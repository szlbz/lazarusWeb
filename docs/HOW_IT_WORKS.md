# lazarusWeb 工作原理详解

> 面向第一次读这套代码的人：把"LCL 控件 + 服务端 + 浏览器渲染"这三件事讲成一条线。
> 编写日期 2026-11-11 · 依据工作区当前代码（`src/core` 27 个单元 13226 行，`src/client/lw.js` 2834 行）
> 配套文档：`ARCHITECTURE.md`（模块清单）、`NOTES.md`（35 组踩坑）、`MAPPING.md`（控件映射表）

---

## 0. 先破除一个误解

初次接触时最容易问的是："到底是服务端渲染还是浏览器渲染？"

答案是**都不是**。这套框架里：

> **控件树只有一棵，在服务端。浏览器没有控件，只有"控件的镜像"。**

所以不存在"两套渲染并存"。真实的动作是**一次序列化 + 一次对账**：

```
服务端 LCL 控件树  ──序列化──►  JSON 快照  ──渲染──►  浏览器 Ext 组件树
      ▲                        {id,kind,      ▲                  │
      │                         props,       │                  │
      │                         children}    │                  │
      └──────────── 事件 {id, ev, val} ◄─────┴──────────────────┘
```

- `lwwriter.pas` 负责向右（树 → JSON）
- `lw.js` 负责再向右（JSON → Ext 组件）和向左（事件 → JSON）
- `lwdispatch.pas` 负责最左（JSON → 真实的 LCL 事件调用）

理解了这一点，剩下的全是细节。而细节之所以复杂，都源于一个决定：**用真的 LCL 控件，而不是影子控件**。

---

## 1. 这套方案为什么能成立：三个前提

### 1.1 `TLWForm` 是真正的 `TForm` 后代

不是代理类、不是影子类、不是包装器。`TLWForm = class(TForm)`，所以：

- 在 IDE 里拖上去的 `TButton` / `TEdit` 就是 LCL 自己的控件；
- `.lfm` 原样加载，属性面板、锚点、`Align`、`TabOrder`、事件页全部照常；
- 设计器里摆的布局**就是**浏览器里的布局（同一坐标系、同一套 `Anchors` 计算）。

业务代码唯一要改的一行：

```pascal
TMainForm = class(TLWForm)   // 原来是 class(TForm)
```

这就是"业务代码 100% 复用"的来源，也是整套方案所有收益与所有麻烦的共同根源。

### 1.2 `--ws=nogui`：给 LCL 换一块"没有屏幕的显卡"

服务端用 nogui widgetset 编译，控件**真实创建、真实持有属性、真实保存事件方法指针**，只是不绘制。

但 nogui 这块"显卡"是残的，LCL 里有大量地方默认"有屏幕、有窗口句柄、有消息循环"。`lwws.pas`（333 行）就是补这些。四个最典型的崩溃点：

| 崩溃点 | 根因 | 补丁 |
|---|---|---|
| 创建任何 `TForm` 都 AV | `TCustomForm.AfterConstruction` 读 `Monitor.PixelsPerInch`，nogui 下 `EnumDisplayMonitors` 返回 False，`Monitor = nil` | `TLWWidgetSet = class(TNoGUIWidgetSet)` 补虚拟显示器（1920×1080 @96DPI） |
| `Application.DoubleBuffered` 硬转型崩 | nogui 的 widgetset 实例不是 `TWSCustomForm` 后代，`adbDefault` 走进 `TWSCustomFormClass(WidgetSetClass)` 硬转型 | `LWInstallWidgetSet` 里显式 `adbFalse` |
| 装载带 `TMainMenu` 的 lfm 就 AV | nogui 的 `RegisterMainMenu` 等全部返回 False，菜单 WS 类没注册，`TWSMenuClass(WidgetSetClass)` 拿到 nil | 注册 LCL 空实现类占位，菜单改由浏览器渲染 |
| `Form.Show` 除零 | 真 `Show` 走 `ShowWindow → SetWindowPos`，依赖屏幕像素计算 | `TLWForm.SetVisible` 拦截，翻译成 `SessionShowForm`，**绝不落到 inherited** |

