// Webhook de WhatsApp Cloud API (Meta) para el CRM Vai Rodar.
// - GET: verificación del webhook (hub.challenge) con WHATSAPP_VERIFY_TOKEN.
// - POST: mensajes entrantes y actualizaciones de estado (sent/delivered/read).
// Usa service role para escribir en crm_contacts / crm_messages.
// Si las variables de entorno no están configuradas, responde 503 sin romper.
const crypto = require('crypto');
const { supabaseRequest, json, corsHeaders } = require('./admin-common');

const VERIFY_TOKEN = process.env.WHATSAPP_VERIFY_TOKEN || '';
const APP_SECRET = process.env.WHATSAPP_APP_SECRET || '';

function webhookSignatureIsValid(event) {
  if (!APP_SECRET) return false;
  const headers = event.headers || {};
  const supplied = String(
    headers['x-hub-signature-256']
    || headers['X-Hub-Signature-256']
    || ''
  );
  const expected = `sha256=${crypto
    .createHmac('sha256', APP_SECRET)
    .update(event.body || '', 'utf8')
    .digest('hex')}`;
  if (supplied.length !== expected.length) return false;
  return crypto.timingSafeEqual(Buffer.from(supplied), Buffer.from(expected));
}

function normalizePhone(value) {
  const digits = String(value || '').replace(/\D/g, '');
  return digits ? `+${digits}` : '';
}

async function upsertContactByPhone(phone, profileName) {
  const encoded = encodeURIComponent(phone);
  const rows = await supabaseRequest(`/rest/v1/crm_contacts?phone=eq.${encoded}&select=id,name&limit=1`);
  if (Array.isArray(rows) && rows.length) return rows[0];
  const created = await supabaseRequest('/rest/v1/crm_contacts', {
    method: 'POST',
    body: {
      phone,
      name: profileName || null,
      source: 'inbound',
      status: 'new',
    },
  });
  return Array.isArray(created) ? created[0] : created;
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 200, headers: corsHeaders, body: '' };

  // Verificación del webhook (configuración inicial en Meta)
  if (event.httpMethod === 'GET') {
    const params = event.queryStringParameters || {};
    if (!VERIFY_TOKEN) return json(503, { error: 'WHATSAPP_VERIFY_TOKEN nao configurado no Netlify.' });
    if (params['hub.mode'] === 'subscribe' && params['hub.verify_token'] === VERIFY_TOKEN) {
      return { statusCode: 200, headers: { 'Content-Type': 'text/plain' }, body: params['hub.challenge'] || '' };
    }
    return json(403, { error: 'Token de verificacao invalido.' });
  }

  if (event.httpMethod !== 'POST') return json(405, { error: 'Method not allowed' });
  if (!APP_SECRET) return json(503, { error: 'WHATSAPP_APP_SECRET nao configurado no Netlify.' });
  if (!webhookSignatureIsValid(event)) return json(401, { error: 'Assinatura do webhook invalida.' });

  try {
    const payload = JSON.parse(event.body || '{}');
    const entries = Array.isArray(payload.entry) ? payload.entry : [];

    for (const entry of entries) {
      const changes = Array.isArray(entry.changes) ? entry.changes : [];
      for (const change of changes) {
        const value = change.value || {};

        // 1) Mensajes entrantes
        const messages = Array.isArray(value.messages) ? value.messages : [];
        const contactsInfo = Array.isArray(value.contacts) ? value.contacts : [];
        for (const message of messages) {
          const phone = normalizePhone(message.from);
          if (!phone) continue;
          const profileName = contactsInfo.find((c) => normalizePhone(c.wa_id) === phone)?.profile?.name || null;
          const contact = await upsertContactByPhone(phone, profileName);
          if (!contact?.id) continue;

          const body =
            message.text?.body
            || message.button?.text
            || message.interactive?.button_reply?.title
            || message.interactive?.list_reply?.title
            || `[${message.type || 'mensagem'}]`;

          await supabaseRequest('/rest/v1/crm_messages', {
            method: 'POST',
            prefer: 'return=minimal',
            body: {
              contact_id: contact.id,
              direction: 'inbound',
              body: String(body).slice(0, 2000),
              wa_message_id: message.id || null,
              status: 'received',
            },
          }).catch((error) => console.warn('[whatsapp-webhook msg]', error.message));

          await supabaseRequest(`/rest/v1/crm_contacts?id=eq.${encodeURIComponent(contact.id)}`, {
            method: 'PATCH',
            prefer: 'return=minimal',
            body: {
              last_message_at: new Date().toISOString(),
              last_message_preview: String(body).slice(0, 160),
            },
          }).catch((error) => console.warn('[whatsapp-webhook contact]', error.message));
        }

        // 2) Estados de mensajes salientes (sent → delivered → read / failed)
        const statuses = Array.isArray(value.statuses) ? value.statuses : [];
        for (const statusUpdate of statuses) {
          if (!statusUpdate.id) continue;
          const newStatus = ['sent', 'delivered', 'read', 'failed'].includes(statusUpdate.status)
            ? statusUpdate.status : null;
          if (!newStatus) continue;
          await supabaseRequest(`/rest/v1/crm_messages?wa_message_id=eq.${encodeURIComponent(statusUpdate.id)}`, {
            method: 'PATCH',
            prefer: 'return=minimal',
            body: {
              status: newStatus,
              error: statusUpdate.errors?.[0]?.title || null,
            },
          }).catch((error) => console.warn('[whatsapp-webhook status]', error.message));
        }
      }
    }

    // Meta exige 200 rápido; los errores internos ya quedaron logueados.
    return json(200, { ok: true });
  } catch (error) {
    console.error('[whatsapp-webhook]', error.message);
    return json(200, { ok: true }); // nunca hacer reintentar a Meta en loop
  }
};
