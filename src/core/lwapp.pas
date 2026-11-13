{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwapp
  ------------------------------------------------------------------
  应用门面：注册窗体、解析命令行、启动服务。

  最小可用的服务程序（整个"服务端"就这么点代码）：

      program hello;
      uses Interfaces, Forms, lwapp, uHello;
      begin
        Application.Initialize;
        TLWApp.Register(THelloForm);     // 窗体名自动取类名去掉 T
        TLWApp.Run;
      end.

  业务窗体 uHello.pas 仍然是普通的 Lazarus 窗体，
  只需要把 TForm 换成 TLWForm。
}
unit lwapp;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, lwbase, lwhttp, lwajax;

type
  { 窗体工厂：把"按名字建窗体"以对象方法的形式交给 HTTP 层 }
  TLWFormProvider = class
  public
    function CreateForm(const AName: string; out AForm: TCustomForm): Boolean;
    procedure ListForms(AList: TStrings);
  end;

  TLWApp = class
  public
    class procedure RegisterForm(const AName: string; AClass: TFormClass);
    { 用类名注册：THelloForm -> HelloForm }
    class procedure Register(AFormClass: TFormClass);
    { 登录窗体：注册 + 启用登录（每个新会话先显示它，认证通过才进主窗体）。
      传 TLWLoginForm 子类，内部自动 RegisterForm }
    class procedure SetLogin(ALoginClass: TFormClass);
    { 自定义 AJAX 端点（AddAjaxProcedure 对应物）。
      注册后浏览器/第三方 JS 直接 fetch('/lw/ajax/<名字>')，不经过组件树。 }
    class procedure AddAjax(const AName: string; AHandler: TLWAjaxHandler);
    class function CreateForm(const AName: string; out AForm: TCustomForm): Boolean;
    class procedure ListForms(AList: TStrings);
    class function FormNames: string;
    { 默认主窗体名（登录成功后 lwlogin 用它创建主窗体）}
    class function DefaultFormName: string;
    class procedure Run;
    class function Server: TLWServer;
  end;

implementation

uses
  lwws, lwdlg, lwdbnav, lwpanel, lwrlog, lwconfig;

type
  { 坑 107：无头 widgetset 上的"异常对话框"是颗雷。
    TApplication.ShowException -> PromptUser -> DialogImageList.LoadImage /
    TLCLGlyphs.GetImageIndex -> ImageList.ScaleImage -> TLazIntfImage.LoadFromBitmap
    -> 虚拟 widgetset 没有 RawImage -> FPImageException
    （"Failed to get raw image description from bitmap"）。
    这颗雷会**吞掉真正的原始异常**再炸出来：40 并发压测看到的 FPImageException
    就是某个 FormCreate 异常的"替身"，真凶全被盖住。
    所以统一接管 Application.OnException：无头线程 / 工作线程只记日志，绝不弹窗；
    只有 GUI 构建且异常发生在主线程（真实 widgetset）才允许 ShowException。 }
  TLWAppExceptionHandler = class
  public
    procedure HandleException(Sender: TObject; E: Exception);
  end;

var
  GExcHandler: TLWAppExceptionHandler = nil;

procedure TLWAppExceptionHandler.HandleException(Sender: TObject; E: Exception);
begin
  if Sender is TComponent then
    LWLog('[lw] unhandled ' + E.ClassName + ': ' + E.Message +
      '  (at ' + TComponent(Sender).Name + ')')
  else
    LWLog('[lw] unhandled ' + E.ClassName + ': ' + E.Message);
  {$IFNDEF LCLnogui}
  { 真实 widgetset + 主线程：弹窗安全（GUI 面板应用保留可见性） }
  if GetCurrentThreadId = MainThreadID then
    Application.ShowException(E);
  {$ENDIF}
end;

var
  GRegistry: TStringList = nil;   { 名字 -> TFormClass，已排序，用于查表 }
  GOrder: TStringList = nil;      { 注册顺序，决定默认窗体与 /lw/api/forms 顺序 }
  GServer: TLWServer = nil;
  GCfg: TLWServerConfig;
  GProvider: TLWFormProvider = nil;
  GLoginName: string = '';        { 登录窗体名（'' = 未启用登录）}

