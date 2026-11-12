{
  lazarusWeb :: lwrlog
  ------------------------------------------------------------------
  统一日志出口。以前日志直接 WriteLn，只在控制台子系统里可见：

    - GUI 编译（win32 widgetset，不带控制台窗口）下 WriteLn 无处可去，
      服务端就"哑"了 —— 用户只看到一个窗口、没有任何运行信息；
    - 服务端控制面板（lwpanel）需要在窗口里显示同样的内容。

  所以所有服务端日志都走这里，按顺序发往三个出口：

    1. 控制台    console 子系统编译时 WriteLn（tests/CI 依赖这个）；
    2. 面板回调  lwpanel 通过 LWSetLogSink 挂进来（HTTP/清扫线程都会
                 写日志，回调内部自己保证线程安全）；
    3. 日志文件  --log=path 开启，服务化部署时留证据。

  时间戳在出口处统一加：控制台/文件/面板看到的是同一行。
}
unit lwrlog;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { 面板等 UI 挂的回调；从 HTTP 线程调用，实现方必须自己处理线程安全 }
  TLWLogEvent = procedure(const ALine: string) of object;

{ 写一行日志（自动加 hh:nn:ss 前缀） }
procedure LWLog(const AText: string);
{ 写一行日志（原样，不加时间戳 —— 启动横幅这类多行排版用） }
procedure LWLogRaw(const AText: string);
{ 带格式化的便捷写法 }
procedure LWLogFmt(const AFmt: string; const AArgs: array of const);
{ 挂/摘 UI 回调（传 nil 摘掉） }
procedure LWSetLogSink(AEvent: TLWLogEvent);
{ stdout 是否真的被 RTL 打开（GUI 子系统下是 False）。
  lwapp 用它决定要不要 SetTextAutoFlush(Output) —— 对未打开的
  Output 调 SetTextAutoFlush 同样是 I/O 103 "File not open"。 }
function LWStdOutOpen: Boolean;
{ 开启文件日志；再次调用换文件。返回 False 表示打不开 }
function LWOpenLogFile(const APath: string): Boolean;
procedure LWCloseLogFile;
function LWLogFilePath: string;

implementation

var
  GSink: TLWLogEvent = nil;
  GLogF: Text;              { Text 文件变量是记录而非指针，用 GLogOpen 当开关 }
  GLogOpen: Boolean = False;
  GLogPath: string = '';
  GLock: TRTLCriticalSection;
  { 面板挂上来之前（横幅、启动警告都发生在这之前）的日志先暂存在这，
    LWSetLogSink 挂上后一次性补发，否则面板里看不到启动横幅 }
  GBacklog: TStringList = nil;

{ stdout 是否真的被 RTL 打开。GUI 子系统（-WG）下 Output.TextRec.Handle
  保持 0 —— 写它就是 I/O 103。console 子系统下 RTL 启动时已打开。 }
function LWStdOutOpen: Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := (TTextRec(Output).Handle <> 0) and
            (TTextRec(Output).Handle <> THandle(-1));
  {$ELSE}
  Result := IsConsole;
  {$ENDIF}
end;

procedure LWSetLogSink(AEvent: TLWLogEvent);
var
  i: Integer;
begin
  EnterCriticalSection(GLock);
  try
    GSink := AEvent;
    { 补发启动期的日志（横幅等），面板一打开就有内容 }
    if Assigned(AEvent) and (GBacklog <> nil) then
    begin
      for i := 0 to GBacklog.Count - 1 do
      begin
        try
          AEvent(GBacklog[i]);
        except
        end;
      end;
      GBacklog.Clear;
    end;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure LWEmit(const ALine: string);
var
  sink: TLWLogEvent;
  open: Boolean;
begin
  EnterCriticalSection(GLock);
  try
    sink := GSink;
    open := GLogOpen;
    if (sink = nil) and (GBacklog <> nil) then
    begin
      GBacklog.Add(ALine);
      while GBacklog.Count > 200 do
        GBacklog.Delete(0);
    end;
  finally
    LeaveCriticalSection(GLock);
  end;

  { 控制台：console 子系统编译时 RTL 才会打开 Output（TextRec.Handle 有效）。
    注意 IsConsole 在这里靠不住 —— GUI 子系统（-WG）下它可能仍是 True，
    但 RTL 没初始化 Output 文件变量，WriteLn 直接 I/O 103 "File not open"，
    还弹一个吓人的错误框。用 Handle 实测：没打开就绝不写。
    （GUI 构建时日志走 lwpanel 面板 / --log 文件，不亏。） }
  if LWStdOutOpen then
  begin
    try
      WriteLn(ALine);
    except
      { 输出失败不影响服务运行 }
    end;
  end;

  if Assigned(sink) then
  begin
    try
      sink(ALine);
    except
      { UI 挂了不能拖垮 HTTP 线程 }
    end;
  end;

  if open then
  begin
    try
      WriteLn(GLogF, ALine);
      Flush(GLogF);
    except
      { 磁盘满/权限等，静默 }
    end;
  end;
end;

procedure LWLog(const AText: string);
begin
  LWEmit(FormatDateTime('hh:nn:ss', Now) + '  ' + AText);
end;

procedure LWLogRaw(const AText: string);
begin
  LWEmit(AText);
end;

procedure LWLogFmt(const AFmt: string; const AArgs: array of const);
begin
  LWLog(Format(AFmt, AArgs));
end;

function LWOpenLogFile(const APath: string): Boolean;
begin
  Result := False;
  LWCloseLogFile;
  EnterCriticalSection(GLock);
  try
    {$I-}
    Assign(GLogF, APath);
    if FileExists(APath) then
      Append(GLogF)
    else
      Rewrite(GLogF);
    {$I+}
    if IOResult = 0 then
    begin
      GLogOpen := True;
      GLogPath := APath;
      Result := True;
    end;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure LWCloseLogFile;
begin
  EnterCriticalSection(GLock);
  try
    if GLogOpen then
    begin
      CloseFile(GLogF);
      GLogOpen := False;
    end;
    GLogPath := '';
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function LWLogFilePath: string;
begin
  EnterCriticalSection(GLock);
  try
    Result := GLogPath;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

initialization
  InitCriticalSection(GLock);
  GBacklog := TStringList.Create;

finalization
  LWCloseLogFile;
  GBacklog.Free;
  DoneCriticalSection(GLock);

end.
