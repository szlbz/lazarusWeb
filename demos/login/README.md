# login 演示 —— TLWLoginForm 登录/权限框架

uniGUI 的 TUniLoginForm 对应物。演示「lfm/IDE 可设计」的登录窗体 +
会话级认证拦截 + 退出登录。

## 运行

```
logindemo.exe --port=8094
```

浏览器打开 `http://127.0.0.1:8094/` —— 新会话自动被登录窗体接管。
演示账号 admin，密码在 `uLogin.pas` 的 `DoLoginEx` 里（内网演示用）。

## 结构

- `uLogin.pas / uLogin.lfm` —— `TLoginForm = class(TLWLoginForm)`，
  **lfm 设计**：published 区声明控件字段（lblTitle/lblUser/lblPass/
  edUser/edPass/btnOk/btnReset），lfm 根节点 `OnCreate = FormCreate`，
  btnOk `OnClick = DoLogin`（基类 published 方法，直接在 lfm 里引用），
  btnReset `OnClick = DoReset`。业务校验在 `OnLogin` 事件
  （`DoLoginEx`：对账号密码，`AOk := True`；错则填 AErr 并 Toast）。
- `uMain.pas` —— 业务主窗体（代码建控件，**Name 必须显式设置**）。
  `DoLogout`：`S.Authenticated := False; S.SessionShowForm(S.LoginForm)`。
- `logindemo.lpr` —— 关键就两行：

```pascal
TLWApp.SetLogin(TLoginForm);     // 登录窗体（不进默认窗体顺序）
TLWApp.Register(TMainForm);      // 业务主窗体
```

## 框架语义

- 未认证会话请求任意窗体 → 一律先给登录窗体；
- 认证成功（`S.Authenticated := True`）→ 框架自动
  `TLWApp.CreateForm(DefaultFormName)` 并推送到浏览器；
- 未认证期间**所有**非登录窗体上的事件（含 API 调用）→
  `400 {"ok":false,"err":"not authenticated"}`；
- 登录失败 → `PushToast` 提示，会话仍停在登录窗体。

## 回归

`tests/t_login.py`（15 项）：接管、lfm 控件齐全、password 标志、
错误密码 Toast、正确密码进主窗体、显示用户、认证后事件、
退出登录、注销拦截、重新登录。运行方式：

```
python tests/run_with_server.py demos/login/logindemo.exe tests/t_login.py 8144
```

注意该脚本读环境变量 `LW_LOGIN_BASE`（不是 LW_BASE）。
