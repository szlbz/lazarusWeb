{
  lazarusWeb :: lwehlibconvert
  ------------------------------------------------------------------
  TDBGridEh -> TLWDBGrid 的转换逻辑（运行时可用，不依赖 IDEIntf）。

  设计期由 lwdsgnehlib（lwehlib.lpk）调用；运行时 demo 也直接调它，
  这样"EhLib 网格长什么样"和"转换后长什么样"用的是同一份代码。

  复制内容：
    - 位置尺寸 / Align / Anchors / 字体 / 颜色 / TabOrder
    - DataSource / ReadOnly / Options（EhLib 的同名枚举逐项映射）
    - Columns（字段名、标题、宽度、可见、对齐、只读、PickList…）
    - 多表头：EhLib 的 UseMultiTitle -> TLWDBGrid.MultiTitle
    - 树形：MemTableEh.TreeList（Active/KeyFieldName/RefParentFieldName/
      DefaultNodeExpanded）-> TLWDBGrid.TreeKeyField/TreeParentField/
      TreeDefaultExpanded。运行时不需要 EhLib：层级由 lwwriter 按
      key/parent 两列在序列化时计算。

  不复制：FrozenCols、Footer 行、EhLib 专有的单元格编辑器/排序标记。
}
unit lwehlibconvert;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, DB, DBGrids, DBGridEh, lwdbgrid;

{ 新建一个 TLWDBGrid 并接管 ASource 的数据/列/多表头/树形。
   ASource 本身不释放 —— 设计期由 IDE 的 DeleteSelection 处理，
   运行时由调用方 Free。返回 nil 表示 ASource 没有 Owner。 }
function LWBuildGridFromEhLib(ASource: TDBGridEh; AOwner: TComponent;
  AParent: TWinControl): TLWDBGrid;

{ 把 ASource 的属性/列复制到已存在的 ADest（不清空 ADest.Columns）}
procedure LWCopyGridEhTo(ASource: TDBGridEh; ADest: TLWDBGrid);

{ 数据集是 TMemTableEh 且 TreeList.Active 时，把树形配置搬到 ADest。
   返回 True 表示 ADest 已按树形网格配置。 }
function LWCopyTreeInfo(ASource: TDBGridEh; ADest: TLWDBGrid): Boolean;

{ 探测树形配置（不修改 ADest）}
function LWGridEhHasTree(ASource: TDBGridEh;
  out AKeyField, AParentField: string; out ADefaultExpanded: Boolean): Boolean;

implementation

uses
  MemTableEh;

{ EhLib 自己定义了一套同名 TDBGridOption（成员相同、类型不同），
  不能直接赋值；按成员逐个搬。EhLib 的 dghColumnMove 在 OptionsEh，
  LCL 放在 Options，这里统一打开。 }
function MapGridOptions(const A: DBGridEh.TDBGridOptions): DBGrids.TDBGridOptions;
begin
  Result := [];
  if DBGridEh.dgEditing in A then Include(Result, DBGrids.dgEditing);
  if DBGridEh.dgAlwaysShowEditor in A then Include(Result, DBGrids.dgAlwaysShowEditor);
  if DBGridEh.dgTitles in A then Include(Result, DBGrids.dgTitles);
  if DBGridEh.dgIndicator in A then Include(Result, DBGrids.dgIndicator);
  if DBGridEh.dgColumnResize in A then Include(Result, DBGrids.dgColumnResize);
  if DBGridEh.dgColLines in A then Include(Result, DBGrids.dgColLines);
  if DBGridEh.dgRowLines in A then Include(Result, DBGrids.dgRowLines);
  if DBGridEh.dgTabs in A then Include(Result, DBGrids.dgTabs);
  if DBGridEh.dgRowSelect in A then Include(Result, DBGrids.dgRowSelect);
  if DBGridEh.dgAlwaysShowSelection in A then Include(Result, DBGrids.dgAlwaysShowSelection);
  if DBGridEh.dgConfirmDelete in A then Include(Result, DBGrids.dgConfirmDelete);
  if DBGridEh.dgCancelOnExit in A then Include(Result, DBGrids.dgCancelOnExit);
  if DBGridEh.dgMultiSelect in A then Include(Result, DBGrids.dgMultiselect);
  Include(Result, DBGrids.dgColumnMove);
