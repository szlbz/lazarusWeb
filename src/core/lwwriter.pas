{
  lazarusWeb :: lwwriter
  ------------------------------------------------------------------
  LCL 控件树 -> JSON 组件树。

  这是整个框架的"翻译层"：把设计期拖出来的 TButton/TEdit/TStringGrid…
  连同坐标、字体、颜色、Tab 顺序、已挂接的事件名，翻译成浏览器端
  Ext JS 可以直接消费的结构。浏览器端只认这些 kind：

    form panel groupbox scrollbox frame label static
    button bitbtn speedbutton edit editbtn maskedit memo spin floatspin
    checkbox radio combo listbox grid drawgrid tree listview
    tabs tabctl tabsheet toolbar toolbutton statusbar progress trackbar image
    splitter
    dbgrid dbedit dbmemo dbcheckbox dbcombo     <- 数据感知控件
    htmlframe pdfframe                          <- 富内容显示（uniHTML/uniPDF）
    chart                                       <- 图表（uniChart，ext charts 包）
    dateedit timeedit datetimeedit              <- 日期/时间选择器（TDateEdit 族）
    unknown

  任何未识别的控件都会退化成 'unknown'（渲染成一个带类名的占位框），
  而不是直接消失 —— 迁移时能立刻看出哪些控件还没适配。
}
unit lwwriter;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Variants, Graphics, Controls, Forms, StdCtrls, ExtCtrls, ComCtrls,
  Grids, Menus, Buttons, MaskEdit, Spin, CheckLst, ValEdit, TypInfo, LCLProc, fpjson,
  EditBtn, GroupedEdit, DB, DBCtrls, DBGrids, lwbase, lwform, lwfileupload, lwdbnav, lwweb,
  lwchart, lwdbgrid, lwui, lwrlog;

type
  TLWWriter = class
  private
    FIds: TLWIdFunc;
    function NodeId(C: TComponent): Integer;
    function CaptionOf(C: TControl): string;
    function WriteEvents(C: TComponent; AForceClick: Boolean): TJSONArray;
    function WriteChildren(WC: TWinControl): TJSONArray;
    function WriteMenuItems(MI: TMenuItem): TJSONArray;
    function StatusPanels(SB: TStatusBar): TJSONArray;
    procedure WriteKindProps(C: TControl; const AKind: string; O: TJSONObject);
    procedure WriteKindPropsBody(C: TControl; const AKind: string; O: TJSONObject);
    function MakeBase(C: TControl; const AKind: string): TJSONObject;
    procedure WriteImage(C: TImage; O: TJSONObject);
    procedure WritePicture(pic: TPicture; AStretch, ACenter: Boolean;
      O: TJSONObject);
    procedure WriteGrid(G: TStringGrid; O: TJSONObject);
    procedure WriteDrawGrid(G: TDrawGrid; O: TJSONObject);
    procedure WriteDBGrid(G: TDBGrid; O: TJSONObject);
    function DBCellsRow(G: TDBGrid; const AEtv: array of Byte;
      const AFilter: string; out AVisible: Boolean): TJSONArray;
    procedure WriteLookupCombo(L: TDBLookupComboBox; O: TJSONObject);
    procedure WriteLookupList(L: TDBLookupListBox; O: TJSONObject);
    procedure WriteLookupItems(AListSource: TDataSource;
      const AKeyField, AListField: string; O: TJSONObject);
    procedure WriteDBField(C: TControl; O: TJSONObject);
    procedure WriteTree(T: TTreeView; O: TJSONObject);
    procedure WriteListView(L: TListView; O: TJSONObject);
    function TreeNodeJson(N: TTreeNode): TJSONObject;
  public
    constructor Create(AIds: TLWIdFunc);
    destructor Destroy; override;
    function WriteForm(AForm: TCustomForm; AIsModal: Boolean): TJSONObject;
    function WriteControl(C: TControl): TJSONObject;
  end;

{ 临时剖析：按 kind 打印耗时（LW_KIND_PROF=1 时才有数据）}
procedure LWKindProfReport;

implementation

{ ---- 临时剖析：按 kind 累计 WriteKindProps 的耗时（LW_KIND_PROF=1 打开）---- }
var
  GKindProfOn: Boolean = False;
  GKindProfInit: Boolean = False;
  GKindT0: Int64 = 0;
  GWalkT0: Int64 = 0;
  GKindNames: array of string;
  GKindCnt: array of Integer;
  GKindUS: array of Int64;

procedure KindProfAdd(const AKind: string; AUS: Int64);
var
  i: Integer;
begin
  if not GKindProfOn then Exit;
  for i := 0 to High(GKindNames) do
    if GKindNames[i] = AKind then
    begin
      Inc(GKindCnt[i]);
      Inc(GKindUS[i], AUS);
      Exit;
    end;
  i := Length(GKindNames);
  SetLength(GKindNames, i + 1);
  SetLength(GKindCnt, i + 1);
  SetLength(GKindUS, i + 1);
  GKindNames[i] := AKind;
  GKindCnt[i] := 1;
  GKindUS[i] := AUS;
end;

procedure KindProfStart;
begin
  if not GKindProfInit then
  begin
    GKindProfInit := True;
    GKindProfOn := GetEnvironmentVariable('LW_KIND_PROF') <> '';
  end;
  if not GKindProfOn then Exit;
  GKindT0 := LWNowUS;
end;

procedure KindProfStop(const AKind: string);
begin
  if not GKindProfOn then Exit;
  KindProfAdd(AKind, LWNowUS - GKindT0);
end;

procedure LWKindProfReport;
var
  i, j: Integer;
  s: string;
  n: string;
  c: Integer;
  u: Int64;
begin
  if High(GKindNames) < 0 then Exit;
  for i := 0 to High(GKindNames) - 1 do
    for j := 0 to High(GKindNames) - 1 - i do
      if GKindUS[j] < GKindUS[j + 1] then
      begin
        n := GKindNames[j]; GKindNames[j] := GKindNames[j + 1]; GKindNames[j + 1] := n;
        c := GKindCnt[j]; GKindCnt[j] := GKindCnt[j + 1]; GKindCnt[j + 1] := c;
        u := GKindUS[j]; GKindUS[j] := GKindUS[j + 1]; GKindUS[j + 1] := u;
      end;
  s := '';
  for i := 0 to High(GKindNames) do
    s := s + GKindNames[i] + '=' + IntToStr(GKindCnt[i]) + '/' + IntToStr(GKindUS[i]) + 'us ';
  WriteLn(StdErr, '[kindprof] ' + s);
end;


{ 控件内部自己造出来的辅助控件（如 TStringGrid 的 TStringCellEditor），
  它们不出现在对象检视器里，也不应该发到浏览器 }
function IsInternalControl(C: TControl): Boolean;
begin
  Result :=
    C.ClassNameIs('TStringCellEditor') or
    C.ClassNameIs('TMemoCellEditor') or
    C.ClassNameIs('TGridEdit') or
    C.ClassNameIs('TListHotTrackEntry') or
    C.ClassNameIs('THeaderControl') or
    { TDBNavigator 内部生成的按钮：navigator 自己以 buttons 数组下发 }
    C.ClassNameIs('TDBNavButton') or
    C.ClassNameIs('TDBNavFocusableButton') or
    { TRadioGroup / TCheckGroup 内部生成的单选/复选按钮：
      组控件自己以 items/checked 数组下发，不发这些子控件 }
    ((C.Parent <> nil) and
     ((C.Parent is TCustomRadioGroup) or (C.Parent is TCustomCheckGroup) or
      { TCustomEditButton 族内部生成的编辑器与"…"按钮：控件本体以
        editbtn 下发，这些子控件不能发（否则多了两个无名杂散节点） }
      (C.Parent is TCustomAbstractGroupedEdit)));
  { TTabControl 内部用 TCustomNotebook + TTabSheet 实现：内部页签控件
    全部以 Owner=TTabControl 挂在设计器控件之外，tabctl 自己用
    tabitems 下发页签文字，这些内部件不能发 }
  if (C.Owner <> nil) and (C.Owner is TTabControl) then Exit(True);
  Result := Result or C.ClassNameIs('TNoteBookStringsTabControl');
end;

