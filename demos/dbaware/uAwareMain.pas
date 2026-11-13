{
  lazarusWeb :: 演示 6 —— 综合演示：DB 感知 + HTML + PDF + 图表 + 大表
  ------------------------------------------------------------------
  已从"DB 控件全家桶"升级为多功能综合 demo（对照 uniGUI 的组织方式），
  用 TPageControl 分成五个页：

    tsDB   数据感知  —— 11 个 DB 控件 + TDBNavigator（原有内容原样保留）
    tsHTML HTML 展示 —— TLWHTMLFrame（对应 uniGUI 的 uniHTMLFrame）：
                        面板里渲染一段任意 HTML，上面一个 TMemo 编辑
                        源码，点"应用"立即在下方面板刷新
    tsPDF  PDF 展示  —— TLWPDFFrame（对应 uniGUI 的 uniPDFFrame）：
                        iframe + 浏览器自带 PDF 查看器。可"生成示例 PDF"
                        （服务端 Pascal 运行时手写 PDF 语法，不引第三方库），
                        也可用 TLWFileUpload 上传本地 PDF 来显示。
    tsChart 图表/其它 —— TLWChart（对应 uniGUI 的 uniChart，ext charts 包）
                        线/柱/饼切换 + 从数据库统计；TDateEdit/TTimeEdit
                        日期时间选择器；TLWForm.ShowToast 轻提示按钮。
    tsBig  大表分页  —— TLWDBGrid（对应 uniDBGrid 的分页/过滤/汇总）：
                        240 行演示数据，每页 20 行 + 过滤条 + 库存合计。

  PDF 不把服务端路径暴露给浏览器：TLWPDFFrame 通过 lwdownload 的
  "查看令牌"（可重复访问、每次序列化续期）换回 /lw/view?t=<令牌>。

  原有 DB 演示的行为全部不变：左边点一行，右边所有控件跟着走；
  保存落库 / 取消回滚 / 导航 / 网格单元格编辑照旧。
}
unit uAwareMain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ComCtrls, Menus,
  Dialogs, DB, DBCtrls, DBGrids, sqldb, sqlite3conn, EditBtn, lwform, lwdbnav,
  lwweb, lwfileupload, lwchart, lwdbgrid, lwui;

