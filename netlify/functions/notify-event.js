const https = require('https');
const { json, supabaseRequest } = require('./admin-common');
const { sendPushToUser, sendPushToAdmins } = require('./push-core');

// Notifica eventos reais de proposta (criada / aceita / recusada) e de mensagens de chat:
// 1. Insere uma linha real em public.notifications (a campainha do user-app le essa tabela).
// 2. Envia push web (celular) para o destinatario, via push-core (usa as mesmas
//    VAPID keys/secrets que ja existem so no Netlify, nunca no frontend).
//
// O campo "link" guarda um token simples que o frontend usa pra navegar direto pra
// acao relacionada ao clicar na notificacao (chat:<conversationId> ou quote:<requestId>),
// ja que o app nao tem router de URL.

const SUPABASE_URL = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
const SUPABASE_ANON_KEY =
  process.env.SUPABASE_ANON_KEY ||
  process.env.SUPABASE_ANON_PUBLIC_KEY ||
  process.env.SUPABASE_SERVICE_ROLE_KEY ||
  process.env.SUPABASE_SERVICE_KEY;

function getBearer(event) {
  const value = event.headers?.authorization || event.headers?.Authorization || '';
  return value.replace(/^Bearer\s+/i, '').trim();
}

function getUser(accessToken) {
  return new Promise((resolve, reject) => {
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return reject(new Error('Supabase public config missing'));
    const url = new URL(`${SUPABASE_URL}/auth/v1/user`);
    const req = https.request(
      {
        hostname: url.hostname,
        path: url.pathname,
        method: 'GET',
        headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${accessToken}` },
      },
      (res) => {
        let data = '';
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => {
          try {
            const parsed = data ? JSON.parse(data) : null;
            if (res.statusCode >= 400) return reject(new Error(parsed?.msg || parsed?.message || 'Invalid session'));
            resolve(parsed);
          } catch (error) {
            reject(error);
          }
        });
      }
    );
    req.on('error', reject);
    req.setTimeout(10000, () => req.destroy(new Error('Supabase auth timeout')));
    req.end();
  });
}

async function loadProposalContext(proposalId) {
  const rows = await supabaseRequest(
    `/rest/v1/proposals?id=eq.${encodeURIComponent(proposalId)}&select=id,price,status,request_id,workshop_id,service_requests(id,title,user_id),workshops(id,name,owner_id)`
  );
  const proposal = Array.isArray(rows) ? rows[0] : null;
  if (!proposal || !proposal.service_requests || !proposal.workshops) throw new Error('Proposta nao encontrada.');
  return proposal;
}

async function loadConversationContext(conversationId) {
  const rows = await supabaseRequest(
    `/rest/v1/conversations?id=eq.${encodeURIComponent(conversationId)}&select=id,user_id,workshop_id,profiles(id,name),workshops(id,name,owner_id)`
  );
  const conversation = Array.isArray(rows) ? rows[0] : null;
  if (!conversation || !conversation.workshops) throw new Error('Conversa nao encontrada.');
  return conversation;
}

async function insertNotification({ userId, type, title, detail, link }) {
  await supabaseRequest('/rest/v1/notifications', {
    method: 'POST',
    prefer: 'return=minimal',
    body: { user_id: userId, type, title, detail, link: link || '/' },
  });
}

async function ensureNotification({ userId, type, title, detail, link }) {
  const rows = await supabaseRequest(
    `/rest/v1/notifications?user_id=eq.${encodeURIComponent(userId)}&title=eq.${encodeURIComponent(title)}&detail=eq.${encodeURIComponent(detail)}&link=eq.${encodeURIComponent(link || '/')}&select=id&limit=1`
  );
  if (Array.isArray(rows) && rows.length) return rows[0];
  await insertNotification({ userId, type, title, detail, link });
  return null;
}

async function notifyAdmins(title, body) {
  return sendPushToAdmins({ title, body, url: '/admin/' })
    .catch((error) => {
      console.warn('[notify-event admin]', error.message);
      return { sent: 0, failed: 0 };
    });
}

function postgresIn(values) {
  return values.map((value) => `"${String(value).replace(/"/g, '')}"`).join(',');
}

const CATEGORY_ALIASES = new Map([
  ['revisao geral / manutencao preventiva', 'mecanica geral'],
  ['troca de oleo e filtros', 'oleo e filtros'],
  ['freios e suspensao', 'freios'],
  ['motor e transmissao', 'mecanica geral'],
  ['eletrica automotiva', 'bateria e eletrica'],
  ['pneus e alinhamento', 'pneus'],
  ['diagnostico computadorizado', 'mecanica geral'],
  ['vidros e acessorios', 'vidros e para-brisas'],
  ['blindagem', 'acessorios'],
  ['lavagem e estetica', 'estetica automotiva'],
]);

function normalizeCategory(value) {
  const normalized = String(value || '')
    .trim()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase();
  return CATEGORY_ALIASES.get(normalized) || normalized;
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return json(200, {});
  if (event.httpMethod !== 'POST') return json(405, { error: 'Method Not Allowed' });

  try {
    const accessToken = getBearer(event);
    if (!accessToken) return json(401, { error: 'Sessao obrigatoria.' });
    const callerUser = await getUser(accessToken);

    const payload = JSON.parse(event.body || '{}');
    const eventType = String(payload.event || '').trim();

    if (eventType === 'message_received') {
      const conversationId = String(payload.conversationId || '').trim();
      if (!conversationId) return json(400, { error: 'conversationId obrigatorio.' });
      const conversation = await loadConversationContext(conversationId);
      const driverId = conversation.user_id;
      const workshopOwnerId = conversation.workshops.owner_id;
      if (callerUser.id !== driverId && callerUser.id !== workshopOwnerId) {
        return json(403, { error: 'Voce nao participa desta conversa.' });
      }
      const recipientId = callerUser.id === driverId ? workshopOwnerId : driverId;
      const senderName = callerUser.id === driverId
        ? (conversation.profiles?.name || 'Motorista')
        : (conversation.workshops.name || 'Oficina');
      const text = String(payload.text || '').slice(0, 160) || 'Nova mensagem.';
      await insertNotification({
        userId: recipientId,
        type: 'message',
        title: `Nova mensagem de ${senderName}`,
        detail: text,
        link: `chat:${conversationId}`,
      });
      const push = await sendPushToUser(recipientId, {
        title: `Nova mensagem de ${senderName}`,
        body: text,
        url: '/',
      });
      const adminPush = await notifyAdmins('Nova mensagem na plataforma', `${senderName}: ${text}`);
      return json(200, { ok: true, push, adminPush });
    }

    if (eventType === 'service_request_created') {
      const requestId = String(payload.requestId || '').trim();
      if (!requestId) return json(400, { error: 'requestId obrigatorio.' });
      const requestRows = await supabaseRequest(
        `/rest/v1/service_requests?id=eq.${encodeURIComponent(requestId)}&select=id,user_id,title,category,target_business_type,selected_business_ids,status`
      );
      const request = Array.isArray(requestRows) ? requestRows[0] : null;
      if (!request) return json(404, { error: 'Solicitacao nao encontrada.' });
      if (callerUser.id !== request.user_id) return json(403, { error: 'Apenas o motorista pode notificar esta solicitacao.' });

      const selectedIds = Array.isArray(request.selected_business_ids)
        ? request.selected_business_ids.filter(Boolean)
        : [];
      let path = '/rest/v1/workshops?approval_status=eq.approved&visible=eq.true&open=eq.true&select=id,name,owner_id,business_type,services';
      if (selectedIds.length) path += `&id=in.(${postgresIn(selectedIds)})`;
      const workshopRows = await supabaseRequest(path);
      const category = normalizeCategory(request.category);
      const targetType = String(request.target_business_type || 'workshop').trim();
      const eligible = (Array.isArray(workshopRows) ? workshopRows : []).filter((workshop) => {
        if (!workshop.owner_id) return false;
        if (targetType && String(workshop.business_type || 'workshop') !== targetType) return false;
        if (selectedIds.length || !category) return true;
        return (Array.isArray(workshop.services) ? workshop.services : [])
          .some((service) => normalizeCategory(service) === category);
      });
      const title = 'Nova solicitacao recebida';
      const detail = `${request.category || 'Servico'}: ${request.title || 'Novo pedido de motorista'}.`;
      const pushes = [];
      for (const workshop of eligible) {
        await insertNotification({
          userId: workshop.owner_id,
          type: 'quote',
          title,
          detail,
          link: '/',
        });
        pushes.push(await sendPushToUser(workshop.owner_id, { title, body: detail, url: '/oficinas/painel/' }));
      }
      const adminPush = await notifyAdmins('Nova solicitacao de motorista', detail);
      return json(200, { ok: true, recipients: eligible.length, pushes, adminPush });
    }

    // Flujo propuesta→reserva (RPCs de 20260720): la notificación
    // interna YA fue creada por la RPC en Supabase. Este evento
    // dispara SOLO el push al destinatario correcto.
    if (eventType === 'reservation_flow') {
      const reservationId = String(payload.reservationId || '').trim();
      const flowEvent = String(payload.flowEvent || '').trim();
      const FLOW_EVENTS = {
        proposal_accepted:          { to: 'workshop', title: 'Proposta aceita', body: 'O motorista aceitou sua proposta. Uma reserva foi criada.' },
        reservation_created:        { to: 'both',     title: 'Reserva criada', body: 'Uma nova reserva foi criada no Vai Rodar.' },
        reservation_time_requested: { to: 'workshop', title: 'Horario solicitado', body: 'O motorista escolheu um horario. Confirme a reserva.' },
        reservation_confirmed:      { to: 'driver',   title: 'Reserva confirmada', body: 'A oficina confirmou sua reserva.' },
        reservation_cancelled:      { to: 'counterpart', title: 'Reserva cancelada', body: 'A reserva foi cancelada.' },
        reservation_completed:      { to: 'driver',   title: 'Servico concluido', body: 'A oficina marcou seu servico como concluido.' },
      };
      const flow = FLOW_EVENTS[flowEvent];
      if (!reservationId || !flow) return json(400, { error: 'reservationId e flowEvent validos sao obrigatorios.' });

      const reservationRows = await supabaseRequest(
        `/rest/v1/reservations?id=eq.${encodeURIComponent(reservationId)}&select=id,user_id,workshop_id,service_type,workshops(id,name,owner_id)`
      );
      const reservation = Array.isArray(reservationRows) ? reservationRows[0] : null;
      if (!reservation || !reservation.workshops) return json(404, { error: 'Reserva nao encontrada.' });

      const driverId = reservation.user_id;
      const ownerId = reservation.workshops.owner_id;
      if (callerUser.id !== driverId && callerUser.id !== ownerId) {
        return json(403, { error: 'Voce nao participa desta reserva.' });
      }

      const targets = [];
      if (flow.to === 'workshop') targets.push(ownerId);
      else if (flow.to === 'driver') targets.push(driverId);
      else if (flow.to === 'both') { targets.push(driverId, ownerId); }
      else if (flow.to === 'counterpart') targets.push(callerUser.id === driverId ? ownerId : driverId);

      const pushes = [];
      for (const targetId of [...new Set(targets.filter(Boolean))]) {
        if (targetId === callerUser.id) continue;
        const push = await sendPushToUser(targetId, { title: flow.title, body: flow.body, url: '/' })
          .catch((error) => { console.warn('[notify-event reservation_flow]', error.message); return null; });
        pushes.push(push);
      }
      const adminPush = await notifyAdmins(flow.title, `${reservation.workshops.name || 'Oficina'}: ${flow.body}`);
      return json(200, { ok: true, pushes, adminPush });
    }

    if (eventType === 'reservation_status_changed') {
      const reservationId = String(payload.reservationId || '').trim();
      const status = String(payload.status || '').trim();
      if (!reservationId || !status) return json(400, { error: 'reservationId e status sao obrigatorios.' });
      const reservationRows = await supabaseRequest(
        `/rest/v1/reservations?id=eq.${encodeURIComponent(reservationId)}&select=id,user_id,workshop_id,service_type,workshops(id,name,owner_id)`
      );
      const reservation = Array.isArray(reservationRows) ? reservationRows[0] : null;
      if (!reservation || !reservation.workshops) return json(404, { error: 'Reserva nao encontrada.' });
      if (callerUser.id !== reservation.workshops.owner_id) {
        return json(403, { error: 'Apenas a oficina pode notificar este evento.' });
      }
      if (!reservation.user_id) return json(200, { ok: true, skipped: true });
      const workshopName = reservation.workshops.name || 'A oficina';
      const verbByStatus = { confirmed: 'confirmou', cancelled: 'cancelou', completed: 'finalizou' };
      const titleByStatus = {
        confirmed: 'Reserva confirmada',
        cancelled: 'Reserva cancelada',
        completed: 'Servico finalizado',
      };
      const verb = verbByStatus[status] || 'atualizou';
      const title = titleByStatus[status] || 'Reserva atualizada';
      const detail = `${workshopName} ${verb} sua reserva (${reservation.service_type || 'servico'}).`;
      await insertNotification({ userId: reservation.user_id, type: 'quote', title, detail, link: '/' });
      const push = await sendPushToUser(reservation.user_id, { title, body: detail, url: '/' });
      const adminPush = await notifyAdmins(title, detail);
      return json(200, { ok: true, push, adminPush });
    }

    const proposalId = String(payload.proposalId || '').trim();
    if (!proposalId) return json(400, { error: 'proposalId obrigatorio.' });

    const proposal = await loadProposalContext(proposalId);
    const requestTitle = proposal.service_requests.title || 'sua solicitacao';
    const driverId = proposal.service_requests.user_id;
    const workshopOwnerId = proposal.workshops.owner_id;
    const workshopName = proposal.workshops.name || 'Uma oficina';
    const priceText = proposal.price != null ? `R$ ${proposal.price}` : 'preco a combinar';

    if (eventType === 'proposal_created') {
      if (callerUser.id !== workshopOwnerId) return json(403, { error: 'Apenas a oficina pode notificar este evento.' });
      const title = 'Nova proposta recebida';
      const detail = `${workshopName} respondeu: ${requestTitle} (${priceText}).`;
      const link = `quote:${proposal.request_id}`;
      // O trigger do banco cria este aviso junto com a proposta. Este fallback
      // mantem o fluxo funcional antes da migration e evita duplicar depois dela.
      await ensureNotification({ userId: driverId, type: 'quote', title, detail, link });
      const push = await sendPushToUser(driverId, {
        title,
        body: `${workshopName} respondeu sua solicitacao: ${requestTitle}.`,
        url: '/',
      });
      const adminPush = await notifyAdmins('Nova proposta enviada', `${workshopName} respondeu: ${requestTitle} (${priceText}).`);
      return json(200, { ok: true, push, adminPush });
    }

    if (eventType === 'proposal_accepted' || eventType === 'proposal_declined') {
      if (callerUser.id !== driverId) return json(403, { error: 'Apenas o motorista pode notificar este evento.' });
      const accepted = eventType === 'proposal_accepted';
      await insertNotification({
        userId: workshopOwnerId,
        type: 'quote',
        title: accepted ? 'Proposta aceita!' : 'Proposta recusada',
        detail: `O motorista ${accepted ? 'aceitou' : 'recusou'} sua proposta para: ${requestTitle}.`,
        link: '/',
      });
      const push = await sendPushToUser(workshopOwnerId, {
        title: accepted ? 'Proposta aceita!' : 'Proposta recusada',
        body: `O motorista ${accepted ? 'aceitou' : 'recusou'} sua proposta: ${requestTitle}.`,
        url: '/',
      });
      const adminPush = await notifyAdmins(
        accepted ? 'Proposta aceita' : 'Proposta recusada',
        `${workshopName}: ${requestTitle}.`
      );
      return json(200, { ok: true, push, adminPush });
    }

    return json(400, { error: 'Evento desconhecido.' });
  } catch (error) {
    console.error('[notify-event]', error.message);
    return json(500, { error: 'Nao foi possivel enviar a notificacao.', detail: error.message });
  }
};
