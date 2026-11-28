/* lazarusWeb PWA 注册与推送辅助
   暴露 window.LWPWA：config() / subscribe() / unsubscribe() / isSubscribed()。
   注册、更新提示自动完成；订阅必须业务代码显式调用，避免未经同意弹权限框。 */
(function () {
  'use strict';
  var script = document.currentScript;
  if (!script) return;
  var scriptUrl = new URL(script.src, location.href);
  var lwBase = new URL('./', scriptUrl).pathname;
  var appBase = lwBase.replace(/lw\/?$/, '') || '/';
  var mv = scriptUrl.search.match(/[?&]v=([^&]+)/);
  var version = mv ? mv[1] : '1';
  var reloading = false;

  function config() {
    return fetch(lwBase + 'pwa/config', { cache: 'no-store' })
      .then(function (r) { return r.json(); });
  }

  function urlB64ToUint8Array(value) {
    var padding = '='.repeat((4 - value.length % 4) % 4);
    var base64 = (value + padding).replace(/-/g, '+').replace(/_/g, '/');
    var raw = atob(base64);
    var output = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; ++i) output[i] = raw.charCodeAt(i);
    return output;
  }

  function subscribe() {
    return config().then(function (cfg) {
      if (!cfg.push || !cfg.vapidPublicKey)
        throw new Error('Web Push 未配置（需要 VAPID 公钥/私钥）');
      return navigator.serviceWorker.ready.then(function (reg) {
        return reg.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlB64ToUint8Array(cfg.vapidPublicKey)
        }).then(function (sub) {
          return fetch(lwBase + 'pwa/subscribe', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(sub)
          }).then(function (r) { return r.json(); }).then(function () { return sub; });
        });
      });
    });
  }

  function unsubscribe() {
    return navigator.serviceWorker.ready.then(function (reg) {
      return reg.pushManager.getSubscription().then(function (sub) {
        if (!sub) return { ok: true };
        return fetch(lwBase + 'pwa/unsubscribe', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ endpoint: sub.endpoint })
        }).then(function (r) { return r.json(); }).then(function () {
          return sub.unsubscribe();
        });
      });
    });
  }

  function isSubscribed() {
    return navigator.serviceWorker.ready.then(function (reg) {
      return reg.pushManager.getSubscription().then(function (s) { return !!s; });
    });
  }

  function showUpdateBanner(worker) {
    if (document.getElementById('lw-pwa-update')) return;
    var box = document.createElement('div');
    box.id = 'lw-pwa-update';
    box.style.cssText = 'position:fixed;right:16px;bottom:16px;z-index:2147483647;' +
      'background:#fff;color:#222;border:1px solid #d0d7de;border-radius:8px;' +
      'box-shadow:0 6px 24px rgba(0,0,0,.18);padding:12px 14px;font:14px/1.5 ' +
      'system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif';
    var text = document.createElement('span');
    text.textContent = '发现新版本，';
    var btn = document.createElement('button');
    btn.textContent = '立即更新';
    btn.style.cssText = 'margin-left:6px;padding:4px 10px;cursor:pointer;' +
      'border:0;border-radius:4px;background:#1a73e8;color:#fff';
    btn.onclick = function () {
      worker.postMessage({ type: 'SKIP_WAITING' });
      box.remove();
    };
    box.appendChild(text);
    box.appendChild(btn);
    document.body.appendChild(box);
  }

  window.LWPWA = {
    config: config,
    subscribe: subscribe,
    unsubscribe: unsubscribe,
    isSubscribed: isSubscribed,
    base: appBase,
    lwBase: lwBase
  };

  if (!('serviceWorker' in navigator)) return;
  window.addEventListener('load', function () {
    navigator.serviceWorker.register(
      lwBase + 'sw.js?v=' + encodeURIComponent(version), { scope: appBase }
    ).then(function (reg) {
      reg.addEventListener('updatefound', function () {
        var worker = reg.installing;
        if (!worker) return;
        worker.addEventListener('statechange', function () {
          if (worker.state === 'installed' && navigator.serviceWorker.controller)
            showUpdateBanner(worker);
        });
      });
    }).catch(function (err) {
      if (window.console && console.warn) console.warn('[LWPWA] 注册失败:', err);
    });
    navigator.serviceWorker.addEventListener('controllerchange', function () {
      if (reloading) return;
      reloading = true;
      location.reload();
    });
  });
})();
