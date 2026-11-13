{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwsession
  ------------------------------------------------------------------
  会话 = 一个浏览器标签页 + 一棵真实的 LCL 窗体实例树。

  与 uniGUI 的对应关系：
     uniGUI 的 TUniSession / UniApplication.Session         ->  TLWSession
     uniGUI 的 组件 -> JS 映射                              ->  TLWWriter
     uniGUI 的 同步模态（nested message loop）              ->  ShowModalInSession + 出站指令队列

  线程模型：
    - HTTP 服务器是多线程的（ThreadMode=tmThread）；
    - 事件处理时不在锁内调用业务代码，避免模态挂起时把会话锁死；
    - 只有"分配组件 ID / 生成 JSON 树"这类纯框架操作才短暂持锁。
}
unit lwsession;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Forms, Controls, fpjson, lwbase, lwwriter, lwform, lwdiff;

const
  { 模态等待上限，防止浏览器崩溃后服务端线程永久悬挂 }
  LW_MODAL_TIMEOUT_MS = 180000;

var
  { 当前正在处理请求的"页签标识"（线程局部）。
    浏览器每个标签页生成一个随机串，随事件一起送上来；
    需要"只给发起方看"的指令（对话框）据此打上 to 字段，
    其它页签收到后忽略，避免同一会话多个页签弹出同一个对话框。
    后台线程（定时器等）发起时为 ''，表示所有页签都可以应答。 }
  LWCurrentTab: string = '';

procedure LWSetCurrentTab(const ATab: string);
function LWGetCurrentTab: string;

{ 服务端正在停止：所有挂起的长轮询（/lw/api/poll）立刻返回。
  这些等待最长 20 秒，不叫醒的话 Stop -> 释放 HTTP 服务器 会一直等
  这些连接线程收工，表现就是"关窗后要等半天才退出"。
  TLWServer.Start 复位为 False，Stop 置 True。 }
procedure LWSetServerStopping(AValue: Boolean);
function LWServerStopping: Boolean;

