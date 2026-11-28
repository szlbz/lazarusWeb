# 给第三方控件添加浏览器绑定

本文说明如何让一个**框架未登记的控件**（第三方组件库、自写控件、LCL 未收录控件）
在 lazarusWeb 里获得正确的浏览器渲染、事件回传与值回写。内容与
`docs/MANUAL.md` §15「扩展开发」对齐，补充了实际操作中必须注意的细节与源码位置。

> 文中行号取自 2026-11-17 的 `src/` 快照，随版本可能漂移；**以函数名为准**。

---

## 0. 适用范围

**适用**：第三方 Pascal 可视控件（`TControl` / `TWinControl` 后代），要求它在浏览器里
被渲染成 HTML、能触发布局与事件、能把用户输入写回 LCL 属性。

**不适用**（走别的路）：

| 需求 | 正确做法 |
|---|---|
| 只想在页面里嵌第三方 **JS** 组件（ECharts、Select2、DataTables…） | `TLWHTMLFrame` + `TLWApp.AddAjax()`，见本文 §5 |
| 控件只在服务端跑业务、界面无人看 | 不用做任何事，未登记类自动落 `unknown` 灰框占位 |
| 想让控件"原样画出来"（复用它的 `OnPaint`） | 做不到，无头 widgetset 画不出像素，见 §4.2 |

---

## 1. 机制：一条 kind 链路

lazarusWeb 不是"控件库换皮"，而是**服务端真 LCL 控件树 + 浏览器端按 `kind` 渲染**。
一个控件在浏览器里能被正确显示，必须打通这条链路：

```
服务端控件树
   │  lwwriter.KindOf(C)          → 类名翻译成 kind 字符串
   │  lwwriter.WriteKindProps     → 按 kind 下发浏览器需要的属性
   ▼
JSON 控件树（form → children）
   │  lw-alpine.js innerOf(node)  → 按 kind 拼内部 HTML
   ▼
浏览器 DOM
   │  事件（ev 列表）+ 当前值（val）
   ▼
lwdispatch.LWApplyValue / LWInvokeEvent  → 写回 LCL 属性 → 触发业务事件
   │
   └── 属性变了 → 服务端重发控件树（回到第一步）
```

**未登记的类的行为**：`KindOf` 返回 `'unknown'`，浏览器渲染成写着类名的灰框
（`.lw-unknown`），服务端对象照常存在、事件照常可触发。因此接入可以渐进：先跑起来，
再逐步补渲染。

---

## 2. 六步接入

### 2.1 让控件能编译进来、能被 lfm 实例化

1. 第三方包加进包依赖：`src/lwcore.lpk` 与 `src/lwserver.lpk` 的 `Required`
   （当前仅有 `LCL` / `FCL` / `fcl-image`），业务工程 `.lpi` 同步加。
2. **`.lfm` 里出现第三方类名时，必须在应用启动前 `RegisterClass`**，否则运行时
   流式加载报 `Class TXxx not found`：

   ```pascal
   initialization
     RegisterClass(TXxxSpin);
   ```

   参考 `src/core/lwdbnav.pas:207`。

   ⚠️ **`RegisterClassAlias` 不能顶替已注册的类名**（`docs/lazarusWeb控件属性映射表.md` 坑 29/41 已推翻
   早期 alias 方案）。若 lfm 里存的是第三方类名，就让那个类名本身可注册；若想用一个
   子类接管，lfm 必须改写真实子类名。

3. **先做无头构造验证**（见 §4.1），确认控件在 `nogui` widgetset 下 `Create` 不抛异常。

### 2.2 `KindOf` 加一条分支

位置：`src/core/lwwriter.pas:196` `function KindOf(C: TControl): string;`

```pascal
  { 第三方 TXxxSpin：值型数字输入框。
    必须排在 TCustomEdit / TEdit 之前——它是 TCustomEdit 后代，
    写在后面会被 'edit' 抢走，属性只下发一半 }
  else if C is TXxxSpin then Result := 'xxxspin'
```

**顺序敏感是本文件最容易踩的坑**。规则是：**派生类必须排在其祖先之前**。现有代码里
DB 族控件排在 `TEdit` 族前、`TLWCamera` 排在 `TLWFileUpload` 前、`TLWChart` 排在
`TCustomPanel` 前，都是这个原因。判断口诀：如果你的控件是 `TEdit` / `TPanel` /
`TStringGrid` 的后代，分支就必须插在对应祖先之前。

