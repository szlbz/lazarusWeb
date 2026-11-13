{
  lazarusWeb :: 全功能画廊
  ------------------------------------------------------------------
  一个窗体 + TPageControl 十二个分类页 + 底部公共事件日志：

    tsStd    标准控件    TLabel/TStaticText/TEdit/TMemo/TCheckBox/TRadioButton/
                         TListBox/TComboBox/TGroupBox/TScrollBox
    tsBtn    按钮        TButton/TBitBtn/TSpeedButton（分组互斥）
    tsEdit   扩展输入    TMaskEdit/TSpinEdit/TFloatSpinEdit/TLabeledEdit/
                         TDateEdit/TTimeEdit/TTrackBar/TUpDown/TProgressBar
    tsPanel  容器布局    TPanel/TSplitter/TRadioGroup/TCheckGroup/
                         TCheckListBox/TShape/TBevel
    tsGrid   网格列表    TStringGrid/TDrawGrid/TValueListEditor/TListView/TTreeView
    tsBar    工具条      TToolBar/TToolButton/TStatusBar
    tsChart  图表仪表    TLWChart(线/柱/饼)/TLWGauge/TLWColorPicker
    tsWeb    HTML/PDF    TLWHTMLFrame/TLWPDFFrame/TLWFileUpload
    tsDlg    对话框      ShowMessage/MessageDlg/InputBox/ShowToast/文件对话框/
                         模态二级窗体(uAbout)
    tsMisc   定时器动态  TTimer 时钟/TProgressBar 自动步进/动态创建控件/
                         SendText/SendFile 下载/会话遮罩
    tsDB     数据感知    sqlite(gallery.db) + TDBGrid/TDBEdit/TDBMemo/
                         TDBCheckBox/TDBComboBox + TLWDBNavigator，改一格即落库；
                         unit 列 PickList 下拉、made 列日期选择、active 列勾选框
                         （框架按字段类型自动出 cedit=2/3/4）
    tsBig    大表分页    TLWDBGrid：sqlite 1000 行、每页 50、过滤条、qty 汇总

  ------------------------------------------------------------------
  界面全部在设计期做好（ugallery.lfm）—— 12 个页签、60+ 控件的位置、
  标题、项目列表、表格列、对齐方式、事件关联都写在 lfm 里，可以在 IDE
  里直接打开改。本单元只保留三类代码：

    1) 数据：sqlite 建表/种子 + DataSource 绑定（数据集和连接不能在
       lfm 里跨单元声明，只能在代码里建；列类型用 VARCHAR 不用 TEXT，
       否则 sqlite3conn 映射成 ftMemo，writer 只输出 "(MEMO)"）；
    2) 纯数据内容：TStringGrid 单元格、TListView 行、TTreeView 节点、
       TLWChart 序列、当天日期（这些是"内容"不是"控件"）；
    3) 运行时行为：TFPTimer 工作线程、TBitBtn.Kind 的 nogui 降级、
       "动态创建控件"页里故意演示的运行时 Create。

  窗体结构看 lfm，业务看代码。改界面的
  时候不要再回到"FormCreate 里 Create 一堆控件"的老路 —— 那样控件
  名、Tab 顺序、对齐都无法在设计器里维护，也没法被 lwaudit 静态检查。
}
unit uGallery;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, ComCtrls,
  Grids, ValEdit, CheckLst, MaskEdit, Spin, EditBtn, Buttons, Dialogs, Menus,
  FPJSON,
  DB, DBCtrls, DBGrids, sqldb, sqlite3conn, FPTimer, lwform,
  lwchart, lwui, lwweb, lwfileupload, lwdbgrid, lwdbnav;