type
  TAwareForm = class(TLWForm)

    { ---- LFM 组件：名字必须和 uAwareMain.lfm 一致（设计器可直接改）---- }
    pcMain: TPageControl;
    tsDB: TTabSheet;
    lblTitle: TLabel;
    lblUser: TLabel;
    grdItems: TDBGrid;
    lblCodeCap: TLabel;
    lblCode: TDBText;
    lblNameCap: TLabel;
    edName: TDBEdit;
    lblPriceCap: TLabel;
    edPrice: TDBEdit;
    lblStockCap: TLabel;
    edStock: TDBEdit;
    lblMemoCap: TLabel;
    mmMemo: TDBMemo;
    chkActive: TDBCheckBox;
    lblTagCap: TLabel;
    cbTag: TDBComboBox;
    lblTagListCap: TLabel;
    lbTag: TDBListBox;
    rgState: TDBRadioGroup;
    lblCatCap: TLabel;
    lkCat: TDBLookupComboBox;
    lblCatListCap: TLabel;
    lkCatList: TDBLookupListBox;
    imgPic: TDBImage;
    btnSave: TButton;
    btnCancel: TButton;
    btnPrev: TButton;
    btnNext: TButton;
    navMain: TLWDBNavigator;
    lblState: TLabel;
    lblHint: TLabel;
    tsHTML: TTabSheet;
    lblHtmlTitle: TLabel;
    mmHtml: TMemo;
    btnHtmlApply: TButton;
    htmlFrame: TLWHTMLFrame;
    tsPDF: TTabSheet;
    lblPdfTitle: TLabel;
    btnPdfSample: TButton;
    upPdf: TLWFileUpload;
    lblPdfName: TLabel;
    pdfFrame: TLWPDFFrame;
    tsChart: TTabSheet;
    lblChartTitle: TLabel;
    chartMain: TLWChart;
    btnChartLine: TButton;
    btnChartBar: TButton;
    btnChartPie: TButton;
    btnChartDB: TButton;
    lblDateCap: TLabel;
    deDate: TDateEdit;
    lblDateVal: TLabel;
    lblTimeCap: TLabel;
    teTime: TTimeEdit;
    lblTimeVal: TLabel;
    lblToastCap: TLabel;
    btnToastOk: TButton;
    btnToastErr: TButton;
    gauge: TLWGauge;
    btnGauge: TButton;
    lblGaugeVal: TLabel;
    btnMaskOn: TButton;
    btnMaskOff: TButton;
    lblColorCap: TLabel;
    cpColor: TLWColorPicker;
    lblColorVal: TLabel;
    lblAjaxCap: TLabel;
    frAjax: TLWHTMLFrame;
    tsBig: TTabSheet;
    lblBigTitle: TLabel;
    grdBig: TLWDBGrid;
    lblBigCodeCap: TLabel;
    lblBigCode: TDBText;
    mmMain: TMainMenu;
    miFile: TMenuItem;
    miLogout: TMenuItem;
    miExit: TMenuItem;
    miWin: TMenuItem;
    miOpenReport: TMenuItem;
    miHelp: TMenuItem;
    miAbout: TMenuItem;
    pmGrid: TPopupMenu;
    miGridRefresh: TMenuItem;
    miGridCount: TMenuItem;

    { ---- 事件（LFM 里按名字绑定）---- }
    procedure FormCreate(Sender: TObject);
    procedure navMainClick(Sender: TObject; Button: TNavigateBtn);
    procedure btnSaveClick(Sender: TObject);
    procedure btnCancelClick(Sender: TObject);
    procedure btnPrevClick(Sender: TObject);
    procedure btnNextClick(Sender: TObject);
    procedure grdTitleClick(Column: TColumn);
    procedure btnHtmlApplyClick(Sender: TObject);
    procedure btnPdfSampleClick(Sender: TObject);
    procedure upPdfUpload(Sender: TObject; const AFileName: string);
    procedure btnChartLineClick(Sender: TObject);
    procedure btnChartBarClick(Sender: TObject);
    procedure btnChartPieClick(Sender: TObject);
    procedure btnChartDBClick(Sender: TObject);
    procedure deDateChange(Sender: TObject);
    procedure teTimeChange(Sender: TObject);
    procedure btnToastOkClick(Sender: TObject);
    procedure btnToastErrClick(Sender: TObject);
    procedure btnGaugeClick(Sender: TObject);
    procedure btnMaskOnClick(Sender: TObject);
    procedure btnMaskOffClick(Sender: TObject);
    procedure ColorChanged(Sender: TObject);
    procedure miGridRefreshClick(Sender: TObject);
    procedure miGridCountClick(Sender: TObject);
    procedure miOpenReportClick(Sender: TObject);
    procedure miAboutClick(Sender: TObject);
    procedure miLogoutClick(Sender: TObject);
    procedure miExitClick(Sender: TObject);
  private
    FConn: TSQLite3Connection;
    FTrans: TSQLTransaction;
    FQry: TSQLQuery;
    FQryCat: TSQLQuery;
    FDs: TDataSource;
    FDsCat: TDataSource;
    FConn2: TSQLite3Connection;  { 独立连接：大表只读统计，与业务表互不干扰 }
    FTrans2: TSQLTransaction;
    FQryBig: TSQLQuery;
    FDsBig: TDataSource;
    { 报表中心窗体（非模态，切换显示） }
    FReportForm: TCustomForm;
    procedure SetupData;
    procedure EnsureSchema;
    procedure SeedData;
    procedure Requery(AKeepId: Integer = -1);
    procedure UpdateState(Sender: TObject; Field: TField);
    procedure SetChartStatic;
    procedure OpenReportForm;
    procedure UpdateUserLabel;
  public
    destructor Destroy; override;
    { 主窗体被"切换回来"时刷新当前用户（注销后换个账号登录也能显示对） }
    procedure SetVisible(AValue: Boolean); override;
  end;

implementation

{$R *.lfm}

uses
  Math, lwbase, lwapp, uLogin, uReport;

const
  { 24x24 的 PNG（深蓝边框 + 橙色内框），直接存进 BLOB 字段。
    演示用图片不值得依赖外部文件，所以内嵌。 }
  DEMO_PNG: array[0..95] of Byte = (
    $89, $50, $4E, $47, $0D, $0A, $1A, $0A, $00, $00, $00, $0D,
    $49, $48, $44, $52, $00, $00, $00, $18, $00, $00, $00, $18,
    $08, $02, $00, $00, $00, $6F, $15, $AA, $AF, $00, $00, $00,
    $27, $49, $44, $41, $54, $78, $DA, $63, $D0, $70, $AB, $A0,
    $0A, $62, $18, $21, $06, $7D, $E8, $D1, $20, $09, $8D, $1A,
    $34, $6A, $D0, $A8, $41, $A3, $06, $D1, $CA, $A0, $D1, $32,
    $1B, $2B, $02, $00, $F2, $B3, $C3, $9F, $F9, $E8, $12, $F6,
    $00, $00, $00, $00, $49, $45, $4E, $44, $AE, $42, $60, $82);

{ 运行时手写一个最简但合法的单页 PDF（PDF 1.4 + 标准 14 字体），
  不依赖任何第三方库。内容只能用 ASCII（标准字体不带 CJK 字形）。
  xref 偏移量按行长度累加算出来，每行以 CRLF 结尾、xref 条目固定 20 字节。 }
