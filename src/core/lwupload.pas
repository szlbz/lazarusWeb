{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwupload
  ------------------------------------------------------------------
  POST /lw/api/upload 的服务端实现。

  请求：multipart/form-data，字段名随意（浏览器端就是 <input type=file>），
        查询串带 sid（会话）和 id（TLWFileUpload 控件）。
  响应：与 /lw/api/event 相同的组件树载荷。

  文件落盘位置（按优先级）：
    1. TLWFileUpload.TargetFolder（业务代码指定，必须已存在或可创建）
    2. <exe目录>/uploads/<会话号>/<控件名>/（LWUploadRootDir；
       exe 旁不可写时自动退回 <临时目录>/uploads/）
  文件名只保留基名并做安全化处理 —— 浏览器给的名字里可能带 ..\ 或盘符，
  直接拼进路径就是目录穿越漏洞。
}
unit lwupload;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, httpdefs, fpjson, LCLType, lwbase, lwsession, lwfileupload;

{ 会话上传目录（不存在则创建） }
function LWUploadDirFor(const ASid: string; const ASub: string = ''): string;

{ 处理一次上传；返回新的组件树，失败时 AErr 非空且返回 nil }
function LWProcessUpload(S: TLWSession; AReq: TRequest; ACompId: Integer;
  out AErr: string): TJSONObject;

{ TOpenDialog.Execute 的浏览器端选文件：把上传的文件存进会话的临时目录，
  然后把服务端路径作为对话框答案交回（多条用 #13#10 分隔）。
  返回空串表示失败（AErr 有原因）。 }
function LWProcessDialogUpload(S: TLWSession; AReq: TRequest; ADlgToken: Integer;
  out AErr: string): string;

{ 清理浏览器给的文件名：去路径、去非法字符、防空 }
function LWSafeFileName(const AName: string): string;

implementation

function LWSafeFileName(const AName: string): string;
var
  s: string;
  i: Integer;
