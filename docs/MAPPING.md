# 控件 / 属性映射表

与服务端 `src/core/lwwriter.pas`、客户端 `src/client/lw.js` 的实际能力对齐。
`tools/lwconvert.exe` 的报告依据的正是这张表；实测覆盖率见
[`docs/CONTROL_MATRIX.md`](CONTROL_MATRIX.md)（`tools\build_audit.bat` 自动生成）。

## 图例

- ✅ 完整支持：序列化 + 渲染 + 值回写 + 事件
- 🔶 占位：浏览器端显示占位框，不影响其他控件
- ⛔ 创建失败：nogui widgetset 下构造就抛异常
- ➖ 不序列化（非可视 / 内部辅助控件）

## 窗体与容器

| LCL | kind | 浏览器端 | 事件 |
|---|---|---|---|
| TForm / TLWForm | form | Ext.window.Window | OnClose（右上角×= mrCancel） |
| TPanel | panel | absolute 面板（bevel/border 保留） | — |
| TGroupBox | groupbox | Ext.form.FieldSet | — |
| TScrollBox | scrollbox | autoScroll 面板 | — |
| TFrame | frame | absolute 面板 | — |
| TPageControl | tabs | Ext.tab.Panel | 页签切换（active 下发） |
| TTabSheet | tabsheet | tab 内面板 | — |

> 注意：`TTabSheet.Visible` 在 LCL 里恒为 False，页签显隐由 PageControl 的
> 活动页管理，客户端不使用该字段。

## 输入控件（值双向：浏览器改动先写回 LCL 属性，再触发事件）

| LCL | kind | 浏览器端 | 回写属性 | 支持的事件 |
|---|---|---|---|---|
| TLabel | label | 静态文本 | — | — |
| TStaticText | static | 静态文本 | — | — |
| TEdit | edit | textfield | Text | OnChange / OnEditingDone / OnExit / OnClick |
| TLabeledEdit | edit | textfield + 标签 | Text | 同上 |
| TMaskEdit | maskedit | textfield | Text | 同上 |
| TMemo | memo | textarea | Lines.Text | 同上 |
| TSpinEdit | spin | numberfield | Value | OnChange / OnEditingDone |
| TFloatSpinEdit | floatspin | numberfield | Value | 同上 |
| TCheckBox | checkbox | checkboxfield | Checked | OnChange / OnClick |
| TRadioButton | radio | radiofield | Checked | 同上 |
| TComboBox | combo | combobox（可编辑） | ItemIndex/Text | OnChange / OnEditingDone |
| TListBox | listbox | 列表 | ItemIndex | OnClick / OnSelect |
| TButton | button | button | — | OnClick（走原生 Click，含 ModalResult 语义） |
| TBitBtn | bitbtn | button | — | 同上 |
| TSpeedButton | speedbutton | toggle 按钮 | — | OnClick |
| TToolButton | toolbutton | 按钮项 | — | OnClick |

`KindOf` 里 `TEdit` 之后还有一条 `else if C is TCustomEdit`，因此
**凡是真正继承自 `TCustomEdit` 的派生控件都自动落到 `edit`**
（TLabeledEdit、自定义单行输入框…），无需逐个登记。

反例：`TFileNameEdit` / `TDateEdit` / `TCalcEdit` / `TDirectoryEdit` /
`TTimeEdit` / `TEditButton` 在 LCL 里继承链是
`TCustomEditButton → TCustomAbstractGroupedEdit → TCustomControl`，
**不是** `TCustomEdit` 的后代，所以仍是占位（见文末 🔶 清单）。

## 数据控件

