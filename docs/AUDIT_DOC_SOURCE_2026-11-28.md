# lazarusWeb 文档—源码一致性复审（2026-11-28）

> 上次审计见 `AUDIT_DOC_SOURCE_2026-11-21.md`。本次只改文档，未改源码。
> 修改前的 19 个文档已备份到 `tmp/_audit_backup_20261128/`，可逐文件回滚。

## 范围与方法

- 文档：根目录 `README.md` / `README_en.md`、`docs/`、`tools/`、`demos/` 下项目自身 Markdown。
  不包含第三方库自带文档（`ext-7.x/`、`alpine-3.17.5/`）、临时目录与备份文件
  （`README (6).md`、`src - 副本*`、`tools - 副本/`）。
- 源码依据：`src/core/lwapp.pas`（命令行与 INI）、`lwhyper.pas`（PWA 透传）、
  `lwpwa.pas`（端点）、`lwwriter.pas`（多表头/树形序列化）、`src/design/lwehlibconvert.pas`、
  `docs/NOTES.md`（坑号与实现记录）。
- 方法：批量扫描 Markdown 中的路径引用 → 人工剔除 URL 路径、命令行参数、示例文本的误报 →
  对确认失效的引用按中英文分别指向实际文件名 → 逐处核对修改前后差异。
- 引用扫描命中数由 297 条降至 254 条（减少 43 条，均为失效引用修正；余下为 URL/参数/示例误报）。

## 一、已修正

### 1. 失效文档引用（43 处）

工作区中 `docs/MAPPING.md`、`docs/HOW_IT_WORKS.md`、`docs/MOBILE.md` 早已删除或改名，
但多处文档仍引用旧名。修正规则：

| 旧引用 | 中文文档改为 | 英文文档改为 |
|---|---|---|
| `docs/MAPPING.md` | `docs/lazarusWeb控件属性映射表.md` | `docs/MAPPING_en.md` |
| `docs/HOW_IT_WORKS.md` | `docs/lazarusWeb工作原理详解.md` | `docs/HOW_IT_WORKS_en.md` |
| `docs/MOBILE.md` | `docs/lazarusWeb手机浏览器适配.md` | `docs/MOBILE_en.md` |

涉及：`README(_en).md`、`docs/INDEX(_en).md`、`ARCHITECTURE(_en).md`、`MANUAL(_en).md`、
`lazarusWeb技术文档.md`、`lazarusWeb工作原理详解.md`、`lazarusWeb使用手册.md`、
`CONTROL_MATRIX.md`、`lazarusWeb_LCL 控件支持度.md`、`COMPARISON_unigui.md`、
`THIRDPARTY_BINDING(_TCHART).md` 及两份中文绑定说明、实例篇、
`tools/lwbinder/README.md`；历史文档 `MERGE_AUDIT_FULL.md`、`NOTES.md` 中的文件名引用也一并指向现名。

### 2. README 参数表补齐 PWA（中英各 11 行）

`lwpwa.pas` 已实现全套 PWA 开关与端点，`lwapp.pas` 的 `--help` 也列出参数，
但 README 作为索引声明的“参数表唯一出处”完全未收录。现按源码补齐：
`--pwa`、`--pwa-name=`、`--pwa-short-name=`、`--pwa-theme=`、`--pwa-bg=`、`--pwa-vapid-public=`、
`--pwa-vapid-private=`、`--pwa-vapid-subject=`、`--pwa-push-token=`、`--pwa-push-file=`、
`--pwa-message-file=`；默认值与 `lwapp.pas` 一致（关闭、#1e88e5、#ffffff）。

### 3. 索引补录新增功能入口

`INDEX.md` 新增两条场景行（PWA；EhLib/多表头）与五份文档清单条目：
`PWA.md`、`EHLIB.md`、`DBGrid多表头使用指南.md`、`插件部署目录与动态探测指南.md`、
`测试报告-2026-11-27.md`。

### 4. 坑数统计同步

`NOTES.md` 实际已记录到坑 212；文档中的 1–108、163、167、203 均更新为 212，
两处“截至 2026-11-16”改为 2026-11-28。

## 二、抽查确认一致（未修改）

- `PWA.md` 的端点表与 `lwpwa.pas` 中 `/lw/manifest.webmanifest`、`/lw/sw.js`、`/lw/pwa.js`、
  `/lw/pwa/config|subscribe|unsubscribe|message|push` 完全对应。
- `EHLIB.md` 的多表头/树形字段与 `lwwriter.pas` 的 `hrows` / `htree` / `tree` / `keys` /
  `lv` / `hc` / `pid` 一致；`lwehlib.lpk` 为独立可选包的说法与源码结构一致。
- `SECURITY.md` 已同步坑 204 的字段级挑战-响应；`demos/pluginsDemo/docs/` 下的权限与
  凭据文档已同步坑 197–203 的多进程插件、验证码与身份注入，无需改写。
- 英文索引原本就引用 `*_en.md` 文件名，除坑数外无需改动。

## 三、边界与建议

- 历史审计文档的**结论**未改写，只修正了其中指向已删除文件的文件名，避免读者无法定位。
- `README (6).md`、`src - 副本*`、`tools - 副本/` 是旧备份，不在同步范围。
- 建议：删除/重命名 `docs/` 下文档时，同步跑一次路径引用扫描；参数表仍以 README 为唯一出处，
  新增命令行开关时优先补那里。
