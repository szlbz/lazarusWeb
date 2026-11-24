# pluginsDemo —— 主程序 exe + 插件 exe 的页内插件工作台

和 `procdemo`（点按钮整页跳转到插件）不同，这个 demo 把插件页面**装进
TPageControl 的页签里**：左边是框架的 LCL 侧栏菜单 `TLWSideMenu`，右边每个
页签里放一个 `TLWHTMLFrame`，里面是指向 `/p/<插件名>/` 的 iframe。

- 左边菜单的**菜单项不是写死的**：一个插件清单 = 一个菜单项，分组也来自清单；
- 主程序（宿主）是独立 exe，只负责菜单、页签、代理和插件进程管理；
- 每个插件也是独立 exe，自己监听端口、自己处理业务；
- 插件 exe 支持**热更新**：宿主不重启，换插件二进制并重启对应进程即可；
- 新增/删除插件目录后点「重新扫描插件」，**菜单即时跟着磁盘变**，宿主不用重启；
- 插件 exe **不能单独运行**：双击/命令行启动会被启动守卫拦下，提示一句
  「请从主程序进入」后退出（退出码 3），必须由主程序拉起；
- 插件有**用户权限**：先登录（admin / analyst / guest），菜单只列当前角色
  能看的插件，直接敲 `/p/报表/` 也会被宿主路由层回 403 —— 不是只藏菜单。

## 目录

```
demos/pluginsDemo/
  common/upluginproc.pas     插件发现、路由注册、拉起/停止、热更新（仅宿主链接）
  common/upluginguard.pas    插件启动守卫：令牌 + 父进程校验（宿主与插件共用）
  common/upluginauth.pas     账号/角色、会话身份、路由鉴权回调（仅宿主链接）
  host/                      宿主 exe
    pluginsdemo.lpr/.lpi/.ini
    umain.pas / umain.lfm    侧栏菜单（TLWSideMenu）+ TPageControl + 状态栏（界面全在 lfm）
    ulogin.pas               登录窗体（基类 TLWLoginForm 自动摆界面，只挂 OnLogin）
  dashplug/                  插件 1：仪表盘      8881
    dashplug.lpr/.lpi/.ini/.plugin.ini
    uform_dashboard.pas/.lfm
  notesplug/                 插件 2：便签        8882
    notesplug.lpr/.lpi/.ini/.plugin.ini
    uform_notes.pas/.lfm
  reportsplug/               插件 3：报表汇总    8883
    reportsplug.lpr/.lpi/.ini/.plugin.ini
    uform_reports.pas/.lfm
  icons/                     侧栏菜单图标（16x16 bmp，清单里 icon= 引用）
  .run/                      运行期自动生成：插件 exe/ini 副本（不要提交）
  build.bat / build.sh       Windows / Linux 构建脚本（先插件后宿主）
  stop-all.bat / stop-all.sh Windows / Linux 清理残留进程脚本
```

宿主 exe 在 `host\` 下，所以清单根目录 = `host\` 的父目录（`pluginsDemo\`）。
启动时扫描 `pluginsDemo\*\*.plugin.ini`，按清单注册路由、拉起进程。

## 清单

```ini
; notesplug/notesplug.plugin.ini
name=notes                  ; 路由名：/p/notes/
title=便签                  ; 左侧菜单文字
group=系统管理/数据维护       ; 侧栏菜单分组，/ 表示层级（可任意深度）
icon=..\icons\notes.bmp     ; 菜单图标（16x16 bmp/png），相对清单目录
exe=notesplug.exe           ; 相对清单所在目录
port=8882
roles=                      ; 允许访问的角色，逗号分隔；空/不写 = 所有已登录用户
```

`group` 的三种写法：

| 写法 | 效果 |
| --- | --- |
| 不写 | 归入默认分组「插件」 |
| `group=业务管理` | 「业务管理」组下的一项 |
| `group=系统管理/数据维护` | 「系统管理 → 数据维护」两级分组下的一项，任意层数都行 |
| `group=-` | 不套分组，插件直接作为顶层菜单行 |

新增插件：建目录 + 插件工程 + 清单，重编插件；宿主源码不用改。

## 左侧菜单：TLWSideMenu，多级菜单由插件清单生成

左侧是 `src/core/lwsidemenu.pas` 的 **LCL 组件 `TLWSideMenu`**（`TMenu` 的后代）：
带子项的节点是可折叠分组、叶子项是可点击的插件行，选中项 `Checked=True` 高亮，
侧栏宽度 `SideWidth=250` 由框架自动让位（右侧客户区右移，`alTop`/`alClient` 照常生效）。

本 demo 的清单拼出来是这样一棵树（全部来自 `*.plugin.ini`）：

```
业务管理              ← dash / reports 的 group=业务管理
  仪表盘
  报表汇总
