# 实例：把真实第三方控件 TAChart 的 TChart 绑定进 lazarusWeb

> **先看这条（2026-11-25 更新）**：本文第 4 步"改 `KindOf`"已经不是必需动作。
> 现在用运行期登记 `LWRegisterControlKind(TChart, 'chart', @Props)` 就能把
> `TChart` 接进 `chart` kind，**不用改框架源码**；整套代码由 `tools/lwbinder`
> 生成，可直接运行的验收样张在 `demos/tachartdemo/`。本文保留作为机制讲解与
> TChart 数据模型（Series → JSON）的参考，步骤以"生成器 + 登记表"为准。

> 这是一篇**可照做的完整实例**。机制总览见 `docs/THIRDPARTY_BINDING.md`，本文只讲一个
> 具体控件——Lazarus 自带的第三方图表包 **TAChart** 里的 `TChart`——从"能构造"到
> "浏览器里画出图"的全过程。文中所有类名、属性、字段名、源码位置、行号都取自
> 2026-11-19 本机实测（`C:\111\lazarus` + `C:\lazarusWeb\src`），不是示例占位符。

---

## 0. 为什么选 TChart 当例子

"绑定第三方控件"最容易被讲成空话，因为很多第三方控件根本过不了服务端的第一关。
先看实测筛选结果，这就是选它的理由：

| 真实第三方控件 | 包 | nogui 编译 | 能否当服务端实例 |
|---|---|---|---|
| **TAChart / TChart** | `tachartlazaruspkg.lpk` | ✅ 通过（43693 行） | **能**，本文主角 |
| SynEdit / TSynEdit | `synedit.lpk` | ✅ 通过（122409 行） | 能（绘制型，另讲） |
| VirtualTreeView / TLazVirtualStringTree | `laz.virtualtreeview_package.lpk` | ❌ 失败 | 不能直接构造，见 §7 |

实测命令与输出（原文保留）：

```
$ lazbuild -B --ws=nogui tachartlazaruspkg.lpk
(1008) 43693 lines compiled, 7.6 sec
CHART_EXIT=0

$ lazbuild -B --ws=nogui laz.virtualtreeview_package.lpk
delphicompat.pas(140,2) Fatal: (2013) Cannot open include file "uses.inc"
Error: Compile required packages failed: laz.virtualtreeview_package 5.5.3.1
EXIT=2
```

TChart 胜在三点：**nogui 下能构造**、**数据模型清晰**（Series → 点集）、**框架已有
`chart` kind 的 SVG 渲染器可直接复用**——它把"服务端控件"和"浏览器画面"之间的
数据契约讲得最清楚。

---

## 1. 先看清要打通的那条链路

lazarusWeb 不是把控件像素搬到浏览器，而是"服务端真 LCL 控件树 + 浏览器按 `kind`
渲染"。TChart 要显示出来，必须打通：

```
TChart（服务端真控件，nogui 构造）
   │  KindOf(TChart)              → 'tachart'
   │  WriteKindPropsBody          → 把 Series/XValue/YValue 转成 JSON
   ▼
JSON 节点 {kind:'tachart', charttype, title, categories, series}
   │  lw-alpine.js innerOf()      → 复用 chartSvg(n) 画 SVG
   ▼
浏览器 DOM（<svg> 折线/柱状/饼图）
   │  （图表只读：本例无值回写）
   ▼
无需回写 → 不碰 LWApplyValue / IsLWClickEvent
```

**这一步的判断很重要**：TChart 是纯展示控件，浏览器端没有"用户把图拖回去改数据"
的需求，所以本例**不需要**事件白名单和值回写。这正是第三方控件绑定的两类情形：

- **只读展示型**（图表、仪表、图片）：只需 ①②③ 三步（构造→kind→属性下发→渲染）。
- **可编辑输入型**（数字框、日期框、树）：三步之外还要补事件、回写、增量更新。

本文选只读展示型，因为它最能集中讲清"数据桥接"这个核心，且代码量小、可验证。

---

## 2. 第 0 步：先验证 nogui 能构造（别跳过）

