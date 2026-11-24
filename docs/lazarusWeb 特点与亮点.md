# lazarusWeb 特点与亮点

> 版本 0.9.6 · 2026-11-18
>
> **一句话**：把 Lazarus/FPC 桌面程序搬到浏览器，只改一行基类；控件还是真的
> LCL 控件，业务逻辑始终留在服务端，前端零构建、零外网依赖。
>
> 本文回答三件事：**它是什么、强在哪、边界在哪**。机制细节见
> `ARCHITECTURE.md` / `HOW_IT_WORKS.md`，操作用法见 `MANUAL.md`，与 uniGUI
> 的逐项对照见 `COMPARISON_unigui.md`。
>
> 口径说明：带"实测"的数字来自本机压测/真浏览器回归；控件与 DB 矩阵是
> 自动生成的快照（会标日期）；行数、脚本数等易变数字标"截至 2026-11-18"。

---

## 0. 一眼看懂

原桌面程序（表单、事件、`.lfm` 全都不动）：

```pascal
TMainForm = class(TLWForm)   // 原来是 class(TForm)
```

改编译目标：

```
lazbuild -B --ws=nogui MyApp.lpi
```

浏览器打开 `http://127.0.0.1:8090/` —— 就是你的程序。

**它不是"把 Pascal 编译成 JS"，也不是"用前端框架重写一遍"。** 它是给 LCL
换了一块"没有屏幕的显卡"（nogui widgetset），让真实的控件树在服务端跑，
再把控件树序列化成 JSON，由浏览器渲染成对应的 DOM。

---

## 1. 三条路线的取舍

| 路线 | 代价 | 结果 |
|---|---|---|
| Vue/React 重写前端 + REST 后端 | 业务逻辑重写一遍、桌面代码归零、两份状态要同步 | 前端体验最好，存量资产报废 |
| uniGUI 类商业框架（Delphi） | 商业授权；控件是"影子类"而非真 `TForm`，设计器能力受限；绑定 Delphi 生态 | 成熟，但把项目锁进另一个商业栈 |
| **真 LCL 控件树 + 服务端权威渲染（本方案）** | 要伺候 LCL 对"有屏幕"的每个隐含假设（成本在框架侧，不在业务侧） | **Pascal 业务 100% 复用；MIT；Windows/Linux/macOS 同一份源码** |

这套方案的所有收益（业务零改动、设计器照常、RTTI 天然可用）和所有麻烦
（假 GDI、DPI、nogui 崩溃点）都来自同一个决定：**用真的 LCL 控件，而不是
影子控件**。框架已经把这些麻烦消化在 `lwws.pas` 等 32 个核心单元里
（23,037 行，截至 2026-11-18）。

---

## 2. 特点：十一个能落地的能力

### 2.1 迁移成本：一行基类，外加一条自动改造流水线

- 业务窗体把 `class(TForm)` 改成 `class(TLWForm)`，`.lfm`、事件方法、属性、
  锚点、`TabOrder` 全部原样；
- 存量工程可以用 `tools/lwconvert.exe` **自动改造**：换基类、重写 `.lpr`
  启动代码、重新生成 `.lpi`（nogui 目标）、输出逐控件的支持度报告；
  端到端回归 `tests/t_convert.py`；
