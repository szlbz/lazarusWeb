program grid;

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uGrid;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb grid';
  TLWApp.Register(TGridForm);
  TLWApp.Run;
end.
