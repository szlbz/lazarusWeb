{
  lazarusWeb :: lwconvert_gui 面板
  ------------------------------------------------------------------
  桌面工程 -> lazarusWeb 工程转换器的 GUI 版，与控制台版共用
  lwconvert_core.pas（同一套改写逻辑，结果一字不差）。

      +------------------------------------------------------+
      | 源工程    [C:\my\proj          ] [浏览]               |
      | 输出目录  [C:\my\proj_web       ] [浏览]              |
      | LW 根目录 [C:\lazarusWeb        ]                     |
      |------------------------------------------------------|
      | [支持度分析] [开始转换] [打开报告] [打开输出目录]      |
      |------------------------------------------------------|
      | == 转换完成 ==                                        |
      | 改写   : 6 处                                         |
      | 注册   : TLWApp.Register(TForm1);                     |
      | 警告   : 1 条 ...                                     |
      +------------------------------------------------------+

  界面在 ulwconvertgui.lfm（Lazarus 设计器可直接打开改布局），
  本单元只保留行为；控件名与 .lfm 一一对应。

  行为约定：
    - 输出目录留空 -> 自动用「源目录 + _web」；
    - 分析模式在源目录写 lwreport.md，转换模式在输出目录写
      lwconvert-report.md（与控制台版一致）；
    - 转换在工作线程里跑（大工程复制文件不冻结界面），结果经
      OnTerminate（主线程）回填 Memo。
}
unit ulwconvertgui;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls, ExtCtrls, Graphics,
  Dialogs, FileCtrl, IniFiles, LCLType, LCLIntf,
  lwconvert_core;

type
  { 转换/分析工作线程：持有 TConv，跑完后由主线程 OnTerminate 收结果 }
  TConvJob = class(TThread)
  protected
    procedure Execute; override;
  public
    Ctx: TConv;
    SrcDir, OutDir, Root, LpiFile, LprFile: string;
    Convert: Boolean;         { True=转换 False=只分析 }
    OK: Boolean;
    Lines: TStringList;       { 结果输出，主线程 OnTerminate 里读 }
    ReportPath: string;       { 本次生成的报告文件 }
    constructor Create;
    destructor Destroy; override;
  end;

  TConvertPanelForm = class(TForm)
    { ---- 控件：全部来自 ulwconvertgui.lfm ---- }
    grpProj: TGroupBox;
    lblSrc: TLabel;
    lblOut: TLabel;
    lblRoot: TLabel;
    edSrc: TEdit;
    btnBrowseSrc: TButton;
    edOut: TEdit;
    btnBrowseOut: TButton;
    edRoot: TEdit;
    btnAnalyze: TButton;
    btnConvert: TButton;
    btnReport: TButton;
    btnOpenOut: TButton;
    memLog: TMemo;
    sbMain: TStatusBar;
    { ---- 事件：在 .lfm 里按方法名绑定，必须留在 published 段 ---- }
    procedure FormCreate(Sender: TObject);
    procedure btnBrowseSrcClick(Sender: TObject);
    procedure btnBrowseOutClick(Sender: TObject);
    procedure btnAnalyzeClick(Sender: TObject);
    procedure btnConvertClick(Sender: TObject);
    procedure btnReportClick(Sender: TObject);
    procedure btnOpenOutClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
  private
    FJob: TConvJob;
    FLastReport: string;
    procedure PickMonoFont;
    procedure Log(const ALine: string);
    procedure ResolveRoot;
    procedure JobDone(Sender: TObject);
    procedure SetBusy(ABusy: Boolean);
    function StartJob(AConvert: Boolean): Boolean;
  public
  end;

var
  ConvertPanelForm: TConvertPanelForm;

implementation

{$R *.lfm}

{ ---------------- 工作线程 ---------------- }

