# 合并前后功能缺失全量审计（src + demos + tools）

日期：2026-11-13
审计对象：`C:\lazarusWeb` 全仓库（`src/`、`demos/`、`tools/`）
基线：合并前主线快照 `backup/20261113_pre_merge322/src`（与 `src合并前版本(331ok)` 逐字节一致）
合并来源：322 分支 `Downloads\lazarusWeb20261113-1849\lazarusWeb`（**只含 `src/`，没有 demos/tools**）
配套文档：`MERGE_AUDIT.md`（首轮，仅 src/core 9 文件 + 3 lpk）

## 一、结论

**没有发现合并造成的功能缺失。** 三层证据（符号级 / 字符串级 / 条件编译展开级）对 `src` 全部 36 个源文件的差集都是空集；`demos` 与 `tools` 在合并时段内源码零改动，符号级同样空集；22 个构建目标全绿，17 套回归全部通过。

审计过程中另外发现 **4 个与合并相关、但不是"丢功能"的问题**，其中 1 个是真 bug：

| # | 问题 | 性质 | 处置 |
|---|---|---|---|
| P1 | `lwwebsocket.pas` 用 `fpShutdown` 却只 uses `BaseUnix` —— **Linux/macOS 交叉编译直接报 `Identifier not found "fpShutdown"` 编不过** | 坑 122（合并后修复 WS 泄漏）引入的跨平台回归，Windows 下不暴露 | 已修：非 Windows 分支补 `uses Sockets`；x86_64 / mips64el / aarch64 三个 Linux 目标重新编过 |
| P2 | `tests/t_files.py` 断言路径含 `lw_uploads` | 上传目录已改为 `LWUploadRootDir`（`<exe>/uploads`），断言过期 | 已修断言，重跑 28/28 |
| P3 | `tests/t_config.py` 5 个主题用例失败 | 默认渲染层改为"自动探测优先 alpine"（坑 92），alpine 首页不含 Ext 主题样式表 | 已修：用例固定 `--client=ext`，重跑 19/19 |
| P4 | `gallery.lpi` / `gallery_gui.lpi` 的 `TargetCPU=mips64el` / `TargetOS=linux` 在合并期被删除，未记入文档 | 构建配置静默变更（删得对：否则不带参数 `lazbuild` 会直接产出本机跑不了的 mips 二进制） | 保留删除，本报告记录；交叉编译改用显式 `--os/--cpu` |

## 二、审计范围与判定口径

"功能"按四类可观测面判定，任一类在合并后变少即算缺失：

1. **符号面** —— 过程/函数/构造析构（含 `TClass.Method` 全名）、类型、常量、`property`、`.lfm` 控件对象名、`.lpi` 单元与包引用；
2. **字面量面** —— 源码里的 URL 路径（`/lw/...`）、JSON 字段名、注册表键名等字符串常量；
3. **编译面** —— 按 `FPC_FULLVERSION=3.3.1` 与 `3.2.2` 两个视角分别展开条件编译后的代码差；
4. **运行面** —— 编译 + 交叉编译 + 端到端回归。

> 判定规则：符号/字面量差集为空即"代码级无缺失"；编译面允许等价改写，但要用 diff 逐块确认；运行面用回归数字兜底。

## 三、src：九个差异文件逐一结论

36 个源文件里 27 个（15 个 core 单元 + client 全部 + 入口单元 + 设计期单元）与合并前**逐字相同**；差异只在这 9 个 `.pas` + 3 个 `.lpk`。

