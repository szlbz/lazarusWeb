{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwnewplugin
  ------------------------------------------------------------------
  插件框架（多进程）的工程骨架模板 —— 宿主 exe + 插件 exe + common 目录。

  与 lwnewproject 的分工：
    lwnewproject  单个工程（.lpr / .lpi / umain / build 脚本）：
                  常规模式、服务(daemon)模式都走它；
    lwnewplugin   插件模式：宿主工程 + common\（插件管理 / 启动守卫 / 用户权限 /
                  身份验签）+ ulogin.pas + plugins\<名>\ 插件工程 +
                  build-all.bat(.sh) / stop-all.bat(.sh) / README.md。

  生成的目录（<Name> = 工程名，<Dir> = 用户选的工程目录）：

    <Dir>\<Name>.lpr / .lpi        宿主：侧栏菜单 TLWSideMenu + TPageControl
    <Dir>\umain.pas / .lfm         宿主主窗体（菜单按角色过滤 + 顶栏身份 + 切换用户）
    <Dir>\ulogin.pas               宿主登录窗体（默认带图形验证码）
    <Dir>\common\upluginproc.pas    插件发现 / 路由注册 / 拉起 / 热更新（只宿主链接）
    <Dir>\common\upluginguard.pas   插件启动守卫（宿主与插件都链接）
    <Dir>\common\upluginauth.pas    用户/角色、菜单过滤、/p/ 403、身份签发（只宿主链接）
    <Dir>\common\upluginidentity.pas 插件侧身份验签（只插件链接）
    <Dir>\plugins\hello\           示例插件（独立 exe、独立端口 <port>+1）
    <Dir>\<Name>.ini               宿主端口等配置
    <Dir>\build-all.bat            先编插件、再编宿主（Windows）
    <Dir>\stop-all.bat             强杀宿主后清理残留插件进程（Windows）
    <Dir>\build-all.sh             同上，Linux/macOS（LF 行尾）
    <Dir>\stop-all.sh              同上，Linux/macOS（LF 行尾）
    <Dir>\README.md                目录结构 + 权限说明 + "再加一个插件"的步骤

  布局约定（与 demos/pluginsDemo 的差别只在清单根目录）：
    宿主 exe 就在工程根目录，清单根目录 = <exe 目录>\plugins，
    扫描 plugins\*\*.plugin.ini —— 一个子目录 = 一个插件（清单 + exe + 窗体）。
    pluginsDemo 的宿主在 host\ 下，所以那边的清单根是 exe 的父目录；
    本单元内嵌的 upluginproc 已按"exe 目录\plugins"改过 ExeRoot，其余逻辑一字不差。

  为什么内嵌源码而不是引用 demos：
    设计期包（lwdesign）和命令行工具（tools\lwnew）都要能独立生成这套框架，
    不能依赖仓库里 demos 目录的相对位置。内嵌的文本就是 pluginsDemo 里
    验证过的那些（upluginproc / upluginguard / upluginauth / upluginidentity /
    ulogin / umain.pas / umain.lfm），只做了与工程名有关的占位替换
    （%NAME% / %TITLE% / %TAG%）。demo 改了这里要同步。
}
unit lwnewplugin;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, lwnewproject;

const
  { common 目录名：宿主与插件共用的**源码**目录（upluginproc.pas + upluginguard.pas）。
    单独一层目录是为了将来给插件加公共单元时不用动 .lpi 的搜索路径 ——
    宿主 .lpi 的 OtherUnitFiles 已经指向它。 }
  sLWPluginCommonDir = 'common';
  { 插件根目录：清单根 = <exe 目录>\plugins，扫描 plugins\*\*.plugin.ini }
  sLWPluginPluginsDir = 'plugins';
  { 示例插件目录名 / 工程名 / 路由名（三处同名，便于对照） }
  sLWPluginSampleName = 'hello';

{ 宿主 .lpr：发现 -> 注册路由 -> 拉起插件 -> TLWApp.Run }
function LWPluginHostSource(const O: TLWNewProject): string;
{ 宿主 .lpi：比常规模板只多两处 —— OtherUnitFiles 指向 common\，
  以及把 common\upluginproc.pas 一起编进来（后者由搜索路径覆盖，不必列 Units） }
function LWPluginHostInfo(const O: TLWNewProject): string;
{ 宿主主窗体：umain.pas / umain.lfm（侧栏菜单 + PageControl + 状态栏） }
function LWPluginHostUnitSource(const O: TLWNewProject): string;
function LWPluginHostResourceSource(const O: TLWNewProject): string;
{ 设计期占位用的类声明（type + var 段）。IDE 向导拼源码时先要一份能对上
  lfm 控件的骨架，Initialized 再用 LWPluginHostUnitSource 整篇替换。 }
function LWPluginHostClassDecl(const O: TLWNewProject; const AFormName: string): string;

{ common\upluginproc.pas 正文（日志前缀换成 [工程名]） }
function LWPluginCommonSource(const O: TLWNewProject): string;
{ common\upluginguard.pas 正文：插件启动守卫（令牌 + 父进程校验）。
  宿主与插件都链接它，所以两边必须一起重编 —— build-all.bat 已按顺序全编。 }
function LWPluginGuardSource(const O: TLWNewProject): string;
{ common\upluginauth.pas 正文：用户/角色与路由鉴权（只宿主链接）。
  清单 roles= 的判定、菜单过滤、/p/ 403 与身份签发都在这里。 }
function LWPluginAuthSource(const O: TLWNewProject): string;
{ common\upluginidentity.pas 正文：插件侧身份验签（只插件链接）。
  与 upluginauth 用同一个 secret，公式见单元头注释。 }
function LWPluginIdentitySource(const O: TLWNewProject): string;
{ ulogin.pas 正文：宿主登录窗体（TLWLoginForm 子类，默认带图形验证码）。 }
function LWPluginLoginSource(const O: TLWNewProject): string;

{ 示例插件 plugins\hello\ 下的四个工程文件 + 清单 + ini }
function LWPluginSampleLpr(const O: TLWNewProject): string;
function LWPluginSampleLpi(const O: TLWNewProject): string;
function LWPluginSampleUnit(const O: TLWNewProject): string;
function LWPluginSampleResource(const O: TLWNewProject): string;
function LWPluginSampleManifest(const O: TLWNewProject): string;
function LWPluginSampleIni(const O: TLWNewProject): string;
{ 示例插件端口 = 宿主端口 + 1（清单与 ini 必须一致，宿主拉起时用 --port= 覆盖） }
function LWPluginSamplePort(const O: TLWNewProject): Integer;

{ 宿主 <工程名>.ini }
function LWPluginHostIni(const O: TLWNewProject): string;
{ build-all.bat（先插件后宿主）/ stop-all.bat / README.md }
function LWPluginBuildAllBatch(const O: TLWNewProject): string;
function LWPluginStopAllBatch(const O: TLWNewProject; const ADir: string): string;
function LWPluginBuildAllSh(const O: TLWNewProject): string;
function LWPluginStopAllSh(const O: TLWNewProject): string;
function LWPluginReadme(const O: TLWNewProject): string;

{ 把插件框架的"附加文件"写进 ADir（宿主工程文件不在这里写）：
    common\upluginproc.pas / upluginguard.pas / upluginauth.pas / upluginidentity.pas
    ulogin.pas
    plugins\hello\hello.lpr / .lpi / .ini / .plugin.ini / uform_hello.pas / .lfm
    <Name>.ini / build-all.bat / stop-all.bat / README.md

  AOverwrite=False（IDE 向导用）：已存在的文件原样保留 —— 保存钩子在每次
  保存工程时都会调到这里，不能让用户改过的插件源码被模板覆盖回原样。
  AOverwrite=True（tools\lwnew --force 用）：全部按模板重写。 }
function LWPluginExtras(const O: TLWNewProject; const ADir: string;
  out AErr: string; AOverwrite: Boolean = False): Boolean;

{ 一次生成整套框架（宿主 + 附加文件），tools\lwnew --plugin 走这条 }
function LWPluginGenerate(const O: TLWNewProject; const ADir: string;
  out AErr: string): Boolean;

implementation

