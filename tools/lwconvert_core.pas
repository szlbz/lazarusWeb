{
  lazarusWeb :: lwconvert_core
  ------------------------------------------------------------------
  桌面工程 -> lazarusWeb 工程转换器的核心逻辑。

  从 lwconvert.lpr 抽出来的单元（原 lwconvert.lpr 是单文件程序，
  GUI 版 lwconvert_gui 需要复用同一套逻辑，控制台版只留命令行壳）。

  职责不变：
    - 只做确定性的文本改写，不猜业务语义；
    - 源文件按字节读写，GBK/UTF-8 都不会被转码破坏；
    - 不依赖 LCL —— 控制台版用纯 fpc 就能编。
}
unit lwconvert_core;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, StrUtils;

const
  VERSION = '2.1';

type
  TUnitInfo = class
    RelFile: string;      { unit1.pas（相对工程目录） }
    UName: string;        { Unit1 }
    BaseClass: string;    { TForm / TDataModule / '' }
    FormClass: string;    { TForm1 —— 被改写过的窗体类 }
    LfmRoot: string;      { Form1 —— .lfm 根组件名 }
  end;

  TConv = class
  public
    SrcDir: string;
    ProjName: string;             { project1（主程序名） }
    OutDir: string;
    Root: string;                 { lazarusWeb 根目录 }
    Units: TList;                 { TUnitInfo }
    Copied: TStringList;          { 全部复制的文件（相对路径） }
    Changed: TStringList;         { "unit1.pas: TForm1 -> TLWForm" }
    Registers: TStringList;       { TLWApp.Register(TForm1) 顺序 }
    Warnings: TStringList;
    Skipped: TStringList;         { 未转换的 class(Txxx)（非 TForm 基类） }
    Matrix: TStringList;          { 类名 -> ok/placeholder/...（来自 CONTROL_MATRIX.md） }
    constructor Create;
    destructor Destroy; override;
  end;

  TNode = class
    Name: string;
    Cls: string;
    Children: TList;
    constructor Create(const AName, ACls: string);
    destructor Destroy; override;
  end;

  TFormReport = class
    LfmFile: string;
    Root: TNode;
    Counts: TStringList;
    Unknown: TStringList;
  end;

{ ==================== 字节级文件读写 ==================== }

function LoadRaw(const AFile: string): RawByteString;
procedure SaveRaw(const AFile: string; const S: RawByteString);
function SplitLines(const S: RawByteString): TStringList;
function JoinLines(ALines: TStringList; const AEol: RawByteString): RawByteString;
function DetectEol(const S: RawByteString): RawByteString;

{ ==================== 目录扫描 / 复制 ==================== }

function SkipDir(const AName: string): Boolean;
function SkipFile(const AName: string): Boolean;
procedure CollectFiles(const ADir, AMask: string; AList: TStringList);
procedure CopyTree(const ASrc, ADst: string; AConv: TConv);

{ ==================== .lfm 解析 ==================== }

function ParseLfm(const AFile: string; out AErr: string): TNode;
procedure CollectCounts(ANode: TNode; ACounts, AUnknown: TStringList; AIsRoot: Boolean;
  AMatrix: TStringList);

{ ==================== 支持度矩阵（来自 docs/CONTROL_MATRIX.md） ==================== }

procedure LoadControlMatrix(const ARoot: string; AMap: TStringList);
function StatusText(const AStatus: string): string;

{ ==================== 报告 ==================== }

procedure WriteReport(ACtx: TConv; AReports: TList; const AOutFile: string);

{ ==================== 转换主流程 ==================== }

function DoConvert(ACtx: TConv; const AProjLpi, AProjLpr: string): Boolean;

{ ==================== 工程定位 ==================== }

function FindProjectIn(const ADir: string; out ALpi, ALpr: string): Boolean;
function FindLazarusWebRoot(const AStart: string): string;

implementation

{ ==================== 字节级文件读写 ==================== }

function LoadRaw(const AFile: string): RawByteString;
var
  fs: TFileStream;
  n: Int64;
begin
  Result := '';
  fs := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    n := fs.Size;
    SetLength(Result, n);
    if n > 0 then fs.ReadBuffer(Result[1], n);
  finally
    fs.Free;
  end;
end;

procedure SaveRaw(const AFile: string; const S: RawByteString);
var
  fs: TFileStream;
begin
  ForceDirectories(ExtractFileDir(AFile));
  fs := TFileStream.Create(AFile, fmCreate);
  try
    if Length(S) > 0 then fs.WriteBuffer(S[1], Length(S));
  finally
    fs.Free;
  end;
end;

function SplitLines(const S: RawByteString): TStringList;
var
  i, start, n: Integer;
  line: RawByteString;
