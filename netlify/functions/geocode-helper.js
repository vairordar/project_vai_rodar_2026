// Geocodifica un endereco brasileiro (rua, bairro, cidade, estado, CEP) em
// latitude/longitude reais usando Nominatim (OpenStreetMap), que e gratuito.
// Retorna null se nao for possivel localizar coordenadas reais - nunca inventa
// uma posicao aproximada/aleatoria.
async function geocodeAddress({ address, neighborhood, city, state, cep }) {
  const cleanCep = String(cep || '').replace(/\D/g, '');
  const parts = [address, neighborhood, city, state, cleanCep, 'Brasil'].filter(Boolean);
  if (!parts.length || (!city && !cleanCep)) return null;

  const query = parts.join(', ');
  const url = `https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=br&q=${encodeURIComponent(query)}`;

  try {
    const response = await fetch(url, {
      headers: { 'User-Agent': 'VaiRodar/1.0 (contato@vairodar.com.br)' },
    });
    if (!response.ok) return null;
    const results = await response.json();
    const first = Array.isArray(results) ? results[0] : null;
    if (!first) return null;
    const latitude = Number(first.lat);
    const longitude = Number(first.lon);
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return null;
    return { latitude, longitude };
  } catch (error) {
    console.warn('[geocode-helper]', error.message);
    return null;
  }
}

module.exports = { geocodeAddress };
