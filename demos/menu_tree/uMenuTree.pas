{
  lazarusWeb :: menu_tree
  ------------------------------------------------------------------
  「截图左侧那种折叠菜单」做法一：用真实的 LCL TTreeView 当菜单。

    * 菜单结构 = 服务端 TTreeView.Items（父子节点树）
    * 折叠/展开 = 前端 lw-alpine.js 的 renderTree 在浏览器里直接完成
    * 点节点    = 回发 OnClick，服务端读 Selected，改右侧控件
                  （右侧标题/面包屑/正文都是真实 LCL 控件，改完自动同步）

  渲染层：Alpine.js（lw-alpine.js）。工程目录下的 menu_tree.ini 里
  Client=alpine，不加载 Ext JS。
}
unit uMenuTree;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, ExtCtrls, ComCtrls, StdCtrls, lwform;

type

  { TMenuTreeForm }

  TMenuTreeForm = class(TLWForm)
    tvMenu: TTreeView;
    pnlRight: TPanel;
    lblTitle: TLabel;
    lblPath: TLabel;
    lblTip: TLabel;
    mmoBody: TMemo;
    procedure FormCreate(Sender: TObject);
    procedure tvMenuClick(Sender: TObject);
  private
    procedure BuildMenu;
    procedure ShowNode(N: TTreeNode);
  public
  end;

var
  MenuTreeForm: TMenuTreeForm;

implementation

{$R *.lfm}

{ 加一个分组（有子项，前端才会画 ▶ 折角） }
function AddGroup(T: TTreeView; const ACaption: string;
  const AItems: array of string): TTreeNode;
var
  i: Integer;
begin
  Result := T.Items.Add(nil, ACaption);
  for i := Low(AItems) to High(AItems) do
    T.Items.AddChild(Result, AItems[i]);
end;

procedure TMenuTreeForm.FormCreate(Sender: TObject);
var
  N: TTreeNode;

  { nogui widgetset 没有 CreateTimer：TTreeView 的 Selected 赋值会启用
    内部 FChangeTimer 直接 EOutOfResources（框架在 lwdispatch 事件路径里
    已规避，业务代码里要自己兜）。选中状态本身已经生效，吞掉即可。 }
  procedure SafeSelect(ANode: TTreeNode);
  begin
    try
      tvMenu.Selected := ANode;
    except
      on E: EOutOfResources do;
    end;
  end;

begin
  BuildMenu;
  { 默认展开第一组并选中第一个叶子，和截图里的初始态一致。
    注意先 ShowNode 再 Selected —— Selected 赋值可能抛 nogui 定时器坑，
    不能让它中断内容初始化 }
  if tvMenu.Items.Count > 0 then
  begin
    tvMenu.Items[0].Expanded := True;
    N := tvMenu.Items[0].GetFirstChild;
    if N <> nil then
    begin
      ShowNode(N);
      SafeSelect(N);
    end;
  end;
end;

procedure TMenuTreeForm.BuildMenu;
begin
  tvMenu.Items.BeginUpdate;
  try
    tvMenu.Items.Clear;
    AddGroup(tvMenu, '从业人员理论考核',
      ['报名查询', '成绩查询', '成绩统计', '考试安排表下载']);
    AddGroup(tvMenu, '考试管理',
      ['考试计划', '考场安排', '监考人员']);
    AddGroup(tvMenu, '资质管理',
      ['企业资质', '人员证书']);
  finally
    tvMenu.Items.EndUpdate;
  end;
end;

procedure TMenuTreeForm.tvMenuClick(Sender: TObject);
var
  N: TTreeNode;
begin
  N := tvMenu.Selected;
  if N = nil then Exit;

  { 叶子节点：把父分组撑开，避免"点完子项分组又收起来" }
  if N.Level > 0 then
  begin
    if N.Parent <> nil then
      try
        N.Parent.Expanded := True;
      except
        on E: EOutOfResources do;
      end
  end
  else
    { 分组节点：点标题本身也能展开/收起（和截图里的行为一致） }
    try
      N.Expanded := not N.Expanded;
    except
      on E: EOutOfResources do;
    end;

  ShowNode(N);
end;

procedure TMenuTreeForm.ShowNode(N: TTreeNode);

  function BodyOf(const ACaption: string): string;
  begin
    if ACaption = '报名查询' then
      Result := '按姓名 / 身份证号 / 单位检索本期理论考核的报名记录，支持导出。' + LineEnding +
        '（真实项目里这里放 TDBGrid + 查询条件，本 demo 只演示菜单切换。）'
    else if ACaption = '成绩查询' then
      Result := '查询理论考核成绩（含补考），可按批次、单位、分数段筛选。'
    else if ACaption = '成绩统计' then
      Result := '按单位 / 批次汇总参考人数、合格率、平均分，并生成统计报表。'
    else if ACaption = '考试安排表下载' then
      Result := '下载本期考场安排表（Excel / PDF），下载走框架的令牌下载通道。'
    else if ACaption = '考试管理' then
      Result := '考试管理分组：维护考试计划、考场、监考人员等基础数据。点分组标题可展开/收起。'
    else if ACaption = '考试计划' then
      Result := '按年度维护考试批次、报名起止时间、考核科目。'
    else if ACaption = '考场安排' then
      Result := '维护考点与考场容量，自动排场并导出安排表。'
    else if ACaption = '监考人员' then
      Result := '维护监考人员名单，按场次分配监考任务。'
    else if ACaption = '资质管理' then
      Result := '资质管理分组：企业资质与人员证书的变更、延续、注销。'
    else if ACaption = '企业资质' then
      Result := '企业资质申报、变更、延续与注销的业务办理。'
    else if ACaption = '人员证书' then
      Result := '人员证书的发放、变更、遗失补办与有效性核验。'
    else
      Result := '（该节点还没有配置内容）';
  end;

var
  crumb: string;
begin
  crumb := N.Text;
  if N.Parent <> nil then
    crumb := N.Parent.Text + ' / ' + crumb;

  lblTitle.Caption := N.Text;
  lblPath.Caption := crumb;
  mmoBody.Lines.Text := BodyOf(N.Text);
  lblTip.Caption := Format('最近点击：%s（服务端 %s）', [crumb, FormatDateTime('hh:nn:ss', Now)]);
end;

end.
