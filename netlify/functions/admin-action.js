const { authorize, corsHeaders, json, supabaseRequest } = require('./admin-common');

const VALID_STATUSES = new Set(['pending', 'approved', 'rejected', 'blocked']);
const VALID_LISTING_STATUSES = new Set(['pending_review', 'active', 'paused', 'sold', 'expired', 'rejected']);

function cleanText(value, max = 500) {
  return String(value || '').trim().slice(0, max);
}

async function writeAudit(action, entity, entityId, detail, metadata = {}) {
  try {
    await supabaseRequest('/rest/v1/admin_audit_logs', {
      method: 'POST',
      body: {
        admin_email: 'netlify-admin',
        action,
        entity,
        entity_id: entityId || null,
        detail,
        metadata,
      },
    });
  } catch (error) {
    console.warn('[admin-action audit]', error.message);
  }
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
      const update = {
        approval_status: status,
        visible: Boolean(payload.visible),
      };
      if (payload.open !== null && payload.open !== undefined) update.open = Boolean(payload.open);
      if (status === 'approved') update.approved_at = new Date().toISOString();

      const result = await supabaseRequest(`/rest/v1/workshops?id=eq.${encodeURIComponent(payload.workshop_id)}`, {
        method: 'PATCH',
        body: update,
      });
      await writeAudit(
        `workshop_${status}`,
        'workshops',
        payload.workshop_id,
        `Oficina marcada como ${status}. Visivel: ${update.visible}. Recebe pedidos: ${update.open === undefined ? 'sem alteracao' : update.open}.`,
        update
      );
      return json(200, { success: true, data: result });
    }

    if (action === 'createSubscriptionPayment') {
      if (!payload.workshop_id || !Number(payload.amount)) {
        return json(400, { success: false, error: 'workshop_id e amount sao obrigatorios.' });
      }
      const now = new Date().toISOString();
      const reference = cleanText(payload.reference || `ADMIN-${Date.now()}`, 120);
      const subscriptionRows = await supabaseRequest('/rest/v1/workshop_subscriptions', {
        method: 'POST',
        body: {
          workshop_id: payload.workshop_id,
          plan_name: cleanText(payload.plan_name || 'Anual oficina', 120),
          paid_at: now,
          duration_days: Number(payload.duration_days || 365),
          amount_paid: Number(payload.amount),
          payment_method: cleanText(payload.method || 'Manual', 80),
          payment_reference: reference,
          invoice_url: cleanText(payload.invoice_url || '', 500) || null,
          notes: cleanText(payload.notes || '', 500) || null,
        },
      });
      const subscription = Array.isArray(subscriptionRows) ? subscriptionRows[0] : subscriptionRows;
      const paymentRows = await supabaseRequest('/rest/v1/workshop_payments', {
        method: 'POST',
        body: {
          workshop_id: payload.workshop_id,
          subscription_id: subscription?.id || null,
          paid_at: now,
          status: 'paid',
          method: cleanText(payload.method || 'Manual', 80),
          amount: Number(payload.amount),
          reference,
          invoice_url: cleanText(payload.invoice_url || '', 500) || null,
          notes: cleanText(payload.notes || '', 500) || null,
        },
      });
      await writeAudit(
        'subscription_payment_created',
        'workshop_subscriptions',
        subscription?.id || null,
        `Assinatura registrada para oficina ${payload.workshop_id}. Valor: ${Number(payload.amount)}. Duracao: ${Number(payload.duration_days || 365)} dias.`,
        { workshop_id: payload.workshop_id, amount: Number(payload.amount), reference }
      );
      return json(200, { success: true, data: { subscription, payment: Array.isArray(paymentRows) ? paymentRows[0] : paymentRows } });
    }

    if (action === 'setVehicleListingStatus') {
      const listingId = cleanText(payload.listing_id, 80);
      const status = cleanText(payload.status, 30);
      if (!listingId || !VALID_LISTING_STATUSES.has(status)) {
        return json(400, { success: false, error: 'listing_id e status validos sao obrigatorios.' });
      }
      const result = await supabaseRequest(`/rest/v1/vehicle_listings?id=eq.${encodeURIComponent(listingId)}`, {
        method: 'PATCH',
        body: { status },
      });
      await writeAudit(
        `vehicle_listing_${status}`,
        'vehicle_listings',
        listingId,
        `Anuncio de veiculo marcado como ${status}.`,
        { status }
      );
      return json(200, { success: true, data: result });
    }

    return json(400, { success: false, error: 'Acao admin desconhecida.' });
  } catch (error) {
    console.error('[admin-action]', error.message);
    return json(500, { success: false, error: error.message });
  }
};