**这是所有工作里最该先做的一步。** 第三方控件若依赖 Win32 句柄、原生 Canvas、
TImageList，在 nogui 无头 widgetset 下会构造即抛异常。改六处代码再发现构造不了，
前面的活全白干。

我写了个 52 行探针（`tests/vtchart_probe/probe.lpr`），用真实 TChart API 实测：
构造 → 设标题 → 加 Series → 加数据点 → 读回。结果文件原文：

```
create ok: TChart 400x240 series=0
title=月度销量
seriescount=1
series0.title=销量
series0.count=3
  pt[0] x=0 y=12
  pt[1] x=1 y=19
  pt[2] x=2 y=15
```

结论：`TChart.Create`、`Title.Text.Text`、`TLineSeries.Create`、`AddXY`、
`SeriesCount`、`S.Count`、`XValue[i]`、`YValue[i]` 在 nogui 下**全部可用**。
探针工程本身也是一份可复用的模板，路径见 `tests/vtchart_probe/`。

探针里踩到的两个真实 API 坑，先记下来（§6 会展开）：

1. 必须 `uses Interfaces, Forms, Graphics`——`Application`/`clRed` 分别来自
   `Forms`/`Graphics`，缺一个就 `Identifier not found`。
2. `Ch.Series[0]` 的静态类型是 `TBasicChartSeries`，**没有** `.Title/.Count` 成员；
   要读数据得持有具体子类变量（如 `S: TLineSeries`）再读 `S.Count`。

---

## 3. 第 1 步：让控件能编译进来、能被 lfm 实例化

### 3.1 加包依赖

TChart 在 `tachartlazaruspkg` 包里。把它加进两个运行期包和业务工程：

- `src/lwcore.lpk`：`<RequiredPkgs>` 增一项 `<PackageName Value="tachartlazaruspkg"/>`
- `src/lwserver.lpk`：同上
- 业务 `.lpi`：`Packages/RequiredPackages` 增 `<PackageName Value="tachartlazaruspkg"/>`

真实的 `<RequiredPkgs>` 结构（`lwserver.lpk:110`）：

```xml
<RequiredPkgs Count="3">
  <Item1><PackageName Value="LCL"/></Item1>
  <Item2><PackageName Value="FCL"/></Item2>
  <Item3><PackageName Value="lwcore"/></Item3>
</RequiredPkgs>
```

加 TChart 后 `Count` 改 4、增 `Item4`。

> 若只想做纯代码创建的实例（不用 lfm 拖控件），可省掉 lfm 相关步骤，
> 直接在代码里 `TChart.Create(Self)`。

### 3.2 注册类，让 lfm 能流式加载

lfm 里出现 `object Chart1: TChart` 时，运行时必须能按类名找到类，否则报
`Class TChart not found`。在某个总是被 `uses` 的单元 `initialization` 段注册
（仿 `lwchart.pas:175` 的 `RegisterClass(TLWChart)`）：

```pascal
uses ..., TAGraph;   // TChart 在 TAGraph 单元（tagraph.pas:184 定义）

initialization
  RegisterClass(TChart);
end.
```

⚠️ 不要指望 `RegisterClassAlias` 顶替——`docs/lazarusWeb控件属性映射表.md` 坑 29/41 已推翻早期 alias
方案：lfm 存的是哪个类名，就得让那个类名本身可注册。

---

## 4. 第 2 步：`KindOf` 加分支（派生顺序敏感）

位置：`src/core/lwwriter.pas:196` `function KindOf(C: TControl): string;`

加一行：

```pascal
  else if C is TChart then Result := 'tachart'
```

**放哪儿有讲究。** `KindOf` 是一条 `if ... else if` 长链，**派生类必须排在祖先前面**。
`TChart` 继承自 `TCustomChart` → `TCustomControl`，不和 `TEdit/TPanel` 族冲突，理论上
放哪都不会被抢；但框架约定把自定义/第三方控件集中在链的前段（和
`TLWChart`、`TLWCaptcha` 一起，见 `lwwriter.pas:220-227`）。稳妥做法：紧跟在
`TLWChart` 分支附近插入。

