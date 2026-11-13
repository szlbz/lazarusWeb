{
  lazarusWeb :: menu_lcl
  ------------------------------------------------------------------
  做法四：左侧菜单换成**真正的 LCL 组件 TLWSideMenu**（源：src/core/lwsidemenu.pas）。

    * 组件是 TMenu 的后裔 —— 在 Lazarus IDE 里双击就打开原生「菜单编辑器」，
      添加/删除菜单项、拖子菜单、设 Caption / ShortCut / Enabled / Checked，
      以及给单项配图标（Add icon from file…，写进 TMenuItem.Bitmap），
      与 TMainMenu 的操作完全一致；
    * 叶子项的 OnClick 就在设计期挂（本 demo 所有项共用 MenuItemClick，
      靠 Tag 区分是哪一个），运行期点击回发服务端，和服务端别的事件一样；
    * 运行期浏览器里：顶层项是可折叠分组、Checked 的项高亮，
      侧栏宽度 SideWidth 由客户区自动让位（右侧仍是真实 LCL 页签控件）。

  右侧内容区与 menu_html / menu_main 两个 demo 保持一致：
  TPageControl 5 个页签 + 真实 TEdit / TComboBox / TButton / TStringGrid，
  点菜单切页签、点页签菜单高亮跟随、查询结果回写状态栏。
}
unit uMenuLcl;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls, ExtCtrls, Grids,
  Menus, lwform, lwweb, lwsidemenu;

type

  { TMenuLclForm }

  TMenuLclForm = class(TLWForm)
    smMain: TLWSideMenu;
    mnuTheory: TMenuItem;
    miSignup: TMenuItem;
    miScore: TMenuItem;
    miStat: TMenuItem;
    miSchedule: TMenuItem;
    mnuExam: TMenuItem;
    miExamPlan: TMenuItem;
    miExamRoom: TMenuItem;
    miExamInv: TMenuItem;
    mnuQual: TMenuItem;
    miQualEnt: TMenuItem;
    miQualCert: TMenuItem;
    pnlTop: TPanel;
    lblGreeting: TLabel;
    pcMain: TPageControl;
    tsSignup: TTabSheet;
    lblName: TLabel;
    edtName: TEdit;
    lblYear: TLabel;
    cboYear: TComboBox;
    btnSignupQuery: TButton;
    lblSignupStatus: TLabel;
    sgSignup: TStringGrid;
    tsScore: TTabSheet;
    lblScoreName: TLabel;
    edtScoreName: TEdit;
    btnScoreQuery: TButton;
    lblScoreStatus: TLabel;
    sgScore: TStringGrid;
    tsStat: TTabSheet;
    btnStat: TButton;
    lblStatStatus: TLabel;
    sgStat: TStringGrid;
    tsSchedule: TTabSheet;
    mmoNotice: TMemo;
    btnDownload: TButton;
    lblDlStatus: TLabel;
    tsOther: TTabSheet;
    lblOther: TLabel;
    sbMain: TStatusBar;
    procedure FormCreate(Sender: TObject);
    procedure MenuItemClick(Sender: TObject);
    procedure pcMainChange(Sender: TObject);
    procedure btnSignupQueryClick(Sender: TObject);
    procedure btnScoreQueryClick(Sender: TObject);
    procedure btnStatClick(Sender: TObject);
    procedure btnDownloadClick(Sender: TObject);
  private
    FActiveTag: Integer;
    procedure ApplyTag(ATag: Integer);
    procedure SyncChecked;
    procedure SetStatus(const AText: string);
  public
  end;

var
  MenuLclForm: TMenuLclForm;

implementation

{$R *.lfm}

const
  { 没有对应业务页的菜单项落到"其他功能"页 }
  PAGE_OTHER = 4;

  { 以下姓名、公司、证件号、电话均为虚构的示例数据，仅用于演示界面 }
  SIGNUP_NAMES: array[0..5] of string =
    ('张一凡', '李思远', '陈嘉禾', '赵子墨', '孙可欣', '周立诚');
  SIGNUP_COMPANIES: array[0..5] of string =
    ('深圳市正衡工程检测有限公司', '深圳市远川建筑工程检测有限公司',
     '深圳市正衡工程检测有限公司', '深圳市正衡工程检测有限公司',
     '深圳市远川建筑工程检测有限公司', '深圳市正衡工程检测有限公司');
  SIGNUP_IDS: array[0..5] of string =
    ('4403**********0017', '4403**********2231', '4401**********5566',
     '4301**********8890', '4403**********3372', '6101**********4415');
  SIGNUP_PHONES: array[0..5] of string =
    ('138****2201', '139****8812', '137****6631', '135****9027',
     '136****4418', '188****7735');
  SIGNUP_STATES: array[0..5] of string =
    ('已审核', '已审核', '待审核', '已审核', '待审核', '已审核');

