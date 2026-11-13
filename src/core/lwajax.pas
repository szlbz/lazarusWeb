{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwajax
  ------------------------------------------------------------------
  自定义 AJAX 端点 —— 对应 uniGUI 的 AddAjaxProcedure。

  这是给"第三方 JS / 外部系统"留的逃生舱：页面里的 Ext、原生 fetch、
  别的站点、移动端 App，都能直接调，不必经过组件树。

      TLWApp.AddAjax('orders/stats', @StatsHandler);   // 注册

      procedure TMainForm.StatsHandler(A: TLWAjaxContext);
      begin
        A.Json('{"today":12,"amount":3456.78}');
      end;

  浏览器端（同源，随便写）：

      const r = await fetch('/lw/ajax/orders/stats?range=7d');
      console.log(await r.json());

  路由：
      /lw/ajax/<名字>      GET / POST / PUT / DELETE 都收（名字可含 '/'）

  约定：
    * 处理器只有一个参数（上下文），请求信息从上下文取：
      Method / Path / Body / Param() / Header() / JSONBody() / Session
    * 输出用 A.Text / A.Json / A.Error；不写就是 200 + 空响应
    * 需要登录态的端点，自己判断 A.Session 与 SessionGetVar('login.name')
      （框架不自动拦 —— 第三方 JS 调用的鉴权策略差异太大，交给业务）
    * 跨域默认不开；启动加 --ajax-cors 才回 Access-Control-Allow-Origin
}
unit lwajax;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, lwbase;

type
  TLWAjaxContext = class
  private
    FMethod: string;
    FPath: string;
    FQueryString: string;
    FBody: string;
    FQuery: TStringList;
    FHeaders: TStringList;
    FSession: TLWSessionBase;
  public
    constructor Create(const AMethod, APath, AQueryString, ABody: string;
      AHeaders: TStringList; ASession: TLWSessionBase);
    destructor Destroy; override;

    { ---------- 请求 ---------- }
    { 查询参数（?a=1&b=2），大小写不敏感 }
    function Param(const AName: string; const ADef: string = ''): string;
    { 请求头（Content-Type / Authorization / X-Whatever） }
    function Header(const AName: string; const ADef: string = ''): string;
    { 把 Body 当 JSON 对象解析；不是 JSON 或解析失败返回 nil（调用方 Free） }
    function JSONBody: TJSONObject;
    { 请求体是表单（application/x-www-form-urlencoded）时按表单取字段 }
    function FormField(const AName: string; const ADef: string = ''): string;
    property Method: string read FMethod;
    property Path: string read FPath;
    property QueryString: string read FQueryString;
    property Body: string read FBody;
    { 关联的会话：URL 带 ?sid= 或请求头 X-LW-Sid 才有，否则 nil }
    property Session: TLWSessionBase read FSession;

  public
    { ---------- 响应 ---------- }
    { 0 = 处理器没设，按 200 处理 }
    Code: Integer;
    ContentType: string;
    Response: string;

    procedure Text(const AText: string; ACode: Integer = 200);
    procedure Json(const AJsonText: string; ACode: Integer = 200);
    { {"ok":true} 或 {"ok":true, ...扩展} }
    procedure Ok(const AExtraJson: string = '');
    { {"ok":false,"err":"..."} }
    procedure Error(const AMsg: string; ACode: Integer = 400);
  end;

  TLWAjaxHandler = procedure(AContext: TLWAjaxContext) of object;

{ 注册 / 查找（lwapp.AddAjax 只是这里的转发） }
procedure LWRegisterAjax(const AName: string; AHandler: TLWAjaxHandler);
function LWLookupAjax(const AName: string; out AHandler: TLWAjaxHandler): Boolean;
function LWAjaxNames: string;

implementation

var
  GNames: TStringList = nil;   { 注册顺序 }
  GHandlers: array of TLWAjaxHandler;

procedure EnsureAjax;
begin
  if GNames = nil then
    GNames := TStringList.Create;
  GNames.CaseSensitive := False;
end;

procedure LWRegisterAjax(const AName: string; AHandler: TLWAjaxHandler);
var
  n: string;
  i: Integer;
begin
  EnsureAjax;
  n := Trim(AName);
  while (n <> '') and (n[1] = '/') do
    Delete(n, 1, 1);
  while (n <> '') and (n[Length(n)] = '/') do
    Delete(n, Length(n), 1);
  if n = '' then
    raise Exception.Create('LWRegisterAjax: 端点名不能为空');
  i := GNames.IndexOf(n);
  if i < 0 then
  begin
    GNames.Add(n);
    SetLength(GHandlers, GNames.Count);
    GHandlers[GNames.Count - 1] := AHandler;
  end
  else
    GHandlers[i] := AHandler;   { 重名覆盖：便于热改 }
end;

function LWLookupAjax(const AName: string; out AHandler: TLWAjaxHandler): Boolean;
var
  i: Integer;
begin
  EnsureAjax;
  Result := False;
  AHandler := nil;
  i := GNames.IndexOf(AName);
  if (i >= 0) and (i < Length(GHandlers)) then
  begin
    AHandler := GHandlers[i];
    Result := Assigned(AHandler);
  end;
end;