| LCL | kind | 说明 |
|---|---|---|
| TStringGrid | grid | 表头/列宽/行高/固定行、整树下发；OnEditingDone 回写 Cells；OnClick 前先回写 Row/Col（浏览器送数据行号，服务端加回 FixedRows） |
| TDrawGrid | drawgrid | 同上（无列标题语义） |
| TTreeView | tree | Ext.tree.Panel，nodes 下发 |
| TListView | listview | 复用表格渲染（`buildGrid`）：`cols` 来自 `Columns[].Caption`，行 = `Caption` + `SubItems`；**设计期至少加一列**，否则列数为 0、看起来是空表 |
| TProgressBar | progress | pos/min/max/orientation，单向（服务端 → 浏览器） |
| TTrackBar | trackbar | Ext.slider.Single，pos/min/max/frequency，单向 |
| TUpDown | updown | 上下箭头的数字框，value/min/max，单向（`TUpDown.Position` 下发） |
| TImage | image | 占位图（不传输二进制图片内容） |
| TBevel | bevel | 纯 CSS 边框/留白（`.lw-bevel`） |
| TShape | shape | 方框/圆/椭圆（`.lw-shape`） |
| TSplitter | splitter | 分隔条（`.lw-splitter`，竖/横按 w/h 判断）；目前只做视觉，**不支持拖动**（拖动改宽度属于后续工作） |

## 文件上传 / 下载

| LCL / API | kind | 说明 |
|---|---|---|
| TLWFileUpload | fileupload | Ext 按钮 + 隐藏 `<input type=file>`；`Filter` / `Multiple` / `MaxSizeKB` / `TargetFolder` / `OnUpload` |

序列化字段（`lwwriter`，kind = `fileupload`）：

```
filter / multiple / maxsize / lastfile（ExtractFileName(LastFileName)）
files（UploadedFiles 全路径数组）
```

运行期语义：

- 点按钮 → 浏览器弹文件选择框 → `multipart/form-data` POST 到
  `/lw/api/upload?sid=<会话>&id=<控件 id>`；
- 服务端 `lwupload.LWProcessUpload` 逐个文件落盘（`f.Stream` 优先，
  退化用 `f.LocalFileName`），文件名经 `LWSafeFileName` 清洗（去路径、
  去 `..`、替换非法字符）；
- 落盘目录：`TargetFolder`，未设则 `%TEMP%\lw_uploads\<sid>\<控件名>\`；
- 每个文件成功后：`U.AddUploadedFile(路径)` → 会话推送新组件树 →
  `OnUpload(U, 路径)`（`TLWFileUploadEvent`）；
- 上传响应与该次事件响应同格式，浏览器直接 `applyPayload` 刷新界面，
  按钮文字在上传过程中显示「上传中 N%」。

下载侧（服务端主动推文件）：

| 方法 | 作用 |
|---|---|
| `TLWForm.SendFile(const AFileName: string; const ADownloadName: string = '')` | 登记一次性令牌，推 `download` 指令；浏览器动态建 `<a download>` 点击 |
| `TLWForm.SendText(const AText, ADownloadName: string; const AWithBOM: Boolean = False)` | 写临时文件后转 `SendFile`；`AWithBOM=True` 加 UTF-8 BOM（Excel 打开 CSV 不乱码） |

- 指令形态：`{"type":"download","url":"/lw/download?t=<令牌>","name":"<下载名>"}`；
- 令牌 = GUID 前 16 位 + 计数器，存于 `lwdownload` 的内存表，**一次有效**
  （`LWDownloadRelease` 后置空），再次访问 404；
- `GET /lw/download?t=<令牌>` 响应带
  `Content-Disposition: attachment; filename="…"; filename*=UTF-8''<百分号编码>`，
  中文名在各浏览器均正确；
- 清扫线程每轮 `LWDownloadSweep(30)`，30 分钟未用的令牌连同临时文件一起回收。

完整示例见 `demos/files`（上传 + 中文名下载 + CSV 导出 + 清单双击下载）。

## 富内容显示（lwweb，对应 uniGUI 的 uniHTMLFrame / uniPDFFrame）

| 控件 | kind | 说明 |
|---|---|---|
| TLWHTMLFrame | htmlframe | 面板里渲染任意 HTML；published `HTML: TStrings`，运行时改内容浏览器按指纹增量 update（不重建面板） |
| TLWPDFFrame | pdfframe | iframe + 浏览器自带 PDF 查看器；`PDFFile`（服务端路径，走查看令牌）或 `PDFURL`（外部地址） |

序列化字段（`lwwriter`）：

```
htmlframe: html（HTML.Text 原样下发）
pdfframe:  url（/lw/view?t=<查看令牌> 或外部地址；没文件为空串）
           file（ExtractFileName(PDFFile)）
