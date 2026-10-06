# E — WebSocket 拦截器选型实测：`@mswjs/interceptors` vs `@rxliuli/vista`

本报告回答：**MV3 扩展在第三方页面的 MAIN world 冒充 aria2 RPC 服务端时，WebSocket 中间件该用哪个。**
所有结论均为实测值；三列对照给出原始值而非"一致/不一致"。未测到的项目在 §7 明确写"未测"。

## 0 元信息

| 项 | 值 |
|---|---|
| 日期（UTC） | 2026-10-06 |
| Chromium | **`148.0.7778.96`**（`ctx.browser().version()` 实测；二进制来自 `~/.cache/ms-playwright/chromium-1223`，目录 `chrome-linux64`） |
| Playwright | `1.60.0`（`/tmp/aria2-probe/E-ws/node_modules/playwright`，从已有 `C-limits/pw` 复制复用） |
| Node / npm | `v24.21.0` / `11.19.0` |
| esbuild | `0.28.2` |
| Xvfb | `/usr/bin/xvfb-run`、`/usr/bin/Xvfb`；实际命令 `xvfb-run -a node run.js` |
| 候选甲 | `@mswjs/interceptors` **0.45.7**，走 `@mswjs/interceptors/WebSocket` → browser 条件 → `lib/browser/interceptors/WebSocket/index.js` |
| 候选乙 | `@rxliuli/vista` **0.5.3**，`interceptWebSocket`（`dist/interceptors/ws.mjs`，源码头注释 `/** @beta */`） |
| 宿主页 | `http://127.0.0.1:8791/strict.html`、`http://127.0.0.1:8791/open.html`（本地 HTTP，CSP 走响应头） |
| 试验目录 | `/tmp/aria2-probe/E-ws/`（全绝对路径；`/workspace` 只写本报告） |
| 跑了几格 | 8 格 = 5 格 `/strict.html`（部署形态 + ISOLATED 对照）× 3 格 `/open.html`（保真度 + mock），全部 `ok` |
| 原始输出 | `/tmp/aria2-probe/E-ws/out/*.json`（每格一份，共 8 份）；关键值全量抄录于 §9 |

### 0.1 精确版本与来源

两个包在 npm 上**都没有发布 `gitHead`**（`npm view @mswjs/interceptors@0.45.7 gitHead` 与 `npm view @rxliuli/vista@0.5.3 gitHead` 均无输出），所以**无法给出 commit SHA**；以 tarball + integrity 作为精确锁定：

| 包 | 版本 | resolved | integrity (sha512) | npm publish (UTC) |
|---|---|---|---|---|
| `@mswjs/interceptors` | 0.45.7（`dist-tags.latest` = 0.45.7） | `https://registry.npmjs.org/@mswjs/interceptors/-/interceptors-0.45.7.tgz` | `sha512-PPZQBiojRuy1jJQoUqbrJhoac47GC1GwRazDrYwwbE70zfqMkOY/5a+Du4hp3vlPUXLt/um4TMcmRabmooAkxw==` | 2026-10-04T02:29:47.097Z |
| `@rxliuli/vista` | 0.5.3（`dist-tags.latest` = 0.5.3） | `https://registry.npmjs.org/@rxliuli/vista/-/vista-0.5.3.tgz` | `sha512-Az9GmwzACiV0NRKnQBRQiK5t8PzNWnIqZ7PIoKq+i3gMDvojKGQxam89qv7PpWX5GvMt7eWr171A4Fxu/vK01A==` | 2026-08-02T04:58:54.539Z |

## 1 判决

> **用乙（`@rxliuli/vista` `interceptWebSocket`），但需修 7 处**——其中 **6 处必须 vendor/fork 那 ~100 行 `dist/interceptors/ws.mjs`**（实测：乙的 middleware 上下文只有 9 个固定键、无 socket 实例可达，见 §5.6），1 处可以在我们自己的 middleware 内规避。上游 `@beta` + CI 不跑测试，**fork 后必须由我们自己的回归测试接管**。

判决依据（全部来自本次实测，详见 §3–§6）：

1. **两库在"MV3 MAIN world + 严格 CSP"下都能跑**（§3，甲在这一组合下是首次实测）：MAIN world 注入后页面 `WebSocket` 确实被替换、双向伪造成功（拿到 `aria2.getVersion` 的伪造响应 + `aria2.onDownloadStart` 推送）；同样 bundle 装进 `world:"ISOLATED"` 后**页面 API 完全保持原生、mock 完全无效**——证明 MAIN 格的成功不是环境副作用。
2. **两库都能"不建真实连接"完成双向通信**（§4）：用不存在主机 `ws://nonexistent.invalid:6800/jsonrpc` 全程 0 个 `error`；更强证据是服务端 accept 日志——同一 URL 指向真实监听端口时，原生留痕 `GET /jsonrpc HTTP/1.1`，甲/乙**该行完全不存在**，且两库的客户端发帧计数只来自透传那条连接（原生 2 帧 / 甲 1 帧 / 乙 1 帧）。
3. **两家都不是原生**（§5）：`Object.prototype.toString.call(ws)` 都变成 `[object EventTarget]`；`Object.getPrototypeOf(ws) === WebSocket.prototype` 都是 `false`；`ws instanceof <替换前原生构造器>` 都是 `false`；mock 事件的 `isTrusted` 都是 `false`（改不了，如实记录）。**纯 JS 伪造做不到"原型链与 `addEventListener` 同时为真"**，这一点两库都得接受。
4. **选乙不选甲，是因为甲在本题的硬需求"未命中原样放行"上实测不保真，且甲的实例形状问题修不到位**：
   - **透传路径谎报连接**（功能性，不可接受）：注册了 `connection` 监听器时，甲的 mock socket 会**无条件自行 `open`**。实测未命中的 `http://example.com/`：甲 `open@0`、`readyState=1`，而原生同一时刻是 `readyState=0`、无任何事件（甲/原生/乙三列都实测到了，乙与原生一致）；`'not a url'`：甲 `open@1 → error → close 1006(wasClean:`**`true`**`)`，原生与乙都只有 `error → close 1006(wasClean:false)`。**"命中就伪造、未命中原样放行"是本题写死的需求，这条直接违背。**
   - **`send()` 在 CONNECTING 状态会把 socket 关掉**（功能性）：实测甲抛出的 `DOMException.name` 是 `"Error"`（原生是 `InvalidStateError`），并且 `readyState` 立刻 `0 → 2`、随后 `3`，派发 `close 1000/wasClean:true`；原生抛错但连接不受影响。
   - **实例形状修不到位**（结构性）：实测甲的 `connection` 事件确实交出了 socket 实例（`client.socket` 可达，见 §5.6），所以 `send`/`close` 这类**行为**缺陷可以由我们逐实例包一层修掉；但形状层包不掉——`Object.getPrototypeOf(ws) === WebSocket.prototype` 为 `false`、`ws instanceof WebSocket` 为 `false`、`Object.getOwnPropertyNames(ws)` 有 14 项，其中 `readyState/url/protocol/extensions/bufferedAmount/binaryType` 是**可写** data 属性（页面可以直接改写 `ws.readyState`）；而实测 `client.socket` 的 own 属性里**没有** `send`/`close`（它们来自 `WebSocketOverride.prototype`），所以换原型会连带丢掉这些方法。
   - 附带（全局足迹）：甲的窗口级 patch 把 `WebSocket` 自己变成 enumerable（实测 `Object.keys(window)` 含 `"WebSocket"` = `true`，乙/原生都是 `false`），并往页面塞 `__MSW_INTERCEPTORS_REGISTRY`；甲的 `WebSocketInterceptor` 每页只能 apply 一次（第二次 apply 实测抛 `Invariant Violation: Failed to replace a global value at "WebSocket": already replaced.`）。
5. **乙没有上述透传/状态机问题，但缺陷都在 class 内部、middleware 够不着**：实测乙的 middleware 上下文只有 9 个固定键（`contextKeys` = `onClientMessage,onClose,onOpen,onServerMessage,protocols,sendToClient,sendToServer,type,url`），`hasSocketLike: []`、无 symbol——**拿不到 socket 实例**，所以下面 1–7 项里有 6 项只能靠 vendor/fork 那 ~100 行 `ws.mjs` 来修：
   1. **构造异常被 `.catch(()=>{})` 吞掉**：`new WebSocket('ws://')` 不抛错、不派 `error`/`close`、`readyState` 永远停在 `0`（静默挂死）；`ws://…/jsonrpc#frag` 更糟——原生抛 `SyntaxError`，乙把它**静默 mock 成功**（`open@0`，`readyState=1`）。
   2. **`close()` 在 CONNECTING 期间调用会产生僵尸态**：派发 close 之后 `readyState` 又回到 `1`（OPEN）（实测 4/4 close 用例 `readyStateAfter200ms === 1`）。
   3. **`close(code, reason)` 完全没有参数校验**：`close(9999)`/`close(1005)` 不抛错，直接派发带非法 code 的 close 且 `wasClean` 恒 `true`；200 字节 reason 也不抛（原生抛 `SyntaxError`）。
   4. **`onopen` 属性处理器恒定先于 `addEventListener` 监听器**（原生按注册顺序；实测"先 addEventListener 后 onopen"时乙输出 `["onopen-attr","addEventListener"]`，反序）。
   5. **常量位置与属性特征不对**：`WebSocket.prototype` 上**完全没有** `CONNECTING/OPEN/CLOSING/CLOSED`（原生有，且 `writable:false, configurable:false`）；静态常量实测 `writable:true, configurable:true`；实例上多出 4 个 own enumerable 常量。（fork 时顺带修构造器外观：`name`=`CustomWebSocket`、`length`=2、`String()` = class 源码、`prototype` 是新对象。）
   6. **`MessageEvent.origin` 恒为 `""`**：mock 消息与**真实透传消息**都是空串（原生 `ws://127.0.0.1:8792`）。
   7. **`binaryType` 接受非法值**（实测赋 `'bogus'` 后读回 `'bogus'`；原生忽略非法值、保持 `'arraybuffer'`）。
6. **可在我们侧规避的 1 处（不改库）**：乙的 mock 响应是在 `ws.send()` **调用栈内同步派发** `message`（实测 `deliveredSynchronouslyInsideSend: true`；原生与甲都不是）。在我们自己的 middleware 里把 `c.sendToClient(...)` 包一层 `queueMicrotask` 即可。

一句话取舍：**甲的形状层更接近原生（Proxy 包住原生构造器）、且能从外部修，但它在"透传保真"和"`send()` 状态机"上实测有功能性硬伤；乙的功能语义更接近原生，但外形和异常路径的账要在 fork 里一次性还清。** 本题的硬需求是"命中伪造 / 未命中原样放行"，透传保真是不可让步项，因此选乙。

## 2 两库版本与打包方式

### 2.1 打包命令（原文）

两个库都是 ESM-only，MAIN world 注入要求单文件，各自 esbuild 打成 IIFE：

```
npx esbuild src/entry-msw.js   --bundle --format=iife --platform=browser --target=chrome120 --legal-comments=none --outfile=ext/msw-main/hook.js
npx esbuild src/entry-msw.js   --bundle --format=iife --platform=browser --target=chrome120 --legal-comments=none --outfile=ext/msw-iso/hook.js
npx esbuild src/entry-vista.js --bundle --format=iife --platform=browser --target=chrome120 --legal-comments=none --outfile=ext/vista-main/hook.js
npx esbuild src/entry-vista.js --bundle --format=iife --platform=browser --target=chrome120 --legal-comments=none --outfile=ext/vista-iso/hook.js
```

产物：甲 `71.1 kB`、乙 `14.4 kB`（未压缩、`--legal-comments=none`）。`grep -c "^import \|^export "` 全部为 0，即确为自包含 IIFE。

- 甲入口：`import { WebSocketInterceptor } from '@mswjs/interceptors/WebSocket'`（`--platform=browser` 命中 `browser` 条件，落在 `lib/browser/...`，不是 node 入口）。
- 乙入口：`import { interceptWebSocket } from '@rxliuli/vista'`（`dist/index.mjs` → `dist/interceptors/ws.mjs`）。

### 2.2 扩展形态（4 个独立扩展，一轮只加载一个）

`ext/msw-main`、`ext/msw-iso`、`ext/vista-main`、`ext/vista-iso` 各含自己的 `hook.js` 副本 + 一份 manifest，4 份只有 `world` 不同：

```json
{
  "manifest_version": 3,
  "name": "E-ws probe <cell>",
  "version": "1.0.0",
  "content_scripts": [{
    "matches": ["http://127.0.0.1:8791/*"],
    "js": ["hook.js"],
    "run_at": "document_start",
    "world": "MAIN",
    "all_frames": false
  }]
}
```

启动参数：`chromium.launchPersistentContext(profile, { headless: false, acceptDownloads: true, args: ['--no-sandbox','--disable-dev-shm-usage', '--disable-extensions-except=<ext>', '--load-extension=<ext>'] })`，外层 `xvfb-run -a`，每格独立 profile 目录。

### 2.3 两个 hook 的 mock 逻辑（同一套 aria2 语义，两边等价）

- 命中判据：URL 字符串包含 `/jsonrpc` → 伪造；否则原样放行（甲 `server.connect()`，乙 `next()`）。
- 命中时**既不 `next()` 也不 `server.connect()`**，即不建真连接。
- 客户端 `send({id,method:'aria2.getVersion'})` → 回推 `{"id":…,"jsonrpc":"2.0","result":{"version":"1.37.0-mock","enabledFeatures":[…]}}`。
- `open` 后 60 ms 主动推 `{"jsonrpc":"2.0","method":"aria2.onDownloadStart","params":[{"gid":"mock-gid-…"}]}`（服务端推送通道）。
- 两个 bundle 都在 patch **之前**先抓原生构造器存入 `window.__E_WS_NATIVE`（§5 里"原生构造器"的同一 realm 来源；`instanceof` 必须同 realm 才有效）。
- 两个 bundle 都往 `document.documentElement` 写 `data-e-ws-hook`（DOM 跨 world 共享），用来证明"内容脚本到底跑没跑、跑在哪个 world"。

