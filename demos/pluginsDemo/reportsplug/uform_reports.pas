unit uform_reports;
{ pluginsDemo 插件 3：报表汇总（独立 exe + .lfm）

  只读汇总：区域收入/成本/毛利。数据与计算都在插件进程内，
  宿主不知道报表结构，只把 /p/reports/ 代理进来。
}
{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls,
  lwform, lwapp;

type
  TReportsForm = class(TLWForm)
    lblTitle: TLabel;
    lblSub: TLabel;
    pnlRevenue: TPanel;
    lblRevenueCap: TLabel;
    lblRevenueValue: TLabel;
    pnlCost: TPanel;
    lblCostCap: TLabel;
    lblCostValue: TLabel;
    pnlProfit: TPanel;
    lblProfitCap: TLabel;
    lblProfitValue: TLabel;
    btnReload: TButton;
    lblStatus: TLabel;
    memoRows: TMemo;
    procedure btnReloadClick(Sender: TObject);
  private
    FLoadCount: Integer;
    procedure Reload;
  public
    procedure AfterConstruction; override;
  end;

procedure RegisterModule;

implementation

{$R *.lfm}

const
  ROW_COUNT = 4;
  ROW_NAME: array[0..ROW_COUNT - 1] of string =
    ('华东', '华南', '华北', '西部');
  ROW_REVENUE: array[0..ROW_COUNT - 1] of Integer =
    (128000, 96000, 74000, 42000);
  ROW_COST: array[0..ROW_COUNT - 1] of Integer =
    (82000, 61000, 52000, 31000);

function SumRevenue: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to ROW_COUNT - 1 do
    Result := Result + ROW_REVENUE[i];
end;

function SumCost: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to ROW_COUNT - 1 do
    Result := Result + ROW_COST[i];
end;

function Money(AValue: Integer): string;
begin
  Result := FormatFloat('#,##0', AValue);
end;

procedure RegisterModule;
begin
  TLWApp.RegisterForm('Reports', TReportsForm);
end;

procedure TReportsForm.AfterConstruction;
begin
  inherited AfterConstruction;
  if csDesigning in ComponentState then Exit;
  FLoadCount := 0;
  Reload;
end;

procedure TReportsForm.btnReloadClick(Sender: TObject);
begin
  Reload;
end;

procedure TReportsForm.Reload;
var
  i, profit: Integer;
begin
  Inc(FLoadCount);
  lblRevenueValue.Caption := Money(SumRevenue);
  lblCostValue.Caption := Money(SumCost);
  lblProfitValue.Caption := Money(SumRevenue - SumCost);

  memoRows.Lines.BeginUpdate;
  try
    memoRows.Lines.Clear;
    memoRows.Lines.Add('区域      收入          成本          毛利');
    memoRows.Lines.Add('----------------------------------------------');
    for i := 0 to ROW_COUNT - 1 do
    begin
      profit := ROW_REVENUE[i] - ROW_COST[i];
      memoRows.Lines.Add(Format('%-8s %10s %13s %13s',
        [ROW_NAME[i], Money(ROW_REVENUE[i]), Money(ROW_COST[i]), Money(profit)]));
    end;
    memoRows.Lines.Add('----------------------------------------------');
    memoRows.Lines.Add(Format('%-8s %10s %13s %13s',
      ['合计', Money(SumRevenue), Money(SumCost), Money(SumRevenue - SumCost)]));
  finally
    memoRows.Lines.EndUpdate;
  end;

  lblStatus.Caption := '第 ' + IntToStr(FLoadCount) + ' 次汇总';
end;

end.
