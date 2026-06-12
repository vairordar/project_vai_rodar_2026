/**
 * Proxy seguro para consultar datos basicos de vehiculo por placa.
 *
 * GET /.netlify/functions/consulta-placa?placa=ABC1D23
 *
 * Variables de entorno:
 * - PLACA_API_KEY: chave da FIPE API (fipeapi.com.br)
 */

const https = require('https');

const PLATE_API_KEY = process.env.PLACA_API_KEY || process.env.PLACA_API_KEY_VR;

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

function fetchPlate(plate, apiKey) {
  return new Promise((resolve, reject) => {
    const path = `/placas/${encodeURIComponent(plate)}?key=${encodeURIComponent(apiKey)}`;
    const req = https.request(
      {
        hostname: 'placas.fipeapi.com.br',
        path,
        method: 'GET',
        headers: { Accept: 'application/json' },
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
            reject(new Error('Resposta invalida da API de placas'));
          }
        });
      }
    );

    req.on('error', reject);
    req.setTimeout(10000, () => {
      req.destroy(new Error('Consulta de placa timeout'));
    });
    req.end();
  });
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return jsonResponse(200, {});
  if (event.httpMethod !== 'GET') return jsonResponse(405, { error: 'Method Not Allowed' });

  const plate = normalizePlate(event.queryStringParameters?.placa);
  if (!isValidPlate(plate)) return jsonResponse(400, { error: 'Placa invalida.' });
  if (!PLATE_API_KEY) return jsonResponse(500, { error: 'PLACA_API_KEY não configurada no Netlify.' });

  try {
    const raw = await fetchPlate(plate, PLATE_API_KEY);

    if (raw.error || (raw.message && !raw.marca)) {
      return jsonResponse(404, { error: raw.error || raw.message || 'Placa não encontrada.' });
    }

    return jsonResponse(200, {
      plate,
      brand: raw.marca || '—',
      model: raw.modelo || '—',
      year: raw.anoModelo || raw.anoFabricacao || '—',
      color: raw.cor || '—',
      fuel: raw.combustivel || '—',
      city: raw.municipio || '',
      state: raw.uf || '',
    });
  } catch (err) {
    console.error('[consulta-placa] Erro:', err.message);
    return jsonResponse(502, { error: 'Erro ao consultar placa.', details: err.message });
  }
};