const
  { ------------------------------------------------------------------
    下面的数组是 demos/pluginsDemo 的源码原文（逐字保留）：
      cCommonLines / cGuardLines       common\upluginproc.pas 与 upluginguard.pas
      cHostUnitLines / cHostLfmLines   宿主主窗体
      cSampleUnitLines / cSampleLfmLines 示例插件窗体
    只做了占位替换：
      %NAME%   工程名（宿主 exe / ini 名）
      %TITLE%  宿主窗口标题与浏览器标题
      %TAG%    日志前缀里的工程名（LWLog 里显示成 [工程名]）
    改动模板时记得两边同步：demo 是给框架开发者看的样本，这里是生成器。
    ------------------------------------------------------------------ }
  cCommonLines: array[0..651] of string = (
    'unit upluginproc;',
    '{ %NAME% :: 进程级插件发现 / 路由 / 拉起 / 热更新（只有宿主链接本单元）',
    '',
    '  目录约定（宿主 exe 在工程根目录，清单根目录 = <exe 目录>\plugins）：',
    '',
    '    %NAME%\',
    '      %NAME%.exe                    宿主：边栏菜单 + PageControl + iframe 容器',
    '      plugins\hello\hello.exe      插件（独立进程、独立端口）',
    '      plugins\<名>\<名>.plugin.ini 插件清单',
    '      plugins\.run\                  宿主为每个插件准备的运行副本（热更新用）',
    '',
    '  清单格式：',
    '      name=<路由名>          必填，字母数字 .-_，访问路径 /p/<name>/',
    '      title=<显示名>         缺省 = name，宿主菜单用',
    '      group=<菜单分组>        可选，缺省「插件」；用 / 分多层级：',
    '                             group=数据看板/运营分析 -> 两级分组',
    '                             group=-            -> 插件直接作为顶层菜单行',
    '      icon=<图标文件>         可选，相对清单目录，16x16 的 bmp/png，侧栏菜单图标',
    '      exe=<相对清单目录>      缺省 = <清单名去 .plugin.ini>.exe',
    '      port=<监听端口>        必填',
    '      roles=<角色清单>        可选，逗号分隔，如 roles=admin,analyst',
    '                             空/不写 = 所有已登录用户；admin 角色通配全部。',
    '                             判定在 common\upluginauth.LWAuthCanOpen，菜单与',
    '                             /p/ 路由共用同一份逻辑（模板已默认接好）',
    '',
    '  为什么要 plugins\.run 运行副本：',
    '      Windows 会锁住正在运行的 exe，插件直接跑自己的 exe 时没法重新编译。',
    '      宿主每次拉起前把插件 exe + 同名 ini 复制到 plugins\.run\ 再启动 ——',
    '      原始 exe 不被占用，改完源码直接重编；重编后再点菜单/热更新按钮，',
    '      宿主停旧进程 → 重新复制 → 起新进程 → 页内 iframe 换新 URL，',
    '      宿主本身不用重启，这就是插件热更新。',
    '',
    '  插件启动守卫（见 upluginguard）：',
    '      插件 exe 不能单独运行。宿主拉起时带三条参数（nonce / token / host exe 名），',
    '      插件 .lpr 第一句 PlugGuardCheck 校验：参数齐全 + nonce 未过期 + token 对得上',
    '      + 父进程就是宿主。任何一条不过就提示"请从主程序进入"并 Halt(3)。',
    '      所以手工双击 hello.exe 只会弹一个提示框，不会起服务、不会占端口。',
    '}',
    '{$mode objfpc}{$H+}',
    '',
    'interface',
    '',
    'uses',
    '  Classes, SysUtils, Process, Sockets, lwconfig, lwroute, lwrlog, upluginguard;',
    '',
    'type',
    '  TPlugPlugin = class',
    '  public',
    '    Name: string;         { 路由名 }',
    '    Title: string;        { 菜单显示名 }',
    '    Group: string;        { 侧栏菜单分组，可用 / 表示多层级（如 数据看板/运营分析）；空 = 默认分组，''-'' = 顶层直接一行 }',
    '    Icon: string;         { 菜单图标文件（16x16 bmp/png），清单里的相对路径；空 = 无图标 }',
    '    Roles: string;        { 允许访问的角色，逗号分隔；空 = 所有已登录用户 }',
    '    ExePath: string;      { 原始 exe（可随时重编） }',
    '    IniPath: string;      { 原始 ini，同 exe 同名 }',
    '    RunDir: string;       { plugins\.run 目录 }',
    '    RunExe: string;       { 运行副本 }',
    '    RunIni: string;       { 运行副本的 ini }',
    '    Port: Integer;',
    '    SourceStamp: LongInt; { 原始 exe 的 FileAge，用来发现"已重编" }',
    '    Seq: Integer;         { 热更新代数，宿主用它给 iframe URL 加版本号 }',
    '    Proc: TProcess;',
    '  end;',
    '',
    '{ 扫描清单；重复调用不会重复扫描 }',
    'function PlugDiscover: Integer;',
    '{ 重新扫描：增删插件目录后调用（宿主「重新扫描插件」按钮）。',
    '  新增的注册路由并拉起；消失的停进程、摘路由；标题/分组就地更新；',
    '  端口或 exe 变了的重启进程。返回扫描后的插件总数 }',
    'function PlugRescan: Integer;',
    'function PlugCount: Integer;',
    'function PlugGet(AIndex: Integer): TPlugPlugin;',
    '{ 按路由名查下标（找不到 -1）/ 查对象（找不到 nil） }',
    'function PlugIndexOf(const AName: string): Integer;',
    'function PlugByName(const AName: string): TPlugPlugin;',
    '{ /p/<name>/ -> 127.0.0.1:<port> }',
    'procedure PlugRegisterRoutes;',
    '{ 复制运行副本并拉起全部插件，返回成功启动的数量 }',
    'function PlugLaunchAll: Integer;',
    '{ 停掉并释放本进程拉起的全部插件 }',
    'procedure PlugStopAll;',
    '{ 单个插件热更新：停旧进程 -> 重新复制 exe/ini -> 起新进程；Seq 自增 }',
    'function PlugHotUpdate(AIndex: Integer): Boolean;',
    '{ 原始 exe 在拉起之后是否被重新编译过 }',
    'function PlugSourceChanged(AIndex: Integer): Boolean;',
    '{ 有更新的插件数量 }',
    'function PlugChangedCount: Integer;',
    'function PlugURL(AIndex: Integer): string;',
    '{ 页内 iframe 的地址（带版本号，热更新后强制重新加载） }',
    'function PlugFrameURL(AIndex: Integer): string;',
    '{ 插件进程是否还在运行 }',
    'function PlugRunning(AIndex: Integer): Boolean;',
    '',
    'implementation',
    '',
    'const',
    '  MANIFEST_SUFFIX = ''.plugin.ini'';',
    '  STOP_WAIT_MS = 5000;',
    '',
    'var',
    '  GList: TList = nil;',
    '  GRoot: string = '''';',
    '  i: Integer;   { finalization 用 }',
    '',
    '{ 进程启动/停止定义在下面（PlugRescan 要用） }',
    'function StartOne(p: TPlugPlugin): Boolean; forward;',
    'procedure StopOne(p: TPlugPlugin); forward;',
    '',
    'function ValidName(const S: string): Boolean;',
    'var',
    '  j: Integer;',
    '  c: Char;',
    'begin',
    '  Result := False;',
    '  if (S = '''') or (Length(S) > 64) then Exit;',
    '  for j := 1 to Length(S) do',
    '  begin',
    '    c := S[j];',
    '    if not (((c >= ''a'') and (c <= ''z'')) or ((c >= ''A'') and (c <= ''Z'')) or',
    '            ((c >= ''0'') and (c <= ''9'')) or (c = ''-'') or (c = ''_'') or (c = ''.'')) then',
    '      Exit;',
    '  end;',
    '  Result := True;',
    'end;',
    '',
    'function ComparePlugin(Item1, Item2: Pointer): Integer;',
    'begin',
    '  Result := CompareText(TPlugPlugin(Item1).Name, TPlugPlugin(Item2).Name);',
    'end;',
    '',
    'function ExeRoot: string;',
    'var',
    '  exeDir: string;',
    'begin',
    '  { 清单根目录 = <宿主 exe 目录>\plugins —— 一个插件一个子目录。',
    '    去尾分隔符是必须的：ExtractFileDir 对 "C:\a\plugins\" 会停在本层，',
    '    拼出来的掩码变成 plugins*，一个清单都扫不到（pluginsDemo 踩过一次）。 }',
    '  exeDir := ExcludeTrailingPathDelimiter(ExtractFileDir(ExpandFileName(ParamStr(0))));',
    '  Result := IncludeTrailingPathDelimiter(exeDir) + ''plugins'';',
    'end;',
    '',
    'function IsAbsPath(const S: string): Boolean;',
    'begin',
    '  Result := (Length(S) > 1) and (S[2] = '':'');',
    '  if (not Result) and (Length(S) > 0) then',
    '    Result := (S[1] = ''/'') or (S[1] = ''\'');',
    'end;',
    '',
    'procedure CopyFileRaw(const Src, Dst: string);',
    'var',
    '  fs, fd: TFileStream;',
    'begin',
    '  fs := TFileStream.Create(Src, fmOpenRead or fmShareDenyNone);',
    '  try',
    '    fd := TFileStream.Create(Dst, fmCreate);',
    '    try',
    '      fd.CopyFrom(fs, 0);',
    '    finally',
    '      fd.Free;',
    '    end;',
    '    {$IFDEF UNIX}',
    '    { TFileStream 新建的 .run 副本只有 0644，Linux 下 TProcess 会',
    '      Permission denied；显式补执行位，Windows 下无此问题 }',
    '    FileSetAttr(Dst, &755);',
    '    {$ENDIF}',
    '  finally',
    '    fs.Free;',
    '  end;',
    'end;',
    '',
    'function IdxByName(AList: TList; const AName: string): Integer;',
    'var',
    '  j: Integer;',
    'begin',
    '  Result := -1;',
    '  if AList = nil then Exit;',
    '  for j := 0 to AList.Count - 1 do',
    '    if CompareText(TPlugPlugin(AList.Items[j]).Name, AName) = 0 then',
    '      Exit(j);',
    'end;',
    '',
    '{ 解析一个清单文件，成功返回新对象（不加入任何列表）}',
    'function ParseManifest(const AFile: string): TPlugPlugin;',
    'var',
    '  cfg: TLWConfig;',
    '  nm, title, grp, ic, exe, dir, base, fileName, roles, alt: string;',
    '  port: Integer;',
    'begin',
    '  Result := nil;',
    '  cfg := TLWConfig.Create;',
    '  try',
    '    if not cfg.Load(AFile) then',
    '    begin',
    '      LWLog(''[%TAG%] 插件清单读取失败: '' + AFile);',
    '      Exit;',
    '    end;',
    '    fileName := ExtractFileName(AFile);',
    '    base := Copy(fileName, 1, Length(fileName) - Length(MANIFEST_SUFFIX));',
    '    nm := Trim(cfg.Str([''name''], base));',
    '    if not ValidName(nm) then',
    '    begin',
    '      LWLog(''[%TAG%] 插件名非法，跳过: '' + nm + '' ('' + AFile + '')'');',
    '      Exit;',
    '    end;',
    '    port := cfg.Int([''port''], 0);',
    '    if port <= 0 then',
    '    begin',
    '      LWLog(''[%TAG%] 插件 port 非法，跳过: '' + nm);',
    '      Exit;',
    '    end;',
    '    dir := ExtractFileDir(AFile);',
    '    title := Trim(cfg.Str([''title''], nm));',
    '    grp := Trim(cfg.Str([''group''], ''''));',
    '    { 访问权限：清单里写 roles=admin,analyst。不写 = 所有已登录用户都能开。',
    '      这里只负责"读出来"，判定统一在 upluginauth.LWAuthCanOpen ——',
    '      菜单过滤和 /p/ 路由鉴权必须用同一份逻辑，否则会出现"菜单看得见、',
    '      点开 403"或者更糟的"菜单看不见、手敲 URL 能进" }',
    '    roles := Trim(cfg.Str([''roles''], ''''));',
    '    exe := Trim(cfg.Str([''exe''], ''''));',
    '    if exe = '''' then',
    '      exe := base + ''.exe'';',
    '    if IsAbsPath(exe) then',
    '      exe := ExpandFileName(exe)',
    '    else',
    '      exe := ExpandFileName(IncludeTrailingPathDelimiter(dir) + exe);',
    '    { Linux 下 FPC 产物没有 .exe 后缀：清单仍写 exe=xxx.exe，',
    '      找不到时退到同目录的无后缀文件（Windows 下文件在，不走这里） }',
    '    if (not FileExists(exe)) and (CompareText(ExtractFileExt(exe), ''.exe'') = 0) then',
    '    begin',
    '      alt := Copy(exe, 1, Length(exe) - 4);',
    '      if FileExists(alt) then exe := alt;',
    '    end;',
    '',
    '    ic := Trim(cfg.Str([''icon''], ''''));',
    '    if ic <> '''' then',
    '    begin',
    '      if IsAbsPath(ic) then',
    '        ic := ExpandFileName(ic)',
    '      else',
    '        ic := ExpandFileName(IncludeTrailingPathDelimiter(dir) + ic);',
    '      if not FileExists(ic) then',
    '      begin',
    '        LWLog(''[%TAG%] 警告: 菜单图标不存在: '' + ic);',
    '        ic := '''';',
    '      end;',
    '    end;',
    '',
    '    Result := TPlugPlugin.Create;',
    '    Result.Name := nm;',
    '    Result.Title := title;',
    '    Result.Group := grp;',
    '    Result.Roles := roles;',
    '    Result.Icon := ic;',
    '    Result.ExePath := exe;',
    '    Result.IniPath := ChangeFileExt(exe, ''.ini'');',
    '    Result.RunDir := IncludeTrailingPathDelimiter(GRoot) + ''.run'';',
    '    Result.RunExe := IncludeTrailingPathDelimiter(Result.RunDir) + ExtractFileName(exe);',
    '    Result.RunIni := ChangeFileExt(Result.RunExe, ''.ini'');',
    '    Result.Port := port;',
    '    Result.SourceStamp := -1;',
    '    Result.Seq := 0;',
    '    Result.Proc := nil;',
    '    if not FileExists(exe) then',
    '      LWLog(''[%TAG%] 警告: 插件 exe 尚不存在: '' + exe);',
    '  finally',
    '    cfg.Free;',
    '  end;',
    'end;',
    '',
    '{ 扫描 <exe 父目录>\*\*.plugin.ini，解析后放进 AList（同名只认第一个）}',
    'function ScanManifests(AList: TList): Integer;',
    'var',
    '  dir, mask: string;',
    '  sr, mr: TSearchRec;',
    '  files: TStringList;',
    '  j: Integer;',
    '  p: TPlugPlugin;',
    'begin',
    '  files := TStringList.Create;',
    '  try',
    '    if FindFirst(IncludeTrailingPathDelimiter(GRoot) + ''*'', faAnyFile, sr) = 0 then',
    '    try',
    '      repeat',
    '        if ((sr.Attr and faDirectory) = 0) or (sr.Name = ''.'') or (sr.Name = ''..'') then',
    '          Continue;',
    '        dir := IncludeTrailingPathDelimiter(IncludeTrailingPathDelimiter(GRoot) + sr.Name);',
    '        mask := dir + ''*'' + MANIFEST_SUFFIX;',
    '        if FindFirst(mask, faAnyFile, mr) = 0 then',
    '        try',
    '          repeat',
    '            if (mr.Attr and faDirectory) = 0 then',
    '              files.Add(dir + mr.Name);',
    '          until FindNext(mr) <> 0;',
    '        finally',
    '          FindClose(mr);',
    '        end;',
    '      until FindNext(sr) <> 0;',
    '    finally',
    '      FindClose(sr);',
    '    end;',
    '',
    '    files.Sort;',
    '    for j := 0 to files.Count - 1 do',
    '    begin',
    '      p := ParseManifest(files[j]);',
    '      if p = nil then Continue;',
    '      if IdxByName(AList, p.Name) >= 0 then',
    '      begin',
    '        LWLog(''[%TAG%] 插件名重复，忽略: '' + files[j]);',
    '        p.Free;',
    '        Continue;',
    '      end;',
    '      AList.Add(p);',
    '    end;',
    '  finally',
    '    files.Free;',
    '  end;',
    '  Result := AList.Count;',
    'end;',
    '',
    'function PlugDiscover: Integer;',
    'begin',
    '  if GList = nil then GList := TList.Create;',
    '  if PlugCount > 0 then Exit(PlugCount);',
    '',
    '  GRoot := ExeRoot;',
    '  ScanManifests(GList);',
    '  GList.Sort(@ComparePlugin);',
    '  Result := PlugCount;',
    '  LWLogFmt(''[%TAG%] 从 %s 发现插件 %d 个'', [GRoot, Result]);',
    'end;',
    '',
    '{ 重新扫描并让运行状态跟上磁盘：新增的注册路由+拉起，消失的停进程+摘路由 }',
    'function PlugRescan: Integer;',
    'var',
    '  fresh: TList;',
    '  j, k, added, removed: Integer;',
    '  np, old: TPlugPlugin;',
    '  reRoute: Boolean;',
    'begin',
    '  if GList = nil then Exit(PlugDiscover);',
    '  GRoot := ExeRoot;',
    '',
    '  fresh := TList.Create;',
    '  try',
    '    ScanManifests(fresh);',
    '    added := 0;',
    '    removed := 0;',
    '',
    '    { 1) 清单没了：停进程、摘路由、从列表移除 }',
    '    for j := GList.Count - 1 downto 0 do',
    '    begin',
    '      old := TPlugPlugin(GList.Items[j]);',
    '      if IdxByName(fresh, old.Name) < 0 then',
    '      begin',
    '        StopOne(old);',
    '        LWRouteRemove(old.Name);',
    '        LWLog(''[%TAG%] 插件已移除: '' + old.Name);',
    '        GList.Delete(j);',
    '        old.Free;',
    '        Inc(removed);',
    '      end;',
    '    end;',
    '',
    '    { 2) 新清单逐条对齐：新的加入并拉起；已有的更新标题/分组，',
    '          端口或 exe 变了就重启进程 }',
    '    for j := 0 to fresh.Count - 1 do',
    '    begin',
    '      np := TPlugPlugin(fresh.Items[j]);',
    '      k := IdxByName(GList, np.Name);',
    '      if k < 0 then',
    '      begin',
    '        GList.Add(np);',
    '        LWRouteSet(np.Name, ''127.0.0.1:'' + IntToStr(np.Port));',
    '        LWLogFmt(''[%TAG%] 新增插件 %s，路由 /p/%s/ -> 127.0.0.1:%d'',',
    '          [np.Name, np.Name, np.Port]);',
    '        StartOne(np);',
    '        Inc(added);',
    '        Continue;',
    '      end;',
    '',
    '      old := TPlugPlugin(GList.Items[k]);',
    '      old.Title := np.Title;',
    '      old.Group := np.Group;',
    '      old.Icon := np.Icon;',
    '      old.Roles := np.Roles;',
    '      reRoute := (old.Port <> np.Port) or (not SameText(old.ExePath, np.ExePath));',
    '      if reRoute then',
    '      begin',
    '        StopOne(old);',
    '        old.Port := np.Port;',
    '        old.ExePath := np.ExePath;',
    '        old.IniPath := np.IniPath;',
    '        old.RunExe := np.RunExe;',
    '        old.RunIni := np.RunIni;',
    '        LWRouteSet(old.Name, ''127.0.0.1:'' + IntToStr(old.Port));',
    '        StartOne(old);',
    '        LWLog(''[%TAG%] 插件配置变化，已重启: '' + old.Name);',
    '      end;',
    '      np.Free;',
    '    end;',
    '    fresh.Clear;   { 接管过的对象不再重复释放 }',
    '  finally',
    '    for j := 0 to fresh.Count - 1 do',
    '      TPlugPlugin(fresh.Items[j]).Free;',
    '    fresh.Free;',
    '  end;',
    '',
    '  GList.Sort(@ComparePlugin);',
    '  Result := PlugCount;',
    '  LWLogFmt(''[%TAG%] 重新扫描完成：共 %d 个（新增 %d，移除 %d）'',',
    '    [Result, added, removed]);',
    'end;',
    '',
    'function PlugIndexOf(const AName: string): Integer;',
    'begin',
    '  Result := IdxByName(GList, AName);',
    'end;',
    '',
    'function PlugByName(const AName: string): TPlugPlugin;',
    'var',
    '  k: Integer;',
    'begin',
    '  k := IdxByName(GList, AName);',
    '  if k < 0 then Result := nil else Result := TPlugPlugin(GList.Items[k]);',
    'end;',
    '',
    'function PlugCount: Integer;',
    'begin',
    '  if GList = nil then Result := 0 else Result := GList.Count;',
    'end;',
    '',
    'function PlugGet(AIndex: Integer): TPlugPlugin;',
    'begin',
    '  Result := nil;',
    '  if (GList = nil) or (AIndex < 0) or (AIndex >= GList.Count) then Exit;',
    '  Result := TPlugPlugin(GList.Items[AIndex]);',
    'end;',
    '',
    'procedure PlugRegisterRoutes;',
    'var',
    '  j: Integer;',
    '  p: TPlugPlugin;',
    'begin',
    '  for j := 0 to PlugCount - 1 do',
    '  begin',
    '    p := PlugGet(j);',
    '    LWRouteSet(p.Name, ''127.0.0.1:'' + IntToStr(p.Port));',
    '    LWLogFmt(''[%TAG%] 路由: /p/%s/ -> 127.0.0.1:%d'', [p.Name, p.Port]);',
    '  end;',
    'end;',
    '',
    'function PortOpen(APort: Integer): Boolean;',
    'var',
    '  s: TSocket;',
    '  addr: TInetSockAddr;',
    'begin',
    '  Result := False;',
    '  s := fpSocket(AF_INET, SOCK_STREAM, 0);',
    '  if s = -1 then Exit;',
    '  try',
    '    FillChar(addr, SizeOf(addr), 0);',
    '    addr.sin_family := AF_INET;',
    '    addr.sin_port := htons(APort);',
    '    addr.sin_addr.s_addr := htonl($7F000001);   { 127.0.0.1 }',
    '    Result := fpConnect(s, @addr, SizeOf(addr)) = 0;',
    '  finally',
    '    CloseSocket(s);',
    '  end;',
    'end;',
    '',
    'function StartOne(p: TPlugPlugin): Boolean;',
    'var',
    '  deadline: QWord;',
    '  nonce: string;',
    'begin',
    '  Result := False;',
    '  if p = nil then Exit;',
    '  if not FileExists(p.ExePath) then',
    '  begin',
    '    LWLog(''[%TAG%] 插件 exe 不存在，无法启动: '' + p.ExePath);',
    '    Exit;',
    '  end;',
    '  try',
    '    ForceDirectories(p.RunDir);',
    '    { 每次启动都取一份最新副本：重编过的 exe 在这里被换成新版本 }',
    '    CopyFileRaw(p.ExePath, p.RunExe);',
    '    if FileExists(p.IniPath) then',
    '      CopyFileRaw(p.IniPath, p.RunIni);',
    '  except',
    '    on E: Exception do',
    '    begin',
    '      LWLog(''[%TAG%] 复制运行副本失败 '' + p.Name + '': '' + E.Message);',
    '      Exit;',
    '    end;',
    '  end;',
    '',
    '  p.SourceStamp := FileAge(p.ExePath);',
    '  p.Proc := TProcess.Create(nil);',
    '  try',
    '    p.Proc.Executable := p.RunExe;',
    '    p.Proc.Parameters.Add(''--port='' + IntToStr(p.Port));',
    '    { 启动令牌：插件 exe 只认这套参数，单独双击会被 upluginguard 拦下。',
    '      nonce 每次拉起现取（带时间戳，2 分钟后作废），token = SHA1(secret|nonce)，',
    '      再附上宿主自己的 exe 名让插件核对父进程 —— 三条缺一条插件就不启动。 }',
    '    nonce := PlugGuardNewNonce;',
    '    p.Proc.Parameters.Add(PlugGuardNonceParam + nonce);',
    '    p.Proc.Parameters.Add(PlugGuardTokenParam + PlugGuardToken(nonce));',
    '    p.Proc.Parameters.Add(PlugGuardHostParam + ExtractFileName(ParamStr(0)));',
    '    {$IFDEF MSWINDOWS}',
    '    p.Proc.Options := p.Proc.Options + [poNoConsole];',
    '    {$ENDIF}',
    '    p.Proc.Execute;',
    '    Result := True;',
    '    LWLogFmt(''[%TAG%] 已启动插件 %s: pid=%d port=%d exe=%s'',',
    '      [p.Name, p.Proc.ProcessID, p.Port, p.RunExe]);',
    '  except',
    '    on E: Exception do',
    '    begin',
    '      LWLog(''[%TAG%] 启动插件失败 '' + p.Name + '': '' + E.Message);',
    '      FreeAndNil(p.Proc);',
    '    end;',
    '  end;',
    '',
    '  { 等端口真正监听：热更新后马上重载 iframe，不能让它打到 502 }',
    '  if Result then',
    '  begin',
    '    deadline := GetTickCount64 + 10000;',
    '    while GetTickCount64 < deadline do',
    '    begin',
    '      if PortOpen(p.Port) then',
    '      begin',
    '        LWLogFmt(''[%TAG%] 插件 %s 端口 %d 已就绪'', [p.Name, p.Port]);',
    '        Exit;',
    '      end;',
    '      if (p.Proc = nil) or (not p.Proc.Running) then',
    '      begin',
    '        LWLog(''[%TAG%] 插件进程启动后立即退出: '' + p.Name +',
    '          ''（退出码 '' + IntToStr(p.Proc.ExitCode) + ''；被启动守卫拦下时是 '' +',
    '          IntToStr(PlugGuardExitCode) + ''，见插件目录 plugin-guard.log）'');',
    '        Exit;',
    '      end;',
    '      Sleep(100);',
    '    end;',
    '    LWLogFmt(''[%TAG%] 等待插件 %s 端口 %d 超时'', [p.Name, p.Port]);',
    '  end;',
    'end;',
    '',
    'procedure StopOne(p: TPlugPlugin);',
    'var',
    '  deadline: QWord;',
    'begin',
    '  if (p = nil) or (p.Proc = nil) then Exit;',
    '  try',
    '    if p.Proc.Running then',
    '      p.Proc.Terminate(1);',
    '    deadline := GetTickCount64 + STOP_WAIT_MS;',
    '    while p.Proc.Running and (GetTickCount64 < deadline) do',
    '      Sleep(50);',
    '  except',
    '    on E: Exception do',
    '      LWLog(''[%TAG%] 停止插件失败 '' + p.Name + '': '' + E.Message);',
    '  end;',
    '  FreeAndNil(p.Proc);',
    'end;',
    '',
    'function PlugLaunchAll: Integer;',
    'var',
    '  j: Integer;',
    'begin',
    '  Result := 0;',
    '  for j := 0 to PlugCount - 1 do',
    '  begin',
    '    if PlugGet(j).Proc <> nil then Continue;',
    '    if StartOne(PlugGet(j)) then Inc(Result);',
    '  end;',
    'end;',
    '',
    'procedure PlugStopAll;',
    'var',
    '  j: Integer;',
    'begin',
    '  for j := 0 to PlugCount - 1 do',
    '    StopOne(PlugGet(j));',
    'end;',
    '',
    'function PlugHotUpdate(AIndex: Integer): Boolean;',
    'var',
    '  p: TPlugPlugin;',
    'begin',
    '  p := PlugGet(AIndex);',
    '  Result := False;',
    '  if p = nil then Exit;',
    '  LWLog(''[%TAG%] 热更新: '' + p.Name);',
    '  StopOne(p);                 { 先停，运行副本才不会被锁 }',
    '  Result := StartOne(p);      { 重新复制最新 exe/ini 再拉起 }',
    '  if Result then',
    '    Inc(p.Seq);',
    'end;',
    '',
    'function PlugSourceChanged(AIndex: Integer): Boolean;',
    'var',
    '  p: TPlugPlugin;',
    '  stamp: LongInt;',
    'begin',
    '  p := PlugGet(AIndex);',
    '  Result := False;',
    '  if p = nil then Exit;',
    '  stamp := FileAge(p.ExePath);',
    '  if (stamp < 0) or (p.SourceStamp < 0) then Exit;',
    '  Result := stamp <> p.SourceStamp;',
    'end;',
    '',
    'function PlugChangedCount: Integer;',
    'var',
    '  j: Integer;',
    'begin',
    '  Result := 0;',
    '  for j := 0 to PlugCount - 1 do',
    '    if PlugSourceChanged(j) then Inc(Result);',
    'end;',
    '',
    'function PlugURL(AIndex: Integer): string;',
    'var',
    '  p: TPlugPlugin;',
    'begin',
    '  p := PlugGet(AIndex);',
    '  if p = nil then Result := '''' else Result := ''/p/'' + p.Name + ''/'';',
    'end;',
    '',
    'function PlugFrameURL(AIndex: Integer): string;',
    'begin',
    '  Result := PlugURL(AIndex) + ''?v='' + IntToStr(PlugGet(AIndex).Seq);',
    'end;',
    '',
    'function PlugRunning(AIndex: Integer): Boolean;',
    'var',
    '  p: TPlugPlugin;',
    'begin',
    '  p := PlugGet(AIndex);',
    '  Result := (p <> nil) and (p.Proc <> nil) and p.Proc.Running;',
    'end;',
    '',
    'finalization',
    '  PlugStopAll;',
    '  if GList <> nil then',
    '  begin',
    '    for i := 0 to GList.Count - 1 do',
    '      TPlugPlugin(GList.Items[i]).Free;',
    '    FreeAndNil(GList);',
    '  end;',
    'end.'
  );

  cGuardLines: array[0..343] of string = (
    'unit upluginguard;',
    '{ pluginsDemo :: 插件启动守卫（宿主与插件共用的一个单元）',
    '',
    '  目的：插件的 exe 不能单独运行。双击、命令行、被别人 Start-Process 时，',
    '  插件自己要能识别出来 —— 打印/弹窗提示一句"请从主程序进入"，然后退出。',
    '',
    '  宿主（upluginproc.StartOne）每次拉起插件时现取一个 nonce，算出口令，三条参数：',
    '',
    '      --lw-plug-nonce=<unix 秒>-<随机 32 位十六进制>',
    '      --lw-plug-token=SHA1(secret|nonce)        小写十六进制',
    '      --lw-plug-host=<宿主 exe 文件名，如 pluginsdemo.exe>',
    '',
    '  插件 .lpr 的第一句调 PlugGuardCheck，逐条验：',
    '',
    '      1. 三条参数都在          —— 少了它就不是宿主起的',
    '      2. nonce 时间戳没过期     —— 挡住"把抓到的命令行存下来以后再重放"',
    '      3. token 对得上          —— 光知道格式没用，得有 secret',
    '      4. 父进程 exe 名与 --lw-plug-host 一致（仅 Windows）—— 光有 secret 也没用，',
    '                                  还得是被主程序拉起来的子进程',
    '',
    '  任何一条不过：提示 + Halt(3)。宿主侧 StartOne 看到了就记一条日志。',
    '',
    '  改 secret：把 PlugGuardSecretHex 换成自己的随机串（两边共用本单元，改一处即可），',
    '  重新编译宿主与全部插件。写成十六进制字符串是为了不在 exe 里留下明文可读的口令。',
    '}',
    '{$mode objfpc}{$H+}',
    '',
    'interface',
    '',
    'const',
    '  PlugGuardTokenParam = ''--lw-plug-token='';',
    '  PlugGuardNonceParam = ''--lw-plug-nonce='';',
    '  PlugGuardHostParam  = ''--lw-plug-host='';',
    '  { nonce 里时间戳允许的偏差（秒）。宿主一拉起就校验，正常不会超过几秒；',
    '    留 120 秒是给慢机器 / 调试断点用的 }',
    '  PlugGuardMaxSkewSec = 120;',
    '  { 守卫拒绝时的退出码，宿主/脚本可据此判断"是被拦下的插件" }',
    '  PlugGuardExitCode = 3;',
    '',
    '{ 共享口令原文（由 PlugGuardSecretHex 解码而来） }',
    'function PlugGuardSecret: string;',
    '{ SHA1(secret + ''|'' + nonce) 的小写十六进制 }',
    'function PlugGuardToken(const ANonce: string): string;',
    '{ 宿主用：<unix 秒>-<随机 32 位十六进制> }',
    'function PlugGuardNewNonce: string;',
    '{ 取 --xxx=value 形式的命令行参数，没有返回空串 }',
    'function PlugGuardArg(const APrefix: string): string;',
    '{ 只校验不退出；AReason 给内部原因码：'''' = 通过，',
    '  ''missing'' / ''stale'' / ''badtoken'' / ''nothost'' 见 PlugGuardReasonText }',
    'function PlugGuardValidate(out AReason: string): Boolean;',
    '{ 原因码 -> 给用户看的中文说明 }',
    'function PlugGuardReasonText(const AReason: string): string;',
    '{ 插件的 .lpr 第一句：校验失败就提示并 Halt(PlugGuardExitCode)。ATitle 拼提示语用 }',
    'procedure PlugGuardCheck(const ATitle: string);',
    '',
    'implementation',
    '',
    'uses',
    '  SysUtils, DateUtils,',
    '  {$IFDEF MSWINDOWS}Windows,{$ENDIF}',
    '  sha1;',
    '',
    'const',
    '  { ''lazarusWeb/plugin-guard/v1-2f9c'' 的十六进制。改这里 = 换口令。 }',
    '  PlugGuardSecretHex = ''6C617A617275735765622F706C7567696E2D67756172642F76312D32663963'';',
    '',
    'function HexToStr(const AHex: string): string;',
    'var',
    '  i, n: Integer;',
    '  b: Byte;',
    'begin',
    '  Result := '''';',
    '  i := 1;',
    '  n := Length(AHex);',
    '  while i + 1 <= n do',
    '  begin',
    '    b := StrToIntDef(''$'' + Copy(AHex, i, 2), 0);',
    '    if b <> 0 then Result := Result + Chr(b);',
    '    Inc(i, 2);',
    '  end;',
    'end;',
    '',
    'function PlugGuardSecret: string;',
    'begin',
    '  Result := HexToStr(PlugGuardSecretHex);',
    'end;',
    '',
    'function PlugGuardToken(const ANonce: string): string;',
    'begin',
    '  Result := LowerCase(SHA1Print(SHA1String(PlugGuardSecret + ''|'' + ANonce)));',
    'end;',
    '',
    'function PlugGuardNewNonce: string;',
    'var',
    '  r: LongWord;',
    'begin',
    '  r := LongWord(Random(MaxInt)) shl 16 xor LongWord(Random(MaxInt));',
    '  Result := IntToStr(DateTimeToUnix(Now, False)) + ''-'' + IntToHex(r, 8);',
    'end;',
    '',
    'function PlugGuardArg(const APrefix: string): string;',
    'var',
    '  i: Integer;',
    '  s: string;',
    'begin',
    '  Result := '''';',
    '  for i := 1 to ParamCount do',
    '  begin',
    '    s := ParamStr(i);',
    '    if (Length(s) > Length(APrefix)) and',
    '       (Copy(s, 1, Length(APrefix)) = APrefix) then',
    '      Exit(Copy(s, Length(APrefix) + 1, MaxInt));',
    '  end;',
    'end;',
    '',
    '{$IFDEF MSWINDOWS}',
    'type',
    '  TProcessBasicInformation = record',
    '    ExitStatus: LongInt;',
    '    PebBaseAddress: Pointer;',
    '    AffinityMask: PtrUInt;',
    '    BasePriority: LongInt;',
    '    UniqueProcessId: PtrUInt;',
    '    InheritedFromUniqueProcessId: PtrUInt;',
    '  end;',
    '',
    'function NtQueryInformationProcess(ProcessHandle: THandle;',
    '  ProcessInformationClass: DWORD; ProcessInformation: Pointer;',
    '  ProcessInformationLength: ULONG; ReturnLength: PULONG): LongInt; stdcall;',
    '  external ''ntdll.dll'' name ''NtQueryInformationProcess'';',
    '',
    '{ 父进程的 exe 全路径；取不到返回空串（例如父进程已退出并被回收） }',
    'function ParentExePath: string;',
    'var',
    '  pbi: TProcessBasicInformation;',
    '  ret: ULONG;',
    '  ppid: DWORD;',
    '  h: THandle;',
    '  buf: array[0..1023] of WideChar;',
    '  size: DWORD;',
    'begin',
    '  Result := '''';',
    '  FillChar(pbi, SizeOf(pbi), 0);',
    '  if NtQueryInformationProcess(GetCurrentProcess, 0, @pbi, SizeOf(pbi), @ret) <> 0 then Exit;',
    '  ppid := DWORD(pbi.InheritedFromUniqueProcessId);',
    '  if ppid = 0 then Exit;',
    '  h := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, ppid);',
    '  if h = 0 then Exit;',
    '  try',
    '    size := SizeOf(buf) div SizeOf(WideChar);',
    '    if QueryFullProcessImageNameW(h, 0, @buf[0], @size) then',
    '      Result := UTF8Encode(WideString(buf));',
    '  finally',
    '    CloseHandle(h);',
    '  end;',
    'end;',
    '{$ENDIF}',
    '',
    'function PlugGuardValidate(out AReason: string): Boolean;',
    'var',
    '  tok, non, host, p, parent: string;',
    '  t, nowsec, dash: Int64;',
    'begin',
    '  AReason := '''';',
    '  Result := False;',
    '  tok  := PlugGuardArg(PlugGuardTokenParam);',
    '  non  := PlugGuardArg(PlugGuardNonceParam);',
    '  host := PlugGuardArg(PlugGuardHostParam);',
    '  if (tok = '''') or (non = '''') or (host = '''') then',
    '  begin',
    '    AReason := ''missing'';',
    '    Exit;',
    '  end;',
    '',
    '  dash := Pos(''-'', non);',
    '  if dash <= 1 then',
    '  begin',
    '    AReason := ''badtoken'';',
    '    Exit;',
    '  end;',
    '  t := StrToInt64Def(Copy(non, 1, dash - 1), 0);',
    '  nowsec := DateTimeToUnix(Now, False);',
    '  if (t = 0) or (Abs(nowsec - t) > PlugGuardMaxSkewSec) then',
    '  begin',
    '    AReason := ''stale'';',
    '    Exit;',
    '  end;',
    '',
    '  if LowerCase(tok) <> PlugGuardToken(non) then',
    '  begin',
    '    AReason := ''badtoken'';',
    '    Exit;',
    '  end;',
    '',
    '  {$IFDEF MSWINDOWS}',
    '  parent := ParentExePath;',
    '  if parent = '''' then',
    '  begin',
    '    { 父进程查不到（被强杀/被回收）也算不通过：宁可让用户重开主程序 }',
    '    AReason := ''nothost'';',
    '    Exit;',
    '  end;',
    '  if not SameText(ExtractFileName(parent), host) then',
    '  begin',
    '    AReason := ''nothost'';',
    '    Exit;',
    '  end;',
    '  {$ENDIF}',
    '',
    '  Result := True;',
    'end;',
    '',
    'function PlugGuardReasonText(const AReason: string): string;',
    'begin',
    '  if AReason = ''missing'' then',
    '    Result := ''缺少主程序下发的启动令牌''',
    '  else if AReason = ''stale'' then',
    '    Result := ''启动令牌已过期（超过 '' + IntToStr(PlugGuardMaxSkewSec) + '' 秒）''',
    '  else if AReason = ''badtoken'' then',
    '    Result := ''启动令牌校验不通过''',
    '  else if AReason = ''nothost'' then',
    '    Result := ''不是由主程序拉起的子进程''',
    '  else',
    '    Result := ''未知原因（'' + AReason + ''）'';',
    'end;',
    '',
    '{$IFDEF MSWINDOWS}',
    '{ 真正的控制台上按控制台代码页（中文 Windows 是 936）输出，否则中文会是乱码；',
    '  没有控制台（输出被重定向到管道 / 宿主 poNoConsole）就原样给 UTF-8 字节，',
    '  让抓取方按 UTF-8 读 }',
    'function ConsoleText(const S: string): RawByteString;',
    'var',
    '  ws: UnicodeString;',
    '  cp: UINT;',
    '  n: Integer;',
    '  h: THandle;',
    'begin',
    '  { 只有 stderr 还挂在字符设备（真控制台）时才转代码页；',
    '    重定向到文件/管道就给 UTF-8 字节，读的一方按 UTF-8 处理 }',
    '  h := GetStdHandle(STD_ERROR_HANDLE);',
    '  if (h = 0) or (h = INVALID_HANDLE_VALUE) or (GetFileType(h) <> FILE_TYPE_CHAR) then',
    '    Exit(RawByteString(S));',
    '  cp := GetConsoleOutputCP;',
    '  if cp = 0 then cp := CP_ACP;',
    '  ws := UTF8Decode(S);',
    '  n := WideCharToMultiByte(cp, 0, PWideChar(ws), Length(ws), nil, 0, nil, nil);',
    '  SetLength(Result, n);',
    '  if n > 0 then',
    '    WideCharToMultiByte(cp, 0, PWideChar(ws), Length(ws), PAnsiChar(Result), n, nil, nil);',
    'end;',
    '{$ELSE}',
    'function ConsoleText(const S: string): RawByteString;',
    'begin',
    '  Result := RawByteString(S);',
    'end;',
    '{$ENDIF}',
    '',
    '{ 直接往 stderr 句柄写字节：走 Write(ErrOutput) 的话 FPC 会按默认代码页',
    '  再转一次，编码就对不上了。没有控制台/句柄无效时静默跳过。 }',
    'procedure DumpStdErr(const S: string);',
    'var',
    '  b: RawByteString;',
    'begin',
    '  b := ConsoleText(S);',
    '  if Length(b) = 0 then Exit;',
    '  try',
    '    FileWrite(StdErrorHandle, PAnsiChar(b)^, Length(b));',
    '  except',
    '    { 句柄不可写（poNoConsole）就不写，提示交给消息框 }',
    '  end;',
    'end;',
    '',
    '{ 提示 + 退出。三种启动方式各有各的输出通道：',
    '    双击        -> 控制台子系统会开个窗口，文字一闪就没，必须靠消息框',
    '    命令行      -> 控制台里能看到文字',
    '    Host 拉起但令牌不对（改了口令只重编了一边）',
    '                -> 没有控制台，且**不弹消息框**：宿主正在等端口，弹个模态框',
    '                   会把宿主的启动流程卡满 10 秒、还留一个没人点的窗口在桌面上',
    '   脚本/CI     -> LW_PLUGIN_GUARD_NOUI=1，只写 stderr 和日志 }',
    'procedure PlugGuardCheck(const ATitle: string);',
    'var',
    '  reason, msg, logFile, line: string;',
    '  showBox: Boolean;',
    '  {$IFDEF MSWINDOWS}',
    '  ws: WideString;',
    '  {$ENDIF}',
    '  f: TextFile;',
    'begin',
    '  if PlugGuardValidate(reason) then Exit;',
    '',
    '  { 一个参数都没带 = 用户自己双击/命令行起；带了但不对 = 被程序拉起。',
    '    后者只写日志和 stderr，别弹窗。 }',
    '  showBox := reason = ''missing'';',
    '',
    '  if showBox then',
    '    msg := ''「'' + ATitle + ''」是 lazarusWeb 的插件程序，不能单独运行。'' + LineEnding +',
    '      LineEnding +',
    '      ''请先启动主程序，再从左侧菜单打开它。'' + LineEnding +',
    '      ''（若主程序已异常退出，可运行 stop-all.bat 清理残留插件进程。）''',
    '  else',
    '    msg := ''「'' + ATitle + ''」启动被拒绝：'' + PlugGuardReasonText(reason) + LineEnding +',
    '      LineEnding +',
    '      ''宿主与插件的启动口令不一致 —— 改过 common\upluginguard.pas 之后'' + LineEnding +',
    '      ''宿主和全部插件都要重编（跑 build.bat / build-all.bat）。'';',
    '',
    '  msg := msg + LineEnding + LineEnding +',
    '    ''拒绝原因：'' + PlugGuardReasonText(reason) + '' ['' + reason + '']'';',
    '',
    '  DumpStdErr(LineEnding + msg + LineEnding + LineEnding);',
    '',
    '  { 插件目录下留一行记录，方便排查"为什么插件没起来" }',
    '  try',
    '    logFile := ExtractFilePath(ParamStr(0)) + ''plugin-guard.log'';',
    '    AssignFile(f, logFile);',
    '    if FileExists(logFile) then Append(f) else Rewrite(f);',
    '    try',
    '      line := FormatDateTime(''yyyy-mm-dd hh:nn:ss'', Now) + ''  pid='' +',
    '        IntToStr(GetProcessID) + ''  '' + reason;',
    '      WriteLn(f, line);',
    '    finally',
    '      CloseFile(f);',
    '    end;',
    '  except',
    '    { 日志写不了不影响主流程 }',
    '  end;',
    '',
    '  {$IFDEF MSWINDOWS}',
    '  { 脚本 / CI 里跑守卫自检时设 LW_PLUGIN_GUARD_NOUI=1：只写日志和 stderr，',
    '    不弹消息框（否则自动化会卡在窗口上等人点确定）。正常使用不要设它。 }',
    '  if showBox and (SysUtils.GetEnvironmentVariable(''LW_PLUGIN_GUARD_NOUI'') <> ''1'') then',
    '  begin',
    '    ws := UTF8Decode(msg);',
    '    MessageBoxW(0, PWideChar(ws), PWideChar(UTF8Decode(''插件启动被拒绝'')),',
    '      MB_OK or MB_ICONWARNING or MB_TOPMOST);',
    '  end;',
    '  {$ENDIF}',
    '',
    '  Halt(PlugGuardExitCode);',
    'end;',
    '',
    'initialization',
    '  Randomize;',
    '',
    'end.'
  );

  cAuthLines: array[0..363] of string = (
    'unit upluginauth;',
    '{ %TAG% :: 用户与角色（宿主侧，插件不链接本单元）',
    '',
    '  和 upluginguard 的分工别混：',
    '    upluginguard  管"这个 exe 能不能被拉起"（进程来源），与"谁在用"无关；',
    '    本单元         管"这个登录用户能不能打开这个插件"（业务权限）。',
    '',
    '  演示账号（真实项目把 LWAuthLogin 换成查库/查接口即可，其它三个入口都不用动）：',
    '',
    '    admin   / 123456   角色 admin      全部插件',
    '    analyst / 123456   角色 analyst    仪表盘 + 便签',
    '    guest   / 123456   角色 guest      只有便签',
    '',
    '  插件清单声明需要哪些角色：',
    '',
    '    roles=admin,analyst     只给这两个角色',
    '    roles=admin             只给管理员',
    '    roles=                 （不写 / 留空）所有已登录用户都能打开',
    '    admin 角色隐含全部权限（通配），清单里不用重复列 admin',
    '',
    '  判定只有一个实现（LWAuthCanOpen），三个入口共用，保证"看得见"和',
    '  "打得开"永远一致：',
    '    1. 登录   LWAuthLogin       校验口令，得到角色串',
    '    2. 菜单   LWAuthCanOpen     决定侧栏里显不显示这一项',
    '    3. 路由   LWAuthGuard       注册给 lwroute，/p/<名>/ 一律先判定，',
    '                                无权限直接 403，不代理到插件进程',
    '  只做 1、2 是不够的：菜单只是 UI，直接敲 URL 照样能进插件页面 ——',
    '  所以 3 才是真正的强制点，1、2 只是让界面别骗人。',
    '}',
    '{$mode objfpc}{$H+}',
    '',
    'interface',
    '',
    'uses',
    '  SysUtils, lwbase, lwhttp, lwapp, lwsession, lwroute, upluginproc;',
    '',
    'const',
    '  { 会话变量名：登录名 / 角色串（逗号分隔）。放在会话上而不是全局变量 ——',
    '    同一进程里多个浏览器/多页签是不同用户，全局变量会把 A 的身份带给 B }',
    '  LWAuthUserVar  = ''lwuser'';',
    '  LWAuthRolesVar = ''lwroles'';',
    '',
    '  { 演示账号口令（明文只为演示；真实项目不要落到源码里） }',
    '  LWAuthDemoPass = ''123456'';',
    '  { admin 通配：拥有任何插件，不必在每个清单里单独列出 }',
    '  LWAuthAdminRole = ''admin'';',
    '',
    'type',
    '  TLWAuthAccount = record',
    '    User: string;',
    '    Pass: string;',
    '    Roles: string;',
    '    Display: string;',
    '  end;',
    '',
    'const',
    '  LWAuthAccounts: array[0..2] of TLWAuthAccount = (',
    '    (User: ''admin'';   Pass: ''123456''; Roles: ''admin'';',
    '     Display: ''系统管理员''),',
    '    (User: ''analyst''; Pass: ''123456''; Roles: ''analyst'';',
    '     Display: ''数据分析员''),',
    '    (User: ''guest'';   Pass: ''123456''; Roles: ''guest'';',
    '     Display: ''访客''));',
    '',
    '{ 账号口令校验。True 时 ARoles/ADisplay 是账号的角色与中文名 }',
    'function LWAuthLogin(const AUser, APass: string;',
    '  out ARoles, ADisplay, AErr: string): Boolean;',
    '{ 角色串里是否含某个角色（逗号分隔，忽略大小写与空格） }',
    'function LWAuthHasRole(const ARoles, ARole: string): Boolean;',
    '{ 当前角色能不能打开需要 ANeed 的插件。ANeed 空 = 所有已登录用户 }',
    'function LWAuthCanOpen(const ARoles, ANeed: string): Boolean;',
    '{ 角色串 -> 给人看的名字，''admin,analyst'' -> ''管理员、分析师'' }',
    'function LWAuthRoleText(const ARoles: string): string;',
    '{ 清单 roles= -> 提示语，'''' -> ''所有已登录用户'' }',
    'function LWAuthNeedText(const ANeed: string): string;',
    '{ 账号中文名（找不到就返回用户名本身） }',
    'function LWAuthDisplayOf(const AUser: string): string;',
    '',
    '{ 当前请求线程所属会话的身份（事件处理里取；后台线程取到 ''''） }',
    'function LWAuthSessionUser: string;',
    'function LWAuthSessionRoles: string;',
    'procedure LWAuthSessionSet(const AUser, ARoles: string);',
    'procedure LWAuthSessionClear;',
    '',
    '{ sid -> 身份。会话不存在/未认证/没登录过都返回 False（AuthGuard 用） }',
    'function LWAuthRolesOfSid(const ASid: string;',
    '  out AUser, ARoles: string): Boolean;',
    '',
    '{ lwroute 鉴权回调：放行返回 True；否则 AReason 是给 403 页面看的中文原因 }',
    'function LWAuthGuard(const AName, ASid: string;',
    '  out AUser, AReason: string): Boolean;',
    '{ lwroute 身份注入回调：给插件进程签发 user/roles/token/ts。',
    '  签名公式与 common/upluginidentity.pas 里校验的必须一致 }',
    'function LWAuthIdentity(const ASid: string;',
    '  out AUser, ARoles, AToken, ATS: string): Boolean;',
    '{ 在 TLWApp.Run 之前调用一次：把鉴权与身份注入都挂到路由上 }',
    'procedure LWAuthRegister;',
    '',
    'implementation',
    '',
    'uses',
    '  DateUtils, sha1, upluginguard;',
    '',
    'function LWAuthHasRole(const ARoles, ARole: string): Boolean;',
    'var',
    '  s: string;',
    '  p: Integer;',
    'begin',
    '  Result := False;',
    '  if (ARoles = '''') or (ARole = '''') then Exit;',
    '  s := ARoles;',
    '  while s <> '''' do',
    '  begin',
    '    p := Pos('','', s);',
    '    if p > 0 then',
    '    begin',
    '      if SameText(Trim(Copy(s, 1, p - 1)), ARole) then Exit(True);',
    '      s := Copy(s, p + 1, MaxInt);',
    '    end',
    '    else',
    '    begin',
    '      if SameText(Trim(s), ARole) then Exit(True);',
    '      s := '''';',
    '    end;',
    '  end;',
    'end;',
    '',
    'function LWAuthCanOpen(const ARoles, ANeed: string): Boolean;',
    'var',
    '  s: string;',
    '  p: Integer;',
    'begin',
    '  { 清单没写 roles=：不算"限制"，只是"任何已登录用户" }',
    '  if Trim(ANeed) = '''' then Exit(True);',
    '  if Trim(ARoles) = '''' then Exit(False);',
    '  { 管理员通配：加插件时不用回头改 admin 的角色串 }',
    '  if LWAuthHasRole(ARoles, LWAuthAdminRole) then Exit(True);',
    '  s := ANeed;',
    '  while s <> '''' do',
    '  begin',
    '    p := Pos('','', s);',
    '    if p > 0 then',
    '    begin',
    '      if LWAuthHasRole(ARoles, Trim(Copy(s, 1, p - 1))) then Exit(True);',
    '      s := Copy(s, p + 1, MaxInt);',
    '    end',
    '    else',
    '    begin',
    '      if LWAuthHasRole(ARoles, Trim(s)) then Exit(True);',
    '      s := '''';',
    '    end;',
    '  end;',
    '  Result := False;',
    'end;',
    '',
    'function LWAuthRoleName(const ARole: string): string;',
    'begin',
    '  if SameText(ARole, ''admin'') then',
    '    Result := ''管理员''',
    '  else if SameText(ARole, ''analyst'') then',
    '    Result := ''分析师''',
    '  else if SameText(ARole, ''guest'') then',
    '    Result := ''访客''',
    '  else',
    '    Result := ARole;',
    'end;',
    '',
    'function LWAuthRoleText(const ARoles: string): string;',
    'var',
    '  s: string;',
    '  p: Integer;',
    'begin',
    '  Result := '''';',
    '  s := ARoles;',
    '  while s <> '''' do',
    '  begin',
    '    p := Pos('','', s);',
    '    if p > 0 then',
    '    begin',
    '      if Trim(Copy(s, 1, p - 1)) <> '''' then',
    '      begin',
    '        if Result <> '''' then Result := Result + ''、'';',
    '        Result := Result + LWAuthRoleName(Trim(Copy(s, 1, p - 1)));',
    '      end;',
    '      s := Copy(s, p + 1, MaxInt);',
    '    end',
    '    else',
    '    begin',
    '      if Trim(s) <> '''' then',
    '      begin',
    '        if Result <> '''' then Result := Result + ''、'';',
    '        Result := Result + LWAuthRoleName(Trim(s));',
    '      end;',
    '      s := '''';',
    '    end;',
    '  end;',
    'end;',
    '',
    'function LWAuthNeedText(const ANeed: string): string;',
    'begin',
    '  if Trim(ANeed) = '''' then',
    '    Result := ''所有已登录用户''',
    '  else',
    '    Result := LWAuthRoleText(ANeed);',
    'end;',
    '',
    'function LWAuthDisplayOf(const AUser: string): string;',
    'var',
    '  i: Integer;',
    'begin',
    '  for i := Low(LWAuthAccounts) to High(LWAuthAccounts) do',
    '    if SameText(LWAuthAccounts[i].User, AUser) then',
    '      Exit(LWAuthAccounts[i].Display);',
    '  Result := AUser;',
    'end;',
    '',
    'function LWAuthLogin(const AUser, APass: string;',
    '  out ARoles, ADisplay, AErr: string): Boolean;',
    'var',
    '  i: Integer;',
    'begin',
    '  ARoles := '''';',
    '  ADisplay := '''';',
    '  AErr := '''';',
    '  Result := False;',
    '  if Trim(AUser) = '''' then',
    '  begin',
    '    AErr := ''请输入用户名'';',
    '    Exit;',
    '  end;',
    '  for i := Low(LWAuthAccounts) to High(LWAuthAccounts) do',
    '    if SameText(LWAuthAccounts[i].User, Trim(AUser)) then',
    '    begin',
    '      if LWAuthAccounts[i].Pass <> APass then',
    '      begin',
    '        AErr := ''用户名或密码错误'';',
    '        Exit;',
    '      end;',
    '      ARoles := LWAuthAccounts[i].Roles;',
    '      ADisplay := LWAuthAccounts[i].Display;',
    '      Exit(True);',
    '    end;',
    '  { 不区分"用户不存在"和"口令错误"：别让人拿错误提示枚举账号 }',
    '  AErr := ''用户名或密码错误'';',
    'end;',
    '',
    'function LWAuthSessionUser: string;',
    'var',
    '  S: TLWSessionBase;',
    'begin',
    '  Result := '''';',
    '  S := LWCurrentSession;',
    '  if S <> nil then',
    '    Result := S.SessionGetVar(LWAuthUserVar);',
    'end;',
    '',
    'function LWAuthSessionRoles: string;',
    'var',
    '  S: TLWSessionBase;',
    'begin',
    '  Result := '''';',
    '  S := LWCurrentSession;',
    '  if S <> nil then',
    '    Result := S.SessionGetVar(LWAuthRolesVar);',
    'end;',
    '',
    'procedure LWAuthSessionSet(const AUser, ARoles: string);',
    'var',
    '  S: TLWSessionBase;',
    'begin',
    '  S := LWCurrentSession;',
    '  if S = nil then Exit;',
    '  S.SessionSetVar(LWAuthUserVar, AUser);',
    '  S.SessionSetVar(LWAuthRolesVar, ARoles);',
    'end;',
    '',
    'procedure LWAuthSessionClear;',
    'begin',
    '  LWAuthSessionSet('''', '''');',
    'end;',
    '',
    'function LWAuthRolesOfSid(const ASid: string;',
    '  out AUser, ARoles: string): Boolean;',
    'var',
    '  srv: TLWServer;',
    '  s: TLWSession;',
    'begin',
    '  AUser := '''';',
    '  ARoles := '''';',
    '  Result := False;',
    '  if Trim(ASid) = '''' then Exit;',
    '  srv := TLWApp.Server;',
    '  if srv = nil then Exit;',
    '  { Find 返回时 RefCount+1：必须 Release，否则会话永远不回收 }',
    '  s := srv.Store.Find(ASid);',
    '  if s = nil then Exit;',
    '  try',
    '    { Authenticated 而不是"有用户变量"：注销后变量可能还留着旧值 }',
    '    if not s.Authenticated then Exit;',
    '    AUser := s.SessionGetVar(LWAuthUserVar);',
    '    ARoles := s.SessionGetVar(LWAuthRolesVar);',
    '    Result := AUser <> '''';',
    '  finally',
    '    srv.Store.Release(s);',
    '  end;',
    'end;',
    '',
    'function LWAuthGuard(const AName, ASid: string;',
    '  out AUser, AReason: string): Boolean;',
    'var',
    '  roles: string;',
    '  p: TPlugPlugin;',
    'begin',
    '  AUser := '''';',
    '  AReason := '''';',
    '  Result := False;',
    '',
    '  if not LWAuthRolesOfSid(ASid, AUser, roles) then',
    '  begin',
    '    AReason := ''未登录，或会话已过期。请回到工作台重新登录，再从侧栏打开本插件。'';',
    '    Exit;',
    '  end;',
    '',
    '  p := PlugByName(AName);',
    '  if p = nil then',
    '  begin',
    '    { 路由存在但清单里没有：别当成"没限制"放过去 }',
    '    AReason := ''插件「'' + AName + ''」不在清单里，宿主拒绝转发。'';',
    '    Exit;',
    '  end;',
    '',
    '  if not LWAuthCanOpen(roles, p.Roles) then',
    '  begin',
    '    AReason := ''当前账号（'' + AUser + ''，角色：'' + LWAuthRoleText(roles) +',
    '      ''）没有该插件的访问权限。'';',
    '    Exit;',
    '  end;',
    '',
    '  Result := True;',
    'end;',
    '',
    'function LWAuthIdentity(const ASid: string;',
    '  out AUser, ARoles, AToken, ATS: string): Boolean;',
    'begin',
    '  AUser := '''';',
    '  ARoles := '''';',
    '  AToken := '''';',
    '  ATS := '''';',
    '  Result := LWAuthRolesOfSid(ASid, AUser, ARoles);',
    '  if not Result then Exit;',
    '  ATS := IntToStr(DateTimeToUnix(Now, False));',
    '  { 与 upluginidentity.Checked 用同一个 secret、同一个拼接顺序。',
    '    浏览器伪造 X-LW-User 时算不出这个 token，插件侧会直接拒掉 }',
    '  AToken := LowerCase(SHA1Print(SHA1String(',
    '    PlugGuardSecret + ''|'' + AUser + ''|'' + ARoles + ''|'' + ATS)));',
    'end;',
    '',
    'procedure LWAuthRegister;',
    'begin',
    '  LWRouteSetAuth(@LWAuthGuard);',
    '  LWRouteSetIdentity(@LWAuthIdentity);',
    'end;',
    '',
    'end.'
  );

  cIdentityLines: array[0..103] of string = (
    'unit upluginidentity;',
    '{ %TAG% :: 插件侧身份读取（宿主签发 + 本地验签）',
    '',
    '  为什么要这个单元：宿主和登录状态都在宿主进程里，插件是独立 exe，',
    '  有自己的会话表，看不到宿主的 lwuser/lwroles。宿主在 /p/ 反代时把',
    '  身份写进请求头（lwroute 的 LWRouteSetIdentity），插件在这里读头、',
    '  验签之后才认。',
    '',
    '  签名用 upluginguard 里同一个 secret，公式：',
    '',
    '      SHA1(secret + ''|'' + user + ''|'' + roles + ''|'' + ts)   小写十六进制',
    '',
    '  ts 是 Unix 秒，允许偏差 PlugIdentityMaxSkewSec = 60 秒，挡住截获旧头',
    '  后的重放。secret 改了要宿主和插件一起重编（共用单元，改一处即可）。',
    '',
    '  直连插件监听端口（127.0.0.1:8882）时没有签名头，三个 getter 都返回',
    '  空串 —— 这正好回答"这个请求是不是从宿主进来的"。浏览器自己伪造',
    '  X-LW-User 头也没用：签名算不出来。 }',
    '{$mode objfpc}{$H+}',
    '',
    'interface',
    '',
    'const',
    '  PlugIdentityMaxSkewSec = 60;',
    '',
    '{ 验签通过才返回非空。业务代码要判断身份来源时先调 PlugIdentityValid }',
    'function PlugIdentityValid: Boolean;',
    'function PlugIdentityUser: string;',
    'function PlugIdentityRoles: string;',
    '{ 演示账号的中文名；没验过签返回"未识别（请从主程序进入）" }',
    'function PlugIdentityDisplay: string;',
    '',
    'implementation',
    '',
    'uses',
    '  SysUtils, DateUtils, sha1, lwhttp, upluginguard;',
    '',
    'function Checked(out AUser, ARoles: string): Boolean;',
    'var',
    '  token, ts, expect: string;',
    '  t: Int64;',
    'begin',
    '  AUser := '''';',
    '  ARoles := '''';',
    '  Result := False;',
    '  AUser := LWIdentityUser;',
    '  ARoles := LWIdentityRoles;',
    '  if (AUser = '''') or (ARoles = '''') then Exit;',
    '  ts := LWIdentityTs;',
    '  token := LowerCase(LWIdentityToken);',
    '  if (ts = '''') or (token = '''') then Exit;',
    '  t := StrToInt64Def(ts, 0);',
    '  if t <= 0 then Exit;',
    '  if Abs(DateTimeToUnix(Now, False) - t) > PlugIdentityMaxSkewSec then Exit;',
    '  expect := LowerCase(SHA1Print(SHA1String(',
    '    PlugGuardSecret + ''|'' + AUser + ''|'' + ARoles + ''|'' + ts)));',
    '  Result := expect = token;',
    '  if not Result then',
    '  begin',
    '    AUser := '''';',
    '    ARoles := '''';',
    '  end;',
    'end;',
    '',
    'function PlugIdentityValid: Boolean;',
    'var',
    '  u, r: string;',
    'begin',
    '  Result := Checked(u, r);',
    'end;',
    '',
    'function PlugIdentityUser: string;',
    'var',
    '  u, r: string;',
    'begin',
    '  if Checked(u, r) then',
    '    Result := u',
    '  else',
    '    Result := '''';',
    'end;',
    '',
    'function PlugIdentityRoles: string;',
    'var',
    '  u, r: string;',
    'begin',
    '  if Checked(u, r) then',
    '    Result := r',
    '  else',
    '    Result := '''';',
    'end;',
    '',
    'function PlugIdentityDisplay: string;',
    'var',
    '  u: string;',
    'begin',
    '  u := PlugIdentityUser;',
    '  if u = '''' then Exit(''未识别（请从主程序进入）'');',
    '  if SameText(u, ''admin'') then Exit(''系统管理员'');',
    '  if SameText(u, ''analyst'') then Exit(''数据分析员'');',
    '  if SameText(u, ''guest'') then Exit(''访客'');',
    '  Result := u;',
    'end;',
    '',
    'end.'
  );

  cLoginLines: array[0..138] of string = (
    'unit ulogin;',
    '{ %TAG% :: 登录窗体（用户权限的第一道门）',
    '',
    '  基类 TLWLoginForm 已经把「空白登录窗自动摆一套界面 + 图形验证码 + 提交',
    '  校验 + 认证通过后换出主窗体」全做完了，这里只做三件事：',
    '',
    '    1. 挂 OnLogin：交给 upluginauth.LWAuthLogin 校验口令，成功后把',
    '       「登录名 / 角色串」写进会话变量（后续菜单过滤和 /p/ 鉴权都读它）；',
    '    2. 改文案：标题写演示账号与口令。口令引用 LWAuthDemoPass 常量而不是',
    '       再抄一遍字面量 —— 之前把口令写死在文案里，账号表换了之后忘了同步，',
    '       照着窗体上的提示输反而登不进去（这种错只有真人去点才会发现）；',
    '    3. 验证码保持开启，只给自动化留一个显式开关（--no-captcha 或',
    '       LW_LOGIN_NO_CAPTCHA=1）。普通启动永远是开着的，不会因为',
    '       「忘了接事件」而静默失效。',
    '}',
    '{$mode objfpc}{$H+}',
    '',
    'interface',
    '',
    'uses',
    '  Classes, SysUtils, Forms, Controls, StdCtrls, Graphics, lwbase, lwform,',
    '  lwlogin, lwrlog, upluginauth;',
    '',
    'type',
    '  TLoginForm = class(TLWLoginForm)',
    '  private',
    '    procedure DoAuth(Sender: TObject; const AUser, APass: string;',
    '      var AOk: Boolean; var AErr: string);',
    '    procedure ApplyCaptchaMode;',
    '    procedure AddCaptchaHint;',
    '  public',
    '    procedure AfterConstruction; override;',
    '  end;',
    '',
    '{ 是否显式关闭验证码。只认两种开关：',
    '    宿主命令行  --no-captcha',
    '    环境变量    LW_LOGIN_NO_CAPTCHA=1 / true / yes',
    '  默认（双击、普通命令行启动）返回 False，即验证码开启。 }',
    'function LoginCaptchaDisabled: Boolean;',
    '',
    'implementation',
    '',
    'function LoginCaptchaDisabled: Boolean;',
    'var',
    '  s: string;',
    'begin',
    '  if Application.HasOption(''no-captcha'') then',
    '    Exit(True);',
    '  { Windows 单元里也有个同名 3 参版本的 GetEnvironmentVariable，会盖掉',
    '    SysUtils 的 1 参版本，所以这里写全限定名 }',
    '  s := SysUtils.GetEnvironmentVariable(''LW_LOGIN_NO_CAPTCHA'');',
    '  Result := (s = ''1'') or SameText(s, ''true'') or SameText(s, ''yes'');',
    'end;',
    '',
    '{ AutoBuildUI 在 AfterConstruction 里跑（此时 lfm/OnCreate 都已结束），',
    '  所以改文案、补提示必须在 inherited 之后做 }',
    'procedure TLoginForm.AfterConstruction;',
    'var',
    '  c: TComponent;',
    'begin',
    '  inherited AfterConstruction;',
    '  Caption := ''插件工作台 · 登录'';',
    '',
    '  c := FindComponent(''lblTitle'');',
    '  if c is TLabel then',
    '    TLabel(c).Caption := ''演示账号 admin / analyst / guest，口令 '' + LWAuthDemoPass;',
    '',
    '  ApplyCaptchaMode;',
    '  if not LoginCaptchaDisabled then',
    '    AddCaptchaHint;',
    '',
    '  OnLogin := @DoAuth;',
    'end;',
    '',
    '{ 自动界面的坐标：标题 y=18、用户名 y=62，中间那条空隙只有 20px 上下 ——',
    '  提示放进去会和"用户名"行挤在一起（实测会压到输入框上沿），所以放到',
    '  按钮下面的留白处当脚注，用灰色小字，不抢视线。',
    '  内容上仍要说明"图能点"，否则没人会想到点它换一张（基类只在失败时自动换） }',
    'procedure TLoginForm.AddCaptchaHint;',
    'var',
    '  l: TLabel;',
    'begin',
    '  l := TLabel.Create(Self);',
    '  { 先 Name 后 Caption：SetName 会把名字回填到文本上 }',
    '  l.Name := ''lblCaptchaHint'';',
    '  l.Parent := Self;',
    '  l.SetBounds(24, 238, 340, 16);',
    '  l.Caption := ''验证码不区分大小写，看不清可点图片换一张'';',
    '  l.Font.Color := clGray;',
    'end;',
    '',
    'procedure TLoginForm.ApplyCaptchaMode;',
    'var',
    '  c: TComponent;',
    'begin',
    '  if not LoginCaptchaDisabled then',
    '  begin',
    '    { 基类初值就是 True，这里显式写一次：表明验证码是「有意开着」的，',
    '      将来基类改默认值时不会悄悄把这道门弄丢 }',
    '    RequireCaptcha := True;',
    '    LWLogFmt(''[%TAG%] 登录验证码：开启'', []);',
    '    Exit;',
    '  end;',
    '',
    '  { 关的时候是三重开关，少一个都进不去：',
    '    1) RequireCaptcha=False 才是"不校验"；',
    '    2) 藏掉输入框 —— 否则用户以为必须填；',
    '    3) 藏掉图片本身。',
    '    只做 2、3 而不做 1 的话，基类仍会拿空输入去比对，永远提示"验证码错误" }',
    '  RequireCaptcha := False;',
    '  LWLogFmt(''[%TAG%] 登录验证码：关闭（--no-captcha / LW_LOGIN_NO_CAPTCHA）'', []);',
    '  c := FindComponent(''lblCode'');',
    '  if c is TControl then TControl(c).Visible := False;',
    '  c := FindComponent(''captcha1'');',
    '  if c is TControl then TControl(c).Visible := False;',
    '  c := FindComponent(''edCode'');',
    '  if c is TControl then TControl(c).Visible := False;',
    'end;',
    '',
    'procedure TLoginForm.DoAuth(Sender: TObject; const AUser, APass: string;',
    '  var AOk: Boolean; var AErr: string);',
    'var',
    '  roles, disp: string;',
    'begin',
    '  AOk := LWAuthLogin(AUser, APass, roles, disp, AErr);',
    '  if not AOk then',
    '  begin',
    '    { 错误提示里带点线索，省得演示时反复试密码 }',
    '    if AErr = '''' then',
    '      AErr := ''用户名或密码错误'';',
    '    Exit;',
    '  end;',
    '  { 写会话变量：菜单过滤（LWAuthSessionRoles）和 /p/ 鉴权（LWAuthRolesForSid）',
    '    都从这里取。写全局变量会把 A 用户的身份带给同一进程里的 B 用户 }',
    '  LWAuthSessionSet(Trim(AUser), roles);',
    '  LWLogFmt(''[%TAG%] 登录成功 user=%s roles=%s'', [Trim(AUser), roles]);',
    'end;',
    '',
    'end.'
  );

  cHostUnitLines: array[0..586] of string = (
    'unit umain;',
    '{ %TAG% :: 宿主（主程序 exe）',
    '',
    '  左边是 TLWSideMenu（框架的 LCL 侧栏菜单组件），右边是 TPageControl。',
    '  菜单项不是写死的 —— 由插件清单扫描结果动态生成：一个 *.plugin.ini 一项，',
    '  标题取 title、分组取 group。group 用 / 表示层级，所以可以生成多级菜单：',
    '',
    '      业务管理              <- 清单 group=业务管理',
    '        仪表盘              <- 清单 group=业务管理',
    '        报表汇总            <- 清单 group=业务管理',
    '      系统管理              <- 清单 group=系统管理/数据维护 的第一段',
    '        数据维护            <- 第二段',
    '          便签              <- title',
    '',
    '  点菜单 -> 在 PageControl 上新增一个 TTabSheet，页内放 TLWHTMLFrame，',
    '  里面是一个指向 /p/<插件名>/ 的 iframe —— 插件本身是独立 exe、独立端口，',
    '  由宿主用 lwroute 反向代理，所以页里显示的是插件进程真正的页面，',
    '  业务处理也全部发生在插件进程内。',
    '',
    '  热更新：插件 exe 跑的是 plugins\.run 下的副本，原始 exe 随时可以重编。',
    '  重编后点菜单（或「热更新当前插件」），宿主停旧进程 -> 复制新 exe ->',
    '  起新进程 -> 页内 iframe 换 URL 重新加载，宿主自己不重启。',
    '',
    '  「重新扫描插件」：不重启宿主也能让菜单跟着磁盘变 —— 新增插件目录并放好',
    '  清单/exe，点一下就注册路由、拉起进程、菜单多出一项；删掉目录再点一下，',
    '  菜单项消失、页签关闭、进程停掉、路由摘除。',
    '}',
    '{$mode objfpc}{$H+}',
    '',
    'interface',
    '',
    'uses',
    '  Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls, ExtCtrls, Menus, Graphics,',
    '  lwbase, lwform, lwapp, lwweb, lwsidemenu, lwlogin, lwsession, upluginproc,',
    '  upluginauth;',
    '',
    'type',
    '  TMainForm = class(TLWForm)',
    '    pnlTop: TPanel;',
    '    lblTitle: TLabel;',
    '    btnRescan: TButton;',
    '    btnHot: TButton;',
    '    lblHot: TLabel;',
    '    lblUser: TLabel;',
    '    btnUser: TButton;',
    '    pcMain: TPageControl;',
    '    sbMain: TStatusBar;',
    '    smMain: TLWSideMenu;',
    '    procedure FormCreate(Sender: TObject);',
    '    procedure FormShow(Sender: TObject);',
    '    procedure pcMainChange(Sender: TObject);',
    '    procedure btnHotClick(Sender: TObject);',
    '    procedure btnRescanClick(Sender: TObject);',
    '    procedure btnUserClick(Sender: TObject);',
    '    procedure MenuItemClick(Sender: TObject);',
    '  private',
    '    FTabs: TStringList;      { 插件名 -> TTabSheet（重扫描后下标会变，按名找页） }',
    '    FActiveName: string;     { 当前高亮的插件路由名 }',
    '    FMenuUser: string;       { 建菜单时的登录名：用户变了要按新角色重算 }',
    '    procedure BuildMenu;',
    '    procedure SyncChecked;',
    '    procedure LoadMenuIcon(MI: TMenuItem; const AFile: string);',
    '    procedure OpenPlugin(AIndex: Integer);',
    '    function TabOfName(const AName: string): TTabSheet;',
    '    function IframeHTML(AIndex: Integer): string;',
    '    procedure ReloadTab(AIndex: Integer);',
    '    procedure RefreshTabs;',
    '    procedure UpdateHotLabel;',
    '    procedure UpdateUserLabel;',
    '    procedure OpenFirstAllowed;',
    '    procedure SetStatus(const AText: string);',
    '  public',
    '    destructor Destroy; override;',
    '  end;',
    '',
    'implementation',
    '',
    '{$R *.lfm}',
    '',
    'destructor TMainForm.Destroy;',
    'begin',
    '  FreeAndNil(FTabs);',
    '  inherited Destroy;',
    'end;',
    '',
    'procedure TMainForm.FormCreate(Sender: TObject);',
    'begin',
    '  if FTabs = nil then',
    '    FTabs := TStringList.Create;',
    '  FActiveName := '''';',
    '',
    '  { 菜单完全由扫描结果生成：换插件目录不用改这里一行代码。',
    '    但只列当前登录账号有权限的插件（判定统一在 upluginauth.LWAuthCanOpen）}',
    '  BuildMenu;',
    '  UpdateHotLabel;',
    '  UpdateUserLabel;',
    '',
    '  if PlugCount = 0 then',
    '  begin',
    '    SetStatus(''没有发现任何插件：检查 %NAME%\plugins\*\*.plugin.ini'');',
    '    Exit;',
    '  end;',
    '  { 默认打开第一个「有权限」的插件：既避免首页空白，也不至于一进来就 403 }',
    '  OpenFirstAllowed;',
    'end;',
    '',
    '{ 注销后换个账号重新登录，框架会复用同一个主窗体实例（不走 FormCreate），',
    '  身份变了就必须按新角色重建菜单、关掉越权页签 —— 否则 guest 登录进来',
    '  看到的还是上一个 admin 的菜单 }',
    'procedure TMainForm.FormShow(Sender: TObject);',
    'var',
    '  idx: Integer;',
    'begin',
    '  if LWAuthSessionUser <> FMenuUser then',
    '  begin',
    '    UpdateUserLabel;',
    '    BuildMenu;',
    '    RefreshTabs;',
    '    UpdateHotLabel;',
    '    idx := PlugIndexOf(FActiveName);',
    '    if (idx < 0) or (not LWAuthCanOpen(LWAuthSessionRoles, PlugGet(idx).Roles)) then',
    '      OpenFirstAllowed;',
    '  end;',
    'end;',
    '',
    '{ 打开第一个当前账号能打开的插件；一个都没有就只在状态栏说明 }',
    'procedure TMainForm.OpenFirstAllowed;',
    'var',
    '  i: Integer;',
    'begin',
    '  for i := 0 to PlugCount - 1 do',
    '    if LWAuthCanOpen(LWAuthSessionRoles, PlugGet(i).Roles) then',
    '    begin',
    '      OpenPlugin(i);',
    '      Exit;',
    '    end;',
    '  SetStatus(''当前账号「'' + LWAuthSessionUser + ''」没有任何插件的访问权限'');',
    'end;',
    '',
    '{ ---------------- 侧栏菜单（TLWSideMenu，运行期按扫描结果建树） ----------------',
    '',
    '  顶层项 = 可折叠分组（Group），叶子项 = 插件，点击回发 OnClick。',
    '  重扫描后整棵树重建：writer 每次序列化窗口都会把菜单树重新下发，',
    '  前端发现签名变了就整块重渲，所以菜单能跟着磁盘变。 }',
    '',
    'procedure TMainForm.BuildMenu;',
    'var',
    '  i, k, idx, shown: Integer;',
    '  p: TPlugPlugin;',
    '  grp, mi: TMenuItem;',
    '  gpath, seg, key, parentKey, roles: string;',
    '  segs, map: TStringList;',
    'begin',
    '  smMain.Items.Clear;',
    '  { 当前身份：菜单是会话级的（每个会话一棵 LCL 窗体树），所以这里读的是',
    '    本会话的角色，不会串到别的浏览器/别的账号 }',
    '  FMenuUser := LWAuthSessionUser;',
    '  roles := LWAuthSessionRoles;',
    '  shown := 0;',
    '',
    '  { map：分组路径 -> TMenuItem。同一次建树里复用，避免逐项遍历查找；',
    '    清单里 group=数据看板/运营分析 这样写就生成两级分组，任意层级都行 }',
    '  map := TStringList.Create;',
    '  segs := TStringList.Create;',
    '  segs.Delimiter := ''/'';',
    '  segs.StrictDelimiter := True;',
    '  try',
    '    map.CaseSensitive := False;',
    '    for i := 0 to PlugCount - 1 do',
    '    begin',
    '      p := PlugGet(i);',
    '      if p = nil then Continue;',
    '',
    '      { 权限过滤：没权限的插件根本不进菜单。',
    '        注意这只是"别让界面骗人"——真正拦住手敲 /p/报表/ 的是路由层的',
    '        LWAuthGuard（common\upluginauth.pas），两层都要有 }',
    '      if not LWAuthCanOpen(roles, p.Roles) then Continue;',
    '',
    '      grp := nil;',
    '      gpath := Trim(p.Group);',
    '      if gpath = '''' then',
    '        gpath := ''插件'';               { 清单没写 group：归入默认分组 }',
    '      if gpath = ''-'' then',
    '        gpath := '''';                   { group=- ：插件直接作为顶层菜单行 }',
    '',
    '      if gpath <> '''' then',
    '      begin',
    '        parentKey := '''';',
    '        segs.DelimitedText := gpath;',
    '        for k := 0 to segs.Count - 1 do',
    '        begin',
    '          seg := Trim(segs[k]);',
    '          if seg = '''' then Continue;',
    '          if parentKey = '''' then',
    '            key := seg',
    '          else',
    '            key := parentKey + ''/'' + seg;',
    '',
    '          idx := map.IndexOf(key);',
    '          if idx >= 0 then',
    '            grp := TMenuItem(map.Objects[idx])',
    '          else',
    '          begin',
    '            grp := TMenuItem.Create(smMain);',
    '            grp.Caption := seg;',
    '            if parentKey = '''' then',
    '              smMain.Items.Add(grp)',
    '            else',
    '              TMenuItem(map.Objects[map.IndexOf(parentKey)]).Add(grp);',
    '            map.AddObject(key, grp);',
    '          end;',
    '          parentKey := key;',
    '        end;',
    '      end;',
    '',
    '      mi := TMenuItem.Create(smMain);',
    '      mi.Caption := p.Title;',
    '      mi.Tag := i;                     { 下标 -> 插件，重扫描后由 RefreshTabs 修正页签 }',
    '      mi.OnClick := @MenuItemClick;',
    '      LoadMenuIcon(mi, p.Icon);',
    '      if grp <> nil then',
    '        grp.Add(mi)',
    '      else',
    '        smMain.Items.Add(mi);',
    '      Inc(shown);',
    '    end;',
    '  finally',
    '    segs.Free;',
    '    map.Free;',
    '  end;',
    '',
    '  { 有插件被权限隐藏时把"共几个"也写出来：演示/排障时一眼能看出',
    '    是"没扫描到"还是"扫到了但当前账号无权" }',
    '  if shown < PlugCount then',
    '    smMain.HeaderCaption := Format(''插件导航（%d / 共 %d）'', [shown, PlugCount])',
    '  else',
    '    smMain.HeaderCaption := Format(''插件导航（%d）'', [shown]);',
    '  SyncChecked;',
    'end;',
    '',
    '{ 菜单图标：清单 icon= 指到文件就读进 TMenuItem.Bitmap，',
    '  writer 会把它转成 PNG data URI 下发（没有图标时前端留占位块保证对齐） }',
    'procedure TMainForm.LoadMenuIcon(MI: TMenuItem; const AFile: string);',
    'begin',
    '  if (MI = nil) or (AFile = '''') or (not FileExists(AFile)) then Exit;',
    '  try',
    '    MI.Bitmap.LoadFromFile(AFile);',
    '  except',
    '    { nogui 下个别格式导不出：没图标也不影响菜单结构和点击 }',
    '  end;',
    'end;',
    '',
    '{ 菜单项的 Checked 就是浏览器侧栏的高亮状态（writer 把它序列化过去）}',
    'procedure TMainForm.SyncChecked;',
    '',
    '  procedure Walk(MI: TMenuItem; AActive: Integer);',
    '  var',
    '    i: Integer;',
    '  begin',
    '    for i := 0 to MI.Count - 1 do',
    '      if MI.Items[i].Count > 0 then',
    '        Walk(MI.Items[i], AActive)',
    '      else',
    '        MI.Items[i].Checked := (AActive >= 0) and (MI.Items[i].Tag = AActive);',
    '  end;',
    '',
    'var',
    '  idx: Integer;',
    'begin',
    '  idx := PlugIndexOf(FActiveName);',
    '  Walk(smMain.Items, idx);',
    'end;',
    '',
    'procedure TMainForm.MenuItemClick(Sender: TObject);',
    'begin',
    '  if Sender is TMenuItem then',
    '    OpenPlugin(TMenuItem(Sender).Tag);',
    'end;',
    '',
    '{ ---------------- 页签 ---------------- }',
    '',
    'function TMainForm.TabOfName(const AName: string): TTabSheet;',
    'var',
    '  i: Integer;',
    'begin',
    '  Result := nil;',
    '  if (FTabs = nil) or (AName = '''') then Exit;',
    '  i := FTabs.IndexOf(AName);',
    '  if i >= 0 then',
    '    Result := TTabSheet(FTabs.Objects[i]);',
    'end;',
    '',
    'procedure TMainForm.OpenPlugin(AIndex: Integer);',
    'var',
    '  p: TPlugPlugin;',
    '  ts: TTabSheet;',
    '  didHot: Boolean;',
    'begin',
    '  p := PlugGet(AIndex);',
    '  if p = nil then Exit;',
    '',
    '  { UI 层二次校验：菜单已经过滤过，但 Tag 可能来自重建前的旧菜单、或',
    '    重扫描后下标被复用。这里挡住是体验问题（给句人话），越权请求本身',
    '    由路由层 403 兜底 —— 两层判定用同一个 LWAuthCanOpen }',
    '  if not LWAuthCanOpen(LWAuthSessionRoles, p.Roles) then',
    '  begin',
    '    SetStatus(''没有权限打开「'' + p.Title + ''」：当前角色 '' +',
    '      LWAuthRoleText(LWAuthSessionRoles) + ''，本插件需要 '' + LWAuthNeedText(p.Roles));',
    '    Exit;',
    '  end;',
    '',
    '  { 插件 exe 在启动后被重新编译过：先热更新，再打开 }',
    '  didHot := False;',
    '  if PlugSourceChanged(AIndex) then',
    '  begin',
    '    if PlugHotUpdate(AIndex) then',
    '      didHot := True',
    '    else',
    '      SetStatus(''热更新失败：「'' + p.Title + ''」继续使用旧进程'');',
    '  end;',
    '',
    '  ts := TabOfName(p.Name);',
    '  if ts <> nil then',
    '  begin',
    '    ts.Tag := AIndex;',
    '    ts.Caption := p.Title;',
    '    FActiveName := p.Name;',
    '    pcMain.ActivePage := ts;',
    '    SyncChecked;',
    '    if didHot then',
    '    begin',
    '      ReloadTab(AIndex);',
    '      SetStatus(Format(''已热更新「%s」并切回页签（pid=%d）'', [p.Title, p.Proc.ProcessID]));',
    '    end',
    '    else',
    '      SetStatus(''切换到已有页签：'' + p.Title + ''（同一插件只保留一页）'');',
    '    UpdateHotLabel;',
    '    Exit;',
    '  end;',
    '',
    '  ts := TTabSheet.Create(pcMain);',
    '  ts.PageControl := pcMain;',
    '  ts.Name := ''tsPlugin'' + p.Name;',
    '  ts.Caption := p.Title;',
    '  ts.Tag := AIndex;',
    '  { nogui 下运行期新建的 TTabSheet 没有窗口句柄，LCL 不会替它算客户区，',
    '    序列化出去就是 0x0；浏览器端虽然有 align=client 的二次拉伸，这里还是',
    '    显式给一个接近页签客户区的盒子作双保险（28 ≈ 页签条高度） }',
    '  if ts.Width <= 0 then',
    '    ts.Width := pcMain.Width;',
    '  if ts.Height <= 0 then',
    '    ts.Height := pcMain.Height - 28;',
    '',
    '  with TLWHTMLFrame.Create(ts) do',
    '  begin',
    '    Name := ''hfPlugin'' + p.Name;',
    '    Parent := ts;',
    '    Align := alClient;',
    '    SetBounds(0, 0, ts.Width, ts.Height);',
    '    BevelOuter := bvNone;',
    '    BorderStyle := bsNone;',
    '    HTML.Text := IframeHTML(AIndex);',
    '  end;',
    '',
    '  FTabs.AddObject(p.Name, ts);',
    '  FActiveName := p.Name;',
    '  pcMain.ActivePage := ts;',
    '  SyncChecked;',
    '',
    '  if didHot then',
    '    SetStatus(Format(''已热更新并打开「%s」：/p/%s/ -> 127.0.0.1:%d'',',
    '      [p.Title, p.Name, p.Port]))',
    '  else',
    '    SetStatus(Format(''已打开「%s」：页内 iframe -> /p/%s/（插件独立进程，端口 %d）'',',
    '      [p.Title, p.Name, p.Port]));',
    '  UpdateHotLabel;',
    'end;',
    '',
    'function TMainForm.IframeHTML(AIndex: Integer): string;',
    'var',
    '  p: TPlugPlugin;',
    '  S: TLWSessionBase;',
    '  sid: string;',
    'begin',
    '  p := PlugGet(AIndex);',
    '  if p = nil then Exit('''');',
    '  { iframe 的首次导航必须自己带上 sid：浏览器发这个请求时不会带宿主的',
    '    ?sid=（那是前端 JS 在 /lw/api/* 上用的），而 /p/ 路由要按会话鉴权。',
    '    放行后 lwroute 会把它落到 Path=/p/ 的 lwpsid cookie 上，之后的子资源',
    '    请求就自动带 cookie 了，不需要在插件页面里再做手脚。 }',
    '  sid := '''';',
    '  S := LWCurrentSession;',
    '  if S is TLWSession then',
    '    sid := TLWSession(S).Sid;',
    '  Result := ''<iframe src="'' + PlugFrameURL(AIndex);',
    '  if sid <> '''' then',
    '    Result := Result + ''&sid='' + sid;',
    '  Result := Result + ''" '' +',
    '    ''style="display:block;width:100%;height:100%;border:0;background:#ffffff" '' +',
    '    ''title="'' + p.Title + ''"></iframe>'';',
    'end;',
    '',
    'procedure TMainForm.ReloadTab(AIndex: Integer);',
    'var',
    '  p: TPlugPlugin;',
    '  ts: TTabSheet;',
    '  c: TComponent;',
    'begin',
    '  p := PlugGet(AIndex);',
    '  if p = nil then Exit;',
    '  ts := TabOfName(p.Name);',
    '  if ts = nil then Exit;',
    '  c := ts.FindComponent(''hfPlugin'' + p.Name);',
    '  if c is TLWHTMLFrame then',
    '  begin',
    '    { 换掉 iframe 的 src（版本号变了 = 重新建 iframe 元素），',
    '      插件进程重启后的新页面才会真正加载 }',
    '    TLWHTMLFrame(c).HTML.Text := IframeHTML(AIndex);',
    '  end;',
    'end;',
    '',
    '{ 重扫描之后：已有页签按插件名重新对上新的下标；插件没了的页签关掉 }',
    'procedure TMainForm.RefreshTabs;',
    'var',
    '  i, idx: Integer;',
    '  ts: TTabSheet;',
    '  p: TPlugPlugin;',
    'begin',
    '  if FTabs = nil then Exit;',
    '  for i := FTabs.Count - 1 downto 0 do',
    '  begin',
    '    ts := TTabSheet(FTabs.Objects[i]);',
    '    idx := PlugIndexOf(FTabs[i]);',
    '    { 插件没了，或者当前账号已无权访问（换了账号 / 清单改了 roles）：',
    '      页签一并关掉 —— 旧页签里的 iframe 还连着插件进程，留着就能继续用 }',
    '    if (idx >= 0) and (not LWAuthCanOpen(LWAuthSessionRoles, PlugGet(idx).Roles)) then',
    '      idx := -1;',
    '    if idx < 0 then',
    '    begin',
    '      if pcMain.ActivePage = ts then',
    '        pcMain.ActivePage := nil;',
    '      FTabs.Delete(i);',
    '      ts.Free;',
    '      Continue;',
    '    end;',
    '    p := PlugGet(idx);',
    '    ts.Tag := idx;',
    '    ts.Caption := p.Title;',
    '  end;',
    '',
    '  { 页签被关掉（插件消失或身份变了）后别再把高亮指向它 }',
    '  if TabOfName(FActiveName) = nil then',
    '    FActiveName := '''';',
    '  SyncChecked;',
    'end;',
    '',
    '{ ---------------- 按钮 ---------------- }',
    '',
    'procedure TMainForm.btnHotClick(Sender: TObject);',
    'var',
    '  i: Integer;',
    '  p: TPlugPlugin;',
    'begin',
    '  if FActiveName = '''' then',
    '  begin',
    '    SetStatus(''先在左侧点一个插件，让它出现在页签里，再热更新'');',
    '    Exit;',
    '  end;',
    '  i := PlugIndexOf(FActiveName);',
    '  p := PlugGet(i);',
    '  if p = nil then Exit;',
    '',
    '  SetStatus(''正在热更新「'' + p.Title + ''」：停旧进程、换新 exe、重新拉起…'');',
    '  if PlugHotUpdate(i) then',
    '  begin',
    '    ReloadTab(i);',
    '    SetStatus(Format(''已热更新「%s」：新进程 pid=%d，页内 iframe 已重新加载'',',
    '      [p.Title, p.Proc.ProcessID]));',
    '  end',
    '  else',
    '    SetStatus(''热更新失败：「'' + p.Title + ''」未启动（检查 exe 与 .run 目录）'');',
    '  UpdateHotLabel;',
    'end;',
    '',
    'procedure TMainForm.btnRescanClick(Sender: TObject);',
    'var',
    '  before, after: Integer;',
    'begin',
    '  before := PlugCount;',
    '  SetStatus(''正在重新扫描插件目录…'');',
    '  after := PlugRescan;',
    '',
    '  { 扫描结果变了：菜单重建、页签重挂下标、插件 exe 状态重算 }',
    '  BuildMenu;',
    '  RefreshTabs;',
    '  UpdateHotLabel;',
    '',
    '  if after = 0 then',
    '    SetStatus(''重新扫描完成：没有发现任何插件（检查 %NAME%\plugins\*\*.plugin.ini）'')',
    '  else if after > before then',
    '    SetStatus(Format(''重新扫描完成：新增 %d 个插件，共 %d 个，左侧菜单已更新'',',
    '      [after - before, after]))',
    '  else if after < before then',
    '    SetStatus(Format(''重新扫描完成：移除 %d 个插件，共 %d 个，左侧菜单已更新'',',
    '      [before - after, after]))',
    '  else',
    '    SetStatus(Format(''重新扫描完成：共 %d 个插件，菜单已按清单刷新'', [after]));',
    'end;',
    '',
    'procedure TMainForm.pcMainChange(Sender: TObject);',
    'var',
    '  ts: TTabSheet;',
    '  p: TPlugPlugin;',
    'begin',
    '  ts := pcMain.ActivePage;',
    '  if ts = nil then Exit;',
    '  { 运行期新建页签时 LCL 会先触发 OnChange（此刻还没登记进 FTabs），跳过 }',
    '  if (FTabs = nil) or (FTabs.IndexOfObject(ts) < 0) then Exit;',
    '  p := PlugGet(ts.Tag);',
    '  if p = nil then Exit;',
    '',
    '  FActiveName := p.Name;',
    '  SyncChecked;',
    '  if PlugSourceChanged(ts.Tag) then',
    '    SetStatus(''当前页：'' + ts.Caption + ''（检测到该插件已重编，可点「热更新当前插件」）'')',
    '  else',
    '    SetStatus(''当前页：'' + ts.Caption + ''（独立进程，端口 '' + IntToStr(p.Port) + ''）'');',
    'end;',
    '',
    'procedure TMainForm.UpdateHotLabel;',
    'var',
    '  n: Integer;',
    'begin',
    '  n := PlugChangedCount;',
    '  if n > 0 then',
    '    lblHot.Caption := ''检测到 '' + IntToStr(n) + '' 个插件已重编，可热更新''',
    '  else',
    '    lblHot.Caption := ''插件 exe 未变化'';',
    'end;',
    '',
    'procedure TMainForm.SetStatus(const AText: string);',
    'begin',
    '  sbMain.Panels[0].Text := AText;',
    'end;',
    '',
    '{ 顶栏身份：用户名（中文名）· 角色。角色直接决定菜单里能看到几项 }',
    'procedure TMainForm.UpdateUserLabel;',
    'var',
    '  u, r: string;',
    'begin',
    '  u := LWAuthSessionUser;',
    '  r := LWAuthSessionRoles;',
    '  if u = '''' then',
    '    lblUser.Caption := ''未登录''',
    '  else if r = '''' then',
    '    lblUser.Caption := u + '' · 无角色''',
    '  else',
    '    lblUser.Caption := u + ''（'' + LWAuthDisplayOf(u) + ''）· '' + LWAuthRoleText(r);',
    'end;',
    '',
    '{ 注销 / 切换用户：把会话退回未认证，再把登录窗体换回来。',
    '  这就是框架的注销路径（Authenticated=False + Hide/Show 窗体）——',
    '  lwdispatch 看到未认证会话只放行登录窗体上的控件，业务事件全部拒绝 }',
    'procedure TMainForm.btnUserClick(Sender: TObject);',
    'var',
    '  S: TLWSessionBase;',
    '  lf: TCustomForm;',
    'begin',
    '  S := LWCurrentSession;',
    '  if (S = nil) or (S.LoginForm = nil) then',
    '  begin',
    '    SetStatus(''当前会话没有登录窗体（未启用登录），无法切换用户'');',
    '    Exit;',
    '  end;',
    '  lf := S.LoginForm;',
    '  LWAuthSessionClear;',
    '  S.Authenticated := False;',
    '  { 清掉上一次输入的用户名/密码，别把上个账号的凭据留在页面上 }',
    '  if lf is TLWLoginForm then',
    '    TLWLoginForm(lf).DoReset(nil);',
    '  S.SessionHideForm(Self);',
    '  S.SessionShowForm(lf);',
    '  FMenuUser := '''';      { 下次 FormShow 一定按新身份重建菜单 }',
    '  SetStatus(''已注销：请用另一个账号登录（admin / analyst / guest，口令 '' + LWAuthDemoPass + ''）'');',
    'end;',
    '',
    'end.'
  );

  cHostLfmLines: array[0..97] of string = (
    'object MainForm: TMainForm',
    '  Left = 160',
    '  Top = 80',
    '  Width = 1180',
    '  Height = 760',
    '  Caption = ''%TITLE%''',
    '  ClientHeight = 760',
    '  ClientWidth = 1180',
    '  OnCreate = FormCreate',
    '  OnShow = FormShow',
    '  object pnlTop: TPanel',
    '    Left = 0',
    '    Top = 0',
    '    Width = 1180',
    '    Height = 56',
    '    Align = alTop',
    '    BevelOuter = bvNone',
    '    TabOrder = 0',
    '    object lblTitle: TLabel',
    '      Left = 16',
    '      Top = 16',
    '      Width = 336',
    '      Height = 26',
    '      Caption = ''插件工作台 —— 主程序 exe + 插件 exe''',
    '      Font.Height = -16',
    '      Font.Style = [fsBold]',
    '      ParentFont = False',
    '    end',
    '    object btnRescan: TButton',
    '      Left = 360',
    '      Top = 11',
    '      Width = 130',
    '      Height = 34',
    '      Caption = ''重新扫描插件''',
    '      TabOrder = 0',
    '      OnClick = btnRescanClick',
    '    end',
    '    object btnHot: TButton',
    '      Left = 500',
    '      Top = 11',
    '      Width = 140',
    '      Height = 34',
    '      Caption = ''热更新当前插件''',
    '      TabOrder = 1',
    '      OnClick = btnHotClick',
    '    end',
    '    object lblHot: TLabel',
    '      Left = 654',
    '      Top = 19',
    '      Width = 200',
    '      Height = 22',
    '      Caption = ''插件 exe 未变化''',
    '    end',
    '    object lblUser: TLabel',
    '      Left = 866',
    '      Top = 19',
    '      Width = 200',
    '      Height = 22',
    '      Caption = ''未登录''',
    '    end',
    '    object btnUser: TButton',
    '      Left = 1074',
    '      Top = 11',
    '      Width = 90',
    '      Height = 34',
    '      Caption = ''切换用户''',
    '      TabOrder = 2',
    '      OnClick = btnUserClick',
    '    end',
    '  end',
    '  object pcMain: TPageControl',
    '    Left = 0',
    '    Top = 56',
    '    Width = 1180',
    '    Height = 678',
    '    Align = alClient',
    '    TabOrder = 1',
    '    OnChange = pcMainChange',
    '  end',
    '  object sbMain: TStatusBar',
    '    Left = 0',
    '    Top = 734',
    '    Width = 1180',
    '    Height = 26',
    '    Panels = <',
    '      item',
    '        Width = 1000',
    '      end>',
    '    TabOrder = 2',
    '  end',
    '  object smMain: TLWSideMenu',
    '    SideWidth = 250',
    '    ItemHeight = 44',
    '    HeaderCaption = ''插件导航''',
    '    Left = 8',
    '    Top = 8',
    '  end',
    'end'
  );

  { 示例插件的 .pas / .lfm 原文。生成到 plugins\hello\ 下的那两个文件
    就是它们的落地版本 —— 复制整个目录改个名就是一个新插件。 }
  cSampleUnitLines: array[0..71] of string = (
    'unit uform_hello;',
    '{ %NAME%\plugins\hello :: 示例插件的页面（独立 exe）',
    '',
    '  这是插件进程自己的完整页面：没有宿主、没有别的插件。',
    '  宿主用 /p/hello/ 反向代理过来，浏览器里看到的就是这一页。',
    '',
    '  界面全在 uform_hello.lfm 里（可以像普通 LCL 窗体一样拖控件）；',
    '  事件在下面：FormCreate 取进程号，btnHelloClick 累加点击次数，',
    '  AfterConstruction 通过 common/upluginidentity.pas 读取宿主签发的身份。',
    '  进程号与身份都是故意显示的 —— 热更新后 pid 会变，直连插件端口时身份会变成"未识别"。',
    '}',
    '{$mode objfpc}{$H+}',
    '',
    'interface',
    '',
    'uses',
    '  Classes, SysUtils, Forms, Controls, StdCtrls, lwform, upluginidentity;',
    '',
    'type',
    '  THelloForm = class(TLWForm)',
    '    lblTitle: TLabel;',
    '    lblSub: TLabel;',
    '    lblIdentity: TLabel;',
    '    lblPidCap: TLabel;',
    '    lblPid: TLabel;',
    '    btnHello: TButton;',
    '    lblCount: TLabel;',
    '    memoLog: TMemo;',
    '    procedure FormCreate(Sender: TObject);',
    '    procedure btnHelloClick(Sender: TObject);',
    '  private',
    '    FCount: Integer;',
    '  public',
    '    procedure AfterConstruction; override;',
    '  end;',
    '',
    'var',
    '  HelloForm: THelloForm;',
    '',
    'implementation',
    '',
    '{$R *.lfm}',
    '',
    'procedure THelloForm.AfterConstruction;',
    'begin',
    '  inherited AfterConstruction;',
    '  { 宿主反代时写身份头，这里验签后才认；直连插件端口显示"未识别" }',
    '  lblIdentity.Caption := ''当前用户：'' + PlugIdentityDisplay;',
    'end;',
    '',
    'procedure THelloForm.FormCreate(Sender: TObject);',
    'begin',
    '  FCount := 0;',
    '  { 进程号：宿主热更新（停旧进程、起新进程）之后这里会变 }',
    '  lblPid.Caption := IntToStr(GetProcessID) + '' （plugins\hello\hello.exe）'';',
    '  lblCount.Caption := ''还没有点过'';',
    '  memoLog.Lines.Add(FormatDateTime(''hh:nn:ss'', Now) +',
    '    ''  插件进程启动，pid='' + IntToStr(GetProcessID) + ''，'' + PlugIdentityDisplay);',
    'end;',
    '',
    'procedure THelloForm.btnHelloClick(Sender: TObject);',
    'begin',
    '  { 这个事件跑在插件进程里 —— 宿主完全不知情，只负责把页面放进页签 }',
    '  Inc(FCount);',
    '  lblCount.Caption := ''已点 '' + IntToStr(FCount) +',
    '    '' 次（计数在插件进程的内存里，重启进程会归零）'';',
    '  memoLog.Lines.Add(FormatDateTime(''hh:nn:ss'', Now) +',
    '    ''  第 '' + IntToStr(FCount) + '' 次点击，'' + PlugIdentityDisplay +',
    '    ''，本进程 pid='' + IntToStr(GetProcessID));',
    'end;',
    '',
    'end.'
  );

  cSampleLfmLines: array[0..73] of string = (
    'object HelloForm: THelloForm',
    '  Left = 240',
    '  Top = 120',
    '  Width = 720',
    '  Height = 460',
    '  Caption = ''示例插件（独立插件进程）''',
    '  ClientHeight = 460',
    '  ClientWidth = 720',
    '  OnCreate = FormCreate',
    '  object lblTitle: TLabel',
    '    Left = 20',
    '    Top = 18',
    '    Width = 420',
    '    Height = 26',
    '    Caption = ''示例插件 — 独立插件进程（exe + lfm）''',
    '    Font.Height = -16',
    '    Font.Style = [fsBold]',
    '    ParentFont = False',
    '  end',
    '  object lblSub: TLabel',
    '    Left = 20',
    '    Top = 46',
    '    Width = 660',
    '    Height = 18',
    '    Caption = ''本页由 plugins\hello\hello.exe 自己渲染，宿主只负责页签与 /p/hello/ 代理。''',
    '  end',
    '  object lblIdentity: TLabel',
    '    Left = 20',
    '    Top = 70',
    '    Width = 660',
    '    Height = 18',
    '    Caption = ''当前用户：未识别（请从主程序进入）''',
    '    Font.Color = clNavy',
    '    ParentFont = False',
    '  end',
    '  object lblPidCap: TLabel',
    '    Left = 20',
    '    Top = 98',
    '    Width = 120',
    '    Height = 18',
    '    Caption = ''插件进程 pid''',
    '  end',
    '  object lblPid: TLabel',
    '    Left = 126',
    '    Top = 98',
    '    Width = 520',
    '    Height = 18',
    '    Caption = ''-''',
    '  end',
    '  object btnHello: TButton',
    '    Left = 20',
    '    Top = 128',
    '    Width = 150',
    '    Height = 34',
    '    Caption = ''打个招呼''',
    '    TabOrder = 0',
    '    OnClick = btnHelloClick',
    '  end',
    '  object lblCount: TLabel',
    '    Left = 186',
    '    Top = 138',
    '    Width = 500',
    '    Height = 18',
    '    Caption = ''还没有点过''',
    '  end',
    '  object memoLog: TMemo',
    '    Left = 20',
    '    Top = 180',
    '    Width = 680',
    '    Height = 250',
    '    ScrollBars = ssAutoVertical',
    '    TabOrder = 1',
    '  end',
    'end'
  );

