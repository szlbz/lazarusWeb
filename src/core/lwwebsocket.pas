{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwwebsocket
  ------------------------------------------------------------------
  WebSocket（RFC 6455）最小实现。

  传输层两种接法，由 FPC 版本决定（封装见 lwhttp/lwhyper）：
    - FPC 3.3.1 及以上：fphttpserver 原生支持连接升级
      （TFPCustomHttpServer.RegisterUpdateHandler）—— 升级成功后连接被标记
      IsUpgraded，HTTP keep-alive 循环不再接管 socket，所有权移交给升级处理器；
    - FPC 3.2.2：fphttpserver 没有这套机制（既没有 RegisterUpdateHandler，
      TSocketStream 也没有 CanRead / Close），改由 OnRequest 回调里手工写
      101 应答并原地跑帧循环，结束后抛异常跳出 fcl-web 的响应流程。

  本单元只做协议层（握手值、帧编解码）和两个跨版本垫片
  （LWCanRead / LWSocketClose），不关心上面两种接法。

  只实现框架需要的部分：
    - 服务端发文本帧（不掩码）
    - 客户端收文本帧（自动解掩码；忽略分片，按整帧处理）
    - ping/pong、close
  握手：Sec-WebSocket-Accept = base64(SHA1(key + 魔串))
}
unit lwwebsocket;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ssockets, sha1
  { WinSock / BaseUnix / Sockets：
      - 3.2.2 的 select 垫片（LWCanRead）需要 FD_ZERO/FD_SET/fpSelect；
      - 两个版本的 LWSocketShutdown 都要走底层句柄（TSocketStream 不导出
        shutdown，只能拿 Handle 调系统调用）。
    注意 fpShutdown 不在 BaseUnix 里，而在 Sockets 单元 —— 少了它
    Linux/macOS 交叉编译会报 "Identifier not found fpShutdown"
    （Windows 走 WinSock.shutdown，这个坑只在非 Windows 暴露）。
    3.3.1 下多引这几个 RTL 单元是新增依赖，但不改变任何既有行为。 }
  {$IFDEF MSWINDOWS}
  , WinSock          { select / FD_ZERO / FD_SET / shutdown }
  {$ELSE}
  , BaseUnix         { fpSelect / fpFD_ZERO / fpFD_SET }
  , Sockets          { fpShutdown（3.2.2/3.3.1 都在这里） }
  {$ENDIF}
  ;

type
  TWSFrameOp = (wsCont = 0, wsText = 1, wsBinary = 2, wsClose = 8,
    wsPing = 9, wsPong = 10);

const
  WS_MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
  WS_MAX_PAYLOAD = 4 * 1024 * 1024;   { 单帧上限 4MB，防恶意 }
  { WSReadFrame 首字节超时的哨兵操作码：空闲不是错误，调用方继续等
    （旧行为是 100ms 没帧就断连，浏览器端被迫 2 秒一重连，事件
    正好落在死连接上就静默丢失 —— gallery 用户看到的"点了没反应"） }
  WS_IDLE_SENTINEL = 252;

{ Sec-WebSocket-Accept 值 }
function WSAcceptValue(const AKey: string): string;

{ 发原始字节（握手应答用） }
function WSSendRaw(Sock: TSocketStream; const ABuf: AnsiString): Boolean;

{ 等 socket 可读（最多 ATimeoutMs 毫秒）。
  为什么不用 Sock.CanRead：那是 FPC 3.3.1 才给 TSocketStream 加的方法，
  3.2.2 上没有（编译报 "identifier idents no member CanRead"），而本项目
  要同时支持 3.2.2 与 3.3.1。这里用 select 自己实现，Windows 走 winsock、
  Linux/macOS 走 BaseUnix，行为与 3.3.1 的 CanRead 一致：
  返回 True = 有数据可读（或对端已关闭，Read 会立刻返回 0），
  返回 False = 超时（连接安静但可能仍然健康）。 }
