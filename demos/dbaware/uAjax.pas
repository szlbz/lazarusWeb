{
  lazarusWeb :: dbaware 演示 —— 自定义 AJAX 端点

  演示 TLWApp.AddAjax（uniGUI 的 AddAjaxProcedure 对应物）：
  这些端点不经过组件树，浏览器里的原生 fetch / Ext.Ajax / 第三方系统
  都能直接调。

      GET  /lw/ajax/items            商品清单（JSON）
      POST /lw/ajax/items/price      改价：{"code":"P1001","price":199}
      GET  /lw/ajax/whoami           当前会话的登录身份（?sid= 或 X-LW-Sid）
      ANY  /lw/ajax/echo             回显 method / 参数 / 请求体

  注册时机：dbaware.lpr 里 TLWApp.Run 之前（见 RegisterDemoAjax）。
}
unit uAjax;

{$mode objfpc}{$H+}

interface

{ 注册本演示的 AJAX 端点。必须在 TLWApp.Run 之前调用 }
procedure RegisterDemoAjax;

implementation

uses
  Classes, SysUtils, DB, sqldb, sqlite3conn, fpjson,
  lwapp, lwajax, lwbase, uLogin;

type
  TDemoAjax = class
  public
    procedure Items(A: TLWAjaxContext);
    procedure ItemPrice(A: TLWAjaxContext);
    procedure WhoAmI(A: TLWAjaxContext);
    procedure Echo(A: TLWAjaxContext);
  end;

var
  GDemoAjax: TDemoAjax = nil;

