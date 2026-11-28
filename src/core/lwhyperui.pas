{
  lazarusWeb :: lwhyper 插件模式的内置页面（登录页 / 工作台首页）

  这些页面由 lwhyper 自己渲染，不走 lwapp：
    /            工作台（左侧按清单分组列插件，右侧 iframe 显示 /p/<名>/）
    /login       登录页（POST /lw/login）

  只依赖 SysUtils，HTML 全部字符串拼装 —— 保持 lwhyper 独立进程的轻量，
  不想为了两页界面把整包 LCL 拖进来。
}
unit lwhyperui;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, lwpwa;

type
  { 工作台里的一行插件。由 TLWHyperServer 从 TLWHyperPluginManager 填充，
    本单元不认识插件管理器，避免循环依赖 }
  TLWHyperUIItem = record
    Name: string;
    Title: string;
    Group: string;    { 清单 group=，'/' 表示层级，'-' 表示顶层 }
    Roles: string;    { 清单 roles=，空 = 所有已登录用户 }
    Port: Word;
    Alive: Boolean;
  end;
  TLWHyperUIItems = array of TLWHyperUIItem;

const
  HYPER_BRAND = 'lazarusWeb · 插件工作台';

function HyperHTMLEsc(const S: string): string;
{ 只允许站内相对路径跳转，挡掉 //evil.com 这类开放重定向 }
function HyperSafeNext(const ANext: string): string;
{ 百分号编码：给 form action 里的 next 用 }
function HyperURLEnc(const S: string): string;

{ 登录页。AErr 非空时红条提示；AHint 是给演示账号用的灰字提示 }
function HyperLoginPage(const AErr, ANext, AHint, ABrand: string): string;

{ 工作台。AItems 只包含当前账号有权限的插件；ATotal 是清单里的总数，
  用来提示"有 n 个插件被权限隐藏" }
function HyperWorkbenchPage(const AUser, ADisplay, ARoles, ARoleText: string;
  const AItems: TLWHyperUIItems; ATotal: Integer;
  const ABrand: string): string;

{ --no-auth 调试模式的直链首页（没有登录态，装不了工作台） }
function HyperOpenIndexPage(const AItems: TLWHyperUIItems; ATotal: Integer;
  const ABrand: string): string;

implementation

function HyperHTMLEsc(const S: string): string;
begin
  Result := S;
  Result := StringReplace(Result, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
  Result := StringReplace(Result, '''', '&#39;', [rfReplaceAll]);
end;

function HyperURLEnc(const S: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
       ((c >= '0') and (c <= '9')) or (c = '-') or (c = '_') or (c = '.') or
       (c = '~') then
      Result := Result + c
    else
      Result := Result + '%' + IntToHex(Ord(c), 2);
  end;
end;

function HyperSafeNext(const ANext: string): string;
var
  s: string;
begin
  s := Trim(ANext);
  if s = '' then Exit('/');
  if s[1] <> '/' then Exit('/');
  if Copy(s, 1, 2) = '//' then Exit('/');
  if Pos('\', s) > 0 then Exit('/');
  Result := s;
end;

{ 两页共用的样式。放一处，改配色只改这一块 }
function PageCSS: string;
begin
  Result :=
    ':root{--bg:#f5f6f8;--panel:#ffffff;--line:#e3e6ea;--text:#1f2328;' +
    '--muted:#6b7280;--accent:#2f6feb;--accent-weak:#eaf1ff;--danger:#c0392b;' +
    '--ok:#1a7f37;--shadow:0 1px 2px rgba(16,24,40,.06),0 8px 24px rgba(16,24,40,.06)}' +
    '@media (prefers-color-scheme:dark){:root{--bg:#16181d;--panel:#1e2127;' +
    '--line:#2c3038;--text:#e6e8eb;--muted:#9aa3ad;--accent:#6ea0ff;' +
    '--accent-weak:#20293a;--danger:#ff7b72;--ok:#56d364;' +
    '--shadow:0 1px 2px rgba(0,0,0,.4),0 8px 24px rgba(0,0,0,.35)}}' +
    '*{box-sizing:border-box}' +
    'html,body{height:100%}' +
    'body{margin:0;background:var(--bg);color:var(--text);' +
    'font:14px/1.6 system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif;' +
    '-webkit-font-smoothing:antialiased}' +
    'code{font-family:ui-monospace,Consolas,monospace;font-size:.92em;' +
    'background:var(--accent-weak);padding:1px 5px;border-radius:4px}' +
    'a{color:var(--accent);text-decoration:none}';
end;

function HyperLoginPage(const AErr, ANext, AHint, ABrand: string): string;
begin
  Result :=
    '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>登录 · ' + HyperHTMLEsc(ABrand) + '</title><style>' + PageCSS +
    'body{display:flex;align-items:center;justify-content:center;padding:24px}' +
    '.card{width:100%;max-width:380px;background:var(--panel);border:1px solid var(--line);' +
    'border-radius:14px;box-shadow:var(--shadow);padding:28px 28px 22px}' +
    '.brand{font-size:12px;letter-spacing:.08em;text-transform:uppercase;' +
    'color:var(--muted);margin-bottom:6px}' +
    'h1{font-size:20px;margin:0 0 4px}' +
    '.sub{color:var(--muted);font-size:13px;margin:0 0 20px}' +
    'label{display:block;font-size:13px;color:var(--muted);margin:14px 0 6px}' +
    'input[type=text],input[type=password]{width:100%;padding:10px 12px;font-size:14px;' +
    'color:var(--text);background:var(--bg);border:1px solid var(--line);border-radius:8px;' +
    'outline:none;transition:border-color .15s,box-shadow .15s}' +
    'input:focus{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-weak)}' +
    'button{width:100%;margin-top:20px;padding:11px 14px;font-size:14px;font-weight:600;' +
    'color:#fff;background:var(--accent);border:0;border-radius:8px;cursor:pointer}' +
    'button:hover{filter:brightness(1.06)}' +
    '.err{margin:0 0 4px;padding:9px 12px;border-radius:8px;font-size:13px;' +
    'color:var(--danger);background:rgba(192,57,43,.08);border:1px solid rgba(192,57,43,.25)}' +
    '.hint{margin:16px 0 0;font-size:12px;color:var(--muted);line-height:1.7}' +
    '</style>' + LWPWAHeadHtml('/') + '</head><body><form class="card" method="post" action="/lw/login?next=' +
    HyperURLEnc(HyperSafeNext(ANext)) + '" autocomplete="off">' +
    '<div class="brand">' + HyperHTMLEsc(ABrand) + '</div>' +
    '<h1>登录</h1>' +
    '<p class="sub">本工作台默认要求登录，未登录只能看到这一页。</p>';
  if AErr <> '' then
    Result := Result + '<p class="err">' + HyperHTMLEsc(AErr) + '</p>';
  Result := Result +
    '<input type="hidden" name="next" value="' + HyperHTMLEsc(HyperSafeNext(ANext)) + '">' +
    '<label for="u">用户名</label>' +
    '<input id="u" name="user" type="text" autofocus autocapitalize="off" ' +
    'autocorrect="off" spellcheck="false" placeholder="admin">' +
    '<label for="p">口令</label>' +
    '<input id="p" name="pass" type="password" placeholder="••••••">' +
    '<button type="submit">登录</button>';
  if AHint <> '' then
    Result := Result + '<p class="hint">' + AHint + '</p>';
  Result := Result +
    '<p class="hint">权限在插件清单 <code>roles=</code> 里声明；' +
    '未登录时直接访问 <code>/p/&lt;名&gt;/</code> 会被送回本页。</p>' +
    '</form>' + LWPWAScriptHtml('/') + '</body></html>';
end;

{ 角色串转中文，工作台顶栏用；未知角色原样显示 }
function NiceRoles(const ARoles: string): string;
var
  s, item: string;
  p: Integer;
begin
  Result := '';
  s := ARoles;
  while s <> '' do
  begin
    p := Pos(',', s);
    if p > 0 then
    begin
      item := Trim(Copy(s, 1, p - 1));
      s := Copy(s, p + 1, MaxInt);
    end
    else
    begin
      item := Trim(s);
      s := '';
    end;
    if item = '' then Continue;
    if SameText(item, 'admin') then item := '管理员'
    else if SameText(item, 'analyst') then item := '分析师'
    else if SameText(item, 'guest') then item := '访客';
    if Result <> '' then Result := Result + '、';
    Result := Result + item;
  end;
end;

{ 分组标题：'系统管理/数据维护' -> '系统管理 / 数据维护' }
function GroupLabel(const AGroup: string): string;
begin
  Result := StringReplace(AGroup, '/', ' / ', [rfReplaceAll]);
end;

function HyperWorkbenchPage(const AUser, ADisplay, ARoles, ARoleText: string;
  const AItems: TLWHyperUIItems; ATotal: Integer; const ABrand: string): string;
var
  i, j, hidden: Integer;
  g, who, initial: string;
  nav, countText: string;
  groups: TStringList;   { 分组出现顺序：清单按文件名排序，同一分组可能不连续 }
begin
  who := ADisplay;
  if (who = '') or SameText(who, AUser) then who := AUser;
  if ARoleText <> '' then
    who := who + ' · ' + NiceRoles(ARoleText);

  { 先按"首次出现"定分组顺序，再把同组的插件并到一起渲染 ——
    否则 dash(业务管理) / notes(系统管理) / reports(业务管理) 会让
    「业务管理」标题出现两次 }
  groups := TStringList.Create;
  try
    groups.CaseSensitive := False;
    for i := 0 to High(AItems) do
    begin
      g := AItems[i].Group;
      if g = '-' then g := '';
      if groups.IndexOf(g) < 0 then groups.Add(g);
    end;

    nav := '';
    for j := 0 to groups.Count - 1 do
    begin
      g := groups[j];
      if g <> '' then
        nav := nav + '<div class="grp">' + HyperHTMLEsc(GroupLabel(g)) + '</div>';
      for i := 0 to High(AItems) do
      begin
        if AItems[i].Group = '-' then
        begin
          if g <> '' then Continue;
        end
        else if not SameText(AItems[i].Group, g) then
          Continue;

        initial := '';
        if AItems[i].Title <> '' then initial := Copy(AItems[i].Title, 1, 1);
        nav := nav + '<a class="item" href="#" data-name="' +
          HyperHTMLEsc(AItems[i].Name) + '" onclick="return lwOpen(this)">' +
          '<span class="av">' + HyperHTMLEsc(initial) + '</span>' +
          '<span class="nm">' + HyperHTMLEsc(AItems[i].Title) + '</span>' +
          '<span class="dot' + BoolToStr(not AItems[i].Alive, ' off', '') + '"></span>' +
          '</a>';
      end;
    end;
  finally
    groups.Free;
  end;
  if nav = '' then
    nav := '<div class="empty-nav">当前账号没有可打开的插件</div>';

  hidden := ATotal - Length(AItems);
  if hidden > 0 then
    countText := '<p>清单里共 <b>' + IntToStr(ATotal) + '</b> 个插件，当前角色可用 <b>' +
      IntToStr(Length(AItems)) + '</b> 个。</p>'
  else
    countText := '<p>清单里共 <b>' + IntToStr(ATotal) + '</b> 个插件，当前角色全部可用。</p>';

  Result :=
    '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>' + HyperHTMLEsc(ABrand) + '</title><style>' + PageCSS +
    'body{display:flex;flex-direction:column}' +
    'header{display:flex;align-items:center;gap:14px;padding:10px 18px;' +
    'background:var(--panel);border-bottom:1px solid var(--line);flex:0 0 auto}' +
    '.logo{width:26px;height:26px;border-radius:7px;background:var(--accent);' +
    'color:#fff;display:flex;align-items:center;justify-content:center;' +
    'font-weight:700;font-size:13px}' +
    '.brand{font-weight:600;letter-spacing:.01em}' +
    '.grow{flex:1}' +
    '.who{font-size:13px;color:var(--muted)}' +
    'form{margin:0}' +
    '.out{padding:6px 12px;font-size:13px;color:var(--text);background:var(--bg);' +
    'border:1px solid var(--line);border-radius:7px;cursor:pointer}' +
    '.out:hover{border-color:var(--accent);color:var(--accent)}' +
    'main{flex:1;display:flex;min-height:0}' +
    'aside{width:238px;flex:0 0 auto;background:var(--panel);' +
    'border-right:1px solid var(--line);overflow:auto;padding:12px 10px 20px}' +
    '.grp{margin:12px 8px 6px;font-size:12px;font-weight:600;letter-spacing:.04em;' +
    'color:var(--muted)}' +
    '.grp:first-child{margin-top:2px}' +
    '.item{display:flex;align-items:center;gap:10px;padding:8px 10px;border-radius:8px;' +
    'color:var(--text);margin:2px 0}' +
    '.item:hover{background:var(--bg)}' +
    '.item.active{background:var(--accent-weak);color:var(--accent);font-weight:600}' +
    '.av{width:22px;height:22px;flex:0 0 auto;border-radius:6px;background:var(--accent-weak);' +
    'color:var(--accent);display:flex;align-items:center;justify-content:center;' +
    'font-size:12px;font-weight:700}' +
    '.item.active .av{background:var(--accent);color:#fff}' +
    '.nm{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
    '.dot{width:7px;height:7px;border-radius:50%;background:var(--ok);flex:0 0 auto}' +
    '.dot.off{background:#c9ccd1}' +
    '.empty-nav{margin:12px 8px;font-size:13px;color:var(--muted)}' +
    'section{flex:1;min-width:0;display:flex;flex-direction:column;min-height:0}' +
    '.stage{flex:1;position:relative;display:flex;min-height:0}' +
    '#view{flex:1;width:100%;height:100%;border:0;background:var(--panel);display:none}' +
    '.welcome{position:absolute;inset:0;display:flex;flex-direction:column;' +
    'align-items:center;justify-content:center;gap:10px;color:var(--muted);' +
    'text-align:center;padding:24px}' +
    '.welcome h2{margin:0;font-size:18px;color:var(--text)}' +
    '.welcome p{margin:0;font-size:13px;max-width:460px}' +
    '.tip{font-size:12px;color:var(--muted);padding:6px 18px;' +
    'border-top:1px solid var(--line);background:var(--panel)}' +
    '@media (max-width:720px){aside{width:168px}.who{display:none}}' +
    '</style>' + LWPWAHeadHtml('/') + '</head><body>' +
    '<header><div class="logo">lw</div>' +
    '<div class="brand">' + HyperHTMLEsc(ABrand) + '</div><div class="grow"></div>' +
    '<div class="who">' + HyperHTMLEsc(who) + '</div>' +
    '<form method="post" action="/lw/logout"><button class="out" type="submit">注销</button></form>' +
    '</header><main><aside>' + nav + '</aside><section><div class="stage">' +
    '<div class="welcome" id="welcome"><h2>从左侧选择一个插件</h2>' +
    '<p>每个插件是独立进程，页面经由宿主 <code>/p/&lt;名&gt;/</code> 反向代理；' +
    '未登录或角色不足的请求到不了插件进程。</p>' + countText +
    '</div>' +
    '<iframe id="view" title="插件页面"></iframe>' +
    '</div>' +
    '<div class="tip">登录状态由 lwhyper 自身维护（内存会话，Cookie lwpsid）；' +
    '关闭浏览器或空闲超时后需重新登录。</div>' +
    '</section></main>' +
    '<script>' +
    'function lwOpen(a){' +
    'var n=a.getAttribute("data-name");' +
    'var it=document.querySelectorAll(".item");' +
    'for(var i=0;i<it.length;i++){it[i].className="item";}' +
    'a.className="item active";' +
    'document.getElementById("welcome").style.display="none";' +
    'var f=document.getElementById("view");f.style.display="block";' +
    'f.src="/p/"+n+"/";return false;}' +
    '</script>' + LWPWAScriptHtml('/') + '</body></html>';
end;

{ --no-auth（仅本机调试）时的首页：没有登录态可展示，就不装工作台，
  只列插件直链，免得 / 落到 worker 代理上回一个莫名其妙的 502 }
function HyperOpenIndexPage(const AItems: TLWHyperUIItems; ATotal: Integer;
  const ABrand: string): string;
var
  i: Integer;
  links: string;
begin
  links := '';
  for i := 0 to High(AItems) do
    links := links + '<li><a href="/p/' + HyperHTMLEsc(AItems[i].Name) + '/">' +
      HyperHTMLEsc(AItems[i].Title) + '</a>' +
      '<span class="p">/p/' + HyperHTMLEsc(AItems[i].Name) + '/ · 端口 ' +
      IntToStr(AItems[i].Port) + '</span></li>';
  if links = '' then
    links := '<li class="p">清单里没有插件</li>';

  Result :=
    '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>' + HyperHTMLEsc(ABrand) + '</title><style>' + PageCSS +
    'body{padding:32px;max-width:760px;margin:0 auto}' +
    '.warn{padding:10px 14px;border-radius:8px;font-size:13px;color:#8a5300;' +
    'background:rgba(240,173,78,.14);border:1px solid rgba(240,173,78,.4);' +
    'margin:0 0 18px}' +
    'h1{font-size:19px;margin:0 0 6px}' +
    '.sub{color:var(--muted);font-size:13px;margin:0 0 18px}' +
    'ul{list-style:none;padding:0;margin:0}' +
    'li{display:flex;align-items:baseline;gap:10px;padding:9px 12px;' +
    'background:var(--panel);border:1px solid var(--line);border-radius:8px;' +
    'margin-bottom:8px}' +
    'li a{font-weight:600}' +
    '.p{color:var(--muted);font-size:12px}' +
    '</style>' + LWPWAHeadHtml('/') + '</head><body>' +
    '<h1>' + HyperHTMLEsc(ABrand) + '</h1>' +
    '<p class="sub">插件模式 · 共 ' + IntToStr(ATotal) + ' 个插件</p>' +
    '<p class="warn">已用 <code>--no-auth</code> 关闭登录：任何能访问本端口的人' +
    '都能直接打开下面的插件。只在本机调试时这样跑。</p><ul>' + links + '</ul>' +
    LWPWAScriptHtml('/') + '</body></html>';
end;

end.
