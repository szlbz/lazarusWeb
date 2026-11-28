/* lazarusWeb PWA Service Worker
   规则：静态资源缓存优先；页面导航网络优先；会话 API 一律不走缓存。 */
'use strict';

var LW_SW_URL = new URL(self.location.href);
var LW_VER = LW_SW_URL.searchParams.get('v') || '1';
var LW_CACHE = 'lw-pwa-' + LW_VER;
var LW_SW_BASE = self.location.pathname.replace(/sw\.js$/, '');
var LW_APP_BASE = LW_SW_BASE.replace(/lw\/?$/, '') || '/';
var LW_SHELL = LW_APP_BASE;

var LW_PRECACHE = [
  LW_SHELL,
  LW_SW_BASE + 'lw.css',
  LW_SW_BASE + 'lw.js',
  LW_SW_BASE + 'lw-alpine.css',
  LW_SW_BASE + 'lw-alpine.js',
  LW_SW_BASE + 'manifest.webmanifest',
  LW_SW_BASE + 'icon-192.png'
];

/* 这些路径永远实时请求：会话状态、订阅状态、探针、控制端点 */
function lwBypass(path) {
  return /^\/lw\/(api|ajax|pwa|health|shutdown|captcha)/.test(path) ||
    path.indexOf('/lw/sw.js') >= 0 ||
    path.indexOf('/lw/pwa.js') >= 0;
}

function lwLocalPath(url) {
  var p = url.pathname;
  if (LW_APP_BASE !== '/' && p.indexOf(LW_APP_BASE) === 0)
    p = '/' + p.slice(LW_APP_BASE.length);
  return p;
}

self.addEventListener('install', function (event) {
  event.waitUntil(
    caches.open(LW_CACHE).then(function (cache) {
      return Promise.all(LW_PRECACHE.map(function (u) {
        return cache.add(new Request(u, { cache: 'reload' })).catch(function () {});
      }));
    }).then(function () {
      return self.skipWaiting();
    })
  );
});

self.addEventListener('activate', function (event) {
  event.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(keys.map(function (k) {
        if (k.indexOf('lw-pwa-') === 0 && k !== LW_CACHE) return caches.delete(k);
      }));
    }).then(function () {
      return self.clients.claim();
    })
  );
});

self.addEventListener('fetch', function (event) {
  var req = event.request;
  if (req.method !== 'GET') return;
  var url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  var path = lwLocalPath(url);

  if (lwBypass(path)) return;

  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req).then(function (resp) {
        if (resp && resp.ok) {
          var copy = resp.clone();
          caches.open(LW_CACHE).then(function (c) { c.put(LW_SHELL, copy); });
        }
        return resp;
      }).catch(function () {
        return caches.match(LW_SHELL).then(function (r) {
          return r || new Response('离线，且没有缓存的页面壳', {
            status: 503,
            headers: { 'Content-Type': 'text/plain; charset=utf-8' }
          });
        });
      })
    );
    return;
  }

  if (path.indexOf('/ext/') === 0 || path.indexOf('/lw/') === 0) {
    event.respondWith(
      caches.match(req).then(function (hit) {
        if (hit) return hit;
        return fetch(req).then(function (resp) {
          if (resp && resp.ok && resp.type === 'basic') {
            var copy = resp.clone();
            caches.open(LW_CACHE).then(function (c) { c.put(req, copy); });
          }
          return resp;
        });
      })
    );
  }
});

/* Web Push：服务端发空负载 tickle，内容从 /lw/pwa/message 现取 */
self.addEventListener('push', function (event) {
  event.waitUntil(
    fetch(LW_SW_BASE + 'pwa/message', { cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : {}; })
      .catch(function () { return {}; })
      .then(function (m) {
        return self.registration.showNotification(
          m.title || 'lazarusWeb',
          {
            body: m.body || '您有一条新通知',
            icon: LW_SW_BASE + 'icon-192.png',
            badge: LW_SW_BASE + 'icon-192.png',
            data: { url: m.url || LW_APP_BASE }
          }
        );
      })
  );
});

self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  var target = (event.notification.data && event.notification.data.url) || LW_APP_BASE;
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (list) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].url === target) return list[i].focus();
      }
      return self.clients.openWindow(target);
    })
  );
});

self.addEventListener('message', function (event) {
  if (event.data && event.data.type === 'SKIP_WAITING') self.skipWaiting();
});
