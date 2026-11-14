{
  lazarusWeb :: 演示 4 —— SQLite 增删改查
  ------------------------------------------------------------------
  这个窗体把"数据库应用"整套搬到了 Web 上，用的全是标准 LCL DB 控件：

      TDBGrid      商品列表（点列头排序、点行定位）
      TDBEdit      编码 / 名称 / 单价 / 库存
      TDBComboBox  分类
      TDBMemo      备注
      TButton      新增 / 保存 / 取消 / 删除 / 首末条 / 上下条
      TLabel       字段名、当前状态、汇总信息
      TStatusBar   状态 + 记录位置 + 库存货值

  关键点：控件本身完全不知道"浏览器"的存在。
    · 服务端 nogui widgetset 下，TDBGrid 照常创建、照常绑数据集；
    · lwwriter 把数据集当前的内容（列、行、游标位置、编辑状态）序列化出去；
    · 浏览器点某一行 -> 服务端把 DataSet.RecNo 挪过去 -> DBEdit 自动刷新；
    · 浏览器改 DBEdit -> 服务端直接写字段（不是写 Text，见 lwdispatch 注释）；
    · 业务代码里的 Post / Cancel / Delete / Locate 一行都不用改。

  数据库文件生成在 exe 同目录的 shop.db，首次运行自动建表并灌 36 条示例数据。

  布局：全部在 uDbMain.lfm 里（设计期摆位）。本单元不 Create 任何界面控件，
    只在 BindDataSources 里把 DataSource 接上去（它是运行时对象，lfm 里没有）。
    控件字段和事件方法都声明在 published 段 —— lfm 只认 published。
}
unit uDbMain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, StdCtrls, ExtCtrls,
  ComCtrls, DB, DBCtrls, DBGrids, sqldb, sqlite3conn,
  lwform, lwfileupload, lwupload, lwdbgrid;