type
  TGalleryForm = class(TLWForm)
    { ---- 设计期控件（名字与 ugallery.lfm 一一对应）---- }
    { 骨架 }
    pcMain: TPageControl;
    tsStd: TTabSheet;
    tsBtn: TTabSheet;
    tsEdit: TTabSheet;
    tsPanel: TTabSheet;
    tsGrid: TTabSheet;
    tsBar: TTabSheet;
    tsChart: TTabSheet;
    tsWeb: TTabSheet;
    tsDlg: TTabSheet;
    tsMisc: TTabSheet;
    tsDB: TTabSheet;
    tsBig: TTabSheet;
    pnlLog: TPanel;
    lblLogCap: TLabel;
    mmoLog: TMemo;
    { tsStd 标准控件 }
    lblHello: TLabel;
    stxtHello: TStaticText;
    lbl2: TLabel;
    edStdName: TEdit;
    lbl3: TLabel;
    mmStdNotes: TMemo;
    chkStdAgree: TCheckBox;
    rbStd1: TRadioButton;
    rbStd2: TRadioButton;
    rbStd3: TRadioButton;
    lbl4: TLabel;
    lbStdFruit: TListBox;
    lbl5: TLabel;
    cbStdCity: TComboBox;
    gbGroup: TGroupBox;
    chkGbA: TCheckBox;
    chkGbB: TCheckBox;
    edGbText: TEdit;
    sbxStd: TScrollBox;
    pnlScrollBody: TPanel;
    { tsBtn 按钮 }
    lblBtnHit: TLabel;
    btnPlain: TButton;
    btnBitOk: TBitBtn;
    btnBitCancel: TBitBtn;
    lbl7: TLabel;
    sbGrp0: TSpeedButton;
    sbGrp1: TSpeedButton;
    sbGrp2: TSpeedButton;
    lblBtnHint: TLabel;
    { tsEdit 扩展输入 }
    lbl8: TLabel;
    mePhone: TMaskEdit;
    lbl11: TLabel;
    deDate: TDateEdit;
    lbl12: TLabel;
    teTime: TTimeEdit;
    leMail: TLabeledEdit;
    lbl9: TLabel;
    seAge: TSpinEdit;
    lbl10: TLabel;
    fsePrice: TFloatSpinEdit;
    leHello: TLabeledEdit;
    lbl13: TLabel;
    tbVol: TTrackBar;
    lbl14: TLabel;
    edUpN: TEdit;
    udN: TUpDown;
    lbl15: TLabel;
    pbTask: TProgressBar;
    btnProgStep: TButton;
    lblEditHint: TLabel;
    { tsPanel 容器布局 }
    pnlLeft: TPanel;
    shpRound: TShape;
    bvlFrame: TBevel;
    pnlInner: TPanel;
    spLeft: TSplitter;
    pnlRight: TPanel;
    rgSize: TRadioGroup;
    cgSkills: TCheckGroup;
    clbLang: TCheckListBox;
    { tsGrid 网格列表 }
    lbl16: TLabel;
    btnSgSave: TButton;
    btnSgLoad: TButton;
    sgData: TStringGrid;
    { tsEdit 的 TTabControl（回写审计：页签序号写回 TabIndex） }
    tcMain: TTabControl;
    lblTc: TLabel;
    lbl17: TLabel;
    dgMain: TDrawGrid;
    lbl18: TLabel;
    veProps: TValueListEditor;
    lbl19: TLabel;
    lvItems: TListView;
    lbl20: TLabel;
    tvDir: TTreeView;
    { tsBar 工具条 }
    pnlBar: TPanel;
    tl1: TToolBar;
    tbtnAction1: TToolButton;
    tbtnAction2: TToolButton;
    tbtnSep: TToolButton;
    tbtnAction4: TToolButton;
    sbMain: TStatusBar;
    lblBarHint: TLabel;
    { tsChart 图表仪表 }
    btnLine: TButton;
    btnBar: TButton;
    btnPie: TButton;
    btnGaugeStep: TButton;
    chMain: TLWChart;
    pnlGauge: TPanel;
    gdMain: TLWGauge;
    lbl21: TLabel;
    cpMain: TLWColorPicker;
    { tsWeb HTML/PDF }
    lbl22: TLabel;
    mmHtml: TMemo;
    btnHtmlApply: TButton;
    hfMain: TLWHTMLFrame;
    lbl23: TLabel;
    pfMain: TLWPDFFrame;
    btnPdfMake: TButton;
    lbl24: TLabel;
    upMain: TLWFileUpload;
    lbl25: TLabel;
    { tsDlg 对话框 }
    lblDlgHint: TLabel;
    btnShowMsg: TButton;
    btnAsk: TButton;
    btnWarn: TButton;
    btnAbout: TButton;
    btnInput: TButton;
    btnToast: TButton;
    btnOpenDlg: TButton;
    btnMask: TButton;
    lblDlgResult: TLabel;
    lblDlgHint2: TLabel;
    { tsMisc 定时器/动态 }
    lbl27: TLabel;
    lblClock: TLabel;
    btnSyncClock: TButton;
    lbl29: TLabel;
    btnDynAdd: TButton;
    pnlDyn: TPanel;
    lbl30: TLabel;
    btnDlTxt: TButton;
    btnDlFile: TButton;
    lblMiscHint: TLabel;
    { tsDB 数据感知 }
    grdDb: TDBGrid;
    pnlDbRight: TPanel;
    lbl31: TLabel;
    dbeName: TDBEdit;
    lbl32: TLabel;
    dbmNote: TDBMemo;
    lbl33: TLabel;
    dbcActive: TDBCheckBox;
    lbl34: TLabel;
    dbcCode: TDBComboBox;
    navDb: TLWDBNavigator;
    lblDbHint: TLabel;
    { tsBig 大表分页 }
    grdBig: TLWDBGrid;
    lblBigHint: TLabel;
    { 非可视组件（同样在 lfm 里） }
    dsMem: TDataSource;
    dsBig: TDataSource;
    dlgOpen: TOpenDialog;
    { ---- lfm 里按名字挂上的事件 ---- }
    procedure FormCreate(Sender: TObject);
    procedure pcMainChange(Sender: TObject);
    { tsStd 事件 }
    procedure StdEditChange(Sender: TObject);
    procedure StdChkChange(Sender: TObject);
    procedure StdLbClick(Sender: TObject);
    procedure StdCbChange(Sender: TObject);
    procedure StdRbClick(Sender: TObject);
    { tsBtn 事件 }
    procedure BtnHit(Sender: TObject);
    procedure SpdClick(Sender: TObject);
    { tsEdit 事件 }
    procedure EditAnyChange(Sender: TObject);
    procedure UpdClick(Sender: TObject; Button: TUDBtnType);
    procedure ProgStep(Sender: TObject);
    { tsPanel 事件 }
    procedure PanelAny(Sender: TObject);
    procedure CgItemClick(Sender: TObject; AIndex: Integer);
    procedure TcChange(Sender: TObject);
    { tsGrid 事件 }
    procedure SgClick(Sender: TObject);
    function GridSavePath: string;
    procedure SgSaveClick(Sender: TObject);
    procedure SgLoadClick(Sender: TObject);
    procedure VeClick(Sender: TObject);
    procedure LvClick(Sender: TObject);
    procedure TvClick(Sender: TObject);
    { tsBar 事件 }
    procedure ToolClick(Sender: TObject);
    { tsChart 事件 }
    procedure ChartKind(Sender: TObject);
    procedure ColorPicked(Sender: TObject);
    { tsWeb 事件 }
    procedure HtmlApply(Sender: TObject);
    procedure PdfMake(Sender: TObject);
    procedure Uploaded(Sender: TObject; const AFileName: string);
    { tsDlg 事件 }
    procedure DlgShow(Sender: TObject);
    procedure DlgInput(Sender: TObject);
    procedure DlgToast(Sender: TObject);
    procedure DlgOpenFile(Sender: TObject);
    procedure DlgAbout(Sender: TObject);
    procedure DlgMask(Sender: TObject);
    { tsMisc 事件 }
    procedure Tick(Sender: TObject);
    procedure DynAdd(Sender: TObject);
    procedure DynClick(Sender: TObject);
    procedure DlText(Sender: TObject);
    procedure DlFile(Sender: TObject);
    procedure SyncClock(Sender: TObject);
    procedure GaugeStep(Sender: TObject);
  private
    { 纯内存状态：TFPTimer 工作线程只碰这些字段（LCL 控件跨线程一碰就崩）}
    FMaskShown: Boolean;
    FClockStr: string;
    FTickCount: Integer;
    FGaugeVal: Integer;
    FBtnCount: Integer;
    FDynCount: Integer;
    { 数据层：两个网格都用 sqlite 真库（gallery.db），改一格即落库、重启不丢。
      tsDB 可编辑（连接 1 + 事务 1）；tsBig 只读展示大表分页（连接 2 + 事务 2，
      和业务事务互不干扰，WAL 下两连接可并存，与 dbaware 演示同一套） }
    FConn: TSQLite3Connection;
    FTrans: TSQLTransaction;
    qryData: TSQLQuery;
    FConn2: TSQLite3Connection;
    FTrans2: TSQLTransaction;
    qryBig: TSQLQuery;
    tmMain: TFPTimer;
    procedure Log(const S: string);
    { 建 sqlite 库/表/种子数据 + 接 DataSource/DataField }
    procedure SetupData;
    { 控件里的"内容"：网格单元格、列表行、树节点、图表序列、当天日期 }
    procedure FillContents;
    { nogui 下 TBitBtn.Kind 会生成 glyph，可能抛 FPImageException → 降级 }
    procedure TryKind(ABtn: TBitBtn; AKind: TBitBtnKind);
  end;

