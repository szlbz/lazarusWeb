# lazarusWeb 使用手册

> 版本基准：LW_VERSION 0.9.6（`src/core/lwbase.pas`），2026-11-17 更新。
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
- 浏览器端由 `lw-alpine.js`（Alpine.js 3.14.9，**默认**）或 `lw.js`
  （Ext JS x.x.x，可选）渲染并按 id 对账增量更新；`--patch=1` 时事件只回
  2~4KB 差量。

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
| mobile_demo | 移动端对照示例（无模板窗体回退平移模式；`tpl/` 内的旧占位符模板属历史机制，新版本只作背景层，不重排控件；新写法见 16.2） |

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
  图形验证码见下面「登录窗体的图形验证码」；
- 图表 `TLWChart`、报表 `lwreport`（HTML/CSV/XLSX）、富内容 `TLWHTMLFrame`
  /`TLWPDFFrame`、仪表 `TLWGauge`、取色器 `TLWColorPicker` 都是框架自带控件；
- 定时器用 **TFPTimer**（必须 `UseTimerThread=True`）——nogui 下 TTimer
  不可用。
- 功能做成插件有两种形态（**新建工程向导的「插件模式」生成后者**）：
  - **旧同进程方案（保留参考）**：页面与 AJAX 放 `plugins/umod_*.pas`，单元里声明
    `procedure RegisterModule;`，跑 `python tools/lwplugins.py` 生成注册汇总，
    主程序只调 `RegisterAllModules`；示例 `demos/plugindemo`。
  - **当前多进程插件模式（推荐）**：宿主 + 每个插件各是独立 exe，清单扫描 /
    进程拉起 / 热更新 / 角色鉴权 / 身份头都在生成工程里成套给出，见
    `demos/pluginsDemo/README.md` 与 `docs/PLUGIN_GUIDE.md` 文首的形态说明。
  窗体界面照常用 **`.lfm` 设计**（单元里写 `{$R *.lfm}`，字段与事件方法放类声明的
  默认段；`.lpi` 不用单独登记资源），不想用 `.lfm` 也可以纯代码建窗。
  **操作步骤见 `docs/PLUGIN_GUIDE.md`**（含两种方案各自的接入步骤、`.lfm` 注意点、
  常见问题），原理与方案对比见 `docs/PLUGIN_FEASIBILITY.md`。

> **安全 / SQL 注入**：框架层不碰 SQL、没有 SQL 端点，浏览器只送控件值；
> 注入风险在业务代码——凡是来自控件/AJAX/URL 的值，进 SQL 前一律用
> `ParamByName`（`ORDER BY`/`LIMIT` 用白名单或数值化）。完整信任边界、
> demo 范例与自检清单见 `docs/SECURITY.md`。

现有工程一键迁移：

```
tools\lwconvert.exe <项目目录> --convert <输出目录>
tools\lwconvert_gui.exe                :: GUI 版：选目录→分析/转换→看报告
```

改写内容：`.pas` 基类与 uses、`.lpr` 启动代码、`.lpi` 重新生成为 nogui
工程，附控件支持度报告。IDE 里也有两个入口（设计期包 `lwdesign`）：

- **Tools → 将 Lazarus 工程转换为 lazarusWeb…**：直接在 IDE 内打开转换
  向导（`ulwconvertgui` 窗体编进 `lwdesign` 包，不启动外部 exe；与
  `lwconvert_gui.exe` 共用 `lwconvert_core`，结果一致）。仓库根优先由
  `lwdesign.lpk` 反推，其次读 `LW_ROOT` / `LAZARUSWEB_ROOT`；当前工程
  目录自动预填到「源工程目录」。
- **New Project 向导**：一个模板，选中后弹三框：应用模式 / 工程类型 /
  工程模板；另有 New Form + 组件面板。

### 用 IDE 向导新建工程（从头建一个）

**前置：按顺序把四个包装进 IDE**（只需一次，换新版包后要重做）

四个包有依赖链，**顺序不能颠倒**：`lwcore` → `lwserver` → `lwvst` →
`lwdesign`（`lwserver` 依赖 `lwcore`；`lwvst` 依赖 `lwcore` + VirtualTreeView
系列包，是 GUI 专属包；`lwdesign` 依赖前三包 + IDEIntf）。跳步会在 Install
`lwdesign` 时报 `Can't find unit lwcore / lwserver / lwdbvst`。

| 顺序 | 包 | 类型 | IDE 操作 |
|---|---|---|---|
| 1 | `src\lwcore.lpk` | RunAndDesignTime | 只 **Compile**，不 Install |
| 2 | `src\lwserver.lpk` | RunAndDesignTime | 只 **Compile**，不 Install |
| 3 | `src\lwvst.lpk` | RunAndDesignTime | 只 **Compile**，不 Install（GUI 专属，必须用 IDE 的 win32 widgetset，不能 `--ws=nogui`） |
| 4 | `src\design\lwdesign.lpk` | DesignTime | **Compile → Use → Install** → 重建 → 重启 |

0. 先命令行登记四包（否则新建工程报「找不到包」）：
   `tools\install_design.bat`。`--add-package-link` 只登记不安装，正常。
1. 打开 Lazarus，**按上表顺序**逐包 `Package → Open Package File → <包>.lpk`：
   前三个只点 **Compile**；第四个（`lwdesign`）点 **Compile → Use → Install**，
   弹窗问是否重建 IDE 时选「是」，等重建完**重启 Lazarus**。
2. 注意：不要在 IDE 里 Compile `lwserver.lpk`（nogui 单元不在 IDE 搜索路径，
   报 `Can't find unit noguiint`，见 `NOTES.md` 坑 15）；交给命令行
   `lazbuild` 即可。设计期包安装弹 `Descriptor.Name empty` 见坑 16。

装好后 **文件 → 新建 → 项目** 里才会出现一个模板 **lazarusWeb**（选中后弹
下面的三框）。没装（或装的是旧版）时新建对话框里看不到它；Tools 菜单里的
「**生成 lazarusWeb 窗体模板（当前单元 LFM）**」同样来自 `lwdesign` 包——
这是**另一个功能**（按当前窗体 .lfm 生成 HTML 模板，见 16.0），与新建工程
向导无关。改过包源码后必须重新 Compile → Install → 重启 IDE，否则菜单仍
执行旧逻辑。

**1. 选模板 —— 连弹三个选择框**

选中 **lazarusWeb** 后依次弹三个框（任一框点取消即退出，不动当前工程）：

第一框（1/3），应用模式：

| 选项 | 生成的工程 |
|---|---|
| **普通应用模式** | 普通 lazarusWeb 程序，浏览器访问服务（历史行为，一字不变） |
| **服务(daemon)模式** | 额外生成 `uDaemon.pas` / `uMapper.pas` / `lazarusWeb.ini` 宿主层，`.lpr` 带 `DaemonApp` 分流：**同一个 exe 既能前台运行，也能 `--install` 注册成 Windows 服务**（详见 `WINDOWS_SERVICE.md`） |

第二框（2/3），工程类型档位：

