{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwhttp
  ------------------------------------------------------------------
  内置 HTTP 服务（fcl-web / TFPHttpServer，tmThread 多线程）。

  路由：
    GET  /                       界面外壳（HTML，加载 Ext JS + lw.js）
    GET  /lw/lw.js, /lw/lw.css   浏览器端运行时
    GET  /ext/<版本>/<路径>       Ext JS 静态资源（<版本> 对应 <root>/ext-<版本>，
                                 任意版本号都行，见 ExtRootFor）
    GET  /lw/api/forms           已注册窗体清单
    POST /lw/api/session         新建会话 -> 返回初始组件树
    GET  /lw/api/tree?sid=       取当前组件树
    POST /lw/api/event           请求体: sid/id/ev/val/row/col -> 新组件树
    GET  /lw/api/poll?sid=       长轮询取服务端推送（模态窗体/消息框）
    POST /lw/api/close           结束会话
    POST /lw/api/upload?sid=&id= 文件上传（multipart/form-data）
    POST /lw/api/dlg            浏览器对话框的答复（sid/id/r/text）
    POST /lw/api/dlgfile?sid=&id= 选文件对话框上传（multipart/form-data）
    GET  /lw/download?t=<令牌>   文件下载（令牌由 lwdownload 登记）
    GET  /lw/view?t=<令牌>       内嵌查看（PDF 帧的 iframe 用，可重复访问）

  FPC 版本兼容（本项目同时支持 FPC 3.2.2 与 3.3.1，见各处的
  {$IF FPC_FULLVERSION >= 30301} 分支）：
    - WebSocket 连接升级：3.3.1 用 fphttpserver 的 RegisterUpdateHandler，
      3.2.2 没有该机制，改在 OnRequest 里手工接管（WSRun + ELWUpgraded）；
    - 服务器属性：3.3.1 是 ThreadMode/tmThread，3.2.2 只有 Threaded: Boolean；
    - 连接清点：3.3.1 用 ConnectionHandler.GetActiveConnectionCount，
      3.2.2 只有 ConnectionCount（见 LiveConnections）；
    - 状态行文本：3.3.1 有 GetHTTPStatusText，3.2.2 没有
      （统一走 lwbase.LWHTTPStatusText 自带码表）；
    - TSocketStream 的 CanRead / Close：3.3.1 才有
      （统一走 lwwebsocket.LWCanRead / LWSocketClose）。
}
unit lwhttp;
{$codepage utf8}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, fphttpserver, httpdefs, httpprotocol, fpjson, jsonparser,
  ssockets, Sockets, Forms, Controls, lwbase, lwsession, lwdispatch, lwform, lwupload, lwdownload,
  lwajax, lwwebsocket, lwrlog;

