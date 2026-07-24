const https = require('https');
const { authorize, corsHeaders, json } = require('./admin-common');

const TOKEN = process.env.WHATSAPP_TOKEN || '';
const PHONE_NUMBER_ID = process.env.WHATSAPP_PHONE_NUMBER_ID || '';
const GRAPH_VERSION = process.env.WHATSAPP_GRAPH_VERSION || 'v25.0';

function graphRequest(path) {
  return new Promise((resolve, reject) => {
    const request = https.request({
      hostname: 'graph.facebook.com',
      path: `/${GRAPH_VERSION}/${path}`,
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    }, (response) => {
      let raw = '';
      response.on('data', (chunk) => (raw += chunk));
      response.on('end', () => {
        let parsed = {};
        try { parsed = raw ? JSON.parse(raw) : {}; } catch { parsed = {}; }
        if (response.statusCode >= 400) {
          reject(new Error(parsed?.error?.message || `Meta ${response.statusCode}`));
          return;
        }
        resolve(parsed);
      });
    });
    request.on('error', reject);
    request.setTimeout(15000, () => request.destroy(new Error('Meta timeout')));
    request.end();
  });
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 200, headers: corsHeaders, body: '' };
  if (event.httpMethod !== 'GET') return json(405, { success: false, error: 'Method not allowed' });
  if (!authorize(event)) return json(401, { success: false, error: 'Senha admin invalida.' });

  try {
    if (!TOKEN || !PHONE_NUMBER_ID) {
      return json(503, { success: false, error: 'WhatsApp nao configurado no Netlify.' });
    }
    const phone = await graphRequest(
      `${PHONE_NUMBER_ID}?fields=id,display_phone_number,verified_name,quality_rating,code_verification_status`
    );
    return json(200, {
      success: true,
      data: {
        connected: true,
        phone_number_id: phone.id,
        display_phone_number: phone.display_phone_number,
        verified_name: phone.verified_name,
        quality_rating: phone.quality_rating,
        verification_status: phone.code_verification_status,
        waba_configured: Boolean(process.env.WHATSAPP_BUSINESS_ACCOUNT_ID),
        graph_version: GRAPH_VERSION,
      },
    });
  } catch (error) {
    return json(422, { success: false, error: error.message, connected: false });
  }
};
