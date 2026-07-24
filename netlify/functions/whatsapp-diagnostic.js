const crypto = require('crypto');
const https = require('https');
const { supabaseRequest, json } = require('./admin-common');

const DIAGNOSTIC_TOKEN = process.env.WHATSAPP_VERIFY_TOKEN || '';
const WHATSAPP_TOKEN = process.env.WHATSAPP_TOKEN || '';
const WABA_ID = process.env.WHATSAPP_BUSINESS_ACCOUNT_ID || '1304610424819827';
const GRAPH_VERSION = process.env.WHATSAPP_GRAPH_VERSION || 'v25.0';

function tokenIsValid(value) {
  if (!DIAGNOSTIC_TOKEN || !value) return false;
  const supplied = Buffer.from(String(value));
  const expected = Buffer.from(DIAGNOSTIC_TOKEN);
  return supplied.length === expected.length && crypto.timingSafeEqual(supplied, expected);
}

function maskedPhone(phone) {
  const digits = String(phone || '').replace(/\D/g, '');
  return digits ? `***${digits.slice(-4)}` : '';
}

function graphRequest(method, path) {
  return new Promise((resolve, reject) => {
    const request = https.request({
      hostname: 'graph.facebook.com',
      path: `/${GRAPH_VERSION}/${path}`,
      method,
      headers: {
        Authorization: `Bearer ${WHATSAPP_TOKEN}`,
        'Content-Type': 'application/json',
        ...(method === 'POST' ? { 'Content-Length': 2 } : {}),
      },
    }, (response) => {
      let raw = '';
      response.on('data', (chunk) => (raw += chunk));
      response.on('end', () => {
        let parsed = {};
        try { parsed = raw ? JSON.parse(raw) : {}; } catch { parsed = { raw }; }
        if (response.statusCode >= 400) {
          reject(new Error(parsed?.error?.message || `Meta ${response.statusCode}`));
          return;
        }
        resolve(parsed);
      });
    });
    request.on('error', reject);
    request.setTimeout(15000, () => request.destroy(new Error('Meta timeout')));
    if (method === 'POST') request.write('{}');
    request.end();
  });
}

exports.handler = async (event) => {
  if (!['GET', 'POST'].includes(event.httpMethod)) return json(405, { error: 'Method not allowed' });
  const headers = event.headers || {};
  const token = headers['x-diagnostic-token'] || headers['X-Diagnostic-Token'] || '';
  if (!tokenIsValid(token)) return json(401, { error: 'Unauthorized' });

  try {
    if (!WHATSAPP_TOKEN || !WABA_ID) {
      return json(503, { error: 'WHATSAPP_TOKEN ou WHATSAPP_BUSINESS_ACCOUNT_ID nao configurado.' });
    }

    if (event.httpMethod === 'POST') {
      const subscription = await graphRequest('POST', `${WABA_ID}/subscribed_apps`);
      const subscribedApps = await graphRequest('GET', `${WABA_ID}/subscribed_apps`);
      return json(200, {
        subscription,
        subscribed_app_ids: (subscribedApps.data || []).map((app) => app.id),
      });
    }

    const [contacts, messages] = await Promise.all([
      supabaseRequest(
        '/rest/v1/crm_contacts?select=id,phone,name,source,status,last_message_at,last_message_preview,created_at&order=created_at.desc&limit=20'
      ),
      supabaseRequest(
        '/rest/v1/crm_messages?select=id,contact_id,direction,status,wa_message_id,created_at&order=created_at.desc&limit=30'
      ),
    ]);

    return json(200, {
      contacts: (contacts || []).map((contact) => ({
        ...contact,
        phone: maskedPhone(contact.phone),
      })),
      messages: messages || [],
      meta: await graphRequest('GET', `${WABA_ID}/subscribed_apps`)
        .then((result) => ({
          waba_id: WABA_ID,
          subscribed_app_ids: (result.data || []).map((app) => app.id),
        }))
        .catch((error) => ({ waba_id: WABA_ID, error: error.message })),
    });
  } catch (error) {
    return json(500, { error: error.message });
  }
};
