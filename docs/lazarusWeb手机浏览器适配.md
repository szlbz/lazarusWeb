# 手机浏览器适配：可行性分析 → 方案 B 实施记录

> 状态：**已实施**（2026-11-16，方案 B：自适应判定 + 窗体模板 + 平移回退）。
> 第 1~7 节是实施前的可行性分析存档；第 8 节记录当时的方案 B 实现，
> 其中「DOM 搬迁 / `{%控件名%}` 占位符 / 单列流式」部分**已被新机制取代**。
> **现状（2026-11-18 起）**：窗口与平面模式共用单个
> `<root>\tpl\<窗体名>.html`，文件头 `lw-tpl-mode:window|flat` 决定渲染
> 方式（flat 优先）；模板只作背景装饰层，**不重排控件**，控件始终按
> LFM 的 `Left/Top` 绝对定位。IDE Tools 菜单按 .lfm 一键生成一个该文件。
> 现状以 `MANUAL.md` 第二篇第 16 章为准；分析基于 Alpine 渲染层
> （`?client=alpine`，当前默认），Ext 版未适用。
> 注：`demos/mobile_demo/tpl/*.html` 与 `uMobileMain.pas` 里的
> 「DOM 搬迁 / `{%控件名%}` 替换成控件节点 / 单列流式 / 搬迁不重建」注释是
> lwdesign 生成骨架时的**旧机制遗留文字**，与上面的现状不符；模板在新机制下
> 只作背景装饰层，控件不重排（见第 8.6 节），读这些注释时以本节现状为准。

## 结论摘要

| 问题 | 答案 |
|---|---|
| 技术上能不能跑在手机浏览器上？ | **能**。底座已经具备（viewport meta + 视口自适应链路 + 缩放兜底），现有窗体打开不会白屏/错乱，按钮能点 |
| 能不能"好用"？ | 不能，差三个框架级坑（虚拟键盘、字号可读性、触控细节）+ 一个架构限制（LCL 绝对坐标不重流） |
| 推荐路线 | 轻量用途 → 方案 1（兼容包，几处小改）；当手机主力端 → 方案 1 + 方案 3（业务双窗体），不建议长期在"流式重排"上耗 |
| 本次决策 | ~~暂不做~~ → **2026-11-16 已实施**：走了自研模板占位符的方案 B（判定在浏览器 + DOM 搬迁模板 + 平移回退），见第 8 节 |

---

## 1. 已具备的基础（改动量几乎为零）

| 现状 | 代码位置 | 对手机的意义 |
|---|---|---|
| `<meta name="viewport" content="width=device-width, initial-scale=1">` | `lwhttp.pas` BuildIndexHtml / BuildAlpineHtml（两处） | 手机不按 980px 虚拟视口渲染，1:1 布局 |
| 主窗体画布跟随视口：resize 防抖 160ms → 发 `OnResize{w,h}` → 服务端 `SetBounds` → 差量回传 | `lw-alpine.js` `sendViewResize()` / `window.addEventListener('resize')`；`lwdispatch.pas` `LWApplyFormResize` | 竖屏/横屏切换、地址栏收放都会触发，align 子项由客户��� `runLayout` 重排 |
| 缩放兜底：画布仍大于视口时 CSS `transform: scale()` 一屏放下 | `lw-alpine.js` `fitMainZoom()` | 固定尺寸窗体也不出页面滚动条 |
| 全部交互走原生 `click`/`blur`/`change` | `lw-alpine.js` 各控件分支 | 触屏 tap 会合成 click，按钮/输入框/下拉**基本可用** |
| 主窗体默认最大化、禁拖角/拖动 | `lw-alpine.js` `buildForm` 的 `isMain` 分支（坑 112） | 手机上不会出现"拖动半个屏幕"的错位 |

**关键架构事实**（决定了上限）：

- nogui 窗体没有句柄，LCL 在服务端不算 align —— 布局全靠客户端 `runLayout` 重排；
- `runLayout` 只重算 **align 子项**（`alClient`/`alTop` 等），**`Left/Top` 写死的控件不会重流**；
- `Scaled=True` 下 LCL 像素 = CSS 像素 1:1（服务端 `SetBounds` 即为所见尺寸）。

