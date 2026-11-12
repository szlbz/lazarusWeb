{
  lazarusWeb :: lwpanel
  ------------------------------------------------------------------
  服务端控制面板 —— 对标 uniGUI 独立服务器的那个窗口：

      +----------------------------------------------+
      | lazarusWeb 0.9.0 独立服务器 - 端口 8141       |
      | 文件(F)   管理(M)                             |
      |----------------------------------------------|
      | 14:32:07  GET /lw/api/session  200  sid=...   |
      | 14:32:09  POST /lw/api/event btnOk OnClick    |
      | ...（只读 Memo，自动滚动）                    |
      |----------------------------------------------|
      | http://127.0.0.1:8141/ | 会话 3 | 运行 00:12  |
      +----------------------------------------------+

  界面全部在设计期画在 lwpanel.lfm 里（主菜单、托盘菜单、日志 Memo、
  状态栏三格、定时器、托盘图标），本单元只保留数据与行为 —— 和 demos
  里的窗体写法一致，可以在 IDE 设计器里直接打开改布局。
  注意 lfm 里的控件名必须与 published 字段同名，流式加载靠
  TComponent.SetName -> Owner.FieldAddress(Name) 绑定指针，
  字段不在 published 区就永远是 nil。

  编译模式决定行为：

    - nogui 构建（LCLnogui）—— 没有 GUI 能力，LWRunPanel 保持
      以前的 "while True do Sleep" 阻塞循环，tests/CI 不受影响；
      整个 TLWPanelForm 与 lfm 资源都在 $IFnDEF 里，不参与编译；
    - win32 构建（LCLwin32 + -WG）—— 默认显示本面板并跑
      Application 消息循环，双击 exe 不再弹出大黑终端；
      --nogui 参数可退回无窗口模式（服务/CI 部署）。

  线程模型：日志行从 HTTP 线程经 LWLog -> sink 进来，这里不直接
  摸 Memo，而是先进 FBuf 缓冲（临界区），TTimer 每秒在主线程里
  swap 出来追加 —— 不用 Synchronize/Queue，没有死锁面。

  注意：LWInstallDialogs 把 ShowMessage/MessageDlg 改道到浏览器，
  面板自己的对话框（关于窗口，见 lwabout）绝不能调它们。
}
unit lwpanel;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, lwhttp
  {$IFnDEF LCLnogui}
  , Controls, StdCtrls, ComCtrls, Menus, Graphics, Clipbrd,
    LCLType, LCLIntf, ExtCtrls
  {$ENDIF}
  ;

{$IFnDEF LCLnogui}
type
  TLWPanelForm = class(TForm)
    { ---- 以下控件由 lwpanel.lfm 流式创建，名字必须一致 ---- }
    memLog: TMemo;              { 只读日志，alClient }
    sbMain: TStatusBar;         { 三格：地址 / 会话数 / 运行时长 }
    mmMain: TMainMenu;
    mnuFile: TMenuItem;
    mniOpen: TMenuItem;         { 打开浏览器 F5 }
    mniCopy: TMenuItem;         { 复制地址 }
    mniSep1: TMenuItem;
    mniExit: TMenuItem;         { 真退出（点 X 只是藏托盘） }
    mnuAdmin: TMenuItem;
    mniClear: TMenuItem;
    mniVerbose: TMenuItem;      { 勾选项 }
    mniSep2: TMenuItem;
    mniAbout: TMenuItem;
    pmTray: TPopupMenu;
    mniTrayShow: TMenuItem;
    mniTrayOpen: TMenuItem;
    mniTraySep: TMenuItem;
    mniTrayExit: TMenuItem;
    trayMain: TTrayIcon;
    tmrMain: TTimer;            { 800ms：刷日志 + 更新状态栏 }
    { ---- 事件（lfm 里按名字挂） ---- }
    procedure FormClose(Sender: TObject; var AAction: TCloseAction);
    procedure tmrMainTimer(Sender: TObject);
    procedure TrayClick(Sender: TObject);
    procedure DoOpen(Sender: TObject);
    procedure DoCopy(Sender: TObject);
    procedure DoExitMenu(Sender: TObject);
    procedure DoClear(Sender: TObject);
    procedure DoVerbose(Sender: TObject);
    procedure DoAbout(Sender: TObject);
    procedure AppIdle(Sender: TObject; var Done: Boolean);
  private
    FServer: TLWServer;
    FStartAt: TDateTime;
    FBuf: TStringList;        { 日志缓冲：HTTP 线程写、主线程读 }
    FBufLock: TRTLCriticalSection;
    FExiting: Boolean;        { True = 用户点了「退出」，OnClose 这回真的退出 }
    FHideHintShown: Boolean;  { 第一次藏进托盘时弹一次气泡提醒，别一直弹 }
    procedure InitPanel(AServer: TLWServer; const ACfg: TLWServerConfig);
    { 32x32 的面板图标：运行时画（圆角方块 + "LW"），不用带 .res 资源。
      同一个 TIcon 给托盘、标题栏、Application 三处用 }
    procedure MakeIcon(AIcon: TIcon);
    procedure SetupTray;
    { 日志 sink：只在临界区里做一件小事，绝不碰 UI }
    procedure OnSink(const ALine: string);
    function BaseURL: string;
    procedure AppendLines;
  public
    class function CreatePanel(AOwner: TComponent; AServer: TLWServer;
      const ACfg: TLWServerConfig): TLWPanelForm;
    destructor Destroy; override;
  end;

