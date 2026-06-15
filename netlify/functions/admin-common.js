const https = require('https');

const SUPABASE_URL = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_KEY;
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Content-Type, X-Admin-Password',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Content-Type': 'application/json',
};

function json(statusCode, body) {
  return { statusCode, headers: corsHeaders, body: JSON.stringify(body) };
}

function assertConfig() {
  if (!SUPABASE_URL) throw new Error('SUPABASE_URL nao configurada no Netlify.');
  if (!SERVICE_ROLE_KEY) throw new Error('SUPABASE_SERVICE_ROLE_KEY nao configurada no Netlify.');
  if (!ADMIN_PASSWORD) throw new Error('ADMIN_PASSWORD nao configurada no Netlify.');
}

function getAdminPassword(event) {
  const headers = event.headers || {};
  return headers['x-admin-password'] || headers['X-Admin-Password'] || headers['X-ADMIN-PASSWORD'] || '';
}

function authorize(event) {
  assertConfig();
  return getAdminPassword(event) === ADMIN_PASSWORD;
}

function supabaseRequest(path, options = {}) {
  return new Promise((resolve, reject) => {
    const body = options.body ? JSON.stringify(options.body) : null;
    const url = new URL(`${SUPABASE_URL}${path}`);
    const req = https.request(
      {
        hostname: url.hostname,
        path: `${url.pathname}${url.search}`,
        method: options.method || 'GET',
        headers: {
          apikey: SERVICE_ROLE_KEY,
          Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
          'Content-Type': 'application/json',
          Prefer: options.prefer || 'return=representation',
          ...(body ? { 'Content-Length': Buffer.byteLength(body) } : {}),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => {
          let parsed = null;
          try { parsed = data ? JSON.parse(data) : null; } catch { parsed = data; }
          if (res.statusCode >= 400) {
            const detail = parsed?.message || parsed?.error || data || `Supabase ${res.statusCode}`;
            reject(new Error(detail));
            return;
          }
          resolve(parsed);
        });
      }
    );
    req.on('error', reject);
    req.setTimeout(15000, () => req.destroy(new Error('Supabase timeout')));
    if (body) req.write(body);
    req.end();
  });
}

module.exports = { authorize, corsHeaders, json, supabaseRequest };
