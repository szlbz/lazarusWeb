{
  lazarusWeb :: dbaware 演示 —— 报表中心（独立窗体，非模态）
  ------------------------------------------------------------------
  这一页演示两件事：

  1) 多窗体切换
     主窗体 / 报表中心都是独立的 TLWForm，浏览器里是两个窗口。
     切换 = 一个 Visible:=False、另一个 Visible:=True（框架把它翻译成
     session 的 hide/show 指令）。返回主界面时主窗体的数据、网格位置
     原样还在 —— 服务端对象一直活着，这正是 uniGUI 的窗体会话模型。

  2) 打印 / 导出
     报表由 lwreport.TLWReport 描述（列、对齐、汇总、纸张），
     三种出口共用一份定义：
       预览 / 打印  -> 生成可打印 HTML，塞进 TLWPDFFrame 的 iframe；
                      点"打印"时 URL 带 #print，页面自动弹浏览器打印
                      对话框（在对话框里可选"另存为 PDF"）
       导出 CSV     -> UTF-8 BOM，Excel 双击不乱码
       导出 Excel   -> 真正的 xlsx（OOXML），带表头样式、冻结窗格、合计行
     只读账号（guest）不允许导出，用按钮禁用来体现权限差别。
}
unit uReport;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Forms, Controls, Graphics, StdCtrls, ComCtrls,
  DB, sqldb, sqlite3conn, lwform, lwweb, lwreport, lwbase;

type
  TReportForm = class(TLWForm)
  published
    { ---- 控件：名字必须和 uReport.lfm 里的对象名一致，LFM 加载时按名字绑定 ---- }
    lblTitle: TLabel;
    lblSourceCap: TLabel;
    cbSource: TComboBox;
    btnPreview: TButton;
    btnPrint: TButton;
    btnCSV: TButton;
    btnXLSX: TButton;
    btnBack: TButton;
    lblInfo: TLabel;
    lblHint: TLabel;
    view: TLWPDFFrame;

    { ---- 事件（LFM 里按名字绑定）---- }
    procedure FormCreate(Sender: TObject);
    procedure cbSourceChange(Sender: TObject);
    procedure btnPreviewClick(Sender: TObject);
    procedure btnPrintClick(Sender: TObject);
    procedure btnCSVClick(Sender: TObject);
    procedure btnXLSXClick(Sender: TObject);
    procedure btnBackClick(Sender: TObject);
  private
    FConn: TSQLite3Connection;
    FTrans: TSQLTransaction;
    FQry: TSQLQuery;
    FLastFile: string;
    FBuildNo: Integer;
    procedure OpenDB;
    procedure CloseDB;
    function MakeReport: TLWReport;
    procedure BuildPreview(APrint: Boolean);
    procedure SyncPerm;
  public
    { 主窗体：返回时要用它把主界面显示回来 }
    HostForm: TCustomForm;
    destructor Destroy; override;
    { 打开报表中心时调用：套用权限、生成第一版预览 }
    procedure RefreshReport;
    { 权限变了（换账号登录）之后重新套一遍 }
    procedure SyncPermForCurrentUser;
  end;

implementation

{$R *.lfm}

uses
  uLogin;

{ 界面全在 uReport.lfm 里：标题、按钮、预览框都是设计期布局，
  代码这边只接手"非可视"的部分 —— 套权限、拉数据。 }
procedure TReportForm.FormCreate(Sender: TObject);
begin
  SyncPerm;
end;

destructor TReportForm.Destroy;
begin
  CloseDB;
  if (FLastFile <> '') and FileExists(FLastFile) then
    DeleteFile(FLastFile);
  inherited Destroy;
end;

{ ---------- 数据 ---------- }