{ 显示面板并进入 Application 消息循环，窗口关闭后返回 }
procedure LWRunPanel(AServer: TLWServer; const ACfg: TLWServerConfig);

{$ELSE}

{ nogui 构建：没有窗口能力，保持老的阻塞行为 }
procedure LWRunPanel(AServer: TLWServer; const ACfg: TLWServerConfig);

{$ENDIF}

implementation

uses
  lwrlog
  {$IFDEF unix}
  , BaseUnix
  {$ENDIF}
  {$IFnDEF LCLnogui}
  , lwbase, lwabout, DateUtils
  {$ENDIF}
  ;

{$IFnDEF LCLnogui}

{$R *.lfm}

type
  { HTTP accept 循环在后台线程里跑（TLWServer.Start 一进 accept
    就永不返回）；主线程只跑面板的消息循环。关窗时 OnClose 调
    FServer.Stop，accept 退出、线程自然结束。 }
  TLWServerThread = class(TThread)
  protected
    FServer: TLWServer;
    procedure Execute; override;
  public
    constructor Create(AServer: TLWServer);
  end;

constructor TLWServerThread.Create(AServer: TLWServer);
begin
  FServer := AServer;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TLWServerThread.Execute;
begin
  try
    FServer.Start;
  except
    on E: Exception do
    begin
      { 主要是端口被占用。日志进面板/文件，用户看完关窗即可退出 }
      LWLog('错误: 无法启动服务: ' + E.Message);
      LWLog('      端口可能已被别的程序占用，换一个 --port= 再试。');
    end;
  end;
end;

{ 退出的最后一道闸门。

  服务停掉之后，剩下的只有本进程的清理：销毁窗体、跑各单元的
  finalization、GTK/glib 收尾。这一段在 mips64el 上实测会卡住不返回
  —— 窗口一直挂着、主线程空转烧 CPU、桌面判定"未响应"并弹出
  "是否强制退出"（日志里能看到 zenity 的 ANR 提示），用户看到的就是
  "点退出关不掉"。

  此刻没有任何必须保住的东西：监听已关、连接已 shutdown、会话仓库
  已释放。所以给它一个硬时限：正常收尾几十毫秒就把进程结束掉，这个
  线程根本醒不过来；真卡住了就由它结束进程。用 fpExit 而不是 Halt，
  是为了跳过卡住的那段 finalization（Halt 恰恰会去跑它）。 }
type
  TLWExitWatchdog = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TLWExitWatchdog.Execute;
begin
  Sleep(500);
  { 走到这里说明正常收尾没能在 500ms 内结束进程。直接写 stderr：
    此时日志 sink 可能已经拆了，这是最原始可靠的一条 }
  WriteLn(StdErr, '[exit] 500ms 内未收工（LCL/GTK 收尾卡住），看门狗强制结束进程');
  Flush(StdErr);
  {$IFDEF unix}
  fpExit(0);
  {$ELSE}
  Halt(0);
  {$ENDIF}
end;

procedure LWStartExitWatchdog;
begin
  with TLWExitWatchdog.Create(True) do
  begin
    FreeOnTerminate := True;
    Start;
  end;
end;

procedure LWRunPanel(AServer: TLWServer; const ACfg: TLWServerConfig);
var
  panel: TLWPanelForm;
  th: TLWServerThread;
