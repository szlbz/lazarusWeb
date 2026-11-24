unit umain;
{ pluginsDemo :: 宿主（主程序 exe）

  左边是 TLWSideMenu（框架的 LCL 侧栏菜单组件），右边是 TPageControl。
  菜单项不是写死的 —— 由插件清单扫描结果动态生成：一个 *.plugin.ini 一项，
  标题取 title、分组取 group。group 用 / 表示层级，所以可以生成多级菜单：

      业务管理              <- 清单 group=业务管理
        仪表盘              <- 清单 group=业务管理
        报表汇总            <- 清单 group=业务管理
      系统管理              <- 清单 group=系统管理/数据维护 的第一段
        数据维护            <- 第二段
          便签              <- title

  点菜单 -> 在 PageControl 上新增一个 TTabSheet，页内放 TLWHTMLFrame，
  里面是一个指向 /p/<插件名>/ 的 iframe —— 插件本身是独立 exe、独立端口，
  由宿主用 lwroute 反向代理，所以页里显示的是插件进程真正的页面，
  业务处理也全部发生在插件进程内。

  热更新：插件 exe 跑的是 .run 下的副本，原始 exe 随时可以重编。
  重编后点菜单（或「热更新当前插件」），宿主停旧进程 -> 复制新 exe ->
  起新进程 -> 页内 iframe 换 URL 重新加载，宿主自己不重启。

  「重新扫描插件」：不重启宿主也能让菜单跟着磁盘变 —— 新增插件目录并放好
  清单/exe，点一下就注册路由、拉起进程、菜单多出一项；删掉目录再点一下，
  菜单项消失、页签关闭、进程停掉、路由摘除。
}
{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls, ExtCtrls, Menus, Graphics,
  lwform, lwapp, lwweb, lwsidemenu, upluginproc;

type
  TMainForm = class(TLWForm)
    pnlTop: TPanel;
    lblTitle: TLabel;
    btnRescan: TButton;
    btnHot: TButton;
    lblHot: TLabel;
    pcMain: TPageControl;
    sbMain: TStatusBar;
    smMain: TLWSideMenu;
    procedure FormCreate(Sender: TObject);
    procedure pcMainChange(Sender: TObject);
    procedure btnHotClick(Sender: TObject);
    procedure btnRescanClick(Sender: TObject);
    procedure MenuItemClick(Sender: TObject);
  private
    FTabs: TStringList;      { 插件名 -> TTabSheet（重扫描后下标会变，按名找页） }
    FActiveName: string;     { 当前高亮的插件路由名 }
    procedure BuildMenu;
    procedure SyncChecked;
    procedure LoadMenuIcon(MI: TMenuItem; const AFile: string);
    procedure OpenPlugin(AIndex: Integer);
    function TabOfName(const AName: string): TTabSheet;
    function IframeHTML(AIndex: Integer): string;
    procedure ReloadTab(AIndex: Integer);
    procedure RefreshTabs;
    procedure UpdateHotLabel;
    procedure SetStatus(const AText: string);
  public
    destructor Destroy; override;
  end;

procedure RegisterMain;

implementation

{$R *.lfm}

procedure RegisterMain;
begin
  TLWApp.RegisterForm('Main', TMainForm);
end;

destructor TMainForm.Destroy;
begin
  FreeAndNil(FTabs);
  inherited Destroy;
end;

procedure TMainForm.FormCreate(Sender: TObject);
begin
  if FTabs = nil then
    FTabs := TStringList.Create;
  FActiveName := '';

  { 菜单完全由扫描结果生成：换插件目录不用改这里一行代码 }
  BuildMenu;
  UpdateHotLabel;

  if PlugCount = 0 then
  begin
    SetStatus('没有发现任何插件：检查 pluginsDemo\*\*.plugin.ini');
    Exit;
  end;
  SetStatus(Format('已发现 %d 个插件进程，点左侧菜单在右侧打开', [PlugCount]));
  { 默认打开第一个插件，避免首页空白 }
  OpenPlugin(0);
end;

{ ---------------- 侧栏菜单（TLWSideMenu，运行期按扫描结果建树） ----------------

  顶层项 = 可折叠分组（Group），叶子项 = 插件，点击回发 OnClick。
  重扫描后整棵树重建：writer 每次序列化窗口都会把菜单树重新下发，
  前端发现签名变了就整块重渲，所以菜单能跟着磁盘变。 }

procedure TMainForm.BuildMenu;
var
  i, k, idx: Integer;
  p: TPlugPlugin;
  grp, mi: TMenuItem;
  gpath, seg, key, parentKey: string;
  segs, map: TStringList;
begin
  smMain.Items.Clear;

  { map：分组路径 -> TMenuItem。同一次建树里复用，避免逐项遍历查找；
    清单里 group=数据看板/运营分析 这样写就生成两级分组，任意层级都行 }
  map := TStringList.Create;
  segs := TStringList.Create;
  segs.Delimiter := '/';
  segs.StrictDelimiter := True;
  try
    map.CaseSensitive := False;
    for i := 0 to PlugCount - 1 do
    begin
      p := PlugGet(i);
      if p = nil then Continue;

      grp := nil;
      gpath := Trim(p.Group);
      if gpath = '' then
        gpath := '插件';               { 清单没写 group：归入默认分组 }
      if gpath = '-' then
        gpath := '';                   { group=- ：插件直接作为顶层菜单行 }

      if gpath <> '' then
      begin
        parentKey := '';
        segs.DelimitedText := gpath;
        for k := 0 to segs.Count - 1 do
        begin
          seg := Trim(segs[k]);
          if seg = '' then Continue;
          if parentKey = '' then
            key := seg
          else
            key := parentKey + '/' + seg;

          idx := map.IndexOf(key);
          if idx >= 0 then
            grp := TMenuItem(map.Objects[idx])
          else
          begin
            grp := TMenuItem.Create(smMain);
            grp.Caption := seg;
            if parentKey = '' then
              smMain.Items.Add(grp)
            else
              TMenuItem(map.Objects[map.IndexOf(parentKey)]).Add(grp);
            map.AddObject(key, grp);
          end;
          parentKey := key;
        end;
      end;

      mi := TMenuItem.Create(smMain);
      mi.Caption := p.Title;
      mi.Tag := i;                     { 下标 -> 插件，重扫描后由 RefreshTabs 修正页签 }
      mi.OnClick := @MenuItemClick;
      LoadMenuIcon(mi, p.Icon);
      if grp <> nil then
        grp.Add(mi)
      else
        smMain.Items.Add(mi);
    end;
  finally
    segs.Free;
    map.Free;
  end;

  smMain.HeaderCaption := Format('插件导航（%d）', [PlugCount]);
  SyncChecked;
end;

{ 菜单图标：清单 icon= 指到文件就读进 TMenuItem.Bitmap，
  writer 会把它转成 PNG data URI 下发（没有图标时前端留占位块保证对齐） }
procedure TMainForm.LoadMenuIcon(MI: TMenuItem; const AFile: string);
begin
  if (MI = nil) or (AFile = '') or (not FileExists(AFile)) then Exit;
  try
    MI.Bitmap.LoadFromFile(AFile);
  except
    { nogui 下个别格式导不出：没图标也不影响菜单结构和点击 }
  end;
end;

{ 菜单项的 Checked 就是浏览器侧栏的高亮状态（writer 把它序列化过去）}
procedure TMainForm.SyncChecked;

  procedure Walk(MI: TMenuItem; AActive: Integer);
  var
    i: Integer;
  begin
    for i := 0 to MI.Count - 1 do
      if MI.Items[i].Count > 0 then
        Walk(MI.Items[i], AActive)
      else
        MI.Items[i].Checked := (AActive >= 0) and (MI.Items[i].Tag = AActive);
  end;

var
  idx: Integer;
begin
  idx := PlugIndexOf(FActiveName);
  Walk(smMain.Items, idx);
end;

procedure TMainForm.MenuItemClick(Sender: TObject);
begin
  if Sender is TMenuItem then
    OpenPlugin(TMenuItem(Sender).Tag);
end;

{ ---------------- 页签 ---------------- }

function TMainForm.TabOfName(const AName: string): TTabSheet;
var
  i: Integer;
begin
  Result := nil;
  if (FTabs = nil) or (AName = '') then Exit;
  i := FTabs.IndexOf(AName);
  if i >= 0 then
    Result := TTabSheet(FTabs.Objects[i]);
end;

procedure TMainForm.OpenPlugin(AIndex: Integer);
var
  p: TPlugPlugin;
  ts: TTabSheet;
  didHot: Boolean;
begin
  p := PlugGet(AIndex);
  if p = nil then Exit;

  { 插件 exe 在启动后被重新编译过：先热更新，再打开 }
  didHot := False;
  if PlugSourceChanged(AIndex) then
  begin
    if PlugHotUpdate(AIndex) then
      didHot := True
    else
      SetStatus('热更新失败：「' + p.Title + '」继续使用旧进程');
  end;

  ts := TabOfName(p.Name);
  if ts <> nil then
  begin
    ts.Tag := AIndex;
    ts.Caption := p.Title;
    FActiveName := p.Name;
    pcMain.ActivePage := ts;
    SyncChecked;
    if didHot then
    begin
      ReloadTab(AIndex);
      SetStatus(Format('已热更新「%s」并切回页签（pid=%d）', [p.Title, p.Proc.ProcessID]));
    end
    else
      SetStatus('切换到已有页签：' + p.Title + '（同一插件只保留一页）');
    UpdateHotLabel;
    Exit;
  end;

  ts := TTabSheet.Create(pcMain);
  ts.PageControl := pcMain;
  ts.Name := 'tsPlugin' + p.Name;
  ts.Caption := p.Title;
  ts.Tag := AIndex;
  { nogui 下运行期新建的 TTabSheet 没有窗口句柄，LCL 不会替它算客户区，
    序列化出去就是 0x0；浏览器端虽然有 align=client 的二次拉伸，这里还是
    显式给一个接近页签客户区的盒子作双保险（28 ≈ 页签条高度） }
  if ts.Width <= 0 then
    ts.Width := pcMain.Width;
  if ts.Height <= 0 then
    ts.Height := pcMain.Height - 28;

  with TLWHTMLFrame.Create(ts) do
  begin
    Name := 'hfPlugin' + p.Name;
    Parent := ts;
    Align := alClient;
    SetBounds(0, 0, ts.Width, ts.Height);
    BevelOuter := bvNone;
    BorderStyle := bsNone;
    HTML.Text := IframeHTML(AIndex);
  end;

  FTabs.AddObject(p.Name, ts);
  FActiveName := p.Name;
  pcMain.ActivePage := ts;
  SyncChecked;

  if didHot then
    SetStatus(Format('已热更新并打开「%s」：/p/%s/ -> 127.0.0.1:%d',
      [p.Title, p.Name, p.Port]))
  else
    SetStatus(Format('已打开「%s」：页内 iframe -> /p/%s/（插件独立进程，端口 %d）',
      [p.Title, p.Name, p.Port]));
  UpdateHotLabel;
end;

function TMainForm.IframeHTML(AIndex: Integer): string;
var
  p: TPlugPlugin;
begin
  p := PlugGet(AIndex);
  if p = nil then Exit('');
  Result := '<iframe src="' + PlugFrameURL(AIndex) + '" ' +
    'style="display:block;width:100%;height:100%;border:0;background:#ffffff" ' +
    'title="' + p.Title + '"></iframe>';
end;

procedure TMainForm.ReloadTab(AIndex: Integer);
var
  p: TPlugPlugin;
  ts: TTabSheet;
  c: TComponent;
begin
  p := PlugGet(AIndex);
  if p = nil then Exit;
  ts := TabOfName(p.Name);
  if ts = nil then Exit;
  c := ts.FindComponent('hfPlugin' + p.Name);
  if c is TLWHTMLFrame then
  begin
    { 换掉 iframe 的 src（版本号变了 = 重新建 iframe 元素），
      插件进程重启后的新页面才会真正加载 }
    TLWHTMLFrame(c).HTML.Text := IframeHTML(AIndex);
  end;
end;

{ 重扫描之后：已有页签按插件名重新对上新的下标；插件没了的页签关掉 }
procedure TMainForm.RefreshTabs;
var
  i, idx: Integer;
  ts: TTabSheet;
  p: TPlugPlugin;
begin
  if FTabs = nil then Exit;
  for i := FTabs.Count - 1 downto 0 do
  begin
    ts := TTabSheet(FTabs.Objects[i]);
    idx := PlugIndexOf(FTabs[i]);
    if idx < 0 then
    begin
      if pcMain.ActivePage = ts then
        pcMain.ActivePage := nil;
      FTabs.Delete(i);
      ts.Free;
      Continue;
    end;
    p := PlugGet(idx);
    ts.Tag := idx;
    ts.Caption := p.Title;
  end;

  if (FActiveName <> '') and (PlugIndexOf(FActiveName) < 0) then
    FActiveName := '';
  SyncChecked;
end;

{ ---------------- 按钮 ---------------- }

procedure TMainForm.btnHotClick(Sender: TObject);
var
  i: Integer;
  p: TPlugPlugin;
begin
  if FActiveName = '' then
  begin
    SetStatus('先在左侧点一个插件，让它出现在页签里，再热更新');
    Exit;
  end;
  i := PlugIndexOf(FActiveName);
  p := PlugGet(i);
  if p = nil then Exit;

  SetStatus('正在热更新「' + p.Title + '」：停旧进程、换新 exe、重新拉起…');
  if PlugHotUpdate(i) then
  begin
    ReloadTab(i);
    SetStatus(Format('已热更新「%s」：新进程 pid=%d，页内 iframe 已重新加载',
      [p.Title, p.Proc.ProcessID]));
  end
  else
    SetStatus('热更新失败：「' + p.Title + '」未启动（检查 exe 与 .run 目录）');
  UpdateHotLabel;
end;

procedure TMainForm.btnRescanClick(Sender: TObject);
var
  before, after: Integer;
begin
  before := PlugCount;
  SetStatus('正在重新扫描插件目录…');
  after := PlugRescan;

  { 扫描结果变了：菜单重建、页签重挂下标、插件 exe 状态重算 }
  BuildMenu;
  RefreshTabs;
  UpdateHotLabel;

  if after = 0 then
    SetStatus('重新扫描完成：没有发现任何插件（检查 pluginsDemo\*\*.plugin.ini）')
  else if after > before then
    SetStatus(Format('重新扫描完成：新增 %d 个插件，共 %d 个，左侧菜单已更新',
      [after - before, after]))
  else if after < before then
    SetStatus(Format('重新扫描完成：移除 %d 个插件，共 %d 个，左侧菜单已更新',
      [before - after, after]))
  else
    SetStatus(Format('重新扫描完成：共 %d 个插件，菜单已按清单刷新', [after]));
end;

procedure TMainForm.pcMainChange(Sender: TObject);
var
  ts: TTabSheet;
  p: TPlugPlugin;
begin
  ts := pcMain.ActivePage;
  if ts = nil then Exit;
  { 运行期新建页签时 LCL 会先触发 OnChange（此刻还没登记进 FTabs），跳过 }
  if (FTabs = nil) or (FTabs.IndexOfObject(ts) < 0) then Exit;
  p := PlugGet(ts.Tag);
  if p = nil then Exit;

  FActiveName := p.Name;
  SyncChecked;
  if PlugSourceChanged(ts.Tag) then
    SetStatus('当前页：' + ts.Caption + '（检测到该插件已重编，可点「热更新当前插件」）')
  else
    SetStatus('当前页：' + ts.Caption + '（独立进程，端口 ' + IntToStr(p.Port) + '）');
end;

procedure TMainForm.UpdateHotLabel;
var
  n: Integer;
begin
  n := PlugChangedCount;
  if n > 0 then
    lblHot.Caption := '检测到 ' + IntToStr(n) + ' 个插件已重编，可热更新'
  else
    lblHot.Caption := '插件 exe 未变化';
end;

procedure TMainForm.SetStatus(const AText: string);
begin
  sbMain.Panels[0].Text := AText;
end;

end.
