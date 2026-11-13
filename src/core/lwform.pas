{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwform
  ------------------------------------------------------------------
  TLWForm —— 业务窗体的基类，只做两件事：

   1. 覆盖 ShowModal：Web 模式下不再真的阻塞 GUI 消息循环，
      而是把窗体推送到浏览器、当前请求线程挂起等待用户关闭，
      用户点确定/取消后线程继续 —— 与 uniGUI 的同步模态完全同构。
   2. 覆盖 DoClose：关闭动作交回会话处理（销毁浏览器端窗口、
      唤醒挂起的线程）。

  迁移已有窗体时，只需把
      TForm1 = class(TForm)
  改成
      TForm1 = class(TLWForm)
}
unit lwform;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, fpjson, lwbase, lwdownload;

type
  TLWForm = class(TForm)
  private
    FWebClosing: Boolean;
    FWebVisible: Boolean;
  protected
    procedure DoClose(var CloseAction: TCloseAction); override;
    { .lfm 加载完后把窗体名还原成设计期名字。
      LCL 的 TReader 在一个进程里已经存在同名窗体时会自动加 "_N" 后缀，
      而多会话并存正是 Web 应用的常态（每个会话一份窗体实例）。 }
    procedure Loaded; override;
    { nogui 下 TCustomForm.Show 会在 LCL 内部触发除零错误；Web 模式根本不需要
      真正的窗口，所以把 Visible 的赋值翻译成"通知会话：这个窗体该显示了" }
    procedure SetVisible(AValue: Boolean); override;
  public
    destructor Destroy; override;
    { Web 模式下走"推送 + 挂起等待"，本地模式下保持原生行为 }
    function ShowModal: Integer; override;
    { 设置结果并关闭，推荐的写法：ModalClose(mrOk) }
    procedure ModalClose(AResult: Integer);
    { 当前窗体是否处于 Web 模态 }
    function IsWebModal: Boolean;
    { 浏览器端是否已显示这个窗体（由会话维护，VCL 的 Visible 不参与） }
    property WebVisible: Boolean read FWebVisible write FWebVisible;

    { 让浏览器下载服务端上的一个文件。
      路径不会出现在 URL 里：先在 lwdownload 里换成一次性令牌，
      浏览器只拿到 /lw/download?t=<令牌>。 }
    procedure SendFile(const AFileName: string; const ADownloadName: string = '');
    { 把一段文本（CSV / 报表 / 日志）直接作为文件下载。
      服务端写到临时目录，再走 SendFile。 }
    procedure SendText(const AText, ADownloadName: string;
      const AWithBOM: Boolean = False);
    { 浏览器右上角弹一条 Toast 轻提示（几秒后自动消失，不阻塞）。
      对应 uniGUI 的 UniSession.AddJS / uniToast；比 ShowMessage 轻：
      不挂起线程、不需要用户点确定。 }
    procedure ShowToast(const AMsg: string; const ATitle: string = '');
  end;

implementation

destructor TLWForm.Destroy;
var
  S: TLWSessionBase;
begin
  { 会话清单里留着指针，窗体一释放就是野指针 —— 必须先摘掉再走 LCL 的销毁 }
  S := LWCurrentSession;
  if S <> nil then
    try
      S.SessionForgetForm(Self);
    except
    end;
  inherited Destroy;
end;

function TLWForm.ShowModal: Integer;
var
  S: TLWSessionBase;
begin
  S := LWCurrentSession;
  if S = nil then
    Exit(inherited ShowModal);
  if S.SessionIsModal(Self) then
    Exit(mrNone);
  Result := S.ShowModalInSession(Self);
end;

procedure TLWForm.ModalClose(AResult: Integer);
begin
  ModalResult := AResult;
  Close;
end;

function TLWForm.IsWebModal: Boolean;
var
  S: TLWSessionBase;
begin
  S := LWCurrentSession;
  Result := (S <> nil) and S.SessionIsModal(Self);
end;

procedure TLWForm.SendFile(const AFileName, ADownloadName: string);
var
  S: TLWSessionBase;
  token, nm: string;
  cmd: TJSONObject;
begin
  if not FileExists(AFileName) then Exit;
  token := LWDownloadRegister(AFileName, ADownloadName);
  if token = '' then Exit;
  nm := ExtractFileName(AFileName);
  if ADownloadName <> '' then
    nm := ExtractFileName(ADownloadName);

  S := LWCurrentSession;
  if S = nil then Exit;   { 设计期/本地模式：没有任何浏览器可推 }
  cmd := TJSONObject.Create;
  try
    cmd.Add('type', 'download');
    cmd.Add('url', '/lw/download?t=' + token);
    cmd.Add('name', nm);
    S.SessionPushCommand(cmd.AsJSON);
    S.SessionNotify('SendFile: ' + nm);
  finally
    cmd.Free;
  end;
