program hello;

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uHello;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb hello';
  TLWApp.Register(THelloForm);
  TLWApp.Run;
end.
