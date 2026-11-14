{
  lazarusWeb :: lwdsgnregister
  ------------------------------------------------------------------
  设计期包（lwdesign）的注册单元。装上这个包以后，IDE 里会多出：

    1. 新建工程 -> 两个模板，差别只在 .lpi 的 widgetset 档位：
       "lazarusWeb Application"          默认 widgetset 构建（IDE 里直接 F9，
                                         启动后弹服务端面板窗口，调试最方便）；
       "lazarusWeb Application (nogui)"  LCLWidgetType=nogui 的控制台服务程序
                                         （部署档，只能 lazbuild --ws=nogui 编译）。
       两者都生成 <工程名>.lpr / .lpi / umain.pas / .lfm + build.bat，
       主窗体直接就是 TLWForm，可以像普通窗体一样拖控件。

    2. 新建文件 -> "lazarusWeb Form" / "lazarusWeb Login form"
       前者是空白 TLWForm 单元（.pas + .lfm），ResourceClass 设为 TLWForm，
       IDE 会为它打开窗体设计器；
       后者预置了登录窗体骨架（TLWLoginForm 子类）：用户名/密码编辑框、
       登录/重置按钮、OnLogin 认证回调，新建即能跑，认证逻辑改 DoLoginEx。

    3. 组件面板 -> "lazarusWeb" 页
       TLWFileUpload / TLWDBGrid / TLWDBNavigator / TLWChart / TLWGauge /
       TLWColorPicker / TLWHTMLFrame / TLWPDFFrame / TLWSideMenu
       （左侧折叠菜单，非可视，拖到窗体上后双击即开 IDE 原生菜单编辑器，
       与 TMainMenu 完全一致）。

       面板上只放"能往窗体上拖的控件"。TLWForm / TLWLoginForm 是窗体基类，
       不进面板 —— 它们由向导生成（新建工程 / 新建文件），没有任何拖放语义。

       这些类注册进 IDE 是"带自定义控件的窗体能在设计期打开"的前提 ——
       读 lfm 时按类名 GetClass，IDE 进程里没注册就直接报未知类。

    4. TLWForm / TLWLoginForm 注册为设计期基类
       FormEditingHook.RegisterDesignerBaseClass —— 这样它们的后代才能在
       设计器里正常打开（与 uniGUI 的 TUniForm 一个道理）。设计期基类
       注册表正好也是 IDE 解析 lfm 祖先类名时的查找目标
       （SearchComponentClass -> FindDesignerBaseClassByName），
       所以拿掉面板注册不会丢祖先解析能力。

  注意：TLWForm 是真正的 TForm 后代，不是 uniGUI 那种"影子类"，
  所以不需要设计期代理类（DesignProxy）—— 拖上去的 TButton/TEdit 就是
  LCL 自己的控件，属性面板、事件页、对齐工具全部照常可用。
}
unit lwdsgnregister;

{$mode objfpc}{$H+}

interface

procedure Register;

implementation

uses
  Classes, SysUtils, TypInfo, Forms, Controls, Dialogs, StdCtrls, LCLType,
  LResources, ProjectIntf, LazIDEIntf, FormEditingIntf, IDEIntf, CompOptsIntf,
  lwbase, lwform, lwfileupload, lwnewproject, lwlogin,
  { 下面这些来自 lwserver 包：注册进 IDE 后，带自定义控件的窗体才能
    在设计器里打开（不然读 lfm 报 "unknown class TLWDBGrid"），
    同时也进组件面板，Object Inspector 能直接编辑它们的新属性 }
  lwdbgrid, lwdbnav, lwchart, lwui, lwweb, lwreport, lwsidemenu;

