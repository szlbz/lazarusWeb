program lwdump;
{ 临时调试工具：把 TAboutForm 经 lwwriter 序列化成 JSON 打出来，
  核对 lblTitle 等控件实际下发的 x/y/w/h/textalign。
  用完可删。编译：lazbuild lwdump.lpi }
{$mode objfpc}{$H+}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, SysUtils, Classes, fpjson,
  lwbase, lwws, lwwriter, uAbout;

type
  TDumper = class
  public
    function IdOf(C: TComponent): Integer;
  end;

var
  gLog: Text;

procedure Log(const S: string);
begin
  writeln(gLog, S);
  Flush(gLog);
end;

function TDumper.IdOf(C: TComponent): Integer;
begin
  Result := 1; // dump 用途，ID 值不重要
end;

var
  f: TAboutForm;
  w: TLWWriter;
  d: TDumper;
  j: TJSONObject;
begin
  Assign(gLog, 'lwdump_out.txt');
  Rewrite(gLog);
  Log('start');
  Application.Initialize;
  LWInstallWidgetSet;   { nogui 下必须先装补丁 widgetset，否则建 TForm 就 AV }
  Application.Scaled := True;   { 与 lwapp.TLWApp.Run 一致：按 DesignTimePPI 缩放 }
  Log('after init');
  try
    f := TAboutForm.Create(nil);
    Log('form created: ' + IntToStr(f.ComponentCount) + ' components');
  except
    on E: Exception do
    begin
      Log('EXCEPTION: ' + E.ClassName + ': ' + E.Message);
      Close(gLog);
      Halt(2);
    end;
  end;
  try
    d := TDumper.Create;
    w := TLWWriter.Create(@d.IdOf);
    try
      j := w.WriteForm(f, True);
      Log('json begin');
      Log(j.FormatJSON([], 2));
      Log('json end');
      j.Free;
    finally
      w.Free;
      d.Free;
    end;
  finally
    f.Free;
  end;
  Log('done');
  Close(gLog);
end.