最后一条有个必须注意的判定条件：拦截时要排除 `csLoading in ComponentState`，否则装载 `.lfm` 时给 `Visible` 赋初值那一步也被拦，LCL 内部状态就不一致了（创建窗体时直接除零）。

> **这就是"真控件树"路线的成本**：省下了重写几百个控件的工作，代价是要伺候 LCL 的每一个隐含假设。

### 1.3 假 GDI：文本度量从哪来

比"虚拟显示器"更隐蔽的一层：`Canvas.TextWidth`、`AutoSize`、`GetTextMetrics` 在 nogui 下全部依赖 GDI，而 GDI 不存在。`lwws.pas` 于是把整套 GDI 调用替换成**估算**：

```pascal
function TLWWidgetSet.GetTextExtentPoint32(DC: HDC; Str: PChar; Count: Integer;
  var Size: TSize): Boolean;
begin
  h := CurFontPx;                              // 最近一次 CreateFontIndirect 的字高
  Size.cx := Max(1, Round(Count * h * 0.55));  // 宽度 ≈ 字符数 × 字高 × 0.55
  Size.cy := Round(h * 1.25) + 3;
  Result := True;
end;
```

设计句柄也是假的：`CreateCompatibleDC` 返回常量 `HDC(1000)`，`SelectObject` 返回 0，`GetDeviceCaps` 对 `LOGPIXELSX` 一律回 96。

这套估算足以让 LCL 内部的排版代码不崩、让 `AutoSize` 有个合理的宽度，但它**不认得字形差异**——`0.55` 是按西文平均字宽取的系数，而中文/全角字符的实际宽度约为字高的 1.0 倍。所以：

> **含中文的 `AutoSize` 标签，服务端算出的宽度可能偏窄。**（据代码推算，未逐控件实测）
> 遇到标签被截断，优先检查是"服务端算窄了"还是"浏览器端样式挤了"，而不是去改 CSS。

理解了这一层，就明白为什么文档反复强调"Web 模式下布局以设计器尺寸为准"——服务端手里只有一套近似度量，像素级还原靠的是绝对坐标，不是靠文本重排。

---

## 2. 一次点击的完整回路

以 `lwdispatch.pas:769` 的 `LWHandleEvent` 为主线：

```
浏览器                                    服务端 (fphttpserver, 每请求一线程)
  │                                        │
  │ 1. click → 收集 {id, ev, val}          │
  │    以及同一窗体所有输入框的 vals        │
  ├──────── POST /lw/api/event ───────────►│
  │                                        │ 2. LWApplyFieldSnapshot 回填其它控件值
  │                                        │ 3. LWApplyValue 把 val 写进目标控件
  │                                        │ 4. LWInvokeEvent → RTTI → OnClick
  │                                        │ 5. 业务代码执行（它以为自己在桌面）
  │                                        │ 6. BuildPayload 序列化新树
  │◄──────── 200 {sid, forms:[...]} ───────┤
  │ 7. applyPayload → syncChildren 对账     │
  │    只 patch 变化的节点                   │
```

服务端拿到请求后的三行核心代码：

```pascal
LWApplyFieldSnapshot(S, JGetObj(AReq,'vals'), id);  // ① 先把同窗体其它输入框的最新值写回
LWApplyValue(c, AReq);                              // ② 把 val 写进事件目标控件
LWInvokeEvent(c, ev, row, col);                     // ③ RTTI 找方法指针，调用
```

### 2.1 为什么需要 ①（一个真实存在的 bug）

`lw.js` 只在控件**挂了 `OnChange`** 时才回传值。所以一个没挂 `OnChange` 的编辑框，在服务端永远停留在构建时的初始 `Text`——

