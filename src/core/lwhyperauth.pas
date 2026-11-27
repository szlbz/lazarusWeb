{
  lazarusWeb :: lwhyper 插件模式的登录 / 会话（宿主自带鉴权入口）

  背景：lwroute 的 /p/ 鉴权只认「sid -> 用户/角色」这个查询回调，它不关心
  sid 是谁发的。插件模式以前没有登录，于是 /p/ 只能匿名放行 —— 谁敲 URL
  谁就进。本单元补上这一层：用户表、登录口令校验、会话令牌、Cookie 读写。

  设计取舍：
    - 会话在内存里（lwhyper 自己就是单进程宿主，重启即全员重新登录），
      不写盘也不依赖任何外部存储，demo 拿到就能跑；
    - Cookie 名沿用 lwroute 的 LW_ROUTE_SID_COOKIE（lwpsid）。这样浏览器
      打开 /p/<名>/ 时，lwroute 的 RouteReqSid 从 cookie 里取到的就是本单元
      发的会话令牌，鉴权回调直接查得动，不需要在 iframe 上手工拼 ?sid=；
    - 口令支持明文（demo）与 pass-sha1=（正式环境别存明文）；
    - 单实例全局 GHyperAuth 只为让 lwroute 的普通函数指针回调能用：
      TLWPluginIdentityLookup 是 function 类型，不接受方法指针。
}
unit lwhyperauth;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, IniFiles, DateUtils, fphttpserver, httpdefs, sha1,
  lwrlog, lwpluginauth, lwroute;

const
  { 会话 Cookie：与 lwroute 的 /p/ 路由共用同一个名字，见上面说明 }
  HYPER_SID_COOKIE = LW_ROUTE_SID_COOKIE;
  { 缺省空闲超时（分钟）：超过这么久没有任何请求就要求重新登录 }
  HYPER_SESSION_MIN = 480;
  { 口令/用户名的最大长度：超长输入直接拒，不浪费哈希 }
  HYPER_MAX_FIELD = 128;

type
  TLWHyperUser = record
    User: string;
    Pass: string;      { pass= 明文 }
    PassSha1: string;  { pass-sha1= 十六进制；非空时优先 }
    Roles: string;
    Display: string;
  end;

  TLWHyperSession = class
  public
    Token: string;
    User: string;
    Roles: string;
    Display: string;
    Last: TDateTime;   { 最近一次访问时间，用于空闲超时 }
  end;

  TLWHyperAuth = class
  private
    FLock: TRTLCriticalSection;
    FUsers: array of TLWHyperUser;
    FSessions: TStringList;   { Token -> TLWHyperSession，Sorted }
    FTTLMin: Integer;
    FUsersFile: string;
    function FindUser(const AUser: string; out AIndex: Integer): Boolean;
    function NewToken: string;
    procedure PurgeExpired;
    function SessionOf(const AToken: string): TLWHyperSession;
    procedure DropAll;
  public
    constructor Create(ATTLMin: Integer);
    destructor Destroy; override;
    { 读用户表。每个 [用户名] 一节：pass= / pass-sha1= / roles= / display=
      返回 False 时 AErr 是给人看的原因（文件缺失 / 一个用户都没有） }
    function LoadUsers(const AFile: string; out AErr: string): Boolean;
    { 校验口令；成功回填角色与中文名 }
    function CheckPassword(const AUser, APass: string;
      out ARoles, ADisplay: string): Boolean;
    { 校验通过后建会话，返回令牌 }
    function Login(const AUser, APass: string;
      out AToken, ARoles, ADisplay, AErr: string): Boolean;
    { 令牌是否有效；有效则续期并回填身份 }
    function Validate(const AToken: string;
      out AUser, ARoles, ADisplay: string): Boolean;
    procedure Logout(const AToken: string);
    function UserCount: Integer;
    function SessionCount: Integer;
    function UserNames: string;   { 逗号分隔，给登录页提示用 }
    property TTLMin: Integer read FTTLMin;
    property UsersFile: string read FUsersFile;
  end;

var
  { 当前进程的鉴权实例。lwroute 的回调是普通函数指针，只能通过全局取 }
  GHyperAuth: TLWHyperAuth = nil;

{ lwroute 的 sid -> 身份查询：直接查 lwhyper 自己的会话表 }
function HyperAuthLookup(const ASid: string;
  out AUser, ARoles: string): Boolean;

{ ---------------- Cookie / 请求辅助 ---------------- }

