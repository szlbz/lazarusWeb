{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwlogin
  ------------------------------------------------------------------
  登录/权限框架 —— TLWLoginForm，对应 uniGUI 的 TUniLoginForm。

  用法（IDE 新建 -> TLWLoginForm 与桌面新建窗体几乎一样）：

    1. 在 Lazarus 里新建一个窗体，把基类从 TForm 换成 TLWLoginForm
       （或直接手写 lfm：object LoginForm: TLoginForm ... 根类声明为
       TLoginForm = class(TLWLoginForm)）；
    2. 窗体上放两个 TEdit（约定名 edUser / edPass；不按约定命名时
       框架自动取"第一个 TEdit"当用户名、"带 PasswordChar 的 TEdit"
       当密码框），一个 TButton（Caption=登录，OnClick = DoLogin ——
       DoLogin 是基类的 published 方法，lfm 里可以直接引用）；
    3. 子类挂 OnLogin 事件：
         procedure TLoginForm.DoLoginEx(Sender: TObject; const AUser,
           APass: string; var AOk: Boolean; var AErr: string);
         begin
           AOk := (AUser = 'admin') and (APass = '123456');
           if not AOk then AErr := '用户名或密码错误';
         end;
    4. lpr 里：
         TLWApp.SetLogin(TLoginForm);   // 自动注册 + 启用登录
         TLWApp.Register(TMainForm);
         TLWApp.Run;

  流程：
    新会话创建时，lwhttp 用登录窗体替代默认主窗体（RequireAuth=True）；
    认证成功 -> Session.Authenticated := True -> 隐藏登录窗、
    TLWApp.CreateForm 创建默认主窗体并推给浏览器；认证失败 -> 推一条
    Toast 错误提示。未认证会话在 lwdispatch 里只允许操作登录窗体上的
    控件（其它 id 一律拒绝），防止未登录者触发业务事件。

  未挂 OnLogin 时的演示缺省：admin / admin。
}
unit lwlogin;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, StdCtrls, Controls, Forms, lwbase, lwform, lwcaptcha;

