{ 自动生成 lwproxyws.pas —— GUI 构建专用：按线程路由的代理 widgetset
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  生成器 gen_proxyws.py；改动请改生成器，不要手改方法转发部分
  LAYER 1  TLWProxyWidgetSet：WidgetSet 实例级代理
           主线程 -> 安装时捕获的真实 widgetset（gtk2/win32/qt5）
           工作线程 -> TLWVirtualWS 无头实现（与 nogui 部署档行为一致）
  LAYER 2  WS 组件类注册表覆盖：
           面板家族 -> TLWWS* 路由类（主线程走真实类，工作线程走空基类）
           会话家族 -> 空基类（等价 nogui）
  背景见 docs/NOTES.md 坑 19：本框架所有控件操作都发生在 HTTP 工作线程，
;; 真 widgetset（gtk2/win32）不是线程安全的 —— 面板必须与业务窗体隔离。 }
unit lwproxyws;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, InterfaceBase, LCLType, LCLIntf, Graphics,
  GraphType, LCLPlatformDef, Themes,
  Controls, Forms, Menus, StdCtrls, ComCtrls, Buttons, ExtCtrls,
  Dialogs, Grids, Calendar, CheckLst, Spin, ImgList,
  WSLCLClasses, WSControls, WSForms, WSStdCtrls, WSMenus, WSComCtrls,
  WSButtons, WSGrids, WSCalendar, WSCheckLst, WSSpin, WSDialogs, WSExtCtrls,
  WSToolWin, WSImgList, WSFactory
{$IFDEF WINDOWS}
  , Win32Int          { TWin32WidgetSet：接口单元硬转型要求代理继承它 }
{$ENDIF}
{$IFDEF LCLGTK2}
  , Gtk2Int           { TGtk2WidgetSet }
{$ENDIF}
{$IFDEF LCLQT5}
  , QtInt             { TQtWidgetSet }
{$ENDIF}
  ;

