unit lwpluginidentity;
{ lazarusWeb :: 插件侧身份读取（宿主签发 + 本地验签）

  从 demos/pluginsDemo/common/upluginidentity.pas 上提到核心；demo 侧的
  upluginidentity 只是本单元的 re-export 包装。lwhyper 插件模式按同一套
  X-LW-* 头与签名公式向插件签发身份。

  为什么要这个单元：宿主和登录状态都在宿主进程里，插件是独立 exe，
  有自己的会话表，看不到宿主的 lwuser/lwroles。宿主在 /p/ 反代时把
  身份写进请求头（lwroute 的 LWRouteSetIdentity），插件在这里读头、
  验签之后才认。

  签名用 lwpluginguard 里同一个 secret，公式：

      SHA1(secret + '|' + user + '|' + roles + '|' + ts)   小写十六进制

  ts 是 Unix 秒，允许偏差 PlugIdentityMaxSkewSec = 60 秒，挡住截获旧头
  后的重放。secret 改了要宿主和插件一起重编（共用单元，改一处即可）。

  直连插件监听端口（127.0.0.1:8882）时没有签名头，三个 getter 都返回
  空串 —— 这正好回答"这个请求是不是从宿主进来的"。浏览器自己伪造
  X-LW-User 头也没用：签名算不出来。 }
{$mode objfpc}{$H+}

interface

{ 验签通过才返回非空。业务代码要判断身份来源时先调 PlugIdentityValid }
function PlugIdentityValid: Boolean;
function PlugIdentityUser: string;
function PlugIdentityRoles: string;
{ 演示账号的中文名；没验过签返回"未识别（请从主程序进入）" }
function PlugIdentityDisplay: string;

implementation

uses
  SysUtils, DateUtils, sha1, lwhttp, lwpluginguard;

function Checked(out AUser, ARoles: string): Boolean;
var
  token, ts, expect: string;
  t: Int64;
begin
  AUser := '';
  ARoles := '';
  Result := False;
  AUser := LWIdentityUser;
  ARoles := LWIdentityRoles;
  if (AUser = '') or (ARoles = '') then Exit;
  ts := LWIdentityTs;
  token := LowerCase(LWIdentityToken);
  if (ts = '') or (token = '') then Exit;
  t := StrToInt64Def(ts, 0);
  if t <= 0 then Exit;
  if Abs(DateTimeToUnix(Now, False) - t) > PlugIdentityMaxSkewSec then Exit;
  expect := LowerCase(SHA1Print(SHA1String(
    PlugGuardSecret + '|' + AUser + '|' + ARoles + '|' + ts)));
  Result := expect = token;
  if not Result then
  begin
    AUser := '';
    ARoles := '';
  end;
end;

function PlugIdentityValid: Boolean;
var
  u, r: string;
begin
  Result := Checked(u, r);
end;

function PlugIdentityUser: string;
var
  u, r: string;
begin
  if Checked(u, r) then
    Result := u
  else
    Result := '';
end;

function PlugIdentityRoles: string;
var
  u, r: string;
begin
  if Checked(u, r) then
    Result := r
  else
    Result := '';
end;

function PlugIdentityDisplay: string;
var
  u: string;
begin
  u := PlugIdentityUser;
  if u = '' then Exit('未识别（请从主程序进入）');
  if SameText(u, 'admin') then Exit('系统管理员');
  if SameText(u, 'analyst') then Exit('数据分析员');
  if SameText(u, 'guest') then Exit('访客');
  Result := u;
end;

end.
