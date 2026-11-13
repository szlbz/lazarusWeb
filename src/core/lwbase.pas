{
  lazarusWeb :: lwbase
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  ------------------------------------------------------------------
  基础类型、颜色/字体转换、JSON 小工具、会话抽象基类。

  设计要点（对照 uniGUI）：
   - uniGUI 走的是 "VCL 兼容垫片 + 自绘控件类" 的路线；
   - lazarusWeb 直接用真实 LCL 控件（TButton/TEdit/TStringGrid...），
     服务端编译时选择 nogui widgetset，不需要任何图形环境；
   - 因此业务窗体可以继续用 Lazarus 设计器拖控件，代码几乎不改。
}
unit lwbase;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, Controls, Forms, TypInfo, fpjson;

const
  LW_VERSION = '0.9.0';
  { Alpine.js 客户端外壳引用的 alpine.min.js 版本（src\client\alpine.min.js）。
    换文件时同步改这里，横幅显示用 }
  ALPINE_VERSION = '3.14.9';
  { 单个表格最多序列化的行数，防止超大表格把 JSON 撑爆 }
  LW_MAX_GRID_ROWS = 2000;

type
  { 会话抽象：让 TLWForm 能反向调用会话（避免 lwform <-> lwsession 循环引用） }
  TLWSessionBase = class(TPersistent)
  public
    { 登录/权限（lwlogin 用）。RequireAuth=True 时未认证会话只允许操作
      登录窗体上的控件（lwdispatch 在 LWHandleEvent 里拦截）。
      放在基类：lwlogin 只依赖 lwbase，不能引用具体 TLWSession }
    FRequireAuth: Boolean;
    FAuthenticated: Boolean;
    { 本会话的登录窗体（ApiSession 创建时登记，注销时重新 Show 它）}
    FLoginForm: TCustomForm;
    property RequireAuth: Boolean read FRequireAuth write FRequireAuth;
    property Authenticated: Boolean read FAuthenticated write FAuthenticated;
    property LoginForm: TCustomForm read FLoginForm write FLoginForm;
    { 模态显示一个窗体：推送渲染指令给浏览器，然后阻塞当前请求线程等待结果 }
    function ShowModalInSession(AForm: TCustomForm): Integer; virtual; abstract;
    { 窗体被关闭（含 ModalResult 设定） }
    procedure SessionEndModal(AForm: TCustomForm; AResult: Integer); virtual; abstract;
    { 向浏览器推送一条异步指令（弹窗、消息框、局部刷新） }
    procedure SessionPushCommand(const ACmdJson: string); virtual; abstract;
    { 服务端日志 }
    procedure SessionNotify(const AText: string); virtual; abstract;
    { 判断某个窗体当前是否处于模态中 }
    function SessionIsModal(AForm: TCustomForm): Boolean; virtual; abstract;
    { 业务代码调用 Form.Show / Visible:=True 时走这里（nogui 下真正的
      TCustomForm.Show 会在 LCL 内部除零崩溃，Web 模式不需要真窗口） }
    procedure SessionShowForm(AForm: TCustomForm); virtual; abstract;
    { 业务代码调用 Form.Hide / Visible:=False / Close 时走这里 }
    procedure SessionHideForm(AForm: TCustomForm); virtual; abstract;
    { 按窗体名在会话里找已经存在（且已显示）的窗体。
      登录成功后用它复用已有的主窗体 —— 否则"注销 -> 再登录"会
      每轮多造一个主窗体，数据库连接也跟着翻倍 }
    function SessionFindForm(const AName: string): TCustomForm; virtual; abstract;
    { 窗体要被释放了：从会话清单里摘掉（否则下一次序列化会访问已释放对象） }
    procedure SessionForgetForm(AForm: TCustomForm); virtual; abstract;
    { 会话级键值区：登录名、角色、租户这类"这个人是谁"的信息必须存在
      会话上。用进程级全局变量会把 A 用户的身份带给同一进程里的 B 用户
      （浏览器多开、多页签时非常明显） }
    function SessionGetVar(const AName: string): string; virtual; abstract;
    procedure SessionSetVar(const AName, AValue: string); virtual; abstract;

    { 在浏览器里弹一个模态框并挂起当前线程等结果。
      ASpecJson 由 lwdlg 生成（kind / caption / text / buttons / input ...），
      返回 True 表示用户确实作了选择（AResult 是某个按钮的 id，
      AText 是输入框的值）；返回 False 表示没有浏览器可弹或等待超时 ——
      调用方应当退回"取消"语义。 }
    function SessionDialog(const ASpecJson: string; out AResult: Integer;
      out AText: string): Boolean; virtual; abstract;

    { 当前 Web 可见（浏览器上还开着的）窗体数。
      最后一个可见窗体被关掉后回登录页用。 }
    function VisibleWebFormCount: Integer; virtual; abstract;

    { 会话专属的临时目录（不存在则创建，返回带结尾分隔符的绝对路径）。
      选文件对话框存上传文件、保存对话框给目标路径都用它。 }
    function SessionTempDir(const ASub: string = ''): string; virtual; abstract;
  end;

  { 组件 -> 稳定整数 ID 的映射，由会话提供 }
  TLWIdFunc = function(C: TComponent): Integer of object;

