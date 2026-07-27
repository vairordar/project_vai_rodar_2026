const https = require('https');
const { geocodeAddress } = require('./geocode-helper');
const { sendPushToAdmins } = require('./push-core');

const SUPABASE_URL = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_KEY;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json',
};

function json(statusCode, body) {
  return { statusCode, headers: corsHeaders, body: JSON.stringify(body) };
}

function assertConfig() {
  if (!SUPABASE_URL) throw new Error('SUPABASE_URL nao configurada no Netlify.');
  if (!SERVICE_ROLE_KEY) throw new Error('SUPABASE_SERVICE_ROLE_KEY nao configurada no Netlify.');
}

function cleanText(value, max = 500) {
  return String(value || '').trim().slice(0, max);
}

function supabaseRequest(path, options = {}) {
  return new Promise((resolve, reject) => {
    const body = options.body ? JSON.stringify(options.body) : null;
    const url = new URL(`${SUPABASE_URL}${path}`);
    const req = https.request(
      {
        hostname: url.hostname,
        path: `${url.pathname}${url.search}`,
        method: options.method || 'GET',
        headers: {
          apikey: SERVICE_ROLE_KEY,
          Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
          'Content-Type': 'application/json',
          Prefer: options.prefer || 'return=representation',
          ...(body ? { 'Content-Length': Buffer.byteLength(body) } : {}),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => {
          let parsed = null;
          try { parsed = data ? JSON.parse(data) : null; } catch { parsed = data; }
          if (res.statusCode >= 400) {
            const detail = parsed?.msg || parsed?.message || parsed?.error_description || parsed?.error || data || `Supabase ${res.statusCode}`;
            reject(new Error(detail));
            return;
          }
          resolve(parsed);
        });
      }
    );
    req.on('error', reject);
    req.setTimeout(15000, () => req.destroy(new Error('Supabase timeout')));
    if (body) req.write(body);
    req.end();
  });
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Valida category_ids contra el catálogo administrado.
// Devuelve las categorías oficiales (id, name, sort_order) o lanza
// un Error con statusCode 400 si algo no es válido.
async function validateCategoryIds(categoryIds) {
  if (!Array.isArray(categoryIds) || !categoryIds.length) {
    const err = new Error('Selecione pelo menos uma categoria de serviço.');
    err.statusCode = 400;
    throw err;
  }
  const cleaned = [...new Set(categoryIds.map((id) => cleanText(id, 80).toLowerCase()))];
  const invalid = cleaned.filter((id) => !UUID_RE.test(id));
  if (invalid.length) {
    const err = new Error('IDs de categoria inválidos.');
    err.statusCode = 400;
    throw err;
  }
  const rows = await supabaseRequest(
    `/rest/v1/service_categories?id=in.(${cleaned.join(',')})&active=eq.true&select=id,name,sort_order`
  );
  const found = Array.isArray(rows) ? rows : [];
  if (found.length !== cleaned.length) {
    const foundIds = new Set(found.map((row) => String(row.id).toLowerCase()));
    const missing = cleaned.filter((id) => !foundIds.has(id));
    const err = new Error(`Categorias inexistentes ou inativas: ${missing.join(', ')}`);
    err.statusCode = 400;
    throw err;
  }
  found.sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0) || String(a.name).localeCompare(String(b.name)));
  return found;
}

async function findProfileByEmail(email) {
  const rows = await supabaseRequest(
    `/rest/v1/profiles?email=eq.${encodeURIComponent(email)}&select=id,email,name,role&limit=1`
  );
  return Array.isArray(rows) ? rows[0] || null : null;
}

