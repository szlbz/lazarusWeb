program dlgdemo;

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

{ 对话框演示：ShowMessage / MessageDlg / InputQuery / QuestionDlg /
  Application.MessageBox / TOpenDialog / TSaveDialog 全部弹在浏览器里。 }

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uDialogs;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb dialogs';
  TLWApp.Register(TDlgForm);
  TLWApp.Run;
end.
