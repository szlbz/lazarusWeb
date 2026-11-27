unit lwpluginguard;
{ lazarusWeb :: 插件启动守卫（src/core 共用单元）

  从 demos/pluginsDemo/common/upluginguard.pas 上提到核心：lwhyper 插件模式
  与 pluginsDemo 宿主共用同一份 secret 与口令算法。demo 侧的 upluginguard
  现在只是本单元的 re-export 包装，避免两处口令漂移。

  目的：插件的 exe 不能单独运行。双击、命令行、被别人 Start-Process 时，
  插件自己要能识别出来 —— 打印/弹窗提示一句"请从主程序进入"，然后退出。

  宿主（upluginproc.StartOne）每次拉起插件时现取一个 nonce，算出口令，三条参数：

      --lw-plug-nonce=<unix 秒>-<随机 32 位十六进制>
      --lw-plug-token=SHA1(secret|nonce)        小写十六进制
      --lw-plug-host=<宿主 exe 文件名，如 pluginsdemo.exe>

  插件 .lpr 的第一句调 PlugGuardCheck，逐条验：

      1. 三条参数都在          —— 少了它就不是宿主起的
      2. nonce 时间戳没过期     —— 挡住"把抓到的命令行存下来以后再重放"
      3. token 对得上          —— 光知道格式没用，得有 secret
      4. 父进程 exe 名与 --lw-plug-host 一致（仅 Windows）—— 光有 secret 也没用，
                                  还得是被主程序拉起来的子进程

  任何一条不过：提示 + Halt(3)。宿主侧 StartOne 看到了就记一条日志。

  改 secret：把 PlugGuardSecretHex 换成自己的随机串（两边共用本单元，改一处即可），
  重新编译宿主与全部插件。写成十六进制字符串是为了不在 exe 里留下明文可读的口令。
}
{$mode objfpc}{$H+}

interface

const
  PlugGuardTokenParam = '--lw-plug-token=';
  PlugGuardNonceParam = '--lw-plug-nonce=';
  PlugGuardHostParam  = '--lw-plug-host=';
  { nonce 里时间戳允许的偏差（秒）。宿主一拉起就校验，正常不会超过几秒；
    留 120 秒是给慢机器 / 调试断点用的 }
  PlugGuardMaxSkewSec = 120;
  { 身份头时间戳允许偏差（秒）。lwhyper 与 pluginsDemo 宿主签发、插件验签
    共用这一常量，避免两边各自写 60 后漂移 }
  PlugIdentityMaxSkewSec = 60;
  { 守卫拒绝时的退出码，宿主/脚本可据此判断"是被拦下的插件" }
  PlugGuardExitCode = 3;

{ 共享口令原文（由 PlugGuardSecretHex 解码而来） }
function PlugGuardSecret: string;
{ SHA1(secret + '|' + nonce) 的小写十六进制 }
function PlugGuardToken(const ANonce: string): string;
{ 宿主用：<unix 秒>-<随机 32 位十六进制> }
function PlugGuardNewNonce: string;
{ 取 --xxx=value 形式的命令行参数，没有返回空串 }
function PlugGuardArg(const APrefix: string): string;
{ 只校验不退出；AReason 给内部原因码：'' = 通过，
  'missing' / 'stale' / 'badtoken' / 'nothost' 见 PlugGuardReasonText }
function PlugGuardValidate(out AReason: string): Boolean;
{ 原因码 -> 给用户看的中文说明 }
function PlugGuardReasonText(const AReason: string): string;
{ 插件的 .lpr 第一句：校验失败就提示并 Halt(PlugGuardExitCode)。ATitle 拼提示语用 }
procedure PlugGuardCheck(const ATitle: string);

implementation

uses
  SysUtils, DateUtils,
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  sha1;

const
  { 'lazarusWeb/plugin-guard/v1-2f9c' 的十六进制。改这里 = 换口令。 }
  PlugGuardSecretHex = '6C617A617275735765622F706C7567696E2D67756172642F76312D32663963';

function HexToStr(const AHex: string): string;
var
  i, n: Integer;
  b: Byte;
begin
  Result := '';
  i := 1;
  n := Length(AHex);
  while i + 1 <= n do
  begin
    b := StrToIntDef('$' + Copy(AHex, i, 2), 0);
    if b <> 0 then Result := Result + Chr(b);
    Inc(i, 2);
  end;
end;

function PlugGuardSecret: string;
begin
  Result := HexToStr(PlugGuardSecretHex);
end;

function PlugGuardToken(const ANonce: string): string;
begin
  Result := LowerCase(SHA1Print(SHA1String(PlugGuardSecret + '|' + ANonce)));
end;

function PlugGuardNewNonce: string;
var
  r: LongWord;
