{
  lazarusWeb :: lwdlg
  ------------------------------------------------------------------
  让 LCL 的"原生对话框"改道到浏览器。业务代码一个字都不用改：

      ShowMessage('保存成功');
      if MessageDlg('确实要删除吗？', mtConfirmation, [mbYes, mbNo], 0) = mrYes then ...
      if InputQuery('重命名', '新名称：', s) then ...
      if OpenDialog1.Execute then Memo1.Lines.Add(OpenDialog1.FileName);

  LCL 把这几类对话框都收敛到了几个全局函数指针（InterfaceBase 单元）：

      PromptDialogFunction    -> ShowMessage / ShowMessagePos / MessageDlg / MessageDlgPos
      InputDialogFunction     -> InputQuery / InputBox / PasswordBox
      QuestionDialogFunction  -> QuestionDlg（自定义按钮文字）
      Forms.MessageBoxFunction-> LCLIntf.MessageBox / Application.MessageBox（MB_* 标志）

  文件对话框走的是另一条路：TCustomFileDialog.Execute 会调用 widgetset 类
  TWSCommonDialog.ShowModal。nogui 下这个方法是空的（直接返回，Execute=False），
  我们注册自己的 WS 类把它替换掉，于是 TOpenDialog / TSaveDialog 也能用。
  浏览器的选择结果是"把文件传到服务端"，FileName 返回服务端的临时路径 ——
  与 uniGUI 的 FileUploadDialog 是同一个思路：浏览器碰不到服务端磁盘。

  安装入口是 LWInstallDialogs，只在 Web 服务程序里调用（TLWApp.Run 已经调用）。
  设计期/本地 GUI 程序不要调用，否则 IDE 自己的对话框也会跑到浏览器去。
}
unit lwdlg;

{$mode objfpc}{$H+}

interface

{ 把上面四类对话框 + 文件选择对话框接到浏览器（幂等，可重复调用）}
procedure LWInstallDialogs;

{ 当前线程是否在一个可用的浏览器会话里（没有就只能退回本地行为）}
function LWDialogAvailable: Boolean;

implementation

uses
  Classes, SysUtils, Forms, Controls, Dialogs, Buttons, Graphics,
  LCLType, InterfaceBase, WSLCLClasses, WSDialogs,
  fpjson, lwbase;

type
  TLWButtonSpec = record
    Id: Integer;
    Caption: string;
    IsDefault: Boolean;
  end;
  TLWButtonSpecs = array of TLWButtonSpec;

const
  { 对话框里的按钮 id 就用 LCL 自己的 idButton* 常量，
    这样 PromptDialog 的返回值不用再做一层映射 }
  LW_KIND_INFO     = 'info';
  LW_KIND_WARNING  = 'warning';
  LW_KIND_ERROR    = 'error';
  LW_KIND_QUESTION = 'question';
  LW_KIND_NONE     = 'none';
  LW_KIND_INPUT    = 'input';
  LW_KIND_OPEN     = 'openfile';
  LW_KIND_SAVE     = 'savefile';

  { 这一版 LCLType 里没有导出这几个掩码/常量，就地补上（值与 Win32 一致）}
  LW_MB_TYPEMASK = $0000000F;
  LW_MB_ICONMASK = $000000F0;
  LW_MB_DEFMASK  = $00000F00;
  LW_IDCONTINUE  = 11;

var
  GInstalled: Boolean = False;
  GOldPrompt: TPromptDialogFunction = nil;
  GOldInput: TInputDialogFunction = nil;
  GOldQuestion: TQuestionDialogFunction = nil;
  GOldMsgBox: TMessageBoxFunction = nil;

function LWDialogAvailable: Boolean;
begin
  Result := LWCurrentSession <> nil;
end;

{ 按钮文字统一取自 LCL（中文环境就是中文，英文环境就是英文），
  和本地模式下弹出的对话框保持一致 }
function ButtonCaptionOf(AId: Integer): string;
begin
  Result := GetButtonCaption(AId);
  if Result = '?' then
    { LCL 的按钮文案表里没有"继续"（MB_CANCELTRYCONTINUE 才会用到）}
    if AId = idButtonContinue then
      Result := 'Continue'
    else
      Result := IntToStr(AId);
end;