于是登录窗体上：用户输了密码 → 点"登录" → 服务端校验的是**空/旧的密码** → 输错也能过。

解法就是让浏览器每次发事件都附带"同一窗体所有输入控件的当前值"（`vals`），服务端在派发事件**之前**整体回填。注意事件目标控件（`SkipId`）要跳过，它自己的值由 ③ 按 `val` 处理。

`LWIsSnapField` 还刻意排除了数据感知控件（`TDBEdit` / `TDBMemo` / …）：它们背后是数据集字段，直接写 `Text` 等于改数据，必须走 `OnSetFieldValue` / `Edit-Post` 通道。

### 2.2 ③ RTTI 派发，以及"按钮不能直接用 RTTI"

标准反射路径是：

```pascal
PP := GetPropInfo(C, AEv);
if (PP = nil) or (PP^.PropType^.Kind <> tkMethod) then Exit;
M := GetMethodProp(C, PP);
if not Assigned(M.Code) then Exit;
TNotifyEvent(M)(C);
```

但按钮必须先走原生 `Click`：

```pascal
if (AEv = 'OnClick') and (C is TButton) then
begin
  TButton(C).Click;   // Click 内部处理 ModalResult，再调 OnClick
  Exit(True);
end;
```

原因在 `TCustomButton.Click` 里那句 `if ModalResult <> mrNone then Form.ModalResult := ModalResult`。**这才是模态对话框点"确定"后关窗的真正机制**。绕过 `Click` 直接调方法指针，nogui 下没有消息循环来接手这件事，`ShowModal` 会一直挂到超时。

同类特判还有：`TDBGrid` 的 `OnTitleClick` / `OnCellClick` 签名是 `(Column: TColumn)` 而不是 `TNotifyEvent`，硬转会栈错乱；`TDBNavigator` 的 `OnClick` 是两参事件且 `BtnClick` 内部自己会触发它。

**这一段是全篇最重要的结论**：`Click`、`ModalResult`、`TSpeedButton` 的组互斥 `SetDown`、`DataSource` 的字段绑定——**全部是 LCL 的原生实现**。框架只是把"用户的手"从鼠标换成了一段 JSON。所以"LCL 控件真的在跑"不是修辞。

---

## 3. 序列化：为什么不能"全量 RTTI dump"

`lwwriter.pas`（1594 行）看起来只是在读属性，其实大部分代码在**替 LCL 补语义**。骨架很简单：

```pascal
function WriteControl(C: TControl): TJSONObject;
begin
  kind := KindOf(C);                      // 70+ 个分支，顺序敏感
  o := MakeBase(C, kind);                 // id/kind/name/x/y/w/h/align/caption/ev/...
  WriteKindProps(C, kind, o);             // 每类控件的专用属性
  o.Add('children', WriteChildren(...));  // 递归
end;
```

难点全在四个地方。

### 3.1 `KindOf` 的顺序敏感

`lcl/interfaces` 里的继承关系会让"按类型从上到下 if"出错：

- `TRadioGroup` / `TCheckGroup` 会落进 `TGroupBox` 分支；
- `TCheckListBox` 会落进 `TListBox`；
- `TValueListEditor` 会落进 `TStringGrid`；
- `TDateEdit` 族是 `TCustomEditButton`（`TCustomEdit` 后代），不先判就退化成普通 `edit`，还会把内部的 `TEdit` + `TSpeedButton` 泄漏成两个杂散节点；
- `TToggleBox` 是 `TCustomCheckBox` 后代而不是 `TButton`，语义是"可保持按下"——按 `button` 渲染 + `Checked` 作 `down` 下发。

所以 `KindOf`（`lwwriter.pas:97`）里每个 `else if` 的先后都是有原因的，改顺序会静默改变渲染结果。

### 3.2 内部控件会污染控件树

