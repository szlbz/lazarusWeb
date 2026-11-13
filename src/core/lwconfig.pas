{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwconfig
  ------------------------------------------------------------------
  服务端配置文件（INI 风格）。命令行参数永远优先于这里。

  设计取舍：
    - 不强制分节：`[lazarusWeb]` / `[server]` / 不写节名都能用，
      所有键摊平成一个表查（本框架只认三个键，不存在重名冲突）；
    - 键名不区分大小写，且忽略 '-' / '_' / 空格：
      ExtDir / ext-dir / ext_dir / EXTDIR 等价；
    - 值里若带中文路径，文件请存 UTF-8（带不带 BOM 都行）或纯 ASCII；
    - 写到环境里最多的两件事是"换个端口、换个主题、ext 换个盘"，
      所以只解析这三项，其它仍走命令行（避免两处配置互相打架）。
}
unit lwconfig;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { 读取器。只负责"把文件读成 key->value"，不理解业务含义；
    语义（默认值、合法性）由 lwapp 决定。 }
  TLWConfig = class
  private
    FPath: string;
    FItems: TStringList;      { 每项 'key=value'，key 已归一化为小写 }
    FNotes: TStringList;      { 解析过程中的提示（给调用方打日志） }
    procedure ParseBytes(const ABytes: RawByteString);
    function RawGet(const AKey: string; out AValue: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    { 读配置文件。
      AExplicit <> ''：用户用 --config= 指定的文件，找不到就返回 False；
      AExplicit = '' ：自动查找，顺序为
          <exe目录>\<exe名>.ini   ->  <exe目录>\lazarusWeb.ini
          -> <当前目录>\<exe名>.ini -> <当前目录>\lazarusWeb.ini
      返回 True 表示成功读到文件（FPath 为绝对路径）。 }
    function Load(const AExplicit: string): Boolean;
    { 有没有这一项（AKeys 支持别名，命中任一即可） }
    function Has(const AKeys: array of string): Boolean;
    function Str(const AKeys: array of string; const ADef: string): string;
    function Int(const AKeys: array of string; ADef: Integer): Integer;
    property Path: string read FPath;
    property Notes: TStringList read FNotes;
  end;

{ 解析 ext-js 目录：
    - 绝对路径直接校验；
    - 相对路径先按 exe 目录、再按当前目录展开（哪个存在用哪个）；
    - 目录不存在、或目录里没有任何条目 → 返回 ''，调用方退回
      "从当前目录/根目录里找 ext-<版本>" 的自动查找。 }
function LWResolveExtDir(const AValue: string): string;

{ 目录里是否有条目（含子目录；只看 '.'/'..' 之外的东西）。不存在返回 False }
function LWDirHasEntries(const ADir: string): Boolean;

implementation

uses
  lwrlog;

const
  { 单文件上限：配置文件是手写的，超过这个数一定是选错文件了 }
  LW_CFG_MAX_SIZE = 1024 * 1024;

{ 键名归一化：小写，去掉 '-' / '_' / 空格 / 制表符 }
function NormKey(const S: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if (c >= 'A') and (c <= 'Z') then
      c := Chr(Ord(c) + 32);
    if (c = '-') or (c = '_') or (c = ' ') or (c = #9) then
      Continue;
    Result := Result + c;
  end;
end;

function LWDirHasEntries(const ADir: string): Boolean;
var
  sr: TSearchRec;
  mask: string;
begin
  Result := False;
  if (ADir = '') or (not DirectoryExists(ADir)) then Exit;
  mask := IncludeTrailingPathDelimiter(ADir) + '*';
  if FindFirst(mask, faAnyFile, sr) = 0 then
  try
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        Result := True;
        Break;
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

function IsAbsPath(const APath: string): Boolean;
begin
  { Windows: 'C:\x' 或 UNC '\\srv\share'；Unix: '/x'。
    不用 FilenameIsAbsolute，是为了两种目标上行为一致、可预期。 }
  Result := False;
  if APath = '' then Exit;
  {$IFDEF WINDOWS}
  if (Length(APath) >= 3) and (APath[2] = ':') and
     ((APath[3] = '\') or (APath[3] = '/')) then
    Exit(True);
  Result := (Length(APath) >= 2) and
    ((APath[1] = '\') or (APath[1] = '/')) and
    ((APath[2] = '\') or (APath[2] = '/'));
  {$ELSE}
  Result := APath[1] = '/';
  {$ENDIF}
end;

function LWResolveExtDir(const AValue: string): string;
var
  v, exeDir, cwd, cand: string;

  function Expand(const ABase, ARel: string): string;
  begin
    if ABase = '' then
      Result := ExpandFileName(ARel)
    else
      Result := ExpandFileName(IncludeTrailingPathDelimiter(ABase) + ARel);
  end;

begin
  Result := '';
  v := Trim(AValue);
  if v = '' then Exit;                    { 没配 → 交给自动查找 }

  exeDir := ExtractFileDir(ExpandFileName(ParamStr(0)));
  cwd := GetCurrentDir;

  if IsAbsPath(v) then
    cand := ExcludeTrailingPathDelimiter(ExpandFileName(v))
  else
  begin
    { 相对路径的两种常见意图：写配置文件的人心里想的是 exe 旁边，
      而在仓库里跑的人想的是当前目录。谁存在用谁；都不存在时按
      当前目录展示报错，读起来最直观。 }
    cand := Expand(exeDir, v);
    if not DirectoryExists(cand) then
      cand := Expand(cwd, v);
  end;

  if not DirectoryExists(cand) then
  begin
    LWLog('警告: 配置文件里的 extdir 不存在 -> ' + cand + '，改为自动查找 ext 目录');
    Exit('');
  end;
  if not LWDirHasEntries(cand) then
  begin
    LWLog('警告: 配置文件里的 extdir 是空目录 -> ' + cand + '，改为自动查找 ext 目录');
    Exit('');
  end;
  Result := ExcludeTrailingPathDelimiter(cand);
end;

{ ---------------- TLWConfig ---------------- }

constructor TLWConfig.Create;
begin
  inherited Create;
  FItems := TStringList.Create;
  FItems.NameValueSeparator := '=';
  FNotes := TStringList.Create;
end;

destructor TLWConfig.Destroy;
begin
  FItems.Free;
  FNotes.Free;
  inherited Destroy;
end;

procedure TLWConfig.ParseBytes(const ABytes: RawByteString);

  procedure HandleLine(const ALine: string);
  var
    p: Integer;
    k, v: string;
  begin
    if ALine = '' then Exit;
    if (ALine[1] = ';') or (ALine[1] = '#') then Exit;      { 注释 }
    if ALine[1] = '[' then Exit;                            { 节名：摊平，忽略 }
    p := Pos('=', ALine);
    if p <= 1 then Exit;
    k := NormKey(Copy(ALine, 1, p - 1));
    if k = '' then Exit;
    v := Trim(Copy(ALine, p + 1, MaxInt));
    { 允许把含空格的路径用引号包起来 }
    if (Length(v) >= 2) and ((v[1] = '"') or (v[1] = '''')) and
       (v[Length(v)] = v[1]) then
      v := Copy(v, 2, Length(v) - 2);
    if FItems.IndexOfName(k) >= 0 then
      FItems[FItems.IndexOfName(k)] := k + '=' + v    { 后出现的覆盖先出现的 }
    else
      FItems.Add(k + '=' + v);                        { 空值也保留，Has() 才准 }
  end;

var
  s: string;
  i, n, lineStart: Integer;
  line: string;
begin
  s := ABytes;
  if Copy(s, 1, 3) = #$EF#$BB#$BF then                      { UTF-8 BOM }
    Delete(s, 1, 3);
  n := Length(s);
  lineStart := 1;
  i := 1;
  while i <= n do
  begin
    if s[i] = #10 then
    begin
      line := Copy(s, lineStart, i - lineStart);
      if (line <> '') and (line[Length(line)] = #13) then
        SetLength(line, Length(line) - 1);
      HandleLine(Trim(line));
      lineStart := i + 1;
    end;
    Inc(i);
  end;
  if lineStart <= n then
    HandleLine(Trim(Copy(s, lineStart, n - lineStart + 1)));
end;

function TLWConfig.Load(const AExplicit: string): Boolean;
var
  cand: array[0..3] of string;
  i: Integer;
  chosen, base, exeDir, cwd: string;
  fs: TFileStream;
  buf: RawByteString;

  function FindExplicit(const APath: string): string;
  var
    p, p2: string;
  begin
    Result := '';
    p := ExpandFileName(APath);
    if not FileExists(p) and (ExtractFileExt(p) = '') then
    begin
      p2 := p + '.ini';
      if FileExists(p2) then p := p2;
    end;
    if FileExists(p) then Exit(p);
    { 相对路径：也允许相对 exe 目录（服务方式启动时 cwd 往往是 C:\Windows\System32）}
    if not IsAbsPath(APath) then
    begin
      p := ExpandFileName(IncludeTrailingPathDelimiter(exeDir) + APath);
      if not FileExists(p) and (ExtractFileExt(p) = '') then
      begin
        p2 := p + '.ini';
        if FileExists(p2) then p := p2;
      end;
      if FileExists(p) then Exit(p);
    end;
  end;

begin
  Result := False;
  FPath := '';
  FItems.Clear;
  FNotes.Clear;
  exeDir := ExtractFileDir(ExpandFileName(ParamStr(0)));
  cwd := GetCurrentDir;
  base := ChangeFileExt(ExtractFileName(ParamStr(0)), '');

  chosen := '';
  if AExplicit <> '' then
  begin
    chosen := FindExplicit(AExplicit);
    if chosen = '' then
    begin
      FNotes.Add('找不到配置文件: ' + AExplicit);
      Exit;
    end;
  end
  else
  begin
    cand[0] := IncludeTrailingPathDelimiter(exeDir) + base + '.ini';
    cand[1] := IncludeTrailingPathDelimiter(exeDir) + 'lazarusWeb.ini';
    cand[2] := IncludeTrailingPathDelimiter(cwd) + base + '.ini';
    cand[3] := IncludeTrailingPathDelimiter(cwd) + 'lazarusWeb.ini';
    for i := Low(cand) to High(cand) do
      if FileExists(cand[i]) then
      begin
        chosen := cand[i];
        Break;
      end;
    if chosen = '' then Exit;              { 没配文件是正常状态，不是错误 }
  end;

  try
    fs := TFileStream.Create(chosen, fmOpenRead or fmShareDenyWrite);
  except
    on E: Exception do
    begin
      FNotes.Add('配置文件打不开: ' + chosen + ' (' + E.Message + ')');
      Exit;
    end;
  end;
  try
    if fs.Size > LW_CFG_MAX_SIZE then
    begin
      FNotes.Add('配置文件过大，忽略: ' + chosen);
      Exit;
    end;
    SetLength(buf, fs.Size);
    if fs.Size > 0 then
      fs.ReadBuffer(buf[1], fs.Size);
  finally
    fs.Free;
  end;

  FPath := ExpandFileName(chosen);
  ParseBytes(buf);
  Result := True;
end;

function TLWConfig.RawGet(const AKey: string; out AValue: string): Boolean;
var
  k: string;
  i: Integer;
begin
  Result := False;
  AValue := '';
  k := NormKey(AKey);
  i := FItems.IndexOfName(k);
  if i >= 0 then
  begin
    AValue := Copy(FItems[i], Length(FItems.Names[i]) + 2, MaxInt);
    Result := True;
  end;
end;

function TLWConfig.Has(const AKeys: array of string): Boolean;
var
  i: Integer;
  dummy: string;
begin
  Result := False;
  for i := Low(AKeys) to High(AKeys) do
    if RawGet(AKeys[i], dummy) then
      Exit(True);
end;

function TLWConfig.Str(const AKeys: array of string; const ADef: string): string;
var
  i: Integer;
  v: string;
begin
  for i := Low(AKeys) to High(AKeys) do
    if RawGet(AKeys[i], v) then
      Exit(v);
  Result := ADef;
end;

function TLWConfig.Int(const AKeys: array of string; ADef: Integer): Integer;
var
  i: Integer;
  v: string;
begin
  for i := Low(AKeys) to High(AKeys) do
    if RawGet(AKeys[i], v) then
      Exit(StrToIntDef(Trim(v), ADef));
  Result := ADef;
end;

end.
