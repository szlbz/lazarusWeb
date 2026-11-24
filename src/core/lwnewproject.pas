{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwnewproject
  ------------------------------------------------------------------
  工程骨架生成器 —— IDE 向导和命令行工具（tools\lwnew）共用这一份代码。

  为什么单独抽出来？
    IDE 向导（设计期包）依赖 IDEIntf，只能在 IDE 进程里运行，没法自动化测试。
    把"要写哪些文件、文件内容是什么"放到这个不含任何 IDE 依赖的单元里，
    命令行工具就能生成一模一样的工程并真正编译运行 —— 模板改错立刻暴露。

  生成的文件：
    <name>.lpr        程序入口：Application.Initialize -> TLWApp.Register -> Run
    <name>.lpi        工程文件：widgetset 档位由 Headless 决定 ——
                      True  = LCLWidgetType=nogui（纯控制台服务，部署档）；
                      False = 不覆盖 widgetset（IDE 里 F9 直接跑，弹服务端面板）。
                      IDE 新建工程里就是 "lazarusWeb Application (nogui)" 和
                      "lazarusWeb Application" 两个模板的全部差别。
    umain.pas/.lfm    一个 TMainForm(TLWForm)，含标签/编辑框/按钮/日志
    build.bat         编译 + 启动提示（纯 ASCII + CRLF，Windows/cmd 用）
    build.sh          同上，POSIX 版（纯 ASCII + LF，Linux/macOS/MSYS2 用）；
                      两个脚本内容等价，跨平台工程就地都能编
}
unit lwnewproject;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TLWNewProject = record
    { 工程名，同时作为 .lpr/.lpi 文件名和默认窗口标题 }
    Name: string;
    { 主窗体单元名（不含扩展名），如 umain }
    UnitName: string;
    { 主窗体类名（不带 T），如 MainForm -> TMainForm }
    FormName: string;
    Title: string;
    Port: Integer;
    { widgetset 档位，决定 .lpi 的写法（IDE 新建工程里就是两个模板的差别）：
      True  = nogui 构建：.lpi 里 LCLWidgetType=nogui，纯控制台服务程序，
              只能 lazbuild --ws=nogui 编译（部署档）；
      False = 默认 widgetset 构建：.lpi 不覆盖 widgetset，IDE 里直接 F9，
              启动后弹服务端面板窗口（lwpanel），浏览器访问同一端口。
      命令行工具（tools\lwnew）默认 True，--gui 切到 False。 }
    Headless: Boolean;
    { 工程模板：True = 插件模式（多进程插件框架：宿主 exe + 插件 exe +
      common 目录，模板见 lwnewplugin），False = 常规模式。
      插件模式的宿主工程文件不由本单元生成 —— IDE 向导和 tools\lwnew
      都改调 lwnewplugin（LWPluginHostSource / LWPluginExtras）。
      IDE 新建工程向导第三框决定，tools\lwnew 用 --plugin 切换。 }
    Plugin: Boolean;
    { True = 服务(daemon)模式：生成可注册为 Windows 服务的完整宿主层
      （.lpr 带 DaemonApp 分流 + uDaemon.pas + uMapper.pas + lazarusWeb.ini），
      同一个 exe 仍可前台运行。IDE 向导第一框的后一项决定，tools\lwnew
      用 --service 切换；False = 普通应用模式（历史行为，一字不变）。 }
    Service: Boolean;
    { 非空时工程用 OtherUnitFiles 指向源码目录（不依赖已安装的包）；
      为空时依赖 lwserver 包（IDE 向导走这条路，工程可随意搬动） }
    UnitPath: string;
  end;

const
  { 服务模式额外生成的文件名（固定名，与 demos/service_demo 同源）。
    守护类名/映射类名固定，mapper 的服务名由工程名派生：<Name>Service。
    ini 用固定名 lazarusWeb.ini 而不是 <工程名>.ini —— 原因见 lwconfig：
    运行期按 <exe名>.ini -> lazarusWeb.ini 查找，固定名让 IDE 向导在
    "落盘前"就能把 ini 内容确定下来（保存时才定工程名，若用 <工程名>.ini
    则落盘那一刻内容还依赖未知的最终名）。 }
  sLWDaemonUnitName = 'uDaemon';
  sLWMapperUnitName = 'uMapper';
  sLWDaemonClassName = 'TLWServiceDaemon';
  sLWMapperClassName = 'TServiceDaemonMapper';
  sLWServiceIniName = 'lazarusWeb.ini';

{ 生成默认选项：Name=MyApp -> umain / TMainForm / 端口 8090 }
function LWDefaultProject(const AName: string): TLWNewProject;

function LWProjectSource(const O: TLWNewProject): string;
function LWProjectInfo(const O: TLWNewProject): string;

{ 服务(daemon)模式额外文件的模板（O.Service=True 才生成）：
  - uDaemon.pas    TDaemon 子类 + worker 线程 + 命令行分流 + 管理员预检
  - uMapper.pas    TDaemonMapper 子类（DaemonDefs 用代码构造，**无需 .lfm**）
  - lazarusWeb.ini 端口与日志配置（服务方式 cwd=System32 也要能找到）
  这些函数是 demos/service_demo 那套已验证代码的模板化版本，
  把踩过的坑（CreateNew 绑事件、worker 注册窗体、防假活）都固化在模板里。 }
function LWServiceDaemonSource(const O: TLWNewProject): string;
function LWServiceMapperSource(const O: TLWNewProject): string;
function LWServiceIniSource(const O: TLWNewProject): string;
{ mapper 的服务名：<工程名>Service（保证多服务共存时不撞名） }
function LWServiceName(const O: TLWNewProject): string;
{ 把 mapper 源码里的 DD.Name / DD.DisplayName 改成最终工程名对应的值。
  IDE 向导在虚拟工程阶段只能用占位名 LWApp1，真正的项目名要等用户在
  "保存项目"对话框里才定；写盘前调用本函数改 CodeBuffer，落盘即是最终值。
  ANewProjectName 为空或与当前值相同时返回 False，调用方一个字节都不用动。
  只匹配 DD.Name := / DD.DisplayName := 两行，其它内容原样保留。 }
function LWRetargetMapperNames(const ASource, ANewProjectName: string;
  out ANewSource: string): Boolean;

{ .lpi 里体现 widgetset 档位的那几段 XML —— 两个档位的差别只在这里判断
  一次，`LWProjectInfo`（写字面意义上的 .lpi）和 IDE 侧的补丁（IDE 自己写完
  .lpi 之后按同样的内容补进去，见设计期包 lwdsgnregister）共用这一份生成代码。

  历史上这段判断被抄了两遍、还各自改错一遍：IDE 侧只补 MacroValues 没补
  SharedMatrixOptions，nogui 于是从来没生效（docs/NOTES.md 坑 170）。

  返回的分段与插入位置（indent 是 .lpi 里的原样缩进）：
    LWProjectMacroValuesXml      -> 放在 <BuildModes> 之前，GUI 档返回 ''
    LWProjectBuildModeItemXml    -> <BuildModes> 的默认项
    LWProjectSharedMatrixXml     -> 放在 </BuildModes> 之前，GUI 档返回 '' }
function LWProjectMacroValuesXml(const O: TLWNewProject): string;
function LWProjectBuildModeItemXml(const O: TLWNewProject): string;
function LWProjectSharedMatrixXml(const O: TLWNewProject): string;