function LWCanRead(Sock: TSocketStream; ATimeoutMs: Integer): Boolean;

{ 关闭底层 socket（不释放流对象）。
  3.2.2 的 TSocketStream 既没有 CanRead 也没有 Close，3.3.1 才补上；
  这里统一走底层句柄，两个版本行为一致：对端立刻收到 FIN，本地对象
  仍可继续 Free。 }
procedure LWSocketClose(Sock: TSocketStream);

{ 只做 shutdown(SHUT_RDWR)，不关闭也不释放流对象。
  用途：给"稍后还要 Free 这个流对象"的收尾路径叫醒阻塞中的读写线程 ——
  shutdown 会让对端泵线程里阻塞的 select/recv 立刻返回，真正的 close
  留给 Free 做唯一一次。为什么不直接 LWSocketClose 再 Free：
  TSocketStream.Close 不幂等（3.3.1 的 Destroy 会再 Close 一次），
  对同一个句柄 closesocket 两次，句柄被系统复用时会误关别人的连接。 }
procedure LWSocketShutdown(Sock: TSocketStream);

{ 发一帧文本（服务端帧不掩码）。成功返回 True }
function WSSendText(Sock: TSocketStream; const AText: string): Boolean;

{ 发控制帧（ping/pong/close，payload 为空） }
function WSSendControl(Sock: TSocketStream; AOp: Byte): Boolean;

{ 读一帧。ATimeoutMs 用于首字节等待；AOp 返回操作码；AText 返回文本负载。
  返回 False = 连接关闭/出错/超时 }
function WSReadFrame(Sock: TSocketStream; AFirstTimeoutMs: Integer;
  out AOp: Byte; out AText: string): Boolean;

implementation

const
  B64: array[0..63] of AnsiChar =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function WSAcceptValue(const AKey: string): string;
var
  buf: AnsiString;
  digest: TSHA1Digest;
  i, n, pad: Integer;
  b: array[0..2] of Byte;
begin
  buf := AnsiString(AKey) + WS_MAGIC;
  digest := SHA1String(buf);
  n := Length(digest);
  i := 0;
  Result := '';
  while i + 2 < n do
  begin
    b[0] := digest[i];
    b[1] := digest[i + 1];
    b[2] := digest[i + 2];
    Result := Result + B64[b[0] shr 2] +
      B64[((b[0] and 3) shl 4) or (b[1] shr 4)] +
      B64[((b[1] and $F) shl 2) or (b[2] shr 6)] +
      B64[b[2] and $3F];
    Inc(i, 3);
  end;
  pad := n mod 3;
  if pad = 1 then
  begin
    b[0] := digest[n - 1];
    Result := Result + B64[b[0] shr 2] +
      B64[(b[0] and 3) shl 4] + '==';
  end
  else if pad = 2 then
  begin
    b[0] := digest[n - 2];
    b[1] := digest[n - 1];
    Result := Result + B64[b[0] shr 2] +
      B64[((b[0] and 3) shl 4) or (b[1] shr 4)] +
      B64[(b[1] and $F) shl 2] + '=';
  end;
end;

function WSSendRaw(Sock: TSocketStream; const ABuf: AnsiString): Boolean;
begin
  try
    Sock.WriteBuffer(ABuf[1], Length(ABuf));
    Result := True;
  except
    Result := False;
  end;
end;

{ LWCanRead 实现思路：
  ① 空 socket 直接当"不可读"（调用方按出错处理）；
  ② 把 socket 句柄塞进 fd_set，超时拆成秒 + 微秒；
  ③ select 返回 >0 表示可读（含对端关闭：可读且 Read 返回 0），
     返回 0 表示超时，<0 表示出错 —— 后两种都返回 False，
     调用方据此区分不了超时与错误，与 3.3.1 的 CanRead 语义相同，
     帧循环靠"超时后发 ping 且不计错误"来兜底。
  平台差异：Windows 用 winsock.select（nfds 参数被忽略，填 0 即可）；
  Linux/macOS 用 BaseUnix.fpSelect，nfds 必须是 fd+1。 }