function KindOf(C: TControl): string;
begin
  { DB 感知控件必须排在同族的普通控件之前判断：
    TDBEdit/TDBMemo/TDBCheckBox/TDBComboBox 都不是 TEdit/TMemo/TCheckBox/TComboBox，
    但保持这个顺序可以避免以后换实现时踩坑 }
  if C is TDBGrid then Result := 'dbgrid'
  else if C is TDBNavigator then Result := 'dbnav'
  else if C is TLWFileUpload then Result := 'fileupload'
  else if C is TDBEdit then Result := 'dbedit'
  else if C is TDBMemo then Result := 'dbmemo'
  else if C is TDBCheckBox then Result := 'dbcheckbox'
  else if C is TDBComboBox then Result := 'dbcombo'
  { TDBText 就是"显示字段值的标签"，直接复用 label 渲染 }
  else if C is TDBText then Result := 'label'
  else if C is TDBListBox then Result := 'dblistbox'
  else if C is TDBLookupListBox then Result := 'dblookuplist'
  else if C is TDBLookupComboBox then Result := 'dblookup'
  else if C is TDBRadioGroup then Result := 'dbradiogroup'
  else if C is TDBImage then Result := 'dbimage'
  { 顺序敏感：TRadioGroup/TCheckGroup 会落进 groupbox、TCheckListBox 会
    落进 listbox、TValueListEditor 会落进 grid —— 必须先判。
    TLWHTMLFrame/TLWPDFFrame/TLWChart 是 TCustomPanel 后代，也必须先判；
    TDateEdit 族是 TCustomEditButton（TCustomEdit）后代，也要先判 }
  else if C is TLWHTMLFrame then Result := 'htmlframe'
  else if C is TLWPDFFrame then Result := 'pdfframe'
  else if C is TLWChart then Result := 'chart'
  else if C is TLWGauge then Result := 'gauge'
  else if C is TLWColorPicker then Result := 'color'
  else if C is TTimeEdit then Result := 'timeedit'
  else if C is TDateEdit then Result := 'dateedit'
  { TCustomEditButton 的其余后代（TFileNameEdit / TDirectoryEdit /
    TCalcEdit…）：带"…按钮"的单行编辑框。不识别时它们退化成 unknown
    占位框，还会把内部的 TEdit/TSpeedButton 泄漏成两个杂散节点 }
  else if C is TCustomEditButton then Result := 'editbtn'
  else if C is TValueListEditor then Result := 'valeditor'
  else if C is TRadioGroup then Result := 'radiogroup'
  else if C is TCheckGroup then Result := 'checkgroup'
  else if C is TCheckListBox then Result := 'checklistbox'
  else if C is TPageControl then Result := 'tabs'
  else if C is TTabSheet then Result := 'tabsheet'
  { TTabControl（不是 TPageControl）：Tabs 字符串列表 + 一块公共客户区，
    没有 TTabSheet 子对象。单独成 kind，浏览器端用单卡片 tabpanel 渲染 }
  else if C is TTabControl then Result := 'tabctl'
  else if C is TStringGrid then Result := 'grid'
  else if C is TDrawGrid then Result := 'drawgrid'
  else if C is TTreeView then Result := 'tree'
  else if C is TListView then Result := 'listview'
  else if C is TToolBar then Result := 'toolbar'
  else if C is TToolButton then Result := 'toolbutton'
  else if C is TStatusBar then Result := 'statusbar'
  else if C is TProgressBar then Result := 'progress'
  else if C is TTrackBar then Result := 'trackbar'
  else if C is TUpDown then Result := 'updown'
  else if C is TMemo then Result := 'memo'
  else if C is TMaskEdit then Result := 'maskedit'
  else if C is TSpinEdit then Result := 'spin'
  else if C is TFloatSpinEdit then Result := 'floatspin'
  else if C is TEdit then Result := 'edit'
  else if C is TCustomEdit then Result := 'edit'   { TLabeledEdit / TFileNameEdit / TDateEdit … }
  else if C is TComboBox then Result := 'combo'
  else if C is TListBox then Result := 'listbox'
  { TToggleBox 是 TCustomCheckBox 后代而非 TButton —— 不识别会落 unknown。
    语义是"可保持按下"的按钮：按 button 渲染，Checked 作 down 下发 }
  else if C is TToggleBox then Result := 'button'
  else if C is TCheckBox then Result := 'checkbox'
  else if C is TRadioButton then Result := 'radio'
  else if C is TGroupBox then Result := 'groupbox'
  else if C is TScrollBox then Result := 'scrollbox'
  else if C is TPanel then Result := 'panel'
  else if C is TImage then Result := 'image'
  { TLabeledEdit 的标签是 TBoundLabel（TLabel 后代）。不识别时会渲染成
    (0,0) 处的 unknown 占位框、'姓名' 之类文字整个丢失 }
  else if C is TBoundLabel then Result := 'label'
  else if C is TLabel then Result := 'label'
  else if C is TStaticText then Result := 'static'
  else if C is TBitBtn then Result := 'bitbtn'
  { TCustomButton 覆盖 TToggleBox / TColorButton —— 它们不是 TButton/
    TBitBtn/TSpeedButton，之前落 unknown。按普通按钮渲染，TToggleBox
    另发 down（Checked）恢复"可保持按下"的语义 }
  else if C is TCustomButton then Result := 'button'
  else if C is TButton then Result := 'button'
  else if C is TSpeedButton then Result := 'speedbutton'
  else if C is TSplitter then Result := 'splitter'
  else if C is TBevel then Result := 'bevel'
  else if C is TShape then Result := 'shape'
  else if C is TFrame then Result := 'frame'
  else if C is TCustomForm then Result := 'form'
  else Result := 'unknown';
end;

constructor TLWWriter.Create(AIds: TLWIdFunc);
begin
  inherited Create;
  FIds := AIds;
end;

destructor TLWWriter.Destroy;
begin
  inherited Destroy;
end;

function TLWWriter.NodeId(C: TComponent): Integer;
begin
  if not Assigned(FIds) then Exit(0);
  Result := FIds(C);
end;

function TLWWriter.CaptionOf(C: TControl): string;
var
  s: string;
begin
  Result := '';
  if IsPublishedProp(C, 'Caption') then
    s := GetStrProp(C, 'Caption')
  else
    Exit;
  { 设计器里 TPanel/TToolBar 的 Caption 默认等于控件名，别渲染出来 }
  if s = C.Name then Exit;
  if SameText(s, 'pnl' + C.Name) then Exit;
  Result := s;
end;

function TLWWriter.WriteEvents(C: TComponent; AForceClick: Boolean): TJSONArray;
var
  PL: PPropList;
  n, i: Integer;
  M: TMethod;
  evT0: Int64;
begin
  Result := TJSONArray.Create;
  if C = nil then Exit;
  if GKindProfOn then
    evT0 := LWNowUS;
  n := GetPropList(C, PL);
  if n > 0 then
  begin
    try
      for i := 0 to n - 1 do
        if PL^[i]^.PropType^.Kind = tkMethod then
        begin
          M := GetMethodProp(C, PL^[i]);
          if Assigned(M.Code) and IsLWClickEvent(PL^[i]^.Name) then
            JArrAddStr(Result, PL^[i]^.Name);
        end;
    finally
      FreeMem(PL);
    end;
  end;
  if AForceClick and (not JArrHasStr(Result, 'OnClick')) then
    JArrAddStr(Result, 'OnClick');
  if GKindProfOn then
    KindProfAdd('~events', LWNowUS - evT0);
end;

function TLWWriter.MakeBase(C: TControl; const AKind: string): TJSONObject;
var
  o: TJSONObject;
  force: Boolean;
begin
  o := TJSONObject.Create;
  o.Add('id', NodeId(C));
  o.Add('kind', AKind);
  o.Add('name', C.Name);
  o.Add('cls', C.ClassName);
  o.Add('x', C.Left);
  o.Add('y', C.Top);
  o.Add('w', C.Width);
  o.Add('h', C.Height);
  o.Add('align', AlignToStr(C.Align));
  o.Add('caption', CaptionOf(C));
  o.Add('enabled', C.Enabled);
  o.Add('visible', C.Visible);
  { Hint 有值就下发，由浏览器端显示（Ext QuickTips）。
    不按 TControl.ShowHint 过滤：nogui 下它的默认值/继承跟 GUI 不一致
    （绝大多数控件读出来是 False），按它过滤会把全部提示都关掉。
    全局开关还是尊重的：Application.ShowHint=False 就一个提示都不出。 }
  if (not Assigned(Application)) or Application.ShowHint then
    o.Add('hint', C.Hint)
  else
    o.Add('hint', '');
  o.Add('fg', ColorToCSS(C.Font.Color));
  { TShape 的填充色在 Brush.Color 里，TControl.Color 对它是无效属性
    （设计期摆的圆角矩形如果只读 Color，浏览器端拿到的就是空串 → 白底
    白边框那块"看不见"）。装饰性控件统一按 Brush 取色。 }
  if C is TShape then
    o.Add('bg', ColorToCSS(TShape(C).Brush.Color))
  else
    o.Add('bg', ColorToCSS(C.Color));
  o.Add('font', FontToJSON(C.Font));
  if C is TWinControl then
  begin
    o.Add('tab', TWinControl(C).TabOrder);
    o.Add('tabstop', TWinControl(C).TabStop);
  end;
  { 按钮即使是"模态结果按钮"也必须回传点击，交给服务端处理 ModalResult }
  force := False;
  if (C is TButton) then
    force := TButton(C).ModalResult <> mrNone;
  o.Add('ev', WriteEvents(C, force));
  { 右键菜单：TControl.PopupMenu 挂哪个就写哪个。菜单项照旧用
    WriteMenuItems（和主菜单同一套结构与事件），浏览器端 contextmenu 弹出来 }
  if TControl(C).PopupMenu <> nil then
    o.Add('popup', WriteMenuItems(TControl(C).PopupMenu.Items));
  Result := o;
end;

procedure TLWWriter.WritePicture(pic: TPicture; AStretch, ACenter: Boolean;
  O: TJSONObject);
var
  png: TPortableNetworkGraphic;
  ms: TMemoryStream;
begin
  O.Add('src', '');
  O.Add('stretch', AStretch);
  O.Add('center', ACenter);
  if (pic = nil) or (pic.Graphic = nil) then Exit;
  ms := TMemoryStream.Create;
  png := TPortableNetworkGraphic.Create;
  try
    try
      png.Assign(pic.Graphic);
      png.SaveToStream(ms);
      ms.Position := 0;
      O.Delete('src');
      O.Add('src', 'data:image/png;base64,' + Base64FromStream(ms));
    except
      { nogui 下某些图元无法导出，忽略即可，前端显示占位 }
    end;
  finally
    png.Free;
    ms.Free;
  end;