function WriteSamplePDF(const AFn: string): Boolean;
var
  all: TStringList;     { 整个 PDF 逐行 }
  stream: TStringList;  { content stream 逐行 }
  offs: array[1..6] of Integer;
  xrefOff, i, len: Integer;
  fs: TFileStream;
  s: string;

  function Pad10(N: Integer): string;
  begin
    Result := IntToStr(N);
    while Length(Result) < 10 do
      Result := '0' + Result;
  end;

begin
  Result := False;
  stream := TStringList.Create;
  all := TStringList.Create;
  try
    { content stream：标题 + 分隔线 + 两段说明 + 三条"表格行"色块 }
    stream.Add('BT /F2 22 Tf 50 750 Td (lazarusWeb Demo Report) Tj ET');
    stream.Add('0.2 0.4 0.75 RG');
    stream.Add('2 w');
    stream.Add('50 738 m 562 738 l S');
    stream.Add('BT /F1 11 Tf 50 712 Td (Generated at runtime by the Pascal demo program.) Tj ET');
    stream.Add('BT /F1 11 Tf 50 694 Td (No third-party PDF library is used - just plain PDF syntax.) Tj ET');
    stream.Add('BT /F1 11 Tf 50 676 Td (Served through /lw/view with a repeatable view token.) Tj ET');
    stream.Add('0.85 0.92 1 rg');
    stream.Add('50 620 250 26 re f');
    stream.Add('0 0 0 RG');
    stream.Add('BT /F1 11 Tf 58 628 Td (Row 1 - grid style demo) Tj ET');
    stream.Add('0.95 0.88 0.88 rg');
    stream.Add('50 588 250 26 re f');
    stream.Add('0 0 0 RG');
    stream.Add('BT /F1 11 Tf 58 596 Td (Row 2 - grid style demo) Tj ET');
    stream.Add('0.9 0.96 0.86 rg');
    stream.Add('50 556 250 26 re f');
    stream.Add('0 0 0 RG');
    stream.Add('BT /F1 11 Tf 58 564 Td (Row 3 - grid style demo) Tj ET');

    { content stream 全文（\n 连接），算 /Length }
    s := '';
    for i := 0 to stream.Count - 1 do
      s := s + stream[i] + #10;
    len := Length(s);

    all.Add('%PDF-1.4');
    all.Add('1 0 obj');
    all.Add('<< /Type /Catalog /Pages 2 0 R >>');
    all.Add('endobj');
    all.Add('2 0 obj');
    all.Add('<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
    all.Add('endobj');
    all.Add('3 0 obj');
    all.Add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]');
    all.Add('/Resources << /Font << /F1 4 0 R /F2 5 0 R >> >>');
    all.Add('/Contents 6 0 R >>');
    all.Add('endobj');
    all.Add('4 0 obj');
    all.Add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
    all.Add('endobj');
    all.Add('5 0 obj');
    all.Add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>');
    all.Add('endobj');
    all.Add('6 0 obj');
    all.Add('<< /Length ' + IntToStr(len) + ' >>');
    all.Add('stream');
    for i := 0 to stream.Count - 1 do
      all.Add(stream[i]);
    all.Add('endstream');
    all.Add('endobj');

    { 按"行 + CRLF"累加偏移，记录对象起点与 xref 位置 }
    xrefOff := 0;
    for i := 0 to all.Count - 1 do
    begin
      s := all[i];
      if s = '1 0 obj' then offs[1] := xrefOff
      else if s = '2 0 obj' then offs[2] := xrefOff
      else if s = '3 0 obj' then offs[3] := xrefOff
      else if s = '4 0 obj' then offs[4] := xrefOff
      else if s = '5 0 obj' then offs[5] := xrefOff
      else if s = '6 0 obj' then offs[6] := xrefOff;
      Inc(xrefOff, Length(s) + 2);
    end;

    all.Add('xref');
    all.Add('0 7');
    all.Add(Pad10(0) + ' 65535 f');
    for i := 1 to 6 do
      all.Add(Pad10(offs[i]) + ' 00000 n');
    all.Add('trailer');
    all.Add('<< /Size 7 /Root 1 0 R >>');
    all.Add('startxref');
    all.Add(IntToStr(xrefOff));
    all.Add('%%EOF');

    try
      fs := TFileStream.Create(AFn, fmCreate);
      try
        for i := 0 to all.Count - 1 do
        begin
          s := all[i] + #13#10;
          fs.WriteBuffer(s[1], Length(s));
        end;
      finally
        fs.Free;
      end;
      Result := True;
    except
      Result := False;
    end;
  finally
    stream.Free;
    all.Free;
  end;
end;