| 文件 | 差异 | 符号缺失 | 性质 |
|---|---|---|---|
| `lwapp` | 16 行 | 0 | 3.2.2 用 `SetTextBuf` 1 字节缓冲替代 `SetTextAutoFlush`；3.3.1 视角展开后 **0 行差异** |
| `lwbase` | +50 行 | 0 | 新增 `LWHTTPStatusText` 码表（3.2.2 无 `GetHTTPStatusText`）；纯新增 |
| `lwsession` | 34 行 | 0 | `LWSeqOf` 无符号中转 + DARWIN `TThreadID(0)`；3.3.1 视角下与原来等价 |
| `lwproxyws` | +8/−1 行 | 0 | 新增 Cocoa 支持与 `TWidgetSet` 兜底；`AppHandle` 赋值收进 `{$IFDEF MSWINDOWS}` |
| `lwreport` | +3 行 | 0 | `Result := nil` 消 5093 提示 |
| `lwwriter` | +9 行 | 0 | 新增 `scrollbox` kind 分支（坑 121，修 TScrollBox 边框缺失） |
| `lwhttp` | 161 行 | 0 | 兼容层：`LiveConnections` 封装、`WSRun(AOwnSocket)` 拆分、`LWReqHeader`、`CodeText` 分派、`ELWUpgraded`；另含坑 122 的显式 `Free` |
| `lwhyper` | 307 行 | 0 | 同上 + `WSTunnel` 拆分、`TLWWSTunnel(AOwnClient)`、`wsopen/wsdone/heap` 观测字段 |
| `lwwebsocket` | 167 行 | 0 | `LWCanRead` / `LWSocketClose` / `LWSocketShutdown` 三个垫片；帧编解码、掩码、分片、ping/pong 原样保留 |

### 3.1 符号级与字面量级

```
python tests/audit_sym.py "src合并前版本(331ok)" src     -> 0 组缺失 / 0 项
字面量（'/lw/...'、注册键名等）差集                     -> 0 项
```
覆盖 `procedure/function/constructor/destructor`（含 `TClass.Method` 全名）、`type`、`const`、`property`、`.lfm` 的 `object XXX:`、`.lpi` 的 `UnitName/Filename`。

### 3.2 条件编译展开（关键层）

自写展开器把两边**都**按同一宏环境展开，再比 diff。这样 `{$IF ...}` 指令行的增删不会假报差异，看到的是"该版本实际编译出的代码"。

| 文件 | 3.3.1 视角 | 3.2.2 视角 | 3.3.1 视角被删的行是什么 |
|---|---|---|---|
| `lwapp` | −0 / +0 | −2 / +8 | 无差异（兼容层完全在 3.2.2 分支内） |
| `lwbase` | −0 / +50 | −0 / +50 | 无 |
| `lwwriter` | −0 / +9 | −0 / +9 | 无 |
| `lwreport` | −0 / +3 | −0 / +3 | 无 |
| `lwproxyws` | −1 / +8 | −1 / +8 | 一行注释 |
| `lwsession` | −5 / +14 | −5 / +14 | `PtrInt(...)` 被 `LWSeqOf(...)` 包裹（同值） |
| `lwwebsocket` | −12 / +93 | −12 / +100 | `Sock.CanRead` → `LWCanRead`（3.3.1 下垫片内部委托原生）、`for i: Int64` → `for k: Integer`（配合 `Integer(L)` 截断，前面有 `WS_MAX_PAYLOAD` 上限保护） |
| `lwhttp` | −15 / +98 | −56 / +115 | `ConnectionHandler` 三次直读 → `LiveConnections`；`GetHeader` → `LWReqHeader`；`aConnection.Socket` → `ASock`；`sock.Free` → `if AOwnSocket then sock.Free`（坑 122）；其余为注释 |
| `lwhyper` | −75 / +181 | −80 / +197 | `WSTunnel` 整体重排（原代码移进 `try` 块、缩进变化）+ `CanRead/Close` 换垫片 + 收尾统一走 `finally`；**没有功能删减** |

3.2.2 视角下多出的 −56/−80 是"3.3.1 专属 API 不可用"的替代实现，逐项都有等价路径：