{ 按行数组拼成文本；用 LineEnding 而不是写死 #13#10 —— 与 lwnewproject
  生成的其它文件保持同一换行风格（Windows 上就是 CRLF）。 }
function LinesText(const ALines: array of string): string;
var
  i: Integer;
begin
  Result := '';
  for i := Low(ALines) to High(ALines) do
  begin
    Result := Result + ALines[i];
    if i < High(ALines) then
      Result := Result + LineEnding;
  end;
end;

function StrReplaceAll(const AText, AFrom, ATo: string): string;
begin
  if AFrom = '' then
    Result := AText
  else
    Result := StringReplace(AText, AFrom, ATo, [rfReplaceAll]);
end;

{ 模板里的三处占位统一在这里替换 }
function ExpandTemplate(const AText: string; const O: TLWNewProject): string;
begin
  Result := StrReplaceAll(AText, '%TAG%', O.Name);
  Result := StrReplaceAll(Result, '%TITLE%', O.Title);
  Result := StrReplaceAll(Result, '%NAME%', O.Name);
end;

{ 示例插件的窗体单元名 / 类名 / 注册名 }
function SampleUnitName: string;
begin
  Result := 'uform_' + sLWPluginSampleName;
end;

function LWPluginSamplePort(const O: TLWNewProject): Integer;
begin
  Result := O.Port + 1;
