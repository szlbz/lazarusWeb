unit uGrid;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, Grids,
  ComCtrls, ExtCtrls, lwform;

type
  TGridForm = class(TLWForm)
    pnlTop: TPanel;
    lblHint: TLabel;
    edtFilter: TEdit;
    btnLoad: TButton;
    btnClear: TButton;
    sgData: TStringGrid;
    stbMain: TStatusBar;
    procedure FormCreate(Sender: TObject);
    procedure btnLoadClick(Sender: TObject);
    procedure btnClearClick(Sender: TObject);
    procedure sgDataClick(Sender: TObject);
  private
    procedure FillGrid(const AFilter: string);
  public
  end;

var
  GridForm: TGridForm;

implementation

{$R *.lfm}

procedure TGridForm.FormCreate(Sender: TObject);
begin
  sgData.ColWidths[0] := 60;
  sgData.ColWidths[1] := 220;
  sgData.ColWidths[2] := 120;
  sgData.Cells[0, 0] := '编号';
  sgData.Cells[1, 0] := '名称';
  sgData.Cells[2, 0] := '数量';
end;

procedure TGridForm.FillGrid(const AFilter: string);
var
  i, r: Integer;
  nm: string;
begin
  sgData.RowCount := 1;
  r := 1;
  for i := 1 to 30 do
  begin
    nm := '物料-' + IntToStr(i);
    if (AFilter <> '') and (Pos(UpperCase(AFilter), UpperCase(nm)) = 0) then
      Continue;
    sgData.RowCount := r + 1;
    sgData.Cells[0, r] := IntToStr(1000 + i);
    sgData.Cells[1, r] := nm;
    sgData.Cells[2, r] := IntToStr(i * 7);
    Inc(r);
  end;
  stbMain.Panels[0].Text := Format('共 %d 行', [sgData.RowCount - 1]);
end;

procedure TGridForm.btnLoadClick(Sender: TObject);
begin
  FillGrid(Trim(edtFilter.Text));
end;

procedure TGridForm.btnClearClick(Sender: TObject);
begin
  sgData.RowCount := 1;
  stbMain.Panels[0].Text := '已清空';
end;

procedure TGridForm.sgDataClick(Sender: TObject);
begin
  if sgData.Row >= sgData.FixedRows then
    stbMain.Panels[1].Text := Format('当前行: %s  %s',
      [sgData.Cells[0, sgData.Row], sgData.Cells[1, sgData.Row]]);
end;

end.
