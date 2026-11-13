# lazarusWeb 使用手册

> 版本基准：LW_VERSION 0.9.0（`src/core/lwbase.pas`），2026-11-13 整理。
> 分两篇：**使用篇**（跑 demo、写程序、部署、排障）与**开发篇**（读码、
> 调试、扩展、测试）。细节以各专题文档为准，本文负责把它们串成一条路。

---

# 第一篇 使用篇

## 1. 这是什么

lazarusWeb 让一个普通的 Lazarus/FPC 桌面程序**不改架构**跑进浏览器：

- 业务窗体基类从 `TForm` 改成 `TLWForm`（真实 TForm 后代），`.lfm`、事件、
  业务代码原样保留；
- 编译为 `--ws=nogui` 无头服务（虚拟显示器补丁 `lwws.pas`）；
- 服务端每个浏览器页签持有一棵真实 LCL 控件树，事件经 HTTP/WebSocket
  回来后 RTTI 派发给真实控件事件；`ShowModal`/`ShowMessage`/`TOpenDialog`
  自动改道成浏览器模态框，服务端真的阻塞等待；
- 浏览器端由 `lw.js`（Ext JS 7.5.1）或 `lw-alpine.js`（Alpine.js 3.14.9）
  渲染并按 id 对账增量更新；`--patch=1` 时事件只回 2~4KB 差量。

对标商业产品 uniGUI。技术总览见 `docs/ARCHITECTURE.md`。

## 2. 环境与构建

工具链：FPC 3.3.1 + Lazarus（本机在 `c:\111\fpc`、`c:\111\lazarus`）。
`build.bat` 自动探测 lazbuild（环境变量 `LAZBUILD` → Program Files →
`C:\111\lazarus`）。

```
build.bat              :: 编译全部 10 个 demo（lazbuild -B --ws=nogui）
build.bat grid         :: 只编译 demos\grid（db→dbdemo、files→filedemo 自动识别）
```

要点：

- **必须带 `-B`**：lazbuild 不跟踪 `.lfm` 依赖，改了窗体不加 `-B` 会静默
  链接旧 `.o`（这是最常见的"改了没生效"）；
- 编译前**先关掉正在跑的 exe**，否则报 "Can't create object file (error 5)"；
- `build.bat` 必须保持 ASCII + CRLF（cmd.exe 解析 UTF-8 中文注释会挂）；
- 产物落在各 demo 目录本身（如 `demos\db\dbdemo.exe`）；
- Linux/macOS 用 `build.sh`。

## 3. 跑第一个 demo

```
demos\multi\multi.exe --port=8090        :: 菜单/多标签/同步模态
demos\db\dbdemo.exe --port=8095          :: SQLite 增删改查（需 demos\db\sqlite3.dll）
demos\files\filedemo.exe --port=8096     :: 上传/下载
demos\dbaware\dbaware.exe --port=8110    :: DB 感知控件全家桶
start-demo.bat                           :: 前台跑 dbdemo（默认 8092，Ctrl+C 停）
start-gui.bat                            :: GUI 版 dbaware_gui.exe（弹服务端面板）
```

浏览器打开 `http://127.0.0.1:8090/`。

demo 一览（可执行入口全在 `demos/`，框架本体是库不是 exe）：

| demo | 演示内容 |
|---|---|
| hello | 最小示例（一个窗体一个按钮） |
| grid | 表格 |
| multi | 菜单/多页签/同步模态往返 |
| db | SQLite 增删改查（工程名 dbdemo） |
| files | 上传下载 |
| dbaware | DB 感知全家桶（dbaware.lpi 控制台版 + dbaware_gui.lpi GUI 版） |
| dialogs | 对话框改道 |
| controls | 控件陈列 |
| login | 登录/权限框架 |
| gallery | 全功能画廊（压测基线，附 lwperf/lwdump） |
| audit | lfm 链路审计演示（auditdemo） |

## 4. 写你自己的程序

最小改造（三步）：

```pascal
// 1) 窗体基类改一行
TMainForm = class(TLWForm)          // 原来是 class(TForm)

// 2) 工程文件启动代码
Application.Initialize;
TLWApp.Register(TMainForm);         // 注册窗体（可多个，--form= 选默认）
TLWApp.Run;                         // 起 HTTP 服务

// 3) 工程编译选项加 -dLCLnogui（--ws=nogui）
```

- 对话框不用改：`ShowMessage` / `MessageDlg` / `InputQuery` / `TOpenDialog`
  由 `lwdlg.pas` 自动改道浏览器；
- 数据库控件直接绑 `TDataSource`，行为与桌面一致；SQLite 三条硬规则见
  README「数据库应用」节（VARCHAR 列、显式 Commit、编辑态不下发网格行）；