procedure TAwareForm.FormCreate(Sender: TObject);
begin
  { 窗体外观全部来自 uAwareMain.lfm；这里只做两件事：
    ① 建连接/查询（数据库路径按 exe 走，写进 LFM 会变成绝对路径）；
    ② 把数据源接回控件 —— LFM 里没有数据库对象，这些引用是代码接的。 }
  SetupData;

  grdItems.DataSource := FDs;
  lblCode.DataSource := FDs;
  edName.DataSource := FDs;
  edPrice.DataSource := FDs;
  edStock.DataSource := FDs;
  mmMemo.DataSource := FDs;
  chkActive.DataSource := FDs;
  cbTag.DataSource := FDs;
  lbTag.DataSource := FDs;
  rgState.DataSource := FDs;
  lkCat.DataSource := FDs;
  lkCat.ListSource := FDsCat;
  lkCatList.DataSource := FDs;
  lkCatList.ListSource := FDsCat;
  imgPic.DataSource := FDs;
  navMain.DataSource := FDs;
  grdBig.DataSource := FDsBig;
  lblBigCode.DataSource := FDsBig;

  { 日期/时间要"现在"，不能把导出那一刻冻结进 LFM }
  deDate.Date := Now;
  teTime.Time := Now;
  lblDateVal.Caption := '选中：' + FormatDateTime('yyyy-mm-dd', deDate.Date);
  lblTimeVal.Caption := '选中：' + FormatDateTime('hh:nn:ss', teTime.Time);

  UpdateUserLabel;
  UpdateState(nil, nil);
end;

destructor TAwareForm.Destroy;
begin
  if FQry <> nil then FQry.Close;
  if FQryCat <> nil then FQryCat.Close;
  if FQryBig <> nil then FQryBig.Close;
  if FConn <> nil then FConn.Close;
  if FConn2 <> nil then FConn2.Close;
  inherited Destroy;
end;

{ ---------- 数据 ---------- }

procedure TAwareForm.SetupData;
begin
  FTrans := TSQLTransaction.Create(Self);
  FTrans.Name := 'FTrans';
  FConn := TSQLite3Connection.Create(Self);
  FConn.Name := 'FConn';
  FConn.DatabaseName := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
    'dbaware.db';
  FConn.Transaction := FTrans;
  FTrans.Database := FConn;
  { 和 db 演示同一套：WAL 必须走 Params，busy_timeout 走 PRAGMA }
  FConn.Params.Add('journal_mode=WAL');
  FConn.Open;
  FConn.ExecuteDirect('PRAGMA busy_timeout=10000');
  EnsureSchema;
  SeedData;

  FQryCat := TSQLQuery.Create(Self);
  FQryCat.Name := 'FQryCat';
  FQryCat.Database := FConn;
  FQryCat.Transaction := FTrans;
  FQryCat.SQL.Text := 'SELECT id, name FROM cats ORDER BY id';

  FDsCat := TDataSource.Create(Self);
  FDsCat.Name := 'FDsCat';
  FDsCat.DataSet := FQryCat;
  FQryCat.Open;

  FQry := TSQLQuery.Create(Self);
  FQry.Name := 'FQry';
  FQry.Database := FConn;
  FQry.Transaction := FTrans;
  FQry.SQL.Text :=
    'SELECT id, code, name, price, stock, active, tag, state, memo, cat_id, img ' +
    'FROM items ORDER BY id';
  { 只发 SQL、不提交事务 —— 提交由 btnSaveClick 显式做 }
  FQry.Options := FQry.Options + [sqoAutoApplyUpdates];

  FDs := TDataSource.Create(Self);
  FDs.Name := 'FDs';
  FDs.DataSet := FQry;
  FDs.OnDataChange := @UpdateState;
  FQry.Open;

  { ---- 大表（分页/过滤/汇总演示）：独立连接，只读，和业务事务互不干扰 ---- }
  FTrans2 := TSQLTransaction.Create(Self);
  FTrans2.Name := 'FTrans2';
  FConn2 := TSQLite3Connection.Create(Self);
  FConn2.Name := 'FConn2';
  FConn2.DatabaseName := FConn.DatabaseName;
  FConn2.Transaction := FTrans2;
  FTrans2.Database := FConn2;
  FConn2.Params.Add('journal_mode=WAL');
  FConn2.Open;
  FConn2.ExecuteDirect('PRAGMA busy_timeout=10000');

  FQryBig := TSQLQuery.Create(Self);
  FQryBig.Name := 'FQryBig';
  FQryBig.Database := FConn2;
  FQryBig.Transaction := FTrans2;
  FQryBig.SQL.Text := 'SELECT id, code, name, qty, price FROM bigitems ORDER BY id';

  FDsBig := TDataSource.Create(Self);
  FDsBig.Name := 'FDsBig';
  FDsBig.DataSet := FQryBig;
  FQryBig.Open;
end;

