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
  公网 HTTPS 场景仍建议前置一层反代做 TLS 终结（fphttpserver 无 TLS），
  但反代配置里不再需要 ip_hash / worker 清单 —— 粘性由 lwhyper 管。

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
  fpjson, jsonparser, ssockets, fphttpclient, Process, lwrlog, lwwebsocket, lwbase;

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
  end;

  TLWHyperServer = class;

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
    FHTTP: TFPHttpServer;
    FMap: TStringList;             { sid -> worker 下标 }
    FMapLock: TRTLCriticalSection;
    FLock: TRTLCriticalSection;
    FRR: Integer;                  { 轮询游标 }
    FMonitor: TLWHyperMonitor;
    FStartedAt: TDateTime;
    { WS 隧道计数：wsopen = 当前正在透传的条数（收尾正确时必然回 0），
      wsdone = 累计正常收尾的条数。排查"每连接漏一个对象"用它们最快：
      wsopen 单调上涨就是漏，wsdone 涨而 wsopen 回 0 就是干净 }
    FWSOpen: Integer;
    FWSDone: Integer;
    function AliveCount: Integer;
    function SessionsTotal: Integer;
    function DoHealthProbe(APort: Word; out ASessions: Integer): Boolean;
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
    procedure ApiHealth(var AResponse: TFPHTTPConnectionResponse);
    procedure ApiStatus(var AResponse: TFPHTTPConnectionResponse);
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
    property Cfg: TLWHyperConfig read FCfg;
    { worker 明细 JSON（/lw/hyper/status 响应体同源）。
      GUI 面板（lwhyper_gui）在主线程定时调它刷 ListView；
      与 HTTP 线程读写同一组字段，粒度同 ApiStatus（良性读竞争） }
    function StatusJSON: string;
  end;

{ 解析命令行填 TLWHyperConfig；参数非法（缺 --exe 等）返回 False }
function LWHyperParseArgs(var ACfg: TLWHyperConfig): Boolean;
procedure LWHyperBanner(const ACfg: TLWHyperConfig);

implementation

const
  POLL_MS = 2000;   { healthz 巡检间隔 }

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

{ ---------------- TLWWorker ---------------- }

constructor TLWWorker.Create(APort: Word);
begin
  inherited Create;
  Port := APort;
  Alive := False;
  Sessions := 0;
  Restarts := 0;
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
        if (w.Proc = nil) or (not w.Proc.Running) then
        begin
          { worker 崩了：清掉粘在它上面的 sid，重启 }
          FHyper.ClearWorkerSids(i);
          LWLogFmt('[hyper] worker #%d (:%d) 异常退出，重启中 (第 %d 次)',
            [i + 1, w.Port, w.Restarts + 1]);
          w.Launch(FHyper.Cfg, i);
          w.BootGuard := 2;   { 重启初期别急着放流量，连续两轮探针过了再说 }
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
  if FCfg.BasePort = 0 then
    FCfg.BasePort := FCfg.Port + 1;
  FMap := TStringList.Create;
  FMap.Sorted := True;
  FMap.Duplicates := dupError;
  InitCriticalSection(FMapLock);
  InitCriticalSection(FLock);
  FRR := 0;
  FStartedAt := Now;
  SetLength(FWorkers, FCfg.WorkerCount);
  for i := 0 to FCfg.WorkerCount - 1 do
  begin
    FWorkers[i] := TLWWorker.Create(FCfg.BasePort + i);
    FWorkers[i].LogPath := IncludeTrailingPathDelimiter(FCfg.LogDir) +
      'worker' + IntToStr(i + 1) + '.log';
  end;
end;

destructor TLWHyperServer.Destroy;
var
  i: Integer;
begin
  { FHTTP 在这里收：Stop 只负责唤醒 accept 循环，
    调用方必须先 WaitFor 启动线程再 Free 本对象 }
  FreeAndNil(FHTTP);
  for i := 0 to High(FWorkers) do
    FWorkers[i].Free;
  SetLength(FWorkers, 0);
  FMap.Free;
  DoneCriticalSection(FMapLock);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TLWHyperServer.Start;
var
  i: Integer;
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
  FHTTP := TFPHttpServer.Create(nil);
  FHTTP.Port := FCfg.Port;
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

function TLWHyperServer.DoHealthProbe(APort: Word; out ASessions: Integer): Boolean;
begin
  Result := ProbeWorkerHealth(APort, ASessions);
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
  p, method, sid: string;
  idx: Integer;
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
  if p = '/lw/hyper/status' then
  begin
    ApiStatus(AResponse);
    Exit;
  end;
  if p = '/favicon.ico' then
  begin
    AResponse.Code := 204;
    Exit;
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

procedure TLWHyperServer.ApiHealth(var AResponse: TFPHTTPConnectionResponse);
var
  j: TJSONObject;
begin
  j := TJSONObject.Create;
  try
    j.Add('ok', AliveCount > 0);
    j.Add('role', 'hyper');
    j.Add('workers', Length(FWorkers));
    j.Add('alive', AliveCount);
    j.Add('sessions', SessionsTotal);
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
  i: Integer;
begin
  j := TJSONObject.Create;
  try
    j.Add('ok', True);
    j.Add('listen', FCfg.Port);
    j.Add('exe', FCfg.WorkerExe);
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
begin
  LWLogRaw('');
  LWLogRaw('  lazarusWeb Hyper Server ' + LW_VERSION);
  LWLogRaw('  --------------------------------------------------');
  LWLogRaw('  Listen    : http://127.0.0.1:' + IntToStr(ACfg.Port) + '/');
  LWLogRaw('  Workers   : ' + IntToStr(ACfg.WorkerCount) + ' x ' + ACfg.WorkerExe);
  for i := 0 to ACfg.WorkerCount - 1 do
    LWLogRaw('              #' + IntToStr(i + 1) + ' -> :' + IntToStr(ACfg.BasePort + i));
  if ACfg.Root <> '' then
    LWLogRaw('  Root      : ' + ACfg.Root);
  LWLogRaw('  Status    : http://127.0.0.1:' + IntToStr(ACfg.Port) + '/lw/hyper/status');
  LWLogRaw('  Health    : http://127.0.0.1:' + IntToStr(ACfg.Port) + '/lw/healthz');
  LWLogRaw('  --------------------------------------------------');
  LWLogRaw('  Ctrl+C 退出（worker 一并停止）');
  LWLogRaw('');
end;

function LWHyperParseArgs(var ACfg: TLWHyperConfig): Boolean;
var
  i: Integer;
  arg, key, val: string;
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
    else
    begin
      WriteLn('未知参数: ', arg);
      Result := False;
    end;
  end;
end;

end.