function PageOfTag(ATag: Integer): Integer;
begin
  if (ATag >= 0) and (ATag <= 3) then Result := ATag
  else Result := PAGE_OTHER;
end;

function TitleOfTag(ATag: Integer): string;
begin
  case ATag of
    0: Result := '报名查询';
    1: Result := '成绩查询';
    2: Result := '成绩统计';
    3: Result := '考试安排表下载';
    10: Result := '考试计划';
    11: Result := '考场安排';
    12: Result := '监考人员';
    20: Result := '企业资质';
    21: Result := '人员证书';
  else
    Result := '其他功能';
  end;
end;

{ ---------------- 窗体 ---------------- }

procedure TMenuLclForm.FormCreate(Sender: TObject);
begin
  pcMain.ActivePageIndex := 0;

  { 表格表头是设计期固定内容，数据由查询按钮填 }
  sgSignup.ColCount := 6;
  sgSignup.FixedRows := 1;
  sgSignup.FixedCols := 0;
  sgSignup.RowCount := 2;
  sgSignup.Cells[0, 0] := '姓名';
  sgSignup.Cells[1, 0] := '公司名称';
  sgSignup.Cells[2, 0] := '身份证号';
  sgSignup.Cells[3, 0] := '手机号';
  sgSignup.Cells[4, 0] := '状态';
  sgSignup.Cells[5, 0] := '考试年份';

  sgScore.ColCount := 5;
  sgScore.FixedRows := 1;
  sgScore.FixedCols := 0;
  sgScore.RowCount := 2;
  sgScore.Cells[0, 0] := '公司名称';
  sgScore.Cells[1, 0] := '姓名';
  sgScore.Cells[2, 0] := '科目';
  sgScore.Cells[3, 0] := '考试日期';
  sgScore.Cells[4, 0] := '成绩';

  sgStat.ColCount := 4;
  sgStat.FixedRows := 1;
  sgStat.FixedCols := 0;
  sgStat.RowCount := 2;
  sgStat.Cells[0, 0] := '公司名称';
  sgStat.Cells[1, 0] := '科目';
  sgStat.Cells[2, 0] := '总人数';
  sgStat.Cells[3, 0] := '通过人数';

  ApplyTag(0);
end;

procedure TMenuLclForm.ApplyTag(ATag: Integer);
begin
  FActiveTag := ATag;
  pcMain.ActivePageIndex := PageOfTag(ATag);
  SyncChecked;
  SetStatus(Format('当前：%s（服务端 %s）',
    [TitleOfTag(ATag), FormatDateTime('hh:nn:ss', Now)]));
end;

{ 菜单项的 Checked 就是浏览器侧栏的高亮状态（writer 把 Checked 序列化过去） }
procedure TMenuLclForm.SyncChecked;

  procedure Walk(MI: TMenuItem);
  var
    i: Integer;
  begin
    for i := 0 to MI.Count - 1 do
    begin
      if MI.Items[i].Count > 0 then
        Walk(MI.Items[i])
      else
        MI.Items[i].Checked := MI.Items[i].Tag = FActiveTag;
    end;
  end;

begin
  Walk(smMain.Items);
end;

procedure TMenuLclForm.SetStatus(const AText: string);
begin
  sbMain.Panels[0].Text := AText;
end;

{ 左侧菜单被点：框架按 TMenuItem.OnClick 通用分发（RTTI），Tag 区分是哪一项 }
procedure TMenuLclForm.MenuItemClick(Sender: TObject);
begin
  if not (Sender is TMenuItem) then Exit;
  ApplyTag(TMenuItem(Sender).Tag);
end;

{ 用户直接在浏览器里点 LCL 页签：菜单高亮（Checked）与状态栏跟上 }
procedure TMenuLclForm.pcMainChange(Sender: TObject);
var
  idx, at2: Integer;
begin
  idx := pcMain.ActivePageIndex;
  if idx = PAGE_OTHER then Exit;      { 其他功能页不改变菜单选中项 }
  at2 := idx;
  if at2 = FActiveTag then Exit;
  FActiveTag := at2;
  SyncChecked;
  SetStatus(Format('当前：%s（服务端 %s）',
    [TitleOfTag(at2), FormatDateTime('hh:nn:ss', Now)]));