type
  { 会话出站指令的直推回调（WebSocket 传输用）。
    ASession 是发起推送的会话（就是 PushSock 的所有者） }
  TPushJSONEvent = procedure(ASession: TObject; const AJSON: string) of object;

  TLWSession = class(TLWSessionBase)
  private
    FSid: string;
    { BuildPayload 的实际实现；对外只暴露带执行锁的 BuildPayload }
    FForms: TList;
    FModal: TCustomForm;
    FModalDone: TEvent;
    FModalResult: Integer;
    FIdOf: TStringList;
    FCompOf: TFPList;
    FNextId: Integer;
    FLock: TCriticalSection;
    FOnPushCommand: TPushJSONEvent;
    FPushSock: TObject;
    { 会话级"执行锁"：同一会话的**事件处理**与**组件树序列化**必须串行。
      为什么需要：LCL 控件不是线程安全的，而 BuildPayload 会写共享状态
      （最典型 TLWDBGrid.FMatches 动态数组：MatchClear/MatchAdd 在序列化
      过程中扩容）。浏览器在对话框挂起期间仍可能发出第二个事件（用户连点、
      点别处、事件失败重试），两个请求线程同时 BuildPayload 就会并发
      realloc 同一个数组 —— 堆被写坏，先抛 EWriteError 之类的杂异常，
      随后 AV（实测栈：两个线程同时停在 lwdbgrid.MatchAdd 的 SetLength）。
      可重入（Windows 临界区同线程可重入），事件里再调 BuildPayload 安全；
      对话框挂起期间不释放锁 —— 语义上也正确：模态框本来就该挡住同一会话
      的其他事件。应答走 /lw/api/dlg（只碰 FLock），不会死锁。 }
    FExec: TCriticalSection;
    FExecDepth: Integer;
    FExecOwner: TThreadID;
    FLastAccess: TDateTime;
    FOutbox: TStringList;
    FOutboxEvent: TEvent;
    FLog: TStringList;
    FRefCount: Integer;
    FMarked: Boolean;
    FRemoteIP: string;
    { 浏览器对话框（消息框 / 输入框 / 选文件）}
    FDlgDone: TEvent;
    FDlgActive: Boolean;
    FDlgToken: Integer;
    FDlgSeq: Integer;
    FDlgResult: Integer;
    FDlgText: string;
    FDlgSpec: string;   { 挂起对话框的完整指令 JSON（重发给刷新后的页签） }
    { 会话级键值（登录名/角色等），随会话一起销毁 }
    FVars: TStringList;
    { 出站指令序号：多页签共用会话时，每个页签用自己的游标(after)取增量，
      所以每条指令都要带序号（单页签时序号只是摆设，走老的销毁式队列） }
    FSeq: Integer;
    FOutboxSeqs: TFPList;
    { 挂到本会话上的页签数（>1 = 多页签共享，推送改走轮询游标） }
    FAttached: Integer;
    FMultiTab: Boolean;
    { ---- 增量补丁（阶段 2，--patch=1 打开）----
      FSnapForms 是"上一次已经交给浏览器的整棵树"，也是下一帧算 diff 的基线。
      它的所有权在本对象；每次发全量时用新树替换。
      FVerTree   当前树版本，客户端下次请求要带回来；对不上就发全量（自愈）。
      为什么不做重传队列：丢帧/多页签/重连都靠"版本对不上 → 全量"兜底，
      代价只是那一帧多 78KB，逻辑简单一个数量级。 }
    FSnapForms: TJSONArray;
    FVerTree: Integer;
    FPatchOn: Boolean;
    FClientVer: Integer;
    FForceFull: Boolean;
    procedure SetFormWebVisible(AForm: TCustomForm; AValue: Boolean);
    { BuildPayload 的实际实现；对外只暴露带执行锁的 BuildPayload }
    function BuildPayloadCore: TJSONObject;
    { 只序列化窗体数组（不含外壳），全量与补丁两条路都要用 }
    function BuildFormsArray: TJSONArray;
    { 调用方已持执行锁 + 进程闸门 }
    function MakeFullPayload: TJSONObject;
    procedure ReplaceSnap(AForms: TJSONArray);
  public
    constructor Create(const ASid: string; AMainForm: TCustomForm; const ARemoteIP: string);
    destructor Destroy; override;

    { 组件 ID 分配 }
    function IdOf(C: TComponent): Integer;
    function CompById(AId: Integer): TComponent;

    { 窗体管理 }
    procedure AddForm(F: TCustomForm);
    function FindFormByName(const AName: string): TCustomForm;
    function FormCount: Integer;

    { TLWSessionBase }
    function VisibleWebFormCount: Integer; override;

    { 生成一次完整的组件树（含所有可见窗体） }
    function BuildPayload: TJSONObject;

    { 事件响应：能补就补，否则全量。与 BuildPayload 的区别只有一点 ——
      它会检查客户端带回的树版本（客户端没带 patch 能力时退化成全量） }
    function BuildEventPayload: TJSONObject;
    { 每个事件进来先登记：AClientVer = body.tver（-1 = 客户端不支持补丁）}
    procedure BeginEventPatch(AClientVer: Integer; AForceFull: Boolean);
    function PatchActive: Boolean;

    { 会话级执行锁：事件处理（LWHandleEvent）与 BuildPayload 都要持锁，
      防止两个请求线程并发操作同一棵 LCL 控件树（见 FExec 注释）。
      可重入：同一线程重复 Enter 只需一次 Leave 对应一次 Enter。 }
    procedure LockExec;
    procedure UnlockExec;
    { 挂起等待（对话框/模态窗体）期间临时把执行锁整个放开：
      等待时本线程不碰任何 LCL 对象，持锁只会把同一会话的其他请求
      （含新页签建会话）堵到超时。返回挂起前的重入深度，恢复时按原深度重新加锁 }
    function SuspendExec: Integer;
    procedure ResumeExec(ADepth: Integer);

    { TLWSessionBase }
    function ShowModalInSession(AForm: TCustomForm): Integer; override;
    procedure SessionEndModal(AForm: TCustomForm; AResult: Integer); override;
    procedure SessionPushCommand(const ACmdJson: string); override;
    procedure SessionNotify(const AText: string); override;
    function SessionIsModal(AForm: TCustomForm): Boolean; override;
    procedure SessionShowForm(AForm: TCustomForm); override;
    procedure SessionHideForm(AForm: TCustomForm); override;
    function SessionFindForm(const AName: string): TCustomForm; override;
    procedure SessionForgetForm(AForm: TCustomForm); override;
    function SessionGetVar(const AName: string): string; override;
    { 多页签：新页签挂到已有会话上。>1 个页签时推送不再走 WebSocket
      （一条推送没法同时喂两个 socket），改由各页签轮询 + 游标取增量 }
    procedure AttachTab;
    function TakeCommandAfter(AAfter: Integer; out ACmd: string; out ASeq: Integer): Boolean;
    procedure WaitCommandAfter(AAfter: Integer; ATimeoutMs: Integer;
      out ACmd: string; out ASeq: Integer);
    property Seq: Integer read FSeq;
    property MultiTab: Boolean read FMultiTab;
    procedure SessionSetVar(const AName, AValue: string); override;
    function SessionDialog(const ASpecJson: string; out AResult: Integer;
      out AText: string): Boolean; override;
    function SessionTempDir(const ASub: string = ''): string; override;

    { 浏览器把对话框的答案送回来（/lw/api/dlg、选文件上传成功时调用）}
    function ResolveDialog(AToken, AResult: Integer; const AText: string): Boolean;

    { 挂起中的对话框指令原文（FDlgActive=True 时非空）。
      页签刷新（Shift+F5）后 attach 响应里带回它重发 —— 否则刷新会把
      对话框"吃掉"：服务端线程吊在 MessageDlg 上直到 180s 超时。 }
    function PendingDialogCmd: string;

    { 出站指令队列（浏览器长轮询消费） }
    function TakeCommand(out ACmd: string): Boolean;
    procedure WaitCommand(var ACmd: string; ATimeoutMs: Integer);

    procedure Touch;
    function ConsoleText: string;

    property Sid: string read FSid;
    property Lock: TCriticalSection read FLock;
    property ModalForm: TCustomForm read FModal;
    property LastAccess: TDateTime read FLastAccess;
    property RefCount: Integer read FRefCount write FRefCount;
    property Marked: Boolean read FMarked write FMarked;
    property RemoteIP: string read FRemoteIP;
    { WebSocket 直推钩子：赋值后 SessionPushCommand 不再进 outbox，
      而是同步调用本钩子（由 WS 连接线程在处理事件时执行，socket
      所有权就在本线程 —— 线程安全）。PushSock 是该会话的 WS 连接
      socket，由升级处理器绑定；长轮询客户端两者都保持 nil。 }
    property OnPushCommand: TPushJSONEvent read FOnPushCommand write FOnPushCommand;
    property PushSock: TObject read FPushSock write FPushSock;
  end;

  TLWSessionStore = class
  private
    FItems: TStringList;
    FLock: TCriticalSection;
    FCounter: Integer;
    function NewSid: string;
  public
    constructor Create;
    destructor Destroy; override;
    function NewSession(AMainForm: TCustomForm; const ARemoteIP: string): TLWSession;
    function Find(const ASid: string): TLWSession;   { 返回时 RefCount+1，用完必须 Release }
    procedure Release(S: TLWSession);
    procedure Remove(const ASid: string);
    function Sweep(AIdleMinutes: Integer): Integer;
    function Count: Integer;
  end;

implementation

