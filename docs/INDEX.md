# lazarusWeb 文档索引

> 按场景找文档。lazarusWeb 是 Lazarus/FPC 桌面程序的 Web 化运行时：
> 业务窗体基类改成 `TLWForm`，编译为 `--ws=nogui`，浏览器里就是原程序
> （默认 Alpine.js 渲染，可选 Ext JS；服务端保持一棵真实 LCL 控件树）。

## 我想……

| 场景 | 读这些 |
|---|---|
| 第一次接触，跑起来看看 | `README.md`（根目录）快速开始 → `MANUAL.md` 使用篇 |
| 向别人介绍 / 评估要不要用（特点、亮点、边界一页看完） | `FEATURES.md` |
| 部署到生产（HTTPS/反代/集群） | `deploy/README.md`、`deploy/nginx.conf`、`WHYPER.md` |
| 把服务端装成 Windows 服务（开机自启/标准运维） | `WINDOWS_SERVICE.md`（**新建工程向导第一框选「服务(daemon)模式」即生成**，或 `tools\lwnew --service`；编译→安装/启停 cmd+PowerShell 双版本→配置→排障→机制；示例 `demos/service_demo/`）；部署总览见 `deploy/README.md` §6.2 |
| 服务叫什么名字 / 怎么改名 / 常用 sc 命令 | `SERVICE_NAMING.md`（两条路线都随工程名走：CLI 按 `--name`、IDE 向导按 Ctrl+S 时填的名字写盘前自动改写 mapper；显示名、改名重装步骤、ini 文件名大小写） |
| 用负载均衡器跑多 worker（参数/CLI/GUI/热更新） | `WHYPER.md`（lwhyper 使用说明） |
| 搞懂 lwhyper 怎么分发请求（粘性/轮询/故障切换/WS 透传） | `LOADBALANCE.md`（负载均衡详解） |
| 发布新版本但不想停服（热更新） | `WHYPER.md` §5.1（用法/运维剧本）→ §5.2（实现机制）；worker 侧优雅退出见 `NOTES.md` 坑 175 |
| 了解架构与工作原理 | `ARCHITECTURE.md`（总览）→ `lazarusWeb工作原理详解.md`（深读） |
| 查某控件能不能用 | `CONTROL_MATRIX.md`（自动生成）→ `lazarusWeb控件属性映射表.md`（映射细节） |
| 查 DB 感知控件 | `DB_AWARE_MATRIX.md`、`lazarusWeb控件属性映射表.md` 数据控件节 |
| 关心安全 / SQL 注入（框架信任边界、参数化范例） | `SECURITY.md`（框架无 SQL 通道；风险在业务代码拼 SQL） |
| 想加功能但不想动主程序 / 问 DLL·SO 插件怎么做 | **先看 `PLUGIN_GUIDE.md`**（手把手：加页面、自己工程接入、`.lfm`、常见问题）；原理与四方案对比见 `PLUGIN_FEASIBILITY.md` |
| 把现有 LCL 工程转 Web | `tools/lwconvert.exe`，回归见 `tests/t_convert.py` |
| 把第三方可视控件接进来（不改框架源码） | `THIRDPARTY_BINDING.md`（机制 + 运行期登记）→ 工具 `tools/lwbinder/`（命令行 `lwbinder.exe` / 图形界面 `lwbinder_gui.exe`）→ 实例 `demos/tachartdemo/` |
| 从头新建一个工程（IDE 向导：应用模式 / GUI-nogui / 常规-插件 三框） | `MANUAL.md` 使用篇「用 IDE 向导新建工程」；速查见 `README.md`「在 IDE 里用向导建工程」 |
| 换配色 / 加一套配色（Alpine 层，7 套现成） | `MANUAL.md` §5.1（用户视角）→ `NOTES.md` 坑 174（加主题的三条约定） |
| 性能与容量 | `BENCH.md`（实测）、`SCALE.md`（优化路线） |
| 排查疑难杂症 | `DEBUGGING.md`（案例方法论）→ `NOTES.md` 按坑号检索 |
| 手机浏览器适配（原理与实施记录） | `lazarusWeb手机浏览器适配.md` §8（判定信号/实测数据） |
| 让应用可安装 / 离线打开 / 收推送通知 | `PWA.md`（默认关闭；`--pwa` 开关、端点、VAPID、证书信任） |
| 把 EhLib 的 DBGridEh 换成本框架网格 / 做多表头 | `EHLIB.md`、`DBGrid多表头使用指南.md` |
| 拍照上传（手机系统相机 / 桌面网页取景） | `MANUAL.md` 使用篇「拍照：TLWCamera」+ `demos/mobile_demo` |
| gallery 网格未保存关闭提醒 / gridsave.json 保存调用 | `ugallery关闭浏览器未保存提示-修改说明.md`（7 处改动逐条；英文版 `ugallery_beforeunload_unsaved_changes_en.md`）；实现内幕见 `NOTES.md` 坑 194 |
| 给窗体写布局模板（窗口浮窗 / 平面整页） | `MANUAL.md` 第二篇「16. 窗体模板开发指南（窗口 + 平面）」；桌面 `<窗体名>.html`（两模式共用）+ 移动 `<窗体名>.m.html`，文件头 `lw-tpl-mode` 标记，控件不重排；骨架由 IDE Tools 菜单按 .lfm 一键生成（见 16.0） |
| 和 uniGUI 对比 | `COMPARISON_unigui.md` |
| 双 FPC 版本（3.2.2 / 3.3.1）合并与一致性审计 | `MERGE_AUDIT.md`（src/core 首轮）→ `MERGE_AUDIT_FULL.md`（src+demos+tools 全量） |
| 编写/扩展框架本身 | `MANUAL.md` 开发篇 + `lazarusWeb工作原理详解.md` |
| 给第三方 / 自写控件加浏览器绑定 | 机制总览 `THIRDPARTY_BINDING.md` → 完整实例 `THIRDPARTY_BINDING_TCHART.md`（以真实 TAChart TChart 为例，含 nogui 构造实测、六步接入、类型坑） |
| 做多语言 / 界面切换中英文 | `I18N_PO.md`（Lazarus PO 模式：原文即 msgid、`--lang=`/`?lwlang=`、加文案流程、能力边界） |