procedure TAwareForm.EnsureSchema;
begin
  FConn.ExecuteDirect(
    'CREATE TABLE IF NOT EXISTS items(id INTEGER PRIMARY KEY, code VARCHAR(20), ' +
    'name VARCHAR(60), price FLOAT, stock INTEGER, active INTEGER, ' +
    'tag VARCHAR(20), state INTEGER, memo VARCHAR(500), cat_id INTEGER, img BLOB)');
  FConn.ExecuteDirect(
    'CREATE TABLE IF NOT EXISTS cats(id INTEGER PRIMARY KEY, name VARCHAR(30))');
  FConn.ExecuteDirect(
    'CREATE TABLE IF NOT EXISTS bigitems(id INTEGER PRIMARY KEY, code VARCHAR(20), ' +
    'name VARCHAR(60), qty INTEGER, price FLOAT)');
  FConn.ExecuteDirect('CREATE UNIQUE INDEX IF NOT EXISTS ux_aw_code ON items(code)');
  FTrans.Commit;
end;

procedure TAwareForm.SeedData;
var
  q: TSQLQuery;
  ms: TMemoryStream;
  i: Integer;

  procedure Cat(AId: Integer; const AName: string);
  begin
    q.ParamByName('id').AsInteger := AId;
    q.ParamByName('name').AsString := AName;
    q.ExecSQL;
  end;

  procedure Item(AId: Integer; const ACode, AName: string; APrice: Double;
    AStock, AActive, AState, ACat: Integer; const ATag, AMemo: string);
  begin
    q.SQL.Text :=
      'INSERT INTO items(id,code,name,price,stock,active,tag,state,memo,cat_id,img) ' +
      'VALUES(:id,:code,:name,:price,:stock,:active,:tag,:state,:memo,:cat,:img)';
    q.ParamByName('id').AsInteger := AId;
    q.ParamByName('code').AsString := ACode;
    q.ParamByName('name').AsString := AName;
    q.ParamByName('price').AsFloat := APrice;
    q.ParamByName('stock').AsInteger := AStock;
    q.ParamByName('active').AsInteger := AActive;
    q.ParamByName('tag').AsString := ATag;
    q.ParamByName('state').AsInteger := AState;
    q.ParamByName('memo').AsString := AMemo;
    q.ParamByName('cat').AsInteger := ACat;
    q.ParamByName('img').LoadFromStream(ms, ftBlob);
    q.ExecSQL;
  end;

begin
  q := TSQLQuery.Create(nil);
  ms := TMemoryStream.Create;
  try
    q.Database := FConn;
    q.Transaction := FTrans;
    ms.WriteBuffer(DEMO_PNG, SizeOf(DEMO_PNG));
    ms.Position := 0;

    q.SQL.Text := 'SELECT COUNT(*) FROM cats';
    q.Open;
    if q.Fields[0].AsInteger = 0 then
    begin
      q.Close;
      q.SQL.Text := 'INSERT INTO cats(id,name) VALUES(:id,:name)';
      Cat(1, '外设');
      Cat(2, '显示');
      Cat(3, '存储');
    end
    else
      q.Close;

    q.SQL.Text := 'SELECT COUNT(*) FROM items';
    q.Open;
    if q.Fields[0].AsInteger = 0 then
    begin
      q.Close;
      Item(1, 'P1001', '机械键盘', 299.00, 12, 1, 1, 1, '热销', '青轴，87 键');
      Item(2, 'P1002', '无线鼠标', 99.00, 30, 0, 0, 1, '新品', '2.4G 双模');
      Item(3, 'P1003', '27 寸显示器', 1499.00, 5, 1, 1, 2, '清仓', '2K 165Hz');
    end
    else
      q.Close;

    { 大表演示数据：240 行，翻页/过滤/汇总才有得玩 }
    q.SQL.Text := 'SELECT COUNT(*) FROM bigitems';
    q.Open;
    if q.Fields[0].AsInteger = 0 then
    begin
      q.Close;
      q.SQL.Text := 'INSERT INTO bigitems(id,code,name,qty,price) ' +
        'VALUES(:id,:code,:name,:qty,:price)';
      for i := 1 to 240 do
      begin
        q.ParamByName('id').AsInteger := i;
        q.ParamByName('code').AsString := 'B' + Format('%.4d', [i]);
        q.ParamByName('name').AsString := '部件 ' + IntToStr(i);
        q.ParamByName('qty').AsInteger := (i * 7) mod 97 + 3;
        q.ParamByName('price').AsFloat := ((i * 13) mod 900) / 10 + 10;
        q.ExecSQL;
      end;
      FTrans.Commit;
    end
    else
      q.Close;
    FTrans.Commit;
  finally
    q.Free;
    ms.Free;
  end;
end;

procedure TAwareForm.Requery(AKeepId: Integer);
var
  keepId: Integer;