procedure TReportForm.OpenDB;
begin
  if (FConn <> nil) and FConn.Connected then Exit;
  FTrans := TSQLTransaction.Create(Self);
  FTrans.Name := 'FTransRpt';
  FConn := TSQLite3Connection.Create(Self);
  FConn.Name := 'FConnRpt';
  FConn.DatabaseName := AwareDBFile;
  FConn.Transaction := FTrans;
  FTrans.Database := FConn;
  FConn.Params.Add('journal_mode=WAL');
  FConn.Open;
  FConn.ExecuteDirect('PRAGMA busy_timeout=10000');

  FQry := TSQLQuery.Create(Self);
  FQry.Name := 'FQryRpt';
  FQry.Database := FConn;
  FQry.Transaction := FTrans;
end;

procedure TReportForm.CloseDB;
begin
  if FQry <> nil then
  begin
    if FQry.Active then FQry.Close;
    FreeAndNil(FQry);
  end;
  if FConn <> nil then
  begin
    if FConn.Connected then FConn.Close;
    FreeAndNil(FConn);
  end;
  if FTrans <> nil then FreeAndNil(FTrans);
end;

function TReportForm.MakeReport: TLWReport;
var
  rpt: TLWReport;
begin
  OpenDB;
  if FQry.Active then FQry.Close;

  if cbSource.ItemIndex = 0 then
  begin
    FQry.SQL.Text :=
      'SELECT code, name, price, stock, price * stock AS amount, tag, cat_id ' +
      'FROM items ORDER BY code';
    FQry.Open;
    rpt := TLWReport.Create(nil);
    rpt.DataSet := FQry;
    rpt.Title := '商品清单';
    rpt.SubTitle := '数据源：items · 含金额合计（单价 × 库存）';
    rpt.Columns.AddCol('编码', 'code', 26);
    rpt.Columns.AddCol('名称', 'name', 52);
    rpt.Columns.AddCol('单价', 'price', 24, taRightJustify, rsSum);
    rpt.Columns.AddCol('库存', 'stock', 18, taRightJustify, rsSum);
    rpt.Columns.AddCol('金额', 'amount', 30, taRightJustify, rsSum);
    rpt.Columns.AddCol('标签', 'tag', 20, taCenter);
    rpt.Columns.AddCol('分类', 'cat_id', 16, taCenter);
    rpt.Columns[2].Mask := '#,##0.00';
    rpt.Columns[3].Mask := '#,##0';
    rpt.Columns[4].Mask := '#,##0.00';
  end
  else
  begin
    FQry.SQL.Text :=
      'SELECT code, name, qty, price, qty * price AS amount FROM bigitems ORDER BY code';
    FQry.Open;
    rpt := TLWReport.Create(nil);
    rpt.DataSet := FQry;
    rpt.Title := '库存大表明细';
    rpt.SubTitle := '数据源：bigitems · 240 行，用于验证多页打印（表头逐页重复）';
    rpt.Columns.AddCol('编码', 'code', 30);
    rpt.Columns.AddCol('名称', 'name', 62);
    rpt.Columns.AddCol('数量', 'qty', 20, taRightJustify, rsSum);
    rpt.Columns.AddCol('单价', 'price', 26, taRightJustify);
    rpt.Columns.AddCol('金额', 'amount', 34, taRightJustify, rsSum);
    rpt.Columns[3].Mask := '#,##0.00';
    rpt.Columns[4].Mask := '#,##0.00';
  end;

  rpt.OperatorName := LoginUserName;
  rpt.FooterText := '制表：' + LoginUserName + '（' + LoginUserRole + '）· ' +
    '本报表由 lazarusWeb 生成，可用浏览器打印或另存为 PDF。';
  MakeReport := rpt;
end;

{ ---------- 生成 ---------- }

function ReportTempName(ABuildNo: Integer): string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    Format('lwreport_%.8d_%s.html', [ABuildNo,
      FormatDateTime('hhnnsszzz', Now)]);
end;

procedure TReportForm.BuildPreview(APrint: Boolean);
var
  rpt: TLWReport;
  fn, old: string;
