{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwreport
  ------------------------------------------------------------------
  服务端报表引擎（打印 / 导出）。承担 FastReport、LazReport 在桌面端
  的那部分职责：把「数据集 + 列定义」渲染成最终版式。

  为什么这里不是 FastReport / LazReport：
    * FastReport 是商业库，本机没有；
    * LazReport 是 LCL 控件集，TfrReport 与预览窗体、打印机强绑定，
      服务端跑的是 nogui widgetset（没有窗口、没有打印机），用它反而
      要绕过一整套 UI；
    * 本框架的"纸张"落在浏览器里 —— 浏览器自带打印引擎和分页媒体，
      服务端只要生成排好版的 HTML 就能打印 / 另存为 PDF。
  所以这里实现一份报表定义（标题 + 列 + 汇总 + 纸张），三种出口：

      RenderHTML  可打印 HTML（A4 @page、@media print、每页重复表头）
      SaveHTML    写文件（交给 TLWPDFFrame 在 iframe 里预览）
      SaveCSV     UTF-8 BOM 的 CSV（Excel 双击不乱码）
      SaveXLSX    真正的 xlsx（OOXML + zip，不依赖第三方库）

  渲染不会弄脏数据集：进出都用 Bookmark 复位，网格上的当前行不变。
}
unit lwreport;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DB;

type
  { 列汇总方式，与 FastReport 的 Aggregate 一个意思 }
  TLWReportSummary = (rsNone, rsSum, rsCount, rsAvg);

  TLWStringArray = array of string;

  TLWReportColumn = class(TCollectionItem)
  private
    FCaption: string;
    FFieldName: string;
    FMask: string;
    FWidthMM: Double;
    FAlign: TAlignment;
    FSummary: TLWReportSummary;
  published
    { 表头文字；留空时用字段名 }
    property Caption: string read FCaption write FCaption;
    property FieldName: string read FFieldName write FFieldName;
    { 数字：'#,##0.00'；日期：'yyyy-mm-dd'；留空按字段类型自动 }
    property Mask: string read FMask write FMask;
    { 打印宽度（毫米），只影响版式比例 }
    property WidthMM: Double read FWidthMM write FWidthMM;
    property Align: TAlignment read FAlign write FAlign;
    property Summary: TLWReportSummary read FSummary write FSummary;
  public
    constructor Create(ACollection: TCollection); override;
  end;

  TLWReportColumns = class(TCollection)
  private
    function GetItem(AIndex: Integer): TLWReportColumn;
  public
    constructor Create;
    function Add: TLWReportColumn;
    { 加一列并直接给齐常用属性 }
    function AddCol(const ACaption, AFieldName: string; AWidthMM: Double = 0;
      AAlign: TAlignment = taLeftJustify;
      ASummary: TLWReportSummary = rsNone): TLWReportColumn;
    property Items[AIndex: Integer]: TLWReportColumn read GetItem; default;
  end;

  TLWReport = class(TComponent)
  private
    FColumns: TLWReportColumns;
    FDataSet: TDataSet;
    FTitle: string;
    FSubTitle: string;
    FFooterText: string;
    FOperator: string;
    FPageSize: string;
    FLandscape: Boolean;
    FZebra: Boolean;
    FShowGrid: Boolean;
    FShowSummary: Boolean;
    function GetRowCount: Integer;
    function GetOrientation: string;
    function ColumnText(ACol: TLWReportColumn): string;
    function ColumnNumber(ACol: TLWReportColumn): Double;
    function IsNumericColumn(ACol: TLWReportColumn): Boolean;
    function SummaryRow: TLWStringArray;
    function BuildHTMLHead: string;
    function BuildCSV: string;
    function BuildXLSXSheet: string;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { 整页可打印 HTML（含打印按钮、A4 @page、每页重复表头） }
    function RenderHTML: string;
    function SaveHTML(const AFileName: string): Boolean;
    function SaveCSV(const AFileName: string): Boolean;
    function SaveXLSX(const AFileName: string): Boolean;

    { 当前数据集行数（只读，不改变游标） }
    property RowCount: Integer read GetRowCount;
    property Columns: TLWReportColumns read FColumns;
  published
    property DataSet: TDataSet read FDataSet write FDataSet;
    property Title: string read FTitle write FTitle;
    property SubTitle: string read FSubTitle write FSubTitle;
    { 页脚说明（表格下方灰色小字） }
    property FooterText: string read FFooterText write FFooterText;
    { 制表人，显示在副标题右侧 }
    property OperatorName: string read FOperator write FOperator;
    { A4 / A5 / Letter }
    property PageSize: string read FPageSize write FPageSize;
    property Landscape: Boolean read FLandscape write FLandscape;
    property Zebra: Boolean read FZebra write FZebra;
    property ShowGrid: Boolean read FShowGrid write FShowGrid;
    property ShowSummary: Boolean read FShowSummary write FShowSummary;
  end;