const
  sLWProjectName      = 'lazarusWeb Application';
  sLWProjectDesc      = '用真实 LCL 控件生成 Web 服务程序（Ext JS 前端）。' + LineEnding +
    '默认 widgetset 构建：IDE 里直接 F9 调试，启动后弹服务端面板窗口。';
  sLWProjectNoguiName = 'lazarusWeb Application (nogui)';
  sLWProjectNoguiDesc = '同 lazarusWeb Application，但 .lpi 固定 LCLWidgetType=nogui：' + LineEnding +
    '纯控制台服务程序，无窗口，只能用 lazbuild --ws=nogui 编译（部署档）。';
  sLWFormName    = 'lazarusWeb Form';
  sLWFormDesc    = '一个 TLWForm 窗体单元，可直接在 IDE 里设计';
  sLWLoginName   = 'lazarusWeb Login form';
  sLWLoginDesc   = '一个 TLWLoginForm 登录窗体单元，新建即用：' + LineEnding +
    '用户名/密码编辑框与登录/重置按钮已备好（约定名 edUser / edPass，' + LineEnding +
    '基类自动识别），认证逻辑写在生成的 DoLoginEx 里（默认 admin / admin）。' + LineEnding +
    '也可以在窗体设计器里放同名控件，模板检测到后不再自动补建。';
  sLWPaletteTab  = 'lazarusWeb';

type
  { ---------------------------------------------------------------
    新建工程
    --------------------------------------------------------------- }
  TProjectLWApp = class(TProjectDescriptor)
  private
    FDir: string;
    FTitle: string;
    { True = nogui 档（.lpi 固定 LCLWidgetType=nogui）；
      False = 默认 widgetset 档。两个模板共用本类，只是这个标志不同 }
    FHeadless: Boolean;
    procedure EnsureDefaultDir;
  public
    constructor Create; override;
    function GetLocalizedName: string; override;
    function GetLocalizedDescription: string; override;
    function DoInitDescriptor: TModalResult; override;
    function InitProject(AProject: TLazProject): TModalResult; override;
    function CreateStartFiles(AProject: TLazProject): TModalResult; override;
  end;

  { ---------------------------------------------------------------
    新建 -> lazarusWeb Form
    --------------------------------------------------------------- }
  TLWFormFileDesc = class(TFileDescPascalUnitWithResource)
  public
    constructor Create; override;
    function GetLocalizedName: string; override;
    function GetLocalizedDescription: string; override;
    function GetInterfaceUsesSection: string; override;
  end;

  TLWLoginFormFileDesc = class(TFileDescPascalUnitWithResource)
  public
    constructor Create; override;
    function GetLocalizedName: string; override;
    function GetLocalizedDescription: string; override;
    function GetInterfaceUsesSection: string; override;
    function GetInterfaceSource(const Filename, SourceName,
      ResourceName: string): string; override;
    function GetImplementationSource(const Filename, SourceName,
      ResourceName: string): string; override;
    { 新建时直接给出带全部控件的 lfm：设计器里立即看到标题/编辑框/按钮，
      运行时走 lfm 流式加载，字段被回填后 AfterConstruction 不再补建。
      （默认实现返回空串，IDE 只生成空 lfm —— 设计器里就是一张白板。） }
    function GetResourceSource(const ResourceName: string): string; override;
  end;

var
  LWProjectDescriptor: TProjectLWApp = nil;       { GUI 档 }
  LWProjectNoguiDescriptor: TProjectLWApp = nil;  { nogui 档 }
  LWFormDescriptor: TLWFormFileDesc = nil;
  LWLoginFormDescriptor: TLWLoginFormFileDesc = nil;

{ ================= TProjectLWApp ================= }

constructor TProjectLWApp.Create;
begin
  inherited Create;
  { Name 是 IDE 内部的唯一标识（RegisterProjectDescriptor 强制要求非空，
    否则装包时直接弹 "Descriptor.Name empty" 异常）；显示名走
    GetLocalizedName（sLWProjectName），两者是两回事 }
  Name := 'lazarusWebApp';
  FDir := '';
  FTitle := 'LWApp';
end;

function TProjectLWApp.GetLocalizedName: string;
begin
  if FHeadless then
    Result := sLWProjectNoguiName
  else
    Result := sLWProjectName;
end;

function TProjectLWApp.GetLocalizedDescription: string;
begin
  if FHeadless then
    Result := sLWProjectNoguiDesc
  else
    Result := sLWProjectDesc;
end;

procedure TProjectLWApp.EnsureDefaultDir;
begin
  if FDir <> '' then Exit;
  { 默认放到用户目录下，避免落到 IDE 自己的工作目录里。
    用户可以在对话框里改成任意路径（含不存在的子目录）。 }
  FDir := IncludeTrailingPathDelimiter(GetUserDir) + 'LazarusWebApps' +
    PathDelim + FTitle;
  FDir := ExcludeTrailingPathDelimiter(FDir);