因此"自适应"目前只解决"画布大小跟着视口走"，不解决"控件重新排布"。

## 2. 差距分析：三个框架级坑

### 坑 1：虚拟键盘触发 resize（最实际）

- Android Chrome 键盘弹出 → `window.innerHeight` 骤减 → 走 `resize` 防抖 → `sendViewResize` → 服务端把窗体压扁 → 收起键盘又弹回，**来回抖动**；
- iOS Safari 更麻烦：`innerHeight` 不变，键盘直接遮住下半屏，聚焦的输入框看不见。

修复思路：改用 `visualViewport.height` 判断，高度差超过阈值（如 >120px）才当作真 resize；iOS 下聚焦时把输入框 `scrollIntoView({block:'center'})`。改动集中在 `sendViewResize()` 与 resize 监听。

### 坑 2：缩放后字号不可读

- 竖屏 390px 放 960~1800px 的桌面窗体，scale ≈ 0.4，12px 字变 **4.8px**；
- 这是绝对坐标布局的本质限制，`fitMainZoom` 只能等比缩，不能重排。

修复思路（二选一）：
- 给 `fitMainZoom` 设缩放下限（如 `s >= 0.55`），低于下限时允许页面纵向滚动，靠用户双指放大；
- 或走方案 2/3 让内容真正适配宽度。

### 坑 3：触控细节

- iOS 输入框字号 <16px 时聚焦自动放大整页 → 移动端断点下把 `.lw-input` 等字号提到 16px；
- 建议给可点元素加 `touch-action: manipulation`，消除双击缩放判定延迟；
- 拖拽（标题栏 `mousedown`/`mousemove`）在触屏拖动时不触发 —— 手机端一般不需要拖窗，可不处理；主窗体已禁拖，无影响。

## 3. 三种方案

| | 方案 1：移动兼容包 | 方案 2：移动流式布局 | 方案 3：业务双窗体 |
|---|---|---|---|
| 做法 | 修上面 3 个坑：visualViewport 判键盘、缩放下限、iOS 字号 + touch-action | 宽 < 断点（如 768px）时 `runLayout` 走 mobile 分支：忽略绝对坐标，控件纵向堆叠、宽度拉满 | 服务端按 UA/参数选手机版 LFM，与桌面版并存；框架只做方案 1 兜底 |
| 改动量 | 小（`lw-alpine.js` 3 处 + CSS） | 中（客户端布局引擎加分支） | 大（每个业务窗体一套手机版设计） |
| 效果 | 现有窗体"能看能点"，布局仍是桌面形，靠缩放塞进屏幕 | align 规整的窗体效果好；绝对坐标密集的老窗体效果不可控 | 手机上是真正的移动端体验 |
| 风险 | 低 | 中：每个业务窗体都要逐个真机验证 | 低（不动框架），成本在业务侧 |
| 适用 | 偶尔用手机查数据、点按钮 | 少量窗体、布局规整、不想做第二套 LFM | 手机是主力端 |

**方案 2 的硬伤**：LCL 的布局语义就是绝对坐标，`runLayout` 强行重排等于在客户端重新发明一套布局引擎，且无法知道控件之间的语义分组（谁和谁该在一行），效果全凭启发式。不建议作为长期路线。

## 4. 推荐路线

1. **短期（若要做）**：方案 1。三处小改，收益立竿见影，桌面端零影响（断点/`visualViewport` 判断都可只在窄屏或差异超阈值时生效）。
2. **中期（若要当手机端用）**：方案 1 + 方案 3。核心业务窗体单独设计手机版 LFM，桌面版一行不动。
3. **不建议**：把方案 2 当作通用解。

## 5. 若将来实施：改动点清单（方案 1）

| 文件 | 改动 |
|---|---|
| `src/client/lw-alpine.js` | `sendViewResize()`：用 `visualViewport` 判断键盘（高度差 >120px 不触发服务端 resize）；`fitMainZoom()`：加缩放下限与"允许纵向滚动"分支；输入框聚焦 `scrollIntoView` |
| `src/client/lw-alpine.css` | 窄屏断点（`@media (max-width: 768px)`）：输入控件字号 ≥16px、`touch-action: manipulation` |
| `demos/gallery/lw/` | 同步副本（坑 109：exe 旁 `lw/` 优先于 `src/client`） |

