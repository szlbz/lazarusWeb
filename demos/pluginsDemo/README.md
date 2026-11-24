# pluginsDemo —— 主程序 exe + 插件 exe 的页内插件工作台

和 `procdemo`（点按钮整页跳转到插件）不同，这个 demo 把插件页面**装进
TPageControl 的页签里**：左边是框架的 LCL 侧栏菜单 `TLWSideMenu`，右边每个
页签里放一个 `TLWHTMLFrame`，里面是指向 `/p/<插件名>/` 的 iframe。

- 左边菜单的**菜单项不是写死的**：一个插件清单 = 一个菜单项，分组也来自清单；
- 主程序（宿主）是独立 exe，只负责菜单、页签、代理和插件进程管理；
- 每个插件也是独立 exe，自己监听端口、自己处理业务；
- 插件 exe 支持**热更新**：宿主不重启，换插件二进制并重启对应进程即可；
- 新增/删除插件目录后点「重新扫描插件」，**菜单即时跟着磁盘变**，宿主不用重启。

## 目录

```
demos/pluginsDemo/
  common/upluginproc.pas     插件发现、路由注册、拉起/停止、热更新（仅宿主链接）
  host/                      宿主 exe
    pluginsdemo.lpr/.lpi/.ini
    umain.pas / umain.lfm    侧栏菜单（TLWSideMenu）+ TPageControl + 状态栏（界面全在 lfm）
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
  stop-all.bat               强杀宿主后清理残留插件进程
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

浏览器打开 <http://127.0.0.1:8878/>，默认打开第一个插件页。
点左侧其它插件会在右侧**新增页签**；同一插件重复点击只切回已有页签。
顶部工具栏：「重新扫描插件」让菜单跟着插件目录变，「热更新当前插件」重启当前页签的插件进程。

## 页内是怎么显示插件页的

页签里是 `TLWHTMLFrame`，HTML 只有一行 iframe：

```html
<iframe src="/p/notes/?v=1" style="width:100%;height:100%;border:0"></iframe>
```

宿主的 `lwroute` 把 `/p/notes/...` 反向代理到 `127.0.0.1:8882`，插件页里的
API 调用按页面路径自动带 `/p/notes/` 前缀，代理后原样回插件进程。
`?v=` 是热更新代数，换版本号就会换掉 iframe 元素，强制重新加载。

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
