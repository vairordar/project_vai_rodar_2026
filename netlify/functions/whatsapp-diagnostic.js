const crypto = require('crypto');
const { supabaseRequest, json } = require('./admin-common');

const DIAGNOSTIC_TOKEN = process.env.WHATSAPP_VERIFY_TOKEN || '';

function tokenIsValid(value) {
  if (!DIAGNOSTIC_TOKEN || !value) return false;
  const supplied = Buffer.from(String(value));
  const expected = Buffer.from(DIAGNOSTIC_TOKEN);
  return supplied.length === expected.length && crypto.timingSafeEqual(supplied, expected);
}

function maskedPhone(phone) {
  const digits = String(phone || '').replace(/\D/g, '');
  return digits ? `***${digits.slice(-4)}` : '';
}

exports.handler = async (event) => {
  if (event.httpMethod !== 'GET') return json(405, { error: 'Method not allowed' });
  const headers = event.headers || {};
  const token = headers['x-diagnostic-token'] || headers['X-Diagnostic-Token'] || '';
  if (!tokenIsValid(token)) return json(401, { error: 'Unauthorized' });

  try {
    const [contacts, messages] = await Promise.all([
      supabaseRequest(
        '/rest/v1/crm_contacts?select=id,phone,name,source,status,last_message_at,last_message_preview,created_at&order=created_at.desc&limit=20'
      ),
      supabaseRequest(
        '/rest/v1/crm_messages?select=id,contact_id,direction,status,wa_message_id,created_at&order=created_at.desc&limit=30'
      ),
    ]);

    return json(200, {
      contacts: (contacts || []).map((contact) => ({
        ...contact,
        phone: maskedPhone(contact.phone),
      })),
      messages: messages || [],
    });
  } catch (error) {
    return json(500, { error: error.message });
  }
};