改动完成后按第 6 节验证，并回归 `t_gallery`（50 项）。

## 6. 验证方法（真机前先用 CDP 模拟）

```bash
# 150% 系统缩放等价环境（用户机器就是这个配置）
msedge.exe --headless=new --remote-debugging-port=9223 \
  --user-data-dir=<临时目录> --force-device-scale-factor=1.5 \
  --window-size=1800,1200 "http://127.0.0.1:8099/?client=alpine"
```

检查清单（`Runtime.evaluate` 取值）：

| 指标 | 期望 |
|---|---|
| `.lw-win` 的 `offsetWidth/offsetHeight` | == 视口尺寸（或按缩放下限处理） |
| `document.documentElement.scrollWidth/scrollHeight` | == 视口（无页面滚动条） |
| `getComputedStyle(.lw-win).transform` | 需要兜底时非 `none`，且 scale 合理 |
| 键盘模拟 | 改 `visualViewport`/窗口高度后画布不动（坑 1 修复生效） |
| 输入框字号 | 窄屏下 ≥16px |

注意（2026-11-16 复测修正）：Edge 157 + `--headless=new` 下 `Emulation.setDeviceMetricsOverride`
在 8 组场景里**全部生效**，`innerWidth` 精确等于设定值，`mobile:true` 配合 viewport meta
得到 1:1 CSS 视口，证据见 `tests/cdp_device_probe.py`。早期「有时不生效」的记载多半源于
旧版浏览器或在页面加载完成前取值；若本机仍复现「innerWidth 不变」，退回
`--force-device-scale-factor` + `--window-size` 启动参数，并始终以页面加载后的
`Runtime.evaluate` 取值为准。截图为物理像素时，CSS 尺寸 = 物理尺寸 / dpr。

## 7. 术语与限制备忘

- **CSS 视口**：`window.innerWidth/innerHeight`（不含浏览器 UI），`sendViewResize` 发的是它，高度再减 28px 标题条；
- **LCL 像素 = CSS 像素**：`Scaled=True` 下成立，服务端 `SetBounds` 不需要 PPI 换算；
- **窗体最小尺寸**：服务端 `LWApplyFormResize` 下限 240×180，窄屏（<240px）不可能出现，但会把缩放下限逻辑压到极小；
- **移动端后台**：WebSocket 在页面冻结/切后台时可能断开，现有重连/自愈机制（lwhyper 巡检 + 客户端 resync）可覆盖，但需真机验证重新激活后的首帧。

## 8. 方案 B 的自适应判定与移动模板（2026-11-16 设计并实施）

> 适用前提：本节记录 2026-11-16 的方案 B（占位符 + DOM 搬迁）；
> 判定策略（8.1~8.5）仍有效，模板接口（8.6）已改为背景装饰层，见下文标注。
> 本节固化判定策略与实测依据。
> 基线校正：第 1 节表格里的 `sendViewResize()` / `fitMainZoom()` 在当前
> `src/client/lw-alpine.js` 中并不存在（全仓检索只命中本文），现有链路只有
> `ResizeObserver`（:2609-2611）；第 6 节的 CDP 注记已按复测结果修正。

### 8.1 结论：判「布局模式」，不判「设备」；判定放在浏览器

方案 B 的模板是在浏览器里把已构建的控件 DOM 搬进占位符，服务端不参与选择，
因此**不需要在 Pascal 侧识别手机**。真正要回答的是「此刻该不该启用流式模板」，
它由可用宽度决定：桌面窗口拖到 420px 同样塞不下 1200px 的绝对定位窗体，
手机横屏 844px 也仍该留在流式布局。把三个量分开，不要压成一个布尔值：

