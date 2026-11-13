program lwperf;
{ 单窗体序列化探针：量 WriteForm（控件树遍历 + JSON 构造）与 AsJSON（转文本）
  各占多少时间，用来判断"事件后重建整棵树"的瓶颈到底在哪一段。

  编译：lazbuild lwperf.lpi ；运行：lwperf.exe [次数]
  按 kind 的细分耗时见 LW_KIND_PROF=1（结果打到 stderr，见 LWKindProfReport）。 }
{$mode objfpc}{$H+}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, SysUtils, Classes, DateUtils, fpjson,
  lwbase, lwws, lwwriter, uGallery, uAbout;

type
  { 稳定的 id 分配：同一个控件永远同一个 id。
    量性能时必须给稳定 id —— 否则 id 每轮都变，任何基于"同一控件同一身份"
    的优化都会显得毫无效果（这个坑踩过，见 NOTES 坑 105）。 }
  TIds = class
  private
    FMap: TStringList;
  public
    function IdOf(C: TComponent): Integer;
    constructor Create;
    destructor Destroy; override;
    property Count_: TStringList read FMap;
  end;

constructor TIds.Create;
begin
  inherited Create;
  FMap := TStringList.Create;
  FMap.Sorted := True;
  FMap.CaseSensitive := True;   { 键是数字串，见 NOTES 坑 100 }
  FMap.Duplicates := dupIgnore;
end;

destructor TIds.Destroy;
begin
  FMap.Free;
  inherited Destroy;
end;

function TIds.IdOf(C: TComponent): Integer;
var
  k: string;
  idx: Integer;
begin
  if C = nil then Exit(0);
  k := IntToStr(PtrInt(Pointer(C)));
  idx := FMap.IndexOf(k);
  if idx >= 0 then Exit(PtrInt(FMap.Objects[idx]));
  Result := FMap.Count + 1;
  FMap.AddObject(k, TObject(PtrInt(Result)));
end;

var
  gLog: Text;

procedure Log(const S: string);
begin
  writeln(gLog, S);
  Flush(gLog);
end;

procedure BenchForm(f: TCustomForm; const AName: string; AIters: Integer);
var
  w: TLWWriter;
  ids: TIds;
  j: TJSONObject;
  i, nodes: Integer;
  t0, tWrite, tJson: Int64;
  bytes: Integer;
begin
  ids := TIds.Create;
  w := TLWWriter.Create(@ids.IdOf);
  try
    { 预热：第一次会碰 LCL 懒初始化/字形缓存，单列出来 }
    t0 := LWNowUS;
    j := w.WriteForm(f, False);
    tWrite := LWNowUS - t0;
    t0 := LWNowUS;
    bytes := Length(j.AsJSON);
    tJson := LWNowUS - t0;
    nodes := ids.FMap.Count;
    j.Free;
    Log(Format('%s  nodes=%d  first_write=%.1fms  first_json=%.1fms  bytes=%d',
      [AName, nodes, tWrite / 1000, tJson / 1000, bytes]));

    tWrite := 0;
    tJson := 0;
    for i := 1 to AIters do
    begin
      t0 := LWNowUS;
      j := w.WriteForm(f, False);
      tWrite := tWrite + (LWNowUS - t0);
      t0 := LWNowUS;
      bytes := Length(j.AsJSON);
      tJson := tJson + (LWNowUS - t0);
      j.Free;
    end;
    Log(Format('%s  avg_write=%.2fms  avg_json=%.2fms  bytes=%d  iters=%d',
      [AName, tWrite / 1000 / AIters, tJson / 1000 / AIters, bytes, AIters]));
  finally
    w.Free;
    ids.Free;
  end;
end;

var
  iters, i: Integer;
  main: TGalleryForm;
  about: TAboutForm;
begin
  iters := 30;
  for i := 1 to ParamCount do
    iters := StrToIntDef(ParamStr(i), iters);

  Assign(gLog, 'lwperf_out.txt');
  Rewrite(gLog);
  Application.Initialize;
  LWInstallWidgetSet;
  Application.Scaled := True;
  Log('cpu=' + IntToStr(GetCPUCount) + ' iters=' + IntToStr(iters));
  try
    try
      main := TGalleryForm.Create(nil);
      try
        BenchForm(main, 'TGalleryForm', iters);
      finally
        main.Free;
      end;
      about := TAboutForm.Create(nil);
      try
        BenchForm(about, 'TAboutForm', iters);
      finally
        about.Free;
      end;
    except
      on E: Exception do
        Log('EXCEPTION: ' + E.ClassName + ': ' + E.Message);
    end;
  finally
    Log('done');
    LWKindProfReport;
    Close(gLog);
  end;
end.
