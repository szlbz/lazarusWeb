# lazarusWeb 安全说明：SQL 注入与信任边界

> 版本 0.9.6 · 2026-11-18
>
> **一句话结论**：框架层没有 SQL 通道，不存在"把浏览器文本拼成 SQL 去执行"
> 的端点；注入风险取决于业务代码是否把浏览器回传值拼进 SQL。这是所有
> "服务端权威"框架共有的责任分担，不是 lazarusWeb 特有缺陷。
>
> 本文只回答 SQL 注入这一件事。HTTPS / 反代 / 部署见 `deploy/README.md`，
> 会话与集群见 `WHYPER.md` / `LOADBALANCE.md`，上传下载与登录能力见
> `FEATURES.md` §2.6。

---

## 1. 信任边界

lazarusWeb 的模型是**服务端权威**：浏览器只拿到控件树快照，业务代码、
SQL、权限判断全在服务端内存里。浏览器能送回服务端的只有事件三元组
`{id, ev, val}`——没有 SQL 文本这一项。

| 层 | 收到什么 | 能做什么 |
|---|---|---|
| 浏览器（不可信） | 用户操作 | 发出 `id` / `ev` / `val`，其中 `val` 是控件的新值 |
| 框架 `lwdispatch` | 事件三元组 | 按 `id` 定位控件、按类型校验、`val` 写入 `TField` 或控件属性 |
| 数据集 / 业务代码 | 字段值、事件 | 由**业务代码**决定何时 `Post`、用什么 SQL 落库 |

因此"框架自己会不会拼 SQL"这个问题的答案是：**不会，它根本不碰 SQL**。

---

## 2. 框架层：三条架构性理由

这不是"恰好没写错"，而是三条结构性保证：

1. **`src/core` 里没有任何 SQL 执行代码**。全库搜索 `TSQLQuery` /
   `ExecSQL` / `ExecuteDirect` / `SQL.Text`，只有注释提及，没有一处真正
   构造或执行 SQL。数据库访问完全属于业务代码（demo / 用户工程）的职责。
2. **不存在 SQL 端点**。框架没有"接收 SQL 文本去服务端执行"的接口；
   `TLWApp.AddAjax` 注册的自定义端点由业务自己决定做什么，框架不赋予
   它们任何 SQL 语义。
3. **回写走字段赋值，不走字符串拼接**（证据）：
   - `src/core/lwdispatch.pas:173` `LWDBWrite`：拿到 `TField` 对象，
     `ds.Edit` 后对字段赋值，浏览器值从不进入 SQL 字符串；
   - `lwdispatch.pas:604-607`：DBGrid 单元格编辑用浏览器传来的**列索引**
     `col` 索引 `G.Columns[col].Field`，并校验 `ReadOnly`，不信任客户端文本；
   - `lwdispatch.pas:742-763`：表头/单元格点击（`OnTitleClick`/`OnCellClick`）
     只从浏览器收**列索引**，服务端据此取 `TColumn` 对象交给业务事件；框架
     本身不读取 `Column.FieldName`（`lwdispatch.pas` 对 `FieldName` 零命中），
     字段名由业务代码的事件处理器自行读取，浏览器无法指定字段名。

---

## 3. demo 层：安全实践与可借鉴写法

仓库自带的数据库 demo 全部按需采用了参数化或类型校验：

| 位置 | 做法 | 评价 |
|---|---|---|
| `demos/dbaware/uAjax.pas:169-172` 改价 | `UPDATE … WHERE code = :c` + `ParamByName` | 参数化，安全 |
| `uAjax.pas:84-86` `limit` | `StrToIntDef` + 钳制 1–500 后拼入 `LIMIT` | 数值化，安全 |
| `demos/dbaware/uLogin.pas:217-219` 登录 | `WHERE login=:u AND pwd=:p` + `ParamByName` | 参数化，安全 |
| `uAwareMain.pas:528-550` 增删改 | 全部 `ParamByName`（含 Blob `LoadFromStream`） | 参数化，安全 |
| `demos/db/uDbMain.pas:383-386` 搜索 / 过滤 | `QuotedStr('%'+kw+'%')` 转义后拼 `LIKE` | **可用但较弱**，见 §4 |
| `uDbMain.pas:397-398, 849-858` 排序 | `FSortField` 取自 `Column.FieldName`（服务端字段名） | 安全，浏览器不提供字段名 |

`ParamByName` 是推荐模板：值与 SQL 结构分离，无论浏览器送来什么字符，
都只当作数据，不会被解释为 SQL 语法。

---

## 4. 需要注意的两个点

**一、`QuotedStr` 手工转义不如参数绑定稳健。**
`demos/db/uDbMain.pas` 的 `BuildWhere` 用 `QuotedStr` 转义搜索关键词，它对
单引号做翻倍转义，能挡住经典的 `' OR 1=1--` 注入，因此**不构成当前漏洞**；
但它依赖转义函数的正确性，面对非常规编码或后续改动更脆弱。新代码请优先
用 `ParamByName`：`SQL.Text := '… WHERE name LIKE :kw'; ParamByName('kw').AsString := '%' + kw + '%';`

**二、责任边界在业务代码。**
框架把浏览器值安全地送到了 `TField`，但**何时 `Post`、用什么 SQL 落库由业务
决定**。如果开发者自己写：

```pascal
SQL.Text := 'SELECT * FROM items WHERE name = ' + edFind.Text;   // 危险
```

那就会被注入——这与用不用 lazarusWeb 无关。`edFind.Text` 此刻是服务端控件
的真实值，但它的内容仍来自浏览器。

---

## 5. 写业务代码时的自检清单

- [ ] 所有来自控件值 / AJAX body / URL 参数的字符串，进入 SQL 前一律走
      `ParamByName`，不直接拼接；
- [ ] `ORDER BY` / `LIMIT` 这类无法参数化的位置，用**白名单或数值化**：
      字段名从服务端常量或 `Column.FieldName` 取，`LIMIT` 用
      `StrToIntDef` 后钳制上下界（范例见 `uAjax.pas:84-86`）；
- [ ] 登录 / 权限判断放在服务端事件里，不要把"是否放行"的判断下发给浏览器
      （框架默认未认证事件全拒，见 `FEATURES.md` §2.6）；
- [ ] 自定义 AJAX 端点（`AddAjax`）接到的参数同样视为不可信输入；
- [ ] 评审时按"这个值最初是谁给的"追溯，而不是看它在服务端是不是控件属性。

---

## 6. 一句话总结

框架没有可被注入的 SQL 通道，demo 也用了参数化；**是否安全最终取决于业务
代码是否遵循参数化查询**。把这条边界写进团队规范，比依赖框架"天然免疫"
更可靠。
