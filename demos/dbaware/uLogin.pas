{
  lazarusWeb :: dbaware 演示 —— 登录窗体
  ------------------------------------------------------------------
  一个窗体怎么来的，两种写法这个仓库里都有：

    * 本窗体（uLogin.lfm + uLogin.pas）：标准 Lazarus 写法 ——
      布局、标题、字号、事件绑定全在 .lfm 里，.pas 只留逻辑
      （FormCreate 接线 + DoAuth 查 SQLite users 表）。
    * 纯代码建窗（TLabel.Create + SetBounds + 手工接事件）效果等价，
      但界面改一行就得改代码、设计期看不到效果 —— 见 docs/NOTES.md 坑 20/41。

  认证走 TLWLoginForm：框架发现会话没登录就推这个窗体，
  它在浏览器里提交账号口令 -> DoAuth 查库 -> 写会话变量（用户名/角色）。
}
unit uLogin;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, DB,
  sqldb, sqlite3conn, lwform, lwlogin, lwbase;

type
  TLoginForm = class(TLWLoginForm)
  published
    { ---- 控件：名字与 uLogin.lfm 里的对象一一对应，LFM 加载时自动绑定 ---- }
    lblLogo: TLabel;
    lblSub: TLabel;
    lblUser: TLabel;
    edUser: TEdit;
    lblPass: TLabel;
    edPass: TEdit;
    btnOk: TButton;
    btnReset: TButton;
    lblHint: TLabel;

    { ---- 事件（LFM 里按名字绑定）---- }
    procedure FormCreate(Sender: TObject);
    { TLWLoginForm 的认证回调：登录窗体的 Name / 标题 / 控件全在 uLogin.lfm 里 }
    procedure DoAuth(Sender: TObject; const AUser, APass: string;
      var AOk: Boolean; var AErr: string);
  end;

{ 当前登录用户 / 角色。
  存在【会话】上（TLWSessionBase.SessionGetVar），不能用进程级全局变量：
  一个进程同时服务多个浏览器会话，全局变量会把 A 的用户名和权限
  带给 B（多开、多页签、换个浏览器都能看到） }
function LoginUserName: string;
function LoginUserRole: string;
procedure ClearLoginUser;

{ dbaware.db 的完整路径（与服务端同目录） }
function AwareDBFile: string;
{ 建 users 表并种入演示账号；返回 True 表示表已就绪 }
function EnsureUserTable(const ADbFile: string; out AErrText: string): Boolean;

implementation

{$R *.lfm}

function LoginUserName: string;
var
  S: TLWSessionBase;
begin
  S := LWCurrentSession;
  if S = nil then Exit('');
  Result := S.SessionGetVar('login.name');
end;

function LoginUserRole: string;
var
  S: TLWSessionBase;
begin
  S := LWCurrentSession;
  if S = nil then Exit('');
  Result := S.SessionGetVar('login.role');
end;

procedure ClearLoginUser;
var
  S: TLWSessionBase;
begin
  S := LWCurrentSession;
  if S = nil then Exit;
  S.SessionSetVar('login.name', '');
  S.SessionSetVar('login.role', '');
end;

function AwareDBFile: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ExpandFileName(ParamStr(0)))) +
    'dbaware.db';
end;

function EnsureUserTable(const ADbFile: string; out AErrText: string): Boolean;
var
  conn: TSQLite3Connection;
  tr: TSQLTransaction;
  q: TSQLQuery;
  n: Integer;
