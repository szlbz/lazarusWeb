# LCL 控件支持度矩阵

> 由 `tools\build_audit.bat` 自动生成（`lwaudit`），2026-11-09 20:52 于 Lazarus nogui widgetset 下实测。
> 每个控件都是**真的创建 + 挂到窗体 + 序列化一次**，不是静态推断。

## 汇总

| 指标 | 数量 | 占比 |
|---|---:|---:|
| 参与审计的可视控件 | 66 | 100% |
| **完整支持**（浏览器渲染成真实控件） | 49 | 74.2% |
| 已映射 kind 但 lw.js 暂无渲染器 | 1 | 1.5% |
| 仅占位（浏览器画一个带类名的框） | 14 | 21.2% |
| nogui 下创建失败 | 1 | 1.5% |
| 序列化失败 | 1 | 1.5% |
| 非可视组件（无需渲染，可直接用） | 16 | — |

## Buttons

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TBitBtn` | bitbtn | ok |  |
| `TSpeedButton` | speedbutton | ok |  |

## CheckLst

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TCheckListBox` | checklistbox | ok |  |

## ColorBox

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TColorBox` | unknown | placeholder |  |
| `TColorListBox` | unknown | placeholder |  |

## ComboEx

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TComboBoxEx` | unknown | placeholder |  |

## ComCtrls

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TPageControl` | tabs | ok |  |
| `TTabSheet` | tabsheet | ok | 需要在 TPageControl 里 |
| `TToolBar` | toolbar | ok |  |
| `TToolButton` | toolbutton | ok | 需要在 TToolBar 里 |
| `TStatusBar` | statusbar | ok |  |
| `TProgressBar` | progress | ok |  |
| `TTrackBar` | trackbar | ok |  |
| `TUpDown` | updown | ok |  |
| `TTreeView` | tree | ok | nogui 选中变化会启用内部 ChangeTimer 炸 nogui —— dispatch 已摘定时器再选中；OnSelectionChanged 延迟通知在 nogui 下不触发 |
| `TListView` | listview | ok |  |
| `THeaderControl` | unknown | placeholder |  |

## DBCtrls

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TDBEdit` | dbedit | ok |  |
| `TDBMemo` | dbmemo | ok |  |
| `TDBCheckBox` | dbcheckbox | ok |  |
| `TDBComboBox` | dbcombo | ok |  |
| `TDBListBox` | dblistbox | ok |  |
| `TDBText` | label | ok |  |
| `TDBImage` | dbimage | ok |  |
| `TDBNavigator` | — | create-failed | FPImageException: Failed to get raw image description from bitmap |
| `TDBLookupComboBox` | dblookup | ok |  |
| `TDBLookupListBox` | dblookuplist | ok |  |
| `TDBRadioGroup` | dbradiogroup | ok |  |

## DBGrids

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TDBGrid` | dbgrid | ok |  |

## EditBtn

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TEditButton` | unknown | placeholder |  |
| `TFileNameEdit` | unknown | placeholder |  |
| `TDirectoryEdit` | unknown | placeholder |  |
| `TDateEdit` | — | render-failed | EConvertError: 29584650.50 is not a valid date/time value. |
| `TTimeEdit` | timeedit | kind-only |  |
| `TCalcEdit` | unknown | placeholder |  |

## ExtCtrls

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TPanel` | panel | ok |  |
| `TImage` | image | ok |  |
| `TBevel` | bevel | ok |  |
| `TShape` | shape | ok |  |
| `TPaintBox` | unknown | placeholder |  |
| `TNotebook` | unknown | placeholder |  |
| `TSplitter` | splitter | ok |  |
| `TRadioGroup` | radiogroup | ok |  |
| `TCheckGroup` | checkgroup | ok |  |
| `TLabeledEdit` | edit | ok |  |
| `TFlowPanel` | unknown | placeholder |  |
| `TScrollBar` | unknown | placeholder |  |

## FileCtrl

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TFileListBox` | unknown | placeholder |  |
| `TFilterComboBox` | unknown | placeholder |  |

## Grids

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TStringGrid` | grid | ok |  |
| `TDrawGrid` | drawgrid | ok |  |

## MaskEdit

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TMaskEdit` | maskedit | ok |  |

## Spin

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TSpinEdit` | spin | ok |  |
| `TFloatSpinEdit` | floatspin | ok |  |

## StdCtrls

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TLabel` | label | ok |  |
| `TStaticText` | static | ok |  |
| `TButton` | button | ok |  |
| `TEdit` | edit | ok |  |
| `TMemo` | memo | ok |  |
| `TCheckBox` | checkbox | ok |  |
| `TRadioButton` | radio | ok |  |
| `TListBox` | listbox | ok |  |
| `TComboBox` | combo | ok |  |
| `TGroupBox` | groupbox | ok |  |
| `TScrollBox` | scrollbox | ok |  |

## ValEdit

| 控件 | kind | 状态 | 说明 |
|---|---|---|---|
| `TValueListEditor` | valeditor | ok |  |

## 非可视组件

这些组件服务端能正常创建和使用（定时器、对话框、数据源、菜单…），
浏览器端不需要对应的 DOM 元素，所以不参与渲染覆盖率统计。

| 组件 | 单元 | 状态 | 说明 |
|---|---|---|---|
| `TMainMenu` | Menus | 可用 |  |
| `TPopupMenu` | Menus | 可用 |  |
| `TMenuItem` | Menus | 可用 |  |
| `TOpenDialog` | Dialogs | 可用 |  |
| `TSaveDialog` | Dialogs | 可用 |  |
| `TColorDialog` | Dialogs | 可用 |  |
| `TFontDialog` | Dialogs | 可用 |  |
| `TFindDialog` | Dialogs | 可用 |  |
| `TReplaceDialog` | Dialogs | 可用 |  |
| `TOpenPictureDialog` | ExtDlgs | 可用 |  |
| `TTimer` | ExtCtrls | nogui 不可用 | nogui widgetset 无 CreateTimer，启用即 EOutOfResources；用 FCL TFPTimer（必须 UseTimerThread=True） |
| `TImageList` | ExtCtrls | 可用 |  |
| `TTrayIcon` | ExtCtrls | 可用 |  |
| `TActionList` | ActnList | 可用 |  |
| `TDataSource` | DB | 可用 |  |
| `TStringField` | DB | 可用 |  |

## 状态含义

- **ok** —— lwwriter 有对应 kind，lw.js 渲染成真实 Ext 组件，双向事件可用。
- **kind-only** —— lwwriter 已经给出 kind，但 lw.js 还没有对应渲染分支，
  浏览器上仍然落到占位框。补一个 case 就能升级成 ok。
- **placeholder** —— 控件在服务端是活的（属性、事件都能跑），但 lw.js 没有渲染器，
  浏览器上只显示一个写着类名的灰框。想用就得在 lwwriter 加 kind + 在 lw.js 加渲染分支。
- **create-failed** —— nogui widgetset 下构造就抛异常，连服务端都用不了；
  这种控件只能换成功能相近的已支持控件。
- **render-failed** —— 创建成功，但序列化时读某个属性出错（多半是依赖画布/句柄）。

