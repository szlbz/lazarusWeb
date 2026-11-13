{
  lazarusWeb :: 文件上传 / 下载演示

  演示三件事：
    1. TLWFileUpload —— 浏览器选文件 → 上传 → 服务端 OnUpload 收到真实路径；
    2. TLWForm.SendFile —— 把服务端上的文件推给浏览器下载；
    3. TLWForm.SendText —— 现算一段文本（CSV 报表）直接当文件下发。

  上传目录不用自己建：控件没设 TargetFolder 时，框架会落到
  %TEMP%\lw_uploads\<会话号>\<控件名>\ 下。
}
unit uFileForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls,
  lwform, lwfileupload;

type
  TFileForm = class(TLWForm)
    lblTitle: TLabel;
    lblHint: TLabel;
    lblStatus: TLabel;
    lblList: TLabel;
    lblDrop: TLabel;
    btnUpload: TLWFileUpload;
    lstFiles: TListBox;
    btnDownload: TButton;
    btnExport: TButton;
    btnClear: TButton;
    mmoLog: TMemo;
    procedure FormCreate(Sender: TObject);
    procedure btnUploadUpload(Sender: TObject; const AFileName: string);
    procedure btnDownloadClick(Sender: TObject);
    procedure btnExportClick(Sender: TObject);
    procedure btnClearClick(Sender: TObject);
    procedure lstFilesDblClick(Sender: TObject);
  private
    { 与 lstFiles 一一对应的服务端全路径 }
    FPaths: TStringList;
    FTotalBytes: Int64;
    procedure Log(const S: string);
    procedure RefreshStatus;
    function SelectedPath: string;
  public
    destructor Destroy; override;
  end;

var
  FileForm: TFileForm;

implementation

{$R *.lfm}

destructor TFileForm.Destroy;
begin
  FPaths.Free;
  inherited Destroy;
end;

procedure TFileForm.FormCreate(Sender: TObject);
begin
  FPaths := TStringList.Create;
  FTotalBytes := 0;
  Log('窗体就绪。点"选择文件并上传…"，文件会先落到服务端，再触发 OnUpload。');
  Log('上传目录：' + IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'lw_uploads\<会话号>\btnUpload\');
  RefreshStatus;
end;

procedure TFileForm.Log(const S: string);
begin
  mmoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
  while mmoLog.Lines.Count > 300 do
    mmoLog.Lines.Delete(0);
end;

procedure TFileForm.RefreshStatus;
begin
  if FPaths.Count = 0 then
    lblStatus.Caption := '（还没有上传）'
  else
    lblStatus.Caption := Format('已上传 %d 个文件，共 %s KB',
      [FPaths.Count, FormatFloat('#,##0.0', FTotalBytes / 1024)]);
end;

function TFileForm.SelectedPath: string;
begin
  Result := '';
  if (lstFiles.ItemIndex >= 0) and (lstFiles.ItemIndex < FPaths.Count) then
    Result := FPaths[lstFiles.ItemIndex];
end;

{ 每个文件上传完成都会进来一次；多选时是多次调用 }
procedure TFileForm.btnUploadUpload(Sender: TObject; const AFileName: string);
var
  nm: string;
  sz: Int64;
  preview: string;
  fs: TFileStream;
  buf: array[0..255] of Char;
  n: Integer;
begin
  if not FileExists(AFileName) then
  begin
    Log('收到路径但文件不存在：' + AFileName);
    Exit;
  end;

  nm := ExtractFileName(AFileName);
  sz := 0;
  preview := '';
  try
    fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
    try
      sz := fs.Size;
      { 顺带演示"服务端真的能读到内容"：文本文件取前 200 字节做预览 }
      if LowerCase(ExtractFileExt(nm)) = '.txt' then
      begin
        n := fs.Read(buf, SizeOf(buf) - 1);
        if n > 0 then
        begin
          buf[n] := #0;
          preview := String(buf);
          if Length(preview) > 200 then preview := Copy(preview, 1, 200);
          preview := StringReplace(preview, #13, ' ', [rfReplaceAll]);
          preview := StringReplace(preview, #10, ' ', [rfReplaceAll]);
        end;
      end;
    finally
      fs.Free;
    end;
  except
    on E: Exception do
      Log('读取失败 ' + nm + ' : ' + E.Message);
  end;

  lstFiles.Items.Add(nm);
  FPaths.Add(AFileName);
  Inc(FTotalBytes, sz);
  RefreshStatus;

  Log(Format('OnUpload: %s  %s bytes  ->  %s',
    [nm, FormatFloat('#,##0', sz), AFileName]));
  if preview <> '' then
    Log('  预览: ' + preview);
end;

procedure TFileForm.btnDownloadClick(Sender: TObject);
var
  p: string;
begin
  p := SelectedPath;
  if p = '' then
  begin
    Log('请先在左边的列表里点一个文件。');
    Exit;
  end;
  if not FileExists(p) then
  begin
    Log('文件已被删除：' + p);
    Exit;
  end;
  Log('SendFile -> ' + ExtractFileName(p));
  SendFile(p);
end;

procedure TFileForm.btnExportClick(Sender: TObject);
var
  csv: TStringList;
  i: Integer;
  sz: Int64;
  fs: TFileStream;
begin
  csv := TStringList.Create;
  try
    csv.Add('序号,文件名,字节数,服务端路径');
    for i := 0 to FPaths.Count - 1 do
    begin
      if not FileExists(FPaths[i]) then Continue;
      fs := TFileStream.Create(FPaths[i], fmOpenRead or fmShareDenyWrite);
      try
        sz := fs.Size;
      finally
        fs.Free;
      end;
      csv.Add(Format('%d,%s,%d,%s', [i + 1, ExtractFileName(FPaths[i]), sz,
        FPaths[i]]));
    end;
    { SendText 写完临时文件就自动推给浏览器；
      AWithBOM=True 让 Excel 正确识别 UTF-8 中文 }
    SendText(csv.Text, '上传清单.csv', True);
    Log(Format('导出清单：%d 行 -> 上传清单.csv', [csv.Count - 1]));
  finally
    csv.Free;
  end;
end;

procedure TFileForm.btnClearClick(Sender: TObject);
begin
  { 只清界面，不删服务端文件 —— 演示里不做破坏性操作 }
  lstFiles.Items.Clear;
  FPaths.Clear;
  FTotalBytes := 0;
  RefreshStatus;
  Log('列表已清空（服务端文件保留）。');
end;

procedure TFileForm.lstFilesDblClick(Sender: TObject);
begin
  btnDownloadClick(Sender);
end;

end.