end;

function LWPluginCommonSource(const O: TLWNewProject): string;
begin
  Result := ExpandTemplate(LinesText(cCommonLines), O);
end;

function LWPluginGuardSource(const O: TLWNewProject): string;
begin
  Result := ExpandTemplate(LinesText(cGuardLines), O);
end;

function LWPluginAuthSource(const O: TLWNewProject): string;
begin
  Result := ExpandTemplate(LinesText(cAuthLines), O);
end;

function LWPluginIdentitySource(const O: TLWNewProject): string;
begin
  Result := ExpandTemplate(LinesText(cIdentityLines), O);
end;

function LWPluginLoginSource(const O: TLWNewProject): string;
begin
  Result := ExpandTemplate(LinesText(cLoginLines), O);
end;

function LWPluginHostUnitSource(const O: TLWNewProject): string;
begin
  Result := ExpandTemplate(LinesText(cHostUnitLines), O);
  { 窗体名/类名跟着调用方给的 O.FormName 走。命令行固定是 MainForm，
    但 IDE 向导在"窗体名已被占用"时会给出 MainForm1 —— 那时 .lpr 里写的是
    TLWApp.Register(TMainForm1)，模板里的类名必须一起改，否则编不过。
    （这份窗体单元没有全局 var 段：窗体由 TLWApp.Register 创建，与
    demos/pluginsDemo 的宿主一致。） }
  if O.FormName <> 'MainForm' then
    Result := StrReplaceAll(Result, 'TMainForm', 'T' + O.FormName);
