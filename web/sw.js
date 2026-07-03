// Cache-first service worker for the GitHub Pages PWAs.
//
// Flutter's generated flutter_service_worker.js is a deprecation tombstone
// that unregisters itself, so without this file every cold open re-negotiates
// every asset against Pages' 10-minute Cache-Control. This worker restores
// the classic behavior: a version-keyed cache, filled at install with the
// boot-critical files and lazily with everything else, served cache-first.
//
// Update model: the VERSION placeholder is stamped with the deploy SHA by
// scripts/finish_pages_build.sh, so every deploy changes this file, the
// browser installs the new worker in the background, and it activates on the
// NEXT launch (no skipWaiting) — a running session never has its cache
// swapped underneath it. The old version's cache is deleted on activation.
//
// index.html only registers this worker off localhost, so local flutter run
// and dev servers never serve stale bundles.
'use strict';

const VERSION = '__SW_VERSION__';
const CACHE_NAME = 'health-pwa-' + VERSION;

// Boot-critical files, precached at install so the second launch after a
// deploy paints without the network. Everything else (assets/, fonts,
// manifest, icons) is cached lazily on first use. Paths are relative to this
// worker's location, i.e. the app's base href.
const CORE = [
  './',
  'flutter_bootstrap.js',
  'flutter.js',
  'main.dart.js',
  'canvaskit/canvaskit.js',
  'canvaskit/canvaskit.wasm',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      // allSettled: a single failed fetch (mid-deploy 404) must not abort the
      // install — missing entries just fall back to the network at runtime.
      Promise.allSettled(CORE.map((url) => cache.add(url)))
    )
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((key) => key.startsWith('health-pwa-') && key !== CACHE_NAME)
            .map((key) => caches.delete(key))
        )
      )
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  // Only same-origin app files. Supabase/API traffic is cross-origin and
  // must always hit the network.
  if (new URL(request.url).origin !== self.location.origin) return;
  // Range requests (media seeking) don't survive cache.put round-trips.
  if (request.headers.has('range')) return;
  event.respondWith(cacheFirst(request));
});

async function cacheFirst(request) {
  const cache = await caches.open(CACHE_NAME);
  // PWA launches can decorate the start URL with query params; the cached
  // entry for './' should still answer them.
  const cached = await cache.match(request, {
    ignoreSearch: request.mode === 'navigate',
  });
  if (cached) return cached;
  const response = await fetch(request);
  if (response.ok && response.type === 'basic') {
    cache.put(request, response.clone());
  }
  return response;
}