begin
  r := LongWord(Random(MaxInt)) shl 16 xor LongWord(Random(MaxInt));
  Result := IntToStr(DateTimeToUnix(Now, False)) + '-' + IntToHex(r, 8);
end;

function PlugGuardArg(const APrefix: string): string;
var
  i: Integer;
  s: string;
begin
  Result := '';
  for i := 1 to ParamCount do
  begin
    s := ParamStr(i);
    if (Length(s) > Length(APrefix)) and
       (Copy(s, 1, Length(APrefix)) = APrefix) then
      Exit(Copy(s, Length(APrefix) + 1, MaxInt));
  end;
end;

{$IFDEF MSWINDOWS}
type
  TProcessBasicInformation = record
    ExitStatus: LongInt;
    PebBaseAddress: Pointer;
    AffinityMask: PtrUInt;
    BasePriority: LongInt;
    UniqueProcessId: PtrUInt;
    InheritedFromUniqueProcessId: PtrUInt;
  end;

function NtQueryInformationProcess(ProcessHandle: THandle;
  ProcessInformationClass: DWORD; ProcessInformation: Pointer;
  ProcessInformationLength: ULONG; ReturnLength: PULONG): LongInt; stdcall;
  external 'ntdll.dll' name 'NtQueryInformationProcess';

{ 父进程的 exe 全路径；取不到返回空串（例如父进程已退出并被回收） }
function ParentExePath: string;
var
  pbi: TProcessBasicInformation;
  ret: ULONG;
  ppid: DWORD;
  h: THandle;
  buf: array[0..1023] of WideChar;
  size: DWORD;
begin
  Result := '';
  FillChar(pbi, SizeOf(pbi), 0);
  if NtQueryInformationProcess(GetCurrentProcess, 0, @pbi, SizeOf(pbi), @ret) <> 0 then Exit;
  ppid := DWORD(pbi.InheritedFromUniqueProcessId);
  if ppid = 0 then Exit;
  h := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, ppid);
  if h = 0 then Exit;
  try
    size := SizeOf(buf) div SizeOf(WideChar);
    if QueryFullProcessImageNameW(h, 0, @buf[0], @size) then
      Result := UTF8Encode(WideString(buf));
  finally
    CloseHandle(h);
  end;
end;
{$ENDIF}

function PlugGuardValidate(out AReason: string): Boolean;
var
  tok, non, host, p, parent: string;
  t, nowsec, dash: Int64;
begin
  AReason := '';
  Result := False;
  tok  := PlugGuardArg(PlugGuardTokenParam);
  non  := PlugGuardArg(PlugGuardNonceParam);
  host := PlugGuardArg(PlugGuardHostParam);
  if (tok = '') or (non = '') or (host = '') then
  begin
    AReason := 'missing';
    Exit;
  end;

  dash := Pos('-', non);
  if dash <= 1 then
  begin
    AReason := 'badtoken';
    Exit;
  end;
  t := StrToInt64Def(Copy(non, 1, dash - 1), 0);
  nowsec := DateTimeToUnix(Now, False);
  if (t = 0) or (Abs(nowsec - t) > PlugGuardMaxSkewSec) then
  begin
    AReason := 'stale';
    Exit;
  end;

  if LowerCase(tok) <> PlugGuardToken(non) then
  begin
    AReason := 'badtoken';
    Exit;
  end;

  {$IFDEF MSWINDOWS}
  parent := ParentExePath;
  if parent = '' then
  begin
    { 父进程查不到（被强杀/被回收）也算不通过：宁可让用户重开主程序 }
    AReason := 'nothost';
    Exit;
  end;
  if not SameText(ExtractFileName(parent), host) then
  begin
    AReason := 'nothost';
    Exit;
  end;
  {$ENDIF}

  Result := True;
end;

function PlugGuardReasonText(const AReason: string): string;
begin
  if AReason = 'missing' then
    Result := '缺少主程序下发的启动令牌'
  else if AReason = 'stale' then
    Result := '启动令牌已过期（超过 ' + IntToStr(PlugGuardMaxSkewSec) + ' 秒）'
  else if AReason = 'badtoken' then
    Result := '启动令牌校验不通过'
  else if AReason = 'nothost' then
    Result := '不是由主程序拉起的子进程'
  else
    Result := '未知原因（' + AReason + '）';
end;

{$IFDEF MSWINDOWS}
{ 真正的控制台上按控制台代码页（中文 Windows 是 936）输出，否则中文会是乱码；
  没有控制台（输出被重定向到管道 / 宿主 poNoConsole）就原样给 UTF-8 字节，
  让抓取方按 UTF-8 读 }
function ConsoleText(const S: string): RawByteString;
var
  ws: UnicodeString;
  cp: UINT;
  n: Integer;
  h: THandle;
