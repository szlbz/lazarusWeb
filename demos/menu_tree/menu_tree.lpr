program menu_tree;

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uMenuTree;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb · menu_tree';
  { 第一个注册的窗体就是默认窗体 }
  TLWApp.Register(TMenuTreeForm);
  TLWApp.Run;
end.