function MakeBtns(const AIds: array of Integer; ADefault: Integer): TLWButtonSpecs;
var
  i: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AIds));
  for i := 0 to High(AIds) do
  begin
    Result[i].Id := AIds[i];
    Result[i].Caption := ButtonCaptionOf(AIds[i]);
    Result[i].IsDefault := (AIds[i] = ADefault);
  end;
end;

{ 真正与服务端会话打交道的地方：拼 JSON，然后阻塞等浏览器 }
function AskBrowser(const AKind, ACaption, AText: string;
  const ABtns: TLWButtonSpecs; AEscape: Integer; const AInputJson: string;
  out AResult: Integer; out ATextOut: string): Boolean;
var
  S: TLWSessionBase;
  spec: TJSONObject;
  arr: TJSONArray;
  o: TJSONObject;
  i: Integer;
begin
  Result := False;
  AResult := AEscape;
  ATextOut := '';
  S := LWCurrentSession;
  if S = nil then Exit;

  spec := TJSONObject.Create;
  try
    spec.Add('kind', AKind);
    spec.Add('caption', ACaption);
    spec.Add('text', AText);
    spec.Add('escape', AEscape);
    arr := TJSONArray.Create;
    for i := 0 to High(ABtns) do
    begin
      o := TJSONObject.Create;
      o.Add('id', ABtns[i].Id);
      o.Add('text', ABtns[i].Caption);
      if ABtns[i].IsDefault then
        o.Add('default', True);
      arr.Add(o);
    end;
    spec.Add('buttons', arr);
    if AInputJson <> '' then
      spec.Add('input', GetJSON(AInputJson));
    Result := S.SessionDialog(spec.AsJSON, AResult, ATextOut);
  finally
    spec.Free;
  end;
end;

function KindOf(DialogType: Longint): string;
begin
  case DialogType of
    idDialogWarning: Result := LW_KIND_WARNING;
    idDialogError:   Result := LW_KIND_ERROR;
    idDialogInfo:    Result := LW_KIND_INFO;
    idDialogConfirm: Result := LW_KIND_QUESTION;
  else
    Result := LW_KIND_NONE;
  end;
end;

{ ---------------- 1. ShowMessage / MessageDlg ---------------- }

function LWPromptDialog(const DialogCaption, DialogMessage: String;
  DialogType: Longint; Buttons: PLongint; ButtonCount, DefaultIndex,
  EscapeResult: Longint; UseDefaultPos: Boolean; X, Y: Longint): Longint;
var
  ids: array of Integer;
  btns: TLWButtonSpecs;
  i, defId, res: Integer;
  txt: string;
begin
  if (not LWDialogAvailable) or (Buttons = nil) or (ButtonCount <= 0) then
  begin
    if GOldPrompt <> nil then
      Exit(GOldPrompt(DialogCaption, DialogMessage, DialogType, Buttons, ButtonCount,
        DefaultIndex, EscapeResult, UseDefaultPos, X, Y));
    Exit(EscapeResult);
  end;

  { Buttons 里装的是 idButton* 常量；DefaultIndex 是"第几个"，要先换成 id }
  SetLength(ids, ButtonCount);
  for i := 0 to ButtonCount - 1 do
    ids[i] := (Buttons + i)^;

  defId := EscapeResult;
  if (DefaultIndex >= 0) and (DefaultIndex < ButtonCount) then
    defId := ids[DefaultIndex];

  btns := MakeBtns(ids, defId);
  if not AskBrowser(KindOf(DialogType), DialogCaption, DialogMessage, btns,
    EscapeResult, '', res, txt) then
    Exit(EscapeResult);
  Result := res;
end;

{ ---------------- 2. InputQuery / InputBox / PasswordBox ---------------- }

function LWInputDialog(const InputCaption, InputPrompt: String; MaskInput: Boolean;
  var Value: String): Boolean;
var
  inp: TJSONObject;
  btns: TLWButtonSpecs;
  res: Integer;
  txt, spec: string;
