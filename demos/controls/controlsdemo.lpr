program controlsdemo;

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uControls;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb · 容器/列表控件';
  TLWApp.Register(TControlsForm);
  TLWApp.Run;
end.