{ 临时剖析（LW_DIFF_PROF=1）：单独量 diff 这一步花多少微秒。
  计时统一走 lwbase.LWNowUS —— 本单元不再自己声明 kernel32 入口，
  否则 Linux 下编不过（框架整体要跨平台）。 }
var
  GDiffProf: Boolean = False;
  GDiffProfInit: Boolean = False;
  GDiffQ0: Int64;

procedure DiffProfStart;
begin
  if not GDiffProfInit then
  begin
    GDiffProfInit := True;
    GDiffProf := GetEnvironmentVariable('LW_DIFF_PROF') <> '';
  end;
  if GDiffProf then GDiffQ0 := LWNowUS;
end;

procedure DiffProfStop(const AStats: TLWDiffStats);
begin
  if not GDiffProf then Exit;
  Writeln(ErrOutput, '[diff] ', LWNowUS - GDiffQ0,
    ' us  nodes=', AStats.Nodes, ' +', AStats.Added, ' -', AStats.Removed,
    ' ~', AStats.Changed, ' m', AStats.Moved);
end;

procedure LWSetCurrentTab(const ATab: string);
begin
  LWCurrentTab := ATab;
end;

function LWGetCurrentTab: string;
begin
  Result := LWCurrentTab;
end;

{ 停止标志：一个 Boolean 全局量就够 —— 写是原子的，读者每 200ms
  轮询一次，最多晚一个切片看到，不需要额外的同步对象。 }
var
  GServerStopping: Boolean = False;

procedure LWSetServerStopping(AValue: Boolean);
begin
  GServerStopping := AValue;
end;

function LWServerStopping: Boolean;
begin
  Result := GServerStopping;
end;

{ 等事件，但服务端要退出时立刻返回 wrAbandoned（调用方按"超时/取消"处理）。
  模态对话框的等待上限是 180 秒，直接 WaitFor 会把这 180 秒原封不动地
  变成关窗的等待时间。 }
function LWWaitEventOrStop(AEvent: TEvent; ATimeoutMs: Integer): TWaitResult;
var
  waited: Integer;
begin
  waited := 0;
  while waited < ATimeoutMs do
  begin
    if LWServerStopping then
      Exit(wrAbandoned);
    Result := AEvent.WaitFor(200);
    if Result <> wrTimeout then
      Exit;
    Inc(waited, 200);
  end;
  Result := wrTimeout;
end;

{ ---------------- TLWSession ---------------- }

constructor TLWSession.Create(const ASid: string; AMainForm: TCustomForm;
  const ARemoteIP: string);
begin
  inherited Create;
  FSid := ASid;
  FRemoteIP := ARemoteIP;
  FForms := TList.Create;
  FIdOf := TStringList.Create;
  FIdOf.Sorted := True;
  { 键是十进制数字串，大小写毫无意义。**必须 True**：False 时有序表的
    查找走 AnsiCompareText，Windows 上是带 locale 的 CompareStringW，
    一次 ~10µs；每个节点序列化都要查一次 id，160 个节点就是 1.5ms
    （和 lwdiff 那轮翻车同一个坑，见 NOTES 坑 100） }
  FIdOf.CaseSensitive := True;
  FIdOf.Duplicates := dupIgnore;
  FCompOf := TFPList.Create;
  FCompOf.Add(nil); { id 从 1 开始，0 留空 }
  FNextId := 1;
  FLock := TCriticalSection.Create;
  FExec := TCriticalSection.Create;
  FExecDepth := 0;
  FVars := TStringList.Create;
  FOutbox := TStringList.Create;
  FOutboxSeqs := TFPList.Create;
  FSeq := 0;
  FAttached := 1;
  FLog := TStringList.Create;
  FOutboxEvent := TEvent.Create(nil, False, False, '');
  FModalDone := TEvent.Create(nil, False, False, '');
  FDlgDone := TEvent.Create(nil, False, False, '');
  FLastAccess := Now;
  { 增量补丁：进程级开关（--patch=1）。关着的时候快照/版本完全不维护，
    老路径零开销 —— 这也是灰度期间出问题能一键退回的保证 }
  FPatchOn := LWServerPatchMode;
  FVerTree := 0;
  FSnapForms := nil;
  FClientVer := -1;
  FForceFull := True;
  if AMainForm <> nil then
  begin
    if AMainForm is TLWForm then
      TLWForm(AMainForm).WebVisible := True;
    AddForm(AMainForm);
  end;
end;

destructor TLWSession.Destroy;
var
  i: Integer;
begin
  { 释放窗体同样动 LCL 的全局字形/位图缓存，与"建窗体"互为竞态 ——
    必须套同一个进程级闸门（否则关会话的线程能把正在首开的另一个会话搞崩） }
  LWLCLEnter;
  try
    for i := FForms.Count - 1 downto 0 do
      TCustomForm(FForms[i]).Free;
  finally
    LWLCLLeave;
  end;
  FForms.Free;
  FSnapForms.Free;
  FIdOf.Free;
  FCompOf.Free;
  FVars.Free;
  FOutboxSeqs.Free;
  FOutbox.Free;
  FLog.Free;
  FOutboxEvent.Free;
  FModalDone.Free;
  FDlgDone.Free;
  FLock.Free;
  FExec.Free;
  inherited Destroy;
end;

procedure TLWSession.Touch;
begin
  FLastAccess := Now;
end;

procedure TLWSession.AddForm(F: TCustomForm);
begin
  FLock.Enter;
  try
    if FForms.IndexOf(F) < 0 then
      FForms.Add(F);
  finally
    FLock.Leave;
  end;
end;

{ 只改标记，不推送、不动清单 }
procedure TLWSession.SetFormWebVisible(AForm: TCustomForm; AValue: Boolean);
begin
  if AForm is TLWForm then
    TLWForm(AForm).WebVisible := AValue;
end;