function LWCanRead(Sock: TSocketStream; ATimeoutMs: Integer): Boolean;
{$IF FPC_FULLVERSION >= 30301}
begin
  { 3.3.1 原生就有 CanRead：这里直接委托，行为与合并前逐字一致
    （select 垫片只在 3.2.2 下编译，不改变 3.3.1 的语义与超时精度） }
  Result := False;
  if Sock = nil then
    Exit;
  Result := Sock.CanRead(ATimeoutMs);
end;
{$ELSE}
{$IFDEF MSWINDOWS}
var
  fds: WinSock.TFDSet;
  tv: WinSock.TTimeVal;
  h: TSocket;
{$ELSE}
var
  fds: BaseUnix.TFDSet;
  tv: BaseUnix.TTimeVal;
  h: cint;
{$ENDIF}
begin
  Result := False;
  if Sock = nil then
    Exit;
  if ATimeoutMs < 0 then
    ATimeoutMs := 0;
  {$IFDEF MSWINDOWS}
  h := TSocket(Sock.Handle);
  WinSock.FD_ZERO(fds);
  WinSock.FD_SET(h, fds);
  tv.tv_sec := ATimeoutMs div 1000;
  tv.tv_usec := (ATimeoutMs mod 1000) * 1000;
  Result := WinSock.select(0, @fds, nil, nil, @tv) > 0;
  {$ELSE}
  h := cint(Sock.Handle);
  fpFD_ZERO(fds);
  fpFD_SET(h, fds);
  tv.tv_sec := ATimeoutMs div 1000;
  tv.tv_usec := (ATimeoutMs mod 1000) * 1000;
  Result := fpSelect(h + 1, @fds, nil, nil, @tv) > 0;
  {$ENDIF}
end;
{$ENDIF}

procedure LWSocketClose(Sock: TSocketStream);
begin
  if Sock = nil then
    Exit;
  try
    {$IF FPC_FULLVERSION >= 30301}
    { 3.3.1 原生有 Close：交给它（会一并清理流对象内部状态），
      与合并前各处 `try Sock.Close except end` 的行为一致 }
    Sock.Close;
    {$ELSE}
    {$IFDEF MSWINDOWS}
    CloseSocket(Longint(Sock.Handle));
    {$ELSE}
    fpClose(cint(Sock.Handle));
    {$ENDIF}
    {$ENDIF}
  except
    { 句柄可能已经被对端/析构关掉了：再关一次只是 EBADF，忽略 }
  end;
end;

procedure LWSocketShutdown(Sock: TSocketStream);
const
  { SD_BOTH（Winsock）= SHUT_RDWR（POSIX）= 2。FPC 的 WinSock 单元只导出
    shutdown 函数、不导出 SD_* 常量（常量在 WinSock2/Sockets 里），这里
    直接写数值，避免为两个常量再拖一个单元进依赖 }
  LW_SHUT_BOTH = 2;
begin
  if Sock = nil then
    Exit;
  try
    {$IFDEF MSWINDOWS}
    shutdown(TSocket(Sock.Handle), LW_SHUT_BOTH);
    {$ELSE}
    fpShutdown(cint(Sock.Handle), LW_SHUT_BOTH);
    {$ENDIF}
  except
    { 句柄无效时系统调用只返回错误码，这里兜一层异常态 }
  end;
end;

function WSSendFrame(Sock: TSocketStream; AOp: Byte; const APayload: AnsiString): Boolean;
var
  hdr: AnsiString;
  L: Integer;
