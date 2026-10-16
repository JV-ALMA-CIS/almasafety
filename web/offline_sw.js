// Keeps JVA Safety opening on sites with weak or no signal.
//
// Flutter no longer ships a caching service worker, so this one keeps a copy
// of the app's own files (and the fonts / engine files it loads from Google)
// as they are fetched:
//  - the app's own files: network first, but if the network is slow or gone
//    the saved copy is used straight away while the download carries on and
//    refreshes the copy for next time;
//  - fonts and engine files from gstatic: their URLs carry a version, so a
//    saved copy is used whenever there is one.
// Firebase traffic (data, sign-in, uploads) is never touched — Firestore and
// the app's outbox handle being offline themselves.

const CACHE = 'jva-safety-app-v1';
const SLOW_NETWORK_MS = 4000;
const VERSIONED_HOSTS = ['www.gstatic.com', 'fonts.gstatic.com', 'fonts.googleapis.com'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(['./', 'index.html'])).catch(() => {}),
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      for (const key of await caches.keys()) {
        if (key !== CACHE) await caches.delete(key);
      }
      await self.clients.claim();
    })(),
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);

  if (url.origin === self.location.origin) {
    // The messaging worker looks after itself.
    if (url.pathname.endsWith('firebase-messaging-sw.js')) return;
    event.respondWith(networkFirst(event, request));
    return;
  }
  if (VERSIONED_HOSTS.includes(url.hostname)) {
    event.respondWith(cacheFirst(request));
  }
});

async function networkFirst(event, request) {
  const cache = await caches.open(CACHE);
  const fromNetwork = fetch(request).then(async (response) => {
    if (response && response.ok) await cache.put(request, response.clone());
    return response;
  });
  // Let the download finish (and refresh the copy) even if we answer early.
  event.waitUntil(fromNetwork.catch(() => {}));

  const saved = await cache.match(request, {ignoreSearch: true});
  if (!saved) {
    try {
      return await fromNetwork;
    } catch (e) {
      // A page address the app handles itself: answer with the app.
      if (request.mode === 'navigate') {
        const app = (await cache.match('index.html')) || (await cache.match('./'));
        if (app) return app;
      }
      throw e;
    }
  }
  const slow = new Promise((resolve) => setTimeout(() => resolve(saved), SLOW_NETWORK_MS));
  return Promise.race([fromNetwork.catch(() => saved), slow]);
}

async function cacheFirst(request) {
  const cache = await caches.open(CACHE);
  const saved = await cache.match(request);
  if (saved) return saved;
  const response = await fetch(request);
  if (response && (response.ok || response.type === 'opaque')) {
    await cache.put(request, response.clone());
  }
  return response;
}