procedure TLWSession.SessionShowForm(AForm: TCustomForm);
var
  cmd: TJSONObject;
begin
  if AForm = nil then Exit;
  SetFormWebVisible(AForm, True);
  AddForm(AForm);
  cmd := TJSONObject.Create;
  try
    cmd.Add('type', 'show');
    SessionPushCommand(cmd.AsJSON);
  finally
    cmd.Free;
  end;
  SessionNotify('Show: ' + AForm.Name);
end;

procedure TLWSession.SessionHideForm(AForm: TCustomForm);
var
  cmd: TJSONObject;
begin
  if AForm = nil then Exit;
  { 只翻可见标记，【不】从 FForms 里删：
    - 对象要留给业务代码下次 Visible:=True 再显示（多窗体切换就靠这个）；
    - 真正删除的时机是窗体被 Free（TLWForm.Destroy -> SessionForgetForm）
      或者模态结束。BuildPayload 按 WebVisible 过滤，隐藏窗体不会下发。 }
  SetFormWebVisible(AForm, False);
  cmd := TJSONObject.Create;
  try
    cmd.Add('type', 'closeform');
    cmd.Add('id', IdOf(AForm));
    SessionPushCommand(cmd.AsJSON);
  finally
    cmd.Free;
  end;
  SessionNotify('Hide: ' + AForm.Name);
end;

function TLWSession.VisibleWebFormCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for i := 0 to FForms.Count - 1 do
      if (TObject(FForms[i]) is TLWForm) and TLWForm(FForms[i]).WebVisible then
        Inc(Result);
  finally
    FLock.Leave;
  end;
end;

function TLWSession.FormCount: Integer;
begin
  FLock.Enter;
  try
    Result := FForms.Count;
  finally
    FLock.Leave;
  end;
end;

function TLWSession.FindFormByName(const AName: string): TCustomForm;
var
  i: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    for i := 0 to FForms.Count - 1 do
      if SameText(TCustomForm(FForms[i]).Name, AName) then
        Exit(TCustomForm(FForms[i]));
  finally
    FLock.Leave;
  end;
end;

function TLWSession.SessionFindForm(const AName: string): TCustomForm;
begin
  Result := FindFormByName(AName);
end;

procedure TLWSession.SessionForgetForm(AForm: TCustomForm);
var
  idx: Integer;
begin
  if AForm = nil then Exit;
  FLock.Enter;
  try
    idx := FForms.IndexOf(AForm);
    if idx >= 0 then FForms.Delete(idx);
  finally
    FLock.Leave;
  end;
end;

function TLWSession.SessionGetVar(const AName: string): string;
begin
  Result := '';
  FLock.Enter;
  try
    Result := FVars.Values[AName];
  finally
    FLock.Leave;
  end;
end;

procedure TLWSession.SessionSetVar(const AName, AValue: string);
begin
  FLock.Enter;
  try
    FVars.Values[AName] := AValue;
  finally
    FLock.Leave;
  end;
end;

function TLWSession.IdOf(C: TComponent): Integer;
var
  k: string;
  idx: Integer;
begin
  if C = nil then Exit(0);
  k := IntToStr(PtrInt(Pointer(C)));
  FLock.Enter;
  try
    idx := FIdOf.IndexOf(k);
    if idx >= 0 then
      Exit(PtrInt(FIdOf.Objects[idx]));
    Result := FNextId;
    Inc(FNextId);
    FCompOf.Add(C);
    FIdOf.AddObject(k, TObject(PtrInt(Result)));
  finally
    FLock.Leave;
  end;
end;

function TLWSession.CompById(AId: Integer): TComponent;
begin
  Result := nil;
  if (AId <= 0) then Exit;
  FLock.Enter;
  try
    if AId < FCompOf.Count then
      Result := TComponent(FCompOf[AId]);
  finally
    FLock.Leave;
  end;
end;

procedure TLWSession.LockExec;
begin
  { 可重入包装：Windows 临界区本身可重入，Linux（pthread mutex）不可。
     用「持有者 + 深度」自己实现重入，两个平台一致。
     深度只有持有者线程会写，读侧的短暂陈旧最多导致多阻塞一次，不影响正确性 }
  if (FExecDepth > 0) and (FExecOwner = GetCurrentThreadId) then
  begin
    Inc(FExecDepth);
    Exit;
  end;
  FExec.Enter;
  FExecOwner := GetCurrentThreadId;
  FExecDepth := 1;
end;

procedure TLWSession.UnlockExec;
begin
  if FExecDepth <= 0 then Exit;
  Dec(FExecDepth);
  if FExecDepth = 0 then
  begin
    {$IFDEF DARWIN}
      FExecOwner := TThreadID(0);
    {$ELSE}
      FExecOwner := 0;
    {$ENDIF}
    FExec.Leave;
  end;
end;

function TLWSession.SuspendExec: Integer;
begin
  { 深度只有持有者线程会写，这里读到的就是本线程的值 }
  Result := FExecDepth;
  while FExecDepth > 0 do UnlockExec;
end;

procedure TLWSession.ResumeExec(ADepth: Integer);
var
  i: Integer;
begin
  for i := 1 to ADepth do LockExec;
end;

function TLWSession.BuildPayload: TJSONObject;
begin
  { 序列化会写控件的共享状态（TLWDBGrid.FMatches 等），必须与同一会话的
    其他序列化/事件互斥，否则并发 realloc 直接把堆写坏（见 FExec 注释） }
  LockExec;
  try
    { 再套一层进程级闸门：writer 读控件属性会碰 LCL 的位图/画布缓存，
      多个会话同时序列化（尤其刚建窗体那一刻）会踩坏 Graphics 的全局状态 }
    LWLCLEnter;
    try
      Result := MakeFullPayload;
    finally
      LWLCLLeave;
    end;
  finally
    UnlockExec;
  end;
