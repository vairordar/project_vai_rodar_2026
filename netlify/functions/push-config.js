const { json } = require('./admin-common');

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return json(200, {});
  if (event.httpMethod !== 'GET') return json(405, { error: 'Method Not Allowed' });
  const publicKey = process.env.VAPID_PUBLIC_KEY || '';
  return json(200, { enabled: Boolean(publicKey), publicKey });
};