constructor TConvJob.Create;
begin
  inherited Create(True);   { 挂起创建，主线程填完字段再 Start }
  OK := False;
  Convert := False;
  { FreeOnTerminate 必须开：OnTerminate 经 Synchronize 在主线程跑，
    工作线程此刻阻塞等它返回；若在 OnTerminate 里 Free 线程对象，
    TThread.Destroy→WaitFor 又反等线程退出 -> 死锁（UI 卡死假死）。
    开了它，OnTerminate 返回后线程在自身上下文自释放，JobDone 只读不 Free。 }
  FreeOnTerminate := True;
  Lines := TStringList.Create;
  Ctx := TConv.Create;
end;

destructor TConvJob.Destroy;
begin
  Ctx.Free;
  Lines.Free;
  inherited Destroy;
end;

procedure TConvJob.Execute;
var
  i, j: Integer;
  lfmFiles: TStringList;
  reports: TList;
  nd: TNode;
  r: TFormReport;
  err, lvl: string;
begin
  try
    Ctx.SrcDir := SrcDir;
    Ctx.OutDir := OutDir;
    Ctx.Root := Root;
    LoadControlMatrix(Ctx.Root, Ctx.Matrix);

    if Convert then
    begin
      OK := DoConvert(Ctx, LpiFile, LprFile);
      if OK then
      begin
        Lines.Add('== 转换完成 ==');
        Lines.Add('输出目录: ' + OutDir);
        Lines.Add('改写   : ' + IntToStr(Ctx.Changed.Count) + ' 处');
        for i := 0 to Ctx.Changed.Count - 1 do
          Lines.Add('  - ' + Ctx.Changed[i]);
        for i := 0 to Ctx.Registers.Count - 1 do
          Lines.Add('注册   : TLWApp.Register(' + Ctx.Registers[i] + ');');
        Lines.Add('警告   : ' + IntToStr(Ctx.Warnings.Count) + ' 条');
        for i := 0 to Ctx.Warnings.Count - 1 do
          Lines.Add('  ! ' + Ctx.Warnings[i]);
        for i := 0 to Ctx.Skipped.Count - 1 do
          Lines.Add('  ~ ' + Ctx.Skipped[i]);
        Lines.Add('');
        Lines.Add('下一步:');
        Lines.Add('  lazbuild -B --ws=nogui ' + IncludeTrailingPathDelimiter(OutDir) +
          Ctx.ProjName + '.lpi');
        Lines.Add('  ' + IncludeTrailingPathDelimiter(OutDir) + Ctx.ProjName +
          {$IFDEF WINDOWS}'.exe'{$ENDIF} + ' --port=8090');
        ReportPath := IncludeTrailingPathDelimiter(OutDir) + 'lwconvert-report.md';
      end
      else
      begin
        Lines.Add('== 转换失败 ==');
        for i := 0 to Ctx.Warnings.Count - 1 do
          Lines.Add('  ! ' + Ctx.Warnings[i]);
      end;
    end
    else
    begin
      { 只分析：扫描 .lfm 出支持度报告（与控制台版相同内容） }
      lfmFiles := TStringList.Create;
      reports := TList.Create;
      try
        CollectFiles(SrcDir, '*.lfm', lfmFiles);
        if lfmFiles.Count = 0 then
          Lines.Add('没有找到 .lfm 文件')
        else
        begin
          for i := 0 to lfmFiles.Count - 1 do
          begin
            nd := ParseLfm(lfmFiles[i], err);
            if nd = nil then
            begin
              Lines.Add('[跳过] ' + lfmFiles[i] + ' (' + err + ')');
              Continue;
            end;
            r := TFormReport.Create;
            r.LfmFile := lfmFiles[i];
            r.Root := nd;
            r.Counts := TStringList.Create;
            r.Unknown := TStringList.Create;
            CollectCounts(nd, r.Counts, r.Unknown, True, Ctx.Matrix);
            reports.Add(r);
          end;
          for j := 0 to reports.Count - 1 do
          begin
            r := TFormReport(reports[j]);
            Lines.Add('== ' + ExtractFileName(r.LfmFile));
            for i := 0 to r.Counts.Count - 1 do
            begin
              lvl := Ctx.Matrix.Values[r.Counts[i]];
              Lines.Add(Format('   %-24s %3d  %s',
                [r.Counts[i], PtrInt(r.Counts.Objects[i]), StatusText(lvl)]));
            end;
          end;
          ReportPath := IncludeTrailingPathDelimiter(SrcDir) + 'lwreport.md';
          WriteReport(Ctx, reports, ReportPath);
          Lines.Add('');
          Lines.Add('报告已写入 ' + ReportPath);
          OK := True;
        end;
      finally
        for i := 0 to reports.Count - 1 do
        begin
          r := TFormReport(reports[i]);
          r.Counts.Free;
          r.Unknown.Free;
          r.Free;
        end;
        reports.Free;
        lfmFiles.Free;
      end;
    end;
  except
    on E: Exception do
    begin
      OK := False;
      Lines.Add('== 异常 ==');
      Lines.Add(E.ClassName + ': ' + E.Message);
    end;
  end;