end;

procedure TLWSession.ReplaceSnap(AForms: TJSONArray);
begin
  if FSnapForms = AForms then Exit;
  FSnapForms.Free;
  FSnapForms := AForms;
end;

function TLWSession.MakeFullPayload: TJSONObject;
var
  arr: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.Add('ok', True);
  Result.Add('sid', FSid);
  Result.Add('ver', LW_VERSION);

  arr := BuildFormsArray;
  if FPatchOn then
  begin
    { 版本 +1：客户端下一次请求必须带回它，否则下一帧发全量。
      快照要留一份（payload 会带走 arr），克隆只在全量时发生 ——
      正常事件走补丁，这条路一天走不了几次 }
    Inc(FVerTree);
    Result.Add('tver', FVerTree);
    ReplaceSnap(TJSONArray(arr.Clone));
  end;
  Result.Add('forms', arr);
end;

function TLWSession.BuildEventPayload: TJSONObject;
var
  arr, patch: TJSONArray;
  stats: TLWDiffStats;
  useFull: Boolean;
  nStruct: Integer;
begin
  LockExec;
  try
    LWLCLEnter;
    try
      Result := TJSONObject.Create;
      Result.Add('ok', True);
      Result.Add('sid', FSid);
      Result.Add('ver', LW_VERSION);

      arr := BuildFormsArray;
      patch := nil;
      useFull := True;
      FillChar(stats, SizeOf(stats), 0);

      if FPatchOn and (not FForceFull) and (FSnapForms <> nil) and
         (FClientVer = FVerTree) then
      begin
        DiffProfStart;
        patch := LWDiffForms(FSnapForms, arr, stats);
        DiffProfStop(stats);
        if patch <> nil then
        begin
          { 节点数太多就别玩补丁了：快照本身就占一份内存，
            而且这种界面每次事件改动都很大，补丁省不了多少 }
          if stats.Nodes > 3000 then
          begin
            FPatchOn := False;
            FreeAndNil(patch);
          end
          else
          begin
            nStruct := stats.Added + stats.Removed;
            { 结构大幅变化（换页签内容/重建列表）时全量更小也更可靠 }
            useFull := (nStruct > 20) or (nStruct * 2 > stats.Nodes);
            if useFull then FreeAndNil(patch);
          end;
        end;
      end;

      if useFull or (patch = nil) then
      begin
        Inc(FVerTree);
        Result.Add('tver', FVerTree);
        Result.Add('forms', arr);
        if FPatchOn then
          ReplaceSnap(TJSONArray(arr.Clone));
        FForceFull := False;
      end
      else
      begin
        Result.Add('base', FVerTree);
        Inc(FVerTree);
        Result.Add('tver', FVerTree);
        Result.Add('patch', patch);   { Result 接管 patch }
        { 新树直接当基线：这里不用克隆，arr 反正不会被别人释放 }
        ReplaceSnap(arr);
      end;
    finally
      LWLCLLeave;
    end;
  finally
    UnlockExec;
  end;
end;

{ 每个事件开始时定基线：客户端报的树版本 + 它懂不懂补丁 }
procedure TLWSession.BeginEventPatch(AClientVer: Integer; AForceFull: Boolean);
begin
  FClientVer := AClientVer;
  { 客户端没声明补丁能力（老的缓存 js / Ext 渲染层）→ 一律全量。
    这条比"服务端开关"更关键：开着 --patch=1 也不会把老客户端打死 }
  FForceFull := AForceFull or (AClientVer < 0) or (not FPatchOn);
end;

function TLWSession.PatchActive: Boolean;
begin
  Result := FPatchOn and (FSnapForms <> nil);
end;

function TLWSession.BuildFormsArray: TJSONArray;
var
  w: TLWWriter;
  arr: TJSONArray;
  i: Integer;
  f: TCustomForm;
  list: TList;
begin
  { 复制一份窗体清单，避免序列化过程中被别的线程改动 }
  list := TList.Create;
  FLock.Enter;
  try
    for i := 0 to FForms.Count - 1 do
      list.Add(FForms[i]);
  finally
    FLock.Leave;
  end;

  arr := TJSONArray.Create;
  w := TLWWriter.Create(@IdOf);
  try
    for i := 0 to list.Count - 1 do
    begin
      f := TCustomForm(list[i]);
      if f = nil then Continue;
      { 隐藏的窗体仍留在会话清单里（可再次显示），但不下发 }
      if (f is TLWForm) and (not TLWForm(f).WebVisible) then Continue;
      { 兜底：启用了登录但会话还没通过认证时，只下发登录窗体本身。
        业务代码哪怕误把主窗体 Show 出来（或复用了一个残留实例），
        浏览器也拿不到 —— 认证是"看到主页"的唯一入口，不能只靠
        事件拦截（拦截只管事件，管不住已经下发的界面）。 }
      if FRequireAuth and (not FAuthenticated) and (f <> FLoginForm) then Continue;
      { FForms 里只有"该在浏览器里显示"的窗体：
        主窗体在建会话时加入，ShowModal / Show 时加入，关闭时移除 }
      arr.Add(w.WriteForm(f, f = FModal));
    end;
  finally
    w.Free;
    list.Free;
  end;
  Result := arr;
end;

function TLWSession.BuildPayloadCore: TJSONObject;
begin
  Result := MakeFullPayload;
end;

function TLWSession.ShowModalInSession(AForm: TCustomForm): Integer;
var
  cmd: TJSONObject;
  w: TLWWriter;
  idx: Integer;
  savedDepth: Integer;
  waitRes: TWaitResult;