## 全部文档清单

| 文件 | 内容 | 维护方式 |
|---|---|---|
| `../README.md` | 项目总入口：快速开始/参数/INI/部署/控件统计 | 手写（**参数表唯一出处**） |
| `FEATURES.md` | **特点与亮点**：十一个能力、七个"做对了的决定"、数字速览、与 uniGUI 对照、适用边界、五分钟自证 | 手写（易变数字带日期） |
| `MANUAL.md` | 使用手册（使用篇 + 开发篇） | 手写 |
| `THIRDPARTY_BINDING.md` | 给第三方控件加浏览器绑定：机制总览、六步接入、技术风险 | 手写 |
| `THIRDPARTY_BINDING_TCHART.md` | 完整实例：把真实 TAChart TChart 绑定进 lazarusWeb（nogui 实测 + 可照抄代码 + 坑） | 手写（2026-11-19） |
| `ARCHITECTURE.md` | 技术决策、模块实现、线程模型 | 手写 |
| `lazarusWeb工作原理详解.md` | 一次点击的完整回路、ShowModal、reconcile | 手写（2026-11-11 快照） |
| `lazarusWeb控件属性映射表.md` | 控件/属性/事件映射、对话框、上传下载 | 手写 |
| `CONTROL_MATRIX.md` | 66 可视控件实测矩阵 | `tools/lwaudit` 自动生成 |
| `DB_AWARE_MATRIX.md` | 12 DB 控件实测矩阵 | `tools/lwdbcheck` 自动生成 |
| `SECURITY.md` | 安全说明：SQL 注入与信任边界（框架无 SQL 通道、demo 参数化范例、业务代码自检清单） | 手写 |
| `PLUGIN_GUIDE.md` | 插件使用说明：30 秒概念、跑 demo、新增页面 5 步、自己工程接入、`.lfm` 三个注意点、AJAX、部署、常见问题表 | 手写（命令与 demo 一致） |
| `PLUGIN_FEASIBILITY.md` | 插件化可行性：跨 DLL 类身份实测、四种方案对比（裸 DLL/进程级/Runtime Package/源码插件）、阶段 0 落地（`.lfm` 设计窗体或纯代码建窗两种写法）、分阶段路线与待验证清单 | 手写（实测数据带环境） |
| `BENCH.md` | 压测方法与实测数据 | 手写 |
| `SCALE.md` | 吞吐优化路线图（增量补丁/lwhyper） | 手写 |
| `WHYPER.md` | lwhyper 使用说明：参数/CLI/GUI/自身端点/热更新（§5.1 用法、§5.2 机制）/排障 | 手写（**lwhyper 参数与用法的出处**） |
| `LOADBALANCE.md` | lwhyper 负载均衡详解：为什么必须应用层、sid 粘性表、轮询跳死、探针与热身闸门、WS 透传、单点语义、观测与回归 | 手写（**负载均衡机制的出处**） |
| `NOTES.md` | 踩坑实录（追加式，编号到坑 212；旧结论被新坑修订处已标注） | 手写 |
| `MERGE_AUDIT.md` | 3.2.2 兼容分支合并的功能级审计（方法/逐文件结论/修回项/验证矩阵） | 手写 |
| `MERGE_AUDIT_FULL.md` | 合并前后全仓库（src+demos+tools）功能缺失审计：符号级/字面量级/条件展开/编译/回归五层 | 手写 |
| `DEBUGGING.md` | 4 个真实 bug 跟踪案例 + 调试方法论 | 手写 |
| `AUDIT_LFM.md` | lfm 链路审计快照（结论并入坑 69） | 手写 |
| `COMPARISON_unigui.md` | 与 uniGUI 功能对照 | 手写 |
| `lazarusWeb手机浏览器适配.md` | 手机浏览器适配：可行性分析存档 + 方案 B 实施记录（自适应判定/移动模板/平移回退） | 手写（状态行与第 8 节随实施更新） |
| `I18N_PO.md` | 多语言（中/英）：PO 模式怎么落地、为什么原文当 msgid、三个输出闸门、按会话切语言、加文案流程、能力边界、自测 | 手写（译文源在 `tools/i18n/`） |
| `WINDOWS_SERVICE.md` | 把服务端跑成 Windows 服务：三条生成路线（向导第一框 / `lwnew --service` / 抄 demo）、快速上手、cmd/PowerShell 双版本安装运维命令、配置、命令行分流、开机自启与故障恢复、排障（sc 别名/假活/CreateNew 与 Register 两坑）、机制原理、搬到自己工程、宿主方式对比、验证清单 | 手写（2026-11-20，示例 `demos/service_demo/`） |
| `SERVICE_NAMING.md` | 生成的服务叫什么名字：两条路线都随最终工程名走（`lwnew --name` / IDE 向导写盘前改写 mapper），显示名/描述/exe 对照、改名必须重装、常用 `sc.exe` 命令、ini 固定名 `lazarusWeb.ini` 的大小写与查找顺序 | 手写（2026-11-20 按 `C:\3` 核对；2026-11-21 向导改为随工程名走） |
| `AUDIT_DOC_SOURCE_2026-11-21.md` | 文档—源码一致性审计：19 处已修正不符（服务名/默认值/向导三框/上传路径/坑号等，中英同步）、5 个源码侧待办（未改源码）、抽查一致项与后续建议 | 手写（2026-11-21） |
| `AUDIT_DOC_SOURCE_2026-11-28.md` | 文档—源码复审：43 处失效引用改指现名、README 参数表补齐 PWA、索引补录新文档、坑数同步至 212；仅改文档 | 手写（2026-11-28） |
| `PWA.md` | PWA 接入说明：开关/参数/端点、Web Push、证书信任与常见问题 | 手写（2026-11-28） |
| `EHLIB.md` | EhLib 可选支持：TDBGridEh → TLWDBGrid 转换，多表头与树形网格映射 | 手写（2026-11-28） |
| `DBGrid多表头使用指南.md` | TLWDBGrid 多表头（HeaderGroups / MultiTitle）用法与前端渲染 | 手写（2026-11-26） |
| `插件部署目录与动态探测指南.md` | 多进程插件的部署目录、ExeRoot 差异与动态探测排障 | 手写（2026-11-26） |
| `测试报告-2026-11-27.md` | 2026-11-27 回归测试报告 | 手写（2026-11-27） |
| `../deploy/README.md` | 部署指南（nginx/Caddy/Linux/systemd/Windows 服务） | 手写 |

## 三条维护规则

1. **单一出处**：参数表只在 README、lwhyper 的**参数与用法**只在 WHYPER、
   lwhyper 的**分发机制**只在 LOADBALANCE、实测矩阵只在自动生成文件——其他
   文档只链接不复制。本次整理发现的问题约一半源于"同一事实两处维护后单侧更新"。
2. **快照带时间戳**：行数、单元数、测试项数、控件统计等易变数字，
   写死必须带"截至 X 日期"，或直接链接自动生成物。
3. **修订要回写**：NOTES 这类追加文档，旧坑被新坑推翻时（坑 23→41、
   坑 66→69、BENCH 55→155）在原处加删除线+指向，避免读者照旧方案操作。
