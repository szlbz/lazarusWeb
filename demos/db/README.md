# 演示 4：SQLite 增删改查（TDBGrid / TDBEdit / TLWFileUpload / TButton）

数据库应用整套搬进浏览器：列表浏览、单条编辑、新增、删除、列头排序、
关键字/分类/库存过滤、分类统计、**商品附件上传/下载**、SQL 日志。
业务代码全是标准 LCL DB 写法，一行 Web 相关代码都没有。

## 运行

```
build.bat                 :: 或单独: build.bat db
demos\db\dbdemo.exe --port=8095
```

浏览器打开 `http://127.0.0.1:8095/`。

- 首次运行自动在 exe 目录创建 `shop.db`，并灌入 36 条示例商品；
- `sqlite3.dll` 必须与 exe 同目录（本目录已放一份，来自 `c:\111\u\sqlite3.dll`）。

## 界面

| 区域 | 控件 | 说明 |
|---|---|---|
| 顶部工具栏 | TEdit + TComboBox + TCheckBox + TButton | 关键字 / 分类 / 只看缺货 / 查询 / 重置 |
| 数据维护页 | `TDBGrid` | 只读浏览；**点列头排序**（再点一次反向）、**点行定位** |
| 右侧编辑区 | `TDBEdit`×4 + `TDBComboBox` + `TDBMemo` | 绑 code/name/price/stock/category/memo |
| 附件区 | `TLWFileUpload` + `TListBox` + `TButton`×2 | 上传附件（可多选）→ 下载选中 → 删除选中 |
| 按钮行 | TButton×8 | 新增 / 保存 / 取消 / 删除 / 首末条 / 上下条 |
| 分类统计页 | 第二个 `TDBGrid` | `GROUP BY category` 汇总（品项数/库存/货值） |
| SQL 日志页 | TMemo | 每次查询/保存/删除/上传/下载都留痕 |
| 状态栏 | TStatusBar×3 | 浏览/编辑/新增状态 · 记录位置 · 库存与货值合计 |

## 布局全在 `uDbMain.lfm` 里

所有控件的坐标、尺寸、字体、列定义、事件绑定都写在 `uDbMain.lfm`
（设计期布局），`uDbMain.pas` 里**没有一行** `TButton.Create` / `SetBounds`。
在 IDE 里打开 `uDbMain.lfm` 就能直接拖动摆位，改完重新编译即可。

代码只保留三样 lfm 表达不了的东西：

| 留在代码里的 | 为什么不能在 lfm |
|---|---|
| `DataSource := FDs` | `TDatasource` 是 `SetupData` 运行时创建的，lfm 里没有可引用的实例名 |
| `cbFilterCat.Items` / `cbCategory.Items` | 候选值来自 `CATEGORIES` 常量，写进 lfm 就变成两处维护 |
| `grdMain.DataSource` 等接线 | 同上，`BindDataSources` 一个过程集中处理 |

三个容易踩的坑（写自己的 lfm 时同样适用）：

1. **控件字段必须 `published`**。lfm 只实例化 published 字段 —— 声明在
   private 里、lfm 里也写了 object 块，运行时那个字段仍是 `nil`。
2. **事件方法必须 `published`**。`OnClick = btnSaveClick` 是靠方法名查的，
   private 方法查不到，加载时直接报 "Cannot find method"。
3. **自定义控件要有运行时 `RegisterClass`**。`TLWFileUpload` 在设计期由
   lwdesign 包注册、运行时不会加载那个包，所以 `lwfileupload.pas` 的
   `initialization` 里补了 `RegisterClass(TLWFileUpload)`，否则 lfm 加载时
   报 "Unknown component class"。

`TDBGrid.Columns` 也能写进 lfm（本 demo 就是这么做的：列宽 / 标题 /
`DisplayFormat` 全在 lfm 里），赋 `DataSource` 时 LCL 会按 `FieldName`
把列和数据字段对上，不会重建。

## 附件是怎么接的（业务代码视角）