type

  { TDbForm }

  TDbForm = class(TLWForm)
    lblCatEdit: TLabel;
    lblCode: TLabel;
    lblMemo: TLabel;
    lblName: TLabel;
    lblPrice: TLabel;
    lblStock: TLabel;
  private
    FConn: TSQLite3Connection;
    FTrans: TSQLTransaction;
    FQry: TSQLQuery;
    FDs: TDataSource;
    FQryStat: TSQLQuery;
    FDsStat: TDataSource;
    FSortField: string;
    FSortDir: string;
    FTotal, FQty: Integer;
    FAmount: Double;
    { 附件：独立连接。主连接上的 FQry 一 Open 就挂着一个长读事务，
      在它上面 Commit 会把 FQry 一起关掉 —— 附件读写必须走自己的连接 }
    FConnAtt: TSQLite3Connection;
    FTransAtt: TSQLTransaction;
    FAttachIds: array of Integer;   { 与 lstAttach.Items 一一对应 }
    FAttachShownId: Integer;        { 列表当前对应哪个商品，-1 = 还没刷新过 }

    procedure SetupData;
    procedure EnsureSchema;
    procedure SeedData;
    procedure BindDataSources;
    function BuildWhere: string;
    function BuildSQL: string;
    { AKeepId>0 时定位回该行（Commit 会关闭数据集，调用方要先自己记住 id） }
    procedure Requery(AKeepId: Integer = 0);
    procedure RefreshTotals;
    procedure RefreshStat;
    procedure UpdateStatus;
    procedure LogSQL(const AText: string);
    procedure ApplyFilter;

    { 附件 }
    function AttachRoot: string;
    function AttachDirOf(AItemId: Integer): string;
    function AttachPathOf(AItemId: Integer; const AName: string): string;
    function UniqueAttachName(const ADir, AName: string): string;
    function AttachNameOf(AId: Integer): string;
    procedure ClearAttachList;
    procedure RefreshAttach;
    procedure CopyFileRaw(const ASrc, ADst: string);

  published
    { 以下控件全部在 uDbMain.lfm 里摆位（设计期布局，代码里不再 Create/SetBounds）。
      lfm 只实例化 published 字段 —— private 字段写了 object 块也不会被创建，
      运行到就是 nil 访问。事件方法同理，必须 published 才能按名字绑定。 }

    { 工具栏 }
    pnlTop: TPanel;
    lblFind: TLabel;
    edFind: TEdit;
    lblCat: TLabel;
    cbFilterCat: TComboBox;
    chkLowStock: TCheckBox;
    btnQuery: TButton;
    btnReset: TButton;
    lblTip: TLabel;
    { 页签 }
    pcMain: TPageControl;
    tsData: TTabSheet;
    tsStat: TTabSheet;
    tsLog: TTabSheet;
    { 数据维护页 }
    grdMain: TLWDBGrid;
    pnlEdit: TPanel;
    edCode: TDBEdit;
    edName: TDBEdit;
    edPrice: TDBEdit;
    edStock: TDBEdit;
    cbCategory: TDBComboBox;
    mmMemo: TDBMemo;
    lblState: TLabel;
    lblDetail: TLabel;
    btnNew: TButton;
    btnSave: TButton;
    btnCancel: TButton;
    btnDelete: TButton;
    btnFirst: TButton;
    btnPrev: TButton;
    btnNext: TButton;
    btnLast: TButton;
    lblInfo: TLabel;
    { 附件 UI }
    lblAttachInfo: TLabel;
    lstAttach: TListBox;
    btnUpload: TLWFileUpload;
    btnAttachOpen: TButton;
    btnAttachDel: TButton;
    { 统计页 / 日志页 }
    grdStat: TLWDBGrid;
    lblStatSum: TLabel;
    mmoLog: TMemo;
    sbMain: TStatusBar;

    procedure btnQueryClick(Sender: TObject);
    procedure btnResetClick(Sender: TObject);
    procedure btnNewClick(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
    procedure btnCancelClick(Sender: TObject);
    procedure btnDeleteClick(Sender: TObject);
    procedure btnNavClick(Sender: TObject);
    procedure grdTitleClick(Column: TColumn);
    procedure grdCellClick(Column: TColumn);
    procedure FieldChanged(Sender: TObject);
    procedure btnUploadUpload(Sender: TObject; const AFileName: string);
    procedure btnAttachOpenClick(Sender: TObject);
    procedure btnAttachDelClick(Sender: TObject);
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
  end;

const
  CATEGORIES: array[0..5] of string = (
    '电子配件', '办公用品', '图书音像', '家居日用', '食品饮料', '工具五金');

  PRODUCTS: array[0..35] of string = (
    'USB-C 数据线 1m', '无线鼠标 M330', '机械键盘 87 键', '65W 氮化镓充电器',
    '蓝牙耳机 Pro', 'Type-C 扩展坞',
    'A4 复印纸 500 张', '中性笔 0.5mm 黑', '订书机 12 号', '文件夹 A4 蓝',
    '白板笔 可擦', '文件柜 三层',
    'Pascal 程序设计', 'Delphi 实战指南', '数据结构与算法', '计算机组成原理',
    '英语语法精讲', '摄影构图入门',
    '竹纤维毛巾', '收纳箱 45L', '陶瓷马克杯', '香薰蜡烛',
    '抱枕套 45cm', '折叠衣架',
    '云南小粒咖啡 250g', '挂耳咖啡 10 包', '龙井茶 100g', '每日坚果 30 包',
    '燕麦片 1kg', '蜂蜜柚子茶',
    '十字螺丝刀套装', '卷尺 5m', '内六角扳手 9 件', '电烙铁 60W',
    '数字万用表', '冲击钻 13mm');

implementation

{$R *.lfm}

{ ==================== 构造 / 析构 ==================== }

constructor TDbForm.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  FSortField := 'id';
  FSortDir := 'ASC';
  { 两级表头（TLWDBGrid.HeaderGroups）：'标题|起-止'，起/止是按可见列
    从左数起的下标（0 起、含止）；没写进任何分组的列自己贯通两行。
    grdMain 的"备注"列 Visible=False，不占列号 —— 所以这里只分到 5，
    最后的"更新时间"（可见列 6）留作不分组的样例。
    lfm 里这两个网格写的是 TLWDBGrid —— FPC 的 GetClass 只认精确类名，
    RegisterClassAlias 在 lfm 加载路径上不生效（同 TLWDBNavigator）。 }
  with grdMain.HeaderGroups do
  begin
    Add('基本信息|0-2');
    Add('价格与库存|3-5');
  end;
  { 统计页：只有"统计指标"三列成组，分类列单独贯通 —— 顺带演示
    部分列分组、部分列不分组的混排 }
  grdStat.HeaderGroups.Add('统计指标|1-3');
  { 控件由 uDbMain.lfm 在 inherited Create 里就建好了（设计期布局）。
    这里只做两件事：开库、把控件和数据集接上。
    DataSource 不能写进 lfm —— 它要到 SetupData 里才创建。 }
  SetupData;
  BindDataSources;
  Requery;
  RefreshStat;
  LogSQL('数据库就绪：' + ExtractFileName(FConn.DatabaseName) +
    '（' + IntToStr(FTotal) + ' 条记录）');
end;

destructor TDbForm.Destroy;
begin
  if FQry <> nil then FQry.Close;
  if FQryStat <> nil then FQryStat.Close;
  if FConnAtt <> nil then FConnAtt.Close;
  if FConn <> nil then FConn.Close;
  inherited Destroy;
end;

{ ==================== 数据层 ==================== }

procedure TDbForm.SetupData;
var
  q: TSQLQuery;
begin
  FTrans := TSQLTransaction.Create(Self);
  FTrans.Name := 'FTrans';
  FConn := TSQLite3Connection.Create(Self);
  FConn.Name := 'FConn';
  FConn.DatabaseName := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'shop.db';
  FConn.Transaction := FTrans;
  FTrans.Database := FConn;
  { 多会话（多浏览器标签 = 多个连接）标配：
    - WAL：读不阻塞写、写不阻塞读（rollback journal 模式下读写互斥）；
      必须走 Params —— sqlite3conn 只认 foreign_keys / journal_mode 两个
      参数，Open 后在事务外自动执行。用 ExecuteDirect 发 PRAGMA 反而不生效
      （SQLdb 会把它包进事务，实测 mode 还是 delete）。
    - busy_timeout：写锁冲突先排队等 10 秒，而不是立刻抛 database is locked。
      它不在 sqlite3conn 的 Params 白名单里，只能 Open 之后用 PRAGMA 设置；
      这个 PRAGMA 在事务内也有效。 }
  FConn.Params.Add('journal_mode=WAL');
  FConn.Open;
  FConn.ExecuteDirect('PRAGMA busy_timeout=10000');

  EnsureSchema;

  FQry := TSQLQuery.Create(Self);
  FQry.Name := 'FQry';
  FQry.Database := FConn;
  FQry.Transaction := FTrans;
  FQry.SQL.Text := 'SELECT id, code, name, category, price, stock, memo, updated FROM items ORDER BY id';
  { FPC 的 TSQLQuery 默认只把 Post/Delete 写进内存缓冲，要等显式 ApplyUpdates。
    sqoAutoApplyUpdates 让 Post 立刻把 UPDATE/INSERT 发给 SQLite ——
    但注意它【并不提交事务】：FPC 源码里只有 sqoAutoCommit 才会跟着
    SQLTransaction.Commit（而那还会顺手关掉数据集）。
    所以真正落库的 Commit 必须业务代码自己做（见 btnSaveClick /
    btnDeleteClick）。不 Commit 的写事务会一直握着 SQLite 的写锁 ——
    第二个会话一保存就 database is locked，而且本会话的数据在程序退出时
    全部回滚。这正是"保存看起来成功、其实没进数据库"的根源。 }
  FQry.Options := FQry.Options + [sqoAutoApplyUpdates];
  FDs := TDataSource.Create(Self);
  FDs.Name := 'FDs';
  FDs.DataSet := FQry;
  FQry.Open;

  { 自检：确认 WAL 真的生效了（还是 delete 就说明 PRAGMA 没起作用） }
  q := TSQLQuery.Create(nil);
  try
    q.Database := FConn;
    q.Transaction := FTrans;
    q.SQL.Text := 'PRAGMA journal_mode';
    q.Open;
    LogSQL('journal_mode=' + q.Fields[0].AsString);
  finally
    q.Free;
  end;

  { 附件用的第二条连接。
    为什么不能共用 FConn：FQry 一 Open 就带着一个长读事务，在 FTrans 上
    Commit 会把它（以及 FQryStat）一起关掉。附件读写挪到独立连接后，
    上传/删除附件完全不会打断正在编辑的商品记录。
    两条连接共享同一个 WAL 库（journal_mode 是库级持久设置，这边不用再设），
    写冲突交给 busy_timeout 排队。
    注意：Open/ExecuteDirect 会顺手开一个空事务，必须马上 Commit ——
    否则后续读一直停留在打开时的旧快照，别的连接刚写进来的附件看不见。 }
  FTransAtt := TSQLTransaction.Create(Self);
  FTransAtt.Name := 'FTransAtt';
  FConnAtt := TSQLite3Connection.Create(Self);
  FConnAtt.Name := 'FConnAtt';
  FConnAtt.DatabaseName := FConn.DatabaseName;
  FConnAtt.Transaction := FTransAtt;
  FTransAtt.Database := FConnAtt;
  FConnAtt.Open;
  FConnAtt.ExecuteDirect('PRAGMA busy_timeout=10000');
  if FTransAtt.Active then
    FTransAtt.Commit;
end;

procedure TDbForm.EnsureSchema;
begin
  { 注意字段类型：sqlite3conn 把 TEXT / CHAR 映射成 ftMemo，
    而再长的 VARCHAR(n) 仍然是 ftString。DBGrid 遇到 ftMemo 只会显示
    "(MEMO)"，DBEdit 也没法编辑 —— 所以这里一律用 VARCHAR(n)。
    这条规则对任何用 sqlite 的 lazarusWeb 项目都适用。 }
  FConn.ExecuteDirect(
    'CREATE TABLE IF NOT EXISTS items(' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  code VARCHAR(20) NOT NULL,' +
    '  name VARCHAR(60) NOT NULL,' +
    '  category VARCHAR(20),' +
    '  price REAL DEFAULT 0,' +
    '  stock INTEGER DEFAULT 0,' +
    '  memo VARCHAR(400),' +
    '  updated VARCHAR(20))');
  FConn.ExecuteDirect('CREATE UNIQUE INDEX IF NOT EXISTS ux_items_code ON items(code)');
  { 附件表：一个商品可以有多个附件。文件本体放 exe 同目录 attachments\<item_id>\，
    这里只存名字，路径靠 item_id + file_name 还原 —— 数据库不绑绝对路径，
    整个目录换个位置照样能用。 }
  FConn.ExecuteDirect(
    'CREATE TABLE IF NOT EXISTS attachments(' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  item_id INTEGER NOT NULL,' +
    '  file_name VARCHAR(200) NOT NULL,' +
    '  size_kb INTEGER DEFAULT 0,' +
    '  uploaded VARCHAR(20))');
  FConn.ExecuteDirect(
    'CREATE INDEX IF NOT EXISTS ix_att_item ON attachments(item_id)');
  FTrans.Commit;
  SeedData;
end;

procedure TDbForm.SeedData;
var
  q: TSQLQuery;
  n, i: Integer;
  cat: string;
begin
  q := TSQLQuery.Create(nil);
  q.Name := 'q';
  try
    q.Database := FConn;
    q.Transaction := FTrans;
    q.SQL.Text := 'SELECT COUNT(*) AS n FROM items';
    q.Open;
    n := q.FieldByName('n').AsInteger;
    q.Close;
  finally
    q.Free;
  end;
  if n > 0 then Exit;

  for i := 0 to High(PRODUCTS) do
  begin
    cat := CATEGORIES[i div 6];
    FConn.ExecuteDirect(Format(
      'INSERT INTO items(code,name,category,price,stock,memo,updated) VALUES(%s,%s,%s,%s,%d,%s,%s)',
      [QuotedStr(Format('P%.4d', [1000 + i])),
       QuotedStr(PRODUCTS[i]),
       QuotedStr(cat),
       StringReplace(Format('%.2f', [8 + (i * 7) mod 120 + 0.5]), ',', '.', [rfReplaceAll]),
       3 + (i * 13) mod 60,
       QuotedStr(Format('%s · 货架 %s%d', [cat, Chr(Ord('A') + i mod 6), 1 + i mod 9])),
       QuotedStr(FormatDateTime('yyyy-mm-dd hh:nn', Now - i))]));
  end;
  FTrans.Commit;
end;

function TDbForm.BuildWhere: string;
var
  w: string;
  kw: string;
begin
  w := '';
  if Assigned(edFind) then
    kw := Trim(edFind.Text)
  else
    kw := '';
  if kw <> '' then
    w := w + Format(' AND (name LIKE %s OR code LIKE %s OR memo LIKE %s)',
      [QuotedStr('%' + kw + '%'), QuotedStr('%' + kw + '%'), QuotedStr('%' + kw + '%')]);
  if Assigned(cbFilterCat) and (cbFilterCat.ItemIndex > 0) then
    w := w + ' AND category = ' + QuotedStr(cbFilterCat.Items[cbFilterCat.ItemIndex]);
  if Assigned(chkLowStock) and chkLowStock.Checked then
    w := w + ' AND stock < 10';
  if w <> '' then
    Result := ' WHERE ' + Copy(w, 6, MaxInt)
  else
    Result := '';
end;

function TDbForm.BuildSQL: string;
begin
  Result := 'SELECT id, code, name, category, price, stock, memo, updated FROM items' +
    BuildWhere + ' ORDER BY ' + FSortField + ' ' + FSortDir;
end;

procedure TDbForm.Requery(AKeepId: Integer);
var
  keepId: Integer;
begin
  keepId := AKeepId;
  if (keepId = 0) and FQry.Active and (not FQry.IsEmpty) then
    keepId := FQry.FieldByName('id').AsInteger;

  FQry.Close;
  FQry.SQL.Text := BuildSQL;
  FQry.Open;
  if keepId > 0 then
    FQry.Locate('id', keepId, []);

  RefreshTotals;
  UpdateStatus;
end;

procedure TDbForm.RefreshTotals;
var
  q: TSQLQuery;
begin
  q := TSQLQuery.Create(nil);
  q.Name := 'q';
  try
    q.Database := FConn;
    q.Transaction := FTrans;
    q.SQL.Text := 'SELECT COUNT(*) AS n, COALESCE(SUM(stock),0) AS qty, ' +
      'COALESCE(SUM(price*stock),0) AS amount FROM items' + BuildWhere;
    q.Open;
    FTotal := q.FieldByName('n').AsInteger;
    FQty := q.FieldByName('qty').AsInteger;
    FAmount := q.FieldByName('amount').AsFloat;
    q.Close;
  finally
    q.Free;
  end;
end;

procedure TDbForm.RefreshStat;
begin
  if FQryStat = nil then
  begin
    FQryStat := TSQLQuery.Create(Self);
    FQryStat.Name := 'FQryStat';
    FQryStat.Database := FConn;
    FQryStat.Transaction := FTrans;
    FDsStat := TDataSource.Create(Self);
    FDsStat.Name := 'FDsStat';
    FDsStat.DataSet := FQryStat;
    if Assigned(grdStat) then
      grdStat.DataSource := FDsStat;
  end;
  if FQryStat.Active then
    FQryStat.Close;
  FQryStat.SQL.Text :=
    'SELECT category, COUNT(*) AS n, COALESCE(SUM(stock),0) AS qty, ' +
    'ROUND(COALESCE(SUM(price*stock),0),2) AS amount FROM items ' +
    BuildWhere + ' GROUP BY category ORDER BY amount DESC';
  FQryStat.Open;

  if Assigned(lblStatSum) then
    lblStatSum.Caption := Format('合计 %d 个品项 · 库存 %d 件 · 货值 ¥%.2f',
      [FTotal, FQty, FAmount]);
end;

{ ==================== 数据源接线 ==================== }

{ 布局全在 uDbMain.lfm 里（设计期摆位，代码不再 Create / SetBounds）。
   这里只接两样 lfm 接不了的东西：
     1. DataSource —— 它是 SetupData 运行时创建的对象，lfm 里没有可引用的实例；
     2. 下拉候选值 —— 来自 CATEGORIES 常量，写进 lfm 会两处维护。
   其余的 Options / 列定义 / 字体 / DataField / OnClick 都已在 lfm 里。 }
procedure TDbForm.BindDataSources;
begin
  grdMain.DataSource := FDs;
  edCode.DataSource := FDs;
  edName.DataSource := FDs;
  edPrice.DataSource := FDs;
  edStock.DataSource := FDs;
  cbCategory.DataSource := FDs;
  mmMemo.DataSource := FDs;

  grdStat.DataSource := FDsStat;

  cbFilterCat.Items.Clear;
  cbFilterCat.Items.Add('全部分类');
  cbFilterCat.Items.AddStrings(CATEGORIES);
  cbFilterCat.ItemIndex := 0;

  cbCategory.Items.Clear;
  cbCategory.Items.AddStrings(CATEGORIES);
end;

{ ==================== 附件：磁盘 + attachments 表 ==================== }

function TDbForm.AttachRoot: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'attachments';
end;

function TDbForm.AttachDirOf(AItemId: Integer): string;
begin
  Result := IncludeTrailingPathDelimiter(AttachRoot) + 'item' + IntToStr(AItemId);
end;

function TDbForm.AttachPathOf(AItemId: Integer; const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(AttachDirOf(AItemId)) + AName;
end;

{ 同名附件不覆盖，自动加 -2 / -3 后缀 }
function TDbForm.UniqueAttachName(const ADir, AName: string): string;
var
  base, ext: string;
  n: Integer;
begin
  Result := AName;
  if not FileExists(IncludeTrailingPathDelimiter(ADir) + Result) then Exit;
  base := ChangeFileExt(AName, '');
  ext := ExtractFileExt(AName);
  n := 2;
  repeat
    Result := Format('%s-%d%s', [base, n, ext]);
    Inc(n);
  until (n > 999) or (not FileExists(IncludeTrailingPathDelimiter(ADir) + Result));
end;

{ 不用 FileUtil.CopyFile：手写流复制，失败能拿到具体异常，
   也不会因为目标盘符不同而行为不一 }
procedure TDbForm.CopyFileRaw(const ASrc, ADst: string);
var
  si, so: TFileStream;
begin
  si := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
  try
    so := TFileStream.Create(ADst, fmCreate);
    try
      so.CopyFrom(si, 0);
    finally
      so.Free;
    end;
  finally
    si.Free;
  end;
end;

function TDbForm.AttachNameOf(AId: Integer): string;
var
  q: TSQLQuery;
begin
  Result := '';
  q := TSQLQuery.Create(nil);
  try
    q.Database := FConnAtt;
    q.Transaction := FTransAtt;
    q.SQL.Text := 'SELECT file_name FROM attachments WHERE id=:aid';
    q.ParamByName('aid').AsInteger := AId;
    q.Open;
    try
      if not q.IsEmpty then
        Result := q.FieldByName('file_name').AsString;
    finally
      q.Close;
    end;
  finally
    q.Free;
  end;
  { 读完就提交：这个连接不能把读事务一直挂着，否则下次看到的还是旧快照 }
  if FTransAtt.Active then
    FTransAtt.Commit;
end;

procedure TDbForm.ClearAttachList;
begin
  SetLength(FAttachIds, 0);
  FAttachShownId := -1;
  if Assigned(lstAttach) then lstAttach.Items.Clear;
  if Assigned(lblAttachInfo) then lblAttachInfo.Caption := '附件：—';
  if Assigned(btnAttachOpen) then btnAttachOpen.Enabled := False;
  if Assigned(btnAttachDel) then btnAttachDel.Enabled := False;
end;

procedure TDbForm.RefreshAttach;
var
  q: TSQLQuery;
  itemId, i, totalKb, sizeKb: Integer;
  nm: string;
begin
  if not Assigned(lstAttach) then Exit;

  SetLength(FAttachIds, 0);
  lstAttach.Items.Clear;

  itemId := 0;
  if FQry.Active and (not FQry.IsEmpty) then
    itemId := FQry.FieldByName('id').AsInteger;
  FAttachShownId := itemId;

  if itemId = 0 then
  begin
    lblAttachInfo.Caption := '附件：先选中一条商品';
    btnAttachOpen.Enabled := False;
    btnAttachDel.Enabled := False;
    Exit;
  end;

  totalKb := 0;
  q := TSQLQuery.Create(nil);
  try
    q.Database := FConnAtt;
    q.Transaction := FTransAtt;
    q.SQL.Text := 'SELECT id, file_name, size_kb FROM attachments ' +
      'WHERE item_id=:iid ORDER BY id';
    q.ParamByName('iid').AsInteger := itemId;
    q.Open;
    try
      while not q.EOF do
      begin
        nm := q.FieldByName('file_name').AsString;
        sizeKb := q.FieldByName('size_kb').AsInteger;
        lstAttach.Items.Add(Format('%s   (%d KB)', [nm, sizeKb]));
        i := Length(FAttachIds);
        SetLength(FAttachIds, i + 1);
        FAttachIds[i] := q.FieldByName('id').AsInteger;
        Inc(totalKb, sizeKb);
        q.Next;
      end;
    finally
      q.Close;
    end;
  finally
    q.Free;
  end;

  if FTransAtt.Active then
    FTransAtt.Commit;

  if lstAttach.Items.Count > 0 then
  begin
    lblAttachInfo.Caption := Format('附件：%d 个 · 共 %d KB',
      [lstAttach.Items.Count, totalKb]);
    lstAttach.ItemIndex := 0;
    btnAttachOpen.Enabled := True;
    btnAttachDel.Enabled := True;
  end
  else
  begin
    lblAttachInfo.Caption := '附件：暂无（点"上传…"添加）';
    btnAttachOpen.Enabled := False;
    btnAttachDel.Enabled := False;
  end;
end;


{ ==================== 状态显示 ==================== }

procedure TDbForm.UpdateStatus;
var
  st: string;
  id: Integer;
begin
  case FQry.State of
    dsEdit: st := '编辑中（改完点保存）';
    dsInsert: st := '新增中（填好点保存）';
  else
    st := '浏览';
  end;

  if Assigned(lblState) then
    lblState.Caption := '状态：' + st;

  if Assigned(lblDetail) then
  begin
    if FQry.Active and (not FQry.IsEmpty) then
      lblDetail.Caption := Format('%s / %s · 更新于 %s',
        [FQry.FieldByName('code').AsString,
         FQry.FieldByName('category').AsString,
         FQry.FieldByName('updated').AsString])
    else
      lblDetail.Caption := '（当前没有记录）';
  end;

  if Assigned(lblInfo) then
    if FQry.Active and (FTotal > 0) then
      lblInfo.Caption := Format('第 %d / %d 条 · 排序：%s %s',
        [FQry.RecNo, FTotal, FSortField, FSortDir])
    else
      lblInfo.Caption := '没有匹配的记录';

  if Assigned(sbMain) then
  begin
    sbMain.Panels[0].Text := '状态: ' + st;
    if FQry.Active then
      sbMain.Panels[1].Text := Format('记录 %d/%d', [Max(FQry.RecNo, 0), FTotal])
    else
      sbMain.Panels[1].Text := '记录 0/0';
    sbMain.Panels[2].Text := Format('库存 %d 件 · 货值 ¥%.2f', [FQty, FAmount]);
  end;

  { 换了记录就重读它的附件列表（id 没变就不查库，避免每次刷新状态都打一次 SQL） }
  if Assigned(lstAttach) then
  begin
    if FQry.Active and (not FQry.IsEmpty) then
      id := FQry.FieldByName('id').AsInteger
    else
      id := 0;
    if id <> FAttachShownId then
      RefreshAttach;
  end;
end;

procedure TDbForm.LogSQL(const AText: string);
begin
  if not Assigned(mmoLog) then Exit;
  mmoLog.Lines.Add('[' + FormatDateTime('hh:nn:ss', Now) + '] ' + AText);
  while mmoLog.Lines.Count > 300 do
    mmoLog.Lines.Delete(0);
end;

procedure TDbForm.ApplyFilter;
begin
  if FQry.State in [dsEdit, dsInsert] then
    FQry.Cancel;
  Requery;
  RefreshStat;
  LogSQL('查询 -> ' + BuildSQL);
end;

{ ==================== 事件 ==================== }

procedure TDbForm.btnQueryClick(Sender: TObject);
begin
  ApplyFilter;
end;

procedure TDbForm.btnResetClick(Sender: TObject);
begin
  edFind.Text := '';
  cbFilterCat.ItemIndex := 0;
  chkLowStock.Checked := False;
  FSortField := 'id';
  FSortDir := 'ASC';
  ApplyFilter;
end;

procedure TDbForm.btnNewClick(Sender: TObject);
var
  n: Integer;
begin
  if FQry.State in [dsEdit, dsInsert] then
    FQry.Cancel;
  FQry.Append;
  n := FTotal + 1;
  FQry.FieldByName('code').AsString := Format('P%.4d', [1000 + n]);
  FQry.FieldByName('name').AsString := '新商品 ' + IntToStr(n);
  FQry.FieldByName('category').AsString := CATEGORIES[0];
  FQry.FieldByName('price').AsFloat := 0;
  FQry.FieldByName('stock').AsInteger := 0;
  FQry.FieldByName('memo').AsString := '';
  FQry.FieldByName('updated').AsString := FormatDateTime('yyyy-mm-dd hh:nn', Now);
  UpdateStatus;
  LogSQL('Append：已追加一条空白记录，填好后点保存');
end;

procedure TDbForm.btnSaveClick(Sender: TObject);
var
  code, pname: string;
  keepId: Integer;
begin
  if not (FQry.State in [dsEdit, dsInsert]) then
  begin
    LogSQL('保存：当前没有待提交的修改');
    Exit;
  end;

  code := Trim(FQry.FieldByName('code').AsString);
  pname := Trim(FQry.FieldByName('name').AsString);
  if (code = '') or (pname = '') then
  begin
    LogSQL('保存失败：编码和名称不能为空');
    sbMain.Panels[0].Text := '保存失败：编码和名称不能为空';
    Exit;
  end;

  FQry.FieldByName('updated').AsString := FormatDateTime('yyyy-mm-dd hh:nn', Now);
  { WAL 模式下还有第二把锁：BUSY_SNAPSHOT。本会话的读事务是几分钟前打开的，
    期间别的会话已经提交过 —— 读事务升级为写时快照过期，SQLite 直接报
    database is locked，而且 busy_timeout 对这个错误【不生效】。
    CommitRetaining = COMMIT + BEGIN：把旧读事务（旧快照）扔掉，新事务的
    快照要到第一条语句才取，所以紧接着的 UPDATE 拿到的是最新数据版。
    顺带把"编辑时点过别的行"造成的隐式 auto-Post 一并提交掉。 }
  FTrans.CommitRetaining;
  FQry.Post;
  LogSQL('Post：已提交 ' + code + ' / ' + pname);
  { sqoAutoApplyUpdates 只把 SQL 发给 SQLite，事务仍是打开的 ——
    这里必须 Commit 才真正落库、释放写锁。Commit 会关闭本事务上的
    数据集（FQry/FQryStat 都在内），所以先记住 id，下面 Requery 重开。 }
  keepId := FQry.FieldByName('id').AsInteger;
  FTrans.Commit;
  Requery(keepId);
  RefreshStat;
end;

procedure TDbForm.btnCancelClick(Sender: TObject);
begin
  if FQry.State in [dsEdit, dsInsert] then
  begin
    FQry.Cancel;
    LogSQL('Cancel：放弃本次修改');
  end;
  UpdateStatus;
end;

procedure TDbForm.btnDeleteClick(Sender: TObject);
var
  code: string;
begin
  if FQry.IsEmpty then Exit;
  code := FQry.FieldByName('code').AsString;
  if FQry.State in [dsEdit, dsInsert] then
    FQry.Cancel;
  { 删除同理：先丢旧读快照（CommitRetaining），DELETE 在新事务里执行，
    再 Commit 落库并释放写锁（Commit 会关数据集，Requery 重开） }
  FTrans.CommitRetaining;
  FQry.Delete;
  LogSQL('Delete：已删除 ' + code);
  FTrans.Commit;
  Requery;
  RefreshStat;
end;

procedure TDbForm.btnNavClick(Sender: TObject);
begin
  if FQry.State in [dsEdit, dsInsert] then
    FQry.Cancel;
  if Sender = btnFirst then FQry.First
  else if Sender = btnPrev then FQry.Prior
  else if Sender = btnNext then FQry.Next
  else if Sender = btnLast then FQry.Last;
  UpdateStatus;
end;

procedure TDbForm.grdTitleClick(Column: TColumn);
var
  f: string;
begin
  if Column = nil then Exit;
  f := Column.FieldName;
  if f = '' then Exit;
  if SameText(f, FSortField) then
  begin
    if FSortDir = 'ASC' then FSortDir := 'DESC' else FSortDir := 'ASC';
  end
  else
  begin
    FSortField := f;
    FSortDir := 'ASC';
  end;
  ApplyFilter;
end;

procedure TDbForm.grdCellClick(Column: TColumn);
begin
  { 游标位置已经由框架在调用本事件之前挪好了，这里只刷新状态显示 }
  UpdateStatus;
end;

procedure TDbForm.FieldChanged(Sender: TObject);
begin
  UpdateStatus;
end;

{ ==================== 附件事件 ==================== }

{ 浏览器上传完成（服务端已落临时目录）后由框架调用。
   Multiple=True 时选了几个文件就触发几次。 }
procedure TDbForm.btnUploadUpload(Sender: TObject; const AFileName: string);
var
  itemId: Integer;
  dir, nm, dest: string;
  fs: TFileStream;
  sizeKb: Integer;
begin
  if not (FQry.Active and (not FQry.IsEmpty)) then
  begin
    LogSQL('上传失败：当前没有选中商品');
    Exit;
  end;
  if FQry.State = dsInsert then
  begin
    LogSQL('上传失败：新记录还没入库，先点"保存"拿到编号再传附件');
    Exit;
  end;
  if not FileExists(AFileName) then
  begin
    LogSQL('上传失败：服务端临时文件不见了 ' + AFileName);
    Exit;
  end;

  itemId := FQry.FieldByName('id').AsInteger;
  dir := AttachDirOf(itemId);
  if not ForceDirectories(dir) then
  begin
    LogSQL('上传失败：建不了目录 ' + dir);
    Exit;
  end;

  { 浏览器给的文件名不可信：LWSafeFileName 会去掉路径、..、盘符、非法字符，
    这里再补一层"同名不覆盖" }
  nm := LWSafeFileName(ExtractFileName(AFileName));
  nm := UniqueAttachName(dir, nm);
  dest := AttachPathOf(itemId, nm);

  { 控件把文件落在临时目录 —— 那里会被下载令牌清扫和系统清理掉，
    长期附件必须搬到商品自己的目录 }
  try
    CopyFileRaw(AFileName, dest);
  except
    on E: Exception do
    begin
      LogSQL('上传失败：' + E.ClassName + ' / ' + E.Message);
      Exit;
    end;
  end;

  fs := TFileStream.Create(dest, fmOpenRead or fmShareDenyNone);
  try
    sizeKb := (fs.Size + 1023) div 1024;
  finally
    fs.Free;
  end;

  { 附件写在自己的连接/事务上：不会打断正在编辑的商品记录 }
  FConnAtt.ExecuteDirect(Format(
    'INSERT INTO attachments(item_id,file_name,size_kb,uploaded) VALUES(%d,%s,%d,%s)',
    [itemId, QuotedStr(nm), sizeKb,
     QuotedStr(FormatDateTime('yyyy-mm-dd hh:nn', Now))]));
  FTransAtt.Commit;

  LogSQL(Format('上传：%s -> attachments/item%d/（%d KB）', [nm, itemId, sizeKb]));

  { 复制完就把临时文件删掉。两个原因：
    1) 临时目录里的东西会被下载令牌清扫和系统清理，留着没用；
    2) 框架落盘时会自动去重（同名 -> xxx_1.txt），临时目录若一直攒着
       同名文件，下次上传拿到的"原名"就变成 xxx_1.txt 了 —— 删掉之后
       每次都是干净的原名，改名规则统一由 UniqueAttachName 的 -2 负责。 }
  DeleteFile(AFileName);
  if Sender is TLWFileUpload then
    TLWFileUpload(Sender).ClearUploaded;

  RefreshAttach;
  UpdateStatus;
