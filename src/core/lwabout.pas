{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwabout
  ------------------------------------------------------------------
  服务端控制面板的「关于」小窗。单独一个单元，只因为一个 unit 只能有
  一个 lfm 资源，放在 lwpanel 里会跟主面板抢资源名。

  不能改用 ShowMessage/MessageDlg：LWInstallDialogs 已把它们改道到
  浏览器会话，服务端自己弹不出来。
}
unit lwabout;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, StdCtrls, Controls;

type
  TLWAboutForm = class(TForm)
    lbInfo: TLabel;
    btnOk: TButton;
  public
    { 文本在调用方拼（版本号 + 监听地址都是运行时的） }
    class procedure ShowAbout(AOwner: TComponent; const AText: string);
  end;

implementation

{$R *.lfm}

class procedure TLWAboutForm.ShowAbout(AOwner: TComponent; const AText: string);
var
  f: TLWAboutForm;
begin
  f := TLWAboutForm.Create(AOwner);
  try
    f.lbInfo.Caption := AText;
    f.ShowModal;
  finally
    f.Free;
  end;
end;

end.