begin
  Result := mrCancel;
  if FModal <> nil then
    Exit(mrNone); { 不支持模态套模态 }
  if AForm = nil then Exit;

  AddForm(AForm);
  AForm.ModalResult := mrNone;
  SetFormWebVisible(AForm, True);
  FModal := AForm;
  FModalResult := mrCancel;
  FModalDone.ResetEvent;

  { 把窗体推给浏览器：主请求此刻还挂在服务端线程上，所以走独立出站通道 }
  cmd := TJSONObject.Create;
  try
    cmd.Add('type', 'modal');
    cmd.Add('text', AForm.Caption);
    w := TLWWriter.Create(@IdOf);
    try
      cmd.Add('form', w.WriteForm(AForm, True));
    finally
      w.Free;
    end;
    SessionPushCommand(cmd.AsJSON);
  finally
    cmd.Free;
  end;
  SessionNotify('ShowModal: ' + AForm.Name + ' (等待浏览器关闭)');
  { 等浏览器关闭期间本线程无事可做，先把执行锁放开，别把同会话的其他
    请求（新页签建会话、轮询之外的 API）堵住 }
  savedDepth := SuspendExec;
  try
    waitRes := LWWaitEventOrStop(FModalDone, LW_MODAL_TIMEOUT_MS);
  finally
    ResumeExec(savedDepth);
  end;
  if waitRes <> wrSignaled then
  begin
    SessionNotify('ShowModal 超时: ' + AForm.Name);
    FModal := nil;
    SetFormWebVisible(AForm, False);
    { 超时后业务代码通常会 Free 掉窗体，必须立刻从清单里摘除，
      否则下一次 BuildPayload 会序列化已释放的对象 -> AV }
    FLock.Enter;
    try
      idx := FForms.IndexOf(AForm);
      if idx >= 0 then FForms.Delete(idx);
    finally
      FLock.Leave;
    end;
    Exit(mrCancel);
  end;
  Result := FModalResult;
end;

procedure TLWSession.SessionEndModal(AForm: TCustomForm; AResult: Integer);
var
  idx: Integer;
  cmd: TJSONObject;
begin
  if (AForm = nil) then Exit;
  if AForm <> FModal then
  begin
    { 非模态窗体关闭：从可见清单摘掉，并通知浏览器销毁窗口 }
    SessionHideForm(AForm);
    Exit;
  end;

  FModalResult := AResult;
  FModal := nil;
  SetFormWebVisible(AForm, False);
  FLock.Enter;
  try
    idx := FForms.IndexOf(AForm);
    if idx >= 0 then FForms.Delete(idx);
  finally
    FLock.Leave;
  end;

  cmd := TJSONObject.Create;
  try
    cmd.Add('type', 'closeform');
    cmd.Add('id', IdOf(AForm));
    SessionPushCommand(cmd.AsJSON);
  finally
    cmd.Free;
  end;

  SessionNotify('EndModal: ' + AForm.Name + ' result=' + IntToStr(AResult));
  FModalDone.SetEvent;
end;

function TLWSession.SessionIsModal(AForm: TCustomForm): Boolean;
begin
  Result := (AForm <> nil) and (AForm = FModal);
end;

{ 弹浏览器对话框并挂起当前请求线程。

  与 ShowModalInSession 的区别：那个推的是一棵"真实窗体树"，
  这个推的是一个轻量对话框描述（消息/警告/错误/询问/输入/选文件），
  浏览器用不到 LCL 窗体，服务端也不创建任何对象 ——
  ShowMessage / MessageDlg / InputQuery / TOpenDialog.Execute 全都落到这里。

  同一会话同时只允许一个挂起对话框（模态语义）：并行请求来的第二个对话框
  直接返回 False，调用方按"取消"处理。 }
function TLWSession.SessionDialog(const ASpecJson: string; out AResult: Integer;
  out AText: string): Boolean;
var
  d: TJSONData;
  o: TJSONObject;
  token: Integer;
  savedDepth: Integer;
  waitRes: TWaitResult;
begin
  Result := False;
  AResult := 0;
  AText := '';
  if ASpecJson = '' then Exit;

  FLock.Enter;
  try
    if FDlgActive then
    begin
      token := 0;   { 0 = 已被占用，下面统一处理 }
      AResult := 0;
    end
    else
    begin
      Inc(FDlgSeq);
      token := FDlgSeq;
      FDlgToken := token;
      FDlgActive := True;
      FDlgResult := 0;
      FDlgText := '';
    end;
  finally
    FLock.Leave;
  end;

  if token = 0 then
  begin
    { 注意 SessionNotify 自己也要拿 FLock，不能写在锁里面（Linux 下普通
      mutex 不可重入，会死锁）}
    SessionNotify('对话框被忽略：已有对话框在等待用户响应');
    Exit;
  end;

  FDlgDone.ResetEvent;

  d := GetJSON(ASpecJson);
  if not (d is TJSONObject) then
  begin
    d.Free;
    FLock.Enter;
    try
      FDlgActive := False;
      FDlgSpec := '';
    finally
      FLock.Leave;
    end;
    Exit;
  end;

  { 直接把 id/type 挂进描述对象里，少一次字符串拼装 }
  o := TJSONObject(d);
  try
    o.Add('type', 'dialog');
    o.Add('id', token);
    { 只给发起这次事件的页签看；空表示"谁都可以应答"（后台线程发起） }
    if LWCurrentTab <> '' then
      o.Add('to', LWCurrentTab);
    { 记下完整指令：页签刷新后 attach 响应会把它重发一遍 }
    FLock.Enter;
    try
      FDlgSpec := o.AsJSON;
    finally
      FLock.Leave;
    end;
    SessionPushCommand(o.AsJSON);
    SessionNotify(Format('Dialog[%d]: %s <<%s>>', [token,
      JGetStr(o, 'kind', '?'), JGetStr(o, 'text', '')]));
  finally
    o.Free;
  end;

  { 挂起等浏览器应答：先把执行锁整个放开（本线程在等，不碰任何 LCL 对象），
    否则一个没人应答的对话框会把整会话堵满 180 秒超时 }
  savedDepth := SuspendExec;
  try
    waitRes := LWWaitEventOrStop(FDlgDone, LW_MODAL_TIMEOUT_MS);
  finally
    ResumeExec(savedDepth);
  end;
  if waitRes <> wrSignaled then
  begin
    FLock.Enter;
    try
      if FDlgToken = token then
      begin
        FDlgActive := False;
        FDlgSpec := '';
      end;
    finally
      FLock.Leave;
    end;
    SessionNotify(Format('Dialog[%d]: 浏览器未响应，按取消处理', [token]));
    Exit;
  end;

  Result := True;
  AResult := FDlgResult;
  AText := FDlgText;
