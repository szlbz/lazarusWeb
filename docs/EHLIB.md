# EhLib 可选支持（TDBGridEh → TLWDBGrid）

## 1. 设计思路

EhLib 的支持做成**独立设计期包** `src/design/lwehlib.lpk`，`lwdesign.lpk` 不新增任何 EhLib 依赖：

- 未安装 EhLib 的机器：不编译 `lwehlib.lpk`，`lwdesign` 与运行时完全不受影响。
- 需要 EhLib 的机器：安装 `lwehlib.lpk`，获得 `TDBGridEh` 的转换命令。
- 开关放在 `src/design/lwehlib.inc`：控制包内注册哪些能力（当前只有 `LW_EHLIB_DBGRIDEH`）。

**为什么不是直接改 `lwdesign.lpk` + inc**：`.lpk` 是 XML，`RequiredPkgs` 和搜索路径由 IDE 解析；FPC 的 `{$IFDEF}` 只作用于 Pascal 源码，无法条件化包依赖。若 `lwdesign` 无条件依赖 `EhLib`，未安装 EhLib 的机器连 `lwdesign` 都编不过。独立可选包是 Lazarus 里实现"可选第三方支持"的标准做法（框架里的 `lwvst.lpk` 同理）。

## 2. 启用

### 2.1 准备 EhLib 包

EhLib 自带 Lazarus 包 `Lazarus/Src/ehlib.lpk`（包名 `EhLib`，依赖 `Printer4Lazarus` / `IDEIntf` / `LCL` / `FCL`）。

在 IDE 中：`Package → Open Package File` 打开 `ehlib.lpk`，点 `Compile`，再 `Install`。

命令行（不绑定版本，路径按实际安装位置给）：

```
lazbuild --add-package="<EhLib 根>\Lazarus\Src\ehlib.lpk"
lazbuild "<EhLib 根>\Lazarus\Src\ehlib.lpk"
```

### 2.2 编译并安装 lwehlib

```
lazbuild C:\lazarusWeb\src\design\lwehlib.lpk
```

然后在 IDE 中打开该包并 `Install`。安装后，设计器里选中 `TDBGridEh`，右键菜单会多出：

```
转换为 lazarusWeb TLWDBGrid…
```

### 2.3 开关

`src/design/lwehlib.inc`：

```pascal
{$DEFINE LW_EHLIB_DBGRIDEH}
```

注释掉后重编译 `lwehlib.lpk`，转换命令不再注册（包仍依赖 EhLib，只是不注册编辑器）。

## 3. 转换行为

转换器把 `TDBGridEh` 替换为 `TLWDBGrid`，复制：

- 位置、尺寸、`Align`、`Anchors`、`Visible`、`Enabled`、`TabOrder`
- `Color`、`Font`、`TitleFont`
- `ReadOnly`、`DataSource`
- `Options`（EhLib 的同名枚举逐项映射到 LCL；`dgColumnMove` 统一打开）
- `Columns`：`FieldName`、`Title.Caption`、`Title.Alignment`、`Title.Font`、`Width`、`Visible`、`Alignment`、`ReadOnly`、`PickList`、`DropDownRows`、`DisplayFormat`、`Color`
- `UseMultiTitle` → `TLWDBGrid.MultiTitle`

转换后运行时**不需要 EhLib**：`TLWDBGrid` 是普通 `TDBGrid` 后代，`lwwriter` 按现有路径序列化。

## 4. 多表头

EhLib 的多表头写法是列标题里用 `|` 分层，例如：

```
'基本信息|姓名'
'基本信息|年龄'
'联系方式|电话'
'备注'
```

`UseMultiTitle=True` 时，EhLib 会自动把相邻同前缀的列合并成超级标题。转换时 `Title.Caption` 原样保留，`TLWDBGrid.MultiTitle` 置为 `True`。

`lwwriter` 会下发两份表头结构：

- `hrows`：行矩阵，每个单元格带 `t`（文本）、`cs`（colspan）、`rs`（rowspan）、`a`（叶列下标）。Alpine 外壳按行拼 `<tr>`。
- `htree`：嵌套树 `[{t,a,n,c:[...]}]`。Ext 外壳递归生成嵌套 `columns`。

两者都支持任意层级；没有 `a` 的格子是分组标题，不挂 `OnTitleClick`。未打开 `MultiTitle` 时，继续使用原来的两级 `HeaderGroups`（`hg`），行为不变。

## 5. 树形（TreeView）

EhLib 的树形不在 `TDBGridEh` 自己的属性里，而在数据集：