end;

{ ---------------- 窗体 ---------------- }

procedure TConvertPanelForm.FormCreate(Sender: TObject);
begin
  Caption := 'lazarusWeb 工程转换器 ' + VERSION;
  FLastReport := '';
  PickMonoFont;
  sbMain.SimpleText :=
    '选择一个普通 Lazarus 工程目录：先「支持度分析」，或直接「开始转换」。';
  { 任务进行中禁止关窗：Job 是 FreeOnTerminate 线程，窗体一关，
    OnTerminate 的 Synchronize 就打在已释放的窗体上（AV/退出卡死） }
  OnCloseQuery := @FormCloseQuery;
end;

procedure TConvertPanelForm.FormCloseQuery(Sender: TObject;
  var CanClose: boolean);
begin
  CanClose := FJob = nil;
  if not CanClose then
    Log('转换/分析进行中，等任务完成后再关闭窗口。');
end;

{ 等宽字体：LFM 里写的是 Consolas（Windows 默认有），换到 Linux/macOS 时挑一个 }
procedure TConvertPanelForm.PickMonoFont;

  function HasFont(const AName: string): Boolean;
  var
    i: Integer;
  begin
    for i := 0 to Screen.Fonts.Count - 1 do
      if SameText(Screen.Fonts[i], AName) then
      begin
        Result := True;
        Exit;
      end;
    Result := False;
  end;

var
  cand: array[0..3] of string;
  i: Integer;
begin
  if HasFont('Consolas') then Exit;
  cand[0] := 'DejaVu Sans Mono';
  cand[1] := 'Liberation Mono';
  cand[2] := 'Menlo';
  cand[3] := 'Courier New';
  for i := Low(cand) to High(cand) do
    if HasFont(cand[i]) then
    begin
      memLog.Font.Name := cand[i];
      Exit;
    end;
end;

procedure TConvertPanelForm.Log(const ALine: string);
begin
  memLog.Lines.Add(ALine);
end;

{ lazarusWeb 根：源目录向上找 -> exe 目录向上找 -> 工具目录上级（repo 根）}
procedure TConvertPanelForm.ResolveRoot;
var
  r, exeDir: string;
begin
  r := Trim(edRoot.Text);
  if (r <> '') and DirectoryExists(r) then Exit;
  r := FindLazarusWebRoot(Trim(edSrc.Text));
  if r = '' then
  begin
    exeDir := ExtractFileDir(ExpandFileName(ParamStr(0)));
    r := FindLazarusWebRoot(exeDir);
  end;
  if r = '' then
    r := ExcludeTrailingPathDelimiter(ExtractFileDir(exeDir));
  edRoot.Text := r;
end;

procedure TConvertPanelForm.SetBusy(ABusy: Boolean);
begin
  btnAnalyze.Enabled := not ABusy;
  btnConvert.Enabled := not ABusy;
  edSrc.Enabled := not ABusy;
  edOut.Enabled := not ABusy;
  edRoot.Enabled := not ABusy;
  if ABusy then
    sbMain.SimpleText := '处理中...'
  else
    sbMain.SimpleText := '完成。';
end;

procedure TConvertPanelForm.btnBrowseSrcClick(Sender: TObject);
var
  d: string;
begin
  d := Trim(edSrc.Text);
  if SelectDirectory('选择 Lazarus 工程目录', '', d) then
  begin
    edSrc.Text := ExcludeTrailingPathDelimiter(d);
    ResolveRoot;
  end;