var
  GalleryForm: TGalleryForm = nil;

implementation

{$R *.lfm}

uses
  uAbout;

{ 运行时手写一个合法的单页 PDF（PDF 1.4 + 标准 14 字体），不依赖第三方库。
  内容只允许 ASCII（标准字体不带 CJK 字形）。 }
function WriteSamplePDF(const AFn: string): Boolean;
var
  all, stream: TStringList;
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
    stream.Add('BT /F2 22 Tf 50 750 Td (lazarusWeb Gallery Report) Tj ET');
    stream.Add('0.2 0.4 0.75 RG');
    stream.Add('2 w');
    stream.Add('50 738 m 562 738 l S');
    stream.Add('BT /F1 11 Tf 50 712 Td (Generated at runtime by the gallery demo.) Tj ET');
    stream.Add('BT /F1 11 Tf 50 694 Td (Plain PDF syntax - no third-party library.) Tj ET');
    stream.Add('0.85 0.92 1 rg');
    stream.Add('50 620 250 26 re f');
    stream.Add('0 0 0 RG');
    stream.Add('BT /F1 11 Tf 58 628 Td (Row 1 - gallery demo) Tj ET');
    stream.Add('0.95 0.88 0.88 rg');
    stream.Add('50 588 250 26 re f');
    stream.Add('0 0 0 RG');
    stream.Add('BT /F1 11 Tf 58 596 Td (Row 2 - gallery demo) Tj ET');

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
          fs.Write(s[1], Length(s));
        end;
      finally
        fs.Free;
      end;
      Result := True;
    except
      Result := False;
    end;
  finally
    all.Free;
    stream.Free;
  end;
end;

procedure TGalleryForm.Log(const S: string);
var
  Stamp: string;
begin
  Stamp := FormatDateTime('hh:nn:ss', Now);
  mmoLog.Lines.Add(Stamp + '  ' + S);
  while mmoLog.Lines.Count > 200 do
    mmoLog.Lines.Delete(0);
end;

procedure TGalleryForm.TryKind(ABtn: TBitBtn; AKind: TBitBtnKind);
begin
  { nogui 下 TBitBtn.Kind 会在 LCL 内部生成 glyph（读 bitmap 的 RawImage），
    直接抛 FPImageException（与坑 23 的 TDBNavigator 同根）。Kind 不放进
    lfm 就是为了这层保护：失败就降级成普通按钮，演示继续。 }
  try
    ABtn.Kind := AKind;
  except
    ABtn.Kind := bkCustom;
    Log('Btn.TBitBtn glyph 在 nogui 下不可用，已降级为普通按钮');
  end;
end;