function LWAjaxNames: string;
begin
  EnsureAjax;
  Result := StringReplace(GNames.Text, LineEnding, ', ', [rfReplaceAll]);
  Result := Trim(Result);
end;

{ ---------------- TLWAjaxContext ---------------- }

constructor TLWAjaxContext.Create(const AMethod, APath, AQueryString, ABody: string;
  AHeaders: TStringList; ASession: TLWSessionBase);
begin
  inherited Create;
  FMethod := UpperCase(AMethod);
  FPath := APath;
  FQueryString := AQueryString;
  FBody := ABody;
  FSession := ASession;
  FQuery := TStringList.Create;
  FQuery.CaseSensitive := False;
  { 手工解析：TStringList 的 NameValueSeparator 对 URL 编码不友好，
    这里用 httpdefs 的逻辑太重，直接按 & 和 = 切 + URLDecode }
  FQuery.Delimiter := '&';
  FQuery.StrictDelimiter := True;
  FQuery.DelimitedText := AQueryString;

  FHeaders := TStringList.Create;
  FHeaders.CaseSensitive := False;
  if AHeaders <> nil then
    FHeaders.Assign(AHeaders);

  Code := 0;
  ContentType := 'application/json; charset=utf-8';
  Response := '';
end;

destructor TLWAjaxContext.Destroy;
begin
  FQuery.Free;
  FHeaders.Free;
  inherited Destroy;
end;

function LWURLDecode(const S: string): string;
var
  i, v: Integer;
  h: string;
begin
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    if S[i] = '%' then
    begin
      if i + 2 <= Length(S) then
      begin
        h := Copy(S, i + 1, 2);
        v := StrToIntDef('$' + h, -1);
        if v >= 0 then
        begin
          Result := Result + Chr(v);
          Inc(i, 3);
          Continue;
        end;
      end;
      Result := Result + S[i];
      Inc(i);
    end
    else if S[i] = '+' then
    begin
      Result := Result + ' ';
      Inc(i);
    end
    else
    begin
      Result := Result + S[i];
      Inc(i);
    end;
  end;
end;

function TLWAjaxContext.Param(const AName: string; const ADef: string): string;
var
  i, p: Integer;
  item, k, v: string;
begin
  for i := 0 to FQuery.Count - 1 do
  begin
    item := FQuery[i];
    p := Pos('=', item);
    if p > 0 then
    begin
      k := LWURLDecode(Copy(item, 1, p - 1));
      v := LWURLDecode(Copy(item, p + 1, MaxInt));
    end
    else
    begin
      k := LWURLDecode(item);
      v := '';
    end;
    if SameText(k, AName) then
      Exit(v);
  end;
  Result := ADef;
end;

function TLWAjaxContext.Header(const AName: string; const ADef: string): string;
var
  i: Integer;
begin
  i := FHeaders.IndexOfName(AName);
  if i >= 0 then
    Result := Trim(Copy(FHeaders[i], Pos(':', FHeaders[i]) + 1, MaxInt))
  else
    Result := ADef;
end;

function TLWAjaxContext.FormField(const AName: string; const ADef: string): string;
var
  sl: TStringList;
begin
  Result := ADef;
  sl := TStringList.Create;
  try
    sl.CaseSensitive := False;
    sl.Delimiter := '&';
    sl.StrictDelimiter := True;
    sl.DelimitedText := FBody;
    Result := LWURLDecode(sl.Values[AName]);
    if Result = '' then Result := ADef;
  finally
    sl.Free;
  end;
end;

function TLWAjaxContext.JSONBody: TJSONObject;
var
  d: TJSONData;
begin
  Result := nil;
  if Trim(FBody) = '' then Exit;
  try
    d := GetJSON(FBody);
  except
    Exit;
  end;
  if d is TJSONObject then
    Result := TJSONObject(d)
  else
    d.Free;
end;

procedure TLWAjaxContext.Text(const AText: string; ACode: Integer);
begin
  Response := AText;
  ContentType := 'text/plain; charset=utf-8';
  Code := ACode;
end;

procedure TLWAjaxContext.Json(const AJsonText: string; ACode: Integer);
begin
  Response := AJsonText;
  ContentType := 'application/json; charset=utf-8';
  Code := ACode;
end;

procedure TLWAjaxContext.Ok(const AExtraJson: string);
begin
  if Trim(AExtraJson) = '' then
    Json('{"ok":true}')
  else if Copy(Trim(AExtraJson), 1, 1) = '{' then
    Json('{"ok":true,' + Copy(Trim(AExtraJson), 2, MaxInt))
  else
    Json('{"ok":true,"data":' + AExtraJson + '}');
end;

{ JSON 字符串转义：TJSONString.Create 的实例要 Free，别直接取 .AsJSON }
function LWJsonEsc(const S: string): string;
var
  j: TJSONString;
begin
  j := TJSONString.Create(S);
  try
    Result := j.AsJSON;
  finally
    j.Free;
  end;
end;

procedure TLWAjaxContext.Error(const AMsg: string; ACode: Integer);
begin
  Json('{"ok":false,"err":' + LWJsonEsc(AMsg) + '}', ACode);
end;

initialization
  GNames := nil;
  SetLength(GHandlers, 0);

finalization
  FreeAndNil(GNames);

end.
