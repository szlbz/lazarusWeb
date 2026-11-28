{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwpwa
  ------------------------------------------------------------------
  PWA 服务端公共层：manifest / Service Worker / 图标 / 订阅存储 / Web Push。

  设计约束：
    - 全局关闭时本单元不接管任何请求，既有应用行为逐字节不变；
    - 只服务静态资源与 PWA 自己的端点，绝不缓存 /lw/api/* 等会话数据；
    - Web Push 采用 "tickle"（空负载）+ /lw/pwa/message 取消息，避免实现
      aes128gcm 加密负载；订阅端点仍用 VAPID ES256 鉴权。
}
unit lwpwa;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fphttpserver, httpdefs, httpprotocol;

type
  TLWPWAOptions = record
    Enabled: Boolean;
    Name: string;
    ShortName: string;
    ThemeColor: string;
    BackgroundColor: string;
    VAPIDPublic: string;
    VAPIDPrivate: string;
    VAPIDSubject: string;
    PushToken: string;
    PushFile: string;
    MessageFile: string;
    Root: string;
    Version: string;
  end;

procedure LWPWAConfigure(const AName, AShortName, AThemeColor, ABackgroundColor,
  AVAPIDPublic, AVAPIDPrivate, AVAPIDSubject, APushToken, APushFile,
  AMessageFile, ARoot, AVersion: string; AEnabled: Boolean);
function LWPWAEnabled: Boolean;
function LWPWAPushEnabled: Boolean;
function LWPWAHeadHtml(const ABase: string): string;
function LWPWAScriptHtml(const ABase: string): string;
function LWPWAIsPath(const APath: string): Boolean;
function LWPWAHandle(ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse): Boolean;
implementation

uses
  DateUtils, SyncObjs, fpjson, jsonparser, base64, fphttpclient, openssl, lwrlog;

const
  LW_PWA_MAX_SUBS = 1000;

var
  GOptions: TLWPWAOptions;
  GLock: TRTLCriticalSection;
  GLockReady: Boolean = False;

procedure LWPWAConfigure(const AName, AShortName, AThemeColor, ABackgroundColor,
  AVAPIDPublic, AVAPIDPrivate, AVAPIDSubject, APushToken, APushFile,
  AMessageFile, ARoot, AVersion: string; AEnabled: Boolean);
begin
  if not GLockReady then
  begin
    InitCriticalSection(GLock);
    GLockReady := True;
  end;
  GOptions.Enabled := AEnabled;
  GOptions.Name := AName;
  GOptions.ShortName := AShortName;
  GOptions.ThemeColor := AThemeColor;
  GOptions.BackgroundColor := ABackgroundColor;
  GOptions.VAPIDPublic := AVAPIDPublic;
  GOptions.VAPIDPrivate := AVAPIDPrivate;
  GOptions.VAPIDSubject := AVAPIDSubject;
  GOptions.PushToken := APushToken;
  GOptions.PushFile := APushFile;
  GOptions.MessageFile := AMessageFile;
  GOptions.Root := ARoot;
  if AVersion = '' then GOptions.Version := '1' else GOptions.Version := AVersion;
end;

function LWPWAEnabled: Boolean;
begin
  Result := GOptions.Enabled;
end;

function LWPWAPushEnabled: Boolean;
begin
  Result := GOptions.Enabled and (GOptions.VAPIDPublic <> '') and
    (GOptions.VAPIDPrivate <> '');
end;

function LWPWAIsPath(const APath: string): Boolean;
begin
  Result := False;
  if not GOptions.Enabled then Exit;
  Result := (APath = '/lw/manifest.webmanifest') or (APath = '/lw/sw.js') or
    (APath = '/lw/pwa.js') or (APath = '/lw/icon-192.png') or
    (APath = '/lw/icon-512.png') or (Copy(APath, 1, 8) = '/lw/pwa/');
end;

{ ---------- 小工具 ---------- }

function JSONEsc(const S: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    case c of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if c < #32 then
        Result := Result + '\u' + IntToHex(Ord(c), 4)
      else
        Result := Result + c;
    end;
  end;
end;

function B64Url(const S: RawByteString): string;
var
  i: Integer;
begin
  Result := EncodeStringBase64(S);
  for i := 1 to Length(Result) do
  begin
    if Result[i] = '+' then Result[i] := '-'
    else if Result[i] = '/' then Result[i] := '_';
  end;
  while (Length(Result) > 0) and (Result[Length(Result)] = '=') do
    SetLength(Result, Length(Result) - 1);
end;

function BaseNameFromEndpoint(const AEndpoint: string): string;
var
  i: Integer;
begin
  Result := '';
  i := Pos('://', AEndpoint);
  if i <= 0 then Exit;
  Result := Copy(AEndpoint, 1, i + 2);
  Inc(i, 3);
  while (i <= Length(AEndpoint)) and (AEndpoint[i] <> '/') do
  begin
    Result := Result + AEndpoint[i];
    Inc(i);
  end;
end;

function FindClientFile(const AName, ARoot: string): string;
var
  d, cand: string;
begin
  Result := '';
  d := IncludeTrailingPathDelimiter(ExtractFilePath(ExpandFileName(ParamStr(0))));
  if FileExists(d + AName) then Exit(d + AName);
  if FileExists(d + 'lw' + PathDelim + AName) then Exit(d + 'lw' + PathDelim + AName);
  if ARoot = '' then Exit;
  cand := IncludeTrailingPathDelimiter(ARoot) + 'src' + PathDelim + 'client' + PathDelim + AName;
  if FileExists(cand) then Exit(cand);
  cand := IncludeTrailingPathDelimiter(ARoot) + 'lw' + PathDelim + AName;
  if FileExists(cand) then Exit(cand);
  cand := IncludeTrailingPathDelimiter(ARoot) + 'client' + PathDelim + AName;
  if FileExists(cand) then Exit(cand);
end;

function NormalizeBase(const S: string): string;
begin
  if (Length(S) < 2) or (S[1] <> '/') or (S[Length(S)] <> '/') or
     (Pos('..', S) > 0) or (Pos('//', S) > 0) or (Pos('\', S) > 0) or
     (Pos(':', S) > 0) or (Pos('%', S) > 0) then
    Result := '/'
  else
    Result := S;
end;

function RequestBase(ARequest: TFPHTTPConnectionRequest): string;
begin
  Result := NormalizeBase(Trim(ARequest.GetCustomHeader('X-Forwarded-Prefix')));
end;

procedure SendText(var AResponse: TFPHTTPConnectionResponse;
  const AText, AMime: string; ACode: Integer);
begin
  AResponse.Code := ACode;
  {$IF FPC_FULLVERSION >= 30301}
  AResponse.CodeText := GetHTTPStatusText(ACode);
  {$ELSE}
  case ACode of
    200: AResponse.CodeText := 'OK';
    204: AResponse.CodeText := 'No Content';
    400: AResponse.CodeText := 'Bad Request';
    403: AResponse.CodeText := 'Forbidden';
    404: AResponse.CodeText := 'Not Found';
    405: AResponse.CodeText := 'Method Not Allowed';
    500: AResponse.CodeText := 'Internal Server Error';
  else AResponse.CodeText := 'OK';
  end;
  {$ENDIF}
  AResponse.ContentType := AMime;
  AResponse.Content := AText;
end;

procedure SendFileContent(const AFile, AMime: string;
  var AResponse: TFPHTTPConnectionResponse);
var
  fs: TFileStream;
begin
  if not FileExists(AFile) then
  begin
    SendText(AResponse, '404 not found: ' + ExtractFileName(AFile),
      'text/plain; charset=utf-8', 404);
    Exit;
  end;
  try
    fs := TFileStream.Create(AFile, fmOpenRead or fmShareDenyWrite);
  except
    SendText(AResponse, '500 cannot open ' + ExtractFileName(AFile),
      'text/plain; charset=utf-8', 500);
    Exit;
  end;
  AResponse.Code := 200;
  AResponse.CodeText := 'OK';
  AResponse.ContentType := AMime;
  AResponse.ContentStream := fs;
  AResponse.FreeContentStream := True;
end;

{ ---------- 外壳片段 ---------- }

function LWPWAHeadHtml(const ABase: string): string;
begin
  Result := '';
  if not GOptions.Enabled then Exit;
  Result := Result + LineEnding + '<link rel="manifest" href="' + ABase +
    'lw/manifest.webmanifest">';
  Result := Result + LineEnding + '<meta name="theme-color" content="' +
    JSONEsc(GOptions.ThemeColor) + '">';
  Result := Result + LineEnding + '<meta name="apple-mobile-web-app-capable" content="yes">';
  Result := Result + LineEnding + '<link rel="apple-touch-icon" href="' + ABase +
    'lw/icon-192.png">';
end;

function LWPWAScriptHtml(const ABase: string): string;
begin
  Result := '';
  if not GOptions.Enabled then Exit;
  Result := Result + LineEnding + '<script src="' + ABase +
    'lw/pwa.js?v=' + GOptions.Version + '" defer></script>';
end;

{ ---------- 订阅存储 ---------- }

function StorePath(const ADefaultName: string; const AConfigured: string): string;
begin
  if AConfigured <> '' then Exit(AConfigured);
  if GOptions.Root <> '' then
    Exit(IncludeTrailingPathDelimiter(GOptions.Root) + ADefaultName);
  Result := ExtractFilePath(ParamStr(0)) + ADefaultName;
end;

function LoadSubscriptions: TJSONArray;
var
  path: string;
  fs: TFileStream;
  raw: RawByteString;
  data: TJSONData;
begin
  Result := TJSONArray.Create;
  path := StorePath('pwa-subscriptions.json', GOptions.PushFile);
  if not FileExists(path) then Exit;
  fs := TFileStream.Create(path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(raw, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(raw[1], fs.Size);
  finally
    fs.Free;
  end;
  if Trim(raw) = '' then Exit;
  try
    data := GetJSON(raw);
    try
      if (data <> nil) and (data.JSONType = jtArray) then
      begin
        Result.Free;
        Result := TJSONArray(data);
        data := nil;
      end;
    finally
      data.Free;
    end;
  except
    on E: Exception do LWLog('[pwa] 订阅文件解析失败: ' + E.Message);
  end;
end;

procedure SaveSubscriptions(AArray: TJSONArray);
var
  path: string;
  fs: TFileStream;
  s: RawByteString;
begin
  path := StorePath('pwa-subscriptions.json', GOptions.PushFile);
  s := AArray.AsJSON;
  fs := TFileStream.Create(path, fmCreate);
  try
    if Length(s) > 0 then fs.WriteBuffer(s[1], Length(s));
  finally
    fs.Free;
  end;
end;

function LoadMessage: TJSONObject;
var
  path: string;
  fs: TFileStream;
  raw: RawByteString;
  data: TJSONData;
begin
  Result := nil;
  path := StorePath('pwa-message.json', GOptions.MessageFile);
  if not FileExists(path) then Exit;
  fs := TFileStream.Create(path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(raw, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(raw[1], fs.Size);
  finally
    fs.Free;
  end;
  if Trim(raw) = '' then Exit;
  try
    data := GetJSON(raw);
    if (data <> nil) and (data.JSONType = jtObject) then
    begin
      Result := TJSONObject(data);
      Exit;
    end;
    data.Free;
  except
    on E: Exception do LWLog('[pwa] 消息文件解析失败: ' + E.Message);
  end;
end;

procedure SaveMessage(AObj: TJSONObject);
var
  path: string;
  fs: TFileStream;
  s: RawByteString;
begin
  path := StorePath('pwa-message.json', GOptions.MessageFile);
  s := AObj.AsJSON;
  fs := TFileStream.Create(path, fmCreate);
  try
    if Length(s) > 0 then fs.WriteBuffer(s[1], Length(s));
  finally
    fs.Free;
  end;
end;

{ ---------- VAPID / Web Push ---------- }

type
  TRawSignature = array[0..63] of Byte;

function DERToRaw(const DER: array of Byte; out Raw: TRawSignature): Boolean;

  procedure CopyInt(const P: PByte; ALen: Integer; out Dst: TRawSignature);
  var
    q: PByte;
    n, i: Integer;
  begin
    FillChar(Dst, SizeOf(Dst), 0);
    q := P;
    n := ALen;
    while (n > 1) and (q^ = 0) do begin Inc(q); Dec(n); end;
    if n > 32 then Exit;
    for i := 0 to n - 1 do Dst[32 - n + i] := q[i];
  end;

var
  p, q: PByte;
  i, rlen, slen, total: Integer;
  temp: TRawSignature;
begin
  Result := False;
  FillChar(Raw, SizeOf(Raw), 0);
  total := Length(DER);
  if total < 8 then Exit;
  if DER[0] <> $30 then Exit;
  i := 2;
  if DER[i] <> $02 then Exit;
  Inc(i);
  rlen := DER[i];
  Inc(i);
  if (rlen < 1) or (i + rlen >= total) then Exit;
  p := @DER[i];
  Inc(i, rlen);
  if DER[i] <> $02 then Exit;
  Inc(i);
  slen := DER[i];
  Inc(i);
  if (slen < 1) or (i + slen > total) then Exit;
  q := @DER[i];
  CopyInt(p, rlen, Raw);
  CopyInt(q, slen, temp);
  if (Raw[0] = 0) and (Raw[1] = 0) and (temp[0] = 0) and (temp[1] = 0) then Exit;
  for i := 0 to 31 do Raw[32 + i] := temp[i];
  Result := True;
end;

function VAPIDJWT(const AEndpoint: string): string;
var
  pem: RawByteString;
  fs: TFileStream;
  bio: PBIO;
  pkey: PEVP_PKEY;
  ctx: PEVP_MD_CTX;
  pctx: PEVP_PKEY_CTX;
  der: array[0..255] of Byte;
  derlen: size_t;
  raw: TRawSignature;
  header, payload, input, sigstr: RawByteString;
  subj, aud: string;
begin
  Result := '';
  if GOptions.VAPIDPrivate = '' then
    raise Exception.Create('未配置 pwa-vapid-private');
  if not FileExists(GOptions.VAPIDPrivate) then
    raise Exception.Create('VAPID 私钥文件不存在: ' + GOptions.VAPIDPrivate);
  fs := TFileStream.Create(GOptions.VAPIDPrivate, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(pem, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(pem[1], fs.Size);
  finally
    fs.Free;
  end;
  bio := BIO_new_mem_buf(PChar(pem), Length(pem));
  pkey := PEM_read_bio_PrivateKey(bio, nil, nil, nil);
  if pkey = nil then
    raise Exception.Create('VAPID 私钥不是有效的 PEM EC 私钥');
  aud := BaseNameFromEndpoint(AEndpoint);
  if aud = '' then aud := 'https://push.services.mozilla.com';
  subj := GOptions.VAPIDSubject;
  if subj = '' then subj := 'mailto:admin@localhost';
  header := '{"typ":"JWT","alg":"ES256"}';
  payload := '{"aud":"' + JSONEsc(aud) + '","exp":' +
    IntToStr(DateTimeToUnix(Now, False) + 12 * 60 * 60) + ',"sub":"' +
    JSONEsc(subj) + '"}';
  input := B64Url(header) + '.' + B64Url(payload);
  ctx := EVP_MD_CTX_new;
  try
    if EVP_DigestSignInit(ctx, @pctx, EVP_sha256, nil, pkey) <> 1 then
      raise Exception.Create('VAPID 签名初始化失败（需要 OpenSSL 3 运行库）');
    derlen := SizeOf(der);
    if (Length(input) = 0) or
       (EVP_DigestSign(ctx, @der[0], @derlen, @input[1], Length(input)) <> 1) then
      raise Exception.Create('VAPID 签名失败');
  finally
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);
  end;
  if not DERToRaw(der, raw) then
    raise Exception.Create('VAPID 签名格式无法转换为 ES256 raw 格式');
  { 不能走 PChar：raw 签名里会有 0 字节。按定长拷贝再编码。 }
  SetLength(sigstr, 64);
  Move(raw[0], sigstr[1], 64);
  Result := input + '.' + B64Url(sigstr);
end;

procedure SendTickle(const AEndpoint: string; ATTL: Integer; out AError: string);
var
  clt: TFPHTTPClient;
  empty: TMemoryStream;
  jwt: string;
begin
  AError := '';
  clt := TFPHTTPClient.Create(nil);
  empty := TMemoryStream.Create;
  try
    try
      jwt := VAPIDJWT(AEndpoint);
      clt.AllowRedirect := False;
      clt.ConnectTimeout := 3000;
      clt.IOTimeout := 5000;
      clt.RequestHeaders.Add('Authorization: vapid t=' + jwt + ',k=' + GOptions.VAPIDPublic);
      clt.RequestHeaders.Add('TTL: ' + IntToStr(ATTL));
      clt.RequestHeaders.Add('Content-Type: application/octet-stream');
      clt.RequestHeaders.Add('Content-Length: 0');
      clt.HTTPMethod('POST', AEndpoint, empty, []);
      if (clt.ResponseStatusCode < 200) or (clt.ResponseStatusCode >= 300) then
        AError := 'HTTP ' + IntToStr(clt.ResponseStatusCode);
    except
      on E: Exception do AError := E.Message;
    end;
  finally
    empty.Free;
    clt.Free;
  end;
end;

{ ---------- 请求处理 ---------- }

function ParseJSONObject(const ABody: string): TJSONObject;
var
  data: TJSONData;
begin
  Result := nil;
  if Trim(ABody) = '' then Exit;
  data := GetJSON(ABody);
  if (data <> nil) and (data.JSONType = jtObject) then
  begin
    Result := TJSONObject(data);
    Exit;
  end;
  data.Free;
end;

function HandleSubscribe(ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse): Boolean;
var
  obj, keys: TJSONObject;
  arr: TJSONArray;
  endpoint, p256dh, auth: string;
  i, n: Integer;
  item: TJSONObject;
begin
  Result := True;
  if not LWPWAPushEnabled then
  begin
    SendText(AResponse, '{"ok":false,"err":"push is not configured"}',
      'application/json; charset=utf-8', 400);
    Exit;
  end;
  if UpperCase(ARequest.Method) <> 'POST' then
  begin
    SendText(AResponse, '{"ok":false,"err":"POST required"}',
      'application/json; charset=utf-8', 405);
    Exit;
  end;
  obj := ParseJSONObject(ARequest.Content);
  if obj = nil then
  begin
    SendText(AResponse, '{"ok":false,"err":"invalid JSON"}',
      'application/json; charset=utf-8', 400);
    Exit;
  end;
  try
    endpoint := obj.Get('endpoint', '');
    keys := nil;
    if obj.Find('keys') <> nil then
      if obj.Find('keys').JSONType = jtObject then
        keys := TJSONObject(obj.Find('keys'));
    if keys <> nil then
    begin
      p256dh := keys.Get('p256dh', '');
      auth := keys.Get('auth', '');
    end
    else
    begin
      p256dh := '';
      auth := '';
    end;
    if (Copy(LowerCase(endpoint), 1, 8) <> 'https://') or
       (p256dh = '') or (auth = '') then
    begin
      SendText(AResponse, '{"ok":false,"err":"invalid subscription"}',
        'application/json; charset=utf-8', 400);
      Exit;
    end;
    EnterCriticalSection(GLock);
    try
      arr := LoadSubscriptions;
      try
        for i := arr.Count - 1 downto 0 do
          if arr.Items[i].JSONType = jtObject then
            if TJSONObject(arr.Items[i]).Get('endpoint', '') = endpoint then
              arr.Delete(i);
        if arr.Count >= LW_PWA_MAX_SUBS then
        begin
          SendText(AResponse, '{"ok":false,"err":"subscription store full"}',
            'application/json; charset=utf-8', 400);
          Exit;
        end;
        item := TJSONObject.Create;
        item.Add('endpoint', endpoint);
        item.Add('p256dh', p256dh);
        item.Add('auth', auth);
        arr.Add(item);
        SaveSubscriptions(arr);
        n := arr.Count;
      finally
        arr.Free;
      end;
    finally
      LeaveCriticalSection(GLock);
    end;
    SendText(AResponse, '{"ok":true,"count":' + IntToStr(n) + '}',
      'application/json; charset=utf-8', 200);
  finally
    obj.Free;
  end;
end;

function HandleUnsubscribe(ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse): Boolean;
var
  obj: TJSONObject;
  arr: TJSONArray;
  endpoint: string;
  i: Integer;
begin
  Result := True;
  if UpperCase(ARequest.Method) <> 'POST' then
  begin
    SendText(AResponse, '{"ok":false,"err":"POST required"}',
      'application/json; charset=utf-8', 405);
    Exit;
  end;
  obj := ParseJSONObject(ARequest.Content);
  if obj = nil then
  begin
    SendText(AResponse, '{"ok":false,"err":"invalid JSON"}',
      'application/json; charset=utf-8', 400);
    Exit;
  end;
  try
    endpoint := obj.Get('endpoint', '');
    EnterCriticalSection(GLock);
    try
      arr := LoadSubscriptions;
      try
        for i := arr.Count - 1 downto 0 do
          if (arr.Items[i].JSONType = jtObject) and
             (TJSONObject(arr.Items[i]).Get('endpoint', '') = endpoint) then
            arr.Delete(i);
        SaveSubscriptions(arr);
      finally
        arr.Free;
      end;
    finally
      LeaveCriticalSection(GLock);
    end;
    SendText(AResponse, '{"ok":true}', 'application/json; charset=utf-8', 200);
  finally
    obj.Free;
  end;
end;

function HandlePush(ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse): Boolean;
var
  obj, msg: TJSONObject;
  arr: TJSONArray;
  i, ttl, sent, failed: Integer;
  endpoint, err: string;
begin
  Result := True;
  if GOptions.PushToken = '' then
  begin
    SendText(AResponse, '404 not found', 'text/plain; charset=utf-8', 404);
    Exit;
  end;
  if ARequest.GetCustomHeader('X-LW-PWA-Token') <> GOptions.PushToken then
  begin
    SendText(AResponse, '{"ok":false,"err":"bad token"}',
      'application/json; charset=utf-8', 403);
    Exit;
  end;
  if UpperCase(ARequest.Method) <> 'POST' then
  begin
    SendText(AResponse, '{"ok":false,"err":"POST required"}',
      'application/json; charset=utf-8', 405);
    Exit;
  end;
  if not LWPWAPushEnabled then
  begin
    SendText(AResponse, '{"ok":false,"err":"push is not configured"}',
      'application/json; charset=utf-8', 400);
    Exit;
  end;
  obj := ParseJSONObject(ARequest.Content);
  if obj = nil then
  begin
    SendText(AResponse, '{"ok":false,"err":"invalid JSON"}',
      'application/json; charset=utf-8', 400);
    Exit;
  end;
  try
    ttl := obj.Get('ttl', 60);
    if (ttl < 0) or (ttl > 86400) then ttl := 60;
    msg := TJSONObject.Create;
    try
      msg.Add('title', obj.Get('title', 'lazarusWeb'));
      msg.Add('body', obj.Get('body', ''));
      msg.Add('url', obj.Get('url', '/'));
      msg.Add('at', DateTimeToUnix(Now, False));
      EnterCriticalSection(GLock);
      try
        SaveMessage(msg);
        arr := LoadSubscriptions;
      finally
        LeaveCriticalSection(GLock);
      end;
    finally
      msg.Free;
    end;
    try
      sent := 0;
      failed := 0;
      for i := 0 to arr.Count - 1 do
      begin
        if arr.Items[i].JSONType <> jtObject then Continue;
        endpoint := TJSONObject(arr.Items[i]).Get('endpoint', '');
        if endpoint = '' then Continue;
        SendTickle(endpoint, ttl, err);
        if err = '' then Inc(sent) else Inc(failed);
      end;
    finally
      arr.Free;
    end;
    SendText(AResponse, '{"ok":true,"sent":' + IntToStr(sent) +
      ',"failed":' + IntToStr(failed) + '}',
      'application/json; charset=utf-8', 200);
  finally
    obj.Free;
  end;
end;

function HandleMessage(var AResponse: TFPHTTPConnectionResponse): Boolean;
var
  obj: TJSONObject;
begin
  Result := True;
  obj := LoadMessage;
  if obj = nil then
  begin
    SendText(AResponse, '', 'application/json; charset=utf-8', 204);
    Exit;
  end;
  try
    SendText(AResponse, obj.AsJSON, 'application/json; charset=utf-8', 200);
  finally
    obj.Free;
  end;
end;

function LWPWAHandle(ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse): Boolean;
var
  p, base, pluginBase, s: string;
  q: SizeInt;
  obj: TJSONObject;
begin
  Result := False;
  if not GOptions.Enabled then Exit;
  p := ARequest.URL;
  q := Pos('?', p);
  if q > 0 then p := Copy(p, 1, q - 1);
  { 插件前缀：lwroute 把 /p/<名>/lw/... 剥前缀后转给宿主，
    这里请求对象里仍是原 URL，自己剥一次才能命中下面的路由表 }
  pluginBase := '';
  if Copy(p, 1, 3) = '/p/' then
  begin
    q := Pos('/', Copy(p, 4, MaxInt));
    if q > 0 then
    begin
      pluginBase := Copy(p, 1, q + 3) + '/';
      while (Length(pluginBase) > 1) and
            (pluginBase[Length(pluginBase)] = '/') and
            (pluginBase[Length(pluginBase) - 1] = '/') do
        SetLength(pluginBase, Length(pluginBase) - 1);
      p := Copy(p, q + 3, MaxInt);
    end;
  end;
  if not LWPWAIsPath(p) then Exit;
  Result := True;
  base := RequestBase(ARequest);
  { 本地改写不会带 X-Forwarded-Prefix，直接从 URL 还原插件前缀 }
  if pluginBase <> '' then
  begin
    pluginBase := NormalizeBase(pluginBase);
    if base = '/' then base := pluginBase;
  end;

  if p = '/lw/manifest.webmanifest' then
  begin
    s := '{"name":"' + JSONEsc(GOptions.Name) + '","short_name":"' +
      JSONEsc(GOptions.ShortName) + '","start_url":"' + JSONEsc(base) +
      '","scope":"' + JSONEsc(base) + '","display":"standalone",' +
      '"background_color":"' + JSONEsc(GOptions.BackgroundColor) +
      '","theme_color":"' + JSONEsc(GOptions.ThemeColor) + '","icons":[' +
      '{"src":"' + base + 'lw/icon-192.png","sizes":"192x192","type":"image/png","purpose":"any maskable"},' +
      '{"src":"' + base + 'lw/icon-512.png","sizes":"512x512","type":"image/png","purpose":"any maskable"}]}';
    SendText(AResponse, s, 'application/manifest+json; charset=utf-8', 200);
    Exit;
  end;
  if p = '/lw/sw.js' then
  begin
    SendFileContent(FindClientFile('sw.js', GOptions.Root),
      'application/javascript; charset=utf-8', AResponse);
    AResponse.SetCustomHeader('Cache-Control', 'no-cache');
    AResponse.SetCustomHeader('Service-Worker-Allowed', base);
    Exit;
  end;
  if p = '/lw/pwa.js' then
  begin
    SendFileContent(FindClientFile('pwa.js', GOptions.Root),
      'application/javascript; charset=utf-8', AResponse);
    AResponse.SetCustomHeader('Cache-Control', 'no-cache');
    Exit;
  end;
  if (p = '/lw/icon-192.png') or (p = '/lw/icon-512.png') then
  begin
    SendFileContent(FindClientFile(ExtractFileName(p), GOptions.Root),
      'image/png', AResponse);
    AResponse.SetCustomHeader('Cache-Control', 'public, max-age=86400');
    Exit;
  end;
  if p = '/lw/pwa/config' then
  begin
    obj := TJSONObject.Create;
    try
      obj.Add('enabled', True);
      obj.Add('push', LWPWAPushEnabled);
      obj.Add('vapidPublicKey', GOptions.VAPIDPublic);
      obj.Add('base', base);
      SendText(AResponse, obj.AsJSON, 'application/json; charset=utf-8', 200);
    finally
      obj.Free;
    end;
    Exit;
  end;
  if p = '/lw/pwa/subscribe' then Exit(HandleSubscribe(ARequest, AResponse));
  if p = '/lw/pwa/unsubscribe' then Exit(HandleUnsubscribe(ARequest, AResponse));
  if p = '/lw/pwa/push' then Exit(HandlePush(ARequest, AResponse));
  if p = '/lw/pwa/message' then Exit(HandleMessage(AResponse));
  SendText(AResponse, '404 not found', 'text/plain; charset=utf-8', 404);
end;

initialization
  if not GLockReady then
  begin
    InitCriticalSection(GLock);
    GLockReady := True;
  end;

finalization
  if GLockReady then DoneCriticalSection(GLock);

end.