{ 由框架里任一源文件 / 包文件 / 目录 / 可执行文件的位置反推 src/client
  （不写死任何盘符）。从该位置起向上找四层，每层试 client 与 src/client：

    <框架>/src/core/lwapp.pas   -> 同层 ../client
    <框架>/src/lwcore.lpk       -> 同层 client
    <框架>/tools/lwnew.exe      -> 上层 src/client
    <框架>/src/core（目录）      -> 同上

  找到的目录里必须有 lw.js（避免把同名目录当成客户端资源），否则返回 ''。 }
function LWClientAssetsDirNear(const APath: string): string;

function LWFormUnitSource(const O: TLWNewProject): string;
function LWFormResourceSource(const O: TLWNewProject): string;

{ 把四个文件写进 ADir（不存在则创建） }
function LWGenerateProject(const O: TLWNewProject; const ADir: string;
  out AErr: string): Boolean;

const
  { 客户端静态资源在工程目录里的落地目录名：运行期 lwhttp 在
    <exe 目录>/lw/<文件名> 里找 lw.js / lw.css / alpine.min.js ……
    （扁平部署），目录名与 URL 前缀 /lw/ 一致 }
  sLWClientSubDir = 'lw';

{ 把框架的 src/client 整个拷到 ADestParent/lw。
  只补缺失的文件，目标已存在的不覆盖（用户可能改过样式 / JS）。
  返回本次实际拷贝的文件数；AErr 非空表示出错。
  路径全部用 PathDelim 拼，不出现任何盘符 / 分隔符常量。 }
function LWCopyClientAssets(const ASourceDir, ADestParent: string;
  out AErr: string): Integer;

{ 站点图标：把 favicon.ico 拷到工程根目录 ADestDir（**不是** lw/）。
  运行期 lwhttp 按 <root>/favicon.ico → <exe 目录>/favicon.ico 找，而 exe
  就在工程目录里，所以图标要落在根目录；缺了它浏览器标签页是空白图标
  （/favicon.ico 直接 404）。
  源文件先找 ASrcClientDir/favicon.ico，再找它的上一级（框架根目录，
  早期这份图标就放在那儿）；目标已存在则原样保留（用户可能换过自己的图标）。
  返回 True = 目标位置已有图标（本次拷的或本来就在）。 }
function LWCopyFavicon(const ASrcClientDir, ADestDir: string): Boolean;

{ 工程自带的 build.bat 内容（纯 ASCII + CRLF，Windows/cmd 用） }
function LWBuildBatch(const O: TLWNewProject): string;

{ 工程自带的 build.sh 内容（纯 ASCII + LF，Linux/macOS/MSYS2 用）。
  跨平台：同一工程在两种系统下都能就地编译，脚本内容互不干扰。 }
function LWBuildShell(const O: TLWNewProject): string;

{ 'My Web App' -> 'MyWebApp'；'2app' -> 'app2'；保证是合法标识符 }
function LWSanitizeIdent(const S: string): string;

{ 工程名与框架单元（或主窗体单元）同名会让 FPC 报
  "Duplicate identifier"：.lpr 里的 program X 与 uses 里的 X 撞车
  （Windows 的文件名还不分大小写，LWApp.lpr 与 lwapp.pas 天然冲突）。

  返回撞车的那个单元名；'' = 没有冲突。
  AUnitName 传主窗体单元名（默认 umain），传空串则只查框架单元。 }
function LWProjectNameConflict(const AName, AUnitName: string): string;

implementation