- 表：`attachments(item_id, file_name, size_kb, uploaded)`；文件本体在
  `attachments\item<id>\`，路径靠 `item_id + file_name` 还原 ——
  数据库不存绝对路径，整个目录搬家照样能用；
- 上传：`TLWFileUpload.OnUpload` 给的是**服务端临时路径**，demo 把它
  复制到商品目录（`LWSafeFileName` 清洗名字，同名自动加 `-2`）、
  写表、刷新列表，然后删掉临时文件；
- 下载：`SendFile(path, name)` 发一条 download 指令 —— 服务端生成
  **一次性令牌**，浏览器用隐藏 `<a download>` 保存，URL 不含服务端路径；
- 删除：先删表记录再删磁盘文件，两边一致。

## 框架为 DB 控件做的事（对业务透明）

| 浏览器动作 | 服务端行为 |
|---|---|
| 点表格某一行 | `DataSet.RecNo := 行号+1`，该行绑定的 DBEdit 自动刷新 |
| 点列头 | 定位列后调用 `OnTitleClick(Column)`（LCL 真实签名，不是 OnClick） |
| 改 DBEdit 值 | 直接写字段（不是写 `Text`），数据集自动进入编辑态 |
| 数据集在编辑/新增态 | 网格不下发行数据（见下"编辑态"），浏览器沿用旧数据 |

## 四条硬性规则（任何 sqlite + lazarusWeb 项目都适用）

1. **字符串列一律 `VARCHAR(n)`，不要用 `TEXT`/`CHAR`**。
   `sqlite3conn` 把 TEXT/CHAR 映射成 `ftMemo`，TDBGrid 只会显示 `(MEMO)`、
   TDBEdit 也没法正常编辑；再长的 `VARCHAR(n)` 都是 `ftString`。
2. **`sqoAutoApplyUpdates` 只发 SQL，不提交事务；Post/Delete 后必须显式
   `SQLTransaction.Commit`**。
   FPC 源码里只有 `sqoAutoCommit` 才会跟着 Commit（还会顺手关掉数据集）。
   只加 sqoAutoApplyUpdates 时：同连接里查询能看到新值（读的是自己未提交
   的事务），但数据库文件没变 —— 程序一退全回滚，而且这个写事务握着
   写锁，第二个会话（另一个浏览器标签）一保存就
   `FConn : database is locked`。所以本演示在保存/删除按钮里：
   `CommitRetaining`（丢旧读快照）-> `Post`/`Delete` -> `Commit` ->
   `Requery` 重开。
3. **多会话（多标签）三件套：WAL + busy_timeout + CommitRetaining**。
   连接加 `Params.Add('journal_mode=WAL')`（必须走 Params，用
   ExecuteDirect 发 PRAGMA 实测无效）+ Open 后
   `PRAGMA busy_timeout=10000`；WAL 让读不阻塞写。但 WAL 还有
   `SQLITE_BUSY_SNAPSHOT`：旧读事务升级为写时快照过期直接报锁，
   busy_timeout 对它不生效 —— 写之前 `CommitRetaining`（=COMMIT+BEGIN，
   新快照第一条语句才取）解决。
   详见 `docs/NOTES.md` 坑 9.2。
4. **数据集处于 dsEdit/dsInsert 时，移动游标会自动 Post**（实测行为）。
   框架的 writer 检测到编辑态就干脆不下发网格行，避免把用户改了一半的
   记录提交掉；保存/取消后数据集回到浏览态，行数据自动恢复下发。

## 附件用第二条连接（别跟主数据集共用事务）

附件读写（`FConnAtt`/`FTransAtt`）和主查询 `FQry` 分开，原因：

- `FQry` 一 Open 就挂着一个**长读事务**，在 `FTrans` 上 Commit 会把
  `FQry`/`FQryStat` 一起关掉 —— 附件写库绝不能走主事务；
- 反过来，附件连接自己也有个坑：连接打开时 `ExecuteDirect` 会顺手开个
  空事务，**必须马上 Commit**，否则后续读一直停留在打开时的旧快照，
  别的会话刚写进来的附件看不见。所以 `RefreshAttach`/`AttachNameOf`
  每次读完都 `if FTransAtt.Active then FTransAtt.Commit`；
- 两条连接共享同一个 WAL 库（journal_mode 是库级持久设置，第二条连接
  不用再设），写冲突交给 busy_timeout 排队。

## 已知行为

- 单价列设置了 `DisplayFormat='#,##0.00'`，显示带千分位；框架回写数值字段
  时会先洗掉千分位再解析（`lwdispatch.LWDBWrite`），所以编辑不受影响；
- 删除没有二次确认（框架暂无 confirm 对话框），误删可用数据库备份找回；
- `编码` 列上有唯一索引，重复编码会在保存时报错并写进 SQL 日志页；
- 上传单文件上限 4MB（`MaxSizeKB`），图片/文档/压缩包都在 Filter 里；
- 附件记录处于编辑中的商品也能传（走独立连接，不打断编辑），但**新增中
  的记录不行** —— id 还没生成，先保存再传。