> 顺带一提：`C is TCustomEdit` 一项已覆盖所有单行输入框后代，派生自它的控件**不需要**
> 单独登记也能落到 `edit`（`TLabeledEdit` 就是这样）。只有需要专用渲染才新增 kind。

### 2.3 下发属性

位置：`src/core/lwwriter.pas:1442` `WriteKindPropsBody`（`unknown` 分支在 2059）

```pascal
  else if AKind = 'xxxspin' then
  begin
    O.Add('text',   (C as TXxxSpin).Text);
    O.Add('value',  TXxxSpin(C).Value);
    O.Add('min',    TXxxSpin(C).Min);
    O.Add('max',    TXxxSpin(C).Max);
    O.Add('readonly', TXxxSpin(C).ReadOnly);
  end
```

原则：

- **只发浏览器用得上的字段**，别把 published 属性全量转 JSON（性能与体积都吃不消）。
  对照写法见 `dateedit` 分支（1923–1943 行），它只发 `text` + `iso` 两个字段。
- **读取必须容错**。脏值（空日期、空位图、越界 `ItemIndex`）随时可能出现，
  `try/except` 包住或给默认值：

  ```pascal
  try
    O.Add('iso', FormatDateTime('yyyy-mm-dd', TDateEdit(C).Date));
  except
    O.Add('iso', '');
  end;
  ```

- 框架已有兜底：`WriteControl` 捕获异常后把该控件降级成带 `err` 字段的占位节点，
  单个控件失败不影响整个 payload（坑 107）。但兜底只是保险，不该当常态用。

### 2.4 事件白名单

位置：`src/core/lwbase.pas:215` `function IsLWClickEvent(const AName: string): Boolean;`

```pascal
  Result := (AName = 'OnClick') or ... or (AName = 'OnSpin');
```

规则：

- **只放行 `(Sender: TObject)` 单参数事件**——`TMethod` 方法指针直接调用才安全。
- 多参数事件（`OnTitleClick(Column)`、`OnItemClick(Sender, Index)`）**可以**登记，
  但仅用于让 writer 把事件名写进 `ev` 列表（浏览器据此绑 DOM 事件）；真正的调用要
  在 `lwdispatch.pas` 里写类型化分支。
- 未登记的事件不会出现在 `ev` 数组里，浏览器端根本绑不上——**表现为"点了没反应"**。

### 2.5 浏览器渲染与值回写

这一步是主要工作量，涉及三到四处：

#### （a）渲染分支：`src/client/lw-alpine.js:1261` `innerOf(node, st)`

在 `switch (k)` 里加 `case`，**只返回控件内部标记，不要包外层 `div`**——
`createNode`（2494 行）已经自动包了 `<div class="lw-n" data-lwid="…">`，几何由
`placeNode` 按 `node.x / y / w / h` 应用：

```javascript
            case 'xxxspin':
                return '<input type="number" class="lw-input" style="' + fs + '" x-model.number="' + r + '.val"' +
                    (node.min != null ? ' min="' + node.min + '"' : '') +
                    (node.max != null ? ' max="' + node.max + '"' : '') +
                    ' ' + dis + ' @change="' + evAttr(id, 'OnChange', '{val:String(' + r + '.val)}') + '"/>';
```

约定：

- `r` = `$lwN('<控件id>')`，是 `Alpine.reactive` 状态对象，字段见 `stateOf`（784 行）：
  `dis / cap / txt / chk / val / idx / iso / items / cols / rows / active …`；
- 事件一律用 `evAttr(id, 'OnXxx')`（1189 行）生成，它会先查 `$lwHas` 再 `$lwFire`，
  业务没挂处理器时不会白发请求；
- 表头/标签类文本用 `accHtml(esc(...))` 处理 `&` 加速键，与现有分支保持一致；
- `innerOf` 抛异常会被 `createNode` 兜住并降级成 `.lw-unknown` 灰框，不会白屏。

#### （b）输入类控件：`FIELD_KINDS`（638 行）

控件有"值"（用户可改）就必须把 kind 加进这个数组，否则批量取值
（`formVals`）与脏值判断拿不到它：

