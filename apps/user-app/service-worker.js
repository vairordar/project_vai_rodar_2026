const CACHE_NAME = 'vai-rodar-mvp-v2-20260804-icon-v3';
const STATIC_ASSETS = [
  '/manifest.json',
  '/assets/vai_rodar_logo_transparent.png',
  '/assets/icon-192x192.png',
  '/assets/icon-512x512.png'
];

// Install: pré-cacheia os assets estáticos
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => {
      return Promise.all(
        STATIC_ASSETS.map(asset => cache.add(asset).catch(() => null))
      );
    }).then(() => self.skipWaiting())
  );
});

// Activate: remove caches antigos
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))
      )
    ).then(() => self.clients.claim())
  );
});

// Fetch: cache-first para assets estáticos, network-first para API
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);

  // Ignora requests não-GET e do Supabase/OpenAI
  if (event.request.method !== 'GET') return;
  if (url.hostname.includes('supabase.co')) return;
  if (url.hostname.includes('openai.com')) return;
  if (url.hostname.includes('netlify.app') && url.pathname.startsWith('/.netlify/functions')) return;

  // Cache-first para fontes e assets locais
  if (
    url.hostname.includes('fonts.googleapis.com') ||
    url.hostname.includes('fonts.gstatic.com') ||
    url.hostname.includes('pexels.com') ||
    url.pathname.startsWith('/assets/')
  ) {
    event.respondWith(
      caches.match(event.request).then(cached => {
        if (cached) return cached;
        return fetch(event.request).then(response => {
          if (!response || response.status !== 200) return response;
          const clone = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone));
          return response;
        });
      })
    );
    return;
  }

  // Network-first com fallback para cache (para o index.html e páginas)
  event.respondWith(
    fetch(event.request)
      .then(response => {
        if (response && response.status === 200) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone));
        }
        return response;
      })
      .catch(() => caches.match(event.request).then(cached => {
        if (cached) return cached;
        // Fallback para index.html (SPA)
        return caches.match('/index.html');
      }))
  );
});

// Push notifications (para OneSignal futuro)
self.addEventListener('push', event => {
  if (!event.data) return;
  const data = event.data.json();
  event.waitUntil(
    self.registration.showNotification(data.title || 'Vai Rodar', {
      body: data.body || '',
      icon: '/assets/vai_rodar_logo_transparent.png',
      badge: '/assets/vai_rodar_logo_transparent.png',
      data: data.url || '/'
    })
  );
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil(
    clients.openWindow(event.notification.data || '/')
  );
});