### 2.4 宿主页与 CSP 对照设计

服务端按路径下发 CSP 响应头：

| 页面 | CSP 响应头 | 用途 |
|---|---|---|
| `/strict.html` | `default-src 'self'; script-src 'self'` | §3 部署形态、CSP 对照、ISOLATED 对照 |
| `/open.html` | `default-src 'self'; script-src 'self'; connect-src ws: wss: http: https:` | §4–§6：script CSP 仍然严格，但**放开 connect-src**，这样"库若漏回真构造器"会真的发起连接、可被观测 |

> 为什么必须有两个页面：在 `/strict.html` 上 `connect-src` 回落到 `default-src 'self'`，**原生的真实连接会被 CSP 直接掐死**——实测原生格 `new WebSocket('ws://nonexistent.invalid:6800/jsonrpc')` 返回时 `readyState` 已经是 **3（CLOSED）**，`error` 在 0 ms 就派发。若在严格页上做"没有 error 所以没建真连接"的推断，会被 CSP 的静默拦截污染，证据不可信。所以 §4–§6 一律在 `/open.html` 上测。

两个页面都在 `<head>` 与 `</body>` 前各放一段**内联**脚本（`window.__INLINE_RAN = true` / `window.__INLINE_RAN_2 = true`）作为"CSP 真的生效"的对照；同源外链 `/probe.js` 承载探针本体（`script-src 'self'` 放行）。

### 2.5 探针与"不建真连接"的服务端证据

- 探针是一份同源 `/probe.js`，**同一套代码**跑三列（原生基线 / 甲 / 乙），每格 8 个 cell 全部产出 72 项结果。
- 另起一个 TCP 监听 `127.0.0.1:8792` 作为 **accept 日志服务端**：记录每个 TCP accept 与 request-line，能完成 RFC6455 握手、握手后 15 ms 推一条 `real-server-hello` 文本帧、把客户端文本帧回显成 `echo:<payload>`、并响应 close 帧（`/slowclose` 路径故意把 close 应答延迟 1200 ms）。页面通过 `fetch('/__accepts')` 在用例前后取快照，实现**逐用例接受数归因**。
- 探针里所有事件监听器都按实例绑定、用 `event.target === socket` 过滤、用完即摘——第一版曾因 `var` 闭包在循环里串事件，已修（§9 的 `errorPath.invalidUrlConstructor` 是修好后的数据）。

## 3 部署形态结果（含 ISOLATED 对照）

8 格全部 `ok`（无 `pageErrors`）。CSP 对照：**5 格的页内联脚本全部没跑**（`__INLINE_RAN = false`、`__INLINE_RAN_2 = false`），且 `securitypolicyviolation` 都记到了 `blockedURI:"inline", violatedDirective:"script-src-elem"`——CSP 确实在生效。

| cell | 扩展 | world | `data-e-ws-hook`（DOM 标记） | hook 自报 | 页面 `WebSocket` 被替换 | `WebSocket.name` | 内联脚本跑了？ | mock 拿到伪造 `getVersion` 响应 | mock 拿到 `onDownloadStart` 推送 |
|---|---|---|---|---|---|---|---|---|---|
| `native-strict` | 无 | — | `null` | `null` | **否**（`=== 原生` true） | `WebSocket` | `false / false` | `false` | `false` |
| `msw-main-strict` | 甲 | **MAIN** | `{"lib":"msw","world":"MAIN","patched":true}` | `{"lib":"msw","applied":true,"readyState":"ACTIVE","patched":true}` | **是** | `WebSocket` | `false / false` | **`true`** | **`true`** |
| `msw-iso-strict` | 甲 | ISOLATED | `{"lib":"msw","world":"ISOLATED","patched":true}` | `null`（页面看不到） | **否** | `WebSocket` | `false / false` | `false` | `false` |
| `vista-main-strict` | 乙 | **MAIN** | `{"lib":"vista","world":"MAIN","patched":true}` | `{"lib":"vista","applied":true,"patched":true}` | **是** | `CustomWebSocket` | `false / false` | **`true`** | **`true`** |
| `vista-iso-strict` | 乙 | ISOLATED | `{"lib":"vista","world":"ISOLATED","patched":true}` | `null`（页面看不到） | **否** | `WebSocket` | `false / false` | `false` | `false` |

逐条对上题目的三格要求：

1. **甲装进 MAIN world**：页面 `WebSocket` 真被替换（`window.WebSocket !== 原生` → `true`，`ctor.globalIsNativeIdentity = false`），mock 生效——`open` 1 次、0 个 `error`，伪造的 `{"result":{"version":"1.37.0-mock","enabledFeatures":["msw-interceptor"]}}` 与 `aria2.onDownloadStart` 推送都拿到了。**结论：能跑。**
2. **乙装进 MAIN world**：同上（`ctor.name` 变成 `CustomWebSocket`），伪造响应 `enabledFeatures:["vista"]` 与推送都拿到。**结论：能跑。**
3. **ISOLATED 对照**：两库的 ISOLATED 格都证明了"内容脚本确实跑过、但只在隔离世界生效"——DOM 标记写明 `world:"ISOLATED"`、`patched:true`（那是隔离世界自己的 `WebSocket`），而页面侧 `ctor.globalIsNativeIdentity = true`、`Object.prototype.toString.call(ws) = "[object WebSocket]"`、`ws instanceof 原生 = true`，mock 完全无效（`mockVer=false`、`error` 1 次即真实 DNS 失败）。**结论：ISOLATED 完全无效，MAIN 格的成功不是环境副作用。**

附带一条与本题直接相关的证据：在 `/strict.html` 上，**原生路径的 WS 数据通道根本不可用**（`connect-src` 回落 `'self'`，构造返回时 `readyState` 已是 3），而 MAIN world 的 mock 路径 `readyState=0 → 1` 正常完成握手。也就是说，在"严格 CSP + 冒充"这个组合里，**mock 不是可选优化，而是让 WS 通道能工作的前提**。

原始值见 §9（`native-strict` / `msw-main-strict` / `msw-iso-strict` / `vista-main-strict` / `vista-iso-strict`）。

## 4 mock 能力结果（含"未建真连接"的证据）

### 4.1 主用例：不存在的主机名 + 双向伪造（`/open.html`）

URL 一律 `ws://nonexistent.invalid:6800/jsonrpc`（该 TLD 不解析）。流程：`new WebSocket(url)` → 中间件拦下、不 `next()`/不 `server.connect()` → `open` → 页面 `send({"id":"probe-1","jsonrpc":"2.0","method":"aria2.getVersion","params":[]})` → 中间件回推伪造 JSON-RPC → 页面 `message` 收到。

| 列 | `open` | 伪造响应（`1.37.0-mock`） | 伪造推送（`aria2.onDownloadStart`） | `error` 次数 | `close` 次数 | `readyState` @350ms / @1050ms | 时间线（ms） |
|---|---|---|---|---|---|---|---|
| 原生 | **无** | `false` | `false` | **1** | 1（`1006, wasClean:false`） | `3 / 3` | `constructed@0 → error@61 → close@61` |
| 甲 msw | 1 | **`true`** | **`true`** | **0** | **0** | `1 / 1` | `constructed@0 → open@1 → open-attr@1 → message(推送)@61 → sent@351 → message(响应)@351` |
| 乙 vista | 1 | **`true`** | **`true`** | **0** | **0** | `1 / 1` | `constructed@0 → open-attr@0 → open@0 → message(推送)@60 → message(响应)@351 → sent@351` |

> 时间线里的**绝对毫秒数是单次采样**，跑与跑之间有抖动（同一个 DNS 失败用例在本轮不同格/不同次里落在 13–75 ms），但**序关系与"有没有 error/close"是稳定的**；`readyState`、事件次数等离散量在多次运行中完全一致。

判据兑现：**甲、乙都是"没有 error 且拿到伪造响应"**，而原生对同一 URL 给出 `error`(13 ms) + `close 1006`。所以两库在这一格都**没有建真连接**。

### 4.2 更强的证据：服务端 accept 日志（同一 URL 指向真实监听端口）

`ws://127.0.0.1:8792/jsonrpc`（端口真的有服务端在听、能完成握手）。用例前后各取一次 `GET /__accepts` 快照：

| 列 | TCP accept 增量 | Upgrade 请求增量 | 页面侧结果 |
|---|---|---|---|
| 原生 | **+1** | **+1** | `open` 1 次、收到真实服务端的 `real-server-hello`、`readyState 1` |
| 甲 msw | **0** | **0** | `open` 1 次、收到**伪造**推送 + **伪造** `getVersion` 响应、`readyState 1` |
| 乙 vista | **0** | **0** | 同上（伪造件 `enabledFeatures:["vista"]`） |

整格总账（把整格跑完的服务端 accept 日志全列出来，request-line 是原始值）：

| 列 | 总 TCP accept | request-line 列表 |
|---|---|---|
| 原生 | **5** | `GET /jsonrpc HTTP/1.1`, `GET /open?case=A`, `GET /open?case=B`, `GET /open?case=C`, `GET /slowclose` |
| 甲 msw | 4 | `GET /open?case=A`, `GET /open?case=B`, `GET /open?case=C`, `GET /slowclose` |
| 乙 vista | 4 | `GET /open?case=A`, `GET /open?case=B`, `GET /open?case=C`, `GET /slowclose` |

**`GET /jsonrpc HTTP/1.1` 只出现在原生列，两库列完全没有这一行**——被 mock 的连接从未触网。
再加一层：服务端统计收到的客户端文本帧数（`clientTextFrames`）——原生 **2**（1 条是 `/jsonrpc` 上真实发出的 RPC，1 条是透传用例的回显），甲/乙各 **1**（只有透传那一条）。即**页面在 mock 连接上 `send()` 的内容一帧都没到网络**。

### 4.3 顺带测到的"未命中原样放行"（透传）能力

`ws://127.0.0.1:8792/open?case=C`（不含 `/jsonrpc`）：两库都走放行分支（甲 `server.connect()`、乙 `next()`），服务端 accept +1，页面收到真实服务端的 `real-server-hello`；页面 `send('client-to-real-server')` 后服务端回显，页面收到 `echo:client-to-real-server`（甲/乙/原生三列都是这个值）。**双向透传在两库都成立**——乙在这条路径上是原生时序，甲有 §6 的保真问题（会提前报 `open`）。

`/slowclose`（服务端延迟 1200 ms 才应答 close 帧）也一并测了，见 §6 最后一行。

## 5 保真度对照表（原生 / 甲 / 乙）

三列同跑同一套探针，全部在 `/open.html`（script CSP 严格、connect-src 放开），Chromium `148.0.7778.96`。
"替换前原生构造器"= 各列 hook 在 patch 之前抓的 `window.__E_WS_NATIVE`（原生列 = 页面自己的 `WebSocket`）。

### 5.1 构造器 / 全局层（原始值）

| # | 探针 | 原生 `148.0.7778.96` | 甲 `@mswjs/interceptors` 0.45.7 | 乙 `@rxliuli/vista` 0.5.3 |
|---|---|---|---|---|
| 1 | `WebSocket.name` | `"WebSocket"` | `"WebSocket"` | **`"CustomWebSocket"`** |
| 2 | `WebSocket.length` | `1` | `1` | **`2`** |
| 3 | `String(WebSocket)` | `function WebSocket() { [native code] }` | **`function () { [native code] }`**（名字丢了） | **`class CustomWebSocket extends EventTarget {\n static CONNECTING = 0; …`** |
| 4 | `Object.prototype.toString.call(WebSocket)` | `"[object Function]"` | `"[object Function]"` | `"[object Function]"` |
| 5 | `WebSocket.prototype === 原生 prototype` | `true` | **`true`**（Proxy 透传，原型没被动过） | **`false`**（新 class 的新原型） |
| 6 | `Object.getOwnPropertyNames(WebSocket)` | `["CLOSED","CLOSING","CONNECTING","OPEN","length","name","prototype"]` | 同原生（Proxy 透传） | 同左（但 `prototype` 指向新对象） |
| 7 | `Object.getOwnPropertyNames(WebSocket.prototype)` | `["CLOSED","CLOSING","CONNECTING","OPEN","binaryType","bufferedAmount","close","constructor","extensions","onclose","onerror","onmessage","onopen","protocol","readyState","send","url"]`（17 项） | **与原生逐项相同**（Proxy 透传） | `["binaryType","bufferedAmount","close","constructor","extensions","onclose","onerror","onmessage","onopen","protocol","readyState","send","url"]`（13 项，**缺 4 个常量**） |
| 8 | `window` 上 `WebSocket` 自身属性描述符 | `{kind:"data", writable:true, enumerable:false, configurable:true}` | **`{kind:"data", writable:true, enumerable:true, configurable:true}`** | `{kind:"data", writable:true, enumerable:false, configurable:true}` |
| 9 | `Object.keys(window)` 含 `"WebSocket"` | `false`（`Object.keys(window).length = 238`） | **`true`（246）** | `false`（243） |
| 10 | 页面可见的新增全局 | `[]` | **`["__MSW_INTERCEPTORS_REGISTRY", …]`** | `[]`（除探针自己的 `__E_WS_*`） |
| 11 | 第二个拦截器实例再 `apply()` | n/a | **抛 `Invariant Violation: Failed to replace a global value at "WebSocket": already replaced.`**（全局仍是第一次的 patch） | 不抛，**静默再包一层**（`globalChangedAgain:true`，原型链深 3），`cancel()` 后 `restoredAfterCancel: true` |

