program notesplug;
{ pluginsDemo 插件 2：便签（独立 exe）

  监听 8882，数据落盘到 exe 同目录；宿主重启本进程（热更新）后数据仍在。
}
{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uform_notes, upluginguard;

begin
  { 启动守卫：只认宿主下发的 nonce/token，并且父进程必须是宿主。
    单独双击时提示"请从主程序进入"后退出（守卫实现见 common\upluginguard.pas） }
  PlugGuardCheck('便签');

  Application.Initialize;
  Application.Title := 'lazarusWeb 插件：便签';
  RegisterModule;
  TLWApp.Run;
end.
