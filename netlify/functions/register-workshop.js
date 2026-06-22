const https = require('https');
const { geocodeAddress } = require('./geocode-helper');

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

async function findProfileByEmail(email) {
  const rows = await supabaseRequest(
    `/rest/v1/profiles?email=eq.${encodeURIComponent(email)}&select=id,email,name&limit=1`
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
    if (existingProfile?.id) return { id: existingProfile.id, email };
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

    const payload = {
      owner_id: user.id,
      name: cleanText(workshop.name, 160),
      legal_name: cleanText(workshop.legal_name || workshop.name, 180),
      cnpj: cleanText(workshop.cnpj, 32) || null,
      responsible_name: ownerName,
      contact_phone: cleanText(workshop.contact_phone || workshop.phone || workshop.whatsapp, 60),
      business_type: cleanText(workshop.business_type, 30) || 'workshop',
      parts_categories: Array.isArray(workshop.parts_categories) ? workshop.parts_categories : [],
      parts_delivery_enabled: Boolean(workshop.parts_delivery_enabled),
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
      services: Array.isArray(workshop.services) ? workshop.services : [],
      category: cleanText(workshop.category, 100),
      schedule: workshop.schedule || {},
      approval_status: 'pending',
      visible: false,
      open: false,
      subscription_status: 'pending_payment',
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

    return json(200, { success: true, user_id: user.id, workshop: Array.isArray(saved) ? saved[0] : saved });
  } catch (error) {
    console.error('[register-workshop]', error.message);
    return json(500, { success: false, error: error.message || 'Erro ao cadastrar oficina.' });
  }
};
