program dbdemo;

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uDbMain;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb · SQLite 演示';
  TLWApp.Register(TDbForm);
  TLWApp.Run;
end.
