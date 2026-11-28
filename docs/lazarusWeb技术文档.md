# lazarusWeb 技术文档 —— 技术路径 · 实现方法 · 使用说明

> 版本 0.9.6 · 更新日期 2026-11-16
> 配套文档：`README.md`（快速上手）、`docs/COMPARISON_unigui.md`（与 uniGUI 对照）、
> `docs/CONTROL_MATRIX.md` / `docs/DB_AWARE_MATRIX.md`（控件支持度实测矩阵）、
> `docs/NOTES.md`（212 个坑的踩坑实录，坑 23/66/108 等旧结论已被后续坑修订）、`deploy/README.md`（HTTPS/反向代理/集群）。

---

## 一、技术路径

### 1.1 定位

lazarusWeb 是 **Lazarus 桌面程序的 Web 化运行时**：把真实运行的 LCL 控件树
序列化成浏览器界面——**默认 Alpine.js 渲染层**（内置依赖，零额外部署），
**Ext JS 为可选渲染层**（自备 `ext-<版本>/` 并 `--client=ext` 显式启用）。
业务程序只改一行基类（`TForm` → `TLWForm`），事件、属性、`.lfm` 全部原样保留，
就能以服务程序的形式跑在浏览器里。

### 1.2 选型思路（为什么走这条路）

| 候选路线 | 结论 |
|---|---|
| Delphi/uniGUI 类影子控件体系 | 商业授权；控件是"影子类"，IDE 设计器体验受限 |
| 纯前端框架（Vue/React）重写业务 | 业务代码零复用，等于重做一遍 |
| **真 LCL 控件树 + 序列化（本方案）** | 业务代码 100% 复用；TForm 后代在 IDE 里照常设计；RTTI 天然可用 |

关键决策三条：

1. **TForm 后代，不是代理类**。`TLWForm` 是真正的 `TForm` 后代，拖上去的
   TButton/TEdit 就是 LCL 自己的控件——属性面板、事件页、锚点、对齐工具照常可用，
   设计器里的布局就是浏览器里的布局。
2. **nogui widgetset 当"虚拟显示器"**。服务端编译为 `--ws=nogui`，控件真实创建、
   真实维护属性与事件，只是没有屏幕。缺的 GDI 设施由 `lwws.pas` 补丁提供。
3. **服务端权威，浏览器只做渲染**。控件树、状态、事件路由全在服务端；
   浏览器端默认由 `lw-alpine.js`（配 `alpine.min.js`）把 JSON 树渲染成原生
   DOM/CSS 并做增量协调（reconcile）；可选 Ext 层由 `lw.js` 渲染成 Ext 组件，
   两层共用同一套 JSON 协议与事件/推送通道。

### 1.3 总体架构

```
浏览器（Alpine.js 3.14.9 默认 / Ext JS 可选）  服务端 (FPC 3.3.1 + Lazarus, nogui)
┌────────────────────────────┐  WS/长轮询 ┌──────────────────────────────┐
│ lw-alpine.js（默认）        │  JSON     │ lwhttp   fphttpserver 多线程   │
│  原生 DOM/CSS + Alpine 指令│ ←────────→ │ lwsession 每标签页一棵 LCL 树  │
│  可选：lw.js → Ext 组件    │  HTTP      │ lwwriter  LCL树 → JSON        │
│  reconcile 增量协调         │            │ lwdispatch 事件 → RTTI 调业务  │
│  WS 只传事件请求/响应       │            │ lwws     nogui 补丁(虚拟显示器)│
│  长轮询游标统一下发推送      │            │                              │
└────────────────────────────┘            └──────────────────────────────┘
```

服务端核心单元与浏览器端渲染脚本的行数为早期快照（默认层 lw-alpine.js 与
可选层 lw.js 均持续演进），精确行数不在此维护；两层职责见 2.3。

### 1.4 移动端技术路径（自适应 + 窗体模板，服务端零改动）

手机/窄窗口适配沿用同一世界观：**服务端权威、浏览器只管呈现**——设备
识别、模板、布局全部在渲染层完成，业务 Pascal 代码一行不改，服务端
单元零改动（实现细节见 2.14，指南见 `MOBILE.md` / `MANUAL.md` 第二篇 16）。

| 候选路线 | 结论 |
|---|---|
| 服务端 UA 探测 + 双树下发 | 判定进服务端就要开维护口子，且 UA 不可靠、桌面窗口缩小照样误判 |
| 整体等比缩放（transform scale） | 390 屏上字号只剩约 0.3 倍不可读（实测后否决，坑 150） |
| 流式重排（自研布局引擎） | 工程量大、与设计期锚定布局冲突，长期维护成本高 |
| **前端自适应 + 窗体级 HTML 模板（本方案）** | 判定/模板/回退全在客户端；业务可选配模板，不配也能用 |

关键决策四条：

1. **判定三量分离，只在前端做**：`layout`（视口宽 + 回滞：≤834 进 /
   ≥1100 出）、`input`（触屏能力）、`capability`（兜底）各判各的，
   根标记挂 `html`；服务端从头到尾不知道设备是什么；
2. **模板按端分文件 + 模式标记**：桌面窗口与平面模式共用
   `<root>\tpl\<窗体名>.html`，移动端用 `<窗体名>.m.html`（两文件都只作
   背景/装饰层）。文件头写 `lw-tpl-mode:window|flat`（两标记并存时 flat 优先）。
   模板**不重排控件**；控件始终按 LFM 的 `Left/Top` 绝对定位，服务端只做
   静态文件下发；
