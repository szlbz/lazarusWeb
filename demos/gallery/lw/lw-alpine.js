/*
 * lazarusWeb :: lw-alpine.js —— 浏览器端运行时（Alpine.js 3.x）
 * SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
 * ------------------------------------------------------------------
 * 与 lw.js（Ext JS 版）协议完全一致，只是渲染层从 Ext 组件树换成
 * 「服务端 JSON 树 -> 绝对定位 DOM + Alpine 响应式绑定」：
 *   1. 向服务端要一棵组件树（JSON）；
 *   2. 每个节点渲染成一个绝对定位的 div，内部用 Alpine 指令声明行为；
 *   3. 用户操作 -> {id, ev, val} 发回服务端执行真实的 Pascal 事件；
 *   4. 事件响应/推送回来的新树做增量协调：值/选中/禁用走 Alpine 响应式
 *      状态，不重建 DOM；结构性变化（行/列/子树）才重建对应区块。
 *
 * 与服务端的约定见 src/core/lwwriter.pas（节点字段完全同 lw.js 消费的那份）。
 * 会话/事件/轮询/对话框/上传/下载协议见 src/core/lwhttp.pas。
 */
var LW = (function () {
    'use strict';

    var S = {
        sid: null,
        R: {},        /* nodeId -> Alpine.reactive 节点状态（模板绑定的唯一来源） */
        E: {},        /* nodeId -> 包装 div（绝对定位） */
        K: {},        /* nodeId -> kind（快速判定） */
        EV: {},       /* nodeId -> ev 数组（是否有某事件） */
        ND: {},       /* nodeId -> 最新节点 JSON（patch 对账/闭包外取最新值） */
        P: {},        /* nodeId -> 父容器包装 el */
        WIN: {},      /* nodeId -> 所属窗体 id（值快照按窗体收集） */
        NAME: {},     /* name -> nodeId（绑定标签找编辑框用） */
        kids: {},     /* 容器元素 -> [child nodeId] */
        forms: {},    /* formId -> {el, body, f} */
        sigs: {},     /* nodeId -> 结构指纹（列表/表格/树整块重建用） */
        busy: 0,
        pollAlive: false,
        ws: null,
        wsCb: null,
        wsTimer: null,
        wsConnecting: false,
        tab: null,
        primary: false,
        multiTab: false,
        after: -1,
        inflight: 0,
        tver: -1,     /* 已应用的树版本（增量补丁用；-1 = 未知，下帧要全量） */
        nPatch: 0,    /* 收到并应用过的补丁数（诊断用，LW.stats() 可见） */
        nFull: 0,     /* 收到过的全量树数 */
    };

    /* ---------------- 工具 ---------------- */

    function log() {
        if (window.console && console.log) {
            console.log.apply(console, ['[lw]'].concat([].slice.call(arguments)));
        }
    }

    function esc(s) {
        if (s == null) return '';
        return String(s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    function defer(fn, ms) { return setTimeout(fn, ms || 0); }

    function api(path, data, cb, opts) {
        opts = opts || {};
        var o = { method: data ? 'POST' : 'GET', headers: { 'Content-Type': 'application/json' } };
        if (data) o.body = JSON.stringify(data);
        if (!data && opts.params) {
            var qs = Object.keys(opts.params).map(function (k) {
                return encodeURIComponent(k) + '=' + encodeURIComponent(opts.params[k]);
            }).join('&');
            path += (path.indexOf('?') >= 0 ? '&' : '?') + qs;
        }
        fetch(path, o).then(function (r) {
            return r.text().then(function (t) {
                var d = null;
                try { d = JSON.parse(t); } catch (e) { }
                cb(d, d ? null : 'bad json');
            });
        }).catch(function (e) { cb(null, 'http error: ' + ((e && e.message) || e)); });
    }

    /* 模板表达式入口（Alpine 表达式里可访问的全局函数） */
    window.$lwN = function (id) { return S.R[id]; };
    window.$lwFire = function (id, ev, extra) { fire(id, ev, extra); };
    window.$lwSet = function (id, k, v) { var r = S.R[id]; if (r) r[k] = v; };
    window.$lwHas = function (id, ev) {
        var evs = S.EV[id];
        return !!(evs && evs.indexOf(ev) >= 0);
    };

    /* ---------------- Alpine store（外壳 UI：遮罩/对话框/toast/忙） ---------------- */

    document.addEventListener('alpine:init', function () {
        Alpine.store('lw', {
            busy: 0,
            splash: '正在创建服务端会话…',
            mask: { show: false, text: '' },
            dialog: null,   /* 服务端对话框指令（见 showServerDialog） */
            dlgText: '',    /* input/savefile 对话框的输入内容 */
            toasts: []      /* {id,title,text} */
        });
    });

    function st() { return window.Alpine ? Alpine.store('lw') : null; }

    function showSplash(txt) { var s = st(); if (s) s.splash = txt || ''; }
    function hideSplash() { var s = st(); if (s) s.splash = ''; }
    function setBusy(on) {
        var s = st(); if (!s) return;
        if (on) s.busy++; else s.busy = Math.max(0, s.busy - 1);
    }

    /* ---------------- LCL Hint -> 浏览器提示（轻量 tooltip） ---------------- */

    var tipEl = null, tipTimer = null;

    function initTooltip() {
        if (tipEl) return;
        tipEl = document.createElement('div');
        tipEl.className = 'lw-tip';
        tipEl.style.display = 'none';
        document.body.appendChild(tipEl);
        document.addEventListener('mouseover', function (e) {
            var t = e.target;
            while (t && t !== document.body && !(t.getAttribute && t.getAttribute('data-lwhint'))) t = t.parentNode;
            if (t && t !== document.body && t.getAttribute) {
                var h = t.getAttribute('data-lwhint');
                if (!h) { hideTip(); return; }
                if (tipTimer) clearTimeout(tipTimer);
                tipTimer = defer(function () { showTip(t, h); }, 400);
            } else hideTip();
        });
        document.addEventListener('mousedown', hideTip);
    }

    function showTip(target, h) {
        if (!tipEl) return;
        tipEl.innerHTML = esc(h).replace(/\r?\n/g, '<br>');
        tipEl.style.display = 'block';
        var r = target.getBoundingClientRect();
        var x = Math.min(r.left, window.innerWidth - tipEl.offsetWidth - 8);
        var y = r.bottom + 6;
        if (y + tipEl.offsetHeight > window.innerHeight) y = r.top - tipEl.offsetHeight - 6;
        tipEl.style.left = Math.max(4, x) + 'px';
        tipEl.style.top = Math.max(4, y) + 'px';
    }

    function hideTip() {
        if (tipTimer) { clearTimeout(tipTimer); tipTimer = null; }
        if (tipEl) tipEl.style.display = 'none';
    }

    function applyHint(id, node) {
        var el = S.E[id];
        if (!el) return;
        if (node.hint) el.setAttribute('data-lwhint', String(node.hint));
        else el.removeAttribute('data-lwhint');
    }

    /* ---------------- 文件上传 ---------------- */

    function filterToAccept(f) {
        var out = [], parts = String(f || '').split('|');
        parts.forEach(function (p) {
            p.split(';').forEach(function (m) {
                m = m.trim();
                if (m.indexOf('*.') === 0) {
                    var e = m.substring(1).toLowerCase();
                    if (out.indexOf(e) < 0) out.push(e);
                }
            });
        });
        return out.join(',');
    }

    function pickFile(node, onDone) {
        var inp = document.createElement('input');
        inp.type = 'file';
        if (node.multiple) inp.multiple = true;
        var acc = filterToAccept(node.filter);
        if (acc) inp.accept = acc;
        inp.style.position = 'fixed';
        inp.style.left = '-9999px';
        document.body.appendChild(inp);
        function cleanup() { try { document.body.removeChild(inp); } catch (e) { } }
        inp.onchange = function () {
            var files = inp.files;
            if (!files || !files.length) { cleanup(); return; }
            uploadFiles(node, files, cleanup);
        };
        inp.click();
    }

    function uploadFiles(node, files, done) {
        var fd = new FormData();
        for (var i = 0; i < files.length; i++) fd.append('f' + i, files[i], files[i].name);
        var base = node.caption || '上传文件…';
        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/lw/api/upload?sid=' + encodeURIComponent(S.sid || '') +
            '&id=' + node.id, true);
        xhr.upload.onprogress = function (e) {
            if (e.lengthComputable) setCaption(node.id, '上传中 ' + Math.round(e.loaded * 100 / e.total) + '%');
        };
        function finish() {
            setBusy(false);
            setCaption(node.id, base);
            if (done) done();
        }
        xhr.onload = function () {
            var d = null;
            try { d = JSON.parse(xhr.responseText); } catch (e) { }
            finish();
            if (d && d.ok) applyPayload(d);
            else showMsg('上传失败', esc((d && d.err) || ('HTTP ' + xhr.status)));
        };
        xhr.onerror = function () { finish(); showMsg('上传失败', '网络错误'); };
        setBusy(true);
        xhr.send(fd);
    }

    function setCaption(id, txt) {
        var r = S.R[id];
        if (r) r.cap = txt;
        var el = S.E[id];
        if (el) {
            var b = el.querySelector('button, .lw-btn');
            if (b) b.textContent = txt;
        }
    }

    /* ---------------- 事件回传 ---------------- */

    /* 会承载"用户输入值"的控件类型（与服务端 LWIsSnapField 对应） */
    var FIELD_KINDS = ['edit', 'maskedit', 'memo', 'spin', 'floatspin', 'combo',
        'checkbox', 'radio', 'dbedit', 'dbmemo', 'dbcheckbox', 'dbcombo',
        'dblookup', 'dateedit', 'timeedit'];

    /* 从 DOM 读控件当前值（正在编辑的输入框以 DOM 为准） */
    function collectVal(id) {
        var kind = S.K[id], el = S.E[id];
        if (!el || !kind) return '';
        try {
            var inp = el.querySelector('input,textarea,select');
            if (kind === 'checkbox' || kind === 'dbcheckbox' || kind === 'radio') {
                return (inp && inp.checked) ? '1' : '0';
            }
            if (inp) return inp.value == null ? '' : String(inp.value);
        } catch (e) { }
        return '';
    }

    /* 同一窗体里所有输入控件的当前值：{控件 id: 值} */
    function formVals(nodeId) {
        var winId = S.WIN[nodeId];
        if (!winId) return null;
        var out = {}, any = false;
        Object.keys(S.K).forEach(function (id) {
            if (S.WIN[id] !== winId) return;
            if (FIELD_KINDS.indexOf(S.K[id]) < 0) return;
            out[id] = collectVal(id);
            any = true;
        });
        return any ? out : null;
    }

    function applyEventResp(resp, err) {
        if (err) { log('event failed', err); return; }
        if (resp && resp.ok) {
            if (resp.patch) applyPatch(resp);
            else applyPayload(resp);
        }
        else if (resp && resp.err) log('event err', resp.err);
    }

    /* HTTP 兜底发送（与 Ext 版同一语义：超时 > 服务端模态等待上限 180s） */
    function sendEventHttp(payload) {
        setBusy(true);
        S.inflight++;
        var ctrl = new AbortController();
        var to = setTimeout(function () { try { ctrl.abort(); } catch (e) { } }, 200000);
        fetch('/lw/api/event', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
            signal: ctrl.signal
        }).then(function (r) { return r.text(); }).then(function (t) {
            clearTimeout(to);
            S.inflight--;
            setBusy(false);
            var d = null;
            try { d = JSON.parse(t); } catch (e) { }
            applyEventResp(d, d ? null : 'bad json');
        }).catch(function () {
            clearTimeout(to);
            S.inflight--;
            setBusy(false);
            applyEventResp(null, 'http error');
        });
    }

    function fire(id, ev, extra) {
        if (!S.sid) return;
        var node = S.ND[id];
        var payload = { sid: S.sid, id: id, ev: ev, tab: S.tab };
        /* 增量补丁：patch=1 声明本前端懂 ops，tver 是已应用的树版本。
           服务端 --patch=0 或没带这两个字段时一律回全量 —— 所以老缓存
           js、Ext 渲染层不会因为服务端开了补丁而白屏 */
        payload.patch = 1;
        if (S.tver >= 0) payload.tver = S.tver;
        if (extra) Object.keys(extra).forEach(function (k) { payload[k] = extra[k]; });
        /* 带上窗体值快照：没挂 OnChange 的编辑框平时不回传值，服务端只有
           初始 Text —— 点"登录"会拿旧密码去校验。 */
        if (!payload.vals) {
            var snap = formVals(id);
            if (snap) payload.vals = snap;
        }
        /* WebSocket 已连接：事件走 WS 帧（与 POST /lw/api/event 同构）。
           同一时刻只允许一个在途事件；连接断了转 HTTP 重发；
           挂在服务端对话框上的事件最长等 190s（180s + 余量）。 */
        if (S.ws && S.ws.readyState === 1 && !S.wsCb) {
            setBusy(true);
            S.inflight++;
            var cbSelf = function (resp, err) {
                if (S.wsTimer) { clearTimeout(S.wsTimer); S.wsTimer = null; }
                S.inflight--;
                setBusy(false);
                if (err) { sendEventHttp(payload); return; }
                applyEventResp(resp, null);
            };
            S.wsCb = cbSelf;
            var waited = 0;
            var tick = function () {
                if (S.wsCb !== cbSelf) return;
                if (S.ws && S.ws.readyState === 1 && waited < 190000) {
                    waited += 5000;
                    S.wsTimer = defer(tick, 5000);
                    return;
                }
                S.wsCb = null;
                S.inflight--;
                setBusy(false);
                try { if (S.ws) S.ws.close(); } catch (e0) { }
                sendEventHttp(payload);
            };
            S.wsTimer = defer(tick, 5000);
            try { S.ws.send(JSON.stringify(payload)); }
            catch (e) {
                if (S.wsTimer) { clearTimeout(S.wsTimer); S.wsTimer = null; }
                S.wsCb = null; S.inflight--; setBusy(false);
                sendEventHttp(payload);
            }
            return;
        }
        sendEventHttp(payload);
    }

    /* ---------------- 样式 ---------------- */

    function styleOf(node) {
        var f = node.font || {}, st = '';
        if (f.size) st += 'font-size:' + Math.round(f.size * 4 / 3) + 'px;';
        if (f.name && f.name !== 'default') st += 'font-family:' + f.name + ';';
        if (f.style) {
            if (f.style.indexOf('b') >= 0) st += 'font-weight:bold;';
            if (f.style.indexOf('i') >= 0) st += 'font-style:italic;';
            if (f.style.indexOf('u') >= 0) st += 'text-decoration:underline;';
        }
        if (node.fg) st += 'color:' + node.fg + ';';
        return st;
    }

    function fieldStyleOf(node) {
        return styleOf(node);
    }

    /* ---------------- 节点状态 ----------------
       每个节点一个 Alpine.reactive 对象，模板指令只读它；
       补丁轮改状态，Alpine 自动把 DOM 更新到位。 */

    function stateOf(node) {
        var id = node.id, r = S.R[id];
        if (r) return r;
        var k = node.kind;
        r = Alpine.reactive({
            dis: node.enabled === false,
            vis: node.visible !== false,
            cap: node.caption != null ? String(node.caption) : '',
            txt: node.text != null ? String(node.text) : '',
            chk: !!node.checked,
            ind: node.state === 2,
            down: !!node.down,
            val: node.value != null ? node.value : 0,
            idx: node.index != null ? node.index : -1,
            iso: node.iso || '',
            src: node.src || '',
            items: node.items || [],
            keys: (k === 'dbradiogroup') ? (node.values || []) : (node.keys || []),
            checked: Array.isArray(node.checked) ? node.checked.slice() : [],
            cols: node.cols || [],
            rows: node.rows || [],
            active: node.active || 0,
            /* dbgrid 扩展状态 */
            recno: node.recno || 0,
            page: node.page || 1,
            pages: node.pages || 0,
            ftext: node.filtertext || '',
            pgtext: '',
            sumtext: '',
            /* valeditor 表头 */
            t0: '', t1: '',
            /* dblookup 当前键 */
            key: node.key != null ? String(node.key) : ''
        });
        if (k === 'combo') {
            r.txt = node.text || (node.items && node.index >= 0 ? node.items[node.index] : '');
        }
        if (k === 'dbgrid') {
            r.pgtext = pagerTextOf(node);
            r.sumtext = node.summary ? summaryTextOf(node.summary) : '';
        }
        if (k === 'valeditor') {
            r.values = (node.values || []).slice();
            var ts = String(node.titles || '键,值').split(',');
            r.t0 = ts[0] || 'Key'; r.t1 = ts[1] || 'Value';
        }
        S.R[id] = r;
        return r;
    }

    /* ---------------- 仪表盘（TLWGauge）：纯 SVG ---------------- */

    function gaugeSig(n) {
        return [n.value, n.min, n.max, n.unit, n.warn, n.danger, n.w, n.h].join('|');
    }

    function gaugeSvg(n) {
        var w = n.w || 220, h = n.h || 140;
        var min = (n.min == null ? 0 : n.min);
        var max = (n.max == null ? 100 : n.max);
        if (max <= min) max = min + 1;
        var v = n.value == null ? min : n.value;
        if (v < min) v = min;
        if (v > max) v = max;
        var f = (v - min) / (max - min);

        var cx = w / 2, cy = h * 0.8;
        var r = Math.max(20, Math.min(w * 0.44, h * 0.6));
        var col = '#188038';
        if (n.danger && f >= n.danger) col = '#d93025';
        else if (n.warn && f >= n.warn) col = '#f29900';

        function pt(frac, rad) {
            var a = Math.PI + Math.PI * frac;
            return [cx + rad * Math.cos(a), cy + rad * Math.sin(a)];
        }
        function arc(f0, f1, rad) {
            var a = pt(f0, rad), b = pt(f1, rad);
            /* large-arc 恒为 0：值弧角最大 180°，按给定半径画才与轨道重合 */
            return 'M ' + a[0].toFixed(1) + ' ' + a[1].toFixed(1) +
                ' A ' + rad.toFixed(1) + ' ' + rad.toFixed(1) + ' 0 0 1 ' +
                b[0].toFixed(1) + ' ' + b[1].toFixed(1);
        }

        var parts = [];
        parts.push('<svg width="' + w + '" height="' + h + '" viewBox="0 0 ' + w + ' ' + h + '" xmlns="http://www.w3.org/2000/svg">');
        parts.push('<path d="' + arc(0, 1, r) + '" fill="none" stroke="#e3e8ee" stroke-width="10" stroke-linecap="round"/>');
        if (f > 0.001)
            parts.push('<path d="' + arc(0, f, r) + '" fill="none" stroke="' + col + '" stroke-width="10" stroke-linecap="round"/>');
        for (var i = 0; i <= 10; i++) {
            var a1 = pt(i / 10, r - 21), a2 = pt(i / 10, r - 15);
            parts.push('<line x1="' + a1[0].toFixed(1) + '" y1="' + a1[1].toFixed(1) +
                '" x2="' + a2[0].toFixed(1) + '" y2="' + a2[1].toFixed(1) +
                '" stroke="#c3ced9" stroke-width="1"/>');
        }
        var tip = pt(f, r * 0.72);
        parts.push('<line x1="' + cx + '" y1="' + cy + '" x2="' + tip[0].toFixed(1) +
            '" y2="' + tip[1].toFixed(1) + '" stroke="' + col + '" stroke-width="3" stroke-linecap="round"/>');
        parts.push('<circle cx="' + cx + '" cy="' + cy + '" r="5" fill="' + col + '"/>');
        var fs = Math.max(13, Math.min(w / 6, h / 4.2));
        var txt = (Math.round(v * 100) / 100) + (n.unit || '');
        parts.push('<text x="' + cx + '" y="' + (cy - 12) + '" text-anchor="middle" font-size="' +
            fs.toFixed(0) + '" font-weight="bold" fill="' + col + '">' + esc(txt) + '</text>');
        if (n.caption)
            parts.push('<text x="' + cx + '" y="14" text-anchor="middle" font-size="12" fill="#5b6b7b">' + esc(n.caption) + '</text>');
        parts.push('</svg>');
        return parts.join('');
    }

    /* ---------------- 图表（TLWChart）：内置 SVG 渲染器 ----------------
       不依赖 Ext charts 包；折线/柱状/饼图三种类型，配色与 Ext 版一致观感 */

    function chartSig(n) {
        return JSON.stringify([n.charttype, n.title, n.categories, n.series]);
    }

    var CHART_COLORS = ['#2a7de1', '#e8743b', '#3f9ae0', '#188038', '#f29900',
        '#a259d9', '#d9534f', '#17a2a2'];

    function chartSvg(n) {
        var w = n.w || 300, h = n.h || 220;
        var cats = n.categories || [];
        var series = n.series || [];
        var pad = { l: 46, r: 12, t: (n.title ? 26 : 10), b: 42 };
        var parts = ['<svg width="100%" height="100%" viewBox="0 0 ' + w + ' ' + h +
            '" preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg">'];

        function textEl(x, y, s, size, anchor, fill, extra) {
            return '<text x="' + x.toFixed(1) + '" y="' + y.toFixed(1) + '" text-anchor="' + (anchor || 'middle') +
                '" font-size="' + (size || 11) + '" fill="' + (fill || '#44525f') + '"' + (extra || '') + '>' + esc(s) + '</text>';
        }

        if (n.title) parts.push(textEl(w / 2, 16, n.title, 13, 'middle', '#2b3a49', ' font-weight="bold"'));

        if (n.charttype === 'pie') {
            var s0 = series[0] || { values: [] };
            var vals = cats.map(function (c, i) { return parseFloat((s0.values || [])[i]) || 0; });
            var total = vals.reduce(function (a, b) { return a + b; }, 0);
            var cx = pad.l + (w - pad.l - pad.r) / 2 - 30, cy = pad.t + (h - pad.t - pad.b) / 2;
            var r = Math.max(20, Math.min((w - pad.l - pad.r) / 2 - 30, (h - pad.t - pad.b) / 2 - 10));
            var a0 = -Math.PI / 2;
            if (total <= 0) total = 1;
            vals.forEach(function (v, i) {
                var frac = v / total, a1 = a0 + frac * Math.PI * 2;
                if (frac <= 0) { a0 = a1; return; }
                var large = (a1 - a0) > Math.PI ? 1 : 0;
                var x0 = cx + r * Math.cos(a0), y0 = cy + r * Math.sin(a0);
                var x1 = cx + r * Math.cos(a1), y1 = cy + r * Math.sin(a1);
                parts.push('<path d="M ' + cx + ' ' + cy + ' L ' + x0.toFixed(1) + ' ' + y0.toFixed(1) +
                    ' A ' + r.toFixed(1) + ' ' + r.toFixed(1) + ' 0 ' + large + ' 1 ' + x1.toFixed(1) + ' ' + y1.toFixed(1) +
                    ' Z" fill="' + CHART_COLORS[i % CHART_COLORS.length] + '" stroke="#fff" stroke-width="1"/>');
                var am = (a0 + a1) / 2, lx = cx + (r + 12) * Math.cos(am), ly = cy + (r + 12) * Math.sin(am);
                parts.push(textEl(lx, ly + 4, cats[i] || '', 11, am > Math.PI / 2 || am < -Math.PI / 2 ? 'end' : 'start'));
                a0 = a1;
            });
            /* 图例（右侧） */
            var ly0 = pad.t + 8;
            cats.forEach(function (c, i) {
                parts.push('<rect x="' + (w - 78) + '" y="' + ly0 + '" width="10" height="10" fill="' + CHART_COLORS[i % CHART_COLORS.length] + '"/>');
                parts.push(textEl(w - 64, ly0 + 9, c, 11, 'start'));
                ly0 += 16;
            });
            parts.push('</svg>');
            return parts.join('');
        }

        /* 折线 / 柱状：统一坐标轴 */
        var iw = w - pad.l - pad.r, ih = h - pad.t - pad.b;
        var maxv = 0;
        series.forEach(function (s) { (s.values || []).forEach(function (v) { var f = parseFloat(v) || 0; if (f > maxv) maxv = f; }); });
        if (maxv <= 0) maxv = 10;
        var nice = Math.pow(10, Math.floor(Math.log(maxv) / Math.LN10));
        maxv = Math.ceil(maxv / nice) * nice;
        /* 网格 + y 轴刻度 */
        for (var g = 0; g <= 4; g++) {
            var gy = pad.t + ih - ih * g / 4;
            parts.push('<line x1="' + pad.l + '" y1="' + gy.toFixed(1) + '" x2="' + (w - pad.r) + '" y2="' + gy.toFixed(1) +
                '" stroke="#e3e8ee" stroke-width="1"/>');
            parts.push(textEl(pad.l - 6, gy + 4, String(Math.round(maxv * g / 4 * 100) / 100), 10, 'end', '#8a97a5'));
        }
        var ncat = Math.max(cats.length, 1);
        var step = iw / ncat;
        cats.forEach(function (c, i) {
            parts.push(textEl(pad.l + step * i + step / 2, h - pad.b + 14, c, 11));
        });
        if (n.charttype === 'bar') {
            var bw = Math.max(4, step * 0.6 / Math.max(series.length, 1));
            series.forEach(function (s, si) {
                (s.values || []).forEach(function (v, i) {
                    var f = parseFloat(v) || 0;
                    var bh = ih * f / maxv;
                    var x = pad.l + step * i + step / 2 - bw * series.length / 2 + bw * si;
                    parts.push('<rect x="' + x.toFixed(1) + '" y="' + (pad.t + ih - bh).toFixed(1) +
                        '" width="' + bw.toFixed(1) + '" height="' + bh.toFixed(1) +
                        '" fill="' + CHART_COLORS[si % CHART_COLORS.length] + '"/>');
                });
            });
        } else {
            series.forEach(function (s, si) {
                var d = '', first = true;
                (s.values || []).forEach(function (v, i) {
                    var f = parseFloat(v) || 0;
                    var x = pad.l + step * i + step / 2;
                    var y = pad.t + ih - ih * f / maxv;
                    d += (first ? 'M ' : ' L ') + x.toFixed(1) + ' ' + y.toFixed(1);
                    first = false;
                    parts.push('<circle cx="' + x.toFixed(1) + '" cy="' + y.toFixed(1) + '" r="3" fill="' + CHART_COLORS[si % CHART_COLORS.length] + '"/>');
                });
                if (d) parts.push('<path d="' + d + '" fill="none" stroke="' + CHART_COLORS[si % CHART_COLORS.length] +
                    '" stroke-width="2"/>');
            });
        }
        /* 多系列图例（底部） */
        if (series.length > 1) {
            var lx = pad.l;
            series.forEach(function (s, si) {
                parts.push('<rect x="' + lx + '" y="' + (h - 16) + '" width="10" height="10" fill="' + CHART_COLORS[si % CHART_COLORS.length] + '"/>');
                parts.push(textEl(lx + 14, h - 7, s.name || ('S' + (si + 1)), 11, 'start'));
                lx += 20 + ((s.name || ('S' + (si + 1))).length) * 12;
            });
        }
        parts.push('</svg>');
        return parts.join('');
    }

    /* ---------------- HTMLFrame 里的 <script> 重放 ---------------- */

    function execHtmlScripts(el) {
        if (!el) return;
        var list = [];
        try { list = el.querySelectorAll('script'); } catch (e) { return; }
        for (var i = 0; i < list.length; i++) {
            try {
                (0, eval)(list[i].textContent || list[i].innerHTML || '');
            } catch (e2) {
                log('htmlframe script error', e2);
            }
        }
    }

    /* ---------------- 列表行点击（listbox 族） ----------------
       回传序号：服务端 TListBox 分支文本找不到时按数字解释（兼容两者） */

    window.$lwLbClick = function (id, i, how) {
        var r = S.R[id];
        if (!r) return;
        r.idx = i;
        var txt = (r.items || [])[i];
        txt = txt == null ? '' : String(txt);
        if ($lwHas(id, 'OnClick')) fire(id, 'OnClick', { val: String(i) });
        if ($lwHas(id, 'OnSelect')) fire(id, 'OnSelect', { val: txt });
        if (how === 'sel' && $lwHas(id, 'OnChange')) fire(id, 'OnChange', { val: String(i) });
    };

    /* dblookuplist/dblistbox 的 OnChange 带 KeyField 值 */
    window.$lwLkClick = function (id, i) {
        var r = S.R[id];
        if (!r) return;
        r.idx = i;
        var k = (r.keys || [])[i];
        if ($lwHas(id, 'OnClick')) fire(id, 'OnClick', { val: String(i) });
        if ($lwHas(id, 'OnChange')) fire(id, 'OnChange', { val: k == null ? '' : String(k) });
    };

    /* 取色器：原生 <input type=color> 弹调色板 */
    window.$lwPickColor = function (id) {
        var inp = document.createElement('input');
        inp.type = 'color';
        inp.value = (S.ND[id] && S.ND[id].value) || '#ffffff';
        inp.style.position = 'fixed';
        inp.style.left = '-9999px';
        document.body.appendChild(inp);
        inp.oninput = function () {
            var hex = String(inp.value).toUpperCase();
            var r = S.R[id];
            if (r) r.txt = hex;
            if (S.ND[id]) S.ND[id].value = hex;
            var el = S.E[id];
            if (el) {
                var sw = el.querySelector('.lw-swatch');
                if (sw) sw.style.background = hex;
            }
            fire(id, 'OnColorChange', { val: hex });
        };
        inp.onchange = function () { try { document.body.removeChild(inp); } catch (e) { } };
        inp.click();
    };

    /* ---------------- 速度按钮组 ---------------- */

    window.$lwBtnClick = function (id, ev) {
        var r = S.R[id], n = S.ND[id];
        if (!r || !n) return;
        if (n.kind === 'speedbutton' && n.groupindex > 0) {
            /* 互斥组：按下后不允许再点弹起（LCL 语义） */
            if (!r.down) {
                r.down = true;
                fire(id, ev || 'OnClick');
            }
        } else if (n.down != null && n.kind !== 'speedbutton') {
            /* TToggleBox：可保持按下，也允许点起（allowup） */
            r.down = n.allowup === false ? true : !r.down;
            fire(id, ev || 'OnClick');
        } else {
            fire(id, ev || 'OnClick');
        }
    };

    /* ---------------- 页签切换 ---------------- */

    window.$lwTabClick = function (id, i) {
        /* tabs 模板不引用响应式状态，stateOf 可能还没建 —— 这里兜底建一次 */
        var r = S.R[id] || (S.ND[id] ? stateOf(S.ND[id]) : null);
        if (!r || r.active === i) return;
        r.active = i;
        applyTabActive(id, i);
        if ($lwHas(id, 'OnChange')) fire(id, 'OnChange', { val: String(i) });
    };

    /* 把卡片可见性同步到 active（服务端改 ActivePage / 用户点标签共用） */
    function applyTabActive(id, active) {
        var el = S.E[id];
        if (!el) return;
        /* 页签卡片 = tabs-body 的直接子节点（sheet 的 .lw-n 包装层）；
           模板结构是 .lw-n > .lw-tabs > .lw-tabbar + .lw-tabs-body，
           老选择器 ':scope > .lw-tabs-body > .lw-tabcard' 永远匹配不到 */
        var cards = el.querySelectorAll(':scope > .lw-tabs > .lw-tabs-body > [data-lwid]');
        for (var i = 0; i < cards.length; i++) {
            cards[i].style.display = (i === active) ? '' : 'none';
        }
    }

    /* ---------------- 节点工厂 ----------------
       每个节点 = 绝对定位包装 div + kind 专属内部标记（Alpine 指令）。
       事件统一用 $lwFire 回传；是否绑定看服务端下发的 ev 列表。 */

    var CONTAINER_KINDS = ['form', 'panel', 'groupbox', 'scrollbox', 'frame', 'tabs', 'tabsheet', 'tabctl', 'toolbar'];
    function isContainer(node) { return CONTAINER_KINDS.indexOf(node.kind) >= 0; }

    function wrapHtml(node, inner, cls, style) {
        return '<div class="lw-n ' + (cls || '') + '" data-lwid="' + node.id + '"' +
            (style ? ' style="' + style + '"' : '') + '>' + inner + '</div>';
    }

    function evAttr(id, ev, extra) {
        return '$lwHas(\'' + id + '\',\'' + ev + '\') && $lwFire(\'' + id + '\',\'' + ev + '\'' +
            (extra ? ',' + extra : '') + ')';
    }

    /* DBGrid 单元格标记（首建与列变化重建共用一份，免得两处走样）：
       布尔列（服务端 cedit=4）里常驻一个勾选框，点一下即写回；
       其余列就是一段文本，点击由 $lwDbCell 换成对应编辑器。
       注意 i/j/cell 是外层 x-for 的变量名，两处模板必须保持一致 */
    function dbCellTd(dgid) {
        return '<td @click.stop="$lwDbCell(\'' + dgid + '\', i, j, $event)">' +
            '<template x-if="$lwChk(\'' + dgid + '\', j)">' +
            '<input type="checkbox" class="lw-chk"' +
            ' :checked="cell === \'1\' || cell === true"' +
            ' @click.stop="$lwChkTap(\'' + dgid + '\', i, j, $event)"/>' +
            '</template>' +
            '<template x-if="!$lwChk(\'' + dgid + '\', j)"><span x-text="cell"></span></template>' +
            '</td>';
    }

    /* 内部标记（不含包装 div）。st = 状态对象，node = 最新 JSON */
    function innerOf(node, st) {
        var k = node.kind, id = node.id, r = '$lwN(\'' + id + '\')';
        var dis = ':disabled="' + r + '.dis"';
        var ro = node.readonly ? ' readonly' : '';
        var fs = fieldStyleOf(node);

        switch (k) {
            case 'label':
            case 'static':
                return '<div class="lw-label" style="white-space:' + (node.wordwrap ? 'normal' : 'nowrap') +
                    ';overflow:hidden;' + (node.textalign === 1 ? 'text-align:center;' : node.textalign === 2 ? 'text-align:right;' : '') +
                    fs + '" x-text="' + r + '.txt" @click="' + evAttr(id, 'OnClick') + '"></div>';

            case 'button':
            case 'bitbtn':
            case 'speedbutton':
            case 'fileupload': {
                var bic = '';
                if (k === 'bitbtn' && node.btnkind > 0) {
                    var BICONS = { 1: 'ok', 2: 'cancel', 3: 'help', 4: 'yes', 5: 'no', 6: 'close', 7: 'abort', 8: 'retry', 9: 'ignore', 10: 'all', 11: 'notoall', 12: 'yestoall' };
                    if (BICONS[node.btnkind]) bic = ' lw-bic-' + BICONS[node.btnkind];
                }
                var clickExp = (k === 'fileupload')
                    ? 'pickUpload(\'' + id + '\')'
                    : '$lwBtnClick(\'' + id + '\',\'OnClick\')';
                return '<button type="button" class="lw-btn' + bic + '" style="' + fs + '" ' + dis +
                    ' :class="' + r + '.down ? \'lw-btn-pressed\' : \'\'" @click="' + clickExp +
                    '" x-text="' + r + '.cap"></button>';
            }

            case 'toolbutton':
                if (node.sep) return '<div class="lw-tbsep"></div>';
                return '<button type="button" class="lw-btn lw-tool" style="' + fs + '" ' + dis +
                    ' @click="$lwBtnClick(\'' + id + '\',\'OnClick\')" x-text="' + r + '.cap"></button>';

            case 'edit':
            case 'maskedit':
            case 'dbedit':
                return '<input type="' + (node.password ? 'password' : 'text') + '" class="lw-input" style="' + fs +
                    '" x-model="' + r + '.txt"' + (node.maxlength ? ' maxlength="' + node.maxlength + '"' : '') +
                    ro + ' ' + dis + ' @change="' + evAttr(id, 'OnChange', '{val:' + r + '.txt}') +
                    '" @focus="' + evAttr(id, 'OnEnter') + '" @blur="' + evAttr(id, 'OnExit') + '"/>';

            case 'editbtn':
                return '<div class="lw-editbtn"><input type="text" class="lw-input" style="' + fs +
                    '" x-model="' + r + '.txt"' + ro + ' ' + dis +
                    ' @change="' + evAttr(id, 'OnChange', '{val:' + r + '.txt}') + '"/>' +
                    '<button type="button" class="lw-btn lw-eb-btn" ' + dis +
                    ' @click="' + evAttr(id, 'OnButtonClick') + '">…</button></div>';

            case 'memo':
            case 'dbmemo':
                return '<textarea class="lw-memo" style="' + fs + '" x-model="' + r + '.txt"' + ro + ' ' + dis +
                    ' @change="' + evAttr(id, 'OnChange', '{val:' + r + '.txt}') +
                    '" @focus="' + evAttr(id, 'OnEnter') + '" @blur="' + evAttr(id, 'OnExit') + '"></textarea>';

            case 'spin':
                return '<input type="number" class="lw-input" style="' + fs + '" x-model.number="' + r + '.val"' +
                    (node.min != null ? ' min="' + node.min + '"' : '') + (node.max != null ? ' max="' + node.max + '"' : '') +
                    ' step="1" ' + dis + ' @change="' + evAttr(id, 'OnChange', '{val:String(' + r + '.val)}') + '"/>';

            case 'floatspin':
                return '<input type="number" class="lw-input" style="' + fs + '" x-model.number="' + r + '.val"' +
                    (node.min != null ? ' min="' + node.min + '"' : '') + (node.max != null ? ' max="' + node.max + '"' : '') +
                    ' step="' + (node.decimals != null ? Math.pow(10, -node.decimals) : 0.01) + '" ' + dis +
                    ' @change="' + evAttr(id, 'OnChange', '{val:String(' + r + '.val)}') + '"/>';

            case 'dateedit':
                return '<input type="date" class="lw-input" style="' + fs + '" x-model="' + r + '.iso"' + ro + ' ' + dis +
                    ' @change="' + evAttr(id, 'OnChange', '{val:' + r + '.iso}') + '"/>';

            case 'timeedit':
                return '<input type="time" step="1" class="lw-input" style="' + fs + '" x-model="' + r + '.iso"' + ro + ' ' + dis +
                    ' @change="' + evAttr(id, 'OnChange', '{val:' + r + '.iso}') + '"/>';

            case 'checkbox':
            case 'dbcheckbox':
                return '<label class="lw-cb" style="' + fs + '"><input type="checkbox" x-model="' + r + '.chk" ' + dis +
                    ' x-effect="if(' + r + '.ind) $el.indeterminate = true"' +
                    ' @change="' + evAttr(id, 'OnChange', '{val:' + r + '.chk ? \'1\' : \'0\'}') + '"/>' +
                    '<span x-text="' + r + '.cap"></span></label>';

            case 'radio':
                return '<label class="lw-cb" style="' + fs + '"><input type="radio" name="lwradio_' +
                    (node.group || 'g') + '" :checked="' + r + '.chk" ' + dis +
                    ' @click="' + r + '.chk = true; ' + evAttr(id, 'OnClick') + '" ' +
                    '@change="' + evAttr(id, 'OnChange', '{val:' + r + '.chk ? \'1\' : \'0\'}') + '"/>' +
                    '<span x-text="' + r + '.cap"></span></label>';

            case 'combo':
            case 'dbcombo': {
                var dl = 'lw-dl-' + id;
                if (node.editable === false) {
                    return '<select class="lw-select" style="' + fs + '" x-model="' + r + '.txt" ' + dis +
                        ' @change="' + evAttr(id, 'OnChange', '{val:' + r + '.txt}') + '">' +
                        '<template x-for="(t,i) in ' + r + '.items" :key="i"><option :value="t" x-text="t" :selected="t===' + r + '.txt"></option></template></select>';
                }
                return '<input type="text" class="lw-input" style="' + fs + '" list="' + dl + '" x-model="' + r + '.txt" ' + dis +
                    ' @change="' + evAttr(id, 'OnChange', '{val:' + r + '.txt}') + '"/>' +
                    '<datalist id="' + dl + '"><template x-for="(t,i) in ' + r + '.items" :key="i"><option :value="t"></option></template></datalist>';
            }

            case 'dblookup':
                return '<select class="lw-select" style="' + fs + '" x-model="' + r + '.key" ' + dis +
                    ' @change="' + evAttr(id, 'OnChange', '{val:' + r + '.key}') + '">' +
                    '<template x-for="(t,i) in ' + r + '.items" :key="i"><option :value="String(' + r + '.keys[i] == null ? \'\' : ' + r + '.keys[i])" x-text="t"></option></template></select>';

            case 'listbox':
            case 'dblistbox':
            case 'dblookuplist': {
                var selExp = k === 'dblookuplist' ? '$lwLkClick(\'' + id + '\',i)' : '$lwLbClick(\'' + id + '\',i,\'' + (k === 'listbox' ? '' : 'sel') + '\')';
                return '<div class="lw-list' + (node.border !== 'none' ? ' lw-boxed' : '') + '">' +
                    '<template x-for="(t,i) in ' + r + '.items" :key="i">' +
                    '<div class="lw-list-item" :class="i===' + r + '.idx ? \'lw-sel\' : \'\'" @click="' + selExp + '">' +
                    '<span x-text="t"></span></div></template></div>';
            }

            case 'radiogroup': {
                var rgIn = '<template x-for="(t,i) in ' + r + '.items" :key="i">' +
                    '<label class="lw-cb"><input type="radio" name="lwrg-' + id + '" :checked="i===' + r + '.idx" ' + dis +
                    ' @click="' + r + '.idx = i; ' + evAttr(id, 'OnClick', '{val:String(i)}') + '"/>' +
                    '<span x-text="t"></span></label></template>';
                return '<div class="lw-group' + (node.border !== 'none' ? ' lw-boxed' : '') + '">' +
                    '<div class="lw-group-title" x-text="' + r + '.cap"></div>' +
                    '<div class="lw-group-body">' + rgIn + '</div></div>';
            }

            case 'dbradiogroup': {
                /* 单选组（DB）：Values[i] 才是写进字段的值（状态放 keys 位） */
                var drgIn = '<template x-for="(t,i) in ' + r + '.items" :key="i">' +
                    '<label class="lw-cb"><input type="radio" name="lwdrg-' + id + '" ' + dis +
                    ' :checked="String(' + r + '.keys[i] == null ? i : ' + r + '.keys[i]) === String(' + r + '.val)"' +
                    ' @click="' + r + '.val = String(' + r + '.keys[i] == null ? i : ' + r + '.keys[i]); ' +
                    evAttr(id, 'OnChange', '{val:' + r + '.keys[i] == null ? String(i) : String(' + r + '.keys[i])}') + '"/>' +
                    '<span x-text="t"></span></label></template>';
                return '<div class="lw-group' + (node.border !== 'none' ? ' lw-boxed' : '') + '">' +
                    '<div class="lw-group-title" x-text="' + r + '.cap"></div>' +
                    '<div class="lw-group-body">' + drgIn + '</div></div>';
            }

            case 'checkgroup':
                return '<div class="lw-group' + (node.border !== 'none' ? ' lw-boxed' : '') + '">' +
                    '<div class="lw-group-title" x-text="' + r + '.cap"></div>' +
                    '<div class="lw-group-body">' +
                    '<template x-for="(t,i) in ' + r + '.items" :key="i">' +
                    '<label class="lw-cb"><input type="checkbox" x-model="' + r + '.checked[i]" ' + dis +
                    ' @change="' + evAttr(id, 'OnItemClick', '{idx:i, val:' + r + '.checked[i] ? \'1\' : \'0\', checked:' + r + '.checked.slice()}') + '"/>' +
                    '<span x-text="t"></span></label></template></div></div>';

            case 'checklistbox':
                return '<div class="lw-list lw-boxed lw-clb">' +
                    '<template x-for="(t,i) in ' + r + '.items" :key="i">' +
                    '<label class="lw-cb lw-clb-item"><input type="checkbox" x-model="' + r + '.checked[i]" ' + dis +
                    ' @change="' + evAttr(id, 'OnClickCheck', '{val:String(i), checked:' + r + '.checked.slice()}') + '" ' +
                    '@click="$lwSet(\'' + id + '\',\'idx\', i); ' + evAttr(id, 'OnClick', '{val:String(i)}') + '"/>' +
                    '<span x-text="t"></span></label></template></div>';

            case 'progress':
                return '<div class="lw-prog">' +
                    '<div class="lw-prog-bar" :style="\'width:\' + (' + r + '.max ? Math.min(100, ' + r + '.pos * 100 / ' + r + '.max) : 0) + \'%\'"></div>' +
                    '<div class="lw-prog-text" x-text="' + r + '.pos + \' / \' + ' + r + '.max"></div></div>';

            case 'trackbar':
                return '<input type="range" class="lw-range' + (node.orientation === 1 ? ' lw-vrange' : '') +
                    '" x-model.number="' + r + '.val" min="' + (node.min || 0) + '" max="' + (node.max == null ? 100 : node.max) +
                    '" ' + dis + ' @change="' + evAttr(id, 'OnChange', '{val:String(' + r + '.val)}') + '"/>';

            case 'updown':
                return '<input type="number" class="lw-input lw-updown" x-model.number="' + r + '.val"' +
                    (node.min != null ? ' min="' + node.min + '"' : '') + (node.max != null ? ' max="' + node.max + '"' : '') +
                    ' ' + dis + ' @change="' + evAttr(id, 'OnClick', '{val:String(' + r + '.val)}') + '"/>';

            case 'grid':
            case 'drawgrid':
            case 'listview': {
                if (k === 'listview') {
                    return '<div class="lw-grid lw-boxed"><table class="lw-table"><thead><tr>' +
                        '<template x-for="(c,j) in ' + r + '.cols" :key="j"><th x-text="c"></th></template>' +
                        '</tr></thead><tbody>' +
                        '<template x-for="(row,i) in ' + r + '.rows" :key="i">' +
                        '<tr :class="i===' + r + '.idx ? \'lw-sel\' : \'\'" @click="$lwLvClick(\'' + id + '\',i)">' +
                        '<template x-for="(cell,j) in row" :key="j">' +
                        '<td x-text="cell"></td>' +
                        '</template></tr></template></tbody></table></div>';
                }
                /* rowheight/colwidths：writer 按 LCL RowHeights/ColWidths 下发，
                   之前整块忽略 -> TDrawGrid 行被压成几像素（坑 95）。
                   readonly=false（goEditing 开）时点单元格就地编辑（对齐 Ext
                   版 CellEditing clicksToEdit:1），提交回发 OnEditingDone。
                   注意 colwidths 是构建期常量：必须用循环生成 th，
                   不能在模板字符串里引用 x-for 的运行时变量（j is not defined） */
                var grh = node.rowheight || 22;
                var gw = node.colwidths || [];
                var ths = '';
                (node.cols || []).forEach(function (c, j) {
                    var st = 'height:' + grh + 'px';
                    if (gw[j] > 0) st += ';width:' + gw[j] + 'px;min-width:' + gw[j] + 'px';
                    ths += '<th style="' + st + '" x-text="' + r + '.cols[' + j + ']"></th>';
                });
                /* drawgrid 单元格支持自绘标记（@bar/@chip/@spark/@stars），
                   由 $lwDrawCell 解析成 HTML；TStringGrid 保持纯文本 x-text */
                var cellTd = (k === 'drawgrid')
                    ? '<td style="height:' + grh + 'px" @click="$lwGridCellClick($el, \'' + id + '\', i, j)" x-html="$lwDrawCell(cell)"></td>'
                    : '<td style="height:' + grh + 'px" @click="$lwGridCellClick($el, \'' + id + '\', i, j)" x-text="cell"></td>';
                return '<div class="lw-grid lw-boxed"><table class="lw-table"><thead><tr>' + ths +
                    '</tr></thead><tbody>' +
                    '<template x-for="(row,i) in ' + r + '.rows" :key="i">' +
                    '<tr :class="i===' + r + '.idx ? \'lw-sel\' : \'\'">' +
                    '<template x-for="(cell,j) in row" :key="j">' +
                    cellTd +
                    '</template></tr></template></tbody></table></div>';
            }

            case 'valeditor':
                return '<div class="lw-grid lw-boxed"><table class="lw-table lw-ve"><thead><tr>' +
                    '<th class="lw-ve-key" x-text="' + r + '.t0"></th><th x-text="' + r + '.t1"></th></tr></thead><tbody>' +
                    '<template x-for="(k,i) in ' + r + '.keys" :key="i">' +
                    '<tr :class="i===' + r + '.idx ? \'lw-sel\' : \'\'" @click="$lwVeClick(\'' + id + '\', i)">' +
                    '<td class="lw-ve-key" x-text="k"></td>' +
                    '<td class="lw-ve-edit" @click.stop="$lwVeEdit($el, \'' + id + '\', i)" x-text="' + r + '.values[i]"></td>' +
                    '</tr></template></tbody></table></div>';

            case 'tree':
                /* 递归结构 Alpine 模板写不了，整棵由 renderTree 生成 */
                return '<div class="lw-tree' + (node.border !== 'none' ? ' lw-boxed' : '') + '" id="lw-tree-' + id + '"></div>';

            case 'dbgrid': {
                var dgid = id;
                var filterBar = node.showfilter
                    ? '<div class="lw-grid-filter"><span>过滤:</span><input type="text" class="lw-input" placeholder="输入关键字后回车…" ' + dis +
                      ' x-model="' + r + '.ftext" @keydown.enter.prevent="' + evAttr(dgid, 'OnFilter', '{val:' + r + '.ftext}') + '"/></div>'
                    : '';
                var pagerBar = ((node.pages || 0) > 1 || node.summary)
                    ? '<div class="lw-grid-pager">' +
                      ((node.pages || 0) > 1
                          ? '<button type="button" class="lw-btn lw-pg" @click="$lwPage(\'' + dgid + '\',1)">⏮</button>' +
                            '<button type="button" class="lw-btn lw-pg" @click="$lwPage(\'' + dgid + '\',' + r + '.page - 1)">◀</button>' +
                            '<span class="lw-pg-text" x-text="' + r + '.pgtext"></span>' +
                            '<button type="button" class="lw-btn lw-pg" @click="$lwPage(\'' + dgid + '\',' + r + '.page + 1)">▶</button>' +
                            '<button type="button" class="lw-btn lw-pg" @click="$lwPage(\'' + dgid + '\',' + r + '.pages)">⏭</button>'
                          : '') +
                      (node.summary ? '<span class="lw-pg-text" x-text="' + r + '.sumtext"></span>' : '') +
                      '</div>'
                    : '';
                return '<div class="lw-dbgrid">' + filterBar +
                    '<div class="lw-grid lw-boxed lw-dbgrid-body"><table class="lw-table"><thead><tr>' +
                    '<template x-for="(c,j) in ' + r + '.cols" :key="j">' +
                    '<th @click="' + evAttr(dgid, 'OnTitleClick', '{col:j}') + '" x-text="c"></th></template>' +
                    '</tr></thead><tbody>' +
                    '<template x-for="(row,i) in ' + r + '.rows" :key="i">' +
                    '<tr :class="i === ' + r + '.recno - 1 ? \'lw-sel\' : \'\'" @click="$lwDbRow(\'' + dgid + '\', i, $event)">' +
                    '<template x-for="(cell,j) in row" :key="j">' +
                    dbCellTd(dgid) +
                    '</template></tr></template></tbody></table></div>' + pagerBar + '</div>';
            }

            case 'dbnav': {
                var GLYPH = { first: '|◀', prior: '◀', next: '▶', last: '▶|', insert: '＋', 'delete': '✖', edit: '✎', post: '✓', cancel: '↶', refresh: '↻' };
                var TIP = { first: '第一条', prior: '上一条', next: '下一条', last: '最后一条', insert: '插入', 'delete': '删除', edit: '编辑', post: '保存', cancel: '取消', refresh: '刷新' };
                var nav = '';
                (node.buttons || []).forEach(function (b) {
                    nav += '<button type="button" class="lw-btn lw-nav"' + (b.en === false ? ' disabled' : '') +
                        ' title="' + esc(TIP[b.id] || b.id) + '" data-navid="' + esc(b.id) + '" ' + dis +
                        ' @click="' + evAttr(id, 'OnClick', '{val:\'' + esc(b.id) + '\'}') + '">' + (GLYPH[b.id] || esc(b.id)) + '</button>';
                });
                /* 按钮禁用态由服务端按数据集状态下发：patch 时同步 */
                return '<div class="lw-nav">' + nav + '</div>';
            }

            case 'image':
            case 'dbimage':
                return '<img class="lw-img" :src="' + r + '.src" :style="' + r + '.src ? \'\' : \'visibility:hidden\'" @click="' + evAttr(id, 'OnClick') + '"/>';

            case 'htmlframe':
            case 'pdfframe':
            case 'chart': {
                /* TLWHTMLFrame / TLWPDFFrame / TLWChart：宿主都是 TCustomPanel，
                   边框跟随 LCL 的 BevelOuter（默认 bvRaised）+ BorderStyle。
                   bevel 未下发（旧服务端）时按 LCL 默认值 bvRaised 处理 ——
                   默认有边框；BevelOuter=bvNone 且 BorderStyle=bsNone 才是无边框 */
                var fNoBev = (node.bevel === 0 || node.bevel === 'none') && node.border !== 'single';
                var fCls = fNoBev ? '' : ' lw-boxed';
                var fPfx = k === 'htmlframe' ? 'hf' : (k === 'pdfframe' ? 'pdf' : 'ch');
                return '<div class="lw-' + k + fCls + '" id="lw-' + fPfx + '-' + id + '"></div>';
            }

            case 'chart':
                return '<div class="lw-chart lw-boxed" id="lw-ch-' + id + '"></div>';

            case 'gauge':
                return '<div class="lw-gauge" id="lw-gauge-' + id + '"></div>';

            case 'color':
                return '<div class="lw-swatch" style="background:' + esc(node.value || '#ffffff') +
                    ';cursor:pointer" @click="$lwPickColor(\'' + id + '\')"></div>';

            case 'panel':
            case 'scrollbox':
            case 'frame':
                { /* TPanel/TScrollBox/TFrame：bevel(bvRaised/bvLowered) 映射边框，
                    caption 非缺省值时居中显示（设计器里 Caption=控件名的不渲染，
                    服务端已过滤，这里双保险），scrollbox 内容超出视口必须可滚
                    （LCL ScrollBox 的滚动语义，否则超出部分"看不见"） */
                  var bevCls = (node.border === 'single' || node.bevel) ? ' lw-boxed' : '';
                  var pOvf = (node.autoscroll || k === 'scrollbox') ? ';overflow:auto' : '';
                  var pCap = (node.caption && node.caption !== node.name) ?
                      '<div class="lw-panel-cap" x-text="' + r + '.cap"></div>' : '';
                  return '<div class="lw-body' + bevCls +
                      '" style="background:' + (node.bg || 'transparent') + pOvf +
                      '">' + pCap + '<div class="lw-kids"></div></div>';
                }

            case 'groupbox':
                /* TGroupBox：AutoScroll=false 时 LCL 只裁剪不滚动。
                   恒 overflow:auto 会因映射误差（标题条高度近似）伪造出
                   比控件矮一大截的滚动条（AutoScroll 关着却出现滚动条） */
                return '<div class="lw-group lw-group-abs' + (node.border !== 'none' ? ' lw-boxed' : '') + '">' +
                    '<div class="lw-group-title" x-text="' + r + '.cap"></div>' +
                    '<div class="lw-body lw-group-body" style="overflow:' + (node.autoscroll ? 'auto' : 'hidden') +
                    '"><div class="lw-kids"></div></div></div>';

            case 'tabs':
                return '<div class="lw-tabs"><div class="lw-tabbar" id="lw-tabbar-' + id + '"></div>' +
                    '<div class="lw-tabs-body lw-boxed"></div></div>';

            case 'tabctl':
                return '<div class="lw-tabs"><div class="lw-tabbar" id="lw-tabbar2-' + id + '"></div>' +
                    '<div class="lw-tabs-body lw-boxed lw-tabcard"><div class="lw-kids"></div></div></div>';

            case 'tabsheet':
                return '<div class="lw-tabcard"><div class="lw-kids"></div></div>';

            case 'toolbar':
                return '<div class="lw-tbar"><div class="lw-kids lw-kids-flow"></div></div>';

            case 'statusbar':
                return '<div class="lw-status" x-text="' + r + '.txt"></div>';

            case 'bevel':
                return '<div class="lw-bevel"></div>';

            case 'shape': {
                var srad = { 2: '10px', 3: '10px', 4: '50%', 5: '50%' }[node.shapestyle];
                return '<div style="width:100%;height:100%;background:' + (node.bg || '#ffffff') +
                    ';border:1px solid rgba(0,0,0,.35);' + (srad ? 'border-radius:' + srad + ';' : '') + '"></div>';
            }

            case 'splitter':
                return '<div class="lw-splitter"></div>';

            default:
                return '<div class="lw-unknown" title="' + esc(node.cls || '') + '">' + esc(node.cls || node.kind) + '</div>';
        }
    }

    /* ---------------- 交互辅助（模板里引用） ---------------- */

    window.$lwLvClick = function (id, i) {
        var r = S.R[id];
        if (!r) return;
        r.idx = i;
        if ($lwHas(id, 'OnClick')) fire(id, 'OnClick', { val: String(i) });
    };

    /* ---------------- drawgrid 单元格自绘标记 ----------------
       nogui 是无头 widgetset（假 DC），LCL 级 OnDrawCell 画不出像素，
       自绘只能在浏览器端做：服务端往 Cells 里放标记字符串，
       这里解析成 HTML（进度条/徽章/迷你图/星级），纯文本原样转义。
       标记语法（大小写敏感，必须整格以 @ 开头）：
         @bar(72)          @bar(72,#dc2626)      进度条（0-100，缺省蓝色）
         @chip(通过,#16a34a)                    彩色徽章（颜色可省）
         @spark(4,6,3,8,5) @spark(4,6,3,#16a34a) 迷你折线图（末参为 #色 时是颜色）
         @stars(4.5)                             星级评分（0-5） */
    window.$lwDrawCell = function (cell) {
        var s = String(cell == null ? '' : cell);
        if (s.charAt(0) !== '@') return esc(s);
        var i = s.indexOf('('), j = s.lastIndexOf(')');
        if (i < 1 || j <= i) return esc(s);
        var kind = s.slice(0, i);
        var parts = s.slice(i + 1, j).split(',');
        var colorOf = function (v, def) {
            v = String(v || '').trim();
            return (/^#[0-9a-fA-F]{3,8}$/.test(v)) ? v : def;
        };
        var k;
        if (kind === '@bar') {
            var pct = parseFloat(parts[0]);
            if (isNaN(pct)) return esc(s);
            pct = Math.max(0, Math.min(100, pct));
            var bc = colorOf(parts[1], '#2563eb');
            return '<div class="lw-cbar"><div class="lw-cbar-fill" style="width:' + pct +
                '%;background:' + bc + '"></div><span class="lw-cbar-text">' + pct + '%</span></div>';
        }
        if (kind === '@chip') {
            var cc = colorOf(parts[1], '#2563eb');
            return '<span class="lw-chip" style="color:' + cc + ';background:' + cc +
                '22;border-color:' + cc + '">' + esc(String(parts[0] || '').trim()) + '</span>';
        }
        if (kind === '@stars') {
            var v = parseFloat(parts[0]);
            if (isNaN(v)) return esc(s);
            v = Math.max(0, Math.min(5, v));
            var full = Math.floor(v), half = (v - full) >= 0.5;
            var out = '<span class="lw-stars">';
            for (k = 0; k < 5; k++) {
                out += '<span class="' + (k < full || (k === full && half) ? 'lw-star-on' : 'lw-star-off') +
                    '">' + (k < full ? '★' : (k === full && half ? '⯪' : '★')) + '</span>';
            }
            return out + '<span class="lw-star-text">' + v + '</span></span>';
        }
        if (kind === '@spark') {
            var sc = colorOf(parts[parts.length - 1], null);
            var vals = (sc ? parts.slice(0, -1) : parts).map(parseFloat).filter(function (x) { return !isNaN(x); });
            if (vals.length < 2) return esc(s);
            var W = 120, H = 22, P = 3;
            var mn = Math.min.apply(null, vals), mx = Math.max.apply(null, vals);
            var rng = (mx - mn) || 1;
            var pts = vals.map(function (x, n) {
                var px = P + n * (W - 2 * P) / (vals.length - 1);
                var py = H - P - (x - mn) * (H - 2 * P) / rng;
                return px.toFixed(1) + ',' + py.toFixed(1);
            }).join(' ');
            var lx = pts.split(' ')[vals.length - 1].split(',');
            return '<svg class="lw-spark" width="' + W + '" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '">' +
                '<polyline fill="none" stroke="' + (sc || '#2563eb') + '" stroke-width="1.5" points="' + pts + '"/>' +
                '<circle cx="' + lx[0] + '" cy="' + lx[1] + '" r="2.2" fill="' + (sc || '#2563eb') + '"/></svg>';
        }
        return esc(s);
    };

    window.$lwGridCellClick = function (td, id, row, col) {
        var n = S.ND[id], r = S.R[id];
        /* TStringGrid/TDrawGrid 行选中高亮（对齐 Ext 版行选择） */
        if (r) r.idx = row;
        if ($lwHas(id, 'OnClick')) fire(id, 'OnClick', { row: row, col: col });
        if ($lwHas(id, 'OnCellClick')) fire(id, 'OnCellClick', { row: row, col: col });
        /* goEditing 开（writer 下发 readonly=false）时单击就地编辑，
           提交回发 OnEditingDone —— 服务端 LWApplyValue 会把值写进
           TStringGrid.Cells[col,row]（row 自动加回 FixedRows） */
        if (!n || n.readonly) return;
        if (td.__lwEditing) return;
        var old = (r.rows || [])[row] ? r.rows[row][col] : '';
        td.__lwEditing = true;
        var inp = document.createElement('input');
        inp.type = 'text';
        inp.className = 'lw-input';
        inp.value = old == null ? '' : String(old);
        td.textContent = '';
        td.appendChild(inp);
        inp.focus();
        inp.select();
        function commit() {
            if (!td.__lwEditing) return;
            td.__lwEditing = false;
            var v = inp.value;
            td.textContent = v;
            if (r.rows && r.rows[row]) r.rows[row][col] = v;
            if (v !== String(old == null ? '' : old)) {
                fire(id, 'OnEditingDone', { val: v, row: row, col: col });
            }
        }
        inp.addEventListener('blur', commit);
        inp.addEventListener('keydown', function (e) {
            if (e.key === 'Enter') { e.preventDefault(); inp.blur(); }
            if (e.key === 'Escape') {
                td.__lwEditing = false;
                td.textContent = old == null ? '' : String(old);
            }
        });
    };

    window.$lwVeClick = function (id, row) {
        var r = S.R[id];
        if (!r) return;
        r.idx = row;
        if ($lwHas(id, 'OnClick')) fire(id, 'OnClick', { val: String(row), row: row });
    };

    /* 键值编辑器：点值格 -> 就地换成输入框，blur/回车提交 OnValidate */
    window.$lwVeEdit = function (td, id, row) {
        if (td.__lwEditing) return;
        var r = S.R[id];
        if (!r) return;
        var old = (r.values || [])[row];
        td.__lwEditing = true;
        var inp = document.createElement('input');
        inp.type = 'text';
        inp.className = 'lw-input';
        inp.value = old == null ? '' : String(old);
        td.textContent = '';
        td.appendChild(inp);
        inp.focus();
        inp.select();
        function commit() {
            if (!td.__lwEditing) return;
            td.__lwEditing = false;
            var v = inp.value;
            td.textContent = v;
            if (v !== String(old == null ? '' : old)) {
                fire(id, 'OnValidate', { row: row, key: (r.keys || [])[row], val: v });
            }
        }
        inp.addEventListener('blur', commit);
        inp.addEventListener('keydown', function (e) {
            if (e.key === 'Enter') { e.preventDefault(); inp.blur(); }
            if (e.key === 'Escape') { td.__lwEditing = false; td.textContent = old == null ? '' : String(old); }
        });
    };

    /* DBGrid：行点击定位数据集游标；可编辑列点击开编辑器 */
    window.$lwDbRow = function (id, row, e) {
        if ($lwHas(id, 'OnCellClick')) fire(id, 'OnCellClick', { row: row, col: 0 });
    };

    /* DBGrid 布尔列（服务端 cedit=4）：单元格常驻勾选框，点一下即写回
       '1'/'0'，走与文本编辑同一条 OnSetFieldValue 通道 —— 服务端
       LWApplyDBGridEdit 用 AsBoolean 赋值。勾选框自己处理点击，
       不再进 $lwDbCell 的"就地换编辑器"分支。 */
    window.$lwChk = function (id, col) {
        var n = S.ND[id];
        if (!n || n.readonly) return false;
        return ((n.cedit || [])[col]) === 4;
    };

    window.$lwChkTap = function (id, row, col, e) {
        var el = e.currentTarget;
        var v = el.checked ? '1' : '0';
        var r = S.R[id];
        /* 本地行数据先改，服务端确认后的树补丁会覆盖成权威值 */
        if (r && r.rows && r.rows[row]) r.rows[row][col] = v;
        fire(id, 'OnSetFieldValue', { val: v, row: row, col: col });
    };

    window.$lwDbCell = function (id, row, col, e) {
        if ($lwHas(id, 'OnCellClick')) fire(id, 'OnCellClick', { row: row, col: col });
        var n = S.ND[id], r = S.R[id];
        if (!n || n.readonly || !r) return;
        /* 列编辑器类型（服务端 cedit）：0=只读 1=文本 2=PickList 下拉
           3=日期选择 4=复选框。旧服务端只发 0/1，缺省当文本。 */
        var et = (n.cedit || [])[col];
        if (et === 0 || et === 4) return;
        if (et == null) et = 1;
        var td = e.currentTarget;
        if (td.__lwEditing) return;
        var old = (r.rows || [])[row] ? (r.rows[row][col]) : '';
        td.__lwEditing = true;
        var inp;
        if (et === 2) {
            /* 下拉：服务端 TColumn.PickList（plist 按列下标带选项） */
            inp = document.createElement('select');
            inp.className = 'lw-input';
            var items = ((n.plist || [])[col]) || [];
            if (!items.length) items = [old == null ? '' : String(old)];
            items.forEach(function (it) {
                var op = document.createElement('option');
                op.value = it;
                op.textContent = it;
                if (String(it) === String(old == null ? '' : old)) op.selected = true;
                inp.appendChild(op);
            });
        } else {
            inp = document.createElement('input');
            inp.className = 'lw-input';
            if (et === 3) {
                /* 日期：服务端日期列发的就是 ISO 'yyyy-mm-dd' */
                inp.type = 'date';
                inp.value = old == null ? '' : String(old).substring(0, 10);
            } else {
                inp.type = 'text';
                inp.value = old == null ? '' : String(old);
                inp.select();
            }
        }
        td.textContent = '';
        td.appendChild(inp);
        inp.focus();
        function commit() {
            if (!td.__lwEditing) return;
            td.__lwEditing = false;
            var v = inp.value;
            td.textContent = v;
            /* 本地行数据跟着改，服务端确认后的树补丁会覆盖成权威值 */
            if (r.rows && r.rows[row]) r.rows[row][col] = v;
            if (v !== String(old == null ? '' : old)) {
                fire(id, 'OnSetFieldValue', { val: v, row: row, col: col });
            }
        }
        inp.addEventListener('blur', commit);
        /* 下拉/日期：选中或选好日期即提交（change -> blur 走同一提交） */
        if (et === 2 || et === 3) {
            inp.addEventListener('change', function () { inp.blur(); });
        } else {
            inp.addEventListener('keydown', function (e2) {
                if (e2.key === 'Enter') { e2.preventDefault(); inp.blur(); }
                if (e2.key === 'Escape') {
                    td.__lwEditing = false;
                    td.textContent = old == null ? '' : String(old);
                }
            });
        }
    };

    /* DBGrid 翻页（从最新节点取页号，闭包里的 node 是快照） */
    window.$lwPage = function (id, p) {
        var n = S.ND[id];
        if (!n) return;
        p = Math.min(Math.max(1, p), n.pages || 1);
        if (p === (n.page || 1)) return;
        fire(id, 'OnPageChange', { val: String(p) });
    };

    /* 文件上传按钮 */
    window.pickUpload = function (id) {
        var n = S.ND[id];
        if (n) pickFile(n);
    };

    /* ---------------- 树（递归结构用命令式 DOM 生成） ---------------- */

    function treeConv(list, out, counter) {
        (list || []).forEach(function (n) {
            var me = counter.n++;
            out.push({ i: me, text: n.text, expanded: !!n.expanded, sel: !!n.selected,
                kids: treeConv(n.children, [], counter) });
        });
        return out;
    }

    function renderTree(id) {
        var n = S.ND[id];
        var host = document.getElementById('lw-tree-' + id);
        if (!n || !host) return;
        var flat = [];
        treeConv(n.nodes, flat, { n: 0 });
        var html = '';
        (function walk(nodes, depth) {
            nodes.forEach(function (nd) {
                /* 服务端 selected（LCL Selected）也要渲染成高亮：
                   点击回发后服务端选中态变化 -> 树 JSON 指纹变化 -> 重渲染，
                   若不渲染 selected，刚点的选中就被这次重渲染抹掉（坑 94） */
                html += '<div class="lw-tree-node' + (nd.sel ? ' lw-sel' : '') + '" style="padding-left:' + (depth * 16) + 'px" data-tid="' + nd.i + '">' +
                    (nd.kids.length
                        ? '<span class="lw-tree-tw' + (nd.expanded ? ' lw-open' : '') + '"></span>'
                        : '<span class="lw-tree-tw lw-leaf"></span>') +
                    '<span class="lw-tree-text">' + esc(nd.text) + '</span></div>';
                if (nd.expanded) walk(nd.kids, depth + 1);
            });
        })(flat, 0);
        host.innerHTML = html;
        host.__lwFlat = flat;
        host.querySelectorAll('.lw-tree-node').forEach(function (el) {
            var tid = parseInt(el.getAttribute('data-tid'), 10);
            el.addEventListener('click', function (e) {
                var nd = host.__lwFlat.filter(function (x) { return x.i === tid; })[0];
                if (nd && nd.kids.length && e.target.classList.contains('lw-tree-tw')) {
                    nd.expanded = !nd.expanded;
                    renderTree(id);
                    return;
                }
                host.querySelectorAll('.lw-tree-node.lw-sel').forEach(function (x) { x.classList.remove('lw-sel'); });
                el.classList.add('lw-sel');
                if ($lwHas(id, 'OnClick')) fire(id, 'OnClick', { val: String(tid) });
            });
        });
    }

    /* ---------------- 主菜单 / 右键菜单 ---------------- */

    function closeAllMenus() {
        document.querySelectorAll('.lw-menu-pop').forEach(function (m) { m.remove(); });
    }

    function menuPopHtml(items) {
        var h = '<div class="lw-menu-pop">';
        (items || []).forEach(function (m) {
            if (m.sep) { h += '<div class="lw-menu-sep"></div>'; return; }
            h += '<div class="lw-menu-item' + (m.enabled === false ? ' lw-disabled' : '') +
                (m.items && m.items.length ? ' lw-has-sub' : '') + '" data-mid="' + esc(m.caption || '') + '">' +
                esc(m.caption || '') + (m.shortcut ? '<span class="lw-mn">' + esc(m.shortcut) + '</span>' : '') +
                (m.checked ? '<span class="lw-menu-check">✓</span>' : '') + '</div>';
        });
        return h + '</div>';
    }

    function bindMenuPop(host, items) {
        host.querySelectorAll('.lw-menu-item').forEach(function (el, i) {
            var m = items[i];
            if (!m || m.sep) return;
            el.addEventListener('click', function (e) {
                e.stopPropagation();
                if (m.enabled === false) return;
                closeAllMenus();
                fire(m, 'OnClick');
            });
            if (m.items && m.items.length) {
                el.addEventListener('mouseenter', function () {
                    closeSubMenus(el);
                    var sub = document.createElement('div');
                    sub.innerHTML = menuPopHtml(m.items);
                    var pop = sub.firstChild;
                    document.body.appendChild(pop);
                    var r = el.getBoundingClientRect();
                    pop.style.left = (r.right - 2) + 'px';
                    pop.style.top = r.top + 'px';
                    bindMenuPop(pop, m.items);
                });
            }
        });
    }

    function closeSubMenus(el) {
        var p = el.closest('.lw-menu-pop');
        document.querySelectorAll('.lw-menu-pop').forEach(function (m) {
            if (m !== p && !p.contains(m) && !m.contains(p)) m.remove();
        });
    }

    /* ---------------- 节点创建 / 子节点同步 ---------------- */

    function createNode(node, ct) {
        var id = node.id, k = node.kind;
        var w = document.createElement('div');
        w.className = 'lw-n';
        w.setAttribute('data-lwid', id);
        var st = stateOf(node);
        S.K[id] = k;
        S.ND[id] = node;
        S.EV[id] = node.ev || [];
        S.E[id] = w;
        S.P[id] = ct.body;
        S.WIN[id] = ct.winId;
        if (node.name) S.NAME[node.name] = id;

        try {
            w.innerHTML = innerOf(node, st);
        } catch (e) {
            log('create failed', k, node.name, e);
            w.innerHTML = '<div class="lw-unknown">' + esc(node.cls || k) + '</div>';
        }
        ct.body.appendChild(w);
        if (ct.flow) w.classList.add('lw-flow');

        try { if (window.Alpine) Alpine.initTree(w); } catch (e) { }
        placeNode(id, node);
        applyHint(id, node);
        bindNodeEvents(id, node, w);

        /* 容器：递归渲染子节点 */
        if (isContainer(node)) {
            var body = w.querySelector('.lw-kids') || w.querySelector('.lw-body') || w;
            if (k === 'tabs') body = w.querySelector('.lw-tabs-body');
            syncChildren({ body: body, winId: ct.winId, flow: (k === 'toolbar'), parentKind: k, parentId: id }, node);
            if (k === 'tabs') buildTabbar(id, node);
            if (k === 'tabctl') buildTabCtl(id, node);
        }
        /* 后补进来的页签：不在活动页就先藏起来 */
        if (k === 'tabsheet' && ct.parentKind === 'tabs') {
            var pn = S.ND[ct.parentId] || {};
            var act = (typeof pn.active === 'number') ? pn.active : 0;
            var myIdx = 0;
            var sibs = w.parentNode ? Array.prototype.slice.call(w.parentNode.children) : [];
            for (var si = 0; si < sibs.length; si++) if (sibs[si] === w) { myIdx = si; break; }
            if (myIdx !== act) w.style.display = 'none';
        }
        /* 非响应式区块的首绘 */
        if (k === 'tree') renderTree(id);
        if (k === 'gauge') {
            var g = document.getElementById('lw-gauge-' + id);
            if (g) { g.innerHTML = gaugeSvg(node); g.__lwSig = gaugeSig(node); }
        }
        if (k === 'chart') {
            var ch = document.getElementById('lw-ch-' + id);
            if (ch) { ch.innerHTML = chartSvg(node); ch.__lwSig = chartSig(node); }
        }
        if (k === 'htmlframe') {
            var hf = document.getElementById('lw-hf-' + id);
            if (hf) {
                hf.innerHTML = node.html || '';
                hf.__lwSig = node.html || '';
                execHtmlScripts(hf);
            }
        }
        if (k === 'pdfframe') {
            renderPdf(id, node);
        }
        if (k === 'image' || k === 'dbimage') {
            if (!node.src) { var im = w.querySelector('img'); if (im) im.style.visibility = 'hidden'; }
        }
        if (k === 'dbgrid') syncDbGridExtras(id, node);
        return w;
    }

    function renderPdf(id, node) {
        var host = document.getElementById('lw-pdf-' + id);
        if (!host) return;
        host.__lwUrlSig = node.url || '';
        if (node.url) {
            host.innerHTML = '<iframe src="' + esc(node.url) + '" frameborder="0" style="width:100%;height:100%;border:0"></iframe>';
        } else {
            host.innerHTML = '<div class="lw-unknown">PDF：尚未指定文件</div>';
        }
    }

    /* dbgrid 的分页/汇总文案状态 */
    function pagerTextOf(n) {
        var total = (n.total != null ? n.total : (n.count || 0));
        if ((n.pages || 0) > 1)
            return '第 ' + (n.page || 1) + ' / ' + n.pages + ' 页 · 共 ' + total + ' 条';
        return '共 ' + total + ' 条';
    }
    function summaryTextOf(sm) {
        var names = { sum: '合计', avg: '平均', count: '计数' };
        return (names[sm.type] || '') + ' ' + (sm.field || '') + ' = ' + (sm.value == null ? '' : sm.value);
    }
    function syncDbGridExtras(id, n) {
        var r = S.R[id];
        if (!r) return;
        r.ftext = n.filtertext || '';
        r.page = n.page || 1;
        r.pages = n.pages || 0;
        r.recno = n.recno || 0;
        r.pgtext = pagerTextOf(n);
        r.sumtext = n.summary ? summaryTextOf(n.summary) : '';
        /* 选中行滚进可视区 */
        var el = S.E[id];
        if (el && r.recno > 0) {
            defer(function () {
                var row = el.querySelector('.lw-dbgrid-body tbody tr:nth-child(' + r.recno + ')');
                if (row && row.scrollIntoView) row.scrollIntoView({ block: 'nearest' });
            }, 30);
        }
    }

    /* 页签条（tabs：每页一套子控件；tabctl：公共客户区） */
    function buildTabbar(id, node) {
        var bar = document.getElementById('lw-tabbar-' + id);
        if (!bar) return;
        var active = (S.ND[id] && typeof S.ND[id].active === 'number') ? S.ND[id].active : 0;
        var html = '';
        (node.children || []).forEach(function (ts, i) {
            html += '<div class="lw-tab' + (i === active ? ' lw-active' : '') + '" data-ti="' + i + '">' +
                esc(ts.caption || ts.name || '') + '</div>';
        });
        bar.innerHTML = html;
        bar.querySelectorAll('.lw-tab').forEach(function (el) {
            el.addEventListener('click', function () {
                $lwTabClick(id, parseInt(el.getAttribute('data-ti'), 10));
            });
        });
        applyTabActive(id, active);
        if (node.tabpos === 1) {   /* TPageControl.TabPosition = tpBottom */
            var tabsEl = S.E[id];
            if (tabsEl) { tabsEl.appendChild(tabsEl.querySelector('.lw-tabs-body')); }
        }
    }

    function buildTabCtl(id, node) {
        var bar = document.getElementById('lw-tabbar2-' + id);
        if (!bar) return;
        /* 点击必须本地先切换高亮：服务端 TTabControl 没有独立的页内容
           （客户区是公共的一块），树补丁只带新 tabindex，不会重建页签条；
           之前只在建树时设一次 active，点了永远停在旧页签上。
           OnChange 无条件回发：服务端 LWApplyValue 先同步 TabIndex（供
           序列化和业务读取），RTTI 调用在没挂 handler 时是空操作 */
        function render(active) {
            if (S.ND[id]) S.ND[id].tabindex = active;
            var html = '';
            (node.tabitems || []).forEach(function (t, i) {
                html += '<div class="lw-tab' + (i === active ? ' lw-active' : '') + '" data-ti="' + i + '">' + esc(t) + '</div>';
            });
            bar.innerHTML = html;
            bar.querySelectorAll('.lw-tab').forEach(function (el) {
                el.addEventListener('click', function () {
                    var i = parseInt(el.getAttribute('data-ti'), 10);
                    var cur = (S.ND[id] && typeof S.ND[id].tabindex === 'number') ? S.ND[id].tabindex : 0;
                    if (i === cur) return;
                    render(i);
                    fire(id, 'OnChange', { val: String(i) });
                });
            });
        }
        render(node.tabindex || 0);
    }

    /* TBoundLabel：按编辑框实测位置精修标签坐标（服务端量 CJK 会偏） */
    function fixBoundLabel(id) {
        var n = S.ND[id];
        if (!n || !n.boundfor) return;
        var edId = S.NAME[n.boundfor];
        if (!edId) return;
        var le = S.E[id], ee = S.E[edId];
        if (!le || !ee) return;
        defer(function () {
            try {
                var er = ee.getBoundingClientRect(), lr = le.getBoundingClientRect();
                if ((!er.width && !er.height) || (!lr.width && !lr.height)) return;
                var sp = (n.labelspacing != null && n.labelspacing >= 0) ? n.labelspacing : 4;
                var par = S.P[id].getBoundingClientRect();
                var ox = 0, oy = 0;
                if (n.labelpos === 0) oy = -lr.height - sp;
                else if (n.labelpos === 1) oy = er.height + sp;
                else if (n.labelpos === 2) { ox = -lr.width - sp; oy = (er.height - lr.height) / 2; }
                else if (n.labelpos === 3) { ox = er.width + sp; oy = (er.height - lr.height) / 2; }
                /* 目标页面位置 -> 父容器局部坐标 */
                var nx = (er.left - par.left) + ox;
                var ny = (er.top - par.top) + oy;
                le.style.left = Math.round(nx) + 'px';
                le.style.top = Math.round(ny) + 'px';
                le.style.height = 'auto';
                if (S.ND[id]) { S.ND[id].x = Math.round(nx); S.ND[id].y = Math.round(ny); }
            } catch (e) { }
        }, 60);
    }

    /* 包装 div 的定位（align 拉伸由 runLayout 精修） */
    function placeNode(id, node) {
        var w = S.E[id];
        if (!w) return;
        if (node.kind === 'toolbutton' || w.classList.contains('lw-flow')) {
            w.style.position = 'static';
            return;
        }
        w.style.left = (node.x || 0) + 'px';
        w.style.top = (node.y || 0) + 'px';
        if (node.kind === 'label' || node.kind === 'static') {
            if (!node.boundfor) {
                if (node.autosize && !node.wordwrap) {
                    /* LCL AutoSize：单行标签盒子缩到文字宽，文字贴 Left，
                       Alignment(taCenter) 因此不起作用。nogui 服务端量不准
                       CJK 字宽，宽高都不下发，绝对定位的盒子按内容自适应
                       （否则 taCenter 会在整窗宽的盒子里把文字推到中央）。 */
                } else {
                    if (node.w) w.style.width = node.w + 'px';
                    if (node.h) w.style.height = node.h + 'px';
                }
            }
        } else {
            if (node.w) w.style.width = node.w + 'px';
            if (node.h) w.style.height = node.h + 'px';
        }
        w.style.zIndex = node.zi || '';
        /* tabsheet 的显隐由页签容器 active 管理（服务端 TTabSheet.Visible 恒 False） */
        if (node.visible === false && node.kind !== 'tabsheet') w.style.display = 'none';
        else if (node.kind !== 'tabsheet') w.style.display = '';
    }

    /* 服务端已算好坐标；这里只处理 align 拉伸（与 lw.js runLayout 同语义） */
    function runLayout(ct, list) {
        var body = ct.body;
        if (!body) return;
        var w = body.clientWidth, h = body.clientHeight;
        if (!w && !h) return;
        var curTop = 0, curBottom = h, curLeft = 0, curRight = w, i, n, el;
        for (i = list.length - 1; i >= 0; i--) {
            n = list[i];
            if (!n.align || n.align === 'client' || n.align === 'none') continue;
            el = S.E[n.id];
            if (!el) continue;
            var x = n.x || 0, y = n.y || 0, wd = n.w || 0, ht = n.h || 0;
            switch (n.align) {
                case 'top': x = curLeft; wd = curRight - curLeft; y = curTop; curTop += ht; break;
                case 'bottom': curBottom -= ht; x = curLeft; wd = curRight - curLeft; y = curBottom; break;
                case 'left': x = curLeft; curLeft += wd; y = curTop; ht = curBottom - curTop; break;
                case 'right': curRight -= wd; x = curRight; y = curTop; ht = curBottom - curTop; break;
                default: continue;
            }
            applyRect(el, n, x, y, Math.max(0, wd), Math.max(0, ht));
        }
        /* 第二趟：alClient 拿剩余矩形（与 lw.js 同语义） */
        for (i = 0; i < list.length; i++) {
            n = list[i];
            if (n.align !== 'client') continue;
            el = S.E[n.id];
            if (!el) continue;
            applyRect(el, n, curLeft, curTop, Math.max(0, curRight - curLeft), Math.max(0, curBottom - curTop));
        }
        for (i = 0; i < list.length; i++) {
            n = list[i];
            if (n.align !== 'client') continue;
            el = S.E[n.id];
            if (!el) continue;
            applyRect(el, n, curLeft, curTop, Math.max(0, curRight - curLeft), Math.max(0, curBottom - curTop));
        }
    }

    function applyRect(el, n, x, y, w, h) {
        el.style.left = x + 'px';
        el.style.top = y + 'px';
        el.style.width = w + 'px';
        el.style.height = h + 'px';
        if (S.ND[n.id]) { S.ND[n.id].x = x; S.ND[n.id].y = y; S.ND[n.id].w = w; S.ND[n.id].h = h; }
        /* 容器尺寸变了，内部 align 子项跟着重排 */
        if (isContainer(n) && S.kids[n.id]) {
            defer(function () { runLayout({ body: S.E[n.id].querySelector('.lw-kids') || S.E[n.id] }, S.ND[n.id].children || []); }, 0);
        }
    }

    function syncChildren(ct, node) {
        var list = node.children || [];
        var body = ct.body;
        if (!body) return;
        var keep = {};
        list.forEach(function (n) {
            keep[n.id] = true;
            if (S.E[n.id] && S.P[n.id] === body) {
                patchNode(n);
            } else {
                destroyNode(n.id);
                createNode(n, ct);
            }
        });
        /* 清掉已经不在树里的旧子节点（按 DOM 实况清，比记清单可靠） */
        Array.prototype.slice.call(body.children).forEach(function (el) {
            var cid = el.getAttribute && el.getAttribute('data-lwid');
            if (cid && !keep[cid]) destroyNode(cid);
        });
        S.kids[body.__lwid || node.id || ''] = list.map(function (n) { return n.id; });
        runLayout(ct, list);
    }

    function destroyNode(id) {
        if (!S.E[id]) return;
        /* 先递归销毁子节点状态，再摘自己的 DOM */
        Object.keys(S.P).filter(function (k) { return S.P[k] === S.E[id] && k !== id; })
            .forEach(function (k) { destroyNode(k); });
        var w = S.E[id];
        try { if (window.Alpine) Alpine.destroyTree(w); } catch (e2) { }
        if (w.parentNode) w.parentNode.removeChild(w);
        delete S.E[id]; delete S.R[id]; delete S.K[id]; delete S.EV[id];
        delete S.ND[id]; delete S.P[id]; delete S.WIN[id]; delete S.NAME[id];
        Object.keys(S.sigs).forEach(function (k) { if (k.indexOf(id + '|') === 0) delete S.sigs[k]; });
        if (S.forms[id]) delete S.forms[id];
    }

    function bindNodeEvents(id, node, w) {
        var ev = node.ev || [];
        function has(n) { return ev.indexOf(n) >= 0; }
        if (node.popup && node.popup.length) {
            w.addEventListener('contextmenu', function (e) {
                e.preventDefault();
                closeAllMenus();
                var host = document.createElement('div');
                host.innerHTML = menuPopHtml(node.popup);
                var pop = host.firstChild;
                document.body.appendChild(pop);
                pop.style.left = e.clientX + 'px';
                pop.style.top = e.clientY + 'px';
                bindMenuPop(pop, node.popup);
            });
        }
        if (has('OnDblClick')) {
            w.addEventListener('dblclick', function () { fire(id, 'OnDblClick'); });
        }
    }

    /* ---------------- 窗体 ---------------- */

    var TITLE_H = 28, STATUS_H = 24;

    function buildForm(f) {
        if (S.forms[f.id]) return S.forms[f.id];

        var fx = f.x, fy = f.y;
        /* 模态/非模态一律在视口里居中（坑 93）：LFM 的 Left/Top 常是 0 或
           设计时随手摆的位置，模态窗体沿用会怼在左上角 */
        fx = Math.max(8, Math.floor((window.innerWidth - (f.w || 300)) / 2));
        fy = Math.max(8, Math.floor((window.innerHeight - (f.h || 300)) / 3));

        var root = document.getElementById('lw-root');
        var clientH = f.ch || f.h || 200;
        var win = document.createElement('div');
        win.className = 'lw-win';
        win.setAttribute('data-lwid', f.id);
        win.style.left = fx + 'px';
        win.style.top = fy + 'px';
        win.style.width = (f.w || 300) + 'px';
        /* 窗口总高 = 标题栏 + 客户区。与 Ext 版 show() 后的 dh 补偿同语义
           （lw.js：窗口 height 含标题栏，LCL ClientHeight 不含，差值补回去），
           否则 .lw-win-body 只剩 h-28，客户区底部（如模态窗体的关闭按钮）被裁掉 */
        win.style.height = (clientH + TITLE_H) + 'px';
        win.style.zIndex = 100 + Object.keys(S.forms).length;
        /* 可调大小：LFM 的 bsSizeable/bsSizeToolWin 才给拖角调整（与 Ext 版
           resizable: !!f.resizable 同语义），用 CSS resize + ResizeObserver */
        if (f.resizable) win.classList.add('lw-resizable');

        /* 模态窗体遮罩：垫在窗体下面一层，ShowModal 期间背景不可点（对齐 Ext modal:true） */
        var maskEl = null;
        if (f.modal) {
            maskEl = document.createElement('div');
            maskEl.className = 'lw-win-mask';
            maskEl.style.zIndex = 99 + Object.keys(S.forms).length;
            root.appendChild(maskEl);
        }

        var title = document.createElement('div');
        title.className = 'lw-win-title';
        title.innerHTML = '<span class="lw-win-cap">' + esc(f.caption || f.name) + '</span>' +
            /* 右上角图标（对齐 Ext 版 maximizable: true）：最大化/还原 +
              模态窗体的 × 关闭 */
            '<span class="lw-win-max" title="最大化/还原">▢</span>' +
            (f.modal ? '<span class="lw-win-x" title="关闭">×</span>' : '');
        win.appendChild(title);

        var body = document.createElement('div');
        body.className = 'lw-win-body';
        body.style.height = clientH + 'px';
        body.style.background = f.bg || '#f0f0f0';
        body.style.overflow = 'auto';
        var kids = document.createElement('div');
        kids.className = 'lw-kids';
        kids.style.position = 'relative';
        kids.style.minHeight = '100%';
        body.appendChild(kids);
        win.appendChild(body);
        root.appendChild(win);

        /* 主菜单：插在标题栏与客户区之间（appendChild 会排到 body 之后，
           flex 列布局下菜单会被挤到客户区下面去），并把高度补进窗口总高 */
        var mbH = 0;
        if (f.menu && f.menu.length) {
            var mb = document.createElement('div');
            mb.className = 'lw-menubar';
            mb.innerHTML = f.menu.map(function (m, i) {
                return '<div class="lw-menu-top" data-mi="' + i + '">' + esc(m.caption || '') + '</div>';
            }).join('');
            win.insertBefore(mb, body);
            mbH = mb.offsetHeight || 26;
            mb.querySelectorAll('.lw-menu-top').forEach(function (el) {
                var mi = parseInt(el.getAttribute('data-mi'), 10);
                el.addEventListener('click', function (e) {
                    e.stopPropagation();
                    var m = f.menu[mi];
                    if (!m) return;
                    if (!m.items || !m.items.length) {
                        closeAllMenus();
                        fire(m, 'OnClick');
                        return;
                    }
                    var existed = el.__lwOpen;
                    closeAllMenus();
                    if (existed) { el.__lwOpen = false; return; }
                    el.__lwOpen = true;
                    var host = document.createElement('div');
                    host.innerHTML = menuPopHtml(m.items);
                    var pop = host.firstChild;
                    document.body.appendChild(pop);
                    var r = el.getBoundingClientRect();
                    pop.style.left = r.left + 'px';
                    pop.style.top = r.bottom + 'px';
                    bindMenuPop(pop, m.items);
                    setTimeout(function () { el.__lwOpen = false; }, 100);
                });
            });
        }

        /* 实测补偿（与 Ext 版 show() 后的 dh 补偿同语义）：窗口边框 +
           标题栏分隔线的 1px 误差会让 body 比 ch 矮一点，按实际读数补齐，
           保证 body 的坐标空间精确等于 LCL 客户区（子控件按 ch 布局） */
        try {
            var bh = body.getBoundingClientRect().height;
            var dh = clientH - bh;
            if (dh) win.style.height = (win.offsetHeight + dh) + 'px';
        } catch (e) { }

        /* 状态栏：铺在客户区底部（与 LCL 坐标系一致）。
           body.offsetTop 已含标题栏/菜单栏/边框的全部偏移，直接用它 */
        if (f.status && f.status.length) {
            var sb = document.createElement('div');
            sb.className = 'lw-statusbar';
            sb.style.top = (body.offsetTop + clientH - STATUS_H) + 'px';
            sb.style.width = (f.w || 300) + 'px';
            sb.innerHTML = f.status.map(function (t) { return '<span class="lw-status-item">' + esc(t == null ? '' : String(t)) + '</span>'; }).join('');
            win.appendChild(sb);
            win.__lwStatus = sb;
        }

        /* 模态窗体右上角 × == OnClose。必须传 f.id：fire 的第一参数是
           组件 id（S.ND 按 id 查），传节点对象服务端找不到组件，事件被
           静默吞掉 —— × 点了没反应（服务端 lwdispatch 的
           "OnClose on 模态窗体 -> SessionEndModal(mrCancel)" 永远收不到） */
        var xBtn = title.querySelector('.lw-win-x');
        if (xBtn) xBtn.addEventListener('click', function () { fire(f.id, 'OnClose'); });

        /* 最大化/还原：CSS 类切换（!important 覆盖内联 left/top/w/h），
           尺寸变化由 ResizeObserver 统一重排布局与状态栏 */
        var maxBtn = title.querySelector('.lw-win-max');
        if (maxBtn) maxBtn.addEventListener('click', function () {
            win.__lwMax = !win.__lwMax;
            win.classList.toggle('lw-max', win.__lwMax);
            maxBtn.title = win.__lwMax ? '还原' : '最大化';
        });

        /* 标题栏拖动 */
        title.addEventListener('mousedown', function (e) {
            if (e.target.classList.contains('lw-win-x') ||
                e.target.classList.contains('lw-win-max')) return;
            if (win.__lwMax) return;   /* 最大化时不可拖 */
            var sx = e.clientX - win.offsetLeft, sy = e.clientY - win.offsetTop;
            function mv(ev2) {
                win.style.left = Math.max(0, ev2.clientX - sx) + 'px';
                win.style.top = Math.max(0, ev2.clientY - sy) + 'px';
            }
            function up() { document.removeEventListener('mousemove', mv); document.removeEventListener('mouseup', up); }
            document.addEventListener('mousemove', mv);
            document.addEventListener('mouseup', up);
        });
        title.addEventListener('mousedown', function () {
            /* 置顶：点谁谁在最上面 */
            var top = 100;
            Object.keys(S.forms).forEach(function (k) {
                var el = S.forms[k].el;
                if (el) top = Math.max(top, parseInt(el.style.zIndex || 100, 10));
            });
            win.style.zIndex = top + 1;
        });

        S.forms[f.id] = { el: win, body: kids, f: f, mask: maskEl };
        S.K[f.id] = 'form';
        S.ND[f.id] = f;
        S.EV[f.id] = f.ev || [];
        S.E[f.id] = kids;
        S.WIN[f.id] = f.id;
        S.P[f.id] = kids;
        stateOf(f);

        /* 窗体尺寸变化（用户拖角 / 最大化还原）→ 状态栏跟随 + align 子项重排。
           CSS resize 不派发任何事件，ResizeObserver 是唯一可靠的钩子 */
        if (typeof ResizeObserver !== 'undefined') {
            var roPending = false;
            var ro = new ResizeObserver(function () {
                if (roPending) return;
                roPending = true;
                requestAnimationFrame(function () {
                    roPending = false;
                    try {
                        var fm = S.forms[f.id];
                        if (!fm) return;
                        if (win.__lwStatus) {
                            win.__lwStatus.style.width = body.clientWidth + 'px';
                            win.__lwStatus.style.top =
                                (body.offsetTop + body.clientHeight - STATUS_H) + 'px';
                        }
                        runLayout({ body: kids }, fm.f.children || []);
                    } catch (e) { }
                });
            });
            ro.observe(win);
            S.forms[f.id].ro = ro;
        }

        var that = { body: kids, winId: f.id };
        syncChildren(that, f);
        return S.forms[f.id];
    }

    function closeFormWin(id) {
        var fm = S.forms[id];
        if (!fm) return;
        /* 先递归销毁子节点状态，再摘 DOM */
        (fm.f.children || []).forEach(function (n) { destroyNode(n.id); });
        delete S.K[id]; delete S.ND[id]; delete S.EV[id]; delete S.E[id];
        delete S.P[id]; delete S.WIN[id]; delete S.R[id];
        delete S.forms[id];
        if (fm.mask && fm.mask.parentNode) fm.mask.parentNode.removeChild(fm.mask);
        if (fm.ro) { try { fm.ro.disconnect(); } catch (e) { } }
        if (fm.el.parentNode) fm.el.parentNode.removeChild(fm.el);
    }

    /* ---------------- 补丁（增量协调） ---------------- */

    function patchNode(n) {
        var id = n.id;
        var prev = S.ND[id] || {};
        var r = S.R[id];
        S.ND[id] = n;
        S.EV[id] = n.ev || [];
        var el = S.E[id];
        if (!el || !r) { return; }

        try {
            if (prev.enabled !== n.enabled) r.dis = n.enabled === false;
            if (n.kind !== 'tabsheet' && prev.visible !== n.visible) {
                el.style.display = (n.visible === false) ? 'none' : '';
            }
            applyHint(id, n);
        } catch (e) { }

        /* 文本/标题 */
        try {
            if (n.kind === 'label' || n.kind === 'static' || n.kind === 'statusbar') {
                if (prev.text !== n.text) r.txt = n.text != null ? String(n.text) : (n.caption || '');
                else if (prev.caption !== n.caption) r.txt = n.caption || '';
            } else if (n.kind === 'button' || n.kind === 'bitbtn' || n.kind === 'speedbutton' ||
                n.kind === 'toolbutton' || n.kind === 'fileupload') {
                if (prev.caption !== n.caption) r.cap = n.caption || '';
                if (n.kind === 'speedbutton' && prev.down !== undefined && prev.down !== n.down) r.down = !!n.down;
            } else if (n.kind === 'groupbox' || n.kind === 'radiogroup' || n.kind === 'checkgroup' || n.kind === 'dbradiogroup') {
                if (prev.caption !== n.caption) r.cap = n.caption || '';
            }
        } catch (e) { }

        /* 绑定标签重新贴 */
        try { if (n.boundfor) fixBoundLabel(id); } catch (e) { }

        /* 值（不要覆盖正在编辑的输入框） */
        try {
            var focused = el.contains(document.activeElement);
            if (n.kind === 'edit' || n.kind === 'maskedit' || n.kind === 'memo' ||
                n.kind === 'dbedit' || n.kind === 'dbmemo') {
                if (!focused && prev.text !== n.text) r.txt = (n.text || '').replace(/\r\n/g, '\n');
            } else if (n.kind === 'checkbox' || n.kind === 'dbcheckbox') {
                if (prev.checked !== n.checked) r.chk = !!n.checked;
                if (prev.state !== n.state) r.ind = n.state === 2;
            } else if (n.kind === 'radio') {
                if (prev.checked !== n.checked) r.chk = !!n.checked;
            } else if (n.kind === 'spin' || n.kind === 'floatspin' || n.kind === 'updown') {
                if (prev.value !== n.value && !focused) r.val = n.value;
            } else if (n.kind === 'combo' || n.kind === 'dbcombo') {
                if (prev.text !== n.text && !focused) r.txt = n.text || '';
                if (JSON.stringify(prev.items) !== JSON.stringify(n.items)) r.items = n.items || [];
            } else if (n.kind === 'dblookup') {
                if (prev.key !== n.key && !focused) r.key = n.key != null ? String(n.key) : '';
                if (JSON.stringify(prev.items) !== JSON.stringify(n.items)) r.items = n.items || [];
                if (JSON.stringify(prev.keys) !== JSON.stringify(n.keys)) r.keys = n.keys || [];
            } else if (n.kind === 'dateedit' || n.kind === 'timeedit') {
                if (prev.iso !== n.iso && !focused) r.iso = n.iso || '';
            } else if (n.kind === 'progress') {
                r.pos = n.pos || 0; r.max = n.max || 0;
            } else if (n.kind === 'trackbar') {
                if (prev.pos !== n.pos && !focused) r.val = n.pos || 0;
            } else if (n.kind === 'listbox' || n.kind === 'dblistbox') {
                if (JSON.stringify(prev.items) !== JSON.stringify(n.items)) r.items = n.items || [];
                if (prev.index !== n.index) r.idx = (typeof n.index === 'number') ? n.index : -1;
            } else if (n.kind === 'dblookuplist') {
                if (JSON.stringify(prev.items) !== JSON.stringify(n.items)) r.items = n.items || [];
                if (JSON.stringify(prev.keys) !== JSON.stringify(n.keys)) r.keys = n.keys || [];
                var ki = (n.keys || []).map(String).indexOf(String(n.key));
                r.idx = ki;
            } else if (n.kind === 'radiogroup') {
                if (prev.index !== n.index) r.idx = (typeof n.index === 'number') ? n.index : -1;
                if (JSON.stringify(prev.items) !== JSON.stringify(n.items)) r.items = n.items || [];
            } else if (n.kind === 'dbradiogroup') {
                if (prev.value !== n.value) r.val = n.value != null ? String(n.value) : '';
                if (JSON.stringify(prev.items) !== JSON.stringify(n.items)) r.items = n.items || [];
                if (JSON.stringify(prev.values) !== JSON.stringify(n.values)) r.keys = n.values || [];
            } else if (n.kind === 'checkgroup' || n.kind === 'checklistbox') {
                /* 指纹必须存 S.sigs（key 带 id），不能存 prev 上 —— patchNode
                   每次都用新节点替换 S.ND[id]，存 prev 等于每次都丢，
                   丢一次就按"内容变了"用服务端旧状态覆盖 r.checked，
                   用户刚点勾的复选框立刻被打回（坑 94 的根因） */
                var csig = JSON.stringify(Array.isArray(n.checked) ? n.checked : []);
                if (S.sigs[id + '|cg'] !== csig) {
                    S.sigs[id + '|cg'] = csig;
                    r.checked = Array.isArray(n.checked) ? n.checked.slice() : [];
                }
                if (JSON.stringify(prev.items) !== JSON.stringify(n.items)) r.items = n.items || [];
                if (n.kind === 'checklistbox' && n.index != null &&
                    prev.index !== n.index && typeof n.index === 'number') r.idx = n.index;
            } else if (n.kind === 'image' || n.kind === 'dbimage') {
                if (prev.src !== n.src) r.src = n.src || '';
            }
        } catch (e) { }

        /* 列表/网格/树/帧：内容指纹变了才整块重建 */
        try {
            if (n.kind === 'grid' || n.kind === 'drawgrid' || n.kind === 'listview') {
                var sig = JSON.stringify(n.rows) + '#' + JSON.stringify(n.cols);
                if (S.sigs[id + '|grid'] !== sig) {
                    S.sigs[id + '|grid'] = sig;
                    r.rows = n.rows || [];
                    r.cols = n.cols || [];
                    r.idx = (n.kind === 'listview') ? (n.index != null ? n.index : -1) : -1;
                }
                /* 服务端 ItemIndex 变化（数据没变也要跟随） */
                if (n.kind === 'listview' && n.index != null &&
                    prev.index !== n.index && typeof n.index === 'number') r.idx = n.index;
            } else if (n.kind === 'valeditor') {
                var vsig = JSON.stringify(n.keys) + '#' + JSON.stringify(n.values);
                if (S.sigs[id + '|ve'] !== vsig) {
                    S.sigs[id + '|ve'] = vsig;
                    r.keys = n.keys || [];
                    r.values = n.values || [];
                }
                if (n.selrow !== prev.selrow && (n.selrow || -1) >= 0) r.idx = n.selrow;
                if (n.titles) {
                    var ts = String(n.titles).split(',');
                    r.t0 = ts[0] || 'Key'; r.t1 = ts[1] || 'Value';
                }
            } else if (n.kind === 'dbgrid') {
                var dsig = JSON.stringify(n.rows || null) + '#' + JSON.stringify(n.cols || null);
                var csig2 = JSON.stringify(n.cols || null);
                if (prev.__dbSig !== dsig) {
                    if (n.rows) {
                        if (prev.__dbColSig === csig2) {
                            /* 列没变只灌行数据（Alpine x-for 自动协调） */
                            r.rows = n.rows || [];
                        } else {
                            /* 列变了整块重建（表头 + 行） */
                            rebuildDbGrid(id, n);
                        }
                        prev.__dbColSig = csig2;
                    }
                    prev.__dbSig = dsig;
                }
                syncDbGridExtras(id, n);
            } else if (n.kind === 'tree') {
                var tsig = JSON.stringify(n.nodes || null);
                if (S.sigs[id + '|tree'] !== tsig) {
                    S.sigs[id + '|tree'] = tsig;
                    renderTree(id);
                }
            } else if (n.kind === 'gauge') {
                var gs = gaugeSig(n);
                var g = document.getElementById('lw-gauge-' + id);
                if (g && g.__lwSig !== gs) {
                    g.__lwSig = gs;
                    g.innerHTML = gaugeSvg(n);
                }
            } else if (n.kind === 'chart') {
                var cs = chartSig(n);
                var chh = document.getElementById('lw-ch-' + id);
                if (chh && chh.__lwSig !== cs) {
                    chh.__lwSig = cs;
                    chh.innerHTML = chartSvg(n);
                }
            } else if (n.kind === 'htmlframe') {
                var hs = n.html || '';
                var hf = document.getElementById('lw-hf-' + id);
                if (hf && hf.__lwSig !== hs) {
                    hf.__lwSig = hs;
                    hf.innerHTML = hs;
                    execHtmlScripts(hf);
                }
            } else if (n.kind === 'pdfframe') {
                var us = n.url || '';
                var pf = document.getElementById('lw-pdf-' + id);
                if (pf && pf.__lwUrlSig !== us) renderPdf(id, n);
            } else if (n.kind === 'dbnav') {
                /* 导航按钮 Enabled 跟随服务端按数据集状态算出的结果 */
                var btns = el.querySelectorAll('.lw-nav');
                (n.buttons || []).forEach(function (nb) {
                    btns.forEach(function (b) {
                        if (b.getAttribute('data-navid') === nb.id) b.disabled = (nb.en === false);
                    });
                });
            } else if (n.kind === 'tabs') {
                if (typeof n.active === 'number' && prev.active !== n.active && prev.active !== undefined) {
                    r.active = n.active;
                    buildTabbar(id, n);   /* 标签高亮 + 卡片可见性 */
                }
            } else if (n.kind === 'tabctl') {
                /* 服务端改 TabIndex（代码赋值）时页签高亮跟着切 */
                if (typeof n.tabindex === 'number' && prev.tabindex !== n.tabindex && prev.tabindex !== undefined) {
                    buildTabCtl(id, n);
                }
            } else if (n.kind === 'color') {
                if (prev.value !== n.value) {
                    var sw = el.querySelector('.lw-swatch');
                    if (sw) sw.style.background = n.value || '#ffffff';
                }
            }
        } catch (e) { }

        /* 容器：递归同步子节点 */
        if (isContainer(n) && n.kind !== 'form') {
            var body = el.querySelector('.lw-kids');
            if (n.kind === 'tabs') body = el.querySelector('.lw-tabs-body');
            if (body) syncChildren({ body: body, winId: S.WIN[id], flow: (n.kind === 'toolbar'), parentKind: n.kind, parentId: id }, n);
        }
    }

    /* ---------------- 增量补丁（服务端 --patch=1） ----------------
       ops 形如 ["p",id,{props}] / ["a",父id,下标,node] / ["d",id] / ["m",id,父id,下标]。
       和"全量重下"相比只是少传数据，界面上走的仍是同一套 patchNode /
       createNode / destroyNode，所以两条路的渲染行为天然一致。

       版本（tver）对不上、窗体不认识、节点找不到 —— 一律退回全量（refreshTree），
       不尝试修补。丢帧/多页签/重连都靠这一条自愈，不需要重传队列。 */

    function applyPatch(p) {
        if (!p || !p.patch) return false;
        S.nPatch++;
        if (typeof p.base === 'number' && S.tver >= 0 && p.base !== S.tver) {
            log('patch ver mismatch', p.base, S.tver);
            S.tver = -1;
            refreshTree();
            return true;
        }
        var bad = false;
        try {
            p.patch.forEach(function (fp) {
                var fm = S.forms[fp.f];
                if (!fm) { bad = true; return; }
                var idx = null, dirty = false;
                (fp.ops || []).forEach(function (op) {
                    if (!idx) idx = treeIndexOf(fp.f);
                    var tag = op[0];
                    if (tag === 'p') {
                        applyPropsOp(fp.f, fm, op[1], op[2], idx);
                    } else {
                        applyStructOp(fp.f, fm, op, idx);
                        dirty = true;
                        idx = null;       /* 结构变了，索引作废，下一条重算 */
                    }
                });
                if (dirty && !S.forms[fp.f]) bad = true;
            });
        } catch (e) {
            log('patch failed', e);
            bad = true;
        }
        if (bad) {
            S.tver = -1;
            refreshTree();
            return true;
        }
        S.tver = (typeof p.tver === 'number') ? p.tver : -1;
        return true;
    }

    /* 窗体当前的节点索引：id -> {n: 节点对象, p: 父节点} */
    function treeIndexOf(formId) {
        var fm = S.forms[formId];
        var out = {};
        if (!fm) return out;
        (function walk(n, parent) {
            out[n.id] = { n: n, p: parent };
            (n.children || []).forEach(function (c) { walk(c, n); });
        })(fm.f, null);
        return out;
    }

    /* 容器上下文（createNode / runLayout 要的 ct） */
    function ctOfNode(n, formId) {
        if (!n || n.id === formId) {
            var fm = S.forms[formId];
            return fm ? { body: fm.body, winId: formId } : null;
        }
        var el = S.E[n.id];
        if (!el) return null;
        var body = el.querySelector('.lw-kids');
        if (n.kind === 'tabs') body = el.querySelector('.lw-tabs-body');
        if (!body) return null;
        return {
            body: body, winId: S.WIN[n.id], flow: (n.kind === 'toolbar'),
            parentKind: n.kind, parentId: n.id
        };
    }

    /* 按 list 的顺序把 body 里的元素排好（appendChild/insertBefore 都只是搬动，
       不会重建，所以焦点和滚动位置都保得住） */
    function reorderDom(body, list) {
        if (!body) return;
        var ref = null;
        for (var i = list.length - 1; i >= 0; i--) {
            var el = S.E[list[i].id];
            if (!el) continue;
            if (el.parentNode !== body || el.nextSibling !== ref) body.insertBefore(el, ref);
            ref = el;
        }
    }

    function applyPropsOp(formId, fm, id, props, idx) {
        if (!props) return;
        var cur = (id === formId) ? fm.f : S.ND[id];
        if (!cur) return;
        var merged = {};
        Object.keys(cur).forEach(function (k) { merged[k] = cur[k]; });
        Object.keys(props).forEach(function (k) {
            /* null = 服务端明确"这个属性没了"（如 TImage 清空图片） */
            merged[k] = props[k];
        });
        if (id === formId) {
            fm.f = merged;
            S.ND[id] = merged;
            var cap = fm.el.querySelector('.lw-win-cap');
            if (cap) cap.textContent = merged.caption || merged.name || '';
            if (fm.__lwStatus && merged.status) {
                fm.__lwStatus.innerHTML = merged.status.map(function (t) {
                    return '<span class="lw-status-item">' + esc(t == null ? '' : String(t)) + '</span>';
                }).join('');
            }
            if (merged.children) runLayout({ body: fm.body }, merged.children);
            return;
        }
        var info = idx[id];
        if (info && info.p && info.p.children) {
            var at = info.p.children.indexOf(cur);
            if (at >= 0) info.p.children[at] = merged;   /* 保持树里指向新对象 */
        }
        patchNode(merged);
    }

    function applyStructOp(formId, fm, op, idx) {
        var tag = op[0];
        var pid = (tag === 'a') ? op[1] : (tag === 'm' ? op[2] : 0);
        var pnode = (pid === formId) ? fm.f : (pid ? S.ND[pid] : null);

        if (tag === 'a') {
            if (!pnode) return;
            var arr = pnode.children || (pnode.children = []);
            var at = op[2];
            if (!(at >= 0) || at > arr.length) at = arr.length;
            arr.splice(at, 0, op[3]);
            var ct1 = ctOfNode(pnode, formId);
            if (!ct1) return;
            destroyNode(op[3].id);          /* 万一有残留 */
            createNode(op[3], ct1);
            reorderDom(ct1.body, arr);
            runLayout(ct1, arr);
            return;
        }

        if (tag === 'd') {
            var info = idx[op[1]];
            if (!info) return;
            if (info.p && info.p.children) {
                var k = info.p.children.indexOf(info.n);
                if (k >= 0) info.p.children.splice(k, 1);
            }
            var ct2 = ctOfNode(info.p, formId);
            destroyNode(op[1]);
            if (ct2) runLayout(ct2, (info.p && info.p.children) || []);
            return;
        }

        if (tag === 'm') {
            if (!pnode) return;
            var ma = pnode.children || [];
            var mi = -1, q;
            for (q = 0; q < ma.length; q++) if (ma[q].id === op[1]) { mi = q; break; }
            if (mi < 0) return;
            var mv = ma.splice(mi, 1)[0];
            var mat = op[3];
            if (!(mat >= 0) || mat > ma.length) mat = ma.length;
            ma.splice(mat, 0, mv);
            var ct3 = ctOfNode(pnode, formId);
            if (!ct3) return;
            reorderDom(ct3.body, ma);
            runLayout(ct3, ma);
        }
    }

    /* dbgrid 列变化：整个网格块重建（表头列数变了，x-for 补不了） */
    function rebuildDbGrid(id, n) {
        var el = S.E[id];
        if (!el) return;
        var host = el.querySelector('.lw-dbgrid');
        if (!host) return;
        var r = S.R[id];
        r.cols = n.cols || [];
        r.rows = n.rows || [];
        var keep = host.querySelectorAll('.lw-grid-filter,.lw-grid-pager');
        var gridBox = host.querySelector('.lw-dbgrid-body');
        if (gridBox) {
            var fresh = document.createElement('div');
            fresh.className = 'lw-grid lw-boxed lw-dbgrid-body';
            fresh.innerHTML = '<table class="lw-table"><thead><tr>' +
                '<template x-for="(c,j) in $lwN(\'' + id + '\').cols" :key="j">' +
                '<th @click="' + evAttr(id, 'OnTitleClick', '{col:j}') + '" x-text="c"></th></template>' +
                '</tr></thead><tbody>' +
                '<template x-for="(row,i) in $lwN(\'' + id + '\').rows" :key="i">' +
                '<tr :class="i === $lwN(\'' + id + '\').recno - 1 ? \'lw-sel\' : \'\'" @click="$lwDbRow(\'' + id + '\', i, $event)">' +
                '<template x-for="(cell,j) in row" :key="j">' +
                dbCellTd(id) +
                '</template></tr></template></tbody></table>';
            gridBox.parentNode.replaceChild(fresh, gridBox);
            try { if (window.Alpine) Alpine.initTree(fresh); } catch (e) { }
        }
    }

    /* ---------------- 载荷应用 ---------------- */

    function applyPayload(p) {
        if (!p || !p.forms) return;
        S.sid = p.sid || S.sid;
        S.nFull++;
        S.tver = (typeof p.tver === 'number') ? p.tver : -1;
        var seen = {};
        p.forms.forEach(function (f) {
            seen[f.id] = true;
            if (!S.forms[f.id]) { buildForm(f); return; }
            var fm = S.forms[f.id];
            var prevF = fm.f;
            fm.f = f;
            S.ND[f.id] = f;
            /* 标题/状态栏文本 */
            var cap = fm.el.querySelector('.lw-win-cap');
            if (cap && prevF.caption !== f.caption) cap.textContent = f.caption || f.name;
            if (fm.__lwStatus && f.status && JSON.stringify(prevF.status || []) !== JSON.stringify(f.status)) {
                fm.__lwStatus.innerHTML = f.status.map(function (t) {
                    return '<span class="lw-status-item">' + esc(t == null ? '' : String(t)) + '</span>';
                }).join('');
            }
            syncChildren({ body: fm.body, winId: f.id }, f);
        });
        Object.keys(S.forms).forEach(function (id) {
            if (!seen[id]) closeFormWin(id);
        });
        hideSplash();
    }

    /* 主动拉一次完整树（重发对话框被应答后用） */
    function refreshTree() {
        if (!S.sid) return;
        api('/lw/api/tree', null, function (resp, err) {
            if (!err && resp) { try { applyPayload(resp); } catch (e) { log('refresh failed', e); } }
        }, { params: { sid: S.sid }, timeout: 20000 });
    }

    /* ---------------- 服务端对话框 ----------------
       ShowMessage / MessageDlg / InputQuery / Application.MessageBox /
       QuestionDlg / TOpenDialog.Execute 全都在服务端挂起等待，
       这里把描述渲染成模态窗口（Alpine store 驱动），用户一操作
       就把结果 POST 回去。 */

    var DLG_TITLE = {
        info: '提示', warning: '警告', error: '错误', question: '确认',
        none: '消息', input: '输入', openfile: '打开文件', savefile: '保存文件'
    };

    function dlgPost(id, r, text, cb) {
        api('/lw/api/dlg', { sid: S.sid, id: id, r: r, text: text == null ? '' : String(text) },
            cb || function () { });
    }

    function showServerDialog(cmd) {
        var s = st();
        if (!s) return;
        /* openfile 的 <input type=file> 留在命令对象里（Alpine 模板外） */
        if (cmd.kind === 'openfile' && !cmd.__fileInput) {
            var fileInput = document.createElement('input');
            fileInput.type = 'file';
            if (cmd.input && cmd.input.multi) fileInput.multiple = true;
            var acc = cmd.input && cmd.input.filter ? filterToAccept(cmd.input.filter) : '';
            if (acc) fileInput.accept = acc;
            fileInput.style.display = 'none';
            document.body.appendChild(fileInput);
            fileInput.onchange = function () {
                if (!fileInput.files || !fileInput.files.length) return;
                var fd = new FormData();
                for (var i = 0; i < fileInput.files.length; i++)
                    fd.append('file' + i, fileInput.files[i]);
                var xhr = new XMLHttpRequest();
                xhr.open('POST', '/lw/api/dlgfile?sid=' + encodeURIComponent(S.sid) +
                    '&id=' + cmd.id, true);
                xhr.onload = function () {
                    if (xhr.status === 200) {
                        closeDialog(false);   /* 答案已由上传接口带回服务端 */
                        if (cmd.__lwResend) refreshTree();
                    } else {
                        showMsg('上传失败', '服务端返回 HTTP ' + xhr.status);
                    }
                };
                xhr.onerror = function () { showMsg('上传失败', '网络错误，文件没有传到服务端'); };
                xhr.upload.onprogress = function (e) {
                    if (e.lengthComputable) {
                        s.dlgUpload = '正在上传… ' + Math.round(e.loaded * 100 / e.total) + '%';
                    }
                };
                setBusy(true);
                xhr.send(fd);
            };
            cmd.__fileInput = fileInput;
            cmd.pick = function () { fileInput.click(); };
        }
        s.dlgText = (cmd.input && cmd.input.value != null) ? String(cmd.input.value) : '';
        s.dlgUpload = '';
        cmd.dlgKind = cmd.kind || 'none';
        cmd.caption = cmd.caption || DLG_TITLE[cmd.dlgKind] || '消息';
        s.dialog = cmd;
    }

    function closeDialog(answered, r, text) {
        var s = st();
        if (!s || !s.dialog) return;
        var cmd = s.dialog;
        var fi = cmd.__fileInput;
        s.dialog = null;
        if (answered) {
            dlgPost(cmd.id, r, text, function () {
                if (cmd.__lwResend) refreshTree();
            });
        }
        /* 点右上角关闭 == 按取消键 */
        if (!answered && cmd.kind !== 'openfile') dlgPost(cmd.id, cmd.escape != null ? cmd.escape : 2, '');
        if (!answered && cmd.kind === 'openfile') dlgPost(cmd.id, cmd.escape != null ? cmd.escape : 2, '');
        if (fi && fi.parentNode) fi.parentNode.removeChild(fi);
    }

    window.$lwDlgAnswer = function (btn) {
        var s = st();
        if (!s || !s.dialog) return;
        var cmd = s.dialog;
        var text = (cmd.kind === 'input' || cmd.kind === 'savefile') ? String(s.dlgText || '') : '';
        closeDialog(true, btn.id, text);
    };
    window.$lwDlgClose = function () { closeDialog(false); };

    /* 服务端对话框拖动：overlay 是 Alpine x-if 按需创建/销毁的，绑不到
       固定元素上 —— 事件委托到 document。首次拖动把 flex 居中的窗口
       固化成 position:fixed 显式坐标，之后跟随鼠标，松开即停。 */
    document.addEventListener('mousedown', function (e) {
        var t = e.target;
        if (!t || !t.closest) return;
        var title = t.closest('.lw-dlg-title');
        if (!title) return;
        if (t.classList.contains('lw-dlg-x')) return;   /* × 只负责关闭 */
        var win = title.closest('.lw-dlg-win');
        if (!win) return;
        var r = win.getBoundingClientRect();
        var sx = e.clientX - r.left, sy = e.clientY - r.top;
        win.style.position = 'fixed';
        win.style.left = r.left + 'px';
        win.style.top = r.top + 'px';
        win.style.marginTop = '0';
        function mv(ev2) {
            var x = Math.max(0, Math.min(window.innerWidth - 80, ev2.clientX - sx));
            var y = Math.max(0, Math.min(window.innerHeight - 40, ev2.clientY - sy));
            win.style.left = x + 'px';
            win.style.top = y + 'px';
        }
        function up() {
            document.removeEventListener('mousemove', mv);
            document.removeEventListener('mouseup', up);
        }
        document.addEventListener('mousemove', mv);
        document.addEventListener('mouseup', up);
        e.preventDefault();
    });

    window.$lwDlgKey = function (e) {
        if (e.key === 'Enter') {
            e.preventDefault();
            var s = st();
            if (!s || !s.dialog) return;
            var btns = s.dialog.buttons || [];
            var def = null;
            for (var i = 0; i < btns.length; i++) if (btns[i]['default']) { def = btns[i]; break; }
            if (!def && btns.length) def = btns[0];
            if (def) window.$lwDlgAnswer(def);
        }
    };

    /* 普通消息框（上传失败等浏览器端错误，非服务端模态） */
    function showMsg(title, text) {
        var s = st();
        if (!s) { alert(text); return; }
        s.dialog = { kind: 'error', caption: title || '消息', text: text,
            buttons: [{ id: 1, text: '确定', 'default': true }], __local: true };
    }

    /* ---------------- 指令处理（长轮询 / WS 推送共用） ---------------- */

    function handleCmd(cmd, tree, resend) {
        if (!cmd) return;
        if (cmd.type === 'modal' && cmd.form) {
            buildForm(cmd.form);
            if (tree) applyPayload(tree);
        } else if (cmd.type === 'show') {
            if (tree) applyPayload(tree);
        } else if (cmd.type === 'closeform') {
            if (S.forms[cmd.id]) closeFormWin(cmd.id);
        } else if (cmd.type === 'dialog') {
            /* 多页签共享会话时只让"引起它的那个页签"弹窗（同 lw.js） */
            if (!resend) {
                if (S.multiTab && cmd.to && cmd.to !== S.tab) return;
                if (!cmd.to && S.multiTab && !S.primary) return;
            } else {
                cmd.__lwResend = true;
            }
            showServerDialog(cmd);
        } else if (cmd.type === 'mask') {
            var s = st();
            if (s) { s.mask.show = cmd.show !== false; s.mask.text = cmd.text || ''; }
        } else if (cmd.type === 'msg') {
            showMsg('lazarusWeb', esc(cmd.text || ''));
        } else if (cmd.type === 'toast') {
            /* 轻提示：右上角弹几秒消失，不阻塞 */
            var s2 = st();
            if (!s2) return;
            var tid = 't' + Math.random().toString(36).slice(2, 8);
            s2.toasts.push({ id: tid, title: cmd.title ? esc(cmd.title) : '', text: esc(cmd.text || '') });
            setTimeout(function () {
                s2.toasts = s2.toasts.filter(function (t) { return t.id !== tid; });
            }, 4000);
        } else if (cmd.type === 'download') {
            var a = document.createElement('a');
            a.href = cmd.url;
            if (cmd.name) a.download = cmd.name;
            a.style.display = 'none';
            document.body.appendChild(a);
            a.click();
            setTimeout(function () { try { document.body.removeChild(a); } catch (e) { } }, 100);
        }
    }

    /* ---------------- 长轮询：接收模态窗体/服务端推送 ---------------- */

    function startPoll() {
        if (!S.sid) { defer(startPoll, 500); return; }
        /* 长轮询是唯一的推送通道（WebSocket 只管事件请求/响应）。
           带着 after 游标：服务端只回"序号比它新"的第一条。 */
        api('/lw/api/poll', null, function (resp, err) {
            if (!err && resp) {
                if (resp.gone) {
                    forgetSid();
                    S.sid = null;
                    S.after = -1;
                    S.pollAlive = false;
                    try { if (S.ws) S.ws.close(); } catch (e) { }
                    S.ws = null;
                    showSplash('会话已过期，正在重新连接…');
                    defer(boot, 800);
                    return;
                }
                if (resp.cmd) handleCmd(resp.cmd, resp.tree);
                if (typeof resp.seq === 'number' && resp.seq > S.after) S.after = resp.seq;
            }
            defer(startPoll, err ? 1500 : 30);
        }, { params: { sid: S.sid, t: 20000, after: S.after }, timeout: 35000 });
    }

    /* ---------------- WebSocket（事件优先通道） ---------------- */

    function wsConnect() {
        if (!window.WebSocket || !S.sid) return;
        if (S.wsConnecting) return;
        S.wsConnecting = true;
        try {
            var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
            var ws = new WebSocket(proto + '//' + location.host + '/lw/ws?sid=' + encodeURIComponent(S.sid));
            ws.onopen = function () {
                S.wsConnecting = false;
                log('websocket connected');
                S.ws = ws;
            };
            ws.onmessage = function (m) {
                var d = null;
                try { d = JSON.parse(m.data); } catch (e) { d = null; }
                if (!d) return;
                if (d.type) {
                    if (d.ok === undefined || d.ok) handleCmd(d, d.tree);
                    return;
                }
                var cb = S.wsCb;
                S.wsCb = null;
                setBusy(false);
                if (cb) cb(d, null);
            };
            ws.onclose = function () {
                S.wsConnecting = false;
                if (S.ws === ws) {
                    S.ws = null;
                    var cb = S.wsCb;
                    S.wsCb = null;
                    if (cb) cb(null, 'ws closed');
                }
                if (S.sid && S.wsWanted) {
                    if (!S.pollAlive) { S.pollAlive = true; startPoll(); }
                    defer(function () { if (S.wsWanted && !S.ws && !S.wsConnecting) wsConnect(); }, 2000);
                }
            };
            ws.onerror = function () { };
        } catch (e) {
            S.wsConnecting = false;
            log('websocket unavailable', e);
        }
    }

    /* ---------------- 启动（跨页签会话共享，与 lw.js 同语义） ---------------- */

    var booting = false;
    var SID_KEY = 'lw.sid';

    function rememberSid(sid) {
        try { if (sid) localStorage.setItem(SID_KEY, sid); } catch (e) { }
    }

    function forgetSid() {
        try { localStorage.removeItem(SID_KEY); } catch (e) { }
    }

    function savedSid() {
        if (/[?&]fresh=1/.test(location.search)) return '';
        try { return localStorage.getItem(SID_KEY) || ''; } catch (e) { return ''; }
    }

    function newTabId() {
        return 't' + Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
    }

    function startChannels() {
        if (/[?&]nopoll=1/.test(location.search)) return;
        if (!S.pollAlive) { S.pollAlive = true; startPoll(); }
        S.wsWanted = true;
        wsConnect();
    }

    function newSession(cfg) {
        api('/lw/api/session', { form: cfg.form || '' }, function (resp, err) {
            booting = false;
            if (err || !resp || !resp.ok) {
                showSplash('无法创建会话：' + (err || (resp && resp.err) || '未知错误'));
                return;
            }
            S.sid = resp.sid;
            S.primary = true;
            S.multiTab = false;
            S.after = (typeof resp.seq === 'number') ? resp.seq : -1;
            rememberSid(resp.sid);
            hideSplash();
            applyPayload(resp);
            startChannels();
        });
    }

    function attachSession(sid, cfg) {
        api('/lw/api/attach', null, function (resp, err) {
            booting = false;
            if (err || !resp || !resp.ok) {
                forgetSid();
                newSession(cfg);
                return;
            }
            S.sid = resp.sid;
            S.primary = false;
            S.multiTab = true;
            S.after = (typeof resp.seq === 'number') ? resp.seq : -1;
            rememberSid(resp.sid);
            hideSplash();
            applyPayload(resp);
            /* 挂起中的对话框：attach 响应带回重发（绕过页签归属过滤） */
            if (resp.cmd) { try { handleCmd(resp.cmd, null, true); } catch (e) { log('resend cmd failed', e); } }
            log('attached to session', resp.sid);
            startChannels();
        }, { params: { sid: sid }, timeout: 20000 });
    }

    function boot() {
        if (booting) return;
        booting = true;
        var cfg = window.LW_CFG || {};
        if (!S.tab) {
            try { S.tab = sessionStorage.getItem('lw.tab') || ''; } catch (e) { }
            if (!S.tab) S.tab = newTabId();
            try { sessionStorage.setItem('lw.tab', S.tab); } catch (e) { }
        }
        var sid = savedSid();
        if (sid) { attachSession(sid, cfg); return; }
        newSession(cfg);
    }

    function start(cfg) {
        window.LW_CFG = cfg || {};
        /* 等 Alpine（defer 加载）就绪后再启动：store/响应式都要它 */
        (function waitAlpine() {
            if (window.Alpine && window.Alpine.store) {
                initTooltip();
                showSplash('正在创建服务端会话…');
                boot();
            } else {
                setTimeout(waitAlpine, 30);
            }
        })();
    }

    return {
        start: start,
        reload: function () { boot(); },
        sid: function () { return S.sid; },
        /* 诊断：补丁/全量各来了多少次，当前树版本 */
        stats: function () {
            return { patch: S.nPatch, full: S.nFull, tver: S.tver };
        },
        /* 强制与服务器对一次全量（GET /lw/api/tree，不改任何业务状态）。
           用途：页面看起来"不刷新"时手动校准，也是补丁一致性的验收入口 */
        resync: function () { S.tver = -1; refreshTree(); }
    };
})();
