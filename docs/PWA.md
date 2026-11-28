# lazarusWeb PWA 接入说明

框架层提供**默认关闭**的 PWA 开关。开启后，宿主进程直出 manifest、Service Worker、图标与推送端点；Ext / Alpine / hyper 三种外壳自动注入安装、离线与更新提示脚本。业务代码不需要改动协议层。

## 1. 启用

最小配置（命令行）：

```
app.exe --pwa --title=我的应用
```

或配置文件：

```ini
[lazarusWeb]
PWA=1
PWAName=我的应用
PWATheme=#1e88e5
PWABg=#ffffff
```

`lwhyper` 同样接受 `--pwa` 等参数，并把它们透传给 worker。

| 参数 | ini 键 | 说明 |
| --- | --- | --- |
| `--pwa` | `PWA=1` | 总开关，默认关 |
| `--pwa-name=` | `PWAName` | 安装名，缺省取 `--title=` |
| `--pwa-short-name=` | `PWAShortName` | 主屏幕短名，缺省取名称前 12 字 |
| `--pwa-theme=` | `PWATheme` | 工具栏颜色，默认 `#1e88e5` |
| `--pwa-bg=` | `PWABg` | 背景色，默认 `#ffffff` |
| `--pwa-vapid-public=` | `PWAVapidPublic` | VAPID 公钥，base64url 的 P-256 非压缩点 |
| `--pwa-vapid-private=` | `PWAVapidPrivate` | VAPID EC 私钥 PEM 路径 |
| `--pwa-vapid-subject=` | `PWAVapidSubject` | 形如 `mailto:admin@example.com` |
| `--pwa-push-token=` | `PWAPushToken` | 投递接口令牌；留空则 `/lw/pwa/push` 不存在 |
| `--pwa-push-file=` | `PWAPushFile` | 订阅库，默认 `<root>\pwa-subscriptions.json` |
| `--pwa-message-file=` | `PWAMessageFile` | 广播消息，默认 `<root>\pwa-message.json` |

相对路径一律按 exe 目录解析。框架资源文件位于 `src/client/`：`sw.js`、`pwa.js`、`icon-192.png`、`icon-512.png`；部署时随 `lw/` 客户端资源一起拷贝即可。

## 2. 端点

| 路径 | 用途 |
| --- | --- |
| `/lw/manifest.webmanifest` | 动态生成 manifest，`start_url`/`scope` 自动带插件前缀 |
| `/lw/sw.js` | Service Worker，响应带 `Service-Worker-Allowed` |
| `/lw/pwa.js` | 注册、更新提示、`window.LWPWA` API |
| `/lw/icon-192.png`、`/lw/icon-512.png` | PWA 图标 |
| `/lw/pwa/config` | 客户端读取开关与 VAPID 公钥 |
| `/lw/pwa/subscribe`、`/lw/pwa/unsubscribe` | 浏览器订阅/退订 |
| `/lw/pwa/message` | Service Worker 取广播消息 |
| `/lw/pwa/push` | 服务端投递，需 `X-LW-PWA-Token` 头 |

所有 `/lw/pwa/*` 与 PWA 静态资源在插件模式下由宿主直出，不转发给插件 worker。Service Worker 明确绕过 `/lw/api/*`、`/lw/ajax/*`、`/lw/pwa/*`、探针与控制端点，避免缓存会话数据。

## 3. Web Push

生成 VAPID 密钥对（需要 openssl 命令行）：

```
openssl ecparam -name prime256v1 -genkey -noout -out vapid.pem
openssl ec -in vapid.pem -pubout -outform DER -out vapid_pub.der
python -c "import base64;print(base64.urlsafe_b64encode(open('vapid_pub.der','rb').read()[-65:]).rstrip(b'=').decode())"
```

把打印出的字符串填 `PWAVapidPublic`，`vapid.pem` 路径填 `PWAVapidPrivate`。运行时签名使用 FPC 的 OpenSSL 单元，需随程序提供 `libcrypto-3-x64.dll`（与 `--ssl` 要求相同）；PWA 不开推送时不需要该 DLL。

浏览器订阅（业务代码自行决定何时请求权限）：

```js
LWPWA.subscribe().then(function (sub) { console.log('subscribed', sub.endpoint); });
```

服务端投递广播消息：

```
curl -X POST http://127.0.0.1:8090/lw/pwa/push \
  -H "X-LW-PWA-Token: <PWAPushToken>" \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"系统通知\",\"body\":\"您有新的待办\",\"url\":\"/\",\"ttl\":60}"
```

投递采用 **空负载 tickle**：服务端只发唤醒信号，Service Worker 收到后从 `/lw/pwa/message` 读取标题/正文/链接并显示通知。这样避免实现 Web Push 的 aes128gcm 负载加密，代价是消息为全局广播、且通知内容依赖浏览器当时能访问服务器；按用户定向推送需要扩展订阅记录结构。

## 4. 约束

- 安装与 Service Worker 要求 HTTPS 或 `localhost`；框架已有 `--ssl` 可直接提供 HTTPS。
- 更新提示由 `pwa.js` 显示一个右下角横幅；用户点击“立即更新”后 SW 跳过等待并刷新页面。
- Service Worker 只缓存页面壳与静态资源；业务 API 永远走网络。
- 订阅库上限 1000 条；超出后新订阅返回 400。