| 3.3.1 写法 | 3.2.2 替代 | 影响 |
|---|---|---|
| `FHTTP.ThreadMode := tmThread` | `FHTTP.Threaded := True` | 等价 |
| `RegisterUpdateHandler` | `OnRequest` 里接管 + 抛 `ELWUpgraded` 跳出 | 等价（连接线程被 WS 独占） |
| `ConnectionHandler.GetActiveConnectionCount` | `ConnectionCount` | 等价计数 |
| `ConnectionHandler` 逐连接 `shutdown` | 不做（该版本一连接一请求、无 keep-alive 空闲连接） | 仅"停服等待"路径简化 |
| `GetHTTPStatusText` | `LWHTTPStatusText` 码表 | 表内码一致，表外给 `Status <码>` |
| `GetHeader` | 先 `GetHeader` 再兜底 `CustomHeaders` | 3.2.2 必需（头落在 CustomHeaders） |
| `Sock.CanRead` / `Sock.Close` | `select` 垫片 / `CloseSocket` | 等价 |

### 3.3 包定义

`lwcore.lpk` / `lwserver.lpk` / `lwdesign.lpk`：只改路径分隔符（`core\lwbase.pas` → `core/lwbase.pas`），`UnitName` 清单与 `PackageName` 依赖清单 diff 为空。

## 四、demos：合并没有碰过它

先行事实：322 分支压缩包里**只有 `src/`**，没有 `demos`/`tools`。

时间戳佐证 —— 合并窗口（19:30–20:10）内 `demos`/`tools` 被写过的文件只有：

- 6 个 `.lpi`（`dbaware` / `dbaware_gui` / `gallery_gui` / 各 demo 的 `UnitOutputDirectory` 分隔符）
- `lib/**` 下的 `.lfm` 编译副本（编译器产物）

**没有一个 `.pas` / `.lfm` / `.lpr` 源文件被覆盖。** 所以 demos 不存在"被 322 旧版覆盖"的风险。

### 4.1 与合并前最后一次提交（`dca6363`）的源码差异

| 文件 | 差异行 | 性质 |
|---|---|---|
| `gallery/ugallery.pas` | 142 | **纯新增**：`FillDrawGridDemo`（@bar/@chip/@spark/@stars）、`GDbEnsured/GBigDbEnsured`（坑 107）、`unit`/`made` 列 + PickList/日期/勾选编辑器、标题去掉"对照 uniGUI"字样 |
| `gallery/ugallery.lfm` | 42 | 尺寸/`TabOrder`/文案微调（IDE 另存），控件对象无增删 |
| `gallery/uabout.lfm` | 29 | 窗体放大到 630×330、`DesignTimePPI=144`（IDE 另存） |
| `gallery/uabout.pas` | 2 | 正文加"Alpine.js或" |
| `*/**.lpi` | 2–6 | `UnitOutputDirectory` 加 `-nogui`/`-win32` 后缀（修 nogui/win32 单元互相覆盖，见首轮审计第六节） |
| `gallery.lpi` / `gallery_gui.lpi` | 13 / 6 | 上表 P4：删掉默认 `TargetCPU=mips64el`/`TargetOS=linux` |
| `tools/ulwhypergui.pas` | +18 | 新增 `autostart=1` 自动启动、cfg 固定到 exe 目录 |

**删除项只有两个**：

1. `demos/gallery - 副本/`（6 个文件）—— 与正式版对比是**更旧**的实现（`TBufDataset` + 代码建窗），正式版已改为 sqlite + 设计期 lfm。删除不丢功能；
2. `demos/gallery/gallery_nogui-aarch64-linux`（二进制产物）—— 本轮已重新交叉编译补回（ELF AArch64）。

**新增项**：`demos/gallery/lwdump.lpi|lpr`、`lwperf.lpi|lpr`（首屏树转储 / 性能探针），属于功能增加。

### 4.2 符号级