- 自定义 AJAX 端点：`TLWApp.AddAjax(name, handler)`（对应 uniGUI 的
  AddAjaxProcedure），第三方 JS 直接 fetch `/lw/ajax/<名字>`；
- 登录：`TLWApp.SetLogin(TXxxLoginForm)` 一行启用，见 `demos/login/`；
- 图表 `TLWChart`、报表 `lwreport`（HTML/CSV/XLSX）、富内容 `TLWHTMLFrame`
  /`TLWPDFFrame`、仪表 `TLWGauge`、取色器 `TLWColorPicker` 都是框架自带控件；
- 定时器用 **TFPTimer**（必须 `UseTimerThread=True`）——nogui 下 TTimer
  不可用。

现有工程一键迁移：

```
tools\lwconvert.exe <项目目录> --convert <输出目录>
tools\lwconvert_gui.exe                :: GUI 版：选目录→分析/转换→看报告
```

改写内容：`.pas` 基类与 uses、`.lpr` 启动代码、`.lpi` 重新生成为 nogui
工程，附控件支持度报告。IDE 里也有向导：设计期包 `lwdesign`（New Project
两个模板 + New Form + 组件面板）。

## 5. 配置

命令行参数（完整表以 `src/core/lwapp.pas` 的 `--help` 为准）：

```
--config=path  --port=  --root=  --form=  --client=ext|alpine  --ext=
--extdir=  --theme=  --title=  --timeout=  --trust-proxy  --ajax-cors
--verbose  --nogui  --patch=1  --log=path  --help
```

INI 配置（模板 `lazarusWeb.ini.sample`，放 exe 旁改名 `<exe名>.ini` 或
`lazarusWeb.ini`）：`Port` / `Theme` / `ExtDir` / `Patch` / `Client`。
优先级：**内置默认 < 配置文件 < 命令行**。编码须 UTF-8 或纯 ASCII。

渲染层二选一：

- `ext`（默认候选）：Ext JS，需要 `ext-7.5.1/` 目录（约 75MB）；
- `alpine`：Alpine.js 3.14.9（内置 `src/client/alpine.min.js`），**不需要
  ext 目录**，部署最轻；`--client=alpine`、INI `Client=alpine` 或 URL
  `?client=alpine` 启用。协议两者完全一致。

## 6. 部署

最小目录（自包含）：

```
yourapp.exe
ext-7.5.1\            （alpine 客户端可省；精简版约 23MB，见 tools\make_ext_min.bat）
src\client\lw.js      （+ lw.css；alpine 模式则 lw-alpine.js + lw-alpine.css）
```

- 应用进程只说 HTTP（无 TLS）；HTTPS 由 nginx/Caddy 反代终结，完整示例
  在 `deploy/nginx.conf`、`deploy/Caddyfile`（含 `/lw/ws` Upgrade、
  `/lw/api/poll` 不缓冲、100MB 上传上限、`/ext/` 缓存）；
- 反代后面加 `--trust-proxy`（日志里的 IP 才是真实客户端）；
- 健康探针 `GET /lw/healthz`；
- 单机多 worker：用自带负载器 `tools\lwhyper.exe`（对标 uniGUI Hyper
  Server：worker 守护 + 反代 + sid 粘性 + WS 透传 + 崩溃重启），完整用法
  见 `docs/WHYPER.md`；强烈建议 worker 参数加 `--patch=1`；
- nginx 集群必须粘性会话（`ip_hash`）——会话在进程内存，Redis 外置未做；
- Linux：`build.sh` 编译，工程 uses 里加 `cthreads`，装 libsqlite3，
  systemd 示例见 `deploy/README.md`。

## 7. 容量与性能

- 单事件（全量输出）约 6.3ms → 开增量补丁后 4.3~6.3ms；
- 单进程吞吐：全量约 57.9 事件/秒，`--patch=1` 后 150~163 事件/秒；
- 舒适区 10~20 个活跃用户，40 为上限；空闲会话可挂 200+（约 1MB/会话）；
- 横向扩展：lwhyper N worker ≈ N×150 事件/秒（workers 建议核数/2）；
- 实测方法与数据见 `docs/BENCH.md`，优化路线见 `docs/SCALE.md`。

## 8. 常见问题（排障速查）

