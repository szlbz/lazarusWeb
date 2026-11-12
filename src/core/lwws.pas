{
  lazarusWeb :: lwws
  ------------------------------------------------------------------
  nogui widgetset 补丁。

  发现的问题（实测）：LCL 的 TCustomForm.AfterConstruction 里有一句
      MonPPI := Monitor.PixelsPerInch;
  而 nogui widgetset 的 EnumDisplayMonitors 直接返回 False，
  于是屏幕上一个显示器都没有，Monitor 为 nil —— 只要创建 TForm 必崩。

  这个单元给 TNoGUIWidgetSet 补一个"虚拟显示器"（默认 1920x1080 @96DPI），
  让 TForm 能够正常构造。服务端本来也不需要真实显示器。
  如果以后要支持"按客户端分辨率自适应"，改这里的常量即可。

  ------------------------------------------------------------------
  为什么整段补丁要用 LCLnogui 条件编译（$IFDEF）包起来：

  noguiint 是 LCL 内部的 widgetset 单元，只在 LCL 按 nogui 编译时才有 .ppu，
  而且 lcl.lpk 里它的 AddToUsesPkgSection = False（即包编辑器里 "Use Unit"
  一栏没有勾），所以 LCL 不会把这个目录传给依赖它的包。于是在别的 widgetset
  下编译本包（典型场景：在 IDE 里直接编译，IDE 自己是 win32）就会报
      lwws.pas(31,3) Error: Can't find unit noguiint used by lwws
      ... Enable flag "Use Unit" of unit noguiint in package LCL

  正确的做法不是去改 LCL 的包（那会让 IDE 自带包被视为已修改，风险很大），
  而是让本单元在非 nogui 下退化成空实现 —— 真实 widgetset 本来就有完整的
  显示器 / 画布实现，压根不需要这套补丁。
}
unit lwws;

{$mode objfpc}{$H+}

interface

{ 安装补丁 widgetset；必须在 Application.Initialize 之后、创建任何窗体之前调用 }
procedure LWInstallWidgetSet;

{ 调整虚拟显示器尺寸（默认 1920x1080） }
procedure LWSetVirtualScreen(AWidth, AHeight: Integer);

implementation

{ LCLnogui 由 lazbuild --ws=nogui（以及 IDE 的 nogui 构建模式）自动下发 }

{$IFDEF LCLnogui}

uses
  Classes, SysUtils, Math, Types, Graphics, LCLType, InterfaceBase, Forms,
  noguiint, Menus, WSMenus, WSLCLClasses;

const
  LW_MONITOR_HANDLE = HMONITOR(1);
  MONITORINFOF_PRIMARY_LW = 1;

type
  TLWWidgetSet = class(TNoGUIWidgetSet)
  public
    function EnumDisplayMonitors(hdc: HDC; lprcClip: PRect; lpfnEnum: MonitorEnumProc;
      dwData: LPARAM): LongBool; override;
    function GetMonitorInfo(hMonitor: HMONITOR; lpmi: PMonitorInfo): Boolean; override;
    function MonitorFromWindow(hWnd: HWND; dwFlags: DWord): HMONITOR; override;
    function MonitorFromPoint(pt: TPoint; dwFlags: DWord): HMONITOR; override;
    function GetDpiForMonitor(hmonitor: HMONITOR; dpiType: TMonitorDpiType;
      out dpiX: UINT; out dpiY: UINT): HRESULT; override;

    { ---- 虚拟画布：nogui 没有任何 GDI 实现，网格等控件创建时要量字高 ---- }
    function CreateCompatibleDC(DC: HDC): HDC; override;
    function DeleteDC(hDC: HDC): Boolean; override;
    function SelectObject(DC: HDC; GDIObj: HGDIOBJ): HGDIOBJ; override;
    function CreateFontIndirect(const LogFont: TLogFont): HFONT; override;
    function CreateFontIndirectEx(const LogFont: TLogFont; const LongFontName: string): HFONT; override;
    function GetTextExtentPoint32(DC: HDC; Str: PChar; Count: Integer; var Size: TSize): Boolean; override;
    function GetTextMetrics(DC: HDC; var TM: TTextMetric): Boolean; override;
    function GetDeviceCaps(DC: HDC; Index: Integer): Integer; override;
    { 控件画布的 DC 全部用假句柄顶上，让 TStringGrid 等控件可以完成
      创建期的文本测量（不真正绘制） }
    function GetDC(hWnd: HWND): HDC; override;
    function ReleaseDC(hWnd: HWND; hDC: HDC): Integer; override;
    function SetTextColor(DC: HDC; Color: TColorRef): TColorRef; override;
    function SetBkColor(DC: HDC; Color: TColorRef): TColorRef; override;
    function SaveDC(DC: HDC): Integer; override;
    function RestoreDC(DC: HDC; SavedDC: Integer): Boolean; override;
    { nogui 里这三个还是抽象的：所有就剩它们没实现，构造 TLWWidgetSet 时会
      提示 "constructing class with abstract methods"，一旦被调用直接崩。
      服务端不绘制，给空实现即可 }
    function DCGetPixel(CanvasHandle: HDC; X: LongInt; Y: LongInt): TColor; override;
    procedure DCSetPixel(CanvasHandle: HDC; X: LongInt; Y: LongInt; AColor: TColor); override;
    procedure DCRedraw(CanvasHandle: HDC); override;
  end;

