{ lazarusWeb :: 对话框演示

  这里的每个按钮调用的都是"原生 LCL 对话框函数"：
      ShowMessage / MessageDlg / InputQuery / QuestionDlg
      Application.MessageBox / TOpenDialog.Execute / TSaveDialog.Execute

  它们内部会走到 LCL 的函数指针（InterfaceBase.PromptDialogFunction 等）
  和 widgetset 的 TWSCommonDialog.ShowModal，框架（lwdlg 单元）把这些入口
  换成了"推给浏览器 -> 挂起服务端线程 -> 等用户答复"。

  也就是说：业务代码一行都不用改，ShowMessage 弹的就是浏览器里的窗口。 }
unit uDialogs;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, LCLType, lwform;

type
  TDlgForm = class(TLWForm)
    lblTitle: TLabel;
    lblHint: TLabel;
    btnMsg: TButton;
    btnConfirm: TButton;
    btnInput: TButton;
    btnQuestion: TButton;
    btnMsgBox: TButton;
    btnOpen: TButton;
    btnSave: TButton;
    mmoLog: TMemo;
    OpenDialog1: TOpenDialog;
    SaveDialog1: TSaveDialog;
    procedure FormCreate(Sender: TObject);
    procedure btnMsgClick(Sender: TObject);
    procedure btnConfirmClick(Sender: TObject);
    procedure btnInputClick(Sender: TObject);
    procedure btnQuestionClick(Sender: TObject);
    procedure btnMsgBoxClick(Sender: TObject);
    procedure btnOpenClick(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
  private
    procedure Log(const S: string);
  public
  end;

var
  DlgForm: TDlgForm;

implementation

{$R *.lfm}

procedure TDlgForm.Log(const S: string);
begin
  mmoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
  { 只保留最近 200 行，免得日志无限增长 }
  while mmoLog.Lines.Count > 200 do
    mmoLog.Lines.Delete(0);
end;

procedure TDlgForm.FormCreate(Sender: TObject);
begin
  Log('窗体已创建。下面的按钮都会在浏览器里弹出真正的模态框 ——');
  Log('服务端线程此刻会挂起等待，和本地程序里的 ShowMessage 完全一样。');
end;

procedure TDlgForm.btnMsgClick(Sender: TObject);
begin
  Log('调用 ShowMessage，等待浏览器点确定…');
  ShowMessage('这是一条来自服务端的消息。' + LineEnding +
    '服务端线程正挂在这里等你点确定。');
  Log('ShowMessage 返回（用户已关闭）');
end;

procedure TDlgForm.btnConfirmClick(Sender: TObject);
var
  r: TModalResult;
begin
  Log('调用 MessageDlg(mtConfirmation, [mbYes, mbNo])…');
  r := MessageDlg('确定要删除这条记录吗？', mtConfirmation, [mbYes, mbNo], 0);
  case r of
    mrYes: Log('MessageDlg 返回 mrYes（用户选了"是"）');
    mrNo:  Log('MessageDlg 返回 mrNo（用户选了"否"）');
  else
    Log('MessageDlg 返回 ' + IntToStr(Ord(r)) + '（超时或已关闭）');
  end;
end;

procedure TDlgForm.btnInputClick(Sender: TObject);
var
  s: string;
begin
  s := '未命名';
  Log('调用 InputQuery，等待用户输入…');
  if InputQuery('重命名', '请输入新的名称：', s) then
  begin
    if Trim(s) = '' then
      Log('InputQuery 返回 True，但输入为空')
    else
      Log('InputQuery 返回 True，用户输入：' + s);
  end
  else
    Log('InputQuery 返回 False（用户取消）');
end;

procedure TDlgForm.btnQuestionClick(Sender: TObject);
var
  r: TModalResult;
begin
  Log('调用 QuestionDlg（自定义按钮文字）…');
  r := QuestionDlg('选择操作', '要保存刚才的修改吗？', mtConfirmation,
    [mrYes, '保存', mrNo, '放弃', mrCancel, '返回'], 0);
  case r of
    mrYes: Log('QuestionDlg 返回 mrYes（保存）');
    mrNo:  Log('QuestionDlg 返回 mrNo（放弃）');
  else
    Log('QuestionDlg 返回 ' + IntToStr(Ord(r)) + '（返回/关闭）');
  end;
end;

procedure TDlgForm.btnMsgBoxClick(Sender: TObject);
var
  r: Integer;
begin
  Log('调用 Application.MessageBox(MB_ICONWARNING or MB_YESNO)…');
  r := Application.MessageBox('磁盘空间不足，是否继续？', '警告',
    MB_ICONWARNING or MB_YESNO);
  case r of
    IDYES: Log('MessageBox 返回 IDYES');
    IDNO:  Log('MessageBox 返回 IDNO');
  else
    Log('MessageBox 返回 ' + IntToStr(r));
  end;
end;

procedure TDlgForm.btnOpenClick(Sender: TObject);
begin
  Log('调用 OpenDialog1.Execute（浏览器选文件 -> 上传到服务端）…');
  if OpenDialog1.Execute then
    Log('已选择文件，服务端路径：' + OpenDialog1.FileName)
  else
    Log('OpenDialog1.Execute 返回 False（取消）');
end;

procedure TDlgForm.btnSaveClick(Sender: TObject);
begin
  Log('调用 SaveDialog1.Execute（只输入文件名，落盘位置由服务端决定）…');
  if SaveDialog1.Execute then
    Log('保存目标：' + SaveDialog1.FileName)
  else
    Log('SaveDialog1.Execute 返回 False（取消）');
end;

end.