begin
  s := StringReplace(AName, '\', '/', [rfReplaceAll]);
  s := ExtractFileName(s);            { 去掉目录部分，含 ../ 和 C:/ }
  s := StringReplace(s, ':', '_', [rfReplaceAll]);
  for i := 1 to Length(s) do
    if s[i] in ['<', '>', '|', '"', '*', '?', #0..#31] then
      s[i] := '_';
  s := Trim(s);
  while (s <> '') and (s[1] = '.') do
    Delete(s, 1, 1);                  { . / .. / 隐藏文件前缀 }
  if s = '' then
    s := 'upload.bin';
  if Length(s) > 120 then
    s := Copy(s, 1, 120);
  Result := s;
end;

function LWUploadDirFor(const ASid: string; const ASub: string): string;
var
  d: string;
begin
  { 根目录来自 lwbase.LWUploadRootDir（默认 exe 旁 uploads，见其注释），
    会话隔离结构保持 <root>/<sid>/<控件名>/ }
  d := LWUploadRootDir + ASid;
  if ASub <> '' then
    d := IncludeTrailingPathDelimiter(d) + LWSafeFileName(ASub);
  if not ForceDirectories(d) then
    Exit('');
  Result := IncludeTrailingPathDelimiter(d);
end;

function UniqueTarget(const ADir, AName: string): string;
var
  base, ext: string;
  n: Integer;
begin
  Result := ADir + AName;
  if not FileExists(Result) then Exit;
  base := ChangeFileExt(AName, '');
  ext := ExtractFileExt(AName);
  n := 1;
  repeat
    Result := ADir + base + '_' + IntToStr(n) + ext;
    Inc(n);
  until (not FileExists(Result)) or (n > 9999);
end;

function LWProcessUpload(S: TLWSession; AReq: TRequest; ACompId: Integer;
  out AErr: string): TJSONObject;
var
  C: TComponent;
  U: TLWFileUpload;
  i, cnt, written: Integer;
  f: TUploadedFile;
  dir, name, path: string;
  fs, src: TFileStream;
  total: Int64;
begin
  Result := nil;
  AErr := '';

  if S = nil then
  begin
    AErr := 'no session';
    Exit;
  end;
  C := S.CompById(ACompId);
  if (C = nil) or (not (C is TLWFileUpload)) then
  begin
    AErr := 'file-upload control not found: ' + IntToStr(ACompId);
    Exit;
  end;
  U := TLWFileUpload(C);

  cnt := 0;
  if AReq.Files <> nil then
    cnt := AReq.Files.Count;
  if cnt = 0 then
  begin
    S.SessionNotify('Upload: 请求里没有文件（浏览器可能把表单发成了普通 POST）');
    AErr := 'no file in request';
    Exit;
  end;

  if U.TargetFolder <> '' then
  begin
    if not ForceDirectories(U.TargetFolder) then
    begin
      AErr := 'cannot create folder: ' + U.TargetFolder;
      Exit;
    end;
    dir := IncludeTrailingPathDelimiter(U.TargetFolder);
  end
  else
    dir := LWUploadDirFor(S.Sid, U.Name);

  if dir = '' then
  begin
    AErr := 'cannot create upload folder';
    Exit;
  end;

  total := 0;
  for i := 0 to cnt - 1 do
  begin
    f := TUploadedFile(AReq.Files.Items[i]);
    { 单文件超限：跳过并记日志，不整体失败（多选时其它文件照常保存） }
    if (U.MaxSizeKB > 0) and (f.Size > Int64(U.MaxSizeKB) * 1024) then
    begin
      S.SessionNotify(Format('Upload: 跳过 %s（%d KB > 上限 %d KB）',
        [f.FileName, f.Size div 1024, U.MaxSizeKB]));
      Continue;
    end;

    name := LWSafeFileName(f.FileName);
    path := UniqueTarget(dir, name);
    written := 0;
    try
      fs := TFileStream.Create(path, fmCreate);
      try
        if (f.Stream <> nil) and (f.Size > 0) then
        begin
          f.Stream.Position := 0;
          written := fs.CopyFrom(f.Stream, 0);
        end
        else if (f.LocalFileName <> '') and FileExists(f.LocalFileName) then
        begin
          { fcl-web 在部分模式下（例如内容先落盘）把数据放在 LocalFileName }
          src := TFileStream.Create(f.LocalFileName, fmOpenRead or fmShareDenyWrite);
          try
            written := fs.CopyFrom(src, 0);
          finally
            src.Free;
          end;
        end;
      finally
        fs.Free;
      end;
    except
      on E: Exception do
      begin
        S.SessionNotify('Upload: 保存失败 ' + path + ' : ' + E.Message);
        Continue;
      end;
    end;

    U.AddUploadedFile(path);
    Inc(total);
    S.SessionNotify(Format('Upload: %s -> %s (%d bytes)',
      [f.FileName, path, written]));
    if Assigned(U.OnUpload) then
      U.OnUpload(U, path);
  end;

  if total = 0 then
  begin
    AErr := 'no file saved';
    Exit;
  end;
  Result := S.BuildPayload;
end;

function LWProcessDialogUpload(S: TLWSession; AReq: TRequest; ADlgToken: Integer;
  out AErr: string): string;
var
  i, cnt: Integer;
  f: TUploadedFile;
  dir, name, path, list: string;
  fs, src: TFileStream;
begin
  Result := '';
  AErr := '';
  if S = nil then
  begin
    AErr := 'no session';
    Exit;
  end;

  dir := LWUploadDirFor(S.Sid, 'pick');
  if dir = '' then
  begin
    AErr := 'cannot create pick folder';
    Exit;
  end;

  cnt := 0;
  if AReq.Files <> nil then
    cnt := AReq.Files.Count;
  if cnt = 0 then
  begin
    AErr := 'no file in request';
    Exit;
  end;

  list := '';
  for i := 0 to cnt - 1 do
  begin
    f := TUploadedFile(AReq.Files.Items[i]);
    name := LWSafeFileName(f.FileName);
    { 每次选文件都放到独立的子目录：同一次选择落在同一个目录里，
      不同次互不覆盖，业务代码拿到的路径也不会被下一次选择改掉 }
    path := UniqueTarget(dir, name);
    try
      fs := TFileStream.Create(path, fmCreate);
      try
        if (f.Stream <> nil) and (f.Size > 0) then
        begin
          f.Stream.Position := 0;
          fs.CopyFrom(f.Stream, 0);
        end
        else if (f.LocalFileName <> '') and FileExists(f.LocalFileName) then
        begin
          { fcl-web 在部分模式下先把内容落到临时文件里 }
          src := TFileStream.Create(f.LocalFileName, fmOpenRead or fmShareDenyWrite);
          try
            fs.CopyFrom(src, 0);
          finally
            src.Free;
          end;
        end;
      finally
        fs.Free;
      end;
    except
      on E: Exception do
      begin
        S.SessionNotify('DialogUpload: 保存失败 ' + path + ' : ' + E.Message);
        Continue;
      end;
    end;
    if list <> '' then
      list := list + #13#10;
    list := list + path;
    S.SessionNotify('DialogUpload: ' + f.FileName + ' -> ' + path);
  end;

  if list = '' then
  begin
    AErr := 'no file saved';
    Exit;
  end;

  { 把路径当成对话框的"输入值"交回去；对话框那边拿到就结束等待 }
  if not S.ResolveDialog(ADlgToken, idButtonOk, list) then
    AErr := 'dialog already closed'
  else
    Result := list;
end;

end.