begin
  if not LWDialogAvailable then
  begin
    if GOldInput <> nil then
      Exit(GOldInput(InputCaption, InputPrompt, MaskInput, Value));
    Exit(False);
  end;

  inp := TJSONObject.Create;
  try
    inp.Add('value', Value);
    inp.Add('mask', MaskInput);
    spec := inp.AsJSON;
  finally
    inp.Free;
  end;

  btns := MakeBtns([idButtonOk, idButtonCancel], idButtonOk);
  if not AskBrowser(LW_KIND_INPUT, InputCaption, InputPrompt, btns,
    idButtonCancel, spec, res, txt) then
    Exit(False);

  Value := txt;
  Result := (res = idButtonOk);
end;

{ ---------------- 3. QuestionDlg（自定义按钮文字） ---------------- }

function LWQuestionDialog(const aCaption, aMsg: string; DlgType: LongInt;
  Buttons: TDialogButtons; HelpCtx: Longint): LongInt;
var
  btns: TLWButtonSpecs;
  b: TDialogButton;
  i, defRes, escRes, res: Integer;
  txt: string;
begin
  if (not LWDialogAvailable) or (Buttons = nil) or (Buttons.Count = 0) then
  begin
    if GOldQuestion <> nil then
      Exit(GOldQuestion(aCaption, aMsg, DlgType, Buttons, HelpCtx));
    Exit(mrCancel);
  end;

  { 这里按钮的 id 直接就是 ModalResult（QuestionDlg 的返回值语义） }
  SetLength(btns, Buttons.Count);
  defRes := mrNone;
  escRes := mrCancel;
  for i := 0 to Buttons.Count - 1 do
  begin
    b := TDialogButton(Buttons.Items[i]);
    btns[i].Id := b.ModalResult;
    btns[i].Caption := b.Caption;
    btns[i].IsDefault := b.Default;
    if b.Default then defRes := b.ModalResult;
    if b.Cancel then escRes := b.ModalResult;
  end;

  if not AskBrowser(KindOf(DlgType), aCaption, aMsg, btns, escRes, '', res, txt) then
    Exit(escRes);
  Result := res;
  if Result = mrNone then
    Result := defRes;
end;

{ ---------------- 4. MessageBox（MB_* 标志） ---------------- }

function MsgBoxIconOf(AFlags: Longint): string;
begin
  { 注意别名：MB_ICONERROR = MB_ICONHAND = MB_ICONSTOP，
    MB_ICONWARNING = MB_ICONEXCLAMATION，MB_ICONINFORMATION = MB_ICONASTERISK，
    case 标签不能重复，所以每类只写一个 }
  case AFlags and LW_MB_ICONMASK of
    MB_ICONHAND:        Result := LW_KIND_ERROR;
    MB_ICONQUESTION:    Result := LW_KIND_QUESTION;
    MB_ICONEXCLAMATION: Result := LW_KIND_WARNING;
    MB_ICONASTERISK:    Result := LW_KIND_INFO;
  else
    Result := LW_KIND_NONE;
  end;
end;

{ MessageBox 的返回值（ID*）与 LCL 按钮 id 的对应 }
function MsgBoxResultOf(AButtonId: Integer): Integer;
begin
  case AButtonId of
    idButtonOk:       Result := IDOK;
    idButtonCancel:   Result := IDCANCEL;
    idButtonYes:      Result := IDYES;
    idButtonNo:       Result := IDNO;
    idButtonAbort:    Result := IDABORT;
    idButtonRetry:    Result := IDRETRY;
    idButtonIgnore:   Result := IDIGNORE;
    idButtonClose:    Result := IDCLOSE;
    idButtonContinue: Result := LW_IDCONTINUE;
  else
    Result := IDCANCEL;
  end;
end;

function LWMessageBox(Text, Caption: PChar; Flags: Longint): Integer;
var
  ids: array of Integer;
  btns: TLWButtonSpecs;
  n, defIdx, res: Integer;
  s, c, txt: string;
  IdsArr: array[0..2] of Integer;
