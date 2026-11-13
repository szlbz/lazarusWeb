{
  lazarusWeb :: 登录演示 —— 主窗体（认证通过后才有）
  ------------------------------------------------------------------
  窗体布局在 uMain.lfm（和普通 Lazarus 工程一样，设计器可直接改），
  这里只留逻辑：
    - 会话级"当前用户"显示（认证时由 OnLogin 事件写进全局变量，按
      演示简化处理 —— 真实项目建议按 sid 存在服务端会话表里）；
    - "退出登录"：Authenticated := False -> 隐藏主窗体 -> 重新显示
      登录窗体，下一轮序列化浏览器里就只剩登录窗口。
}
unit uMain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, lwform, lwbase;

type
  TMainForm = class(TLWForm)
    lblTitle: TLabel;
    lblUser: TLabel;
    btnToast: TButton;
    btnLogout: TButton;
    procedure FormCreate(Sender: TObject);
    procedure DoToast(Sender: TObject);
    procedure DoLogout(Sender: TObject);
  end;

var
  { 演示用的会话用户名（TryLogin 成功时记录）。真实项目请按 sid 存表 }
  GLoginUser: string = '';

implementation

{$R *.lfm}

procedure TMainForm.FormCreate(Sender: TObject);
begin
  lblUser.Caption := '当前用户：' + GLoginUser;
end;

procedure TMainForm.DoToast(Sender: TObject);
begin
  ShowToast('这是主窗体的 Toast 提示', '提示');
end;

procedure TMainForm.DoLogout(Sender: TObject);
var
  S: TLWSessionBase;
begin
  S := LWCurrentSession;
  if S = nil then Exit;
  S.Authenticated := False;
  GLoginUser := '';
  { 先把登录窗体重新显示出来，再隐藏主窗体：
    下一轮序列化浏览器里就只剩登录窗口 }
  if S.LoginForm <> nil then
    S.SessionShowForm(S.LoginForm);
  Self.Hide;
end;

end.
