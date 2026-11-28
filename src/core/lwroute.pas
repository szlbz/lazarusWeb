{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwroute
  ------------------------------------------------------------------
  进程级插件路由：插件是独立 exe（一个完整的 lazarusWeb 服务，自己监听
  自己的端口），主框架把 /p/<插件名>/... 反向代理到对应上游。

  为什么是"独立 exe + HTTP 路由"而不是 DLL：
    - FPC 的 RTL/LCL 静态链接进每个模块，跨 DLL 边界 is 判断恒 False 且
      静默失败（实测见 docs/PLUGIN_FEASIBILITY.md §3）；
    - 进程边界天然跨平台（每个平台编自己的可执行文件）、故障隔离最好；
    - 插件页面就是普通 lazarusWeb 页面：长轮询是唯一推送通道，WebSocket
      只管事件加速且可缺省 —— 所以纯 HTTP 代理就能承载完整交互。
      （WebSocket 经代理暂不透传：前端 WS 连不上会自动回退 POST 事件 +
      长轮询，每 2 秒重试一次，无功能损失，只有约 1KB/2s 的重试流量。）

  配置（主框架 exe 同名 ini，命令行参数优先级更高）：
      plugin.notes=127.0.0.1:8871
      plugin.dashboard=127.0.0.1:8872
  键名 plugin.<插件名>=<host:port>（也可写完整 http://URL，尾部 '/' 剥掉）。

  约定：
    - 浏览器访问 /p/notes/ -> 上游 /（GET /p/notes 补尾斜杠 301，保证
      页面内相对路径解析正确）；
    - 转发时加 X-Forwarded-For / X-Forwarded-Prefix 头；插件的外壳 HTML
      读 X-Forwarded-Prefix 把 /lw/... 资源 URL 生成到 /p/<名>/ 前缀下；
    - 除 /p/ 前缀外不动任何现有路由，没配插件时零开销。
}
unit lwroute;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fphttpserver, httpdefs, httpprotocol,
  fphttpclient, lwbase, lwrlog, lwlang;

type
  { LWRouteDispatch 的结果：handled=True 表示响应已写好（成功或已回错误），
    调用方直接 Exit；False 表示路径不是 /p/ 前缀（调用方继续自己的路由） }
  TLWRouteHandled = (rrNotPlugin, rrDone, rrNoUpstream, rrUpstreamFail);

  { 插件访问鉴权回调（用户权限）。/p/<名>/ 在代理之前调用：
      AName     插件名（清单里的 name=）
      ASid      请求带来的会话标识，可能为 ''（没登录 / cookie 还没落到 /p/ 下）
      AUser     回填登录名，403 页面显示"你是谁"
      AReason   回填拒绝原因（中文，直接显示在 403 页面上）
    返回 True = 放行；False = 回 403，不代理。
    没注册回调（nil）= 不鉴权，行为与旧版完全一致 —— 单机/内网工具不需要
    用户体系的场合零改动、零开销。 }
  TLWRouteAuthFunc = function(const AName, ASid: string;
    out AUser, AReason: string): Boolean;

  { 身份注入回调。鉴权放行后调用，让宿主把"当前是谁"交给插件进程。
     插件是独立进程、有自己的会话表，宿主会话里的 lwuser/lwroles 不会
     自动过去；这里由宿主决定身份并签名，框架只负责把结果放进请求头。
     ASid       同一个请求鉴权时用的会话标识
     AUser      登录名；ARoles 逗号分隔的角色串
     AToken     宿主对 user|roles|ts 的签名（算法由宿主与插件约定）
     ATS        签名时间戳（秒），插件据此判过期
     返回 False = 不注入任何头（未登录或宿主不想传），插件拿不到身份。
     不注册（nil）= 插件完全看不到宿主身份，行为与改动前一致。 }
  TLWRouteIdentityFunc = function(const ASid: string;
    out AUser, ARoles, AToken, ATS: string): Boolean;

{ 注册/取消插件访问鉴权。宿主在 Run 之前调用一次即可（nil = 关闭） }
procedure LWRouteSetAuth(AFunc: TLWRouteAuthFunc);
function LWRouteAuth: TLWRouteAuthFunc;
{ 注册/取消身份注入。宿主在 Run 之前调用一次即可（nil = 不传身份） }
procedure LWRouteSetIdentity(AFunc: TLWRouteIdentityFunc);
function LWRouteIdentity: TLWRouteIdentityFunc;

