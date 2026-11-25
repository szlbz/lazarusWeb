unit upluginauth;
{ pluginsDemo :: 用户与角色（宿主侧，插件不链接本单元）

  和 upluginguard 的分工别混：
    upluginguard  管"这个 exe 能不能被拉起"（进程来源），与"谁在用"无关；
    本单元         管"这个登录用户能不能打开这个插件"（业务权限）。

  演示账号（真实项目把 LWAuthLogin 换成查库/查接口即可，其它三个入口都不用动）：

    admin   / 123456   角色 admin      全部插件
    analyst / 123456   角色 analyst    仪表盘 + 便签
    guest   / 123456   角色 guest      只有便签

  插件清单声明需要哪些角色：

    roles=admin,analyst     只给这两个角色
    roles=admin             只给管理员
    roles=                 （不写 / 留空）所有已登录用户都能打开
    admin 角色隐含全部权限（通配），清单里不用重复列 admin

  判定只有一个实现（LWAuthCanOpen），三个入口共用，保证"看得见"和
  "打得开"永远一致：
    1. 登录   LWAuthLogin       校验口令，得到角色串
    2. 菜单   LWAuthCanOpen     决定侧栏里显不显示这一项
    3. 路由   LWAuthGuard       注册给 lwroute，/p/<名>/ 一律先判定，
                                无权限直接 403，不代理到插件进程
  只做 1、2 是不够的：菜单只是 UI，直接敲 URL 照样能进插件页面 ——
  所以 3 才是真正的强制点，1、2 只是让界面别骗人。
}
{$mode objfpc}{$H+}

interface

uses
  SysUtils, lwbase, lwhttp, lwapp, lwsession, lwroute, upluginproc;

const
  { 会话变量名：登录名 / 角色串（逗号分隔）。放在会话上而不是全局变量 ——
    同一进程里多个浏览器/多页签是不同用户，全局变量会把 A 的身份带给 B }
  LWAuthUserVar  = 'lwuser';
  LWAuthRolesVar = 'lwroles';

  { 演示账号口令（明文只为演示；真实项目不要落到源码里） }
  LWAuthDemoPass = '123456';
  { admin 通配：拥有任何插件，不必在每个清单里单独列出 }
  LWAuthAdminRole = 'admin';

type
  TLWAuthAccount = record
    User: string;
    Pass: string;
    Roles: string;
    Display: string;
  end;

const
  LWAuthAccounts: array[0..2] of TLWAuthAccount = (
    (User: 'admin';   Pass: '123456'; Roles: 'admin';
     Display: '系统管理员'),
    (User: 'analyst'; Pass: '123456'; Roles: 'analyst';
     Display: '数据分析员'),
    (User: 'guest';   Pass: '123456'; Roles: 'guest';
     Display: '访客'));

{ 账号口令校验。True 时 ARoles/ADisplay 是账号的角色与中文名 }
function LWAuthLogin(const AUser, APass: string;
  out ARoles, ADisplay, AErr: string): Boolean;
{ 挑战-响应版（TLWLoginForm.SecureLogin=True 时用）：
  AUserHash/APassHash 是浏览器上报的 SHA256(令牌|值)，ANonce 是
  TLWLoginForm.LoginNonce。服务端拿同一令牌复算账户名与口令的摘要比对；
  用户名大小写不敏感（双方都转小写），口令大小写敏感。
  命中时 ARealUser 返回真实登录名 —— 会话变量必须写它，不能写哈希。 }
function LWAuthLoginHashed(const AUserHash, APassHash, ANonce: string;
  out ARealUser, ARoles, ADisplay, AErr: string): Boolean;
{ 角色串里是否含某个角色（逗号分隔，忽略大小写与空格） }
function LWAuthHasRole(const ARoles, ARole: string): Boolean;
{ 当前角色能不能打开需要 ANeed 的插件。ANeed 空 = 所有已登录用户 }
function LWAuthCanOpen(const ARoles, ANeed: string): Boolean;
{ 角色串 -> 给人看的名字，'admin,analyst' -> '管理员、分析师' }
function LWAuthRoleText(const ARoles: string): string;
{ 清单 roles= -> 提示语，'' -> '所有已登录用户' }
function LWAuthNeedText(const ANeed: string): string;
{ 账号中文名（找不到就返回用户名本身） }
function LWAuthDisplayOf(const AUser: string): string;

{ 当前请求线程所属会话的身份（事件处理里取；后台线程取到 ''） }
function LWAuthSessionUser: string;
function LWAuthSessionRoles: string;
procedure LWAuthSessionSet(const AUser, ARoles: string);
procedure LWAuthSessionClear;

{ sid -> 身份。会话不存在/未认证/没登录过都返回 False（AuthGuard 用） }
function LWAuthRolesOfSid(const ASid: string;
  out AUser, ARoles: string): Boolean;

