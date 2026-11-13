# controls 演示 —— 容器/列表控件全家桶（不带数据库）

`demos/controls/controlsdemo.exe`（默认 8090，`--port=N` 可换）。

演示四个此前未适配的普通控件，全部在 lfm 里声明：

| 控件 | 演示变量 | 语义要点 |
|---|---|---|
| `TRadioGroup` | rgColor | 浏览器回传"第几项"（与 TDBRadioGroup 的 Value 语义不同） |
| `TCheckGroup` | cgLang | checked 布尔数组逐项套用；`OnItemClick` 是 `(Sender; Index)` 两参事件 |
| `TCheckListBox` | clbTodo | checked 数组 + `OnClickCheck`；`val` = 选中项序号 |
| `TValueListEditor` | vleInfo | 键值对编辑：编辑完成先写值再触发 `OnValidate`（五参事件） |

所有事件都写进底部 `lblLog` —— 回归测试靠读它断言"服务端业务代码真的跑了"。

## 服务端实现要点（docs/NOTES.md 坑 25）

- TRadioGroup / TCheckGroup 内部生成的单选/复选按钮是真实子控件，
  `IsInternalControl` 按父控件类型排除，组控件自己以 items/checked 数组下发。
- TValueListEditor 的怪癖：`Keys[i]=Cells[0,i]` 是**网格行号**（0 = 标题行），
  而 `Strings.Count` 是**数据行数**（不含标题行）——数据行是网格行 1..Strings.Count。
- 值列编辑完成：服务端先写 `Values[key]` 再触发 `OnValidate`，
  handler 里读到的是已生效的新值。
- 事件签名不同者（OnItemClick 两参、OnValidate 五参）走 lwdispatch 的
  类型化调用，绝不 TNotifyEvent 强转。

## 回归

`python tests/t_controls.py`（26 项）：kind 映射、首次下发值、
内部按钮不下发、四个控件的事件回写与值生效。