end;

{ ---------------- LCL 业务：查询 / 统计 / 下载 ---------------- }

procedure TMenuLclForm.btnSignupQueryClick(Sender: TObject);
var
  i, n: Integer;
  kw, year: string;
begin
  kw := Trim(edtName.Text);
  year := cboYear.Text;
  if year = '' then year := '2026';

  n := 0;
  sgSignup.RowCount := 1;
  for i := Low(SIGNUP_NAMES) to High(SIGNUP_NAMES) do
    if (kw = '') or (Pos(kw, SIGNUP_NAMES[i]) > 0) then
    begin
      Inc(n);
      sgSignup.RowCount := n + 1;
      sgSignup.Cells[0, n] := SIGNUP_NAMES[i];
      sgSignup.Cells[1, n] := SIGNUP_COMPANIES[i];
      sgSignup.Cells[2, n] := SIGNUP_IDS[i];
      sgSignup.Cells[3, n] := SIGNUP_PHONES[i];
      sgSignup.Cells[4, n] := SIGNUP_STATES[i];
      sgSignup.Cells[5, n] := year;
    end;

  lblSignupStatus.Caption := Format('共 %d 条（%s）',
    [n, FormatDateTime('hh:nn:ss', Now)]);
  SetStatus(Format('报名查询：%s 年份共 %d 条', [year, n]));
end;

procedure TMenuLclForm.btnScoreQueryClick(Sender: TObject);
var
  i, n: Integer;
  kw: string;
begin
  kw := Trim(edtScoreName.Text);

  n := 0;
  sgScore.RowCount := 1;
  for i := Low(SIGNUP_NAMES) to High(SIGNUP_NAMES) do
    if (kw = '') or (Pos(kw, SIGNUP_NAMES[i]) > 0) then
    begin
      Inc(n);
      sgScore.RowCount := n + 1;
      sgScore.Cells[0, n] := SIGNUP_COMPANIES[i];
      sgScore.Cells[1, n] := SIGNUP_NAMES[i];
      sgScore.Cells[2, n] := '超声探伤';
      sgScore.Cells[3, n] := FormatDateTime('yyyy-mm-dd', Date);
      sgScore.Cells[4, n] := IntToStr(62 + i * 6);
    end;

  lblScoreStatus.Caption := Format('共 %d 条（%s）',
    [n, FormatDateTime('hh:nn:ss', Now)]);
  SetStatus(Format('成绩查询：共 %d 条', [n]));
end;

procedure TMenuLclForm.btnStatClick(Sender: TObject);
begin
  sgStat.RowCount := 4;

  sgStat.Cells[0, 1] := '深圳市正衡工程检测有限公司';
  sgStat.Cells[1, 1] := '超声探伤';
  sgStat.Cells[2, 1] := '4';
  sgStat.Cells[3, 1] := '3';

  sgStat.Cells[0, 2] := '深圳市远川建筑工程检测有限公司';
  sgStat.Cells[1, 2] := '低应变';
  sgStat.Cells[2, 2] := '2';
  sgStat.Cells[3, 2] := '2';

  sgStat.Cells[0, 3] := '深圳市正衡工程检测有限公司';
  sgStat.Cells[1, 3] := '地基基础';
  sgStat.Cells[2, 3] := '3';
  sgStat.Cells[3, 3] := '2';

  lblStatStatus.Caption := Format('统计完成（%s）', [FormatDateTime('hh:nn:ss', Now)]);
  SetStatus('成绩统计：3 个单位 / 9 人');
end;

procedure TMenuLclForm.btnDownloadClick(Sender: TObject);
var
  L: TStringList;
  i: Integer;
begin
  L := TStringList.Create;
  try
    L.Add('场次,考试时间,考试科目,人数,考生姓名');
    for i := Low(SIGNUP_NAMES) to High(SIGNUP_NAMES) do
      L.Add(Format('%d,2026-11-09 09:15~10:00,超声探伤,3,%s',
        [i + 1, SIGNUP_NAMES[i]]));
    SendText(L.Text, '考试安排表.csv', True);
  finally
    L.Free;
  end;
  lblDlStatus.Caption := Format('已生成下载（%s）', [FormatDateTime('hh:nn:ss', Now)]);
  SetStatus('已生成考试安排表下载');
end;

end.