{ lwroute 鉴权回调：放行返回 True；否则 AReason 是给 403 页面看的中文原因 }
function LWAuthGuard(const AName, ASid: string;
  out AUser, AReason: string): Boolean;
{ lwroute 身份注入回调：给插件进程签发 user/roles/token/ts。
  签名公式与 common/upluginidentity.pas 里校验的必须一致 }
function LWAuthIdentity(const ASid: string;
  out AUser, ARoles, AToken, ATS: string): Boolean;
{ 在 TLWApp.Run 之前调用一次：把鉴权与身份注入都挂到路由上 }
procedure LWAuthRegister;

implementation

uses
  DateUtils, sha1, upluginguard;

function LWAuthHasRole(const ARoles, ARole: string): Boolean;
var
  s: string;
  p: Integer;
begin
  Result := False;
  if (ARoles = '') or (ARole = '') then Exit;
  s := ARoles;
  while s <> '' do
  begin
    p := Pos(',', s);
    if p > 0 then
    begin
      if SameText(Trim(Copy(s, 1, p - 1)), ARole) then Exit(True);
      s := Copy(s, p + 1, MaxInt);
    end
    else
    begin
      if SameText(Trim(s), ARole) then Exit(True);
      s := '';
    end;
  end;
end;

function LWAuthCanOpen(const ARoles, ANeed: string): Boolean;
var
  s: string;
  p: Integer;
begin
  { 清单没写 roles=：不算"限制"，只是"任何已登录用户" }
  if Trim(ANeed) = '' then Exit(True);
  if Trim(ARoles) = '' then Exit(False);
  { 管理员通配：加插件时不用回头改 admin 的角色串 }
  if LWAuthHasRole(ARoles, LWAuthAdminRole) then Exit(True);
  s := ANeed;
  while s <> '' do
  begin
    p := Pos(',', s);
    if p > 0 then
    begin
      if LWAuthHasRole(ARoles, Trim(Copy(s, 1, p - 1))) then Exit(True);
      s := Copy(s, p + 1, MaxInt);
    end
    else
    begin
      if LWAuthHasRole(ARoles, Trim(s)) then Exit(True);
      s := '';
    end;
  end;
  Result := False;
end;

function LWAuthRoleName(const ARole: string): string;
begin
  if SameText(ARole, 'admin') then
    Result := '管理员'
  else if SameText(ARole, 'analyst') then
    Result := '分析师'
  else if SameText(ARole, 'guest') then
    Result := '访客'
  else
    Result := ARole;
end;

function LWAuthRoleText(const ARoles: string): string;
var
  s: string;
  p: Integer;
begin
  Result := '';
  s := ARoles;
  while s <> '' do
  begin
    p := Pos(',', s);
    if p > 0 then
    begin
      if Trim(Copy(s, 1, p - 1)) <> '' then
      begin
        if Result <> '' then Result := Result + '、';
        Result := Result + LWAuthRoleName(Trim(Copy(s, 1, p - 1)));
      end;
      s := Copy(s, p + 1, MaxInt);
    end
    else
    begin
      if Trim(s) <> '' then
      begin
        if Result <> '' then Result := Result + '、';
        Result := Result + LWAuthRoleName(Trim(s));
      end;
      s := '';
    end;
  end;
end;

function LWAuthNeedText(const ANeed: string): string;
begin
  if Trim(ANeed) = '' then
    Result := '所有已登录用户'
  else
    Result := LWAuthRoleText(ANeed);
end;

function LWAuthDisplayOf(const AUser: string): string;
var
  i: Integer;
begin
  for i := Low(LWAuthAccounts) to High(LWAuthAccounts) do
    if SameText(LWAuthAccounts[i].User, AUser) then
      Exit(LWAuthAccounts[i].Display);
  Result := AUser;
end;

function LWAuthLogin(const AUser, APass: string;
  out ARoles, ADisplay, AErr: string): Boolean;
var
  i: Integer;
begin
  ARoles := '';
  ADisplay := '';
  AErr := '';
  Result := False;
  if Trim(AUser) = '' then
  begin
    AErr := '请输入用户名';
    Exit;
  end;
  for i := Low(LWAuthAccounts) to High(LWAuthAccounts) do
    if SameText(LWAuthAccounts[i].User, Trim(AUser)) then
    begin
      if LWAuthAccounts[i].Pass <> APass then
      begin
        AErr := '用户名或密码错误';
        Exit;
      end;
      ARoles := LWAuthAccounts[i].Roles;
      ADisplay := LWAuthAccounts[i].Display;
      Exit(True);
    end;
  { 不区分"用户不存在"和"口令错误"：别让人拿错误提示枚举账号 }
  AErr := '用户名或密码错误';
end;

function LWAuthLoginHashed(const AUserHash, APassHash, ANonce: string;
  out ARealUser, ARoles, ADisplay, AErr: string): Boolean;
var
  i: Integer;
  uh: string;