LCL 的 `TStringGrid` 内部真的有一个 `TStringCellEditor`，`TRadioGroup` 内部真的有一堆 `TRadioButton`，`TTabControl` 内部真的有一个 `TCustomNotebook`。它们都在 `Controls[]` 里，直接递归序列化会让浏览器多出几十个无名杂散节点（`(0,0)` 处的灰框）。

`IsInternalControl()`（`lwwriter.pas:72`）就是一张逐个点名的黑名单。

### 3.3 属性的"字面值"不等于"用户意图"

- `TPanel` / `TToolBar` 的 `Caption` 默认等于控件名 → 不能渲染出来（`CaptionOf` 里判 `s = C.Name` 就丢弃）；
- `TShape` 的填充色在 `Brush.Color`，`TControl.Color` 对它是无效属性；只读 `Color` 会得到空串 → **白底白框，控件"消失"**；
- `TLWClickEvent` 白名单决定哪些事件下发：只有真的挂了方法指针（`Assigned(M.Code)`）才写进 `ev`，避免浏览器发一堆没人接的事件。

### 3.4 nogui 下有些属性读出来是"假值"

最典型的是窗体客户区尺寸：句柄没创建时 `ClientWidth` 返回构造默认值 320×240，而不是 `.lfm` 里的 1020×680。浏览器照这个尺寸补高度，窗口就被缩到 277px。

```pascal
if AForm.HandleAllocated then
begin
  o.Add('cw', AForm.ClientWidth);
  o.Add('ch', AForm.ClientHeight);
end
else
begin
  o.Add('cw', AForm.Width);      // 句柄没建时 Width 才准
  o.Add('ch', AForm.Height);
end;
```

---

## 4. 浏览器端：不是"渲染"，是"对账"

### 4.1 reconcile

新树到达后 `applyPayload`（`lw.js:2322`）→ `syncChildren`（`lw.js:1802`）按 `id` 对账，三路分支：

```js
list.forEach(function (n) {
    var c = S.comps[n.id];
    if (c && c.__lwParent === ct) patchNode(c, n);        // 已存在 → 只改差异属性
    else { if (c) destroyNode(n.id); createNode(n, ct); } // 新增/换父 → 重建
});
old.forEach(function (id) { if (!keep[id]) destroyNode(id); });  // 消失 → 销毁
```

两个直接好处：

- **输入焦点不丢**：没变的组件实例一个都没动，光标还在原处；
- **不整页刷新**：只有差异节点被 patch。

窗体级别也走同一套：`p.forms` 里没出现的窗体直接 `close + destroy`（服务端删了窗体，浏览器跟着消失）。

### 4.2 布局：绝对定位，不是 CSS 流

LCL 是**绝对坐标 + `Align`/`Anchors`**，没有 CSS 的流式排版。所以 Ext 组件全部按 `x/y/w/h` 绝对定位，`runLayout`（`lw.js:1831`）自己算一遍 `Align`，并在容器 `resize` 时重算——**不交给浏览器去弹性排版**。

这是"像素级还原设计器"的代价，也意味着：**这套框架天生不适合做响应式/移动端**。要自适应，得在业务层自己写 `OnResize` 里重排控件。

### 4.3 推送通道

- 事件：`POST /lw/api/event`，响应里直接带新树（同步），或走 WS；
- 推送：`/lw/ws` 优先，连不上自动退回 `GET /lw/api/poll?after=N` 长轮询；
- 游标协议：推送队列带 `seq`，各页签 `poll?after=N` 各取各的（多个标签页共用一个会话时必须如此）；对话框指令还带 `to=<页签>` 定向，只有发起页弹窗；
- 会话：`sid` 存 localStorage，新标签页 `attach` 到已有会话，过期返回 410 + `gone`（浏览器据此自动新建会话回登录页）。

---

## 5. 最反直觉的一处：`ShowModal` 竟然真的会阻塞