| 量 | 取值 | 依据 | 用途 |
|---|---|---|---|
| layout | `mobile` / `desktop` | 宽度断点 + 回滞 | 是否套模板、是否跳过 `placeNode` / `runLayout` |
| input | `touch` / `mouse` | `(any-pointer: coarse)` 且 `(hover: none)` 同时成立 | 触控细节（字号 ≥16px、`touch-action`、点击目标 ≥44px），与 layout 独立 |
| capability | 键盘 / 方向 / 缩放 | `visualViewport`、`orientation` | 第 2 节坑 1/2 的兜底，不参与模式判定 |

### 8.2 信号优先级

| 层 | 信号 | 实测可靠性 | 用途 |
|---|---|---|---|
| 硬覆盖 | URL 上的 `?layout=desktop\|mobile\|auto`（客户端直接读 `location.search`，服务端无需改动；请求参数读取见 `lwhttp.pas` 的查询串解析）、`sessionStorage['lw-layout']` | 确定 | 用户手动切、演示、排障 |
| 主判据 | `matchMedia('(max-width: 834px)')` / `('(min-width: 1100px)')` + 回滞区 | 高（8 场景现读全对） | layout |
| 输入判据 | `any-pointer: coarse` + `hover: none` | 高（UA 伪造不改它） | input |
| 辅助 | `orientation`、`visualViewport.height` | 中 | 横竖屏、键盘兜底 |
| 弱信号 | UA 关键字、`navigator.userAgentData.mobile` | 低 | 仅统计 / 日志 / 首屏提示，不参与判定 |
| 禁用 | `navigator.maxTouchPoints > 0` | 桌面 headless 实测为 10 | 不可作为触摸依据 |

### 8.3 实测数据（`tests/cdp_device_probe.py`，Edge 157 headless）

| 场景 | innerW×H | coarse | UA 含 Mobile | UAD.mobile | 判定 |
|---|---|---|---|---|---|
| 桌面基线 | 1200×900 | 否 | 否 | false | desktop |
| 桌面窄窗（只改尺寸） | 420×900 | 否 | 否 | false | **mobile** |
| 手机完整模拟 | 390×844 | 是 | 是 | false | mobile |
| 仅伪造 UA | 1200×900 | 否 | 是 | false | **desktop** |
| iPad 竖屏 | 820×1180 | 是 | 是 | false | mobile |
| 桌面触屏 | 1200×900 | 是 | 否 | false | desktop（但 input=touch） |
| 折叠屏外屏 | 280×653 | 是 | 是 | false | mobile |
| 手机横屏 | 844×390 | 是 | 是 | false | mobile（回滞区，触控优先） |

其它实测事实：viewport meta 生效（390px 视口按 1:1 渲染，`visualViewport.scale=1`）；
首屏请求头**只有 `User-Agent`**，没有任何 `Sec-CH-UA-*`；`userAgentData.mobile`
在全部 8 场景恒为 `false`（CDP 覆盖 UA 时不联动），更说明不能拿它当主判据。

### 8.4 自研判定代码（全部 Web 标准 API）

> 下面是与 `src/client/lw-alpine.js:2191-2236` 同步的简化版；模板 fetch 与
> DOM 搬迁的完整实现以源码为准。