end;

function LWPluginHostResourceSource(const O: TLWNewProject): string;
begin
  Result := ExpandTemplate(LinesText(cHostLfmLines), O);
  { 同上：lfm 的根对象名与类名要跟窗体名一致 }
  if O.FormName <> 'MainForm' then
    Result := StrReplaceAll(Result, 'object MainForm: TMainForm',
      'object ' + O.FormName + ': T' + O.FormName);
end;

{ ---------------- 宿主 .lpr ---------------- }

function LWPluginHostSource(const O: TLWNewProject): string;
var
  apptype: string;
begin
  { 与常规模板同一套判据：nogui 档控制台、GUI 档 GUI 子系统，
    否则 GUI 工程会跟着弹一个黑窗口 }
  if O.Headless then
    apptype := '{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}'
  else
    apptype := '{$IFDEF MSWINDOWS}{$APPTYPE GUI}{$ENDIF}';

  Result :=
    'program ' + O.Name + ';' + LineEnding +
    '{ ' + O.Name + ' :: 插件框架的宿主（主程序 exe）' + LineEnding +
    LineEnding +
    '  宿主自己不实现任何业务：它只干三件事 ——' + LineEnding +
    '    1. 扫描 plugins\*\*.plugin.ini，按清单注册 /p/<插件名>/ 反向代理路由；' + LineEnding +
    '    2. 把每个插件 exe 复制到 plugins\.run\ 并拉起（独立进程、独立端口）；' + LineEnding +
    '    3. 左边 TLWSideMenu 按清单生成菜单，右边 TPageControl 按点击开页签。' + LineEnding +
    LineEnding +
    '  新增插件 = 建一个 plugins\<名>\ 目录（清单 + 插件工程），不用改本文件。' + LineEnding +
    '  插件热更新：改完插件源码重编 -> 宿主里点「热更新当前插件」。' + LineEnding +
    '  用户权限：模板默认带登录 + 角色鉴权 —— common\upluginauth.pas 判定 roles=' + LineEnding +
    '  （菜单过滤 / /p/ 403 / 身份签发），ulogin.pas 是登录窗体，插件侧用' + LineEnding +
    '  common\upluginidentity.pas 验签显示当前用户。不需要登录就把 SetLogin 与' + LineEnding +
    '  LWAuthRegister 两行删掉；只删菜单过滤、不删路由鉴权会留下越权访问。' + LineEnding +
    '}' + LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    apptype + LineEnding +
    LineEnding +
    'uses' + LineEnding +
    '  {$IFDEF UNIX}cthreads,{$ENDIF}' + LineEnding +
    '  Interfaces, Forms, lwapp, upluginproc, upluginauth, ulogin, umain;' + LineEnding +
    LineEnding +
    'begin' + LineEnding +
    '  Application.Initialize;' + LineEnding +
    '  Application.Title := ' + QuotedStr(O.Title) + ';' + LineEnding +
    '  { 类名去掉 T 就是浏览器里的窗体名（' + O.FormName + '） }' + LineEnding +
    '  TLWApp.Register(T' + O.FormName + ');' + LineEnding +
    '  { 两道门：1) 新会话先显示 ulogin（默认带图形验证码）；' + LineEnding +
    '    2) LWAuthRegister 把角色鉴权与身份签发挂到 /p/ 反代上。' + LineEnding +
    '    只做 1 的话菜单藏了但手敲 URL 照样能进 —— 2 才是真正的强制点。 }' + LineEnding +
    '  TLWApp.SetLogin(TLoginForm);' + LineEnding +
    '  LWAuthRegister;' + LineEnding +
    '  { 发现 -> 注册路由 -> 拉起进程，必须都在 TLWApp.Run 之前完成：' + LineEnding +
    '    Run 之后才注册的路由，第一次访问就会 502。 }' + LineEnding +
    '  PlugDiscover;' + LineEnding +
    '  PlugRegisterRoutes;' + LineEnding +
    '  PlugLaunchAll;' + LineEnding +
    '  TLWApp.Run;' + LineEnding +
    'end.' + LineEnding;
