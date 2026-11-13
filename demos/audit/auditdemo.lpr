program auditdemo;

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uAudit;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb · 架构审计';
  TLWApp.Register(TAuditForm);
  TLWApp.Run;
end.
