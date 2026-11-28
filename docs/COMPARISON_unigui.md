# lazarusWeb ↔ uniGUI 功能对照与缺口审计

> 基准：uniGUI Complete / Professional 的公开功能集（1.90+）。
> 状态标记：✅ 已实现 · 🟡 部分/变通可用 · ❌ 未实现。
> 审计日期：2026-11-16 更新（版本 0.9.6；在第三轮自定义 AJAX、报表打印/导出、
> WebSocket、跨页签会话共享、集群部署、GUI 服务端面板基础上，补齐 Alpine 默认渲染、
> 桌面/移动模板、相机与 FPC 自带 TLS 状态）。
> 状态以**默认 Alpine.js 渲染层**为准；Ext JS 为可选层（`--client=ext` + 自备
> `ext-<版本>/`），表中个别 Ext 组件名仅作对照标注。移动端相关状态已按
> Alpine 层的模板/自适应能力更新（2026-11-16）。

## 一、控件映射（✅ = kind 有对应渲染 + 回写）

| uniGUI | LazarusWeb | 状态 |
|---|---|---|
| uniForm / MainModule | TLWForm（TForm 直接换基类，ShowModal 同步模态） | ✅ |
| uniButton / uniSpeedButton | TButton / TBitBtn / TSpeedButton | ✅ |
| uniEdit / uniMaskEdit / uniMemo | TEdit / TMaskEdit / TMemo | ✅ |
| uniSpinEdit / uniFloatSpinEdit | TSpinEdit / TFloatSpinEdit | ✅ |
| uniCheckBox / uniRadioGroup / uniCheckGroup | TCheckBox / TRadioButton / TRadioGroup / TCheckGroup | ✅ |
| uniComboBox / uniListBox | TComboBox / TListBox | ✅ |
| uniCheckListBox | TCheckListBox | ✅ |
| uniHashTable（键值编辑） | TValueListEditor | ✅ |
| uniTreeView / uniListView | TTreeView / TListView | ✅ |
| uniStringGrid / uniDrawGrid | TStringGrid / TDrawGrid | ✅ |
| uniPageControl / uniToolBar / uniStatusBar | TPageControl / TToolBar / TStatusBar | ✅ |
| uniImage / uniProgressBar / uniSlider | TImage / TProgressBar / TTrackBar / TUpDown | ✅ |
| uniHTMLFrame | TLWHTMLFrame（HTML: TStrings） | ✅ |
| uniPDFFrame | TLWPDFFrame（iframe + 浏览器查看器 + 查看令牌） | ✅ |
| uniFileUpload | TLWFileUpload（Filter/Multiple/MaxSizeKB/TargetFolder/OnUpload） | ✅ |
| uniDBGrid | TLWDBGrid（行定位/列头排序/单元格编辑 + PageSize 分页/过滤条/汇总条） | ✅ |
| uniDBNavigator | TLWDBNavigator（10 按钮全语义） | ✅ |
| uniDBEdit / uniDBMemo / uniDBCheckBox / uniDBComboBox / uniDBListBox / uniDBRadioGroup / uniDBLookupComboBox / uniDBLookupListBox / uniDBImage / uniDBText | 同名 LCL 控件全支持 | ✅ |
| uniMenu（主菜单） | TMainMenu | ✅ |
| uniPopupMenu | `TPopupMenu`（挂在 `TControl.PopupMenu` 上的右键上下文菜单） | ✅ 右键菜单 |
| uniDateTimePicker / uniDatePicker | TDateEdit/TTimeEdit → 原生 date/time 输入（Alpine 默认，ISO 回传）/ 可选 Ext datefield/timefield | ✅ |
| uniChart（柱/线/饼） | TLWChart → Alpine 内置 SVG（默认）/ 可选 ext-x.x.x charts 包（Cartesian/Polar） | ✅ |
| uniColorPicker / uniFontSizeCombo | `TLWColorPicker`（四色块 + 调色板，选色回写 `Color`）/ FontSizeCombo 未做 | 🟡 |
| uniScreenMask | 全局 busy 指示 | 🟡 无会话级遮罩 |
| uniToast / 通知 | TLWForm.ShowToast → Alpine store.toasts 原生提示（默认）/ 可选 Ext.window.Toast（WS/轮询均可直推） | ✅ |
| uniPDFFrame 等图表外控件 | TLWPDFFrame（iframe + 查看令牌）/ TLWChart / `TLWGauge` 仪表盘 | ✅ |

