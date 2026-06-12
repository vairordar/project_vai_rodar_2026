const { handler: consultarFipe } = require('./consultar-fipe');

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return consultarFipe({ ...event, httpMethod: 'OPTIONS' });
  if (event.httpMethod !== 'GET') {
    return {
      statusCode: 405,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type',
        'Access-Control-Allow-Methods': 'GET, OPTIONS',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ success: false, error: 'Method not allowed' }),
    };
  }

  const placa = event.queryStringParameters?.placa || '';
  return consultarFipe({
    ...event,
    httpMethod: 'POST',
    body: JSON.stringify({ placa }),
  });
};