```javascript
    var FIELD_KINDS = ['edit', 'maskedit', 'memo', 'spin', 'floatspin', 'combo',
        'checkbox', 'radio', 'dbedit', 'dbmemo', 'dbcheckbox', 'dbcombo',
        'dblookup', 'dateedit', 'timeedit', 'xxxspin'];
```

同时补 `collectVal`（643 行）的取值分支，从 DOM 读当前值（正在编辑的输入框以 DOM 为准）。

#### （c）增量更新：`patchNode`（3309 行）

默认行为是"JSON 变了就整节点重建"（`syncChildren` 2810 行：同一父节点下走
`patchNode`，否则 `destroyNode` + `createNode`）。**重建会丢焦点、丢滚动位置**。

纯展示型控件不改 `patchNode` 也能用；**输入型控件建议补一条**，实现"值/文本变了就地
更新"的轻路径。

#### （d）值回写：`src/core/lwdispatch.pas:225` `LWApplyValue`

```pascal
  if C is TXxxSpin then
  begin
    TXxxSpin(C).Value := StrToIntDef(s, TXxxSpin(C).Value);
    Exit;
  end;
```

注意：

- **必须放在通用兜底之前**。函数末尾有 `if C is TEdit ... else if C is TMemo ...` 的
  通用链，新分支写在它后面永远轮不到。
- `s` 是浏览器送来的 `val`（已确认是标量，对象/数组会被提前丢弃，坑 142）。
- 有特殊语义的值（页签序号、`Values` 映射、`KeyValue`）参照同函数里
  `TPageControl` / `TRadioGroup` / `TDBLookupComboBox` 的写法。
- 数据库控件用 `LWDBWrite(C, s)` 而不是直接写属性。

#### （e）Ext 渲染层（可选）

仅当部署用 `--client=ext` 才需要：`src/client/lw.js` 的渲染 `switch`（`case 'edit'`
约 886 行起）加对应分支，用 `Ext.create(...)` + `addTo(c, ct)`。

**两层必须语义一致**：kind 名、回写属性、事件名都相同，只是渲染实现不同。默认层
两层都支持窗体模板（桌面 `.html` + 移动 `.m.html`、`lw-tpl-mode:window|flat`，控件保持设计期绝对坐标）；
移动端断点/平移回退仅默认 Alpine 层有。

### 2.6 验证与留档

1. 在 `demos/audit` 或 `demos/controls` 摆一个真实实例（给足非默认属性）；
2. 跑 `tools/build_audit.bat` → 重新生成 `docs/CONTROL_MATRIX.md`，确认该控件不再是
   🔶 / ⛔；
3. 跑 `tests/` 回归（控件行为用 `tests/t_controls.py`，涉及布局的加 CDP 探针）；
4. 把映射行写进 `docs/lazarusWeb控件属性映射表.md`（LCL / kind / 浏览器端 / 事件 四列）；
5. 若窗体配了模板，确认新控件在 `.lfm` 里有明确的 `Left/Top/Width/Height`：
   当前模板只是背景装饰层，不搬动控件、也不改控件高度，位置完全由设计期
   坐标决定（见 `MANUAL.md` §16）。

---

## 3. 一次最小可用改动的清单

| # | 文件 | 改动 |
|---|---|---|
| 1 | `src/lwcore.lpk`、`src/lwserver.lpk`、业务 `.lpi` | 加第三方包依赖 |
| 2 | 控件单元 `initialization` | `RegisterClass(TXxx)` |
| 3 | `src/core/lwwriter.pas` `KindOf` | 加一行 `else if C is TXxx`，位置在祖先之前 |
| 4 | `src/core/lwwriter.pas` `WriteKindPropsBody` | 加属性分支 |
| 5 | `src/core/lwbase.pas` `IsLWClickEvent` | 加事件名 |
| 6 | `src/client/lw-alpine.js` `innerOf` | 加 `case` 渲染分支 |
| 7 | `src/client/lw-alpine.js` `FIELD_KINDS` / `collectVal` | 输入类才需要 |
| 8 | `src/core/lwdispatch.pas` `LWApplyValue` | 加回写分支（兜底之前） |
| 9 | `src/client/lw.js`（可选） | Ext 层同 kind 分支 |
| 10 | `docs/lazarusWeb控件属性映射表.md`、`docs/CONTROL_MATRIX.md` | 留档 + 重跑审计 |

---

## 4. 三个必须先确认的技术风险

### 4.1 `nogui` widgetset 能否构造

