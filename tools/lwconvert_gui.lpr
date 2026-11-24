{
  lwconvert_gui —— 桌面工程 -> lazarusWeb 工程转换器的 GUI 版入口。
  与控制台版（lwconvert.lpr）共用 lwconvert_core.pas。
}
program lwconvert_gui;

{$codepage utf8}
{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE GUI}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, SysUtils,
  lwconvert_core, ulwconvertgui;

begin
  { 窗体在 *.lfm 里：保留 LCL 的「资源缺失就报错」检查 }
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Title := 'lazarusWeb 工程转换器';
  Application.Initialize;
  Application.CreateForm(TConvertPanelForm, ConvertPanelForm);
  Application.Run;
end.