```

PDF 查看链路：

- `TLWPDFFrame.ViewURL`：同一文件沿用同一查看令牌（缓存于控件内），
  每次序列化调 `LWDownloadTouch` 续期 —— 会话活着令牌不过期；
  换文件先 `RevokeToken` 再签新令牌，浏览器端 url 变化即换 iframe src；
- `GET /lw/view?t=<令牌>`：`Content-Disposition: inline`，令牌**不释放**
  （与一次性下载令牌不同），前端 iframe 翻页/刷新反复请求都返回 200；
- 浏览器端渲染：`url` 为空显示"尚未指定文件"占位，有 url 时建 iframe。

示例见 `demos/dbaware` 的"PDF 展示"页签（运行时手写 PDF 语法生成示例文档 +
TLWFileUpload 上传本地 PDF 显示）与"HTML 展示"页签（TMemo 编辑源码实时刷新）。

## 对话框（阻塞式，`lwdlg` 把 LCL 钩子改道浏览器）

业务代码不用改，`ShowMessage` / `MessageDlg` / `OpenDialog1.Execute` 照原样写。
实现上是替换 `InterfaceBase` 的四套函数指针 + `TOpenDialog`/`TSaveDialog` 的 WS 类：

| LCL 入口 | 钩子 | 指令 kind | 浏览器渲染 | 返回值 |
|---|---|---|---|---|
| `ShowMessage` / `ShowMessagePos` | `PromptDialogFunction` | `none` | 无图标 + 确定 | 无 |
| `MessageDlg` / `MessageDlgPos` | `PromptDialogFunction` | 按 `TMsgDlgType`：`info`/`warning`/`error`/`question` | 对应图标 + 按钮组 | `mrNone/mrOk/mrCancel/mrYes/mrNo/…` |
| `InputQuery` / `InputBox` | `InputDialogFunction` | `input` | 提示 + 单行（`PasswordBox` 是 password） | `Boolean` + `var Value` |
| `QuestionDlg` | `QuestionDialogFunction` | `question` | 自定义按钮文字 | 按钮的 `ModalResult` |
| `Application.MessageBox` / `LCLIntf.MessageBox` | `Forms.MessageBoxFunction` | 按 `MB_ICON*` 定图标 | Windows 风格按钮 | `IDOK/IDCANCEL/IDYES/IDNO/IDABORT/IDRETRY/IDIGNORE/IDCONTINUE` |
| `TOpenDialog.Execute` | `TWSOpenDialog.ShowModal` | `openfile` | 选文件（可多选） | `FileName` / `Files` = **服务端路径** |
| `TSaveDialog.Execute` | `TWSCommonDialog.ShowModal` | `savefile` | 文件名输入框 | `FileName` = 会话临时目录下路径 |

指令形态（`TLWSession.SessionPushCommand`）：

```json
{ "type":"dialog", "id":7, "kind":"question", "caption":"确认", "text":"要保存吗？",
  "buttons":[{"id":4,"text":"保存","default":true},{"id":5,"text":"放弃"},{"id":2,"text":"返回"}],
  "input": {"value":"未命名","mask":false} }