对照记忆口诀：**若你的控件是 `TEdit`/`TPanel`/`TCustomControl` 的后代，分支必须插在
对应祖先判断之前**，否则被通用分支截胡，属性只下发一半。TChart 虽是
`TCustomControl` 后代，但 `KindOf` 里没有裸的 `TCustomControl` 兜底分支，所以安全。
（VirtualTreeView 就没这么幸运——它是 `TCustomControl` 后代且若放在通用控件之后会被抢。）

给新 kind 起名 `tachart` 而非复用 `chart`，是为了不碰框架自研 `TLWChart` 的现有逻辑；
渲染层再显式复用它的 `chartSvg`，两全其美。

---

## 5. 第 3 步：下发属性（核心：把 Series 桥接成 JSON）

位置：`src/core/lwwriter.pas` `procedure TLWWriter.WriteKindPropsBody`，`chart` 分支在
1910 行附近。仿它加一个 `tachart` 分支。目标 JSON 必须和渲染器 `chartSvg` 的字段
**逐字对齐**（字段名见 `lw-alpine.js:908-918`）：

| JSON 字段 | 类型 | 来源 |
|---|---|---|
| `charttype` | string | `'line'`/`'bar'`/`'pie'` |
| `title` | string | `Chart.Title.Text.Text` |
| `categories` | string[] | X 轴标签（本例用点的 X 值格式化） |
| `series` | `{name,values:number[]}[]` | 每个 Series 名 + 点集 Y 值 |

桥接代码（可直接照抄，变量名与框架 `chart` 分支保持一致）：

```pascal
  else if AKind = 'tachart' then
  begin
    { TAChart TChart → 框架 chart 渲染器的数据契约。
      实测TAGraph/TASeries 在 nogui 下可构造、可读点集（见 §2 探针）。 }
    Ch := TChart(C);
    O.Add('charttype', 'line');          // 本例只做折线；多 Series/其它类型见本节末尾
    O.Add('title', Ch.Title.Text.Text);

    items := TJSONArray.Create;          // categories：X 轴标签
    vals  := TJSONArray.Create;          // series[0].values：Y 值
    if Ch.SeriesCount > 0 then
    begin
      S := TLineSeries(Ch.Series[0]);    // 类型强转：见 §8 坑 2
      for j := 0 to S.Count - 1 do
      begin
        JArrAddStr(items, FloatToStr(S.XValue[j]));
        vals.Add(S.YValue[j]);           // Double 直接进 JSON 数组
      end;
    end;
    O.Add('categories', items);

    seri := TJSONArray.Create;
    b := TJSONObject.Create;
    if Ch.SeriesCount > 0 then
      b.Add('name', TLineSeries(Ch.Series[0]).Title)
    else
      b.Add('name', '');
    b.Add('values', vals);
    seri.Add(b);
    O.Add('series', seri);
  end
```

需要额外声明的局部变量（`WriteKindPropsBody` 现有 `i/j/O/items/b/vals` 之外补）：

```pascal
var
  Ch: TChart;
  S: TLineSeries;
  seri: TJSONArray;
```

并在单元 `uses` 加 `TAGraph, TASeries`。

**容错要求**（框架铁律，见 THIRDPARTY_BINDING.md §2.3）：
`S.Count = 0`、`SeriesCount = 0`、`Title.Text = nil` 都是脏值常态。上面的
`if Ch.SeriesCount > 0` 已挡住空 Series；`Title.Text.Text` 在 nogui 下即使无标题也返回
空串（探针证实），安全。若要更稳，可用 `try/except` 包住整个分支，框架
`WriteControl` 会把异常控件降级成带 `err` 的占位节点，不影响整体 payload。

**多 Series 扩展**：把内层 `for` 改成遍历 `0..Ch.SeriesCount-1`，每条 Series 生成一个
`{name,values}` 对象加进 `seri` 即可，和框架 `chart` 分支（1910-1940 行）写法一致。

**改图表类型**：本例写死 `charttype='line'`。若要跟随 TChart 的真实系列类型，判断第一个
Series 的类即可（TAChart 里 `TLineSeries`/`TBarSeries`/`TPieSeries` 均定义在
`taseries.pas`）：

