# DB 感知控件（data-aware）实测矩阵

> 由 `tools\lwdbcheck.exe` 生成，勿手改。生成时间：2026-11-08 19:29

每个控件都挂到真实的 SQLite 数据集上（3 行商品 + 2 行分类），逐项验证：

| 列 | 含义 |
|---|---|
| 绑定 | 设 DataSource/DataField 后 `Field` 能否取到 |
| 显示 | 控件显示值是否等于字段当前值 |
| 同步 | 游标换行后显示是否自动跟着变（DataChange） |
| 改值 | 模拟浏览器送值（`LWApplyValue`），字段是否真被改写 |
| payload | `lwwriter` 序列化出的 JSON 是否带值 |
| 前端 | `lw.js` 里有无该 kind 的渲染分支（读源文件实测） |

结论口径：**完全可用** = 显示/同步/改值三项全通且前端有渲染；
**只读可用** = 能正确显示并跟随游标，但设计上不允许改（或改值不通）；
**占位** = 前端没有渲染分支，浏览器只画灰框；**异常** = 创建/绑定/显示出错。

## 汇总

- 控件总数：**12**
- 完全可用：**8**（66.7%）
- 只读可用：**3**（25.0%）
- 占位不可用：**0**（0.0%）
- 异常：**1**（8.3%）

## 明细

| 控件 | kind | 创建 | 绑定 | 显示 | 同步 | 改值 | 前端 | 结论 |
|---|---|---|---|---|---|---|---|---|
| TDBGrid | dbgrid | ok | ok(n/a) | ok | ok | n/a | yes | **只读可用** |
| TDBEdit | dbedit | ok | ok | ok | ok | ok | yes | **完全可用** |
| TDBMemo | dbmemo | ok | ok | ok | ok | ok | yes | **完全可用** |
| TDBCheckBox | dbcheckbox | ok | ok | ok | ok | ok | yes | **完全可用** |
| TDBComboBox | dbcombo | ok | ok | ok | ok | ok | yes | **完全可用** |
| TDBText | label | ok | ok | ok | ok | n/a | yes | **只读可用** |
| TDBListBox | dblistbox | ok | ok | ok | ok | ok | yes | **完全可用** |
| TDBRadioGroup | dbradiogroup | ok | ok | ok | ok | ok | yes | **完全可用** |
| TDBLookupListBox | dblookuplist | ok | ok | ok | ok | ok | yes | **完全可用** |
| TDBLookupComboBox | dblookup | ok | ok | ok | ok | ok | yes | **完全可用** |
| TDBImage | dbimage | ok | ok | ok(image) |  | n/a | yes | **只读可用** |
| TDBNavigator | dbnav | ok | ok | ok | ok | n/a | yes | **完全可用** |

## 逐条说明

- **TDBGrid**（只读可用）：表格浏览，前端只读
- **TDBText**（只读可用）：只读标签
- **TDBImage**（只读可用）：图片字段
- **TDBNavigator**（完全可用）：lfm 里照写 TDBNavigator，运行时自动落到
  `TLWDBNavigator`（lwdbnav.pas，覆盖 UpdateButtons 跳过 LCLGlyphs 位图
  加载 —— 原版在 nogui 下 Create 即抛 FPImageException）。浏览器端画图标，
  点击回传 `OnClick + val=按钮名`，服务端转 `BtnClick()`；
  first/prior/next/last 的 Enabled 由框架按 `RecNo` 兜底计算（SQLdb 的
  BOF/EOF 在 RecNo 导航后不可靠）。SQLdb 下 Delete/Post 进缓存，
  落库要业务自己在 OnClick 里 ApplyUpdates+Commit（见 dbaware 演示）。

## 复现

```
cd tools
build_dbcheck.bat
```