function LWSanitizeIdent(const S: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if c in ['A'..'Z', 'a'..'z', '0'..'9', '_'] then
      Result := Result + c;
  end;
  if Result = '' then
    { 兜底名不能是 'LWApp'：那正是框架单元 lwapp 的名字，
      program LWApp + uses lwapp 会撞成 Duplicate identifier }
    Result := 'LWApp1';
  if Result[1] in ['0'..'9'] then
    Result := 'LW' + Result;
end;

const
  { 框架单元名（全小写）。工程名命中任意一个都会让 FPC 报
    Duplicate identifier —— .lpr 的 program X 与 uses 里的 X 同名。
    增删单元时这份清单要跟着改（src 下所有 lw*.pas 都列在这里）。 }
  LWReservedUnitNames: array[0..37] of string = (
    'lwabout', 'lwajax', 'lwapp', 'lwbase', 'lwcamera', 'lwcaptcha',
    'lwchart', 'lwconfig', 'lwcore', 'lwdbgrid', 'lwdbnav', 'lwdesign',
    'lwdiff', 'lwdispatch', 'lwdlg', 'lwdownload', 'lwdsgnregister',
    'lwdsgntplcore', 'lwdsgntplgen', 'lwfileupload', 'lwform', 'lwhttp',
    'lwhyper', 'lwlogin', 'lwnewproject', 'lwpanel', 'lwproxyws', 'lwreport',
    'lwrlog', 'lwserver', 'lwsession', 'lwsidemenu', 'lwui', 'lwupload',
    'lwweb', 'lwwebsocket', 'lwwriter', 'lwws');

function LWProjectNameConflict(const AName, AUnitName: string): string;
var
  i: Integer;
begin
  Result := '';
  if AName = '' then Exit;
  for i := Low(LWReservedUnitNames) to High(LWReservedUnitNames) do
    if SameText(AName, LWReservedUnitNames[i]) then
      Exit(LWReservedUnitNames[i]);
  if (AUnitName <> '') and SameText(AName, AUnitName) then
    Exit(LowerCase(AUnitName));
end;

function XmlEsc(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

function LWDefaultProject(const AName: string): TLWNewProject;
begin
  Result.Name := LWSanitizeIdent(AName);
  Result.UnitName := 'umain';
  Result.FormName := 'MainForm';
  Result.Title := 'lazarusWeb · ' + AName;
  Result.Port := 8090;
  Result.Headless := True;   { lwnew 命令行保持历史行为；IDE 向导会显式覆盖 }
  Result.Plugin := False;    { 默认常规模式 }
  Result.Service := False;   { 默认普通应用模式；IDE 向导第一框 / --service 覆盖 }
  Result.UnitPath := '';
end;

function LWProjectSource(const O: TLWNewProject): string;
var
  hint, apptype, regLine, head, body, frontReg: string;
begin
  { apptype / hint 与历史完全一致：GUI 档写 $APPTYPE GUI，nogui 写 CONSOLE
    （LWIsTemplateProject 的源码判据也靠这个，不能改）。服务模式叠加说明文字。 }
  if O.Headless then
  begin
    hint :=
      '    编译时必须用 nogui widgetset（lazbuild --ws=nogui 或工程选项里设置），' + LineEnding +
      '    这样服务端不需要任何图形环境，LCL 控件仍然真的。';
    apptype := '{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}' + LineEnding;
  end
  else
  begin
    hint :=
      '    默认 widgetset 编译即可（IDE 里直接按 F9）。' + LineEnding +
      '    启动后弹出服务端面板窗口（状态/日志/停止），浏览器访问同一端口。';
    apptype := '{$IFDEF MSWINDOWS}{$APPTYPE GUI}{$ENDIF}' + LineEnding;
  end;
  if O.Service then
    hint := hint + LineEnding +
      '    本工程为服务(daemon)模式：同一个 exe 既能前台运行（不带参数），' + LineEnding +
      '    也能 --install 注册成 Windows 服务（需管理员）。';

  { 前台分支的窗体注册（普通/服务两模式共用，内容一字不改）。
    插件模式的宿主 .lpr 不由本函数生成，见 lwnewplugin.LWPluginHostSource }
  regLine :=
    '  { 注册窗体：类名去掉 T 就是浏览器里的窗体名（' + O.FormName + '） }' + LineEnding +
    '  TLWApp.Register(T' + O.FormName + ');' + LineEnding;

  if O.Service then
  begin
    { 前台分支的注册块单独构造，缩进对齐到 else begin 内部（4 空格） }
    frontReg :=
      '    { 注册窗体：类名去掉 T 就是浏览器里的窗体名（' + O.FormName + '） }' + LineEnding +
      '    TLWApp.Register(T' + O.FormName + ');' + LineEnding;
    { ---- 服务(daemon)模式：uses 加 DaemonApp + 宿主单元 + Windows API ---- }
    head :=
      'uses' + LineEnding +
      '  {$IFDEF UNIX}cthreads,{$ENDIF}' + LineEnding +
      '  Interfaces, Forms, DaemonApp, lwapp, ' +
      O.UnitName + ', ' + sLWDaemonUnitName + ', ' +
      sLWMapperUnitName +
      ' {$IFDEF MSWINDOWS}, SysUtils, Windows{$ENDIF};' + LineEnding;

    { begin 块：--install/--uninstall/--run 交给 DaemonApp，其余前台运行。
      来自已验证的 demos/service_demo，含管理员预检，避免误导性 Disk Full。 }
    body :=
      'var' + LineEnding +
      '  ServiceManagerError: DWORD = 0;' + LineEnding +
      LineEnding +
      'function CanManageWindowsServices: Boolean;' + LineEnding +
      'var' + LineEnding +
      '  Mgr: THandle;' + LineEnding +
      'begin' + LineEnding +
      '  Mgr := OpenSCManager(nil, nil, SC_MANAGER_ALL_ACCESS);' + LineEnding +
      '  Result := Mgr <> 0;' + LineEnding +
      '  if Result then' + LineEnding +
      '    CloseServiceHandle(Mgr)' + LineEnding +
      '  else' + LineEnding +
      '    ServiceManagerError := GetLastError;' + LineEnding +
      'end;' + LineEnding +
      LineEnding +
      'begin' + LineEnding +
      '  if WantDaemonApp then' + LineEnding +
      '  begin' + LineEnding +
      '    {$IFDEF MSWINDOWS}' + LineEnding +
      '    { 安装/卸载需要管理员令牌：提前拦住，避免 FCL 连抛 OS Code 5' + LineEnding +
      '      与误导性的 EInOutError: Disk Full }' + LineEnding +
      '    if NeedsServiceManagerAccess and (not CanManageWindowsServices) then' + LineEnding +
      '    begin' + LineEnding +
      '      WriteLn(' +
        '''ERROR: cannot open Windows Service Control Manager (OS Code ''' +
        ' + IntToStr(ServiceManagerError) + ' +
        ''').''' + ');' + LineEnding +
      '      WriteLn(''Please run as Administrator before --install / --uninstall.'');' + LineEnding +
      '      ExitCode := 1;' + LineEnding +
      '      Exit;' + LineEnding +
      '    end;' + LineEnding +
      '    {$ENDIF}' + LineEnding +
      '    { 服务形态：DaemonApp 原生处理 --install/--uninstall/--run }' + LineEnding +
      '    RegisterServiceDaemon;' + LineEnding +
      '    RegisterServiceMapper;' + LineEnding +
      '    DaemonApp.Application.Initialize;' + LineEnding +
      '    DaemonApp.Application.Run;' + LineEnding +
      '  end' + LineEnding +
      '  else' + LineEnding +
      '  begin' + LineEnding +
      '    { 前台形态：与普通应用一模一样，GUI 构建照常显示服务端面板 }' + LineEnding +
      '    Application.Initialize;' + LineEnding +
      '    Application.Title := ' + QuotedStr(O.Title) + ';' + LineEnding +
      frontReg +
      '    TLWApp.Run;' + LineEnding +
      '  end;' + LineEnding +
      'end.' + LineEnding;
  end
  else
  begin
    { ---- 普通模式：生成的 .lpr 与改动前逐字一致 ---- }
    head :=
      'uses' + LineEnding +
      '  {$IFDEF UNIX}cthreads,{$ENDIF}' + LineEnding +
      '  Interfaces, Forms, lwapp, ' +
      O.UnitName + ';' + LineEnding;
    body :=
      'begin' + LineEnding +
      '  Application.Initialize;' + LineEnding +
      '  Application.Title := ' + QuotedStr(O.Title) + ';' + LineEnding +
      regLine +
      '  { 想加更多窗体就继续注册，最后一个 --form=名字 可指定默认窗体 }' + LineEnding +
      '  TLWApp.Run;' + LineEnding +
      'end.' + LineEnding;
  end;

  Result :=
    'program ' + O.Name + ';' + LineEnding +
    LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    apptype +
    LineEnding +
    '{ lazarusWeb 服务程序：' + LineEnding +
    hint + ' }' + LineEnding +
    head +
    LineEnding +
    body;
end;

function LWServiceName(const O: TLWNewProject): string;
begin
  Result := O.Name + 'Service';
end;

function LWRetargetMapperNames(const ASource, ANewProjectName: string;
  out ANewSource: string): Boolean;
var
  Lines: TStringList;
  NewSvc, NewDisp, Line, Trimmed: string;
  i, LeadingPos: Integer;
begin
  Result := False;
  ANewSource := ASource;
  if ANewProjectName = '' then Exit;
  NewSvc := ANewProjectName + 'Service';
  NewDisp := 'lazarusWeb · ' + ANewProjectName + ' Service';

  Lines := TStringList.Create;
  try
    Lines.Text := ASource;
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Lines[i];
      Trimmed := Trim(Line);
      if (Pos('DD.Name :=', Trimmed) <> 1) and
         (Pos('DD.DisplayName :=', Trimmed) <> 1) then Continue;
      LeadingPos := Pos(Trimmed, Line);   { 保留原来的缩进 }
      if LeadingPos <= 0 then Continue;
      if Pos('DD.DisplayName :=', Trimmed) = 1 then
        Line := Copy(Line, 1, LeadingPos - 1) + 'DD.DisplayName := ' +
          QuotedStr(NewDisp) + ';'
      else
        Line := Copy(Line, 1, LeadingPos - 1) + 'DD.Name := ' +
          QuotedStr(NewSvc) + ';';
      if Line <> Lines[i] then
      begin
        Lines[i] := Line;
        Result := True;
      end;
    end;
    if Result then ANewSource := Lines.Text;
  finally
    Lines.Free;
  end;
end;

{ 把服务模板里的占位符换成工程相关的值。模板正文统一用字面量拼接，
  这里集中替换，避免每处都写 QuotedStr / IntToStr 把代码读乱。 }
function LWServiceExpand(const S: string; const O: TLWNewProject): string;
begin
  Result := StringReplace(S, '@FORMCLASS@', 'T' + O.FormName, [rfReplaceAll]);
  Result := StringReplace(Result, '@FORMUNIT@', O.UnitName, [rfReplaceAll]);
  Result := StringReplace(Result, '@SERVICENAME@', LWServiceName(O), [rfReplaceAll]);
  Result := StringReplace(Result, '@DISPLAYNAME@', O.Title + ' Service', [rfReplaceAll]);
  Result := StringReplace(Result, '@APPNAME@', O.Name, [rfReplaceAll]);
  Result := StringReplace(Result, '@PORT@', IntToStr(O.Port), [rfReplaceAll]);
  Result := StringReplace(Result, '@DAEMONUNIT@', sLWDaemonUnitName, [rfReplaceAll]);
  Result := StringReplace(Result, '@MAPPERUNIT@', sLWMapperUnitName, [rfReplaceAll]);
  Result := StringReplace(Result, '@DAEMONCLASS@', sLWDaemonClassName, [rfReplaceAll]);
  Result := StringReplace(Result, '@MAPPERCLASS@', sLWMapperClassName, [rfReplaceAll]);
end;

function LWServiceDaemonSource(const O: TLWNewProject): string;
var
  t: string;
begin
  { demos/service_demo/uServiceDaemon.pas 的模板化版本。三处实战修复都固化：
    1. override CreateNew 绑事件（FPC 用 CreateNew 创建 daemon，绕过 Create）；
    2. worker 里 Register(主窗体)，否则 "no form specified"；
    3. 非 SCM 停止时 Halt(1)，避免 services.msc "假活"。
    诊断文件 Diag() 内联保留（定位问题用，稳定后可删，不影响运行）。 }
  t :=
    'unit ' + sLWDaemonUnitName + ';' + LineEnding +
    LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    LineEnding +
    'interface' + LineEnding +
    LineEnding +
    '{ 是否应走 DaemonApp（服务管理命令或服务运行模式）。' + LineEnding +
    '  False = 前台运行，主程序走原来的 TLWApp.Run。 }' + LineEnding +
    'function WantDaemonApp: Boolean;' + LineEnding +
    LineEnding +
    '{ 仅 --install / --uninstall 需要打开 SCM（SC_MANAGER_ALL_ACCESS）。 }' + LineEnding +
    'function NeedsServiceManagerAccess: Boolean;' + LineEnding +
    LineEnding +
    '{ 注册守护类；必须在 DaemonApp.Application.Initialize 之前调用 }' + LineEnding +
    'procedure RegisterServiceDaemon;' + LineEnding +
    LineEnding +
    'implementation' + LineEnding +
    LineEnding +
    'uses' + LineEnding +
    '  Classes, SysUtils, DaemonApp, lwapp, lwrlog, @FORMUNIT@;' + LineEnding +
    LineEnding +
    'const' + LineEnding +
    '  DIAG_FILE = ''@APPNAME@.diag'';' + LineEnding +
    LineEnding +
    'procedure Diag(const AMsg: string);' + LineEnding +
    'var' + LineEnding +
    '  F: TextFile;' + LineEnding +
    '  P: string;' + LineEnding +
    'begin' + LineEnding +
    '  try' + LineEnding +
    '    P := IncludeTrailingPathDelimiter(' + LineEnding +
    '           ExtractFileDir(ExpandFileName(ParamStr(0)))) + DIAG_FILE;' + LineEnding +
    '    AssignFile(F, P);' + LineEnding +
    '    {$I-}' + LineEnding +
    '    if FileExists(P) then Append(F) else Rewrite(F);' + LineEnding +
    '    Writeln(F, FormatDateTime(''hh:nn:ss'', Now) + ''  '' + AMsg);' + LineEnding +
    '    CloseFile(F);' + LineEnding +
    '    {$I+}' + LineEnding +
    '  except' + LineEnding +
    '  end;' + LineEnding +
    'end;' + LineEnding +
    LineEnding +
    'var' + LineEnding +
    '  GStoppingBySCM: Boolean = False;' + LineEnding +
    LineEnding +
    'type' + LineEnding +
    '  TLWWorkerThread = class(TThread)' + LineEnding +
    '  protected' + LineEnding +
    '    procedure Execute; override;' + LineEnding +
    '  end;' + LineEnding +
    LineEnding +
    '  TLWServiceDaemon = class(TDaemon)' + LineEnding +
    '  private' + LineEnding +
    '    FWorker: TLWWorkerThread;' + LineEnding +
    '    procedure BindEvents;' + LineEnding +
    '  public' + LineEnding +
    '    constructor Create(AOwner: TComponent); override;' + LineEnding +
    '    { 框架用 DaemonClass.CreateNew 创建 daemon 实例，绕过 override 的 Create；' + LineEnding +
    '      必须 override CreateNew 并在这里绑事件，否则 DoStart 永不触发（假活）。 }' + LineEnding +
    '    constructor CreateNew(AOwner: TComponent; CreateMode: Integer); override;' + LineEnding +
    '    procedure DoStart(Sender: TCustomDaemon; var OK: Boolean);' + LineEnding +
    '    procedure DoStop(Sender: TCustomDaemon; var OK: Boolean);' + LineEnding +
    '  end;' + LineEnding +
    LineEnding +
    'procedure TLWWorkerThread.Execute;' + LineEnding +
    'begin' + LineEnding +
    '  Diag(''worker.Execute 进入，即将调用 TLWApp.RunService'');' + LineEnding +
    '  { 服务模式也要注册主窗体：Run 用 GOrder[0] 设 DefaultForm，' + LineEnding +
    '    不注册则建会话时报 "no form specified"。 }' + LineEnding +
    '  TLWApp.Register(@FORMCLASS@);' + LineEnding +
    '  try' + LineEnding +
    '    TLWApp.RunService;' + LineEnding +
    '  except' + LineEnding +
    '    on E: Exception do' + LineEnding +
    '    begin' + LineEnding +
    '      Diag(''worker 异常: '' + E.ClassName + '': '' + E.Message);' + LineEnding +
    '      LWLog(''[service] worker 异常: '' + E.ClassName + '': '' + E.Message);' + LineEnding +
    '    end;' + LineEnding +
    '  end;' + LineEnding +
    '  { 非 SCM 主动停止时 worker 退出 = 服务已失效，Halt 让 SCM 看到真实状态，' + LineEnding +
    '    避免 services.msc 一直显示"正在运行"却没人监听端口。 }' + LineEnding +
    '  if not GStoppingBySCM then' + LineEnding +
    '  begin' + LineEnding +
    '    LWLog(''[service] worker 非正常退出，终止进程（防假活）'');' + LineEnding +
    '    Halt(1);' + LineEnding +
    '  end;' + LineEnding +
    'end;' + LineEnding +
    LineEnding +
    'procedure TLWServiceDaemon.BindEvents;' + LineEnding +
    'begin' + LineEnding +
    '  OnStart := @DoStart;' + LineEnding +
    '  OnStop := @DoStop;' + LineEnding +
    'end;' + LineEnding +
    LineEnding +
    'constructor TLWServiceDaemon.Create(AOwner: TComponent);' + LineEnding +
    'begin' + LineEnding +
    '  inherited Create(AOwner);' + LineEnding +
    '  BindEvents;' + LineEnding +
    'end;' + LineEnding +
    LineEnding +
    'constructor TLWServiceDaemon.CreateNew(AOwner: TComponent; CreateMode: Integer);' + LineEnding +
    'begin' + LineEnding +
    '  inherited CreateNew(AOwner, CreateMode);' + LineEnding +
    '  BindEvents;' + LineEnding +
    'end;' + LineEnding +
    LineEnding +
    'procedure TLWServiceDaemon.DoStart(Sender: TCustomDaemon; var OK: Boolean);' + LineEnding +
    'begin' + LineEnding +
    '  Diag(''DoStart 进入（OnStart 已触发）'');' + LineEnding +
    '  FWorker := TLWWorkerThread.Create(True);' + LineEnding +
    '  FWorker.FreeOnTerminate := False;' + LineEnding +
    '  FWorker.Start;' + LineEnding +
    '  OK := True;' + LineEnding +
    'end;' + LineEnding +
    LineEnding +
    'procedure TLWServiceDaemon.DoStop(Sender: TCustomDaemon; var OK: Boolean);' + LineEnding +
    'begin' + LineEnding +
    '  GStoppingBySCM := True;' + LineEnding +
    '  TLWApp.StopService;' + LineEnding +
    '  if FWorker <> nil then' + LineEnding +
    '  begin' + LineEnding +
    '    FWorker.WaitFor;' + LineEnding +
    '    FWorker.Free;' + LineEnding +
    '    FWorker := nil;' + LineEnding +
    '  end;' + LineEnding +
    '  OK := True;' + LineEnding +
    'end;' + LineEnding +
    LineEnding +
    'procedure RegisterServiceDaemon;' + LineEnding +
    'begin' + LineEnding +
    '  RegisterDaemonClass(@DAEMONCLASS@);' + LineEnding +
    'end;' + LineEnding +
    LineEnding +
    'function NeedsServiceManagerAccess: Boolean;' + LineEnding +
    'var' + LineEnding +
    '  i: Integer;' + LineEnding +
    '  arg: string;' + LineEnding +
    'begin' + LineEnding +
    '  Result := False;' + LineEnding +
    '  for i := 1 to ParamCount do' + LineEnding +
    '  begin' + LineEnding +
    '    arg := LowerCase(ParamStr(i));' + LineEnding +
    '    if (arg = ''--install'') or (arg = ''-i'') or' + LineEnding +
    '       (arg = ''--uninstall'') or (arg = ''-u'') then' + LineEnding +
    '      Exit(True);' + LineEnding +
    '  end;' + LineEnding +
    'end;' + LineEnding +
    LineEnding +
    'function WantDaemonApp: Boolean;' + LineEnding +
    'var' + LineEnding +
    '  i: Integer;' + LineEnding +
    '  arg: string;' + LineEnding +
    'begin' + LineEnding +
    '  Result := False;' + LineEnding +
    '  for i := 1 to ParamCount do' + LineEnding +
    '  begin' + LineEnding +
    '    arg := LowerCase(ParamStr(i));' + LineEnding +
    '    if (arg = ''--install'') or (arg = ''-i'') or' + LineEnding +
    '       (arg = ''--uninstall'') or (arg = ''-u'') or' + LineEnding +
    '       (arg = ''--run'') or (arg = ''-r'') then' + LineEnding +
    '      Exit(True);' + LineEnding +
    '  end;' + LineEnding +
    'end;' + LineEnding +
    LineEnding +
    'end.' + LineEnding;
  Result := LWServiceExpand(t, O);
end;

function LWServiceMapperSource(const O: TLWNewProject): string;
var
  t: string;
begin
  { daemon 映射单元。**不需要 .lfm 资源文件**：override Create 用 CreateNew
    跳过 InitInheritedComponent，DaemonDefs 直接在代码里构造。
    这样落盘时 uMapper.pas 一个文件就完整正确（不必依赖额外 .lfm，
    也避开 IDE 把 .lfm 当窗体资源打开设计器的问题）。 }
  t :=
    'unit ' + sLWMapperUnitName + ';' + LineEnding +
    LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    LineEnding +
    'interface' + LineEnding +
    LineEnding +
    'uses' + LineEnding +
    '  Classes, SysUtils, DaemonApp;' + LineEnding +
    LineEnding +
    'type' + LineEnding +
    '  @MAPPERCLASS@ = class(TDaemonMapper)' + LineEnding +
    '  public' + LineEnding +
    '    constructor Create(AOwner: TComponent); override;' + LineEnding +
    '  end;' + LineEnding +
    LineEnding +
    '{ 注册映射类；在 DaemonApp.Application.Initialize 之前调用 }' + LineEnding +
    'procedure RegisterServiceMapper;' + LineEnding +
    LineEnding +
    'implementation' + LineEnding +
    LineEnding +
    'constructor @MAPPERCLASS@.Create(AOwner: TComponent);' + LineEnding +
    'var' + LineEnding +
    '  DD: TDaemonDef;' + LineEnding +
    'begin' + LineEnding +
    '  { 用 CreateNew 跳过 TDaemonMapper.Create 的 InitInheritedComponent，' + LineEnding +
    '    因此不需要 @MAPPERUNIT@.lfm —— 服务定义全在代码里，一个 .pas 就够。' + LineEnding +
    '    （纯代码 Create 若走 inherited Create 会报 No streaming method available）}' + LineEnding +
    '  inherited CreateNew(AOwner, 0);' + LineEnding +
    '  DD := TDaemonDef(DaemonDefs.Add);' + LineEnding +
    '  DD.DaemonClassName := ''' + sLWDaemonClassName + ''';' + LineEnding +
    '  DD.Name := ''' + LWServiceName(O) + ''';' + LineEnding +
    '  DD.DisplayName := ''' + StringReplace(O.Title + ' Service', '''', '''''', [rfReplaceAll]) + ''';' + LineEnding +
    '  DD.Description := ''lazarusWeb server running as a Windows service'';' + LineEnding +
    '  DD.Options := [doAllowStop];' + LineEnding +
    '  DD.WinBindings.StartType := stAuto;      { 开机自启 }' + LineEnding +
    '  DD.WinBindings.ServiceType := stWin32;' + LineEnding +
    '  DD.WinBindings.ErrorSeverity := esIgnore;' + LineEnding +
    '  DD.LogStatusReport := False;' + LineEnding +
    'end;' + LineEnding +
    LineEnding +
    'procedure RegisterServiceMapper;' + LineEnding +
    'begin' + LineEnding +
    '  RegisterDaemonMapper(@MAPPERCLASS@);' + LineEnding +
    'end;' + LineEnding +
    LineEnding +
    'end.' + LineEnding;
  Result := LWServiceExpand(t, O);
end;

function LWServiceIniSource(const O: TLWNewProject): string;
var
  t: string;
begin
  { 服务方式 cwd 常是 System32，所有路径按 exe 目录解析；开文件日志，
    因为 Windows 服务没有控制台，屏幕日志看不见。 }
  t :=
    '; @APPNAME@ 服务版配置（服务启动时 cwd 常是 System32，勿用相对路径）' + LineEnding +
    'client=alpine' + LineEnding +
    'port=@PORT@' + LineEnding +
    LineEnding +
    '; Windows 服务没有控制台，建议开文件日志（按 exe 目录解析）' + LineEnding +
    'log=@APPNAME@.log' + LineEnding;
  Result := LWServiceExpand(t, O);
end;

function LWProjectMacroValuesXml(const O: TLWNewProject): string;
begin
  if not O.Headless then
  begin
    { GUI 档：不写宏 = 用 IDE 的默认 widgetset }
    Result := '';
    Exit;
  end;
  Result :=
    '    <MacroValues Count="1">' + LineEnding +
    '      <Macro1 Name="LCLWidgetType" Value="nogui"/>' + LineEnding +
    '    </MacroValues>' + LineEnding;
end;

function LWProjectBuildModeItemXml(const O: TLWNewProject): string;
begin
  { IDE 里"默认构建模式"这一项，两个档位一样，名字必须叫 Default }
  Result := '      <Item Name="Default" Default="True"/>' + LineEnding;
end;

function LWProjectSharedMatrixXml(const O: TLWNewProject): string;
begin
  if not O.Headless then
  begin
    Result := '';
    Exit;
  end;
  { 这一段才是"启用"宏的地方（lazbuild / IDE 都在这里查 Type="IDEMacro"）。
    只写 MacroValues 不写它 → 日志里 LCL=False，仍用全局 win32 widgetset。 }
  Result :=
    '      <SharedMatrixOptions Count="1">' + LineEnding +
    '        <Item1 Modes="Default" Type="IDEMacro"' +
    ' MacroName="LCLWidgetType" Value="nogui"/>' + LineEnding +
    '      </SharedMatrixOptions>' + LineEnding;
end;

function LWProjectInfo(const O: TLWNewProject): string;
var
  s: string;
begin
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
    '      <Title Value="' + XmlEsc(O.Name) + '"/>' + LineEnding +
    '      <UseAppBundle Value="False"/>' + LineEnding +
    '    </General>' + LineEnding;
  { 两个模板在 .lpi 上的全部差别就在下面这三段里（见 LWProjectMacroValuesXml
    / LWProjectSharedMatrixXml）：nogui 档覆盖 LCLWidgetType=nogui，GUI 档
    完全不写宏、用 IDE 的默认 widgetset。 }
  s := s + LWProjectMacroValuesXml(O);
  s := s +
    '    <BuildModes>' + LineEnding +
    LWProjectBuildModeItemXml(O) +
    LWProjectSharedMatrixXml(O) +
    '    </BuildModes>' + LineEnding;
  s := s +
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
  if O.UnitPath <> '' then
    s := s +
      '      <OtherUnitFiles Value="' + XmlEsc(O.UnitPath) + '"/>' + LineEnding;
  s := s +
    '    </SearchPaths>' + LineEnding +
    '    <Linking>' + LineEnding +
    '      <Options>' + LineEnding;
  { 两档都要显式声明 Win32 子系统：
    - nogui 档：GraphicApplication=False —— 控制台程序，日志直接打在 stdout，
      服务化部署好采日志；
    - GUI 档：GraphicApplication=True —— Windows GUI 子系统。不写这一项时
      FPC 默认按控制台程序链接，运行起来会跟着弹一个黑色控制台窗口，
      面板窗口再漂亮也白搭（这就是"GUI 服务程序带大黑窗口"的原因）。 }
  s := s +
    '        <Win32>' + LineEnding;
  if O.Headless then
    s := s +
    '          <GraphicApplication Value="False"/>' + LineEnding
  else
    s := s +
    '          <GraphicApplication Value="True"/>' + LineEnding;
  s := s +
    '        </Win32>' + LineEnding;
  s := s +
    '      </Options>' + LineEnding +
    '    </Linking>' + LineEnding +
    '  </CompilerOptions>' + LineEnding +
    '</CONFIG>' + LineEnding;
  Result := s;
end;

function LWFormUnitSource(const O: TLWNewProject): string;
begin
  Result :=
    '{ ' + O.Name + ' 的主窗体。' + LineEnding +
    '  这里没有一行 Web 代码：TButton / TEdit / TMemo 都是真实的 LCL 控件，' + LineEnding +
    '  服务端把它们序列化给浏览器，浏览器的操作再回到下面这些事件方法里。 }' + LineEnding +
    'unit ' + O.UnitName + ';' + LineEnding +
    LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    LineEnding +
    'interface' + LineEnding +
    LineEnding +
    'uses' + LineEnding +
    '  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, lwform;' + LineEnding +
    LineEnding +
    'type' + LineEnding +
    '  T' + O.FormName + ' = class(TLWForm)' + LineEnding +
    //'    lblTitle: TLabel;' + LineEnding +
    //'    lblName: TLabel;' + LineEnding +
    //'    edtName: TEdit;' + LineEnding +
    //'    btnSay: TButton;' + LineEnding +
    //'    lblResult: TLabel;' + LineEnding +
    //'    mmoLog: TMemo;' + LineEnding +
    //'    procedure FormCreate(Sender: TObject);' + LineEnding +
    //'    procedure btnSayClick(Sender: TObject);' + LineEnding +
    '  private' + LineEnding +
    //'    FCount: Integer;' + LineEnding +
    '  public' + LineEnding +
    '  end;' + LineEnding +
    LineEnding +
    'var' + LineEnding +
    '  ' + O.FormName + ': T' + O.FormName + ';' + LineEnding +
    LineEnding +
    'implementation' + LineEnding +
    LineEnding +
    '{$R *.lfm}' + LineEnding +
    LineEnding +
    //'procedure T' + O.FormName + '.FormCreate(Sender: TObject);' + LineEnding +
    //'begin' + LineEnding +
    //'  FCount := 0;' + LineEnding +
    //'  mmoLog.Lines.Add(''窗体在服务端创建完毕，端口来自命令行 --port（默认 8090）。'');' + LineEnding +
    //'  mmoLog.Lines.Add(''试试修改这个窗体：改动 *.pas / *.lfm 后重新编译即可。'');' + LineEnding +
    //'end;' + LineEnding +
    //LineEnding +
    //'procedure T' + O.FormName + '.btnSayClick(Sender: TObject);' + LineEnding +
    //'var' + LineEnding +
    //'  s: string;' + LineEnding +
    //'begin' + LineEnding +
    //'  Inc(FCount);' + LineEnding +
    //'  s := Trim(edtName.Text);' + LineEnding +
    //'  if s = '''' then' + LineEnding +
    //'    s := ''世界'';' + LineEnding +
    //'  lblResult.Caption := ''你好，'' + s + ''！第 '' + IntToStr(FCount) + '' 次点击'';' + LineEnding +
    //'  mmoLog.Lines.Add(FormatDateTime(''hh:nn:ss'', Now) + ''  服务端处理：'' + lblResult.Caption);' + LineEnding +
    //'end;' + LineEnding +
    LineEnding +
    'end.' + LineEnding;
end;

function LWFormResourceSource(const O: TLWNewProject): string;
begin
  Result :=
    'object ' + O.FormName + ': T' + O.FormName + LineEnding +
    '  Left = 240' + LineEnding +
    '  Top = 140' + LineEnding +
    '  Width = 700' + LineEnding +
    '  Height = 440' + LineEnding +
    '  Caption = ''' + StringReplace(O.Title, '''', '''''', [rfReplaceAll]) + '''' + LineEnding +
    '  ClientHeight = 440' + LineEnding +
    '  ClientWidth = 700' + LineEnding +
    '  Color = clBtnFace' + LineEnding +
    '  Font.Charset = GB2312_CHARSET' + LineEnding +
    '  Font.Color = clWindowText' + LineEnding +
    '  Font.Height = -13' + LineEnding +
    '  Font.Name = ''Microsoft YaHei''' + LineEnding +
    '  Font.Style = []' + LineEnding +
    //'  OnCreate = FormCreate' + LineEnding +
    '  ExplicitWidth = 716' + LineEnding +
    '  ExplicitHeight = 479' + LineEnding +
    //'  object lblTitle: TLabel' + LineEnding +
    //'    Left = 24' + LineEnding +
    //'    Top = 16' + LineEnding +
    //'    Width = 400' + LineEnding +
    //'    Height = 25' + LineEnding +
    //'    Caption = ''Lazarus 窗体，直接跑在浏览器里''' + LineEnding +
    //'    Font.Height = -19' + LineEnding +
    //'    Font.Style = [fsBold]' + LineEnding +
    //'    ParentFont = False' + LineEnding +
    //'  end' + LineEnding +
    //'  object lblName: TLabel' + LineEnding +
    //'    Left = 24' + LineEnding +
    //'    Top = 64' + LineEnding +
    //'    Width = 60' + LineEnding +
    //'    Height = 17' + LineEnding +
    //'    Caption = ''你的名字''' + LineEnding +
    //'  end' + LineEnding +
    //'  object edtName: TEdit' + LineEnding +
    //'    Left = 96' + LineEnding +
    //'    Top = 60' + LineEnding +
    //'    Width = 220' + LineEnding +
    //'    Height = 27' + LineEnding +
    //'    TabOrder = 0' + LineEnding +
    //'    Text = ''Lazarus''' + LineEnding +
    //'  end' + LineEnding +
    //'  object btnSay: TButton' + LineEnding +
    //'    Left = 328' + LineEnding +
    //'    Top = 60' + LineEnding +
    //'    Width = 110' + LineEnding +
    //'    Height = 27' + LineEnding +
    //'    Caption = ''打招呼''' + LineEnding +
    //'    TabOrder = 1' + LineEnding +
    //'    OnClick = btnSayClick' + LineEnding +
    //'  end' + LineEnding +
    //'  object lblResult: TLabel' + LineEnding +
    //'    Left = 24' + LineEnding +
    //'    Top = 104' + LineEnding +
    //'    Width = 400' + LineEnding +
    //'    Height = 21' + LineEnding +
    //'    Caption = ''（等待点击）''' + LineEnding +
    //'    Font.Height = -16' + LineEnding +
    //'    Font.Color = clNavy' + LineEnding +
    //'    ParentFont = False' + LineEnding +
    //'  end' + LineEnding +
    //'  object mmoLog: TMemo' + LineEnding +
    //'    Left = 24' + LineEnding +
    //'    Top = 144' + LineEnding +
    //'    Width = 650' + LineEnding +
    //'    Height = 270' + LineEnding +
    //'    Lines.Strings = (' + LineEnding +
    //'      ''服务端日志：'')' + LineEnding +
    //'    ScrollBars = ssVertical' + LineEnding +
    //'    TabOrder = 2' + LineEnding +
    //'  end' + LineEnding +
    'end' + LineEnding;
end;

function WriteText(const APath, AText: string; out AErr: string): Boolean;
var
  fs: TFileStream;
  b: RawByteString;
begin
  Result := False;
  try
    fs := TFileStream.Create(APath, fmCreate);
    try
      b := AText;
      if b <> '' then
        fs.WriteBuffer(b[1], Length(b));
    finally
      fs.Free;
    end;
    Result := True;
  except
    on E: Exception do
      AErr := APath + ': ' + E.Message;
  end;
end;

{ 单文件按字节拷贝（TFileStream，跨平台，不用 Windows API） }
function LWCopyFileBytes(const Src, Dest: string): Boolean;
var
  fi, fo: TFileStream;
begin
  Result := False;
  fi := TFileStream.Create(Src, fmOpenRead or fmShareDenyWrite);
  try
    fo := TFileStream.Create(Dest, fmCreate);
    try
      fo.CopyFrom(fi, 0);
      Result := True;
    finally
      fo.Free;
    end;
  finally
    fi.Free;
  end;
end;

{ 递归拷目录：目标已有的文件不覆盖（用户可能改过样式/JS） }
function LWCopyTree(const SrcDir, DestDir: string; out AErr: string): Integer;
var
  sr: TSearchRec;
  d, f: string;
begin
  Result := 0;
  if not ForceDirectories(DestDir) then
  begin
    AErr := '无法创建目录：' + DestDir;
    Exit;
  end;
  if FindFirst(IncludeTrailingPathDelimiter(SrcDir) + '*', faAnyFile, sr) <> 0 then
    Exit;
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      d := IncludeTrailingPathDelimiter(SrcDir) + sr.Name;
      f := IncludeTrailingPathDelimiter(DestDir) + sr.Name;
      if (sr.Attr and faDirectory) <> 0 then
        Inc(Result, LWCopyTree(d, f, AErr))
      else if not FileExists(f) then
      begin
        try
          if LWCopyFileBytes(d, f) then
            Inc(Result)
          else
            AErr := '拷贝失败：' + d;
        except
          on E: Exception do
            AErr := d + ': ' + E.Message;
        end;
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

function LWCopyClientAssets(const ASourceDir, ADestParent: string;
  out AErr: string): Integer;
begin
  AErr := '';
  if not DirectoryExists(ASourceDir) then
  begin
    AErr := '找不到客户端资源目录：' + ASourceDir;
    Exit(0);
  end;
  Result := LWCopyTree(ExcludeTrailingPathDelimiter(ASourceDir),
    IncludeTrailingPathDelimiter(ADestParent) + sLWClientSubDir, AErr);
end;

function LWCopyFavicon(const ASrcClientDir, ADestDir: string): Boolean;
var
  dst, src, up: string;
begin
  Result := False;
  if ADestDir = '' then Exit;
  dst := IncludeTrailingPathDelimiter(ADestDir) + 'favicon.ico';
  { 已经有图标就一个字节都不动：可能是用户自己换的 }
  if FileExists(dst) then Exit(True);
  src := '';
  if ASrcClientDir <> '' then
  begin
    src := IncludeTrailingPathDelimiter(ASrcClientDir) + 'favicon.ico';
    if not FileExists(src) then
    begin
      { 早期版本把这份图标放在框架根目录，顺着 client 往上找一层兜住 }
      src := '';
      up := ExtractFileDir(ExcludeTrailingPathDelimiter(ASrcClientDir));
      if (up <> '') and FileExists(IncludeTrailingPathDelimiter(up) + 'favicon.ico') then
        src := IncludeTrailingPathDelimiter(up) + 'favicon.ico';
    end;
  end;
  if src = '' then Exit;
  try
    Result := LWCopyFileBytes(src, dst);
  except
    { 图标拷不过去不该影响工程落盘（lwhttp 会退到 exe 目录，再不行 404） }
    Result := False;
  end;
end;

function LWClientAssetsDirNear(const APath: string): string;
var
  d: string;
  depth: Integer;

  function TryClient(const ADir: string): string;
  var
    c: string;
  begin
    Result := '';
    if ADir = '' then Exit;
    c := IncludeTrailingPathDelimiter(ADir) + 'client';
    if not DirectoryExists(c) then Exit;
    { 认一下特征文件，别把别的同名目录当成客户端资源 }
    if not FileExists(IncludeTrailingPathDelimiter(c) + 'lw.js') then Exit;
    Result := c;
  end;

begin
  Result := '';
  if APath = '' then Exit;
  { APath 可以是文件（lwapp.pas / lwcore.lpk）也可以是目录（src/core / src） }
  if DirectoryExists(APath) then
    d := ExcludeTrailingPathDelimiter(APath)
  else
    d := ExtractFileDir(APath);
  if d = '' then Exit;
  { 逐层向上：本层 client、本层 src/client，再上一层…… 覆盖三种落点：
    <框架>/src/core/lwapp.pas、<框架>/src/lwcore.lpk、<框架>/tools/lwnew.exe }
  for depth := 0 to 3 do
  begin
    Result := TryClient(d);
    if Result = '' then
      Result := TryClient(IncludeTrailingPathDelimiter(d) + 'src');
    if Result <> '' then Exit;
    d := ExtractFileDir(d);
    if d = '' then Exit;
  end;
end;

function LWBuildBatch(const O: TLWNewProject): string;
var
  wsArg, runHint, svcHint: string;
begin
  { 服务模式的运维提示（纯 ASCII + CRLF）：安装/启动都需管理员，且明确
    写 sc.exe（PowerShell 里 sc 是 Set-Content 别名，直接写 sc 会踩坑）。 }
  if O.Service then
    svcHint :=
      'echo  install (as Admin): ' + O.Name + '.exe --install' + #13#10 +
      'echo  start:              sc.exe start ' + LWServiceName(O) + #13#10 +
      'echo  uninstall (Admin):  ' + O.Name + '.exe --uninstall' + #13#10
  else
    svcHint := '';
  { 纯 ASCII + CRLF：cmd.exe 碰到 UTF-8 中文注释会错行，甚至整只批处理挂死
    （详见 docs/NOTES.md 坑 10）。启动/浏览提示也用英文，别在这里放中文。 }
  if O.Headless then
  begin
    { nogui 工程用 IDE 的 F9 会链接到 IDE widgetset，报 noguiint 找不到 }
    wsArg := '--ws=nogui ';
    runHint :=
      'rem GUI build mode of the IDE cannot link noguiint:' + #13#10 +
      'rem pressing F9 in the IDE fails, build with this script (or the GUI template)' + #13#10;
  end
  else
  begin
    { GUI 工程不覆盖 widgetset：lazbuild 按 .lpi 编译即可，IDE 里 F9 也能跑 }
    wsArg := '';
    runHint :=
      'rem this project uses the default IDE widgetset:' + #13#10 +
      'rem pressing F9 in the IDE works and shows the server panel window' + #13#10;
  end;
  Result :=
    '@echo off' + #13#10 +
    'rem generated by the lazarusWeb project wizard' + #13#10 +
    runHint +
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
    '"%LAZBUILD%" -B ' + wsArg + O.Name + '.lpi %*' + #13#10 +
    'if errorlevel 1 goto end' + #13#10 +
    'echo.' + #13#10 +
    'echo  run:  ' + O.Name + '.exe --port=' + IntToStr(O.Port) + #13#10 +
    'echo  open: http://127.0.0.1:' + IntToStr(O.Port) + '/' + #13#10 +
    svcHint +
    ':end' + #13#10;
end;

function LWBuildShell(const O: TLWNewProject): string;
var
  wsArg, svcHint: string;
begin
  { Windows 服务是 SCM 概念，build.sh 只在服务模式加一句说明：
    服务命令要在 Windows 的 cmd/PowerShell 里跑，不是 bash。 }
  if O.Service then
    svcHint :=
      '# Windows service: run ' + O.Name + '.exe --install / --uninstall as Admin,' + #10 +
      '# then: sc.exe start ' + LWServiceName(O) + ' (in cmd or PowerShell)' + #10
  else
    svcHint := '';
  { 纯 ASCII + LF（WriteText 原样写字节，#10 不会变成 CRLF）。
    Windows 文件系统不存执行位，首次使用：chmod +x build.sh 或 bash build.sh。 }
  if O.Headless then
    wsArg := '--ws=nogui '
  else
    wsArg := '';
  Result :=
    '#!/usr/bin/env bash' + #10 +
    '# build.sh - build ' + O.Name + ' with lazbuild (Linux / macOS / MSYS2)' + #10 +
    '# generated by the lazarusWeb project wizard. First time:' + #10 +
    '#   chmod +x build.sh && ./build.sh' + #10 +
    'set -eu' + #10 +
    'cd "$(dirname "$0")"' + #10 +
    'LAZBUILD="${LAZBUILD:-lazbuild}"' + #10 +
    'command -v "$LAZBUILD" >/dev/null 2>&1 || {' + #10 +
    '  for c in /usr/bin/lazbuild /usr/local/bin/lazbuild /opt/lazarus/lazbuild \' + #10 +
    '           "$HOME/lazarus/lazbuild" \' + #10 +
    '           /Applications/Lazarus/lazbuild.app/Contents/MacOS/lazbuild; do' + #10 +
    '    [ -x "$c" ] && LAZBUILD="$c" && break' + #10 +
    '  done' + #10 +
    '}' + #10 +
    'command -v "$LAZBUILD" >/dev/null 2>&1 || [ -x "$LAZBUILD" ] || {' + #10 +
    '  echo "lazbuild not found. Install Lazarus or: export LAZBUILD=/path/to/lazbuild" >&2' + #10 +
    '  exit 1' + #10 +
    '}' + #10 +
    svcHint +
    '"$LAZBUILD" -B ' + wsArg + O.Name + '.lpi "$@"' + #10 +
    'echo' + #10 +
    'echo "  run:  ./' + O.Name + ' --port=' + IntToStr(O.Port) + '"' + #10 +
    'echo "  open: http://127.0.0.1:' + IntToStr(O.Port) + '/"' + #10;
end;

function LWGenerateProject(const O: TLWNewProject; const ADir: string;
  out AErr: string): Boolean;
var
  d: string;
  clash: string;
begin
  Result := False;
  AErr := '';
  { 插件模式不是"一个工程"而是"一套框架"（宿主 exe + common + plugins\<名>\），
    模板在 lwnewplugin（LWPluginGenerate / LWPluginExtras）。本函数只管单工程，
    误用就直接拒绝，免得生成一个只有宿主、没有 common 的半成品。 }
  if O.Plugin then
  begin
    AErr := '插件模式请调用 lwnewplugin.LWPluginGenerate（本函数只生成单个工程）';
    Exit;
  end;
  { program 名不能与框架单元（或主窗体单元）重名，否则 FPC 报
    "Duplicate identifier"。清单与判据见 LWProjectNameConflict。 }
  clash := LWProjectNameConflict(O.Name, O.UnitName);
  if clash <> '' then
  begin
    AErr := '工程名 "' + O.Name + '" 与单元 ' + clash +
      ' 重名（FPC 会报 Duplicate identifier），请换个名字，例如 ' +
      O.Name + 'App';
    Exit;
  end;
  d := IncludeTrailingPathDelimiter(ADir);
  if not ForceDirectories(ExcludeTrailingPathDelimiter(d)) then
  begin
    AErr := '无法创建目录: ' + d;
    Exit;
  end;
  if not WriteText(d + O.Name + '.lpr', LWProjectSource(O), AErr) then Exit;
  if not WriteText(d + O.Name + '.lpi', LWProjectInfo(O), AErr) then Exit;
  if not WriteText(d + O.UnitName + '.pas', LWFormUnitSource(O), AErr) then Exit;
  if not WriteText(d + O.UnitName + '.lfm', LWFormResourceSource(O), AErr) then Exit;
  { 服务(daemon)模式额外写守护层：uDaemon.pas / uMapper.pas / lazarusWeb.ini }
  if O.Service then
  begin
    if not WriteText(d + sLWDaemonUnitName + '.pas', LWServiceDaemonSource(O), AErr) then Exit;
    if not WriteText(d + sLWMapperUnitName + '.pas', LWServiceMapperSource(O), AErr) then Exit;
    if not WriteText(d + sLWServiceIniName, LWServiceIniSource(O), AErr) then Exit;
  end;
  if not WriteText(d + 'build.bat', LWBuildBatch(O), AErr) then Exit;
  if not WriteText(d + 'build.sh', LWBuildShell(O), AErr) then Exit;
  Result := True;
end;

end.
