{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwwebsocket
  ------------------------------------------------------------------
  WebSocket（RFC 6455）最小实现，跑在 fphttpserver 的连接升级机制上
  （TFPCustomHttpServer.RegisterUpdateHandler —— 本机 FPC 3.3.1 trunk
  的 fphttpserver 原生支持：升级成功后连接被标记 IsUpgraded，HTTP
  keep-alive 循环不再接管 socket，所有权移交给升级处理器）。

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
  Classes, SysUtils, ssockets, sha1;

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
    if not Sock.CanRead(ATimeoutMs) then Exit;
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
  L, i: Int64;
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
    for i := 0 to 7 do
      L := (L shl 8) or hdr2[i];
  end;
  if (L < 0) or (L > WS_MAX_PAYLOAD) then Exit;
  if masked then
  begin
    if not WSReadExact(Sock, mask, 4, 5000) then Exit;
  end;
  SetLength(raw, L);
  if L > 0 then
  begin
    if not WSReadExact(Sock, raw[1], L, 10000) then Exit;
    if masked then
      for i := 0 to L - 1 do
        raw[i + 1] := AnsiChar(Byte(raw[i + 1]) xor mask[i mod 4]);
  end;
  AText := string(raw);
  Result := True;
end;

end.
