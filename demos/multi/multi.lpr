program multi;

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uMain, uAbout in 'uAbout.pas';

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb multi';
  TLWApp.Register(TMainForm);
  TLWApp.Register(TAboutForm);
  TLWApp.Run;
end.