```js
var TPL_MQ_IN = '(max-width: 834px)';
var TPL_MQ_OUT = '(min-width: 1100px)';
var TPL_KEY = 'lw-layout';      /* ?layout= / sessionStorage 硬覆盖 */
var layoutState = null;         /* null / 'desktop' / 'mobile' */
var tplCache = {};              /* 模板串缓存；404 也缓存为 null */

function lwIsTouch() {
    return matchMedia('(any-pointer: coarse)').matches &&
           matchMedia('(hover: none)').matches;
}
function lwLayoutNow() {
    var force = null;
    try {
        force = new URLSearchParams(location.search).get('layout') ||
                sessionStorage.getItem(TPL_KEY);
    } catch (e) { }
    if (force === 'desktop' || force === 'mobile') return force;
    var enter = matchMedia(TPL_MQ_IN).matches;
    var leave = matchMedia(TPL_MQ_OUT).matches;
    if (layoutState === null) {
        if (enter) return 'mobile';
        if (leave) return 'desktop';
        return lwIsTouch() ? 'mobile' : 'desktop';
    }
    if (enter) return 'mobile';
    if (leave) return 'desktop';
    return layoutState;                            /* 835~1099 保持 */
}
function lwApplyLayout() {
    var want = lwLayoutNow();
    if (want === layoutState) return;
    layoutState = want;
    document.documentElement.setAttribute('data-lw-layout', want);
    document.documentElement.setAttribute('data-lw-input', lwIsTouch() ? 'touch' : 'mouse');
    lwRelayout(want);                              /* 已实现：按目标模式搬迁 DOM */
}
var pending = false;
function lwSchedule() {                           /* 事件只当触发器，状态一律现读 */
    if (pending) return;
    pending = true;
    requestAnimationFrame(function () { pending = false; lwApplyLayout(); });
}
[TPL_MQ_IN, TPL_MQ_OUT, '(any-pointer: coarse)', '(orientation: landscape)'].forEach(function (q) {
    var mq = matchMedia(q);
    if (mq.addEventListener) mq.addEventListener('change', lwSchedule);
});
window.addEventListener('resize', lwSchedule);
window.addEventListener('orientationchange', lwSchedule);
if (window.visualViewport) visualViewport.addEventListener('resize', lwSchedule);
lwApplyLayout();
```

### 8.5 为什么「事件只当触发器、状态现读」

动态切换实测（同一页面注入监听后连续改视口）：

| 动作 | 现读状态 | 实际派发的事件 |
|---|---|---|
| 1200 → 390 竖屏 | `narrow=1 coarse=1 hoverNone=1` | `resize`×2、`vv`×2、`orient=0`；**`narrow=1` 的 change 没派发** |
| 390 → 844 横屏 | `narrow=0 landscape=1` | `resize`、`vv`、`narrow=0`、`orient=1` |
| 844 → 960 回滞区 | `narrow=0 wide=0` | `resize`、`vv`；指针变化无 change |
| 960 → 1200 | `wide=1` | `resize`、`vv`、`wide=1` |

结论：`matchMedia` 的 `change` 在首次断点变化、指针能力变化时可能漏发，
`resize` / `visualViewport.resize` 又会成组重复；因此**不能在事件里读
`e.matches` 决定状态**，必须每次现读、用 `requestAnimationFrame` 去重（必要时再加
120~160ms 防抖，与现有 `ResizeObserver` 链路一致），并靠回滞区消除来回跳变。
主判据取宽度，键盘弹出只改高度，`lwApplyLayout()` 幂等返回，天然免疫第 2 节坑 1
的高度抖动。

### 8.6 与模板层的接口（已实现，实现要点）

- **【2026-11-18 现状】** `lwRelayout(mode)` 不再搬动任何控件 DOM：
  模板作为 `.lw-tpl.lw-tpl-backdrop` 背景层插入客户区最前，控件仍在
  窗体 kids 里按 LFM 的 `Left/Top` 绝对定位；`S.P[id]` / `S.E[id]` 不变，
  事件 id、Alpine 指令、增量 patch 全部照常生效（坑 149 的不变式保留）。
- **【现状】** 桌面模板 `<窗体名>.html`（窗口/平面两模式共用这一个文件），
  移动模板 `<窗体名>.m.html`（移动端只读，无模板直接回 LCL 布局）；
  文件头 `lw-tpl-mode:flat` 时 `lwApplyFlatTpl` 隐藏标题栏/拖角、铺满
  视口、页面自身滚动；`window` 时保持原浮窗几何。两种模式都不加
  `lw-flow`、不跳过 `placeNode` / `runLayout`；两份模板都只作背景装饰层。
- **【现状】** 模板缺失或解析失败时整体回退设计期布局；旧 `.flat.html`
  仍按兼容规则触发平面模式（flat 优先）。
- **【现状】** 移动端套上 `.m.html` 后，模板只是装饰层：控件保持设计期
  绝对定位，窗体也**保持设计宽高**（设计尺寸小于视口时撑满视口），
  超出视口的内容靠 `#lw-root` 平移滚动查看（`fm.tplFallback=true`）。
  不能把窗宽压成 `min(设计宽, 视口宽)`：压窄后页签页按窄宽重排，
  右侧 TPageControl 里的控件会被裁成空白（坑 179）。无 `.m.html` 时
  直接回 LCL 布局（不读桌面 `.html`）。