begin
  keepId := AKeepId;
  if keepId < 0 then
  begin
    keepId := 0;
    try
      if FQry.Active and (not FQry.IsEmpty) then
        keepId := FQry.FieldByName('id').AsInteger;
    except
    end;
  end;
  try
    if FQry.Active then FQry.Close;
    FQry.Open;
    if keepId > 0 then
      FQry.Locate('id', keepId, []);
  except
  end;
end;

{ ---------- 界面 ---------- }

{ ---------- 事件 ---------- }

procedure TAwareForm.btnHtmlApplyClick(Sender: TObject);
begin
  { 只改 TLWHTMLFrame.HTML：下一次协调时前端比较内容指纹，
    有变化才 update()，不会打断面板里其它内容 }
  htmlFrame.HTML.Assign(mmHtml.Lines);
end;

procedure TAwareForm.btnPdfSampleClick(Sender: TObject);
var
  fn: string;
begin
  fn := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'lw_sample_report.pdf';
  if WriteSamplePDF(fn) then
  begin
    pdfFrame.PDFFile := fn;
    lblPdfName.Caption := '当前文件：' + fn;
  end
  else
    lblPdfName.Caption := '示例 PDF 生成失败（临时目录不可写？）';
end;

procedure TAwareForm.upPdfUpload(Sender: TObject; const AFileName: string);
begin
  { 文件已由框架落到会话上传目录；把路径交给 PDF 帧即可 ——
    服务端下次序列化会为新文件签发新的查看令牌，iframe 自动换 src }
  pdfFrame.PDFFile := AFileName;
  lblPdfName.Caption := '当前文件：' + AFileName;
end;

procedure TAwareForm.UpdateState(Sender: TObject; Field: TField);
var
  st: string;
begin
  { 数据集 Open 时就会触发 OnDataChange，那会儿界面还没建出来（lblState = nil），
    这里必须挡一下 —— 否则构造阶段直接 AV。 }
  if lblState = nil then Exit;
  try
    case FQry.State of
      dsEdit: st := '编辑中';
      dsInsert: st := '新增中';
    else
      st := '浏览';
    end;
    lblState.Caption := Format('第 %d / %d 条 · %s · 编码 %s',
      [FQry.RecNo, FQry.RecordCount, st, FQry.FieldByName('code').AsString]);
  except
    { 数据集正好在关闭/重开时可能取不到字段，状态行留空即可 }
  end;
end;

procedure TAwareForm.navMainClick(Sender: TObject; Button: TNavigateBtn);
begin
  { 删除已在数据集里生效（缓存），这里把它落库并刷新；
    Commit 会关数据集，所以走 Requery 重开 }
  if Button = nbDelete then
  begin
    try
      FQry.ApplyUpdates;
      FTrans.Commit;
      Requery(-1);
      UpdateState(nil, nil);
      lblState.Caption := '已删除并落库';
    except
      on E: Exception do
        lblState.Caption := '删除失败：' + E.Message;
    end;
  end
  else if Button = nbRefresh then
  begin
    { 刷新 = 看到别人改过的数据：先 CommitRetaining 丢掉旧读快照
      （WAL 下不换快照，外部已提交的改动永远看不见），再重开数据集 }
    try
      if FQry.State in [dsEdit, dsInsert] then
        FQry.Cancel;
      if FTrans.Active then FTrans.CommitRetaining;
      Requery(-1);
      UpdateState(nil, nil);
      lblState.Caption := '已刷新';
    except
      on E: Exception do
        lblState.Caption := '刷新失败：' + E.Message;
    end;
  end;
end;

procedure TAwareForm.btnSaveClick(Sender: TObject);
var
  keepId: Integer;
begin
  { 两种待保存来源，统一走 Post + Commit：
    1. dsEdit/dsInsert —— 控件（DBEdit/DBMemo 等）改了一半，先 Post；
       sqoAutoApplyUpdates 会随之 ApplyUpdates 把 UPDATE 发进事务。
    2. 网格单元格编辑 —— 服务端已 Post（同样已 ApplyUpdates），
       数据集回到 dsBrowse，这里只欠一个 Commit。 }
  { Commit 会把数据集一起关掉，所以先把 id 记下来，重开后定位回去 }
  keepId := FQry.FieldByName('id').AsInteger;
  try
    { CommitRetaining：丢掉旧读快照，避免 WAL 下的 BUSY_SNAPSHOT；
      注意必须先 CommitRetaining 再 Post，Post 里的 ApplyUpdates 才能拿到新快照 }
    if FTrans.Active then FTrans.CommitRetaining;
    if FQry.State in [dsEdit, dsInsert] then
      FQry.Post;
    FTrans.Commit;
  except
    on E: Exception do
    begin
      lblState.Caption := '保存失败：' + E.Message;
      Exit;
    end;
  end;
  Requery(keepId);
  UpdateState(nil, nil);
  lblState.Caption := lblState.Caption + ' · 已保存';