type
  TLWServerConfig = record
    Port: Word;
    Root: string;          { 项目根目录，里面放 ext-<版本> / src\client }
    DefaultForm: string;
    { 默认浏览器客户端：'ext'（Ext JS 渲染层）| 'alpine'（Alpine.js 渲染层）。
      两者协议完全一致，?client= 仍可按请求覆盖 }
    DefaultClient: string;
    { client= 是否被显式指定（配置文件 client= 或命令行 --client=）。
      False = 启动阶段自动探测：alpine.min.js 与 ext-all.js 都可用时优先
      alpine，只有一个就用那一个（坑 92） }
    ClientExplicit: Boolean;
    DefaultExt: string;    { 默认 Ext 版本，对应 <root>\ext-<DefaultExt>；
                             目录名不必严格等于版本号，见 ExtRootFor }
    { ext-js 目录（配置文件 extdir）；'' = 自动查找 <root>\ext-<DefaultExt>。
      非空时所有 /ext/<版本>/... 请求都从这个目录取（部署时通常只带一个
      ext 版本，也就没必要再按版本分开）}
    ExtDir: string;
    Title: string;
    SessionTimeoutMin: Integer;
    Verbose: Boolean;
    { 默认主题（?theme= 可按请求覆盖）：classic/crisp/gray/material/
      neptune/graphite }
    Theme: string;
    { 登录窗体名（'' = 未启用登录）。非空时每个新会话先显示登录窗体，
      认证通过才创建默认主窗体（lwlogin / TLWApp.SetLogin）}
    LoginForm: string;
    { /lw/ajax/* 回 Access-Control-Allow-Origin: *（给第三方站点直接调）}
    AjaxCORS: Boolean;
    { 部署在 nginx / Caddy 反代后面：客户端 IP 取 X-Forwarded-For 的第一段 }
    TrustProxy: Boolean;
    { GUI 构建下不弹服务端面板（--nogui），服务化部署用 }
    NoUI: Boolean;
    { --log=path：服务端日志追加写入文件（GUI 面板只显示到窗口） }
    LogFile: string;
  end;

  { 由 lwapp 提供：按名字创建窗体实例 }
  TLWFormFactory = function(const AName: string; out AForm: TCustomForm): Boolean of object;
  TLWFormLister = procedure(AList: TStrings) of object;

  TLWSweepThread = class(TThread)
  private
    FStore: TLWSessionStore;
    FMinutes: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AStore: TLWSessionStore; AMinutes: Integer);
  end;

  { 只为拿到 protected 的 ConnectionHandler（fphttpserver 没把它的
    CloseSockets 公开出来）：停服时主动断开残留连接，不用等 Free 里
    那套 10×100ms 的空转探测。
    注意这里不能只 close：浏览器 keep-alive 留下的空闲连接，其工作线程
    正阻塞在 select 上等数据，close(fd) 在 Linux 上叫不醒它，线程要睡满
    RequestReadTimeout（默认 30 秒）才醒。而 TFPCustomHttpServer.Destroy
    里最后一句是 WaitForRequests(High(Integer)) —— 于是"打开过网站再点
    退出"就变成干等 29 秒，窗口一直关不掉。先 shutdown(SHUT_RDWR)，
    select 立刻返回，线程马上收工。 }
  TLWHttpServer = class(TFPHttpServer)
  public
    procedure AbortConnections;
  end;

  { FPC 3.2.2 专用控制流信号：OnRequest 里已经手工写完 101 应答并跑完了
    WebSocket 帧循环，用它把控制流从 fcl-web 的"继续发响应"流程里拽出来。
    该异常不会产生任何输出，fcl-web 捕获后直接回收连接；本单元的
    HandleRequestError 把它静默吞掉（不写日志）。3.3.1 下不会用到。 }
  ELWUpgraded = class(Exception);


  TLWServer = class
  private
    FHTTP: TLWHttpServer;
    FStore: TLWSessionStore;
    FCfg: TLWServerConfig;
    FFactory: TLWFormFactory;
    FLister: TLWFormLister;
    FSweeper: TLWSweepThread;
    FStartedAt: TDateTime;
    { Start 已经进去过（accept 循环跑起来了）。Stop 里靠它判断
      要不要等 Start 返回，避免在别人脚下把 FHTTP 拆掉 }
    FStartCalled: Boolean;
    { Start 真正返回时置位（正常返回或异常退出都置）。
      accept 循环里 FAccepting 变 False 到"真的跳出循环"之间有个间隙，
      不等这一步就 Free，accept 线程会踩到已经释放的对象 —— 表现为
      启动线程里抛 Access violation（关窗日志里那句"无法启动服务"）。 }
    FRunDone: PRTLEvent;
    { Start 已经返回。RTLEventWaitFor 在这个 FPC 版本里不带返回值，
      所以用一个标志配事件：事件只负责"叫醒"，结果看这个标志 }
    FRunFinished: Boolean;
    FStopping: Boolean;
    { --root 下唯一的 ext-* 目录名（'ext-7.5.1' 形式）；多版本共存或没有
      这样的目录时为 ''。用于「目录名跟版本号对不上」时兜底。 }
    FSingleExtDir: string;
    procedure HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    procedure Route(var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
    procedure ServeIndex(const AExtVer, AForm, ATheme: string; var AResponse: TFPHTTPConnectionResponse);
    { Alpine.js 客户端外壳（?client=alpine）：与 Ext 版同协议，渲染层换 Alpine }
    function BuildAlpineHtml(const AForm: string): string;
    procedure ServeAlpineIndex(const AForm: string; var AResponse: TFPHTTPConnectionResponse);
    procedure ServeFile(const AFullPath: string; var AResponse: TFPHTTPConnectionResponse);
    procedure ServeExt(const APath: string; var AResponse: TFPHTTPConnectionResponse);
    procedure Reply(const AText, AMime: string; ACode: Integer; var AResponse: TFPHTTPConnectionResponse);
    procedure ApiSession(var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
    procedure ApiEvent(var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
    procedure ApiPoll(var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
    procedure ApiTree(var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
    { 文件上传：落到会话目录并触发 TLWFileUpload.OnUpload }
    procedure ApiUpload(var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
    { 对话框答复：浏览器点按钮 / 输入框确定后回传结果 }
    procedure ApiDialog(var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
    { 选文件对话框：浏览器把选中的文件传上来，直接当作对话框的答案 }
    procedure ApiDialogFile(var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
    { 文件下载：凭一次性令牌取文件，响应头带 Content-Disposition }
    procedure ApiDownload(var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
    { 内嵌查看（PDF 帧）：令牌可重复访问、不失效，Content-Disposition: inline，
      浏览器自带查看器直接在 iframe 里渲染 }
    procedure ApiView(var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
    { 会话日志：Show / ShowModal / EndModal 之类的事件都记在会话里，
      浏览器打不开时用它排查最省事 }
    procedure ApiLog(var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
    { 自定义 AJAX 端点：/lw/ajax/<名字>（lwajax 注册表）}
    procedure ApiAjax(var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
    { 负载均衡健康检查：/lw/healthz }
    procedure ApiHealth(var AResponse: TFPHTTPConnectionResponse);
    { 跨页签会话共享：新页签挂到已有 sid 上（不新建会话）}
    procedure ApiAttach(var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
    { 会话标识（?sid= 或 X-LW-Sid 头）；找不到返回 '' }
    function RequestSid(var ARequest: TFPHTTPConnectionRequest): string;
    { 客户端 IP（反代后面取 X-Forwarded-For） }
    function ClientIP(var ARequest: TFPHTTPConnectionRequest): string;
    function ParseBody(var ARequest: TFPHTTPConnectionRequest): TJSONObject;
    function QueryP(const ARequest: TFPHTTPConnectionRequest; const AName, ADef: string): string;
    { ext 目录下的相对路径是否存在（用来判断 charts 包、主题 CSS 有没有）}
    function ExtFileExists(const AVer, ARel: string): Boolean;
    { 选一个在磁盘上真实存在的主题：新版本 Ext 可能删掉某个主题，
      请求的主题没有 CSS 时依次退到 crisp / classic / neptune }
    function PickTheme(const AVer, ATheme: string): string;
    { --root 下唯一的 ext-* 目录名（不含路径），没有或不唯一返回 '' }
    function FindSingleExtDir: string;
    { 还活着的连接数（3.3.1 走 ConnectionHandler，3.2.2 走 ConnectionCount）}
    function LiveConnections: Integer;
  public
    constructor Create(const ACfg: TLWServerConfig; AFactory: TLWFormFactory;
      ALister: TLWFormLister);
    destructor Destroy; override;
    { 打印启动横幅。必须在 Start 之前调用：Start 里 fcl-web 的
      Active := True 会进入永返不回的 accept 循环（TSocketServer.
      StartAccepting），写在它后面的代码执行不到。 }
    procedure PrintBanner;
    procedure Start;
    procedure Stop;
    { 服务端面板（lwpanel）用的只读视图 }
    function Cfg: TLWServerConfig;
    function SessionCount: Integer;
    procedure SetVerbose(AValue: Boolean);
    function ExtRootFor(const AVer: string): string;
    function BuildIndexHtml(const AExtVer, AForm, ATheme: string): string;
    { WebSocket（/lw/ws）}
    procedure WSHandlesUpgrade(aRequest: TFPHTTPConnectionRequest;
      var aHandles: Boolean);
    procedure WSUpgrade(aConnection: TFPHTTPConnection;
      aRequest: TFPHTTPConnectionRequest);
    { WebSocket 帧主循环本体。两个 FPC 版本的差别只在外层怎么把连接交进来：
        FPC 3.3.1 有 fphttpserver 的连接升级机制（RegisterUpdateHandler），
        socket 所有权移交给我们，AOwnSocket=True，循环结束自己 Free；
        FPC 3.2.2 没有这套机制，改由 OnRequest 里自己接管（WSRun 后抛
        ELWUpgraded 终止 fcl-web 的响应流程），socket 由连接析构释放，
        AOwnSocket=False。 }
    procedure WSRun(ASock: TSocketStream; aRequest: TFPHTTPConnectionRequest;
      AOwnSocket: Boolean);
    procedure WSPushCommand(ASession: TObject; const AJSON: string);
    { fphttpserver 的请求级异常回调。只做一件事：把"客户端提前断开"
      这类读/写失败记一行日志 —— 它们已经被 fcl-web 捕获、连接被断开，
      服务器照常服务，但 IDE 调试器会在 raise 处停下来弹框，看起来像
      我们的 bug（见 NOTES 坑 73；EReadError 是同一族在读侧的表现，
      同样无害） }
    procedure HandleRequestError(Sender: TObject; E: Exception);
    property Store: TLWSessionStore read FStore;
    property Config: TLWServerConfig read FCfg;
  end;

function LWDefaultRoot(const APreferVer: string = ''): string;
function LWResolveRoot(const AHint: string; const APreferVer: string = ''): string;
{ 定位客户端运行时文件（lw.js / lw.css）。支持三种部署布局：
  ① <root>/src/client/（标准仓库布局）
  ② <exe目录>/（扁平部署，直接把 lw.js 拷到 exe 旁边）
  ③ <exe目录>/lw/  或  <root>/client/
  都找不到再从 root 向上逐级找 src/client，返回 '' 表示没有。 }
function LWFindClientFile(const AName, ARoot: string): string;

{ 关停耗时追踪。设 LW_EXIT_TRACE=1 后，Stop / 面板收尾的每一步都往日志
  打一行"距开始多少毫秒"，用来定位"关窗/退出要等好几秒"到底卡在哪一环
  （mips64 这类慢机器上尤其需要实测，靠猜容易改错地方）。
  未设环境变量时全部是空调用，零开销。 }
procedure LWStopTraceBegin;
procedure LWStopTrace(const AText: string);

implementation

const
  LW_POLL_MS = 20000;

{ 状态行文本统一走 lwbase.LWHTTPStatusText（自带码表，3.2.2/3.3.1 一致） }

{ ---------------- 关停耗时追踪 ---------------- }

var
  GTraceOn: Boolean = False;
  GTraceInit: Boolean = False;
  GTraceT0: QWord = 0;

procedure LWStopTraceBegin;
begin
  if not GTraceInit then
  begin
    GTraceInit := True;
    GTraceOn := GetEnvironmentVariable('LW_EXIT_TRACE') <> '';
  end;
  GTraceT0 := GetTickCount64;
end;

procedure LWStopTrace(const AText: string);
begin
  if GTraceOn then
    LWLogFmt('[exit] %6d ms  %s', [Int64(GetTickCount64 - GTraceT0), AText]);
end;

{ ---------------- 事件耗时剖析（LW_PROF=1 打开） ----------------

  单位：**微秒**。disp = 事件派发（业务代码 + BuildPayload 里的控件树重建），
  json = 把树编码成文本，send = 写 socket。
  为什么不用 GetTickCount64：Windows 上精度 15.6ms，正好和这里的单次事件
  同量级，量出来全是 0/16 两个值，等于没测。计数器的实现统一放在
  lwbase.LWNowUS（Windows 走 QPC，Unix 走 clock_gettime），这里只取时间差。
  默认关闭；打开时每个事件一行，只适合短时间采样。 }
var
  GProfOn: Boolean = False;
  GProfInit: Boolean = False;

function LWProfOn: Boolean;
begin
  if not GProfInit then
  begin
    GProfInit := True;
    GProfOn := GetEnvironmentVariable('LW_PROF') <> '';
  end;
  Result := GProfOn;
end;

{ 单调微秒计数 }
function LWProfNow: Int64;
begin
  Result := LWNowUS;
end;

procedure LWProfLog(const ATag: string; ADisp, AJson, ASend: Int64; ABytes: Integer);
begin
  if not LWProfOn then Exit;
  LWLogFmt('[prof] %s disp=%d us json=%d us send=%d us bytes=%d',
    [ATag, ADisp, AJson, ASend, ABytes]);
end;

{ ---------------- 活着的 WebSocket 连接 ---------------- }

{ 升级成功后 socket 的所有权从 fcl-web 移交给 WSUpgrade 里的帧循环，
  ConnectionHandler 的连接列表里已经找不到它了（aConnection.Socket 被
  置 nil）。停服时普通连接靠 shutdown 叫醒，这条也得照顾到 —— 否则
  WS 线程要等在 WSReadFrame 的 30 秒读超时才醒，退出又变成"卡半分钟"。 }
var
  GWSLock: TRTLCriticalSection;
  GWSSocks: TList = nil;

procedure LWWSRegister(ASock: TSocketStream);
begin
  if GWSSocks = nil then Exit;
  EnterCriticalSection(GWSLock);
  try
    if GWSSocks.IndexOf(ASock) < 0 then
      GWSSocks.Add(ASock);
  finally
    LeaveCriticalSection(GWSLock);
  end;
end;

procedure LWWSUnregister(ASock: TSocketStream);
begin
  if GWSSocks = nil then Exit;
  EnterCriticalSection(GWSLock);
  try
    GWSSocks.Remove(ASock);
  finally
    LeaveCriticalSection(GWSLock);
  end;
end;

procedure LWWShutdownAll;
var
  i: Integer;
begin
  if GWSSocks = nil then Exit;
  EnterCriticalSection(GWSLock);
  try
    for i := 0 to GWSSocks.Count - 1 do
      try
        { shutdown 只是"叫醒"，不释放 socket —— 释放仍由 WSUpgrade 的
          帧循环自己 Free，这里不能代劳 }
        fpShutdown(TSocket(TSocketStream(GWSSocks[i]).Handle), SHUT_RDWR);
      except
      end;
  finally
    LeaveCriticalSection(GWSLock);
  end;
end;

function LWValidTheme(const ATheme: string): string;
const
  Themes: array[0..5] of string =
    ('classic', 'crisp', 'gray', 'material', 'neptune', 'graphite');
var
  i: Integer;
begin
  Result := LowerCase(Trim(ATheme));
  for i := Low(Themes) to High(Themes) do
    if Result = Themes[i] then Exit;
  Result := 'crisp';
end;

{ 版本段的安全性：它会被拼进路径（<root>\ext-<ver>），必须挡掉路径分隔符
  和 '..'，否则 /ext/..\..\Windows 这类请求能跳出根目录。只放行字母、数字、
  '.'、'_'、'-'，长度也设个上限（真实版本号不会超过 32 字符）。 }
function LWIsSafeExtVer(const AVer: string): Boolean;
var
  i: Integer;
  c: Char;
begin
  Result := False;
  if (AVer = '') or (AVer = '.') or (AVer = '..') or (Length(AVer) > 32) then Exit;
  for i := 1 to Length(AVer) do
  begin
    c := AVer[i];
    if not (((c >= '0') and (c <= '9')) or ((c >= 'a') and (c <= 'z')) or
            ((c >= 'A') and (c <= 'Z')) or (c = '.') or (c = '_') or (c = '-')) then
      Exit;
  end;
  Result := True;
end;

{ 在 ADir 下找 ext-* 目录，返回目录名（'ext-7.6.0' 这种，不含路径）。
  APreferVer 非空时优先精确命中 ext-<APreferVer>；否则只在「有且仅有一个」
  ext-* 目录时返回它 —— 多版本共存时不做猜测，交给调用方严格匹配。
  这样部署时把目录改名成 ext-7.6.0 / ext-7.5.1-min 都能被认出来。 }
function LWFindExtDirIn(const ADir, APreferVer: string): string;
var
  sr: TSearchRec;
  found: Integer;
begin
  Result := '';
  if (ADir = '') or (not DirectoryExists(ADir)) then Exit;
  if APreferVer <> '' then
    if DirectoryExists(IncludeTrailingPathDelimiter(ADir) + 'ext-' + APreferVer) then
      Exit('ext-' + APreferVer);
  found := 0;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + 'ext-*', faDirectory, sr) = 0 then
  try
    repeat
      if ((sr.Attr and faDirectory) <> 0) and (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        Inc(found);
        if Result = '' then Result := sr.Name;
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
  if found <> 1 then Result := '';
end;

function MimeOf(const AFile: string): string;
var
  e: string;
begin
  e := LowerCase(ExtractFileExt(AFile));
  if e = '.js' then Result := 'application/javascript'
  else if e = '.css' then Result := 'text/css'
  else if e = '.html' then Result := 'text/html'
  else if e = '.png' then Result := 'image/png'
  else if e = '.gif' then Result := 'image/gif'
  else if e = '.jpg' then Result := 'image/jpeg'
  else if e = '.svg' then Result := 'image/svg+xml'
  else if e = '.woff' then Result := 'font/woff'
  else if e = '.woff2' then Result := 'font/woff2'
  else if e = '.ttf' then Result := 'font/ttf'
  else if e = '.eot' then Result := 'application/vnd.ms-fontobject'
  else if e = '.json' then Result := 'application/json'
  else if e = '.ico' then Result := 'image/x-icon'
  else
    Result := 'application/octet-stream';
end;

{ 出站指令字符串 -> 判断是不是模态推送。
  不能对字符串做 Pos('"type":"modal"') —— fpjson 输出的 AsJSON 带空格
  变成带空格的 "type" : "modal"，字面匹配会漏。 }
function IsModalCmd(const ACmd: string): Boolean;
var
  d: TJSONData;
  t: TJSONData;
begin
  Result := False;
  if ACmd = '' then Exit;
  try
    d := GetJSON(ACmd);
    try
      if d is TJSONObject then
      begin
        t := TJSONObject(d).Find('type');
        if t <> nil then
          Result := SameText(t.AsString, 'modal');
      end;
    finally
      d.Free;
    end;
  except
    Result := False;
  end;
end;

function LWDefaultRoot(const APreferVer: string): string;
var  d: string;
  i: Integer;
  firstExt: string;
  par, up: string;
begin
  { 不加 --root= 时按以下顺序定位根目录：
    ① 当前工作目录（GetCurrentDir）—— 在哪个目录启动就用哪个目录，
       这也是「把 ext-7.5.1 和应用放同一目录」最自然的用法；
    ② 从可执行文件目录向上最多 5 层（双击运行 / 从别处启动的兜底）。
    两者都优先挑「ext 目录 + src/client/lw.js 都在」的完整根；若只找到
    ext（客户端脚本缺失），退回第一个含 ext 的候选，保持旧行为不让
    页面彻底起不来。
    ext 目录不按固定版本号认：ext-<APreferVer> 优先，其次是唯一的
    ext-*（见 LWFindExtDirIn），所以 ext-7.6.0 / ext-7.5.1-min 都能当根。 }
  firstExt := '';
  d := IncludeTrailingPathDelimiter(GetCurrentDir);
  if LWFindExtDirIn(ExcludeTrailingPathDelimiter(d), APreferVer) <> '' then
    { 当前目录里有 ext，就认定它是根 —— 哪怕没有 src/client
      （扁平部署：lw.js 直接拷到 exe 同目录，由 LWFindClientFile 兜底） }
    Exit(ExcludeTrailingPathDelimiter(d));

  d := IncludeTrailingPathDelimiter(ExtractFilePath(ExpandFileName(ParamStr(0))));
  for i := 0 to 5 do
  begin
    if LWFindExtDirIn(ExcludeTrailingPathDelimiter(d), APreferVer) <> '' then
    begin
      if FileExists(d + 'src' + PathDelim + 'client' + PathDelim + 'lw.js') then
        Exit(ExcludeTrailingPathDelimiter(d));
      if firstExt = '' then
        firstExt := d;
    end;
    par := ExcludeTrailingPathDelimiter(d);
    up := ExtractFileDir(par);
    if (up = '') or (up = par) then Break;   { 已到根（/' 或 C:\） }
    d := IncludeTrailingPathDelimiter(up);
  end;
  if firstExt <> '' then
    Result := ExcludeTrailingPathDelimiter(firstExt)
  else
    Result := '';
end;

function LWFindClientFile(const AName, ARoot: string): string;
var
  d, cand, par, up: string;
  i: Integer;
begin
  Result := '';
  if AName = '' then Exit;
  d := IncludeTrailingPathDelimiter(ExtractFilePath(ExpandFileName(ParamStr(0))));
  { ② 扁平部署：exe 同目录 或 exe/lw/ }
  if FileExists(d + AName) then Exit(d + AName);
  if FileExists(d + 'lw' + PathDelim + AName) then
    Exit(d + 'lw' + PathDelim + AName);
  { ① 标准仓库布局 }
  if ARoot <> '' then
  begin
    cand := IncludeTrailingPathDelimiter(ARoot) + 'src' + PathDelim + 'client' + PathDelim + AName;
    if FileExists(cand) then Exit(cand);
    { 扁平部署（推荐）：root\lw\ —— 目录名与 /lw/ URL 前缀、exe\lw\ 惯例一致 }
    cand := IncludeTrailingPathDelimiter(ARoot) + 'lw' + PathDelim + AName;
    if FileExists(cand) then Exit(cand);
    { 旧部署兼容：root\client\ —— 目录名容易被当成"客户端源码目录"，
      语义不清，仅继续识别不再推荐 }
    cand := IncludeTrailingPathDelimiter(ARoot) + 'client' + PathDelim + AName;
    if FileExists(cand) then Exit(cand);
    { ③ 兜底：从 root 向上逐级找 src/client }
    d := IncludeTrailingPathDelimiter(ARoot);
    for i := 0 to 4 do
    begin
      cand := d + 'src' + PathDelim + 'client' + PathDelim + AName;
      if FileExists(cand) then Exit(cand);
      par := ExcludeTrailingPathDelimiter(d);
      up := ExtractFileDir(par);
      if (up = '') or (up = par) then Break;   { 已到根（/ 或 C://） }
      d := IncludeTrailingPathDelimiter(up);
    end;
  end;
end;

function LWResolveRoot(const AHint: string; const APreferVer: string): string;
begin
  { 跨平台：不写死任何盘符/路径。显式 --root= 优先，其次按
    LWDefaultRoot 的规则（cwd → exe 向上），最后退回 exe 所在目录。 }
  if (AHint <> '') and DirectoryExists(AHint) then
    Exit(ExcludeTrailingPathDelimiter(AHint));
  Result := LWDefaultRoot(APreferVer);
  if Result = '' then
    Result := ExcludeTrailingPathDelimiter(ExtractFileDir(ExpandFileName(ParamStr(0))));
  if Result = '' then
    Result := ExcludeTrailingPathDelimiter(GetCurrentDir);
end;

{ ---------------- TLWHttpServer ---------------- }

{ 当前还活着的连接数。FPC 3.3.1 走 ConnectionHandler（3.2.2 根本没有
  这个类），3.2.2 只有公开的 ConnectionCount 计数器。包一层，
  Stop 里的收尾逻辑就能两个版本共用。 }
function TLWServer.LiveConnections: Integer;
begin
  Result := 0;
  if FHTTP = nil then
    Exit;
  {$IF FPC_FULLVERSION >= 30301}
  if FHTTP.ConnectionHandler <> nil then
    Result := FHTTP.ConnectionHandler.GetActiveConnectionCount;
  {$ELSE}
  Result := FHTTP.ConnectionCount;
  {$ENDIF}
end;

procedure TLWHttpServer.AbortConnections;
{$IF FPC_FULLVERSION >= 30301}
var
  h: TFPHTTPServerConnectionHandler;
  lst: TThreadList;
  L: TList;
  i: Integer;
  c: TFPHTTPConnection;
{$ENDIF}
begin
  {$IF FPC_FULLVERSION >= 30301}
  if ConnectionHandler = nil then Exit;
  { ① 先 shutdown 每个活跃连接：这是唯一能立刻叫醒阻塞在 select/recv
       里的连接线程的办法（见类声明处的注释）。fd 无效时 fpShutdown
       只是返回 -1，忽略即可。 }
  if ConnectionHandler is TFPHTTPServerConnectionListHandler then
  begin
    h := ConnectionHandler;
    lst := TFPHTTPServerConnectionListHandler(h).List;
    if lst <> nil then
    begin
      L := lst.LockList;
      try
        for i := 0 to L.Count - 1 do
        begin
          c := TFPHTTPConnection(L[i]);
          if (c <> nil) and (c.Socket <> nil) then
          begin
            try
              fpShutdown(TSocket(c.Socket.Handle), SHUT_RDWR);
            except
            end;
          end;
        end;
      finally
        lst.UnlockList;
      end;
    end;
  end;
  { ② 再走 fcl-web 自己的 CloseSockets（顺带把 keep-alive 标记清掉） }
  try
    ConnectionHandler.CloseSockets;
  except
  end;
  {$ELSE}
  { 3.2.2 没有 ConnectionHandler：连接线程列表是 TFPCustomHttpServer 的私有
    字段，外部（含子类）都拿不到，没法逐个 shutdown。好在这个版本的
    fphttpserver 是一连接一请求、不做 keep-alive —— 请求处理完连接线程
    自己就退，不存在"阻塞在 select 上等下一个请求"的空闲连接，所以这里
    只需要处理 WebSocket（它们已经不在 fcl-web 的连接列表里，见 ③）。 }
  {$ENDIF}
  { ③ WebSocket 连接不在 ConnectionHandler 的列表里，单独叫醒 }
  LWWShutdownAll;
end;

{ ---------------- TLWSweepThread ---------------- }

constructor TLWSweepThread.Create(AStore: TLWSessionStore; AMinutes: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FStore := AStore;
  FMinutes := AMinutes;
end;

procedure TLWSweepThread.Execute;
var
  i: Integer;
begin
  while not Terminated do
  begin
    { 一分钟一轮。用 250ms 切片等，停服时最多耽误 250ms 而不是 1 秒 }
    for i := 1 to 240 do
    begin
      if Terminated then Exit;
      Sleep(250);
    end;
    try
      LWDownloadSweep(30);   { 没人取的下载令牌 30 分钟后作废 }
      if FStore.Sweep(FMinutes) > 0 then
        LWLog('[lw] idle sessions swept');
    except
    end;
  end;
end;

{ ---------------- TLWServer ---------------- }

constructor TLWServer.Create(const ACfg: TLWServerConfig; AFactory: TLWFormFactory;
  ALister: TLWFormLister);
begin
  inherited Create;
  FCfg := ACfg;
  FFactory := AFactory;
  FLister := ALister;
  FStore := TLWSessionStore.Create;
  FStartedAt := Now;
  { 根目录下只有一个 ext-* 时就记下它：部署时目录名跟 DefaultExt 对不上
    （改名 ext-7.6.0、或只有 ext-7.5.1-min）也能直接跑。传 '' 而不是
    DefaultExt —— 多版本共存时必须严格按版本号匹配，不能因为「默认版本
    存在」就把别的版本号也指到它上面。 }
  if FCfg.ExtDir = '' then
    FSingleExtDir := LWFindExtDirIn(FCfg.Root, '')
  else
    FSingleExtDir := '';
  FRunDone := RTLEventCreate;
end;

destructor TLWServer.Destroy;
begin
  LWStopTrace('Destroy 进入（Stop 幂等，这里通常是空转）');
  Stop;
  LWStopTrace('Destroy ① Stop 完毕');
  FStore.Free;
  LWStopTrace('Destroy ② 会话仓库已释放');
  if FRunDone <> nil then
  begin
    RTLEventDestroy(FRunDone);
    FRunDone := nil;
  end;
  inherited Destroy;
end;

function TLWServer.Cfg: TLWServerConfig;
begin
  Result := FCfg;
end;

procedure TLWServer.SetVerbose(AValue: Boolean);
begin
  FCfg.Verbose := AValue;
end;

function TLWServer.SessionCount: Integer;
begin
  if FStore <> nil then
    Result := FStore.Count
  else
    Result := 0;
end;

function TLWServer.ExtRootFor(const AVer: string): string;
var
  v, exact: string;
begin
  { 配置文件指定了 ext-js 目录就以它为准：一个部署一般只带一个 ext 版本，
    按版本再分目录反而多一层歧义。 }
  if FCfg.ExtDir <> '' then
    Exit(IncludeTrailingPathDelimiter(FCfg.ExtDir));
  v := AVer;
  if v = '' then v := FCfg.DefaultExt;
  exact := IncludeTrailingPathDelimiter(FCfg.Root) + 'ext-' + v;
  { ① 正常情况：<root>\ext-<版本> 存在就用它（多版本并存时各走各的）
    ② 目录名对不上：根目录下只有一个 ext-* 目录，就用那个 —— 这样把
       ext-7.5.1 改名成 ext-7.6.0、或只部署 ext-7.5.1-min 都能跑，
       版本号不再需要改源码。 }
  if DirectoryExists(exact) or (FSingleExtDir = '') then
    Result := exact
  else
    Result := IncludeTrailingPathDelimiter(FCfg.Root) + FSingleExtDir;
end;

{ 某个 ext 目录下是否存在相对路径 ARel（'/' 分隔） }
function TLWServer.ExtFileExists(const AVer, ARel: string): Boolean;
var
  p: string;
begin
  p := StringReplace(ARel, '/', PathDelim, [rfReplaceAll]);
  Result := FileExists(IncludeTrailingPathDelimiter(ExtRootFor(AVer)) + p);
end;

function TLWServer.FindSingleExtDir: string;
begin
  Result := FSingleExtDir;
end;

{ 主题 CSS 三件套在不在。新版 Ext 可能删掉某个主题（比如 7.6 之后
  classic 改名），请求的主题没 CSS 就退到还在的，避免整页没样式。 }
function TLWServer.PickTheme(const AVer, ATheme: string): string;
const
  Fallback: array[0..2] of string = ('crisp', 'classic', 'neptune');
var
  i: Integer;
begin
  Result := LWValidTheme(ATheme);
  if ExtFileExists(AVer, 'build/classic/theme-' + Result + '/resources/theme-' +
    Result + '-all.css') then
    Exit;
  for i := Low(Fallback) to High(Fallback) do
    if ExtFileExists(AVer, 'build/classic/theme-' + Fallback[i] + '/resources/theme-' +
      Fallback[i] + '-all.css') then
      Exit(Fallback[i]);
  { 一个都没有：保持用户要的，404 至少能看出是主题名不对 }
  Result := LWValidTheme(ATheme);
end;

procedure TLWServer.PrintBanner;
var
  s: string;
  sr: TSearchRec;
begin
  LWLogRaw('');
  LWLogRaw('  lazarusWeb ' + LW_VERSION);
  LWLogRaw('  --------------------------------------------------');
  LWLogRaw('  Root      : ' + FCfg.Root);
  if SameText(FCfg.DefaultClient, 'alpine') then
  begin
    { Alpine.js 渲染层：样式内置（lw-alpine.css），不依赖 ext-<版本> 目录 }
    if FCfg.ClientExplicit then
      LWLogRaw('  Client    : alpine（Alpine.js ' + ALPINE_VERSION +
        '，无需 ext 目录）   (切换: /?client=ext)')
    else
      LWLogRaw('  Client    : alpine（Alpine.js ' + ALPINE_VERSION +
        '，自动探测优先）   (切换: /?client=ext)');
    LWLogRaw('  Form      : ' + FCfg.DefaultForm);
    LWLogRaw('  Listen    : http://127.0.0.1:' + IntToStr(FCfg.Port) + '/');
  end
  else
  begin
    if FCfg.ClientExplicit then
      LWLogRaw('  Client    : ext（Ext JS）   (切换: /?client=alpine)')
    else
      LWLogRaw('  Client    : ext（Ext JS，自动探测：未找到 alpine.min.js）   (切换: /?client=alpine)');
    if FCfg.ExtDir <> '' then
      LWLogRaw('  Ext       : ' + IncludeTrailingPathDelimiter(FCfg.ExtDir) +
        '  (配置文件 extdir)')
    else
    begin
      LWLogRaw('  Ext       : ' + ExtRootFor(FCfg.DefaultExt) +
        '  (版本 ' + FCfg.DefaultExt + ')');
      { 目录名跟版本号不一致时提示一句，免得以后看到 "/ext/7.5.1/..." 犯迷糊 }
      if (FSingleExtDir <> '') and (FSingleExtDir <> 'ext-' + FCfg.DefaultExt) then
        LWLogRaw('              根目录下只有 ' + FSingleExtDir +
          '，按它提供所有版本号的请求');
    end;
    if not ExtFileExists(FCfg.DefaultExt, 'build/ext-all.js') then
      LWLogRaw('  警告      : ' + ExtRootFor(FCfg.DefaultExt) +
        PathDelim + 'build' + PathDelim + 'ext-all.js 不存在，页面会白屏');
    LWLogRaw('  Form      : ' + FCfg.DefaultForm);
    LWLogRaw('  Listen    : http://127.0.0.1:' + IntToStr(FCfg.Port) + '/');
    { 根目录里有多个 ext-* 时列出来：?ext=<版本> 可以逐个切（默认走 DefaultExt）}
    if FCfg.ExtDir = '' then
    begin
      s := '';
      if FindFirst(IncludeTrailingPathDelimiter(FCfg.Root) + 'ext-*', faDirectory, sr) = 0 then
      try
        repeat
          if ((sr.Attr and faDirectory) <> 0) and (sr.Name <> '.') and (sr.Name <> '..') then
            s := s + '  ' + sr.Name;
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
      end;
      if s <> '' then
        LWLogRaw('  Ext dirs  :' + s + '   (切换: /?ext=<版本>)');
    end;
    LWLogRaw('  Theme      : ' + PickTheme(FCfg.DefaultExt, FCfg.Theme) +
      '   (切换: /?theme=gray 等)');
  end;
  if FCfg.LoginForm <> '' then
    LWLogRaw('  Login      : ' + FCfg.LoginForm + '（未认证会话先显示登录窗体）');
  LWLogRaw('  --------------------------------------------------');
  if FCfg.NoUI then
    LWLogRaw('  无窗口模式（--nogui），Ctrl+C 退出')
  else
    LWLogRaw('  关闭面板窗口 = 隐藏到系统托盘；结束服务请用面板菜单「退出」');
  LWLogRaw('');
end;

procedure TLWServer.Start;
begin
  LWSetServerStopping(False);
  FStopping := False;
  FHTTP := TLWHttpServer.Create(nil);
  FHTTP.Port := FCfg.Port;
  { 每连接一个线程。3.3.1 用枚举 ThreadMode，3.2.2 只有一个布尔开关 }
  {$IF FPC_FULLVERSION >= 30301}
  FHTTP.ThreadMode := tmThread;
  {$ELSE}
  FHTTP.Threaded := True;
  {$ENDIF}
  FHTTP.QueueSize := 64;
  { accept 循环的超时。默认 0 = 阻塞在 accept() 里直到有人连进来，
    于是 Active := False 只是把 FAccepting 置 False，循环却还要等下一个
    连接才醒 —— 关窗时进程就这么吊着（NOTES 坑 44）。给个 250ms 的
    select 超时，循环每 250ms 看一次标志，停服时立刻退出。
    新连接的处理没有延迟：select 一有数据就返回。 }
  FHTTP.AcceptIdleTimeout := 250;
  FHTTP.OnRequest := @HandleRequest;
  { 请求级异常：客户端中途断开/中止请求时向死 socket 写响应会抛
    EWriteError/ESocketError，fcl-web 已捕获并断开该连接（不影响服务），
    这里只记日志，方便在 --log 里确认"这是断连不是故障" }
  FHTTP.OnRequestError := @HandleRequestError;
  { WebSocket：升级 /lw/ws。握手与帧循环见 WSUpgrade/WSRun。
    FPC 3.3.1 起 fphttpserver 原生支持连接升级：注册处理器后，命中
    Upgrade: websocket 的连接被标记 IsUpgraded、socket 所有权移交给
    WSUpgrade；FPC 3.2.2 没有这套机制（fphttpserver 里连
    RegisterUpdateHandler 都没有），改由 HandleRequest 自己接管，
    见那里 {$IF FPC_FULLVERSION < 30301} 的分支。 }
  {$IF FPC_FULLVERSION >= 30301}
  FHTTP.RegisterUpdateHandler('websocket', @WSHandlesUpgrade, @WSUpgrade);
  {$ENDIF}

  { 清扫线程必须在 Active := True 之前起：Active := True 一进 accept
    循环就不返回，写在它后面的代码要等服务停了才执行（早期版本就是这么
    写的，等于会话过期清理从来没跑过） }
  FSweeper := TLWSweepThread.Create(FStore, FCfg.SessionTimeoutMin);
  FSweeper.Start;

  FStartCalled := True;
  try
    FHTTP.Active := True;   { 阻塞在 accept 循环里，直到 Stop }
  finally
    FRunFinished := True;
    RTLEventSetEvent(FRunDone);
  end;
end;

procedure TLWServer.Stop;
var
  i: Integer;
begin
  { 幂等：关窗时 OnClose 调一次，TLWServer.Destroy 里还会再调一次 }
  if FStopping then Exit;
  FStopping := True;
  LWStopTraceBegin;

  { ① 先叫醒挂起的长轮询。它们卡在 WaitCommand 里最长 20 秒，
       不叫醒的话下面释放 HTTP 服务器会一直等这些连接线程收工，
       关窗就变成"等半天"。 }
  LWSetServerStopping(True);
  LWStopTrace('Stop ① 长轮询已置退出标志');

  { ② 清扫线程：切片 250ms，最多耽误 250ms }
  if FSweeper <> nil then
  begin
    FSweeper.Terminate;
    FSweeper.WaitFor;
    FreeAndNil(FSweeper);
  end;
  LWStopTrace('Stop ② 清扫线程已结束');

  if FHTTP <> nil then
  begin
    { ③ 关监听：accept 循环最多 250ms 后自己退出 }
    try
      FHTTP.Active := False;
    except
      on E: Exception do
        LWLog('警告: 停止监听时出错: ' + E.Message);
    end;
    LWStopTrace('Stop ③ 监听已关闭');
    { ④ 还挂着的连接（浏览器 keep-alive、正在读一半的请求）直接断掉。
         不主动断的话，下面 Free 里那套 WaitForRequests 会按 10×100ms
         的节奏空等一秒多才轮到 CloseSockets —— 关窗白白慢一拍 }
    FHTTP.AbortConnections;
    LWStopTrace('Stop ④ 残留连接已断开');
    { ⑤ 等 Start 真的返回再释放。少了这一步，accept 线程可能在
         FHTTP 已经被释放之后才回到循环里，踩空指针抛 Access violation }
    if FStartCalled and (not FRunFinished) then
    begin
      RTLEventWaitFor(FRunDone, 3000);
      if not FRunFinished then
        LWLog('警告: 监听线程 3 秒内没有退出，跳过服务器清理（内存泄漏但可安全退出）');
    end;
    LWStopTrace('Stop ⑤ Start 已返回');
    if (not FStartCalled) or FRunFinished then
    begin
      { ⑥ 释放 HTTP 服务器。这里有两个坑，都是 fcl-web 内部的：
         1) TFPCustomHttpServer.Destroy 在连接列表非空时会调
            WaitForRequests(High(Integer)) —— 无限等，而个别连接线程
            可能还睡在自己的读超时里（实测浏览器连过之后能干等
            10~29 秒）；
         2) 就算跳过析构，把还活着的连接线程留在进程里，收尾阶段
            （停服务 -> 释放会话 -> RTL 退出）也可能被它拖住几十秒
            （实测一次 33 秒）。
         所以先给 1 秒宽限（shutdown 之后绝大多数连接 50ms 内就收工，
         通常这里一次都不循环就过去了），还没走完就直接结束进程：
         退出这一刻没有任何必须保住的资源，让 OS 回收远比让用户
         盯着关不掉的窗口划算。 }
      i := 0;
      while (i < 20) and (LiveConnections > 0) do
      begin
        Sleep(50);
        Inc(i);
      end;
      if LiveConnections > 0 then
      begin
        LWStopTrace('Stop ⑥ 仍有 ' + IntToStr(LiveConnections) +
          ' 个连接没退，直接结束进程');
        FHTTP := nil;
        Halt(0);
      end
      else
        FreeAndNil(FHTTP);
    end
    else
      FHTTP := nil;   { 线程还卡在里面：宁可泄漏，也不能在它脚下拆对象 }
    LWStopTrace('Stop ⑥ HTTP 服务器已释放');
  end;
  LWStopTrace('Stop 结束');
end;

procedure TLWServer.Reply(const AText, AMime: string; ACode: Integer;
  var AResponse: TFPHTTPConnectionResponse);
begin
  AResponse.Code := ACode;
  {$IF FPC_FULLVERSION >= 30301}
  AResponse.CodeText := GetHTTPStatusText(ACode);   { 3.3.1 原生，与合并前一致 }
  {$ELSE}
  AResponse.CodeText := LWHTTPStatusText(ACode);    { 3.2.2 无此函数，用自带码表 }
  {$ENDIF}
  AResponse.ContentType := AMime;
  AResponse.Content := AText;
end;

procedure TLWServer.ServeFile(const AFullPath: string; var AResponse: TFPHTTPConnectionResponse);
var
  fs: TFileStream;
begin
  if not FileExists(AFullPath) then
  begin
    Reply('404 not found: ' + ExtractFileName(AFullPath), 'text/plain; charset=utf-8', 404, AResponse);
    Exit;
  end;
  try
    fs := TFileStream.Create(AFullPath, fmOpenRead or fmShareDenyWrite);
  except
    Reply('500 cannot open ' + ExtractFileName(AFullPath), 'text/plain; charset=utf-8', 500, AResponse);
    Exit;
  end;
  AResponse.Code := 200;
  AResponse.CodeText := 'OK';
  AResponse.ContentType := MimeOf(AFullPath);
  { lw.js/lw.css 是浏览器端运行时，改动频繁 —— 禁止缓存，避免用户
    浏览器拿着旧版运行时对不上服务端（表现为按钮点了没反应、新控件
    渲染成占位框等"时灵时不灵"的怪象） }
  AResponse.SetCustomHeader('Cache-Control', 'no-store');
  AResponse.ContentStream := fs;
  AResponse.FreeContentStream := True;
end;

procedure TLWServer.ServeExt(const APath: string; var AResponse: TFPHTTPConnectionResponse);
var
  rest, ver, rel, full: string;
  p: Integer;
begin
  { /ext/<版本>/build/ext-all.js  ->  <root>\ext-<版本>\build\ext-all.js }
  rest := Copy(APath, 6, MaxInt);
  p := Pos('/', rest);
  if p <= 0 then
  begin
    Reply('400 bad ext path', 'text/plain; charset=utf-8', 400, AResponse);
    Exit;
  end;
  ver := Copy(rest, 1, p - 1);
  rel := Copy(rest, p + 1, MaxInt);
  rel := StringReplace(rel, '/', PathDelim, [rfReplaceAll]);
  { 版本段和相对路径都会拼进文件名，必须挡掉越界：版本只放行
    [0-9A-Za-z._-]，相对路径不许有 '..' 和盘符。 }
  if (not LWIsSafeExtVer(ver)) or (rel = '') or
     (Pos('..', rel) > 0) or (Pos(':', rel) > 0) then
  begin
    Reply('403 forbidden', 'text/plain; charset=utf-8', 403, AResponse);
    Exit;
  end;
  { 版本目录必须真实存在（ExtDir 模式下所有版本都落到同一目录，
    ExtRootFor 已经把它换掉了）。不再维护版本白名单：7.6.0、8.0.0
    甚至 ext-custom 这样自己起的目录名都能用。 }
  if (FCfg.ExtDir = '') and (not DirectoryExists(ExtRootFor(ver))) then
  begin
    Reply('404 unknown ext version: ' + ver, 'text/plain; charset=utf-8', 404, AResponse);
    Exit;
  end;
  full := IncludeTrailingPathDelimiter(ExtRootFor(ver)) + rel;
  ServeFile(full, AResponse);
end;

function TLWServer.BuildIndexHtml(const AExtVer, AForm, ATheme: string): string;
var
  ver, th: string;
  hasChartCss, hasChartJs: Boolean;
begin
  { 版本号不再归一化成固定值：?ext=7.6.0 就按 7.6.0 找目录（ExtRootFor 负责
    落到 ext-7.6.0，或在只有一个 ext 目录时落到那个目录）。不合法的版本段
    （带路径分隔符等）退回默认版本，避免拼出越界路径。 }
  ver := Trim(AExtVer);
  if not LWIsSafeExtVer(ver) then ver := FCfg.DefaultExt;
  th := PickTheme(ver, ATheme);
  { charts 包按「磁盘上有没有」决定注入：Ext 6.5 以来 charts.js 与
    charts-all.css 的路径一直没变，7.0.0 其实也有，所以不再按版本号判断。
    charts CSS 用 crisp 变体：图表配色是自包含的，配哪个主题都协调 }
  hasChartCss := ExtFileExists(ver,
    'build/packages/charts/classic/crisp/resources/charts-all.css');
  hasChartJs := ExtFileExists(ver, 'build/packages/charts/classic/charts.js');
  { 注意：必须分步拼接，不能写成一条 "常量 + 运行时值 + 常量 + ..." 的长链。
    本机 FPC 3.3.1 (2026-11-07 trunk) 编译器在这种链式折叠 + {$codepage utf8}
    组合下会丢字节：字面量末尾的 ":" ">" 和 LineEnding 的 "\n" 都会被吃掉，
    浏览器端 LW.start(...) 变成非法 JS，页面只剩白块。
    分步（s := s + ...）实测逐字节正确，见 docs/NOTES.md 坑 22。 }
  Result := '<!DOCTYPE html>';
  Result := Result + LineEnding + '<html><head><meta charset="utf-8">';
  Result := Result + LineEnding + '<meta name="viewport" content="width=device-width, initial-scale=1">';
  Result := Result + LineEnding + '<title>' + FCfg.Title + '</title>';
  Result := Result + LineEnding + '<link rel="stylesheet" href="/ext/' + ver + '/build/classic/theme-' + th + '/resources/theme-' + th + '-all.css">';
  if hasChartCss then
  begin
    Result := Result + LineEnding + '<link rel="stylesheet" href="/ext/' + ver + '/build/packages/charts/classic/crisp/resources/charts-all.css">';
  end;
  Result := Result + LineEnding + '<link rel="stylesheet" href="/lw/lw.css?v=' + LW_VERSION + '">';
  Result := Result + LineEnding + '<script src="/ext/' + ver + '/build/ext-all.js"></script>';
  if hasChartJs then
  begin
    Result := Result + LineEnding + '<script src="/ext/' + ver + '/build/packages/charts/classic/charts.js"></script>';
  end;
  Result := Result + LineEnding + '<script src="/lw/lw.js?v=' + LW_VERSION + '"></script>';
  Result := Result + LineEnding + '</head><body>';
  Result := Result + LineEnding + '<div id="lw-busy"></div>';
  Result := Result + LineEnding + '<div id="lw-splash"><div class="lw-splash-box">正在连接 lazarusWeb 服务端…</div></div>';
  Result := Result + LineEnding + '<script>LW.start({form:' + QuotedStr(AForm) + ',ext:' + QuotedStr(ver) + '});</script>';
  Result := Result + LineEnding + '</body></html>';
end;

procedure TLWServer.ServeIndex(const AExtVer, AForm, ATheme: string;
  var AResponse: TFPHTTPConnectionResponse);
begin
  Reply(BuildIndexHtml(AExtVer, AForm, ATheme), 'text/html; charset=utf-8', 200, AResponse);
end;

{ ---------------- Alpine.js 客户端外壳（?client=alpine） ----------------
  与 Ext 版同一套 /lw/api/* 协议，只是页面壳换成：
    alpine.min.js（defer，本地文件，不走 CDN）+ lw-alpine.js/lw-alpine.css。
  外壳 UI（遮罩/对话框/toast/忙条）用 Alpine store + 指令声明在静态标记里，
  业务控件树由 lw-alpine.js 动态渲染。注意坑 22：分步拼接，别折叠成长链。 }
function TLWServer.BuildAlpineHtml(const AForm: string): string;
var
  s: string;
begin
  s := '<!DOCTYPE html>';
  s := s + LineEnding + '<html><head><meta charset="utf-8">';
  s := s + LineEnding + '<meta name="viewport" content="width=device-width, initial-scale=1">';
  s := s + LineEnding + '<title>' + FCfg.Title + '</title>';
  s := s + LineEnding + '<link rel="stylesheet" href="/lw/lw.css?v=' + LW_VERSION + '">';
  s := s + LineEnding + '<link rel="stylesheet" href="/lw/lw-alpine.css?v=' + LW_VERSION + '">';
  s := s + LineEnding + '<script src="/lw/alpine.min.js" defer></script>';
  s := s + LineEnding + '<script src="/lw/lw-alpine.js?v=' + LW_VERSION + '"></script>';
  s := s + LineEnding + '</head><body>';
  s := s + LineEnding + '<div id="lw-busy" x-data x-show="$store.lw.busy > 0" style="display:none"></div>';
  s := s + LineEnding + '<div id="lw-splash" x-data x-show="$store.lw.splash">';
  s := s + LineEnding + '<div class="lw-splash-box" x-text="$store.lw.splash">正在连接 lazarusWeb 服务端…</div>';
  s := s + LineEnding + '</div>';
  s := s + LineEnding + '<div id="lw-root"></div>';
  { 会话级遮罩（LWShowScreenMask）—— 顶层指令必须在 x-data 作用域内 }
  s := s + LineEnding + '<div x-data>';
  s := s + LineEnding + '<template x-if="$store.lw.mask.show">';
  s := s + LineEnding + '<div class="lw-mask" @click="$store.lw.mask.show = false"><div class="lw-mask-box"><div class="lw-mask-spin"></div>';
  s := s + LineEnding + '<div class="lw-mask-text" x-text="$store.lw.mask.text"></div></div></div>';
  s := s + LineEnding + '</template>';
  s := s + LineEnding + '</div>';
  { 轻提示（ShowToast）：右上角弹几秒消失 }
  s := s + LineEnding + '<div class="lw-toast-wrap" x-data x-show="$store.lw.toasts.length > 0">';
  s := s + LineEnding + '<template x-for="t in $store.lw.toasts" :key="t.id">';
  s := s + LineEnding + '<div class="lw-toast"><div class="lw-toast-title" x-text="t.title"></div>';
  s := s + LineEnding + '<div class="lw-toast-text" x-text="t.text"></div></div>';
  s := s + LineEnding + '</template></div>';
  { 服务端模态对话框（ShowMessage/MessageDlg/InputBox/选文件） }
  s := s + LineEnding + '<div x-data>';
  s := s + LineEnding + '<template x-if="$store.lw.dialog">';
  s := s + LineEnding + '<div class="lw-dlg-overlay" @keydown.escape.window="$lwDlgClose()">';
  s := s + LineEnding + '<div class="lw-dlg-win" role="dialog">';
  s := s + LineEnding + '<div class="lw-dlg-title">';
  s := s + LineEnding + '<template x-if="$store.lw.dialog.kind === ''info''"><span class="lw-dlg-title-icon lw-dlg-i-info">i</span></template>';
  s := s + LineEnding + '<template x-if="$store.lw.dialog.kind === ''warning''"><span class="lw-dlg-title-icon lw-dlg-i-warn">!</span></template>';
  s := s + LineEnding + '<template x-if="$store.lw.dialog.kind === ''error''"><span class="lw-dlg-title-icon lw-dlg-i-err">✕</span></template>';
  s := s + LineEnding + '<template x-if="$store.lw.dialog.kind === ''question''"><span class="lw-dlg-title-icon lw-dlg-i-ques">?</span></template>';
  s := s + LineEnding + '<span x-text="$store.lw.dialog.caption || ''消息''"></span>';
  s := s + LineEnding + '<span class="lw-dlg-x" @click="$lwDlgClose()">×</span>';
  s := s + LineEnding + '</div>';
  s := s + LineEnding + '<div class="lw-dlg-body">';
  s := s + LineEnding + '<div class="lw-dlg-msg" x-text="$store.lw.dialog.text"></div>';
  s := s + LineEnding + '<template x-if="$store.lw.dialog.kind === ''input'' || $store.lw.dialog.kind === ''savefile''">';
  s := s + LineEnding + '<input type="text" class="lw-input lw-dlg-input" x-model="$store.lw.dlgText" @keydown.enter="$lwDlgKey($event)"/>';
  s := s + LineEnding + '</template>';
  s := s + LineEnding + '<template x-if="$store.lw.dialog.kind === ''openfile''">';
  s := s + LineEnding + '<div class="lw-dlg-file"><span x-text="$store.lw.dlgUpload || ''点「浏览」选择文件，确认后自动上传''"></span></div>';
  s := s + LineEnding + '</template>';
  s := s + LineEnding + '</div>';
  s := s + LineEnding + '<div class="lw-dlg-btns">';
  s := s + LineEnding + '<template x-for="b in $store.lw.dialog.buttons" :key="b.id">';
  { Alpine x-for 模板要求单根节点，这里用 display:contents 包住两个兄弟节点 }
  s := s + LineEnding + '<span style="display:contents">';
  s := s + LineEnding + '<template x-if="$store.lw.dialog.kind === ''openfile'' && b[''default'']">';
  s := s + LineEnding + '<button type="button" class="lw-btn" @click="$store.lw.dialog.pick()">浏览…</button>';
  s := s + LineEnding + '</template>';
  s := s + LineEnding + '<button type="button" class="lw-btn" :class="b[''default''] ? ''lw-dlg-default'' : ''''"';
  s := s + LineEnding + ' x-show="!($store.lw.dialog.kind === ''openfile'' && b[''default''] )" @click="$lwDlgAnswer(b)" x-text="b.text"></button>';
  s := s + LineEnding + '</span>';
  s := s + LineEnding + '</template>';
  s := s + LineEnding + '</div>';
  s := s + LineEnding + '</div></div>';
  s := s + LineEnding + '</template>';
  s := s + LineEnding + '</div>';
  s := s + LineEnding + '<script>LW.start({form:' + QuotedStr(AForm) + '});</script>';
  s := s + LineEnding + '</body></html>';
  Result := s;
end;

procedure TLWServer.ServeAlpineIndex(const AForm: string;
  var AResponse: TFPHTTPConnectionResponse);
begin
  Reply(BuildAlpineHtml(AForm), 'text/html; charset=utf-8', 200, AResponse);
end;

function TLWServer.QueryP(const ARequest: TFPHTTPConnectionRequest; const AName, ADef: string): string;
var
  s: string;
begin
  s := '';
  if Assigned(ARequest.QueryFields) then
    s := Trim(ARequest.QueryFields.Values[AName]);
  if s = '' then Result := ADef else Result := s;
end;

function TLWServer.ParseBody(var ARequest: TFPHTTPConnectionRequest): TJSONObject;
var
  d: TJSONData;
  s: string;
begin
  Result := nil;
  s := ARequest.Content;
  if Trim(s) = '' then Exit;
  try
    d := GetJSON(s);
  except
    Exit(nil);
  end;
  if (d <> nil) and (d.JSONType = jtObject) then
    Result := TJSONObject(d)
  else
    d.Free;
end;

procedure TLWServer.ApiSession(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  body: TJSONObject;
  fname: string;
  f: TCustomForm;
  s: TLWSession;
  payload: TJSONObject;
begin
  f := nil;
  body := ParseBody(ARequest);
  try
    if body <> nil then
      fname := JGetStr(body, 'form', FCfg.DefaultForm)
    else
      fname := FCfg.DefaultForm;
  finally
    body.Free;
  end;
  if fname = '' then
  begin
    Reply('{"ok":false,"err":"no form specified"}', 'application/json; charset=utf-8', 400, AResponse);
    Exit;
  end;
  { 启用了登录（TLWApp.SetLogin）：不管浏览器请求哪个窗体，
    新会话一律先创建登录窗体；主窗体等认证通过后由 lwlogin 创建 }
  if FCfg.LoginForm <> '' then
    fname := FCfg.LoginForm;

  { 建窗体和首次序列化都在 lwapp / lwsession 内部串行了（LWLCLEnter），
    这里保持顺序调用即可 }
  if (FFactory = nil) or (not FFactory(fname, f)) then
  begin
    Reply('{"ok":false,"err":"form not registered: ' + fname + '"}',
      'application/json; charset=utf-8', 404, AResponse);
    Exit;
  end;

  s := FStore.NewSession(f, ClientIP(ARequest));
  s.RequireAuth := FCfg.LoginForm <> '';
  s.LoginForm := f;
  if FCfg.Verbose then
    LWLog(Format('[lw] %s session %s form=%s', [FormatDateTime('hh:nn:ss', Now), s.Sid, fname]));
  s.AttachTab;
  payload := s.BuildPayload;
  try
    payload.Add('seq', s.Seq);
    Reply(payload.AsJSON, 'application/json; charset=utf-8', 200, AResponse);
  finally
    payload.Free;
  end;
end;

procedure TLWServer.ApiAttach(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  sid: string;
  s: TLWSession;
  payload: TJSONObject;
  dlg: string;
  d: TJSONData;
begin
  sid := QueryP(ARequest, 'sid', '');
  s := FStore.Find(sid);
  if s = nil then
  begin
    { 会话过期/服务重启：浏览器会退回新建会话 }
    Reply('{"ok":false,"gone":true,"err":"session gone"}',
      'application/json; charset=utf-8', 410, AResponse);
    Exit;
  end;
  try
    s.Touch;
    s.AttachTab;
    payload := s.BuildPayload;
    try
      payload.Add('attached', True);
      payload.Add('seq', s.Seq);
      { 页签刷新（Shift+F5）时挂起的对话框指令已经被旧游标消费掉，
        不重发的话：对话框消失、服务端线程吊在 MessageDlg 上直到超时，
        期间整个会话的事件全部堵死。attach 响应里带回重发一次。 }
      dlg := s.PendingDialogCmd;
      if dlg <> '' then
      begin
        d := GetJSON(dlg);
        if d is TJSONObject then
          payload.Add('cmd', TJSONObject(d))
        else
          d.Free;
      end;
      Reply(payload.AsJSON, 'application/json; charset=utf-8', 200, AResponse);
    finally
      payload.Free;
    end;
  finally
    FStore.Release(s);
  end;
end;

procedure TLWServer.ApiTree(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  s: TLWSession;
  payload: TJSONObject;
begin
  s := FStore.Find(QueryP(ARequest, 'sid', ''));
  if s = nil then
  begin
    Reply('{"ok":false,"err":"session gone"}', 'application/json; charset=utf-8', 410, AResponse);
    Exit;
  end;
  try
    s.Touch;
    payload := s.BuildPayload;
    try
      Reply(payload.AsJSON, 'application/json; charset=utf-8', 200, AResponse);
    finally
      payload.Free;
    end;
  finally
    FStore.Release(s);
  end;
end;

procedure TLWServer.ApiUpload(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  s: TLWSession;
  sid, err: string;
  id: Integer;
  payload: TJSONObject;
begin
  sid := QueryP(ARequest, 'sid', '');
  id := StrToIntDef(QueryP(ARequest, 'id', '0'), 0);
  s := FStore.Find(sid);
  if s = nil then
  begin
    Reply('{"ok":false,"err":"session gone"}', 'application/json; charset=utf-8', 410, AResponse);
    Exit;
  end;
  try
    s.Touch;
    payload := LWProcessUpload(s, ARequest, id, err);
    if payload = nil then
    begin
      Reply('{"ok":false,"err":' + TJSONString.Create(err).AsJSON + '}',
        'application/json; charset=utf-8', 400, AResponse);
      Exit;
    end;
    try
      Reply(payload.AsJSON, 'application/json; charset=utf-8', 200, AResponse);
    finally
      payload.Free;
    end;
  finally
    FStore.Release(s);
  end;
end;

{ 浏览器对话框的答复：请求体 sid / id / r / text

  服务端此刻正有一个线程挂在 SessionDialog 里等（ShowMessage / MessageDlg /
  InputQuery / TOpenDialog.Execute 都在那儿），这里把结果交给它唤醒即可。
  id 是对话框令牌，过期的令牌（用户连点两次、或者已经超时）会被忽略。 }
procedure TLWServer.ApiDialog(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  body: TJSONObject;
  s: TLWSession;
  sid: string;
  id, r: Integer;
  txt: string;
  ok: Boolean;
begin
  body := ParseBody(ARequest);
  if body = nil then
  begin
    Reply('{"ok":false,"err":"bad json"}', 'application/json; charset=utf-8', 400, AResponse);
    Exit;
  end;
  try
    sid := JGetStr(body, 'sid');
    s := FStore.Find(sid);
    if s = nil then
    begin
      Reply('{"ok":false,"err":"session gone"}', 'application/json; charset=utf-8', 410, AResponse);
      Exit;
    end;
    try
      s.Touch;
      id := JGetInt(body, 'id', 0);
      r := JGetInt(body, 'r', 0);
      txt := JGetStr(body, 'text');
      ok := s.ResolveDialog(id, r, txt);
      if ok then
        Reply('{"ok":true}', 'application/json; charset=utf-8', 200, AResponse)
      else
        Reply('{"ok":false,"err":"dialog not pending"}',
          'application/json; charset=utf-8', 200, AResponse);
    finally
      FStore.Release(s);
    end;
  finally
    body.Free;
  end;
end;

{ TOpenDialog.Execute：浏览器选中的文件以 multipart 传上来，
  服务端存到会话临时目录，路径直接作为对话框的答案。 }
procedure TLWServer.ApiDialogFile(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  s: TLWSession;
  sid, saved, err: string;
  id: Integer;
  j: TJSONObject;
begin
  sid := QueryP(ARequest, 'sid', '');
  id := StrToIntDef(QueryP(ARequest, 'id', '0'), 0);
  s := FStore.Find(sid);
  if s = nil then
  begin
    Reply('{"ok":false,"err":"session gone"}', 'application/json; charset=utf-8', 410, AResponse);
    Exit;
  end;
  try
    s.Touch;
    saved := LWProcessDialogUpload(s, ARequest, id, err);
    if saved = '' then
    begin
      Reply('{"ok":false,"err":' + TJSONString.Create(err).AsJSON + '}',
        'application/json; charset=utf-8', 400, AResponse);
      Exit;
    end;
    j := TJSONObject.Create;
    try
      j.Add('ok', True);
      j.Add('path', saved);
      Reply(j.AsJSON, 'application/json; charset=utf-8', 200, AResponse);
    finally
      j.Free;
    end;
  finally
    FStore.Release(s);
  end;
end;

{ RFC 5987 的 filename*=UTF-8''<百分号编码>，中文文件名才不会变乱码 }function UrlEncodeUTF8(const S: string): string;
var
  b: RawByteString;
  i: Integer;
const
  Hex = '0123456789ABCDEF';
begin
  Result := '';
  b := UTF8Encode(S);
  for i := 1 to Length(b) do
    if (b[i] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~']) then
      Result := Result + b[i]
    else
      Result := Result + '%' + Hex[(Ord(b[i]) shr 4) + 1] + Hex[(Ord(b[i]) and $F) + 1];
end;

procedure TLWServer.ApiDownload(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  token, fname, dname, mime: string;
  fs: TFileStream;
begin
  token := QueryP(ARequest, 't', '');
  if not LWDownloadResolve(token, fname, dname, mime) then
  begin
    Reply('404 下载链接无效或已过期', 'text/plain; charset=utf-8', 404, AResponse);
    Exit;
  end;
  try
    fs := TFileStream.Create(fname, fmOpenRead or fmShareDenyWrite);
  except
    Reply('500 无法打开文件', 'text/plain; charset=utf-8', 500, AResponse);
    Exit;
  end;
  LWDownloadRelease(token);   { 一次有效 }

  AResponse.Code := 200;
  AResponse.CodeText := 'OK';
  AResponse.ContentType := mime;
  AResponse.ContentLength := fs.Size;
  AResponse.SetCustomHeader('Content-Disposition',
    'attachment; filename="' + dname + '"; filename*=UTF-8''' + UrlEncodeUTF8(dname) + '''');
  AResponse.SetCustomHeader('Cache-Control', 'no-store');
  AResponse.ContentStream := fs;
  AResponse.FreeContentStream := True;
  if FCfg.Verbose then
    LWLog('[lw] download ' + dname + ' (' + IntToStr(fs.Size) + ' bytes)');
end;

procedure TLWServer.ApiView(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  token, fname, dname, mime: string;
  fs: TFileStream;
begin
  token := QueryP(ARequest, 't', '');
  if not LWDownloadResolve(token, fname, dname, mime) then
  begin
    Reply('404 查看链接无效或已过期', 'text/plain; charset=utf-8', 404, AResponse);
    Exit;
  end;
  try
    fs := TFileStream.Create(fname, fmOpenRead or fmShareDenyWrite);
  except
    Reply('500 无法打开文件', 'text/plain; charset=utf-8', 500, AResponse);
    Exit;
  end;
  { 查看：不释放令牌（iframe 可能反复请求），续期即可 }
  LWDownloadTouch(token);

  AResponse.Code := 200;
  AResponse.CodeText := 'OK';
  AResponse.ContentType := mime;
  AResponse.ContentLength := fs.Size;
  AResponse.SetCustomHeader('Content-Disposition',
    'inline; filename="' + dname + '"; filename*=UTF-8''' + UrlEncodeUTF8(dname) + '''');
  AResponse.SetCustomHeader('Cache-Control', 'no-store');
  AResponse.ContentStream := fs;
  AResponse.FreeContentStream := True;
end;

procedure TLWServer.ApiEvent(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  body: TJSONObject;
  sid, err, sjson: string;
  s: TLWSession;
  payload: TJSONObject;
  t0, t1, t2, t3: Int64;
begin
  body := ParseBody(ARequest);
  if body = nil then
  begin
    Reply('{"ok":false,"err":"bad json"}', 'application/json; charset=utf-8', 400, AResponse);
    Exit;
  end;
  try
    sid := JGetStr(body, 'sid');
    s := FStore.Find(sid);
    if s = nil then
    begin
      Reply('{"ok":false,"err":"session gone"}', 'application/json; charset=utf-8', 410, AResponse);
      Exit;
    end;
    try
      s.Touch;
      { 事件来自哪个页签（多页签共享会话时用来定向对话框），
        事件处理完必须清掉 —— 线程会被下一个请求复用 }
      LWSetCurrentTab(JGetStr(body, 'tab'));
      { 同一会话的事件串行执行：LCL 控件不是线程安全的，浏览器在对话框
        挂起期间仍可能发来第二个事件（连点 / 点别处 / 失败重试）。串行化
        同时保证"事件里再 BuildPayload"不会与其他序列化并发（见 TLWSession.FExec）}
      s.LockExec;
      t0 := LWProfNow;
      try
        payload := LWHandleEvent(s, body, err);
      finally
        t1 := LWProfNow;
        s.UnlockExec;
        LWSetCurrentTab('');
      end;
      if payload = nil then
      begin
        Reply('{"ok":false,"err":' + TJSONString.Create(err).AsJSON + '}',
          'application/json; charset=utf-8', 400, AResponse);
        Exit;
      end;
      try
        t2 := LWProfNow;
        sjson := payload.AsJSON;
        t3 := LWProfNow;
        Reply(sjson, 'application/json; charset=utf-8', 200, AResponse);
        if LWProfOn then
          LWProfLog(Format('http ev=%s id=%d', [JGetStr(body, 'ev'),
            JGetInt(body, 'id', 0)]),
            t1 - t0, t3 - t2, LWProfNow - t3, Length(sjson));
      finally
        payload.Free;
      end;
    finally
      FStore.Release(s);
    end;
  finally
    body.Free;
  end;
end;

procedure TLWServer.ApiLog(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  s: TLWSession;
  j: TJSONObject;
begin
  s := FStore.Find(QueryP(ARequest, 'sid', ''));
  if s = nil then
  begin
    Reply('{"ok":false,"err":"session gone"}', 'application/json; charset=utf-8', 410, AResponse);
    Exit;
  end;
  try
    j := TJSONObject.Create;
    try
      j.Add('ok', True);
      j.Add('log', s.ConsoleText);
      Reply(j.AsJSON, 'application/json; charset=utf-8', 200, AResponse);
    finally
      j.Free;
    end;
  finally
    FStore.Release(s);
  end;
end;

procedure TLWServer.ApiPoll(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  sid, cmd, outJson, asj, afterStr: string;
  s: TLWSession;
  t, after, seq: Integer;
  j: TJSONObject;
begin
  sid := QueryP(ARequest, 'sid', '');
  s := FStore.Find(sid);
  if s = nil then
  begin
    Reply('{"cmd":null,"gone":true}', 'application/json; charset=utf-8', 200, AResponse);
    Exit;
  end;
  try
    s.Touch;
    t := StrToIntDef(QueryP(ARequest, 't', IntToStr(LW_POLL_MS)), LW_POLL_MS);
    if t > 60000 then t := 60000;
    cmd := '';
    afterStr := QueryP(ARequest, 'after', '');
    if afterStr = '' then
    begin
      { 单页签（老行为）：销毁式队列 }
      s.WaitCommand(cmd, t);
      seq := s.Seq;
    end
    else
    begin
      { 多页签：每个页签带自己的游标。after=-1 表示"从现在开始"，
        只回当前序号，不回任何历史指令（新挂上的页签用） }
      after := StrToIntDef(afterStr, -1);
      if after < 0 then
      begin
        cmd := '';
        seq := s.Seq;
      end
      else
        s.WaitCommandAfter(after, t, cmd, seq);
    end;
    if cmd = '' then
      outJson := '{"cmd":null,"seq":' + IntToStr(seq) + '}'
    else
    begin
      outJson := '{"cmd":' + cmd + ',"seq":' + IntToStr(seq) + '}';
      { 模态窗体已经推送过去了，顺便把最新的树塞进指令里，少一次往返 }
      if IsModalCmd(cmd) then
      begin
        j := s.BuildPayload;
        try
          asj := j.AsJSON;
        finally
          j.Free;
        end;
        // 注意：必须先把 AsJSON 落到局部变量再 Format。
        // FPC 对 "常量 + 属性取值 + 常量" 这种链式拼接会丢末尾字符
        // （实测少了最后一个花括号，浏览器端 JSON.parse 直接失败）
        { seq 必须带上：多页签靠它推进游标，漏了会一直重复取同一条指令 }
        outJson := Format('{"cmd":%s,"tree":%s,"seq":%d}', [cmd, asj, seq]);
      end;
    end;
    Reply(outJson, 'application/json; charset=utf-8', 200, AResponse);
  finally
    FStore.Release(s);
  end;
end;

function TLWServer.RequestSid(var ARequest: TFPHTTPConnectionRequest): string;
begin
  Result := QueryP(ARequest, 'sid', '');
  if Result = '' then
    Result := Trim(ARequest.GetCustomHeader('X-LW-Sid'));
end;

function TLWServer.ClientIP(var ARequest: TFPHTTPConnectionRequest): string;
var
  xff: string;
  p: Integer;
begin
  Result := ARequest.RemoteAddress;
  if not FCfg.TrustProxy then Exit;
  { 反代后面：X-Forwarded-For 可能是 "client, proxy1, proxy2"，取第一段 }
  xff := Trim(ARequest.GetCustomHeader('X-Forwarded-For'));
  if xff = '' then Exit;
  p := Pos(',', xff);
  if p > 0 then xff := Trim(Copy(xff, 1, p - 1));
  if xff <> '' then Result := xff;
end;

procedure TLWServer.ApiHealth(var AResponse: TFPHTTPConnectionResponse);
var
  j: TJSONObject;
  up: Int64;
begin
  up := SecondsBetween(Now, FStartedAt);
  j := TJSONObject.Create;
  try
    j.Add('ok', True);
    j.Add('app', FCfg.Title);
    j.Add('ver', LW_VERSION);
    j.Add('sessions', FStore.Count);
    j.Add('uptime', up);
    j.Add('time', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    Reply(j.AsJSON, 'application/json; charset=utf-8', 200, AResponse);
  finally
    j.Free;
  end;
end;

{ 自定义 AJAX 端点。
  约定：/lw/ajax/<名字>，名字里允许 '/'；GET/POST/PUT/DELETE 都收；
  响应格式由处理器决定（默认 JSON）。第三方 JS 只需要知道 URL。 }
procedure TLWServer.ApiAjax(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  p, name, sid: string;
  q: Integer;
  h: TLWAjaxHandler;
  ctx: TLWAjaxContext;
  s: TLWSession;
  hdr: TStringList;
begin
  p := ARequest.URL;
  q := Pos('?', p);
  if q > 0 then p := Copy(p, 1, q - 1);
  name := Copy(p, 10, MaxInt);          { 去掉 '/lw/ajax/' }
  while (name <> '') and (name[Length(name)] = '/') do
    Delete(name, Length(name), 1);

  { CORS 预检：--ajax-cors 时允许跨域，浏览器就不再发 OPTIONS，
    但为了兼容手写的 fetch(method:'PUT') 还是应答一下 }
  if FCfg.AjaxCORS then
  begin
    AResponse.SetCustomHeader('Access-Control-Allow-Origin', '*');
    AResponse.SetCustomHeader('Access-Control-Allow-Headers', 'Content-Type, X-LW-Sid, Authorization');
    AResponse.SetCustomHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    AResponse.SetCustomHeader('Access-Control-Max-Age', '600');
  end;
  if UpperCase(ARequest.Method) = 'OPTIONS' then
  begin
    AResponse.Code := 204;
    Exit;
  end;

  if not LWLookupAjax(name, h) then
  begin
    Reply('{"ok":false,"err":' + TJSONString.Create('未注册的 AJAX 端点: ' + name).AsJSON +
      ',"names":"' + LWAjaxNames + '"}', 'application/json; charset=utf-8', 404, AResponse);
    Exit;
  end;

  sid := RequestSid(ARequest);
  s := nil;
  if sid <> '' then
    s := FStore.Find(sid);

  hdr := TStringList.Create;
  ctx := nil;
  try
    try
      if Assigned(ARequest.CustomHeaders) then
        hdr.Assign(ARequest.CustomHeaders);
    except
    end;
    ctx := TLWAjaxContext.Create(ARequest.Method, name, ARequest.QueryString,
      ARequest.Content, hdr, s);
    try
      try
        h(ctx);
      except
        on E: Exception do
        begin
          ctx.Error(E.ClassName + ': ' + E.Message, 500);
          LWLog('[lw] AJAX ERROR ' + name + ': ' + E.ClassName + ': ' + E.Message);
        end;
      end;
      if ctx.Code <= 0 then ctx.Code := 200;
      if ctx.Response = '' then ctx.Response := '{"ok":true}';
      Reply(ctx.Response, ctx.ContentType, ctx.Code, AResponse);
    finally
      ctx.Free;
    end;
  finally
    hdr.Free;
    if s <> nil then FStore.Release(s);
  end;
end;

procedure TLWServer.HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  handles: Boolean;
begin
  { FPC 3.2.2 兼容路径：这个版本的 fphttpserver 没有连接升级机制，只能在
    请求回调里自己接管。握手应答、帧循环全部在 WSRun 里同步完成 —— 连接
    线程被这条 WebSocket 独占（与 3.3.1 升级路径的行为一致）。
    循环结束后抛 ELWUpgraded 跳出，避免 fcl-web 再往这条已升级的连接上
    写一份 HTTP 响应（那不是合法的 WebSocket 数据）。 }
  {$IF FPC_FULLVERSION < 30301}
  handles := False;
  if ARequest.Connection <> nil then
  begin
    WSHandlesUpgrade(ARequest, handles);
    if handles then
    begin
      WSRun(ARequest.Connection.Socket, ARequest, False);
      raise ELWUpgraded.Create('websocket connection finished');
    end;
  end;
  {$ENDIF}
  try
    Route(ARequest, AResponse);
  except
    on E: Exception do
    begin
      try
        Reply('{"ok":false,"err":' + TJSONString.Create(E.Message).AsJSON + '}',
          'application/json; charset=utf-8', 500, AResponse);
      except
      end;
      LWLog('[lw] ERROR ' + E.ClassName + ': ' + E.Message);
      if FCfg.Verbose then
      begin
        LWLog('[lw] backtrace:');
        DumpExceptionBackTrace(ErrOutput);
        Flush(ErrOutput);
      end;
    end;
  end;
end;

procedure TLWServer.Route(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  p, method, lf: string;
  q: Integer;
begin
  method := UpperCase(ARequest.Method);
  p := ARequest.URL;
  q := Pos('?', p);
  if q > 0 then p := Copy(p, 1, q - 1);
  if p = '' then p := '/';

  if FCfg.Verbose then
    LWLog(Format('[lw] %s %s', [method, p]));

  if (p = '/') or (p = '/index.html') then
  begin
    { ?client= 选渲染层：'alpine' 走 Alpine.js 外壳，其余走 Ext 版。
      默认取 GCfg.DefaultClient（配置文件 client= / --client=），
      两个客户端协议完全一致、可并存切换 }
    if SameText(QueryP(ARequest, 'client', FCfg.DefaultClient), 'alpine') then
      ServeAlpineIndex(QueryP(ARequest, 'form', FCfg.DefaultForm), AResponse)
    else
      ServeIndex(QueryP(ARequest, 'ext', FCfg.DefaultExt),
        QueryP(ARequest, 'form', FCfg.DefaultForm),
        QueryP(ARequest, 'theme', FCfg.Theme), AResponse);
    Exit;
  end;

  if p = '/favicon.ico' then
  begin
    AResponse.Code := 204;
    Exit;
  end;

  { 负载均衡 / k8s 探针：不建会话、不碰磁盘，纯内存读 }
  if (p = '/lw/healthz') or (p = '/lw/health') then
  begin
    ApiHealth(AResponse);
    Exit;
  end;

  { 自定义 AJAX 端点（第三方 JS 逃生舱）。放在静态资源之前判断，
    名字里允许带 '/'，比如 /lw/ajax/orders/stats }
  if Copy(p, 1, 9) = '/lw/ajax/' then
  begin
    ApiAjax(ARequest, AResponse);
    Exit;
  end;

  if Copy(p, 1, 5) = '/ext/' then
  begin
    ServeExt(p, AResponse);
    Exit;
  end;

  if (p = '/lw/lw.js') or (p = '/lw/lw.css') or
     (p = '/lw/lw-alpine.js') or (p = '/lw/lw-alpine.css') or
     (p = '/lw/alpine.min.js') then
  begin
    lf := LWFindClientFile(ExtractFileName(p), FCfg.Root);
    if lf <> '' then
      ServeFile(lf, AResponse)
    else
      Reply('404 not found: ' + ExtractFileName(p) +
        '（部署目录需含 src/client/ 或 lw/' + ExtractFileName(p) +
        '，或把该文件拷到 exe 同目录）',
        'text/plain; charset=utf-8', 404, AResponse);
    Exit;
  end;

  if p = '/lw/api/forms' then
  begin
    if Assigned(FLister) then
    begin
      { 交给 lwapp 生成清单 }
    end;
    Reply('{"ok":true,"ver":"' + LW_VERSION + '","form":"' + FCfg.DefaultForm + '"}',
      'application/json; charset=utf-8', 200, AResponse);
    Exit;
  end;

  if p = '/lw/api/session' then
  begin
    ApiSession(ARequest, AResponse);
    Exit;
  end;
  if p = '/lw/api/attach' then
  begin
    ApiAttach(ARequest, AResponse);
    Exit;
  end;
  if p = '/lw/api/tree' then
  begin
    ApiTree(ARequest, AResponse);
    Exit;
  end;
  if p = '/lw/api/event' then
  begin
    ApiEvent(ARequest, AResponse);
    Exit;
  end;
  if p = '/lw/api/poll' then
  begin
    ApiPoll(ARequest, AResponse);
    Exit;
  end;
  if p = '/lw/api/log' then
  begin
    ApiLog(ARequest, AResponse);
    Exit;
  end;
  if p = '/lw/api/upload' then
  begin
    ApiUpload(ARequest, AResponse);
    Exit;
  end;
  if p = '/lw/api/dlg' then
  begin
    ApiDialog(ARequest, AResponse);
    Exit;
  end;
  if p = '/lw/api/dlgfile' then
  begin
    ApiDialogFile(ARequest, AResponse);
    Exit;
  end;
  if p = '/lw/download' then
  begin
    ApiDownload(ARequest, AResponse);
    Exit;
  end;
  if p = '/lw/view' then
  begin
    ApiView(ARequest, AResponse);
    Exit;
  end;
  if p = '/lw/api/close' then
  begin
    FStore.Remove(QueryP(ARequest, 'sid', ''));
    Reply('{"ok":true}', 'application/json; charset=utf-8', 200, AResponse);
    Exit;
  end;

  Reply('404 not found: ' + p, 'text/plain; charset=utf-8', 404, AResponse);
end;

{ ---------------- WebSocket（/lw/ws） ---------------- }

{ 升级判定：Upgrade: websocket 且路径以 /lw/ws 开头 }
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

procedure TLWServer.WSHandlesUpgrade(aRequest: TFPHTTPConnectionRequest;
  var aHandles: Boolean);
begin
  aHandles :=
    SameText(LWReqHeader(aRequest, aRequest.GetHeader(hhUpgrade), 'upgrade'),
      'websocket') and
    (Copy(aRequest.URL, 1, 6) = '/lw/ws');
end;

{ 会话出站指令直推：SessionPushCommand 在 WS 连接线程上同步调用这里
  （对话框指令、Show/Hide/Modal 等都是事件处理过程中产生的） }
procedure TLWServer.HandleRequestError(Sender: TObject; E: Exception);
var
  Benign: Boolean;
begin
  { FPC 3.2.2 的 WebSocket 兼容路径用异常跳出响应流程，不是故障：静默返回 }
  if E is ELWUpgraded then
    Exit;
  { 到这里的异常都是"这一个连接"的问题：最常见是浏览器已经断开/中止了
    请求（关页签、切走、Ext 的请求超时 abort、长轮询被取消），我们这时
    才把响应写下去，socket 已死 -> TStream.WriteBuffer 抛 EWriteError
    （streams.inc:631）。fcl-web 的 TFPHTTPConnection.HandleRequest 捕获
    它、把连接标记为不可 keep-alive 并回收，服务本身完全不受影响。
    只记一行日志：不写日志的话，用户在 IDE 里看到的就是一个吓人的
    异常框，而没有任何线索说明它无害。
    断开类异常是正常现象，措辞降为 [info] 别吓人；其余（真正的服务端
    bug）保留 [warn] 并带上异常详情。 }
    Benign := (E is EWriteError) or (E is EReadError) or
    (Pos('socket', LowerCase(E.ClassName)) > 0) or
    (Pos('conn', LowerCase(E.ClassName)) > 0);
  if Benign then
    LWLog('[info] 客户端已断开，本次请求/响应中止（正常现象，无需处理）——' +
      '常见于浏览器关页签/刷新或请求超时取消；连接已被 fcl-web 自动回收，服务不受影响。')
  else
    LWLog('[warn] 处理请求时出错: ' + E.ClassName + ': ' + E.Message);
end;

procedure TLWServer.WSPushCommand(ASession: TObject; const AJSON: string);
var
  s: TLWSession;
  o: TJSONObject;
  tree: TJSONObject;
begin
  s := ASession as TLWSession;
  if not (s.PushSock is TSocketStream) then Exit;
  { 指令连同当前组件树一起推：show/modal 指令的客户端渲染需要 tree
    （长轮询模式下 tree 是 poll 响应附带的，WS 模式必须随帧给） }
  tree := s.BuildPayload;
  try
    o := TJSONObject(GetJSON(AJSON));
    try
      o.Add('tree', tree);      { fpjson Add 接管 tree 所有权 }
      tree := nil;
      lwwebsocket.WSSendText(TSocketStream(s.PushSock), o.AsJSON);
    finally
      o.Free;
    end;
  finally
    tree.Free;
  end;
end;

{ 升级 + 帧主循环。FPC 3.3.1 的约定：本方法返回后连接被标记
  IsUpgraded 且 FSocket 已置 nil —— socket 所有权移交给本方法，
  循环结束后必须自己 Free（AOwnSocket=True）。
  FPC 3.2.2 走 OnRequest 里的兼容路径，socket 仍归连接对象所有，
  AOwnSocket=False，这里只关不释放。 }
procedure TLWServer.WSUpgrade(aConnection: TFPHTTPConnection;
  aRequest: TFPHTTPConnectionRequest);
begin
  WSRun(aConnection.Socket, aRequest, True);
end;

procedure TLWServer.WSRun(ASock: TSocketStream;
  aRequest: TFPHTTPConnectionRequest; AOwnSocket: Boolean);
var
  sock: TSocketStream;
  key, sid, txt, err, sjson: string;
  op: Byte;
  s: TLWSession;
  body, payload: TJSONObject;
  okconn: Boolean;
  idle: Integer;
  t0, t1, t2, t3: Int64;
begin
  sock := ASock;
  key := Trim(aRequest.CustomHeaders.Values['sec-websocket-key']);
  if (sock = nil) or (key = '') then
    Exit;   { 异常握手：socket 由连接析构兜底释放（两个 FPC 版本都一样） }

  { RFC 6455 握手应答 }
  okconn := lwwebsocket.WSSendRaw(sock,
    'HTTP/1.1 101 Switching Protocols' + #13#10 +
    'Upgrade: websocket' + #13#10 +
    'Connection: Upgrade' + #13#10 +
    'Sec-WebSocket-Accept: ' + lwwebsocket.WSAcceptValue(key) + #13#10 + #13#10);
  if not okconn then
    Exit;

  { 绑定会话：WS 连接期间持有引用，sweeper 不会清理。
    FStore.Find 之后整个循环只在最外层 Release 这一次。 }
  sid := aRequest.QueryFields.Values['sid'];
  s := FStore.Find(sid);
  { 登记到 WS 连接表：停服时要靠它 shutdown 叫醒下面这个读循环 }
  LWWSRegister(sock);
  try
    try
      if s <> nil then
      begin
        s.Touch;
        s.PushSock := sock;
        s.OnPushCommand := @WSPushCommand;
      end;
      { 帧主循环：30s 没帧不是错误 —— 发 ping 保活继续等（浏览器自动回
        pong，下一轮就收到帧把 idle 清零）。连续 ~10 分钟一个帧都没有才
        认定连接已死收掉。旧的 100ms 超时直接断连是"点了没反应"的根因：
        连接活不过 100ms，浏览器 2 秒一重连，事件经常落进死连接里静默丢。 }
      idle := 0;
      while okconn do
      begin
        okconn := lwwebsocket.WSReadFrame(sock, 30000, op, txt);
        if not okconn then
        begin
          if op = Byte(lwwebsocket.WS_IDLE_SENTINEL) then
          begin
            Inc(idle);
            if idle >= 20 then
              Break;   { ~10 分钟无任何帧：连接早没了，收线程 }
            okconn := lwwebsocket.WSSendControl(sock, Byte(lwwebsocket.wsPing));
            Continue;
          end;
          Break;
        end;
        idle := 0;
        if op = Byte(lwwebsocket.wsClose) then
          Break
        else if op = Byte(lwwebsocket.wsPing) then
          okconn := lwwebsocket.WSSendControl(sock, Byte(lwwebsocket.wsPong))
        else if (op = Byte(lwwebsocket.wsText)) or (op = Byte(lwwebsocket.wsBinary)) then
        begin
          { 一帧 = 一个事件请求（与 POST /lw/api/event 的 body 同构） }
          body := nil;
          try
            try
              body := TJSONObject(GetJSON(txt));
            except
              body := nil;
            end;
            if body = nil then
              okconn := lwwebsocket.WSSendText(sock, '{"ok":false,"err":"bad json"}')
            else if s = nil then
              okconn := lwwebsocket.WSSendText(sock, '{"ok":false,"err":"session gone"}')
            else
            begin
              s.Touch;
              err := '';
              LWSetCurrentTab(JGetStr(body, 'tab'));
              { 与 HTTP 事件路径同一把执行锁：WS 帧事件与 HTTP 事件可能
                同时到达（浏览器 WS 重连期间走 HTTP 兜底），必须串行 }
              s.LockExec;
              t0 := LWProfNow;
              try
                payload := LWHandleEvent(s, body, err);
              finally
                t1 := LWProfNow;
                s.UnlockExec;
                LWSetCurrentTab('');
              end;
              try
                if payload = nil then
                  okconn := lwwebsocket.WSSendText(sock,
                    '{"ok":false,"err":' + TJSONString.Create(err).AsJSON + '}')
                else
                begin
                  t2 := LWProfNow;
                  sjson := payload.AsJSON;
                  t3 := LWProfNow;
                  okconn := lwwebsocket.WSSendText(sock, sjson);
                  if LWProfOn then
                    LWProfLog(Format('ws ev=%s id=%d', [JGetStr(body, 'ev'),
                      JGetInt(body, 'id', 0)]),
                      t1 - t0, t3 - t2, LWProfNow - t3, Length(sjson));
                end;
              finally
                payload.Free;
              end;
            end;
          finally
            body.Free;
          end;
          { 事件期间产生的对话框等指令走会话出站队列，
            由各页签的 /lw/api/poll 取走（见 SessionPushCommand） }
        end;
      end;
    finally
      if s <> nil then
      begin
        s.OnPushCommand := nil;
        s.PushSock := nil;
      end;
    end;
  finally
    LWWSUnregister(sock);
    FStore.Release(s);
    if AOwnSocket then
      sock.Free;
  end;
end;

initialization
  InitCriticalSection(GWSLock);
  GWSSocks := TList.Create;

finalization
  FreeAndNil(GWSSocks);
  DoneCriticalSection(GWSLock);

end.