var
  GInstalled: Boolean = False;
  GScreenW: Integer = 1920;
  GScreenH: Integer = 1080;
  GFontHeightPx: Integer = 13;

function TLWWidgetSet.EnumDisplayMonitors(hdc: HDC; lprcClip: PRect;
  lpfnEnum: MonitorEnumProc; dwData: LPARAM): LongBool;
var
  r: TRect;
begin
  Result := False;
  if not Assigned(lpfnEnum) then Exit;
  r.Left := 0;
  r.Top := 0;
  r.Right := GScreenW;
  r.Bottom := GScreenH;
  lpfnEnum(LW_MONITOR_HANDLE, 0, @r, dwData);
  Result := True;
end;

function TLWWidgetSet.GetMonitorInfo(hMonitor: HMONITOR; lpmi: PMonitorInfo): Boolean;
begin
  Result := False;
  if lpmi = nil then Exit;
  FillChar(lpmi^, SizeOf(lpmi^), 0);
  lpmi^.cbSize := SizeOf(lpmi^);
  lpmi^.rcMonitor.Left := 0;
  lpmi^.rcMonitor.Top := 0;
  lpmi^.rcMonitor.Right := GScreenW;
  lpmi^.rcMonitor.Bottom := GScreenH;
  lpmi^.rcWork := lpmi^.rcMonitor;
  lpmi^.dwFlags := MONITORINFOF_PRIMARY_LW;
  Result := True;
end;

function TLWWidgetSet.MonitorFromWindow(hWnd: HWND; dwFlags: DWord): HMONITOR;
begin
  Result := LW_MONITOR_HANDLE;
end;

function TLWWidgetSet.MonitorFromPoint(pt: TPoint; dwFlags: DWord): HMONITOR;
begin
  Result := LW_MONITOR_HANDLE;
end;

function TLWWidgetSet.GetDpiForMonitor(hmonitor: HMONITOR; dpiType: TMonitorDpiType;
  out dpiX: UINT; out dpiY: UINT): HRESULT;
begin
  dpiX := 96;
  dpiY := 96;
  Result := S_OK;
end;

{ 虚拟字体：记录最近一次创建的字体像素高度，供文本测量估算使用 }
function CurFontPx: Integer;
begin
  if GFontHeightPx <= 0 then
    Result := 13
  else
    Result := GFontHeightPx;
end;

function TLWWidgetSet.CreateCompatibleDC(DC: HDC): HDC;
begin
  Result := HDC(1000);
end;

function TLWWidgetSet.DeleteDC(hDC: HDC): Boolean;
begin
  Result := True;
end;

function TLWWidgetSet.SelectObject(DC: HDC; GDIObj: HGDIOBJ): HGDIOBJ;
begin
  Result := 0;
end;

function TLWWidgetSet.CreateFontIndirect(const LogFont: TLogFont): HFONT;
begin
  if LogFont.lfHeight <> 0 then
    GFontHeightPx := Abs(LogFont.lfHeight);
  Result := HFONT(7000);
end;

function TLWWidgetSet.CreateFontIndirectEx(const LogFont: TLogFont;
  const LongFontName: string): HFONT;
begin
  if LogFont.lfHeight <> 0 then
    GFontHeightPx := Abs(LogFont.lfHeight);
  Result := HFONT(7001);
end;

function TLWWidgetSet.GetTextExtentPoint32(DC: HDC; Str: PChar; Count: Integer;
  var Size: TSize): Boolean;
var
  h: Integer;
begin
  h := CurFontPx;
  Size.cx := Max(1, Round(Count * h * 0.55));
  Size.cy := Round(h * 1.25) + 3;
  Result := True;
end;

function TLWWidgetSet.GetTextMetrics(DC: HDC; var TM: TTextMetric): Boolean;
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
  TM.tmItalic := 0;
  TM.tmUnderlined := 0;
  TM.tmStruckOut := 0;
  TM.tmPitchAndFamily := $22;
  Result := True;