begin
  if not LWDialogAvailable then
  begin
    if GOldMsgBox <> nil then
      Exit(GOldMsgBox(Text, Caption, Flags));
    Exit(IDCANCEL);
  end;

  { MB_TYPEMASK = 按钮组合 }
  n := 1;
  case Flags and LW_MB_TYPEMASK of
    MB_OKCANCEL:
      begin
        IdsArr[0] := idButtonOk; IdsArr[1] := idButtonCancel; n := 2;
      end;
    MB_ABORTRETRYIGNORE:
      begin
        IdsArr[0] := idButtonAbort; IdsArr[1] := idButtonRetry;
        IdsArr[2] := idButtonIgnore; n := 3;
      end;
    MB_YESNOCANCEL:
      begin
        IdsArr[0] := idButtonYes; IdsArr[1] := idButtonNo;
        IdsArr[2] := idButtonCancel; n := 3;
      end;
    MB_YESNO:
      begin
        IdsArr[0] := idButtonYes; IdsArr[1] := idButtonNo; n := 2;
      end;
    MB_RETRYCANCEL:
      begin
        IdsArr[0] := idButtonRetry; IdsArr[1] := idButtonCancel; n := 2;
      end;
    MB_CANCELTRYCONTINUE:
      begin
        IdsArr[0] := idButtonCancel; IdsArr[1] := idButtonRetry;
        IdsArr[2] := idButtonContinue; n := 3;
      end;
  else
    IdsArr[0] := idButtonOk; n := 1;
  end;

  SetLength(ids, n);
  for defIdx := 0 to n - 1 do
    ids[defIdx] := IdsArr[defIdx];

  { MB_DEFBUTTON1..4 是"第几个按钮"，越界就取第一个 }
  defIdx := 0;
  case Flags and LW_MB_DEFMASK of
    MB_DEFBUTTON2: defIdx := 1;
    MB_DEFBUTTON3: defIdx := 2;
    MB_DEFBUTTON4: defIdx := 3;
  end;
  if defIdx >= n then defIdx := 0;

  btns := MakeBtns(ids, ids[defIdx]);
  if Text = nil then s := '' else s := Text;
  if Caption = nil then c := '' else c := Caption;

  if not AskBrowser(MsgBoxIconOf(Flags), c, s, btns, idButtonCancel, '', res, txt) then
    Exit(IDCANCEL);
  Result := MsgBoxResultOf(res);
end;

{ ---------------- 5. TOpenDialog / TSaveDialog ---------------- }

