# 演示 7：对话框（ShowMessage / MessageDlg / TOpenDialog …）

这个窗体证明一件事：**原生 LCL 对话框在浏览器里能用，业务代码一行都不用改**。
左边一列按钮，每个按钮触发一种 LCL 对话框；点完之后返回记录到底部的 `TMemo`。

## 运行

```
build.bat                 :: 或单独: build.bat dialogs
demos\dialogs\dlgdemo.exe --port=8099
```

浏览器打开 `http://127.0.0.1:8099/`。

> 工程名是 `dlgdemo` 而不是 `dialogs`：后者会和 LCL 的 `dialogs` 单元撞名，
> 链接期报 `Undefined symbol: DIALOGS_$$_SHOWMESSAGE`。

## 七个按钮

| 按钮 | 调用的 LCL 入口 | 浏览器里看到 | 返回值回到哪 |
|---|---|---|---|
| 消息 | `ShowMessage` | 无图标提示框，一个"确定" | 无返回值，`ShowMessage` 直接返回 |
| 确认 | `MessageDlg(..., mtConfirmation, [mbYes, mbNo], 0)` | 问号图标 + 是/否 | `mrYes` / `mrNo` |
| 输入 | `InputQuery('标题', '提示', s)` | 提示 + 单行输入框 | `Result` + `var s` |
| 自定义按钮 | `QuestionDlg(..., [mrYes,'保存',0, mrNo,'放弃',0, mrCancel,'返回',0], 0)` | 三个按钮用你给的文字 | `ModalResult` 原样 |
| MessageBox | `Application.MessageBox(PChar(...), '警告', MB_YESNO or MB_ICONWARNING)` | 警告图标 + 是/否 | `IDYES` / `IDNO` |
| 打开文件 | `OpenDialog1.Execute` | 选文件框（**多选按 Options 走**） | `FileName` = 服务端路径 |
| 保存文件 | `SaveDialog1.Execute` | 输入文件名的框 | `FileName` = 会话临时目录下 |

## 两处和桌面不一样的地方（必须知道）

### 1. 文件对话框拿到的是服务端路径

浏览器不可能把本地路径交出去，所以用户选的文件**先上传**：

```
用户选 C:\Users\me\Desktop\报告 2026.txt
   ↓  multipart  POST /lw/api/dlgfile?sid=<会话>&id=<对话框令牌>
服务端 %TEMP%\lw_uploads\<会话>\pick\报告 2026.txt
   ↓
OpenDialog1.FileName = 'C:\Users\...\Temp\lw_uploads\<会话>\pick\报告 2026.txt'
```

于是下面这段完全照常工作：

```pascal
if OpenDialog1.Execute then
  mmoLog.Lines.Add(OpenDialog1.FileName);
```

注意 `%TEMP%` 是临时的：要长期保留请自己 `CopyFile` 到正式目录。

`TSaveDialog` 反过来 —— 浏览器只给一个文件名，落盘位置服务端定
（`...\<会话>\save\`），你写完文件再 `SendFile` 推给用户下载。

### 2. 服务端线程是真的挂住了

点"确认"之后，事件请求（`POST /lw/api/event`）会一直不返回，
直到用户在浏览器里点了按钮 —— 和桌面上 `MessageDlg` 阻塞在那行代码上完全一样。
期间：

- 其它会话（其它浏览器标签）照常响应；
- 同一会话里再弹第二个框会被拒绝（`SessionNotify` 提示"已有对话框在等待用户响应"）；
- 超过 180 秒没人点，`WaitFor` 超时，`ShowModal` 放弃，`Execute` 返回 False。

## 底层实现（`src/core/lwdlg.pas`）

LCL 的对话框不是统一入口，得接四套钩子 + 一套 widgetset 类：

```pascal
PromptDialogFunction   := @LWPromptDialog;    // ShowMessage / MessageDlg
InputDialogFunction    := @LWInputDialog;     // InputQuery / InputBox
QuestionDialogFunction := @LWQuestionDialog;  // QuestionDlg
Forms.MessageBoxFunction := @LWMessageBox;    // Application.MessageBox
RegisterWSComponent(TOpenDialog, TLWWSOpenDialog);
RegisterWSComponent(TSaveDialog, TLWWSSaveDialog);
```

`LWInstallDialogs` 在 `TLWApp.Run` 里、创建任何窗体**之前**调用
（`RegisterWSComponent` 只影响之后新建的实例）。没有浏览器会话时每个函数
都直接调原实现 —— 所以在 IDE 里 F9 调试或者跑单元测试，行为还是桌面的。

流程：

```
业务代码 ShowMessage(...)
  → LWPromptDialog 组装 {kind, caption, text, buttons, default}
  → TLWSession.SessionDialog 推 type=dialog 指令 + TEvent.WaitFor(180s)
  → 浏览器渲染模态框，用户点"确定"
  → POST /lw/api/dlg {sid, id, r:1}
  → TLWSession.ResolveDialog 设结果 + SetEvent
  → 线程醒，LWPromptDialog 返回按钮 id（1 = idButtonOk）
```

按钮 id 用的就是 LCL 自己的 `idButton*`（`idButtonOk=1`、`idButtonCancel=2`、
`idButtonYes=4`、`idButtonNo=5`），所以 `PromptDialog` → `mrYes/mrNo` 那一层
映射不用重写。

## 回归测试

```
python tests\t_dialog.py        :: 默认连 8099，需要先启动本 demo
```

36 项，覆盖 7 类对话框的完整链路（推送 → 检查 kind/text/buttons → 答复 →
检查事件线程返回 → 检查 `mmoLog` 文本），文件对话框还包含一次真实
multipart 上传。
