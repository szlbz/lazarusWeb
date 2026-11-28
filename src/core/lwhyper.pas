{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwhyper
  ------------------------------------------------------------------
  专用负载均衡器（对标 uniGUI Hyper Server）。

  一个进程搞定"集群"：
    - 拉起 N 个 worker（同一个业务 exe 多开，--port/--nogui/--log），
      崩溃自动重启；
    - 对外监听一个端口，HTTP 反向代理到 worker（fphttpclient 流式转发）；
    - 会话粘性：sid 出现在每个 API 调用（?sid= 或 X-LW-Sid 头），
      新会话轮询分配，之后按 sid 查表粘住同一个 worker；
    - WebSocket（/lw/ws）：TCP 级双向透传（握手在 worker 端完成）；
    - 自带健康监控：定时打 worker 的 /lw/healthz（缓存会话数），
      自身暴露 /lw/healthz（汇总）与 /lw/hyper/status（明细）。

  典型用法（HTTP 场景不再需要 nginx）：
    lwhyper --port=8080 --workers=3 --exe=demos/dbaware/dbaware(.exe)
  HTTPS 场景直接在 lwhyper 终结即可，无需前置反代：
    lwhyper --port=8443 --ssl --workers=3 --exe=demos/dbaware/dbaware(.exe)
  （纯 FPC：TFPHttpServer.UseSSL + opensslsockets；worker 之间仍走 HTTP，
   只有对外这一层是 TLS，粘性由 lwhyper 管，反代不需要 ip_hash）
  需随包带 libssl-3-x64.dll + libcrypto-3-x64.dll（或 1.1 版）。

  会话恢复：lwhyper 重启会丢 sid->worker 表；带未知 sid 的请求轮询转发，
  worker 回 410 + gone，浏览器自动重建会话回登录页（框架既有兜底链路）。

  边界（已知取舍）：
    - worker 重启 = 该 worker 上的会话全部丢失（会话在进程内存里）；
    - 请求体经内存中转（上传大文件会有一次内存拷贝）；
    - 转发时剥掉 hop-by-hop 头（Connection/Keep-Alive/TE/Trailer/
      Transfer-Encoding/Upgrade/Expect），其余头原样透传。

  FPC 版本兼容（同时支持 3.2.2 与 3.3.1）：
    - WebSocket 升级：3.3.1 用 fphttpserver 的 RegisterUpdateHandler，
      3.2.2 改在 OnRequest 里接管（WSTunnel + ELWHyperUpgraded）；
    - 线程模式：ThreadMode/tmThread(3.3.1) vs Threaded:Boolean(3.2.2)；
    - 请求体：TRequest.ContentBytes(3.3.1) vs TRequest.Content(3.2.2)；
    - 状态行文本：GetHTTPStatusText(3.3.1) vs lwbase.LWHTTPStatusText；
    - TSocketStream 的 CanRead / Close：3.3.1 才有，统一走
      lwwebsocket.LWCanRead / LWSocketClose；
    - 升级判定要用 LWReqHeader 同时查 Headers 与 CustomHeaders
      （3.2.2 把 Upgrade 这类头放在 CustomHeaders 里）。
}
unit lwhyper;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, SyncObjs, fphttpserver, httpdefs, httpprotocol,
  fpjson, jsonparser, ssockets, fphttpclient, Process, lwrlog, lwwebsocket, lwbase,
  lwroute, lwpluginauth, lwhyperplugin, lwhyperauth, lwhyperui, lwpwa,
  opensslsockets;