begin
  { 只有 stderr 还挂在字符设备（真控制台）时才转代码页；
    重定向到文件/管道就给 UTF-8 字节，读的一方按 UTF-8 处理 }
  h := GetStdHandle(STD_ERROR_HANDLE);
  if (h = 0) or (h = INVALID_HANDLE_VALUE) or (GetFileType(h) <> FILE_TYPE_CHAR) then
    Exit(RawByteString(S));
  cp := GetConsoleOutputCP;
  if cp = 0 then cp := CP_ACP;
  ws := UTF8Decode(S);
  n := WideCharToMultiByte(cp, 0, PWideChar(ws), Length(ws), nil, 0, nil, nil);
  SetLength(Result, n);
  if n > 0 then
    WideCharToMultiByte(cp, 0, PWideChar(ws), Length(ws), PAnsiChar(Result), n, nil, nil);
end;
{$ELSE}
function ConsoleText(const S: string): RawByteString;
begin
  Result := RawByteString(S);
end;
{$ENDIF}

{ 直接往 stderr 句柄写字节：走 Write(ErrOutput) 的话 FPC 会按默认代码页
  再转一次，编码就对不上了。没有控制台/句柄无效时静默跳过。 }
procedure DumpStdErr(const S: string);
var
  b: RawByteString;
begin
  b := ConsoleText(S);
  if Length(b) = 0 then Exit;
  try
    FileWrite(StdErrorHandle, PAnsiChar(b)^, Length(b));
  except
    { 句柄不可写（poNoConsole）就不写，提示交给消息框 }
  end;
end;

{ 提示 + 退出。三种启动方式各有各的输出通道：
    双击        -> 控制台子系统会开个窗口，文字一闪就没，必须靠消息框
    命令行      -> 控制台里能看到文字
    Host 拉起但令牌不对（改了口令只重编了一边）
                -> 没有控制台，且**不弹消息框**：宿主正在等端口，弹个模态框
                   会把宿主的启动流程卡满 10 秒、还留一个没人点的窗口在桌面上
   脚本/CI     -> LW_PLUGIN_GUARD_NOUI=1，只写 stderr 和日志 }
procedure PlugGuardCheck(const ATitle: string);
var
  reason, msg, logFile, line: string;
  showBox: Boolean;
  {$IFDEF MSWINDOWS}
  ws: WideString;
  {$ENDIF}
  f: TextFile;
begin
  if PlugGuardValidate(reason) then Exit;

  { 一个参数都没带 = 用户自己双击/命令行起；带了但不对 = 被程序拉起。
    后者只写日志和 stderr，别弹窗。 }
  showBox := reason = 'missing';

  if showBox then
    msg := '「' + ATitle + '」是 lazarusWeb 的插件程序，不能单独运行。' + LineEnding +
      LineEnding +
      '请先启动主程序，再从左侧菜单打开它。' + LineEnding +
      '（若主程序已异常退出，可运行 stop-all.bat 清理残留插件进程。）'
  else
    msg := '「' + ATitle + '」启动被拒绝：' + PlugGuardReasonText(reason) + LineEnding +
      LineEnding +
      '宿主与插件的启动口令不一致 —— 改过 common\upluginguard.pas 之后' + LineEnding +
      '宿主和全部插件都要重编（跑 build.bat / build-all.bat）。';

  msg := msg + LineEnding + LineEnding +
    '拒绝原因：' + PlugGuardReasonText(reason) + ' [' + reason + ']';

  DumpStdErr(LineEnding + msg + LineEnding + LineEnding);

  { 插件目录下留一行记录，方便排查"为什么插件没起来" }
  try
    logFile := ExtractFilePath(ParamStr(0)) + 'plugin-guard.log';
    AssignFile(f, logFile);
    if FileExists(logFile) then Append(f) else Rewrite(f);
    try
      line := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + '  pid=' +
        IntToStr(GetProcessID) + '  ' + reason;
      WriteLn(f, line);
    finally
      CloseFile(f);
    end;
  except
    { 日志写不了不影响主流程 }
  end;

  {$IFDEF MSWINDOWS}
  { 脚本 / CI 里跑守卫自检时设 LW_PLUGIN_GUARD_NOUI=1：只写日志和 stderr，
    不弹消息框（否则自动化会卡在窗口上等人点确定）。正常使用不要设它。 }
  if showBox and (SysUtils.GetEnvironmentVariable('LW_PLUGIN_GUARD_NOUI') <> '1') then
  begin
    ws := UTF8Decode(msg);
    MessageBoxW(0, PWideChar(ws), PWideChar(UTF8Decode('插件启动被拒绝')),
      MB_OK or MB_ICONWARNING or MB_TOPMOST);
  end;
  {$ENDIF}

  Halt(PlugGuardExitCode);
end;

initialization
  Randomize;

end.
