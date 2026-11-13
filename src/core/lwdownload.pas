{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwdownload
  ------------------------------------------------------------------
  下载令牌表。

  为什么要令牌而不是直接把路径放进 URL？
   浏览器拿到的是 <a href="/lw/download?f=C:\data\x.csv">，把服务端文件系统
   的绝对路径暴露给客户端是安全漏洞：只要猜一个路径就能下载任意文件。
   所以业务代码只登记"我要给这个文件"，换回一个随机令牌，
   URL 里只有令牌，服务端凭令牌反查真实路径 —— 客户端无法构造越权请求。

  令牌一次有效：第一次下载后即失效（浏览器重试/断点续传很少见，
  需要重下就让业务代码重新登记一次）。
}
unit lwdownload;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, DateUtils;

type
  TLWDownloadEntry = class
  public
    FileName: string;      { 服务端真实路径 }
    DownloadName: string;  { 浏览器另存为的文件名 }
    Mime: string;
    Created: TDateTime;
  end;

{ 登记一个可下载文件，返回令牌（失败返回空串） }
function LWDownloadRegister(const AFileName: string;
  const ADownloadName: string = ''; const AMime: string = ''): string;

{ 用令牌换回文件信息；返回 False 表示令牌无效/已过期 }
function LWDownloadResolve(const AToken: string; out AFileName, ADownloadName,
  AMime: string): Boolean;

{ 令牌用掉之后调用（也可不调，靠 Sweep 兜底） }
procedure LWDownloadRelease(const AToken: string);

{ 续期：把令牌的创建时间刷成"现在"。
  内嵌查看（PDF 帧的 iframe）走的是可重复访问的令牌，
  每次 BuildPayload 序列化时都 Touch 一次 —— 只要会话活着，
  令牌就不过期；超过 AMinutes 没人 Touch 才被 Sweep 收走。 }
procedure LWDownloadTouch(const AToken: string);

{ 清理超过 AMinutes 分钟未被取走的令牌 }
procedure LWDownloadSweep(AMinutes: Integer);

{ 按扩展名猜 MIME，lwhttp / lwdownload 共用 }
function LWMimeOf(const AFileName: string): string;

implementation

var
  GLock: TCriticalSection = nil;
  GItems: TStringList = nil;
  GCounter: Integer = 0;

procedure EnsureInit;
begin
  if GLock = nil then
  begin
    GLock := TCriticalSection.Create;
    GItems := TStringList.Create;
    GItems.Sorted := True;
    GItems.CaseSensitive := True;
    GItems.Duplicates := dupIgnore;
  end;
end;

function LWMimeOf(const AFileName: string): string;
var
  e: string;
begin
  e := LowerCase(ExtractFileExt(AFileName));
  if e = '.txt' then Result := 'text/plain; charset=utf-8'
  else if e = '.csv' then Result := 'text/csv; charset=utf-8'
  else if e = '.htm' then Result := 'text/html; charset=utf-8'
  else if e = '.html' then Result := 'text/html; charset=utf-8'
  else if e = '.json' then Result := 'application/json; charset=utf-8'
  else if e = '.xml' then Result := 'application/xml; charset=utf-8'
  else if e = '.js' then Result := 'application/javascript'
  else if e = '.css' then Result := 'text/css'
  else if e = '.png' then Result := 'image/png'
  else if e = '.gif' then Result := 'image/gif'
  else if e = '.jpg' then Result := 'image/jpeg'
  else if e = '.jpeg' then Result := 'image/jpeg'
  else if e = '.bmp' then Result := 'image/bmp'
  else if e = '.svg' then Result := 'image/svg+xml'
  else if e = '.pdf' then Result := 'application/pdf'
  else if e = '.zip' then Result := 'application/zip'
  else if e = '.xlsx' then Result := 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  else if e = '.docx' then Result := 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  else if e = '.woff' then Result := 'font/woff'
  else if e = '.woff2' then Result := 'font/woff2'
  else if e = '.ttf' then Result := 'font/ttf'
  else if e = '.ico' then Result := 'image/x-icon'
  else
    Result := 'application/octet-stream';
end;

function LWDownloadRegister(const AFileName: string;
  const ADownloadName, AMime: string): string;
var
  g: TGUID;
  e: TLWDownloadEntry;
begin
  Result := '';
  if (AFileName = '') or (not FileExists(AFileName)) then Exit;
  EnsureInit;
  CreateGUID(g);
  Inc(GCounter);
  Result := LowerCase(Copy(GUIDToString(g), 2, 16)) + IntToHex(GCounter, 4);
  e := TLWDownloadEntry.Create;
  e.FileName := ExpandFileName(AFileName);
  if ADownloadName <> '' then
    e.DownloadName := ExtractFileName(ADownloadName)
  else
    e.DownloadName := ExtractFileName(AFileName);
  if AMime <> '' then
    e.Mime := AMime
  else
    e.Mime := LWMimeOf(e.DownloadName);
  e.Created := Now;
  GLock.Enter;
  try
    GItems.AddObject(Result, e);
  finally
    GLock.Leave;
  end;
end;

function LWDownloadResolve(const AToken: string; out AFileName, ADownloadName,
  AMime: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  AFileName := '';
  ADownloadName := '';
  AMime := '';
  if (AToken = '') or (GLock = nil) then Exit;
  GLock.Enter;
  try
    i := GItems.IndexOf(AToken);
    if i >= 0 then
    begin
      AFileName := TLWDownloadEntry(GItems.Objects[i]).FileName;
      ADownloadName := TLWDownloadEntry(GItems.Objects[i]).DownloadName;
      AMime := TLWDownloadEntry(GItems.Objects[i]).Mime;
      Result := FileExists(AFileName);
    end;
  finally
    GLock.Leave;
  end;
end;

procedure LWDownloadRelease(const AToken: string);
var
  i: Integer;
begin
  if (AToken = '') or (GLock = nil) then Exit;
  GLock.Enter;
  try
    i := GItems.IndexOf(AToken);
    if i >= 0 then
    begin
      GItems.Objects[i].Free;
      GItems.Delete(i);
    end;
  finally
    GLock.Leave;
  end;
end;

procedure LWDownloadTouch(const AToken: string);
var
  i: Integer;
begin
  if (AToken = '') or (GLock = nil) then Exit;
  GLock.Enter;
  try
    i := GItems.IndexOf(AToken);
    if i >= 0 then
      TLWDownloadEntry(GItems.Objects[i]).Created := Now;
  finally
    GLock.Leave;
  end;
end;

procedure LWDownloadSweep(AMinutes: Integer);
var
  i: Integer;
  deadline: TDateTime;
begin
  if GLock = nil then Exit;
  deadline := Now - (AMinutes / (24 * 60));
  GLock.Enter;
  try
    for i := GItems.Count - 1 downto 0 do
      if TLWDownloadEntry(GItems.Objects[i]).Created < deadline then
      begin
        GItems.Objects[i].Free;
        GItems.Delete(i);
      end;
  finally
    GLock.Leave;
  end;
end;

procedure FinalizeDownloads;
var
  i: Integer;
begin
  if GItems = nil then Exit;
  for i := GItems.Count - 1 downto 0 do
    GItems.Objects[i].Free;
  FreeAndNil(GItems);
  FreeAndNil(GLock);
end;

finalization
  FinalizeDownloads;

end.
