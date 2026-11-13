program menu_main;

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uMenuMain;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb · menu_main';
  TLWApp.Register(TMenuMainForm);
  TLWApp.Run;
end.
