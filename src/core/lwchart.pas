{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwchart
  ------------------------------------------------------------------
  TLWChart —— 图表控件（对应 uniGUI 的 uniChart / uniChartSeries），
  浏览器端用 ext-7.5.1 自带 charts 包渲染（Ext.chart.CartesianChart /
  Ext.chart.PolarChart，服务端零第三方依赖）。

  用法：
    chart.ChartType  := ctLine;   // ctLine / ctBar / ctPie
    chart.Title      := '月度销量';
    chart.Categories := ['一月','二月',...];            // X 轴标签（饼图 = 扇区名）
    chart.Series.Add.Name   := '销量';
    chart.Series[0].Values  := ['12','19','15',...];     // 逐点数值（按行）
    chart.Series[1].Values  := ...

  语义：
    line/bar —— 每个系列一条线/一组柱；Categories 是 X 轴；
    pie      —— 只取第一个系列的数值，Categories 是扇区标签。

  运行时改 ChartType / Categories / Series 后，任意一次事件协调
  （或 SessionPushCommand 推树）都会把新数据带下去，前端按内容
  指纹增量重建图表（不刷新页面）。

  charts 包由服务端按「ext 目录里有没有 charts.js」决定是否注入
  （不按版本号判断），目录里没有时图表控件会渲染成"缺少 charts 包"
  的占位框。
}
unit lwchart;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, ExtCtrls;

type
  TLWChartType = (ctLine, ctBar, ctPie);

  { 一个数据系列：Name 显示名（图例），Values 每行一个数值点 }
  TLWSeriesItem = class(TCollectionItem)
  private
    FName: string;
    FValues: TStrings;
    procedure SetValues(AValue: TStrings);
  public
    constructor Create(ACollection: TCollection); override;
    destructor Destroy; override;
    procedure Assign(Source: TPersistent); override;
  published
    property Name: string read FName write FName;
    property Values: TStrings read FValues write SetValues;
  end;

  TLWSeriesCollection = class(TOwnedCollection)
  protected
    function GetItem(AIndex: Integer): TLWSeriesItem;
    procedure SetItem(AIndex: Integer; AValue: TLWSeriesItem);
  public
    function Add: TLWSeriesItem;
    { 让 Series[0] 这种下标写法可用（demo/业务代码常用）}
    property Items[AIndex: Integer]: TLWSeriesItem
      read GetItem write SetItem; default;
  end;

  TLWChart = class(TCustomPanel)
  private
    FChartType: TLWChartType;
    FTitle: string;
    FCategories: TStrings;
    FSeries: TLWSeriesCollection;
    procedure SetCategories(AValue: TStrings);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  published
    property ChartType: TLWChartType read FChartType write FChartType default ctLine;
    property Title: string read FTitle write FTitle;
    property Categories: TStrings read FCategories write SetCategories;
    property Series: TLWSeriesCollection read FSeries write FSeries;
    property Align;
    property Anchors;
    property BevelOuter;
    property BorderStyle;
    property Color;
    property Constraints;
    property Enabled;
    property Font;
    property ParentColor;
    property ParentFont;
    property ShowHint;
    property TabOrder;
    property TabStop;
    property Visible;
    property OnClick;
    property OnResize;
  end;

implementation

{ ---------------- TLWSeriesItem ---------------- }

constructor TLWSeriesItem.Create(ACollection: TCollection);
begin
  inherited Create(ACollection);
  FValues := TStringList.Create;
end;

destructor TLWSeriesItem.Destroy;
begin
  FValues.Free;
  inherited Destroy;
end;

procedure TLWSeriesItem.Assign(Source: TPersistent);
begin
  if Source is TLWSeriesItem then
  begin
    FName := TLWSeriesItem(Source).Name;
    FValues.Assign(TLWSeriesItem(Source).Values);
  end
  else
    inherited Assign(Source);
end;

procedure TLWSeriesItem.SetValues(AValue: TStrings);
begin
  FValues.Assign(AValue);
end;

{ ---------------- TLWSeriesCollection ---------------- }

function TLWSeriesCollection.GetItem(AIndex: Integer): TLWSeriesItem;
begin
  Result := TLWSeriesItem(inherited GetItem(AIndex));
end;

procedure TLWSeriesCollection.SetItem(AIndex: Integer; AValue: TLWSeriesItem);
begin
  inherited SetItem(AIndex, AValue);
end;

function TLWSeriesCollection.Add: TLWSeriesItem;
begin
  Result := TLWSeriesItem(inherited Add);
end;
{ ---------------- TLWChart ---------------- }

constructor TLWChart.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Caption := '';
  Width := 480;
  Height := 300;
  FChartType := ctLine;
  FCategories := TStringList.Create;
  FSeries := TLWSeriesCollection.Create(Self, TLWSeriesItem);
end;

destructor TLWChart.Destroy;
begin
  FSeries.Free;
  FCategories.Free;
  inherited Destroy;
end;

procedure TLWChart.SetCategories(AValue: TStrings);
begin
  FCategories.Assign(AValue);
end;

initialization
  { lfm 里的自定义控件按类名实例化（GetClass），必须有运行时注册 }
  RegisterClass(TLWChart);
  RegisterClass(TLWSeriesItem);

end.