| 选项 | 档位 | 编出来的程序 |
|---|---|---|
| **lazarusWeb project** | `$APPTYPE GUI`，默认 widgetset | IDE 里 F9 直接跑，**无**黑窗口（调试用） |
| **lazarusWeb project(nogui)** | `$APPTYPE CONSOLE` + `LCLWidgetType=nogui` | 纯控制台服务，只有**黑终端**（部署用） |

第三框（3/3），工程模板：

| 选项 | 生成的 `.lpr` |
|---|---|
| **常规模式** | 常规工程：`uses lwapp, umain`，`TLWApp.Register(TMainForm)` |
| **插件模式** | **多进程插件框架**：宿主工程（`uses upluginproc, upluginauth, ulogin, umain`；启动时 `TLWApp.SetLogin(TLoginForm)` + `LWAuthRegister` → `PlugDiscover` → `PlugRegisterRoutes` → `PlugLaunchAll`，主窗体是侧栏菜单 + `TPageControl` 的插件工作台）+ `common\upluginproc.pas` + `common\upluginguard.pas`（启动守卫：令牌 + 父进程校验，插件 exe 不能单独运行）+ `common\upluginauth.pas`（角色鉴权、菜单过滤、`/p/` 无权限 403、身份签发）+ `common\upluginidentity.pas`（插件侧验签读"当前用户"）+ `ulogin.pas`（默认带图形验证码）+ `plugins\hello\` 示例插件工程（独立 exe）+ `build-all.bat` / `stop-all.bat`（Windows）及 `build-all.sh` / `stop-all.sh`（Linux/macOS，LF 行尾）/ `README.md`。Linux 上清单仍写 `exe=xxx.exe`，`upluginproc` 自动退回无后缀产物并给 `.run/` 副本补执行位。宿主 `.lpi` 的 `OtherUnitFiles` 自动指向 `common`；插件清单根目录 = `<宿主 exe 目录>\plugins`。演示账号 `admin / analyst / guest`，口令 `123456`；清单 `roles=admin,analyst` 控权限。不需要登录就删 `.lpr` 的 `SetLogin` / `LWAuthRegister` 两行；只删菜单过滤、不删路由鉴权会留下越权访问 |

三个框都选完**不写盘**：工程此刻是"虚拟"的，`.lpr` / `umain.pas` / `.lfm`
（服务模式还有 `uDaemon.pas` / `uMapper.pas` / `lazarusWeb.ini`）的源码全在
内存里，标题栏是 `LWApp1 (*lpi)`；插件模式的 `common\` / `plugins\` 一整套不是
宿主工程单元，由保存钩子在落盘之后补写（已存在的文件不覆盖）。
这与 Lazarus 自带模板的流程完全一致。

> 服务模式的三个附加文件在**落盘之前内容就已完整正确**，不靠保存钩子事后
> 补写；其中 `uMapper.pas` 用代码构造 `DaemonDefs`，**不需要 `.lfm` 资源**
> （见 `NOTES.md` 坑 195）。

**2. Ctrl+S 才落盘**

弹出的就是 Lazarus 标准的"保存项目"对话框：

- **目录**默认取 IDE 选项里的"项目构建测试的目录"；如果上次存到过别处，
  这里会显示上次的目录（例如 `C:\3`），直接在对话框里改成你要的目录即可，
  改一次以后就默认用它；
- **工程名**别用 `LWApp` —— 它和框架单元 `lwapp.pas` 同名，编译必报
  `Duplicate identifier "LWAPP"`。默认给的是 `LWApp1`，是安全的；要改就用
  `LWApp2` / `MyApp` 之类。

**3. 落盘结果**

```
<目录>\LWApp1.lpr  LWApp1.lpi  umain.pas  umain.lfm
       build.bat   build.sh    favicon.ico
       lw\        ← 前端资源（lw.js/lw.css/alpine.min.js…）
```

服务(daemon)模式再多三个文件（同样在 Ctrl+S 时一次落盘，新建时 IDE 会给它们
各开一个标签页，可以当场改服务名/端口）：

```
       uDaemon.pas   ← 守护类 + worker 线程（RunService / 非 SCM 停止 Halt）
       uMapper.pas   ← TDaemonMapper 子类，stAuto 自启；服务名随 Ctrl+S 时填的工程名走（写盘前自动改好），详见 SERVICE_NAMING.md
       lazarusWeb.ini ← port= / log= / client=（固定名，运行期自动找）
```

`build.bat` / `build.sh`、nogui 档的 `.lpi` 宏、`favicon.ico`、以及 `lw\` 里的
前端资源，IDE 的工程模型都写不出来，由向导在**保存后约 1 秒**补齐（运行期按
`exe\lw\<文件>` 找静态资源，所以拷到工程目录下的 `lw\`）。

`favicon.ico` 放在**工程根目录**（不是 `lw\`）：服务端取图标的顺序是
`<root>\favicon.ico` → `<exe 目录>\favicon.ico`，而 exe 就在工程目录里。
少了它浏览器标签页是空白图标（`/favicon.ico` 直接 404）。想换成自己的图标，
直接覆盖工程目录里的 `favicon.ico` —— 已经有了向导就不再动它。

**4. nogui 档：多一步"重新加载"，否则 F9 用错 widgetset**

保存后约 1 秒会弹出：

> **nogui 档：重新加载工程后生效** —— 已为工程写入 LCLWidgetType=nogui…

点 **"是"**，IDE 立刻按新的 `.lpi` 重读工程，之后 F9 就是无窗口的控制台
服务。点"否"也行：`.lpi` 已经是 nogui，用工程目录里的 `build.bat` 编译即可，
下次打开工程自动生效。

> **注意：保存后 1 秒内按 F9，用的还是 win32 widgetset** —— 宏刚写进
> `.lpi` 文件，IDE 内存里的工程选项还没重读，编出来照样会弹服务端面板窗口。
> 等那个询问框出现、点"是"之后再 F9 就对了。

**5. 出问题时**

- **弹"文件未找到 …\umain.pas"**：工程目录只剩半截文件（`.lpi`/`.lpr` 在、
  `umain.pas` 没有）。这是早期版本在保存事务里重载工程留下的（详见
  `NOTES.md` 坑 172），当前版本保存期间不弹框、不重载，不会再出现。
  处理：**项目 → 关闭项目**，重新新建一个。
- **F9 仍然弹出面板窗口**：确认弹"重新加载"时点了"是"，且工程不是改名后
  又用旧 `.lpi`；也可直接用工程目录里的 `build.bat` 对比（nogui 档里是
  `lazbuild -B --ws=nogui <工程名>.lpi`，GUI 档不带 `--ws`）。
- **看日志**：`%TEMP%\lazarusweb-wizard.log` 每次补写记一行 —— `.lpi` 路径、
  档位（`headless=gui|nogui`）、是否插入宏（`widgetset: inserted=True`）、
  客户端资源拷了几个文件、有没有在等保存结束（`保存还没写完，等下一轮`）。
  补没补上，看这个文件最直接。

非 IDE 场景（CI、脚本化出工程）：

```
tools\lwnew.exe --name=CliDemo --dir=D:\proj\CliDemo --gui
```

同一套骨架，同样会把 `src/client` 拷到工程下的 `lw\`。

### 移动端：手机 / 窄窗口自适应（业务代码零改动）

Alpine 渲染层（默认）内置移动端自适应，判定在浏览器端完成，服务端不参与：

- **自动判定**：视口宽 ≤834px 进入移动布局，≥1100px 退出，835~1099 为
  回滞区保持现状（拖窗口、软键盘弹收都不会来回抖动）；手机、平板、
  桌面窄窗口都会自动进入。触屏细节（输入框字号 ≥16px、去双击缩放
  延迟）由指针能力独立判定，与窗口宽度无关；
- **没配模板的窗体（两端一致：设计期所见即所得）**：移动端按设计尺寸
  原样渲染（**字号不缩小**），超出屏幕的部分由页面滚动平移查看——能用，
  但不是为小屏优化的排布；桌面端是绝对定位原样（历来行为，完全不变）；
- **配了模板的窗体**：模板只是背景/装饰层，控件始终按 LFM 的绝对坐标
  渲染，事件与增量补丁不变；`<窗体名>.html` 文件头的 `lw-tpl-mode`
  决定是浮窗还是整页平面模式（flat 优先）。两种模式都不重排控件；
- **手动切换**（演示 / 排障）：URL 加 `?layout=mobile` 或 `?layout=desktop`；
  控制台 `LW.layout.set('mobile'|'desktop'|'auto')`、`LW.layout.get()`；
  选择存 `sessionStorage['lw-layout']`，只影响当前标签页；
- 写模板的方法与完整范例见第二篇「16. 窗体模板开发指南（窗口 + 平面）」；
  一键生成用 IDE Tools 菜单（选窗口/平面模式，桌面写 `<窗体名>.html`、
  移动写 `<窗体名>.m.html`），模板改动刷新即生效，无需重编。

### 拍照：TLWCamera（手机唤起系统相机，桌面页面内取景）

组件面板拖 `TLWCamera`（`TLWFileUpload` 的专用后代）到窗体上，写一个事件：

```pascal
procedure TMainForm.camPhotoCapture(Sender: TObject; const AFileName: string);
begin
  // AFileName 是服务端上的完整路径（%TEMP%\lw_uploads\<会话>\<控件名>\xxx.jpg），
  // 直接 TFileStream / 后续入库处理即可；预览不在服务端做
