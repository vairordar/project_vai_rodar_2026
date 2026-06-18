const webpush = require('web-push');
const { authorize, json, supabaseRequest } = require('./admin-common');

function assertPushConfig() {
  const publicKey = process.env.VAPID_PUBLIC_KEY;
  const privateKey = process.env.VAPID_PRIVATE_KEY;
  if (!publicKey || !privateKey) throw new Error('VAPID_PUBLIC_KEY/VAPID_PRIVATE_KEY nao configuradas.');
  webpush.setVapidDetails(
    process.env.VAPID_SUBJECT || 'mailto:vairodarbr@gmail.com',
    publicKey,
    privateKey
  );
}

async function markInactive(id) {
  if (!id) return;
  await supabaseRequest(`/rest/v1/push_subscriptions?id=eq.${encodeURIComponent(id)}`, {
    method: 'PATCH',
    body: { active: false, updated_at: new Date().toISOString() },
  }).catch(() => null);
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return json(200, {});
  if (event.httpMethod !== 'POST') return json(405, { error: 'Method Not Allowed' });
  if (!authorize(event)) return json(401, { error: 'Nao autorizado.' });

  try {
    assertPushConfig();
    const payload = JSON.parse(event.body || '{}');
    const userId = String(payload.user_id || payload.userId || '').trim();
    if (!userId) return json(400, { error: 'user_id obrigatorio.' });

    const subscriptions = await supabaseRequest(
      `/rest/v1/push_subscriptions?user_id=eq.${encodeURIComponent(userId)}&active=eq.true&select=id,subscription`
    );
    const notification = {
      title: String(payload.title || 'Vai Rodar').slice(0, 80),
      body: String(payload.body || '').slice(0, 180),
      url: String(payload.url || '/').slice(0, 300),
    };

    const results = await Promise.allSettled((subscriptions || []).map(async (row) => {
      try {
        await webpush.sendNotification(row.subscription, JSON.stringify(notification));
        return { id: row.id, ok: true };
      } catch (error) {
        if (error.statusCode === 404 || error.statusCode === 410) await markInactive(row.id);
        throw error;
      }
    }));

    return json(200, {
      ok: true,
      sent: results.filter((item) => item.status === 'fulfilled').length,
      failed: results.filter((item) => item.status === 'rejected').length,
    });
  } catch (error) {
    console.error('[send-push]', error.message);
    return json(500, { error: 'Nao foi possivel enviar push.', detail: error.message });
  }
};
