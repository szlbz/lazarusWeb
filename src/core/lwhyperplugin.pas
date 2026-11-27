{
  lazarusWeb :: lwhyper 插件宿主管理（清单 / 进程 / 热更新 / 路由登记）

  TLWHyperServer 在 PluginMode 下把插件宿主能力委托给本单元；保留旧的
  "单 exe 多 worker"模式时本单元完全不参与。

  与 demos/pluginsDemo/common/upluginproc.pas 的关系：协议与目录约定一致
  （<root>\<插件目录>\<名>.plugin.ini、.run 运行副本、启动守卫三参数），
  但这里不依赖 lwapp/TLWApp，所以 lwhyper 独立进程也能直接跑插件宿主。
}
unit lwhyperplugin;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Process, ssockets, DateUtils,
  fpjson, jsonparser, lwrlog, lwconfig, lwroute, lwpluginguard
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

type
  TLWHyperPlugin = class
  public
    Name: string;       { 路由名：/p/<name>/ }
    Title: string;      { 菜单/面板显示名 }
    Group: string;      { 分组，保留字段 }
    Roles: string;      { 清单 roles=，逗号分隔；空 = 任一已登录用户 }
    ExePath: string;    { 原始 exe（可随时重编） }
    IniPath: string;    { 同名 ini }
    RunDir: string;     { .run 运行副本目录 }
    RunExe: string;
    RunIni: string;
    Port: Word;
    SourceStamp: LongInt;
    Seq: Integer;       { 热更新代数 }
    Restarts: Integer;  { 崩溃重启次数 }
    Proc: TProcess;
    Alive: Boolean;
  end;

  TLWHyperPluginManager = class;

  { 插件健康巡检：崩了自动重启（带守卫参数），热更新期间不插手进程 }
  TLWHyperPluginMonitor = class(TThread)
  private
    FOwner: TLWHyperPluginManager;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TLWHyperPluginManager);
  end;

  TLWHyperPluginManager = class
  private
    FList: TList;
    FRoot: string;
    FLock: TRTLCriticalSection;
    FMonitor: TLWHyperPluginMonitor;
    FUpdating: Boolean;
    function StartOne(p: TLWHyperPlugin): Boolean;
    procedure StopOne(p: TLWHyperPlugin);
    procedure CopyRunFiles(p: TLWHyperPlugin);
    function PortOpen(APort: Word): Boolean;
    procedure ScanInto(AList: TList);
  public
    constructor Create(const ARoot: string);
    destructor Destroy; override;
    { 扫描 <Root>\*\*.plugin.ini；重复调用不重复扫描 }
    function Discover: Integer;
    { 重新扫描：新增的拉起并登记路由，消失的停进程并摘路由 }
    function Rescan: Integer;
    function LaunchAll: Integer;
    procedure RegisterRoutes;
    procedure StopAll;
    function HotUpdate(AIndex: Integer): Boolean;
    function SourceChanged(AIndex: Integer): Boolean;
    function StatusJSON: string;
    function Count: Integer;
    function Item(AIndex: Integer): TLWHyperPlugin;
    function ByName(const AName: string): TLWHyperPlugin;
    procedure StartMonitor;
    procedure StopMonitor;
    property Root: string read FRoot;
    property Updating: Boolean read FUpdating;
  end;

implementation

const
  MANIFEST_SUFFIX = '.plugin.ini';
  STOP_WAIT_MS = 5000;
  PLUGIN_POLL_MS = 2000;

{ ---------------- 工具 ---------------- }

function ValidPluginName(const S: string): Boolean;
var
  i: Integer;
  c: Char;
