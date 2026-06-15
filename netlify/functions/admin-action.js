const { authorize, corsHeaders, json, supabaseRequest } = require('./admin-common');

const VALID_STATUSES = new Set(['pending', 'approved', 'rejected', 'blocked']);

function cleanText(value, max = 500) {
  return String(value || '').trim().slice(0, max);
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 200, headers: corsHeaders, body: '' };
  if (event.httpMethod !== 'POST') return json(405, { success: false, error: 'Method not allowed' });

  try {
    if (!authorize(event)) return json(401, { success: false, error: 'Senha admin invalida.' });

    let body;
    try { body = JSON.parse(event.body || '{}'); }
    catch { return json(400, { success: false, error: 'Body invalido.' }); }

    const action = cleanText(body.action, 80);
    const payload = body.payload || {};

    if (action === 'setWorkshopVisibility') {
      const status = cleanText(payload.approval_status, 20);
      if (!payload.workshop_id || !VALID_STATUSES.has(status)) {
        return json(400, { success: false, error: 'workshop_id e approval_status validos sao obrigatorios.' });
      }
      const result = await supabaseRequest('/rest/v1/rpc/admin_set_workshop_visibility', {
        method: 'POST',
        body: {
          p_workshop_id: payload.workshop_id,
          p_approval_status: status,
          p_visible: Boolean(payload.visible),
          p_open: payload.open === null || payload.open === undefined ? null : Boolean(payload.open),
        },
      });
      return json(200, { success: true, data: result });
    }

    if (action === 'createSubscriptionPayment') {
      if (!payload.workshop_id || !Number(payload.amount)) {
        return json(400, { success: false, error: 'workshop_id e amount sao obrigatorios.' });
      }
      const result = await supabaseRequest('/rest/v1/rpc/create_workshop_subscription_payment', {
        method: 'POST',
        body: {
          p_workshop_id: payload.workshop_id,
          p_amount: Number(payload.amount),
          p_method: cleanText(payload.method || 'Manual', 80),
          p_reference: cleanText(payload.reference || `ADMIN-${Date.now()}`, 120),
          p_invoice_url: cleanText(payload.invoice_url || '', 500) || null,
          p_notes: cleanText(payload.notes || '', 500) || null,
          p_duration_days: Number(payload.duration_days || 365),
        },
      });
      return json(200, { success: true, data: result });
    }

    return json(400, { success: false, error: 'Acao admin desconhecida.' });
  } catch (error) {
    console.error('[admin-action]', error.message);
    return json(500, { success: false, error: error.message });
  }
};