end;

procedure TAwareForm.btnCancelClick(Sender: TObject);
begin
  if FQry.State in [dsEdit, dsInsert] then
    FQry.Cancel;
  UpdateState(nil, nil);
end;

procedure TAwareForm.btnPrevClick(Sender: TObject);
begin
  if FQry.State in [dsEdit, dsInsert] then FQry.Cancel;
  FQry.Prior;
  UpdateState(nil, nil);
end;

procedure TAwareForm.btnNextClick(Sender: TObject);
begin
  if FQry.State in [dsEdit, dsInsert] then FQry.Cancel;
  FQry.Next;
  UpdateState(nil, nil);
end;

procedure TAwareForm.grdTitleClick(Column: TColumn);
var
  fld: string;
begin
  fld := Column.FieldName;
  if fld = '' then Exit;
  if FQry.State in [dsEdit, dsInsert] then Exit;
  FQry.Close;
  FQry.SQL.Text :=
    'SELECT id, code, name, price, stock, active, tag, state, memo, cat_id, img ' +
    'FROM items ORDER BY ' + fld;
  FQry.Open;
  UpdateState(nil, nil);
end;

{ ---------- tsChart：图表 ---------- }

procedure TAwareForm.SetChartStatic;
begin
  chartMain.ChartType := ctLine;
  chartMain.Title := '月度销量（示例数据）';
  chartMain.Categories.Clear;
  chartMain.Categories.Add('一月');
  chartMain.Categories.Add('二月');
  chartMain.Categories.Add('三月');
  chartMain.Categories.Add('四月');
  chartMain.Categories.Add('五月');
  chartMain.Categories.Add('六月');
  chartMain.Series.Clear;
  with chartMain.Series.Add do begin Name := '销量'; Values.CommaText := '12,19,15,25,22,30'; end;
  with chartMain.Series.Add do begin Name := '退货'; Values.CommaText := '2,3,2,5,3,4'; end;
end;

procedure TAwareForm.btnChartLineClick(Sender: TObject);
begin
  SetChartStatic;
  chartMain.ChartType := ctLine;
end;

procedure TAwareForm.btnChartBarClick(Sender: TObject);
begin
  SetChartStatic;
  chartMain.ChartType := ctBar;
end;

procedure TAwareForm.btnChartPieClick(Sender: TObject);
begin
  SetChartStatic;
  chartMain.ChartType := ctPie;
end;

procedure TAwareForm.btnChartDBClick(Sender: TObject);
var
  q: TSQLQuery;
  catName: string;
  total: Double;
begin
  { 从数据库统计：分类汇总（对 cats 逐类查 items 求和），
    结果直接填进图表 —— 演示"图表数据来自运行时计算" }
  chartMain.ChartType := ctBar;
  chartMain.Title := '各分类金额合计（来自 SQLite）';
  chartMain.Categories.Clear;
  chartMain.Series.Clear;
  with chartMain.Series.Add do
  begin
    Name := '金额';
    Values.Clear;
  end;
  q := TSQLQuery.Create(nil);
  try
    q.Database := FConn;
    q.Transaction := FTrans;
    q.SQL.Text := 'SELECT name FROM cats ORDER BY id';
    q.Open;
    while not q.Eof do
    begin
      catName := q.Fields[0].AsString;
      with TSQLQuery.Create(nil) do
      try
        Database := FConn;
        Transaction := FTrans;
        SQL.Text := 'SELECT COALESCE(SUM(price),0) FROM items WHERE cat_id = ' +
          '(SELECT id FROM cats WHERE name = :n)';
        ParamByName('n').AsString := catName;
        Open;
        total := Fields[0].AsFloat;
        Close;
      finally
        Free;
      end;
      chartMain.Categories.Add(catName);
      chartMain.Series[0].Values.Add(FormatFloat('0.00', total));
      q.Next;
    end;
    q.Close;
  finally
    q.Free;
  end;
end;

{ ---------- tsChart：日期/时间选择器 ---------- }

procedure TAwareForm.deDateChange(Sender: TObject);
begin
  if lblDateVal <> nil then
    lblDateVal.Caption := '选中：' + FormatDateTime('yyyy-mm-dd', deDate.Date);
end;

procedure TAwareForm.teTimeChange(Sender: TObject);
begin
  if lblTimeVal <> nil then
    lblTimeVal.Caption := '选中：' + FormatDateTime('hh:nn:ss', teTime.Time);
end;

{ ---------- tsChart：Toast ---------- }

procedure TAwareForm.btnToastOkClick(Sender: TObject);
begin
  ShowToast('数据已保存到服务端 ✓', '成功');
end;

procedure TAwareForm.btnToastErrClick(Sender: TObject);
begin
  ShowToast('库存不足，请先补货再上架（示例错误提示）', '错误');
