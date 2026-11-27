unit upluginproc;
{ pluginsDemo :: 进程级插件发现 / 路由 / 拉起 / 热更新（只有宿主链接本单元）

  目录约定（宿主 exe 在 host\ 下，清单根目录 = exe 目录的父目录）：

    pluginsDemo\
      host\pluginsdemo.exe          宿主：边栏菜单 + PageControl + iframe 容器
      dashplug\dashplug.exe         插件 1（独立进程、独立端口）
      notesplug\notesplug.exe       插件 2
      reportsplug\reportsplug.exe   插件 3
      <插件目录>\<名>.plugin.ini    插件清单
      .run\                         宿主为每个插件准备的运行副本（热更新用）

  清单格式：
      name=<路由名>          必填，字母数字 .-_，访问路径 /p/<name>/
      title=<显示名>         缺省 = name，宿主菜单用
      group=<菜单分组>        可选，缺省「插件」；用 / 分多层级：
                             group=数据看板/运营分析 -> 两级分组
                             group=-            -> 插件直接作为顶层菜单行
      icon=<图标文件>         可选，相对清单目录，16x16 的 bmp/png，侧栏菜单图标
      exe=<相对清单目录>      缺省 = <清单名去 .plugin.ini>.exe
      port=<监听端口>        必填
      roles=<角色清单>        可选，逗号分隔，如 roles=admin,analyst
                             空/不写 = 所有已登录用户；admin 角色通配全部。
                             判定在 upluginauth.LWAuthCanOpen，菜单与 /p/ 路由共用

  为什么要 .run 运行副本：
      Windows 会锁住正在运行的 exe，插件直接跑自己的 exe 时没法重新编译。
      宿主每次拉起前把插件 exe + 同名 ini 复制到 .run\ 再从那里启动 ——
      原始 exe 不被占用，改完源码直接重编；重编后再点菜单/热更新按钮，
      宿主停旧进程 → 重新复制 → 起新进程 → 页内 iframe 换新 URL，
      宿主本身不用重启，这就是插件热更新。

  插件启动守卫（见 upluginguard）：
      插件 exe 不能单独运行。宿主拉起时带三条参数（nonce / token / host exe 名），
      插件 .lpr 第一句 PlugGuardCheck 校验：参数齐全 + nonce 未过期 + token 对得上
      + 父进程就是宿主。任何一条不过就提示"请从主程序进入"并 Halt(3)。
      所以手工双击 dashplug.exe 只会弹一个提示框，不会起服务、不会占端口。
}
{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Process, Sockets, lwconfig, lwroute, lwrlog, upluginguard
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

type
  TPlugPlugin = class
  public
    Name: string;         { 路由名 }
    Title: string;        { 菜单显示名 }
    Group: string;        { 侧栏菜单分组，可用 / 表示多层级（如 数据看板/运营分析）；空 = 默认分组，'-' = 顶层直接一行 }
    Icon: string;         { 菜单图标文件（16x16 bmp/png），清单里的相对路径；空 = 无图标 }
    Roles: string;        { 允许访问的角色，逗号分隔；空 = 所有已登录用户 }
    ExePath: string;      { 原始 exe（可随时重编） }
    IniPath: string;      { 原始 ini，同 exe 同名 }
    RunDir: string;       { .run 目录 }
    RunExe: string;       { 运行副本 }
    RunIni: string;       { 运行副本的 ini }
    Port: Integer;
    SourceStamp: LongInt; { 原始 exe 的 FileAge，用来发现"已重编" }
    Seq: Integer;         { 热更新代数，宿主用它给 iframe URL 加版本号 }
    Proc: TProcess;
  end;

{ 扫描清单；重复调用不会重复扫描 }
function PlugDiscover: Integer;
{ 重新扫描：增删插件目录后调用（宿主「重新扫描插件」按钮）。
  新增的注册路由并拉起；消失的停进程、摘路由；标题/分组就地更新；
  端口或 exe 变了的重启进程。返回扫描后的插件总数 }
function PlugRescan: Integer;
function PlugCount: Integer;
function PlugGet(AIndex: Integer): TPlugPlugin;
{ 按路由名查下标（找不到 -1）/ 查对象（找不到 nil） }
function PlugIndexOf(const AName: string): Integer;
function PlugByName(const AName: string): TPlugPlugin;
{ /p/<name>/ -> 127.0.0.1:<port> }
procedure PlugRegisterRoutes;
{ 复制运行副本并拉起全部插件，返回成功启动的数量 }
function PlugLaunchAll: Integer;
{ 停掉并释放本进程拉起的全部插件 }
procedure PlugStopAll;
{ 单个插件热更新：停旧进程 -> 重新复制 exe/ini -> 起新进程；Seq 自增 }
function PlugHotUpdate(AIndex: Integer): Boolean;
{ 原始 exe 在拉起之后是否被重新编译过 }
function PlugSourceChanged(AIndex: Integer): Boolean;
{ 有更新的插件数量 }
function PlugChangedCount: Integer;
function PlugURL(AIndex: Integer): string;
{ 页内 iframe 的地址（带版本号，热更新后强制重新加载） }
function PlugFrameURL(AIndex: Integer): string;
{ 插件进程是否还在运行 }
function PlugRunning(AIndex: Integer): Boolean;

implementation

const
  MANIFEST_SUFFIX = '.plugin.ini';
  STOP_WAIT_MS = 5000;

var
  GList: TList = nil;
  GRoot: string = '';
  i: Integer;   { finalization 用 }

{ 进程启动/停止定义在下面（PlugRescan 要用） }
function StartOne(p: TPlugPlugin): Boolean; forward;
procedure StopOne(p: TPlugPlugin); forward;

function ValidName(const S: string): Boolean;
var
  j: Integer;
  c: Char;
begin
  Result := False;
  if (S = '') or (Length(S) > 64) then Exit;
  for j := 1 to Length(S) do
  begin
    c := S[j];
    if not (((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
            ((c >= '0') and (c <= '9')) or (c = '-') or (c = '_') or (c = '.')) then
      Exit;
  end;
  Result := True;
end;

function ComparePlugin(Item1, Item2: Pointer): Integer;
begin
  Result := CompareText(TPlugPlugin(Item1).Name, TPlugPlugin(Item2).Name);
end;

function ExeRoot: string;
var
  exeDir: string;
begin
  { 去尾分隔符：ExtractFileDir('C:\a\host\') 会返回 'C:\a\host'，
    再取一次父目录就停在 host 自己这层，扫不到任何插件目录 }
  exeDir := ExcludeTrailingPathDelimiter(ExtractFileDir(ExpandFileName(ParamStr(0))));
  Result := ExtractFileDir(exeDir);
end;

function IsAbsPath(const S: string): Boolean;
begin
  Result := (Length(S) > 1) and (S[2] = ':');
  if (not Result) and (Length(S) > 0) then
    Result := (S[1] = '/') or (S[1] = '\');
end;

procedure CopyFileRaw(const Src, Dst: string);
var
  fs, fd: TFileStream;
begin
  fs := TFileStream.Create(Src, fmOpenRead or fmShareDenyNone);
  try
    fd := TFileStream.Create(Dst, fmCreate);
    try
      fd.CopyFrom(fs, 0);
    finally
      fd.Free;
    end;
    {$IFDEF UNIX}
    { TFileStream 新建的 .run 副本只有 0644，Linux 下 TProcess 会
      Permission denied（退出码 127）；显式补执行位。
      用 fpChmod 而不是 FileSetAttr：实测本机的 FileSetAttr 没生效，
      复制出来的副本仍是 0644。Windows 下无此问题 }
    fpChmod(Dst, &755);
    {$ENDIF}
  finally
    fs.Free;
  end;
end;

function IdxByName(AList: TList; const AName: string): Integer;
var
  j: Integer;
begin
  Result := -1;
  if AList = nil then Exit;
  for j := 0 to AList.Count - 1 do
    if CompareText(TPlugPlugin(AList.Items[j]).Name, AName) = 0 then
      Exit(j);
end;

{ 解析一个清单文件，成功返回新对象（不加入任何列表）}
function ParseManifest(const AFile: string): TPlugPlugin;
var
  cfg: TLWConfig;
  nm, title, grp, ic, exe, dir, base, fileName, roles, alt: string;
  port: Integer;
begin
  Result := nil;
  cfg := TLWConfig.Create;
  try
    if not cfg.Load(AFile) then
    begin
      LWLog('[pluginsDemo] 插件清单读取失败: ' + AFile);
      Exit;
    end;
    fileName := ExtractFileName(AFile);
    base := Copy(fileName, 1, Length(fileName) - Length(MANIFEST_SUFFIX));
    nm := Trim(cfg.Str(['name'], base));
    if not ValidName(nm) then
    begin
      LWLog('[pluginsDemo] 插件名非法，跳过: ' + nm + ' (' + AFile + ')');
      Exit;
    end;
    port := cfg.Int(['port'], 0);
    if port <= 0 then
    begin
      LWLog('[pluginsDemo] 插件 port 非法，跳过: ' + nm);
      Exit;
    end;
    dir := ExtractFileDir(AFile);
    title := Trim(cfg.Str(['title'], nm));
    grp := Trim(cfg.Str(['group'], ''));
    { 访问权限：清单里写 roles=admin,analyst。不写 = 所有已登录用户都能开。
      注意这里只负责"读出来"，判定统一在 upluginauth.LWAuthCanOpen ——
      菜单过滤和 /p/ 路由鉴权必须用同一份逻辑，否则会出现"菜单看得见、
      点开 403"或者更糟的"菜单看不见、手敲 URL 能进" }
    roles := Trim(cfg.Str(['roles'], ''));
    exe := Trim(cfg.Str(['exe'], ''));
    if exe = '' then
      exe := base + '.exe';
    if IsAbsPath(exe) then
      exe := ExpandFileName(exe)
    else
      exe := ExpandFileName(IncludeTrailingPathDelimiter(dir) + exe);
    { Linux 下 FPC 产物没有 .exe 后缀：清单仍写 exe=xxx.exe。
      UNIX 上只要同目录有同名的无后缀文件就优先用它 —— 不能只看
      "xxx.exe 不存在才退"，因为从 Windows 把构建目录整包传过来时，
      xxx.exe 会跟着一起上来（PE 文件），宿主 exec 它只会得到退出码 127，
      而真正的 aarch64/ELF 就在旁边（dashplug）。Windows 上没有无后缀
      文件，保持原来的"缺了才退"。 }
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

    ic := Trim(cfg.Str(['icon'], ''));
    if ic <> '' then
    begin
      if IsAbsPath(ic) then
        ic := ExpandFileName(ic)
      else
        ic := ExpandFileName(IncludeTrailingPathDelimiter(dir) + ic);
      if not FileExists(ic) then
      begin
        LWLog('[pluginsDemo] 警告: 菜单图标不存在: ' + ic);
        ic := '';
      end;
    end;

    Result := TPlugPlugin.Create;
    Result.Name := nm;
    Result.Title := title;
    Result.Group := grp;
    Result.Roles := roles;
    Result.Icon := ic;
    Result.ExePath := exe;
    Result.IniPath := ChangeFileExt(exe, '.ini');
    Result.RunDir := IncludeTrailingPathDelimiter(GRoot) + '.run';
    Result.RunExe := IncludeTrailingPathDelimiter(Result.RunDir) + ExtractFileName(exe);
    Result.RunIni := ChangeFileExt(Result.RunExe, '.ini');
    Result.Port := port;
    Result.SourceStamp := -1;
    Result.Seq := 0;
    Result.Proc := nil;
    if not FileExists(exe) then
      LWLog('[pluginsDemo] 警告: 插件 exe 尚不存在: ' + exe);
  finally
    cfg.Free;
  end;
end;

{ 扫描 <exe 父目录>\*\*.plugin.ini，解析后放进 AList（同名只认第一个）}
function ScanManifests(AList: TList): Integer;
var
  dir, mask: string;
  sr, mr: TSearchRec;
  files: TStringList;
  j: Integer;
  p: TPlugPlugin;
begin
  files := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(GRoot) + '*', faAnyFile, sr) = 0 then
    try
      repeat
        if ((sr.Attr and faDirectory) = 0) or (sr.Name = '.') or (sr.Name = '..') then
          Continue;
        dir := IncludeTrailingPathDelimiter(IncludeTrailingPathDelimiter(GRoot) + sr.Name);
        mask := dir + '*' + MANIFEST_SUFFIX;
        if FindFirst(mask, faAnyFile, mr) = 0 then
        try
          repeat
            if (mr.Attr and faDirectory) = 0 then
              files.Add(dir + mr.Name);
          until FindNext(mr) <> 0;
        finally
          FindClose(mr);
        end;
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;

    files.Sort;
    for j := 0 to files.Count - 1 do
    begin
      p := ParseManifest(files[j]);
      if p = nil then Continue;
      if IdxByName(AList, p.Name) >= 0 then
      begin
        LWLog('[pluginsDemo] 插件名重复，忽略: ' + files[j]);
        p.Free;
        Continue;
      end;
      AList.Add(p);
    end;
  finally
    files.Free;
  end;
  Result := AList.Count;
end;

function PlugDiscover: Integer;
begin
  if GList = nil then GList := TList.Create;
  if PlugCount > 0 then Exit(PlugCount);

  GRoot := ExeRoot;
  ScanManifests(GList);
  GList.Sort(@ComparePlugin);
  Result := PlugCount;
  LWLogFmt('[pluginsDemo] 从 %s 发现插件 %d 个', [GRoot, Result]);
end;

{ 重新扫描并让运行状态跟上磁盘：新增的注册路由+拉起，消失的停进程+摘路由 }
function PlugRescan: Integer;
var
  fresh: TList;
  j, k, added, removed: Integer;
  np, old: TPlugPlugin;
  reRoute: Boolean;
begin
  if GList = nil then Exit(PlugDiscover);
  GRoot := ExeRoot;

  fresh := TList.Create;
  try
    ScanManifests(fresh);
    added := 0;
    removed := 0;

    { 1) 清单没了：停进程、摘路由、从列表移除 }
    for j := GList.Count - 1 downto 0 do
    begin
      old := TPlugPlugin(GList.Items[j]);
      if IdxByName(fresh, old.Name) < 0 then
      begin
        StopOne(old);
        LWRouteRemove(old.Name);
        LWLog('[pluginsDemo] 插件已移除: ' + old.Name);
        GList.Delete(j);
        old.Free;
        Inc(removed);
      end;
    end;

    { 2) 新清单逐条对齐：新的加入并拉起；已有的更新标题/分组，
          端口或 exe 变了就重启进程 }
    for j := 0 to fresh.Count - 1 do
    begin
      np := TPlugPlugin(fresh.Items[j]);
      k := IdxByName(GList, np.Name);
      if k < 0 then
      begin
        GList.Add(np);
        LWRouteSet(np.Name, '127.0.0.1:' + IntToStr(np.Port));
        LWLogFmt('[pluginsDemo] 新增插件 %s，路由 /p/%s/ -> 127.0.0.1:%d',
          [np.Name, np.Name, np.Port]);
        StartOne(np);
        Inc(added);
        Continue;
      end;

      old := TPlugPlugin(GList.Items[k]);
      old.Title := np.Title;
      old.Group := np.Group;
      old.Icon := np.Icon;
      old.Roles := np.Roles;
      reRoute := (old.Port <> np.Port) or (not SameText(old.ExePath, np.ExePath));
      if reRoute then
      begin
        StopOne(old);
        old.Port := np.Port;
        old.ExePath := np.ExePath;
        old.IniPath := np.IniPath;
        old.RunExe := np.RunExe;
        old.RunIni := np.RunIni;
        LWRouteSet(old.Name, '127.0.0.1:' + IntToStr(old.Port));
        StartOne(old);
        LWLog('[pluginsDemo] 插件配置变化，已重启: ' + old.Name);
      end;
      np.Free;
    end;
    fresh.Clear;   { 接管过的对象不再重复释放 }
  finally
    for j := 0 to fresh.Count - 1 do
      TPlugPlugin(fresh.Items[j]).Free;
    fresh.Free;
  end;

  GList.Sort(@ComparePlugin);
  Result := PlugCount;
  LWLogFmt('[pluginsDemo] 重新扫描完成：共 %d 个（新增 %d，移除 %d）',
    [Result, added, removed]);
end;

function PlugIndexOf(const AName: string): Integer;
begin
  Result := IdxByName(GList, AName);
end;

function PlugByName(const AName: string): TPlugPlugin;
var
  k: Integer;
begin
  k := IdxByName(GList, AName);
  if k < 0 then Result := nil else Result := TPlugPlugin(GList.Items[k]);
end;

function PlugCount: Integer;
begin
  if GList = nil then Result := 0 else Result := GList.Count;
end;

function PlugGet(AIndex: Integer): TPlugPlugin;
begin
  Result := nil;
  if (GList = nil) or (AIndex < 0) or (AIndex >= GList.Count) then Exit;
  Result := TPlugPlugin(GList.Items[AIndex]);
end;

procedure PlugRegisterRoutes;
var
  j: Integer;
  p: TPlugPlugin;
begin
  for j := 0 to PlugCount - 1 do
  begin
    p := PlugGet(j);
    LWRouteSet(p.Name, '127.0.0.1:' + IntToStr(p.Port));
    LWLogFmt('[pluginsDemo] 路由: /p/%s/ -> 127.0.0.1:%d', [p.Name, p.Port]);
  end;
end;

function PortOpen(APort: Integer): Boolean;
var
  s: TSocket;
  addr: TInetSockAddr;
begin
  Result := False;
  s := fpSocket(AF_INET, SOCK_STREAM, 0);
  if s = -1 then Exit;
  try
    FillChar(addr, SizeOf(addr), 0);
    addr.sin_family := AF_INET;
    addr.sin_port := htons(APort);
    addr.sin_addr.s_addr := htonl($7F000001);   { 127.0.0.1 }
    Result := fpConnect(s, @addr, SizeOf(addr)) = 0;
  finally
    CloseSocket(s);
  end;
end;

function StartOne(p: TPlugPlugin): Boolean;
var
  deadline: QWord;
  nonce: string;
begin
  Result := False;
  if p = nil then Exit;
  if not FileExists(p.ExePath) then
  begin
    LWLog('[pluginsDemo] 插件 exe 不存在，无法启动: ' + p.ExePath);
    Exit;
  end;
  try
    ForceDirectories(p.RunDir);
    { 每次启动都取一份最新副本：重编过的 exe 在这里被换成新版本 }
    CopyFileRaw(p.ExePath, p.RunExe);
    if FileExists(p.IniPath) then
      CopyFileRaw(p.IniPath, p.RunIni);
  except
    on E: Exception do
    begin
      LWLog('[pluginsDemo] 复制运行副本失败 ' + p.Name + ': ' + E.Message);
      Exit;
    end;
  end;

  p.SourceStamp := FileAge(p.ExePath);
  p.Proc := TProcess.Create(nil);
  try
    p.Proc.Executable := p.RunExe;
    p.Proc.Parameters.Add('--port=' + IntToStr(p.Port));
    { 启动令牌：插件 exe 只认这套参数，单独双击会被 upluginguard 拦下。
      nonce 每次拉起现取（带时间戳，2 分钟后作废），token = SHA1(secret|nonce)，
      再附上宿主自己的 exe 名让插件核对父进程 —— 三条缺一条插件就不启动。 }
    nonce := PlugGuardNewNonce;
    p.Proc.Parameters.Add(PlugGuardNonceParam + nonce);
    p.Proc.Parameters.Add(PlugGuardTokenParam + PlugGuardToken(nonce));
    p.Proc.Parameters.Add(PlugGuardHostParam + ExtractFileName(ParamStr(0)));
    {$IFDEF MSWINDOWS}
    p.Proc.Options := p.Proc.Options + [poNoConsole];
    {$ENDIF}
    p.Proc.Execute;
    Result := True;
    LWLogFmt('[pluginsDemo] 已启动插件 %s: pid=%d port=%d exe=%s',
      [p.Name, p.Proc.ProcessID, p.Port, p.RunExe]);
  except
    on E: Exception do
    begin
      LWLog('[pluginsDemo] 启动插件失败 ' + p.Name + ': ' + E.Message);
      FreeAndNil(p.Proc);
    end;
  end;

  { 等端口真正监听：热更新后马上重载 iframe，不能让它打到 502 }
  if Result then
  begin
    deadline := GetTickCount64 + 10000;
    while GetTickCount64 < deadline do
    begin
      if PortOpen(p.Port) then
      begin
        LWLogFmt('[pluginsDemo] 插件 %s 端口 %d 已就绪', [p.Name, p.Port]);
        Exit;
      end;
      if (p.Proc = nil) or (not p.Proc.Running) then
      begin
        LWLog('[pluginsDemo] 插件进程启动后立即退出: ' + p.Name +
          '（退出码 ' + IntToStr(p.Proc.ExitCode) + '；被启动守卫拦下时是 ' +
          IntToStr(PlugGuardExitCode) + '，见插件目录 plugin-guard.log）');
        {$IFDEF UNIX}
        { 126/127 是系统根本没执行起来（不是本机架构的可执行文件 / 没有执行位），
          与启动守卫无关（守卫拦下是 3）。最常见的原因是 exe= 指到了 Windows 的 PE }
        if p.Proc.ExitCode in [126, 127] then
          LWLog('[pluginsDemo] 提示: 退出码 ' + IntToStr(p.Proc.ExitCode) +
            ' = 系统无法执行该文件（不是本机架构 ELF 或缺执行位）: ' + p.RunExe);
        {$ENDIF}
        Exit;
      end;
      Sleep(100);
    end;
    LWLogFmt('[pluginsDemo] 等待插件 %s 端口 %d 超时', [p.Name, p.Port]);
  end;
end;

procedure StopOne(p: TPlugPlugin);
var
  deadline: QWord;
begin
  if (p = nil) or (p.Proc = nil) then Exit;
  try
    if p.Proc.Running then
      p.Proc.Terminate(1);
    deadline := GetTickCount64 + STOP_WAIT_MS;
    while p.Proc.Running and (GetTickCount64 < deadline) do
      Sleep(50);
  except
    on E: Exception do
      LWLog('[pluginsDemo] 停止插件失败 ' + p.Name + ': ' + E.Message);
  end;
  FreeAndNil(p.Proc);
end;

function PlugLaunchAll: Integer;
var
  j: Integer;
begin
  Result := 0;
  for j := 0 to PlugCount - 1 do
  begin
    if PlugGet(j).Proc <> nil then Continue;
    if StartOne(PlugGet(j)) then Inc(Result);
  end;
end;

procedure PlugStopAll;
var
  j: Integer;
begin
  for j := 0 to PlugCount - 1 do
    StopOne(PlugGet(j));
end;

function PlugHotUpdate(AIndex: Integer): Boolean;
var
  p: TPlugPlugin;
begin
  p := PlugGet(AIndex);
  Result := False;
  if p = nil then Exit;
  LWLog('[pluginsDemo] 热更新: ' + p.Name);
  StopOne(p);                 { 先停，运行副本才不会被锁 }
  Result := StartOne(p);      { 重新复制最新 exe/ini 再拉起 }
  if Result then
    Inc(p.Seq);
end;

function PlugSourceChanged(AIndex: Integer): Boolean;
var
  p: TPlugPlugin;
  stamp: LongInt;
begin
  p := PlugGet(AIndex);
  Result := False;
  if p = nil then Exit;
  stamp := FileAge(p.ExePath);
  if (stamp < 0) or (p.SourceStamp < 0) then Exit;
  Result := stamp <> p.SourceStamp;
end;

function PlugChangedCount: Integer;
var
  j: Integer;
begin
  Result := 0;
  for j := 0 to PlugCount - 1 do
    if PlugSourceChanged(j) then Inc(Result);
end;

function PlugURL(AIndex: Integer): string;
var
  p: TPlugPlugin;
begin
  p := PlugGet(AIndex);
  if p = nil then Result := '' else Result := '/p/' + p.Name + '/';
end;

function PlugFrameURL(AIndex: Integer): string;
begin
  Result := PlugURL(AIndex) + '?v=' + IntToStr(PlugGet(AIndex).Seq);
end;

function PlugRunning(AIndex: Integer): Boolean;
var
  p: TPlugPlugin;
begin
  p := PlugGet(AIndex);
  Result := (p <> nil) and (p.Proc <> nil) and p.Proc.Running;
end;

finalization
  PlugStopAll;
  if GList <> nil then
  begin
    for i := 0 to GList.Count - 1 do
      TPlugPlugin(GList.Items[i]).Free;
    FreeAndNil(GList);
  end;
end.