{ 从原始 Cookie 头里取一个键（fcl-web 的 Cookies 属性各版本行为不一致） }
function HyperCookieValue(const ARawCookie, AName: string): string;
function HyperRawCookie(ARequest: TFPHTTPConnectionRequest): string;
{ 读请求带来的会话令牌：?sid= > X-LW-Sid > Cookie（与 lwroute 导航同序） }
function HyperRequestToken(ARequest: TFPHTTPConnectionRequest): string;

procedure HyperSetCookie(var AResponse: TFPHTTPConnectionResponse;
  const AName, AValue, APath: string; AMaxAgeSec: Integer);
procedure HyperClearCookie(var AResponse: TFPHTTPConnectionResponse;
  const AName, APath: string);

{ 取当前请求的会话身份；未登录返回 False }
function HyperAuthOf(AAuth: TLWHyperAuth; ARequest: TFPHTTPConnectionRequest;
  out AUser, ARoles, ADisplay, AToken: string): Boolean;

implementation

{ ---------------- 小工具 ---------------- }

function FixedEq(const A, B: string): Boolean;
var
  i, n: Integer;
  d: Byte;
begin
  { 长度不等也走完整循环：别用提前 return 泄露"前几位对不对" }
  n := Length(A);
  if Length(B) > n then n := Length(B);
  d := Byte(Length(A) <> Length(B));
  for i := 1 to n do
  begin
    if i <= Length(A) then d := d or (Byte(A[i]) xor Byte(B[i]))
    else d := d or Byte(B[i]);
  end;
  Result := d = 0;
end;

function Sha1Hex(const S: string): string;
begin
  Result := LowerCase(SHA1Print(SHA1String(S)));
end;

function HyperCookieValue(const ARawCookie, AName: string): string;
var
  s, item, k, v: string;
  p: Integer;
begin
  Result := '';
  s := ARawCookie;
  while s <> '' do
  begin
    p := Pos(';', s);
    if p > 0 then
    begin
      item := Trim(Copy(s, 1, p - 1));
      s := Copy(s, p + 1, MaxInt);
    end
    else
    begin
      item := Trim(s);
      s := '';
    end;
    if item = '' then Continue;
    p := Pos('=', item);
    if p <= 0 then Continue;
    k := Trim(Copy(item, 1, p - 1));
    v := Trim(Copy(item, p + 1, MaxInt));
    if SameText(k, AName) then Exit(v);
  end;
end;

function HyperRawCookie(ARequest: TFPHTTPConnectionRequest): string;
begin
  Result := Trim(ARequest.Cookie);
  if Result = '' then
    Result := Trim(ARequest.GetCustomHeader('Cookie'));
end;

function HyperRequestToken(ARequest: TFPHTTPConnectionRequest): string;
begin
  Result := '';
  if Assigned(ARequest.QueryFields) then
    Result := Trim(ARequest.QueryFields.Values['sid']);
  if Result = '' then
    Result := Trim(ARequest.GetCustomHeader('X-LW-Sid'));
  if Result = '' then
    Result := HyperCookieValue(HyperRawCookie(ARequest), HYPER_SID_COOKIE);
end;

procedure HyperSetCookie(var AResponse: TFPHTTPConnectionResponse;
  const AName, AValue, APath: string; AMaxAgeSec: Integer);
begin
  { 必须走 AResponse.Cookies（TCookie）：TStringList 以 '=' 作分隔符，
    手写 'Set-Cookie: k=v' 会被拆坏（lwroute 里同一处坑有详细注释） }
  with AResponse.Cookies.Add do
  begin
    Name := AName;
    Value := AValue;
    Path := APath;
    HttpOnly := True;
    SameSite := ssLax;
    if AMaxAgeSec > 0 then
      Expires := Now + (AMaxAgeSec / 86400)
    else
      Expires := Now - 1;   { <=0 表示立即失效 }
  end;
end;

procedure HyperClearCookie(var AResponse: TFPHTTPConnectionResponse;
  const AName, APath: string);
begin
  HyperSetCookie(AResponse, AName, '', APath, 0);
end;

{ ---------------- TLWHyperAuth ---------------- }

constructor TLWHyperAuth.Create(ATTLMin: Integer);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FSessions := TStringList.Create;
  FSessions.Sorted := True;
  FSessions.Duplicates := dupIgnore;
  FTTLMin := ATTLMin;
  if FTTLMin < 1 then FTTLMin := HYPER_SESSION_MIN;
end;

