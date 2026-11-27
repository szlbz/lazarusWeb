unit upluginguard;
{ pluginsDemo 兼容包装：实现已上提到 src/core/lwpluginguard.pas。

  FPC 的 interface uses 不会把标识符再导出给本单元的使用者，所以这里把
  公共 API 显式转调一遍。原有 `uses upluginguard` 的宿主/插件源码无需改动，
  且与 lwhyper 插件模式共用同一份 secret 与口令算法。 }
{$mode objfpc}{$H+}

interface

const
  PlugGuardTokenParam = '--lw-plug-token=';
  PlugGuardNonceParam = '--lw-plug-nonce=';
  PlugGuardHostParam  = '--lw-plug-host=';
  PlugGuardMaxSkewSec = 120;
  PlugIdentityMaxSkewSec = 60;
  PlugGuardExitCode = 3;

function PlugGuardSecret: string;
function PlugGuardToken(const ANonce: string): string;
function PlugGuardNewNonce: string;
function PlugGuardArg(const APrefix: string): string;
function PlugGuardValidate(out AReason: string): Boolean;
function PlugGuardReasonText(const AReason: string): string;
procedure PlugGuardCheck(const ATitle: string);

implementation

uses
  lwpluginguard;

function PlugGuardSecret: string;
begin
  Result := lwpluginguard.PlugGuardSecret;
end;

function PlugGuardToken(const ANonce: string): string;
begin
  Result := lwpluginguard.PlugGuardToken(ANonce);
end;

function PlugGuardNewNonce: string;
begin
  Result := lwpluginguard.PlugGuardNewNonce;
end;

function PlugGuardArg(const APrefix: string): string;
begin
  Result := lwpluginguard.PlugGuardArg(APrefix);
end;

function PlugGuardValidate(out AReason: string): Boolean;
begin
  Result := lwpluginguard.PlugGuardValidate(AReason);
end;

function PlugGuardReasonText(const AReason: string): string;
begin
  Result := lwpluginguard.PlugGuardReasonText(AReason);
end;

procedure PlugGuardCheck(const ATitle: string);
begin
  lwpluginguard.PlugGuardCheck(ATitle);
end;

end.
