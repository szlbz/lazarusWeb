unit uform_notes;
{ pluginsDemo 插件 2：便签（独立 exe + .lfm）

  业务全部在插件进程内完成。数据落盘到 exe 同目录的 notesplug.notes.txt，
  所以宿主热更新（重启本进程）之后，已保存的便签仍然存在 —— 这是热更新
  演示里最直观的一项：代码换了、进程重启了，业务数据没丢。
}
{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls,
  lwform, lwapp;

type
  TNotesForm = class(TLWForm)
    lblTitle: TLabel;
    lblSub: TLabel;
    lblTitleCap: TLabel;
    edTitle: TEdit;
    lblTextCap: TLabel;
    memoText: TMemo;
    btnSave: TButton;
    btnClear: TButton;
    lblStatus: TLabel;
    lblListCap: TLabel;
    lstNotes: TListBox;
    procedure btnSaveClick(Sender: TObject);
    procedure btnClearClick(Sender: TObject);
  private
    procedure SyncList;
  public
    procedure AfterConstruction; override;
  end;

procedure RegisterModule;

implementation

{$R *.lfm}

const
  NOTES_FILE = 'notesplug.notes.txt';

var
  GNotes: TStringList = nil;

function DataFile: string;
begin
  Result := IncludeTrailingPathDelimiter(
    ExtractFileDir(ExpandFileName(ParamStr(0)))) + NOTES_FILE;
end;

procedure LoadNotes;
begin
  if GNotes = nil then GNotes := TStringList.Create;
  GNotes.Clear;
  if FileExists(DataFile) then
  try
    GNotes.LoadFromFile(DataFile);
  except
    on E: Exception do
      GNotes.Clear;
  end;
end;

procedure SaveNotes;
begin
  if GNotes = nil then Exit;
  try
    GNotes.SaveToFile(DataFile);
  except
    { 落盘失败不影响界面业务，演示里只忽略 }
  end;
end;

procedure RegisterModule;
begin
  TLWApp.RegisterForm('Notes', TNotesForm);
end;

procedure TNotesForm.AfterConstruction;
begin
  inherited AfterConstruction;
  if csDesigning in ComponentState then Exit;
  LoadNotes;
  SyncList;
  lblStatus.Caption := '等待操作（已载入 ' + IntToStr(GNotes.Count) + ' 条）';
  edTitle.Text := '';
  memoText.Lines.Clear;
end;

procedure TNotesForm.SyncList;
var
  i: Integer;
begin
  lstNotes.Items.BeginUpdate;
  try
    lstNotes.Items.Clear;
    for i := 0 to GNotes.Count - 1 do
      lstNotes.Items.Add(Format('%d. %s', [i + 1, GNotes[i]]));
  finally
    lstNotes.Items.EndUpdate;
  end;
end;

procedure TNotesForm.btnSaveClick(Sender: TObject);
var
  t: string;
begin
  t := Trim(edTitle.Text);
  if t = '' then
  begin
    lblStatus.Caption := '标题不能为空';
    Exit;
  end;
  GNotes.Add(t);
  SaveNotes;
  SyncList;
  lblStatus.Caption := '已保存「' + t + '」，共 ' + IntToStr(GNotes.Count) + ' 条';
  edTitle.Text := '';
  memoText.Lines.Clear;
end;

procedure TNotesForm.btnClearClick(Sender: TObject);
begin
  edTitle.Text := '';
  memoText.Lines.Clear;
  lblStatus.Caption := '已清空输入（列表保留）';
end;

end.
