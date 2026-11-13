{
  lazarusWeb :: menu_main
  ------------------------------------------------------------------
  做法三：菜单改用**标准 TMainMenu 控件**（LCL 原生菜单栏），右侧和
  menu_html 版一样是**真实的 LCL 控件**（TPageControl + 编辑框 +
  下拉框 + TStringGrid + TStatusBar）。演示主菜单与 LCL 控件的双向联动：

    菜单叶子项点击 -> 框架把 TMenuItem.OnClick 回发服务端（RTTI 通用分发）
                 -> MenuItemClick 里按控件名定位 -> ApplyKey 切 pcMain 页
                 -> 菜单项 Checked 与状态栏同步刷新

    LCL 查询/统计/下载按钮 -> 服务端填表格 -> 状态栏文字跟着更新

    直接点浏览器里的 LCL 页签 -> pcMain.OnChange -> 菜单 Checked 跟上

  框架侧无需任何改动：lwwriter 的 WriteMenuItems 序列化 TMainMenu
  （caption/enabled/checked/shortcut/分隔线），lw-alpine.js 在标题栏与
  客户区之间渲染 lw-menubar 并弹下拉，叶子项点击走通用事件通道。

  渲染层：Alpine.js，工程目录下 menu_main.ini 里 Client=alpine，不加载 Ext JS。
}
unit uMenuMain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls, ExtCtrls, Grids,
  Menus, lwform, lwweb;

type

  { TMenuMainForm }

  TMenuMainForm = class(TLWForm)
    mnuMain: TMainMenu;
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
    mnuHelp: TMenuItem;
    miAbout: TMenuItem;
    miSep1: TMenuItem;
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
    FActiveKey: string;
    procedure ApplyKey(const AKey: string);
    procedure SyncMenuState;
    procedure SetStatus(const AText: string);
  public
  end;

var
  MenuMainForm: TMenuMainForm;

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

function PageOfKey(const AKey: string): Integer;
begin
  if AKey = 'theory.signup' then Result := 0
  else if AKey = 'theory.score' then Result := 1
  else if AKey = 'theory.stat' then Result := 2
  else if AKey = 'theory.schedule' then Result := 3
  else Result := PAGE_OTHER;
end;

function KeyOfPage(APage: Integer): string;
begin
  case APage of
    0: Result := 'theory.signup';
    1: Result := 'theory.score';
    2: Result := 'theory.stat';
    3: Result := 'theory.schedule';
  else
    Result := 'other';
  end;
end;

function TitleOfKey(const AKey: string): string;
begin
  if AKey = 'theory.signup' then Result := '报名查询'
  else if AKey = 'theory.score' then Result := '成绩查询'
  else if AKey = 'theory.stat' then Result := '成绩统计'
  else if AKey = 'theory.schedule' then Result := '考试安排表下载'
  else if AKey = 'exam.plan' then Result := '考试计划'
  else if AKey = 'exam.room' then Result := '考场安排'
  else if AKey = 'exam.inv' then Result := '监考人员'
  else if AKey = 'qual.ent' then Result := '企业资质'
  else if AKey = 'qual.cert' then Result := '人员证书'
  else Result := '其他功能';
end;

{ ---------------- 窗体 ---------------- }

procedure TMenuMainForm.FormCreate(Sender: TObject);
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

  ApplyKey('theory.signup');
end;

procedure TMenuMainForm.ApplyKey(const AKey: string);
begin
  FActiveKey := AKey;
  pcMain.ActivePageIndex := PageOfKey(AKey);
  SyncMenuState;
  SetStatus(Format('当前：%s（服务端 %s）',
    [TitleOfKey(AKey), FormatDateTime('hh:nn:ss', Now)]));
end;

{ 菜单项 Checked 同步：writer 会把 Checked 序列化成下拉里的 ✓ }
procedure TMenuMainForm.SyncMenuState;
begin
  miSignup.Checked := FActiveKey = 'theory.signup';
  miScore.Checked := FActiveKey = 'theory.score';
  miStat.Checked := FActiveKey = 'theory.stat';
  miSchedule.Checked := FActiveKey = 'theory.schedule';
  miExamPlan.Checked := FActiveKey = 'exam.plan';
  miExamRoom.Checked := FActiveKey = 'exam.room';
  miExamInv.Checked := FActiveKey = 'exam.inv';
  miQualEnt.Checked := FActiveKey = 'qual.ent';
  miQualCert.Checked := FActiveKey = 'qual.cert';
end;

procedure TMenuMainForm.SetStatus(const AText: string);
begin
  sbMain.Panels[0].Text := AText;
end;

{ 主菜单叶子项点击：框架按 TMenuItem.OnClick 通用分发，这里按控件名定位 key }
procedure TMenuMainForm.MenuItemClick(Sender: TObject);
var
  n: string;
begin
  n := (Sender as TMenuItem).Name;
  if n = 'miSignup' then ApplyKey('theory.signup')
  else if n = 'miScore' then ApplyKey('theory.score')
  else if n = 'miStat' then ApplyKey('theory.stat')
  else if n = 'miSchedule' then ApplyKey('theory.schedule')
  else if n = 'miExamPlan' then ApplyKey('exam.plan')
  else if n = 'miExamRoom' then ApplyKey('exam.room')
  else if n = 'miExamInv' then ApplyKey('exam.inv')
  else if n = 'miQualEnt' then ApplyKey('qual.ent')
  else if n = 'miQualCert' then ApplyKey('qual.cert')
  else if n = 'miAbout' then
  begin
    SetStatus(Format('lazarusWeb menu_main demo（%s）',
      [FormatDateTime('hh:nn:ss', Now)]));
  end;
end;

{ 用户直接在浏览器里点 LCL 页签：这里只同步菜单 Checked 与状态栏 }
procedure TMenuMainForm.pcMainChange(Sender: TObject);
var
  key: string;
begin
  key := KeyOfPage(pcMain.ActivePageIndex);
  if key = FActiveKey then Exit;
  FActiveKey := key;
  SyncMenuState;
  SetStatus(Format('当前：%s（服务端 %s）',
    [TitleOfKey(key), FormatDateTime('hh:nn:ss', Now)]));
end;

{ ---------------- LCL 业务：查询 / 统计 / 下载 ---------------- }

procedure TMenuMainForm.btnSignupQueryClick(Sender: TObject);
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

procedure TMenuMainForm.btnScoreQueryClick(Sender: TObject);
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

procedure TMenuMainForm.btnStatClick(Sender: TObject);
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

procedure TMenuMainForm.btnDownloadClick(Sender: TObject);
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
