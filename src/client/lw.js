/*
 * lazarusWeb :: lw.js  —— 浏览器端运行时（Ext JS classic 7.x）
 * ------------------------------------------------------------------
 * 职责：
 *   1. 向服务端要一棵组件树（JSON）；
 *   2. 把这棵树"翻译"成 Ext JS 组件；
 *   3. 用户操作时把 {id, ev, val} 发回服务端，服务端执行真实的 Pascal 事件方法；
 *   4. 拿回新的树，做增量协调（reconcile），不刷新页面、不重建已有控件。
 *
 * 与服务端的约定见 src/core/lwwriter.pas。
 */
var LW = (function () {
    'use strict';

    var S = {
        sid: null,
        ext: '7.5.1',
        forms: {},     /* formId -> Ext.window.Window */
        comps: {},     /* nodeId -> Ext component */
        nodes: {},     /* nodeId -> 最新节点 JSON */
        busy: 0,
        pollAlive: false,
        ws: null,      /* WebSocket（连接成功后接管事件通道） */
        wsCb: null,    /* 当前在途事件的回调（WS 是请求/响应一一对应） */
        wsTimer: null, /* WS 响应超时定时器（超时走 HTTP 兜底） */
        wsConnecting: false, /* 重连防抖：同一时刻只允许一个连接过程 */
        /* ---- 多页签共享会话 ---- */
        tab: null,     /* 本标签页的随机标识，随事件上送（对话框定向用） */
        primary: false,/* 是否由本页签创建了这个会话 */
        multiTab: false,/* 本页签是"挂"到已有会话上的 */
        after: -1,     /* 推送游标：已经处理到的指令序号 */
        inflight: 0    /* 在途事件数（判断"对话框是不是我引起的"） */
    };

    /* ---------------- 工具 ---------------- */

    function log() {
        if (window.console && console.log) {
            console.log.apply(console, ['[lw]'].concat([].slice.call(arguments)));
        }
    }

    function esc(s) {
        return Ext.util.Format.htmlEncode(s == null ? '' : String(s));
    }

    function px(n) { return (n || 0) + 'px'; }

    function isContainer(node) {
        return ['form', 'panel', 'groupbox', 'scrollbox', 'tabsheet', 'frame', 'tabs', 'toolbar'].indexOf(node.kind) >= 0;
    }

    function api(path, data, cb, opts) {
        opts = opts || {};
        Ext.Ajax.request({
            url: path,
            method: data ? 'POST' : 'GET',
            params: (!data && opts.params) ? opts.params : undefined,
            jsonData: data || undefined,
            timeout: opts.timeout || 60000,
            headers: { 'Content-Type': 'application/json' },
            success: function (resp) {
                var d = null;
                try { d = Ext.decode(resp.responseText, true); } catch (e) { d = null; }
                if (!d) { if (cb) cb(null, 'bad json'); return; }
                if (cb) cb(d, null);
            },
            failure: function (resp, opts2) {
                if (cb) cb(null, 'http ' + (resp ? resp.status : '?'));
            }
        });
    }

    function showSplash(txt) {
        var el = document.getElementById('lw-splash');
        if (!el) return;
        el.style.display = '';
        if (txt) el.innerHTML = '<div class="lw-splash-box">' + esc(txt) + '</div>';
    }

    function hideSplash() {
        var el = document.getElementById('lw-splash');
        if (el) el.style.display = 'none';
    }

    function setBusy(on) {
        if (on) S.busy++; else S.busy = Math.max(0, S.busy - 1);
        var el = document.getElementById('lw-busy');
        if (el) el.style.display = S.busy > 0 ? 'block' : 'none';
    }

    /* ---------------- 文件上传 ---------------- */

    /* 'Text|*.txt;*.csv|All|*.*' 或 '*.csv' -> input.accept 用的小写扩展名列表 */
    function filterToAccept(f) {
        var out = [], parts = String(f).split('|');
        parts.forEach(function (p) {
            p.split(';').forEach(function (m) {
                m = Ext.String.trim(m);
                if (m.indexOf('*.') === 0) {
                    var e = m.substring(1).toLowerCase();
                    if (out.indexOf(e) < 0) out.push(e);
                }
            });
        });
        return out.join(',');
    }

    function pickFile(node, btn) {
        var inp = document.createElement('input');
        inp.type = 'file';
        if (node.multiple) inp.multiple = true;
        var acc = filterToAccept(node.filter);
        if (acc) inp.accept = acc;
        inp.style.position = 'fixed';
        inp.style.left = '-9999px';
        document.body.appendChild(inp);

        function cleanup() {
            try { document.body.removeChild(inp); } catch (e) { }
        }

        inp.onchange = function () {
            var files = inp.files;
            if (!files || !files.length) { cleanup(); return; }
            uploadFiles(node, btn, files, cleanup);
        };
        inp.click();
    }

    function uploadFiles(node, btn, files, done) {
        var fd = new FormData(), i;
        for (i = 0; i < files.length; i++) fd.append('f' + i, files[i], files[i].name);

        var base = node.caption || '上传文件…';
        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/lw/api/upload?sid=' + encodeURIComponent(S.sid || '') +
            '&id=' + node.id, true);

        xhr.upload.onprogress = function (e) {
            if (e.lengthComputable && btn.setText) {
                btn.setText('上传中 ' + Math.round(e.loaded * 100 / e.total) + '%');
            }
        };
        function finish() {
            setBusy(false);
            try { btn.setText(base); } catch (e) { }
            if (done) done();
        }
        xhr.onload = function () {
            var d = null;
            try { d = Ext.decode(xhr.responseText, true); } catch (e) { d = null; }
            finish();
            if (d && d.ok) {
                applyPayload(d);
            } else {
                Ext.Msg.alert('上传失败', esc((d && d.err) || ('HTTP ' + xhr.status)));
            }
        };
        xhr.onerror = function () {
            finish();
            Ext.Msg.alert('上传失败', '网络错误');
        };
        setBusy(true);
        xhr.send(fd);
    }

    /* ---------------- 事件回传 ---------------- */

    function collectVal(cmp, node) {
        if (!cmp) return '';
        try {
            if (node.kind === 'checkbox' || node.kind === 'radio' || node.kind === 'dbcheckbox') return cmp.getValue() ? '1' : '0';
            /* 日期/时间选择器统一回传 ISO 串，服务端按 ScanDateTime 解析 */
            if (node.kind === 'dateedit') {
                var dv = cmp.getValue();
                return dv ? Ext.Date.format(dv, 'Y-m-d') : '';
            }
            if (node.kind === 'timeedit') {
                var tv = cmp.getValue();
                return tv ? Ext.Date.format(tv, 'H:i:s') : '';
            }
            if (cmp.getValue) {
                var v = cmp.getValue();
                return v == null ? '' : String(v);
            }
        } catch (e) { }
        return '';
    }

    /* 会承载"用户输入值"的控件类型（与服务端 LWIsSnapField 对应） */
    var FIELD_KINDS = ['edit', 'maskedit', 'memo', 'spin', 'floatspin', 'combo',
        'checkbox', 'radio', 'dbedit', 'dbmemo', 'dbcheckbox', 'dbcombo',
        'dblookup', 'dateedit', 'timeedit'];

    function owningWin(c) {
        if (!c) return null;
        if (c.isWindow) return c;
        try { return c.up('window'); } catch (e) { return null; }
    }

    /* 绑定"元素级"事件（click/dblclick/contextmenu…）。
       控件可能在未渲染时创建（懒加载的页签 / 折叠面板），getEl() 为空
       —— 直接绑会静默失败，必须挂到 afterrender，等渲染好再绑。 */
    function onEl(cmp, ev, fn) {
        try {
            var el = cmp.getEl ? cmp.getEl() : null;
            if (el) { el.on(ev, fn); return; }
        } catch (e) { }
        try {
            cmp.on('afterrender', function () {
                try { cmp.getEl().on(ev, fn); } catch (e2) { }
            });
        } catch (e3) { }
    }

    /* 同一窗体里所有输入控件的当前值：{控件 id: 值}。
       服务端派发事件前会先写回这些值，这样 OnClick 里读 Edit.Text
       拿到的是用户刚输入的，而不是构建窗体时的初始值。 */
    function formVals(node) {
        var win = owningWin(S.comps[node.id]);
        if (!win) return null;
        var out = {}, any = false;
        Object.keys(S.comps).forEach(function (id) {
            var c = S.comps[id], n = S.nodes[id];
            if (!c || !n || FIELD_KINDS.indexOf(n.kind) < 0) return;
            if (owningWin(c) !== win) return;
            out[id] = collectVal(c, n);
            any = true;
        });
        return any ? out : null;
    }

    function applyEventResp(resp, err) {
        if (err) { log('event failed', err); return; }
        if (resp && resp.ok) applyPayload(resp);
        else if (resp && resp.err) log('event err', resp.err);
    }

    /* HTTP 兜底发送：WS 半死/超时/发送失败时，保证这次点击至少送达一次。
       （服务端 WS 空闲保活修复前，连接 100ms 一断，事件落进死连接
       就静默消失 —— 用户看到的就是"点了没反应"。） */
    function sendEventHttp(payload) {
        setBusy(true);
        S.inflight++;
        /* 超时必须大于服务端的模态等待上限（LW_MODAL_TIMEOUT_MS = 180s）：
           点开对话框的那个事件会一直挂到用户应答为止，60s 就 abort 的话
           服务端稍后写响应时对端已断（EWriteError/streams.inc:631），
           而且对话框的应答还会落在一条已经废弃的请求上 */
        api('/lw/api/event', payload, function (resp, err) {
            S.inflight--;
            setBusy(false);
            applyEventResp(resp, err);
        }, { timeout: 200000 });
    }

    function fire(node, ev, extra) {
        if (!S.sid) return;
        var payload = { sid: S.sid, id: node.id, ev: ev, tab: S.tab };
        if (extra) Ext.apply(payload, extra);
        /* 带上窗体值快照：没挂 OnChange 的编辑框（登录窗体的用户名/密码
           就是）平时不回传值，服务端只有初始 Text —— 点"登录"会拿旧密码
           去校验，输错也能进主页。 */
        if (!payload.vals) {
            var snap = formVals(node);
            if (snap) payload.vals = snap;
        }
        /* WebSocket 已连接：事件走 WS 帧（与 POST /lw/api/event 的 body
           同构），响应从同一连接回来。同一时刻只允许一个在途事件，
           有未决回调就退回 HTTP。
           注意：WS 现在只负责"事件请求/响应"，服务端推送一律走长轮询，
           所以这个页签同时开着 WS 和一条 poll 是正常状态。 */
        if (S.ws && S.ws.readyState === 1 && !S.wsCb) {
            setBusy(true);
            S.inflight++;
            var cbSelf = function (resp, err) {
                if (S.wsTimer) { clearTimeout(S.wsTimer); S.wsTimer = null; }
                S.inflight--;
                setBusy(false);
                if (err) {
                    /* 连接死了不算失败：换 HTTP 重发一次 */
                    sendEventHttp(payload);
                    return;
                }
                applyEventResp(resp, null);
            };
            S.wsCb = cbSelf;
            /* 响应兜底：只在**连接真的断了**（readyState 不是 OPEN）时
               撤回调 + 断连 + 转 HTTP 重发；连接还开着就继续等。
               事件可能正挂在服务端对话框上（服务端最长等 180s），
               早期写的是"5 秒没回音就重发"，于是：①同一个事件被执行
               两次（对话框弹两遍/计数加两次）；②关掉的旧连接上服务端
               稍后写响应必然失败，IDE 里就是那个 EWriteError 异常框。 */
            var waited = 0;
            var tick = function () {
                if (S.wsCb !== cbSelf) return;
                if (S.ws && S.ws.readyState === 1 && waited < 190000) {
                    waited += 5000;
                    S.wsTimer = Ext.defer(tick, 5000);
                    return;
                }
                S.wsCb = null;
                S.inflight--;
                setBusy(false);
                try { if (S.ws) S.ws.close(); } catch (e0) { }
                sendEventHttp(payload);
            };
            S.wsTimer = Ext.defer(tick, 5000);
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

    function fireChange(node, cmp) {
        fire(node, 'OnChange', { val: collectVal(cmp, node) });
    }

    /* ---------------- 样式 ---------------- */

    function styleOf(node) {
        var f = node.font || {}, st = {};
        if (f.size) st.fontSize = Math.round(f.size * 4 / 3) + 'px';
        if (f.name && f.name !== 'default') st.fontFamily = f.name;
        if (f.style) {
            if (f.style.indexOf('b') >= 0) st.fontWeight = 'bold';
            if (f.style.indexOf('i') >= 0) st.fontStyle = 'italic';
            if (f.style.indexOf('u') >= 0) st.textDecoration = 'underline';
        }
        if (node.fg) st.color = node.fg;
        return st;
    }

    function fieldStyleOf(node) {
        var f = node.font || {}, st = [];
        if (f.size) st.push('font-size:' + Math.round(f.size * 4 / 3) + 'px');
        if (f.name && f.name !== 'default') st.push('font-family:' + f.name);
        if (node.fg) st.push('color:' + node.fg);
        return st.join(';');
    }

    function applyStyle(cmp, node) {
        if (!cmp || !cmp.getEl) return;
        var st = styleOf(node);
        try {
            if (cmp.getEl()) {
                cmp.getEl().setStyle(st);
                /* Ext 按钮的文字在 .x-btn-inner 里，scale（small/medium）类把
                   font-size 写死在内层，外层 el 的字体进不去 —— 结果按钮文字
                   永远 11px，跟 Label/Memo（13px 起）对不上。内层一起设。 */
                var inner = cmp.getEl().down('.x-btn-inner');
                if (inner) inner.setStyle(st);
            }
        } catch (e) { }
    }

    /* ---------------- LCL Hint -> 浏览器提示 ----------------
       TControl.Hint 在浏览器端走 Ext QuickTips（元素上的 data-qtip 委托）：
       外观统一、延迟/停留时长可控，不依赖 Ext 组件是否支持 tooltip 配置
       （自定义控件、TShape/TBevel、仪表盘的 el 都只有 DOM）。
       注意：QuickTips 不 init 就完全不出提示 —— 见 start() 里的初始化。 */
    var hintTips = false;

    function initHintTips() {
        if (hintTips) return;
        hintTips = true;
        try {
            /* animate, { dismissDelay } —— 默认 5 秒对中文提示偏短，给 12 秒 */
            Ext.tip.QuickTipManager.init(true, { dismissDelay: 12000 });
        } catch (e) { log('quicktips init failed', e); }
    }

    function applyHint(cmp, node) {
        if (!cmp) return;
        var put = function () {
            var el = null;
            try { el = cmp.getEl(); } catch (e) { }
            if (!el || !el.dom) return;
            var h = node.hint ? String(node.hint) : '';
            if (h) {
                /* QuickTip 把 data-qtip 的内容当 HTML 插进提示体，先转义 */
                el.dom.setAttribute('data-qtip', esc(h).replace(/\r?\n/g, '<br>'));
            } else {
                el.dom.removeAttribute('data-qtip');
            }
        };
        if (cmp.rendered) { put(); return; }
        if (!cmp.__lwHintBound) {
            cmp.__lwHintBound = true;
            try {
                cmp.on('afterrender', function () {
                    applyHint(cmp, cmp.__lwNode || node);
                });
            } catch (e) { }
        }
    }

    /* ---------------- 组件工厂 ---------------- */

    function baseCfg(node) {
        var cfg = {
            x: node.x, y: node.y, width: node.w, height: node.h,
            hidden: node.visible === false,
            disabled: node.enabled === false
        };
        /* Hint 不在这里塞 cfg.tooltip：统一由 applyHint 写 data-qtip，
           否则部分控件（自绘/无 el 的）会漏，重复设置还可能被覆盖 */
        return cfg;
    }

    /* ---------------- 仪表盘（TLWGauge）----------------
       纯 SVG，不依赖 Ext charts 包：外圈刻度 + 数值弧 + 指针 + 数值。
       服务端只给 value/min/max/unit/warn/danger，画法全在浏览器。 */
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
            /* large-arc 恒为 0：本仪表弧角最大 180°（f1-f0 ≤ 1），只有
               "大弧"标志为 0 才按给定半径画。曾写成 (f1-f0)>0.5?1:0，
               值一过半程 SVG 就按大弧另选圆心 —— 值弧整条鼓到底弧外面
               （56%/91% 错位），100% 时弦恰为直径两圆心重合又跟底弧完全
               重合，看起来"满格没画上"。 */
            return 'M ' + a[0].toFixed(1) + ' ' + a[1].toFixed(1) +
                ' A ' + rad.toFixed(1) + ' ' + rad.toFixed(1) + ' 0 0 1 ' +
                b[0].toFixed(1) + ' ' + b[1].toFixed(1);
        }

        var parts = [];
        parts.push('<svg width="' + w + '" height="' + h + '" viewBox="0 0 ' + w + ' ' + h +
            '" xmlns="http://www.w3.org/2000/svg">');
        /* 底图轨道与值弧同半径同粗细（r / 10）：进度弧直接压在灰轨道上，
           起点终点都和轨道重合 —— 用户预期就是"进度条叠在灰底上"。
           （曾画成内圈 r-10 / 7 的平行弧，和灰底之间留缝，被当成错位 bug） */
        parts.push('<path d="' + arc(0, 1, r) + '" fill="none" stroke="#e3e8ee" stroke-width="10" stroke-linecap="round"/>');
        if (f > 0.001)
            parts.push('<path d="' + arc(0, f, r) + '" fill="none" stroke="' + col + '" stroke-width="10" stroke-linecap="round"/>');
        /* 刻度（在值弧内侧） */
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
        parts.push('<text x="' + cx + '" y="' + (cy - 12) + '" text-anchor="middle" ' +
            'font-size="' + fs.toFixed(0) + '" font-weight="bold" fill="' + col + '">' +
            esc(txt) + '</text>');
        if (n.caption)
            parts.push('<text x="' + cx + '" y="14" text-anchor="middle" font-size="12" fill="#5b6b7b">' +
                esc(n.caption) + '</text>');
        parts.push('</svg>');
        return parts.join('');
    }

    /* ---------------- 取色器（TLWColorPicker）---------------- */
    function applyColor(cmp, n) {
        try {
            cmp.update('<div class="lw-swatch" style="background:' +
                esc(n.value || '#ffffff') + '"></div>');
        } catch (e) { }
    }

    function openColorPicker(cmp, node) {
        if (typeof Ext.picker === 'undefined') { log('colorpicker unavailable'); return; }
        var cur = String(node.value || '#ffffff').replace('#', '');
        var win = Ext.create('Ext.window.Window', {
            title: '选择颜色',
            width: 210, height: 216,
            layout: 'fit',
            modal: false,
            resizable: false,
            closeAction: 'destroy',
            items: [{
                xtype: 'colorpicker',
                listeners: {
                    select: function (p, sel) {
                        var hex = '#' + String(sel).toUpperCase();
                        node.value = hex;
                        applyColor(cmp, node);
                        /* 值跟着事件走（服务端 LWApplyValue 写回 Color 属性）*/
                        fire(node, 'OnColorChange', { val: hex });
                        try { win.close(); } catch (e) { }
                    }
                }
            }]
        });
        /* Ext 7.5 的 Ext.picker.Color.select() 对调色板（40 个标准色）里
           不存在的颜色会空引用崩溃（selectedEl 为 null 还 addCls）。
           所以初始值绝不能放进构造配置——渲染期就会调 select，show() 当场
           抛异常：定位代码不执行 → 面板甩到视口左上角；异常再穿透事件链
           → 之后点什么都不响应。当前颜色只在弹出后 try/catch 预选，
           不在标准色里就放弃（只是色板无高亮格，选色无损）。 */
        /* 贴着取色块弹出。showAt 一步到位（show 完了再 setPosition 中间
           有空窗且多一轮布局）；坐标夹在视口范围内，别让面板半个身子出屏 */
        try {
            var b = cmp.getEl().getBox();
            var vw = Ext.Element.getViewportWidth(), vh = Ext.Element.getViewportHeight();
            var x = Math.min(Math.max(8, b.x), Math.max(8, vw - 226));
            var y = Math.min(Math.max(8, b.y + b.height + 4), Math.max(8, vh - 240));
            win.showAt(x, y);
        } catch (e) {
            win.show();
        }
        try {
            var pk = win.down('colorpicker');
            if (pk && cur) {
                try { pk.select(cur, true); } catch (eSel) { }
            }
        } catch (ePk) { }
        return win;
    }

    /* innerHTML 插进去的 <script> 不会自动执行（浏览器规定），
       TLWHTMLFrame 里想跑脚本（比如演示 AJAX 端点）就得自己重新 eval。
       内容视为可信（服务端业务代码写死的），与 Ext 的 html 配置同一信任级别。 */
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

    /* ---------------- 会话级遮罩（uniScreenMask 对应物）---------------- */
    var maskEl = null;
    function setScreenMask(show, text) {
        if (!show) {
            if (maskEl && maskEl.parentNode) {
                try { maskEl.parentNode.removeChild(maskEl); } catch (e) { }
            }
            maskEl = null;
            return;
        }
        if (!maskEl) {
            maskEl = document.createElement('div');
            maskEl.className = 'lw-mask';
            maskEl.innerHTML = '<div class="lw-mask-box">' +
                '<div class="lw-mask-spin"></div>' +
                '<div class="lw-mask-text"></div></div>';
            document.body.appendChild(maskEl);
        }
        maskEl.querySelector('.lw-mask-text').textContent = text || '';
    }

    function createNode(node, ct) {
        var cmp = null;
        try {
            cmp = build(node, ct);
        } catch (e) {
            log('create failed', node.kind, node.name, e);
            cmp = Ext.create('Ext.Component', {
                x: node.x, y: node.y, width: node.w, height: node.h,
                autoEl: { tag: 'div', html: '<div class="lw-unknown">' + esc(node.cls || node.kind) + '</div>' }
            });
            if (ct) ct.add(cmp);
        }
        if (!cmp) return null;
        if (node.id) { S.comps[node.id] = cmp; S.nodes[node.id] = node; }
        cmp.__lwNode = node;
        applyStyle(cmp, node);
        applyHint(cmp, node);
        bindEvents(cmp, node);
        return cmp;
    }

    function addTo(cmp, ct) {
        if (!ct || !cmp) return cmp;
        ct.add(cmp);
        cmp.__lwParent = ct;
        return cmp;
    }

    function build(node, ct) {
        var cfg = baseCfg(node), k = node.kind, c;

        switch (k) {
            case 'form':
                return buildForm(node);

            case 'label':
            case 'static':
                cfg.autoEl = {
                    tag: 'div',
                    html: esc(node.text != null ? node.text : node.caption),
                    style: 'white-space:' + (node.wordwrap ? 'normal' : 'nowrap') + ';overflow:hidden;'
                };
                if (node.textalign === 1) cfg.autoEl.style += 'text-align:center;';
                else if (node.textalign === 2) cfg.autoEl.style += 'text-align:right;';
                /* TBoundLabel 的高度交给文字自己：LCL 给的 24px 盒子里文字只
                   占上半部分，固定高度会在标签和编辑框之间白留一条（看起来
                   "间距偏大"）。auto 高度下盒子贴着文字走，间距就是 LabelSpacing。 */
                if (node.boundfor) delete cfg.height;
                /* TLabel.AutoSize：单行标签盒子缩到文字宽，文字贴 Left，
                   Alignment(taCenter) 因此不起作用。nogui 服务端量不准 CJK
                   字宽，宽高都不下发，绝对定位的 el 按内容自适应；
                   带换行的保留服务端宽度、高度自适应。 */
                if (node.autosize && !node.wordwrap) { delete cfg.width; delete cfg.height; }
                else if (node.autosize) delete cfg.height;
                c = addTo(Ext.create('Ext.Component', cfg), ct);
                /* TLabeledEdit 的 TBoundLabel：服务端按编辑框边界给了初值，
                   但 lpLeft/lpRight 依赖标签真实宽度（nogui 服务端量 CJK
                   会偏），渲染后按 DOM 实测宽度精修一次。
                   labelpos: lpAbove=0 lpBelow=1 lpLeft=2 lpRight=3 */
                if (node.boundfor) {
                    var fixTries = 0;
                    var fixBound = function () {
                        Ext.defer(function () {
                            try {
                                if (!c.rendered || !c.getEl()) return retryFix();
                                var ed = null, comps = Ext.ComponentQuery.query('component');
                                for (var i2 = 0; i2 < comps.length; i2++) {
                                    var n2 = comps[i2].__lwNode;
                                    if (n2 && n2.name === node.boundfor &&
                                        comps[i2].rendered && comps[i2].getEl()) { ed = comps[i2]; break; }
                                }
                                if (!ed) return retryFix();
                                /* reconcile 会换掉 __lwNode（新对象），坐标/间距
                                   一律读最新的那份，别用创建时的闭包变量 */
                                var nd = c.__lwNode || node;
                                var ee = ed.getEl(), le = c.getEl();
                                /* 页签没激活 / 窗口还没显示时盒子全是 0，这时候
                                   定位会把标签挪到面板外（刷新后"标签不见了"就是这个
                                   —— 等它可见再来一次，别拿 0 当坐标） */
                                if ((!ee.getWidth() && !ee.getHeight()) || !le.getHeight()) return retryFix();
                                var sp = (nd.labelspacing != null && nd.labelspacing >= 0) ? nd.labelspacing : 4;
                                /* Ext 的 getXY/getBox 是页面坐标，setPosition 要的是
                                   父容器局部坐标 —— 直接把页面坐标喂给 setPosition，
                                   父容器原点不在 (0,0) 时标签会整体平移（跑到编辑框
                                   下面去）。用"目标页面位置 - 当前页面位置"的差量
                                   加到当前局部坐标上，跟原点/滚动都无关。 */
                                var ep = ee.getXY(), lp = le.getXY();
                                var lbw = le.getWidth(), lbh = le.getHeight();
                                var ox = 0, oy = 0;
                                if (nd.labelpos === 0) { oy = -lbh - sp; }
                                else if (nd.labelpos === 1) { oy = ee.getHeight() + sp; }
                                else if (nd.labelpos === 2) { ox = -lbw - sp; oy = (ee.getHeight() - lbh) / 2; }
                                else if (nd.labelpos === 3) { ox = ee.getWidth() + sp; oy = (ee.getHeight() - lbh) / 2; }
                                var cur = c.getPosition(true);
                                var nx = cur[0] + (ep[0] + ox - lp[0]);
                                var ny = cur[1] + (ep[1] + oy - lp[1]);
                                c.setPosition(nx, ny);
                                /* 回写到节点：reconcile 的 runLayout 按 node.x/y 重排，
                                   不写回的话下一次事件又用 LCL 的 24px 盒坐标摆回去 */
                                nd.x = nx; nd.y = ny;
                            } catch (e) { }
                        }, fixTries ? 150 : 30);
                    };
                    var retryFix = function () { if (++fixTries <= 4) fixBound(); };
                    /* 同 checkbox：addTo 可能已渲染完，afterrender 不再来 */
                    if (c.rendered) fixBound();
                    else c.on('afterrender', function () { fixTries = 0; fixBound(); });
                    /* 页签切回来 / 窗口显示后再精修一次（隐藏期间量不到盒子） */
                    c.on('show', function () { fixTries = 0; fixBound(); });
                    c.__lwFixBound = fixBound;
                }
                return c;

            case 'button':
            case 'bitbtn':
            case 'speedbutton':
                cfg.text = node.caption || '';
                cfg.scale = 'small';
                /* TToggleBox（node.down = Checked）：可保持按下的普通按钮 */
                if (k !== 'speedbutton' && node.down != null) {
                    cfg.enableToggle = true;
                    cfg.allowDepress = node.allowup !== false;
                    cfg.pressed = !!node.down;
                }
                if (k === 'bitbtn' && node.btnkind > 0) {
                    /* TBitBtn.Kind -> 浏览器端图标按钮（见 lw.css 的 lw-bic-*） */
                    var BICONS = { 1: 'ok', 2: 'cancel', 3: 'help', 4: 'yes', 5: 'no',
                        6: 'close', 7: 'abort', 8: 'retry', 9: 'ignore',
                        10: 'all', 11: 'notoall', 12: 'yestoall' };
                    var bn = BICONS[node.btnkind];
                    if (bn) cfg.iconCls = 'lw-bic-' + bn;
                }
                if (k === 'speedbutton' && node.groupindex > 0) {
                    /* 互斥组（TSpeedButton.GroupIndex）：可保持按下 */
                    cfg.enableToggle = true;
                    cfg.allowDepress = false;
                    cfg.pressed = !!node.down;
                }
                return addTo(Ext.create('Ext.button.Button', cfg), ct);

            case 'toolbutton':
                if (node.sep) return addTo(Ext.create('Ext.toolbar.Separator', {}), ct);
                cfg.text = node.caption || '';
                cfg.scale = 'small';
                /* nogui 下 TToolButton 的 Width/Height 是 LCL 默认值（约 11px），
                   不会按 Caption 自算 —— 照搬会把"动作 1"截成"动"或者压成扁条。
                   浏览器端按文字自动排宽高，忽略服务端宽度和高度。 */
                delete cfg.width;
                delete cfg.height;
                delete cfg.x;
                delete cfg.y;
                return addTo(Ext.create('Ext.button.Button', cfg), ct);

            case 'fileupload':
                cfg.text = node.caption || '上传文件…';
                cfg.scale = 'small';
                c = Ext.create('Ext.button.Button', cfg);
                addTo(c, ct);
                c.on('click', function () { pickFile(node, c); });
                return c;

            case 'edit':
            case 'maskedit':
            case 'dbedit':
                /* TMaskEdit 的 editmask 暂不在浏览器端执行掩码校验
                   （见审计报告：已知限制），按普通编辑框渲染 */
                cfg.fieldStyle = fieldStyleOf(node);
                cfg.value = node.text || '';
                cfg.readOnly = !!node.readonly;
                cfg.maxLength = node.maxlength || undefined;
                if (node.password) cfg.inputType = 'password';
                return addTo(Ext.create('Ext.form.field.Text', cfg), ct);

            case 'editbtn':
                /* TCustomEditButton 族（TFileNameEdit/TDirectoryEdit…）：
                   单行编辑框 + "…"按钮，按钮点击回传 OnButtonClick */
                cfg.fieldStyle = fieldStyleOf(node);
                cfg.value = node.text || '';
                cfg.readOnly = !!node.readonly;
                cfg.triggers = {
                    pick: {
                        weight: 1,
                        cls: Ext.baseCSSPrefix + 'form-search-trigger',
                        handler: function () { fire(node, 'OnButtonClick'); }
                    }
                };
                return addTo(Ext.create('Ext.form.field.Text', cfg), ct);

            case 'memo':
            case 'dbmemo':
                cfg.fieldStyle = fieldStyleOf(node);
                cfg.value = (node.text || '').replace(/\r\n/g, '\n');
                cfg.readOnly = !!node.readonly;
                return addTo(Ext.create('Ext.form.field.TextArea', cfg), ct);

            case 'spin':
                cfg.value = node.value || 0;
                cfg.minValue = node.min != null ? node.min : undefined;
                cfg.maxValue = node.max != null ? node.max : undefined;
                cfg.hideTrigger = false;
                return addTo(Ext.create('Ext.form.field.Number', cfg), ct);

            case 'floatspin':
                cfg.value = node.value || 0;
                cfg.decimalPrecision = node.decimals || 2;
                cfg.minValue = node.min != null ? node.min : undefined;
                cfg.maxValue = node.max != null ? node.max : undefined;
                return addTo(Ext.create('Ext.form.field.Number', cfg), ct);

            case 'dateedit':
                /* TDateEdit -> Ext datefield。value 用服务端下发的 ISO 串，
                   显示格式统一 Y-m-d，与服务端 ScanDateTime 的解析格式一致 */
                cfg.format = 'Y-m-d';
                cfg.value = node.iso || '';
                cfg.readOnly = !!node.readonly;
                cfg.editable = !node.readonly;
                return addTo(Ext.create('Ext.form.field.Date', cfg), ct);

            case 'timeedit':
                /* TTimeEdit -> Ext timefield，格式统一 H:i:s */
                cfg.format = 'H:i:s';
                cfg.value = node.iso || '';
                cfg.readOnly = !!node.readonly;
                cfg.editable = !node.readonly;
                return addTo(Ext.create('Ext.form.field.Time', cfg), ct);

            case 'chart':
                /* TLWChart（uniChart 对应物）：ext 的 charts 包渲染 */
                return addTo(buildChart(node, cfg), ct);

            case 'gauge': {
                /* TLWGauge：纯 SVG，不吃 charts 包 */
                var g = Ext.create('Ext.Component', cfg);
                g.update(gaugeSvg(node));
                g.__lwGaugeSig = gaugeSig(node);
                return addTo(g, ct);
            }

            case 'color': {
                /* TLWColorPicker：色块 + 点开调色板。
                   懒加载页签里创建时 el 还没渲染，用 onEl 挂 afterrender */
                var cp = Ext.create('Ext.Component', cfg);
                applyColor(cp, node);
                onEl(cp, 'click', function () {
                    openColorPicker(cp, S.nodes[node.id] || node);
                });
                try {
                    cp.on('afterrender', function () {
                        try { cp.getEl().setStyle('cursor', 'pointer'); } catch (e2) { }
                    });
                } catch (e) { }
                return addTo(cp, ct);
            }

            case 'checkbox':
            case 'dbcheckbox':
                cfg.boxLabel = node.caption || '';
                /* LCL 三态：State=cbGrayed(2)。Ext 复选框原生不支持第三态，
                   用 DOM 的 indeterminate 补上（渲染后打补丁） */
                cfg.checked = !!node.checked;
                cfg.inputValue = '1';
                c = addTo(Ext.create('Ext.form.field.Checkbox', cfg), ct);
                if (node.state === 2) {
                    c.__lwGrayed = true;
                    var setInd = function () {
                        try {
                            if (c.inputEl) c.inputEl.dom.indeterminate = true;
                            else window.__lwIndErr = 'no inputEl';
                        } catch (e) { window.__lwIndErr = String(e); }
                    };
                    /* addTo 里 ct.add() 可能已经把组件渲染完（afterrender 已
                       触发），此时 on('afterrender') 永远不会再跑 —— 先判
                       rendered，已渲染就立即打 + 延迟补 */
                    if (c.rendered) {
                        setInd();
                        Ext.defer(setInd, 50);
                        Ext.defer(setInd, 300);
                    } else {
                        c.on('afterrender', function () {
                            setInd();
                            Ext.defer(setInd, 50);
                            Ext.defer(setInd, 300);
                        });
                    }
                }
                return c;

            case 'radio':
                cfg.boxLabel = node.caption || '';
                cfg.checked = !!node.checked;
                cfg.name = 'lwradio_' + (node.group || 'g');
                cfg.inputValue = String(node.id);
                return addTo(Ext.create('Ext.form.field.Radio', cfg), ct);

            case 'combo':
            case 'dbcombo':
                cfg.fieldStyle = fieldStyleOf(node);
                cfg.store = Ext.create('Ext.data.Store', {
                    fields: ['text'],
                    data: (node.items || []).map(function (t) { return { text: t }; })
                });
                cfg.queryMode = 'local';
                cfg.displayField = 'text';
                cfg.valueField = 'text';
                cfg.editable = node.editable !== false;
                cfg.value = node.text || (node.items && node.index >= 0 ? node.items[node.index] : '');
                return addTo(Ext.create('Ext.form.field.ComboBox', cfg), ct);

            case 'listbox':
                return addTo(buildList(node, cfg), ct);

            case 'dblistbox':
                /* 数据感知列表框：选中行 = 改字段，所以要把选中回传成"第几项" */
                c = buildList(node, cfg);
                addTo(c, ct);
                if ((node.ev || []).indexOf('OnChange') >= 0) {
                    c.on('select', function (sm, rec, idx) {
                        fire(node, 'OnChange', { val: String(idx) });
                    });
                }
                return c;

            case 'dbradiogroup': {
                /* 单选组：Values[i] 才是写进字段的值，Items[i] 只是显示文字 */
                var rcfg = Ext.apply({}, cfg);
                delete rcfg.items; delete rcfg.values; delete rcfg.value; delete rcfg.field;
                rcfg.title = esc(node.caption || '');
                rcfg.layout = 'anchor';
                rcfg.defaults = { anchor: '100%' };
                c = addTo(Ext.create('Ext.form.FieldSet', rcfg), ct);
                (function () {
                    var items = node.items || [], values = node.values || [];
                    items.forEach(function (t, i) {
                        var v = String(values[i] == null ? i : values[i]);
                        var r = Ext.create('Ext.form.field.Radio', {
                            boxLabel: esc(t),
                            name: 'lwrg_' + node.id,
                            inputValue: v,
                            checked: v === String(node.value)
                        });
                        r.on('change', function () {
                            if (r.getValue()) fire(node, 'OnChange', { val: v });
                        });
                        c.add(r);
                    });
                })();
                return c;
            }

            case 'radiogroup': {
                /* 普通单选组：val 是"第几项"（与 dbradiogroup 的 Value 语义不同） */
                var rg = Ext.apply({}, cfg);
                delete rg.items; delete rg.values; delete rg.value; delete rg.field;
                rg.title = esc(node.caption || '');
                rg.layout = 'anchor';
                rg.defaults = { anchor: '100%' };
                c = addTo(Ext.create('Ext.form.FieldSet', rg), ct);
                (node.items || []).forEach(function (t, i) {
                    var r = Ext.create('Ext.form.field.Radio', {
                        boxLabel: esc(t),
                        name: 'lwrg_' + node.id,
                        inputValue: String(i),
                        checked: i === (node.index || -1)
                    });
                    r.on('change', function () {
                        if (r.getValue()) fire(node, 'OnClick', { val: String(i) });
                    });
                    c.add(r);
                });
                return c;
            }

            case 'checkgroup': {
                var cg = Ext.apply({}, cfg);
                delete cg.items; delete cg.values; delete cg.value; delete cg.field;
                cg.title = esc(node.caption || '');
                cg.layout = 'anchor';
                cg.defaults = { anchor: '100%' };
                c = addTo(Ext.create('Ext.form.FieldSet', cg), ct);
                var cks = node.checked || [];
                (node.items || []).forEach(function (t, i) {
                    var k = Ext.create('Ext.form.field.Checkbox', {
                        boxLabel: esc(t),
                        checked: !!cks[i]
                    });
                    k.on('change', function (cb, nv) {
                        fire(node, 'OnItemClick', { idx: i, val: nv ? '1' : '0' });
                    });
                    c.add(k);
                });
                return c;
            }

            case 'checklistbox': {
                var clb = Ext.apply({}, cfg);
                delete clb.items;
                clb.layout = 'fit';
                clb.bodyStyle = 'padding:4px;';
                var wrap = addTo(Ext.create('Ext.panel.Panel', clb), ct);
                var ckl = node.checked || [];
                var boxes = [];
                (node.items || []).forEach(function (t, i) {
                    var b = Ext.create('Ext.form.field.Checkbox', {
                        boxLabel: esc(t),
                        checked: !!ckl[i],
                        margin: '2 6'
                    });
                    b.on('change', function (cb, nv) {
                        fire(node, 'OnClickCheck', {
                            val: String(i),
                            checked: boxes.map(function (x) { return !!x.checked; })
                        });
                        fire(node, 'OnClick', { val: String(i) });
                    });
                    wrap.add(b);
                    boxes.push(b);
                });
                wrap.__lwBoxes = boxes;
                return wrap;
            }

            case 'valeditor': {
                /* 键值对编辑器：两列网格，值列可编辑，编辑完成回发 OnValidate */
                var ve = Ext.apply({}, cfg);
                delete ve.items;
                ve.layout = 'fit';
                var vkeys = node.keys || [], vvals = node.values || [];
                var vdata = vkeys.map(function (k, i) {
                    return { lwRow: i, key: k, value: vvals[i] == null ? '' : String(vvals[i]) };
                });
                ve.store = Ext.create('Ext.data.Store', {
                    fields: ['lwRow', 'key', 'value'],
                    data: vdata
                });
                var titles = String(node.titles || '键,值').split(',');
                ve.columns = [
                    { text: esc(titles[0] || 'Key'), dataIndex: 'key', width: 110,
                      menuDisabled: true, sortable: false },
                    { text: esc(titles[1] || 'Value'), dataIndex: 'value', flex: 1,
                      menuDisabled: true, sortable: false,
                      editor: { xtype: 'textfield' } }
                ];
                ve.plugins = [Ext.create('Ext.grid.plugin.CellEditing', { clicksToEdit: 1 })];
                var vgrid = Ext.create('Ext.grid.Panel', ve);
                vgrid.__lwSig = JSON.stringify(vdata);
                vgrid.on('edit', function (ed, ctx) {
                    fire(node, 'OnValidate', {
                        row: ctx.rowIdx,
                        key: ctx.record.get('key'),
                        val: ctx.value == null ? '' : String(ctx.value)
                    });
                });
                vgrid.on('selectionchange', function (sm) {
                    var sels = sm.getSelection();
                    if (sels.length) {
                        var ri = sels[0].get('lwRow');
                        if (vgrid.__lwSel !== ri) {
                            vgrid.__lwSel = ri;
                            fire(node, 'OnClick', { val: String(ri), row: ri });
                        }
                    }
                });
                if ((node.selrow || -1) >= 0) {
                    vgrid.on('afterrender', function () {
                        try { vgrid.getSelectionModel().select(node.selrow); } catch (e) { }
                    });
                }
                return addTo(vgrid, ct);
            }

            case 'dblookuplist':
                /* 外键列表：显示 ListField，回传 KeyField */
                c = buildList(node, cfg);
                addTo(c, ct);
                if ((node.ev || []).indexOf('OnChange') >= 0) {
                    c.on('select', function (sm, rec, idx) {
                        var keys = node.keys || [];
                        fire(node, 'OnChange', { val: String(keys[idx] == null ? '' : keys[idx]) });
                    });
                }
                return c;

            case 'dblookup':
                /* 外键下拉：显示 ListField，回传 KeyField */
                cfg.fieldStyle = fieldStyleOf(node);
                cfg.store = Ext.create('Ext.data.Store', {
                    fields: ['text', 'key'],
                    data: (node.items || []).map(function (t, i) {
                        var k = (node.keys || [])[i];
                        return { text: t, key: k == null ? '' : String(k) };
                    })
                });
                cfg.queryMode = 'local';
                cfg.displayField = 'text';
                cfg.valueField = 'key';
                cfg.editable = false;
                cfg.value = node.key != null ? String(node.key) : '';
                return addTo(Ext.create('Ext.form.field.ComboBox', cfg), ct);

            case 'dbgrid':
                return addTo(buildDBGrid(node, cfg), ct);

            case 'grid':
            case 'drawgrid':
            case 'listview':
                return addTo(buildGrid(node, cfg), ct);

            case 'tree':
                return addTo(buildTree(node, cfg), ct);

            case 'progress':
                cfg.value = (node.max ? (node.pos || 0) / node.max : 0);
                cfg.text = (node.pos || 0) + ' / ' + (node.max || 100);
                return addTo(Ext.create('Ext.ProgressBar', cfg), ct);

            case 'trackbar':
                try {
                    cfg.value = node.pos || 0;
                    cfg.minValue = node.min || 0;
                    cfg.maxValue = node.max || 100;
                    /* 竖直滑条（Orientation=trVertical）：不下发/不消费的话
                       40x150 的竖条会被渲染成一条横滑条挤在小格里 */
                    if (node.orientation === 1) cfg.vertical = true;
                    return addTo(Ext.create('Ext.slider.Single', cfg), ct);
                } catch (e) {
                    cfg.autoEl = { tag: 'div', html: esc('slider ' + (node.pos || 0)) };
                    return addTo(Ext.create('Ext.Component', cfg), ct);
                }

            case 'image':
            case 'dbimage':
                cfg.src = node.src || Ext.BLANK_IMAGE_URL;
                return addTo(Ext.create('Ext.Img', cfg), ct);

            case 'htmlframe':
                /* TLWHTMLFrame（uniHTMLFrame 对应物）：面板里渲染一段任意 HTML。
                   内容是业务代码给的，视作可信内容原样交给 ext 的 html 配置 */
                cfg.layout = 'fit';
                cfg.border = true;
                cfg.html = node.html || '';
                cfg.autoScroll = true;
                c = addTo(Ext.create('Ext.panel.Panel', cfg), ct);
                c.__lwHtmlSig = node.html || '';
                execHtmlScripts(c.getEl() && (c.getEl().dom || c.getEl()));
                return c;

            case 'pdfframe':
                /* TLWPDFFrame（uniPDFFrame 对应物）：iframe + 浏览器自带
                   PDF 查看器，不引第三方库。src 由服务端签发令牌下发 */
                return addTo(buildPDFFrame(node, cfg), ct);

            case 'panel':
            case 'scrollbox':
            case 'frame':
                cfg.layout = 'absolute';
                /* bevel(bvRaised/bvLowered) 也给边框，caption 非缺省时居中显示，
                   scrollbox 恒可滚（LCL ScrollBox 语义，见 lw-alpine.js 同分支） */
                cfg.border = (node.border === 'single' || !!node.bevel);
                cfg.header = false;
                cfg.bodyStyle = node.bg ? 'background:' + node.bg : '';
                if (node.autoscroll || node.kind === 'scrollbox') cfg.autoScroll = true;
                if (node.caption && node.caption !== node.name)
                    cfg.html = '<div class="lw-panel-cap">' + esc(node.caption) + '</div>';
                c = Ext.create('Ext.panel.Panel', cfg);
                addTo(c, ct);
                syncChildren(c, node);
                return c;

            case 'groupbox':
                cfg.title = esc(node.caption || '');
                cfg.layout = 'absolute';
                cfg.bodyPadding = 0;
                cfg.collapsible = false;
                c = Ext.create('Ext.form.FieldSet', cfg);
                addTo(c, ct);
                syncChildren(c, node);
                return c;

            case 'tabs':
                return addTo(buildTabs(node, cfg), ct);

            case 'tabctl':
                /* TTabControl：页签是字符串列表，全部子控件共用一块客户区
                   （与 TPageControl 的"每页一套"不同）—— 单卡片 tabpanel */
                return addTo(buildTabCtl(node, cfg), ct);

            case 'tabsheet':
                return addTo(buildTabSheet(node, cfg), ct);

            case 'toolbar':
                cfg.layout = { type: 'hbox', align: 'middle' };
                cfg.border = false;
                c = Ext.create('Ext.toolbar.Toolbar', cfg);
                addTo(c, ct);
                syncChildren(c, node);
                return c;

            case 'dbnav':
                return addTo(buildDBNav(node, cfg), ct);

            case 'statusbar':
                cfg.autoEl = { tag: 'div', html: esc((node.panels || []).join('   |   ')) };
                return addTo(Ext.create('Ext.Component', cfg), ct);

            /* 装饰/布局类控件：没有交互，只要把"线/块"画对位置就行 */
            case 'bevel':
                /* 宽高写进内联样式：bevel 没有内容，自然尺寸 0。依赖
                   cfg.width 在渲染期落地有时机竞态（懒加载页签里容器
                   未渲染时创建，尺寸配置可能不落地 → 只剩 2px 边框），
                   内联样式与创建/渲染顺序完全无关。 */
                cfg.autoEl = {
                    tag: 'div',
                    cls: 'lw-bevel',
                    style: 'width:' + (node.w || 10) + 'px;height:' + (node.h || 10) + 'px;'
                };
                return addTo(Ext.create('Ext.Component', cfg), ct);

            case 'shape':
                /* shapestyle: 0 矩形 1 正方形 2 圆角矩形 3 圆角正方形 4 椭圆 5 圆 */
                var srad = { 2: '10px', 3: '10px', 4: '50%', 5: '50%' }[node.shapestyle];
                cfg.autoEl = {
                    tag: 'div',
                    style: 'width:' + (node.w || 10) + 'px;height:' + (node.h || 10) + 'px;' +
                        'background:' + (node.bg || '#ffffff') +
                        ';border:1px solid rgba(0,0,0,.35);' +
                        (srad ? 'border-radius:' + srad + ';' : '')
                };
                return addTo(Ext.create('Ext.Component', cfg), ct);

            case 'splitter':
                cfg.autoEl = { tag: 'div', cls: 'lw-splitter' };
                return addTo(Ext.create('Ext.Component', cfg), ct);

            case 'updown':
                /* TUpDown 是"配着别的编辑框用"的小控件，单独渲染成一个
                   上下箭头的数字框，位置和尺寸与设计期一致 */
                cfg.value = (node.value != null ? node.value : 0);
                if (node.min != null) cfg.minValue = node.min;
                if (node.max != null) cfg.maxValue = node.max;
                cfg.hideTrigger = false;
                cfg.width = node.w || 18;
                return addTo(Ext.create('Ext.form.field.Number', cfg), ct);

            default:
                cfg.autoEl = {
                    tag: 'div',
                    html: '<div class="lw-unknown" title="' + esc(node.cls || '') + '">' +
                        esc(node.cls || node.kind) + '</div>'
                };
                return addTo(Ext.create('Ext.Component', cfg), ct);
        }
    }

    function buildList(node, cfg) {
        cfg.hideHeaders = true;
        /* 坑 85：LCL TListBox/TCheckListBox 默认 bsSingle 有边框；
           服务端下发 border（BorderStyleToStr），缺省按有边框处理 */
        cfg.border = (node.border !== 'none');
        /* 单选且点了已选行不取消（LCL TListBox.ItemIndex 语义） */
        cfg.selModel = { mode: 'SINGLE', toggleOnClick: false };
        cfg.columns = [{ dataIndex: 'text', flex: 1 }];
        cfg.store = Ext.create('Ext.data.Store', {
            fields: ['text'],
            data: (node.items || []).map(function (t) { return { text: t }; })
        });
        var g = Ext.create('Ext.grid.Panel', cfg);
        if (node.index >= 0) {
            g.on('afterrender', function () {
                try { g.getSelectionModel().select(node.index); } catch (e) { }
            });
        }
        return g;
    }

    function buildGrid(node, cfg) {
        var cols = node.cols || [];
        var widths = node.colwidths || [];
        var columns = [], i;
        for (i = 0; i < cols.length; i++) {
            var w = widths[i] && widths[i] > 0 ? widths[i] : null;
            columns.push({
                text: esc(cols[i]),
                dataIndex: 'c' + i,
                flex: w ? undefined : 1,
                width: w || undefined,
                editor: (node.readonly ? undefined : 'textfield')
            });
        }
        var data = (node.rows || []).map(function (row, ri) {
            var o = { lwRow: ri };
            for (var j = 0; j < row.length; j++) o['c' + j] = row[j];
            return o;
        });
        cfg.columns = columns;
        cfg.columnLines = true;
        cfg.border = true;
        cfg.store = Ext.create('Ext.data.Store', {
            fields: [{ name: 'lwRow', type: 'int' }].concat(cols.map(function (_, idx) { return 'c' + idx; })),
            data: data
        });
        if (!node.readonly) {
            cfg.plugins = [Ext.create('Ext.grid.plugin.CellEditing', { clicksToEdit: 1 })];
        }
        var grid = Ext.create('Ext.grid.Panel', cfg);
        grid.on('edit', function (editor, ctx) {
            var rec = ctx.record, field = ctx.column.dataIndex;
            var col = parseInt(field.substring(1), 10);
            var val = rec.get(field);
            fire(node, 'OnEditingDone', { val: val == null ? '' : String(val), row: rec.get('lwRow'), col: col });
        });
        return grid;
    }

    /* ---------------- 图表（TLWChart，ext charts 包） ---------------- */

    function chartSig(n) {
        return JSON.stringify([n.charttype, n.title, n.categories, n.series]);
    }

    function chartStoreOf(n) {
        var cats = n.categories || [], series = n.series || [];
        var fields = ['cat'].concat(series.map(function (_, i) { return 's' + i; }));
        var data = cats.map(function (c, i) {
            var o = { cat: c };
            series.forEach(function (s, j) {
                o['s' + j] = parseFloat((s.values || [])[i]) || 0;
            });
            return o;
        });
        return Ext.create('Ext.data.JsonStore', { fields: fields, data: data });
    }

    function makeCartesianChart(n) {
        var series = n.series || [];
        var sers = series.map(function (s, i) {
            return {
                type: n.charttype === 'bar' ? 'bar' : 'line',
                xField: 'cat',
                yField: 's' + i,
                title: s.name || ('S' + (i + 1)),
                smooth: n.charttype === 'bar' ? 0 : 3
            };
        });
        return Ext.create('Ext.chart.CartesianChart', {
            store: chartStoreOf(n),
            axes: [
                { type: 'numeric', position: 'left',
                  fields: series.map(function (_, i) { return 's' + i; }),
                  grid: true, minimum: 0 },
                { type: 'category', position: 'bottom', fields: 'cat' }
            ],
            series: sers,
            legend: series.length > 1 ? { dock: 'bottom' } : null
        });
    }

    function makePieChart(n) {
        /* 饼图取第一个系列的数值，Categories 是扇区标签 */
        var s = (n.series && n.series[0]) || { values: [] };
        var cats = n.categories || [];
        var data = cats.map(function (c, i) {
            return { cat: c, v: parseFloat((s.values || [])[i]) || 0 };
        });
        return Ext.create('Ext.chart.PolarChart', {
            store: Ext.create('Ext.data.JsonStore', { fields: ['cat', 'v'], data: data }),
            series: [{
                type: 'pie',
                angleField: 'v',
                label: { field: 'cat', calloutLine: true },
                highlight: true
            }],
            legend: { dock: 'right' }
        });
    }

    function buildChart(node, cfg) {
        cfg.layout = 'fit';
        cfg.border = true;
        var p = Ext.create('Ext.panel.Panel', cfg);
        p.__lwChartSig = chartSig(node);
        if (typeof Ext.chart === 'undefined') {
            /* 当前 ext 目录里没有 charts 包（服务端按文件是否存在决定注入） */
            p.update('<div class="lw-unknown">chart：当前 Ext 目录未提供 charts 包</div>');
            return p;
        }
        try {
            p.add(node.charttype === 'pie' ? makePieChart(node) : makeCartesianChart(node));
        } catch (e) {
            log('chart build failed', e);
            p.update('<div class="lw-unknown">chart 构建失败</div>');
        }
        return p;
    }

    /* DBNavigator（TDBNavigator / TLWDBNavigator）：
       服务端只下发按钮清单与各自的 Enabled，图标浏览器端自己画
       （nogui 服务端没有位图资源可用）。点击 -> OnClick + val=按钮名，
       服务端转成 BtnClick()，删除按钮会触发服务端的确认对话框。 */
    var LW_NAV_GLYPH = {
        first: '|◀', prior: '◀', next: '▶', last: '▶|',
        insert: '＋', delete: '✖', edit: '✎', post: '✓',
        cancel: '↶', refresh: '↻'
    };
    var LW_NAV_TIP = {
        first: '第一条', prior: '上一条', next: '下一条', last: '最后一条',
        insert: '插入', delete: '删除', edit: '编辑', post: '保存',
        cancel: '取消', refresh: '刷新'
    };

    function buildDBNav(node, cfg) {
        cfg.layout = { type: 'hbox', align: 'middle', padding: '0 2' };
        cfg.border = false;
        var bar = Ext.create('Ext.toolbar.Toolbar', cfg);
        (node.buttons || []).forEach(function (b) {
            var btn = Ext.create('Ext.button.Button', {
                text: LW_NAV_GLYPH[b.id] || b.id,
                scale: 'small',
                tooltip: LW_NAV_TIP[b.id] || b.id,
                disabled: b.en === false
            });
            btn.__lwBtnId = b.id;
            btn.on('click', function () { fire(node, 'OnClick', { val: b.id }); });
            bar.add(btn);
        });
        return bar;
    }

    /* DBGrid：数据在服务端的数据集里，浏览器只负责显示，
       并把"点了哪一行 / 点了哪一列表头"回传。
       行点击 -> OnCellClick（服务端先定位数据集游标，再调事件）
       表头点击 -> OnTitleClick（业务代码里做排序） */
    /* 分页/汇总工具条文案（TLWDBGrid 的 PageSize / Summary* 驱动） */
    function pagerText(n) {
        var total = (n.total != null ? n.total : (n.count || 0));
        if ((n.pages || 0) > 1)
            return '第 ' + (n.page || 1) + ' / ' + n.pages + ' 页 · 共 ' + total + ' 条';
        return '共 ' + total + ' 条';
    }

    function summaryText(sm) {
        var names = { sum: '合计', avg: '平均', count: '计数' };
        return (names[sm.type] || '') + ' ' + (sm.field || '') + ' = ' +
            (sm.value == null ? '' : sm.value);
    }

    function buildDBGrid(node, cfg) {
        cfg.columns = dbColumns(node);
        cfg.columnLines = true;
        cfg.border = true;
        cfg.selType = 'rowmodel';
        cfg.multiSelect = false;
        cfg.viewConfig = { stripeRows: true, markDirty: !node.readonly };
        cfg.store = buildGridStore(node);
        if (!node.readonly) {
            /* 服务端开了 dgEditing：挂 CellEditing，可编辑列（cedit=1）
               挂文本编辑器，编辑完成后回发 OnSetFieldValue 让服务端
               写进数据集。列编辑器统一 textfield，类型校验交给字段本身。
               编辑器在 dbEditColumns 里挂 —— 补丁路径 reconfigure 必须带同样的 */
            cfg.plugins = [Ext.create('Ext.grid.plugin.CellEditing', { clicksToEdit: 1 })];
            cfg.columns = dbEditColumns(node);
        }
        /* 顶部过滤条（TLWDBGrid.ShowFilter）：回车提交 OnFilter，
           服务端做显示层过滤并回到第 1 页 */
        if (node.showfilter) {
            cfg.tbar = {
                border: false,
                items: ['过滤:', {
                    xtype: 'textfield',
                    flex: 1,
                    emptyText: '输入关键字后回车…',
                    value: node.filtertext || '',
                    listeners: {
                        specialkey: function (f, e) {
                            if (e.getKey() === e.ENTER) {
                                e.stopEvent();
                                fire(node, 'OnFilter', { val: f.getValue() });
                            }
                        }
                    }
                }]
            };
        }
        /* 底部分页条 + 汇总（TLWDBGrid.PageSize / SummaryType）：
           翻页回发 OnPageChange（页号），服务端下发对应页的行 */
        if ((node.pages || 0) > 1 || node.summary) {
            var bar = [];
            if ((node.pages || 0) > 1) {
                /* 闭包里的 node 是构建时的快照，翻页后 page 已过期 ——
                   每次点击都从 S.nodes 取最新节点，否则"下一页"永远算成 2 */
                function liveNode() { return S.nodes[node.id] || node; }
                function pageTo(p) {
                    var cur = liveNode();
                    p = Math.min(Math.max(1, p), cur.pages || 1);
                    if (p === (cur.page || 1)) return;
                    fire(cur, 'OnPageChange', { val: String(p) });
                }
                bar.push(
                    { text: '⏮', scale: 'small', tooltip: '首页', handler: function () { pageTo(1); } },
                    { text: '◀', scale: 'small', tooltip: '上一页', handler: function () { pageTo((liveNode().page || 1) - 1); } },
                    { xtype: 'tbtext', itemId: 'lwpg', text: pagerText(node) },
                    { text: '▶', scale: 'small', tooltip: '下一页', handler: function () { pageTo((liveNode().page || 1) + 1); } },
                    { text: '⏭', scale: 'small', tooltip: '末页', handler: function () { pageTo(liveNode().pages || 1); } }
                );
            }
            if (node.summary) {
                bar.push('-', { xtype: 'tbtext', itemId: 'lwsum', text: summaryText(node.summary) });
            }
            cfg.bbar = { border: false, items: bar };
        }
        var grid = Ext.create('Ext.grid.Panel', cfg);
        grid.__lwSig = dbSig(node);
        grid.__lwColSig = dbColSig(node);

        grid.on('itemclick', function (v, rec, item, idx, e) {
            var col = 0;
            try {
                var td = e && e.target ? e.target : null;
                while (td && td.tagName !== 'TD') td = td.parentNode;
                if (td) col = td.cellIndex;
            } catch (x) { }
            /* 布尔列（cedit=4）：点一格就切换并回发，和桌面端 TDBGrid
               里的勾选框同一手感，不进编辑态（列上没挂编辑器） */
            if (!node.readonly && ((node.cedit || [])[col] === 4)) {
                var nv = !rec.get('c' + col);
                rec.set('c' + col, nv);
                try { grid.getView().refreshNode(idx); } catch (x) { }
                fire(node, 'OnSetFieldValue', { val: nv ? '1' : '0', row: rec.get('lwRow'), col: col });
                return;
            }
            fire(node, 'OnCellClick', { row: rec.get('lwRow'), col: col });
        });
        grid.on('headerclick', function (ct, column) {
            var col = 0;
            try { col = parseInt(String(column.dataIndex).substring(1), 10) || 0; } catch (x) { }
            fire(node, 'OnTitleClick', { col: col });
        });
        if (!node.readonly) {
            grid.on('edit', function (editor, ctx) {
                var rec = ctx.record;
                var col = parseInt(String(ctx.column.dataIndex).substring(1), 10) || 0;
                var v = ctx.value == null ? '' : ctx.value;
                /* 日期编辑器的 ctx.value 是 Date 对象：格式化成 ISO 串再回发，
                   服务端 LWISOToDateTime 只认 'yyyy-mm-dd' */
                if (v instanceof Date) v = Ext.Date.format(v, 'Y-m-d');
                v = String(v);
                fire(node, 'OnSetFieldValue', { val: v, row: rec.get('lwRow'), col: col });
            });
        }
        grid.on('afterrender', function () { selectDBRow(grid, node); });
        return grid;
    }

    function dbColumns(n) {
        var cols = n.cols || [], widths = n.colwidths || [], out = [];
        for (var i = 0; i < cols.length; i++) {
            var w = widths[i] > 0 ? widths[i] : null;
            out.push({
                text: esc(cols[i]),
                dataIndex: 'c' + i,
                flex: w ? undefined : 1,
                width: w || undefined,
                menuDisabled: true,
                sortable: false
            });
        }
        return out;
    }

    /* 行数据 -> store 记录。布尔列（cedit=4）必须转成真正的 boolean：
       服务端发的是 '1'/'0' 字符串，而 '0' 在 JS 里是真值，直接喂给
       勾选框渲染器会把全表都画成选中 */
    function gridRowObj(n, row, ri) {
        var eds = n.cedit || [];
        var o = { lwRow: ri };
        for (var j = 0; j < row.length; j++) {
            var v = row[j];
            if (eds[j] === 4) v = (v === true || String(v) === '1');
            o['c' + j] = v;
        }
        return o;
    }

    /* 行数据 + 列定义的指纹；服务端在编辑态下不发 rows，指纹保持不变 */
    function dbSig(n) {
        return JSON.stringify(n.rows || null) + '#' + JSON.stringify(n.cols || null);
    }

    /* 列定义指纹（补丁路径判断"列没变"用；dbSig 里 rows 文本可能含 '#'，
       不能用 split 取列部分） */
    function dbColSig(n) {
        return JSON.stringify(n.cols || null);
    }

    /* 坑79：行数据直接灌进现有 store。reconfigure 会复用列实例但销毁
       编辑器字段，Ext 配置系统的 reap 随后把 column.editor 清成 null
       —— CellEditing 从此起不来，表现为"网格只能编辑一个单元格"。 */
    function fillGridRows(store, n) {
        store.loadData((n.rows || []).map(function (row, ri) {
            return gridRowObj(n, row, ri);
        }));
    }

    /* 可编辑网格的列：dbColumns + 按列挂编辑器（cedit：0=只读 1=文本
       2=PickList 下拉 3=日期选择，plist 按同下标带选项）。
       坑79：必须首建和补丁共用 —— 编辑回发后的树补丁走 reconfigure 重建
       列，若这里不带 editor，第一次编辑完成后 CellEditing 就再也起不来
       （只能改一个单元格）。 */
    function dbEditColumns(n) {
        var cols = dbColumns(n);
        if (!n.readonly) {
            var eds = n.cedit || [];
            var pls = n.plist || [];
            for (var i = 0; i < cols.length; i++) {
                if (eds[i] === 0) continue;
                if (eds[i] === 2) {
                    cols[i].editor = Ext.create('Ext.form.field.ComboBox', {
                        editable: false,
                        queryMode: 'local',
                        store: pls[i] || []
                    });
                } else if (eds[i] === 3) {
                    cols[i].editor = { xtype: 'datefield', format: 'Y-m-d',
                                       altFormats: 'Y-m-d|Ymd|YmdHis' };
                } else if (eds[i] === 4) {
                    /* 布尔列：画一个勾选框，点击由 buildDBGrid 的 itemclick
                       切换（不挂编辑器 —— 勾选框不需要进编辑态） */
                    cols[i].align = 'center';
                    cols[i].renderer = function (v) {
                        return '<span class="lw-xchk' + (v ? ' lw-xchk-on' : '') + '"></span>';
                    };
                } else {
                    cols[i].editor = { xtype: 'textfield' };
                }
            }
        }
        return cols;
    }

    function selectDBRow(grid, node) {
        try {
            var sm = grid.getSelectionModel();
            var store = grid.getStore();
            var idx = (node.recno || 0) - 1;
            if (idx >= 0 && idx < store.getCount()) {
                sm.select(idx, false, true);
                try { grid.getView().scrollRowIntoView(idx); } catch (x) { }
            } else {
                sm.deselectAll(true);
            }
        } catch (e) { }
    }

    function buildTree(node, cfg) {
        function conv(list) {
            return (list || []).map(function (n) {
                return {
                    text: esc(n.text),
                    expanded: !!n.expanded,
                    leaf: !(n.children && n.children.length),
                    children: conv(n.children)
                };
            });
        }
        cfg.rootVisible = false;
        /* 坑 86：LCL TTreeView 默认 bsSingle 有边框，别写死 false；
           服务端下发 border，缺省按有边框处理 */
        cfg.border = (node.border !== 'none');
        cfg.store = Ext.create('Ext.data.TreeStore', {
            root: { expanded: true, children: conv(node.nodes) }
        });
        cfg.columns = [{ xtype: 'treecolumn', text: '', dataIndex: 'text', flex: 1 }];
        return Ext.create('Ext.tree.Panel', cfg);
    }

    /* TLWPDFFrame：一个填满面板的 iframe。url 为空时显示占位提示；
       服务端换文件后 url 变化，patchNode 里直接换 src 触发浏览器重新加载 */
    function buildPDFFrame(node, cfg) {
        var has = !!node.url;
        cfg.layout = 'fit';
        cfg.border = true;
        if (has) {
            cfg.items = [Ext.create('Ext.Component', {
                autoEl: { tag: 'iframe', src: node.url, frameborder: 0,
                          style: 'width:100%;height:100%;border:0;' }
            })];
        } else {
            cfg.html = '<div class="lw-unknown">PDF：尚未指定文件</div>';
        }
        var p = Ext.create('Ext.panel.Panel', cfg);
        p.__lwUrlSig = node.url || '';
        return p;
    }

    function buildTabs(node, cfg) {
        cfg.layout = 'card';
        cfg.activeTab = node.active || 0;
        cfg.border = false;
        /* TPageControl.TabPosition = tpBottom：页签条放底部 */
        if (node.tabpos === 1) cfg.tabBar = { dock: 'bottom' };
        cfg.items = [];
        var tabs = Ext.create('Ext.tab.Panel', cfg);
        syncChildren(tabs, node);
        /* activeTab 必须在子项挂好之后再显式激活一次：
           Ext.tab.Panel.initComponent 里是 `activeTab = getComponent(activeTab)`，
           构造时 items 还是空的 -> 解析成 undefined，整条标签栏没有任何一页是
           active 态（gallery 默认页"标准控件"不选中，正是这个问题）。
           此时 tabchange 还没绑，不会误回传服务端。 */
        try {
            var want = typeof node.active === 'number' ? node.active : 0;
            if (want >= 0 && want < tabs.items.getCount()) tabs.setActiveTab(want);
        } catch (e) { }
        /* TPageControl.OnChange：服务端业务经常挂在页签切换上
           （gallery 的 pcMainChange 就靠它回显），之前一直没绑。
           索引按控件 id 建表查——直接 indexOf(children) 在补丁轮次后
           会失配（children 每次都是新对象），结果永远回 0。 */
        if ((node.ev || []).indexOf('OnChange') >= 0) {
            var tabIndex = {};
            (node.children || []).forEach(function (ch, i) { tabIndex[ch.id] = i; });
            tabs.on('tabchange', function (tp, newCard) {
                /* 服务端改 ActivePage 引发的同步不回调，否则两边乒乓 */
                if (tabs.__lwSilentTab) return;
                if (!newCard || !newCard.__lwNode) return;
                var idx = tabIndex[newCard.__lwNode.id];
                fire(node, 'OnChange', { val: String(idx == null ? 0 : idx) });
            });
        }
        /* Crisp 主题下，标签条如果在宿主还没完成布局时测量会得到 0 高，
           表现为标签文字被拦腰裁掉。渲染后强制再排一次。 */
        tabs.on('afterrender', function () {
            Ext.defer(function () {
                try { tabs.getTabBar().updateLayout(); } catch (e) { }
                try { tabs.updateLayout(); } catch (e) { }
            }, 30);
        });
        return tabs;
    }

    /* TTabControl：Tabs 字符串列表 + 公共客户区。
       每个 tabitem 建一张卡（之前只建一张卡、页签条上只有一项，点了
       永远切不动）；子控件挂在初始活动卡上，切页签时把子控件集搬进
       新卡（syncChildren 按 __lwParent 判断会销毁重建），保持"公共
       客户区"语义。tabchange 无条件回传 OnChange —— 服务端
       LWApplyValue 先同步 TabIndex，没挂 handler 时 RTTI 调用是空操作 */
    function buildTabCtl(node, cfg) {
        var items = node.tabitems || [];
        var tcfg = {
            x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height,
            hidden: cfg.hidden, disabled: cfg.disabled,
            activeTab: node.tabindex || 0, border: false,
            items: items.map(function (t) {
                return { title: esc(t), layout: 'absolute', border: false, bodyPadding: 0 };
            })
        };
        if (!tcfg.items.length) {
            tcfg.items = [{ title: '', layout: 'absolute', border: false, bodyPadding: 0 }];
        }
        var tc = Ext.create('Ext.tab.Panel', tcfg);
        function activeCard() {
            return tc.items.getAt(tc.getActiveTab() ? tc.items.indexOf(tc.getActiveTab()) : 0);
        }
        syncChildren(activeCard(), node);
        tc.on('tabchange', function (p, nc) {
            var i = tc.items.indexOf(nc);
            node.tabindex = i;
            syncChildren(nc, node);
            fire(node, 'OnChange', { val: String(i) });
        });
        return tc;
    }

    function buildTabSheet(node, cfg) {
        cfg.title = esc(node.caption || '');
        cfg.layout = 'absolute';
        cfg.border = false;
        cfg.closable = false;
        /* LCL 里 TTabSheet.Visible 恒为 False（显隐由 PageControl 的活动页决定），
           不能拿它当 hidden 用，否则两个页签全被藏掉、标签条量出 0 高 */
        cfg.hidden = false;
        var p = Ext.create('Ext.panel.Panel', cfg);
        syncChildren(p, node);
        return p;
    }

    /* ---------------- 窗体 ---------------- */

    /* 菜单项 -> Ext.menu.Menu / Toolbar 的 items 数组。
       主菜单与右键菜单（node.popup）共用同一套结构，事件也走同一个 id。 */
    function menuItems(list) {
        var out = [];
        (list || []).forEach(function (m) {
            if (m.sep) { out.push('-'); return; }
            var it = {
                text: esc(m.caption),
                disabled: m.enabled === false,
                checked: m.checked || undefined,
                handler: function () { fire(m, 'OnClick'); }
            };
            if (m.shortcut) it.text += '<span class="lw-mn">' + esc(m.shortcut) + '</span>';
            if (m.items && m.items.length) it.menu = menuItems(m.items);
            out.push(it);
        });
        return out;
    }

    function buildMenu(list) {
        if (!list || !list.length) return null;
        function items(arr) { return menuItems(arr); }
        return Ext.create('Ext.toolbar.Toolbar', {
            dock: 'top',
            border: false,
            items: list.map(function (m) {
                if (!m.items || !m.items.length) {
                    return {
                        text: esc(m.caption), disabled: m.enabled === false,
                        handler: function () { fire(m, 'OnClick'); }
                    };
                }
                return { text: esc(m.caption), menu: items(m.items) };
            })
        });
    }

    function buildForm(f) {
        var win = S.forms[f.id];
        if (win) return win;

        /* 主窗体（非模态）在视口里居中，模态对话框沿用设计坐标 */
        var fx = f.x, fy = f.y;
        if (!f.modal) {
            try {
                fx = Math.max(8, Math.floor((Ext.Element.getViewportWidth() - f.w) / 2));
                fy = Math.max(8, Math.floor((Ext.Element.getViewportHeight() - f.h) / 3));
            } catch (e) { }
        }

        var cfg = {
            title: esc(f.caption || f.name),
            x: fx, y: fy, width: f.w, height: f.h,
            layout: 'absolute',
            bodyStyle: 'background:' + (f.bg || '#f0f0f0') + ';overflow:auto;',
            resizable: !!f.resizable,
            draggable: true,
            maximizable: true,
            minimizable: false,
            closable: !!f.modal,
            modal: !!f.modal,
            closeAction: 'hide',
            shadow: true,
            constrain: false,
            glyph: false,
            listeners: {
                close: function () { fire(f.id, 'OnClose'); return false; }
            }
        };
        if (!f.modal) cfg.closable = false;

        win = Ext.create('Ext.window.Window', cfg);
        win.__lwForm = f;
        S.forms[f.id] = win;
        S.comps[f.id] = win;
        S.nodes[f.id] = f;

        var menu = buildMenu(f.menu);
        if (menu) win.addDocked(menu);

        /* 状态栏：不要 dock 到窗口底部 —— dock 会把 body 压矮，
           而 LCL 的坐标是相对整个客户区（含状态栏区域）的，
           铺在底部就与 LCL 坐标一致了 */
        var sbH = 24;
        if (f.status && f.status.length) {
            var sb = Ext.create('Ext.toolbar.Toolbar', {
                x: 0, y: Math.max(0, (f.ch || f.h || 0) - sbH),
                width: f.w || 300, height: sbH,
                border: false,
                items: f.status.map(function (t) { return { xtype: 'tbtext', text: esc(t) }; })
            });
            win.add(sb);
            win.__lwStatus = sb;
            win.on('resize', function () {
                try {
                    sb.setWidth(win.body.getWidth());
                    sb.setPosition(0, Math.max(0, win.body.getHeight() - sbH));
                } catch (e) { }
            });
        }

        win.show();
        /* Ext 的 height 含标题栏，LCL 的 ClientHeight 不含；
           把差值补回去，让窗口 body 的坐标空间与 LCL 客户区一致 */
        try {
            var dh = (f.ch || f.h || 0) - win.body.getHeight();
            if (dh) win.setHeight(win.getHeight() + dh);
        } catch (e) { }
        syncChildren(win, f);
        return win;
    }

    /* ---------------- 子节点同步 ---------------- */

    function syncChildren(ct, node) {
        var list = node.children || [];
        var keep = {};
        list.forEach(function (n) {
            keep[n.id] = true;
            var c = S.comps[n.id];
            if (c && c.__lwParent === ct) {
                patchNode(c, n);
            } else {
                if (c) destroyNode(n.id);
                createNode(n, ct);
            }
        });
        /* 销毁已经不在树里的旧子节点 */
        var old = ct.__lwKids || [];
        old.forEach(function (id) { if (!keep[id]) destroyNode(id); });
        ct.__lwKids = list.map(function (n) { return n.id; });

        runLayout(ct, list);
        if (!ct.__lwLayoutBound) {
            ct.__lwLayoutBound = true;
            ct.on('resize', function () { runLayout(ct, ct.__lwKidsNodes || list); });
            ct.__lwKidsNodes = list;
        } else {
            ct.__lwKidsNodes = list;
        }
    }

    /* 服务端已经算好坐标；这里只处理 align 拉伸（窗口尺寸与设计期不一致时） */
    function runLayout(ct, list) {
        /* Ext toolbar 是 hbox 流式布局，自己会排子项，
           服务端坐标（TToolButton 没有 x）套上来只会互相踩 */
        try { if (ct instanceof Ext.toolbar.Toolbar) return; } catch (e0) { }
        var body = ct.body || ct;
        var w = 0, h = 0;
        try {
            w = body.getWidth();
            h = body.getHeight();
        } catch (e) { return; }
        /* 容器还没显示（窗口 hide 着、页签没激活）时量出来是 0×0。此时
           直接 return 会让绝对定位的 Ext.Component（TLabel 之类）永远停在
           (0,0)——刷新后"标签不见了"就是这么来的。等布局出来了再来一次。 */
        if (!w || !h) {
            var tries = (ct.__lwLayoutTries || 0);
            if (tries < 6) {
                ct.__lwLayoutTries = tries + 1;
                Ext.defer(function () { try { runLayout(ct, list); } catch (e2) { } }, 60 * (tries + 1));
            }
            return;
        }
        ct.__lwLayoutTries = 0;
        /* 与 LCL 的 align 语义一致：先按逆 z 序让 top/bottom/left/right
           依次吃掉自己那一条，alClient 拿剩下的矩形。
           之前的"预扫 + 处理趟"写法有双重扣减：预扫把 left 自身的宽度
           加进了 xLeft，处理趟再用 xLeft 给 left 定位，每个左对齐控件
           都右移一个自身宽度、client 宽度算成负数 —— gallery 数据感知
           页的 TDBGrid 跑到页签中间、右面板整个被挤出可见区；bottom
           同理上移一个自身高度（事件日志面板压住页签内容）。
           VCL/LCL 里 alClient 永远最后分配，因此逆序单趟即可。 */
        var curTop = 0, curBottom = h, curLeft = 0, curRight = w, i, n, c;
        var x, y, wd, ht;
        /* 第一趟（逆 z 序，与 LCL 一致）：top/bottom/left/right 依次占边 */
        for (i = list.length - 1; i >= 0; i--) {
            n = list[i];
            if (n.align === 'client' || n.align === 'none') continue;
            c = S.comps[n.id];
            if (!c || c.__lwParent !== ct) continue;
            x = n.x || 0; y = n.y || 0; wd = n.w || 0; ht = n.h || 0;
            switch (n.align) {
                case 'top': x = curLeft; wd = curRight - curLeft; y = curTop; curTop += ht; break;
                case 'bottom': curBottom -= ht; x = curLeft; wd = curRight - curLeft; y = curBottom; break;
                case 'left': x = curLeft; curLeft += wd; y = curTop; ht = curBottom - curTop; break;
                case 'right': curRight -= wd; x = curRight; y = curTop; ht = curBottom - curTop; break;
                default: continue;
            }
            try {
                c.setPosition(x, y);
                if (c.setSize) c.setSize(Math.max(0, wd), Math.max(0, ht));
            } catch (e) { }
        }
        /* 第二趟：alClient 拿剩余矩形（LCL 里 client 永远最后分配） */
        for (i = 0; i < list.length; i++) {
            n = list[i];
            if (n.align !== 'client') continue;
            c = S.comps[n.id];
            if (!c || c.__lwParent !== ct) continue;
            try {
                c.setPosition(curLeft, curTop);
                if (c.setSize) c.setSize(Math.max(0, curRight - curLeft), Math.max(0, curBottom - curTop));
            } catch (e) { }
        }
        /* 第三趟：绝对定位（align=none）的子项。Ext 的 absolute 布局对
           Ext.Component（TLabel 之类）不生成 layout item，x/y 配置不落地，
           全部堆在 (0,0) —— 数据感知页右面板的 5 个标签叠成一团。
           服务端坐标是唯一可靠的，这里统一摆正；只设位置不设尺寸，
           标签用自然宽度（nogui 下服务端量出的标签宽会截断 CJK 文字）。 */
        for (i = 0; i < list.length; i++) {
            n = list[i];
            if (n.align && n.align !== 'none') continue;
            c = S.comps[n.id];
            if (!c || c.__lwParent !== ct) continue;
            try {
                if (c.setPosition) c.setPosition(n.x || 0, n.y || 0);
            } catch (e) { }
        }
        try { if (ct.updateLayout) ct.updateLayout(); } catch (e) { }
    }

    function patchNode(cmp, n) {
        var prev = cmp.__lwNode || {};
        cmp.__lwNode = n;
        S.nodes[n.id] = n;

        try {
            if (cmp.setDisabled) cmp.setDisabled(n.enabled === false);
            /* tabsheet 的显隐由标签页容器的 activeTab 管理，服务端的
               TTabSheet.Visible 恒为 False，不能拿来 setVisible(False) */
            if (cmp.setVisible && n.kind !== 'tabsheet') cmp.setVisible(n.visible !== false);
        } catch (e) { }

        /* 提示文本（服务端可能中途改 Hint） */
        try { applyHint(cmp, n); } catch (e) { }

        /* TPageControl.ActivePage 被服务端代码改了：跟着切页签。
           置 __lwSilentTab 防止 tabchange 又把 OnChange 回传（乒乓）。 */
        try {
            if (n.kind === 'tabs' && cmp.setActiveTab && prev.active !== undefined &&
                typeof n.active === 'number' && prev.active !== n.active) {
                cmp.__lwSilentTab = true;
                try { cmp.setActiveTab(n.active); } finally { cmp.__lwSilentTab = false; }
            }
        } catch (e) { }

        /* 文本/标题 */
        try {
            if (n.kind === 'label' || n.kind === 'static' || n.kind === 'statusbar') {
                if (prev.text !== n.text && cmp.getEl()) {
                    cmp.getEl().update(esc(n.text != null ? n.text : n.caption));
                }
            } else if (cmp.setText && (n.kind === 'button' || n.kind === 'bitbtn' || n.kind === 'speedbutton' || n.kind === 'toolbutton')) {
                if (prev.caption !== n.caption) cmp.setText(n.caption || '');
                /* TSpeedButton 按下态跟随服务端（点击后服务端把 Down 置位） */
                if (n.kind === 'speedbutton' && cmp.setPressed && prev.down !== undefined && prev.down !== n.down) {
                    try { cmp.setPressed(!!n.down); } catch (e2) { }
                }
            } else if (cmp.setText && n.kind === 'fileupload') {
                /* 上传中按钮文字是进度，结束后由 uploadFiles 还原；
                   服务端改 Caption 时这里跟过去 */
                if (prev.caption !== n.caption && prev.caption !== undefined) cmp.setText(n.caption || '');
            } else if (cmp.setTitle && (n.kind === 'groupbox' || n.kind === 'tabsheet')) {
                if (prev.caption !== n.caption) cmp.setTitle(esc(n.caption || ''));
            }
        } catch (e) { }

        /* 绑定标签：reconcile 换了 __lwNode 并会按 node.x/y 重摆，重新贴一次编辑框 */
        try { if (n.boundfor && cmp.__lwFixBound) cmp.__lwFixBound(); } catch (e) { }

        /* 值（不要覆盖正在编辑的输入框） */
        try {
            if (n.kind === 'edit' || n.kind === 'maskedit' || n.kind === 'memo' ||
                n.kind === 'dbedit' || n.kind === 'dbmemo') {
                var focused = cmp.hasFocus && cmp.hasFocus();
                if (!focused && prev.text !== n.text) {
                    cmp.setValue((n.text || '').replace(/\r\n/g, '\n'));
                }
            } else if (n.kind === 'checkbox' || n.kind === 'radio' || n.kind === 'dbcheckbox') {
                if (prev.checked !== n.checked) cmp.setValue(!!n.checked);
            } else if (n.kind === 'spin' || n.kind === 'floatspin' || n.kind === 'updown') {
                if (prev.value !== n.value && !(cmp.hasFocus && cmp.hasFocus())) cmp.setValue(n.value);
            } else if (n.kind === 'combo') {
                if (prev.text !== n.text && !(cmp.hasFocus && cmp.hasFocus())) cmp.setValue(n.text || '');
            } else if (n.kind === 'dblookup') {
                /* 服务端把"当前键"写在 key 上；键变了才改，避免打断用户选择 */
                if (prev.key !== n.key && !(cmp.hasFocus && cmp.hasFocus())) {
                    try { cmp.setValue(n.key != null ? String(n.key) : ''); } catch (e) { }
                }
                if (JSON.stringify(prev.items) !== JSON.stringify(n.items) && cmp.getStore) {
                    cmp.getStore().loadData((n.items || []).map(function (t, i) {
                        var k = (n.keys || [])[i];
                        return { text: t, key: k == null ? '' : String(k) };
                    }));
                }
            } else if (n.kind === 'progress') {
                cmp.updateValue((n.max ? (n.pos || 0) / n.max : 0));
                cmp.updateText((n.pos || 0) + ' / ' + (n.max || 100));
            } else if (n.kind === 'dbradiogroup') {
                if (prev.value !== n.value && cmp.items && cmp.items.each) {
                    cmp.items.each(function (r) {
                        if (r.setValue) r.setValue(String(r.inputValue) === String(n.value));
                    });
                }
            } else if (n.kind === 'radiogroup' && cmp.items && cmp.items.each) {
                if (prev.index !== n.index) {
                    cmp.items.each(function (r) {
                        if (r.setValue) r.setValue(parseInt(r.inputValue, 10) === n.index);
                    });
                }
            } else if (n.kind === 'checkgroup' && cmp.items && cmp.items.each) {
                var cgsig = JSON.stringify(n.checked || []);
                if (cmp.__lwSig !== cgsig) {
                    cmp.__lwSig = cgsig;
                    var cgi = 0;
                    cmp.items.each(function (k) {
                        if (k.setValue) {
                            var want = !!((n.checked || [])[cgi]);
                            if (k.getValue() !== want) {
                                k.suspendEvents(false);
                                k.setValue(want);
                                k.resumeEvents();
                            }
                        }
                        cgi++;
                    });
                }
            } else if (n.kind === 'checklistbox' && cmp.__lwBoxes) {
                var clsig = JSON.stringify(n.items) + '#' + JSON.stringify(n.checked || []);
                if (cmp.__lwSig !== clsig) {
                    cmp.__lwSig = clsig;
                    if (JSON.stringify(prev.items) !== JSON.stringify(n.items)) {
                        /* 条目变了：整体重建 */
                        cmp.removeAll();
                        cmp.__lwBoxes = [];
                        (n.items || []).forEach(function (t, i) {
                            var b = Ext.create('Ext.form.field.Checkbox', {
                                boxLabel: esc(t),
                                checked: !!((n.checked || [])[i]),
                                margin: '2 6'
                            });
                            b.on('change', function (cb, nv) {
                                fire(n, 'OnClickCheck', {
                                    val: String(i),
                                    checked: cmp.__lwBoxes.map(function (x) { return !!x.checked; })
                                });
                                fire(n, 'OnClick', { val: String(i) });
                            });
                            cmp.add(b);
                            cmp.__lwBoxes.push(b);
                        });
                    } else {
                        cmp.__lwBoxes.forEach(function (b, i) {
                            var want = !!((n.checked || [])[i]);
                            if (b.getValue() !== want) {
                                b.suspendEvents(false);
                                b.setValue(want);
                                b.resumeEvents();
                            }
                        });
                    }
                }
            } else if (n.kind === 'valeditor' && cmp.getStore) {
                var vesig = JSON.stringify(n.keys) + '#' + JSON.stringify(n.values);
                if (cmp.__lwSig !== vesig) {
                    cmp.__lwSig = vesig;
                    cmp.getStore().loadData((n.keys || []).map(function (k, i) {
                        return { lwRow: i, key: k,
                                 value: (n.values || [])[i] == null ? '' : String((n.values || [])[i]) };
                    }));
                }
                if ((n.selrow || -1) >= 0 && cmp.__lwSel !== n.selrow) {
                    try { cmp.getSelectionModel().select(n.selrow); } catch (e) { }
                }
            } else if (n.kind === 'shape' || n.kind === 'bevel') {
                /* shape/bevel 的宽高/填充全在内联样式里（创建期 Ext 布局
                   对无内容 Component 的尺寸落地有时机竞态），每次同步
                   对账一次，签名没变不动 DOM */
                if (cmp.getEl && cmp.getEl()) {
                    var spx = 'width:' + (n.w || 10) + 'px;height:' + (n.h || 10) + 'px;';
                    if (n.kind === 'shape') {
                        var srd = { 2: '10px', 3: '10px', 4: '50%', 5: '50%' }[n.shapestyle];
                        spx += 'background:' + (n.bg || '#ffffff') +
                            ';border:1px solid rgba(0,0,0,.35);' +
                            (srd ? 'border-radius:' + srd + ';' : '');
                    }
                    if (cmp.__lwShapeSig !== spx) {
                        cmp.__lwShapeSig = spx;
                        try { cmp.getEl().applyStyles(spx); } catch (e) { }
                    }
                }
            } else if (n.kind === 'image' || n.kind === 'dbimage') {
                if (prev.src !== n.src && n.src) cmp.setSrc(n.src);
            } else if (n.kind === 'htmlframe') {
                /* HTML 内容变了才替换，避免打掉 iframe / 选中状态 */
                var hs = n.html || '';
                if (cmp.__lwHtmlSig !== hs) {
                    cmp.__lwHtmlSig = hs;
                    try {
                        cmp.update(hs);
                        execHtmlScripts(cmp.getEl() && (cmp.getEl().dom || cmp.getEl()));
                    } catch (e) { }
                }
            } else if (n.kind === 'pdfframe') {
                /* 服务端换文件/换令牌后 url 变化：换 src 或整体重建 */
                var us = n.url || '';
                if (cmp.__lwUrlSig !== us) {
                    cmp.__lwUrlSig = us;
                    try {
                        var old = cmp.items && cmp.items.items && cmp.items.items[0];
                        if (us) {
                            if (old && old.getEl && old.getEl() && old.getEl().dom) {
                                old.getEl().dom.src = us;
                            } else {
                                cmp.removeAll();
                                cmp.add(Ext.create('Ext.Component', {
                                    autoEl: { tag: 'iframe', src: us, frameborder: 0,
                                              style: 'width:100%;height:100%;border:0;' }
                                }));
                                cmp.updateLayout();
                            }
                        } else {
                            cmp.removeAll();
                            cmp.update('<div class="lw-unknown">PDF：尚未指定文件</div>');
                        }
                    } catch (e) { }
                }
            } else if (n.kind === 'dateedit' || n.kind === 'timeedit') {
                /* 服务端 Date/Time 变了才改，避免打断正在选择的面板 */
                var iso = n.iso || '';
                if (prev.iso !== iso && !(cmp.hasFocus && cmp.hasFocus())) {
                    try { cmp.setValue(iso); } catch (e) { }
                }
            }
        } catch (e) { }

        /* 表格内容整表替换（简单可靠） */
        try {
            if (n.kind === 'dbgrid' && cmp.getStore) {
                /* 编辑态下服务端不发 rows，这里就保持上次的数据不动，
                   只把选中行跟过去 */
                if (n.rows) {
                    var dsig = dbSig(n);
                    if (cmp.__lwSig !== dsig) {
                        /* 坑79：列没变只灌行数据（reconfigure 会销毁编辑器
                           字段，reap 再把 column.editor 清 null）；列变了
                           才 reconfigure，新列由 dbEditColumns 重建自带 editor */
                        var csig = dbColSig(n);
                        var st = (csig === cmp.__lwColSig) && cmp.getStore();
                        cmp.__lwSig = dsig;
                        cmp.__lwColSig = csig;
                        if (st) fillGridRows(st, n);
                        else cmp.reconfigure(buildGridStore(n), dbEditColumns(n));
                    }
                }
                selectDBRow(cmp, n);
                /* 分页/汇总文案跟过去（TLWDBGrid 的 page/pages/total/summary）*/
                try {
                    var pg = cmp.down('#lwpg');
                    if (pg) pg.setText(pagerText(n));
                    var sm2 = cmp.down('#lwsum');
                    if (sm2 && n.summary) sm2.setText(summaryText(n.summary));
                } catch (x2) { }
            } else if (n.kind === 'gauge') {
                var gs = gaugeSig(n);
                if (cmp.__lwGaugeSig !== gs) {
                    cmp.__lwGaugeSig = gs;
                    cmp.update(gaugeSvg(n));
                }
            } else if (n.kind === 'color') {
                if (prev.value !== n.value) {
                    cmp.__lwNode = n;
                    applyColor(cmp, n);
                }
            } else if (n.kind === 'chart') {
                /* 类型/数据变了整体重建图表（图表增量重配太脆弱）*/
                var cs = chartSig(n);
                if (cmp.__lwChartSig !== cs) {
                    cmp.__lwChartSig = cs;
                    try {
                        cmp.removeAll();
                        if (typeof Ext.chart !== 'undefined') {
                            cmp.add(n.charttype === 'pie' ? makePieChart(n) : makeCartesianChart(n));
                            cmp.updateLayout();
                        }
                    } catch (e) { }
                }
            } else if ((n.kind === 'grid' || n.kind === 'drawgrid') && cmp.getStore) {
                var sig = JSON.stringify(n.rows) + '#' + JSON.stringify(n.cols);
                if (cmp.__lwSig !== sig) {
                    cmp.__lwSig = sig;
                    cmp.reconfigure && cmp.reconfigure(buildGridStore(n), buildGridColumns(n));
                }
            } else if (n.kind === 'listbox' && cmp.getStore) {
                var sig2 = JSON.stringify(n.items);
                if (cmp.__lwSig !== sig2) {
                    cmp.__lwSig = sig2;
                    cmp.getStore().loadData((n.items || []).map(function (t) { return { text: t }; }));
                }
            } else if (n.kind === 'dblookuplist' && cmp.getStore) {
                var sig4 = JSON.stringify(n.items) + '#' + JSON.stringify(n.keys) + '#' + n.key;
                if (cmp.__lwSig !== sig4) {
                    cmp.__lwSig = sig4;
                    cmp.getStore().loadData((n.items || []).map(function (t) { return { text: t }; }));
                }
                var ki = (n.keys || []).map(String).indexOf(String(n.key));
                try {
                    if (ki >= 0) cmp.getSelectionModel().select(ki);
                    else cmp.getSelectionModel().deselectAll();
                } catch (e) { }
            } else if (n.kind === 'dblistbox' && cmp.getStore) {
                var sig3 = JSON.stringify(n.items) + '#' + n.index;
                if (cmp.__lwSig !== sig3) {
                    cmp.__lwSig = sig3;
                    cmp.getStore().loadData((n.items || []).map(function (t) { return { text: t }; }));
                }
                if (n.index >= 0) {
                    try { cmp.getSelectionModel().select(n.index); } catch (e) { }
                } else {
                    try { cmp.getSelectionModel().deselectAll(); } catch (e) { }
                }
            } else if (n.kind === 'dbnav') {
                /* 导航按钮的 Enabled 由服务端按数据集状态算好下发 */
                var navBtns = (cmp.items && cmp.items.items) || [];
                (n.buttons || []).forEach(function (nb) {
                    for (var j = 0; j < navBtns.length; j++) {
                        if (navBtns[j].__lwBtnId === nb.id) {
                            navBtns[j].setDisabled(nb.en === false);
                            break;
                        }
                    }
                });
            }
        } catch (e) { }

        if (isContainer(n)) syncChildren(cmp, n);
    }

    function buildGridColumns(n) {
        var cols = n.cols || [], widths = n.colwidths || [], out = [];
        for (var i = 0; i < cols.length; i++) {
            var w = widths[i] > 0 ? widths[i] : null;
            out.push({ text: esc(cols[i]), dataIndex: 'c' + i, flex: w ? undefined : 1, width: w || undefined });
        }
        return out;
    }

    function buildGridStore(n) {
        var data = (n.rows || []).map(function (row, ri) { return gridRowObj(n, row, ri); });
        return Ext.create('Ext.data.Store', {
            fields: [{ name: 'lwRow', type: 'int' }].concat((n.cols || []).map(function (_, i) { return 'c' + i; })),
            data: data
        });
    }

    function destroyNode(id) {
        var c = S.comps[id];
        if (!c) return;
        delete S.comps[id];
        delete S.nodes[id];
        try {
            if (c.__lwParent && c.__lwParent.remove) c.__lwParent.remove(c, true);
            else c.destroy();
        } catch (e) { }
    }

    /* ---------------- 事件绑定 ---------------- */

    function bindEvents(cmp, node) {
        var ev = node.ev || [];
        function has(n) { return ev.indexOf(n) >= 0; }

        var isField = FIELD_KINDS.indexOf(node.kind) >= 0;

        if (has('OnClick')) {
            if (node.kind === 'button' || node.kind === 'bitbtn' || node.kind === 'speedbutton' || node.kind === 'toolbutton') {
                cmp.on('click', function () { fire(node, 'OnClick'); });
            } else if (node.kind === 'fileupload') {
                /* 上传按钮的点击已经绑成"选文件"，不再额外回传 OnClick，
                   业务逻辑写在 OnUpload 里 */
            } else if (node.kind === 'label' || node.kind === 'static' || node.kind === 'panel' || node.kind === 'image') {
                onEl(cmp, 'click', function () { fire(node, 'OnClick'); });
            } else {
                try { cmp.on('click', function () { fire(node, 'OnClick'); }); } catch (e) { }
            }
        }

        if (has('OnDblClick')) {
            onEl(cmp, 'dblclick', function () { fire(node, 'OnDblClick'); });
        }

        if (has('OnChange') && isField) {
            cmp.on('change', function () { fireChange(node, cmp); });
            if (node.kind === 'combo' || node.kind === 'dblookup') cmp.on('select', function () { fireChange(node, cmp); });
        }

        if (has('OnEnter')) {
            try {
                if (isField) cmp.on('focus', function () { fire(node, 'OnEnter'); });
            } catch (e) { }
        }
        if (has('OnExit')) {
            try {
                if (isField) cmp.on('blur', function () { fire(node, 'OnExit'); });
            } catch (e) { }
        }

        if (node.kind === 'listbox' && has('OnSelect')) {
            cmp.on('select', function (grid, rec) { fire(node, 'OnSelect', { val: String(rec.get('text')) }); });
        }

        /* TListBox 的 OnClick：网格没有通用 click 事件，挂 itemclick
           （点行 = 用户点了列表项），服务端 StdLbClick 这些处理器才有得跑 */
        if ((node.kind === 'listbox' || node.kind === 'dblistbox') && has('OnClick')) {
            cmp.on('itemclick', function (dv, rec) {
                fire(node, 'OnClick', { val: rec && rec.get ? String(rec.get('text')) : '' });
            });
        }

        /* TUpDown：上下箭头一点，Number field 的 value 就变了 ——
           当成 OnClick 回传新位置，服务端 LWApplyValue 写 Position
           并联动 Associate 编辑框（nogui 没有消息链，联动在服务端做） */
        if (node.kind === 'updown' && has('OnClick')) {
            cmp.on('change', function (f, v) {
                fire(node, 'OnClick', { val: String(v == null ? 0 : v) });
            });
        }

        /* 右键菜单（服务端 TControl.PopupMenu）：菜单项的 id 与主菜单一致，
           点中直接 fire(m, 'OnClick')，服务端 RWInvokeEvent 调到 OnClick */
        if (node.popup && node.popup.length) {
            onEl(cmp, 'contextmenu', function (e) {
                e.preventDefault();
                var cur = S.nodes[node.id] || node;
                var menu = Ext.create('Ext.menu.Menu', { items: menuItems(cur.popup || []) });
                menu.showAt(e.getXY());
            });
        }
    }

    /* ---------------- 载荷应用 ---------------- */

    function applyPayload(p) {
        if (!p || !p.forms) return;
        S.sid = p.sid || S.sid;
        var seen = {};
        p.forms.forEach(function (f) {
            seen[f.id] = true;
            var win = S.forms[f.id];
            if (!win) { buildForm(f); return; }
            var prevStatus = (win.__lwForm || {}).status;
            win.__lwForm = f;
            try {
                if (win.title !== f.caption) win.setTitle(esc(f.caption || f.name));
            } catch (e) { }
            /* 状态栏文本（服务端改 Panels[i].Text 后跟着变） */
            if (win.__lwStatus && f.status &&
                JSON.stringify(prevStatus || []) !== JSON.stringify(f.status)) {
                try {
                    var its = win.__lwStatus.items.getRange();
                    f.status.forEach(function (t, i) {
                        if (its[i]) its[i].setText(esc(t == null ? '' : String(t)));
                    });
                } catch (e) { }
            }
            syncChildren(win, f);
        });
        Object.keys(S.forms).forEach(function (id) {
            if (!seen[id]) {
                var w = S.forms[id];
                delete S.forms[id];
                delete S.comps[id];
                try { w.close(); w.destroy(); } catch (e) { }
            }
        });
        hideSplash();
    }

    /* 主动拉一次完整树（重发对话框被应答后用：那次事件的响应已经没了） */
    function refreshTree() {
        if (!S.sid) return;
        api('/lw/api/tree', null, function (resp, err) {
            if (!err && resp) { try { applyPayload(resp); } catch (e) { log('refresh failed', e); } }
        }, { params: { sid: S.sid }, timeout: 20000 });
    }

    /* ---------------- 服务端对话框 ----------------
       ShowMessage / MessageDlg / InputQuery / Application.MessageBox /
       QuestionDlg / TOpenDialog.Execute 全都在服务端挂起等待，
       这里负责把描述渲染成模态窗口，用户一操作就把结果 POST 回去。 */

    var DLG_TITLE = {
        info: '提示', warning: '警告', error: '错误', question: '确认',
        none: '消息', input: '输入', openfile: '打开文件', savefile: '保存文件'
    };

    var DLG_ICON = {
        info: { cls: 'lw-dlg-i-info', glyph: 'i' },
        warning: { cls: 'lw-dlg-i-warn', glyph: '!' },
        error: { cls: 'lw-dlg-i-err', glyph: '✕' },
        question: { cls: 'lw-dlg-i-ques', glyph: '?' }
    };

    function dlgPost(id, r, text, cb) {
        api('/lw/api/dlg', { sid: S.sid, id: id, r: r, text: text == null ? '' : String(text) },
            cb || function () { });
    }

    function showServerDialog(cmd) {
        var kind = cmd.kind || 'none';
        var inp = cmd.input || null;
        var escId = cmd.escape != null ? cmd.escape : 2;
        var answered = false;
        var win = null;
        var field = null;
        var pickLabel = null;
        var fileInput = null;
        var bodyItems = [];
        var btnCfg = [];

        function currentText() {
            try { return field ? field.getValue() : ''; } catch (e) { return ''; }
        }

        /* 把答案送回服务端（服务端的那个线程正挂在这儿等） */
        function answer(r, text) {
            if (answered) return;
            answered = true;
            dlgPost(cmd.id, r, text, function () {
                /* 刷新后重发的对话框（cmd.__lwResend）：原来那次事件的响应
                   已经被刷新丢掉，业务代码执行完的新状态没人送过来 ——
                   主动拉一次树补上，否则界面上看不到对话框之后的副作用 */
                if (cmd.__lwResend) refreshTree();
            });
            try { win.close(); } catch (e) { }
        }

        /* 已经由别的途径（文件上传接口）把答案交回服务端了，这里只负责关窗 */
        function answerSilently() {
            answered = true;
            try { win.close(); } catch (e) { }
        }

        var textHtml = esc(cmd.text || '').replace(/\n/g, '<br>');

        bodyItems.push({
            xtype: 'component',
            border: false,
            html: textHtml,
            cls: 'lw-dlg-msg'
        });

        if (kind === 'input') {
            field = {
                xtype: 'textfield',
                emptyText: '',
                value: inp && inp.value != null ? inp.value : '',
                inputType: (inp && inp.mask) ? 'password' : 'text',
                selectOnFocus: true,
                listeners: {
                    specialkey: function (f, e) {
                        if (e.getKey() === e.ENTER) {
                            e.stopEvent();
                            answer(defaultId(), currentText());
                        }
                    }
                }
            };
            bodyItems.push(field);
        } else if (kind === 'savefile') {
            field = {
                xtype: 'textfield',
                fieldLabel: '文件名',
                labelWidth: 60,
                value: inp && inp.value ? inp.value : 'untitled.txt',
                selectOnFocus: true,
                listeners: {
                    specialkey: function (f, e) {
                        if (e.getKey() === e.ENTER) {
                            e.stopEvent();
                            answer(defaultId(), currentText());
                        }
                    }
                }
            };
            bodyItems.push(field);
        } else if (kind === 'openfile') {
            fileInput = document.createElement('input');
            fileInput.type = 'file';
            if (inp && inp.multi) fileInput.multiple = true;
            var accept = inp && inp.filter ? filterToAccept(inp.filter) : '';
            if (accept) fileInput.accept = accept;
            fileInput.style.display = 'none';
            document.body.appendChild(fileInput);

            pickLabel = {
                xtype: 'component',
                border: false,
                cls: 'lw-dlg-file',
                html: '<span class="lw-dlg-file-tip">尚未选择文件</span>'
            };
            bodyItems.push(pickLabel);

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
                        answerSilently();
                    } else {
                        answered = false;
                        Ext.Msg.alert('上传失败', '服务端返回 HTTP ' + xhr.status);
                    }
                };
                xhr.onerror = function () {
                    answered = false;
                    Ext.Msg.alert('上传失败', '网络错误，文件没有传到服务端');
                };
                xhr.upload.onprogress = function (e) {
                    if (e.lengthComputable && pickLabel) {
                        var p = Math.round(e.loaded * 100 / e.total);
                        try {
                            pickLabel.update('<span class="lw-dlg-file-tip">正在上传… ' + p + '%</span>');
                        } catch (err) { }
                    }
                };
                xhr.send(fd);
            };
        }

        function defaultId() {
            var btns = cmd.buttons || [];
            for (var i = 0; i < btns.length; i++)
                if (btns[i]['default']) return btns[i].id;
            return btns.length ? btns[0].id : 1;
        }

        (cmd.buttons || []).forEach(function (b) {
            if (kind === 'openfile') {
                /* 选文件：第一个按钮换成"浏览…"，点了才打开文件选择框 */
                btnCfg.push({
                    text: b['default'] ? (b.text || '选择文件…') : b.text,
                    cls: b['default'] ? 'lw-dlg-default' : '',
                    handler: function () {
                        if (b['default']) fileInput.click();
                        else answer(b.id, '');
                    }
                });
                return;
            }
            btnCfg.push({
                text: b.text,
                cls: b['default'] ? 'lw-dlg-default' : '',
                handler: function () { answer(b.id, currentText()); }
            });
        });

        if (!btnCfg.length) btnCfg.push({ text: 'OK', handler: function () { answer(1, currentText()); } });

        var icon = DLG_ICON[kind];
        var cfg = {
            title: esc(cmd.caption || DLG_TITLE[kind] || '消息'),
            width: 430,
            modal: true,
            closable: true,
            resizable: false,
            closeAction: 'destroy',
            bodyPadding: 18,
            cls: 'lw-dlg-win',
            layout: { type: 'vbox', align: 'stretch' },
            items: bodyItems,
            buttons: btnCfg,
            listeners: {
                close: function () {
                    if (!answered) {
                        answered = true;
                        /* 点右上角关闭 == 按取消键 */
                        dlgPost(cmd.id, escId, '');
                    }
                    if (fileInput && fileInput.parentNode)
                        fileInput.parentNode.removeChild(fileInput);
                    return true;
                }
            }
        };
        if (icon) {
            cfg.title = '<span class="lw-dlg-title-icon ' + icon.cls + '">' + icon.glyph +
                '</span>' + cfg.title;
        }

        win = Ext.create('Ext.window.Window', cfg);
        win.show();
        if (field) {
            try { win.down('textfield').focus(); } catch (e) { }
        }
        return win;
    }

    /* ---------------- 长轮询：接收模态窗体/服务端推送 ---------------- */

    function handleCmd(cmd, tree, resend) {
        if (!cmd) return;
        if (cmd.type === 'modal' && cmd.form) {
            buildForm(cmd.form);
            if (tree) applyPayload(tree);
            Ext.defer(function () {
                var w = S.forms[cmd.form.id];
                if (w) try { w.toFront(); } catch (e) { }
            }, 50);
        } else if (cmd.type === 'show') {
            /* 业务代码 Form.Show：服务端已把窗体加进清单，这里整体协调一次 */
            if (tree) applyPayload(tree);
        } else if (cmd.type === 'closeform') {
            var w = S.forms[cmd.id];
            if (w) {
                delete S.forms[cmd.id];
                try { w.close(); w.destroy(); } catch (e) { }
            }
        } else if (cmd.type === 'dialog') {
            /* ShowMessage / MessageDlg / InputQuery / 文件对话框：
               服务端线程挂起等我们的答复（POST /lw/api/dlg）。
               多页签共享一个会话时，同一条对话框指令每个页签都会收到，
               只让"引起它的那个页签"弹窗：
                 cmd.to = 页签标识   -> 就是发起事件的页签
                 cmd.to 为空         -> 后台线程发起，由主页签兜底
               resend（attach 响应里重发的挂起对话框）不做过滤：能收到它
               的只有发起页签自己刷新后的那一页，旧页签已经不在了 */
            if (!resend) {
                if (S.multiTab && cmd.to && cmd.to !== S.tab) return;
                if (!cmd.to && S.multiTab && !S.primary) return;
            } else {
                cmd.__lwResend = true;
            }
            showServerDialog(cmd);
        } else if (cmd.type === 'mask') {
            /* 会话级遮罩（LWShowScreenMask / LWHideScreenMask） */
            setScreenMask(cmd.show !== false, cmd.text || '');
        } else if (cmd.type === 'msg') {
            Ext.Msg.alert('lazarusWeb', esc(cmd.text || ''));
        } else if (cmd.type === 'toast') {
            /* 轻提示（TLWForm.ShowToast / 登录失败提示）：右上角弹几秒消失，
               不阻塞、不需要用户点确定 */
            Ext.toast({
                html: esc(cmd.text || ''),
                title: cmd.title ? esc(cmd.title) : '',
                width: 280,
                align: 't',
                closable: true
            });
        } else if (cmd.type === 'download') {
            /* 服务端已经把文件登记成一次性令牌，这里只需要让浏览器去取。
               用 <a download> 而不是 location.href：不打断当前页面，
               也不会把 POST 事件的响应流搞乱 */
            var a = document.createElement('a');
            a.href = cmd.url;
            if (cmd.name) a.download = cmd.name;
            a.style.display = 'none';
            document.body.appendChild(a);
            a.click();
            Ext.defer(function () {
                try { document.body.removeChild(a); } catch (e) { }
            }, 100);
        }
    }

    function startPoll() {
        if (!S.sid) { Ext.defer(startPoll, 500); return; }
        /* 长轮询是唯一的推送通道（WebSocket 只管事件请求/响应）。
           带着 after 游标：服务端只回"序号比它新"的第一条，
           所以几个页签共用一个会话时各取各的，谁也不会吃掉别人的指令。 */
        api('/lw/api/poll', null, function (resp, err) {
            if (!err && resp) {
                if (resp.gone) {
                    /* 会话被清理（超时/服务重启）：丢掉旧 sid 重新来过 */
                    forgetSid();
                    S.sid = null;
                    S.after = -1;
                    S.pollAlive = false;
                    try { if (S.ws) S.ws.close(); } catch (e) { }
                    S.ws = null;
                    showSplash('会话已过期，正在重新连接…');
                    Ext.defer(boot, 800);
                    return;
                }
                if (resp.cmd) handleCmd(resp.cmd, resp.tree);
                if (typeof resp.seq === 'number' && resp.seq > S.after) S.after = resp.seq;
            }
            Ext.defer(startPoll, err ? 1500 : 30);
        }, { params: { sid: S.sid, t: 20000, after: S.after }, timeout: 35000 });
    }

    /* ---------------- WebSocket（优先通道） ---------------- */

    function wsConnect() {
        if (!window.WebSocket || !S.sid) return;
        if (S.wsConnecting) return;   /* 重连防抖：别越积越多 */
        S.wsConnecting = true;
        try {
            var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
            var ws = new WebSocket(proto + '//' + location.host + '/lw/ws?sid=' + encodeURIComponent(S.sid));
            var settled = false;
            ws.onopen = function () {
                settled = true;
                S.wsConnecting = false;
                log('websocket connected');
                S.ws = ws;
            };
            ws.onmessage = function (m) {
                var d = null;
                try { d = Ext.decode(m.data, true); } catch (e) { d = null; }
                if (!d) return;
                /* 服务端直推指令（dialog/show/modal/download…，tree 随帧附带） */
                if (d.type) {
                    if (d.ok === undefined || d.ok) handleCmd(d, d.tree);
                    return;
                }
                /* 事件响应 */
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
                    if (cb) cb(null, 'ws closed');   /* fire 里会转 HTTP 重发 */
                }
                /* 断线：长轮询兜底 + 定期重试 WS */
                if (S.sid && S.wsWanted) {
                    if (!S.pollAlive) { S.pollAlive = true; startPoll(); }
                    Ext.defer(function () { if (S.wsWanted && !S.ws && !S.wsConnecting) wsConnect(); }, 2000);
                }
            };
            ws.onerror = function () { };
        } catch (e) {
            S.wsConnecting = false;
            log('websocket unavailable', e);
        }
    }

    /* ---------------- 启动 ---------------- */

    var booting = false;

    /* ---- 跨页签会话共享 ----
       sid 存在 localStorage 里，同一浏览器的第二个标签页直接"挂"上去，
       共享同一份服务端会话（登录身份、打开的窗体、数据游标全都在服务端）。
       会话没了（服务重启 / 空闲超时清理）服务端回 410，这时才新建。 */
    var SID_KEY = 'lw.sid';

    function rememberSid(sid) {
        try { if (sid) localStorage.setItem(SID_KEY, sid); } catch (e) { }
    }

    function forgetSid() {
        try { localStorage.removeItem(SID_KEY); } catch (e) { }
    }

    function savedSid() {
        /* ?fresh=1 强制开新会话（调试/多人共用一个浏览器时用） */
        if (/[?&]fresh=1/.test(location.search)) return '';
        try { return localStorage.getItem(SID_KEY) || ''; } catch (e) { return ''; }
    }

    function newTabId() {
        return 't' + Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
    }

    /* 会话就绪后的收尾：起长轮询 + 连 WebSocket */
    function startChannels() {
        /* ?nopoll=1 用于截图/调试：不建立长轮询，页面可以正常"加载完成" */
        if (/[?&]nopoll=1/.test(location.search)) return;
        if (!S.pollAlive) { S.pollAlive = true; startPoll(); }
        /* WebSocket 只传事件：连上后事件走 WS 帧，长轮询继续负责推送 */
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
            applyPayload(resp);
            startChannels();
        });
    }

    function attachSession(sid, cfg) {
        api('/lw/api/attach', null, function (resp, err) {
            booting = false;
            if (err || !resp || !resp.ok) {
                /* 会话过期 / 服务重启：清掉旧 sid，老老实实新建 */
                forgetSid();
                newSession(cfg);
                return;
            }
            S.sid = resp.sid;
            S.primary = false;
            S.multiTab = true;
            S.after = (typeof resp.seq === 'number') ? resp.seq : -1;
            rememberSid(resp.sid);
            applyPayload(resp);
            /* 挂起中的对话框（页签刷新前的模态弹窗）：attach 响应带回重发。
               resend=true 绕过页签归属过滤 —— 旧页签已经死了，这页就是它。 */
            if (resp.cmd) { try { handleCmd(resp.cmd, null, true); } catch (e) { log('resend cmd failed', e); } }
            log('attached to session', resp.sid);
            startChannels();
        }, { params: { sid: sid }, timeout: 20000 });
    }

    function boot() {
        if (booting) return;
        booting = true;
        var cfg = window.LW_CFG || {};
        /* 页签标识存 sessionStorage：刷新后还是同一个"页签"（挂起对话框
           的 cmd.to 才能对上），新开标签页自然是新标识 */
        if (!S.tab) {
            try { S.tab = sessionStorage.getItem('lw.tab') || ''; } catch (e) { }
            if (!S.tab) S.tab = newTabId();
            try { sessionStorage.setItem('lw.tab', S.tab); } catch (e) { }
        }
        var sid = savedSid();
        if (sid) { attachSession(sid, cfg); return; }
        newSession(cfg);
    }

    return {
        start: function (cfg) {
            window.LW_CFG = cfg || {};
            Ext.onReady(function () {
                initHintTips();
                showSplash('正在创建服务端会话…');
                boot();
            });
        },
        reload: function () { boot(); },
        sid: function () { return S.sid; }
    };
})();
