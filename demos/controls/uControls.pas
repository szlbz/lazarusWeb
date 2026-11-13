{
  lazarusWeb :: uControls
  ------------------------------------------------------------------
  普通容器类/列表类控件全家桶（不带数据库）：

    TRadioGroup       单选组（val 语义 = 第几项）
    TCheckGroup       复选组（checked 数组 + OnItemClick 两参事件）
    TCheckListBox     带复选框的列表（checked 数组 + OnClickCheck）
    TValueListEditor  键值对编辑器（OnValidate 五参事件）

  控件字段和事件方法都声明在 published 段 —— lfm 只认 published。
  所有事件都写进 lblLog，测试脚本靠读它断言"服务端业务代码真的跑了"。
}
unit uControls;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, CheckLst, ValEdit, lwform;

type

  { TControlsForm }

  TControlsForm = class(TLWForm)
    rgColor: TRadioGroup;
    cgLang: TCheckGroup;
    clbTodo: TCheckListBox;
    vleInfo: TValueListEditor;
    lblLog: TLabel;
    procedure FormCreate(Sender: TObject);
    procedure rgColorClick(Sender: TObject);
    procedure cgLangItemClick(Sender: TObject; Index: Integer);
    procedure clbTodoClickCheck(Sender: TObject);
    procedure clbTodoClick(Sender: TObject);
    procedure vleInfoValidate(Sender: TObject; ACol, ARow: Longint;
      const KeyName, KeyValue: string);
  end;

implementation

{$R *.lfm}

procedure TControlsForm.FormCreate(Sender: TObject);
begin
  lblLog.Caption := '（等待事件）';
end;

procedure TControlsForm.rgColorClick(Sender: TObject);
begin
  lblLog.Caption := Format('radiogroup: %s（第 %d 项）',
    [rgColor.Items[rgColor.ItemIndex], rgColor.ItemIndex]);
end;

procedure TControlsForm.cgLangItemClick(Sender: TObject; Index: Integer);
begin
  lblLog.Caption := Format('checkgroup: 第 %d 项 = %s',
    [Index, BoolToStr(cgLang.Checked[Index], True)]);
end;

procedure TControlsForm.clbTodoClickCheck(Sender: TObject);
begin
  lblLog.Caption := Format('checklistbox: 勾选变化，第 %d 项 = %s',
    [clbTodo.ItemIndex, BoolToStr(clbTodo.Checked[clbTodo.ItemIndex], True)]);
end;

procedure TControlsForm.clbTodoClick(Sender: TObject);
begin
  lblLog.Caption := Format('checklistbox: 选中第 %d 项 %s',
    [clbTodo.ItemIndex, clbTodo.Items[clbTodo.ItemIndex]]);
end;

procedure TControlsForm.vleInfoValidate(Sender: TObject; ACol, ARow: Longint;
  const KeyName, KeyValue: string);
begin
  lblLog.Caption := Format('valeditor: %s = %s', [KeyName, KeyValue]);
end;

end.