end;

{ ---------------- 宿主 .lpi ---------------- }

function LWPluginHostInfo(const O: TLWNewProject): string;
var
  s, others: string;
begin
  { 与 lwnewproject.LWProjectInfo 同构，差别只有 SearchPaths 里的
    OtherUnitFiles：common\ 是插件管理的源码目录，不列进 Units 也能编，
    但 IDE 的代码跳转要靠这条搜索路径。 }
  s :=
    '<?xml version="1.0" encoding="UTF-8"?>' + LineEnding +
    '<CONFIG>' + LineEnding +
    '  <ProjectOptions>' + LineEnding +
    '    <Version Value="12"/>' + LineEnding +
    '    <General>' + LineEnding +
    '      <Flags>' + LineEnding +
    '        <MainUnitHasCreateFormStatements Value="False"/>' + LineEnding +
    '        <MainUnitHasTitleStatement Value="False"/>' + LineEnding +
    '      </Flags>' + LineEnding +
    '      <SessionStorage Value="InProjectDir"/>' + LineEnding +
    '      <Title Value="' + O.Name + '"/>' + LineEnding +
    '      <UseAppBundle Value="False"/>' + LineEnding +
    '    </General>' + LineEnding;
  s := s + LWProjectMacroValuesXml(O);
  s := s +
    '    <BuildModes>' + LineEnding +
    LWProjectBuildModeItemXml(O) +
    LWProjectSharedMatrixXml(O) +
    '    </BuildModes>' + LineEnding +
    '    <PublishOptions>' + LineEnding +
    '      <Version Value="2"/>' + LineEnding +
    '    </PublishOptions>' + LineEnding +
    '    <RunParams>' + LineEnding +
    '      <FormatVersion Value="2"/>' + LineEnding +
    '    </RunParams>' + LineEnding +
    '    <RequiredPackages>' + LineEnding +
    '      <Item>' + LineEnding +
    '        <PackageName Value="LCL"/>' + LineEnding +
    '      </Item>' + LineEnding;
  if O.UnitPath = '' then
    s := s +
      '      <Item>' + LineEnding +
      '        <PackageName Value="lwserver"/>' + LineEnding +
      '      </Item>' + LineEnding;
  s := s +
    '    </RequiredPackages>' + LineEnding +
    '    <Units>' + LineEnding +
    '      <Unit>' + LineEnding +
    '        <Filename Value="' + O.Name + '.lpr"/>' + LineEnding +
    '        <IsPartOfProject Value="True"/>' + LineEnding +
    '      </Unit>' + LineEnding +
    '      <Unit>' + LineEnding +
    '        <Filename Value="' + O.UnitName + '.pas"/>' + LineEnding +
    '        <IsPartOfProject Value="True"/>' + LineEnding +
    '        <ComponentName Value="' + O.FormName + '"/>' + LineEnding +
    '        <HasResources Value="True"/>' + LineEnding +
    '        <ResourceBaseClass Value="Form"/>' + LineEnding +
    '      </Unit>' + LineEnding +
    '    </Units>' + LineEnding +
    '  </ProjectOptions>' + LineEnding +
    '  <CompilerOptions>' + LineEnding +
    '    <Version Value="11"/>' + LineEnding +
    '    <Target>' + LineEnding +
    '      <Filename Value="' + O.Name + '"/>' + LineEnding +
    '    </Target>' + LineEnding +
    '    <SearchPaths>' + LineEnding +
    '      <IncludeFiles Value="$(ProjOutDir)"/>' + LineEnding +
    '      <UnitOutputDirectory Value="lib\$(TargetCPU)-$(TargetOS)"/>' + LineEnding;

  { OtherUnitFiles：common\ 必写；带 --units 时再拼上框架源码目录 }
  others := sLWPluginCommonDir;
  if O.UnitPath <> '' then
    others := others + ';' + O.UnitPath;
  s := s +
    '      <OtherUnitFiles Value="' + others + '"/>' + LineEnding +
    '    </SearchPaths>' + LineEnding +
    '    <Linking>' + LineEnding +
    '      <Options>' + LineEnding +
    '        <Win32>' + LineEnding;
  if O.Headless then
    s := s + '          <GraphicApplication Value="False"/>' + LineEnding
  else
    s := s + '          <GraphicApplication Value="True"/>' + LineEnding;
  s := s +
    '        </Win32>' + LineEnding +
    '      </Options>' + LineEnding +
    '    </Linking>' + LineEnding +
    '  </CompilerOptions>' + LineEnding +
    '</CONFIG>' + LineEnding;
  Result := s;