begin
  Result := False;
  conn := TSQLite3Connection.Create(nil);
  tr := TSQLTransaction.Create(nil);
  q := TSQLQuery.Create(nil);
  try
    try
      conn.DatabaseName := ADbFile;
      conn.Transaction := tr;
      tr.Database := conn;
      conn.Params.Add('journal_mode=WAL');
      conn.Open;
      conn.ExecuteDirect('PRAGMA busy_timeout=10000');
      { 注意：ExecuteDirect 会自己起事务（sqlite3conn 的行为），
        这里不要再 StartTransaction，否则报 Transaction already active }
      conn.ExecuteDirect(
        'CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, ' +
        'login VARCHAR(40), pwd VARCHAR(60), role VARCHAR(20), fullname VARCHAR(40))');
      tr.Commit;

      q.Database := conn;
      q.Transaction := tr;
      q.SQL.Text := 'SELECT COUNT(*) FROM users';
      q.Open;
      n := q.Fields[0].AsInteger;
      q.Close;

      if n = 0 then
      begin
        conn.ExecuteDirect('INSERT INTO users(login,pwd,role,fullname) ' +
          'VALUES(''admin'',''123456'',''admin'',''系统管理员'')');
        conn.ExecuteDirect('INSERT INTO users(login,pwd,role,fullname) ' +
          'VALUES(''guest'',''guest'',''guest'',''只读访客'')');
        tr.Commit;
      end;
      Result := True;
    except
      on E: Exception do
        AErrText := E.ClassName + ': ' + E.Message;
    end;
  finally
    q.Free;
    tr.Free;
    conn.Free;
  end;
end;

{ ---------- TLoginForm ---------- }

procedure TLoginForm.FormCreate(Sender: TObject);
begin
  { LFM 只管界面：这里补的是非可视接线（认证回调 / 两个编辑框的引用）与演示初始值 }
  OnLogin := @DoAuth;
  { 明确指定两个编辑框，省得靠命名约定去猜 }
  LoginUserEdit := edUser;
  LoginPassEdit := edPass;
  edUser.Text := 'admin';
  edPass.Text := '123456';
  btnOk.Default := True;
  lblHint.WordWrap := True;
  lblHint.Caption :=
  '演示账号：admin / 123456（管理员）· guest / guest（只读）。' +
  '账号存在 dbaware.db 的 users 表里，认证失败会在浏览器右上角弹提示。';
end;

procedure TLoginForm.DoAuth(Sender: TObject; const AUser, APass: string;
  var AOk: Boolean; var AErr: string);
var
  db: string;
  S: TLWSessionBase;
  conn: TSQLite3Connection;
  tr: TSQLTransaction;
  q: TSQLQuery;
begin
  AOk := False;
  AErr := '';
  db := AwareDBFile;
  if not EnsureUserTable(db, AErr) then
  begin
    AErr := '数据库不可用：' + AErr + '（' + db + '）';
    Exit;
  end;

  conn := TSQLite3Connection.Create(nil);
  tr := TSQLTransaction.Create(nil);
  q := TSQLQuery.Create(nil);
  try
    try
      conn.DatabaseName := db;
      conn.Transaction := tr;
      tr.Database := conn;
      conn.Params.Add('journal_mode=WAL');
      conn.Open;
      conn.ExecuteDirect('PRAGMA busy_timeout=10000');
      q.Database := conn;
      q.Transaction := tr;
      q.SQL.Text := 'SELECT role, fullname FROM users WHERE login = :u AND pwd = :p';
      q.ParamByName('u').AsString := AUser;
      q.ParamByName('p').AsString := APass;
      q.Open;
      if not q.Eof then
      begin
        AOk := True;
        { 身份写进【本会话】，之后主窗体/报表都从会话读 —— 多开浏览器
          各是各的，不会串号 }
        S := LWCurrentSession;
        if S <> nil then
        begin
          S.SessionSetVar('login.name', AUser);
          S.SessionSetVar('login.role', q.FieldByName('role').AsString);
          if q.FieldByName('fullname').AsString <> '' then
            S.SessionSetVar('login.name', q.FieldByName('fullname').AsString);
        end;
      end
      else
        AErr := '用户名或密码不正确（演示账号 admin / 123456）';
      q.Close;
    except
      on E: Exception do
        AErr := '认证失败：' + E.Message;
    end;
  finally
    q.Free;
    tr.Free;
    conn.Free;
  end;
end;

end.
