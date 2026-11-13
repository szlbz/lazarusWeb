unit uAudit;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls,
  ComCtrls, Buttons, MaskEdit, EditBtn;

type
  TAuditForm = class(TForm)
    lblA1: TLabel;
    lblA2: TLabel;
    bvlBox: TBevel;
    bvlRaised: TBevel;
    imgEmpty: TImage;
    ledName: TLabeledEdit;
    fneFile: TFileNameEdit;
    tbcTabs: TTabControl;
    trbV: TTrackBar;
    trbH: TTrackBar;
    prgV: TProgressBar;
    medPhone: TMaskEdit;
    chkGray: TCheckBox;
    tgbA: TToggleBox;
    lbMulti: TListBox;
    spbA: TSpeedButton;
    spbB: TSpeedButton;
    stx1: TStaticText;
    pgcBottom: TPageControl;
    tsOne: TTabSheet;
    tsTwo: TTabSheet;
    lblP1: TLabel;
    lblP2: TLabel;
    shpEllipse: TShape;
    shpRoundRect: TShape;
    splMain: TSplitter;
  end;

implementation

{$R *.lfm}

end.