```
# 合并前最后一次提交（dca6363，2026-11-12 10:25）的源码快照
mkdir -p /tmp/base_head && git archive HEAD | tar -x -C /tmp/base_head
python tests/audit_sym.py /tmp/base_head/demos demos
  -> 唯一"缺失"：被删的 gallery-副本 6 个文件；唯一 SYM-MISSING：
     .lw-htmlframe, .lw-pdfframe, .lw-chart  { ... } 一条组合 CSS 选择器
```
该 CSS 规则不是删除，是拆成三条独立规则并各自补了 `.lw-boxed` 边框（当前 `.lw-htmlframe, .lw-pdfframe` + `.lw-chart` + 三者的 `.lw-boxed`），属增强。

### 4.3 demo 项目清单

13 个（与合并前一致，另 +2 个新增探针）：`audit` `controls` `db` `dbaware` `dbaware_gui` `dialogs` `files` `gallery` `gallery_gui` `grid` `hello` `login` `lwapp1` `multi`。
（历史快照：此为合并审计当时的探针清单；其中的 `lwapp1` demo 后来已删除，现存 demo 见 `README.md`。）

## 五、tools：源码零差异

| 工具 | 与合并前 |
|---|---|
| `lwaudit`（控件支持度审计） | 源码逐字相同；`--stdout` 实测 82 个控件行，与 `docs/CONTROL_MATRIX.md` 的 82 行**完全对齐**（ok 49 / 可用 16 / kind-only 7 / placeholder 10，`unknown` 0） |
| `lwconvert` / `lwconvert_core` / `ulwconvertgui` | 逐字相同；`t_convert` 全链路 29/29（转换 8 处改写 → 编译 → 启动 → 页面/控件/模态往返） |
| `lwdbcheck` | 逐字相同 |
| `lwhyper` / `lwhyper_main` | 逐字相同（能力全部在 `src/core/lwhyper.pas`） |
| `lwhyper_gui` / `ulwhypergui` | 新增 `autostart` + cfg 固定 exe 目录（+18 行，纯新增） |
| `lwnew` | 逐字相同；实测生成 6 个文件并 `lazbuild` 通过 |
| `tspp` | 新增（模板预处理） |

`tools/lib/**` 只是编译产物。

## 六、验证矩阵

### 6.1 全量编译（FPC 3.3.1 / win64）

3 个包 + 14 个 demo + 5 个 tools = 22 个目标，**0 失败**（`tmp/build_all2.log`）。

### 6.2 交叉编译（修复 P1 后）

| 目标 | 结果 |
|---|---|
| linux / x86_64 | ELF64 machine=62 |
| linux / mips64el | ELF64 machine=8 |
| linux / aarch64 | ELF64 machine=183 |

修复前三个 Linux 目标**全部编不过**（`lwwebsocket.pas(241,5) Error: Identifier not found "fpShutdown"`）。

### 6.3 端到端回归

| 套件 | 结果 | 覆盖 |
|---|---|---|
| `t_gallery` | 50 / 50 | 12 页签、46 个关键控件、网格/图表/帧/对话框/定时器/大表分页 |
| `t_controls` | 26 / 26 | 容器与列表类控件 |
| `t_ws` | 8 / 8 | WebSocket 直连通道 |
| `t_db` | 35 / 35 | 数据库演示 |
| `t_dbaware` | 134 / 134 | 数据感知控件全集 |
| `t_dialog` | 36 / 36 | 对话框族 |
| `t_files` | 28 / 28 | 上传/下载/令牌一次性/CSV |
| `t_login` | 15 / 15 | 登录 + 会话 |
| `t_multitab` | 22 / 22 | 跨页签 + 推送游标 |
| `t_hyper` | 20 / 20 | 负载均衡、粘性、崩溃重启、死会话兜底 |
| `t_hyper_ws` | 6 / 6 | WS 隧道握手与帧往返 |
| `t_convert` | 29 / 29 | lwconvert 转换 + 编译 + 运行 |
| `t_writeback_audit` | 7 / 7 | 浏览器值 → LCL 写回 |
| `t_patch_e2e` | 20 事件对账通过 | 增量补丁 vs 全量对账 |
| `t_lwdiff_fuzz` | 300 组 0 失败 | 补丁算法对拍 |
| `t_ws_churn` | 800 / 800 | 建/断压力，资源收尾 |
| `t_config` | 19 / 19 | 端口/主题/extdir 优先级 |

