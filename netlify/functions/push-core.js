const webpush = require('web-push');
const { supabaseRequest } = require('./admin-common');

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

async function sendPushToUser(userId, { title, body, url } = {}) {
  if (!userId) return { sent: 0, failed: 0 };
  try {
    assertPushConfig();
  } catch (error) {
    console.warn('[push-core] config:', error.message);
    return { sent: 0, failed: 0 };
  }

  let subscriptions = [];
  try {
    subscriptions = await supabaseRequest(
      `/rest/v1/push_subscriptions?user_id=eq.${encodeURIComponent(userId)}&active=eq.true&select=id,subscription`
    );
  } catch (error) {
    console.warn('[push-core] fetch subscriptions:', error.message);
    return { sent: 0, failed: 0 };
  }

  if (!Array.isArray(subscriptions) || !subscriptions.length) return { sent: 0, failed: 0 };

  const notification = {
    title: String(title || 'Vai Rodar').slice(0, 80),
    body: String(body || '').slice(0, 180),
    url: String(url || '/').slice(0, 300),
  };

  const results = await Promise.allSettled(subscriptions.map(async (row) => {
    try {
      await webpush.sendNotification(row.subscription, JSON.stringify(notification));
      return { id: row.id, ok: true };
    } catch (error) {
      if (error.statusCode === 404 || error.statusCode === 410) await markInactive(row.id);
      throw error;
    }
  }));

  return {
    sent: results.filter((item) => item.status === 'fulfilled').length,
    failed: results.filter((item) => item.status === 'rejected').length,
  };
}

module.exports = { sendPushToUser };