3. **不搬迁、不改逻辑父级**：`S.P[id]` 与 DOM 父级都不变，增量补丁机制
   完全不受影响；模板缺失/解析失败时整体回退设计期布局，绝不半套；
4. **无模板也是一等公民**：没配模板的窗体两端都保持设计期所见即所得
   （桌面=绝对定位原样；移动=平移模式，设计尺寸原样、`#lw-root` 滚动、
   字号不缩），保证任何老程序开箱可用、行为与历来完全一致。

**怎样实现桌面端 ↔ 移动端的自适应（机制一览）**：

1. **判定**：三量分离、只在前端。`layout` 按视口宽 + 回滞判定
   （≤834px 进移动 / ≥1100px 出 / 之间保持，防拖动抖动）；`input` 用
   `any-pointer:coarse` + `hover:none` 判触屏；`capability` 只兜底不参与。
   结果挂根标记 `html[data-lw-layout]` / `html[data-lw-input]`，
   `matchMedia` 现读 + rAF 去重；硬覆盖 `?layout=` →
   `sessionStorage['lw-layout']` → `LW.layout.set()`，优先级最高；
2. **配了模板 → 背景装饰层**：客户端 fetch 同名 `.html`，按文件头标记
   决定浮窗或整页平面模式；模板作为 `.lw-tpl` 背景层插到客户区最前，
   `pointer-events:none`；控件 DOM 不动，按设计期绝对坐标绘制；
   平面模式无标题栏/边框/拖动/缩放，宽高取 max(设计值, 视口)（窄屏保持
   设计宽、超出部分平移查看，压到视口宽会把右侧控件裁掉），窗口模式保持原几何；
3. **没配模板 → 设计期所见即所得**：桌面绝对定位原样；移动平移模式
   （设计尺寸原样、贴左、禁拖动、`#lw-root` 滚动，`html[data-lw-pan]`）；
4. **个别控件换形态**：CSS 按 `data-lw-layout`/`data-lw-input` 切换，
   如 TUpDown 桌面上下箭头 / 移动端 −/+ 大触控区（坑 152）。

业务代码全程零改动；想给某窗体做手机单列版，只需新增一个模板文件
（改完刷新即生效），范例 `demos/mobile_demo`。端到端细节见 2.14。

---

## 二、实现方法（按模块）

### 2.1 lwws.pas —— nogui widgetset 补丁（整个方案的基石）

nogui widgetset 缺显示器、缺画布，直接 `TForm.Create` 就 AV（坑 1）。补丁提供：

- **虚拟显示器**：固定 96 DPI 的屏幕尺寸，`Form.Show/Visible` 不再除零（坑 4）；
- **空 WS 类注册**：所有控件声明"事件能力为空集"的 widgetset 类，构造不崩（坑 3/17.2）；
- **GDI 补齐**：菜单、位图图元等 nogui 下缺失的设施的最小实现；
- 全部包在 `{$IFDEF LCLnogui}` 里，非 nogui 下退化为空实现——因此包能在 IDE 里
  直接编译，工程仍必须 `--ws=nogui`（坑 15/19）。

### 2.2 lwwriter.pas —— LCL 树 → JSON（1337 行）

反射遍历窗体的控件树，把每个控件序列化成 `{id, kind, props, children}`：

- 属性按**白名单映射表**输出（不是全量 RTTI dump），映射关系见 `docs/lazarusWeb控件属性映射表.md`；
- 事件能力用类引用表声明（Click/Change/DblClick/KeyPress…）；
- 增量输出：树带 `seq`，浏览器按 id diff，只更新变化的节点（reconcile）；
- 特殊控件有专门序列化分支：`TRadioGroup/TCheckGroup/TValueListEditor` 的
  Items/Rows 结构（坑 25）、`TTreeView` 的节点树、`TStringGrid` 的行列等。

### 2.3 lw-alpine.js —— 默认浏览器端渲染与协调（Alpine.js 层）

- 把 `kind` 映射到**原生 HTML/CSS + Alpine 指令**（默认层覆盖全部常用可视控件，
  含 grid/tree/chart 的 SVG 渲染）；`alpine.min.js` 随包内置下发，不走 CDN；
- **reconcile**：新树到达后按 id 对账，未变的 DOM 实例不动（保留输入焦点）；
- 事件捕获：DOM 事件带上 `id/ev/val`（连着 WS 时走 WS 帧，否则 `POST /lw/api/event`）；
- **窗体模板（与 Ext 层共用同一份文件，见 2.14）与移动端适配**：模式判定、
  背景装饰层与整页/浮窗渲染均在客户端完成；未配模板时仍保持设计期所见即所得；
  移动端断点/平移回退为本层独有；
- **长轮询 `/lw/api/poll` 是唯一推送通道**：推送统一入会话队列带序号（模态/消息框/遮罩/下载指令），各页签带 `after` 游标各取各的；
- **WebSocket `/lw/ws` 只传事件请求/响应**：连上后事件走 WS 帧（长轮询不停），断了自动退回 HTTP `/lw/api/event`；
- 会话归属：sid 存 **sessionStorage**（页签级）。刷新留在同一会话；
  **关标签页即失效**（下次打开重新登录）；新标签页默认是独立会话。
  `/lw/api/attach` 仍在：显式带同一个 sid 打开（刷新、或业务自己把
  sid 传给新页签）就挂到已有会话上，按游标各取各的推送。
  `localStorage['lw.persist']='1'` 可改成跨页签/跨重启保持。