end;
```

按下拍照按钮后浏览器按环境自动选路（**同一份代码，无需判断**）：

| 环境 | 行为 | 前提 |
| --- | --- | --- |
| 手机 / 平板 | `<input capture>` 唤起**系统相机 App**（默认后置，`Facing := cfFront` 前置），拍完经 `/lw/api/upload` 传回服务端落盘并触发 `OnCapture` | 无，局域网 http 可用 |
| 桌面 + HTTPS/localhost | **页面内取景弹层**（getUserMedia）：实时画面 + 「拍摄 / 取消 / 选择图片」，拍下的帧压到长边 1600px 转 JPEG 走同一上传通道 | 需要安全上下文 |
| 桌面 + 局域网 http | 退化成「选择图片文件」对话框（浏览器禁止 http 页面调摄像头，这是硬限制） | — |

- 回显预览：把窗体上某个 `TImage` 的 Name 填进 `TLWCamera.PreviewImage`
  （如 `imgPhoto`），浏览器拍完**立刻本地显示**（不走服务端补丁——手机
  照片几 MB，转 base64 塞进组件树会让之后每次增量补丁都白跑）；
  服务端 `TImage.Picture` 始终为空，要服务端缩略图/入库自己处理文件；
- 大小上限 `MaxSizeKB`（KB，0 不限）、保存目录 `TargetFolder`（留空用
  会话上传目录）与上传按钮同语义；`UploadedFiles`/`LastFileName` 可查历史；
- `OnUpload` 与 `OnCapture` 都会触发，业务里挂一个就够；
- 可跑范例：`demos/mobile_demo`（拍照 + 本地预览 + 日志，配了桌面/移动
  两份模板，手机打开体验完整）；回归 `tests/cdp_camera.py`。

### 登录窗体的图形验证码（TLWCaptcha）

TLWLoginForm 的验证码是「拖一个控件就启用」，不写一行代码：

1. 组件面板 **lazarusWeb** 页把 `TLWCaptcha` 拖到登录窗体上
   （它就是可视控件，尺寸 = 图片尺寸，默认 110×34）；
2. 再放一个 `TEdit` 当输入框，名字用约定的 **`edCode`**。
   不按约定命名也行：基类先找名字里带 `code` / `captcha` / `vcode`
   的编辑框，最后退化成「除用户名、密码之外的第一个 TEdit」；
3. 完事。`TLWLoginForm.TryLogin` 会**先验码、再验账号密码**（顺序不能反：
   先查账号就等于给暴力枚举开后门），码错推一条 Toast 并自动换一张图。

细节：

- 比较忽略大小写和首尾空格；**一枚码只允许试一次**（比完即作废，
  失败自动换图），同一张图无法反复猜；
- 「点图片换一张」是纯前端动作（`src` 后追加 `&r=<时间戳>`），
  不占会话执行锁、不等一次往返；服务端见到 `r` 就重新生成答案。
  服务端主动换图（登录失败、业务代码调 `RefreshCaptcha`）走的是
  版本号 `&v=`，补丁里 `src` 变了浏览器才会重拉；
- 图片是服务端用内置 5×7 点阵字模 + FPImage 现画的 PNG：零字体、
  零 widgetset 依赖，nogui 档一样出图；
- 深色主题不重画第二张图，客户端用 `filter: invert(...)` 反相，
  所以切换主题不会多一次请求；
- 不想用：窗体上不放 `TLWCaptcha` 即可（**老工程完全不受影响**，
  验证码只在窗体上真有这个控件时才校验），或把 `RequireCaptcha`
  设成 `False`；
- 想调：`Left/Top/Width/Height` 定位置与大小，`CaptchaLength`（2..8，
  默认 4）定字符数；业务代码可调 `RefreshCaptcha` 主动换图
  （例如账号被锁定后强制换码）；
- 排障：设环境变量 `LW_CAPTCHA_DEBUG=1` 启动，服务端把
  `[lw] captcha <令牌> = <答案>` 打到 stderr —— 用来分清到底是
  「码不对」还是「图不对」（生产环境别开）。

### 登录字段挑战-响应（SecureLogin，默认关闭）

TLS 保护的是链路；如果还想让**口令原文根本不进网络载荷**，开
`TLWLoginForm.SecureLogin`：

```pascal
procedure TLoginForm.AfterConstruction;
begin
  inherited AfterConstruction;
  SecureLogin := True;          // 默认 False，老工程不受影响
  OnLogin := @DoAuth;
