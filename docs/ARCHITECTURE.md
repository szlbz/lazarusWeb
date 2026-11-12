# lazarusWeb 技术文档 —— 技术路径 · 实现方法 · 使用说明

> 版本 0.9.0 · 更新日期 2026-11-09
> 配套文档：`README.md`（快速上手）、`docs/COMPARISON_unigui.md`（与 uniGUI 对照）、
> `docs/CONTROL_MATRIX.md` / `docs/DB_AWARE_MATRIX.md`（控件支持度实测矩阵）、
> `docs/NOTES.md`（35 组踩坑实录）、`deploy/README.md`（HTTPS/反向代理/集群）。

---

## 一、技术路径

### 1.1 定位

lazarusWeb 是 **Lazarus 桌面程序的 Web 化运行时**：把真实运行的 LCL 控件树
直接序列化成 Ext JS 界面。业务程序只改一行基类（`TForm` → `TLWForm`），
事件、属性、`.lfm` 全部原样保留，就能以服务程序的形式跑在浏览器里。

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
   浏览器端 `lw.js` 只负责把 JSON 树渲染成 Ext JS 并做增量协调（reconcile）。

### 1.3 总体架构

```
浏览器 (Ext JS 7.0.0 / 7.5.1)          服务端 (FPC 3.3.1 + Lazarus, nogui)
┌────────────────────────────┐  WS/长轮询 ┌──────────────────────────────┐
│ lw.js (2350 行)             │  JSON     │ lwhttp   fphttpserver 多线程   │
│  Ext.window/panel/grid/... │ ←────────→ │ lwsession 每标签页一棵 LCL 树  │
│  reconcile 增量协调         │  HTTP      │ lwwriter  LCL树 → JSON        │
│  WS 只传事件请求/响应       │            │ lwdispatch 事件 → RTTI 调业务  │
│  长轮询游标统一下发推送      │            │ lwws     nogui 补丁(虚拟显示器)│
└────────────────────────────┘            └──────────────────────────────┘
```

服务端核心 24 个单元共约 1.4 万行，浏览器端 lw.js 2350 行。

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

- 属性按**白名单映射表**输出（不是全量 RTTI dump），映射关系见 `docs/MAPPING.md`；
- 事件能力用类引用表声明（Click/Change/DblClick/KeyPress…）；
- 增量输出：树带 `seq`，浏览器按 id diff，只更新变化的节点（reconcile）；
- 特殊控件有专门序列化分支：`TRadioGroup/TCheckGroup/TValueListEditor` 的
  Items/Rows 结构（坑 25）、`TTreeView` 的节点树、`TStringGrid` 的行列等。

### 2.3 lw.js —— 浏览器端渲染与协调（2350 行）

- 把 `kind` 映射到 Ext JS 组件（39 个可视控件有真实渲染分支）；
- **reconcile**：新树到达后按 id 对账，未变的 DOM/Ext 实例不动（保留输入焦点）；
- 事件捕获：Ext 组件事件带上 `id/ev/val`（连着 WS 时走 WS 帧，否则 `POST /lw/api/event`）；
- **长轮询 `/lw/api/poll` 是唯一推送通道**：推送统一入会话队列带序号（模态/消息框/遮罩/下载指令），各页签带 `after` 游标各取各的；
- **WebSocket `/lw/ws` 只传事件请求/响应**：连上后事件走 WS 帧（长轮询不停），断了自动退回 HTTP `/lw/api/event`；
- 跨页签：sid 存 localStorage，新标签页 `attach` 到已有会话，按游标各取各的推送。

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
| `GET /ext/<版本>/...` | Ext JS 静态资源（任意版本目录，见下） |
| `GET /lw/ws` | WebSocket 升级（fphttpserver trunk，坑 26） |

静态资源/根目录定位有多级回退（坑 30）：当前工作目录 → exe 向上 5 层 →
`--root=` 显式指定。`--trust-proxy` 时客户端 IP 取 `X-Forwarded-For`。

**Ext 目录解析与版本无关**（坑 40）：URL 里的版本段只是一个"目录名"，不再
和 7.0.0 / 7.5.1 这些具体版本号绑定。

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
  `ShowFilter` 过滤条、`SummaryType(gsSum/gsAvg/gsCount)` 汇总条；