end;

{ ---------------- 宿主主窗体（设计期占位） ---------------- }

function LWPluginHostClassDecl(const O: TLWNewProject; const AFormName: string): string;
const
  LE = LineEnding;
begin
  { 与 umain.lfm 里的控件一一对应（漏一个设计器就会说属性/字段对不上）。
    Initialized 会把整篇换成 LWPluginHostUnitSource 的原文，这里只为
    "拼源码 -> 建设计器"这一步能过。 }
  Result :=
     'type' + LE
    + '  T' + AFormName + ' = class(TLWForm)' + LE
    + '    pnlTop: TPanel;' + LE
    + '    lblTitle: TLabel;' + LE
    + '    btnRescan: TButton;' + LE
    + '    btnHot: TButton;' + LE
    + '    lblHot: TLabel;' + LE
    + '    lblUser: TLabel;' + LE
    + '    btnUser: TButton;' + LE
    + '    pcMain: TPageControl;' + LE
    + '    sbMain: TStatusBar;' + LE
    + '    smMain: TLWSideMenu;' + LE
    + '    procedure FormCreate(Sender: TObject);' + LE
    + '    procedure FormShow(Sender: TObject);' + LE
    + '    procedure pcMainChange(Sender: TObject);' + LE
    + '    procedure btnHotClick(Sender: TObject);' + LE
    + '    procedure btnRescanClick(Sender: TObject);' + LE
    + '    procedure btnUserClick(Sender: TObject);' + LE
    + '    procedure MenuItemClick(Sender: TObject);' + LE
    + '  private' + LE
    + '    FTabs: TStringList;' + LE
    + '    FActiveName: string;' + LE
    + '    FMenuUser: string;' + LE
    + '    procedure BuildMenu;' + LE
    + '    procedure SyncChecked;' + LE
    + '    procedure LoadMenuIcon(MI: TMenuItem; const AFile: string);' + LE
    + '    procedure OpenPlugin(AIndex: Integer);' + LE
    + '    function TabOfName(const AName: string): TTabSheet;' + LE
    + '    function IframeHTML(AIndex: Integer): string;' + LE
    + '    procedure ReloadTab(AIndex: Integer);' + LE
    + '    procedure RefreshTabs;' + LE
    + '    procedure UpdateHotLabel;' + LE
    + '    procedure UpdateUserLabel;' + LE
    + '    procedure OpenFirstAllowed;' + LE
    + '    procedure SetStatus(const AText: string);' + LE
    + '  public' + LE
    + '    destructor Destroy; override;' + LE
    + '  end;' + LE
    + LE
    + 'var' + LE
    + '  ' + AFormName + ': T' + AFormName + ';' + LE
    + LE;
end;

{ ---------------- 示例插件 ---------------- }

function LWPluginSampleLpr(const O: TLWNewProject): string;
begin
  Result :=
    'program ' + sLWPluginSampleName + ';' + LineEnding +
    '{ plugins\' + sLWPluginSampleName + ' :: 示例插件（独立 exe、独立端口）' + LineEnding +
    LineEnding +
    '  这个插件自己就是一个 lazarusWeb 服务：只注册一个 Hello 窗体，监听 ' +
      IntToStr(LWPluginSamplePort(O)) + '。' + LineEnding +
    '  宿主用 /p/' + sLWPluginSampleName + '/ 反向代理到本进程，' + LineEnding +
    '  所以这一页的按钮点击、数据处理全部发生在**本进程**里 ——' + LineEnding +
    '  插件崩了只影响自己这一页，宿主和其它插件照常运行。' + LineEnding +
    LineEnding +
    '  加自己的插件：把本目录整个复制成 plugins\<新名>\，改三处 ——' + LineEnding +
    '    <新名>.lpr / <新名>.lpi / <新名>.plugin.ini（name、title、port 换掉），' + LineEnding +
    '    窗体单元改成自己的；宿主不用改，点「重新扫描插件」即可见到新菜单。' + LineEnding +
    '}' + LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    '{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}' + LineEnding +
    LineEnding +
    'uses' + LineEnding +
    '  {$IFDEF UNIX}cthreads,{$ENDIF}' + LineEnding +
    '  Interfaces, Forms, lwapp, ' + SampleUnitName + ', upluginguard;' + LineEnding +
    LineEnding +
    'begin' + LineEnding +
    '  { 启动守卫：只认宿主下发的 nonce/token，并且父进程必须是宿主。' + LineEnding +
    '    单独双击时提示"请从主程序进入"后退出（实现在 ..\..\common\upluginguard.pas） }' + LineEnding +
    '  PlugGuardCheck(' + QuotedStr('示例插件') + ');' + LineEnding +
    LineEnding +
    '  Application.Initialize;' + LineEnding +
    '  Application.Title := ' + QuotedStr('lazarusWeb 插件：示例插件') + ';' + LineEnding +
    '  { 类名去掉 T 就是这一页的窗体名（Hello） }' + LineEnding +
    '  TLWApp.Register(THelloForm);' + LineEnding +
    '  TLWApp.Run;' + LineEnding +
    'end.' + LineEnding;
end;

function LWPluginSampleLpi(const O: TLWNewProject): string;
var
  s: string;
begin
  { 插件一律按 nogui 编（跑起来是纯控制台服务，不弹面板窗口）：
    .lpi 里两段宏 + GraphicApplication=False，lazbuild 不加 --ws=nogui 也能编。
    宿主 exe 拉起插件时也不需要任何图形环境。 }
  s :=
    '<?xml version="1.0" encoding="UTF-8"?>' + LineEnding +
    '<CONFIG>' + LineEnding +
    '  <ProjectOptions>' + LineEnding +
    '    <Version Value="12"/>' + LineEnding +
    '    <General>' + LineEnding +
    '      <Flags>' + LineEnding +
    '        <MainUnitHasCreateFormStatements Value="False"/>' + LineEnding +
    '        <MainUnitHasTitleStatement Value="False"/>' + LineEnding +
    '      </Flags>' + LineEnding +
    '      <SessionStorage Value="InProjectDir"/>' + LineEnding +
    '      <Title Value="' + sLWPluginSampleName + '"/>' + LineEnding +
    '      <UseAppBundle Value="False"/>' + LineEnding +
    '    </General>' + LineEnding +
    '    <MacroValues Count="1">' + LineEnding +
    '      <Macro1 Name="LCLWidgetType" Value="nogui"/>' + LineEnding +
    '    </MacroValues>' + LineEnding +
    '    <BuildModes>' + LineEnding +
    '      <Item Name="Default" Default="True"/>' + LineEnding +
    '      <SharedMatrixOptions Count="1">' + LineEnding +
    '        <Item1 Modes="Default" Type="IDEMacro" MacroName="LCLWidgetType" Value="nogui"/>' + LineEnding +
    '      </SharedMatrixOptions>' + LineEnding +
    '    </BuildModes>' + LineEnding +
    '    <PublishOptions>' + LineEnding +
    '      <Version Value="2"/>' + LineEnding +
    '    </PublishOptions>' + LineEnding +
    '    <RunParams>' + LineEnding +
    '      <FormatVersion Value="2"/>' + LineEnding +
    '    </RunParams>' + LineEnding +
    '    <RequiredPackages>' + LineEnding +
    '      <Item>' + LineEnding +
    '        <PackageName Value="LCL"/>' + LineEnding +
    '      </Item>' + LineEnding;

  { --units 给了源码目录就不用包：插件的 RequiredPackages 里不写 lwserver }
  if O.UnitPath = '' then
    s := s +
      '      <Item>' + LineEnding +
      '        <PackageName Value="lwserver"/>' + LineEnding +
      '      </Item>' + LineEnding;
  s := s +
    '    </RequiredPackages>' + LineEnding +
    '    <Units>' + LineEnding +
    '      <Unit>' + LineEnding +
    '        <Filename Value="' + sLWPluginSampleName + '.lpr"/>' + LineEnding +
    '        <IsPartOfProject Value="True"/>' + LineEnding +
    '      </Unit>' + LineEnding +
    '      <Unit>' + LineEnding +
    '        <Filename Value="' + SampleUnitName + '.pas"/>' + LineEnding +
    '        <IsPartOfProject Value="True"/>' + LineEnding +
    '        <ComponentName Value="HelloForm"/>' + LineEnding +
    '        <HasResources Value="True"/>' + LineEnding +
    '        <ResourceBaseClass Value="Form"/>' + LineEnding +
    '      </Unit>' + LineEnding +
    '    </Units>' + LineEnding +
    '  </ProjectOptions>' + LineEnding +
    '  <CompilerOptions>' + LineEnding +
    '    <Version Value="11"/>' + LineEnding +
    '    <Target>' + LineEnding +
    '      <Filename Value="' + sLWPluginSampleName + '"/>' + LineEnding +
    '    </Target>' + LineEnding +
    '    <SearchPaths>' + LineEnding +
    '      <IncludeFiles Value="$(ProjOutDir)"/>' + LineEnding +
    '      <UnitOutputDirectory Value="lib\$(TargetCPU)-$(TargetOS)-nogui"/>' + LineEnding;
  { 单元搜索路径：插件要能编到 common\upluginguard.pas（启动守卫）。
    --units 模式下再额外带上框架源码目录；相对路径以 .lpi 所在目录
    （plugins\hello\）为基准，所以 common 是上两级。 }
  if O.UnitPath <> '' then
    s := s +
      '      <OtherUnitFiles Value="' + O.UnitPath + ';..\..\common"/>' + LineEnding
  else
    s := s +
      '      <OtherUnitFiles Value="..\..\common"/>' + LineEnding;
  s := s +
    '    </SearchPaths>' + LineEnding +
    '    <Linking>' + LineEnding +
    '      <Options>' + LineEnding +
    '        <Win32>' + LineEnding +
    '          <GraphicApplication Value="False"/>' + LineEnding +
    '        </Win32>' + LineEnding +
    '      </Options>' + LineEnding +
    '    </Linking>' + LineEnding +
    '  </CompilerOptions>' + LineEnding +
    '</CONFIG>' + LineEnding;
  Result := s;
end;

function LWPluginSampleUnit(const O: TLWNewProject): string;
begin
  { 按行数组拼装：生成出来的是一份完整 .pas，引号 / 中文 / 缩进都在数组里
    原样保留，拼装代码不用再跟 Pascal 字符串转义较劲 }
  Result := ExpandTemplate(LinesText(cSampleUnitLines), O);
end;

function LWPluginSampleResource(const O: TLWNewProject): string;
begin
  Result := ExpandTemplate(LinesText(cSampleLfmLines), O);
end;

function LWPluginSampleManifest(const O: TLWNewProject): string;
begin
  Result :=
    '; 插件清单：宿主扫描 plugins\*\*.plugin.ini，按本文件注册路由并拉起进程。' + LineEnding +
    ';' + LineEnding +
    '; name  = 路由名，访问路径 /p/<name>/；只能字母数字与 . - _' + LineEnding +
    '; title = 左侧菜单文字' + LineEnding +
    '; group = 菜单分组，用 / 表示多层级：group=业务管理/报表 -> 两级分组；' + LineEnding +
    ';         group=-   -> 不套分组，插件直接作为顶层菜单行；不写 = 默认分组「插件」' + LineEnding +
    '; icon  = 可选，16x16 的 bmp/png，相对本清单目录（如 ..\..\icons\hello.bmp）' + LineEnding +
    '; exe   = 插件 exe，相对本清单目录；缺省 = <清单名>.exe' + LineEnding +
    '; port  = 插件监听端口，必须与 hello.ini 里的 port 一致' + LineEnding +
    '; roles = 可选，允许访问的角色（逗号分隔，如 roles=admin,analyst）。' + LineEnding +
    ';         不写 = 所有已登录用户；admin 通配。模板已默认启用登录与角色鉴权：' + LineEnding +
    ';         判定在 ..\..\common\upluginauth.pas，登录在宿主 ulogin.pas，' + LineEnding +
    ';         插件侧身份在 ..\..\common\upluginidentity.pas，菜单与 /p/ 路由同判定' + LineEnding +
    'name=' + sLWPluginSampleName + LineEnding +
    'title=示例插件' + LineEnding +
    'exe=' + sLWPluginSampleName + '.exe' + LineEnding +
    'port=' + IntToStr(LWPluginSamplePort(O)) + LineEnding;
end;

function LWPluginSampleIni(const O: TLWNewProject): string;
begin
  Result :=
    '; 示例插件进程配置。宿主拉起时用 --port= 覆盖这里的 port，' + LineEnding +
    '; 清单（' + sLWPluginSampleName + '.plugin.ini）里的 port 必须与这里一致。' + LineEnding +
    LineEnding +
    'client=alpine' + LineEnding +
    'port=' + IntToStr(LWPluginSamplePort(O)) + LineEnding +
    'theme=auto' + LineEnding;
end;

{ ---------------- 宿主 ini / 脚本 / 说明 ---------------- }

function LWPluginHostIni(const O: TLWNewProject): string;
begin
  Result :=
    '; ' + O.Name + ' 宿主（主程序 exe）。同名 ini 自动加载，命令行参数优先级更高。' + LineEnding +
    LineEnding +
    'client=alpine' + LineEnding +
    'port=' + IntToStr(O.Port) + LineEnding +
    'theme=auto' + LineEnding +
    LineEnding +
    '; 插件不在这里逐个登记：宿主启动时扫描 plugins\*\*.plugin.ini，' + LineEnding +
    '; 按清单注册 /p/<名>/ 路由并拉起插件 exe。' + LineEnding +
    '; 插件运行副本放在 plugins\.run\，所以原始插件 exe 可以被重新编译（热更新）。' + LineEnding;
end;

function LWPluginBuildAllBatch(const O: TLWNewProject): string;
var
  wsArg: string;
begin
  { 纯 ASCII + CRLF：cmd.exe 碰到 UTF-8 中文注释会错行（docs/NOTES.md 坑 10）。
    顺序有讲究：先插件后宿主 —— 宿主启动时就会去复制/拉起插件 exe，
    插件 exe 不存在只会让菜单项空着，但先编插件体验最好。 }
  if O.Headless then
    wsArg := '--ws=nogui '
  else
    wsArg := '';
  Result :=
    '@echo off' + #13#10 +
    'rem generated by the lazarusWeb project wizard (plugin framework)' + #13#10 +
    'rem builds the sample plugin first, then the host exe' + #13#10 +
    'rem keep this file ASCII + CRLF, cmd.exe chokes on UTF-8 comments' + #13#10 +
    'rem lazbuild is searched on PATH first, then common install locations' + #13#10 +
    'rem set LAZBUILD env var to override all of them' + #13#10 +
    'if defined LAZBUILD goto havetool' + #13#10 +
    'set LAZBUILD=lazbuild.exe' + #13#10 +
    'if exist "%ProgramFiles%\Lazarus\lazbuild.exe" set LAZBUILD=%ProgramFiles%\Lazarus\lazbuild.exe' + #13#10 +
    'if exist "%LocalAppData%\Lazarus\lazbuild.exe" set LAZBUILD=%LocalAppData%\Lazarus\lazbuild.exe' + #13#10 +
    'if exist "%SystemDrive%\lazarus\lazbuild.exe" set LAZBUILD=%SystemDrive%\lazarus\lazbuild.exe' + #13#10 +
    'if exist "C:\lazarus\lazbuild.exe" set LAZBUILD=C:\lazarus\lazbuild.exe' + #13#10 +
    'if exist "C:\111\lazarus\lazbuild.exe" set LAZBUILD=C:\111\lazarus\lazbuild.exe' + #13#10 +
    ':havetool' + #13#10 +
    'echo [1/2] plugin: ' + sLWPluginPluginsDir + '\' + sLWPluginSampleName + '\' + sLWPluginSampleName + '.lpi' + #13#10 +
    '"%LAZBUILD%" -B ' + sLWPluginPluginsDir + '\' + sLWPluginSampleName + '\' + sLWPluginSampleName + '.lpi %*' + #13#10 +
    'if errorlevel 1 goto end' + #13#10 +
    'echo [2/2] host: ' + O.Name + '.lpi' + #13#10 +
    '"%LAZBUILD%" -B ' + wsArg + O.Name + '.lpi %*' + #13#10 +
    'if errorlevel 1 goto end' + #13#10 +
    'echo.' + #13#10 +
    'echo  run:  ' + O.Name + '.exe' + #13#10 +
    'echo  open: http://127.0.0.1:' + IntToStr(O.Port) + '/' + #13#10 +
    'rem < and > would be redirections in cmd - never put them in echo lines' + #13#10 +
    'echo  note: one folder per plugin under ' + sLWPluginPluginsDir +
      '\ then click "rescan"' + #13#10 +
    ':end' + #13#10;
end;

function LWPluginStopAllBatch(const O: TLWNewProject; const ADir: string): string;
var
  leaf: string;
begin
  { 宿主正常退出会 Terminate 自己拉起的插件；被强杀时插件会残留。
    按 exe 路径过滤，避免误杀别的 lazarusWeb demo（插件 exe 名可能重名）。 }
  leaf := ExtractFileName(ExcludeTrailingPathDelimiter(ExpandFileName(ADir)));
  if leaf = '' then
    leaf := O.Name;
  Result :=
    '@echo off' + #13#10 +
    'rem Kill ' + O.Name + ' host + plugin processes left behind by a hard kill.' + #13#10 +
    'rem Filtered by path so other lazarusWeb projects are untouched.' + #13#10 +
    'powershell -NoProfile -Command "Get-Process ' + O.Name + ',' + sLWPluginSampleName +
      ' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like ''*\' + leaf +
      '\*'' } | Stop-Process -Force"' + #13#10 +
    'echo ' + O.Name + ' processes stopped.' + #13#10;
end;

{ Linux 版构建脚本。行尾必须写死 LF（#10）—— 用 LineEnding 在 Windows
  上生成 CRLF，bash 会把每行末尾的 ^M 当命令的一部分，直接报错。 }
function LWPluginBuildAllSh(const O: TLWNewProject): string;
var
  wsArg: string;
begin
  if O.Headless then
    wsArg := '--ws=nogui '
  else
    wsArg := '';
  Result :=
    '#!/usr/bin/env bash' + #10 +
    '# generated by the lazarusWeb project wizard (plugin framework)' + #10 +
    '# builds the sample plugin first, then the host exe' + #10 +
    '# Linux: FPC emits suffix-less exe; upluginproc falls back from exe=xxx.exe' + #10 +
    '# set LAZBUILD=/path/to/lazbuild to override the tool' + #10 +
    'set -e' + #10 +
    #10 +
    'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' + #10 +
    'LAZBUILD="${LAZBUILD:-lazbuild}"' + #10 +
    #10 +
    'if ! command -v "$LAZBUILD" >/dev/null 2>&1; then' + #10 +
    '  echo "lazbuild not found: $LAZBUILD" >&2' + #10 +
    '  echo "Install Lazarus or set LAZBUILD=/path/to/lazbuild" >&2' + #10 +
    '  exit 1' + #10 +
    'fi' + #10 +
    #10 +
    'echo "[1/2] plugin: ' + sLWPluginPluginsDir + '/' + sLWPluginSampleName + '/' +
      sLWPluginSampleName + '.lpi"' + #10 +
    '"$LAZBUILD" -B ' + sLWPluginPluginsDir + '/' + sLWPluginSampleName + '/' +
      sLWPluginSampleName + '.lpi "$@"' + #10 +
    'echo "[2/2] host: ' + O.Name + '.lpi"' + #10 +
    '"$LAZBUILD" -B ' + wsArg + O.Name + '.lpi "$@"' + #10 +
    'echo' + #10 +
    'echo "run:  $HERE/' + O.Name + '"' + #10 +
    'echo "open: http://127.0.0.1:' + IntToStr(O.Port) + '/"' + #10 +
    'echo "note: one folder per plugin under ' + sLWPluginPluginsDir +
      '/ then click rescan"' + #10;
