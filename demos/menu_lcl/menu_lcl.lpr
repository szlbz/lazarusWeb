program menu_lcl;

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uMenuLcl;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb · menu_lcl';
  TLWApp.Register(TMenuLclForm);
  TLWApp.Run;
end.