end;

function TProjectLWApp.DoInitDescriptor: TModalResult;
var
  s, cap: string;
begin
  EnsureDefaultDir;
  s := FDir;
  if FHeadless then
    cap := '新建 lazarusWeb 工程（nogui 档，部署用）'
  else
    cap := '新建 lazarusWeb 工程';
  if not InputQuery(cap,
    '工程目录（不存在会自动创建）：' + LineEnding + LineEnding +
    '生成：<目录>\<工程名>.lpr/.lpi、umain.pas/.lfm、build.bat', s) then
    Exit(mrCancel);
  s := Trim(s);
  if s = '' then
    Exit(mrCancel);
  FDir := ExcludeTrailingPathDelimiter(ExpandFileName(s));
  FTitle := LWSanitizeIdent(ExtractFileName(FDir));
  if FTitle = '' then
    FTitle := 'LWApp';
  Result := mrOk;
end;

function TProjectLWApp.InitProject(AProject: TLazProject): TModalResult;
var
  O: TLWNewProject;
  MainFile: TLazProjectFile;
  CO: TLazCompilerOptions;
  FormFile: TLazProjectFile;
begin
  Result := inherited InitProject(AProject);
  if Result <> mrOk then Exit;

  EnsureDefaultDir;
  O := LWDefaultProject(FTitle);
  O.Port := 8090;
  O.Title := FTitle;
  O.Headless := FHeadless;

  if not ForceDirectories(ExcludeTrailingPathDelimiter(FDir)) then
  begin
    MessageDlg(sLWProjectName, '无法创建目录：' + LineEnding + FDir,
      mtError, [mbOK], 0);
    Exit(mrCancel);
  end;

  AProject.ProjectInfoFile := IncludeTrailingPathDelimiter(FDir) + O.Name + '.lpi';
  MainFile := AProject.CreateProjectFile(IncludeTrailingPathDelimiter(FDir) + O.Name + '.lpr');
  MainFile.IsPartOfProject := True;
  AProject.AddFile(MainFile, False);
  AProject.MainFileID := 0;
  MainFile.SetSourceText(LWProjectSource(O));

  { 主窗体单元：先登记进工程，源码后面在 CreateStartFiles 里落盘。
    ResourceClass 已在描述符里设成 TLWForm，所以 IDE 认得出它是窗体。 }
  FormFile := AProject.CreateProjectFile(IncludeTrailingPathDelimiter(FDir) + O.UnitName + '.pas');
  FormFile.IsPartOfProject := True;
  AProject.AddFile(FormFile, False);
  FormFile.SetSourceText(LWFormUnitSource(O));

  CO := AProject.LazCompilerOptions;
  CO.TargetFilename := O.Name;
  CO.TargetFilenameApplyConventions := True;
  CO.UnitOutputDirectory := 'lib' + PathDelim + '$(TargetCPU)-$(TargetOS)';
  CO.Win32GraphicApp := False;      { 服务程序：控制台，不要 GUI 子系统 }
  CO.GenerateDebugInfo := True;

  AProject.Flags := AProject.Flags - [pfMainUnitHasCreateFormStatements];

  { 依赖运行时包：工程里不用写任何源码路径，搬到别的机器也能编译 }
  AProject.AddPackageDependency('LCL');
  AProject.AddPackageDependency('lwserver');

  Result := mrOk;
end;

function TProjectLWApp.CreateStartFiles(AProject: TLazProject): TModalResult;
var
  O: TLWNewProject;
  dir, err: string;