procedure TGalleryForm.FormCreate(Sender: TObject);
begin
  Caption := 'lazarusWeb · 全功能画廊';
  Log('尺寸: Client=' + IntToStr(ClientWidth) + 'x' + IntToStr(ClientHeight) +
    ' Bound=' + IntToStr(Width) + 'x' + IntToStr(Height) +
    ' PPI=' + IntToStr(PixelsPerInch) + ' DesignPPI=' + IntToStr(DesignTimePPI) +
    ' Pos=' + IntToStr(Ord(Position)));
  SetupData;
  FillContents;
  TryKind(btnBitOk, bkOK);
  TryKind(btnBitCancel, bkCancel);
  { nogui widgetset 的 CreateTimer 返回 0，LCL TTimer 一启用就抛
    EOutOfResources（NOTES 坑 48）—— 必须 FCL 的 TFPTimer。
    默认模式要等主线程泵消息才触发（服务端没有），必须
    UseTimerThread := True 才真的起后台线程；OnTimer 在工作线程触发，
    里面绝对不能碰 LCL 控件，只更新上面的纯内存字段。 }
  tmMain := TFPTimer.Create(Self);
  tmMain.UseTimerThread := True;
  tmMain.Interval := 1000;
  tmMain.OnTimer := @Tick;
  tmMain.Enabled := True;
  Log('画廊就绪：12 页 60+ 控件（全部在设计期摆放），点任何东西都会回显到这里。');
end;

procedure TGalleryForm.pcMainChange(Sender: TObject);
begin
  Log('切到页签：' + pcMain.ActivePage.Caption);
end;

{ ============================ 数据层 ============================ }

var
  GDbEnsured: Boolean = False;    { DDL/种子每进程只做一次（坑 107）}
  GBigDbEnsured: Boolean = False;

