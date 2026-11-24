unit ulogin;
{ pluginsDemo :: 登录窗体（用户权限的第一道门）

  基类 TLWLoginForm 已经把「空白登录窗自动摆一套界面 + 图形验证码 + 提交
  校验 + 认证通过后换出主窗体」全做完了，这里只做三件事：

    1. 挂 OnLogin：交给 upluginauth.LWAuthLogin 校验口令，成功后把
       「登录名 / 角色串」写进会话变量（后续菜单过滤和 /p/ 鉴权都读它）；
    2. 改文案：标题写演示账号与口令。口令引用 LWAuthDemoPass 常量而不是
       再抄一遍字面量 —— 之前把口令写死在文案里，账号表换了之后忘了同步，
       照着窗体上的提示输反而登不进去（这种错只有真人去点才会发现）；
    3. 验证码保持开启，只给自动化留一个显式开关（--no-captcha 或
       LW_LOGIN_NO_CAPTCHA=1）。普通启动永远是开着的，不会因为
       「忘了接事件」而静默失效。
}
{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Graphics, lwbase, lwform,
  lwlogin, lwrlog, upluginauth;

type
  TLoginForm = class(TLWLoginForm)
  private
    procedure DoAuth(Sender: TObject; const AUser, APass: string;
      var AOk: Boolean; var AErr: string);
    procedure ApplyCaptchaMode;
    procedure AddCaptchaHint;
  public
    procedure AfterConstruction; override;
  end;

{ 是否显式关闭验证码。只认两种开关：
    宿主命令行  --no-captcha
    环境变量    LW_LOGIN_NO_CAPTCHA=1 / true / yes
  默认（双击、普通命令行启动）返回 False，即验证码开启。 }
function LoginCaptchaDisabled: Boolean;

implementation

function LoginCaptchaDisabled: Boolean;
var
  s: string;
begin
  if Application.HasOption('no-captcha') then
    Exit(True);
  { Windows 单元里也有个同名 3 参版本的 GetEnvironmentVariable，会盖掉
    SysUtils 的 1 参版本，所以这里写全限定名 }
  s := SysUtils.GetEnvironmentVariable('LW_LOGIN_NO_CAPTCHA');
  Result := (s = '1') or SameText(s, 'true') or SameText(s, 'yes');
end;

{ AutoBuildUI 在 AfterConstruction 里跑（此时 lfm/OnCreate 都已结束），
  所以改文案、补提示必须在 inherited 之后做 }
procedure TLoginForm.AfterConstruction;
var
  c: TComponent;
begin
  inherited AfterConstruction;
  Caption := '插件工作台 · 登录';

  c := FindComponent('lblTitle');
  if c is TLabel then
    TLabel(c).Caption := '演示账号 admin / analyst / guest，口令 ' + LWAuthDemoPass;

  ApplyCaptchaMode;
  if not LoginCaptchaDisabled then
    AddCaptchaHint;

  OnLogin := @DoAuth;
end;

{ 自动界面的坐标：标题 y=18、用户名 y=62，中间那条空隙只有 20px 上下 ——
  提示放进去会和"用户名"行挤在一起（实测会压到输入框上沿），所以放到
  按钮下面的留白处当脚注，用灰色小字，不抢视线。
  内容上仍要说明"图能点"，否则没人会想到点它换一张（基类只在失败时自动换） }
procedure TLoginForm.AddCaptchaHint;
var
  l: TLabel;
begin
  l := TLabel.Create(Self);
  { 先 Name 后 Caption：SetName 会把名字回填到文本上 }
  l.Name := 'lblCaptchaHint';
  l.Parent := Self;
  l.SetBounds(24, 238, 340, 16);
  l.Caption := '验证码不区分大小写，看不清可点图片换一张';
  l.Font.Color := clGray;
end;

procedure TLoginForm.ApplyCaptchaMode;
var
  c: TComponent;
begin
  if not LoginCaptchaDisabled then
  begin
    { 基类初值就是 True，这里显式写一次：表明验证码是「有意开着」的，
      将来基类改默认值时不会悄悄把这道门弄丢 }
    RequireCaptcha := True;
    LWLogFmt('[pluginsDemo] 登录验证码：开启', []);
    Exit;
  end;

  { 关的时候是三重开关，少一个都进不去：
    1) RequireCaptcha=False 才是"不校验"；
    2) 藏掉输入框 —— 否则用户以为必须填；
    3) 藏掉图片本身。
    只做 2、3 而不做 1 的话，基类仍会拿空输入去比对，永远提示"验证码错误" }
  RequireCaptcha := False;
  LWLogFmt('[pluginsDemo] 登录验证码：关闭（--no-captcha / LW_LOGIN_NO_CAPTCHA）', []);
  c := FindComponent('lblCode');
  if c is TControl then TControl(c).Visible := False;
  c := FindComponent('captcha1');
  if c is TControl then TControl(c).Visible := False;
  c := FindComponent('edCode');
  if c is TControl then TControl(c).Visible := False;
end;

procedure TLoginForm.DoAuth(Sender: TObject; const AUser, APass: string;
  var AOk: Boolean; var AErr: string);
var
  roles, disp: string;
begin
  AOk := LWAuthLogin(AUser, APass, roles, disp, AErr);
  if not AOk then
  begin
    { 错误提示里带点线索，省得演示时反复试密码 }
    if AErr = '' then
      AErr := '用户名或密码错误';
    Exit;
  end;
  { 写会话变量：菜单过滤（LWAuthSessionRoles）和 /p/ 鉴权（LWAuthRolesForSid）
    都从这里取。写全局变量会把 A 用户的身份带给同一进程里的 B 用户 }
  LWAuthSessionSet(Trim(AUser), roles);
  LWLogFmt('[pluginsDemo] 登录成功 user=%s roles=%s', [Trim(AUser), roles]);
end;

end.
