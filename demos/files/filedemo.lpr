program filedemo;

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uFileForm;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb · 文件上传下载';
  TLWApp.Register(TFileForm);
  TLWApp.Run;
end.
