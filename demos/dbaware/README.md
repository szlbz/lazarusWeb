# 演示 6：综合演示（登录 + 多窗体 + DB 感知 + HTML/PDF + 图表 + 报表）

已从"DB 控件全家桶"升级为多功能综合 demo（对照 uniGUI 的组织方式）。
本轮新增三块能力：

- **登录**（`uLogin.pas`）：`TLWLoginForm` + SQLite `users` 表
  （首次运行自动建表，种入 `admin/123456` 与只读 `guest/guest`）。
  登录窗体是 **.lfm 布局 + 代码逻辑**（uLogin.lfm 放控件，uLogin.pas 只留 DoAuth），
  未认证会话只能操作登录窗体上的控件（框架在 lwdispatch 里拦截）。
- **多窗体切换**（`uReport.pas` + 主窗体菜单）：主窗体 <-> 报表中心
  是两个独立 `TLWForm`，切换 = 一个 `Visible:=False`、另一个 `True`；
  服务端对象一直活着，切回来数据、网格位置都在。注销 -> 重新登录会
  **复用同一个主窗体实例**（`SessionFindForm`），不会越登越多窗体。
- **报表中心：打印与导出**（`src/core/lwreport.pas`）：
  数据源切换（商品清单 / 240 行库存大表）→ 生成 A4 可打印 HTML，
  在 iframe 里预览（`TLWPDFFrame`，查看令牌不暴露路径）。
  - 预览页顶部有「打印 / 另存为 PDF」按钮；窗体上的「打印…」让
    URL 带 `#print`，页面加载完自动弹打印对话框；
  - 「导出 CSV」UTF-8 BOM，「导出 Excel」真 xlsx（OOXML + zip，
    表头样式 / 冻结窗格 / 合计行）；
  - 权限差异：guest 的导出按钮被禁用（`Enabled` 同步到浏览器）。

原有内容：TPageControl 五个页签：

- **数据感知**：11 个 LCL 数据感知控件 + TDBNavigator 的完整行为验证
  （原内容原样保留，仍是 `docs/DB_AWARE_MATRIX.md` 的可视化对照物）；
- **HTML 展示**：`TLWHTMLFrame`（uniHTMLFrame 对应物）——上面 TMemo
  编辑 HTML 源码，点"应用到下方面板"立即刷新；
- **PDF 展示**：`TLWPDFFrame`（uniPDFFrame 对应物）——"生成示例 PDF"
  （服务端 Pascal 运行时手写 PDF 1.4 语法，不引第三方库），
  或用 `TLWFileUpload` 上传本地 PDF 显示；iframe 用浏览器自带查看器，
  文件路径不进 URL（查看令牌 + `/lw/view`）。

## 运行

```
build.bat                 :: 或单独: build.bat dbaware
demos\dbaware\dbaware.exe --port=8110
```

浏览器打开 `http://127.0.0.1:8110/`，**先登录**：
`admin / 123456`（管理员，全部功能）或 `guest / guest`（只读，
导出禁用）。首次运行自动在 exe 目录创建 `dbaware.db`（3 条商品 +
3 个分类 + 240 行大表 + users 表），`sqlite3.dll` 与 exe 同目录。

回归：`tests/t_dbaware.py`（数据感知 134 项）、`tests/t_dbaware2.py`
（登录 / 多窗体 / 打印导出 42 项）。

## 界面

### 数据感知页（tsDB）

左侧 `TDBGrid`（点行定位、点列头排序、**双击单元格可直接编辑**，
网格开了 `dgEditing`，编辑=改缓存、点保存才落库），右侧分两列：

| 控件 | 绑定字段 | 说明 |
|---|---|---|
| `TDBText` | code | 只读文本（框架映射成 label） |
| `TDBEdit` ×3 | name / price / stock | 单行文本 |
| `TDBMemo` | memo | 多行文本 |
| `TDBCheckBox` | active | **必须设 ValueChecked/ValueUnchecked** |
| `TDBComboBox` | tag | 候选值：新品/热销/清仓 |
| `TDBListBox` | tag | 选中即改字段，与 ComboBox 联动 |
| `TDBRadioGroup` | state | Items 是显示文字，**Values 才是字段值** |
| `TDBLookupComboBox` | cat_id | 显示 cats.name，回写 cats.id |
| `TDBLookupListBox` | cat_id | 同上，列表形态 |
| `TDBImage` | img | BLOB -> PNG data URI |

底部：保存 / 取消 / 上一条 / 下一条 + 状态行；左下角 `TDBNavigator`
（10 个导航按钮，点删除弹浏览器确认框）。

## 框架为这些控件做的事