end;

procedure TLWWriter.WriteImage(C: TImage; O: TJSONObject);
begin
  WritePicture(C.Picture, C.Stretch, C.Center, O);
end;

procedure TLWWriter.WriteGrid(G: TStringGrid; O: TJSONObject);
var
  cols, rows, cw: TJSONArray;
  row: TJSONArray;
  c, r, rmax, rh: Integer;
  s: string;
begin
  cols := TJSONArray.Create;
  for c := 0 to G.ColCount - 1 do
  begin
    if (G.FixedRows > 0) and (G.RowCount > 0) then
      JArrAddStr(cols, G.Cells[c, 0])
    else
      JArrAddStr(cols, 'Col' + IntToStr(c));
  end;
  O.Add('cols', cols);

  cw := TJSONArray.Create;
  for c := 0 to G.ColCount - 1 do
    cw.Add(G.ColWidths[c]);
  O.Add('colwidths', cw);

  rows := TJSONArray.Create;
  rmax := G.RowCount - 1;
  if rmax > LW_MAX_GRID_ROWS then rmax := LW_MAX_GRID_ROWS;
  for r := G.FixedRows to rmax do
  begin
    row := TJSONArray.Create;
    for c := 0 to G.ColCount - 1 do
      JArrAddStr(row, G.Cells[c, r]);
    rows.Add(row);
  end;
  O.Add('rows', rows);
  O.Add('fixedcols', G.FixedCols);
  O.Add('fixedrows', G.FixedRows);
  O.Add('readonly', G.Options * [goEditing] = []);
  { nogui 下 Canvas.TextHeight 拿到的是虚拟值，不可靠；
    优先用窗体里真正设过的行高，再退回到一个稳妥的默认值 }
  rh := G.DefaultRowHeight;
  if (G.RowCount > 0) and (G.RowHeights[0] > 0) then
    rh := G.RowHeights[0];
  if rh < 16 then
    rh := 22;
  O.Add('rowheight', rh);
  O.Add('truncated', G.RowCount - 1 > LW_MAX_GRID_ROWS);
end;

{ TDrawGrid 没有字符串 Cells（自绘网格），但行列结构与列宽必须发给
  浏览器端 —— 之前没有这个分支，gallery 的 TDrawGrid 渲染成空白格。
  内容按空字符串下发（前端画 5x5 空格子，固定行/列样式照常）。 }
{ TDrawGrid 没有 Cells/Objects 字符串存储（那是 TCustomStringGrid 的）。
  自绘标记文本放在 lwui 的 TLWDrawCellStore 仓库里（LWSetDrawCellText
  写入、以网格为 Owner 挂靠），writer 从仓库读取。 }
function LWDrawGridCellText(G: TDrawGrid; c, r: Integer): string;
begin
  Result := LWGetDrawCellText(G, c, r);
end;

procedure TLWWriter.WriteDrawGrid(G: TDrawGrid; O: TJSONObject);
var
  cols, rows, cw: TJSONArray;
  row: TJSONArray;
  c, r, rmax, rh: Integer;
begin
  { 表头列名取固定行第 0 行的 Cells（TDrawGrid 没有独立 HeaderText，
    惯例：FixedRows>=1 时第 0 行就是列标题；FixedRows=0 则列名为空 } ;
  cols := TJSONArray.Create;
  for c := 0 to G.ColCount - 1 do
    if G.FixedRows > 0 then
      JArrAddStr(cols, LWDrawGridCellText(G, c, 0))
    else
      JArrAddStr(cols, '');
  O.Add('cols', cols);

  cw := TJSONArray.Create;
  for c := 0 to G.ColCount - 1 do
    cw.Add(G.ColWidths[c]);
  O.Add('colwidths', cw);

  { 自 2026-11-13 起下发真实单元格文本：DrawGrid 单元格可以放自绘标记
    （@bar(72) / @chip(文本,颜色) / @spark(v1,v2…) / @stars(4.5)），
    浏览器端 $lwDrawCell 把标记渲染成进度条/徽章/迷你图/星级；
    nogui 是无头 widgetset（假 DC），LCL 级 OnDrawCell 画不出像素，
    自绘只能在浏览器端做 —— 这是框架唯一可行路径 }
  rows := TJSONArray.Create;
  rmax := G.RowCount - 1;
  if rmax > LW_MAX_GRID_ROWS then rmax := LW_MAX_GRID_ROWS;
  for r := G.FixedRows to rmax do
  begin
    row := TJSONArray.Create;
    for c := 0 to G.ColCount - 1 do
      JArrAddStr(row, LWDrawGridCellText(G, c, r));
    rows.Add(row);
  end;
  O.Add('rows', rows);
  O.Add('fixedcols', G.FixedCols);
  O.Add('fixedrows', G.FixedRows);
  O.Add('readonly', True);
  rh := G.DefaultRowHeight;
  if rh < 16 then
    rh := 22;
  O.Add('rowheight', rh);
  O.Add('truncated', False);
end;

{ TLWDBGrid 的匹配书签表：每次序列化前先清空 }
procedure lwgMatchesInit(lwg: TLWDBGrid);
begin
  if lwg <> nil then lwg.MatchClear;
end;

procedure lwgMatchesAdd(lwg: TLWDBGrid; bm: TBookmark);
begin
  if lwg <> nil then lwg.MatchAdd(bm);
end;

{ UTF8 串的"显示单位数"：CJK 等全宽字符算 2，其余算 1
  （网页端 13px 字号下半角约 7-8px、全角约 14px，估列宽够用） }
function lwWideUnits(const S: string): Integer;
var
  ws: WideString;
  i: Integer;
begin
  Result := 0;
  ws := UTF8Decode(S);
  for i := 1 to Length(ws) do
  begin
    if Ord(ws[i]) > $7F then
      Inc(Result, 2)
    else
      Inc(Result, 1);
  end;
end;

{ nogui 下窗体句柄没建，TColumn.Width 走无句柄 Canvas 的字体度量
  （CalcColumnFieldWidth / Scale96ToFont），退化成 6px 这类个位数 ——
  gallery 数据感知页的 TDBGrid 列全被挤成一条细线。真实列宽至少
  30px 上下，小于 24 视为退化，按"标题 / 字段显示宽度"估一个
  网页像素宽（CJK 双宽），兜底 40、封顶 400。 }
function lwDbColWidth(col: TColumn): Integer;
var
  s: string;
  units: Integer;
begin
  Result := col.Width;
  if Result >= 24 then Exit;

  s := col.Title.Caption;
  if s = '' then
  begin
    if col.Field <> nil then
      s := col.Field.DisplayLabel;
    if s = '' then
      s := col.FieldName;
  end;
  units := lwWideUnits(s);
  if (col.Field <> nil) and (col.Field.DisplayWidth > units) then
    units := col.Field.DisplayWidth;
  Result := units * 8 + 20;
  if Result < 40 then Result := 40;
  if Result > 400 then Result := 400;
end;

{ 把"当前记录"按可见列取成一行单元格文本。
  AFilter 非空时顺带判断这行是否命中（命中/未命中写进 AVisible）；
  AFilter 为空时 AVisible 恒真，调用方可以据此跳过不需要下发的行。 }
function TLWWriter.DBCellsRow(G: TDBGrid; const AEtv: array of Byte;
  const AFilter: string; out AVisible: Boolean): TJSONArray;
var
  i: Integer;
  col: TColumn;
  f: TField;
  cell: string;
begin
  Result := TJSONArray.Create;
  AVisible := (AFilter = '');
  for i := 0 to G.Columns.Count - 1 do
  begin
    col := TColumn(G.Columns[i]);
    if not col.Visible then Continue;
    f := col.Field;
    if f = nil then
    begin
      JArrAddStr(Result, '');
      Continue;
    end;
    case AEtv[i] of
      3:
        begin
          { 日期列：固定发 ISO 'yyyy-mm-dd'，前端 date 输入直接吃；
            显示层也统一成这个无歧义格式 }
          if f.IsNull then
            cell := ''
          else
            cell := FormatDateTime('yyyy-mm-dd', f.AsDateTime);
        end;
      4:
        begin
          { 布尔列：发 '1'/'0' 作为勾选框状态。不走 DisplayText ——
            那可能是 True/False，也可能被业务改成"是/否"，前端没法当
            布尔值用 }
          if (not f.IsNull) and f.AsBoolean then
            cell := '1'
          else
            cell := '0';
        end;
    else
      cell := f.DisplayText;
    end;
    JArrAddStr(Result, cell);
    if (not AVisible) and (Pos(AFilter, LowerCase(cell)) > 0) then
      AVisible := True;
  end;
end;

procedure TLWWriter.WriteDBGrid(G: TDBGrid; O: TJSONObject);
var
  ds: TDataSet;
  cols, fields, cw, cedit, plist, rows, row: TJSONArray;
  i, cnt, rh: Integer;
  k: Integer;
  bm: TBookmark;
  col: TColumn;
  f: TField;
  st: string;
  cell: string;
  items: TJSONArray;
  { 每列的编辑器类型（下标与 G.Columns 一致，含隐藏列占位）：
    1=text 2=PickList 下拉 3=日期选择 4=复选框（布尔列） }
  etv: array of Byte;
  { TLWDBGrid 扩展（分页/过滤/汇总）；普通 TDBGrid 时为 nil，行为完全不变 }
  lwg: TLWDBGrid;
  ft: string;
  filtered, pageStart, pageEnd, curMatch, matchIdx: Integer;
  sumVal: Double;
  sumCnt: Integer;
  sumObj: TJSONObject;
  pages: Integer;
  sumField: TField;
  visible: Boolean;