procedure TGalleryForm.SetupData;

  { 表不存在就建；空库灌 20 行种子。以前是纯内存 TBufDataset ——
    改单元格只进内存，进程一重启就回原样（"不能落库"）。现在换成
    sqlite：删掉 exe 同目录的 gallery.db 就会重建种子数据 }
  procedure EnsureDb;
  var
    i, n: Integer;
    u: string;
  begin
    FTrans := TSQLTransaction.Create(Self);
    FConn := TSQLite3Connection.Create(Self);
    FConn.DatabaseName := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
      'gallery.db';
    FConn.Transaction := FTrans;
    FTrans.Database := FConn;
    { WAL 必须走 Params，busy_timeout 走 PRAGMA（与 dbaware 同一套） }
    FConn.Params.Add('journal_mode=WAL');
    FConn.Open;
    FConn.ExecuteDirect('PRAGMA busy_timeout=10000');
    if GDbEnsured then
      Exit;   { DDL/UPDATE 每进程只做一遍：40 并发建会话时每个会话都跑一遍
                CREATE/ALTER/UPDATE，写锁竞争直接 "database is locked"
                （坑 107 复测抓到的真凶之一） }
    { 列类型要用 VARCHAR 而不是 TEXT：sqlite3conn 把 TEXT 映射成 ftMemo，
      writer 序列化时会输出 "(MEMO)" 占位符；VARCHAR(n) 才是 ftString。
      unit = DBGrid 下拉选择演示（PickList）；made = 日期选择演示（DATE） }
    FConn.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS products(code VARCHAR(20) PRIMARY KEY, ' +
      'name VARCHAR(60), unit VARCHAR(10), made DATE, price REAL, ' +
      'stock INTEGER, active BOOLEAN)');
    { 老库没有 unit/made 列：ALTER 补上（新库会报 duplicate column，吞掉） }
    try
      FConn.ExecuteDirect('ALTER TABLE products ADD COLUMN unit VARCHAR(10)');
    except
    end;
    try
      FConn.ExecuteDirect('ALTER TABLE products ADD COLUMN made DATE');
    except
    end;
    { 补出来的列是 NULL：按行号随手填上，界面上不留空 }
    FConn.ExecuteDirect(
      'UPDATE products SET unit = CASE rowid % 4 ' +
      'WHEN 1 THEN ''个'' WHEN 2 THEN ''箱'' WHEN 3 THEN ''件'' ' +
      'ELSE ''套'' END WHERE unit IS NULL');
    FConn.ExecuteDirect(
      'UPDATE products SET made = date(''2026-01-01'', ''+'' || (rowid - 1) || ' +
      ''' day'') WHERE made IS NULL');
    FTrans.Commit;
    GDbEnsured := True;
    n := 0;
    with TSQLQuery.Create(nil) do
    try
      Database := FConn;
      Transaction := FTrans;
      SQL.Text := 'SELECT COUNT(*) AS n FROM products';
      Open;
      n := FieldByName('n').AsInteger;
      Close;
    finally
      Free;
    end;
    if n > 0 then
      Exit;
    for i := 1 to 20 do
    begin
      case i mod 4 of
        1: u := '个';
        2: u := '箱';
        3: u := '件';
      else
        u := '套';
      end;
      FConn.ExecuteDirect(Format(
        'INSERT INTO products(code, name, unit, made, price, stock, active) ' +
        'VALUES (''P%.3d'', ''商品 %d'', ''%s'', ''%s'', %s, %d, %d)',
        [i, i, u, FormatDateTime('yyyy-mm-dd', EncodeDate(2026, 1, 1) + i - 1),
         FloatToStr(i * 3.5), i * 7, Ord(Odd(i))]));
    end;
    FTrans.Commit;
  end;

  { 大表：独立连接 + 独立事务；空库灌 1000 行物料 }
  procedure EnsureBigDb;
  var
    i, n: Integer;
  begin
    FTrans2 := TSQLTransaction.Create(Self);
    FConn2 := TSQLite3Connection.Create(Self);
    FConn2.DatabaseName := FConn.DatabaseName;
    FConn2.Transaction := FTrans2;
    FTrans2.Database := FConn2;
    FConn2.Params.Add('journal_mode=WAL');
    FConn2.Open;
    FConn2.ExecuteDirect('PRAGMA busy_timeout=10000');
    if GBigDbEnsured then
      Exit;
    FConn2.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS bigitems(id INTEGER PRIMARY KEY, ' +
      'name VARCHAR(60), qty INTEGER, price REAL)');
    FTrans2.Commit;
    GBigDbEnsured := True;
    n := 0;
    with TSQLQuery.Create(nil) do
    try
      Database := FConn2;
      Transaction := FTrans2;
      SQL.Text := 'SELECT COUNT(*) AS n FROM bigitems';
      Open;
      n := FieldByName('n').AsInteger;
      Close;
    finally
      Free;
    end;
    if n > 0 then
      Exit;
    for i := 1 to 1000 do
      FConn2.ExecuteDirect(Format(
        'INSERT INTO bigitems(id, name, qty, price) VALUES (%d, ''物料 %d'', %d, %s)',
        [i, i, (i * 13) mod 500, FloatToStr(((i * 7) mod 900) / 10 + 1)]));
    FTrans2.Commit;
  end;

var
  i: Integer;
begin
  { tsDB：20 行商品，sqlite 落库 }
  EnsureDb;

  qryData := TSQLQuery.Create(Self);
  qryData.Database := FConn;
  qryData.Transaction := FTrans;
  qryData.SQL.Text :=
    'SELECT code, name, unit, made, price, stock, active FROM products ORDER BY code';
  { 单元格编辑 = Post：sqoAutoApplyUpdates 把 UPDATE 发进事务，
    sqoAutoCommit 随即提交，sqoKeepOpenOnCommit 保证数据集不被关掉
    —— 一行 Options 就实现"改一格即落库"，与桌面 LCL 的 Edit+Post 手感一致 }
  qryData.Options := qryData.Options +
    [sqoAutoApplyUpdates, sqoAutoCommit, sqoKeepOpenOnCommit];
  qryData.Open;

  { 控件上的 DataSource/DataField 是设计期定下来的结构，这里只接数据集 }
  dsMem.DataSet := qryData;
  dbeName.DataField := 'name';
  dbeName.DataSource := dsMem;
  dbmNote.DataField := 'name';
  dbmNote.DataSource := dsMem;
  dbcActive.DataField := 'active';
  dbcActive.DataSource := dsMem;
  dbcCode.DataField := 'code';
  dbcCode.DataSource := dsMem;
  navDb.DataSource := dsMem;
  grdDb.DataSource := dsMem;

  { DBGrid 单元格编辑器（框架按列类型自动判定，这里只挑一处做样板）：
    - unit：TColumn.PickList 非空 -> cedit=2，点开是 <select>，选中即写库；
    - made：TDateField -> cedit=3，点开是日期选择器；
    - active：TBooleanField -> cedit=4，单元格常驻勾选框，点一下即写回 '1'/'0'。
    列没在 lfm 里定义，访问 Columns 时 TDBGrid 会按字段自动生成
    （设计期结构 + 运行时补内容），所以只需要在这里补列级属性 }
  for i := 0 to grdDb.Columns.Count - 1 do
  begin
    if grdDb.Columns[i].FieldName = 'unit' then
    begin
      grdDb.Columns[i].PickList.Clear;
      grdDb.Columns[i].PickList.Add('个');
      grdDb.Columns[i].PickList.Add('箱');
      grdDb.Columns[i].PickList.Add('件');
      grdDb.Columns[i].PickList.Add('套');
    end
    else if grdDb.Columns[i].FieldName = 'active' then
      grdDb.Columns[i].Title.Caption := '上架';
  end;

  { tsBig：1000 行物料，TLWDBGrid 显示层分页。同样走 sqlite（bigitems 表），
    独立连接/事务：只读展示，和 tsDB 的业务事务互不干扰（WAL 下两连接可并存） }
  EnsureBigDb;

  qryBig := TSQLQuery.Create(Self);
  qryBig.Database := FConn2;
  qryBig.Transaction := FTrans2;
  qryBig.SQL.Text := 'SELECT id, name, qty, price FROM bigitems ORDER BY id';
  qryBig.Open;

  dsBig.DataSet := qryBig;
  grdBig.DataSource := dsBig;
end;

{ ============================ 控件内容 ============================ }

procedure TGalleryForm.FillContents;
var
  i: Integer;
  nd, sub: TTreeNode;
begin
  { tsGrid：表格的表头/行首是数据，不是控件本身 }
  sgData.Options := sgData.Options + [goEditing];
  for i := 1 to 4 do
    sgData.Cells[i - 1, 0] := '列' + IntToStr(i);
  for i := 1 to 5 do
    sgData.Cells[0, i] := '第' + IntToStr(i) + '行';

  { TListView：列在设计期（lfm），行在代码 }
  for i := 1 to 5 do
    with lvItems.Items.Add do
    begin
      Caption := '条目 ' + IntToStr(i);
      SubItems.Add(IntToStr(i * 10));
      SubItems.Add('说明 ' + IntToStr(i));
    end;

  { TTreeView 节点 }
  nd := tvDir.Items.Add(nil, '源码');
  tvDir.Items.AddChild(nd, 'src/core');
  tvDir.Items.AddChild(nd, 'src/client');
  nd := tvDir.Items.Add(nil, '演示');
  sub := tvDir.Items.AddChild(nd, 'demos');
  tvDir.Items.AddChild(sub, 'gallery');
  tvDir.Items.AddChild(sub, 'dbaware');
  tvDir.FullExpand;

  { TLWChart 序列（标题和类目在设计期） }
  with chMain.Series.Add do
  begin
    Name := '销售额';
    Values.CommaText := '120,95,140,160,130,185';
  end;
  with chMain.Series.Add do
  begin
    Name := '成本';
    Values.CommaText := '80,70,88,95,85,110';
  end;

  { 日期/时间控件默认给"今天/现在" }
  deDate.Date := Date;
  teTime.Time := Frac(Now);

  { 初始 HTML 帧内容取自上面的源码框 }
  hfMain.HTML.Assign(mmHtml.Lines);
end;

{ ============================ tsStd 标准控件 ============================ }

procedure TGalleryForm.StdEditChange(Sender: TObject);
begin
  Log('Std.' + Sender.ClassName + ' 内容 = ' +
    (Sender as TCustomEdit).Text);
end;

procedure TGalleryForm.StdChkChange(Sender: TObject);
begin
  Log('Std.TCheckBox = ' + BoolToStr(chkStdAgree.Checked, True));
end;

procedure TGalleryForm.StdLbClick(Sender: TObject);
begin
  if lbStdFruit.ItemIndex >= 0 then
    Log('Std.TListBox 选中 = ' + lbStdFruit.Items[lbStdFruit.ItemIndex]);
end;

procedure TGalleryForm.StdCbChange(Sender: TObject);
begin
  if cbStdCity.ItemIndex >= 0 then
    Log('Std.TComboBox = ' + cbStdCity.Items[cbStdCity.ItemIndex]);
end;

procedure TGalleryForm.StdRbClick(Sender: TObject);
begin
  Log('Std.TRadioButton = ' + (Sender as TRadioButton).Caption);
end;

{ ============================ tsBtn 按钮 ============================ }

procedure TGalleryForm.BtnHit(Sender: TObject);
begin
  Inc(FBtnCount);
  lblBtnHit.Caption := '点击次数：' + IntToStr(FBtnCount) +
    '（最后：' + (Sender as TButtonControl).Caption + '）';
  Log('Btn.OnClick = ' + (Sender as TButtonControl).Caption);
end;

procedure TGalleryForm.SpdClick(Sender: TObject);
begin
  Log('Btn.TSpeedButton = ' + (Sender as TSpeedButton).Caption +
    ' Down=' + BoolToStr((Sender as TSpeedButton).Down, True));
end;

{ ============================ tsEdit 扩展输入 ============================ }

procedure TGalleryForm.EditAnyChange(Sender: TObject);
begin
  { 不能在这里 as TCustomEdit —— TDateEdit/TTimeEdit 是 TCustomEditButton
    （TCustomControl 系）后代，强转直接 EInvalidCast（NOTES 坑 28）。 }
  Log('Edit.' + Sender.ClassName + ' 变更');
end;

procedure TGalleryForm.UpdClick(Sender: TObject; Button: TUDBtnType);
begin
  { TUpDown.OnClick 是两参事件（TUDBtnType），不能强转成 TNotifyEvent }
  Log('Edit.TUpDown = ' + edUpN.Text);
end;

procedure TGalleryForm.ProgStep(Sender: TObject);
begin
  pbTask.Position := (pbTask.Position + 10) mod 110;
  Log('Edit.TProgressBar = ' + IntToStr(pbTask.Position) + '%');
end;

{ ============================ tsPanel 容器布局 ============================ }

procedure TGalleryForm.PanelAny(Sender: TObject);
begin
  Log('Panel.' + Sender.ClassName + ' 触发');
end;

procedure TGalleryForm.CgItemClick(Sender: TObject; AIndex: Integer);
begin
  Log('Panel.TCheckGroup 第 ' + IntToStr(AIndex) + ' 项 = ' +
    BoolToStr(cgSkills.Checked[AIndex], True));
end;

procedure TGalleryForm.TcChange(Sender: TObject);
begin
  { 回写审计：浏览器切 TTabControl 页签 -> 服务端 TabIndex 已同步，
    这里读到的必须是新页签序号（坑 97 之前永远是 0） }
  Log('Edit.TTabControl TabIndex=' + IntToStr(tcMain.TabIndex) +
    ' [' + tcMain.Tabs[tcMain.TabIndex] + ']');
end;

{ ============================ tsGrid 网格列表 ============================ }

procedure TGalleryForm.SgClick(Sender: TObject);
begin
  { LCL 的 TCustomGrid 把 Col/Row 藏在 protected，只有 TStringGrid 提为公开 }
  if Sender is TStringGrid then
    Log('Grid.TStringGrid 行=' + IntToStr(TStringGrid(Sender).Row) +
      ' 列=' + IntToStr(TStringGrid(Sender).Col))
  else
    Log('Grid.' + Sender.ClassName + ' 点击');
end;

{ tsGrid 的保存/调用：把 sgData 全部单元格序列化成 JSON 落盘
  （demos/gallery/gridsave.json，与 exe 同目录），再原样读回。
  保存的内容含浏览器端就地编辑写回的值（OnEditingDone -> Cells），
  调用后重设 ColCount/RowCount 填 Cells —— 事件回包带完整组件树，
  新行列结构自动刷到浏览器，无需手动刷新。}

function TGalleryForm.GridSavePath: string;
begin
  Result := ExtractFilePath(Application.ExeName) + 'gridsave.json';
end;

procedure TGalleryForm.SgSaveClick(Sender: TObject);
var
  root: TJSONObject;
  rows, cells: TJSONArray;
  c, r: Integer;
begin
  root := TJSONObject.Create;
  try
    root.Add('cols', sgData.ColCount);
    root.Add('fixedRows', sgData.FixedRows);
    root.Add('fixedCols', sgData.FixedCols);
    rows := TJSONArray.Create;
    for r := 0 to sgData.RowCount - 1 do
    begin
      cells := TJSONArray.Create;
      for c := 0 to sgData.ColCount - 1 do
        cells.Add(sgData.Cells[c, r]);
      rows.Add(cells);
    end;
    root.Add('rows', rows);
    with TStringStream.Create(root.AsJSON) do
    try
      SaveToFile(GridSavePath);
    finally
      Free;
    end;
    Log('Grid.保存 -> gridsave.json（' + IntToStr(sgData.RowCount) + ' 行 x ' +
      IntToStr(sgData.ColCount) + ' 列）');
    ShowMessage('已保存 ' + IntToStr(sgData.RowCount) + ' 行 x ' +
      IntToStr(sgData.ColCount) + ' 列到 gridsave.json');
  finally
    root.Free;
  end;
end;

procedure TGalleryForm.SgLoadClick(Sender: TObject);
var
  root: TJSONObject;
  rows, cells: TJSONArray;
  c, r, nCols, nRows: Integer;
  s: string;
  fs: TFileStream;
begin
  if not FileExists(GridSavePath) then
  begin
    Log('Grid.调用 -> gridsave.json 不存在（先点"保存"）');
    ShowMessage('gridsave.json 不存在，请先点"保存"');
    Exit;
  end;
  fs := TFileStream.Create(GridSavePath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(s, fs.Size);
    fs.ReadBuffer(s[1], fs.Size);
  finally
    fs.Free;
  end;
  root := TJSONObject(GetJSON(s));
  try
    nCols := root.Get('cols', sgData.ColCount);
    rows := root.FindPath('rows') as TJSONArray;
    nRows := rows.Count;
    sgData.ColCount := nCols;
    sgData.RowCount := nRows;
    for r := 0 to nRows - 1 do
    begin
      cells := TJSONArray(rows[r]);
      for c := 0 to nCols - 1 do
        if c < cells.Count then
          sgData.Cells[c, r] := cells.Strings[c];
    end;
    Log('Grid.调用 <- gridsave.json（' + IntToStr(nRows) + ' 行 x ' +
      IntToStr(nCols) + ' 列）');
    ShowMessage('已从 gridsave.json 调用 ' + IntToStr(nRows) + ' 行 x ' +
      IntToStr(nCols) + ' 列');
  finally
    root.Free;
  end;
end;

procedure TGalleryForm.VeClick(Sender: TObject);
begin
  Log('Grid.TValueListEditor 行=' + IntToStr(veProps.Row));
end;

procedure TGalleryForm.LvClick(Sender: TObject);
begin
  if Assigned(lvItems.Selected) then
    Log('Grid.TListView = ' + lvItems.Selected.Caption);
end;

procedure TGalleryForm.TvClick(Sender: TObject);
begin
  if Assigned(tvDir.Selected) then
    Log('Grid.TTreeView = ' + tvDir.Selected.Text);
end;

{ ============================ tsBar 工具条/状态栏 ============================ }

procedure TGalleryForm.ToolClick(Sender: TObject);
begin
  sbMain.Panels[0].Text := '最后动作：' + (Sender as TToolButton).Caption;
  Log('Bar.TToolButton = ' + (Sender as TToolButton).Caption);
end;

{ ============================ tsChart 图表仪表 ============================ }

procedure TGalleryForm.ChartKind(Sender: TObject);
var
  s: string;
begin
  s := (Sender as TButton).Caption;
  if s = '折线图' then
    chMain.ChartType := ctLine
  else if s = '柱状图' then
    chMain.ChartType := ctBar
  else
    chMain.ChartType := ctPie;
  Log('Chart.' + s);
end;

procedure TGalleryForm.GaugeStep(Sender: TObject);
begin
  gdMain.Value := (gdMain.Value + 7);
  if gdMain.Value > 100 then
    gdMain.Value := 5;
  Log('Chart.仪表 = ' + FloatToStr(gdMain.Value) + '%');
end;

procedure TGalleryForm.ColorPicked(Sender: TObject);
begin
  Log('Chart.TLWColorPicker = #' + IntToHex(cpMain.Color and $FFFFFF, 6));
end;

{ ============================ tsWeb HTML / PDF / 上传 ============================ }

procedure TGalleryForm.HtmlApply(Sender: TObject);
begin
  hfMain.HTML.Assign(mmHtml.Lines);
  Log('Web.HTML 已应用（' + IntToStr(mmHtml.Lines.Count) + ' 行）');
end;

procedure TGalleryForm.PdfMake(Sender: TObject);
var
  fn: string;
begin
  fn := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'lw_gallery.pdf';
  if WriteSamplePDF(fn) then
  begin
    pfMain.PDFFile := fn;
    Log('Web.示例 PDF 已生成并载入 PDF 帧');
  end
  else
    Log('Web.示例 PDF 生成失败');
end;

procedure TGalleryForm.Uploaded(Sender: TObject; const AFileName: string);
begin
  Log('Web.上传完成 -> ' + AFileName);
end;

{ ============================ tsDlg 对话框 ============================ }

procedure TGalleryForm.DlgShow(Sender: TObject);
var
  s: string;
begin
  s := (Sender as TButton).Caption;
  if s = 'ShowMessage' then
  begin
    ShowMessage('这是 ShowMessage，浏览器端渲染成 Ext 窗口。');
    Log('Dlg.ShowMessage 返回');
  end
  else if s = 'MessageDlg 询问' then
  begin
    if MessageDlg('确认继续吗？', mtConfirmation, mbYesNo, 0) = mrYes then
      lblDlgResult.Caption := '对话框返回值：mrYes'
    else
      lblDlgResult.Caption := '对话框返回值：mrNo';
  end
  else
  begin
    MessageDlg('磁盘空间不足！', mtWarning, [mbOK], 0);
    lblDlgResult.Caption := '对话框返回值：警告已确认';
  end;
  Log('Dlg.' + s + ' -> ' + lblDlgResult.Caption);
end;

procedure TGalleryForm.DlgInput(Sender: TObject);
var
  v: string;
begin
  v := InputBox('输入框', '请输入你的名字：', '');
  lblDlgResult.Caption := '对话框返回值：' + v;
  Log('Dlg.InputBox -> ' + v);
end;

procedure TGalleryForm.DlgToast(Sender: TObject);
begin
  ShowToast('操作已保存（Toast，2 秒自动消失）', '提示');
  Log('Dlg.ShowToast');
end;

procedure TGalleryForm.DlgOpenFile(Sender: TObject);
begin
  dlgOpen.Filter := '文本文件|*.txt;*.pas|所有文件|*.*';
  if dlgOpen.Execute then
  begin
    lblDlgResult.Caption := '对话框返回值：' + dlgOpen.FileName;
    Log('Dlg.OpenDialog -> ' + dlgOpen.FileName);
  end
  else
    Log('Dlg.OpenDialog 取消');
end;

procedure TGalleryForm.DlgMask(Sender: TObject);
begin
  if FMaskShown then
  begin
    LWHideScreenMask;
    FMaskShown := False;
    Log('Dlg.遮罩关闭');
  end
  else
  begin
    LWShowScreenMask('服务端正在处理…（点击遮罩任意处关闭）');
    FMaskShown := True;
    Log('Dlg.遮罩显示');
  end;
end;

procedure TGalleryForm.DlgAbout(Sender: TObject);
var
  r: Integer;
begin
  r := 0;
  with TAboutForm.Create(nil) do
  try
    r := ShowModal;
  finally
    Free;
  end;
  lblDlgResult.Caption := '对话框返回值：模态 ' + IntToStr(r);
  Log('Dlg.模态窗体返回 ' + IntToStr(r));
end;

{ ============================ tsMisc 定时器/动态/下载 ============================ }

procedure TGalleryForm.Tick(Sender: TObject);
begin
  { 工作线程：只写普通字段。FClockStr/FGaugeVal 由按钮回发时读出来。 }
  FClockStr := FormatDateTime('hh:nn:ss', Now);
  FGaugeVal := (FGaugeVal + 7) mod 100;
  Inc(FTickCount);
end;

procedure TGalleryForm.SyncClock(Sender: TObject);
begin
  lblClock.Caption := FClockStr;
  gdMain.Value := FGaugeVal;
  Log('Misc.定时器已跑 ' + IntToStr(FTickCount) + ' 拍，时钟 = ' + FClockStr);
end;

procedure TGalleryForm.DynAdd(Sender: TObject);
var
  b: TButton;
begin
  { 这一页是"运行时建控件"能力的演示，故意保留 Create：
    其余页签的控件一律在设计期（lfm）摆好。 }
  Inc(FDynCount);
  b := TButton.Create(pnlDyn);
  b.Parent := pnlDyn;
  b.SetBounds(10 + (FDynCount - 1) mod 6 * 80,
    10 + (FDynCount - 1) div 6 * 40, 72, 32);
  b.Caption := '动态' + IntToStr(FDynCount);
  b.OnClick := @DynClick;
  Log('Misc.动态创建 按钮 #' + IntToStr(FDynCount));
end;

procedure TGalleryForm.DynClick(Sender: TObject);
begin
  Log('Misc.动态按钮 OnClick = ' + (Sender as TButton).Caption);
end;

procedure TGalleryForm.DlText(Sender: TObject);
begin
  SendText('lazarusWeb 下载演示' + LineEnding + '时间：' +
    FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), 'demo.txt');
  Log('Misc.SendText -> demo.txt');
end;

procedure TGalleryForm.DlFile(Sender: TObject);
var
  fn: string;
begin
  fn := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'lw_gallery.pdf';
  if (not FileExists(fn)) and (not WriteSamplePDF(fn)) then
  begin
    Log('Misc.示例 PDF 生成失败');
    Exit;
  end;
  SendFile(fn, 'gallery.pdf');
  Log('Misc.SendFile -> gallery.pdf');
end;

end.
