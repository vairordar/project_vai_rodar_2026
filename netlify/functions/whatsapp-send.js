// Envío de mensajes de WhatsApp desde el CRM del admin (Vai Rodar).
// Protegido con X-Admin-Password (igual que admin-action).
// Requiere en Netlify: WHATSAPP_TOKEN y WHATSAPP_PHONE_NUMBER_ID.
// Sin esas variables responde un error claro (modo preparación).
//
// Body:
//   { contact_id, text }                                → mensaje libre
//   { contact_id, template_name, template_params: [] }  → plantilla aprobada
// Nota Meta: los mensajes libres solo llegan dentro de la ventana de
// 24h desde el último mensaje del contacto. Para iniciar conversación
// se DEBE usar una plantilla aprobada.
const https = require('https');
const { authorize, corsHeaders, json, supabaseRequest } = require('./admin-common');

const WHATSAPP_TOKEN = process.env.WHATSAPP_TOKEN || '';
const PHONE_NUMBER_ID = process.env.WHATSAPP_PHONE_NUMBER_ID || '';
const GRAPH_VERSION = process.env.WHATSAPP_GRAPH_VERSION || 'v20.0';

function graphRequest(path, body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = https.request(
      {
        hostname: 'graph.facebook.com',
        path: `/${GRAPH_VERSION}${path}`,
        method: 'POST',
        headers: {
          Authorization: `Bearer ${WHATSAPP_TOKEN}`,
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(data),
        },
      },
      (res) => {
        let out = '';
        res.on('data', (chunk) => (out += chunk));
        res.on('end', () => {
          let parsed = null;
          try { parsed = out ? JSON.parse(out) : null; } catch { parsed = out; }
          if (res.statusCode >= 400) {
            reject(new Error(parsed?.error?.message || out || `Meta ${res.statusCode}`));
            return;
          }
          resolve(parsed);
        });
      }
    );
    req.on('error', reject);
    req.setTimeout(15000, () => req.destroy(new Error('Meta timeout')));
    req.write(data);
    req.end();
  });
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 200, headers: corsHeaders, body: '' };
  if (event.httpMethod !== 'POST') return json(405, { success: false, error: 'Method not allowed' });

  try {
    if (!authorize(event)) return json(401, { success: false, error: 'Senha admin invalida.' });

    if (!WHATSAPP_TOKEN || !PHONE_NUMBER_ID) {
      return json(503, {
        success: false,
        error: 'WhatsApp ainda nao configurado: defina WHATSAPP_TOKEN e WHATSAPP_PHONE_NUMBER_ID no Netlify (ver docs/guia-configuracion-whatsapp-cloud.md).',
      });
    }

    const body = JSON.parse(event.body || '{}');
    const contactId = String(body.contact_id || '').trim();
    const text = String(body.text || '').trim().slice(0, 2000);
    const templateName = String(body.template_name || '').trim();
    const templateParams = Array.isArray(body.template_params) ? body.template_params : [];

    if (!contactId) return json(400, { success: false, error: 'contact_id obrigatorio.' });
    if (!text && !templateName) return json(400, { success: false, error: 'Informe text ou template_name.' });

    const rows = await supabaseRequest(
      `/rest/v1/crm_contacts?id=eq.${encodeURIComponent(contactId)}&select=id,phone,name&limit=1`
    );
    const contact = Array.isArray(rows) ? rows[0] : null;
    if (!contact) return json(404, { success: false, error: 'Contato nao encontrado.' });

    const to = String(contact.phone || '').replace(/\D/g, '');
    if (!to) return json(400, { success: false, error: 'Contato sem telefone valido.' });

    let payload;
    if (templateName) {
      payload = {
        messaging_product: 'whatsapp',
        to,
        type: 'template',
        template: {
          name: templateName,
          language: { code: String(body.template_language || 'pt_BR') },
          ...(templateParams.length
            ? {
                components: [{
                  type: 'body',
                  parameters: templateParams.map((p) => ({ type: 'text', text: String(p).slice(0, 300) })),
                }],
              }
            : {}),
        },
      };
    } else {
      payload = { messaging_product: 'whatsapp', to, type: 'text', text: { body: text } };
    }

    let waMessageId = null;
    let sendError = null;
    try {
      const result = await graphRequest(`/${PHONE_NUMBER_ID}/messages`, payload);
      waMessageId = result?.messages?.[0]?.id || null;
    } catch (error) {
      sendError = error.message;
    }

    const preview = templateName ? `[template] ${templateName}` : text;
    const saved = await supabaseRequest('/rest/v1/crm_messages', {
      method: 'POST',
      body: {
        contact_id: contact.id,
        direction: 'outbound',
        body: preview.slice(0, 2000),
        template_name: templateName || null,
        wa_message_id: waMessageId,
        status: sendError ? 'failed' : 'sent',
        error: sendError,
      },
    });

    await supabaseRequest(`/rest/v1/crm_contacts?id=eq.${encodeURIComponent(contact.id)}`, {
      method: 'PATCH',
      prefer: 'return=minimal',
      body: {
        last_message_at: new Date().toISOString(),
        last_message_preview: preview.slice(0, 160),
        ...(sendError ? {} : { status: 'contacted' }),
      },
    }).catch((error) => console.warn('[whatsapp-send contact]', error.message));

    if (sendError) {
      return json(502, { success: false, error: `Falha ao enviar: ${sendError}`, message: Array.isArray(saved) ? saved[0] : saved });
    }
    return json(200, { success: true, wa_message_id: waMessageId, message: Array.isArray(saved) ? saved[0] : saved });
  } catch (error) {
    console.error('[whatsapp-send]', error.message);
    return json(500, { success: false, error: error.message });
  }
};
