program notesplug;
{ pluginsDemo 插件 2：便签（独立 exe）

  监听 8882，数据落盘到 exe 同目录；宿主重启本进程（热更新）后数据仍在。
}
{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uform_notes;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb 插件：便签';
  RegisterModule;
  TLWApp.Run;
end.
