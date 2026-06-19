const https = require('https');
const { json, supabaseRequest } = require('./admin-common');
const { sendPushToUser } = require('./push-core');

// Notifica eventos reais de proposta (criada / aceita / recusada) e de mensagens de chat:
// 1. Insere uma linha real em public.notifications (a campainha do user-app le essa tabela).
// 2. Envia push web (celular) para o destinatario, via push-core (usa as mesmas
//    VAPID keys/secrets que ja existem so no Netlify, nunca no frontend).
//
// Autenticacao: igual ao push-subscribe.js - o proprio token de sessao do usuario que
// disparou o evento (motorista ou taller), sem precisar de ADMIN_PASSWORD nem de
// segredo interno. O destinatario e' resolvido no servidor (com a service role key) e
// validamos que quem chamou realmente e' uma das partes (da proposta ou da conversa),
// para que ninguem possa forjar notificacoes para outros usuarios.

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
        link: '/',
      });
      const push = await sendPushToUser(recipientId, {
        title: `Nova mensagem de ${senderName}`,
        body: text,
        url: '/',
      });
      return json(200, { ok: true, push });
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
      await insertNotification({
        userId: driverId,
        type: 'quote',
        title: 'Nova proposta recebida',
        detail: `${workshopName} respondeu: ${requestTitle} (${priceText}).`,
        link: '/',
      });
      const push = await sendPushToUser(driverId, {
        title: 'Nova proposta recebida',
        body: `${workshopName} respondeu sua solicitacao: ${requestTitle}.`,
        url: '/',
      });
      return json(200, { ok: true, push });
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
      return json(200, { ok: true, push });
    }

    return json(400, { error: 'Evento desconhecido.' });
  } catch (error) {
    console.error('[notify-event]', error.message);
    return json(500, { error: 'Nao foi possivel enviar a notificacao.', detail: error.message });
  }
};