async function getOrCreateUser(email, password, metadata) {
  try {
    return await supabaseRequest('/auth/v1/admin/users', {
      method: 'POST',
      body: {
        email,
        password,
        email_confirm: true,
        user_metadata: metadata,
      },
    });
  } catch (error) {
    if (!/already|registered|exists|duplicate/i.test(error.message)) throw error;
    const existingProfile = await findProfileByEmail(email).catch(() => null);
    if (existingProfile?.id) {
      if (String(existingProfile.role || '').toLowerCase() !== 'workshop') {
        const identityError = new Error('Este e-mail ja pertence a uma conta de motorista. Use outro e-mail para cadastrar a oficina.');
        identityError.statusCode = 409;
        throw identityError;
      }
      return { id: existingProfile.id, email };
    }
    throw new Error('Este e-mail ja existe no Auth, mas nao tem perfil vinculado. Use outro e-mail ou remova o usuario antigo no Supabase Auth.');
  }
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 200, headers: corsHeaders, body: '' };
  if (event.httpMethod !== 'POST') return json(405, { success: false, error: 'Method not allowed' });

  try {
    assertConfig();
    const body = JSON.parse(event.body || '{}');
    const email = cleanText(body.email, 180).toLowerCase();
    const password = String(body.password || '');
    const workshop = body.workshop || {};

    if (!email || !email.includes('@')) return json(400, { success: false, error: 'E-mail invalido.' });
    if (password.length < 6) return json(400, { success: false, error: 'A senha deve ter pelo menos 6 caracteres.' });
    if (!cleanText(workshop.name, 160)) return json(400, { success: false, error: 'Nome da oficina obrigatorio.' });

    // Catálogo administrado: el frontend nuevo envía category_ids.
    // Si vienen, se validan estrictamente y los nombres oficiales
    // reemplazan a workshop.services (nunca se aceptan nombres
    // arbitrarios del navegador). Si NO vienen (frontend anterior),
    // se mantiene el flujo legacy con workshop.services.
    let officialCategories = null;
    if (body.category_ids !== undefined) {
      try {
        officialCategories = await validateCategoryIds(body.category_ids);
      } catch (error) {
        return json(error.statusCode || 500, { success: false, error: error.message });
      }
    }

    // Plan elegido en el cadastro (free | pro). Debe existir y estar
    // activo en la tabla plans. Sin plan enviado (frontend viejo) = free.
    let selectedPlan = 'free';
    if (body.plan !== undefined) {
      selectedPlan = cleanText(body.plan, 20).toLowerCase();
      const planRows = await supabaseRequest(
        `/rest/v1/plans?code=eq.${encodeURIComponent(selectedPlan)}&active=eq.true&select=code&limit=1`
      ).catch(() => []);
      if (!Array.isArray(planRows) || !planRows.length) {
        return json(400, { success: false, error: 'Plano invalido ou indisponivel.' });
      }
    }

    const ownerName = cleanText(body.owner_name || workshop.responsible_name, 160);
    const now = new Date().toISOString();
    const user = await getOrCreateUser(email, password, {
      role: 'workshop',
      name: ownerName,
      terms_accepted_at: now,
      privacy_accepted_at: now,
      legal_version: '2026-06',
    });

    await supabaseRequest('/rest/v1/profiles', {
      method: 'POST',
      prefer: 'resolution=merge-duplicates,return=representation',
      body: {
        id: user.id,
        name: ownerName || cleanText(workshop.name, 160),
        email,
        phone: cleanText(workshop.contact_phone || workshop.phone || workshop.whatsapp, 60),
        role: 'workshop',
      },
    });

    const existing = await supabaseRequest(
      `/rest/v1/workshops?owner_id=eq.${encodeURIComponent(user.id)}&select=id&limit=1`
    );

    const requestedServiceMode = cleanText(workshop?.schedule?.mode || workshop.service_mode, 40);
    const normalizedServiceMode = requestedServiceMode
      .normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '')
      .toLowerCase();
    const supportsHomeService = Boolean(
      workshop.home_service ||
      workshop.parts_delivery_enabled ||
      normalizedServiceMode.includes('domicilio') ||
      normalizedServiceMode.includes('ambos') ||
      normalizedServiceMode === 'home' ||
      normalizedServiceMode === 'both'
    );
    const persistedSchedule = {
      ...(workshop.schedule && typeof workshop.schedule === 'object' ? workshop.schedule : {}),
      mode: requestedServiceMode || (supportsHomeService ? 'Ambos' : 'Na oficina'),
    };

    const payload = {
      owner_id: user.id,
      name: cleanText(workshop.name, 160),
      legal_name: cleanText(workshop.legal_name || workshop.name, 180),
      cnpj: cleanText(workshop.cnpj, 32) || null,
      responsible_name: ownerName,
      contact_phone: cleanText(workshop.contact_phone || workshop.phone || workshop.whatsapp, 60),
      business_type: cleanText(workshop.business_type, 30) || 'workshop',
      parts_categories: Array.isArray(workshop.parts_categories) ? workshop.parts_categories : [],
      home_service: supportsHomeService,
      parts_delivery_enabled: supportsHomeService,
      parts_pickup_enabled: workshop.parts_pickup_enabled !== false,
      description: cleanText(workshop.description, 700),
      email,
      phone: cleanText(workshop.phone || workshop.contact_phone, 60),
      whatsapp: cleanText(workshop.whatsapp || workshop.contact_phone || workshop.phone, 60),
      address: cleanText(workshop.address, 240),
      neighborhood: cleanText(workshop.neighborhood, 120),
      city: cleanText(workshop.city, 120),
      state: cleanText(workshop.state, 40),
      zip_code: cleanText(workshop.zip_code, 20),
      cep: cleanText(workshop.cep || workshop.zip_code, 20),
      services: officialCategories
        ? officialCategories.map((c) => c.name)
        : (Array.isArray(workshop.services) ? workshop.services : []),
      category: cleanText(workshop.category, 100),
      schedule: persistedSchedule,
      approval_status: 'pending',
      visible: false,
      open: false,
      latitude: null,
      longitude: null,
      subscription_status: 'pending_payment',
      plan: selectedPlan,
      plan_selected_at: now,
    };

    const geocoded = await geocodeAddress({
      address: payload.address,
      neighborhood: payload.neighborhood,
      city: payload.city,
      state: payload.state,
      cep: payload.cep || payload.zip_code,
    }).catch(() => null);
    if (geocoded) {
      payload.latitude = geocoded.latitude;
      payload.longitude = geocoded.longitude;
    }

    const saved = existing?.[0]?.id
      ? await supabaseRequest(`/rest/v1/workshops?id=eq.${encodeURIComponent(existing[0].id)}`, {
          method: 'PATCH',
          body: payload,
        })
      : await supabaseRequest('/rest/v1/workshops', {
          method: 'POST',
          body: payload,
        });

    const savedWorkshop = Array.isArray(saved) ? saved[0] : saved;

    if (savedWorkshop?.id) {
      await supabaseRequest('/rest/v1/workshop_owner_details?on_conflict=workshop_id', {
        method: 'POST',
        prefer: 'resolution=merge-duplicates,return=minimal',
        body: {
          workshop_id: savedWorkshop.id,
          responsible_name: ownerName,
          cnpj: payload.cnpj,
          no_cnpj: !payload.cnpj,
          contact_phone: payload.contact_phone,
          contact_email: email,
        },
      });
    }

    // Relaciones por ID en workshop_categories. Si esto falla, el
    // registro NO se reporta como exitoso (sin éxito silencioso).
    if (officialCategories && savedWorkshop?.id) {
      try {
        await supabaseRequest(
          `/rest/v1/workshop_categories?workshop_id=eq.${encodeURIComponent(savedWorkshop.id)}`,
          { method: 'DELETE', prefer: 'return=minimal' }
        );
        await supabaseRequest('/rest/v1/workshop_categories', {
          method: 'POST',
          prefer: 'return=minimal',
          body: officialCategories.map((c) => ({
            workshop_id: savedWorkshop.id,
            category_id: c.id,
          })),
        });
      } catch (error) {
        console.error('[register-workshop categories]', error.message);
        return json(500, {
          success: false,
          error: `Oficina criada, mas houve erro ao salvar as categorias: ${error.message}. Tente novamente ou contate o suporte.`,
          user_id: user.id,
        });
      }
    }

    await sendPushToAdmins({
      title: 'Novo comercio pendente',
      body: `${savedWorkshop?.name || payload.name} concluiu o cadastro e aguarda aprovacao.`,
      url: '/admin/',
    }).catch((error) => console.warn('[register-workshop admin push]', error.message));

    return json(200, { success: true, user_id: user.id, workshop: savedWorkshop });
  } catch (error) {
    console.error('[register-workshop]', error.message);
    return json(error.statusCode || 500, { success: false, error: error.message || 'Erro ao cadastrar oficina.' });
  }
};