- **【现状】** 移动布局下，主题入口统一为右下角可拖动浮钮 `.lw-theme-fab`
  （窗口模式与平面模式都挂）：28px 标题栏里的 22px 图标手指点不准；桌面
  布局的窗口模式仍用标题栏图标，移动布局用 CSS 隐藏那份，桌面布局自动摘
  浮钮（`themeEntrySync` 在布局/模板切换时幂等纠正）。
- 以下为 2026-11-16 原方案记录，仅作历史参考：模板内部的列数/间距/字号
  交给模板自己的 `<style>`；占位符对不上控件 `Name` 时整体回退。
- **无模板回退窗体不做整体等比缩放**（2026-11-16 定稿）：曾实现
  `transform: scale((innerWidth-8)/设计宽)` 的 fit-width 方案并验证通过，
  但 1200 设计宽压到 390 屏字号只有 0.32 倍，实际不可读 —— 用户拍板放弃。
  也不把窗体硬压到视口宽：压窄后子控件仍按设计坐标摆，右侧被裁/留白，
  拖动窗体只会让空白挪位置（真机截图反馈）。**定稿为平移模式**：
  窗体保持设计宽高（字号原大，设计尺寸小于视口时撑满视口），固定
  `left=0` 且禁止标题栏拖动，超出视口的内容由 `#lw-root` 滚动平移查看
  —— `lwUpdatePan()` 按存在回退窗体与否开关 `html[data-lw-pan]`，
  CSS 侧 `html[data-lw-pan="1"] #lw-root { overflow:auto }`；
  `lwFallbackSize` 在旋转/改窗/键盘弹出时跟随视口重算（挂在
  `lwScheduleLayout` 每帧）。要小屏单列可用性请为窗体配移动模板。
- 移动模式下窗体保持设计宽高并开平移（`savedPos` 保存 left/width/height，
  切回桌面恢复；`top` 固定 6px），状态栏贴窗体底；切换时若有输入焦点，
  延后到 blur 或保留焦点。
- 硬覆盖：URL `?layout=desktop|mobile` 与 `sessionStorage['lw-layout']`，
  运行期可用 `LW.layout.set()/get()` 读写；仅 Alpine 层实现，Ext 层是
  组件树，不适用。

### 8.7 服务端与授权边界

- 服务端**零改动**：`?layout=` 只是可选的硬覆盖，走现有 `QueryP`。
- 若业务侧确实要拿 UA 做统计：本机 fcl-web 3.3.1 实测 `ARequest.UserAgent` 有值；
  `ARequest.GetCustomHeader('User-Agent')` 返回**空**（标准头不进 CustomHeaders，
  项目现有的自定义头读取写法只适用于自定义头，不能用来读 User-Agent）。
- 首屏请求头无 `Sec-CH-UA-Mobile` 等 Client Hints，要拿需服务端发 `Accept-CH`
  且浏览器支持，首次请求通常仍缺失 —— 不足以承担布局判定。

### 8.8 遗留（真机验证项，非本次范围）

CDP 模拟下 `(any-pointer: coarse)` 关闭触摸后有粘滞、`maxTouchPoints` 桌面非 0，
指针能力需在真机上复核；iOS 键盘与 `visualViewport` 的关系、折叠屏切换时的
连续两次 resize、后台冻结后首帧，均需真机验证。

另记一个**测试脚手架伪影**（不是产品缺陷）：CDP 改视口尺寸前若先
`clearDeviceMetricsOverride`，视口会瞬间回到真实窗口宽（1200，命中退出断点），
回滞区把误锁的 desktop 保留到下一个尺寸；真机旋转是 390↔844 直接跳变，
不经过中间宽。模拟时直接叠加新的 `setDeviceMetricsOverride` 即可
（`cdp_fit_scale.py` 的 `metrics()` 已按此写法）。

---

相关：`NOTES.md` 坑 111（视口自适应链路）、坑 112（主窗体最大化 + 缓存指纹）、`DEBUGGING.md`（CDP 取证方法论）。
