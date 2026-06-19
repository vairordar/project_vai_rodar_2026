const { authorize, json } = require('./admin-common');
const { sendPushToUser } = require('./push-core');

function authorizeRequest(event) {
  if (authorize(event)) return true;
  const internalSecret = process.env.INTERNAL_PUSH_SECRET;
  if (!internalSecret) return false;
  const headers = event.headers || {};
  const provided = headers['x-internal-push-secret'] || headers['X-Internal-Push-Secret'] || '';
  return provided === internalSecret;
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return json(200, {});
  if (event.httpMethod !== 'POST') return json(405, { error: 'Method Not Allowed' });
  if (!authorizeRequest(event)) return json(401, { error: 'Nao autorizado.' });

  try {
    const payload = JSON.parse(event.body || '{}');
    const userId = String(payload.user_id || payload.userId || '').trim();
    if (!userId) return json(400, { error: 'user_id obrigatorio.' });

    const result = await sendPushToUser(userId, {
      title: payload.title,
      body: payload.body,
      url: payload.url,
    });

    return json(200, { ok: true, ...result });
  } catch (error) {
    console.error('[send-push]', error.message);
    return json(500, { error: 'Nao foi possivel enviar push.', detail: error.message });
  }
};