begin
  Result := mrCancel;
  EnsureDefaultDir;
  dir := IncludeTrailingPathDelimiter(FDir);
  O := LWDefaultProject(FTitle);
  O.Port := 8090;
  O.Title := FTitle;
  O.Headless := FHeadless;
  { 工程用 lwserver 包，不再需要绝对源码路径 }
  O.UnitPath := '';

  { .lfm 必须写盘：IDE 只有在单元旁边看到 <unit>.lfm 才把它当窗体，
    也才能在项目树里显示 Form/Code 切换按钮。
    build.bat 也由 LWGenerateProject 一起写（纯 ASCII + CRLF，
    nogui widgetset 只能用 lazbuild --ws=nogui 编译；在 IDE 里按 F9 会用
    IDE 自己的 widgetset（win32），链接不到 noguiint）。 }
  if not LWGenerateProject(O, ExcludeTrailingPathDelimiter(dir), err) then
  begin
    MessageDlg(sLWProjectName, '写入工程文件失败：' + LineEnding + err,
      mtError, [mbOK], 0);
    Exit;
  end;

  { 让 IDE 把 .lpi/.lpr 落盘，否则工程是"虚拟"的，重开就丢 }
  try
    LazarusIDE.DoSaveProject([]);
  except
    { 保存失败不该让建工程整体失败，用户还能手动 Ctrl+S }
  end;

  Result := LazarusIDE.DoOpenEditorFile(AProject.MainFile.Filename, -1, -1,
    [ofProjectLoading, ofRegularFile]);
  if Result = mrCancel then
    Result := mrOk;
end;

{ ================= TLWFormFileDesc ================= }

constructor TLWFormFileDesc.Create;
begin
  inherited Create;
  Name := 'lazarusWebForm';
  { ResourceClass 决定三段：
      1. IDE 认为新单元"是个窗体"，从而打开设计器；
      2. 生成的类声明是 = class(TLWForm)；
      3. 保存时由 IDE 自动写出 .lfm（TFileDescPascalUnitWithResource
         会在实现段写 R *.lfm 编译指令）。 }
  ResourceClass := TLWForm;
  { 不给 Application.CreateForm：窗体由 TLWApp.Register 注册 }
  UseCreateFormStatements := False;
  DefaultFilename := 'unit1.pas';
  DefaultResourceName := 'LWForm';
  VisibleInNewDialog := True;
  RequiredPackages := 'lwcore';
  AddToProject := True;
end;

function TLWFormFileDesc.GetLocalizedName: string;
begin
  Result := sLWFormName;
end;

function TLWFormFileDesc.GetLocalizedDescription: string;
begin
  Result := sLWFormDesc;
end;

function TLWFormFileDesc.GetInterfaceUsesSection: string;
begin
  { 在标准 uses 后面补上窗体相关的 LCL 单元和 lwform，生成的单元直接能编译 }
  Result := inherited GetInterfaceUsesSection +
    ', Forms, Controls, Graphics, Dialogs, StdCtrls, lwform';
end;

{ ================= TLWLoginFormFileDesc ================= }

constructor TLWLoginFormFileDesc.Create;
begin
  inherited Create;
  Name := 'lazarusWebLoginForm';
  { ResourceClass 同 TLWFormFileDesc：IDE 认出"是窗体"并打开设计器，
    生成的类声明基类是 TLWLoginForm }
  ResourceClass := TLWLoginForm;
  { 不给 Application.CreateForm：登录窗体由 lwlogin 框架按会话创建 }
  UseCreateFormStatements := False;
  DefaultFilename := 'unit1.pas';
  DefaultResourceName := 'LoginForm';
  VisibleInNewDialog := True;
  { lwlogin 在 lwserver 包里（lwcore 只含 lwform），两个都要 }
  RequiredPackages := 'lwcore;lwserver';
  AddToProject := True;
end;

function TLWLoginFormFileDesc.GetLocalizedName: string;
begin
  Result := sLWLoginName;
end;

function TLWLoginFormFileDesc.GetLocalizedDescription: string;
begin
  Result := sLWLoginDesc;
end;

function TLWLoginFormFileDesc.GetInterfaceUsesSection: string;
begin
  Result := inherited GetInterfaceUsesSection +
    ', Forms, Controls, StdCtrls, lwform, lwlogin';
end;

{ 生成的类：控件字段声明在前（默认 published，lfm 可回填），
  AfterConstruction 负责在字段为空时自动补建控件（见实现段），
  认证回调 DoLoginEx 挂到基类 OnLogin }
function TLWLoginFormFileDesc.GetInterfaceSource(const Filename,
  SourceName, ResourceName: string): string;
const
  LE = LineEnding;