- `TDBNavigator` 在 nogui 下构造即崩（位图图元链，坑 23）→ `LWNewNavigator`
  工厂出安全子类，lfm 靠 `RegisterClassAlias` 自动落子类，用户代码写原生类型；
- 11 种 data-aware 控件全部实测（`docs/DB_AWARE_MATRIX.md`），三条硬规则见
  README「数据库应用」节（SQLite 用 VARCHAR、必须显式 Commit、编辑态不下发网格行）。

### 2.11 周边能力

| 单元 | 能力 |
|---|---|
| `lwchart.pas` | `TLWChart` ctLine/ctBar/ctPie，ext-7.5.1 charts 包渲染，运行时切类型 |
| `lwreport.pas` | 报表引擎：可打印 HTML（A4/@media print/thead 逐页重复）+ CSV（BOM+CRLF）+ **真 XLSX**（zipper 打包 OOXML，零第三方依赖） |
| `lwajax.pas` | `TLWApp.AddAjax(name, handler)` 自定义端点；上下文给 Param/Header/JSONBody/Session；未注册名回 404 并自省列出全部端点 |
| `lwwebsocket.pas` | `/lw/ws` 升级（RFC6455）：**只传事件请求/响应**；推送一律由长轮询游标下发（`OnPushCommand` WS 直推保留但默认不启用） |
| `lwhyper.pas` | 专用负载均衡器（对标 uniGUI Hyper Server）：单进程拉起 N 个 worker（同 exe 多开）、崩溃自动重启、HTTP 反向代理 + sid 会话粘性、WebSocket TCP 级透传、healthz 巡检；`tools/lwhyper.exe` 是入口，自身端点 `/lw/healthz`（汇总）与 `/lw/hyper/status`（worker 明细） |
| `lwpanel.pas` + `lwrlog.pas` | GUI 服务端面板（对标 uniGUI 独立服务器窗口）与统一日志（见下） |
| `lwconfig.pas` | 服务端配置文件（INI）：`Port` / `Theme` / `ExtDir` 三项，命令行优先级最高（见 3.2.1） |
| `lwnewproject.pas` + `src/design/lwdesign.lpk` | IDE 向导（New Project 两个模板：默认 widgetset 与 nogui，差别只在 .lpi 的 `LCLWidgetType`）/ New Form / 组件面板，与 `tools/lwnew.exe` 命令行共用同一模板；lwdesign 把全部自定义控件注册进 IDE，带它们的窗体才能在设计器里打开 |
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

---

## 三、使用说明

### 3.1 环境与构建

- FPC 3.3.1 + Lazarus（本机 `c:\111\fpc`、`c:\111\lazarus`）；
- Ext JS 7.0.0 / 7.5.1（仓库根目录已带）。

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

```
--config=path         指定配置文件（缺省自动找 <exe名>.ini / lazarusWeb.ini）
--port=8090           监听端口
--root=C:\lazarusWeb  项目根目录（含 ext-7.x.x）
--ext=7.5.1           默认 Ext 版本（URL ?ext= 可临时切换）
--extdir=目录         ext-js 目录（配置项 ExtDir 的等价物）
--theme=crisp         缺省主题（classic/crisp/gray/material/neptune/graphite）
--trust-proxy         反代后面取 X-Forwarded-For 真实 IP
--ajax-cors           /lw/ajax/* 允许跨域（第三方页面集成）
--verbose             打印每个请求与异常栈
--nogui               GUI 构建下也不弹面板（服务化部署）
--log=path            日志追加写文件
--help                帮助
```

### 3.2.1 配置文件（`lwconfig.pas`）

`TLWApp.Run` 在解析命令行**之前**先读 INI，所以顺序是
「内置默认值 → 配置文件 → 命令行」，命令行永远赢：