type
  { 认证回调：AOk/AErr 都是 var 参数，业务代码决定放不放行、错误说什么 }
  TLWLoginEvent = procedure(Sender: TObject; const AUser, APass: string;
    var AOk: Boolean; var AErr: string) of object;

  TLWLoginForm = class(TLWForm)
  private
    FOnLogin: TLWLoginEvent;
    FLoginUserEdit: TEdit;   { 显式指定用户名框；nil 时按约定自动找 }
    FLoginPassEdit: TEdit;   { 显式指定密码框 }
    FLoginCodeEdit: TEdit;   { 显式指定验证码输入框 }
    FRequireCaptcha: Boolean;
    FAutoBuildUI: Boolean;
    function GetUserEdit: TEdit;
    function GetPassEdit: TEdit;
    function GetCodeEdit: TEdit;
    function GetCaptcha: TLWCaptcha;
    { 空白登录窗体（IDE 里"新建 -> TLWLoginForm"出来的那种）自动摆一套
      账号/密码/验证码/按钮，保证"新建即可用"。cf. AutoBuildUI }
    procedure BuildDefaultUI;
  protected
    procedure PushToast(const ATitle, AText: string);
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    { lfm 已在构造期读入、OnCreate 也已触发（TCustomForm.AfterConstruction
      里调 DoCreate），所以到这里还一个控件都没有 = 空窗体，才补建 }
    procedure AfterConstruction; override;
    { 提交一次登录：验证码 -> 读两个编辑框 -> 触发 OnLogin（或演示缺省）->
      成功则换出主窗体、失败推 Toast }
    procedure TryLogin;
    { 换一张验证码（作废旧答案）；frontend 的 img 会跟着重拉 }
    procedure RefreshCaptcha;
    property UserEdit: TEdit read GetUserEdit;
    property PassEdit: TEdit read GetPassEdit;
    { 验证码输入框（约定名 edCode / 名字含 code / 除账号密码外的第一个编辑框）}
    property CodeEdit: TEdit read GetCodeEdit;
    { 窗体上的图形验证码控件；没有则返回 nil（此时不校验验证码）}
    property Captcha: TLWCaptcha read GetCaptcha;
    { 想绕过约定命名时手动指定（FormCreate 里赋值即可）}
    property LoginUserEdit: TEdit read FLoginUserEdit write FLoginUserEdit;
    property LoginPassEdit: TEdit read FLoginPassEdit write FLoginPassEdit;
    property LoginCodeEdit: TEdit read FLoginCodeEdit write FLoginCodeEdit;
    { 空窗体自动补建界面（默认 True）。窗体上已经有控件（lfm 设计的、
      或 FormCreate 里自己建的）时本属性不起作用 —— 它只在"一个控件
      都没有"时兜底。不想用就在 FormCreate 里置 False }
    property AutoBuildUI: Boolean read FAutoBuildUI write FAutoBuildUI default True;
  published
    { 是否校验图形验证码（默认 True）。窗体上没有 TLWCaptcha 时自动跳过 ——
      老工程不受影响，拖一个控件上去就生效 }
    property RequireCaptcha: Boolean read FRequireCaptcha write FRequireCaptcha default True;
    property OnLogin: TLWLoginEvent read FOnLogin write FOnLogin;
    { 供 lfm 的 OnClick 直接引用（published 方法 lfm 才能流式引用）}
    procedure DoLogin(Sender: TObject);
    { 重置按钮：清空两个编辑框 }
    procedure DoReset(Sender: TObject);
  end;

implementation

uses
  lwapp;

constructor TLWLoginForm.CreateNew(AOwner: TComponent; Num: Integer);
begin
  inherited CreateNew(AOwner, Num);
  { published 的 default True 只是流式标记，字段本身要在这里初始化 }
  FRequireCaptcha := True;
  FAutoBuildUI := True;
end;

{ 自动补建：只有"设计期一个控件都没放"的登录窗体才走这里。
  这样 IDE 里"新建 -> TLWLoginForm"（或 SetLogin(TLWLoginForm) 直接用基类）
  新建出来的窗体，跑起来就是一整套可用的登录界面 —— 包括图形验证码。
  有 lfm / FormCreate 自己摆过控件的窗体一律不动（ControlCount > 0）。

  注意顺序：本方法由 AfterConstruction 调用，那时 TCustomForm 已经
  调过 DoCreate（OnCreate 早于这里），所以拿到的 ControlCount 是
  "用户最终摆完"的数量，不会误判。 }
procedure TLWLoginForm.BuildDefaultUI;

  function AddLabel(const AName, ACaption: string;
    L, T, W, H: Integer): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Name := AName;      { 先 Name 后 Caption：SetName 会回填文本 }
    Result.Parent := Self;
    Result.SetBounds(L, T, W, H);
    Result.Caption := ACaption;
  end;

  function AddEdit(const AName: string; L, T, W, H: Integer): TEdit;
  begin
    Result := TEdit.Create(Self);
    Result.Name := AName;
    Result.Parent := Self;
    Result.SetBounds(L, T, W, H);
    { Name 设完再压一次 Text：lfm 之外也有同样的"名字被填进 Text"问题 }
    Result.Text := '';
  end;

  function AddButton(const AName, ACaption: string; L, T, W, H: Integer;
    AHandler: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Name := AName;
    Result.Parent := Self;
    Result.SetBounds(L, T, W, H);
    Result.Caption := ACaption;
    Result.OnClick := AHandler;
  end;

var
  cap: TLWCaptcha;
  ed: TEdit;
begin
  { 空窗体往往是 LCL 默认尺寸（240x180）—— 装不下一整套登录控件 }
  if Width < 390 then Width := 390;
  if Height < 270 then Height := 270;
  Caption := '登录';
  { 这个名字有两个用处：TLWForm.SetVisible 用 Name<>'' 判断"这是网页窗体"
    （空名字时 Hide 不生效，登录后登录窗关不掉）；浏览器端也用它做窗体标识 }
  if Name = '' then Name := 'LoginForm';

  AddLabel('lblTitle', '登录（演示账号 admin / admin）', 24, 18, 340, 18);
  AddLabel('lblUser', '用户名', 24, 62, 60, 18);
  AddEdit('edUser', 110, 58, 250, 26);
  AddLabel('lblPass', '密 码', 24, 102, 60, 18);
  ed := AddEdit('edPass', 110, 98, 250, 26);
  ed.PasswordChar := '*';

  { 图形验证码：控件 + 输入框成对出现，基类的 TryLogin 会自动认出它们
    （约定名 edCode），不需要业务代码接线 }
  AddLabel('lblCode', '验证码', 24, 142, 60, 18);
  cap := TLWCaptcha.Create(Self);
  cap.Name := 'captcha1';
  cap.Parent := Self;
  cap.SetBounds(110, 136, 110, 34);
  AddEdit('edCode', 230, 140, 130, 26);

  AddButton('btnOk', '登 录', 110, 196, 110, 30, @DoLogin);
  AddButton('btnReset', '重 置', 250, 196, 110, 30, @DoReset);
end;

procedure TLWLoginForm.AfterConstruction;
begin
  { 调用 inherited 会走到 TCustomForm.AfterConstruction：那里 DoCreate
    触发 OnCreate —— 必须先让它跑完，再看控件数量 }
  inherited AfterConstruction;
  if csDesigning in ComponentState then Exit;
  if not FAutoBuildUI then Exit;
  if ControlCount > 0 then Exit;
  BuildDefaultUI;
end;

function TLWLoginForm.GetUserEdit: TEdit;
var
  i: Integer;
begin
  if FLoginUserEdit <> nil then Exit(FLoginUserEdit);
  { 约定名优先，其次是"窗体上第一个 TEdit" }
  Result := TEdit(FindComponent('edUser'));
  if Result <> nil then Exit;
  for i := 0 to ControlCount - 1 do
    if Controls[i] is TEdit then
      Exit(TEdit(Controls[i]));
  Result := nil;
end;

function TLWLoginForm.GetPassEdit: TEdit;
var
  i: Integer;
  first: TEdit;
begin
  if FLoginPassEdit <> nil then Exit(FLoginPassEdit);
  Result := TEdit(FindComponent('edPass'));
  if Result <> nil then Exit;
  { 没有约定名：带 PasswordChar 的算密码框；否则取第二个 TEdit }
  first := nil;
  for i := 0 to ControlCount - 1 do
    if Controls[i] is TEdit then
    begin
      if TEdit(Controls[i]).PasswordChar <> #0 then
        Exit(TEdit(Controls[i]));
      if first = nil then first := TEdit(Controls[i]);
    end;
  if (first <> nil) and (first <> GetUserEdit) then
    Result := first
  else if first <> GetUserEdit then
    Result := first
  else
    Result := nil;
end;

{ 验证码控件：窗体上第一个 TLWCaptcha。TGraphicControl 也是窗体 Controls 的
  成员，所以直接遍历即可（不依赖 .lfm 里的控件名）。 }
function TLWLoginForm.GetCaptcha: TLWCaptcha;
var
  i: Integer;
begin
  for i := 0 to ControlCount - 1 do
    if Controls[i] is TLWCaptcha then
      Exit(TLWCaptcha(Controls[i]));
  Result := nil;
end;

{ 验证码输入框：约定名 edCode 优先；其次"名字里带 code 的编辑框"；
  最后退化成"除用户名框、密码框之外的第一个 TEdit"（登录窗体上通常就三个）}
function TLWLoginForm.GetCodeEdit: TEdit;
var
  i: Integer;
  e: TEdit;
begin
  if FLoginCodeEdit <> nil then Exit(FLoginCodeEdit);
  Result := TEdit(FindComponent('edCode'));
  if Result <> nil then Exit;
  for i := 0 to ControlCount - 1 do
    if Controls[i] is TEdit then
    begin
      e := TEdit(Controls[i]);
      if (Pos('code', LowerCase(e.Name)) > 0) or
         (Pos('captcha', LowerCase(e.Name)) > 0) or
         (Pos('vcode', LowerCase(e.Name)) > 0) then
        Exit(e);
    end;
  Result := nil;
  for i := 0 to ControlCount - 1 do
    if (Controls[i] is TEdit) and (Controls[i] <> GetUserEdit) and
       (Controls[i] <> GetPassEdit) then
      Exit(TEdit(Controls[i]));
end;

procedure TLWLoginForm.RefreshCaptcha;
var
  cap: TLWCaptcha;
begin
  cap := GetCaptcha;
  if cap <> nil then cap.Refresh;
  if GetCodeEdit <> nil then GetCodeEdit.Text := '';
end;

procedure TLWLoginForm.PushToast(const ATitle, AText: string);
var
  S: TLWSessionBase;
  cmd: TJSONObject;
begin
  S := LWCurrentSession;
  if S = nil then Exit;
  cmd := TJSONObject.Create;
  try
    cmd.Add('type', 'toast');
    cmd.Add('title', ATitle);
    cmd.Add('text', AText);
    S.SessionPushCommand(cmd.AsJSON);
  finally
    cmd.Free;
  end;
end;

procedure TLWLoginForm.TryLogin;
var
  S: TLWSessionBase;
  u, p, err, code: string;
  ok: Boolean;
  main: TCustomForm;
  cap: TLWCaptcha;
begin
  u := '';
  p := '';
  if GetUserEdit <> nil then u := GetUserEdit.Text;
  if GetPassEdit <> nil then p := GetPassEdit.Text;

  { 1. 先验码，再验账号密码 —— 顺序不能反：先查账号就等于给暴力枚举
     开了后门（验证码的意义正是让"猜密码"必须一张图一次）。
     RequireCaptcha 默认开，但窗体上没有 TLWCaptcha 时自动跳过，
     老工程/向导模板不受影响。 }
  if FRequireCaptcha then
  begin
    cap := GetCaptcha;
    if cap <> nil then
    begin
      code := '';
      if GetCodeEdit <> nil then code := GetCodeEdit.Text;
      if not LWCaptchaCheck(cap.Token, code) then
      begin
        { 一枚码只试一次：失败立即换图并清空输入框，
          用户不必手动点图，也不可能拿同一张图反复试 }
        RefreshCaptcha;
        PushToast('登录失败', '验证码错误，已换一张，请重新输入');
        Exit;
      end;
      { 校验通过后把输入框清掉：这张图已作废，留着旧码只会误导用户 }
      if GetCodeEdit <> nil then GetCodeEdit.Text := '';
    end;
  end;

  ok := False;
  err := '';
  if Assigned(FOnLogin) then
    FOnLogin(Self, u, p, ok, err)
  else
  begin
    { 未挂事件：演示缺省账号 }
    ok := (u = 'admin') and (p = 'admin');
    if not ok then
      err := '用户名或密码错误（演示账号 admin / admin）';
  end;

  S := LWCurrentSession;
  if ok then
  begin
    if S <> nil then S.Authenticated := True;
    { 隐藏登录窗（浏览器端销毁窗口），创建并显示默认主窗体 }
    Self.Hide;
    if S <> nil then
    begin
      { 先看会话里是不是已经有这个主窗体：
        注销后重新登录时复用同一个实例，避免每轮多建一个窗体 }
      main := S.SessionFindForm(TLWApp.DefaultFormName);
      if main = nil then
      begin
        if not TLWApp.CreateForm(TLWApp.DefaultFormName, main) then
          main := nil;
      end;
      if main <> nil then
        S.SessionShowForm(main)
      else
        PushToast('登录失败', '默认主窗体未注册（TLWApp.Register）');
    end;
  end
  else
  begin
    { 验证码在校验阶段就已经消费掉了，账号密码错也必须换一张新图，
      否则浏览器停在旧图上，用户再提交一次必然报"验证码错误" }
    RefreshCaptcha;
    PushToast('登录失败', err);
  end;
end;

procedure TLWLoginForm.DoLogin(Sender: TObject);
begin
  TryLogin;
end;

procedure TLWLoginForm.DoReset(Sender: TObject);
begin
  if GetUserEdit <> nil then GetUserEdit.Text := '';
  if GetPassEdit <> nil then GetPassEdit.Text := '';
  RefreshCaptcha;
end;

initialization
  { lfm 根类 / 子类实例化需要运行时类注册 }
  RegisterClass(TLWLoginForm);

end.