end;
```

开启后（前提：窗体上有 `TLWCaptcha`，它提供一次性令牌）：

1. 浏览器提交登录时，把 `edUser` / `edPass` / `edCode` 三个字段替换成
   `SHA256(令牌|值)` 再放进事件载荷 —— 口令原文不离开浏览器；
   用户名统一转小写、验证码统一转大写去空格，与明文校验的大小写语义一致；
2. 服务端 `TryLogin` 用同一令牌复算验证码答案的摘要比对（`LWCaptchaCheckHashed`），
   令牌随验证码**一次作废**，抓到的摘要无法重放；
3. `OnLogin` 收到的是摘要，业务层用 `LoginNonce` 复算账户名与口令：

```pascal
if SecureLoginActive then
  AOk := LWAuthLoginHashed(AUser, APass, LoginNonce, RealUser, Roles, Disp, Err)
else
  AOk := LWAuthLogin(AUser, APass, Roles, Disp, Err);
LWAuthSessionSet(RealUser, Roles);   // 必须写真实用户名，不能写摘要
```

约束与边界：

- 服务端要能拿到**明文口令或等价摘要**才能验证挑战（演示账号是源码常量，
  天然满足）。若库里存的是 bcrypt 这类不可逆哈希，应改用 SRP/PAKE，
  或退回"仅 TLS"；
- 用户名也参与摘要，账户表需逐个复算匹配；账户量大时建议在库里加
  `SHA256(盐|用户名)` 索引列，或只哈希口令（`SecureLogin` 仍可开，
  但需自行调整前端字段范围）；
- `--no-captcha` / `RequireCaptcha=False` 时没有一次性令牌，自动退回明文
  并在日志告警 —— 不要在没有验证码的窗体上强行开启；
- 前端脚本 `src/client/lw-alpine.js` 内置同步 SHA-256；服务端
  `lwbase.LWSha256Hex` 是自包含实现，不依赖 fcl-hash。

### 登录窗体开箱即用：新建就有验证码

两种新建方式都自带验证码，不用自己摆控件、不用写校验代码：

- **IDE 文件 → 新建 → `lazarusWeb Login form`**：模板 .lfm 里已经放好
  `lblCode` / `captcha1` / `edCode`（还有两个按钮挂好基类的
  `DoLogin` / `DoReset`），改了设计期包记得在 IDE 里重编一次；
- **新建普通窗体、基类改成 `TLWLoginForm`（或 `SetLogin(TLWLoginForm)`
  直接用基类）**：窗体上一个控件都没有时，基类在 `AfterConstruction`
  里按同一套坐标自动补建 用户名 / 密码 / 验证码 / 两个按钮
  （`AutoBuildUI`，默认开）。设计期看不到这套控件，但跑起来就有；
  一旦你自己摆过任何控件（lfm 或 `FormCreate` 里建的），它就不再插手。

### 登录会话什么时候失效

sid 存在 **sessionStorage**（`lw.sid`）里，不是 localStorage，也不是 cookie：

- 刷新页面 —— 还在同一个标签页里，不会刷一下就掉登录；
- **关掉这个标签页 —— sessionStorage 随页签销毁，下次打开必须重新登录**
  （"关标签页即退出"，与桌面程序"关窗口 = 退出"同一个心智）；
- 关掉浏览器 —— 当然也退出；
- **浏览器"启动时恢复上次打开的网页"也一样退出**：恢复会话会把
  sessionStorage 连同 sid 一起还原，所以客户端在 `pagehide` 留一枚
  墓碑（`lw.bye` = 卸载时刻）。卸载到下一次加载只隔几十毫秒的算"刷新"，
  保持登录；隔了 3 秒以上才回来的（= 中间关过窗口）不认旧 sid，重新登录。
  判据用 `performance.timeOrigin`（本次导航开始的时刻）减去墓碑时刻，
  页面自己加载多久不计入，所以服务器慢也不会把刷新误判成关过窗口。
  阈值 `BYE_GRACE_MS = 3000`，写在 `lw-alpine.js` / `lw.js` 里；
- 每个标签页各自一个会话：同一浏览器开第二个标签页是**新会话**，
  不会自动共享上一页的登录身份（要共享就显式带着同一个 sid 打开，
  框架的 `/lw/api/attach` 仍然在，见 `docs/ARCHITECTURE.md` 2.3）；
- 不带端口名：sessionStorage 本来就按源（协议+主机+端口）隔离，
  同机跑多个 demo 天然互不干扰。

要「记住我」（跨页签、跨浏览器重启都保持登录），在页面里设
`localStorage['lw.persist'] = '1'`；调试时想强制开新会话，URL 加
`?fresh=1`。老版本留在浏览器里的会话 cookie（`lw_sid_<端口>`）
会在启动时被顺手清掉，不会影响新语义。

### 状态栏（TStatusBar）：分格宽度/对齐都照 LFM 画

把 `TStatusBar` 拖到窗体上（默认 `Align=alBottom`），在 IDE 里设
`Panels`（每格的 `Text` / `Width` / `Alignment` / `Bevel`），浏览器端就是
一条和桌面端同构的分格栏：

- **高度** 取 `TStatusBar.Height`，按窗体的 `DesignTimePPI / 当前 PPI`
  折算（144PPI 设计、96PPI 运行时 → 34 变 23），和子控件坐标同一把尺子；
- **分格宽度** 用 `Panels[i].Width`，**最后一格延到右边缘**（LCL 的
  `SB_SETPARTS` 规则）；格与格之间有 1px 分隔线，`Bevel=pbNone` 的格子没有；
- **对齐** `taLeftJustify / taRightJustify / taCenter` 分别映射到
  `text-align`；文本太长按格宽裁掉（`ellipsis`），不会撑开格子；
- 状态栏宽度 = 客户区宽度：窗体外框用 inset 阴影画，不占盒模型
  （否则客户区比 LFM 的 `Width` 少 2px，`Align=alNone` 的容器会溢出）；
- `SimplePanel=True` 时只显示 `SimpleText`（与 LCL 一致）；
- 文本由业务代码写：`stbMain.Panels[0].Text := '就绪';` —— 服务端改了，
  下一次补丁就把新文本送到浏览器（`demos/multi` 的第二格显示行数）。

需要自定义样式时改 CSS 变量或 `.lw-statusbar` / `.lw-status-item` 两条规则，
不影响服务端。

### 多级表头（TLWDBGrid.HeaderGroups）

LCL 的 `TDBGrid` 表头只有一行，要"多表头"用框架扩展的 `TLWDBGrid`（lfm 里
网格类名就写 `TLWDBGrid`，FPC 的 GetClass 只认精确类名）：

```pascal
uses lwdbgrid;

with grdMain.HeaderGroups do
begin
  Add('基本信息|0-2');     // 标题|起-止：起/止是"可见列"下标（0 起、含止）
  Add('价格与库存|3-5');