begin
  if ACfg.NoUI then
  begin
    { --nogui：无窗口模式，服务化部署用 —— 同线程跑 accept 循环，
      与 nogui 构建的历史行为完全一致 }
    try
      AServer.Start;
    except
      on E: Exception do
      begin
        LWLog('错误: 无法启动服务: ' + E.Message);
        LWLog('      端口可能已被别的程序占用，换一个 --port= 再试。');
        ExitCode := 2;
        Exit;
      end;
    end;
    while True do
      Sleep(500);
    Exit;
  end;

  th := TLWServerThread.Create(AServer);
  panel := TLWPanelForm.CreatePanel(Application, AServer, ACfg);
  panel.Show;
  { 让主循环在没事干时睡一下，见 AppIdle 的注释 }
  Application.OnIdle := @panel.AppIdle;
  Application.Run;    { 关窗 -> OnClose 停服务 -> 线程退出 -> 这里返回 }
  LWStopTrace('主循环 ① Application.Run 已返回');
  th.WaitFor;
  LWStopTrace('主循环 ② 服务线程已结束');
  th.Free;
  LWStopTrace('主循环 ③ 服务线程已释放（接下来走单元收尾）');
end;

{ ---------------- TLWPanelForm ---------------- }

{ 先让 TForm 的构造函数把 lwpanel.lfm 流进来（TCustomForm.Create ->
  CreateNew -> ProcessResource），再灌注运行时状态：lfm 里的控件
  此刻已经全部建好并且 published 字段已经指向它们。 }
class function TLWPanelForm.CreatePanel(AOwner: TComponent; AServer: TLWServer;
  const ACfg: TLWServerConfig): TLWPanelForm;
begin
  Result := TLWPanelForm.Create(AOwner);
  try
    Result.InitPanel(AServer, ACfg);
  except
    Result.Free;
    raise;
  end;
end;

procedure TLWPanelForm.InitPanel(AServer: TLWServer;
  const ACfg: TLWServerConfig);
begin
  FServer := AServer;
  FStartAt := Now;
  FBuf := TStringList.Create;
  InitCriticalSection(FBufLock);
  Caption := 'lazarusWeb ' + LW_VERSION + ' 独立服务器 - 端口 ' +
    IntToStr(ACfg.Port);
  { 收工前的横幅已经在 PrintBanner 里走 LWLog 进了缓冲，
    这里的定时器会把它刷到 Memo 上 }
  LWSetLogSink(@OnSink);
  { LW_NOTRAY=1：不建托盘图标（调试 / 无系统托盘的精简桌面用）。
    某些 X 会话没有 systray 宿主时 GtkStatusIcon 会退化成忙等，
    主线程 CPU 打满（MIPS 上实测 100%），这个开关便于先排除它。 }
  if GetEnvironmentVariable('LW_NOTRAY') = '' then
    SetupTray;
  tmrMain.Enabled := True;
  mniVerbose.Checked := ACfg.Verbose;
end;

destructor TLWPanelForm.Destroy;
begin
  LWStopTrace('窗体 Destroy 进入');
  LWSetLogSink(nil);
  if tmrMain <> nil then
    tmrMain.Enabled := False;
  if trayMain <> nil then
    trayMain.Visible := False;
  LWStopTrace('窗体 Destroy ① 定时器/托盘已收');
  if FBuf <> nil then
  begin
    DoneCriticalSection(FBufLock);
    FreeAndNil(FBuf);
  end;
  LWStopTrace('窗体 Destroy ② 缓冲已释放');
  inherited Destroy;
  LWStopTrace('窗体 Destroy 结束');
end;

function TLWPanelForm.BaseURL: string;
begin
  Result := 'http://127.0.0.1:' + IntToStr(FServer.Cfg.Port) + '/';
end;

procedure TLWPanelForm.OnSink(const ALine: string);
begin
  EnterCriticalSection(FBufLock);
  try
    FBuf.Add(ALine);
  finally
    LeaveCriticalSection(FBufLock);
  end;
end;

procedure TLWPanelForm.AppendLines;
var
  chunk: TStringList;
  i: Integer;