> #9 的绝对计数含探针/hook 自己写入的 `__E_WS_*` 全局，构成为：原生 238 基准 → 乙 243 = +5（hook 的 5 个 `__E_WS_*`/`window.__E_WS_CTX` 等，全是探针自己的）→ 甲 246 = 238 + 5 + `WebSocket` 变可枚举 + `__MSW_INTERCEPTORS_REGISTRY` + `__E_WS_INTERCEPTOR`。所以**可比的是"是否含 `WebSocket`"这一项**（`false` / **`true`** / `false`）与 #10：**甲把 `WebSocket` 自己变成了可枚举属性，并额外在窗口上留了一个注册表全局；乙两项都没有。**
>
> #8/#9 的归因做了对照实验：在本页把**完全相同的 descriptor 形状** `{value, enumerable:true, configurable:true}` 施加到另一个既有窗口接口构造器 `XMLHttpRequest` 上，读回是 `{writable:true, enumerable:true, configurable:true}`（原生为 `{writable:true, enumerable:false, configurable:true}`），`restoreOk:true`；而对**新建**属性名施加同样形状得到 `{writable:false, enumerable:true, configurable:true}`。所以：#8 里 `enumerable` 变 `true` 是甲的 `enumerable: true` 直接造成的（Chrome 对既有窗口属性会保留原 `writable` 位，故 `writable` 仍是 `true`，**不是**甲把它改成只读）。

### 5.2 实例层（`new WebSocket('ws://nonexistent.invalid:6800/jsonrpc')` 后同步读取）

| # | 探针 | 原生 | 甲 | 乙 |
|---|---|---|---|---|
| 12 | `Object.prototype.toString.call(ws)` | `"[object WebSocket]"` | **`"[object EventTarget]"`** | **`"[object EventTarget]"`** |
| 13 | `ws instanceof <替换前原生构造器>` | `true` | **`false`** | **`false`** |
| 14 | `ws instanceof <当前全局 WebSocket>` | `true` | **`false`** | `true` |
| 15 | `ws.constructor.name` | `"WebSocket"` | **`"WebSocketOverride"`** | **`"CustomWebSocket"`** |
| 16 | `Object.getPrototypeOf(ws).constructor.name` | `"WebSocket"` | `"WebSocketOverride"` | `"CustomWebSocket"` |
| 17 | `Object.getPrototypeOf(ws) === WebSocket.prototype` | `true` | **`false`** | `true` |
| 18 | 原型链 | `WebSocket → EventTarget → Object` | **`WebSocketOverride → EventTarget → Object`** | **`CustomWebSocket → EventTarget → Object`** |
| 19 | `Object.keys(ws)` | `[]` | **`["CONNECTING","OPEN","CLOSING","CLOSED","_onopen","_onmessage","_onerror","_onclose","url","protocol","extensions","binaryType","readyState","bufferedAmount"]`（14 项）** | **`["CONNECTING","OPEN","CLOSING","CLOSED"]`（4 项）** |
| 20 | `Object.getOwnPropertyNames(ws)` | `[]` | 同 #19 的 14 项 | 同 #19 的 4 项 |
| 21 | `Object.getOwnPropertySymbols(ws)` | `[]` | **`["Symbol(kPassthroughPromise)","Symbol(kOnSend)"]`** | `[]` |
| 22 | 构造后**立刻** `readyState` | `0` | `0` | `0` |
| 23 | `ws.url`（原样） | `"ws://nonexistent.invalid:6800/jsonrpc"` | 同原生 | 同原生 |
| 24 | `ws.url` 归一化（传 `'WS://Nonexistent.INVALID:6800/jsonrpc'`） | **`"ws://nonexistent.invalid:6800/jsonrpc"`** | 同原生（归一化） | **`"WS://Nonexistent.INVALID:6800/jsonrpc"`（原串，未归一化）** |
| 25 | `ws.protocol` / `extensions` / `bufferedAmount` / `binaryType`（初值） | `""` / `""` / `0` / `"blob"` | 同原生 | 同原生 |
| 26 | `ws.onopen` / `ws.onmessage` 的值 | `null` / `null` | `null` / `null` | `null` / `null` |
| 27 | `ws.CONNECTING/OPEN/CLOSING/CLOSED` 读值 | `0/1/2/3`（来自原型） | `0/1/2/3`（**实例自有**） | `0/1/2/3`（**实例自有**） |
| 28 | `new WebSocket(url,'aria2').protocol`（立刻 / 250 ms 后） | `""` / **`""`** | `""` / **`"aria2"`（凭空回显请求的子协议）** | `""` / **`""`** |
| 29 | `new WebSocket(url,['dup','dup'])` | **抛 `DOMException` name=`SyntaxError`**（"The subprotocol 'dup' is duplicated."） | 不抛（`protocol:""`） | 不抛（`protocol:""`） |
| 30 | `ws.binaryType = 'arraybuffer'` → 再赋 `'bogus'` | `"arraybuffer"` → **`"arraybuffer"`（忽略非法值）** | `"arraybuffer"` → **`"bogus"`（接受）** | `"arraybuffer"` → **`"bogus"`（接受）** |

### 5.3 关键属性的属性描述符（own 还是原型上 + get/set/enumerable/configurable）

`proto-1` = `ws` 的原型链第一层（原生是 `WebSocket.prototype`；甲是 `WebSocketOverride.prototype`；乙是 `CustomWebSocket.prototype`）。

| 属性 | 原生 | 甲 | 乙 |
|---|---|---|---|
| `readyState` | `proto-1`/accessor/`enumerable:true`/`configurable:true`/get,无 set | **`instance`/data/`enumerable:true`/`configurable:true`/`writable:true`/值 `0`** | `proto-1`/accessor/**`enumerable:false`**/`configurable:true`/get,无 set |
| `url` | `proto-1`/accessor/`enumerable:true`/`configurable:true`/get,无 set | **`instance`/data/`writable:true`/值 `"ws://nonexistent.invalid:6800/jsonrpc"`** | `proto-1`/accessor/`enumerable:false`/get,无 set |
| `protocol` | `proto-1`/accessor/`enumerable:true`/`configurable:true`/get,无 set | **`instance`/data/`writable:true`/值 `""`** | `proto-1`/accessor/`enumerable:false`/get,无 set |
| `extensions` | `proto-1`/accessor/`enumerable:true`/`configurable:true`/get,无 set | **`instance`/data/`writable:true`/值 `""`** | `proto-1`/accessor/`enumerable:false`/get,无 set |
| `bufferedAmount` | `proto-1`/accessor/`enumerable:true`/`configurable:true`/get,无 set | **`instance`/data/`writable:true`/值 `0`** | `proto-1`/accessor/`enumerable:false`/get,无 set |
| `binaryType` | `proto-1`/accessor/`enumerable:true`/`configurable:true`/get+set | **`instance`/data/`writable:true`/值 `"blob"`** | `proto-1`/accessor/`enumerable:false`/get+set |
| `onopen` | `proto-1`/accessor/`enumerable:true`/`configurable:true`/get+set | `proto-1`/accessor/**`enumerable:false`**/get+set（另有实例上的 `_onopen` data 属性） | `proto-1`/accessor/**`enumerable:false`**/get+set |
| `onmessage` | 同上（`enumerable:true`） | `proto-1`/accessor/`enumerable:false`/get+set | `proto-1`/accessor/`enumerable:false`/get+set |
| `onerror` | 同上 | `proto-1`/accessor/`enumerable:false`/get+set | `proto-1`/accessor/`enumerable:false`/get+set |
| `onclose` | 同上 | `proto-1`/accessor/`enumerable:false`/get+set | `proto-1`/accessor/`enumerable:false`/get+set |
| `CONNECTING`/`OPEN`/`CLOSING`/`CLOSED` | `proto-1`/data/`enumerable:true`/**`configurable:false`/`writable:false`**/`0,1,2,3` | **`instance`/data/`enumerable:true`/`configurable:true`/`writable:true`**/`0,1,2,3` | **`instance`/data/`enumerable:true`/`configurable:true`/`writable:true`**/`0,1,2,3` |

一句话：**两库的原型 accessor 都从 `enumerable:true` 变成 `enumerable:false`；甲把 6 个状态/地址属性从"原型只读访问器"降级成"实例可写 data 属性"（页面能直接 `ws.readyState = 3`）；两库都把 4 个常量塞成了实例自有可写属性；乙的常量在 `WebSocket.prototype` 上彻底不存在。**

### 5.4 静态常量与原型常量（值与描述符）

| 位置 | 常量 | 原生 | 甲 | 乙 |
|---|---|---|---|---|
| `WebSocket.CONNECTING…CLOSED` | 值 | `0,1,2,3` | `0,1,2,3` | `0,1,2,3` |
| 同上 | 描述符 | `{writable:false, enumerable:true, configurable:false}` | **同原生**（Proxy 透传） | **`{writable:true, enumerable:true, configurable:true}`** |
| `WebSocket.prototype.CONNECTING…CLOSED` | 值 | `0,1,2,3` | `0,1,2,3` | **ABSENT（`undefined`）** |
| 同上 | 描述符 | `{writable:false, enumerable:true, configurable:false}` | **同原生** | **ABSENT** |

### 5.5 行为型保真

| # | 探针 | 原生 | 甲 | 乙 |
|---|---|---|---|---|
| 31 | 事件处理器顺序 A：先 `ws.onopen=f` 再 `addEventListener('open',g)` | `["onopen-attr","addEventListener"]` | `["onopen-attr","addEventListener"]` | `["onopen-attr","addEventListener"]` |
| 32 | 顺序 B：先 `addEventListener('open',g)` 再 `ws.onopen=f` | `["addEventListener","onopen-attr"]` | `["addEventListener","onopen-attr"]`（同原生） | **`["onopen-attr","addEventListener"]`（反了）** |
| 33 | `open`→`message`→`close` 先后（真实连接，`/open?case=C`） | `["open:true","message:true","message:true","close:true"]` | `["open:false","message:false","message:false","close:false"]` | `["open:false","message:false","message:false","close:false"]` |
| 34 | 事件对象 `isTrusted` | `true` | **`false`**（改不了） | **`false`**（改不了） |
| 35 | `open`/`message`/`close` 事件 `event.target === ws`、`currentTarget === ws` | `true` | `true` | `true` |
| 36 | 事件构造器名 | `open:Event`, `message:MessageEvent`, `close:CloseEvent` | `open:Event`, `message:MessageEvent`, `close:**CloseEvent（库私有类）**` | `open:Event`, `message:MessageEvent`, `close:CloseEvent` |
| 37 | `close` 事件 `e instanceof CloseEvent`（页面全局） | `true` | **`false`** | `true` |
| 38 | `close` 事件 `e instanceof Event` / `instanceof MessageEvent` | `true` / `false` | `true` / `false` | `true` / `false` |
| 39 | mock 路径的 `isTrusted`（`open`/`message`） | n/a（原生没有 mock 路径） | **`false` / `false,false`** | **`false` / `false,false`** |
| 40 | mock 消息的 `MessageEvent.origin` | n/a | **`"ws://nonexistent.invalid:6800/jsonrpc"`（整条 URL，不是 origin）** | **`""`** |
| 41 | 真实透传消息的 `MessageEvent.origin` | **`"ws://127.0.0.1:8792"`** | 同原生 `"ws://127.0.0.1:8792"` | **`""`** |
| 42 | mock 响应相对 `ws.send()` 的时序 | n/a | 微任务后在 `send()` 之外派发（`deliveredSynchronouslyInsideSend: false`） | **在 `ws.send()` 调用栈内同步派发（`true`）** |

> #42 的时间线原始值：甲 `… message@351 → sent@351`（`sent` 在前），乙 `… message@351 → sent@351`（**`message` 在 `sent` 之前**，因为 message 是在 `send()` 内部派发的，时间戳同为 351 ms）。这是一条**每个 mock 请求都会走**的差异，但对本项目可以在 middleware 里用 `queueMicrotask` 规避（§1 第 6 条）。

### 5.6 回调上下文里"够得着什么"（决定缺陷能否从外部修）

探针在 hook 内部、每条连接第一次进入回调时，把回调参数的可达面原样记下来（`hook.contextSurface`）：

| 库 | 回调参数 | 实测可达面（原始值） |
|---|---|---|
| 甲 | `interceptor.on('connection', ({client, server}) => …)` | `eventKeys = ["client","server"]`；`clientOwnNames = ["id","socket","transport","url"]`；`clientSocketReachable = true`；**`clientSocketOwnNames = ["CLOSED","CLOSING","CONNECTING","OPEN","_onclose","_onerror","_onmessage","_onopen","binaryType","bufferedAmount","extensions","protocol","readyState","url"]`（有实例，但 own 里没有 `send`/`close`——`clientSocketCanBeWrapped` 为 `true` 是因为 `send`/`close` 来自 `WebSocketOverride.prototype`，可以用 own 属性遮蔽）**；`serverOwnNames = ["client","createConnection","mockCloseController","realCloseController","transport"]`；`serverHasConnect = true` |
| 乙 | `interceptWebSocket([(c, next) => …])` | `contextKeys = ["onClientMessage","onClose","onOpen","onServerMessage","protocols","sendToClient","sendToServer","type","url"]`（9 个）；`contextOwnNames` 与之一致；`protoIsPlainObject = true`；**`hasSocketLike = []`（`socket`/`ws`/`realWs`/`instance`/`self` 一个都没有）**；`symbols = []` |

结论（实测支撑）：
- **甲**：行为类缺陷（`send`/`close` 语义、透传 open 时序）可以由我们**逐实例包一层**在 hook 内修，不需要 fork 库；形状类缺陷（原型身份、`instanceof`、14 个 own 可写属性）包不掉——因为 `send`/`close`/`onopen` 访问器都在 `WebSocketOverride.prototype` 上，实测实例 own 属性里没有它们，换原型会连带丢方法。
- **乙**：**回调里根本拿不到 socket 实例**，所以 §1 第 5 条的 1–7 项里除第 6 项（`origin`，需要实例）……事实上**全部**都只能在 `ws.mjs` 源码里修；只有"同步派发"这一项能在 middleware 里通过 `queueMicrotask` 规避。

### 5.7 事件时序（补：`close` 是否等服务端握手）

服务端 `/slowclose` 故意把 close 应答延迟 **1200 ms**：