end;
// 没写进任何分组的列自己贯通两行（上下两行合成一格）
```

- 隐藏列（`Visible=False`）不占列号，分组按可见列从左数；
- 分组表头点击不产生 `OnTitleClick`（跨列标题没有唯一列），叶子表头照常回发；
- 两行表头整体粘在网格顶部，滚动时不会散开；
- 演示见 `demos/db` 与 `demos/gallery`（数据感知 / 大表分页两个页签）。

### Caption 里的 `&`（加速键 / 助记符）

跟 LCL 一样，`Caption := '确定(&O)'` 在网页上显示成 **确定(O)**，`O` 带下划线，
按 `Alt+O` 等于点了这个按钮——`&` 不会露出来。规则是**按控件**的：

- 解析：TLabel、TStaticText、按钮族、TCheckBox/TRadioButton、
  TRadioGroup/TCheckGroup（标题与选项）、TGroupBox、TPageControl/TTabControl
  页签、TMenuItem；
- 不解析：**TPanel.Caption**（`TCustomPanel.ShowAccelChar` 默认就是 False）、
  显式 `ShowAccelChar := False` 的任何控件、TListBox/TComboBox/TCheckListBox
  的 `Items`、`TStatusBar.Panels[].Text`、窗体标题；
- 想写字面 `&` 就写两个：`'A && B'` → `A & B`。

演示：`demos/accel`（每类控件一个，点一下回显到日志标签），
验收：`tests/cdp_accel_audit.py`（Alpine + Ext 共 114 项断言）。

## 5. 配置

命令行参数（完整表以 `src/core/lwapp.pas` 的 `--help` 为准）：

```
--config=path  --port=  --root=  --form=  --client=alpine|ext  --ext=
--extdir=  --theme=  --title=  --timeout=  --trust-proxy  --ajax-cors
--ssl  --ssl-host=  --ssl-cert=  --ssl-key=
       （--tls-cert= / --tls-key= 是后两个的别名；给了证书或私钥即自动开 HTTPS）