end;

procedure TDbForm.btnAttachOpenClick(Sender: TObject);
var
  idx, aid, itemId: Integer;
  nm, path: string;
begin
  idx := lstAttach.ItemIndex;
  if (idx < 0) or (idx > High(FAttachIds)) then
  begin
    LogSQL('下载：没选中附件');
    Exit;
  end;
  aid := FAttachIds[idx];
  itemId := FAttachShownId;

  nm := AttachNameOf(aid);
  if nm = '' then
  begin
    LogSQL('下载失败：附件记录已不存在（可能被另一个会话删了）');
    RefreshAttach;
    Exit;
  end;

  path := AttachPathOf(itemId, nm);
  if not FileExists(path) then
  begin
    LogSQL('下载失败：磁盘上找不到 ' + path);
    Exit;
  end;

  { SendFile 发一条 download 指令：服务端生成一次性令牌，
    浏览器用隐藏 <a download> 保存文件 —— URL 里不含服务端路径 }
  SendFile(path, nm);
  LogSQL('下载：' + nm);
end;

procedure TDbForm.btnAttachDelClick(Sender: TObject);
var
  idx, aid, itemId: Integer;
  nm, path: string;
begin
  idx := lstAttach.ItemIndex;
  if (idx < 0) or (idx > High(FAttachIds)) then Exit;
  aid := FAttachIds[idx];
  itemId := FAttachShownId;

  nm := AttachNameOf(aid);
  if nm = '' then
  begin
    RefreshAttach;
    Exit;
  end;

  FConnAtt.ExecuteDirect('DELETE FROM attachments WHERE id=' + IntToStr(aid));
  FTransAtt.Commit;

  path := AttachPathOf(itemId, nm);
  if FileExists(path) and (not DeleteFile(path)) then
    LogSQL('已删记录，但磁盘文件删不掉：' + path)
  else
    LogSQL('删除附件：' + nm);

  RefreshAttach;
  UpdateStatus;
end;

end.
