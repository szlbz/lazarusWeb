program logindemo;

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uLogin, uMain;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb · 登录演示（TLWLoginForm）';
  TLWApp.SetLogin(TLoginForm);    { 登录窗体：每个新会话先过它 }
  TLWApp.Register(TMainForm);     { 主窗体：认证通过后创建 }
  TLWApp.Run;
end.
