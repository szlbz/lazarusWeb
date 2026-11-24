program dashplug;
{ pluginsDemo 插件 1：仪表盘（独立 exe）

  自己就是一个 lazarusWeb 服务：只注册 Dashboard 窗体，监听 8881。
  宿主用 /p/dash/ 反向代理到本进程。
}
{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uform_dashboard, upluginguard;

begin
  { 启动守卫：只认宿主下发的 nonce/token，并且父进程必须是宿主。
    单独双击时提示"请从主程序进入"后退出（守卫实现见 common\upluginguard.pas） }
  PlugGuardCheck('仪表盘');

  Application.Initialize;
  Application.Title := 'lazarusWeb 插件：仪表盘';
  RegisterModule;
  TLWApp.Run;
end.
