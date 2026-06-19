/**
 * Consulta FIPE Beta por placa usando APIBrasil.
 *
 * POST /.netlify/functions/consultar-fipe
 * Body: { "placa": "ABC1234" }
 *
 * Variaveis de ambiente (Netlify):
 * - APIBRASIL_BEARER_TOKEN  (Authorization: Bearer ...)
 * - APIBRASIL_DEVICE_TOKEN  (opcional; FIPE Beta muestra solo Authorization en la doc actual)
 * - APIBRASIL_HOMOLOG: "true" para homologacao, "false" para consumir creditos reais
 *
 * Endpoint confirmado en doc.apibrasil.io (19/06/2026): a API "Fipe (Beta)"
 * usa a rota consulta/veiculos/credits sob a Base URL gateway.apibrasil.io/api/v2.
 * A rota antiga vehicles/dados retornava 404 "Plano ativo nao encontrado".
 */

const https = require('https');

const API_URL = 'https://gateway.apibrasil.io/api/v2/consulta/veiculos/credits';
const BEARER_TOKEN = process.env.APIBRASIL_BEARER_TOKEN;
const DEVICE_TOKEN = process.env.APIBRASIL_DEVICE_TOKEN;
const HOMOLOG = String(process.env.APIBRASIL_HOMOLOG || 'false').toLowerCase() === 'true';

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

function normalizePlate(value) {
  return String(value || '').trim().toUpperCase().replace(/[^A-Z0-9]/g, '');
}

function isValidPlate(plate) {
  return /^[A-Z]{3}[0-9][A-Z][0-9]{2}$/.test(plate) || /^[A-Z]{3}[0-9]{4}$/.test(plate);
}

function postJson(url, body, token, deviceToken) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const parsedUrl = new URL(url);
    const req = https.request(
      {
        hostname: parsedUrl.hostname,
        path: parsedUrl.pathname,
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          ...(deviceToken ? { DeviceToken: deviceToken } : {}),
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (chunk) => {
          data += chunk;
        });
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
    req.setTimeout(15000, () => {
      req.destroy(new Error('Timeout na consulta APIBrasil'));
    });
    req.write(payload);
    req.end();
  });
}

function findFirstDeep(value, keys) {
  const normalizedKeys = keys.map((key) => key.toLowerCase());
  const seen = new Set();

  function visit(node) {
    if (!node || typeof node !== 'object' || seen.has(node)) return '';
    seen.add(node);

    for (const [key, child] of Object.entries(node)) {
      if (normalizedKeys.includes(key.toLowerCase()) && child !== null && child !== undefined && child !== '') {
        return String(child);
      }
    }

    for (const child of Object.values(node)) {
      const found = visit(child);
      if (found) return found;
    }
    return '';
  }

  return visit(value);
}

function extractVehicle(raw, plate) {
  const marca = findFirstDeep(raw, ['marca', 'MARCA', 'brand']);
  const modelo = findFirstDeep(raw, ['modelo', 'MODELO', 'model']);
  const ano = findFirstDeep(raw, ['ano', 'ANO', 'anoModelo', 'ANO_MODELO', 'ano_modelo', 'year']);
  const codigoFipe = findFirstDeep(raw, ['codigo_fipe', 'codigoFipe', 'CODIGO_FIPE', 'cod_fipe', 'codigo']);
  const valorFipe = findFirstDeep(raw, ['valor', 'VALOR', 'valor_fipe', 'valorFipe', 'VALOR_FIPE', 'preco', 'precoFipe']);
  const mesReferencia = findFirstDeep(raw, ['mes_referencia', 'mesReferencia', 'MES_REFERENCIA', 'referencia']);
  const linkConsulta = findFirstDeep(raw, ['link', 'url', 'linkConsulta', 'LINK_CONSULTA']);
  const cor = findFirstDeep(raw, ['cor', 'COR', 'color']);
  const combustivel = findFirstDeep(raw, ['combustivel', 'COMBUSTIVEL', 'fuel']);
  const municipio = findFirstDeep(raw, ['municipio', 'MUNICIPIO', 'city']);
  const uf = findFirstDeep(raw, ['uf', 'UF', 'state']);

  return {
    placa: plate,
    marca: marca || 'â€”',
    modelo: modelo || 'â€”',
    ano: ano || 'â€”',
    codigoFipe: codigoFipe || '',
    valorFipe: valorFipe || 'â€”',
    mesReferencia: mesReferencia || '',
    linkConsulta: linkConsulta || '',
    cor: cor || 'â€”',
    combustivel: combustivel || '',
    municipio: municipio || '',
    uf: uf || '',
    plate,
    brand: marca || 'â€”',
    model: modelo || 'â€”',
    year: ano || 'â€”',
    color: cor || 'â€”',
    valueFipe: valorFipe || 'â€”',
    fuel: combustivel || '',
    city: municipio || '',
    state: uf || '',
  };
}

function isInsufficientBalance(data) {
  const text = JSON.stringify(data || {}).toLowerCase();
  return text.includes('saldo') || text.includes('crÃ©dito') || text.includes('credito') || text.includes('balance');
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

  const plate = normalizePlate(payload.placa || payload.plate);
  if (!plate) return jsonResponse(400, { success: false, error: 'Placa vazia.' });
  if (!isValidPlate(plate)) {
    return jsonResponse(400, { success: false, error: 'Placa invalida. Use formato ABC1234 ou ABC1D23.' });
  }

  if (!BEARER_TOKEN) {
    return jsonResponse(500, { success: false, error: 'APIBRASIL_BEARER_TOKEN not configured' });
  }
  try {
    const apiResponse = await postJson(
      API_URL,
      {
        tipo: 'fipe',
        placa: plate,
        homolog: HOMOLOG,
      },
      BEARER_TOKEN,
      DEVICE_TOKEN
    );

    const data = apiResponse.body;
    if (apiResponse.statusCode >= 400 || data.error || data.success === false) {
      return jsonResponse(apiResponse.statusCode >= 400 ? apiResponse.statusCode : 502, {
        success: false,
        error: isInsufficientBalance(data) ? 'Saldo insuficiente na APIBrasil.' : 'Erro na consulta APIBrasil',
        status: apiResponse.statusCode,
        details: data,
      });
    }

    const vehicle = extractVehicle(data, plate);
    const hasUsefulData = [vehicle.marca, vehicle.modelo, vehicle.valorFipe].some((item) => item && item !== 'â€”');
    if (!hasUsefulData) {
      return jsonResponse(404, { success: false, error: 'Resposta sem dados FIPE.', raw: data });
    }

    return jsonResponse(200, {
      success: true,
      placa: plate,
      vehicle,
      raw: data,
    });
  } catch (error) {
    return jsonResponse(502, {
      success: false,
      error: error.message || 'Erro ao consultar APIBrasil',
    });
  }
};

