# DBGrid 多表头使用指南（TLWDBGrid.HeaderGroups）

## 1. 适用范围

LCL 原生 `TDBGrid` 的 `TColumnTitle` 只有 Caption / Alignment / MultiLine，
没有跨列、分层能力，因此**原生 TDBGrid 做不到多表头**。多表头是 lazarusWeb
对 DBGrid 的框架扩展类 `TLWDBGrid`（`src/core/lwdbgrid.pas`，继承 TDBGrid），
普通 TDBGrid 的全部属性和事件照常继承。

`TLWDBGrid` 同时提供分页 / 过滤 / 汇总（`PageSize`、`ShowFilter`、
`SummaryType`、`SummaryField`），但**多表头不依赖这些功能**：只配
`HeaderGroups` 也能用，未配分组时载荷与普通 TDBGrid 完全一致。

## 2. 最小可用步骤

1. 单元 `uses` 加 `lwdbgrid`：

   ```pascal
   uses ..., DBGrids, lwdbgrid;
   ```

2. lfm 里网格对象的类名必须写**精确类名**：

   ```lazarus
   object grdMain: TLWDBGrid
   ```

   业务代码里的字段声明也必须是 `TLWDBGrid`。写 `TDBGrid` 时加载出来的是
   原生类，`is TLWDBGrid` 为 False，多表头配置整个失效。源码里虽然有
   `RegisterClassAlias(TLWDBGrid, 'TDBGrid')`，但 **lfm 加载路径不认别名**
   （FPC `GetClass` 只按精确类名查找）。

3. 运行时把分组写进 `HeaderGroups`（`demos/db/uDbMain.pas` 的真实写法）：

   ```pascal
   with grdMain.HeaderGroups do
   begin
     Add('基本信息|0-2');      // 标题|起-止
     Add('价格与库存|3-5');
   end;
   ```

   一行一组；`起-止` 是**可见列下标**，从 0 开始，**含止**。
   上例表示第 0、1、2 列共用一个"基本信息"分组格，第 3、4、5 列共用
   "价格与库存"。

4. 不写进任何分组的列会自动占一格、上下两行贯通（rowspan=2），
   因此"部分列分组 + 部分列不分组"的混排无需额外设置。例如
   `demos/db` 的统计页只写 `grdStat.HeaderGroups.Add('统计指标|1-3');`，
   第 0 列单独贯通两行。

## 3. 分组编号的硬规则

| 规则 | 说明 |
| --- | --- |
| 下标基准 | 按**可见列**从左往右数，0 起、含止；不是 `Columns.Count` |
| 隐藏列 | `Columns[i].Visible=False` 的列不占号，隐藏后后续列下标会前移 |
| 未分组列 | 自己一格贯通两行，不需要写进 HeaderGroups |
| 重叠 / 越界 | 按配置**先来先占**；越界或非法格式的行直接丢弃 |
| 缺省 | `HeaderGroups.Count=0` 时渲染成普通单行表头，零额外开销 |

`demos/db` 的 `grdMain` 有 7 列，其中"备注"列 `Visible=False`，可见列只有
6 个（下标 0…5），所以分组写到 5 为止，最后一个可见列保持不分组。
改了列顺序或可见性，务必重新核对分组下标。

## 4. 运行期行为

- 渲染成两行 `thead`：第一行是分组格（`colspan=跨度`），第二行是叶子列头；
  未分组列只在第一行出现一次并跨两行。
- **两行表头作为整块粘顶**，滚动时不会散开；框架自动给表格加 `lw-hg` 类，
  改用 `border-collapse: separate`，避免 Chromium 折叠边框 + sticky 时的
  数据行文字透出。
- 两级表头的文字统一**居中**；数据单元格仍按各自列的 align，不受影响。
- 点击行为：**分组格不回发** `OnTitleClick`（跨列标题没有唯一列），
  叶子表头照常回发，`OnTitleClick(Column)` 里的 `Column.Index` 仍是可见列
  下标，业务排序代码不用改。
- 协议：服务端 `lwwriter.HeaderGroupsJson` 把每一行折成 `hg=[{t,a,n}]`
  （t=标题、a=起始可见列、n=跨度）挂在 dbgrid 节点上。只有配了分组才有
  这个键，普通网格载荷一个字节不多。
- Alpine（默认渲染层）和 Ext（可选渲染层）均已实现：Ext 先把叶子列平铺
  建好，再按 hg 包一层嵌套 columns；自定义 Ext 列配置时注意顺序，
  反了会丢编辑器。

## 5. 演示与验收位置

| 位置 | 内容 |
| --- | --- |
| `demos/db/uDbMain.pas` | 基本信息 / 价格与库存两组 + 统计页"部分分组"混排 |
| `demos/gallery/ugallery.pas` | 数据感知页三组 + 末列"上架"贯通；大表分页页两组 |
| `tests/cdp_dbgrid_headergroups.py` | hg 协议、colspan/rowspan、叶子排序、分组不回发、粘顶等 |
| `tests/cdp_gallery_dbgrid_hg.py` | gallery 两页签 + Ext 嵌套列 + 连编两次 |

## 6. 相关坑（排查时优先看）

1. **配了没效果**：先查 lfm 的类名是不是 `TLWDBGrid`，以及单元 uses 有没有
   `lwdbgrid`；写 `TDBGrid` 时配置会被加载成原生类而静默失效。
2. **列错位**：按可见列重新数下标，特别是运行时改过 `Visible` 的场景。
3. **gallery 前端不同步**：`demos/gallery/lw/` 是 gallery 自带的前端静态副本
   （其它 demo 直接读 `src/client`）。改了客户端 JS/CSS 必须执行
   `cp src/client/* demos/gallery/lw/`，否则服务端有 `hg`、浏览器不认识。
4. **滚动时文字透出表头**：确认客户端是新版 `lw-alpine.css`（含
   `.lw-table.lw-hg` / `thead.lw-thead-hg` 规则）。

详细实现记录见 `docs/NOTES.md` 坑 135、140；属性总表见
`docs/lazarusWeb控件属性映射表.md` 的 `TLWDBGrid` 条目。