| 浏览器动作 | 服务端行为 |
|---|---|
| 点表格某行 | `DataSet.RecNo := 行号`，右侧所有控件自动跟随（DataChange） |
| 双击表格单元格编辑 | 回传 `OnSetFieldValue(row, col, val)`：`RecNo` 定位 → `Edit` + `Post`（`sqoAutoApplyUpdates` 随之 ApplyUpdates），**落库仍要点保存**（Commit） |
| 改 TDBEdit/Memo | 直接写字段（不是写 Text，见 `lwdispatch.LWDBWrite` 注释） |
| 选 TDBListBox 项 | 回传"第几项"，服务端 `ItemIndex := n` + 把该项文本写进字段 |
| 选 TDBRadioGroup 项 | 回传该项的 **Value**（不是序号），写进字段 |
| 选 Lookup 下拉 | 回传 **KeyField 值**，直接写外键字段（不依赖 KeyValue 的焦点链） |
| TDBText / TDBImage | 只读：writer 每次序列化都重新读字段（DisplayText / PNG base64） |
| 点导航刷新 | `CommitRetaining` 丢旧读快照 + `Requery`（WAL 下不换快照就永远看不到外部改动） |

## 本演示踩出的四条规则

1. **TDBCheckBox 绑 0/1 整数字段必须显式设 `ValueChecked='1'`、
   `ValueUnchecked='0'`**。默认是 'True'/'False'，跟字段的 '1'/'0' 对不上，
   勾选状态永远是错的（LCL 语义，不是框架问题）。
2. **TDBText 在 nogui 下 Caption 一直为空**。LCL 的 `TDBText.DataChange`
   里 `Caption := Field.DisplayText` 这条赋值链在无图形环境不生效；
   框架改为直接读字段（`lwwriter` label 分支），业务代码无感。
3. **TDBNavigator 在 nogui 下创建即崩**（`FPImageException: Failed to get
   raw image description from bitmap`，构造时就要生成按钮 glyph）。
   **已解决**：框架提供 `TLWDBNavigator`（lwdbnav.pas），覆盖 UpdateButtons
   跳过 glyph 加载，并用 RegisterClassAlias 让 lfm 里的 TDBNavigator 自动
   落到子类 —— 窗口左下角那条导航栏就是它，浏览器端画图标。
   注意 SQLdb 下 Delete/Post 先进缓存，落库要在 OnClick 里
   ApplyUpdates + Commit（本演示 navMainClick 就是这个接法）。
4. **TDBLookup*.KeyValue / ItemIndex 是 DataLink 缓存，数据集重开后可能
   没刷上**（实测保存后取到空串 / -1）。框架下发 `key` 时直接读绑定字段，
   `index` 按 key 在 keys 里的位置反推，永远可靠。

## 数据库

`items(id, code, name, price, stock, active, tag, state, memo, cat_id, img)` +
`cats(id, name)`。连接参数与 db 演示一致（WAL 走 Params + busy_timeout），
保存用 `CommitRetaining -> Post -> Commit -> Requery(keepId)`，保存后仍停在
原记录。图片是内嵌的 24x24 PNG（96 字节），避免演示依赖外部文件。

## 回归

`python tests/t_dbaware.py`（97 项）：kind 映射、首次下发值、点行同步、
逐控件回写、保存落库、取消回滚、上下条导航，以及 TDBNavigator 的
按钮清单 / 置灰状态 / prior / insert / cancel / 删除确认框落库 / refresh，
以及网格单元格编辑（readonly/cedit 标志、编辑回显、非法值回滚、
缓存编辑保存落库）；另有 HTML/PDF 页签 14 项（kind、HTML 内容下发、
运行时更新、示例 PDF 生成、查看令牌可重复访问、Content-Type、
上传 PDF 换文件换令牌）。脚本开跑前会自动复位种子数据（删除用例会先把
整行备份、断言后插回）。

## 2026-11-09 新增：「图表/其它」与「大表分页」页签

- **tsChart** —— TLWChart（折线/柱状/饼图运行时切换 + 从数据库统计
  柱状图）、TDateEdit/TTimeEdit（→ Ext datefield/timefield）、
  Toast 演示按钮（ShowToast 成功/失败两种文案）。
- **tsBig** —— TLWDBGrid 大表场景：bigitems 表 240 行，
  PageSize=20（12 页）/过滤条/price 汇总条；OnPageChange/OnFilter
  框架级事件；点行经 MatchAt 书签定位真实记录。
- 回归：`tests/run_with_server.py demos/dbaware/dbaware.exe tests/t_dbaware.py 8110`
  （127 项，含原有 11 个数据感知控件全量用例）。