threadvar
  { 当前正在处理事件的会话；TLWForm.ShowModal 用它来决定走 Web 分支还是本地分支 }
  LWCurrentSession: TLWSessionBase;

{ ---- 小工具 ---- }
function IsLWClickEvent(const AName: string): Boolean;
function ColorToCSS(C: TColor): string;
function ColorIsSystem(C: TColor): Boolean;
function FontToJSON(F: TFont): TJSONObject;
function AlignToStr(A: TAlign): string;
function BorderStyleToStr(A: TBorderStyle): string;
function Base64FromStream(AStream: TStream): string;
function BoolToInt(B: Boolean): Integer;
{ HTTP 状态行文本（如 200 -> 'OK'、404 -> 'Not Found'）。
  为什么不直接用 fcl-web 的 GetHTTPStatusText：那是 FPC 3.3.1 才有的函数，
  3.2.2 的 httpprotocol 里没有（编译报 "Identifier not found"）。这里自带
  一份码表，两个 FPC 版本给出完全一致的状态行文本，也省掉 lwcore 对
  fcl-web 的依赖。客户端只认数字码，文本仅用于日志/调试可读性。 }
function LWHTTPStatusText(ACode: Integer): string;
{ 上传/浏览器选文件等服务端落地文件的根目录：默认 <exe目录>/uploads/，
  与"配置文件保存到 exe 目录"的部署约定一致；exe 旁不可写时自动退回
  <临时目录>/uploads/。部署/业务可在启动早期赋 LWUploadRoot 覆盖。 }
function LWUploadRootDir: string;
var
  LWUploadRoot: string = '';   { 非空 = 强制指定上传根目录 }
{ 去掉 LCL 流式加载自动加的 "_N" 数字后缀：FooForm_3 -> FooForm。
  一个进程同时服务多个会话时，同名窗体会被实例化多次；LCL 的 TReader
  发现「全局已有同名窗体」就把名字改成 FooForm_1。但窗体名是框架识别
  窗体的依据（登录窗体 / 默认窗体 / 会话内查找），必须还原成设计期名字。 }
function LWStripUniqSuffix(const AName: string): string;