| 现象 | 原因/解法 |
|---|---|
| 改了窗体没生效 | 重编译没带 `-B`；或 exe 还在跑导致链接失败（先关 exe） |
| lfm 读流失败 Unknown property | LW 控件没有 TabOrder 等 published 属性，lfm 里删掉；TBufDataset FieldDefs 别进 lfm |
| TDBNavigator 建崩 | lfm 写真实类名 `TLWDBNavigator` 并 `RegisterClass(TLWDBNavigator)`（坑 29/41） |
| DBGrid 显示 (MEMO) | SQLite 字符串列改 `VARCHAR(n)`（坑 9） |
| 保存"成功"重启丢数据 | `sqoAutoApplyUpdates` 不提交事务，Post/Delete 后显式 `SQLTransaction.Commit` |
| 控件显示灰框 | 该控件是 placeholder，查 `docs/CONTROL_MATRIX.md`；服务端逻辑照常跑 |
| 程序秒退（无输出） | 终端工具在 Job Object 里拉起又被回收；GUI 版看面板日志；坑 108 |
| worker 无限重启 | 命令行 DelimitedText 替换语义踩坑，已修（坑 106） |
| FPImageException | 多半是替身，真凶常是 sqlite 锁（坑 107） |
| SQLite database is locked | WAL + busy_timeout=10000 + 写前 CommitRetaining（坑 9） |
| 公网日志 IP 全是反代地址 | 加 `--trust-proxy` |
| 端口被强杀残留孤儿 socket | `LISTENING PID 0`，换端口最省事 |

更多案例与调试方法论：`docs/DEBUGGING.md`；108 个坑按编号检索
`docs/NOTES.md`（坑 23/66 等旧结论已被后续坑修订，以标注为准）。

## 9. 已知限制

- 模态超时 180 秒；同一会话同时只能有一个对话框；
- `TOpenDialog` 不能浏览服务端磁盘（只能上传文件）；
- `TSplitter` 不可拖动；`Anchors` 不做前端吸附计算；
- 高 DPI 按 96 处理（125%/150% 设计的 lfm 自动缩回）；
- PDF 直出暂以浏览器"另存为 PDF"代替；会话外置 Redis 未实现；
- 未适配控件浏览器端灰框占位（服务端照常活着），不影响其他控件。

---

# 第二篇 开发篇

## 10. 源码结构

```
src/
├── lwcore.lpk / lwserver.lpk      运行时包（IDE 自动生成，聚合单元）
├── design/lwdesign.lpk            设计期包（IDE 向导/组件面板）
├── client/                        前端运行时：lw.js lw.css lw-alpine.js lw-alpine.css alpine.min.js
├── lib/                           包编译产物（入库忽略）
└── core/                          全部核心单元（约 30 个）
```

`core/` 关键单元（职责即文件头注释）：