```ini
[lazarusWeb]
Port=8090
Theme=crisp
ExtDir=ext-7.5.1
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

### 3.4 常用能力速查

| 需求 | 做法 |
|---|---|
| 同步模态 | `f.ShowModal = mrOk` 原样写，浏览器里真的等用户点 |
| 消息框/输入框 | `ShowMessage / MessageDlg / InputQuery / QuestionDlg / MessageBox` 原样写 |
| 文件上传 | 设计期摆 `TLWFileUpload`，写 `OnUpload(Sender, AFileName)` |
| 文件下载 | `SendFile('报表.xlsx')` 或 `SendText(csv.Text, '清单.csv', True)` |
| 报表导出 | `TLWReport`：`SaveHTML / SaveCSV / SaveXLSX` 三出口 |
| 图表 | `TLWChart`：ctLine / ctBar / ctPie，运行时可切 |
| 自定义 AJAX | `TLWApp.AddAjax('items/price', handler)`，前端 `fetch('/lw/ajax/items/price')` |
| Toast | `Self.ShowToast('已保存')` |
| DB 网格分页 | `TLWDBGrid.PageSize := 20; ShowFilter := True; SummaryType := gsSum;` |

### 3.5 部署

- **自包含部署**：exe + `ext-7.5.1/`（约 75MB）+ `src/client/lw.js`(86KB) + `lw.css`。
  缺 lw.js 会白屏（Ext 加载完等不到渲染脚本），启动横幅会警告；
- **HTTPS**：fphttpserver 无 TLS，由 nginx/Caddy 反代终结
  （现成配置 `deploy/nginx.conf`、`deploy/Caddyfile`）。反代后加 `--trust-proxy`；
  nginx 的 `/lw/ws` location 必须带 `Upgrade/Connection` 头，否则 WS 静默退化成长轮询；
- **集群**：两种方案。① **lwhyper 专用负载器**（对标 uniGUI Hyper Server）：
  `lwhyper.exe --port=8080 --workers=3 --exe=<业务exe>`，一个进程搞定
  worker 守护 + 反向代理 + sid 粘性 + WS 透传，HTTP 场景不再需要 nginx；
  ② nginx/Caddy 反代 + 粘性会话（nginx `ip_hash` / Caddy
  `lb_policy ip_hash`）。两者会话都在进程内存里（外置 Redis 未做）；
  健康检查打 `/lw/healthz`；实例宕机切换后浏览器收 410 自动新建会话回登录页；
- **服务化**：GUI 构建 + `--nogui`（无窗口）+ `--log=path`（日志落盘）。

### 3.6 回归测试

`python tests/t_xxx.py`（HTTP 级，先起服务；`run_with_server.py` 可自动起停）：

| 脚本 | 覆盖 |
|---|---|
| t_dbaware2 / t_closewin / t_multitab / cdp_multitab | DB 全家桶 / 关窗回登录 / 多页签 |
| t_dbaware(134) / t_db(35) | data-aware 回写落库 / SQLite 增删改查 |
| t_dialog(36) / t_files(28) / t_controls(26) | 对话框 / 上传下载 / 控件 |
| t_ws(8) / t_login(15) / t_attach(42) | WebSocket / 登录 / 附件 |

当前全量 **385 项全绿**。CDP 脚本驱动无头 Edge 做真实浏览器验证。

### 3.7 已知限制

- 模态超时 180 秒；同一会话同时只允许一个对话框；
- `TOpenDialog` 不能浏览服务端磁盘（只能上传）；`TSplitter` 不支持拖动；
  `TUpDown/TProgressBar/TTrackBar` 单向；未适配控件浏览器端灰框占位；
- 高 DPI 按虚拟显示器 96 DPI 处理，125%/150% 设计的 lfm 自动缩回 96；
- 端口被强杀后可能残留孤儿 socket（`LISTENING PID 0`），换端口最省事；
- PDF 直出暂以浏览器"另存为 PDF"代替（fcl-pdf 的 ToUnicode 尚不稳）；
- 会话外置 Redis 未实现（集群靠粘性会话）。

### 3.8 踩坑实录

35 组坑全部沉淀在 `docs/NOTES.md`（nogui 基础设施 → fpjson/编码 → SQLite/WAL →
设计期包 → multipart 安全 → 对话框钩子 → WebSocket → 多页签游标 → GUI 面板），
是这份框架最贵的资产——每个坑都带根因分析和验证手段。