begin
  Result :=
     'type' + LE
    + '  { 登录窗体（TLWLoginForm 子类），新建即用：' + LE
    + '    - 控件已在模板 lfm 里放好：约定名 edUser / edPass ' + LE
    + '      基类自动识别；登录/重置按钮直接挂基类的 DoLogin / DoReset；' + LE
    + '    - 认证逻辑写在 DoLoginEx（默认演示账号 admin / admin，' + LE
    + '      真实项目改成查数据库 / LDAP / 权限表）。' + LE
    + '    AfterConstruction 是兜底：字段为空（控件被删）时按同一套坐标补建。 }' + LE
    + '  T' + ResourceName + ' = class(TLWLoginForm)' + LE
    + '    lblTitle: TLabel;' + LE
    + '    lblUser: TLabel;' + LE
    + '    lblPass: TLabel;' + LE
    + '    edUser: TEdit;' + LE
    + '    edPass: TEdit;' + LE
    + '    btnOk: TButton;' + LE
    + '    btnReset: TButton;' + LE
    + '  public' + LE
    + '    procedure AfterConstruction; override;' + LE
    + '  published' + LE
    + '    procedure DoLoginEx(Sender: TObject; const AUser, APass: string;' + LE
    + '      var AOk: Boolean; var AErr: string);' + LE
    + '  end;' + LE
    + LE;
end;

{ lfm 源：控件布局与运行时补建版完全一致（同一套坐标）。
  - edUser/edPass 显式 Text = ''：lfm 流式加载时 LCL SetName 会把空
    Text 填成组件名，必须压住（见 NOTES 坑 54）；
  - OnClick 直接引用基类 published 的 DoLogin / DoReset；
  - 窗体尺寸用 Width/Height（窗口外框），与补建版一致。 }
function TLWLoginFormFileDesc.GetResourceSource(
  const ResourceName: string): string;
const
  LE = LineEnding;
begin
  Result :=
     'object ' + ResourceName + ': T' + ResourceName + LE
    + '  Left = 300' + LE
    + '  Height = 220' + LE
    + '  Top = 200' + LE
    + '  Width = 390' + LE
    + '  Caption = ''登录''' + LE
    + '  object lblTitle: TLabel' + LE
    + '    Left = 24' + LE
    + '    Height = 18' + LE
    + '    Top = 18' + LE
    + '    Width = 340' + LE
    + '    Caption = ''登录（演示账号 admin / admin）''' + LE
    + '  end' + LE
    + '  object lblUser: TLabel' + LE
    + '    Left = 24' + LE
    + '    Height = 18' + LE
    + '    Top = 62' + LE
    + '    Width = 60' + LE
    + '    Caption = ''用户名''' + LE
    + '  end' + LE
    + '  object edUser: TEdit' + LE
    + '    Left = 110' + LE
    + '    Height = 26' + LE
    + '    Top = 58' + LE
    + '    Width = 250' + LE
    + '    Text = ''''' + LE
    + '  end' + LE
    + '  object lblPass: TLabel' + LE
    + '    Left = 24' + LE
    + '    Height = 18' + LE
    + '    Top = 102' + LE
    + '    Width = 60' + LE
    + '    Caption = ''密 码''' + LE
    + '  end' + LE
    + '  object edPass: TEdit' + LE
    + '    Left = 110' + LE
    + '    Height = 26' + LE
    + '    Top = 98' + LE
    + '    Width = 250' + LE
    + '    PasswordChar = ''*''' + LE
    + '    Text = ''''' + LE
    + '  end' + LE
    + '  object btnOk: TButton' + LE
    + '    Left = 110' + LE
    + '    Height = 30' + LE
    + '    Top = 150' + LE
    + '    Width = 110' + LE
    + '    Caption = ''登 录''' + LE
    + '    OnClick = DoLogin' + LE
    + '  end' + LE
    + '  object btnReset: TButton' + LE
    + '    Left = 250' + LE
    + '    Height = 30' + LE
    + '    Top = 150' + LE
    + '    Width = 110' + LE
    + '    Caption = ''重 置''' + LE
    + '    OnClick = DoReset' + LE
    + '  end' + LE
    + 'end' + LE;
end;

{ 实现段：R 编译指令（*.lfm）与基类 rtRes 行为一致（窗体设计器照常可用），
  后面是补建控件与认证骨架。控件创建走约定名（edUser / edPass），
  这样无论自动补建还是 lfm 设计，TLWLoginForm 都认得 }