const
  { 注入到插件请求的头名。插件侧用同名常量读取，不要抄字面量。
    签名头由宿主生成、插件校验；框架不参与密码学，也不解释内容。 }
  LW_ROUTE_IDENTITY_USER_HDR  = 'X-LW-User';
  LW_ROUTE_IDENTITY_ROLES_HDR = 'X-LW-Roles';
  LW_ROUTE_IDENTITY_TOKEN_HDR = 'X-LW-Identity-Token';
  LW_ROUTE_IDENTITY_TS_HDR    = 'X-LW-Identity-Ts';

const
  { 通过鉴权后把会话标识落到这个 Cookie 上（Path 限定 /p/）：
    iframe 的入口请求带 ?sid=，但页面里的子资源请求（/p/名/lw/...、
    /lw/api/event 等）不会再带 query —— 只靠 URL 参数的话，鉴权只拦得住
    第一次导航，后续请求一律"没有 sid"被拒或漏检。Cookie 由浏览器自动
    附加到所有同源 /p/ 请求，正好补上这个缺口。 }
  LW_ROUTE_SID_COOKIE = 'lwpsid';

{ 登记/查询插件。AUpstream 归一化为 'host:port'（剥 http:// 与尾斜杠） }
procedure LWRouteSet(const AName, AUpstream: string);
procedure LWRouteRemove(const AName: string);
function LWRouteGet(const AName: string; out AUpstream: string): Boolean;
{ 逗号分隔的插件名清单（注册表为空返回 ''） }
function LWRouteNames: string;
{ 已登记插件数量。lwhttp 用它决定要不要把 /p/ 当插件前缀拦下来：
  一个插件都没登记的工程（绝大多数）不占用 /p/，原有 /p/xxx 路由照旧走 }
function LWRouteCount: Integer;

{ /p/<名>/<框架静态资源> -> 本地路径（宿主直出）；非框架静态资源返回 ''。
  框架运行时（客户端 JS/CSS、alpine.min.js、favicon、Ext 资源）属于
  非业务功能，由主程序统一直出：升级只换宿主一处、插件部署不用带这些
  文件；插件 exe 只收业务请求（页面外壳、/lw/api/*、/lw/ajax/*、模板） }
function LWRouteStaticLocal(const APath: string): string;

{ 主框架路由入口：APath 是已去掉查询串的请求路径。
  返回 rrDone = 响应已写好；其余情形调用方按语义回 404/502 或继续路由。 }
function LWRouteDispatch(ARequest: TFPHTTPConnectionRequest;
  AResponse: TFPHTTPConnectionResponse; const APath: string): TLWRouteHandled;

implementation

type
  { 插件注册表。读多写少（启动后基本只读），进程闸门保护 }
  TLWRouteTable = class
  private
    FLock: TCriticalSection;
    FItems: TStringList;   { 'name=http://host:port'，name 已小写 }
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetItem(const AName, AUpstream: string);
    procedure RemoveItem(const AName: string);
    function GetItem(const AName: string; out AUpstream: string): Boolean;
    function Names: string;
    function Count: Integer;
  end;

var
  GTable: TLWRouteTable = nil;
  { 鉴权回调：nil = 不做用户权限判断（默认）。宿主注册一个函数即可让
    所有 /p/ 请求先过它 —— 不用登录的工程完全不受影响 }
  GRouteAuth: TLWRouteAuthFunc = nil;
  GRouteIdentity: TLWRouteIdentityFunc = nil;

const
  { 插件路由前缀。这是框架的**保留前缀**：/p/ 归插件（清单自动生成路由），
    /lw/ 归框架自身（协议、运行时、探针、登录）。业务路由不要用它们。
    改这个常量要同步 lwhttp / lwhyper / upluginproc 与客户端拼接处，
    一般不建议改；lwhttp 只在 LWRouteCount > 0 时拦 /p/ }
  LW_PLUGIN_PREFIX = '/p/';

procedure LWRouteSetAuth(AFunc: TLWRouteAuthFunc);
begin
  GRouteAuth := AFunc;
end;

function LWRouteAuth: TLWRouteAuthFunc;
begin
  Result := GRouteAuth;
end;

procedure LWRouteSetIdentity(AFunc: TLWRouteIdentityFunc);
begin
  GRouteIdentity := AFunc;
end;

function LWRouteIdentity: TLWRouteIdentityFunc;
begin
  Result := GRouteIdentity;
end;

function GetTable: TLWRouteTable;
begin
  if GTable = nil then
    GTable := TLWRouteTable.Create;
  Result := GTable;
end;

{ 浏览器请求（Accept 含 text/html）？Accept 走双位置读取：先查 TRequest.Accept
  标准字段（3.3.1 常见头在 Headers 里），查不到再退 CustomHeaders（3.2.2
  未映射头的存放点）—— 与 lwhttp.LWReqHeader 同思路，只看一个位置会漏 }
function WantsHTML(ARequest: TFPHTTPConnectionRequest): Boolean;
var
  acc: string;
begin
  acc := Trim(ARequest.Accept);
  if acc = '' then
    acc := Trim(ARequest.CustomHeaders.Values['Accept']);
  Result := Pos('text/html', LowerCase(acc)) > 0;
end;

{ Cookie 头里取一个键。fcl-web 的 TRequest.Cookies 属性在不同 FPC 版本上
  行为不一致，这里直接解析原始头（与 lwhttp.LWCookieValue 同思路） }
function RouteCookieValue(const ARaw, AName: string): string;
var
  rest, item, k, v: string;
  p: Integer;
begin
  Result := '';
  rest := ARaw;
  while rest <> '' do
  begin
    p := Pos(';', rest);
    if p > 0 then
    begin
      item := Trim(Copy(rest, 1, p - 1));
      rest := Copy(rest, p + 1, MaxInt);
    end
    else
    begin
      item := Trim(rest);
      rest := '';
    end;
    if item = '' then Continue;
    p := Pos('=', item);
    if p <= 0 then Continue;
    k := Trim(Copy(item, 1, p - 1));
    v := Trim(Copy(item, p + 1, MaxInt));
    if SameText(k, AName) then Exit(v);
  end;
end;

{ 原始 Cookie 头：fcl-web 把 "Cookie:" 映射成 TRequest.Cookie 属性，
  不一定留在 CustomHeaders 里 —— 只读 CustomHeaders 会拿到空串，
  表现就是"浏览器明明发了 cookie，服务端硬是看不见" }
function RouteRawCookie(ARequest: TFPHTTPConnectionRequest): string;
begin
  Result := Trim(ARequest.Cookie);
  if Result = '' then
    Result := Trim(ARequest.GetCustomHeader('Cookie'));
end;

{ 本次请求的会话标识。三处都看：
    - ?sid=  宿主序列化 iframe HTML 时拼进 URL（首次导航靠它）；
    - 头     API / 脚本调用自己带；
    - cookie iframe 页面里的子资源请求由浏览器自动附加。
  cookie 名带 lwp 前缀且 Path=/p/，与宿主自身的 sid 传递互不干扰。

  顺序按请求类型分：
    - 页面导航（/p/名/）：?sid= > 头 > cookie。首次进来还没有 cookie，
      必须靠宿主拼在 iframe URL 上的 sid。
    - 插件内部 /lw/*（API、静态资源、长轮询、WS）：头 > cookie > ?sid=。
      这些请求的 ?sid= 是**插件自己 session 的 sid**，宿主会话库里根本没有；
      之前一律让 query 优先，导致每次轮询都 403、日志刷屏（页面看着
      还正常，因为事件 POST 的 sid 在 body 里、靠 cookie 放行）。
      cookie 是宿主放行导航时下发的，才是这类请求该用的宿主 sid。 }
function RouteReqSid(ARequest: TFPHTTPConnectionRequest;
  const ARest: string): string;
var
  qs, hd, ck: string;
begin
  if Assigned(ARequest.QueryFields) then
    qs := Trim(ARequest.QueryFields.Values['sid'])
  else
    qs := '';
  hd := Trim(ARequest.GetCustomHeader('X-LW-Sid'));
  ck := RouteCookieValue(RouteRawCookie(ARequest), LW_ROUTE_SID_COOKIE);

  if Copy(ARest, 1, 4) = '/lw/' then
  begin
    Result := hd;
    if Result = '' then Result := ck;
    if Result = '' then Result := qs;
  end
  else
  begin
    Result := qs;
    if Result = '' then Result := hd;
    if Result = '' then Result := ck;
  end;
end;

{ 403：鉴权回调拒绝。浏览器请求给人看的页面（说明是谁、为什么、怎么办），
  程序调用给 JSON —— 与 502 页同样的分流逻辑 }
procedure RouteForbidden(ARequest: TFPHTTPConnectionRequest;
  AResponse: TFPHTTPConnectionResponse;
  const AName, AUser, AReason: string);

  function Esc(const S: string): string;
  begin
    Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
    Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
    Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
    Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
  end;

var
  who: string;
begin
  AResponse.Code := 403;
  AResponse.CodeText := 'Forbidden';
  if AUser = '' then
    who := '未登录（或会话已过期）'
  else
    who := '当前用户：' + AUser;

  if WantsHTML(ARequest) then
  begin
    AResponse.ContentType := 'text/html; charset=utf-8';
    AResponse.Content :=
      '<!DOCTYPE html><html lang="' + LWLangGet + '"><head><meta charset="utf-8">' +
      '<title>无权访问: ' + Esc(AName) + '</title></head><body ' +
      'style="font-family:sans-serif;background:#1e1e1e;color:#ddd;' +
      'margin:0;padding:48px 24px">' +
      '<h2 style="color:#f6a623;margin:0 0 16px">无权访问插件「' + Esc(AName) + '」</h2>' +
      '<p>' + Esc(AReason) + '</p>' +
      '<p style="color:#aaa">' + Esc(who) + '</p>' +
      '<p><a href="/" style="color:#6cf">返回工作台</a>' +
      '　<span style="color:#666">用有权限的账号重新登录后再打开本插件</span></p>' +
      '<p style="color:#777;font-size:13px">插件访问权限在插件清单 ' +
      '<code>' + Esc(AName) + '.plugin.ini</code> 的 <code>roles=</code> 行配置；' +
      '不写 roles= 表示所有已登录用户都可访问。</p>' +
      '</body></html>';
  end
  else
  begin
    AResponse.ContentType := 'application/json; charset=utf-8';
    AResponse.Content := '{"ok":false,"err":"forbidden","plugin":"' +
      Esc(AName) + '","user":"' + Esc(AUser) + '"}';
  end;
end;

{ hop-by-hop 头：代理必须剥掉（RFC 7230 6.1）+ 由两端各自生成的头。
  与 lwhyper.IsHopByHop 同语义（那边是实现段私有，这边独立成套） }
function IsHopByHop(const AName: string): Boolean;
begin
  Result :=
    SameText(AName, 'connection') or SameText(AName, 'keep-alive') or
    SameText(AName, 'transfer-encoding') or SameText(AName, 'te') or
    SameText(AName, 'trailer') or SameText(AName, 'upgrade') or
    SameText(AName, 'proxy-connection') or SameText(AName, 'expect') or
    SameText(AName, 'host') or SameText(AName, 'content-length');
end;

{ 插件名只放行 URL 安全字符（注册表键与 URL 段共用） }
function ValidPluginName(const AName: string): Boolean;
var
  i: Integer;
  c: Char;
begin
  Result := False;
  if (Length(AName) < 1) or (Length(AName) > 64) then Exit;
  for i := 1 to Length(AName) do
  begin
    c := AName[i];
    if not ( ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
             ((c >= '0') and (c <= '9')) or (c = '-') or (c = '_') or (c = '.') ) then
      Exit;
  end;
  Result := True;
end;

{ 'http://127.0.0.1:8871/' -> '127.0.0.1:8871'；'127.0.0.1:8871' 原样 }
function NormUpstream(const AValue: string): string;
var
  v: string;
begin
  Result := '';
  v := Trim(AValue);
  if v = '' then Exit;
  if Copy(LowerCase(v), 1, 7) = 'http://' then
    Delete(v, 1, 7)
  else if Copy(LowerCase(v), 1, 8) = 'https://' then
  begin
    LWLog('警告: 插件上游不支持 https://（进程间走本机/内网 HTTP），剥掉协议: ' + v);
    Delete(v, 1, 8);
  end;
  while (Length(v) > 0) and ((v[Length(v)] = '/') or (v[Length(v)] = '\')) do
    Delete(v, Length(v), 1);
  if v = '' then Exit;
  Result := v;
end;

{ ---------------- TLWRouteTable ---------------- }

constructor TLWRouteTable.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FItems := TStringList.Create;
  FItems.NameValueSeparator := '=';
end;

destructor TLWRouteTable.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TLWRouteTable.SetItem(const AName, AUpstream: string);
var
  k: string;
  idx: Integer;
begin
  k := LowerCase(AName);
  FLock.Enter;
  try
    idx := FItems.IndexOfName(k);
    if idx >= 0 then
      FItems[idx] := k + '=' + AUpstream
    else
      FItems.Add(k + '=' + AUpstream);
  finally
    FLock.Leave;
  end;
end;

procedure TLWRouteTable.RemoveItem(const AName: string);
var
  k: string;
  idx: Integer;
begin
  k := LowerCase(AName);
  FLock.Enter;
  try
    { 不要在持锁状态下调 GetItem —— 它也会加锁，Linux 的 pthread 互斥量
      不可重入，嵌套加锁直接死锁 }
    idx := FItems.IndexOfName(k);
    if idx >= 0 then
      FItems.Delete(idx);
  finally
    FLock.Leave;
  end;
end;

function TLWRouteTable.GetItem(const AName: string; out AUpstream: string): Boolean;
var
  k, v: string;
  idx: Integer;
begin
  Result := False;
  AUpstream := '';
  k := LowerCase(AName);
  FLock.Enter;
  try
    idx := FItems.IndexOfName(k);
    if idx >= 0 then
    begin
      v := FItems.ValueFromIndex[idx];
      if v <> '' then
      begin
        AUpstream := v;
        Result := True;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TLWRouteTable.Names: string;
var
  i: Integer;
begin
  Result := '';
  FLock.Enter;
  try
    for i := 0 to FItems.Count - 1 do
    begin
      if Result <> '' then Result := Result + ',';
      Result := Result + FItems.Names[i];
    end;
  finally
    FLock.Leave;
  end;
end;

function TLWRouteTable.Count: Integer;
begin
  FLock.Enter;
  try
    Result := FItems.Count;
  finally
    FLock.Leave;
  end;
end;

{ ---------------- 公开 API ---------------- }

procedure LWRouteSet(const AName, AUpstream: string);
var
  up: string;
begin
  if not ValidPluginName(AName) then
  begin
    LWLog('警告: 插件名非法（只允许字母数字 .-_，1..64 位）: ' + AName);
    Exit;
  end;
  up := NormUpstream(AUpstream);
  if up = '' then
  begin
    LWLog('警告: 插件上游为空，忽略: ' + AName);
    Exit;
  end;
  GetTable.SetItem(AName, up);
  LWLog('插件路由: /p/' + AName + '/ -> http://' + up + '/');
end;

procedure LWRouteRemove(const AName: string);
begin
  GetTable.RemoveItem(AName);
end;

function LWRouteGet(const AName: string; out AUpstream: string): Boolean;
begin
  Result := GetTable.GetItem(AName, AUpstream);
end;

function LWRouteNames: string;
begin
  Result := GetTable.Names;
end;

function LWRouteCount: Integer;
begin
  { 没登记过插件时不要为了数 0 去建表：这里每个 /p/ 请求都会问一次，
    顺手也免掉"首次并发建表"的竞态 }
  if GTable = nil then Exit(0);
  Result := GTable.Count;
end;

{ 框架静态资源白名单：宿主直出，不进插件（非业务功能由主程序处理）。
  会话绑定类端点（/lw/api/*、/lw/ajax/*、验证码、/lw/tpl/ 模板）不在
  此列 —— 状态在插件会话里，必须代理回插件 }
function LWRouteStaticLocal(const APath: string): string;
const
  STATIC_ASSETS: array[0..9] of string = (
    '/lw/lw.js', '/lw/lw.css', '/lw/lw-alpine.js', '/lw/lw-alpine.css',
    '/lw/alpine.min.js', '/lw/manifest.webmanifest', '/lw/sw.js',
    '/lw/pwa.js', '/lw/icon-192.png', '/lw/icon-512.png');
var
  rest: string;
  slash, i: Integer;
begin
  Result := '';
  if Copy(APath, 1, Length(LW_PLUGIN_PREFIX)) <> LW_PLUGIN_PREFIX then
    Exit;
  rest := Copy(APath, Length(LW_PLUGIN_PREFIX) + 1, MaxInt);
  slash := Pos('/', rest);
  if slash <= 0 then
    Exit;                                    { /p/<名> 无尾斜杠：交给代理补 301 }
  rest := Copy(rest, slash, MaxInt);         { 含开头 '/' }
  if rest = '/favicon.ico' then
    Exit('/favicon.ico');
  if Copy(rest, 1, 5) = '/ext/' then
    Exit(rest);
  { PWA 端点由宿主直出：订阅/消息状态属于宿主进程，不能转发给插件 worker }
  if Copy(rest, 1, 8) = '/lw/pwa/' then
    Exit(rest);
  for i := Low(STATIC_ASSETS) to High(STATIC_ASSETS) do
    if rest = STATIC_ASSETS[i] then
      Exit(rest);
end;

{ 反向代理：把 ARequest 原样转发到 http://AUpstream+AUpPath（含查询串），
  响应搬运回 AResponse。写法与 lwhyper.ProxyHTTP 同源：
  头/体透传、hop-by-hop 剥离、请求体原始字节不动（multipart 二进制安全）。 }
function IsIdentityHeader(const AName: string): Boolean;
begin
  Result := SameText(AName, LW_ROUTE_IDENTITY_USER_HDR) or
            SameText(AName, LW_ROUTE_IDENTITY_ROLES_HDR) or
            SameText(AName, LW_ROUTE_IDENTITY_TOKEN_HDR) or
            SameText(AName, LW_ROUTE_IDENTITY_TS_HDR);
end;

function ProxyTo(ARequest: TFPHTTPConnectionRequest;
  AResponse: TFPHTTPConnectionResponse;
  const AUpstream, AUpPath, AForwardedPrefix: string;
  const AIdUser, AIdRoles, AIdToken, AIdTs: string): Boolean;
var
  clt: TFPHTTPClient;
  body, ms: TMemoryStream;
  i, n, q: Integer;
  name, val, ct: string;
  url: string;
begin
  Result := False;
  clt := TFPHTTPClient.Create(nil);
  body := nil;
  ms := TMemoryStream.Create;
  try
    clt.AllowRedirect := False;
    { Windows 上 connection refused 被当超时处理，缺省烧 3 秒 ——
      本机转发 connect 毫秒级完成，1 秒足够宽裕 }
    clt.ConnectTimeout := 1000;
    { 长轮询 /lw/api/poll 服务端最多挂 20s（LW_POLL_MS），30s 宽裕 }
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
    clt.RequestHeaders.Values['X-Forwarded-Prefix'] := AForwardedPrefix;

    { 身份头一律由宿主签发：先删掉客户端自带的同名头，再写入宿主的值。
      只"追加"等于给伪造开后门 —— 浏览器自己发一个 X-LW-User: admin
      就能在插件里冒充管理员。没签发（AIdUser=''）时也会删干净，
      插件读到空身份，而不是上一次请求残留的值 }
    for i := clt.RequestHeaders.Count - 1 downto 0 do
      if IsIdentityHeader(clt.RequestHeaders.Names[i]) then
        clt.RequestHeaders.Delete(i);
    if AIdUser <> '' then
    begin
      clt.RequestHeaders.Values[LW_ROUTE_IDENTITY_USER_HDR] := AIdUser;
      clt.RequestHeaders.Values[LW_ROUTE_IDENTITY_ROLES_HDR] := AIdRoles;
      clt.RequestHeaders.Values[LW_ROUTE_IDENTITY_TOKEN_HDR] := AIdToken;
      clt.RequestHeaders.Values[LW_ROUTE_IDENTITY_TS_HDR] := AIdTs;
    end;

    { 请求体透传（原始字节）。3.3.1 在 ContentBytes，3.2.2 在 Content }
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

    url := 'http://' + AUpstream + AUpPath;
    { query string 必须透传：Route 为匹配路径把 ?... 去掉了，但 poll/tree/ajax
      全靠 query 传 sid/t/after/form —— 丢了上游 Find('')=nil 就回 gone，
      前端 forgetSid+boot 反复重建，表现为"会话已过期"无限闪 }
    q := Pos('?', ARequest.URL);
    if q > 0 then
      url := url + Copy(ARequest.URL, q, MaxInt);   { 含开头 '?' }
    try
      clt.HTTPMethod(ARequest.Method, url, ms, []);
    except
      on E: Exception do
      begin
        LWLog('[route] ' + url + ' 转发失败: ' + E.Message);
        FreeAndNil(ms);
        Exit;
      end;
    end;
    Result := True;   { 上游已应答，后续只是搬运 }

    { 响应头透传（剥 hop-by-hop 与 fphttpserver 自己生成的头）。
      content-length 不抄：ContentStream 赋值时框架自动按流大小设置 }
    AResponse.Code := clt.ResponseStatusCode;
    {$IF FPC_FULLVERSION >= 30301}
    AResponse.CodeText := GetHTTPStatusText(clt.ResponseStatusCode);
    {$ELSE}
    AResponse.CodeText := LWHTTPStatusText(clt.ResponseStatusCode);
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

function LWRouteDispatch(ARequest: TFPHTTPConnectionRequest;
  AResponse: TFPHTTPConnectionResponse; const APath: string): TLWRouteHandled;
var
  rest, name, up, prefix, sid, auser, areason, qs: string;
  iduser, idroles, idtoken, idts: string;
  slash, qp: Integer;
begin
  Result := rrNotPlugin;
  if Copy(APath, 1, Length(LW_PLUGIN_PREFIX)) <> LW_PLUGIN_PREFIX then
    Exit;

  rest := Copy(APath, Length(LW_PLUGIN_PREFIX) + 1, MaxInt);
  slash := Pos('/', rest);
  if slash > 0 then
  begin
    name := Copy(rest, 1, slash - 1);
    rest := Copy(rest, slash, MaxInt);          { 含开头 '/' }
  end
  else
  begin
    name := rest;
    rest := '/';                                 { /p/notes -> 上游 / }
  end;

  if not ValidPluginName(name) then
  begin
    AResponse.Code := 404;
    AResponse.CodeText := 'Not Found';
    AResponse.ContentType := 'text/plain; charset=utf-8';
    AResponse.Content := '404 invalid plugin name';
    Result := rrDone;
    Exit;
  end;
  if not LWRouteGet(name, up) then
  begin
    AResponse.Code := 404;
    AResponse.CodeText := 'Not Found';
    if WantsHTML(ARequest) then
    begin
      AResponse.ContentType := 'text/html; charset=utf-8';
      AResponse.Content :=
        '<!DOCTYPE html><html><head><meta charset="utf-8">' +
        '<title>未登记插件: ' + name + '</title></head><body ' +
        'style="font-family:sans-serif;background:#1e1e1e;color:#ddd;' +
        'margin:0;padding:48px 24px">' +
        '<h2 style="color:#f66;margin:0 0 16px">没有名为「' + name + '」的插件</h2>' +
        '<p>宿主 ini 里加一行 <code>plugin.' + name + '=host:port</code> 指向该' +
        '插件 exe 的监听地址，然后重启宿主。已登记：' + LWRouteNames + '</p>' +
        '</body></html>';
    end
    else
    begin
      AResponse.ContentType := 'text/plain; charset=utf-8';
      AResponse.Content := '404 no plugin named "' + name +
        '"（主框架 ini 里加 plugin.' + name + '=host:port 后重启）';
    end;
    Result := rrNoUpstream;
    Exit;
  end;

  { 用户权限：/p/ 是插件唯一的对外门，鉴权必须在这里做 —— 只靠宿主菜单
    隐藏不够，直接敲 URL、转发页面链接、iframe 里的子资源请求都会绕过 UI。
    回调由宿主用 LWRouteSetAuth 注册；没注册就一律放行（旧行为） }
  sid := RouteReqSid(ARequest, rest);
  if Assigned(GRouteAuth) then
  begin
    auser := '';
    areason := '';
    if not GRouteAuth(name, sid, auser, areason) then
    begin
      { 日志带上真实子路径：以前固定写 /p/<名>/，分不清是页面导航
        还是 iframe 里的 /lw/api/poll 被拒，排障时白费一轮 }
      LWLog('[route] 拒绝 ' + APath + ' sid=' + sid + '：' + areason);
      RouteForbidden(ARequest, AResponse, name, auser, areason);
      Result := rrDone;
      Exit;
    end;
    { 放行后把 sid 落到 /p/ 下的 HttpOnly cookie：iframe 页面里的子资源
      请求（相对路径、/lw/api/*、静态资源）不会带 query，只靠 URL 参数
      鉴权只拦得住第一次导航。已经一致就不重复下发。
      必须走 AResponse.Cookies（TCookie），不能 CustomHeaders.Add
      'Set-Cookie: name=value' —— TStringList 以 '=' 作 NameValueSeparator，
      会被拆成 Name='Set-Cookie: name'、Value='value'，发出去变成
      "Set-Cookie: name: value"，浏览器直接忽略（lwhttp.SetLangCookie 同坑） }
    if (sid <> '') and
       (RouteCookieValue(RouteRawCookie(ARequest), LW_ROUTE_SID_COOKIE) <> sid) then
      with AResponse.Cookies.Add do
      begin
        Name := LW_ROUTE_SID_COOKIE;
        Value := sid;
        Path := LW_PLUGIN_PREFIX;
        HttpOnly := True;
        SameSite := ssLax;
      end;
  end;

  { 身份注入：鉴权通过后让宿主签发身份，随这个请求带给插件进程。
    和鉴权是两件事 —— 只注册 identity 不注册 auth 也行（只传身份不拦问）。
    回调返回 False 或字段为空时，ProxyTo 会清掉同名头，插件读不到身份 }
  iduser := '';
  idroles := '';
  idtoken := '';
  idts := '';
  if Assigned(GRouteIdentity) then
    GRouteIdentity(sid, iduser, idroles, idtoken, idts);

  { /p/notes（无尾斜杠）补 301：页面内相对路径（BASE 推导）依赖尾斜杠。
    原 query 一定要带上 —— 首次导航的 ?sid= 丢了就只能靠 cookie，
    而这时浏览器手里还没有 cookie }
  if (rest = '/') and (APath = LW_PLUGIN_PREFIX + name) then
  begin
    qs := '';
    qp := Pos('?', ARequest.URL);
    if qp > 0 then
      qs := Copy(ARequest.URL, qp, MaxInt);
    AResponse.Code := 301;
    AResponse.CodeText := 'Moved Permanently';
    AResponse.SetCustomHeader('Location', LW_PLUGIN_PREFIX + name + '/' + qs);
    AResponse.Content := '';
    Result := rrDone;
    Exit;
  end;

  prefix := LW_PLUGIN_PREFIX + name + '/';
  if ProxyTo(ARequest, AResponse, up, rest, prefix,
     iduser, idroles, idtoken, idts) then
    Result := rrDone
  else
  begin
    { 上游连不上（最常见：插件 exe 没启动）。浏览器请求（Accept 含
      text/html）回人可读的 HTML 错误页，API/程序调用仍回 JSON ——
      裸 JSON 在浏览器页签里就是一行代码，运维不知道该干什么 }
    AResponse.Code := 502;
    AResponse.CodeText := 'Bad Gateway';
    if WantsHTML(ARequest) then
    begin
      AResponse.ContentType := 'text/html; charset=utf-8';
      AResponse.Content :=
        '<!DOCTYPE html><html lang="' + LWLangGet + '"><head><meta charset="utf-8">' +
        '<title>' + LWLangText('插件不可达') + ': ' + name + '</title></head><body ' +
        'style="font-family:sans-serif;background:#1e1e1e;color:#ddd;' +
        'margin:0;padding:48px 24px">' +
        '<h2 style="color:#f66;margin:0 0 16px">' +
        LWLangText('插件「') + name + LWLangText('」未启动或不可达') + '</h2>' +
        '<p>' + LWLangText('宿主已按登记把本页代理到') + ' <code>' + up + '</code>' +
        LWLangText('，但连接失败。') + '</p>' +
        '<p>' + LWLangText('最常见原因：') + '<b>' +
        LWLangText('插件 exe 没有运行') + '</b>' + LWLangText('（或正在重启）。请启动对应插件程序后') +
        '<a href="" onclick="location.reload();return false" ' +
        'style="color:#6cf">' + LWLangText('刷新本页') + '</a>。</p>' +
        '<p style="color:#999;font-size:13px">' + LWLangText('宿主 ini 键：') +
        'plugin.' + name + '=' + up + '</p></body></html>';
    end
    else
    begin
      AResponse.ContentType := 'application/json; charset=utf-8';
      AResponse.Content := '{"ok":false,"err":"plugin unreachable: ' + name + '"}';
    end;
    Result := rrUpstreamFail;
  end;
end;

finalization
  FreeAndNil(GTable);
end.