procedure EnsureRegistry;
begin
  if GRegistry = nil then
  begin
    GRegistry := TStringList.Create;
    GRegistry.Sorted := True;
    GRegistry.CaseSensitive := False;
    GRegistry.Duplicates := dupIgnore;
  end;
  if GOrder = nil then
  begin
    GOrder := TStringList.Create;
    GOrder.CaseSensitive := False;
    GOrder.Duplicates := dupIgnore;
    GOrder.Sorted := False;
  end;
end;

{ ---------------- TLWFormProvider ---------------- }

{ LCL 装载 .lfm 时会给重名的根组件自动加 _1/_2… 后缀，
  这里把后缀去掉，保证每个会话里窗体名和设计期一致 }
function TLWFormProvider.CreateForm(const AName: string; out AForm: TCustomForm): Boolean;
var
  i: Integer;
  cls: TFormClass;
begin
  AForm := nil;
  Result := False;
  EnsureRegistry;
  i := GRegistry.IndexOf(AName);
  if i < 0 then Exit;
  cls := TFormClass(GRegistry.Objects[i]);
  { 建窗体要串行：TBitBtn 构造时会解码 LCLGlyphs 的标准字形位图，
    多线程同时建会踩坏 Graphics/FPImage 的全局缓存（见 lwbase 的闸门注释） }
  LWLCLEnter;
  try
    AForm := cls.Create(nil);
    AForm.Name := LWStripUniqSuffix(AForm.Name);
  finally
    LWLCLLeave;
  end;
  Result := True;
end;

procedure TLWFormProvider.ListForms(AList: TStrings);
var
  i: Integer;
begin
  AList.Clear;
  EnsureRegistry;
  for i := 0 to GOrder.Count - 1 do
    AList.Add(GOrder[i]);
end;

{ ---------------- TLWApp ---------------- }

class procedure TLWApp.RegisterForm(const AName: string; AClass: TFormClass);
begin
  EnsureRegistry;
  if GRegistry.IndexOf(AName) < 0 then
    GOrder.Add(AName);
  GRegistry.AddObject(AName, TObject(AClass));
end;

class procedure TLWApp.Register(AFormClass: TFormClass);
var
  n: string;
begin
  n := AFormClass.ClassName;
  if (Length(n) > 1) and (n[1] = 'T') then
    Delete(n, 1, 1);
  RegisterForm(n, AFormClass);
end;

class procedure TLWApp.AddAjax(const AName: string; AHandler: TLWAjaxHandler);
begin
  LWRegisterAjax(AName, AHandler);
end;

class procedure TLWApp.SetLogin(ALoginClass: TFormClass);
var
  n: string;
begin
  if ALoginClass = nil then Exit;
  n := ALoginClass.ClassName;
  if (Length(n) > 1) and (n[1] = 'T') then
    Delete(n, 1, 1);
  GLoginName := n;
  { 只进查找表（GRegistry），不进顺序表（GOrder）：
    顺序表决定默认主窗体，登录窗体不能抢这个位置 }
  EnsureRegistry;
  GRegistry.AddObject(n, TObject(ALoginClass));
end;

class function TLWApp.DefaultFormName: string;
begin
  Result := GCfg.DefaultForm;
end;

class function TLWApp.CreateForm(const AName: string; out AForm: TCustomForm): Boolean;
begin
  if GProvider = nil then
    GProvider := TLWFormProvider.Create;
  Result := GProvider.CreateForm(AName, AForm);
end;

class procedure TLWApp.ListForms(AList: TStrings);
begin
  EnsureRegistry;
  AList.Clear;
  AList.Assign(GOrder);
end;

class function TLWApp.FormNames: string;
var
  i: Integer;
begin
  Result := '';
  EnsureRegistry;
  for i := 0 to GOrder.Count - 1 do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + GOrder[i];
  end;
end;

class function TLWApp.Server: TLWServer;
begin
  Result := GServer;
end;

