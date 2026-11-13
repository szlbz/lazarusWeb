{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwdbgrid
  ------------------------------------------------------------------
  TLWDBGrid —— 带分页/过滤/汇总的 TDBGrid 子类（大表场景，
  对应 uniGUI 的 uniDBGrid PagingBar / FilterBar / Summary）。

  用法：
    grd.PageSize    := 25;       // 每页 25 行；0 = 不分页（默认，完全等同 TDBGrid）
    grd.ShowFilter  := True;     // 网格顶部出"过滤"工具条
    grd.SummaryType := gsSum;    // gsNone / gsSum / gsAvg / gsCount
    grd.SummaryField := 'price'; // 汇总字段（须是数值列）

  运行时状态（不 published，框架自己维护）：
    CurrentPage  当前页（1 起）；浏览器端分页条触发 OnPageChange 时改写
    FilterText   过滤关键字；触发 OnFilter 时改写（显示层过滤，
                 序列化时对可见列做"包含匹配"，不动 SQL、不动数据集）

  行号->记录映射（分页/过滤后浏览器送来的 row 是"页内第几行"）：
    序列化时把"匹配行"的书签记在 Matches 里，lwdispatch 的
    LWApplyGridPos 用它定位数据集游标 —— 点行 / 编辑单元格在翻页
    和过滤之后依然指向正确的记录。

  lfm 兼容：RegisterClassAlias(TLWDBGrid, 'TDBGrid') —— 旧 lfm 里写的
  TDBGrid 自动落到这个子类，新属性全有缺省值，行为不变。
}
unit lwdbgrid;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DBGrids;

type
  TLWGridSummary = (gsNone, gsSum, gsAvg, gsCount);

  TLWDBGrid = class(TDBGrid)
  private
    FPageSize: Integer;
    FShowFilter: Boolean;
    FSummaryType: TLWGridSummary;
    FSummaryField: string;
    FCurrentPage: Integer;
    FFilterText: string;
    FMatches: array of TBytes;   { 最近一次序列化的匹配行书签（TBookmark = TBytes）}
    function GetCurrentPage: Integer;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { 按过滤后的总行数算页数；PageSize<=0 时恒为 1 }
    function PageOf(AFilteredRows: Integer): Integer;
    { 匹配书签表：writer 填充 / lwdispatch 读取。书签只在"数据集未关闭
      重开"期间有效，失效时定位静默失败（try/except 兜底退回 RecNo 路径）。
      TBookmark 在本机 FPC 是 TBytes（托管动态数组），不能用 TList 装指针 }
    procedure MatchClear;
    procedure MatchAdd(const B: TBytes);
    function MatchCount: Integer;
    function MatchAt(AIndex: Integer): TBytes;
    property CurrentPage: Integer read GetCurrentPage write FCurrentPage;
    property FilterText: string read FFilterText write FFilterText;
  published
    property PageSize: Integer read FPageSize write FPageSize;   { 0 = 关闭分页 }
    property ShowFilter: Boolean read FShowFilter write FShowFilter;
    property SummaryType: TLWGridSummary read FSummaryType write FSummaryType default gsNone;
    property SummaryField: string read FSummaryField write FSummaryField;
    { TDBGrid 的常规 published 属性原样继承（Options/Columns/DataSource...）}
  end;

implementation

constructor TLWDBGrid.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPageSize := 0;
  FCurrentPage := 1;
  FSummaryType := gsNone;
end;

destructor TLWDBGrid.Destroy;
begin
  { TBytes 由引用计数自动回收，这里只需清引用 }
  FMatches := nil;
  inherited Destroy;
end;

procedure TLWDBGrid.MatchClear;
begin
  FMatches := nil;
end;

procedure TLWDBGrid.MatchAdd(const B: TBytes);
var
  n: Integer;
begin
  n := Length(FMatches);
  SetLength(FMatches, n + 1);
  FMatches[n] := B;
end;

function TLWDBGrid.MatchCount: Integer;
begin
  Result := Length(FMatches);
end;

function TLWDBGrid.MatchAt(AIndex: Integer): TBytes;
begin
  Result := nil;
  if (AIndex >= 0) and (AIndex < Length(FMatches)) then
    Result := FMatches[AIndex];
end;

function TLWDBGrid.GetCurrentPage: Integer;
begin
  if FCurrentPage < 1 then FCurrentPage := 1;
  Result := FCurrentPage;
end;

function TLWDBGrid.PageOf(AFilteredRows: Integer): Integer;
begin
  if FPageSize <= 0 then Exit(1);
  Result := (AFilteredRows + FPageSize - 1) div FPageSize;
  if Result < 1 then Result := 1;
end;

initialization
  RegisterClass(TLWDBGrid);
  { lfm 里写 TDBGrid 的窗体自动获得分页/过滤能力（新属性全缺省关闭）。
    注意后注册的别名优先：FindClass('TDBGrid') 会先命中这个别名 }
  RegisterClassAlias(TLWDBGrid, 'TDBGrid');

end.
