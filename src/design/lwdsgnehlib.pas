{
  lazarusWeb :: lwdsgnehlib
  ------------------------------------------------------------------
  可选设计期包 lwehlib 的注册单元：把 TDBGridEh 转成 TLWDBGrid。

  为什么需要转换：TDBGridEh 的祖先链是 TCustomDBGridEh ->
  TCustomDBAxisGridEh，不是 TDBGrid 的后代，lwwriter 的
  "if C is TDBGrid" 分支认不出它。转换后运行时零 EhLib 依赖，
  列、DataSource、Options、多表头（UseMultiTitle）一次性搬过去。

  多表头：EhLib 用列标题里的 '|' 分层（'基本信息|姓名'），
  转换时 Title.Caption 原样复制，并把 MultiTitle 置为 True；
  lwwriter 会按同一套写法生成 hrows/htree，浏览器按
  colspan/rowspan 渲染任意层级。

  开关见 lwehlib.inc。本单元只在 lwehlib.lpk 里编译，
  lwdesign 不引用它，未安装 EhLib 的机器不受影响。
}
unit lwdsgnehlib;

{$mode objfpc}{$H+}
{$I lwehlib.inc}

interface

procedure Register;

implementation

{$IFDEF LW_EHLIB_DBGRIDEH}

uses
  Classes, SysUtils, Controls, DB, DBGrids, DBGridEh, Dialogs, ComponentEditors,
  lwdbgrid, lwehlibconvert;

type
  TDBGridEhConvertEditor = class(TComponentEditor)
  public
    procedure ExecuteVerb(Index: Integer); override;
    function GetVerb(Index: Integer): string; override;
    function GetVerbCount: Integer; override;
  end;

{ 属性/列/多表头/树形的复制都在 lwehlibconvert 里（运行时 demo 共用同一份），
  这里只负责设计器的"新建 -> 删除旧控件 -> 接管名字"流程。 }
function ConvertGridEh(AGrid: TDBGridEh;
  ADesigner: TComponentEditorDesigner): Boolean;
var
  NewGrid: TLWDBGrid;
  OldName: string;
begin
  Result := False;
  if (AGrid = nil) or (AGrid.Owner = nil) or (AGrid.Parent = nil) then Exit;
  OldName := AGrid.Name;
  NewGrid := LWBuildGridFromEhLib(AGrid, AGrid.Owner, AGrid.Parent);
  if NewGrid = nil then Exit;
  try
    { 先让 IDE 删除旧组件（走 DeleteSelection，设计器对象树才会同步）；
       没有设计器时（理论上不会发生）退化为直接 Free。 }
    if ADesigner <> nil then
    begin
      ADesigner.SelectOnlyThisComponent(AGrid);
      ADesigner.DeleteSelection;
    end
    else
      AGrid.Free;
    NewGrid.Name := OldName;
    if ADesigner <> nil then
    begin
      ADesigner.SelectOnlyThisComponent(NewGrid);
      ADesigner.Modified;
    end;
    Result := True;
  except
    NewGrid.Free;
    raise;
  end;
end;

procedure TDBGridEhConvertEditor.ExecuteVerb(Index: Integer);
var
  G: TDBGridEh;
  Msg: string;
  k, p: string;
  defexp: Boolean;
begin
  if Index <> 0 then Exit;
  G := TDBGridEh(Component);
  Msg := '已转换为 TLWDBGrid：Columns、DataSource、Options、多表头（UseMultiTitle）已复制。';
  if LWGridEhHasTree(G, k, p, defexp) then
    Msg := Msg + LineEnding + '树形已复制：KeyField=' + k +
      '，ParentField=' + p + '（TreeView 展开/缩进由前端渲染）。';
  if G.FrozenCols > 0 then
    Msg := Msg + LineEnding + '注意：EhLib 冻结列（FrozenCols）未映射。';
  if G.FooterRowCount > 0 then
    Msg := Msg + LineEnding + '注意：Footer 行未自动映射，请用 TLWDBGrid 的 SummaryType/SummaryField 配置。';
  if ConvertGridEh(G, Designer) then
    ShowMessage(Msg + LineEnding + '请检查列宽与表头，保存窗体后生效。')
  else
    ShowMessage('转换失败：该控件没有 Owner 或 Parent。');
end;

function TDBGridEhConvertEditor.GetVerbCount: Integer;
begin
  Result := 1;
end;

function TDBGridEhConvertEditor.GetVerb(Index: Integer): string;
begin
  if Index = 0 then
    Result := '转换为 lazarusWeb TLWDBGrid…'
  else
    Result := '';
end;

{$ENDIF}

procedure Register;
begin
  {$IFDEF LW_EHLIB_DBGRIDEH}
  RegisterComponentEditor(TDBGridEh, TDBGridEhConvertEditor);
  {$ENDIF}
end;

end.