class procedure TLWApp.Run;
var
  i: Integer;
  arg, val: string;
  cfgPath: string;
  ini: TLWConfig;
  portVal: Integer;
  alpineOK, extOK: Boolean;

  { ext 渲染层是否可用：ExtDir 给了看它，否则 ext-<版本> 目录，
    目录名对不上时根下唯一一个 ext-* 也算（与 lwhttp.ExtRootFor 同语义） }
  function ExtReady: Boolean;
  var
    base, cand, one: string;
    sr: TSearchRec;
    cnt: Integer;
  begin
    if GCfg.ExtDir <> '' then
      Exit(FileExists(IncludeTrailingPathDelimiter(GCfg.ExtDir) +
        'build' + PathDelim + 'ext-all.js'));
    base := IncludeTrailingPathDelimiter(GCfg.Root);
    cand := base + 'ext-' + GCfg.DefaultExt;
    if DirectoryExists(cand) then
      Exit(FileExists(IncludeTrailingPathDelimiter(cand) +
        'build' + PathDelim + 'ext-all.js'));
    cnt := 0;
    one := '';
    if FindFirst(base + 'ext-*', faDirectory, sr) = 0 then
    try
      repeat
        if ((sr.Attr and faDirectory) <> 0) and (sr.Name <> '.') and
          (sr.Name <> '..') then
        begin
          Inc(cnt);
          if cnt = 1 then one := sr.Name;
        end;
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
    if (cnt = 1) and (one <> '') then
      Result := FileExists(base + one + PathDelim + 'build' + PathDelim +
        'ext-all.js')
    else
      Result := False;
  end;

  function ValueOf(const APrefix: string; out AValue: string): Boolean;
  begin
    Result := Copy(arg, 1, Length(APrefix)) = APrefix;
    if Result then
      AValue := Copy(arg, Length(APrefix) + 1, MaxInt);
  end;

  { 主题名合法性：拼错时给个提示，别让用户对着"看起来没生效"猜半天 }
  function ThemeKnown(const ATheme: string): Boolean;
  const
    Known: array[0..5] of string =
      ('classic', 'crisp', 'gray', 'material', 'neptune', 'graphite');
  var
    k: Integer;
  begin
    for k := Low(Known) to High(Known) do
      if SameText(Trim(ATheme), Known[k]) then Exit(True);
    Result := False;
  end;

  { 应用配置文件里的三项（命令行随后会再覆盖一遍）。
    只认这三个键：真有别的需求，命令行参数更直接，也避免两处配置打架。 }
  procedure ApplyConfigFile;
  var
    k: Integer;
  begin
    if ini.Path = '' then Exit;
    LWLog('配置文件: ' + ini.Path);
    for k := 0 to ini.Notes.Count - 1 do
      LWLog('  ! ' + ini.Notes[k]);

    if ini.Has(['port']) then
    begin
      portVal := ini.Int(['port'], 0);
      if (portVal >= 1) and (portVal <= 65535) then
        GCfg.Port := portVal
      else
        LWLogFmt('警告: 配置文件 port=%d 非法（应为 1..65535），用默认 %d',
          [portVal, GCfg.Port]);
    end;

    if ini.Has(['theme']) then
    begin
      val := Trim(ini.Str(['theme'], ''));
      if val = '' then
        GCfg.Theme := 'crisp'
      else if ThemeKnown(val) then
        GCfg.Theme := LowerCase(val)
      else
      begin
        LWLog('警告: 配置文件 theme=' + val +
          ' 未收录（classic/crisp/gray/material/neptune/graphite），按 crisp 处理');
        GCfg.Theme := 'crisp';
      end;
    end;

    if ini.Has(['extdir', 'extjs', 'extroot']) then
      GCfg.ExtDir := Trim(ini.Str(['extdir', 'extjs', 'extroot'], ''));

    { 增量补丁（阶段 2）：1/0。灰度期间默认 0，出事直接改回 0 重启 }
    if ini.Has(['patch']) then
      LWServerPatchMode := ini.Int(['patch'], 0) <> 0;

    { 浏览器渲染层：ext（Ext JS，需要 ext-<版本> 目录）| alpine（Alpine.js，
      内置 src\client\alpine.min.js，不需要 ext 目录）。协议两者完全一致 }
    if ini.Has(['client']) then
    begin
      val := LowerCase(Trim(ini.Str(['client'], 'ext')));
      if (val = 'ext') or (val = 'alpine') then
      begin
        GCfg.DefaultClient := val;
        GCfg.ClientExplicit := True;
      end
      else
        LWLog('警告: 配置文件 client=' + ini.Str(['client'], '') +
          ' 非法（应为 ext 或 alpine），按 ext 处理');
    end;
  end;