begin
  Result := TStringList.Create;
  Result.SkipLastLineBreak := True;
  n := Length(S);
  start := 1;
  i := 1;
  while i <= n do
  begin
    if S[i] = #10 then
    begin
      line := Copy(S, start, i - start);
      if (Length(line) > 0) and (line[Length(line)] = #13) then
        SetLength(line, Length(line) - 1);
      Result.Add(line);
      start := i + 1;
    end;
    Inc(i);
  end;
  if start <= n then
    Result.Add(Copy(S, start, n - start + 1));
end;

function JoinLines(ALines: TStringList; const AEol: RawByteString): RawByteString;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to ALines.Count - 1 do
  begin
    if i > 0 then Result := Result + AEol;
    Result := Result + RawByteString(ALines[i]);
  end;
  if ALines.Count > 0 then Result := Result + AEol;
end;

{ 检测原文件的换行风格 }
function DetectEol(const S: RawByteString): RawByteString;
var
  p: Integer;
begin
  p := Pos(#13#10, S);
  if p > 0 then
    Result := #13#10
  else if Pos(#10, S) > 0 then
    Result := #10
  else
    Result := #13#10;
end;

{ ==================== 文本小工具 ==================== }

function PosCI(const ASub, AText: string): Integer;
begin
  Result := Pos(LowerCase(ASub), LowerCase(AText));
end;

function Trim2(const S: string): string;
begin
  Result := Trim(S);
  while (Length(Result) > 0) and (Result[Length(Result)] in [#13, #10]) do
    SetLength(Result, Length(Result) - 1);
end;

{ 从 APos（指向标识符的最后一个字符）往回取一个标识符 }
function WordBefore(const AText: string; APos: Integer): string;
var
  a: Integer;
begin
  a := APos;
  while (a >= 1) and (AText[a] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
    Dec(a);
  Result := Copy(AText, a + 1, APos - a);
end;

function PathPartsOf(const APath: string): TStringList;
var
  i: Integer;
  p: string;
begin
  Result := TStringList.Create;
  p := ExpandFileName(APath);
  p := StringReplace(p, '/', PathDelim, [rfReplaceAll]);
  Result.Delimiter := PathDelim;
  Result.StrictDelimiter := True;
  Result.DelimitedText := ExcludeTrailingPathDelimiter(p);
end;

{ 从 AFromDir 指向 AToDir 的相对路径（同盘才可能成功，失败返回绝对路径） }
function RelPath(const AFromDir, AToDir: string): string;
var
  f, t: TStringList;
  i, common: Integer;
begin
  f := PathPartsOf(AFromDir);
  t := PathPartsOf(AToDir);
  try
    if (f.Count = 0) or (t.Count = 0) or
       (not SameText(f[0], t[0])) then
      Exit(ExcludeTrailingPathDelimiter(ExpandFileName(AToDir)));
    common := 0;
    while (common < f.Count) and (common < t.Count) and
          SameText(f[common], t[common]) do
      Inc(common);
    if common = 0 then
      Exit(ExcludeTrailingPathDelimiter(ExpandFileName(AToDir)));
    Result := '';
    for i := common to f.Count - 1 do
      Result := Result + '..' + PathDelim;
    for i := common to t.Count - 1 do
      Result := Result + t[i] + PathDelim;
    if Result = '' then
      Result := '.'
    else
      SetLength(Result, Length(Result) - 1);
  finally
    f.Free;
    t.Free;
  end;
end;

{ 相对于工程目录的文件名（ExtractRelativePath 要求 Base 带分隔符，这里统一兜住）}
function RelFileIn(const ADir, AFile: string): string;
begin
  Result := ExtractRelativePath(IncludeTrailingPathDelimiter(ExpandFileName(ADir)),
    ExpandFileName(AFile));
  Result := StringReplace(Result, '/', PathDelim, [rfReplaceAll]);
end;

{ ==================== 目录扫描 / 复制 ==================== }

function SkipDir(const AName: string): Boolean;
begin
  Result := SameText(AName, 'lib') or SameText(AName, 'backup') or
    SameText(AName, 'backups') or SameText(AName, '.git') or
    SameText(AName, '.svn') or SameText(AName, '__history');
end;

function SkipFile(const AName: string): Boolean;
var
  ext: string;
begin
  ext := LowerCase(ExtractFileExt(AName));
  Result := (ext = '.exe') or (ext = '.o') or (ext = '.ppu') or
    (ext = '.obj') or (ext = '.compiled') or (ext = '.log') or
    (ext = '.dbg') or (ext = '.bak') or (ext = '.lps') or
    (ext = '.a') or (ext = '.or') or
    (ext = '.dll') or (ext = '.so') or (ext = '.dylib');
end;

procedure CollectFiles(const ADir, AMask: string; AList: TStringList);
var
  sr: TSearchRec;
  sub: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + AMask, faAnyFile, sr) = 0 then
  try
    repeat
      if (sr.Attr and faDirectory) = 0 then
        AList.Add(IncludeTrailingPathDelimiter(ADir) + sr.Name);
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faDirectory, sr) = 0 then
  try
    repeat
      sub := sr.Name;
      if ((sr.Attr and faDirectory) <> 0) and (sub <> '.') and (sub <> '..') and
         (not SkipDir(sub)) then
        CollectFiles(IncludeTrailingPathDelimiter(ADir) + sub, AMask, AList);
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

{ 复制整个工程（跳过产物目录；跳过输出目录自身） }
procedure CopyTree(const ASrc, ADst: string; AConv: TConv);
var
  sr: TSearchRec;
  sub, s, d: string;
begin
  ForceDirectories(ADst);
  if FindFirst(IncludeTrailingPathDelimiter(ASrc) + '*', faAnyFile, sr) = 0 then
  try
    repeat
      sub := sr.Name;
      if (sub = '.') or (sub = '..') then Continue;
      s := IncludeTrailingPathDelimiter(ASrc) + sub;
      d := IncludeTrailingPathDelimiter(ADst) + sub;
      if (sr.Attr and faDirectory) <> 0 then
      begin
        if SkipDir(sub) then Continue;
        { 输出目录可能就在源目录里，别自己复制自己 }
        if SameText(ExpandFileName(s), ExpandFileName(AConv.OutDir)) then Continue;
        CopyTree(s, d, AConv);
      end
      else
      begin
        if SkipFile(sub) then Continue;
        ForceDirectories(ExtractFileDir(d));
        SaveRaw(d, LoadRaw(s));
        AConv.Copied.Add(sub);
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

{ ==================== .lfm 解析 ==================== }

function ParseObjectLine(const ALine: string; out AName, ACls: string): Boolean;
var
  s, p: string;
  c1, c2: Integer;
begin
  Result := False;
  s := Trim(ALine);
  if Copy(s, 1, 7) = 'object ' then
    Delete(s, 1, 7)
  else if Copy(s, 1, 6) = 'inline ' then
    Delete(s, 1, 6)
  else
    Exit;
  c1 := Pos(':', s);
  if c1 < 2 then Exit;
  AName := Trim(Copy(s, 1, c1 - 1));
  p := Trim(Copy(s, c1 + 1, MaxInt));
  c2 := Pos(' ', p);
  if c2 > 0 then
    p := Copy(p, 1, c2 - 1);
  ACls := p;
  Result := (AName <> '') and (ACls <> '');
end;

function IsEndLine(const ALine: string): Boolean;
var
  s: string;
begin
  s := Trim(ALine);
  Result := (s = 'end') or (Copy(s, 1, 4) = 'end>');
end;

function ParseLfm(const AFile: string; out AErr: string): TNode;
var
  sl: TStringList;
  stack: TList;
  i: Integer;
  nm, cs: string;
  nd: TNode;
begin
  Result := nil;
  AErr := '';
  sl := TStringList.Create;
  stack := TList.Create;
  try
    try
      sl.Text := string(LoadRaw(AFile));
    except
      on E: Exception do
      begin
        AErr := E.Message;
        Exit;
      end;
    end;
    for i := 0 to sl.Count - 1 do
    begin
      if ParseObjectLine(sl[i], nm, cs) then
      begin
        nd := TNode.Create(nm, cs);
        if stack.Count = 0 then
        begin
          if Result <> nil then
          begin
            AErr := '一个文件里有多个根对象';
            nd.Free;
            Exit;
          end;
          Result := nd;
        end
        else
          TNode(stack[stack.Count - 1]).Children.Add(nd);
        stack.Add(nd);
      end
      else if IsEndLine(sl[i]) then
      begin
        if stack.Count > 0 then
          stack.Delete(stack.Count - 1);
      end;
    end;
    if Result = nil then
      AErr := '没有找到根对象';
  finally
    stack.Free;
    sl.Free;
  end;
end;

procedure CollectCounts(ANode: TNode; ACounts, AUnknown: TStringList; AIsRoot: Boolean;
  AMatrix: TStringList);
var
  i, n: Integer;
  lvl: string;
begin
  if not AIsRoot then
  begin
    n := ACounts.IndexOf(ANode.Cls);
    if n < 0 then
      ACounts.AddObject(ANode.Cls, TObject(PtrInt(1)))
    else
      ACounts.Objects[n] := TObject(PtrInt(PtrInt(ACounts.Objects[n]) + 1));
    if AMatrix.IndexOf(ANode.Cls) >= 0 then
      lvl := AMatrix.Values[ANode.Cls]
    else
      lvl := '';
    if (lvl <> 'ok') and (AUnknown.IndexOf(ANode.Cls) < 0) then
      AUnknown.Add(ANode.Cls);
  end;
  for i := 0 to ANode.Children.Count - 1 do
    CollectCounts(TNode(ANode.Children[i]), ACounts, AUnknown, False, AMatrix);
end;

{ ==================== 支持度矩阵（来自 docs/CONTROL_MATRIX.md） ==================== }

procedure LoadControlMatrix(const ARoot: string; AMap: TStringList);
var
  f: string;
  sl: TStringList;
  i, p1, p2, p3, p4: Integer;
  s, cls, status: string;
begin
  f := IncludeTrailingPathDelimiter(ARoot) + 'docs' + PathDelim + 'CONTROL_MATRIX.md';
  if not FileExists(f) then Exit;
  sl := TStringList.Create;
  try
    sl.Text := string(LoadRaw(f));
    for i := 0 to sl.Count - 1 do
    begin
      s := Trim(sl[i]);
      if (Copy(s, 1, 3) <> '| `') then Continue;
      p1 := Pos('|', s);
      p2 := PosEx('|', s, p1 + 1);   { class 之后 }
      p3 := PosEx('|', s, p2 + 1);   { kind 之后 }
      p4 := PosEx('|', s, p3 + 1);   { status 之后 }
      if (p2 < 0) or (p3 < 0) or (p4 < 0) then Continue;
      cls := Trim(Copy(s, p1 + 1, p2 - p1 - 1));
      cls := StringReplace(cls, '`', '', [rfReplaceAll]);
      status := Trim(Copy(s, p3 + 1, p4 - p3 - 1));
      if (cls <> '') and (Pos(' ', cls) = 0) then
        AMap.Values[cls] := status;
    end;
  finally
    sl.Free;
  end;
end;

function StatusText(const AStatus: string): string;
begin
  if AStatus = 'ok' then Result := '支持'
  else if AStatus = 'placeholder' then Result := '占位'
  else if AStatus = 'create-failed' then Result := '无法创建'
  else if AStatus = '' then Result := '未收录'
  else Result := AStatus;
end;

{ ==================== .pas 改写 ==================== }

{ 替换 class(TForm) -> class(TLWForm)，返回改写的类名（可能多个，逗号分隔） }
function RewritePasBase(AText: RawByteString; ACtx: TConv;
  const ARelName: string; out AClasses: string): RawByteString;
var
  scan, p, q, q2, i, cnt: Integer;
  s, clsName, low: string;
begin
  Result := AText;
  AClasses := '';
  cnt := 0;
  s := string(Result);
  scan := 1;
  while scan <= Length(s) do
  begin
    low := LowerCase(s);
    p := PosEx('class(', low, scan);
    if p = 0 then Break;
    q := p + 6;                               { class( 之后 }
    while (q <= Length(s)) and (s[q] = ' ') do Inc(q);
    if LowerCase(Copy(s, q, 5)) <> 'tform' then
    begin
      scan := q;                              { 不是 TForm（TFormXxx 等），继续往后找 }
      Continue;
    end;
    { 类名在 '=' 之前：TForm1 = class(TForm) }
    i := Pos('=', Copy(s, 1, p - 1));
    clsName := '';
    if i > 0 then
    begin
      q2 := i - 1;
      while (q2 >= 1) and (s[q2] in [' ', #9]) do Dec(q2);
      i := q2;
      while (q2 >= 1) and (s[q2] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do Dec(q2);
      clsName := Copy(s, q2 + 1, i - q2);
    end;
    s := Copy(s, 1, q - 1) + 'TLWForm' + Copy(s, q + 5, MaxInt);
    Inc(cnt);
    scan := q + 7;
    if clsName <> '' then
    begin
      if AClasses <> '' then AClasses := AClasses + ',';
      AClasses := AClasses + clsName;
      ACtx.Changed.Add(ARelName + ': ' + clsName + ' = class(TForm) -> class(TLWForm)');
    end;
  end;
  if cnt > 0 then
    Result := s;
end;

{ 在 interface 段的 uses 里补一个单元名 }
function EnsureUsesUnit(AText: RawByteString; const AUnitName: string;
  out AAdded: Boolean): RawByteString;
var
  s, low: string;
  usesPos, semiPos: Integer;
begin
  AAdded := False;
  Result := AText;
  s := string(Result);
  low := LowerCase(s);
  if Pos(',' + LowerCase(AUnitName), low) > 0 then Exit;
  if Pos(LowerCase(AUnitName) + ',', low) > 0 then Exit;
  if Pos(LowerCase(AUnitName) + ';', low) > 0 then Exit;
  { 直接找第一个 uses 关键字即可：unit 的 interface uses / program 的 uses
    都是文件里第一个（注释里出现的极罕见）。别去搜 interface —— 会被
    uses 里的 "Interfaces" 截胡。 }
  usesPos := PosEx('uses', low, 1);
  if usesPos = 0 then Exit;
  semiPos := PosEx(';', s, usesPos);
  if semiPos = 0 then Exit;
  s := Copy(s, 1, semiPos - 1) + ', ' + AUnitName + Copy(s, semiPos, MaxInt);
  AAdded := True;
  Result := s;
end;

{ ==================== .lpr 改写 ==================== }

function ExtractCreateFormClass(const ALine: string; out ACls: string): Boolean;
var
  p, q: Integer;
  args, a1: string;
begin
  Result := False;
  ACls := '';
  p := PosCI('createform(', ALine);
  if p = 0 then Exit;
  q := PosEx(')', ALine, p);
  if q = 0 then Exit;
  args := Copy(ALine, p + Length('createform('), q - p - Length('createform('));
  a1 := Trim(Copy(args, 1, Pos(',', args + ',') - 1));
  if (a1 = '') or (a1[1] <> 'T') then Exit;
  ACls := a1;
  Result := True;
end;

function LookupBaseClass(ACtx: TConv; const ACls: string): string;
var
  i: Integer;
  u: TUnitInfo;
begin
  Result := '';
  for i := 0 to ACtx.Units.Count - 1 do
  begin
    u := TUnitInfo(ACtx.Units[i]);
    if SameText(u.FormClass, ACls) then
      Exit(u.BaseClass);
  end;
end;

function RewriteLpr(AText: RawByteString; ACtx: TConv; const ARelName: string): RawByteString;
var
  sl, out2: TStringList;
  eol: RawByteString;
  i, p: Integer;
  line, cls, base: string;
  regLines: TStringList;
  hasRun, hasRes: Boolean;
begin
  eol := DetectEol(AText);
  sl := SplitLines(AText);
  out2 := TStringList.Create;
  regLines := TStringList.Create;
  try
    hasRun := False;
    hasRes := False;
    for i := 0 to sl.Count - 1 do
    begin
      line := sl[i];
      { Application.CreateForm(TXxx, Xxx); }
      if ExtractCreateFormClass(line, cls) then
      begin
        base := LookupBaseClass(ACtx, cls);
        if SameText(base, 'TDataModule') then
        begin
          { 数据模块：保留原语句（全局只建一次），给个警告 }
          out2.Add(line);
          ACtx.Warnings.Add(ARelName + ': ' + cls +
            ' 是 TDataModule，保留启动时创建（所有会话共享同一实例）');
        end
        else
        begin
          regLines.Add('  TLWApp.Register(' + cls + ');');
          ACtx.Registers.Add(cls);
          out2.Add('  TLWApp.Register(' + cls + ');   { 原 Application.CreateForm }');
          ACtx.Changed.Add(ARelName + ': Application.CreateForm(' + cls +
            ') -> TLWApp.Register(' + cls + ')');
        end;
        Continue;
      end;
      { Application.Run; }
      p := PosCI('application.run;', line);
      if p > 0 then
      begin
        line := Copy(line, 1, p - 1) + 'TLWApp.Run;' +
          Copy(line, p + Length('application.run;'), MaxInt);
        hasRun := True;
        ACtx.Changed.Add(ARelName + ': Application.Run -> TLWApp.Run');
        out2.Add(line);
        Continue;
      end;
      { $R *.res 但 .res 不存在 -> 删掉，否则 lazbuild 直接编译失败 }
      if PosCI('{$r *.res}', line) > 0 then
      begin
        hasRes := True;
        if not FileExists(IncludeTrailingPathDelimiter(ACtx.OutDir) +
          ChangeFileExt(ARelName, '.res')) then
        begin
          ACtx.Warnings.Add(ARelName + ': 没有 .res 文件，已移除 {$R *.res}');
          Continue;
        end;
      end;
      out2.Add(line);
    end;
    if not hasRun then
      ACtx.Warnings.Add(ARelName + ': 没找到 Application.Run，请手工确认入口');
    if not hasRes then ;
    Result := JoinLines(out2, eol);
  finally
    sl.Free;
    out2.Free;
    regLines.Free;
  end;
end;

{ ==================== .lpi 生成 ==================== }

function XmlEscape(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

function BuildLpi(ACtx: TConv; const AProjName, ATitle, ALprRel, AUnitsPath: string): string;
var
  sl: TStringList;
  i, p: Integer;
  u: TUnitInfo;
  fn: string;
begin
  sl := TStringList.Create;
  try
    sl.Add('<?xml version="1.0" encoding="UTF-8"?>');
    sl.Add('<CONFIG>');
    sl.Add('  <ProjectOptions>');
    sl.Add('    <Version Value="12"/>');
    sl.Add('    <General>');
    sl.Add('      <Flags>');
    sl.Add('        <MainUnitHasCreateFormStatements Value="False"/>');
    sl.Add('        <MainUnitHasTitleStatement Value="False"/>');
    sl.Add('      </Flags>');
    sl.Add('      <SessionStorage Value="InProjectDir"/>');
    sl.Add('      <Title Value="' + XmlEscape(ATitle) + '"/>');
    sl.Add('      <UseAppBundle Value="False"/>');
    sl.Add('    </General>');
    sl.Add('    <MacroValues Count="1">');
    sl.Add('      <Macro1 Name="LCLWidgetType" Value="nogui"/>');
    sl.Add('    </MacroValues>');
    sl.Add('    <BuildModes>');
    sl.Add('      <Item Name="Default" Default="True"/>');
    sl.Add('    </BuildModes>');
    sl.Add('    <PublishOptions>');
    sl.Add('      <Version Value="2"/>');
    sl.Add('    </PublishOptions>');
    sl.Add('    <RunParams>');
    sl.Add('      <FormatVersion Value="2"/>');
    sl.Add('    </RunParams>');
    sl.Add('    <RequiredPackages>');
    sl.Add('      <Item>');
    sl.Add('        <PackageName Value="LCL"/>');
    sl.Add('      </Item>');
    sl.Add('    </RequiredPackages>');
    sl.Add('    <Units>');
    sl.Add('      <Unit>');
    sl.Add('        <Filename Value="' + XmlEscape(ALprRel) + '"/>');
    sl.Add('        <IsPartOfProject Value="True"/>');
    sl.Add('      </Unit>');
    for i := 0 to ACtx.Units.Count - 1 do
    begin
      u := TUnitInfo(ACtx.Units[i]);
      sl.Add('      <Unit>');
      sl.Add('        <Filename Value="' + XmlEscape(u.RelFile) + '"/>');
      sl.Add('        <IsPartOfProject Value="True"/>');
      if u.LfmRoot <> '' then
      begin
        sl.Add('        <ComponentName Value="' + XmlEscape(u.LfmRoot) + '"/>');
        sl.Add('        <HasResources Value="True"/>');
        sl.Add('        <ResourceBaseClass Value="Form"/>');
      end;
      sl.Add('      </Unit>');
    end;
    sl.Add('    </Units>');
    sl.Add('  </ProjectOptions>');
    sl.Add('  <CompilerOptions>');
    sl.Add('    <Version Value="11"/>');
    sl.Add('    <Target>');
    sl.Add('      <Filename Value="' + XmlEscape(AProjName) + '"/>');
    sl.Add('    </Target>');
    sl.Add('    <SearchPaths>');
    sl.Add('      <IncludeFiles Value="$(ProjOutDir)"/>');
    sl.Add('      <UnitOutputDirectory Value="lib\$(TargetCPU)-$(TargetOS)"/>');
    sl.Add('      <OtherUnitFiles Value="' + XmlEscape(AUnitsPath) + '"/>');
    sl.Add('    </SearchPaths>');
    sl.Add('    <Linking>');
    sl.Add('      <Options>');
    sl.Add('        <Win32>');
    sl.Add('          <GraphicApplication Value="False"/>');
    sl.Add('        </Win32>');
    sl.Add('      </Options>');
    sl.Add('    </Linking>');
    sl.Add('  </CompilerOptions>');
    sl.Add('</CONFIG>');
    Result := sl.Text;
    { TStringList.Text 用平台换行；XML 无所谓，但保持 LF 更干净 }
    Result := StringReplace(Result, #13#10, #10, [rfReplaceAll]);
  finally
    sl.Free;
  end;
end;

{ 读原 .lpi 里的 Title / OtherUnitFiles（简单文本抓取，不做完整 XML 解析） }
procedure ReadLpiMeta(const ALpiFile: string; out ATitle, AOtherUnits: string);
var
  s: string;
  p, q: Integer;
begin
  ATitle := '';
  AOtherUnits := '';
  if not FileExists(ALpiFile) then Exit;
  s := string(LoadRaw(ALpiFile));
  p := PosCI('<Title Value="', s);
  if p > 0 then
  begin
    p := p + Length('<Title Value="');
    q := PosEx('"', s, p);
    if q > p then ATitle := Copy(s, p, q - p);
  end;
  p := PosCI('<OtherUnitFiles Value="', s);
  if p > 0 then
  begin
    p := p + Length('<OtherUnitFiles Value="');
    q := PosEx('"', s, p);
    if q > p then AOtherUnits := Copy(s, p, q - p);
  end;
end;

{ 读原 .lpi 的单元列表（<Filename Value="xx.pas"/>） }
procedure ReadLpiUnits(const ALpiFile: string; AList: TStringList);
var
  s: string;
  p, q: Integer;
  v: string;
begin
  if not FileExists(ALpiFile) then Exit;
  s := string(LoadRaw(ALpiFile));
  p := 1;
  while True do
  begin
    p := PosEx('<Filename Value="', s, p);
    if p = 0 then Break;
    p := p + Length('<Filename Value="');
    q := PosEx('"', s, p);
    if q = 0 then Break;
    v := Copy(s, p, q - p);
    if (LowerCase(ExtractFileExt(v)) = '.pas') or (LowerCase(ExtractFileExt(v)) = '.pp') then
      if AList.IndexOf(v) < 0 then AList.Add(v);
    p := q;
  end;
end;

{ 找 .pas 里的基类：Txxx = class(TForm|TDataModule|TOther) }
procedure ScanUnitClasses(ACtx: TConv; const AFile, ARelFile: string; AInfo: TUnitInfo);
var
  sl: TStringList;
  i, p: Integer;
  s, lhs, rhs: string;
begin
  sl := SplitLines(LoadRaw(AFile));
  try
    AInfo.RelFile := ARelFile;
    AInfo.UName := ChangeFileExt(ExtractFileName(AFile), '');
    for i := 0 to sl.Count - 1 do
    begin
      s := Trim(sl[i]);
      p := PosCI('= class(', s);
      if p = 0 then Continue;
      lhs := Trim(Copy(s, 1, p - 1));
      if (lhs = '') or (lhs[1] <> 'T') or (Pos(' ', lhs) > 0) then Continue;
      rhs := Trim(Copy(s, p + Length('= class('), MaxInt));
      if (Length(rhs) > 0) and (rhs[Length(rhs)] = ')') then
        SetLength(rhs, Length(rhs) - 1);
      if Pos(',', rhs) > 0 then rhs := Trim(Copy(rhs, 1, Pos(',', rhs) - 1));
      if AInfo.FormClass = '' then
      begin
        AInfo.FormClass := lhs;
        AInfo.BaseClass := rhs;
      end;
    end;
  finally
    sl.Free;
  end;
end;

{ ==================== 报告 ==================== }

procedure WriteReport(ACtx: TConv; AReports: TList; const AOutFile: string);
var
  sl: TStringList;
  i, j, total, unknownTotal: Integer;
  r: TFormReport;
  cls, lvl: string;
begin
  sl := TStringList.Create;
  try
    sl.Add('# lazarusWeb 转换报告');
    sl.Add('');
    sl.Add('生成时间: ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    sl.Add('源工程  : `' + ACtx.SrcDir + '`');
    sl.Add('输出目录: `' + ACtx.OutDir + '`');
    sl.Add('转换器  : lwconvert ' + VERSION);
    sl.Add('');
    sl.Add('## 一、源码改写');
    sl.Add('');
    if ACtx.Changed.Count = 0 then
      sl.Add('（没有需要改写的行）')
    else
    begin
      sl.Add('| 文件 | 改写 |');
      sl.Add('|---|---|');
      for i := 0 to ACtx.Changed.Count - 1 do
        sl.Add('| ' + ACtx.Changed[i] + ' |');
    end;
    sl.Add('');
    sl.Add('## 二、窗体注册顺序（第一个是默认窗体）');
    sl.Add('');
    if ACtx.Registers.Count = 0 then
      sl.Add('（没有找到 Application.CreateForm —— 请手工在 .lpr 里加 TLWApp.Register）')
    else
      for i := 0 to ACtx.Registers.Count - 1 do
        sl.Add(Format('%d. `TLWApp.Register(%s);`', [i + 1, ACtx.Registers[i]]));
    sl.Add('');
    sl.Add('## 三、控件支持度');
    sl.Add('');
    total := 0;
    unknownTotal := 0;
    for i := 0 to AReports.Count - 1 do
    begin
      r := TFormReport(AReports[i]);
      sl.Add('### ' + ExtractFileName(r.LfmFile));
      sl.Add('');
      sl.Add('| 控件类 | 数量 | 支持度 |');
      sl.Add('|---|---:|---|');
      for j := 0 to r.Counts.Count - 1 do
      begin
        cls := r.Counts[j];
        if ACtx.Matrix.IndexOf(cls) >= 0 then
          lvl := StatusText(ACtx.Matrix.Values[cls])
        else
          lvl := '未收录';
        sl.Add(Format('| %s | %d | %s |', [cls, PtrInt(r.Counts.Objects[j]), lvl]));
        Inc(total, PtrInt(r.Counts.Objects[j]));
      end;
      if r.Unknown.Count > 0 then
      begin
        Inc(unknownTotal);
        sl.Add('');
        sl.Add('> 这些类不在支持矩阵里 / 只做占位：' + r.Unknown.CommaText);
      end;
      sl.Add('');
    end;
    sl.Add(Format('共 %d 个窗体、%d 个控件实例；%d 个窗体含未完整支持的控件。',
      [AReports.Count, total, unknownTotal]));
    sl.Add('');
    sl.Add('## 四、警告与待办');
    sl.Add('');
    if ACtx.Warnings.Count = 0 then
      sl.Add('无。')
    else
      for i := 0 to ACtx.Warnings.Count - 1 do
        sl.Add('- ' + ACtx.Warnings[i]);
    if ACtx.Skipped.Count > 0 then
    begin
      sl.Add('');
      sl.Add('非 TForm 基类的类（未改写基类，按原逻辑处理）：');
      for i := 0 to ACtx.Skipped.Count - 1 do
        sl.Add('- ' + ACtx.Skipped[i]);
    end;
    sl.Add('');
    sl.Add('## 五、编译与运行');
    sl.Add('');
    sl.Add('```bat');
    sl.Add('lazbuild -B --ws=nogui ' + IncludeTrailingPathDelimiter(ACtx.OutDir) +
      ACtx.ProjName + '.lpi');
    sl.Add('```');
    sl.Add('');
    SaveRaw(AOutFile, sl.Text);
  finally
    sl.Free;
  end;
end;

{ ==================== 转换主流程 ==================== }

function DoConvert(ACtx: TConv; const AProjLpi, AProjLpr: string): Boolean;
var
  lpiUnits, pasFiles, lfmFiles: TStringList;
  i, p: Integer;
  u: TUnitInfo;
  rel, src, dst, lprRel, projName, title, otherUnits, unitsPath, base: string;
  root: TNode;
  err: string;
  reports: TList;
  r: TFormReport;
  txt: RawByteString;
  classes, added, lfmDst, lt: string;
  added2, added3: Boolean;
begin
  Result := False;
  reports := TList.Create;
  lpiUnits := TStringList.Create;
  pasFiles := TStringList.Create;
  lfmFiles := TStringList.Create;
  try
    { 1) 复制工程 }
    CopyTree(ACtx.SrcDir, ACtx.OutDir, ACtx);

    { 2) 单元清单：优先用 .lpi 的列表（避免把不相关 .pas 也转进来） }
    ReadLpiUnits(AProjLpi, lpiUnits);
    if lpiUnits.Count = 0 then
    begin
      CollectFiles(ACtx.SrcDir, '*.pas', pasFiles);
      for i := 0 to pasFiles.Count - 1 do
        lpiUnits.Add(RelFileIn(ACtx.SrcDir, pasFiles[i]));
    end;

    { 3) 逐单元扫描 + 改写 }
    for i := 0 to lpiUnits.Count - 1 do
    begin
      rel := StringReplace(lpiUnits[i], '/', PathDelim, [rfReplaceAll]);
      src := IncludeTrailingPathDelimiter(ACtx.SrcDir) + rel;
      if not FileExists(src) then
      begin
        ACtx.Warnings.Add('单元文件不存在（.lpi 里列了但磁盘没有）: ' + rel);
        Continue;
      end;
      u := TUnitInfo.Create;
      ScanUnitClasses(ACtx, src, rel, u);
      { .lfm 根组件名 }
      dst := ChangeFileExt(src, '.lfm');
      if FileExists(dst) then
      begin
        root := ParseLfm(dst, err);
        if root <> nil then
        begin
          u.LfmRoot := root.Name;
          r := TFormReport.Create;
          r.LfmFile := dst;
          r.Root := root;
          r.Counts := TStringList.Create;
          r.Unknown := TStringList.Create;
          CollectCounts(root, r.Counts, r.Unknown, True, ACtx.Matrix);
          reports.Add(r);
        end
        else
          ACtx.Warnings.Add(rel + ': .lfm 解析失败 (' + err + ')');
      end;

      { 改写：只改 TForm 基类（TDataModule 等保持原样） }
      if SameText(u.BaseClass, 'TForm') then
      begin
        dst := IncludeTrailingPathDelimiter(ACtx.OutDir) + rel;
        txt := LoadRaw(dst);
        if PosCI('class(tform', string(txt)) > 0 then
        begin
          txt := RewritePasBase(txt, ACtx, rel, classes);
          if classes <> '' then
          begin
            u.FormClass := Trim(Copy(classes, 1, Pos(',', classes + ',') - 1));
            txt := EnsureUsesUnit(txt, 'lwform', added2);
            if added2 then
              ACtx.Changed.Add(rel + ': uses + lwform');
            SaveRaw(dst, txt);
          end;

          { .lfm 里的 TDBNavigator 必须换成子类名：TDBNavigator 这个类名
            LCL 已经注册过，RegisterClassAlias 抢不过来（NOTES 坑 41-4），
            nogui 下加载会去读 glyph 位图直接崩。 }
          lfmDst := IncludeTrailingPathDelimiter(ACtx.OutDir) + ChangeFileExt(rel, '.lfm');
          if FileExists(lfmDst) then
          begin
            lt := LoadRaw(lfmDst);
            if PosCI(': TDBNavigator', lt) > 0 then
            begin
              lt := StringReplace(lt, ': TDBNavigator', ': TLWDBNavigator',
                [rfReplaceAll, rfIgnoreCase]);
              SaveRaw(lfmDst, lt);
              txt := EnsureUsesUnit(txt, 'lwdbnav', added3);
              if added3 then
                ACtx.Changed.Add(rel + ': .lfm TDBNavigator -> TLWDBNavigator, uses + lwdbnav');
              SaveRaw(dst, txt);
            end;
          end;
        end
        else
          ACtx.Warnings.Add(rel + ': 有 .lfm 但没找到 class(TForm)，跳过基类改写');
      end
      else if u.BaseClass <> '' then
        ACtx.Skipped.Add(rel + ': ' + u.FormClass + ' = class(' + u.BaseClass + ')');

      if u.FormClass <> '' then
        ACtx.Units.Add(u)
      else
        u.Free;
    end;

    { 4) 主程序改写 }
    lprRel := RelFileIn(ACtx.SrcDir, AProjLpr);
    dst := IncludeTrailingPathDelimiter(ACtx.OutDir) + lprRel;
    if not FileExists(dst) then
    begin
      ACtx.Warnings.Add('输出目录没有主程序 ' + lprRel);
      Exit;
    end;
    txt := LoadRaw(dst);
    txt := RewriteLpr(txt, ACtx, lprRel);
    txt := EnsureUsesUnit(txt, 'lwapp', added2);
    if added2 then
      ACtx.Changed.Add(lprRel + ': uses + lwapp');
    SaveRaw(dst, txt);

    { 5) 生成 .lpi }
    projName := ChangeFileExt(ExtractFileName(AProjLpr), '');
    ACtx.ProjName := projName;
    ReadLpiMeta(AProjLpi, title, otherUnits);
    if title = '' then title := projName;
    { 搜索路径 = lazarusWeb/src/core + 原工程的额外单元路径 }
    unitsPath := RelPath(ACtx.OutDir, IncludeTrailingPathDelimiter(ACtx.Root) + 'src' + PathDelim + 'core');
    if (otherUnits <> '') and (Pos('$(ProjOutDir)', otherUnits) = 0) then
      unitsPath := unitsPath + ';' + otherUnits;
    dst := IncludeTrailingPathDelimiter(ACtx.OutDir) + projName + '.lpi';
    SaveRaw(dst, BuildLpi(ACtx, projName, title, lprRel, unitsPath));
    ACtx.Changed.Add(projName + '.lpi: 重新生成为 nogui 工程');

    { 6) 报告 }
    WriteReport(ACtx, reports, IncludeTrailingPathDelimiter(ACtx.OutDir) + 'lwconvert-report.md');
    Result := True;
  finally
    for i := 0 to reports.Count - 1 do
    begin
      r := TFormReport(reports[i]);
      r.Counts.Free;
      r.Unknown.Free;
      r.Free;
    end;
    reports.Free;
    lpiUnits.Free;
    pasFiles.Free;
    lfmFiles.Free;
  end;
end;

{ ==================== 工程定位 ==================== }

function FindProjectIn(const ADir: string; out ALpi, ALpr: string): Boolean;
var
  sr: TSearchRec;
  lpis, lprs: TStringList;
  i: Integer;
begin
  Result := False;
  ALpi := '';
  ALpr := '';
  lpis := TStringList.Create;
  lprs := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*.lpi', faAnyFile, sr) = 0 then
    try
      repeat
        if Pos('_web', LowerCase(sr.Name)) = 0 then
          lpis.Add(IncludeTrailingPathDelimiter(ADir) + sr.Name);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
    if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*.lpr', faAnyFile, sr) = 0 then
    try
      repeat
        lprs.Add(IncludeTrailingPathDelimiter(ADir) + sr.Name);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
    if lpis.Count > 0 then
    begin
      ALpi := lpis[0];
      for i := 0 to lprs.Count - 1 do
        if SameText(ChangeFileExt(ExtractFileName(lprs[i]), ''),
          ChangeFileExt(ExtractFileName(ALpi), '')) then
        begin
          ALpr := lprs[i];
          Break;
        end;
      if (ALpr = '') and (lprs.Count > 0) then
        ALpr := lprs[0];
      Result := ALpr <> '';
    end
    else if lprs.Count > 0 then
    begin
      ALpr := lprs[0];
      ALpi := ChangeFileExt(ALpr, '.lpi');
      Result := True;
    end;
  finally
    lpis.Free;
    lprs.Free;
  end;
end;

function FindLazarusWebRoot(const AStart: string): string;
var
  d: string;
  i: Integer;
begin
  Result := '';
  d := IncludeTrailingPathDelimiter(ExpandFileName(AStart));
  for i := 0 to 8 do
  begin
    if FileExists(d + 'src' + PathDelim + 'core' + PathDelim + 'lwapp.pas') then
      Exit(ExcludeTrailingPathDelimiter(d));
    d := ExcludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(d)));
    if d = '' then Break;
    d := IncludeTrailingPathDelimiter(d);
  end;
end;

{ ==================== 类型实现 ==================== }

constructor TNode.Create(const AName, ACls: string);
begin
  inherited Create;
  Name := AName;
  Cls := ACls;
  Children := TList.Create;
end;

destructor TNode.Destroy;
var
  i: Integer;
begin
  for i := 0 to Children.Count - 1 do
    TNode(Children[i]).Free;
  Children.Free;
  inherited Destroy;
end;

constructor TConv.Create;
begin
  inherited Create;
  Units := TList.Create;
  Copied := TStringList.Create;
  Changed := TStringList.Create;
  Registers := TStringList.Create;
  Warnings := TStringList.Create;
  Skipped := TStringList.Create;
  Matrix := TStringList.Create;
end;

destructor TConv.Destroy;
var
  i: Integer;
begin
  for i := 0 to Units.Count - 1 do
    TUnitInfo(Units[i]).Free;
  Units.Free;
  Copied.Free;
  Changed.Free;
  Registers.Free;
  Warnings.Free;
  Skipped.Free;
  Matrix.Free;
  inherited Destroy;
end;

end.