end;

{ ---------- 边缘控件：仪表盘 / 遮罩 / 取色器 / 右键菜单 ---------- }

procedure TAwareForm.btnGaugeClick(Sender: TObject);
begin
  { 每次 +10，超过 100 回到 0；服务端值一变，下一次协调浏览器就重画 SVG }
  gauge.Value := gauge.Value + 10;
  if gauge.Value > gauge.Max then gauge.Value := gauge.Min;
  lblGaugeVal.Caption := '当前值：' + FormatFloat('0.#', gauge.Value) + '%';
end;

procedure TAwareForm.btnMaskOnClick(Sender: TObject);
begin
  LWShowScreenMask('正在处理，请稍候…');
end;

procedure TAwareForm.btnMaskOffClick(Sender: TObject);
begin
  LWHideScreenMask;
end;

procedure TAwareForm.ColorChanged(Sender: TObject);
begin
  if lblColorVal <> nil then
    lblColorVal.Caption := '颜色：' + ColorToString(cpColor.Color);
end;

procedure TAwareForm.miGridRefreshClick(Sender: TObject);
begin
  if (FDsBig <> nil) and (FDsBig.DataSet <> nil) and FDsBig.DataSet.Active then
    FDsBig.DataSet.Refresh;
  ShowToast('大表已刷新', '提示');
end;

procedure TAwareForm.miGridCountClick(Sender: TObject);
var
  n: Integer;
begin
  n := 0;
  if (FDsBig <> nil) and (FDsBig.DataSet <> nil) then
    n := FDsBig.DataSet.RecordCount;
  ShowToast('当前数据集共 ' + IntToStr(n) + ' 行', '统计');
end;

{ ---------- 登录用户 / 多窗体切换 ---------- }

procedure TAwareForm.SetVisible(AValue: Boolean);
begin
  inherited SetVisible(AValue);
  if AValue then UpdateUserLabel;
end;

procedure TAwareForm.UpdateUserLabel;
begin
  if lblUser = nil then Exit;
  if LoginUserName = '' then
    lblUser.Caption := ''
  else
    lblUser.Caption := '当前用户：' + LoginUserName + '（' + LoginUserRole + '）';
end;

{ 打开报表中心：第一次创建，之后复用同一个实例 —— 报表里的数据源选择、
  预览位置都保留着，切回来接着看 }
procedure TAwareForm.OpenReportForm;
var
  rf: TReportForm;
begin
  if FReportForm = nil then
  begin
    rf := TReportForm.Create(Self);   { Owner = 主窗体：随主窗体一起释放 }
    rf.HostForm := Self;
    FReportForm := rf;
    rf.SyncPermForCurrentUser;
    rf.RefreshReport;                 { 先出第一版预览再显示，避免空白 iframe }
  end
  else if FReportForm is TReportForm then
    TReportForm(FReportForm).SyncPermForCurrentUser;

  { 窗体切换 = 先亮目标、再藏自己 }
  if not FReportForm.Visible then
    FReportForm.Visible := True;
  Visible := False;
end;

procedure TAwareForm.miOpenReportClick(Sender: TObject);
begin
  OpenReportForm;
end;

procedure TAwareForm.miAboutClick(Sender: TObject);
begin
  ShowMessage('lazarusWeb 综合演示（dbaware）' + LineEnding + LineEnding +
    '登录：TLWLoginForm + SQLite users 表' + LineEnding +
    '多窗体：主窗体 <-> 报表中心 切换' + LineEnding +
    '打印/导出：lwreport（HTML 打印预览 / CSV / XLSX）' + LineEnding + LineEnding +
    '当前用户：' + LoginUserName + '（' + LoginUserRole + '）');
end;

procedure TAwareForm.miLogoutClick(Sender: TObject);
var
  S: TLWSessionBase;
  loginForm: TCustomForm;
begin
  if FReportForm <> nil then
    FReportForm.Visible := False;
  { 清掉本会话的身份（不是全局变量，别的会话不受影响） }
  ClearLoginUser;

  S := LWCurrentSession;
  if S = nil then Exit;
  { 认证标记清掉之后，lwdispatch 只放行登录窗体上的控件事件 ——
    主窗体即使还活着，浏览器也点不动它的任何按钮 }
  S.Authenticated := False;
  Visible := False;

  { 会话里登记的登录窗体直接复用：不重复创建，字段内容也还在 }
  loginForm := S.LoginForm;
  if loginForm = nil then
  begin
    if TLWApp.CreateForm('LoginForm', loginForm) then
      S.LoginForm := loginForm
    else
      loginForm := nil;
  end;
  if loginForm <> nil then
    S.SessionShowForm(loginForm);
end;

procedure TAwareForm.miExitClick(Sender: TObject);
begin
  Close;
end;

end.