end;

function TLWWidgetSet.GetDeviceCaps(DC: HDC; Index: Integer): Integer;
begin
  { LOGPIXELSX/SY = 88/90，其余给个通用值 }
  case Index of
    88, 90: Result := 96;
    6: Result := GScreenW;   { HORZRES }
    10: Result := GScreenH;  { VERTRES }
  else
    Result := 0;
  end;
end;

function TLWWidgetSet.GetDC(hWnd: HWND): HDC;
begin
  Result := HDC(2000);
end;

function TLWWidgetSet.ReleaseDC(hWnd: HWND; hDC: HDC): Integer;
begin
  Result := 1;
end;

function TLWWidgetSet.SetTextColor(DC: HDC; Color: TColorRef): TColorRef;
begin
  Result := Color;
end;

function TLWWidgetSet.SetBkColor(DC: HDC; Color: TColorRef): TColorRef;
begin
  Result := Color;
end;

function TLWWidgetSet.SaveDC(DC: HDC): Integer;
begin
  Result := 1;
end;

function TLWWidgetSet.RestoreDC(DC: HDC; SavedDC: Integer): Boolean;
begin
  Result := True;
end;

function TLWWidgetSet.DCGetPixel(CanvasHandle: HDC; X: LongInt; Y: LongInt): TColor;
begin
  Result := clBlack;
end;

procedure TLWWidgetSet.DCSetPixel(CanvasHandle: HDC; X: LongInt; Y: LongInt;
  AColor: TColor);
begin
end;

procedure TLWWidgetSet.DCRedraw(CanvasHandle: HDC);
begin
end;

procedure LWSetVirtualScreen(AWidth, AHeight: Integer);
begin
  if AWidth > 0 then GScreenW := AWidth;
  if AHeight > 0 then GScreenH := AHeight;
end;

procedure LWInstallWidgetSet;
var
  ws: TWidgetSet;
begin
  if GInstalled then Exit;
  GInstalled := True;
  { 旧实例不释放：interfaces 单元内部可能仍持有引用，泄漏一个对象无妨 }
  ws := TLWWidgetSet.Create;
  WidgetSet := ws;
  if Screen <> nil then
    Screen.UpdateMonitors;

  { 第二个坑：TCustomForm.CreateNew 里
        case Application.DoubleBuffered of
          adbDefault: FDoubleBuffered := TWSCustomFormClass(WidgetSetClass).GetDefaultDoubleBuffered;
     nogui 的 widgetset 实例不是 TWSCustomForm 的后代，这个类型转换会崩，
     adbDefault 正是默认值。显式关掉双缓冲即可绕过（服务端根本不绘制） }
  Application.DoubleBuffered := adbFalse;

  { 第三个坑：菜单。nogui 的 RegisterMainMenu 等直接 return False，
     菜单相关的 WS 类根本没注册，于是
        TMenu.CreateHandle: FItems.Handle := TWSMenuClass(WidgetSetClass).CreateHandle(Self)
     里的 WidgetSetClass 是 nil，硬转型后调用类方法 -> AV。
     LCL 自带的 TWSMenu/TWSMenuItem/TWSMainMenu/TWSPopupMenu 全是空实现，
     注册上去只为占位，浏览器端的菜单由 lw.js 用 Ext.menu.Menu 渲染。 }
  RegisterWSComponent(TMenuItem, TWSMenuItem);
  RegisterWSComponent(TMenu, TWSMenu);
  RegisterWSComponent(TMainMenu, TWSMainMenu);
  RegisterWSComponent(TPopupMenu, TWSPopupMenu);
end;

{$ELSE}

{ ---------------------------------------------------------------- }
{ 非 nogui widgetset（win32 / gtk2 / qt5 ...）：装"按线程路由"代理。 }
{ ---------------------------------------------------------------- }
{ 面板窗体（主线程创建）走真实 widgetset，正常显示；
  会话窗体（HTTP 工作线程创建）走无头实现，行为与 nogui 部署档完全一致。
  真实 widgetset 不是线程安全的（NOTES 坑 19），而本框架所有控件操作
  都发生在工作线程里 —— 不隔离就必然堆损坏（gtk2 下打开网站即闪退）。 }

uses
  lwproxyws;

var
  GScreenW: Integer = 1920;
  GScreenH: Integer = 1080;

procedure LWSetVirtualScreen(AWidth, AHeight: Integer);
begin
  if AWidth > 0 then GScreenW := AWidth;
  if AHeight > 0 then GScreenH := AHeight;
end;

procedure LWInstallWidgetSet;
begin
  LWInstallProxyWidgetSet;
end;

{$ENDIF}

end.
