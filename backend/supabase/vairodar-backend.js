/**
 * vairodar-backend.js
 * Biblioteca JS para integração com Supabase — Vai Rodar 2026
 *
 * Módulos: Auth, Workshop, Requests, Chat, Proposals, Calendar, Notifications, Stats
 *
 * Uso:
 *   const vr = new VaiRodar({ supabaseUrl: '...', supabaseKey: '...' });
 *   await vr.auth.signUp({ email, password, name, phone });
 */

class VaiRodar {
  constructor({ supabaseUrl, supabaseKey }) {
    if (!supabaseUrl || !supabaseKey) throw new Error('supabaseUrl e supabaseKey são obrigatórios');
    this._url = supabaseUrl;
    this._key = supabaseKey;
    this._token = null;
    this._userId = null;

    this.auth          = new VRAuth(this);
    this.workshops     = new VRWorkshops(this);
    this.requests      = new VRRequests(this);
    this.proposals     = new VRProposals(this);
    this.chat          = new VRChat(this);
    this.calendar      = new VRCalendar(this);
    this.notifications = new VRNotifications(this);
    this.stats         = new VRStats(this);
  }

  // ─── HTTP Helper ────────────────────────────────────────────────
  async _fetch(path, { method = 'GET', body, token, params } = {}) {
    let url = `${this._url}/rest/v1${path}`;
    if (params) {
      const qs = new URLSearchParams(params).toString();
      url += (url.includes('?') ? '&' : '?') + qs;
    }
    const headers = {
      'apikey': this._key,
      'Content-Type': 'application/json',
      'Prefer': 'return=representation',
    };
    const authToken = token || this._token;
    if (authToken) headers['Authorization'] = `Bearer ${authToken}`;

    const res = await fetch(url, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({ message: res.statusText }));
      throw Object.assign(new Error(err.message || 'Erro na requisição'), { status: res.status, details: err });
    }
    if (res.status === 204) return null;
    return res.json();
  }

  // ─── Auth Helper (Supabase Auth REST) ───────────────────────────
  async _authFetch(path, body) {
    const res = await fetch(`${this._url}/auth/v1${path}`, {
      method: 'POST',
      headers: { 'apikey': this._key, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error_description || data.msg || 'Erro de autenticação');
    return data;
  }

  setSession(token, userId) {
    this._token = token;
    this._userId = userId;
  }

  clearSession() {
    this._token = null;
    this._userId = null;
  }
}

// ═══════════════════════════════════════════════════════════════════
// Auth
// ═══════════════════════════════════════════════════════════════════
class VRAuth {
  constructor(vr) { this._vr = vr; }

  async signUp({ email, password, name, phone, role = 'motorist' }) {
    const data = await this._vr._authFetch('/signup', {
      email, password,
      data: { name, phone, role },
    });
    if (data.access_token) {
      this._vr.setSession(data.access_token, data.user?.id);
      // Cria perfil na tabela profiles
      await this._vr._fetch('/profiles', {
        method: 'POST',
        body: { id: data.user.id, name, phone, email, role },
      });
    }
    return data;
  }

  async signIn({ email, password }) {
    const data = await this._vr._authFetch('/token?grant_type=password', { email, password });
    this._vr.setSession(data.access_token, data.user?.id);
    return data;
  }

  async signOut() {
    await fetch(`${this._vr._url}/auth/v1/logout`, {
      method: 'POST',
      headers: { 'apikey': this._vr._key, 'Authorization': `Bearer ${this._vr._token}` },
    });
    this._vr.clearSession();
  }

  async resetPassword(email) {
    return this._vr._authFetch('/recover', { email });
  }

  async getProfile(userId) {
    const id = userId || this._vr._userId;
    const rows = await this._vr._fetch(`/profiles?id=eq.${id}`);
    return rows?.[0] || null;
  }

  async updateProfile(fields) {
    const id = this._vr._userId;
    return this._vr._fetch(`/profiles?id=eq.${id}`, { method: 'PATCH', body: fields });
  }
}

// ═══════════════════════════════════════════════════════════════════
// Workshops
// ═══════════════════════════════════════════════════════════════════
class VRWorkshops {
  constructor(vr) { this._vr = vr; }

  async list({ category, city, open, limit = 20, offset = 0 } = {}) {
    const params = { limit, offset, order: 'rating.desc' };
    let path = '/workshops?';
    if (category) path += `&category=eq.${encodeURIComponent(category)}`;
    if (city)     path += `&city=ilike.*${encodeURIComponent(city)}*`;
    if (open === true)  path += '&open=eq.true';
    path += `&limit=${limit}&offset=${offset}&order=rating.desc`;
    return this._vr._fetch(path.replace('?&', '?'));
  }

  async get(id) {
    const rows = await this._vr._fetch(`/workshops?id=eq.${id}`);
    return rows?.[0] || null;
  }

  async register(data) {
    return this._vr._fetch('/workshops', { method: 'POST', body: data });
  }

  async update(id, data) {
    return this._vr._fetch(`/workshops?id=eq.${id}`, { method: 'PATCH', body: data });
  }

  async search(query) {
    return this._vr._fetch(
      `/workshops?or=(name.ilike.*${encodeURIComponent(query)}*,category.ilike.*${encodeURIComponent(query)}*)&order=rating.desc`
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Service Requests (cotações do motorista)
// ═══════════════════════════════════════════════════════════════════
class VRRequests {
  constructor(vr) { this._vr = vr; }

  async create({ title, description, category, vehicleId, location, imageUrl }) {
    return this._vr._fetch('/service_requests', {
      method: 'POST',
      body: {
        user_id: this._vr._userId,
        title, description, category,
        vehicle_id: vehicleId,
        location, image_url: imageUrl,
        status: 'open',
      },
    });
  }

  async list({ status } = {}) {
    let path = `/service_requests?user_id=eq.${this._vr._userId}&order=created_at.desc`;
    if (status) path += `&status=eq.${status}`;
    return this._vr._fetch(path);
  }

  async get(id) {
    const rows = await this._vr._fetch(`/service_requests?id=eq.${id}`);
    return rows?.[0] || null;
  }

  async close(id) {
    return this._vr._fetch(`/service_requests?id=eq.${id}`, {
      method: 'PATCH', body: { status: 'closed' },
    });
  }
}

// ═══════════════════════════════════════════════════════════════════
// Proposals (respostas das oficinas)
// ═══════════════════════════════════════════════════════════════════
class VRProposals {
  constructor(vr) { this._vr = vr; }

  // Oficina envia proposta
  async send({ requestId, workshopId, price, estimatedTime, message }) {
    return this._vr._fetch('/proposals', {
      method: 'POST',
      body: {
        request_id: requestId,
        workshop_id: workshopId,
        price, estimated_time: estimatedTime,
        message, status: 'pending',
      },
    });
  }

  // Motorista lista propostas de uma solicitação
  async listForRequest(requestId) {
    return this._vr._fetch(
      `/proposals?request_id=eq.${requestId}&order=created_at.desc`
    );
  }

  // Motorista aceita uma proposta
  async accept(proposalId) {
    return this._vr._fetch(`/proposals?id=eq.${proposalId}`, {
      method: 'PATCH', body: { status: 'accepted' },
    });
  }

  // Motorista recusa uma proposta
  async decline(proposalId) {
    return this._vr._fetch(`/proposals?id=eq.${proposalId}`, {
      method: 'PATCH', body: { status: 'declined' },
    });
  }
}

// ═══════════════════════════════════════════════════════════════════
// Chat
// ═══════════════════════════════════════════════════════════════════
class VRChat {
  constructor(vr) { this._vr = vr; }

  async listConversations() {
    return this._vr._fetch(
      `/conversations?or=(user_id.eq.${this._vr._userId},workshop_id.eq.${this._vr._userId})&order=updated_at.desc`
    );
  }

  async getOrCreate({ userId, workshopId }) {
    const rows = await this._vr._fetch(
      `/conversations?user_id=eq.${userId}&workshop_id=eq.${workshopId}`
    );
    if (rows?.length) return rows[0];
    const created = await this._vr._fetch('/conversations', {
      method: 'POST',
      body: { user_id: userId, workshop_id: workshopId },
    });
    return created?.[0];
  }

  async getMessages(conversationId, { limit = 50 } = {}) {
    return this._vr._fetch(
      `/messages?conversation_id=eq.${conversationId}&order=created_at.asc&limit=${limit}`
    );
  }

  async sendMessage({ conversationId, text, imageUrl }) {
    return this._vr._fetch('/messages', {
      method: 'POST',
      body: {
        conversation_id: conversationId,
        sender_id: this._vr._userId,
        text, image_url: imageUrl,
      },
    });
  }

  // Realtime — retorna o canal Supabase (requer @supabase/supabase-js)
  subscribeToConversation(supabaseClient, conversationId, onMessage) {
    return supabaseClient
      .channel(`messages:${conversationId}`)
      .on('postgres_changes', {
        event: 'INSERT',
        schema: 'public',
        table: 'messages',
        filter: `conversation_id=eq.${conversationId}`,
      }, payload => onMessage(payload.new))
      .subscribe();
  }
}

// ═══════════════════════════════════════════════════════════════════
// Calendar / Reservations
// ═══════════════════════════════════════════════════════════════════
class VRCalendar {
  constructor(vr) { this._vr = vr; }

  async createReservation({ workshopId, serviceType, scheduledAt, notes }) {
    return this._vr._fetch('/reservations', {
      method: 'POST',
      body: {
        user_id: this._vr._userId,
        workshop_id: workshopId,
        service_type: serviceType,
        scheduled_at: scheduledAt,
        notes, status: 'pending',
      },
    });
  }

  async listMyReservations({ status } = {}) {
    let path = `/reservations?user_id=eq.${this._vr._userId}&order=scheduled_at.asc`;
    if (status) path += `&status=eq.${status}`;
    return this._vr._fetch(path);
  }

  async listWorkshopReservations(workshopId, { date } = {}) {
    let path = `/reservations?workshop_id=eq.${workshopId}&order=scheduled_at.asc`;
    if (date) path += `&scheduled_at=gte.${date}T00:00:00&scheduled_at=lte.${date}T23:59:59`;
    return this._vr._fetch(path);
  }

  async confirm(reservationId) {
    return this._vr._fetch(`/reservations?id=eq.${reservationId}`, {
      method: 'PATCH', body: { status: 'confirmed' },
    });
  }

  async cancel(reservationId) {
    return this._vr._fetch(`/reservations?id=eq.${reservationId}`, {
      method: 'PATCH', body: { status: 'cancelled' },
    });
  }
}

// ═══════════════════════════════════════════════════════════════════
// Notifications
// ═══════════════════════════════════════════════════════════════════
class VRNotifications {
  constructor(vr) { this._vr = vr; }

  async list({ unreadOnly = false } = {}) {
    let path = `/notifications?user_id=eq.${this._vr._userId}&order=created_at.desc&limit=50`;
    if (unreadOnly) path += '&read=eq.false';
    return this._vr._fetch(path);
  }

  async markRead(notificationId) {
    return this._vr._fetch(`/notifications?id=eq.${notificationId}`, {
      method: 'PATCH', body: { read: true },
    });
  }

  async markAllRead() {
    return this._vr._fetch(`/notifications?user_id=eq.${this._vr._userId}&read=eq.false`, {
      method: 'PATCH', body: { read: true },
    });
  }
}

// ═══════════════════════════════════════════════════════════════════
// Stats (para painel admin)
// ═══════════════════════════════════════════════════════════════════
class VRStats {
  constructor(vr) { this._vr = vr; }

  async overview() {
    const [workshops, requests, users] = await Promise.all([
      this._vr._fetch('/workshops?select=count'),
      this._vr._fetch('/service_requests?select=count'),
      this._vr._fetch('/profiles?select=count'),
    ]);
    return { workshops, requests, users };
  }

  async workshopStats(workshopId) {
    const [proposals, reservations, rating] = await Promise.all([
      this._vr._fetch(`/proposals?workshop_id=eq.${workshopId}&select=count,status`),
      this._vr._fetch(`/reservations?workshop_id=eq.${workshopId}&select=count,status`),
      this._vr._fetch(`/workshops?id=eq.${workshopId}&select=rating,review_count`),
    ]);
    return { proposals, reservations, rating: rating?.[0] };
  }
}

// Exporta para uso em módulos ES e scripts globais
if (typeof module !== 'undefined') module.exports = VaiRodar;
if (typeof window !== 'undefined') window.VaiRodar = VaiRodar;