--verbose  --nogui  --patch=1  --log=path  --help
```

INI 配置（模板 `lazarusWeb.ini.sample`，放 exe 旁改名 `<exe名>.ini` 或
`lazarusWeb.ini`）：`Port` / `Theme` / `ExtDir` / `Patch` / `Client` /
`SSL` / `SSLHost` / `SSLCert` / `SSLKey`。
优先级：**内置默认 < 配置文件 < 命令行**。编码须 UTF-8 或纯 ASCII。

`--ssl-host` / INI `SSLHost` 是证书主机名，填浏览器地址栏中的域名或 IP，
须与证书 SAN 一致；它不是监听地址。正式 CA / 私有 CA 的非自签证书命令行
范例见 `deploy/README.md` §1.1。

渲染层二选一（**默认 Alpine.js**：`--client` 不指定时自动探测——两套都
可用优先 alpine，只有一套用在那套；alpine 文件内置恒可用，所以实际默认
就是 alpine）：

- `alpine`（默认）：Alpine.js 3.14.9（内置 `src/client/alpine.min.js`），
  **不需要 ext 目录**，部署最轻；
- `ext`：Ext JS，需要 `ext-x.x.x/` 目录（约 75MB）；`--client=ext`、
  INI `Client=ext` 或 URL `?client=ext` 显式启用。协议两者完全一致。

### 5.1 Alpine 渲染层的配色（7 套 + 跟随系统）

只有 Alpine 渲染层有这一套（Ext 层仍用 `--theme=` 选 Ext 主题）。

**7 套配色，分两个色系**：

| 配色 | 名称 | 适合 |
|---|---|---|
| `light` | 亮色 | 默认，蓝灰商务风 |
| `paper` | 米黄纸张 | 长时间阅读表格/文档，暖色护眼 |
| `mint` | 护眼绿 | 白底偏绿的护眼环境 |
| `contrast` | 高对比 | 白底纯黑字+黑边框，强光/投屏/色弱 |
| `dark` | 深色 | 通用深色 |
| `midnight` | 深蓝夜色 | 更冷更蓝的企业后台夜色 |
| `forest` | 墨绿夜色 | 深色里偏绿，长时间盯日志舒服 |

外加 `auto`（跟随系统，解析成 light 或 dark）。

- 窗体标题栏右侧的 ☀/☾/◐ 按钮，点开是这 8 项；**图标形状表示色系**
  （太阳=浅色系、月牙=深色系、半圆=跟随系统），**填充色是当前主题的强调色**；
  选择存 `localStorage['lw-theme']`，刷新、多标签页保持一致；
- "跟随系统" 监听 `prefers-color-scheme`，系统切深色时页面即时跟着变；
- 设计期可在对象检查器设窗体属性 `LWTheme`（`twAuto`/`twLight`/`twDark`/
  `twPaper`/`twMint`/`twMidnight`/`twForest`/`twContrast`，缺省 `twAuto`）
  作为**首次默认值**；用户手动选过之后以用户本地选择为准；
- 代码里想强制切换：`LW.theme.set('midnight')` / `$lwTheme.set('paper')`
  （`LW.theme.get()` 读偏好含 auto，`LW.theme.current()` 读实际生效值，
  `LW.theme.dark()` 判断当前是不是深色系，`LW.theme.modes()` 列全部可选项）；
  不想显示标题栏按钮：`LW.theme.button(false)`；
- 换主题时会派发 `lw:themechange` 事件，`detail = { theme, pref, dark }`。
  **判断深浅请用 `detail.dark`**，别写 `theme === 'dark'` —— 深色系有三套；
  自己画 canvas 的业务代码应监听它重绘；
- 配色全在 `src/client/lw-alpine.css` 顶部（`:root` 亮色 + 深色基准块 +
  各变体覆盖块，共 61 个 `--lw-*` 变量），组件规则里没有颜色字面量。
  新增主题的做法与约束见文件头注释和 `NOTES.md` 坑 174。

> 用了旧工程、看不到新配色？前端资源在**工程目录的 `lw/`** 里，是拷贝副本。
> 把新版 `src/client` 的三个文件重新拷进去即可：
>
> ```
> copy /Y src\client\lw-alpine.css <你的工程>\lw\
> copy /Y src\client\lw-alpine.js  <你的工程>\lw\
> copy /Y src\client\alpine.min.js <你的工程>\lw\
> ```
>
> 新建工程由向导自动拷，不用管。

## 6. 部署

最小目录（自包含，**默认 Alpine.js 渲染层，不需要 ext 目录**）：

```
yourapp.exe
src\client\alpine.min.js    Alpine.js 本体（44KB，defer 加载，不走 CDN）
src\client\lw-alpine.js     渲染/协调器（模板两层共用；自适应仅本层）
src\client\lw-alpine.css    样式，含 7 套配色的 CSS 变量（§5.1）
tpl\                        （可选：窗口/平面窗体模板 <窗体名>.html；Alpine/Ext 两层都读取）
favicon.ico                 （可选：浏览器标签图标）
cert\                       （可选：开 SSL 且用自有 PEM 时放 server.crt/server.key/ca.crt）
libssl-3-x64.dll + libcrypto-3-x64.dll  （可选：开 SSL 时必须放 exe 同目录）
```

三个 alpine 文件**缺一不可**：少 `alpine.min.js`（或 `lw-alpine.js`）会被
自动探测判为 alpine 不可用而回退 ext；少 `lw-alpine.css` 页面能跑但没有任何
样式。文件可平铺放（与 exe 同目录或 `lw\` 子目录均兼容，查找顺序见 README
「部署」节的扁平/半扁平布局表）。

Ext JS 渲染层为**可选**（默认不部署）：需要时把 `ext-x.x.x\` 放到 exe 旁
（完整约 75MB；精简版约 23MB，见 `tools\make_ext_min.bat`），并用
`--client=ext` 显式切换，前端文件换成 `lw.js` + `lw.css`。

### 站点图标（favicon）

浏览器标签上的小图标不靠框架画，**放一个 `favicon.ico` 文件即可**：

- 查找顺序：`--root` 指定目录 → exe 同目录 → 都没有时 `/favicon.ico` 回 204
  （浏览器显示默认图标，不报错）；
- 命中时返回 200 + `image/x-icon` + `Cache-Control: public, max-age=86400`
  （文件级缓存即可，改图标后用户侧最多一天内生效；**Ctrl+F5 立即刷新**）；
- Ext 版与 Alpine 版两套外壳的 HTML head 都已带
  `<link rel="icon" href="/favicon.ico" type="image/x-icon">`，无需改前端；
- 图标建议做多尺寸 ico（16/32/48px），SVG 不经转换在部分浏览器不生效；
- 排障：如果之前部署期间访问过（当时回 204），浏览器可能把空响应缓存了——
  强刷一次或关掉标签重开即可；
- 反向代理无需为 favicon 配置任何转发规则（由应用自身直答，不经 worker）。

**注意**：升级自旧版本时用户浏览器很可能缓存了旧 204 空响应，发布说明里
提醒一次 Ctrl+F5。

- HTTPS 两种做法：① **FPC 自带**：业务 exe 或 lwhyper 加 `--ssl`，
  证书不给就自动生成自签证书，随包带 `libssl-3-x64.dll` +
  `libcrypto-3-x64.dll`（集群只在 lwhyper 外层开，worker 仍明文，见坑 160）；
  用正式 CA 或私有 CA 证书时加 `--ssl-cert=/--ssl-key=`，`--ssl-host=` 填
  证书 SAN 中的域名/IP，完整范例见 `deploy/README.md` §1.1；
  ② nginx/Caddy 反代终结，示例在 `deploy/nginx.conf`、`deploy/Caddyfile`
  （含 `/lw/ws` Upgrade、`/lw/api/poll` 不缓冲、100MB 上传上限、`/ext/` 缓存）；
- TLS 安全基线：当前随包 OpenSSL 3.x 实测支持 **TLS 1.2 / TLS 1.3**，
  应用内不提供最低版本、cipher suite、mTLS、HSTS 或证书热重载配置；需要
  这些能力时在 nginx/Caddy 外层显式配置并终结 TLS。项目未显式启用 HTTP/2，
  `TFPHttpServer.UseSSL` 不等于浏览器一定走 h2；
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
| 浏览器标签没图标（还是默认地球） | exe 同目录或 `--root` 没有 favicon.ico → 放一个；或浏览器缓存了旧 204 空响应 → Ctrl+F5 强刷（坑 144） |
| **本机 127.0.0.1 能开、所有手机/平板同时打不开**（换 Wi-Fi 或重启后突然全挂） | 先查本机入站，不用翻代码：`Get-NetConnectionProfile` 看当前是 Private 还是 Public，再 `Get-NetFirewallRule -DisplayName 'mobile_demo' \| select Profile` 看放行规则落在哪个 Profile —— **两者不一致时入站全被丢**，回环不受影响，所以"本机能开、设备全挂"。管理员运行 `tools\allow-firewall.bat`（写 `profile=any` 的 TCP/UDP + 端口兜底），不用重启服务（坑 159） |
| 手机/平板打不开网页（"已丢失网络连接"/无法访问），但某个设备能开 | ① **URL 必须带端口**（`http://192.168.x.x:8090/`），只写 IP 会走 80 端口，服务端没监听；横幅 `LAN:` 行给的就是该用的完整地址。② iOS：设置 → 隐私与安全性 → **本地网络** → 允许 Safari（被拒一次会一直静默失败）。③ 确认三台设备在同一 Wi-Fi/同一网段，不是访客网络或 5G 独立 SSID。④ 关掉 VPN / 代理 / iCloud 专用代理。⑤ 用 `/lw/healthz` 单独验证：能返回 ok 说明网络通、问题在页面层 |
| 手机打开后控件没重排 | 新机制下模板不重排控件，控件始终按 LFM 绝对坐标；超出视口由平移滚动查看 |
| 改了模板没生效 | 模板应是 `<root>\tpl\<窗体名>.html`，文件头要有 `lw-tpl-mode:window|flat`；客户端脚本有缓存 → `Ctrl+F5` 强刷排查；若同时存在旧 `.flat.html`，会因兼容规则继续走平面模式 |
| 选了窗口模式却仍整页显示 | `tpl\` 里残留旧 `<窗体名>.flat.html`，删除它后强刷；或 `.html` 文件头写的是 `lw-tpl-mode:flat` |
| 从 AI 终端/脚本启动的服务跑一会儿就消失、无日志 | 命令跑在 kill-on-job-close 的 Job Object 里被回收；后台任务方式也可能在轮次结束后被收走 → 用 `Start-Process`（脱离 Job）或真实用户终端启动（坑 108/145） |

更多案例与调试方法论：`docs/DEBUGGING.md`；212 个坑按编号检索
`docs/NOTES.md`（坑 23/66/108 等旧结论已被后续坑修订，以标注为准）。

## 9. 已知限制

- 模态超时 180 秒；同一会话同时只能有一个对话框；
- `TOpenDialog` 不能浏览服务端磁盘（只能上传文件）；
- `TSplitter` 可拖动调整位置（坑 186）；`Anchors` 不做前端吸附计算；
- 高 DPI 按 96 处理（125%/150% 设计的 lfm 自动缩回）；
- PDF 直出暂以浏览器"另存为 PDF"代替；会话外置 Redis 未实现；
- 未适配控件浏览器端灰框占位（服务端照常活着），不影响其他控件；
- `TLWCamera` 桌面取景是简化版（单帧拍摄，不能连拍/手动对焦/切换分辨率）；
  桌面局域网 http 页面**无法**调摄像头（浏览器硬限制），只能选图片文件，
  要完整桌面相机体验把页面挂到 HTTPS 或本机 localhost 访问。

---

# 第二篇 开发篇

## 10. 源码结构

```
src/
├── lwcore.lpk / lwserver.lpk      运行时包（IDE 自动生成，聚合单元）
├── lwvst.lpk                      GUI 专属可选包（VirtualTreeView，仅 IDE widgetset）
├── design/lwdesign.lpk            设计期包（IDE 向导/组件面板，依赖 lwvst）
├── client/                        前端运行时：lw.js lw.css lw-alpine.js lw-alpine.css alpine.min.js
├── lib/                           包编译产物（入库忽略）
└── core/                          全部核心单元（40 个）
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
| lwchart/lwui/lwweb/lwreport/lwlogin/lwcaptcha/lwcamera/lwpanel/lwrlog | 图表/仪表取色遮罩/富内容/报表/登录/图形验证码/拍照/面板/日志 |
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