end;

{ Linux 版清理脚本：按 /proc/<pid>/exe 的真实路径过滤，避免误杀别的项目。
  同样是 LF 行尾；宿主/插件名来自工程配置。 }
function LWPluginStopAllSh(const O: TLWNewProject): string;
begin
  Result :=
    '#!/usr/bin/env bash' + #10 +
    '# generated by the lazarusWeb project wizard (plugin framework)' + #10 +
    '# Stop ' + O.Name + ' host + plugin processes left behind by a hard kill.' + #10 +
    '# Filtered by executable path so other projects are untouched.' + #10 +
    'set -u' + #10 +
    #10 +
    'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' + #10 +
    'NAMES=" ' + O.Name + ' ' + sLWPluginSampleName + ' "' + #10 +
    'KILLED=0' + #10 +
    #10 +
    'for d in /proc/[0-9]*; do' + #10 +
    '  [ -r "$d/exe" ] || continue' + #10 +
    '  pid="${d#/proc/}"' + #10 +
    '  [ "$pid" = "$$" ] && continue' + #10 +
    '  exe="$(readlink "$d/exe" 2>/dev/null)" || continue' + #10 +
    '  case "$exe" in' + #10 +
    '    "$HERE"/*) ;;' + #10 +
    '    *) continue ;;' + #10 +
    '  esac' + #10 +
    '  base="${exe##*/}"' + #10 +
    '  base="${base% (deleted)}"' + #10 +
    '  case "$NAMES" in' + #10 +
    '    *" $base "*) ;;' + #10 +
    '    *) continue ;;' + #10 +
    '  esac' + #10 +
    '  if kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null; then' + #10 +
    '    KILLED=$((KILLED + 1))' + #10 +
    '  fi' + #10 +
    'done' + #10 +
    'echo "' + O.Name + ' processes stopped ($KILLED)."' + #10;
end;

function LWPluginReadme(const O: TLWNewProject): string;
begin
  Result :=
    '# ' + O.Name + ' —— lazarusWeb 插件框架（宿主 exe + 插件 exe）' + LineEnding +
    LineEnding +
    '由 lazarusWeb 新建工程向导的「插件模式」生成。' + LineEnding +
    LineEnding +
    '左边是框架的 LCL 侧栏菜单 `TLWSideMenu`，右边每个页签里放一个 `TLWHTMLFrame`，' + LineEnding +
    '里面是指向 `/p/<插件名>/` 的 iframe；菜单项不是写死的，一个插件清单 = 一个菜单项。' + LineEnding +
    LineEnding +
    '## 目录' + LineEnding +
    LineEnding +
    '```' + LineEnding +
    O.Name + '\' + LineEnding +
    '  ' + O.Name + '.lpr / .lpi          宿主：菜单 + 页签 + 代理 + 插件进程管理' + LineEnding +
    '  umain.pas / .lfm               宿主主窗体（菜单按角色过滤 + 顶栏身份 + 切换用户）' + LineEnding +
    '  ulogin.pas                     宿主登录窗体（TLWLoginForm，默认带图形验证码）' + LineEnding +
    '  ' + O.Name + '.ini                宿主端口等配置' + LineEnding +
    '  common\upluginproc.pas         插件发现 / 路由 / 拉起 / 热更新（只宿主链接）' + LineEnding +
    '  common\upluginguard.pas        插件启动守卫：令牌 + 父进程校验（宿主和插件都链接）' + LineEnding +
    '  common\upluginauth.pas         用户/角色、菜单过滤、/p/ 403、身份签发（只宿主链接）' + LineEnding +
    '  common\upluginidentity.pas     插件侧身份验签与读取（只插件链接）' + LineEnding +
    '  plugins\' + sLWPluginSampleName + '\                 示例插件（独立 exe，端口 ' +
      IntToStr(LWPluginSamplePort(O)) + '）' + LineEnding +
    '  plugins\.run\                 运行期自动生成：插件 exe/ini 副本（不要提交）' + LineEnding +
    '  build-all.bat / build-all.sh   先编插件、再编宿主（.sh 是 Linux/macOS 版）' + LineEnding +
    '  stop-all.bat / stop-all.sh     强杀宿主后清理残留插件进程（同上）' + LineEnding +
    '```' + LineEnding +
    LineEnding +
    '清单根目录 = 宿主 exe 所在目录下的 `plugins\`，宿主扫描 `plugins\*\*.plugin.ini`。' + LineEnding +
    LineEnding +
    '## 构建与运行' + LineEnding +
    LineEnding +
    '```bat' + LineEnding +
    'build-all.bat' + LineEnding +
    'rem 或分别：' + LineEnding +
    'lazbuild -B plugins\' + sLWPluginSampleName + '\' + sLWPluginSampleName + '.lpi' + LineEnding +
    'lazbuild -B ' + O.Name + '.lpi' + LineEnding +
    O.Name + '.exe' + LineEnding +
    '```' + LineEnding +
    LineEnding +
    'Linux/macOS 用 `bash build-all.sh`（需要 Lazarus 的 `lazbuild` 在 PATH 上；' + LineEnding +
    '也可用 `LAZBUILD=/path/to/lazbuild bash build-all.sh` 指定）。FPC 在 Linux 上' + LineEnding +
    '生成的 exe 没有 `.exe` 后缀，清单里照写 `exe=xxx.exe` 即可 —— ' + LineEnding +
    '`upluginproc.pas` 会自动退回无后缀文件，并给 `plugins\.run\` 里的运行副本补执行位。' + LineEnding +
    '清理残留进程用 `bash stop-all.sh`（按 exe 真实路径过滤，不误杀别的项目）。' + LineEnding +
    '脚本本身是 LF 行尾；从 Windows 拷到 Linux 不用转 CRLF。' + LineEnding +
    LineEnding +
    '改过 `common\upluginguard.pas`（启动守卫/口令）要**两边都重编**：宿主与插件都链接它，' + LineEnding +
    '只编一边会出现「令牌对不上，插件起不来」。' + LineEnding +
    LineEnding +
    '浏览器打开 <http://127.0.0.1:' + IntToStr(O.Port) + '/>，先登录再点左侧「插件 → 示例插件」，' + LineEnding +
    '点开就是插件进程自己渲染的页面（顶栏显示当前用户，右侧显示宿主签发的身份）。' + LineEnding +
    LineEnding +
    '## 用户权限（模板默认开启）' + LineEnding +
    LineEnding +
    '演示账号：`admin` / `analyst` / `guest`，口令 `123456`（见 `common\upluginauth.pas` 的' + LineEnding +
    '`LWAuthAccounts` 与 `LWAuthDemoPass`）。' + LineEnding +
    LineEnding +
    '- 登录：`ulogin.pas` 挂 `LWAuthLogin`，角色写进会话变量；验证码默认开，' + LineEnding +
    '  自动化可传 `--no-captcha` 或设 `LW_LOGIN_NO_CAPTCHA=1` 关掉。' + LineEnding +
    '- 菜单：`umain.pas` 用 `LWAuthCanOpen` 按清单 `roles=` 过滤，只列有权限的插件。' + LineEnding +
    '- 路由：`LWAuthRegister` 把 `LWAuthGuard` 挂到 `lwroute`，直接敲 `/p/<名>/` 也先鉴权，' + LineEnding +
    '  没权限回 403，不会代理到插件进程 —— 这是强制点，菜单过滤只是别让界面骗人。' + LineEnding +
    '- 身份：放行后签发 `X-LW-User / X-LW-Roles / X-LW-Identity-Ts / X-LW-Identity-Token`，' + LineEnding +
    '  插件用 `upluginidentity` 验签后才显示"当前用户"；直连插件端口显示"未识别"。' + LineEnding +
    LineEnding +
    '加新账号改 `LWAuthAccounts`；接自有账号体系时只换 `LWAuthLogin`，其余三处不用动。' + LineEnding +
    '不需要登录就删宿主 `.lpr` 里的 `TLWApp.SetLogin` 与 `LWAuthRegister` 两行；' + LineEnding +
    '只删菜单过滤、不删路由鉴权会留下越权访问。' + LineEnding +
    LineEnding +
    '## 清单格式（plugins\<名>\<名>.plugin.ini）' + LineEnding +
    LineEnding +
    '```ini' + LineEnding +
    'name=hello            ; 路由名，访问路径 /p/hello/' + LineEnding +
    'title=示例插件        ; 左侧菜单文字' + LineEnding +
    'group=业务管理/报表   ; 可选：用 / 分多层级；group=- 表示顶层直接一行' + LineEnding +
    'icon=..\..\icons\hello.bmp ; 可选：16x16 bmp/png' + LineEnding +
    'exe=hello.exe         ; 相对清单目录' + LineEnding +
    'port=' + IntToStr(LWPluginSamplePort(O)) + '                ; 与 hello.ini 的 port 一致' + LineEnding +
    'roles=admin,analyst   ; 可选：允许的角色；不写 = 所有已登录用户，admin 通配' + LineEnding +
    '```' + LineEnding +
    LineEnding +
    '## 再加一个插件' + LineEnding +
    LineEnding +
    '1. 把 `plugins\' + sLWPluginSampleName + '\` 整个复制成 `plugins\orders\`；' + LineEnding +
    '2. 文件改名：`orders.lpr` / `orders.lpi` / `orders.ini` / `orders.plugin.ini`，' + LineEnding +
    '   窗体单元按需改（`uform_orders.pas/.lfm`）；' + LineEnding +
    '   （`.lpi` 的 OtherUnitFiles 里有 `..\..\common`，新插件的 .lpi 也要留着；' + LineEnding +
    '   `upluginguard` 与 `upluginidentity` 都从那里编进来）' + LineEnding +
    '3. 清单里改 `name=orders`、`title=订单`、`port=<换一个空闲端口>`，' + LineEnding +
    '   `orders.ini` 里的 port 同步；' + LineEnding +
    '4. `build-all.bat` 现在只编示例插件 —— 手动 `lazbuild -B plugins\orders\orders.lpi`，' + LineEnding +
    '   或把这条命令加进 build-all.bat；' + LineEnding +
    '5. 回到宿主点顶部「重新扫描插件」：菜单多出一项、路由注册、进程拉起，宿主不用重启。' + LineEnding +
    LineEnding +
    '## 插件 exe 不能单独运行（启动守卫）' + LineEnding +
    LineEnding +
    '插件是主程序的一部分，不该让用户绕过主程序直接双击。`common\upluginguard.pas` 做了四道校验：' + LineEnding +
    LineEnding +
    '| 校验 | 说明 |' + LineEnding +
    '| --- | --- |' + LineEnding +
    '| 参数齐全 | 宿主拉起时带 `--lw-plug-nonce= / --lw-plug-token= / --lw-plug-host=` |' + LineEnding +
    '| nonce 未过期 | nonce = `<unix 秒>-<随机>`，超过 120 秒作废（挡住攒下命令行再重放） |' + LineEnding +
    '| token 对得上 | `token = SHA1(secret|nonce)`，secret 只存在于宿主与插件里（十六进制存放） |' + LineEnding +
    '| 父进程是宿主 | Windows 下取父进程 exe 名，与 `--lw-plug-host` 比对 |' + LineEnding +
    LineEnding +
    '任何一条不过：stderr 打提示 + 弹消息框 + 写 `plugin-guard.log`（插件 exe 同目录），然后 `Halt(3)`。' + LineEnding +
    '宿主 `StartOne` 看到退出码 3 会在日志里注明「被启动守卫拦了」。' + LineEnding +
    LineEnding +
    '插件侧只需要在 `.lpr` 的 `begin` 第一句加：' + LineEnding +
    LineEnding +
    '```pascal' + LineEnding +
    'PlugGuardCheck(''示例插件'');   // 通不过就提示并退出，不会往下走 Application.Initialize' + LineEnding +
    '```' + LineEnding +
    LineEnding +
    '自己验证：' + LineEnding +
    LineEnding +
    '```bat' + LineEnding +
    'cd plugins\' + sLWPluginSampleName + LineEnding +
    sLWPluginSampleName + '.exe' + LineEnding +
    'rem 弹出「『示例插件』是 lazarusWeb 的插件程序，不能单独运行。」，控制台 exit 3' + LineEnding +
    'rem 插件目录下多一行 plugin-guard.log： pid=1234  missing' + LineEnding +
    LineEnding +
    'rem 脚本/CI 里不想弹窗（只写 stderr 与日志）：' + LineEnding +
    'set LW_PLUGIN_GUARD_NOUI=1' + LineEnding +
    '```' + LineEnding +
    LineEnding +
    '改口令：只改 `upluginguard.pas` 里的 `PlugGuardSecretHex` 一处，然后重建宿主与全部插件。' + LineEnding +
    LineEnding +
    '**这层是「防误操作 + 提高门槛」，不是强保护**：secret 在 exe 里，拿到源码的人可以照着算 token，' + LineEnding +
    '父进程名也在命令行里。要做到「只有我的主程序能开」，得换证书或本地 IPC 鉴权。' + LineEnding +
    LineEnding +
    '## 热更新' + LineEnding +
    LineEnding +
    'Windows 会锁住正在运行的 exe，所以插件跑的是 `plugins\.run\` 里的副本：' + LineEnding +
    '改完插件源码直接 `lazbuild -B plugins\hello\hello.lpi`，' + LineEnding +
    '回到宿主点该插件菜单（或顶部「热更新当前插件」）——' + LineEnding +
    '宿主停旧进程 → 重新复制 exe → 起新进程 → 页内 iframe 换 URL 重新加载，' + LineEnding +
    '宿主自己不用重启。示例插件页上的 pid 会变，就是换进程的直接证据。' + LineEnding +
    LineEnding +
    '## 边界' + LineEnding +
    LineEnding +
    '- 页内是 iframe（另一个 lazarusWeb 页面），不是 LCL 控件；页面内部交互完全由插件进程处理。' + LineEnding +
    '- 宿主正常退出会终止自己拉起的插件；被强杀时插件可能残留，跑 `stop-all.bat` 清理。' + LineEnding +
    '- `plugins\.run\` 是运行副本，随时可删（下次启动重新复制）。' + LineEnding +
    '- 启动守卫只在插件**启动那一刻**校验；插件起来之后宿主退出，插件进程仍会继续跑' + LineEnding +
    '  （「拉起即信任」）。宿主正常退出会 Terminate 子进程，强杀才需要 stop-all.bat。' + LineEnding +
    '- `plugin-guard.log` 是运行期产物，不要提交。' + LineEnding +
    '- 身份头带 60 秒时间戳与签名，能挡伪造与旧头重放；同一台机器上被抓包的**新鲜**请求' + LineEnding +
    '  仍可重放，敏感系统要上 HTTPS + 短会话，别把这条当加密通道。' + LineEnding;
end;

{ ---------------- 写盘 ---------------- }

{ 按 UTF-8 原样写字节：源文件里就是 UTF-8，不做任何编码转换 }
function WriteTextFile(const APath, AText: string): Boolean;
var
  fs: TFileStream;
begin
  Result := False;
  try
    ForceDirectories(ExtractFileDir(ExpandFileName(APath)));
    fs := TFileStream.Create(APath, fmCreate);
    try
      if AText <> '' then
        fs.WriteBuffer(AText[1], Length(AText));
    finally
      fs.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

{ 需要就写：AOverwrite=False 时已存在的文件一个字节都不碰 }
function PutFile(const APath, AText: string; AOverwrite: Boolean;
  out AErr: string): Boolean;
begin
  Result := True;
  if (not AOverwrite) and FileExists(APath) then Exit;
  if not WriteTextFile(APath, AText) then
  begin
    AErr := '写入失败: ' + APath;
    Result := False;
  end;
end;

function LWPluginExtras(const O: TLWNewProject; const ADir: string;
  out AErr: string; AOverwrite: Boolean): Boolean;
var
  dir, pdir, sdir: string;

  function Put(const ARel, AText: string): Boolean;
  begin
    Result := PutFile(IncludeTrailingPathDelimiter(dir) + ARel, AText,
      AOverwrite, AErr);
  end;

begin
  Result := False;
  AErr := '';
  dir := IncludeTrailingPathDelimiter(ExpandFileName(
    ExcludeTrailingPathDelimiter(ADir)));
  if not ForceDirectories(ExcludeTrailingPathDelimiter(dir)) then
  begin
    AErr := '无法创建目录: ' + dir;
    Exit;
  end;

  pdir := sLWPluginPluginsDir + PathDelim + sLWPluginSampleName;
  sdir := sLWPluginCommonDir;

  { common\：宿主链接的插件管理 / 权限单元 + 宿主与插件共用的启动守卫 / 身份验签。
    生成一次就够，之后用户自己改（改守卫/口令或身份公式要连插件一起重编） }
  if not Put(sdir + PathDelim + 'upluginproc.pas', LWPluginCommonSource(O)) then Exit;
  if not Put(sdir + PathDelim + 'upluginguard.pas', LWPluginGuardSource(O)) then Exit;
  if not Put(sdir + PathDelim + 'upluginauth.pas', LWPluginAuthSource(O)) then Exit;
  if not Put(sdir + PathDelim + 'upluginidentity.pas', LWPluginIdentitySource(O)) then Exit;

  { 宿主根目录的登录窗体：.lpr 里 TLWApp.SetLogin(TLoginForm) 会用到 }
  if not Put('ulogin.pas', LWPluginLoginSource(O)) then Exit;

  { plugins\hello\：清单 + 插件工程（.lpr/.lpi/窗体/ini） }
  if not Put(pdir + PathDelim + sLWPluginSampleName + '.plugin.ini',
    LWPluginSampleManifest(O)) then Exit;
  if not Put(pdir + PathDelim + sLWPluginSampleName + '.lpr',
    LWPluginSampleLpr(O)) then Exit;
  if not Put(pdir + PathDelim + sLWPluginSampleName + '.lpi',
    LWPluginSampleLpi(O)) then Exit;
  if not Put(pdir + PathDelim + sLWPluginSampleName + '.ini',
    LWPluginSampleIni(O)) then Exit;
  if not Put(pdir + PathDelim + SampleUnitName + '.pas',
    LWPluginSampleUnit(O)) then Exit;
  if not Put(pdir + PathDelim + SampleUnitName + '.lfm',
    LWPluginSampleResource(O)) then Exit;

  { 宿主配置与运维脚本 }
  if not Put(O.Name + '.ini', LWPluginHostIni(O)) then Exit;
  if not Put('build-all.bat', LWPluginBuildAllBatch(O)) then Exit;
  if not Put('stop-all.bat', LWPluginStopAllBatch(O, ADir)) then Exit;
  { Linux 版：LF 行尾，bash build-all.sh / bash stop-all.sh 可直接跑 }
  if not Put('build-all.sh', LWPluginBuildAllSh(O)) then Exit;
  if not Put('stop-all.sh', LWPluginStopAllSh(O)) then Exit;
  if not Put('README.md', LWPluginReadme(O)) then Exit;

  Result := True;
end;

function LWPluginGenerate(const O: TLWNewProject; const ADir: string;
  out AErr: string): Boolean;
var
  d, clash: string;
begin
  Result := False;
  AErr := '';

  { 与常规模板同一个判据：program 名不能与框架单元或主窗体单元同名 }
  clash := LWProjectNameConflict(O.Name, O.UnitName);
  if clash <> '' then
  begin
    AErr := '工程名 "' + O.Name + '" 与单元 ' + clash +
      ' 重名（FPC 会报 Duplicate identifier），请换个名字，例如 ' +
      O.Name + 'App';
    Exit;
  end;

  d := IncludeTrailingPathDelimiter(ExpandFileName(
    ExcludeTrailingPathDelimiter(ADir)));
  if not ForceDirectories(ExcludeTrailingPathDelimiter(d)) then
  begin
    AErr := '无法创建目录: ' + d;
    Exit;
  end;

  { 宿主四个工程文件 }
  if not WriteTextFile(d + O.Name + '.lpr', LWPluginHostSource(O)) then
  begin
    AErr := '写入失败: ' + d + O.Name + '.lpr';
    Exit;
  end;
  if not WriteTextFile(d + O.Name + '.lpi', LWPluginHostInfo(O)) then
  begin
    AErr := '写入失败: ' + d + O.Name + '.lpi';
    Exit;
  end;
  if not WriteTextFile(d + O.UnitName + '.pas', LWPluginHostUnitSource(O)) then
  begin
    AErr := '写入失败: ' + d + O.UnitName + '.pas';
    Exit;
  end;
  if not WriteTextFile(d + O.UnitName + '.lfm', LWPluginHostResourceSource(O)) then
  begin
    AErr := '写入失败: ' + d + O.UnitName + '.lfm';
    Exit;
  end;

  { 命令行生成是一次性的：已存在的插件源码也按模板重写，便于 --force 重来 }
  Result := LWPluginExtras(O, ADir, AErr, True);
end;

end.
