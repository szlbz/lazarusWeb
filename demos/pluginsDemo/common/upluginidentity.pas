unit upluginidentity;
{ pluginsDemo 兼容包装：实现已上提到 src/core/lwpluginidentity.pas。

  FPC 的 interface uses 不会把标识符再导出给本单元的使用者，所以这里把
  公共 API 显式转调一遍。插件源码无需改动，验签与 lwhyper 插件模式签发的
  身份头使用同一 secret 与同一套公式。 }
{$mode objfpc}{$H+}

interface

function PlugIdentityValid: Boolean;
function PlugIdentityUser: string;
function PlugIdentityRoles: string;
function PlugIdentityDisplay: string;

implementation

uses
  lwpluginidentity;

function PlugIdentityValid: Boolean;
begin
  Result := lwpluginidentity.PlugIdentityValid;
end;

function PlugIdentityUser: string;
begin
  Result := lwpluginidentity.PlugIdentityUser;
end;

function PlugIdentityRoles: string;
begin
  Result := lwpluginidentity.PlugIdentityRoles;
end;

function PlugIdentityDisplay: string;
begin
  Result := lwpluginidentity.PlugIdentityDisplay;
end;

end.