end;

procedure TLWForm.SendText(const AText, ADownloadName: string;
  const AWithBOM: Boolean);
var
  fn: string;
  fs: TFileStream;
  bom: array[0..2] of Byte = ($EF, $BB, $BF);
  buf: RawByteString;
begin
  if ADownloadName = '' then Exit;
  fn := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'lw_' + FormatDateTime('yyyymmdd_hhnnsszzz', Now) + '_' + ExtractFileName(ADownloadName);
  fs := TFileStream.Create(fn, fmCreate);
  try
    if AWithBOM then
      fs.WriteBuffer(bom[0], 3);
    { UTF-8 无 BOM 时 Excel 会按本地代码页解析中文，业务代码可自行选 AWithBOM }
    buf := UTF8Encode(AText);
    if buf <> '' then
      fs.WriteBuffer(buf[1], Length(buf));
  finally
    fs.Free;
  end;
  SendFile(fn, ADownloadName);
end;

procedure TLWForm.ShowToast(const AMsg, ATitle: string);
var
  S: TLWSessionBase;
  cmd: TJSONObject;
begin
  S := LWCurrentSession;
  if S = nil then Exit;   { 设计期/本地模式：没有浏览器可推 }
  cmd := TJSONObject.Create;
  try
    cmd.Add('type', 'toast');
    cmd.Add('title', ATitle);
    cmd.Add('text', AMsg);
    S.SessionPushCommand(cmd.AsJSON);
  finally
    cmd.Free;
  end;
end;

procedure TLWForm.SetVisible(AValue: Boolean);
var
  S: TLWSessionBase;
begin
  S := LWCurrentSession;
  { 注意：装载 .lfm 期间 LCL 也会给 Visible 赋初值，那必须走原路径，
     否则 LCL 内部状态不一致（会在创建窗体时直接除零崩溃）。
     装载完成后，Web 模式下 Visible 只是"该不该显示"的意图，
     真正的窗口可见性由 FWebVisible + 浏览器端窗口决定，
     所以这里绝不能落到 inherited —— nogui 的 ShowWindow 会除零。 }
  if (S <> nil) and (Name <> '') and
     not (csLoading in ComponentState) and not (csCreating in ControlState) then
  begin
    if AValue then
    begin
      if not FWebVisible then S.SessionShowForm(Self);
    end
    else if FWebVisible then
      S.SessionHideForm(Self);
    Exit;
  end;
  inherited SetVisible(AValue);
end;

procedure TLWForm.Loaded;
begin
  inherited Loaded;
  { 名字必须是设计期那个：框架按名字找登录窗体、默认窗体、会话内窗体 }
  Name := LWStripUniqSuffix(Name);
end;

procedure TLWForm.DoClose(var CloseAction: TCloseAction);
var
  S: TLWSessionBase;
begin
  S := LWCurrentSession;
  if S = nil then
  begin
    inherited DoClose(CloseAction);
    Exit;
  end;

  if S.SessionIsModal(Self) then
  begin
    if FWebClosing then
    begin
      CloseAction := caNone;
      Exit;
    end;
    FWebClosing := True;
    try
      CloseAction := caNone; { 不销毁对象，由会话决定生命周期 }
      S.SessionEndModal(Self, ModalResult);
    finally
      FWebClosing := False;
    end;
    Exit;
  end;

  { 非模态窗体关闭：通知浏览器销毁窗口，并从会话的可见清单里摘掉。
    必须摘掉 —— 业务代码随后 Free 掉窗体时，清单里留着就是野指针，
    下一次 BuildPayload 会直接 AV。 }
  S.SessionHideForm(Self);
  CloseAction := caNone;

  { 会话里最后一个可见窗体被关掉后自动回登录页。不这样做的话，
    点主窗体菜单"关闭窗口"后浏览器就是一张白纸 —— 没有任何窗体
    可点，用户只能退出服务端重启才能再登录（坑 35）。
    登录窗体自己被关不在此列：关就关了，不再自动弹回来。 }
  if (S.LoginForm <> nil) and (S.LoginForm <> Self) and
     (S.VisibleWebFormCount = 0) then
    S.SessionShowForm(S.LoginForm);
end;

end.
