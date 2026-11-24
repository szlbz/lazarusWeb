program pluginsdemo;
{ pluginsDemo :: 宿主（主程序 exe）

  宿主不链接任何插件单元。插件是三个独立 exe，各自监听自己的端口：
    dashplug.exe     8881
    notesplug.exe    8882
    reportsplug.exe  8883
  宿主启动时扫描 ../*\*.plugin.ini，注册 /p/<名>/ 路由并拉起插件进程。
}
{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, upluginproc, upluginauth, ulogin, umain;

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb 插件工作台（主程序 exe + 插件 exe）';
  RegisterMain;
  { 用户权限（两道门，别混）：
      1) 登录窗体：新会话先显示登录页，认证通过才建主窗体。账号 / 角色映射
         在 common\upluginauth.pas（admin / analyst / guest）；
      2) 路由鉴权：把 LWAuthGuard 挂到 lwroute 上，之后所有 /p/<名>/ 请求
         先按会话角色判定，没权限直接 403，不会代理到插件进程。
    只做 1 的话，菜单藏起来但手敲 URL 照样能进 —— 2 才是真正的强制点。 }
  TLWApp.SetLogin(TLoginForm);
  LWAuthRegister;
  { 发现 -> 注册路由 -> 拉起进程，必须在 Run 之前完成 }
  PlugDiscover;
  PlugRegisterRoutes;
  PlugLaunchAll;
  TLWApp.Run;
end.
