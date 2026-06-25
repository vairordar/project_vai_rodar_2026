/**
 * ai-diagnose.js - Netlify Function
 * Proxy seguro para OpenAI. La API key nunca sale al frontend.
 *
 * POST /.netlify/functions/ai-diagnose
 * Body: { message: string, conversation: [{user, assistant}] }
 * Returns: { intent, title, text, categories, action, technicalSummary, missingQuestions, urgency }
 */

const https = require('https');

const CATEGORIES = [
  'Revisao geral / Manutencao preventiva',
  'Troca de oleo e filtros',
  'Freios e suspensao',
  'Motor e transmissao',
  'Eletrica automotiva',
  'Ar-condicionado',
  'Funilaria e pintura',
  'Pneus e alinhamento',
  'Diagnostico computadorizado',
  'Vidros e acessorios',
  'Blindagem',
];

const CATEGORY_ALIASES = {
  'Revisão geral / Manutenção preventiva': 'Revisao geral / Manutencao preventiva',
  'Troca de óleo e filtros': 'Troca de oleo e filtros',
  'Freios e suspensão': 'Freios e suspensao',
  'Motor e transmissão': 'Motor e transmissao',
  'Elétrica automotiva': 'Eletrica automotiva',
  'Diagnóstico computadorizado': 'Diagnostico computadorizado',
  'Vidros e acessórios': 'Vidros e acessorios',
};

const INTENTS = new Set(['serviceQuote', 'partQuote', 'buy', 'sell', 'value', 'offers']);
const OPENAI_API_KEY = process.env.OPENAI_API_KEY_VR || process.env.OPENAI_API_KEY;

const SYSTEM_PROMPT = `Voce e o assistente tecnico do Vai Rodar, um seletor inteligente para motoristas brasileiros que nao entendem de mecanica.

Objetivo central:
1. Entender o que o motorista escreveu.
2. Explicar de forma simples, sem assustar e sem inventar certeza.
3. Identificar o melhor fluxo: oficina, pecas, comprar carro, vender carro, avaliar carro ou ofertas.
4. Coletar apenas os dados que faltam para reduzir friccao.
5. Preparar um resumo tecnico limpo para oficinas/lojas, separado da resposta simples para o motorista.

Regras de comportamento:
- Responda SEMPRE com JSON valido, sem texto fora do JSON.
- Nao fale muito. Valor aqui e clareza, nao texto longo.
- Nao diagnostique com certeza. Use "pode ser", "e provavel", "vale revisar".
- Se houver risco de seguranca (freio sem funcionar, fumaca, superaquecimento, cheiro queimado, luz de oleo, perda de direcao), marque urgency "high" e recomende evitar rodar.
- Se o usuario quer comprar peca clara (ex: pneu, bateria, pastilha), use intent "partQuote" e peca dado especifico util: medida do pneu, amperagem, dianteiro/traseiro, quantidade, marca preferida.
- Se descreve sintoma (ex: barulho ao virar), priorize intent "serviceQuote", mesmo que mencione uma peca, porque ele pode nao saber a causa.
- Se pergunta "quanto custa X", responda que o preco depende do veiculo/peca/disponibilidade e ofereca cotacao online.
- Enquanto "missingQuestions" nao estiver vazio (ainda coletando informacao), o campo "text" NUNCA deve sugerir uma causa, palpite de diagnostico, nem recomendar ver um mecanico. Nessa fase o texto e so de acolhimento e pedido de info, tipo "Para te ajudar a resolver isso, me conta mais um detalhe:". Nada de "pode ser algo do motor" ou "recomendo levar a um mecanico" antes da hora — isso incomoda o motorista.
- So mencione uma possivel causa/hipotese quando "missingQuestions" estiver vazio (resumo final ja com info suficiente), e mesmo assim com linguagem leve ("pode ser", "vale revisar"), nunca alarmando.
- O campo "text" e para o motorista: simples, ate 3 frases curtas.
- O campo "technicalSummary" e para oficina/loja: objetivo, com sintomas, hipoteses, categoria e dados faltantes. Nao inclua placa/endereco se ainda nao foram fornecidos.
- O campo "missingQuestions" deve ter 0 a 3 perguntas curtas que melhoram a cotacao. Retorne UMA pergunta por vez quando possivel (a primeira mais importante), nao despeje as 3 juntas se a conversa esta comecando.
- O campo "categories" deve conter entre 1 e 3 categorias permitidas.
- Use intent "buy" para comprar carro, "sell" para vender carro, "value" para avaliar carro, "offers" para ofertas/eventos.

Categorias permitidas (use exatamente esses nomes):
- "Revisao geral / Manutencao preventiva"
- "Troca de oleo e filtros"
- "Freios e suspensao"
- "Motor e transmissao"
- "Eletrica automotiva"
- "Ar-condicionado"
- "Funilaria e pintura"
- "Pneus e alinhamento"
- "Diagnostico computadorizado"
- "Vidros e acessorios"
- "Blindagem"

Formato obrigatorio:
{
  "intent": "serviceQuote",
  "title": "Entendi seu problema.",
  "text": "Resposta simples para o motorista.",
  "categories": ["Freios e suspensao", "Pneus e alinhamento"],
  "missingQuestions": ["Acontece ao frear, virar ou passar em buracos?"],
  "technicalSummary": "Cliente relata barulho ao virar a direita. Possiveis areas: suspensao, direcao, roda/rolamento. Solicita diagnostico com preco, prazo e disponibilidade.",
  "urgency": "normal",
  "action": "Pedir cotacao"
}`;

