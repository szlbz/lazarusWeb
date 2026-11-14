{
  lazarusWeb :: 登录演示 —— TLWLoginForm（IDE 新建 -> TLWLoginForm）
  ------------------------------------------------------------------
  演示框架的登录/权限能力，对应 uniGUI 的 TUniLoginForm：

    - 登录窗体是【lfm 设计期窗体】（uLogin.lfm），证明可以像桌面
      程序一样在 IDE 里"新建 -> 基类换 TLWLoginForm -> 拖控件"：
      两个 TEdit（edUser / edPass）+ 登录按钮（OnClick = DoLogin，
      DoLogin 是 TLWLoginForm 的 published 方法，lfm 直接引用）；
    - TLoginForm 只写认证逻辑：OnLogin 事件里核对账号密码；
    - 认证通过后框架自动创建主窗体（uMain.TMainForm）；
    - 主窗体上"退出登录"回到登录窗体（会话重新要求认证）。

  跑起来：logindemo.exe --port=8130  ->  浏览器 admin / 123456
          验证码点图即可换一张；账号或密码错、验证码错都会自动换新图。
}
unit uLogin;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, lwform, lwlogin, lwcaptcha;

type
  { 登录窗体：lfm 在 uLogin.lfm，业务代码只挂认证回调。
    控件字段必须声明在类头部（published 区）—— LCL 的 lfm 读取器
    会按名字回填字段，这和 Lazarus IDE 自动生成的写法一致 }
  TLoginForm = class(TLWLoginForm)
    lblTitle: TLabel;
    lblUser: TLabel;
    lblPass: TLabel;
    lblCode: TLabel;
    edUser: TEdit;
    edPass: TEdit;
    edCode: TEdit;
    captcha1: TLWCaptcha;
    btnOk: TButton;
    btnReset: TButton;
  published
    procedure FormCreate(Sender: TObject);
    procedure DoLoginEx(Sender: TObject; const AUser, APass: string;
      var AOk: Boolean; var AErr: string);
  end;

implementation

uses
  uMain;

{$R *.lfm}

procedure TLoginForm.FormCreate(Sender: TObject);
begin
  OnLogin := @DoLoginEx;
end;

procedure TLoginForm.DoLoginEx(Sender: TObject; const AUser, APass: string;
  var AOk: Boolean; var AErr: string);
begin
  { 演示认证：固定账号。真实项目在这里查数据库 / LDAP / 权限表，
    并把用户信息存到服务端会话级变量（按 sid 索引）}
  AOk := (AUser = 'admin') and (APass = '123456');
  if AOk then
    GLoginUser := AUser
  else
    AErr := '用户名或密码错误（演示账号：admin / 123456）';
end;

end.