begin
  chunk := nil;
  EnterCriticalSection(FBufLock);
  try
    if FBuf.Count > 0 then
    begin
      chunk := FBuf;
      FBuf := TStringList.Create;
    end;
  finally
    LeaveCriticalSection(FBufLock);
  end;
  if chunk = nil then Exit;
  try
    memLog.Lines.BeginUpdate;
    try
      for i := 0 to chunk.Count - 1 do
        memLog.Lines.Add(chunk[i]);
      { 限制行数：长跑的服务不能让 Memo 无限涨 }
      while memLog.Lines.Count > 4000 do
        memLog.Lines.Delete(0);
      { 自动滚到底部 }
      memLog.SelStart := Length(memLog.Text);
      memLog.SelLength := 0;
    finally
      memLog.Lines.EndUpdate;
    end;
  finally
    chunk.Free;
  end;
end;

procedure TLWPanelForm.tmrMainTimer(Sender: TObject);
var
  up: Int64;
  h, m, s: Integer;
begin
  AppendLines;
  up := SecondsBetween(Now, FStartAt);
  h := up div 3600;
  m := (up mod 3600) div 60;
  s := up mod 60;
  sbMain.Panels[0].Text := BaseURL;
  sbMain.Panels[1].Text := '会话 ' + IntToStr(FServer.SessionCount);
  sbMain.Panels[2].Text := Format('运行 %.2d:%.2d:%.2d', [h, m, s]);
end;

procedure TLWPanelForm.MakeIcon(AIcon: TIcon);
var
  bmp: TBitmap;
  w, h: Integer;
begin
  { 运行时画一个 32x32 图标：蓝底方块 + 白色 "LW"。
    不带 .res 资源，工程里少一个二进制文件要维护。

    【不要在这里用 RoundRect】LCL 的 TCanvas.RoundRect 走
    PolyBezier -> graphmath.Bezier2Polyline，而它靠
    Colinear(B, 1) 的浮点判定来终止 SplitRecursive 递归。
    在 FPC/mips64（龙芯、mips64el 龙梦机）上该判定恒为 False：
    Tolerance 以 Extended 传递、比较始终不成立，于是曲线被无限
    二分成左右两半，栈溢出后崩在 SYSTEM_$$_MOVE（栈指针越界，
    gdb 里只看到一帧 MOVE，极难定位）。实测 MIPS 上启动即
    SIGSEGV，Windows/gtk2 x86 上则正常 —— 换成"实心方块 + 描边"
    后各平台都安全，32x32 的图标视觉差异可以忽略。 }
  bmp := TBitmap.Create;
  try
    bmp.SetSize(32, 32);
    bmp.Canvas.Brush.Color := RGB(37, 99, 235);        // 蓝
    bmp.Canvas.FillRect(0, 0, 32, 32);
    bmp.Canvas.Brush.Style := bsClear;                 // 只描边不填充
    bmp.Canvas.Pen.Color := RGB(59, 130, 246);         // 内圈浅一点的蓝
    bmp.Canvas.FrameRect(2, 2, 30, 30);
    bmp.Canvas.Brush.Style := bsSolid;
    bmp.Canvas.Font.Name := 'Segoe UI';
    bmp.Canvas.Font.Size := 11;
    bmp.Canvas.Font.Style := [fsBold];
    bmp.Canvas.Font.Color := clWhite;
    w := bmp.Canvas.TextWidth('LW');
    h := bmp.Canvas.TextHeight('LW');
    bmp.Canvas.TextOut((32 - w) div 2, (32 - h) div 2, 'LW');
    AIcon.Assign(bmp);   { TCustomIcon.Assign 直接吃位图 }
  finally
    bmp.Free;
  end;
end;

{ 托盘菜单、气泡文案在 lfm 里；这里只补运行时的东西：
  图标（位图没法流式化）和依赖端口/版本的 Hint 文本 }
procedure TLWPanelForm.SetupTray;
var
  ico: TIcon;
begin
  ico := TIcon.Create;
  try
    MakeIcon(ico);

    { 窗口标题栏 / 任务栏 / Application / 托盘 用同一个图标 }
    Icon.Assign(ico);
    Application.Icon.Assign(ico);
    trayMain.Icon.Assign(ico);

    trayMain.Hint := Caption + ' · ' + BaseURL +
      '（点 X 隐藏到托盘，右键退出）';
    trayMain.BalloonHint := '服务面板已隐藏到托盘。' + BaseURL +
      '  点此图标恢复面板；结束服务请用右键菜单「退出」。';
    trayMain.Visible := True;   { 托盘图标从启动起就常驻 }
  finally
    ico.Free;
  end;
