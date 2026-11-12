{
  lazarusWeb :: lwdbnav
  ------------------------------------------------------------------
  让 TDBNavigator 在 nogui widgetset 下可用（对应 uniGUI 的 uniDBNavigator）。

  问题：LCL 的 TDBCustomNavigator.UpdateButtons 会给每个 TDBNavButton
  挂上 LCLGlyphs（内置 PNG 字形），而 PNG -> TBitmap -> RawImage 这条链
  在 nogui 下拿不到 RawImageDescription，构造时直接
  FPImageException("Failed to get raw image description from bitmap")
  —— 窗体都建不出来。

  方案：TLWDBNavigator 覆盖 UpdateButtons（LCL 里是 virtual），按钮照建
  （DataChanged/EditingChanged 靠它们维护 Enabled，BtnClick 也走它们），
  只是跳过 LCLGlyphs 的两行赋值 —— 浏览器端自己画图标，服务端不需要位图。

  lfm 兼容：**lfm 里要写 "object navMain: TLWDBNavigator"**。

  为什么不能靠 RegisterClassAlias 把子类伪装成 'TDBNavigator'：
  TDBNavigator 是 LCL（DBGrids 单元）已经注册过的类名，而 FPC 的 GetClass
  取"最后注册的那个"，谁后初始化不可控（实测初始化顺序一变就退回基础类，
  加载时去读 glyph 位图 → Failed to get raw image description from bitmap）。
  所以这里用 RegisterClass(TLWDBNavigator)，lfm 直接用真实类名；
  工具（lwconvert）转换别人的 lfm 时，也要把 TDBNavigator 改成 TLWDBNavigator。

  代码建窗体：用 LWNewNavigator(AOwner) 工厂，返回类型就是原生
  TDBNavigator —— 用户代码只写 LCL 类型，不引用这个子类。
  writer / dispatch 也都按 TDBNavigator 判类型，子类只是实现细节。
}
unit lwdbnav;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, DB, DBCtrls;

type
  { 无 glyph 的 TDBNavigator：nogui 下可构造，浏览器端负责画按钮图标 }
  TLWDBNavigator = class(TDBNavigator)
  protected
    procedure UpdateButtons; override;
  public
    { 序列化用：某个导航按钮当前是否可用（LCL 的 DataLink 已经算好）}
    function BtnEnabled(Index: TDBNavButtonType): Boolean;
  end;

{ 代码建窗体时用这个工厂：返回类型是 LCL 原生 TDBNavigator，
  实例是 nogui 安全的 TLWDBNavigator（用户侧不必引用子类类型）。
  lfm 设计期拖 TDBNavigator 则靠 RegisterClassAlias 自动落到子类。 }
function LWNewNavigator(AOwner: TComponent): TDBNavigator;
{ 某个按钮当前是否可用：子类走 BtnEnabled 的精确判据；
  原生 TDBNavigator（nogui 下实际构造不出来）兜底全可用 }
function LWNavBtnEnabled(C: TDBNavigator; Index: TDBNavButtonType): Boolean;
{ 浏览器回传的按钮名 -> 按钮类型；非法名返回 False }
function LWNavBtnFromId(const AId: string; out ABtn: TDBNavButtonType): Boolean;
{ 按钮类型 -> 浏览器按钮名 }
function LWNavBtnToId(B: TDBNavButtonType): string;

implementation

const
  { 与 LCL 的 DBNavButtonResourceName 一一对应，但用小写短 id，
    浏览器端好认好传 }
  LWNavBtnIds: array[TDBNavButtonType] of string = (
    'first', 'prior', 'next', 'last',
    'insert', 'delete', 'edit', 'post', 'cancel', 'refresh');

function LWNewNavigator(AOwner: TComponent): TDBNavigator;
begin
  Result := TLWDBNavigator.Create(AOwner);
end;

function LWNavBtnEnabled(C: TDBNavigator; Index: TDBNavButtonType): Boolean;
begin
  if C is TLWDBNavigator then
    Result := TLWDBNavigator(C).BtnEnabled(Index)
  else
    { 原生 TDBNavigator 在 nogui 下构造即崩（LCLGlyphs 位图链），
      正常路径到不了这里；真到了就按"全部可用"处理，不至于空按钮条 }
    Result := True;
end;

function LWNavBtnFromId(const AId: string; out ABtn: TDBNavButtonType): Boolean;
var
  bt: TDBNavButtonType;
begin
  Result := False;
  for bt := Low(TDBNavButtonType) to High(TDBNavButtonType) do
    if LWNavBtnIds[bt] = AId then
    begin
      ABtn := bt;
      Exit(True);
    end;
end;

function LWNavBtnToId(B: TDBNavButtonType): string;
begin
  Result := LWNavBtnIds[B];
end;

procedure TLWDBNavigator.UpdateButtons;
var
  bt: TDBNavButtonType;
  CurButton: TDBNavButton;
  CurFocusableButton: TDBNavFocusableButton;