| 列 | `close(1000,'bye')` 调用后到 `close` 事件的毫秒数 | 300 ms 内就派发？ | 结束时 `readyState` |
|---|---|---|---|
| 原生 | **1201** | `false`（等真握手） | `3` |
| 甲 | **0** | **`true`**（本地合成一次 `1000/wasClean:true`，不等服务端） | `3` |
| 乙 | **1203** | `false`（同原生，等真握手） | `3` |

## 6 真实连接失败与异常路径的行为差异

全部在 `/open.html`；非法 URL 一栏用 5 个输入逐一构造，事件监听器按实例绑定、`event.target === socket` 过滤、400 ms 窗口。

### 6.1 非法 / 异常 URL 的构造行为（原始值）

> 同样地，表中 `@N` 的绝对毫秒数是单次采样（DNS/握手耗时抖动），离散结论（抛不抛、派发哪些事件、`readyState` 终值）是稳定的。

| 输入 | 原生 | 甲 | 乙 |
|---|---|---|---|
| `'not a url'` | **不抛**（按页面 URL 解析成 `ws://127.0.0.1:8791/not%20a%20url`）→ `error@1`, `close 1006/wasClean:false@1`，400 ms 后 `readyState=3` | 不抛 → **`open@1`**, `error@2`, `close 1006/wasClean:`**`true`**`@3`；`readyState=3` | 不抛 → `error@2`, `close 1006/wasClean:false@2`；`readyState=3`**（与原生一致）** |
| `'http://example.com/'` | 不抛（scheme 换成 `ws:`）→ **恒不派发 `open`**；本轮 400 ms 内无事件、`readyState=0`（真实握手仍挂起） | 不抛 → **`open@0`**（本轮与上一轮都是 `@0`）；`readyState=`**`1`（谎报已连接）** | 不抛 → **恒不派发 `open`**；上一轮 `readyState=0` 无事件，本轮 `error@90 → close 1006@90`、`readyState=3`（见下方注） |
| `'ws://127.0.0.1:8792/jsonrpc#frag'` | **抛 `DOMException` name=`SyntaxError`**："The URL contains a fragment identifier ('frag'). Fragment identifiers are not allowed in WebSocket URLs." | **抛普通 `SyntaxError`**（`isDOMException:false`），消息含 `'#frag'` | **不抛**，而且因含 `/jsonrpc` 被**静默 mock** → `open@0`，`readyState=1` |
| `'ws://'` | **抛 `DOMException` name=`SyntaxError`**："The URL 'ws://' is invalid." | **抛 `TypeError`**（来自内部 `new URL`）："Failed to construct 'URL': Invalid URL" | **不抛、无事件、`readyState` 永远 `0`**（构造异常被构造函数链尾的 `.catch(() => {})` 吞掉） |
| `''` | 不抛（解析为页面 URL）→ `error@2`, `close 1006@2`；`readyState=3` | 不抛 → `open@0`, `error@3`, `close 1006/wasClean:`**`true`**`@3`；`readyState=3` | 不抛 → `error@2`, `close 1006/wasClean:false@2`；`readyState=3`**（与原生一致）** |

> **`'http://example.com/'` 这一行的说明**：该 URL 原生与乙都会去真连（`example.com:80`，无外网），失败时机受 DNS 负缓存/超时影响，跑与跑之间会漂——本轮原生 400 ms 内无事件（`readyState=0`）、乙 90 ms 就 `error+close`，上一轮则反过来（原生与乙都无事件）。**原生与乙之间在这一行的差异不构成库差异**；真正稳定的判别点是：**原生与乙在这一行恒不派发 `open`，而甲恒为 `open@~0` + `readyState=1`**（甲因为 mock socket 无条件自行 open，无论真连接是否已建立、是否最终失败）。
>
> **对题目预设的一处纠正（实测）**：题面写"传非法 URL（如 `'not a url'`）原生抛 `SyntaxError`"——**实测原生不抛**。`'not a url'` 会被当作相对 URL 解析到页面地址（`ws://127.0.0.1:8791/not%20a%20url`），然后是 `error` + `close 1006`。真正抛 `SyntaxError` 的是 `'ws://'`（URL 无效）与含 fragment 的 URL。三个库的对照按实测值记录如上。

### 6.2 不存在的主机（DNS 失败路径）

| 列 | 事件序列（1500 ms 窗口） | `readyState` | 说明 |
|---|---|---|---|
| 原生 | `error@68 (isTrusted:true)` → `close 1006/wasClean:false@68 (isTrusted:true)` | `3` | 真实 DNS 失败 |
| 甲 | `open@0 (isTrusted:false)` | `1` | 该 URL 被 mock，所以**没有** DNS 失败；但注意若该 URL 走透传，甲同样会先报 `open`（见 6.1 第 2 行） |
| 乙 | `open@0 (isTrusted:false)` | `1` | 同上，被 mock |

### 6.3 `send()` 在 `CONNECTING` 状态调用

| 列 | 抛什么 | 抛时 `readyState` | 抛完立刻 `readyState` | 300 ms 后 | 之后的 `close` 事件 |
|---|---|---|---|---|---|
| 原生 | `DOMException` `name:"InvalidStateError"`，message `"Failed to execute 'send' on 'WebSocket': Still in CONNECTING state."` | `0` | `0`（**socket 不受影响**） | `3` | `1006/wasClean:false`（DNS 失败导致） |
| 甲 | `DOMException` 但 **`name:"Error"`**，message 只有 `"InvalidStateError"` | `0` | **`2`（CLOSING）** | `3` | **`1000/wasClean:true`（被 `send()` 自己关掉了）** |
| 乙 | `DOMException` `name:"InvalidStateError"`，message 与原生**逐字相同** | `0` | `0` | `1` | 无（随后正常 mock `open`） |

### 6.4 `close()` 参数校验

| 调用 | 原生 | 甲 | 乙 |
|---|---|---|---|
| `close(9999)` | **抛 `DOMException` `name:"InvalidAccessError"`**："The close code must be either 1000, or between 3000 and 4999. 9999 is neither."；socket 不受影响 | **抛 `InvariantError`**（`name:"Invariant Violation"`，`isDOMException:`**`false`**），message `"InvalidAccessError: close code out of user configurable range"`；连接未被关闭（200 ms 后因 mock 自动 `open` 而 `readyState=1`） | **不抛**；立刻派发 `close{code:9999, reason:"", wasClean:true}`，且 200 ms 后 `readyState=`**`1`（僵尸 OPEN）** |
| `close(1005)`（保留码） | **抛 `DOMException` `InvalidAccessError`**（同上，1005） | 同上（`InvariantError`） | **不抛**；派发 `close{code:1005, wasClean:true}`，`readyState` 回到 `1` |
| `close(1000, <200 字节 reason>)` | **抛 `DOMException` `name:"SyntaxError"`**："The close reason must not be greater than 123 UTF-8 bytes." | **不抛**；真的派发 `close{code:1000, reason:<200 字节>, wasClean:true}` | **不抛**；派发 `close{code:1000, reason:<200 字节>, wasClean:true}`，`readyState` 回到 `1` |
| `close(3000,'ok')` | 不抛；`readyState` 立刻 `2`，随后 `3` | 不抛；`readyState` 立刻 `2`，随后 `3`，`close{code:3000,reason:"ok",wasClean:true}` | 不抛；`readyState` 立刻 `2`，随后 **`1`**，`close{code:3000,...}` |

### 6.5 `binaryType` 合法性校验

| 列 | 初值 | 赋 `'arraybuffer'` | 再赋 `'bogus'` |
|---|---|---|---|
| 原生 | `"blob"` | `"arraybuffer"` | **`"arraybuffer"`（忽略非法值，控制台另有 `The provided value 'bogus' is not a valid enum value of type BinaryType.` 警告）** |
| 甲 | `"blob"` | `"arraybuffer"` | **`"bogus"`** |
| 乙 | `"blob"` | `"arraybuffer"` | **`"bogus"`** |

### 6.6 `close()` 与服务端 close 握手

见 §5.7：服务端把 close 应答延迟 1200 ms 时，原生 `1201 ms`、乙 `1203 ms`、**甲 `0 ms`**（甲在本地立刻合成 `1000/wasClean:true`，不等对端）。对"未命中原样放行"的连接，这意味着页面可能在真实 TCP 仍打开时就认为已经干净关闭。

## 7 未能测成的部分与原因

以下项目**未测**，不得从本报告推断其结论：

| # | 未测项 | 原因 |
|---|---|---|
| 1 | 甲在"**没有** `connection` 监听器"时的纯透传分支（源码里 `hasConnectionListeners === false` 那条路径：`kPassthroughPromise.resolve(true)` + `server.connect()` + 由真实服务端 `open` 转发） | 本项目的用法**必须**注册 `connection` 监听器才能伪造响应，所以两份 hook 都注册了。该分支需要另一个 bundle 才能覆盖 |
| 2 | 真 aria2 服务端（`127.0.0.1:6800`）与 `wss://`/TLS 的端到端联调 | 环境里没有 aria2，也没有可用的 TLS WS 服务端；本实验用自建 accept 日志服务端替代 |
| 3 | `Sec-WebSocket-Protocol` 的**服务端选择**语义（真实服务端回该头之后 `ws.protocol` 是否更新） | accept 日志服务端不回 `Sec-WebSocket-Protocol` 头，只测了"请求了子协议但服务端未同意"这一种情形（§5.2 #28） |
| 4 | 二进制帧保真：mock 与透传路径下的 `Blob` / `ArrayBuffer` / `TypedArray`（含分片、`binaryType='arraybuffer'` 时的类型） | 本次只用文本帧（aria2 JSON-RPC 本身也是文本），二进制未测 |
| 5 | `bufferedAmount` 的真实语义（发送积压、随 `send()` 增减） | 只测了初始值 `0`（§5.2 #25） |
| 6 | `permessage-deflate` 扩展协商下的行为 | accept 日志服务端不做扩展协商，`extensions` 只测了初始值 `""` |
| 7 | 甲与本项目另外两个拦截器（`fetch` / `XMLHttpRequest`）共存时的行为，以及 `@mswjs/interceptors/presets/browser`、`BatchInterceptor` 路径 | 本轮刻意只隔离测 WebSocket 单点，避免多个 patch 互相掩盖 |
| 8 | 页面自身也 patch 了 `window.WebSocket`（或另一个扩展先 patch）时的叠加/竞争行为 | 未构造该场景。已知相关实测：甲第二个拦截器实例 `apply()` 直接抛 `already replaced`（§5.1 #11），乙会静默再包一层 |
| 9 | 长时间运行 / 大量连接下的内存增长与句柄泄漏 | 每格只跑 ~20 条连接、单次 ~15 s，未做长跑 |
| 10 | **由服务端发起**的 close（页面被动收到 close 帧）在甲乙下的 code/reason/`wasClean` 保真 | §6.6 的 1200 ms 用例是**页面发起** `close()` 后等服务端应答；服务端主动 close 未测 |
| 11 | msw 的 mock socket 在 `close()` 之后是否与真实 socket 完全解耦（例如 mock 已 CLOSED 后真实帧仍到达） | 未构造该时序 |
| 12 | 乙 mock 且无真连接时 `context.sendToServer()` 的行为 | 未测（本项目只需服务端→客户端推送方向） |
| 13 | Firefox / Safari 上的表现 | 题目只要求 Chromium；两库都可能依赖 Chromium 特有行为，未跨引擎测 |
| 14 | CSP 违规上报（`report-to` / `report-uri`）路径下的观测差异 | 未配置上报端点 |
| 15 | 两库的 commit SHA | **不可得**，不是未测：`npm view <pkg>@<ver> gitHead` 对两者都无输出（§0.1） |

过程透明性说明：第一版探针在循环里用 `var` 声明事件数组，导致**上一个用例的 socket 事件串进下一个用例**（表现为 `'ws://'` 一格出现两组 `error/close`）。该 bug 已修（改块级作用域 + `event.target === socket` 过滤 + 用完即摘监听器），§6 全部数据是修好后重跑的；修好前后**结论性差异**只有一处：乙在 `'ws://…/jsonrpc#frag'` 上原先看似"open + error + close"，实际是串台，真实行为是"不抛错并静默 mock 成功"（§6.1 第 3 行）。

## 8 复现步骤

全部在 `/tmp/aria2-probe/E-ws/` 下，绝对路径：

```bash
# 0) 目录与依赖（/tmp 被重置后照此重建；浏览器二进制走共享缓存 ~/.cache/ms-playwright）
mkdir -p /tmp/aria2-probe/E-ws && cd /tmp/aria2-probe/E-ws
npm i playwright@1.60.0 esbuild @mswjs/interceptors @rxliuli/vista
npx playwright install chromium          # 若共享缓存已有 chromium-1223 可跳过

# 1) 打 IIFE bundle（4 份：甲/乙 × MAIN/ISOLATED）
npx esbuild src/entry-msw.js   --bundle --format=iife --platform=browser --target=chrome120 --legal-comments=none --outfile=ext/msw-main/hook.js
npx esbuild src/entry-msw.js   --bundle --format=iife --platform=browser --target=chrome120 --legal-comments=none --outfile=ext/msw-iso/hook.js
npx esbuild src/entry-vista.js --bundle --format=iife --platform=browser --target=chrome120 --legal-comments=none --outfile=ext/vista-main/hook.js
npx esbuild src/entry-vista.js --bundle --format=iife --platform=browser --target=chrome120 --legal-comments=none --outfile=ext/vista-iso/hook.js

# 2) 一把跑完 8 格（host 8791 + accept 日志服务端 8792 由 run.js 内部拉起）
xvfb-run -a node run.js
#    单格： xvfb-run -a node run.js msw-main-open
#    结果： out/<cell>.json

# 3) 看某格结果
node -e "const {cells,get}=require('/tmp/aria2-probe/E-ws/extract.js'); console.log(JSON.stringify(get('msw-main-open','inst.descriptors'),null,1))"
```