begin
  lwg := nil;
  if G is TLWDBGrid then lwg := TLWDBGrid(G);
  ft := '';
  if lwg <> nil then
  begin
    ft := LowerCase(Trim(lwg.FilterText));
    O.Add('showfilter', lwg.ShowFilter);
    O.Add('pagesize', lwg.PageSize);
    O.Add('filtertext', lwg.FilterText);
    O.Add('page', lwg.CurrentPage);
  end;

  cols := TJSONArray.Create;
  fields := TJSONArray.Create;
  cw := TJSONArray.Create;
  cedit := TJSONArray.Create;
  plist := TJSONArray.Create;
  SetLength(etv, G.Columns.Count);
  for i := 0 to G.Columns.Count - 1 do
  begin
    col := TColumn(G.Columns[i]);
    if not col.Visible then Continue;
    if col.Title.Caption <> '' then
      JArrAddStr(cols, col.Title.Caption)
    else if col.Field <> nil then
      JArrAddStr(cols, col.Field.DisplayLabel)
    else
      JArrAddStr(cols, col.FieldName);
    JArrAddStr(fields, col.FieldName);
    cw.Add(lwDbColWidth(col));
    { 单元格可编辑：整表开了 dgEditing，且这一列没有单独只读
      （列只读 / 字段只读，如自增主键）。前端据此决定挂不挂编辑器。
      编辑器类型：1=文本（默认）；2=下拉（TColumn.PickList 非空，
      plist 按同下标带选项列表）；3=日期选择（日期/时间戳字段，
      浏览器渲染成 date 输入，回传 ISO 'yyyy-mm-dd'）；4=复选框
      （布尔字段，单元格常驻勾选框，点一下即写回 '1'/'0'）。
      旧前端把任何非 0 当文本编辑器，新属性不影响旧版渲染。 }
    if (col.Field <> nil) and (not col.ReadOnly) and (not col.Field.ReadOnly) then
    begin
      { 布尔列优先判定：这类字段不需要 PickList / 日期编辑器，
        LCL 桌面端 TDBGrid 也是直接画一个勾选框 }
      if col.Field is TBooleanField then
      begin
        etv[i] := 4;
        cedit.Add(4);
        plist.Add(TJSONArray.Create);
      end
      else if col.PickList.Count > 0 then
      begin
        etv[i] := 2;
        cedit.Add(2);
        items := TJSONArray.Create;
        for k := 0 to col.PickList.Count - 1 do
          items.Add(col.PickList[k]);
        plist.Add(items);
      end
      else if (col.Field is TDateField) or (col.Field.ClassType = TDateTimeField) then
      begin
        etv[i] := 3;
        cedit.Add(3);
        plist.Add(TJSONArray.Create);
      end
      else
      begin
        etv[i] := 1;
        cedit.Add(1);
        plist.Add(TJSONArray.Create);
      end;
    end
    else
    begin
      etv[i] := 0;
      cedit.Add(0);
      plist.Add(TJSONArray.Create);
    end;
  end;
  O.Add('cols', cols);
  O.Add('fields', fields);
  O.Add('colwidths', cw);
  O.Add('cedit', cedit);
  O.Add('plist', plist);
  O.Add('readonly', not (dgEditing in G.Options));

  rh := G.DefaultRowHeight;
  if rh < 16 then
    rh := 22;
  O.Add('rowheight', rh);

  ds := nil;
  if G.DataSource <> nil then
    ds := G.DataSource.DataSet;
  if (ds = nil) or (not ds.Active) then
  begin
    O.Add('rows', TJSONArray.Create);
    O.Add('recno', 0);
    O.Add('count', 0);
    O.Add('state', 'closed');
    if lwg <> nil then
    begin
      O.Add('total', 0);
      O.Add('pages', 1);
      lwg.MatchClear;
    end
    else
      O.Add('truncated', False);
    Exit;
  end;

  try
    O.Add('recno', ds.RecNo);
  except
    O.Add('recno', 0);
  end;

  case ds.State of
    dsEdit: st := 'edit';
    dsInsert: st := 'insert';
    dsSetKey: st := 'setkey';
  else
    st := 'browse';
  end;
  O.Add('state', st);

  { 实测：TDataSet 处于 dsEdit/dsInsert 时移动游标会自动 Post。
    这里只是想"看一眼"数据，绝不能顺手把用户改了一半的记录提交掉，
    所以编辑态下干脆不输出行，浏览器沿用上一次拿到的数据 }
  if ds.State <> dsBrowse then Exit;

  sumField := nil;
  if (lwg <> nil) and (lwg.SummaryType <> gsNone) and (lwg.SummaryField <> '') then
    sumField := ds.FindField(lwg.SummaryField);

  { 遍历：先做显示层过滤（可见列的"包含匹配"），把匹配行收进书签表；
    分页时只下发当前页那一小段。整段在 DisableControls 里走 }
  rows := TJSONArray.Create;
  cnt := 0;
  filtered := 0;
  curMatch := -1;
  matchIdx := -1;
  sumVal := 0;
  sumCnt := 0;
  pageStart := 0;
  pageEnd := MaxInt;
  if (lwg <> nil) and (lwg.PageSize > 0) then
  begin
    pageStart := (lwg.CurrentPage - 1) * lwg.PageSize;
    pageEnd := pageStart + lwg.PageSize;
  end;
  lwgMatchesInit(lwg);

  bm := ds.GetBookmark;
  ds.DisableControls;
  if GKindProfOn then
    GWalkT0 := LWNowUS;
  try
    try
      ds.First;
      while (not ds.Eof) and (cnt < LW_MAX_GRID_ROWS) do
      begin
        row := nil;
        if ft = '' then
          visible := True
        else
          { 有过滤时绕不开：得先拿到每格的文本才能判断这行命中不命中 }
          row := DBCellsRow(G, etv, ft, visible);

        if visible then
        begin
          Inc(filtered);
          Inc(matchIdx);
          { 只有 TLWDBGrid 才需要匹配行书签。原来是先建书签再判空 ——
            普通 TDBGrid 每行白造一个书签，且没有任何人释放它 }
          if lwg <> nil then
            lwgMatchesAdd(lwg, ds.GetBookmark);
          { 当前记录在匹配序列里的位置（recno 按页内行号发）}
          try
            if curMatch < 0 then
              if ds.CompareBookmarks(bm, ds.Bookmark) = 0 then
                curMatch := matchIdx;
          except
          end;
          if sumField <> nil then
          begin
            sumVal := sumVal + sumField.AsFloat;
            Inc(sumCnt);
          end;
          if (matchIdx >= pageStart) and (matchIdx < pageEnd) then
          begin
            { 到这里才真正读字段：1000 行的表只发 50 行，
              另外 950 行的 DisplayText 原来全是白算的 }
            if row = nil then
              row := DBCellsRow(G, etv, '', visible);
            rows.Add(row);
            row := nil;          { 交给 rows 拥有 }
            Inc(cnt);
          end;
        end;

        if row <> nil then
          row.Free;              { 不在本页 / 被过滤掉 }
        ds.Next;
      end;
    except
      { 遍历中途出错就返回已取到的部分，不影响其它控件序列化 }
    end;
  finally
    if GKindProfOn then
      KindProfAdd('~walk', LWNowUS - GWalkT0);
    if bm <> nil then
    begin
      try
        ds.GotoBookmark(bm);
      except
      end;
      ds.FreeBookmark(bm);
    end;
    ds.EnableControls;
  end;
  O.Add('rows', rows);
  O.Add('count', cnt);
  O.Add('truncated', filtered >= LW_MAX_GRID_ROWS);

  if lwg = nil then Exit;

  { ---- TLWDBGrid 专属：页信息 / recno 映射 / 汇总 ---- }
  pages := lwg.PageOf(filtered);
  if lwg.CurrentPage > pages then lwg.CurrentPage := pages;
  if lwg.CurrentPage < 1 then lwg.CurrentPage := 1;
  O.Delete('page');
  O.Add('page', lwg.CurrentPage);
  O.Add('pages', pages);
  O.Add('total', filtered);
  { 浏览器端的"选中行"是页内行号：当前记录不在本页时发 0（取消选中）}
  if (lwg.PageSize > 0) then
  begin
    pageStart := (lwg.CurrentPage - 1) * lwg.PageSize;
    if (curMatch >= pageStart) and (curMatch < pageStart + lwg.PageSize) then
      matchIdx := curMatch - pageStart + 1
    else
      matchIdx := 0;
    O.Delete('recno');
    O.Add('recno', matchIdx);
  end;

    if (lwg.SummaryType <> gsNone) and (lwg.SummaryField <> '') then
    begin
      sumObj := TJSONObject.Create;
      sumObj.Add('field', lwg.SummaryField);
      case lwg.SummaryType of
        gsSum: sumObj.Add('type', 'sum');
        gsAvg: sumObj.Add('type', 'avg');
        gsCount: sumObj.Add('type', 'count');
      else
        sumObj.Add('type', 'none');
      end;
      if lwg.SummaryType = gsCount then
        sumObj.Add('value', Format('%.0f', [Double(sumCnt)]))
      else if (lwg.SummaryType = gsAvg) and (sumCnt > 0) then
        sumObj.Add('value', Format('%.2f', [sumVal / sumCnt]))
      else
        sumObj.Add('value', Format('%.2f', [sumVal]));
      O.Add('summary', sumObj);
    end;
