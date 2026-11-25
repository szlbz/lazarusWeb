# pluginsDemo 文档索引

本目录存放 `demos/pluginsDemo` 的实现说明，README 只保留「怎么用」，深度设计放这里。

| 文档 | 内容 |
| --- | --- |
| [插件用户权限实现说明.md](./插件用户权限实现说明.md) | 登录 + 角色 + `/p/` 路由强制鉴权的完整实现，约 290 行 |

---

## 一、插件用户权限这份文档包含什么

十一节，按「先分清概念、再看链路、最后看边界」的顺序组织：

1. **它和「启动守卫」不是一回事** —— 守卫管「exe 谁能拉起」，权限管「页面谁能看」，一张对照表先切开
2. **三层判定链路** —— mermaid 流程图 + 登录/菜单/路由三层职责表，说明为什么判定只留一份实现
3. **演示账号** —— admin / analyst / guest 的可见范围矩阵
4. **清单里怎么写权限** —— `roles=` 的三种写法与三条判定规则
5. **两个必须做的细节** —— iframe 首次导航带 `&sid=`、放行后下发 `lwpsid` Cookie，缺一条权限就等于没做
6. **顺手修掉的两个框架缺陷** —— `Set-Cookie` 被 `TStringList` 按 `=` 拆坏、Cookie 要走 `TRequest.Cookie` 读
7. **验证** —— 回归脚本覆盖的场景、全量重编、生成器验证
8. **边界与限制** —— 插件只听 `127.0.0.1`，绕过宿主直连不受约束
9. **涉及文件清单** —— 框架侧、demo 侧、文档与测试分开列
10. **接入到自己工程的步骤** —— 五步，含运行时不需要权限时的零改动说明
11. **插件如何拿到当前登录用户（身份注入）** —— `LWRouteSetIdentity` 签发 user/roles/token/ts，插件 `upluginidentity.pas` 验签，便签页显示当前用户

## 二、交付时核对过的实际值

文档里的配置值都与代码逐项比对过，不是凭记忆写的：

| 项 | 实际值 | 出处 |
| --- | --- | --- |
| 演示口令 | `123456` | `common/upluginauth.pas` 的 `LWAuthDemoPass` |
| 仪表盘权限 | `roles=admin,analyst` | `dashplug/dashplug.plugin.ini` |
| 报表权限 | `roles=admin` | `reportsplug/reportsplug.plugin.ini` |
| 便签权限 | 不写 `roles`（所有已登录用户） | `notesplug/notesplug.plugin.ini` |
| 鉴权回调 | `LWRouteSetAuth` / `TLWRouteAuthFunc` | `src/core/lwroute.pas` |
| 会话 Cookie | `lwpsid`（`Path=/p/`、`HttpOnly`、`SameSite=Lax`） | `src/core/lwroute.pas` |

## 三、文档约定

- `docs/` 只放实现说明与设计取舍，操作步骤留在 `README.md`；
- 每份文档开头写清「本文解决什么问题、和相邻机制的区别」，避免读者拿错文档；
- 涉及配置值一律标出处文件，方便改代码后回头核对；
- 文件统一 UTF-8（无 BOM）+ CRLF，Windows 下各编辑器与 Git 都不会出问题；
- 边界与限制必须单独成节，不藏在正文里 —— 权限这类功能最怕「看起来做了、其实只做了一半」。

## 四、后续可以补的

- 把「插件启动守卫」也整理成同规格的文档（令牌生成、四道校验、失败日志字段）；
- 补一份「新增一个受限插件」的分步示例：改清单 → 加账号角色 → 验证 403；
- 若后续换成命名管道或 ACL 受限句柄做进程级隔离，需要新增一节说明与当前方案的差异。
