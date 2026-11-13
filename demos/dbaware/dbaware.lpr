program dbaware;

{$mode objfpc}{$H+}
{ 是否带控制台窗口由编译选项决定：
  - nogui 构建（dbaware.lpi 默认模式）→ console 子系统，大黑终端，tests/CI 用
  - GUI 构建（dbaware_gui.lpi，-WG）→ GUI 子系统，无终端，显示服务端面板 }

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uLogin, uAwareMain, uReport, uAjax;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb · 综合演示（登录 + 多窗体 + 打印导出）';
  TLWApp.SetLogin(TLoginForm);     { 每个新会话先过登录窗体 }
  TLWApp.Register(TAwareForm);     { 默认主窗体：认证通过后创建 }
  RegisterDemoAjax;                { 自定义 AJAX 端点（/lw/ajax/*）}
  TLWApp.Run;                      { nogui: 阻塞 accept；GUI: 面板 + 消息循环 }
end.