end;

{ 取 DB 控件的绑定字段，非 DB 控件返回 nil }
function LWDBControlField(C: TControl): TField;
begin
  Result := nil;
  if C is TDBEdit then
    Result := TDBEdit(C).Field
  else if C is TDBMemo then
    Result := TDBMemo(C).Field
  else if C is TDBCheckBox then
    Result := TDBCheckBox(C).Field
  else if C is TDBComboBox then
    Result := TDBComboBox(C).Field
  else if C is TDBText then
    Result := TDBText(C).Field
  else if C is TDBListBox then
    Result := TDBListBox(C).Field
  else if C is TDBLookupListBox then
    Result := TDBLookupListBox(C).Field
  else if C is TDBRadioGroup then
    Result := TDBRadioGroup(C).Field
  else if C is TDBImage then
    Result := TDBImage(C).Field
  else if C is TDBLookupComboBox then
    Result := TDBLookupComboBox(C).Field;
end;

{ 下拉型 lookup：Value 是 KeyField，显示的是 ListField，
  所以要把两份列表都发给浏览器（text 用来显示，key 用来回写）。 }
procedure TLWWriter.WriteLookupItems(AListSource: TDataSource;
  const AKeyField, AListField: string; O: TJSONObject);
var
  ds: TDataSet;
  bm: TBookmark;
  items, keys: TJSONArray;
  kf, lf: TField;
begin
  items := TJSONArray.Create;
  keys := TJSONArray.Create;
  ds := nil;
  if AListSource <> nil then
    ds := AListSource.DataSet;
  if (ds <> nil) and ds.Active then
  begin
    kf := ds.FindField(AKeyField);
    lf := ds.FindField(AListField);
    bm := ds.GetBookmark;
    ds.DisableControls;
    try
      try
        ds.First;
        while not ds.Eof do
        begin
          if kf <> nil then
            keys.Add(kf.AsString)
          else
            keys.Add('');
          if lf <> nil then
            JArrAddStr(items, lf.DisplayText)
          else
            JArrAddStr(items, '');
          ds.Next;
        end;
      except
      end;
    finally
      if bm <> nil then
      begin
        try
          ds.GotoBookmark(bm);
        except
        end;
        ds.FreeBookmark(bm);
      end;
      ds.EnableControls;
    end;
  end;
  O.Add('items', items);
  O.Add('keys', keys);
end;

{ 当前选中的键：优先用绑定字段的值。
  TDBLookupComboBox.KeyValue 依赖 DataLink 的缓存，数据集重新打开后可能还没刷上
  （实测保存后取到空串），而 DataField 本身就是外键字段，直接读它最可靠。 }
function LookupKeyOf(AListSource: TDataSource; AKeyField: string;
  AField: TField; AKeyValue: Variant): string;
begin
  if (AField <> nil) and (AField.DataSet <> nil) and AField.DataSet.Active then
    Result := AField.AsString
  else
    Result := VarToStr(AKeyValue);
end;

procedure TLWWriter.WriteLookupCombo(L: TDBLookupComboBox; O: TJSONObject);
begin
  O.Add('key', LookupKeyOf(L.ListSource, L.KeyField, L.Field, L.KeyValue));
  WriteLookupItems(L.ListSource, L.KeyField, L.ListField, O);
end;

procedure TLWWriter.WriteLookupList(L: TDBLookupListBox; O: TJSONObject);
var
  key: string;
  d: TJSONData;
  arr: TJSONArray;
  i, idx: Integer;
begin
  key := LookupKeyOf(L.ListSource, L.KeyField, L.Field, L.KeyValue);
  O.Add('key', key);
  WriteLookupItems(L.ListSource, L.KeyField, L.ListField, O);
  { ItemIndex 同样可能滞后，按 key 在 keys 里的位置算一个可靠值 }
  idx := -1;
  d := O.Find('keys');
  if d is TJSONArray then
  begin
    arr := TJSONArray(d);
    for i := 0 to arr.Count - 1 do
      if arr.Strings[i] = key then
      begin
        idx := i;
        Break;
      end;
  end;
  O.Add('index', idx);
end;

procedure TLWWriter.WriteDBField(C: TControl; O: TJSONObject);
var
  f: TField;
  txt, fname: string;
  ro: Boolean;
begin
  f := LWDBControlField(C);
  fname := '';
  txt := '';
  ro := True;
  if f <> nil then
  begin
    fname := f.FieldName;
    { TMemoField/BlobField 的 DisplayText 是 "(MEMO)" 这种占位串，
      真正要显示的内容得走 AsString }
    if (f is TBlobField) and not (f is TMemoField) then
      txt := ''
    else if f is TMemoField then
      txt := f.AsString
    else
      txt := f.DisplayText;
    ro := f.ReadOnly or (f.DataSet = nil) or (f.DataSet.State = dsInactive);
    if C is TDBEdit then
      ro := ro or TDBEdit(C).ReadOnly
    else if C is TDBMemo then
      ro := ro or TDBMemo(C).ReadOnly;
  end;
  O.Add('field', fname);
  O.Add('text', txt);
  O.Add('readonly', ro);
end;

function TLWWriter.StatusPanels(SB: TStatusBar): TJSONArray;
var
  i: Integer;
begin
  Result := TJSONArray.Create;
  for i := 0 to SB.Panels.Count - 1 do
    JArrAddStr(Result, SB.Panels[i].Text);
end;

function TLWWriter.TreeNodeJson(N: TTreeNode): TJSONObject;
var
  o: TJSONObject;
  arr: TJSONArray;
  ch: TTreeNode;
begin
  o := TJSONObject.Create;
  o.Add('text', N.Text);
  o.Add('expanded', N.Expanded);
  o.Add('selected', N.Selected);
  o.Add('level', N.Level);
  arr := TJSONArray.Create;
  ch := N.GetFirstChild;
  while ch <> nil do
  begin
    arr.Add(TreeNodeJson(ch));
    ch := ch.GetNextSibling;
  end;
  o.Add('children', arr);
  Result := o;
end;

procedure TLWWriter.WriteTree(T: TTreeView; O: TJSONObject);
var
  arr: TJSONArray;
  n: TTreeNode;
begin
  arr := TJSONArray.Create;
  n := T.Items.GetFirstNode;
  while n <> nil do
  begin
    arr.Add(TreeNodeJson(n));
    n := n.GetNextSibling;
  end;
  O.Add('nodes', arr);
  O.Add('rowselect', T.RowSelect);
  { LCL TTreeView 默认 bsSingle 有边框；不下发前端无从得知（坑 86） }
  O.Add('border', BorderStyleToStr(T.BorderStyle));
end;

procedure TLWWriter.WriteListView(L: TListView; O: TJSONObject);
var
  cols, rows, row: TJSONArray;
  i, j: Integer;
  it: TListItem;
begin
  cols := TJSONArray.Create;
  for i := 0 to L.Columns.Count - 1 do
    JArrAddStr(cols, L.Columns[i].Caption);
  O.Add('cols', cols);

  rows := TJSONArray.Create;
  for i := 0 to L.Items.Count - 1 do
  begin
    it := L.Items[i];
    row := TJSONArray.Create;
    JArrAddStr(row, it.Caption);
    for j := 0 to it.SubItems.Count - 1 do
      JArrAddStr(row, it.SubItems[j]);
    rows.Add(row);
  end;
  O.Add('rows', rows);
  O.Add('viewstyle', Ord(L.ViewStyle));
end;

procedure TLWWriter.WriteKindProps(C: TControl; const AKind: string; O: TJSONObject);
begin
  KindProfStart;
  try
    WriteKindPropsBody(C, AKind, O);
  finally
    KindProfStop(AKind);
  end;
end;

procedure TLWWriter.WriteKindPropsBody(C: TControl; const AKind: string; O: TJSONObject);
var
  items, vals: TJSONArray;
  bts: TJSONArray;
  b: TJSONObject;
  bt: TDBNavButtonType;
  a: TControl;
  le: TCustomLabeledEdit;
  lx, ly, sp: Integer;
  i, j: Integer;
