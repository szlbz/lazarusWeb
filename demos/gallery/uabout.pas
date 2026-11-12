{ lazarusWeb :: uAbout —— 模态二级窗体演示
  从画廊的"对话框"页用 ShowModal 打开：浏览器端弹出模态窗口，
  关闭后 ModalResult 回传给主窗体。 }
unit uAbout;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, lwform;

type
  TAboutForm = class(TLWForm)
    lblTitle: TLabel;
    lblBody: TLabel;
    btnClose: TButton;
    procedure FormCreate(Sender: TObject);
  end;

implementation

{$R *.lfm}

procedure TAboutForm.FormCreate(Sender: TObject);
begin
  lblBody.Caption :=
    '纯 Pascal 服务端 + 真实 LCL 控件 + Ext JS 前端。' + LineEnding +
    '这个窗体是真实的 TLWForm（.lfm 加载），' + LineEnding +
    '通过 ShowModal 在浏览器里以模态窗口显示。';
end;

end.