系统管理              ← notes 的 group=系统管理/数据维护
  数据维护
    便签
```

**菜单树在运行期由扫描结果生成**（`umain.pas` 的 `BuildMenu`，lfm 里没有一条菜单项）：

```
PlugDiscover 扫到 N 个 *.plugin.ini
  → group 按 '/' 拆段，逐段建（或复用）分组 TMenuItem（同一路径共用一个分组）
  → 每个插件建一个叶子 TMenuItem：Caption=title，Tag=插件下标，
    OnClick=MenuItemClick，Bitmap 来自清单的 icon=
  → HeaderCaption = '插件导航（N）'
```

所以：

- 改清单里的 `title` / `group` / `icon`，菜单文字、层级和图标就跟着变；
- 加一个插件目录（清单 + exe）后点顶部「重新扫描插件」，菜单**当场多出一项**，
  宿主同时注册 `/p/<名>/` 路由并拉起该插件进程；
- 删掉插件目录再点一次，菜单项消失、对应页签自动关闭、进程停掉、路由摘除；
- 端口或 exe 路径改了，重新扫描时会重启该插件进程。

`PlugRescan`（`upluginproc.pas`）做的就是「磁盘 → 运行时」的对齐：新增的加入并拉起，
消失的 `Terminate` + `LWRouteRemove`，其余就地更新标题/分组/图标，最后按名字排序保证菜单顺序稳定。

多级渲染在前端 `lw-alpine.js` 的 `buildSideMenu` 里是**递归**的：有子项就再套一层
`lw-sm-grp`，缩进每层 12px，折叠状态按层级路径（`0`、`0.2`、`0.2.1`…）记在
localStorage；选中项所在的所有祖先分组会自动展开（用户手动折叠过的以用户为准）。

## 构建与运行

```bat
build.bat
rem 或分别：
lazbuild demos\pluginsDemo\dashplug\dashplug.lpi
lazbuild demos\pluginsDemo\notesplug\notesplug.lpi
lazbuild demos\pluginsDemo\reportsplug\reportsplug.lpi
lazbuild demos\pluginsDemo\host\pluginsdemo.lpi