桌面上 `if f.ShowModal = mrOk then ...` 靠的是**嵌套消息循环**。服务端没有消息循环，nogui 连窗口都没有。解法是换一个"能阻塞的东西"：

```
事件请求线程（fphttpserver 每请求一线程）
  │
  ├─ 业务代码调用 ShowModal
  ├─ 把模态指令塞进会话出站队列（带 seq）→ SetEvent 唤醒长轮询/WS
  ├─ TEvent.WaitFor(200)          ← 每 200ms 醒一次，仅为检查超时
  │
  └─ 浏览器点关闭 → POST /lw/api/dlg → FDlgDone.SetEvent → 线程醒来返回 ModalResult
```

关键实现：`lwsession.pas:587` 的 `ShowModalInSession`，等待循环在 `lwsession.pas:246`。

为什么是 200ms 切片而不是一次 `WaitFor(180000)`？源码注释写得很清楚：直接等 180 秒就没法在中途检查超时、也没法响应会话清理。

于是 **`if f.ShowModal = mrOk then ...` 这行代码真的在等用户点**，业务代码一行不改。

代价是那个请求线程被占住（上限 180 秒），同一会话的其它请求只能排队——恰好和桌面"模态期间点不动别处"的语义一致。另外，业务代码**手动**赋值 `ModalResult := mrOk` 也要能关窗，所以 `LWHandleEvent` 在事件派发后还会补一刀：

```pascal
mf := S.ModalForm;
if (mf <> nil) and (mf.ModalResult <> mrNone) then
  S.SessionEndModal(mf, mf.ModalResult);
```

---

## 6. 线程模型总览

```
fphttpserver（每请求一线程）
 ├─ 事件请求线程：回填值 → RTTI 触发业务 → ShowModal 时 TEvent.WaitFor 阻塞在这里
 ├─ 长轮询 / WS 推送：会话出站队列带 seq，多页签游标各取
 ├─ Sweep 线程：过期会话清理
 ├─ TLWServerThread（GUI 构建）：accept 循环在后台线程
 └─ 面板 TTimer（GUI 构建）：主线程定时 swap 日志缓冲（不用 Synchronize）
```

推论（部署时必须知道）：

- 会话全在**进程内存**里，没有外置 Redis → 集群只能靠**粘性会话**（`ip_hash` / `lwhyper` 的 sid 粘性）；
- 每个在线用户**一棵完整控件树**，内存随用户数线性增长；
- 每个事件**一次 HTTP 往返**——内网无感，公网移动网络会明显卡顿。

---

## 7. 与另外两条路线的对比

| | 服务端渲染（fpWeb） | 浏览器渲染（pas2js/WASM） | **本方案** |
|---|---|---|---|
| 控件在哪 | 无（只有 WebModule + 模板） | 浏览器（LCL 逻辑编译成 JS/wasm） | **服务端（真 LCL 树）** |
| 浏览器拿到的 | HTML 字符串 | 编译好的程序 | **控件树 JSON** |
| 状态在哪 | 无状态（靠 Session/隐藏字段） | 浏览器 | **服务端会话内存** |
| 每事件开销 | 一次完整 HTTP 往返 | 0（本地） | 一次 HTTP/WS 往返 |
| 业务代码复用 | 0（要重写界面逻辑） | 部分（需适配浏览器控件） | **100%（改一行基类）** |
| `.lfm` / 设计器 | 不可用 | 需转换 | **原样可用** |
| 扩展新控件 | 写模板 | 写浏览器端控件实现 | **写一条 `KindOf` + 一条渲染分支** |
| 适合 | 后台管理、报表、SEO | 重交互 SPA、离线 | **把内网桌面系统搬到浏览器** |

本方案在"扩展新控件"上的成本优势来自 1.3 节那个选择：**把 Ext JS 当作浏览器端的 widgetset**。不去自己写几百个控件的浏览器实现，而是把每个 LCL 控件"翻译"到一套成熟控件库上——工作量从"重写控件"变成"写映射表 + 写对账逻辑"。