end;

procedure TLWPanelForm.TrayClick(Sender: TObject);
begin
  { 点托盘图标 = 把面板调回来 }
  Show;
  if WindowState = wsMinimized then
    WindowState := wsNormal;
  SetForegroundWindow(Handle);
end;

procedure TLWPanelForm.FormClose(Sender: TObject; var AAction: TCloseAction);
begin
  if not FExiting then
  begin
    { 点 X（或系统关机请求之外的普通关闭）：藏进托盘，服务继续跑 }
    AAction := caHide;
    if not FHideHintShown then
    begin
      FHideHintShown := True;
      trayMain.ShowBalloonHint;
    end;
    Exit;
  end;

  { 真正退出：先停服务再收尾（Stop 幂等，可重复调）。
    Stop 现在最坏也就 300ms 左右（关 accept、断连接、叫醒长轮询），
    见 NOTES 坑 44 —— 早期版本这里会让进程吊到"下一个浏览器请求到达"为止 }
  LWStopTraceBegin;
  trayMain.Visible := False;
  LWStopTrace('面板 ① 托盘图标已隐藏');
  FServer.Stop;
  LWStopTrace('面板 ② 服务已停止');
  { 服务已停，后面全是本进程的清理。LCL/GTK 那段 finalization 在
    mips64el 上会卡住不返回（见 TLWExitWatchdog 的注释和坑 88），
    启动看门狗兜底：500ms 内没收工就直接结束进程 }
  LWStartExitWatchdog;
  AAction := caFree;
  Application.Terminate;
  LWStopTrace('面板 ③ 已请求结束消息循环（500ms 未退则由看门狗强制结束）');
end;

procedure TLWPanelForm.DoOpen(Sender: TObject);
begin
  OpenURL(BaseURL);
end;

procedure TLWPanelForm.DoCopy(Sender: TObject);
begin
  Clipboard.AsText := BaseURL;
end;

procedure TLWPanelForm.DoExitMenu(Sender: TObject);
begin
  { 只有这条路是真的退出：点 X 会被 OnClose 拦下藏进托盘 }
  FExiting := True;
  Close;
end;

procedure TLWPanelForm.DoClear(Sender: TObject);
begin
  memLog.Clear;
end;

procedure TLWPanelForm.DoVerbose(Sender: TObject);
begin
  mniVerbose.Checked := not mniVerbose.Checked;
  FServer.SetVerbose(mniVerbose.Checked);
end;

procedure TLWPanelForm.DoAbout(Sender: TObject);
begin
  { 不能用 ShowMessage：LWInstallDialogs 已把它改道到浏览器会话 }
  TLWAboutForm.ShowAbout(Self, 'lazarusWeb ' + LW_VERSION + LineEnding +
    'FPC/LCL 窗体 -> Ext JS 的 Web 化框架' + LineEnding +
    '监听: ' + BaseURL);
end;

{ gtk2 的 TWidgetSet.AppRun 是"非阻塞 iteration"循环：
      while not Terminated do AppProcessMessage;
  里面 g_main_context_iteration(nil, False) 从不阻塞，所以只要没有窗口事件，
  主线程就空转把一个核吃满（MIPS 上实测 100%，strace 显示 5 秒 14 万次
  recvmsg 且几乎全是 EAGAIN）。这里在 OnIdle 里小睡让出 CPU：
  5ms 对"看日志的面板窗口"完全够用，实测 CPU 从 100% 降到个位数。 }
procedure TLWPanelForm.AppIdle(Sender: TObject; var Done: Boolean);
begin
  Sleep(5);
  Done := False;      { 还有 idle 时间，继续让 LCL 处理消息 }
end;

{$ELSE}

{ nogui 构建：同线程跑 accept 循环（TLWServer.Start 一进 accept 就
  永不返回），行为与历史版本完全一致。注意 Start 不能忘 ——
  lwapp 已把启动全权交给本过程。 }
procedure LWRunPanel(AServer: TLWServer; const ACfg: TLWServerConfig);
begin
  try
    AServer.Start;
  except
    on E: Exception do
    begin
      LWLog('错误: 无法启动服务: ' + E.Message);
      LWLog('      端口可能已被别的程序占用，换一个 --port= 再试。');
      ExitCode := 2;
      Exit;
    end;
  end;
  while True do
    Sleep(500);
end;

{$ENDIF}

end.