end;

function TLWSession.ResolveDialog(AToken, AResult: Integer;
  const AText: string): Boolean;
begin
  Result := False;
  FLock.Enter;
  try
    if (not FDlgActive) or (FDlgToken <> AToken) then Exit;
    FDlgResult := AResult;
    FDlgText := AText;
    FDlgActive := False;
    FDlgSpec := '';
  finally
    FLock.Leave;
  end;
  FDlgDone.SetEvent;
  Result := True;
end;

{ 挂起中的对话框指令原文；没有挂起对话框时返回空串。
  供 ApiAttach 在响应里带回（页签刷新后重发，见lwhttp.pas）。 }
function TLWSession.PendingDialogCmd: string;
begin
  Result := '';
  FLock.Enter;
  try
    if FDlgActive then Result := FDlgSpec;
  finally
    FLock.Leave;
  end;
end;

{ 会话专属临时目录：<temp>/lw_uploads/<sid>[/<sub>] }
function TLWSession.SessionTempDir(const ASub: string): string;
var
  d: string;
begin
  d := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'lw_uploads' +
    PathDelim + FSid;
  if ASub <> '' then
    d := IncludeTrailingPathDelimiter(d) + ASub;
  if not ForceDirectories(d) then
    Exit('');
  Result := IncludeTrailingPathDelimiter(d);
end;

procedure TLWSession.SessionPushCommand(const ACmdJson: string);
begin
  { 推送统一入队，由各页签带自己的游标（/lw/api/poll?after=N）来取。
    以前"单页签 + WebSocket 就直推、多页签才入队"的做法有个死结：
    第二个页签挂上来的那一刻，主页签正连着 WS、又没在轮询，
    它永远收不到任何推送（也就不知道自己该切模式了）。
    改成全部走队列之后，"几个页签"对客户端完全透明：
    WS 只负责传事件（请求/响应），推送一律靠长轮询按序号补。
    OnPushCommand/PushSock 保留给需要极低延迟的场景，默认不启用。 }
  FLock.Enter;
  try
    Inc(FSeq);
    FOutbox.Add(ACmdJson);
    {$IF FPC_FULLVERSION >= 30301}
    FOutboxSeqs.Add(Pointer(PtrInt(FSeq)));      { 3.3.1：与合并前完全一致 }
    {$ELSE}
    FOutboxSeqs.Add(Pointer(PtrUInt(FSeq)));     { 3.2.2：经无符号中转，避开 4082 }
    {$ENDIF}
    { 只保留最近的 64 条，防止客户端掉线后无限堆积 }
    while FOutbox.Count > 64 do
    begin
      FOutbox.Delete(0);
      FOutboxSeqs.Delete(0);
    end;
  finally
    FLock.Leave;
  end;
  FOutboxEvent.SetEvent;
end;

procedure TLWSession.AttachTab;
begin
  FLock.Enter;
  try
    Inc(FAttached);
    if FAttached > 1 then
      FMultiTab := True;
  finally
    FLock.Leave;
  end;
end;

{ 推送序号在 TFPList 里以指针形式寄存（值域是很小的正整数）。
  读回时经 PtrUInt 中转到 Int64：直接 PtrInt(Pointer) 会触发 FPC 的
  4082（指针转有符号整数）提示 —— 序号永远非负，无符号中转不改变语义，
  而且不同版本对 4082 的抑制指令处理不一致，绕开更稳。 }
function LWSeqOf(P: Pointer): Int64; inline;
begin
  {$IF FPC_FULLVERSION >= 30301}
  Result := Int64(PtrInt(P));     { 3.3.1：与合并前的 PtrInt(...) 一致 }
  {$ELSE}
  Result := Int64(PtrUInt(P));    { 3.2.2：无符号中转，避开 4082 提示 }
  {$ENDIF}
end;

{ 取"序号 > AAfter"的第一条指令，不删除别人的（各页签独立游标）。
   已经在所有页签身后很远的条目顺手清掉，避免无限增长。
   没有新指令时 ASeq 返回当前最大序号 —— 客户端把它当作新游标。 }
function TLWSession.TakeCommandAfter(AAfter: Integer; out ACmd: string;
  out ASeq: Integer): Boolean;
var
  i: Integer;
begin
  ACmd := '';
  ASeq := 0;
  Result := False;
  FLock.Enter;
  try
    while (FOutboxSeqs.Count > 0) and
          (LWSeqOf(FOutboxSeqs[0]) <= Int64(AAfter) - 64) do
    begin
      FOutbox.Delete(0);
      FOutboxSeqs.Delete(0);
    end;
    for i := 0 to FOutboxSeqs.Count - 1 do
      if LWSeqOf(FOutboxSeqs[i]) > AAfter then
      begin
        ACmd := FOutbox[i];
        ASeq := Integer(LWSeqOf(FOutboxSeqs[i]));
        Result := True;
        Break;
      end;
    if not Result then
      ASeq := FSeq;
  finally
    FLock.Leave;
  end;
end;

procedure TLWSession.WaitCommandAfter(AAfter: Integer; ATimeoutMs: Integer;
  out ACmd: string; out ASeq: Integer);
