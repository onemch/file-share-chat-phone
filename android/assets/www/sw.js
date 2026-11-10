/* 只离线缓存界面壳；API、跨主机请求、WebSocket 一律直连，不缓存 */
const CACHE = 'fsc-phone-v3';
const SHELL = [
  '/', '/static/style.css', '/static/app.js',
  '/static/qrcode.min.js', '/static/jsqr.min.js',
  '/manifest.webmanifest', '/icon-192.png',
];
const API_PREFIX = [
  '/health', '/files', '/upload', '/download', '/delete',
  '/clear-download', '/preview', '/qr.png', '/chat',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE)
      .then((cache) => cache.addAll(SHELL))
      .catch(() => {})
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  let url;
  try { url = new URL(req.url); } catch (e) { return; }
  // 切换到其他主机后的跨域 API：交给浏览器直接发，绝不缓存
  if (url.origin !== self.location.origin) return;
  if (API_PREFIX.some((p) => url.pathname.startsWith(p))) return;

  // 界面壳与脚本一律 network-first：保证改版后刷新就能拿到新代码，
  // 离线时才回退缓存。API 与跨主机请求始终直连，不缓存。
  if (url.pathname === '/' || SHELL.includes(url.pathname)) {
    const key = url.pathname === '/' ? '/' : req;
    event.respondWith(
      fetch(req).then((res) => {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(key, copy)).catch(() => {});
        return res;
      }).catch(() => caches.match(key))
    );
  }
});