## 七、P1 详情（唯一真 bug）

```
src/core/lwwebsocket.pas(241,5) Error: (5000) Identifier not found "fpShutdown"
```

坑 122 新增 `LWSocketShutdown` 时，注释写的是"Linux/macOS 走 BaseUnix，`fpShutdown`"，但 **`fpShutdown` 在 `Sockets` 单元，不在 `BaseUnix`**。Windows 分支走 `WinSock.shutdown`，所以 win64 全绿、只有交叉编译才暴露。

修法（一行依赖）：

```pascal
{$IFDEF MSWINDOWS}
, WinSock          { select / FD_ZERO / FD_SET / shutdown }
{$ELSE}
, BaseUnix         { fpSelect / fpFD_ZERO / fpFD_SET }
, Sockets          { fpShutdown（3.2.2/3.3.1 都在这里） }
{$ENDIF}
```

验证：三个 Linux 目标全部链接成功；win64 全套重编 0 失败；`t_ws` 8/8、`t_hyper_ws` 6/6 复测通过。

## 八、复现

```bash
# 符号级 / 字面量级
python tests/audit_sym.py "src合并前版本(331ok)" src
python tests/audit_sym.py /tmp/base_head/demos demos

# 条件展开对比（两版本各一遍）
python tests/audit_cpp.py src/core/lwhttp.pas 3.3.1 win > /tmp/a.pas
python tests/audit_cpp.py "src合并前版本(331ok)/core/lwhttp.pas" 3.3.1 win > /tmp/b.pas
diff -u /tmp/b.pas /tmp/a.pas

# 全量编译 / 交叉编译
for p in src/lwcore.lpk src/lwserver.lpk src/design/lwdesign.lpk demos/*/*.lpi tools/*.lpi; do lazbuild "$p"; done
lazbuild --os=linux --cpu=x86_64  --ws=nogui --compiler=C:/111/fpc/bin/x86_64-win64/ppcrossx64.exe      demos/gallery/gallery.lpi
lazbuild --os=linux --cpu=mips64el --ws=nogui --compiler=C:/111/fpc/bin/x86_64-win64/ppcrossmips64el.exe demos/gallery/gallery.lpi
lazbuild --os=linux --cpu=aarch64 --ws=nogui --compiler=C:/111/fpc/bin/x86_64-win64/ppcrossa64.exe      demos/gallery/gallery.lpi
```

## 九、遗留（不影响"无缺失"结论，但建议处理）

1. **未纳入版本控制的新源码**：`src/core/lwdiff.pas`、`demos/gallery/lwdump.lpr`、`lwperf.lpr`、`tools/tspp.lpr`、`tests/*.py|lpr` —— `git status` 里是 `??`。这些是被审计确认存在且已编译通过的功能，不在 git 里意味着一次误删就无法恢复，建议尽快提交。
2. **`TLWSession.SessionTempDir` 仍用 `%TEMP%\lw_uploads/<sid>`**，而上传落地已改 `LWUploadRootDir`（`<exe>/uploads/<sid>/<控件>`）。两者是不同用途（对话框 pick/save 中转 vs 上传落地），但目录名不一致，`docs/lazarusWeb控件属性映射表.md` 的示例路径也已过期 —— 属文档/命名一致性问题。
3. **`?v=0.9.0` 仍是静态版本号**，资源 mtime 指纹（`LWAssetVer`）在更早的回滚中丢失（见 `MERGE_AUDIT.md` 第九节）。
4. `demos/gallery/lw/lw.css` 比 `src/client/lw.css` 少一行 SPDX 版权头 —— 纯注释差异，可顺手同步。