{ LCL 全局闸门 —— LCL 不是线程安全的，下面这些动作必须串行：
    - 建窗体（TBitBtn 构造时会解码 LCLGlyphs 的标准字形位图）
    - 释放窗体（销毁时释放字形/位图，同样动全局缓存）
    - 序列化组件树（writer 读控件属性，含位图/画布度量）
  几个线程同时干这些事会踩坏 Graphics / FPImage 的全局缓存，症状是同一
  时刻冒出 FPImageException("Failed to get raw image description from
  bitmap")、EConvertError、EAccessViolation 三连，随后进程直接死掉
  （gallery demo 实测 5~6 个浏览器同时首开必崩）。

  为什么只锁这三处：事件处理里可能有 ShowModal 阻塞几分钟，把事件也塞进
  闸门会把所有会话一起冻住；而事件对控件的改写是"各改各的窗体"，实测并
  发安全。TRTLCriticalSection 在同一线程内可重入，嵌套调用无需额外判断。 }
procedure LWLCLEnter;
procedure LWLCLLeave;

{ ---- 增量补丁总开关（lwapp 解析 --patch=1 后置位）----
  置 False 时 TLWSession 完全不维护树快照与版本号，走老的全量路径。
  放全局而不是放配置记录：lwsession 不能依赖 lwhttp（会循环引用）。 }
var
  LWServerPatchMode: Boolean = False;

{ ---- 单调微秒时钟 ----
  剖析用。GetTickCount64 的精度在 Windows 上是 15.6ms（Linux 上 1ms），
  量一次 1~2ms 的 diff 全是 0 或者 16，等于没测，所以必须用高精度计数器。
  Windows 走 QueryPerformanceCounter，Unix 走 gettimeofday —— 两条分支
  都返回"微秒"这一个语义，调用方不用关心平台。
  注意：这里刻意不是"只在 Windows 上定义、别处不实现"，那样 Linux 下会
  直接"标识符未定义"编不过（这条踩过）。 }
function LWNowUS: Int64;

{ ---- JSON 读取辅助 ---- }
function JGetStr(O: TJSONObject; const AName: string; const ADef: string = ''): string;function JGetInt(O: TJSONObject; const AName: string; ADef: Integer = 0): Integer;
function JGetBool(O: TJSONObject; const AName: string; ADef: Boolean = False): Boolean;
function JGetObj(O: TJSONObject; const AName: string): TJSONObject;
{ fpjson 的 TJSONArray.Add 对字符串常量有重载歧义，统一走这两个helper }
procedure JArrAddStr(A: TJSONArray; const S: string);
function JArrHasStr(A: TJSONArray; const S: string): Boolean;

implementation

{$IFDEF UNIX}
uses
  { fpgettimeofday 只在 Unix 单元里（BaseUnix 没有），签名收的是指针 }
  Unix;
{$ENDIF}

{$IFDEF MSWINDOWS}
function QueryPerformanceCounter(out lpPerformanceCount: Int64): LongBool;
  stdcall; external 'kernel32' name 'QueryPerformanceCounter';
function QueryPerformanceFrequency(out lpFrequency: Int64): LongBool;
  stdcall; external 'kernel32' name 'QueryPerformanceFrequency';
{$ENDIF}

var
  GNowUSFreq: Int64 = 0;

function LWNowUS: Int64;
{$IFDEF MSWINDOWS}
var
  c: Int64;
{$ENDIF}
{$IFDEF UNIX}
var
  tv: TTimeVal;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  if GNowUSFreq = 0 then
  begin
    if (not QueryPerformanceFrequency(GNowUSFreq)) or (GNowUSFreq <= 0) then
      GNowUSFreq := 1000;
  end;
  QueryPerformanceCounter(c);
  Result := c * 1000000 div GNowUSFreq;
  {$ELSE}
  {$IFDEF UNIX}
  if fpgettimeofday(@tv, nil) = 0 then
    Result := Int64(tv.tv_sec) * 1000000 + Int64(tv.tv_usec)
  else
    Result := Int64(GetTickCount64) * 1000;
  {$ELSE}
  Result := Int64(GetTickCount64) * 1000;
  {$ENDIF}
  {$ENDIF}
end;

function IsLWClickEvent(const AName: string): Boolean;
begin
  { 只放行"单参数 (Sender: TObject)"形式的事件，方法指针调用才安全。
    OnTitleClick / OnCellClick 是 TDBGrid 的 (Column: TColumn) 形式，
    由 lwdispatch 单独走类型化调用，列在这里只是为了让 writer 把它们
    写进 ev 列表，浏览器才知道该绑哪个 DOM 事件 }
  Result := (AName = 'OnClick') or (AName = 'OnDblClick') or (AName = 'OnChange') or
    (AName = 'OnEnter') or (AName = 'OnExit') or (AName = 'OnSelect') or
    (AName = 'OnShow') or (AName = 'OnHide') or (AName = 'OnActivate') or
    (AName = 'OnDeactivate') or (AName = 'OnEditingDone') or
    (AName = 'OnTitleClick') or (AName = 'OnCellClick') or
    (AName = 'OnColEnter') or (AName = 'OnColExit') or
    { TCheckGroup.OnItemClick 是 (Sender; Index) 两参、TValueListEditor.OnValidate
      是 (Sender; ACol; ARow; KeyName; KeyValue) 五参，由 lwdispatch 单独走
      类型化调用；列在这里只是让 writer 把它们写进 ev 列表 }
    (AName = 'OnItemClick') or (AName = 'OnValidate') or
    (AName = 'OnClickCheck') or
    { TCustomEditButton 的"…"按钮（TFileNameEdit 等，TNotifyEvent，安全） }
    (AName = 'OnButtonClick') or
    { TLWColorPicker 的选色事件（TNotifyEvent，单参数，安全） }
    (AName = 'OnColorChange');
end;

function ColorIsSystem(C: TColor): Boolean;
begin
  { LCL 的系统色带 $80000000 标志位 }
  Result := (LongInt(C) and LongInt($80000000)) <> 0;
end;

function ColorToCSS(C: TColor): string;
var
  v: LongInt;
  r, g, b: Byte;
begin
  Result := '';
  if C = clNone then Exit;
  { clDefault 是 $20000000，直接按 RGB 拆会得到 #000020（近黑）——
    窗体/面板的默认色、label 的默认字色全变成黑底黑字。
    它表示"用系统默认"，和系统色一样交给 CSS 主题决定。 }
  if C = clDefault then Exit;
  v := LongInt(C);
  if (v and LongInt($80000000)) <> 0 then
  begin
    { 系统色交给主题去决定，避免把 clBtnFace 画成纯黑 }
    case v and $FFFFFF of
      $0F: Result := '';         // clBtnFace
      $0B: Result := '';         // clWindow
      $05: Result := '';         // clMenu
      $0D: Result := '';         // clHighlight
    else
      Result := '';
    end;
    Exit;
  end;
  r := v and $FF;
  g := (v shr 8) and $FF;
  b := (v shr 16) and $FF;
  Result := Format('#%.2x%.2x%.2x', [r, g, b]);
end;

function FontToJSON(F: TFont): TJSONObject;
var
  st: string;
begin
  Result := TJSONObject.Create;
  if F = nil then Exit;
  Result.Add('name', F.Name);
  Result.Add('size', F.Size);
  st := '';
  if fsBold in F.Style then st := st + 'b';
  if fsItalic in F.Style then st := st + 'i';
  if fsUnderline in F.Style then st := st + 'u';
  Result.Add('style', st);
  Result.Add('color', ColorToCSS(F.Color));
end;

function AlignToStr(A: TAlign): string;
begin
  case A of
    alTop: Result := 'top';
    alBottom: Result := 'bottom';
    alLeft: Result := 'left';
    alRight: Result := 'right';
    alClient: Result := 'client';
    alCustom: Result := 'custom';
  else
    Result := 'none';
  end;
end;

function BorderStyleToStr(A: TBorderStyle): string;
begin
  if A = bsSingle then Result := 'single' else Result := 'none';
end;

function LWUploadRootDir: string;
var
  d: string;
begin
  if LWUploadRoot <> '' then
    d := IncludeTrailingPathDelimiter(LWUploadRoot)
  else
    d := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
      'uploads' + PathDelim;
  if not ForceDirectories(d) then
    { exe 旁不可写（例如部署到 Program Files 且无权限）→ 退回系统临时目录，
      保证上传永远有地方落盘 }
    d := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'uploads' + PathDelim;
  ForceDirectories(d);
  Result := d;
end;

function Base64FromStream(AStream: TStream): string;
const
  Tbl: array[0..63] of Char =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  buf: array[0..2] of Byte;
  n: Integer;
begin
  Result := '';
  if AStream = nil then Exit;
  AStream.Position := 0;
  while True do
  begin
    n := AStream.Read(buf[0], 3);
    if n <= 0 then Break;
    if n = 1 then
    begin
      Result := Result + Tbl[buf[0] shr 2];
      Result := Result + Tbl[(buf[0] and 3) shl 4];
      Result := Result + '==';
      Break;
    end
    else if n = 2 then
    begin
      Result := Result + Tbl[buf[0] shr 2];
      Result := Result + Tbl[((buf[0] and 3) shl 4) or (buf[1] shr 4)];
      Result := Result + Tbl[(buf[1] and $0F) shl 2];
      Result := Result + '=';
      Break;
    end
    else
    begin
      Result := Result + Tbl[buf[0] shr 2];
      Result := Result + Tbl[((buf[0] and 3) shl 4) or (buf[1] shr 4)];
      Result := Result + Tbl[((buf[1] and $0F) shl 2) or (buf[2] shr 6)];
      Result := Result + Tbl[buf[2] and $3F];
    end;
    { 避免超长字符串反复分配时的极端内存压力 }
    if Length(Result) > 8 * 1024 * 1024 then Break;
  end;
end;

function BoolToInt(B: Boolean): Integer;
begin
  if B then Result := 1 else Result := 0;
end;

{ 状态码 -> 状态行文本。实现思路：一张只含框架真正会用到的码（另加常见码）
  的 case 表，纯 RTL 实现，两个 FPC 版本行为一致；表外的合法码给
  "Status <码>"，非法码给 "Unknown"。 }
function LWHTTPStatusText(ACode: Integer): string;
begin
  case ACode of
    100: Result := 'Continue';
    101: Result := 'Switching Protocols';
    200: Result := 'OK';
    201: Result := 'Created';
    202: Result := 'Accepted';
    204: Result := 'No Content';
    206: Result := 'Partial Content';
    301: Result := 'Moved Permanently';
    302: Result := 'Found';
    303: Result := 'See Other';
    304: Result := 'Not Modified';
    307: Result := 'Temporary Redirect';
    308: Result := 'Permanent Redirect';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    408: Result := 'Request Timeout';
    409: Result := 'Conflict';
    410: Result := 'Gone';
    413: Result := 'Payload Too Large';
    415: Result := 'Unsupported Media Type';
    416: Result := 'Range Not Satisfiable';
    422: Result := 'Unprocessable Entity';
    429: Result := 'Too Many Requests';
    500: Result := 'Internal Server Error';
    501: Result := 'Not Implemented';
    502: Result := 'Bad Gateway';
    503: Result := 'Service Unavailable';
    504: Result := 'Gateway Timeout';
  else
    if (ACode >= 100) and (ACode < 600) then
      Result := 'Status ' + IntToStr(ACode)
    else
      Result := 'Unknown';
  end;
end;

function LWStripUniqSuffix(const AName: string): string;
var
  p, i: Integer;
begin
  Result := AName;
  p := LastDelimiter('_', AName);
  if (p <= 1) or (p >= Length(AName)) then Exit;
  for i := p + 1 to Length(AName) do
    if not (AName[i] in ['0'..'9']) then Exit;
  Result := Copy(AName, 1, p - 1);
end;

function JGetStr(O: TJSONObject; const AName: string; const ADef: string): string;
var
  d: TJSONData;
begin
  Result := ADef;
  if O = nil then Exit;
  d := O.Find(AName);
  if (d <> nil) and (d.JSONType <> jtNull) then
    Result := d.AsString;
end;

function JGetInt(O: TJSONObject; const AName: string; ADef: Integer): Integer;
var
  d: TJSONData;
begin
  Result := ADef;
  if O = nil then Exit;
  d := O.Find(AName);
  if (d <> nil) and (d.JSONType <> jtNull) then
    Result := d.AsInteger;
end;

function JGetBool(O: TJSONObject; const AName: string; ADef: Boolean): Boolean;
var
  d: TJSONData;
begin
  Result := ADef;
  if O = nil then Exit;
  d := O.Find(AName);
  if (d <> nil) and (d.JSONType <> jtNull) then
    Result := d.AsBoolean;
end;

function JGetObj(O: TJSONObject; const AName: string): TJSONObject;
var
  d: TJSONData;
begin
  Result := nil;
  if O = nil then Exit;
  d := O.Find(AName);
  if (d <> nil) and (d.JSONType = jtObject) then
    Result := TJSONObject(d);
end;

{ fpjson 的 TJSONArray.Add 对字符串常量有重载歧义，统一走这两个 helper }
procedure JArrAddStr(A: TJSONArray; const S: string);
begin
  A.Add(TJSONString.Create(S));
end;

function JArrHasStr(A: TJSONArray; const S: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if A = nil then Exit;
  for i := 0 to A.Count - 1 do
    if A.Items[i].AsString = S then
      Exit(True);
end;

{ ---------------- LCL 全局闸门 ---------------- }

var
  GLCLGate: TRTLCriticalSection;
  GLCLGateReady: Boolean = False;

procedure LWLCLEnter;
begin
  if GLCLGateReady then
    EnterCriticalSection(GLCLGate);
end;

procedure LWLCLLeave;
begin
  if GLCLGateReady then
    LeaveCriticalSection(GLCLGate);
end;

initialization
  InitCriticalSection(GLCLGate);
  GLCLGateReady := True;

finalization
  GLCLGateReady := False;
  DoneCriticalSection(GLCLGate);

end.
