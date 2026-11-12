{
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
    { 非空时工程用 OtherUnitFiles 指向源码目录（不依赖已安装的包）；
      为空时依赖 lwserver 包（IDE 向导走这条路，工程可随意搬动） }
    UnitPath: string;
  end;

{ 生成默认选项：Name=MyApp -> umain / TMainForm / 端口 8090 }
function LWDefaultProject(const AName: string): TLWNewProject;

function LWProjectSource(const O: TLWNewProject): string;
function LWProjectInfo(const O: TLWNewProject): string;
function LWFormUnitSource(const O: TLWNewProject): string;
function LWFormResourceSource(const O: TLWNewProject): string;

{ 把四个文件写进 ADir（不存在则创建） }
function LWGenerateProject(const O: TLWNewProject; const ADir: string;
  out AErr: string): Boolean;

{ 工程自带的 build.bat 内容（纯 ASCII + CRLF，Windows/cmd 用） }
function LWBuildBatch(const O: TLWNewProject): string;

{ 工程自带的 build.sh 内容（纯 ASCII + LF，Linux/macOS/MSYS2 用）。
  跨平台：同一工程在两种系统下都能就地编译，脚本内容互不干扰。 }
function LWBuildShell(const O: TLWNewProject): string;

{ 'My Web App' -> 'MyWebApp'；'2app' -> 'app2'；保证是合法标识符 }
function LWSanitizeIdent(const S: string): string;

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
    Result := 'LWApp';
  if Result[1] in ['0'..'9'] then
    Result := 'LW' + Result;
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
  Result.UnitPath := '';
end;

function LWProjectSource(const O: TLWNewProject): string;
var
  hint: string;
  apptype: string;
begin
  if O.Headless then
  begin
    hint :=
      '    编译时必须用 nogui widgetset（lazbuild --ws=nogui 或工程选项里设置），' + LineEnding +
      '    这样服务端不需要任何图形环境，LCL 控件仍然真的。';
    { 控制台子系统：日志直接打在 stdout，服务化部署好采日志 }
    apptype := '{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}' + LineEnding;
  end
  else
  begin
    hint :=
      '    默认 widgetset 编译即可（IDE 里直接按 F9）。' + LineEnding +
      '    启动后弹出服务端面板窗口（状态/日志/停止），浏览器访问同一端口。';
    { GUI 子系统：不写这一句时 FPC 按控制台链接，跑起来会跟一个黑窗口。
      APPTYPE 编译指令的优先级高于命令行的 -WG，所以这里必须显式写 GUI。 }
    apptype := '{$IFDEF MSWINDOWS}{$APPTYPE GUI}{$ENDIF}' + LineEnding;
  end;
  Result :=
    'program ' + O.Name + ';' + LineEnding +
    LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    apptype +
    LineEnding +
    '{ lazarusWeb 服务程序：' + LineEnding +
    hint + ' }' + LineEnding +
    'uses' + LineEnding +
    '  {$IFDEF UNIX}cthreads,{$ENDIF}' + LineEnding +
    '  Interfaces, Forms, lwapp, ' + O.UnitName + ';' + LineEnding +
    LineEnding +
    'begin' + LineEnding +
    '  Application.Initialize;' + LineEnding +
    '  Application.Title := ' + QuotedStr(O.Title) + ';' + LineEnding +
    '  { 注册窗体：类名去掉 T 就是浏览器里的窗体名（' + O.FormName + '） }' + LineEnding +
    '  TLWApp.Register(T' + O.FormName + ');' + LineEnding +
    '  { 想加更多窗体就继续注册，最后一个 --form=名字 可指定默认窗体 }' + LineEnding +
    '  TLWApp.Run;' + LineEnding +
    'end.' + LineEnding;
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
  { 两个模板在 .lpi 上的全部差别就在这里：
    - nogui 档：覆盖 LCLWidgetType=nogui（纯控制台服务，只能 lazbuild --ws=nogui）；
    - GUI 档：不覆盖 widgetset（用 IDE 的默认 widgetset），IDE 里直接 F9，
      启动后出服务端面板窗口。 }
  if O.Headless then
    s := s +
    '    <MacroValues Count="1">' + LineEnding +
    '      <Macro1 Name="LCLWidgetType" Value="nogui"/>' + LineEnding +
    '    </MacroValues>' + LineEnding +
    '    <BuildModes>' + LineEnding +
    '      <Item Name="Default" Default="True"/>' + LineEnding +
    '      <SharedMatrixOptions Count="1">' + LineEnding +
    '        <Item1 ID="131280374502" Modes="Default" Type="IDEMacro" MacroName="LCLWidgetType" Value="nogui"/>' + LineEnding +
    '      </SharedMatrixOptions>' + LineEnding +
    '    </BuildModes>' + LineEnding
  else
    s := s +
    '    <BuildModes>' + LineEnding +
    '      <Item Name="Default" Default="True"/>' + LineEnding +
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
    '    lblTitle: TLabel;' + LineEnding +
    '    lblName: TLabel;' + LineEnding +
    '    edtName: TEdit;' + LineEnding +
    '    btnSay: TButton;' + LineEnding +
    '    lblResult: TLabel;' + LineEnding +
    '    mmoLog: TMemo;' + LineEnding +
    '    procedure FormCreate(Sender: TObject);' + LineEnding +
    '    procedure btnSayClick(Sender: TObject);' + LineEnding +
    '  private' + LineEnding +
    '    FCount: Integer;' + LineEnding +
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
    'procedure T' + O.FormName + '.FormCreate(Sender: TObject);' + LineEnding +
    'begin' + LineEnding +
    '  FCount := 0;' + LineEnding +
    '  mmoLog.Lines.Add(''窗体在服务端创建完毕，端口来自命令行 --port（默认 8090）。'');' + LineEnding +
    '  mmoLog.Lines.Add(''试试修改这个窗体：改动 *.pas / *.lfm 后重新编译即可。'');' + LineEnding +
    'end;' + LineEnding +
    LineEnding +
    'procedure T' + O.FormName + '.btnSayClick(Sender: TObject);' + LineEnding +
    'var' + LineEnding +
    '  s: string;' + LineEnding +
    'begin' + LineEnding +
    '  Inc(FCount);' + LineEnding +
    '  s := Trim(edtName.Text);' + LineEnding +
    '  if s = '''' then' + LineEnding +
    '    s := ''世界'';' + LineEnding +
    '  lblResult.Caption := ''你好，'' + s + ''！第 '' + IntToStr(FCount) + '' 次点击'';' + LineEnding +
    '  mmoLog.Lines.Add(FormatDateTime(''hh:nn:ss'', Now) + ''  服务端处理：'' + lblResult.Caption);' + LineEnding +
    'end;' + LineEnding +
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
    '  OnCreate = FormCreate' + LineEnding +
    '  ExplicitWidth = 716' + LineEnding +
    '  ExplicitHeight = 479' + LineEnding +
    '  object lblTitle: TLabel' + LineEnding +
    '    Left = 24' + LineEnding +
    '    Top = 16' + LineEnding +
    '    Width = 400' + LineEnding +
    '    Height = 25' + LineEnding +
    '    Caption = ''Lazarus 窗体，直接跑在浏览器里''' + LineEnding +
    '    Font.Height = -19' + LineEnding +
    '    Font.Style = [fsBold]' + LineEnding +
    '    ParentFont = False' + LineEnding +
    '  end' + LineEnding +
    '  object lblName: TLabel' + LineEnding +
    '    Left = 24' + LineEnding +
    '    Top = 64' + LineEnding +
    '    Width = 60' + LineEnding +
    '    Height = 17' + LineEnding +
    '    Caption = ''你的名字''' + LineEnding +
    '  end' + LineEnding +
    '  object edtName: TEdit' + LineEnding +
    '    Left = 96' + LineEnding +
    '    Top = 60' + LineEnding +
    '    Width = 220' + LineEnding +
    '    Height = 27' + LineEnding +
    '    TabOrder = 0' + LineEnding +
    '    Text = ''Lazarus''' + LineEnding +
    '  end' + LineEnding +
    '  object btnSay: TButton' + LineEnding +
    '    Left = 328' + LineEnding +
    '    Top = 60' + LineEnding +
    '    Width = 110' + LineEnding +
    '    Height = 27' + LineEnding +
    '    Caption = ''打招呼''' + LineEnding +
    '    TabOrder = 1' + LineEnding +
    '    OnClick = btnSayClick' + LineEnding +
    '  end' + LineEnding +
    '  object lblResult: TLabel' + LineEnding +
    '    Left = 24' + LineEnding +
    '    Top = 104' + LineEnding +
    '    Width = 400' + LineEnding +
    '    Height = 21' + LineEnding +
    '    Caption = ''（等待点击）''' + LineEnding +
    '    Font.Height = -16' + LineEnding +
    '    Font.Color = clNavy' + LineEnding +
    '    ParentFont = False' + LineEnding +
    '  end' + LineEnding +
    '  object mmoLog: TMemo' + LineEnding +
    '    Left = 24' + LineEnding +
    '    Top = 144' + LineEnding +
    '    Width = 650' + LineEnding +
    '    Height = 270' + LineEnding +
    '    Lines.Strings = (' + LineEnding +
    '      ''服务端日志：'')' + LineEnding +
    '    ScrollBars = ssVertical' + LineEnding +
    '    TabOrder = 2' + LineEnding +
    '  end' + LineEnding +
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

function LWBuildBatch(const O: TLWNewProject): string;
var
  wsArg, runHint: string;
begin
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
    ':end' + #13#10;
end;

function LWBuildShell(const O: TLWNewProject): string;
var
  wsArg: string;
begin
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
    '"$LAZBUILD" -B ' + wsArg + O.Name + '.lpi "$@"' + #10 +
    'echo' + #10 +
    'echo "  run:  ./' + O.Name + ' --port=' + IntToStr(O.Port) + '"' + #10 +
    'echo "  open: http://127.0.0.1:' + IntToStr(O.Port) + '/"' + #10;
end;

function LWGenerateProject(const O: TLWNewProject; const ADir: string;
  out AErr: string): Boolean;
var
  d: string;
  Reserved: array[0..26] of string;
  i: Integer;
begin
  Result := False;
  AErr := '';
  { program 名不能与框架单元重名（FPC: Duplicate identifier），历史上
    有用户把工程命名为 LWApp 而踩坑。这里直接把已知核心单元列为保留字。 }
  Reserved[0] := 'lwabout';  Reserved[1] := 'lwajax';   Reserved[2] := 'lwapp';
  Reserved[3] := 'lwbase';   Reserved[4] := 'lwchart';  Reserved[5] := 'lwconfig';
  Reserved[6] := 'lwdbgrid'; Reserved[7] := 'lwdbnav';  Reserved[8] := 'lwdispatch';
  Reserved[9] := 'lwdlg';    Reserved[10] := 'lwdownload'; Reserved[11] := 'lwfileupload';
  Reserved[12] := 'lwform';  Reserved[13] := 'lwhttp';  Reserved[14] := 'lwhyper';
  Reserved[15] := 'lwlogin'; Reserved[16] := 'lwnewproject'; Reserved[17] := 'lwpanel';
  Reserved[18] := 'lwreport'; Reserved[19] := 'lwrlog'; Reserved[20] := 'lwsession';
  Reserved[21] := 'lwui';    Reserved[22] := 'lwupload'; Reserved[23] := 'lwweb';
  Reserved[24] := 'lwwebsocket'; Reserved[25] := 'lwwriter'; Reserved[26] := 'lwws';
  for i := Low(Reserved) to High(Reserved) do
    if SameText(O.Name, Reserved[i]) then
    begin
      AErr := '工程名 "' + O.Name + '" 与框架单元 ' + Reserved[i] +
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
  if not WriteText(d + 'build.bat', LWBuildBatch(O), AErr) then Exit;
  if not WriteText(d + 'build.sh', LWBuildShell(O), AErr) then Exit;
  Result := True;
end;

end.
