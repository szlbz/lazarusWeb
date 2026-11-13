program gallery;

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

{ lazarusWeb :: 全功能画廊 demo（对照 uniGUI mdemo 的组织方式）
  运行：gallery.exe --port=8116   浏览器打开 http://127.0.0.1:8116/ }

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uGallery, uAbout;

{$R *.res}

begin
  Application.Initialize;
  Application.Title := 'lazarusWeb · 全功能画廊';
  { 【不要再用 {$ifdef web} 包住这三句】nogui 工程的 lpi 从未定义
    web 宏，包住的结果就是：编译能过、程序启动即退出（Initialize 之后
    无事可做），现象是"执行就退出、没有任何输出"，极难从日志看出原因。
    dbaware.lpr / gallery_gui.lpr 都是直接调用，这里与它们保持一致。 }
  TLWApp.Register(TGalleryForm);
  TLWApp.RegisterForm('About', TAboutForm);
  TLWApp.Run;
end.