深读：`docs/lazarusWeb工作原理详解.md`（含关键源码行号）；
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
6. 映射写进 `docs/lazarusWeb控件属性映射表.md`。

前端协议字段（payload/ops/tver/seq 游标）见 `docs/SCALE.md` §2 与
`docs/lazarusWeb工作原理详解.md`；改 lwproxyws 相关内容必须走 `gen_proxyws.py`
重新生成。

## 16. 窗体模板开发指南（窗口 + 平面）

模板**不再重排控件**：控件始终按 LFM 的 `Left/Top` 绝对定位，事件、增量
补丁、容器内部结构全部保持原样。模板只是一层背景/装饰 HTML，业务窗体
一行代码不改。窗口模式与平面模式**共用一个模板文件**
`<root>\tpl\<窗体名>.html`，由文件头的模式标记决定渲染方式：

模板按端分两个文件，**桌面端窗口/平面两种模式共用同一个 `.html`**：

| 端 | 模板文件 | 文件头标记 | 页面表现 | 无模板时 |
|---|---|---|---|---|
| 桌面·窗口 | `<root>\tpl\<窗体名>.html` | `lw-tpl-mode:window` | 现有浮窗，可移动/缩放，模板作客户区背景 | 设计期所见即所得 |
| 桌面·平面 | 同名 `.html` | `lw-tpl-mode:flat` | 整页网页：无标题栏/边框/拖动/缩放，页面自身滚动 | 同上 |
| 移动 | `<root>\tpl\<窗体名>.m.html` | 同上二选一 | 移动端只读这份模板（同为装饰层、控件不重排；窗体保持设计宽高，超出视口的部分左右滑动查看） | 直接 LCL 布局（不读桌面 `.html`） |

同一文件若同时出现两种标记，**flat 优先**。生成器窗口/平面两模式都各写
桌面 `.html` 与移动 `.m.html` 两份（模式靠文件头标记区分）；旧 `.flat.html`
仍保留兼容探测（存在即按平面模式），需要切换回窗口模式时请删除它。

### 16.0 一键生成：IDE Tools 菜单（lwdesign）

装了设计期包 `lwdesign` 后，IDE 的 **Tools 菜单**多一项
「**生成 lazarusWeb 窗体模板（当前单元 LFM）**」：

1. 打开窗体单元（.pas，自动找同名 .lfm）或直接打开 .lfm；
2. 点该菜单 → 弹出「窗口模式 / 平面模式 / 取消」选择；
3. 选完后在 `<工程目录>\tpl\` 下生成**两份**：桌面 `<窗体名>.html` 与
   移动 `<窗体名>.m.html`；两份都按所选模式写文件头标记（窗口写
   `lw-tpl-mode:window`，平面写 `lw-tpl-mode:flat`）。**桌面两种模式共用
   同一个 `.html`，不会生成第二份桌面文件**；文件已存在时逐份询问是否覆盖
   （覆盖后原模式标记一并替换）；
4. 生成内容：文件头注释列出解析到的顶层控件清单（类名 + 设计期
   `Left/Top/宽高`）、自检报告，以及一段 `<style>` + 空 `<div>` 装饰层。
   **没有** `{%控件名%}` 占位符，也没有流式/百分比宽/主区域伸缩 CSS；
   控件位置完全由框架按 LFM 绘制；
5. 把两份文件拷到**运行根目录**的 `tpl\`（或工程目录就是运行根目录时
   生成完即生效），强刷浏览器（`Ctrl+F5`，客户端脚本有缓存）即见效果；
   移动端只读 `.m.html`，删掉它则用 LCL 布局（不读桌面 `.html`）；
6. 设计期包改动后必须 **Package → Open Package File → lwdesign.lpk →
   Compile → Install → 重启 IDE**，否则菜单仍执行旧的一键生成逻辑。

解析范围：窗体**顶层可视控件**（按 Top/Left 排成视觉顺序）；数据源、
对话框、菜单、图片列表等非可视控件与状态栏自动跳过。解析按“对象层级 +
集合 item 块 + 括号字符串块”三态推进，`TListView.Columns` 这类集合中的
`end`/`end>` 与多行字符串中的 `end` 不再误伤对象层级（坑 163，
以 `demos/gallery/ugallery.lfm` 为回归样本）。空窗体也能生成空装饰层，
提示中会说明没有顶层可视控件。

回归：`tests/tplgen_test.lpr` 对 mobile_demo、gallery、dbaware 六个窗体与
`tests/fixtures/tpl_two_cols.lfm` 做字符串断言（含新断言：桌面单文件 +
移动 `.m.html` 两份、模式标记、无占位符、保留设计坐标），并保留旧流式
生成器的历史回归；`tests/run_fixed_regression.py` 为固定入口。

### 16.1 文件与路由

- 模板路径：先查 `<root>\tpl\`，找不到再查 `<exe目录>\tpl\`；桌面读
  `<窗体名>.html`（窗口/平面两模式共用这一个文件），移动端优先读
  `<窗体名>.m.html`。`--root` 未指定时由 `LWResolveRoot` 从当前目录/exe
  目录向上探测，不能简单等同于“永远是 exe 目录”；
- 下发：桌面请求 `GET /lw/tpl/<窗体名>.html`，移动端只请求
  `GET /lw/tpl/<窗体名>.m.html`（无模板不再读桌面 `.html`，回 LCL 布局），
  响应带 `Cache-Control: no-store` ——
  **改模板内容刷新页面即生效，不用重编译**；另外为兼容旧版本仍会探测
  同名 `.flat.html`，命中即按平面模式处理；
- 安全：文件名挡路径穿越（越界回 403）；模板不存在回 404，客户端
  静默回退设计期布局，页面不报错；
- 两层都支持：Alpine（`lw-alpine.js`）与 Ext（`lw.js`，`--client=ext`）走同一
  套模板机制——同一套 `lw-tpl-mode` 标记、同样兼容旧 `.flat.html`。两层的
  模板都只作背景装饰层，控件一律保持设计期绝对坐标，不重排；Ext 层在探测
  到 `flat` 时去掉标题栏/边框/拖动/缩放，宽高取 max(设计宽高, 视口)（窄屏
  保持设计宽、超出平移查看）。移动端 `.m.html` 的加载
  与回退由 Alpine 层负责（Ext 层无移动端布局机制，始终只读 `.html`）。

### 16.2 模板写法

模板 = 文件头模式标记 + 一段 `<style>` + 一个空 `<div>` 装饰层。
客户端把整段模板作为背景层挂进窗体客户区（插在最前、`pointer-events:none`），
控件 DOM 仍在客户区里按绝对坐标绘制，不存在 DOM 搬迁：

```html
<!DOCTYPE html>                       <!-- 仅平面模式需要 -->
<!-- lw-tpl-mode:flat -->             <!-- 或 window -->
<!--
  MainForm 的平面模式模板（起始骨架）
  顶层控件（设计期坐标供参考）：
    Button1 : TButton  (left=163, top=225, 113x38)
    ...
