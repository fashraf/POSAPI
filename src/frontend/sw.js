/*
 * The till's offline shell (QA N17).
 *
 * Without this, a phone with no internet that reopened the app got the
 * WebView's error page and then the app's «Cannot reach the POS» — the till
 * could not even start, though it can sell offline once running (orders queue
 * on the phone and sync later).
 *
 * What it caches, and nothing else:
 *   - the page itself (index.html), network first: online, every start gets
 *     the latest deploy; offline, the last one seen;
 *   - the built files under /assets/ (their names carry a content hash, so a
 *     cached copy is never stale — cache first);
 *   - the Google fonts the page links, so Arabic still looks right offline.
 *
 * Never the API: /api/* is not touched here. Sales, prices and stock are the
 * server's, and the device screens keep their own offline copies (see
 * src/device/state/store.tsx) where they can say how old they are.
 *
 * Registered by the handheld screens (src/device/DeviceApp.tsx) in production
 * builds only.
 */

const SHELL = 'nz-shell-v1';
const ASSETS = 'nz-assets-v1';
const FONTS = 'nz-fonts-v1';
const KEEP = [SHELL, ASSETS, FONTS];

/** The most built files kept; the least recently used go first. */
const MAX_ASSETS = 250;

const INDEX = '/index.html';

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      await cacheIndexAndItsAssets();
      await self.skipWaiting();
    })().catch(() => undefined),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const names = await caches.keys();
      await Promise.all(names.filter((n) => n.startsWith('nz-') && !KEEP.includes(n)).map((n) => caches.delete(n)));
      await self.clients.claim();
    })(),
  );
});

/* The page sends the files it already loaded before this worker controlled
   it (the first start registers the worker after the till's own code has
   been fetched), so they are offline too. */
self.addEventListener('message', (event) => {
  const data = event.data || {};
  if (data.type !== 'cache-urls' || !Array.isArray(data.urls)) return;
  event.waitUntil(
    (async () => {
      const cache = await caches.open(ASSETS);
      for (const url of data.urls) {
        try {
          const u = new URL(url, self.location.origin);
          if (u.origin !== self.location.origin || !u.pathname.startsWith('/assets/')) continue;
          if (await cache.match(u.pathname)) continue;
          const response = await fetch(u.pathname);
          if (response.ok) await cache.put(u.pathname, response);
        } catch {
          /* Tried again on the next start. */
        }
      }
      await trim();
    })(),
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);

  if (url.origin === self.location.origin) {
    /* The API, and anything else that is not the app's own files, goes
       straight to the network as if this worker did not exist. */
    if (url.pathname.startsWith('/api/') || url.pathname === '/api') return;

    if (request.mode === 'navigate') {
      event.respondWith(page(request));
      return;
    }
    if (url.pathname.startsWith('/assets/')) {
      event.respondWith(asset(request, url.pathname));
      return;
    }
    if (url.pathname === '/favicon.svg') {
      event.respondWith(asset(request, url.pathname));
    }
    return;
  }

  if (url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com') {
    event.respondWith(font(request));
  }
});

/** Network first, with a short wait; the cached page when there is no answer. */
async function page(request) {
  const cache = await caches.open(SHELL);
  try {
    const response = await withTimeout(fetch(request), 6000);
    const type = response.headers.get('content-type') || '';
    if (response.ok && type.includes('text/html')) {
      await cache.put(INDEX, response.clone());
      return response;
    }
    /* The server is up but failing (a 502 from the proxy mid-deploy): the
       last good page is more use than its error. */
    if (response.status >= 500) {
      const cached = await cache.match(INDEX);
      if (cached) return cached;
    }
    return response;
  } catch {
    const cached = await cache.match(INDEX);
    if (cached) return cached;
    /* Never loaded online on this phone: nothing to offer. The app shows
       its own offline page for this. */
    return Response.error();
  }
}

/** Cache first: a hashed file never changes. Touched on use, for the trim. */
async function asset(request, key) {
  const cache = await caches.open(ASSETS);
  const cached = await cache.match(key);
  if (cached) {
    /* Re-put moves it to the end of the cache's order: least recently used
       first when trimming. */
    cache.put(key, cached.clone()).catch(() => undefined);
    return cached;
  }
  const response = await fetch(request);
  if (response.ok) {
    await cache.put(key, response.clone());
    trim().catch(() => undefined);
  }
  return response;
}

/** Stale while revalidate. */
async function font(request) {
  const cache = await caches.open(FONTS);
  const cached = await cache.match(request);
  const fresh = fetch(request)
    .then((response) => {
      if (response.ok || response.type === 'opaque') cache.put(request, response.clone()).catch(() => undefined);
      return response;
    })
    .catch(() => cached || Response.error());
  return cached || fresh;
}

async function cacheIndexAndItsAssets() {
  const response = await fetch('/', { cache: 'no-cache' });
  if (!response.ok) return;
  const html = await response.clone().text();
  const shell = await caches.open(SHELL);
  await shell.put(INDEX, response);

  const urls = new Set();
  for (const match of html.matchAll(/(?:src|href)="(\/assets\/[^"]+)"/g)) urls.add(match[1]);
  const assets = await caches.open(ASSETS);
  await Promise.all(
    [...urls].map(async (path) => {
      try {
        const r = await fetch(path);
        if (r.ok) await assets.put(path, r);
      } catch {
        /* Fetched, and cached, when the page asks for it. */
      }
    }),
  );
}

async function trim() {
  const cache = await caches.open(ASSETS);
  const keys = await cache.keys();
  const extra = keys.length - MAX_ASSETS;
  for (let i = 0; i < extra; i++) await cache.delete(keys[i]);
}

function withTimeout(promise, ms) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout')), ms);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}