destructor TLWHyperAuth.Destroy;
begin
  DropAll;
  FSessions.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TLWHyperAuth.DropAll;
var
  i: Integer;
begin
  for i := 0 to FSessions.Count - 1 do
    FSessions.Objects[i].Free;
  FSessions.Clear;
end;

function TLWHyperAuth.UserCount: Integer;
begin
  Result := Length(FUsers);
end;

function TLWHyperAuth.SessionCount: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FSessions.Count;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLWHyperAuth.UserNames: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(FUsers) do
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + FUsers[i].User;
  end;
end;

function TLWHyperAuth.LoadUsers(const AFile: string; out AErr: string): Boolean;
var
  ini: TIniFile;
  secs: TStringList;
  i, n: Integer;
  u: TLWHyperUser;
begin
  Result := False;
  AErr := '';
  FUsersFile := AFile;
  if Trim(AFile) = '' then
  begin
    AErr := '没有指定用户表（--users=路径）';
    Exit;
  end;
  if not FileExists(AFile) then
  begin
    AErr := '用户表不存在: ' + AFile;
    Exit;
  end;

  secs := TStringList.Create;
  try
    ini := TIniFile.Create(AFile);
    try
      ini.ReadSections(secs);
      SetLength(FUsers, 0);
      for i := 0 to secs.Count - 1 do
      begin
        if Trim(secs[i]) = '' then Continue;
        if SameText(secs[i], 'auth') then Continue;   { 保留节，不当用户 }
        u.User := Trim(secs[i]);
        u.Pass := ini.ReadString(secs[i], 'pass', '');
        u.PassSha1 := LowerCase(Trim(ini.ReadString(secs[i], 'pass-sha1', '')));
        u.Roles := Trim(ini.ReadString(secs[i], 'roles', ''));
        u.Display := Trim(ini.ReadString(secs[i], 'display', ''));
        if u.Display = '' then u.Display := u.User;
        { 口令两种都没写 = 这个账号根本没法登录，直接跳过并留日志 }
        if (u.Pass = '') and (u.PassSha1 = '') then
        begin
          LWLog('[hyper-auth] 用户 ' + u.User + ' 没有配置口令，已忽略');
          Continue;
        end;
        if u.Roles = '' then
        begin
          LWLog('[hyper-auth] 用户 ' + u.User + ' 没有角色，登录后打不开任何插件');
        end;
        n := Length(FUsers);
        SetLength(FUsers, n + 1);
        FUsers[n] := u;
      end;
    finally
      ini.Free;
    end;
  finally
    secs.Free;
  end;

  if Length(FUsers) = 0 then
  begin
    AErr := '用户表里没有任何可用账号（每节 [用户名] 需要 pass= 或 pass-sha1=）: ' + AFile;
    Exit;
  end;
  LWLogFmt('[hyper-auth] 用户表 %s：%d 个账号', [AFile, Length(FUsers)]);
  Result := True;
end;

function TLWHyperAuth.FindUser(const AUser: string; out AIndex: Integer): Boolean;
var
  i: Integer;
begin
  AIndex := -1;
  for i := 0 to High(FUsers) do
    if SameText(FUsers[i].User, AUser) then
    begin
      AIndex := i;
      Exit(True);
    end;
  Result := False;
end;

function TLWHyperAuth.CheckPassword(const AUser, APass: string;
  out ARoles, ADisplay: string): Boolean;
var
  i, dummy: Integer;
  u: TLWHyperUser;
  ok: Boolean;
begin
  ARoles := '';
  ADisplay := '';
  Result := False;
  if (AUser = '') or (APass = '') then Exit;
  if (Length(AUser) > HYPER_MAX_FIELD) or (Length(APass) > HYPER_MAX_FIELD) then Exit;

  if not FindUser(Trim(AUser), i) then
  begin
    { 账号不存在也要走一次哈希：响应时间别把"用户存在与否"泄露出去 }
    dummy := 0;
    if dummy = 0 then
      Sha1Hex(APass);
    Exit;
  end;

  u := FUsers[i];
  if u.PassSha1 <> '' then
    ok := FixedEq(Sha1Hex(APass), u.PassSha1)
  else
    ok := FixedEq(APass, u.Pass);

  if not ok then Exit;
  ARoles := u.Roles;
  ADisplay := u.Display;
  Result := True;
end;

function TLWHyperAuth.NewToken: string;
var
  i: Integer;
