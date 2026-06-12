/**
 * consulta-placa.js — Netlify Function
 * Proxy seguro para API Brasil (gateway.apibrasil.io)
 *
 * GET /.netlify/functions/consulta-placa?placa=ABC1D23
 * Returns: { plate, brand, model, year, color, fuel, city, state }
 *
 * Variáveis de ambiente no Netlify:
 *   PLACA_BEARER_TOKEN  →  BearerToken da API Brasil
 *   PLACA_DEVICE_TOKEN  →  DeviceToken da API Brasil
 */

const https = require('https');

const BEARER_TOKEN = process.env.PLACA_BEARER_TOKEN;
const DEVICE_TOKEN = process.env.PLACA_DEVICE_TOKEN;

function jsonResponse(statusCode, body) {
  return {
    statusCode,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Content-Type',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  };
}

function normalizePlate(value) {
  return String(value || '').trim().toUpperCase().replace(/[^A-Z0-9]/g, '');
}

function isValidPlate(plate) {
  return /^[A-Z]{3}[0-9][A-Z][0-9]{2}$/.test(plate) || /^[A-Z]{3}[0-9]{4}$/.test(plate);
}

function fetchPlate(plate, bearerToken, deviceToken) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ placa: plate });
    const req = https.request(
      {
        hostname: 'gateway.apibrasil.io',
        path: '/api/v2/vehicles/dados',
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${bearerToken}`,
          DeviceToken: deviceToken,
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (chunk) => {
          data += chunk;
        });
        res.on('end', () => {
          try {
            const parsed = JSON.parse(data || '{}');
            if (res.statusCode >= 400) {
              reject(new Error(parsed.error || parsed.message || `status ${res.statusCode}`));
              return;
            }
            resolve(parsed);
          } catch {
            reject(new Error('Resposta inválida da API Brasil'));
          }
        });
      }
    );

    req.on('error', reject);
    req.setTimeout(10000, () => {
      req.destroy(new Error('Consulta de placa timeout'));
    });
    req.write(body);
    req.end();
  });
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return jsonResponse(200, {});
  if (event.httpMethod !== 'GET') return jsonResponse(405, { error: 'Method Not Allowed' });

  const plate = normalizePlate(event.queryStringParameters?.placa);
  if (!isValidPlate(plate)) return jsonResponse(400, { error: 'Placa inválida.' });

  if (!BEARER_TOKEN || !DEVICE_TOKEN) {
    return jsonResponse(500, { error: 'PLACA_BEARER_TOKEN ou PLACA_DEVICE_TOKEN não configurados no Netlify.' });
  }

  try {
    const raw = await fetchPlate(plate, BEARER_TOKEN, DEVICE_TOKEN);

    if (raw.error || !raw.MARCA) {
      return jsonResponse(404, { error: raw.error || raw.message || 'Placa não encontrada.' });
    }

    return jsonResponse(200, {
      plate,
      brand: raw.MARCA || '—',
      model: raw.MODELO || '—',
      year: raw.ano || raw.ANO_MODELO || '—',
      color: raw.COR || '—',
      fuel: raw.COMBUSTIVEL || '—',
      city: raw.MUNICIPIO || '',
      state: raw.UF || '',
    });
  } catch (err) {
    console.error('[consulta-placa] Erro:', err.message);
    return jsonResponse(502, { error: 'Erro ao consultar placa.' });
  }
};