type
  { 工作线程用的"无头"widgetset：虚拟显示器 + 假字体/DC，不碰 X/GTK/win32 }
  TLWVirtualWS = class(TWidgetSet)
    constructor Create; override;
    function LCLPlatform: TLCLPlatform; override;
    procedure AppInit(var ScreenInfo: TScreenInfo); override;
    procedure AppProcessMessages; override;
    procedure AppWaitMessage; override;
    procedure AppTerminate; override;
    procedure AppMinimize; override;
    procedure AppRestore; override;
    procedure AppBringToFront; override;
    procedure AppSetTitle(const ATitle: string); override;
    function EnumFontFamiliesEx(DC: HDC; lpLogFont: PLogFont; Callback: FontEnumExProc;
      Lparam: LParam; Flags: dword): longint; override;
    function CreateTimer(Interval: integer; TimerFunc: TWSTimerProc): TLCLHandle; override;
    function DestroyTimer(TimerHandle: TLCLHandle): boolean; override;
    procedure DestroyLCLComponent(Sender: TObject); virtual;
    function EnumDisplayMonitors(hdc: HDC; lprcClip: PRect; lpfnEnum: MonitorEnumProc;
      dwData: LPARAM): LongBool; override;
    function GetMonitorInfo(hMonitor: HMONITOR; lpmi: PMonitorInfo): Boolean; override;
    function MonitorFromWindow(hWnd: HWND; dwFlags: DWord): HMONITOR; override;
    function MonitorFromPoint(pt: TPoint; dwFlags: DWord): HMONITOR; override;
    function GetDpiForMonitor(hmonitor: HMONITOR; dpiType: TMonitorDpiType;
      out dpiX: UINT; out dpiY: UINT): HRESULT; override;
    function CreateCompatibleDC(DC: HDC): HDC; override;
    function DeleteDC(hDC: HDC): Boolean; override;
    function SelectObject(DC: HDC; GDIObj: HGDIOBJ): HGDIOBJ; override;
    function CreateFontIndirect(const LogFont: TLogFont): HFONT; override;
    function CreateFontIndirectEx(const LogFont: TLogFont; const LongFontName: string): HFONT; override;
    function GetTextExtentPoint32(DC: HDC; Str: PChar; Count: Integer; var Size: TSize): Boolean; override;
    function GetTextMetrics(DC: HDC; var TM: TTextMetric): Boolean; override;
    function GetDeviceCaps(DC: HDC; Index: Integer): Integer; override;
    function GetDC(hWnd: HWND): HDC; override;
    function ReleaseDC(hWnd: HWND; hDC: HDC): Integer; override;
    function SetTextColor(DC: HDC; Color: TColorRef): TColorRef; override;
    function SetBkColor(DC: HDC; Color: TColorRef): TColorRef; override;
    function SaveDC(DC: HDC): Integer; override;
    function RestoreDC(DC: HDC; SavedDC: Integer): Boolean; override;
    function DCGetPixel(CanvasHandle: HDC; X: LongInt; Y: LongInt): TColor; override;
    procedure DCSetPixel(CanvasHandle: HDC; X: LongInt; Y: LongInt; AColor: TColor); override;
    procedure DCRedraw(CanvasHandle: HDC); override;
  end;

  { 按线程路由（面板家族） }
  TLWWSWinControl = class(TWSWinControl)
    class function CanFocus(const AWincontrol: TWinControl): Boolean; override;
    class function GetClientBounds(const AWincontrol: TWinControl; var ARect: TRect): Boolean; override;
    class function GetClientRect(const AWincontrol: TWinControl; var ARect: TRect): Boolean; override;
    class procedure GetPreferredSize(const AWinControl: TWinControl; var PreferredWidth, PreferredHeight: integer; WithThemeSpace: Boolean); override;
    class function GetDefaultClientRect(const AWinControl: TWinControl; const aLeft, aTop, aWidth, aHeight: integer; var aClientRect: TRect): boolean; override;
    class function GetDesignInteractive(const AWinControl: TWinControl; AClientPos: TPoint): Boolean; override;
    class function GetDoubleBuffered(const AWinControl: TWinControl): Boolean; override;
    class function GetText(const AWinControl: TWinControl; var AText: String): Boolean; override;
    class function GetTextLen(const AWinControl: TWinControl; var ALength: Integer): Boolean; override;
    class procedure SetBiDiMode(const AWinControl: TWinControl; UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar : Boolean); override;
    class procedure SetBorderStyle(const AWinControl: TWinControl; const ABorderStyle: TBorderStyle); override;
    class procedure SetBounds(const AWinControl: TWinControl; const ALeft, ATop, AWidth, AHeight: Integer); override;
    class procedure SetColor(const AWinControl: TWinControl); override;
    class procedure SetChildZPosition(const AWinControl, AChild: TWinControl; const AOldPos, ANewPos: Integer; const AChildren: TFPList); override;
    class procedure SetFont(const AWinControl: TWinControl; const AFont: TFont); override;
    class procedure SetPos(const AWinControl: TWinControl; const ALeft, ATop: Integer); override;
    class procedure SetSize(const AWinControl: TWinControl; const AWidth, AHeight: Integer); override;
    class procedure SetText(const AWinControl: TWinControl; const AText: String); override;
    class procedure SetCursor(const AWinControl: TWinControl; const ACursor: HCursor); override;
    class procedure SetShape(const AWinControl: TWinControl; const AShape: HBITMAP); override;
    class procedure AdaptBounds(const AWinControl: TWinControl; var Left, Top, Width, Height: integer; var SuppressMove: boolean); override;
    class procedure ConstraintsChange(const AWinControl: TWinControl); override;
    class function CreateHandle(const AWinControl: TWinControl; const AParams: TCreateParams): TLCLHandle; override;
    class procedure DestroyHandle(const AWinControl: TWinControl); override;
    class procedure Invalidate(const AWinControl: TWinControl); override;
    class procedure PaintTo(const AWinControl: TWinControl; ADC: HDC; X, Y: Integer); override;
    class procedure Repaint(const AWinControl: TWinControl); override;
    class procedure ShowHide(const AWinControl: TWinControl); override;
    class procedure ScrollBy(const AWinControl: TWinControl; DeltaX, DeltaY: integer); override;
    class procedure AddControl(const AControl: TControl); override;
    class function GetConstraints(const AControl: TControl; const AConstraints: TObject): Boolean; override;
    class function GetDefaultColor(const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor; override;
    class procedure ConstraintWidth(const AControl: TControl; const AConstraints: TObject; var aWidth: integer); override;
    class procedure ConstraintHeight(const AControl: TControl; const AConstraints: TObject; var aHeight: integer); override;
    class function GetCanvasScaleFactor(const AControl: TControl): Double; override;
  end;

  { 按线程路由（面板家族） }
  TLWWSCustomForm = class(TWSCustomForm)
    class procedure CloseModal(const ACustomForm: TCustomForm); override;
    class procedure SetAllowDropFiles(const AForm: TCustomForm; AValue: Boolean); override;
    class procedure SetAlphaBlend(const ACustomForm: TCustomForm; const AlphaBlend: Boolean; const Alpha: Byte); override;
    class procedure SetBorderIcons(const AForm: TCustomForm; const ABorderIcons: TBorderIcons); override;
    class procedure SetFormBorderStyle(const AForm: TCustomForm; const AFormBorderStyle: TFormBorderStyle); override;
    class procedure SetFormStyle(const AForm: TCustomform; const AFormStyle, AOldFormStyle: TFormStyle); override;
    class procedure SetIcon(const AForm: TCustomForm; const Small, Big: HICON); override;
    class procedure ShowModal(const ACustomForm: TCustomForm); override;
    class procedure SetModalResult(const ACustomForm: TCustomForm; ANewValue: TModalResult); override;
    class procedure SetRealPopupParent(const ACustomForm: TCustomForm; const APopupParent: TCustomForm); override;
    class procedure SetShowInTaskbar(const AForm: TCustomForm; const AValue: TShowInTaskbar); override;
    class procedure SetZPosition(const AWinControl: TWinControl; const APosition: TWSZPosition); override;
    class function GetDefaultDoubleBuffered: Boolean; override;
    class function ActiveMDIChild(const AForm: TCustomForm): TCustomForm; override;
    class function Cascade(const AForm: TCustomForm): Boolean; override;
    class function GetClientHandle(const AForm: TCustomForm): HWND; override;
    class function GetMDIChildren(const AForm: TCustomForm; AIndex: Integer): TCustomForm; override;
    class function Next(const AForm: TCustomForm): Boolean; override;
    class function Previous(const AForm: TCustomForm): Boolean; override;
    class function Tile(const AForm: TCustomForm): Boolean; override;
    class function ArrangeIcons(const AForm: TCustomForm): Boolean; override;
    class function MDIChildCount(const AForm: TCustomForm): Integer; override;
    class function CanFocus(const AWincontrol: TWinControl): Boolean; override;
    class function GetClientBounds(const AWincontrol: TWinControl; var ARect: TRect): Boolean; override;
    class function GetClientRect(const AWincontrol: TWinControl; var ARect: TRect): Boolean; override;
    class procedure GetPreferredSize(const AWinControl: TWinControl; var PreferredWidth, PreferredHeight: integer; WithThemeSpace: Boolean); override;
    class function GetDefaultClientRect(const AWinControl: TWinControl; const aLeft, aTop, aWidth, aHeight: integer; var aClientRect: TRect): boolean; override;
    class function GetDesignInteractive(const AWinControl: TWinControl; AClientPos: TPoint): Boolean; override;
    class function GetDoubleBuffered(const AWinControl: TWinControl): Boolean; override;
    class function GetText(const AWinControl: TWinControl; var AText: String): Boolean; override;
    class function GetTextLen(const AWinControl: TWinControl; var ALength: Integer): Boolean; override;
    class procedure SetBiDiMode(const AWinControl: TWinControl; UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar : Boolean); override;
    class procedure SetBorderStyle(const AWinControl: TWinControl; const ABorderStyle: TBorderStyle); override;
    class procedure SetBounds(const AWinControl: TWinControl; const ALeft, ATop, AWidth, AHeight: Integer); override;
    class procedure SetColor(const AWinControl: TWinControl); override;
    class procedure SetChildZPosition(const AWinControl, AChild: TWinControl; const AOldPos, ANewPos: Integer; const AChildren: TFPList); override;
    class procedure SetFont(const AWinControl: TWinControl; const AFont: TFont); override;
    class procedure SetPos(const AWinControl: TWinControl; const ALeft, ATop: Integer); override;
    class procedure SetSize(const AWinControl: TWinControl; const AWidth, AHeight: Integer); override;
    class procedure SetText(const AWinControl: TWinControl; const AText: String); override;
    class procedure SetCursor(const AWinControl: TWinControl; const ACursor: HCursor); override;
    class procedure SetShape(const AWinControl: TWinControl; const AShape: HBITMAP); override;
    class procedure AdaptBounds(const AWinControl: TWinControl; var Left, Top, Width, Height: integer; var SuppressMove: boolean); override;
    class procedure ConstraintsChange(const AWinControl: TWinControl); override;
    class function CreateHandle(const AWinControl: TWinControl; const AParams: TCreateParams): TLCLHandle; override;
    class procedure DestroyHandle(const AWinControl: TWinControl); override;
    class procedure Invalidate(const AWinControl: TWinControl); override;
    class procedure PaintTo(const AWinControl: TWinControl; ADC: HDC; X, Y: Integer); override;
    class procedure Repaint(const AWinControl: TWinControl); override;
    class procedure ShowHide(const AWinControl: TWinControl); override;
    class procedure ScrollBy(const AWinControl: TWinControl; DeltaX, DeltaY: integer); override;
    class procedure AddControl(const AControl: TControl); override;
    class function GetConstraints(const AControl: TControl; const AConstraints: TObject): Boolean; override;
    class function GetDefaultColor(const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor; override;
    class procedure ConstraintWidth(const AControl: TControl; const AConstraints: TObject; var aWidth: integer); override;
    class procedure ConstraintHeight(const AControl: TControl; const AConstraints: TObject; var aHeight: integer); override;
    class function GetCanvasScaleFactor(const AControl: TControl): Double; override;
  end;

  { 按线程路由（面板家族） }
  TLWWSCustomMemo = class(TWSCustomMemo)
    class procedure AppendText(const ACustomMemo: TCustomMemo; const AText: string); override;
    class function GetStrings(const ACustomMemo: TCustomMemo): TStrings; override;
    class procedure FreeStrings(var AStrings: TStrings); override;
    class procedure SetScrollbars(const ACustomMemo: TCustomMemo; const NewScrollbars: TScrollStyle); override;
    class procedure SetWantTabs(const ACustomMemo: TCustomMemo; const NewWantTabs: boolean); override;
    class procedure SetWantReturns(const ACustomMemo: TCustomMemo; const NewWantReturns: boolean); override;
    class procedure SetWordWrap(const ACustomMemo: TCustomMemo; const NewWordWrap: boolean); override;
    class function GetCanUndo(const ACustomEdit: TCustomEdit): Boolean; override;
    class function GetCaretPos(const ACustomEdit: TCustomEdit): TPoint; override;
    class function GetSelStart(const ACustomEdit: TCustomEdit): integer; override;
    class function GetSelLength(const ACustomEdit: TCustomEdit): integer; override;
    class procedure SetAlignment(const ACustomEdit: TCustomEdit; const AAlignment: TAlignment); override;
    class procedure SetCaretPos(const ACustomEdit: TCustomEdit; const NewPos: TPoint); override;
    class procedure SetCharCase(const ACustomEdit: TCustomEdit; NewCase: TEditCharCase); override;
    class procedure SetEchoMode(const ACustomEdit: TCustomEdit; NewMode: TEchoMode); override;
    class procedure SetHideSelection(const ACustomEdit: TCustomEdit; NewHideSelection: Boolean); override;
    class procedure SetMaxLength(const ACustomEdit: TCustomEdit; NewLength: integer); override;
    class procedure SetNumbersOnly(const ACustomEdit: TCustomEdit; NewNumbersOnly: Boolean); override;
    class procedure SetPasswordChar(const ACustomEdit: TCustomEdit; NewChar: char); override;
    class procedure SetReadOnly(const ACustomEdit: TCustomEdit; NewReadOnly: boolean); override;
    class procedure SetSelStart(const ACustomEdit: TCustomEdit; NewStart: integer); override;
    class procedure SetSelLength(const ACustomEdit: TCustomEdit; NewLength: integer); override;
    class procedure SetSelText(const ACustomEdit: TCustomEdit; const NewSelText: string); override;
    class procedure SetTextHint(const ACustomEdit: TCustomEdit; const ATextHint: string); override;
    class procedure Cut(const ACustomEdit: TCustomEdit); override;
    class procedure Copy(const ACustomEdit: TCustomEdit); override;
    class procedure Paste(const ACustomEdit: TCustomEdit); override;
    class procedure Undo(const ACustomEdit: TCustomEdit); override;
    class function CanFocus(const AWincontrol: TWinControl): Boolean; override;
    class function GetClientBounds(const AWincontrol: TWinControl; var ARect: TRect): Boolean; override;
    class function GetClientRect(const AWincontrol: TWinControl; var ARect: TRect): Boolean; override;
    class procedure GetPreferredSize(const AWinControl: TWinControl; var PreferredWidth, PreferredHeight: integer; WithThemeSpace: Boolean); override;
    class function GetDefaultClientRect(const AWinControl: TWinControl; const aLeft, aTop, aWidth, aHeight: integer; var aClientRect: TRect): boolean; override;
    class function GetDesignInteractive(const AWinControl: TWinControl; AClientPos: TPoint): Boolean; override;
    class function GetDoubleBuffered(const AWinControl: TWinControl): Boolean; override;
    class function GetText(const AWinControl: TWinControl; var AText: String): Boolean; override;
    class function GetTextLen(const AWinControl: TWinControl; var ALength: Integer): Boolean; override;
    class procedure SetBiDiMode(const AWinControl: TWinControl; UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar : Boolean); override;
    class procedure SetBorderStyle(const AWinControl: TWinControl; const ABorderStyle: TBorderStyle); override;
    class procedure SetBounds(const AWinControl: TWinControl; const ALeft, ATop, AWidth, AHeight: Integer); override;
    class procedure SetColor(const AWinControl: TWinControl); override;
    class procedure SetChildZPosition(const AWinControl, AChild: TWinControl; const AOldPos, ANewPos: Integer; const AChildren: TFPList); override;
    class procedure SetFont(const AWinControl: TWinControl; const AFont: TFont); override;
    class procedure SetPos(const AWinControl: TWinControl; const ALeft, ATop: Integer); override;
    class procedure SetSize(const AWinControl: TWinControl; const AWidth, AHeight: Integer); override;
    class procedure SetText(const AWinControl: TWinControl; const AText: String); override;
    class procedure SetCursor(const AWinControl: TWinControl; const ACursor: HCursor); override;
    class procedure SetShape(const AWinControl: TWinControl; const AShape: HBITMAP); override;
    class procedure AdaptBounds(const AWinControl: TWinControl; var Left, Top, Width, Height: integer; var SuppressMove: boolean); override;
    class procedure ConstraintsChange(const AWinControl: TWinControl); override;
    class function CreateHandle(const AWinControl: TWinControl; const AParams: TCreateParams): TLCLHandle; override;
    class procedure DestroyHandle(const AWinControl: TWinControl); override;
    class procedure Invalidate(const AWinControl: TWinControl); override;
    class procedure PaintTo(const AWinControl: TWinControl; ADC: HDC; X, Y: Integer); override;
    class procedure Repaint(const AWinControl: TWinControl); override;
    class procedure ShowHide(const AWinControl: TWinControl); override;
    class procedure ScrollBy(const AWinControl: TWinControl; DeltaX, DeltaY: integer); override;
    class procedure AddControl(const AControl: TControl); override;
    class function GetConstraints(const AControl: TControl; const AConstraints: TObject): Boolean; override;
    class function GetDefaultColor(const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor; override;
    class procedure ConstraintWidth(const AControl: TControl; const AConstraints: TObject; var aWidth: integer); override;
    class procedure ConstraintHeight(const AControl: TControl; const AConstraints: TObject; var aHeight: integer); override;
    class function GetCanvasScaleFactor(const AControl: TControl): Double; override;
  end;

  { 按线程路由（面板家族） }
  TLWWSCustomButton = class(TWSButton)
    class procedure SetDefault(const AButton: TCustomButton; ADefault: Boolean); override;
    class procedure SetShortCut(const AButton: TCustomButton; const ShortCutK1, ShortCutK2: TShortCut); override;
    class function CanFocus(const AWincontrol: TWinControl): Boolean; override;
    class function GetClientBounds(const AWincontrol: TWinControl; var ARect: TRect): Boolean; override;
    class function GetClientRect(const AWincontrol: TWinControl; var ARect: TRect): Boolean; override;
    class procedure GetPreferredSize(const AWinControl: TWinControl; var PreferredWidth, PreferredHeight: integer; WithThemeSpace: Boolean); override;
    class function GetDefaultClientRect(const AWinControl: TWinControl; const aLeft, aTop, aWidth, aHeight: integer; var aClientRect: TRect): boolean; override;
    class function GetDesignInteractive(const AWinControl: TWinControl; AClientPos: TPoint): Boolean; override;
    class function GetDoubleBuffered(const AWinControl: TWinControl): Boolean; override;
    class function GetText(const AWinControl: TWinControl; var AText: String): Boolean; override;
    class function GetTextLen(const AWinControl: TWinControl; var ALength: Integer): Boolean; override;
    class procedure SetBiDiMode(const AWinControl: TWinControl; UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar : Boolean); override;
    class procedure SetBorderStyle(const AWinControl: TWinControl; const ABorderStyle: TBorderStyle); override;
    class procedure SetBounds(const AWinControl: TWinControl; const ALeft, ATop, AWidth, AHeight: Integer); override;
    class procedure SetColor(const AWinControl: TWinControl); override;
    class procedure SetChildZPosition(const AWinControl, AChild: TWinControl; const AOldPos, ANewPos: Integer; const AChildren: TFPList); override;
    class procedure SetFont(const AWinControl: TWinControl; const AFont: TFont); override;
    class procedure SetPos(const AWinControl: TWinControl; const ALeft, ATop: Integer); override;
    class procedure SetSize(const AWinControl: TWinControl; const AWidth, AHeight: Integer); override;
    class procedure SetText(const AWinControl: TWinControl; const AText: String); override;
    class procedure SetCursor(const AWinControl: TWinControl; const ACursor: HCursor); override;
    class procedure SetShape(const AWinControl: TWinControl; const AShape: HBITMAP); override;
    class procedure AdaptBounds(const AWinControl: TWinControl; var Left, Top, Width, Height: integer; var SuppressMove: boolean); override;
    class procedure ConstraintsChange(const AWinControl: TWinControl); override;
    class function CreateHandle(const AWinControl: TWinControl; const AParams: TCreateParams): TLCLHandle; override;
    class procedure DestroyHandle(const AWinControl: TWinControl); override;
    class procedure Invalidate(const AWinControl: TWinControl); override;
    class procedure PaintTo(const AWinControl: TWinControl; ADC: HDC; X, Y: Integer); override;
    class procedure Repaint(const AWinControl: TWinControl); override;
    class procedure ShowHide(const AWinControl: TWinControl); override;
    class procedure ScrollBy(const AWinControl: TWinControl; DeltaX, DeltaY: integer); override;
    class procedure AddControl(const AControl: TControl); override;
    class function GetConstraints(const AControl: TControl; const AConstraints: TObject): Boolean; override;
    class function GetDefaultColor(const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor; override;
    class procedure ConstraintWidth(const AControl: TControl; const AConstraints: TObject; var aWidth: integer); override;
    class procedure ConstraintHeight(const AControl: TControl; const AConstraints: TObject; var aHeight: integer); override;
    class function GetCanvasScaleFactor(const AControl: TControl): Double; override;
  end;

  { 按线程路由（面板家族） }
  TLWWSStatusBar = class(TWSStatusBar)
    class procedure PanelUpdate(const AStatusBar: TStatusBar; PanelIndex: integer); override;
    class procedure SetPanelText(const AStatusBar: TStatusBar; PanelIndex: integer); override;
    class procedure SetSizeGrip(const AStatusBar: TStatusBar; SizeGrip: Boolean); override;
    class procedure Update(const AStatusBar: TStatusBar); override;
    class function CanFocus(const AWincontrol: TWinControl): Boolean; override;
    class function GetClientBounds(const AWincontrol: TWinControl; var ARect: TRect): Boolean; override;
    class function GetClientRect(const AWincontrol: TWinControl; var ARect: TRect): Boolean; override;
    class procedure GetPreferredSize(const AWinControl: TWinControl; var PreferredWidth, PreferredHeight: integer; WithThemeSpace: Boolean); override;
    class function GetDefaultClientRect(const AWinControl: TWinControl; const aLeft, aTop, aWidth, aHeight: integer; var aClientRect: TRect): boolean; override;
    class function GetDesignInteractive(const AWinControl: TWinControl; AClientPos: TPoint): Boolean; override;
    class function GetDoubleBuffered(const AWinControl: TWinControl): Boolean; override;
    class function GetText(const AWinControl: TWinControl; var AText: String): Boolean; override;
    class function GetTextLen(const AWinControl: TWinControl; var ALength: Integer): Boolean; override;
    class procedure SetBiDiMode(const AWinControl: TWinControl; UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar : Boolean); override;
    class procedure SetBorderStyle(const AWinControl: TWinControl; const ABorderStyle: TBorderStyle); override;
    class procedure SetBounds(const AWinControl: TWinControl; const ALeft, ATop, AWidth, AHeight: Integer); override;
    class procedure SetColor(const AWinControl: TWinControl); override;
    class procedure SetChildZPosition(const AWinControl, AChild: TWinControl; const AOldPos, ANewPos: Integer; const AChildren: TFPList); override;
    class procedure SetFont(const AWinControl: TWinControl; const AFont: TFont); override;
    class procedure SetPos(const AWinControl: TWinControl; const ALeft, ATop: Integer); override;
    class procedure SetSize(const AWinControl: TWinControl; const AWidth, AHeight: Integer); override;
    class procedure SetText(const AWinControl: TWinControl; const AText: String); override;
    class procedure SetCursor(const AWinControl: TWinControl; const ACursor: HCursor); override;
    class procedure SetShape(const AWinControl: TWinControl; const AShape: HBITMAP); override;
    class procedure AdaptBounds(const AWinControl: TWinControl; var Left, Top, Width, Height: integer; var SuppressMove: boolean); override;
    class procedure ConstraintsChange(const AWinControl: TWinControl); override;
    class function CreateHandle(const AWinControl: TWinControl; const AParams: TCreateParams): TLCLHandle; override;
    class procedure DestroyHandle(const AWinControl: TWinControl); override;
    class procedure Invalidate(const AWinControl: TWinControl); override;
    class procedure PaintTo(const AWinControl: TWinControl; ADC: HDC; X, Y: Integer); override;
    class procedure Repaint(const AWinControl: TWinControl); override;
    class procedure ShowHide(const AWinControl: TWinControl); override;
    class procedure ScrollBy(const AWinControl: TWinControl; DeltaX, DeltaY: integer); override;
    class procedure AddControl(const AControl: TControl); override;
    class function GetConstraints(const AControl: TControl; const AConstraints: TObject): Boolean; override;
    class function GetDefaultColor(const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor; override;
    class procedure ConstraintWidth(const AControl: TControl; const AConstraints: TObject; var aWidth: integer); override;
    class procedure ConstraintHeight(const AControl: TControl; const AConstraints: TObject; var aHeight: integer); override;
    class function GetCanvasScaleFactor(const AControl: TControl): Double; override;
  end;

  { 按线程路由（面板家族） }
  TLWWSMenuItem = class(TWSMenuItem)
    class function OpenCommand: LongInt; override;
    class procedure CloseCommand(ACommand: LongInt); override;
    class procedure AttachMenu(const AMenuItem: TMenuItem); override;
    class function CreateHandle(const AMenuItem: TMenuItem): HMENU; override;
    class procedure DestroyHandle(const AMenuItem: TMenuItem); override;
    class procedure SetCaption(const AMenuItem: TMenuItem; const ACaption: string); override;
    class procedure SetShortCut(const AMenuItem: TMenuItem; const ShortCutK1, ShortCutK2: TShortCut); override;
    class procedure SetVisible(const AMenuItem: TMenuItem; const Visible: boolean); override;
    class function SetCheck(const AMenuItem: TMenuItem; const Checked: boolean): boolean; override;
    class function SetEnable(const AMenuItem: TMenuItem; const Enabled: boolean): boolean; override;
    class function SetRadioItem(const AMenuItem: TMenuItem; const RadioItem: boolean): boolean; override;
    class function SetRightJustify(const AMenuItem: TMenuItem; const Justified: boolean): boolean; override;
    class procedure UpdateMenuIcon(const AMenuItem: TMenuItem; const HasIcon: Boolean; const AIcon: TBitmap); override;
  end;

  { 按线程路由（面板家族） }
  TLWWSMenu = class(TWSMenu)
    class function CreateHandle(const AMenu: TMenu): HMENU; override;
    class procedure SetBiDiMode(const AMenu: TMenu; UseRightToLeftAlign, UseRightToLeftReading : Boolean); override;
  end;

  { 按线程路由（面板家族） }
  TLWWSMainMenu = class(TWSMainMenu)
    class function CreateHandle(const AMenu: TMenu): HMENU; override;
    class procedure SetBiDiMode(const AMenu: TMenu; UseRightToLeftAlign, UseRightToLeftReading : Boolean); override;
  end;

  { 按线程路由（面板家族） }
  TLWWSPopupMenu = class(TWSPopupMenu)
    class procedure Popup(const APopupMenu: TPopupMenu; const X, Y: integer); override;
    class function CreateHandle(const AMenu: TMenu): HMENU; override;
    class procedure SetBiDiMode(const AMenu: TMenu; UseRightToLeftAlign, UseRightToLeftReading : Boolean); override;
  end;

  { LAYER-1：WidgetSet 实例级按线程转发。
    代理类必须继承目标 widgetset 的具体类：各接口单元（win32int/gtk2int/qtint）
    存在大量 TWin32WidgetSet(WidgetSet) 式硬转型，继承 TWidgetSet 的代理会被
    硬转型后越界读字段直接崩（CheckPipeEvents 案）。继承具体类后转型合法，
    且主线程 inherited 走代理自身状态，与硬转型访问的状态完全一致。 }
{$IFDEF WINDOWS}
  TLWWSBase = TWin32WidgetSet;
{$ENDIF}
{$IFDEF LCLGTK2}
  TLWWSBase = TGtk2WidgetSet;
{$ENDIF}
{$IFDEF LCLQT5}
  TLWWSBase = TQtWidgetSet;
{$ENDIF}
  TLWProxyWidgetSet = class(TLWWSBase)
  public
    constructor Create; override;
    procedure PassCmdLineOptions; override;
    function CreateThemeServices: TThemeServices; override;
    function GetAppHandle: TLCLHandle; override;
    procedure SetAppHandle(const AValue: TLCLHandle); override;
    procedure AppInit(var ScreenInfo: TScreenInfo); override;
    procedure AppRun(const ALoop: TApplicationMainLoop); override;
    procedure AppWaitMessage; override;
    procedure AppProcessMessages; override;
    procedure AppTerminate; override;
    procedure AppMinimize; override;
    procedure AppRestore; override;
    procedure AppBringToFront; override;
    procedure AppSetIcon(const Small, Big: HICON); override;
    procedure AppSetTitle(const ATitle: string); override;
    procedure AppSetVisible(const AVisible: Boolean); override;
    function AppRemoveStayOnTopFlags(const ASystemTopAlso: Boolean): Boolean; override;
    function AppRestoreStayOnTopFlags(const ASystemTopAlso: Boolean): Boolean; override;
    procedure AppSetMainFormOnTaskBar(const DoSet: Boolean); override;
    procedure AppSetupMainForm(AMainForm: TObject); override;
    function BeginMessageProcess: TLCLHandle; override;
    procedure EndMessageProcess(context: TLCLHandle); override;
    function LCLPlatform: TLCLPlatform; override;
    function GetLCLCapability(ACapability: TLCLCapability): PtrUInt; override;
    function DCGetPixel(CanvasHandle: HDC; X, Y: integer): TGraphicsColor; override;
    procedure DCSetPixel(CanvasHandle: HDC; X, Y: integer; AColor: TGraphicsColor); override;
    procedure DCRedraw(CanvasHandle: HDC); override;
    procedure DCSetAntialiasing(CanvasHandle: HDC; AEnabled: Boolean); override;
    procedure SetDesigning(AComponent: TComponent); override;
    function InitStockFont(AFont: TObject; AStockFont: TStockFont): Boolean; override;
    function IsHelpKey(Key: Word; Shift: TShiftState): Boolean; override;
    function CreateTimer(Interval: integer; TimerProc: TWSTimerProc): TLCLHandle; override;
    function DestroyTimer(TimerHandle: TLCLHandle): boolean; override;
    function Arc(DC: HDC; Left,Top,Right,Bottom,Angle16Deg, Angle16DegLength: Integer): Boolean; override;
    function AngleChord(DC: HDC; x1,y1,x2,y2,angle1,angle2 : Integer): Boolean; override;
    function BeginPaint(Handle : hwnd; var PS : TPaintStruct): hdc; override;
    function BitBlt(DestDC: HDC; X, Y, Width, Height: Integer; SrcDC: HDC; XSrc, YSrc: Integer; Rop: DWORD): Boolean; override;
    function CallNextHookEx(hhk : HHOOK; ncode : Integer; WParam: WParam; LParam: LParam): Integer; override;
    function CallWindowProc(lpPrevWndFunc : TFarProc; Handle : HWND; Msg : UINT; WParam: WParam; LParam: LParam): Integer; override;
    function ClientToScreen(Handle : HWND; var P : TPoint): Boolean; override;
    function CombineRgn(Dest, Src1, Src2 : HRGN; fnCombineMode : Longint): Longint; override;
    function CreateBitmap(Width, Height: Integer; Planes, BitCount: Longint; BitmapBits: Pointer): HBITMAP; override;
    function CreateBrushIndirect(const LogBrush: TLogBrush): HBRUSH; override;
    function CreateBrushWithRadialGradient(const LogBrush: TLogRadialGradient): HBRUSH; override;
    function CreateCaret(Handle: HWND; Bitmap: hBitmap; width, Height: Integer): Boolean; override;
    function CreateCompatibleBitmap(DC: HDC; Width, Height: Integer): HBITMAP; override;
    function CreateCompatibleDC(DC: HDC): HDC; override;
    function CreateDIBitmap(DC: HDC; var InfoHeader: TBitmapInfoHeader; dwUsage: DWORD; InitBits: PChar; var InitInfo: TBitmapInfo; wUsage: UINT): HBITMAP; override;
    function CreateDIBSection(DC: HDC; const BitmapInfo: tagBitmapInfo; Usage: UINT; var Bits: Pointer; SectionHandle: TLCLHandle; Offset: DWORD): HBITMAP; override;
    function CreateEllipticRgn(X1, Y1, X2, Y2: Integer): HRGN; override;
    function CreateFontIndirect(const LogFont: TLogFont): HFONT; override;
    function CreateFontIndirectEx(const LogFont: TLogFont; const LongFontName: string): HFONT; override;
    function CreateIconIndirect(IconInfo: PIconInfo): HICON; override;
    function CreatePalette(const LogPalette: TLogPalette): HPalette; override;
    function CreatePatternBrush(ABitmap: HBITMAP): HBRUSH; override;
    function CreatePenIndirect(const LogPen: TLogPen): HPEN; override;
    function CreatePolygonRgn(Points: PPoint; NumPts: Integer; FillMode: integer): HRGN; override;
    function CreateRectRgn(X1,Y1,X2,Y2 : Integer): HRGN; override;
    function CreateRoundRectRgn(X1, Y1, X2, Y2, nWidthEllipse, nHeightEllipse: Integer): HRGN; override;
    procedure DeleteCriticalSection(var CritSection: TCriticalSection); override;
    function DeleteDC(hDC: HDC): Boolean; override;
    function DeleteObject(GDIObject: HGDIOBJ): Boolean; override;
    function DestroyCaret(Handle : HWND): Boolean; override;
    function DestroyCursor(Handle: HCURSOR): Boolean; override;
    function DestroyIcon(Handle: HICON): Boolean; override;
    function DrawFrameControl(DC: HDC; const Rect : TRect; uType, uState : Cardinal): Boolean; override;
    function DrawFocusRect(DC: HDC; const Rect: TRect): Boolean; override;
    function DrawEdge(DC: HDC; var Rect: TRect; edge: Cardinal; grfFlags: Cardinal): Boolean; override;
    function DrawText(DC: HDC; Str: PChar; Count: Integer; var Rect: TRect; Flags: Cardinal): Integer; override;
    function EnableScrollBar(Wnd: HWND; wSBflags, wArrows: Cardinal): Boolean; override;
    function EnableWindow(hWnd: HWND; bEnable: Boolean): Boolean; override;
    function EndPaint(Handle : hwnd; var PS : TPaintStruct): Integer; override;
    procedure EnterCriticalSection(var CritSection: TCriticalSection); override;
    function EnumDisplayMonitors(hdc: HDC; lprcClip: PRect; lpfnEnum: MonitorEnumProc; dwData: LPARAM): LongBool; override;
    function EnumFontFamilies(DC: HDC; Family: Pchar; EnumFontFamProc: FontEnumProc; LParam:Lparam): longint; override;
    function EnumFontFamiliesEx(DC: HDC; lpLogFont:PLogFont; Callback: FontEnumExProc; Lparam:LParam; Flags: dword): longint; override;
    function Ellipse(DC: HDC; x1, y1, x2, y2: Integer): Boolean; override;
    function EqualRgn(Rgn1: HRGN; Rgn2: HRGN): Boolean; override;
    function ExcludeClipRect(dc: hdc; Left, Top, Right, Bottom : Integer): Integer; override;
    function ExtCreatePen(dwPenStyle, dwWidth: DWord; const lplb: TLogBrush; dwStyleCount: DWord; lpStyle: PDWord): HPEN; override;
    function ExtTextOut(DC: HDC; X, Y: Integer; Options: Longint; Rect: PRect; Str: PChar; Count: Longint; Dx: PInteger): Boolean; override;
    function ExtSelectClipRGN(dc: hdc; rgn : hrgn; Mode : Longint): Integer; override;
    function FillRect(DC: HDC; const Rect: TRect; Brush: HBRUSH): Boolean; override;
    function FillRgn(DC: HDC; RegionHnd: HRGN; hbr: HBRUSH): BOOL; override;
    function FloodFill(DC: HDC; X, Y: Integer; Color: TGraphicsColor; FillStyle: TGraphicsFillStyle; Brush: HBRUSH): Boolean; override;
    function FrameRect(DC: HDC; const ARect: TRect; hBr: HBRUSH): Integer; override;
    function GetActiveWindow: HWND; override;
    function GetBitmapBits(Bitmap: HBITMAP; Count: Longint; Bits: Pointer): Longint; override;
    function GetBkColor(DC: HDC): TColorRef; override;
    function GetCapture: HWND; override;
    function GetCaretPos(var lpPoint: TPoint): Boolean; override;
    function GetClientRect(handle : HWND; var Rect: TRect): Boolean; override;
    function GetClipBox(DC : hDC; lpRect : PRect): Longint; override;
    function GetClipRGN(DC : hDC; RGN : hRGN): Longint; override;
    function GetCompositorExtendedBorder(handle : HWND; var Borders: TRect): Boolean; override;
    function GetCurrentObject(DC: HDC; uObjectType: UINT): HGDIOBJ; override;
    function GetCursorPos(var lpPoint: TPoint): Boolean; override;
    function GetDC(hWnd: HWND): HDC; override;
    function GetDeviceCaps(DC: HDC; Index: Integer): Integer; override;
    function GetDIBits(DC: HDC; Bitmap: HBitmap; StartScan, NumScans: UINT; Bits: Pointer; var BitInfo: BitmapInfo; Usage: UINT): Integer; override;
    function GetDoubleClickTime: UINT; override;
    function GetFocus: HWND; override;
    function GetFontLanguageInfo(DC: HDC): DWord; override;
    function GetForegroundWindow: HWND; override;
    function GetIconInfo(AIcon: HICON; AIconInfo: PIconInfo): Boolean; override;
    function GetKeyState(nVirtKey: Integer): Smallint; override;
    function GetMapMode(DC: HDC): Integer; override;
    function GetMonitorInfo(hMonitor: HMONITOR; lpmi: PMonitorInfo): Boolean; override;
    function GetDpiForMonitor(hmonitor: HMONITOR; dpiType: TMonitorDpiType; out dpiX: UINT; out dpiY: UINT): HRESULT; override;
    function GetObject(GDIObject: HGDIOBJ; BufSize: Integer; Buf: Pointer): Integer; override;
    function GetParent(Handle : HWND): HWND; override;
    function GetProp(Handle : hwnd; Str : PChar): Pointer; override;
    function GetRgnBox(RGN : HRGN; lpRect : PRect): Longint; override;
    function GetROP2(DC: HDC): integer; override;
    function GetScrollInfo(Handle: HWND; SBStyle: Integer; var ScrollInfo: TScrollInfo): Boolean; override;
    function GetStockObject(Value: Integer): TLCLHandle; override;
    function GetSysColor(nIndex: Integer): DWORD; override;
    function GetSysColorBrush(nIndex: Integer): HBrush; override;
    function GetSystemMetrics(nIndex: Integer): Integer; override;
    function GetTextColor(DC: HDC): TColorRef; override;
    function GetTextExtentExPoint(DC: HDC; Str: PChar; Count, MaxWidth: Integer; MaxCount, PartialWidths: PInteger; var Size: TSize): Boolean; override;
    function GetTextExtentPoint(DC: HDC; Str: PChar; Count: Integer; var Size: TSize): Boolean; override;
    function GetTextExtentPoint32(DC: HDC; Str: PChar; Count: Integer; var Size: TSize): Boolean; override;
    function GetTextMetrics(DC: HDC; var TM: TTextMetric): Boolean; override;
    function GetViewPortExtEx(DC: HDC; Size: PSize): Integer; override;
    function GetViewPortOrgEx(DC: HDC; P: PPoint): Integer; override;
    function GetWindowExtEx(DC: HDC; Size: PSize): Integer; override;
    function GetWindowLong(Handle : hwnd; int : Integer): PtrInt; override;
    function GetWindowRect(Handle : hwnd; var Rect : TRect): Integer; override;
    function GetWindowSize(Handle : hwnd; var Width, Height: integer): boolean; override;
    function GetWindowOrgEx(dc : hdc; var P: TPoint): Integer; override;
    function GetWindowOrgEx(dc : hdc; P : PPoint): Integer; overload; override;
    function GradientFill(DC: HDC; Vertices: PTriVertex; NumVertices : Longint; Meshes: Pointer; NumMeshes : Longint; Mode : Longint): Boolean; override;
    function HideCaret(hWnd: HWND): Boolean; override;
    procedure InitializeCriticalSection(var CritSection: TCriticalSection); override;
    function IntersectClipRect(dc: hdc; Left, Top, Right,Bottom: Integer): Integer; override;
    function InvalidateRect(aHandle : HWND; ARect : pRect; bErase : Boolean): Boolean; override;
    function InvalidateRgn(Handle: HWND; Rgn: HRGN; Erase: Boolean): Boolean; override;
    function IsDBCSLeadByte(TestChar: Byte): boolean; override;
    function IsIconic(handle: HWND): boolean; override;
    function IsWindow(handle: HWND): boolean; override;
    function IsWindowEnabled(handle: HWND): boolean; override;
    function IsWindowVisible(handle: HWND): boolean; override;
    function IsZoomed(handle: HWND): boolean; override;
    procedure LeaveCriticalSection(var CritSection: TCriticalSection); override;
    function LineTo(DC: HDC; X, Y: Integer): Boolean; override;
    function LoadBitmap(hInstance: TLCLHandle; lpBitmapName: PChar): HBitmap; override;
    function LoadCursor(hInstance: TLCLHandle; lpCursorName: PChar): HCursor; override;
    function LoadIcon(hInstance: TLCLHandle; lpIconName: PChar): HIcon; override;
    function MaskBlt(DestDC: HDC; X, Y, Width, Height: Integer; SrcDC: HDC; XSrc, YSrc: Integer; Mask: HBITMAP; XMask, YMask: Integer; Rop: DWORD): Boolean; override;
    function MaskBlt(DestDC: HDC; X, Y, Width, Height: Integer; SrcDC: HDC; XSrc, YSrc: Integer; Mask: HBITMAP; XMask, YMask: Integer): Boolean; overload; override;
    function MessageBox(hWnd: HWND; lpText, lpCaption: PChar; uType: Cardinal): integer; override;
    function MonitorFromPoint(ptScreenCoords: TPoint; dwFlags: DWord): HMONITOR; override;
    function MonitorFromRect(lprcScreenCoords: PRect; dwFlags: DWord): HMONITOR; override;
    function MonitorFromWindow(hWnd: HWND; dwFlags: DWord): HMONITOR; override;
    function MoveToEx(DC: HDC; X, Y: Integer; OldPoint: PPoint): Boolean; override;
    function OffsetRgn(RGN: HRGN; nXOffset, nYOffset: Integer): Integer; override;
    function PaintRgn(DC: HDC; RGN: HRGN): Boolean; override;
    function PeekMessage(var lpMsg : TMsg; Handle : HWND; wMsgFilterMin, wMsgFilterMax,wRemoveMsg : UINT): Boolean; override;
    function Pie(DC: HDC; x1, y1, x2, y2, sx, sy, ex, ey: Integer): Boolean; override;
    function PolyBezier(DC: HDC; Points: PPoint; NumPts: Integer; Filled, Continuous: boolean): boolean; override;
    function Polygon(DC: HDC; Points: PPoint; NumPts: Integer; Winding: boolean): boolean; override;
    function Polyline(DC: HDC; Points: PPoint; NumPts: Integer): boolean; override;
    function PostMessage(Handle: HWND; Msg: Cardinal; WParam: WParam; LParam: LParam): Boolean; override;
    function PtInRegion(RGN: HRGN; X, Y: Integer): Boolean; override;
    function RealizePalette(DC: HDC): Cardinal; override;
    function Rectangle(DC: HDC; X1, Y1, X2, Y2: Integer): Boolean; override;
    function RectInRegion(RGN: HRGN; ARect: TRect): Boolean; override;
    function RectVisible(DC: HDC; const ARect: TRect): Boolean; override;
    function RedrawWindow(Wnd: HWND; lprcUpdate: PRECT; hrgnUpdate: HRGN; flags: UINT): Boolean; override;
    function ReleaseCapture: Boolean; override;
    function ReleaseDC(hWnd: HWND; DC: HDC): Integer; override;
    function RemoveProp(Handle: HWND; Str: PChar): TLCLHandle; override;
    function RestoreDC(DC: HDC; SavedDC: Integer): Boolean; override;
    function RoundRect(DC : hDC; X1, Y1, X2, Y2: Integer; RX,RY : Integer): Boolean; override;
    function SaveDC(DC: HDC): Integer; override;
    function ScreenToClient(Handle : HWND; var P : TPoint): Integer; override;
    function ScrollWindowEx(hWnd: HWND; dx, dy: Integer; prcScroll, prcClip: PRect; hrgnUpdate: HRGN; prcUpdate: PRect; flags: UINT): Boolean; override;
    function SelectClipRGN(DC : hDC; RGN : HRGN): Longint; override;
    function SelectObject(DC: HDC; GDIObj: HGDIOBJ): HGDIOBJ; override;
    function SelectPalette(DC: HDC; Palette: HPALETTE; ForceBackground: Boolean): HPALETTE; override;
    function SendMessage(HandleWnd: HWND; Msg: Cardinal; WParam: WParam; LParam: LParam): LResult; override;
    function SetActiveWindow(Handle: HWND): HWND; override;
    function SetBkColor(DC: HDC; Color: TColorRef): TColorRef; override;
    function SetBkMode(DC: HDC; bkMode : Integer): Integer; override;
    function SetCapture(AHandle: HWND): HWND; override;
    function SetCaretPos(X, Y: Integer): Boolean; override;
    function SetCaretPosEx(handle: HWnd; X, Y: Integer): Boolean; override;
    function SetCursor(hCursor: HICON): HCURSOR; override;
    function SetCursorPos(X, Y: Integer): Boolean; override;
    function SetFocus(hWnd: HWND): HWND; override;
    function SetForegroundWindow(hWnd : HWND): Boolean; override;
    function SetMapMode(DC: HDC; fnMapMode : Integer): Integer; override;
    function SetMenu(AWindowHandle: HWND; AMenuHandle: HMENU): Boolean; override;
    function SetParent(hWndChild: HWND; hWndParent: HWND): HWND; override;
    function SetProp(Handle: hwnd; Str : PChar; Data : Pointer): Boolean; override;
    function SetRectRgn(aRGN: HRGN; X1, Y1, X2, Y2 : Integer): Boolean; override;
    function SetROP2(DC: HDC; Mode: Integer): Integer; override;
    function SetScrollInfo(Handle: HWND; SBStyle: Integer; ScrollInfo: TScrollInfo; Redraw : Boolean): Integer; override;
    function SetStretchBltMode(DC: HDC; StretchMode: Integer): Integer; override;
    function SetTextCharacterExtra(_hdc : hdc; nCharExtra : Integer): Integer; override;
    function SetTextColor(DC: HDC; Color: TColorRef): TColorRef; override;
    function SetWindowLong(Handle: HWND; Idx: Integer; NewLong : PtrInt): PtrInt; override;
    function SetViewPortExtEx(DC: HDC; XExtent, YExtent : Integer; OldSize: PSize): Boolean; override;
    function SetViewPortOrgEx(DC: HDC; NewX, NewY: Integer; OldPoint: PPoint): Boolean; override;
    function SetWindowExtEx(DC: HDC; XExtent, YExtent: Integer; OldSize: PSize): Boolean; override;
    function SetWindowOrgEx(dc : hdc; NewX, NewY: Integer; OldPoint: PPoint): Boolean; override;
    function SetWindowPos(hWnd: HWND; hWndInsertAfter: HWND; X, Y, cx, cy: Integer; uFlags: UINT): Boolean; override;
    function SetWindowRgn(hWnd: HWND; hRgn: HRGN; bRedraw: Boolean): longint; override;
    function ShowCaret(hWnd: HWND): Boolean; override;
    function ShowScrollBar(Handle: HWND; wBar: Integer; bShow: Boolean): Boolean; override;
    function ShowWindow(hWnd: HWND; nCmdShow: Integer): Boolean; override;
    function StretchBlt(DestDC: HDC; X, Y, Width, Height: Integer; SrcDC: HDC; XSrc, YSrc, SrcWidth, SrcHeight: Integer; Rop: Cardinal): Boolean; override;
    function StretchDIBits(DC: HDC; DestX, DestY, DestWidth, DestHeight, SrcX, SrcY, SrcWidth, SrcHeight: Integer; Bits: Pointer; var BitsInfo: TBitmapInfo; Usage: UINT; Rop: DWORD): Integer; override;
    function SystemParametersInfo(uiAction: DWord; uiParam: DWord; pvParam: Pointer; fWinIni: DWord): LongBool; override;
    function TextOut(DC: HDC; X,Y : Integer; Str : Pchar; Count: Integer): Boolean; override;
    function UpdateWindow(Handle: HWND): Boolean; override;
    function WindowFromPoint(Point : TPoint): HWND; override;
    function AddEventHandler(AHandle: TLCLHandle; AFlags: dword; AEventHandler: TWaitHandleEvent; AData: PtrInt): PEventHandler; override;
    function AddProcessEventHandler(AHandle: TLCLHandle; AEventHandler: TChildExitEvent; AData: PtrInt): PProcessEventHandler; override;
    function AddPipeEventHandler(AHandle: TLCLHandle; AEventHandler: TPipeEvent; AData: PtrInt): PPipeEventHandler; override;
    function AllocateHWnd(Method: TLCLWndMethod): HWND; override;
    function AskUser(const DialogCaption, DialogMessage: string; DialogType: LongInt; Buttons: TDialogButtons; HelpCtx: Longint): LongInt; override;
    function ClipboardFormatToMimeType(FormatID: TClipboardFormat): string; override;
    function ClipboardGetData(ClipboardType: TClipboardType; FormatID: TClipboardFormat; Stream: TStream): boolean; override;
    function ClipboardGetFormats(ClipboardType: TClipboardType; var Count: integer; var List: PClipboardFormat): boolean; override;
    function ClipboardGetOwnerShip(ClipboardType: TClipboardType; OnRequestProc: TClipboardRequestEvent; FormatCount: integer; Formats: PClipboardFormat): boolean; override;
    function ClipboardRegisterFormat(const AMimeType: string): TClipboardFormat; override;
    function ClipboardFormatNeedsNullByte(const AFormat: TPredefinedClipboardFormat): Boolean; override;
    function CreateEmptyRegion: hRGN; override;
    function CreatePixmapIndirect(const Data: Pointer; const TransColor: Longint): HBITMAP; override;
    function CreateRegionCopy(SrcRGN: hRGN): hRGN; override;
    function CreateRubberBand(const ARect: TRect; const ABrush: HBrush): HWND; override;
    function CreateStandardCursor(ACursor: SmallInt): hCursor; override;
    function DCClipRegionValid(DC: HDC): boolean; override;
    procedure DeallocateHWnd(Wnd: HWND); override;
    procedure DestroyRubberBand(ARubberBand: HWND); override;
    procedure DrawDefaultDockImage(AOldRect, ANewRect: TRect; AOperation: TDockImageOperation); override;
    procedure DrawGrid(DC: HDC; const R: TRect; DX, DY: Integer); override;
    function ExtUTF8Out(DC: HDC; X, Y: Integer; Options: Longint; Rect: PRect; Str: PChar; Count: Longint; Dx: PInteger): Boolean; override;
    function FontIsMonoSpace(Font: HFont): boolean; override;
    function Frame3d(DC: HDC; var ARect: TRect; const FrameWidth : integer; const Style : TGraphicsBevelCut): Boolean; override;
    function GetAcceleratorString(const AVKey: Byte; const AShiftState: TShiftState): String; override;
    function GetAvailableNativeCanvasTypes(DC: HDC; AAllowFallbackToParent: Boolean): TNativeCanvasTypes; override;
    function GetAvailableNativeHandleTypes(Handle: HWND; AAllowFallbackToParent: Boolean): TNativeHandleTypes; override;
    function GetCaretRespondToFocus(handle: HWND; var ShowHideOnFocus: boolean): Boolean; override;
    function GetClientBounds(handle : HWND; var ARect: TRect): Boolean; override;
    function GetCmdLineParamDescForInterface: TStringList; override;
    function GetControlConstraints(Constraints: TObject): boolean; override;
    function GetDCOriginRelativeToWindow(PaintDC: HDC; WindowHandle: HWND; var OriginDiff: TPoint): boolean; override;
    function GetDesignerDC(WindowHandle: HWND): HDC; override;
    function GetDeviceSize(DC: HDC; var p: TPoint): boolean; override;
    function GetLCLOwnerObject(Handle: HWnd): TObject; override;
    function GetNativeCanvas(DC: HDC; AHandleType: TNativeCanvasType; AAllowFallbackToParent: Boolean): PtrInt; override;
    function GetNativeHandle(Handle: HWND; AHandleType: TNativeHandleType; AAllowFallbackToParent: Boolean): PtrInt; override;
    function GetScrollBarSize(Handle: HWND; SBStyle: Integer): integer; override;
    function GetScrollbarVisible(Handle: HWND; SBStyle: Integer): boolean; override;
    function GetWindowRelativePosition(Handle : hwnd; var Left, Top: integer): boolean; override;
    function InvalidateFrame(aHandle : HWND; ARect : pRect; bErase : Boolean; BorderWidth: integer): Boolean; override;
    function IsDesignerDC(WindowHandle: HWND; DC: HDC): Boolean; override;
    function IsMobilePlatform: Boolean; override;
    function IsCDIntfControl(AWinControl: TObject): Boolean; override;
    function MoveWindowOrgEx(dc : hdc; dX,dY : Integer): boolean; override;
    function PromptUser(const DialogCaption, DialogMessage : String; DialogType : longint; Buttons : PLongint; ButtonCount, DefaultIndex, EscapeResult : Longint): Longint; override;
    function PromptUserAtXY(const DialogCaption, DialogMessage : String; DialogType : longint; Buttons : PLongint; ButtonCount, DefaultIndex, EscapeResult : Longint; X, Y : Longint): Longint; override;
    function RadialArc(DC: HDC; left, top, right, bottom, sx, sy, ex, ey : Integer): Boolean; override;
    function RadialChord(DC: HDC; x1, y1, x2, y2, sx, sy, ex, ey : Integer): Boolean; override;
    function RadialPie(DC: HDC; x1, y1, x2, y2, Angle1, Angle2: Integer): Boolean; override;
    function RawImage_CreateBitmaps(const ARawImage: TRawImage; out ABitmap, AMask: HBitmap; ASkipMask: Boolean): Boolean; override;
    function RawImage_DescriptionFromBitmap(ABitmap: HBITMAP; out ADesc: TRawImageDescription): Boolean; override;
    function RawImage_DescriptionFromDevice(ADC: HDC; out ADesc: TRawImageDescription): Boolean; override;
    function RawImage_FromBitmap(out ARawImage: TRawImage; ABitmap, AMask: HBITMAP; ARect: PRect): Boolean; override;
    function RawImage_FromDevice(out ARawImage: TRawImage; ADC: HDC; const ARect: TRect): Boolean; override;
    function RawImage_QueryDescription(AFlags: TRawImageQueryFlags; var ADesc: TRawImageDescription): Boolean; override;
    function RegroupMenuItem(hndMenu: HMENU; GroupIndex: integer): Boolean; override;
    function ReleaseDesignerDC(hWnd: HWND; DC: HDC): Integer; override;
    procedure RemoveEventHandler(var AHandler: PEventHandler); override;
    procedure RemoveProcessEventHandler(var AHandler: PProcessEventHandler); override;
    procedure RemovePipeEventHandler(var AHandler: PPipeEventHandler); override;
    function RequestInput(const InputCaption, InputPrompt : String; MaskInput : Boolean; var Value : String): Boolean; override;
    procedure SendCachedLCLMessages; override;
    function SetCaretRespondToFocus(handle: HWND; ShowHideOnFocus: boolean): Boolean; override;
    function SetComboMinDropDownSize(Handle: HWND; MinItemsWidth, MinItemsHeight, MinItemCount: integer): boolean; override;
    procedure SetEventHandlerFlags(AHandler: PEventHandler; NewFlags: dword); override;
    procedure SetRubberBandRect(const ARubberBand: HWND; const ARect: TRect); override;
    function ShowSelectItemDialog(const AItems: TStrings; APos: TPoint): Boolean; override;
    function StretchMaskBlt(DestDC: HDC; X, Y, Width, Height: Integer; SrcDC: HDC; XSrc, YSrc, SrcWidth, SrcHeight: Integer; Mask: HBITMAP; XMask, YMask: Integer; Rop: DWORD): Boolean; override;
    function TextUTF8Out(DC: HDC; X, Y: Integer; Str: PChar; Count: Longint): Boolean; override;
  end;

procedure LWInstallProxyWidgetSet;
function LWIsMainThread: Boolean; inline;

implementation

type
  TRouteLCLArray  = array[0..8] of TComponentClass;
  TRouteWSArray   = array[0..8] of TWSLCLComponentClass;
  TEmptyLCLArray  = array[0..24] of TComponentClass;
  TEmptyWSArray   = array[0..24] of TWSLCLComponentClass;

var
  GInstalled: Boolean = False;
  GScreenW: Integer = 1920;
  GScreenH: Integer = 1080;
  GFontHeightPx: Integer = 13;
  FVirtual: TLWVirtualWS = nil;  { 工作线程的无头实现 }

var
  GRealWinControl: TWSWinControlClass = nil;   { 捕获的真实 TWinControl 类 }
  GRealCustomForm: TWSCustomFormClass = nil;   { 捕获的真实 TCustomForm 类 }
  GRealCustomMemo: TWSCustomMemoClass = nil;   { 捕获的真实 TCustomMemo 类 }
  GRealCustomButton: TWSButtonClass = nil;   { 捕获的真实 TCustomButton 类 }
  GRealStatusBar: TWSStatusBarClass = nil;   { 捕获的真实 TStatusBar 类 }
  GRealMenuItem: TWSMenuItemClass = nil;   { 捕获的真实 TMenuItem 类 }
  GRealMenu: TWSMenuClass = nil;   { 捕获的真实 TMenu 类 }
  GRealMainMenu: TWSMenuClass = nil;   { 捕获的真实 TMainMenu 类 }
  GRealPopupMenu: TWSPopupMenuClass = nil;   { 捕获的真实 TPopupMenu 类 }
  GRouteLCL: TRouteLCLArray = (TWinControl, TCustomForm, TCustomMemo, TCustomButton, TStatusBar, TMenuItem, TMenu, TMainMenu, TPopupMenu);
  GRouteProxy: TRouteWSArray = (TLWWSWinControl, TLWWSCustomForm, TLWWSCustomMemo, TLWWSCustomButton, TLWWSStatusBar, TLWWSMenuItem, TLWWSMenu, TLWWSMainMenu, TLWWSPopupMenu);
  GEmptyLCL: TEmptyLCLArray = (TCustomEdit, TCustomComboBox, TCustomListBox, TCustomScrollBar, TCustomGroupBox, TCustomCheckBox, TToggleBox, TRadioButton, TCustomStaticText, TCustomPage, TCustomBitBtn, TCustomCheckListBox, TCustomGrid, TCustomFloatSpinEdit, TCustomCalendar, TCustomListView, TCustomProgressBar, TToolBar, TCustomTrackBar, TScrollingWinControl, TCommonDialog, TFileDialog, TOpenDialog, TColorDialog, TFontDialog);
  GEmptyWS: TEmptyWSArray = (TWSCustomEdit, TWSCustomComboBox, TWSCustomListBox, TWSScrollBar, TWSCustomGroupBox, TWSCustomCheckBox, TWSToggleBox, TWSRadioButton, TWSCustomStaticText, TWSCustomPage, TWSBitBtn, TWSCustomCheckListBox, TWSCustomGrid, TWSCustomFloatSpinEdit, TWSCustomCalendar, TWSCustomListView, TWSProgressBar, TWSToolBar, TWSTrackBar, TWSScrollingWinControl, TWSCommonDialog, TWSFileDialog, TWSOpenDialog, TWSColorDialog, TWSFontDialog);

function LWIsMainThread: Boolean;
begin
  Result := GetCurrentThreadId = MainThreadID;
end;

{ ---------------- TLWVirtualWS：无头实现（照搬 nogui 部署档行为） ---------------- }

constructor TLWVirtualWS.Create;
begin
  inherited Create;
end;

function TLWVirtualWS.LCLPlatform: TLCLPlatform;
begin
  Result := lpNoGUI;
end;

procedure TLWVirtualWS.AppInit(var ScreenInfo: TScreenInfo);
begin
end;

procedure TLWVirtualWS.AppProcessMessages;
begin
  { 与 nogui 一致：工作线程泵消息时顺手处理同步队列 }
  if IsMultiThread then
    CheckSynchronize;
end;

procedure TLWVirtualWS.AppWaitMessage; begin end;
procedure TLWVirtualWS.AppTerminate; begin end;
procedure TLWVirtualWS.AppMinimize; begin end;
procedure TLWVirtualWS.AppRestore; begin end;
procedure TLWVirtualWS.AppBringToFront; begin end;
procedure TLWVirtualWS.AppSetTitle(const ATitle: string); begin end;

function TLWVirtualWS.EnumFontFamiliesEx(DC: HDC; lpLogFont: PLogFont;
  Callback: FontEnumExProc; Lparam: LParam; Flags: dword): longint;
begin
  Result := 0;
end;

function TLWVirtualWS.CreateTimer(Interval: integer; TimerFunc: TWSTimerProc): TLCLHandle;
begin
  Result := 0;   { 与 nogui 相同：不支持服务端 UI 定时器 }
end;

function TLWVirtualWS.DestroyTimer(TimerHandle: TLCLHandle): boolean;
begin
  Result := false;
end;

procedure TLWVirtualWS.DestroyLCLComponent(Sender: TObject);
begin
end;

function TLWVirtualWS.EnumDisplayMonitors(hdc: HDC; lprcClip: PRect;
  lpfnEnum: MonitorEnumProc; dwData: LPARAM): LongBool;
var
  r: TRect;
begin
  Result := False;
  if not Assigned(lpfnEnum) then Exit;
  r.Left := 0; r.Top := 0;
  r.Right := GScreenW; r.Bottom := GScreenH;
  lpfnEnum(HMONITOR(1), 0, @r, dwData);
  Result := True;
end;

function TLWVirtualWS.GetMonitorInfo(hMonitor: HMONITOR; lpmi: PMonitorInfo): Boolean;
begin
  Result := False;
  if lpmi = nil then Exit;
  FillChar(lpmi^, SizeOf(lpmi^), 0);
  lpmi^.cbSize := SizeOf(lpmi^);
  lpmi^.rcMonitor.Left := 0; lpmi^.rcMonitor.Top := 0;
  lpmi^.rcMonitor.Right := GScreenW; lpmi^.rcMonitor.Bottom := GScreenH;
  lpmi^.rcWork := lpmi^.rcMonitor;
  lpmi^.dwFlags := 1;
  Result := True;
end;

function TLWVirtualWS.MonitorFromWindow(hWnd: HWND; dwFlags: DWord): HMONITOR;
begin
  Result := HMONITOR(1);
end;

function TLWVirtualWS.MonitorFromPoint(pt: TPoint; dwFlags: DWord): HMONITOR;
begin
  Result := HMONITOR(1);
end;

function TLWVirtualWS.GetDpiForMonitor(hmonitor: HMONITOR; dpiType: TMonitorDpiType;
  out dpiX: UINT; out dpiY: UINT): HRESULT;
begin
  dpiX := 96; dpiY := 96;
  Result := S_OK;
end;

function TLWVirtualWS.CreateCompatibleDC(DC: HDC): HDC;
begin
  Result := HDC(1000);
end;

function TLWVirtualWS.DeleteDC(hDC: HDC): Boolean;
begin
  Result := True;
end;

function TLWVirtualWS.SelectObject(DC: HDC; GDIObj: HGDIOBJ): HGDIOBJ;
begin
  Result := 0;
end;

function CurFontPx: Integer;
begin
  if GFontHeightPx <= 0 then Result := 13 else Result := GFontHeightPx;
end;

function TLWVirtualWS.CreateFontIndirect(const LogFont: TLogFont): HFONT;
begin
  if LogFont.lfHeight <> 0 then GFontHeightPx := Abs(LogFont.lfHeight);
  Result := HFONT(7000);
end;

function TLWVirtualWS.CreateFontIndirectEx(const LogFont: TLogFont;
  const LongFontName: string): HFONT;
begin
  if LogFont.lfHeight <> 0 then GFontHeightPx := Abs(LogFont.lfHeight);
  Result := HFONT(7001);
end;

function TLWVirtualWS.GetTextExtentPoint32(DC: HDC; Str: PChar; Count: Integer;
  var Size: TSize): Boolean;
var
  h: Integer;
begin
  h := CurFontPx;
  Size.cx := Max(1, Round(Count * h * 0.55));
  Size.cy := Round(h * 1.25) + 3;
  Result := True;
end;

function TLWVirtualWS.GetTextMetrics(DC: HDC; var TM: TTextMetric): Boolean;
var
  h: Integer;
begin
  h := CurFontPx;
  TM.tmHeight := h;
  TM.tmAscent := h - 3;
  TM.tmDescent := 3;
  TM.tmInternalLeading := 2;
  TM.tmExternalLeading := 2;
  TM.tmAveCharWidth := Max(6, Round(h * 0.5));
  TM.tmMaxCharWidth := Max(8, Round(h * 0.9));
  TM.tmWeight := 400;
  TM.tmCharSet := 1;
  Result := True;
end;

function TLWVirtualWS.GetDeviceCaps(DC: HDC; Index: Integer): Integer;
begin
  case Index of
    88, 90: Result := 96;
    6: Result := GScreenW;
    10: Result := GScreenH;
  else
    Result := 0;
  end;
end;

function TLWVirtualWS.GetDC(hWnd: HWND): HDC;
begin
  Result := HDC(2000);
end;

function TLWVirtualWS.ReleaseDC(hWnd: HWND; hDC: HDC): Integer;
begin
  Result := 1;
end;

function TLWVirtualWS.SetTextColor(DC: HDC; Color: TColorRef): TColorRef;
begin
  Result := Color;
end;

function TLWVirtualWS.SetBkColor(DC: HDC; Color: TColorRef): TColorRef;
begin
  Result := Color;
end;

function TLWVirtualWS.SaveDC(DC: HDC): Integer;
begin
  Result := 1;
end;

function TLWVirtualWS.RestoreDC(DC: HDC; SavedDC: Integer): Boolean;
begin
  Result := True;
end;

function TLWVirtualWS.DCGetPixel(CanvasHandle: HDC; X: LongInt; Y: LongInt): TColor;
begin
  Result := clBlack;
end;

procedure TLWVirtualWS.DCSetPixel(CanvasHandle: HDC; X: LongInt; Y: LongInt; AColor: TColor);
begin
end;

procedure TLWVirtualWS.DCRedraw(CanvasHandle: HDC);
begin
end;

{ TLWWSWinControl：主线程走真实类，工作线程走空基类（= nogui 行为） }
class function TLWWSWinControl.CanFocus(const AWincontrol: TWinControl): Boolean;
begin
  if LWIsMainThread then
    Result := GRealWinControl.CanFocus(AWincontrol)
  else
    Result := inherited CanFocus(AWincontrol);
end;

class function TLWWSWinControl.GetClientBounds(const AWincontrol: TWinControl; var ARect: TRect): Boolean;
begin
  if LWIsMainThread then
    Result := GRealWinControl.GetClientBounds(AWincontrol, ARect)
  else
    Result := inherited GetClientBounds(AWincontrol, ARect);
end;

class function TLWWSWinControl.GetClientRect(const AWincontrol: TWinControl; var ARect: TRect): Boolean;
begin
  if LWIsMainThread then
    Result := GRealWinControl.GetClientRect(AWincontrol, ARect)
  else
    Result := inherited GetClientRect(AWincontrol, ARect);
end;

class procedure TLWWSWinControl.GetPreferredSize(const AWinControl: TWinControl; var PreferredWidth, PreferredHeight: integer; WithThemeSpace: Boolean);
begin
  if LWIsMainThread then
    GRealWinControl.GetPreferredSize(AWinControl, PreferredWidth, PreferredHeight, WithThemeSpace)
  else
    inherited GetPreferredSize(AWinControl, PreferredWidth, PreferredHeight, WithThemeSpace);
end;

class function TLWWSWinControl.GetDefaultClientRect(const AWinControl: TWinControl; const aLeft, aTop, aWidth, aHeight: integer; var aClientRect: TRect): boolean;
begin
  if LWIsMainThread then
    Result := GRealWinControl.GetDefaultClientRect(AWinControl, aLeft, aTop, aWidth, aHeight, aClientRect)
  else
    Result := inherited GetDefaultClientRect(AWinControl, aLeft, aTop, aWidth, aHeight, aClientRect);
end;

class function TLWWSWinControl.GetDesignInteractive(const AWinControl: TWinControl; AClientPos: TPoint): Boolean;
begin
  if LWIsMainThread then
    Result := GRealWinControl.GetDesignInteractive(AWinControl, AClientPos)
  else
    Result := inherited GetDesignInteractive(AWinControl, AClientPos);
end;

class function TLWWSWinControl.GetDoubleBuffered(const AWinControl: TWinControl): Boolean;
begin
  if LWIsMainThread then
    Result := GRealWinControl.GetDoubleBuffered(AWinControl)
  else
    Result := inherited GetDoubleBuffered(AWinControl);
end;

class function TLWWSWinControl.GetText(const AWinControl: TWinControl; var AText: String): Boolean;
begin
  if LWIsMainThread then
    Result := GRealWinControl.GetText(AWinControl, AText)
  else
    Result := inherited GetText(AWinControl, AText);
end;

class function TLWWSWinControl.GetTextLen(const AWinControl: TWinControl; var ALength: Integer): Boolean;
begin
  if LWIsMainThread then
    Result := GRealWinControl.GetTextLen(AWinControl, ALength)
  else
    Result := inherited GetTextLen(AWinControl, ALength);
end;

class procedure TLWWSWinControl.SetBiDiMode(const AWinControl: TWinControl; UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar : Boolean);
begin
  if LWIsMainThread then
    GRealWinControl.SetBiDiMode(AWinControl, UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar)
  else
    inherited SetBiDiMode(AWinControl, UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar);
end;

class procedure TLWWSWinControl.SetBorderStyle(const AWinControl: TWinControl; const ABorderStyle: TBorderStyle);
begin
  if LWIsMainThread then
    GRealWinControl.SetBorderStyle(AWinControl, ABorderStyle)
  else
    inherited SetBorderStyle(AWinControl, ABorderStyle);
end;

class procedure TLWWSWinControl.SetBounds(const AWinControl: TWinControl; const ALeft, ATop, AWidth, AHeight: Integer);
begin
  if LWIsMainThread then
    GRealWinControl.SetBounds(AWinControl, ALeft, ATop, AWidth, AHeight)
  else
    inherited SetBounds(AWinControl, ALeft, ATop, AWidth, AHeight);
end;

class procedure TLWWSWinControl.SetColor(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealWinControl.SetColor(AWinControl)
  else
    inherited SetColor(AWinControl);
end;

class procedure TLWWSWinControl.SetChildZPosition(const AWinControl, AChild: TWinControl; const AOldPos, ANewPos: Integer; const AChildren: TFPList);
begin
  if LWIsMainThread then
    GRealWinControl.SetChildZPosition(AWinControl, AChild, AOldPos, ANewPos, AChildren)
  else
    inherited SetChildZPosition(AWinControl, AChild, AOldPos, ANewPos, AChildren);
end;

class procedure TLWWSWinControl.SetFont(const AWinControl: TWinControl; const AFont: TFont);
begin
  if LWIsMainThread then
    GRealWinControl.SetFont(AWinControl, AFont)
  else
    inherited SetFont(AWinControl, AFont);
end;

class procedure TLWWSWinControl.SetPos(const AWinControl: TWinControl; const ALeft, ATop: Integer);
begin
  if LWIsMainThread then
    GRealWinControl.SetPos(AWinControl, ALeft, ATop)
  else
    inherited SetPos(AWinControl, ALeft, ATop);
end;

class procedure TLWWSWinControl.SetSize(const AWinControl: TWinControl; const AWidth, AHeight: Integer);
begin
  if LWIsMainThread then
    GRealWinControl.SetSize(AWinControl, AWidth, AHeight)
  else
    inherited SetSize(AWinControl, AWidth, AHeight);
end;

class procedure TLWWSWinControl.SetText(const AWinControl: TWinControl; const AText: String);
begin
  if LWIsMainThread then
    GRealWinControl.SetText(AWinControl, AText)
  else
    inherited SetText(AWinControl, AText);
end;

class procedure TLWWSWinControl.SetCursor(const AWinControl: TWinControl; const ACursor: HCursor);
begin
  if LWIsMainThread then
    GRealWinControl.SetCursor(AWinControl, ACursor)
  else
    inherited SetCursor(AWinControl, ACursor);
end;

class procedure TLWWSWinControl.SetShape(const AWinControl: TWinControl; const AShape: HBITMAP);
begin
  if LWIsMainThread then
    GRealWinControl.SetShape(AWinControl, AShape)
  else
    inherited SetShape(AWinControl, AShape);
end;

class procedure TLWWSWinControl.AdaptBounds(const AWinControl: TWinControl; var Left, Top, Width, Height: integer; var SuppressMove: boolean);
begin
  if LWIsMainThread then
    GRealWinControl.AdaptBounds(AWinControl, Left, Top, Width, Height, SuppressMove)
  else
    inherited AdaptBounds(AWinControl, Left, Top, Width, Height, SuppressMove);
end;

class procedure TLWWSWinControl.ConstraintsChange(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealWinControl.ConstraintsChange(AWinControl)
  else
    inherited ConstraintsChange(AWinControl);
end;

class function TLWWSWinControl.CreateHandle(const AWinControl: TWinControl; const AParams: TCreateParams): TLCLHandle;
begin
  if LWIsMainThread then
    Result := GRealWinControl.CreateHandle(AWinControl, AParams)
  else
    Result := inherited CreateHandle(AWinControl, AParams);
end;

class procedure TLWWSWinControl.DestroyHandle(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealWinControl.DestroyHandle(AWinControl)
  else
    inherited DestroyHandle(AWinControl);
end;

class procedure TLWWSWinControl.Invalidate(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealWinControl.Invalidate(AWinControl)
  else
    inherited Invalidate(AWinControl);
end;

class procedure TLWWSWinControl.PaintTo(const AWinControl: TWinControl; ADC: HDC; X, Y: Integer);
begin
  if LWIsMainThread then
    GRealWinControl.PaintTo(AWinControl, ADC, X, Y)
  else
    inherited PaintTo(AWinControl, ADC, X, Y);
end;

class procedure TLWWSWinControl.Repaint(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealWinControl.Repaint(AWinControl)
  else
    inherited Repaint(AWinControl);
end;

class procedure TLWWSWinControl.ShowHide(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealWinControl.ShowHide(AWinControl)
  else
    inherited ShowHide(AWinControl);
end;

class procedure TLWWSWinControl.ScrollBy(const AWinControl: TWinControl; DeltaX, DeltaY: integer);
begin
  if LWIsMainThread then
    GRealWinControl.ScrollBy(AWinControl, DeltaX, DeltaY)
  else
    inherited ScrollBy(AWinControl, DeltaX, DeltaY);
end;

class procedure TLWWSWinControl.AddControl(const AControl: TControl);
begin
  if LWIsMainThread then
    GRealWinControl.AddControl(AControl)
  else
    inherited AddControl(AControl);
end;

class function TLWWSWinControl.GetConstraints(const AControl: TControl; const AConstraints: TObject): Boolean;
begin
  if LWIsMainThread then
    Result := GRealWinControl.GetConstraints(AControl, AConstraints)
  else
    Result := inherited GetConstraints(AControl, AConstraints);
end;

class function TLWWSWinControl.GetDefaultColor(const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor;
begin
  if LWIsMainThread then
    Result := GRealWinControl.GetDefaultColor(AControl, ADefaultColorType)
  else
    Result := inherited GetDefaultColor(AControl, ADefaultColorType);
end;

class procedure TLWWSWinControl.ConstraintWidth(const AControl: TControl; const AConstraints: TObject; var aWidth: integer);
begin
  if LWIsMainThread then
    GRealWinControl.ConstraintWidth(AControl, AConstraints, aWidth)
  else
    inherited ConstraintWidth(AControl, AConstraints, aWidth);
end;

class procedure TLWWSWinControl.ConstraintHeight(const AControl: TControl; const AConstraints: TObject; var aHeight: integer);
begin
  if LWIsMainThread then
    GRealWinControl.ConstraintHeight(AControl, AConstraints, aHeight)
  else
    inherited ConstraintHeight(AControl, AConstraints, aHeight);
end;

class function TLWWSWinControl.GetCanvasScaleFactor(const AControl: TControl): Double;
begin
  if LWIsMainThread then
    Result := GRealWinControl.GetCanvasScaleFactor(AControl)
  else
    Result := inherited GetCanvasScaleFactor(AControl);
end;

{ TLWWSCustomForm：主线程走真实类，工作线程走空基类（= nogui 行为） }
class procedure TLWWSCustomForm.CloseModal(const ACustomForm: TCustomForm);
begin
  if LWIsMainThread then
    GRealCustomForm.CloseModal(ACustomForm)
  else
    inherited CloseModal(ACustomForm);
end;

class procedure TLWWSCustomForm.SetAllowDropFiles(const AForm: TCustomForm; AValue: Boolean);
begin
  if LWIsMainThread then
    GRealCustomForm.SetAllowDropFiles(AForm, AValue)
  else
    inherited SetAllowDropFiles(AForm, AValue);
end;

class procedure TLWWSCustomForm.SetAlphaBlend(const ACustomForm: TCustomForm; const AlphaBlend: Boolean; const Alpha: Byte);
begin
  if LWIsMainThread then
    GRealCustomForm.SetAlphaBlend(ACustomForm, AlphaBlend, Alpha)
  else
    inherited SetAlphaBlend(ACustomForm, AlphaBlend, Alpha);
end;

class procedure TLWWSCustomForm.SetBorderIcons(const AForm: TCustomForm; const ABorderIcons: TBorderIcons);
begin
  if LWIsMainThread then
    GRealCustomForm.SetBorderIcons(AForm, ABorderIcons)
  else
    inherited SetBorderIcons(AForm, ABorderIcons);
end;

class procedure TLWWSCustomForm.SetFormBorderStyle(const AForm: TCustomForm; const AFormBorderStyle: TFormBorderStyle);
begin
  if LWIsMainThread then
    GRealCustomForm.SetFormBorderStyle(AForm, AFormBorderStyle)
  else
    inherited SetFormBorderStyle(AForm, AFormBorderStyle);
end;

class procedure TLWWSCustomForm.SetFormStyle(const AForm: TCustomform; const AFormStyle, AOldFormStyle: TFormStyle);
begin
  if LWIsMainThread then
    GRealCustomForm.SetFormStyle(AForm, AFormStyle, AOldFormStyle)
  else
    inherited SetFormStyle(AForm, AFormStyle, AOldFormStyle);
end;

class procedure TLWWSCustomForm.SetIcon(const AForm: TCustomForm; const Small, Big: HICON);
begin
  if LWIsMainThread then
    GRealCustomForm.SetIcon(AForm, Small, Big)
  else
    inherited SetIcon(AForm, Small, Big);
end;

class procedure TLWWSCustomForm.ShowModal(const ACustomForm: TCustomForm);
begin
  if LWIsMainThread then
    GRealCustomForm.ShowModal(ACustomForm)
  else
    inherited ShowModal(ACustomForm);
end;

class procedure TLWWSCustomForm.SetModalResult(const ACustomForm: TCustomForm; ANewValue: TModalResult);
begin
  if LWIsMainThread then
    GRealCustomForm.SetModalResult(ACustomForm, ANewValue)
  else
    inherited SetModalResult(ACustomForm, ANewValue);
end;

class procedure TLWWSCustomForm.SetRealPopupParent(const ACustomForm: TCustomForm; const APopupParent: TCustomForm);
begin
  if LWIsMainThread then
    GRealCustomForm.SetRealPopupParent(ACustomForm, APopupParent)
  else
    inherited SetRealPopupParent(ACustomForm, APopupParent);
end;

class procedure TLWWSCustomForm.SetShowInTaskbar(const AForm: TCustomForm; const AValue: TShowInTaskbar);
begin
  if LWIsMainThread then
    GRealCustomForm.SetShowInTaskbar(AForm, AValue)
  else
    inherited SetShowInTaskbar(AForm, AValue);
end;

class procedure TLWWSCustomForm.SetZPosition(const AWinControl: TWinControl; const APosition: TWSZPosition);
begin
  if LWIsMainThread then
    GRealCustomForm.SetZPosition(AWinControl, APosition)
  else
    inherited SetZPosition(AWinControl, APosition);
end;

class function TLWWSCustomForm.GetDefaultDoubleBuffered: Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.GetDefaultDoubleBuffered()
  else
    Result := inherited GetDefaultDoubleBuffered();
end;

class function TLWWSCustomForm.ActiveMDIChild(const AForm: TCustomForm): TCustomForm;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.ActiveMDIChild(AForm)
  else
    Result := inherited ActiveMDIChild(AForm);
end;

class function TLWWSCustomForm.Cascade(const AForm: TCustomForm): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.Cascade(AForm)
  else
    Result := inherited Cascade(AForm);
end;

class function TLWWSCustomForm.GetClientHandle(const AForm: TCustomForm): HWND;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.GetClientHandle(AForm)
  else
    Result := inherited GetClientHandle(AForm);
end;

class function TLWWSCustomForm.GetMDIChildren(const AForm: TCustomForm; AIndex: Integer): TCustomForm;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.GetMDIChildren(AForm, AIndex)
  else
    Result := inherited GetMDIChildren(AForm, AIndex);
end;

class function TLWWSCustomForm.Next(const AForm: TCustomForm): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.Next(AForm)
  else
    Result := inherited Next(AForm);
end;

class function TLWWSCustomForm.Previous(const AForm: TCustomForm): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.Previous(AForm)
  else
    Result := inherited Previous(AForm);
end;

class function TLWWSCustomForm.Tile(const AForm: TCustomForm): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.Tile(AForm)
  else
    Result := inherited Tile(AForm);
end;

class function TLWWSCustomForm.ArrangeIcons(const AForm: TCustomForm): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.ArrangeIcons(AForm)
  else
    Result := inherited ArrangeIcons(AForm);
end;

class function TLWWSCustomForm.MDIChildCount(const AForm: TCustomForm): Integer;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.MDIChildCount(AForm)
  else
    Result := inherited MDIChildCount(AForm);
end;

class function TLWWSCustomForm.CanFocus(const AWincontrol: TWinControl): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.CanFocus(AWincontrol)
  else
    Result := inherited CanFocus(AWincontrol);
end;

class function TLWWSCustomForm.GetClientBounds(const AWincontrol: TWinControl; var ARect: TRect): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.GetClientBounds(AWincontrol, ARect)
  else
    Result := inherited GetClientBounds(AWincontrol, ARect);
end;

class function TLWWSCustomForm.GetClientRect(const AWincontrol: TWinControl; var ARect: TRect): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.GetClientRect(AWincontrol, ARect)
  else
    Result := inherited GetClientRect(AWincontrol, ARect);
end;

class procedure TLWWSCustomForm.GetPreferredSize(const AWinControl: TWinControl; var PreferredWidth, PreferredHeight: integer; WithThemeSpace: Boolean);
begin
  if LWIsMainThread then
    GRealCustomForm.GetPreferredSize(AWinControl, PreferredWidth, PreferredHeight, WithThemeSpace)
  else
    inherited GetPreferredSize(AWinControl, PreferredWidth, PreferredHeight, WithThemeSpace);
end;

class function TLWWSCustomForm.GetDefaultClientRect(const AWinControl: TWinControl; const aLeft, aTop, aWidth, aHeight: integer; var aClientRect: TRect): boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.GetDefaultClientRect(AWinControl, aLeft, aTop, aWidth, aHeight, aClientRect)
  else
    Result := inherited GetDefaultClientRect(AWinControl, aLeft, aTop, aWidth, aHeight, aClientRect);
end;

class function TLWWSCustomForm.GetDesignInteractive(const AWinControl: TWinControl; AClientPos: TPoint): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.GetDesignInteractive(AWinControl, AClientPos)
  else
    Result := inherited GetDesignInteractive(AWinControl, AClientPos);
end;

class function TLWWSCustomForm.GetDoubleBuffered(const AWinControl: TWinControl): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.GetDoubleBuffered(AWinControl)
  else
    Result := inherited GetDoubleBuffered(AWinControl);
end;

class function TLWWSCustomForm.GetText(const AWinControl: TWinControl; var AText: String): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.GetText(AWinControl, AText)
  else
    Result := inherited GetText(AWinControl, AText);
end;

class function TLWWSCustomForm.GetTextLen(const AWinControl: TWinControl; var ALength: Integer): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.GetTextLen(AWinControl, ALength)
  else
    Result := inherited GetTextLen(AWinControl, ALength);
end;

class procedure TLWWSCustomForm.SetBiDiMode(const AWinControl: TWinControl; UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar : Boolean);
begin
  if LWIsMainThread then
    GRealCustomForm.SetBiDiMode(AWinControl, UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar)
  else
    inherited SetBiDiMode(AWinControl, UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar);
end;

class procedure TLWWSCustomForm.SetBorderStyle(const AWinControl: TWinControl; const ABorderStyle: TBorderStyle);
begin
  if LWIsMainThread then
    GRealCustomForm.SetBorderStyle(AWinControl, ABorderStyle)
  else
    inherited SetBorderStyle(AWinControl, ABorderStyle);
end;

class procedure TLWWSCustomForm.SetBounds(const AWinControl: TWinControl; const ALeft, ATop, AWidth, AHeight: Integer);
begin
  if LWIsMainThread then
    GRealCustomForm.SetBounds(AWinControl, ALeft, ATop, AWidth, AHeight)
  else
    inherited SetBounds(AWinControl, ALeft, ATop, AWidth, AHeight);
end;

class procedure TLWWSCustomForm.SetColor(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomForm.SetColor(AWinControl)
  else
    inherited SetColor(AWinControl);
end;

class procedure TLWWSCustomForm.SetChildZPosition(const AWinControl, AChild: TWinControl; const AOldPos, ANewPos: Integer; const AChildren: TFPList);
begin
  if LWIsMainThread then
    GRealCustomForm.SetChildZPosition(AWinControl, AChild, AOldPos, ANewPos, AChildren)
  else
    inherited SetChildZPosition(AWinControl, AChild, AOldPos, ANewPos, AChildren);
end;

class procedure TLWWSCustomForm.SetFont(const AWinControl: TWinControl; const AFont: TFont);
begin
  if LWIsMainThread then
    GRealCustomForm.SetFont(AWinControl, AFont)
  else
    inherited SetFont(AWinControl, AFont);
end;

class procedure TLWWSCustomForm.SetPos(const AWinControl: TWinControl; const ALeft, ATop: Integer);
begin
  if LWIsMainThread then
    GRealCustomForm.SetPos(AWinControl, ALeft, ATop)
  else
    inherited SetPos(AWinControl, ALeft, ATop);
end;

class procedure TLWWSCustomForm.SetSize(const AWinControl: TWinControl; const AWidth, AHeight: Integer);
begin
  if LWIsMainThread then
    GRealCustomForm.SetSize(AWinControl, AWidth, AHeight)
  else
    inherited SetSize(AWinControl, AWidth, AHeight);
end;

class procedure TLWWSCustomForm.SetText(const AWinControl: TWinControl; const AText: String);
begin
  if LWIsMainThread then
    GRealCustomForm.SetText(AWinControl, AText)
  else
    inherited SetText(AWinControl, AText);
end;

class procedure TLWWSCustomForm.SetCursor(const AWinControl: TWinControl; const ACursor: HCursor);
begin
  if LWIsMainThread then
    GRealCustomForm.SetCursor(AWinControl, ACursor)
  else
    inherited SetCursor(AWinControl, ACursor);
end;

class procedure TLWWSCustomForm.SetShape(const AWinControl: TWinControl; const AShape: HBITMAP);
begin
  if LWIsMainThread then
    GRealCustomForm.SetShape(AWinControl, AShape)
  else
    inherited SetShape(AWinControl, AShape);
end;

class procedure TLWWSCustomForm.AdaptBounds(const AWinControl: TWinControl; var Left, Top, Width, Height: integer; var SuppressMove: boolean);
begin
  if LWIsMainThread then
    GRealCustomForm.AdaptBounds(AWinControl, Left, Top, Width, Height, SuppressMove)
  else
    inherited AdaptBounds(AWinControl, Left, Top, Width, Height, SuppressMove);
end;

class procedure TLWWSCustomForm.ConstraintsChange(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomForm.ConstraintsChange(AWinControl)
  else
    inherited ConstraintsChange(AWinControl);
end;

class function TLWWSCustomForm.CreateHandle(const AWinControl: TWinControl; const AParams: TCreateParams): TLCLHandle;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.CreateHandle(AWinControl, AParams)
  else
    Result := inherited CreateHandle(AWinControl, AParams);
end;

class procedure TLWWSCustomForm.DestroyHandle(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomForm.DestroyHandle(AWinControl)
  else
    inherited DestroyHandle(AWinControl);
end;

class procedure TLWWSCustomForm.Invalidate(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomForm.Invalidate(AWinControl)
  else
    inherited Invalidate(AWinControl);
end;

class procedure TLWWSCustomForm.PaintTo(const AWinControl: TWinControl; ADC: HDC; X, Y: Integer);
begin
  if LWIsMainThread then
    GRealCustomForm.PaintTo(AWinControl, ADC, X, Y)
  else
    inherited PaintTo(AWinControl, ADC, X, Y);
end;

class procedure TLWWSCustomForm.Repaint(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomForm.Repaint(AWinControl)
  else
    inherited Repaint(AWinControl);
end;

class procedure TLWWSCustomForm.ShowHide(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomForm.ShowHide(AWinControl)
  else
    inherited ShowHide(AWinControl);
end;

class procedure TLWWSCustomForm.ScrollBy(const AWinControl: TWinControl; DeltaX, DeltaY: integer);
begin
  if LWIsMainThread then
    GRealCustomForm.ScrollBy(AWinControl, DeltaX, DeltaY)
  else
    inherited ScrollBy(AWinControl, DeltaX, DeltaY);
end;

class procedure TLWWSCustomForm.AddControl(const AControl: TControl);
begin
  if LWIsMainThread then
    GRealCustomForm.AddControl(AControl)
  else
    inherited AddControl(AControl);
end;

class function TLWWSCustomForm.GetConstraints(const AControl: TControl; const AConstraints: TObject): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.GetConstraints(AControl, AConstraints)
  else
    Result := inherited GetConstraints(AControl, AConstraints);
end;

class function TLWWSCustomForm.GetDefaultColor(const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.GetDefaultColor(AControl, ADefaultColorType)
  else
    Result := inherited GetDefaultColor(AControl, ADefaultColorType);
end;

class procedure TLWWSCustomForm.ConstraintWidth(const AControl: TControl; const AConstraints: TObject; var aWidth: integer);
begin
  if LWIsMainThread then
    GRealCustomForm.ConstraintWidth(AControl, AConstraints, aWidth)
  else
    inherited ConstraintWidth(AControl, AConstraints, aWidth);
end;

class procedure TLWWSCustomForm.ConstraintHeight(const AControl: TControl; const AConstraints: TObject; var aHeight: integer);
begin
  if LWIsMainThread then
    GRealCustomForm.ConstraintHeight(AControl, AConstraints, aHeight)
  else
    inherited ConstraintHeight(AControl, AConstraints, aHeight);
end;

class function TLWWSCustomForm.GetCanvasScaleFactor(const AControl: TControl): Double;
begin
  if LWIsMainThread then
    Result := GRealCustomForm.GetCanvasScaleFactor(AControl)
  else
    Result := inherited GetCanvasScaleFactor(AControl);
end;

{ TLWWSCustomMemo：主线程走真实类，工作线程走空基类（= nogui 行为） }
class procedure TLWWSCustomMemo.AppendText(const ACustomMemo: TCustomMemo; const AText: string);
begin
  if LWIsMainThread then
    GRealCustomMemo.AppendText(ACustomMemo, AText)
  else
    inherited AppendText(ACustomMemo, AText);
end;

class function TLWWSCustomMemo.GetStrings(const ACustomMemo: TCustomMemo): TStrings;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetStrings(ACustomMemo)
  else
    Result := inherited GetStrings(ACustomMemo);
end;

class procedure TLWWSCustomMemo.FreeStrings(var AStrings: TStrings);
begin
  if LWIsMainThread then
    GRealCustomMemo.FreeStrings(AStrings)
  else
    inherited FreeStrings(AStrings);
end;

class procedure TLWWSCustomMemo.SetScrollbars(const ACustomMemo: TCustomMemo; const NewScrollbars: TScrollStyle);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetScrollbars(ACustomMemo, NewScrollbars)
  else
    inherited SetScrollbars(ACustomMemo, NewScrollbars);
end;

class procedure TLWWSCustomMemo.SetWantTabs(const ACustomMemo: TCustomMemo; const NewWantTabs: boolean);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetWantTabs(ACustomMemo, NewWantTabs)
  else
    inherited SetWantTabs(ACustomMemo, NewWantTabs);
end;

class procedure TLWWSCustomMemo.SetWantReturns(const ACustomMemo: TCustomMemo; const NewWantReturns: boolean);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetWantReturns(ACustomMemo, NewWantReturns)
  else
    inherited SetWantReturns(ACustomMemo, NewWantReturns);
end;

class procedure TLWWSCustomMemo.SetWordWrap(const ACustomMemo: TCustomMemo; const NewWordWrap: boolean);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetWordWrap(ACustomMemo, NewWordWrap)
  else
    inherited SetWordWrap(ACustomMemo, NewWordWrap);
end;

class function TLWWSCustomMemo.GetCanUndo(const ACustomEdit: TCustomEdit): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetCanUndo(ACustomEdit)
  else
    Result := inherited GetCanUndo(ACustomEdit);
end;

class function TLWWSCustomMemo.GetCaretPos(const ACustomEdit: TCustomEdit): TPoint;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetCaretPos(ACustomEdit)
  else
    Result := inherited GetCaretPos(ACustomEdit);
end;

class function TLWWSCustomMemo.GetSelStart(const ACustomEdit: TCustomEdit): integer;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetSelStart(ACustomEdit)
  else
    Result := inherited GetSelStart(ACustomEdit);
end;

class function TLWWSCustomMemo.GetSelLength(const ACustomEdit: TCustomEdit): integer;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetSelLength(ACustomEdit)
  else
    Result := inherited GetSelLength(ACustomEdit);
end;

class procedure TLWWSCustomMemo.SetAlignment(const ACustomEdit: TCustomEdit; const AAlignment: TAlignment);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetAlignment(ACustomEdit, AAlignment)
  else
    inherited SetAlignment(ACustomEdit, AAlignment);
end;

class procedure TLWWSCustomMemo.SetCaretPos(const ACustomEdit: TCustomEdit; const NewPos: TPoint);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetCaretPos(ACustomEdit, NewPos)
  else
    inherited SetCaretPos(ACustomEdit, NewPos);
end;

class procedure TLWWSCustomMemo.SetCharCase(const ACustomEdit: TCustomEdit; NewCase: TEditCharCase);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetCharCase(ACustomEdit, NewCase)
  else
    inherited SetCharCase(ACustomEdit, NewCase);
end;

class procedure TLWWSCustomMemo.SetEchoMode(const ACustomEdit: TCustomEdit; NewMode: TEchoMode);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetEchoMode(ACustomEdit, NewMode)
  else
    inherited SetEchoMode(ACustomEdit, NewMode);
end;

class procedure TLWWSCustomMemo.SetHideSelection(const ACustomEdit: TCustomEdit; NewHideSelection: Boolean);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetHideSelection(ACustomEdit, NewHideSelection)
  else
    inherited SetHideSelection(ACustomEdit, NewHideSelection);
end;

class procedure TLWWSCustomMemo.SetMaxLength(const ACustomEdit: TCustomEdit; NewLength: integer);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetMaxLength(ACustomEdit, NewLength)
  else
    inherited SetMaxLength(ACustomEdit, NewLength);
end;

class procedure TLWWSCustomMemo.SetNumbersOnly(const ACustomEdit: TCustomEdit; NewNumbersOnly: Boolean);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetNumbersOnly(ACustomEdit, NewNumbersOnly)
  else
    inherited SetNumbersOnly(ACustomEdit, NewNumbersOnly);
end;

class procedure TLWWSCustomMemo.SetPasswordChar(const ACustomEdit: TCustomEdit; NewChar: char);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetPasswordChar(ACustomEdit, NewChar)
  else
    inherited SetPasswordChar(ACustomEdit, NewChar);
end;

class procedure TLWWSCustomMemo.SetReadOnly(const ACustomEdit: TCustomEdit; NewReadOnly: boolean);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetReadOnly(ACustomEdit, NewReadOnly)
  else
    inherited SetReadOnly(ACustomEdit, NewReadOnly);
end;

class procedure TLWWSCustomMemo.SetSelStart(const ACustomEdit: TCustomEdit; NewStart: integer);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetSelStart(ACustomEdit, NewStart)
  else
    inherited SetSelStart(ACustomEdit, NewStart);
end;

class procedure TLWWSCustomMemo.SetSelLength(const ACustomEdit: TCustomEdit; NewLength: integer);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetSelLength(ACustomEdit, NewLength)
  else
    inherited SetSelLength(ACustomEdit, NewLength);
end;

class procedure TLWWSCustomMemo.SetSelText(const ACustomEdit: TCustomEdit; const NewSelText: string);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetSelText(ACustomEdit, NewSelText)
  else
    inherited SetSelText(ACustomEdit, NewSelText);
end;

class procedure TLWWSCustomMemo.SetTextHint(const ACustomEdit: TCustomEdit; const ATextHint: string);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetTextHint(ACustomEdit, ATextHint)
  else
    inherited SetTextHint(ACustomEdit, ATextHint);
end;

class procedure TLWWSCustomMemo.Cut(const ACustomEdit: TCustomEdit);
begin
  if LWIsMainThread then
    GRealCustomMemo.Cut(ACustomEdit)
  else
    inherited Cut(ACustomEdit);
end;

class procedure TLWWSCustomMemo.Copy(const ACustomEdit: TCustomEdit);
begin
  if LWIsMainThread then
    GRealCustomMemo.Copy(ACustomEdit)
  else
    inherited Copy(ACustomEdit);
end;

class procedure TLWWSCustomMemo.Paste(const ACustomEdit: TCustomEdit);
begin
  if LWIsMainThread then
    GRealCustomMemo.Paste(ACustomEdit)
  else
    inherited Paste(ACustomEdit);
end;

class procedure TLWWSCustomMemo.Undo(const ACustomEdit: TCustomEdit);
begin
  if LWIsMainThread then
    GRealCustomMemo.Undo(ACustomEdit)
  else
    inherited Undo(ACustomEdit);
end;

class function TLWWSCustomMemo.CanFocus(const AWincontrol: TWinControl): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.CanFocus(AWincontrol)
  else
    Result := inherited CanFocus(AWincontrol);
end;

class function TLWWSCustomMemo.GetClientBounds(const AWincontrol: TWinControl; var ARect: TRect): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetClientBounds(AWincontrol, ARect)
  else
    Result := inherited GetClientBounds(AWincontrol, ARect);
end;

class function TLWWSCustomMemo.GetClientRect(const AWincontrol: TWinControl; var ARect: TRect): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetClientRect(AWincontrol, ARect)
  else
    Result := inherited GetClientRect(AWincontrol, ARect);
end;

class procedure TLWWSCustomMemo.GetPreferredSize(const AWinControl: TWinControl; var PreferredWidth, PreferredHeight: integer; WithThemeSpace: Boolean);
begin
  if LWIsMainThread then
    GRealCustomMemo.GetPreferredSize(AWinControl, PreferredWidth, PreferredHeight, WithThemeSpace)
  else
    inherited GetPreferredSize(AWinControl, PreferredWidth, PreferredHeight, WithThemeSpace);
end;

class function TLWWSCustomMemo.GetDefaultClientRect(const AWinControl: TWinControl; const aLeft, aTop, aWidth, aHeight: integer; var aClientRect: TRect): boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetDefaultClientRect(AWinControl, aLeft, aTop, aWidth, aHeight, aClientRect)
  else
    Result := inherited GetDefaultClientRect(AWinControl, aLeft, aTop, aWidth, aHeight, aClientRect);
end;

class function TLWWSCustomMemo.GetDesignInteractive(const AWinControl: TWinControl; AClientPos: TPoint): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetDesignInteractive(AWinControl, AClientPos)
  else
    Result := inherited GetDesignInteractive(AWinControl, AClientPos);
end;

class function TLWWSCustomMemo.GetDoubleBuffered(const AWinControl: TWinControl): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetDoubleBuffered(AWinControl)
  else
    Result := inherited GetDoubleBuffered(AWinControl);
end;

class function TLWWSCustomMemo.GetText(const AWinControl: TWinControl; var AText: String): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetText(AWinControl, AText)
  else
    Result := inherited GetText(AWinControl, AText);
end;

class function TLWWSCustomMemo.GetTextLen(const AWinControl: TWinControl; var ALength: Integer): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetTextLen(AWinControl, ALength)
  else
    Result := inherited GetTextLen(AWinControl, ALength);
end;

class procedure TLWWSCustomMemo.SetBiDiMode(const AWinControl: TWinControl; UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar : Boolean);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetBiDiMode(AWinControl, UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar)
  else
    inherited SetBiDiMode(AWinControl, UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar);
end;

class procedure TLWWSCustomMemo.SetBorderStyle(const AWinControl: TWinControl; const ABorderStyle: TBorderStyle);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetBorderStyle(AWinControl, ABorderStyle)
  else
    inherited SetBorderStyle(AWinControl, ABorderStyle);
end;

class procedure TLWWSCustomMemo.SetBounds(const AWinControl: TWinControl; const ALeft, ATop, AWidth, AHeight: Integer);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetBounds(AWinControl, ALeft, ATop, AWidth, AHeight)
  else
    inherited SetBounds(AWinControl, ALeft, ATop, AWidth, AHeight);
end;

class procedure TLWWSCustomMemo.SetColor(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetColor(AWinControl)
  else
    inherited SetColor(AWinControl);
end;

class procedure TLWWSCustomMemo.SetChildZPosition(const AWinControl, AChild: TWinControl; const AOldPos, ANewPos: Integer; const AChildren: TFPList);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetChildZPosition(AWinControl, AChild, AOldPos, ANewPos, AChildren)
  else
    inherited SetChildZPosition(AWinControl, AChild, AOldPos, ANewPos, AChildren);
end;

class procedure TLWWSCustomMemo.SetFont(const AWinControl: TWinControl; const AFont: TFont);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetFont(AWinControl, AFont)
  else
    inherited SetFont(AWinControl, AFont);
end;

class procedure TLWWSCustomMemo.SetPos(const AWinControl: TWinControl; const ALeft, ATop: Integer);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetPos(AWinControl, ALeft, ATop)
  else
    inherited SetPos(AWinControl, ALeft, ATop);
end;

class procedure TLWWSCustomMemo.SetSize(const AWinControl: TWinControl; const AWidth, AHeight: Integer);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetSize(AWinControl, AWidth, AHeight)
  else
    inherited SetSize(AWinControl, AWidth, AHeight);
end;

class procedure TLWWSCustomMemo.SetText(const AWinControl: TWinControl; const AText: String);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetText(AWinControl, AText)
  else
    inherited SetText(AWinControl, AText);
end;

class procedure TLWWSCustomMemo.SetCursor(const AWinControl: TWinControl; const ACursor: HCursor);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetCursor(AWinControl, ACursor)
  else
    inherited SetCursor(AWinControl, ACursor);
end;

class procedure TLWWSCustomMemo.SetShape(const AWinControl: TWinControl; const AShape: HBITMAP);
begin
  if LWIsMainThread then
    GRealCustomMemo.SetShape(AWinControl, AShape)
  else
    inherited SetShape(AWinControl, AShape);
end;

class procedure TLWWSCustomMemo.AdaptBounds(const AWinControl: TWinControl; var Left, Top, Width, Height: integer; var SuppressMove: boolean);
begin
  if LWIsMainThread then
    GRealCustomMemo.AdaptBounds(AWinControl, Left, Top, Width, Height, SuppressMove)
  else
    inherited AdaptBounds(AWinControl, Left, Top, Width, Height, SuppressMove);
end;

class procedure TLWWSCustomMemo.ConstraintsChange(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomMemo.ConstraintsChange(AWinControl)
  else
    inherited ConstraintsChange(AWinControl);
end;

class function TLWWSCustomMemo.CreateHandle(const AWinControl: TWinControl; const AParams: TCreateParams): TLCLHandle;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.CreateHandle(AWinControl, AParams)
  else
    Result := inherited CreateHandle(AWinControl, AParams);
end;

class procedure TLWWSCustomMemo.DestroyHandle(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomMemo.DestroyHandle(AWinControl)
  else
    inherited DestroyHandle(AWinControl);
end;

class procedure TLWWSCustomMemo.Invalidate(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomMemo.Invalidate(AWinControl)
  else
    inherited Invalidate(AWinControl);
end;

class procedure TLWWSCustomMemo.PaintTo(const AWinControl: TWinControl; ADC: HDC; X, Y: Integer);
begin
  if LWIsMainThread then
    GRealCustomMemo.PaintTo(AWinControl, ADC, X, Y)
  else
    inherited PaintTo(AWinControl, ADC, X, Y);
end;

class procedure TLWWSCustomMemo.Repaint(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomMemo.Repaint(AWinControl)
  else
    inherited Repaint(AWinControl);
end;

class procedure TLWWSCustomMemo.ShowHide(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomMemo.ShowHide(AWinControl)
  else
    inherited ShowHide(AWinControl);
end;

class procedure TLWWSCustomMemo.ScrollBy(const AWinControl: TWinControl; DeltaX, DeltaY: integer);
begin
  if LWIsMainThread then
    GRealCustomMemo.ScrollBy(AWinControl, DeltaX, DeltaY)
  else
    inherited ScrollBy(AWinControl, DeltaX, DeltaY);
end;

class procedure TLWWSCustomMemo.AddControl(const AControl: TControl);
begin
  if LWIsMainThread then
    GRealCustomMemo.AddControl(AControl)
  else
    inherited AddControl(AControl);
end;

class function TLWWSCustomMemo.GetConstraints(const AControl: TControl; const AConstraints: TObject): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetConstraints(AControl, AConstraints)
  else
    Result := inherited GetConstraints(AControl, AConstraints);
end;

class function TLWWSCustomMemo.GetDefaultColor(const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetDefaultColor(AControl, ADefaultColorType)
  else
    Result := inherited GetDefaultColor(AControl, ADefaultColorType);
end;

class procedure TLWWSCustomMemo.ConstraintWidth(const AControl: TControl; const AConstraints: TObject; var aWidth: integer);
begin
  if LWIsMainThread then
    GRealCustomMemo.ConstraintWidth(AControl, AConstraints, aWidth)
  else
    inherited ConstraintWidth(AControl, AConstraints, aWidth);
end;

class procedure TLWWSCustomMemo.ConstraintHeight(const AControl: TControl; const AConstraints: TObject; var aHeight: integer);
begin
  if LWIsMainThread then
    GRealCustomMemo.ConstraintHeight(AControl, AConstraints, aHeight)
  else
    inherited ConstraintHeight(AControl, AConstraints, aHeight);
end;

class function TLWWSCustomMemo.GetCanvasScaleFactor(const AControl: TControl): Double;
begin
  if LWIsMainThread then
    Result := GRealCustomMemo.GetCanvasScaleFactor(AControl)
  else
    Result := inherited GetCanvasScaleFactor(AControl);
end;

{ TLWWSCustomButton：主线程走真实类，工作线程走空基类（= nogui 行为） }
class procedure TLWWSCustomButton.SetDefault(const AButton: TCustomButton; ADefault: Boolean);
begin
  if LWIsMainThread then
    GRealCustomButton.SetDefault(AButton, ADefault)
  else
    inherited SetDefault(AButton, ADefault);
end;

class procedure TLWWSCustomButton.SetShortCut(const AButton: TCustomButton; const ShortCutK1, ShortCutK2: TShortCut);
begin
  if LWIsMainThread then
    GRealCustomButton.SetShortCut(AButton, ShortCutK1, ShortCutK2)
  else
    inherited SetShortCut(AButton, ShortCutK1, ShortCutK2);
end;

class function TLWWSCustomButton.CanFocus(const AWincontrol: TWinControl): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomButton.CanFocus(AWincontrol)
  else
    Result := inherited CanFocus(AWincontrol);
end;

class function TLWWSCustomButton.GetClientBounds(const AWincontrol: TWinControl; var ARect: TRect): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomButton.GetClientBounds(AWincontrol, ARect)
  else
    Result := inherited GetClientBounds(AWincontrol, ARect);
end;

class function TLWWSCustomButton.GetClientRect(const AWincontrol: TWinControl; var ARect: TRect): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomButton.GetClientRect(AWincontrol, ARect)
  else
    Result := inherited GetClientRect(AWincontrol, ARect);
end;

class procedure TLWWSCustomButton.GetPreferredSize(const AWinControl: TWinControl; var PreferredWidth, PreferredHeight: integer; WithThemeSpace: Boolean);
begin
  if LWIsMainThread then
    GRealCustomButton.GetPreferredSize(AWinControl, PreferredWidth, PreferredHeight, WithThemeSpace)
  else
    inherited GetPreferredSize(AWinControl, PreferredWidth, PreferredHeight, WithThemeSpace);
end;

class function TLWWSCustomButton.GetDefaultClientRect(const AWinControl: TWinControl; const aLeft, aTop, aWidth, aHeight: integer; var aClientRect: TRect): boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomButton.GetDefaultClientRect(AWinControl, aLeft, aTop, aWidth, aHeight, aClientRect)
  else
    Result := inherited GetDefaultClientRect(AWinControl, aLeft, aTop, aWidth, aHeight, aClientRect);
end;

class function TLWWSCustomButton.GetDesignInteractive(const AWinControl: TWinControl; AClientPos: TPoint): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomButton.GetDesignInteractive(AWinControl, AClientPos)
  else
    Result := inherited GetDesignInteractive(AWinControl, AClientPos);
end;

class function TLWWSCustomButton.GetDoubleBuffered(const AWinControl: TWinControl): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomButton.GetDoubleBuffered(AWinControl)
  else
    Result := inherited GetDoubleBuffered(AWinControl);
end;

class function TLWWSCustomButton.GetText(const AWinControl: TWinControl; var AText: String): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomButton.GetText(AWinControl, AText)
  else
    Result := inherited GetText(AWinControl, AText);
end;

class function TLWWSCustomButton.GetTextLen(const AWinControl: TWinControl; var ALength: Integer): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomButton.GetTextLen(AWinControl, ALength)
  else
    Result := inherited GetTextLen(AWinControl, ALength);
end;

class procedure TLWWSCustomButton.SetBiDiMode(const AWinControl: TWinControl; UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar : Boolean);
begin
  if LWIsMainThread then
    GRealCustomButton.SetBiDiMode(AWinControl, UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar)
  else
    inherited SetBiDiMode(AWinControl, UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar);
end;

class procedure TLWWSCustomButton.SetBorderStyle(const AWinControl: TWinControl; const ABorderStyle: TBorderStyle);
begin
  if LWIsMainThread then
    GRealCustomButton.SetBorderStyle(AWinControl, ABorderStyle)
  else
    inherited SetBorderStyle(AWinControl, ABorderStyle);
end;

class procedure TLWWSCustomButton.SetBounds(const AWinControl: TWinControl; const ALeft, ATop, AWidth, AHeight: Integer);
begin
  if LWIsMainThread then
    GRealCustomButton.SetBounds(AWinControl, ALeft, ATop, AWidth, AHeight)
  else
    inherited SetBounds(AWinControl, ALeft, ATop, AWidth, AHeight);
end;

class procedure TLWWSCustomButton.SetColor(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomButton.SetColor(AWinControl)
  else
    inherited SetColor(AWinControl);
end;

class procedure TLWWSCustomButton.SetChildZPosition(const AWinControl, AChild: TWinControl; const AOldPos, ANewPos: Integer; const AChildren: TFPList);
begin
  if LWIsMainThread then
    GRealCustomButton.SetChildZPosition(AWinControl, AChild, AOldPos, ANewPos, AChildren)
  else
    inherited SetChildZPosition(AWinControl, AChild, AOldPos, ANewPos, AChildren);
end;

class procedure TLWWSCustomButton.SetFont(const AWinControl: TWinControl; const AFont: TFont);
begin
  if LWIsMainThread then
    GRealCustomButton.SetFont(AWinControl, AFont)
  else
    inherited SetFont(AWinControl, AFont);
end;

class procedure TLWWSCustomButton.SetPos(const AWinControl: TWinControl; const ALeft, ATop: Integer);
begin
  if LWIsMainThread then
    GRealCustomButton.SetPos(AWinControl, ALeft, ATop)
  else
    inherited SetPos(AWinControl, ALeft, ATop);
end;

class procedure TLWWSCustomButton.SetSize(const AWinControl: TWinControl; const AWidth, AHeight: Integer);
begin
  if LWIsMainThread then
    GRealCustomButton.SetSize(AWinControl, AWidth, AHeight)
  else
    inherited SetSize(AWinControl, AWidth, AHeight);
end;

class procedure TLWWSCustomButton.SetText(const AWinControl: TWinControl; const AText: String);
begin
  if LWIsMainThread then
    GRealCustomButton.SetText(AWinControl, AText)
  else
    inherited SetText(AWinControl, AText);
end;

class procedure TLWWSCustomButton.SetCursor(const AWinControl: TWinControl; const ACursor: HCursor);
begin
  if LWIsMainThread then
    GRealCustomButton.SetCursor(AWinControl, ACursor)
  else
    inherited SetCursor(AWinControl, ACursor);
end;

class procedure TLWWSCustomButton.SetShape(const AWinControl: TWinControl; const AShape: HBITMAP);
begin
  if LWIsMainThread then
    GRealCustomButton.SetShape(AWinControl, AShape)
  else
    inherited SetShape(AWinControl, AShape);
end;

class procedure TLWWSCustomButton.AdaptBounds(const AWinControl: TWinControl; var Left, Top, Width, Height: integer; var SuppressMove: boolean);
begin
  if LWIsMainThread then
    GRealCustomButton.AdaptBounds(AWinControl, Left, Top, Width, Height, SuppressMove)
  else
    inherited AdaptBounds(AWinControl, Left, Top, Width, Height, SuppressMove);
end;

class procedure TLWWSCustomButton.ConstraintsChange(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomButton.ConstraintsChange(AWinControl)
  else
    inherited ConstraintsChange(AWinControl);
end;

class function TLWWSCustomButton.CreateHandle(const AWinControl: TWinControl; const AParams: TCreateParams): TLCLHandle;
begin
  if LWIsMainThread then
    Result := GRealCustomButton.CreateHandle(AWinControl, AParams)
  else
    Result := inherited CreateHandle(AWinControl, AParams);
end;

class procedure TLWWSCustomButton.DestroyHandle(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomButton.DestroyHandle(AWinControl)
  else
    inherited DestroyHandle(AWinControl);
end;

class procedure TLWWSCustomButton.Invalidate(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomButton.Invalidate(AWinControl)
  else
    inherited Invalidate(AWinControl);
end;

class procedure TLWWSCustomButton.PaintTo(const AWinControl: TWinControl; ADC: HDC; X, Y: Integer);
begin
  if LWIsMainThread then
    GRealCustomButton.PaintTo(AWinControl, ADC, X, Y)
  else
    inherited PaintTo(AWinControl, ADC, X, Y);
end;

class procedure TLWWSCustomButton.Repaint(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomButton.Repaint(AWinControl)
  else
    inherited Repaint(AWinControl);
end;

class procedure TLWWSCustomButton.ShowHide(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealCustomButton.ShowHide(AWinControl)
  else
    inherited ShowHide(AWinControl);
end;

class procedure TLWWSCustomButton.ScrollBy(const AWinControl: TWinControl; DeltaX, DeltaY: integer);
begin
  if LWIsMainThread then
    GRealCustomButton.ScrollBy(AWinControl, DeltaX, DeltaY)
  else
    inherited ScrollBy(AWinControl, DeltaX, DeltaY);
end;

class procedure TLWWSCustomButton.AddControl(const AControl: TControl);
begin
  if LWIsMainThread then
    GRealCustomButton.AddControl(AControl)
  else
    inherited AddControl(AControl);
end;

class function TLWWSCustomButton.GetConstraints(const AControl: TControl; const AConstraints: TObject): Boolean;
begin
  if LWIsMainThread then
    Result := GRealCustomButton.GetConstraints(AControl, AConstraints)
  else
    Result := inherited GetConstraints(AControl, AConstraints);
end;

class function TLWWSCustomButton.GetDefaultColor(const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor;
begin
  if LWIsMainThread then
    Result := GRealCustomButton.GetDefaultColor(AControl, ADefaultColorType)
  else
    Result := inherited GetDefaultColor(AControl, ADefaultColorType);
end;

class procedure TLWWSCustomButton.ConstraintWidth(const AControl: TControl; const AConstraints: TObject; var aWidth: integer);
begin
  if LWIsMainThread then
    GRealCustomButton.ConstraintWidth(AControl, AConstraints, aWidth)
  else
    inherited ConstraintWidth(AControl, AConstraints, aWidth);
end;

class procedure TLWWSCustomButton.ConstraintHeight(const AControl: TControl; const AConstraints: TObject; var aHeight: integer);
begin
  if LWIsMainThread then
    GRealCustomButton.ConstraintHeight(AControl, AConstraints, aHeight)
  else
    inherited ConstraintHeight(AControl, AConstraints, aHeight);
end;

class function TLWWSCustomButton.GetCanvasScaleFactor(const AControl: TControl): Double;
begin
  if LWIsMainThread then
    Result := GRealCustomButton.GetCanvasScaleFactor(AControl)
  else
    Result := inherited GetCanvasScaleFactor(AControl);
end;

{ TLWWSStatusBar：主线程走真实类，工作线程走空基类（= nogui 行为） }
class procedure TLWWSStatusBar.PanelUpdate(const AStatusBar: TStatusBar; PanelIndex: integer);
begin
  if LWIsMainThread then
    GRealStatusBar.PanelUpdate(AStatusBar, PanelIndex)
  else
    inherited PanelUpdate(AStatusBar, PanelIndex);
end;

class procedure TLWWSStatusBar.SetPanelText(const AStatusBar: TStatusBar; PanelIndex: integer);
begin
  if LWIsMainThread then
    GRealStatusBar.SetPanelText(AStatusBar, PanelIndex)
  else
    inherited SetPanelText(AStatusBar, PanelIndex);
end;

class procedure TLWWSStatusBar.SetSizeGrip(const AStatusBar: TStatusBar; SizeGrip: Boolean);
begin
  if LWIsMainThread then
    GRealStatusBar.SetSizeGrip(AStatusBar, SizeGrip)
  else
    inherited SetSizeGrip(AStatusBar, SizeGrip);
end;

class procedure TLWWSStatusBar.Update(const AStatusBar: TStatusBar);
begin
  if LWIsMainThread then
    GRealStatusBar.Update(AStatusBar)
  else
    inherited Update(AStatusBar);
end;

class function TLWWSStatusBar.CanFocus(const AWincontrol: TWinControl): Boolean;
begin
  if LWIsMainThread then
    Result := GRealStatusBar.CanFocus(AWincontrol)
  else
    Result := inherited CanFocus(AWincontrol);
end;

class function TLWWSStatusBar.GetClientBounds(const AWincontrol: TWinControl; var ARect: TRect): Boolean;
begin
  if LWIsMainThread then
    Result := GRealStatusBar.GetClientBounds(AWincontrol, ARect)
  else
    Result := inherited GetClientBounds(AWincontrol, ARect);
end;

class function TLWWSStatusBar.GetClientRect(const AWincontrol: TWinControl; var ARect: TRect): Boolean;
begin
  if LWIsMainThread then
    Result := GRealStatusBar.GetClientRect(AWincontrol, ARect)
  else
    Result := inherited GetClientRect(AWincontrol, ARect);
end;

class procedure TLWWSStatusBar.GetPreferredSize(const AWinControl: TWinControl; var PreferredWidth, PreferredHeight: integer; WithThemeSpace: Boolean);
begin
  if LWIsMainThread then
    GRealStatusBar.GetPreferredSize(AWinControl, PreferredWidth, PreferredHeight, WithThemeSpace)
  else
    inherited GetPreferredSize(AWinControl, PreferredWidth, PreferredHeight, WithThemeSpace);
end;

class function TLWWSStatusBar.GetDefaultClientRect(const AWinControl: TWinControl; const aLeft, aTop, aWidth, aHeight: integer; var aClientRect: TRect): boolean;
begin
  if LWIsMainThread then
    Result := GRealStatusBar.GetDefaultClientRect(AWinControl, aLeft, aTop, aWidth, aHeight, aClientRect)
  else
    Result := inherited GetDefaultClientRect(AWinControl, aLeft, aTop, aWidth, aHeight, aClientRect);
end;

class function TLWWSStatusBar.GetDesignInteractive(const AWinControl: TWinControl; AClientPos: TPoint): Boolean;
begin
  if LWIsMainThread then
    Result := GRealStatusBar.GetDesignInteractive(AWinControl, AClientPos)
  else
    Result := inherited GetDesignInteractive(AWinControl, AClientPos);
end;

class function TLWWSStatusBar.GetDoubleBuffered(const AWinControl: TWinControl): Boolean;
begin
  if LWIsMainThread then
    Result := GRealStatusBar.GetDoubleBuffered(AWinControl)
  else
    Result := inherited GetDoubleBuffered(AWinControl);
end;

class function TLWWSStatusBar.GetText(const AWinControl: TWinControl; var AText: String): Boolean;
begin
  if LWIsMainThread then
    Result := GRealStatusBar.GetText(AWinControl, AText)
  else
    Result := inherited GetText(AWinControl, AText);
end;

class function TLWWSStatusBar.GetTextLen(const AWinControl: TWinControl; var ALength: Integer): Boolean;
begin
  if LWIsMainThread then
    Result := GRealStatusBar.GetTextLen(AWinControl, ALength)
  else
    Result := inherited GetTextLen(AWinControl, ALength);
end;

class procedure TLWWSStatusBar.SetBiDiMode(const AWinControl: TWinControl; UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar : Boolean);
begin
  if LWIsMainThread then
    GRealStatusBar.SetBiDiMode(AWinControl, UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar)
  else
    inherited SetBiDiMode(AWinControl, UseRightToLeftAlign, UseRightToLeftReading, UseRightToLeftScrollBar);
end;

class procedure TLWWSStatusBar.SetBorderStyle(const AWinControl: TWinControl; const ABorderStyle: TBorderStyle);
begin
  if LWIsMainThread then
    GRealStatusBar.SetBorderStyle(AWinControl, ABorderStyle)
  else
    inherited SetBorderStyle(AWinControl, ABorderStyle);
end;

class procedure TLWWSStatusBar.SetBounds(const AWinControl: TWinControl; const ALeft, ATop, AWidth, AHeight: Integer);
begin
  if LWIsMainThread then
    GRealStatusBar.SetBounds(AWinControl, ALeft, ATop, AWidth, AHeight)
  else
    inherited SetBounds(AWinControl, ALeft, ATop, AWidth, AHeight);
end;

class procedure TLWWSStatusBar.SetColor(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealStatusBar.SetColor(AWinControl)
  else
    inherited SetColor(AWinControl);
end;

class procedure TLWWSStatusBar.SetChildZPosition(const AWinControl, AChild: TWinControl; const AOldPos, ANewPos: Integer; const AChildren: TFPList);
begin
  if LWIsMainThread then
    GRealStatusBar.SetChildZPosition(AWinControl, AChild, AOldPos, ANewPos, AChildren)
  else
    inherited SetChildZPosition(AWinControl, AChild, AOldPos, ANewPos, AChildren);
end;

class procedure TLWWSStatusBar.SetFont(const AWinControl: TWinControl; const AFont: TFont);
begin
  if LWIsMainThread then
    GRealStatusBar.SetFont(AWinControl, AFont)
  else
    inherited SetFont(AWinControl, AFont);
end;

class procedure TLWWSStatusBar.SetPos(const AWinControl: TWinControl; const ALeft, ATop: Integer);
begin
  if LWIsMainThread then
    GRealStatusBar.SetPos(AWinControl, ALeft, ATop)
  else
    inherited SetPos(AWinControl, ALeft, ATop);
end;

class procedure TLWWSStatusBar.SetSize(const AWinControl: TWinControl; const AWidth, AHeight: Integer);
begin
  if LWIsMainThread then
    GRealStatusBar.SetSize(AWinControl, AWidth, AHeight)
  else
    inherited SetSize(AWinControl, AWidth, AHeight);
end;

class procedure TLWWSStatusBar.SetText(const AWinControl: TWinControl; const AText: String);
begin
  if LWIsMainThread then
    GRealStatusBar.SetText(AWinControl, AText)
  else
    inherited SetText(AWinControl, AText);
end;

class procedure TLWWSStatusBar.SetCursor(const AWinControl: TWinControl; const ACursor: HCursor);
begin
  if LWIsMainThread then
    GRealStatusBar.SetCursor(AWinControl, ACursor)
  else
    inherited SetCursor(AWinControl, ACursor);
end;

class procedure TLWWSStatusBar.SetShape(const AWinControl: TWinControl; const AShape: HBITMAP);
begin
  if LWIsMainThread then
    GRealStatusBar.SetShape(AWinControl, AShape)
  else
    inherited SetShape(AWinControl, AShape);
end;

class procedure TLWWSStatusBar.AdaptBounds(const AWinControl: TWinControl; var Left, Top, Width, Height: integer; var SuppressMove: boolean);
begin
  if LWIsMainThread then
    GRealStatusBar.AdaptBounds(AWinControl, Left, Top, Width, Height, SuppressMove)
  else
    inherited AdaptBounds(AWinControl, Left, Top, Width, Height, SuppressMove);
end;

class procedure TLWWSStatusBar.ConstraintsChange(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealStatusBar.ConstraintsChange(AWinControl)
  else
    inherited ConstraintsChange(AWinControl);
end;

class function TLWWSStatusBar.CreateHandle(const AWinControl: TWinControl; const AParams: TCreateParams): TLCLHandle;
begin
  if LWIsMainThread then
    Result := GRealStatusBar.CreateHandle(AWinControl, AParams)
  else
    Result := inherited CreateHandle(AWinControl, AParams);
end;

class procedure TLWWSStatusBar.DestroyHandle(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealStatusBar.DestroyHandle(AWinControl)
  else
    inherited DestroyHandle(AWinControl);
end;

class procedure TLWWSStatusBar.Invalidate(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealStatusBar.Invalidate(AWinControl)
  else
    inherited Invalidate(AWinControl);
end;

class procedure TLWWSStatusBar.PaintTo(const AWinControl: TWinControl; ADC: HDC; X, Y: Integer);
begin
  if LWIsMainThread then
    GRealStatusBar.PaintTo(AWinControl, ADC, X, Y)
  else
    inherited PaintTo(AWinControl, ADC, X, Y);
end;

class procedure TLWWSStatusBar.Repaint(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealStatusBar.Repaint(AWinControl)
  else
    inherited Repaint(AWinControl);
end;

class procedure TLWWSStatusBar.ShowHide(const AWinControl: TWinControl);
begin
  if LWIsMainThread then
    GRealStatusBar.ShowHide(AWinControl)
  else
    inherited ShowHide(AWinControl);
end;

class procedure TLWWSStatusBar.ScrollBy(const AWinControl: TWinControl; DeltaX, DeltaY: integer);
begin
  if LWIsMainThread then
    GRealStatusBar.ScrollBy(AWinControl, DeltaX, DeltaY)
  else
    inherited ScrollBy(AWinControl, DeltaX, DeltaY);
end;

class procedure TLWWSStatusBar.AddControl(const AControl: TControl);
begin
  if LWIsMainThread then
    GRealStatusBar.AddControl(AControl)
  else
    inherited AddControl(AControl);
end;

class function TLWWSStatusBar.GetConstraints(const AControl: TControl; const AConstraints: TObject): Boolean;
begin
  if LWIsMainThread then
    Result := GRealStatusBar.GetConstraints(AControl, AConstraints)
  else
    Result := inherited GetConstraints(AControl, AConstraints);
end;

class function TLWWSStatusBar.GetDefaultColor(const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor;
begin
  if LWIsMainThread then
    Result := GRealStatusBar.GetDefaultColor(AControl, ADefaultColorType)
  else
    Result := inherited GetDefaultColor(AControl, ADefaultColorType);
end;

class procedure TLWWSStatusBar.ConstraintWidth(const AControl: TControl; const AConstraints: TObject; var aWidth: integer);
begin
  if LWIsMainThread then
    GRealStatusBar.ConstraintWidth(AControl, AConstraints, aWidth)
  else
    inherited ConstraintWidth(AControl, AConstraints, aWidth);
end;

class procedure TLWWSStatusBar.ConstraintHeight(const AControl: TControl; const AConstraints: TObject; var aHeight: integer);
begin
  if LWIsMainThread then
    GRealStatusBar.ConstraintHeight(AControl, AConstraints, aHeight)
  else
    inherited ConstraintHeight(AControl, AConstraints, aHeight);
end;

class function TLWWSStatusBar.GetCanvasScaleFactor(const AControl: TControl): Double;
begin
  if LWIsMainThread then
    Result := GRealStatusBar.GetCanvasScaleFactor(AControl)
  else
    Result := inherited GetCanvasScaleFactor(AControl);
end;

{ TLWWSMenuItem：主线程走真实类，工作线程走空基类（= nogui 行为） }
class function TLWWSMenuItem.OpenCommand: LongInt;
begin
  if LWIsMainThread then
    Result := GRealMenuItem.OpenCommand()
  else
    Result := inherited OpenCommand();
end;

class procedure TLWWSMenuItem.CloseCommand(ACommand: LongInt);
begin
  if LWIsMainThread then
    GRealMenuItem.CloseCommand(ACommand)
  else
    inherited CloseCommand(ACommand);
end;

class procedure TLWWSMenuItem.AttachMenu(const AMenuItem: TMenuItem);
begin
  if LWIsMainThread then
    GRealMenuItem.AttachMenu(AMenuItem)
  else
    inherited AttachMenu(AMenuItem);
end;

class function TLWWSMenuItem.CreateHandle(const AMenuItem: TMenuItem): HMENU;
begin
  if LWIsMainThread then
    Result := GRealMenuItem.CreateHandle(AMenuItem)
  else
    Result := inherited CreateHandle(AMenuItem);
end;

class procedure TLWWSMenuItem.DestroyHandle(const AMenuItem: TMenuItem);
begin
  if LWIsMainThread then
    GRealMenuItem.DestroyHandle(AMenuItem)
  else
    inherited DestroyHandle(AMenuItem);
end;

class procedure TLWWSMenuItem.SetCaption(const AMenuItem: TMenuItem; const ACaption: string);
begin
  if LWIsMainThread then
    GRealMenuItem.SetCaption(AMenuItem, ACaption)
  else
    inherited SetCaption(AMenuItem, ACaption);
end;

class procedure TLWWSMenuItem.SetShortCut(const AMenuItem: TMenuItem; const ShortCutK1, ShortCutK2: TShortCut);
begin
  if LWIsMainThread then
    GRealMenuItem.SetShortCut(AMenuItem, ShortCutK1, ShortCutK2)
  else
    inherited SetShortCut(AMenuItem, ShortCutK1, ShortCutK2);
end;

class procedure TLWWSMenuItem.SetVisible(const AMenuItem: TMenuItem; const Visible: boolean);
begin
  if LWIsMainThread then
    GRealMenuItem.SetVisible(AMenuItem, Visible)
  else
    inherited SetVisible(AMenuItem, Visible);
end;

class function TLWWSMenuItem.SetCheck(const AMenuItem: TMenuItem; const Checked: boolean): boolean;
begin
  if LWIsMainThread then
    Result := GRealMenuItem.SetCheck(AMenuItem, Checked)
  else
    Result := inherited SetCheck(AMenuItem, Checked);
end;

class function TLWWSMenuItem.SetEnable(const AMenuItem: TMenuItem; const Enabled: boolean): boolean;
begin
  if LWIsMainThread then
    Result := GRealMenuItem.SetEnable(AMenuItem, Enabled)
  else
    Result := inherited SetEnable(AMenuItem, Enabled);
end;

class function TLWWSMenuItem.SetRadioItem(const AMenuItem: TMenuItem; const RadioItem: boolean): boolean;
begin
  if LWIsMainThread then
    Result := GRealMenuItem.SetRadioItem(AMenuItem, RadioItem)
  else
    Result := inherited SetRadioItem(AMenuItem, RadioItem);
end;

class function TLWWSMenuItem.SetRightJustify(const AMenuItem: TMenuItem; const Justified: boolean): boolean;
begin
  if LWIsMainThread then
    Result := GRealMenuItem.SetRightJustify(AMenuItem, Justified)
  else
    Result := inherited SetRightJustify(AMenuItem, Justified);
end;

class procedure TLWWSMenuItem.UpdateMenuIcon(const AMenuItem: TMenuItem; const HasIcon: Boolean; const AIcon: TBitmap);
begin
  if LWIsMainThread then
    GRealMenuItem.UpdateMenuIcon(AMenuItem, HasIcon, AIcon)
  else
    inherited UpdateMenuIcon(AMenuItem, HasIcon, AIcon);
end;

{ TLWWSMenu：主线程走真实类，工作线程走空基类（= nogui 行为） }
class function TLWWSMenu.CreateHandle(const AMenu: TMenu): HMENU;
begin
  if LWIsMainThread then
    Result := GRealMenu.CreateHandle(AMenu)
  else
    Result := inherited CreateHandle(AMenu);
end;

class procedure TLWWSMenu.SetBiDiMode(const AMenu: TMenu; UseRightToLeftAlign, UseRightToLeftReading : Boolean);
begin
  if LWIsMainThread then
    GRealMenu.SetBiDiMode(AMenu, UseRightToLeftAlign, UseRightToLeftReading)
  else
    inherited SetBiDiMode(AMenu, UseRightToLeftAlign, UseRightToLeftReading);
end;

{ TLWWSMainMenu：主线程走真实类，工作线程走空基类（= nogui 行为） }
class function TLWWSMainMenu.CreateHandle(const AMenu: TMenu): HMENU;
begin
  if LWIsMainThread then
    Result := GRealMainMenu.CreateHandle(AMenu)
  else
    Result := inherited CreateHandle(AMenu);
end;

class procedure TLWWSMainMenu.SetBiDiMode(const AMenu: TMenu; UseRightToLeftAlign, UseRightToLeftReading : Boolean);
begin
  if LWIsMainThread then
    GRealMainMenu.SetBiDiMode(AMenu, UseRightToLeftAlign, UseRightToLeftReading)
  else
    inherited SetBiDiMode(AMenu, UseRightToLeftAlign, UseRightToLeftReading);
end;

{ TLWWSPopupMenu：主线程走真实类，工作线程走空基类（= nogui 行为） }
class procedure TLWWSPopupMenu.Popup(const APopupMenu: TPopupMenu; const X, Y: integer);
begin
  if LWIsMainThread then
    GRealPopupMenu.Popup(APopupMenu, X, Y)
  else
    inherited Popup(APopupMenu, X, Y);
end;

class function TLWWSPopupMenu.CreateHandle(const AMenu: TMenu): HMENU;
begin
  if LWIsMainThread then
    Result := GRealPopupMenu.CreateHandle(AMenu)
  else
    Result := inherited CreateHandle(AMenu);
end;

class procedure TLWWSPopupMenu.SetBiDiMode(const AMenu: TMenu; UseRightToLeftAlign, UseRightToLeftReading : Boolean);
begin
  if LWIsMainThread then
    GRealPopupMenu.SetBiDiMode(AMenu, UseRightToLeftAlign, UseRightToLeftReading)
  else
    inherited SetBiDiMode(AMenu, UseRightToLeftAlign, UseRightToLeftReading);
end;

{ ---------------- TLWProxyWidgetSet：按线程转发 ---------------- }

constructor TLWProxyWidgetSet.Create;
begin
  inherited Create;
end;

procedure TLWProxyWidgetSet.PassCmdLineOptions;
begin
  if LWIsMainThread then inherited PassCmdLineOptions() else FVirtual.PassCmdLineOptions();
end;

function TLWProxyWidgetSet.CreateThemeServices: TThemeServices;
begin
  if LWIsMainThread then Result := inherited CreateThemeServices() else Result := FVirtual.CreateThemeServices();
end;

function TLWProxyWidgetSet.GetAppHandle: TLCLHandle;
begin
  if LWIsMainThread then Result := inherited GetAppHandle() else Result := FVirtual.GetAppHandle();
end;

procedure TLWProxyWidgetSet.SetAppHandle(const AValue: TLCLHandle);
begin
  if LWIsMainThread then inherited SetAppHandle(AValue) else FVirtual.SetAppHandle(AValue);
end;

procedure TLWProxyWidgetSet.AppInit(var ScreenInfo: TScreenInfo);
begin
  if LWIsMainThread then inherited AppInit(ScreenInfo) else FVirtual.AppInit(ScreenInfo);
end;

procedure TLWProxyWidgetSet.AppRun(const ALoop: TApplicationMainLoop);
begin
  if LWIsMainThread then inherited AppRun(ALoop) else FVirtual.AppRun(ALoop);
end;

procedure TLWProxyWidgetSet.AppWaitMessage;
begin
  if LWIsMainThread then inherited AppWaitMessage() else FVirtual.AppWaitMessage();
end;

procedure TLWProxyWidgetSet.AppProcessMessages;
begin
  if LWIsMainThread then inherited AppProcessMessages() else FVirtual.AppProcessMessages();
end;

procedure TLWProxyWidgetSet.AppTerminate;
begin
  if LWIsMainThread then inherited AppTerminate() else FVirtual.AppTerminate();
end;

procedure TLWProxyWidgetSet.AppMinimize;
begin
  if LWIsMainThread then inherited AppMinimize() else FVirtual.AppMinimize();
end;

procedure TLWProxyWidgetSet.AppRestore;
begin
  if LWIsMainThread then inherited AppRestore() else FVirtual.AppRestore();
end;

procedure TLWProxyWidgetSet.AppBringToFront;
begin
  if LWIsMainThread then inherited AppBringToFront() else FVirtual.AppBringToFront();
end;

procedure TLWProxyWidgetSet.AppSetIcon(const Small, Big: HICON);
begin
  if LWIsMainThread then inherited AppSetIcon(Small, Big) else FVirtual.AppSetIcon(Small, Big);
end;

procedure TLWProxyWidgetSet.AppSetTitle(const ATitle: string);
begin
  if LWIsMainThread then inherited AppSetTitle(ATitle) else FVirtual.AppSetTitle(ATitle);
end;

procedure TLWProxyWidgetSet.AppSetVisible(const AVisible: Boolean);
begin
  if LWIsMainThread then inherited AppSetVisible(AVisible) else FVirtual.AppSetVisible(AVisible);
end;

function TLWProxyWidgetSet.AppRemoveStayOnTopFlags(const ASystemTopAlso: Boolean): Boolean;
begin
  if LWIsMainThread then Result := inherited AppRemoveStayOnTopFlags(ASystemTopAlso) else Result := FVirtual.AppRemoveStayOnTopFlags(ASystemTopAlso);
end;

function TLWProxyWidgetSet.AppRestoreStayOnTopFlags(const ASystemTopAlso: Boolean): Boolean;
begin
  if LWIsMainThread then Result := inherited AppRestoreStayOnTopFlags(ASystemTopAlso) else Result := FVirtual.AppRestoreStayOnTopFlags(ASystemTopAlso);
end;

procedure TLWProxyWidgetSet.AppSetMainFormOnTaskBar(const DoSet: Boolean);
begin
  if LWIsMainThread then inherited AppSetMainFormOnTaskBar(DoSet) else FVirtual.AppSetMainFormOnTaskBar(DoSet);
end;

procedure TLWProxyWidgetSet.AppSetupMainForm(AMainForm: TObject);
begin
  if LWIsMainThread then inherited AppSetupMainForm(AMainForm) else FVirtual.AppSetupMainForm(AMainForm);
end;

function TLWProxyWidgetSet.BeginMessageProcess: TLCLHandle;
begin
  if LWIsMainThread then Result := inherited BeginMessageProcess() else Result := FVirtual.BeginMessageProcess();
end;

procedure TLWProxyWidgetSet.EndMessageProcess(context: TLCLHandle);
begin
  if LWIsMainThread then inherited EndMessageProcess(context) else FVirtual.EndMessageProcess(context);
end;

function TLWProxyWidgetSet.LCLPlatform: TLCLPlatform;
begin
  if LWIsMainThread then Result := inherited LCLPlatform() else Result := FVirtual.LCLPlatform();
end;

function TLWProxyWidgetSet.GetLCLCapability(ACapability: TLCLCapability): PtrUInt;
begin
  if LWIsMainThread then Result := inherited GetLCLCapability(ACapability) else Result := FVirtual.GetLCLCapability(ACapability);
end;

function TLWProxyWidgetSet.DCGetPixel(CanvasHandle: HDC; X, Y: integer): TGraphicsColor;
begin
  if LWIsMainThread then Result := inherited DCGetPixel(CanvasHandle, X, Y) else Result := FVirtual.DCGetPixel(CanvasHandle, X, Y);
end;

procedure TLWProxyWidgetSet.DCSetPixel(CanvasHandle: HDC; X, Y: integer; AColor: TGraphicsColor);
begin
  if LWIsMainThread then inherited DCSetPixel(CanvasHandle, X, Y, AColor) else FVirtual.DCSetPixel(CanvasHandle, X, Y, AColor);
end;

procedure TLWProxyWidgetSet.DCRedraw(CanvasHandle: HDC);
begin
  if LWIsMainThread then inherited DCRedraw(CanvasHandle) else FVirtual.DCRedraw(CanvasHandle);
end;

procedure TLWProxyWidgetSet.DCSetAntialiasing(CanvasHandle: HDC; AEnabled: Boolean);
begin
  if LWIsMainThread then inherited DCSetAntialiasing(CanvasHandle, AEnabled) else FVirtual.DCSetAntialiasing(CanvasHandle, AEnabled);
end;

procedure TLWProxyWidgetSet.SetDesigning(AComponent: TComponent);
begin
  if LWIsMainThread then inherited SetDesigning(AComponent) else FVirtual.SetDesigning(AComponent);
end;

function TLWProxyWidgetSet.InitStockFont(AFont: TObject; AStockFont: TStockFont): Boolean;
begin
  if LWIsMainThread then Result := inherited InitStockFont(AFont, AStockFont) else Result := FVirtual.InitStockFont(AFont, AStockFont);
end;

function TLWProxyWidgetSet.IsHelpKey(Key: Word; Shift: TShiftState): Boolean;
begin
  if LWIsMainThread then Result := inherited IsHelpKey(Key, Shift) else Result := FVirtual.IsHelpKey(Key, Shift);
end;

function TLWProxyWidgetSet.CreateTimer(Interval: integer; TimerProc: TWSTimerProc): TLCLHandle;
begin
  if LWIsMainThread then Result := inherited CreateTimer(Interval, TimerProc) else Result := FVirtual.CreateTimer(Interval, TimerProc);
end;

function TLWProxyWidgetSet.DestroyTimer(TimerHandle: TLCLHandle): boolean;
begin
  if LWIsMainThread then Result := inherited DestroyTimer(TimerHandle) else Result := FVirtual.DestroyTimer(TimerHandle);
end;

function TLWProxyWidgetSet.Arc(DC: HDC; Left,Top,Right,Bottom,Angle16Deg, Angle16DegLength: Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited Arc(DC, Left, Top, Right, Bottom, Angle16Deg, Angle16DegLength) else Result := FVirtual.Arc(DC, Left, Top, Right, Bottom, Angle16Deg, Angle16DegLength);
end;

function TLWProxyWidgetSet.AngleChord(DC: HDC; x1,y1,x2,y2,angle1,angle2 : Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited AngleChord(DC, x1, y1, x2, y2, angle1, angle2) else Result := FVirtual.AngleChord(DC, x1, y1, x2, y2, angle1, angle2);
end;

function TLWProxyWidgetSet.BeginPaint(Handle : hwnd; var PS : TPaintStruct): hdc;
begin
  if LWIsMainThread then Result := inherited BeginPaint(Handle, PS) else Result := FVirtual.BeginPaint(Handle, PS);
end;

function TLWProxyWidgetSet.BitBlt(DestDC: HDC; X, Y, Width, Height: Integer; SrcDC: HDC; XSrc, YSrc: Integer; Rop: DWORD): Boolean;
begin
  if LWIsMainThread then Result := inherited BitBlt(DestDC, X, Y, Width, Height, SrcDC, XSrc, YSrc, Rop) else Result := FVirtual.BitBlt(DestDC, X, Y, Width, Height, SrcDC, XSrc, YSrc, Rop);
end;

function TLWProxyWidgetSet.CallNextHookEx(hhk : HHOOK; ncode : Integer; WParam: WParam; LParam: LParam): Integer;
begin
  if LWIsMainThread then Result := inherited CallNextHookEx(hhk, ncode, WParam, LParam) else Result := FVirtual.CallNextHookEx(hhk, ncode, WParam, LParam);
end;

function TLWProxyWidgetSet.CallWindowProc(lpPrevWndFunc : TFarProc; Handle : HWND; Msg : UINT; WParam: WParam; LParam: LParam): Integer;
begin
  if LWIsMainThread then Result := inherited CallWindowProc(lpPrevWndFunc, Handle, Msg, WParam, LParam) else Result := FVirtual.CallWindowProc(lpPrevWndFunc, Handle, Msg, WParam, LParam);
end;

function TLWProxyWidgetSet.ClientToScreen(Handle : HWND; var P : TPoint): Boolean;
begin
  if LWIsMainThread then Result := inherited ClientToScreen(Handle, P) else Result := FVirtual.ClientToScreen(Handle, P);
end;

function TLWProxyWidgetSet.CombineRgn(Dest, Src1, Src2 : HRGN; fnCombineMode : Longint): Longint;
begin
  if LWIsMainThread then Result := inherited CombineRgn(Dest, Src1, Src2, fnCombineMode) else Result := FVirtual.CombineRgn(Dest, Src1, Src2, fnCombineMode);
end;

function TLWProxyWidgetSet.CreateBitmap(Width, Height: Integer; Planes, BitCount: Longint; BitmapBits: Pointer): HBITMAP;
begin
  if LWIsMainThread then Result := inherited CreateBitmap(Width, Height, Planes, BitCount, BitmapBits) else Result := FVirtual.CreateBitmap(Width, Height, Planes, BitCount, BitmapBits);
end;

function TLWProxyWidgetSet.CreateBrushIndirect(const LogBrush: TLogBrush): HBRUSH;
begin
  if LWIsMainThread then Result := inherited CreateBrushIndirect(LogBrush) else Result := FVirtual.CreateBrushIndirect(LogBrush);
end;

function TLWProxyWidgetSet.CreateBrushWithRadialGradient(const LogBrush: TLogRadialGradient): HBRUSH;
begin
  if LWIsMainThread then Result := inherited CreateBrushWithRadialGradient(LogBrush) else Result := FVirtual.CreateBrushWithRadialGradient(LogBrush);
end;

function TLWProxyWidgetSet.CreateCaret(Handle: HWND; Bitmap: hBitmap; width, Height: Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited CreateCaret(Handle, Bitmap, width, Height) else Result := FVirtual.CreateCaret(Handle, Bitmap, width, Height);
end;

function TLWProxyWidgetSet.CreateCompatibleBitmap(DC: HDC; Width, Height: Integer): HBITMAP;
begin
  if LWIsMainThread then Result := inherited CreateCompatibleBitmap(DC, Width, Height) else Result := FVirtual.CreateCompatibleBitmap(DC, Width, Height);
end;

function TLWProxyWidgetSet.CreateCompatibleDC(DC: HDC): HDC;
begin
  if LWIsMainThread then Result := inherited CreateCompatibleDC(DC) else Result := FVirtual.CreateCompatibleDC(DC);
end;

function TLWProxyWidgetSet.CreateDIBitmap(DC: HDC; var InfoHeader: TBitmapInfoHeader; dwUsage: DWORD; InitBits: PChar; var InitInfo: TBitmapInfo; wUsage: UINT): HBITMAP;
begin
  if LWIsMainThread then Result := inherited CreateDIBitmap(DC, InfoHeader, dwUsage, InitBits, InitInfo, wUsage) else Result := FVirtual.CreateDIBitmap(DC, InfoHeader, dwUsage, InitBits, InitInfo, wUsage);
end;

function TLWProxyWidgetSet.CreateDIBSection(DC: HDC; const BitmapInfo: tagBitmapInfo; Usage: UINT; var Bits: Pointer; SectionHandle: TLCLHandle; Offset: DWORD): HBITMAP;
begin
  if LWIsMainThread then Result := inherited CreateDIBSection(DC, BitmapInfo, Usage, Bits, SectionHandle, Offset) else Result := FVirtual.CreateDIBSection(DC, BitmapInfo, Usage, Bits, SectionHandle, Offset);
end;

function TLWProxyWidgetSet.CreateEllipticRgn(X1, Y1, X2, Y2: Integer): HRGN;
begin
  if LWIsMainThread then Result := inherited CreateEllipticRgn(X1, Y1, X2, Y2) else Result := FVirtual.CreateEllipticRgn(X1, Y1, X2, Y2);
end;

function TLWProxyWidgetSet.CreateFontIndirect(const LogFont: TLogFont): HFONT;
begin
  if LWIsMainThread then Result := inherited CreateFontIndirect(LogFont) else Result := FVirtual.CreateFontIndirect(LogFont);
end;

function TLWProxyWidgetSet.CreateFontIndirectEx(const LogFont: TLogFont; const LongFontName: string): HFONT;
begin
  if LWIsMainThread then Result := inherited CreateFontIndirectEx(LogFont, LongFontName) else Result := FVirtual.CreateFontIndirectEx(LogFont, LongFontName);
end;

function TLWProxyWidgetSet.CreateIconIndirect(IconInfo: PIconInfo): HICON;
begin
  if LWIsMainThread then Result := inherited CreateIconIndirect(IconInfo) else Result := FVirtual.CreateIconIndirect(IconInfo);
end;

function TLWProxyWidgetSet.CreatePalette(const LogPalette: TLogPalette): HPalette;
begin
  if LWIsMainThread then Result := inherited CreatePalette(LogPalette) else Result := FVirtual.CreatePalette(LogPalette);
end;

function TLWProxyWidgetSet.CreatePatternBrush(ABitmap: HBITMAP): HBRUSH;
begin
  if LWIsMainThread then Result := inherited CreatePatternBrush(ABitmap) else Result := FVirtual.CreatePatternBrush(ABitmap);
end;

function TLWProxyWidgetSet.CreatePenIndirect(const LogPen: TLogPen): HPEN;
begin
  if LWIsMainThread then Result := inherited CreatePenIndirect(LogPen) else Result := FVirtual.CreatePenIndirect(LogPen);
end;

function TLWProxyWidgetSet.CreatePolygonRgn(Points: PPoint; NumPts: Integer; FillMode: integer): HRGN;
begin
  if LWIsMainThread then Result := inherited CreatePolygonRgn(Points, NumPts, FillMode) else Result := FVirtual.CreatePolygonRgn(Points, NumPts, FillMode);
end;

function TLWProxyWidgetSet.CreateRectRgn(X1,Y1,X2,Y2 : Integer): HRGN;
begin
  if LWIsMainThread then Result := inherited CreateRectRgn(X1, Y1, X2, Y2) else Result := FVirtual.CreateRectRgn(X1, Y1, X2, Y2);
end;

function TLWProxyWidgetSet.CreateRoundRectRgn(X1, Y1, X2, Y2, nWidthEllipse, nHeightEllipse: Integer): HRGN;
begin
  if LWIsMainThread then Result := inherited CreateRoundRectRgn(X1, Y1, X2, Y2, nWidthEllipse, nHeightEllipse) else Result := FVirtual.CreateRoundRectRgn(X1, Y1, X2, Y2, nWidthEllipse, nHeightEllipse);
end;

procedure TLWProxyWidgetSet.DeleteCriticalSection(var CritSection: TCriticalSection);
begin
  if LWIsMainThread then inherited DeleteCriticalSection(CritSection) else FVirtual.DeleteCriticalSection(CritSection);
end;

function TLWProxyWidgetSet.DeleteDC(hDC: HDC): Boolean;
begin
  if LWIsMainThread then Result := inherited DeleteDC(hDC) else Result := FVirtual.DeleteDC(hDC);
end;

function TLWProxyWidgetSet.DeleteObject(GDIObject: HGDIOBJ): Boolean;
begin
  if LWIsMainThread then Result := inherited DeleteObject(GDIObject) else Result := FVirtual.DeleteObject(GDIObject);
end;

function TLWProxyWidgetSet.DestroyCaret(Handle : HWND): Boolean;
begin
  if LWIsMainThread then Result := inherited DestroyCaret(Handle) else Result := FVirtual.DestroyCaret(Handle);
end;

function TLWProxyWidgetSet.DestroyCursor(Handle: HCURSOR): Boolean;
begin
  if LWIsMainThread then Result := inherited DestroyCursor(Handle) else Result := FVirtual.DestroyCursor(Handle);
end;

function TLWProxyWidgetSet.DestroyIcon(Handle: HICON): Boolean;
begin
  if LWIsMainThread then Result := inherited DestroyIcon(Handle) else Result := FVirtual.DestroyIcon(Handle);
end;

function TLWProxyWidgetSet.DrawFrameControl(DC: HDC; const Rect : TRect; uType, uState : Cardinal): Boolean;
begin
  if LWIsMainThread then Result := inherited DrawFrameControl(DC, Rect, uType, uState) else Result := FVirtual.DrawFrameControl(DC, Rect, uType, uState);
end;

function TLWProxyWidgetSet.DrawFocusRect(DC: HDC; const Rect: TRect): Boolean;
begin
  if LWIsMainThread then Result := inherited DrawFocusRect(DC, Rect) else Result := FVirtual.DrawFocusRect(DC, Rect);
end;

function TLWProxyWidgetSet.DrawEdge(DC: HDC; var Rect: TRect; edge: Cardinal; grfFlags: Cardinal): Boolean;
begin
  if LWIsMainThread then Result := inherited DrawEdge(DC, Rect, edge, grfFlags) else Result := FVirtual.DrawEdge(DC, Rect, edge, grfFlags);
end;

function TLWProxyWidgetSet.DrawText(DC: HDC; Str: PChar; Count: Integer; var Rect: TRect; Flags: Cardinal): Integer;
begin
  if LWIsMainThread then Result := inherited DrawText(DC, Str, Count, Rect, Flags) else Result := FVirtual.DrawText(DC, Str, Count, Rect, Flags);
end;

function TLWProxyWidgetSet.EnableScrollBar(Wnd: HWND; wSBflags, wArrows: Cardinal): Boolean;
begin
  if LWIsMainThread then Result := inherited EnableScrollBar(Wnd, wSBflags, wArrows) else Result := FVirtual.EnableScrollBar(Wnd, wSBflags, wArrows);
end;

function TLWProxyWidgetSet.EnableWindow(hWnd: HWND; bEnable: Boolean): Boolean;
begin
  if LWIsMainThread then Result := inherited EnableWindow(hWnd, bEnable) else Result := FVirtual.EnableWindow(hWnd, bEnable);
end;

function TLWProxyWidgetSet.EndPaint(Handle : hwnd; var PS : TPaintStruct): Integer;
begin
  if LWIsMainThread then Result := inherited EndPaint(Handle, PS) else Result := FVirtual.EndPaint(Handle, PS);
end;

procedure TLWProxyWidgetSet.EnterCriticalSection(var CritSection: TCriticalSection);
begin
  if LWIsMainThread then inherited EnterCriticalSection(CritSection) else FVirtual.EnterCriticalSection(CritSection);
end;

function TLWProxyWidgetSet.EnumDisplayMonitors(hdc: HDC; lprcClip: PRect; lpfnEnum: MonitorEnumProc; dwData: LPARAM): LongBool;
begin
  if LWIsMainThread then Result := inherited EnumDisplayMonitors(hdc, lprcClip, lpfnEnum, dwData) else Result := FVirtual.EnumDisplayMonitors(hdc, lprcClip, lpfnEnum, dwData);
end;

function TLWProxyWidgetSet.EnumFontFamilies(DC: HDC; Family: Pchar; EnumFontFamProc: FontEnumProc; LParam:Lparam): longint;
begin
  if LWIsMainThread then Result := inherited EnumFontFamilies(DC, Family, EnumFontFamProc, LParam) else Result := FVirtual.EnumFontFamilies(DC, Family, EnumFontFamProc, LParam);
end;

function TLWProxyWidgetSet.EnumFontFamiliesEx(DC: HDC; lpLogFont:PLogFont; Callback: FontEnumExProc; Lparam:LParam; Flags: dword): longint;
begin
  if LWIsMainThread then Result := inherited EnumFontFamiliesEx(DC, lpLogFont, Callback, Lparam, Flags) else Result := FVirtual.EnumFontFamiliesEx(DC, lpLogFont, Callback, Lparam, Flags);
end;

function TLWProxyWidgetSet.Ellipse(DC: HDC; x1, y1, x2, y2: Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited Ellipse(DC, x1, y1, x2, y2) else Result := FVirtual.Ellipse(DC, x1, y1, x2, y2);
end;

function TLWProxyWidgetSet.EqualRgn(Rgn1: HRGN; Rgn2: HRGN): Boolean;
begin
  if LWIsMainThread then Result := inherited EqualRgn(Rgn1, Rgn2) else Result := FVirtual.EqualRgn(Rgn1, Rgn2);
end;

function TLWProxyWidgetSet.ExcludeClipRect(dc: hdc; Left, Top, Right, Bottom : Integer): Integer;
begin
  if LWIsMainThread then Result := inherited ExcludeClipRect(dc, Left, Top, Right, Bottom) else Result := FVirtual.ExcludeClipRect(dc, Left, Top, Right, Bottom);
end;

function TLWProxyWidgetSet.ExtCreatePen(dwPenStyle, dwWidth: DWord; const lplb: TLogBrush; dwStyleCount: DWord; lpStyle: PDWord): HPEN;
begin
  if LWIsMainThread then Result := inherited ExtCreatePen(dwPenStyle, dwWidth, lplb, dwStyleCount, lpStyle) else Result := FVirtual.ExtCreatePen(dwPenStyle, dwWidth, lplb, dwStyleCount, lpStyle);
end;

function TLWProxyWidgetSet.ExtTextOut(DC: HDC; X, Y: Integer; Options: Longint; Rect: PRect; Str: PChar; Count: Longint; Dx: PInteger): Boolean;
begin
  if LWIsMainThread then Result := inherited ExtTextOut(DC, X, Y, Options, Rect, Str, Count, Dx) else Result := FVirtual.ExtTextOut(DC, X, Y, Options, Rect, Str, Count, Dx);
end;

function TLWProxyWidgetSet.ExtSelectClipRGN(dc: hdc; rgn : hrgn; Mode : Longint): Integer;
begin
  if LWIsMainThread then Result := inherited ExtSelectClipRGN(dc, rgn, Mode) else Result := FVirtual.ExtSelectClipRGN(dc, rgn, Mode);
end;

function TLWProxyWidgetSet.FillRect(DC: HDC; const Rect: TRect; Brush: HBRUSH): Boolean;
begin
  if LWIsMainThread then Result := inherited FillRect(DC, Rect, Brush) else Result := FVirtual.FillRect(DC, Rect, Brush);
end;

function TLWProxyWidgetSet.FillRgn(DC: HDC; RegionHnd: HRGN; hbr: HBRUSH): BOOL;
begin
  if LWIsMainThread then Result := inherited FillRgn(DC, RegionHnd, hbr) else Result := FVirtual.FillRgn(DC, RegionHnd, hbr);
end;

function TLWProxyWidgetSet.FloodFill(DC: HDC; X, Y: Integer; Color: TGraphicsColor; FillStyle: TGraphicsFillStyle; Brush: HBRUSH): Boolean;
begin
  if LWIsMainThread then Result := inherited FloodFill(DC, X, Y, Color, FillStyle, Brush) else Result := FVirtual.FloodFill(DC, X, Y, Color, FillStyle, Brush);
end;

function TLWProxyWidgetSet.FrameRect(DC: HDC; const ARect: TRect; hBr: HBRUSH): Integer;
begin
  if LWIsMainThread then Result := inherited FrameRect(DC, ARect, hBr) else Result := FVirtual.FrameRect(DC, ARect, hBr);
end;

function TLWProxyWidgetSet.GetActiveWindow: HWND;
begin
  if LWIsMainThread then Result := inherited GetActiveWindow() else Result := FVirtual.GetActiveWindow();
end;

function TLWProxyWidgetSet.GetBitmapBits(Bitmap: HBITMAP; Count: Longint; Bits: Pointer): Longint;
begin
  if LWIsMainThread then Result := inherited GetBitmapBits(Bitmap, Count, Bits) else Result := FVirtual.GetBitmapBits(Bitmap, Count, Bits);
end;

function TLWProxyWidgetSet.GetBkColor(DC: HDC): TColorRef;
begin
  if LWIsMainThread then Result := inherited GetBkColor(DC) else Result := FVirtual.GetBkColor(DC);
end;

function TLWProxyWidgetSet.GetCapture: HWND;
begin
  if LWIsMainThread then Result := inherited GetCapture() else Result := FVirtual.GetCapture();
end;

function TLWProxyWidgetSet.GetCaretPos(var lpPoint: TPoint): Boolean;
begin
  if LWIsMainThread then Result := inherited GetCaretPos(lpPoint) else Result := FVirtual.GetCaretPos(lpPoint);
end;

function TLWProxyWidgetSet.GetClientRect(handle : HWND; var Rect: TRect): Boolean;
begin
  if LWIsMainThread then Result := inherited GetClientRect(handle, Rect) else Result := FVirtual.GetClientRect(handle, Rect);
end;

function TLWProxyWidgetSet.GetClipBox(DC : hDC; lpRect : PRect): Longint;
begin
  if LWIsMainThread then Result := inherited GetClipBox(DC, lpRect) else Result := FVirtual.GetClipBox(DC, lpRect);
end;

function TLWProxyWidgetSet.GetClipRGN(DC : hDC; RGN : hRGN): Longint;
begin
  if LWIsMainThread then Result := inherited GetClipRGN(DC, RGN) else Result := FVirtual.GetClipRGN(DC, RGN);
end;

function TLWProxyWidgetSet.GetCompositorExtendedBorder(handle : HWND; var Borders: TRect): Boolean;
begin
  if LWIsMainThread then Result := inherited GetCompositorExtendedBorder(handle, Borders) else Result := FVirtual.GetCompositorExtendedBorder(handle, Borders);
end;

function TLWProxyWidgetSet.GetCurrentObject(DC: HDC; uObjectType: UINT): HGDIOBJ;
begin
  if LWIsMainThread then Result := inherited GetCurrentObject(DC, uObjectType) else Result := FVirtual.GetCurrentObject(DC, uObjectType);
end;

function TLWProxyWidgetSet.GetCursorPos(var lpPoint: TPoint): Boolean;
begin
  if LWIsMainThread then Result := inherited GetCursorPos(lpPoint) else Result := FVirtual.GetCursorPos(lpPoint);
end;

function TLWProxyWidgetSet.GetDC(hWnd: HWND): HDC;
begin
  if LWIsMainThread then Result := inherited GetDC(hWnd) else Result := FVirtual.GetDC(hWnd);
end;

function TLWProxyWidgetSet.GetDeviceCaps(DC: HDC; Index: Integer): Integer;
begin
  if LWIsMainThread then Result := inherited GetDeviceCaps(DC, Index) else Result := FVirtual.GetDeviceCaps(DC, Index);
end;

function TLWProxyWidgetSet.GetDIBits(DC: HDC; Bitmap: HBitmap; StartScan, NumScans: UINT; Bits: Pointer; var BitInfo: BitmapInfo; Usage: UINT): Integer;
begin
  if LWIsMainThread then Result := inherited GetDIBits(DC, Bitmap, StartScan, NumScans, Bits, BitInfo, Usage) else Result := FVirtual.GetDIBits(DC, Bitmap, StartScan, NumScans, Bits, BitInfo, Usage);
end;

function TLWProxyWidgetSet.GetDoubleClickTime: UINT;
begin
  if LWIsMainThread then Result := inherited GetDoubleClickTime() else Result := FVirtual.GetDoubleClickTime();
end;

function TLWProxyWidgetSet.GetFocus: HWND;
begin
  if LWIsMainThread then Result := inherited GetFocus() else Result := FVirtual.GetFocus();
end;

function TLWProxyWidgetSet.GetFontLanguageInfo(DC: HDC): DWord;
begin
  if LWIsMainThread then Result := inherited GetFontLanguageInfo(DC) else Result := FVirtual.GetFontLanguageInfo(DC);
end;

function TLWProxyWidgetSet.GetForegroundWindow: HWND;
begin
  if LWIsMainThread then Result := inherited GetForegroundWindow() else Result := FVirtual.GetForegroundWindow();
end;

function TLWProxyWidgetSet.GetIconInfo(AIcon: HICON; AIconInfo: PIconInfo): Boolean;
begin
  if LWIsMainThread then Result := inherited GetIconInfo(AIcon, AIconInfo) else Result := FVirtual.GetIconInfo(AIcon, AIconInfo);
end;

function TLWProxyWidgetSet.GetKeyState(nVirtKey: Integer): Smallint;
begin
  if LWIsMainThread then Result := inherited GetKeyState(nVirtKey) else Result := FVirtual.GetKeyState(nVirtKey);
end;

function TLWProxyWidgetSet.GetMapMode(DC: HDC): Integer;
begin
  if LWIsMainThread then Result := inherited GetMapMode(DC) else Result := FVirtual.GetMapMode(DC);
end;

function TLWProxyWidgetSet.GetMonitorInfo(hMonitor: HMONITOR; lpmi: PMonitorInfo): Boolean;
begin
  if LWIsMainThread then Result := inherited GetMonitorInfo(hMonitor, lpmi) else Result := FVirtual.GetMonitorInfo(hMonitor, lpmi);
end;

function TLWProxyWidgetSet.GetDpiForMonitor(hmonitor: HMONITOR; dpiType: TMonitorDpiType; out dpiX: UINT; out dpiY: UINT): HRESULT;
begin
  if LWIsMainThread then Result := inherited GetDpiForMonitor(hmonitor, dpiType, dpiX, dpiY) else Result := FVirtual.GetDpiForMonitor(hmonitor, dpiType, dpiX, dpiY);
end;

function TLWProxyWidgetSet.GetObject(GDIObject: HGDIOBJ; BufSize: Integer; Buf: Pointer): Integer;
begin
  if LWIsMainThread then Result := inherited GetObject(GDIObject, BufSize, Buf) else Result := FVirtual.GetObject(GDIObject, BufSize, Buf);
end;

function TLWProxyWidgetSet.GetParent(Handle : HWND): HWND;
begin
  if LWIsMainThread then Result := inherited GetParent(Handle) else Result := FVirtual.GetParent(Handle);
end;

function TLWProxyWidgetSet.GetProp(Handle : hwnd; Str : PChar): Pointer;
begin
  if LWIsMainThread then Result := inherited GetProp(Handle, Str) else Result := FVirtual.GetProp(Handle, Str);
end;

function TLWProxyWidgetSet.GetRgnBox(RGN : HRGN; lpRect : PRect): Longint;
begin
  if LWIsMainThread then Result := inherited GetRgnBox(RGN, lpRect) else Result := FVirtual.GetRgnBox(RGN, lpRect);
end;

function TLWProxyWidgetSet.GetROP2(DC: HDC): integer;
begin
  if LWIsMainThread then Result := inherited GetROP2(DC) else Result := FVirtual.GetROP2(DC);
end;

function TLWProxyWidgetSet.GetScrollInfo(Handle: HWND; SBStyle: Integer; var ScrollInfo: TScrollInfo): Boolean;
begin
  if LWIsMainThread then Result := inherited GetScrollInfo(Handle, SBStyle, ScrollInfo) else Result := FVirtual.GetScrollInfo(Handle, SBStyle, ScrollInfo);
end;

function TLWProxyWidgetSet.GetStockObject(Value: Integer): TLCLHandle;
begin
  if LWIsMainThread then Result := inherited GetStockObject(Value) else Result := FVirtual.GetStockObject(Value);
end;

function TLWProxyWidgetSet.GetSysColor(nIndex: Integer): DWORD;
begin
  if LWIsMainThread then Result := inherited GetSysColor(nIndex) else Result := FVirtual.GetSysColor(nIndex);
end;

function TLWProxyWidgetSet.GetSysColorBrush(nIndex: Integer): HBrush;
begin
  if LWIsMainThread then Result := inherited GetSysColorBrush(nIndex) else Result := FVirtual.GetSysColorBrush(nIndex);
end;

function TLWProxyWidgetSet.GetSystemMetrics(nIndex: Integer): Integer;
begin
  if LWIsMainThread then Result := inherited GetSystemMetrics(nIndex) else Result := FVirtual.GetSystemMetrics(nIndex);
end;

function TLWProxyWidgetSet.GetTextColor(DC: HDC): TColorRef;
begin
  if LWIsMainThread then Result := inherited GetTextColor(DC) else Result := FVirtual.GetTextColor(DC);
end;

function TLWProxyWidgetSet.GetTextExtentExPoint(DC: HDC; Str: PChar; Count, MaxWidth: Integer; MaxCount, PartialWidths: PInteger; var Size: TSize): Boolean;
begin
  if LWIsMainThread then Result := inherited GetTextExtentExPoint(DC, Str, Count, MaxWidth, MaxCount, PartialWidths, Size) else Result := FVirtual.GetTextExtentExPoint(DC, Str, Count, MaxWidth, MaxCount, PartialWidths, Size);
end;

function TLWProxyWidgetSet.GetTextExtentPoint(DC: HDC; Str: PChar; Count: Integer; var Size: TSize): Boolean;
begin
  if LWIsMainThread then Result := inherited GetTextExtentPoint(DC, Str, Count, Size) else Result := FVirtual.GetTextExtentPoint(DC, Str, Count, Size);
end;

function TLWProxyWidgetSet.GetTextExtentPoint32(DC: HDC; Str: PChar; Count: Integer; var Size: TSize): Boolean;
begin
  if LWIsMainThread then Result := inherited GetTextExtentPoint32(DC, Str, Count, Size) else Result := FVirtual.GetTextExtentPoint32(DC, Str, Count, Size);
end;

function TLWProxyWidgetSet.GetTextMetrics(DC: HDC; var TM: TTextMetric): Boolean;
begin
  if LWIsMainThread then Result := inherited GetTextMetrics(DC, TM) else Result := FVirtual.GetTextMetrics(DC, TM);
end;

function TLWProxyWidgetSet.GetViewPortExtEx(DC: HDC; Size: PSize): Integer;
begin
  if LWIsMainThread then Result := inherited GetViewPortExtEx(DC, Size) else Result := FVirtual.GetViewPortExtEx(DC, Size);
end;

function TLWProxyWidgetSet.GetViewPortOrgEx(DC: HDC; P: PPoint): Integer;
begin
  if LWIsMainThread then Result := inherited GetViewPortOrgEx(DC, P) else Result := FVirtual.GetViewPortOrgEx(DC, P);
end;

function TLWProxyWidgetSet.GetWindowExtEx(DC: HDC; Size: PSize): Integer;
begin
  if LWIsMainThread then Result := inherited GetWindowExtEx(DC, Size) else Result := FVirtual.GetWindowExtEx(DC, Size);
end;

function TLWProxyWidgetSet.GetWindowLong(Handle : hwnd; int : Integer): PtrInt;
begin
  if LWIsMainThread then Result := inherited GetWindowLong(Handle, int) else Result := FVirtual.GetWindowLong(Handle, int);
end;

function TLWProxyWidgetSet.GetWindowRect(Handle : hwnd; var Rect : TRect): Integer;
begin
  if LWIsMainThread then Result := inherited GetWindowRect(Handle, Rect) else Result := FVirtual.GetWindowRect(Handle, Rect);
end;

function TLWProxyWidgetSet.GetWindowSize(Handle : hwnd; var Width, Height: integer): boolean;
begin
  if LWIsMainThread then Result := inherited GetWindowSize(Handle, Width, Height) else Result := FVirtual.GetWindowSize(Handle, Width, Height);
end;

function TLWProxyWidgetSet.GetWindowOrgEx(dc : hdc; var P: TPoint): Integer;
begin
  Result := GetWindowOrgEx(dc, @P);
end;

function TLWProxyWidgetSet.GetWindowOrgEx(dc : hdc; P : PPoint): Integer; overload;
begin
  if LWIsMainThread then Result := inherited GetWindowOrgEx(dc, P) else Result := FVirtual.GetWindowOrgEx(dc, P);
end;

function TLWProxyWidgetSet.GradientFill(DC: HDC; Vertices: PTriVertex; NumVertices : Longint; Meshes: Pointer; NumMeshes : Longint; Mode : Longint): Boolean;
begin
  if LWIsMainThread then Result := inherited GradientFill(DC, Vertices, NumVertices, Meshes, NumMeshes, Mode) else Result := FVirtual.GradientFill(DC, Vertices, NumVertices, Meshes, NumMeshes, Mode);
end;

function TLWProxyWidgetSet.HideCaret(hWnd: HWND): Boolean;
begin
  if LWIsMainThread then Result := inherited HideCaret(hWnd) else Result := FVirtual.HideCaret(hWnd);
end;

procedure TLWProxyWidgetSet.InitializeCriticalSection(var CritSection: TCriticalSection);
begin
  if LWIsMainThread then inherited InitializeCriticalSection(CritSection) else FVirtual.InitializeCriticalSection(CritSection);
end;

function TLWProxyWidgetSet.IntersectClipRect(dc: hdc; Left, Top, Right,Bottom: Integer): Integer;
begin
  if LWIsMainThread then Result := inherited IntersectClipRect(dc, Left, Top, Right, Bottom) else Result := FVirtual.IntersectClipRect(dc, Left, Top, Right, Bottom);
end;

function TLWProxyWidgetSet.InvalidateRect(aHandle : HWND; ARect : pRect; bErase : Boolean): Boolean;
begin
  if LWIsMainThread then Result := inherited InvalidateRect(aHandle, ARect, bErase) else Result := FVirtual.InvalidateRect(aHandle, ARect, bErase);
end;

function TLWProxyWidgetSet.InvalidateRgn(Handle: HWND; Rgn: HRGN; Erase: Boolean): Boolean;
begin
  if LWIsMainThread then Result := inherited InvalidateRgn(Handle, Rgn, Erase) else Result := FVirtual.InvalidateRgn(Handle, Rgn, Erase);
end;

function TLWProxyWidgetSet.IsDBCSLeadByte(TestChar: Byte): boolean;
begin
  if LWIsMainThread then Result := inherited IsDBCSLeadByte(TestChar) else Result := FVirtual.IsDBCSLeadByte(TestChar);
end;

function TLWProxyWidgetSet.IsIconic(handle: HWND): boolean;
begin
  if LWIsMainThread then Result := inherited IsIconic(handle) else Result := FVirtual.IsIconic(handle);
end;

function TLWProxyWidgetSet.IsWindow(handle: HWND): boolean;
begin
  if LWIsMainThread then Result := inherited IsWindow(handle) else Result := FVirtual.IsWindow(handle);
end;

function TLWProxyWidgetSet.IsWindowEnabled(handle: HWND): boolean;
begin
  if LWIsMainThread then Result := inherited IsWindowEnabled(handle) else Result := FVirtual.IsWindowEnabled(handle);
end;

function TLWProxyWidgetSet.IsWindowVisible(handle: HWND): boolean;
begin
  if LWIsMainThread then Result := inherited IsWindowVisible(handle) else Result := FVirtual.IsWindowVisible(handle);
end;

function TLWProxyWidgetSet.IsZoomed(handle: HWND): boolean;
begin
  if LWIsMainThread then Result := inherited IsZoomed(handle) else Result := FVirtual.IsZoomed(handle);
end;

procedure TLWProxyWidgetSet.LeaveCriticalSection(var CritSection: TCriticalSection);
begin
  if LWIsMainThread then inherited LeaveCriticalSection(CritSection) else FVirtual.LeaveCriticalSection(CritSection);
end;

function TLWProxyWidgetSet.LineTo(DC: HDC; X, Y: Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited LineTo(DC, X, Y) else Result := FVirtual.LineTo(DC, X, Y);
end;

function TLWProxyWidgetSet.LoadBitmap(hInstance: TLCLHandle; lpBitmapName: PChar): HBitmap;
begin
  if LWIsMainThread then Result := inherited LoadBitmap(hInstance, lpBitmapName) else Result := FVirtual.LoadBitmap(hInstance, lpBitmapName);
end;

function TLWProxyWidgetSet.LoadCursor(hInstance: TLCLHandle; lpCursorName: PChar): HCursor;
begin
  if LWIsMainThread then Result := inherited LoadCursor(hInstance, lpCursorName) else Result := FVirtual.LoadCursor(hInstance, lpCursorName);
end;

function TLWProxyWidgetSet.LoadIcon(hInstance: TLCLHandle; lpIconName: PChar): HIcon;
begin
  if LWIsMainThread then Result := inherited LoadIcon(hInstance, lpIconName) else Result := FVirtual.LoadIcon(hInstance, lpIconName);
end;

function TLWProxyWidgetSet.MaskBlt(DestDC: HDC; X, Y, Width, Height: Integer; SrcDC: HDC; XSrc, YSrc: Integer; Mask: HBITMAP; XMask, YMask: Integer; Rop: DWORD): Boolean;
begin
  if LWIsMainThread then Result := inherited MaskBlt(DestDC, X, Y, Width, Height, SrcDC, XSrc, YSrc, Mask, XMask, YMask, Rop) else Result := FVirtual.MaskBlt(DestDC, X, Y, Width, Height, SrcDC, XSrc, YSrc, Mask, XMask, YMask, Rop);
end;

function TLWProxyWidgetSet.MaskBlt(DestDC: HDC; X, Y, Width, Height: Integer; SrcDC: HDC; XSrc, YSrc: Integer; Mask: HBITMAP; XMask, YMask: Integer): Boolean; overload;
begin
  if LWIsMainThread then Result := inherited MaskBlt(DestDC, X, Y, Width, Height, SrcDC, XSrc, YSrc, Mask, XMask, YMask) else Result := FVirtual.MaskBlt(DestDC, X, Y, Width, Height, SrcDC, XSrc, YSrc, Mask, XMask, YMask);
end;

function TLWProxyWidgetSet.MessageBox(hWnd: HWND; lpText, lpCaption: PChar; uType: Cardinal): integer;
begin
  if LWIsMainThread then Result := inherited MessageBox(hWnd, lpText, lpCaption, uType) else Result := FVirtual.MessageBox(hWnd, lpText, lpCaption, uType);
end;

function TLWProxyWidgetSet.MonitorFromPoint(ptScreenCoords: TPoint; dwFlags: DWord): HMONITOR;
begin
  if LWIsMainThread then Result := inherited MonitorFromPoint(ptScreenCoords, dwFlags) else Result := FVirtual.MonitorFromPoint(ptScreenCoords, dwFlags);
end;

function TLWProxyWidgetSet.MonitorFromRect(lprcScreenCoords: PRect; dwFlags: DWord): HMONITOR;
begin
  if LWIsMainThread then Result := inherited MonitorFromRect(lprcScreenCoords, dwFlags) else Result := FVirtual.MonitorFromRect(lprcScreenCoords, dwFlags);
end;

function TLWProxyWidgetSet.MonitorFromWindow(hWnd: HWND; dwFlags: DWord): HMONITOR;
begin
  if LWIsMainThread then Result := inherited MonitorFromWindow(hWnd, dwFlags) else Result := FVirtual.MonitorFromWindow(hWnd, dwFlags);
end;

function TLWProxyWidgetSet.MoveToEx(DC: HDC; X, Y: Integer; OldPoint: PPoint): Boolean;
begin
  if LWIsMainThread then Result := inherited MoveToEx(DC, X, Y, OldPoint) else Result := FVirtual.MoveToEx(DC, X, Y, OldPoint);
end;

function TLWProxyWidgetSet.OffsetRgn(RGN: HRGN; nXOffset, nYOffset: Integer): Integer;
begin
  if LWIsMainThread then Result := inherited OffsetRgn(RGN, nXOffset, nYOffset) else Result := FVirtual.OffsetRgn(RGN, nXOffset, nYOffset);
end;

function TLWProxyWidgetSet.PaintRgn(DC: HDC; RGN: HRGN): Boolean;
begin
  if LWIsMainThread then Result := inherited PaintRgn(DC, RGN) else Result := FVirtual.PaintRgn(DC, RGN);
end;

function TLWProxyWidgetSet.PeekMessage(var lpMsg : TMsg; Handle : HWND; wMsgFilterMin, wMsgFilterMax,wRemoveMsg : UINT): Boolean;
begin
  if LWIsMainThread then Result := inherited PeekMessage(lpMsg, Handle, wMsgFilterMin, wMsgFilterMax, wRemoveMsg) else Result := FVirtual.PeekMessage(lpMsg, Handle, wMsgFilterMin, wMsgFilterMax, wRemoveMsg);
end;

function TLWProxyWidgetSet.Pie(DC: HDC; x1, y1, x2, y2, sx, sy, ex, ey: Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited Pie(DC, x1, y1, x2, y2, sx, sy, ex, ey) else Result := FVirtual.Pie(DC, x1, y1, x2, y2, sx, sy, ex, ey);
end;

function TLWProxyWidgetSet.PolyBezier(DC: HDC; Points: PPoint; NumPts: Integer; Filled, Continuous: boolean): boolean;
begin
  if LWIsMainThread then Result := inherited PolyBezier(DC, Points, NumPts, Filled, Continuous) else Result := FVirtual.PolyBezier(DC, Points, NumPts, Filled, Continuous);
end;

function TLWProxyWidgetSet.Polygon(DC: HDC; Points: PPoint; NumPts: Integer; Winding: boolean): boolean;
begin
  if LWIsMainThread then Result := inherited Polygon(DC, Points, NumPts, Winding) else Result := FVirtual.Polygon(DC, Points, NumPts, Winding);
end;

function TLWProxyWidgetSet.Polyline(DC: HDC; Points: PPoint; NumPts: Integer): boolean;
begin
  if LWIsMainThread then Result := inherited Polyline(DC, Points, NumPts) else Result := FVirtual.Polyline(DC, Points, NumPts);
end;

function TLWProxyWidgetSet.PostMessage(Handle: HWND; Msg: Cardinal; WParam: WParam; LParam: LParam): Boolean;
begin
  if LWIsMainThread then Result := inherited PostMessage(Handle, Msg, WParam, LParam) else Result := FVirtual.PostMessage(Handle, Msg, WParam, LParam);
end;

function TLWProxyWidgetSet.PtInRegion(RGN: HRGN; X, Y: Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited PtInRegion(RGN, X, Y) else Result := FVirtual.PtInRegion(RGN, X, Y);
end;

function TLWProxyWidgetSet.RealizePalette(DC: HDC): Cardinal;
begin
  if LWIsMainThread then Result := inherited RealizePalette(DC) else Result := FVirtual.RealizePalette(DC);
end;

function TLWProxyWidgetSet.Rectangle(DC: HDC; X1, Y1, X2, Y2: Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited Rectangle(DC, X1, Y1, X2, Y2) else Result := FVirtual.Rectangle(DC, X1, Y1, X2, Y2);
end;

function TLWProxyWidgetSet.RectInRegion(RGN: HRGN; ARect: TRect): Boolean;
begin
  if LWIsMainThread then Result := inherited RectInRegion(RGN, ARect) else Result := FVirtual.RectInRegion(RGN, ARect);
end;

function TLWProxyWidgetSet.RectVisible(DC: HDC; const ARect: TRect): Boolean;
begin
  if LWIsMainThread then Result := inherited RectVisible(DC, ARect) else Result := FVirtual.RectVisible(DC, ARect);
end;

function TLWProxyWidgetSet.RedrawWindow(Wnd: HWND; lprcUpdate: PRECT; hrgnUpdate: HRGN; flags: UINT): Boolean;
begin
  if LWIsMainThread then Result := inherited RedrawWindow(Wnd, lprcUpdate, hrgnUpdate, flags) else Result := FVirtual.RedrawWindow(Wnd, lprcUpdate, hrgnUpdate, flags);
end;

function TLWProxyWidgetSet.ReleaseCapture: Boolean;
begin
  if LWIsMainThread then Result := inherited ReleaseCapture() else Result := FVirtual.ReleaseCapture();
end;

function TLWProxyWidgetSet.ReleaseDC(hWnd: HWND; DC: HDC): Integer;
begin
  if LWIsMainThread then Result := inherited ReleaseDC(hWnd, DC) else Result := FVirtual.ReleaseDC(hWnd, DC);
end;

function TLWProxyWidgetSet.RemoveProp(Handle: HWND; Str: PChar): TLCLHandle;
begin
  if LWIsMainThread then Result := inherited RemoveProp(Handle, Str) else Result := FVirtual.RemoveProp(Handle, Str);
end;

function TLWProxyWidgetSet.RestoreDC(DC: HDC; SavedDC: Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited RestoreDC(DC, SavedDC) else Result := FVirtual.RestoreDC(DC, SavedDC);
end;

function TLWProxyWidgetSet.RoundRect(DC : hDC; X1, Y1, X2, Y2: Integer; RX,RY : Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited RoundRect(DC, X1, Y1, X2, Y2, RX, RY) else Result := FVirtual.RoundRect(DC, X1, Y1, X2, Y2, RX, RY);
end;

function TLWProxyWidgetSet.SaveDC(DC: HDC): Integer;
begin
  if LWIsMainThread then Result := inherited SaveDC(DC) else Result := FVirtual.SaveDC(DC);
end;

function TLWProxyWidgetSet.ScreenToClient(Handle : HWND; var P : TPoint): Integer;
begin
  if LWIsMainThread then Result := inherited ScreenToClient(Handle, P) else Result := FVirtual.ScreenToClient(Handle, P);
end;

function TLWProxyWidgetSet.ScrollWindowEx(hWnd: HWND; dx, dy: Integer; prcScroll, prcClip: PRect; hrgnUpdate: HRGN; prcUpdate: PRect; flags: UINT): Boolean;
begin
  if LWIsMainThread then Result := inherited ScrollWindowEx(hWnd, dx, dy, prcScroll, prcClip, hrgnUpdate, prcUpdate, flags) else Result := FVirtual.ScrollWindowEx(hWnd, dx, dy, prcScroll, prcClip, hrgnUpdate, prcUpdate, flags);
end;

function TLWProxyWidgetSet.SelectClipRGN(DC : hDC; RGN : HRGN): Longint;
begin
  if LWIsMainThread then Result := inherited SelectClipRGN(DC, RGN) else Result := FVirtual.SelectClipRGN(DC, RGN);
end;

function TLWProxyWidgetSet.SelectObject(DC: HDC; GDIObj: HGDIOBJ): HGDIOBJ;
begin
  if LWIsMainThread then Result := inherited SelectObject(DC, GDIObj) else Result := FVirtual.SelectObject(DC, GDIObj);
end;

function TLWProxyWidgetSet.SelectPalette(DC: HDC; Palette: HPALETTE; ForceBackground: Boolean): HPALETTE;
begin
  if LWIsMainThread then Result := inherited SelectPalette(DC, Palette, ForceBackground) else Result := FVirtual.SelectPalette(DC, Palette, ForceBackground);
end;

function TLWProxyWidgetSet.SendMessage(HandleWnd: HWND; Msg: Cardinal; WParam: WParam; LParam: LParam): LResult;
begin
  if LWIsMainThread then Result := inherited SendMessage(HandleWnd, Msg, WParam, LParam) else Result := FVirtual.SendMessage(HandleWnd, Msg, WParam, LParam);
end;

function TLWProxyWidgetSet.SetActiveWindow(Handle: HWND): HWND;
begin
  if LWIsMainThread then Result := inherited SetActiveWindow(Handle) else Result := FVirtual.SetActiveWindow(Handle);
end;

function TLWProxyWidgetSet.SetBkColor(DC: HDC; Color: TColorRef): TColorRef;
begin
  if LWIsMainThread then Result := inherited SetBkColor(DC, Color) else Result := FVirtual.SetBkColor(DC, Color);
end;

function TLWProxyWidgetSet.SetBkMode(DC: HDC; bkMode : Integer): Integer;
begin
  if LWIsMainThread then Result := inherited SetBkMode(DC, bkMode) else Result := FVirtual.SetBkMode(DC, bkMode);
end;

function TLWProxyWidgetSet.SetCapture(AHandle: HWND): HWND;
begin
  if LWIsMainThread then Result := inherited SetCapture(AHandle) else Result := FVirtual.SetCapture(AHandle);
end;

function TLWProxyWidgetSet.SetCaretPos(X, Y: Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited SetCaretPos(X, Y) else Result := FVirtual.SetCaretPos(X, Y);
end;

function TLWProxyWidgetSet.SetCaretPosEx(handle: HWnd; X, Y: Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited SetCaretPosEx(handle, X, Y) else Result := FVirtual.SetCaretPosEx(handle, X, Y);
end;

function TLWProxyWidgetSet.SetCursor(hCursor: HICON): HCURSOR;
begin
  if LWIsMainThread then Result := inherited SetCursor(hCursor) else Result := FVirtual.SetCursor(hCursor);
end;

function TLWProxyWidgetSet.SetCursorPos(X, Y: Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited SetCursorPos(X, Y) else Result := FVirtual.SetCursorPos(X, Y);
end;

function TLWProxyWidgetSet.SetFocus(hWnd: HWND): HWND;
begin
  if LWIsMainThread then Result := inherited SetFocus(hWnd) else Result := FVirtual.SetFocus(hWnd);
end;

function TLWProxyWidgetSet.SetForegroundWindow(hWnd : HWND): Boolean;
begin
  if LWIsMainThread then Result := inherited SetForegroundWindow(hWnd) else Result := FVirtual.SetForegroundWindow(hWnd);
end;

function TLWProxyWidgetSet.SetMapMode(DC: HDC; fnMapMode : Integer): Integer;
begin
  if LWIsMainThread then Result := inherited SetMapMode(DC, fnMapMode) else Result := FVirtual.SetMapMode(DC, fnMapMode);
end;

function TLWProxyWidgetSet.SetMenu(AWindowHandle: HWND; AMenuHandle: HMENU): Boolean;
begin
  if LWIsMainThread then Result := inherited SetMenu(AWindowHandle, AMenuHandle) else Result := FVirtual.SetMenu(AWindowHandle, AMenuHandle);
end;

function TLWProxyWidgetSet.SetParent(hWndChild: HWND; hWndParent: HWND): HWND;
begin
  if LWIsMainThread then Result := inherited SetParent(hWndChild, hWndParent) else Result := FVirtual.SetParent(hWndChild, hWndParent);
end;

function TLWProxyWidgetSet.SetProp(Handle: hwnd; Str : PChar; Data : Pointer): Boolean;
begin
  if LWIsMainThread then Result := inherited SetProp(Handle, Str, Data) else Result := FVirtual.SetProp(Handle, Str, Data);
end;

function TLWProxyWidgetSet.SetRectRgn(aRGN: HRGN; X1, Y1, X2, Y2 : Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited SetRectRgn(aRGN, X1, Y1, X2, Y2) else Result := FVirtual.SetRectRgn(aRGN, X1, Y1, X2, Y2);
end;

function TLWProxyWidgetSet.SetROP2(DC: HDC; Mode: Integer): Integer;
begin
  if LWIsMainThread then Result := inherited SetROP2(DC, Mode) else Result := FVirtual.SetROP2(DC, Mode);
end;

function TLWProxyWidgetSet.SetScrollInfo(Handle: HWND; SBStyle: Integer; ScrollInfo: TScrollInfo; Redraw : Boolean): Integer;
begin
  if LWIsMainThread then Result := inherited SetScrollInfo(Handle, SBStyle, ScrollInfo, Redraw) else Result := FVirtual.SetScrollInfo(Handle, SBStyle, ScrollInfo, Redraw);
end;

function TLWProxyWidgetSet.SetStretchBltMode(DC: HDC; StretchMode: Integer): Integer;
begin
  if LWIsMainThread then Result := inherited SetStretchBltMode(DC, StretchMode) else Result := FVirtual.SetStretchBltMode(DC, StretchMode);
end;

function TLWProxyWidgetSet.SetTextCharacterExtra(_hdc : hdc; nCharExtra : Integer): Integer;
begin
  if LWIsMainThread then Result := inherited SetTextCharacterExtra(_hdc, nCharExtra) else Result := FVirtual.SetTextCharacterExtra(_hdc, nCharExtra);
end;

function TLWProxyWidgetSet.SetTextColor(DC: HDC; Color: TColorRef): TColorRef;
begin
  if LWIsMainThread then Result := inherited SetTextColor(DC, Color) else Result := FVirtual.SetTextColor(DC, Color);
end;

function TLWProxyWidgetSet.SetWindowLong(Handle: HWND; Idx: Integer; NewLong : PtrInt): PtrInt;
begin
  if LWIsMainThread then Result := inherited SetWindowLong(Handle, Idx, NewLong) else Result := FVirtual.SetWindowLong(Handle, Idx, NewLong);
end;

function TLWProxyWidgetSet.SetViewPortExtEx(DC: HDC; XExtent, YExtent : Integer; OldSize: PSize): Boolean;
begin
  if LWIsMainThread then Result := inherited SetViewPortExtEx(DC, XExtent, YExtent, OldSize) else Result := FVirtual.SetViewPortExtEx(DC, XExtent, YExtent, OldSize);
end;

function TLWProxyWidgetSet.SetViewPortOrgEx(DC: HDC; NewX, NewY: Integer; OldPoint: PPoint): Boolean;
begin
  if LWIsMainThread then Result := inherited SetViewPortOrgEx(DC, NewX, NewY, OldPoint) else Result := FVirtual.SetViewPortOrgEx(DC, NewX, NewY, OldPoint);
end;

function TLWProxyWidgetSet.SetWindowExtEx(DC: HDC; XExtent, YExtent: Integer; OldSize: PSize): Boolean;
begin
  if LWIsMainThread then Result := inherited SetWindowExtEx(DC, XExtent, YExtent, OldSize) else Result := FVirtual.SetWindowExtEx(DC, XExtent, YExtent, OldSize);
end;

function TLWProxyWidgetSet.SetWindowOrgEx(dc : hdc; NewX, NewY: Integer; OldPoint: PPoint): Boolean;
begin
  if LWIsMainThread then Result := inherited SetWindowOrgEx(dc, NewX, NewY, OldPoint) else Result := FVirtual.SetWindowOrgEx(dc, NewX, NewY, OldPoint);
end;

function TLWProxyWidgetSet.SetWindowPos(hWnd: HWND; hWndInsertAfter: HWND; X, Y, cx, cy: Integer; uFlags: UINT): Boolean;
begin
  if LWIsMainThread then Result := inherited SetWindowPos(hWnd, hWndInsertAfter, X, Y, cx, cy, uFlags) else Result := FVirtual.SetWindowPos(hWnd, hWndInsertAfter, X, Y, cx, cy, uFlags);
end;

function TLWProxyWidgetSet.SetWindowRgn(hWnd: HWND; hRgn: HRGN; bRedraw: Boolean): longint;
begin
  if LWIsMainThread then Result := inherited SetWindowRgn(hWnd, hRgn, bRedraw) else Result := FVirtual.SetWindowRgn(hWnd, hRgn, bRedraw);
end;

function TLWProxyWidgetSet.ShowCaret(hWnd: HWND): Boolean;
begin
  if LWIsMainThread then Result := inherited ShowCaret(hWnd) else Result := FVirtual.ShowCaret(hWnd);
end;

function TLWProxyWidgetSet.ShowScrollBar(Handle: HWND; wBar: Integer; bShow: Boolean): Boolean;
begin
  if LWIsMainThread then Result := inherited ShowScrollBar(Handle, wBar, bShow) else Result := FVirtual.ShowScrollBar(Handle, wBar, bShow);
end;

function TLWProxyWidgetSet.ShowWindow(hWnd: HWND; nCmdShow: Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited ShowWindow(hWnd, nCmdShow) else Result := FVirtual.ShowWindow(hWnd, nCmdShow);
end;

function TLWProxyWidgetSet.StretchBlt(DestDC: HDC; X, Y, Width, Height: Integer; SrcDC: HDC; XSrc, YSrc, SrcWidth, SrcHeight: Integer; Rop: Cardinal): Boolean;
begin
  if LWIsMainThread then Result := inherited StretchBlt(DestDC, X, Y, Width, Height, SrcDC, XSrc, YSrc, SrcWidth, SrcHeight, Rop) else Result := FVirtual.StretchBlt(DestDC, X, Y, Width, Height, SrcDC, XSrc, YSrc, SrcWidth, SrcHeight, Rop);
end;

function TLWProxyWidgetSet.StretchDIBits(DC: HDC; DestX, DestY, DestWidth, DestHeight, SrcX, SrcY, SrcWidth, SrcHeight: Integer; Bits: Pointer; var BitsInfo: TBitmapInfo; Usage: UINT; Rop: DWORD): Integer;
begin
  if LWIsMainThread then Result := inherited StretchDIBits(DC, DestX, DestY, DestWidth, DestHeight, SrcX, SrcY, SrcWidth, SrcHeight, Bits, BitsInfo, Usage, Rop) else Result := FVirtual.StretchDIBits(DC, DestX, DestY, DestWidth, DestHeight, SrcX, SrcY, SrcWidth, SrcHeight, Bits, BitsInfo, Usage, Rop);
end;

function TLWProxyWidgetSet.SystemParametersInfo(uiAction: DWord; uiParam: DWord; pvParam: Pointer; fWinIni: DWord): LongBool;
begin
  if LWIsMainThread then Result := inherited SystemParametersInfo(uiAction, uiParam, pvParam, fWinIni) else Result := FVirtual.SystemParametersInfo(uiAction, uiParam, pvParam, fWinIni);
end;

function TLWProxyWidgetSet.TextOut(DC: HDC; X,Y : Integer; Str : Pchar; Count: Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited TextOut(DC, X, Y, Str, Count) else Result := FVirtual.TextOut(DC, X, Y, Str, Count);
end;

function TLWProxyWidgetSet.UpdateWindow(Handle: HWND): Boolean;
begin
  if LWIsMainThread then Result := inherited UpdateWindow(Handle) else Result := FVirtual.UpdateWindow(Handle);
end;

function TLWProxyWidgetSet.WindowFromPoint(Point : TPoint): HWND;
begin
  if LWIsMainThread then Result := inherited WindowFromPoint(Point) else Result := FVirtual.WindowFromPoint(Point);
end;

function TLWProxyWidgetSet.AddEventHandler(AHandle: TLCLHandle; AFlags: dword; AEventHandler: TWaitHandleEvent; AData: PtrInt): PEventHandler;
begin
  if LWIsMainThread then Result := inherited AddEventHandler(AHandle, AFlags, AEventHandler, AData) else Result := FVirtual.AddEventHandler(AHandle, AFlags, AEventHandler, AData);
end;

function TLWProxyWidgetSet.AddProcessEventHandler(AHandle: TLCLHandle; AEventHandler: TChildExitEvent; AData: PtrInt): PProcessEventHandler;
begin
  if LWIsMainThread then Result := inherited AddProcessEventHandler(AHandle, AEventHandler, AData) else Result := FVirtual.AddProcessEventHandler(AHandle, AEventHandler, AData);
end;

function TLWProxyWidgetSet.AddPipeEventHandler(AHandle: TLCLHandle; AEventHandler: TPipeEvent; AData: PtrInt): PPipeEventHandler;
begin
  if LWIsMainThread then Result := inherited AddPipeEventHandler(AHandle, AEventHandler, AData) else Result := FVirtual.AddPipeEventHandler(AHandle, AEventHandler, AData);
end;

function TLWProxyWidgetSet.AllocateHWnd(Method: TLCLWndMethod): HWND;
begin
  if LWIsMainThread then Result := inherited AllocateHWnd(Method) else Result := FVirtual.AllocateHWnd(Method);
end;

function TLWProxyWidgetSet.AskUser(const DialogCaption, DialogMessage: string; DialogType: LongInt; Buttons: TDialogButtons; HelpCtx: Longint): LongInt;
begin
  if LWIsMainThread then Result := inherited AskUser(DialogCaption, DialogMessage, DialogType, Buttons, HelpCtx) else Result := FVirtual.AskUser(DialogCaption, DialogMessage, DialogType, Buttons, HelpCtx);
end;

function TLWProxyWidgetSet.ClipboardFormatToMimeType(FormatID: TClipboardFormat): string;
begin
  if LWIsMainThread then Result := inherited ClipboardFormatToMimeType(FormatID) else Result := FVirtual.ClipboardFormatToMimeType(FormatID);
end;

function TLWProxyWidgetSet.ClipboardGetData(ClipboardType: TClipboardType; FormatID: TClipboardFormat; Stream: TStream): boolean;
begin
  if LWIsMainThread then Result := inherited ClipboardGetData(ClipboardType, FormatID, Stream) else Result := FVirtual.ClipboardGetData(ClipboardType, FormatID, Stream);
end;

function TLWProxyWidgetSet.ClipboardGetFormats(ClipboardType: TClipboardType; var Count: integer; var List: PClipboardFormat): boolean;
begin
  if LWIsMainThread then Result := inherited ClipboardGetFormats(ClipboardType, Count, List) else Result := FVirtual.ClipboardGetFormats(ClipboardType, Count, List);
end;

function TLWProxyWidgetSet.ClipboardGetOwnerShip(ClipboardType: TClipboardType; OnRequestProc: TClipboardRequestEvent; FormatCount: integer; Formats: PClipboardFormat): boolean;
begin
  if LWIsMainThread then Result := inherited ClipboardGetOwnerShip(ClipboardType, OnRequestProc, FormatCount, Formats) else Result := FVirtual.ClipboardGetOwnerShip(ClipboardType, OnRequestProc, FormatCount, Formats);
end;

function TLWProxyWidgetSet.ClipboardRegisterFormat(const AMimeType: string): TClipboardFormat;
begin
  if LWIsMainThread then Result := inherited ClipboardRegisterFormat(AMimeType) else Result := FVirtual.ClipboardRegisterFormat(AMimeType);
end;

function TLWProxyWidgetSet.ClipboardFormatNeedsNullByte(const AFormat: TPredefinedClipboardFormat): Boolean;
begin
  if LWIsMainThread then Result := inherited ClipboardFormatNeedsNullByte(AFormat) else Result := FVirtual.ClipboardFormatNeedsNullByte(AFormat);
end;

function TLWProxyWidgetSet.CreateEmptyRegion: hRGN;
begin
  if LWIsMainThread then Result := inherited CreateEmptyRegion() else Result := FVirtual.CreateEmptyRegion();
end;

function TLWProxyWidgetSet.CreatePixmapIndirect(const Data: Pointer; const TransColor: Longint): HBITMAP;
begin
  if LWIsMainThread then Result := inherited CreatePixmapIndirect(Data, TransColor) else Result := FVirtual.CreatePixmapIndirect(Data, TransColor);
end;

function TLWProxyWidgetSet.CreateRegionCopy(SrcRGN: hRGN): hRGN;
begin
  if LWIsMainThread then Result := inherited CreateRegionCopy(SrcRGN) else Result := FVirtual.CreateRegionCopy(SrcRGN);
end;

function TLWProxyWidgetSet.CreateRubberBand(const ARect: TRect; const ABrush: HBrush): HWND;
begin
  if LWIsMainThread then Result := inherited CreateRubberBand(ARect, ABrush) else Result := FVirtual.CreateRubberBand(ARect, ABrush);
end;

function TLWProxyWidgetSet.CreateStandardCursor(ACursor: SmallInt): hCursor;
begin
  if LWIsMainThread then Result := inherited CreateStandardCursor(ACursor) else Result := FVirtual.CreateStandardCursor(ACursor);
end;

function TLWProxyWidgetSet.DCClipRegionValid(DC: HDC): boolean;
begin
  if LWIsMainThread then Result := inherited DCClipRegionValid(DC) else Result := FVirtual.DCClipRegionValid(DC);
end;

procedure TLWProxyWidgetSet.DeallocateHWnd(Wnd: HWND);
begin
  if LWIsMainThread then inherited DeallocateHWnd(Wnd) else FVirtual.DeallocateHWnd(Wnd);
end;

procedure TLWProxyWidgetSet.DestroyRubberBand(ARubberBand: HWND);
begin
  if LWIsMainThread then inherited DestroyRubberBand(ARubberBand) else FVirtual.DestroyRubberBand(ARubberBand);
end;

procedure TLWProxyWidgetSet.DrawDefaultDockImage(AOldRect, ANewRect: TRect; AOperation: TDockImageOperation);
begin
  if LWIsMainThread then inherited DrawDefaultDockImage(AOldRect, ANewRect, AOperation) else FVirtual.DrawDefaultDockImage(AOldRect, ANewRect, AOperation);
end;

procedure TLWProxyWidgetSet.DrawGrid(DC: HDC; const R: TRect; DX, DY: Integer);
begin
  if LWIsMainThread then inherited DrawGrid(DC, R, DX, DY) else FVirtual.DrawGrid(DC, R, DX, DY);
end;

function TLWProxyWidgetSet.ExtUTF8Out(DC: HDC; X, Y: Integer; Options: Longint; Rect: PRect; Str: PChar; Count: Longint; Dx: PInteger): Boolean;
begin
  if LWIsMainThread then Result := inherited ExtUTF8Out(DC, X, Y, Options, Rect, Str, Count, Dx) else Result := FVirtual.ExtUTF8Out(DC, X, Y, Options, Rect, Str, Count, Dx);
end;

function TLWProxyWidgetSet.FontIsMonoSpace(Font: HFont): boolean;
begin
  if LWIsMainThread then Result := inherited FontIsMonoSpace(Font) else Result := FVirtual.FontIsMonoSpace(Font);
end;

function TLWProxyWidgetSet.Frame3d(DC: HDC; var ARect: TRect; const FrameWidth : integer; const Style : TGraphicsBevelCut): Boolean;
begin
  if LWIsMainThread then Result := inherited Frame3d(DC, ARect, FrameWidth, Style) else Result := FVirtual.Frame3d(DC, ARect, FrameWidth, Style);
end;

function TLWProxyWidgetSet.GetAcceleratorString(const AVKey: Byte; const AShiftState: TShiftState): String;
begin
  if LWIsMainThread then Result := inherited GetAcceleratorString(AVKey, AShiftState) else Result := FVirtual.GetAcceleratorString(AVKey, AShiftState);
end;

function TLWProxyWidgetSet.GetAvailableNativeCanvasTypes(DC: HDC; AAllowFallbackToParent: Boolean): TNativeCanvasTypes;
begin
  if LWIsMainThread then Result := inherited GetAvailableNativeCanvasTypes(DC, AAllowFallbackToParent) else Result := FVirtual.GetAvailableNativeCanvasTypes(DC, AAllowFallbackToParent);
end;

function TLWProxyWidgetSet.GetAvailableNativeHandleTypes(Handle: HWND; AAllowFallbackToParent: Boolean): TNativeHandleTypes;
begin
  if LWIsMainThread then Result := inherited GetAvailableNativeHandleTypes(Handle, AAllowFallbackToParent) else Result := FVirtual.GetAvailableNativeHandleTypes(Handle, AAllowFallbackToParent);
end;

function TLWProxyWidgetSet.GetCaretRespondToFocus(handle: HWND; var ShowHideOnFocus: boolean): Boolean;
begin
  if LWIsMainThread then Result := inherited GetCaretRespondToFocus(handle, ShowHideOnFocus) else Result := FVirtual.GetCaretRespondToFocus(handle, ShowHideOnFocus);
end;

function TLWProxyWidgetSet.GetClientBounds(handle : HWND; var ARect: TRect): Boolean;
begin
  if LWIsMainThread then Result := inherited GetClientBounds(handle, ARect) else Result := FVirtual.GetClientBounds(handle, ARect);
end;

function TLWProxyWidgetSet.GetCmdLineParamDescForInterface: TStringList;
begin
  if LWIsMainThread then Result := inherited GetCmdLineParamDescForInterface() else Result := FVirtual.GetCmdLineParamDescForInterface();
end;

function TLWProxyWidgetSet.GetControlConstraints(Constraints: TObject): boolean;
begin
  if LWIsMainThread then Result := inherited GetControlConstraints(Constraints) else Result := FVirtual.GetControlConstraints(Constraints);
end;

function TLWProxyWidgetSet.GetDCOriginRelativeToWindow(PaintDC: HDC; WindowHandle: HWND; var OriginDiff: TPoint): boolean;
begin
  if LWIsMainThread then Result := inherited GetDCOriginRelativeToWindow(PaintDC, WindowHandle, OriginDiff) else Result := FVirtual.GetDCOriginRelativeToWindow(PaintDC, WindowHandle, OriginDiff);
end;

function TLWProxyWidgetSet.GetDesignerDC(WindowHandle: HWND): HDC;
begin
  if LWIsMainThread then Result := inherited GetDesignerDC(WindowHandle) else Result := FVirtual.GetDesignerDC(WindowHandle);
end;

function TLWProxyWidgetSet.GetDeviceSize(DC: HDC; var p: TPoint): boolean;
begin
  if LWIsMainThread then Result := inherited GetDeviceSize(DC, p) else Result := FVirtual.GetDeviceSize(DC, p);
end;

function TLWProxyWidgetSet.GetLCLOwnerObject(Handle: HWnd): TObject;
begin
  if LWIsMainThread then Result := inherited GetLCLOwnerObject(Handle) else Result := FVirtual.GetLCLOwnerObject(Handle);
end;

function TLWProxyWidgetSet.GetNativeCanvas(DC: HDC; AHandleType: TNativeCanvasType; AAllowFallbackToParent: Boolean): PtrInt;
begin
  if LWIsMainThread then Result := inherited GetNativeCanvas(DC, AHandleType, AAllowFallbackToParent) else Result := FVirtual.GetNativeCanvas(DC, AHandleType, AAllowFallbackToParent);
end;

function TLWProxyWidgetSet.GetNativeHandle(Handle: HWND; AHandleType: TNativeHandleType; AAllowFallbackToParent: Boolean): PtrInt;
begin
  if LWIsMainThread then Result := inherited GetNativeHandle(Handle, AHandleType, AAllowFallbackToParent) else Result := FVirtual.GetNativeHandle(Handle, AHandleType, AAllowFallbackToParent);
end;

function TLWProxyWidgetSet.GetScrollBarSize(Handle: HWND; SBStyle: Integer): integer;
begin
  if LWIsMainThread then Result := inherited GetScrollBarSize(Handle, SBStyle) else Result := FVirtual.GetScrollBarSize(Handle, SBStyle);
end;

function TLWProxyWidgetSet.GetScrollbarVisible(Handle: HWND; SBStyle: Integer): boolean;
begin
  if LWIsMainThread then Result := inherited GetScrollbarVisible(Handle, SBStyle) else Result := FVirtual.GetScrollbarVisible(Handle, SBStyle);
end;

function TLWProxyWidgetSet.GetWindowRelativePosition(Handle : hwnd; var Left, Top: integer): boolean;
begin
  if LWIsMainThread then Result := inherited GetWindowRelativePosition(Handle, Left, Top) else Result := FVirtual.GetWindowRelativePosition(Handle, Left, Top);
end;

function TLWProxyWidgetSet.InvalidateFrame(aHandle : HWND; ARect : pRect; bErase : Boolean; BorderWidth: integer): Boolean;
begin
  if LWIsMainThread then Result := inherited InvalidateFrame(aHandle, ARect, bErase, BorderWidth) else Result := FVirtual.InvalidateFrame(aHandle, ARect, bErase, BorderWidth);
end;

function TLWProxyWidgetSet.IsDesignerDC(WindowHandle: HWND; DC: HDC): Boolean;
begin
  if LWIsMainThread then Result := inherited IsDesignerDC(WindowHandle, DC) else Result := FVirtual.IsDesignerDC(WindowHandle, DC);
end;

function TLWProxyWidgetSet.IsMobilePlatform: Boolean;
begin
  if LWIsMainThread then Result := inherited IsMobilePlatform() else Result := FVirtual.IsMobilePlatform();
end;

function TLWProxyWidgetSet.IsCDIntfControl(AWinControl: TObject): Boolean;
begin
  if LWIsMainThread then Result := inherited IsCDIntfControl(AWinControl) else Result := FVirtual.IsCDIntfControl(AWinControl);
end;

function TLWProxyWidgetSet.MoveWindowOrgEx(dc : hdc; dX,dY : Integer): boolean;
begin
  if LWIsMainThread then Result := inherited MoveWindowOrgEx(dc, dX, dY) else Result := FVirtual.MoveWindowOrgEx(dc, dX, dY);
end;

function TLWProxyWidgetSet.PromptUser(const DialogCaption, DialogMessage : String; DialogType : longint; Buttons : PLongint; ButtonCount, DefaultIndex, EscapeResult : Longint): Longint;
begin
  if LWIsMainThread then Result := inherited PromptUser(DialogCaption, DialogMessage, DialogType, Buttons, ButtonCount, DefaultIndex, EscapeResult) else Result := FVirtual.PromptUser(DialogCaption, DialogMessage, DialogType, Buttons, ButtonCount, DefaultIndex, EscapeResult);
end;

function TLWProxyWidgetSet.PromptUserAtXY(const DialogCaption, DialogMessage : String; DialogType : longint; Buttons : PLongint; ButtonCount, DefaultIndex, EscapeResult : Longint; X, Y : Longint): Longint;
begin
  if LWIsMainThread then Result := inherited PromptUserAtXY(DialogCaption, DialogMessage, DialogType, Buttons, ButtonCount, DefaultIndex, EscapeResult, X, Y) else Result := FVirtual.PromptUserAtXY(DialogCaption, DialogMessage, DialogType, Buttons, ButtonCount, DefaultIndex, EscapeResult, X, Y);
end;

function TLWProxyWidgetSet.RadialArc(DC: HDC; left, top, right, bottom, sx, sy, ex, ey : Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited RadialArc(DC, left, top, right, bottom, sx, sy, ex, ey) else Result := FVirtual.RadialArc(DC, left, top, right, bottom, sx, sy, ex, ey);
end;

function TLWProxyWidgetSet.RadialChord(DC: HDC; x1, y1, x2, y2, sx, sy, ex, ey : Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited RadialChord(DC, x1, y1, x2, y2, sx, sy, ex, ey) else Result := FVirtual.RadialChord(DC, x1, y1, x2, y2, sx, sy, ex, ey);
end;

function TLWProxyWidgetSet.RadialPie(DC: HDC; x1, y1, x2, y2, Angle1, Angle2: Integer): Boolean;
begin
  if LWIsMainThread then Result := inherited RadialPie(DC, x1, y1, x2, y2, Angle1, Angle2) else Result := FVirtual.RadialPie(DC, x1, y1, x2, y2, Angle1, Angle2);
end;

function TLWProxyWidgetSet.RawImage_CreateBitmaps(const ARawImage: TRawImage; out ABitmap, AMask: HBitmap; ASkipMask: Boolean): Boolean;
begin
  if LWIsMainThread then Result := inherited RawImage_CreateBitmaps(ARawImage, ABitmap, AMask, ASkipMask) else Result := FVirtual.RawImage_CreateBitmaps(ARawImage, ABitmap, AMask, ASkipMask);
end;

function TLWProxyWidgetSet.RawImage_DescriptionFromBitmap(ABitmap: HBITMAP; out ADesc: TRawImageDescription): Boolean;
begin
  if LWIsMainThread then Result := inherited RawImage_DescriptionFromBitmap(ABitmap, ADesc) else Result := FVirtual.RawImage_DescriptionFromBitmap(ABitmap, ADesc);
end;

function TLWProxyWidgetSet.RawImage_DescriptionFromDevice(ADC: HDC; out ADesc: TRawImageDescription): Boolean;
begin
  if LWIsMainThread then Result := inherited RawImage_DescriptionFromDevice(ADC, ADesc) else Result := FVirtual.RawImage_DescriptionFromDevice(ADC, ADesc);
end;

function TLWProxyWidgetSet.RawImage_FromBitmap(out ARawImage: TRawImage; ABitmap, AMask: HBITMAP; ARect: PRect): Boolean;
begin
  if LWIsMainThread then Result := inherited RawImage_FromBitmap(ARawImage, ABitmap, AMask, ARect) else Result := FVirtual.RawImage_FromBitmap(ARawImage, ABitmap, AMask, ARect);
end;

function TLWProxyWidgetSet.RawImage_FromDevice(out ARawImage: TRawImage; ADC: HDC; const ARect: TRect): Boolean;
begin
  if LWIsMainThread then Result := inherited RawImage_FromDevice(ARawImage, ADC, ARect) else Result := FVirtual.RawImage_FromDevice(ARawImage, ADC, ARect);
end;

function TLWProxyWidgetSet.RawImage_QueryDescription(AFlags: TRawImageQueryFlags; var ADesc: TRawImageDescription): Boolean;
begin
  if LWIsMainThread then Result := inherited RawImage_QueryDescription(AFlags, ADesc) else Result := FVirtual.RawImage_QueryDescription(AFlags, ADesc);
end;

function TLWProxyWidgetSet.RegroupMenuItem(hndMenu: HMENU; GroupIndex: integer): Boolean;
begin
  if LWIsMainThread then Result := inherited RegroupMenuItem(hndMenu, GroupIndex) else Result := FVirtual.RegroupMenuItem(hndMenu, GroupIndex);
end;

function TLWProxyWidgetSet.ReleaseDesignerDC(hWnd: HWND; DC: HDC): Integer;
begin
  if LWIsMainThread then Result := inherited ReleaseDesignerDC(hWnd, DC) else Result := FVirtual.ReleaseDesignerDC(hWnd, DC);
end;

procedure TLWProxyWidgetSet.RemoveEventHandler(var AHandler: PEventHandler);
begin
  if LWIsMainThread then inherited RemoveEventHandler(AHandler) else FVirtual.RemoveEventHandler(AHandler);
end;

procedure TLWProxyWidgetSet.RemoveProcessEventHandler(var AHandler: PProcessEventHandler);
begin
  if LWIsMainThread then inherited RemoveProcessEventHandler(AHandler) else FVirtual.RemoveProcessEventHandler(AHandler);
end;

procedure TLWProxyWidgetSet.RemovePipeEventHandler(var AHandler: PPipeEventHandler);
begin
  if LWIsMainThread then inherited RemovePipeEventHandler(AHandler) else FVirtual.RemovePipeEventHandler(AHandler);
end;

function TLWProxyWidgetSet.RequestInput(const InputCaption, InputPrompt : String; MaskInput : Boolean; var Value : String): Boolean;
begin
  if LWIsMainThread then Result := inherited RequestInput(InputCaption, InputPrompt, MaskInput, Value) else Result := FVirtual.RequestInput(InputCaption, InputPrompt, MaskInput, Value);
end;

procedure TLWProxyWidgetSet.SendCachedLCLMessages;
begin
  if LWIsMainThread then inherited SendCachedLCLMessages() else FVirtual.SendCachedLCLMessages();
end;

function TLWProxyWidgetSet.SetCaretRespondToFocus(handle: HWND; ShowHideOnFocus: boolean): Boolean;
begin
  if LWIsMainThread then Result := inherited SetCaretRespondToFocus(handle, ShowHideOnFocus) else Result := FVirtual.SetCaretRespondToFocus(handle, ShowHideOnFocus);
end;

function TLWProxyWidgetSet.SetComboMinDropDownSize(Handle: HWND; MinItemsWidth, MinItemsHeight, MinItemCount: integer): boolean;
begin
  if LWIsMainThread then Result := inherited SetComboMinDropDownSize(Handle, MinItemsWidth, MinItemsHeight, MinItemCount) else Result := FVirtual.SetComboMinDropDownSize(Handle, MinItemsWidth, MinItemsHeight, MinItemCount);
end;

procedure TLWProxyWidgetSet.SetEventHandlerFlags(AHandler: PEventHandler; NewFlags: dword);
begin
  if LWIsMainThread then inherited SetEventHandlerFlags(AHandler, NewFlags) else FVirtual.SetEventHandlerFlags(AHandler, NewFlags);
end;

procedure TLWProxyWidgetSet.SetRubberBandRect(const ARubberBand: HWND; const ARect: TRect);
begin
  if LWIsMainThread then inherited SetRubberBandRect(ARubberBand, ARect) else FVirtual.SetRubberBandRect(ARubberBand, ARect);
end;

function TLWProxyWidgetSet.ShowSelectItemDialog(const AItems: TStrings; APos: TPoint): Boolean;
begin
  if LWIsMainThread then Result := inherited ShowSelectItemDialog(AItems, APos) else Result := FVirtual.ShowSelectItemDialog(AItems, APos);
end;

function TLWProxyWidgetSet.StretchMaskBlt(DestDC: HDC; X, Y, Width, Height: Integer; SrcDC: HDC; XSrc, YSrc, SrcWidth, SrcHeight: Integer; Mask: HBITMAP; XMask, YMask: Integer; Rop: DWORD): Boolean;
begin
  if LWIsMainThread then Result := inherited StretchMaskBlt(DestDC, X, Y, Width, Height, SrcDC, XSrc, YSrc, SrcWidth, SrcHeight, Mask, XMask, YMask, Rop) else Result := FVirtual.StretchMaskBlt(DestDC, X, Y, Width, Height, SrcDC, XSrc, YSrc, SrcWidth, SrcHeight, Mask, XMask, YMask, Rop);
end;

function TLWProxyWidgetSet.TextUTF8Out(DC: HDC; X, Y: Integer; Str: PChar; Count: Longint): Boolean;
begin
  if LWIsMainThread then Result := inherited TextUTF8Out(DC, X, Y, Str, Count) else Result := FVirtual.TextUTF8Out(DC, X, Y, Str, Count);
end;

{ ---------------- 安装 ---------------- }

procedure ForceWSFactoryHooks;
{ 把所有家族的 WS 注册钩子先跑一遍：工厂（gtk2/win32）当场注册真实类并
  置位一次性 Done 标志，之后不会再覆盖我们的代理注册 }
begin
  WSRegisterControl; WSRegisterWinControl; WSRegisterGraphicControl; WSRegisterCustomControl;
  WSRegisterScrollingWinControl; WSRegisterScrollBox; WSRegisterCustomFrame;
  WSRegisterCustomForm; WSRegisterHintWindow;
  WSRegisterCustomScrollBar; WSRegisterCustomGroupBox; WSRegisterCustomComboBox;
  WSRegisterCustomListBox; WSRegisterCustomEdit; WSRegisterCustomMemo;
  WSRegisterButtonControl; WSRegisterCustomButton; WSRegisterCustomCheckBox;
  WSRegisterToggleBox; WSRegisterRadioButton; WSRegisterCustomStaticText;
  WSRegisterCustomLabel;
  WSRegisterStatusBar; WSRegisterTabSheet; WSRegisterPageControl; WSRegisterCustomListView;
  WSRegisterCustomProgressBar; WSRegisterCustomUpDown; WSRegisterCustomToolButton;
  WSRegisterToolBar; WSRegisterCustomTrackBar; WSRegisterCustomTreeView;
  WSRegisterCustomPage; WSRegisterCustomNotebook; WSRegisterCustomShape;
  WSRegisterCustomSplitter; WSRegisterPaintBox; WSRegisterCustomImage; WSRegisterBevel;
  WSRegisterCustomRadioGroup; WSRegisterCustomCheckGroup; WSRegisterCustomLabeledEdit;
  WSRegisterCustomPanel; WSRegisterCustomTrayIcon;
  WSRegisterCustomCalendar;
  WSRegisterCommonDialog; WSRegisterFileDialog; WSRegisterOpenDialog; WSRegisterSaveDialog;
  WSRegisterSelectDirectoryDialog; WSRegisterColorDialog; WSRegisterColorButton;
  WSRegisterFontDialog; WSRegisterTaskDialog;
  WSRegisterCustomBitBtn; WSRegisterCustomSpeedButton;
  WSRegisterCustomCheckListBox;
  WSRegisterCustomGrid;
  WSRegisterMenuItem; WSRegisterMenu; WSRegisterMainMenu; WSRegisterPopupMenu;
  WSRegisterCustomImageListResolution; WSRegisterDragImageListResolution;
  WSRegisterCustomFloatSpinEdit;
  WSRegisterLazAccessibleObject;
end;

{ 深拷贝 FindWSComponentClass 返回的 VClass：FPC 的类 VMT 全部在正偏移，
  vmtMethodStart 起是虚方法指针数组、以 nil 结尾，拷贝 [0 .. 表尾) 即得一个
  可正常派发虚方法的静态快照（块内指针仍指向原类的静态数据，永久有效）。
  节点 VClass 会被 CreateVClass 原地改写，快照不受影响。 }
function CopyVClass(P: TClass): TClass;
type
  TPtrArr = array[0..0] of Pointer;
  PPtrArr = ^TPtrArr;
var
  vmt: PPtrArr;
  n, size: Integer;
  q: Pointer;
begin
  Result := nil;
  if P = nil then Exit;
  vmt := PPtrArr(PByte(P) + vmtMethodStart);
  n := 0;
  while vmt^[n] <> nil do Inc(n);
  size := vmtMethodStart + (n + 1) * SizeOf(Pointer);
  GetMem(q, size);
  Move(Pointer(P)^, q^, size);
  Result := TClass(q);
end;

procedure SwapWSClasses;
begin
  { 面板家族：捕获真实类 + 注册按线程路由的代理类。
    注意 FindWSComponentClass 返回的是注册节点的 VClass（运行时构建的
    唯一内存块）：RegisterWSComponent 换 WSClass 时 CreateVClass 会
    原地 Move 改写这块内存，先捕获的指针随即"变成"代理类自身，
    主线程路由调用它就无限递归。必须 CopyVClass 拍静态快照。 }
  GRealWinControl := TWSWinControlClass(CopyVClass(FindWSComponentClass(TWinControl)));
  RegisterWSComponent(TWinControl, TLWWSWinControl);
  GRealCustomForm := TWSCustomFormClass(CopyVClass(FindWSComponentClass(TCustomForm)));
  RegisterWSComponent(TCustomForm, TLWWSCustomForm);
  GRealCustomMemo := TWSCustomMemoClass(CopyVClass(FindWSComponentClass(TCustomMemo)));
  RegisterWSComponent(TCustomMemo, TLWWSCustomMemo);
  GRealCustomButton := TWSButtonClass(CopyVClass(FindWSComponentClass(TCustomButton)));
  RegisterWSComponent(TCustomButton, TLWWSCustomButton);
  GRealStatusBar := TWSStatusBarClass(CopyVClass(FindWSComponentClass(TStatusBar)));
  RegisterWSComponent(TStatusBar, TLWWSStatusBar);
  GRealMenuItem := TWSMenuItemClass(CopyVClass(FindWSComponentClass(TMenuItem)));
  RegisterWSComponent(TMenuItem, TLWWSMenuItem);
  GRealMenu := TWSMenuClass(CopyVClass(FindWSComponentClass(TMenu)));
  RegisterWSComponent(TMenu, TLWWSMenu);
  GRealMainMenu := TWSMenuClass(CopyVClass(FindWSComponentClass(TMainMenu)));
  RegisterWSComponent(TMainMenu, TLWWSMainMenu);
  GRealPopupMenu := TWSPopupMenuClass(CopyVClass(FindWSComponentClass(TPopupMenu)));
  RegisterWSComponent(TPopupMenu, TLWWSPopupMenu);
  { 会话专用家族：一律空实现（等价 nogui） }
  RegisterWSComponent(TCustomEdit, TWSCustomEdit);
  RegisterWSComponent(TCustomComboBox, TWSCustomComboBox);
  RegisterWSComponent(TCustomListBox, TWSCustomListBox);
  RegisterWSComponent(TCustomScrollBar, TWSScrollBar);
  RegisterWSComponent(TCustomGroupBox, TWSCustomGroupBox);
  RegisterWSComponent(TCustomCheckBox, TWSCustomCheckBox);
  RegisterWSComponent(TToggleBox, TWSToggleBox);
  RegisterWSComponent(TRadioButton, TWSRadioButton);
  RegisterWSComponent(TCustomStaticText, TWSCustomStaticText);
  RegisterWSComponent(TCustomPage, TWSCustomPage);
  RegisterWSComponent(TCustomBitBtn, TWSBitBtn);
  RegisterWSComponent(TCustomCheckListBox, TWSCustomCheckListBox);
  RegisterWSComponent(TCustomGrid, TWSCustomGrid);
  RegisterWSComponent(TCustomFloatSpinEdit, TWSCustomFloatSpinEdit);
  RegisterWSComponent(TCustomCalendar, TWSCustomCalendar);
  RegisterWSComponent(TCustomListView, TWSCustomListView);
  RegisterWSComponent(TCustomProgressBar, TWSProgressBar);
  RegisterWSComponent(TToolBar, TWSToolBar);
  RegisterWSComponent(TCustomTrackBar, TWSTrackBar);
  RegisterWSComponent(TScrollingWinControl, TWSScrollingWinControl);
  RegisterWSComponent(TCommonDialog, TWSCommonDialog);
  RegisterWSComponent(TFileDialog, TWSFileDialog);
  RegisterWSComponent(TOpenDialog, TWSOpenDialog);
  RegisterWSComponent(TColorDialog, TWSColorDialog);
  RegisterWSComponent(TFontDialog, TWSFontDialog);
end;

procedure LWInstallProxyWidgetSet;
var
  OldWS: TWidgetSet;
begin
  if GInstalled then Exit;
  GInstalled := True;
  { LAYER 1：装代理实例（继承具体 widgetset 类，构造函数自行完成初始化；
    旧实例不释放，泄漏一个对象无妨 —— 与 nogui 部署档一致）。
    工作线程的无头实现 }
  FVirtual := TLWVirtualWS.Create;
  OldWS := WidgetSet;
  WidgetSet := TLWProxyWidgetSet.Create;
  { AppHandle 过户：Application.Initialize 先于安装，AppInit 已在旧实例上
    建好 AppHandle 隐藏窗口（AppInit 内部有 Done 静态标志，重放是 no-op，
    代理实例的 AppHandle 必为 0）。而 win32 接口大量代码按
    TWin32WidgetSet(WidgetSet) 硬转型读代理的 AppHandle（典型：
    InitializePreferredStatusBarHeight），为 0 时 WS_CHILD 窗口 parent=0
    创建失败（error 1406）抛异常 -> GServer 被 finally 释放，accept 后台
    线程仍握着它 -> 悬挂对象堆损坏。AppHandle 属性 public，直接过户。 }
  WidgetSet.AppHandle := OldWS.AppHandle;
  { LAYER 2：强制工厂注册 -> 捕获真实类 -> 覆盖为路由/空实现 }
  ForceWSFactoryHooks;
  SwapWSClasses;
end;

end.