**可选 Ext 渲染层**：`lw.js` + `ext-<版本>/` 把同一份 JSON 映射到 Ext 组件树，
需 `--client=ext`（或 `?client=ext`）显式启用并自备 Ext 分发包。两层共用上面的
reconcile、事件、推送与会话协议；差别只在 DOM 构建方式与样式体系。
两层共用同一套窗体模板（`lw-tpl-mode:window|flat`、控件保持设计期绝对坐标、
平面模式宽高不小于设计值），移动端 `.m.html` 加载与断点/平移回退仅 Alpine 层有。

### 2.4 lwsession.pas —— 会话与同步模态（976 行）

- **每个浏览器标签页一个 `TLWSession`**，持有一棵窗体清单（`FForms`）；
- `Sweep` 线程分钟级清理过期会话；
- **同步模态是核心难点**：`ShowModal` 不是嵌套消息循环（服务端没有消息循环），
  而是"推送模态指令 → `TEvent.WaitFor` 挂起请求线程 → 浏览器点关闭 → 唤醒"。
  语义与桌面模态完全一致：`if f.ShowModal = mrOk then ...` 这行代码会真的等用户点（坑 5/6）；
- 推送走**带序号的会话队列**（游标协议，坑 33）：各页签 `poll?after=N` 各取各的；
  对话框指令带 `to=<页签标识>` 定向，只有发起页弹窗；
- 关闭窗口自动回登录页：`VisibleWebFormCount = 0` 且有 LoginForm 时自动
  `SessionShowForm(LoginForm)`（坑 35.4，修"关窗后必须重启服务才能再登录"）。

### 2.5 lwdispatch.pas —— 事件 → RTTI（752 行）

- `POST /lw/api/event` 的 `{sid,id,ev,val}` → 找到会话里的控件 → **值先写回控件**
  （`val` 写 Text/Checked/ItemIndex…，网格还有 `row/col/vals` 单元格编辑）→
  用 RTTI 找到 published 事件方法触发；
- 线程模型：fphttpserver 每请求一线程，事件处理就发生在该请求线程里——
  这正是同步模态能"阻塞等待"的前提；
- 懒加载页签：元素级事件在未渲染控件上要挂到代理元素（坑 34）。

### 2.6 lwhttp.pas —— HTTP 服务与路由（1448 行）

fphttpserver 多线程服务器，路由表：

| 路由 | 说明 |
|---|---|
| `GET /` | 界面外壳（`?form=?ext=?theme=?fresh=1` 可覆盖） |
| `POST /lw/api/session` | 新建会话 → 树 + sid + seq |
| `GET /lw/api/attach?sid=` | 新页签挂到已有会话（过期回 410 + `gone`） |
| `GET /lw/api/tree?sid=` | 当前组件树 |
| `POST /lw/api/event` | 事件 → RTTI → 新树 |
| `GET /lw/api/poll?sid=&after=` | 长轮询（游标式推送队列） |
| `GET /lw/api/log?sid=` | 会话日志（Show/ShowModal/EndModal 全记录） |
| `POST /lw/api/close` | 结束会话 |
| `POST /lw/api/upload?sid=&id=` | multipart 上传 → 新树 |
| `GET /lw/download?t=` | 一次性令牌下载（URL 不出现服务端路径） |
| `GET /lw/ajax/<名字>` | 自定义 AJAX 端点（lwajax 注册） |
| `GET /lw/healthz` | 健康探针 `{"ok":true,"sessions":..,"uptime":..}` |
| `GET /lw/tpl/<名称>.html`、`.m.html` | 窗体布局模板（桌面 `.html` 为窗口/平面共用单文件，移动只读 `.m.html`；文件头 `lw-tpl-mode` 标记）：`<root>\tpl\` → `<exe目录>\tpl\` 两级回退，挡路径穿越（403），响应 no-store（改模板刷新即生效）；另兼容探测旧 `.flat.html`（存在即平面优先）；模板缺失时整体回退设计期布局 |
| `GET /lw/lw-alpine.js、/lw/alpine.min.js…` | 默认 Alpine 层脚本/样式（lw-alpine.js / lw-alpine.css / alpine.min.js） |
| `GET /lw/lw.js、/lw/lw.css` | 可选 Ext 层脚本/样式（`--client=ext` 时才加载） |
| `GET /ext/<版本>/...` | 可选 Ext JS 静态资源（任意版本目录，见下；未部署 Ext 时不请求） |
| `GET /lw/ws` | WebSocket 升级（fphttpserver trunk，坑 26） |

静态资源/根目录定位有多级回退（坑 30）：当前工作目录 → exe 向上 5 层 →
`--root=` 显式指定。`--trust-proxy` 时客户端 IP 取 `X-Forwarded-For`。

**Ext 目录解析与版本无关**（坑 40，仅可选 Ext 层需要）：URL 里的版本段只是
一个"目录名"，不再和 7.0.0 / x.x.x 这些具体版本号绑定。默认 Alpine 部署
没有 `ext-*` 目录，也不请求 `/ext/` 路由。

```
ExtRootFor(ver):
  1. <root>\ext-<ver> 存在        -> 用它（严格匹配）
  2. 否则，root 下「有且仅有一个」 ext-*  -> 回落（只装了一个版本，随便叫什么都行）
  3. 否则                          -> 404（多版本共存时绝不猜）