begin
  { 32 字节十六进制。Random 已在 TLWHyperServer 构造时 Randomize 过，
    这里再掺入时间和计数器，避免同一毫秒内重复 }
  Result := '';
  { 8 段 x 8 位十六进制 = 32 字符。Random(MaxInt) 每次约 31 bit 熵，
    再掺一个自增计数避免极端情况下撞车（撞了也会被 Login 里的重试挡住） }
  for i := 1 to 8 do
    Result := Result + IntToHex(Int64(Random(2000000000)), 8);
  Result := LowerCase(Result + IntToHex(Int64(FSessions.Count + 1), 4));
end;

procedure TLWHyperAuth.PurgeExpired;
var
  i: Integer;
  s: TLWHyperSession;
  deadline: TDateTime;
begin
  deadline := Now - (FTTLMin / (24 * 60));
  for i := FSessions.Count - 1 downto 0 do
  begin
    s := TLWHyperSession(FSessions.Objects[i]);
    if (s = nil) or (s.Last < deadline) then
    begin
      s.Free;
      FSessions.Delete(i);
    end;
  end;
end;

function TLWHyperAuth.SessionOf(const AToken: string): TLWHyperSession;
var
  i: Integer;
begin
  Result := nil;
  if AToken = '' then Exit;
  i := FSessions.IndexOf(AToken);
  if i >= 0 then
    Result := TLWHyperSession(FSessions.Objects[i]);
end;

function TLWHyperAuth.Login(const AUser, APass: string;
  out AToken, ARoles, ADisplay, AErr: string): Boolean;
var
  s: TLWHyperSession;
begin
  AToken := '';
  AErr := '';
  Result := CheckPassword(AUser, APass, ARoles, ADisplay);
  if not Result then
  begin
    ARoles := '';
    ADisplay := '';
    AErr := '用户名或口令错误';
    Exit;
  end;

  EnterCriticalSection(FLock);
  try
    PurgeExpired;
    s := TLWHyperSession.Create;
    s.Token := NewToken;
    while FSessions.IndexOf(s.Token) >= 0 do
      s.Token := NewToken;
    s.User := Trim(AUser);
    s.Roles := ARoles;
    s.Display := ADisplay;
    s.Last := Now;
    FSessions.AddObject(s.Token, s);
    AToken := s.Token;
  finally
    LeaveCriticalSection(FLock);
  end;
  LWLogFmt('[hyper-auth] 登录成功 user=%s roles=%s', [Trim(AUser), ARoles]);
end;

function TLWHyperAuth.Validate(const AToken: string;
  out AUser, ARoles, ADisplay: string): Boolean;
var
  s: TLWHyperSession;
begin
  AUser := '';
  ARoles := '';
  ADisplay := '';
  Result := False;
  if Trim(AToken) = '' then Exit;
  EnterCriticalSection(FLock);
  try
    s := SessionOf(AToken);
    if s = nil then Exit;
    if s.Last < (Now - (FTTLMin / (24 * 60))) then
    begin
      FSessions.Delete(FSessions.IndexOf(AToken));
      s.Free;
      Exit;
    end;
    s.Last := Now;      { 滑动续期：有请求就一直算活跃 }
    AUser := s.User;
    ARoles := s.Roles;
    ADisplay := s.Display;
    Result := True;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TLWHyperAuth.Logout(const AToken: string);
var
  i: Integer;
  s: TLWHyperSession;
begin
  if Trim(AToken) = '' then Exit;
  EnterCriticalSection(FLock);
  try
    i := FSessions.IndexOf(AToken);
    if i >= 0 then
    begin
      s := TLWHyperSession(FSessions.Objects[i]);
      FSessions.Delete(i);
      s.Free;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ ---------------- 全局回调 ---------------- }

function HyperAuthLookup(const ASid: string;
  out AUser, ARoles: string): Boolean;
var
  disp: string;
begin
  AUser := '';
  ARoles := '';
  Result := (GHyperAuth <> nil) and GHyperAuth.Validate(ASid, AUser, ARoles, disp);
  if not Result then
  begin
    AUser := '';
    ARoles := '';
  end;
end;

function HyperAuthOf(AAuth: TLWHyperAuth; ARequest: TFPHTTPConnectionRequest;
  out AUser, ARoles, ADisplay, AToken: string): Boolean;
begin
  AUser := '';
  ARoles := '';
  ADisplay := '';
  AToken := HyperRequestToken(ARequest);
  Result := (AAuth <> nil) and AAuth.Validate(AToken, AUser, ARoles, ADisplay);
end;

end.
