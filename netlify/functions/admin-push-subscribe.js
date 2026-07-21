const { authorize, json, supabaseRequest } = require('./admin-common');

function cleanText(value, max = 500) {
  return String(value || '').trim().slice(0, max);
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return json(200, {});
  if (event.httpMethod !== 'POST') return json(405, { success: false, error: 'Method Not Allowed' });

  try {
    if (!authorize(event)) return json(401, { success: false, error: 'Senha admin invalida.' });
    const payload = JSON.parse(event.body || '{}');
    const subscription = payload.subscription || {};
    const endpoint = cleanText(subscription.endpoint, 2000);
    const p256dh = cleanText(subscription.keys?.p256dh, 1000);
    const auth = cleanText(subscription.keys?.auth, 1000);
    if (!endpoint || !p256dh || !auth) {
      return json(400, { success: false, error: 'Inscricao push invalida.' });
    }

    await supabaseRequest('/rest/v1/admin_push_subscriptions?on_conflict=endpoint', {
      method: 'POST',
      prefer: 'resolution=merge-duplicates,return=minimal',
      body: {
        endpoint,
        subscription: { endpoint, expirationTime: subscription.expirationTime || null, keys: { p256dh, auth } },
        user_agent: cleanText(payload.userAgent, 500),
        platform: cleanText(payload.platform, 40) || 'web',
        active: true,
        updated_at: new Date().toISOString(),
      },
    });

    return json(200, { success: true });
  } catch (error) {
    console.error('[admin-push-subscribe]', error.message);
    return json(500, { success: false, error: 'Nao foi possivel ativar as notificacoes do admin.', detail: error.message });
  }
};