begin
  { 与 LCL 源码（dbcustomnavigator.inc 的 UpdateButtons）保持一致的骨架。
    两处差异：
    1. 不给按钮挂 LCLGlyphs / FImages —— nogui 下任何位图转 RawImage
       都会抛 FPImageException，这正是原版构造即崩的原因；
    2. 不碰 FUpdateButtonsLock / FUpdateButtonsNeeded（private，子类
       不可见）。LCL 的语义是"锁着就记账、解锁后重跑"，这里改成无条件
       立即重建：多几次冗余重建，但没有递归风险，也不会漏建。 }
  DisableAlign;
  try
    if Direction = nbdHorizontal then
      ChildSizing.Layout := cclLeftToRightThenTopToBottom
    else
      ChildSizing.Layout := cclTopToBottomThenLeftToRight;

    { 强制按预定义顺序重建 }
    for bt := Low(Buttons) to High(Buttons) do
    begin
      Buttons[bt].Free;
      Buttons[bt] := nil;
      FocusableButtons[bt].Free;
      FocusableButtons[bt] := nil;
    end;

    for bt := Low(Buttons) to High(Buttons) do
    begin
      CurButton := TDBNavButton.Create(Self);
      CurButton.Name := DBNavButtonResourceName[bt];
      Buttons[bt] := CurButton;
      if bt in [nbPrior, nbNext] then
        CurButton.NavStyle := CurButton.NavStyle + [nsAllowTimer];
      { 这里是关键改动：不设置 Images / ImageIndex ——
        nogui 下 LCLGlyphs.GetImageIndex 会走位图解码并抛异常 }
      CurButton.Flat := Flat;
      CurButton.Index := bt;
      CurButton.Visible := bt in VisibleButtons;
      CurButton.Parent := Self;
      CurButton.OnClick := @ButtonClickHandler;
      CurButton.ControlStyle := CurButton.ControlStyle + [csNoDesignSelectable];
    end;

    { 焦点可达版本：DataChanged/EditingChanged 无条件访问这个数组
      （见 LCL 的 DataChanged 里 FocusableButtons[nbFirst].Enabled := ...），
      必须一起建，否则开 navFocusableButtons 选项就是 AV }
    for bt := Low(Buttons) to High(Buttons) do
    begin
      CurFocusableButton := TDBNavFocusableButton.Create(Self);
      FocusableButtons[bt] := CurFocusableButton;
      if bt in [nbPrior, nbNext] then
        CurFocusableButton.NavStyle := CurFocusableButton.NavStyle + [nsAllowTimer];
      { 同上：跳过 glyph }
      CurFocusableButton.TabStop := True;
      CurFocusableButton.Index := bt;
      CurFocusableButton.Visible := bt in VisibleButtons;
      CurFocusableButton.OnClick := @ButtonClickHandler;
      CurFocusableButton.ControlStyle := CurFocusableButton.ControlStyle + [csNoDesignSelectable];
    end;
  finally
    EnableAlign;
  end;
  ActiveChanged;
end;

function TLWDBNavigator.BtnEnabled(Index: TDBNavButtonType): Boolean;
var
  ds: TDataSet;
begin
  { DataChanged/EditingChanged 会随数据集事件维护各按钮的 Enabled，
    大多数按钮直接读它们的值即可。
    但 first/prior/next/last 的 LCL 判据是 not BOF / not EOF，而 SQLdb
    系数据集的 BOF/EOF 在 RecNo 导航后不一定置位（实测停在第 1 条时
    BOF 仍为 False，"第一条"按钮不灰）。这类按钮改用 RecNo 兜底：
    RecNo 可靠（=1 就是第一条；=-1 表示数据集不支持，退回 BOF 判据）。 }
  Result := False;
  if not Enabled then Exit;
  ds := nil;
  if DataSource <> nil then ds := DataSource.DataSet;
  if (ds = nil) or not ds.Active then Exit;

  case Index of
    nbFirst, nbPrior:
      Result := (not ds.BOF) and (ds.RecNo <> 1);
    nbNext, nbLast:
      if ds.RecordCount > 0 then
        Result := (not ds.EOF) and (ds.RecNo < ds.RecordCount)
      else
        Result := not ds.EOF;
  else
    if Buttons[Index] <> nil then
      Result := Buttons[Index].Enabled;
  end;
end;

initialization
  { ① 用真实类名注册：LFM 里写 "object nav: TLWDBNavigator" 时，加载器
      按 GetClass 查表直接命中子类（TDBNavigator 是 LCL 里已注册的基类，
      同名别名根本轮不到，这点和 Delphi 的文档描述不同）。
     ② 别名保留：手写/转换过来的 LFM 若还写成 TDBNavigator，在某些
      查找路径（FindClass）下仍能落到子类。 }
  RegisterClass(TLWDBNavigator);
  RegisterClassAlias(TLWDBNavigator, 'TDBNavigator');

end.
