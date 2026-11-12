unit uAbout;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, lwform;

type
  TAboutForm = class(TLWForm)
    lblTitle: TLabel;
    lblText: TLabel;
    lblVer: TLabel;
    btnOk: TButton;
    btnCancel: TButton;
  private
  public
  end;

var
  AboutForm: TAboutForm;

implementation

{$R *.lfm}

end.
