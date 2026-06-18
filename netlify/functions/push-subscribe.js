const https = require('https');
const { json, supabaseRequest } = require('./admin-common');

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
        headers: {
          apikey: SUPABASE_ANON_KEY,
          Authorization: `Bearer ${accessToken}`,
        },
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

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return json(200, {});
  if (event.httpMethod !== 'POST') return json(405, { error: 'Method Not Allowed' });

  try {
    const accessToken = getBearer(event);
    if (!accessToken) return json(401, { error: 'Sessao obrigatoria.' });

    const user = await getUser(accessToken);
    const payload = JSON.parse(event.body || '{}');
    const subscription = payload.subscription || {};
    if (!subscription.endpoint || !subscription.keys?.p256dh || !subscription.keys?.auth) {
      return json(400, { error: 'Push subscription invalida.' });
    }

    const endpoint = String(subscription.endpoint);
    await supabaseRequest('/rest/v1/push_subscriptions?on_conflict=endpoint', {
      method: 'POST',
      prefer: 'resolution=merge-duplicates,return=representation',
      body: {
        user_id: user.id,
        endpoint,
        subscription,
        user_agent: String(payload.userAgent || '').slice(0, 500),
        platform: String(payload.platform || 'web').slice(0, 40),
        active: true,
        updated_at: new Date().toISOString(),
      },
    });

    return json(200, { ok: true });
  } catch (error) {
    console.error('[push-subscribe]', error.message);
    return json(500, { error: 'Nao foi possivel ativar notificacoes push.', detail: error.message });
  }
};