function callOpenAI(messages) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      model: process.env.OPENAI_MODEL || 'gpt-4o-mini',
      messages,
      temperature: 0.2,
      max_tokens: 520,
      response_format: { type: 'json_object' },
    });

    const req = https.request(
      {
        hostname: 'api.openai.com',
        path: '/v1/chat/completions',
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${OPENAI_API_KEY}`,
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
          } catch (error) {
            reject(error);
          }
        });
      }
    );
    req.on('error', reject);
    req.setTimeout(15000, () => req.destroy(new Error('OpenAI timeout')));
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
      'Access-Control-Allow-Headers': 'Content-Type',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
    },
    body: JSON.stringify(body),
  };
}

function cleanText(value, maxLength) {
  return String(value || '').trim().slice(0, maxLength);
}

function sanitizeConversation(conversation) {
  if (!Array.isArray(conversation)) return [];
  return conversation.slice(-8).flatMap((turn) => {
    const user = cleanText(turn?.user, 900);
    const assistant = cleanText(turn?.assistant, 900);
    const messages = [];
    if (user) messages.push({ role: 'user', content: user });
    if (assistant) messages.push({ role: 'assistant', content: assistant });
    return messages;
  });
}

function normalizeCategory(category) {
  const value = cleanText(category, 90);
  return CATEGORY_ALIASES[value] || value;
}

function sanitizeResult(result) {
  const intent = INTENTS.has(result.intent) ? result.intent : 'serviceQuote';
  const categories = Array.isArray(result.categories)
    ? result.categories.map(normalizeCategory).filter((category) => CATEGORIES.includes(category)).slice(0, 3)
    : [];
  const missingQuestions = Array.isArray(result.missingQuestions)
    ? result.missingQuestions.map((item) => cleanText(item, 120)).filter(Boolean).slice(0, 3)
    : [];
  const urgency = ['low', 'normal', 'high'].includes(result.urgency) ? result.urgency : 'normal';

  return {
    intent,
    title: cleanText(result.title, 90) || 'Entendi seu problema.',
    text: cleanText(result.text, 420) || 'Posso organizar isso como uma cotacao para oficinas proximas.',
    categories,
    missingQuestions,
    technicalSummary: cleanText(result.technicalSummary, 700),
    urgency,
    action: cleanText(result.action, 80) || (intent === 'partQuote' ? 'Buscar peca' : 'Pedir cotacao'),
  };
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return jsonResponse(200, {});
  if (event.httpMethod !== 'POST') return { statusCode: 405, body: 'Method Not Allowed' };

  if (!OPENAI_API_KEY) {
    return jsonResponse(500, { error: 'OPENAI_API_KEY_VR nao configurada no Netlify.' });
  }

  let message, conversation;
  try {
    ({ message, conversation = [] } = JSON.parse(event.body || '{}'));
  } catch {
    return jsonResponse(400, { error: 'Body invalido' });
  }

  if (!message || typeof message !== 'string') {
    return jsonResponse(400, { error: 'Campo "message" obrigatorio' });
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
    return jsonResponse(200, sanitizeResult(JSON.parse(raw)));
  } catch (error) {
    console.error('OpenAI error:', error.message);
    return jsonResponse(502, { error: 'Erro ao chamar OpenAI', details: error.message });
  }
};