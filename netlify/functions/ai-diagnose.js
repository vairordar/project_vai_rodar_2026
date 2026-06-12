/**
 * ai-diagnose.js — Netlify Function
 * Proxy seguro para OpenAI GPT-4o mini.
 * La API key nunca sale al frontend.
 *
 * POST /.netlify/functions/ai-diagnose
 * Body: { message: string, conversation: [{user, assistant}] }
 * Returns: { intent, title, text, categories, action }
 */

const https = require('https');

const CATEGORIES = [
  'Revisão geral / Manutenção preventiva',
  'Troca de óleo e filtros',
  'Freios e suspensão',
  'Motor e transmissão',
  'Elétrica automotiva',
  'Ar-condicionado',
  'Funilaria e pintura',
  'Pneus e alinhamento',
  'Diagnóstico computadorizado',
  'Vidros e acessórios',
  'Blindagem',
];

const INTENTS = new Set(['serviceQuote', 'partQuote', 'buy', 'sell', 'value', 'offers']);
const OPENAI_API_KEY = process.env.OPENAI_API_KEY_VR || process.env.OPENAI_API_KEY;

const SYSTEM_PROMPT = `Você é o assistente de diagnóstico automotivo do Vai Rodar, um app brasileiro que conecta motoristas a oficinas.

Seu trabalho é entender o problema do motorista e retornar um JSON estruturado em português do Brasil.

Regras:
- Responda SEMPRE com JSON válido, sem texto fora do JSON.
- O campo "text" deve ser direto, empático e útil — máximo 2 frases curtas.
- O campo "categories" deve conter entre 1 e 3 das categorias permitidas.
- Se o motorista está descrevendo um sintoma, sugira categorias relacionadas.
- Se o motorista quer comprar carro, use intent "buy".
- Se quer vender carro, use intent "sell".
- Se quer avaliar o valor do carro, use intent "value".
- Se quer peças, use intent "partQuote".
- Se quer promoções/eventos, use intent "offers".
- Para qualquer problema mecânico ou serviço, use intent "serviceQuote".

Categorias permitidas (use exatamente esses nomes):
- "Revisão geral / Manutenção preventiva"
- "Troca de óleo e filtros"
- "Freios e suspensão"
- "Motor e transmissão"
- "Elétrica automotiva"
- "Ar-condicionado"
- "Funilaria e pintura"
- "Pneus e alinhamento"
- "Diagnóstico computadorizado"
- "Vidros e acessórios"
- "Blindagem"

Formato de resposta obrigatório:
{
  "intent": "serviceQuote",
  "title": "Frase curta descrevendo o que foi entendido",
  "text": "Resposta empática e útil em até 2 frases",
  "categories": ["Categoria 1", "Categoria 2"],
  "action": "Texto do botão de ação"
}`;

function callOpenAI(messages) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      model: process.env.OPENAI_MODEL || 'gpt-4o-mini',
      messages,
      temperature: 0.3,
      max_tokens: 300,
      response_format: { type: 'json_object' },
    });

    const req = https.request(
      {
        hostname: 'api.openai.com',
        path: '/v1/chat/completions',
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${OPENAI_API_KEY}`,
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => {
          try {
            const parsed = JSON.parse(data);
            if (parsed.error) return reject(new Error(parsed.error.message));
            resolve(parsed);
          } catch (e) {
            reject(e);
          }
        });
      }
    );
    req.on('error', reject);
    req.setTimeout(15000, () => {
      req.destroy(new Error('OpenAI timeout'));
    });
    req.write(body);
    req.end();
  });
}

function jsonResponse(statusCode, body) {
  return {
    statusCode,
    headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
    },
    body: JSON.stringify(body),
  };
}

function cleanText(value, maxLength) {
  return String(value || '').trim().slice(0, maxLength);
}

function sanitizeConversation(conversation) {
  if (!Array.isArray(conversation)) return [];
  return conversation.slice(-6).flatMap((turn) => {
    const user = cleanText(turn?.user, 800);
    const assistant = cleanText(turn?.assistant, 800);
    const messages = [];
    if (user) messages.push({ role: 'user', content: user });
    if (assistant) messages.push({ role: 'assistant', content: assistant });
    return messages;
  });
}

function sanitizeResult(result) {
  const intent = INTENTS.has(result.intent) ? result.intent : 'serviceQuote';
  const categories = Array.isArray(result.categories)
    ? result.categories.filter((category) => CATEGORIES.includes(category)).slice(0, 3)
    : [];

  return {
    intent,
    title: cleanText(result.title, 90) || 'Entendi seu problema.',
    text: cleanText(result.text, 280) || 'Posso organizar isso como uma solicitação para oficinas próximas.',
    categories,
    action: cleanText(result.action, 80) || (intent === 'partQuote' ? 'Enviar solicitação de peça' : 'Enviar solicitação a oficinas'),
  };
}

exports.handler = async (event) => {
  // CORS preflight
  if (event.httpMethod === 'OPTIONS') {
    return {
      statusCode: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
      },
      body: '',
    };
  }

  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method Not Allowed' };
  }

  if (!OPENAI_API_KEY) {
    return jsonResponse(500, { error: 'OPENAI_API_KEY_VR não configurada no Netlify.' });
  }

  let message, conversation;
  try {
    ({ message, conversation = [] } = JSON.parse(event.body));
  } catch {
    return jsonResponse(400, { error: 'Body inválido' });
  }

  if (!message || typeof message !== 'string') {
    return jsonResponse(400, { error: 'Campo "message" obrigatório' });
  }

  const cleanMessage = cleanText(message, 1200);

  const messages = [
    { role: 'system', content: SYSTEM_PROMPT },
    ...sanitizeConversation(conversation),
    { role: 'user', content: cleanMessage },
  ];

  try {
    const openaiRes = await callOpenAI(messages);
    const raw = openaiRes.choices?.[0]?.message?.content || '{}';
    const result = JSON.parse(raw);
    return jsonResponse(200, sanitizeResult(result));
  } catch (err) {
    console.error('OpenAI error:', err.message);
    return jsonResponse(502, { error: 'Erro ao chamar OpenAI', details: err.message });
  }
};
