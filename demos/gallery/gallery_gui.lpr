program gallery;

{$mode objfpc}{$H+}

{ lazarusWeb :: 全功能画廊 demo（对照 uniGUI mdemo 的组织方式）
  运行：gallery.exe --port=8116   浏览器打开 http://127.0.0.1:8116/ }

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, lwapp, uGallery, uAbout;

{$R *.res}

begin
  Application.Scaled:=True;
  Application.Initialize;
  Application.Title := 'lazarusWeb · 全功能画廊';
  TLWApp.Register(TGalleryForm);
  TLWApp.RegisterForm('About', TAboutForm);
  TLWApp.Run;
end.
