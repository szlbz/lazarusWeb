{
  lazarusWeb :: 插件鉴权 / 身份签名公共逻辑（src/core 共用单元）

  从 demos/pluginsDemo/common/upluginauth.pas 中把与具体账号表无关的部分
  上提到核心，供 lwhyper 插件模式与 pluginsDemo 宿主共用：

    - 角色串解析 / 通配 admin / 清单 roles= 判定
    - 身份令牌签名与验签（公式与 lwpluginidentity 一致）

  账号表、会话表查询仍由宿主工程自己提供（upluginauth.LWAuthRolesOfSid
  或 TLWHyperServer 的 OnLookupIdentity 回调）；本单元刻意不依赖 lwapp /
  lwsession，这样 lwhyper 这种非 lazarusWeb 应用进程也能直接复用。
}
unit lwpluginauth;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DateUtils, sha1, lwpluginguard;

const
  { admin 通配：拥有任何插件，不必在每个清单里单独列出 }
  LWPluginAdminRole = 'admin';

{ 从宿主注入的“sid -> 登录名/角色串”查询函数。返回 False = 未登录 }
type
  TLWPluginIdentityLookup = function(const ASid: string;
    out AUser, ARoles: string): Boolean;

{ 角色串（逗号分隔，忽略大小写与空格）里是否含 ARole }
function LWPluginHasRole(const ARoles, ARole: string): Boolean;
{ 当前角色能否打开清单声明了 ANeed 角色的插件；ANeed 空 = 任一已登录用户 }
function LWPluginCanOpen(const ARoles, ANeed: string): Boolean;
{ 角色串转人可读文本（逗号 -> 顿号） }
function LWPluginRoleText(const ARoles: string): string;
{ 清单 roles= 的提示语 }
function LWPluginNeedText(const ANeed: string): string;
{ SHA1(secret|user|roles|ts) 小写十六进制，与插件侧验签共用同一 secret }
function LWPluginSignIdentity(const AUser, ARoles, ATS: string): string;
{ 插件侧/宿主侧通用验签；ATS 为 Unix 秒字符串 }
function LWPluginVerifyIdentity(const AUser, ARoles, ATS,
  AToken: string): Boolean;
{ 统一鉴权入口：查身份 + 判角色；拒绝原因回填 AReason }
function LWPluginAuthorize(ALookup: TLWPluginIdentityLookup;
  const ASid, ANeed: string; out AUser, ARoles, AReason: string): Boolean;

implementation

function LWPluginHasRole(const ARoles, ARole: string): Boolean;
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

function LWPluginCanOpen(const ARoles, ANeed: string): Boolean;
var
  s: string;
  p: Integer;
begin
  if Trim(ANeed) = '' then Exit(True);
  if Trim(ARoles) = '' then Exit(False);
  if LWPluginHasRole(ARoles, LWPluginAdminRole) then Exit(True);
  s := ANeed;
  while s <> '' do
  begin
    p := Pos(',', s);
    if p > 0 then
    begin
      if LWPluginHasRole(ARoles, Trim(Copy(s, 1, p - 1))) then Exit(True);
      s := Copy(s, p + 1, MaxInt);
    end
    else
    begin
      if LWPluginHasRole(ARoles, Trim(s)) then Exit(True);
      s := '';
    end;
  end;
  Result := False;
end;

function LWPluginRoleText(const ARoles: string): string;
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
        Result := Result + Trim(Copy(s, 1, p - 1));
      end;
      s := Copy(s, p + 1, MaxInt);
    end
    else
    begin
      if Trim(s) <> '' then
      begin
        if Result <> '' then Result := Result + '、';
        Result := Result + Trim(s);
      end;
      s := '';
    end;
  end;
end;

function LWPluginNeedText(const ANeed: string): string;
begin
  if Trim(ANeed) = '' then
    Result := '所有已登录用户'
  else
    Result := LWPluginRoleText(ANeed);
end;

function LWPluginSignIdentity(const AUser, ARoles, ATS: string): string;
begin
  Result := LowerCase(SHA1Print(SHA1String(
    PlugGuardSecret + '|' + AUser + '|' + ARoles + '|' + ATS)));
end;

function LWPluginVerifyIdentity(const AUser, ARoles, ATS,
  AToken: string): Boolean;
var
  t: Int64;
begin
  Result := False;
  if (AUser = '') or (ARoles = '') or (ATS = '') or (AToken = '') then Exit;
  t := StrToInt64Def(ATS, 0);
  if t <= 0 then Exit;
  if Abs(DateTimeToUnix(Now, False) - t) > PlugIdentityMaxSkewSec then Exit;
  Result := LWPluginSignIdentity(AUser, ARoles, ATS) = LowerCase(AToken);
end;

function LWPluginAuthorize(ALookup: TLWPluginIdentityLookup;
  const ASid, ANeed: string; out AUser, ARoles, AReason: string): Boolean;
begin
  AUser := '';
  ARoles := '';
  AReason := '';
  Result := False;
  if not Assigned(ALookup) then Exit;
  if not ALookup(ASid, AUser, ARoles) then
  begin
    AUser := '';
    ARoles := '';
    AReason := '未登录，或会话已过期。请回到工作台重新登录后再打开插件。';
    Exit;
  end;
  if not LWPluginCanOpen(ARoles, ANeed) then
  begin
    AReason := '当前账号（' + AUser + '，角色：' + LWPluginRoleText(ARoles) +
      '）没有该插件的访问权限。';
    Exit;
  end;
  Result := True;
end;

end.
