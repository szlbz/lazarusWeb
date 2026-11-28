# ehlibTree — EhLib 多表头 + 树形网格 demo

演示 `TDBGridEh`（MemTableEh 树形 + `UseMultiTitle`）转换为 lazarusWeb `TLWDBGrid` 后的效果：

- **多级表头**：`编制|人数`、`经营数据|产值(万元)|本月`
- **树形**：四层组织架构，首列缩进 + 展开折叠（Alpine 用 `▸/▾`，Ext 用原生树图标）
- 顶部过滤条（`ShowFilter`）

## 运行

```bat
lazbuild C:\lazarusWeb\demos\ehlibTree\ehlibTree.lpi
demos\ehlibTree\ehlibTree.exe --port=8090 --root=C:\lazarusWeb
```

浏览器打开 `http://127.0.0.1:8090/`。

命令行说明：

- `--nogui`：不显示本机窗口，只跑浏览器端（推荐）
- `--client=alpine` / `--client=ext`：切换渲染层，两边都支持树形
- 不加 `--root` 时默认用 exe 所在目录往上找 `src/client`

## 依赖

本 demo 编译期依赖 EhLib（`EhLib` 包）。首次使用先注册：

```bat
lazbuild --add-package="C:\111\ccr\EhLib.VclFmx 13.0 Build 13.0.018\Lazarus\Src\ehlib.lpk"
lazbuild "C:\111\ccr\EhLib.VclFmx 13.0 Build 13.0.018\Lazarus\Src\ehlib.lpk"
```

**运行时不需要 EhLib 网格**：转换后是普通 `TLWDBGrid`，层级由 `lwwriter` 按 `id` / `parent_id` 计算。EhLib 单元会静态链接进 exe（体积约 4.7 MB），但不再参与渲染。

## 代码要点

`uEhLibTree.pas`：

1. `BuildData`：`TMemTableEh` + `TreeList.KeyFieldName='id'`、`RefParentFieldName='parent_id'`、`Active=True`，插入 11 条四层数据。
2. `BuildGrid`：建一个真实的 `TDBGridEh`，列标题带 `|`，`UseMultiTitle=True`，再调
   `LWBuildGridFromEhLib(Eh, Self, Self)` 转成 `TLWDBGrid`，源网格随即释放。
   注意首列（树列）用**顶级标题** `组织架构`，不要写成 `组织架构|名称` ——
   Ext 的 `tree.Panel` 会强制把树列提到最左并把分组拆开。
3. 转换会把 `TreeKeyField` / `TreeParentField` / `TreeDefaultExpanded` / `MultiTitle` 一起带过来。

## 换用自己的数据

把 `BuildData` 换成你的数据集即可，树形只要满足：

- 有主键字段（整数或字符串）
- 有父键字段（根节点为 `NULL` 或 `0`）
- 数据集是 `TMemTableEh` 且 `TreeList.Active=True`（转换器靠它识别树形）

若不是 MemTable，也可以手工设置：

```pascal
Grid.TreeKeyField := 'id';
Grid.TreeParentField := 'parent_id';
Grid.TreeIndent := 20;
```

## 已知限制

- 树形模式自动忽略 `PageSize`（分页会切断父子关系）。
- 树形列固定为第一个可见列。
- Ext 端首列必须是顶层 `treecolumn`，转换已保证；若手工调整列顺序，需保持树列在首位。