```pascal
MemTable.TreeList.KeyFieldName := 'id';
MemTable.TreeList.RefParentFieldName := 'parent_id';
MemTable.TreeList.DefaultNodeExpanded := True;
MemTable.TreeList.Active := True;
```

网格只判断 `MemTableIsTreeList`，成立就在首列画缩进、树线、展开标记；`Grid.TreeViewParams` 只控制 `GlyphStyle` / `ShowTreeLines` 这两个外观项。

转换时 `lwehlibconvert.LWCopyTreeInfo` 把上面三项搬到 `TLWDBGrid`：

| EhLib | TLWDBGrid |
| --- | --- |
| `TreeList.KeyFieldName` | `TreeKeyField` |
| `TreeList.RefParentFieldName` | `TreeParentField` |
| `TreeList.DefaultNodeExpanded` | `TreeDefaultExpanded` |

`TreeKeyField` 非空即启用树形网格，`lwwriter` 在序列化时下发：

- `tree`：`{k,p,ind,exp}`（键字段、父字段、缩进像素、默认展开）
- `keys`：每行的键
- `lv`：每行的层级（沿父链计算，成环/找不到父按根处理）
- `hc`：每行是否有子节点
- `pid`：父行下标（`-1` 为根），前端折叠时直接上溯，不依赖行顺序

行数据仍是原来的扁平 `rows` 矩阵，旧前端不认识 `tree` 就按平表渲染。前端表现：

- **Alpine**：首列左侧缩进 + `▸/▾` 箭头，折叠纯客户端（不发请求）；展开状态按 key 记在会话内存里，数据刷新后保持。
- **Ext**：`Ext.tree.Panel` + `TreeStore`，首列是顶层 `treecolumn`，其余列仍按 `htree` 分组；重建 store 前按 key 记录展开状态，重建后还原。

注意：

- **树形模式自动停用分页**（`PageSize` 视为 0）。只发一页会让父节点落在页外，层级算不出来。
- 树形列固定为**第一个可见列**（与 EhLib 的绘制位置一致）。
- **Ext 端树列必须是顶层第一列**。如果原标题写成 `组织架构|名称`，`Ext.tree.Panel` 会把树列从分组里提出来，分组只剩其余列，表头看起来是断的。建议给树列一个独立的顶级标题（如 `组织架构`），其余列再进分组；Alpine 端不受这个限制（表头直接来自服务端 `hrows`）。
- Ext 使用原生树样式（文件夹/三角图标 + 连接线），Alpine 用 `▸/▾` 文本箭头；两者缩进与层级一致。
- 过滤仍可用；父节点被过滤掉时该行按根节点缩进显示，不会凭空多出展开箭头。
- 运行时不依赖 EhLib：层级由 `lwwriter` 按 key/parent 两列算，不需要 `TMemTableEh`。

完整示例见 `demos/ehlibTree`（多表头 + 四层树 + 转换）。

## 6. 未覆盖的 EhLib 特性

转换只搬 Web 表格能表达的部分，以下不映射：

- `FrozenCols`（冻结列）：`TLWDBGrid` 暂无冻结列属性；转换时会提示。
- `FooterRowCount` / 每列 `Footer`：转换时会提示，请改用 `TLWDBGrid.SummaryType` / `SummaryField`（单列汇总）。
- EhLib 专有单元格编辑器、下拉框、排序标记、过滤按钮、行明细面板等。
- 事件处理器（`OnTitleClick` 等）不复制，需在转换后重新挂。

## 7. 相关文件

| 文件 | 作用 |
| --- | --- |
| `src/design/lwehlib.lpk` | 可选设计期包，依赖 `lwdesign` + `EhLib` |
| `src/design/lwdsgnehlib.pas` | 设计期转换命令注册 |
| `src/design/lwehlibconvert.pas` | 转换逻辑（运行时也可调用），含树形配置复制 |
| `src/design/lwehlib.inc` | 编译开关 |
| `src/core/lwdbgrid.pas` | `MultiTitle`、`TreeKeyField` / `TreeParentField` / `TreeIndent` / `TreeDefaultExpanded` |
| `src/core/lwwriter.pas` | `hrows` / `htree` / `tree` / `keys` / `lv` / `hc` / `pid` 序列化 |
| `src/client/lw.js` | Ext 嵌套表头 + `tree.Panel` 树形网格 |
| `src/client/lw-alpine.js` | Alpine 矩阵表头 + 缩进/折叠 |
| `demos/ehlibTree` | EhLib 多表头 + 树形 demo |
