const { authorize, corsHeaders, json, supabaseRequest } = require('./admin-common');
const { sendPushToUser } = require('./push-core');
const { geocodeAddress } = require('./geocode-helper');

const LISTING_STATUS_MESSAGES = {
  active: 'Seu anuncio foi aprovado e ja esta publicado.',
  rejected: 'Seu anuncio foi rejeitado pela equipe Vai Rodar.',
  paused: 'Seu anuncio foi pausado.',
  sold: 'Seu anuncio foi marcado como vendido.',
  expired: 'Seu anuncio expirou.',
};

const WORKSHOP_STATUS_MESSAGES = {
  approved: 'Sua oficina foi aprovada e ja esta visivel para os usuarios.',
  rejected: 'O cadastro da sua oficina foi rejeitado pela equipe Vai Rodar.',
  blocked: 'Sua oficina foi bloqueada pela equipe Vai Rodar.',
};

const VALID_STATUSES = new Set(['pending', 'approved', 'rejected', 'blocked']);
const VALID_LISTING_STATUSES = new Set(['pending_review', 'active', 'paused', 'sold', 'expired', 'rejected']);
const VALID_OFFER_STATUSES = new Set(['active', 'inactive']);
const VALID_PCR_DECISIONS = new Set(['approved', 'rejected']);
const PERFIL_PUBLICO_FIELDS = ['name', 'whatsapp', 'email', 'city', 'state', 'address', 'description'];

function cleanText(value, max = 500) {
  return String(value || '').trim().slice(0, max);
}