begin
  Inc(FBuildNo);
  fn := ReportTempName(FBuildNo);
  rpt := nil;
  try
    try
      rpt := MakeReport;
      if not rpt.SaveHTML(fn) then
      begin
        lblInfo.Caption := '报表生成失败：临时目录不可写（' + fn + '）';
        Exit;
      end;
      lblInfo.Caption := Format('%s · %d 行 · 纸张 %s%s', [rpt.Title, rpt.RowCount,
        rpt.PageSize, BoolToStr(rpt.Landscape, ' 横向', ' 纵向')]);
    except
      on E: Exception do
      begin
        lblInfo.Caption := '报表生成失败：' + E.Message;
        Exit;
      end;
    end;
  finally
    rpt.Free;
  end;

  { 换文件 -> 换查看令牌 -> iframe 重新加载。
    #print 让预览页自己弹打印对话框（对应"打印"按钮）。 }
  old := FLastFile;
  FLastFile := fn;
  view.URLSuffix := IfThen(APrint, '#print', '');
  view.PDFFile := fn;
  if (old <> '') and (old <> fn) and FileExists(old) then
    DeleteFile(old);
end;

procedure TReportForm.RefreshReport;
begin
  BuildPreview(False);
end;

procedure TReportForm.SyncPermForCurrentUser;
begin
  SyncPerm;
end;

procedure TReportForm.SyncPerm;
var
  isGuest: Boolean;
begin
  isGuest := SameText(LoginUserRole, 'guest');
  btnCSV.Enabled := not isGuest;
  btnXLSX.Enabled := not isGuest;
  btnPrint.Enabled := True;
  if isGuest then
    lblHint.Caption :=
      '当前为只读账号（guest）：可以预览和打印，导出已禁用 —— 权限控制在业务代码里做，' +
      '框架只负责把 Enabled 同步到浏览器。'
  else
    lblHint.Caption :=
      '预览页顶部有「打印 / 另存为 PDF」按钮（浏览器打印引擎，A4 版式、表头逐页重复）；' +
      '本页的「打印…」会直接弹出打印对话框。';
end;

{ ---------- 事件 ---------- }

procedure TReportForm.cbSourceChange(Sender: TObject);
begin
  BuildPreview(False);
end;

procedure TReportForm.btnPreviewClick(Sender: TObject);
begin
  BuildPreview(False);
end;

procedure TReportForm.btnPrintClick(Sender: TObject);
begin
  BuildPreview(True);
end;

procedure TReportForm.btnCSVClick(Sender: TObject);
var
  rpt: TLWReport;
  fn: string;
begin
  rpt := nil;
  fn := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'lwreport_' + FormatDateTime('hhnnsszzz', Now) + '.csv';
  try
    try
      rpt := MakeReport;
      if rpt.SaveCSV(fn) then
      begin
        SendFile(fn, 'dbaware_report.csv');
        lblInfo.Caption := Format('已导出 CSV：%s（%d 行）', [ExtractFileName(fn), rpt.RowCount]);
      end
      else
        lblInfo.Caption := 'CSV 导出失败';
    except
      on E: Exception do
        lblInfo.Caption := 'CSV 导出失败：' + E.Message;
    end;
  finally
    rpt.Free;
  end;
end;

procedure TReportForm.btnXLSXClick(Sender: TObject);
var
  rpt: TLWReport;
  fn: string;
begin
  rpt := nil;
  fn := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'lwreport_' + FormatDateTime('hhnnsszzz', Now) + '.xlsx';
  try
    try
      rpt := MakeReport;
      if rpt.SaveXLSX(fn) then
      begin
        SendFile(fn, 'dbaware_report.xlsx');
        lblInfo.Caption := Format('已导出 Excel：%s（%d 行）',
          [ExtractFileName(fn), rpt.RowCount]);
      end
      else
        lblInfo.Caption := 'Excel 导出失败';
    except
      on E: Exception do
        lblInfo.Caption := 'Excel 导出失败：' + E.Message;
    end;
  finally
    rpt.Free;
  end;
end;

procedure TReportForm.btnBackClick(Sender: TObject);
begin
  { 多窗体切换：先亮主窗体、再藏自己。
    顺序不能反 —— 反了会有一瞬间两个窗口都不显示 }
  if (HostForm <> nil) and (not HostForm.Visible) then
    HostForm.Visible := True;
  Self.Visible := False;
end;

end.