```pascal
    if Ch.SeriesCount > 0 then
    begin
      if Ch.Series[0] is TPieSeries then O.Add('charttype', 'pie')
      else if Ch.Series[0] is TBarSeries then O.Add('charttype', 'bar')
      else O.Add('charttype', 'line');
    end
    else O.Add('charttype', 'line');
```

（注意：这里的 `is` 判断对 `TBasicChartSeries` 静态类型成立，属于类型判定而非成员访问，
不受 §8 坑 2 限制。`TBarSeries`/`TPieSeries` 需 `uses TASeries`。）

---

## 6. 第 4 步：浏览器渲染（复用现成 SVG 渲染器）

位置：`src/client/lw-alpine.js` `function innerOf(node, st)` 的 `switch (k)`，约 1261 行。

因为第 5 步产出的 JSON 和框架 `chart` kind 完全同构，**这里一行就能接上**——让
`tachart` 走和 `chart` 一样的渲染分支：

```javascript
            case 'chart':
            case 'tachart':          // ← 新增：复用同一套 SVG 渲染
                return '<div class="lw-chart lw-boxed" id="lw-ch-' + id + '"></div>';
```

渲染实际发生在 `chartSvg(n)`（`lw-alpine.js:915`），读取的正是
`charttype/title/categories/series` 四个字段。因为 `tachart` 节点带了这些字段，
无需改 `chartSvg`。内容指纹 `chartSig(n)`（909 行）也用同样四字段，所以运行时改数据后
任意事件协调都会自动重画图表——和自研 `TLWChart` 行为一致。

**如果不用现成渲染器**：想要 TChart 的原生观感（网格、图例、坐标轴刻度），就在
`innerOf` 里自己拼 `<svg>` 或 `<canvas>`，但注意 nogui 下不能复用 TChart 的 `OnPaint`
像素（`docs/THIRDPARTY_BINDING.md` §4.2）——所有坐标、刻度、颜色都得自己按数据算。
这是一条更长的路，本例不展开。

### 只读控件不需要的两件事

- **不用改 `FIELD_KINDS` / `collectVal`**：图表没有可编辑值。
- **不用改 `LWApplyValue` / `IsLWClickEvent`**：没有浏览器→服务端的输入回传。

这就是只读展示型控件比输入型少三步的原因。

---

## 7. 第 5 步：验证与留档

1. **构造探针**：`tests/vtchart_probe/` 已给出可编译工程，`lazbuild --ws=nogui probe.lpi`
   后运行，比对 `probe_result.txt`（§2）。这是最快的回归。
2. **摆一个真实实例**：在 `demos/audit` 的 lfm 里加 `object Chart1: TChart`，设置
   `Align=alClient`，代码里 `AddXY` 几个点。给足非默认属性（标题、多 Series），
   避免默认值掩盖问题。
3. **重跑审计**：`tools/build_audit.bat` 重新生成 `docs/CONTROL_MATRIX.md`，确认
   `TChart` 不再是 unknown 灰框。
4. **映射留档**：在 `docs/lazarusWeb控件属性映射表.md` 加一行：

   | LCL 控件 | kind | 浏览器端 | 事件 |
   |---|---|---|---|
   | TChart (TAChart) | tachart | SVG 折线/柱/饼（复用 chartSvg） | 无（只读） |

5. **端到端**：用 `tests/` 的 CDP 探针抓 DOM，确认 `<svg>` 存在、`series` 点数正确、
   切主题时图表颜色跟随 `lw-ch-*` 类变化（渲染器 923 行注释：颜色走 class 承载，
   SVG 的 `fill` 不认 `var()`）。

---

## 8. 两个必须知道的真实坑

### 坑 1：VirtualTreeView 过不了 nogui 这关

它是"最适合 lazarusWeb 数据模型"的控件（虚拟树靠 `OnGetText` 按需供数据），但
**本机实测 nogui 编译失败**：包依赖 `lclextensions`，其 `delphicompat.pas` 在 nogui 下
找不到 `uses.inc`（§0 实测输出）。若一定要用它，三条路：

