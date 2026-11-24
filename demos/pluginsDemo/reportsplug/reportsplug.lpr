program reportsplug;
{ pluginsDemo 插件 3：报表汇总（独立 exe）

  监听 8883；只读汇总，数据与计算都在本进程。
}
{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uform_reports, upluginguard;

begin
  { 启动守卫：只认宿主下发的 nonce/token，并且父进程必须是宿主。
    单独双击时提示"请从主程序进入"后退出（守卫实现见 common\upluginguard.pas） }
  PlugGuardCheck('报表汇总');

  Application.Initialize;
  Application.Title := 'lazarusWeb 插件：报表汇总';
  RegisterModule;
  TLWApp.Run;
end.
