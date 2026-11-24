program dashplug;
{ pluginsDemo 插件 1：仪表盘（独立 exe）

  自己就是一个 lazarusWeb 服务：只注册 Dashboard 窗体，监听 8881。
  宿主用 /p/dash/ 反向代理到本进程。
}
{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uform_dashboard;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb 插件：仪表盘';
  RegisterModule;
  TLWApp.Run;
end.