function TLWLoginFormFileDesc.GetImplementationSource(const Filename,
  SourceName, ResourceName: string): string;
const
  LE = LineEnding;
begin
  Result :=
     '{$R *.lfm}' + LE
    + LE
    + '{ 按 TLWLoginForm 的约定名补建控件；lfm 里已有同名控件时跳过。 }' + LE
    + 'procedure T' + ResourceName + '.AfterConstruction;' + LE
    + 'begin' + LE
    + '  inherited AfterConstruction;' + LE
    + '  if edUser <> nil then Exit;  { lfm 已设计过，不再自动补建 }' + LE
    + LE
    + '  Caption := ''登录'';' + LE
    + '  Width := 390;' + LE
    + '  Height := 220;' + LE
    + LE
    + '  lblTitle := TLabel.Create(Self);' + LE
    + '  lblTitle.Parent := Self;' + LE
    + '  lblTitle.SetBounds(24, 18, 340, 18);' + LE
    + '  lblTitle.Caption := ''登录（演示账号 admin / admin）'';' + LE
    + LE
    + '  lblUser := TLabel.Create(Self);' + LE
    + '  lblUser.Parent := Self;' + LE
    + '  lblUser.SetBounds(24, 62, 60, 18);' + LE
    + '  lblUser.Caption := ''用户名'';' + LE
    + LE
    + '  edUser := TEdit.Create(Self);' + LE
    + '  edUser.Parent := Self;' + LE
    + '  edUser.Name := ''edUser'';' + LE
    + '  edUser.SetBounds(110, 58, 250, 26);' + LE
    + '  edUser.Text := '''';  { LCL SetName 会把空 Text 填成组件名，必须清掉 }' + LE
    + LE
    + '  lblPass := TLabel.Create(Self);' + LE
    + '  lblPass.Parent := Self;' + LE
    + '  lblPass.SetBounds(24, 102, 60, 18);' + LE
    + '  lblPass.Caption := ''密 码'';' + LE
    + LE
    + '  edPass := TEdit.Create(Self);' + LE
    + '  edPass.Parent := Self;' + LE
    + '  edPass.Name := ''edPass'';' + LE
    + '  edPass.SetBounds(110, 98, 250, 26);' + LE
    + '  edPass.PasswordChar := ''*'';' + LE
    + '  edPass.Text := '''';  { 同上：清掉 SetName 填进来的组件名 }' + LE
    + LE
    + '  btnOk := TButton.Create(Self);' + LE
    + '  btnOk.Parent := Self;' + LE
    + '  btnOk.SetBounds(110, 150, 110, 30);' + LE
    + '  btnOk.Caption := ''登 录'';' + LE
    + '  btnOk.OnClick := @DoLogin;    { 基类 published：读编辑框 -> OnLogin }' + LE
    + LE
    + '  btnReset := TButton.Create(Self);' + LE
    + '  btnReset.Parent := Self;' + LE
    + '  btnReset.SetBounds(250, 150, 110, 30);' + LE
    + '  btnReset.Caption := ''重 置'';' + LE
    + '  btnReset.OnClick := @DoReset; { 基类 published：清空两个编辑框 }' + LE
    + LE
    + '  OnLogin := @DoLoginEx;' + LE
    + 'end;' + LE
    + LE
    + '{ 认证逻辑：真实项目在这里查数据库 / LDAP / 权限表，' + LE
    + '  并把用户信息存到服务端会话级变量（按 sid 索引）。 }' + LE
    + 'procedure T' + ResourceName + '.DoLoginEx(Sender: TObject;' + LE
    + '  const AUser, APass: string; var AOk: Boolean; var AErr: string);' + LE
    + 'begin' + LE
    + '  AOk := (AUser = ''admin'') and (APass = ''admin'');' + LE
    + '  if not AOk then' + LE
    + '    AErr := ''用户名或密码错误'';' + LE
    + 'end;' + LE
    + LE;
end;

{ ================= 注册 ================= }