{$IF FPC_FULLVERSION < 30301}
var
  { FPC 3.2.2 没有 SetTextAutoFlush。这里用 1 字节的文本缓冲达到同样效果：
    缓冲一满（每写 1 个字节）就立刻 write 出去，等价于逐行刷新。
    缓冲区必须一直有效，所以放单元级变量而不是局部变量。 }
  GLWOutFlushBuf: array[0..0] of AnsiChar;
  GLWErrFlushBuf: array[0..0] of AnsiChar;
{$ENDIF}

begin
  { 控制台日志逐行立即写出。FPC 默认只在 stdout 是"真控制台设备"时才
    逐行刷新（OpenStdIO 按 GetFileType 判断）；一旦 stdout 是管道/重定向
    （Windows 11 的 Windows Terminal 用 ConPTY 接管时就是管道），输出会积压
    在缓冲区里直到进程退出 —— 而本服务永不退出，结果就是横幅和日志
    一个字都看不见（程序本身完全正常）。这里强制逐行刷新，两种情形都覆盖。 }
  if LWStdOutOpen then
  begin
    {$IF FPC_FULLVERSION >= 30301}
    SetTextAutoFlush(Output, True);
    SetTextAutoFlush(ErrOutput, True);
    {$ELSE}
    SetTextBuf(Output, GLWOutFlushBuf, SizeOf(GLWOutFlushBuf));
    SetTextBuf(ErrOutput, GLWErrFlushBuf, SizeOf(GLWErrFlushBuf));
    {$ENDIF}
  end;

  { 坑 107：先接管异常，再允许建任何窗体 }
  if GExcHandler = nil then
  begin
    GExcHandler := TLWAppExceptionHandler.Create;
    Application.OnException := @GExcHandler.HandleException;
  end;

  EnsureRegistry;
  { 给 nogui widgetset 打补丁：虚拟显示器 + 关闭双缓冲，
    否则创建任何 TForm 都会 AV }
  LWInstallWidgetSet;
  { 把 LCL 的对话框改道到浏览器：ShowMessage / MessageDlg / InputQuery /
    Application.MessageBox / QuestionDlg / TOpenDialog.Execute / TSaveDialog.Execute。
    必须在创建任何窗体之前完成（TOpenDialog 的 widgetset 类在实例化时就绑定了）。 }
  LWInstallDialogs;
  { 打开 LCL 的 DPI 自适配。窗体是 96 DPI 的虚拟显示器上创建的，而设计窗体的
    IDE 可能跑在 125% / 150% 缩放下（lfm 里 DesignTimePPI=120/144）；
    LCL 拿 Application.Scaled 当开关，nogui 下它默认 False —— 结果是谁都不缩，
    144 DPI 设计的窗体原样下发，浏览器里字体和控件整体大 1.5 倍。
    打开它，TCustomForm.AfterConstruction 会自动把窗体按
    DesignTimePPI -> Monitor.PixelsPerInch(=96) 缩放（几何 + 字体一起）。 }
  Application.Scaled := True;

  if GProvider = nil then
    GProvider := TLWFormProvider.Create;

  GCfg.Port := 8090;
  GCfg.DefaultClient := 'ext';
  GCfg.ClientExplicit := False;
  GCfg.DefaultExt := '7.0.0';
  GCfg.Title := 'lazarusWeb';
  GCfg.SessionTimeoutMin := 20;
  GCfg.Verbose := False;
  GCfg.Theme := 'crisp';
  GCfg.LoginForm := GLoginName;
  GCfg.AjaxCORS := False;
  GCfg.TrustProxy := False;
  GCfg.NoUI := False;
  GCfg.LogFile := '';
  GCfg.Root := LWDefaultRoot(GCfg.DefaultExt);
  GCfg.ExtDir := '';
  if GOrder.Count > 0 then
    GCfg.DefaultForm := GOrder[0];

  { ---- 配置文件（INI）----
    顺序：内置默认值 -> 配置文件 -> 命令行。命令行永远赢，所以
    "同一个 exe 拷十份、各自一个 ini" 和 "临时 --port= 覆盖一下" 都好使。
    --config=<路径> 显式指定；不给就自动找 exe 目录/当前目录里的
    <exe名>.ini 或 lazarusWeb.ini（见 lwconfig）。 }
  cfgPath := '';
  for i := 1 to ParamCount do
    if Copy(ParamStr(i), 1, 9) = '--config=' then
      cfgPath := Trim(Copy(ParamStr(i), 10, MaxInt));
  ini := TLWConfig.Create;
  try
    if cfgPath <> '' then
    begin
      if not ini.Load(cfgPath) then
      begin
        LWLog('错误: 找不到配置文件 -> ' + cfgPath);
        Halt(1);
      end;
    end
    else
      ini.Load('');
    ApplyConfigFile;
  finally
    ini.Free;
  end;

  for i := 1 to ParamCount do
  begin
    arg := ParamStr(i);
    if ValueOf('--port=', val) then
      GCfg.Port := StrToIntDef(val, GCfg.Port)
    else if ValueOf('--root=', val) then
      GCfg.Root := val
    else if ValueOf('--form=', val) then
      GCfg.DefaultForm := val
    else if ValueOf('--ext=', val) then
      GCfg.DefaultExt := val
    else if ValueOf('--client=', val) then
    begin
      val := LowerCase(Trim(val));
      if (val = 'ext') or (val = 'alpine') then
      begin
        GCfg.DefaultClient := val;
        GCfg.ClientExplicit := True;
      end
      else
        LWLog('警告: --client=' + val + ' 非法（应为 ext 或 alpine），忽略');
    end
    else if ValueOf('--extdir=', val) then
      GCfg.ExtDir := val
    else if ValueOf('--theme=', val) then
      GCfg.Theme := val
    else if ValueOf('--title=', val) then
      GCfg.Title := val
    else if ValueOf('--timeout=', val) then
      GCfg.SessionTimeoutMin := StrToIntDef(val, GCfg.SessionTimeoutMin)
    else if arg = '--verbose' then
      GCfg.Verbose := True
    else if arg = '--ajax-cors' then
      GCfg.AjaxCORS := True
    else if arg = '--trust-proxy' then
      GCfg.TrustProxy := True
    else if arg = '--nogui' then
      GCfg.NoUI := True
    else if ValueOf('--patch=', val) then
      LWServerPatchMode := (Trim(val) = '1') or SameText(Trim(val), 'true')
    else if arg = '--patch' then
      LWServerPatchMode := True
    else if ValueOf('--log=', val) then
      GCfg.LogFile := val
    else if (arg = '--help') or (arg = '-h') then
    begin
      WriteLn('用法: ' + ExtractFileName(ParamStr(0)) + ' [选项]');
      WriteLn('  --config=path         配置文件（缺省自动找 <exe名>.ini / lazarusWeb.ini）');
      WriteLn('  --port=8090           监听端口');
      WriteLn('  --root=C:\LazarusWeb  项目根目录（含 ext-<版本> 目录）；缺省取当前目录');
      WriteLn('  --form=Name           默认窗体名');
      WriteLn('  --client=ext          浏览器渲染层：ext | alpine；不指定时自动探测（都在优先 alpine）');
      WriteLn('  --ext=7.0.0           默认 Ext 版本（对应 ext-<版本> 目录，任意版本号都行）');
      WriteLn('  --extdir=目录         ext-js 目录（配置文件 extdir 的等价物）');
      WriteLn('  --theme=crisp         主题（classic/crisp/gray/material/neptune/graphite，?theme= 可覆盖）');
      WriteLn('  --title=标题          浏览器标签页标题（缺省取 Application.Title）');
      WriteLn('  --timeout=20          会话空闲超时（分钟）');
      WriteLn('  --verbose             打印每个请求');
      WriteLn('  --ajax-cors           /lw/ajax/* 回 CORS 头（第三方站点直接调）');
      WriteLn('  --trust-proxy         在 nginx/Caddy 反代后面：取 X-Forwarded-For 作客户端 IP');
      WriteLn('  --nogui               GUI 构建下也不弹服务端面板（服务化部署）');
      WriteLn('  --patch=1             增量补丁（事件只回变化的 ops，默认关；老前端自动退回全量）');
      WriteLn('  --log=path            把服务端日志追加写入文件');
      WriteLn('已注册窗体: ' + FormNames);
      Halt(0);
    end;
  end;

  { 浏览器标签页标题：--title= / 配置文件 > Application.Title > 内置默认。
    标题仍是内置默认 'lazarusWeb'（说明用户没显式指定）时取 Application.Title，
    与桌面程序"标题栏显示 Application.Title"的语义一致；
    gallery.lpr 里的 Application.Title 赋值发生在 Run 之前，此处必然已就绪。 }
  if (GCfg.Title = 'lazarusWeb') and (Application.Title <> '') then
    GCfg.Title := Application.Title;

  GCfg.Root := LWResolveRoot(GCfg.Root, GCfg.DefaultExt);
  if not DirectoryExists(GCfg.Root) then
  begin
    LWLog('错误: 项目根目录不存在 -> ' + GCfg.Root);
    Halt(1);
  end;
  { ext-js 目录：配置/命令行给了就用它（相对路径按 exe 目录、当前目录展开），
    没给（或给的空目录/不存在）就退回"从根目录找 ext-<版本>"。
    根目录下只有一个 ext-* 时，服务端会直接用那个目录，不管它叫什么名字；
    "ext-all.js 到底在不在"由启动横幅统一检查（见 lwhttp.PrintBanner）。 }
  GCfg.ExtDir := LWResolveExtDir(GCfg.ExtDir);

  { 渲染层自动探测（坑 92）：配置文件 client= 和命令行 --client= 都没给时，
    检查 alpine.min.js / lw-alpine.js 与 ext-all.js 是否真实存在——
    两个渲染层都可用 → 优先 alpine；只有一个 → 用在的那个；
    都没有 → 保持 ext（启动横幅会给出白屏警告）。 }
  if not GCfg.ClientExplicit then
  begin
    alpineOK := (LWFindClientFile('alpine.min.js', GCfg.Root) <> '') and
      (LWFindClientFile('lw-alpine.js', GCfg.Root) <> '');
    extOK := ExtReady;
    if alpineOK then
      GCfg.DefaultClient := 'alpine'
    else if not extOK then
    begin
      LWLog('警告: 未找到 alpine.min.js 也没有可用的 ext-all.js，');
      LWLog('      浏览器渲染层保持 ext 默认值 —— 两种渲染层都会白屏，请部署 src\client\ 或 ext-<版本>\。');
    end;
  end;

  { 客户端脚本缺失不会让服务报错，但浏览器一定白屏 —— 启动时就拦住。
    常见于只拷了一个 ext-<版本> 目录的自包含部署。 }
  if LWFindClientFile('lw.js', GCfg.Root) = '' then
  begin
    LWLog('警告: 未找到客户端脚本 lw.js，浏览器将白屏！');
    LWLog('      把 src\client\ 拷到部署目录（或用 root\lw\ 扁平部署，或把文件拷到 exe 同目录）。');
  end;

  GServer := TLWServer.Create(GCfg, @GProvider.CreateForm, @GProvider.ListForms);
  try
    { 横幅必须打在 Start 之前：Start 进入 accept 循环后不再返回 }
    GServer.PrintBanner;
    { --log= 开文件日志：服务化部署留证据；GUI 面板只显示到窗口里 }
    if GCfg.LogFile <> '' then
      LWOpenLogFile(GCfg.LogFile);
    { TLWServer.Start 一进 accept 循环就永不返回，所以 Start 与
      "服务运行期间做什么" 都交给 LWRunPanel：
      - nogui 构建 / --nogui：同线程跑 accept（历史行为，Ctrl+C 退出）；
      - GUI 构建：accept 放后台线程，主线程跑服务端面板消息循环。 }
    LWRunPanel(GServer, GCfg);
    LWStopTrace('lwapp ① LWRunPanel 返回');
  finally
    GServer.Free;
    GServer := nil;
    LWStopTrace('lwapp ② 服务器对象已释放');
  end;
end;

finalization
  LWStopTrace('lwapp ③ 单元收尾开始');
  GServer.Free;
  if GRegistry <> nil then GRegistry.Free;
  if GProvider <> nil then GProvider.Free;
  LWStopTrace('lwapp ④ 单元收尾完毕（接下来是 RTL/GTK 收尾）');

end.