demos\pluginsDemo\host\pluginsdemo.exe
```

Linux/macOS 用 `bash build.sh`（或 `chmod +x build.sh` 后直接执行）；
`lazbuild` 不在 PATH 上时先设 `LAZBUILD=/path/to/lazbuild`。FPC 在 Linux 上
生成的插件 exe 没有 `.exe` 后缀，清单里照写 `exe=xxx.exe` 即可 ——
`common\upluginproc.pas` 会自动退到无后缀文件，并给 `.run/` 里的运行副本补执行位。
清理残留进程用 `bash stop-all.sh`（按 exe 真实路径过滤，不误杀别的 demo）。

**改了 `common\upluginguard.pas`（守卫/口令）要全部重编**：宿主和三个插件都链接它，
只重编一边会出现「令牌对不上，插件起不来」。`build.bat` / `build.sh` 已经按顺序全编。

浏览器打开 <http://127.0.0.1:8878/>，**先看到登录页**：admin / analyst / guest
（口令见 `common\upluginauth.pas` 的 `LWAuthDemoPass`）。登录后默认打开当前账号
能访问的第一个插件页，不同账号看到的侧栏项数不同（见下面「用户权限」）。
点左侧其它插件会在右侧**新增页签**；同一插件重复点击只切回已有页签。
顶部工具栏：「重新扫描插件」让菜单跟着插件目录变，「热更新当前插件」重启当前页签的
插件进程，「切换用户」注销回登录页。

## 页内是怎么显示插件页的

页签里是 `TLWHTMLFrame`，HTML 只有一行 iframe：

```html
<iframe src="/p/notes/?v=1&sid=<当前会话号>" style="width:100%;height:100%;border:0"></iframe>
```

`sid` 是宿主当前会话标识：`/p/` 路由要按会话角色鉴权，而浏览器不会替
iframe 自动带这个参数（宿主的 `?sid=` 是前端 JS 发 `/lw/api/*` 时用的）。
`lwroute` 放行后会把它落到 `Path=/p/` 的 `lwpsid` cookie，之后 iframe 里的
子请求就靠 cookie 通过鉴权。

宿主的 `lwroute` 把 `/p/notes/...` 反向代理到 `127.0.0.1:8882`，插件页里的
API 调用按页面路径自动带 `/p/notes/` 前缀，代理后原样回插件进程。
`?v=` 是热更新代数，换版本号就会换掉 iframe 元素，强制重新加载。

## 插件 exe 不能单独运行（启动守卫）

插件是业务片段，不应该让用户绕过主程序直接双击。`common\upluginguard.pas` 做了四道校验：

| 校验 | 说明 |
| --- | --- |
| 参数齐全 | 宿主拉起时带 `--lw-plug-nonce= / --lw-plug-token= / --lw-plug-host=` |
| nonce 未过期 | nonce = `<unix 秒>-<随机>`，超过 120 秒作废（挡住攒下命令行以后再重放） |
| token 对得上 | `token = SHA1(secret|nonce)`，secret 只在宿主与插件里（十六进制存放，不出明文） |
| 父进程是宿主 | Windows 下取父进程 exe 名，与 `--lw-plug-host` 比对 |

任何一条不过：往 stderr 打提示 + 弹消息框 + 写 `plugin-guard.log`（在插件 exe 同目录），
然后 `Halt(3)`。宿主的 `StartOne` 看到退出码 3 会在日志里注明「被启动守卫拦了」。

插件这边只需要在 `.lpr` 的 `begin` 第一句加：

```pascal
PlugGuardCheck('仪表盘');   // 通不过就提示并退出，不会往下走 Application.Initialize
```

自己验证：

```bat
cd demos\pluginsDemo\dashplug
dashplug.exe
rem 弹出「『仪表盘』是 lazarusWeb 的插件程序，不能单独运行。」，控制台 exit 3
rem 插件目录下多一行 plugin-guard.log：  ...  pid=1234  missing

rem 脚本/CI 里不想弹窗（只写 stderr 与日志）：
set LW_PLUGIN_GUARD_NOUI=1
dashplug.exe --lw-plug-nonce=1795482878-deadbeef --lw-plug-token=0000 --lw-plug-host=dashplug.exe
echo %ERRORLEVEL%      rem 3，日志里是 badtoken
```

改口令：只改 `PlugGuardSecretHex` 一处（宿主与插件共用同一单元），然后全部重编。

**这层是「防误操作 + 提高门槛」，不是密码学意义上的强保护**：secret 在 exe 里，
拿到源码的人可以照着算一个 token；父进程名也在命令行里，能伪造。真要做到
「只有我的主程序能开」，得换成宿主签发证书/走本地 IPC 鉴权。

## 用户权限：谁能打开哪个插件

守卫管的是「这个 exe 能不能被拉起」，与「谁在用」无关。用户权限是另一条线：
**登录身份 → 角色 → 插件清单里的 `roles=`**。

演示账号（`common\upluginauth.pas`，口令都是 `123456`，即 `LWAuthDemoPass`）：

| 账号 | 角色 | 能打开的插件 |
| --- | --- | --- |
| `admin` | admin（通配全部） | 仪表盘、报表汇总、便签 |
| `analyst` | analyst | 仪表盘、便签 |
| `guest` | guest | 便签 |

清单侧：

| 清单写法 | 谁能打开 |
| --- | --- |
| `roles=admin` | 只有管理员（本 demo 的报表汇总） |
| `roles=admin,analyst` | 管理员与分析师（本 demo 的仪表盘） |
| 不写 / `roles=` | 所有已登录用户（本 demo 的便签） |
| —— | admin 角色隐含全部权限，清单里不用重复列 |

### 登录窗体带图形验证码

登录页有图形验证码（`TLWLoginForm.BuildDefaultUI` 自带 `captcha1` + `edCode`，
`host\ulogin.pas` 保持开启）：

- **点图片换一张**：浏览器只在图片 URL 后追加 `&r=<时间戳>`，纯前端行为，
  不走事件、不占会话执行锁；服务端看到 `r` 就重新生成一张。
- **一枚码只试一次**：校验无论对错都立即作废。验证码错、账号密码错都会
  自动换图并清空输入框，用户不用手动点。
- **先验码再验账号**：顺序不能反，否则等于给暴力枚举开了后门。
- **不区分大小写**，首尾空格忽略。

自动化测试需要登录但读不了图，用显式开关关掉（普通启动不受影响）：

```bat
pluginsdemo.exe --port=8878 --no-captcha
rem 或 set LW_LOGIN_NO_CAPTCHA=1
```

注意：**只把控件 `Visible := False` 不等于关闭验证码** —— 基类仍会拿空输入
去比对，结果永远提示「验证码错误」。必须同时 `RequireCaptcha := False`。

排障时想知道图上的码到底是几个字符：

```bat
set LW_CAPTCHA_DEBUG=1
```

会把 `[lw] captcha <令牌> = <答案>` 打到 stderr（正常部署不要开）。

### 三道判定，少一道就漏

```
登录   host\ulogin.pas        口令对 -> 把「登录名 / 角色串」写进会话变量
                              （Session.SessionSetVar，不是全局变量：同一进程
                              里多个浏览器是不同用户，全局变量会串号）
菜单   umain.BuildMenu        逐个插件 LWAuthCanOpen(本会话角色, 清单 roles)，
                              无权限的项根本不进侧栏，菜单头显示「可见 2 / 共 3」
路由   src\core\lwroute.pas   /p/<名>/ 代理之前调 LWAuthGuard（宿主注册），
                              无权限直接 403，请求不会到达插件进程
```

只做前两道是不够的 —— 菜单只是 UI，直接敲地址栏、转发链接、iframe 里的
子请求都能绕过。**第三道才是强制点**，前两道只是让界面不骗人。

### 会话标识怎么进到 iframe 里

宿主的会话标识走 `?sid=`（框架既有机制），而 iframe 的 `<iframe src="/p/notes/">`
是浏览器自己发的请求，不会带 query。所以：

1. 宿主序列化页面时把 sid 拼进 iframe URL：`/p/notes/?v=0&sid=<当前会话>`；
2. `lwroute` 放行后回一个 `Set-Cookie: lwpsid=<sid>; Path=/p/; HttpOnly; SameSite=Lax`
   —— 之后的子资源请求（插件页面里的相对路径、`/lw/api/event`、静态资源）
   由浏览器自动带 cookie，鉴权这才覆盖到整棵请求树。

`Path=/p/` 让这个 cookie 只发给插件代理前缀，不污染宿主自身的请求。

### 403 页面

无权限时返回的是人可读的页面（不是裸 JSON）：说明是哪个账号、缺什么角色、
返回工作台的链接。程序/脚本调用（`Accept` 不含 `text/html`）仍回
`{"ok":false,"err":"forbidden",...}`。

### 切换用户

顶栏「切换用户」= 注销：清会话变量 → `Authenticated := False` →
`SessionHideForm(主窗体)` + `SessionShowForm(登录窗体)`。换账号登录后框架会
**复用同一个主窗体实例**，所以 `TMainForm.FormShow` 里比对登录名，变了就按新
角色重建菜单、关掉越权页签（否则 guest 登录进来看到的是上一个 admin 的菜单）。

### 插件怎么知道"当前是谁"（身份注入）

权限判定在宿主，但插件是独立进程、有自己的会话表，宿主会话里的 `lwuser`
不会自动过去。宿主在 `/p/<名>/` 反代时把身份签发到请求头，插件验签后读取：

| 请求头 | 内容 |
| --- | --- |
| `X-LW-User` | 登录名 |
| `X-LW-Roles` | 逗号分隔的角色串 |
| `X-LW-Identity-Ts` | 签发时刻（Unix 秒），60 秒有效 |
| `X-LW-Identity-Token` | `SHA1(secret + '|' + user + '|' + roles + '|' + ts)` |

- **框架侧**：`lwroute.LWRouteSetIdentity` 注册回调（不注册就没有头，行为与旧版
  一致）。`ProxyTo` **先删掉客户端自带的同名头，再写宿主签发的头** —— 只追加的
  话，浏览器自己发一个 `X-LW-User: admin` 就能冒充。`lwhttp.HandleRequest` 把四个
  头落到线程变量，业务事件里能读到，请求结束清空。
- **宿主侧**：`common/upluginauth.pas` 的 `LWAuthIdentity` 从会话取 user/roles 并
  签名；`LWAuthRegister` 一次挂上鉴权与身份两个回调。签名复用 `upluginguard` 的
  secret，两边共用同一个单元，改 secret 要宿主和插件一起重编。
- **插件侧**：`common/upluginidentity.pas` 验签后暴露 `PlugIdentityUser/Roles/
  Display`。便签页右上角显示「当前用户：…」，保存时把身份带进状态栏。直连插件
  端口时没有签名头，显示「未识别」；浏览器伪造头算不出 token，也会被拒。

### 边界

- 插件进程监听 `127.0.0.1:<port>`，**绕过宿主直连端口没有用户权限**。本机上有
  权限跑程序的人可以直接访问。要做到进程级隔离，只能给插件也加登录、或把端口
  改成命名管道/ACL 受限的句柄；
- 身份头有 60 秒时效，挡的是随手伪造与旧头重放；能在插件端口上抓包的本机进程
  仍可在窗口内重放。secret 也在 exe 里，不是密码学强认证；
- `lwpsid` 是会话标识，不是令牌：会话过期即失效，但它本身可被同机进程读到；
- 框架侧改的是 `lwroute` / `lwhttp`（新增可选回调，未注册时行为与旧版一致），
  **权限判定仍全在宿主代理层**；身份注入是可选的一层，插件不读就没有影响。

## 热更新

Windows 会锁住正在运行的 exe，所以插件**不直接跑原始 exe**：宿主每次启动前
把 `<插件目录>\<名>.exe` 和同名 `.ini` 复制到 `.run\`，再从 `.run\` 拉起。
原始 exe 不被占用，改完源码可以随时重编。

两种触发方式：

1. **重编后点该插件的菜单**：宿主发现原始 exe 的修改时间变了，自动
   停旧进程 → 重新复制 → 起新进程 → 页内 iframe 换 URL 重载；
2. **点顶部「热更新当前插件」**：对当前页签的插件强制执行一次上述流程。

流程细节（`upluginproc.pas`）：

```
StopOne(p)        Terminate + 等待退出（最多 5s）
StartOne(p)       ForceDirectories(.run) → 复制 exe/ini → TProcess.Execute(--port=)
                  轮询 127.0.0.1:<port> 直到可连接（最多 10s）
Inc(p.Seq)        宿主重设 iframe 的 src（?v=N），页面重新加载
```

验证方式（本机）：

```bat
rem 1) 插件运行中直接重编
lazbuild demos\pluginsDemo\notesplug\notesplug.lpi
rem 2) 回到浏览器点「便签」菜单：状态栏提示已热更新，pid 变化，iframe 重新加载
```

便签数据写在插件 exe 同目录（`.run\notesplug.notes.txt`），所以热更新重启
进程后已保存的便签仍在 —— 用来直观区分「代码换了」和「数据丢了」。

## 端口

| 进程 | 端口 |
| --- | --- |
| 宿主 pluginsdemo.exe | 8878 |
| dashplug.exe | 8881 |
| notesplug.exe | 8882 |
| reportsplug.exe | 8883 |

## 边界

- 页内是 iframe（另一个 lazarusWeb 页面），不是 LCL 控件；页面内部交互
  完全由插件进程处理，宿主拿不到插件控件。
- 宿主正常退出（关控制台/Ctrl+C/优雅关闭）会终止自己拉起的插件；
  如果宿主被强杀，插件可能残留，跑 `stop-all.bat` 清理。
- `.run\` 里的 exe/ini 是运行副本，可以随时删掉（下次启动重新复制）；
  但便签的数据文件 `notesplug.notes.txt` 也在里面，删掉会丢已保存的便签。

- 插件的启动守卫只在插件**启动那一刻**校验；插件起来之后主程序退出，
  插件进程仍会继续跑（下游请求照常）—— 这不是漏洞，是「拉起即信任」的设计，
  宿主退出时自己会 Terminate 掉子进程。
- 用户权限判定发生在**宿主代理层**（`lwroute`）：绕过宿主直连
  `127.0.0.1:<插件端口>` 不受权限约束，插件自己也不知道"现在是谁在点"。
- `plugin-guard.log` / `.run\` 都属于运行期产物，不要提交。