end;

function LWGridEhHasTree(ASource: TDBGridEh;
  out AKeyField, AParentField: string; out ADefaultExpanded: Boolean): Boolean;
var
  ds: TDataSet;
  mt: TCustomMemTableEh;
begin
  Result := False;
  AKeyField := '';
  AParentField := '';
  ADefaultExpanded := False;
  if (ASource = nil) or (ASource.DataSource = nil) then Exit;
  { EhLib 的 DataSource 是 TComponent（可能接非 DB 数据源），
    DB 网格统一用 DBDataSource 取 TDataSource }
  ds := ASource.DataSet;
  if ds = nil then Exit;
  if not (ds is TCustomMemTableEh) then Exit;
  mt := TCustomMemTableEh(ds);
  if not mt.TreeList.Active then Exit;
  AKeyField := mt.TreeList.KeyFieldName;
  AParentField := mt.TreeList.RefParentFieldName;
  ADefaultExpanded := mt.TreeList.DefaultNodeExpanded;
  Result := AKeyField <> '';
end;

function LWCopyTreeInfo(ASource: TDBGridEh; ADest: TLWDBGrid): Boolean;
var
  k, p: string;
  defexp: Boolean;
begin
  Result := LWGridEhHasTree(ASource, k, p, defexp);
  if not Result then Exit;
  ADest.TreeKeyField := k;
  ADest.TreeParentField := p;
  ADest.TreeDefaultExpanded := defexp;
end;

procedure LWCopyGridEhTo(ASource: TDBGridEh; ADest: TLWDBGrid);
var
  i: Integer;
  Src: TColumnEh;
  Dst: TColumn;
begin
  if (ASource = nil) or (ADest = nil) then Exit;
  ADest.Left := ASource.Left;
  ADest.Top := ASource.Top;
  ADest.Width := ASource.Width;
  ADest.Height := ASource.Height;
  ADest.Align := ASource.Align;
  ADest.Anchors := ASource.Anchors;
  ADest.Visible := ASource.Visible;
  ADest.Enabled := ASource.Enabled;
  ADest.TabOrder := ASource.TabOrder;
  ADest.Color := ASource.Color;
  ADest.Font.Assign(ASource.Font);
  ADest.TitleFont.Assign(ASource.TitleFont);
  ADest.ReadOnly := ASource.ReadOnly;
  if ASource.DBDataSource <> nil then
    ADest.DataSource := ASource.DBDataSource
  else
    ADest.DataSource := nil;
  ADest.Options := MapGridOptions(ASource.Options);
  { EhLib 的多表头开关；列标题里的 '|' 原样保留，由 lwwriter 解析 }
  ADest.MultiTitle := ASource.UseMultiTitle;

  for i := 0 to ASource.Columns.Count - 1 do
  begin
    Src := ASource.Columns[i];
    Dst := ADest.Columns.Add;
    Dst.FieldName := Src.FieldName;
    Dst.Title.Caption := Src.Title.Caption;
    Dst.Title.Alignment := Src.Title.Alignment;
    if Src.Title.Font <> nil then
      Dst.Title.Font.Assign(Src.Title.Font);
    Dst.Width := Src.Width;
    Dst.Visible := Src.Visible;
    Dst.Alignment := Src.Alignment;
    Dst.ReadOnly := Src.ReadOnly;
    Dst.PickList.Assign(Src.PickList);
    Dst.DropDownRows := Src.DropDownRows;
    Dst.DisplayFormat := Src.DisplayFormat;
    Dst.Color := Src.Color;
  end;

  LWCopyTreeInfo(ASource, ADest);
end;

function LWBuildGridFromEhLib(ASource: TDBGridEh; AOwner: TComponent;
  AParent: TWinControl): TLWDBGrid;
begin
  Result := nil;
  if (ASource = nil) or (AOwner = nil) then Exit;
  Result := TLWDBGrid.Create(AOwner);
  try
    if AParent <> nil then
      Result.Parent := AParent;
    LWCopyGridEhTo(ASource, Result);
  except
    FreeAndNil(Result);
    raise;
  end;
end;

end.