代价是两套语义不完全对齐（绝对定位 vs Ext 布局、`ModalResult` vs Ext window、`Items` vs Ext store），每处不对齐都要写一条专用序列化分支。`lwwriter.pas` 那 1594 行，大半是这些。

---

## 8. 边界与已知限制

**不该用这套方案的场景**：新写的、面向公网的、要响应式和移动端的、要 SEO 的系统。它是"桌面程序 Web 化运行时"，不是通用 Web 框架。

**内建限制**（见 `ARCHITECTURE.md` §3.7）：

- 模态超时 180 秒；同一会话同时只允许一个对话框；
- `TOpenDialog` 不能浏览服务端磁盘（只能"选文件→上传"）；
- `TSplitter` 不支持拖动；`TUpDown/TProgressBar/TTrackBar` 单向；
- 高 DPI 按虚拟显示器 96 DPI 处理，125%/150% 设计的 `.lfm` 会被缩回 96；
- 未适配控件在浏览器端是灰框占位（支持度见 `CONTROL_MATRIX.md`）；
- PDF 直出暂以浏览器"另存为 PDF"代替。

---

## 9. 想读代码的话，按这个顺序

| 顺序 | 文件 | 看什么 | 关键位置 |
|---|---|---|---|
| 1 | `src/core/lwws.pas` | 整套方案的地基：虚拟显示器 + 假 GDI | `TLWWidgetSet` L56、`GetTextExtentPoint32` L184 |
| 2 | `src/core/lwform.pas` | `TLWForm` 如何拦截 `Visible` | `SetVisible` |
| 3 | `src/core/lwsession.pas` | 会话、窗体清单、出站队列、模态 | `BuildPayload` L527、`ShowModalInSession` L587 |
| 4 | `src/core/lwwriter.pas` | 树 → JSON：白名单、内部控件、特判 | `KindOf` L97、`MakeBase` L241、`WriteControl` L1461、`WriteForm` L1507 |
| 5 | `src/core/lwdispatch.pas` | 事件 → RTTI：回填、派发、按钮特判 | `LWInvokeEvent` L662、`LWHandleEvent` L769 |
| 6 | `src/client/lw.js` | 对账、布局、事件捕获、推送 | `fire` L257、`createNode` L582、`syncChildren` L1802、`runLayout` L1831、`applyPayload` L2322 |
| 7 | `src/core/lwhttp.pas` | 路由表、静态资源、上传下载 | 路由分发 |

**最快的验证方式**不是读代码，是跑一个 demo 把 JSON 打出来看：

```bat
build.bat hello
demos\hello\hello.exe --port=8090 --verbose
```

浏览器打开 `http://127.0.0.1:8090/`，然后 `curl "http://127.0.0.1:8090/lw/api/tree?sid=<你的sid>"` 就能看到那棵树的真实样子——比任何文档都直观。

---

## 10. 一句话总结

> 它不渲染两遍。它把 **LCL 控件树**当作唯一数据源，把 **Ext JS** 当作一块可以远程刷新的"显示器"，把 **HTTP 请求线程**当作可以阻塞的消息循环。三件事凑齐，桌面程序的执行模型就在浏览器里被完整复现了。

---

## 附：容易踩的三个理解误区

1. **"浏览器在跑 LCL"** —— 不。浏览器一行 Pascal 都没有，它跑的是 Ext JS。LCL 只在服务端进程里跑。
2. **"每次事件都重建整棵树"** —— 服务端确实重新序列化整棵树（`BuildPayload`），但浏览器端按 `id` 对账，只有差异节点被 patch，焦点和输入态都保留。
3. **"`ShowModal` 是浏览器端的弹窗"** —— 不。服务端线程真的在等，浏览器只是它等待的对象。浏览器刷新/关标签页会让它等到 180 秒超时。