服务端是 `LCLWidgetType=nogui` 的**无头 widgetset**。依赖 Win32 句柄、`TImageList`、
`LCLGlyphs` 标准字形的控件会**构造即抛异常**——原生 `TDBNavigator` 就是
`FPImageException`，框架只能用子类 `TLWDBNavigator` 替代（`docs/lazarusWeb控件属性映射表.md`「创建失败」）。

**接入前先跑这个 20 行验证**，比改完六处再调试便宜得多：

```pascal
program probe;
{$mode objfpc}{$H+}
uses Interfaces, Classes, Forms, XxxUnit;
var C: TXxxSpin;
begin
  Application.Initialize;          // nogui 下也必须走一次
  C := TXxxSpin.CreateNew(nil);
  try
    C.Name := 'probe';
    C.Width := 120; C.Height := 24;
    WriteLn('create ok: ', C.ClassName, ' ', C.Width, 'x', C.Height);
  finally
    C.Free;
  end;
end.
```

编译时链接 `nogui` 的 LCL 单元（工程 `.lpi` 里 `LCLWidgetType=nogui`）。

### 4.2 绘制型控件不会自动出图

`OnPaint` / `OnDrawCell` / `Canvas` 在 nogui 下**画不出任何像素**——没有设备上下文。

正确路径是"服务端下发数据标记、浏览器端渲染"，`TDrawGrid` 就是这么做的：

```pascal
LWSetDrawCellText(G, c, r, '@bar(72,#dc2626)');   // 进度条
LWSetDrawCellText(G, c, r, '@chip(已审,#0F6E56)'); // 徽章
// 另有 @spark(...) 迷你图、@stars(0-5) 星级，实现见 lwui / lw-alpine.js
```

所以：如果第三方控件的价值全在自绘（图表、仪表、甘特图），**不要试图搬运它的绘制
代码**，而是把它的数据模型序列化成 JSON，在 `innerOf` 里用 SVG/Canvas 重画。

### 4.3 内部子控件泄漏

不少复合控件在内部自建 `TEdit` / `TSpeedButton` / 单元格编辑器。不做过滤时它们会被
`WriteChildren` 当成真实子控件序列化出去，页面上多出几个位置在 (0,0) 的杂散节点。

处理：在 `lwwriter.IsInternalControl` 里加判断（现有规则按 `Owner`/`ClassNameIs`
识别 `TStringGrid` / `TTabControl` 的内部件）。

---

## 5. 容易混淆的一类：第三方 JS 组件

**不要把 JS 组件库硬塞进 kind 链路。** 官方预留了逃生舱：

```pascal
// 服务端注册数据端点
App.AddAjax('items/price', @HandleItemsPrice);
```

```javascript
// 前端直接取数，自管渲染
fetch('/lw/ajax/items/price?sid=' + sid).then(r => r.json()).then(initChart);
```

配合 `TLWHTMLFrame`（`TLWHTMLFrame.HTML` 下发一段 HTML，脚本会被执行）即可把
ECharts / Select2 / DataTables 之类整块嵌进窗体，绕开控件树协议。详见 README
「自定义 AJAX 端点」一节。

---

## 6. 参考索引

| 内容 | 位置 |
|---|---|
| 官方扩展流程 | `docs/MANUAL.md` §15 |
| 控件/属性映射总表 | `docs/lazarusWeb控件属性映射表.md` |
| 实测覆盖率矩阵 | `docs/CONTROL_MATRIX.md`（`tools/build_audit.bat` 生成） |
| kind 判定 | `src/core/lwwriter.pas` `KindOf` |
| 属性下发 | `src/core/lwwriter.pas` `WriteKindPropsBody` |
| 事件白名单 | `src/core/lwbase.pas` `IsLWClickEvent` |
| 值回写 | `src/core/lwdispatch.pas` `LWApplyValue` |
| 默认层渲染 | `src/client/lw-alpine.js` `innerOf` |
| 节点创建/几何 | `src/client/lw-alpine.js` `createNode` / `placeNode` |
| 增量更新 | `src/client/lw-alpine.js` `patchNode` |
| Ext 层渲染 | `src/client/lw.js`（`case 'edit'` 起的 `switch`） |
| 无头构造失败的既有案例 | `docs/lazarusWeb控件属性映射表.md`「创建失败」/ `src/core/lwdbnav.pas` |