文件清单：`src/entry-msw.js`、`src/entry-vista.js`（两个 hook）、`ext/<cell>/{manifest.json,hook.js}`（4 个扩展）、`server.js`（CSP 宿主 + accept 日志服务端）、`page/probe.js`（唯一探针，三列同跑）、`run.js`（Playwright 驱动，逐格独立 profile）、`extract.js`（结果读取助手）、`out/*.json`（原始输出）。

## 9 原始输出

下面按 cell 列出**探针全部 75 项结果**（`id => value`）。说明：
- 3 个 `-open` 格（原生 / 甲 / 乙）是 §5、§6 的取值来源，**除 3 个超大项外全量列出**；
- 5 个 `-strict` 格只列 §3 用到的子集（其余探针项与 `-open` 格同类，避免重复上百 KB）；
- 3 个超大项（`inst.descriptors`、`ctor.staticConsts`、`ctor.protoConsts`）已在 §5.3/§5.4 逐字段抄录，此处标注省略；
- `console` 是页面 console 原文（截断 160 字符），`acceptEvents` 是 accept 日志服务端的 request-line 原文；
- 下表是**最后一轮**运行的原始输出；`@N` 毫秒数为单次采样（见 §4.1 的抖动说明）。

```text
### native-strict   [ext=none, page=/strict.html, chromium 148.0.7778.96, tcpAccepts=0, upgrades=0, serverTextFrames=0]
domMarker => null
acceptEvents(requestLine) => []
console => ["error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-8SDdPw","error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-00rWOP","error:Failed to load resource: the server responded with a status of 404 (Not Found)","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://127.0.0.1:8792/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not expl","error:WebSocket connection to 'ws://127.0.0.1:8791/not%20a%20url' failed: Error during WebSocket handshake: Unexpected response code: 404","error:Connecting to 'ws://example.com/' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not explicitly set","error:WebSocket connection to 'ws://127.0.0.1:8791/strict.html' failed: Error during WebSocket handshake: Unexpected response code: 200","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:WebSocket is already in CLOSING or CLOSED state.","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","warning:The provided value 'bogus' is not a valid enum value of type BinaryType.","error:Connecting to 'ws://127.0.0.1:8792/open?case=A' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:Connecting to 'ws://127.0.0.1:8792/open?case=B' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:Connecting to 'ws://127.0.0.1:8792/open?case=C' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:WebSocket is already in CLOSING or CLOSED state.","error:Connecting to 'ws://127.0.0.1:8792/slowclose' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ex"]
pageErrors => []
env.href => "http://127.0.0.1:8791/strict.html"
env.hook => null
env.nativeCapturedByHook => false
env.domMarkerAtProbeStart => null
csp.inlineScriptRan_window___INLINE_RAN => false
csp.inlineScriptRan_window___INLINE_RAN_2 => false
csp.probeJsRan => true
csp.securitypolicyviolationEvents => <19 events; #1 = {"blockedURI":"inline","violatedDirective":"script-src-elem","effectiveDirective":"script-src-elem","sourceFile":"http://127.0.0.1:8791/strict.html","lineNumber":11}>
ctor.globalIsNativeIdentity => true
ctor.name => "WebSocket"
ctor.staticConsts => <full value transcribed in the §5 table>
ctor.protoConsts => <full value transcribed in the §5 table>
global.windowOwnDescriptor => {"kind":"data","writable":true,"enumerable":false,"configurable":true,"hasGet":false,"hasSet":false}
global.ObjectKeysWindow_includes_WebSocket => false
global.ObjectKeysWindow_length => 238
global.probeGlobalsVisible => []
inst.Object.prototype.toString => "[object WebSocket]"
inst.instanceof_NativeWS => true
inst.instanceof_currentGlobalWS => true
inst.descriptors => <full value transcribed in the §5 table>
mock.nonexistentHost.roundTrip => {"opens":0,"errors":1,"closes":0,"msgs":0,"ver":false,"push":false,"rs350":3,"timeline":["constructed readyState=3@0","error@0"]}
mock.livePort.zeroAcceptsEvidence => {"opens":0,"errors":1,"rs300":3,"delta":0,"deltaUp":0}
hookStats => null
hook.doubleApply => null
hook.contextSurface => null
(subset: this cell ran on /strict.html for the §3 deployment check; items not listed here are the same probes as in the open-page cells.)

### msw-main-strict   [ext=msw-main, page=/strict.html, chromium 148.0.7778.96, tcpAccepts=0, upgrades=0, serverTextFrames=0]
domMarker => "{\"lib\":\"msw\",\"world\":\"MAIN\",\"patched\":true}"
acceptEvents(requestLine) => []
console => ["error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-8SDdPw","error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-00rWOP","error:Failed to load resource: the server responded with a status of 404 (Not Found)","error:WebSocket connection to 'ws://127.0.0.1:8791/not%20a%20url' failed: Error during WebSocket handshake: Unexpected response code: 404","error:Connecting to 'ws://example.com/' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not explicitly set","error:WebSocket connection to 'ws://127.0.0.1:8791/strict.html' failed: Error during WebSocket handshake: Unexpected response code: 200","error:Connecting to 'ws://127.0.0.1:8792/open?case=A' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:Connecting to 'ws://127.0.0.1:8792/open?case=B' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:Connecting to 'ws://127.0.0.1:8792/open?case=C' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:Connecting to 'ws://127.0.0.1:8792/slowclose' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ex"]
pageErrors => []
env.href => "http://127.0.0.1:8791/strict.html"
env.hook => {"lib":"msw","applied":true,"readyState":"ACTIVE","patched":true}
env.nativeCapturedByHook => false
env.domMarkerAtProbeStart => "{\"lib\":\"msw\",\"world\":\"MAIN\",\"patched\":true}"
csp.inlineScriptRan_window___INLINE_RAN => false
csp.inlineScriptRan_window___INLINE_RAN_2 => false
csp.probeJsRan => true
csp.securitypolicyviolationEvents => <7 events; #1 = {"blockedURI":"inline","violatedDirective":"script-src-elem","effectiveDirective":"script-src-elem","sourceFile":"http://127.0.0.1:8791/strict.html","lineNumber":6}>
ctor.globalIsNativeIdentity => false
ctor.name => "WebSocket"
ctor.staticConsts => <full value transcribed in the §5 table>
ctor.protoConsts => <full value transcribed in the §5 table>
global.windowOwnDescriptor => {"kind":"data","writable":true,"enumerable":true,"configurable":true,"hasGet":false,"hasSet":false}
global.ObjectKeysWindow_includes_WebSocket => true
global.ObjectKeysWindow_length => 246
global.probeGlobalsVisible => ["__MSW_INTERCEPTORS_REGISTRY","__E_WS_HOOK","__E_WS_NATIVE","__E_WS_INTERCEPTOR"]
inst.Object.prototype.toString => "[object EventTarget]"
inst.instanceof_NativeWS => false
inst.instanceof_currentGlobalWS => false
inst.descriptors => <full value transcribed in the §5 table>
mock.nonexistentHost.roundTrip => {"opens":1,"errors":0,"closes":0,"msgs":2,"ver":true,"push":true,"rs350":1,"timeline":["constructed readyState=0@0","open@1","open-attr-handler@1","message@61","sent@351","message@351"]}
mock.livePort.zeroAcceptsEvidence => {"opens":1,"errors":0,"rs300":1,"delta":0,"deltaUp":0}
hookStats => {"connectionsSeen":20,"passthroughCount":7,"interceptorError":null}
hook.doubleApply => {"threw":"Failed to replace a global value at \"WebSocket\": already replaced.","name":"Invariant Violation","globalStillPatched":true}
hook.contextSurface => {"eventKeys":["client","server"],"clientOwnNames":["id","socket","transport","url"],"serverOwnNames":["client","createConnection","mockCloseController","realCloseController","transport"],"clientSocketReachable":true,"clientSocketOwnNames":["CLOSED","CLOSING","CONNECTING","OPEN","_onclose","_onerror","_onmessage","_onopen","binaryType","bufferedAmount","extensions","protocol","readyState","url"],"clientSocketCanBeWrapped":true,"serverHasConnect":true}
(subset: this cell ran on /strict.html for the §3 deployment check; items not listed here are the same probes as in the open-page cells.)

### msw-iso-strict   [ext=msw-iso, page=/strict.html, chromium 148.0.7778.96, tcpAccepts=0, upgrades=0, serverTextFrames=0]
domMarker => "{\"lib\":\"msw\",\"world\":\"ISOLATED\",\"patched\":true}"
acceptEvents(requestLine) => []
console => ["error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-8SDdPw","error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-00rWOP","error:Failed to load resource: the server responded with a status of 404 (Not Found)","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://127.0.0.1:8792/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not expl","error:WebSocket connection to 'ws://127.0.0.1:8791/not%20a%20url' failed: Error during WebSocket handshake: Unexpected response code: 404","error:Connecting to 'ws://example.com/' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not explicitly set","error:WebSocket connection to 'ws://127.0.0.1:8791/strict.html' failed: Error during WebSocket handshake: Unexpected response code: 200","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:WebSocket is already in CLOSING or CLOSED state.","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","warning:The provided value 'bogus' is not a valid enum value of type BinaryType.","error:Connecting to 'ws://127.0.0.1:8792/open?case=A' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:Connecting to 'ws://127.0.0.1:8792/open?case=B' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:Connecting to 'ws://127.0.0.1:8792/open?case=C' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:WebSocket is already in CLOSING or CLOSED state.","error:Connecting to 'ws://127.0.0.1:8792/slowclose' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ex"]
pageErrors => []
env.href => "http://127.0.0.1:8791/strict.html"
env.hook => null
env.nativeCapturedByHook => false
env.domMarkerAtProbeStart => "{\"lib\":\"msw\",\"world\":\"ISOLATED\",\"patched\":true}"
csp.inlineScriptRan_window___INLINE_RAN => false
csp.inlineScriptRan_window___INLINE_RAN_2 => false
csp.probeJsRan => true
csp.securitypolicyviolationEvents => <20 events; #1 = {"blockedURI":"inline","violatedDirective":"script-src-elem","effectiveDirective":"script-src-elem","sourceFile":"http://127.0.0.1:8791/strict.html","lineNumber":6}>
ctor.globalIsNativeIdentity => true
ctor.name => "WebSocket"
ctor.staticConsts => <full value transcribed in the §5 table>
ctor.protoConsts => <full value transcribed in the §5 table>
global.windowOwnDescriptor => {"kind":"data","writable":true,"enumerable":false,"configurable":true,"hasGet":false,"hasSet":false}
global.ObjectKeysWindow_includes_WebSocket => false
global.ObjectKeysWindow_length => 238
global.probeGlobalsVisible => []
inst.Object.prototype.toString => "[object WebSocket]"
inst.instanceof_NativeWS => true
inst.instanceof_currentGlobalWS => true
inst.descriptors => <full value transcribed in the §5 table>
mock.nonexistentHost.roundTrip => {"opens":0,"errors":1,"closes":0,"msgs":0,"ver":false,"push":false,"rs350":3,"timeline":["constructed readyState=3@0","error@0"]}
mock.livePort.zeroAcceptsEvidence => {"opens":0,"errors":1,"rs300":3,"delta":0,"deltaUp":0}
hookStats => null
hook.doubleApply => null
hook.contextSurface => null
(subset: this cell ran on /strict.html for the §3 deployment check; items not listed here are the same probes as in the open-page cells.)

### vista-main-strict   [ext=vista-main, page=/strict.html, chromium 148.0.7778.96, tcpAccepts=0, upgrades=0, serverTextFrames=0]
domMarker => "{\"lib\":\"vista\",\"world\":\"MAIN\",\"patched\":true}"
acceptEvents(requestLine) => []
console => ["error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-8SDdPw","error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-00rWOP","error:Failed to load resource: the server responded with a status of 404 (Not Found)","error:WebSocket connection to 'ws://127.0.0.1:8791/not%20a%20url' failed: Error during WebSocket handshake: Unexpected response code: 404","error:Connecting to 'ws://example.com/' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not explicitly set","error:WebSocket connection to 'ws://127.0.0.1:8791/strict.html' failed: Error during WebSocket handshake: Unexpected response code: 200","error:Connecting to 'ws://127.0.0.1:8792/open?case=A' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:Connecting to 'ws://127.0.0.1:8792/open?case=B' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:Connecting to 'ws://127.0.0.1:8792/open?case=C' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:Connecting to 'ws://127.0.0.1:8792/slowclose' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ex"]
pageErrors => []
env.href => "http://127.0.0.1:8791/strict.html"
env.hook => {"lib":"vista","applied":true,"patched":true}
env.nativeCapturedByHook => false
env.domMarkerAtProbeStart => "{\"lib\":\"vista\",\"world\":\"MAIN\",\"patched\":true}"
csp.inlineScriptRan_window___INLINE_RAN => false
csp.inlineScriptRan_window___INLINE_RAN_2 => false
csp.probeJsRan => true
csp.securitypolicyviolationEvents => <6 events; #1 = {"blockedURI":"inline","violatedDirective":"script-src-elem","effectiveDirective":"script-src-elem","sourceFile":"http://127.0.0.1:8791/strict.html","lineNumber":11}>
ctor.globalIsNativeIdentity => false
ctor.name => "CustomWebSocket"
ctor.staticConsts => <full value transcribed in the §5 table>
ctor.protoConsts => <full value transcribed in the §5 table>
global.windowOwnDescriptor => {"kind":"data","writable":true,"enumerable":false,"configurable":true,"hasGet":false,"hasSet":false}
global.ObjectKeysWindow_includes_WebSocket => false
global.ObjectKeysWindow_length => 243
global.probeGlobalsVisible => ["__E_WS_HOOK","__E_WS_NATIVE"]
inst.Object.prototype.toString => "[object EventTarget]"
inst.instanceof_NativeWS => false
inst.instanceof_currentGlobalWS => true
inst.descriptors => <full value transcribed in the §5 table>
mock.nonexistentHost.roundTrip => {"opens":1,"errors":0,"closes":0,"msgs":2,"ver":true,"push":true,"rs350":1,"timeline":["constructed readyState=0@0","open-attr-handler@0","open@0","message@61","message@351","sent@351"]}
mock.livePort.zeroAcceptsEvidence => {"opens":1,"errors":0,"rs300":1,"delta":0,"deltaUp":0}
hookStats => {"connectionsSeen":22,"passthroughCount":8,"interceptorError":null}
hook.doubleApply => {"threw":null,"globalChangedAgain":true,"secondCtorName":"CustomWebSocket","nestedProtoChain":3,"restoredAfterCancel":true}
hook.contextSurface => {"contextKeys":["onClientMessage","onClose","onOpen","onServerMessage","protocols","sendToClient","sendToServer","type","url"],"contextOwnNames":["onClientMessage","onClose","onOpen","onServerMessage","protocols","sendToClient","sendToServer","type","url"],"protoIsPlainObject":true,"hasSocketLike":[],"symbols":[]}
(subset: this cell ran on /strict.html for the §3 deployment check; items not listed here are the same probes as in the open-page cells.)

### vista-iso-strict   [ext=vista-iso, page=/strict.html, chromium 148.0.7778.96, tcpAccepts=0, upgrades=0, serverTextFrames=0]
domMarker => "{\"lib\":\"vista\",\"world\":\"ISOLATED\",\"patched\":true}"
acceptEvents(requestLine) => []
console => ["error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-8SDdPw","error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-00rWOP","error:Failed to load resource: the server responded with a status of 404 (Not Found)","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://127.0.0.1:8792/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not expl","error:WebSocket connection to 'ws://127.0.0.1:8791/not%20a%20url' failed: Error during WebSocket handshake: Unexpected response code: 404","error:Connecting to 'ws://example.com/' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not explicitly set","error:WebSocket connection to 'ws://127.0.0.1:8791/strict.html' failed: Error during WebSocket handshake: Unexpected response code: 200","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:WebSocket is already in CLOSING or CLOSED state.","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","error:Connecting to 'ws://nonexistent.invalid:6800/jsonrpc' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' wa","warning:The provided value 'bogus' is not a valid enum value of type BinaryType.","error:Connecting to 'ws://127.0.0.1:8792/open?case=A' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:Connecting to 'ws://127.0.0.1:8792/open?case=B' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:Connecting to 'ws://127.0.0.1:8792/open?case=C' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ","error:WebSocket is already in CLOSING or CLOSED state.","error:Connecting to 'ws://127.0.0.1:8792/slowclose' violates the following Content Security Policy directive: \"default-src 'self'\". Note that 'connect-src' was not ex"]
pageErrors => []
env.href => "http://127.0.0.1:8791/strict.html"
env.hook => null
env.nativeCapturedByHook => false
env.domMarkerAtProbeStart => "{\"lib\":\"vista\",\"world\":\"ISOLATED\",\"patched\":true}"
csp.inlineScriptRan_window___INLINE_RAN => false
csp.inlineScriptRan_window___INLINE_RAN_2 => false
csp.probeJsRan => true
csp.securitypolicyviolationEvents => <20 events; #1 = {"blockedURI":"inline","violatedDirective":"script-src-elem","effectiveDirective":"script-src-elem","sourceFile":"http://127.0.0.1:8791/strict.html","lineNumber":6}>
ctor.globalIsNativeIdentity => true
ctor.name => "WebSocket"
ctor.staticConsts => <full value transcribed in the §5 table>
ctor.protoConsts => <full value transcribed in the §5 table>
global.windowOwnDescriptor => {"kind":"data","writable":true,"enumerable":false,"configurable":true,"hasGet":false,"hasSet":false}
global.ObjectKeysWindow_includes_WebSocket => false
global.ObjectKeysWindow_length => 238
global.probeGlobalsVisible => []
inst.Object.prototype.toString => "[object WebSocket]"
inst.instanceof_NativeWS => true
inst.instanceof_currentGlobalWS => true
inst.descriptors => <full value transcribed in the §5 table>
mock.nonexistentHost.roundTrip => {"opens":0,"errors":1,"closes":0,"msgs":0,"ver":false,"push":false,"rs350":3,"timeline":["constructed readyState=3@0","error@0"]}
mock.livePort.zeroAcceptsEvidence => {"opens":0,"errors":1,"rs300":3,"delta":0,"deltaUp":0}
hookStats => null
hook.doubleApply => null
hook.contextSurface => null
(subset: this cell ran on /strict.html for the §3 deployment check; items not listed here are the same probes as in the open-page cells.)

### native-open   [ext=none, page=/open.html, chromium 148.0.7778.96, tcpAccepts=5, upgrades=5, serverTextFrames=2]
domMarker => null
acceptEvents(requestLine) => ["GET /jsonrpc HTTP/1.1","GET /open?case=A HTTP/1.1","GET /open?case=B HTTP/1.1","GET /open?case=C HTTP/1.1","GET /slowclose HTTP/1.1"]
console => ["error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-8SDdPw","error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-00rWOP","error:Failed to load resource: the server responded with a status of 404 (Not Found)","error:WebSocket connection to 'ws://nonexistent.invalid:6800/jsonrpc' failed: Error in connection establishment: net::ERR_NAME_NOT_RESOLVED","error:WebSocket connection to 'ws://nonexistent.invalid:6800/jsonrpc' failed: Error in connection establishment: net::ERR_NAME_NOT_RESOLVED","error:WebSocket connection to 'ws://nonexistent.invalid:6800/jsonrpc' failed: Error in connection establishment: net::ERR_NAME_NOT_RESOLVED","error:WebSocket connection to 'ws://nonexistent.invalid:6800/jsonrpc' failed: Error in connection establishment: net::ERR_NAME_NOT_RESOLVED","error:WebSocket connection to 'ws://127.0.0.1:8791/not%20a%20url' failed: Error during WebSocket handshake: Unexpected response code: 404","error:WebSocket connection to 'ws://127.0.0.1:8791/open.html' failed: Error during WebSocket handshake: Unexpected response code: 200","error:WebSocket connection to 'ws://example.com/' failed: Error during WebSocket handshake: Unexpected response code: 200","error:WebSocket connection to 'ws://nonexistent.invalid:6800/jsonrpc' failed: Error in connection establishment: net::ERR_NAME_NOT_RESOLVED","error:WebSocket connection to 'ws://nonexistent.invalid:6800/jsonrpc' failed: Error in connection establishment: net::ERR_NAME_NOT_RESOLVED","error:WebSocket connection to 'ws://nonexistent.invalid:6800/jsonrpc' failed: Error in connection establishment: net::ERR_NAME_NOT_RESOLVED","error:WebSocket connection to 'ws://nonexistent.invalid:6800/jsonrpc' failed: Error in connection establishment: net::ERR_NAME_NOT_RESOLVED","error:WebSocket connection to 'ws://nonexistent.invalid:6800/jsonrpc' failed: Error in connection establishment: net::ERR_NAME_NOT_RESOLVED","warning:WebSocket connection to 'ws://nonexistent.invalid:6800/jsonrpc' failed: WebSocket is closed before the connection is established.","warning:The provided value 'bogus' is not a valid enum value of type BinaryType.","error:WebSocket connection to 'ws://nonexistent.invalid:6800/jsonrpc' failed: Error in connection establishment: net::ERR_NAME_NOT_RESOLVED"]
pageErrors => []
env.href => "http://127.0.0.1:8791/open.html"
env.ua => "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
env.hook => null
env.nativeCapturedByHook => false
env.domMarkerAtProbeStart => null
csp.inlineScriptRan_window___INLINE_RAN => false
csp.inlineScriptRan_window___INLINE_RAN_2 => false
csp.probeJsRan => true
csp.securitypolicyviolationEvents => <1 events; #1 = {"blockedURI":"inline","violatedDirective":"script-src-elem","effectiveDirective":"script-src-elem","sourceFile":"http://127.0.0.1:8791/open.html","lineNumber":11}>
ctor.globalIsNativeIdentity => true
ctor.name => "WebSocket"
ctor.length => 1
ctor.String => "function WebSocket() { [native code] }"
ctor.toStringTag => "[object Function]"
ctor.prototypeIsNativePrototype => true
ctor.ownPropertyNames => ["CLOSED","CLOSING","CONNECTING","OPEN","length","name","prototype"]
ctor.staticConsts => <full value transcribed in the §5 table>
ctor.protoOwnPropertyNames => ["CLOSED","CLOSING","CONNECTING","OPEN","binaryType","bufferedAmount","close","constructor","extensions","onclose","onerror","onmessage","onopen","protocol","readyState","send","url"]
ctor.protoConsts => <full value transcribed in the §5 table>
global.windowOwnDescriptor => {"kind":"data","writable":true,"enumerable":false,"configurable":true,"hasGet":false,"hasSet":false}
global.windowOwnDescriptor_nativeRef => true
global.definePropertyQuirkControl => {"writable":false,"enumerable":true,"configurable":true}
global.definePropertyOnExistingWindowPropControl => {"target":"XMLHttpRequest","before":{"writable":true,"enumerable":false,"configurable":true},"afterSameShapeAsMsw":{"writable":true,"enumerable":true,"configurable":true},"restoreOk":true}
global.ObjectKeysWindow_includes_WebSocket => false
global.ObjectKeysWindow_length => 238
global.probeGlobalsVisible => []
inst.constructThrew => null
inst.Object.prototype.toString => "[object WebSocket]"
inst.instanceof_NativeWS => true
inst.instanceof_currentGlobalWS => true
inst.constructor_name => "WebSocket"
inst.protoOf_constructor_name => "WebSocket"
inst.protoIs_currentGlobalWS.prototype => true
inst.protoChain => ["WebSocket","EventTarget","Object"]
inst.Object.keys => []
inst.Object.getOwnPropertyNames => []
inst.Object.getOwnPropertySymbols => []
inst.readyState_immediatelyAfterConstruct => 0
inst.url => "ws://nonexistent.invalid:6800/jsonrpc"
inst.protocol => ""
inst.extensions => ""
inst.bufferedAmount => 0
inst.binaryType => "blob"
inst.onopen_valueIsNull => true
inst.onopen_typeof => "object"
inst.onmessage_valueIsNull => true
inst.CONNECTING_ownValue => 0
inst.OPEN_ownValue => 1
inst.CLOSING_ownValue => 2
inst.CLOSED_ownValue => 3
inst.onmessage_typeof => "object"
inst.hasOwn_readyState => false
inst.hasOwn_url => false
inst.hasOwn_binaryType => false
inst.hasOwn_onopen => false
inst.hasOwn_CONNECTING => false
inst.descriptors => <full value transcribed in the §5 table>
url.normalization.uppercaseHost => {"url":"ws://nonexistent.invalid:6800/jsonrpc","readyState":0}
protocol.requestedString => {"immediately":"","after250ms":""}
protocol.duplicateInList => {"threw":{"name":"SyntaxError","message":"Failed to construct 'WebSocket': The subprotocol 'dup' is duplicated.","ctor":"DOMException","isDOMException":true,"isError":true,"thrownTypeof":"object"}}
mock.nonexistentHost.roundTrip => {"opens":0,"errors":1,"closes":1,"msgs":0,"ver":false,"push":false,"rs350":3,"timeline":["constructed readyState=0@0","error@61","close@61"]}
mock.livePort.zeroAcceptsEvidence => {"opens":1,"errors":0,"rs300":1,"delta":1,"deltaUp":1}
errorPath.invalidUrlConstructor => [{"url":"not a url","threw":null,"readyStateImmediately":0,"eventsWithin400ms":[{"what":"error","atMs":1},{"what":"close","code":1006,"wasClean":false,"atMs":1}],"readyStateAfter400ms":3},{"url":"http://example.com/","threw":null,"readyStateImmediately":0,"eventsWithin400ms":[],"readyStateAfter400ms":0},{"url":"ws://127.0.0.1:8792/jsonrpc#frag","threw":{"name":"SyntaxError","message":"Failed to construct 'WebSocket': The URL contains a fragment identifier ('frag'). Fragment identifiers are not allowed in WebSocket URLs.","ctor":"DOMException","isDOMException":true,"isError":true,"thrownTypeof":"object"}},{"url":"ws://","threw":{"name":"SyntaxError","message":"Failed to construct 'WebSocket': The URL 'ws://' is invalid.","ctor":"DOMException","isDOMException":true,"isError":true,"thrownTypeof":"object"}},{"url":"","threw":null,"readyStateImmediately":0,"eventsWithin400ms":[{"what":"error","atMs":2},{"what":"close","code":1006,"wasClean":false,"atMs":2}],"readyStateAfter400ms":3}]
errorPath.nonexistentHostDnsFailure => {"url":"ws://nonexistent.invalid:6800/jsonrpc","note":"for native this is a real DNS failure; for the libs this URL is mocked","events":[{"what":"error","isTrusted":true,"atMs":68},{"what":"close","code":1006,"wasClean":false,"isTrusted":true,"atMs":68}],"readyStateAfter1500ms":3}
state.sendWhileConnecting => {"readyStateAtSend":0,"threw":{"name":"InvalidStateError","message":"Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.","ctor":"DOMException","isDOMException":true,"isError":true,"thrownTypeof":"object"},"readyStateImmediatelyAfterSend":0,"readyStateAfter300ms":3,"eventsAfterSend":[{"code":1006,"wasClean":false}]}
state.closeIllegalCode => [{"code":9999,"reasonLen":0,"threw":{"name":"InvalidAccessError","message":"Failed to execute 'close' on 'WebSocket': The close code must be either 1000, or between 3000 and 4999. 9999 is neither.","ctor":"DOMException","isDOMException":true,"isError":true,"thrownTypeof":"object"},"readyStateImmediately":0,"readyStateAfter200ms":3,"closeEvents":[{"code":1006,"reason":"","wasClean":false}]},{"code":1005,"reasonLen":0,"threw":{"name":"InvalidAccessError","message":"Failed to execute 'close' on 'WebSocket': The close code must be either 1000, or between 3000 and 4999. 1005 is neither.","ctor":"DOMException","isDOMException":true,"isError":true,"thrownTypeof":"object"},"readyStateImmediately":0,"readyStateAfter200ms":3,"closeEvents":[{"code":1006,"reason":"","wasClean":false}]},{"code":1000,"reasonLen":200,"threw":{"name":"SyntaxError","message":"Failed to execute 'close' on 'WebSocket': The close reason must not be greater than 123 UTF-8 bytes.","ctor":"DOMException","isDOMException":true,"isError":true,"thrownTypeof":"object"},"readyStateImmediately":0,"readyStateAfter200ms":3,"closeEvents":[{"code":1006,"reason":"","wasClean":false}]},{"code":3000,"reasonLen":2,"threw":null,"readyStateImmediately":2,"readyStateAfter200ms":3,"closeEvents":[{"code":1006,"reason":"","wasClean":false}]}]
state.binaryTypeValidation => {"initial":"blob","afterArraybuffer":"arraybuffer","afterBogus":"arraybuffer","afterBlob":"blob"}
realConnection.orderAndPassthrough => {"url":"ws://127.0.0.1:8792/open","orderA_attributeFirst":["onopen-attr","addEventListener"],"orderB_listenerFirst":["addEventListener","onopen-attr"],"passthroughGotRealServerMessage":"real-server-hello","readyStateAfterMessage":1,"passthroughSendOk":true,"passthroughClientToServerEcho":"echo:client-to-real-server","closeEventWithin1500ms":true,"lifecycleOrder":["open:true","message:true","message:true","close:true"],"lifecycleEvents":[{"type":"open","origin":"<no origin prop>","isTrusted":true,"ctor":"Event","targetIsSocket":true,"currentTargetIsSocket":true,"isEvent":true,"isMessageEvent":false,"isCloseEvent":false,"atMs":12},{"type":"message","origin":"ws://127.0.0.1:8792","isTrusted":true,"ctor":"MessageEvent","targetIsSocket":true,"currentTargetIsSocket":true,"isEvent":true,"isMessageEvent":true,"isCloseEvent":false,"atMs":27,"data":"real-server-hello"},{"type":"message","origin":"ws://127.0.0.1:8792","isTrusted":true,"ctor":"MessageEvent","targetIsSocket":true,"currentTargetIsSocket":true,"isEvent":true,"isMessageEvent":true,"isCloseEvent":false,"atMs":28,"data":"echo:client-to-real-server"},{"type":"close","origin":"<no origin prop>","isTrusted":true,"ctor":"CloseEvent","targetIsSocket":true,"currentTargetIsSocket":true,"isEvent":true,"isMessageEvent":false,"isCloseEvent":true,"atMs":40,"code":1000,"wasClean":true}],"readyStateAtEnd":3,"accepts":{"before":{"tcpAccepts":1,"upgradeRequests":1},"after":{"tcpAccepts":4,"upgradeRequests":4},"deltaTcpAccepts":3}}
close.waitForServerHandshake => {"url":"ws://127.0.0.1:8792/slowclose","note":"server delays its close reply by 1200ms","opened":true,"closeCallThrew":null,"readyStateImmediatelyAfterClose":2,"msFromCloseCallToCloseEvent":1201,"closeEventWithin300ms":false,"readyStateAtEnd":3}
mockedPath.isTrusted => {"open":[],"message":[],"note":"native has no mocked path; the native column records real events only"}
hookStats => null
hook.doubleApply => null
hook.contextSurface => null
global.mutability => {"ReflectSet_returned":true,"valueAfterReflectSet":"123 (write succeeded)","restoredAfterReflectSet":true,"strictAssign_threw":null,"valueAfterStrictAssign":"456 (write succeeded)","restoredAfterStrictAssign":true,"delete_returned":true,"afterDelete_typeof":"undefined","afterDelete_isNativeSerialized":"window.WebSocket === undefined (hook removed by one delete)","restoredAfterDelete":true}
DONE => true

### msw-main-open   [ext=msw-main, page=/open.html, chromium 148.0.7778.96, tcpAccepts=4, upgrades=4, serverTextFrames=1]
domMarker => "{\"lib\":\"msw\",\"world\":\"MAIN\",\"patched\":true}"
acceptEvents(requestLine) => ["GET /open?case=A HTTP/1.1","GET /open?case=B HTTP/1.1","GET /open?case=C HTTP/1.1","GET /slowclose HTTP/1.1"]
console => ["error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-8SDdPw","error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-00rWOP","error:Failed to load resource: the server responded with a status of 404 (Not Found)","error:WebSocket connection to 'ws://127.0.0.1:8791/not%20a%20url' failed: Error during WebSocket handshake: Unexpected response code: 404","error:WebSocket connection to 'ws://127.0.0.1:8791/open.html' failed: Error during WebSocket handshake: Unexpected response code: 200","error:WebSocket connection to 'ws://example.com/' failed: Error during WebSocket handshake: Unexpected response code: 200"]
pageErrors => []
env.href => "http://127.0.0.1:8791/open.html"
env.ua => "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
env.hook => {"lib":"msw","applied":true,"readyState":"ACTIVE","patched":true}
env.nativeCapturedByHook => false
env.domMarkerAtProbeStart => "{\"lib\":\"msw\",\"world\":\"MAIN\",\"patched\":true}"
csp.inlineScriptRan_window___INLINE_RAN => false
csp.inlineScriptRan_window___INLINE_RAN_2 => false
csp.probeJsRan => true
csp.securitypolicyviolationEvents => <2 events; #1 = {"blockedURI":"inline","violatedDirective":"script-src-elem","effectiveDirective":"script-src-elem","sourceFile":"http://127.0.0.1:8791/open.html","lineNumber":6}>
ctor.globalIsNativeIdentity => false
ctor.name => "WebSocket"
ctor.length => 1
ctor.String => "function () { [native code] }"
ctor.toStringTag => "[object Function]"
ctor.prototypeIsNativePrototype => true
ctor.ownPropertyNames => ["CLOSED","CLOSING","CONNECTING","OPEN","length","name","prototype"]
ctor.staticConsts => <full value transcribed in the §5 table>
ctor.protoOwnPropertyNames => ["CLOSED","CLOSING","CONNECTING","OPEN","binaryType","bufferedAmount","close","constructor","extensions","onclose","onerror","onmessage","onopen","protocol","readyState","send","url"]
ctor.protoConsts => <full value transcribed in the §5 table>
global.windowOwnDescriptor => {"kind":"data","writable":true,"enumerable":true,"configurable":true,"hasGet":false,"hasSet":false}
global.windowOwnDescriptor_nativeRef => true
global.definePropertyQuirkControl => {"writable":false,"enumerable":true,"configurable":true}
global.definePropertyOnExistingWindowPropControl => {"target":"XMLHttpRequest","before":{"writable":true,"enumerable":false,"configurable":true},"afterSameShapeAsMsw":{"writable":true,"enumerable":true,"configurable":true},"restoreOk":true}
global.ObjectKeysWindow_includes_WebSocket => true
global.ObjectKeysWindow_length => 246
global.probeGlobalsVisible => ["__MSW_INTERCEPTORS_REGISTRY","__E_WS_HOOK","__E_WS_NATIVE","__E_WS_INTERCEPTOR"]
inst.constructThrew => null
inst.Object.prototype.toString => "[object EventTarget]"
inst.instanceof_NativeWS => false
inst.instanceof_currentGlobalWS => false
inst.constructor_name => "WebSocketOverride"
inst.protoOf_constructor_name => "WebSocketOverride"
inst.protoIs_currentGlobalWS.prototype => false
inst.protoChain => ["WebSocketOverride","EventTarget","Object"]
inst.Object.keys => ["CONNECTING","OPEN","CLOSING","CLOSED","_onopen","_onmessage","_onerror","_onclose","url","protocol","extensions","binaryType","readyState","bufferedAmount"]
inst.Object.getOwnPropertyNames => ["CONNECTING","OPEN","CLOSING","CLOSED","_onopen","_onmessage","_onerror","_onclose","url","protocol","extensions","binaryType","readyState","bufferedAmount"]
inst.Object.getOwnPropertySymbols => ["Symbol(kPassthroughPromise)","Symbol(kOnSend)"]
inst.readyState_immediatelyAfterConstruct => 0
inst.url => "ws://nonexistent.invalid:6800/jsonrpc"
inst.protocol => ""
inst.extensions => ""
inst.bufferedAmount => 0
inst.binaryType => "blob"
inst.onopen_valueIsNull => true
inst.onopen_typeof => "object"
inst.onmessage_valueIsNull => true
inst.CONNECTING_ownValue => 0
inst.OPEN_ownValue => 1
inst.CLOSING_ownValue => 2
inst.CLOSED_ownValue => 3
inst.onmessage_typeof => "object"
inst.hasOwn_readyState => true
inst.hasOwn_url => true
inst.hasOwn_binaryType => true
inst.hasOwn_onopen => false
inst.hasOwn_CONNECTING => true
inst.descriptors => <full value transcribed in the §5 table>
url.normalization.uppercaseHost => {"url":"ws://nonexistent.invalid:6800/jsonrpc","readyState":0}
protocol.requestedString => {"immediately":"","after250ms":"aria2"}
protocol.duplicateInList => {"threw":null,"protocol":""}
mock.nonexistentHost.roundTrip => {"opens":1,"errors":0,"closes":0,"msgs":2,"ver":true,"push":true,"rs350":1,"timeline":["constructed readyState=0@0","open@1","open-attr-handler@1","message@61","sent@351","message@351"]}
mock.livePort.zeroAcceptsEvidence => {"opens":1,"errors":0,"rs300":1,"delta":0,"deltaUp":0}
errorPath.invalidUrlConstructor => [{"url":"not a url","threw":null,"readyStateImmediately":0,"eventsWithin400ms":[{"what":"open","atMs":1},{"what":"error","atMs":2},{"what":"close","code":1006,"wasClean":true,"atMs":3}],"readyStateAfter400ms":3},{"url":"http://example.com/","threw":null,"readyStateImmediately":0,"eventsWithin400ms":[{"what":"open","atMs":0}],"readyStateAfter400ms":1},{"url":"ws://127.0.0.1:8792/jsonrpc#frag","threw":{"name":"SyntaxError","message":"Failed to construct 'WebSocket': The URL contains a fragment identifier ('#frag'). Fragment identifiers are not allowed in WebSocket URLs.","ctor":"SyntaxError","isDOMException":false,"isError":true,"thrownTypeof":"object"}},{"url":"ws://","threw":{"name":"TypeError","message":"Failed to construct 'URL': Invalid URL","ctor":"TypeError","isDOMException":false,"isError":true,"thrownTypeof":"object"}},{"url":"","threw":null,"readyStateImmediately":0,"eventsWithin400ms":[{"what":"open","atMs":0},{"what":"error","atMs":3},{"what":"close","code":1006,"wasClean":true,"atMs":3}],"readyStateAfter400ms":3}]
errorPath.nonexistentHostDnsFailure => {"url":"ws://nonexistent.invalid:6800/jsonrpc","note":"for native this is a real DNS failure; for the libs this URL is mocked","events":[{"what":"open","atMs":0}],"readyStateAfter1500ms":1}
state.sendWhileConnecting => {"readyStateAtSend":0,"threw":{"name":"Error","message":"InvalidStateError","ctor":"DOMException","isDOMException":true,"isError":true,"thrownTypeof":"object"},"readyStateImmediatelyAfterSend":2,"readyStateAfter300ms":3,"eventsAfterSend":[{"code":1000,"wasClean":true}]}
state.closeIllegalCode => [{"code":9999,"reasonLen":0,"threw":{"name":"Invariant Violation","message":"InvalidAccessError: close code out of user configurable range","ctor":"InvariantError","isDOMException":false,"isError":true,"thrownTypeof":"object"},"readyStateImmediately":0,"readyStateAfter200ms":1,"closeEvents":[]},{"code":1005,"reasonLen":0,"threw":{"name":"Invariant Violation","message":"InvalidAccessError: close code out of user configurable range","ctor":"InvariantError","isDOMException":false,"isError":true,"thrownTypeof":"object"},"readyStateImmediately":0,"readyStateAfter200ms":1,"closeEvents":[]},{"code":1000,"reasonLen":200,"threw":null,"readyStateImmediately":2,"readyStateAfter200ms":3,"closeEvents":[{"code":1000,"reason":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","wasClean":true}]},{"code":3000,"reasonLen":2,"threw":null,"readyStateImmediately":2,"readyStateAfter200ms":3,"closeEvents":[{"code":3000,"reason":"ok","wasClean":true}]}]
state.binaryTypeValidation => {"initial":"blob","afterArraybuffer":"arraybuffer","afterBogus":"bogus","afterBlob":"blob"}
realConnection.orderAndPassthrough => {"url":"ws://127.0.0.1:8792/open","orderA_attributeFirst":["onopen-attr","addEventListener"],"orderB_listenerFirst":["addEventListener","onopen-attr"],"passthroughGotRealServerMessage":"real-server-hello","readyStateAfterMessage":1,"passthroughSendOk":true,"passthroughClientToServerEcho":"echo:client-to-real-server","closeEventWithin1500ms":true,"lifecycleOrder":["open:false","message:false","message:false","close:false"],"lifecycleEvents":[{"type":"open","origin":"<no origin prop>","isTrusted":false,"ctor":"Event","targetIsSocket":true,"currentTargetIsSocket":true,"isEvent":true,"isMessageEvent":false,"isCloseEvent":false,"atMs":0},{"type":"message","origin":"ws://127.0.0.1:8792","isTrusted":false,"ctor":"MessageEvent","targetIsSocket":true,"currentTargetIsSocket":true,"isEvent":true,"isMessageEvent":true,"isCloseEvent":false,"atMs":40,"data":"real-server-hello"},{"type":"message","origin":"ws://127.0.0.1:8792","isTrusted":false,"ctor":"MessageEvent","targetIsSocket":true,"currentTargetIsSocket":true,"isEvent":true,"isMessageEvent":true,"isCloseEvent":false,"atMs":40,"data":"echo:client-to-real-server"},{"type":"close","origin":"<no origin prop>","isTrusted":false,"ctor":"CloseEvent","targetIsSocket":true,"currentTargetIsSocket":true,"isEvent":true,"isMessageEvent":false,"isCloseEvent":false,"atMs":40,"code":1000,"wasClean":true}],"readyStateAtEnd":3,"accepts":{"before":{"tcpAccepts":0,"upgradeRequests":0},"after":{"tcpAccepts":3,"upgradeRequests":3},"deltaTcpAccepts":3}}
close.waitForServerHandshake => {"url":"ws://127.0.0.1:8792/slowclose","note":"server delays its close reply by 1200ms","opened":true,"closeCallThrew":null,"readyStateImmediatelyAfterClose":2,"msFromCloseCallToCloseEvent":0,"closeEventWithin300ms":true,"readyStateAtEnd":3}
mockedPath.isTrusted => {"open":[false],"message":[false,false],"note":"native has no mocked path; the native column records real events only"}
hookStats => {"connectionsSeen":20,"passthroughCount":7,"interceptorError":null}
hook.doubleApply => {"threw":"Failed to replace a global value at \"WebSocket\": already replaced.","name":"Invariant Violation","globalStillPatched":true}
hook.contextSurface => {"eventKeys":["client","server"],"clientOwnNames":["id","socket","transport","url"],"serverOwnNames":["client","createConnection","mockCloseController","realCloseController","transport"],"clientSocketReachable":true,"clientSocketOwnNames":["CLOSED","CLOSING","CONNECTING","OPEN","_onclose","_onerror","_onmessage","_onopen","binaryType","bufferedAmount","extensions","protocol","readyState","url"],"clientSocketCanBeWrapped":true,"serverHasConnect":true}
global.mutability => {"ReflectSet_returned":true,"valueAfterReflectSet":"123 (write succeeded)","restoredAfterReflectSet":true,"strictAssign_threw":null,"valueAfterStrictAssign":"456 (write succeeded)","restoredAfterStrictAssign":true,"delete_returned":true,"afterDelete_typeof":"undefined","afterDelete_isNativeSerialized":"window.WebSocket === undefined (hook removed by one delete)","restoredAfterDelete":true}
DONE => true

### vista-main-open   [ext=vista-main, page=/open.html, chromium 148.0.7778.96, tcpAccepts=4, upgrades=4, serverTextFrames=1]
domMarker => "{\"lib\":\"vista\",\"world\":\"MAIN\",\"patched\":true}"
acceptEvents(requestLine) => ["GET /open?case=A HTTP/1.1","GET /open?case=B HTTP/1.1","GET /open?case=C HTTP/1.1","GET /slowclose HTTP/1.1"]
console => ["error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-8SDdPw","error:Executing inline script violates the following Content Security Policy directive 'script-src 'self''. Either the 'unsafe-inline' keyword, a hash ('sha256-00rWOP","error:Failed to load resource: the server responded with a status of 404 (Not Found)","error:WebSocket connection to 'ws://127.0.0.1:8791/not%20a%20url' failed: Error during WebSocket handshake: Unexpected response code: 404","error:WebSocket connection to 'ws://example.com/' failed: Error during WebSocket handshake: Unexpected response code: 200","error:WebSocket connection to 'ws://127.0.0.1:8791/open.html' failed: Error during WebSocket handshake: Unexpected response code: 200"]
pageErrors => []
env.href => "http://127.0.0.1:8791/open.html"
env.ua => "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
env.hook => {"lib":"vista","applied":true,"patched":true}
env.nativeCapturedByHook => false
env.domMarkerAtProbeStart => "{\"lib\":\"vista\",\"world\":\"MAIN\",\"patched\":true}"
csp.inlineScriptRan_window___INLINE_RAN => false
csp.inlineScriptRan_window___INLINE_RAN_2 => false
csp.probeJsRan => true
csp.securitypolicyviolationEvents => <2 events; #1 = {"blockedURI":"inline","violatedDirective":"script-src-elem","effectiveDirective":"script-src-elem","sourceFile":"http://127.0.0.1:8791/open.html","lineNumber":6}>
ctor.globalIsNativeIdentity => false
ctor.name => "CustomWebSocket"
ctor.length => 2
ctor.String => "class CustomWebSocket extends EventTarget {\n          static CONNECTING = 0;\n          static OPEN = 1;\n          static CLOSING = 2;\n          static CLOSED = 3;\n          CONNECTING = 0;\n          OPEN = 1;\n          C"
ctor.toStringTag => "[object Function]"
ctor.prototypeIsNativePrototype => false
ctor.ownPropertyNames => ["CLOSED","CLOSING","CONNECTING","OPEN","length","name","prototype"]
ctor.staticConsts => <full value transcribed in the §5 table>
ctor.protoOwnPropertyNames => ["binaryType","bufferedAmount","close","constructor","extensions","onclose","onerror","onmessage","onopen","protocol","readyState","send","url"]
ctor.protoConsts => <full value transcribed in the §5 table>
global.windowOwnDescriptor => {"kind":"data","writable":true,"enumerable":false,"configurable":true,"hasGet":false,"hasSet":false}
global.windowOwnDescriptor_nativeRef => true
global.definePropertyQuirkControl => {"writable":false,"enumerable":true,"configurable":true}
global.definePropertyOnExistingWindowPropControl => {"target":"XMLHttpRequest","before":{"writable":true,"enumerable":false,"configurable":true},"afterSameShapeAsMsw":{"writable":true,"enumerable":true,"configurable":true},"restoreOk":true}
global.ObjectKeysWindow_includes_WebSocket => false
global.ObjectKeysWindow_length => 243
global.probeGlobalsVisible => ["__E_WS_HOOK","__E_WS_NATIVE"]
inst.constructThrew => null
inst.Object.prototype.toString => "[object EventTarget]"
inst.instanceof_NativeWS => false
inst.instanceof_currentGlobalWS => true
inst.constructor_name => "CustomWebSocket"
inst.protoOf_constructor_name => "CustomWebSocket"
inst.protoIs_currentGlobalWS.prototype => true
inst.protoChain => ["CustomWebSocket","EventTarget","Object"]
inst.Object.keys => ["CONNECTING","OPEN","CLOSING","CLOSED"]
inst.Object.getOwnPropertyNames => ["CONNECTING","OPEN","CLOSING","CLOSED"]
inst.Object.getOwnPropertySymbols => []
inst.readyState_immediatelyAfterConstruct => 0
inst.url => "ws://nonexistent.invalid:6800/jsonrpc"
inst.protocol => ""
inst.extensions => ""
inst.bufferedAmount => 0
inst.binaryType => "blob"
inst.onopen_valueIsNull => true
inst.onopen_typeof => "object"
inst.onmessage_valueIsNull => true
inst.CONNECTING_ownValue => 0
inst.OPEN_ownValue => 1
inst.CLOSING_ownValue => 2
inst.CLOSED_ownValue => 3
inst.onmessage_typeof => "object"
inst.hasOwn_readyState => false
inst.hasOwn_url => false
inst.hasOwn_binaryType => false
inst.hasOwn_onopen => false
inst.hasOwn_CONNECTING => true
inst.descriptors => <full value transcribed in the §5 table>
url.normalization.uppercaseHost => {"url":"WS://Nonexistent.INVALID:6800/jsonrpc","readyState":0}
protocol.requestedString => {"immediately":"","after250ms":""}
protocol.duplicateInList => {"threw":null,"protocol":""}
mock.nonexistentHost.roundTrip => {"opens":1,"errors":0,"closes":0,"msgs":2,"ver":true,"push":true,"rs350":1,"timeline":["constructed readyState=0@0","open-attr-handler@0","open@0","message@60","message@351","sent@351"]}
mock.livePort.zeroAcceptsEvidence => {"opens":1,"errors":0,"rs300":1,"delta":0,"deltaUp":0}
errorPath.invalidUrlConstructor => [{"url":"not a url","threw":null,"readyStateImmediately":0,"eventsWithin400ms":[{"what":"error","atMs":2},{"what":"close","code":1006,"wasClean":false,"atMs":2}],"readyStateAfter400ms":3},{"url":"http://example.com/","threw":null,"readyStateImmediately":0,"eventsWithin400ms":[{"what":"error","atMs":90},{"what":"close","code":1006,"wasClean":false,"atMs":90}],"readyStateAfter400ms":3},{"url":"ws://127.0.0.1:8792/jsonrpc#frag","threw":null,"readyStateImmediately":0,"eventsWithin400ms":[{"what":"open","atMs":0}],"readyStateAfter400ms":1},{"url":"ws://","threw":null,"readyStateImmediately":0,"eventsWithin400ms":[],"readyStateAfter400ms":0},{"url":"","threw":null,"readyStateImmediately":0,"eventsWithin400ms":[{"what":"error","atMs":2},{"what":"close","code":1006,"wasClean":false,"atMs":2}],"readyStateAfter400ms":3}]
errorPath.nonexistentHostDnsFailure => {"url":"ws://nonexistent.invalid:6800/jsonrpc","note":"for native this is a real DNS failure; for the libs this URL is mocked","events":[{"what":"open","atMs":0}],"readyStateAfter1500ms":1}
state.sendWhileConnecting => {"readyStateAtSend":0,"threw":{"name":"InvalidStateError","message":"Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.","ctor":"DOMException","isDOMException":true,"isError":true,"thrownTypeof":"object"},"readyStateImmediatelyAfterSend":0,"readyStateAfter300ms":1,"eventsAfterSend":[{"what":"open"}]}
state.closeIllegalCode => [{"code":9999,"reasonLen":0,"threw":null,"readyStateImmediately":2,"readyStateAfter200ms":1,"closeEvents":[{"code":9999,"reason":"","wasClean":true}]},{"code":1005,"reasonLen":0,"threw":null,"readyStateImmediately":2,"readyStateAfter200ms":1,"closeEvents":[{"code":1005,"reason":"","wasClean":true}]},{"code":1000,"reasonLen":200,"threw":null,"readyStateImmediately":2,"readyStateAfter200ms":1,"closeEvents":[{"code":1000,"reason":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","wasClean":true}]},{"code":3000,"reasonLen":2,"threw":null,"readyStateImmediately":2,"readyStateAfter200ms":1,"closeEvents":[{"code":3000,"reason":"ok","wasClean":true}]}]
state.binaryTypeValidation => {"initial":"blob","afterArraybuffer":"arraybuffer","afterBogus":"bogus","afterBlob":"blob"}
realConnection.orderAndPassthrough => {"url":"ws://127.0.0.1:8792/open","orderA_attributeFirst":["onopen-attr","addEventListener"],"orderB_listenerFirst":["onopen-attr","addEventListener"],"passthroughGotRealServerMessage":"real-server-hello","readyStateAfterMessage":1,"passthroughSendOk":true,"passthroughClientToServerEcho":"echo:client-to-real-server","closeEventWithin1500ms":true,"lifecycleOrder":["open:false","message:false","message:false","close:false"],"lifecycleEvents":[{"type":"open","origin":"<no origin prop>","isTrusted":false,"ctor":"Event","targetIsSocket":true,"currentTargetIsSocket":true,"isEvent":true,"isMessageEvent":false,"isCloseEvent":false,"atMs":11},{"type":"message","origin":"","isTrusted":false,"ctor":"MessageEvent","targetIsSocket":true,"currentTargetIsSocket":true,"isEvent":true,"isMessageEvent":true,"isCloseEvent":false,"atMs":25,"data":"real-server-hello"},{"type":"message","origin":"","isTrusted":false,"ctor":"MessageEvent","targetIsSocket":true,"currentTargetIsSocket":true,"isEvent":true,"isMessageEvent":true,"isCloseEvent":false,"atMs":25,"data":"echo:client-to-real-server"},{"type":"close","origin":"<no origin prop>","isTrusted":false,"ctor":"CloseEvent","targetIsSocket":true,"currentTargetIsSocket":true,"isEvent":true,"isMessageEvent":false,"isCloseEvent":true,"atMs":36,"code":1000,"wasClean":true}],"readyStateAtEnd":3,"accepts":{"before":{"tcpAccepts":0,"upgradeRequests":0},"after":{"tcpAccepts":3,"upgradeRequests":3},"deltaTcpAccepts":3}}
close.waitForServerHandshake => {"url":"ws://127.0.0.1:8792/slowclose","note":"server delays its close reply by 1200ms","opened":true,"closeCallThrew":null,"readyStateImmediatelyAfterClose":2,"msFromCloseCallToCloseEvent":1203,"closeEventWithin300ms":false,"readyStateAtEnd":3}
mockedPath.isTrusted => {"open":[false],"message":[false,false],"note":"native has no mocked path; the native column records real events only"}
hookStats => {"connectionsSeen":22,"passthroughCount":8,"interceptorError":null}
hook.doubleApply => {"threw":null,"globalChangedAgain":true,"secondCtorName":"CustomWebSocket","nestedProtoChain":3,"restoredAfterCancel":true}
hook.contextSurface => {"contextKeys":["onClientMessage","onClose","onOpen","onServerMessage","protocols","sendToClient","sendToServer","type","url"],"contextOwnNames":["onClientMessage","onClose","onOpen","onServerMessage","protocols","sendToClient","sendToServer","type","url"],"protoIsPlainObject":true,"hasSocketLike":[],"symbols":[]}
global.mutability => {"ReflectSet_returned":true,"valueAfterReflectSet":"123 (write succeeded)","restoredAfterReflectSet":true,"strictAssign_threw":null,"valueAfterStrictAssign":"456 (write succeeded)","restoredAfterStrictAssign":true,"delete_returned":true,"afterDelete_typeof":"undefined","afterDelete_isNativeSerialized":"window.WebSocket === undefined (hook removed by one delete)","restoredAfterDelete":true}
DONE => true
```