| 单元 | 职责 |
|---|---|
| lwbase.pas | 基础类型/JSON 工具；`LW_VERSION`；事件白名单 `IsLWClickEvent` |
| lwws.pas | nogui widgetset 补丁：虚拟显示器 1920×1080@96DPI + GDI 补齐 |
| lwform.pas | `TLWForm` 基类（覆盖 ShowModal/DoClose 实现同步模态） |
| lwwriter.pas | LCL 树 → JSON（KindOf 映射、白名单属性、内部件过滤） |
| lwsession.pas | 会话 = 一个页签 + 一棵 LCL 树；推送队列；增量补丁快照 |
| lwdispatch.pas | 浏览器事件 → RTTI 调真实控件事件；vals 回填 LWApplyValue |
| lwhttp.pas | fphttpserver 路由（/lw/api/*、/ext/、/lw/download、/lw/view…） |
| lwapp.pas | 门面：Register/SetLogin/Run；命令行与 INI 解析 |
| lwdlg.pas | 对话框改道（LWInstallDialogs） |
| lwdiff.pas | 增量补丁 diff（两次 payload → ops） |
| lwws/lwwebsocket.pas | WS 只传事件请求/响应；推送走长轮询游标 |
| lwdbgrid.pas / lwdbnav.pas | TLWDBGrid / TLWDBNavigator（lfm 写真实类名） |
| lwchart/lwui/lwweb/lwreport/lwlogin/lwpanel/lwrlog | 图表/仪表取色遮罩/富内容/报表/登录/面板/日志 |
| lwhyper.pas | 负载均衡核心（tools 的控制台/GUI 版共用） |
| lwnewproject.pas | 工程骨架模板（IDE 向导与 tools\lwnew 共用） |
| lwproxyws.pas | 自动生成（gen_proxyws.py），GUI 构建专用代理 widgetset，勿手改 |

## 11. 工作原理（一分钟版）

1. `TLWApp.Register(TMainForm)` 只记窗体类；`Run` 起 HTTP 服务；
2. 浏览器 `GET /` → `POST /lw/api/session` → 服务端创建真实 `TMainForm`
   实例并跑 `OnCreate`，`lwwriter` 把整棵 LCL 树序列化成 JSON 下发；
3. 点击 → `POST /lw/api/event {sid,id,ev,val,vals}` → `lwdispatch` 用
   RTTI 找到控件，先 `LWApplyValue` 回填值再触发真实事件（按钮走原生
   Click 保 ModalResult 语义）→ 重新序列化返回新树；
4. `ShowModal` 用 `TEvent.WaitFor` 200ms 切片真阻塞事件线程，浏览器端
   长轮询把模态指令推给页签；点 OK 经 `/lw/api/dlg` 带回模态结果；
5. 推送一律走长轮询游标（`poll?after=N`，队列 64 条），WS 只传事件；
6. 浏览器 `lw.js` 按 id reconcile 增量更新；`--patch=1` 时服务端先 diff
   （lwdiff）只发 ops，客户端 `tver` 不匹配自动退回全量自愈。

深读：`docs/HOW_IT_WORKS.md`（含关键源码行号）；
为什么不能全量 RTTI dump、KindOf 顺序敏感性等设计约束也在那里。

## 12. 线程模型（改动前必读）

- fphttpserver 每请求一线程；事件线程处理 `/lw/api/event`；
- 长轮询线程阻塞 20s；Sweep 线程清会话（默认 20 分钟超时）；
- GUI 版另有 accept 后台线程 + 面板 TTimer；
- **并发建窗会踩坏 LCL 全局字形缓存**：建窗/销毁/序列化必须进
  `LWLCLEnter/Leave` 闸门（坑 100），事件处理故意不进；
- 会话级可重入执行锁 `FExec`（坑 71）：模态期间同会话其他请求排队；
- 会话数据全部在进程内存 → 集群必须粘性，worker 重启即丢会话。

## 13. 调试

- `--verbose` 打印每个请求与异常栈；`--log=path` 落盘；
- GUI 版面板：菜单 File/Admin + 实时日志（限 4000 行）+ 状态栏三格；
- lwhyper 自带 `/lw/hyper/status` worker 明细端点；
- 压测：`tools/bench_concurrency.py`（阶梯加压）、`tools/pipe_bench.py`
  （管道基准）；性能剖析开关 `LW_PROF`；
- 四个真实 bug 的定位过程 + 九条调试方法论：`docs/DEBUGGING.md`。

## 14. 测试

统一入口（自动起停服务）：

```
python tests/run_with_server.py <exe路径> <测试脚本> [端口] [exe额外参数]
```

- **HTTP 级回归** `tests/t_*.py`（约 25 个：controls/db/dbaware/dialog/
  files/login/multitab/ws/hyper_ws/writeback_audit…），数百项断言；
- **CDP 浏览器探针** `tests/cdp_*.py`（走 Chrome DevTools 协议连无头
  Edge，9237 端口，需 websocket-python）：首屏渲染/截图/控制台错误；
- **离线单测**：`tests/lwdiff_case.lpr` + `t_lwdiff_fuzz.py`（diff fuzz，
  纯 fpjson 不用 lazbuild）；
- **支持度审计**（改动 lwwriter/lw.js 后重跑）：

  ```
  tools\build_audit.bat     → docs\CONTROL_MATRIX.md
  tools\build_dbcheck.bat   → docs\DB_AWARE_MATRIX.md
  ```

## 15. 扩展开发

加一个新控件的渲染支持（标准路径）：

1. `lwwriter.KindOf` 加 kind（注意分支顺序，KindOf 顺序敏感）；
2. `lwbase` 事件白名单按需加事件；
3. `lw.js`（及 lw-alpine.js，如需双端一致）加渲染分支与回写分支；
4. `demos/audit` 或 `demos/controls` 摆一个实例；
5. 重跑 `lwaudit` 更新矩阵 + `tests/t_controls.py` 回归；
6. 映射写进 `docs/MAPPING.md`。

前端协议字段（payload/ops/tver/seq 游标）见 `docs/SCALE.md` §2 与
`docs/HOW_IT_WORKS.md`；改 lwproxyws 相关内容必须走 `gen_proxyws.py`
重新生成。

## 16. 仓库注意

- 根目录 `src - 副本 (N)`、`src稳定版20261111`、`src高吞吐量` 等是历史
  快照，**唯一权威源码是 `src/`**；`demos/gallery - 副本` 同理；
- `demos/gallery/lw/` 等扁平部署副本会导致"改了 src/client 不生效"（坑 93）；
- `CrossSocket/` 目前无工程引用；`patches/` 是 FPC MIPS64 补丁（龙芯场景）；
- `packagefiles.xml` 是 IDE 用户包链接清单（含本机第三方包路径），不是构建脚本；
- `src/core/backup/`、`*.ppu/*.o`、`tmp/` 为本地产物，`.gitignore` 已覆盖。