## 二、框架能力

| 能力 | uniGUI | lazarusWeb | 状态 |
|---|---|---|---|
| 同步模态窗体 | ShowModal 挂起服务端线程 | TLWForm.ShowModal 同语义 | ✅ |
| 浏览器对话框改道 | ShowMessage/MessageDlg/InputQuery/MessageBox | lwdlg 钩子全套（含 Open/SaveDialog） | ✅ |
| 文件上传/下载 | uniFileUpload / SendFile | 上传端点 + 一次性下载令牌 + 查看令牌 | ✅ |
| 事件通道 | AJAX（uniGUI 0.9x 曾用长轮询） | WS 传事件（请求/响应）+ 长轮询游标推送（多页签各取各的） | ✅ |
| 多窗体 / 推送 | Show/ShowModal/Destroy 推送 | SessionShowForm/EndModal + reconcile 增量协调 | ✅ |
| 会话超时/清理 | ServerModule.SessionTimeout | Sweep 线程（分钟级） | ✅ |
| URL 参数 | TUniURLParameters | `?form=` `?client=alpine\|ext` `?ext=` `?theme=` `?fresh=1` `?nopoll=1` | 🟡 不能带自定义业务参数（可用 /lw/ajax 补） |
| 自定义 AJAX 端点 | ServerModule.AddAjaxProcedure | `TLWApp.AddAjax(name, handler)`（lwajax，含 Session 上下文、404 自省、`--ajax-cors`） | ✅ |
| 登录窗体/权限 | TUniLoginForm + MainModule 状态 | TLWLoginForm（lfm/IDE 可设计，RequireAuth/Authenticated，未认证事件全拒） | ✅ |
| 主题/皮肤切换 | themes 运行时切换 | `?theme=` 六主题运行时切换（classic/crisp/gray/material/neptune/graphite）+ `--theme=` 缺省 | ✅ |
| 打印 | uniPrint | `lwreport` 可打印 HTML（A4 @page / @media print / thead 逐页重复 / 合计行）+ `#print` 自动弹打印对话框 | ✅ |
| Excel 导出 | uniGridExcelExport | `lwreport.SaveXLSX`（真 OOXML：表头样式/冻结窗格/列宽/合计行）+ CSV（BOM）兜底 | ✅ |
| HTTPS / ISAPI / DLL 部署 | 多部署形态 | standalone 原生 HTTPS（FPC 自带 `--ssl`，自签零配置）+ nginx/Caddy 反代（deploy/ 现成配置）；无 ISAPI/DLL 形态 | 🟡 |
| 日志面板 | ServerLogger | GUI 服务端面板（lwpanel：菜单/滚动日志/状态栏，对标 uniGUI 独立服务器窗口）+ `--log=` 落盘 + /lw/api/log | ✅ |
| 集群/负载均衡 | 商业版 Hyper Server | **lwhyper.exe 专用负载器**（对标 Hyper Server：单进程拉起 N 个 worker、崩溃自动重启、反向代理 + sid 粘性 + WS 透传、/lw/hyper/status 监视端点）；亦可 nginx `ip_hash` / Caddy 粘性；会话外置 Redis 未实现 | ✅ |
| 跨页签会话共享 | — | sid 显式复用（`/lw/api/attach`）+ 游标式推送队列 + 对话框定向（to=）；默认每个页签一个独立会话，关页签即退出 | ✅（uniGUI 反而没做） |
| 移动端（uniMobile） | 独立控件族 | 默认 Alpine 层：前端自适应 + 窗体模板（桌面 `<窗体名>.html` + 移动 `<窗体名>.m.html`，`lw-tpl-mode:window\|flat`，背景层不重排控件）；未配模板保持设计期布局；手机可唤起系统相机拍照上传 | 🟡 无独立移动控件族，靠模板 + 自适应 |
| RTL / 多语言 | 支持 | 未做 | ❌ |

## 三、缺口优先级建议（2026-11-09 第三轮补缺后更新）

已完成（历轮补缺全部落地，回归全绿）：

1. ✅ **登录窗体/权限框架** —— `TLWLoginForm`（lwlogin.pas）：lfm/IDE
   可设计，`TLWApp.SetLogin(TXxxLoginForm)` 一行启用；未认证会话事件一律拒绝。
   参考 `demos/login/`。
