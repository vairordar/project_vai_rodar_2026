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

const WORKSHOP_TEXT_FIELD_MAX = {
  name: 160, legal_name: 180, cnpj: 32, responsible_name: 160, contact_phone: 60, phone: 60,
  whatsapp: 60, email: 180, business_type: 30, description: 700, address: 240, neighborhood: 120,
  city: 120, state: 40, cep: 20, zip_code: 20, category: 100,
};
const VALID_STATUSES = new Set(['pending', 'approved', 'rejected', 'blocked']);
const VALID_LISTING_STATUSES = new Set(['pending_review', 'active', 'paused', 'sold', 'expired', 'rejected']);
const VALID_OFFER_STATUSES = new Set(['pending', 'active', 'inactive', 'rejected', 'expired']);
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
      const statusReason = cleanText(payload.reason || '', 300);
      const update = {
        approval_status: status,
        visible: Boolean(payload.visible),
      };
      if (payload.open !== null && payload.open !== undefined) update.open = Boolean(payload.open);
      if (status === 'approved') update.approved_at = new Date().toISOString();
      if (status === 'rejected' || status === 'blocked') {
        update.blocked_reason = statusReason || null;
        update.blocked_at = new Date().toISOString();
      } else {
        update.blocked_reason = null;
        update.blocked_at = null;
      }

      const result = await supabaseRequest(`/rest/v1/workshops?id=eq.${encodeURIComponent(payload.workshop_id)}`, {
        method: 'PATCH',
        body: update,
      });
      await writeAudit(
        `workshop_${status}`,
        'workshops',
        payload.workshop_id,
        `Oficina marcada como ${status}. Visivel: ${update.visible}. Recebe pedidos: ${update.open === undefined ? 'sem alteracao' : update.open}.${statusReason ? ` Motivo: ${statusReason}` : ''}`,
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
        return json(400, { success: false, error: 'offer_id e status validos (pending/active/inactive/rejected/expired) sao obrigatorios.' });
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
          const offerMessages = {
            pending: 'Sua oferta esta aguardando revisao da equipe Vai Rodar.',
            active: 'Sua oferta foi aprovada e ja esta visivel.',
            inactive: 'Sua oferta foi desativada pela equipe Vai Rodar.',
            rejected: 'Sua oferta foi rejeitada pela equipe Vai Rodar.',
            expired: 'Sua oferta foi marcada como expirada.',
          };
          const offerMsg = offerMessages[status] || `Sua oferta foi atualizada para ${status}.`;
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

    if (action === 'updateWorkshopInfo') {
      const workshopId = cleanText(payload.workshop_id, 80);
      if (!workshopId) return json(400, { success: false, error: 'workshop_id obrigatorio.' });

      const update = {};
      Object.keys(WORKSHOP_TEXT_FIELD_MAX).forEach((field) => {
        if (payload[field] === undefined) return;
        update[field] = cleanText(payload[field], WORKSHOP_TEXT_FIELD_MAX[field]) || null;
      });
      if (payload.services !== undefined) {
        update.services = Array.isArray(payload.services) ? payload.services.map((item) => cleanText(item, 80)).filter(Boolean) : [];
      }
      if (payload.parts_categories !== undefined) {
        update.parts_categories = Array.isArray(payload.parts_categories) ? payload.parts_categories.map((item) => cleanText(item, 80)).filter(Boolean) : [];
      }
      if (payload.parts_delivery_enabled !== undefined) update.parts_delivery_enabled = Boolean(payload.parts_delivery_enabled);
      if (payload.parts_pickup_enabled !== undefined) update.parts_pickup_enabled = Boolean(payload.parts_pickup_enabled);
      if (!update.name) return json(400, { success: false, error: 'Nome da oficina e obrigatorio.' });

      if (!Object.keys(update).length) {
        return json(400, { success: false, error: 'Nenhum campo valido para atualizar.' });
      }

      const addressFields = ['address', 'neighborhood', 'city', 'state', 'cep', 'zip_code'];
      const addressChanged = addressFields.some((field) => update[field] !== undefined);
      if (addressChanged) {
        const currentRows = await supabaseRequest(
          `/rest/v1/workshops?id=eq.${encodeURIComponent(workshopId)}&select=address,neighborhood,city,state,cep,zip_code`
        );
        const current = Array.isArray(currentRows) ? currentRows[0] : currentRows;
        const merged = { ...current, ...update };
        const geocoded = await geocodeAddress({
          address: merged.address,
          neighborhood: merged.neighborhood,
          city: merged.city,
          state: merged.state,
          cep: merged.cep || merged.zip_code,
        }).catch(() => null);
        if (geocoded) {
          update.latitude = geocoded.latitude;
          update.longitude = geocoded.longitude;
        }
      }

      const result = await supabaseRequest(`/rest/v1/workshops?id=eq.${encodeURIComponent(workshopId)}`, {
        method: 'PATCH',
        body: update,
      });
      await writeAudit(
        'workshop_info_updated',
        'workshops',
        workshopId,
        `Informacoes da oficina atualizadas: ${Object.keys(update).join(', ')}.`,
        update
      );
      return json(200, { success: true, data: result });
    }

    if (action === 'upsertServiceCategory') {
      const categoryId = cleanText(payload.category_id, 80);
      const name = cleanText(payload.name, 100);
      if (!categoryId && !name) return json(400, { success: false, error: 'name obrigatorio para criar categoria.' });
      const update = {};
      if (name) update.name = name;
      if (payload.sort_order !== undefined && Number.isFinite(Number(payload.sort_order))) update.sort_order = Number(payload.sort_order);
      if (payload.active !== undefined) update.active = Boolean(payload.active);
      if (!Object.keys(update).length) return json(400, { success: false, error: 'Nenhum campo valido para atualizar.' });
      const result = categoryId
        ? await supabaseRequest(`/rest/v1/service_categories?id=eq.${encodeURIComponent(categoryId)}`, { method: 'PATCH', body: update })
        : await supabaseRequest('/rest/v1/service_categories', { method: 'POST', body: { sort_order: 0, active: true, ...update } });
      await writeAudit(
        categoryId ? 'service_category_updated' : 'service_category_created',
        'service_categories',
        categoryId || (Array.isArray(result) ? result[0]?.id : result?.id) || null,
        `Categoria ${categoryId ? 'atualizada' : 'criada'}: ${name || categoryId}.`,
        update
      );
      return json(200, { success: true, data: result });
    }

    if (action === 'deleteServiceCategory') {
      const categoryId = cleanText(payload.category_id, 80);
      if (!categoryId) return json(400, { success: false, error: 'category_id obrigatorio.' });
      const categoryFilter = encodeURIComponent(categoryId);
      const [servicesInUse, workshopsInUse] = await Promise.all([
        supabaseRequest(`/rest/v1/workshop_services?select=id&category_id=eq.${categoryFilter}&limit=1`),
        supabaseRequest(`/rest/v1/workshop_categories?select=workshop_id&category_id=eq.${categoryFilter}&limit=1`),
      ]);
      const hasServices = Array.isArray(servicesInUse) && servicesInUse.length;
      const hasWorkshops = Array.isArray(workshopsInUse) && workshopsInUse.length;
      if (hasServices || hasWorkshops) {
        return json(409, {
          success: false,
          error: 'Categoria em uso por oficinas ou servicos. Desative-a em vez de excluir, ou remova antes todos os vinculos.',
        });
      }
      const result = await supabaseRequest(`/rest/v1/service_categories?id=eq.${encodeURIComponent(categoryId)}`, { method: 'DELETE' });
      await writeAudit('service_category_deleted', 'service_categories', categoryId, 'Categoria excluida (subcategorias removidas em cascata).', {});
      return json(200, { success: true, data: result });
    }

    if (action === 'upsertServiceSubcategory') {
      const subcategoryId = cleanText(payload.subcategory_id, 80);
      const categoryId = cleanText(payload.category_id, 80);
      const name = cleanText(payload.name, 100);
      if (!subcategoryId && (!categoryId || !name)) {
        return json(400, { success: false, error: 'category_id e name sao obrigatorios para criar subcategoria.' });
      }
      const update = {};
      if (categoryId) update.category_id = categoryId;
      if (name) update.name = name;
      if (payload.sort_order !== undefined && Number.isFinite(Number(payload.sort_order))) update.sort_order = Number(payload.sort_order);
      if (payload.active !== undefined) update.active = Boolean(payload.active);
      if (!Object.keys(update).length) return json(400, { success: false, error: 'Nenhum campo valido para atualizar.' });
      const result = subcategoryId
        ? await supabaseRequest(`/rest/v1/service_subcategories?id=eq.${encodeURIComponent(subcategoryId)}`, { method: 'PATCH', body: update })
        : await supabaseRequest('/rest/v1/service_subcategories', { method: 'POST', body: { sort_order: 0, active: true, ...update } });
      await writeAudit(
        subcategoryId ? 'service_subcategory_updated' : 'service_subcategory_created',
        'service_subcategories',
        subcategoryId || (Array.isArray(result) ? result[0]?.id : result?.id) || null,
        `Subcategoria ${subcategoryId ? 'atualizada' : 'criada'}: ${name || subcategoryId}.`,
        update
      );
      return json(200, { success: true, data: result });
    }

    if (action === 'deleteServiceSubcategory') {
      const subcategoryId = cleanText(payload.subcategory_id, 80);
      if (!subcategoryId) return json(400, { success: false, error: 'subcategory_id obrigatorio.' });
      const inUse = await supabaseRequest(
        `/rest/v1/workshop_services?select=id&subcategory_id=eq.${encodeURIComponent(subcategoryId)}&limit=100`
      );
      const usageCount = Array.isArray(inUse) ? inUse.length : 0;
      if (usageCount && !payload.force) {
        return json(400, { success: false, error: `Subcategoria em uso por ${usageCount} servico(s) de oficinas. Envie force=true para excluir mesmo assim (os servicos existentes mantem o nome, sem vinculo).` });
      }
      const result = await supabaseRequest(`/rest/v1/service_subcategories?id=eq.${encodeURIComponent(subcategoryId)}`, { method: 'DELETE' });
      await writeAudit('service_subcategory_deleted', 'service_subcategories', subcategoryId, `Subcategoria excluida. Servicos vinculados: ${usageCount}.`, { force: Boolean(payload.force), usage: usageCount });
      return json(200, { success: true, data: result });
    }

    if (action === 'setUserBlocked') {
      const userId = cleanText(payload.user_id, 80);
      const blocked = payload.blocked === true;
      const reason = cleanText(payload.reason || '', 300);
      if (!userId) return json(400, { success: false, error: 'user_id obrigatorio.' });
      if (blocked && !reason) return json(400, { success: false, error: 'Motivo do bloqueio obrigatorio.' });

      const result = await supabaseRequest(`/rest/v1/profiles?id=eq.${encodeURIComponent(userId)}`, {
        method: 'PATCH',
        body: {
          blocked,
          blocked_reason: blocked ? reason : null,
          blocked_at: blocked ? new Date().toISOString() : null,
          blocked_by: blocked ? 'netlify-admin' : null,
        },
      });
      if (!Array.isArray(result) || !result.length) {
        return json(404, { success: false, error: 'Usuario nao encontrado.' });
      }

      // Ban real en Supabase Auth: impide iniciar sesión.
      try {
        await supabaseRequest(`/auth/v1/admin/users/${encodeURIComponent(userId)}`, {
          method: 'PUT',
          body: { ban_duration: blocked ? '87600h' : 'none' },
        });
      } catch (error) {
        console.warn('[admin-action auth ban]', error.message);
        return json(200, {
          success: true,
          data: result,
          warning: `Perfil ${blocked ? 'bloqueado' : 'desbloqueado'}, mas o ban de login falhou: ${error.message}`,
        });
      }

      await writeAudit(
        blocked ? 'user_blocked' : 'user_unblocked',
        'profiles',
        userId,
        blocked ? `Usuario bloqueado. Motivo: ${reason}` : 'Usuario desbloqueado.',
        { blocked, reason }
      );
      return json(200, { success: true, data: result });
    }

    if (action === 'setVehicleBlocked') {
      const vehicleId = cleanText(payload.vehicle_id, 80);
      const blocked = payload.blocked === true;
      const reason = cleanText(payload.reason || '', 300);
      if (!vehicleId) return json(400, { success: false, error: 'vehicle_id obrigatorio.' });
      if (blocked && !reason) return json(400, { success: false, error: 'Motivo do bloqueio obrigatorio.' });

      const result = await supabaseRequest(`/rest/v1/vehicles?id=eq.${encodeURIComponent(vehicleId)}`, {
        method: 'PATCH',
        body: {
          blocked,
          blocked_reason: blocked ? reason : null,
          blocked_at: blocked ? new Date().toISOString() : null,
          blocked_by: blocked ? 'netlify-admin' : null,
        },
      });
      if (!Array.isArray(result) || !result.length) {
        return json(404, { success: false, error: 'Veiculo nao encontrado.' });
      }
      await writeAudit(
        blocked ? 'vehicle_blocked' : 'vehicle_unblocked',
        'vehicles',
        vehicleId,
        blocked ? `Placa bloqueada. Motivo: ${reason}` : 'Placa desbloqueada.',
        { blocked, reason, plate: result[0]?.plate || null }
      );
      return json(200, { success: true, data: result });
    }

    if (action === 'deleteWorkshop') {
      const workshopId = cleanText(payload.workshop_id, 80);
      if (!workshopId) return json(400, { success: false, error: 'workshop_id obrigatorio.' });

      const idFilter = encodeURIComponent(workshopId);
      const selectedBusinessFilter = encodeURIComponent(`{${workshopId}}`);
      const [proposals, reservations, conversations, subscriptionsRows, paymentsRows, offers, profileChanges, directedRequests] = await Promise.all([
        supabaseRequest(`/rest/v1/proposals?select=id&workshop_id=eq.${idFilter}&limit=1000`),
        supabaseRequest(`/rest/v1/reservations?select=id&workshop_id=eq.${idFilter}&limit=1000`),
        supabaseRequest(`/rest/v1/conversations?select=id&workshop_id=eq.${idFilter}&limit=1000`),
        supabaseRequest(`/rest/v1/workshop_subscriptions?select=id&workshop_id=eq.${idFilter}&limit=1000`),
        supabaseRequest(`/rest/v1/workshop_payments?select=id&workshop_id=eq.${idFilter}&limit=1000`),
        supabaseRequest(`/rest/v1/workshop_offers?select=id&workshop_id=eq.${idFilter}&limit=1000`),
        supabaseRequest(`/rest/v1/workshop_profile_change_requests?select=id&workshop_id=eq.${idFilter}&limit=1000`),
        supabaseRequest(`/rest/v1/service_requests?select=id&selected_business_ids=cs.${selectedBusinessFilter}&limit=1000`),
      ]);
      const deps = [
        ['propostas', proposals],
        ['reservas', reservations],
        ['conversas', conversations],
        ['assinaturas', subscriptionsRows],
        ['pagamentos', paymentsRows],
        ['ofertas', offers],
        ['solicitacoes de alteracao', profileChanges],
        ['solicitacoes direcionadas', directedRequests],
      ]
        .map(([label, rows]) => [label, Array.isArray(rows) ? rows.length : 0])
        .filter(([, count]) => count > 0);

      if (deps.length) {
        const detail = deps.map(([label, count]) => `${count} ${label}`).join(', ');
        return json(409, {
          success: false,
          error: `Este comercio tem historico (${detail}) e nao pode ser eliminado definitivamente. Mantenha-o bloqueado.`,
        });
      }

      const result = await supabaseRequest(`/rest/v1/workshops?id=eq.${idFilter}`, { method: 'DELETE' });
      await writeAudit(
        'workshop_deleted',
        'workshops',
        workshopId,
        'Comercio eliminado definitivamente (sem historico).',
        {}
      );
      return json(200, { success: true, data: result });
    }

    if (action === 'upsertCrmContact') {
      const contactId = cleanText(payload.contact_id, 80);
      const phoneDigits = String(payload.phone || '').replace(/\D/g, '');
      const phone = phoneDigits ? `+${phoneDigits}` : '';
      if (!contactId && !phone) return json(400, { success: false, error: 'phone obrigatorio para criar contato (formato +5511999999999).' });
      const update = {};
      if (phone) update.phone = phone;
      ['name', 'business_name', 'city', 'state', 'notes'].forEach((field) => {
        if (payload[field] !== undefined) update[field] = cleanText(payload[field], field === 'notes' ? 2000 : 160) || null;
      });
      if (payload.status !== undefined) {
        const status = cleanText(payload.status, 30);
        if (!['new', 'contacted', 'interested', 'negotiating', 'registered', 'not_interested', 'invalid'].includes(status)) {
          return json(400, { success: false, error: 'status de contato invalido.' });
        }
        update.status = status;
      }
      if (payload.tags !== undefined) {
        update.tags = Array.isArray(payload.tags) ? payload.tags.map((t) => cleanText(t, 40)).filter(Boolean) : [];
      }
      if (payload.workshop_id !== undefined) update.workshop_id = cleanText(payload.workshop_id, 80) || null;
      if (!Object.keys(update).length) return json(400, { success: false, error: 'Nenhum campo valido para atualizar.' });

      const result = contactId
        ? await supabaseRequest(`/rest/v1/crm_contacts?id=eq.${encodeURIComponent(contactId)}`, { method: 'PATCH', body: update })
        : await supabaseRequest('/rest/v1/crm_contacts', { method: 'POST', body: { source: 'manual', status: 'new', ...update } });
      await writeAudit(
        contactId ? 'crm_contact_updated' : 'crm_contact_created',
        'crm_contacts',
        contactId || (Array.isArray(result) ? result[0]?.id : result?.id) || null,
        `Contato CRM ${contactId ? 'atualizado' : 'criado'}: ${update.business_name || update.name || phone || contactId}.`,
        update
      );
      return json(200, { success: true, data: result });
    }

    if (action === 'deleteCrmContact') {
      const contactId = cleanText(payload.contact_id, 80);
      if (!contactId) return json(400, { success: false, error: 'contact_id obrigatorio.' });
      const result = await supabaseRequest(`/rest/v1/crm_contacts?id=eq.${encodeURIComponent(contactId)}`, { method: 'DELETE' });
      await writeAudit('crm_contact_deleted', 'crm_contacts', contactId, 'Contato CRM excluido (mensagens removidas em cascata).', {});
      return json(200, { success: true, data: result });
    }

    if (action === 'importCrmContacts') {
      // payload.contacts: [{phone, name?, business_name?, city?, state?, notes?}]
      const list = Array.isArray(payload.contacts) ? payload.contacts.slice(0, 500) : [];
      if (!list.length) return json(400, { success: false, error: 'contacts (array) obrigatorio.' });
      const rows = [];
      const invalid = [];
      for (const item of list) {
        const digits = String(item.phone || '').replace(/\D/g, '');
        if (digits.length < 10) { invalid.push(item.phone || '(vazio)'); continue; }
        rows.push({
          phone: `+${digits}`,
          name: cleanText(item.name, 160) || null,
          business_name: cleanText(item.business_name, 160) || null,
          city: cleanText(item.city, 120) || null,
          state: cleanText(item.state, 40) || null,
          notes: cleanText(item.notes, 2000) || null,
          source: 'import',
          status: 'new',
        });
      }
      if (!rows.length) return json(400, { success: false, error: `Nenhum telefone valido. Invalidos: ${invalid.join(', ')}` });
      const result = await supabaseRequest('/rest/v1/crm_contacts?on_conflict=phone', {
        method: 'POST',
        prefer: 'resolution=ignore-duplicates,return=representation',
        body: rows,
      });
      const inserted = Array.isArray(result) ? result.length : 0;
      await writeAudit('crm_contacts_imported', 'crm_contacts', null,
        `Importacao CRM: ${inserted} novos, ${rows.length - inserted} duplicados, ${invalid.length} invalidos.`,
        { total: list.length, inserted, invalid: invalid.length });
      return json(200, { success: true, data: { inserted, duplicated: rows.length - inserted, invalid } });
    }

    if (action === 'upsertCrmTemplate') {
      const templateId = cleanText(payload.template_id, 80);
      const name = cleanText(payload.name, 120);
      const templateBody = cleanText(payload.body, 2000);
      if (!templateId && (!name || !templateBody)) {
        return json(400, { success: false, error: 'name e body sao obrigatorios para criar template.' });
      }
      const update = {};
      if (name) update.name = name;
      if (templateBody) update.body = templateBody;
      if (payload.language !== undefined) update.language = cleanText(payload.language, 10) || 'pt_BR';
      if (payload.meta_status !== undefined) {
        const metaStatus = cleanText(payload.meta_status, 20);
        if (!['draft', 'pending', 'approved', 'rejected'].includes(metaStatus)) {
          return json(400, { success: false, error: 'meta_status invalido.' });
        }
        update.meta_status = metaStatus;
      }
      if (payload.active !== undefined) update.active = Boolean(payload.active);
      const result = templateId
        ? await supabaseRequest(`/rest/v1/crm_templates?id=eq.${encodeURIComponent(templateId)}`, { method: 'PATCH', body: update })
        : await supabaseRequest('/rest/v1/crm_templates', { method: 'POST', body: update });
      await writeAudit(
        templateId ? 'crm_template_updated' : 'crm_template_created',
        'crm_templates',
        templateId || (Array.isArray(result) ? result[0]?.id : result?.id) || null,
        `Template CRM ${templateId ? 'atualizado' : 'criado'}: ${name || templateId}.`,
        update
      );
      return json(200, { success: true, data: result });
    }

    if (action === 'deleteCrmTemplate') {
      const templateId = cleanText(payload.template_id, 80);
      if (!templateId) return json(400, { success: false, error: 'template_id obrigatorio.' });
      const result = await supabaseRequest(`/rest/v1/crm_templates?id=eq.${encodeURIComponent(templateId)}`, { method: 'DELETE' });
      await writeAudit('crm_template_deleted', 'crm_templates', templateId, 'Template CRM excluido.', {});
      return json(200, { success: true, data: result });
    }

    if (action === 'setWorkshopPlan') {
      const workshopId = cleanText(payload.workshop_id, 80);
      const plan = cleanText(payload.plan, 20).toLowerCase();
      if (!workshopId || !['free', 'pro'].includes(plan)) {
        return json(400, { success: false, error: 'workshop_id e plan (free/pro) sao obrigatorios.' });
      }
      const update = {
        plan,
        plan_selected_at: new Date().toISOString(),
      };
      // Precio particular para este cliente (override del oficial).
      // null/vacío = vuelve al precio de la tabla plans.
      if (payload.custom_price !== undefined) {
        const price = payload.custom_price === null || payload.custom_price === ''
          ? null : Number(payload.custom_price);
        if (price !== null && (!Number.isFinite(price) || price < 0)) {
          return json(400, { success: false, error: 'custom_price invalido.' });
        }
        update.plan_price = price;
      }
      const result = await supabaseRequest(`/rest/v1/workshops?id=eq.${encodeURIComponent(workshopId)}`, {
        method: 'PATCH',
        body: update,
      });
      if (!Array.isArray(result) || !result.length) {
        return json(404, { success: false, error: 'Oficina nao encontrada.' });
      }
      await writeAudit(
        'workshop_plan_changed',
        'workshops',
        workshopId,
        `Plano alterado para ${plan}.${update.plan_price !== undefined ? ` Preco particular: ${update.plan_price === null ? 'precio oficial' : update.plan_price}.` : ''}`,
        update
      );
      return json(200, { success: true, data: result });
    }

    if (action === 'updatePlanCatalog') {
      const code = cleanText(payload.code, 20).toLowerCase();
      if (!['free', 'pro'].includes(code)) {
        return json(400, { success: false, error: 'code (free/pro) obrigatorio.' });
      }
      const update = {};
      if (payload.name !== undefined) update.name = cleanText(payload.name, 80);
      if (payload.description !== undefined) update.description = cleanText(payload.description, 300) || null;
      if (payload.price_monthly !== undefined) {
        const price = payload.price_monthly === null || payload.price_monthly === ''
          ? null : Number(payload.price_monthly);
        if (price !== null && (!Number.isFinite(price) || price < 0)) {
          return json(400, { success: false, error: 'price_monthly invalido.' });
        }
        update.price_monthly = price;
      }
      if (payload.benefits !== undefined) {
        update.benefits = Array.isArray(payload.benefits)
          ? payload.benefits.map((b) => cleanText(b, 120)).filter(Boolean)
          : [];
      }
      if (payload.active !== undefined) update.active = Boolean(payload.active);
      if (!Object.keys(update).length) return json(400, { success: false, error: 'Nenhum campo valido para atualizar.' });

      const result = await supabaseRequest(`/rest/v1/plans?code=eq.${encodeURIComponent(code)}`, {
        method: 'PATCH',
        body: update,
      });
      await writeAudit(
        'plan_catalog_updated',
        'plans',
        null,
        `Plano ${code} atualizado: ${Object.keys(update).join(', ')}.`,
        { code, ...update }
      );
      return json(200, { success: true, data: result });
    }

    return json(400, { success: false, error: 'Acao admin desconhecida.' });
  } catch (error) {
    console.error('[admin-action]', error.message);
    return json(500, { success: false, error: error.message });
  }
};