- 新工程有 IDE 向导：装上设计期包 `lwdesign` 后，**File → New → Project**
  多出 `lazarusWeb` 一个模板，选中后连弹三框：先选应用模式
  （普通应用 / 服务(daemon) 模式；后者额外生成 `uDaemon.pas` / `uMapper.pas` /
  `lazarusWeb.ini`，同一个 exe 既能前台跑也能 `--install` 注册成 Windows 服务，
  见 `WINDOWS_SERVICE.md`），再选工程类型
  （`lazarusWeb project` GUI 调试档 / `lazarusWeb project(nogui)` 部署档），
  最后选工程模板（常规 / 插件；插件模式生成**多进程插件框架**：宿主 exe
  （侧栏菜单 `TLWSideMenu` + `TPageControl`）+ `common\upluginproc.pas` +
  `plugins\hello\` 示例插件工程 + `build-all.bat` / `stop-all.bat` 及 Linux 版
  `build-all.sh` / `stop-all.sh`（清单 `exe=xxx.exe` 自动兼容无后缀产物）；插件 exe 带
  启动守卫（令牌 + 父进程校验），单独双击只提示「请从主程序进入」，
  插件是独立进程、可热更新，与 `demos/pluginsDemo` 同一套机制）。
  插件模式现在**默认生成用户权限与跨进程身份**：宿主 `ulogin.pas` 登录窗
  （默认带图形验证码）+ `common\upluginauth.pas`（清单 `roles=`、
  菜单过滤、`lwroute` 路由鉴权无权限 403、身份签发）+ 插件侧
  `common\upluginidentity.pas` 验签显示"当前用户"；框架侧的回调未注册时
  行为不变，不想用登录就删宿主 `.lpr` 的 `SetLogin` / `LWAuthRegister` 两行。
  直连插件端口没有签名头，身份显示"未识别"；
  落盘时机与 Lazarus 自带模板一致（先虚拟工程，Ctrl+S 才写盘，附加文件在落盘前
  内容就已完整正确），落盘即带 `build.bat/build.sh/favicon.ico` 与 `lw/` 前端资源；
- 顺手也给：**New Form**（`TLWForm`）、组件面板 `lazarusWeb` 页、
  Tools 菜单的"按 .lfm 一键生成桌面+移动模板骨架"。

> 为什么这条最重要：Web 化的真实成本从来不是"能不能跑"，而是"要不要重写"。
> 这里重写量是 1 行（加一个 `uses`）。

### 2.2 真控件、真设计器：设计期看到的就是浏览器里看到的

`TLWForm` 是**真正的 `TForm` 后代**，不是代理类、不是包装器。所以在 IDE 里：

- 拖上去的 `TButton`/`TEdit` 就是 LCL 自己的控件，属性面板、事件页、
  对齐工具、锚点编辑全部照常；
- `.lfm` 原样加载，窗体设计器里的布局**就是**浏览器里的布局（同一坐标系）。

对比之下，影子控件体系只能提供"看起来像设计器"的东西，第三方控件、
自定义控件、运行时动态创建的控件都会遇到墙。这里没有这堵墙——**任何
LCL 控件放上去，服务端都是真的在跑它**。

### 2.3 服务端权威：业务代码和状态都不进浏览器

浏览器只拿到两样东西：**JSON 控件树快照**和**事件三元组 `{id, ev, val}`**。
控件实例、业务状态、SQL、权限判断、会话数据全在服务端内存里。

由此带来三个实际收益：

1. **源码与规则不下发**。前端看不到你的 Pascal、看不到 SQL、看不到业务分支
   ——这是"重写前端"路线的天然短板，也是这类方案在政企/内网场景的硬需求；
2. **没有"两份状态"**。不存在前端 store 和后端模型对不上的问题，
   也不需要设计 REST 接口；
3. **多端一致**。桌面、手机、以及显式共享的多个页签，看到的是同一棵树的镜像，
   不靠前后端同步协议。

代价也要说清楚：**每次交互一次服务端往返**（延迟与吞吐见 2.8），
浏览器端不能离线工作。

### 2.4 桌面语义是完整的，不是"能显示就算"

这是很多 Web 化方案真正翻车的地方，而这里逐条对上了：

| 桌面语义 | 这里的做法 |
|---|---|
| 同步模态 `if f.ShowModal = mrOk then` | 推指令后**挂起请求线程**（`TEvent.WaitFor`），浏览器关窗才继续，业务代码原样 |
| `ShowMessage` / `MessageDlg` / `InputQuery` / `QuestionDlg` / `Application.MessageBox` | 运行时改道到浏览器模态框，**一行代码不改**（`lwdlg`，挂在 `lwcore`） |
| `TOpenDialog` / `TSaveDialog` | 浏览器选框 → 文件上传到会话临时目录，`FileName` 给服务端路径，`TFileStream` 直接可读 |
| 加速键（Caption 里的 `&`） | 按 LCL 规则渲染成带下划线的字母，`&&` 是字面 `&` |
| `TStatusBar` 分格 / `TLWDBGrid` 多级表头 | 照 `.lfm` 的分格宽度、对齐、表头分组画 |
| 高 DPI 设计（`DesignTimePPI=120/144`） | 创建时按 96 DPI 归一（几何 + 字体一起），与桌面观感一致 |
| `TLabeledEdit` 的标签贴合 | 服务端摆位 + 浏览器按真实渲染矩形精修，间距等于 `LabelSpacing` |

### 2.5 交付形态极简：默认 Alpine.js，零构建、零外网

- 默认渲染层是 `lw-alpine.js` + `alpine.min.js` + `lw-alpine.css`，
  **三个静态文件随包内置**（45KB + 215KB + 59KB），不走 CDN、不需要
  node/npm/打包器；
- Ext JS 是**可选**渲染层（`--client=ext` + 自备 `ext-<版本>/`），
  两层共用同一套 JSON 协议、同一套事件与推送通道——换渲染层不改业务；
- 部署就是：exe + 几个静态文件。运行时不依赖任何框架安装包
  （可选依赖只有 `sqlite3.dll` 与开 HTTPS 用的 OpenSSL DLL）；
- **7 套配色 + 跟随系统**：浅色系 `light`/`paper`/`mint`/`contrast`，
  深色系 `dark`/`midnight`/`forest`，标题栏按钮可切、`localStorage` 记忆、
  设计期还能用窗体属性 `LWTheme` 设默认值；
- 站点图标、`favicon.ico`、HTTPS 自签证书、INI 配置都是开箱即用。

### 2.6 全栈能力开箱，不用自己拼轮子

| 能力 | 现成的东西 |
|---|---|
| 上传 | `TLWFileUpload`：进度百分比、`Filter`/`Multiple`/`MaxSizeKB`、文件名安全化、落 `%TEMP%\lw_uploads\<会话>\<控件>\`（可用 `TargetFolder` 改） |
| 下载 | `SendFile` / `SendText`（可带 BOM），URL 里**不暴露服务端路径**（一次性令牌，30 分钟或首次取用即废） |
| 拍照 | `TLWCamera`：手机直接唤起**系统相机**（局域网 http 就能用）；桌面走 `getUserMedia` 页面内取景；拍完自动回传并本地预览 |
| 数据库 | `TLWDBGrid`（分页/过滤/汇总/多级表头/单元格编辑）+ `TDBEdit`/`TDBMemo`/`TDBCheckBox`/`TDBListBox`/`TDBRadioGroup`/`TDBLookup*`/`TDBText`/`TDBImage`/`TLWDBNavigator` |
| 报表 | `lwreport`：可打印 HTML（A4 `@page`、`thead` 逐页重复、合计行）、CSV（BOM）、XLSX（真 OOXML，自带 zipper，不依赖第三方库） |
| 图表 | `TLWChart` → 内置 SVG 渲染（柱/线/饼），换主题自动变色 |
| 登录与权限 | `TLWLoginForm`（可设计、`RequireAuth`、未认证事件全拒）+ `TLWCaptcha`（自绘点阵 PNG，零字体依赖）+ `TLWSideMenu`（设计期就是 IDE 原生菜单编辑器） |
| 交互反馈 | Toast、全局 busy 遮罩、提示气泡、`LW.theme`/`LW.layout`/`LW.stats`/`LW.resync` 客户端 API |
| 第三方集成 | `TLWApp.AddAjax('items/price', handler)` 注册自定义端点，第三方 JS 直接 `fetch('/lw/ajax/...')`，跨域加 `--ajax-cors` |
| 富内容 | `TLWHTMLFrame`（HTML: TStrings）、`TLWPDFFrame`（iframe + 查看令牌） |

### 2.7 移动端：业务零改动，模板可选

- 判定全在前端：视口 ≤834px 进移动、≥1100px 出（中间回滞防抖动），
  触屏能力单独判定；服务端从头到尾不知道设备是什么；
- **不配模板也能用**：桌面端保持设计期绝对布局，移动端进入"平移模式"
  （设计尺寸原样、不缩字号、整页可滚动）；
- **配模板 = 背景装饰层**：桌面 `<root>\tpl\<窗体名>.html`（窗口/平面两模式
  共用这一个文件）、移动 `<窗体名>.m.html`，文件头 `lw-tpl-mode:window|flat`
  决定浮窗或整页平面模式（flat 优先）。模板**不重排控件**，控件始终按
  `.lfm` 的 `Left/Top` 绝对定位，事件、Alpine 状态、增量补丁不变；改模板
  刷新即生效（不用重编）；移动端只读 `.m.html`，无模板则直接用 LCL 布局；
- IDE Tools 菜单可按 `.lfm` **一键生成**：先选窗口/平面，再写桌面 `.html`
  与移动 `.m.html` 两份（含模式标记、控件坐标清单与自检报告）。

### 2.8 性能是量出来的，不是"理论上很快"

| 事实 | 数字（Ryzen 5 7520U / 4C8T / 15.3GB，gallery demo） |
|---|---|
| 一次事件的全量载荷 | 73~78KB（157 个节点） |
| 开增量补丁（`--patch=1`）后 | **2~4KB**（1/30~1/70） |
| 单事件服务端成本 | 6.3ms → **4.3ms** |
| 单进程事件吞吐 | 57.9 → **150~163 事件/秒** |
| 空闲会话 | **200+ 个**不崩（约 1MB/会话、2 线程/会话） |
| 横向扩展 | N 个 worker ≈ N × 150 事件/秒 |

更有价值的是**优化过程本身有记录**（`SCALE.md`）：框架做过"节点签名 + 节点
缓存"，实测判负（签名 ≈ 重建的 60%，命中省不出钱）就删掉；剖析发现真瓶颈
不是"读属性"，而是 `TLWDBGrid` 给不下发的行白算单元格文本——修掉它比加缓存
收益大得多。**敢写"试过、没用、已删除"的文档，比只报喜的数字可信。**

### 2.9 集群与运维：自带"Hyper Server"那一层

- **`lwhyper` 专用负载器**：一个进程拉起 N 个 worker（同一个 exe 多开）、
  崩溃 2 秒探针自动重启、对外单端口反向代理、按 sid 做**应用层粘性**、
  WebSocket TCP 级透传、自带 `/lw/healthz` 与 `/lw/hyper/status`；
- **热更新（零停机换版）**：把新 exe 拷成 `<业务exe>.new`，约 4 秒判定后
  换壳并**逐个**滚动重启（任一时刻至少 N-1 个在服务）；新版本起不来自动
  回滚并留存 `.bad-<时间>`；worker 走优雅退出（`POST /lw/shutdown` + 令牌），
  不是强杀；
- **HTTPS 两条路**：`--ssl` 直接开（FPC 自带，证书不给就自签），或
  nginx/Caddy 前置终结（`deploy/` 里有现成配置，含 `Upgrade` 头与 `ip_hash`）；
- **GUI 服务端面板**：菜单、滚动日志、在线会话数/运行时长、系统托盘常驻
  （点 X 只是隐藏），对标 uniGUI 独立服务器窗口；控制台版给 CI/容器用；
- **自己就是 Windows 服务**：`TLWApp.RunService/StopService` + 可选宿主层
  （`uDaemon.pas`/`uMapper.pas`），`exe --install` 注册、`sc.exe start` 启停、
  `StartType=stAuto` 开机自启、`sc.exe stop` 优雅收尾，**不需要 nssm 之类的包装器**；
  同一个 exe 不带参数时仍是原来的前台程序（新建工程向导第一框勾一下就有，
  详见 `WINDOWS_SERVICE.md`）；
- 反向代理后面加 `--trust-proxy`，日志里才是真实客户端 IP。

### 2.10 跨平台，且能落到国产化环境

- 同一份源码跑 Windows / Linux / macOS：核心单元不含 `Windows`、`winsock`、
  `ShellExecute` 之类平台专属单元，差异用 `{$IFDEF MSWINDOWS/LCLGTK2/LCLQT5}`
  隔离且都有非 Windows 分支；
- 已实测交叉编译：**x86_64-linux**、**mips64el-linux（龙芯 3A 实跑）**，
  仓库里还有 aarch64 产物；
- 同一份源码同时支持 **FPC 3.2.2 与 3.3.1**：新能力用能力探测 + 双分支包着，
  3.2.2 下走等价垫片（自实现 `LWCanRead`、自带状态码表等），行为一致。

### 2.11 工程可信度：能查、能跑、能复现

| 维度 | 现状（截至 2026-11-18） |
|---|---|
| 控件支持度 | `CONTROL_MATRIX.md` 由 `tools/lwaudit` **自动生成**：66 个可视控件**真的创建 + 挂窗体 + 序列化一次**，快照 49 ok（74.2%）；其后又把 6 个高频 placeholder 补成 ok（清单见 README 路线图） |
| DB 控件 | `DB_AWARE_MATRIX.md` 由 `tools/lwdbcheck` 生成：12 个 data-aware 控件挂真 SQLite 数据集，逐项验绑定/显示/同步/改值/序列化/前端分支（明细 9 完全 + 3 只读；文件顶部那行汇总还是 `TDBNavigator` 修复前的旧数） |
| 自动化测试 | `tests/` 87 个 Python 脚本（含夹具/工具），其中 **23 个 HTTP 级回归**（controls/db/dialog/files/login/multitab/ws/hyper_ws/patch_e2e…，数百项断言）+ **55 个 CDP 真浏览器探针**（连无头 Edge，查首屏/截图/控制台错误） |
| 文档 | `README` + `docs/*.md` 共 **约 1.3 万行**；`NOTES.md` 是追加式实录（编号至坑 194，实记 153 条，有跳号；旧结论被推翻处带删除线和指向） |
| 示例 | 20 个 demo：hello、grid、multi、db、dbaware、files、dialogs、login、gallery（13 页 60+ 控件，含报表页）、mobile_demo… |
| 授权 | 本项目 MIT；Alpine.js（MIT）随包内置并附许可声明；**Ext JS 不随附**（授权合规由使用方自负，README 写得很直白） |

> 一段值得单独提的话：`NOTES.md` 里记的不是"我做了什么"，而是"哪里错了、
> 为什么错、怎么发现的、教训是什么"。坑 172 那种"我上一版修法把保存搞坏
> 了"的记录也照样留着——**这类文档才是长期可维护的信号**。

---

## 3. 亮点：七个"做对了的决定"

### 3.1 用 nogui widgetset 当"虚拟显示器"，而不是重写控件

省下了重写几百个控件的工作量，代价是要补给 LCL 一套"假 GDI"：
`CreateCompatibleDC` 返回常量、`GetTextExtentPoint32` 按 `字符数 × 字高 × 0.55`
估算、虚拟显示器固定 96 DPI。

**代价要诚实说**：这套估算是按西文平均字宽取的系数，中文/全角字符实际宽度
约为字高的 1.0 倍，所以**含中文的 `AutoSize` 标签，服务端算出的宽度可能偏窄**。
框架因此坚持"布局以设计期坐标为准确，不靠服务端重排"——这也是为什么
不能把网页布局交给服务端算。

### 3.2 白名单序列化，不做全量 RTTI dump

`lwwriter` 按映射表输出属性，而不是把控件所有 published 属性反射一遍。
好处：载荷小且稳定、前端只认已知字段、不会把内部实现细节泄给浏览器；
代价：新控件/新属性要显式加映射（`MAPPING.md` 就是这张表）。

### 3.3 按 id 对账（reconcile），而不是重绘

新树到达后按节点 id diff，未变的 DOM 实例原地不动 —— 输入焦点、光标位置、
滚动条位置都不被打断（这是"整页重绘"方案最容易砸掉的东西）。增量补丁
（`--patch=1`）把这个思路再往前推一步：服务端只回变化的 ops。

### 3.4 事件走 WebSocket，推送走长轮询游标

职责分离得很干净：

- **事件**（点击/输入）要低延迟双向 → 连上 WS 就走 WS 帧，断了自动退回
  `POST /lw/api/event`；
- **推送**（模态/消息框/遮罩/下载指令）要"多页签各取各的" → 统一进会话
  队列带序号，各页签用 `/lw/api/poll?after=N` 拿自己的游标，互不消费。

### 3.5 模板 = 背景层，不是字符串重渲染

窗口/平面模板只是挂在客户区最前的装饰层（`pointer-events:none`），控件
DOM 既不被搬进占位符也不重建，事件绑定、Alpine 状态、增量补丁机制
**完全不受影响**。这也是模板能"配上就生效、不配就回退"的前提。

### 3.6 会话生命周期按"关页签即退出"设计

默认 sid 放 `sessionStorage`：刷新不掉登录，**关标签页就必须重新登录**——
和桌面程序"关窗口 = 退出"同一个心智。

细节很讲究：浏览器"恢复上次打开的网页"会把 sessionStorage 连同 sid 一起还原，
所以客户端在 `pagehide` 留一枚墓碑，用 `performance.timeOrigin` 减去墓碑时刻
判断"这是刷新还是关过窗口"（阈值 3 秒）。要"记住我"再显式开
`localStorage['lw.persist'] = '1'`。

### 3.7 双 FPC 版本单源，而不是两个分支

3.3.1 的新能力（`RegisterUpdateHandler`/`ThreadMode`/`ConnectionHandler`…）
用 `{$IF FPC_FULLVERSION >= 30301}` 包着，3.2.2 下走等价垫片。合并不是
"拷一份改改"，而是做了**符号级 + 字面量级 + 条件展开 + 编译 + 回归**五层审计
（`MERGE_AUDIT.md` / `MERGE_AUDIT_FULL.md`）。

---

## 4. 数字速览

| 项 | 数字 | 口径 |
|---|---|---|
| 服务端核心 | 32 个单元 / 23,037 行 | 截至 2026-11-18，`src/core` |
| 默认渲染层 | `lw-alpine.js` 215KB + `lw-alpine.css` 59KB + `alpine.min.js` 45KB | 文件大小 |
| 可选 Ext 层 | `lw.js` 154KB + `lw.css` 9KB + 自备 `ext-<版本>/` | 文件大小 |
| 可视控件审计 | 66 个，49 ok（74.2%） | 快照 2026-11-09，其后补 6 个 |
| DB 感知控件 | 12 个：9 完全可用 + 3 只读 | 明细快照 2026-11-08 |
| 事件吞吐 | 150~163 事件/秒/进程（`--patch=1`） | 本机实测 |
| 事件载荷 | 73~78KB → 2~4KB（补丁） | 本机实测 |
| 空闲会话 | 200+（约 1MB/会话） | 本机实测 |
| 移动断点 | ≤834px 进 / ≥1100px 出（回滞） | 设计参数 |
| 模态超时 | 180 秒 | 常量 `LW_MODAL_TIMEOUT_MS` |
| 配色 | 7 套 + 跟随系统 | Alpine 层 |
| 测试脚本 | 87 个（其中 23 HTTP 级 + 55 CDP 浏览器探针） | 截至 2026-11-18 |
| 文档 | 约 1.3 万行；`NOTES.md` 编号至坑 194（实记 153 条） | 复核 2026-11-20 |
| 示例 | 20 个 demo（含 mobile_demo） | 复核 2026-11-20 |

---

## 5. 与 uniGUI 的对照（精选）

完整逐项对照见 `COMPARISON_unigui.md`（含 🟡/❌ 缺口）。

| 维度 | uniGUI | lazarusWeb |
|---|---|---|
| 控件体系 | 影子控件（非真 `TForm`） | **真 LCL 控件**，`TForm` 直接换基类 |
| 迁移成本 | 需改用 uni 控件族 | 改 1 行基类；存量工程可 `lwconvert` 自动改造 |
| 前端交付 | 依赖 Ext JS（商业授权） | **默认 Alpine.js 内置**，零外网；Ext 可选 |
| 授权 | 商业授权 | **MIT**（Alpine MIT 内置；Ext 不随附） |
| 同步模态 / 对话框改道 | 有 | 有，且 `TOpenDialog`/`TSaveDialog` 也接上了 |
| 报表/导出 | uniPrint / uniGridExcelExport | `lwreport`：可打印 HTML / CSV / XLSX（真 OOXML） |
| 集群 | 商业版 Hyper Server | **`lwhyper` 开源等价物** + 热更新 + 健康探针 |
| 跨页签共享 | 无 | **有**（sid 复用 + 游标推送 + 对话框定向，可选开启） |
| 移动端 | 独立 `uniMobile` 控件族 | 前端自适应 + 窗体模板（无独立控件族） |
| 跨平台 | Windows 为主 | **Windows / Linux / macOS，含龙芯 mips64el 实测** |
| 多语言 RTL | 支持 | 未做 |

**结论**：uniGUI 更成熟、控件更全、有商业支持；lazarusWeb 的优势在
**开源、真控件、跨平台、零前端构建**，以及"业务代码一行不改"的迁移路径。

---

## 6. 边界：什么场景不要用它

这部分和亮点同样重要——**选型的失败大多源于"用错了地方"，而不是"东西不好"**。

- **不是高并发互联网前端**。舒适区是每进程 10~20 个活跃用户（40 上限），
  要更多就多开 worker 横向扩。面向公众的秒杀/信息流首页，请用常规前后端分离；
- **不适合毫秒级交互**。每次交互一次服务端往返（4~6ms 计算 + 网络），
  画板、游戏、实时协同编辑这类不合适；
- **会话在进程内存里**。进程挂掉，该 worker 上的会话一起丢（外置 Redis 未做），
  靠 lwhyper 粘性 + `410` 自动重建兜底；
- **未做的能力**：RTL/多语言；移动端没有独立控件族。（`TSplitter` 已支持拖动，坑 186）
  `TPopupMenu` 右键上下文菜单、仪表盘 gauge、颜色选择器、
  `TProgressBar`/`TTrackBar` 回写均已支持（见 2.4 / 2.6）；
- **nogui 的文本度量是估算**。极端依赖 `AutoSize` 精排的界面要复核，
  中文标签可能偏窄；
- **一个会话同时只能有一个模态框**，模态期间同会话其它请求排队
  （与桌面模态语义一致）；
- **前端仍是自研 JS**（Alpine 层 215KB）。对业务开发者是"零 JS"，
  但"框架零 JS"这句话不成立，别对外这么说。

---

## 7. 五分钟自证

不用听介绍，跑几个现成的就能判断合不合用：

```bat
:: 1) 编译全部 demo（--ws=nogui）
build.bat

:: 2) 全功能画廊：13 页 60+ 控件，标准控件/网格（保存/调用 + 未保存关闭提醒）/图表/上传/对话框/DB 分页/报表都在
demos\gallery\gallery_nogui-x86_64-win64.exe --port=8090

:: 3) DB 感知全家桶 + 报表中心（87 个对象一页摆开）
demos\dbaware\dbaware.exe --port=8110

:: 4) 手机：用手机浏览器打开横幅里 LAN: 那一行给的地址（记得带端口）
demos\mobile_demo\mobile_demo.exe --port=8106

:: 5) 集群与热更新
tools\lwhyper.exe --port=8080 --workers=2 --exe=demos\dbaware\dbaware.exe
```

自动化回归（自动起停服务）：

```bat
python tests\run_with_server.py demos\gallery\gallery_nogui-x86_64-win64.exe tests\t_gallery.py
python tests\run_with_server.py demos\dialogs\dlgdemo.exe tests\t_dialog.py
```

---

## 8. 延伸阅读

| 想了解 | 读 |
|---|---|
| 架构与模块职责 | `ARCHITECTURE.md` |
| 一次点击的完整回路、为什么不能全量 RTTI dump | `HOW_IT_WORKS.md` |
| 上手与开发指南 | `MANUAL.md`（使用篇 + 开发篇） |
| 控件/属性映射细节 | `MAPPING.md` + `CONTROL_MATRIX.md` |
| 性能与容量 | `BENCH.md`（实测）→ `SCALE.md`（优化路线） |
| 负载均衡与热更新 | `WHYPER.md` → `LOADBALANCE.md` |
| 移动端原理与实测 | `MOBILE.md` |
| 踩过的坑（编号至 194，实记 153 条） | `NOTES.md` |
| 排障方法论 | `DEBUGGING.md` |
| 部署（HTTPS/反代/systemd） | `deploy/README.md` |
| 按场景找文档 | `INDEX.md` |