```

- 按钮 `id` 就是 LCL 的 `idButton*`（`Ok=1`、`Cancel=2`、`Help=3`、`Yes=4`、`No=5`、
  `Close=6`、`Abort=7`、`Retry=8`、`Ignore=9`、`All=10`、`YesToAll=11`、`NoToAll=12`、
  `Open=13`、`Save=14`、`Shield=15`、`Continue=16`、`TryAgain=17`），
  `PromptDialog` 内部再按 `DialogResults[]` 映射成 `mrYes/mrNo`；
- 答复：`POST /lw/api/dlg`，体内 `sid` / `id` / `r`（按钮 id）/ `text`（输入值）；
- 文件：`POST /lw/api/dlgfile?sid=&id=`，`multipart/form-data`，
  落 `%TEMP%\lw_uploads\<sid>\pick\`（打开）或 `...\<sid>\save\`（保存）；
- 服务端线程 `TEvent.WaitFor(LW_MODAL_TIMEOUT_MS=180000)` 挂起等答复，
  同一会话同时只允许一个对话框；无会话时全部退回 LCL 原实现。

完整示例见 `demos/dialogs`（7 类各一个按钮），回归 `tests/t_dialog.py`（36 项）。

## 数据库感知控件（SQLite / SQLdb 演示见 `demos/db`）

| LCL | kind | 浏览器端 | 回写目标 | 事件 |
|---|---|---|---|---|
| TDBGrid | dbgrid | 只读表格（行选中高亮） | 点行 → `DataSet.RecNo := 行+1` | OnCellClick(Column)、OnTitleClick(Column)（点列头，业务代码里做排序） |
| TDBEdit | dbedit | textfield | `Field.AsString/AsFloat/AsInteger`（自动进编辑态） | OnChange / OnExit |
| TDBMemo | dbmemo | textarea | 同上 | 同上 |
| TDBCheckBox | dbcheckbox | checkboxfield | `Field.AsBoolean` | OnChange / OnClick |
| TDBComboBox | dbcombo | combobox | `Field.AsString` | OnChange |
| TDBText | label | 只读文本（writer 直接读 `Field.DisplayText`） | —（只读） | — |
| TDBListBox | dblistbox | 列表框 | 回传选中序号 → `ItemIndex := n` + 项文本写字段 | OnChange |
| TDBRadioGroup | dbradiogroup | FieldSet + Radio 组 | 回传该项的 **Value** → 写字段 | OnChange |
| TDBLookupComboBox | dblookup | combobox（valueField=key） | 回传 **KeyField 值** → 直接写外键字段 | OnChange |
| TDBLookupListBox | dblookuplist | 列表框（回传键值） | 同上 | OnChange |
| TDBImage | dbimage | 图片（BLOB → PNG data URI） | —（只读，实时跟随字段） | — |

Lookup 下发的 payload：`items`（ListField 显示值）、`keys`（KeyField 值）、
`key`（当前键，直接读绑定字段 —— `KeyValue` 是 DataLink 缓存，数据集重开后
可能还没刷上）。前端选择时回传 `keys[i]`，服务端把键值写进外键字段，
ListField 显示由 DataChange 自动跟上。

序列化细节（`lwwriter.WriteDBGrid`）：

- 下发 `cols`（Title.Caption）、`fields`（FieldName）、`colwidths`、
  `rows`（`Field.DisplayText`）、`recno`（当前记录，浏览器据此高亮）、
  `count`、`state`（browse/edit/insert）；
- **数据集处于编辑/新增态时不下发 `rows`**（移动游标会触发自动 Post），
  浏览器沿用上一次的数据，Post/Cancel 后自动恢复下发；
- 数字字段若设了 `DisplayFormat`，回写时会先洗掉千分位再解析。

SQLite + SQLdb 的三条硬规则（TEXT→ftMemo、sqoAutoApplyUpdates、编辑态游标）
见 `docs/NOTES.md` 坑 9。

## 菜单 / 工具栏 / 状态栏

| LCL | 说明 |
|---|---|
| TMainMenu / TMenuItem | 独立于控件树序列化进 form.menu，浏览器端 Ext.menu.Menu；支持 Caption、Shortcut（ShortCutToText）、Checked、Enabled、分隔线、OnClick |
| TPopupMenu | 同上（右键上下文按 kind 预留） |
| TToolBar | 绝对定位容器 + 按钮项 |
| TStatusBar | form.status 面板文本数组；服务端改 Panels[i].Text 后随下次响应同步到浏览器 |

## 占位（🔶，26 个）

这些控件在服务端是**活的**（属性、事件、业务逻辑都照常跑），只是浏览器端
没有渲染器，显示成一个写着类名的灰框（`.lw-unknown`）。补一个 kind +
一个 `lw.js` 渲染分支即可升级。

| 单元 | 控件 |
|---|---|
| CheckLst | `TCheckListBox` |
| ColorBox | `TColorBox`、`TColorListBox` |
| ComboEx | `TComboBoxEx` |
| ComCtrls | `THeaderControl` |
| DBCtrls | （已全部适配，见上表；`TDBNavigator` 经 lwdbnav 子类可在 nogui 下使用，用户侧写原生类型） |
| EditBtn | `TEditButton`、`TFileNameEdit`、`TDirectoryEdit`、`TDateEdit`、`TTimeEdit`、`TCalcEdit` |
| ExtCtrls | `TPaintBox`、`TNotebook`、`TRadioGroup`、`TCheckGroup`、`TFlowPanel`、`TScrollBar` |
| FileCtrl | `TFileListBox`、`TFilterComboBox` |
| ValEdit | `TValueListEditor` |

> 想用 `TRadioGroup` / `TCheckGroup` 的，现在可以用 TGroupBox + 若干
> TRadioButton / TCheckBox 组合替代，浏览器端效果一致。
> 想用 `TFileNameEdit` 的，用 `TLWFileUpload` 更合适（真上传）。

## 创建失败（⛔，1 个）

| 控件 | 原因 |
|---|---|
| `TDBNavigator` | nogui 下构造即抛 `FPImageException` —— 由 lwdbnav 的 TLWDBNavigator 跳过 LCLGlyphs 解决：lfm 用 alias，代码用 `LWNewNavigator()` |
| 前端分页箭头 | 闭包捕获构建时的 node 快照，翻页后 `node.page` 过期 → 只能到第 2 页；每次点击须从 `S.nodes[id]` 取实时节点 |

这种控件服务端连创建都过不去，只能换实现（自己排几个 TButton）。

## 不序列化（➖）

- 控件内部辅助控件：`TStringCellEditor`、`TMemoCellEditor`、`TGridEdit`、
  `TListHotTrackEntry` 等（`lwwriter.IsInternalControl` 过滤）；
- 非可视组件（TDataSource、TActionList、TTimer、各类 Dialog、TImageList 等）：
  不参与渲染，它们的业务逻辑照常在服务端运行 —— 实测 16 个全部「可用」，
  详见 `docs/CONTROL_MATRIX.md` 的非可视表。

## 序列化的公共属性

`id / kind / name / cls / x / y / w / h / align / caption / text / enabled /
visible / hint / fg / bg / font(name,size,style,color) / tab(order) / ev(白名单事件)`
+ 各 kind 的特有字段（cols/colwidths/rowheight/rows/fixedcols/filter/…）。

事件白名单见 `lwbase.IsLWClickEvent`：
OnClick、OnChange、OnEditingDone、OnExit、OnSelect、OnClose 等；
通过 RTTI `GetMethodProp` 取方法指针直接调用，业务代码不需要任何注册。

## 覆盖率快照

66 个实测可视控件中：**39 个完整支持（59.1%）**、26 个占位（39.4%）、
1 个创建失败。按「常用度加权」实际覆盖要高得多 —— StdCtrls / ComCtrls /
ExtCtrls / Grids / DBCtrls 的日常控件基本都在 ✅ 一栏。

## 2026-11-09 新增映射

| LCL/框架 | kind / 指令 | 前端 |
|---|---|---|
| `TLWLoginForm`（lwlogin.pas） | form（带 RequireAuth 会话语义） | 登录窗体渲染 + TryLogin → `S.Authenticated` |
| `TLWChart`（lwchart.pas） | `chart`（charttype/title/categories/series） | Ext.chart.CartesianChart（line/bar）/ PolarChart（pie），`__lwChartSig` 指纹增量 |
| `TLWDBGrid`（lwdbgrid.pas） | `dbgrid`（pagesize/page/pages/total/filtertext/showfilter/summary） | tbar 过滤条 + bbar 页码条/汇总条；OnPageChange/OnFilter 框架级事件 |
| `TDateEdit`（EditBtn） | `dateedit`（text + iso） | Ext.form.field.Date，format Y-m-d，ISO 回传 |
| `TTimeEdit`（EditBtn） | `timeedit`（text + iso） | Ext.form.field.Time，format H:i:s，ISO 回传 |
| `TLWForm.ShowToast` | cmd `{type:'toast',title,text}` | Ext.window.Toast（align:'t'） |

注意：本机 Lazarus 的 `TCustomEditButton = class(TCustomAbstractGroupedEdit)`
（TCustomControl 系），**不是** TCustomEdit —— dateedit/timeedit 的
转型与 KindOf 判定都按此层级；ISO 解析 LWISOToDateTime 在解析前
快照 hasd/hast（TakeInt 会消费掉 dp/tp）。