2. ✅ **图表** —— `TLWChart`（lwchart.pas）：ctLine/ctBar/ctPie，
   ext-x.x.x charts 包渲染（Cartesian/Polar），运行时切换类型。
3. ✅ **DBGrid 分页/过滤/汇总** —— `TLWDBGrid`（lwdbgrid.pas）：
   PageSize/ShowFilter/SummaryType(gsSum/gsAvg/gsCount)/SummaryField，
   240 行 12 页实测，旧 lfm 自动升级（RegisterClassAlias）。
4. ✅ **主题运行时切换** —— `?theme=` 六主题 + `--theme=` 缺省。
5. ✅ **日期选择器** —— TDateEdit/TTimeEdit → Ext datefield/timefield，
   ISO 统一回传（LWISOToDateTime 解析）。
6. ✅ **Toast** —— TLWForm.ShowToast → Ext.window.Toast，
   WS 直推与轮询 outbox 双通道。
7. ✅ **自定义 AJAX 端点** —— `TLWApp.AddAjax`（lwajax.pas）：AddAjaxProcedure
   的对应物，带 Session 上下文、404 自省、`--ajax-cors` 跨域。`demos/dbaware/uAjax.pas`。
8. ✅ **报表/打印/导出** —— `lwreport`：可打印 HTML（浏览器打印引擎）、
   CSV（BOM+CRLF）、真 XLSX（OOXML，零第三方依赖）。替代 FastReport/LazReport
   的实测结论见 NOTES.md 坑 31.8。
9. ✅ **WebSocket** —— `lwwebsocket`：`/lw/ws` 只传事件请求/响应，推送一律长轮询游标下发（t_ws.py）。
10. ✅ **跨页签会话共享** —— 显式复用 sid + `/lw/api/attach` + 游标式推送
    队列 + 对话框定向（t_multitab.py 22 项 + CDP 6 项）；默认 sid 存
    sessionStorage（页签级，关页签即退出）。
11. ✅ **集群/负载均衡** —— 双方案：**lwhyper 专用负载器**（uniGUI Hyper Server
    的对应物：单进程守护 N 个 worker + 反向代理 + sid 粘性 + WS TCP 透传 +
    健康监控，`tools/lwhyper.exe`；t_hyper.py 20 项 + t_hyper_ws.py 6 项）
    与 nginx 粘性会话（`deploy/nginx.conf` 的 `ip_hash`、`/lw/healthz` 探针、
    `--trust-proxy`、宕机 410 自动重建）。
12. ✅ **GUI 服务端面板** —— `lwpanel`：菜单 + 滚动日志 + 状态栏，对标
    uniGUI 独立服务器窗口；双构建并存（console/GUI），`--nogui` 服务化。

剩余缺口（按价值排序）：

1. **移动端**（uniMobile 对应物）—— 绝对定位桌面布局，需独立响应式布局层，缺口最大。
2. **RTL / 多语言** —— 未做。
3. **PDF 直出** —— 暂以浏览器"另存为 PDF"代替（fcl-pdf 已验证可嵌入中文
   TrueType 子集，但该版本 ToUnicode/页面输出尚不稳）。
4. **会话外置 Redis** —— 集群目前靠粘性会话，外置后会话可漂移。
5. ~~**边缘控件**：gauge、uniColorPicker、会话级遮罩、`TRadioGroup/TCheckGroup/
   TCheckListBox/TValueListEditor` 真渲染器~~ ✅ 已完成（2026-11-12 更新）：
   `TLWGauge`/`TLWColorPicker`/会话级遮罩在 `lwui.pas`；
   TRadioGroup/TCheckGroup/TCheckListBox/TValueListEditor 渲染器已实现并实测 ok
   （坑 25/42/97，见 docs/CONTROL_MATRIX.md）。`TPopupMenu` 右键上下文菜单也已支持
   （`TControl.PopupMenu` 挂接 + 浏览器 `contextmenu` 弹出，见 `docs/lazarusWeb控件属性映射表.md`）。
6. ~~**lwconvert 深化**~~ ✅ 已完成（v2：窗体基类 / 启动代码 / 工程文件全自动改写，`tests/t_convert.py` 端到端回归 29 项）。
