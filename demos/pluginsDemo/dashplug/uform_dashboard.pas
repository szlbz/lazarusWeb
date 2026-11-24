unit uform_dashboard;
{ pluginsDemo 插件 1：仪表盘（独立 exe + .lfm）

  这是插件进程自己的完整页面：只注册 Dashboard 窗体，不包含宿主、也不包含
  其他插件。宿主用 /p/dash/ 反向代理到本进程，浏览器里看到的就是这一页。
}
{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls, ExtCtrls,
  lwform, lwapp;

type
  TDashboardForm = class(TLWForm)
    lblTitle: TLabel;
    lblSub: TLabel;
    pnlModule: TPanel;
    lblModuleCap: TLabel;
    lblModuleValue: TLabel;
    pnlHits: TPanel;
    lblHitsCap: TLabel;
    lblHitsValue: TLabel;
    pnlUptime: TPanel;
    lblUptimeCap: TLabel;
    lblUptimeValue: TLabel;
    barHealth: TProgressBar;
    btnRefresh: TButton;
    lblStatus: TLabel;
    memoLog: TMemo;
    procedure btnRefreshClick(Sender: TObject);
  private
    FStartTick: QWord;
    FRefreshCount: Integer;
    procedure RefreshStats;
  public
    procedure AfterConstruction; override;
  end;

procedure RegisterModule;

implementation

{$R *.lfm}

procedure RegisterModule;
begin
  TLWApp.RegisterForm('Dashboard', TDashboardForm);
end;

procedure TDashboardForm.AfterConstruction;
begin
  inherited AfterConstruction;
  if csDesigning in ComponentState then Exit;
  FStartTick := GetTickCount64;
  FRefreshCount := 0;
  RefreshStats;
end;

procedure TDashboardForm.btnRefreshClick(Sender: TObject);
begin
  RefreshStats;
end;

procedure TDashboardForm.RefreshStats;
var
  secs: QWord;
begin
  Inc(FRefreshCount);
  secs := (GetTickCount64 - FStartTick) div 1000;
  lblModuleValue.Caption := 'DashboardForm';
  lblHitsValue.Caption := IntToStr(FRefreshCount);
  lblUptimeValue.Caption := IntToStr(secs) + ' 秒';
  barHealth.Position := (FRefreshCount * 7) mod 101;
  lblStatus.Caption := '第 ' + IntToStr(FRefreshCount) + ' 次刷新';
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) +
    '  刷新：本插件进程已运行 ' + IntToStr(secs) + ' 秒');
end;

end.