{ 文件对话框：浏览器把选中的文件 POST 到 /lw/api/dlgfile，服务端存到临时目录，
  然后把"服务端路径"当作对话框答案送回来（多个文件用 #13#10 分隔）。 }
type
  TLWWSOpenDialog = class(TWSOpenDialog)
  public
    class function CreateHandle(const ACommonDialog: TCommonDialog): TLCLHandle; override;
    class procedure ShowModal(const ACommonDialog: TCommonDialog); override;
    class function QueryWSEventCapabilities(const ACommonDialog: TCommonDialog): TCDWSEventCapabilities; override;
    class procedure DestroyHandle(const ACommonDialog: TCommonDialog); override;
  end;

  TLWWSSaveDialog = class(TLWWSOpenDialog)
  public
    class procedure ShowModal(const ACommonDialog: TCommonDialog); override;
  end;

{ 只留基名：浏览器传回来的"文件名"可能带路径分隔符，不能直接拼进服务端路径 }
function SafeBaseName(const AName: string): string;
var
  s: string;
  i: Integer;
begin
  s := StringReplace(AName, '\', '/', [rfReplaceAll]);
  s := ExtractFileName(s);
  s := StringReplace(s, ':', '_', [rfReplaceAll]);
  for i := 1 to Length(s) do
    if s[i] in ['<', '>', '|', '"', '*', '?', #0..#31] then
      s[i] := '_';
  s := Trim(s);
  while (s <> '') and (s[1] = '.') do
    Delete(s, 1, 1);
  if s = '' then
    s := 'untitled.txt';
  Result := s;
end;

function AskFileDialog(const ACaption, AFilter, ADefaultName: string;
  ASave, AMulti: Boolean; out AResult: Integer; out APaths: string): Boolean;
var
  btns: TLWButtonSpecs;
  inp: TJSONObject;
  spec, kind: string;
begin
  Result := False;
  AResult := idButtonCancel;
  APaths := '';
  if not LWDialogAvailable then Exit;

  inp := TJSONObject.Create;
  try
    inp.Add('filter', AFilter);
    inp.Add('value', ADefaultName);
    inp.Add('multi', AMulti);
    inp.Add('save', ASave);
    spec := inp.AsJSON;
  finally
    inp.Free;
  end;

  if ASave then kind := LW_KIND_SAVE else kind := LW_KIND_OPEN;
  btns := MakeBtns([idButtonOk, idButtonCancel], idButtonOk);
  Result := AskBrowser(kind, ACaption, '', btns, idButtonCancel, spec, AResult, APaths);
end;

class function TLWWSOpenDialog.CreateHandle(const ACommonDialog: TCommonDialog): TLCLHandle;
begin
  { 句柄只在 LCL 内部流转，我们不用它，给个非零值即可 }
  Result := 1;
end;

class function TLWWSOpenDialog.QueryWSEventCapabilities(
  const ACommonDialog: TCommonDialog): TCDWSEventCapabilities;
begin
  { 空集表示 DoShow / DoCanClose / DoClose 这些都由基类走默认实现，
    我们只接管 ShowModal —— 否则 LCL 会绕开 ShowModal 直接找这些钩子 }
  Result := [];
end;

class procedure TLWWSOpenDialog.DestroyHandle(const ACommonDialog: TCommonDialog);
begin
  { 没有真实资源要释放 }
end;

class procedure TLWWSOpenDialog.ShowModal(const ACommonDialog: TCommonDialog);
var
  d: TOpenDialog;
  res: Integer;
  paths, first: string;
begin
  if not (ACommonDialog is TOpenDialog) then Exit;
  if not LWDialogAvailable then Exit;   { 没有浏览器：保持 nogui 的原行为（什么也不做）}

  d := TOpenDialog(ACommonDialog);
  if not AskFileDialog(d.Title, d.Filter, ExtractFileName(d.FileName), False,
    ofAllowMultiSelect in d.Options, res, paths) then
    Exit;

  if (res = idButtonOk) and (paths <> '') then
  begin
    first := paths;
    if Pos(#13#10, first) > 0 then
      first := Copy(first, 1, Pos(#13#10, first) - 1);
    try
      d.Files.Text := paths;      { 编辑器风格的换行在 TStrings 里就是多行 }
    except
    end;
    d.FileName := first;
    d.UserChoice := mrOk;
  end
  else
    d.UserChoice := mrCancel;
end;

class procedure TLWWSSaveDialog.ShowModal(const ACommonDialog: TCommonDialog);
var
  d: TOpenDialog;
  res: Integer;
  paths, dir: string;
begin
  if not (ACommonDialog is TOpenDialog) then Exit;
  if not LWDialogAvailable then Exit;

  d := TOpenDialog(ACommonDialog);
  if not AskFileDialog(d.Title, d.Filter, ExtractFileName(d.FileName), True, False,
    res, paths) then
    Exit;

  if (res = idButtonOk) and (paths <> '') then
  begin
    { 浏览器只给文件名，落盘位置由服务端决定（会话专属临时目录）。
      业务代码拿到 FileName 后自己写文件，再 SendFile 推给浏览器下载。 }
    dir := LWCurrentSession.SessionTempDir('save');
    if dir = '' then
    begin
      d.UserChoice := mrCancel;
      Exit;
    end;
    d.FileName := dir + SafeBaseName(paths);
    d.UserChoice := mrOk;
  end
  else
    d.UserChoice := mrCancel;
end;

{ ---------------- 安装 ---------------- }

procedure LWInstallDialogs;
begin
  if GInstalled then Exit;
  GInstalled := True;

  { 先记下原来的实现：本地模式（没有会话）时原样退回去 }
  GOldPrompt := PromptDialogFunction;
  GOldInput := InputDialogFunction;
  GOldQuestion := QuestionDialogFunction;
  GOldMsgBox := Forms.MessageBoxFunction;

  PromptDialogFunction := @LWPromptDialog;
  InputDialogFunction := @LWInputDialog;
  QuestionDialogFunction := @LWQuestionDialog;
  Forms.MessageBoxFunction := @LWMessageBox;

  { 文件对话框：替换 widgetset 类。必须在任何 TOpenDialog 实例创建之前完成，
    否则那个实例已经绑定了旧的 WS 类（这里的调用点在建任何窗体之前，安全）。 }
  RegisterWSComponent(TOpenDialog, TLWWSOpenDialog);
  RegisterWSComponent(TSaveDialog, TLWWSSaveDialog);
end;

end.