type
  TLWHyperConfig = record
    Port: Word;            { lwhyper 监听端口 }
    BasePort: Word;        { 第一个 worker 的端口（缺省 Port+1，顺次 +1） }
    WorkerCount: Integer;  { worker 进程数 }
    WorkerExe: string;     { 业务 exe 路径 }
    Root: string;          { 转发为 worker 的 --root= }
    Theme: string;         { 转发为 worker 的 --theme= }
    ExtraArgs: string;     { --worker-args="..." 原样追加到 worker 命令行 }
    LogDir: string;        { worker 日志目录（缺省 <TEMP>/lwhyper，PathDelim 无关） }
    Verbose: Boolean;
    { 热更新：监听业务 exe 的新版本文件，原子换壳后逐个滚动重启 worker。
      没有新版本文件时什么都不做，所以缺省开启不改变既有行为。 }
    HotUpdate: Boolean;
    UpdateDir: string;     { 新版本投放目录（空 = 看 <WorkerExe>.new） }
    { worker 优雅退出令牌：启动时随机生成，用 --shutdown-token= 注入每个
      worker 的命令行，热更新前 POST /lw/shutdown 让它自己收尾。
      不对外暴露参数（运维不需要知道，也不该手工指定） }
    ShutdownToken: string;
    { 插件宿主模式：扫描 <PluginRoot>\<插件目录>\*.plugin.ini，按 /p/<名>/
      反代到独立插件 exe。False = 原有"单 exe 多 worker"模式。
      两种模式互斥使用同一监听端口，但代码共用 TLWHyperServer。 }
    PluginMode: Boolean;
    PluginRoot: string;
    { 插件模式的登录入口。默认开：未登录只能看到 /login，/p/ 一律送回登录。
      AuthEnabled=False 是显式的逃生开关（--no-auth），只给本机调试用。 }
    AuthEnabled: Boolean;
    UsersFile: string;     { 用户表 ini（每节 [用户名]：pass=/roles=/display=） }
    SessionMin: Integer;   { 会话空闲超时（分钟），缺省 480 }
    LoginHint: string;     { 登录页脚注（演示账号提示），可空 }
    { TLS（纯 FPC）：只在外层监听终结，worker 间仍明文转发 }
    UseSSL: Boolean;
    SSLHost: string;
    SSLCertFile: string;
    SSLKeyFile: string;
    { PWA：宿主直出静态资源与订阅端点，同时把开关透传给 worker 外壳 }
    PWAEnabled: Boolean;
    PWAName: string;
    PWAShortName: string;
    PWAThemeColor: string;
    PWABackgroundColor: string;
    PWAVapidPublic: string;
    PWAVapidPrivate: string;
    PWAVapidSubject: string;
    PWAPushToken: string;
    PWAPushFile: string;
    PWAMessageFile: string;
  end;

  TLWHyperServer = class;
  TLWHyperUpdater = class;

  { FPC 3.2.2 专用控制流信号：HandleRequest 里已经手工完成 WebSocket 透传，
    用它跳出 fcl-web 的"继续发响应"流程（不产生任何输出）。3.3.1 下不会用到。 }
  ELWHyperUpgraded = class(Exception);  { 单个 worker：一个业务 exe 子进程 }
  TLWWorker = class
  public
    Port: Word;
    Proc: TProcess;
    Alive: Boolean;       { 最近一次 healthz 是否通过 }
    Sessions: Integer;    { 最近一次 healthz 报告的会话数 }
    Restarts: Integer;    { 崩溃重启次数（不含首轮启动） }
    Updates: Integer;     { 热更新导致的重启次数 }
    { 热身闸门：重启后要连续通过 N 次探针才重新对外（重启初期
      healthz 可能已通但页面初始化没完，直接放行会出现秒级慢请求）。
      只在重启时置位，首轮启动不受影响 }
    BootGuard: Integer;
    LogPath: string;
    constructor Create(APort: Word);
    destructor Destroy; override;
    procedure Launch(const ACfg: TLWHyperConfig; AIndex: Integer);
    procedure Kill;
  end;

  { worker 守护线程：healthz 巡检 + 崩溃重启 }
  TLWHyperMonitor = class(TThread)
  protected
    FHyper: TLWHyperServer;
    procedure Execute; override;
  end;

  { worker 热更新线程：轮询新版本 exe -> 原子换壳 -> 逐个滚动重启 worker。

    换壳为什么不先停 worker：Windows 不允许覆盖写正在运行的 exe，但**允许
    改名**（已实测），所以先把当前 exe 改成备份名，各 worker 进程仍跑着各自
    已映射的旧镜像；再把新文件改名成正式名。这一步零停机，之后才逐个重启
    让 worker 加载新镜像——任一时刻至少 N-1 个 worker 在对外服务。

    失败回滚：某个 worker 起不来就整体退回旧版本（坏 exe 留存为 .bad-<时间>），
    并把已经切到新版本的 worker 全部重启回旧版，避免集群长期瘫着。 }
  TLWHyperUpdater = class(TThread)
  private
    FHyper: TLWHyperServer;
    FWatch: string;
    FDisabled: Boolean;
    FStampSize: Int64;
    FStampTime: LongInt;
    FStampHits: Integer;
    { 换壳失败过的那一份文件（大小+时间）：同一份不再反复重试，
      否则 exe 被别的进程长期占用时每 4 秒刷一次错误日志 }
    FFailSize: Int64;
    FFailTime: LongInt;
    procedure ResetStamp;
    function CandidateReady: Boolean;
    function SwapIn(const ANewFile: string; out AOldFile: string): Boolean;
    function RestartWorker(AIndex: Integer): Boolean;
    procedure Rollback(const AOldFile: string; AProgress: Integer);
    function RunUpdate(const ANewFile: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AHyper: TLWHyperServer);
  end;

  { WebSocket 双向透传线程（一个方向） }
  TLWWSPump = class(TThread)
  protected
    FTun: TObject;
    procedure Execute; override;
  end;

  { 一条 WS 透传隧道：client socket <-> worker socket。
    两个 socket 的归宿不同，用 AOwnClient 区分：
      - FPC 3.3.1：走 fphttpserver 的升级机制，CheckUpgrade 返回后连接会把
        FSocket 置 nil（见 fphttpserver.DoHandleRequest），所有权移交给我们，
        AOwnClient=True —— 不释放就每个 WS 连接漏一个 TSocketStream；
      - FPC 3.2.2：没有该机制，socket 仍归连接对象，AOwnClient=False。
    worker socket 恒由 WSTunnel 自建，恒由隧道释放。 }
  TLWWSTunnel = class
  private
    FLock: TRTLCriticalSection;
    FClient, FWorker: TSocketStream;
    FClientOurs: Boolean; { client socket 是否归隧道释放 }
    FPeer: TLWWSPump;     { 反方向的泵线程 }
    FClosed: Boolean;
    procedure CloseAll;
  public
    constructor Create(AClient, AWorker: TSocketStream; AOwnClient: Boolean);
    destructor Destroy; override;
    { 反方向泵（由 TLWWSPump 线程调用）：worker->client }
    procedure PumpPeer;
    { 阻塞泵 client->worker；内部另起线程泵 worker->client。
      任一方向结束即关闭两端并返回 }
    procedure Run;
  end;

  TLWHyperServer = class
  private
    FCfg: TLWHyperConfig;
    FWorkers: array of TLWWorker;
    FPlugins: TLWHyperPluginManager;  { 仅 PluginMode 下创建 }
    FLookup: TLWPluginIdentityLookup; { 宿主注入的 sid -> 身份查询 }
    FAuth: TLWHyperAuth;              { 仅 PluginMode + AuthEnabled 下创建 }
    FHTTP: TFPHttpServer;
    FMap: TStringList;             { sid -> worker 下标 }
    FMapLock: TRTLCriticalSection;
    FLock: TRTLCriticalSection;
    { worker 进程起停锁：巡检线程与热更新线程都会 Kill/Launch 同一个 Proc，
      没有这把锁就可能一方刚 Free、另一方正在读 Proc.Running（AV） }
    FWorkerLock: TRTLCriticalSection;
    FRR: Integer;                  { 轮询游标 }
    FMonitor: TLWHyperMonitor;
    FUpdater: TLWHyperUpdater;
    FUpdating: Boolean;            { 滚动更新进行中：巡检线程不插手 worker 起停 }
    FUpdateCount: Integer;         { 累计成功的热更新次数 }
    FStartedAt: TDateTime;
    { WS 隧道计数：wsopen = 当前正在透传的条数（收尾正确时必然回 0），
      wsdone = 累计正常收尾的条数。排查"每连接漏一个对象"用它们最快：
      wsopen 单调上涨就是漏，wsdone 涨而 wsopen 回 0 就是干净 }
    FWSOpen: Integer;
    FWSDone: Integer;
    function AliveCount: Integer;
    function SessionsTotal: Integer;
    function DoHealthProbe(APort: Word; out ASessions: Integer): Boolean;
    { Proc 起停的两个加锁入口：巡检线程与热更新线程共用，避免并发 Kill/Launch }
    function WorkerRunning(AIndex: Integer): Boolean;
    procedure RelaunchWorker(AIndex: Integer; AHotUpdate: Boolean = False);
    { 请 worker 自己优雅退出（POST /lw/shutdown），并等进程真的结束。
      返回 True = 优雅退出成功；False = 没应答/超时，由调用方强杀兜底 }
    function ShutdownWorker(AIndex: Integer; ATimeoutMs: Integer): Boolean;
    function PickWorker(const ASid: string): Integer;
    procedure BindSid(const ASid: string; AIndex: Integer);
    procedure ClearWorkerSids(AIndex: Integer);
    function LearnSessionSid(var AResponse: TFPHTTPConnectionResponse): string;
    function WorkerURL(AIndex: Integer; const APathAndQuery: string): string;
    function RequestSid(var ARequest: TFPHTTPConnectionRequest): string;
    { 事件帧 sid 在 JSON body 里的提取（见实现注释） }
    function BodySid(ARequest: TFPHTTPConnectionRequest): string;
    procedure HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    procedure Route(var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    { 转发请求到 worker；成功返回 True。失败时已回 502 并把该 worker
      当场标记为 dead（不等下一轮 healthz），调用方可换 worker 重试 }
    function ProxyHTTP(var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse; AIndex: Integer): Boolean;
    procedure Reply(const AText, AMime: string; ACode: Integer;
      var AResponse: TFPHTTPConnectionResponse);
    { 插件模式：宿主直出框架静态资源（/lw/*.js|css、/ext/*、favicon） }
    procedure ServeLocalAsset(const ARelativePath: string;
      var AResponse: TFPHTTPConnectionResponse);
    procedure ApiHealth(var AResponse: TFPHTTPConnectionResponse);
    procedure ApiStatus(var AResponse: TFPHTTPConnectionResponse);
    { ---- 插件模式的登录入口（/、/login、/lw/login、/lw/logout、/p/ 闸门） ---- }
    procedure LoadAuthUsers;   { Start 时读用户表；失败直接抛异常，配置错误不静默 }
    function HandleAuthRoute(const APath, AMethod: string;
      var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse): Boolean;
    { True = 已拦截（重定向 / 401）；False = 已登录，调用方继续走插件路由 }
    function PluginGate(var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse; const APath: string): Boolean;
    procedure BuildUIItems(const ARoles: string; out AItems: TLWHyperUIItems;
      out ATotal: Integer);
    procedure ReplyPage(const AHTML: string; ACode: Integer;
      var AResponse: TFPHTTPConnectionResponse);
    procedure RedirectTo(const ALocation: string;
      var AResponse: TFPHTTPConnectionResponse);
    { WebSocket }
    procedure WSHandlesUpgrade(aRequest: TFPHTTPConnectionRequest;
      var aHandles: Boolean);
    procedure WSUpgrade(aConnection: TFPHTTPConnection;
      aRequest: TFPHTTPConnectionRequest);
    { WebSocket 透传本体。FPC 3.3.1 走 fphttpserver 的连接升级机制，
      socket 所有权归我们（AOwnSocket=True）；FPC 3.2.2 没有该机制，
      由 HandleRequest 在请求回调里接管（AOwnSocket=False，
      socket 由连接析构释放） }
    procedure WSTunnel(AClient: TSocketStream; aRequest: TFPHTTPConnectionRequest;
      AOwnSocket: Boolean);
  public
    constructor Create(const ACfg: TLWHyperConfig);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    { 插件模式注入身份查询回调。注入后自动开启 /p/ 鉴权与身份头签名；
      不注入则插件路由沿用 lwroute 默认行为（不鉴权、不传身份）。 }
    procedure SetIdentityLookup(ALookup: TLWPluginIdentityLookup);
    property Cfg: TLWHyperConfig read FCfg;
    property Plugins: TLWHyperPluginManager read FPlugins;
    { worker 明细 JSON（/lw/hyper/status 响应体同源）。
      GUI 面板（lwhyper_gui）在主线程定时调它刷 ListView；
      与 HTTP 线程读写同一组字段，粒度同 ApiStatus（良性读竞争） }
    function StatusJSON: string;
  end;

{ 解析命令行填 TLWHyperConfig；参数非法（缺 --exe 等）返回 False }
function LWHyperParseArgs(var ACfg: TLWHyperConfig): Boolean;
procedure LWHyperBanner(const ACfg: TLWHyperConfig);
{ 热更新监听的新版本文件路径。横幅与 updater 共用同一个函数，
  免得"横幅说看 A、实际盯 B" }
function LWHyperUpdateTarget(const ACfg: TLWHyperConfig): string;

implementation

const
  POLL_MS = 2000;   { healthz 巡检间隔 }
  HU_POLL_MS = 2000;   { 新版本文件轮询间隔 }
  HU_READY_MS = 30000; { 单个 worker 换上新品后等待就绪的上限 }

{ lwroute 的回调是全局函数指针；TLWHyperServer 通常一进程一实例，
  这里用一个"当前实例"间接层把回调转给注入的 FLookup。 }
var
  GHyperPluginServer: TLWHyperServer = nil;

function LWHyperPluginAuthGuard(const AName, ASid: string;
  out AUser, AReason: string): Boolean;
var
  p: TLWHyperPlugin;
  roles, dummy: string;
begin
  AUser := '';
  AReason := '';
  Result := False;
  if (GHyperPluginServer = nil) or (GHyperPluginServer.FPlugins = nil) or
     (not Assigned(GHyperPluginServer.FLookup)) then
    Exit(True);   { 没注入身份查询 = 不启用鉴权，与旧 lwroute 行为一致 }
  p := GHyperPluginServer.FPlugins.ByName(AName);
  if p = nil then roles := '' else roles := p.Roles;
  Result := LWPluginAuthorize(GHyperPluginServer.FLookup, ASid, roles,
    AUser, dummy, AReason);
end;

function LWHyperPluginIdentity(const ASid: string;
  out AUser, ARoles, AToken, ATS: string): Boolean;
begin
  AUser := '';
  ARoles := '';
  AToken := '';
  ATS := '';
  Result := False;
  if (GHyperPluginServer = nil) or
     (not Assigned(GHyperPluginServer.FLookup)) then Exit;
  Result := GHyperPluginServer.FLookup(ASid, AUser, ARoles);
  if not Result then Exit;
  ATS := IntToStr(DateTimeToUnix(Now, False));
  AToken := LWPluginSignIdentity(AUser, ARoles, ATS);
end;

{ hop-by-hop 头：代理必须剥掉（RFC 7230 6.1）+ 由两端各自生成的头 }
function IsHopByHop(const AName: string): Boolean;
begin
  Result :=
    SameText(AName, 'connection') or SameText(AName, 'keep-alive') or
    SameText(AName, 'transfer-encoding') or SameText(AName, 'te') or
    SameText(AName, 'trailer') or SameText(AName, 'upgrade') or
    SameText(AName, 'proxy-connection') or SameText(AName, 'expect') or
    SameText(AName, 'host') or SameText(AName, 'content-length');
end;

function PathPart(const AURL: string): string;
var
  q: Integer;
begin
  Result := AURL;
  q := Pos('?', Result);
  if q > 0 then Result := Copy(Result, 1, q - 1);
  if Result = '' then Result := '/';
end;

function BoolStr(B: Boolean): string;
begin
  if B then Result := 'yes' else Result := 'no';
end;

{ ---------------- 热更新的文件/端口工具 ---------------- }

{ 改名优先；跨卷（MoveFile 报 ERROR_NOT_SAME_DEVICE）或目标被占用时退回复制。
  热更新用它做"换壳"，两步都必须是原子的，所以失败要能被调用方看见 }
function LWMoveFile(const ASrc, ADst: string): Boolean;
var
  src, dst: TFileStream;
begin
  Result := SysUtils.RenameFile(ASrc, ADst);
  if Result then Exit;
  Result := False;
  src := nil;
  dst := nil;
  try
    try
      src := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
      dst := TFileStream.Create(ADst, fmCreate);
      dst.CopyFrom(src, 0);
      Result := True;
    except
      Result := False;
    end;
  finally
    dst.Free;
    src.Free;
  end;
  if Result and (not SysUtils.DeleteFile(ASrc)) then
    LWLog('[hyper] 警告: 复制完成后未能删除源文件 ' + ASrc);
end;

{ 文件大小。FPC 的 SysUtils 没有"按文件名取大小"的重载（同名的是
  system.FileSize(var File) 和 TFileStream 版本），这里包一层 }
function LWFileSize64(const APath: string): Int64;
var
  fs: TFileStream;
begin
  Result := 0;
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      Result := fs.Size;
    finally
      fs.Free;
    end;
  except
    Result := 0;
  end;
end;

{ 端口上还有没有人在 listen。连得上 = 旧进程还没完全退出。
  TInetSocket.Create 在连接失败时抛异常，本机 refused 是立即返回的 }
function LWPortFree(APort: Word): Boolean;
var
  s: TInetSocket;
begin
  Result := True;
  s := nil;
  try
    try
      s := TInetSocket.Create('127.0.0.1', APort);
      Result := False;
    except
      Result := True;
    end;
  finally
    s.Free;
  end;
end;

{ 热更新重启前等旧进程把端口放掉：否则新进程 bind 失败直接退出，
  只能靠下一轮巡检再兜一次，白白多花两秒 }
function LWWaitPortFree(APort: Word; ATimeoutMs: Integer): Boolean;
var
  t0: TDateTime;
begin
  t0 := Now;
  while MilliSecondsBetween(Now, t0) < ATimeoutMs do
  begin
    if LWPortFree(APort) then Exit(True);
    Sleep(100);
  end;
  Result := LWPortFree(APort);
end;

{ ---------------- TLWWorker ---------------- }

constructor TLWWorker.Create(APort: Word);
begin
  inherited Create;
  Port := APort;
  Alive := False;
  Sessions := 0;
  Restarts := 0;
  Updates := 0;
  BootGuard := 0;
end;

destructor TLWWorker.Destroy;
begin
  Kill;
  inherited Destroy;
end;

procedure TLWWorker.Launch(const ACfg: TLWHyperConfig; AIndex: Integer);
var
  i: Integer;
  s: string;
  args, extra: TStringList;
begin
  Kill;
  args := TStringList.Create;
  try
    args.Add('--port=' + IntToStr(Port));
    args.Add('--nogui');
    if ACfg.Root <> '' then args.Add('--root=' + ACfg.Root);
    if ACfg.Theme <> '' then args.Add('--theme=' + ACfg.Theme);
    { 优雅退出令牌：worker 收到 POST /lw/shutdown（带该令牌头）后走正常
      停服流程退出，热更新就不必强杀。空则不加，worker 上也就没有该端点 }
    if ACfg.ShutdownToken <> '' then
      args.Add('--shutdown-token=' + ACfg.ShutdownToken);
    { PWA：worker 外壳也要注入 head/script，参数与宿主保持一致 }
    if ACfg.PWAEnabled then
    begin
      args.Add('--pwa');
      if ACfg.PWAName <> '' then args.Add('--pwa-name=' + ACfg.PWAName);
      if ACfg.PWAShortName <> '' then args.Add('--pwa-short-name=' + ACfg.PWAShortName);
      if ACfg.PWAThemeColor <> '' then args.Add('--pwa-theme=' + ACfg.PWAThemeColor);
      if ACfg.PWABackgroundColor <> '' then args.Add('--pwa-bg=' + ACfg.PWABackgroundColor);
      if ACfg.PWAVapidPublic <> '' then args.Add('--pwa-vapid-public=' + ACfg.PWAVapidPublic);
      if ACfg.PWAVapidPrivate <> '' then args.Add('--pwa-vapid-private=' + ACfg.PWAVapidPrivate);
      if ACfg.PWAVapidSubject <> '' then args.Add('--pwa-vapid-subject=' + ACfg.PWAVapidSubject);
      if ACfg.PWAPushToken <> '' then args.Add('--pwa-push-token=' + ACfg.PWAPushToken);
      if ACfg.PWAPushFile <> '' then args.Add('--pwa-push-file=' + ACfg.PWAPushFile);
      if ACfg.PWAMessageFile <> '' then args.Add('--pwa-message-file=' + ACfg.PWAMessageFile);
    end;
    { 注意：不能直接 args.DelimitedText := ExtraArgs —— 给 DelimitedText 赋值
      会先 Clear 整个列表，把上面刚加的 --port/--nogui 全部抹掉（坑 106：
      worker 因此拿默认端口 8090 起来，撞上 lwhyper 自己的监听口，无限重启。
      只要带了 --worker-args 就必现）。必须拆到临时列表再 AddStrings 追加。 }
    if ACfg.ExtraArgs <> '' then
    begin
      extra := TStringList.Create;
      try
        extra.StrictDelimiter := True;
        extra.Delimiter := ' ';
        extra.DelimitedText := ACfg.ExtraArgs;
        args.AddStrings(extra);
      finally
        extra.Free;
      end;
    end;
    args.Add('--log=' + LogPath);
    Proc := TProcess.Create(nil);
    Proc.Executable := ACfg.WorkerExe;
    for i := 0 to args.Count - 1 do
      Proc.Parameters.Add(args[i]);
    {$IFDEF MSWINDOWS}
    Proc.Options := Proc.Options + [poNoConsole];
    {$ENDIF}
    s := '';
    for i := 0 to args.Count - 1 do
      s := s + ' ' + args[i];
    LWLogFmt('[hyper] launch #%d port=%d exe=%s args=%s', [AIndex + 1, Port, ACfg.WorkerExe, s]);
    Proc.Execute;
  finally
    args.Free;
  end;
end;

procedure TLWWorker.Kill;
begin
  if Proc <> nil then
  begin
    if Proc.Running then
      Proc.Terminate(1);
    Proc.Free;
    Proc := nil;
  end;
end;

{ 随机令牌（32 个十六进制字符）。只用 Random 不用时间戳：时间戳在容器/
  同机多实例下容易撞，而这里唯一的用途是"同一个 worker 只认自家负载器" }
function LWMakeShutdownToken: string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to 4 do
    Result := Result + IntToHex(Random(MaxInt), 8);
end;

{ ---------------- healthz 探测 ---------------- }

{ 探 worker 的 /lw/healthz。IOTimeout 3 秒：探针不能被挂死的 worker 拖住 }
function ProbeWorkerHealth(APort: Word; out ASessions: Integer): Boolean;
var
  clt: TFPHTTPClient;
  ms: TMemoryStream;
  j: TJSONData;
  o: TJSONObject;
  v: TJSONData;
begin
  Result := False;
  ASessions := 0;
  clt := TFPHTTPClient.Create(nil);
  ms := TMemoryStream.Create;
  try
    try
      clt.AllowRedirect := False;
      clt.IOTimeout := 3000;
      clt.HTTPMethod('GET', 'http://127.0.0.1:' + IntToStr(APort) + '/lw/healthz', ms, []);
      ms.Position := 0;
      j := GetJSON(ms);
      try
        o := TJSONObject(j);
        v := o.Find('ok');
        Result := (v <> nil) and v.AsBoolean;
        v := o.Find('sessions');
        if v <> nil then
          ASessions := v.AsInteger;
      finally
        j.Free;
      end;
    except
      on E: Exception do
      begin
        LWLogFmt('[hyper] probe :%d EXC %s: %s', [APort, E.ClassName, E.Message]);
        Result := False;
      end;
    end;
  finally
    ms.Free;
    clt.Free;
  end;
end;

{ ---------------- TLWHyperMonitor ---------------- }

procedure TLWHyperMonitor.Execute;
var
  i: Integer;
  ok: Boolean;
  sess: Integer;
  w: TLWWorker;
begin
  LWLog('[hyper] monitor thread started');
  while not Terminated do
  begin
    if FHyper <> nil then
    begin
      for i := 0 to High(FHyper.FWorkers) do
      begin
        if Terminated then Exit;
        w := FHyper.FWorkers[i];
        ok := FHyper.DoHealthProbe(w.Port, sess);
        if (not ok) or FHyper.Cfg.Verbose then
          LWLogFmt('[hyper] probe #%d :%d -> %s (sess=%d)',
            [i + 1, w.Port, BoolStr(ok), sess]);
        { 热身闸门：重启后连续 BootGuard 次探针通过才重新对外 }
        if ok and (w.BootGuard > 0) then
          Dec(w.BootGuard);
        w.Alive := ok and (w.BootGuard <= 0);
        if ok and (w.BootGuard <= 0) then
          w.Sessions := sess;
        { 热更新进行中：worker 的起停由 updater 独占，这里只管探针。
          否则两边同时 Kill/Launch 会互相踩（重复起进程、端口抢占） }
        if FHyper.FUpdating then Continue;
        if not FHyper.WorkerRunning(i) then
        begin
          { worker 崩了：清掉粘在它上面的 sid，重启 }
          FHyper.ClearWorkerSids(i);
          LWLogFmt('[hyper] worker #%d (:%d) 异常退出，重启中 (第 %d 次)',
            [i + 1, w.Port, w.Restarts + 1]);
          { RelaunchWorker 内部会置 BootGuard=2：重启初期别急着放流量，
            连续两轮探针过了再说 }
          FHyper.RelaunchWorker(i, False);
          Inc(w.Restarts);
        end;
      end;
    end;
    { 分片 sleep，Terminate 能及时生效 }
    for i := 1 to (POLL_MS div 200) do
    begin
      if Terminated then Exit;
      Sleep(200);
    end;
  end;
end;

{ ---------------- TLWHyperUpdater ---------------- }

constructor TLWHyperUpdater.Create(AHyper: TLWHyperServer);
begin
  FHyper := AHyper;
  FDisabled := False;
  FFailSize := -1;
  FFailTime := -1;
  ResetStamp;
  FWatch := LWHyperUpdateTarget(AHyper.Cfg);
  { 监听对象正好是 exe 本身时停手：否则会把正在跑的镜像当成新版换掉 }
  if SameFileName(ExpandFileName(FWatch), ExpandFileName(AHyper.Cfg.WorkerExe)) then
  begin
    FDisabled := True;
    LWLog('[hyper] hot-update 关闭：监听路径与业务 exe 相同');
  end;
  FreeOnTerminate := False;
  inherited Create(True);   { 挂起创建，由 TLWHyperServer.Start 显式启动 }
end;

procedure TLWHyperUpdater.ResetStamp;
begin
  FStampSize := -1;
  FStampTime := -1;
  FStampHits := 0;
end;

{ 新版本文件是否已经"落定"：连续两轮探针大小与修改时间都不变，且能被
  独占打开（正在复制的文件拿不到独占句柄）。两个条件都满足才动手，
  否则半截文件会被换进去 }
function TLWHyperUpdater.CandidateReady: Boolean;
var
  sz: Int64;
  tm: LongInt;
  fs: TFileStream;
begin
  Result := False;
  if not FileExists(FWatch) then
  begin
    ResetStamp;
    Exit;
  end;
  sz := LWFileSize64(FWatch);
  tm := FileAge(FWatch);
  { 同一份文件上次换壳就失败了（exe 被占用之类）：等它变了再试，
    免得每 4 秒往日志里刷一遍同样的错误 }
  if (FFailSize >= 0) and (sz = FFailSize) and (tm = FFailTime) then Exit;
  if (sz = FStampSize) and (tm = FStampTime) then
    Inc(FStampHits)
  else
  begin
    FStampSize := sz;
    FStampTime := tm;
    FStampHits := 1;
  end;
  if (sz <= 0) or (FStampHits < 2) then Exit;
  fs := nil;
  try
    try
      fs := TFileStream.Create(FWatch, fmOpenRead or fmShareExclusive);
      Result := True;
    except
      FStampHits := 0;   { 还在写，下一轮重新攒计数 }
    end;
  finally
    fs.Free;
  end;
end;

{ 换壳：exe -> 备份名，新文件 -> exe。两步都是改名，不做逐字节拷贝。
  运行中的 exe 在 Windows 上不能覆盖写但可以改名，所以第一步对正在跑的
  worker 无害——它们继续跑已映射的旧镜像，直到被重启 }
function TLWHyperUpdater.SwapIn(const ANewFile: string; out AOldFile: string): Boolean;
var
  exe: string;
begin
  Result := False;
  exe := FHyper.Cfg.WorkerExe;
  AOldFile := exe + '.old-' + FormatDateTime('yyyymmdd-hhnnss', Now);
  if not LWMoveFile(exe, AOldFile) then
  begin
    LWLog('[hyper] hot-update 失败：无法移走当前 exe（被占用？）');
    Exit;
  end;
  if not LWMoveFile(ANewFile, exe) then
  begin
    LWLog('[hyper] hot-update 失败：无法换入新 exe，恢复原状');
    LWMoveFile(AOldFile, exe);
    Exit;
  end;
  Result := True;
end;

{ 停掉 worker #AIndex，用（已换入的）新 exe 重新拉起，等到它重新对外。
  Alive 由巡检线程按热身闸门置位，这里只等结果——不另开一套探针 }
function TLWHyperUpdater.RestartWorker(AIndex: Integer): Boolean;
var
  w: TLWWorker;
  t0: TDateTime;
  dead: Integer;
begin
  w := FHyper.FWorkers[AIndex];
  FHyper.ClearWorkerSids(AIndex);
  w.Alive := False;   { 立刻从路由池摘掉，别让新请求落进来 }
  LWLogFmt('[hyper] hot-update 重启 worker #%d (:%d)', [AIndex + 1, w.Port]);
  FHyper.RelaunchWorker(AIndex, True);
  t0 := Now;
  dead := 0;
  while MilliSecondsBetween(Now, t0) < HU_READY_MS do
  begin
    if Terminated then Exit(False);
    if w.Alive then Exit(True);
    { 进程起来就退（缺 DLL、初始化即崩）不用等满 30 秒：连续 6 秒没进程
      就判失败去回滚。慢启动的应用进程一直在跑，不会被误判 }
    if FHyper.WorkerRunning(AIndex) then
      dead := 0
    else
    begin
      Inc(dead);
      if dead >= 30 then
      begin
        LWLogFmt('[hyper] hot-update worker #%d 启动后立即退出', [AIndex + 1]);
        Exit(False);
      end;
    end;
    Sleep(200);
  end;
  Result := False;
end;

{ 回滚：坏 exe 改名留存（便于事后看），旧 exe 复位，已经把新版本跑起来的
  worker（0..AProgress）全部重启回旧版 }
procedure TLWHyperUpdater.Rollback(const AOldFile: string; AProgress: Integer);
var
  exe, bad: string;
  i: Integer;
begin
  exe := FHyper.Cfg.WorkerExe;
  bad := exe + '.bad-' + FormatDateTime('yyyymmdd-hhnnss', Now);
  if not LWMoveFile(exe, bad) then
  begin
    LWLog('[hyper] hot-update 回滚失败：无法移走新 exe');
    Exit;
  end;
  if not LWMoveFile(AOldFile, exe) then
  begin
    LWLog('[hyper] hot-update 回滚失败：无法恢复旧 exe，请手工处理');
    Exit;
  end;
  LWLogFmt('[hyper] hot-update 已回滚到旧版本，坏版本留存为 %s',
    [ExtractFileName(bad)]);
  for i := 0 to AProgress do
  begin
    { 回滚时的重启也可能失败（旧 exe 万一也被占）：单条失败不能让
      整个回滚流程半途而废，剩下的交给巡检线程兜底 }
    try
      FHyper.ClearWorkerSids(i);
      FHyper.RelaunchWorker(i, True);
    except
      on E: Exception do
        LWLogFmt('[hyper] hot-update 回滚重启 worker #%d 失败: %s',
          [i + 1, E.Message]);
    end;
  end;
end;

function TLWHyperUpdater.RunUpdate(const ANewFile: string): Boolean;
var
  oldFile: string;
  i, done: Integer;
begin
  Result := False;   { False = 连换壳都没成（文件没动过），调用方别再重试 }
  done := 0;
  i := -1;   { 当前处理到第几个 worker；异常回滚时要用它定位进度 }
  LWLogFmt('[hyper] hot-update 发现新版本: %s (%d 字节)',
    [ExtractFileName(ANewFile), LWFileSize64(ANewFile)]);
  if not SwapIn(ANewFile, oldFile) then Exit;
  Result := True;
  LWLogFmt('[hyper] hot-update 已换入新 exe（旧版留存 %s），开始逐个滚动重启',
    [ExtractFileName(oldFile)]);
  { 新 exe 可能根本不是有效的可执行文件 —— 那种情况下 TProcess.Execute 会
    直接抛异常（不是"起不来"，而是压根没起来）。异常必须也走回滚，否则
    集群会停在"exe 已被换成坏的、worker 全死"的状态 }
  try
    for i := 0 to High(FHyper.FWorkers) do
    begin
      if Terminated then
      begin
        LWLogFmt('[hyper] hot-update 被中断（服务正在停止），已完成 %d/%d',
          [done, Length(FHyper.FWorkers)]);
        Exit;
      end;
      if not RestartWorker(i) then
      begin
        LWLogFmt('[hyper] hot-update worker #%d 在 %d 秒内未就绪，回滚',
          [i + 1, HU_READY_MS div 1000]);
        Rollback(oldFile, i);
        Exit;
      end;
      Inc(done);
      LWLogFmt('[hyper] hot-update worker #%d 已运行新版本', [i + 1]);
    end;
  except
    on E: Exception do
    begin
      LWLogFmt('[hyper] hot-update 启动新版本失败: %s: %s，回滚',
        [E.ClassName, E.Message]);
      Rollback(oldFile, i);
      Exit;
    end;
  end;
  Inc(FHyper.FUpdateCount);
  if not SysUtils.DeleteFile(oldFile) then
    LWLogFmt('[hyper] hot-update 旧版本备份保留: %s（仍有进程映射，可稍后手工删）',
      [ExtractFileName(oldFile)]);
  LWLogFmt('[hyper] hot-update 完成：%d 个 worker 全部换到新版本', [done]);
end;

procedure TLWHyperUpdater.Execute;
var
  i: Integer;
  ok: Boolean;
begin
  if FDisabled then Exit;
  LWLogFmt('[hyper] hot-update 监听: %s（每 %d ms 检查，换版不中断服务）',
    [FWatch, HU_POLL_MS]);
  while not Terminated do
  begin
    try
      if CandidateReady then
      begin
        FHyper.FUpdating := True;
        try
          ok := RunUpdate(FWatch);
        finally
          FHyper.FUpdating := False;
        end;
        if not ok then
        begin
          { 换壳没成：记住这份文件，等它变了再试（避免日志被同一错误刷屏） }
          FFailSize := LWFileSize64(FWatch);
          FFailTime := FileAge(FWatch);
        end;
        ResetStamp;
      end;
    except
      on E: Exception do
      begin
        FHyper.FUpdating := False;
        LWLog('[hyper] hot-update 异常: ' + E.ClassName + ': ' + E.Message);
      end;
    end;
    for i := 1 to (HU_POLL_MS div 200) do
    begin
      if Terminated then Exit;
      Sleep(200);
    end;
  end;
end;

{ ---------------- TLWWSTunnel / TLWWSPump ---------------- }


procedure TLWWSPump.Execute;
begin
  if FTun is TLWWSTunnel then
    TLWWSTunnel(FTun).PumpPeer;
end;

constructor TLWWSTunnel.Create(AClient, AWorker: TSocketStream; AOwnClient: Boolean);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FClient := AClient;
  FWorker := AWorker;
  FClientOurs := AOwnClient;
  FClosed := False;
end;

destructor TLWWSTunnel.Destroy;
begin
  CloseAll;
  { 最终释放：CloseAll 只 shutdown（叫醒泵线程），close 由这里唯一一次
    完成。Run 返回前已经 WaitFor 过泵线程，此时不会再有人碰这两个对象 }
  if FClientOurs then
    FreeAndNil(FClient);
  FreeAndNil(FWorker);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TLWWSTunnel.CloseAll;
begin
  EnterCriticalSection(FLock);
  try
    if FClosed then Exit;
    FClosed := True;
    { 归我们释放的一侧只 shutdown：让阻塞在对端泵线程里的 select/recv
      立刻返回（泵循环里 LWCanRead 会变成"可读且 Read=0"），真正的
      close 留给析构里的 Free。
      不在这里 Close 的原因：TSocketStream.Close 不幂等，3.3.1 的 Free
      会再 Close 一次 —— 对同一句柄关闭两次，句柄被系统复用时可能误关
      别的连接。3.2.2 的 client 归连接对象，沿用原来的直接关闭。 }
    if FClient <> nil then
    begin
      if FClientOurs then
        lwwebsocket.LWSocketShutdown(FClient)
      else
        lwwebsocket.LWSocketClose(FClient);
    end;
    if FWorker <> nil then
      lwwebsocket.LWSocketShutdown(FWorker);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TLWWSTunnel.PumpPeer;
var
  buf: array[0..8191] of Byte;
  n: Integer;
begin
  try
    while True do
    begin
      if not lwwebsocket.LWCanRead(FWorker, 200) then
      begin
        if FClosed then Break;
        Continue;
      end;
      n := FWorker.Read(buf[0], SizeOf(buf));
      if n <= 0 then Break;
      FClient.WriteBuffer(buf[0], n);
    end;
  except
  end;
  CloseAll;
end;

procedure TLWWSTunnel.Run;
var
  buf: array[0..8191] of Byte;
  n: Integer;
begin
  { 反方向（worker->client）丢线程里泵 }
  FPeer := TLWWSPump.Create(True);
  FPeer.FTun := Self;
  FPeer.Start;
  try
    try
      while True do
      begin
        if not lwwebsocket.LWCanRead(FClient, 200) then
        begin
          if FClosed then Break;
          Continue;
        end;
        n := FClient.Read(buf[0], SizeOf(buf));
        if n <= 0 then Break;
        FWorker.WriteBuffer(buf[0], n);
      end;
    except
    end;
  finally
    CloseAll;
    if FPeer <> nil then
    begin
      FPeer.WaitFor;
      FPeer.Free;
      FPeer := nil;
    end;
  end;
end;

{ ---------------- TLWHyperServer ---------------- }

constructor TLWHyperServer.Create(const ACfg: TLWHyperConfig);
var
  i: Integer;
begin
  inherited Create;
  FCfg := ACfg;
  { 优雅退出令牌：每次启动随机重新生成，只存在于本进程内存与 worker 的
    命令行里（不落盘），作用是让 worker 认得出"停我是自家负载器" }
  if FCfg.ShutdownToken = '' then
  begin
    Randomize;
    FCfg.ShutdownToken := LWMakeShutdownToken;
  end;
  if FCfg.BasePort = 0 then
    FCfg.BasePort := FCfg.Port + 1;
  FMap := TStringList.Create;
  FMap.Sorted := True;
  FMap.Duplicates := dupError;
  InitCriticalSection(FMapLock);
  InitCriticalSection(FLock);
  InitCriticalSection(FWorkerLock);
  FRR := 0;
  FUpdating := False;
  FUpdateCount := 0;
  FStartedAt := Now;
  FPlugins := nil;
  FLookup := nil;
  FAuth := nil;
  if FCfg.PluginMode then
  begin
    { 插件模式不拉起旧 worker 池 / 不跑换壳 updater；插件进程由
      TLWHyperPluginManager 管，各自独立端口与清单热更新 }
    SetLength(FWorkers, 0);
    FCfg.PluginRoot := LWResolveExeRelativePath(FCfg.PluginRoot);
    FPlugins := TLWHyperPluginManager.Create(FCfg.PluginRoot);
    GHyperPluginServer := Self;
    { 登录入口：默认开。会话表由本实例持有，lwroute 的 /p/ 鉴权通过
      HyperAuthLookup（全局，因为那个回调类型是普通函数指针）查它 }
    if FCfg.AuthEnabled then
    begin
      FAuth := TLWHyperAuth.Create(FCfg.SessionMin);
      GHyperAuth := FAuth;
      FLookup := @HyperAuthLookup;
      SetIdentityLookup(@HyperAuthLookup);
    end
    else
    begin
      { 显式关掉鉴权（--no-auth）：别留下上一轮的 /p/ 回调，
        否则旧回调会拿空会话把请求全拒掉 }
      LWRouteSetAuth(nil);
      LWRouteSetIdentity(nil);
    end;
  end
  else
  begin
    SetLength(FWorkers, FCfg.WorkerCount);
    for i := 0 to FCfg.WorkerCount - 1 do
    begin
      FWorkers[i] := TLWWorker.Create(FCfg.BasePort + i);
      FWorkers[i].LogPath := IncludeTrailingPathDelimiter(FCfg.LogDir) +
        'worker' + IntToStr(i + 1) + '.log';
    end;
  end;
end;

destructor TLWHyperServer.Destroy;
var
  i: Integer;
begin
  { 热更新线程可能正在 Kill/Launch worker —— 必须先在它停稳后再收 worker }
  if FUpdater <> nil then
  begin
    FUpdater.Terminate;
    FUpdater.WaitFor;
    FreeAndNil(FUpdater);
  end;
  { FHTTP 在这里收：Stop 只负责唤醒 accept 循环，
    调用方必须先 WaitFor 启动线程再 Free 本对象 }
  FreeAndNil(FHTTP);
  FreeAndNil(FPlugins);
  if GHyperPluginServer = Self then GHyperPluginServer := nil;
  if (FAuth <> nil) and (GHyperAuth = FAuth) then
  begin
    GHyperAuth := nil;
    LWRouteSetAuth(nil);
    LWRouteSetIdentity(nil);
  end;
  FreeAndNil(FAuth);
  for i := 0 to High(FWorkers) do
    FWorkers[i].Free;
  SetLength(FWorkers, 0);
  FMap.Free;
  DoneCriticalSection(FMapLock);
  DoneCriticalSection(FLock);
  DoneCriticalSection(FWorkerLock);
  inherited Destroy;
end;

procedure TLWHyperServer.Start;
var
  i: Integer;
begin
  if FCfg.PluginMode then
  begin
    { 插件模式：先读用户表（配置错就当场报出来，别等到有人访问登录页
      才发现没有账号），再清单发现 -> 注册 /p/ 路由 -> 拉起插件 -> 巡检。 }
    LoadAuthUsers;
    FPlugins.Discover;
    FPlugins.RegisterRoutes;
    FPlugins.LaunchAll;
    FPlugins.StartMonitor;
  end
  else
  begin
    { 先拉 worker 再开监听；没就绪的 worker 会被探针标成 dead（代理回 502），
      不用阻塞等 }
    for i := 0 to High(FWorkers) do
      FWorkers[i].Launch(FCfg, i);
    { 守护线程必须在 FHTTP.Active := True 之前启动：
      trunk 的 SetActive -> StartAccepting 进入 accept 循环永不返回
      （与 nogui worker 同一行为），之后的代码永远执行不到 }
    FMonitor := TLWHyperMonitor.Create(True);
    FMonitor.FHyper := Self;
    FMonitor.Start;
    { 热更新线程同样要在 accept 循环之前起来（理由同上）。
      监听开关在配置里，关掉时不建线程 }
    if FCfg.HotUpdate then
    begin
      FUpdater := TLWHyperUpdater.Create(Self);
      FUpdater.Start;
    end;
  end;
  FHTTP := TFPHttpServer.Create(nil);
  FHTTP.Port := FCfg.Port;
  { TLS 只加在外层：浏览器 -> lwhyper 走 HTTPS，lwhyper -> worker 仍走 HTTP。
    自签证书零配置可用；正式环境给 --ssl-cert/--ssl-key。 }
  if FCfg.UseSSL then
  begin
    FHTTP.UseSSL := True;
    if FCfg.SSLHost <> '' then
      FHTTP.CertificateData.HostName := FCfg.SSLHost;
    if FCfg.SSLCertFile <> '' then
      FHTTP.CertificateData.Certificate.FileName := FCfg.SSLCertFile;
    if FCfg.SSLKeyFile <> '' then
      FHTTP.CertificateData.PrivateKey.FileName := FCfg.SSLKeyFile;
  end;
  { 每连接一个线程：3.3.1 用枚举 ThreadMode，3.2.2 只有一个布尔开关 }
  {$IF FPC_FULLVERSION >= 30301}
  FHTTP.ThreadMode := tmThread;
  {$ELSE}
  FHTTP.Threaded := True;
  {$ENDIF}
  FHTTP.QueueSize := 128;
  { accept 循环要能被叫醒：AcceptIdleTimeout=0 时 StopAccepting 只置标志，
    循环阻塞在 accept() 直到下一个连接 —— Stop 之后线程永远退不出来，
    GUI 的 WaitFor 就卡死（见 NOTES 坑 44，与 lwhttp 同源） }
  FHTTP.AcceptIdleTimeout := 250;
  FHTTP.OnRequest := @HandleRequest;
  { 连接升级处理器：FPC 3.3.1 起 fphttpserver 才有 RegisterUpdateHandler，
    3.2.2 没有 —— 那时改由 HandleRequest 自己接管 /lw/ws（见那里） }
  {$IF FPC_FULLVERSION >= 30301}
  FHTTP.RegisterUpdateHandler('websocket', @WSHandlesUpgrade, @WSUpgrade);
  {$ENDIF}
  FHTTP.Active := True;   { 阻塞在 accept 循环 }
end;

procedure TLWHyperServer.Stop;
var
  i: Integer;
begin
  if FCfg.PluginMode then
  begin
    if FPlugins <> nil then
    begin
      FPlugins.StopMonitor;
      FPlugins.StopAll;
    end;
    if FHTTP <> nil then FHTTP.Active := False;
    Exit;
  end;
  { 先停热更新线程：它可能正在重启 worker，晚停会和下面的 Kill 抢同一个进程 }
  if FUpdater <> nil then
  begin
    FUpdater.Terminate;
    FUpdater.WaitFor;
    FreeAndNil(FUpdater);
  end;
  if FMonitor <> nil then
  begin
    FMonitor.Terminate;
    FMonitor.WaitFor;
    FreeAndNil(FMonitor);
  end;
  { 只关监听唤醒 accept 循环（AcceptIdleTimeout=250，≤250ms 退出）。
    绝不能在这里 Free FHTTP —— accept 线程此刻还可能站在循环里，
    在它脚下拆对象必 AV（NOTES 坑 44.3）；FHTTP 由 Destroy 统一收，
    调用方（GUI / CLI）必须先等 Start 所在线程退出再释放本对象 }
  if FHTTP <> nil then
  begin
    FHTTP.Active := False;
  end;
  for i := 0 to High(FWorkers) do
    FWorkers[i].Kill;
end;

procedure TLWHyperServer.SetIdentityLookup(ALookup: TLWPluginIdentityLookup);
begin
  FLookup := ALookup;
  GHyperPluginServer := Self;
  if Assigned(ALookup) then
  begin
    LWRouteSetAuth(@LWHyperPluginAuthGuard);
    LWRouteSetIdentity(@LWHyperPluginIdentity);
  end
  else
  begin
    LWRouteSetAuth(nil);
    LWRouteSetIdentity(nil);
  end;
end;

{ ---------------- 插件模式的登录入口 ---------------- }

procedure TLWHyperServer.ReplyPage(const AHTML: string; ACode: Integer;
  var AResponse: TFPHTTPConnectionResponse);
begin
  Reply(AHTML, 'text/html; charset=utf-8', ACode, AResponse);
  AResponse.SetCustomHeader('Cache-Control', 'no-store');
end;

procedure TLWHyperServer.RedirectTo(const ALocation: string;
  var AResponse: TFPHTTPConnectionResponse);
begin
  { 302 而不是 301：登录态是会变的，别让浏览器把跳转永久缓存下来 }
  AResponse.Code := 302;
  AResponse.CodeText := 'Found';
  AResponse.SetCustomHeader('Location', ALocation);
  AResponse.SetCustomHeader('Cache-Control', 'no-store');
  AResponse.Content := '';
end;

procedure TLWHyperServer.LoadAuthUsers;
var
  err: string;
begin
  if (not FCfg.PluginMode) or (not FCfg.AuthEnabled) then Exit;
  if FAuth = nil then Exit;
  if not FAuth.LoadUsers(FCfg.UsersFile, err) then
    raise Exception.Create(
      '插件模式已启用登录（缺省行为），但用户表不可用：' + err +
      '。用 --users=<用户表.ini> 指定，或显式 --no-auth 关闭鉴权（仅本机调试）');
end;

procedure TLWHyperServer.BuildUIItems(const ARoles: string;
  out AItems: TLWHyperUIItems; out ATotal: Integer);
var
  i, n: Integer;
  p: TLWHyperPlugin;
begin
  SetLength(AItems, 0);
  ATotal := 0;
  if FPlugins = nil then Exit;
  ATotal := FPlugins.Count;
  for i := 0 to FPlugins.Count - 1 do
  begin
    p := FPlugins.Item(i);
    if p = nil then Continue;
    { 工作台只列当前角色能打开的：菜单不骗人；真正的强制点仍是路由层 }
    if not LWPluginCanOpen(ARoles, p.Roles) then Continue;
    n := Length(AItems);
    SetLength(AItems, n + 1);
    AItems[n].Name := p.Name;
    AItems[n].Title := p.Title;
    AItems[n].Group := p.Group;
    AItems[n].Roles := p.Roles;
    AItems[n].Port := p.Port;
    AItems[n].Alive := p.Alive;
  end;
end;

{ /p/ 闸门：没登录就别把请求放进插件路由（那里只会回 403 页面，
  用户看不出该去登录）。页面导航回登录页，插件内部的 /lw/* 调用给 401 JSON，
  免得把一段 HTML 塞进 fetch 的响应里。 }
function TLWHyperServer.PluginGate(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse; const APath: string): Boolean;

  function UrlEnc(const S: string): string;
  var
    i: Integer;
    c: Char;
  begin
    Result := '';
    for i := 1 to Length(S) do
    begin
      c := S[i];
      if ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
         ((c >= '0') and (c <= '9')) or (c = '-') or (c = '_') or
         (c = '.') or (c = '/') or (c = '?') or (c = '=') or (c = '&') then
        Result := Result + c
      else
        Result := Result + '%' + IntToHex(Ord(c), 2);
    end;
  end;

var
  u, r, d, tok, rest, sub, target: string;
  slashIdx: Integer;
begin
  Result := True;
  try
    if HyperAuthOf(FAuth, ARequest, u, r, d, tok) then Exit(False);
  except
    Exit(False);   { 鉴权自身出错时别把整站锁死，交给路由层判定 }
  end;

  rest := Copy(APath, Length('/p/') + 1, MaxInt);
  slashIdx := Pos('/', rest);
  if slashIdx > 0 then
    sub := Copy(rest, slashIdx, MaxInt)
  else
    sub := '/';

  if Copy(sub, 1, 4) = '/lw/' then
  begin
    { 插件页面里的接口调用：401 + JSON，前端好处理 }
    AResponse.Code := 401;
    AResponse.CodeText := 'Unauthorized';
    AResponse.ContentType := 'application/json; charset=utf-8';
    AResponse.Content := '{"ok":false,"err":"unauthenticated",' +
      '"msg":"会话不存在或已过期，请回到工作台重新登录"}';
    AResponse.SetCustomHeader('Cache-Control', 'no-store');
    Exit;
  end;

  target := '/login?next=' + UrlEnc(ARequest.URL);
  RedirectTo(target, AResponse);
end;

{ 返回 True = 这个请求已经处理完（页面/跳转/401），Route 直接返回。
  返回 False = 与登录无关或已登录放行，交给后面的插件路由。 }
function TLWHyperServer.HandleAuthRoute(const APath, AMethod: string;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse): Boolean;
var
  u, r, d, tok, next, user, pass, err, brand: string;
  items: TLWHyperUIItems;
  total: Integer;
begin
  Result := True;
  brand := HYPER_BRAND;

  { 工作台首页 }
  if (APath = '/') or (APath = '/index.html') or (APath = '/workbench') then
  begin
    if not HyperAuthOf(FAuth, ARequest, u, r, d, tok) then
    begin
      RedirectTo('/login?next=/', AResponse);
      Exit;
    end;
    BuildUIItems(r, items, total);
    ReplyPage(HyperWorkbenchPage(u, d, r, LWPluginRoleText(r), items, total, brand),
      200, AResponse);
    Exit;
  end;

  { 登录页（GET） }
  if APath = '/login' then
  begin
    if HyperAuthOf(FAuth, ARequest, u, r, d, tok) then
    begin
      RedirectTo('/', AResponse);
      Exit;
    end;
    next := '';
    if Assigned(ARequest.QueryFields) then
      next := ARequest.QueryFields.Values['next'];
    ReplyPage(HyperLoginPage('', next, FCfg.LoginHint, brand), 200, AResponse);
    Exit;
  end;

  { 登录提交 }
  if APath = '/lw/login' then
  begin
    if AMethod <> 'POST' then
    begin
      RedirectTo('/login', AResponse);
      Exit;
    end;
    user := Trim(ARequest.ContentFields.Values['user']);
    pass := ARequest.ContentFields.Values['pass'];
    { 登录页把 next 放在 form action 的 query 里（百分号编码），所以先读
      QueryFields —— 表单 body 里未编码的 '/' 在 fcl-web 的解析里会丢，
      用它当权威来源不可靠。hidden 字段只作兜底（老页面/直接 POST 的客户端） }
    next := '';
    if Assigned(ARequest.QueryFields) then
      next := ARequest.QueryFields.Values['next'];
    if next = '' then
      next := ARequest.ContentFields.Values['next'];
    err := '';
    if FAuth.Login(user, pass, tok, r, d, err) then
    begin
      { Cookie 落 Path=/：插件 iframe 里的子资源请求也自动带上，
        lwroute 的 RouteReqSid 从同一个 Cookie 名取到会话令牌 }
      HyperSetCookie(AResponse, HYPER_SID_COOKIE, tok, '/', FAuth.TTLMin * 60);
      LWLogFmt('[hyper-auth] 会话建立 user=%s from %s',
        [user, ARequest.RemoteAddress]);
      RedirectTo(HyperSafeNext(next), AResponse);
    end
    else
    begin
      LWLogFmt('[hyper-auth] 登录失败 user=%s from %s：%s',
        [user, ARequest.RemoteAddress, err]);
      ReplyPage(HyperLoginPage(err, next, FCfg.LoginHint, brand), 200, AResponse);
    end;
    Exit;
  end;

  { 注销 }
  if (APath = '/lw/logout') or (APath = '/logout') then
  begin
    tok := HyperRequestToken(ARequest);
    if tok <> '' then
    begin
      FAuth.Logout(tok);
      LWLog('[hyper-auth] 注销 token=' + Copy(tok, 1, 8) + '…');
    end;
    HyperClearCookie(AResponse, HYPER_SID_COOKIE, '/');
    RedirectTo('/login', AResponse);
    Exit;
  end;

  { 状态接口：暴露插件端口/进程信息，登录后才给看 }
  if APath = '/lw/hyper/status' then
  begin
    if not HyperAuthOf(FAuth, ARequest, u, r, d, tok) then
    begin
      AResponse.Code := 401;
      AResponse.CodeText := 'Unauthorized';
      AResponse.ContentType := 'application/json; charset=utf-8';
      AResponse.Content := '{"ok":false,"err":"unauthenticated"}';
      AResponse.SetCustomHeader('Cache-Control', 'no-store');
      Exit;
    end;
    ApiStatus(AResponse);
    Exit;
  end;

  { 工作台自身的静态资源（/lw/lw.js 等）。只给登录用户，避免未登录时
    也能从宿主批量拉前端文件 }
  if Copy(APath, 1, 4) = '/lw/' then
  begin
    if not HyperAuthOf(FAuth, ARequest, u, r, d, tok) then
    begin
      AResponse.Code := 401;
      AResponse.CodeText := 'Unauthorized';
      AResponse.ContentType := 'text/plain; charset=utf-8';
      AResponse.Content := '401 unauthorized';
      Exit;
    end;
    ServeLocalAsset(APath, AResponse);
    Exit;
  end;

  { 插件路由闸门：已登录返回 False 让 Route 继续走 lwroute }
  if Copy(APath, 1, 3) = '/p/' then
  begin
    Result := PluginGate(ARequest, AResponse, APath);
    Exit;
  end;

  Result := False;
end;

function TLWHyperServer.DoHealthProbe(APort: Word; out ASessions: Integer): Boolean;
begin
  Result := ProbeWorkerHealth(APort, ASessions);
end;

function TLWHyperServer.WorkerRunning(AIndex: Integer): Boolean;
begin
  { Proc 可能被另一个线程 Free：读它必须在锁里 }
  EnterCriticalSection(FWorkerLock);
  try
    Result := (FWorkers[AIndex].Proc <> nil) and FWorkers[AIndex].Proc.Running;
  finally
    LeaveCriticalSection(FWorkerLock);
  end;
end;

{ 让 worker 自己走正常停服流程退出：POST /lw/shutdown（带令牌头），
  再等进程真的结束。这样在途请求能答完、日志能刷盘、框架自己的收尾
  清理都能跑；强杀只在它不应答（进程挂死）时兜底。 }
function TLWHyperServer.ShutdownWorker(AIndex: Integer; ATimeoutMs: Integer): Boolean;
var
  clt: TFPHTTPClient;
  ms: TMemoryStream;
  t0: TDateTime;
  port: Word;
begin
  Result := False;
  if FCfg.ShutdownToken = '' then Exit;
  port := FWorkers[AIndex].Port;
  clt := TFPHTTPClient.Create(nil);
  ms := TMemoryStream.Create;
  try
    try
      clt.AllowRedirect := False;
      clt.ConnectTimeout := 1000;
      clt.IOTimeout := 3000;
      clt.RequestHeaders.Add('X-LW-Shutdown: ' + FCfg.ShutdownToken);
      clt.HTTPMethod('POST', 'http://127.0.0.1:' + IntToStr(port) + '/lw/shutdown',
        ms, []);
      Result := clt.ResponseStatusCode = 200;
      if not Result then
        LWLogFmt('[hyper] worker :%d 拒绝优雅退出（HTTP %d），改强杀',
          [port, clt.ResponseStatusCode]);
    except
      on E: Exception do
      begin
        LWLogFmt('[hyper] worker :%d 优雅退出请求失败: %s，改强杀', [port, E.Message]);
        Result := False;
      end;
    end;
  finally
    ms.Free;
    clt.Free;
  end;
  if not Result then Exit;
  { 等它自己退：worker 的 Stop 最长会等 3 秒让连接线程收工，这里给足余量 }
  t0 := Now;
  while MilliSecondsBetween(Now, t0) < ATimeoutMs do
  begin
    if not WorkerRunning(AIndex) then Exit(True);
    Sleep(100);
  end;
  LWLogFmt('[hyper] worker :%d 在 %d ms 内未退出，改强杀', [port, ATimeoutMs]);
  Result := False;
end;

{ Kill + Launch 一步到位（巡检线程与热更新线程共用）。
  AHotUpdate=True 先请 worker 自己优雅退出（在途请求能答完），不应答才强杀；
  并在重启前等端口释放。等端口放在锁外做，免得把巡检线程按在这里 } 
procedure TLWHyperServer.RelaunchWorker(AIndex: Integer; AHotUpdate: Boolean);
begin
  if AHotUpdate then
  begin
    { 10 秒上限：worker 正常收尾通常几百毫秒，挂死才会走满 }
    if not ShutdownWorker(AIndex, 10000) then
      LWLogFmt('[hyper] worker :%d 未能优雅退出，强杀', [FWorkers[AIndex].Port]);
  end;
  EnterCriticalSection(FWorkerLock);
  try
    { 已经优雅退出的，Kill 里 Proc.Running 为 False，只释放对象 }
    FWorkers[AIndex].Kill;
  finally
    LeaveCriticalSection(FWorkerLock);
  end;
  if AHotUpdate then
    LWWaitPortFree(FWorkers[AIndex].Port, 5000);
  EnterCriticalSection(FWorkerLock);
  try
    FWorkers[AIndex].Launch(FCfg, AIndex);
    FWorkers[AIndex].BootGuard := 2;
    if AHotUpdate then
      Inc(FWorkers[AIndex].Updates);
  finally
    LeaveCriticalSection(FWorkerLock);
  end;
end;

function TLWHyperServer.AliveCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FWorkers) do
    if FWorkers[i].Alive then Inc(Result);
end;

function TLWHyperServer.SessionsTotal: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FWorkers) do
    Inc(Result, FWorkers[i].Sessions);
end;

{ sid -> worker 查表；无 sid（新会话）或未知 sid / 目标 worker 已死
  都走轮询兜底。全部 dead 才返回 -1 }
function TLWHyperServer.PickWorker(const ASid: string): Integer;
var
  i, tries: Integer;
begin
  Result := -1;
  if ASid <> '' then
  begin
    EnterCriticalSection(FMapLock);
    try
      i := FMap.IndexOf(ASid);
      if i >= 0 then
        Result := PtrInt(FMap.Objects[i]);
    finally
      LeaveCriticalSection(FMapLock);
    end;
    if (Result >= 0) and (FWorkers[Result].Alive) then
      Exit;
    Result := -1;
  end;
  tries := 0;
  while tries < Length(FWorkers) do
  begin
    EnterCriticalSection(FLock);
    try
      i := FRR;
      FRR := (FRR + 1) mod Length(FWorkers);
    finally
      LeaveCriticalSection(FLock);
    end;
    if FWorkers[i].Alive then
    begin
      Result := i;
      Break;
    end;
    Inc(tries);
  end;
end;

procedure TLWHyperServer.BindSid(const ASid: string; AIndex: Integer);
var
  i: Integer;
begin
  if ASid = '' then Exit;
  EnterCriticalSection(FMapLock);
  try
    i := FMap.IndexOf(ASid);
    if i >= 0 then
    begin
      if PtrInt(FMap.Objects[i]) <> AIndex then
        FMap.Objects[i] := TObject(PtrInt(AIndex));
    end
    else
    begin
      try
        FMap.AddObject(ASid, TObject(PtrInt(AIndex)));
      except
        { dupError：并发下 sid 撞表理论上不该发生，忽略 }
      end;
    end;
  finally
    LeaveCriticalSection(FMapLock);
  end;
end;

procedure TLWHyperServer.ClearWorkerSids(AIndex: Integer);
var
  i: Integer;
begin
  EnterCriticalSection(FMapLock);
  try
    for i := FMap.Count - 1 downto 0 do
      if PtrInt(FMap.Objects[i]) = AIndex then
        FMap.Delete(i);
  finally
    LeaveCriticalSection(FMapLock);
  end;
end;

function TLWHyperServer.WorkerURL(AIndex: Integer; const APathAndQuery: string): string;
begin
  Result := 'http://127.0.0.1:' + IntToStr(FWorkers[AIndex].Port) + APathAndQuery;
end;

function TLWHyperServer.RequestSid(var ARequest: TFPHTTPConnectionRequest): string;
begin
  Result := Trim(ARequest.QueryFields.Values['sid']);
  if Result = '' then
    Result := Trim(ARequest.GetCustomHeader('X-LW-Sid'));
end;

{ 事件帧的 sid 也可以在 JSON body 里（服务端测试 / 直连客户端的
  POST /lw/api/event 就只发 body，不带 ?sid=）。不提取的话 PickWorker
  走轮询兜底，事件会被转到另一个 worker，worker 回 410 "session gone"
  —— 真前端不受影响（URL 永远带 sid），但任何走 body 的客户端都会
  被粘性路由漏掉。 }
function TLWHyperServer.BodySid(ARequest: TFPHTTPConnectionRequest): string;
var
  j: TJSONData;
begin
  Result := '';
  if (ARequest.Content = '') or
     (ARequest.ContentType <> 'application/json') then
    Exit;
  try
    j := GetJSON(ARequest.Content);
    try
      if j.JSONType = jtObject then
        Result := Trim(TJSONObject(j).Get('sid', ''));
    finally
      j.Free;
    end;
  except
    Result := '';
  end;
end;

procedure TLWHyperServer.Reply(const AText, AMime: string; ACode: Integer;
  var AResponse: TFPHTTPConnectionResponse);
begin
  AResponse.Code := ACode;
  {$IF FPC_FULLVERSION >= 30301}
  AResponse.CodeText := GetHTTPStatusText(ACode);        { 3.3.1 原生，与合并前一致 }
  {$ELSE}
  AResponse.CodeText := lwbase.LWHTTPStatusText(ACode);  { 3.2.2 无此函数 }
  {$ENDIF}
  AResponse.ContentType := AMime;
  AResponse.Content := AText;
end;

procedure TLWHyperServer.HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  handles: Boolean;
begin
  { FPC 3.2.2 兼容路径：没有 fphttpserver 的连接升级机制，只能在请求回调里
    接管 —— 握手转发 + 双向透传在 WSTunnel 里同步跑完（连接线程被这条
    WebSocket 独占，与 3.3.1 升级路径行为一致），结束后抛 ELWHyperUpgraded
    跳出，避免 fcl-web 再往已升级的 TCP 流上写 HTTP 响应。 }
  {$IF FPC_FULLVERSION < 30301}
  handles := False;
  if ARequest.Connection <> nil then
  begin
    WSHandlesUpgrade(ARequest, handles);
    if handles then
    begin
      WSTunnel(ARequest.Connection.Socket, ARequest, False);
      raise ELWHyperUpgraded.Create('websocket tunnel finished');
    end;
  end;
  {$ENDIF}
  try
    Route(ARequest, AResponse);
  except
    on E: Exception do
    begin
      try
        Reply('{"ok":false,"err":"hyper: ' + E.ClassName + '"}',
          'application/json; charset=utf-8', 502, AResponse);
      except
      end;
      LWLog('[hyper] ERROR ' + E.ClassName + ': ' + E.Message);
    end;
  end;
end;

procedure TLWHyperServer.Route(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  p, method, sid, iconPath, localPath: string;
  idx: Integer;
  uiItems: TLWHyperUIItems;
  uiTotal: Integer;
  routeResult: TLWRouteHandled;
  ms: TMemoryStream;
begin
  method := UpperCase(ARequest.Method);
  p := PathPart(ARequest.URL);
  sid := RequestSid(ARequest);
  if sid = '' then
    sid := BodySid(ARequest);

  if FCfg.Verbose then
    LWLogFmt('[hyper] %s %s (sid=%s)', [method, p, sid]);

  { 自身端点：healthz 汇总 / worker 明细，不进代理 }
  if (p = '/lw/healthz') or (p = '/lw/health') then
  begin
    ApiHealth(AResponse);
    Exit;
  end;

  { PWA 静态资源与端点由宿主直出，不转发给业务 worker/插件 }
  if LWPWAHandle(ARequest, AResponse) then Exit;

  { 插件模式 + 登录：工作台、登录、注销、状态、宿主静态资源、/p/ 闸门。
    健康探针 /lw/healthz 保持公开（LB/k8s 探针不登录）；其余在
    HandleAuthRoute 里判。未启用鉴权时整块跳过，行为与旧版一致。 }
  if FCfg.PluginMode and FCfg.AuthEnabled then
  begin
    if HandleAuthRoute(p, method, ARequest, AResponse) then Exit;
  end;

  if p = '/lw/hyper/status' then
  begin
    ApiStatus(AResponse);
    Exit;
  end;
  if p = '/favicon.ico' then
  begin
    { 站点图标：root 下 favicon.ico → exe 同目录 → 204 兜底。
      hyper 自己就该答 favicon，别把这种高频小请求转发给 worker }
    iconPath := IncludeTrailingPathDelimiter(FCfg.Root) + 'favicon.ico';
    if not FileExists(iconPath) then
      iconPath := ExtractFilePath(ParamStr(0)) + 'favicon.ico';
    if FileExists(iconPath) then
    begin
      ms := TMemoryStream.Create;
      try
        ms.LoadFromFile(iconPath);
        AResponse.Code := 200;
        AResponse.CodeText := 'OK';
        AResponse.ContentType := 'image/x-icon';
        AResponse.SetCustomHeader('Cache-Control', 'public, max-age=86400');
        AResponse.ContentStream := ms;
        AResponse.FreeContentStream := True;
      except
        ms.Free;
        AResponse.Code := 204;
      end;
    end
    else
      AResponse.Code := 204;
    Exit;
  end;

  { 插件模式但显式关了登录（--no-auth，仅本机调试）：/ 给一个直链页。
    不处理的话它会落到下面的 worker 代理分支，插件模式没有 worker，回 502 }
  if FCfg.PluginMode and (not FCfg.AuthEnabled) and
     ((p = '/') or (p = '/index.html') or (p = '/workbench')) then
  begin
    BuildUIItems('', uiItems, uiTotal);
    ReplyPage(HyperOpenIndexPage(uiItems, uiTotal, HYPER_BRAND), 200, AResponse);
    Exit;
  end;

  { 插件宿主模式：/p/<名>/ 走 lwroute 的插件路由（清单路由、鉴权、
    身份头、X-Forwarded-Prefix、301 补斜杠、502 页面都已在那里实现）。
    框架静态资源由宿主直出，不转发给插件。 }
  if FCfg.PluginMode and (Copy(p, 1, 3) = '/p/') then
  begin
    localPath := LWRouteStaticLocal(p);
    if localPath <> '' then
    begin
      ServeLocalAsset(localPath, AResponse);
      Exit;
    end;
    routeResult := LWRouteDispatch(ARequest, AResponse, p);
    if routeResult <> rrNotPlugin then Exit;
  end;

  idx := PickWorker(sid);
  if idx < 0 then
  begin
    Reply('{"ok":false,"err":"hyper: no alive worker"}',
      'application/json; charset=utf-8', 502, AResponse);
    Exit;
  end;

  { 死一个进程不能拖垮整体：转发失败立刻换下一个 worker 重试一次。
    ProxyHTTP 失败时已把该 worker 标死并回 502 —— 标死让 PickWorker
    下一把就跳过它，所以重试基本必中存活 worker }
  if not ProxyHTTP(ARequest, AResponse, idx) then
  begin
    idx := PickWorker('');
    if idx >= 0 then
      ProxyHTTP(ARequest, AResponse, idx);
  end;

  { 会话粘性：任何成功响应把请求携带的 sid 绑到该 worker；
    新会话（POST /lw/api/session 不带 sid）从响应 JSON 里学 sid }
  if (AResponse.Code div 100) = 2 then
  begin
    if sid <> '' then
      BindSid(sid, idx)
    else if p = '/lw/api/session' then
      BindSid(LearnSessionSid(AResponse), idx);
  end;
end;

{ 从刚代理回来的 /lw/api/session 响应体里抠 sid。
  响应在内存流里，读出来解析后把 Position 归零（响应还要原样发给浏览器）}
function TLWHyperServer.LearnSessionSid(var AResponse: TFPHTTPConnectionResponse): string;
var
  ms: TMemoryStream;
  s: AnsiString;
  j: TJSONData;
begin
  Result := '';
  try
    if (AResponse.ContentStream = nil) or
       (not (AResponse.ContentStream is TMemoryStream)) then Exit;
    ms := TMemoryStream(AResponse.ContentStream);
    ms.Position := 0;
    SetLength(s, ms.Size);
    if ms.Size > 0 then
      ms.Read(s[1], ms.Size);
    j := GetJSON(s);
    try
      Result := Trim(TJSONObject(j).Get('sid', ''));
    finally
      j.Free;
    end;
  except
    Result := '';
  end;
  if AResponse.ContentStream <> nil then
    AResponse.ContentStream.Position := 0;
end;

function TLWHyperServer.ProxyHTTP(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse; AIndex: Integer): Boolean;
var
  clt: TFPHTTPClient;
  body, ms: TMemoryStream;
  i, n: Integer;
  name, val, ct: string;
begin
  Result := False;
  clt := TFPHTTPClient.Create(nil);
  body := nil;
  ms := TMemoryStream.Create;
  try
    clt.AllowRedirect := False;
    { 关键：fphttpclient 在 Windows 上把 connection refused 当超时处理，
      缺省要烧 3 秒才报错 —— 死 worker 的每个请求都会慢 3 秒。
      本地转发 connect 毫秒级完成，1 秒足够宽裕 }
    clt.ConnectTimeout := 1000;
    clt.IOTimeout := 30000;
    { 请求头透传（剥 hop-by-hop） }
    for i := 0 to ARequest.CustomHeaders.Count - 1 do
    begin
      name := ARequest.CustomHeaders.Names[i];
      val := Trim(ARequest.CustomHeaders.Values[name]);
      if val = '' then Continue;
      if IsHopByHop(name) then Continue;
      clt.RequestHeaders.Add(name + ': ' + val);
    end;
    clt.RequestHeaders.Values['X-Forwarded-For'] := ARequest.RemoteAddress;

    { 请求体透传（原始字节，multipart 原样）。
      FPC 3.3.1 的 fphttpserver 把请求体读进 TRequest.ContentBytes；
      3.2.2 没有这个属性，ReadRequestContent 走的是 InitContent(S)，
      原始字节落在 TRequest.Content（RawByteString，二进制安全）。
      两者都直接写进内存流，不做任何解码 —— 上传大文件、multipart 边界
      和中途的二进制数据都必须原样过去。 }
    {$IF FPC_FULLVERSION >= 30301}
    if Length(ARequest.ContentBytes) > 0 then
    begin
      body := TMemoryStream.Create;
      body.WriteBuffer(ARequest.ContentBytes[0], Length(ARequest.ContentBytes));
      body.Position := 0;
      clt.RequestBody := body;
    end;
    {$ELSE}
    if Length(ARequest.Content) > 0 then
    begin
      body := TMemoryStream.Create;
      body.WriteBuffer(ARequest.Content[1], Length(ARequest.Content));
      body.Position := 0;
      clt.RequestBody := body;
    end;
    {$ENDIF}

    try
      clt.HTTPMethod(ARequest.Method, WorkerURL(AIndex, ARequest.URL), ms, []);
    except
      on E: Exception do
      begin
        LWLogFmt('[hyper] worker :%d 转发失败: %s', [FWorkers[AIndex].Port, E.Message]);
        { 当场标死：不等下一轮 healthz（间隔 2s，期间每个粘住的请求
          都会再撞一次）。下一轮探针通过（热身闸门后）会重新放行 }
        FWorkers[AIndex].Alive := False;
        Reply('{"ok":false,"err":"hyper: worker unreachable"}',
          'application/json; charset=utf-8', 502, AResponse);
        Exit;
      end;
    end;
    Result := True;   { worker 已应答，后续只是搬运 }

    { 响应头透传（剥 hop-by-hop 与 fphttpserver 自己生成的头）。
      content-length 不抄：ContentStream 赋值时框架自动按流大小设置 }
    AResponse.Code := clt.ResponseStatusCode;
    {$IF FPC_FULLVERSION >= 30301}
    AResponse.CodeText := GetHTTPStatusText(clt.ResponseStatusCode);
    {$ELSE}
    AResponse.CodeText := lwbase.LWHTTPStatusText(clt.ResponseStatusCode);
    {$ENDIF}
    n := clt.ResponseHeaders.Count - 1;
    for i := 0 to n do
    begin
      name := clt.ResponseHeaders.Names[i];
      val := Trim(clt.ResponseHeaders.Values[name]);
      if val = '' then Continue;
      if IsHopByHop(name) then Continue;
      if SameText(name, 'server') or SameText(name, 'date') or
         SameText(name, 'content-type') or SameText(name, 'content-length') then
        Continue;
      AResponse.CustomHeaders.Add(name + ': ' + val);
    end;
    ct := clt.ResponseHeaders.Values['content-type'];
    if ct = '' then ct := 'application/octet-stream';
    AResponse.ContentType := ct;

    if (clt.ResponseStatusCode = 204) or (clt.ResponseStatusCode = 304) or
       (ms.Size = 0) then
    begin
      AResponse.Content := '';
      Exit;
    end;
    ms.Position := 0;
    AResponse.ContentStream := ms;
    AResponse.FreeContentStream := True;
    ms := nil;   { 所有权移交给响应对象 }
  finally
    ms.Free;
    body.Free;
    clt.Free;
  end;
end;

function HyperLocalMime(const APath: string): string;
var
  ext: string;
begin
  ext := LowerCase(ExtractFileExt(APath));
  if ext = '.js' then Result := 'application/javascript; charset=utf-8'
  else if ext = '.css' then Result := 'text/css; charset=utf-8'
  else if ext = '.html' then Result := 'text/html; charset=utf-8'
  else if ext = '.json' then Result := 'application/json; charset=utf-8'
  else if ext = '.ico' then Result := 'image/x-icon'
  else if ext = '.png' then Result := 'image/png'
  else if ext = '.jpg' then Result := 'image/jpeg'
  else if ext = '.svg' then Result := 'image/svg+xml'
  else Result := 'application/octet-stream';
end;

{ /p/<名>/lw/lw.js 由 LWRouteStaticLocal 归一成 /lw/lw.js；
  这里按 lazarusWeb 既有惯例找 root\lw\、exe\lw\、root\src\client\ }
function HyperFindLocalFile(const ARelativePath, ARoot: string): string;
var
  rel, nm, d, cand: string;
  i: Integer;
begin
  Result := '';
  if (ARelativePath = '') or (ARelativePath[1] <> '/') then Exit;
  rel := Copy(ARelativePath, 2, MaxInt);   { 去开头 '/' }
  nm := ExtractFileName(rel);

  if ARoot <> '' then
  begin
    cand := IncludeTrailingPathDelimiter(ARoot) + rel;
    if FileExists(cand) then Exit(cand);
    cand := IncludeTrailingPathDelimiter(ARoot) + 'lw' + PathDelim + nm;
    if FileExists(cand) then Exit(cand);
    d := IncludeTrailingPathDelimiter(ARoot);
    for i := 0 to 4 do
    begin
      cand := d + 'src' + PathDelim + 'client' + PathDelim + nm;
      if FileExists(cand) then Exit(cand);
      cand := ExcludeTrailingPathDelimiter(d);
      d := IncludeTrailingPathDelimiter(ExtractFileDir(cand));
      if (d = '') or (ExcludeTrailingPathDelimiter(d) = cand) then Break;
    end;
  end;

  cand := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + rel;
  if FileExists(cand) then Exit(cand);
  cand := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
    'lw' + PathDelim + nm;
  if FileExists(cand) then Exit(cand);
end;

procedure TLWHyperServer.ServeLocalAsset(const ARelativePath: string;
  var AResponse: TFPHTTPConnectionResponse);
var
  path: string;
  ms: TMemoryStream;
begin
  if (FCfg.Root = '') and FCfg.PluginMode then
    path := HyperFindLocalFile(ARelativePath, FCfg.PluginRoot)
  else
    path := HyperFindLocalFile(ARelativePath, FCfg.Root);
  if path = '' then
  begin
    AResponse.Code := 404;
    AResponse.CodeText := 'Not Found';
    AResponse.ContentType := 'text/plain; charset=utf-8';
    AResponse.Content := '404 static asset not found: ' + ARelativePath;
    Exit;
  end;
  ms := TMemoryStream.Create;
  try
    ms.LoadFromFile(path);
    AResponse.Code := 200;
    AResponse.CodeText := 'OK';
    AResponse.ContentType := HyperLocalMime(path);
    AResponse.SetCustomHeader('Cache-Control', 'public, max-age=86400');
    AResponse.ContentStream := ms;
    AResponse.FreeContentStream := True;
    ms := nil;
  finally
    ms.Free;
  end;
end;

procedure TLWHyperServer.ApiHealth(var AResponse: TFPHTTPConnectionResponse);
var
  j: TJSONObject;
begin
  j := TJSONObject.Create;
  try
    if FCfg.PluginMode then
    begin
      j.Add('ok', (FPlugins <> nil) and (FPlugins.Count > 0));
      j.Add('role', 'hyper-plugin');
      j.Add('workers', 0);
      if FPlugins = nil then j.Add('alive', 0) else j.Add('alive', FPlugins.Count);
      j.Add('sessions', 0);
    end
    else
    begin
      j.Add('ok', AliveCount > 0);
      j.Add('role', 'hyper');
      j.Add('workers', Length(FWorkers));
      j.Add('alive', AliveCount);
      j.Add('sessions', SessionsTotal);
    end;
    j.Add('uptime', SecondsBetween(Now, FStartedAt));
    Reply(j.AsJSON, 'application/json; charset=utf-8', 200, AResponse);
  finally
    j.Free;
  end;
end;

function TLWHyperServer.StatusJSON: string;
var
  j: TJSONObject;
  w: TJSONObject;
  arr: TJSONArray;
  pj: TJSONData;
  i: Integer;
begin
  j := TJSONObject.Create;
  try
    j.Add('ok', True);
    if FCfg.PluginMode then
    begin
      j.Add('mode', 'plugin');
      j.Add('pluginroot', FCfg.PluginRoot);
      { 登录入口的可观测性：auth=false 表示 /p/ 匿名放行（显式 --no-auth） }
      j.Add('auth', FCfg.AuthEnabled);
      if FCfg.AuthEnabled then
      begin
        j.Add('users', FAuth.UserCount);
        j.Add('sessions', FAuth.SessionCount);
        j.Add('sessionmin', FAuth.TTLMin);
      end;
      if FPlugins <> nil then
      begin
        pj := GetJSON(FPlugins.StatusJSON);
        j.Add('plugins', pj);
      end;
    end
    else
      j.Add('mode', 'worker');
    j.Add('listen', FCfg.Port);
    j.Add('exe', FCfg.WorkerExe);
    { 热更新可观测性：updating 表示正在滚动换版，updates 是累计成功次数 }
    j.Add('hotupdate', FCfg.HotUpdate);
    j.Add('updating', FUpdating);
    j.Add('updates', FUpdateCount);
    arr := TJSONArray.Create;
    for i := 0 to High(FWorkers) do
    begin
      w := TJSONObject.Create;
      w.Add('n', i + 1);
      w.Add('port', FWorkers[i].Port);
      if FWorkers[i].Proc <> nil then
        w.Add('pid', FWorkers[i].Proc.ProcessID)
      else
        w.Add('pid', 0);
      w.Add('alive', FWorkers[i].Alive);
      w.Add('sessions', FWorkers[i].Sessions);
      w.Add('restarts', FWorkers[i].Restarts);
      w.Add('updates', FWorkers[i].Updates);
      arr.Add(w);
    end;
    j.Add('workers', arr);
    EnterCriticalSection(FMapLock);
    try
      j.Add('sticky', FMap.Count);
    finally
      LeaveCriticalSection(FMapLock);
    end;
    { WS 隧道计数 + 当前堆占用。wsopen 收尾正确时必然回 0；heap 用来
      判断"反复建/断连接"到底有没有漏字节（配合 tests/t_ws_churn.py） }
    j.Add('wsopen', FWSOpen);
    j.Add('wsdone', FWSDone);
    j.Add('heap', Int64(GetFPCHeapStatus.CurrHeapUsed));
    Result := j.AsJSON;
  finally
    j.Free;
  end;
end;

procedure TLWHyperServer.ApiStatus(var AResponse: TFPHTTPConnectionResponse);
begin
  Reply(StatusJSON, 'application/json; charset=utf-8', 200, AResponse);
end;

{ ---------------- WebSocket 透传 ---------------- }

{ 读一个请求头：先查标准位置，查不到再退回 CustomHeaders。
  为什么需要这个：FPC 3.2.2 的 fphttpserver 用 SetFieldByName 存请求头，
  THTTPHeader 字段表里没有映射的头（Upgrade、Sec-WebSocket-* 等）会被
  塞进 CustomHeaders，GetHeader 返回空串 —— 于是"是不是 WebSocket 升级"
  永远判 False，浏览器侧的 /lw/ws 直接落进普通路由变成 404。
  3.3.1 把常见头放进了 Headers，但两个位置都查一遍对它是无害的。 }
function LWReqHeader(aRequest: TFPHTTPConnectionRequest;
  const AStdValue: string; const AAlt: string): string;
begin
  Result := Trim(AStdValue);
  { 只有 3.2.2 需要退回 CustomHeaders 兜底；3.3.1 下保持原样（只看标准位置），
    行为与合并前一致 }
  {$IF FPC_FULLVERSION < 30301}
  if Result = '' then
    Result := Trim(aRequest.CustomHeaders.Values[AAlt]);
  {$ENDIF}
end;

procedure TLWHyperServer.WSHandlesUpgrade(aRequest: TFPHTTPConnectionRequest;
  var aHandles: Boolean);
begin
  aHandles :=
    SameText(LWReqHeader(aRequest, aRequest.GetHeader(hhUpgrade), 'upgrade'),
      'websocket') and
    (Copy(PathPart(aRequest.URL), 1, 6) = '/lw/ws');
end;

procedure TLWHyperServer.WSUpgrade(aConnection: TFPHTTPConnection;
  aRequest: TFPHTTPConnectionRequest);
begin
  { FPC 3.3.1 升级路径：socket 所有权已移交，循环结束后必须自己释放 }
  WSTunnel(aConnection.Socket, aRequest, True);
end;

procedure TLWHyperServer.WSTunnel(AClient: TSocketStream;
  aRequest: TFPHTTPConnectionRequest; AOwnSocket: Boolean);
var
  cli, up: TSocketStream;
  key, sid, req, line, hdr: AnsiString;
  idx, hport, n: Integer;
  tun: TLWWSTunnel;
begin
  cli := AClient;
  up := nil;
  tun := nil;
  { 收尾统一走下面的 finally，每个 Exit 都覆盖到：
      - up 是本方法建的，没交给隧道就自己释放；
      - cli 在 3.3.1 下所有权已随升级移交给我们（fphttpserver 把 FSocket
        置 nil 后不再管它）—— 必须 Free，否则每个 WS 连接漏一个流对象，
        异常握手/502/隧道失败这些分支也一样漏；
      - cli 在 3.2.2 下仍归连接对象，只关不释放（与合并前一致）。 }
  try
    key := Trim(aRequest.CustomHeaders.Values['sec-websocket-key']);
    if (cli = nil) or (key = '') then
      Exit;   { 异常握手 }

    sid := Trim(aRequest.QueryFields.Values['sid']);
    if sid = '' then
      sid := Trim(aRequest.GetCustomHeader('X-LW-Sid'));
    idx := PickWorker(sid);
    if idx < 0 then
    begin
      try
        lwwebsocket.WSSendRaw(cli, 'HTTP/1.1 502 Bad Gateway' + #13#10 +
          'Connection: close' + #13#10#13#10);
      except
      end;
      Exit;
    end;
    hport := FWorkers[idx].Port;

    { 重建握手请求发给 worker（握手在 worker 端完成，负载器只搬字节） }
    req := AnsiString('GET ' + aRequest.URL + ' HTTP/1.1' + #13#10 +
      'Host: 127.0.0.1:' + IntToStr(hport) + #13#10 +
      'Upgrade: websocket' + #13#10 +
      'Connection: Upgrade' + #13#10 +
      'Sec-WebSocket-Key: ' + key + #13#10 +
      'Sec-WebSocket-Version: 13' + #13#10);
    line := AnsiString(Trim(aRequest.CustomHeaders.Values['sec-websocket-protocol']));
    if line <> '' then
      req := req + AnsiString('Sec-WebSocket-Protocol: ') + line + #13#10;
    line := AnsiString(Trim(aRequest.GetCustomHeader('X-LW-Sid')));
    if line <> '' then
      req := req + AnsiString('X-LW-Sid: ') + line + #13#10;
    req := req + #13#10;

    try
      up := TInetSocket.Create('127.0.0.1', hport);
      up.WriteBuffer(req[1], Length(req));
      { 读 worker 的 101 应答头（到空行），原样转给客户端。握手段很小，
        逐字节读足够可靠 }
      hdr := '';
      SetLength(line, 1);
      while Pos(#13#10#13#10, hdr) = 0 do
      begin
        if not lwwebsocket.LWCanRead(up, 5000) then
          raise Exception.Create('worker handshake timeout');
        n := up.Read(line[1], 1);
        if n <= 0 then
          raise Exception.Create('worker closed during handshake');
        hdr := hdr + line[1];
      end;
      if Pos('101', Copy(hdr, 1, 20)) = 0 then
        raise Exception.Create('worker refused upgrade');
      cli.WriteBuffer(hdr[1], Length(hdr));
    except
      on E: Exception do
      begin
        LWLogFmt('[hyper] ws tunnel :%d 失败: %s', [hport, E.Message]);
        try
          lwwebsocket.WSSendRaw(cli, 'HTTP/1.1 502 Bad Gateway' + #13#10 +
            'Connection: close' + #13#10#13#10);
        except
        end;
        Exit;
      end;
    end;

    { 双向透传到任一方断开。socket 交接给隧道：由它 shutdown 叫醒两端泵线程、
      再由析构 Free 完成唯一一次 close（cli 只在 AOwnSocket 时归它管） }
    tun := TLWWSTunnel.Create(cli, up, AOwnSocket);
    up := nil;
    if AOwnSocket then
      cli := nil;
    InterlockedIncrement(FWSOpen);
    try
      tun.Run;
    finally
      FreeAndNil(tun);
      InterlockedDecrement(FWSOpen);
      InterlockedIncrement(FWSDone);
    end;
  finally
    if up <> nil then
      FreeAndNil(up);
    if cli <> nil then
    begin
      if AOwnSocket then
        FreeAndNil(cli)
      else
        lwwebsocket.LWSocketClose(cli);
    end;
  end;
end;

{ ---------------- 命令行 ---------------- }

procedure LWHyperBanner(const ACfg: TLWHyperConfig);
var
  i: Integer;
  scheme: string;
begin
  if ACfg.UseSSL then scheme := 'https' else scheme := 'http';
  LWLogRaw('');
  LWLogRaw('  lazarusWeb Hyper Server ' + LW_VERSION);
  LWLogRaw('  --------------------------------------------------');
  LWLogRaw('  Listen    : ' + scheme + '://127.0.0.1:' + IntToStr(ACfg.Port) + '/');
  if ACfg.PluginMode then
  begin
    LWLogRaw('  Mode      : plugin（/p/<名>/ 反代到独立插件 exe）');
    LWLogRaw('  PluginRoot: ' + ACfg.PluginRoot);
    LWLogRaw('  Routes    : /p/<name>/  （插件路由由清单 *.plugin.ini 自动生成）');
    if ACfg.AuthEnabled then
    begin
      LWLogRaw('  Login     : 开（未登录只能看到 /login）；用户表 ' + ACfg.UsersFile);
      LWLogRaw('  入口      : ' + scheme + '://127.0.0.1:' + IntToStr(ACfg.Port) + '/');
    end
    else
      LWLogRaw('  Login     : 关（--no-auth：/p/ 匿名放行，仅限本机调试）');
  end
  else
  begin
    LWLogRaw('  Workers   : ' + IntToStr(ACfg.WorkerCount) + ' x ' + ACfg.WorkerExe);
    for i := 0 to ACfg.WorkerCount - 1 do
      LWLogRaw('              #' + IntToStr(i + 1) + ' -> :' + IntToStr(ACfg.BasePort + i));
  end;
  if ACfg.Root <> '' then
    LWLogRaw('  Root      : ' + ACfg.Root);
  if ACfg.HotUpdate then
    LWLogRaw('  HotUpdate : 开（监听 ' + LWHyperUpdateTarget(ACfg) + '，换版逐个重启 worker）')
  else
    LWLogRaw('  HotUpdate : 关');
  LWLogRaw('  Status    : ' + scheme + '://127.0.0.1:' + IntToStr(ACfg.Port) + '/lw/hyper/status');
  LWLogRaw('  Health    : ' + scheme + '://127.0.0.1:' + IntToStr(ACfg.Port) + '/lw/healthz');
  if ACfg.UseSSL then
    LWLogRaw('  TLS       : 开（自签证书浏览器会告警，点“继续访问”；相机取景需 https）');
  if ACfg.PWAEnabled then
    LWLogRaw('  PWA       : 开（manifest / Service Worker / 图标 / 订阅端点由宿主直出）');
  LWLogRaw('  --------------------------------------------------');
  if ACfg.PluginMode then
    LWLogRaw('  Ctrl+C 退出宿主（插件是独立进程：收尾用 stop-all.bat 或任务管理器）')
  else
    LWLogRaw('  Ctrl+C 退出（worker 一并停止）');
  LWLogRaw('');
end;

function LWHyperUpdateTarget(const ACfg: TLWHyperConfig): string;
begin
  if ACfg.UpdateDir <> '' then
    Result := IncludeTrailingPathDelimiter(ACfg.UpdateDir) +
      ExtractFileName(ACfg.WorkerExe)
  else
    Result := ACfg.WorkerExe + '.new';
end;

function LWHyperParseArgs(var ACfg: TLWHyperConfig): Boolean;
var
  i: Integer;
  arg, key, val, err: string;
begin
  Result := True;
  for i := 1 to ParamCount do
  begin
    arg := ParamStr(i);
    key := arg;
    val := '';
    if Pos('=', arg) > 0 then
    begin
      key := Copy(arg, 1, Pos('=', arg) - 1);
      val := Copy(arg, Pos('=', arg) + 1, MaxInt);
    end;
    if (key = '--help') or (key = '-h') then
      Result := False
    else if key = '--port' then ACfg.Port := Word(StrToIntDef(val, ACfg.Port))
    else if key = '--base-port' then ACfg.BasePort := Word(StrToIntDef(val, ACfg.BasePort))
    else if key = '--workers' then ACfg.WorkerCount := StrToIntDef(val, ACfg.WorkerCount)
    else if key = '--exe' then ACfg.WorkerExe := val
    else if key = '--root' then ACfg.Root := val
    else if key = '--theme' then ACfg.Theme := val
    else if key = '--logdir' then ACfg.LogDir := val
    else if key = '--worker-args' then ACfg.ExtraArgs := val
    else if key = '--verbose' then ACfg.Verbose := True
    else if key = '--plugin' then ACfg.PluginMode := True
    else if key = '--no-plugin' then ACfg.PluginMode := False
    else if key = '--plugin-root' then
    begin
      ACfg.PluginRoot := val;
      ACfg.PluginMode := True;
    end
    else if key = '--hot-update' then ACfg.HotUpdate := True
    else if key = '--no-hot-update' then ACfg.HotUpdate := False
    else if key = '--no-auth' then ACfg.AuthEnabled := False
    else if key = '--auth' then ACfg.AuthEnabled := True
    else if key = '--users' then ACfg.UsersFile := val
    else if key = '--session-min' then
      ACfg.SessionMin := StrToIntDef(val, ACfg.SessionMin)
    else if key = '--login-hint' then ACfg.LoginHint := val
    else if key = '--update-dir' then ACfg.UpdateDir := val
    else if key = '--ssl' then ACfg.UseSSL := True
    else if key = '--ssl-host' then ACfg.SSLHost := val
    { 与 lwapp 一致：--tls-cert/--tls-key 是别名，给了证书即自动开 HTTPS }
    else if (key = '--ssl-cert') or (key = '--tls-cert') then
    begin
      ACfg.SSLCertFile := val;
      ACfg.UseSSL := True;
    end
    else if (key = '--ssl-key') or (key = '--tls-key') then
    begin
      ACfg.SSLKeyFile := val;
      ACfg.UseSSL := True;
    end
    else if key = '--pwa' then ACfg.PWAEnabled := True
    else if key = '--pwa-name' then ACfg.PWAName := val
    else if key = '--pwa-short-name' then ACfg.PWAShortName := val
    else if key = '--pwa-theme' then ACfg.PWAThemeColor := val
    else if key = '--pwa-bg' then ACfg.PWABackgroundColor := val
    else if key = '--pwa-vapid-public' then ACfg.PWAVapidPublic := val
    else if key = '--pwa-vapid-private' then ACfg.PWAVapidPrivate := val
    else if key = '--pwa-vapid-subject' then ACfg.PWAVapidSubject := val
    else if key = '--pwa-push-token' then ACfg.PWAPushToken := val
    else if key = '--pwa-push-file' then ACfg.PWAPushFile := val
    else if key = '--pwa-message-file' then ACfg.PWAMessageFile := val
    else
    begin
      LWLog('未知参数: ' + arg);
      Result := False;
    end;
  end;

  { 证书相对路径以 exe 目录为基准。证书/私钥不成对或文件不存在时不再失败
    退出 —— 改为打警告并回退 HTTP：INI 里 ssl=1 但 crt/key 没放好是常见
    部署失误，直接退出会"负载器根本起不来"，GUI 构建下裸 WriteLn 还会弹
    I/O 103 "File not open"。降级后照常用 HTTP 起来，日志里说清楚。 }
  if Result and ACfg.UseSSL then
  begin
    ACfg.SSLCertFile := LWResolveExeRelativePath(ACfg.SSLCertFile);
    ACfg.SSLKeyFile := LWResolveExeRelativePath(ACfg.SSLKeyFile);
    if not LWValidateTLSFiles(ACfg.SSLCertFile, ACfg.SSLKeyFile, err) then
    begin
      LWLog('警告: ' + err + '；lwhyper 已关闭 HTTPS，回退 HTTP 启动（请检查证书路径或改回 ssl=0）');
      ACfg.UseSSL := False;
      ACfg.SSLCertFile := '';
      ACfg.SSLKeyFile := '';
    end;
  end;

  { 插件根目录与投放目录同样按 exe 目录解析（服务方式启动时 cwd 常是 System32） }
  if Result and (ACfg.PluginMode) and (ACfg.PluginRoot <> '') then
    ACfg.PluginRoot := LWResolveExeRelativePath(ACfg.PluginRoot);
  if Result and (ACfg.UsersFile <> '') then
    ACfg.UsersFile := LWResolveExeRelativePath(ACfg.UsersFile);
  { 没写 --users= 时按惯例找 exe 同目录的 hyper.users.ini；
    找不到留给 Start 报错（"用户表不存在"比"匿名放行"安全得多） }
  if Result and ACfg.PluginMode and ACfg.AuthEnabled and (ACfg.UsersFile = '') then
    ACfg.UsersFile := LWResolveExeRelativePath('hyper.users.ini');
  if Result and (ACfg.UpdateDir <> '') then
    ACfg.UpdateDir := LWResolveExeRelativePath(ACfg.UpdateDir);

  { PWA 默认主题与相对路径，配置一次供宿主与 worker 共用 }
  if Result and ACfg.PWAEnabled then
  begin
    if ACfg.PWAName = '' then ACfg.PWAName := 'lazarusWeb';
    if ACfg.PWAShortName = '' then ACfg.PWAShortName := Copy(ACfg.PWAName, 1, 12);
    if ACfg.PWAThemeColor = '' then ACfg.PWAThemeColor := '#1e88e5';
    if ACfg.PWABackgroundColor = '' then ACfg.PWABackgroundColor := '#ffffff';
    if ACfg.PWAVapidPrivate <> '' then
      ACfg.PWAVapidPrivate := LWResolveExeRelativePath(ACfg.PWAVapidPrivate);
    if ACfg.PWAPushFile <> '' then
      ACfg.PWAPushFile := LWResolveExeRelativePath(ACfg.PWAPushFile);
    if ACfg.PWAMessageFile <> '' then
      ACfg.PWAMessageFile := LWResolveExeRelativePath(ACfg.PWAMessageFile);
    LWPWAConfigure(ACfg.PWAName, ACfg.PWAShortName, ACfg.PWAThemeColor,
      ACfg.PWABackgroundColor, ACfg.PWAVapidPublic, ACfg.PWAVapidPrivate,
      ACfg.PWAVapidSubject, ACfg.PWAPushToken, ACfg.PWAPushFile,
      ACfg.PWAMessageFile, ACfg.Root, LW_VERSION, True);
  end;
end;

end.
