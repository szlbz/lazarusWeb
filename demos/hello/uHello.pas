unit uHello;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, lwform;

type
  THelloForm = class(TLWForm)
    lblTitle: TLabel;
    lblName: TLabel;
    edtName: TEdit;
    btnSay: TButton;
    lblResult: TLabel;
    mmoLog: TMemo;
    chkUpper: TCheckBox;
    cboCity: TComboBox;
    procedure FormCreate(Sender: TObject);
    procedure btnSayClick(Sender: TObject);
    procedure chkUpperChange(Sender: TObject);
  private
    FCount: Integer;
  public
  end;

var
  HelloForm: THelloForm;

implementation

{$R *.lfm}

procedure THelloForm.FormCreate(Sender: TObject);
begin
  FCount := 0;
  mmoLog.Lines.Add('窗体已在服务端创建：这是一个真实的 LCL 窗体。');
  mmoLog.Lines.Add('浏览器里看到的每个控件，服务端都有一个对应对象。');
end;

procedure THelloForm.btnSayClick(Sender: TObject);
var
  s: string;
begin
  Inc(FCount);
  s := Trim(edtName.Text);
  if s = '' then
    s := '陌生人';
  if chkUpper.Checked then
    s := UpperCase(s);
  if cboCity.ItemIndex >= 0 then
    s := s + ' @ ' + cboCity.Text;
  lblResult.Caption := '你好，' + s + '！第 ' + IntToStr(FCount) + ' 次点击';
  mmoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + ' 服务端处理 -> ' + lblResult.Caption);
end;

procedure THelloForm.chkUpperChange(Sender: TObject);
begin
  mmoLog.Lines.Add('复选框状态变化: ' + BoolToStr(chkUpper.Checked, True));
end;

end.
