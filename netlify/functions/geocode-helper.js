// Limites amplos do territorio brasileiro. Alem de impedir pontos em outros
// continentes, esta validacao detecta o erro comum de latitude/longitude
// invertidas antes que ele chegue ao mapa.
function isBrazilCoordinate(latitude, longitude) {
  return Number.isFinite(latitude)
    && Number.isFinite(longitude)
    && latitude >= -35
    && latitude <= 6
    && longitude >= -75
    && longitude <= -28;
}

function normalizeResult(result, precision) {
  if (!result) return null;
  const latitude = Number(result.lat);
  const longitude = Number(result.lon);
  const countryCode = String(result.address?.country_code || '').toLowerCase();
  if (countryCode && countryCode !== 'br') return null;
  if (!isBrazilCoordinate(latitude, longitude)) return null;
  return {
    latitude,
    longitude,
    precision,
    display_name: String(result.display_name || ''),
  };
}

async function searchNominatim(query, precision) {
  const params = new URLSearchParams({
    format: 'jsonv2',
    limit: '5',
    countrycodes: 'br',
    addressdetails: '1',
    q: query,
  });
  const response = await fetch(`https://nominatim.openstreetmap.org/search?${params.toString()}`, {
    headers: {
      'User-Agent': 'VaiRodar/1.0 (contato@vairodar.com.br)',
      'Accept-Language': 'pt-BR,pt;q=0.9',
    },
  });
  if (!response.ok) return null;
  const results = await response.json();
  if (!Array.isArray(results)) return null;
  for (const result of results) {
    const normalized = normalizeResult(result, precision);
    if (normalized) return normalized;
  }
  return null;
}

// Geocodifica primeiro o endereco completo (incluindo numero) e usa o CEP
// apenas como fallback. Retorna null se nao houver um resultado real no Brasil.
async function geocodeAddress({ address, neighborhood, city, state, cep }) {
  const cleanCep = String(cep || '').replace(/\D/g, '');
  const fullAddress = [address, neighborhood, city, state, cleanCep, 'Brasil'].filter(Boolean).join(', ');
  const streetAddress = [address, city, state, 'Brasil'].filter(Boolean).join(', ');
  const cepAddress = [cleanCep, city, state, 'Brasil'].filter(Boolean).join(', ');
  const queries = [];

  if (address && city) queries.push({ query: fullAddress, precision: 'address' });
  if (streetAddress && streetAddress !== fullAddress) queries.push({ query: streetAddress, precision: 'street' });
  if (cleanCep) queries.push({ query: cepAddress, precision: 'cep' });
  if (!queries.length) return null;

  try {
    for (const item of queries) {
      const result = await searchNominatim(item.query, item.precision);
      if (result) return result;
    }
    return null;
  } catch (error) {
    console.warn('[geocode-helper]', error.message);
    return null;
  }
}

module.exports = { geocodeAddress, isBrazilCoordinate };
