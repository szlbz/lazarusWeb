program reportsplug;
{ pluginsDemo 插件 3：报表汇总（独立 exe）

  监听 8883；只读汇总，数据与计算都在本进程。
}
{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uform_reports;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb 插件：报表汇总';
  RegisterModule;
  TLWApp.Run;
end.