{ 按 UTF-8 写文本文件（不经系统代码页） }
function LWWriteTextFile(const AFileName, AContent: string): Boolean;
{ UTF-8 带 BOM 写文件（Excel 打开 CSV 不乱码） }
function LWWriteTextFileBOM(const AFileName, AContent: string): Boolean;

implementation

uses
  Math, zipper;

const
  CRLF = #13#10;

function HtmlEsc(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

function XmlEsc(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
  Result := StringReplace(Result, '''', '&apos;', [rfReplaceAll]);
  Result := StringReplace(Result, #0, '', [rfReplaceAll]);
end;

function CsvEsc(const S: string): string;
begin
  if (Pos('"', S) > 0) or (Pos(',', S) > 0) or (Pos(#13, S) > 0) or
     (Pos(#10, S) > 0) or (Pos(';', S) > 0) then
    Result := '"' + StringReplace(S, '"', '""', [rfReplaceAll]) + '"'
  else
    Result := S;
end;

function LWWriteTextFile(const AFileName, AContent: string): Boolean;
var
  fs: TFileStream;
begin
  Result := False;
  try
    fs := TFileStream.Create(AFileName, fmCreate);
    try
      if AContent <> '' then
        fs.WriteBuffer(AContent[1], Length(AContent));
      Result := True;
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

function LWWriteTextFileBOM(const AFileName, AContent: string): Boolean;
const
  BOM: array[0..2] of Byte = ($EF, $BB, $BF);
var
  fs: TFileStream;
begin
  Result := False;
  try
    fs := TFileStream.Create(AFileName, fmCreate);
    try
      fs.WriteBuffer(BOM[0], 3);
      if AContent <> '' then
        fs.WriteBuffer(AContent[1], Length(AContent));
      Result := True;
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

{ 游标守卫：构造时记书签、关控件、跳到首行；析构时复位。
  报表渲染必须这么干 —— 否则用户的网格会跟着报表跑到底部。 }
type
  TLWCursorGuard = class
  private
    FDS: TDataSet;
    FBM: TBookmark;
  public
    constructor Create(ADS: TDataSet);
    destructor Destroy; override;
  end;

constructor TLWCursorGuard.Create(ADS: TDataSet);
begin
  inherited Create;
  FDS := ADS;
  if (FDS = nil) or (not FDS.Active) then Exit;
  FBM := FDS.GetBookmark;
  FDS.DisableControls;
  FDS.First;
end;

destructor TLWCursorGuard.Destroy;
begin
  if (FDS <> nil) and FDS.Active then
  begin
    if (FBM <> nil) and FDS.BookmarkValid(FBM) then
      FDS.GotoBookmark(FBM);
    if FBM <> nil then FDS.FreeBookmark(FBM);
    FDS.EnableControls;
  end;
  inherited Destroy;
end;

{ ---------------- TLWReportColumn / Columns ---------------- }

constructor TLWReportColumn.Create(ACollection: TCollection);
begin
  inherited Create(ACollection);
  FWidthMM := 0;
  FAlign := taLeftJustify;
  FSummary := rsNone;
end;

constructor TLWReportColumns.Create;
begin
  inherited Create(TLWReportColumn);
end;

function TLWReportColumns.GetItem(AIndex: Integer): TLWReportColumn;
begin
  Result := TLWReportColumn(inherited Items[AIndex]);
end;

function TLWReportColumns.Add: TLWReportColumn;
begin
  Result := TLWReportColumn(inherited Add);
end;

function TLWReportColumns.AddCol(const ACaption, AFieldName: string;
  AWidthMM: Double; AAlign: TAlignment; ASummary: TLWReportSummary): TLWReportColumn;
begin
  Result := Add;
  Result.Caption := ACaption;
  Result.FieldName := AFieldName;
  Result.WidthMM := AWidthMM;
  Result.Align := AAlign;
  Result.Summary := ASummary;
end;

{ ---------------- TLWReport ---------------- }

constructor TLWReport.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FColumns := TLWReportColumns.Create;
  FPageSize := 'A4';
  FZebra := True;
  FShowGrid := True;
  FShowSummary := True;
end;

destructor TLWReport.Destroy;
begin
  FColumns.Free;
  inherited Destroy;
end;

function TLWReport.GetOrientation: string;
begin
  if FLandscape then Result := 'landscape' else Result := 'portrait';
end;

function TLWReport.GetRowCount: Integer;
var
  g: TLWCursorGuard;
begin
  Result := 0;
  if (FDataSet = nil) or (not FDataSet.Active) then Exit;
  g := TLWCursorGuard.Create(FDataSet);
  try
    while not FDataSet.Eof do
    begin
      Inc(Result);
      FDataSet.Next;
    end;
  finally
    g.Free;
  end;
end;

function TLWReport.IsNumericColumn(ACol: TLWReportColumn): Boolean;
var
  f: TField;
begin
  Result := False;
  if (FDataSet = nil) or (ACol = nil) or (ACol.FieldName = '') then Exit;
  f := FDataSet.FindField(ACol.FieldName);
  if f = nil then Exit;
  Result := f.DataType in [ftSmallint, ftInteger, ftWord, ftLargeint, ftFloat,
    ftCurrency, ftBCD, ftFMTBcd, ftAutoInc];
end;

function TLWReport.ColumnText(ACol: TLWReportColumn): string;
var
  f: TField;
begin
  Result := '';
  if (FDataSet = nil) or (ACol = nil) or (ACol.FieldName = '') then Exit;
  f := FDataSet.FindField(ACol.FieldName);
  if f = nil then Exit;

  if ACol.Mask <> '' then
  begin
    if IsNumericColumn(ACol) then
      Result := FormatFloat(ACol.Mask, f.AsFloat)
    else if f.DataType in [ftDate, ftTime, ftDateTime, ftTimeStamp] then
      Result := FormatDateTime(ACol.Mask, f.AsDateTime)
    else
      Result := f.AsString;
    Exit;
  end;

  case f.DataType of
    ftFloat, ftCurrency, ftBCD, ftFMTBcd:
      Result := FormatFloat('#,##0.00', f.AsFloat);
    ftSmallint, ftInteger, ftWord, ftLargeint, ftAutoInc:
      Result := IntToStr(f.AsLargeInt);
    ftDate:
      Result := FormatDateTime('yyyy-mm-dd', f.AsDateTime);
    ftTime:
      Result := FormatDateTime('hh:nn:ss', f.AsDateTime);
    ftDateTime, ftTimeStamp:
      Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', f.AsDateTime);
    ftBoolean:
      if f.AsBoolean then Result := '是' else Result := '否';
  else
    Result := Trim(f.AsString);
  end;
end;

function TLWReport.ColumnNumber(ACol: TLWReportColumn): Double;
var
  f: TField;
begin
  Result := 0;
  if (FDataSet = nil) or (ACol = nil) then Exit;
  f := FDataSet.FindField(ACol.FieldName);
  if (f = nil) or (not IsNumericColumn(ACol)) then Exit;
  Result := f.AsFloat;
end;

{ 汇总行：只有显式标了 rsSum/rsAvg/rsCount 的列才有值，
  第一列没有汇总时由渲染层写成"合计"两个字 }
function TLWReport.SummaryRow: TLWStringArray;
var
  i, cnt: Integer;
  sums: array of Double;
  g: TLWCursorGuard;
begin
  { 动态数组结果显式清零：FPC 会对"托管类型结果变量未初始化"给 5093
    提示（实际会自动置 nil，但显式写出来既消警又表明意图） }
  Result := nil;
  SetLength(Result, FColumns.Count);
  SetLength(sums, FColumns.Count);
  for i := 0 to FColumns.Count - 1 do
  begin
    Result[i] := '';
    sums[i] := 0;
  end;
  if (FDataSet = nil) or (not FDataSet.Active) then Exit;

  cnt := 0;
  g := TLWCursorGuard.Create(FDataSet);
  try
    while not FDataSet.Eof do
    begin
      Inc(cnt);
      for i := 0 to FColumns.Count - 1 do
        if FColumns[i].Summary in [rsSum, rsAvg] then
          sums[i] := sums[i] + ColumnNumber(FColumns[i]);
      FDataSet.Next;
    end;
  finally
    g.Free;
  end;

  for i := 0 to FColumns.Count - 1 do
  begin
    case FColumns[i].Summary of
      rsSum:
        if FColumns[i].Mask <> '' then
          Result[i] := FormatFloat(FColumns[i].Mask, sums[i])
        else
          Result[i] := FormatFloat('#,##0.00', sums[i]);
      rsAvg:
        begin
          if cnt > 0 then sums[i] := sums[i] / cnt;
          if FColumns[i].Mask <> '' then
            Result[i] := FormatFloat(FColumns[i].Mask, sums[i])
          else
            Result[i] := FormatFloat('#,##0.00', sums[i]);
        end;
      rsCount:
        Result[i] := IntToStr(cnt);
    end;
  end;
end;

function TLWReport.BuildHTMLHead: string;
var
  sl: TStringList;
  i: Integer;
  totalMM, w: Double;
  orientTxt: string;
begin
  if FLandscape then orientTxt := ' 横向' else orientTxt := ' 纵向';
  totalMM := 0;
  for i := 0 to FColumns.Count - 1 do
    totalMM := totalMM + FColumns[i].WidthMM;

  sl := TStringList.Create;
  try
    sl.Add('<!DOCTYPE html>');
    sl.Add('<html lang="zh-CN">');
    sl.Add('<head>');
    sl.Add('<meta charset="utf-8">');
    sl.Add('<meta name="viewport" content="width=device-width,initial-scale=1">');
    sl.Add('<title>' + HtmlEsc(FTitle) + '</title>');
    sl.Add('<style>');
    sl.Add('@page { size: ' + FPageSize + ' ' + GetOrientation + '; margin: 12mm 10mm 14mm; }');
    sl.Add('html,body{margin:0;padding:0;background:#eef1f5;}');
    sl.Add('body{font:10pt/1.55 "Microsoft YaHei","PingFang SC","Hiragino Sans GB",');
    sl.Add('  "Source Han Sans SC","WenQuanYi Micro Hei",sans-serif;color:#1f2328;}');
    sl.Add('.lw-sheet{background:#fff;margin:0 auto;padding:14mm 10mm 10mm;');
    sl.Add('  max-width:210mm;box-shadow:0 2px 12px rgba(0,0,0,.12);}');
    sl.Add('.lw-head{border-bottom:2px solid #2255aa;padding-bottom:6px;margin-bottom:12px;}');
    sl.Add('.lw-title{font-size:17pt;font-weight:700;letter-spacing:.5px;color:#173a70;}');
    sl.Add('.lw-sub{font-size:9pt;color:#5b6470;margin-top:4px;float:left;}');
    sl.Add('.lw-op{font-size:9pt;color:#5b6470;float:right;}');
    sl.Add('.lw-clear{clear:both;}');
    sl.Add('table{width:100%;border-collapse:collapse;table-layout:fixed;}');
    sl.Add('thead{display:table-header-group;}');
    sl.Add('tr{page-break-inside:avoid;}');
    if FShowGrid then
      sl.Add('th,td{border:1px solid #b9c2cc;padding:3px 5px;font-size:9.5pt;overflow:hidden;}')
    else
      sl.Add('th,td{border:none;border-bottom:1px solid #e3e8ee;padding:3px 5px;font-size:9.5pt;overflow:hidden;}');
    sl.Add('th{background:#e8eef8;font-weight:700;white-space:nowrap;}');
    if FZebra then
      sl.Add('tbody tr:nth-child(even) td{background:#f7f9fc;}');
    sl.Add('td.lw-r{text-align:right;}');
    sl.Add('td.lw-c{text-align:center;}');
    sl.Add('tfoot td{background:#eef3fb;font-weight:700;}');
    sl.Add('.lw-foot{margin-top:10px;font-size:8.5pt;color:#7b8593;}');
    sl.Add('.lw-bar{position:sticky;top:0;z-index:9;background:#2255aa;color:#fff;');
    sl.Add('  padding:7px 14px;display:flex;align-items:center;gap:12px;');
    sl.Add('  font:9.5pt/1.4 sans-serif;}');
    sl.Add('.lw-bar b{font-size:10.5pt;}');
    sl.Add('.lw-bar button{margin-left:auto;background:#fff;color:#2255aa;border:0;');
    sl.Add('  border-radius:4px;padding:5px 14px;font-size:9.5pt;cursor:pointer;font-weight:700;}');
    sl.Add('.lw-bar span{opacity:.85;}');
    sl.Add('@media print{');
    sl.Add('  html,body{background:#fff;}');
    sl.Add('  .lw-bar{display:none !important;}');
    sl.Add('  .lw-sheet{box-shadow:none;margin:0;padding:0;max-width:none;}');
    sl.Add('}');
    sl.Add('</style>');
    sl.Add('</head>');
    sl.Add('<body>');
    sl.Add('<div class="lw-bar"><b>' + HtmlEsc(FTitle) + '</b>');
    sl.Add('<span>' + IntToStr(GetRowCount) + ' 行 · ' + FPageSize +
      orientTxt + '</span>');
    sl.Add('<button onclick="window.print()">打印 / 另存为 PDF</button></div>');
    sl.Add('<div class="lw-sheet">');
    sl.Add('<div class="lw-head">');
    sl.Add('<div class="lw-title">' + HtmlEsc(FTitle) + '</div>');
    sl.Add('<div class="lw-sub">' + HtmlEsc(FSubTitle) + '</div>');
    if FOperator <> '' then
      sl.Add('<div class="lw-op">制表：' + HtmlEsc(FOperator) + '</div>');
    sl.Add('<div class="lw-clear"></div>');
    sl.Add('</div>');
    sl.Add('<table>');
    sl.Add('<colgroup>');
    for i := 0 to FColumns.Count - 1 do
    begin
      if totalMM > 0 then
        w := FColumns[i].WidthMM / totalMM * 100
      else
        w := 100 / Max(1, FColumns.Count);
      sl.Add(Format('<col style="width:%.2f%%">', [w]));
    end;
    sl.Add('</colgroup>');
    sl.Add('<thead><tr>');
    for i := 0 to FColumns.Count - 1 do
    begin
      if FColumns[i].Caption <> '' then
        sl.Add('<th>' + HtmlEsc(FColumns[i].Caption) + '</th>')
      else
        sl.Add('<th>' + HtmlEsc(FColumns[i].FieldName) + '</th>');
    end;
    sl.Add('</tr></thead>');
    sl.Add('<tbody>');
    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

function TLWReport.RenderHTML: string;
var
  sl: TStringList;
  i: Integer;
  sums: array of string;
  tdCls: string;
  g: TLWCursorGuard;
begin
  sl := TStringList.Create;
  try
    sl.Text := BuildHTMLHead;

    g := TLWCursorGuard.Create(FDataSet);
    try
      while (FDataSet <> nil) and (not FDataSet.Eof) do
      begin
        sl.Add('<tr>');
        for i := 0 to FColumns.Count - 1 do
        begin
          case FColumns[i].Align of
            taRightJustify: tdCls := ' class="lw-r"';
            taCenter: tdCls := ' class="lw-c"';
          else
            tdCls := '';
          end;
          sl.Add('<td' + tdCls + '>' + HtmlEsc(ColumnText(FColumns[i])) + '</td>');
        end;
        sl.Add('</tr>');
        FDataSet.Next;
      end;
    finally
      g.Free;
    end;

    sl.Add('</tbody>');
    if FShowSummary and (FColumns.Count > 0) then
    begin
      sums := SummaryRow;
      sl.Add('<tfoot><tr>');
      for i := 0 to FColumns.Count - 1 do
      begin
        if (i = 0) and (sums[i] = '') then
          sl.Add('<td>合计</td>')
        else if FColumns[i].Align = taRightJustify then
          sl.Add('<td class="lw-r">' + HtmlEsc(sums[i]) + '</td>')
        else
          sl.Add('<td>' + HtmlEsc(sums[i]) + '</td>');
      end;
      sl.Add('</tr></tfoot>');
    end;
    sl.Add('</table>');

    if FFooterText <> '' then
      sl.Add('<div class="lw-foot">' + HtmlEsc(FFooterText) + '</div>');
    sl.Add('<div class="lw-foot">lazarusWeb 报表引擎 · ' +
      FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + '</div>');
    sl.Add('</div>');
    { 带 #print 打开（TLWPDFFrame.URLSuffix）时自动弹打印对话框，
      对应"报表窗体上点打印"这条路；不带时只做预览 }
    sl.Add('<script>');
    sl.Add('if (location.hash === ''#print'') {');
    sl.Add('  window.addEventListener(''load'', function () {');
    sl.Add('    setTimeout(function () { window.print(); }, 250);');
    sl.Add('  });');
    sl.Add('}');
    sl.Add('</script>');
    sl.Add('</body>');
    sl.Add('</html>');
    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

function TLWReport.SaveHTML(const AFileName: string): Boolean;
begin
  Result := LWWriteTextFile(AFileName, RenderHTML);
end;

function TLWReport.BuildCSV: string;
var
  sl: TStringList;
  i: Integer;
  line: string;
  sums: array of string;
  g: TLWCursorGuard;
begin
  sl := TStringList.Create;
  try
    { 标题行 + 制表信息，方便直接当交接单用 }
    if FTitle <> '' then
      sl.Add(CsvEsc(FTitle));
    if FSubTitle <> '' then
      sl.Add(CsvEsc(FSubTitle));

    line := '';
    for i := 0 to FColumns.Count - 1 do
    begin
      if i > 0 then line := line + ',';
      if FColumns[i].Caption <> '' then
        line := line + CsvEsc(FColumns[i].Caption)
      else
        line := line + CsvEsc(FColumns[i].FieldName);
    end;
    sl.Add(line);

    g := TLWCursorGuard.Create(FDataSet);
    try
      while (FDataSet <> nil) and (not FDataSet.Eof) do
      begin
        line := '';
        for i := 0 to FColumns.Count - 1 do
        begin
          if i > 0 then line := line + ',';
          line := line + CsvEsc(ColumnText(FColumns[i]));
        end;
        sl.Add(line);
        FDataSet.Next;
      end;
    finally
      g.Free;
    end;

    if FShowSummary and (FColumns.Count > 0) then
    begin
      sums := SummaryRow;
      line := '合计';
      for i := 0 to FColumns.Count - 1 do
      begin
        if i > 0 then line := line + ',';
        line := line + CsvEsc(sums[i]);
      end;
      sl.Add(line);
    end;

    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

function TLWReport.SaveCSV(const AFileName: string): Boolean;
var
  s: string;
begin
  { 统一成 CRLF + BOM：Excel / WPS 双击直接认，中文不乱码。
    先清掉 TStringList.Text 自带的换行（Windows 上本身就是 CRLF），
    再统一换成 CRLF —— 否则会变成 CR CR LF，每行之间多一个空行。 }
  s := BuildCSV;
  s := StringReplace(s, #13#10, #10, [rfReplaceAll]);
  s := StringReplace(s, #13, #10, [rfReplaceAll]);
  s := StringReplace(s, #10, CRLF, [rfReplaceAll]);
  Result := LWWriteTextFileBOM(AFileName, s);
end;

{ ---------- xlsx ---------- }

function XLColName(AIndex: Integer): string;
var
  n: Integer;
begin
  { 0 -> A, 25 -> Z, 26 -> AA }
  Result := '';
  n := AIndex;
  repeat
    Result := Chr(Ord('A') + (n mod 26)) + Result;
    n := n div 26 - 1;
  until n < 0;
end;

function TLWReport.BuildXLSXSheet: string;
var
  sl: TStringList;
  i, r: Integer;
  line, cellRef: string;
  sums: array of string;
  totalMM, w: Double;
  g: TLWCursorGuard;
  numCols: array of Boolean;
begin
  SetLength(numCols, FColumns.Count);
  for i := 0 to FColumns.Count - 1 do
    numCols[i] := IsNumericColumn(FColumns[i]);

  totalMM := 0;
  for i := 0 to FColumns.Count - 1 do
    totalMM := totalMM + FColumns[i].WidthMM;

  sl := TStringList.Create;
  try
    sl.Add('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
    sl.Add('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">');
    sl.Add('<sheetViews><sheetView workbookViewId="0">');
    sl.Add('<pane ySplit="2" topLeftCell="A3" activePane="bottomLeft" state="frozen"/>');
    sl.Add('</sheetView></sheetViews>');
    sl.Add('<sheetFormatPr defaultRowHeight="16"/>');

    { 列宽：有 WidthMM 就按毫米折算成字符宽，否则给 14 }
    sl.Add('<cols>');
    for i := 0 to FColumns.Count - 1 do
    begin
      if (totalMM > 0) and (FColumns[i].WidthMM > 0) then
        w := Max(8, FColumns[i].WidthMM / 2.1)
      else
        w := 14;
      sl.Add(Format('<col min="%d" max="%d" width="%.1f" customWidth="1"/>',
        [i + 1, i + 1, w]));
    end;
    sl.Add('</cols>');

    sl.Add('<sheetData>');

    { 第 1 行：报表标题（合并单元格 + 大字号样式） }
    if FTitle <> '' then
    begin
      sl.Add('<row r="1" ht="24" customHeight="1">');
      cellRef := 'A1';
      sl.Add('<c r="' + cellRef + '" s="3" t="inlineStr"><is><t>' +
        XmlEsc(FTitle) + '</t></is></c>');
      sl.Add('</row>');
    end;

    { 第 2 行：表头 }
    sl.Add('<row r="2" ht="20" customHeight="1">');
    for i := 0 to FColumns.Count - 1 do
    begin
      cellRef := XLColName(i) + '2';
      if FColumns[i].Caption <> '' then
        line := FColumns[i].Caption
      else
        line := FColumns[i].FieldName;
      sl.Add('<c r="' + cellRef + '" s="1" t="inlineStr"><is><t>' +
        XmlEsc(line) + '</t></is></c>');
    end;
    sl.Add('</row>');

    { 数据行 }
    r := 2;
    g := TLWCursorGuard.Create(FDataSet);
    try
      while (FDataSet <> nil) and (not FDataSet.Eof) do
      begin
        Inc(r);
        sl.Add('<row r="' + IntToStr(r) + '">');
        for i := 0 to FColumns.Count - 1 do
        begin
          cellRef := XLColName(i) + IntToStr(r);
          if numCols[i] then
            sl.Add('<c r="' + cellRef + '"><v>' +
              StringReplace(ColumnText(FColumns[i]), ',', '',
                [rfReplaceAll]) + '</v></c>')
          else
            sl.Add('<c r="' + cellRef + '" t="inlineStr"><is><t>' +
              XmlEsc(ColumnText(FColumns[i])) + '</t></is></c>');
        end;
        sl.Add('</row>');
        FDataSet.Next;
      end;
    finally
      g.Free;
    end;

    { 汇总行 }
    if FShowSummary and (FColumns.Count > 0) then
    begin
      Inc(r);
      sums := SummaryRow;
      sl.Add('<row r="' + IntToStr(r) + '">');
      for i := 0 to FColumns.Count - 1 do
      begin
        cellRef := XLColName(i) + IntToStr(r);
        if (i = 0) and (sums[i] = '') then
          sl.Add('<c r="' + cellRef + '" s="2" t="inlineStr"><is><t>合计</t></is></c>')
        else if numCols[i] then
          sl.Add('<c r="' + cellRef + '" s="2"><v>' +
            StringReplace(sums[i], ',', '', [rfReplaceAll]) + '</v></c>')
        else
          sl.Add('<c r="' + cellRef + '" s="2" t="inlineStr"><is><t>' +
            XmlEsc(sums[i]) + '</t></is></c>');
      end;
      sl.Add('</row>');
    end;

    sl.Add('</sheetData>');
    sl.Add('</worksheet>');
    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

function TLWReport.SaveXLSX(const AFileName: string): Boolean;
var
  z: TZipper;
  keep: TList;
  i: Integer;

  procedure AddPart(const AName, AContent: string);
  var
    ms: TMemoryStream;
  begin
    ms := TMemoryStream.Create;
    if AContent <> '' then
      ms.WriteBuffer(AContent[1], Length(AContent));
    ms.Position := 0;
    keep.Add(ms);
    z.Entries.AddFileEntry(ms, AName);
  end;

var
  sheetName: string;
  contentTypes, rels, workbook, wbRels, styles, sheet: string;
begin
  Result := False;
  if (FColumns.Count = 0) then Exit;

  sheetName := '报表';
  if FTitle <> '' then
  begin
    sheetName := StringReplace(FTitle, '/', '-', [rfReplaceAll]);
    sheetName := StringReplace(sheetName, '\', '-', [rfReplaceAll]);
    sheetName := StringReplace(sheetName, '?', '', [rfReplaceAll]);
    sheetName := StringReplace(sheetName, '*', '', [rfReplaceAll]);
    sheetName := StringReplace(sheetName, '[', '(', [rfReplaceAll]);
    sheetName := StringReplace(sheetName, ']', ')', [rfReplaceAll]);
    sheetName := StringReplace(sheetName, ':', '-', [rfReplaceAll]);
    if Length(sheetName) > 31 then
      sheetName := Copy(sheetName, 1, 31);
  end;

  contentTypes :=
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + CRLF +
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
    '<Default Extension="xml" ContentType="application/xml"/>' +
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' +
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>' +
    '</Types>';

  rels :=
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + CRLF +
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
    '</Relationships>';

  workbook :=
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + CRLF +
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' +
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
    '<sheets><sheet name="' + XmlEsc(sheetName) + '" sheetId="1" r:id="rId1"/></sheets>' +
    '</workbook>';

  wbRels :=
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + CRLF +
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>' +
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' +
    '</Relationships>';

  { 4 个 cellXfs：0 普通、1 表头（粗体+浅蓝底）、2 合计（粗体+边框上）、3 标题（16pt 粗体） }
  styles :=
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + CRLF +
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
    '<fonts count="3">' +
    '<font><sz val="10.5"/><name val="Microsoft YaHei"/></font>' +
    '<font><b/><sz val="10.5"/><name val="Microsoft YaHei"/></font>' +
    '<font><b/><sz val="16"/><color rgb="FF173A70"/><name val="Microsoft YaHei"/></font>' +
    '</fonts>' +
    '<fills count="3">' +
    '<fill><patternFill patternType="none"/></fill>' +
    '<fill><patternFill patternType="gray125"/></fill>' +
    '<fill><patternFill patternType="solid"><fgColor rgb="FFE8EEF8"/><bgColor indexed="64"/></patternFill></fill>' +
    '</fills>' +
    '<borders count="2">' +
    '<border><left/><right/><top/><bottom/><diagonal/></border>' +
    '<border><left/><right/><top style="thin"><color rgb="FF2255AA"/></top><bottom/><diagonal/></border>' +
    '</borders>' +
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
    '<cellXfs count="4">' +
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>' +
    '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>' +
    '<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1"/>' +
    '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>' +
    '</cellXfs>' +
    '</styleSheet>';

  sheet := BuildXLSXSheet;

  z := TZipper.Create;
  keep := TList.Create;
  try
    try
      z.FileName := AFileName;
      AddPart('[Content_Types].xml', contentTypes);
      AddPart('_rels/.rels', rels);
      AddPart('xl/workbook.xml', workbook);
      AddPart('xl/_rels/workbook.xml.rels', wbRels);
      AddPart('xl/styles.xml', styles);
      AddPart('xl/worksheets/sheet1.xml', sheet);
      z.ZipAllFiles;
      Result := FileExists(AFileName);
    except
      Result := False;
    end;
  finally
    for i := 0 to keep.Count - 1 do
      TObject(keep[i]).Free;
    keep.Free;
    z.Free;
  end;
end;

end.
