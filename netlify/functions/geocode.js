/**
 * Reverse geocoding: lat/lng → dirección legible.
 *
 * POST /.netlify/functions/geocode
 * Body: { "lat": -23.5505, "lng": -46.6333 }
 *
 * Usa OpenStreetMap Nominatim (gratis, sin API key, pero exige:
 * - User-Agent identificable (requisito de la política de uso de Nominatim)
 * - Rate limit de 1 request/segundo
 * Por eso se centraliza en esta function en vez de llamarlo directo
 * desde el navegador (evita bloqueos de CORS / abuso de la política).
 *
 * No requiere variables de entorno.
 */

const https = require('https');

function jsonResponse(statusCode, body) {
  return {
    statusCode,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Content-Type',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  };
}

function getJson(url, headers) {
  return new Promise((resolve, reject) => {
    const parsedUrl = new URL(url);
    const req = https.request(
      {
        hostname: parsedUrl.hostname,
        path: parsedUrl.pathname + (parsedUrl.search || ''),
        method: 'GET',
        headers,
      },
      (res) => {
        let data = '';
        res.on('data', (chunk) => { data += chunk; });
        res.on('end', () => {
          let parsed;
          try {
            parsed = JSON.parse(data || '{}');
          } catch {
            parsed = { rawText: data };
          }
          resolve({ statusCode: res.statusCode || 500, body: parsed });
        });
      }
    );
    req.on('error', reject);
    req.setTimeout(10000, () => req.destroy(new Error('Timeout na consulta de geocoding')));
    req.end();
  });
}

function isValidCoordinate(lat, lng) {
  return (
    typeof lat === 'number' && typeof lng === 'number' &&
    lat >= -90 && lat <= 90 &&
    lng >= -180 && lng <= 180 &&
    !Number.isNaN(lat) && !Number.isNaN(lng)
  );
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return jsonResponse(200, {});
  if (event.httpMethod !== 'POST') return jsonResponse(405, { success: false, error: 'Method not allowed' });

  let payload;
  try {
    payload = JSON.parse(event.body || '{}');
  } catch {
    return jsonResponse(400, { success: false, error: 'Body invalido' });
  }

  const lat = Number(payload.lat ?? payload.latitude);
  const lng = Number(payload.lng ?? payload.longitude);

  if (!isValidCoordinate(lat, lng)) {
    return jsonResponse(400, { success: false, error: 'lat/lng invalidos.' });
  }

  const url = `https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${lat}&lon=${lng}&addressdetails=1&accept-language=pt-BR`;

  try {
    const response = await getJson(url, {
      'User-Agent': 'VaiRodar/1.0 (contato: jds11529@gmail.com)',
      Accept: 'application/json',
    });

    if (response.statusCode >= 400 || response.body.error) {
      return jsonResponse(502, {
        success: false,
        error: 'Erro ao consultar geocoding.',
        details: response.body,
      });
    }

    const addr = response.body.address || {};
    const address = response.body.display_name || '';

    return jsonResponse(200, {
      success: true,
      lat,
      lng,
      address,
      details: {
        street: addr.road || addr.pedestrian || '',
        neighborhood: addr.suburb || addr.neighbourhood || '',
        city: addr.city || addr.town || addr.village || addr.municipality || '',
        state: addr.state || '',
        postcode: addr.postcode || '',
        country: addr.country || '',
      },
    });
  } catch (error) {
    return jsonResponse(502, {
      success: false,
      error: error.message || 'Erro ao consultar geocoding',
    });
  }
};