1. 先让 `lclextensions` 适配 nogui（补 include 路径），再编译 VT——工作量大；
2. 不实例化 VT 本体，只在服务端用普通数据结构存树，把数据序列化下发、浏览器端渲染
   （即它自己的"虚拟数据"模型，正好和 lazarusWeb 契合）——推荐；
3. 走 JS 组件逃生舱（`TLWHTMLFrame` + `AddAjax`），前端直接画树。

这正是 `docs/THIRDPARTY_BINDING.md` §4.1 强调的"先验证 nogui 构造"的现实意义。

### 坑 2：`Ch.Series[i]` 静态类型没有数据成员

`TChart.Series` 是 `TChartSeriesList`，元素静态类型是 `TBasicChartSeries`——它只有
`Title` 之类通用属性，**没有** `Count`/`XValue[]`/`YValue[]`/`AddXY`。这些在具体子类
`TLineSeries`/TChartSeries`（`taseries.pas`）上。所以：

```pascal
// ✗ 编译不过：Identifier idents no member "Count"
Ch.Series[0].Count;

// ✓ 持有具体子类变量
S := TLineSeries(Ch.Series[0]);
n := S.Count;
```

探针第一次编译就栽在这里（`probe.lpr(31,3) Error: no member "Title"`），改用
`S.Title` 后通过。桥接代码 §5 已按正确写法给出。

### 坑 3：`uses` 缺单元

nogui 探针最小 `uses` 必须含 `Interfaces, Forms, Graphics`：`Interfaces` 提供 widgetset，
`Forms` 提供 `Application`（若调用 `Application.Initialize`），`Graphics` 提供 `clRed`
等颜色常量。少哪个报 `Identifier not found`。

---

## 9. 一页速查：只读展示型第三方控件接入清单

| # | 文件 | 改动 |
|---|---|---|
| 1 | `src/lwcore.lpk`、`src/lwserver.lpk`、业务 `.lpi` | 加第三方包依赖（TChart → tachartlazaruspkg） |
| 2 | 公共单元 `initialization` | `RegisterClass(TChart)` |
| 3 | `src/core/lwwriter.pas` `KindOf` | 加 `else if C is TChart then Result := 'tachart'` |
| 4 | `src/core/lwwriter.pas` `WriteKindPropsBody` | 加 `tachart` 分支：Series→chart JSON |
| 5 | `src/client/lw-alpine.js` `innerOf` | `case 'tachart':` 复用 chart 渲染 |
| 6 | 验证 | nogui 构造探针 + audit 审计 + CDP 端到端 |

**可编辑输入型**另需：`IsLWClickEvent`（事件白名单）、`LWApplyValue`（值回写）、
`FIELD_KINDS`/`collectVal`（批量取值）、`patchNode`（增量更新不丢焦点）——
完整清单见 `docs/THIRDPARTY_BINDING.md` §3。

---

## 10. 参考索引

| 内容 | 真实位置 |
|---|---|
| 机制总览 / 六步接入 | `docs/THIRDPARTY_BINDING.md` |
| 官方扩展流程 | `docs/MANUAL.md` §15 |
| kind 判定 | `src/core/lwwriter.pas:196` `KindOf` |
| chart 属性下发（照抄对象） | `src/core/lwwriter.pas:2006` `chart` 分支 |
| chart SVG 渲染器 | `src/client/lw-alpine.js:915` `chartSvg` / `:908` `chartSig` |
| chart 渲染分支 | `src/client/lw-alpine.js:1631` `case 'chart'` |
| 类注册范例 | `src/core/lwchart.pas:175` |
| 包依赖写法 | `src/lwserver.lpk:110` `RequiredPkgs` |
| TChart 类定义 | `C:\111\lazarus\components\tachart\tagraph.pas:184` |
| TLineSeries / AddXY | `...\tachart\taseries.pas:245` / `tacustomseries.pas:213` |
| nogui 构造探针 | `tests/vtchart_probe/probe.lpr` + `probe.lpi` |
| VirtualTreeView 实测失败 | 本文 §0 / §8 坑 1 |