begin
  Result := False;
  if (S = '') or (Length(S) > 64) then Exit;
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if not (((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
            ((c >= '0') and (c <= '9')) or (c = '-') or (c = '_') or
            (c = '.')) then Exit;
  end;
  Result := True;
end;

function IsAbsPath(const S: string): Boolean;
begin
  Result := (Length(S) > 1) and (S[2] = ':');
  if (not Result) and (Length(S) > 0) then
    Result := (S[1] = '/') or (S[1] = '\');
end;

procedure CopyFileRaw(const ASrc, ADst: string);
var
  fs, fd: TFileStream;
begin
  fs := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
  try
    fd := TFileStream.Create(ADst, fmCreate);
    try
      fd.CopyFrom(fs, 0);
    finally
      fd.Free;
    end;
    {$IFDEF UNIX}
    { FPC 新建副本是 0644，TProcess 会 Permission denied }
    fpChmod(ADst, &755);
    {$ENDIF}
  finally
    fs.Free;
  end;
end;

function IdxByName(AList: TList; const AName: string): Integer;
var
  i: Integer;
begin
  Result := -1;
  if AList = nil then Exit;
  for i := 0 to AList.Count - 1 do
    if SameText(TLWHyperPlugin(AList[i]).Name, AName) then Exit(i);
end;

{ ---------------- TLWHyperPluginManager ---------------- }

constructor TLWHyperPluginManager.Create(const ARoot: string);
begin
  inherited Create;
  FRoot := ExcludeTrailingPathDelimiter(ExpandFileName(ARoot));
  FList := TList.Create;
  InitCriticalSection(FLock);
  FUpdating := False;
end;

destructor TLWHyperPluginManager.Destroy;
var
  i: Integer;
begin
  StopMonitor;
  StopAll;
  for i := 0 to FList.Count - 1 do
    TLWHyperPlugin(FList[i]).Free;
  FList.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TLWHyperPluginManager.Count: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FList.Count;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLWHyperPluginManager.Item(AIndex: Integer): TLWHyperPlugin;
begin
  EnterCriticalSection(FLock);
  try
    if (AIndex < 0) or (AIndex >= FList.Count) then
      Result := nil
    else
      Result := TLWHyperPlugin(FList[AIndex]);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLWHyperPluginManager.ByName(const AName: string): TLWHyperPlugin;
var
  i: Integer;
begin
  EnterCriticalSection(FLock);
  try
    i := IdxByName(FList, AName);
    if i < 0 then Result := nil else Result := TLWHyperPlugin(FList[i]);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLWHyperPluginManager.PortOpen(APort: Word): Boolean;
var
  s: TInetSocket;
begin
  Result := False;
  s := nil;
  try
    try
      s := TInetSocket.Create('127.0.0.1', APort);
      Result := True;
    except
      Result := False;
    end;
  finally
    s.Free;
  end;
end;

{ 解析一个清单文件；成功返回新对象（不加入列表） }
function ParseManifest(const AFile, ARoot: string): TLWHyperPlugin;
var
  cfg: TLWConfig;
  fileName, base, nm, exe, dir, alt: string;
  port: Integer;
begin
  Result := nil;
  cfg := TLWConfig.Create;
  try
    if not cfg.Load(AFile) then
    begin
      LWLog('[hyper-plugin] 清单读取失败: ' + AFile);
      Exit;
    end;
    fileName := ExtractFileName(AFile);
    base := Copy(fileName, 1, Length(fileName) - Length(MANIFEST_SUFFIX));
    nm := Trim(cfg.Str(['name'], base));
    if not ValidPluginName(nm) then
    begin
      LWLog('[hyper-plugin] 插件名非法，跳过: ' + nm + ' (' + AFile + ')');
      Exit;
    end;
    port := cfg.Int(['port'], 0);
    if (port <= 0) or (port > 65535) then
    begin
      LWLog('[hyper-plugin] 插件 port 非法，跳过: ' + nm);
      Exit;
    end;
    dir := ExtractFileDir(AFile);
    exe := Trim(cfg.Str(['exe'], ''));
    if exe = '' then exe := base + '.exe';
    if IsAbsPath(exe) then
      exe := ExpandFileName(exe)
    else
      exe := ExpandFileName(IncludeTrailingPathDelimiter(dir) + exe);
    { UNIX 上优先同名的无后缀 ELF；Windows PE 副本可能混在交付包里 }
    if CompareText(ExtractFileExt(exe), '.exe') = 0 then
    begin
      alt := Copy(exe, 1, Length(exe) - 4);
      if FileExists(alt) then
      begin
        {$IFDEF UNIX}
        exe := alt;
        {$ELSE}
        if not FileExists(exe) then exe := alt;
        {$ENDIF}
      end;
    end;

    Result := TLWHyperPlugin.Create;
    Result.Name := nm;
    Result.Title := Trim(cfg.Str(['title'], nm));
    Result.Group := Trim(cfg.Str(['group'], ''));
    Result.Roles := Trim(cfg.Str(['roles'], ''));
    Result.ExePath := exe;
    Result.IniPath := ChangeFileExt(exe, '.ini');
    Result.RunDir := IncludeTrailingPathDelimiter(ARoot) + '.run';
    Result.RunExe := IncludeTrailingPathDelimiter(Result.RunDir) + ExtractFileName(exe);
    Result.RunIni := ChangeFileExt(Result.RunExe, '.ini');
    Result.Port := Word(port);
    Result.SourceStamp := -1;
    Result.Seq := 0;
    Result.Restarts := 0;
    Result.Proc := nil;
    Result.Alive := False;
    if not FileExists(exe) then
      LWLog('[hyper-plugin] 警告: 插件 exe 尚不存在: ' + exe);
  finally
    cfg.Free;
  end;
end;

procedure TLWHyperPluginManager.ScanInto(AList: TList);
var
  dir, mask: string;
  sr, mr: TSearchRec;
  files: TStringList;
  i: Integer;
  p: TLWHyperPlugin;
begin
  files := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(FRoot) + '*', faAnyFile, sr) = 0 then
    try
      repeat
        if ((sr.Attr and faDirectory) = 0) or (sr.Name = '.') or
           (sr.Name = '..') or (sr.Name = '.run') then Continue;
        dir := IncludeTrailingPathDelimiter(
          IncludeTrailingPathDelimiter(FRoot) + sr.Name);
        mask := dir + '*' + MANIFEST_SUFFIX;
        if FindFirst(mask, faAnyFile, mr) = 0 then
        try
          repeat
            if (mr.Attr and faDirectory) = 0 then files.Add(dir + mr.Name);
          until FindNext(mr) <> 0;
        finally
          FindClose(mr);
        end;
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
    files.Sort;
    for i := 0 to files.Count - 1 do
    begin
      p := ParseManifest(files[i], FRoot);
      if p = nil then Continue;
      if IdxByName(AList, p.Name) >= 0 then
      begin
        LWLog('[hyper-plugin] 插件名重复，忽略: ' + files[i]);
        p.Free;
        Continue;
      end;
      AList.Add(p);
    end;
  finally
    files.Free;
  end;
end;

function TLWHyperPluginManager.Discover: Integer;
begin
  EnterCriticalSection(FLock);
  try
    if FList.Count = 0 then ScanInto(FList);
    Result := FList.Count;
  finally
    LeaveCriticalSection(FLock);
  end;
  LWLogFmt('[hyper-plugin] 从 %s 发现插件 %d 个', [FRoot, Result]);
end;

function TLWHyperPluginManager.Rescan: Integer;
var
  fresh: TList;
  i, k, added, removed: Integer;
  np, old: TLWHyperPlugin;
  reroute: Boolean;
begin
  added := 0;
  removed := 0;
  fresh := TList.Create;
  EnterCriticalSection(FLock);
  try
    ScanInto(fresh);
    { 清单消失：停进程、摘路由 }
    for i := FList.Count - 1 downto 0 do
    begin
      old := TLWHyperPlugin(FList[i]);
      if IdxByName(fresh, old.Name) < 0 then
      begin
        StopOne(old);
        LWRouteRemove(old.Name);
        FList.Delete(i);
        old.Free;
        Inc(removed);
      end;
    end;
    { 新清单逐条对齐 }
    for i := 0 to fresh.Count - 1 do
    begin
      np := TLWHyperPlugin(fresh[i]);
      k := IdxByName(FList, np.Name);
      if k < 0 then
      begin
        FList.Add(np);
        LWRouteSet(np.Name, '127.0.0.1:' + IntToStr(np.Port));
        StartOne(np);
        Inc(added);
        Continue;
      end;
      old := TLWHyperPlugin(FList[k]);
      old.Title := np.Title;
      old.Group := np.Group;
      old.Roles := np.Roles;
      reroute := (old.Port <> np.Port) or (not SameText(old.ExePath, np.ExePath));
      if reroute then
      begin
        StopOne(old);
        old.Port := np.Port;
        old.ExePath := np.ExePath;
        old.IniPath := np.IniPath;
        old.RunDir := np.RunDir;
        old.RunExe := np.RunExe;
        old.RunIni := np.RunIni;
        LWRouteSet(old.Name, '127.0.0.1:' + IntToStr(old.Port));
        StartOne(old);
      end;
      np.Free;
    end;
    fresh.Clear;   { 已接管的对象不再重复释放 }
    Result := FList.Count;
  finally
    for i := 0 to fresh.Count - 1 do
      TLWHyperPlugin(fresh[i]).Free;
    fresh.Free;
    LeaveCriticalSection(FLock);
  end;
  LWLogFmt('[hyper-plugin] 重新扫描完成：共 %d 个（新增 %d，移除 %d）',
    [Result, added, removed]);
end;

procedure TLWHyperPluginManager.CopyRunFiles(p: TLWHyperPlugin);
begin
  ForceDirectories(p.RunDir);
  CopyFileRaw(p.ExePath, p.RunExe);
  if FileExists(p.IniPath) then CopyFileRaw(p.IniPath, p.RunIni);
end;

function TLWHyperPluginManager.StartOne(p: TLWHyperPlugin): Boolean;
var
  nonce: string;
  deadline: QWord;
begin
  Result := False;
  if p = nil then Exit;
  if not FileExists(p.ExePath) then
  begin
    LWLog('[hyper-plugin] 插件 exe 不存在，无法启动: ' + p.ExePath);
    Exit;
  end;
  try
    CopyRunFiles(p);
  except
    on E: Exception do
    begin
      LWLog('[hyper-plugin] 复制运行副本失败 ' + p.Name + ': ' + E.Message);
      Exit;
    end;
  end;
  p.SourceStamp := FileAge(p.ExePath);
  p.Proc := TProcess.Create(nil);
  try
    p.Proc.Executable := p.RunExe;
    p.Proc.Parameters.Add('--port=' + IntToStr(p.Port));
    { 启动守卫三参数：nonce / token / host。父进程是 lwhyper(.exe)，
      host 参数也写它，插件侧父子进程校验才能通过 }
    nonce := PlugGuardNewNonce;
    p.Proc.Parameters.Add(PlugGuardNonceParam + nonce);
    p.Proc.Parameters.Add(PlugGuardTokenParam + PlugGuardToken(nonce));
    p.Proc.Parameters.Add(PlugGuardHostParam + ExtractFileName(ParamStr(0)));
    {$IFDEF MSWINDOWS}
    p.Proc.Options := p.Proc.Options + [poNoConsole];
    {$ENDIF}
    p.Proc.Execute;
    Result := True;
    LWLogFmt('[hyper-plugin] 已启动 %s: pid=%d port=%d exe=%s',
      [p.Name, p.Proc.ProcessID, p.Port, p.RunExe]);
  except
    on E: Exception do
    begin
      LWLog('[hyper-plugin] 启动插件失败 ' + p.Name + ': ' + E.Message);
      FreeAndNil(p.Proc);
      Exit;
    end;
  end;

  deadline := GetTickCount64 + 10000;
  while GetTickCount64 < deadline do
  begin
    if PortOpen(p.Port) then
    begin
      p.Alive := True;
      LWLogFmt('[hyper-plugin] 插件 %s 端口 %d 已就绪', [p.Name, p.Port]);
      Exit;
    end;
    if (p.Proc = nil) or (not p.Proc.Running) then
    begin
      LWLog('[hyper-plugin] 插件进程启动后立即退出: ' + p.Name +
        '（退出码 ' + IntToStr(p.Proc.ExitCode) + '；守卫拒绝是 ' +
        IntToStr(PlugGuardExitCode) + '）');
      Exit;
    end;
    Sleep(100);
  end;
  LWLogFmt('[hyper-plugin] 等待插件 %s 端口 %d 超时', [p.Name, p.Port]);
end;

procedure TLWHyperPluginManager.StopOne(p: TLWHyperPlugin);
var
  deadline: QWord;
begin
  if (p = nil) or (p.Proc = nil) then Exit;
  try
    if p.Proc.Running then p.Proc.Terminate(1);
    deadline := GetTickCount64 + STOP_WAIT_MS;
    while p.Proc.Running and (GetTickCount64 < deadline) do Sleep(50);
  except
    on E: Exception do
      LWLog('[hyper-plugin] 停止插件失败 ' + p.Name + ': ' + E.Message);
  end;
  FreeAndNil(p.Proc);
  p.Alive := False;
end;

function TLWHyperPluginManager.LaunchAll: Integer;
var
  i: Integer;
  p: TLWHyperPlugin;
begin
  Result := 0;
  for i := 0 to Count - 1 do
  begin
    p := Item(i);
    if (p <> nil) and (p.Proc = nil) then
      if StartOne(p) then Inc(Result);
  end;
end;

procedure TLWHyperPluginManager.RegisterRoutes;
var
  i: Integer;
  p: TLWHyperPlugin;
begin
  for i := 0 to Count - 1 do
  begin
    p := Item(i);
    if p = nil then Continue;
    LWRouteSet(p.Name, '127.0.0.1:' + IntToStr(p.Port));
    LWLogFmt('[hyper-plugin] 路由 /p/%s/ -> 127.0.0.1:%d', [p.Name, p.Port]);
  end;
end;

procedure TLWHyperPluginManager.StopAll;
var
  i: Integer;
begin
  for i := 0 to Count - 1 do
    StopOne(Item(i));
end;

function TLWHyperPluginManager.SourceChanged(AIndex: Integer): Boolean;
var
  p: TLWHyperPlugin;
  stamp: LongInt;
begin
  p := Item(AIndex);
  Result := False;
  if p = nil then Exit;
  stamp := FileAge(p.ExePath);
  if (stamp < 0) or (p.SourceStamp < 0) then Exit;
  Result := stamp <> p.SourceStamp;
end;

function TLWHyperPluginManager.HotUpdate(AIndex: Integer): Boolean;
var
  p: TLWHyperPlugin;
begin
  p := Item(AIndex);
  Result := False;
  if p = nil then Exit;
  LWLog('[hyper-plugin] 热更新: ' + p.Name);
  FUpdating := True;
  try
    StopOne(p);
    Result := StartOne(p);
    if Result then Inc(p.Seq);
  finally
    FUpdating := False;
  end;
end;

function TLWHyperPluginManager.StatusJSON: string;
var
  j: TJSONObject;
  arr: TJSONArray;
  o: TJSONObject;
  i: Integer;
  p: TLWHyperPlugin;
begin
  j := TJSONObject.Create;
  try
    j.Add('root', FRoot);
    j.Add('count', Count);
    arr := TJSONArray.Create;
    for i := 0 to Count - 1 do
    begin
      p := Item(i);
      if p = nil then Continue;
      o := TJSONObject.Create;
      o.Add('name', p.Name);
      o.Add('title', p.Title);
      o.Add('port', p.Port);
      o.Add('roles', p.Roles);
      if p.Proc <> nil then
        o.Add('pid', p.Proc.ProcessID)
      else
        o.Add('pid', 0);
      o.Add('alive', p.Alive);
      o.Add('restarts', p.Restarts);
      o.Add('seq', p.Seq);
      arr.Add(o);
    end;
    j.Add('plugins', arr);
    Result := j.AsJSON;
  finally
    j.Free;
  end;
end;

{ ---------------- 健康巡检线程 ---------------- }

constructor TLWHyperPluginMonitor.Create(AOwner: TLWHyperPluginManager);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(True);
end;

procedure TLWHyperPluginMonitor.Execute;
var
  i: Integer;
  p: TLWHyperPlugin;
begin
  LWLog('[hyper-plugin] monitor thread started');
  while not Terminated do
  begin
    if FOwner <> nil then
      for i := 0 to FOwner.Count - 1 do
      begin
        if Terminated then Exit;
        if FOwner.Updating then Break;
        p := FOwner.Item(i);
        if p = nil then Continue;
        if (p.Proc <> nil) and (not p.Proc.Running) then
        begin
          LWLogFmt('[hyper-plugin] 插件 %s 异常退出，重启中（第 %d 次）',
            [p.Name, p.Restarts + 1]);
          FOwner.StartOne(p);
          Inc(p.Restarts);
        end
        else
          p.Alive := (p.Proc <> nil) and p.Proc.Running and
                     FOwner.PortOpen(p.Port);
      end;
    for i := 1 to (PLUGIN_POLL_MS div 200) do
    begin
      if Terminated then Exit;
      Sleep(200);
    end;
  end;
end;

procedure TLWHyperPluginManager.StartMonitor;
begin
  if FMonitor <> nil then Exit;
  FMonitor := TLWHyperPluginMonitor.Create(Self);
  FMonitor.Start;
end;

procedure TLWHyperPluginManager.StopMonitor;
begin
  if FMonitor = nil then Exit;
  FMonitor.Terminate;
  FMonitor.WaitFor;
  FreeAndNil(FMonitor);
end;

end.