-->
<head>
<style>
  .tpl-mainform-flat { position: absolute; left: 0; top: 0; right: 0;
    bottom: 0; box-sizing: border-box; pointer-events: none; }
  /* 在这里加背景色/渐变/花纹/说明文字等装饰 */
</style>
</head>
<body>
<div class="tpl-mainform-flat"></div>
</body>
</html>
```

窗口模式是 HTML 片段（无 doctype/head/body），结构相同：模式标记 +
`<style>` + `<div>`。业务侧的工作量就是这一份 HTML；`.pas`/`.lfm`
完全不用动。**旧版 `{%控件名%}` 占位符模板不再驱动流式排布**：
其中的占位符会被替换成空 `<span>`，控件仍按设计期坐标显示，如需流式
排布请改回旧版客户端或手工重写业务布局。

### 16.3 常用 CSS 钩子

| 钩子 | 说明 |
|---|---|
| `.lw-tpl` / `.lw-tpl-backdrop` | 模板背景层（框架自动添加，铺满客户区、`pointer-events:none`） |
| `.lw-win.lw-flat-form` | 平面模式窗体根：无边框/标题栏/拖角，宽高不小于设计值（窄屏可平移） |
| `.lw-theme-fab` | 配色浮钮（圆形，平面模式与移动布局的窗口模式自动挂；可拖动、位置记忆；框架按布局自动挂/摘，标题栏图标同时隐藏） |
| `html[data-lw-layout="mobile"]` | 移动布局根标记（框架自动维护） |
| `html[data-lw-input="touch"]` | 触屏标记（与宽度无关） |

模板自己的类（例中的 `.tpl-mainform-flat`）只作用于装饰层；控件仍由
框架的 `.lw-n` 按 LFM 坐标定位，模板 CSS 不应再去改它们的 `left/top`。

### 16.4 断点、硬覆盖与回退（无模板窗体）

- 断点：视口 ≤834px 进入移动布局，≥1100px 退出，835~1099 回滞区保持；
  首次落点在回滞区时按触屏能力决定；
- 硬覆盖：URL `?layout=mobile|desktop|auto` > `sessionStorage['lw-layout']`
  > 自动判定；运行期 `LW.layout.set()/get()`；
- **没有模板的窗体（两端一致：设计期所见即所得）**：桌面端绝对定位
  原样（与历来行为完全相同）；移动端保持设计尺寸（字号原大），固定
  贴左、禁标题栏拖动，超出视口由 `#lw-root` 滚动平移
  （`html[data-lw-pan]`）；**不做整体等比缩放**（缩到 390 屏字号只剩
  0.3 倍不可读，实测后否决）；
- 有模板的窗体也遵循同一套几何规则：窗口模式不改窗体位置尺寸，
  平面模式宽高取 max(设计值, 视口)（窄屏保持设计宽、可平移查看，不压窄）；
  两种模式都不移动控件。
- **平面模式的底色跟随主题**：模板装饰层的背景/文字色请写
  `var(--lw-win-bg)` / `var(--lw-fg)`（生成器默认如此）。写死固定色会让
  所有主题都显示同一块底色。
- **主题入口按布局/模式自动切换形态**：桌面窗口模式用标题栏里的配色按钮
  （☀/☾/◐）；**平面模式**（标题栏整条被隐藏）与**移动布局的窗口模式**
  （标题栏只有 28px 高，22px 图标手指点不准）改用右下角的半透明圆形浮钮
  `.lw-theme-fab`。浮钮**可拖动**（位置记在 localStorage，刷新后仍在原处；
  平面模式与窗口模式各自记忆），点一下展开同一份配色菜单（按上下空间自动
  选展开方向）；移动布局下标题栏那个图标由 CSS 隐藏，桌面布局下浮钮会被
  自动摘掉 —— 两者不会同时出现。服务端 `LWThemeButton = False` 与模态
  窗体不挂。手机上没有 Alt 键，所以不能只提供快捷键。

### 16.5 测试

统一跑法见第 14 节；固定回归入口（文件/跟踪、模板生成器、TLS 参数校验与
HTTPS healthz，不依赖浏览器）：

```
python tests/run_fixed_regression.py
```

模板相关 CDP 探针（需无头 Edge，调试端口 9239；也可用
`python tests/run_fixed_regression.py --with-cdp` 一并执行）。
注意：`cdp_desktop_tpl.py`、`cdp_tplgen_gallery.py`、`cdp_tplgen_dbaware.py`
针对旧的「占位符 + DOM 搬迁」流式模板，新版本已改为不重排控件的背景装饰层，
这三项仅作历史回归参考，不再作为新模板机制的验收依据：

```
python tests/cdp_desktop_tpl.py    # 桌面模板：套用/几何不变/三态切换/无模板回退 7 项
python tests/cdp_tplgen_gallery.py # 生成器产物（gallery）：三档视口量主区域高度 7 项
python tests/cdp_tplgen_dbaware.py # 生成器产物（dbaware）：登录页 + 浮窗主窗体 6 项
python tests/cdp_dbaware_dark.py   # 深色主题帧内 HTML 可读性（坑 165）：
                                   #   前提 dbaware.exe --port=8155 LW_CAPTCHA_DEBUG=1
python tests/cdp_colorpicker.py    # 色块弹调色板锚点 + 选色回写链路（坑 166）：
                                   #   前提同上（与深色主题探针共用 8155）
python tests/cdp_dbaware_regress.py # 登录页竖线 + 关浏览器跳过登录（坑 167）：
                                   #   前提 dbaware.exe --port=8156 LW_CAPTCHA_DEBUG=1
python tests/cdp_mobile_demo.py    # 模板窗体：桌面/390/切回/硬覆盖/路由 19 项
python tests/cdp_fit_scale.py      # 无模板回退平移模式 23 项
python tests/cdp_device_probe.py   # 判定信号 8 场景
python tests/cdp_updown.py         # TUpDown 两端形态与联动 7 项
```

生成器解析/内容另有控制台测试（不依赖 IDE，直接 fpc 编译运行）：

```
fpc -FE. -FU. -Fu../src/design tests/tplgen_test.lpr
tests/tplgen_test.exe demos/gallery/ugallery.lfm tests/out_tpl
```

注意：CDP 模拟改视口用 `Emulation.setDeviceMetricsOverride` **直接叠加
新尺寸**，不要先 clear —— clear 会瞬间回到真实窗宽（1200，命中退出
断点），回滞区把误判锁死（MOBILE.md §8.8）。

## 17. 仓库注意

- 根目录 `src - 副本 (N)`、`src稳定版20261111`、`src高吞吐量` 等是历史
  快照，**唯一权威源码是 `src/`**；`demos/gallery - 副本` 同理；
- `demos/gallery/lw/` 等扁平部署副本会导致"改了 src/client 不生效"（坑 93）；
- `CrossSocket/` 目前无工程引用；`patches/` 是 FPC MIPS64 补丁（龙芯场景）；
- `packagefiles.xml` 是 IDE 用户包链接清单（含本机第三方包路径），不是构建脚本；
- `src/core/backup/`、`*.ppu/*.o`、`tmp/` 为本地产物，`.gitignore` 已覆盖。
