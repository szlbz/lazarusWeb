program pluginsdemo;
{ pluginsDemo :: 宿主（主程序 exe）

  宿主不链接任何插件单元。插件是三个独立 exe，各自监听自己的端口：
    dashplug.exe     8881
    notesplug.exe    8882
    reportsplug.exe  8883
  宿主启动时扫描 ../*\*.plugin.ini，注册 /p/<名>/ 路由并拉起插件进程。
}
{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, upluginproc, umain;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb 插件工作台（主程序 exe + 插件 exe）';
  RegisterMain;
  { 发现 -> 注册路由 -> 拉起进程，必须在 Run 之前完成 }
  PlugDiscover;
  PlugRegisterRoutes;
  PlugLaunchAll;
  TLWApp.Run;
end.