async function insertNotification({ userId, type, title, detail, link }) {
  if (!userId) return;
  try {
    await supabaseRequest('/rest/v1/notifications', {
      method: 'POST',
      prefer: 'return=minimal',
      body: { user_id: userId, type: type || 'system', title, detail, link: link || '/' },
    });
  } catch (error) {
    console.warn('[admin-action notification]', error.message);
  }
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
      const ownerId = Array.isArray(result) ? result[0]?.owner_id : result?.owner_id;
      if (ownerId && WORKSHOP_STATUS_MESSAGES[status]) {
        await insertNotification({
          userId: ownerId,
          type: 'system',
          title: 'Vai Rodar',
          detail: WORKSHOP_STATUS_MESSAGES[status],
          link: '/',
        });
        await sendPushToUser(ownerId, { title: 'Vai Rodar', body: WORKSHOP_STATUS_MESSAGES[status], url: '/' })
          .catch((error) => console.warn('[admin-action push]', error.message));
      }
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
      const listingOwnerId = Array.isArray(result) ? result[0]?.user_id : result?.user_id;
      if (listingOwnerId && LISTING_STATUS_MESSAGES[status]) {
        await insertNotification({
          userId: listingOwnerId,
          type: 'system',
          title: 'Vai Rodar',
          detail: LISTING_STATUS_MESSAGES[status],
          link: '/',
        });
        await sendPushToUser(listingOwnerId, { title: 'Vai Rodar', body: LISTING_STATUS_MESSAGES[status], url: '/' })
          .catch((error) => console.warn('[admin-action push]', error.message));
      }
      return json(200, { success: true, data: result });
    }

    if (action === 'setWorkshopOfferStatus') {
      const offerId = cleanText(payload.offer_id, 80);
      const status = cleanText(payload.status, 20);
      if (!offerId || !VALID_OFFER_STATUSES.has(status)) {
        return json(400, { success: false, error: 'offer_id e status validos (active/inactive) sao obrigatorios.' });
      }
      const result = await supabaseRequest(`/rest/v1/workshop_offers?id=eq.${encodeURIComponent(offerId)}`, {
        method: 'PATCH',
        body: { status },
      });
      await writeAudit(
        `workshop_offer_${status}`,
        'workshop_offers',
        offerId,
        `Oferta marcada como ${status}.`,
        { status }
      );
      try {
        const offerRows = await supabaseRequest(`/rest/v1/workshop_offers?id=eq.${encodeURIComponent(offerId)}&select=workshop_id,workshops(owner_id)`);
        const offerOwnerId = Array.isArray(offerRows) ? offerRows[0]?.workshops?.owner_id : offerRows?.workshops?.owner_id;
        if (offerOwnerId) {
          const offerMsg = status === 'active' ? 'Sua oferta foi reativada e ja esta visivel.' : 'Sua oferta foi desativada pela equipe Vai Rodar.';
          await insertNotification({ userId: offerOwnerId, type: 'system', title: 'Vai Rodar', detail: offerMsg, link: '/' });
          await sendPushToUser(offerOwnerId, { title: 'Vai Rodar', body: offerMsg, url: '/' })
            .catch((error) => console.warn('[admin-action push]', error.message));
        }
      } catch (error) {
        console.warn('[admin-action offer notify]', error.message);
      }
      return json(200, { success: true, data: result });
    }

    if (action === 'reviewProfileChangeRequest') {
      const requestId = cleanText(payload.request_id, 80);
      const decision = cleanText(payload.decision, 20);
      const adminNotes = cleanText(payload.admin_notes || '', 500);
      if (!requestId || !VALID_PCR_DECISIONS.has(decision)) {
        return json(400, { success: false, error: 'request_id e decision validos (approved/rejected) sao obrigatorios.' });
      }

      const rows = await supabaseRequest(
        `/rest/v1/workshop_profile_change_requests?id=eq.${encodeURIComponent(requestId)}&select=*`
      );
      const request = Array.isArray(rows) ? rows[0] : rows;
      if (!request) return json(404, { success: false, error: 'Solicitacao nao encontrada.' });
      if (request.status !== 'pending') {
        return json(400, { success: false, error: 'Esta solicitacao ja foi revisada.' });
      }

      if (decision === 'approved') {
        let workshopUpdate = {};
        if (request.field_name === 'perfil_publico' && request.new_value && typeof request.new_value === 'object') {
          PERFIL_PUBLICO_FIELDS.forEach((field) => {
            if (request.new_value[field] !== undefined) workshopUpdate[field] = request.new_value[field];
          });
        } else if (request.new_value && typeof request.new_value === 'object' && 'value' in request.new_value) {
          workshopUpdate[request.field_name] = request.new_value.value;
        }
        if (Object.keys(workshopUpdate).length > 0) {
          await supabaseRequest(`/rest/v1/workshops?id=eq.${encodeURIComponent(request.workshop_id)}`, {
            method: 'PATCH',
            body: workshopUpdate,
          });
        }
      }

      const result = await supabaseRequest(
        `/rest/v1/workshop_profile_change_requests?id=eq.${encodeURIComponent(requestId)}`,
        {
          method: 'PATCH',
          body: {
            status: decision,
            admin_notes: adminNotes || null,
            reviewed_at: new Date().toISOString(),
          },
        }
      );
      await writeAudit(
        `profile_change_request_${decision}`,
        'workshop_profile_change_requests',
        requestId,
        `Solicitacao de alteracao (${request.field_name}) da oficina ${request.workshop_id} marcada como ${decision}.`,
        { field_name: request.field_name, decision }
      );
      if (request.workshop_id) {
        try {
          const workshopRows = await supabaseRequest(`/rest/v1/workshops?id=eq.${encodeURIComponent(request.workshop_id)}&select=owner_id`);
          const ownerId = Array.isArray(workshopRows) ? workshopRows[0]?.owner_id : workshopRows?.owner_id;
          if (ownerId) {
            const msg = decision === 'approved'
              ? 'Sua solicitacao de alteracao de perfil foi aprovada.'
              : 'Sua solicitacao de alteracao de perfil foi rejeitada.';
            await insertNotification({ userId: ownerId, type: 'system', title: 'Vai Rodar', detail: msg, link: '/' });
            await sendPushToUser(ownerId, { title: 'Vai Rodar', body: msg, url: '/' });
          }
        } catch (error) {
          console.warn('[admin-action push]', error.message);
        }
      }
      return json(200, { success: true, data: result });
    }

    if (action === 'sendAdminMessage') {
      const recipientType = cleanText(payload.recipient_type, 20);
      const recipientId = cleanText(payload.recipient_id, 80);
      const title = cleanText(payload.title || 'Vai Rodar', 120);
      const message = cleanText(payload.message, 500);
      if (!['user', 'workshop'].includes(recipientType) || !recipientId || !message) {
        return json(400, { success: false, error: 'recipient_type (user/workshop), recipient_id e message sao obrigatorios.' });
      }

      let targetUserId = recipientId;
      if (recipientType === 'workshop') {
        const workshopRows = await supabaseRequest(`/rest/v1/workshops?id=eq.${encodeURIComponent(recipientId)}&select=owner_id`);
        targetUserId = Array.isArray(workshopRows) ? workshopRows[0]?.owner_id : workshopRows?.owner_id;
        if (!targetUserId) return json(404, { success: false, error: 'Oficina nao encontrada ou sem responsavel cadastrado.' });
      }

      await insertNotification({ userId: targetUserId, type: 'system', title, detail: message, link: '/' });
      const push = await sendPushToUser(targetUserId, { title, body: message, url: '/' })
        .catch((error) => { console.warn('[admin-action push]', error.message); return null; });
      await writeAudit(
        'admin_message_sent',
        recipientType,
        recipientId,
        `Mensagem enviada (${recipientType}): ${title} - ${message.slice(0, 100)}`,
        { recipient_type: recipientType, recipient_id: recipientId, title }
      );
      return json(200, { success: true, data: { push } });
    }

    if (action === 'geocodeWorkshop') {
      const workshopId = cleanText(payload.workshop_id, 80);
      if (!workshopId) return json(400, { success: false, error: 'workshop_id obrigatorio.' });

      const rows = await supabaseRequest(
        `/rest/v1/workshops?id=eq.${encodeURIComponent(workshopId)}&select=address,neighborhood,city,state,cep,zip_code`
      );
      const workshop = Array.isArray(rows) ? rows[0] : rows;
      if (!workshop) return json(404, { success: false, error: 'Oficina nao encontrada.' });

      const geocoded = await geocodeAddress({
        address: workshop.address,
        neighborhood: workshop.neighborhood,
        city: workshop.city,
        state: workshop.state,
        cep: workshop.cep || workshop.zip_code,
      });
      if (!geocoded) {
        return json(422, { success: false, error: 'Nao foi possivel localizar coordenadas para este endereco. Confira o CEP/endereco cadastrado da oficina.' });
      }

      const result = await supabaseRequest(`/rest/v1/workshops?id=eq.${encodeURIComponent(workshopId)}`, {
        method: 'PATCH',
        body: { latitude: geocoded.latitude, longitude: geocoded.longitude },
      });
      await writeAudit(
        'workshop_geocoded',
        'workshops',
        workshopId,
        `Coordenadas recalculadas: ${geocoded.latitude}, ${geocoded.longitude}.`,
        geocoded
      );
      return json(200, { success: true, data: result });
    }

    return json(400, { success: false, error: 'Acao admin desconhecida.' });
  } catch (error) {
    console.error('[admin-action]', error.message);
    return json(500, { success: false, error: error.message });
  }
};