```

版本段只放行 `[0-9A-Za-z._-]`（且长度 ≤ 32），`..`/`:`/`\` 一律 403 —— 用
"目录真实存在"替代原来的版本白名单，安全性等价而不再需要改代码加版本。
同理：charts 包按 `ext-<ver>/build/.../charts.js` 是否存在决定注入，主题按
CSS 三件套是否存在回落 crisp → classic → neptune，都不再写死版本号。

### 2.7 lwdlg.pas —— 对话框改道浏览器（549 行）

业务代码**一行不改**，LCL 对话框在服务端被改成"浏览器弹模态框"：

- 挂钩点：`InterfaceBase` 的 `PromptDialogFunction / InputDialogFunction /
  QuestionDialogFunction`、`Forms.MessageBoxFunction`、
  `RegisterWSComponent(TOpenDialog, ...)`——运行时替换，`uses lwapp` 即生效；
- 服务端线程真的阻塞等答复（180 秒超时），与桌面模态语义一致；
- 文件对话框：`TOpenDialog.Execute` = 浏览器选文件**先上传**到
  `%TEMP%\lw_uploads\<sid>\pick\`，`FileName` 是服务端路径；
  `TSaveDialog` 落 `<sid>\save\`，写完 `SendFile` 推给用户（坑 17.5）；
- 无浏览器会话时（IDE 调试/单测）自动退回 LCL 原实现。

### 2.8 上传/下载安全（lwupload / lwdownload / lwfileupload）

- `TLWFileUpload`（TButton 后代）：浏览器弹系统选框，XHR 带进度，
  按钮文字实时显示百分比；`Filter/Multiple/MaxSizeKB/TargetFolder` 全参与校验；
- `TLWCamera`（`TLWFileUpload` 的专用后代，lwcamera.pas）：拍照控件，按环境
  自动选路。移动端动态建 `<input type=file accept=image/* capture=environment|
  user>` 唤起**系统相机 App**（`Facing` 控制前后置）；capture 方案不要求安全
  上下文，手机走局域网 http 也能用。桌面端（鼠标/触控板 + HTTPS/localhost）
  改用 getUserMedia 弹页面内取景框，「拍摄」把当前帧画进 canvas 压到长边
  1600px 转 JPEG —— 桌面浏览器本来就忽略 capture，而 http 局域网下
  getUserMedia 又被禁止，两条路都不通时退化选图片文件；失败过一次会置
  `_camFail` 直接降级（getUserMedia 的 catch 已脱离用户手势，不能再弹文件框）。
  上传/落盘/洗白/大小上限全部复用 TLWFileUpload 链路（lwupload 按
  `C is TLWFileUpload` 找控件，后代天然命中），落盘后 `AddUploadedFile`
  触发 `OnCapture`。预览是**浏览器本地**的：`PreviewImage` 指定目标 TImage
  的名字，writer 解析成节点 id 下发，客户端拍完用 ObjectURL 直接塞 img
  （`data-lw-photo` 标记 + `!important` 压过 TImage 的 visibility:hidden
  绑定）—— 手机照片几 MB，不进组件树补丁；
- multipart 自解析（坑 13.1），文件名**强制洗白**：去路径、去 `..`、去非法字符，
  不信 `Content-Disposition`（坑 13.2）；
- 下载走**一次性令牌**：`SendFile` 登记 30 分钟令牌，浏览器拿到的只有
  `/lw/download?t=<token>`，用后即废（坑 13.3）。

### 2.9 lwlogin.pas —— 登录框架

- `TLWLoginForm` 是 lfm/IDE 可设计的普通窗体；
- `TLWApp.SetLogin(TXxxLoginForm)` 一行启用；未认证会话的**所有事件一律拒绝**；
- 认证状态存会话级（不是进程级全局，坑 32.3）；输错密码的值同步问题在框架层
  三道闸修复（坑 32.2）。

### 2.10 数据感知（lwdbgrid / lwdbnav + LCL 原生 DB 控件）

- `TLWDBGrid`：行定位、列头排序、单元格编辑回写、`PageSize` 分页、
  `ShowFilter` 过滤条、`SummaryType(gsSum/gsAvg/gsCount)` 汇总条、
  `HeaderGroups` 两级表头（`hg=[{t,a,n}]`，Alpine 两行 thead / Ext 嵌套列）；
- `TDBNavigator` 在 nogui 下构造即崩（位图图元链，坑 23）→ `LWNewNavigator`
  工厂出安全子类；lfm 里必须写真实类名 `TLWDBNavigator` 并
  `RegisterClass(TLWDBNavigator)` —— `RegisterClassAlias` 方案已被推翻（LCL
  已注册 `TDBNavigator`，别名注册顺序不可控，见坑 29/41）；代码侧仍可用
  `LWNewNavigator()` 工厂，用户代码只写 LCL 类型；
- 12 种 data-aware 控件全部实测（`docs/DB_AWARE_MATRIX.md`），三条硬规则见
  README「数据库应用」节（SQLite 用 VARCHAR、必须显式 Commit、编辑态不下发网格行）。

### 2.11 周边能力

| 单元 | 能力 |
|---|---|
| `lwchart.pas` | `TLWChart` ctLine/ctBar/ctPie，ext-x.x.x charts 包渲染，运行时切类型 |
| `lwreport.pas` | 报表引擎：可打印 HTML（A4/@media print/thead 逐页重复）+ CSV（BOM+CRLF）+ **真 XLSX**（zipper 打包 OOXML，零第三方依赖） |
| `lwdiff.pas` | 增量补丁（`--patch=1`）：两次 BuildPayload 的 forms 数组 diff 出 ops，客户端按 `tver` 自愈回全量（设计见 `docs/SCALE.md` §2） |
| `lwui.pas` | `TLWGauge` / `TLWColorPicker` / 会话级遮罩 |
| `lwweb.pas` | `TLWHTMLFrame` / `TLWPDFFrame` 富内容显示 |
| `lw-alpine.js` | **默认渲染层**（Alpine.js 3.14.9）：无需 ext-\<版本\> 目录；Ext JS 为可选层，需 `--client=ext` 显式启用（坑 89–97） |
| `lwajax.pas` | `TLWApp.AddAjax(name, handler)` 自定义端点；上下文给 Param/Header/JSONBody/Session；未注册名回 404 并自省列出全部端点 |
| `lwwebsocket.pas` | `/lw/ws` 升级（RFC6455）：**只传事件请求/响应**；推送一律由长轮询游标下发（`OnPushCommand` WS 直推保留但默认不启用） |
| `lwhyper.pas` | 专用负载均衡器（对标 uniGUI Hyper Server）：单进程拉起 N 个 worker（同 exe 多开）、崩溃自动重启、HTTP 反向代理 + sid 会话粘性、WebSocket TCP 级透传、healthz 巡检；`tools/lwhyper.exe` 是入口，自身端点 `/lw/healthz`（汇总）与 `/lw/hyper/status`（worker 明细） |
| `lwpanel.pas` + `lwrlog.pas` | GUI 服务端面板（对标 uniGUI 独立服务器窗口）与统一日志（见下） |
| `lwconfig.pas` | INI 解析底座：键名归一化（大小写/`-`/`_`/空格）、忽略分节、UTF-8 BOM、`--config=`。单元自身取 `Port` / `Theme` / `ExtDir` 三项；`log` / `language` / `patch` / `ssl*` / `client` / `plugin.*` 由 `lwapp.pas` 的 `ApplyConfigFile` 读同一个 INI（见 3.2.1）。命令行永远优先 |
| `lwnewproject.pas` + `src/design/lwdesign.lpk` | IDE 向导（New Project 一个 `lazarusWeb` 模板，选中后三框：**应用模式** 普通/服务(daemon) 决定是否生成 `uDaemon.pas`+`uMapper.pas`+`lazarusWeb.ini` 与 `.lpr` 的 `DaemonApp` 分支，**工程类型** GUI/nogui 决定 .lpi 的 `LCLWidgetType`，**工程模板** 常规/插件：插件模式生成多进程框架 —— 宿主 `.lpr` `uses upluginproc, upluginauth, ulogin, umain` + `TLWApp.SetLogin(TLoginForm)` + `LWAuthRegister` → `PlugDiscover` → `PlugRegisterRoutes` → `PlugLaunchAll`，落盘 `common\upluginproc.pas` / `upluginguard.pas` / `upluginauth.pas` / `upluginidentity.pas` + `ulogin.pas` + `plugins\hello\` 独立插件 exe + `build-all.bat/.sh` / `stop-all.bat/.sh` / `README.md`，宿主登录（admin / analyst / guest，口令见 `LWAuthDemoPass`，验证码默认开）、清单 `roles=` 路由鉴权与签名身份头；旧同进程 `lwmodules` / `RegisterAllModules` 只留在 `demos/plugindemo`）/ New Form / 组件面板，与 `tools/lwnew.exe` 命令行（`--service` / `--plugin`）共用同一模板；lwdesign 把全部自定义控件注册进 IDE，带它们的窗体才能在设计器里打开；另在 Tools 菜单注册「生成 lazarusWeb 窗体模板」（`lwdsgntplcore` 解析 .lfm + `lwdsgntplgen` 写盘；选窗口/平面模式，生成带模式标记的桌面 `<窗体名>.html` 与移动 `<窗体名>.m.html`，见 2.14 与坑 154）。这是两个独立入口：New Project 向导建工程，Tools 菜单生成窗体模板，别混为一谈 |
| `lwconvert.exe` | **LCL → Web 转换器**：`.pas` 基类与 uses 改写、`.lpr` 启动代码改写、`.lpi` 重新生成为 nogui 工程，附支持度报告 |

### 2.12 GUI 服务端面板（lwpanel + lwrlog，对标 uniGUI 独立服务器）

- **统一日志 `lwrlog`**：`LWLog/LWLogFmt` + `LWSetLogSink` 回调；无 sink 时
  200 行后备缓冲，sink 挂上时一次性补发；`LWStdOutOpen` 用
  `TTextRec(Output).Handle` 实测 stdout 是否真被 RTL 打开（GUI 子系统下
  `IsConsole` 不可靠，裸 WriteLn 会 I/O 103，坑 35.1）；
- **面板 `lwpanel`**：菜单（文件：打开浏览器/复制地址/退出；管理：清空日志/
  verbose/关于）+ TMemo 滚动日志（限 4000 行）+ 状态栏三格（地址/会话数/时长，
  TTimer 800ms 从临界区缓冲 swap，不用 Synchronize）；
- **accept 循环后台化**：`TLWServerThread` 跑 `FServer.Start`，主线程跑
  `Application.Run`；关窗 `OnClose` → `Stop`（幂等）→ `WaitFor/Free`（坑 35.2）；
- 双构建并存：`xxx.lpi`（console，--ws=nogui，tests/CI 用）与
  `xxx_gui.lpi`（win32 + `-WG`，GUI 子系统，双击即用）。

### 2.13 并发与线程模型（汇总）

```
fphttpserver（每请求一线程）
 ├─ 事件请求线程：写回值 → RTTI 触发业务 → ShowModal 时 TEvent.WaitFor 阻塞在这里
 ├─ 长轮询推送：会话队列带 seq，多页签游标各取（WS 只传事件，不推）
 ├─ Sweep 线程：过期会话清理
 ├─ TLWServerThread（GUI 版）：accept 循环
 └─ 面板 TTimer（GUI 版）：主线程定时 swap 日志缓冲
```

同一会话的模态期间其它请求在事件队列上排队——与桌面程序模态语义一致。

### 2.14 自适应与窗体模板（lw-alpine.js 内置，服务端零改动）

手机/窄窗口适配与两端窗体模板全部在 Alpine 渲染层完成，服务端 Pascal
不参与设备识别：

- **判定三量分离**（判「布局模式」不判「设备」，全部现读 + rAF 去重 +
  回滞，见 `MOBILE.md` §8）：`layout`（≤834px 进 / ≥1100px 出 / 回滞区
  保持）、`input`（`any-pointer:coarse` + `hover:none`，触控细节）、
  `capability`（visualViewport / orientation，兜底不参与判定）；
  硬覆盖 `?layout=` / `sessionStorage['lw-layout']` / `LW.layout.set()`。
  根标记：`html[data-lw-layout]`、`html[data-lw-input]`；
- **窗体模板（窗口/平面同机制）**：桌面模板 `<root>\tpl\<窗体名>.html`
  （两模式共用这一个文件）与移动模板 `<root>\tpl\<窗体名>.m.html` 由
  `lwhttp.pas` 静态路由 `/lw/tpl/<名称>` 下发（挡路径穿越 403、
  缺失 404、`no-store` 改动即生效），服务端不解析内容；客户端
  `lwFetchTpl`/`lwApplyFormTpl` fetch 后读文件头 `lw-tpl-mode`：
  `window` → 浮窗背景层，`flat` → 整页平面模式（两者并存 flat 优先）。
  桌面读 `.html`，无模板回 LCL 布局；移动端只读 `.m.html`，有模板用移动
  模板布局，无模板直接回 LCL 布局（与桌面端一致，不读桌面 `.html`）。
  模板作为 `.lw-tpl.lw-tpl-backdrop` 插到客户区最前，控件 DOM 与
  `S.P[id]` 都不变，仍按 LFM 绝对坐标绘制（坑 149 的不变式继续成立）。
  模板缺失/解析失败 → `tplFallback` 整体回退设计期布局。异步回包按
  `fm.tplSeq` 序号丢弃过期响应；`lwApplyFlatTpl` 隐藏标题栏/拖角，
  宽高取 `max(设计值, 视口)`（窄屏不压窄，超出由 `#lw-root` 平移），
  窗口模式保持设计期几何；
- **模板骨架一键生成（设计期包，坑 154）**：`lwdesign.lpk` 在 IDE **Tools
  菜单**注册「生成 lazarusWeb 窗体模板（当前单元 LFM）」——`lwdsgntplgen`
  挂菜单/写盘；点击后先弹「窗口模式 / 平面模式 / 取消」，
  `lwdsgntplcore` 行级解析 .lfm 顶层可视控件（非可视控件跳过、按
  Top/Left 视觉排序），生成桌面 `<窗体名>.html` 与移动 `<窗体名>.m.html`
  两份到 `<工程目录>\tpl\`（桌面两模式共用同一个 `.html`）：
  文件头写 `lw-tpl-mode` 标记与控件设计期坐标
  清单，正文是 `<style>` + 空 `<div>` 装饰层，不写占位符、不改控件定位。
  改包源码后需在 IDE 里 Compile/Install lwdesign 并重启；
- **无模板回退 = 设计期所见即所得**：桌面绝对定位原样（历来行为）；
  移动端窗体保持设计尺寸（字号原大）、固定贴左、禁拖动，超出视口由
  `#lw-root` 滚动（`html[data-lw-pan]`）；不做整体等比缩放（390 屏
  字号只剩 0.3 倍，实测不可读后否决，坑 150）；
- **端侧形态适配**：个别控件按 `data-lw-layout`/`data-lw-input` 换形态，
  如 TUpDown 桌面上下箭头 / 移动端 −/+ 大触控区（坑 152）。

使用与开发指南见 `MANUAL.md`（使用篇「移动端」节 + 第二篇 16），
可跑范例 `demos/mobile_demo`。

---

## 三、使用说明

### 3.1 环境与构建

- FPC 3.3.1 + Lazarus（本机 `c:\111\fpc`、`c:\111\lazarus`）；
- Alpine.js（`src/client/alpine.min.js`，随仓库内置，默认渲染层，必须保留）；
- Ext JS 7.0.0 / x.x.x（**可选**：自备 `ext-<版本>/` 且用 `--client=ext` 启用）。

```bat
cd c:\lazarusWeb
build.bat                 :: 编译全部演示（lazbuild -B --ws=nogui）
build.bat grid            :: 只编译 demos\grid
build.bat dbaware         :: 会同时产出 dbaware.exe（console）与 dbaware_gui.exe（GUI）
start-gui.bat             :: 双击启动 GUI 版服务端面板
```

Linux/macOS 用 `./build.sh`，`LAZBUILD` 环境变量可覆盖 lazbuild 路径。
**必须带 `-B`**：lazbuild 不把 `.lfm` 记进依赖表，只改界面不改 `.pas` 时
旧 `.o` 会被继续使用。

### 3.2 命令行参数

完整参数表在 README「快速开始」节统一维护（单一出处，此处不再复制）；
与旧版相比新增：`--form=` `--client=ext|alpine` `--title=` `--timeout=`
`--patch=1`。权威口径以源码 `src/core/lwapp.pas` 的 `--help` 输出为准。

### 3.2.1 配置文件（INI，解析在 `lwapp.pas`）

`TLWApp.Run` 在解析命令行**之前**先读 INI，所以顺序是
「内置默认值 → 配置文件 → 命令行」，命令行永远赢：

```ini
[lazarusWeb]
Port=8090
Theme=crisp
ExtDir=ext-x.x.x          ; 可选：仅 Ext 渲染层需要
;Patch=0
;Client=alpine            ; 默认；要用可选 Ext 层时改成 ext
```

- 文件定位：`--config=` 显式指定；否则 `<exe目录>\<exe名>.ini` →
  `<exe目录>\lazarusWeb.ini` → `<当前目录>\<exe名>.ini` →
  `<当前目录>\lazarusWeb.ini`；
- 解析器很宽容：节名可省（`[lazarusWeb]` / `[server]` / 无节名），键名忽略
  大小写与 `-`/`_`，值可用引号，`;`/`#` 为注释，UTF-8 BOM 自动跳过；
- `ExtDir` 是**目录**而非版本号：非空时 `TLWServer.ExtRootFor` 对任何
  `/ext/<ver>/...` 都返回它；指向不存在/空目录 → 警告 + 回退到
  `<root>\ext-<DefaultExt>`（`LWResolveExtDir`）；
- 相对路径先按 exe 目录展开、再按当前目录（服务方式启动时 cwd 常是 System32）；
- 回归：`tests/t_config.py`（19 项：三项生效、命令行覆盖、空/坏 ExtDir 回退、
  无节名、别名引号、exe 目录自动发现、默认 8090）。

### 3.3 写一个自己的 Web 程序

```pascal
program myapp;
uses Interfaces, Forms, lwapp, uMain;
begin
  Application.Initialize;
  TLWApp.Register(TMainForm);   // 类名去掉 T 即浏览器里的窗体名
  TLWApp.SetLogin(TLoginForm);  // 可选：启用登录框架
  TLWApp.Run;
end.
```

窗体单元唯一要改的一行：

```pascal
uses ..., lwform;
TMainForm = class(TLWForm)   // 原来是 class(TForm)
```

也可以用 IDE 向导（装 `src/design/lwdesign.lpk`，先跑 `tools\install_design.bat`）
或命令行 `tools\lwnew.exe --name=DemoApp --dir=C:\work\DemoApp --units=C:\lazarusWeb\src\core`。

### 3.3.1 同一个 exe 变成 Windows 服务

在向导第一框选「服务(daemon)模式」（或加 `--service`），模板会多给一层宿主：

| 文件 | 作用 |
|---|---|
| `uDaemon.pas` | `TDaemon` 子类 + worker 线程；`DoStart` 起线程调 `RunService`，`DoStop` 调 `StopService` 再 `WaitFor` |
| `uMapper.pas` | `TDaemonMapper` 子类，`StartType=stAuto`；**代码构造 `DaemonDefs`，无 `.lfm`**。服务名随工程名走：`lwnew --name=X` 生成 `XService`，IDE 向导在写盘前把占位名换成 Ctrl+S 时填的工程名（详见 `SERVICE_NAMING.md`） |
| `lazarusWeb.ini` | 固定名的配置（`port=` / `log=` / `client=`），与工程名解耦 |

`.lpr` 变成按参数分流：不带参数照旧走 `TLWApp.Run`（GUI 档仍显示面板），
`--install/--uninstall/--run` 交给 FPC 的 DaemonApp。
框架层只加了两个入口 —— `TLWApp.RunService`（置 `GServiceMode`，致命错误改抛
`ELWServiceAbort` 而不 `Halt`）与 `TLWApp.StopService`（唤醒阻塞的 accept），
`Run` 主体一字未改，现有 demo 行为不变。完整用法见 `WINDOWS_SERVICE.md`。

### 3.4 常用能力速查

| 需求 | 做法 |
|---|---|
| 同步模态 | `f.ShowModal = mrOk` 原样写，浏览器里真的等用户点 |
| 消息框/输入框 | `ShowMessage / MessageDlg / InputQuery / QuestionDlg / MessageBox` 原样写 |
| 文件上传 | 设计期摆 `TLWFileUpload`，写 `OnUpload(Sender, AFileName)` |
| 拍照 | 设计期摆 `TLWCamera`，`PreviewImage='imgPhoto'`（本地回显），写 `OnCapture(Sender, AFileName)`；手机走系统相机（http 可用），桌面在 HTTPS/localhost 下走页面内取景 |
| 文件下载 | `SendFile('报表.xlsx')` 或 `SendText(csv.Text, '清单.csv', True)` |
| 报表导出 | `TLWReport`：`SaveHTML / SaveCSV / SaveXLSX` 三出口 |
| 图表 | `TLWChart`：ctLine / ctBar / ctPie，运行时可切 |
| 自定义 AJAX | `TLWApp.AddAjax('items/price', handler)`，前端 `fetch('/lw/ajax/items/price')` |
| Toast | `Self.ShowToast('已保存')` |
| DB 网格分页 | `TLWDBGrid.PageSize := 20; ShowFilter := True; SummaryType := gsSum;` |
| 确认/切换渲染层 | 默认 Alpine.js（内置，无需配置）；可选 Ext 需自备 `ext-<版本>/` 并 `--client=ext`；启动横幅 `Client:` 行显示实际生效层 |
| 手机/窄窗口整页平面排布 | 写 `<root>\tpl\<窗体名>.html`，文件头 `lw-tpl-mode:flat`；控件仍按设计期绝对坐标，页面自身滚动；见 `MANUAL.md` 第二篇 16 |
| 窗口模式背景装饰 | 同一个 `<窗体名>.html`，文件头 `lw-tpl-mode:window`；窗体几何保持设计期，模板只作背景层；见 `MANUAL.md` 第二篇 16 |
| 从既有窗体快速得到模板骨架 | IDE Tools 菜单「生成 lazarusWeb 窗体模板（当前单元 LFM）」（lwdesign 设计期包），选模式后按 .lfm 生成一个 `<窗体名>.html`，按 16.2 精修；见 `MANUAL.md` 16.0 |

### 3.5 部署

- **自包含部署（默认 Alpine 层）**：exe + `src/client/alpine.min.js`（约 44KB）
  + `lw-alpine.js`（约 242KB）+ `lw-alpine.css`（约 64KB）；不需要 `ext-*` 目录。
  三个 Alpine 文件缺一不可（缺 js 会回退探测 Ext，缺 css 页面无样式），
  启动横幅会打印实际采用的 `Client`；
  **可选 Ext 层**：另加 `ext-x.x.x/`（约 75MB）+ `lw.js` + `lw.css`，
  并用 `--client=ext` 显式启用；
- **HTTPS**：FPC 自带 `TFPHttpServer.UseSSL`，业务 exe 或 lwhyper 加 `--ssl`
  即可在同端口终结 TLS（自签证书零配置，随包带 OpenSSL DLL，见坑 160）；
  也可由 nginx/Caddy 反代终结（现成配置 `deploy/nginx.conf`、`deploy/Caddyfile`，
  反代后加 `--trust-proxy`）；
  nginx 的 `/lw/ws` location 必须带 `Upgrade/Connection` 头，否则 WS 静默退化成长轮询；
- **集群**：两种方案。① **lwhyper 专用负载器**（对标 uniGUI Hyper Server）：
  `lwhyper.exe --port=8080 --workers=3 --exe=<业务exe>`，一个进程搞定
  worker 守护 + 反向代理 + sid 粘性 + WS 透传，HTTP 场景不再需要 nginx；
  ② nginx/Caddy 反代 + 粘性会话（nginx `ip_hash` / Caddy
  `lb_policy ip_hash`）。两者会话都在进程内存里（外置 Redis 未做）；
  健康检查打 `/lw/healthz`；实例宕机切换后浏览器收 410 自动新建会话回登录页；
  容量怎么估（单进程 ≈ 155 事件/秒，≈ N × 155 扩）、增量补丁协议与分阶段
  方案见 `docs/SCALE.md`；
- **服务化**：GUI 构建 + `--nogui`（无窗口）+ `--log=path`（日志落盘）。

### 3.6 回归测试

`python tests/t_xxx.py`（HTTP 级，先起服务；`run_with_server.py` 可自动起停）：

| 脚本 | 覆盖 |
|---|---|
| t_dbaware2 / t_closewin / t_multitab / cdp_multitab | DB 全家桶 / 关窗回登录 / 多页签 |
| t_dbaware(134) / t_db(35) | data-aware 回写落库 / SQLite 增删改查 |
| t_dialog(36) / t_files(28) / t_controls(26) | 对话框 / 上传下载 / 控件 |
| t_ws(8) / t_login(15) / t_attach(42) | WebSocket / 登录 / 附件 |

当前全量回归 **数百项全绿**（各阶段快照为 385~472 项，精确计数以最近一次
`tests/run_with_server.py` 全量跑的结果为准）。CDP 脚本驱动无头 Edge 做真实浏览器验证。

### 3.7 已知限制

- 模态超时 180 秒；同一会话同时只允许一个对话框；
- `TOpenDialog` 不能浏览服务端磁盘（只能上传）；`TSplitter` 支持拖动（回传位移→服务端 `SetSplitterPosition` 按 Align 重排邻居，坑 186）；
  `TUpDown/TProgressBar/TTrackBar` 浏览器端回写 `Position`；未适配控件浏览器端灰框占位；
- 高 DPI 按虚拟显示器 96 DPI 处理，125%/150% 设计的 lfm 自动缩回 96；
- 端口被强杀后可能残留孤儿 socket（`LISTENING PID 0`），换端口最省事；
- PDF 直出暂以浏览器"另存为 PDF"代替（fcl-pdf 的 ToUnicode 尚不稳）；
- 会话外置 Redis 未实现（集群靠粘性会话）。

### 3.8 踩坑实录

截至 2026-11-28 共 212 个坑全部沉淀在 `docs/NOTES.md`
（nogui 基础设施 → fpjson/编码 → SQLite/WAL → 设计期包 → multipart 安全 →
对话框钩子 → WebSocket → 多页签游标 → GUI 面板 → lfm 化改造 → 性能剖析 →
压测排障），是这份框架最贵的资产——每个坑都带根因分析和验证手段。
注意坑是按时间累积的：坑 23（TDBNavigator 的 RegisterClassAlias）已被坑 29/41
推翻、坑 66（TLabeledEdit 标签未修）已被坑 69 修复，以最新坑为准。
