{
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
  Classes, SysUtils, fpjson, StdCtrls, Controls, Forms, lwbase, lwform;

type
  { 认证回调：AOk/AErr 都是 var 参数，业务代码决定放不放行、错误说什么 }
  TLWLoginEvent = procedure(Sender: TObject; const AUser, APass: string;
    var AOk: Boolean; var AErr: string) of object;

  TLWLoginForm = class(TLWForm)
  private
    FOnLogin: TLWLoginEvent;
    FLoginUserEdit: TEdit;   { 显式指定用户名框；nil 时按约定自动找 }
    FLoginPassEdit: TEdit;   { 显式指定密码框 }
    function GetUserEdit: TEdit;
    function GetPassEdit: TEdit;
  protected
    procedure PushToast(const ATitle, AText: string);
  public
    { 提交一次登录：读两个编辑框 -> 触发 OnLogin（或演示缺省）->
      成功则换出主窗体、失败推 Toast }
    procedure TryLogin;
    property UserEdit: TEdit read GetUserEdit;
    property PassEdit: TEdit read GetPassEdit;
    { 想绕过约定命名时手动指定（FormCreate 里赋值即可）}
    property LoginUserEdit: TEdit read FLoginUserEdit write FLoginUserEdit;
    property LoginPassEdit: TEdit read FLoginPassEdit write FLoginPassEdit;
  published
    property OnLogin: TLWLoginEvent read FOnLogin write FOnLogin;
    { 供 lfm 的 OnClick 直接引用（published 方法 lfm 才能流式引用）}
    procedure DoLogin(Sender: TObject);
    { 重置按钮：清空两个编辑框 }
    procedure DoReset(Sender: TObject);
  end;

implementation

uses
  lwapp;

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
  u, p, err: string;
  ok: Boolean;
  main: TCustomForm;
begin
  u := '';
  p := '';
  if GetUserEdit <> nil then u := GetUserEdit.Text;
  if GetPassEdit <> nil then p := GetPassEdit.Text;

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
    PushToast('登录失败', err);
end;

procedure TLWLoginForm.DoLogin(Sender: TObject);
begin
  TryLogin;
end;

procedure TLWLoginForm.DoReset(Sender: TObject);
begin
  if GetUserEdit <> nil then GetUserEdit.Text := '';
  if GetPassEdit <> nil then GetPassEdit.Text := '';
end;

initialization
  { lfm 根类 / 子类实例化需要运行时类注册 }
  RegisterClass(TLWLoginForm);

end.
