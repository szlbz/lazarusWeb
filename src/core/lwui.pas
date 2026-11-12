{
  lazarusWeb :: lwui
  ------------------------------------------------------------------
  几个"边缘但常用"的界面件（对应 uniGUI 的同类控件）：

    TLWGauge        仪表盘（服务端给值，浏览器画 SVG 指针盘）
    TLWColorPicker  取色器（色块 + Ext.picker.Color）
    LWShowScreenMask / LWHideScreenMask
                    会话级遮罩（对应 uniScreenMask）：挡住整个页面，
                    防止用户在长操作期间乱点

  共同点：都只依赖组件树，不需要第三方 JS 包。

  用法：
      g := TLWGauge.Create(Self);
      g.Parent := tsChart; g.SetBounds(12, 470, 240, 140);
      g.Caption := '本月完成率'; g.Value := 72; g.Max := 100; g.UnitText := '%';

      cp := TLWColorPicker.Create(Self);
      cp.Parent := tsChart; cp.SetBounds(620, 450, 80, 28);
      cp.Color := clRed;
      cp.OnColorChange := @ColorChanged;

      LWShowScreenMask('正在生成报表…');   // 任意事件里调用
      LWHideScreenMask;
}
unit lwui;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, ExtCtrls, Graphics, lwbase;

type
  { 仪表盘：Value 落在 [Min, Max]，浏览器端画半圆刻度盘 + 指针。
    Caption 是盘上方的标题；UnitText 跟在数值后面（'%'、'件'…）。 }
  TLWGauge = class(TCustomPanel)
  private
    FValue: Double;
    FMin: Double;
    FMax: Double;
    FUnitText: string;
    FWarnAt: Double;
    FDangerAt: Double;
    procedure SetValue(AValue: Double);
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Value: Double read FValue write SetValue;
    property Min: Double read FMin write FMin;
    property Max: Double read FMax write FMax;
    property UnitText: string read FUnitText write FUnitText;
    { 占比阈值（0..1）：超过就变黄 / 变红；0 = 不启用 }
    property WarnAt: Double read FWarnAt write FWarnAt;
    property DangerAt: Double read FDangerAt write FDangerAt;
    property Caption;
    property Align;
    property Color;
    property Parent;
  end;

  { 取色器：显示当前颜色的色块，点开调色板，选完触发 OnColorChange。
    颜色就存在继承来的 Color 属性里（png 上也方便）。 }
  TLWColorPicker = class(TCustomPanel)
  private
    FOnColorChange: TNotifyEvent;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Color;
    property OnColorChange: TNotifyEvent read FOnColorChange write FOnColorChange;
    property Align;
    property Parent;
  end;

{ 会话级遮罩：挡住整页并显示一段文字（空字符串 = 只转圈）。
  只在有浏览器会话时有效；桌面调试时静默忽略。 }
procedure LWShowScreenMask(const AText: string = '');
procedure LWHideScreenMask;

implementation

uses
  fpjson;

{ ---------------- TLWGauge ---------------- }

constructor TLWGauge.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 220;
  Height := 140;
  FMin := 0;
  FMax := 100;
  FValue := 0;
  FWarnAt := 0;
  FDangerAt := 0;
  FUnitText := '';
  BevelOuter := bvNone;
end;

procedure TLWGauge.SetValue(AValue: Double);
begin
  if AValue < FMin then AValue := FMin;
  if (FMax > FMin) and (AValue > FMax) then AValue := FMax;
  if FValue = AValue then Exit;
  FValue := AValue;
end;

{ ---------------- TLWColorPicker ---------------- }

constructor TLWColorPicker.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 90;
  Height := 28;
  Caption := '';
  BevelOuter := bvNone;
  Color := clWhite;
end;

{ ---------------- 会话级遮罩 ---------------- }

procedure LWShowScreenMask(const AText: string);
var
  S: TLWSessionBase;
  cmd: TJSONObject;
begin
  S := LWCurrentSession;
  if S = nil then Exit;
  cmd := TJSONObject.Create;
  try
    cmd.Add('type', 'mask');
    cmd.Add('show', True);
    cmd.Add('text', AText);
    S.SessionPushCommand(cmd.AsJSON);
  finally
    cmd.Free;
  end;
end;

procedure LWHideScreenMask;
var
  S: TLWSessionBase;
  cmd: TJSONObject;
begin
  S := LWCurrentSession;
  if S = nil then Exit;
  cmd := TJSONObject.Create;
  try
    cmd.Add('type', 'mask');
    cmd.Add('show', False);
    S.SessionPushCommand(cmd.AsJSON);
  finally
    cmd.Free;
  end;
end;

end.