procedure Register;
begin
  { 1. 窗体基类：TLWForm / TLWLoginForm 不是"能拖到窗体上"的组件，
    不进组件面板；只做两件事：
      - RegisterClass：IDE 读 .lfm 时按类名 GetClass 能找到它们；
      - RegisterDesignerBaseClass：IDE 才用窗体设计器打开它们的后代，
        同时这也是解析 lfm 祖先类名（TLWLoginForm 只出现在祖先位置）
        的查找目标 —— 正是坑 64 里唯一命中过的两条路。 }
  RegisterClass(TLWForm);
  RegisterClass(TLWLoginForm);
  FormEditingHook.RegisterDesignerBaseClass(TLWForm);
  FormEditingHook.RegisterDesignerBaseClass(TLWLoginForm);

  { 2. 新建工程向导：两个模板，差别只有 .lpi 的 widgetset 档位。
    注册顺序 = 新建工程对话框里的显示顺序；GUI 档调试最顺手，放前面。 }
  LWProjectDescriptor := TProjectLWApp.Create;
  LWProjectDescriptor.FHeadless := False;
  RegisterProjectDescriptor(LWProjectDescriptor);
  LWProjectNoguiDescriptor := TProjectLWApp.Create;
  LWProjectNoguiDescriptor.FHeadless := True;
  RegisterProjectDescriptor(LWProjectNoguiDescriptor);

  { 3. 新建文件 -> lazarusWeb Form / lazarusWeb Login form }
  LWFormDescriptor := TLWFormFileDesc.Create;
  RegisterProjectFileDescriptor(LWFormDescriptor);
  LWLoginFormDescriptor := TLWLoginFormFileDesc.Create;
  RegisterProjectFileDescriptor(LWLoginFormDescriptor);

  { 5. 组件面板：只放能拖到窗体上的控件。
    RegisterComponents 内部会 RegisterClass，IDE 读 lfm 因此能找到这些类 ——
    这是"带自定义控件的窗体能在设计期打开"的前提，缺了就报未知类。
    TLWReport 是非可视 TComponent，注册类名但不进面板。

    窗体基类（TLWForm / TLWLoginForm）不进面板：它们不是"往窗体上拖"的
    组件，而是向导生成的窗体基类，见上面第 1 段。曾经靠面板注册来顺带
    解决祖先类名解析（坑 64），现在改为 RegisterDesignerBaseClass ——
    SearchComponentClass 的查找顺序里，"设计期基类"排在面板注册表之后
    同样能命中，且不会在面板上多出两个拖不下来的条目。 }
  RegisterComponents(sLWPaletteTab, [
    TLWFileUpload,
    TLWDBGrid, TLWDBNavigator,
    TLWChart, TLWGauge, TLWColorPicker,
    TLWHTMLFrame, TLWPDFFrame,
    { 左侧折叠菜单。它是 TMenu 的后裔（非可视组件）：
      - 拖到窗体上落在非可视组件栏，选中后可在对象观察器里改
        SideWidth / ItemHeight / HeaderCaption / FirstGroupOpen；
      - 双击组件（或右键 "Menu Editor…"）弹出 IDE 原生菜单编辑器 ——
        IDE 用 RegisterComponentEditor(TMenu, TMainMenuComponentEditor)
        按继承查找，Edit 里就是 ShowMenuEditor(Component as TMenu)，
        增删菜单项、拖成子菜单、设 Caption/ShortCut/Checked、
        "Add icon from file…" 设图标、挂各叶子项的 OnClick 全都一样；
      - lfm 里就是这么存的（object 侧栏: TLWSideMenu + 嵌套 TMenuItem），
        运行时由 lwwriter 序列化成前端侧栏。 }
    TLWSideMenu]);
  RegisterClass(TLWReport);
end;

initialization
  { 组件面板图标：24x24 PNG（icons/*.png），资源名 = 组件类名
    （RegisterComponents 注册的类，IDE 按类名在 LazarusResources 里找
    'TLWxxx' PNG，找不到才落默认方块）。只有进面板的控件才需要图标；
    TLWForm / TLWLoginForm 已不在面板上，图标也一并去掉了。
    改图标后用 lazres 重新生成：
      cd icons && python gen_icons.py
      ../ 下执行：lazres lwdesign_icons.lrs TLWFileUpload.png TLWDBGrid.png
        TLWDBNavigator.png TLWChart.png TLWGauge.png TLWColorPicker.png
        TLWHTMLFrame.png TLWPDFFrame.png TLWSideMenu.png }
  {$I lwdesign_icons.lrs}

end.
