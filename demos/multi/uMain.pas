unit uMain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, Grids,
  ComCtrls, ExtCtrls, Menus, Buttons, Spin, lwform, uAbout;

type
  TMainForm = class(TLWForm)
    mmMain: TMainMenu;
    miFile: TMenuItem;
    miExit: TMenuItem;
    miHelp: TMenuItem;
    miAbout: TMenuItem;
    tbMain: TToolBar;
    tbRefresh: TToolButton;
    tbAbout: TToolButton;
    pcMain: TPageControl;
    tsData: TTabSheet;
    tsOpts: TTabSheet;
    sgData: TStringGrid;
    btnLoad: TButton;
    stbMain: TStatusBar;
    chkAuto: TCheckBox;
    lblLevel: TLabel;
    cboLevel: TComboBox;
    lblThreads: TLabel;
    seThreads: TSpinEdit;
    btnApply: TButton;
    lblState: TLabel;
    procedure FormCreate(Sender: TObject);
    procedure miExitClick(Sender: TObject);
    procedure miAboutClick(Sender: TObject);
    procedure tbRefreshClick(Sender: TObject);
    procedure btnLoadClick(Sender: TObject);
    procedure btnApplyClick(Sender: TObject);
  private
    procedure FillGrid;
  public
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

procedure TMainForm.FormCreate(Sender: TObject);
begin
  sgData.Cells[0, 0] := '单号';
  sgData.Cells[1, 0] := '客户';
  sgData.Cells[2, 0] := '金额';
  FillGrid;
  lblState.Caption := '就绪';
end;

procedure TMainForm.FillGrid;
var
  i, r: Integer;
begin
  sgData.RowCount := 1;
  for i := 1 to 12 do
  begin
    sgData.RowCount := i + 1;
    sgData.Cells[0, i] := Format('SO%04d', [i]);
    sgData.Cells[1, i] := '客户' + IntToStr(i);
    sgData.Cells[2, i] := FormatFloat('0.00', i * 137.5);
  end;
end;

procedure TMainForm.miExitClick(Sender: TObject);
begin
  Close;
end;

procedure TMainForm.miAboutClick(Sender: TObject);
var
  f: TAboutForm;
begin
  { 与桌面程序完全相同的写法：创建 -> ShowModal -> 释放。
    Web 模式下这一行会阻塞当前请求线程，把对话框推给浏览器，
    用户点确定后线程继续往下走 }
  f := TAboutForm.Create(nil);
  try
    if f.ShowModal = mrOk then
      lblState.Caption := '已查看关于（返回 mrOk）'
    else
      lblState.Caption := '已取消关于';
  finally
    f.Free;
  end;
end;

procedure TMainForm.tbRefreshClick(Sender: TObject);
begin
  FillGrid;
  lblState.Caption := '已刷新 ' + FormatDateTime('hh:nn:ss', Now);
end;

procedure TMainForm.btnLoadClick(Sender: TObject);
begin
  FillGrid;
  lblState.Caption := Format('已加载 %d 行', [sgData.RowCount - 1]);
end;

procedure TMainForm.btnApplyClick(Sender: TObject);
begin
  stbMain.Panels[0].Text := Format('自动刷新=%s 级别=%s 线程=%d',
    [BoolToStr(chkAuto.Checked, True), cboLevel.Text, seThreads.Value]);
  lblState.Caption := '参数已应用';
end;

end.