begin
  if AKind = 'label' then
  begin
    { TDBText 的 Caption 由 LCL 的 DataChange 填，但 nogui 下这个赋值链
      并不总能落到 Caption 上（实测一直为空）。直接读绑定字段的 DisplayText，
      语义也更准：标签显示的就是字段当前值。 }
    if C is TDBText then
    begin
      if TDBText(C).Field <> nil then
        O.Add('text', TDBText(C).Field.DisplayText)
      else
        O.Add('text', '');
    end
    else
      O.Add('text', CaptionOf(C));
    if C is TLabel then
    begin
      O.Add('wordwrap', TLabel(C).WordWrap);
      O.Add('textalign', Ord(TLabel(C).Alignment));
      O.Add('layout', Ord(TLabel(C).Layout));
      { AutoSize=True 时 LCL 把盒子缩到文字宽，Alignment（taCenter）因此
        不起作用、文字贴着 Left。nogui 虚拟显示器量不准 CJK 字宽，直接把
        设计期宽度（约等于整窗宽）下发、浏览器再对盒子做 text-align:center，
        标题就会被推到窗中央（About 对话框标题跑中间就是这个）。
        把 AutoSize 下发，浏览器端让 DOM 自适应宽度，与真实 LCL 一致。 }
      O.Add('autosize', TLabel(C).AutoSize);
    end;
    { TBoundLabel（TLabeledEdit 的标签）：nogui 下 LCL 的锚点没机会解析，
      位置是 (0,0)。按 LCL 的 DoPositionLabel 语义（枚举 lpAbove/lpBelow/
      lpLeft/lpRight = 0/1/2/3，间距默认 3）+ 宿主编辑框的最终边界重摆；
      浏览器端渲染后还会按标签真实宽度精修一次 }
    if C is TBoundLabel then
    begin
      if (C.Owner is TCustomLabeledEdit) then
      begin
        le := TCustomLabeledEdit(C.Owner);
        sp := le.LabelSpacing;
        if sp <= 0 then sp := 3;
        O.Add('boundfor', le.Name);
        O.Add('labelpos', Ord(le.LabelPosition));
        { 浏览器端按这个间距贴编辑框；LCL 的 LabelSpacing 默认 3 }
        O.Add('labelspacing', sp);
        case le.LabelPosition of
          lpAbove: begin lx := le.Left; ly := le.Top - C.Height - sp; end;
          lpBelow: begin lx := le.Left; ly := le.Top + le.Height + sp; end;
          lpLeft:  begin lx := le.Left - C.Width - sp;
                         ly := le.Top + (le.Height - C.Height) div 2; end;
          lpRight: begin lx := le.Left + le.Width + sp;
                         ly := le.Top + (le.Height - C.Height) div 2; end;
        else begin lx := C.Left; ly := C.Top; end;
        end;
        O.Elements['x'] := TJSONIntegerNumber.Create(lx);
        O.Elements['y'] := TJSONIntegerNumber.Create(ly);
      end;
    end;
  end
  else if AKind = 'edit' then
  begin
    O.Add('text', TEdit(C).Text);
    O.Add('readonly', TEdit(C).ReadOnly);
    O.Add('password', TEdit(C).PasswordChar <> #0);
    O.Add('maxlength', TEdit(C).MaxLength);
    O.Add('alignment', Ord(TEdit(C).Alignment));
  end
  else if AKind = 'maskedit' then
  begin
    O.Add('text', TMaskEdit(C).Text);
    O.Add('readonly', TMaskEdit(C).ReadOnly);
    O.Add('editmask', TMaskEdit(C).EditMask);
  end
  else if AKind = 'memo' then
  begin
    O.Add('text', TMemo(C).Lines.Text);
    O.Add('readonly', TMemo(C).ReadOnly);
    O.Add('scrollbars', Ord(TMemo(C).ScrollBars));
    O.Add('wordwrap', TMemo(C).WordWrap);
  end
  else if AKind = 'spin' then
  begin
    O.Add('value', TSpinEdit(C).Value);
    O.Add('min', TSpinEdit(C).MinValue);
    O.Add('max', TSpinEdit(C).MaxValue);
  end
  else if AKind = 'floatspin' then
  begin
    O.Add('value', TFloatSpinEdit(C).Value);
    O.Add('min', TFloatSpinEdit(C).MinValue);
    O.Add('max', TFloatSpinEdit(C).MaxValue);
    O.Add('decimals', TFloatSpinEdit(C).DecimalPlaces);
  end
  else if AKind = 'checkbox' then
  begin
    O.Add('checked', TCheckBox(C).Checked);
    O.Add('allowgrayed', TCheckBox(C).AllowGrayed);
    O.Add('state', Ord(TCheckBox(C).State));
  end
  else if AKind = 'radio' then
  begin
    O.Add('checked', TRadioButton(C).Checked);
    if C.Parent <> nil then
      O.Add('group', C.Parent.Name)
    else
      O.Add('group', '');
  end
  else if (AKind = 'combo') then
  begin
    items := TJSONArray.Create;
    for i := 0 to TComboBox(C).Items.Count - 1 do
      JArrAddStr(items, TComboBox(C).Items[i]);
    O.Add('items', items);
    O.Add('index', TComboBox(C).ItemIndex);
    O.Add('text', TComboBox(C).Text);
    O.Add('editable', TComboBox(C).Style <> csDropDownList);
    O.Add('sorted', TComboBox(C).Sorted);
  end
  else if AKind = 'listbox' then
  begin
    items := TJSONArray.Create;
    for i := 0 to TListBox(C).Items.Count - 1 do
      JArrAddStr(items, TListBox(C).Items[i]);
    O.Add('items', items);
    O.Add('index', TListBox(C).ItemIndex);
    O.Add('multiselect', TListBox(C).MultiSelect);
    O.Add('sorted', TListBox(C).Sorted);
    { LCL TListBox 默认 bsSingle：浏览器端要画出边框（坑 85） }
    O.Add('border', BorderStyleToStr(TListBox(C).BorderStyle));
  end
  else if AKind = 'dbgrid' then
    WriteDBGrid(TDBGrid(C), O)
  else if AKind = 'dbnav' then
  begin
    { TDBNavigator（原生类型；nogui 下实例是 lwdbnav 的子类）：
      按 LCL 的按钮顺序下发可见按钮与各自 Enabled。Enabled 由 LCL 的
      DataChanged / EditingChanged 随数据集状态维护，这里只读。 }
    bts := TJSONArray.Create;
    for bt := Low(TDBNavButtonType) to High(TDBNavButtonType) do
      if bt in TDBNavigator(C).VisibleButtons then
      begin
        b := TJSONObject.Create;
        b.Add('id', LWNavBtnToId(bt));
        b.Add('en', LWNavBtnEnabled(TDBNavigator(C), bt));
        bts.Add(b);
      end;
    O.Add('buttons', bts);
  end
  else if AKind = 'dbedit' then
  begin
    WriteDBField(C, O);
    O.Add('password', TDBEdit(C).PasswordChar <> #0);
    O.Add('alignment', Ord(TDBEdit(C).Alignment));
  end
  else if AKind = 'dbmemo' then
  begin
    WriteDBField(C, O);
    O.Add('scrollbars', Ord(TDBMemo(C).ScrollBars));
    O.Add('wordwrap', TDBMemo(C).WordWrap);
  end
  else if AKind = 'dbcheckbox' then
  begin
    WriteDBField(C, O);
    if LWDBControlField(C) <> nil then
      O.Add('checked', LWDBControlField(C).AsBoolean)
    else
      O.Add('checked', TDBCheckBox(C).Checked);
  end
  else if AKind = 'dbcombo' then
  begin
    WriteDBField(C, O);
    items := TJSONArray.Create;
    for i := 0 to TDBComboBox(C).Items.Count - 1 do
      JArrAddStr(items, TDBComboBox(C).Items[i]);
    O.Add('items', items);
  end
  else if AKind = 'dblistbox' then
  begin
    WriteDBField(C, O);
    items := TJSONArray.Create;
    for i := 0 to TDBListBox(C).Items.Count - 1 do
      JArrAddStr(items, TDBListBox(C).Items[i]);
    O.Add('items', items);
    O.Add('index', TDBListBox(C).ItemIndex);
    O.Add('border', BorderStyleToStr(TDBListBox(C).BorderStyle));
  end
  else if AKind = 'dbimage' then
  begin
    WriteDBField(C, O);
    WritePicture(TDBImage(C).Picture, TDBImage(C).Stretch, TDBImage(C).Center, O);
  end
  else if AKind = 'dblookuplist' then
  begin
    WriteDBField(C, O);
    WriteLookupList(TDBLookupListBox(C), O);
  end
  else if AKind = 'dbradiogroup' then
  begin
    WriteDBField(C, O);
    items := TJSONArray.Create;
    for i := 0 to TDBRadioGroup(C).Items.Count - 1 do
      JArrAddStr(items, TDBRadioGroup(C).Items[i]);
    O.Add('items', items);
    vals := TJSONArray.Create;
    for i := 0 to TDBRadioGroup(C).Values.Count - 1 do
      JArrAddStr(vals, TDBRadioGroup(C).Values[i]);
    O.Add('values', vals);
    O.Add('value', TDBRadioGroup(C).Value);
  end
  else if AKind = 'radiogroup' then
  begin
    items := TJSONArray.Create;
    for i := 0 to TRadioGroup(C).Items.Count - 1 do
      JArrAddStr(items, TRadioGroup(C).Items[i]);
    O.Add('items', items);
    O.Add('index', TRadioGroup(C).ItemIndex);
    O.Add('cols', TRadioGroup(C).Columns);
  end
  else if AKind = 'checkgroup' then
  begin
    items := TJSONArray.Create;
    vals := TJSONArray.Create;
    for i := 0 to TCheckGroup(C).Items.Count - 1 do
    begin
      JArrAddStr(items, TCheckGroup(C).Items[i]);
      vals.Add(TCheckGroup(C).Checked[i]);
    end;
    O.Add('items', items);
    O.Add('checked', vals);
    O.Add('cols', TCheckGroup(C).Columns);
  end
  else if AKind = 'checklistbox' then
  begin
    items := TJSONArray.Create;
    vals := TJSONArray.Create;
    for i := 0 to TCheckListBox(C).Items.Count - 1 do
    begin
      JArrAddStr(items, TCheckListBox(C).Items[i]);
      vals.Add(TCheckListBox(C).Checked[i]);
    end;
    O.Add('items', items);
    O.Add('checked', vals);
    O.Add('index', TCheckListBox(C).ItemIndex);
    O.Add('border', BorderStyleToStr(TCheckListBox(C).BorderStyle));
  end
  else if AKind = 'valeditor' then
  begin
    { 键值对编辑器。注意 LCL 的怪癖：Keys[i]=Cells[0,i] 是网格行号
      （0 = 标题行），而 Strings.Count 是数据行数（不含标题行）。
      所以数据行是网格行 1..Strings.Count。 }
    items := TJSONArray.Create;
    vals := TJSONArray.Create;
    for i := 1 to TValueListEditor(C).Strings.Count do
    begin
      JArrAddStr(items, TValueListEditor(C).Keys[i]);
      JArrAddStr(vals, TValueListEditor(C).Values[TValueListEditor(C).Keys[i]]);
    end;
    O.Add('keys', items);
    O.Add('values', vals);
    O.Add('titles', TValueListEditor(C).TitleCaptions.CommaText);
    try
      O.Add('selrow', TValueListEditor(C).Row - 1);
    except
      O.Add('selrow', -1);
    end;
  end
  else if AKind = 'dblookup' then
  begin
    WriteDBField(C, O);
    WriteLookupCombo(TDBLookupComboBox(C), O);
  end
  else if AKind = 'grid' then
    WriteGrid(TStringGrid(C), O)
  else if AKind = 'drawgrid' then
    WriteDrawGrid(TDrawGrid(C), O)
  else if AKind = 'tree' then
    WriteTree(TTreeView(C), O)
  else if AKind = 'listview' then
    WriteListView(TListView(C), O)
  else if AKind = 'bitbtn' then
  begin
    { Kind 映射成浏览器端的图标按钮（bkCustom=0 不加图标）；
      nogui 下读 Kind 若抛异常（位图资源缺失）就按 bkCustom 处理 }
    try
      O.Add('btnkind', Ord(TBitBtn(C).Kind));
    except
      O.Add('btnkind', 0);
    end;
  end
  else if AKind = 'speedbutton' then
  begin
    { 按下态 + 组号：浏览器端据此恢复"可保持按下"的观感 }
    O.Add('down', TSpeedButton(C).Down);
    O.Add('groupindex', TSpeedButton(C).GroupIndex);
  end
  else if AKind = 'progress' then
  begin
    O.Add('pos', TProgressBar(C).Position);
    O.Add('min', TProgressBar(C).Min);
    O.Add('max', TProgressBar(C).Max);
    O.Add('orientation', Ord(TProgressBar(C).Orientation));
  end
  else if AKind = 'trackbar' then
  begin
    O.Add('pos', TTrackBar(C).Position);
    O.Add('min', TTrackBar(C).Min);
    O.Add('max', TTrackBar(C).Max);
    O.Add('frequency', TTrackBar(C).Frequency);
    { 竖直滑条（Orientation=trVertical）：不下发的话浏览器端渲染成横的 }
    O.Add('orientation', Ord(TTrackBar(C).Orientation));
  end
  else if AKind = 'updown' then
  begin
    O.Add('value', TUpDown(C).Position);
    O.Add('min', Integer(TUpDown(C).Min));
    O.Add('max', Integer(TUpDown(C).Max));
    { TUpDown 挂了 Associate 之后，LCL 会在 Associate 的 ChangeBounds 里
      用 UpdateAlignButtonPos 自己挪位置。lfm 里的 DesignTimePPI（IDE 保存
      窗体时按显示器 DPI 写成 144）和服务端 nogui 的 96 PPI 不一致时，
      AutoAdjustLayout 的缩放过程中会触发这个回调，回调按"缩放了一半"的
      边界算位置，之后自身再被缩放一次 → 坐标彻底跑偏（gallery 里 TUpDown
      飘到 trackbar 上方就是这样）。这里直接按 Associate 的最终边界推导，
      与 PPI 缩放无关，浏览器端稳定贴着编辑框。 }
    if (C is TUpDown) and (TUpDown(C).Associate <> nil) then
    begin
      a := TUpDown(C).Associate;
      case TUpDown(C).AlignButton of
        udLeft:
          begin
            O.Elements['x'] := TJSONIntegerNumber.Create(a.Left - C.Width);
            O.Elements['y'] := TJSONIntegerNumber.Create(a.Top);
          end;
        udTop:
          begin
            O.Elements['x'] := TJSONIntegerNumber.Create(a.Left);
            O.Elements['y'] := TJSONIntegerNumber.Create(a.Top - C.Height);
          end;
        udBottom:
          begin
            O.Elements['x'] := TJSONIntegerNumber.Create(a.Left);
            O.Elements['y'] := TJSONIntegerNumber.Create(a.Top + a.Height);
          end;
      else
        { udRight：编辑框右缘 }
        O.Elements['x'] := TJSONIntegerNumber.Create(a.Left + a.Width);
        O.Elements['y'] := TJSONIntegerNumber.Create(a.Top);
      end;
      O.Elements['h'] := TJSONIntegerNumber.Create(a.Height);
    end;
  end
  else if AKind = 'shape' then
  begin
    { 形状类型：浏览器端按它决定圆角/椭圆，否则圆角矩形会被画成直角块 }
    O.Add('shapestyle', Ord(TShape(C).Shape));
  end
  else if AKind = 'image' then
    WriteImage(TImage(C), O)
  else if AKind = 'panel' then
  begin
    O.Add('bevel', Ord(TPanel(C).BevelOuter));
    O.Add('border', BorderStyleToStr(TPanel(C).BorderStyle));
    if C is TScrollBox then
      O.Add('autoscroll', TScrollBox(C).AutoScroll);
  end
  else if AKind = 'tabs' then
  begin
    if TPageControl(C).ActivePage <> nil then
      O.Add('active', TPageControl(C).ActivePage.PageIndex)
    else
      O.Add('active', 0);
    O.Add('tabpos', Ord(TPageControl(C).TabPosition));
  end
  else if AKind = 'statusbar' then
  begin
    items := TJSONArray.Create;
    for i := 0 to TStatusBar(C).Panels.Count - 1 do
      JArrAddStr(items, TStatusBar(C).Panels[i].Text);
    O.Add('panels', items);
    O.Add('sizegrip', TStatusBar(C).SizeGrip);
  end
  else if AKind = 'tabctl' then
  begin
    { TTabControl：页签是 Tabs 字符串列表，内容是一块公共客户区 }
    items := TJSONArray.Create;
    for i := 0 to TTabControl(C).Tabs.Count - 1 do
      JArrAddStr(items, TTabControl(C).Tabs[i]);
    O.Add('tabitems', items);
    O.Add('tabindex', TTabControl(C).TabIndex);
  end
  else if AKind = 'editbtn' then
  begin
    { TCustomEditButton 族（TFileNameEdit 等）：本体是单行编辑框 + "…"按钮 }
    O.Add('text', TCustomEditButton(C).Text);
    O.Add('readonly', TCustomEditButton(C).ReadOnly);
  end
  else if AKind = 'button' then
  begin
    { TToggleBox（TCustomButton 系）：Checked 就是按下态 }
    if C is TToggleBox then
    begin
      O.Add('down', TToggleBox(C).Checked);
      O.Add('allowup', True);
    end;
  end
  else if AKind = 'toolbutton' then
  begin
    O.Add('style', Ord(TToolButton(C).Style));
    { 分隔符两种都要算上：tbsDivider 与 tbsSeparator（gallery 的工具条
      用的是 tbsSeparator，只认 Divider 时它被渲染成空按钮） }
    O.Add('sep', TToolButton(C).Style in [tbsDivider, tbsSeparator]);
  end
  else if AKind = 'fileupload' then
  begin
    O.Add('filter', TLWFileUpload(C).Filter);
    O.Add('multiple', TLWFileUpload(C).Multiple);
    O.Add('maxsize', TLWFileUpload(C).MaxSizeKB);
    O.Add('lastfile', ExtractFileName(TLWFileUpload(C).LastFileName));
    items := TJSONArray.Create;
    for i := 0 to TLWFileUpload(C).UploadedFiles.Count - 1 do
      JArrAddStr(items, TLWFileUpload(C).UploadedFiles[i]);
    O.Add('files', items);
  end
  else if AKind = 'htmlframe' then
  begin
    { 面板里渲染一段任意 HTML（uniHTMLFrame 对应物）。
      HTML 内容是业务代码给的，视作可信内容原样下发；
      前端把换行统一成 \n，ext 的 html 配置按标记解析。
      bevel/border 与 panel 同语义：LCL 的 BevelOuter 默认 bvRaised，
      浏览器端据此画 1px 边（BevelOuter=bvNone + BorderStyle=bsNone
      才是真正无边框） }
    O.Add('html', TLWHTMLFrame(C).HTML.Text);
    O.Add('bevel', Ord(TCustomPanel(C).BevelOuter));
    O.Add('border', BorderStyleToStr(TCustomPanel(C).BorderStyle));
  end
  else if AKind = 'pdfframe' then
  begin
    { iframe 的 src：/lw/view?t=<令牌> 或外部 URL，没有文件就是空串。
      ViewURL 每次调用都 Touch 续期查看令牌 }
    O.Add('url', TLWPDFFrame(C).ViewURL);
    O.Add('file', ExtractFileName(TLWPDFFrame(C).PDFFile));
    O.Add('bevel', Ord(TCustomPanel(C).BevelOuter));
    O.Add('border', BorderStyleToStr(TCustomPanel(C).BorderStyle));
  end
  else if AKind = 'gauge' then
  begin
    { TLWGauge：盘面参数。数值/阈值改变后下一次协调自然重画 }
    O.Add('value', TLWGauge(C).Value);
    O.Add('min', TLWGauge(C).Min);
    O.Add('max', TLWGauge(C).Max);
    O.Add('unit', TLWGauge(C).UnitText);
    O.Add('warn', TLWGauge(C).WarnAt);
    O.Add('danger', TLWGauge(C).DangerAt);
  end
  else if AKind = 'color' then
  begin
    { TLWColorPicker：当前颜色（#rrggbb），色块由浏览器画 }
    O.Add('value', ColorToCSS(TControl(C).Color));
  end
  else if AKind = 'chart' then
  begin
    { TLWChart（uniChart 对应物）：类型 + X 轴标签 + 系列数组。
      数值逐行解析（Values 每行一个点），解析失败按 0 处理。
      bevel/border 与 htmlframe/pdfframe 同语义（宿主 TCustomPanel，
      BevelOuter 默认 bvRaised → 浏览器端画 1px 边） }
    case TLWChart(C).ChartType of
      ctBar: O.Add('charttype', 'bar');
      ctPie: O.Add('charttype', 'pie');
    else
      O.Add('charttype', 'line');
    end;
    O.Add('title', TLWChart(C).Title);
    items := TJSONArray.Create;
    for i := 0 to TLWChart(C).Categories.Count - 1 do
      JArrAddStr(items, TLWChart(C).Categories[i]);
    O.Add('categories', items);
    items := TJSONArray.Create;
    for i := 0 to TLWChart(C).Series.Count - 1 do
    begin
      b := TJSONObject.Create;
      b.Add('name', TLWSeriesItem(TLWChart(C).Series.Items[i]).Name);
      vals := TJSONArray.Create;
      for j := 0 to TLWSeriesItem(TLWChart(C).Series.Items[i]).Values.Count - 1 do
        vals.Add(StrToFloatDef(Trim(TLWSeriesItem(TLWChart(C).Series.Items[i]).Values[j]), 0));
      b.Add('values', vals);
      items.Add(b);
    end;
    O.Add('series', items);
    O.Add('bevel', Ord(TCustomPanel(C).BevelOuter));
    O.Add('border', BorderStyleToStr(TCustomPanel(C).BorderStyle));
  end
  else if (AKind = 'dateedit') or (AKind = 'timeedit') then
  begin
    { TDateEdit/TTimeEdit：text 是设计期显示串，iso 是统一格式
      （yyyy-mm-dd / hh:nn:ss），前端按 ISO 解析，免掉服务端/浏览器
      本地化格式的对不上 }
    { 注意：本机 Lazarus 的 TCustomEditButton 继承 TCustomAbstractGroupedEdit
      （TCustomPanel 系），不是 TCustomEdit，因此必须按 TCustomEditButton 转 }
    O.Add('text', (C as TCustomEditButton).Text);
    O.Add('readonly', (C as TCustomEditButton).ReadOnly);
    { Date/Time 可能是脏值（DB 里塞过垃圾日期时 Date=天文数字），直接
      FormatDateTime 会抛 EConvertError —— 坑 107 复测时 deDate 就是这样。
      降级成空 iso（前端显示 text），不要让整个控件降级。 }
    try
      if AKind = 'dateedit' then
        O.Add('iso', FormatDateTime('yyyy-mm-dd', TDateEdit(C).Date))
      else
        O.Add('iso', FormatDateTime('hh:nn:ss', TTimeEdit(C).Time));
    except
      O.Add('iso', '');
    end;
  end
  else if AKind = 'unknown' then
    O.Add('unsupported', True);
end;

function TLWWriter.WriteChildren(WC: TWinControl): TJSONArray;
var
  arr: TJSONArray;
  i: Integer;
  c: TControl;
begin
  arr := TJSONArray.Create;
  { Controls[] 的顺序就是 z 顺序，后加的盖在前面，直接沿用 }
  for i := 0 to WC.ControlCount - 1 do
  begin
    c := WC.Controls[i];
    if c = nil then Continue;
    if c is TCustomForm then Continue;
    { TStringGrid / TListView 之类的控件会在内部造一个不可见的单元格编辑器，
      它不是设计师放的控件，不能序列化出去 }
    if IsInternalControl(c) then Continue;
    arr.Add(WriteControl(c));
  end;
  Result := arr;
end;

function TLWWriter.WriteControl(C: TControl): TJSONObject;
var
  kind: string;
  o: TJSONObject;
begin
  o := nil;
  kind := '';
  try
    kind := KindOf(C);
    o := MakeBase(C, kind);
    WriteKindProps(C, kind, o);
    if C is TWinControl then
      o.Add('children', WriteChildren(TWinControl(C)))
    else
      o.Add('children', TJSONArray.Create);
    Result := o;
  except
    on E: Exception do
    begin
      { 坑 107：单控件序列化失败不炸整个 payload —— 降级成带 err 的占位节点。
        前端只少一块内容，其余控件照常下发；请求本身不 500。
        （半途丢弃的 o 直接释放重建，不带半截数据。） }
      o.Free;
      if kind = '' then
        kind := 'unknown';
      Result := MakeBase(C, kind);
      Result.Add('err', E.ClassName + ': ' + E.Message);
      LWLogFmt('[writer] 控件 %s (%s) 序列化失败，已降级: %s',
        [C.Name, C.ClassName, E.Message]);
    end;
  end;
end;

function TLWWriter.WriteMenuItems(MI: TMenuItem): TJSONArray;
var
  arr: TJSONArray;
  i: Integer;
  it: TMenuItem;
  o: TJSONObject;
begin
  arr := TJSONArray.Create;
  for i := 0 to MI.Count - 1 do
  begin
    it := MI.Items[i];
    if not it.Visible then Continue;
    o := TJSONObject.Create;
    o.Add('id', NodeId(it));
    o.Add('caption', StringReplace(it.Caption, '&', '', [rfReplaceAll]));
    o.Add('enabled', it.Enabled);
    o.Add('checked', it.Checked);
    o.Add('sep', it.Caption = '-');
    { ShortCutToText(0) 在部分 LCL 版本里会返回 'Unknown'，无快捷键就不要写 }
    if it.ShortCut <> 0 then
      o.Add('shortcut', ShortCutToText(it.ShortCut));
    o.Add('ev', WriteEvents(it, it.Count = 0));
    if it.Count > 0 then
      o.Add('items', WriteMenuItems(it))
    else
      o.Add('items', TJSONArray.Create);
    arr.Add(o);
  end;
  Result := arr;
end;

function TLWWriter.WriteForm(AForm: TCustomForm; AIsModal: Boolean): TJSONObject;
var
  o: TJSONObject;
  i: Integer;
  c: TControl;
  arr: TJSONArray;
  sb: TStatusBar;
  bs: string;
begin
  o := TJSONObject.Create;
  o.Add('id', NodeId(AForm));
  o.Add('kind', 'form');
  o.Add('name', AForm.Name);
  o.Add('cls', AForm.ClassName);
  o.Add('caption', AForm.Caption);
  o.Add('x', AForm.Left);
  o.Add('y', AForm.Top);
  o.Add('w', AForm.Width);
  o.Add('h', AForm.Height);
  { nogui 下窗体句柄未创建，LCL 的 ClientWidth/ClientHeight 读出来是
    构造默认值 320x240（GetClientRect 走 GetDefaults 兜底），不是 LFM
    设计尺寸 —— 实测 gallery 的 1020x680 序列化成 320x240，浏览器端
    按它补高度把窗口缩到 277px。句柄没建时用 Width/Height（LCL 对
    窗体约定 Width==ClientWidth，见 LCL FAQ；有句柄时 Client* 才准）。 }
  if AForm.HandleAllocated then
  begin
    o.Add('cw', AForm.ClientWidth);
    o.Add('ch', AForm.ClientHeight);
  end
  else
  begin
    o.Add('cw', AForm.Width);
    o.Add('ch', AForm.Height);
  end;
  o.Add('modal', AIsModal);
  o.Add('modalresult', AForm.ModalResult);
  o.Add('fg', ColorToCSS(AForm.Font.Color));
  o.Add('bg', ColorToCSS(AForm.Color));
  o.Add('font', FontToJSON(AForm.Font));

  case AForm.BorderStyle of
    bsNone: bs := 'none';
    bsSingle: bs := 'single';
    bsDialog: bs := 'dialog';
    bsToolWindow: bs := 'toolwindow';
    bsSizeToolWin: bs := 'sizetoolwin';
  else
    bs := 'sizeable';
  end;
  o.Add('border', bs);
  o.Add('resizable', AForm.BorderStyle in [bsSizeable, bsSizeToolWin]);

  { 主菜单：LCL 的 TMainMenu 是非可视组件，单独序列化成菜单栏 }
  if AForm.Menu <> nil then
    o.Add('menu', WriteMenuItems(AForm.Menu.Items))
  else
    o.Add('menu', TJSONArray.Create);

  { 状态栏单独处理，避免在绝对定位里错位 }
  sb := nil;
  for i := 0 to AForm.ControlCount - 1 do
  begin
    c := AForm.Controls[i];
    if c is TStatusBar then
    begin
      sb := TStatusBar(c);
      Break;
    end;
  end;
  if sb <> nil then
    o.Add('status', StatusPanels(sb))
  else
    o.Add('status', TJSONArray.Create);

  arr := TJSONArray.Create;
  for i := 0 to AForm.ControlCount - 1 do
  begin
    c := AForm.Controls[i];
    if c = nil then Continue;
    if c is TStatusBar then Continue;
    if IsInternalControl(c) then Continue;
    arr.Add(WriteControl(c));
  end;
  o.Add('children', arr);
  Result := o;
end;

end.