end;

procedure TConvertPanelForm.btnBrowseOutClick(Sender: TObject);
var
  d: string;
begin
  d := Trim(edOut.Text);
  if SelectDirectory('选择输出目录（不存在可先新建）', '', d) then
    edOut.Text := ExcludeTrailingPathDelimiter(d);
end;

{ 公共校验 + 起线程；AConvert=True 转换、False 分析 }
function TConvertPanelForm.StartJob(AConvert: Boolean): Boolean;
var
  src, outd, lpiFile, lprFile: string;
begin
  Result := False;
  if FJob <> nil then Exit;
  src := ExcludeTrailingPathDelimiter(ExpandFileName(Trim(edSrc.Text)));
  if (src = '') or (not DirectoryExists(src)) then
  begin
    ShowMessage('源工程目录不存在');
    Exit;
  end;
  if not FindProjectIn(src, lpiFile, lprFile) then
  begin
    ShowMessage('在 ' + src + ' 里没有找到 .lpi/.lpr 工程文件');
    Exit;
  end;

  outd := Trim(edOut.Text);
  if outd = '' then
  begin
    { 自动建议：源目录 + _web }
    outd := src + '_web';
    edOut.Text := outd;
    Log('（输出目录留空，自动使用 ' + outd + '）');
  end;
  outd := ExcludeTrailingPathDelimiter(ExpandFileName(outd));
  if AConvert and SameText(outd, src) then
  begin
    ShowMessage('输出目录不能等于源目录（转换会改写源码，请换一个目录）');
    Exit;
  end;
  ResolveRoot;

  FJob := TConvJob.Create;
  FJob.SrcDir := src;
  FJob.OutDir := outd;
  FJob.Root := ExcludeTrailingPathDelimiter(ExpandFileName(Trim(edRoot.Text)));
  FJob.LpiFile := lpiFile;
  FJob.LprFile := lprFile;
  FJob.Convert := AConvert;
  FJob.OnTerminate := @JobDone;
  SetBusy(True);
  Log('');
  if AConvert then
    Log('== 开始转换: ' + src + '  ->  ' + outd)
  else
    Log('== 支持度分析: ' + src);
  FJob.Start;
  Result := True;
end;

procedure TConvertPanelForm.btnAnalyzeClick(Sender: TObject);
begin
  StartJob(False);
end;

procedure TConvertPanelForm.btnConvertClick(Sender: TObject);
begin
  StartJob(True);
end;

{ 线程结束回调（主线程）：回填结果、复位 UI。
  注意：FreeOnTerminate=True，这里只读 job 的字段，绝不 Free —— 见构造函数注释。 }
procedure TConvertPanelForm.JobDone(Sender: TObject);
var
  i: Integer;
  job: TConvJob;
begin
  job := FJob;
  FJob := nil;
  SetBusy(False);
  if job <> nil then
  begin
    for i := 0 to job.Lines.Count - 1 do
      Log(job.Lines[i]);
    if job.ReportPath <> '' then
      FLastReport := job.ReportPath;
    if job.Convert then
    begin
      if job.OK then
        sbMain.SimpleText := '转换完成，报告: ' + FLastReport
      else
        sbMain.SimpleText := '转换失败，见上方警告。';
    end
    else
      sbMain.SimpleText := '分析完成，报告: ' + FLastReport;
  end;
end;

procedure TConvertPanelForm.btnReportClick(Sender: TObject);
begin
  if (FLastReport <> '') and FileExists(FLastReport) then
    OpenDocument(FLastReport)
  else
    ShowMessage('还没有生成过报告，先「支持度分析」或「开始转换」。');
end;

procedure TConvertPanelForm.btnOpenOutClick(Sender: TObject);
var
  d: string;
begin
  d := ExpandFileName(Trim(edOut.Text));
  if (d = '') or (not DirectoryExists(d)) then
  begin
    ShowMessage('输出目录还不存在，先「开始转换」。');
    Exit;
  end;
  OpenDocument(IncludeTrailingPathDelimiter(d));
end;

end.