{ JSON 字符串转义（只处理最常见的 \ 和 "） }
function JsonQuote(const S: string): string;
begin
  Result := '"' + StringReplace(StringReplace(S, '\', '\\', [rfReplaceAll]),
    '"', '\"', [rfReplaceAll]) + '"';
end;

{ 打开 dbaware.db（与登录窗体共用同一个文件） }
function OpenDb(out AConn: TSQLite3Connection; out ATrans: TSQLTransaction): Boolean;
begin
  Result := False;
  AConn := TSQLite3Connection.Create(nil);
  ATrans := TSQLTransaction.Create(nil);
  try
    AConn.DatabaseName := AwareDBFile;
    AConn.Transaction := ATrans;
    ATrans.Database := AConn;
    AConn.Params.Add('journal_mode=WAL');
    AConn.Open;
    AConn.ExecuteDirect('PRAGMA busy_timeout=10000');
    Result := True;
  except
    on E: Exception do
    begin
      ATrans.Free;
      AConn.Free;
      AConn := nil;
      ATrans := nil;
      raise;
    end;
  end;
end;

{ 商品清单：GET /lw/ajax/items?limit=10 }
procedure TDemoAjax.Items(A: TLWAjaxContext);
var
  conn: TSQLite3Connection;
  tr: TSQLTransaction;
  q: TSQLQuery;
  acc, one: string;
  limit, n: Integer;
begin
  limit := StrToIntDef(A.Param('limit', '50'), 50);
  if limit < 1 then limit := 1;
  if limit > 500 then limit := 500;

  conn := nil;
  tr := nil;
  n := 0;
  q := TSQLQuery.Create(nil);
  { 手工拼 JSON：fpjson 的浮点默认写成 2.99E+002 这种科学计数法，
    JS 那边能用但难读；金额这类字段保留两位小数更符合直觉 }
  acc := '';
  try
    try
      OpenDb(conn, tr);
      q.Database := conn;
      q.Transaction := tr;
      q.SQL.Text :=
        'SELECT code, name, price, stock FROM items ORDER BY code LIMIT ' + IntToStr(limit);
      q.Open;
      while not q.Eof do
      begin
        if acc <> '' then acc := acc + ',';
        one := '{"code":' + JsonQuote(q.FieldByName('code').AsString) +
          ',"name":' + JsonQuote(q.FieldByName('name').AsString) +
          ',"price":' + FormatFloat('0.00', q.FieldByName('price').AsFloat) +
          ',"stock":' + IntToStr(q.FieldByName('stock').AsInteger) + '}';
        acc := acc + one;
        Inc(n);
        q.Next;
      end;
      q.Close;
      A.Json('{"ok":true,"count":' + IntToStr(n) + ',"items":[' + acc + ']}');
    except
      on E: Exception do
        A.Error('查询失败：' + E.Message, 500);
    end;
  finally
    q.Free;
    if tr <> nil then tr.Free;
    if conn <> nil then conn.Free;
  end;
end;

{ 改价：POST /lw/ajax/items/price  body: {"code":"P1001","price":199.5} }
procedure TDemoAjax.ItemPrice(A: TLWAjaxContext);
var
  body: TJSONObject;
  code: string;
  price: Double;
  conn: TSQLite3Connection;
  tr: TSQLTransaction;
  q: TSQLQuery;
  n: Integer;
begin
  body := A.JSONBody;
  if body = nil then
  begin
    A.Error('请求体必须是 JSON', 400);
    Exit;
  end;
  try
    code := Trim(body.Get('code', ''));
    price := body.Get('price', -1.0);
  finally
    body.Free;
  end;
  if code = '' then
  begin
    A.Error('缺少 code', 400);
    Exit;
  end;
  if price < 0 then
  begin
    A.Error('缺少 price（或为负）', 400);
    Exit;
  end;

  conn := nil;
  tr := nil;
  q := TSQLQuery.Create(nil);
  try
    try
      OpenDb(conn, tr);
      q.Database := conn;
      q.Transaction := tr;
      q.SQL.Text := 'UPDATE items SET price = :p WHERE code = :c';
      q.ParamByName('p').AsFloat := price;
      q.ParamByName('c').AsString := code;
      q.ExecSQL;
      n := q.RowsAffected;
      tr.Commit;
      A.Json('{"ok":true,"updated":' + IntToStr(n) + ',"code":"' + code +
        '","price":' + FloatToStr(price) + '}');
    except
      on E: Exception do
        A.Error('更新失败：' + E.Message, 500);
    end;
  finally
    q.Free;
    if tr <> nil then tr.Free;
    if conn <> nil then conn.Free;
  end;
end;

{ 当前会话身份：证明 AJAX 端点也能拿到会话（?sid= 或 X-LW-Sid） }
procedure TDemoAjax.WhoAmI(A: TLWAjaxContext);
var
  name, role: string;
begin
  if A.Session = nil then
  begin
    A.Json('{"ok":false,"err":"没有会话：请带 ?sid= 或 X-LW-Sid 头"}', 401);
    Exit;
  end;
  name := A.Session.SessionGetVar('login.name');
  role := A.Session.SessionGetVar('login.role');
  if name = '' then
    A.Json('{"ok":true,"authenticated":false}')
  else
    A.Json('{"ok":true,"authenticated":true,"name":"' + name +
      '","role":"' + role + '"}');
end;

{ 回显：任意方法，把 method / 查询参数 / 请求体原样返回（联调用） }
procedure TDemoAjax.Echo(A: TLWAjaxContext);
var
  o: TJSONObject;
begin
  o := TJSONObject.Create;
  try
    o.Add('method', A.Method);
    o.Add('path', A.Path);
    o.Add('query', A.QueryString);
    o.Add('body', A.Body);
    o.Add('hasSession', A.Session <> nil);
    A.Json(o.AsJSON);
  finally
    o.Free;
  end;
end;

procedure RegisterDemoAjax;
begin
  if GDemoAjax <> nil then Exit;
  GDemoAjax := TDemoAjax.Create;
  TLWApp.AddAjax('items', @GDemoAjax.Items);
  TLWApp.AddAjax('items/price', @GDemoAjax.ItemPrice);
  TLWApp.AddAjax('whoami', @GDemoAjax.WhoAmI);
  TLWApp.AddAjax('echo', @GDemoAjax.Echo);
end;

end.
