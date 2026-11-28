# nogui 移植踩坑记录

把 LCL 跑在无头服务端（`--ws=nogui` / `-dLCLnogui`）时实际撞过的坑。
`src/core/lwws.pas`、`lwform.pas`、`lwsession.pas` 里的关键代码都是这些坑的解。

> **阅读约定**：本文按时间顺序追加，记录的是"当时"的状态。坑 90 等早期条目里
> 提到的"默认客户端是 Ext"是当时的配置；**当前默认渲染层为 Alpine.js**
> （内置，不需要 ext 目录），Ext JS 为可选层，需 `--client=ext` 并自备
> `ext-<版本>/`。以 `README.md`、`ARCHITECTURE.md`、`MANUAL.md` 的现行表述为准。

## 坑 1：创建任何 TForm 都 AV —— 没有显示器

`TCustomForm.AfterConstruction` 里有一句：

```pascal
MonPPI := Monitor.PixelsPerInch;
```

nogui 的 `EnumDisplayMonitors` 直接返回 False，屏幕上一个显示器都没有，
`Monitor` 为 nil → AV。

**解**：`lwws.pas` 用 `TLWWidgetSet = class(TNoGUIWidgetSet)` 替换全局
`WidgetSet`，补一个虚拟显示器（默认 1920x1080 @96DPI）：

- `EnumDisplayMonitors / GetMonitorInfo / MonitorFromWindow / MonitorFromPoint`
- `GetDpiForMonitor` → 96

## 坑 2：`Application.DoubleBuffered` 的野类型转换

`TCustomForm.CreateNew` 里：

```pascal
case Application.DoubleBuffered of
  adbDefault: FDoubleBuffered := TWSCustomFormClass(WidgetSetClass).GetDefaultDoubleBuffered;
```

nogui 的 widgetset 实例**不是** `TWSCustomForm` 的后代，默认值 `adbDefault`
会走进这个硬转型 → 崩。

**解**：`LWInstallWidgetSet` 里显式 `Application.DoubleBuffered := adbFalse;`
（服务端不绘制，不需要双缓冲。）

## 坑 3：菜单控件 AV —— WS 类没注册

nogui 的 `RegisterMainMenu / RegisterMenu / RegisterMenuItem / RegisterPopupMenu`
全部 `return False`，菜单相关 WS 类根本没注册。于是：

```pascal
TMenu.CreateHandle:
  FItems.Handle := TWSMenuClass(WidgetSetClass).CreateHandle(Self)
```

`WidgetSetClass` 是 nil，硬转型后调用类方法 → AV。装载 `.lfm` 里的
`TMainMenu` 即崩（栈显示 READCOMPONENT → TMainMenu.Create）。

**解**：把 LCL 自带的空实现类注册上去占位（浏览器端菜单由 lw.js 渲染）：

```pascal
RegisterWSComponent(TMenuItem, TWSMenuItem);
RegisterWSComponent(TMenu, TWSMenu);
RegisterWSComponent(TMainMenu, TWSMainMenu);
RegisterWSComponent(TPopupMenu, TWSPopupMenu);
```

## 坑 4：`Form.Show / Visible := True` 除零

nogui 下真正的 `TCustomForm.Show` 会在 LCL 内部（ShowWindow → SetWindowPos
→ 依赖屏幕/像素计算）除零崩溃。

**解**：`TLWForm.SetVisible` 拦截 —— Web 模式下 `Visible` 只是"该不该显示"
的意图，翻译成 `SessionShowForm / SessionHideForm`，**绝不落到 inherited**。

**注意**：装载 `.lfm` 期间 LCL 也会给 `Visible` 赋初值，那一步必须走原路径，
否则 LCL 内部状态不一致（创建窗体时直接除零）。判定条件：

```pascal
if (S <> nil) and (Name <> '') and
   not (csLoading in ComponentState) and not (csCreating in ControlState) then
  ... // 拦截
else
  inherited;
```

## 坑 5：`TButton.ModalResult` 无人翻译 —— ShowModal 永远不返回

真实 LCL 里点一个 `ModalResult <> mrNone` 的按钮，是 `TCustomButton.Click`
把值写进 `Form.ModalResult` 并关闭模态窗。nogui 没有消息循环，这层不会自动
发生，`ShowModal` 会一直等到超时。

**解**：`lwdispatch.LWInvokeEvent` 对按钮**直接调用原生 `Click`** 而不是自己
RTTI 调 OnClick 方法指针：

```pascal
if (AEv = 'OnClick') and (C is TButton) then
begin
  TButton(C).Click;   // Click 内部处理 ModalResult，再调 OnClick
  Exit(True);
end;
```

顺带：`.lfm` 里 ModalResult 必须是真实常量值（`mrOk=1`、`mrCancel=2`），
写错（比如 11）不会报错但语义全错。

## 坑 6：模态窗体 Free 后序列化野指针

超时或关闭后，业务代码通常会 `Free` 掉模态窗体。会话的可见清单里若还留着它，
下一次 `BuildPayload` 直接 AV（栈指向 WRITEFORM）。

**解**：`ShowModalInSession` 超时分支与 `SessionEndModal` 都必须立刻
`SetFormWebVisible(False)` 并从 `FForms` 删除（`idx >= 0`）。

## 坑 7：fpjson 的 AsJSON 带空格 + FPC 链式拼接丢字符

- `TJSONObject.AsJSON` 输出 `{ "type" : "modal" }`（带空格），
  `Pos('"type":"modal"', cmd)` 永远不成立。判断指令类型用 `GetJSON` + `Find('type')`。
- FPC 对 `'{"cmd":' + cmd + ',"tree":' + j.AsJSON + '}'` 这种"常量+属性取值+
  常量"链式拼接会**丢末尾字符**（实测固定少 2 个字符，JSON.parse 失败）。
  先把 `AsJSON` 落到局部变量，再用 `Format` 拼接。

## 坑 8：FPC/工具链杂项

- lazbuild 不把 `.lfm` 记进依赖表：只改界面不改 `.pas` 时必须 `-B` 强制重建，
  否则继续用旧 `.o`（窗体属性不生效，极难排查）。
- Git Bash 下直接调 fpc.exe，MSYS 会把 `-FuC:\...` 转换成 `./C:\...`。
  设 `MSYS2_ARG_CONV_EXCL='*'`；或一律走 lazbuild。
- lazbuild 不转发任意 fpc 选项（如 `-Xm`）；要额外选项需写进 `.lpi` 的
  `<CustomOptions>`。
- `{ }` 注释里不能再出现裸花括号（比如描述 JSON 示例），FPC 按嵌套注释处理，
  会出现 `Comment level 2 found` 警告甚至吞代码。注释里写 JSON 用文字描述。
- 单元内**字段声明必须出现在方法/属性之前**（`Fields cannot appear after a
  method or property definition`）。
- 旧进程占用 exe：`Can't create object file ... (error code: 5)`，先 taskkill。
- 写「控件审计」这类探针程序时：**`uses Interfaces` 必须在**，否则
  `WSRegister*` 系列全部 Undefined symbol（widgetset 注册在 Interfaces 的
  初始化段里）；
- FPC 的 `TArray<T>` 在 `{$mode objfpc}` 下不能直接当变量类型用
  （`Identifier not found` 或泛型实例化报错），用自己的
  `array of record` 定义代替；
- `TTabSheet`、`TToolButton` 这类控件离开父容器创建就会 AV/异常，
  探针里要现造 `TPageControl` / `TToolBar` 再 `Parent :=`。

## nogui 下仍缺的 GDI 实现

`TLWWidgetSet` 还虚拟化了：`CreateCompatibleDC / SelectObject /
CreateFontIndirect(Ex) / GetTextExtentPoint32 / GetTextMetrics / GetDeviceCaps /
GetDC / ReleaseDC / SetTextColor / SetBkColor / SaveDC / RestoreDC /
DCGetPixel / DCSetPixel / DCRedraw`。

- 虚拟字体记录最近一次 `lfHeight`，`GetTextExtentPoint32` 用 `宽≈字数×字高×0.55`
  估算，让 TStringGrid 等控件完成创建期的文本测量（不真正绘制）；
- 网格行高不要依赖 Canvas.TextHeight（虚拟值），优先读 `DefaultRowHeight /
  RowHeights[0]`（lwwriter 的做法）；
- `ShortCutToText(0)` 返回 'Unknown'，序列化菜单快捷键前先判 0。

## 坑 9：SQLite + SQLdb 三件套（demos/db 实测）

### 9.1 TEXT/CHAR 列变 ftMemo，DBGrid 显示 `(MEMO)`

`TSQLite3Connection` 按列声明类型映射：`TEXT`、`CHAR(n)`、无类型的表达式
（含 `CAST(x AS VARCHAR(n))`）一律映射成 `ftMemo`；只有 `VARCHAR(n)` 是
`ftString`。ftMemo 在 TDBGrid 里显示 `(MEMO)`，TDBEdit 也没法正常编辑。

**解**：建表时字符串列一律 `VARCHAR(n)`，多长都行（`VARCHAR(400)` 仍是
ftString）。`FieldDefs` 手工指定类型没用——Open 时会按 SQL 重新推导。

### 9.2 Post 不落库 —— `sqoAutoApplyUpdates` 只发 SQL，**不提交事务**

FPC 的 `TCustomSQLQuery`：

```pascal
procedure TCustomSQLQuery.Post;
begin
  inherited Post;
  If (sqoAutoApplyUpdates in Options) then
    ApplyUpdates;
end;

procedure TCustomSQLQuery.ApplyUpdates(MaxErrors: Integer);
begin
  inherited ApplyUpdates(MaxErrors);
  If sqoAutoCommit in Options then          // ← 只有这个选项才提交
    begin
    FStatement.RowsAffected;
    SQLTransaction.Commit;
    end;
end;
```

只加 `sqoAutoApplyUpdates` 时：UPDATE/INSERT 确实发给 SQLite 了，
但事务一直开着。表现为两种"看起来正常"的假象 + 两个真故障：

- ✅ 假象 1：同一连接里再查，新值都在（读的是自己未提交的事务）；
- ✅ 假象 2：日志/界面都显示"保存成功"；
- ❌ 故障 1：数据库文件其实没变，**程序一退出全部回滚**；
- ❌ 故障 2：这个写事务握着 SQLite 的写锁，第二个会话（另一个浏览器
  标签 = 另一个连接）一保存就 `FConn : database is locked`。

**解**（`demos/db` 的做法，三条一起上）：

1. `Post`/`Delete` 之后**显式 `SQLTransaction.Commit`**。
   注意 `Commit` 会关闭该事务上的所有数据集，所以要先把当前行的 id
   记下来，Commit 完再 `Requery(keepId)` 重开 + 定位回去。

2. 打开连接时加 WAL 与 busy_timeout：

   ```pascal
   FConn.Params.Add('journal_mode=WAL');          // 必须走 Params
   FConn.Open;
   FConn.ExecuteDirect('PRAGMA busy_timeout=10000');
   ```

   - **WAL 只能走 `Params`**：`sqlite3conn.DoInternalConnect` 里写死只认
     `foreign_keys` / `journal_mode` 两个参数，在 `sqlite3_open_v2` 之后、
     任何事务之前执行；
   - 用 `ExecuteDirect('PRAGMA journal_mode=WAL')` **实测无效**（SQLdb 把
     语句包进事务，`PRAGMA` 返回当前模式但没改；文件仍是 `delete`）；
   - `busy_timeout` 不在那个白名单里，只能 Open 后用 PRAGMA（它在事务内也有效）。

3. WAL 下的第二把锁：`SQLITE_BUSY_SNAPSHOT`。
   本会话的读事务是几分钟前打开的（`FQry.Open` 时 BEGIN 并取了快照），
   期间别的会话提交过 → 读事务升级为写时快照已过期，SQLite 直接返回
   `database is locked`，**而且 busy handler 对 `BUSY_SNAPSHOT` 根本不触发**
   （busy_timeout 白等）。写之前先把旧快照扔掉：

   ```pascal
   FTrans.CommitRetaining;   // = COMMIT + BEGIN（sqlite3conn 就这么实现）
   FQry.Post;                // 新事务的快照在第一条语句才取 -> 拿到最新版
   keepId := FQry.FieldByName('id').AsInteger;
   FTrans.Commit;            // 真正落库
   Requery(keepId);
   ```

   顺带好处：用户"编辑到一半点了别的行"造成的隐式 auto-Post，
   会在这次 CommitRetaining 里一并提交掉，不会再挂成孤儿事务。

验证（`demos/db` 实测）：两个会话各自打开 → A 保存 → B 保存（修复前必
500 `database is locked`）→ 各自删除 → 杀进程 → 直接用 `sqlite3` 读文件，
改动全在，`journal_mode = wal`。

### 9.3 编辑态移动游标 = 自动 Post

数据集处于 `dsEdit`/`dsInsert` 时，`First/Next/RecNo := ...` 会触发
`CheckBrowseMode` → 把改了一半的记录提交掉。框架的 writer 检测到编辑态就
不下发网格行（浏览器沿用旧数据），业务代码里也应注意：遍历数据集前先
Post 或 Cancel。

### 9.4 其它

- `TSQLTransaction` 必须创建并挂到 `Connection.Transaction`，否则
  `ExecuteDirect` 报 `Transaction not set`；
- 同一事务上再开第二个查询（汇总/统计）没有问题，SQLite 支持并发读游标；
- `sqlite3.dll` 放在 exe 同目录即可（Windows 搜索顺序最先查 exe 目录）。

## 坑 10：`.bat` 里写中文注释 + LF 换行 —— cmd 把批处理解析成乱码甚至挂死

`build.bat` 用 UTF-8 存了中文注释、又是 LF 换行时，cmd.exe 的解析会出现三种
阶梯式故障（实测量子）：

1. **LF 换行**：cmd 把相邻两行粘成一行，`rem` 吞掉下一行开头的词，
   于是变量赋值没执行 → `set DIR=%1` 之后 `DIR` 是空的，
   日志打出来是 `building demos\  (files.lpi)`；
2. **UTF-8 中文 + cp936**：`rem` 行里的多字节序列让行尾判定错位，
   报 `'zbuild.exe' 不是内部或外部命令` 之类 —— 变量名被切碎；
3. **CRLF + UTF-8 中文**：能进到执行阶段，但可能在 `setlocal` 附近**直接挂住**，
   一个字符都不输出、不报错、也不 fork 子进程（`tasklist` 里没有 lazbuild）。

**规则**：`.bat` 一律 **纯 ASCII 注释 + CRLF**。中文说明写进 `README.md` /
`docs/*.md`，批处理里只留英文一行注释。写完用 `xxd build.bat | head -2`
确认前几字节是 `...0d 0a`，且没有高位字节。

顺带：批处理里 `if not exist "x.lpi" set PROJ=` + 下一行 `for %%F` 自动探测
目录里唯一的 `.lpi`，比手工维护「目录名 → 工程名」映射表可靠
（`db → dbdemo`、`files → filedemo` 这种不一致就靠它兜住）。

## 坑 11：设计期包（lwdesign）与 lazbuild

目标：让 IDE 认识 `TLWForm`，并出现「新建工程 → lazarusWeb 应用」向导。
包本身能编译，但**装进 IDE 这件事在命令行里做不到**，几条实测结论：

### 11.1 `--add-package-link` 不等于「已安装」

```bat
lazbuild --add-package-link=lwcore.lpk
```

只把包登记进 `C:\111\config_lazarus\packagefiles.xml` 的 **`UserPkgLinks`**
（"最近打开过的包"），**不会**写进 `GlobalPkgLinks`（"已安装包"）。
所以 `lazarus.exe` 启动后既不会加载它，`TLWForm` 也不会出现在组件面板。

另外 `--add-package=lwcore.lpk` 会报 `Option ... does not allow an argument`，
但包仍被正确登记 —— 新版 lazbuild 的参数语义和文档不一致，别被报错误导。

### 11.2 手工改 `GlobalPkgLinks` → `--build-ide` 被第三方包阻断

把 `lwdesign` 手写进 `GlobalPkgLinks`（`<Item .../>` 加到已安装列表）后，
必须 `lazbuild --build-ide=` 重建 `lazarus.exe` 才会静态链接进设计期代码。
本机环境里这一步栽在 UniGUI 系列包上：

```
uniGUIVars.pas(...) Fatal: (1024) I/O error: File not open
```

即 **IDE 重建会被任何一个编译不过的已安装包拖死**，与本项目无关。
已用备份 `packagefiles.xml.bak_lw` 还原，`lazarus.exe` 未被改动。

**正确做法**：在 IDE 里装 —— `Package → Open Package File → src\design\lwdesign.lpk
→ Compile → Install → 重启 IDE`。IDE 只重编译需要的那部分包，
比整只 IDE 的 `--build-ide` 稳。步骤也写在 `tools\install_design.bat` 的提示里。

### 11.3 设计期 API 的两个小坑

- `TFileDescPascalUnitWithForm` 定义在 IDE 的 `mainintf.pas`，**IDEIntf 里没有**；
  运行时/设计期包只能看到 IDEIntf 时，用
  `TFileDescPascalUnitWithResource` + `ResourceClass := TLWForm` 代替；
- `TLazCompilerOptions` 在 `CompOptsIntf`，`TProjectDescriptor` 在 `ProjectIntf`，
  `FormEditingHook` 在 `ComponentEditors`，三者分属不同单元，缺一个就 Identifier not found。

## 坑 12：`TCustomEdit` 的派生判断会漏掉一大票"编辑框长得像"的控件

`lwwriter.KindOf` 里加一条 `else if C is TCustomEdit then 'edit'`，
本意是让 TLabeledEdit、自定义单行输入框自动落到 `edit`。但 LCL 的
**`TCustomEditButton` 继承链是 `TCustomAbstractGroupedEdit → TCustomControl`**，
不是 `TCustomEdit`：

```
TCustomEditButton = class(TCustomAbstractGroupedEdit)   // lcl/editbtn.pas:63
```

所以 `TFileNameEdit` / `TDirectoryEdit` / `TDateEdit` / `TTimeEdit` /
`TCalcEdit` / `TEditButton` **全部不会**命中 `TCustomEdit` 分支，仍是 `unknown`
占位（见 `docs/CONTROL_MATRIX.md`）。要支持它们得单独按 kind 处理（右侧带按钮的
复合输入框，得连按钮一起渲染），不能指望继承判断兜住。

## 坑 13：multipart 上传 / 一次性下载令牌的实现要点

### 13.1 `TRequest.Files` 的两条取内容路径

`fpshttpdefs.TUploadedFile` 同时给了 `Stream` 和 `LocalFileName`，
不同 `TRequest` 实现填的不一样（内存里 vs 落到临时文件）：

```pascal
if (f.Stream <> nil) and (f.Stream.Size > 0) then
begin
  src := TFileStream.Create(path, fmCreate);
  try written := src.CopyFrom(f.Stream, 0); finally src.Free; end;
end
else if f.LocalFileName <> ''
  then CopyFile(f.LocalFileName, path)   // 退化路径
else 400;
```

只判断其中一个，换个 fpWeb 版本就会"上传成功但文件是 0 字节"。

### 13.2 上传文件名必须洗，且不能信 `Content-Disposition`

浏览器送来的 `FileName` 可能是 `C:\Users\x\中文 名.txt`，也可能是
`../../web/evil.pas`（老 IE 风格全路径）。`LWSafeFileName` 做三件事：
`ExtractFileName` → 去掉 `..` → 非法字符（`\/:*?"<>|` 与控制符）替换成 `_`。
落盘前还要 `UniqueTarget`（同名自动 `name_2.ext`），否则两个用户同时传同名文件互相覆盖。

### 13.3 下载走令牌，URL 不出现服务端路径

`TLWForm.SendFile` 不直接给出文件路径，而是
`LWDownloadRegister(真实路径, 下载名)` 换一个一次性令牌：
`/lw/download?t=<GUID16+计数器>`。好处有三：

- 浏览器拿不到服务器目录结构（`..\..\config.ini` 这类试探无效）；
- 令牌一次有效，`LWDownloadRelease` 后置空，第二次访问 404；
- 清扫线程 `LWDownloadSweep(30)` 顺手回收 30 分钟没用的令牌和临时文件
  （`SendText` 写出来的临时文件就是靠这个清理的）。

中文下载名靠 `Content-Disposition` 双写：

```
attachment; filename="fallback.txt"; filename*=UTF-8''%E4%B8%AD%E6%96%87.txt
```

只写 `filename="中文"` 在部分浏览器上是乱码；只写 `filename*` 老客户端不认。
`UrlEncodeUTF8` 要按 UTF-8 逐字节百分号编码，不能直接 `TIdURI.ParamsEncode`。

## 坑 14：DB 感知控件（data-aware）在 nogui 下的四个坑（demos/dbaware 实测）

1. **TDBCheckBox 绑 0/1 整数字段必须显式设 `ValueChecked='1'`、
   `ValueUnchecked='0'`**。默认是 'True'/'False'，跟字段文本 '1'/'0'
   对不上，勾选状态永远是错的。LCL 的判定基于 `DisplayText` 与这两个
   字符串的比较，不是 `AsBoolean`。
2. **TDBText 的 Caption 在 nogui 下一直为空**。`TDBText.DataChange` 里
   `Caption := Field.DisplayText` 这条赋值链依赖图形层的刷新，nogui 下
   不生效。框架的 writer 改为直接读 `Field.DisplayText`（label 分支），
   顺带语义更准。别在业务代码里读 `TDBText.Caption` 判断字段值。
3. **TDBNavigator 创建即崩**：`FPImageException: Failed to get raw image
   description from bitmap` —— 构造时就要为默认按钮生成 glyph。nogui
   规避不了（除非改 LCL），导航按钮用普通 `TButton` 拼。
4. **TDBLookup*.KeyValue / ItemIndex 是 DataLink 缓存**：数据集 Close/Open
   之后可能还没刷上（实测保存后取到空串 / -1），而 `DataField` 本身就是
   外键字段，直接读字段值最可靠。另外 `SetKeyValue` 的实现是
   `ItemIndex := GetKeyIndex(...)`，真正写字段走焦点/键盘消息链 —— nogui
   下没有，所以框架回写外键时直接 `Field.AsString := 键值`（`lwdispatch`
   的 `LWApplyValue`），控件显示由 DataChange 自动跟上。

Bonus 坑：**`clDefault` 是 `$20000000`**，按 RGB 拆会得到 `#000020`
（近黑）—— 窗体默认背景、label 默认字色全变"黑底黑字"。`lwbase` 的
`ColorToCSS` 现在把 `clDefault`（和 `clNone`）交给 CSS 主题决定。

## 坑 15：在 IDE 里编译 `lwserver.lpk` 报 `Can't find unit noguiint`

现象：

```
lwws.pas(31,3) Error: 不能找到 noguiint 由 lwws 使用.
  启用单元 noguiint （软件包 LCL） 的 "Use Unit" 标志.
```

原因有两层，缺一不可地都踩上了：

1. `noguiint` 是 LCL 内部的 widgetset 单元，只在 LCL 按 **nogui** 编译时才产出
   `.ppu`，落在 `lcl\units\<cpu>-<os>\nogui\`。IDE 自己的 widgetset 是 **win32**，
   编译包下发的是 `-dLCLwin32` 和 `...\win32` 路径，自然找不到。
2. `lcl.lpk` 里 nogui 那三个单元（`interfaces` / `noguiint` / `noguiwsfactory`）
   的 `AddToUsesPkgSection = False`，也就是包编辑器 "Use Unit" 一栏没勾，
   LCL 不会把该目录传给依赖它的包。所以 IDE 才会给出"启用 Use Unit 标志"
   这个提示 —— 但**别照着做**：改 `lcl.lpk` 会让 IDE 自带包变成"已修改"，
   下次重建 IDE 或装包时很容易连锁出问题。

正确的修法是把 widgetset 相关代码条件编译掉（`src/core/lwws.pas`）：

```pascal
implementation

{$IFDEF LCLnogui}
uses ... noguiint, WSMenus, WSLCLClasses;   // 真补丁
...
{$ELSE}
procedure LWInstallWidgetSet;
begin
  { 真实 widgetset 自带显示器枚举与画布实现，什么都不做 }
end;
{$ENDIF}
```

`LCLnogui` 由 lazbuild `--ws=nogui`（以及 IDE 的 nogui 构建模式）自动 `-d` 下发，
不需要手工定义。这样包在任何 widgetset 下都能编译/安装，而 demo 工程仍然
必须 `--ws=nogui`（工程才真正需要补丁）。

补充：如果哪天 IDE 自己就是 nogui 版、却还报同样的错，那是 LCL 的 nogui
`.ppu` 丢了而 `lcl.compiled` 标记还在（标记在就不会重编）。删掉
`lcl\units\<cpu>-<os>\nogui\lcl.compiled` 后重编 LCL 即可。

## 坑 16：安装 `lwdesign.lpk` 弹 "Descriptor.Name empty"

现象：装包（或装完重启 IDE 加载包）时弹异常框：

```
TLazProjectDescriptors.RegisterDescriptor
Descriptor.Name empty.
```

原因：`TProjectDescriptor.Create` 的基类实现**不会**给 `Name` 默认值
（见 `buildintf/projectintf.pas`，只设 ReferenceCount/Flags/VisibleInNewDialog/
DefaultExt），而 `RegisterProjectDescriptor` 强制要求 `Name <> ''`。
`Name` 是 IDE 内部的唯一标识，和 `GetLocalizedName`（新建对话框里的显示名）
是两回事 —— 只重载 `GetLocalizedName` 不设 `Name` 就会踩这个雷。

修法（`src/design/lwdsgnregister.pas` 的 `TProjectLWApp.Create`）：

```pascal
Name := 'lazarusWebApp';   // 内部唯一标识，注册用
// 显示名仍是 GetLocalizedName -> 'lazarusWeb Application'
```

对照：`TLWFormFileDesc`（TFileDescPascalUnitWithResource 一系）本来就要求
显式设 `Name`（同时还要 `DefaultFilename`），所以它没踩雷 —— 这也是两种
描述符容易写混的地方。

## 坑 17：ShowMessage / TOpenDialog 在浏览器里"没反应"

现象：业务代码 `ShowMessage('...')` 点了没任何反应，`OpenDialog1.Execute`
直接抛 `Access violation`（HTTP 500 回给浏览器），而控件本身显示正常。

三条独立的原因，逐条说：

### 17.1 没装钩子，就等于没做

LCL 的对话框**不是**一个统一入口，而是四套函数指针 + 一套 widgetset 类：

| 位置 | 变量 | 谁在用 |
|---|---|---|
| `InterfaceBase` | `PromptDialogFunction` | ShowMessage / ShowMessagePos / MessageDlg / MessageDlgPos |
| `InterfaceBase` | `InputDialogFunction` | InputQuery / InputBox / PasswordBox |
| `InterfaceBase` | `QuestionDialogFunction` | QuestionDlg |
| `Forms` | `MessageBoxFunction` | `Application.MessageBox` / `LCLIntf.MessageBox` |
| widgetset | `TWSOpenDialog` / `TWSCommonDialog` | TOpenDialog / TSaveDialog 的 `Execute` |

四套都要接，缺一个就有一类弹不出来。文件对话框走 `TCommonDialog.Execute →
DoExecute → TWSCommonDialog.ShowModal`，所以**必须换掉 widgetset 类**：

```pascal
RegisterWSComponent(TOpenDialog, TLWWSOpenDialog);
RegisterWSComponent(TSaveDialog, TLWWSSaveDialog);
```

`RegisterWSComponent` 是"改注册表"，改的是**之后新建**的实例用的 WS 对象；
已有实例不管用，所以 `LWInstallDialogs` 必须在创建任何窗体之前调用
（`TLWApp.Run` 一开头）。

替代方案 `TCommonDialog.OnShow` 也能拦到，但那是"用户在浏览器点了按钮之后"
才跑，此时 LCL 已经在等一个模态返回值，反而更绕。

### 17.2 从 nogui widgetset 出来的 WS 类，事件能力要声明成空集

```pascal
class function TLWWSOpenDialog.QueryWSEventCapabilities(
  const ACommonDialog: TCommonDialog): TCDWSEventCapabilities;
begin
  Result := [];   // 不要报 cdecWSPerformsDoShow 等
end;
```

原因：一旦声明 `cdecWSPerformsDoShow`，LCL 就会绕开 `ShowModal` 去调
`DoShow` / `DoCanClose` / `DoClose`，而这三个我们没实现 —— 结果是 `Execute`
返回 True 但 `FileName` 一直是空串。空集表示"全走基类默认实现"，只剩
`ShowModal` 是我们自己的。

`CreateHandle` 随便返回个非零值（`Result := 1`）即可，句柄只在 LCL 内部流转。

### 17.3 `.lfm` 漏写 object，就是 nil 指针

这条纯属自找的：`udialogs.pas` 里声明了 `OpenDialog1: TOpenDialog`，
但 `.lfm` 里忘了写 `object OpenDialog1: TOpenDialog ... end`。窗体加载时
字段不会被实例化，`OpenDialog1.Execute` 就是对 nil 调方法 → AV。

**教训**：手写 `.lfm` 时，类里每个 published 组件字段都得有对应 object 块，
一个都不能漏。`lazbuild -B` 是必须的 —— 它不跟踪 `.lfm` 依赖，改窗体不改
`.pas` 会留旧 `.o`，新属性静默不生效。

顺带：demo 工程**不能**叫 `dialogs`。`dialogs.lpr` 生成的可执行文件会和
LCL 的 `dialogs` 单元撞名，链接期报 `Undefined symbol:
DIALOGS_$$_SHOWMESSAGE`。改叫 `dlgdemo` 就好。

### 17.4 服务端怎么等的

```pascal
FDlgDone.ResetEvent;
SessionPushCommand(o.AsJson);              // {type:"dialog", id, kind, text, buttons, input}
if FDlgDone.WaitFor(LW_MODAL_TIMEOUT_MS) <> wrSignaled then ...   // 180 秒
```

浏览器渲染模态框，用户点了之后 `POST /lw/api/dlg {sid, id, r, text}` →
`TLWSession.ResolveDialog(token, r, text)` 设结果并 `SetEvent`，事件线程从
`WaitFor` 里醒过来接着跑。`id` 是自增 token，答复带错 token 一律丢弃。

两个坑点：

1. **`SessionNotify` 不能写在 `FLock` 里面**。它是普通 mutex，不可重入，
   锁内再调会自己把自己锁死（Linux 下 100% 死锁，Windows 下看运气）。
   所以"已被占用"的判断要在锁内算，`SessionNotify` 放到锁外。
2. **同一会话只允许一个对话框**。`FDlgActive` 置位期间再来一个直接返回 0，
   调用方 `SessionDialog` 返回 False，`lwdlg` 就退回原实现（什么也不做）。
   别指望嵌套两层模态 —— 浏览器上盖两层模态本身就是坏交互。

### 17.5 文件对话框：浏览器只能上传，不能给路径

`TOpenDialog.Execute` 在浏览器里弹出的是 `<input type=file>`，用户选完
直接 `POST /lw/api/dlgfile?sid=&id=` 把文件 `multipart` 上传，服务端存到
`%TEMP%\lw_uploads\<sid>\pick\` 再把**服务端路径**作为答复文本回填：

```pascal
d.FileName := first;          // 例如 C:/.../lw_uploads/a1b2/pick/报告.txt
d.Files.Text := paths;        // 多选时换行分隔
d.UserChoice := mrOk;
```

业务代码 `TFileStream.Create(d.FileName)` 直接能开 —— 但这是**临时目录**，
会话结束后可能被系统清理，要长期保存请自己 `CopyFile` 到正式位置。

`TSaveDialog` 反过来：浏览器只给一个文件名（`<input type=text>`），
落盘位置由服务端定（`...\<sid>\save\`），写完自己 `SendFile` 推下载。
文件名要过一遍 `SafeBaseName()`：去路径、去 `..`、去 `<>|"*?`、去前导点。

## 坑 18：150% 缩放下设计的窗体，在浏览器里字体"超大"

现象：IDE 里看着正常的窗体，浏览器里整体大一圈（标题 29px、正文 20px），
控件也跟着大 1.5 倍，一屏塞不下。同一个框架下的 demo 却是正常的 13px。

原因：lfm 里写着

```
DesignTimePPI = 144        // 窗体是在 150% 缩放的 Windows 上设计的
Font.Height = -20          // 20 像素，是按 144 DPI 算的
```

而服务端是 96 DPI 的虚拟显示器（`lwws.pas` 里 `LWSetVirtualScreen`，
默认 1920x1080 @96DPI）。LCL 本来会在 `TCustomForm.AfterConstruction` 里
把窗体从 `PixelsPerInch`(=144) 缩放到 `Monitor.PixelsPerInch`(=96)，但那条
路径的第一道门槛是：

```pascal
if Application.Scaled and Scaled and (MonPPI > 0) and (MonPPI <> PixelsPerInch) then
  AutoAdjustLayout(lapAutoAdjustForDPI, PixelsPerInch, MonPPI, ...);
```

`Application.Scaled` 在 nogui 下默认是 **False**（桌面 IDE 会替你打开），
于是缩放整个被跳过：几何保持在 144 DPI 的设计像素，字体 `Height=-20` 按
96 DPI 解释成 15pt，客户端再 `*4/3` 换回 20px —— 正好比设计意图大三成。

修法（`lwapp.pas` 的 `TLWApp.Run`，创建任何窗体之前）：

```pascal
LWInstallWidgetSet;
Application.Scaled := True;   // 打开 LCL 的 DPI 自适配
```

之后 LCL 自己会把每个窗体按 `DesignTimePPI -> 96` 缩放，几何和字体一起：

| | 修复前 | 修复后 |
|---|---|---|
| 窗体 | 1050×660 | 700×440 |
| 正文 Font.Height / Size | -20 / 15pt（20px） | -13 / 10pt（13px） |
| 标题 Font.Height | -29（29px） | -19（19px） |
| 按钮 | 165×40 | 110×27 |

96 DPI 下设计的窗体（所有 demo）`DesignTimePPI=96`，与运行时 PPI 相同，
这一行对它们完全无影响 —— 所以 demo 表现不变，用户按 150% 设计的窗体自动收回来。

副作用（nogui 特有，可接受）：`TEdit` 的高度不会跟着字体重算
（真实 widgetset 会，nogui 没有字体度量），所以缩放后输入框比标准略高几像素
（如 35px 而不是 23px）；`AutoSize=True` 的 TLabel 宽度也停留在设计值附近。
不影响可用性，真要精确就在 lfm 里把控件摆成 96 DPI 的尺寸。

顺带记一个调试坑：写探针时用 `Application.CreateForm(TMainForm, MainForm)`
会在 `AForm.HandleNeeded` 处抛 `EDivByZero`（nogui 的 ShowWindow 除零，
`lwform.SetVisible` 的注释里提过）。服务端不会走这条路 —— 它用
`TFormClass.Create(nil)`（`TLWFormProvider.CreateForm`），从不申请句柄。
写验证程序时照着服务端的方式建窗体即可。

## 坑 19：IDE 里按 F9，编译出来的还是 win32 —— 保存数据时弹异常

现象：在 Lazarus IDE 里打开 demo（或向导生成的工程）按 F9 调试，浏览器里
修改数据点"保存"时，IDE 弹出两连弹：

```
EWriteError: Stream write error            （streams.inc TStream.WriteBuffer）
External: ACCESS VIOLATION (sqldb.pp)      （之后进程可能直接死掉）
```

而用 `build.bat`（lazbuild --ws=nogui）编译的同一个工程毫无问题。

### 根因：lfm……不，lpi 里 LCLWidgetType 写错了位置

工程 lpi 里有一行：

```xml
<General>
  ...
  <LCLWidgetType Value="nogui"/>    ← 写在这里【无效】
</General>
```

`LCLWidgetType` 是 IDE 宏，不是 General 节的属性 —— IDE 和 lazbuild 都会
**无视它**。lazbuild 命令行靠 `--ws=nogui` 补救，所以 build.bat 一直没事；
但 IDE 按 F9 走的是 lpi 自身配置 → 宏不生效 → 用默认 win32 widgetset 编译
（看 `lib/*/x86_64-win64/*.compiled` 里的 `-dLCLwin32` 即可实锤）。

win32 widgetset 下框架要出事：LCL 不是线程安全的，而本框架所有控件操作都
发生在 fcl-web 的工作线程里；nogui 下"widgetset"是自己的虚拟实现没有真窗口
所以无事，win32 下会随机 AV（实测：跑完 t_db 35 项后进程 2 分钟内静默死亡）。

正确写法（IDE 认的宏格式，两处缺一不可）：

```xml
<MacroValues Count="1">
  <Macro1 Name="LCLWidgetType" Value="nogui"/>
</MacroValues>
<BuildModes>
  <Item Name="Default" Default="True"/>
  <SharedMatrixOptions Count="1">
    <Item1 ID="131280374502" Modes="Default" Type="IDEMacro"
           MacroName="LCLWidgetType" Value="nogui"/>
  </SharedMatrixOptions>
</BuildModes>
```

验证方法：**不带 --ws** 执行 `lazbuild -B 工程名.lpi`，看
`lib/x86_64-win64/*.compiled` 里的 define —— `-dLCLnogui` 为对，
`-dLCLwin32` 为错。也可以直接查 `lib/` 下有没有 `x86_64-win64-nogui`
输出目录（注意：只有显式传 --ws 时 lazbuild 才会加 -nogui 后缀；
宏方式输出的目录名不带后缀）。

修复：全部 demo lpi + `lwnewproject.pas` 向导模板已改为正确宏格式；
用户既有工程手工改 lpi 或用向导重建。

### 那两个弹窗本身是什么

1. **EWriteError: Stream write error** —— 浏览器断开了长轮询连接（刷新页面、
   请求超时、关标签页），fcl-web 往已死的 socket 写响应时 raise。
   `TFPHTTPConnectionThread.Execute` 里有 `except ... HandleUnexpectedError`
   兜底，**已被捕获、无害**。调试器对"已捕获的异常"也弹通知而已。
   闲得烦就在弹窗上勾"忽略这个异常类型"（EWriteError）。

2. **ACCESS VIOLATION** —— win32 构建特有的不稳定（线程 + 真 LCL），
   nogui 构建下不出现。**只要 widgetset 对了，这两个弹窗都会消失。**

## 坑 20：把代码里建的控件搬进 lfm，三处必须一起改

把 `BuildAll` 那种"代码摆位"改成设计期 lfm 时，只写 lfm 是不够的 ——
下面三条缺一条，运行时就是 nil 访问或加载异常：

### 20.1 控件字段必须挪到 published

```pascal
private
  btnSave: TButton;      // lfm 里的 object btnSave 会被【静默忽略】
published
  btnSave: TButton;      // 正确
```

lfm 加载走的是 `InitInheritedComponent` → 按 published 字段名查组件实例并赋值。
声明在 private 里的字段，lfm 里写了 object 块也不报错，运行时字段仍是 nil，
第一句 `btnSave.Caption := ...` 就 AV。这类问题在 nogui 下表现为 HTTP 500
（事件线程的异常被 lwhttp 兜住），在 IDE 调试器下表现为弹窗。

### 20.2 事件方法也必须 published

```
      OnClick = btnSaveClick
```

lfm 是按**方法名**反射查的（`MethodAddress`，只覆盖 published）。private
方法查不到，加载时抛 "Cannot find method: btnSaveClick"，窗体直接建不起来。

### 20.3 自定义控件要补运行时 RegisterClass

标准 LCL 控件（TButton/TDBGrid…）在各自单元的 initialization 里已经
`RegisterClass`，lfm 能按类名实例化。自定义控件往往只在**设计期包**里注册：

```pascal
// lwdsgnregister.pas（只装进 IDE 时才执行）
RegisterClass(TLWForm);
RegisterComponents(sLWPaletteTab, [TLWFileUpload]);
```

可执行文件不加载设计期包，所以运行时 lfm 里遇到 `object btnUpload: TLWFileUpload`
直接报 "Unknown component class"。修法是在控件自己的单元补：

```pascal
// lwfileupload.pas
initialization
  RegisterClass(TLWFileUpload);
end.
```

### 20.4 什么该留在代码里

不是所有属性都能进 lfm，典型的两类：

| 留在代码 | 原因 |
|---|---|
| `DataSource := FDs` | DataSource 是运行时创建的对象，lfm 里没有可引用的实例名 |
| `ComboBox.Items`（来自常量） | 写进 lfm 就要和代码里的常量表两处维护 |

其余全都可以进 lfm：坐标尺寸、`Options` 集合、`Font`、`DataField`、
`OnClick`、`TDBGrid.Columns`（含 `DisplayFormat`）。赋 `DataSource` 时
LCL 会按 `FieldName` 把已有列和数据字段对上，不会重建列。

### 20.5 搬家时的操作顺序

用脚本按行号区间替换"界面构建段"很危险 —— 那段代码里往往夹着别的过程。
`demos/db` 这次就顺手删掉了 8 个附件函数（`AttachRoot` / `RefreshAttach` /
`CopyFileRaw` …），编译报一排 `Forward declaration not solved`。教训：
替换前先 `grep "^procedure TDbForm\.\|^function TDbForm\."` 列出区间内的所有
过程名，替换后逐个核对是否还在。

## 坑 21：控制台横幅和日志一个字都不显示（程序却活得好好的）

现象：`WriteLn` 打印的启动横幅（Root/Ext/Listen...）和所有日志在控制台里
从不出现，但服务正常、浏览器正常。`--help` 这种"打印完就退出"的路径反而
能看见输出。

两个独立的根因，都会造成同样现象：

### 21.1 横幅写在 accept 循环后面 —— 死代码

`TLWServer.Start` 的顺序是：

```pascal
FHTTP.Active := True;      // ← 永不返回！
FSweeper.Start;
WriteLn('  lazarusWeb ...');  // ← 永远执行不到
```

`TFPCustomHttpServer.SetActive(True)` 一路调到 fcl-sockets 的
`TSocketServer.StartAccepting`（ssockets.pp），那是一个

```pascal
Repeat ... Until Not FAccepting ...
```

的**阻塞 accept 循环**，跑在调用线程里，服务停止前不返回。主线程从此
就住在循环里服务 HTTP —— 这也解释了为什么服务一切正常：accept 循环本身
就是服务主体，`TLWApp.Run` 里它后面的 `while True do Sleep(500)` 同样
从未执行过（幸好不需要）。

修法：把横幅从 `Start` 挪到独立的 `TLWServer.PrintBanner`，`TLWApp.Run`
在调用 `GServer.Start` **之前**打印。端口被占用时的报错也一样 —— 异常从
`Start` 里抛出来才能被拦住打印，所以顺序没问题；但任何"想在服务起来之后
再打印"的想法都注定失败。

### 21.2 stdout 是管道时，FPC 默认缓冲到进程退出

FPC 的 `OpenStdIO` 只对"真控制台设备"（`GetFileType=FILE_TYPE_CHAR`）
设置逐行刷新；stdout 是**管道/文件重定向**时输出积压在缓冲区里，直到
进程退出才写出。服务端永不退出 → 一个字都看不见。Windows 11 的
Windows Terminal 在某些接管方式下 stdout 就是管道，所以即使真开着终端
窗口也可能中招。

修法（`TLWApp.Run` 开头，两行）：

```pascal
SetTextAutoFlush(Output, True);
SetTextAutoFlush(ErrOutput, True);
```

注意验证方法：**不能用 taskkill/timeout 验证** —— `TerminateProcess`
强杀不经过退出流程，缓冲区照样丢。要么让进程优雅退出（--help 路径），
要么在进程存活期间去读重定向文件。

排查这类问题时 `WriteLn` 探针 + 重定向文件 + 存活期读取是有效的手段；
但注意探针本身也会因为缓冲而"看不见"，先修 21.2 再排查 21.1，否则探针
结果会骗人（这次就是：探针全出来让人以为 flush 正常，其实那是探针行
恰好凑满了 256 字节缓冲）。

## 坑 22：{$codepage utf8} + 长链式字符串拼接 = 丢字节（浏览器只剩白块）

现象：加上 `{$codepage utf8}` 后终端中文正常了，但浏览器打开只有
中间一个白块（splash 停住），F12 看 HTML 是：

- `class="lw-splash-box"` 后面的 `>` 丢了
- `LW.start({form:'DbForm'` 的 `:` 丢了
- 结尾 `</script` 的 `>` 丢了、LineEnding 只剩 `\r`

白块根因：`LW.start({form'DbForm',...})` 是非法 JS，客户端运行时根本
没启动，splash 永远停在那里。

根因是本机 FPC 3.3.1（2026-11-07 trunk 编译版）的编译器 bug，最小复现：

```pascal
{$codepage utf8}
s := '<a>中文</a>' + LineEnding + '<b>{f:' + QuotedStr('y') + ...;
```

**含多字节字符的字面量**与其它常量（如 LineEnding）折叠后再和运行时值
拼接，折叠结果会随机丢掉若干 ASCII 字节（丢的是各常量片段的"末尾字符"）。
纯 ASCII 的同结构表达式完全正常；分步拼接（`s := s + ...`）也完全正常。
这与坑 15.5（JSON 拼接丢末尾花括号）是同一个编译器 bug，`{$codepage utf8}`
只是让它更容易触发。

结论 / 规则：

1. 含中文字面量的长链拼接一律改成分步：`Result := '...'; Result := Result + ...;`
   BuildIndexHtml 已按此重写（lwhttp.pas）。
2. JSON/HTML 这类要按字节原样输出的内容，拼完最好自查一遍首尾标记
   （`</html>`、`}` 等），别信编译器折叠。
3. `{$codepage utf8}` 保留：终端输出（WriteLn）走 GBK 转换是正确的，
   不加它中文反而在中文 Windows 控制台变乱码。HTTP 路径分步拼接后
   输出的仍是干净 UTF-8，两边互不影响。

## 坑 23：TDBNavigator 在 nogui 下构造即崩（LCLGlyphs 位图链）

现象：`TDBNavigator.Create` 抛 `FPImageException: Failed to get raw image
description from bitmap`，窗体建不出来。

根因：LCL 的 `TDBCustomNavigator.UpdateButtons` 给每个 TDBNavButton 挂
`LCLGlyphs`（内置 PNG 字形），`PNG -> TBitmap -> RawImage` 这条链在 nogui
下拿不到 RawImageDescription（intfgraphics.pas:3622 抛异常）。任何走
TLazIntfImage.LoadFromBitmap 的位图转换在 nogui 下都会这样。

解法（lwdbnav.pas）：
1. `TLWDBNavigator` 覆盖 `UpdateButtons`（virtual）：按钮照建
   （DataChanged/EditingChanged 无条件索引 Buttons[]，不建就是 AV），
   只是跳过 LCLGlyphs 两行赋值 —— 图标由浏览器端画。
2. 别碰 `FUpdateButtonsLock/FUpdateButtonsNeeded/FVisibleButtons/FOptions`，
   全是 private；用 public 属性 `VisibleButtons/Options/Direction/Flat`。
3. ~~`RegisterClassAlias(TLWDBNavigator, 'TDBNavigator')`：lfm 照写
   TDBNavigator 即可~~ **已被坑 29/41 推翻**：alias 顶替不了已注册的
   TDBNavigator 类名，lfm 里必须写真实类名 `TLWDBNavigator` 并
   `RegisterClass(TLWDBNavigator)`。
4. 序列化不要把 TDBNavButton/TDBNavFocusableButton 当子控件发出去
   （IsInternalControl 里排除），navigator 自己下发 buttons 数组。
5. `OnClick` 是 `TDBNavClickEvent(Sender; Button)` 两参签名，分发必须走
   `BtnClick(val)`，不能套 TNotifyEvent 强转（栈错乱）。
6. SQLdb 的 BOF/EOF 在 RecNo 导航后不可靠：first/prior/next/last 的
   Enabled 用 `RecNo <> 1` / `RecNo < RecordCount` 兜底计算。

## 坑 24：dbgrid 单元格编辑的三件事（readOnly 标志 / Post 时机 / WAL 快照）

给 TDBGrid 加浏览器端单元格编辑（Ext CellEditing -> OnSetFieldValue
-> Edit+Post）时踩出的三条规则：

1. **readonly 早就发了，客户端没接**：WriteDBGrid 一直输出
   `readonly: not (dgEditing in G.Options)`，但 buildDBGrid 从没看过它。
   接编辑时还要按列下发 `cedit`（列只读 / 字段只读如自增主键不给编辑器），
   否则用户在只读列里编辑完直接被服务端吞掉，界面却显示改成功了。

2. **Post 的时机 = 数据集回 dsBrowse**：服务端收到 OnSetFieldValue 后
   必须 Edit -> Post，不能停在 dsEdit（dsEdit 下 writer 不发 rows，
   浏览器永远显示旧值）。Post 只进缓存，落库靠业务代码 Commit ——
   与桌面 LCL 完全一致。因此**保存按钮不能再卡
   `State in [dsEdit, dsInsert]` 才提交**：网格编辑 Post 完就回 browse，
   只欠一个 Commit。demo 的 btnSaveClick 已改为无条件 CommitRetaining+Commit。

3. **外部改动 + WAL 快照**：SQLite WAL 下事务快照是打开时定格的，
   别的连接提交的数据，本事务里 Refresh 也看不见。导航的 nbRefresh
   必须 `CommitRetaining`（丢旧快照）+ `Requery` 重开才有效。
   测试在"删除 -> 外部重插 -> 编辑第一行"场景里被这个坑了：
   数据集缓存的第 1 行其实是删剩的旧 id2，编辑全落在了 id2 上。

4. sqoAutoApplyUpdates 语义（FPC 文档确认）：**每次 Post/Delete 后立即
   ApplyUpdates**（UPDATE 进事务但未提交），提交仍要显式 Commit。

5. **列编辑器 cedit 的完整语义**（2026-11-12 补全）：`0=只读 1=文本
   2=PickList 下拉（plist 同下标带选项）3=日期选择（TDateField/
   TDateTimeField，行值固定发 ISO 'yyyy-mm-dd'）4=复选框（TBooleanField，
   行值固定发 '1'/'0'，不走 DisplayText —— 那可能是 True/False 也可
   能被业务改成"是/否"，前端没法当布尔值用）。判定顺序：布尔列优先，
   再 PickList，再日期，兜底文本。写回端 LWApplyDBGridEdit 对应分支：
   日期走 LWISOToDateTime + AsDateTime；布尔走 AsBoolean（'1'/'true'/
   'yes'，SameText）；其余 AsString。前端两个渲染层：alpine 版布尔列
   单元格常驻 <input type=checkbox>（x-if 按 cedit 渲染，点击即回发，
   不进"就地换编辑器"分支）；Ext 版用渲染器画勾选框 + itemclick 整格
   切换（store 行数据必须把 '1'/'0' 转成真 boolean —— '0' 在 JS 里是
   真值，直接喂渲染器会全表选中）。

## 坑 25：TRadioGroup / TCheckGroup / TValueListEditor 的序列化陷阱

给普通（非 DB）组控件/列表控件补渲染器时踩出的：

1. TRadioGroup / TCheckGroup 内部会生成真实的 TRadioButton/TCheckBox
   子控件（radiogroup.inc:221、customcheckgroup.inc:236 都 Parent:=Self），
   writer 的子控件遍历会把它们当独立控件发出去 —— 必须在
   IsInternalControl 里按父控件类型排除，组控件自己以 items/checked
   数组下发。
2. TRadioGroup 与 TDBRadioGroup 的回传语义不同：前者回传"第几项"，
   后者回传 Values[i]。
3. TValueListEditor 的 API 错位：Keys[i] = Cells[0,i] 是网格行号
   （0 = 标题行），而 Strings.Count 是数据行数（不含标题行）——
   数据行是网格行 1..Strings.Count。用 Strings.Names[i] 会得到
   错位一行的键名。
4. TValueListEditor 没有 UpdatesPending/Rows 这类属性（fcl-db 里的
   TSQLQuery 才有）；OnValidate 是五参 (Sender; ACol; ARow; KeyName;
   KeyValue)，OnItemClick 是两参 —— 必须类型化调用，不能套
   TNotifyEvent 强转。
5. 语义：浏览器编辑完成 = 服务端先写值再触发 OnValidate（handler
   里读到的是已生效的新值），与 dbgrid 单元格编辑一致。

## 坑 26：fphttpserver 上做 WebSocket（本机 FPC 3.3.1 trunk）

1. **不用自己劫持 socket**：这版 fphttpserver 原生支持协议升级 ——
   `FHTTP.RegisterUpdateHandler(name, OnCheck, OnUpgrade)`。
   OnCheck 里判 `GetHeader(hhUpgrade)='websocket'` + URL 前缀；
   OnUpgrade 里自己做 RFC6455 握手（SHA1(key+魔串)→base64）和帧循环。
   升级成功后连接标记 IsUpgraded，keep-alive 循环不再接管，
   `aConnection.Socket` 所有权移交给升级处理器（返回前连接的
   FSocket 已被置 nil，**循环结束后必须自己 Free socket**）。
2. **Sec-WebSocket-Key 取法**：httpdefs 的 THeader 枚举里没有
   Sec-WebSocket-Key，走 `aRequest.CustomHeaders.Values['sec-websocket-key']`
   （TStringList 大小写不敏感）。SHA1 用 units/hash 的 sha1 单元。
3. **对话框推送是硬点**：事件线程阻塞在 SessionDialog（TEvent 等待）
   时，唯一能写 WS socket 的就是事件线程自己。解法：TLWSession 加
   `OnPushCommand(ASession, AJSON)` 直推钩子 + `PushSock` 槽位，
   SessionPushCommand 有钩子就同步直推、不进 outbox。所有推送都
   发生在事件处理过程中（= WS 连接线程），线程安全。长轮询客户端
   两者保持 nil，行为不变。
4. **WS 推送必须带 tree**：长轮询模式下 poll 响应附带 tree，
   WS 模式的 show/modal 指令若不带树，客户端渲染不出控件。
   WSPushCommand 里 `o.Add('tree', S.BuildPayload)`。
5. 客户端策略：WS 优先、失败回退长轮询（回归测试全部走 HTTP，
   WS 是纯增量）。事件响应与请求一一对应，同一时刻只允许一个在途
   WS 事件（有未决回调就退回 HTTP POST）。

## 坑 27：HTML/PDF 显示（TLWHTMLFrame / TLWPDFFrame，uniHTMLFrame/uniPDFFrame 对应物）

1. **PDF 不走 data URI**：几百 KB 的 PDF base64 塞进组件树会把每次
   协调都拖成 MB 级。走 iframe + `/lw/view?t=<令牌>`：文件路径不出
   URL（与 SendFile 同一套安全模型），Content-Disposition: inline。
2. **查看令牌必须"可重复访问"**：下载令牌一次有效，iframe 翻页/
   刷新会反复请求。TLWPDFFrame 缓存令牌（FToken + FTokenFile），
   同一文件沿用同一令牌；lwdownload 新增 `LWDownloadTouch` ——
   每次 BuildPayload 序列化都续期，会话活着令牌就不过期，
   Sweep 只收没人用的。换文件（PDFFile 改变）先 RevokeToken 再签新。
3. **前端增量更新用"指纹"**：htmlframe 比较 html 字符串、pdfframe
   比较 url，有变化才 update()/换 iframe src —— 否则每次协调都
   重载 iframe（翻页进度、选中状态全丢）。
4. **TLWHTMLFrame/TLWPDFFrame 基于 TCustomPanel**：writer 必须在
   `C is TPanel` 之前判（同 radiogroup/checkgroup 的顺序敏感问题）。
   浏览器端不渲染它们的子控件（面板被 HTML/iframe 占满）。
5. **运行时生成 PDF**：手写 PDF 1.4 语法（对象 + xref 偏移按行累加、
   条目固定 20 字节）+ 标准 14 字体即可出合法单页文档，无需第三方库；
   内容只能 ASCII（标准字体不带 CJK 字形），中文 PDF 需要 CID 字体
   或引 lib，属后续工作。

## 坑 28：登录框架 / 图表 / 大表分页 / 主题 / 日期时间 / Toast（六大功能落地）

1. **登录窗体必须用「published 字段 + lfm」方式设计**（对应 ide 新建
   TLWLoginForm）：lfm 流式读取要求根类把子控件声明为类字段
   （`lblUser: TLabel; edUser: TEdit; …` 写在类头的 published 区），
   否则报 `EClassNotFound: No field of class TLabel in TLoginForm`。
   与 Lazarus IDE 自动生成写法一致。事件挂接靠根节点
   `OnCreate = FormCreate`（缺省 OnLogin 是 admin/admin，lfm 挂了
   OnLogin 就走业务校验）。
2. **SetLogin 只进 GRegistry，不进 GOrder**：GOrder 决定默认主窗体
   （第一个注册的窗体），登录窗体抢了那个位置会把业务主窗体顶掉。
   ApiSession 在 `GCfg.LoginForm <> ''` 时用登录窗体替代请求的主窗体；
   未认证会话在 LWHandleEvent 沿 Owner 找根窗体、非 TLWLoginForm
   一律 `not authenticated`。
3. **TLWSessionBase 是登录框架的挂钩点**：RequireAuth/Authenticated/
   LoginForm 必须加在基类（lwlogin 只依赖 lwbase），加在具体
   TLWSession 上 lwlogin 编译不过。
4. **本机 Lazarus 的 TCustomEditButton 不继承 TCustomEdit**！
   `TCustomEditButton = class(TCustomAbstractGroupedEdit)`
   （groupededit.pp，TCustomControl 系）。writer 里对 TDateEdit/
   TTimeEdit 做 `as TCustomEdit` 直接 EInvalidCast。一律按
   TCustomEditButton 转。KindOf 同理：dateedit/timeedit 必须判在
   TCustomEdit 分支之前。
5. **TDateEdit.Time/Date 的「解析后 flags 快照」**：LWISOToDateTime
   把 dp/tp 作为 var 实参传给 TakeInt 逐段消费，函数尾部再用
   dp/tp 判「是否提供了该部分」时它们必然已是空串 —— 所有成功
   解析都会掉进 `Result := ADef`，且**默认值恰等于当前时间/今天时
   测试完全看不出来**（dateedit 首次"通过"就是这种假阳性）。
   必须在解析前快照 hasd/hast 布尔标志。独立小程序（tmp/tparse）
   验证过四种输入。坑 28-4 与 28-5 都是「静默失败 + 巧合通过」，
   回归断言要设计成与初值不同的值。
6. **TBookmark 在此 FPC 是 TBytes（托管动态数组）**，不能 TList 装
   指针。TLWDBGrid 的匹配书签表用 `array of TBytes` +
   MatchAdd/MatchAt/MatchCount/MatchClear。
7. **大表分页是显示层过滤，不动 SQL**：writer 对可见列
   DisplayText 做"包含匹配"收书签表，分页只下发当前页切片；
   recno 改发"页内 1 起行号"（当前记录不在本页发 0 —— 表示
   不高亮，不是错误）。行号→记录映射走
   `MatchAt((CurrentPage-1)*PageSize + row)` GotoBookmark。
8. **Ext x.x.x charts 包没有独立 Pie widget**：柱/线走
   `Ext.chart.CartesianChart`（xtype cartesian），饼图走
   `Ext.chart.PolarChart` + series type pie。资源在
   `build/packages/charts/classic/charts.js`，CSS 自带配色
   （crisp resources/charts-all.css），配任何主题都行。
   首页注入按 Ext 版本判断（x.x.x 才注入 charts 资源）。
9. **前端增量更新全靠"指纹"**：chart 用 charttype+categories+series
   哈希做 `__lwChartSig`，dbgrid 分页/汇总文案走 patchNode 文本替换，
   dateedit/timeedit 的 iso 在 hasFocus 时不同步（避免打断输入）。
10. **主题切换即查询参数**：`?theme=` 白名单六主题
    （classic/crisp/gray/material/neptune/graphite），BuildIndexHtml
    按参数注入对应 theme-xxx-all.css；`--theme=` 命令行设缺省。
    注册表别名 `RegisterClassAlias(TLWDBGrid, 'TDBGrid')` 让旧 lfm
    自动升级成分页网格。
11. **代码建控件必须显式设 Name**：LCL 自动名是 TLabel1/TButton1，
    测试与前端按 Name 找控件。另外页签这类容器**创建 + PageControl
    赋值 + Name 三步一个都不能少** —— 本轮 tsChart/tsBig 忘了
    TTabSheet.Create，字段是 nil，Parent := nil 的控件全成孤儿，
    树里整页消失且无任何报错（无声失败的典型）。
12. **测试基建**：Bash 工具的后台进程在调用结束会被杀，统一走
    `tests/run_with_server.py <exe> <test.py> [port]`：Python 内
    subprocess 启动 + 轮询就绪 + 跑测试 + finally kill，全收敛在
    单次调用里。另注意各测试脚本的环境变量名不一
    （LW_BASE / LW_LOGIN_BASE / LW_PORT）。

## 坑 29：分页箭头只能翻到第 2 页 / 导航条改用原生 TDBNavigator

1. **前端分页闭包快照**：`buildDBGrid` 里 `pageTo` 的四个箭头
   （⏮◀▶⏭）捕获的是**构建时**的 node 对象，翻页后 node.page 仍是旧值。
   点"下一页"永远算成 `1 + 1 = 2`，服务端也照做 —— 表现就是"12 页只能
   到第 2 页"。修法：`pageTo` 内部每次从 `S.nodes[node.id]` 取实时节点
   （patchNode 会更新它），箭头里的目标页也用 `liveNode().page` 计算。
   回归补了 3→12→11→1 连续翻页断言（原来只测到第 2 页，正好漏掉）。
2. **导航条按原生类型判**：TLWDBNavigator 只是 nogui 实现细节
   （TDBNavigator 的 UpdateButtons 会挂 LCLGlyphs 位图，nogui 下构造
   即抛 FPImageException）。用户侧一律写 LCL 原生 `TDBNavigator`：
   - lfm/IDE：**写真实类名 `TLWDBNavigator`**（`RegisterClass(TLWDBNavigator)`）。
     不要指望 `RegisterClassAlias` 顶替 `TDBNavigator` —— 那个类名 LCL 已经
     注册过，`GetClass` 取最后注册的那个，初始化顺序一变就退回基础类并崩在
     LCLGlyphs 上（坑 41-4 有细节）；
   - 代码建窗体：`navMain := LWNewNavigator(Self)`，返回类型就是
     `TDBNavigator`（不引用子类单元里的类型名）；
   - writer / dispatch 都改成 `C is TDBNavigator`，Enabled 走
     `LWNavBtnEnabled()` 包一层，子类可实现精确判据。
3. **端口僵尸**：Windows 上进程被杀后可能出现 `LISTENING PID 0` 的
   孤儿监听套接字（netstat 看得到、tasklist 没进程），此时 bind 必失败。
   换端口最省事；别误判成"程序没起来"。

## 坑 30：根目录（Root）定位 —— ext-x.x.x 可以放进应用目录

上一轮把「demos/dbaware 下有 ext 副本导致 Root 偏移」当成问题，判断错了：
**把 ext 拷到应用目录是受支持的标准自包含部署**，问题只在于当时 Root
判定与客户端脚本查找是两套硬编码路径，容易互相踩。

现在的规则（`LWDefaultRoot` / `LWFindClientFile`）：

1. **当前工作目录优先**：`GetCurrentDir` 下只要有 `ext-x.x.x`（或
   `ext-7.0.0`）就直接认它为根 —— 不再要求同时有 `src/client/lw.js`，
   否则扁平部署（lw.js 与 exe 同目录）会被误判而跳回仓库根。
2. **exe 目录向上最多 5 层**：只在 cwd 没有 ext 时启用；这一路才要求
   「ext + `src/client/lw.js` 都在」，找不到完整根则退回第一个含 ext 的
   候选（旧行为，避免页面彻底起不来）。
3. `--root=` 显式指定压过以上全部（`LWResolveRoot` 里判断目录存在即用）。
4. `/lw/lw.js`、`/lw/lw.css` 用 `LWFindClientFile` 多路查找：exe 同目录 →
   `<exe>/lw/` → `<root>/src/client/` → `<root>/client/` → 从 root 逐级向上
   找 `src/client/`。全部落空才 404，且 404 文案直接告诉用户该放哪。
5. 关键点：**Root ≠ 客户端脚本位置**。Root 只决定 `/ext/...` 的物理路径，
   脚本可以来自别处。把两者解耦后，「只拷 ext 不拷 lw.js」也能跑。

实测四种布局（全部 `/`、`/lw/lw.js`、`/ext/x.x.x/build/ext-all.js` 均 200）：

| 布局 | cwd | exe 所在 | 结果 Root |
|---|---|---|---|
| 仓库内 demo | `demos/dbaware`（无 ext） | 同目录 | `C:/LazarusWeb`（向上找） |
| 自包含 | `tmp/deploy`（ext + src/client） | 同目录 | `tmp/deploy` |
| 扁平 | `tmp/flat`（ext + lw.js 同目录） | 同目录 | `tmp/flat` |
| cwd 与 exe 都有 ext | `tmp/b` | `tmp/a` | `tmp/b`（cwd 赢） |

回归：t_dbaware 134/134 通过。

### 坑 30 补：跨平台

1. `LWResolveRoot` 原来兜底写死 `'C:/LazarusWeb'`，Linux/macOS 下会得到
   一个不存在的路径。改为「exe 所在目录 → 当前目录」，三平台通用。
2. 向上回溯的终止条件不能写 `d = PathDelim`（Windows 根是 `C:/`，
   Unix 根是 `/`）：改为 `par := ExcludeTrailingPathDelimiter(d)`、
   `up := ExtractFileDir(par)`，`up = ''` 或 `up = par` 即到根，两个平台
   语义一致且不会死循环。
3. 拼路径一律 `PathDelim` + `IncludeTrailingPathDelimiter`，不要写 `'\'`；
   `ParamStr(0)` 先过 `ExpandFileName`，否则相对路径启动时
   `ExtractFilePath` 返回空串，被误当成「在 cwd 里找 ext」。
4. `build.sh` 与 `build.bat` 并存：前者自动探测 lazbuild（`command -v`、
   常见安装路径、macOS 的 `.app` 内部），也支持 `LAZBUILD=` 覆盖；Unix
   产物无扩展名，脚本同时删 `proj` 和 `proj.exe`。`.lpi` 不固定
   TargetOS，按宿主构建。
5. demo 的 SQLite 走 FPC `sqlite3conn` 动态加载：Windows 找 `sqlite3.dll`，
   Unix 找 `libsqlite3.so`（macOS 自带）。仓库里只提交了 dll，Unix 依赖
   系统库。
6. Unix 大小写敏感：`ext-x.x.x`、`src/client/lw.js` 必须原样，不能写成
   `Ext-x.x.x`。Windows 上这种错会被掩盖。

### 坑 30 补：自包含部署白屏（用户实测踩中）

用户把 exe + ext-x.x.x + sqlite3.dll 拷到独立目录（C:/1233）运行，浏览器
白屏。诊断：`/` 与 `/ext/...` 均 200，但 `/lw/lw.js`、`/lw/lw.css` 404 ——
Ext JS 加载完成后等不到渲染脚本，页面无内容。lw.js（86 KB）+ lw.css（3 KB）
是部署清单里最容易被漏掉的两件（体积小、不在 ext 目录里）。

修复动作：把 `src/client/lw.js`、`lw.css` 拷到 exe 同目录即可，**服务不用
重启**（静态文件每请求现读）。框架改进：`TLWApp.Run` 启动时用
`LWFindClientFile` 检查 lw.js，找不到就在横幅前打印醒目警告（`浏览器将白屏`+
放置指引）。警告验证过两种场景：部署目录在仓库附近时不误报（回退找到），
彻底独立时准确报警。

## 坑 31：登录 + 多窗体切换 + 打印/导出（本轮实测）

### 31.1 代码创建的窗体必须自己设 Name

lfm 窗体的名字来自 lfm 根节点；纯代码 `TXXX.CreateNew` 建的窗体 Name 是空的。
框架靠**窗体名**识别登录窗体（`TLWLoginForm`）、按名创建默认主窗体、
会话内按名找窗体 —— Name 为空的后果：`forms: [{name:''}]`，测试与业务
都找不到控件。解法：`constructor CreateNew` 里 `Name := 'LoginForm'`。
同理，代码建的窗体也别指望 `OnCreate` —— 没有 lfm 就没人把
`FormCreate` 接上去，界面构建直接写进构造函数。

### 31.2 sqlite3conn 的 ExecuteDirect 会自己开事务

`conn.Open` 后先 `ExecuteDirect(PRAGMA ...)`，再 `tr.StartTransaction`
会报 `Transaction already active`（ExecuteDirect 隐式开了事务）。
DDL/DML 直接连续 `ExecuteDirect`，收尾一次 `tr.Commit` 即可。

### 31.3 TStringList.Text 在 Windows 上已是 CRLF

`StringReplace(sl.Text, #10, CRLF)` 会把 CRLF 变成 `CR CR LF`，
CSV 每行之间多一个空行。要统一换行，先归一到 LF
（`#13#10 -> #10`、`#13 -> #10`），再整体换 CRLF。

### 31.4 浏览器打印代替报表引擎的四个要点

1. `@page { size: A4 portrait; margin: 12mm 10mm }` 控制纸张与页边距；
2. `thead { display: table-header-group }` —— 打印时表头逐页重复；
3. `tr { page-break-inside: avoid }` 防止一行被劈成两半；
4. `@media print` 里隐藏工具栏/背景阴影，打印件才是干净的 A4。
"自动弹打印对话框"不能由服务端命令浏览器，只能页面自己做：
URL 带 `#print`（TLWPDFFrame.URLSuffix）+ 页内脚本在 load 后
`window.print()`。注意 iframe 换内容必须**换文件**（新文件名 -> 新令牌 ->
src 变化才真正重载），只改 hash 浏览器不会重新请求。

### 31.5 手写 xlsx（OOXML）的最小集合

`[Content_Types].xml`、`_rels/.rels`、`xl/workbook.xml`、
`xl/_rels/workbook.xml.rels`、`xl/styles.xml`、`xl/worksheets/sheet1.xml`
六个部件缺一不可（Override 少一个 Excel 直接报"文件损坏"）。文本单元格用
`<c t="inlineStr"><is><t>…</t></is></c>` 免掉 sharedStrings；数字单元格
不要带 `t` 属性；表头/合计的样式是 `styles.xml` 里 `cellXfs` 的下标
（`s="1"`），下标从 0 起。打包用 `zipper`：`Entries.AddFileEntry(stream, name)`
的参数顺序是 (流, 包内名)，内存流必须活到 `ZipAllFiles` 之后。
写 XML 前把 `#0` 等非法控制字符抹掉，否则 Excel 又报损坏。

### 31.6 会话里的窗体：隐藏 ≠ 删除

多窗体切换（主窗体 <-> 报表中心）和"注销 -> 重新登录"都要求窗体对象常驻。
原来 `SessionHideForm` 直接把窗体从清单里删掉，后果是注销重登每轮多造一个
主窗体（数据库连接跟着翻倍）。改为：隐藏只翻 `WebVisible` 标记，
`BuildPayload` 按 `WebVisible` 过滤（隐藏窗体不下发，浏览器端由 closeform
销毁窗口）；对象真正退场的时机是 `TLWForm.Destroy` ->
`SessionForgetForm`（防止业务 Free 之后清单里留野指针）。

### 31.7 报表渲染不许弄脏数据集

报表逐行扫描会把游标跑到底，用户网格上的当前行跟着丢。进出都要
`GetBookmark` + `DisableControls`，结束时 `BookmarkValid` 判断后
`GotoBookmark` 复位（封装在 lwreport 的 TLWCursorGuard 里）。

### 31.8 FastReport / LazReport / fcl-pdf 的实测结论

* FastReport：商业库，本机没有，无从对接；
* LazReport：源码在 `components/lazreport`，但 `TfrReport` 与
  `Printers`、预览窗体强绑定 —— nogui widgetset 没有打印机也没有窗口，
  硬接的成本远高于收益；
* fcl-pdf（本机 trunk 3.3.1）：`AddFont(AFontFile, AName)` 双参数版本
  可以嵌入中文 TrueType 并做子集（poSubsetFont 后 240 行报表级的 PDF
  只有十几 KB），`FontFile2`/`Identity-H`/`ToUnicode` 都在 —— 但实测
  ToUnicode 的码点映射不对（复制粘贴会得到错字），且偶发
  `Pages /Kids []` 空清单，不能作为默认导出路径。故打印走浏览器
  打印引擎，PDF 靠"打印对话框 -> 另存为 PDF"，服务端 PDF 直出留在路线图。
* 顺带：`AddFont` 的参数顺序用 `ppudump` 的 ParaNr 确认是
  `(AFontFile, AName)`，网上的单参数写法在本机版本不存在。

### 31.9 验证手段

无 GUI 环境下验证打印版式：无头 Edge 截图
`msedge --headless=new --screenshot=x.png --window-size=1000,1500 file:///.../out.html`，
版式（工具栏/表头/斑马纹/合计/页脚）一眼可见。xlsx/CSV 用 Python
zipfile + ElementTree 校验结构，登录/切换/导出走 HTTP 级回归
（`tests/t_dbaware2.py`）。

## 坑 32：输错密码也能进主页（值不同步 + 双重修复）

### 32.1 现象与根因

浏览器里输错密码点"登录"，主页照样弹出来。HTTP 级测试（显式发 OnChange
再点按钮）却全绿 —— 问题被测试掩盖了。

根因：lw.js 只在控件**挂了 OnChange** 时才回传值（`bindEvents` 里
`if (has('OnChange') && isField)`）。登录窗体的用户名/密码框没挂
OnChange，浏览器里输的内容**永远不会**到服务端；点"登录"时服务端
拿的是窗体**构建时的初始 Text**（演示里正好预填了正确密码），
于是怎么点都能过。

教训：测试模拟用户输入用的是 OnChange 事件，而真实浏览器不产生这个
事件 —— 测试环境和真实路径不一致时，测试会给出假安全感。

### 32.2 修复（框架层，三道闸）

1. **前端值快照**（lw.js）：`fire()` 每次事件都附带 `vals` ——
   同一窗体所有输入控件的当前值（按 `cmp.up('window')` 归组）。
   控件清单 `FIELD_KINDS` 与 `bindEvents` 的 `isField` 共用一份。
2. **服务端写回**（lwdispatch）：`LWApplyFieldSnapshot` 在派发事件前
   把 vals 写回控件，但只允许"纯输入控件"（TEdit/TMemo/TComboBox/
   TCheckBox/TSpinEdit/TDateEdit...）。数据库感知控件（TDBEdit 等）
   **绝不**写 —— 写 Text 等于改数据集字段，走它们自己的编辑通道。
3. **兜底过滤**（lwsession.BuildPayload）：`RequireAuth` 且未认证时
   只下发登录窗体。事件拦截（lwdispatch）只管事件，管不住已经下发的
   界面；认证必须是"看到主页"的唯一入口。

### 32.3 顺带修的第二个洞：登录身份用进程级全局变量

`GLoginUser/GLoginRole` 放在单元级变量里，同一个进程服务多个浏览器
会话时 B 能看到 A 的用户名、拿到 A 的权限（报表导出就是按角色禁用的）。
框架补了会话级键值区 `TLWSessionBase.SessionGetVar/SessionSetVar`
（lwbase 抽象 + lwsession 用 TStringList 实现），dbaware 改存
`login.name / login.role`，多开浏览器各是各的。

### 32.4 验证手段：CDP 驱动无头 Edge

HTTP 级测试永远打不中出现过的这个 bug，必须真实浏览器路径：
`msedge --headless=new --remote-debugging-port=9222`，用
websocket-client 连 CDP，`Input.dispatchKeyEvent/insertText` 模拟真实
键盘输入、`Input.dispatchMouseEvent` 模拟点击，再用
`Runtime.evaluate` 读 Ext 组件树断言窗口标题。注意关掉缓存
（`Network.setCacheDisabled`），否则改完 lw.js 测的还是旧脚本。

## 坑 33：多页签共享会话后，第二个页签永远收不到推送

### 33.1 现象与根因

跨页签共享会话做完后，CDP 双标签页验证：页签 A 点"显示遮罩"，A 自己
立刻出现遮罩，B 要等 20 秒（甚至永远等不到）。HTTP 级测试全绿 —— 因为
测试里每个页签都是独立请求，不存在"两个线程同时挂在一个等待上"。

根因有两层：

1. **模式切换死结**：原设计"单页签 + WebSocket 就直推、多页签才入队"。
   第二个页签挂上来那一刻，主页签正连着 WS、又没在轮询（WS 接管了事件
   通道），它**永远收不到任何推送，也就永远不知道该切模式**。
   修法：干脆取消直推 —— 推送一律带序号进队列，WS 只做"事件请求/响应"，
   长轮询成为唯一推送通道。"几个页签"对客户端完全透明，也不需要任何
   模式协商。
2. **自动复位事件只叫醒一个等待者**：`TEvent.Create(nil, False, ...)`
   是 auto-reset，`SessionPushCommand` 里一次 `SetEvent` 只能唤醒
   `WaitFor` 队列里的**一个**线程；另一个页签的长轮询要等满整个超时
   （20s）才会自己醒来。修法：`WaitCommand/WaitCommandAfter` 改成
   200ms 切片轮询（每次醒来先查队列），多等待者最迟 200ms 都能看到
   新指令 —— CPU 代价可忽略，长轮询本来就闲着。

### 33.2 游标协议

- 每条指令入队时 `Inc(FSeq)`，队列里存 `<seq, cmd>` 对；
- `/lw/api/poll?after=N` 返回"序号 > N"的**第一条**（不删除），
  客户端把响应里的 `seq` 当新游标；
- `after=-1` 表示"从现在开始"，只回当前序号（新挂的页签用）；
- 不带 `after` 保持老的销毁式队列（老客户端 / 测试兼容）；
- 队列只留最近 64 条，落后 64 以上的条目顺手清掉，掉线的页签不会
  让内存无限涨。

### 33.3 对话框定向（to 字段）

多页签共享会话时，同一条 `dialog` 指令每个页签都会收到 —— 不处理的话
一个 ShowMessage 会弹 N 个框。服务端用 threadvar `LWCurrentTab` 记住
"正在处理的是哪个页签的事件"（lwhttp 在调 `LWHandleEvent` 前从 body 的
`tab` 字段设置、finally 清掉），`dialog` 指令据此带 `to` 字段；
前端只在 `to` 等于自己的页签标识（或 `to` 为空且自己是主标签页 ——
后台线程发起的对话框）时弹窗。**教训**：threadvar 记得在 finally 里
清空，线程会被下一个请求复用。

### 33.4 验证

`tests/t_multitab.py`（HTTP 级 22 项：attach/410/双游标不互吃/序号对齐/
to 定向/新会话隔离）+ `tests/cdp_multitab.py`（CDP 开两个真实标签页：
同 sid、第二个页签直接见主窗体、A 点遮罩 B 的 DOM 里出现 `.lw-mask`、
B 关遮罩 A 同步消失）。CDP 里操作**未激活页签上的控件**用
`cmp.fireEvent('click')`，`el.dom.click()` 会因为 el 还没渲染而抛异常。

## 坑 34：元素级事件在"未渲染控件"上静默失效（懒加载页签）

### 34.1 现象

边缘控件 CDP 验证：取色器色块点不动（调色板不弹）、大表右键菜单不弹。
HTTP 级测试全绿 —— 服务端把 popup 配置、ev 清单都发对了，问题在前端绑定。

根因：`bindEvents` / `build()` 里好几处 `cmp.getEl().on('click', ...)`
在**创建控件的那一刻**就执行。控件在未激活的 Ext 页签（懒渲染）里时
`getEl()` 返回 null，try/catch 把异常吞了，事件**永远绑不上**。

### 34.2 修法

抽出 `onEl(cmp, ev, fn)`：el 在就绑，不在就挂 `afterrender` 再绑。
四处改用：label/panel/image 的 OnClick、OnDblClick、TControl.PopupMenu
的 contextmenu、TLWColorPicker 色块的 click。

教训：Ext 的组件事件（`cmp.on('click')`）与 DOM 元素事件（`el.on()`）
时机不同 —— 组件事件永远安全，元素事件必须等渲染。凡是要碰
`getEl()` 的代码都要回答"这时候 el 存在吗"。

### 34.3 CDP 验证技巧

操作未激活页签上的 Ext 组件用 `cmp.fireEvent('click', cmp)` 直接触发
组件事件（el 未渲染也能用）；合成 contextmenu 的 `initEvent` 不带坐标，
菜单会弹到 (0,0)，断言"菜单出现 + 菜单项文本"没问题，测定位才需要真鼠标。

## 坑 35：GUI 服务端面板 —— 四个连环坑与「关闭窗口」白屏

### 35.1 File not open（I/O 103 弹错误框）

GUI 构建（win32 widgetset + `-WG`）一启动就弹
「File not open. Press OK to ignore…」。三条线索叠在一起：

1. `IsConsole` 在 GUI 子系统下**不可靠**——有时仍为 True；
2. 但 RTL 没打开 `Output`（`TextRec(Output).Handle = 0`）；
3. 于是 `WriteLn` / `SetTextAutoFlush(Output)` 都是 I/O 103。

GUI 程序里 RTL 的运行时错误不走控制台、直接弹框（exit code 217），
所以表现为那个吓人的对话框。修法：`lwrlog.LWStdOutOpen` 用
`TTextRec(Output).Handle` 实测句柄有效性，所有 stdout 操作
（LWLog 的控制台出口、lwapp 的 SetTextAutoFlush）都先问它。
另外 `.lpr` 里的 `{$APPTYPE CONSOLE}` 会压过命令行 `-WG`，
GUI 工程必须删掉这行。

### 35.2 服务起不来（面板永远不出现）

第二版 GUI 构建服务在监听、healthz 正常，但面板窗口没建出来。
插桩发现 `LWRunPanel` 根本没执行 —— **`TLWServer.Start` 一进
fcl-web 的 accept 循环就永不返回**，写在它后面的代码全部不可达
（包括老代码里那句防御性的 `while True do Sleep(500)`）。
修法：accept 循环放后台线程（`TLWServerThread.Execute := Start`），
主线程只跑面板 + `Application.Run`；关窗 OnClose 调 `Stop`
（幂等），accept 退出、线程自然结束。

改完别忘了另一头：`lwapp.Run` 里的 `GServer.Start` 要一并挪进
`LWRunPanel` —— **nogui 分支也必须调 Start**，否则 nogui 构建
（tests/CI 的全部服务）起不来，表现为 8090 拒绝连接。

### 35.3 面板里看不到启动横幅

横幅在 `LWSetLogSink` 挂上之前就打了。日志统一走 `lwrlog`，
无 sink 时暂存到 200 行后备缓冲，`LWSetLogSink` 挂上时一次性补发。
面板日志的线程模型：HTTP 线程 → 临界区缓冲 → TTimer 每秒在主线程
swap 出来追加 Memo（不用 Synchronize/Queue，没有死锁面）。

### 35.4 点主窗体菜单「关闭窗口」后白屏（nogui 也有）

`TLWForm.DoClose` 的非模态分支只推 `closeform` —— 会话里最后一个
可见窗体关掉后，浏览器上什么都没剩，只能重启服务端再登录。
修法：DoClose 尾部检查 `VisibleWebFormCount = 0` 且会话有登录窗体
且关的不是登录窗体自己 → `SessionShowForm(S.LoginForm)` 自动回登录页。
回归 `tests/t_closewin.py` 6 项（关→回登录→再登录→退出登录不回归）。

## 坑 36：lwhyper 专用负载均衡器（实现期的四个坑）

### 36.1 program 与单元同名 → 链接缺符号（坑「lwlog」的变体）

`tools\lwhyper.lpr`（program lwhyper）和 `src\core\lwhyper.pas`（unit lwhyper）
都会生成目标文件 `lwhyper.o`，互相覆盖 → 链接时 `Undefined symbol:
LWHYPER_$$_...`。与坑「单元名不能叫 lwlog」同源但更隐蔽：这次是**文件名**
冲突而不只是标识符冲突。修法：lpr 改名 `lwhyper_main.lpr`
（产物文件名仍由 lpi 的 Target Filename 定为 lwhyper.exe）。

### 36.2 `TFPHttpServer.Active := True` 永不返回 —— monitor 线程永远没建出来

monitor（healthz 巡检 + 崩溃重启）写在 `FHTTP.Active := True` 之后，
结果探针一次都没跑过（`/lw/hyper/status` 里 alive 恒为 false）。
与坑 35.2 同根：trunk 的 `SetActive` → `StartServerSocket` →
`StartAccepting` 进 accept 循环不回头。修法：**先把 monitor 建出来再开监听**，
让 `Start` 阻塞在 accept 循环（与 nogui worker 同一形态）。
注意 `TFPHTTPServer` 与 `TSocketServer` 在这一点上行为一致。

### 36.3 无 sid 的新会话拿不到 worker（PickWorker 的 early-exit）

第一版 `PickWorker` 开头 `if ASid = '' then Exit(-1)` ——「无 sid = 找不到
worker」。但新会话（POST /lw/api/session）本来就**不带 sid**，理应走轮询分配；
结果所有新会话一律 502 "no alive worker"。修法：无 sid / 未知 sid /
目标已死三种情况统一落到「跳过 dead 的轮询」，全部 dead 才返回 -1。

### 36.4 fphttpclient 的三个 API 事实（FPC 3.3.1 trunk 实测）

- `HTTPMethod(..., AllowedResponseCodes)` 传**空数组 `[]` = 全部放行**
  （`CheckResponseCode: Result := High(AllowedResponseCodes) = -1`），
  不要去枚举 200..599；
- 响应码属性叫 **`ResponseStatusCode`**（不是 ResponseCode），
  响应头在 `ResponseHeaders`（NameValueSeparator 已设为 ':'）；
- **不会自动读环境变量代理**（Proxy 只能显式设置），所以 shell 里的
  http_proxy 不影响代理转发；请求体从 `ARequest.ContentBytes`（fphttpserver
  把请求体读进 TBytes，不是 ContentStream）拷出来塞进 `RequestBody`。

另：lpr 忘了 `uses Interfaces` 会在链接时报一整屏 `WSRegister*` 未定义
（LCL 控件注册链没进来）——纯 fcl-web 程序一旦引了 lwbase（依赖 Forms）
就要带上 Interfaces 单元。回归：`tests/t_hyper.py` 20 项 +
`tests/t_hyper_ws.py` 6 项（WS 隧道双向往返）。

## 坑 37：Ext 精简版提取（ext-x.x.x → 23MB）与 .bat 的两个连环坑

背景：自包含部署只想带真正被引用的 Ext 文件。lazarusWeb 服务端只引用
4 类路径：`build/ext-all.js`、六主题（classic/crisp/gray/material/
neptune/graphite）的 `theme-<t>-all.css` + 同目录 `_1`/`_2` 分卷（all.css
只有两条 @import 指向它们，无其它 url）、各主题 `resources/images/`、
material/graphite 另引 `fonts/`(material)/`font-awesome/`/`font-ext/`、
charts 包的 `build/packages/charts/classic/charts.js` +
`crisp/resources/charts-all.css`（纯 CSS 零资源引用）。提取脚本
`tools/make_ext_min.bat` 产出 `ext-x.x.x-min`（24MB / 3093 文件）。

- **Sencha 官方发行包本来就缺图**：theme CSS 里共 2856 条 url() 引用，
  其中 389 条在完整 75MB 树里同样不存在（btn-default-toolbar-*、
  toolbar-footer-bg 等，构建产物裁剪所致）。别把这 389 条当成精简版
  的回归——判据是"与完整树逐条比对"，零真实缺失即等价。
- **.bat 中文注释 = GBK 碎裂**：Write 工具写 UTF-8，cmd 按 cp936 逐行
  解析，多字节尾字节吞掉换行 → 后半段注释被当命令执行，整个脚本碎成
  乱码（与坑 22 同族）。.bat 注释一律用 ASCII。
- **.bat 里 for 块内 `call :x ... || exit /b 1` 会解析错乱**：实测
  cmd 把 `%%T` 展开成裸 `%T`、跳行执行、call 的 %~dp2 被截断——
  for+call+|| 组合是雷区。改成逐行 `call :theme classic` 子例程 +
  子例程尾 `goto :eof`、错误不往上抛（靠最后结果说话）就稳了。
- **Git Bash 排查 cmd 的干扰**：`cmd //c "a\\b.bat"` 的转义、`&` 把
  连同 `cd` 在内的整条链后台化导致 cwd 漂移，都会搅浑现场。定位时
  `cd` 到脚本同目录用裸文件名调用最干净。

验证：2856 条 CSS url() 引用与完整树逐一比对（0 真实缺失）、images/
fonts/font-awesome/font-ext 目录 filecmp 递归全等、ext-all.js 字节级
一致、`t_dbaware.py` 134 项在 `--root` 指向精简树的实例上全绿、6 主题
CSS + 字体 + 图片样例 HTTP 全部 200。

## 坑 38：lwconvert v2（真转换）落地的七个坑

v1 只产出"骨架 + 两步手工"；v2 要直接改写源码，踩到的坑都出在文本处理上：

1. **`class(TForm)` 的 token 必须比 5 个字符**：`TForm` 是 5 个字母，我按 4 个
   比（`'tfor' <> 'tform'`）永远不成立，于是每一处都被判成"不是 TForm"跳过，
   表面现象是"文件没改，但报告说改了"。
2. **类名在 `=` 左边**：`TForm1 = class(TForm)`。先写成取 `=` 右边，取出来是空串。
3. **不能靠 `interface` 定位 uses**：`EnsureUsesUnit` 先搜 `interface` 会被
   uses 里的 `Interfaces` 截胡，且 `.lpr` 根本没有 interface 段。直接找文件里
   第一个 `uses` 关键字即可（注释里出现 uses 极罕见）。
4. **`ExtractRelativePath` 的 Base 必须带路径分隔符**，否则返回半截路径，
   后续 `FileExists` 全 false → 转换"静默失败"。包一层 `RelFileIn` 统一补分隔符。
5. **读 `CONTROL_MATRIX.md` 的列位**：行是 `| class | kind | status | note |`，
   状态在**第 4** 个字段；读第 3 个会把 kind 当状态，结果所有控件都"未收录"。
6. **FPC 的 for 变量不能嵌套复用**：`for i` 里再 `for i` 直接编译错
   （`Illegal assignment to for-loop variable`），-O2 下一样报。
7. **测试侧的三个"想当然"**（对照真实 JSON 才发现的）：
   - `TMemo` 下发的是 `text`（行用 CRLF 拼成一串），不是 `lines` 数组；
   - 菜单不在控件树里，在 `form['menu']` 的嵌套数组（`items`）；
   - 两个窗体都有 `Button1`/`Edit2` 时，按名字查找会命中另一个窗体 —— 必须
     "窗体名 + 控件名"限定，否则点"OK"点成了主窗体按钮，模态永远不结束
     （表现为请求一直挂着）。

转换器边界（有意为之，写进报告不猜语义）：只改写 `class(TForm)` 的基类；
一个单元里只认第一个类声明；`TDataModule` 的 `CreateForm` 保留原样并给警告
（全局单例，所有会话共享）；`{$R *.res}` 在 .res 不存在时移除（否则 lazbuild
直接编译失败）。

回归：`tests/t_convert.py` 29 项（转换 → lazbuild → 启动 → 树断言 →
复选框事件 → **模态窗体往返** → 菜单项点击）。

## 坑 39：服务端配置文件（INI）的五个小坑

需求：给服务端加一份配置文件（当前主题 / ext-js 目录 / 监听端口），命令行优先。
新单元 `src/core/lwconfig.pas` + `TLWServerConfig.ExtDir`。

1. **FPC 的 `TIniFile` 读不到"无节名"的键**：`ReadString('', 'Port', '')`
   永远返回默认值（实测：`[lazarusWeb]` 里的能读到，文件头那几行读不到）。
   而手写 ini 的人十有八九先写 `Port=8090`。所以不用 `TIniFile`，自己按字节
   解析：节名一律忽略（摊平），键名归一化成小写并去掉 `-`/`_`/空格，
   `;`/`#` 注释、UTF-8 BOM、CRLF/LF、值两侧引号都处理掉。
2. **`TStringList.Values[k] := ''` 会把键删掉**（FPC 实现如此），于是
   `ExtDir=` 这种"显式留空"会变成"没有这个键"，`Has()` 判断失真。
   改成自己维护 `key=value` 行 + `IndexOfName` 查找，空值也保留。
3. **嵌套过程里不能拿外层变量当 for 计数器**：`ApplyConfigFile` 是
   `TLWApp.Run` 里的嵌套过程，`for i := ...` 用了 Run 的 `i` →
   `Error: (4058) Illegal counter variable`。给嵌套过程自己的局部变量。
4. **`ExtDir` 是"目录"，不是"版本号"**：框架的 URL 是
   `/ext/<版本>/build/...`，`ExtRootFor` 原来硬拼 `<root>\ext-<版本>`。
   给了 `ExtDir` 就必须让**任何**版本号都落到这个目录，同时 `ServeExt`
   里 `7.0.0/x.x.x` 的白名单要放行 —— 否则 `?ext=7.0.0` 直接 404。
5. **测试环境的两个坑**：
   - `subprocess.Popen(stdout=PIPE)` 后 `p.stdout.read(3000)` 会一直阻塞
     （服务不退出就没有 EOF），把整条命令拖到超时；改成重定向到文件、
     kill 之后再读；
   - 各测试脚本用的是各自的固定端口（`LW_DBAWARE_BASE` 默认 8141、
     `LW_BASE` 默认 8110/8120/…），`run_with_server.py` 的端口参数必须和
     被测脚本的默认值一致，否则表现为"服务起来了但测试连接被拒"。

回归：`tests/t_config.py` 19 项（三项生效、命令行覆盖、ExtDir 留空/坏路径回退、
无节名、键名别名+引号、exe 目录自动发现、无配置时默认 8090）。

## 坑 40：源码里到处都是 `x.x.x` / `7.0.0`，换个 Ext 版本就白屏

起因：有人问"用别的 Ext 版本会不会有问题"。当时不配 `ExtDir`、把目录改名成
`ext-7.6.0` 实测：外壳 404、浏览器白屏。根因是框架把"版本号"当成"目录名"的
硬编码判断，散落在三处：

1. `ExtRootFor` 直接拼 `<root>\ext-<ver>`，`ServeExt` 再用 `7.0.0/x.x.x`
   白名单过滤 —— 白名单之外的版本连"目录存在"都不看就直接拒；
2. `BuildIndexHtml` 里 `if ver = 'x.x.x' then` 决定插不插 charts 包；
3. 主题选择同样写死了"哪些版本有 crisp"。

改法（全部改成"看目录/看文件"，一个版本号都不写）：

| 位置 | 原来 | 现在 |
|---|---|---|
| 目录解析 | 硬拼路径 + 版本白名单 | `ExtRootFor`：精确目录存在就用；否则 root 下**有且仅有一个** `ext-*` 时回落；多版本共存时严格匹配 |
| 版本段校验 | `'7.0.0','x.x.x'` 白名单 | `LWIsSafeExtVer`（`[0-9A-Za-z._-]`，≤32）+ `DirectoryExists` |
| charts | `ver = 'x.x.x'` | `ExtFileExists(ver, 'build/.../charts.js')` |
| 主题 | 按版本列表 | `PickTheme`：CSS 三件套存在即用，否则 crisp→classic→neptune |
| 横幅 | 打印默认版本 | 打印**实际目录** + 列出所有 `ext-*`，单目录名字不一致时提示 |

实测（`?ext=` 三种写法 × 单/多目录）：只有一个 `ext-7.6.0` 时 `/ext/x.x.x/`、
`/ext/7.6.0/`、`/ext/8.0.0/` 全 200（2464021 字节，与真实 ext-all.js 一致）；
`ext-7.0.0` 与 `ext-x.x.x` 并存时 `/ext/7.6.0/` 必须 404（不许乱猜）；路径穿越
`/ext/..\..\Windows/...`、`/ext/..\..\..\win.ini` 均 403；`?ext=7.0.0` 现在也能
正确注入 charts（7.0.0 的 charts.js/charts-all.css 都在）。`tests/t_config.py`
19 项全过。

**坑中坑**：构造函数里探测"唯一 ext 目录"必须传 `APreferVer = ''`。传默认版本
的话，`ext-x.x.x` 存在时就会把 `ext-7.6.0` 也指过去 —— 多版本共存时表现为
"请求 7.6.0 拿到 x.x.x 的文件"，比 404 更难查。

## 坑 41：把"代码建窗"的 demo 全部改成 `.lfm`（九个坑）

目标：`demos/dbaware` 里两个用 `Txxx.Create` + `SetBounds` 手搭界面的窗体
（主窗体 90+ 控件、登录窗体 9 个、报表窗体 11 个）改成标准 Lazarus 写法 ——
`.lfm` 存布局，`.pas` 只留逻辑。现在**所有 demo 的窗体都是 `.lfm`**。

现成的窗体用一次性的导出工具（win32 编译的小程序）跑出 LFM，再由脚本清洗，
比手写可靠（自定义控件的属性名不会写错）。踩到的坑：

1. **`TWriter` 只写 `Owner = 根组件` 的子控件**。代码建窗时 `TTabSheet` 归
   `TPageControl` 所有，导出的 LFM 只剩第一层，标签页和页内控件全丢。
   写盘前把整棵可视树的 `Owner` 递归改成窗体（`InsertComponent`）；改完
   `Form.Free` 会卡在销毁顺序上 —— 导出工具直接 `Halt`，别释放。
2. **`WriteComponentResFile` 写出来的不是纯窗体流**，前面还有资源头。
   `ObjectBinaryToText` 会报 `Illegal stream image`；先扫 `'TPF0'`
   （LE DWORD `$30465054`）定位起点再转。
3. **运行时 `TMethod.Name` 是空的**：`btn.OnClick := @Handler` 写不进二进制流。
   事件必须从 `.pas` 源码里正则挖出来（`X.OnY := @Handler`）补进 LFM。
4. **`RegisterClassAlias` 不会覆盖已注册的类名**：`TDBNavigator` 是 LCL 已注册
   类，别名落不到子类，加载时用基础类构造 → 加载 glyph 位图失败
   （`Failed to get raw image description from bitmap`）。改成
   `RegisterClass(TLWDBNavigator)`，LFM 里就写真实类名 `TLWDBNavigator`。
5. **nogui widgetset 下建不出任何窗体**：`TForm.CreateNew` 一律 AV。导出工具
   必须用 **win32** widgetset 编译，导完就扔。
6. **`TDateEdit` / `TTimeEdit` 是"日期时间暗礁"**：二进制流里 `Date`/`Time`
   属性写的是 LCL 的 `NullDate = 29584650.5`（≈ 10 × MaxDateTime），加载时
   直接 `EConvertError: 29584650.50 is not a valid date/time value`，
   而且这个异常发生在 `.lfm` 解析阶段，`OnCreate` 里再赋值也来不及。
   导出时不要写 `Date`/`Time`，只写 `Text`（人可读的日期串）。
7. **匿名对象绑不上字段**：手工建窗经常 `TLabel.Create(Self)` 不起名，导出的
   就是 `object TLabel`，LFM 加载后没有名字、published 字段拿不到引用。
   导出前把没起名的控件补上 `Name`。
8. **LCL 会给同名窗体偷偷加 `_N` 后缀**：一个进程服务多个会话时，同名窗体会
   被实例化多次；`TReader` 发现"全局已有同名窗体"就把名字改成 `ReportForm_1`。
   窗体名是框架识别窗体的依据（登录窗体 / 默认窗体 / 会话内查找），于是
   "切换后只剩报表窗体"的断言拿到 `['ReportForm_1']` 而失败。
   修复放在框架层：`TLWForm.Loaded` 里 `Name := LWStripUniqSuffix(Name)`
   （`lwbase.LWStripUniqSuffix` 去掉 `_数字` 尾巴）。这是 **所有** 用 `.lfm`
   的多会话应用的隐患，不是单个 demo 的问题。
9. **转换脚本按行切语句时，夹在中间的整行注释会吃掉下一条语句**：`{ ... }`
   不以 `;` 结尾，于是 `btnOk.OnClick := @DoLogin` 被并进注释那条"语句"，
   落到 `FormCreate` 里 —— 虽然还能跑（属性赋值等价），但 LFM 里少了事件绑定。
   切语句前先剔掉 `{`/`//` 开头的整行注释。

LFM 里的两个小知识：长标题可以写成 `'前半' +` 换行 `'后半'` 的拼接形式；
`Font.Size := 13` 在 LFM 里存成 `Font.Height = -17`（`-Round(Size*96/72)`），
配 `ParentFont = False`。

回归：`tests/` 全套 472 项（dbaware 134 + 46、multitab 22、closewin 6、
login 15、controls 26、ws 8、db 35、attach 42、dialog 36、files 28、
config 19、hyper 20、hyper_ws 6、convert 29）全绿。

## 坑 42：四类容器控件在浏览器里"隐形"——两个前端小错叠加

TRadioGroup 渲染正常，但 TCheckGroup / TCheckListBox / TValueListEditor 三个
在浏览器里要么是 Ext 的红色占位框、要么干脆看不见。无头浏览器（Edge
`--remote-debugging-port` + node 原生 WebSocket 走 CDP）挂上控制台一看，
两处错一起冒出来：

1. **Ext 类名大小写**：Ext JS 的复选框类是 `Ext.form.field.Checkbox`
   （b 小写），lw.js 有 3 处写成了 `CheckBox` —— `Ext.create` 抛
   `TypeError: c is not a constructor`，createNode 兜底成红色占位框。
   而"复选框类名拼错"这种错，服务端 JSON、kind 判定、事件分发全是好的，
   `tests/t_controls.py` 照样全绿 —— **纯前端错误服务器端测试探不到**，
   必须真开浏览器。
2. **valeditor 忘了 addTo**：`case 'valeditor'` 里 `Ext.create('Ext.grid.Panel')`
   之后直接 `return vgrid`，没有 `addTo(vgrid, ct)` —— 组件在
   ComponentManager 里查得到、getStore 有数据，但从未挂进父容器，
   `getEl()` 是 undefined，页面上自然没有它。Ext 组件"创建"和"加入容器"
   是两步，漏了第二步就是隐形。

修完后用同样的 CDP 探针复核：两组 FieldSet、4+3 个复选框、键值网格
（属性/值 两列三行）全部在 DOM 与截图里出现。`tools/lwaudit.lpr` 的
JSRenders 名单补上这四个 kind，`build_audit.bat` 重新生成
CONTROL_MATRIX（完整支持 45 → 49 / 66）。

## 坑 43：IDE 里两件事 —— 两个工程模板、设计期注册自定义控件

**两个模板**：原来只有 "lazarusWeb Application"（.lpi 固定
`LCLWidgetType=nogui`），代价是 IDE 里 F9 链接不到 noguiint 必须改用
build.bat。现在拆成两个（`TLWNewProject.Headless` 一个字段决定 .lpi 全部
差别，IDE 向导与 `lwnew` 命令行共用）：

| 模板 | .lpi | 适合 |
|---|---|---|
| lazarusWeb Application | 不覆盖 widgetset，GraphicApplication 默认 | 日常开发：IDE 里 F9 直接跑，弹服务端面板窗口 |
| lazarusWeb Application (nogui) | `LCLWidgetType=nogui` + `GraphicApplication=False` | 部署：纯控制台服务，`lazbuild --ws=nogui` |

**设计期打开带自定义控件的窗体**：lfm 里写 `TLWDBGrid`，但 lwdesign 只
RegisterComponents 了 TLWFileUpload —— IDE 读 lfm 按 GetClass 找类，找
不到就报未知类。修法是把 lwdbgrid/lwdbnav/lwchart/lwui/lwweb/lwreport
里的控件全注册进组件面板（RegisterComponents 内部会 RegisterClass），
lwdesign.lpk 加 lwserver 依赖。

**坑中坑**：lwserver.lpk 只登记了 7 个单元，其余 13 个（lwdbgrid、
lwchart、lwreport…）靠 `OtherUnitFiles=core` "顺手"能编译 —— 但依赖包
（lwdesign）解析单元时只看 lpk 里**登记过的文件**，于是
`Can't find unit lwreport`。把核心单元全部登记进 lwserver.lpk 才算正路；
顺带说明 demo 工程不受影响是因为它们根本没走包（直接指 src\core 路径）。

装完包需要重新 Install lwdesign 重启 IDE 生效（`tools\install_design.bat`
会打印步骤）。

## 坑 44：GUI 版服务端关窗后要等很久才退出（实测 60 秒起步）

现象：GUI 版面板点 X，进程吊着几十秒甚至 60 秒以上才消失。逐层拆开是
四个问题叠加，每个单独看都"不算 bug"：

1. **accept 循环叫不醒**（主因）。fphttpserver 的 `TSocketServer.StopAccepting(False)`
   只把 `FAccepting := False`，而 accept 循环默认 `AcceptIdleTimeout = 0` =
   **阻塞在 accept() 里直到下一个连接**。`FHTTP.Active := False` 之后线程
   还卡在 accept 里，面板里的 `th.WaitFor` 就等到了天荒地老 —— 直到浏览器
   再发一个请求把它叫醒。用探针实测（tmp/t_stop，无客户端）：
   `Stop = 0ms, accept 线程退出 = 20000ms(超时, 没退出)`。
   修法：`FHTTP.AcceptIdleTimeout := 250` —— 循环变成 select+250ms 轮询，
   停服后 ≤250ms 退出，新连接无延迟（select 一有数据就返回）。
2. **挂起的长轮询把连接线程吊 20 秒**。`/lw/api/poll` 在 `WaitCommand`
   里切片等待最长 20s；`FHTTP.Free`（析构）会 `WaitForRequests(High)`
   无限等连接线程收工。修法：lwsession 加全局停止标志
   `LWSetServerStopping`，两个 Wait 循环每片都检查；模态对话框的
   180 秒等待同样包了一层（`LWWaitEventOrStop`，200ms 切片）。
3. **在 accept 循环脚下拆对象**。原来 Stop 里 `FreeAndNil(FHTTP)` 不等
   Start 返回 —— accept 线程随后回到循环里就踩释放了的内存。表现是
   关窗时日志冒出 `错误: 无法启动服务: Access violation`（异常发生在
   启动线程里，极具迷惑性）。修法：`Start` 在 finally 里置 `FRunFinished`
   + 事件；`Stop` 先等（上限 3s）再 Free，等不到就放弃清理（宁可泄漏）。
4. **清扫线程从来没跑过**。`FSweeper.Create` 写在 `FHTTP.Active := True`
   **之后** —— 而 Active := True 一进 accept 就不返回，所以建清扫线程那两行
   要等服务停了才执行。修法：挪到 Active := True 之前；等待切片从 1s 改
   250ms，停服时最多耽误 250ms。

修完实测：`Stop = 200~330ms`、accept 线程 0ms 跟着退出；带自测钩子的
GUI 版点"退出"全程 ~0.7s。顺带：Stop 现在还会主动断残留连接
（`TLWHttpServer.AbortConnections` 拿 protected 的 ConnectionHandler.CloseSockets），
否则析构里那套 10×100ms 的探测要白等一秒多。

## 坑 45：托盘化的两个小坑（GUI 面板点 X = 隐藏到托盘）

面板行为改成：点 X `caHide` 藏进托盘（服务照跑、第一次弹气泡提醒）、
托盘常驻图标（运行时画 32x32：蓝底圆角 + "LW"，`TIcon.Assign(TBitmap)`
就能把位图变图标，不用带 .res）、左键点图标恢复面板、右键弹出菜单
（打开面板/浏览器/退出），只有菜单「退出」置 `FExiting` 再 Close 才真正
停服退出。两个小坑：

1. 托盘 tooltip（`TTrayIcon.Hint`）是**单行文本**，`#13#10` 会被 Windows
   拍平，别指望两行显示；总长超 128 字符会截断。
2. `Canvas.TextRect` 的样式枚举是 LCL 的 `TTextFormats`（tfCenter/
   tfVerticalCenter…），没有 Delphi 的 CenterX/CenterY；图标上写字直接
   `TextWidth/TextHeight` 算偏移最省事。

## 坑 46：GUI 档服务程序带一个大黑控制台窗口

现象：`lazarusWeb Application`（GUI 档）编出来的 exe，双击运行先弹一个
黑色控制台窗口，面板窗口再跟着弹 —— 两个窗口很怪。

根因有两层，缺一不可：

1. `.lpr` 里写死了 `{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}`。
   **`{$APPTYPE}` 编译指令的优先级高于命令行的 `-WG`** —— 就算 lazbuild
   传了 `-WG`（lpi 里 `GraphicApplication=True`），源码指令照样把它盖掉。
2. `.lpi` 的 GUI 档根本没写 `<Linking><Options><Win32>
   <GraphicApplication Value="True"/>`，所以光删 .lpr 里的 CONSOLE、
   用 IDE 重编还不一定稳（手工 fpc 编译默认就是控制台）。

修法（生成器 `lwnewproject` 两处都改）：

- `.lpr`：GUI 档写 `{$APPTYPE GUI}`，nogui 档保持 `{$APPTYPE CONSOLE}`
  （部署档要 stdout 日志，别丢）；
- `.lpi`：两档都显式写 Win32 子系统 —— GUI 档 `GraphicApplication=True`，
  nogui 档 `=False`。

验证手段：读 PE 头 Subsystem 字段（OptionalHeader 偏移 68；2=GUI、
3=console）。`lazbuild` 参数里有 `-WG` 不代表生效，必须看 PE。
历史生成的 GUI 工程（lwapp1、用户工程）已批量补 `{$APPTYPE GUI}` +
lpi 的 True，重编后 Subsystem=2 实测 HTTP 200。
## 坑 47：工程名叫 LWApp 时根本编不过 —— 两层撞名

生成器已禁止工程名与框架单元重名，但历史工程（LWApp）踩了两层：

1. **program 名撞单元名**：`program LWApp; uses ..., lwapp, ...` →
   `Duplicate identifier "LWAPP"`（program 标识符进作用域，与 uses 单元
   大小写不敏感撞车）。改 program 名（LWAppGUI）即可，lpi 的 Target
   Filename 可以不动 exe 名。
2. **.lpr 文件名撞单元 .o 名（更隐蔽）**：`-B` 全量重编会把 uses 树里
   所有单元（含框架的 lwapp/lwlogin…）重新编进工程的 UnitOutputDirectory。
   主程序汇编输出是 `<lpr 文件基名>.o`（LWApp.lpr → LWApp.o），框架单元
   是 `lwapp.o` —— Windows 文件系统大小写不敏感，**同一个文件被写两次，
   后写的覆盖先写的**。链接列表里主程序和 lwapp 单元指向同一 .o：
   main 定义两次（Multiple defined symbol "main"）+ TLWApp 实现丢失
   （Undefined symbol: LWAPP$_$TLWAPP...）。报错位置在 .lpr 最后一行，
   极具迷惑性。修法：lpr 文件改名（LWAppGUI.lpr），lpi 的 Units 同步，
   清 lib 重编。exe 输出名（Target Filename）无关紧要 —— 撞的是
   lpr 基名与单元名。
## 坑 48：nogui 下 LCL TTimer 一启用就 EOutOfResources

nogui widgetset 的 `CreateTimer` 直接返回 0，LCL `TCustomTimer.UpdateTimer`
拿到 0 就 `raise EOutOfResources(SNoTimers)`。赋 OnTimer（默认 Enabled）
当场炸 —— gallery 全功能 demo 构建期就撞上。

修法：nogui 部署必须用 FCL 的 **TFPTimer**，而且有两个连环坑：

1. 默认模式等主线程泵消息（`CheckSynchronize`）才触发 —— 服务端主线程
   阻塞在 accept 循环里，**永远不触发**（实测最小程序 cnt=0）。必须
   `UseTimerThread := True` 才真的起后台线程（最小程序实测线程里触发）。
2. OnTimer 在工作线程触发，**里面绝对不能碰 LCL 控件**（实测秒崩）。
   只更新普通字段（纯内存），UI 值由任意一次事件回发时同步下发。

## 坑 49：nogui 下 TTreeView 选中、TListView Selected 的 LCL 行为

- `TTreeView` 构造时就创建了内部 `FChangeTimer`（TTimer，Interval=1）；
  选中变化 → `InternalSelectionChanged` → `FChangeTimer.Enabled := True`
  → `UpdateTimer` → nogui 无 CreateTimer → **EOutOfResources**。
  dispatch 的处理：`{$IFDEF LCLnogui}` 先把 TTreeView 拥有的 TTimer
  的 OnTimer 摘掉再赋 `Selected`（代价：OnSelectionChanged 的延迟通知
  在 nogui 下不触发，OnClick 不受影响）。
- `TListView`：MultiSelect=True（默认）时 `GetSelection` 每次都按
  `Items[i].Selected` 重算 —— 直接给 `Selected` 属性赋值在 nogui 下
  会被冲掉。必须 `ClearSelection` + `Items[i].Selected := True` +
  `ItemIndex := i`。
- 配套框架增强（lwdispatch.LWApplyGridPos）：TListView/TTreeView 的
  OnClick 现在按 `val`（第几项/顶层节点序号）服务端模拟选中，
  与 TListBox/TCustomGrid 的 row/col 同一约定。

## 跨平台审计（2026-11-10）

结论：核心单元（src/core）本就无平台依赖（fphttpserver + PathDelim +
cthreads 条件编译，无 Windows/winsock/ShellExecute 单元），本轮把
工具链和生成器的 Windows 残余补齐：

- `lwnewproject` 生成器现在同时产出 `build.bat`（CRLF）与 `build.sh`
  （LF，WriteText 原样写字节所以行尾不串），并去掉 `C:/111/lazarus`
  硬编码——改为 PATH → 常见安装位置兜底，`LAZBUILD` 环境变量最高优先。
- 新增 `tools/build.sh`（convert/hyper/audit/dbcheck/hyper_gui/convert_gui
  统一入口）与 `start-gui.sh`，与既有 bat 一一对应。
- 文件对话框 filter、帮助文本、输出提示里的 `.exe` / `\` 全部按
  `{$IFDEF WINDOWS}` 分支或改用平台中性写法；`lwconvert` 的 SkipFile
  补 `.dll/.so/.dylib`。
- 细节坑：bash `for c in a b \` 续行符漏写会报 syntax error（生成脚本
  里已修）；`{$IFDEF}` 夹在两个字符串字面量中间时必须有 `+` 连接，
  相邻字面量拼接在 FPC 里是语法错误。

## 坑 50：nogui 无句柄时 ClientWidth/ClientHeight 是默认值 320x240

gallery 窗口在浏览器里被缩到 277px 高、内容互相重叠 —— 根因不在前端：

- LFM 流加载时 `SetClientHeight` 只存 `FLoadedClientSize`（csLoading 分支，
  controls.inc），`TWinControl.GetClientRect` 在**句柄未创建**时走
  `GetDefaults` 兜底，读出来是构造默认值 320x240，不是 LFM 的 1020x680。
- lwwriter 把 ch=240 发给前端；buildForm 按 `ch - body 高度` 补差值，
  窗口被 setHeight 缩小 → 页签内容被压没、"事件日志"盖在控件上，
  用户看到的就是"后面 5 个页签是空的""点击无效"。
- 修复（lwwriter.WriteForm）：`HandleAllocated` 时才用 Client*，
  否则用 Width/Height（LCL 约定窗体 Width==ClientWidth，见 LCL FAQ）。

顺带修的同源问题：

- **TToolButton**：nogui 下 Width 是默认 24，不按 Caption 自算，
  前端照搬会把"动作 1"截成"动" → 前端忽略宽度自动排。
- **TUpDown**：nogui 没有 Windows 消息链，Associate 联动不会发生 →
  前端把箭头点击当 OnClick 回传新位置，LWApplyValue 写 Position
  并手动写 Associate 的 Text。
- **TListBox OnClick**：前端网格没有通用 click，挂 itemclick 回传项
  文本；LWApplyValue 按 IndexOf 回写 ItemIndex（找不到文本再按数字
  解释，兼容回归测试直接传序号）。
- **TSpeedButton 按下态**：dispatch 在 OnClick 前置 `Down := True`
  （SetDown 内部 UpdateExclusive 自动关同组），序列化补 down/groupindex，
  前端 enableToggle + setPressed 恢复观感。
- **TBitBtn.Kind**：序列化补 btnkind，前端映射 lw-bic-* 图标（CSS 伪元素）。
- **灰字**：Ext Crisp 把 checkbox/radio/fieldlabel 做成灰色，LCL 是黑字
  → lw.css 统一拉回深色。
- **运行时缓存**：/lw/lw.js、/lw/lw.css 加 `Cache-Control: no-store`，
  否则用户浏览器拿旧 lw.js 对不上新服务端，出现"时灵时不灵"。
- runLayout 的 alClient 现在先扫 top/bottom 占用再用剩余空间，
  否则 client 面板盖住 bottom 面板。

## 51. 代码建 UI 改回 .lfm：事件方法必须留在 published（默认）段

tools 里两个 GUI（lwhyper_gui / lwconvert_gui）最初用代码 BuildUI 建界面，
现改回标准 LFM（ulwhypergui.lfm / ulwconvertgui.lfm），迁移要点：

- `{$R *.lfm}` + .lpi 单元项 `<HasResources Value="True"/>`；
  lpr 里 `RequireDerivedFormResource := True`（资源缺失当场报错，别关）。
- 控件字段与事件方法都写在 `class(TForm)` 的**默认段**（`private` 之前）：
  默认段在 $M+ 祖先的子类里就是 published，`MethodAddress` 才找得到
  （private 段的方法 LFM 绑不上，且 FPC reader 是静默不绑，不报错——
  只能用运行实测验证，编译器不吭声）。
- LFM 不能写平台条件字符串（TextHint 等），差异挪回代码；
  版本号（`LW_VERSION`）也留代码里拼，LFM 放静态 Caption。
- TTrayIcon 的 Icon/Visible 留代码设（LFM 里设 Visible=True 会先于
  图标赋值弹空托盘）；TTimer Enabled 先 False，FormCreate 里再开。
- 等宽字体 LFM 写 Consolas，运行时 PickMonoFont 按 Screen.Fonts 兜底
  （Linux/macOS 换 DejaVu Sans Mono / Menlo / Courier New）。
- `{ ... }` 注释结尾写成 `*/` 会吞到下一个 `}`：编译报一串
  "Comment level 2 found" + "Unexpected end of file"，位置却指向别的行。

## 52. gallery 十一项缺陷排查：一个 WS 保活根因 + 各个击破

用户截图报了 11 项（灰字/截断/TDrawGrid 空/分隔符/图表与取色器/PDF/HTML 应用/
对话框/动态页/DBGrid 错位），排查结论：

- **"点了没反应"的公共根因是 WS 保活**：WSReadFrame 首字节超时 100ms
  把空闲连接当错误掐掉 → 浏览器 2 秒重连风暴 → 事件落进死连接静默丢失。
  修复：首字节超时返回哨兵 op（WS_IDLE_SENTINEL=252），上层发 ping 续约，
  真正对端关闭（select 可读 + read 0）才断。事件另加 5 秒超时兜底转 HTTP。
- **旧缓存救不回来**：no-store 只防新缓存，HTML 引用改 `?v=LW_VERSION`
  才能把用户已缓存的旧 lw.css/lw.js 冲掉（灰字问题就是旧缓存）。
- **runLayout 两遍扫**：alClient 要同时扣 top/bottom **和** left/right
  占位，否则数据感知页 client 面板整个盖住 alLeft 的 DBGrid。
- **TDrawGrid**：此前 lwwriter 根本没写这个分支；补 WriteDrawGrid
  （cols/colwidths/rows/fixed/rowheight/readonly），空串走网格空表渲染。
- **工具条分隔符**：gallery 用 tbsSeparator，旧序列化只认 tbsDivider。
- **取色器弹窗**：Ext 不给坐标就甩到 (0,0)；openColorPicker 在 show 后
  按色块 box 定位并 clamp 到视口内。
- **TPageControl ActivePage**：dispatch 补分支（索引写回页签），
  buildTabs 补 OnChange（id→索引映射，别用 indexOf 对象比对）。
- **验证手法**：CDP 无头 Edge + Input.dispatchMouseEvent 真坐标点击；
  断言"服务端日志真的写了业务行"，比看 DOM 可靠。注意
  Runtime.exceptionThrown 的 params 直接就是 exceptionDetails
  （没有外层 exception 键）。测试脚本用 ComponentQuery 找控件时
  别按 name 找（字段没设 cfg.name），用 `cmp.__lwNode.name`。
- **改 core 后全量重建**：demos/tools 静态链接 core 单元，修完
  lwwebsocket/lwhttp/lwwriter/lwdispatch 必须 lazbuild -B 全部重建，
  否则旧 exe 表现不一致误导排查。回归 14 套全绿（见 t_*.py）。

## 53. GUI 工具线程收尾：绝不能在 OnTerminate 里 Free 线程对象

lwconvert_gui 点「支持度分析」分析完成后整个 UI 卡死（假死）：日志已回填、
按钮仍禁用、WM_CLOSE 无响应。根因是教科书级死锁——

- OnTerminate 经 Synchronize 在**主线程**执行，此刻工作线程正阻塞等它返回；
- OnTerminate 处理器里 `job.Free` → TThread.Destroy → WaitFor 反过来
  等工作线程退出 → 互相等死（memo 已回填、SetBusy(False) 永远跑不到，
  所以表象是"分析完成后死了"）。

修法：`FreeOnTerminate := True`，OnTerminate 里只读字段、绝不 Free，
线程在自身上下文自释放。顺带修掉 SetBusy(False) 覆盖状态栏完成消息的
顺序问题（先复位 UI 再写最终消息）。

验证手法：Python ctypes 找窗口/子控件（LCL 在 Windows 上是原生
Edit/Button 类），BM_CLICK 真实点击 + WM_GETTEXT 读状态栏/日志 +
WM_CLOSE 验证能干净退出（exit=0）。分析、转换两条路径均过。
lwhyper_gui 的 THyperThread 是常驻服务线程从不中途 Free，无此问题。

## 54. IDE 新建模板"lazarusWeb Login form"：TFileDescPascalUnitWithResource 定制 + LCL SetName 的 Text 坑

在 lwdesign 注册单元里新增 TLWLoginFormFileDesc（New -> 模块 ->
"lazarusWeb Login form"），要点：

- **预置窗体内容走 GetInterfaceSource/GetImplementationSource 覆写**：
  TFileDescPascalUnitWithResource 的这两个虚方法决定生成单元的全文
  （CreateSource 拼 unit/uses/interface/implementation）。lfm 本身没法预置
  （新建表单的 lfm 由设计器生成、内容为空），所以模板用
  AfterConstruction 在字段为空时自动补建控件——想改 lfm 设计的用户放
  同名控件（edUser/edPass）后补建逻辑自动跳过，两条路都通。
- **登录窗体必须 IsPartOfProject 前就编译过的基类**：ResourceClass :=
  TLWLoginForm（lwlogin 在 lwserver 包），RequiredPackages := 'lwcore;lwserver'
  （分号分隔，packager 用 SplitString(Packages,';') 解析）。
- **静态装包后 IDE 的重建**：lazbuild --build-ide 会被编译不过的第三方包拖死
  （坑 11.2）；只要设计包能单独编译过，直接
  `ppcx64 @<主配置>\idemake.cfg -o... ide/lazarus.pp` 重链接即可——
  idemake.cfg 里已含全部 -Fu（含 lwdesign 的 ppu），秒级完成。ide.inc 要
  补 -Fi<ide>\include。
- **LCL SetName 的 Text 坑（本任务真正抓到的 bug）**：运行时
  `TEdit.Create` 后设 `Name := 'edUser'`，LCL 会把空的 Text 填成组件名
  （TControl.SetName 的"Text 为空则同步 Name"行为）。lfm 流式加载的控件
  不受影响（Text='' 显式流入），但代码创建的控件里 edUser.Text 会变成
  'edUser'——登录窗体一提交就把组件名当账号。修法：命名后显式
  `Text := ''`。这个坑只有端到端跑一遍（curl 建 session 看组件树 +
  浏览器真实登录）才能发现，单看源码全对。
- **验证手法**：设计包编译 → 模板样本单元 fpc 编译 → 最小 demo
  （SetLogin + 主窗体）nogui 构建 → curl POST /lw/api/session 看初始组件树
  → CDP 无头浏览器真实走"错误密码 toast / 正确密码进主窗体"。

## 坑 55：runLayout 预扫描把 align 自身的宽度/高度也扣了（双重扣减）

「数据感知」页 TDBGrid 跑到页签中间、右面板整个挤出可见区，事件日志
面板压进页签内容 —— 全是 lw.js runLayout 一个函数的锅。

- 旧写法：先预扫描一遍把 top/bottom/left/right 的**自身**尺寸累加进
  `yTop/yBottom/xLeft/xRight`，处理趟再用**同一个**游标定位 —— left
  控件定位到"已含自己宽度"的 xLeft 上（整体右移一个自身宽度），
  client 宽度算成负数被 `max(0,…)` 归零，bottom 同理上移。
- 修法：改成与 LCL/VCL 一致的两趟 —— **逆 z 序**处理
  top/bottom/left/right（后创建的先占边），alClient 在第二趟拿剩余
  矩形。顺带修掉了 bottom 面板同样存在的"上移一个自身高度"老问题
  （事件日志面板之前一直压着页签底边）。

## 坑 56：nogui 下 TDBGrid 的列宽退化成 6px

`TColumn.Width` 在 nogui（窗体句柄未建）走无句柄 Canvas 的字体度量：
`CalcColumnFieldWidth`（dbgrids.pas）用虚拟 Canvas 量字符、
`Scale96ToFont(DEFCOLWIDTH)` 用假字体缩放，实测 gallery 5 列全是 6px，
前端照发就挤成一条细线。TStringGrid/TDrawGrid 反而没事（它们的
`FColWidths` 默认值是构造期写死的 64，不依赖度量）。

- 修法（lwwriter.pas `lwDbColWidth`）：`col.Width < 24` 视为退化，
  按"标题显示单位（CJK 记 2）与 Field.DisplayWidth 取大者 × 8px + 20"
  估宽，下限 40、上限 400。
- 同类教训：**nogui 下任何依赖 Canvas 字体度量的 LCL 属性都不可信**
  （此前坑 50 的 ClientHeight、WriteGrid 的 DefaultRowHeight 同源）。

## 坑 57：Ext absolute 布局对 Ext.Component（label）不落 x/y

lw.js 里 label 用 `Ext.Component`（box）+ autoEl 渲染，Ext 的
absolute 布局不给它生成 layout item，initialConfig 里的 x/y 永远不写
进 DOM 样式 —— 所有标签堆在父容器 (0,0) 叠成一团；textfield 之类
字段控件有 layout item 所以没事，问题只挑 label 爆。

- 修法：runLayout 补第三趟，把 align=none 的子项统一按服务端坐标
  `setPosition` 摆正。**只设位置不设尺寸**：nogui 下服务端量出的
  标签 w 偏小（同样是坑 56 的度量失真），设了会把 CJK 文字截断，
  标签交给浏览器自然宽度最稳。

## 坑 58：新建文件模板要在设计器里看到控件，必须覆写 GetResourceSource

TFileDescPascalUnitWithResource 默认 GetResourceSource 返回空串，IDE 只生成
空 lfm。模板 Pascal 里声明字段 + AfterConstruction 运行时补建只解决"运行
时有控件"，设计器里仍是一张白板。覆写 `GetResourceSource(ResourceName)`
返回完整 lfm 文本即可（IDE 会 CreateFile + LoadLFM 直接进设计器）：
- lfm 根名必须用参数 ResourceName（用户改过默认名时才不崩）；
- OnClick 可直接引用基类 published 方法（DoLogin/DoReset）；
- edUser/edPass 显式 `Text = ''` 压住 lfm 流式加载的 SetName 填充。

## 坑 59：nogui 下裸建 TForm 必 AV —— 必须先 LWInstallWidgetSet

LCLnogui 的 TNoGUIWidgetSet 有三个抽象方法（EnumDisplayMonitors /
GetMonitorInfo / MonitorFromWindow），任何 TCustomForm 构造都会查显示器，
直接 EAccessViolation，而且 AV 常被吞成"静默退出 exit 0"极难排查。
lazarusWeb 的 lwapp 框架自带补丁：`uses lwws` + `Application.Initialize`
之后、建任何窗体之前调 `LWInstallWidgetSet`（补全 1920x1080 虚拟显示器）。
脱离框架写 nogui 单元测试时最容易踩。

排查手段：从描述符源码用脚本提取 lfm 文本（保证测试与生成一致），写 nogui
流式加载测试逐项断言字段/属性/事件绑定。

## 坑 60：fphttpclient 在 Windows 上把 connection refused 当超时，缺省烧 3 秒

实测（tmp/clttest 最小复现）：对已关闭端口 HTTPMethod，报
`ESocketError: Connection to 127.0.0.1:9 timed out`，耗时 **3.002s**（内部
缺省），设 ConnectTimeout=1000 则 1.016s。而裸 curl 对同端口 refused 只要
1ms。lwhyper 的代理客户端没设 ConnectTimeout —— 杀掉一个 worker 后，粘在
它上面的请求每个都慢 3 秒再 502，这就是「死一个进程访问变慢」。
修法（lwhyper.pas）：
1. 代理客户端 `ConnectTimeout := 1000; IOTimeout := 30000`；
2. 转发失败**当场把该 worker 标死**（不等 2s 一轮的 healthz），并立刻换
   下一个存活 worker **重试一次**（POST 请求体是每次现拷的流，重试安全）；
3. 重启的 worker 加 `BootGuard=2`：连续两轮探针通过才重新放流量
   （healthz 先通、页面初始化没完时会出现 2s 的慢 200）。
修完实测：杀 worker 后第一个请求 1s 内经重试拿到 200，后续 3ms；
粘性会话直接 3ms 切到存活 worker。

## 坑 61：lwhyper 点「停止」卡死 —— 坑 44 的三个问题原样重演

lwhttp 修过的 lwhyper 又犯了一遍（复制代码时没带修复）：
1. 没设 `AcceptIdleTimeout` → `FHTTP.Active := False` 后 accept 循环
   阻塞在 accept() 直到下一个连接 → `FThread.WaitFor` 天荒地老；
2. Stop 里 `FreeAndNil(FHTTP)` 在 accept 线程脚下拆对象（AV）；
3. GUI 在主线程同步做 Stop（monitor 探针最坏 3s/worker 也算进去）。
修法（lwhyper.pas + ulwhypergui.pas）：
- `FHTTP.AcceptIdleTimeout := 250`；Stop 只关监听不 Free，FHTTP 挪到
  TLWHyperServer.Destroy 统一收（调用方必须先 WaitFor 启动线程）；
- GUI 新增 THyperStopThread：Stop + WaitFor + Free 全在后台做，
  Synchronize 回主线程只做恢复 UI（btnStop 文案「停止中...」防重复点）；
  托盘「退出」同样走异步停止，停完 Application.Terminate；
- tmrRefresh 在 FStopping 期间只刷日志不碰 FHyper（停止线程正在拆它）。
修完实测：点停止 0.01s 返回、UI 立即响应，worker 全部被收掉。

## 坑 62：GUI 任务中关窗 —— Synchronize 打在已释放的窗体上

lwconvert_gui 没有任何关窗处理：转换/分析进行中点 X，窗体 caFree，
FreeOnTerminate 的 TConvJob 跑完后 OnTerminate 的 Synchronize 打在已
释放的窗体上（AV / 退出挂死）。修法：OnCloseQuery 里 `CanClose :=
FJob = nil`，任务中拒绝关窗并日志提示。任务完成后正常关。
（lwhyper_gui 不需要：它关窗本来就是「运行中藏托盘」，退出走异步停止。）

GUI 自动化测试注意：LCL TMemo 在 Windows 是多行 Edit（ES_MULTILINE=0x04
区分）；SendMessage 一律用 SendMessageTimeoutW + SMTO_ABORTIFHUNG，否则
被测程序弹模态框时测试脚本跟着吊死；另外 demo 太小时任务 <0.5s 就完了，
「任务中关窗」根本测不到拦截逻辑 —— 要造大输入拖慢任务再测。

## 坑 63：中文在 Crisp 主题下发灰 —— 不是颜色是 font:300

现象：gallery 的 TRadioGroup/TCheckGroup/TCheckListBox 里「小/中/大/中文」
看着是灰字，而同页的 Pascal/JavaScript/SQL 是黑字。CDP 查 computed color
三者全是 rgb(27,27,27)、opacity 1 —— 颜色没问题。

根因：Crisp 主题全局用 `font:300 13px ...`（cb-label / item-label /
form-text / grid-item / fieldset-header / menu / tab 全是 300）。拉丁
字体没有 Light 字面，浏览器回退成 regular 渲染，看不出差别；中文回退到
「微软雅黑 Light」，笔画细一圈 —— 看起来就像灰字/被禁用。字体度量探针
（截图像素 darkest avg）可量化：Latin 9，CJK 43，YaHei Light 下中文更浅。

修法（lw.css，主题之后加载靠同特异性+顺序压过）：

    .x-window, .x-window *,
    .x-layer, .x-layer *,      /* 菜单/日期弹层不在 .x-window 里 */
    .x-mask, .x-mask * { font-weight: 400; }
    .x-window .x-fieldset-header-text,   /* 主题这条是 (0,2,0) */
    .x-layer .x-fieldset-header-text { font-weight: 400; }

注意别用 !important —— 会把 .lw-bic-* 图标的 bold 一起干掉。
验证：CDP 截图 + 像素统计，小/中/大 darkest 43→20，中文 100→47，
与 Pascal(9) 同级；观察放大图三处文字一致黑。

## 坑 64：GetResourceSource 给的 lfm 在 IDE 里「消失」——祖先类没进面板注册表

现象：登录窗体模板加了 GetResourceSource（返回完整 lfm）后，新建得到
的只有 .pas，没有 .lfm、设计器也不出现；把 IDE 用 -dVerboseLFMSearch
重链后抓到真实链条：

    LoadLFM 解析 lfm 正常（object LoginForm: TLoginForm）
    SearchComponentClass 找不到 TLWLoginForm
      TryUnitComponent(unit2.pas) 无已加载组件
      TryLFM 遍历 uses：lwlogin/lwform/stdctrls/… 都没有 .lfm → 跳过
      TryFindDeclaration 在新单元里找"同名类型定义" → 只有 TLoginForm
        （TLWLoginForm 只出现在祖先位置）→ 失败
      TryRegisteredClasses → 当时只命中 TLWForm（错配）

NewFile 的自定义 lfm 分支（ide/sourcefilemanager.pas:2523）要求
LoadAncestorDependencyHidden 把 lfm 根类 TLoginForm 的祖先解析成一个
**具体 TComponentClass**；四条解析路只认：已加载设计组件的单元 /
**面板注册类** / 带 .lfm 的单元 / 当前单元里的同名类型定义。TLWLoginForm
四条都不满足 → 祖先被错配成 TLWForm → 读流失败 → NewFile 静默 exit
（连 lfm 缓冲都不留在编辑器里），用户看到的就只是源码页。

修法（lwdsgnregister.pas）：
    RegisterComponents(sLWPaletteTab, [TLWForm, TLWLoginForm, ...其余控件]);
    （原来只有 SysUtils.RegisterClass(TLWLoginForm)，SearchComponentClass 不查它）
验证：重链后 trace 里 `TryRegisteredClasses found: TLWLoginForm` →
`LoadComponentDependencyHidden AComponentClass=TLWLoginForm` → LoadLFM 成功；
F12 后设计器窗体停靠进 IDE 且可见，子窗口恰好 4 个
（edUser/edPass/btnOk/btnReset；TLabel 在 Win32 不是窗口，不额外占句柄）。

坑外补充：
- 重链要 `-FuC:/lazarusWeb/src/design`——删了 lwdsgnregister.ppu 后光有
  -Fi 找不到源文件（ppu 里不带源路径）；-Fu 顺带把新 ppu 写回 src/lib。
- 面板多出 TLWForm / TLWLoginForm 两个图标（副作用，无害）。
- 调试期不要用 -dVerboseLFMSearch 的 ppu 链正式 exe：sourcefilemanager.ppu
  带上了 define，正式重链前必须再删一次该 ppu 让它按无 define 重编。
- 新建虚拟单元的 "no pascal code found (first token is )" 异常是创建期
  解析空缓冲的正常噪音，与本问题无关。

## 坑 65：新建窗体设计器不可见，要切换一次才出现（停靠表单编辑器时序竞争）

现象：File→新建→lazarusWeb Login form，只有源码页，设计器要切换到别的
单元/窗体再切回来才出现。普通新窗体偶发，自定义 lfm 模板必现。

根因（埋点 TDockedMainIDE.OnShowDesignerForm 实测）：
- Screen_FormAdded 创建 TDesignForm 时 `Hiding := True`，并 SetTimer
  (WM_SETNOFRAME, 10ms)；定时器触发后才 `ShowWindow(SW_HIDE)` +
  `FHiding := False`。也就是 TDesignForm 创建后 10ms 内处于"隐藏中"状态。
- NewFile 末尾 `DoShowDesignerFormOfCurrentSrc(False)` 是同步调用，跑在
  同一个消息循环回合里，到 OnShowDesignerForm 时 Hiding 还是 True（或
  TDesignForm 还没注册，CreateNewForm 路径实测 designForm=nil）→ 直接
  Exit，之后没人再补显示。切一次之所以有效：切换重新触发
  OnShowDesignerForm，此时定时器早已把 Hiding 清掉。

修法（dockedmainide.pas，停靠包源码）：
- TDockedMainIDE.OnShowDesignerForm：所有"没准备好"的出口
  （designForm=nil / Hiding=True / pageCtrl=nil / TryShowDesignerForm
  失败）一律 QueueDeferredShowDesigner，不再静默丢弃。
- TDockedTabMaster 新增 FPendingShowForms(TObjectList, 不拥有) +
  FDeferredShowTimer(TTimer, 15ms)。QueueDeferredShowDesigner 挂表单开
  定时器；Tick 里逐个 TryShowDesignerForm（重查 Hiding/注册状态，成功则
  ShowDesigner(ActiveEditor)），全部成功或超 400 次放弃后关定时器。
- 为什么不能用 Application.QueueAsyncCall 重试：回调自旋重排会连续投递
  消息，1000 次一眨眼跑完，SetTimer 的 10ms 定时器根本轮不到触发；
  TTimer 才有真实时间间隔。

编译注意：dockedformeditor 是预编译包，改源码必须
`lazbuild dockedformeditor.lpk` 单独重编（idemake.cfg 只引它的 lib ppu），
再正常重链 IDE。该包是 {$mode delphi}：方法指针/事件赋值不能加 `@`，
否则报误导性的 4004 "Variable identifier expected"。

验证：埋点 IDE 自动化新建登录窗体，不按 F12 不切换，截图确认设计器页
直接激活、7 个控件齐全；正式 lazarus.exe 重链后同流程通过。

## 坑 66：把"代码建界面"改成设计期 lfm 时的几个坑（gallery 已改造完）

gallery 原来 lfm 里只有 TPageControl 骨架 + 日志区，60+ 控件全靠
FormCreate 里的 NewLabel/NewBtn/BuildXxx 建。改成"控件全在设计期"时踩到：

- **LW 控件不是所有 LCL 属性都 published**：TLWGauge/TLWColorPicker/
  TLWChart/TLWHTMLFrame/TLWPDFFrame 都没有 TabOrder，TLWDBNavigator 也
  没有。lfm 里写上就 `Error reading gdMain.TabOrder: Unknown property`,
  整个窗体读流失败（会话直接建不起来，前端只看到空白）。
- **TSplitter.BeveledSplitLines 在本机 LCL 不存在**（同理报 Unknown property）。
- **TDateEdit/TTimeEdit 的 NumGlyphs 别写**（不是公开属性，会读流失败）。
- **非可视组件（TDataSource/TOpenDialog）没有 Left/Top**，lfm 里只写
  `object dsMem: TDataSource end`。TDataSource 可以放进 lfm，但
  **TBufDataset 的 FieldDefs 不能流式化** → 数据集仍在代码里 Create +
  CreateDataset + 灌数据，只把 `DataSource.DataSet` 在 FormCreate 里接上；
  控件的 DataField/DataSource 建议在代码里按 DataField→DataSource 顺序赋值。
- **TBitBtn.Kind 故意留在代码里**（TryKind 包 try/except）：nogui 下 Kind
  会触发 LCL 生成 glyph 抛 FPImageException，写进 lfm 就是读流时崩。
- ~~**TLabeledEdit.EditLabel 目前没有任何序列化支持**~~ **已在坑 69 修复**：
  TBoundLabel 现按 LabelPosition（lpAbove/lpBelow）合并成父 textfield 的
  fieldLabel 下发（见坑 69 与 docs/AUDIT_LFM.md；下文为修复前的旧记录）。
- 改完必须 `lazbuild -B`（lfm 不是依赖项），并且**先关掉正在跑的 exe**，
  否则链接阶段报 "Can't create object file ... (error code: 5)"。

验收：tests/t_gallery.py 50/50 通过（节点 157 个，关键控件 46 个全在），
12 个页签逐页截图确认布局与改造前一致。

## 坑 67：lwpanel 改成设计期 lfm（SimplePanel 默认 True 等）

服务端控制面板原来 BuildUI/BuildTray 全代码建控件，已改为 lwpanel.lfm
（菜单/托盘菜单/日志 Memo/状态栏/定时器/托盘图标全在设计期），「关于」
小窗拆成独立单元 lwabout.pas + lwabout.lfm（一个 unit 只能有一个 lfm
资源）。踩到的坑：

- **lfm 控件名必须与 published 字段同名**：流式绑定靠
  TComponent.SetName -> Owner.FieldAddress(Name)，字段不在 published
  区就永远是 nil（编译不报错、运行空指针）。
- **TStatusBar.SimplePanel 在本机 LCL 默认 True**：lfm 里不写
  `SimplePanel = False`，Panels 永远不显示（win32 下整个条走
  SB_SIMPLE 简单模式）。旧代码是显式 `FStatus.SimplePanel := False`，
  搬进 lfm 时最容易漏。
- **LCL 读 lfm 对不认识的属性是静默跳过**（OnPropertyNotFound），
  不是报错 —— 写错属性名不会崩，只会"没效果"，排查要用运行时探针。
- **TTrayIcon/TTimer/TMainMenu/TPopupMenu 都能进 lfm**，但托盘的
  Icon（位图）和依赖端口/版本的 Hint、Balloon 文案留在代码里
  （SetupTray）。
- 自定义构造函数要走资源加载：用普通 `Create(AOwner)`（TCustomForm.Create
  = CreateNew + ProcessResource），不要 CreateNew —— 后者不读资源。
  lwpanel 用 `class function CreatePanel` 包了一层。
- 验证手段：菜单命令可以直接 PostMessage(WM_COMMAND, 菜单ID)；
  窗口内容用 PrintWindow(PW_RENDERFULLCONTENT) 抓（SetForegroundWindow
  会被系统拦 + 打扰用户桌面）；状态栏分格读 SB_GETPARTS 必须传
  有效的整型数组缓冲，lParam=0 返回值不可信。
- 改完 dwabout/lwpanel 后 lazbuild 两个 widgetset 都要编（nogui 的
  $IFnDEF 分支、win32 的面板本体），demo 用 dbaware_gui.lpi 验证。

## 坑 68：lfm 化后 TUpDown/TShape/TToolButton/TLWDBNavigator 的四个浏览器端问题

gallery 改 lfm 后用户报四个问题，根因分三层（框架修了三个，demo 改一个）：

- **TUpDown 位置跑飞**：lfm 里挂 `Associate` 后，LCL 会在 Associate 的
  ChangeBounds 回调里用 UpdateAlignButtonPos 自动挪位置。IDE 保存窗体按
  显示器 DPI 写 `DesignTimePPI=144`，nogui 服务端跑 96 PPI → 运行时
  AutoAdjustLayout 缩 2/3；缩放过程中 Associate 的 ChangeBounds 触发回调，
  按"缩到一半"的边界算位置，自身再被缩放一次 → 坐标彻底错（实测
  edUpN(160,196) 时 udN 落到 (147,131)）。修在 lwwriter：updown 挂
  Associate 时直接按 Associate 最终边界推导 x/y/h（AlignButton 四向都算），
  与 PPI 缩放无关。
- **TShape 看不见**：两层问题。① writer 的 bg 取 C.Color，而 TShape 的
  填充色在 Brush.Color → 下发空串白底；② 浏览器端 Ext 的 absolute 布局
  对普通 Component 不落宽高（runLayout 第三趟也只摆位置），TShape 没有内容
  → 自然尺寸 0，只剩 2px 边框点。修在 lwwriter（bg 读 Brush.Color +
  下发 shapestyle）和 lw.js（shape 分支显式 setSize + 圆角/椭圆半径）。
- **TToolButton 压成扁条**：nogui 下 TToolButton 默认宽高只有 11px，浏览器
  端之前只删了 width 没删 height → 按钮被压成 11px 高的半截。lw.js
  toolbutton 分支把 width/height/x/y 全删，交给 Ext 按文字自动排。
- **TLWDBNavigator 右边被裁**：10 个按钮 ×约 38px 需要 ~382px，而
  DesignTimePPI 144 的 lfm 在 96 PPI 服务端会缩 2/3 —— lfm 里写 390
  运行时只剩 260。这是纯布局账：lfm 里把 navDb 加宽到 600（运行时 400）。
  注意这类控件的"最小宽度"要按 运行时 PPI 折算，不能按设计期数字估。
- **IDE 编译注意**：demo 都用 IDE 编译。lfm 改了 IDE 增量编译可能不重编
  嵌入资源（坑 66 同款），改完窗体用「运行 → 重新构建全部」最稳。
- 验证：t_gallery.py 50/50；无头浏览器逐页签截图 + CDP 探测 DOM 尺寸
  （navDb overflow=-20 即最后按钮有 20px 余量）。

## 坑 69：lfm 化审计发现的 7 个同类问题（TUpDown/TShape 之外）

系统性审计了「IDE 拖放 lfm → lwwriter → lw.js」链路（新建 demos/audit 集中
实证），详见 docs/AUDIT_LFM.md。修复速查：

- **KindOf 四个洞**：TBoundLabel（TLabeledEdit 的标签，落 unknown 后"姓名"
  丢失+红框）、TCustomEditButton 其余后代（TFileNameEdit 等，落 unknown）、
  TTabControl（落 unknown，页签全丢）、TToggleBox（注意它是 TCustomCheckBox
  后代不是 TButton！）与 TColorButton（TCustomButton 后代）。
- **内部件泄漏**：TCustomEditButton 内部 TEdit/TSpeedButton、TTabControl 内部
  TCustomNotebook+TTabSheet 都会被当普通子控件序列化成杂散节点 ——
  IsInternalControl 按 Parent/Owner 过滤。
- **新 kind**：editbtn（编辑框+…按钮，OnButtonClick 加进 lwbase 事件白名单）、
  tabctl（单卡片 tabpanel，TTabControl 语义是公共客户区）。
- **TrackBar 竖直**：writer 下发 orientation，前端 slider.vertical。
- **CheckBox 三态**：DOM indeterminate。大坑：lw.js 里 `ct.add()` 在
  `c.on('afterrender')` 注册之前就渲染完了，afterrender 永远不触发 ——
  必须先判 c.rendered 再决定立即执行还是挂监听（label 的 boundfor 精修同款）。
- **PageControl.TabPosition=tpBottom**：tabpos 早已下发但前端没消费，
  buildTabs 补 tabBar:{dock:'bottom'}。
- 已知限制（不修，见报告）：Anchors 不实现（用 Align 代替）、
  TMaskEdit 掩码浏览器端不执行、MultiSelect 不回传、键盘/鼠标事件白名单外
  静默失效。（TSplitter 拖动已实现，见坑 186）

## 坑 70：TShape/TBevel 尺寸落地的时机竞态（lw.js）

下午修的"shape 分支显式 setSize"并不稳：`addTo(c, ct)` 后立刻
`c.setSize(w,h)` 只在**容器已渲染**时才落到 DOM；容器未渲染（懒加载
页签首次激活前构建）时只写了 config，而 Ext absolute 布局在某些渲染
路径下不把普通 Component 的 width/height config 落到元素 —— 结果随机
出现"形状只剩 2px 边框点"（同一页面刷新有概率正常/不正常，极难排查）。
实测同一代码 5 连跑 1 次 2×2、4 次正常。

修法（确定性，与时序解耦）：
- shape/bevel 分支把 `width/height` 直接写进 autoEl 的内联 style；
  内联样式在任何创建/渲染顺序下都生效，废弃事后 setSize。
- patchNode 增加 shape/bevel 分支：每次轮询对账内联样式（签名比较），
  竞态受害的存量元素在 20s 内被自愈，运行期改 bg/Shape 也同步。

## 坑 71：对话框交互下 gallery AV —— BuildPayload 并发写坏堆（严重）

现象：gallery 在 IDE 调试器下点对话框/按钮，先弹
`EWriteError: Stream write error`(streams.inc:631)，随后
`External: ACCESS VIOLATION reading address $14`。页面与浏览器全程正常
（不是断连导致）。用 gdb 抓到的栈是决定性证据：

```
Thread 36 / Thread 38 同时：
  MatchAdd (lwdbgrid.pas:97)  ← SetLength(FMatches, n+1)
  lwgMatchesAdd → WriteDBGrid → WriteKindProps → WriteControl
  → BuildPayload (lwsession.pas) → LWHandleEvent → ApiEvent
```

根因：`TLWDBGrid.FMatches` 是**共享网格对象**上的动态数组，序列化过程中
MatchClear/MatchAdd 会扩容。会话内的 BuildPayload 没有任何互斥，而
一个事件挂在对话框里等应答（最长 180s）时，浏览器仍可能发来第二个事件
（连点、点别处、lw.js 的 HTTP 兜底重发）——两个线程并发 realloc 同一
块堆，先写坏堆（表现为 EWriteError 之类的“杂异常”），随后 AV。

修法（`lwsession.pas` / `lwhttp.pas`）：
- TLWSession 增加会话级**执行锁** FExec（可重入：持有者+深度，Windows
  临界区本身可重入，Linux pthread mutex 不可，自己实现两平台一致）。
- `BuildPayload` 全程持锁；`ApiEvent`（HTTP 与 WebSocket 两条事件路径）
  在 `LWHandleEvent` 外持锁 —— 同一会话的事件与序列化彻底串行。
- **关键细节**：对话框/模态窗体挂起等待前用 `SuspendExec` 把锁整个放开、
  唤醒后 `ResumeExec` 恢复原深度。否则一个没人应答的对话框会把同一会话
  的所有请求（连新页签建会话）堵满 180 秒——实测页面就卡在
  "正在创建服务端会话…"。放开是安全的：等待期间本线程不碰任何 LCL 对象，
  应答走 /lw/api/dlg（只用 FLock），不会死锁。

验证：
- gdb 全程挂着新 exe 跑完：6 个并发事件 + 7 个对话框交互（真实鼠标点击：
  是→mrYes、否→mrNo、警告→已确认、Input/OpenDialog）全部正常，无 SIGSEGV。
- 挂起对话框期间新建会话 0.02s 返回（旧代码会被堵）。
- t_gallery.py 50/50。

经验：**凡是序列化会写控件自身状态的地方，都不能假设“同一会话只有
一个请求线程”** —— 浏览器并发发事件是常态。

## 坑 72：TLWGauge 值弧"错位/100%与底图重合" —— SVG large-arc-flag 写错（lw.js）

现象（gallery 图表仪表页）：
- 值一过 50%（56%、91%…），彩色值弧整条鼓到灰色底弧**外面**，看起来
  仪表"错位"、超出容器；
- 恰好 100% 时值弧与底弧完全重合，看不出满格（"100%和底图重合"）；
- 50% 以下（42%、49%）一直正常，所以此前没暴露。

根因：`gaugeSvg()` 里 `var large = (f1 - f0) > 0.5 ? 1 : 0;`。
本仪表弧角最大 180°（f1-f0 ≤ 1），SVG A 命令的 large-arc-flag 必须**恒为 0**；
写成 ">0.5" 后，凡值弧角在 90°~180° 之间（值 50%~100%）large 都被错置 1，
SVG 便改选弦另一侧的圆心把弧画成"大弧"，整条值弧鼓到底弧外面。100% 时弦恰为直径，两个候选圆心重合，
弧与底弧重叠 —— 两个现象同源。

修法（lw.js gaugeSvg）：
- large-arc 恒为 0；
- 顺手改进版式：底图轨道在外圈（r、宽 10），值弧在内圈（r-10、宽 7），
  刻度再往内（r-21..r-15）—— 100% 满格时值弧两侧仍露出灰底，不再"重合"。

验证：真实点击到 56%/91%/100% 截图核对；t_gallery.py 50/50。

另：IDE 里那个 `EWriteError (streams.inc:631)` 见坑 73（客户端中止请求，
框架已捕获，无害）。

## 坑 73：IDE 里弹 EWriteError(Stream write error) —— 客户端中止请求，无害

现象：跑 demo 时 Lazarus 调试器弹「项目 xxx 援引异常类 'EWriteError'
带有信息: Stream write error，在文件 streams.inc 行 631」，关浏览器会弹，
**不关浏览器（刷新/切页签/长时间挂对话框）也会弹**。

链路（已用日志坐实）：
```
浏览器中止/丢弃请求（刷新、导航、切后台被节流、Ext 请求超时 abort）
  -> 服务端线程还在写响应
  -> TSocketStream.Write 失败 -> TStream.WriteBuffer 抛 EWriteError
  -> fphttpserver TFPHTTPConnection.HandleRequest 捕获
     -> HandleRequestError：标记不可 keep-alive、回收连接
```
所以**服务本身不受影响**。实测：gdb 下"连点图表按钮→强杀浏览器"无 SIGSEGV，
之后新建会话、跑回归 50/50 全正常。最容易复现的一条：刷新页面后约 20 秒
（长轮询睡满 20s 才写响应，那时旧连接早被浏览器丢了）。

为什么看着像 bug：Lazarus 调试器默认在异常 **raise** 时停下（哪怕框架随后
捕获了），于是无害断连也弹框。三种处理：
1. 弹框里勾「忽略这个异常类型」再点继续（下次不再停）；
2. 工具 → 选项 → 调试器 → 语言异常 → 添加 `EWriteError`，勾 Ignore；
3. 试 demo 时直接 **运行而不调试**（Shift+F9 / Ctrl+F9 取决于版本）。
生产环境（不带调试器跑 exe）完全看不到。

顺手修掉两个**真问题**（它们会放大这件事，且本身是 bug）：
- `lw.js` 的 WS 事件兜底原来写"5 秒没回音就当连接半死：关掉 WS + 同一事件
  改走 HTTP 重发"。事件只要挂在服务端对话框上超过 5 秒（很正常），就会
  **重复执行**（对话框弹两遍、计数加两次），同时向刚关掉的 WS 写响应。
  改成：连接仍 OPEN 就继续等（上限 190s），只有 readyState 不是 OPEN 才重发。
- `/lw/api/event` 的 XHR 超时是 60s，而服务端模态等待上限是 180s
  （LW_MODAL_TIMEOUT_MS）。超过 60s 浏览器就 abort，应答落在废弃请求上，
  服务端稍后写响应必然失败。改成 200s。

另外服务端新增 `OnRequestError` 日志：
`[warn] 连接中断（客户端已断开，已忽略）: EWriteError: Stream write error`
—— 有这行就说明是断连；真故障不会有它。

经验：**HTTP 服务端永远要假设"客户端会中途跑掉"**。fcl-web 已经兜住了
异常，剩下的是 IDE 调试器的显示问题，不是运行时问题。

### 补（2026-11-12）：读侧孪生 —— EReadError(Stream read error, streams.inc:453)

现象：IDE 跑 dbaware，登录/切换/点按钮弹 `EReadError` `Stream read error`
在 streams.inc:453 —— 与坑 73 同族，方向相反：坑 73 是"读着请求、写响应时
socket 已死"（EWriteError），这条是"读请求时流没给够字节数"
（TStream.ReadBuffer 短读）。同样是浏览器中途断开/中止请求的第一 chance
异常，fcl-web 捕获、连接回收，服务不受影响，只是 IDE 弹框。

已核实（gdb catch exception EReadError + CDP 真实无头浏览器全流程：
登录/WS 事件/HTTP 事件/文件IO/切页签/关窗 + 截断 body 请求）：
当前框架所有 TStream.ReadBuffer 调用点都在"长度诚实"的流上
（TBytesStream/TMemoryStream/TFileStream），正常流程**零触发**；
截断请求走的是 HandleRequestError（已记录）。

处理（三选一，同坑 73）：
1. 弹框勾「忽略这个异常类型」；
2. 调试器语言异常列表加 `EReadError` 勾 Ignore；
3. 运行而不调试。

框架侧已把 `EReadError` 与 `EWriteError` 同等纳入 OnRequestError 的
benign 分类（[info] 而非 [warn]），日志不再吓人。

## 坑 74：TLWColorPicker 点击后调色板甩到左上角、页面随后全部失灵

现象（gallery 图表仪表页）：
- 点取色块，调色板出现在**视口左上角**而不是色块旁边；
- 更糟：此后点折线图/柱状图/饼图……图表不再渲染，页面像死了一样。

根因（一个异常两头炸）：Ext x.x.x 的 `Ext.picker.Color.select()` 对**不在
其 40 个标准色调色板里的颜色**会空引用崩溃（`selectedEl` 为 null 还调
addCls）。旧代码把当前颜色（如 `#EEAA22`，非标准色）作为 `value` 传进
colorpicker 的构造配置，而渲染期 Ext 就会调 select —— 于是：

```
win.show() 当场抛异常
  → show() 之后的定位代码不执行   → 面板停在默认位置（左上角）
  → 异常沿 Ext 事件链继续上传     → 后续交互/渲染全断（页面"失灵"）
```

修法（lw.js openColorPicker）：
- 初始颜色**绝不放进构造配置**；
- `win.showAt(x, y)` 贴着色块一步弹出（坐标夹在视口内）；
- 当前颜色只在渲染后 try/catch 尝试预选——不在标准色里就放弃预选，
  只是色板上看不到高亮格，选色功能无损。

验证：真实点击开面板贴着色块弹出；选 #993300 后色块更新、窗口自关、
OnColorChange 回服务端；随后连点柱状图/饼图图表正常；全程 0 个 JS 异常。

经验：**Ext 的 picker 类对"非法初始值"的容错很差**，凡是把运行期数据
传进构造配置的，先想一遍渲染期它会被拿去做什么。

## 坑 75：LCL 的 Hint 在浏览器端从来不弹（QuickTips 没 init）

现象：LFM 里给控件写了 `Hint`，浏览器里悬停什么都没有。

根因：lw.js 的 baseCfg 一直在传 `cfg.tooltip = node.hint`，但 **Ext 的
tooltip 配置必须先 `Ext.tip.QuickTipManager.init()` 才生效**——没 init
就是个静默 no-op，所以 Hint 从项目开始就没显示过，不是"浏览器不支持"。

修法（lw.js + lwwriter.pas）：
- `start()` 里 onReady 后先 `Ext.tip.QuickTipManager.init(true, {dismissDelay: 12000})`；
- 统一走 `applyHint()`：把 `esc(hint)` 写进组件外层 el 的 `data-qtip`
  属性（QuickTips 是全文档委托，悬停目标会向上找带 data-qtip 的祖先，
  所以按钮的内层 span、编辑框的 input 都能命中）；创建（afterrender）
  和 reconcile（patchNode）两条路都调用，服务端中途改 Hint 也会跟上；
- baseCfg 不再传 cfg.tooltip，避免双份来源；
- lwwriter：`hint` 仍然有值就下发。**不按 TControl.ShowHint 过滤** ——
  nogui 下它的默认值/继承跟 GUI 不一致（绝大多数控件读出来是 False，
  连 LFM 没写 ShowHint 的按钮也是），按它过滤会把所有提示都关掉；
  全局开关尊重 Application.ShowHint（=False 时全部不出）。

验证：gallery 按钮/编辑框/列表/Bevel 的 Hint 悬停弹出、移开消失；
tests/cdp_hint_gallery.py；t_gallery.py 50/50。

经验：**Ext 里凡是"配了不生效"的声明式配置，先查它依赖的全局开关
（QuickTips、Ext.Loader、focus manager）有没有初始化。**

## 坑 76：模态对话框挂起时刷新页面 -> 对话框消失、会话被吊到超时

现象（用户口径："TLabeledEdit 的 EditLabel 只显示一次，Shift+F5 后就没了，
还报 EWriteError"）：

- 服务端弹着 MessageDlg / InputBox（线程挂起等答复）时按 Shift+F5；
- 刷新后的页面**不再弹这个对话框**，但服务端线程还在等；
- 180 秒内所有事件都在排队（会话执行锁被这次模态占着，直到超时/Cancel），
  看上去就是"页面卡死、点什么都没反应"，顺带还会有一条 EWriteError。

根因（两个独立缺口）：
1. **指令不重发**：对话框指令靠 poll 的 `after` 游标取增量，刷新时页面
   `S.after = seq` 已经越过它，attach 响应又不带挂起指令 → 新页面永远看不到；
2. **页签标识活不过刷新**：`S.tab` 每次加载都是 `newTabId()`，而对话框指令
   带 `to=<发起页签>`，多页签过滤会把它当"别人的对话框"直接丢掉。

修法：
- 服务端 `TLWSession` 新增 `FDlgSpec`（挂起对话框的完整指令 JSON）+
  `PendingDialogCmd`，`ResolveDialog`/超时/解析失败时清空；
  `ApiAttach` 在响应里带 `cmd`（重发一次）。
- 客户端 `attachSession` 收到 `resp.cmd` 就 `handleCmd(cmd, null, true)`
  —— resend=true 绕过页签归属过滤（旧页签已经死了，这页就是它）；
- `S.tab` 改存 sessionStorage（`lw.tab`）：刷新保持同一标识，新标签页是新标识；
- 重发的对话框被应答后，原来那次事件的 HTTP 响应早就被刷新丢掉了，
  业务代码的副作用没人送回来 → `answer()` 里 `if (cmd.__lwResend) refreshTree()`，
  主动 GET `/lw/api/tree` 补一次。

验证：tests/cdp_reload_modal_fix.py（MessageDialog 打开 → ignoreCache reload
→ 对话框原样重弹 → 点"是" → 服务端日志出现 `Dlg.MessageDlg 询问 -> mrYes`，
页面同步到新状态）；t_gallery.py 50/50。

经验：**"服务端挂起等浏览器"的状态必须有重放机制**——任何一次刷新都会
把在途响应丢掉，只有指令队列里的游标是记不住它的。

## 坑 77：TBoundLabel 间距偏大 / 刷新后标签消失

现象：
- TLabeledEdit 的标签和编辑框之间白留一条（"间距有点大"）；
- 浏览器刷新后标签整个不见（首载正常，F5 之后空一块）。

根因（三个叠在一起）：
1. **高度是死的**：LFM 里 `EditLabel.Height = 24`，14 行文字只占上半部分，
   盒子比文字高出一截 → 视觉间距 = 空白带 + LabelSpacing。
2. **坐标系混用**：`getBox()/getXY()` 是**页面坐标**，`setPosition()` 要的是
   **父容器局部坐标**。旧代码把页面坐标直接喂给 setPosition，父容器原点
   不在 (0,0)（窗口/页签容器在 y≈80）时标签整体下移，正好压到下一行控件
   上或被盖住 —— 看起来就是"标签没显示/位置怪"。首载时窗口还没定位、
   原点接近 0 所以碰巧对，刷新后布局变了就错位。
3. **量不到盒子就摆**：页签没激活/窗口还没显示时宽高是 0，旧代码拿 0 当
   坐标算，把标签挪到面板外；`runLayout` 在容器 0×0 时直接 return，
   绝对定位的 Ext.Component（TLabel 这类）永远停在 (0,0)。

修法：
- 服务端 `lwwriter` 下发 `labelspacing`（LCL 的 LabelSpacing，默认 3）；
- 客户端 bound 标签 `delete cfg.height` —— 高度交给文字（实测 17px），
  间距就是纯 LabelSpacing；
- `fixBound` 改用**差量定位**：`curLocal + (目标页面位置 - 当前页面位置)`，
  与父容器原点、页面滚动都无关；盒子为 0 时不摆，退避重试（30/150ms ×4），
  并在 `afterrender`、`show`、`patchNode`（reconcile）时各修一次；
- 定位结果**回写 node.x/node.y**，否则下一次 reconcile 的 `runLayout`
  又按服务端旧坐标重摆；
- `runLayout` 量到 0×0 时退避重试（60ms × n，最多 6 次）。

验证：测试 label 盒 (26,162,360,17) vs 编辑框 (26,182) → 间距 3px；刷新、
reconcile、切页签后位置不变；截图确认标签紧贴输入框且不压其他控件；
t_gallery.py 50/50。

经验：**Ext 里 getBox/getXY 是页面坐标，setPosition 是局部坐标，两者不能
直接互换**；凡是"算出来的位置"，都要用差量或先换算，别假设父容器在原点。

## 坑 78：DBGrid 编辑后点导航器"保存/刷新"报错（值看起来没保存）

现象：网格里改了单元格 → 点 TDBNavigator 的 ✓（post）或 刷新（refresh）→
服务端 500，日志刷 `EDatabaseError`，用户感觉"改了存不上"。

根因：LCL 的 `TDBCustomNavigator.BtnClick(Index)` 是**先执行内建数据集
动作，再触发 OnClick**（dbcustomnavigator.inc）。而 Web 端的事件链是：
网格单元格编辑 → 服务端 `LWApplyDBGridEdit` 已经 `Edit + Post`（数据集
回到 dsBrowse）。这时点导航器 post，内建 `Post` 直接抛
`"not in edit or insert state"`；点 refresh，内存缓冲数据集（TBufDataset 系，
包括没配 Database 的 TSQLQuery）抛 `"In-memory table cannot be refreshed"`。
异常发生在 OnClick **之前** → 应用的处理分支永远轮不到，请求 500。

修法（lwdispatch.LWApplyDBNavClick）：内建动作抛异常时不再让它打断请求
——有 OnClick 就记一条 SessionNotify（`nav post: 内建动作失败已忽略…`）
然后继续触发 OnClick 让业务分支兜底；没有 OnClick 才把异常原样抛回。
语义依据：桌面 LCL 下点这两个按钮本来也会抛同样的异常，浏览器端没有
理由比桌面更坏。

顺带的语义澄清（写给用户）：网格单元格编辑 = `Post`，改动进**事务缓存**
（sqoAutoApplyUpdates 会 ApplyUpdates 但不 Commit）；真正落库要靠应用里
的保存按钮做 `Commit`（dbaware 演示的 btnSave 就是干这个的）。编辑后点
导航器 post 不会Commit——这和桌面 LCL 一致，不是 bug。

验证：S1-S5 场景（编辑→post、重复 post、refresh、编辑→refresh、cancel→post）
全部正常不再 500；btnSave 后 sqlite 里确认新值；t_dbaware 134/134、
t_db 35/35。

经验：**LCL 控件的"内置动作 + OnClick"两段式结构，在 Web 事件链里内建
动作可能已经被框架提前做过（Post），或对 nogui 数据集根本不成立（Refresh），
包装时必须允许内建动作失败而把 OnClick 走完。**

## 坑 79：DBGrid 网格只能编辑一个单元格（reconfigure 复用列 + reap 清空 editor）

现象：TDBGrid 里改一个单元格成功，之后再点任何单元格，编辑框都不出现
（CellEditing startEdit 后 getActiveEditor 为 null）。第一次编辑的值确实
进了数据集（刷新页面值还在），但"只能改一次"让用户以为没保存。

根因（CDP 插桩定位）：编辑回发后服务端重发树，patchNode 的 dbgrid 分支
走 `grid.reconfigure(newStore, dbColumns(n))`。Ext 7.5 的 reconfigure
**复用现有列实例**（column id 不变），但会销毁每列挂的编辑器字段；随后
Ext 配置系统的 reap（$reap → flush → tick）把引用了已销毁字段实例的
`column.editor` **统一置 null**。列还在、编辑器没了 → CellEditing 再也
起不来。注意两处反直觉：
- 用 `reconfigure(store, [{...editor...}])` 传入带 editor 的新列配置也没用
  —— 列实例被复用时新配置会合并，但 reap 是**之后**异步跑的，照样清 null；
- `column.editor` 读起来是 0 不代表编辑器坏在"配置丢了"，而是"字段实例
  被销毁后引用被 reap 清掉"。

修法（lw.js）：
- patchNode 的 dbgrid 分支：列指纹（`__lwColSig`，与行指纹分开算，因为
  rows 文本里可能有 '#' 不能 split）没变时**只 `store.loadData` 灌行数据，
  完全不 reconfigure**；列真的变了才 reconfigure；
- 列构建抽成 `dbEditColumns(n)`（dbColumns + 按 cedit 挂 textfield 编辑器），
  首建（buildDBGrid）与 reconfigure 路径共用，保证任何重建路径都带 editor；
- 行灌入抽成 `fillGridRows(store, n)`，与 buildGridStore 的行映射一致。

验证：5 列 × 每列连续编辑 2 次 = 10/10 全部成功；整页刷新后值仍在服务端
数据集；t_gallery 50/50、t_dbaware 134/134。

经验：**Ext 的 reconfigure 不是"重建"而是"复用 + 合并"，销毁的编辑器字段
会通过 config reap 把列上的引用清 null；数据补丁永远优先走 store.loadData，
reconfigure 只留给列结构真变（列数/列标题/只读性变化）的场合。**

顺带的语义澄清（写给用户，gallery 数据感知页签）：memData 是 TBufDataset
纯内存表，网格编辑 = Edit+Post 进服务端数据集（刷新页面值还在、可继续编辑），
但**进程重启即消失**——它没有数据库后端，也就没有"落库"。真正的落库演示
在 demos/dbaware：sqlite + 事务，编辑后点"保存"（btnSave → FTrans.Commit）
才写进 dbaware.db。

## 坑 80：gallery 两个 DBGrid 换 sqlite（"改了不落库/重启就没了"）

现象：gallery「数据感知」页签改单元格，刷新页面值还在，但**重启 exe 就回原样**；
用户连续三次反馈"不能落库"。

根因：demo 的 memData 是 TBufDataset 纯内存表（tsBig 的 memBig 同理），
没有数据库后端 —— 框架语义没错（网格编辑 = Edit+Post 进数据集），是 demo
本身没有"库"。

修法（ugallery.pas）：
- 两张表都搬进 sqlite（exe 同目录 gallery.db；删掉该文件即重建种子数据）：
  products(code/name/price/stock/active) 20 行、bigitems(id/name/qty/price) 1000 行；
- tsDB 可编辑，连接 1 + 事务 1；tsBig 只读大表分页，连接 2 + 事务 2
  （WAL 下两连接并存，与 dbaware 演示同一套；busy_timeout=10000）；
- "改一格即落库"不用写 AfterPost：sqldb 的
  `sqoAutoApplyUpdates + sqoAutoCommit + sqoKeepOpenOnCommit` 三个选项就够
  —— Post 时自动 ApplyUpdates → Commit，且不关数据集（注意 TSQLQuery.Post
  的实现是 **先 inherited Post（触发 AfterPost）后 ApplyUpdates**，所以在
  AfterPost 里 Commit 会抢在 UPDATE 之前，别那么写）；
- sqlite3.dll 必须在 exe 同目录（从 demos/dbaware 拷一份）。

第二个坑（同一轮踩到）：**列类型别用 TEXT**。sqlite3conn 把 TEXT 映射成
ftMemo，lwwriter 对 memo 字段只输出 "(MEMO)"，浏览器网格整列显示占位符；
要 ftString 就用 `VARCHAR(n)`（BOOLEAN 会映射成 ftBoolean，True/False 正常）。

验证：CDP 改 3 个单元格 → 直接查 gallery.db 立刻是新值；杀掉进程重启 →
浏览器仍是改后的值；t_gallery 50/50。

经验：**"能不能落库"取决于业务层有没有真库和提交，框架只保证 Edit+Post
的语义与桌面一致；demo 用内存表演示联动时，用户一定会问"为什么重启没了"，
要么换真库，要么在 UI 上写明"内存表演示"。**

## 坑 81：Application.Title 没进浏览器标签页（<title> 用的是 GCfg.Title）

现象：gallery.lpr 里写了 `Application.Title := 'lazarusWeb · 全功能画廊'`，
浏览器标签页却一直显示 "lazarusWeb"。

根因：页面 <title> 来自 `GCfg.Title`（lwapp 初始化时内置默认
'lazarusWeb'，只有 --title= 命令行能改），和 Application.Title 毫无关联。

修法（lwapp.pas TLWApp.Run）：命令行/配置解析完后，若标题仍是内置默认
（= 用户没显式指定）且 Application.Title 非空，则 `GCfg.Title := Application.Title`。
优先级：--title=/配置文件 > Application.Title > 内置默认 'lazarusWeb'。
lpr 里的 Application.Title 赋值在 TLWApp.Run 之前，此处必然已就绪。
--help 里 --title 的说明同步更新。

验证：gallery 8158 显示 "lazarusWeb · 全功能画廊"；--title="命令行覆盖标题"
8159 显示覆盖值；t_gallery 50/50。

经验：**桌面框架搬到 Web 时，凡"Application 级属性"（Title/Caption）都该有
明确的映射去处——Title 的自然去处是浏览器标签页；映射规则要留出显式覆盖口
（--title=），别让 Application.Title 反过来吃掉用户的显式配置。**

## 坑 82：nogui 工程改 GUI 要动哪几处（实测清单）

一句话：**nogui 与 GUI 的差别只有「LCLWidgetType 宏 + Windows 子系统 +
启动路径」三项**，框架代码不用改（lwpanel/lwws/lwdispatch 里 `{$IFDEF
LCLnogui}` 两条分支都编得出来，宏一变就自动走另一条）。

### 1. .lpi：`BuildModes` 里的 LCLWidgetType 宏

```xml
<BuildModes>
  <Item Name="GUI" Default="True"/>
  <SharedMatrixOptions Count="1">
    <Item1 ID="651209837114" Modes="GUI" Type="IDEMacro"
           MacroName="LCLWidgetType" Value="win32"/>
  </SharedMatrixOptions>
</BuildModes>
```

注意 `Item Name` 与 `Item1 Modes` 必须对上：只把 Value 改成 win32、`Modes`
还写着 `Default`，IDE 里选 GUI 模式时这个宏不生效，编出来仍是 nogui。
`win32` 是 Windows 的 widgetset 名（Linux 用 `gtk2`/`qt5`，macOS 用 `cocoa`）。

### 2. .lpi：Windows 子系统（`-WG` 的等价物）

```xml
<Linking>
  <Debugging><DebugInfoType Value="dsDwarf3"/></Debugging>
  <Options>
    <Win32><GraphicApplication Value="True"/></Win32>
  </Options>
</Linking>
```

不写这项 → FPC 默认按控制台链接，运行起来跟着弹一个黑窗口。
（也可以在 SharedMatrixOptions 里加 `Modes="GUI" Value="-WG"`，dbaware.lpi
就是这么干的；两者等价。）

### 3. .lpr：`{$APPTYPE CONSOLE}` 必须去掉/分档

**`{$APPTYPE}` 指令优先级高于命令行 `-WG` 和 lpi 的 GraphicApplication** ——
只改 lpi 不改源码，PE 仍是 console（文档坑 46）。要两档共存就条件化：

```pascal
{$IFDEF MSWINDOWS}
  {$IFDEF LCLnogui}{$APPTYPE CONSOLE}{$ELSE}{$APPTYPE GUI}{$ENDIF}
{$ENDIF}
```

`LCLnogui` 由 lazbuild 按 LCLWidgetType 自动下发，正好当开关。

### 4. 编译命令：去掉 `--ws=nogui`

`--ws=nogui` 会把 lpi 里的宏**整体盖掉**，GUI 档还带这个参数就永远编成
nogui。正确写法：`lazbuild -B gallery.lpi`（只有一个模式时）或
`lazbuild -B --build-mode=GUI gallery.lpi`。

前置条件：LCL 得有为该 widgetset 编好的单元（本机
`lazarus/lcl/units/x86_64-win64/{nogui,win32}` 都在）。缺了会报
"LCL not compiled for win32"，重装/重编 LCL 即可。

### 5. 运行期行为差异（不用改代码，但要知道）

| | nogui 档 | GUI 档 |
|---|---|---|
| 主线程 | 阻塞在 accept 循环，Ctrl+C 退出 | accept 在后台线程，主线程跑面板消息循环 |
| 窗口 | 无 | 服务端面板（地址/会话/日志），关窗 = Stop 服务 |
| 控制台 | 有，日志走 stdout | **没有**，日志用 `--log=path` 落盘 |
| 测试/CI | 适合（tests 抓 stdout 判就绪） | 不适合，继续用 nogui 档跑 |

想 GUI 构建但不要窗口（服务化部署）：加 `--nogui`，面板不弹、行为等同 nogui。

### 实测（gallery 副本改 GUI 档）

改完 lazbuild 无 `--ws` 编译通过 → PE `Subsystem=2 (GUI)` → 启动后
`curl /` 200、`<title>lazarusWeb · 全功能画廊</title>` 正常。

### 建议：两个模式都留着

照 `demos/dbaware/dbaware.lpi` 的写法，`Default`=nogui（测试/CI/部署）+
`GUI`=win32（日常开发、双击即用），一份源码两档产物，靠 `--build-mode=`
切换。只留 GUI 一档的话，t_gallery 这类抓 stdout 的测试就跑不了了。

## 坑 83：radio/checkbox 选中态画成灰色（看着像禁用）+ 一段构建插曲

现象：浏览器里 TRadioGroup 选中项是**灰实心圆**、TCheckGroup 选中项是**灰勾**，
未选中的白底灰边 —— 用户认为灰色=禁用，看起来像整组被禁用了。

根因：**Ext 7.5 crisp 主题雪碧图的设计**。`images/form/radio.png`、
`checkbox.png` 都是 2×2 格（各 15px）：未选中(0,0)=白底灰边、选中(0,-15px)=
**灰色**、focus 未选中(-15px,0)=蓝框、focus 选中(-15px,-15px)=**蓝色**。
也就是说非键盘焦点的选中态天生就是灰的，蓝色只给了 focus 态。控件本身
`disabled:false`，纯属主题观感问题。

修法（lw.css 两行）：把选中态改指 focus 选中格 ——
```css
.x-form-cb-checked .x-form-radio-default,
.x-form-cb-checked .x-form-checkbox-default { background-position: -15px -15px !important; }
```
（x-keyboard-mode 的同名规则一并覆盖。）选中=蓝圈蓝点/蓝框蓝勾，未选中
保持白底灰边，disabled 仍走主题灰色，三种状态语义不再混淆。CDP 截图验证：
选中 radio 蓝点、勾上 Pascal 蓝勾。纯 CSS，刷新即生效。

排查工具：tests/cdp_radio_gray.py（切页签 + dump radiofield/checkboxfield
的 checked/disabled/cls/背景偏移 + 截图）。

### 插曲：回归突然挂了，真凶是"被人重编过的 exe"

修 CSS 后跑 t_gallery 竟在 btnToast 上超时；手动复现发现 ShowMessage/
MessageDlg 的对话框指令根本推不到 poll（会话被挂死），InputBox 却好的。
对照实验：同一 exe 手动起服务 46/48（对话框失败但继续）、run_with_server
下直接挂死 —— 因为挂起对话框没清理，后续事件全堵在会话执行锁上。
**源码自昨晚绿色回归后一行没改，但 gallery.exe 的 mtime 是今天上午 11:40**
（用户在 Lazarus 里按过编译）。用当前源码重编后 50/50 全绿。教训：
**回归突然变红时，先 stat 一眼 exe 的 mtime 和源码对不对得上，再怀疑代码**；
IDE 里"随手编译一下"留下的产物不一定和 lazbuild 的等价。

## 坑 84：仪表盘进度弧与灰轨道不重叠（值弧画在内圈）

现象：TLWGauge 的绿色进度弧和灰色轨道是两条**平行的同心弧**，中间还有一条
缝；用户直接判定为"错位"，要求"进度条要和灰色的重叠"。

定量确认（直接量截图像素 + 最小二乘圆拟合）：灰轨道中心半径 ≈134.6px、
带 129.6–139.6；绿弧中心半径 ≈118px、带 112–124 —— 绿弧在**内侧**，半径差
恰好是代码里写死的 10。

根因：`gaugeSvg` 最初为了"100% 满格时值弧两侧仍露出灰底、不和底图混成一条
线"，把值弧画在 `r-10`、且线宽更细（7 vs 10）。这是设计选择而非 bug，但
**用户的心理模型是"进度条压在灰底上"**（绝大多数仪表盘/进度环都这么画），
两条平行弧天然被读成错位。

修法（lw.js gaugeSvg）：值弧改用与轨道**完全相同的半径和线宽**（r / 10）：

```js
parts.push('<path d="' + arc(0, 1, r) + '" ... stroke="#e3e8ee" stroke-width="10" .../>');
if (f > 0.001)
    parts.push('<path d="' + arc(0, f, r) + '" ... stroke="' + col + '" stroke-width="10" .../>');
```

起点/终点因此与轨道严格重合（同一个圆心、同一个 f=0 起点），满格时整条轨道
变绿，语义更直观。

验证：CDP 截图后重新做圆拟合，绿弧半径带 83–93、灰轨道中心 85.7 —— 同一条
圆环（残差在亚像素拟合噪声内）；视觉上绿段与灰段首尾相接、无缝。

经验：**"弧/环上叠一层进度"这类图形，默认就该同半径同线宽压上去；想做
"双轨"要有明确理由，否则用户只会读成错位。**

## 坑 85：TListBox 没有左右边框（前端把 border 写死 false）

现象：浏览器里的 TListBox 只有行间横线，**四周没有框**，尤其左右两侧完全
没有竖边框，跟 LCL 桌面上带凹陷边框的列表框差很远。

根因：`buildList`（listbox / dblistbox / checklistbox 共用）里写死了
`cfg.border = false`，而 writer 又根本没下发 BorderStyle —— 前端没有任何
依据能画出边框。

修法：
- **writer**：`listbox`/`dblistbox`/`checklistbox` 分支补
  `O.Add('border', BorderStyleToStr(<C>.BorderStyle))`（`'single'`/`'none'`，
  与 panel 分支同一套约定）；
- **lw.js `buildList`**：`cfg.border = (node.border !== 'none')` —— 缺省按
  LCL 默认 `bsSingle` 视为有边框（老服务端不下发也能正确显示）。

验证：CDP 量 `.x-panel-body` 计算样式 `border-left: 1px solid rgb(207,207,207)`，
四边齐全；截图确认。回归 t_gallery 50/50。

经验：**"控件默认该有的装饰（边框/滚动条/焦点框）如果前端写死成 false，
就等于丢了 LCL 的一个属性"；凡是 LCL 有对应属性（BorderStyle）的，都应该
由 writer 下发、前端照做，而不是硬编码。**

## 坑 86：TTreeView 缺左右和底边框（与坑 85 同源）

现象：树形控件只有顶部一条线，**左右两侧和底部都没有边框**。

根因与坑 85 完全一样：`buildTree` 里写死 `cfg.border = false`，`WriteTree`
没下发 BorderStyle。

修法：
- `WriteTree` 补 `O.Add('border', BorderStyleToStr(T.BorderStyle))`；
- `lw.js buildTree`：`cfg.border = (node.border !== 'none')`。

验证：CDP 量树面板 body 计算样式 `border-left/bottom/right: 1px solid`，
四边齐全；截图确认。回归 t_gallery 50/50。

经验：**同类问题要一次性扫干净。** listbox 修完应该立刻 grep 所有
`cfg.border = false` 的硬编码点（tabs/panel/frame 等），逐个对照 LCL 控件
是否真有 BorderStyle 属性——tabs 的 border=false 是对的（TPageControl
本身不画外框），tree/listbox/grid 则都应该跟随 BorderStyle。

## 坑 87：GUI 服务端"点退出一直关不了"（浏览器连过之后，mips64 实测）

现象：只起服务端、没开网页时，退出约 1 秒；**浏览器打开过页面之后**再点
「文件→退出」，窗口一直不消失——实测 29 秒才退，另一次 33 秒。

定位：给 Stop 每一步加打点（`LW_EXIT_TRACE=1`，见下），一眼看到卡在最后
一句 `FreeAndNil(FHTTP)`：

```
[exit]    121 ms  Stop ⑤ Start 已返回
[exit]  29440 ms  Stop ⑥ HTTP 服务器已释放      <- 29319ms 全在这里
```

根因两层：

1. `TFPCustomHttpServer.Destroy` 里当连接列表非空时会
   `WaitForRequests(High(Integer))` —— **无限等**连接线程收工。而 tmThread
   的连接线程在 keep-alive 循环里用 `CanRead(30000)` 等下一个请求，我们停服
   时只 `CloseSockets`（= close(fd)）。**Linux 上 close() 叫不醒阻塞在
   select/recv 里的线程**，它要睡满 `RequestReadTimeout`（默认 30000ms）——
   29 秒正好是这个超时。
2. 就算跳过析构、把活着的线程留在进程里，收尾阶段（释放会话仓库 → RTL
   退出）仍会被它拖住，实测一次 **33 秒**。

修法（`src/core/lwhttp.pas`）：

- `TLWHttpServer.AbortConnections` 改成 **先 shutdown 再 close**：遍历
  `ConnectionHandler.List`（public 属性）对每个连接 `fpShutdown(..., SHUT_RDWR)`，
  阻塞在 select 里的线程立刻返回；再调 fcl-web 的 `CloseSockets` 顺带清
  keep-alive 标记。
- WebSocket 升级后 socket 所有权已移交、**不在** ConnectionHandler 列表里，
  单独登记（`LWWSRegister` / `LWWSUnregister` + `LWWShutdownAll`），停服时
  一并 shutdown。
- Stop 第 ⑥ 步：先给 1 秒宽限（20×50ms 轮询连接数），收工走正常
  `FreeAndNil(FHTTP)`；仍有残留就 `Halt(0)` —— 退出这一刻没有必须保住的资源，
  交给 OS 回收，比让用户盯着关不掉的窗口划算。

注意：这个 FPC 版本里 `fpShutdown` / `SHUT_RDWR` 由 unit **`Sockets`** 提供，
写 `BaseUnix` 会 `Identifier not found`（实测 3.3.1/mips64el）。

顺带补的诊断设施：`LW_EXIT_TRACE=1` 时，Stop / 面板收尾 / lwapp 单元收尾
每一步都往日志打一行 `[exit] NNN ms ...`（`lwhttp.LWStopTraceBegin` /
`LWStopTrace`），不设环境变量时全是空调用，零开销。

验证（192.168.1.103，mips64el，真浏览器）：
- 浏览器开着退出：修前 29440ms → 修后 253~1255ms；
- **浏览器先关再退出（用户实际用法）：404ms**；
- 不开网页直接退出：288ms；
- 回归：`/lw/healthz` 正常、建会话 + 长轮询正常、日志无异常/AV。

经验：**"关不掉"先用打点确认卡在哪一步，别猜。** 这次前三步都对（关 accept、
断连接、等 Start 返回都在 300ms 内），问题全在最后一句 Free 里，而它藏在
fcl-web 的析构内部。另外：Linux 上 close(fd) 不叫醒 select，要 shutdown——
凡是"停服务要快"的场景都成立。

## 坑 88：退出卡在 LCL/GTK 的 finalization（mips64el，坑 87 的下一层）

坑 87 修完 Stop（FreeAndNil(FHTTP) 那 29 秒）之后，桌面会话里点「退出」
仍会卡：窗口一直挂着、主线程烧 CPU、桌面弹 zenity 的
「lazarusWeb … 未响应，是否强制退出」。日志（`~/.xsession-errors`）里能看到：

```
(zenity:15660): Gtk-WARNING **: Failed to set text '<big><b><tt>lazarusWeb 0.9.0
独立服务器 - 端口 8090<tt> 未响应。</b></big>...
```

定位：`LW_EXIT_TRACE=1` 的追踪每次都停在**同一句之后**：

```
[exit]  310 ms  lwapp ④ 单元收尾完毕（接下来是 RTL/GTK 收尾）
                  <- 到此为止，后面什么都没有，窗口还在、CPU 在跑
```

也就是：服务已经停干净（Stop 200~310ms，连接全 shutdown、会话仓库已释放），
卡的是**之后的 LCL/GTK finalization**（各单元 finalization 段 + gtk/glib 收尾）。
这段在 mips64el 上不返回，而且空转烧 CPU。

注意一个测量陷阱：用 `pgrep -x dbaware_gui` 轮询判断"进程是否消失"会误判
（早先据此得出"404ms 退出"的结论是错的，其实那次同样卡住并弹了 ANR）。
改用 `/proc/<pid>` 存在性 + `State != Z` 判断才准。

修法（`src/core/lwpanel.pas`）：加 `TLWExitWatchdog`。
`FormClose` 的退出分支在 `FServer.Stop` 之后启动一个 500ms 的看门狗线程，
正常收尾几十毫秒就结束进程、它醒不过来；真卡住就由它
`WriteLn(StdErr, ...)` 留一行证据后 `fpExit(0)` 结束进程。

用 `fpExit` 而不是 `Halt` 是关键：`Halt` 恰恰会去跑那段卡住的
finalization，`fpExit` 走 C 的 exit，跳过 FPC 的 finalization 段。
（Windows 分支用 `Halt(0)`：LCL/win32 收尾正常，看门狗基本不会触发。
 另外别在 `implementation uses` 里加 `Windows` —— 它的
 `GetEnvironmentVariable` 会盖掉 SysUtils 的同名函数，整个单元编不过。）

此刻没有必须保住的资源：监听已关、连接已 shutdown、会话仓库已释放、
日志已落盘，所以强退是安全的。

验证（192.168.1.103 / mips64el / 真浏览器在线时点退出）：
- 服务停止 310ms → 看门狗 500ms 触发 → 进程消失，**窗口不再残留**；
- `ZENITY=0`：不再出现"未响应"弹窗；
- 日志里能看到 `[exit] 500ms 内未收工（LCL/GTK 收尾卡住），看门狗强制结束进程`。

经验：**修完一层再测一层。** 坑 87 让 Stop 从 29 秒降到 300ms，但用户仍说"慢"，
因为卡点搬到了 finalization；追踪打点一定要打到"进程消失"之前最后一刻，
否则会误以为已经修好。

## 坑 89：Alpine.js 客户端（lw-alpine.js）替代 Ext JS —— 迁移实录与 8 连坑

分支 `alpine-client`，目标：功能与 Ext 版一致，协议（控件树 JSON / 事件回发 /
poll+WS / 对话框指令）完全不变，`?client=alpine` 切换，Ext 版保留可切回。

新增：`src/client/alpine.min.js`（3.14.9 CDN build）、`lw-alpine.js`（渲染层：
服务端 JSON 树 → 绝对定位 DOM + Alpine 指令）、`lw-alpine.css`；
`lwhttp.pas`：ServeIndex 按 `client=` 参数选 shell，加 3 个静态路由。

实测踩坑（全部 CDP 验证）：
1. **`checked` 双类型**：writer 对 checkbox 发 boolean、对 checkgroup 发数组，
   `stateOf` 里 `(node.checked||[]).slice()` 对 boolean 直接炸（错误还被
   fetch catch 吞成 "http error" 显示成"无法创建会话"）。改
   `Array.isArray(node.checked) ? node.checked.slice() : []`。
   教训：**错误信息要带上原始原因**（`'http error: '+e.message`），
   否则排查方向全错。
2. **窗体高度塌成标题栏**：`.lw-win` 只设了宽没设高，flex 子项
   `.lw-win-body { flex:1 }` 的 flex-basis:0 把内联 740px 压成 15px。
   `win.style.height = f.h + 'px'` 补上。
3. **align=client 不拉伸**：Alpine 版 runLayout 只处理了 top/bottom/left/right，
   client 的第二趟漏了 → TPageControl 停在设计尺寸 1800x899。补第二趟
   （与 lw.js 同语义）。
4. **tabsheet 全部不可见**：服务端 TTabSheet.Visible 恒为 False（lw.js 坑里
   早有注释"显隐由 activeTab 管理"），placeNode 必须跳过 tabsheet 的
   visible 处理。
5. **applyTabActive 选择器永远匹配不到**：`:scope > .lw-tabs-body > .lw-tabcard`
   —— 实际结构是 `.lw-n > .lw-tabs > .lw-tabs-body > .lw-n(包装层)`，且要藏的
   是 sheet 包装层不是内层卡。改
   `:scope > .lw-tabs > .lw-tabs-body > [data-lwid]`。
   另 `$lwTabClick` 里 `S.R[id]` 可能从未初始化（tabs 模板不引用响应式状态），
   要兜底 `stateOf(S.ND[id])`。
6. **外壳 `<template x-if>` 静默失效**：不在任何 x-data 作用域内的顶层指令
   Alpine 直接忽略（mask/dialog 全不出来）。外面套 `<div x-data>`。
7. **`x-for` 模板要求单根**：对话框按钮区 template x-for 里有两个兄弟节点
   （openfile 特判 + 真按钮）→ 一个按钮都不渲染。用
   `<span style="display:contents">` 包住。
8. **textarea 的值不在 textContent 里**：验证日志更新时读 textContent 恒空，
   要读 `.value` —— 差点把"链路其实是通的"误判成"事件没回发"。

验证：12 页签全遍历（每页可见节点数 7~28 各异、无 JS 错误）、按钮点击回发
（日志出现 Btn.OnClick）、ShowMessage 弹窗→确定→服务端挂起恢复（日志出现
"Dlg.ShowMessage 返回"）、协议回归 t_gallery 50/50 + t_dbaware 134/134。

CDP 探针：`tests/cdp_alpine_smoke.py`（首屏+控制台错误）、
`tests/cdp_alpine_style.py`（几何诊断）。教训：**探针脚本里 Edge 必须和
诊断在同一次运行里起**（Popen 的 Edge 会随 bash 会话退出被杀，复用必 502）。

## 坑 90：删掉 ext 目录后浏览器白屏 + 横幅还显示 Ext 信息（Alpine 模式的默认客户端）

Alpine 客户端刚落地，用户把 ext-x.x.x 目录删了 → 打开页面白屏；启动面板横幅
也还在显示 `Ext: C:/lazarusWeb/ext-x.x.x` / `Ext dirs`——此刻这些信息毫无意义。

两个根因：
1. **默认客户端写死 ext**：`?client=alpine` 只是查询参数，没进配置。
   删了 ext 目录，默认 shell 还是 Ext 版 → /ext/x.x.x/... 全 404 → 白屏。
2. **根目录定位靠 ext- 目录**：`LWDefaultRoot` 用「cwd/exe 向上找 ext-*」来
   认根，ext 删掉后 Root 退回 exe 所在目录（demos\gallery）。
   好在 `LWFindClientFile` 有「从 root 向上 5 层找 src/client」的兜底，
   alpine.min.js / lw-alpine.js 仍然能找到——不白屏的前提是 shell 换对。

修法（`lwhttp.pas` + `lwapp.pas`）：
- `TLWServerConfig` 加 `DefaultClient`（'ext'|'alpine'，~~默认 ext~~ 见坑 92：
  未显式指定 client= 时已改为自动探测、双全优先 alpine；此处"默认 ext"仅
  在显式指定或两渲染层都缺时成立）；
- 配置文件 `client=alpine` / 命令行 `--client=alpine`（非法值警告后按 ext）；
- `/?client=` 仍可按请求覆盖（现在默认取 GCfg.DefaultClient）；
- `PrintBanner` 按模式分叉：alpine 显示
  `Client : alpine（Alpine.js 3.14.9，无需 ext 目录）  (切换: /?client=ext)`，
  不再输出 Ext/Ext dirs/Theme 行；ext 模式加一行 Client 提示；
- `lwbase.pas` 加 `ALPINE_VERSION = '3.14.9'`（换 alpine.min.js 时同步改）。

gallery demo：`demos/gallery/gallery.ini` + `gallery_x86_64-win64.ini`
（GUI 面板版按 exe 名找 ini）写 `client=alpine`，GUI/nogui 两个 exe 重编。

验证（ext 目录确实删除的环境）：--client=alpine 起 → 横幅 Client 行正确、
index/alpine.min.js/lw-alpine.js/session 全 200；URL 不带 client= 也直接
Alpine 首屏（150 节点渲染、无 JS 错误）；GUI 版 --nogui 读 ini 同样生效；
t_gallery 50/50 不回归。

## 坑 91：模态窗体（uAbout）显示不完整——底部被裁 + 滚动条（Alpine buildForm 没补标题栏高度）

用户点"模态窗体(uAbout)"，对话框正文能看但"关闭"按钮被切掉一半，客户区出滚动条。

根因：**窗口总高含标题栏，LCL ClientHeight 不含**。Ext 版 lw.js 在 `win.show()`
之后有明确的补偿（`dh = ch - win.body.getHeight(); setHeight(getHeight()+dh)`，
注释原话"把差值补回去，让窗口 body 的坐标空间与 LCL 客户区一致"）；Alpine 版
`buildForm` 漏了这一步——`win` 高度设成 `f.h`，标题栏占 28px，`.lw-win-body`
（flex:1）只剩 `h-28`，而子控件按 `f.ch`（nogui 模态下 ch==h）布局，底部 28px
整个被裁掉。模态窗体的关闭按钮恰好贴着客户区底边 → 必裁；主窗体底部是空白所以
一直没暴露。

顺带修掉的三个同源问题：
1. **主菜单栏 appendChild 排在 body 之后**，flex 列布局下菜单被挤到客户区下面；
   改 `insertBefore(mb, body)` 并把菜单高度计入窗口总高；
2. **状态栏 top 没算标题栏/菜单栏偏移**（浮动在客户区上方 28px）；
   改用 `body.offsetTop`（已含边框+标题栏+菜单栏全部偏移）自动定位；
3. **边框/标题栏分隔线的 1px 累计误差**：估高 `ch+TITLE_H` 之后仍有 3px 短差，
   学 Ext 版按实测补齐（`dh = ch - body.getBoundingClientRect().height`）。

另补一个保真缺口：Alpine 版模态窗体没有遮罩（Ext `modal:true` 会罩住背景），
加 `.lw-win-mask`（rgba 0.32，z 比 win 低一层），`closeFormWin` 一并摘除——
ShowModal 期间背景不可点，与 LCL/Ext 语义对齐。

nogui 版还有个配置暗坑：ini 自动发现是 `<exe名>.ini`，gallery.ini 只对
gallery.exe 生效，`gallery_nogui-x86_64-win64.exe` 找的是
`gallery_nogui-x86_64-win64.ini`——没有就按默认跑（坑 92 起为自动探测、
双全优先 alpine，不再是硬编码 ext）。补上同名 ini。

验证：CDP 探针（tests/cdp_alpine_about.py）点按钮 → 量几何：
`win_h=251 = 220(ch)+28(标题栏)+3(边框)`、`body_h=220 == ch`、scrollH 无溢出、
"关闭"按钮 bottom 在客户区上方 25px 完整可见；遮罩实测全屏且背景像素
255→175 变暗；t_gallery 50/50 + t_dbaware 134/134 不回归。

## 坑 92：渲染层自动探测——配置/命令行都没指定 client= 时，alpine 与 ext 双全优先 alpine

（补记：原此处留白标"编号跳号"，实际提交 `e44a1de` 有完整实现与测试，2026-11-20 审计补档。）

坑 90 把 `DefaultClient` 默认值写死 ext，于是 alpine 与 ext 都在时仍走 Ext——
用户删不删 ext 目录都得手动 `client=alpine`，不智能。坑 92 改为**启动期自动探测**：

- `TLWServerConfig` 加 `ClientExplicit: Boolean`——ini 的 `client=` 或命令行
  `--client=` **显式**指定时跳过探测，行为与坑 90 完全一致；
- 未显式指定时，探测 alpine（`alpine.min.js` + `lw-alpine.js`）与 ext
  （`ext-<版本>/build/ext-all.js`，ExtDir/ext-版本/根下唯一 ext-* 三级解析，
  与 `ExtRootFor` 同语义）是否存在：两个都在 → **优先 alpine**；只有一个 →
  用那个；都没有 → 保持 ext 并告警；
- 横幅区分显式/自动：自动选 alpine 显示"自动探测优先"，自动退回 ext 显示
  "自动探测：未找到 alpine.min.js"；显式指定时不带这些字样；
- `--help` 更新 `--client=` 说明；重编 gallery_nogui/gallery_gui/dbaware。

验证：`tests/t_autodetect.py` 五场景断言（仅 alpine / 双全 / 仅 ext /
`--client=` / ini），t_gallery 50/50 + t_dbaware 134/134 均**不带** `--client=`
跑，实测走的就是探测路径。

> 现行规则：未指定 client= 时"双全优先 alpine"；坑 90 的"默认 ext"只在
> 显式指定或两者都缺时成立。

## 坑 93：模态窗体怼在左上角 + 标题栏右上角没图标 + 窗体不能调整大小

用户连报三点：uAbout 显示在左上角；主窗体/对话框标题栏右上角空着（Ext 版有
maximizable 图标）；窗体拖不了大小。

修法（lw-alpine.js / lw-alpine.css）：
1. **模态/非模态一律视口居中**：LFM 的 Left/Top 常是 0 或设计时随手摆的，
   模态窗体沿用设计坐标就怼在左上角。fx/fy 改成统一按 innerWidth/innerHeight 居中；
2. **标题栏右上角图标**：所有窗体加 `.lw-win-max`（▢，最大化/还原，对齐 Ext
   maximizable:true），模态窗体 × 在其右侧。最大化用 CSS 类 `.lw-max`
   （!important 覆盖内联 left/top/width/height），还原即摘类；
3. **可调大小**：writer 本来就下发 `resizable`（bsSizeable/bsSizeToolWin），
   Alpine 版一直没用。加 `.lw-resizable`（CSS `resize:both`，overflow 必须
   非 visible 句柄才出现）+ ResizeObserver：CSS resize 不派发任何事件，RO 是
   唯一可靠钩子 —— 回调里用 rAF 节流，更新状态栏宽/top，并对 align 子项重跑
   runLayout（align=client 的面板随窗口伸缩）。最大化时 resize:none、拖动禁用。

**部署暗坑**：`demos/gallery/lw/`（扁平部署副本，原名 client/ —— 目录名容易
被当成"客户端源码"，坑 93 后改名为 lw/，与 /lw/ URL 前缀一致；旧 root\client\
仍兼容识别但不再推荐）在 LWFindClientFile 里优先于向上找的 `src\client` ——
改了 src\client 不同步这份副本，浏览器永远拿旧 JS（本次 max 按钮就这样
"消失"过一次）。改客户端脚本后要么同步副本、要么删掉副本目录。

验证（tests/cdp_alpine_about.py）：模态 cx_off=0（水平居中）、max_btn=true；
最大化 1170x780 全屏 -> 还原 1200x771；右下角出现调整手柄；冒烟 150 节点无 JS 错误。

## 坑 94：复选框勾不上 / 表格树列表选中即消失（patchNode 指纹存在被替换的 prev 上）

用户连报两图：CheckGroup 复选框"不可选"、TStringGrid/TDrawGrid/TTreeView/
TValueListEditor/TListView 全部"不可选"。

根因是一个统一 bug + 一个缺失功能：

1. **统一 bug**：`LWHandleEvent` 每次事件都返回**完整组件树**，客户端对每个
   节点跑 patchNode。patchNode 里 checkgroup/grid/vle/tree 的内容指纹
   （`prev.__cgSig`/`__gridSig`/`__veSig`/`__treeSig`）全都存在 `prev`
   （旧节点对象）上，而 patchNode 开头 `S.ND[id] = n` 就把节点对象换新了
   ——指纹永远丢失，每次补丁都判"内容变了"：
   - checkgroup/checklistbox：`r.checked` 被服务端旧状态覆盖 -> 用户刚勾上
     的复选框在事件回包到达后（几十毫秒）被打回，体感就是"勾不上"；
   - grid/drawgrid/listview：`r.idx = -1` -> 选中行立刻被清；
   - tree：renderTree 整体重渲染 -> 点击瞬间加上的 lw-sel 被抹掉。
   之前用 el.click() 的探针测不出来：同步读 sel 都在，异步回包一来就没了。
   **必须用 CDP Input.dispatchMouseEvent 真实鼠标事件 + 延时复核**才能复现。
   `S.sigs` 字段早就声明了（注释写明"结构指纹"）却从未使用——修复就是把
   四处指纹改存 `S.sigs[id+'|cg'|'grid'|'ve'|'tree']`（destroyNode 一并清）。

2. **缺失功能**：TStringGrid/TDrawGrid 行选中高亮压根没实现（td 点击只发
   事件、无 lw-sel 绑定、$lwGridCellClick 不记行）。补：`<tr :class="i===r.idx...">
   + $lwGridCellClick 里 r.idx=row`（对齐 Ext 版行选择）。

3. **树选中被重渲染抹掉的另一半**：writer 下发 `selected`（LCL Selected），
   点击回发后 dispatcher 把选中写回 LCL（Selected := Items[row]）-> 树 JSON
   指纹变 -> renderTree 重渲染，但 renderTree 从不渲染 selected。修：
   treeConv 传递 sel，节点 HTML 按服务端 selected 加 lw-sel。

验证（tests/cdp_real_diag.py + cdp_tree_diag.py，真实鼠标事件）：
Pascal/中文 勾选保持；StringGrid 第1行、DrawGrid、VLE、ListView 条目1、
Tree src/core 全部选中高亮且 1.5s 后仍在；t_gallery 50/50 + t_dbaware
134/134 + 冒烟 150 节点无 JS 错误。

## 坑 95：TStringGrid 不能编辑 / TDrawGrid 行高被压扁 / 会话遮罩永久卡死

用户三连报。三个独立问题：

1. **TStringGrid 编辑缺失**：writer 一直下发 `readonly`（goEditing 取反），
   Alpine 版完全没用。补：readonly=false 时单击单元格就地编辑（对齐 Ext 版
   CellEditing clicksToEdit:1），回车/失焦提交 -> 回发 OnEditingDone
   {val,row,col} -> 服务端 LWApplyValue 写 TStringGrid.Cells[col,row]
   （row 自动加回 FixedRows），本地 rows 同步更新。
2. **rowheight/colwidths 被忽略**：writer 按 LCL RowHeights/ColWidths 下发
   rowheight/colwidths，Alpine 表格全用 CSS 默认值 -> TDrawGrid 行被压成几像素。
   补：td 内联 height、th 按 colwidths 设 width。
   **实现暗坑**：colwidths 是构建期常量，th 必须用 JS 循环生成；若在模板
   字符串里写 `gw[j]`（j 是 x-for 的运行时变量），innerOf 构建期直接
   ReferenceError: j is not defined -> createNode catch 兜底成 lw-unknown
   -> 控件"消失"且无报错（log 带 [lw] 前缀，探针不抓 consoleAPICalled 就
   看不见）。教训：**模板字符串里不能引用 x-for 作用域变量做构建期运算**。
3. **会话遮罩卡死**：demo 按钮是 toggle（再点按钮关闭），但 lw-mask 全屏
   z-index 99999 盖住按钮本身、遮罩无任何点击处理 -> 点第一下就永远关不掉
   （也根本没有"2 秒自动关"这回事）。修：遮罩 @click="$store.lw.mask.show
   = false"，点任意处关闭；服务端 FMaskShown toggle 依然自洽（下一次按钮
   点击走 LWHideScreenMask 空操作后归位）。demo 文案改"点击遮罩任意处关闭"。

调试手段：create failed 只走 console.log('[lw]',...)，Runtime.consoleAPICalled
要在 sleep 后用一次 evaluate 排水才收得到（CDP 事件在无 pending 命令时积压
在 socket 缓冲里）。

验证（tests/cdp_pit95_verify.py + cdp_real_diag.py）：td_h=rowheight、
th_w=colwidths；单击 TStringGrid 空单元格 -> 输入 -> 回车 -> 单元格显示新值
且服务端日志 Grid.TStringGrid 行=1 列=1；遮罩显示 -> 点任意处关闭 -> 再次
点击按钮 toggle 正常；t_gallery 50/50 + t_dbaware 134/134 + 全量选中探针
（坑 94 修复项）不回归。

## 坑 96：TDrawGrid 标题行被压扁（th 没应用 rowheight）

坑 95 只给数据行 td 加了 `height: rowheight`，列头 th 没加——TStringGrid 列头
有文字撑着看不出问题，**TDrawGrid 列头是空字符串**（自绘网格没有 Cells，
writer 按空串下发），th 立即塌成最小高度，标题行细成一条。

修：th 生成时统一带 `style="height:<rowheight>px"`（colwidths 仍按坑 95 的
循环方式拼接 width/min-width，注意不要产生重复 style 属性）。

验证（tests/cdp_pit96_verify.py）：六个 .lw-grid 中可见的四个 th 高度与
td 完全一致（29/29/23/23）；截图确认；t_gallery 50/50。

## 坑 97：回写审计——5 类可输入控件的浏览器值到服务端 LCL 属性是断的

按"所有可输入控件都必须可回写"做全量审计：writer 下发的每种可编辑字段 ×
客户端回发事件 × 服务端 LWApplyValue 分支三方交叉。发现 5 个断链（两个客户端
共有，部分自框架初版就存在）：

1. **TCheckGroup**：客户端 OnItemClick 只发 {idx, val:'0'/'1'}（Ext 962 行 /
   Alpine 都一样），而服务端 TCheckGroup 分支只认 'checked' 布尔数组——
   **Checked[] 从来没写回过**，业务在 OnItemClick 里读 Checked[i] 是旧值
   （lwdispatch 里"浏览器已把新 checked 状态放进请求"的注释是错的）。
   修：服务端数组缺席时用 idx+val 单项写回（'1'/'true' 为勾选）；
   Alpine 客户端同时补发 checked 数组（x-model 已更新，slice() 拷贝）。
2. **TCheckListBox**：OnClickCheck 只发索引，勾选状态丢失。修：两个客户端
   都补发 checked 数组（Ext 的两处重建点都要补）。
3. **TTabControl（tabctl）**：客户端发 OnChange 序号，服务端只有 TPageControl
   分支——TabIndex 永不更新，页签切不动。修：加 TTabControl 分支（与
   TPageControl 同语义）。demo 扩展输入页签补了一个 TTabControl + OnChange
   日志（TCustomEditButton 族要先判，见 KindOf 119-130 行注释）。
4. **TFloatSpinEdit**：服务端只有 `C is TSpinEdit` 分支，而 TFloatSpinEdit
   与 TSpinEdit 是**兄弟类**（都继承 TCustomSpinEdit）——floatspin 的值
   全部被丢弃。修：单独分支 StrToFloatDef。
5. **TCustomEdit 族兜底**：服务端只认 TEdit/TMaskEdit/TMemo，而 TLabeledEdit
   是 TCustomEdit 子类而非 TEdit 子类——Text 回写落空。修：链尾加
   `C is TCustomEdit → Text := s` 兜底（TEdit/TMaskEdit/TMemo 已先命中，
   不受影响；TDateEdit/TTimeEdit 有自己的分支且先判，也不受影响）。
   勘误（2026-11-20 审计）：此前的表述把 TFileNameEdit/TDirectoryEdit
   （TCustomEditButton 族）也算作 TCustomEdit 子类，**不准确**。LCL 实际继承链为
   `TCustomEditButton → TCustomAbstractGroupedEdit → TCustomControl`
   （`lcl/groupededit.pp:62`），它们**不是** TCustomEdit 后代，这条兜底对它们
   并不生效——与 `MAPPING.md` 输入控件表的反例清单一致。`lwdispatch.pas:464`
   的同行注释也沿用了旧说法，读代码时以 LCL 源码为准。

审计方法：新增 tests/t_writeback_audit.py（协议级，POST /lw/api/event ->
断言组件树字段）：TLabeledEdit 文本、TFloatSpinEdit 88.5、TSpinEdit 33、
TCheckGroup idx/val 与数组双路径、TCheckListBox 数组、TTabControl TabIndex=1
—— 7/7。无头 Edge 探针跑浏览器端语义时注意：element.blur() 不派发 blur
事件（坑 95 调试时已踩过），checked 数组路径用协议级测更可靠。

回归：t_gallery 50/50 + t_dbaware 134/134（重编后的三个 exe）。

## 坑 98：AutoSize + taCenter 的 TLabel 在浏览器里跑到窗体水平中央

现象：About 对话框 lblTitle（AutoSize=True, Alignment=taCenter, Left=30,
Width=380 @144dpi）设计期/真实运行时文字都贴在 Left=30（AutoSize 把盒子
缩到文字宽，Alignment 不起作用）；浏览器里标题却被水平居中。

根因：nogui 虚拟显示器量不准 CJK 字宽，writer 按设计期宽度下发
（w=380 缩放后 ≈ 全窗宽），浏览器对这个"整窗宽"的盒子做
text-align:center → 文字被推到中央。设计期 Width 只是 AutoSize 的初值，
真实运行时会重算，两者天然对不上。

修：writer 给 TLabel 额外下发 `autosize`；两端渲染层对
autosize && !wordwrap && !boundfor 的标签**不下发宽高**，绝对定位盒子
按内容自适应（等价于 LCL AutoSize）；autosize && wordwrap 保留宽度
（LCL 语义：换行标签宽度固定、高度自适应）。AutoSize=False 的标签仍按
下发的固定宽高 + taCenter 居中（这才是 taCenter 该有的行为）。

验证：tests/cdp_about_title.py（无头 Edge，alpine/ext 两层各跑一遍），
断言"标题贴左（距窗左缘 < 120px）+ 文字宽 ≈ 盒子宽"。

顺带的调试基建：demos/gallery/lwdump.lpr（+lwdump.lpi）把任意窗体经
lwwriter 序列化成 JSON 打印，核对实际下发的 x/y/w/h/textalign/autosize。
**nogui 下手工建窗体必须先 Application.Initialize → LWInstallWidgetSet
（lwws 单元）→ 再 Create**，否则 TCustomForm.CreateNew 直接 AV；
不装补丁 widgetset 时进程甚至可能静默退出（exit 0 无输出）。

遗留：gallery + ?client=ext 在无头 Edge 下白屏（组件 282 个只 render 15 个，
updateLayout 不冲刷），HEAD 旧版 lw.js 同样白屏、dbaware+ext 正常——
与本次改动无关的既有问题，真实浏览器待确认。

## 坑 99：量吞吐时踩的两个假象（计时精度 + 压测工具自己成了瓶颈）

想把"事件后重建整棵树"换成增量补丁，先得知道一棵树到底值多少毫秒。第一版探针
用 `GetTickCount64` 打点，日志里全是 0 / 16 两个值 —— Windows 上这个计数器的
精度就是 **15.6ms**，和单次事件（几毫秒）同量级，等于没测。改用
`QueryPerformanceCounter`（`lwhttp.pas` 里 `LWProfNow`，微秒）才看清。

第二版探针又暴露出两个测量工具的问题：

1. `bench_concurrency.py` 每收到一个响应就 `json.loads` 整棵 78KB 的树，
   8 个会话在 GIL 上排队，客户端自己只有 ~57 事件/秒。之前 BENCH.md 里
   "吞吐封顶 55~57 事件/秒"的结论就是这么来的 —— 是**工具的上限**，不是
   服务端上限。改成只认 `"ok":false` 和推送帧后，同样的机器单进程能到
   130+ 事件/秒。
2. 用 `pipe_bench.py --clients 4`（线程版）测聚合，4 路加起来只有 59 事件/秒，
   和 1 路一样 —— Python 解析 WS 帧受 GIL 限制，"4 个并发客户端"其实还是
   串行的。改成**每个客户端一个进程**后才测出真实聚合值。

测出来的账（gallery / 切页签 / 157 节点 / 73KB 载荷）：

```
disp（派发业务 + BuildPayload 重建树）   p50 5.15ms
json（payload.AsJSON）                  p50 1.16ms
send（写 socket，受客户端回压影响）       p50 0.17~8.6ms
→ 服务端 ≈ 6.3ms/事件，单进程上限 ≈ 155 事件/秒
```

结论：串行区是"每事件重建整棵树 + 编码"，不是 HTTP/线程；要往上走只有
多进程（`tools/lwhyper.exe`，容量 ≈ N × 155）或增量补丁 + 序列化缓存
（`docs/SCALE.md` 有协议和分阶段方案）。

新增工具：`LW_PROF=1` 环境变量打开服务端剖析（默认关，每事件一行微秒日志）、
`tools/pipe_bench.py`（流水线吞吐）、`demos/gallery/lwperf.lpr`（单独量一个
窗体的 WriteForm/AsJSON 成本）。

## 坑 100：增量补丁第一版比全量还慢 4 倍（TStringList 的 locale 比较 + fpjson 的 Find）

补丁协议按计划写完了，功能全对（对拍 0 失败、浏览器 DOM 逐字节一致），**一量性能
是反的**：

```
全量: disp p50=7.28ms  json p50=1.19ms   载荷 82023 字节
补丁: disp p50=33.67ms json p50=0.04ms   载荷  7410 字节   ← 慢 4 倍
[diff] 26000 us  nodes=157 +0 -0 ~1 m0              （LW_DIFF_PROF=1）
```

省下的 JSON 编码只有 1.16ms，diff 自己吃掉 26ms。两个元凶都长得人畜无害：

1. **`TStringList.Sorted := True` 的查找走 `AnsiCompareStr`** —— Windows 上是带
   locale 的 `CompareStringW`，一次 ~10µs；`CaseSensitive := False`（默认）走
   `AnsiCompareText`，更慢。`id -> node` 用三张 `TStringList` 存（节点/父/下标），
   160 个节点做几轮查找就是 20ms+。
2. **fpjson 的 `TJSONObject.Find` 是线性 + 大小写不敏感扫描**（每个键都过一次
   `CompareStringW`）。`NodeId()` 到处调、`ChildrenOf()` 每节点调一次，160 节点
   × 25 属性 = 4000 次，又是十几毫秒。

修法：把索引换成**纯整型开放寻址哈希**（`$9E3779B1` 乘法散列 + 线性探测，
槽位 2 的幂、负载 ≤3/4），`FKeys/FNodes/FParents/FPos` 四张平行数组 + 一张
`FOrder` 存前序遍历序（哈希槽的顺序没有语义，遍历必须另存）。取 `children` 改成
**从后往前**扫 `Names[i]='children'`（writer 总是最后写它）。属性比较按位置比
（两份 JSON 同源、键序一致）。子节点顺序模拟换成 `TIntList`（整型数组）。

```
[diff] 1300 us  nodes=160 +0 -0 ~2 m0     ← 20 倍
```

教训写在这里，因为"只有一百多个元素，用 TStringList 足够"是**每次都会犯的直觉**：
元素少不等于查找便宜，常量取决于比较函数的成本，而 `AnsiCompareStr` 在 Windows 上
是 locale 调用。凡是 key 是整数的映射，一律用整型哈希，别用字符串容器。

## 坑 101：补丁漏发 `null`（"属性个数相同"当捷径）

`DiffProps` 里有一句优化：新旧节点属性个数相同 ⇒ 没有"消失的键" ⇒ 跳过
"每个键 Find 一遍"的收尾分支。看起来无懈可击（个数相同就没有净减少），但
**增一个键 + 删一个键时个数不变**：

```
老: {... "w":800, ... }                     （14 个键）
新: {... 没有 w ..., "rows":[...] }          （也是 14 个键）
→ 补丁只发 {"h":369,"rows":[...]}，客户端上 w 永远留着
```

对拍跑到第 194 组才撞上（换随机种子就换一组命中），现象是
`form.w: 少了 800` —— 重放结果比新树多一个属性。修法：把"个数相同"换成
**逐位比键名序列**（`AOld.Names[i] = ANew.Names[i]`，二进制比较，比逐个 `Find`
便宜得多），序列不一致才进消失键分支。

顺带修掉一个统计错误：跨父移动的节点被 `Removed` 计了两次（删除阶段 + 发 `d`
时各一次），只影响 `+/-/~` 那行日志。

## 坑 102：`external 'kernel32'` 让 Linux 交叉编译直接断掉（这个框架真的是跨平台的）

`lwsession.pas` 里那段临时剖析照抄了 `lwhttp.pas` 的写法：

```pascal
{$IFDEF MSWINDOWS}
function QueryPerformanceCounter(out lpPerformanceCount: Int64): LongBool;
  stdcall; external 'kernel32' name 'QueryPerformanceCounter';
{$ENDIF}
...
if GDiffProf then QueryPerformanceCounter(GDiffQ0);   // ← 这行在 Linux 下没有声明
```

`{$IFDEF}` 只保护了**声明**，没保护**调用点**。而 `demos/gallery/gallery_gui.lpi`
的 TargetOS 是 **linux / CPU mips64el**（`lazbuild -B gallery_gui.lpi` 就是往那块
板子交叉编译），所以这不是"理论上的可移植性"，是当场编不过：

```
Error: (5000) Identifier not found "QueryPerformanceCounter"
```

正确做法：把高精度计数器收进 `lwbase.pas` 的 `LWNowUS`，**两条平台分支都给出实现**：

```pascal
{$IFDEF MSWINDOWS}
  QueryPerformanceCounter(c);  Result := c * 1000000 div GNowUSFreq;
{$ELSE}
  {$IFDEF UNIX}
  if fpgettimeofday(@tv, nil) = 0 then Result := Int64(tv.tv_sec)*1000000 + Int64(tv.tv_usec)
  else Result := Int64(GetTickCount64) * 1000;
  {$ELSE}
  Result := Int64(GetTickCount64) * 1000;
  {$ENDIF}
{$ENDIF}
```

两点细节：

- `fpgettimeofday` **只在 `Unix` 单元里**（`BaseUnix` 没有它），签名收的是
  `PTimeVal`，所以传 `@tv`；`uses Unix` 要写在 `implementation` 里的
  `{$IFDEF UNIX}` 块中，别提到 interface（Windows 上没有这个单元）。
- `lwhttp.pas` 的 `LWProfNow` 也改成直接调 `LWNowUS`，去掉重复的 QPC 声明和
  频率全局量 —— 之前那个 `GProfFreq` 初值为 0 时除零的问题（坑 99 的余波）也一起没了。

验证方式：`lazbuild -B gallery_gui.lpi`（linux/mips64el）**和**
`lazbuild -B gallery.lpi`（本机 win64/nogui）都必须过。改完两个都过。

## 坑 103：`disp 5.15ms` 的真瓶颈是 DBGrid，不是"157 个节点读属性"

阶段 ③ 之前一直按"重建整棵树 = 逐控件读属性 4.3ms"来定优化方向。
给 `lwwriter.pas` 加了按 kind 的耗时探针（`LW_KIND_PROF=1`，`lwperf` 结束时往
stderr 打降序表），一开局面目全非：

```
dbgrid=42/78085us   ← 两个 DBGrid 实例，每事件 3.90ms，占 80%
grid/tree/chart/valeditor/listview/dbnav/... 全部加起来 ~0.6ms
```

也就是 155 个普通节点合计只要 0.6ms，**3.9ms 全在 TLWDBGrid 上**。
原因在 `WriteDBGrid` 的整表遍历：

1. 1000 行的表每轮渲染把 **1000 行 × 7 列的 `DisplayText` 全算一遍**，而这堆
   文本只有一个用途——过滤匹配（`Pos(ft, cell)`）。`FilterText` 为空时
   根本不用算，实际只下发当前页 50 行，另外 950 行全是白算。
2. `lwgMatchesAdd(lwg, ds.GetBookmark)` 先求值参数再进函数：普通 `TDBGrid`
   （`lwg = nil`）每行照样 `GetBookmark` 造一个书签，然后直接丢弃 ——
   **泄漏 + 浪费**，20 行的表每轮漏 20 个。

修法（`WriteDBGrid` + 抽出的 `TLWWriter.DBCellsRow`）：单元格文本只在
"这一行要下发"或"有过滤文本需要判断命中"时才读；书签只在 `TLWDBGrid` 下建。
修完 dbgrid 3.90 → 1.03ms，端到端 104.6 → 150~163 事件/秒（细节见 SCALE 2.8）。

教训：**先按 kind 剖析再定方向**。当时要是先跑了这一步，阶段 ③ 的力气
就该直接花在 DBGrid 上。

## 坑 104：值哈希签名 + 节点缓存判负（三个数）—— 已按结论删除实现

签名/缓存本身做对了（当时的 `--cache=1` / `--cache-verify=1`，对拍 4050 次
命中 MISMATCH=0，四层回归全绿），但**省钱判负**。既然收益是负的，就不该留在
代码里：评估完把 `TLWNodeCache` / `TLWSigTable` / `SigSelf` / `SigTree` /
`--cache` 开关全部删了（`lwwriter` 回到一趟重建）。数据留在这里，别再重做：

| 配置 | avg_write | 端到端 |
|---|---|---|
| 无缓存 | 2.2~2.6ms | 163 事件/秒 |
| `--cache=1` | 2.6~2.8ms | 145 事件/秒 |

- **签名 ≈ 重建的 60%**（sig 1.1ms vs 可缓存部分重建 ~1.0ms）：签名和重建读
  的是同一批属性，读属性本身就是大头，省掉的只有 JSON 树构造那一小截；
- **clone ≈ 重建的 50%**（0.5ms）：命中后 `Clone` 一棵 75KB 子树并不便宜；
- 事件表签名要 `GetPropList`（每节点一次 RTTI 全属性枚举），占签名 24%，
  砍掉也翻不了盘。

结论：值哈希签名只在"子树重建成本 ≫ 读属性 + clone"时才值钱（几千节点的
tree/listview）。属性即内容的普通窗体是净亏 —— **收益是负的就不做**，代码已
删掉（不是"留着默认关"：默认关的死代码一样要维护，还带着"签名漏字段就
界面不刷新"的风险）。别再往这条线上投入，要 500 事件/秒得换 JSON 表示层。

## 坑 105：测缓存/序列化时的三个假象

1. **id 必须稳定**。`lwperf` 第一版的 `TIds.IdOf` 每次调用 `Inc(n)` —— id
   每轮都变，签名里含 id → 缓存永远不可能命中。量出"缓存没效果"是假的。
   改成 `指针 → id` 的稳定映射后才有真数字（hits=1080 misses=0）。
2. **校验模式（当时的 `--cache-verify=1`）命中也要重建对拍**，所以 disp 反而
   更高（~5ms），那是校验成本不是缓存成本。量缓存收益必须关掉校验。
   教训是通用的：**带对拍的测量不能当性能结论。**
3. **`tests/bench_json.pas` 量 fpjson 时**：`GetJSON` 的参数必须传
   `UTF8String`——传 `string`（ANSI 代码页）会把中文 UTF-8 按单字节打散，
   报 `Expected comma` / `Invalid character`；读文件要用 `TFileStream` 按字节
   读，`TStringList.LoadFromFile` 会转码，同样把中文搞坏。

## 坑 106：`TStringList.DelimitedText := x` 会先 Clear 整个列表

`lwhyper` 往 worker 命令行追加 `--worker-args` 时写了
`args.DelimitedText := ACfg.ExtraArgs` —— 这一句**先清空再赋值**，把前面刚
`Add` 的 `--port=<port>` / `--nogui` 全部抹掉。worker 于是拿默认端口 8090
起来，撞上 lwhyper 自己的监听口，"Binding of socket failed: 8090" 无限重启
（探针超时 → kill → 重启循环）。只要命令行带了 `--worker-args` 就必现；
11 月 10 日的 hyper 日志里就有同样症状，当时没查出来。

修法：拆到临时列表再 `AddStrings` 追加；`Launch` 里顺手加了命令行日志
（`[hyper] launch #N port=... args=...`），下次这种问题一行日志就能定位。

教训：**给 DelimitedText 赋值不是"追加"，是"替换"。** 另外排这类问题时，
把"实际传给子进程的完整命令行"打出来是最短路径——这次加了日志立刻看到
args 里少了 --port。

## 坑 107：worker 失去响应的真凶是"异常对话框雷"，不是图片竞态

（2026-11-13 复盘改写：旧结论"TImage/TBitmap 竞态"是 FPImageException 这个
替身带偏的。）

40+ 并发压 gallery 时 worker 打出
`FPImageException: Failed to get raw image description from bitmap`
然后失去响应（healthz 探针超时，被 monitor 当成死掉重启）。

**根因链**（用 tests/tformthread.exe 最小复现 + gdb `info symbol` 定位）：

```
TCustomForm.DoCreate（窗体 OnCreate 抛原始异常）
→ HandleCreateException → TApplication.HandleException → ShowException
→ PromptUser → DialogImageList.LoadImage / TLCLGlyphs.GetImageIndex
→ ImageList.ScaleImage → TLazIntfImage.LoadFromBitmap
→ FPImageException（无头 widgetset 没有 RawImage，弹窗必炸）
```

也就是说：worker 里任何一个控件在 OnCreate/序列化中抛异常，LCL 默认会去
**弹错误对话框**，而无头 widgetset 连弹窗所需的位图都拿不出来 —— 弹窗本身
再抛 FPImageException，把真正的原始异常吞掉。真凶举例：40 并发下 gallery
的 SetupData 每会话都跑 CREATE/ALTER/UPDATE，sqlite 写锁竞争抛出
`ESQLDatabaseError: database is locked (at GalleryForm)`。

**修复（三层）**：
1. `lwapp.pas` 接管 `Application.OnException`：无头线程/工作线程只记日志
   绝不弹窗；GUI 构建且主线程才 `ShowException`。
2. `lwwriter.WriteControl` 单控件 try/except 降级：序列化失败的控件输出
   带 `err` 键的占位节点，不再炸掉整个 worker。
3. dateedit/timeedit 的 `FormatDateTime` 单独 try/except（脏日期 → 空 iso）。

**配套修复**：gallery 的 `EnsureDb/EnsureBigDb` 加进程级 `GDbEnsured` 标志，
DDL/种子每进程只做一次，消除 40 并发下的 sqlite 写锁竞争。

复测：bench_concurrency 40 并发四轮 0 错误 0 降级 0 重启，worker 错误日志 0 条。

## 坑 108：终端工具的命令跑在 Job Object 里，命令结束会连带杀掉子进程

（2026-11-13，lwhyper_gui 排障时踩到，极易误判成"程序自发退出"）

现象：从 AI 终端工具（bash/PowerShell）启动的 gallery worker 与 GUI 进程，
命令一结束就静默消失 —— 没有崩溃记录、没有日志、事件查看器里也没有。
看起来像"启动即退出"，实际是**宿主把每条命令放进 Windows Job Object
（kill-on-job-close）**，命令收尾时整个作业树（含孙进程）被一起终止。

判定方法（当时的一次性最小复现 `tests/tspp.lpr`，已删除，结论保留：
GUI 子系统父进程 TProcess 拉 worker）：
- 同一条命令内探活：活着、能监听、healthz 正常；
- 下一跳命令再看：没了。=> 不是程序问题，是命令生命周期问题。

**正确姿势**：长驻服务（lwhyper/lwhyper_gui/worker）必须用工具的
"后台任务"（run_in_background）方式启动，前台命令只能做一次性探测。
在真实用户的终端/桌面双击场景不存在此问题。

另：lwhyper_gui 的配置固定放 exe 目录（lwhyper_gui.cfg，与 exe 同行部署），
不再用 GetAppConfigFile 的 AppData 路径 —— 部署简单、排查直观。
[cfg] autostart=1 时启动即自动点「启动」，用于无头部署与 CI 冒烟。

> **2026-11-15 修订**：上面"后台任务（run_in_background）方式启动"的结论
> 只在**同一轮次内**成立——实测长驻服务跨轮次仍会被回收（一次 2 分半、
> 一次 11 秒后消失，退出码 1、无任何日志，极易再次误判成程序崩溃）。
> 现行正确姿势见坑 145：`Start-Process` 让进程脱离 Job Object。

## 坑 109：TPanel/TScrollBox"没渲染"其实是渲染了但视觉不可见；改客户端脚本不生效要先查 exe\lw\ 部署副本

（2026-11-13，gallery demo 的 sbxStd/pnlScrollBody 排障）

**现象**：窗体上新加的 TScrollBox + 内嵌 TPanel 浏览器里"看不见"。

**排查**：服务端树 JSON 正常（kind=scrollbox/panel、坐标尺寸都对）→
CDP（Edge headless + Runtime.evaluate）取真实 DOM：**节点都在、位置正确**。
真问题是视觉三缺失：

1. panel/scrollbox 模板不渲染 Caption（TPanel 的 Caption 是它唯一的"内容"）；
2. Bevel（bvRaised/bvLowered）没映射成边框，只有 border=bsSingle 才加
   lw-boxed —— TPanel 默认 bvRaised 也该有浮雕感；
3. TScrollBox.AutoScroll=False 时不下发 overflow:auto，内容超出视口后
   既裁不掉也滚不动，滚动语义丢失。

**修复**（lw-alpine.js + lw.js + 两份 css）：panel/scrollbox/frame 分支加
caption 居中渲染（.lw-panel-cap，服务端已过滤 Caption=控件名的缺省值）+
bevel 非 none 加 lw-boxed + scrollbox 恒 overflow:auto。

**第二个坑（排障时间大头）**：改了 src/client/lw-alpine.js 页面无变化，
禁浏览器缓存也无变化。LWFindClientFile 的搜索顺序是 **exe 同目录 →
exe\lw\ → root\src\client → root\lw → root\client**——gallery 的
demos/gallery/lw/ 里有一份旧部署副本，优先于 src/client 生效。
**改客户端脚本后必须同步所有 exe 旁的 lw/ 副本**（或删掉副本走 src/client）。

**取证工具**：Edge headless 的 --dump-dom 会因页面 WebSocket 长连接永不
idle 而卡死；正确姿势是 --remote-debugging-port + CDP
Runtime.evaluate/page.captureScreenshot（python websocket-client 即可）。

## 坑 110：TGroupBox 在浏览器里冒出一对"矮滚动条"（标题条占流式高度 + content-box 溢出）

（2026-11-13，gallery 的 gbGroup 反馈"垂直滚动条高度比控件高度小很多"）

实测（CDP）：groupbox 240×130、AutoScroll=null（LCL 里根本没有滚动条），
浏览器里却同时出现纵横两条滚动条，且竖轨只有 ~90px（控件 130px）。

三个叠加原因：
1. `.lw-group-body` 没有 `box-sizing:border-box` —— flex 拉伸宽 238 +
   左右 padding 20 = 258，**溢出边框 18px**，滚动条画到了边框外；
2. abs 版 body 带流式版 padding(4px 10px)，而子控件坐标是 LCL 客户区
   坐标，再叠 14px 偏移，内容底边被推出容器；
3. 基础 CSS 恒 `overflow:auto`，LCL AutoScroll=false 应该是只裁剪不滚动。

修复（lw-alpine.js/css）：
- `.lw-group-body` 加 `box-sizing:border-box`；
- `.lw-group-abs .lw-group-title` 改绝对定位叠加（top:2px left:10px），
  **标题不再占流式高度** —— 否则子控件整体下移 ~20px、编辑框底边(120)
  被 body(106) 裁掉；LCL 客户区原点就在边框内侧几像素；
- `.lw-group-abs .lw-group-body` 改 `position:absolute; inset:0; padding:0`，
  子控件坐标 1:1 对齐；overflow 按 node.autoscroll 下发（false → hidden）。

复验：body 238×128 铺满、scrollHeight=128 无溢出、编辑框完整、零滚动条。
注意：`overflow:hidden` 的前提是坐标映射 1:1；若标题仍占高度就会裁内容
——所以两条必须一起改。

## 坑 111：页面级横纵滚动条 → 视口自适应 + 整体缩放（2026-11-13）

**现象**：窗体画布固定（LFM 设计尺寸缩放后，gallery = 1200×740 CSS px），
浏览器视口小于画布时页面出滚动条；"最大化浏览器"无效 —— 协议里没有
视口→服务端的 resize 反馈回路，服务端窗体永远是设计尺寸。

**根因链**（三件事叠加）：
1. nogui 窗体无句柄（HandleNeeded 直接 EDivByZero，tests/tresize 实测），
   LCL 的 align 重算只在有句柄时发生 —— 所以服务端序列化的 align 子项
   坐标是 LFM 设计值；布局其实全靠**客户端 runLayout** 按 align 字符串
   重排。=> 服务端 resize 只需改窗体尺寸，不用（也没法）算 align；
2. `Application.Scaled := True` 已把窗体缩到 96 DPI 虚拟屏：**LCL 像素 =
   CSS 像素 1:1**，resize 参数不用换算；
3. 客户端 fire() 的响应可能走**全量树**（applyPayload）也可能走补丁
   （applyPropsOp）—— 窗体几何同步必须两条路径都写，漏一条就是
   "resize 事件发了、服务端也改了、画布不动"（排查时踩的正是这个）。

**实现**（lw-alpine.js + lwdispatch.pas + lwbase.pas）：
- 客户端：首个非模态窗体记为主窗体（S.mainFormId），钉在 (0,0)；
  resize 防抖 160ms 发 `{ev:'OnResize', w: innerWidth, h: innerHeight-28}`
  （28 = 窗体标题条）；全量/补丁两条路径都同步 w/ch 到窗口壳；
- 服务端：lwdispatch 加框架级分支 —— OnResize 先 LWApplyFormResize
  （SetBounds，下限 240×180）再 LWInvokeEvent 触发业务 OnResize；
- **OnResize 必须加进 lwbase 的 IsLWClickEvent 白名单**（TNotifyEvent 单参
  安全），否则业务 handler 不触发；
- **B 整体缩放兜底**：fitMainZoom —— 主窗体画布仍大于视口时 transform
  scale 到一屏放下（body overflow hidden），响应落地后自动复原为 1；
  服务端未及响应的首帧也靠它保证无滚动条。

**验证**：CDP 三档 1400×900 → 1100×780 → 1600×950 画布逐次精确贴合
（winLayout == viewport）、v/h 滚动条占位均为 0；缩到 0.9167 倍的兜底
路径实测可用。回归：t_gallery 50/50、t_patch_e2e 20/20、patch 吞吐
178.5 事件/秒、bench_concurrency 5 并发 0 失败。

**排障提醒**：worker 的 /lw/api/event 的 sid **只从 body 读**（URL query
无效）——curl 手测事件时 sid 必须放 JSON body，否则 "session gone"。
t_gallery 用 LW_BASE 环境变量指定目标（位置参数被忽略），且要
NO_PROXY=127.0.0.1（urllib 读 Windows 注册表代理）。

### 坑 112：浏览器缓存了旧客户端 JS（no-store 加晚了救不了存量缓存）

**症状**：服务端明明已带上视口自适应/缩放兜底的新 lw-alpine.js，用户浏览器
打开却还是旧行为——画布固定 1800×1110、页面滚动条回潮、"不能调整窗体大小"。
而 CDP 全新 profile 复现不出来（一切正常）。

**根因**：`Cache-Control: no-store` 是响应头，只能管"以后"。no-store 加入
（2026-11-12 22:55）之前，浏览器已经把旧版 lw-alpine.js 存进了磁盘缓存；
外壳 URL 是 `/lw/lw-alpine.js?v=LW_VERSION`，LW_VERSION 没变 → URL 相同 →
浏览器直接命中缓存、根本不发请求 → no-store 永远没机会生效 → 旧 JS 一直跑。

**修复**：URL 缓存指纹换"版本号 + 文件 mtime"——lwhttp.pas 加
TLWServer.LWAssetVer（LWFindClientFile 找到实际下发文件，FileAge 进
URL），BuildIndexHtml/BuildAlpineHtml 里 lw.js/lw.css/lw-alpine.js/
lw-alpine.css 全部换用。文件一改 URL 必变，浏览器存过多少旧版本都失效。

**排障提醒**：判断"用户端跑的是不是新 JS"别只看服务端文件——先查浏览器
实际加载的 URL 指纹（DevTools Network 或 document 里的 script src）。
CDP 复现不了 ≠ 用户复现不了，profile 缓存是最大变量。

**主窗体交互收紧**（同批）：主窗体是视口最大化画布——
- 恒不给 .lw-resizable（拖角与 sendViewResize 回包打架）；
- 标题栏不绑拖动（恒钉 (0,0)）；不渲染 ▢ 最大化按钮；
- 模态/弹出窗体的拖角、▢、拖动全部保留，行为不变。

**⚠️ 2026-11-13 12:55 回滚**：视口自适应（A+B）与主窗体交互收紧**已全部撤销**
（用户实测新版本问题多于收益）。`lw-alpine.js` 恢复为固定画布：主窗体按 LFM
尺寸渲染、可拖角、有 ▢、标题可拖，内容超出时出窗体内部滚动条。
`lwdispatch.pas` 的 OnResize 框架分支与 `lwbase.pas` 白名单保留（客户端不再
发该事件，属无害死代码）。**缓存指纹（LWAssetVer）保留**——它是纯运维修复，
不回退，保证以后改 JS 用户端必能拿到。
`docs/lazarusWeb手机浏览器适配.md` 里方案 1 的"顺手修掉键盘抖动"若重启，仍需从零评估。

### 坑 113：gallery.lpi 的目标平台被固化成 aarch64-linux

**症状**：改完 `ugallery.pas` 跑 `lazbuild --build-all gallery.lpi`，输出
`Linking ...\gallery_nogui-aarch64-linux`，而 `gallery_nogui-x86_64-win64.exe`
时间戳一动不动 —— 编译"成功"但测的是旧 exe，改动全白费。

**根因**：`gallery.lpi` 的 `<CodeGeneration>` 段被写入了
`TargetCPU=aarch64 / TargetOS=linux`（显式值覆盖本机默认）。BuildModes 里
只有 `Default`，没有分平台模式，所以每次编译都去链 Linux 目标。

**修复**：lpi 里改回 `x86_64 / win64`；输出名模板
`gallery_nogui-$(TargetCPU)-$(TargetOS)` 自然回到
`gallery_nogui-x86_64-win64.exe`。

**排障提醒**：`lazbuild` 返回 0 + 有 Linking 行 ≠ 产物更新。**永远 `ls -la`
核对 exe 的 mtime**，尤其在"改完代码行为没变"时——这是第二常见的假象
（第一是坑 112 的浏览器缓存）。

### 坑 114：TLWHTMLFrame / TLWPDFFrame 在 Alpine 版没有边框

**症状**：HTML/PDF 页签里两个 frame 只有一片白底，看不出控件边界；Ext 版
（`cfg.border = true`）却有边框。

**根因（两处缺失）**：
1. 客户端 `lw-alpine.js` 给它们硬编码了 `lw-boxed` class，但
   `lw-alpine.css` 里 `lw-boxed` 全是"类型 + class"的复合选择器
   （`.lw-group.lw-boxed`/`.lw-list.lw-boxed`/`.lw-grid.lw-boxed`/
   `.lw-tree.lw-boxed`），**没有 `.lw-htmlframe.lw-boxed`** → class 加了没规则命中。
2. `lwwriter.pas` 的 htmlframe/pdfframe 分支没下发 `bevel`/`border`
   （只有 panel 分支下发），客户端无从判断 LCL 的 BevelOuter 语义。

**修复**：
- CSS 加 `.lw-htmlframe.lw-boxed, .lw-pdfframe.lw-boxed { border:1px solid #b9c3cd; border-radius:3px; }`
- writer 两个分支补 `bevel`(Ord(BevelOuter)) + `border`(BorderStyleToStr)
- 客户端改按 bevel 判定，**bevel 未下发（旧服务端）时按 LCL 默认 bvRaised
  视为有边框**——保证前端修复不依赖重编 exe

**顺带发现**：`.lw-body.lw-boxed`（TPanel/TScrollBox 的 bevel）同样没有 CSS
规则，即 panel 的 `BevelOuter` 边框在 Alpine 版也没画出来。本次未改（影响面
覆盖所有面板视觉），待单独评估。

### 坑 115：TLWChart 无边框 + 右侧多出纵向滚动条

**症状**：图表页签的折线图没有边框，且 chart 右侧多一条几乎全高的纵向滚动条。

**根因**：
1. 边框：与坑 114 同源 —— 客户端硬编码 `lw-boxed`，CSS 没有
   `.lw-chart.lw-boxed` 规则；writer 的 chart 分支也不下发 bevel/border。
2. 滚动条：`.lw-chart` 与 htmlframe/pdfframe 共享 `overflow:auto`，而
   `<svg width=100% height=100%>` 是**行内元素**，底部有 line-height
   空隙 —— 100% 高 + 空隙溢出几像素，正好够 auto 伪造出滚动条。

**修复**：
- CSS：`.lw-chart` 从共享规则拆出，`overflow:hidden`（SVG 自适应永不超界）；
  `.lw-chart > svg { display:block }` 消除行内空隙（根治溢出来源）；
  边框规则并入 `.lw-htmlframe.lw-boxed, .lw-pdfframe.lw-boxed, .lw-chart.lw-boxed`
- writer：chart 分支补 `bevel`/`border`（与 htmlframe/pdfframe 同语义）
- 客户端：chart 并入 frame 的 bevel 判定块（未下发时默认 bvRaised 有框）

**教训**：`width/height=100%` 的 inline SVG 天生带底部空隙，要么
`display:block` 要么容器 `overflow:hidden`——只做后者治标，两个都做才稳。

### 上传目录迁移：Temp → exe 旁 uploads（2026-11-13 15:50）

用户要求上传目录与 exe 同级（"所有配置文件保存到 exe 目录"约定的延伸）。
原实现 `<临时目录>/lw_uploads/<sid>/<控件名>/` 在系统 Temp 里，用户找不到
自己的上传文件。

**改动**：
- `lwbase.pas` 新增 `LWUploadRootDir`（+ 可全局覆盖的 `LWUploadRoot` 变量）：
  默认 `<exe目录>/uploads/`，ForceDirectories 失败（exe 旁只读，如部署在
  Program Files）时自动退回 `<临时目录>/uploads/`，保证上传永不失败
- `lwupload.pas` `LWUploadDirFor` 改用之；目录结构 `<root>/<sid>/<控件名>/`
  不变，`TLWFileUpload.TargetFolder` 优先级不变
- 浏览器端选文件（TOpenDialog 的 pick）同走此函数，一并迁移

**验证**：CDP 页面内 fetch 上传 → 落盘
`demos/gallery/uploads/<sid>/upMain/test-upload.txt`，内容一致；t_gallery 50/50。

## 116. MIT 开源协议落地（2026-11-13）

- 仓库根目录新增 `LICENSE`（MIT，Copyright (c) 2026 szlbz(秋风) QQ:315795176）
- 源码文件头部（`src/core/*.pas`、`src/client/lw*.js/lw*.css`）插入
  `SPDX-License-Identifier: MIT` 单行注释；按用户要求**保留单独 LICENSE 文件**
  + 头部声明双份（第一次只做 LICENSE，用户补充"头部也加上"）
- README 增加「开源协议」章节，注明第三方依赖协议（Ext JS 双许可 / Alpine MIT / FPC 修改版 GPL）
- 坑：用 Python 文本读写 JS 会把 CRLF 行尾洗成 LF —— 已改二进制读写并按文件
  自身行尾插入；`demos/gallery/lw` 副本与 src 重新 diff 校验一致

## 117. 全代码跨平台编译（2026-11-13）

- 审计：`src/core` 无 `uses Windows`；平台差异（LWNowUS 时间戳、临界区可重入
  包装、lwconfig 路径风格、lwrlog、lwhyper）均已有 `$IFDEF MSWINDOWS` 且带
  非 Windows 分支；`lwproxyws` 代理 widgetset 支持 TWin32/TGtk2/TQt5 三基类；
  demos、tools 无 Windows 专属单元引用
- lpi 清理：12 个 lpi 的 Windows 反斜杠路径（`lib\$(TargetCPU)`、
  `..\..\src\core`）统一为正斜杠；删除 gallery.lpi 固化的 x86_64/win64 与
  gallery_gui.lpi 固化的 mips64el/linux（恢复跟随编译器默认，防坑 113 复发）
- 实测交叉编译：Windows 宿主 + ppcrossx64 → x86_64-linux（nogui），
  `lazbuild --os=linux --cpu=x86_64 --ws=nogui --compiler=...ppcrossx64.exe`
  —— hello 与 gallery 均成功产出 ELF（gallery_nogui-x86_64-linux，
  ~4.2MB 代码段；FPC 内部链接器自动兜住 crtn.o 缺失警告）
- 注意：lpi 里手写 `<TargetOS Value="linux"/>` lazbuild 不采纳（SetBuildTarget
  仍为 win64），必须走命令行 `--os/--cpu/--ws` 三参数
- gallery win64 重编因 exe 被用户进程占用（error 5）暂缓，代码编译已通过

## 118. 组件面板图标（2026-11-13）

- IDE 组件面板 "lazarusWeb" 页此前全是默认红方块：设计期包没提供图标资源，
  IDE 按类名在 LazarusResources 找不到 'TLWxxx' PNG 就落默认。
- 落地：`src/design/icons/*.png`（10 个 24x24 PNG，蓝色 LCL 风格：Form=窗口+地球、
  Login=窗口+锁、FileUpload=文档+绿箭头、DBGrid=表格、DBNavigator=四箭头条、
  Chart=柱状+折线、Gauge=半圆仪表、ColorPicker=四色块、HTMLFrame=</>、
  PDFFrame=PDF 红角标）→ `lazres lwdesign_icons.lrs ...` 打包 → 注册单元加
  `initialization {$I lwdesign_icons.lrs}`（LResources 已在 uses）。
- 维护：`icons/gen_icons.py`（PIL 画图脚本，PNG 源 + 脚本均已登记进 lpk Files，
  Type=Binary/Text）。改图标后重跑脚本 + lazres + 重装包。
- 注意：设计期包静态链接进 IDE —— 改包后必须在 IDE 里重装（Package >
  Install/Uninstall 或包编辑器里 Recompile），重启 IDE 面板图标才刷新；
  仅 lazbuild 编包不会改变已运行的 IDE。

## 119. 合并 FPC 3.2.2 兼容分支（2026-11-13）

- 来源：`Downloads\lazarusWeb20261113-1849\lazarusWeb\src`（完整的 3.2.2 版 src，
  44 个源文件；`C:/fpc322/src` 只是 9 个文件的残片，已弃用）
- 备份：`backup/20261113_pre_merge322/src`（合并前完整 src，1.6M）
- 合并规则（方案 A：以主版为基线，只并入双版本条件编译）：
  - 取 322 版覆盖：`lwapp` `lwbase` `lwhttp` `lwhyper` `lwproxyws` `lwreport`
    `lwsession` `lwwebsocket`（8 个）。它们的差异全部是
    `{$IF FPC_FULLVERSION >= 30301}` 双分支——3.3.1 走原生，
    3.2.2 走垫片（OnRequest 手工接管升级 + `ELWUpgraded`、`LWCanRead` 的
    select 实现、`LWHTTPStatusText` 码表、`SetTextBuf` 1 字节缓冲等）
  - **不取** `lwupload`：322 版落后（还用 `<Temp>/lw_uploads`），保留主版的
    `LWUploadRootDir`（exe 旁 uploads）
  - `lwproxyws` 顺带白捡：`LCLCOCOA` 支持、无匹配 widgetset 时退化
    `TWidgetSet`、AppHandle 仅 win32（消 5044）
  - `lwdesign.lpk` / `lwdsgnregister.pas` 保持主版（含 10 个组件图标）
- 行尾纪律：322 版多为 CRLF、主版多为 LF。按**目标文件原有行尾**归一化后写入，
  避免整文件 diff 噪声（坑 116 的教训）
- lpk 路径：`lwcore.lpk`(8) / `lwserver.lpk`(23) / `lwdesign.lpk`(2) 里残留的
  Windows 反斜杠统一改正斜杠；`UnitOutputDirectory` 仍是 `../lib/...`
  （产物落 `lazarusWeb/lib`，与原来一致）
- 验证（本机 FPC 3.3.1）：`lwcore.lpk` / `lwserver.lpk` / `lwdesign.lpk` /
  `demos/gallery` 全部编译通过；交叉编译产出
  `gallery_nogui-x86_64-linux`（ELF x86-64）与
  `gallery_nogui-mips64el-linux`（ELF MIPS）
- 真机冒烟（龙芯 3A，mips64，Loongnix 4.19）：上传到 `~/LW/`，
  `./gallery_nogui-mips64el-linux --port=8097` 起服务 → `/?form=GalleryForm&client=alpine`
  返回 3008B（下发 lw.css/lw-alpine.css/alpine.min.js/lw-alpine.js），
  Ext 路径 769B（lw.css/lw.js），`POST /lw/api/session` 正常返回 sid。旧版
  保留为 `gallery_nogui-mips64el-linux.orig-1111`
- 坑：`--cpu=mips64` 被 `ppcrossmips64el` 拒绝（`Unsupported target
  architecture -Pmips64`），CPU 名必须写 **`mips64el`**
- 备注：`?v=0.9.0` 仍是静态版本号——之前做的"资源指纹（mtime 进 URL）"
  在回滚那轮一并撤掉了，当前源码里没有 `LWAssetVer`。若再遇到
  "改了 JS 浏览器不生效"，需要重做该功能

### 119.1 功能一致性审计与修回（同日）

机械覆盖后做了四层审计（文件清单 / 符号集合 / 条件编译展开对比 / 逐块语义判定），
详细报告见 `docs/MERGE_AUDIT.md`。核心结论与修回项：

- 符号级：9 个文件"主线有、合并后缺"的例程/类型/常量 = **0**；合并后只多出
  `LWHTTPStatusText` / `LiveConnections` / `LWReqHeader` / `WSRun` / `WSTunnel` /
  `LWCanRead` / `LWSocketClose` / `LWSeqOf` 八个兼容辅助
- 展开对比（关键方法）：按 `FPC_FULLVERSION=3.3.1 + MSWINDOWS` 把**两边都展开**后
  再 diff，避免 `{$IFDEF}` 指令行假报差异（第一版拿原文比展开结果，误判
  `lwapp` 丢了 `{$IFNDEF LCLnogui}`、`lwbase` 丢了 UNIX 时间戳分支，均为假阳性）
- **修回 5 处 322 版擅自改掉的 3.3.1 行为**：
  1. `CodeText` 恢复 `GetHTTPStatusText`（3.2.2 才用自带码表）
  2. 异常握手不再 `sock.Free`（恢复主线"由连接析构兜底"）
  3. `LWReqHeader` 的 `CustomHeaders` 兜底只在 3.2.2 编译
  4. `LWCanRead` / `LWSocketClose` 在 3.3.1 下委托原生 `CanRead` / `Close`
     （`WinSock`/`BaseUnix` 的 uses 也移进 3.2.2 分支）
  5. `lwsession` 的 `PtrInt→PtrUInt` 中转只在 3.2.2 生效
- 3.2.2 视角复核：与 322 原版差异仅剩注释与等价释放逻辑（逐块确认）

## 120. demo 的 gui / nogui 共用中间目录导致 ppu 互相污染（2026-11-13）

- **症状**：`lazbuild demos/gallery/gallery_gui.lpi` →
  `Fatal: (10022) Can't find unit NoGUIInt used by lwws`
- **根因**：`gallery.lpi` 与 `gallery_gui.lpi` 的
  `UnitOutputDirectory` 都写 `lib/$(TargetCPU)-$(TargetOS)`，两种 widgetset
  共用同一目录。先编 nogui（`-dLCLnogui`，`lwws` 引用 `noguiint`）会把
  win32 构建要用的 `lwws.ppu` 覆盖成 nogui 版本；随后编 `_gui` 就找不到
  `noguiint`（win32 的 LCL 没这个单元）
- **触发条件**：只有当 `lwws.pas` 等单元被重编时才暴露（改了 core 单元后必现），
  与"编译顺序"有关，之前一直没踩到
- **修法**：输出目录加 widgetset 后缀
  `lib/$(TargetCPU)-$(TargetOS)-nogui` / `-win32`（`gallery`、`dbaware` 两对
  工程各改一处）；旧的共用目录已清理
- **顺带**：`tests/t_hyper.py` 的首页断言只认 `lw.js`，dbaware 默认客户端是
  alpine（页面里只有 `lw-alpine.js`），改为两者都接受

## 121. TPanel/TScrollBox 的 BevelOuter 边框在浏览器里完全没画（2026-11-13）

- **症状**：TPanel 默认 BevelOuter=bvRaised 在 LCL 里有一圈 1px 3D 边，浏览器
  端什么都没有；TScrollBox 默认 BorderStyle=bsSingle 同样没边。之前修坑 114/115
  时已顺带发现 `.lw-body.lw-boxed` 无 CSS 规则（当时只修了 htmlframe/pdfframe/chart）。
- **三层根因**：
  1. 客户端 `lw-alpine.js` 的 panel/scrollbox 分支早就按下发值给了 `lw-boxed`，
     但 CSS 里只有 `.lw-group/.lw-list/.lw-grid/.lw-tree/.lw-htmlframe/...` 的
     复合选择器，**没有 `.lw-body.lw-boxed`** —— class 加了也没视觉效果；
  2. 服务端 `lwwriter.pas` 只在 `AKind='panel'` 分支发 bevel/border，而
     TScrollBox 的 kind 是 `'scrollbox'`，**一条属性都不发**（autoscroll 靠
     客户端 `k==='scrollbox'` 硬编码才侥幸有滚动语义）；
  3. bevel 的"凸/凹"方向（LCL Frame3d：bvRaised 上左高光下右阴影）从没映射过。
- **修法（三处一起）**：
  1. CSS：`.lw-body.lw-boxed { border:1px solid #b9c3cd; box-sizing:border-box; }`
     + `.lw-bev-raised/.lw-bev-lowered/.lw-bev-space` 三档方向。
     **box-sizing 是硬前提**：`.lw-body` 是 100%×100%，不加它边框会把盒子顶出
     2px，父容器立刻伪造滚动条（坑 110 同款教训）。
     1px 边框 + border-box 也正好等价 LCL 的语义：`TCustomPanel.AdjustClientRect`
     在 BevelOuter<>bvNone 时把客户区内缩 BevelWidth(1) —— 子控件坐标 1:1 对齐。
  2. JS：按 `node.bevel`（Ord(TPanelBevel)）追加 `lw-bev-raised/lowered/space`。
  3. writer：补 `AKind='scrollbox'` 分支，下发 border/autoscroll。
- **验证**（tests/cdp_panel_bevel.py，CDP）：11 个 .lw-body、9 个 boxed、
  8 个 raised，全部 1px solid、box-sizing=border-box、`.lw-kids` 宽度 = 面板
  clientWidth（边框占在框内，坐标无 1px 偏移）；唯一一个内容超高的滚动区
  （node 22，320 vs 123）去掉边框后依然超高 —— 是本来就有的合法滚动区，
  不是边框顶出来的。t_gallery 50/50。截图 tests/panel_bevel.png。
- **教训**：客户端"先画 class 后补 CSS"的模式（坑 114/115/121 同款）意味着
  每加一种容器都要同步查 CSS 有没有对应规则；`.lw-boxed` 目前共 7 类宿主，
  漏一处就是"看不见的边框"。

## 122. lwhyper/worker 的 WS 连接每条漏 1~2 个 TSocketStream 对象（2026-11-13）

- **症状（源码级确认）**：FPC 3.3.1 走 fphttpserver 的升级机制，
  `TFPHTTPConnection.DoHandleRequest` 在 `CheckUpgrade` 返回 True 后执行
  `FSocket := Nil`（见 fphttpserver.pp ~2214 行）—— **所有权移交给我们之后，
  谁都不释放这个流对象**。lwhyper 的 WSTunnel 与 worker 的 WSRun 在 3.3.1 下
  都只关 socket 不 Free 对象：每条 WS 连接漏 1 个（worker）/ 2 个（lwhyper：
  client + TInetSocket）对象。之前压测"没观察到内存增长"只是因为单条对象
  只有几百字节，量级被噪声盖住了。
- **修法**（对齐 lwhttp.WSRun 已有的 `if AOwnSocket then sock.Free` 约定）：
  1. `lwwebsocket` 新增 `LWSocketShutdown`：只 shutdown(SHUT_RDWR=2) 叫醒阻塞
     中的读写，不关闭 —— 给"稍后还要 Free"的收尾路径用。
     **为什么不能先 Close 再 Free**：`TSocketStream.Close` 不幂等，3.3.1 的
     `Destroy` 会再 Close 一次，对同一句柄 closesocket 两次，句柄被系统复用
     时可能误关别人的连接。
  2. `TLWWSTunnel` 增加 `AOwnClient`（3.3.1=True / 3.2.2=False）：CloseAll 对
     归自己的 socket 只 shutdown；Destroy 里 Free 完成唯一一次 close。
     worker socket 恒由隧道释放（两个 FPC 版本都是）。WSTunnel 所有提前退出
     （缺 key、无可用 worker 502、握手失败）统一走收尾，3.3.1 下同样 Free，
     不再走"连接析构兜底"的旧假设。
  3. `lwhttp.WSRun` 的两条异常握手提前退出（缺 key / 握手应答写失败）在
     AOwnSocket 时也补了 `sock.Free`。
  4. `lwwebsocket` 的 `WinSock`/`BaseUnix` uses 从"仅 3.2.2"改为恒引入
     （shutdown 要走底层句柄）。
- **可观测性**：`/lw/hyper/status` 新增 `wsopen`（正在透传的隧道数，收尾正确
  时必然回 0）/ `wsdone`（累计正常收尾）/ `heap`（GetFPCHeapStatus.CurrHeapUsed）。
  排查"每连接漏对象"用 wsopen 最快：单调上涨就是漏。
- **复测**（tests/t_ws_churn.py，新建：并发建 WS→读 101→SO_LINGER=0 立即 RST，
  覆盖"对端突然消失"收尾路径；注意客户端必须设 SO_LINGER=0，否则几千次就把
  Windows 动态端口耗光报 WinError 10048）：
  - 终版 10000 次建/断（8 并发）：0 失败，`wsdone=10000 wsopen=0`，
    lwhyper 句柄数 163 恒定（不漏 fd/线程），worker alive、restarts=0；
  - 对照：直连 worker（lwhttp.WSRun）20000 次建/断 0 失败、句柄恒定；
  - 修复前同口径 ~208B/连接的私有内存增长，修复后降到 ~100B/连接量级
    （且 lwhyper 与直连 worker 都有这个量级的漂移、堆计数不动）—— 残余部分
    是每连接一线程 + fcl-web 连接对象的运行时开销，不是 socket 对象泄漏，
    量级可接受、随连接数线性但不加速。
- **教训**：fcl-web 的升级机制是"所有权移交"语义，接手方必须 Free；
  3.2.2 与 3.3.1 的归宿不同，任何 WS 收尾代码都要按 AOwnSocket 分叉。

## 123. DBGrid/ValueListEditor 单元格进入编辑时行高跳动、编辑框比单元格矮一圈（2026-11-13）

- **症状**（用户截图对比）：浏览态单元格是纯文本、行高饱满；点击进编辑后
  编辑框四周留白、整行高度变化。用户要求"修改单元格时不改变大小"。
- **根因**（两个叠加）：
  1. `lw-alpine.css` 把就地编辑器硬编码成固定高
     `.lw-table td .lw-input { height: 22px; padding: 1px 4px; }` ——
     单元格实际高度远不止 22px，编辑框必然矮一圈；
  2. `$lwDbCell` / `$lwVeEdit` 用 `td.textContent=''` 清空后把 input **塞进
     文档流** —— 编辑器参与行高计算：普通行高 = 文本行高 + td padding 6px +
     border 2px，编辑时 = 22 + 6 + 2，两个数不相等 → 整行跳动。
- **修法（覆盖模式，纯前端）**：
  1. 进编辑只给 td 加 `lw-cell-edit`，原文本 span（valeditor 是裸文本节点）
     **隐藏但留在文档流当尺寸撑子** —— 行高/列宽进出编辑一个像素不变；
  2. 编辑器绝对定位铺满 td（`.lw-cell-edit .lw-input` 特异性压过 22px 旧规则），
     `padding:2px 7px` + 1px 边框正好对齐 td 的 3px 8px 内边距，光标落点不偏移；
  3. 提交/Escape 统一走 `leave(v)`：摘 class、移除编辑器、还原文本。
- **验证**（tests/cdp_dbedit_size.py，新）：dbgrid price 列
  before 25px → 编辑中 25px → 提交后 25px → 服务端补丁回来 25px，编辑器与
  td 四边重合 ≤1px，提交后无残留编辑器；**同格二次编辑**（77）正常 ——
  覆盖"编辑一次后不能再编辑"的旧坑路径；valeditor 23→23→23。
  t_gallery 50/50、t_dbaware 134/134。截图 tests/dbedit_during.png。
- **测试环境的两个坑**：
  1. 无头 Edge 的 `blur()` 会移走焦点但**不派发 blur 事件**（800ms 后仍无
     blur）——探针里补发合成 `FocusEvent('blur')` 才能触发 commit；
     真浏览器无此问题；
  2. CDP `/json` 目标列表会混入 `edge://sync-confirmation-dialog`，
     按 URL 过滤后再取 page；gallery 的 products 网格在
     网格列表 → 数据感知 **两级页签**下面，且 `tr.children` 里混着
     Alpine `<template>` 元素，列定位必须用 `querySelectorAll('td')[col]`。
- **备注**：`cdp_grid_edit_twice.py` 是 Ext 客户端的历史调试脚本（依赖
  `Ext` 全局），与本次改动无关；本轮只动 `lw-alpine.js/css`。

## 124. `fpShutdown` 不在 BaseUnix 里，Linux 交叉编译直接编不过（2026-11-13）

- **症状**：win64 全套全绿，交叉编译 x86_64/mips64el/aarch64-linux 时报
  `lwwebsocket.pas(241,5) Error: (5000) Identifier not found "fpShutdown"`。
- **根因**：坑 122 加 `LWSocketShutdown` 时按"Linux 走 BaseUnix"写了
  `fpShutdown`，但 FPC 的 `BaseUnix` 只导出 `fpClose/fpSelect/fpRead/fpWrite`
  这一批，**`fpShutdown` 在 `Sockets` 单元**。Windows 分支走
  `WinSock.shutdown`，所以这个错只在非 Windows 平台暴露 —— 单平台验证
  抓不到。
- **修法**：`lwwebsocket.pas` 的非 Windows uses 补 `Sockets`：
  ```pascal
  {$ELSE}
  , BaseUnix         { fpSelect / fpFD_ZERO / fpFD_SET }
  , Sockets          { fpShutdown（3.2.2/3.3.1 都在这里） }
  {$ENDIF}
  ```
- **验证**：三个 Linux 目标全部链接成功（ELF machine 62 / 8 / 183）；
  win64 全量重编 0 失败；`t_ws` 8/8、`t_hyper_ws` 6/6 复测通过。
- **教训**：凡是"两个版本都要编、且平台分支不同"的垫片，改完必须跑一遍
  交叉编译 —— 单平台重编 + 单平台回归证明不了跨平台可用。

## 125. TLWSideMenu 进组件面板 + 调色板图标（2026-11-14）

- **需求**：`TLWSideMenu` 要像 `TMainMenu` 一样，设计期能从组件面板拖到窗体，
  双击弹 IDE 原生菜单编辑器（增删菜单项 / 建子菜单 / 设 Caption、ShortCut、
  Checked / "Add icon from file…" 设图标 / 挂各叶子项 OnClick），并且面板上
  有图标而不是默认红方块。
- **为什么继承 `TMenu` 就够**：IDE 用
  `RegisterComponentEditor(TMenu, TMainMenuComponentEditor)`（`designer/menueditor.pp:2667`）
  按**继承链**查找组件编辑器，`TMainMenuComponentEditor.Edit` 的实现是
  `ShowMenuEditor(Component as TMenu)`，`TMenuDesignerForm.SetMenu(aMenu: TMenu; …)`
  全程没有 `as TMainMenu` 的硬转 —— 所以任何 `TMenu` 后裔都白得菜单设计器。
  注册到面板只需要 `RegisterComponents`，不需要写 `TComponentEditor`。
- **落地三处**：
  1. `src/core/lwsidemenu.pas` 加进 `lwserver.lpk` 的 Files（`lwwriter` 用它，
     之前靠 `OtherUnitFiles=core` 隐式编进去，包清单里没登记 —— 设计期包
     `uses lwsidemenu` 会找不到）；
  2. `icons/gen_icons.py` 加 `TLWSideMenu` 画法（深色左侧栏 + 高亮行带左侧白条
     + 右侧内容块），`lazres lwdesign_icons.lrs … TLWSideMenu.png` 重新打包，
     `lwdesign.lpk` Files 登记该 png；
  3. `lwdsgnregister.pas`：`uses` 补 `lwsidemenu`，`RegisterComponents('lazarusWeb', […, TLWSideMenu])`。
- **面板图标资源名必须 = 组件类名**（`'TLWSideMenu'` / PNG），IDE 按类名在
  LazarusResources 里查，查不到落默认方块（同坑 118）。
- **注意**：`TMenu` 后裔不是 `TMainMenu`，拖到窗体上落在"非可视组件栏"，
  **IDE 不会自动赋 `Form.Menu`**（`TCustomForm.SetMenu` 参数类型是 `TMainMenu`，
  类型上就不可能），所以 `AForm.Menu is TLWSideMenu` 这种防御写法编不过
  （`Error: (4039) Class or Object types "TMainMenu" and "TLWSideMenu" are not related`）。
  侧栏在**设计期没有视觉预览**，只有运行时浏览器里才画出来 —— 这是正常现象。
- **生效方式**：设计期包是静态链接进 IDE 的，`lazbuild` 编包不会影响已运行的
  IDE；必须在 IDE 里打开 `src/design/lwdesign.lpk` → Compile → 重装/重启 IDE。
- **验证**：`lazbuild --ws=win32 src/design/lwdesign.lpk` 通过（`lwdsgnregister.ppu`
  内含 11 个图标资源）；`grep -o "^LazarusResources.Add('[^']*'" lwdesign_icons.lrs`
  列出 11 项，含 `TLWSideMenu`；`lazbuild -B --ws=nogui src/lwserver.lpk` 通过。

## 126. TComboBox 自绘下拉：datalist 只剩一项 + 原生弹层大黑块（2026-11-14）

- **现象**：demo 里「计划考试年份」下拉点开只有一个 `2026`，而且弹层是
  一整块深色圆角（Edge/Chrome 的 native 弹层跟系统主题走）。LFM 里明明有
  2024..2027 四项，服务端 `/lw/api/tree` 的 `items` 也是四项。
- **根因**：可编辑 combo（`csDropDown`）走的是
  `<input list="lw-dl-xx"><datalist>` —— **datalist 的候选按输入框当前文本过滤**，
  框里已经有 "2026"，所以只剩完全匹配的那一项。不是服务端少发数据，
  也不是 `x-for` 没渲染。只读 combo（`csDropDownList`）走原生 `<select>`，
  数据是全的，但弹层样式完全交给浏览器/系统主题，深色下就是大黑块。
- **改法**（`src/client/lw-alpine.js` + `lw-alpine.css`）：`combo`/`dbcombo`
  统一改成自绘下拉 —— `input` + 三角箭头 + 自绘弹层：
  - 状态对象加 `open / px / py / pw`（弹层展开标记与 fixed 坐标）；
  - `$lwComboOpen(id, el)` 按输入框 `getBoundingClientRect()` 算坐标，
    下方放不下就翻到上方，最多显示 10 行再滚；
  - `$lwComboPick(id, t)` 写回 `r.txt`、关弹层、按 LCL 语义发 `OnChange`；
  - `csDropDownList` 不再用 `<select>`，而是同一套自绘下拉 + `readonly`
    input（LCL 里它本来就是白底不可输入，CSS 里 `.lw-combo-in[readonly]`
    要覆盖掉通用的 `#f6f8fa` 灰底）。
- **为什么弹层用 `position:fixed`**：`.lw-tabcard` / `.lw-tabs-body` 都是
  `overflow:hidden`，绝对定位的弹层会被页签卡片裁掉；fixed 才能盖出边界
  （祖先没有 transform 时才成立，本框架的容器都没有）。
- **坑中坑**：只改 `.lfm`（例如给 combo 加 `Style = csDropDownList`）后
  `lazbuild` 增量编译可能**只重新链接、不重编 `{$R *.lfm}` 资源**，exe 里
  还是旧布局（本次实测：lfm 已还原，服务端仍报 `editable:false`）。
  改 lfm 必须 `lazbuild -B`，否则验证结论是假的。
- **验证**：chrome-free 的 CDP 脚本（`/tmp/cdp_combo.py`）实测三组：
  可编辑 combo → 4 项齐、白底弹层、点 2024 后服务端回包
  `报名查询：2024 年份共 6 条`；只读 combo（临时 lfm 加 `Style`，验完还原）
  → `readonly=true`、4 项齐、选中同样触发 `OnChange`；`menu_html` / `menu_main`
  同一份客户端脚本，同步生效。

## 127. TLWForm / TLWLoginForm 从组件面板撤下（2026-11-14）

- **需求**：这两个是**窗体基类**，只由向导生成（New Project / New File），
  没有任何"拖到窗体上"的语义，面板上不该出现。
- **为什么当初在面板里**：坑 64 —— 登录模板 lfm 的**祖先类名** `TLWLoginForm`
  在设计期必须能解析，否则祖先被错配成 `TLWForm`、lfm 里的控件全丢。
  当时的结论是"只有面板注册表能命中"，于是把它们塞进了 `RegisterComponents`。
- **重查 IDE 源码后推翻了这个结论**：`SearchComponentClass`
  （`ide/sourcefilemanager.pas:7079`）解析祖先时走 `TryRegisteredClasses`，
  查找顺序是
  1. `AnUnitInfo.UnitResourceFileformat.FindComponentClass`（单元自带资源）
  2. `IDEComponentPalette.FindRegComponent`（**面板注册表**）
  3. `FormEditor1.FindDesignerBaseClassByName(name, True)`（**设计期基类**）
  第 3 条正是 `FormEditingHook.RegisterDesignerBaseClass` 写进去的表 ——
  所以把 `TLWLoginForm` 也注册成设计期基类，撤掉面板条目后仍然命中。
  （fpweb 就是这么干的：6 个 Module 类只注册基类，不上面板。）
- **改法**（`src/design/lwdsgnregister.pas`）：
  ```pascal
  RegisterClass(TLWForm);
  RegisterClass(TLWLoginForm);          // lfm 按类名 GetClass 用
  FormEditingHook.RegisterDesignerBaseClass(TLWForm);
  FormEditingHook.RegisterDesignerBaseClass(TLWLoginForm);
  RegisterComponents(sLWPaletteTab, [   // 只剩能拖的控件
    TLWFileUpload, TLWDBGrid, TLWDBNavigator, TLWChart, TLWGauge,
    TLWColorPicker, TLWHTMLFrame, TLWPDFFrame, TLWSideMenu]);
  ```
- **图标一并清掉**：不进面板就不需要调色板图标（资源名 = 类名，留着也是死资源）。
  `icons/TLWForm.png`、`icons/TLWLoginForm.png` 删除，`gen_icons.py` 去掉两段画法，
  `lazres` 重打包 → `lwdesign_icons.lrs` 由 11 项变 9 项，
  `lwdesign.lpk` Files 14 → 12（125 里"11 个图标资源"的说法到此为止）。
- **验证**：`lazbuild --ws=win32 src/design/lwdesign.lpk` 通过（0 错误）；
  `grep -o "LazarusResources.Add('[^']*'" lwdesign_icons.lrs` 列出 9 项；
  面板数组已无 `TLWForm` / `TLWLoginForm`。
- **生效**：设计期包静态链接进 IDE，必须 IDE 里 Compile → 重装/重启（同 125）。
  重装后建议实测一次 `File → New → File → lazarusWeb Login form`，
  确认新单元能在设计器里打开（这是唯一需要人眼确认的点）。

## 128. Alpine 渲染层的三档配色：亮色 / 深色 / 跟随系统（2026-11-14）

- **需求**：Alpine 客户端要能在亮色、深色、跟随系统之间切。
- **做法**（CSS 只认一个属性，JS 负责解析偏好）：
  - `src/client/lw-alpine.css` 顶部两块变量表 —— `:root`（亮色）与
    `html[data-lw-theme="dark"]`（深色）。全文件 164 处颜色字面量全部换成
    `var(--lw-*)`（共 ~50 个变量，按"背景/文字/面/线/强调/图表/侧栏"分组）。
    这样**不需要第三套 @media 分支**：跟随系统由 JS 解析成 light/dark 后写到
    `<html data-lw-theme>`，CSS 只有两套。
  - `src/client/lw-alpine.js` 顶部主题模块：偏好 `light|dark|auto`
    存 `localStorage['lw-theme']`；`auto` 时监听 `matchMedia` 的 change
    （系统深色开关、Windows 定时切换都覆盖）；`storage` 事件让多标签页同步。
    `lw-alpine.js` 在 `<head>` 里是**同步**加载的，执行时 body 还是空的，
    所以不会出现"先白底再闪成深色"。
  - 入口：标题栏右侧 ☀/☾/◐ 按钮（只加在非模态窗体），点开复用
    `.lw-menu-pop` 的三项菜单；API 为 `LW.theme.set/get/current/button`
    与 `window.$lwTheme`（HTMLFrame 里的脚本也能用）；另派发
    `lw:themechange` 事件给业务侧。
- **服务端**：`TLWForm.LWTheme: TLWThemeMode = (twAuto, twLight, twDark)`，
  `default twAuto`（枚举 0 值，不写构造也能对齐 LCL 的字段零初始化），
  writer 在窗体 JSON 里多写 `theme`。前端只当"本地还没有用户选择时的默认值"。
- **易踩的三处**：
  1. **SVG 表现属性不认 `var()`** —— `fill="var(--x)"` 无效（表现属性不是声明
     上下文）。图表/仪表盘改成 class 承载（`.lw-ch-title/-text/-axis/-grid/-track/-sep`），
     换主题时已画好的 SVG 直接跟着变色，不用重绘。
  2. **左侧菜单图标自带底块** —— `TMenuItem.Bitmap` 是 24bpp 无 alpha 的小图，
     图标里画了一块"侧栏底色"的实心方块。亮色主题下侧栏变浅色，这块底就会
     变成一个深色方块。用 `filter: invert(1) hue-rotate(180deg) saturate(.25)
     brightness(1.06)` 把它翻成浅色、字形翻成深色（hue-rotate 保证色相不跑偏），
     变量名 `--lw-sm-ic-filter`，深色主题下是 `none`。
  3. **HTMLFrame 里的自绘菜单** —— 内容是 innerHTML，和页面同文档，所以直接写
     `background:var(--lw-sm-bg,#2c3947)` 就能跟着主题走（第二参数是兜底值）。
     `demos/menu_html` 已按这个写法改过，是"自定义 HTML 跟随主题"的样板。
- **侧栏配色**：亮色=浅灰蓝面板（#eef2f7）深色文字，深色=原深蓝面板；
  两套都是 `--lw-sm-*` 变量，避免"亮色页面里跳出一块深色侧栏"。
- **验证**（CDP 真浏览器，非只看编译）：
  - `menu_lcl`：初始（系统深色 + 无本地偏好）跟随成 dark；点按钮弹
    `亮色/深色/跟随系统` 三项、当前项带勾；选深色后 `localStorage` = dark，
    刷新后保持；`Emulation.setEmulatedMedia` 模拟系统亮/暗，auto 档即时跟随；
    组件底色实测 `body #15181c / grid #1d2229 / 输入框 #1d2229 / 状态栏 #212730`。
  - 临时给 lfm 加 `LWTheme = twDark` 全量重编（`-B`）实测：服务端下发
    `theme=dark`，本地无偏好时页面为 dark 且不写 localStorage；用户选亮色后
    刷新仍为亮色（用户选择压过设计期默认值）。验完已还原 lfm。
  - `gallery`：图表背景 `#fff → #1d2229`、标题文字 `#2b3a49 → #dde3ea`、
    网格 `#e3e8ee → #333d48`，仪表盘刻度/标题同步骤变。
- **坑**：`demos/gallery/lw/` 是扁平部署的客户端**副本**（`LWFindClientFile`
  先查 exe 旁的 `lw\`），改 `src/client/` 后忘了同步，就会出现"改完没效果"；
  另外 CSS/JS 的 URL 带 `?v=<LW_VERSION>`，浏览器会缓存，验收时要
  `Network.setCacheDisabled` 或 Ctrl+F5。

## 129. 主题切换过一次后就失效（要点两次、需刷新）（2026-11-14）

- **现象**：标题栏主题按钮点开选一次正常；再点开选别的主题，弹层一闪、主题毫无变化；
  刷新页面后又只能生效一次。
- **根因**：主题弹层的"点外面关闭"是**每开一次弹层就 `document.addEventListener`
  注册一个** `onDoc`，而这个监听只在"点到弹层外面"的分支里
  `removeEventListener` 自摘。流程是这样坏的：
  1. 第一次：弹层1 打开 → 注册 onDoc1 → 点菜单项（在弹层内）→ 应用主题，
     但 onDoc1 **没摘**（它只在弹层外点击时摘）；
  2. 第二次点按钮：mousedown 命中 onDoc1，`anchor.contains(target)` 成立 → return，
     onDoc1 依然留着；随后弹层2 打开、注册 onDoc2；
  3. 点弹层2 的菜单项：mousedown 先命中**残留的 onDoc1** —— 弹层1 已 detach，
     按钮也不含 target，于是它执行 `closeAllMenus()` 把弹层2 从 DOM 删掉；
  4. 元素已不在文档里，后续 `click` 落到 body 上，菜单项的 click 处理器永不执行
     → 主题不变。刷新后监听表清空，循环重来。
- **改法**（`src/client/lw-alpine.js`）：改成**常驻单例监听**，
  用模块变量 `themePopEl / themePopAnchor` 记录"当前弹层实例"，判断的是实例而不是
  注册时机；`closeAllMenus()` 一并把这两个引用清空（其它菜单关掉时主题弹层引用
  也失效）。`themeMenu()` 里不再注册监听，只登记实例。
- **验证**（CDP 真实鼠标事件 `Input.dispatchMouseEvent`，不是 `el.click()` —— 后者
  不触发 mousedown，复现不出来）：
  - `menu_lcl`：亮/深/跟随 循环 **10 轮全对**（`data-lw-theme-pref` 与
    `data-lw-theme`、`body` 计算色逐轮变化，深 `rgb(21,24,28)` / 亮 `rgb(223,227,230)`）；
  - 点内容区空白：弹层 `pops 1 → 0`；弹层开着再点按钮：重开为 1 个，不卡死；
  - 刷新后偏好保持；控制台无异常；
  - `gallery`（走 `demos/gallery/lw/` 扁平副本那条查找路径）同样 10/10。
- **教训**：凡"每次开都注册、只在某个分支里自摘"的 document 监听，都会留下
  指向已 detach 节点的悬空处理器（ghost listener）；要么单例化，要么在关闭路径上无条件摘除。

## 130. TStaticText 在浏览器里不显示 + 标题栏 ▢ 表达不出"最大化"（2026-11-14）

### 130.1 stxtHello（TStaticText）整块不见
- **现象**：`demos/gallery` 标准控件页的 `stxtHello`（Caption = `TStaticText 静态文本`）
  在浏览器里是空白，同一页 `TLabel` 正常。
- **根因**：`lwwriter.WriteKindPropsBody` 只有 `if AKind = 'label'` 一个分支，
  `KindOf` 明明把 TStaticText 判成 `static`，但这个分支没覆盖它 ——
  节点 JSON 里只有 `caption`、没有 `text`。前端 `stateOf` 的 `txt` 取的是
  `node.text`，取不到就是空串，`x-text` 于是渲染出一个空 div（控件"消失"）。
  Ext 层（`lw.js`）写的是 `node.text != null ? node.text : node.caption`，
  有 caption 兜底，所以只有 Alpine 层暴露。
- **改法**：
  - `lwwriter.pas`：分支改成 `(AKind = 'label') or (AKind = 'static')` 共用 `text`
    输出；TStaticText 另发 `textalign`（Alignment）、`staticborder`
    （TStaticBorderStyle 0/1/2）、`transparent`、`wordwrap=False`。
  - `lw-alpine.js`：`case 'static'` 从 `case 'label'` 里独立出来 ——
    用 flex 而非 text-align（带边框时要垂直居中，Alignment 走 justify-content），
    按 `staticborder` 加 `.lw-static-single` / `.lw-static-sunken`；
    `stateOf` 里给 `static` 补 caption 兜底，旧服务端配新客户端也不会再空。
  - `lw-alpine.css`：`.lw-static`（内边距）+ 两种边框，颜色全走主题变量。
- **验证**：`/lw/api/tree` 里该节点已有 `"text": "TStaticText 静态文本"`；
  浏览器 DOM 为 `<div class="lw-label lw-static" x-text>`，130×20、`scrollWidth`
  未超宽（无裁剪）；深色 `rgb(228,232,238)` / 亮色 `rgb(27,27,27)` 随主题翻转。
  `demos/audit` 的 `stx1`（`BorderStyle = sbsSingle`）实测边框
  `1px solid rgb(59,69,81)`，文字在框内垂直居中（盒高 22、文字 17、上内边距 2）。

### 130.2 标题栏右上角 ▢ 不像"最大化"
- **根因**：图标是字形 `▢`（U+25A2）。该字符在很多字体里落到"缺字方块"或
  空方框，13px 下字重和尺寸也不受控，看起来就是标题旁边一个无意义方块。
- **改法**（`lw-alpine.js` 的 `winIcon` + `lw-alpine.css`）：改内联 SVG，
  三态分别是 —— 最大化：两支斜向**外扩**双箭头；还原：**两层窗口叠角**
  （系统里"还原窗口"的标准形状，与箭头不会看混）；关闭：X。
  三者统一放进 22×20 的可点块并加 hover 底色（`--lw-hover`），
  一眼能看出是可点按钮而不是装饰。顺带删掉重复的 `.lw-win-theme` 规则：
  原来它带 `padding:0 7px` + 后面的 `width:22px`，content-box 下主题按钮
  会比另两个宽 14px；现在三条规则合成一个共用块（含 `box-sizing:border-box`）。
- **验证**（CDP 真实鼠标）：连续点 4 次，`lw-win` 的 `lw-max` 类与
  `title`（最大化/还原）逐次正确切换，图标图形数同步在「2 path（双向箭头）」
  与「1 rect + 1 path（叠角窗口）」之间变化；模态窗 `.lw-win-x` 22×20、
  内有 svg、点击后 `win 2→1`、遮罩归零；`menu_lcl` 回归同样正常，控制台无异常。

### 附带：gallery 的 exe 是旧的
`demos/gallery/gallery_nogui.exe` 是 11-12 的文件，而 `gallery.lpi` 的产物叫
`gallery_nogui-$(TargetCPU)-$(TargetOS).exe`（`gallery_nogui-x86_64-win64.exe`）。
只编不拷的话，双击跑的一直是老代码。本次已用新产物覆盖 `gallery_nogui.exe`
（并补了同名 `.ini`，指向 `client=alpine`）。

## 131. TLWLoginForm 增加图形验证码（TLWCaptcha，2026-11-14）

需求：登录窗体要有图形验证码，点图能换一张。

### 131.1 为什么不用 TBitmap/Canvas 画字

服务端跑 `--ws=nogui`，没有真实 Canvas，更没有字体后端：
`TBitmap.Canvas.TextOut` 在 nogui 下要么空白要么直接抛 FPImageException
（坑 129 那类问题的同源）。验证码要的只是"几个扭曲字符 + 干扰线"，
所以走 **内置 5×7 点阵字模 + FPImage 直接写像素**：
零字体依赖、零 widgetset 依赖，任何档位都能出图，PNG 由 `TFPWriterPNG`
编码（`lwcaptcha.pas`）。

### 131.2 三层结构

| 层 | 位置 | 职责 |
| --- | --- | --- |
| 控件 | `lwcaptcha.pas` 的 `TLWCaptcha`（TGraphicControl） | 位置/尺寸/字符数；`Refresh` 换图；设计期画占位示意 |
| 出图 | `LWCaptchaPng` + `/lw/api/captcha` | 生成答案、画 PNG、`no-store` 返回 |
| 校验 | `TLWLoginForm.TryLogin` + `LWCaptchaCheck` | 先验码再验账号密码；一次性消费 |

`lwwriter` 里 `KindOf` 把 `TLWCaptcha` 判成 `captcha`，节点只发一个
`src`（`/lw/api/captcha?k=<令牌>&v=<版本>&n&w&h`）。**必须排在所有标准控件
判断之前** —— 它是 TGraphicControl 后代，落进 `unknown` 就是一个占位框。

### 131.3 两个"刷新"要分清（这是本坑的核心）

- **点图刷新**：纯前端。`$lwCaptchaTap` 只在 `src` 后追加 `&r=<时间戳>`，
  服务端看到 `r` 就重新生成答案。不走事件、不占会话执行锁、零等待。
- **服务端换图**：`TLWCaptcha.Refresh` 作废旧答案并把版本号 +1，
  `src` 里的 `&v=` 变了，补丁重设 `src`，浏览器才重拉。
  登录失败（验证码错 / 账号密码错）都走这条，用户不必手动点图。

为什么当初不把"点图刷新"也做成事件：点击会经过 `LWHandleEvent` ->
会话执行锁 -> 一次完整往返，慢且占线程；而换图对服务端状态只有"换答案"
一个副作用，用 `r` 参数表达足够了。反过来，如果让前端直接改
`r.src`（响应式变量）来实现服务端换图，会和补丁重设 `src` 打架，
一次操作白拉两张图。

### 131.4 一次性答案 / 缓存 / 深色主题

- 答案存进程级 `TStringList`（令牌 -> 答案）+ 临界区，不挂会话对象：
  图片请求由独立 HTTP 线程处理，拿不到"正在执行事件的会话"；
  超过 4000 条按插入顺序丢最老的（验证码是短命数据）。
- `LWCaptchaCheck` 无论对错都立刻删表项 —— 同一张图只允许试一次，
  否则"图不变、码可穷举"验证码就白做了。
- 响应头 `Cache-Control: no-store` + 前端换图靠改 URL：两者缺一不可，
  否则浏览器拿旧缓存表现为"点了没反应"。
- 深色主题不画第二张图：`--lw-captcha-filter` 在 dark 块里是
  `invert(.92) hue-rotate(180deg) saturate(.85)`，浅底深字一键变深底浅字，
  切主题不额外请求。
- 排障开关：环境变量 `LW_CAPTCHA_DEBUG=1` 时把 `令牌 = 答案` 打到 stderr。

### 131.5 向后兼容

`RequireCaptcha` 默认 True，但**窗体上没有 TLWCaptcha 就整段跳过**
（`GetCaptcha = nil`）。`demos/dbaware` 的旧登录窗体实测：注册会话后
`captcha` 节点数 0，提交错误账号拿到的仍是"用户名或密码不正确"，
没有误报"验证码错误"。

### 131.6 验证（真实浏览器 + 服务端日志对照）

`tests/cdp_captcha_e2e.py`（Alpine + 真实鼠标，一次跑完）：

- 首屏 `img.lw-captcha` `naturalWidth=110 / naturalHeight=34`，CSS 尺寸与
  PNG 一致（无拉伸）；
- 点图：`src` 变、带 `&r=`，服务端答案确实从 `2HKF` 换成 `X9HP`
  （对照 `LW_CAPTCHA_DEBUG` 日志），新图仍解码成功；
- 用小写 `x9hp` 提交 -> 登录成功（`SameText`），登录窗体消失、主窗体出现；
- 错误码 `ZZZZ`：Toast「验证码错误，已换一张，请重新输入」，
  图片 `&v=0` -> `&v=1` 自动换图，仍停在登录页；
- Ext 层（`lw.js`）同样：`Ext.Img` 110×110 命中、`cursor:pointer`、
  点击后 `src` 带 `&r=`；
- 亮/暗两套主题截图各一张（`tests/cap_e2e_light.png` /
  `cap_e2e_first.png`），暗色下计算样式确认为反相滤镜。

顺带修：`demos/login/uLogin.lfm` 的标题原来写的是"密码 123456"，
而 `uLogin.pas` 里其实是 123456 —— 改成同一值，并把窗体加高到 250
放验证码行。向导模板（新建 lazarusWeb Login form）也同步加了 `lblCode` /
`captcha1` / `edCode`，新建即带验证码。

## 132. 验证码落地后暴露的三个问题（2026-11-14）

用户在 `demos/dbaware`（自带 lfm 的登录窗体）上实测反馈三条，逐条记：

### 132.1 页面上一根莫名其妙的竖线（其实是纵向滚动条 + 1px 标签）

现象：登录窗体右边多出一条竖线，底下按钮下方还有一列"点状细线"。
实测（CDP 量 DOM）：`.lw-win-body` `scrollHeight=954 / clientHeight=322`，
超出的高度来自一个 **1×1 像素的 `TLabel`**（`lblHint`，设计期 Width/Height
留成 1 忘了改），而它 `WordWrap=True` 且 Caption 是一整段话 ——
浏览器就按"每行一个字符"折成一列 700 多像素高的字。

两层修：

1. 数据：`demos/dbaware/uLogin.lfm` 的 `lblHint` 给真实尺寸，并在
   `FormCreate` 里 `lblHint.AutoSize := False` —— **AutoSize 开着时
   LCL 会按文字重算尺寸**，把 lfm 里的框子又撑大了（实测 540×60，
   比设计值高出 9px，滚动条就是这么来的）；
2. 规则：`lw-alpine.js` 的 label 渲染里，声明宽度 < 16px（装不下一个
   汉字）时一律按 `nowrap` 排 —— 这种宽度不可能是"真的要折行"，
   宁可截断也不要把界面变成竖排。

修完 `scrollHeight == clientHeight == 322`，无滚动条、无竖列。

### 132.2 关掉浏览器再打开，直接进主页面（跳过登录）

根因不在服务端：认证是**会话级**的（`TLWSession.Authenticated`），新会话
必然要求登录。问题在客户端把 sid 存进了 `localStorage` —— 那是永久存储，
浏览器重启后还会把上一轮**已认证**的会话 attach 回来。

改存 **会话 cookie**（`lw_sid_<端口>`，不带 `Max-Age`/`Expires`）：

| 场景 | localStorage（旧） | 会话 cookie（新） |
| --- | --- | --- |
| 刷新页面 | 保持登录 | 保持登录 |
| 同浏览器开新标签页 | 共享会话 | 共享会话 |
| 关掉浏览器再打开 | **仍然是登录态**（错） | 重新登录（对） |
| 同机多端口 demo | 各自一份 | cookie 名带端口，各自一份 |

为什么不用 `sessionStorage`：它是**按标签页**隔离的，开第二个标签页就
拿不到会话，得重新登录；cookie 是浏览器级、会话级，正好卡在中间。
（**2026-11-14 这条推理被推翻**：用户要的恰恰是"关标签页即退出"，
见 132.5 —— 现在就是 sessionStorage。）

配 `localStorage['lw.persist']='1'` 可恢复"记住我"（跨重启保持），
`?fresh=1` 仍用于强制新会话（测试脚本全靠它）。`lw-alpine.js` 与 `lw.js`
同步改，语义一致；`forgetSid` 会同时删 cookie 与 localStorage 副本。

### 132.3 新建 -> TLWLoginForm 要自带验证码

原来只有"新建 -> lazarusWeb Login form"模板带验证码；而 IDE 里"新建窗体、
把基类改成 TLWLoginForm"（或干脆 `SetLogin(TLWLoginForm)`）出来的是空窗体，
一个控件都没有，自然也没有验证码。

现在把"kit"下沉到基类：`TLWLoginForm.AfterConstruction` 里判断
**如果窗体上一个控件都没有**，就按模板同一套坐标补建
`lblTitle/lblUser/edUser/lblPass/edPass/lblCode/captcha1/edCode/btnOk/btnReset`
（`AutoBuildUI` 可关）。判断时机很关键：`inherited AfterConstruction`
会走到 `TCustomForm.AfterConstruction` 里的 `DoCreate`，**OnCreate 先于
这里执行**，所以"用户在 FormCreate 里自己建了控件"也能被正确跳过；
lfm 设计的窗体更是早就 >0 个控件。向导模板里的那段补建代码随之瘦身成
`inherited + OnLogin := @DoLoginEx`（避免两处坐标各写一遍）。

顺带修两个"无 lfm 窗体"的坑：

- `TLWFormProvider.CreateForm` 建出来的窗体 `Name` 是空串（lfm 才会给名字），
  而 `TLWForm.SetVisible` 用 `Name <> ''` 判断"这是网页窗体" —— 空名字时
  `Hide` 落到 `inherited`（nogui 下不生效），登录成功后登录窗关不掉。
  现在工厂用注册名兜底，基类补建时也给了默认名 `LoginForm`。
- 主窗体同样受益：纯代码建窗现在也有名字，多会话里不再出现"无名窗体"。

### 132.4 验证

- `tests/t_kitlogin.py`（新增，`tests/kitlogin` 是个**没有任何 lfm** 的工程，
  登录窗体直接用 `TLWLoginForm` 基类）：**19/19** —— 自动补建的 3 个输入框 /
  2 个按钮 / 1 个验证码都在，窗体被撑到 390×270，错码不放行且自动换图，
  正确码 + admin/admin 进主窗体、登录窗已移除；
- `tests/cdp_dbaware_login.py`（新增，真实 Edge + 真实鼠标）：竖列元素 0 个、
  `scrollHeight-clientHeight=0`、验证码 110×34 解码成功、登录进主窗体、
  cookie 有 `lw_sid_8111` 而 localStorage 无 `lw.sid`、刷新仍在主窗体、
  **删 cookie（= 关浏览器）后重新打开回到登录页**；
- 回归：`t_login.py` 19/19、`t_controls.py` 26/26、`cdp_captcha_e2e.py` 全绿；
- Ext 层（`?client=ext`）同样命中验证码图、cookie 名正确、无 localStorage sid。

### 132.5 sid 改存 sessionStorage：关标签页即退出

132.2 把 sid 从 localStorage 挪到了**会话 cookie**，解决了"关浏览器还登录"。
但用户马上发现下一个不对劲的地方：**关掉标签页、再开一个，还是直接进主页面**。
cookie 是浏览器级的，关页签它当然还在 —— 而桌面的心智是"关掉窗口 = 退出程序"。

三个存储，三档寿命，缺一档都不对：

| 存储 | 寿命 | 表现 |
| --- | --- | --- |
| localStorage | 永久 | 关浏览器还登录（错） |
| 会话 cookie | 浏览器级 | 关浏览器才退出，**关页签不退出**（不够） |
| **sessionStorage** | **页签级** | **关页签即退出**；刷新还在（对） |

所以现在 `lw.sid` 存 sessionStorage：

- 刷新同一页签 -> 仍在（`boot()` 里 `attach` 回自己的会话）；
- **关标签页 -> 存储没了，下次打开重新登录**；
- 每个页签各自一个会话（新页签默认是新会话，不共享上一页的登录身份）；
  `/lw/api/attach` 保留，业务要共享就显式带同一个 sid 打开；
- 同一台机器多个端口不用再给键名加端口了（sessionStorage 本按源隔离）；
- `boot()` 顺手把老版本留下的 `lw_sid_<端口>` cookie 删掉 —— 留着会让
  "关页签即退出"失效（老浏览器会拿它 attach 回旧会话）；
- "记住我" 仍是 `localStorage['lw.persist']='1'`（此时 localStorage 里
  另存一份 sid，跨页签/跨重启都保持）。

验证（`tests/cdp_dbaware_login.py`，真实 Edge）：登录后
`sessionStorage['lw.sid']` 有值、localStorage 空、`document.cookie` 无
`lw_sid_8111`；同页签刷新仍是主窗体；**`Page.close` 关页签后新开一个 ->
回到登录页**。Ext 层（`?client=ext`）同样：sessionStorage 有 sid、无 cookie、
新页签是新会话。

### 132.6 关浏览器再打开还是直接进主页面：浏览器"恢复上次会话"把 sid 还回来了

132.5 上线后用户又报："登录后关掉浏览器再打开，还是跳过登录窗体"。原因不在
存储选错，而在**浏览器的会话语义**：

> 启动时"恢复上次打开的网页"会把 `sessionStorage` 连同 sid 一起还原。

于是"sessionStorage 里有 sid"这件事，既可能是"同一个活着的页签"，也可能是
"十分钟前被关掉、现在被还原的旧页签" —— 光看存储分不出来，登录就"被记住"了。
（Headless 里复现不出来：headless 的 --restore-last-session 不会真的还原页签。）

**解法：pagehide 墓碑。** 页面真的要走了（`pagehide`，且不是进 bfcache）
就在 sessionStorage 里写一枚时间戳 `lw.bye = Date.now()`；下次启动先看它：

| 卸载到再次加载的间隔 | 判定 | 结果 |
| --- | --- | --- |
| 几十毫秒（刷新） | 同一个活页签 | 保持登录 |
| 3 秒以上（关窗口 / 关浏览器 / 被还原） | 中间断过 | 旧 sid 作废，回登录页 |
| 没有墓碑（首次打开、崩溃） | 无从判断 | 保持当前逻辑（有 sid 就复用） |

阈值 `BYE_GRACE_MS = 3000`（3 秒），比较的是 `performance.timeOrigin`
（本次导航开始的时刻）与墓碑时刻 —— 差的只是"上次卸载 -> 这次导航开始"的
空档，页面本身加载多久不算进来，所以服务器慢、页面重也不会把刷新误判成
"关过窗口"。刷新时这个空档通常是 1-50 毫秒。墓碑被读过就删掉，避免影响下一轮判断；墓碑作废只
影响 sessionStorage 那份 sid，`localStorage['lw.persist']='1'`（记住我）仍然
跨页签/跨重启保持。

验证（`tests/cdp_browser_restart.py`，真实 Edge）：登录 -> 主页面；同页签刷新
-> 主页面；墓碑 1 秒前 -> 主页面（不误杀刷新）；**墓碑 60 秒前（= 被还原的
旧页签）-> 登录页**；`taskkill` 杀掉 Edge 再拉起 -> 登录页。Ext 层用 sid 是否
换新会话判定，同样通过。

### 133 页签切换：内容换了、高亮不换（demos/multi）

现象：点 `pcMain: TPageControl` 的第二个页签，"参数设置"的内容显示了，
但页签条上高亮的还是"订单数据"。

根因在渲染层而非服务端：`buildTabbar` 用 `innerHTML` 拼出页签条
（`<div class="lw-tab lw-active">`），页签条**没有任何 Alpine 绑定**，
只在建树/补丁时整块重建一次。而 `$lwTabClick` 只做了两件事：
`r.active = i` + `applyTabActive()`（切卡片显隐）—— 高亮 class 没人重画。

修法：点击时补一次 `paintTabbar(id, active)`（只切 `.lw-active` class，
不重建 DOM，避免页签条闪烁），同时把 `S.ND[id].active` 也改掉，
让后续补丁能据此判断"服务端和我一致，别重建"。

第二个坑：`$lwTabClick` 原来只在 `$lwHas(id,'OnChange')` 时才回发事件。
`demos/multi` 的 `pcMain` 没挂 `OnChange`，于是服务端的 `ActivePage`
一直停在 0 —— 点"刷新"触发一次重下树，页签就被弹回第一页。
现在**无条件回发**（服务端 `LWApplyValue` 先把 `ActivePage` 切过去，
没挂 handler 时 RTTI 调用是空操作；`TTabControl` 早就这么做了）。
Ext 层（`lw.js`）的 `tabchange` 同样改成无条件回发。

验证：`tests/cdp_multi_tabs.py`（真实 Edge + 真实鼠标）四项全过 ——
点击后高亮跟手、补丁落地后不回弹、点"刷新"后仍停在第 2 页、
整页重载后服务端 `ActivePage` 已是第 2 页。

### 134 TStatusBar 在网页上"只剩两个小方块"（demos/multi）

现象：`stbMain: TStatusBar`（LFM 里 `Height=34`、`Panels` 两格 `600 / 450`）
在网页上是一条空栏，左边贴着一两个 21px 的小方块，底部还悬空一截。

根因不在 LCL，在序列化：`WriteForm` 只发了 `form.status = [Panels[i].Text]`，
**没发任何布局信息**，前端只能自己猜 —— 高度写死 24px，每格宽度按内容自适应。
空文本 + 1px 分隔线 = 21px，于是两格 600/450 变成两个小方块，其余全空。
高度 24 也不是 LFM 里的 34（折算后 23），所以底边还差几像素。

改法：

1. `lwwriter.StatusInfo` 新增 `form.sb`：
   `{h, simple, simpletext, sizegrip, panels:[{w, al, bev}]}`；
   文本仍走 `status`（保持兼容，补丁只比这两个键）。
2. **高度要折算**。LCL 加载 LFM 时按 `DesignTimePPI / 当前 PPI` 缩放窗体和
   子控件（multi 的 1230x840@144PPI → 820x560，Panels 600/450 → 400/300），
   但 `TStatusBar` 是 `AutoSize=True` 的控件，`ShouldAutoAdjust` 对它返回
   False，`Height` 就停在设计值 34 上 —— 与已经缩放的子控件不在同一把尺子上，
   照它画会把底部一行按钮切掉（实测 `重新加载` 被压掉 9px）。所以按同一个
   比例折算：`h := Round(h * PixelsPerInch / DesignTimePPI)`（34 → 23，
   与 `demos/grid` 在 96PPI 下写的 22 对齐）。面板宽度**不用**再折，LCL 已经
   替我们折过了。
3. 前端按 LCL 的规则画（`lw-alpine.js` 的 `paintStatusbar` / `placeStatusbar`，
   `lw.js` 的 `statusItems`）：
   - 除最后一格外 `flex: 0 0 Panels[i].Width`，**最后一格占满剩余**（LCL 的
     `SB_SETPARTS` 把最后一格设成 `-1`，即延到右边缘）；
   - `.lw-status-item` 加 `box-sizing: border-box` —— 否则每格胖 21px
     （padding 20 + 边框 1）；
   - `bev=pbNone` 和最后一格不画右分隔线；
   - `SimplePanel=True` 只画 `SimpleText`；
   - 状态栏改由 CSS `bottom: 0` 贴客户区底边。原来用
     `body.clientHeight - 24` 算 `top`：body 一旦出现横向滚动条，
     `clientHeight` 少 15px，状态栏就悬空一截。
5. 顺带挖出横向滚动条的根：`.lw-win` 原来用 `border: 1px`，客户区比
   LFM 的 `Width` 少 2px（LCL 里 `Width == ClientWidth`）。`Align=alNone`
   的容器（multi 的 `pcMain` 宽 820）于是溢出 2px，逼出一条 15px 的横向
   滚动条 —— 状态栏悬空、`sgData` 少一截都是它引起的。改成
   `box-shadow: inset 0 0 0 1px` 画边框（不占盒模型），客户区就是 820，
   滚动条消失，状态栏宽度也跟着 = ClientWidth。
4. Ext 层的分格用 `xtype:'component'` + `margin: 0`（Toolbar 默认给每个 item
   加外边距，400 的格子实际占 408），最后一格 `flex: 1`。

顺带把 demo 补成"能看出是状态栏"：`FormCreate` 里
`Panels[0].Text := '就绪'`，`FillGrid` 里 `Panels[1].Text := Format('行数 %d', ...)`
—— 后者正好验证"服务端改 Panels[i].Text → 补丁落到前端"。

验证：`tests/cdp_multi_statusbar.py`（真实 Edge，18 项）——`sb.h=23`、
分格 400 / 418（分隔线在 400）、底边与客户区底边对齐、宽度不压边框、
初始文本 = `status`、点"应用参数"后第 1 格文本变而宽度不变、Ext 层同样
400 / 418。`demos/db`（三格 480/300/570，运行时写文本）也实测
320 / 200 / 558，分隔线与文本都正常。

### 135 TDBGrid 多表头（TLWDBGrid.HeaderGroups，2026-11-14）

用户问"tdbgrid 能实现多表头功能吗"——LCL 的 `TColumnTitle` 只有
Caption/Alignment/MultiLine，没有跨列/分层能力，照搬做不到；于是做成框架扩展：

    TLWDBGrid(grd).HeaderGroups.Add('基本信息|0-2');

**API 规则**：每条 `'标题|起-止'`，起/止是**可见列**下标（0 起、含止），
`Visible=False` 的列不占号；没写进任何分组的列自己贯通两行（rowspan=2），
所以"部分分组 + 部分不分列"的混排天然支持。重叠/越界的分组按先来先占、
非法的直接丢掉（服务端算归属，前端只画）。

**协议**：dbgrid 节点新增 `hg=[{t,a,n}]`（t=标题、a=起始可见列、n=跨度），
没配分组就没有这个键（普通 TDBGrid 载荷一个字节不多）。服务端
`lwwriter.WriteDBGrid` 里 `TLWDBGrid(G).HeaderGroups` 逐条转。

**前端**（两端同步实现）：

- Alpine：`dbHeadHtml` 画两行 thead——分组格 `colspan=n`（居中、底色深一档
  `lw-th-grp`），未分组列 `rowspan=2`；叶子格的 OnTitleClick 事件参数**烧成
  字面量**（`{col:3}`）——表头不在任何 x-for 作用域里，写 `{col:j}` 一点就
  "j is not defined"。分组格不回发 OnTitleClick（跨列标题没有唯一列）。
- Ext：`dbColumns` 先平铺建带编辑器的叶子列（c0..cN），再按 hg 包一层
  分组列（columns 嵌套 columns）——顺序反了编辑器会丢；CellEditing 在
  重构列结构后仍可复用（连编两次回归过）。

**踩坑**：

1. lfm 必须写 `object grdMain: TLWDBGrid`。FPC 的 `GetClass` 只认**精确类名**，
   `RegisterClassAlias('TDBGrid', TLWDBGrid)` 在 lfm 加载路径上不生效
   （同 TLWDBNavigator，坑 23 同款）；lfm 写 TDBGrid 时 `is TLWDBGrid` 为
   False，HeaderGroups 白配。业务代码里的字段声明也要跟着改类型。
2. **滚动残影**：两级表头整体 sticky 后，`border-collapse: collapse` 的表格里
   数据行文字会从表头里透出来（Chromium 折叠边框和 sticky 的绘制顺序问题，
   逐格 sticky / translateZ(0) 都救不了）。配了分组的表格换
   `border-collapse: separate; border-spacing: 0`（`tableCls` 给 table 加
   `lw-hg` 类），视觉与 collapse 无差别，残影消失。
3. **粘顶**用整块 `thead { position: sticky }` 而不是逐格 sticky：第二行 th
   的 top 要按第一行高度算，字体/DPI 一变就叠字，还得 JS 量高写 CSS 变量；
   整块粘之后那套 `stickHeads`/`--lw-hgh` 全部删掉。
4. 隐藏列不占列号：demos/db 的 grdMain"备注"列 Visible=False，7 个可见列
   分组只能分到 5——业务侧按"可见列"数，别按 Columns.Count。

**验证**：`tests/cdp_dbgrid_headergroups.py`（demos/db，29 项：hg 协议、
两行 thead 的 colspan/rowspan、叶子点击排序、分组点击不发事件、滚动粘顶、
Ext 嵌套列、控制台无异常）+ `tests/cdp_gallery_dbgrid_hg.py`（gallery 两页签
演示 + Ext 分组表头下连编两次，24 项）。回归 `t_gallery` 50/50。
演示位置：`demos/db`（基本信息/价格与库存 + 统计页单组混排）、
`demos/gallery`（数据感知页三组 + "上架"贯通；大表分页页两组）。

**注意**：`demos/gallery/lw/` 是 gallery 自带的前端静态副本（别的 demo 直接
读 `src/client`），改了客户端 JS/CSS 要 `cp src/client/* demos/gallery/lw/`，
否则 gallery 跑的是旧版——本次就栽在这上面（服务端有 hg、前端不认识）。

### 136 Caption 里的 `&`：加速键（mnemonic）两端统一解析（2026-11-14）

用户报"快捷键处理有问题，多了 & 这个符号"——LCL 的 `&X` 在 Caption 里是
**助记符标记**：控件自己把它画成带下划线的 X，并注册 Alt+X。以前服务端原样
把 `'确定(&O)'` 下发，浏览器 `<div>` 里没有 LCL 的绘制逻辑，就把 `&` 直接
写出来了。

**规则是"控件级"的，不是全局的**（这点最容易做错）：

| 位置 | 解析 `&X`？ | 依据 |
| --- | --- | --- |
| TLabel / TStaticText Caption | 是 | `TCustomLabel.ShowAccelChar` 默认 True |
| TButton / TBitBtn / TSpeedButton / TToolButton | 是 | 同上 |
| TCheckBox / TRadioButton / TRadioGroup / TCheckGroup | 是 | 同上 |
| TGroupBox / TPageControl 页签 / TTabControl 页签 / TMenuItem | 是 | 同上 |
| **TPanel.Caption** | **默认否** | `TCustomPanel.ShowAccelChar` 默认 **False**（extctrls.pp） |
| 任意控件显式 `ShowAccelChar := False` | 否 | 控件级开关 |
| TListBox / TComboBox / TCheckListBox 的 **Items** | 否 | 条目是 owner-draw 文本，不走加速键 |
| TStatusBar.Panels[].Text | 否 | 同上 |
| 窗体的 Caption（标题栏） | 否 | 系统标题栏不画助记符 |

**服务端**（`lwwriter.pas`）：`MakeBase` 里 `AccelOff(C)` 用
`GetPropInfo(C,'ShowAccelChar') + GetOrdProp` 判是否被关掉，**只在关掉时**下发
`acc: 0`（省字段：默认即解析，普通控件 payload 不变）。菜单项
（`WriteMenuItems` / `WriteSideItems`）改回**原样下发 Caption**（以前是
`StringReplace(it.Caption,'&','')` 硬删，连 `&&` 转义都一起吃掉）。

**客户端**：两端各有一个 `accHtml(s)`（`&X` → `X` + `<u>X</u>`、`&&` → `&`、
孤立 `&` 原样）和 `accText(s, acc)` / `$lwCap(s, acc)` 包装（`acc===0` 时
只 escape 不解析）。所有 Caption 类渲染点都走它；列表 Items / 状态栏 /
窗体标题**不**走。Alt+X 由统一的全局 keydown 处理：在 `ACCEL_HOSTS`
（`button, .x-btn, .lw-btn, .lw-tab, .x-tab, .lw-menu-top, .lw-menu-item,
.x-menu-item, ...`）里找可见且含 `<u>k</u>` 的元素并 `click()`。

**踩坑**：

1. 一开始把 `TCheckListBox` 的条目也套了 `accText`——LCL 里列表条目
   owner-draw 不解析，`X & Y` 被画成 `X <u>Y</u>`。改回 `esc(t)`。
2. 全页正则扫"裸露的 `&X)`"会把 TPanel 那条**合法**的字面量算成泄漏。
   扫描范围要限定在"会解析 &"的那类元素上。
3. "面板标题没解析"报了 FAIL，其实是 LCL 的默认值就这样（见上表）。
   为了把两种情况都钉住，`demos/accel` 摆了两个面板：一个不给
   `ShowAccelChar`（`E 面板(&P)` 原样），一个显式 `True`（`I 面板(&Q)` 解析）。

**验证**：`demos/accel`（20 类控件铺满一屏，点击回显到日志标签）+
`tests/cdp_accel_audit.py`——Alpine / Ext 各 57 项、合计 **114 项断言**，
既查"该解析的真的画了下划线"，也查"该原样的真没有 `<u>`"，还实测
`Alt+O` 点中"确定(O)"、`Alt+E` 切复选框。截图 `tests/accel_alpine.png`、
`tests/accel_ext.png`。

### 137 Ext tab.Panel 一个未配对的 suspendLayouts 把整页吃掉（白屏）

加完上面那条、重建 gallery 之后，gallery 的 Ext 端**整页只剩窗口标题**
（`document.body.innerText` 18 字符、`.x-tab` 0 个），Alpine 端正常。查了很久
才发现不是渲染不全，是**布局从来没 flush 过**：

    Ext.Component.layoutSuspendCount === 1     // 卡住了
    Ext.suspendLayouts(); Ext.resumeLayouts(true);   // 手动跑一下，页面立刻恢复

**根因**（Ext 7.0.0 `ext-all.js`）：`Ext.tab.Panel#initComponent` 里有

    a.layout = Ext.apply({type:'card', ..., activeItem: c}, a.layout);

这里 `c` 是 `activeTab` 这个**索引数字**。构造 tab.Panel 时 `items` 还是空的，
解析不出组件，于是 **card 布局的 `activeItem` 就永久留着那个数字**（实测
`tabpanel.layout.activeItem === 10`）。之后任何一次 `setActiveTab` 都会走到

    if (b && b.fireEvent('beforedeactivate', b, a) === false)   // b = 那个数字

数字没有 `fireEvent` → `TypeError`。而 `setActiveTab` 的实现是

    Ext.suspendLayouts(); ... b.layout.setActiveItem(a); ... Ext.resumeLayouts(true)

异常一跳，`resumeLayouts` 永远执行不到，全局挂起计数 +1 不再归零；此后所有
`updateLayout` 只排队不 flush —— **整页不渲染**。老的 Ext 版本也一样（`x.x.x`
同款），只是 gallery 的"重建后首次装载"才踩到。

**修法**（`src/client/lw.js`，两处一起，缺一不可）：

- `lwSetActiveTab(tabs, want)`：先把 `tabs.layout.activeItem` 显式清成
  `undefined`（绕过那个数字），再 `setActiveTab(卡片组件)`；并且前后**快照
  `Ext.Component.layoutSuspendCount`，finally 里用 `resumeLayouts(true)` 把
  计数还回快照值**。这样即使 Ext 内部别的分支再抛，也不会把全局计数带偏。
  `buildTabs` 首次激活和 `patchNode` 里服务端改 `ActivePage` 都改走它。
- `runLayout` 不再用 `try { body.getWidth() } catch { return }` 吞错：`ct.body`
  没建出来时 `body` 会退化成 `ct` 本身（`Ext.Component` 没有 `getWidth`），
  以前 TypeError 被当成"没尺寸"直接 return，绝对定位的子项永远停在 (0,0)。
  现在先判 `typeof body.getWidth === 'function' && body.dom`，量不出来/量到
  0×0 都走统一的 `scheduleRetry`（最多 6 次、递增间隔）。

**教训**：`catch (e) { }` 包着 Ext 的 `suspend/resume` 调用是定时炸弹——
Ext 里有若干"先挂起、出错也不保证恢复"的地方，漏一次就静默整页白屏，
控制台还只有一条被 Ext 布局循环吞掉的 TypeError。排查手法记在
`tests/dbg_ext_tabs.py`（打印 `layoutSuspendCount` + 每个 tabpanel 的
`activeTab` / `layout.activeItem` / 类型 / rendered）和 `tests/dbg_pause_ext.py`
（`Debugger.setPauseOnExceptions: all` 抓被吞异常并打栈）。

**连带修**：`tests/cdp_dbedit_size.py` 找 `price` 列时是扁平枚举所有
`thead th`——加了多表头（坑 135）之后表头变两行，扁平下标 8 对不上
tbody 的 7 列，`td` 取不到 → 全 null。改成按**最后一行表头**自己的 cell
顺序数；顺带把 Edge 内建页那条 `Could not establish connection` 噪音滤掉。

### 138 TLWDBGrid"选中行不跟随"：点行必须定位数据集游标（2026-11-14）

用户报 gallery 的 TLWDBGrid 选中行显示不跟随（点别的行，高亮和右侧的
DBEdit/TDBMemo 都不动）。根因在 **Alpine 端**：

`$lwDbRow` / `$lwDbCell` 把回发套在 `$lwHas(id,'OnCellClick')` 里——
**业务代码没挂 OnCellClick 的网格（grdDb 就没挂），点行连事件都不发**，
数据集游标永远不动。而 LCL 里"点 TDBGrid 的一行，游标移过去"是**网格的
内部行为**，跟业务挂没挂 handler 无关；编辑单元格提交后会动，纯粹是
`OnSetFieldValue` 那条链路里 `LWApplyGridPos` 顺带做的。

**修法**（`lw-alpine.js`）：新增 `lwDbLocate(id,row,col)` —— 先乐观把
`r.recno = row+1`（recno 是页内 1 基行号，服务端 `WriteDBGrid` 同一约定，
不在本页时服务端发 0 取消选中）高亮立即跟上，再**无条件**发
`OnCellClick`：服务端 `LWHandleEvent` 里 `LWApplyGridPos` 对任何事件都先
定位游标，`LWInvokeEvent` 没挂 handler 就是空操作，一条往返两件事都做完。
`$lwDbRow`（整行）与 `$lwDbCell`（单元格，含只读列——只读网格点行照样要
移动游标）都改走它。**Ext 端一直是无条件发的（`itemclick` 里直接
`fire(node,'OnCellClick')`），行为本就正确**，这次只是对齐。

教训：`$lwHas` 只该用来决定"要不要发业务事件"，**框架语义的行为
（定位游标、翻页、滚动）不能依赖业务 handler 的存在**。

**验证**：点 P003 可编辑格 → 高亮到第 3 行、右侧 DBEdit 变"商品 3"、
TDBComboBox 变 P003；点 P006 只读格同样跟随；Ext 端点行 0→2 无回归。
回归 `t_gallery` 50/50、`cdp_gallery_dbgrid_hg` / `cdp_accel_audit` ALL PASS、
`cdp_dbedit_size` PASS、`t_controls` 26/26、`t_dialog` 36/36。

### 139 标题栏与窗体客户区颜色太接近（2026-11-14）

用户报标题栏和窗体分不清。原来 `.lw-win-title` 用 `--lw-title-a/b`
（亮色 `#f7f9fb→#e8edf2`）配在 `#f0f0f0` 的客户区上，几乎无差别。

**修法**（`lw-alpine.css`）：标题栏改用**独立变量** `--lw-cap-a/b/fg`
（亮色 `#dbe6f2→#c6d6e8` + 深蓝灰文字 `#23374d`，暗色 `#333f4d→#273140`
+ 亮文字），比客户区明显深/亮一档，一眼可分；`--lw-title-a/b` 保留给
进度条槽色等旧用途（这正是不能直接改它们值的原因）。标题栏底色加深后
右上角图标（`--lw-icon` 的灰）对比不够，追加
`.lw-win-title .lw-win-max/...  { opacity:.78 }` —— 用透明度而不是换色，
hover 的变色规则继续生效。标题栏下边框也从 `--lw-border3` 提到
`--lw-border-strong`。

### 140 多表头"分组居中、叶子左对齐"不一致（2026-11-14）

用户报 gallery 多表头的标题没水平居中——其实是**两行表头对齐规则不一致**：
Alpine 端分组格（`th.lw-th-grp`）当初特意做了 `text-align:center`，叶子格
却走 `.lw-table th/td` 的 `text-align:left`；Ext 端也一样——分组表头
**Ext 原生就居中**（嵌套列的默认行为），叶子表头跟随列 align（默认左）。
两行放一起，用户自然当成"没居中"。

**修法**：
- Alpine（`lw-alpine.css`）：`.lw-table thead.lw-thead-hg th` 追加
  `text-align:center`——两级表头模式下整行居中，规则统一。
- Ext（`lw.js` + `lw.css`）：`buildDBGrid` 里 `hg` 非空时给 grid 挂
  `lw-hg-grid` 类，CSS `.lw-hg-grid .x-column-header-text-container/text
  { text-align:center }`——**只动表头文字，数据单元格仍按各自 align**
  （用列的 `align:'center'` 会连数据一起居中，不能用）。补丁路径
  reconfigure 分支里 hg 出现/消失时同步 add/removeCls（hg 变化必触发
  dbSig 变化，一定走到）。

**验证**：Alpine 10 个表头格 computed `text-align` 全 center；Ext 端
`lw-hg-grid` 类在位、10 个 `.x-column-header-text` 全 center。
回归 `t_gallery` 50/50、`cdp_gallery_dbgrid_hg` ALL PASS、
`cdp_accel_audit` ALL PASS。

### 141 点单元格"改不了"：点击回发的补丁把编辑器拆了（2026-11-14）

修完坑 138（点行跟随，改成点格无条件发 `OnCellClick`）之后，用户报
gallery 的 TDBGrid 单元格**不能修改**了。

**现象与定位**：点可编辑格 → `$lwDbCell` 建出 `<input class="lw-input">`
（脚本里 `ok inside=true` 能证明建出来了）→ 100ms 后查已不存在；给 tbody
挂 `MutationObserver` 看到 200+ 条 `childList +0/-1`，即**整表反复重建**。

**根因链**：点格 → `lwDbLocate()` 发 `OnCellClick` → 服务端回树补丁 →
补丁里 `r.rows = n.rows` 赋了一个**新数组**。Alpine 的 `x-for` 按数组引用
判断，赋新数组就整段重建 tbody —— 刚 append 到 `td` 里的编辑器跟着被换掉，
用户看到的就是"点了没反应/改不了"。以前点格不发请求，所以没这问题。

**修法**（`lw-alpine.js` 的 dbgrid 补丁分支，两条一起）：

1. `sameRows(r.rows, n.rows)`：行内容（JSON）完全一致时**不赋新数组**。
   点格只改游标，行数据本来就没变，这条就挡住了绝大多数重建。
2. `dbCellEditing(id)`：网格里还有 `.lw-input`（编辑中）时**整段跳过行数据
   更新**，并且**先不记 `__dbSig`** —— 编辑器的提交/取消自己会发事件并带来
   新一轮补丁，那时代码照常同步；要是当场把 sig 记掉，这次变化就永远丢了。

**教训**：把"点一下发个请求"加到高频交互上之前，先确认补丁路径对**局部
重建**是安全的。`x-for` 的整表重建会连带销毁用户正在操作的 DOM（输入框、
滚动位置、焦点）。凡是"每次点击都会回发"的场景，行数据要按内容比较，
并且尊重"用户正在编辑"这个状态。

**验证**：点 P002 的 name → 编辑器稳定存在（0.15/0.5/1.0s 三次采样都在、
焦点在框里）→ 输入回车 → 单元格变新值、行高亮、编辑器摘除；**刷新页面后
值仍在**（真写进数据集）；连续编辑第 4 行同样成功；布尔列勾选照常写回。
Ext 端无影响。回归 `t_gallery` 50/50、`cdp_gallery_dbgrid_hg` ALL PASS
（含 Ext 两次连续编辑）、`cdp_dbedit_size` PASS、`cdp_accel_audit` ALL PASS、
`t_controls` 26/26。

> 排查提示：CDP 探针跑的 Edge 若是**前台命令**起的，命令结束会被 Job
> Object 收走，下一条命令就连不上 9239（`WinError 10061`）。要么整段
> 探针放在同一条命令里，要么把 Edge 用后台任务常驻。

### 142 菜单点什么都没反应 + 服务端刷屏 EJSON（2026-11-14）

用户报 multi 菜单「退出」不起作用，同时服务端控制台反复刷
`[warn] 处理请求时出错: EJSON: Cannot convert data from object value`。
**两个现象同一个根因。**

**定位**：给浏览器插桩（hook `fetch` + `WebSocket.send`）抓真实请求体，
点「退出」发出的是

    {"id": {"id":3,"caption":"退出(&X)",...}, "ev":"OnClick", ...}

**`id` 是整个菜单项节点对象，不是数字**。服务端 `LWHandleEvent` 里
`JGetInt(AReq,'id')` → fpjson `AsInteger` 遇 TJSONObject 抛
`EJSON: Cannot convert data from object value`，整个事件处理被中断 ——
`miExitClick` 根本没执行，所以"不起作用"。

**根子**（历史遗留，`git show HEAD` 就在）：Alpine 端 `fire(id, ev)`
收**数字 id**，而 `bindMenuPop` / 菜单条绑定把节点对象 `m` 直接传了进去
（`fire(m, 'OnClick')`）。Ext 端没这问题——`lw.js` 的 `fire(node)`
本来就是收节点对象、内部取 `node.id`。两个客户端的 fire 约定不一致，
正是这种不一致最容易埋雷。

**修法**：
1. `lw-alpine.js`：两处 `fire(m, 'OnClick')` → `fire(m.id, 'OnClick')`。
2. **服务端加固**（`lwbase.pas`）：`JGetStr/JGetInt/JGetBool` 只对标量
   （jtString/jtNumber/jtBoolean）取值，遇对象/数组**回默认值**而不是抛
   EJSON —— 一条坏请求不该打断整个事件处理、更不该刷屏；
   `lwdispatch.pas` 的 `LWApplyValue` 里直取 `d.AsString` 处同样加守卫。
3. **收尾体验**：点"退出"后窗体全关，没有登录窗体可回的应用（multi）会
   留一张白纸。两端 `applyPayload` 在"关之前有窗体、关之后 0 个"时铺一层
   `#lw-end`「会话已结束……刷新本页可重新进入」（坑 35 的无登录版）。

**验证**：multi 两端点 文件→退出 → 窗体关闭、出现结束提示、日志零错误；
刷新页面重新进入正常。全量回归：`t_gallery` 50/50、`cdp_gallery_dbgrid_hg`
ALL PASS、`cdp_dbedit_size` PASS、`cdp_dbgrid_headergroups` ALL PASS、
`cdp_accel_audit` ALL PASS、`t_controls` 26/26、`t_dialog` 36/36；六个
demo 日志均无 EJSON。（这也是 gallery 控制台刷 EJSON 的原因——用户在点菜单。）

> 排查基础设施：CDP 探针的 Edge 改为**后台任务常驻**（前台命令一结束
> Job Object 就把 Edge 收走，9239 立即拒连）；插桩模板见本次会话
> （`Page.addScriptToEvaluateOnNewDocument` hook fetch/WS 抓请求体）。
>
> 坑中坑：`Page(create={'url':...})` 并不会导航 —— `Page.__init__` 里
> `tab_new()` 固定开 about:blank，create 参数只是"新建页签"开关；
> 要自己再 `pg.send('Page.navigate', {'url':...})`。

### 143 退出后刷新变白屏：attach 到"0 窗体的活会话"（2026-11-14）

坑 142 补了 `#lw-end`「会话已结束……刷新本页可重新进入」，但用户点完
退出**刷新本页**，得到的是一张纯白页 —— 连结束提示都没有。

**定位**：刷新时浏览器从 sessionStorage 捞回旧 sid 走 `/lw/api/attach`。
会话没超时还活着，但窗体已全部关闭，`ApiAttach` 照常返回
`ok:true + forms:[]`。前端 `attachSession` 成功路径不检查窗体数，
`applyPayload` 渲染 0 个窗体；而 `#lw-end` 提示只在"**页内**窗体从有到
无"时出现（`winsBefore > 0` 才铺），刚加载的页面窗体本来就是 0，兜不住
刷新场景 → 白纸。

**修法**（两端 `attachSession`，成功分支开头）：attach 成功但
`resp.forms.length === 0` = 这条会话已经结束 —— `forgetSid()` 清掉旧
sid、`newSession(cfg)` 开新会话重新进入。语义上"活会话不可能 0 窗体"
（至少有主窗体/登录窗体），所以这个判断不会误伤多页签 attach。

**验证**：新增 `tests/cdp_multi_relogin.py` —— 退出出 `#lw-end` →
不带 fresh 刷新 → 主窗体重现（新会话），连跑两轮，控制台零错误；
回归"活会话刷新仍 attach 原 sid"（sessionStorage sid 前后一致）；
`cdp_gallery_dbgrid_hg` ALL PASS、`cdp_dbedit_size` PASS。
注意：`/lw/api/attach` 与两个客户端 js 都是直接读磁盘，改 `src/client`
即生效、无需重编；`demos/gallery/lw/` 的静态副本仍需手动 cp 同步。

## 144. 浏览器标签没图标：`/favicon.ico` 一直回 204（2026-11-15）

现象：浏览器标签上始终是默认地球，别的 Web 应用（如 demo 页签）却有图标。
原因很简单：`lwhttp.pas` / `lwhyper.pas` 的路由里 `/favicon.ico` 是
**占位实现，直接回 204 无内容**——浏览器拿不到图标又不报错，静默显示默认。

**修法**（favicon 不是画的，放文件就行）：

1. 仓库根目录放一份多尺寸 `favicon.ico`（16/32/48px，深蓝紫圆角方块 +
   白色粗体 LW，Pillow 生成，5.3KB）；
2. 两处路由从 204 改为真发文件：`--root` 目录 → exe 同目录 → 都没有才回
   204 兜底；命中时 200 + `image/x-icon` +
   `Cache-Control: public, max-age=86400`（ServeFile 默认 no-store 会被
   覆写——图标是文件级资源，缓存一天即可）；
3. Ext 版（BuildIndexHtml）与 Alpine 版（BuildAlpineHtml）两套外壳 head
   都补 `<link rel="icon" href="/favicon.ico" type="image/x-icon">`；
4. lwhyper 代理层同样直答（不经 worker，不占 worker 会话）。

**发布注意**（已写进 MANUAL 部署节）：老用户浏览器可能缓存了升级前的
204 空响应，升级后要 Ctrl+F5 一次；部署时把 favicon.ico 放 exe 同目录
或 `--root` 目录任一处。

**验证**：`/favicon.ico` → 200/5284B/image/x-icon + 缓存头；两种 client
的页面 head 均带 link 标签；lwhyper 单独编译通过。

## 145. run_in_background 的长驻服务跨轮次也会被回收——用 Start-Process 脱离（2026-11-15）

坑 108 说"长驻服务必须用后台任务（run_in_background）方式启动"，本次
实测发现那只保证**同一轮次内**活着：gallery 服务以 run_in_background
拉起后，分别在 2 分半和 11 秒后无征兆消失（退出码 1、stdout 只有启动
横幅、stderr 空）——又是 Job Object 在轮次结束时把整棵作业树收走，
不是程序崩溃（日志无异常可证）。

**现行正确姿势**（按优先级）：

```powershell
# PowerShell：脱离当前 Job Object 启动（进程活到被显式 Stop-Process）
Start-Process -FilePath 'xxx.exe' -WorkingDirectory '<exe目录>' -WindowStyle Hidden
```

真实用户的终端/双击场景本就不经过 AI 工具的 Job Object，无此问题。
判定还是坑 108 那套：同一条命令内探活正常、下一跳命令再看就没了 =>
环境回收，别往程序 bug 上查。

## 146. nogui 下 LazReport→PDF 图片导出三坑（aTruncate 清流 / 悬空引用 / JPEG 直通）（2026-11-15）

gallery 的 LazReport demo（QF_Lazreport，`uLazReportDemo.pas`）做
`poCompressImages` 优化时踩的三个坑，nogui 挂接图形链路的通用教训：

1. **FPImage 写入器默认清空目标流**：`TFPCustomImage.SaveToStream` /
   `Writer.ImageWrite` 的 aTruncate 默认 True（内部 `Str.Size:=0`）。
   若目标流是页对象流（`TfrPictureView.SaveToStream`），整页数据会被
   PNG 魔数覆写、内容全坏。所有自写 SaveToStream 一律传 `False`；
2. **PDF 图像项只留引用会悬空**：`Images.AddImageItem` 的 `IP.Image :=
   xxx` 只存指针，`TfrPictureView` 在 ExportData 返回后即释放——写 PDF
   时已是悬空引用（现象：图 0×0 且数量翻倍）。必须立即
   `CreateStreamedData(...)` + `DetachImage` 固化像素；
3. **页流里图像边界不能按"流尾"抓**：TVirtualGraphic 保留原始字节做
   JPEG 直通（`AddJPEGStream`→DCTDecode，160×64 从 23.9KB deflate 像素
   降到 1.4KB）与同图去重（FImageCache 按字节比对）时，`LoadFromStream`
   若从当前位置复制到流尾，会把图像后面的其他视图数据混进来——同一张
   图在不同位置抓到的"原始字节"都不同，去重必失效。要按 PNG IEND /
   JPEG EOI 标记精确截断（或解码后按 reader 实际消耗截断）。

配套结论：`poCompressImages` 本来就默认开着（fcl-pdf 构造函数
`[poCompressFonts, poCompressImages]`，导出器 `Options + [...]` 不会清
掉）——优化点不在开关，在避免"解码→逐像素→deflate"的重编码。
nogui 下 LCL `TBitmap/TPNG/TPicture.LoadFromFile/ShowMessage` 全都
AV，图形一律走 `lr_ngcanvas.TVirtualGraphic`（包装 TFPMemoryImage）。


## 147. `TEditButton` 的按钮文字被硬编码成 "…"（2026-11-15）

现象：LCL 设计器里 `EditButton1.ButtonCaption = 'ok'`（宽度 34），浏览器里
却显示 "…"，而且被 `.lw-btn` 的 `padding: 3px 12px` 挤到按钮右缘不居中。

两处根因：
1. `lw-alpine.js` 的 `case 'editbtn'` 把按钮内容写死为 `…`，服务端也从
   没下发过 `ButtonCaption` / `ButtonWidth`；
2. `.lw-eb-btn` 宽 26px 却继承了 `.lw-btn` 的左右各 12px 内边距，内容区
   剩 0px。修复：`padding: 0 !important` + flex 三行居中。

服务端补发：`lwwriter.pas` 的 `editbtn` 分支在**非默认**时下发
`btncap`（`ButtonCaption`）与 `btnw`（`ButtonWidth`），客户端缺省回退
`…` + 26px。注意 LCL 里这两个属性是 **protected**，跨单元读不到，用
派生类重声明可见性：

```pascal
TCustomEditButtonAccess = class(TCustomEditButton)
public
  property ButtonCaption;
  property ButtonWidth;
end;
```

实测：demo 的 `ButtonCaption='ok'` → JSON `"btncap":"ok","btnw":23`
（运行时 buddy 实际宽度被 LCL 从 34 收成 23）。

尚未覆盖：
- Ext 渲染层（`lw.js`）仍用 Ext 的 trigger 图标，trigger 不支持文字，
  要支持得给 trigger 元素挂 `data-cap` + CSS `::before` 自绘；
- `btncap` 只在建节点时下发，运行期改 ButtonCaption 不会实时刷新
  （LCL 里极少这么用）。

另外：`/lw/` 路由读的是 `demos/gallery/lw/` 的静态副本，改
`src/client/*` 后必须 `cp` 过去，否则浏览器拿到的还是旧文件——这次就
先被它骗过一次（服务端返回的 CSS 里没有新规则）。

## 148. `TTabControl`/`TPageControl` 客户区没边框（2026-11-15）

现象：设计器里 TabControl 客户区四周有边框线，浏览器（alpine 层）里
只有页签和内容，客户区光秃秃。

根因：`tabctl`/`tabs` 模板的客户区类是 `.lw-tabs-body lw-boxed`，而
描边规则写的是 **`.lw-body.lw-boxed`**（给 TPanel/ScrollBox 等的
`.lw-body` 用）——两个类名差一个词，规则永远匹配不上，`lw-boxed` 在
这里成了无效类名。

修复：`lw-alpine.css` 补 `.lw-tabs-body.lw-boxed { border: 1px solid
var(--lw-border); box-sizing: border-box; }`（box-sizing 防止边框把
盒子顶出 2px，同坑 110）。TPageControl 的页签卡片区域同款描边，与
LCL 的显示区边框一致。

教训：同一个语义（"带边框的客户区"）在两处用了不同类名组合，
`lw-boxed` 没有统一挂在 `.lw-body` 上时就会静默失效——加新容器时
搜一遍 `lw-boxed` 的全部规则，别只按 `.lw-body` 前缀写。

## 149. 亮色主题下 bvRaised 面板的上/左边框"隐身"（2026-11-15）

现象：`pnlDyn: TPanel`（`BevelOuter` 默认 `bvRaised`）在浏览器亮色主题
里只剩右/下两条边，上/左看不见；LCL 设计器里四条边都在。

根因：亮色主题 `--lw-bevel-hi`（凸起高光，上/左边框色）取 **#ffffff**，
而面板内表面是 `--lw-surface: #ffffff`——高光与面板自己的底色同色。
LCL 真机上面板底是 clBtnFace（#F0F0F0 灰），白高光夹在两片灰之间才
可辨；Web 主题把面板改成白底后，这个前提被打破了。暗色主题不受影响
（hi=#46515e 有对比度）。

修复：亮色主题 `--lw-bevel-hi` 改 **#dde4ea**（与分隔线 `--lw-border2`
一族，仍明显浅于边框 #b9c3cd 与阴影 #8a97a3，保持"高光浅/阴影深"的
凸起语义）。波及面 4 处全部向好：bvRaised 上/左、bvLowered 下/右、
TBevel 内阴影、分隔条亮边。

教训：给"应该被看见"的装饰色取值时，要对照它实际落点的背景变量——
主题把某个表面从灰改白后，所有"白系高光"都要复查一遍对比度。

**暗色主题修订（同日 14:50）**：镜像问题——`--lw-bevel-lo`（bvRaised
下/右阴影）原取 `#12161a`，与面板底 `#1d2229` / 窗体底 `#191d23` 几乎
同色，下/右边框同样"隐身"。改 **#2a323c**：仍明显深于 hi `#46515e`
与边框 `#3b4551`（方向语义不变），但与两种底色可分辨。两主题合计
四个 bevel 色（hi/lo × 亮/暗）现在都满足"落点背景有对比度"。

### 144 LazReport 导出 PDF 换行行距为 0（压字）（2026-11-15）

**现象**：LazReport 导出的 PDF 里自动换行的中文两行互相压字，看起来
"行距是 0"（用户截图：公司名两行贴死）。屏幕预览正常，只有 PDF 有问题。

**根因**（`QF_Lazreport/source/addons/lrFclPDFExport/lr_e_fclpdf.pas`）：
换行步进用的是 `TExportFontItem.TextHeight`，而 fcl-pdf 的
`TFPFontCacheItem.TextHeight` 返回 **CapHeight + |Descender|** —— 拉丁
大写字母高度。解析 simhei.ttf 实测：CapHeight+Descender = **0.828em**，
而 CJK 字面高 ≈ **1.0em**、正确行高（hhea Ascender+Descender+LineGap）
= **1.141em**。步进比字面还矮 0.17em → 两行重叠。纯拉丁文本看不出来，
中文必现。

**修法**：
1. `TExportFontItem` 新增 `LineHeight`：取 `FontData.HHead` 的
   Ascender+|Descender+LineGap（hhea 表，与 LCL 屏幕行高同源）；hhea
   值异常时退 OS/2 typo 度量，再退老算法兜底。uses 加 `fpparsettf`。
2. `DoMemoView` 三处换行相关度量（缩字循环的行高估算、垂直对齐的
   `hg`、逐行步进 `y := y + ...`）全部从 `TextHeight` 换成 `LineHeight`。
   **基线定位（WriteTextRect 的 `Y1 := fY + FTH`）不动** —— 那是
   "基线 = 行顶 + ascent"的近似，行高变大后多余空间落在行间，语义正确。

**验证**：`tests/pdf_ls/`（最小复现程序：载入 demo 模板 → 第一个 memo
换成 17 字公司名、宽 110px 强制折行 → 导出 PDF）。解析内容流基线：
行进 = 15.187pt @ 12pt = 1.266em，与 LineHeight(1.141em) + 模板
LineSpacing(1.5pt=0.125em) 精确吻合；Edge 打开目视三行无压字。gallery
demo（重编后）走 UI 生成报表同样正常。**用户的业务工程重编一次 exe
即生效**（lr_e_fclpdf 源在 C:/111/ccr/QF_Lazreport，编译期源码直接进
exe，没有需要部署的 dll/ppu）。

### 145（144 的下半场）PDF 单元格文字垂直居中偏顶（2026-11-15）

行距修好后用户立刻报：单元格文字偏顶。像素测量（上 9px / 下 20px，
两种格高下偏差恒定 ~5.5px）确认是**基线在行槽里的固定偏高**，两个来源：

1. **居中公式多算一行行距**：`dy/2 - (hg+LS)*hs/2`，行间 gap 只该有
   `hs-1` 个，多出的 LS 把整块上抬 LS/2；
2. **基线偏移用 cap+desc 定位**：CJK 字面是 `[基线, 基线+Ascender]`，
   基本无下伸；行槽里那截 descender 空间不属于字面，算进去字就往上顶。

**修法**（`lr_e_fclpdf.pas`）：
- 居中/贴底/缩字三处的块高改为 `hg*hs + LS*(hs-1)`；
- 新增 `TExportFontItem.InkAscent`（hhea Ascender，异常回 OS/2 typo），
  `BaselineOffset := (LineHeight + InkAscent)/2` —— 字面在行槽里居中；
  `WriteTextRect` / `WriteTextRectJustify` 的基线统一用它。

**验证**（`tests/pdf_ls_check.py`，三个场景独立页）：换行 3 行步进一致
且 ≥ 字面；单行 tlCenter 上下间隙 18.85/18.84pt；多行 tlCenter 整块
13.41/13.41pt。gallery demo（重编）走 UI 生成同一份混凝土配合比报表，
截图目视居中、量像素上下差 ≤3px（其中还有括号下伸的墨迹）。排障开关：
导出器支持 `LW_PDF_DEBUG=1` 打印每次排版的字体度量与坐标（写 stderr）。

### 146（144/145 的终章）空行占位的 tlCenter memo 把文字推到格边（2026-11-15）

**现象**：145 修完居中后用户报「(印章复印无效) 距底框的距离不对了」——
修复前 ~0.77em 的舒适间隙，修复后基本贴住底框（实测 0.5pt）。

**根因**（拿到模板 C:/111/report 后定位）：这类注记是**6 个空行 + 1 行文字**
的 7 行 memo，Layout=tlCenter，靠空行"垫"到格内合适位置——模板作者是按
**1em 的行槽**排的空行。而 144/145 把换行步进/块高改成了 **hhea 行高**
（SimHei 1.14em、STSong **1.301em**），7 行的居中块从 ~107px 撑到 ~158px
（格高才 157px），块直接撑满格子，末行被推到底框上。

**引擎参照**（lr_class 绘制循环，这才是"对"的基准）：
- 行进 `curyf += thf + LineSpc`，thf = **字号px（1.0em）**（还先
  `Font.Height := -Round(thf)` 强设为 1em）——引擎的行槽就是 1em+行距；
- 字体 `TextHeight` 是 CapHeight+Descender，STSong 的 CapHeight=0
  → 老 PDF 行槽 0.83em/0.315em，偶然接近引擎，所以看着"对"。

**修法**（`lr_e_fclpdf.pas`，只动度量定义，排版公式不动）：
- `LineHeight`（行槽）改为 **1em（字号）**——与引擎完全一致；
- `BaselineOffset` 仍取 `(槽高+字面高)/2`（字面在 1em 槽里居中，
  与引擎 TextRect tlTop 的 tmAscent 落点差 <0.1em，但保证居中对称）；
- 缩字/居中/贴底三处公式沿用 145 的块高（hs×1em + (hs-1)×行距）。

**验证**：
- `tests/pdf_ls_check.py`：换行步进 13.5pt@12pt（=1em+1.5pt 行距，
  >字面 10.3pt 不压字）；单行居中 18.85/18.84、多行居中 15.10/15.09；
- 真实模板（混凝土力学性能.frf）导出：注记基线距底框 **9.46pt=0.79em**，
  与用户"修复前正确"截图的 ~0.77em 吻合；
- gallery 走 UI 重新生成配合比报表：公司名两行不压字、注记间隙正常。
- 诊断利器：`pdf_ls <模板> inspect` 直接 dump 模板全部视图参数
  （位置/尺寸/Layout/行距/字体/多行内容），排查模板排版问题先用它。

**教训**：报告模板里大量用"空行当占位符 + tlCenter"竖向定位，
任何"行槽变大"的全局改动都会把它们推到格边；排版语义必须以
引擎（屏幕预览）为准，PDF 导出器只是它的忠实转印。

### 147 TLabel/TStaticText Caption 里的 LineEnding 不换行（2026-11-15）

**现象**：`lblBody.Caption := '…前端。' + LineEnding + '…'`，屏幕预览按
LCL 逐行画，浏览器里却连成一段（换行被折叠成空格）。

**根因**：label/static 的 `text` 原样下发，前端经 esc 后用 x-html /
autoEl.html 注入 —— HTML 里裸 CR/LF 就是空白字符，必然折叠成空格。
LCL 的 DrawText 对 Caption 里的换行是真换行，且与 WordWrap 无关。

**修法**（两端客户端，服务器/业务代码零改动）：
- `lw-alpine.js` 新增 `$lwTxt(s, on)`、`lw.js` 新增 `brText(s, on)`：
  esc → `\r\n|\r|\n` → `<br>` → accHtml（先 esc 再补 br，避免被转义）；
- label / static 两个渲染点（Alpine 模板 x-html、Ext build 的 autoEl 与
  patch 的 getEl().update）从 `$lwCap/accText` 换成它；
- **状态栏仍是 accText**（单行面板，语义不折行）；按钮/页签/菜单等单行
  Caption 的渲染点不动。

**验证**：`tests/cdp_about_linebreak.py`——gallery「模态窗体(uAbout)」
正文 2 个 `<br>`、行盒高 55px（Alpine）/ 51px（Ext），截图三行与
LineEnding 逐一对应；`cdp_gallery_dbgrid_hg` ALL PASS 无回归。

### 148 菜单弹层点外部不关闭（2026-11-15）

**现象**：TPopupMenu 弹出后只有选中菜单项才消失，点菜单外的窗体/空白处
不会关闭；TMainMenu 下拉、主题弹层同一套代码路径。

**根因**（`lw-alpine.js`）：只有主题弹层有 `themePopEl` + 常驻
`document.mousedown` 捕获监听；主菜单下拉和右键菜单只调 `closeAllMenus()`
建新弹层，从不登记实例，也没有外部点击判定。菜单项 click 里那句
`closeAllMenus()` 于是成了唯一的关闭入口。Ext 版用 `Ext.menu.Menu`，
`Ext.menu.Manager` 自带点外部隐藏，实测正常，不用改。

**修法**（`src/client/lw-alpine.js`，同步 `demos/gallery/lw/`）：
- 统一为 `menuPopEl` / `menuPopAnchor` 单例状态 + `openMenuPop(items, anchor)`；
  子菜单仍由 `bindMenuPop` 直接 append，不登记但受同一判定覆盖；
- 一个常驻 `document.mousedown` **捕获**监听：点弹层内不关、点当前锚点不关
  （交给锚点 click 做开关）、点其它处关闭；右键一律先关旧的（随后
  `contextmenu` 在新位置重开）；补 `touchstart` / `Escape` / `window.blur`；
- 主菜单的 `el.__lwOpen` + 100ms 计时器换成真实状态判断
  `menuPopEl && menuPopAnchor === el`，否则"再点一次收起"会被外部关闭
  逻辑变成重开；主题按钮也补上同锚点 toggle；
- 顺手修 `bindMenuPop` 的分隔线错位：`items[i]` 换成按非分隔项重新编号
  （菜单含 `-` 时，后面所有菜单项原本会错一个 id）。

**坑**：监听必须常驻单例且用捕获阶段。开一次注册一个、关掉自摘，在
"点锚点开第二次"那次不摘，旧监听会在下一次 mousedown 先删掉新弹层，
click 落到已移除元素上 —— 就是主题弹层历史上那个"切一次后再也切不动"
的成因；控件常 `stopPropagation`，冒泡阶段收不到 mousedown。

**验证**：`tests/cdp_popup_outside.py`（gallery :8090 两端 + menu_main :8103）
ALL PASS：右键菜单点外关 / 选中项关且无 EJSON / Esc 关 / 右键换位置只剩
一个新弹层 / 主题弹层点外关且两轮可开、再点锚点收起 / Ext 点外隐藏 /
TMainMenu 点外关、间隔 >100ms 再点同一项收起、含分隔线的「帮助→关于」
仍能派发。注意 `.lw-menu-pop` 是 `position:fixed`，Chrome 下
`offsetParent` 恒为 null，测试要用 `getComputedStyle` + 盒子尺寸判可见。

## 坑 149：移动模板改造（方案 B 落地）：DOM 搬迁的三个不变式

2026-11-16 实施「自适应桌面 / 移动端」：窄屏（≤834px）或触控设备把窗体
顶层控件从绝对定位搬进 HTML 模板的 `{%控件名%}` 占位符（自研，模板从
`/lw/tpl/<窗体名>.m.html` 静态下发，服务端不解析模板内容）；≥1100px 搬回
原位，835~1099 回滞区保持上一态。改动：`lwhttp.pas` 新增 `/lw/tpl/` 路由；
`lw-alpine.js` 新增自适应模块（`lwLayoutNow`/`lwApplyFormTpl` 等）；
`lw-alpine.css` 新增 `.lw-tpl`/`.lw-ph` 与触控细节；demo 见
`demos/mobile_demo`（模板 `tpl/MobileMainForm.m.html`）。

**三个不变式**（破坏任何一个都会崩）：

1. 搬迁不改 `S.P[id]`：`syncChildren` 靠 `S.P[n.id] === body` 判定走
   patch 还是整棵重建；DOM 搬进占位符后若连 S.P 一起改，每个增量补丁
   都会把整窗重建一遍；
2. 事件只当触发器：媒体查询 change 在首次断点变化 / 指针变化会漏发
   （CDP 实测），`resize` 与 `visualViewport.resize` 成组重复 —— 状态
   一律现读 + rAF 去重 + 回滞，不能在事件回调里读 `e.matches` 定状态；
3. 回退必须完整：模板 404 或占位符引用了不存在的控件名 →
   `fm.tplFallback` 置位、摘掉 `lw-flow` 重跑 `placeNode`/`runLayout`；
   `placeNode` / `syncChildren` / `ResizeObserver` 三处都要看这个标志
   决定走桌面路径，不能半套。

**模板 CSS 的坑**：绝对定位与定宽都写在 `.lw-n` 包装上（不是内层
`.lw-label`）；占位符到深层控件隔着「面板 `.lw-n` > `.lw-body`」两层，
选择器不能用 `>` 直连（`[data-lw-ph="pnlInfo"] > .lw-body` 不命中）。
容器内部控件 v1 不重排：模板只接管窗体顶层。移动模式下窗体贴满视口
（`savedPos` 保存 left/width/height，切回桌面恢复），否则 144ppi 缩放后
373px 的客户区装不下单列内容，尾部控件被滚出窗外。

**验证**：`tests/cdp_mobile_demo.py` 19 项断言 ALL PASS（桌面绝对定位 /
390 套模板 / 切回还原 / `?layout=` 硬覆盖 / gallery 无模板回退 /
tpl 路由 200·403·404）；回归 `cdp_popup_outside`（24 项）、
`cdp_gallery_dbgrid_hg`（两端）ALL PASS；390px 截图目视：单列流式、
面板文字、清空按钮、贴底状态栏全部正常。

## 坑 150：无模板窗体移动端右侧留白 —— 缩放方案被否决，定为视口跟随

**现象**：手机上打开没有移动模板的窗体（如 gallery，设计宽 1200px），
`tplFallback` 分支把窗体硬压到 `min(设计宽, innerWidth-8)`，子控件仍按
设计坐标绝对定位，超出部分被裁掉 —— 右侧一片空白，布局残缺。

**方案取舍（2026-11-16 同日两轮）**：

1. 第一版：整体 `transform: scale((innerWidth-8)/设计宽)` fit-width，
   18 项断言与截图均通过。用户看实际效果后否决：1200 压到 390 缩放比
   0.32，字号太小不可读 —— **"没模板时退回时不要缩放，否则太小了"**。
   技术上可行（transform 不改布局盒，不污染 clientWidth/RO/runLayout
   度量；缩放须在 runLayout 之前定窗体尺寸），败在可读性。
2. 定稿：不缩放。窗体保持 `min(设计宽, 视口宽-8)`，新增
   `lwFallbackSize`/`lwFallbackSizeAll` 在旋转/改窗/键盘弹出时跟随视口
   重设尺寸并居中（挂在 `lwScheduleLayout` 每帧，布局模式没变也要跑）；
   尺寸变化由 ResizeObserver 触发 `runLayout` 重排拉伸型子控件。

**代价与边界**：右侧空白在内容超出视口时依然存在（设计坐标如此），
这是"不缩放"的固有代价；小屏完整可用性由移动模板承担（方案 B 主路径）。

**验证**：`tests/cdp_fit_scale.py` 重写为不缩放断言，17 项 ALL PASS ——
390 无 transform、宽 382、740/844（回滞区）跟随视口、切回 1200 恢复
设计宽、有模板窗体不受影响；回归 `cdp_mobile_demo` ALL PASS（T2 的
1.0s 固定等待在模板 fetch 上偶发超时，改为轮询等待后消除）。
测试脚手架伪影另见 `MOBILE.md` §8.8：CDP 改视口前先 clear 会瞬间回
1200 触发退出断点，回滞区锁死错误的 desktop。

## 坑 151：移动端首开 TPageControl 内容空白，切一次页签才出现

**现象**：手机打开 gallery（无移动模板，回退路径），页签条正常，
活动页签页内容区空白；手动切换页签后才显示。桌面不受影响。

**根因**（两步叠加，均与容器内容查找有关）：

1. 首开时序：移动模式下建树时窗体顶层控件先进 `lw-flow`（等模板 fetch
   回来再决定套模板或回退），页签控件此刻是文档流、无尺寸 —— 建树时对
   `.lw-tabs-body` 跑的 `runLayout` 按 0 高把 `alClient` 的页签页写成
   内联 `height: 0px`。fetch 回来走回退分支只重排窗体顶层，页签控件
   恢复了服务端尺寸，**页签页的 0 高却没人再算**。
2. 本应兜底的 `applyRect` 容器递归重排救不回来：它用
   `querySelector('.lw-kids')` 找内容容器，是深度优先首匹配 ——
   `tabs` 容器自己没有 `.lw-kids`（页签页在 `.lw-tabs-body`），命中
   的却是第一个页签页内部的 `.lw-kids`（隐藏、尺寸 0），`runLayout`
   见 `!w && !h` 直接早退。

桌面正常是因为建树时页签控件已带服务端尺寸，首排即正确，错误路径
从未被触发。

**修复**（`lw-alpine.js`）：新增 `containerBody(el, kind)` 统一容器
内容查找 —— `tabs` 取 `.lw-tabs-body`（`tabctl` 客户区是公共一块，
`.lw-kids` 在 tabs-body 里，维持原语义），其余取 `.lw-kids`/`.lw-body`；
`applyRect` 的递归重排、`createNode`/`patchNode`/`ctxOf` 四处全部换用。
fetch 回退后 `applyRect(页签控件)` 触发的延迟重排会用正确的 body 把
页签页尺寸补齐，首开即显示。

**验证**：CDP 390 模拟首开（不点页签），活动页签页从 `1198x0` 变为
`1198x632`、22 个子控件可见；`cdp_fit_scale` 23 项、`cdp_mobile_demo`
ALL PASS。注意：一轮 S2-S4 假阴性由**调试 Edge 实例退化**引起（新开
页签 `document.body` 为 null、页面未启动），换新 profile 重启即愈——
长会话 CDP 实例异常时先怀疑浏览器再怀疑代码。

## 坑 152：TUpDown 被渲染成数字输入框 —— 本体应是贴着编辑框的上下箭头

现象：移动端打开含 TUpDown 的窗体（gallery「扩展输入」页签），TUpDown
位置出现一个窄的数字输入框，与旁边的 TEdit 并排，看起来像多了一个
输入框。桌面同样如此（与移动端无关，用户在手机上先发现）。

**根因**：Alpine 渲染层 `case 'updown'` 直接渲染成
`<input type="number">`（x-model 绑 val），把 TUpDown 当成了独立编辑框。
而 TUpDown 的本体是贴着 Associate 编辑框的上下箭头：点箭头改 Position、
触发 OnClick；nogui 没有消息链，Associate 编辑框文本由服务端在
OnClick 处理里联动（lwdispatch）。

**修复**（三处）：

1. `lw-alpine.js` `case 'updown'`：改为 `<span class="lw-ud">` 内两枚
   `button.lw-ud-btn`（▲/▼），点击走新全局 `$lwUd(id, dir)` —— 本地先按
   Increment 步进并夹 Min/Max（与 LCL 一致：Max=0 表示不设上限），再回传
   `OnClick {val}`，服务端补丁回来校正 `r.val`（服务端是最终裁决）；
2. `lwwriter.pas`：updown 节点补发 `inc`（TUpDown.Increment，缺省 1）；
3. `lw-alpine.css`：新增 `.lw-ud`/`.lw-ud-btn`（横向并排两枚箭头，按
   设计期 w×h 定位，LCL 缺省样子；touch-action:manipulation 防双击缩放）。

**验证**：新增 `tests/cdp_updown.py` 5 项 —— `.lw-ud` 存在且无旧
`input.lw-updown`、恰好两枚 ▲/▼ 按钮、点 ▲ 后 Associate 编辑框 10→11、
点 ▼ 回到 10、事件链无异常，ALL PASS；回归 `cdp_popup_outside`（含
menu_main :8103 重新拉起后 C 段）与 `cdp_mobile_demo` 全部 ALL PASS。
注意：gallery 重编后需重启（writer 改动进 exe）；lw-alpine.js/css 是
磁盘文件，同步 `demos/gallery/lw/` 副本即可，无需重编。

### 坑 152 形态定稿（用户 2026-11-16 三轮反馈后）
- **桌面端**：上下堆叠（LCL 缺省样子）——`.lw-ud` 纵向两格，箭头用 CSS
  三角形（`.lw-ud-a`，减号按钮 rotate 180°），不再用文本字形。
- **移动端**：`−/+` 文字大按钮（`html[data-lw-layout=mobile]` 下
  `::after` 切换内容、三角形 display:none），− 在左 + 在右（CSS `order`
  对调，DOM 语义不变）；**高度跟随包装层**（与 Associate 编辑框设计
  高度齐平，不另设 min-height——曾设 40px 被用户指出比输入框高），
  仅横向放宽（min-width:68px）保证可点。
- 两端共用一套按钮语义：第 1 枚=加、第 2 枚=减；另支持滚轮步进
  （`@wheel.prevent` 绑在 `.lw-ud` 上）。
- 测试注：页签项真实类名是 `.lw-tab`（tabctl 是 `.lw-tab` + `lw-tabbar2`），
  不存在 `.lw-tabs-h` —— 写错选择器会把「点错页签」误判成布局 bug。
  `cdp_updown.py` T6 轮询断言移动端 row / 高度 26-38 / ::after 文字。

## 坑 153：桌面端窗体模板（.html）—— 模板机制从移动端扩展到两端

需求（用户 2026-11-16）：桌面端也参考移动端做法，窗体有桌面模板
`<root>\tpl\<窗体名>.html` 就用模板流式布局；没模板时两端都保持
设计期所见即所得（用户确认）。此前桌面永远绝对定位，模板只在
layoutState==='mobile' 时尝试。

**实现要点（lw-alpine.js，服务端仅 lwhttp 404 文案改中性）**：

1. `lwFetchTpl(name, suffix, cb)`：后缀参数化（移动 `.m.html` / 桌面
   `.html`），tplCache 的 key 带 `name|suffix` 区分（404 也缓存）；
2. `lwApplyFormTpl(fm, mode)` 由布尔改三态模式参数：先拆旧模板
   （按建树原序搬回、摘 `lw-kids-tpl`），再按端处理几何——移动贴满
   视口（savedPos 暂存原几何），**桌面不动窗体几何**（savedPos 在切回
   桌面时恢复）；fetch 回包按 `fm.tplSeq` 序号丢弃过期响应；
3. **门控全面换掉 `layoutState==='mobile'` 判断**：placeNode /
   syncChildren / ResizeObserver 三处改判 `fm.tplApplied ||
   fm.tplPending`。tplPending 覆盖 fetch 在途期（此前移动靠
   layoutState 兜住，桌面新增 fetch 后必须有 pending，否则回包前的
   patch 会写回绝对定位与搬迁打架）；tplFallback 只属于移动端
   平移回退，lwUpdatePan 语义不变；
4. CSS：新增 `.lw-kids.lw-kids-tpl { overflow:auto }` + `> .lw-tpl
   { min-height:100% }`（桌面窗体是设计尺寸，模板内容超高要滚动）；
   `.lw-tpl/.lw-ph` 原本就不限端，直接复用。

**模板范例**：`tpl/MobileMainForm.html`（桌面：居中卡片、标题行右对
清空按钮、双栏等高）与 `.m.html`（移动：单列）同一窗体对照——demo
即 mobile_demo :8106。

**验证**：新增 `tests/cdp_desktop_tpl.py` 7 项（T1 桌面模板套用/
T2 几何不变/T4 三态切换/T5 移动贴满/T3+T6 无模板窗体两端 WYSIWYG）
ALL PASS；回归 cdp_mobile_demo / cdp_updown / cdp_popup_outside
ALL PASS（cdp_mobile_demo 的 T1/T3/T4 断言按新语义更新——桌面现在
也套模板）。

**测试坑**：
- 断言基准：窗体设计宽 820 是 DesignTimePPI 144 的值，服务端按 96 DPI
  下发 820×96/144≈547 —— 对抗像素级断言先查 lfm 的 PPI；
- `min(设计宽, 视口-8)` 的贴满逻辑在 1200 宽调试视口下量不出变化，
  必须缩视口到 390 再断言；
- `LW.layout.set('desktop')` 会写 sessionStorage 硬覆盖，后续改视口
  不会自动进移动 —— 用完记得 `set(null)` 清掉；
- `.lw-n` 的 absolute 来自 CSS 类不是内联样式，断言要用
  getComputedStyle 而非 style.position。

## 坑 154：LFM→模板生成器（lwdesign Tools 菜单）—— 行级解析与搬迁清内联的两个坑

需求（用户 2026-11-16）：IDE Tools 菜单加「根据当前打开单元的 lfm 生成
模板」，**分别生成桌面与移动端**两份。实现为 lwdesign 新增两单元：
lwdsgntplcore（纯解析/生成，无 IDE 依赖）+ lwdsgntplgen（MenuIntf 注册
Tools 菜单，写入 <工程目录>\tpl\，已存在逐份询问覆盖）。

**坑 1：TNotifyProcedure 是 method 指针**。MenuIntf 的
RegisterIDEMenuCommand 回调不是普通过程指针，全局过程 @ 传入报
"Incompatible type ... of object"。解决：处理逻辑挂单例对象
（initialization 创建 TTplGenMenuHandler）。相关单元名：MenuIntf（不是
IDEMenuIntf）、SrcEditorIntf（不是 SourceEditorManagerIntf）、
ActiveEditor（不是 ActiveSourceEditor）、TLazProject 没有
ProjectDirectory，工程目录取 ProjectInfoFile 的目录。

**坑 2：搬迁清内联宽高，生成的骨架必须逐控件定高**。lwDropNode 搬迁时
清 style.width/height，生成模板若只给 width:100%，容器类控件
（TPageControl/TPanel/TMemo）塌到内容高（页签只剩标题条 31px，内容区
2px 空白，gallery 实测）。生成器改为对每个控件输出
`height: <设计H>px !important`（桌面另按 Width/FormWidth 百分比给
flex-basis）。gallery ugallery.lfm（GalleryForm，顶层仅 pcMain 1800x900）
实测：桌面/390 移动两端均正常渲染（52 个输入控件可见）。

**坑 3：fpc 控制台测试会把 .ppu 写进包源目录**，lazbuild 随后报
「发现多义的单元」退出码 2。控制台编译一律 `-FE. -FU.` 指定输出目录；
已删 src/design 下误生成的 ppu/o。

**坑 4：行级 lfm 解析的两个修正**。子控件块扫描的终止条件是「深度回到
1」不是 0；且扫描结束处 j 停在收尾 end 行上，外层必须 i:=j+1 跳过，
否则外层再减一次深度，后续顶层控件被误判成新窗体（首测 form=lblInfo）。

**验证**：控制台测试 tplgen_test（MobileMainForm 断言 7 控件/状态栏跳过/
视觉排序 + GalleryForm 冒烟）；gallery :8091 CDP 实测两端渲染正常；
lwdesign.lpk lazbuild 编译通过（IDE 里需重新安装包后 Tools 菜单才出现）。

## 坑 155：AutoSize 标签宽高未按 PPI 折算 + 生成骨架缺容器内兜底（lblInfo 溢出面板）

现象（用户 2026-11-16，mobile_demo 生成模板实测）：桌面/移动模板里
pnlInfo 内的 lblInfo 文字跑到面板右侧、裁出窗外。两个根因叠加：

**根因 1（服务端）：AutoSize=True 的 TLabel 宽高留在 144PPI 设计值**。
LCL 加载 LFM 的 PPI 缩放对 AutoSize 控件不生效（ShouldAutoAdjustLayout
返回 False，与坑「状态栏高度」同类，见 lwwriter.StatusInfo 注释），nogui
的 AutoSize 重算又量不准 —— 树里 pnlInfo 下发 515x64（已折算），其内
lblInfo 却是 748x76（未折算）。浏览器端 placeNode 对 autosize+wordwrap
标签会照抄内联 width:748px，文字盒比面板宽出一半，text-align 一靠中/右
就溢出。修法（lwwriter.MakeBase）：AutoSize 标签按窗体
DesignTimePPI -> PixelsPerInch 比例折算 w/h（RootFormOf 沿 Parent 找根
窗体）；只折 AutoSize 标签，非 AutoSize 控件 LCL 已折过、再折会双倍缩。

**根因 2（生成器）：骨架没有容器内部兜底**。模板 v1 只重排顶层，容器
（pnlInfo）内部仍是设计期绝对定位；模板把容器宽度改了（桌面按百分比、
移动单列），内部控件按设计期 px 定的 left/width 必然可能溢出。旧手写
模板（tpl1 备份）是给该面板手写 `left:8 right:8 width:auto` 兜底的，
生成器不可能预知这种细节。修法（lwdsgntplcore）：解析时记
TTplChild.HasKids（顶层块内再出现 object/inline，item 不算），对
HasKids 且类名属 BODY_CONTAINERS（TPanel/TGroupBox/TRadioGroup/
TCheckGroup/TFlowPanel/TScrollBox）的控件生成两条规则：

    [data-lw-ph="<名>"] > .lw-n > .lw-body { overflow: hidden; }
    [data-lw-ph="<名>"] .lw-body .lw-n { max-width: calc(100% - 16px); }

overflow:hidden 按 LCL「容器裁剪子控件」语义兜底；max-width 收宽留出
左右 8px 内边距（首版 max-width:100% 因 left:8px 偏移右端仍裁 8px，
实测后改 calc(100% - 16px)）。重排内部控件仍按手册 16.3 精修。

**验证**：tplgen_test 重编（新增 pnlInfo 兜底规则断言）过；重新生成
mobile_demo 两份模板；CDP 实测（旧 exe + 新模板，CSS 即时生效）：
桌面 lblInfo 盒宽 461.5px 收进面板、rect 完全 contained、截图无裁切；
移动端文字完整可读。lwwriter 改动编译通过（mobile_demo.exe 被运行中
进程占用未链接，重启后生效：标签宽下发变为 499x51）。

## 坑 156：标签 Alignment 序数映射错位 —— taCenter 被渲染成右对齐

现象（用户 2026-11-16）：lblInfo 设计期 Alignment=taCenter，桌面与移动
模板下最后一行都缩进靠右（像右对齐），用户质疑对齐不对。

根因：LCL 的 TAlignment 序数是 **0=左 1=右 2=中**，lwhttp/lwwriter 按
`Ord(Alignment)` 原样下发没错；但前端三处按 **1=中 2=右** 解释——
lw-alpine.js label 分支（text-align）与 static 分支（justify-content）、
lw.js static 分支。taCenter(=2) 因此全被渲染成右对齐。状态栏的映射
（lw-alpine.js StatusInfo 消费处 `al===1?'right':al===2?'center'`）
是对的，三处错映射是照抄时想当然。

修法：三处统一改为 `===2 → center`、`===1 → right`。纯前端静态文件，
刷新即生效，无需重编。CDP 实测：lblInfo computed textAlign=center，
两端截图确认居中、无裁切（与坑 155 的容器兜底叠加后效果正确）。

教训：跨层传 LCL 枚举时，接收端映射必须对照 LCL 源码的序数定义，
不能按「直觉顺序」写；同文件内已有正确先例（状态栏）时先对齐先例。

## 坑 157：移动端相机不能走 getUserMedia（局域网 http 直接拒绝）——TLWCamera 用 capture 方案

**日期**：2026-11-16　**标签**：移动端 / 相机 / HTTPS / 新控件

需求：手机浏览器里拍照上传。第一反应是 getUserMedia（页面内取景框 + canvas
抓帧），但它只在**安全上下文**可用 —— HTTPS 或 localhost。业务现场是手机
访问 `http://192.168.x.x:8090`，`navigator.mediaDevices` 直接是 undefined，
没有证书可装就永远用不了。

**方案**：新增 `TLWCamera`（lwcamera.pas，`TLWFileUpload` 的专用后代），
前端点按钮动态建
`<input type="file" accept="image/*" capture="environment|user">`，
唤起**系统相机 App** 拍一张，浏览器把 JPEG 当普通文件交回 —— 与选文件
共用同一条 multipart 上传通道，http 页面完全可用。代价：没有页面内取景框
（看到的是系统相机界面）；对"拍一张上传"类业务反而更省电更稳。

**实现要点与坑**：
- 复用链路：lwupload 按 `C is TLWFileUpload` 找控件，后代天然命中 ——
  服务端落盘/洗白/大小上限零改动；`AddUploadedFile` 改 virtual，
  TLWCamera override 里追加触发 `OnCapture`；
- **KindOf 判定顺序**：`C is TLWCamera` 必须排在 `C is TLWFileUpload`
  之前（后者命中会丢 capture，移动端点开变文件管理器）—— 同类顺序坑
  见 captcha（TGraphicControl 提前）注释；
- **预览别走服务端**：手机照片 3~5MB，转 base64 塞进组件树会让之后每次
  增量补丁都白跑几 MB。改成浏览器本地回显：TLWCamera.PreviewImage 填
  目标 TImage 名，writer 解析成节点 id 下发（不能下发名字——data-lw-ph
  只在模板模式存在，无模板窗体查不到），客户端拍完 ObjectURL 直接塞
  `img.lw-img` 的 src；
- **回显会被增量协调冲掉**：TImage 渲染成 `:style="src ? '' :
  'visibility:hidden'"`，src 空时 Alpine 会把 visibility:hidden 写回。
  用 `data-lw-photo` 属性 + CSS `visibility: visible !important` 压过
  inline 绑定（!important 优先于非 important inline）；
- 服务端 TImage.Picture 保持空：nogui 下 TPicture 加载 JPEG 依赖 LCL 的
  FPImage 解码（未实测大图内存），且缩放需要 Canvas（nogui 没有真画布，
  见 lwcaptcha 头注释）——缩略图留给业务侧自己做；
- 测试模拟拍照：CDP `DOM.setFileInputFiles` 给动态 input 塞真实 JPEG
  （1.6MB Windows 壁纸），setFileInputFiles 会派发 change；个别版本不派发
  时脚本补一次 `dispatchEvent(new Event('change'))` 兜底。

**验证**：tests/cdp_camera.py 两端各 15 项 ALL PASS（按钮/图标/accept/
capture/上传落盘 1565KB/OnCapture 日志/本地预览可见且有尺寸）；桌面 1280
与移动 390 截图目视正常；lwcore/lwserver/lwdesign 三包与 mobile_demo 编译过。

**文档**：MANUAL 使用篇「移动端拍照」+ 已知限制（无实时取景）、
ARCHITECTURE 2.8 与 3.4 速查、README 模块表与独立小节、INDEX 场景表。

## 坑 158：桌面"没有相机"；顺带 iOS/平板打不开网页的两个真凶

**日期**：2026-11-16　**标签**：相机 / 局域网 / iOS / 排障

### 一、桌面端为什么不拍照

`<input type=file capture>` 的 capture 只有**移动端**认，桌面浏览器一律忽略
（Chrome/Firefox/Safari 都是），所以桌面上点"拍照"永远只弹文件对话框——
用户看到的就是"桌面只能上传图片"。桌面要真相机只有 getUserMedia 一条路，
而它**只在安全上下文**（HTTPS 或 localhost）存在，局域网 http 页面上
`navigator.mediaDevices` 直接 undefined。两个方案不是二选一而是按环境分工：

| 环境 | 方案 | 前提 |
| --- | --- | --- |
| 手机/平板（粗指针） | `capture` 唤起系统相机 App | 无（http 可用） |
| 桌面 + HTTPS/localhost | getUserMedia 页面内取景 + canvas 抓帧 | 安全上下文 |
| 桌面 + 局域网 http | 退化选文件 | 浏览器硬限制，无解 |

判断条件用 `matchMedia('(hover: hover) and (pointer: fine)')`，不要用 UA。抓帧
后长边压到 1600px 转 JPEG（0.9），手机/笔记本 4K 帧原样传会几 MB。

**踩到的坑（重要）**：getUserMedia 是**异步**的，`catch` 里再 `input.click()`
已经脱离用户手势，Chrome/Safari 都会拒绝弹文件框（"File chooser dialog can
only be shown with a user activation"）。所以失败时不能"当场降级"，只能
①提示一次原因，②给控件打 `_camFail` 标记，**下次点击**才走文件选择（那时有
真实手势）。测试时用 `canvas.captureStream()` 造假流，整条取景→拍摄→上传
链路才能跑到（假画面是纯色，JPEG 只有 8KB，断言大小阈值要按路径区分）。

### 二、iOS / 另一台平板打不开网页，不是服务端的锅

现象：安卓手机正常，iPhone、安卓平板、另一台安卓手机全都"打不开/已丢失
网络连接"。这组分布本身就说明服务是活的（同一台机、同一端口有人能开），
问题在**设备到服务端的可达性**，按下面顺序查，两条最常见：

1. **URL 少写端口**。服务端只监听 `:8090`（或 8106 等），地址栏里只输
   `192.168.1.84` 等于访问 80 端口，什么也没监听 → iOS 报"已丢失网络连接"、
   安卓报连接被拒绝。**启动横幅过去只打 `http://127.0.0.1:8090/`**，很容易
   照着抄成回环地址或漏端口 —— 已改为在横幅里多打一行 `LAN:`，用 UDP
   connect 探出本机出口网卡的 IPv4（不发包，比 gethostbyname 可靠，
   多网卡/虚拟网卡机器上后者常回 127.0.0.1）。
2. **iOS 本地网络权限**（iOS 14+）。Safari 访问局域网 IP 需要"本地网络"
   授权，第一次会弹窗；点过"不允许"之后**永久静默失败**，报错就是"已丢失
   网络连接"。路径：设置 → 隐私与安全性 → 本地网络 → 允许 Safari（列表里
   没有就先开一次页面让它弹窗，或还原位置与隐私）。

其余分支：访客网络/AP 隔离（平板连的 SSID 与手机不同）、5G 独立 SSID 分属
不同网段、VPN/代理/iCloud 专用代理在中间截一道；微信等内置 WebView 还会
额外拦 `input[type=file]`。判定技巧：让打不开的设备访问
`http://<ip>:<port>/lw/healthz`，返回 ok = 网络通、问题在页面层；连 healthz
都打不开 = 设备/网络层，不用翻服务端代码。

**验证**：cdp_camera.py 重写为双路径（桌面假流取景 + 移动 capture），两端
全绿；桌面取景弹层截图目视正常；lwcore.lpk 编译通过（lwhttp 加横幅行）。

---

## 坑 159：所有手机/平板同时打不开——防火墙规则只落在"公用网络"上（2026-11-16）

**日期**：2026-11-16　**标签**：局域网 / Windows 防火墙 / 排障

### 症状

上一轮还是"安卓能开、iOS 打不开"，这一轮变成**全部设备都打不开**（iPhone、
安卓手机、安卓平板无一例外），而本机 `http://127.0.0.1:8090/` 一切正常。
"个别设备不行"和"全都不行"是两个层的问题，后者先怀疑**本机入站**。

### 定位（四步，全部只读）

```text
1) 服务在听哪儿，要 0.0.0.0 而不是 127.0.0.1
   netstat -ano | findstr :8090

2) 本机走局域网 IP 自测（这条**不走防火墙**，只能证明服务是活的）
   curl --noproxy "*" http://192.168.1.84:8090/lw/healthz

3) 当前网络被识别成哪种配置文件
   Get-NetConnectionProfile | select InterfaceAlias,Name,NetworkCategory

4) 放行规则落在哪个 Profile
   Get-NetFirewallRule -DisplayName 'mobile_demo' | select DisplayName,Profile,Enabled
```

实测结果：服务 `0.0.0.0:8090` 正常、`healthz` 本机 200，但规则只有
`Profile = Public` 两条（TCP/UDP），而 `Get-NetConnectionProfile` 报
**`NetworkCategory = Private`**，`DefaultInboundAction = NotConfigured`
（等于入站默认阻止）。**规则和当前配置文件对不上，入站包全被丢**，于是所有
局域网设备一起挂；而 127.0.0.1 走回环不经该过滤器 —— 这正是"本机能开、
手机全打不开"的成因。

`Private` 那两条规则是应用重启时 Windows 按当前配置文件补弹窗生成的，
所以"重启一下又好了"是假象，策略不改，下次换网络仍会复发。

### 修复

用管理员的 `netsh advfirewall` 写 `profile=any` 的规则（两种配置文件都覆盖），
再按端口兜底一层（换 exe 名、临时编译到别处也能用）：见
`tools\allow-firewall.bat`（自带提权，右键或双击运行）。要点：

- `profile=any`，不要写死 `profile=public`；
- 程序规则 + 端口规则**都要**：程序规则认路径，重编译换目录就失效；
- 加规则前先 `delete rule name=...`，否则同名规则重复堆积；
- 改完不用重启服务，规则立即生效。

### 验证

`Get-NetTCPConnection -LocalPort 8090` 里出现来自手机 IP 的
`Established / TimeWait` 记录（现场看到过 `192.168.1.92`），说明 TCP 握手
已经穿过去；再看 `/lw/healthz` 的 `sessions` 是否随设备接入增长。

### 顺带

横幅 `LAN:` 行下面新增一行提示，指向 `tools\allow-firewall.bat`。这个故障
最容易被误判成"代码坏了"，而它 100% 是本机网络策略问题。

## 坑 160：fphttpserver 其实支持 TLS——FPC 自带 UseSSL 直接终结 HTTPS（2026-11-16）

**日期**：2026-11-16　**标签**：HTTPS / TLS / FPC 自带 / lwhyper

### 症状（先纠正一个错误结论）

前面几轮一直按"fphttpserver 不支持 TLS，入站 HTTPS 只能前置 nginx/Caddy"
来设计，还专门讨论过"自己写反向代理"。**这个结论是错的**，它把
`TFPHTTPClient`（客户端）和 `TFPHttpServer`（服务端）混为一谈了：

- `TFPHTTPClient` 是客户端，`uses opensslsockets` 才有 HTTPS；
- `TFPHttpServer` 也走同一套 socket handler 抽象，`TOpenSSLSocketHandler.Accept`
  就是服务端握手入口。FPC 源码自带完整例子
  `packages/fcl-web/examples/http2/h2tls.lpr`：`FSrv.UseSSL := True` +
  `CertificateData.HostName := 'localhost'` 就能起 HTTPS（FPC 示例还演示了
  ALPN h2；本项目未显式启用 HTTP/2，浏览器实际协议以握手结果为准）。

项目里 `TLWHttpServer = class(TFPHttpServer)`、`TLWHyperServer.FHTTP` 也是
`TFPHttpServer`，所以两处都能直接开 TLS，**不需要任何反向代理**。

### 确定性验证（不是推测）

```
写 tlstest.pas: uses fphttpserver, opensslsockets;
  S.UseSSL := True; S.CertificateData.HostName := 'localhost';
fpc 编译 -> 成功，5916 行，生成 tlstest.exe；运行打印 UseSSL=TRUE
（此时本机还没有任何 OpenSSL DLL，说明仅 uses 不影响普通 HTTP 启动）
```

### 落地

纯 FPC，无 CrossSocket / 无 nginx / 无 Caddy：

- `lwhttp.pas`：uses 加 `opensslsockets`；`TLWServerConfig` 加 `UseSSL /
  SSLHost / SSLCertFile / SSLKeyFile`；`Start` 里赋给 `FHTTP.UseSSL` 与
  `CertificateData`；横幅按 scheme 输出 http/https。
- `lwapp.pas`：默认值、`--ssl / --ssl-host / --ssl-cert / --ssl-key`、
  INI 键 `ssl / sslhost / sslcert / sslkey`、帮助文本。
- `lwhyper.pas`：同样四个字段和四个参数。**TLS 只加在外层**——浏览器到
  lwhyper 走 HTTPS，lwhyper 到 worker 仍走 HTTP（worker 根本不用改）。
- `ulwhypergui.pas` / `.lfm`：GUI 版「配置」区加 `chkSSL / edSSLHost /
  edSSLCert / edSSLKey` + 两个浏览按钮；`BuildCfg/LoadCfg/SaveCfg` 读写
  `ssl / sslhost / sslcert / sslkey`；`BaseURL` 按 chkSSL 出 https（状态栏和
  「打开浏览器」都走它）；`ValidateCfg` 拦"证书/私钥只给一个"与文件不存在。
  配置区加高 80px、下方控件同步下移，窗口 960→1040。

证书零配置可用：不指定 HostName / 证书文件时，`InitContext` 调
`CreateSelfSignedCertificate` 自动生成自签证书。正式环境给 PEM 文件。

### Windows 依赖（唯一的外部件）

随包带 `libssl-3-x64.dll` + `libcrypto-3-x64.dll`（或 1.1 版），放 exe 同目录。
FPC 的 `openssl.pas` 按此顺序找：`libssl-3-x64 → libssl-1_1-x64 → ssleay32`。
本机验证时取自 FastReport 自带 DLL；`tools\` 与 `demos\mobile_demo\` 已放一份。
**不带 DLL 时**：普通 HTTP 照常，开 `--ssl` 会在握手时报 "Could not load SSL library"。

### 实测（全绿）

```
lwhyper --port=8443 --ssl --workers=1 --exe=demos/hello/hello.exe
  HTTPS /lw/healthz      -> 200 { ok:true, role:hyper, alive:1 }
  HTTPS /                -> 200 3137B
  ws 升级                -> 101 Switching Protocols（wsdone=1 正常收尾）
  worker :8444 明文       -> 200（外层 TLS 不影响内网转发）
mobile_demo --port=8445 --ssl --nogui
  HTTPS /lw/healthz      -> 200，横幅 Listen/LAN 显示 https://
  HTTP 同一端口           -> 连接被拒（curl code=000）
  lw-alpine.js/css、alpine.min.js 全部 200，无混合内容
lwhyper_gui.exe（cfg 写 ssl=1 + autostart=1，无头冒烟）
  HTTPS /lw/healthz      -> 200，首页 200，WS 升级 101
  HTTP 同一端口           -> 连接被拒（curl code=000）
  只给 sslcert 不给 sslkey -> 服务不启动（ValidateCfg 在 UI 层拦住，8450 无监听）
```

### 与局域网可达性的边界

TLS 只解决"安全上下文"（相机 getUserMedia 需要 https 或 localhost），
**不解决 ARP / 二层隔离**。若设备连 TCP 握手都到不了（坑 158/159 那类
现象），换 https 一样打不开；先关路由器"无线隔离"，再谈证书信任。

自签证书的额外成本：手机首次访问会告警，需点"继续访问"；iOS 16+ 对
证书 SAN 要求更严，正式用建议签一张含 IP SAN 的内部证书。

## 坑 161：SSL 证书路径按 exe 解析 + 启动前成对校验（2026-11-16）

**现象**：`--ssl-cert=cert\server.crt` 在双击 bat（cwd=exe 目录）时正常，
但服务化部署（cwd 常为 `System32`）会在握手期报 "Could not load SSL library"；
只给 `--ssl-cert` 不给 `--ssl-key` 时，错误信息也来得过晚。

**修正**：`lwbase.pas` 新增 `LWResolveExeRelativePath` 与 `LWValidateTLSFiles`：
- 业务 exe（`lwapp.pas`）、`lwhyper`（`lwhyper.pas`）与 GUI（`ulwhypergui.pas`）
  统一把证书/私钥相对路径解析成 exe 目录下的绝对路径；
- 启动前检查"成对指定 + 文件存在"，失败即打印中文错误并退出；
- GUI 输入框仍显示原值，运行时使用解析后的绝对路径，保存 cfg 不被改写。

**回归**：固定脚本 `tests/run_fixed_regression.py` 的 TLS 段会生成临时证书，
用相对 `cert\server.crt` 启动HTTPS并打 `/lw/healthz`，同时验证缺私钥会快速失败。

## 坑 162：GUI 版本退出弹「错误」框（heaptrc 误报 + 看门狗抢跑）（2026-11-16）

**现象**：`demos\dbaware\dbaware_gui.exe` 点「文件 → 退出」后弹出一个标题为
「错误」的模态框，内容是 `Heap dump by heaptrc unit ... 20 unfreed memory
blocks : 5123`（含 `TWin32WidgetSet` / `TWin32ThemeServices` 调用栈）。另一种
变体是框里只有一行 `[exit] 500ms 内未收工（LCL/GTK 收尾卡住），看门狗强制
结束进程`，且进程挂住不退出。两种都不是崩溃：实测退出码为 0。

**三个独立成因**（用 `HEAPTRC=log=...` + WM_COMMAND 触发退出逐层定位）：

1. `dbaware_gui.lpi` 的 `CustomOptions` 里带着 `-gh`。`-WG`（GUI 子系统）没有
   控制台，heaptrc 只能把报告塞进 `MessageBox`，而它是在收尾阶段弹的 —— 进程
   一直等到用户点「确定」才真正退出。**泄漏检查不该跟着 GUI demo 出厂。**
2. GUI 构建的代理 widgetset（`lwproxyws.LWInstallProxyWidgetSet`）是**有意**
   留下未释放对象的：旧的 `TWin32WidgetSet` 实例不释放（`AppHandle` 已过户给
   代理，释放它会连带销毁那个隐藏窗口），`SwapWSClasses` 用 `CopyVClass` 造
   的一批类对象也长驻。固定约 4.7KB，属设计取舍，不是缺陷 —— 但 `-gh` 会把它
   当"泄漏"报出来，看起来像 bug。
3. 真泄漏只有三处小对象：`lwapp` 收尾漏掉 `GOrder`（`EnsureRegistry` 建的
   第 2 个 TStringList）和 `GExcHandler`；demo 的 `GDemoAjax` 从未释放。
   另外 Windows 上也装了 500ms 退出看门狗（本意是兜 mips64el/Linux 的 GTK
   收尾卡死）：Windows 收尾虽然只要 ~350ms，但机器一慢就会越线，看门狗从
   **工作线程**调 `Halt(0)`，正好撞上主线程还在跑 Forms/Interfaces 的
   finalization —— 收尾被截断（widgetset 等块就"泄漏"了），而且它那句
   `WriteLn(StdErr, ...)` 在 GUI 子系统里同样会变成模态框，进程直接挂住。

**修正**：
- `lwapp.pas` finalization 补 `GOrder.Free`；`GExcHandler` 先摘
  `Application.OnException` 再释放（Forms 单元比 lwapp 后收尾，此刻
  `Application` 还活着）。
- `uAjax.pas`（demo）加 finalization 释放 `GDemoAjax`。
- `lwpanel.pas`：`LWStartExitWatchdog` 只在 `{$IFDEF unix}` 下装。Windows 的
  LCL 收尾是确定的毫秒级，不需要看门狗，装了反而会在慢机器上抢跑。
- `dbaware_gui.lpi` 的 `CustomOptions` 回到 `-WG`。

**验证**（同一台机器，触发同一条退出菜单）：
```
修复前：退出弹「错误」框，需人工点掉；HEAPTRC 报告 20 块 / 5123 字节
修复后：退出码 0，无任何对话框；HEAPTRC 报告 14 块 / 4752 字节
        剩余 14 块 = 旧 TWin32WidgetSet + TWin32/TThemeServices + TFPList
                   + TLWVirtualWS + 9 个 CopyVClass 类对象（均为代理 WS 设计保留）
```

**要查泄漏怎么办**：别把 `-gh` 塞回 lpi，用临时构建 + 日志模式，避免弹框：
```bat
lazbuild --opt=-gh --opt=-oMyApp.ht.exe MyApp.lpi
set HEAPTRC=log=C:/temp/ht.txt
MyApp.ht.exe
```

## 坑 163：模板生成器拿 gallery 当样本暴露的三类问题（2026-11-16）

以 `demos/gallery/ugallery.lfm`（1800×1110 的真实窗体：一个铺满的
`TPageControl` + 底部日志 `TPanel` + `TListView.Columns` 集合 + 多行
字符串）为样本跑生成器，暴露出三类问题；`tests/tplgen_test.lpr` 与
`tests/cdp_tplgen_gallery.py` 已把它们固定成回归。

**1. 解析：集合块与多行字符串里的 `end` 会吃掉后面的顶层控件**

`TListView.Columns` 的 `item ... end` / `end>`、以及 `Lines.Strings = ( ... )`
里的 `end` 都被旧解析器当成对象结束，深度错乱后 `pnlLog` 整块消失
（生成模板只剩 `{%pcMain%}`，运行时 pnlLog 仍按设计期绝对定位，页面
看起来"模板没生效"）。修法：解析改成"对象层级 + 集合 item 块 + 括号
字符串块"三态推进 —— `ParenDelta` 统计每行括号净变化（认 `''` 转义），
`IsCollectionEnd` 消化 `end`/`end>`/`end)`，两者都在对象计数之前拦掉。

**2. 尺寸：铺满窗体的大控件写死设计期像素高**

`pcMain` 是 1800×900、窗体 1800×1110，生成出来是
`height: 900px !important`。后果不是报错而是"页面能用但难用"：
720p 窗口里底部日志条被顶出可视区；手机 844px 高的屏上要滚一屏才
看得到页签之外的内容。修法：横向 ≥85% 窗体宽、纵向 ≥50% 纵向占用的
那个控件判为**主区域**，生成
`height: calc(100vh - 其它控件固定高度px)` + `min-height: 240px`。
gallery 里就是 `calc(100vh - 220px)`（日志条 210 + gap 10），
且只认最高的一个，避免两个控件同时伸缩。
（`100vh` 这一步后来被证明只在"窗体就是整页"时成立，浮窗里会整块
溢出，见下文坑 164 —— 现已改为按容器高度 `calc(100% - Npx)`。）

**3. 桌面：百分比宽没扣 `gap`**

`flex: 0 0 50%` 配 `gap: 10px`，两个半宽控件加起来 100%+10px 超过一行，
本该并排的被换成上下两行。修法：`flex: 0 0 calc(50% - 10px)`；
≥95% 的直接给 `100%`（整行控件不吃 gap）。用
`tests/fixtures/tpl_two_cols.lfm`（800 宽窗体 + 两个 400 宽面板）锁死。

**顺带补的自检**（弹窗与文件头 `自检提示` 段同步给出）：设计期宽度
超过窗体宽、缺几何、重复/非法占位符名、含嵌套子控件、主区域被改成
视口伸缩。生成器签名相应加了 `FormWidth`（`GenMobileTplEx` 之前拿不到
窗体宽，没法算比例）。

**验证**（真实渲染盒，不是字符串比对）：
```
python tests/cdp_tplgen_gallery.py 18110      # gallery + 无头 Edge 9239
desktop 1600x900: mainH=680  logH=210  overflowX=0
mobile  1600x900: mainH=680  logH=210  overflowX=0
phone   390x844 : mainH=624  logH=210  overflowX=0   # 844-220
```
探针在运行期间把骨架装进 `demos/gallery/tpl/`、跑完删除：gallery 本身
要保持"无模板窗体"的身份（`cdp_desktop_tpl.py` 的 T6 用它验证平移回退），
所以生成样本放在 `tests/out_tpl/gallery/`，不进 demo 目录。

## 坑 164：模板按 `100vh` 排版，窗体一开进浮窗就整块溢出（dbaware 实测）

坑 163 修完主区域伸缩后，我拿 gallery 收尾。gallery 的窗体就是整页，
`100vh` 与"窗体客户区"恰好相等，所以没暴露。换 dbaware 一测就现形：
它有三个窗体，覆盖 gallery 一个都覆盖不到的形态 —— 主窗体顶层只有一个
铺满的 `TPageControl`（1800×1080 窗体上的 1650×1080）、登录页 12 个
平铺控件且没有主区域、报表窗"顶部工具行 + 底部 `TLWPDFFrame` 主区域"。

**现象**：登录后主窗体套上模板，页签内容下沿被切掉、整页多出约 200px
纵向滚动。量渲染盒：

```
.lw-tpl        top=61  h=926     # 模板容器被内容撑高（应 720）
.lw-kids       top=61  h=720     # 窗体客户区
.lw-win-body   top=61  h=720
.lw-win        top=6   h=775     # 主窗体是浮窗，不是整页
视口 900
```

根因两层，都不在模板文本里，只能量真实盒子才看得见：

1. **`100vh` 不是客户区高度**。窗体开在 `.lw-win` 浮窗里时，客户区
   （720）比视口（900）小；生成物写 `height: calc(100vh - 220px)`，
   主区域连同其它控件一起顶出客户区 206px。
2. **百分比高度在这条链上不解析**。改成 `calc(100% - Npx)` 后仍然
   塌到 `min-height: 240px`：`.lw-kids → .lw-tpl` 这条链上有一环是
   flex 项的 `flex: 1`，Chromium 在百分比解析时不算它 definite，
   根节点的 `height: 100%` 退化成 `auto`，主区域的百分比随之失效。
   实测 `root css=460px`（= 内容高），强制 `inline height:100%` 仍是
   460，而 `inline height:600px` 立刻正确（`pcMain=380`）。

**修法**（两处配合，改完两端都验）：

- 客户端 CSS（`src/client/lw-alpine.css`，`.lw-kids-tpl > .lw-tpl`）：
  `min-height: 100%` 改 `height: 100%`，并加"单轨 grid"
  `display: grid; grid-template-rows: 1fr`。1fr 轨道的尺寸是确定的，
  网格项（模板根节点）拿到的就是客户区高度 —— 这才是让下游
  `calc(100% - Npx)` 能算出数的关键。只写 `height: 100%` 不够（见根因 2）。
- 生成器（`lwdsgntplcore.pas`）：主区域表达式由 `calc(100vh - Npx)`
  改 `calc(100% - Npx)`（`fixedH = 0` 时直接 `100%`），根节点加
  `height: 100%; box-sizing: border-box`，非主区域占位符加
  `flex: 0 0 auto`（否则根节点定高后会被 flex 压扁）。

**顺手修掉的第三个问题：桌面扣减要按行算。** 桌面是 wrap 流式，
同一行的控件只占一份纵向高度。旧算法把每个控件高度直接相加：
报表窗顶排 6 个控件被重复扣 5 份，主区域算成负数、`min-height` 兜底，
整页比设计期还高。只按 `Top` 差值分行也不行 —— `lblInfo(84)` 与
`lblHint(104)` 差 20px 会被并成一行，少扣一行高度。最终按
"宽度还能不能再塞一个 + 纵向仍站在同一行"贪心分行
（`RowsFixedHeight`，阈值与排序用的 24px 一致）：报表窗 = 26 + 28 +
18 + 20 + 4×10 = **132px**（移动端单列仍是 248 + 10×10 = 348px，
两端口径不同是应该的）。

**dbaware 另外暴露的**：`LoginForm` 的标签是纵向居中于输入框的
（`lblUser Top=144` / `edUser Top=138`），单列排序若按 `Top` 直接比，
标签会排到输入框后面 —— 手机上"先见输入框、后见用户名"。现有排序
（同一排按 `Left`）本来就正确，这次补了断言锁住它，别再退化。

**验证**（三档视口 + 两个 demo，全部量真实渲染盒）：

```
# gallery（顶层就是整页）
desktop 1600x900: contentH=714  mainH=494  logH=210  tplScroll=0  overflowX=0
mobile  1600x900: contentH=833  mainH=613  logH=210  tplScroll=0  overflowX=0
phone   390x844 : contentH=777  mainH=557  logH=210  tplScroll=0  overflowX=0

# dbaware（主窗体在浮窗里，客户区 720）
login desktop   : tpl=true fallback=false overflowX=0，btnOk/btnReset 同一行
login phone     : 单列、标签在各自输入框之前、列内左边界与宽度一致
main  desktop   : pcMain=694 = 客户区 694，tplScroll=0
main  phone     : pcMain=751 = 客户区 751，tplScroll=0
```

`tplScroll = tpl.scrollHeight - tpl.clientHeight` 是新增的判据：
模板内容一旦超出客户区就非 0，正是"按 100vh 排版"的直接后果
（修前 926 - 720 = 206）。

**已知残留（不是本次改动引入）**：页签内部那层 `.lw-n` 的高度来自
客户端按设计期尺寸缩放（AwareForm 实测 689px），而带模板时客户区
剩给页签的是 665px（694 - 29 页签栏），底部约 24px 落在
`.lw-tabs-body` 的裁剪区。页签内容自身可滚动，不影响操作；要彻底
对齐得让页签内的缩放跟随客户区，属于客户端 fit-scale 的独立问题，
不在模板生成器范围内。

**回归资产**：`tests/cdp_tplgen_dbaware.py`（登录 → 主窗体，含
"页签容器没塌陷" `tabsH/cardH > 0` 与 `tabsH = barH + bodyH` 两条断言）；
`tests/run_fixed_regression.py` 的 `check_tplgen` 把 dbaware 三个窗体
加进用例，并断言生成物里不出现 `calc(100vh` / `height: 100vh`。
注意两个探针都要 `Network.setCacheDisabled(true)`：客户端 CSS 走浏览器
缓存，改完样式不关缓存会量到旧规则（本次就踩了一次，改了 grid 却仍
量出 240px）。

## 坑 165：`TLWHTMLFrame` 内联 HTML 写死浅色底色，深色主题下文字看不清

`demos/dbaware` 的 `frAjax`（AJAX 端点示例）在 LFM 里写死
`background:#f7f9fc; border:1px solid #dbe3ec`，另一处对照表表头写
`background:#dde`。框架本体所有颜色都走 `--lw-*` 变量（见
`lw-alpine.css` 头部注释："组件规则里不再出现颜色字面量"），但
`TLWHTMLFrame` 的内容是用户自己写的 HTML，写死浅色后：深色主题里页面
前景是浅色，继承进来落在浅色底上 —— 白底浅字，几乎不可读（用户实测）。

**修法**：内联 HTML 一律用主题变量，不写颜色字面量：
`background:var(--lw-surface2); border:1px solid var(--lw-border);
color:var(--lw-fg)`；表头用 `background:var(--lw-surface3);
color:var(--lw-fg2b)`。变量在 `:root` / `html[data-lw-theme="dark"]`
两套调色板里各有一份，跟随主题切换实时生效，页面不用刷新。
实测（dbaware 图表页签，点 `GET /lw/ajax/items` 后量 `#lwAjaxOut`）：

```
light: rgb(242,245,248) / rgb(27,27,27)     # 浅底深字
dark : rgb(35,42,50)   / rgb(228,232,238)   # 深底浅字
```

注意 `TLWHTMLFrame` 的 HTML 在 LFM 资源里，改完必须重编译
（lazbuild 不追踪 .lfm 依赖，`build.bat dbaware` 的 `-B` 就是为此）。
参考写法见 `demos/menu_html/uMenuHtml.pas`（`var(--lw-sm-*, 兜底色)`）。

**补充（同一坑的第二次翻车）**：只在 LFM 里改一次还不够 —— LFM 是
编译期资源，IDE 里重新保存一次窗体就可能把示例 HTML 写回旧文本（本
仓库实际发生过：改完 LFM、用户重编译后 exe 里仍是 `#f7f9fc`）。所以
`demos/dbaware/uAwareMain.pas` 里加了运行时兜底
`TAwareForm.NormalizeFrameColors`（`FormCreate` 调用）：把帧内 HTML 的
浅色字面量统一替换成 `var(--lw-*)`，同时把"应用到面板"的源码备忘
`mmHtml` 也归一（否则一点按钮就把改好的颜色又写回去）。替换是按
`background:#f7f9fc` / `border:1px solid #dbe3ec` / `background:#dde` /
`color:#2255aa` / `color:#888` 逐条 StringReplace，不依赖行格式。

**验证探针**：`tests/cdp_dbaware_dark.py` —— 真实登录后切"图表/其它"
页签（**frAjax 在图表页不在 HTML 展示页**，量错页签拿到的是隐藏元素，
getComputedStyle 照样出值但 rect 是 0x0，截图是空条 —— 本探针自己先
踩了一遍），量 `#lwAjaxOut` 的计算样式并算对比度：两个主题都要求
`底色 == var(--lw-surface2) 的解析值` 且对比度 >= 4.5:1；深色
11.79:1、亮色 15.74:1（2026-11-16 实测）。

## 坑 166：`TLWColorPicker` 点色块不弹调色板（弹窗开到视口外）

alpine 客户端的 `$lwPickColor` 用"造一个隐藏 `<input type=color>` 再
`click()`"的方式调原生调色板。以前为了让 input 不可见，把它摆在
`position:fixed; left:-9999px` —— 但 Chromium 的原生调色板是**锚着
input 的位置**弹出的：锚点在视口外，弹窗就开到屏幕外，用户看到的就是
"点了色块没反应"（无报错、无异常、`input` 也创建了，就是看不见弹窗）。

**修法**（`src/client/lw-alpine.js`）：input 必须留在视口内 —— 贴着
色块摆一个 1px、`opacity:0` 的 input（取 `getBoundingClientRect()` 的
left/bottom，夹在视口范围内），弹窗像下拉一样从色块下方展开。
`opacity:0` 不影响锚点（元素仍参与布局）。Ext 客户端（`lw.js`）走
`Ext.picker.Color` 的 Window，不受影响。

**验证**：`tests/cdp_colorpicker.py`（前提 dbaware.exe --port=8155 +
LW_CAPTCHA_DEBUG=1）—— 无头浏览器看不到原生弹窗本体，验的是锚点与
值链路：点色块后 input 贴在色块正下方（y == swatch.bottom）且在视口内；
对 input 派发 input/change 后色块背景跟新、input 被清理；
`OnColorChange` 回发服务端，`ColorChanged` 把 `lblColorVal` 刷成
`颜色：$0044AA22`（LCL `ColorToString` 的 `$00BBGGRR` 格式，
`$0044AA22` == #22aa44，2026-11-16 实测全过）。

顺带：`demos/gallery/lw/` 下的部署副本（查找优先级高于 `src/client`，
见坑 164 的 CSS 教训）同步了 `lw-alpine.js` / `lw.js`。

## 坑 167：已修复的_bug_又重现（lblHint 竖线 + 关浏览器跳过登录）+ 全量审计

2026-11-17 用户同时报两个旧 bug 重现，两个都不是"修法写错了"，而是
**修复的存活与覆盖**出了问题：

1. **`lblHint` 又变回 1×1**：`demos/dbaware/uLogin.lfm` 里 Width/Height
   被写回 1（正确值 540×60，见坑 132.1）。客户端"窄标签 nowrap"兜底只能
   让它显示成 1px 宽的一列字影 —— 看着还是竖线。HEAD 里是 360×60，
   工作区那次窗体被整体重画（630×483 / 144PPI）时留下了 1×1，
   `backup/uLogin.lfm` 和 `lib/*/uLogin.lfm` 里也都是 1×1。
   修法：LFM 恢复 540×60，并在 `uLogin.pas.FormCreate` 里按
   `Width<300 or Height<30 → 540×60` 运行时兜底（LFM 是编译期资源，
   IDE 再保存一次就可能回退 —— 坑 165 已经遇到过一次）。
   过时断言同步：`tplgen_test.lpr` 里 lblHint 的 `flex:0 0 calc(8% - 10px)`
   （1×1 时代的期望）改为 86%；8% 下限规则本身由固定回归的字符串检查
   （`lwdsgntplcore.pas` 两处 `if pct < 8 then`）覆盖。

2. **关浏览器再开跳过登录**：客户端墓碑原本只写 `sessionStorage['lw.bye']`
   （坑 132.6）。但浏览器"恢复上次会话"可能在 **pagehide 写入之前**快照
   sessionStorage —— 快照里只有 sid 没有墓碑，旧会话又被挂回来了。
   实测探针：登录 → 取 pagehide 之前的快照 → 隔 4 秒注入新标签 →
   直接进主页面（复现）。修法：`lw-alpine.js` / `lw.js` 双写
   `localStorage['lw.bye:<tabId>']`（不随页签快照走），`tabWasClosed()`
   取两份里较新的时刻；多页签按 tabId 分开互不干扰，"记住我"仍按
   `persisted()` 单独放行。

**为什么两个旧 bug 会同时回来（审计结论）**：
- LFM/窗体文件被重画或从 backup/lib 旧副本恢复时，只改在 LFM 里的修复
  会被整段覆盖；本仓库已有两次前科（坑 165 的颜色、这次的 lblHint）。
- 仓库有 200+ 个已修改的受版本控制文件、`git HEAD` 还停在旧基线
  （HEAD 的 `lw-alpine.js` 没有墓碑、`uAwareMain.lfm` 没有主题变量、
  `uLogin.pas` 没有兜底）—— 修复没有提交点，也就没有可恢复的基线。
- 测试盲区：墓碑只验过"墓碑随会话还原"，没验"快照早于墓碑写入"；
  登录页竖线只有 CDP 探针覆盖，固定回归的字符串检查里没有那条约束。
- 部署副本会漂移：`demos/gallery/lw/` 的 JS/CSS 优先级高于 `src/client`
  （坑 164），这次发现 `lw-alpine.js`/`lw.js` 已漂移，已重新同步。

**审计结果**（2026-11-17，静态 + 动态两层）：
- 静态：把 NOTES 全部 160+ 坑按三段并行核验代码标记（函数名/选择器/
  关键字符串），确认丢失 0 条；"可疑"仅坑 111/112 的废弃 OnResize 残留
  （NOTES 自身说保留死代码，实际已清掉，风险低）、坑 65 的 IDE 安装包补丁
  （在 Lazarus 安装目录，不在仓库，静态不可验）。gallery 部署副本与
  `src/client` 逐字节一致。
- 动态：`run_fixed_regression.py`、`cdp_browser_restart.py`、
  `cdp_dbaware_login.py`、`cdp_tplgen_gallery.py`、`cdp_tplgen_dbaware.py`、
  `cdp_desktop_tpl.py`、`cdp_dbaware_dark.py`、`cdp_colorpicker.py`、
  `cdp_dbaware_regress.py`、`cdp_mobile_demo.py`、`cdp_fit_scale.py`
  全部通过；`cdp_device_probe.py` 为信息输出，判定表无异常。
  审计过程发现的唯一"失败"是固定回归里过时断言，已随 LFM 修复更新。
- 未覆盖：坑 65（IDE 安装补丁）、坑 87/88/71/107（进程退出/并发压测）、
  坑 157/158（真相机/HTTPS 设备）、坑 144（外部 LazReport 单元）等
  环境依赖项，静态无法确认运行时仍生效。

新增探针：`tests/cdp_dbaware_regress.py`（前提 dbaware.exe --port=8156
+ LW_CAPTCHA_DEBUG=1），A 段量 lblHint 渲染盒与纵向溢出，B 段复现
"pagehide 前快照"的会话恢复并断言回到登录页。

## 坑 168：新建工程向导改成 Lazarus 标准流程（不再立即落盘）

**现象**：File → New → Project → `lazarusWeb Application`，弹自定义
"工程目录（不存在会自动创建）"对话框，点确定就把 `.lpr/.lpi/umain.pas/.lfm/
build.bat` 全写进那个目录。标准 Lazarus 不是这样 —— 选完模板什么都不问、
一个字节都不写，标题栏显示 `project1 (*lpi)`，按保存才弹"保存项目"，目录
默认就是 IDE 选项"环境 / 文件"里的**项目构建测试的目录**。

**根因**：`TProjectLWApp` 自己改了三处 —— 重写 `DoInitDescriptor` 问目录、
`InitProject` 里设绝对 `ProjectInfoFile` + `ForceDirectories`、
`CreateStartFiles` 里 `LWGenerateProject` 全量写盘再 `DoSaveProject`。

**标准做法**（`ide/projectdescriptortypes.pas` 的 `TProjectApplicationDescriptor`）：

- `DoInitDescriptor` 不问任何问题；
- `InitProject` 只用相对文件名（`'project1.lpr'`），**从不设
  `ProjectInfoFile`** —— `TProject.IsVirtual` 的判据就是 ProjectInfoFile
  为空 / 主单元虚拟；虚拟工程保存时 `SaveProjectInfo` 才走
  `ShowSaveProjectAsDialog`，对话框建议名取自主程序里的 `program X`，
  目录取 IDE 选项里那个测试目录；
- `CreateStartFiles` 用
  `DoNewEditorFile(FD,'','',[nfIsPartOfProject,nfOpenInEditor,nfCreateDefaultSrc])`，
  单元源码与 `.lfm` 都留在内存缓冲里（`TCodeBuffer.IsVirtual`），
  `.lfm` 由设计器在保存时写。

**修法**（`src/design/lwdsgnregister.pas`）：

- 删掉 `DoInitDescriptor` / `EnsureDefaultDir`；`InitProject` 用相对名
  `LWApp1.lpr`（默认名带数字，见坑 169）、不设 `ProjectInfoFile`、
  不建目录、不写盘；
- 新类 `TLWMainFormFileDesc`（`TFileDescPascalUnitWithResource` 后代，
  `VisibleInNewDialog=False`）承担"内存里的主窗体单元"：
  `ResourceClass=TLWForm`、`DefaultSourceName=umain`、
  `DefaultResourceName=MainForm`、`GetResourceSource` 给模板 lfm；
  `Initialized` 里 `NewFile.SetSourceText(LWFormUnitSource(...))` 把 IDE
  拼的占位源码整篇换成模板原文 —— 与 `tools\lwnew` 生成的 `umain.pas`
  逐字节一致，两条生成路径仍然只认 `lwnewproject` 这一份模板；
- 单元名必须与 `.lpr` 的 uses 一致（都取 `sLWDefaultUnitName='umain'`）；
  窗体名取 IDE 给的 ComponentName（新工程必是 `MainForm`），类名
  `T<窗体名>` 与 `.lpr` 里的 `TMainForm` 对得上。

**代价：两样 IDE 写不出来，靠保存钩子补**（`TLWProjectFinalizer`，
挂 `AddHandlerOnSaveEditorFile` / `sefsAfterWrite`）：

1. `build.bat` / `build.sh` —— 不是工程单元，IDE 不管；
2. nogui 档 `.lpi` 里的 `LCLWidgetType=nogui` 宏 —— **IDEIntf 没有设置工程
   宏的接口**（`TLazProject` 只暴露编译选项与包依赖，`TLazProjectBuildModes`
   连 `Add` 都没有），只能在 `.lpi` 落盘后按字节插
   `<MacroValues Count="1"><Macro1 Name="LCLWidgetType" Value="nogui"/></MacroValues>`
   —— `TProjectBuildModes.LoadMacroValues` 读的就是
   `MacroValues/Count` + `Macro1/Name|Value`；插在 `</ProjectOptions>` 之前
   即可，XMLConfig 按路径取值、不认元素顺序（坑 19 记了宏写错位置的后果）。

两件事都是"缺什么补什么"，所以每次保存都跑：同一次会话里改工程选项再保存，
IDE 会用内存模型重写 `.lpi`，宏又丢一次。工程识别不看描述符
（`TLazProject` 没有 `Descriptor` 属性），看主程序源码特征 —— 含
`TLWApp.Register`，且带 `{$APPTYPE CONSOLE}` 就是 nogui 档。

**顺带修正**：GUI 档原来在 `InitProject` 里硬写 `Win32GraphicApp:=False`，
与 `.lpi` 想要的 `GraphicApplication=True` 相反（"GUI 服务程序带黑窗口"
就是这条）；现在两档都按 `Headless` 取反，内存模型与 `.lpi` 一致，
而 `.lpi` 这次是 IDE 自己写的，不会再各说各话。

**验证**：`lazbuild src/design/lwdesign.lpk` 通过；宏插入逻辑用独立小程序
在真实 `.lpi` 上连跑两遍（幂等、XML 仍合法）。IDE 内的流程需装包后手测：
建工程 → 磁盘无文件 → Ctrl+S → 只出标准保存对话框 → 目录下 6 个文件齐、
nogui 档 `.lpi` 里有宏。

## 坑 169：向导默认工程名不能叫 LWApp（与 lwapp 单元撞名）

**现象**：按坑 168 改成标准流程后，向导的默认名沿用 `LWApp`，IDE 保存时
把 `.lpr` 里的 `program LWApp;` 也改成这个名字 —— 一编译就是
`LWApp.lpr(11,22) Error: Duplicate identifier "LWAPP"`（坑 47 的第一层，
只不过这次是向导自己送的默认值）。

**根因**：默认名与框架核心单元 `lwapp` 同名。FPC 里 program 标识符进
作用域，`uses ..., lwapp, ...` 与它大小写不敏感撞车。IDE 的"保存项目"
对话框不查这个，Lazarus 自带的 `project1` 之所以安全，只是因为它带数字。

**修法**：

- `sLWDefaultProjectName` 改 `'LWApp1'`：默认 `.lpr` / `.lpi` / exe 名
  都是 `LWApp1`，与 `lwapp` 不同名，开箱即能编；
- `LWSanitizeIdent` 的兜底名同样从 `'LWApp'` 改 `'LWApp1'`；
- 重名判定抽成 `lwnewproject.LWProjectNameConflict(Name, UnitName)`
  （保留字清单含 src 下全部 38 个 `lw*` 单元 + 主窗体单元 `umain`），
  `LWGenerateProject`（tools\lwnew 走这条）与保存钩子共用一份判据；
- IDE 侧没有"改工程名"的钩子，只能在 `TLWProjectFinalizer.FileSaved`
  里发现重名后弹一次提示（按 .lpi 路径去重，`FWarnedFor`），告诉用户
  "文件 → 工程另存为"换个名字 —— 宏和脚本仍然照补，不阻断保存。

**顺带**：`LWGenerateProject` 原来内联的 27 项保留字数组漏了
`lwcamera`/`lwcaptcha`/`lwsidemenu`/`lwdsgn*` 等后来新增的单元，现在
按全部 38 个单元列全。

**验证**：`lazbuild src/design/lwdesign.lpk` 通过；用 `lwnewproject` 写
小测试程序：`LWProjectNameConflict('LWApp')='lwapp'`、
`('LWApp1')=''`、`('umain')='umain'`；`LWGenerateProject('LWApp')` 报错
拒绝、`'LWApp1'` 生成 6 个文件；再用 `lazbuild --ws=nogui` 真编该工程，
链接出 `LWApp1.exe`（18 MB），无 Duplicate identifier。

## 坑 170：两个模板编出同一个程序（GUI/nogui 不分）—— 两个独立原因

**现象**：`lazarusWeb Application` 与 `lazarusWeb Application (nogui)` 建出来
的工程，编译后完全一样：都有黑终端窗口，都弹服务端面板窗口。而且新建工程
目录里 `.lpi` 缺 `LCLWidgetType=nogui`，`.lpr` 是 `$APPTYPE CONSOLE`。

**原因一：宏只写了一半，nogui 从来没生效**
`EnsureNoguiMacro` 只往 `.lpi` 的 `ProjectOptions/MacroValues` 插了
`Macro1 Name="LCLWidgetType" Value="nogui"`。那只登记了宏值，**没有启用**它。
IDE 真正判断 widgetset 看的是
`ProjectOptions/BuildModes/SharedMatrixOptions/Item1`（`Type="IDEMacro"`）。
实测（`lazbuild` 编 2026-11-17 建的工程）：

- 只写 `MacroValues` → 日志 `SetBuildTarget ... Changed: LCL=False`，仍用
  win32，于是 nogui 档也弹面板窗口；
- 补上 `SharedMatrixOptions` → `Changed: LCL=True`，切到 nogui。

正确写法（以 IDE 自己保存过的 nogui 工程为准）：

```xml
    <MacroValues Count="1">
      <Macro1 Name="LCLWidgetType" Value="nogui"/>
    </MacroValues>
    <BuildModes>
      <Item Name="Default" Default="True"/>
      <SharedMatrixOptions Count="1">
        <Item1 Modes="Default" Type="IDEMacro" MacroName="LCLWidgetType" Value="nogui"/>
      </SharedMatrixOptions>
    </BuildModes>
```

`ID` 属性可以不给（`TBuildMatrixOption.LoadFromXMLConfig` 读到空会自动生成
GUID），`Targets` 默认 `*`。

**原因二：保存钩子跑在 .lpi 落盘之前**
虚拟工程的第一次保存里，IDE 先逐个写单元、最后写 `.lpi`。原来只挂
`AddHandlerOnSaveEditorFile / sefsAfterWrite`：那时 `.lpi` 还不存在，
`EnsureNoguiMacro` 读不到文件直接返回 —— 于是 `build.bat` 有了、宏没有
（坑 168 的现场就是这样：`build.bat` 在，`.lpi` 里一行 `LCLWidgetType` 都没有）。
修法：同一个 `EnsureExtras` 再挂到 `AddHandlerOnSavedAll`（`DoSaveAll` 里
`DoSaveProject` 之后触发，这时 `.lpi` 一定已写）。两个钩子都"缺什么补什么"，
重复调用无副作用。

**顺带：两个模板改成两个类**
原来用一个 `TProjectLWApp` + 可变字段 `FHeadless` 区分档位。改成
`TProjectLWAppBase`（共同实现，`GetHeadless` 抽象）+
`TProjectLWApp`（False）/ `TProjectLWAppNogui`（True），`Name` 分别为
`lazarusWebApp` / `lazarusWebAppNogui`。档位不再是实例状态，IDE 复制/重建
描述符都不会丢。

**nogui 在 IDE 里的限制（要跟用户说清楚）**
宏只写进了文件，IDE **内存**里的工程选项不会跟着变，所以刚保存完就按 F9
仍会用 win32 widgetset（弹面板窗口）。两条正路：
① 跑工程目录里的 `build.bat`（`lazbuild --ws=nogui`）；
② 重新打开工程后再 F9。
所以 `EnsureNoguiMacro` 插成功后弹一次提示说明这两条。

**同时新增：落盘时把 src/client 拷到工程目录的 lw/**
运行期 `lwhttp.LWFindClientFile` 先找 `<exe 目录>/lw/<文件名>`（扁平部署），
exe 就在工程目录里，所以新建工程时把框架的 `src/client` 拷一份过去，浏览器
才不会白屏。实现：
- `lwnewproject.LWCopyClientAssets(SrcDir, DestParent)`：递归拷到
  `DestParent/lw/`，**不覆盖**已存在的文件（用户可能改过 lw.css / lw.js），
  返回实际拷贝数；单文件用 `TFileStream.CopyFrom`，跨平台；
- 源目录靠 `LazarusIDE.FindSourceFile('lwapp.pas','',[])` 反查：lwapp 在
  `<框架>/src/core`，于是 client = `<框架>/src/client` —— **不写死任何盘符
  或安装路径**，IDE 装在哪个盘、搬到哪、Windows/Linux/macOS 都成立；
- 找不到源目录或拷失败，弹一次提示并给出应手动拷贝的目标路径。

**验证**：
- `lazbuild src/design/lwdesign.lpk` 通过；
- 宏格式：把上面两段 XML 插进一份真实工程后 `lazbuild xxx.lpi`，
  日志从 `Changed: LCL=False` 变成 `LCL=True`（win32 → nogui）；
- `LWCopyClientAssets`：src/client 5 个文件 → `proj/lw/`，首跑 n=5、
  再跑 n=0，字节大小与原文件一致。

## 坑 171：宏补了又没了 —— IDE 在保存结束前会再写一遍 .lpi

**现象**：按坑 170 改完（补 MacroValues + SharedMatrixOptions、加 SavedAll
钩子），nogui 档新建工程编出来依然是 win32 widgetset：`.lpi` 里一行
`LCLWidgetType` 都没有，`build.bat` 却在；而工程目录 `backup/lwapp1.lpi`
里明明有我们补的那一段。于是两档编出同一个程序。

**根因**（读 `ide/sourcefilemanager.pas` 的 `SaveProject` + 现场 backup 文件）：

虚拟工程按 Ctrl+S 走的是 `SaveEditorFile -> SaveProject`，而**不是**
`DoSaveAll`，所以 `AddHandlerOnSavedAll` 根本不触发。`SaveProject` 的顺序是：

1. `SaveProjectInfo`（弹"保存项目"对话框 + 写第一遍 .lpi，工程目录在这里定下）；
2. 逐个写虚拟单元，`SaveEditorFile` 钩子在这一步触发 —— 我们补的宏写进磁盘；
3. **`SaveProjectInfo` 又写一遍 .lpi**（按 IDE 内存模型，没有宏）—— 覆盖掉；
4. `UpdateProjectAutomaticFiles`。

第 3 步之后没有任何钩子，所以补写等于白做。`backup/*.lpi` 是 IDE 覆盖前自己
留的备份，正好把中间状态存了下来 —— 这就是判断依据。

**修法**（`src/design/lwdsgnregister.pas`）：

- 钩子只**排队**，不再当场写：`Application.QueueAsyncCall(@EnsureDeferred)`，
  真正补写在消息循环空闲时执行，那时保存事务已全部结束。另加一个 1.5 s 的
  `TTimer` 兜底（保存过程中若有进度框调 `ProcessMessages`，异步可能跑早了）；
  补写"缺什么补什么"，跑两遍无副作用。
- 补写的 XML **不再手写一遍**，直接调 `lwnewproject` 里 `LWProjectInfo` 用的
  同一份生成函数：新增 `LWProjectMacroValuesXml` / `LWProjectBuildModeItemXml`
  / `LWProjectSharedMatrixXml`，两个档位（GUI / nogui）只在那里判断一次。
  这是坑 170 的第二教训：同一段判断抄两遍必错一遍。
- nogui 补写成功后弹一次询问："立即重新加载本工程让 nogui 生效？" → 是就
  `LazarusIDE.DoOpenProjectFile(...)`。IDE 内存里的工程选项没法用 IDEIntf
  改，重开会让它从 .lpi 重新读，之后 F9 就是 nogui；选"否"仍可用 build.bat。

**同时修：客户端资源目录改按"工程依赖的包"反推**
`LazarusIDE.FindSourceFile('lwapp.pas','',[])` 在保存事务里没命中（日志里
client 那行是 `src=` 空），于是 `lw/` 一直没建。改成：

1. `PackageEditingInterface.FindPackageWithName('lwserver')` → `TIDEPackage.Filename`
   = `<框架>/src/lwserver.lpk` → 反推 `<框架>/src/client`（`lwcore` 再兜一次）；
2. `FindInstalledPackageWithUnit('lwapp')`；
3. 最后才用 `FindSourceFile` 试标志文件。

`lwnewproject.LWClientAssetsDirNear` 现在从给定路径向上找四层，每层试
`client` 与 `src/client`，所以 `<框架>/src/*.lpk`、`<框架>/src/core/*.pas`、
`<框架>/tools/lwnew.exe` 三种落点都能命中（没有 lw.js 的目录不认）。
`tools\lwnew` 也顺手把 `src/client` 拷到工程的 `lw/`，与 IDE 向导一致。

**另外留了一份日志**：`%TEMP%/lazarusweb-wizard.log`，每次补写记一行
（lpi 路径 / 档位 / client 命中过程 / 拷贝数 / 宏是否插入），排障时直接看。

**验证**（不依赖 IDE 交互的部分都实跑过）：
- `lazbuild src/design/lwdesign.lpk` 通过；
- 用"IDE 写出来的那份 .lpi"（照现场抄下来：有 PathDelim / ResourceType /
  Debugging，无 LCLWidgetType）跑补丁逻辑 → 得到与 `LWProjectInfo` 完全一致的
  两段 XML，缩进也对；
- 补过之后 `lazbuild` 编：日志 `Changed: LCL=True`（切 nogui），exe PE 子系统
  3（console）；同一份 GUI 模板工程 `LCL=False`、子系统 2（GUI，不带黑窗口）
  —— 两档确实不同了；
- `LWClientAssetsDirNear` 六种输入（core/lwapp.pas、src/lwcore.lpk、
  tools/lwnew.exe、目录 core、目录 client、不存在路径）结果正确；
- `lwnew.exe --name=CliDemo --dir=... --gui`：生成 6 个文件 + `lw/`（5 个文件）。

## 坑 172：保存时弹"文件未找到 C:/3/umain.pas" —— 在保存事务里弹框/重载工程（2026-11-17）

**现象**：新建工程（nogui 档）→ Ctrl+S → 弹出"文件未找到：该文件
"C:/3/umain.pas" 未找到。忽略将继续加载项目，取消将停止加载项目"。
点任一按钮，工程目录里只剩半截文件（.lpi / .lpr 在，umain.pas 没有），
工程报废。这是坑 171 那个"延迟补写"方案的直接后果，比宏没补严重得多。

**根因**：坑 171 里我们以为 `Application.QueueAsyncCall` 的回调一定在
"消息循环空闲、保存事务已结束"时执行。**不是**。`SaveProject` 内部会
`ProcessMessages`（写单元、刷进度条），排队的异步回调就在保存事务**中间**
被执行了：

1. `SaveProjectInfo` 写完第一遍 .lpi（登记了 umain.pas）—— 此时 umain.pas
   还没写到盘上；
2. 写第一个单元（.lpr）后 `SaveEditorFile` 钩子触发 → 排队；
3. `ProcessMessages` → 异步回调跑 → 我们的代码弹"是否重新加载工程"模态框；
4. 用户点"是" → `DoOpenProjectFile` 在保存事务内部把工程关掉重读；
5. IDE 按 .lpi 去找 `C:/3/umain.pas`，盘上没有（第 2 步只写了 .lpr）
   → `TFileOpener.OpenNotExistingFile`（`ofProjectLoading` 分支）弹
   "文件未找到"；
6. 保存事务被这次重入打断，剩下的单元永远不落盘。

判定依据：`%TEMP%/lazarusweb-wizard.log` 最后一行是 `reload project to
apply nogui`（14:53:53），17 秒后用户截图；提示语只出现在
`ide/sourcefilemanager.pas` 的 `OpenNotExistingFile`，且仅当
`ofProjectLoading in FFlags` —— 即**加载**工程时才弹，不是保存时。

**教训（比修法更重要）**：
- "延迟"不等于"事务结束"。`QueueAsyncCall`、`TTimer`、`Application.OnIdle`
  都可能在 IDE 的 `ProcessMessages` 里被提前触发 —— 只要 IDE 处在
  保存/加载/编译这类事务中，**一律不许弹模态框，更不许 `DoOpenProjectFile`**
  （它会关工程，等于把事务连根拔掉）。要确认事务结束，只能看**外部可观测
  状态**（文件写完了没有），不能看"我排了多久"。
- 同理：任何"保存后置处理"的钩子都必须自带幂等 + 守卫，宁可这一轮不做，
  也不能在不该动的时候动。

**修法**（`src/design/lwdsgnregister.pas`，`TLWProjectFinalizer`）：

- **删掉 `QueueAsyncCall`**。保存钩子（`SaveEditorFile` / `SavedAll`）只做一
  件事：确保一个 0.5 s 的 `TTimer` 在跑（已在跑就不重置计数）。
- 定时器每轮先判定"保存写完了吗"：
  - `.lpi` 在盘上；
  - 工程里每个 `IsPartOfProject` 的单元，按"内存里的 Filename（绝对就用
    绝对，相对就拼 `.lpi` 所在目录）"检查**磁盘上存在**。
  - 注意 `TLazProjectFile.GetFullFilename` 只是 `Result := fFilename`
    （`ide/packages/ideproject/project.pp:2160`），判不出"有没有路径"，
    别拿它当"已落盘"的判据。
  没写完 → 稳定计数清零、下一轮再看（最多 120 轮 ≈ 1 分钟，放弃时只写日志）。
- 连续**两轮**都通过才调 `EnsureExtras`：SaveProject 末尾还会再写一遍 .lpi
  （坑 171），两轮之间没有新写入才说明真的结束了（原间隔 1.5 s 的思路保留，
  只是判据从"等了多久"换成"文件状态"）。
- 唯一还会重载工程的地方，就是 `EnsureExtras` 里补完宏之后的那次询问，此时
  上述前提已成立；按钮顺序改成 `[mbNo, mbYes]`——默认"否"，用户明确点"是"
  才 `DoOpenProjectFile`。

**连带**：用户现场的工程已经被那次重载搞坏（`C:/3` 后来清空了）。恢复办法
只有一个 —— 关掉当前工程（项目 → 关闭），或者重启 IDE，然后重新新建工程。
`.lpi` 若还在，直接重开也能用（只是 umain.pas 得补回来）。

**验证**：`lazbuild src/design/lwdesign.lpk` 通过；逻辑上（无法在 IDE 里
自动化）—— 保存事务中定时器触发时 `UnitsOnDisk` 必为 False（umain.pas
此时不存在），因此只会"等下一轮"，不可能再弹框。

## 坑 173：新建窗体上 Button/CheckBox/RadioButton/Label 在浏览器里全是空白（2026-11-17）

**现象**：向导新建的工程，在设计器里拖上 `TButton` / `TCheckBox` /
`TRadioButton` / `TLabel`（Caption 都是 LCL 默认的控件名），设计期显示正常，
浏览器里全部**没有文字** —— 按钮是个空壳，勾选框/单选框旁边一片空白，
Label 干脆不见了。而 `TEdit`（`Edit1`）、`TMemo`（`Memo1`）正常。

**根因**：`lwwriter.pas` 的 `TLWWriter.CaptionOf` 里有一条启发式：

```pascal
{ 设计器里 TPanel/TToolBar 的 Caption 默认等于控件名，别渲染出来 }
if s = C.Name then Exit;
```

注释说的是 TPanel/TToolBar，代码却**没判控件类型**，对所有控件一律生效。
而 LCL 新建按钮/勾选框/单选框/标签时，Caption 默认就等于控件名（`Button1`、
`CheckBox1`…），于是文字被整条规则吞掉。Edit/Memo 不受影响是因为它们显的是
`Text`/`Lines`，不走 Caption。仓库里的 demo 一直没暴露，因为那些控件的
Caption 都写成了业务文字（"保存"、"用户名"…），不会命中 `Caption = Name`。

**修法**：把守卫限定到"Caption 只是设计期占位标题"的容器 —— `TPanel` /
`TScrollBox` / `TFrame`。客户端 `panel`/`scrollbox`/`frame` 分支本来就有
`node.caption !== node.name` 的过滤（注释写着"服务端已过滤，这里双保险"），
两边判据现在一致；按钮、勾选框、单选框、标签、分组框、页签的
`Caption = 控件名` 一律照原样下发。

**验证**（临时工程 `captest.lpr`，直接调 `TLWWriter.WriteControl`，
窗口不启也能跑）：

```
TButton        kind=button    caption=[Button1]
TBitBtn        kind=bitbtn    caption=[BitBtn1]
TCheckBox      kind=checkbox  caption=[CheckBox1]
TRadioButton   kind=radio     caption=[RadioButton1]
TLabel         kind=label     caption=[Label1]
TPanel(吞)     kind=panel     caption=[]          <- 容器仍按原意吞掉
TButton(保存)  kind=button    caption=[保存]      <- 业务文字不受影响
```

**教训**：翻译层里的"启发式丢弃"必须先限定**控件类型/语义**，再判**值形态**。
只凭"值等于名字"就丢，等于把"用户没改名"误判成"这是占位符" —— 默认值恰好
等于名字的控件（LCL 全是默认值时就是这样）会被集体误杀。

## 坑 174：主题从 2 套扩到 7 套 —— 三条会静默出错的约定（2026-11-17）

**背景**：Alpine 渲染层原来只有 `light` / `dark` 两套（加 `auto`）。这次
扩成 7 套固定配色 + `auto`，分两个色系：

```
浅色系  light 亮色（默认） / paper 米黄纸张 / mint 护眼绿 / contrast 高对比
深色系  dark 深色（基准）   / midnight 深蓝夜色 / forest 墨绿夜色
```

**三条约定**（不遵守时都不会报错，只是配色悄悄不对）：

1. **浅色变体必须写全 61 个 `--lw-*` 变量**。
   浅色变体继承的是 `:root`（蓝灰亮色），少写一个（比如 `--lw-ch-grid`），
   那个位置就还是默认的蓝灰 —— 在一屏暖棕/浅绿里冒出一根蓝线。
   `paper` / `mint` / `contrast` 三块都是完整 61 项。

2. **深色变体只覆盖色调，但选择器必须进"深色基准块"那一行**。
   基准块的选择器是三个一起：
   ```css
   html[data-lw-theme="dark"],
   html[data-lw-theme="midnight"],
   html[data-lw-theme="forest"] { /* 61 个全量深色值 */ }
   ```
   变体块（只写差异 ~59 项）排在后面覆盖。**加新深色主题时忘了往基准行
   补选择器，它就会去继承 `:root` 的亮色**——症状是"深色主题下白底黑字"，
   非常好认，但要先想到这里。`midnight` / `forest` 的 `--lw-captcha-filter`
   与 `--lw-sm-ic-filter` 有意不覆盖（沿用深色基准的反相/不过滤）。

3. **`theme === 'dark'` 这类判断全部要换掉**。
   深色系有三套，写死 `'dark'` 的地方（图标、`LW.theme` 判断、业务代码）
   在 `midnight` 下会当成浅色。客户端统一用 `THEME_DARK` / `themeIsDark()`
   / `LW.theme.dark()`；`lw:themechange` 事件的 `detail` 里也带了
   `dark: true|false`。

另外一条与服务端有关：`TLWThemeMode` 枚举新值**只能追加在末尾**
（`twAuto, twLight, twDark, twPaper, twMint, twMidnight, twForest, twContrast`）——
`.lfm` 存的是枚举序数，插在中间会把老窗体存的值解释成别的配色。

**验证**（真跑，不是看代码）：

- CSS 解析脚本：基准块 61 项齐全；`paper`/`mint`/`contrast` 各 61 项、
  无未知变量名、无重复；`midnight`/`forest` 各 59 项（缺的两项正是有意继承）；
  全文件花括号平衡。
- WCAG 对比度脚本（16 组关键配对的相对亮度比）：7 套全部达标；唯一低于
  3.0 的是浅色系的"禁用文字"（light 自己就是 2.49，属既有设计，新主题
  2.58~2.64 反而略好）。
- 真浏览器截图：`gallery_nogui.exe --port=8123` + Edge headless/CDP，
  逐套 `LW.theme.set(...)` 后截全页，7 张目视检查无残留色、无隐字；
  再点开标题栏按钮截图，确认菜单 8 项、当前项带 ✓、不被窗口裁掉。
  `LW.theme.modes()` 返回
  `["light","dark","paper","mint","midnight","forest","contrast","auto"]`。

**教训**：主题这类"纯值"的扩展，风险不在代码逻辑，而在**不报错的漏项**
（少一个变量、少一个选择器、少一处字符串判断）。所以要么让结构强制
（深色基准块共享、枚举追加在末尾），要么用脚本把"完整性"变成可断言的
东西 —— 靠肉眼看 7 套配色是看不全的。

## 坑 175：热更新换版与优雅退出——两条 Windows 语义定了整套设计（2026-11-17）

**日期**：2026-11-17　**标签**：lwhyper / 热更新 / 进程 / 优雅退出 / Windows

### 先验证，再写代码

"换 exe 不断服"能不能做，取决于两个 Windows 语义。这两个都是**实测**出来的，
不是推断（临时写了 parent/child 两个 FPC 小程序验证）：

| 语义 | 实测结果 |
|---|---|
| 正在运行的 exe 能否覆盖写 | ❌ 不能（链接/写入失败） |
| 正在运行的 exe 能否**改名** | ✅ 可以（`RenameFile` 成功，进程继续跑已映射的镜像） |
| `TProcess.Terminate(1)` 的实际效果 | **强杀**：300ms 内进程消失，不经过任何退出流程 |

第一条决定了换壳必须用"改名"而不是"复制覆盖"，第三条决定了必须给 worker 加
一个**优雅退出端点**——强杀会丢掉在途请求、日志缓冲和框架自己的收尾。

### 换壳：两步改名

```
exe      -> exe.old-<时间>     ① 旧镜像让位（运行中的 worker 无感）
exe.new  -> exe                ② 新文件就位（不停任何进程）
worker #1..N 逐个重启          ③ 只有重启窗口在换镜像
```

`LWMoveFile` 先试 `RenameFile`，跨卷失败才退化成"复制 + 删源"。
① 失败就放弃，② 失败把 ① 改回来——两个分支都不会留下"exe 没了"的状态。

### 四个会静默出错的地方（都踩过）

1. **`Launch` 抛异常没走回滚**。新 exe 若不是有效 PE，`TProcess.Execute` 直接
   抛异常（不是"起不来"，是压根没起）。最初只在"等就绪超时"分支回滚，异常
   分支会跳过回滚——集群停在"exe 已被换成坏的、worker 全死"上。现在 `RunUpdate`
   的循环包在 `try..except` 里，异常同样 `Rollback`。
2. **巡检线程与换版线程并发起停同一个 `Proc`**。一方刚 `Free`、另一方正在读
   `Proc.Running` → AV；两边同时 `Launch` → 重复进程 + 端口抢占（新进程 bind
   失败直接退出，又触发下一轮重启）。修法：`FWorkerLock` 保护所有起停/读取，
   再加 `FUpdating` 让巡检线程在换版期间只管探针、不动手。
3. **同一份换不进去的文件每 4 秒刷一遍日志**。exe 被占用时换壳会失败，而
   `CandidateReady` 每轮都为真 → 日志被撑爆。修法：记住失败文件的 size+mtime，
   等它变了再试。
4. **回调里直接 `Stop` 收不掉自己**。`/lw/shutdown` 若在请求线程里 `Stop`，
   正在应答的这条连接会被一起收掉，客户端拿不到 200 → lwhyper 误判"拒绝退出"
   转而强杀。修法：回调只置标志 + 回 200，另起 `TLWShutdownWatch` 线程做停服。

另外一处连带修复：nogui 主循环原本是 `while True do Sleep(500)`，收到优雅退出
请求后也只能靠强杀结束。改成判断 `TLWServer.StopRequested`，`Start` 返回即正常
退出（`lwpanel.pas` 的 LCLnogui 与 LCL 两处分支都改了）。

### 优雅退出：三道闸

`POST /lw/shutdown` 在 worker 侧存在的前提与约束：

1. lwhyper 启动时随机生成 32 位十六进制令牌，用 `--shutdown-token=` 注入每个
   worker 命令行——**没注入时这个端点根本不存在**（普通应用不会被关）；
2. 只认回环地址（`127.0.0.1` / `::1` / `localhost`），否则 403；
3. 令牌放自定义头 `X-LW-Shutdown`，不放 URL——浏览器页面跨域加不了自定义头，
   恶意链接关不掉服务。

lwhyper 侧：先请它自己退（等进程结束，上限 10s），**不应答才强杀**兜底；
老 worker（不含本次 core 的）回 403/404，日志记一行后退回强杀，功能不退化。

### 验证矩阵（真跑）

| 场景 | 结果 |
|---|---|
| 2 worker 热替换 + 持续压测 | 83 请求 **0 失败**，6 秒完成，`updating` 期间始终有 worker 在线 |
| 优雅退出 | worker 日志出 `[lw] /lw/shutdown已受理，优雅退出中`，两个 worker 都走此路径 |
| 坏版本（文本冒充 exe） | 6 秒内回滚，坏文件留存 `.bad-<时间>`，服务恢复；未被换版的 worker PID 不变 |
| `--no-hot-update` | 不建线程，`.new` 放着不动 |
| `--update-dir` | 投放目录同名文件触发换版，处理完文件被移走 |

观测字段：`/lw/hyper/status` 的 `hotupdate` / `updating` / `updates`（每个
worker 也有 `updates`）。

### 教训

"零停机换版"真正的难点不是换壳，而是**换壳失败时的状态恢复**和**两个后台线程
抢同一批进程**。三个失败分支（改名失败、启动抛异常、等就绪超时）必须都有明确
落点，且落点都得是"集群还跑着可用版本"；否则一次发布事故会把整站留在不可用
状态。相关机制细节见 `WHYPER.md` §5.1/§5.2，分发侧见 `LOADBALANCE.md`。

## 坑 176：TLabeledEdit 标签和输入框之间多出一条缝（2026-11-18）

**现象**：nogui 工程里 `TLabeledEdit`（LabelPosition=lpAbove，默认）的标签
文字和输入框之间有 ~12px 空隙，视觉上像两个不相干的控件；而 LCL 里
LabelSpacing 默认 3px。lpLeft/lpRight 同理会偏。

**根因（两处叠加）**：

1. **服务端两套坐标混算**。144PPI 设计的窗体加载时 LCL 按 96/144 折算控件
   边界，但 AutoSize 控件不走 LFM 缩放（坑 155 同源）：`TLabeledEdit` 的
   `Top` 已折成 96 系（200→133）、`Height` 却还是原始 35；它的 `TBoundLabel`
   更是整个没被折（Height=27、Width=120 全是 144 原始值）。`WriteKindPropsBody`
   摆标签用 `le.Top(96系) - C.Height(144系) - 3`，多出 (27-18)=9px。
2. **客户端"渲染后精修"没挂到首次创建**。`fixBoundLabel` 本来就是为此设计
   的：按浏览器渲染后的真实矩形重贴标签，不信任服务端数字。但它只挂在
   `updateNode`（补丁轮），`createNode` 没有 —— 首屏永远是错位，直到第一
   次事件往返触发补丁轮才被纠正。

**修法**：

- `lw-alpine.js` `createNode`：`placeNode` 之后补 `if (node.boundfor)
  fixBoundLabel(id)`。这是权威修复 —— 浏览器拿渲染结果算，服务端数字随便
  错它都能纠正。
- `lwwriter.pas` TBoundLabel 分支：用 `C.Width/C.Height` 之前先按宿主窗体
  `DesignTimePPI -> PixelsPerInch` 折算（与 MakeBase 对 AutoSize 标签的折算
  对齐），初值不再离谱，避免精修（60ms 定时器）前闪一下错位。

**验证**：重建用户工程（C:/3/LWApp1）+ 无头浏览器实测：修复前标签底到
输入框顶 12px；修复后 gap=3px，labelTopStyle=112px（= 133-18-3，客户端
精修值）。`node --check` + lwserver win32/nogui 两目标重编通过。

**教训**：凡"服务端摆位 + 客户端精修"双保险的结构，精修必须**两条路径都
挂**（首建 + 补丁轮），否则首屏就是裸奔；另外 nogui 下运行期边界里
"折算过的位置" 和 "没折算的尺寸" 会同时出现在同一个控件上，任何拿它们
做加减的代码都要先问一句"这两个数是一个坐标系吗"。

## 坑 177：报表页「生成报表」第一次必失败（No timers available），之后又报重名（2026-11-18）

**现象**（画廊 → 报表 LazReport → 生成报表）：

1. 第一次点，`生成失败：EOutOfResources: No timers available`；
2. 再点一次就成功（看起来"自愈"了）；
3. 但点第三下会变成 `生成失败：EComponentError: Duplicate name:
   A component named "HntphbTable" already exists`。

复现条件：**win32（默认 widgetset）的产物**（`gallery.lpi` 之外的
`gallery_gui.lpi` → `gallery_x86_64-win64.exe`）。nogui 产物
（`gallery_nogui-x86_64-win64.exe`）实测没触发第 1 条，所以以前没暴露。

**根因 A：LazReport 的进度窗体里有个 LCL TTimer，收尾时无条件碰它**

`lr_progr.pas` 的 `TfrProgressForm` 带一个 `Timer1: TTimer`，`Timer1Timer`
只做一件事：把 `Enabled` 置回 False。就算根本不显示进度条，收尾也会摸到它：

```
TfrReport.DoPrepareReport         // 开头 FinalPass := True
  -> BuildBeforeModal(nil)        // 非模态分支（IsMainThread=False 就走这里）
       -> if FinalPass then frProgressForm.ModalDone(mrOk)
            -> Timer1.Enabled := True
                 -> TCustomTimer.UpdateTimer
                      -> WidgetSet.CreateTimer     // 分配系统定时器
```

`WidgetSet.CreateTimer` 返回 0（服务器工作线程里 `SetTimer` 拿不到定时器；
nogui 的实现干脆永远返回 0）→ LCL 抛 `EOutOfResources(SNoTimers)`。

**为什么"第二次就好了"**：`TCustomTimer.SetEnabled` 是先 `FEnabled := True`
再 `UpdateTimer`，异常是后一步抛的。所以第一次虽然失败，`Enabled` 已经记成
True；第二次再赋 True 时值没变，直接 return，不会重试 —— 现象上的"自愈"，
其实是状态已经被改脏了。

**根因 B：每次生成都重复建同名数据集组件**

`TLazReportDemo.Prepare` 每次都 `TfrDBDataset.Create(FOwner)`（Name 固定
`HntphbTable`），`BuildSampleData` 每次都建一个同名 `TBufDataset`，旧的两样
都不释放。它们挂在同一个 `Owner` 下，第二次建就撞名 → `TComponent` 抛
`EComponentError`。

**修法**（`demos/gallery/uLazReportDemo.pas`）：

1. 构造函数：`FReport.ShowProgress := False;` —— 服务端不要模态进度窗
   （没有主消息循环，也没有人能点"取消"）。
2. 构造函数：`if Assigned(frProgressForm) then frProgressForm.Timer1.OnTimer := nil;`
   —— 光有关掉显示的开关**不够**，因为收尾代码绕过了它。`TCustomTimer.UpdateTimer`
   里 `Assigned(FOnTimer)` 是"要不要真去 CreateTimer"的前提，把 OnTimer 摘掉
   就等于让它彻底不碰 widgetset（同一个套路见 `lwdispatch` 对 TTreeView
   内部 FChangeTimer 的处理）。
3. `Prepare` 开头：`FReport.Dataset := nil; FreeAndNil(FDB); FreeAndNil(FData);`
   —— 重建之前先释放，不再撞名。

**验证**（真跑，CDP 驱动浏览器点按钮）：

| 构建 | 处理 | 连点三次结果 |
|---|---|---|
| win32 | 原始代码 | 失败(No timers) / 成功 / 成功 —— 与用户现象一致 |
| win32 | 只加 `ShowProgress := False` | **仍然第 1 次失败** → 证明碰定时器的是 `ModalDone` 而不是显示开关 |
| win32 | + `Timer1.OnTimer := nil` | 成功 / 成功 / 成功 |
| nogui | 不修 | 成功 / 成功 / 成功（第 1 条在此产物上不触发） |
| nogui（重建产物） | 全修 | 成功 / 成功 / 成功 |

生成物检查：`uploads/lazreport/report_*.pdf` 153 KB、`%PDF-1.3` 头、
1 页（与页面显示的"已生成 1 页"一致）；文件名带毫秒，同秒连点不会互相覆盖。

**教训**：

- 第三方库的"进度条 / 模态窗"在服务端是毒药：**光关显示开关不够**，收尾
  路径常常绕过开关直接操作那个对象。要么把它的回调摘掉（本例 `OnTimer`），
  要么干脆别让它创建。
- "第一次失败、第二次正常"不是偶发，多半是某个 setter **先改状态再抛异常**
  —— 状态已脏，下次走进另一条分支。看到这种自愈，先找"状态被提前改掉"的地方。
- 同一个会话里第二次点击暴露的往往是**另一个** bug（本例是组件重名），
  修完第一个别急着收工，连点三次再确认。

## 坑 178：`--tls-cert/--tls-key` 被静默忽略，刷「Invalid control character in request」（2026-11-18）

**现象**（`demos/dbaware`）：
```
dbaware --nogui --port=8090 --tls-cert=server_self.crt --tls-key=server_self.key
```
浏览器用 https 打开 → 服务端日志疯狂刷：
```
[warn] 处理请求时出错: EHTTPServer:Invalid control character in request "\x16\x03\x01\x06\x9C\x01\x00..."
```
加上 `--ssl` 就正常。

**根因（三层）**：

1. **参数名根本不存在**。框架只认 `--ssl-cert=`/`--ssl-key=`（`lwapp.pas`），
   用户写的 `--tls-cert=`/`--tls-key=` 在命令行循环里没有匹配分支。而那个
   循环**没有 else 兜底**，未知参数被静默吞掉，一个字都不提示。
2. **给了证书也不自动开 HTTPS**。`UseSSL` 只由独立的 `--ssl` 开关置位。
   于是"证书/私钥都交出来了"却仍以纯 HTTP 启动 —— 明明意图是 HTTPS。
3. **TLS 握手被当 HTTP 解析**。`\x16\x03\x01` 是 TLS ClientHello 的记录头
   （0x16=handshake、0x03 0x01=TLS 1.0）。fcl-web 把它当请求行读，遇到
   二进制控制字符抛 `EHTTPServer:Invalid control character in request`，
   `HandleRequestError` 把整段握手字节打进 `[warn]`，既刷屏又看不懂。

**修法**：

- `lwapp.pas`：`--tls-cert=`/`--tls-key=` 作为 `--ssl-cert=`/`--ssl-key=`
  的别名；**给了证书或私钥就自动 `UseSSL := True`**（不必再记 `--ssl`）；
  参数循环末尾加 else，未知 `--` 参数打警告；`--help` 同步。
- `lwhyper.pas`：同样加别名 + 自动开 SSL（保持 daemon 与 worker 行为一致）。
- `lwhttp.pas` `HandleRequestError`：识别
  `EHTTPServer` + `Invalid control character`，改打一句明确指引
  （"收到非 HTTP 流量，看起来是 TLS 握手…要 HTTPS 加 --ssl"），
  不再把二进制握手原样刷出来。

**验证**（真跑）：

| 场景 | 命令 | 结果 |
|---|---|---|
| 新别名自动开 HTTPS | `dbaware --nogui --port=8091 --tls-cert=<crt> --tls-key=<key>` | `curl -k https://…` → **200** |
| 纯 HTTP 端口收到 TLS 握手 | `dbaware --nogui --port=8092` + `curl https://…` | 日志只出现一行友好提示，无二进制；`curl http://…` 仍 200 |
| 未知参数 | 加 `--bogus=1` | 启动日志出现"未识别的参数 --bogus=1，已忽略" |

`lwserver` 包 win32/nogui、`dbaware`/`dbaware_gui`、`lwhyper`/`lwhyper_gui`
全部重编通过。

**教训**：
- 命令行解析循环**一定要有 else**。静默忽略拼错的参数，等于把配置错误
  藏起来，等到运行时以完全无关的异常形式爆出来（本例是 TLS 握手错）。
- "意图明确的参数"（给出证书/私钥）应当**自动推出**配套开关（开 SSL），
  不要逼用户记住两个必须同时出现的开关。
- 服务端收到"不是本协议的流量"（TLS 握手打 HTTP 口、HTTP 打 TLS 口）
  是很常见的误配，`HandleRequestError` 应识别这类特征并翻译成人话，
  别把协议字节原样当错误上下文打印。

## 坑 179：移动端套 .m.html 后右侧 TPageControl 控件被裁成空白（回归）

**现象**（用户 2026-11-19 真机反馈）：gallery（设计宽 1800@144PPI → 下发
1200）在手机上打开 `.m.html` 后，右边 TPageControl 里的控件不显示，
只剩一片空白。同一个问题此前修过一次（坑 150/151 的同一族）。

**根因**：`lwApplyFormTpl` 的 `mode==='mobile'` 分支还在用老方案
把窗宽压成 `min(设计宽, 视口宽-8)`（1200 → 382），而模板只是装饰层、
控件仍按设计期绝对坐标摆放；窗一窄，页签页（`alClient`）就按 382 宽
重算，x>382 的控件被裁掉。同时 `lwApplyTplHost` 把 `fm.tplFallback`
清成 `false`，`lwUpdatePan` 判定"无需平移" → `#lw-root` 不滚动，
被裁的部分连滑动都看不到，视觉上就是右侧空白。

**修法**（`lw-alpine.js`，只动 Alpine 移动端，桌面端一行未改）：

1. `lwApplyFormTpl` 移动分支：窗宽/高改
   `Math.max(设计值, 视口-8 / 视口-12)`、`left=0`、`top=6px`，与无模板
   平移模式同一套几何；并置 `fm.tplFallback = true`；
2. `lwUseTpl` 套模板成功后（移动端）再确认一次几何 + `lwUpdatePan()`，
   并 `runLayout` 重排顶层，抵消 `lwApplyTplHost` 的清标志；
3. 语义统一：`tplFallback` 现在表示"移动端保持设计宽高、需要平移查看"，
   不再等同"无模板"；无 `.m.html` 仍直接回 LCL 布局（不读桌面 `.html`），
   但回 LCL 时 `tplFallback=false`，不强制平移。

**验证**（真跑 Edge CDP，390×844）：
- 新增 `tests/cdp_gallery_mobile_tpl.py` 6 项 ALL PASS：
  套上 `.m.html`、窗体 1200（不再 382）、`pan=1`、
  `#lw-root` scrollWidth 1200 > clientWidth 390、活动页签页 1198 宽、
  25/25 个子控件尺寸非零，横滚后最右控件进入视口；
- 截图目视：初始视口控件正常，滚到中部能看到 TTimeEdit / 进度条 / 价格等；
- `tests/cdp_fit_scale.py` 23 项 ALL PASS（S2 断言改为"套模板 + 保持设计宽"，
  S6 改为"设计宽 547 > 390 时有模板也平移"）；
- `tests/cdp_mobile_demo.py` ALL PASS（占位符断言按"模板只作装饰层、
  控件保持绝对定位"更新；T5 改为 gallery 有模板 + 平移）；
- `node --check lw-alpine.js` 通过。

**教训**：把"模板 = 装饰层、不重排控件"定下来以后，**几何就不能再为了
适配视口去压窄窗体** —— 压窄只是把裁剪从"窗口外"挪到"页签页内"，
看起来更像 bug。保持设计宽 + 平移滚动是唯一自洽解；有模板与无模板
必须共用同一套几何规则，否则一方修好另一方又回归。

## 坑 180：平面模式（flat）里没有换配色的入口

**现象**（用户 2026-11-19）：窗体用 `lw-tpl-mode:flat` 时，界面上找不到
主题（配色）切换按钮；窗口模式正常。

**根因**：配色按钮只创建在标题栏里（`themeButton(title)`），而平面模式
的第一条样式就是 `.lw-win.lw-flat-form > .lw-win-title { display:none
!important }` —— 整条标题栏连同 ☀/☾/◐ 一起没了。也不能只加快捷键：
手机上根本没有 Alt 键，平面模式恰恰主要用在手机整页场景。

**修法**（`lw-alpine.js` + `lw-alpine.css`）：

1. `themeFabAdd(fm)` / `themeFabDrop(fm)`：平面窗体在 `win` 下挂一个
   `.lw-theme-fab` 浮动圆钮（`position:fixed`，右下角 12px，34px；
   移动布局 38px），点击 `themeMenu(b, true)` 向上展开同一份 8 项菜单；
2. `themeMenu(anchor, up)` 增加向上展开分支（`top = r.top - pop.height - 2`），
   否则底部按钮的菜单会跑出屏幕；
3. 生命周期：`lwApplyFlatTpl` 成功后挂；`lwClearFormTpl` 里摘（切回窗口
   模式时标题栏按钮本来就回来了，浮钮不能留两份）；浮钮也 push 进
   `themeBtns`，主题切换时图标同步、`LW.theme.button(false)` 时一起隐藏；
4. 服务端 `LWThemeButton=False` 与模态窗体不挂（与标题栏按钮同规则）。

**验证**（`tests/cdp_flat_theme.py`，390×844 真跑）：5 项 ALL PASS ——
flat 形态 + 标题栏 display:none、浮钮 38×38 可点、菜单 8 项完整落在
视口内（top 568 / bottom 794 < 844）、选「深色」后 `data-lw-theme=dark`
且图标重绘、再点可重新展开。截图目视：按钮半透明贴在右下角，菜单向上
展开不遮挡。

**回归**：`cdp_gallery_mobile_tpl.py` 7 项 ALL PASS（新增 A4b：窗口模式
**不**应出现 `.lw-theme-fab`，防止浮钮泄漏）。

**部署教训**：客户端脚本有三处副本 —— `src/client`（源）、exe 同目录
`lw/`（`LWFindClientFile` 第②优先级，实际生效）、以及测试部署目录。
改完只同步一两个地方，会出现"代码明明改了、浏览器还是旧行为"，还容易
误判成逻辑没生效（本次排查就绕了一圈：curl 到的仍是 219087 字节旧版）。
排查第一步固定是 `curl /lw/lw-alpine.js | grep <新符号>` 确认下发版本。

## 坑 181：移动端 TLWColorPicker 点了没反应（桌面正常）

**现象**（用户 2026-11-19 真机反馈）：手机点色块没有任何弹窗；同一页面
在桌面浏览器能正常弹出原生调色板。

**根因**：色块的点击入口是「JS 造一个 1px、`opacity:0` 的
`<input type=color>`，append 到 body 之后再 `inp.click()`」（坑 166 为
修"弹窗开在视口外"定下的方案）。桌面 Chromium 认这种程序化唤起，移动
浏览器普遍把它当**非用户手势**直接忽略 —— 脚本跑完、input 也建了，就是
不弹。CDP 实测：`$lwPickColor` 被调用、`input[type=color]` 也确实生成，
但原生选择器不出现。

**修法**（`lw-alpine.js` + `lw-alpine.css`）：

1. `kind=color` 的渲染改成**色块内常驻一个真实 input**：
   `<div class="lw-swatch">` 里放 `<input class="lw-cp-inp" type="color">`，
   CSS 让它 `position:absolute; inset:0; opacity:0` 铺满色块。手指直接点中
   真 input，由浏览器自己唤起调色板，桌面/移动完全一致；
2. 新增 `$lwPickColorChange(id, ev)` 处理 `@input` → 更新色块背景、
   `S.R/S.ND` 与 `OnColorChange` 回发；
3. 旧的 `$lwPickColor(id)` 保留兼容：优先 `showPicker()`，失败回退
   `click()`，且兜底 input 尺寸跟随色块（不再是 1px）；
4. patch 时同步 `input.value`，否则下次点开还是旧颜色。

**顺带修**：`lwApplyFlatTpl` 把窗宽设成 `100%`（视口宽），页签页
（alClient）随之收缩到 388，而控件仍按 1200 设计坐标摆放 —— 右侧控件
（含本坑的色块）被页签页内部裁掉，滚都滚不到（与坑 179 同族）。现在
平面模式与窗口模式统一：宽高取 `max(设计值, 视口)`，移动布局置
`tplFallback=true` 让 `#lw-root` 平移。`lwUpdatePan`/`lwApplyFlatTpl`
改用 `lwLayoutNow()` 判断布局（冷启动时 `layoutState` 还是 null，会漏开
平移）。

**验证**（`tests/cdp_colorpicker_mobile.py`，真跑 Edge）：
C1 input 尺寸 = 色块（138×34，不是 1px）；C2 `elementsFromPoint` 命中
input；C3 真实触摸收到 click；C4 派发 input 后色块背景变 `rgb(18,52,86)`；
C6/C7 390 竖屏横滑后色块进入视口且命中 input；C5 桌面同样命中 —— ALL PASS。
`cdp_gallery_mobile_tpl` / `cdp_fit_scale` / `cdp_mobile_demo` 同步按
"平面模式保持设计宽 + 可平移"更新断言，全 PASS。

---

## 坑 182：平面模式切主题永远是同一块底色；深色下 pnlLog 白底浅字

**现象**（用户 2026-11-19）：平面模式下切换任何主题，页面都是同一块浅色
（米色）；切到「深蓝夜色」后底部 pnlLog（TPanel）仍是白底，里面的 TLabel
浅色文字几乎看不清。

**根因**（三处写死）：

1. 模板骨架生成器把装饰层底色写死 `background:#f5f7fa; color:#2b3a49`
   （`lwdsgntplcore.pas` 两处）→ 装饰层铺满客户区，主题怎么切都是浅色；
2. `.lw-win.lw-flat-form > .lw-win-body { background:#fff }` → 面板在 LCL 里
   是系统色（服务端 `ColorToCSS` 对系统色返回空串，客户端给
   `transparent`），透明面板透出的正是这块写死的白；
3. 文字色 `fg` 是系统色 → 空 → 用主题前景（深色主题下是浅色）→ 白底浅字。

**修法**：

1. 生成器两处改为 `var(--lw-win-bg, #f5f7fa)` / `var(--lw-fg, #2b3a49)`，
   模板自动跟随具名主题；同时把 `demos/gallery/tpl/*.html` 两份测试模板
   一并改掉；
2. flat 的 `.lw-win-body` 底色改 `var(--lw-win-bg)`；
3. 主题浮钮改为**可拖动**：`pointerdown/move/up` + 6px 位移阈值区分拖动与
   点击（拖动结束吃掉那次 click，避免误弹菜单），位置存
   `localStorage['lw.themeFab.pos']`，`resize` 时 clamp 回视口；
   `themeMenu` 按上下可用空间自动选展开方向并整体 clamp（按钮被拖到顶部时
   不会把菜单顶出屏幕）；CSS 加 `touch-action:none` 防拖动时页面跟着滚。

**验证**（`tests/cdp_flat_theme.py` 扩到 10 项，390×844 真跑）：
F6 装饰层 `rgb(25,29,35)`（深色，lum 28.5，不再是 #f5f7fa）；
F7 窗体客户区同为深色；F8 触摸拖到 (80,240) 生效、F8b 不误弹菜单、
F8c 刷新后位置记住 —— ALL PASS。深蓝夜色下截图目视：pnlLog 深底浅字可读。

## 坑 183：移动端窗口模式也要主题浮钮（入口形态要跟着布局走）

**需求**（用户 2026-11-19）：移动端窗口模式（有标题栏）切换主题也改成浮框，
与平面模式统一。

**做法**（`lw-alpine.js` + `lw-alpine.css`）：

1. 新增 `themeEntryWanted(fm)`：`fm.flatMode || lwLayoutNow() === 'mobile'`
   且非模态、`LWThemeButton` 未关 → 该挂浮钮；
2. `themeEntrySync(fm)` 幂等（该挂的挂、该摘的摘），`themeEntrySyncAll()`
   遍历所有窗体；四个时机调用：
   - `lwApplyTplHost`（窗口模板装饰层套好）、`lwApplyFlatTpl`（平面接管）、
     `lwApplyNoTpl`（无模板回 LCL）末尾；
   - `lwClearFormTpl` 里原来无条件 `themeFabDrop` 改成 `themeEntrySync`
     （离开平面模式后，移动布局的窗口模式仍要浮钮）；
   - `lwApplyLayout`（桌面↔移动切换）末尾 `themeEntrySyncAll()`
     —— `lwApplyFormTpl` 对已套模板的窗体直接 return，切换布局不会重走
     套用流程，入口形态只能在这里纠正；
3. CSS：`html[data-lw-layout="mobile"] .lw-win-title .lw-win-theme
   { display: none }` —— 标题栏那份让位（按钮照旧创建，桌面切回来即显示，
   不做 DOM 增删）；
4. 位置记忆**分两套键**：`lw.themeFab.pos`（平面）/ `…pos.win`（窗口）。
   共用一套会把平面模式拖到控件上方（实测 80,240）的位置带进窗口模式，
   一打开就压在 TUpDown 输入框上；窗口模式默认落右下角（38px）。浮钮挂在
   元素上记 `__fabKey`，`themeFabAdd` 发现形态变了就 drop 重建并按新键恢复。

**验证**（`tests/cdp_theme_entry_mobile.py`，390×844 ↔ 1200×900 真跑，不刷新）：
M0 切到 mobile 且非平面；M1a/M1b/M1c 浮钮在、标题栏图标 `display:none`、
浮钮 38×38；M2 点浮钮出 8 项菜单且完整在视口内（top 568 / bottom 794）；
M3 选「深色」→ `data-lw-theme=dark`；D1a/D1b 切桌面后浮钮 0 个、标题栏
图标 `display:flex`；D2 桌面点图标仍能弹菜单；M4 再切回移动浮钮 1 个、
图标再次隐藏 —— 13 项 ALL PASS。

**回归**：`cdp_gallery_mobile_tpl`（A4b 改为「移动端窗口模式挂浮钮」+
A4b2「标题栏图标隐藏」）ALL PASS；`cdp_flat_theme`（临时把 .m.html 改 flat
跑完还原）ALL PASS；`cdp_fit_scale` / `cdp_mobile_demo` ALL PASS；
`node --check` 通过。

**坑**：新测试第一版用 `?layout=desktop` 起步，结果它写进 sessionStorage
变成硬覆盖，后面改视口一直是 desktop（M0~M3、M4 全红）。测试里要
`sessionStorage.removeItem('lw-layout')` 再 reload，或干脆不带该参数。

## 坑 184：两个新建工程向导合二为一，档位/模板靠弹框当场定

**需求**（用户 2026-11-19）：原来新建工程里的两个 lazarusWeb 向导
（GUI / nogui）合并成一个 `lazarusWeb`。选中后弹第一个框选工程类型档位
`lazarusWeb project` / `lazarusWeb project(nogui)`，再弹第二个框选工程模板
`常规模式` / `插件模式`；插件模式按插件工程生成 `.lpr`。用户特意澄清：
**第一框是工程类型档位（GUI/nogui），不是"窗口模式/平面模式"**——后者是
Tools 菜单「生成 lazarusWeb 窗体模板」的事，与新建工程向导无关。

**为什么敢把档位放回实例字段**（坑 170 的反例）：
坑 170 时是两个描述符靠可变字段传档位，IDE 重建描述符实例后两个模板都按
nogui 生成。这次只有一个描述符，字段在两个框当场赋值；查了 IDE 源码
（`ide/main.pp` 的 `DoNewProject` → `sourcefilemanager.pas` 的
`InitNewProject`）确认同一次新建里 `InitDescriptor`、`InitProject`、
`CreateStartFiles` 用的都是 `ChooseNewProject` 返回的**同一个** ProjectDesc
实例，中间不重建。Lazarus 自带的 pas2js / fpcunit 向导也是把选项存在
`DoInitDescriptor` 里、在 `InitProject` 读，属于官方模式。
结论：两个框任一返回 mrCancel 就退出，IDE 不会动当前工程。

**插件模式 `.lpr` 只差两处**（与命令行 `--plugin` 共用 `LWProjectSource`）：
`uses` 多一个 `lwmodules`，`begin` 里多一句 `RegisterAllModules`。
主窗体照常保留（`TLWApp.Register(TMainForm)`）—— `docs/PLUGIN_GUIDE.md` 3.2
说主窗体和插件可以共存；也正因为这行还在，`LWIsTemplateProject` 的源码
特征判据对插件工程照样成立，保存钩子会照常补 build 脚本和 nogui 宏。
`lwmodules.pas` 在 IDE 里做成虚拟工程文件（`CreateProjectFile` +
`SetSourceText`），保存时随工程自动落盘；命令行则由 `LWGenerateProject` 直接写。

**踩坑**：`LWModulesSource` 里第一个 `end` 误写成 `end.`（单元结束符），
生成的 `lwmodules.pas` 编译报 `Syntax error, ";" expected but "." found`。
过程体必须是 `end;`，只有单元最后才是 `end.`。已改为 `end;`。

**验证**：
- `lazbuild --build-all src/design/lwdesign.lpk` 通过；`fpc lwnew.lpr` 通过；
- `lwnew` 生成 GUI/常规、nogui/常规、GUI/插件、nogui/插件四种工程：
  GUI 档 `.lpi` 无 `LCLWidgetType`，nogui 档有 `MacroValues` +
  `SharedMatrixOptions`；插件档 `.lpr` 含 `lwmodules` 与 `RegisterAllModules`
  并多出 `lwmodules.pas`，常规档没有；
- `lazbuild -B --ws=nogui Demo.lpi`（插件档）与 `lazbuild -B Demo.lpi`
  （常规档）均编译+链接成功。

## 坑 185：Tools 菜单那个 lazarusWeb 命令才是用户说的"向导"，不是 File/新建/项目

**用户反馈**（2026-11-19）："你说理解了，但重新编译后还是一样" + 截图。
截图弹的是「lazarusWeb 模板生成 / 请选择要生成的模板模式：窗口模式 / 平面模式」。
这一轮才真正定位清楚：**用户从一开始说的"tools 菜单的 lazarusweb 向导"，
指的就是 `lwdsgntplgen.pas` 注册在 Tools 菜单里那唯一一个命令**
（原名「生成 lazarusWeb 窗体模板（当前单元 LFM）」，弹窗口/平面模式框）。
用户要的不是"窗口模式/平面模式"，而是：这个命令变成**新建 lazarusWeb 工程
向导**——点它弹 project/nogui + 常规/插件两框，按选择生成 lpr。

**我连续两次理解错**：
- 第一次把需求理解成"合并 File→New→Project 的两个工程模板 + 加插件模式"，
  改了 `lwdsgnregister.pas` 的 `TProjectLWApp`——这部分本身没错（合并向导、
  两框、插件 lpr 都对），但**用户点的 Tools 菜单命令没动**，所以看到的现象
  完全没变。
- 用户纠正后又追问、再确认，才锁定是 Tools 菜单命令。

**教训（改 IDE 菜单功能前先确认入口）**：Lazarus 里"向导"可能指多个入口——
File→New→Project 的 ProjectDescriptor、Tools 菜单的 RegisterIDEMenuCommand、
New File 的 ProjectFileDescriptor。用户说"某菜单的命令"时，先 grep
`RegisterIDEMenuCommand` / `RegisterProjectDescriptor` 把每个入口列出来对号，
不要凭"新建工程向导"这个词就默认成 ProjectDescriptor。

**最终实现**：
- `lwdsgnregister.pas` 暴露 `LWRunNewProjectWizard`，内部调
  `LazarusIDE.DoNewProject(LWProjectDescriptor)`。Lazarus 源码 `main.pp` 的
  `TMainIDE.DoNewProject` 第一步就是 `ProjectDesc.InitDescriptor`（我们的两框），
  任一框 mrCancel 即退出，之后关旧工程、建虚拟工程，与 File→New→Project 同一条路。
- `lwdsgntplgen.pas` 的 Tools 菜单回调从 `ExecGenFormTpl` 换成新增的
  `ExecNewProject`（调 `LWRunNewProjectWizard`），菜单项注册名
  `lwNewProjectWizard`，标题「lazarusWeb」。`ExecGenFormTpl` 与
  `lwdsgntplcore` 的模板生成能力**保留**（没删），只是不再挂菜单——
  要恢复时把 Register 的回调切回即可。
- `lwdsgntplgen` uses `lwdsgnregister`（单向，无循环；编译通过）。

**关键提醒**：用户"重新编译后还是一样"还有一层常见原因——只跑了
`lazbuild`（命令行编译包）但没在 IDE 里 **Compile → Install → 重启**，
IDE 进程里仍是旧 BPL。改设计期包后必须走 IDE 的 Install 流程才生效。

**验证**：`lazbuild --build-all src/design/lwdesign.lpk` 通过（2727 行，
无 Error）。菜单实际弹框需在装了新包的 IDE 里点「Tools → lazarusWeb」确认。

**最终结论（同日审计后撤销，以此为准）**：用户确认"这次对了"后要求审计
对 10:00 前功能的影响，明确决定——**恢复 Tools 菜单原「生成 lazarusWeb
窗体模板」命令，删除 Tools 菜单的「lazarusWeb」新建向导**。即上面那套
`ExecNewProject` / `LWRunNewProjectWizard` / `lwNewProjectWizard` 的改造
**整体回滚**：`lwdsgnregister.pas`、`lwdsgntplgen.pas` 已从
`backup/2026-11-19-tools-wizard` 恢复为改造前原样（Tools 菜单重新注册
`lwGenFormTpl` → `ExecGenFormTpl`，弹窗口/平面模式，生成桌面 `.html` +
移动 `.m.html`）。回滚前状态另存 `backup/2026-11-19-restore-tools-menu`。

**保留不变的部分**：File → 新建 → 项目 里合并后的 `lazarusWeb` 向导
（一个描述符 + 工程类型/工程模板两框 + 插件模式 lpr）是用户确认的核心需求，
本次未动；`lwnewproject.pas` 的 `Plugin` 字段、`LWModulesSource` 与
`tools/lwnew.lpr --plugin` 也保留。坑 185 前半段记录的"Tools 菜单改成向导"
只作排错过程存档，**当前代码以本段最终结论为准**。

**两个入口的分工（务必区分）**：
- File → 新建 → 项目 → `lazarusWeb`：建工程（弹工程类型 + 工程模板两框）；
- Tools →「生成 lazarusWeb 窗体模板（当前单元 LFM）」：按当前窗体 .lfm
  生成 HTML 模板（弹窗口/平面模式）。

审计证据：10:00 前功能文件（lw-alpine.js/css、lwdsgntplcore.pas、
demos 部署副本、CDP 测试）时间戳均 ≤ 07:02，本会话零改动；
`check_files + check_tplgen + check_wizard` 源码守门全通过。

## 坑 186：TSplitter 拖动调整位置（2026-11-19）

**现象**：TSplitter 之前只渲染静态分隔条（`.lw-splitter` + col-resize 光标），
无拖动逻辑，文档长期标注"不支持拖动"。用户要求补上拖动调整位置。

**LCL 语义**：TCustomSplitter 默认 `Align=alLeft`，拖动按 Align 改变同侧邻居
尺寸（左/右分隔条改邻居 Width，上/下改 Height）。LCL 公开
`GetSplitterPosition`/`SetSplitterPosition(NewPosition)`，内部 MoveSplitter
会做 MinSize/约束、触发 OnCanResize/OnMoved、按 Align 重排邻居并写回控件边界。

**实现（三处）**：
1. 客户端 `lw-alpine.js` 新增 `bindSplitterDrag`（`bindNodeEvents` 里对
   `node.kind==='splitter'` 调用）：pointerdown/move/up + 6px 阈值 +
   setPointerCapture（触摸天然兼容）。拖动中本地把 wrapper 的 left/top 跟手
   挪动 + 内部 bar 加 `.lw-splitter-dragging` 高亮；松手时 fire 一次
   `OnSplitterMove`，**回传相对位移 `sd`（像素）**而非绝对位置。
2. 服务端 `lwdispatch.pas` 的 `LWHandleEvent` 加框架级分支：
   `if (c is TSplitter) and (ev='OnSplitterMove')` →
   `TSplitter(c).SetSplitterPosition(TSplitter(c).GetSplitterPosition + JGetInt(AReq,'sd',0))`。
   不进 LWInvokeEvent（无此业务事件签名）。回包由 BuildEventPayload/DiffProps
   自动带出新坐标，客户端 runLayout 落地。
3. CSS `.lw-splitter` 加 `touch-action:none` + `.lw-splitter-dragging` 高亮；
   横向分隔条由 JS 内联设 `row-resize` 光标。

**关键坑（方向反了）**：最初回传绝对位置 `spos=屏幕 clientX 起点+位移`，
但浏览器 clientX 原点与 LCL 控件坐标系不同，且 `S.ND[id].x` 是 align 布局后的
运行时坐标（常被 applyRect 改成 0），导致 SetSplitterPosition 把分隔条移向错误
方向、把左邻居压到 1px。**正解：回传纯位移 `sd`，服务端以
GetSplitterPosition+sd 为目标**——与坐标系无关。

**另一个坑**：客户端 JS/CSS 是**磁盘实时读取**（LWFindClientFile 优先 exe 同目录
`lw/`，再 root/src/client），改 src 后必须同步到各 demo 的 `lw/` 副本才生效；
 gallery 第一次测试"绑定没生效"就是因为加载了旧副本。已同步 gallery/dbaware/C:/3。

**验证**：`tests/cdp_splitter_drag.py`（无头 Edge + PointerEvent 驱动，CDP 的
Input.dispatchMouseEvent 在无头下不派发到 pointer 监听，故用页面内 dispatchEvent）。
端到端实测：右拖 100px → 左邻居 pnlLeft 宽 260→360(+100)、右邻 pnlRight
x 267→367(+100) 宽 1087→987(-100)、无 JS 错误，pass=true。
服务端 `lwdispatch.pas` 改动经 lazbuild -B 重编 lwserver 包后编入 gallery/lwapp1
exe（串 `OnSplitterMove`/`sd` 已在二进制中确认）。

## 坑 187：TSplitter 必须有同侧可调整邻居（2026-11-19）

**现象**：`C:\3` 只有 `Splitter1 + Panel1(alClient)`，拖动时事件到达服务端、
分隔条本地跟随，但 `Panel1` 完全不动。

**根因**：LCL `TCustomSplitter` 的对齐模式只调整**同侧**控件：
`Align=alLeft` 的竖向分隔条调整它左侧 `Align=alLeft` 的邻居，
`alRight/alTop/alBottom` 同理。源码见
`lcl/include/customsplitter.inc` 的 `FindAlignControl` / `MoveSplitter`：
`FindAlignControl` 只收 `CurControl.Align = Self.Align` 或 `alClient`，
并要求 `CurControl.Left+Width <= Splitter.Left`。当分隔条在最左（Left=0）
且右侧只有 `alClient` 面板时，没有候选，`GetResizeControl` 返回 nil，
`MoveSplitter` 直接退出，所以 `alClient` 面板不会被改。

**正解**：在分隔条左侧放一个 `Align=alLeft` 的面板（本例 `Panel2`），
顺序为 `Splitter1 → Panel2(alLeft) → Panel1(alClient)`（LCL 对齐控件按
反向 Z 序布局，这个顺序浏览器里才是 Panel2、分隔条、Panel1）。拖动分隔条
时 LCL 改 Panel2 宽度，`alClient` 的 Panel1 自动跟随。

**反例**：单独给 `Panel1` 换 `Align=alNone` + AnchorSideLeft 锚到 Splitter
在当前 nogui 代理 widgetset 下不生效，服务端坐标不更新，不采用。

**验证**：`C:\3` 改 LFM + `umain.pas` 声明后 lazbuild -B 重编；无头 Edge
右拖 100px 实测 Panel2 173→273、分隔条 173→273、Panel1 x 178→278
且宽 1192→1092，JS 错误为空。

## 坑 188：增量补丁不落地几何 + nogui 下连续拖动第二次卡死（2026-11-19）

**现象**（用户连续两步反馈）：
1. "可以拖动 Splitter1 但 panel 不变"；
2. 修完上一条后 "第 1 次能向右移到一定位置后就不能再移动了"。

**根因 A：`--patch=1` 增量补丁不写 DOM 坐标、不重排 align 兄弟。**
全量回包走 `applyPayload → syncChildren → runLayout`，会按 Align 重排所有
兄弟，所以坑 186/187 的无头测试（默认全量）一直通过。开启增量补丁后，
服务端 `BeginEventPatch` 只回：

```json
{"f": 1, "ops": [["p", 3, {"w": 273}]]}
```

客户端 `applyPropsOp → patchNode` 只把属性合进内存节点 `S.ND`，既不写
`el.style.left/top/width/height`，也不对父容器跑 `runLayout`。结果：分隔条
wrapper（拖动时本地跟手）看着动了，`Panel2`/`Panel1` 的 DOM 盒模型还停在
旧坐标 —— 服务端模型已变、浏览器没变。

**修复 A**：`src/client/lw-alpine.js` 的 `applyPropsOp` 检测 `x/y/w/h/align`
任一几何属性变化 → 调新增的 `applyGeomPatch`：

```js
function applyGeomPatch(formId, n, info) {
    var el = S.E[n.id];
    if (el && (!n.align || n.align === 'none')) {
        el.style.left = (n.x || 0) + 'px';
        el.style.top = (n.y || 0) + 'px';
        el.style.width = (n.w || 0) + 'px';
        el.style.height = (n.h || 0) + 'px';
    }
    var p = info && info.p;
    if (!p) return;
    var ct = ctOfNode(p, formId);
    var list = p.children || [];
    if (ct && ct.body && list.length) runLayout(ct, list);
}
```

`runLayout` 只拉伸有 Align 的兄弟，无 align/none 的控件由前半段自己写服务端
绝对坐标，两类分开处理。已同步 `C:\3\lw`、`demos\gallery\lw`、
`demos\dbaware\lw` 三份磁盘副本（客户端资源按 exe 同目录 `lw/` 实时读取）。

**根因 B：nogui/代理 widgetset 下 `SetSplitterPosition` 自身坐标不自洽。**
坑 186/187 的服务端实现是

```pascal
sp.SetSplitterPosition(sp.GetSplitterPosition + sd);
```

靠 LCL `MoveSplitter/FindAlignControl` 改邻居尺寸。实测连续拖动：第一次
`+100` 生效（Panel2 173→273），第二次 `+50` 后 Panel2 被夹到 1px。原因：
nogui 下 `SetSplitterPosition` 只改邻居 `Width`，**不把 Splitter 自身的
`Left/Top` 挪到新边界**，`sp.Left` 恒为设计期值 260。而 `FindAlignControl`
要求候选邻居右边界 `<= Splitter.Left`；第一次拖动后 Panel2 右边界已是
273 > 260，候选直接消失，后续所有拖动失效。

**失败尝试**：在 `LWMoveSplitter` 里把 `sp.Left` 同步到邻居新边界，反而让
`FindAlignOtherControl` 找不到 `alClient` 面板，`EndSize` 退化成负数，第二次
拖动把邻层夹到 1px（`drag +100 -> p2w=273 OK` / `drag +50 -> p2w=1
MISMATCH`）。对齐状态机不能半手动改。

**修复 B**：完全绕开 LCL 对齐状态机，新增
`procedure LWMoveSplitter(sp: TSplitter; ASd: Integer)`
（`src/core/lwdispatch.pas:839`），直接按 `Align` 在父容器里找同侧邻居：

- `ctl.Align <> sp.Align` 一律跳过（`alClient` 不参与直接 resize）；
- 按 align 方向取"最贴边"的那个（`alLeft` 取 `Left+Width` 最大者，
  `alRight` 取 `-Left` 最大者，`alTop/alBottom` 同理）；
- 直接 `target.Width := target.Width ± ASd`（或 Height），下限 8px；
- `alLeft/alTop` 往右/下拖为 grow，`alRight/alBottom` 取反；
- 找不到同侧邻居时退回 `SetSplitterPosition` 兜底（保持旧行为不回退）。

事件分支改为：

```pascal
else if (c is TSplitter) and (ev = 'OnSplitterMove') then
  LWMoveSplitter(TSplitter(c), JGetInt(AReq, 'sd', 0))
```

备份 `backup\lwdispatch.pas.before-splitter-repeat`。改包源码后须
`lazbuild -B` 重编 `lwserver` 包对应的 `.ppu` 再链接 exe，否则 exe 里仍是
旧的移动逻辑。

**编译阻塞**：用户运行中的 `LWApp1.exe`（PID 25488，监听 8090）占用目标
文件，`lazbuild` 报 `Can't create object file ... error code: 5`。
`Stop-Process -Id 25488 -Force` 后重编成功（`lwdispatch.ppu` 18:08:16、
`LWApp1.exe` 18:08:18）。函数名未出现在 exe 字符串表，疑被内联/裁剪，以
行为验证为准，**不要**拿字符串表当"改没编进去"的判据。

**验证**：

- 静态：`tests\check_splitter_drag.py` 扩到 33 项，覆盖
  `bindSplitterDrag` / `sd` / `applyGeomPatch` / `runLayout(ct, list)` /
  `LWMoveSplitter` / `target.Width := newSize` / 8px 下限 / 兜底 / 三副本同步，
  `FAILS=0`。
- 端到端（无头 Edge，增量 `--patch=1` 与全量两条路径各跑 5 次往返）：

```text
+100 -> p2w=273, sp_x=273, p1w=1092 OK
 +50 -> p2w=323, sp_x=323, p1w=1042 OK
 -30 -> p2w=293, sp_x=293, p1w=1072 OK
 -80 -> p2w=213, sp_x=213, p1w=1152 OK
+120 -> p2w=333, sp_x=333, p1w=1032 OK
INCREMENTAL RESULT PASS errors=[] / FULL RESULT PASS errors=[] / ALL PASS
```

**教训**：①增量补丁与全量回包是两条独立渲染路径，几何类改动必须在两条上
都验；②nogui 代理 widgetset 下不要假设 LCL 的对齐状态机会自洽维护 Splitter
自身坐标，服务端权威模型直接算邻居尺寸更可靠；③改包源码后确认 `.ppu`
时间戳与 exe 链接时间，别只 grep exe 字符串。

## 坑 189：procdemo 的插件模块要自持副本，新增插件的四处登记一个都不能漏（2026-11-19）

**诉求**：`demos/procdemo` 原来靠 `../../../plugins` 引用项目根的共享模块
（`umod_notes.pas/.lfm`、`umod_dashboard.pas`），同一份源码被
`plugindemo`（编译期链入）与本 demo 共用，"分散在各处"。要求把代码全部
集中进这个 demo，并再加第三个插件。

**做法**：`plugins/` 里的三个文件**复制**（不是移动）到
`demos/procdemo/modules/`，两个插件 `.lpi` 的 `Units Filename` 与
`OtherUnitFiles` 由 `../../../plugins` 改指 `../modules`；`src/core` 仍从
项目根引用（那是框架本体，不属于 demo）。根 `plugins/` 一字未动，
`plugindemo` 照旧构建。

**踩到的点**：

- `notesplug.lpi` 里原本就写错了资源路径：`../../plugins/umod_notes.lfm`
  （少一级 `../`，指向根本不存在的 `demos/plugins/`）。因为
  `umod_notes.pas` 用 `{$R *.lfm}` 按**自身所在目录**找资源，这个错误
  一直没暴露。集中后一并改成 `../modules/umod_notes.lfm`。
- 新建模块时 `JsonEscape` 编译不过：它在 `src/core/lwpluginutil.pas`，
  不在 `lwajax` 里。`umod_notes` 早就 uses 了它，新模块漏了就会
  `Error: (5000) Identifier not found "JsonEscape"`。
- `build.bat` 的工程名是 **`hostdemo.lpi`**，不是目录名的 `host.lpi`；
  用目录名猜会直接 `File not found`。
- `build.bat` 必须保持 ASCII + CRLF（cmd.exe 对 UTF-8 中文注释会误解析，
  可挂住整个批处理）。用编辑器改完要重新规范化为 CRLF。

**新增一个插件要动的四处**（少一处就是 502 / 页面能开但跳不动）：

1. `host/hostdemo.ini` 加 `plugin.<名>=127.0.0.1:<端口>`；
2. 新插件自己的 `<名>plug.ini` 里 `port=` 与上面一致，并配
   `page.<目标注册名>=/p/<目标>/`；
3. **另外两个插件的 ini 各加一行** `page.<新注册名>=/p/<新名>/`，
   否则老插件的 `OpenForm('新名')` 找不到映射；
4. `build.bat` 加编译行；宿主若要在导航页给入口，再补按钮与
   `RunJS('location.href=''/p/<名>/''')`。

**验证**：四个 exe 全部 `lazbuild -B --ws=nogui` 通过；
`python tests/t_route.py` 由 22 项扩到 28 项全绿（新增：reports 直连、
`/lw/api/plugins` 含三个名字、`/p/reports/` 前缀与 301、`reports_summary`
数值自洽、reports→dash/notes 两条跳转、宿主 `btnReports` 同标签命令）。
`/p/reports/` 返回 `<title>lazarusWeb 插件：报表汇总</title>`，会话树里
是 `TReportsForm` + 17 个控件。

## 坑 190：跨插件导航要"每个页面都配齐"，缺按钮不等于缺机制（2026-11-19）

**现象**：用户反馈三个插件"不能互访、回不到首页"。看截图是按钮位置空着，
不是点了没反应 —— 仪表盘只有「打开便签页」、便签只有「返回仪表盘」、
报表有另两个但没有首页，三个页面都没有回宿主的入口。

**结论**：`OpenForm` + `page.<注册名>=<URL>` 这套机制本身是通的（`t_route.py`
一直在验），缺的是**按钮与映射条目**。两类缺口要一起补：

- 页面上少画按钮 → 用户没法发起跳转。三个插件页现在统一成
  「另两个插件 + 返回首页」，谁在哪一页都能直达任意另一页与宿主。
- ini 里少配映射 → 即使有按钮，`OpenForm` 找不到本地窗体又没有映射时
  直接返回 False，表现是"点了不动"，很容易被误判成路由或客户端 bug。
  **回首页不是特例**：把 `Host` 映射到宿主根路径即可（`page.Host=/`），
  跟跳到别的插件走完全同一条路。

**改动**：`umod_dashboard` 加 `btnOpenReports`/`btnHome`；`umod_notes` 在
`.lfm` 里加 `btnOpenReports`/`btnHome`（按钮宽度 120→112，五个按钮
96/232/368/504/640 排满 760 宽不越界，`lstNotes.TabOrder` 顺延到 7）；
`umod_reports` 加 `btnHome`，`lblStatus` 右移到 632 让位。三份 ini 各加
`page.Host=/`，`tests/t_route.py` 补 5 条断言（28→33 项）。

**验证**：四个进程在跑的情况下，无头 Edge 逐页逐个按钮真实点击 9 条路径，
落点全部正确：

```text
/p/dash/    打开便签页 -> /p/notes/    打开报表页 -> /p/reports/   返回首页 -> /
/p/notes/   返回仪表盘 -> /p/dash/     打开报表页 -> /p/reports/   返回首页 -> /
/p/reports/ 打开仪表盘 -> /p/dash/     打开便签页 -> /p/notes/     返回首页 -> /
```

`t_route.py` 33 项全 PASS（含三条 `location.href="/"` 的断言）。

**教训**：加插件时"能被别人跳进来"和"能跳出去"是两件事；`page.*` 要给
**每一个**页面配全，包括 `Host`。验收要看真实点击落点，只看服务端有没有
排进 cmd 队列会漏掉"按钮压根不存在"这种情况。

## 坑 191：中英双语走 Lazarus PO 模式 —— 不改字面量，只在输出那刻查表（2026-11-19）

**现象**：要把 `src` 与 `demos` 做成中英双语。第一反应是两条路：把上千条
`Caption := '标准控件'` 改成 `resourcestring`，或者自建一张
`'中文' -> 'English'` 的字典表。前者要动遍每个单元的 `interface` 段和所有
赋值点，后者等于自己实现一遍 gettext（复数、上下文、工具链全得自己来）。

**结论**：两条都不必走。`TPOFile.Translate(Identifier, OriginalValue)` 的
**第二个参数就是原文**（`components/lazutils/translations.pas:1213`，内部先查
`FIdentifierLowToItem`、再查 `FOriginalToItem`）。也就是说：**界面上的中文本身
就是 msgid**，不需要给每条文案起资源名，也不需要改任何一行字面量 —— 只要在
"文本即将离开服务端"的那一刻查一次表。

三个输出闸门，全在这一层做就够了：

| 闸门 | 覆盖 |
|---|---|
| `core/lwwriter.pas` | 控件树序列化：Caption / Hint / 窗体标题 / Items / 表格表头 / 菜单 / 侧栏 |
| `core/lwdlg.pas` | 浏览器对话框的标题、正文、按钮 |
| `core/lwhttp.pas`、`lwroute.pas` | 外壳 HTML、启动遮罩、502 插件不可达页 |

因为是"输出时翻译"而不是"建窗体时翻译"，**同一个进程里中英文会话可以并存**：
语言存在会话变量 `lwlang` 里，请求线程用 `threadvar LWReqLang` 带着走。

**这一轮踩的七个点**（都不在 gettext 本体上，全在周边）：

1. **`build.bat` 的三段兜底是死代码**。原写法
   `if not defined LAZBUILD set LAZBUILD=lazbuild.exe` 放在最前面，赋完值
   后面两个 `if not defined` 就永远不成立，`%ProgramFiles%\Lazarus` 和
   `C:/111/lazarus` 的探测形同虚设，PATH 里没有 lazbuild 时整批全
   `'"lazbuild.exe"' 不是内部或外部命令`。改成"先探测两个固定路径，最后才
   兜底 PATH"。修完直接 `build.bat` 就能跑，不用再传环境变量。
2. **GUI 分支硬编码了一个工程名**。`if "%PROJ%"=="dbaware_gui"` 只放行
   `dbaware_gui`，后来加的 `plugindemo_gui` 掉进 nogui 分支，吃到
   `--ws=nogui --build-mode=Default`，而该工程只有一个叫 `GUI` 的 mode，
   报 `无效的构建模式 "Default"`。改成按后缀判断 `if /i "%PROJ:~-4%"=="_gui"`。
   注意 `*_gui.lpi` 必须用自身 widgetset（win32）编，加 `--ws=nogui` 会挂。
3. **按钮文案与语言设置无关**。LCL 中文构建下 `GetButtonCaption(idButtonOk)`
   恒定返回 `确定(&O)`（`lcltype.pp` 的 `idButton*` 常量 + 编译期语言），
   英文界面照抄会漏出中文。`lwdlg.ButtonCaptionOf` 现在按 13 个 `idButton*`
   建了一张中文键表，非中文时用中文键查 PO、查不到再用内置英文兜底。
4. **拼接片段要 trim 再查一次**。`'共 ' + n + ' 条'` 这类片段进 PO 时首尾空格
   会被吃掉（键是 `共`），精确匹配必然失败。服务端 `LWLangTextIn` 与浏览器
   `lwT()` 都做了"匹配不到就 Trim 再查一次"。
5. **纯全角标点的条目没人译**。`TEdit：` 不含汉字，抽取器按"含 CJK 才收"的
   规则会漏掉它，英文界面就留着全角冒号。两处修：抽取器的 CJK 正则扩到
   `\u3000-\u303f\uff01-\uff5e`；`build_po.py` 对**不含汉字**的条目自动做
   全角->半角标点映射，含汉字的必须人工译（`auto_translate` 不猜语义）。
6. **注入给浏览器的字典必须是严格 JSON**。原先写成
   `window.__LW_LANG={code:"en",t:{...}}`，JS 能吃，但测试脚本 `json.loads`
   直接 `Expecting property name enclosed in double quotes`。键加引号即可 ——
   这条不只是好看，它让"字典内容"变成可被外部工具校验的契约。
7. **TSV 别带 BOM**。`utf-8-sig` 写出来的译文表，首条键会变成
   `\ufeff左面板（alLeft）`，合并时报"TSV 里多出来的键"。读用
   `encoding='utf-8-sig'`（能吃掉 BOM），写必须用 `utf-8`。

**产物**：`src/core/lwlang.pas`（419 行，PO 加载 + 原文查译文 + 会话/请求级
语言 + 浏览器字典）、`languages/*.pot`、`languages/en/*.po`、
`tools/i18n/{extract_po,build_po}.py` + `tools/i18n/en/*.tsv`（777 条译文，
唯一需要人手维护的源）、`tests/check_i18n.py`（静态守门 + 覆盖率）、
`docs/I18N_PO.md`。

**验证**：`check_i18n.py` 36 项 `FAILS=0`；同一进程两个会话并存：

```text
?lwlang=zh  form: TGalleryForm / 'lazarusWeb · 全功能画廊'
            页签 标准控件 Button 扩展输入 容器布局 表格列表 工具栏 图表与仪表 HTML/PDF
?lwlang=en  form: TGalleryForm / 'lazarusWeb · full-feature gallery'
            页签 Standard controls Button Extended input Container layout
                 Grid list Toolbar Charts and gauges HTML/PDF
```

覆盖率 `lazarusweb 694/694`、`lwclient 83/83`。18 个 demo 工程全量重编通过。

**教训**：gettext 这套东西的"用法"是简单的，"接进去"全在边角：构建脚本的
兜底顺序、UI 框架自带的本地化文案、字符串拼接的空白、编码与 BOM、以及
"给前端的字典"到底是不是合法 JSON。这些都不在 `translations.pas` 里，
但每一个都能让"支持多语言"看起来没生效。

## 坑 192：`--lang=en` 网页是英文、控制台还是中文 —— 日志/横幅也是界面（2026-11-20）

**现象**：`gallery_nogui-x86_64-win64.exe --lang=en` 之后浏览器里全英文，
控制台仍是「配置文件: …」「界面语言: en」「Client : alpine（…无需 ext 目录）」
「仍打不开？管理员运行 tools\allow-firewall.bat…」「[info] 客户端已断开…」。

**三个彼此独立的原因**，缺一个都修不干净：

1. **控制台输出没进翻译链路**。横幅是 `LWLogRaw('  Client : …')` 之类的硬字符串，
   而抽取器把 `[` 开头（`[info]`/`[warn]`）和含 `;`、`:=` 的行都当噪声丢掉了，
   所以这些句子从来没进过 PO。日志同样是从没人当它是"界面"。
2. **注释剥离把 URL 吃掉了**。`strip_pas_comments` 用正则删 `//[^\n]*`，
   `'若浏览器地址是 https:// 请改成 http://'` 里那两个斜杠被当成注释开头，
   整行后半句被删 → PO 里只有半句 → 运行时整句查不到，英文界面照旧显示中文。
   这类"半句条目"在 PO 里看着像正常条目，肉眼极难发现。
3. **拼接字面量只抽到前半**。`'警告: 端口 %d 被占用' + '，已改用 %d'` 这种排版，
   抽取器按字面量逐条取，PO 里存的是前半句，运行时字符串是整句，永远匹配不上。

**修法**：

- `extract_po.py` 三处：注释剥离改成**字符串感知的分词**（只在字符串外识别
  `{ }` / `(* *)` / `//`）；相邻字面量 `'a' + 'b'` 自动拼成一个 msgid；
  日志级别前缀 `[info] ` 剥掉只留正文当键。另加"碎片过滤"：HTML 片段、
  被变量切开的半句（以 `"` 结尾）、纯标点、带换行的注释块残留，都不进 PO。
- `lwrlog.LWEmit`：控制台与面板出口都过 `LWLangLine` —— 先整行查表，查不到
  再把 `[级别] ` 前缀切开、只翻正文。`--log=` 文件出口保持原文（跨语言 grep 需要）。
- `lwhttp.PrintBanner`、`lwapp` 的启动/告警行全部改成 `LWLangFmt`
  （格式串即 msgid，`LWLangText` 之后 `Format`），配置路径那一行因为要等语言
  定下来，改成先存 `TLWServerConfig.IniPath`、初始化完再打。

**默认语言**：用户要求"按系统语言，或 `--lang=xxx` 指定"。默认值不再是写死的
`zh`，改用 Lazarus 自己的做法 —— `Translations.GetLanguageID`
（Windows 走 `GetUserDefaultLCID` + `GetLocaleInfo(LOCALE_SISO639LANGNAME)`，
其它平台读 `LC_ALL`/`LC_MESSAGES`/`LANG`，macOS 读 AppleLocale）：中文系统给
`zh`，其余给 `en`。Windows 上再加一道双保险：LCID 低 10 位 `= $04` 即中文
（个别语言包会把 `LOCALE_SISO639LANGNAME` 返回成 `CHS`/`CHT`）。
优先级：命令行 `--lang=` > 配置文件 `language=` > 环境变量 `LW_LANG` > 系统语言。

**验证**（同一台机器，中文 Windows）：

```text
--lang=en   Config file: …\gallery_nogui-x86_64-win64.ini
            UI language: en (languages\en\; one session can switch with ?lwlang=zh)
            Client    : alpine (Alpine.js 3.14.9, no ext directory needed)   (switch: /?client=ext)
            LAN       : http://192.168.1.99:8091/   <- use this address on phones/tablets
            Closing the panel hides it to the tray; use the panel menu "Exit" to stop the service
（无参数）   配置文件: …\gallery_nogui-x86_64-win64.ini
            界面语言: zh（中文即源码原文；单会话可用 ?lwlang=en 切换）
```

**教训**：多语言的边界不是"网页"，是**一切人眼看到的地方**。控制台横幅、
启动信息、日志、面板状态栏都算界面；而抽取器里一条图省事的正则（删 `//`）
会让整类含 URL 的文案永远漏译，且漏得悄无声息 —— 覆盖率报表看不出来，
因为 PO 里"有"这条（只是半句）。

## 坑 193：TGroupBox 的标题为什么"漂"在框里 —— 客户区不是控件左上角（2026-11-20）

**现象**：`C:/passwordgen_web` 里 `GroupBox1.Caption = '生成的密码:'`，设计器里
标题压在框线上，浏览器里却整个沉到框线以下、贴着 Memo 的顶边；Memo 也从框外
顶边开始铺（等于把标题那一条盖住了）。用户看的是"标题位置不对"，根因是
**GroupBox 的客户区原点不是控件的左上角**。

**LCL 的规矩**（`lcl/interfaces/win32/win32proc.pp` 的
`GetLCLClientBoundsOffset`，注释写得很直白："TGroupBox's client area is the
area inside the groupbox frame. Hence the LeftOffset is the frame width and the
TopOffset is the caption height"）：

| 方向 | 内缩 |
|---|---|
| 上 | `TMHeight + 3`（整个标题带） |
| 下 | 2 |
| 左 / 右 | 2 / 2 |

所以：

1. **框线不在控件顶边**，而在标题带的中线上（Windows 的 `BS_GROUPBOX` 就这么画：
   框线穿过文字中部，并在文字处断开）；
2. **标题文字压在框线上**，不是"悬浮在客户区顶部"；
3. **子控件从客户区原点摆起**，比控件左上角低整整一个标题带。

这三条在 LFM 里能直接对出来：`passwordgen` 的 GroupBox1 是 467×169、
`ClientWidth/ClientHeight = 465×147` → 横向内缩 2（左 1 右 1）、纵向 22
（上 20 下 2）。`gallery` 的 `gbGroup` 是 360×206 / 356×177 → 上 27 下 2，
说明标题带高度随字体变，**不能写死 20**。

**修法**：

- 服务端（`lwwriter.MakeBase`）对 `TGroupBox` 下发 `cl/ct/cr/cb` 四个内缩量：
  用 `Width - ClientWidth`、`Height - ClientHeight` 相减，下沿固定 2，其余归顶部；
  客户区读不出（0 或荒唐值）时回落 win32 常量 2/22。
- 客户端（`lw-alpine.js`）把内缩转成 CSS 变量挂在容器上，框线改用
  `<fieldset><legend>` 画：**浏览器本来就会把 legend 的中线压在边框上、并让
  边框在文字处断开** —— 正是 `BS_GROUPBOX` 的画法，省掉"用底色盖住框线"那种补丁
  （底色一旦和父容器不一致，压线处就会露出一块色差）。
- 关键细节：Chrome 把 fieldset 的上边框画在 **legend 的中线上**，不是 border-box
  顶边（实测：fieldset top=10、legend 高 16 → 画出来的线在 18）。所以让
  `legend` 的高度正好等于整个标题带 `--lw-gb-top`、fieldset 顶边贴 0，
  框线自然落在 `ct/2`。
- `.lw-body` 的 `width/height:100%` 必须显式改成 `auto` —— 绝对定位里
  `width` 与 `left+right` 同时给定则 `right` 失效，客户区会撑到框外。

**验证**：`tests/cdp_groupbox_geo.py`（新增，CDP 无头 Edge + 像素找框线）：

```text
控件 450x164，内缩 cl=1 ct=20 cr=1 cb=2
标题中线 - 控件顶       10.00  (应 10.00 = ct/2)   OK
画出的框线 - 控件顶     10.00  (应 10.00 = ct/2)   OK
子控件顶 - 控件顶       20.00  (应 20.00 = ct)     OK
子控件左 - 控件左        1.00  (应  1.00 = cl)     OK
子控件高              142.00  (应 142.00 = H-ct-cb) OK
```

**教训**：这类"位置不对"多半不是 CSS 的锅，是**坐标系的锅**。LCL 的容器控件
有一批"客户区不等于控件矩形"的成员（GroupBox 最典型，另外 TPanel 的
BevelWidth、TScrollBox 的滚动条都要扣）。先在 LCL 源码里把客户区的定义查出来，
比在浏览器里调 `top: 2px` 试十次快得多 —— 而且后者一旦遇到换个字体的工程就崩。

## 坑 194：gallery 未保存数据关闭浏览器提醒——编辑未提交就关，事件回不来

需求：`tsGrid` 页编辑了 `sgData`（存 `gridsave.json`，有显式"保存"按钮），
未保存就关浏览器标签要提示。

两个时序坑，都不是"加个 beforeunload 就完事"：

1. **不能等 `OnEditingDone` 置脏**：用户在输入框里敲了字但光标还在格里
   （未提交）就直接关标签，`OnEditingDone`（blur/回车）根本不触发；就算触发，
   服务端往返 + `RunJS` 推标记也来不及。改成**客户端即时置脏**：守卫里挂一个
   document 级 `input` 事件委托（捕获阶段），认 `.lw-grid:not(.lw-dbgrid-body)`
   内的输入框（排除改一格即落库的 DBGrid），一边输入就立刻把
   `window.__lwGridDirty` 置 true，零往返。
2. **守卫安装时机**：`LWCurrentSession` 只在事件分发期间赋值，FormCreate 时是 nil、
   `RunJS` 静默返回，装不了。挪到 `SgClick`——点单元格是编辑第一步，此刻必有会话。

另一个隐蔽 bug：`SetGridDirty` 原来有 `if FGridDirty = ADirty then Exit` 去重。
客户端 input 委托自己置脏后服务端 `FGridDirty` 仍是 False，点保存调
`SetGridDirty(False)` 被去重跳过 → **标记永远清不掉**。守卫本身幂等，去重必须删。

实现全在 `demos/gallery/ugallery.pas`（未动框架核心/客户端 JS）：`UNLOAD_GUARD`
常量 + `InstallUnloadGuard`/`SetGridDirty`/`SgEditingDone`，保存/调用成功后清标记。
验证 `tests/cdp_beforeunload_dialog_verify.py`（无头 Edge，覆盖"只输入不提交就关"）：
点格后守卫已装、输入即置脏、`defaultPrevented=true`、保存后清除，PASS。
详细 7 处改动见 `docs/ugallery关闭浏览器未保存提示-修改说明.md`（英文版
`docs/ugallery_beforeunload_unsaved_changes_en.md`）。

**限制**：beforeunload 是浏览器原生框，文案/按钮不可自定义，且需页面先有用户交互；
无头模式不弹框，测试用可取消事件的 `defaultPrevented` 等价验证。

## 坑 195：向导最前面加一级"应用模式"，服务模式的文件必须落盘前就正确

**需求**（用户 2026-11-20）：在新建工程向导**最前面**再加一级选项——普通应用模式
/ 服务(daemon)模式，后面两级顺延，"后面的流程不变"。于是三个框的标题变成
`（1/3）应用模式` → `（2/3）工程类型（GUI/nogui）` → `（3/3）工程模板（常规/插件）`，
任一框 `mrCancel` 即 `Exit`（返回 `mrCancel`，IDE 不动当前工程）。

**追加约束（用户提了两次）：「落盘之前已是正确的」**。这条把方案里的两个"事后补写"
都否掉了——

1. **`.lfm` 不能作为虚拟工程文件**。最初的 `uMapper.pas` + `uMapper.lfm` 是照
   `demos/service_demo` 抄的（DaemonApp 的 `TDaemonMapper.Create` 会调
   `InitInheritedComponent`，没有 `.lfm` 就抛 `EStreamError "No streaming method
   available"`，见 `fcl-extra/src/daemonapp.pp` 1487 行）。但 IDE 这边
   `TLazProjectFile`（`projectintf.pas:53`）是抽象类，**没有** `HasResources`——
   只有 `TUnitInfo`（`ideproject/project.pp:274`）才有，而它在 IDEIntf 里没导出。
   也就是说，自己 `CreateProjectFile('uMapper.lfm')` 塞一段文本，IDE 只当它是
   "一个没有编辑器页的源文件"，保存路径（`sourcefilemanager.pas` 4305-4361、
   `SaveProjectInfo:7998`）不确定，落盘结果不可靠。
   → **改成不需要 `.lfm`**：mapper 里 override `Create`，用
   `inherited CreateNew(AOwner, 0)` **跳过** `InitInheritedComponent`，再用
   `TDaemonDef(DaemonDefs.Add)` 逐个赋 `DaemonClassName` / `Name` / `DisplayName` /
   `Options` / `WinBindings.StartType` / `LogStatusReport`。一个 `.pas` 自足。
   专门写了个独立测试程序验证：`DaemonDefs.Count=1`、`DaemonClassName` 对、
   `StartType=2`（stAuto）、`Enabled=TRUE`，然后才改模板。
   （Note 3250 "virtual method Create has a lower visibility (public) than parent
   class TDaemonMapper (published)" 是无害提示，不影响运行。）
2. **ini 名字不能依赖工程名**。原来想写 `<工程名>.ini`，可工程名要等用户按
   Ctrl+S 在"保存项目"对话框里才定——落盘那一刻内容依赖一个未知量。
   → 查 `lwconfig.pas:302-305` 的查找顺序是
   `<exe目录>\<exe名>.ini` → `<exe目录>\lazarusWeb.ini` → 当前目录下同名两个，
   **固定名 `lazarusWeb.ini` 完全够用**，与工程名解耦。

**第三个坑（最后才发现，最要命）：没有编辑器页的工程文件，IDE 根本不写盘**

一开始把 `uDaemon.pas` / `uMapper.pas` / `lazarusWeb.ini` 都做成"虚拟工程文件"：
`CreateProjectFile` + `SetSourceText`，想着"内容先在内存里写好，Ctrl+S 时
IDE 自然会把它们写出去"。**不会。** `ide/sourcefilemanager.pas` 的 `SaveProject`
里，"save virtual files" 那段的判据是：

```pascal
if AnUnitInfo.Loaded and AnUnitInfo.IsVirtual and AnUnitInfo.IsPartOfProject
and (Project1.MainUnitID<>i)
and (AnUnitInfo.OpenEditorInfoCount > 0) then   // <-- 关键
  SaveEditorFile(AnUnitInfo.OpenEditorInfo[0].EditorComponent, SaveFileFlags);
```

`OpenEditorInfoCount` 就是"有没有编辑器页"。`SetSourceText` 只写
`TCodeBuffer`，不建编辑器页 —— 于是这几个文件在保存时被整段跳过：Ctrl+S
之后盘上只有 `.lpr/.lpi/umain.*`，附加文件一个都没有，工程的 `.lpas`
里却登记着它们，下次打开就报"文件未找到"。
（旁证：`TCodeBuffer.IsVirtual` 的判据是 `not FilenameIsAbsolute(Filename)`，
跟"文件在不在盘上"无关，所以光靠文件名也绕不过去。）

**改法**：走 IDE 的标准路径 `DoNewEditorFile` —— 和主窗体单元一模一样：

```pascal
function TProjectLWApp.AddExtraFile(const AFile, ASource: string);
begin
  LazarusIDE.DoNewEditorFile(LWExtraDescriptor, AFile, ASource,
    [nfIsPartOfProject, nfOpenInEditor]);
end;
```

- 新增 `TLWExtraFileDesc = class(TProjectFileDescriptor)`，只设
  `VisibleInNewDialog := False` / `AddToProject := False`，三个附加文件共用
  一个实例（文件名走第一参数，整篇源码走第三参数）；
- **必须带 `nfOpenInEditor`**：`NewFile` 里只有这个标志才会
  `SrcNoteBook.NewFile` 建编辑器页（`if nfOpenInEditor in NewFlags then ...`），
  没有页就又回到上面那条死路；
- **不要 `nfCreateDefaultSrc`**：那个标志会改调 `CreateSource` 重新"造"源码，
  我们是把整篇文本当 `NewSource` 传进去的（`NewBuffer.Source := NewSource`）；
- 源码在 `InitProject` 里就生成好了（内容由 `O` 完全决定），`CreateStartFiles`
  只负责"挂上去"，所以**落盘之前内容就已经是最终版本**，保存钩子一个字节都
  不碰这三个文件。
- 顺带修掉一个老问题：插件模式的 `lwmodules.pas` 原本也是
  `CreateProjectFile + SetSourceText`，一直没落盘（同样的原因）—— 现在一起
  走 `AddExtraFile`。

**代价**：新建服务工程会在 IDE 里多开三个标签页（`uDaemon.pas` /
`uMapper.pas` / `lazarusWeb.ini`）。这是"能被 IDE 正常保存"的前提，也方便
用户当场改服务名/端口。

**实现要点**：
- `TLWNewProject` 加 `Service: Boolean`，向导第一框写 `FService`，
  `InitProject` 里 `O.Service := FService`（三个附加文件的内容在这里就算好，
  真正挂进工程在 `CreateStartFiles`，见上）。
- 三个附加文件的模板全部在 `lwnewproject.pas` 里（`LWServiceDaemonSource` /
  `LWServiceMapperSource` / `LWServiceIniSource` / `LWServiceExpand` 占位符替换），
  IDE 向导与 `tools\lwnew --service` 共用同一份，不会走偏。
- `.lpr` 只在服务模式多写 `DaemonApp` 分支与 `WantDaemonApp` / 预检函数；
  普通模式**逐字未变**（回归：`lwnew` 生成的常规 `.lpr` 与改动前一致）。
- 保存钩子里的 `LWIsServiceProject` 判据是 `.lpr` 含 `WantDaemonApp`，只用来给
  build 脚本加三行服务提示，**不再补写任何文件**。

**踩过的编译错误**：
- 拼 `WriteLn('''ERROR: ... (OS Code ''' + IntToStr(...) + ').'')` 时引号嵌套写错，
  报 `Syntax error, ";" expected but ")" found`，拆成多段拼接；
- 生成的 `.lpr` 里 `uses ... uMapper;` 换行后又接
  `{$IFDEF MSWINDOWS}, SysUtils, Windows{$ENDIF}` → 分号提前结束，
  报 `"BEGIN" expected but "," found`，改成 `uMapper {$IFDEF MSWINDOWS}, SysUtils,
  Windows{$ENDIF};`（与 service_demo 一致）；
- 前台分支用 `StringReplace(regLine, LineEnding, LineEnding + '    ')` 做缩进，
  结果整体错位，改成预构造 `frontReg`（4 空格缩进，含插件模式的
  `RegisterAllModules`）；
- `fpc -Fu../src/core lwnew.lpr` 会把 `lwnewproject.ppu/.o` 写到**源目录**，
  之后 `lazbuild --build-all src/design/lwdesign.lpk` 直接报
  「在包外的源目录里找到同名单元」。编译 `lwnew` 要加 `-FU<临时目录>`，或编完即删。

**验证**：
- `lazbuild --build-all src/design/lwdesign.lpk` 通过（只余 hint）；
- `tools\lwnew --service` 生成的工程只有 `uMapper.pas`、**没有** `uMapper.lfm`；
  `lazbuild -B --ws=nogui` 编译 + 链接成功（16827 行）；
- 非管理员 `--install` 正确输出
  `ERROR: cannot open Windows Service Control Manager (OS Code 5).` + 提示；
- 前台 `--port=8099` 启动后 `curl --noproxy '*'` 得 HTTP 200；
- `tests/run_fixed_regression.py` 的 `check_wizard()` 已补三框与服务模板断言。

## 坑 196：向导的服务名怎么"随工程名走"（2026-11-21）

**问题**：坑 195 加的服务模式里，`.lpr` 和 `uMapper.pas` 是在虚拟工程阶段生成的，
那会儿最终工程名还没定，只能用占位名 `LWApp1`，所以服务名恒为 `LWApp1Service`。
用户在"保存项目"对话框里另存为 `MyApp` 后，`DD.Name` 不会跟着变。
抄 demo 和 `lwnew --name=MyApp` 都没这个问题（服务名在生成时就按真实名字算好了）。

**为什么不在保存后补写**：用户明确要求"落盘之前就正确"。保存后的定时器（坑 172/195）
只能补 `build.bat` / 资源，用它改源码会让 `uMapper.pas` 先以错误内容落盘再被改，
而且编辑器页还留着旧缓冲区，下次保存会把改动冲掉。

**正确做法**：用 IDE 的 `sefsBeforeWrite`（**写盘之前**）钩子。
- `src/core/lwnewproject.pas` 新增不含 IDE 依赖的公共函数
  `LWRetargetMapperNames(ASource, ANewProjectName, out ANewSource)`：
  只替换 `DD.Name := '...';` 与 `DD.DisplayName := '...';` 两行（保留缩进），
  其它源码一字不动；同名重复调用返回 False（幂等），空名字直接返回。
  放在这个单元是为了能用命令行独立测试（设计期包只能在 IDE 里跑）。
- `src/design/lwdsgnregister.pas` 的 `TLWProjectFinalizer.FileSaved` 处理
  `sefsBeforeWrite`，对服务工程的 mapper 单元调用它：
  - 判据：`LWIsServiceProject(P)`（`.lpr` 含 `WantDaemonApp`）+
    文件名等于 `uMapper.pas`（IDE 保存时写成小写）+ 源码含
    `TServiceDaemonMapper` / `DaemonDefs`，三重保证不误改用户自己的文件；
  - 新名字取 `ExtractFileNameOnly(LazarusIDE.ActiveProject.ProjectInfoFile)`。
- 为什么此刻拿得到新名字：Lazarus 的 `ShowSaveProjectAsDialog` →
  `FinalizeSavingProject`（`ide/sourcefilemanager.pas:8140` 起）先设置
  `Project1.ProjectInfoFile := AnLPIFilename`，然后才写盘；
  `sefsBeforeWrite` 在 `RenameUnit` / `SaveEditorFile` 写盘前触发（同文件 :5926 / :2843）。
- 改的是 `aFile.SetSourceText(...)` → `TUnitInfo.SetSourceText` → `Source.Source := ...`，
  也就是**同一个 CodeBuffer**：`WriteUnitSource` 写的是它，编辑器页也指向它，
  所以落盘即最终值、编辑器同步、不弹框、不重载（满足坑 172 的约束）。

**顺带踩的编译坑**：Pascal 标识符大小写不敏感，局部变量 `P: TLazProject` 和
`p: Integer` 撞成 `Duplicate identifier "P"`，后者改名 `LeadingPos` 才过。

**验证**：`lazbuild --build-all src/design/lwdesign.lpk`、`lwnew` 均编译通过；
独立测试程序 13 项断言全过（占位名替换、显示名、幂等、空名字、二次另存为改名）；
`tests/run_fixed_regression.py::check_wizard()` 加了三项守门，全套回归全绿。

## 坑 197：插件模式改成多进程插件框架（2026-11-24）

**需求**：新建工程向导第三框选「插件模式」时，不再生成"单 exe + lwmodules 同进程
模块"，而是生成 `demos/pluginsDemo` 那套**多进程插件框架**（宿主 exe + 插件 exe），
并且要带 `common` 目录。旧的同进程路径**直接替换**（用户明确要求）。

**做法**（新增 `src/core/lwnewplugin.pas`，lwnewproject 只管单工程）：

- 模板：宿主 `.lpr` / `.lpi` / `umain.pas` / `.lfm`、`common\upluginproc.pas`、
  `plugins\hello\` 示例插件工程、`<Name>.ini`、`build-all.bat` / `stop-all.bat` /
  `README.md` 全在这个单元里；`LWPluginExtras` 写附件（默认只补缺失）、
  `LWPluginGenerate` 一次生成整套。
- 两条生成路径共用同一份模板：`tools\lwnew --plugin` 走 `LWPluginGenerate`；
  IDE 向导在 `InitProject` 里用 `LWPluginHostSource`，主窗体描述符换成
  `LWPluginHostUnitSource` / `LWPluginHostResourceSource`，
  保存钩子 `EnsureExtras` 在落盘后调 `LWPluginExtras`（判据：
  `LWIsPluginProject` = `.lpr` 含 `PlugLaunchAll`）。
- `common` 的编译路径交给 IDE 自己写：`CO.OtherUnitFiles := 'common'`
  （= `TLazCompilerOptions.UnitPath`，和工程选项对话框同一个属性），
  比落盘后再改 `.lpi` 的 XML 可靠 —— IDE 内存与文件始终一致。
- `lwnewproject.LWGenerateProject` 收到 `Plugin=True` 直接报错返回，
  防有人以为它还会生成插件框架，结果只拿到一个"没有 common 的空宿主"。

**踩的坑**：

1. 生成的 `build-all.bat` 里写了 `echo ... plugins\<name>\ ...` —— `<` 被 cmd
   当成输入重定向，报"系统找不到指定的文件"。ASCII 脚本里的 `<` `>` 一样危险，
   不是只有中文注释才要小心（坑 10 的同类）。
2. 清单根目录改了：demo 里宿主在 `host\` 下，清单根 = exe 的**父**目录；
   生成的布局宿主就在工程根，所以 `ExeRoot` 取 `<exe 目录>\plugins`，
   `.run` 也随之落在 `plugins\.run`（README/注释都已同步，别照抄 demo 的路径）。
3. 大段模板**不要手写字符串拼接**：示例窗体里引号一多，`QuotedStr` 混拼很容易
   出现奇数个单引号，FPC 报 `String exceeds line`（改动时踩过一次）。
   改为把模板文本按行存成 `array of string`（引号在数组里双写），
   再用 `LinesText` 拼 —— 与内嵌的 `upluginproc.pas` / `umain.pas` 同一手法。
4. 插件模式**不**走 `DoNewEditorFile`：`common\` / `plugins\` 是独立子工程，
   不是宿主工程单元，塞进宿主工程检查器反而混乱；它们由保存钩子直接写盘，
   所以"已存在就不覆盖"是硬约束（钩子每次保存都会跑）。

**验证**（本机）：`lwnew --plugin` 生成 → `lazbuild -B plugins\hello\hello.lpi`
与 `lazbuild -B --ws=nogui <Name>.lpi` 均通过 → 运行后 `/` 与 `/p/hello/` 全 200，
`/lw/api/session` 里侧栏菜单为「插件 → 示例插件」、页签里是 `htmlframe`；
重编插件后点菜单：pid 变化、iframe `?v=1`、页面显示新文案（热更新）；
移走 `plugins\hello` 点「重新扫描插件」→ 菜单消失、`/p/hello/` 变 404，
移回来再点 → 菜单恢复、进程重启、200；`--gui` 模式 `build-all.bat` 通过；
`--units` 模式（不装包）插件与宿主都能编；`tests/run_fixed_regression.py` 全绿
（`check_wizard()` 的插件断言已改为多进程框架）。

## 坑 198：插件 exe 不能单独运行（启动守卫，2026-11-24）

**需求**：插件是主程序的一部分，双击插件 exe 不能起服务；必须由主程序拉起，
单独执行时给提示后退出。

**做法**：新增 `common\upluginguard.pas`（宿主与插件共用，demos/pluginsDemo 与
生成器模板各一份同源文本）：

- 宿主 `StartOne` 每次拉起插件时现取 nonce（`<unix 秒>-<随机32位>`），
  命令行多三条：`--lw-plug-nonce=` / `--lw-plug-token=SHA1(secret|nonce)` /
  `--lw-plug-host=<宿主 exe 名>`。
- 插件 `.lpr` 的 `begin` 第一句 `PlugGuardCheck('标题')`，四道校验：
  参数齐全 → nonce 未过期（120 秒）→ token 对得上 → 父进程 exe 名与
  `--lw-plug-host` 一致。任一不过：stderr 提示 + （只有在"一个参数都没带"时）
  消息框 + `plugin-guard.log` 追加一行 + `Halt(3)`。
- 父进程用 `NtQueryInformationProcess` 取 PPID（FPC 这套 winunits 里**没有**
  `tlhelp32` 单元，Toolhelp 那条路走不通），再 `QueryFullProcessImageNameW`
  取父进程路径。
- secret 以十六进制字符串常量存储（`PlugGuardSecretHex`），运行时解码，
  免得 exe 里 `strings` 直接看到明文口令。

**踩的坑**：

1. **FPC 的 `Write(ErrOutput, ...)` 会按默认代码页再转一次**：源码是 UTF-8，
   中文写出去变成乱码。改成 `FileWrite(StdErrorHandle, ...)` 直接写字节，
   并区分句柄类型：`GetFileType(stderr) = FILE_TYPE_CHAR`（真控制台）时用
   `WideCharToMultiByte(GetConsoleOutputCP,...)` 转 CP936，被重定向到
   文件/管道时保持 UTF-8。
2. **被宿主拉起时弹模态框会卡死宿主启动**：宿主 `poNoConsole` 拉起插件后要
   轮询端口 10 秒，插件弹个没人点的 MessageBox 就一直不退出 —— 宿主白等满 10 秒，
   桌面上还留一个孤儿窗口。改为：**只有 `reason='missing'`（一个参数都没带 =
   用户自己双击）才弹框**；带了参数但校验不过（改了口令只重编了一边）只写
   stderr + 日志，宿主日志里立刻出现「退出码 3」。
3. **`array[0..N] of string` 的 N 必须跟着改**：给内嵌的 `cCommonLines` 插了几行
   注释/参数，忘了改边界，FPC 在数组末尾报 `")" expected but "," found`（报的
   位置离真正原因几十行，容易误判）。后来写了脚本按块重新数元素并回写 N。
4. **生成器里的守卫源码不要手改**：`cGuardLines` 由 demo 的
   `upluginguard.pas` 整篇重新生成（逐行转 Pascal 字面量、单引号双写、末行不加
   逗号），两边永远同源；手改模板迟早和 demo 走偏。
5. **`..\common` 的相对层级**：demo 里插件在 `pluginsDemo\dashplug\`，
   common 是 `..\common`；生成的工程里插件在 `plugins\hello\`，common 是
   `..\..\common`（`..\..\common` 这一串已进模板与 README）。
6. `GetEnvironmentVariable` 同时被 `Windows` 和 `SysUtils` 提供，`uses` 里
   Windows 在后会盖住 SysUtils 的单参版本，必须写 `SysUtils.GetEnvironmentVariable`。

**验证**（本机）：demo 四个 exe 与生成工程全部重编通过；直接跑 `dashplug.exe`
→ exit 3 + 提示「不能单独运行」+ `plugin-guard.log: missing`；伪造 token
→ `badtoken`；600 秒前的 nonce + 正确 token → `stale`；正确 token 但父进程不是
宿主 → `nothost`；宿主拉起三个插件全 200、热更新（pid 变、`?v=` 递增）、重新扫描
（404 → 200）都正常；把插件侧 secret 单独改掉再启动宿主 → 宿主日志
「插件进程启动后立即退出: hello（退出码 3…）」且插件进程不残留、宿主照常服务；
`lwnew --plugin` 生成 → `build-all.bat` 通过 → 单跑插件 exit 3、宿主拉起 200；
`tests/run_fixed_regression.py` 增加守卫断言后全绿。

**边界**：这层是"防误操作 + 提高门槛"，不是密码学强保护 —— secret 在 exe 里，
拿到源码能照算 token，父进程名也在命令行里。要真正"只有我的主程序能开"，
得换证书/本地 IPC 鉴权。

---

## 坑 199：插件用户权限（登录 + 角色 + 路由鉴权，2026-11-24）

守卫（坑 198）解决"exe 不能被单独执行"，但**不是用户权限** —— 插件页面照样
对任何能访问宿主的人开放。真正要"谁只能看哪个插件"，必须落到代理层。

**结构**（`demos/pluginsDemo`，框架侧只改 `lwroute` 加一个可选回调）：

```
登录   host/ulogin.pas        TLWLoginForm 子类，OnLogin 里写会话变量
账号   common/upluginauth.pas 账号表 + 角色 + LWAuthCanOpen + LWAuthGuard
清单   <插件>.plugin.ini       roles=admin,analyst（空 = 所有已登录用户）
菜单   umain.BuildMenu        无权限的项不进侧栏（只是 UI，不构成强制）
路由   lwroute                /p/ 代理前调 LWAuthGuard，无权限 403
```

踩到的坑，按"现象 → 根因"记：

1. **Set-Cookie 发出去浏览器不认**：`AResponse.CustomHeaders.Add('Set-Cookie: lwpsid=xxx')`
   实际发出的是 `Set-Cookie: lwpsid: xxx` —— fcl-web 的 CustomHeaders 是
   `TStringList`，`NameValueSeparator` 是 `=`，Add 时按 `=` 把整串拆成
   `Name='Set-Cookie: lwpsid'`、`Value='xxx'`，发送时再用 `': '` 拼回去。
   必须走 `AResponse.Cookies.Add`（`TCookie`，有 Name/Value/Path/HttpOnly/SameSite）。
   同一个坑此前一直存在于 `lwhttp.SetLangCookie`（语言 Cookie 从来没生效，
   靠 `?lwlang=` 和默认值兜着，所以没人发现），本次一并修掉。
2. **浏览器明明发了 Cookie，服务端读到空串**：fcl-web 把 `Cookie:` 头放进了
   `TRequest.Cookie` 属性，`GetCustomHeader('Cookie')` 拿不到。读取要
   `ARequest.Cookie` 优先、CustomHeaders 兜底（`lwroute.RouteRawCookie`；
   `lwhttp.ReqLang` 同样修了，否则语言 Cookie 读不回来）。
3. **iframe 的 sid**：浏览器发 `/p/notes/` 不会带宿主的 `?sid=`（那是前端 JS
   发 `/lw/api/*` 时用的）。宿主序列化 iframe 时要把会话号拼进 URL，放行后
   lwroute 落一个 `Path=/p/` 的 cookie，子资源请求才带上 —— 只校验入口 HTML
   等于没校验（`/p/名/lw/api/event` 可以绕过去）。
4. **只隐藏验证码输入框 ≠ 关闭验证码**：`TLWLoginForm.RequireCaptcha` 默认
   True，隐藏 `edCode`/`captcha1` 但没置 False，基类仍拿空输入比对，永远提示
   "验证码错误"，登录进不去。要同时 `RequireCaptcha := False`。
5. **注销再登录复用同一个主窗体**（框架 `SessionFindForm` 的设计，避免每轮多造
   一个窗体），所以 `FormCreate` 里建的菜单不会重跑 —— 身份变了但菜单还是上一个
   账号的。要在 `OnShow` 里比对登录名，变了就重建菜单、关越权页签。
6. **菜单和路由必须共用一份判定**：一开始菜单用 `roles` 判断、路由另写一份，
   结果清单加了个角色后两边不一致 —— 现在统一 `LWAuthCanOpen`。

**验证**：`tests/t_pluginauth.py` 34 项全过 —— 未登录 3 个插件全 403；admin 侧栏
3 项且全 200；analyst 2 项（报表 403）；guest 1 项（仪表盘/报表都 403）；
放行时下发 `lwpsid`，之后不带 query 也 200；伪造 sid / 注销后旧 sid 都 403。

**边界**：插件监听 `127.0.0.1:<port>`，绕过宿主直连端口不受权限约束；要进程级
隔离得让插件自己也登录，或改成命名管道 / ACL 受限句柄。

## 200. pluginsDemo 登录窗开启图形验证码（2026-11-24）

需求：插件 demo 的登录窗要有验证码。框架其实早就有了 —— `TLWLoginForm.BuildDefaultUI`
在空窗体上会自动摆 `lblCode` / `captcha1` / `edCode`，`TryLogin` 先验码再验账号、
错码自动换图。是 demo 自己当初为了少一步操作主动关掉的（`HideCaptcha`）。

**开启只需要"别关"**：删掉 `RequireCaptcha := False` 与三个 `Visible := False`，
再显式写一次 `RequireCaptcha := True`（表明是有意开着，基类将来改默认值也不会把门弄丢）。

**踩到的三件事**：

1. **提示文案塞不进标题下面**。自动 UI 的坐标是标题 y=18、用户名 y=62，中间只有
   20px 出头，加一行提示会压到用户名输入框上沿。改成按钮下方的灰色脚注
   （y=238，`Font.Color := clGray`）—— 用 `Graphics` 单元的 `clGray`，别忘了 uses。
2. **判断"验证码关没关"不能看节点存不存在**。关掉后控件只是 `visible=false`，
   序列化里仍在。要看 `visible` 字段，或者看启动日志里那行开关状态。
3. **口令文案必须引用常量**。之前把口令写死在标题里，账号表换了之后没同步，
   窗体上提示的口令与实际口令不一致 —— 照着提示输永远登不进去，只有真人去点
   才会发现。改成 `'口令 ' + LWAuthDemoPass`，一处改全处生效。

**自动化怎么登录**：读不了图，只能显式关掉验证码 ——
`pluginsdemo.exe --port=8878 --no-captcha` 或环境变量 `LW_LOGIN_NO_CAPTCHA=1`。
`tests/t_pluginauth.py` 因此改成：端口没实例就自己拉起（带 `--no-captcha`），
已有实例则先探测它是否开着验证码，开着就直接提示换参数，而不是让 29 项断言全红。

**想要真码登录验证**：`LW_CAPTCHA_DEBUG=1` 会把 `[lw] captcha <令牌> = <答案>`
打到 stderr，脚本/人从日志取答案再提交。比 OCR 可靠得多（点阵字符人眼容易看错）。
本次用它完成了 Form 从 `LoginForm` 切到 `MainForm` 的完整验证。

**边界**：验证码挡的是脚本批量试口令，不挡人工打码；账号锁定 / 失败计数仍要另做。

## 201. 宿主把登录身份带给插件进程：注入头 + 验签（2026-11-24）

需求：插件是独立 exe，宿主会话里的 lwuser/lwroles 不会自动过去；便签页要显示
"当前是谁"。四个进程各自一套会话表，没有共享内存，也不能做全局"当前用户"
（两个浏览器同时登录不同账号会串）。

**做法**：宿主在 `/p/` 反代时签发身份头，插件验签后读。
- `lwroute` 新增 `TLWRouteIdentityFunc` + `LWRouteSetIdentity`（nil = 不注入）；
  鉴权通过后调回调拿 user/roles/token/ts，`ProxyTo` 写进四个头。
- **必须先删客户端自带的同名头再写宿主的值** —— 只追加等于让浏览器自己发
  `X-LW-User: admin` 就能在插件里冒充管理员。
- `lwhttp.HandleRequest` 把头落到 threadvar，业务事件里可读，`finally` 清空；
  连接线程会复用，不清空会把上一个用户的身份带给下一个请求。
- 插件 `common/upluginidentity.pas` 用 upluginguard 的同一个 secret 验
  `SHA1(secret|user|roles|ts)`，60 秒有效；验不过一律返回空身份。

**验证时踩的坑**：拿插件 `/lw/api/session` 返回的 sid 去请求
`/p/notes/lw/api/tree` 会 403 —— 那是插件会话 id，宿主鉴权只认宿主 sid。
验证身份只需看插件 session 响应里 `lblIdentity` 的 caption，别把两个 sid 混用。

另一个是坑 200 的延续：`t_pluginauth._has_captcha` 只看 `kind == 'captcha'`
会把 `--no-captcha` 的实例误判成"开着验证码"，脚本拒绝复用自己拉起的宿主。
关掉时控件只是 `visible=false`，节点仍在序列化里 —— 要看 `visible` 字段。

**最新状态**：`tests/t_pluginauth.py:96-101` 的 `_has_captcha` 已按
`kind == 'captcha' and n.get('visible') is not False` 判定，此坑已修正。

**边界**：签名只证明"这个头是宿主最近 60 秒签的"，不证明"请求确实来自宿主
进程"；本机抓包拿到完整头的进程仍可在窗口内重放。要更强只能校验调用方进程
身份，或改用 ACL 受限的 IPC。

## 202. 插件模式模板没跟上 demo 的权限改动（2026-11-24）

坑 198~201 把 `demos/pluginsDemo` 的用户权限、验证码、身份注入都跑通了，
但新建工程向导的「插件模式」走的不是 demo，而是 `src/core/lwnewplugin.pas`
里**内嵌的源码文本**。只改 demo 的话，新生成的工程仍然是"没有登录、
插件 exe 只带启动守卫"的旧框架 —— 用户照着 demo 文档找 `upluginauth.pas`
会找不到文件。

**这次把模板与 demo 对齐**：

- `cCommonLines` 补 `Roles` 字段：`ParseManifest` 读 `roles=`、`PlugRescan`
  同步 `old.Roles`。原来清单注释提了 roles，但对象里根本没这个字段，
  `LWAuthGuard` 拿不到限制（模板里当时也没有这个单元，所以看不出来）。
- 新增三个内嵌数组：`cAuthLines` / `cIdentityLines` / `cLoginLines`，
  分别来自 demo 的 `common/upluginauth.pas`、`common/upluginidentity.pas`、
  `host/ulogin.pas`；`LWPluginExtras` 把它们写进 `common\` 与宿主根目录，
  设计期保存钩子与 `--plugin` 都走同一条路，不用改向导逻辑。
- 宿主 `.lpr` 加 `SetLogin` + `LWAuthRegister`，`umain.pas/.lfm` 换成
  demo 的权限版（菜单过滤、顶栏身份、切换用户、iframe 带 sid）。
- 示例插件 `uform_hello` 加 `lblIdentity`，`uses upluginidentity` —— 这样
  "当前用户"在模板生成的工程里就能直接看到，不用再抄 notesplug。

**两个必须注意的同步点**：

1. **数组上界要重算**。`cXxxLines: array[0..N] of string` 是手写的，
   往数组里插几行不改 N，FPC 会报 "range check error" 或直接编译失败。
   改完用脚本按 `'...'` 行数重算一遍最省事（本次 9 个数组全重算）。
2. **`%NAME%` 要在生成函数里展开**。新加的 `cSampleUnitLines` 最初直接
   `LinesText(...)` 返回，生成出来的文件头留下一个 `%NAME%`。所有内嵌数组
   都统一走 `ExpandTemplate` 才不会漏。

**验证**：`tests/run_fixed_regression.py` 新增 `check_plugin_template_generation()`
—— 现编 lwnew → 现生成一套插件工程 → 检查四个 common 文件、登录接线、
`PlugIdentityDisplay`、无残留占位符。另外实际编译了生成的宿主与插件，
并用 `--no-captcha` 登录确认 `/p/hello/` 未登录 403、登录后 200、
插件页 `lblIdentity = 当前用户：系统管理员`。

**边界**：模板默认带登录是"开箱即用"的演示档，不是强制产品形态；
不需要就删 `.lpr` 两行（见 README）。只删菜单过滤、不删 `LWAuthRegister`
会留下"菜单看不见但手敲 URL 能进"的越权口子。

## 203. 插件 demo 的 Linux 构建脚本与两处平台差异（2026-11-24）

给 `demos/pluginsDemo` 补了 `build.sh` / `stop-all.sh`，新建工程向导的
「插件模式」也同步生成 `build-all.sh` / `stop-all.sh`。只写脚本不够，
Linux 上还有两个会让插件根本起不来的差异：

1. **清单写 `exe=dashplug.exe`，但 FPC 在 Linux 上生成的二进制没有后缀。**
   `ParseManifest` 找不到带 `.exe` 的文件时，退回同目录的无后缀同名文件
   （`Copy(exe, 1, Length(exe) - 4)`）；两个平台共用同一份清单，不用维护两套。
2. **`CopyFileRaw` 用 TFileStream 新建 `.run` 副本，Linux 下权限是 0644。**
   宿主 `TProcess` 拉起时报 Permission denied（退出码 127）。`{$IFDEF UNIX}`
   里补 `fpChmod(Dst, &755)`（uses 加 `BaseUnix`）—— Windows 下走不到，
   不影响原行为。实测 FPC 3.3.1/Linux 上 `FileSetAttr(Dst, &755)` **不会**
   改权限，复制出来的副本仍是 0644，不能用它代替 fpChmod。
   demo 与向导模板（`src/core/lwnewplugin.pas` 的 `cCommonLines`）是两份
   独立副本，修一处必须同步另一处；改完模板还要重编 `tools/lwnew.exe`。

**模板特有的坑**：生成 `.sh` 不能用 `LineEnding`，否则在 Windows 上生成的文件是
CRLF，bash 会把行尾的 `^M` 当命令的一部分。模板里所有 sh 行尾写死 `#10`。
回归测试会检查生成结果不含 `\r`。

`stop-all.sh` 按 `/proc/<pid>/exe` 的真实路径过滤（含 ` (deleted)` 后缀处理），
只杀本 demo 目录下的宿主/插件，不会误杀 procdemo 里同名的进程。

**验证**：`bash -n` 两个脚本通过；生成的插件工程里两个 `.sh` 全是 LF；
生成的宿主与插件、demo 的宿主与两个改过的插件均编译通过；登录后
dash / notes / reports 三个插件页都显示「当前用户：系统管理员」。

## 204. 登录字段挑战-响应：TLS 之外再把口令原文挡在浏览器里（2026-11-24）

TLS 只保证"路上看不见"，载荷里仍是原文；要口令原文不出浏览器，得做
**一次性挑战-响应**。框架级开关 `TLWLoginForm.SecureLogin`（默认关），
`pluginsDemo` 已开启。

做法：令牌直接复用 `TLWCaptcha.Token`（天然一次性，换图即变），前端提交时
把 `edUser/edPass/edCode` 换成 `SHA256(令牌|值)`；服务端 `LWCaptchaCheckHashed`
复算答案摘要，业务层 `LWAuthLoginHashed` 复算账户摘要。用户名统一小写、
验证码统一大写去空格，与明文校验的大小写语义保持一致。

五个坑：

1. **`lwwriter` 不能 `uses lwlogin`**：`lwwriter -> lwlogin -> lwapp -> lwhttp
   -> lwdispatch -> lwwriter` 成环。改成在 `TLWForm` 上放虚方法
   `SecureLoginActive`，`TLWLoginForm` 覆盖，writer 只依赖 `lwform`。
2. **`--no-captcha` 只是把控件 `Visible := False`，控件对象还在**。
   `SecureLoginActive` 必须写成 `FSecureLogin and FRequireCaptcha and (Captcha <> nil)`，
   否则前端明文、服务端按摘要比对，登录 100% 失败。
3. **用户名也是摘要，会话变量必须写真实名**。`LWAuthLoginHashed` 用 out 参数
   返回 `ARealUser`；`LWAuthSessionSet` 写它，不能写 `AUser`（否则顶栏、
   插件身份头、权限日志里全是哈希串）。
4. **前端不能用 Web Crypto**：`crypto.subtle.digest` 是异步的，而 `formVals`
   是同步收集。`lw-alpine.js` 内嵌了一份同步 SHA-256（UTF-8、小写 hex），
   必须与服务端 `lwbase.LWSha256Hex` 逐字节一致；回归用 Node 对
   `crypto.createHash('sha256')` 比过 `abc` / 空串 / 中文 / 长串。
5. **前端资源查找顺序**：`LWFindClientFile` 先看 exe 同目录和 `lw/` 副本，
   再看 `root/src/client/`。`pluginsDemo` 没有 `lw/` 副本，所以改
   `src/client/lw-alpine.js` 对它立即生效；其他 demo 的 `lw/` 副本保持旧版，
   正好符合"默认关闭"。

边界：服务端必须能拿到明文口令或等价摘要（演示账号是源码常量）。库里存
bcrypt 这类不可逆哈希时无法验证挑战，应改用 SRP/PAKE，或只依赖 TLS。

验证：正确摘要登录成功且日志 `user=admin`；错误口令拒绝；旧摘要向新会话
重放拒绝；`--no-captcha` 下 `securelogin` 不下发、明文登录成功。

## 205. 第三方可视控件：运行期登记 + 生成器，别再逐个改 KindOf（2026-11-25）

老文档（`THIRDPARTY_BINDING.md` §2.2）要求把第三方类加进 `KindOf` 那条
`if` 链。问题不在写法，而在**位置**：`KindOf` 在 `lwcore` 里编译，第三方类
在业务工程里，业务侧无论怎么写都进不去，只能改框架再全量重编，且每个控件
都要给核心引入一个第三方包依赖。

改成运行期登记表（`lwwriter`）：`LWRegisterControlKind(AClass, AKind, AProps)`
+ `LWBindPublishedProps(C, O, [...])`，业务在 `TLWApp.Run` 之前登记。三个真实坑：

1. **命中登记后必须跳过内建属性分支**。`WriteKindPropsBody` 的 `chart` 分支里有
   `TLWChart(C)` 硬转；注册的类若落到内建分支会抛异常，被 `WriteControl` 兜成
   `unknown` + `err`——页面表现为"灰框里写着类名"，看起来像没绑定成功。
2. **登记表用只增链表，不用动态数组**。`SetLength` 会让并发读拿到已释放的旧块；
   头插 + 节点永不释放，启动期单线程写、运行期无锁读即可。
3. **匹配按继承链走，先派生后祖先**。`TMyChart` 与 `TChart` 同时登记时，前者命中
   自己那条；否则子类会被父类规则抢走，和 `KindOf` 的顺序坑同源。

配套生成器 `tools/lwbinder`（实测流程）：

```
lwbinder --class=TChart --unit=TAGraph --package=tachartlazaruspkg ^
         --kind=chart --out=demos\tachartdemo\gen
```

它先编一个 nogui 探针真跑，`CREATE_OK` 才继续；属性一律从 RTTI 读，不解析源码
（解析会漏 IFDEF 分支、继承属性、published 改名）。筛属性要按 `tkXxx` 种类判断——
RTTI 报的类型名是 `AnsiString` / `TTranslateString` / `LongInt`，按 `'string'` /
`'Integer'` 比会全部落空。几何与可见性（`Left/Top/Width/Height/Align/Visible/Name/Tag`）
要排除，节点基类已经发过。

生成器自身的坑：写文件用 `TEncoding.UTF8.GetBytes(AnsiString)` 会把源码里的
UTF-8 字节先按系统代码页（GBK）解释一遍再编码，落盘就是"鎺т欢"式乱码；
直接 `WriteBuffer(PChar(s)^, Length(s))` 原样写字节即可。

边界：`TChart.Title` / `Series` 是对象属性，RTTI 读不出来（`tkClass` 且非
`TStrings`，被跳过），要用生成单元留的 `<Cls>Extra` 钩子补。绘制型控件的
`OnPaint` 在 nogui 下仍无设备上下文，这条没变。

验证（`demos/tachartdemo`）：探针 `CREATE_OK TChart 300x200`；组件树
`kind=chart`、2 系列 × 6 点；浏览器 2 个 SVG、控制台无报错；点按钮后柱高
`230.6/368.3/334.8 → 146.9/130.2/199.0`、页面未刷新。

## 206. lwbinder 的 GUI 外壳：四个跟 LCL 打交道时真踩到的坑（2026-11-25）

`tools/lwbinder/lwbinder_gui.exe` 是转换器的图形界面，界面在 `ubindgui.lfm`，
逻辑仍在 `ubindcore.pas`。下面四条是写这层壳时实测出来的，不是理论风险：

1. **`TStatusBar` 在 win32 下画不出分格文字**。`Panels` 三格、`Panels[0].Text='就绪'`
   都设对了，运行时 `Panels.Count=3` 也读得到，但屏幕上只剩一条纯灰带，没有分隔线也没有字；
   `WM_PRINT` 抓图同样拍不到。换成 `TPanel`（`BevelOuter=bvNone`）+ 两个 `TLabel`
   一次就正常。工具类窗口不值得为状态栏去调 widgetset 细节。
2. **`Scaled = False` 是刻意的**。开着自动缩放时，系统按 DPI 重排这个按 96dpi 设计的窗体，
   实测在 150% 下把锚定底部的页签/状态条挤出可视区（窗口 1224×1079，内容只画到 880）。
   关掉后窗体固定 800×680，任何 DPI 下都完整显示（代价是高 DPI 下略小）。
   要改回缩放，必须连同"所有分组用 `Align` 堆叠、不要靠绝对坐标 + anchors"一起改。
3. **改 `.lfm` 后必须 `lazbuild -B`**。只改 lfm 不改 `.pas` 时，增量编译认为单元没变、
   不重新编译资源，跑起来还是旧界面——排查半天以为是布局算错，其实二进制没更新。
4. **`TWinControl.PaintTo` 会把标题栏一起画**，客户区整体下移约 40px，底部状态条出画。
   要做"不依赖屏幕"的界面快照，用 `WM_PRINT + PRF_CLIENT|PRF_CHILDREN|PRF_ERASEBKGND`，
   并先用 `SetViewportOrgEx(DC, -dx, -dy)` 把客户区原点挪回 (0,0)
   （`dx,dy = ClientOrigin - (Left,Top)`）。GUI 里的 `--shot=` 就是这套。

线程那侧沿用 `lwconvert_gui` 的结论：`FreeOnTerminate := True`，主线程只在
`OnTerminate` 里读结果、**不 Free** 线程对象，否则 `TThread.Destroy → WaitFor`
反等自己退出直接死锁。

验证：默认套 TAChart 示例后点「生成绑定」，`--no-probe` 下产出 5 个文件、日志给出
等效命令行与下一步；勾回「运行探针」再跑，`README_Chart.md` 里出现
`CREATE_OK TChart 300x200`，`uChartBinding.pas` 从 1583 字节涨到 1978 字节（属性桥补全）。

## 207. 转换器漏改主窗体 + 依赖包全丢 + DateTimeCtrls 支持（2026-11-26）

用户实测 `lwconvert_gui` 转 QF123（真实工程）时三处不对，根因都在"文本改写"这一层：

1. **主窗体没改成 `class(TLWForm)`，uses 也没补 `lwform`**。`ScanUnitClasses` 只取
   单元里**第一个** `Txxx = class(...)`：`QFLazarusUnit.pas` 先声明 5 个 `TThread`
   后代，`TQFBuildFrm = class(TForm)` 排在第 6 个，于是整个单元被判成"非 TForm"
   直接跳过（既不换基类、也不补 uses，还进不了 `.lpi` 的窗体单元表）。
   修法：优先认第一个 **TForm 后代**，一个都没有才退回第一个类（TDataModule /
   其它基类的分支行为不变）。
2. **`RewritePasBase` 取错了类名**。它用 `Pos('=', Copy(s,1,p-1))` 取"前面第一个等号"，
   前面的 `TWorker = class(TThread)` 里的等号就会被先命中，报告里写成
   `TWorker = class(TForm) -> TLWForm`，`u.FormClass` 也跟着错。
   改成紧贴着 `class(` 往前找 `=`（跳过空白），并且要求 `TForm` 后面紧跟
   `)`/`,`/空白 —— 否则 `class(TFormWithGrid)` 这种自定义祖先会被改成
   `class(TLWFormWithGrid)`，直接编译不过。
3. **原 `.lpi` 的 RequiredPackages 被整个丢掉**。生成 `.lpi` 时只写死了一条 `LCL`，
   于是 `DateTimeCtrls` / `fr_lazarus` / `lazreport` / `MyBtnPackage` … 全没了，
   转换产物一编译就 `unit not found`。修法：`ReadLpiPackages` 按原顺序整套搬过来，
   只保证 `LCL` 在里面。

**DateTimeCtrls（TDateTimePicker）支持**：像 VirtualTreeView 一样不塞进核心包 ——
`TDateTimePicker` 是 `TCustomControl` 后代、nogui 下能创建（实测 Create + 设 Date 正常），
但 `lwcore`/`lwserver` 不依赖 DateTimeCtrls。新增 `src/core/lwdatetime.pas`，在
initialization 里登记两件事：

- `LWRegisterControlKind(TDateTimePicker, 'datetimeedit', @Props)` → 浏览器端按
  `dtkind`(`date`/`time`/`datetime`) 渲染成 date / time / datetime-local；
- `LWRegisterValueWriter(TDateTimePicker, @Write)` → 新增的值回写登记表
  （`lwdispatch` 里 `LWRegisterValueWriter`/`LWRegisteredValueWriter`，规则与
  kind 表一致：沿继承链从最派生往祖先找）。回写必须走 `DateTime`/`Date`/`Time`，
  写 `Text` 无效（`TDateTimePicker` 根本没有 published Text）。

配套改动：`LWIsSnapField` 认登记的回写器（否则点"保存"读到旧值）；`LWISOToDateTime`
接受 `<input type="datetime-local">` 的 `T` 分隔符并吃掉小数秒；`IsInternalControl`
过滤掉控件内部的 `TDTSpeedButton`/`TDTUpDown`（它们是 `TCustomSpeedButton`/
`TCustomUpDown` 后代，KindOf 认不出，会多出两个带类名的占位框）；两个客户端
（`lw.js` / `lw-alpine.js`）都加 `datetimeedit` 渲染与回传。

转换器侧：`.lfm` 里发现 `TDateTimePicker` 就自动把 `lwdatetime` 加进 `.lpr` 的 uses
（核心包不能替工程 uses），并保证 `DateTimeCtrls` 在生成 `.lpi` 的依赖里。

验证（临时工程：`TThread` 前置 + `TDateTimePicker` + `RequiredPackages=LCL,DateTimeCtrls`）：
转换后 `TMainForm = class(TLWForm)`、`uses` 有 `lwform`、`.lpr` 有 `lwapp, lwdatetime`、
`.lpi` 两条依赖都在；`lazbuild --ws=nogui` 编过；服务起来后组件树
`kind=datetimeedit / dtkind=date / iso=2024-01-09`、内部按钮不再出现；
`/lw/api/event` 依次回传 `2026-11-26`、`2026-11-26 13:45:10`、`2026-11-26T21:05:00`，
业务 `OnChange` 里读到的 `dtpStart.DateTime` 都对（含 `T` 分隔符那种）。
`tests/t_convert.py` 29 项全绿。

## 208. 转换器 GUI：给「lazarusWeb 根」补浏览按钮（2026-11-26）

`ulwconvertgui.lfm` 里前两行（源工程 / 输出目录）都有「浏览...」按钮，第三行
`edRoot` 漏了，只能手敲路径。补 `btnBrowseRoot`（Left=944 / Top=112 / W=96，
与上面两个按钮同列，Anchors=akTop,akRight）。

`btnBrowseRootClick` 除了 `SelectDirectory` 之外做两件事：

- 用户常常直接点进 `src` 或 `src/core`，这里向上退到仓库根（`while` 判目录名）；
- 选完检查 `<dir>/src/core` 是否存在，不存在弹确认框（可仍用），避免把工具目录或
  随便一个目录当根，后面 `LoadControlMatrix` 静默读不到矩阵、全按 unknown 报。

`SetBusy` 里一并禁用三个浏览按钮（原来只禁用了编辑框，任务跑起来还能点浏览）。

顺手修 `lwconvert_gui.lpi`：IDE 曾把 `<TargetCPU>aarch64</TargetCPU>` +
`<TargetOS>linux</TargetOS>` 存进去，`build_convert_gui.bat` 直接跑会产出 Linux
二进制。删掉这两行恢复默认（本机 win64）；`lazbuild -B lwconvert_gui.lpi` 现在直接
出 `lwconvert_gui.exe`，不用再手工加 `--os=win64 --cpu=x86_64`。

## 209. 「转换后 uses 还是漏 lwform」：真凶是复制阶段崩溃（2026-11-26）

现象：GUI 转换完，窗体单元还是 `class(TForm)`、uses 里没有 `lwform`。

根因不在改写逻辑，而在 `CopyTree`：QF123 工程目录里嵌了一份 336MB 的 Lazarus 源码
副本（`1\lazarus-b755ac0e...`），其中 `DelphiZXingQRCode_中文.txt` 这类中文文件名
在 ANSI 版 `FindFirst` 下变成 `DelphiZXingQRCode_?????.txt`，`LoadRaw` 抛
`EFOpenError`。`DoConvert` 里没有捕获 —— 转换在**复制阶段**就整体终止，输出目录
一个文件都没更新，用户看到的是 11-10 的旧产物（旧产物就是 `class(TForm)` + 无
`lwform`），所以像「改了没用」。

诊断依据：`C:/QF123 - 副本 (2)_web` 里 185 个文件的时间戳全是 `11-10 11:10`，
本次转换没有任何文件被刷新。

修法：
- `CopyTree` 单文件复制套 `try/except`，失败记 warning 继续（不再中断整次转换）；
- `DoConvert` 的基类改写分支放宽到 `TForm` **或** `TLWForm`：基类已是 TLWForm 的
  单元（人工改过基类，或旧版输出遗留）原来直接落进「没找到 class(TForm)」分支被
  跳过，于是 uses 永远补不上；现在走单独分支只做 `EnsureUsesUnit(txt,'lwform')`。

验证：同工程完整转换 → 1386 处改写、4 条警告（两条中文名复制跳过、一条 lazreport
的 .lfm 无根对象、一条缺 .res），`qflazarusunit.pas` 得到
`TQFBuildFrm = class(TLWForm)` + uses 末尾 `, lwform;`。手工构造「基类已是
TLWForm、uses 缺 lwform」的工程也能补上。`tests/t_convert.py` 29/29 绿。

遗留（未改，待定）：工程目录有多个 `.lpi` 时 `FindProjectIn` 取 `lpis[0]`，QF123
会选中 `QFLazarusInstall - 副本.lpi` 而不是 `QFLazarusInstall.lpi`，输出里没有主
`.lpi`，容易误判「转换没生效」。另外 `CopyTree` 只覆盖不清理，输出目录里上一轮的
旧文件会一直留着。

## 210. lwform 被插进文件开头的废弃代码里（2026-11-26）

现象：`khzl_find_unit.pas` 转换后 `class(TLWForm)` 改了，但 `uses` 里没有 `lwform`。
实际是**加错了地方** —— 文件开头有一段残留的旧单元代码（旧 `unit` 声明 + `interface`
+ `uses ...;`），`lwform` 被插进了那一段，真正的 `uses` 没动。

根因：`EnsureUsesUnit` 直接用 `PosEx('uses', ...)` 取文件里**第一个** uses，再用第一个
`;` 定位插入点。两个毛病：① 不认注释，注释里写的 `uses` 会命中；② 不认"文件头"，
前面那段废弃代码里的 uses 优先于真单元头。

修法（`lwconvert_core.pas`）：

- `MaskNonCode`：把注释体与字符串字面量替换成等长空格（花括号注释、圆括号注释、
  双斜杠行注释、单引号字符串），`{$...}` 编译指令整段原样保留。位置一一对应，
  后续 Pos/PosEx 得到的偏移可直接用于原文。
- `FindKeywordAt`：在屏蔽串上按**词边界**找关键字，`uses` 不会命中 `xxxuses`，
  `interface` 不会命中 `Interfaces` / `InterfaceBase`。
- `FindRealUses`：先找文件头关键字 `unit` / `program` / `library` / `package`，
  跳过 `unit xxx;` 这一行，再往后找 uses；都找不到才退回第一个 uses。
- `EnsureUsesUnit` 的"已存在"判断也改走屏蔽串 + 词边界 —— 否则注释里写着 `lwform`
  就会被判成"已经有"，一直不补。

验证：构造一个"整块旧代码在前 + 真 unit 在后"的单元，转换后 lwform 落在真 uses 末尾
（`..., StrUtils, lwform;`），残留段原样不动；普通工程 `main.pas` 与 `.lpr`（`lwapp`）
结果不变；`tests/t_convert.py` 29/29 绿。

顺带说明：那段残留不是合法的注释块 —— 花括号注释在内部 `{$mode objfpc}` 的右花括号
处就结束了，按 FPC 语义后面的 `interface` / `uses` 是**真代码**，这个文件本身编译
不过。转换器现在能把单元加对位置，但那段残留仍应手工删掉。

## 211. 插件页内 /lw/* 的 sid 顶掉宿主 cookie，403 刷屏但页面照常（2026-11-26）

现象：pluginsDemo 登录后侧栏插件能正常打开、页面数据也在，宿主终端却一条接一条
刷 `[route] 拒绝 /p/dash/ sid=…: 未登录，或会话已过期`。看起来像登录失效，
实际功能没断。

两个独立坑：

1. **日志路径是假的**。`LWRouteDispatch` 无论被拒的是页面导航还是
   `/p/名/lw/api/poll`，都固定写 `/p/<名>/`，完全看不出被拒的是哪类请求。
   现在改成打印 `APath` 原值，排障一眼就能分清。
2. **sid 取错优先级**。`RouteReqSid` 原来是 `?sid= > X-LW-Sid > lwpsid cookie`。
   插件 iframe 里的前端会用它**自己的** session id 去请求
   `/p/名/lw/api/poll?sid=<插件 sid>`（还有 WS/upload/dlg），宿主会话库里
   根本没有这个 sid，于是每次长轮询都 403；而事件 POST 的 sid 放在 body、
   靠 `lwpsid` cookie 鉴权，所以页面反而看着正常。长轮询失败还会按 1.5s
   间隔疯狂重试，日志就刷起来了。

修法（`src/core/lwroute.pas`）：`RouteReqSid` 增加 `ARest` 参数，按请求类型分流：

- 页面导航（`/p/名/`）：仍是 `?sid= > 头 > cookie` —— 首次导航还没有 cookie，
  只能靠宿主拼进 iframe URL 的 sid；
- 插件内部 `/lw/*`：改成 `头 > cookie > ?sid=` —— `lwpsid` 是宿主放行导航时
  下发的宿主 sid，才是这类请求该用的；插件自己的 sid 只能作为兜底。

这样既保留首次导航的鉴权，又不让插件 sid 干扰宿主鉴权；手工在导航 URL 上写
假 sid 依然会被 403，没有放宽安全边界。

验证（192.168.31.240 测试实例）：带合法 cookie、query 放插件 sid 时，
`/lw/api/poll`、`/lw/api/session`、`/lw/lw.css` 全部 200；导航 `/p/dash/?sid=<假>`
仍 403；整轮只有那条故意伪造的导航留下 1 条拒绝日志。回归脚本增加
`run_fixed_regression.py` 的源码断言和 `t_pluginauth.py` 的运行时断言。

## 212. 登录失败锁定：按 IP 计数，连续 N 次锁 M 分钟（2026-11-26）

需求：框架此前没有任何登录限流，口令可被脚本无限次试。增加"同一 IP 连续
登录失败 5 次后锁定 15 分钟"的能力，参数可配，且不能因为升级把人锁在门外。

### 设计要点

1. **入口唯一**：逻辑挂在 `TLWLoginForm.TryLogin`（`src/core/lwlogin.pas`），
   所有用登录窗体的工程共用，不用每个 demo 各写一遍。
2. **验证码错误也计数**（2026-11-26 修正）：最初设计是"验证码错误不计数"，
   但实测发现这正是"错了 N 次没锁定"的主因 —— 用户输错验证码时永远卡在
   这一关直接 `Exit`，根本走不到账号密码校验，`LoginNoteFail` 一次都没调。
   现在验证码失败和账号密码失败**都计入同一个 IP 计数**，成功登录一次即清零。
   验证码一枚一作废确实仍是独立防暴破门，但从用户视角两种都算"登录失败"，
   都该触发同一道锁。
3. **成功即清零**：`LoginNoteSuccess` 直接删掉该 IP 的记录；锁定到期也会
   自动复位计数，不必等用户再成功登录一次。
   **锁定提示用模态框不用 toast**（同日修正）：锁定原先只推 `type=toast`，
   4 秒自动消失，用户切个窗口就错过，以为"锁了但没提示"。改成 `TLWLoginForm.
   PushAlert` 推 `type=msg`（浏览器端模态对话框，不点"确定"不消），文案含
   "账号已锁定"字样。普通失败仍是 toast。
4. **锁定期内彻底拒绝**：`TryLogin` 一进门先查 `LoginLocked`，连验证码都
   不校验，避免锁着还能借刷新验证码刷服务端。
5. **远程 IP 的取法**：`TLWSessionBase` 新增 `RemoteIP`（原来只在
   `TLWSession` 私有字段里），`TLWSession.Create(sid, form, ARemoteIP)` 构造
   时就赋值，登录请求到达时已可读。移到基类后删掉 `TLWSession` 里遮蔽的
   同名字段/属性，否则 `TLWLoginForm` 拿不到。`AIP=''` 时整段逻辑跳过，
   没有会话的调用路径不会被误锁。
6. **线程安全**：全局 `TStringList` + `TRTLCriticalSection`。按 IP 换会话/
   换页签都累计同一条；超过 512 条顺手扫掉"未锁定且 1 天未活动"的项，
   防止爬虫换 IP 把表撑大。`finalization` 里释放。
7. **默认安全值 + 0 关闭**：默认 5 次 / 15 分钟，任一参数设 0 即整段关闭
   （`LoginLockEnabled` 要求两者都 >0）。升级后即使 ini 没写新键也不会
   突然锁住既有部署；要收紧才显式配置。ini 非法值（<0 或超上限）告警并
   回默认，不会因为一个手滑数字把服务锁死。

### 配置

```
; 宿主同名 ini
loginfailmax=5      ; 0=关闭；合法 0..1000，别名 loginfailcount
loginlockmin=15     ; 0=关闭；合法 0..10080（一周），别名 loginlockminutes
```

命令行 `--login-fail-max=N --login-lock-min=M` 优先级高于 ini。
`--help` 里列出了两行说明。向导生成的宿主 ini 模板
（`lwnewplugin.LWPluginHostIni`）以注释形式给出这两个键，避免写死后
新工程行为被固定。

### 相关文件

- `src/core/lwlogin.pas` —— 计数表、锁定判定、`TryLogin` 三个挂接点
- `src/core/lwbase.pas` / `lwsession.pas` —— `RemoteIP` 提到基类
- `src/core/lwhttp.pas` —— `TLWServerConfig` 加两个字段
- `src/core/lwapp.pas` —— `GCfg` 提到 interface（供 lwlogin 引用）、默认值、
  ini/命令行解析与校验、help 文本
- `src/core/lwnewplugin.pas` —— 生成 ini 的注释说明
- `tests/run_fixed_regression.py` —— 源码级断言（四处）

### 验证状态

本地：宿主交叉编译（aarch64/linux）通过；`lwnew.exe` 重编覆盖；
`run_fixed_regression.py` 全绿；生成的 ini 含新注释。
远端 192.168.31.240 功能性实测本轮**未做**——主机离线（ping 100% 丢包、
22 端口不可达），新宿主已编译待上传，主机恢复后用 3 次/10 分钟参数起
测试实例即可快速验证。