begin
  ARealUser := '';
  ARoles := '';
  ADisplay := '';
  AErr := '';
  Result := False;
  if (ANonce = '') or (AUserHash = '') then
  begin
    AErr := '登录参数不完整（挑战令牌缺失）';
    Exit;
  end;

  { 用户名也是哈希，无法按名字直接查表：逐个账户复算摘要匹配。
    账户量小（演示 3 个）无所谓；真实项目应在库里存
    SHA256(盐|用户名) 的索引列，或退回"用户名明文 + 只哈希口令"。 }
  for i := Low(LWAuthAccounts) to High(LWAuthAccounts) do
  begin
    uh := LWSha256Hex(ANonce + '|' +
      LowerCase(Trim(LWAuthAccounts[i].User)));
    if not SameText(uh, AUserHash) then
      Continue;

    if not SameText(LWSha256Hex(ANonce + '|' + LWAuthAccounts[i].Pass),
      APassHash) then
    begin
      AErr := '用户名或密码错误';
      Exit;
    end;

    ARealUser := LWAuthAccounts[i].User;
    ARoles := LWAuthAccounts[i].Roles;
    ADisplay := LWAuthAccounts[i].Display;
    Exit(True);
  end;

  AErr := '用户名或密码错误';
end;

function LWAuthSessionUser: string;
var
  S: TLWSessionBase;
begin
  Result := '';
  S := LWCurrentSession;
  if S <> nil then
    Result := S.SessionGetVar(LWAuthUserVar);
end;

function LWAuthSessionRoles: string;
var
  S: TLWSessionBase;
begin
  Result := '';
  S := LWCurrentSession;
  if S <> nil then
    Result := S.SessionGetVar(LWAuthRolesVar);
end;

procedure LWAuthSessionSet(const AUser, ARoles: string);
var
  S: TLWSessionBase;
begin
  S := LWCurrentSession;
  if S = nil then Exit;
  S.SessionSetVar(LWAuthUserVar, AUser);
  S.SessionSetVar(LWAuthRolesVar, ARoles);
end;

procedure LWAuthSessionClear;
begin
  LWAuthSessionSet('', '');
end;

function LWAuthRolesOfSid(const ASid: string;
  out AUser, ARoles: string): Boolean;
var
  srv: TLWServer;
  s: TLWSession;
begin
  AUser := '';
  ARoles := '';
  Result := False;
  if Trim(ASid) = '' then Exit;
  srv := TLWApp.Server;
  if srv = nil then Exit;
  { Find 返回时 RefCount+1：必须 Release，否则会话永远不回收 }
  s := srv.Store.Find(ASid);
  if s = nil then Exit;
  try
    { Authenticated 而不是"有用户变量"：注销后变量可能还留着旧值 }
    if not s.Authenticated then Exit;
    AUser := s.SessionGetVar(LWAuthUserVar);
    ARoles := s.SessionGetVar(LWAuthRolesVar);
    Result := AUser <> '';
  finally
    srv.Store.Release(s);
  end;
end;

function LWAuthGuard(const AName, ASid: string;
  out AUser, AReason: string): Boolean;
var
  roles: string;
  p: TPlugPlugin;
begin
  AUser := '';
  AReason := '';
  Result := False;

  if not LWAuthRolesOfSid(ASid, AUser, roles) then
  begin
    AReason := '未登录，或会话已过期。请回到工作台重新登录，再从侧栏打开本插件。';
    Exit;
  end;

  p := PlugByName(AName);
  if p = nil then
  begin
    { 路由存在但清单里没有：别当成"没限制"放过去 }
    AReason := '插件「' + AName + '」不在清单里，宿主拒绝转发。';
    Exit;
  end;

  if not LWAuthCanOpen(roles, p.Roles) then
  begin
    AReason := '当前账号（' + AUser + '，角色：' + LWAuthRoleText(roles) +
      '）没有该插件的访问权限。';
    Exit;
  end;

  Result := True;
end;

function LWAuthIdentity(const ASid: string;
  out AUser, ARoles, AToken, ATS: string): Boolean;
begin
  AUser := '';
  ARoles := '';
  AToken := '';
  ATS := '';
  Result := LWAuthRolesOfSid(ASid, AUser, ARoles);
  if not Result then Exit;
  ATS := IntToStr(DateTimeToUnix(Now, False));
  { 与 upluginidentity.Checked 用同一个 secret、同一个拼接顺序。
    浏览器伪造 X-LW-User 时算不出这个 token，插件侧会直接拒掉 }
  AToken := LowerCase(SHA1Print(SHA1String(
    PlugGuardSecret + '|' + AUser + '|' + ARoles + '|' + ATS)));
end;

procedure LWAuthRegister;
begin
  LWRouteSetAuth(@LWAuthGuard);
  LWRouteSetIdentity(@LWAuthIdentity);
end;

end.
