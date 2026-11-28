program ehlibTree;

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uEhLibTree;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb EhLib Tree Grid';
  TLWApp.Register(TEhLibTreeForm);
  TLWApp.Run;
end.
