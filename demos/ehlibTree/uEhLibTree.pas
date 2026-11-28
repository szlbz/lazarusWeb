{ lazarusWeb :: EhLib 树形网格 demo
  ------------------------------------------------------------------
  演示两件事同时成立：
    1. EhLib 的多表头（UseMultiTitle + 列标题里的 '|'）
    2. EhLib/MemTable 的树形（TreeList.Active + KeyFieldName/RefParentFieldName）

  流程：先用 TMemTableEh 造一棵组织架构数据，放在 TDBGridEh 里；
  再调用 LWBuildGridFromEhLib 转成 TLWDBGrid（运行时不需要 EhLib），
  浏览器端看到的就是「多级表头 + 树形网格」。

  为什么不是直接把 TDBGridEh 交给框架：TDBGridEh 不是 TDBGrid 的后代，
  lwwriter 认不出它；转换后列、多表头、树形配置都搬进 TLWDBGrid，
  Web 端由 lwwriter 按 key/parent 计算层级。
}
unit uEhLibTree;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Graphics, DB, DBGrids, DBGridEh,
  MemTableEh, lwform, lwdbgrid, lwehlibconvert;

type
  TEhLibTreeForm = class(TLWForm)
  private
    FMem: TMemTableEh;
    FDS: TDataSource;
    FGrid: TLWDBGrid;
    FLbl: TLabel;
    procedure BuildData;
    procedure AddNode(AId, AParentId: Integer; const AName: string;
      APeople: Integer; AAmount: Double; const ANote: string);
    procedure BuildGrid;
  public
    { 没有 .lfm 资源，界面在构造函数里搭：TLWApp 用 cls.Create(nil) 建窗体，
      OnCreate 不会被触发（那是 lfm 负责赋值的）}
    constructor Create(AOwner: TComponent); override;
  end;

implementation

procedure TEhLibTreeForm.AddNode(AId, AParentId: Integer; const AName: string;
  APeople: Integer; AAmount: Double; const ANote: string);
begin
  FMem.Append;
  FMem.FieldByName('id').AsInteger := AId;
  if AParentId > 0 then
    FMem.FieldByName('parent_id').AsInteger := AParentId
  else
    FMem.FieldByName('parent_id').Clear;
  FMem.FieldByName('name').AsString := AName;
  FMem.FieldByName('people').AsInteger := APeople;
  FMem.FieldByName('amount').AsFloat := AAmount;
  FMem.FieldByName('note').AsString := ANote;
  FMem.Post;
end;

procedure TEhLibTreeForm.BuildData;
begin
  FMem := TMemTableEh.Create(Self);
  FMem.FieldDefs.Add('id', ftInteger);
  FMem.FieldDefs.Add('parent_id', ftInteger);
  FMem.FieldDefs.Add('name', ftString, 40);
  FMem.FieldDefs.Add('people', ftInteger);
  FMem.FieldDefs.Add('amount', ftFloat);
  FMem.FieldDefs.Add('note', ftString, 60);

  { EhLib 树形：KeyFieldName + RefParentFieldName，Active 打开后
    网格首列自动画缩进/树线/展开标记 }
  FMem.TreeList.KeyFieldName := 'id';
  FMem.TreeList.RefParentFieldName := 'parent_id';
  FMem.TreeList.DefaultNodeExpanded := True;
  FMem.TreeList.Active := True;

  FMem.CreateDataSet;

  { 三层：总部 -> 大区 -> 分公司 -> 部门（第四层）}
  AddNode(1, 0, '集团总部', 120, 3600, '含董事会与职能中心');
  AddNode(2, 1, '华东大区', 48, 1580, '');
  AddNode(3, 1, '华南大区', 42, 1320, '');
  AddNode(4, 2, '上海分公司', 22, 860, '旗舰分公司');
  AddNode(5, 2, '杭州分公司', 14, 420, '');
  AddNode(6, 3, '广州分公司', 26, 780, '');
  AddNode(7, 3, '深圳分公司', 16, 540, '');
  AddNode(8, 4, '销售一部', 9, 420, '');
  AddNode(9, 4, '销售二部', 7, 310, '');
  AddNode(10, 8, '华东一组', 5, 230, '最末级');
  AddNode(11, 8, '华东二组', 4, 190, '最末级');

  FDS := TDataSource.Create(Self);
  FDS.DataSet := FMem;
end;

procedure TEhLibTreeForm.BuildGrid;
var
  Eh: TDBGridEh;
  C: TColumnEh;

  procedure AddCol(const AField, ATitle: string; AWidth: Integer);
  begin
    C := Eh.Columns.Add;
    C.FieldName := AField;
    C.Title.Caption := ATitle;
    C.Width := AWidth;
    C.Title.Alignment := taCenter;
  end;

begin
  { 源网格：真实存在的 TDBGridEh，多表头靠列标题里的 '|' 分层 }
  Eh := TDBGridEh.Create(Self);
  Eh.Width := 860;
  Eh.Height := 420;
  Eh.DataSource := FDS;
  Eh.UseMultiTitle := True;
  Eh.ReadOnly := True;
  Eh.Options := Eh.Options + [dgTitles, dgIndicator, dgColLines, dgRowLines];

  { 首列是树列，给一个顶层标题；其余列才进分组。
    Ext 的树列必须是顶层第一列，若写成 '组织架构|名称'，TreePanel 会把
    树列提出来、把分组拆开，表头看起来是断的。 }
  AddCol('name', '组织架构', 210);
  AddCol('people', '编制|人数', 80);
  AddCol('amount', '经营数据|产值(万元)|本月', 120);
  AddCol('note', '经营数据|产值(万元)|说明', 160);
  AddCol('id', '编号', 70);
  AddCol('parent_id', '上级编号', 90);

  { 转换：列、多表头、树形（KeyFieldName/RefParentFieldName）一起搬过去 }
  FGrid := LWBuildGridFromEhLib(Eh, Self, Self);
  Eh.Free;
  if FGrid = nil then
  begin
    FLbl.Caption := '转换失败：请检查 EhLib 是否可用。';
    Exit;
  end;

  FGrid.Left := 0;
  FGrid.Top := 0;
  FGrid.Align := alClient;
  FGrid.TreeIndent := 20;
  FGrid.PageSize := 0;      { 树形模式下分页本来也会被忽略 }
  FGrid.ShowFilter := True;
end;

constructor TEhLibTreeForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Caption := 'lazarusWeb · EhLib 树形网格 Demo';
  Width := 1000;
  Height := 620;

  FLbl := TLabel.Create(Self);
  FLbl.Parent := Self;
  FLbl.Align := alTop;
  FLbl.Height := 34;
  FLbl.Layout := tlCenter;
  FLbl.Font.Size := 11;
  FLbl.Caption := 'EhLib TDBGridEh（多表头 + MemTable 树形）已转换为 TLWDBGrid；' +
    '点首列箭头展开/折叠。';

  BuildData;
  BuildGrid;
end;

end.