var
  waited, slice: Integer;
begin
  ACmd := '';
  ASeq := FSeq;
  waited := 0;
  while waited < ATimeoutMs do
  begin
    if LWServerStopping then Exit;   { 服务端要退出：别占着连接线程 }
    if TakeCommandAfter(AAfter, ACmd, ASeq) then Exit;
    { 一个会话可能有好几个页签同时在等。TEvent 是自动复位的，
      一次 SetEvent 只能叫醒一个，剩下的必须靠切片轮询自己发现 ——
      否则第二个页签要等满整个超时（20s）才看到指令。 }
    slice := 200;
    if ATimeoutMs - waited < slice then slice := ATimeoutMs - waited;
    FOutboxEvent.WaitFor(slice);
    Inc(waited, slice);
  end;
  TakeCommandAfter(AAfter, ACmd, ASeq);
end;

procedure TLWSession.SessionNotify(const AText: string);
begin
  FLock.Enter;
  try
    FLog.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + AText);
    while FLog.Count > 500 do
      FLog.Delete(0);
  finally
    FLock.Leave;
  end;
end;

function TLWSession.TakeCommand(out ACmd: string): Boolean;
begin
  ACmd := '';
  FLock.Enter;
  try
    if FOutbox.Count > 0 then
    begin
      ACmd := FOutbox[0];
      FOutbox.Delete(0);
      Result := True;
    end
    else
      Result := False;
  finally
    FLock.Leave;
  end;
end;

procedure TLWSession.WaitCommand(var ACmd: string; ATimeoutMs: Integer);
var
  waited, slice: Integer;
begin
  ACmd := '';
  { 先看有没有积压，没有才等 }
  if TakeCommand(ACmd) then Exit;
  waited := 0;
  while waited < ATimeoutMs do
  begin
    if LWServerStopping then Exit;   { 服务端要退出：别占着连接线程 }
    { 自动复位事件一次只叫醒一个等待者，切片等待保证同会话的多个
      页签都能及时发现新指令（最迟 200ms） }
    slice := 200;
    if ATimeoutMs - waited < slice then slice := ATimeoutMs - waited;
    FOutboxEvent.WaitFor(slice);
    Inc(waited, slice);
    if TakeCommand(ACmd) then Exit;
  end;
end;

function TLWSession.ConsoleText: string;
begin
  FLock.Enter;
  try
    Result := FLog.Text;
  finally
    FLock.Leave;
  end;
end;

{ ---------------- TLWSessionStore ---------------- }

constructor TLWSessionStore.Create;
begin
  inherited Create;
  FItems := TStringList.Create;
  FItems.Sorted := True;
  FItems.CaseSensitive := False;
  FItems.Duplicates := dupIgnore;
  FLock := TCriticalSection.Create;
  FCounter := 0;
end;

destructor TLWSessionStore.Destroy;
var
  i: Integer;
begin
  for i := 0 to FItems.Count - 1 do
    TLWSession(FItems.Objects[i]).Free;
  FItems.Free;
  FLock.Free;
  inherited Destroy;
end;

function TLWSessionStore.NewSid: string;
var
  g: TGUID;
begin
  Inc(FCounter);
  CreateGUID(g);
  Result := LowerCase(Copy(GUIDToString(g), 2, 8)) + IntToHex(FCounter, 4);
end;

function TLWSessionStore.NewSession(AMainForm: TCustomForm; const ARemoteIP: string): TLWSession;
var
  sid: string;
begin
  sid := NewSid;
  Result := TLWSession.Create(sid, AMainForm, ARemoteIP);
  FLock.Enter;
  try
    FItems.AddObject(sid, Result);
  finally
    FLock.Leave;
  end;
end;

function TLWSessionStore.Find(const ASid: string): TLWSession;
var
  i: Integer;
begin
  Result := nil;
  if ASid = '' then Exit;
  FLock.Enter;
  try
    i := FItems.IndexOf(ASid);
    if i >= 0 then
    begin
      Result := TLWSession(FItems.Objects[i]);
      Inc(Result.FRefCount);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TLWSessionStore.Release(S: TLWSession);
begin
  if S = nil then Exit;
  FLock.Enter;
  try
    Dec(S.FRefCount);
    if (S.FRefCount <= 0) and S.Marked then
    begin
      FItems.Delete(FItems.IndexOfObject(S));
      S.Free;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TLWSessionStore.Remove(const ASid: string);
var
  i: Integer;
  s: TLWSession;
begin
  FLock.Enter;
  try
    i := FItems.IndexOf(ASid);
    if i < 0 then Exit;
    s := TLWSession(FItems.Objects[i]);
    s.Marked := True;
    if s.FRefCount <= 0 then
    begin
      FItems.Delete(i);
      s.Free;
    end;
  finally
    FLock.Leave;
  end;
end;

function TLWSessionStore.Sweep(AIdleMinutes: Integer): Integer;
var
  i: Integer;
  s: TLWSession;
  deadline: TDateTime;
  dead: TList;
begin
  Result := 0;
  deadline := Now - (AIdleMinutes / (24 * 60));
  dead := TList.Create;
  FLock.Enter;
  try
    for i := 0 to FItems.Count - 1 do
    begin
      s := TLWSession(FItems.Objects[i]);
      if (s.LastAccess < deadline) and (s.FRefCount <= 0) then
        dead.Add(s);
    end;
    for i := 0 to dead.Count - 1 do
    begin
      s := TLWSession(dead[i]);
      FItems.Delete(FItems.IndexOfObject(s));
      s.Free;
      Inc(Result);
    end;
  finally
    FLock.Leave;
    dead.Free;
  end;
end;

function TLWSessionStore.Count: Integer;
begin
  FLock.Enter;
  try
    Result := FItems.Count;
  finally
    FLock.Leave;
  end;
end;

end.