begin
  L := Length(APayload);
  hdr := AnsiChar($80 or AOp);   { FIN=1 }
  if L <= 125 then
    hdr := hdr + AnsiChar(Byte(L))
  else if L <= 65535 then
    hdr := hdr + AnsiChar(126) + AnsiChar(Byte(L shr 8)) + AnsiChar(Byte(L))
  else
    hdr := hdr + AnsiChar(127) +
      AnsiChar(Byte((QWord(L) shr 56) and $FF)) +
      AnsiChar(Byte((QWord(L) shr 48) and $FF)) +
      AnsiChar(Byte((QWord(L) shr 40) and $FF)) +
      AnsiChar(Byte((QWord(L) shr 32) and $FF)) +
      AnsiChar(Byte((QWord(L) shr 24) and $FF)) +
      AnsiChar(Byte((QWord(L) shr 16) and $FF)) +
      AnsiChar(Byte((QWord(L) shr 8) and $FF)) +
      AnsiChar(Byte(QWord(L) and $FF));
  Result := WSSendRaw(Sock, hdr + APayload);
end;

function WSSendText(Sock: TSocketStream; const AText: string): Boolean;
begin
  Result := WSSendFrame(Sock, 1, AnsiString(AText));
end;

function WSSendControl(Sock: TSocketStream; AOp: Byte): Boolean;
begin
  Result := WSSendFrame(Sock, AOp, '');
end;

function WSReadExact(Sock: TSocketStream; var Buf; Count: Integer;
  ATimeoutMs: Integer): Boolean;
var
  p: PByte;
  got, n: Integer;
begin
  Result := False;
  p := @Buf;
  got := 0;
  while got < Count do
  begin
    if not LWCanRead(Sock, ATimeoutMs) then Exit;
    n := Sock.Read(p^, Count - got);
    if n <= 0 then Exit;
    Inc(p, n);
    Inc(got, n);
  end;
  Result := True;
end;

function WSReadFrame(Sock: TSocketStream; AFirstTimeoutMs: Integer;
  out AOp: Byte; out AText: string): Boolean;
var
  b0, b1: Byte;
  masked: Boolean;
  { 循环变量必须是 Integer：FPC 3.2.2 不接受 Int64 作为 for 计数器
    （报 "Ordinal expression expected"），3.3.1 才开始放开 }
  L: Int64;
  k: Integer;
  mask: array[0..3] of Byte;
  raw: AnsiString;
  hdr2: array[0..7] of Byte;
begin
  Result := False;
  AOp := 0;
  AText := '';
  if not WSReadExact(Sock, b0, 1, AFirstTimeoutMs) then
  begin
    { 区分「超时」和「出错」：CanRead 超时 = 连接安静但健康
      （对端关机会让 select 可读、Read 返回 0 走另一条路） }
    AOp := WS_IDLE_SENTINEL;
    Exit;
  end;
  if not WSReadExact(Sock, b1, 1, 5000) then Exit;
  AOp := b0 and $0F;
  masked := (b1 and $80) <> 0;
  L := b1 and $7F;
  if L = 126 then
  begin
    if not WSReadExact(Sock, hdr2, 2, 5000) then Exit;
    L := (Int64(hdr2[0]) shl 8) or hdr2[1];
  end
  else if L = 127 then
  begin
    if not WSReadExact(Sock, hdr2, 8, 5000) then Exit;
    L := 0;
    for k := 0 to 7 do
      L := (L shl 8) or hdr2[k];
  end;
  if (L < 0) or (L > WS_MAX_PAYLOAD) then Exit;
  if masked then
  begin
    if not WSReadExact(Sock, mask, 4, 5000) then Exit;
  end;
  SetLength(raw, L);
  if L > 0 then
  begin
    if not WSReadExact(Sock, raw[1], Integer(L), 10000) then Exit;
    if masked then
      for k := 0 to Integer(L) - 1 do
        raw[k + 1] := AnsiChar(Byte(raw[k + 1]) xor mask[k mod 4]);
  end;
  AText := string(raw);
  Result := True;
end;

end.
