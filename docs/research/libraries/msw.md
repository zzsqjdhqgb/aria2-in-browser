# mswjs/msw（Mock Service Worker）调研

> 本文件是「浏览器技术边界测绘」的开源库调研之一，服务于 aria2-in-browser 项目的 R4（转发器）、R5（内置 UI 不得走特殊通道）、R9（拦截在 JS API 层）、R10（伪装还原判据）。
> 目标导向：回答「原理是什么 / 能不能借鉴 / 能不能直接用」，不是使用教程。

---

## 0 元信息

| 项 | 值 |
|---|---|
| 调研日期 | **2026-10-06（UTC）** |
| 被调研对象 A | **msw v3.0.2**，npm latest，仓库 HEAD commit `501a591640648c86b9733167eab7d29339671eec`（2026-10-05），本地 clone 到 `/tmp/msw` 逐文件阅读 |
| 被调研对象 B | **@mswjs/interceptors v0.45.7**，commit `49d7901772d5c07b71d75b7470a2562ef28c3755`（2026-10-04），本地 clone 到 `/tmp/interceptors` 逐文件阅读 |
| 官方文档 | mswjs.io 文档仓库 `mswjs/mswjs.io`，commit `610762537b2d672fc6820ac27ce1c00a1e41a4a3`（2026-10-05），本地 clone 到 `/tmp/docs-site` |
| 平台侧证据 | Service Worker 规范（w3c.github.io/ServiceWorker，2026-10-06 抓取）、Fetch 规范（fetch.spec.whatwg.org，2026-10-06 抓取）、MDN（2026-10-06 抓取）、Chromium 源码 main 分支（2026-10-06 抓取）、Chrome 扩展官方文档（2026-10-06 抓取）、CDP `browser_protocol.json`（2026-10-06 抓取） |
| 证据标注约定 | 【源码】= 我读到的仓库源码（给出 commit 永久链接）；【官方文档】= 官方文档原文；【规范】= W3C/WHATWG 规范原文；【平台文档】= MDN / Chrome / Chromium；【推论】= 由以上证据推出的结论（非原文）；【未验证】= 查不到依据 |
| 注意 | 仓库源码链接一律使用 **commit 永久链接**（`blob/<commit>/...`），避免上游移动 |

---

## 1 它是什么（一句话）

**MSW 是一个「API mocking 库」：让开发者用自己的应用代码声明「哪些请求应该返回什么」，从而在开发/测试/演示时接管应用发出的网络请求。**（【官方文档】docs/index.md："Mock Service Worker (MSW) is an API mocking library for browser and Node.js. It helps you intercept, observe, and affect the network of your application."）

展开四条（都影响「能不能借鉴/能不能用」的判断）：

1. **它是给「应用自己的开发者」用的测试/开发工具，不是给终端用户用的拦截器。** 官方在 limitations.md 里明确自我定位："Mock Service Worker positions itself as a development tool..."。它的典型场景是：单元测试（Vitest/Jest）、集成测试、E2E、Storybook、开发环境无后端联调。
2. **它的核心资产是「一套 handler 声明 + 两条拦截实现路线」。** 同一份 handler 既能在浏览器（Service Worker 路线）跑，也能在 Node（interceptors 路线）跑——这是它宣传的"single source of truth"。
3. **它在浏览器里刻意选择 Service Worker 而不是 patch `fetch`。** 【官方文档】docs/index.md："MSW uses the Service Worker API to intercept actual production requests on the network level. Instead of patching `fetch` and meddling with your application's integrity, MSW bets on the platform..."
4. **它不做网络代理、不做真实服务转发、不是抓包/篡改工具。** 官方把"用浏览器级 HTTP 代理"列在竞品（Cypress）那一栏：【官方文档】docs/comparison.md："Cypress … Uses a browser-wide HTTP proxy to route outgoing requests through the custom server Cypress spawns as a part of its runtime." 对比列里 MSW 是 "Uses a Service Worker to intercept requests on the browser level."

---

## 2 实现原理

### 2.1 全景：v3 的「网络源（network source）」抽象与两条路线

msw v3 把「拦截」抽象成 **网络源（NetworkSource）**，把「决策」抽象成 **handlers**。浏览器入口 `setupWorker()` 的组装代码是理解全局的关键：

```ts
// src/browser/setup-worker.ts
const httpSource = supportsServiceWorker()
  ? await ServiceWorkerSource.from({ serviceWorker: { url: options?.serviceWorker?.url ... } })
  : new FallbackHttpSource({ quiet: options?.quiet })

network.configure({
  sources: [
    httpSource,
    new InterceptorSource({ interceptors: [new WebSocketInterceptor()] }),
  ],
  ...
})
```

【源码】[src/browser/setup-worker.ts#L52-L74](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/setup-worker.ts#L52-L74)

由此得到三条硬事实：

- **浏览器里 HTTP 走 Service Worker 路线**（`ServiceWorkerSource`），**WebSocket 走 JS 层拦截路线**（`InterceptorSource` + `@mswjs/interceptors` 的 `WebSocketInterceptor`）。
- **Service Worker 不可用时（例如 `file:` 协议），HTTP 会退化成 JS 层拦截路线**：`FallbackHttpSource` = `new XMLHttpRequestInterceptor()` + `new FetchInterceptor()`。【源码】[src/browser/sources/fallback-http-source.ts#L1-L15](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/sources/fallback-http-source.ts#L1-L15)
  - 这正是 R5「扩展页注入失败时，只换『装载方式』，不换『路径』」的现成范例：msw 的两条路线上层语义完全相同（同一套 handler / 同一套 frame 解析），只换底层 source。
- 判定分支在 `supportsServiceWorker()`：`navigator` 有 `serviceWorker` 且 `location.protocol !== 'file:'`。【源码】[src/browser/utils/supports.ts#L1-L17](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/utils/supports.ts#L1-L17)

### 2.2 Service Worker 路线（浏览器）

#### 2.2.1 脚本是怎么"装上去"的：**由应用自己托管并提供**

这是 msw 与"扩展给任意站点注入"之间最大的鸿沟，有四层证据：

1. **CLI 把 worker 脚本拷贝到应用自己的 public 目录。** `msw init <PUBLIC_DIR>` 的实现在 `cli/init.js`：`copyWorkerScript()` → `fs.copyFileSync(SERVICE_WORKER_BUILD_PATH, workerDestinationPath)`。【源码】[cli/init.js](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/cli/init.js)、[config/constants.js](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/config/constants.js)
2. **该脚本是构建产物，含版本与校验和占位符**：`src/mockServiceWorker.js` 顶部是 `const PACKAGE_VERSION = '<PACKAGE_VERSION>'`、`const INTEGRITY_CHECKSUM = '<INTEGRITY_CHECKSUM>'`，构建时由 `config/copy-service-worker.ts` 替换（`.replace('<INTEGRITY_CHECKSUM>', checksum).replace('<PACKAGE_VERSION>', packageJson.version)`）。【源码】[config/copy-service-worker.ts#L36-L42](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/config/copy-service-worker.ts#L36-L42)
3. **注册由页面代码调用 `navigator.serviceWorker.register(url, options)` 完成**：`getWorkerInstance()` 先 `navigator.serviceWorker.getRegistrations()` 查找已存在的同 URL 注册，找不到才 `register`。URL 默认 `/mockServiceWorker.js`。【源码】[src/browser/utils/get-worker-instance.ts#L14-L60](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/utils/get-worker-instance.ts#L14-L60)
4. **官方文档把这条约束写成硬要求**：【官方文档】guides/integrations/browser.md —— "If your application registers a Service Worker it must **host and serve it**. The library CLI provides you with the `init` command to quickly copy the `./mockServiceWorker.js` worker script into your application's public directory."

> 衍生结论：**worker 脚本的存在前提是"目标源的服务器上真的有一份脚本"**。找不到脚本时 msw 的报错也直说这一点：`Failed to register a Service Worker for scope ('…') with script ('…'): Service Worker script does not exist at the given path. Did you forget to run "npx msw init <PUBLIC_DIR>"?`【源码】get-worker-instance.ts 同文件。

#### 2.2.2 SW 处在什么位置：它是**网络栈里的一个中间人**，业务逻辑在页面里

- `mockServiceWorker.js` 是一个普通的 Service Worker 脚本，只做四件事：
  1. `install` 时 `self.skipWaiting()`，`activate` 时 `event.waitUntil(self.clients.claim())`（尽快接管已打开的页面）；
  2. 维护 `activeClientIds`（哪些页面在"MOCK_ACTIVATE"状态）；
  3. 在 `fetch` 事件里把请求**序列化后 postMessage 给页面**，等页面回话，再决定 `respondWith(MOCK_RESPONSE)` 还是 `fetch(...)` 放行；
  4. 把响应（含 body 流）回传给页面做事件通知。
  【源码】[src/mockServiceWorker.js](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/mockServiceWorker.js)
- 页面与 SW 之间是 **MessageChannel 双向通道**：SW 侧 `sendToClient()` 用 `client.postMessage(message, [channel.port2, ...transferrables])`，把 `MessagePort` 传给页面；页面侧 `WorkerChannel` 用 `TypedEvent` 承载 `REQUEST / RESPONSE / MOCKING_ENABLED / INTEGRITY_CHECK_RESPONSE / KEEPALIVE_RESPONSE / CLIENT_CLOSED`。【源码】[src/mockServiceWorker.js#L386-L404](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/mockServiceWorker.js#L386-L404)、[src/browser/utils/worker-channel.ts#L1-L120](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/utils/worker-channel.ts#L1-L120)
- **请求处理的决策全部在页面侧**：页面拿到 `REQUEST` 后构造 `ServiceWorkerHttpNetworkFrame`，交给 `executeHandlers()` 逐个跑 handler；命中 → `MOCK_RESPONSE`（带上 `toResponseInit(response)`），未命中 → `PASSTHROUGH`（可带修改后的请求头）。【源码】[service-worker-source.ts#L304-L330（收发 REQUEST/RESPONSE）](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/sources/service-worker-source.ts#L304-L330)、[#L493-L562（passthrough / respondWith）](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/sources/service-worker-source.ts#L493-L562)

**一次请求的完整时序**（【源码】+【规范】）：

| # | 位置 | 发生什么 |
|---|---|---|
| 1 | 页面 | `fetch()` / XHR / `<img>` / 导航等发起请求 |
| 2 | 浏览器网络栈 | 判断该 fetch 是否要派发 fetch 事件：看 `service-workers mode`（默认 `"all"`）与请求类型；SW 侧再看 scope 与客户端是否受控 |
| 3 | SW | `fetch` 监听器：跳过 DevTools 的 `only-if-cached` 请求、跳过无 active client 的情形，然后 `event.respondWith(handleRequest(...))` |
| 4 | SW | `serializeRequest()` 把 `url/mode/method/headers/cache/credentials/destination/integrity/redirect/referrer/keepalive/body(ArrayBuffer)` 发给页面 |
| 5 | 页面 | `deserializeRequest()` → `executeHandlers()`（handler 匹配 + resolver 执行） |
| 6a | 页面 → SW | 命中且返回 mock：`MOCK_RESPONSE`（body 可为 `ReadableStream`，作为 transferable 传递） |
| 6b | 页面 → SW | `passthrough()` / 未命中 / 显式 passthrough：`PASSTHROUGH`（可带页面改写后的请求头） |
| 7 | SW | `new Response(body, responseInit)` 回给浏览器（status 0 → `Response.error()`）；或 `fetch(requestClone, { headers })` 真发网络 |
| 8 | SW → 页面 | 回传响应元信息 + body 流副本，页面发 `response:mocked` / `response:bypass` 生命周期事件 |

#### 2.2.3 为什么它能拦到页面请求

【规范】Service Worker 规范把 fetch 事件当作 **HTTP fetch 的一个必经环节**：

- "The Handle Fetch algorithm is the entry point for the fetch handling handed to the service worker context."（[Service Worker spec §Handle Fetch](https://w3c.github.io/ServiceWorker/)）
- 判定是"按客户端 + scope 前缀匹配"：`Match Service Worker Registration` 用 **URL 字符串前缀匹配**选出最长匹配的 scope："The URL string matching in this step is prefix-based rather than path-structural."，且断言 "matchingScope's origin and clientURL's origin are same origin."
- 子资源请求用 **客户端自己的 active service worker**："Else if request is a subresource request, then: If client's active service worker is non-null, set registration to client's active service worker's containing service worker registration. Else, return null."

【规范】Fetch 规范给出"哪些 fetch 会走到 SW"：

- "A request has an associated service-workers mode, that is `"all"` or `"none"`. Unless stated otherwise it is `"all"`. This determines which service workers will receive a fetch event for this fetch. `"all"`: Relevant service workers will get a fetch event for this fetch."
- §4.4 HTTP fetch：`If request's service-workers mode is "all", then: Let requestForServiceWorker be a clone of request.`（[fetch.spec.whatwg.org](https://fetch.spec.whatwg.org/)）

#### 2.2.4 为什么被它拦下的请求**仍然出现在 DevTools 的 Network 面板**里

这条证据链给出的答案是：**Network 面板记录的是"浏览器网络栈里的请求生命周期"，而 SW 只是这个生命周期里"响应来源"的一种；请求对象在派发 fetch 事件之前就已经存在于网络栈中。**

- 【平台文档】Chrome DevTools Network reference 的 Timing 面板文档里，直接列出了 SW 相关的阶段：
  - "**ServiceWorker Preparation**. The browser is starting up the service worker."
  - "**Request to ServiceWorker**. The request is being sent to the service worker."
  - "**Content Download**. The browser is receiving the response, either directly from the network or from a service worker."
  （[developer.chrome.com/docs/devtools/network/reference](https://developer.chrome.com/docs/devtools/network/reference)）
- 【平台文档】CDP `Network.Response` 结构里带两个 SW 专用字段（原始协议 JSON）：
  - `fromServiceWorker`：**"Specifies that the request was served from the ServiceWorker."**
  - `serviceWorkerResponseSource`：**"Response source of response from ServiceWorker."**（枚举 `cache-storage | http-cache | fallback-code | network`）
  （[ChromeDevTools/devtools-protocol browser_protocol.json](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/browser_protocol.json)，2026-10-06 抓取）
- 【平台文档】CDP `Network.setBypassServiceWorker`：**"Toggles ignoring of service worker for each request."** —— 说明"经过 SW"是网络栈里可开关的一层，而不是网络栈之外的东西。
- 【推论】因此：SW 用 `respondWith()` 短路时，页面的请求**确实没有产生真实的网络往返**，但它在网络栈里的"请求记录"已经存在，DevTools 会照常显示（并带 SW 相关时序/来源标记）。**我未找到官方文档明确写"mocked 响应也会出现在 Network 面板"这句话**，此结论是"CDP 字段 + DevTools 文档 + 规范位置"三者推出的，标注为推论（见 §8）。

### 2.3 `@mswjs/interceptors` 的 JS 层拦截路线

#### 2.3.1 浏览器：`FetchInterceptor` 与 `XMLHttpRequestInterceptor`

**浏览器 preset** 就是这两个：`export default [new FetchInterceptor(), new XMLHttpRequestInterceptor()]`。【源码】[src/presets/browser.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/presets/browser.ts)

**FetchInterceptor（浏览器）＝ 替换 `globalThis.fetch`**：

```ts
// src/interceptors/fetch/web.ts
this.subscriptions.push(
  patchesRegistry.applyPatch(globalThis, 'fetch', (realFetch) => {
    return async (input, init) => {
      const request = new Request(resolvedInput, init)
      const responsePromise = Promise.withResolvers<Response>()
      const controller = new RequestController(request, {
        passthrough: async () => {
          const requestClone = request.clone()
          const [responseError, originalResponse] = await until(() => realFetch(requestClone))
          ...
        },
        respondWith: async (rawResponse) => { ... responsePromise.resolve(response) ... },
        errorWith: (reason) => { ... responsePromise.reject(reason) },
      }, { logger, requestId })
      await handleRequest({ initiator: request, request, requestId, emitter: this.emitter, controller, logger })
      return responsePromise.promise
    }
  })
)
```

【源码】[src/interceptors/fetch/web.ts#L30-L60](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/fetch/web.ts#L30-L60)、[#L65-L90](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/fetch/web.ts#L65-L90)

要点：
- **拦截点就是全局 `fetch` 本身**；真实 fetch 被保存在闭包 `realFetch` 里。
- 原始请求用 **`request.clone()`** 发出，保证 `request` 事件里传给业务方的实例仍是未被消费的那个，且 request/response 事件里是同一个引用。
- mock 响应时**直接 resolve 一个 `Response` 实例**（`FetchResponse.setUrl(request.url, response)` 把 `response.url` 改成请求 URL，因为构造出来的 Response 没有 URL）。

**XMLHttpRequestInterceptor（浏览器）＝ 用 `Proxy` 替换 `XMLHttpRequest` 构造器**：

```ts
// src/interceptors/XMLHttpRequest/xml-http-request-proxy.ts
const XMLHttpRequestProxy = new Proxy(globalThis.XMLHttpRequest, {
  construct(target, args, newTarget) {
    const originalRequest = Reflect.construct(target, args, newTarget) as XMLHttpRequest
    // Forward prototype descriptors onto the proxied object.
    const prototypeDescriptors = Object.getOwnPropertyDescriptors(target.prototype)
    for (const propertyName in prototypeDescriptors) {
      Reflect.defineProperty(originalRequest, propertyName, prototypeDescriptors[propertyName])
    }
    const xhrRequestController = new XMLHttpRequestController(originalRequest, logger)
    ...
    return xhrRequestController.request   // 再包一层 createProxy 的代理实例
  },
})
```

【源码】[src/interceptors/XMLHttpRequest/xml-http-request-proxy.ts#L19-L47](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/XMLHttpRequest/xml-http-request-proxy.ts#L19-L47)、[src/interceptors/XMLHttpRequest/web.ts#L18-L24](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/XMLHttpRequest/web.ts#L18-L24)

要点：
- **构造器是 `Proxy`，不是子类**：`XMLHttpRequest.name`、`instanceof`、原生原型链都保持；然后把原生原型上的属性描述符**逐条转发**到实例上（应付 JSDOM/浏览器把 `responseType` 之流定义在原型上的实现）。
- 实例本身再被 `createProxy()`（`src/utils/create-proxy.ts`）包一层，用于拦截 `open()` / `send()` / `setRequestHeader()` / `addEventListener()` 等**方法调用**。
- 被拦截的请求**仍会构造真实的 XHR 对象**，只是它的网络行为被接管。

#### 2.3.2 Node：`ClientRequest` / `http` / `fetch` 三张门面 + **socket 层真正的拦截**

这是 msw v3 最反直觉的地方：Node 侧的多张门面 **全部指向同一个 `NodeHttpRequestSource` 单例**，真正的拦截点被下沉到 **`net.Socket.prototype.connect`**。

- `ClientRequestInterceptor` 做的事只有两件：patch 五个入口（`http.ClientRequest`、`http.get`、`http.request`、`https.get`、`https.request`）把调用放进 `runInRequestContext()`（`AsyncLocalStorage`，用于归因"这个 socket 是哪个 client 发起的"），然后订阅共享的 `NodeHttpRequestSource`。

  ```ts
  // src/interceptors/ClientRequest/index.ts
  patchesRegistry.applyPatch(http, 'ClientRequest', (ClientRequest) =>
    new Proxy(ClientRequest, { construct(target, args, newTarget) {
      return runInRequestContext(() => Reflect.construct(target, args, newTarget), requestLogger) } })),
  patchesRegistry.applyPatch(http, 'get', (httpGet) => function mockHttpGet(...args) {
    return runInRequestContext(() => httpGet(...(args as [any, any])), requestLogger) }),
  ...
  ```

  【源码】[src/interceptors/ClientRequest/index.ts#L18-L77](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/ClientRequest/index.ts#L18-L77)
- `HttpRequestInterceptor`（"all HTTP in Node.js"）与 `FetchInterceptor`（Node）同样只是订阅 `NodeHttpRequestSource` 并按 initiator 过滤事件。

  【源码】[src/interceptors/http/index.ts#L1-L34](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/http/index.ts#L1-L34)、[src/interceptors/fetch/node.ts#L9-L64](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/fetch/node.ts#L9-L64)
- 真正的拦截：

  ```ts
  // src/interceptors/net/index.ts —— SocketInterceptor.setup()
  /**
   * @note Intercept connections at the "net.Socket.prototype.connect"
   * level instead of patching the "net.connect()" module function.
   * ESM consumers snapshot the module bindings at import time
   * ("import * as net from 'node:net'"), so reassigning "net.connect"
   * is invisible to them. Every client connection ends up calling
   * "Socket.prototype.connect" (including the one made by the original
   * "net.connect()"), and prototype mutations are visible regardless
   * of how the module was imported.
   */
  patchesRegistry.applyPatch(net.Socket.prototype, 'connect', (realSocketConnect) => { ... })
  ```

  【源码】[src/interceptors/net/index.ts#L203-L225](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/net/index.ts#L203-L225)
- 被拦下的 socket 会把客户端写出的字节**镜像**给 HTTP 解析器（llhttp/WASM），由 `NodeHttpRequestSource` 判断"这是不是一个 HTTP 请求"，是则产生 `request` 事件。

  【源码】[src/interceptors/http/source.ts#L37-L45](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/http/source.ts#L37-L45)（"Interceptor for HTTP requests in Node.js. Routes socket connections through an HTTP parser."）
- 官方仓库内的架构笔记把这条分层写得很清楚（可直接引用）：

  | Layer | Responsibility / entry point |
  | --- | --- |
  | Socket | `src/interceptors/net/index.ts` patches `Socket.prototype.connect`; TCP/TLS controllers intercept handles and writes. |
  | HTTP source | `src/interceptors/http/source.ts` subscribes to mirrored socket data, detects HTTP, parses requests, handles decisions, and serializes mocked responses through native `ServerResponse`. |
  | Browser clients | `fetch/web` and `XMLHttpRequest/web` intercept at the API boundary and implement response/event behavior there. Node's socket mechanism does not apply. |

  【源码】[discoveries/architecture.md](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/discoveries/architecture.md)

  > 另一条可直接引用的原话（v3 发布博客）："The new architecture of Interceptors doesn't patch request clients, or internal classes, or agents. It doesn't even patch the sockets themselves, not in the way you'd think. What it does is bring the interception to the TCP and TLS wraps, which are JavaScript bindings for the Node.js network code in C." / "**Moving the interception any lower would require recompiling Node.js**."【官方文档】[blog/introducing-msw-3.0](https://github.com/mswjs/mswjs.io/blob/610762537b2d672fc6820ac27ce1c00a1e41a4a3/src/content/blog/introducing-msw-3.0.md)

#### 2.3.3 一次请求在 JS 层拦截路线里的通用流程

所有拦截器都走同一个决策函数 `handleRequest()`：

1. 向监听者发 `request` 事件（带 `request / requestId / controller`）；
2. 监听者可以：`controller.respondWith(response)`（mock）、`controller.errorWith(reason)`（错误）、`controller.passthrough()`（放行）、什么都不做；
3. 事件结束后若 controller 仍是 PENDING → **自动 passthrough**：

   ```ts
   // If the request hasn't been handled by this point, passthrough.
   if (options.controller.readyState === RequestController.PENDING) {
     return await options.controller.passthrough()
   }
   ```

   【源码】[src/utils/handle-request.ts#L216-L222](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/utils/handle-request.ts#L216-L222)
4. handler 抛出的异常默认转成 **500 Internal Server Error** 响应（`createServerErrorResponse`）——本项目的 Mock 层若复用这套语义，需要自己接管异常到 aria2 风格错误。

---

## 3 前提条件与能力边界（SW 路线）

### 3.1 前提条件（每条都有依据）

| # | 前提 | 依据 |
|---|---|---|
| P1 | **脚本必须由目标源自己提供**（部署在目标源的 HTTP 服务上，能被该源的 URL 请求到） | 【官方文档】guides/integrations/browser.md "If your application registers a Service Worker it must host and serve it."；【源码】cli/init.js 拷贝脚本、get-worker-instance.ts 404 报错文案 |
| P2 | **脚本 URL 与注册页面必须同源** | 【规范】SW spec Register 算法："If job's script url's origin and job's referrer's origin are not same origin, then: Invoke Reject Job Promise with job and 'SecurityError' DOMException."；【平台文档】MDN register() 的 SecurityError 条目："The scriptURL and scope are not same-origin with the registering page." |
| P3 | **scope 决定能拦哪些 URL；默认 scope = 脚本所在目录；扩大 scope 需要响应头 `Service-Worker-Allowed`** | 【平台文档】MDN register()："The default scope for a service worker registration is the directory where the service worker script is located… A service worker can't have a scope broader than its own location, unless the server specifies a broader maximum scope in a Service-Worker-Allowed header on the service worker script."；【规范】SW spec note："service workers are restricted by the path of the service worker script. For example, a service worker script at https://www.example.com/~bob/sw.js can be registered for the scope url https://www.example.com/~bob/ but not for the scope https://www.example.com/" |
| P4 | **msw 官方对 scope 的直白警告** | 【官方文档】api/setup-worker/start.md："Keep in mind that a Service Worker can only control the network from the clients (pages) hosted at its level or down. You likely always want to register the worker at the root." |
| P5 | **一个 scope 只能有一个 SW**（与站点已有的 SW 冲突） | 【官方文档】guides/recipes/merging-service-workers.md："The browser can only register a single Service Worker per scope. This means that if your application already registers a Service Worker, it cannot register another one for MSW in parallel." |
| P6 | **需要页面上有 MSW 客户端代码**（handler 在页面里跑，SW 只转发）；否则 SW 一律 passthrough | 【源码】mockServiceWorker.js `getResponse()`：`if (!client) return passthrough()`、`if (!activeClientIds.has(client.id)) return passthrough()`；`activeClientIds` 由页面发 `MOCK_ACTIVATE` 加入 |
| P7 | **首次加载 / SW 未激活、未 claim 期间拦不到** | 【源码】同上（`activeClientIds.size === 0` 直接 return、`client.claim()` 在 activate 才生效）；【平台文档】该行为由 SW 生命周期决定 |
| P8 | **非安全上下文不行**（localhost 例外）；`file:` 直接降级 | 【源码】supports.ts `location.protocol !== 'file:'`；【官方文档】guides/integrations/browser.md "Although Service Workers are meant to be served via HTTPS, browsers allow registering workers on HTTP while developing on localhost." |
| P9 | **必须存在"被控制的客户端"**：请求必须来自受该 SW 控制的页面/Worker | 【规范】Handle Fetch：非子资源请求先 `Match Service Worker Registration`，为 null 则 `return null`；子资源请求看 `client's active service worker`，为 null 则 `return null` |

### 3.2 能拦什么 / 拦不到什么

| 请求类型 | 能否被 SW fetch 事件拦到 | 依据 / 说明 |
|---|---|---|
| 受控页面的同源 `fetch` / XHR | ✅ | 【规范】子资源请求 → 客户端 active SW；【平台文档】MDN fetch event："This includes not only explicit fetch() calls from the main thread, but also implicit network requests to load pages and subresources" |
| 受控页面的**跨源** `fetch` / XHR | ✅（能拦到；但 CORS 语义依旧生效） | 同上（子资源请求不看同源，只看客户端受控）；【推论】mock 的跨源响应必须带 CORS 头，否则页面 JS 读不到 |
| 导航请求（`mode: "navigate"`） | ✅ | 【规范】Handle Fetch 的"非子资源请求"分支；【源码】mockServiceWorker.js 对 `event.request.mode === 'navigate'` 有专门处理（把流缓冲成 ArrayBuffer） |
| 子资源：`<img>` / `<script>` / `<link>` / 字体 / 媒体 | ✅ | 【平台文档】MDN fetch event 原文（"pages and subresources (such as JavaScript, CSS, and images)"） |
| `no-cors` 请求 | ⚠️ **能拦到事件，但响应必然以 opaque 形式交给页面**（页面读不到，msw 也主动放弃处理） | 【规范】Fetch spec："no-cors: … Upon success, fetch will return an opaque filtered response."；"An opaque filtered response is a filtered response whose type is 'opaque', URL list is « », status is 0, status message is the empty byte sequence, header list is « », body is null"；【源码】service-worker-source.ts 注释："CORS requests with `mode: "no-cors"` result in 'opaque' responses. That kind of responses cannot be manipulated in JavaScript due to the security considerations." |
| WebSocket | ❌ **SW 拦不到** | 【源码】msw v3 在浏览器给 WS 单独走 `InterceptorSource + WebSocketInterceptor`（setup-worker.ts）；SW 的 fetch 事件不覆盖 WS 升级后的连接语义 |
| SW 脚本自身的请求（`destination: "serviceworker"`） | ❌ 规范禁止 | 【规范】Handle Fetch："Assert: request's destination is not 'serviceworker'." |
| `<embed>` / `<object>` 的请求 | ❌ | 【规范】Handle Fetch："If request's destination is either 'embed' or 'object', then: Return null."；规范注："Plug-ins should not load via service workers… the Handle Fetch algorithm makes <embed> and <object> requests immediately fallback to the network without dispatching fetch event." |
| 不受 SW 控制的页面（其他源、未注册该 SW 的页面） | ❌ | 【规范】P9 |
| SW 激活前的首屏请求 | ❌ | P7 |
| `chrome://`、`view-source:`、扩展的 `chrome-extension://` 页面内请求（不经 HTTP(S) 网络栈） | ❌（Chrome 平台限制） | 【推论】Handle Fetch 的 `potentially trustworthy URL` / HTTP(S) 前提；本项目的 R8/Q-D2 已把 `chrome://` 列为已知盲区 |
| Node 里 `net.connect()` 直连（没有 HTTP 语义的裸 socket） | ❌（按官方文档） | 【官方文档】docs/limitations.md："Due to technical limitations, MSW cannot intercept requests performed via direct net.connect()/net.createConnection() calls."，见 §8 与源码的出入 |

**其他已知边界（官方自己列的）**：

- 【官方文档】docs/limitations.md："**XMLHttpRequest: progress events** — The Service Worker API translates all outgoing requests on the page to Fetch API requests. Those, sadly, do not have a concept of request progress and so the related progress and upload progress events will not be dispatched on the intercepted XMLHttpRequest."（解决方案是绕过 SW，直接用 `XMLHttpRequestInterceptor`）
- 【官方文档】docs/limitations.md："**Firefox: `fetch` event for XMLHttpRequest** — Firefox does not notify the worker when an XMLHttpRequest happens on the page… Even if you have a matching request handler for the request, it won't be matched and the mocked response won't be sent if it's an XMLHttpRequest."
- 【官方文档】docs/limitations.md：总纲 "This library uses the Service Worker API to intercept requests in the browser. Any limitations of that API or any limitations of its implementation in individual browsers are transitively inherited by MSW."

### 3.3 为什么拦不到：一句话机制

SW 是**网络栈内部的一个响应来源**（Fetch 规范 §4.4/§Handle Fetch），而不是 JS 层的钩子。因此它的可见范围 = 「**受它控制的客户端** + **落到它 scope 内的 URL** + **走 Fetch 语义的请求类型**」三者交集；三者之外（别的源/别的客户端、scope 之外、非 HTTP(S) 或非 fetch 语义的请求如 WebSocket/`embed`/SW 脚本自身）天然不可见。

---

## 4 关键技术细节

### 4.1 拦截点一览

| 路线 | 拦截点 | 手段 | 生效范围 |
|---|---|---|---|
| 浏览器 SW | **浏览器的 fetch 事件** | `event.respondWith(promise)` | 受控页面在该 scope 内的所有 fetch 语义请求（含导航、子资源） |
| 浏览器 JS 层（fetch） | `globalThis.fetch` | `patchesRegistry.applyPatch(globalThis, 'fetch', ...)`，闭包保留真函数 | 同一 JS 世界（world）内所有 `fetch()` 调用 |
| 浏览器 JS 层（XHR） | `globalThis.XMLHttpRequest` | `new Proxy(原生构造器, { construct })` + `createProxy()` 拦截方法调用 | 同一 JS 世界内 `new XMLHttpRequest()` |
| 浏览器 JS 层（WS） | `globalThis.WebSocket` | 独立的 `WebSocketInterceptor`（含 client/server 双向 transport 抽象） | 同一 JS 世界内的 `new WebSocket()` |
| Node | **`net.Socket.prototype.connect`** | patch 原型方法；镜像字节 → llhttp 解析 → `request` 事件；响应用原生 `ServerResponse` 序列化 | 进程内所有经 socket 的 HTTP(S) 流量（含 `http.request` / `fetch` / 直接 Undici） |

补充：patch 的落地方式在 `patches-registry.ts`：优先 `Object.defineProperty(owner, key, { value, enumerable: true, configurable: true })`，不可配置时退回赋值，保留 `restorePatch()` 用于卸载（`restoreAllPatches()`）。【源码】[src/utils/patches-registry.ts#L1-L60](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/utils/patches-registry.ts#L1-L60)

msw 侧还额外维护了 `Interceptor.singleton()`（同一进程/全局只允许一份 interceptor，多"owner"引用计数式 apply/dispose），避免多个库重复 patch。【源码】[src/interceptor.ts#L18-L95](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptor.ts#L18-L95)

### 4.2 如何"合成"可信的 Response / XMLHttpRequest

**(a) SW 路线**：SW 里最后是**真的构造了一个 `Response`**，所以对页面而言这就是普通响应：

```js
const mockedResponse = new Response(body, response)   // body 可以是 ReadableStream
Reflect.defineProperty(mockedResponse, IS_MOCKED_RESPONSE, { value: true, enumerable: true })
```

【源码】[src/mockServiceWorker.js#L408-L436](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/mockServiceWorker.js#L408-L436)
细节：`status === 0` 时改返回 `Response.error()`（因为"构造状态码 0 的 Response 是 no-op"）；`navigate` 请求会把流缓冲成 ArrayBuffer 再构造（见 4.4）。

**(b) fetch 路线**：直接返回构造好的 `Response`。难点是 **`response.url`**：原生 fetch 的响应有 URL，mock 出来的没有。msw 的做法是 `FetchResponse.setUrl()`：Node/Undici 下写内部 `Symbol(state).urlList`，其他环境直接 `Object.defineProperty(response, 'url', {...})`，并额外改写 `clone()` 以保证克隆体也带 URL（因为自己定义的 `url` 不会随 clone 传递）。同类还有 `setStatus()`。注释原文："Undici keeps an internal 'Symbol(state)' that holds the actual value of response status. Update that in Node.js."【源码】[src/utils/fetch-utils.ts#L140-L260](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/utils/fetch-utils.ts#L140-L260)

**(c) XHR 路线**：不是"返回一个对象"，而是**驱动真实 XHR 实例的状态机**：

- `define(this.request, 'status', response.status)`、`define(this.request, 'statusText', ...)`、`define(this.request, 'responseURL', response.url)`；
- `setReadyState(HEADERS_RECEIVED)` → `setReadyState(LOADING)`（读 body 过程中分块触发 `readystatechange` + `progress`）→ `setReadyState(DONE)` → `load` + `loadend`；
- `getAllResponseHeaders()` 由 `finalResponse.headers` 拼回 `name: value` 字符串；
- `response` / `responseText` / `responseXML` 按 `responseType`（`json` / `arraybuffer` / `blob` / `text` / `document`）分别实现，并在 `responseText` 上模仿规范的 `InvalidStateError`；
- `errorWith()` → `DONE` + `error` + `loadend`。

【源码】[src/interceptors/XMLHttpRequest/xml-http-request-controller.ts#L390-L500](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/XMLHttpRequest/xml-http-request-controller.ts#L390-L500)、[#L560-L700](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/XMLHttpRequest/xml-http-request-controller.ts#L560-L700)、[#L737-L745](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/XMLHttpRequest/xml-http-request-controller.ts#L737-L745)
反向也有一条：`create-response.ts` 能从 XHR 实例的属性还原出一个 Fetch `Response`（用于把 XHR 请求冒泡成统一的 request/response 事件）。【源码】[utils/create-response.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/XMLHttpRequest/utils/create-response.ts)

**(d) 避免"非法调用"**：`create-proxy.ts` 里有一条注释直白说明为什么要用 `target[propertyName]` 而不是 `Reflect.get()`："Using `Reflect.get()` here causes 'TypeError: Illegal invocation'."【源码】[src/utils/create-proxy.ts#L70-L80](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/utils/create-proxy.ts#L70-L80)

**(e) 请求侧伪造**：`FetchRequest` 支持把 fetch 不允许的 `method`（CONNECT/TRACE/TRACK）与非法的 `mode`（navigate/websocket/webtransport）塞进内部 state，并为 CONNECT 把 `url` 定义成 authority。【源码】[src/utils/fetch-utils.ts#L1-L120](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/utils/fetch-utils.ts#L1-L120)

### 4.3 passthrough 是怎么实现的（三种，别混淆）

| 场景 | 实现 | 原话/证据 |
|---|---|---|
| SW 路线 | SW 内部执行 `fetch(requestClone, { headers })`。SW 自己发起的 fetch **不会再触发自己的 fetch 事件**（规范：`fetch()` 在 `ServiceWorkerGlobalScope` 里调用时把 `service-workers mode` 设为 `"none"`），因此不会无限递归 | 【规范】Fetch spec §5.6 fetch(input, init)："Let globalObject be request's client's global object. If globalObject is a ServiceWorkerGlobalScope object, then set request's service-workers mode to 'none'."；【源码】server-worker-source.ts / mockServiceWorker.js 的 `passthrough()` |
| SW 路线（页面侧改头） | 页面在 `PASSTHROUGH` 消息里回传改写后的请求头 `Array<[name, value]>`，SW 用它构造 `Headers` 再 fetch；同时**删除内部标记** | 【源码】mockServiceWorker.js："Remove the 'accept' header value that marked this request as passthrough. This prevents request alteration and also keeps it compliant with the user-defined CORS policies." |
| JS 层（fetch/XHR/WS） | 用闭包里保存的**原始函数**对 `request.clone()` 执行；XHR 则"不接管，交给真实 XHR 走" | 【源码】fetch/web.ts `realFetch(requestClone)`；xhr-http-request-proxy.ts 的 `passthrough: () => {...}` |
| Node | 用原始 `Socket.prototype.connect` 建一条**真实连接**（保留原始 DNS/TLS 选项），把此前缓冲的写入 flush 过去 | 【源码】net/index.ts `realSocketConnect` / `tls.connect(tlsConnectionOptions)`；discoveries/architecture.md："passthrough -> real connection; flush buffered writes; forward real events/data" |

msw 在 handler 层还把"放行"分成两个**语义不同**的 API，这对本项目 R4.1「未命中 → 原样放行」的措辞有直接参考价值：

- `passthrough()`：**原地放行已拦截的请求，不产生额外请求**；内部实现是返回一个 `302 + x-msw-intention: passthrough` 的响应对象当哨兵，框架看见它就 passthrough。
  【源码】[src/utils/passthrough.ts#L20-L40](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/utils/passthrough.ts#L20-L40)；【官方文档】api/passthrough.md："Unlike bypass(), the passthrough() function does not result in an additional request."
- `bypass()`：**发起一次绕过拦截的额外请求**（实现的技巧是给请求打上 `Accept: msw/passthrough` 标记，msw 的 `shouldBypassRequest()` 见到该标记直接 passthrough）。
  【源码】[src/core/experimental/request-utils.ts#L1-L10](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/core/experimental/request-utils.ts#L1-L10)；【官方文档】api/bypass.md："Requests performed via bypass() will never be intercepted"

### 4.4 流式响应（ReadableStream）怎么处理

有四层机制：

1. **能力探测 + `postMessage` transferable**：`supportsReadableStreamTransfer()` 试着把 `ReadableStream` 通过 `MessageChannel` 传一次，成功才走流式传输；否则退化为 `await response.clone().arrayBuffer()`。
   【源码】[src/browser/utils/supports.ts#L18-L30](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/utils/supports.ts#L18-L30)、service-worker-source.ts `#respondWith()`
2. **导航请求要缓冲**（否则页面导航后原客户端被销毁、流永不完成）："Buffer the streamed mocked response body for navigation requests… Buffering here keeps 'event.respondWith()' pending (the navigation cannot commit) until the entire body arrives from the client."
   【源码】[src/mockServiceWorker.js#L410-L435](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/mockServiceWorker.js#L410-L435)
3. **给观察者克隆流时不能拖住调用方的取消**：`cloneResponse()` 手工 tee 并包装 `cancel`："Clone for observers without letting their unread body block caller cancellation."【源码】[src/utils/clone-response.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/utils/clone-response.ts)
4. **SSE 特例**：`content-type: text/event-stream` 的响应**不克隆** body，避免把整条流缓冲进一个永不消费的克隆、并保证客户端的取消能传导到原流。【源码】[src/mockServiceWorker.js#L190-L210](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/mockServiceWorker.js#L190-L210)

另外：msw 官方支持用 `ReadableStream` / `TransformStream` 作为 mock body，且能"取真实响应的流 + 插延迟再返回"。【官方文档】docs/http/mocking-responses/streaming.md；二进制用 `HttpResponse.arrayBuffer()` 并自动补 `content-length`。【官方文档】docs/http/mocking-responses/binary.md

### 4.5 抗检测（"如何避免被识破"）

**路线 A：SW 路线本身几乎不可被页面 JS 检测**（这是它最大的技术优势，也是本项目 R9 的对照面）：

- msw v3 在浏览器里**只对 WebSocket 用 JS 层拦截**，HTTP 完全走 SW；也就是说页面里的 `window.fetch` / `XMLHttpRequest` / `Response` **一个都没被改**（【源码】setup-worker.ts 的 sources 组装）。
- 【官方文档】docs/index.md 把它当作卖点："Instead of patching `fetch` and meddling with your application's integrity, MSW bets on the platform…"
- 但"不可检测"是相对的：页面可以查 `navigator.serviceWorker.controller`、`getRegistrations()` 看到多出来的 SW；DevTools 的 Application 面板也可见。**SW 注册本身对页面是可见的**。

**路线 B：JS 层拦截器的"伪装"手法**（如果本项目走 R9 的 JS 层 patch，这些细节可以直接抄）：

| 手法 | 证据 |
|---|---|
| 用 `Proxy` 包住原生构造器而非 `class XHR extends XMLHttpRequest`，保持 `name` / 原型链 / `instanceof` | 【源码】xml-http-request-proxy.ts；并显式把原型描述符转发到实例上 |
| patch 时保留属性描述符（`enumerable: true, configurable: true`）并提供 restore | 【源码】patches-registry.ts |
| 只改"必须改"的属性，其余走原生：例如 mock Response 只额外定义 `url`/`status`，并改写 `clone()` 保持一致性 | 【源码】fetch-utils.ts |
| 请求/响应仍是**真实的 `Request`/`Response` 实例**（不是鸭子类型） | 【官方文档】docs/philosophy.md："each intercepted request is an _actual_ `Request` instance, and each mocked response is an _actual_ `Response` instance" |
| Node 侧保留 `rawHeaders`（`recordRawFetchHeaders` / `copyRawHeaders`）以贴近原生 IncomingMessage | 【源码】ClientRequest/utils/record-raw-headers.ts |
| 处理"非法调用"这类边角（避免在 Proxy 上用 `Reflect.get`） | 【源码】create-proxy.ts 注释 |
| 支持对 mock 响应做 `decompressResponse`、`followFetchRedirect`、redirect 模式（`error`/`follow`/`manual`）语义 | 【源码】fetch/web.ts |

**注意（对"抗检测"的诚实边界）**：以上都只能做到"接口行为尽量像原生"，**不能做到不可检测**。`Function.prototype.toString` 对 patched 全局（例如被 async 箭头函数替换的 `fetch`）与原生函数的输出是否一致、属性描述符是否逐位相同等，我**没有找到 msw 的专门处理代码**，列为【未验证】（见 §8）。

---

## 5 能否借鉴（逐条）

> 判断标准：能否直接落到 R4/R5/R9/R10 上；"借鉴"= 抄设计/复用代码，不等于"用 msw 这个库"。

| # | 可借鉴的设计 | 为什么对本项目有价值 | 证据 |
|---|---|---|---|
| B1 | **「网络源（source）」与「handler 决策」分离**：`NetworkSource` 抽象出"请求从哪来"，`HandlersController/NetworkFrame` 负责"怎么判、怎么答"；同一个 frame 逻辑可挂在不同 source 上 | 与本项目"转发器（入口）／Mock 层（决策）／引擎层（执行）"三层高度同构；也使 R5「只换装载方式，不换路径」变成**结构性保证**而不是纪律要求 | 【源码】[src/core/experimental/define-network.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/core/experimental/define-network.ts)、[handlers-controller.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/core/experimental/handlers-controller.ts)、[network-source.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/core/experimental/sources/network-source.ts) |
| B2 | **多路拦截可并存**：SW 源 + JS 层源同时挂在同一个 network 上（HTTP 走 SW、WS 走 interceptor），互不干扰 | 直接支撑 R4.1「尽可能多地拦截各种途径」：`fetch`/XHR/WS 可以各自用不同底层机制，上层统一 | 【源码】setup-worker.ts 的 `sources: [httpSource, new InterceptorSource({ interceptors: [new WebSocketInterceptor()] })]` |
| B3 | **handler 匹配模型**：`method + path(字符串/正则/自定义谓词)`，查询串被剥离，`params` 提取；`executeHandlers` 语义是"**第一个返回响应的 handler 生效**；返回了结果但没返回响应的算 fallthrough" | R4.1 的"命中 → 转交 / 未命中 → 放行"可以照抄这个判定结构与次序语义；Q-D1 的"只支持一条精准 URL"用现成模型即可表达 | 【源码】[execute-handlers.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/core/utils/execute-handlers.ts)、[match-request-url.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/core/utils/matching/match-request-url.ts)、[http-handler.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/http/http-handler.ts) |
| B4 | **未命中请求的三种策略 + 静态资源豁免**：`onUnhandledFrame` 取 `'bypass'` / `'warn'` / `'error'` 之一或自定义回调；`isCommonAssetRequest()` 对 `file:`、`node_modules`、`@vite`、常见后缀自动忽略 | 本项目需要"未命中一律放行"（R4.1）＋"拦截盲区要可观测"（Q-D2/Q-D6），这套策略枚举正好是现成词汇表 | 【源码】[on-unhandled-frame.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/core/experimental/on-unhandled-frame.ts)、[is-common-asset-request.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/utils/is-common-asset-request.ts) |
| B5 | **显式旁路标记**：`Accept: msw/passthrough` 作为"这条请求不要拦"的内部信令，且在真正发出前删除该值 | 若本项目的 Mock 层需要"内部发起的真实请求不得被自己再拦一次"（例如引擎去取真实文件），这是低成本、跨世界可达（SW ↔ 页面）的信令方案 | 【源码】request-utils.ts；mockServiceWorker.js 的注释见 §4.3 |
| B6 | **`passthrough()` vs `bypass()` 的语义切分** | R10 判据是"最终结果是否兑现"；引擎若需要"拿真实响应再加工"（response patching），`bypass` 的语义正是这个；而"未命中就放行"应当是 `passthrough`（不产生额外请求） | 【官方文档】api/passthrough.md / api/bypass.md |
| B7 | **流式响应跨上下文传输的完整方案**（能力探测 → transferable → 导航缓冲 → 观察者 tee/cancel → SSE 特例） | 下载引擎在本项目里必然涉及"大 body / 流式进度 / 取消"；这套坑位清单可以直接当设计 checklist（尤其"给观察者克隆流不能阻断调用方取消"这一条，容易踩） | 【源码】supports.ts、clone-response.ts、mockServiceWorker.js §4.4 |
| B8 | **response 生命周期事件**（`request:start / match / unhandled / end`、`response:mocked / bypass`） | Q-D6「Mock 控制台」与 Q-D2「盲区必须可观测」的直接实现参考：把"拦到了但没处理"也做成事件而不是静默 | 【源码】http-frame.ts 的 `HttpNetworkFrameEventMap` |
| B9 | **SW 生命周期工程化处理**（`skipWaiting` + `clients.claim`、5s keepalive ping、`pagehide`/`CLIENT_CLOSE`、无客户端自动 unregister、脚本版本 + checksum 校验） | 与 Q-D5「SW 重启不模拟重启、状态必须持久化」同源问题：msw 的答案是**不依赖 SW 内存**（业务状态在页面），SW 只做通道；keepalive 是它对"SW 会被杀"的补丁 | 【源码】mockServiceWorker.js（`skipWaiting`/`clients.claim`/`CLIENT_CLOSE`/`actionClientIds`）、service-worker-source.ts（`keepAliveInterval` 5000ms、`INTEGRITY_CHECK`）、get-worker-instance.ts（worker 版本/校验和） |
| B10 | **`@mswjs/interceptors` 作为独立依赖直接用在浏览器**（browser preset 只有 2 个拦截器，MIT，无 SW 依赖） | 本项目 R9 定的就是 JS API 层拦截；这个包把 fetch/XHR/WS 的 patch 细节（Proxy、描述符转发、事件伪造、passthrough 的"自动放行"默认语义）都封装好了，可以省掉大量边角工作 | 【源码】[src/presets/browser.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/presets/browser.ts)、[LICENSE.md](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/LICENSE.md) |
| B11 | **反面教训：SW 路线会让 XMLHttpRequest 失去 progress 事件**（因为请求被翻译成 Fetch 语义） | AriaNg 之类的前端会依赖 XHR 进度/上传进度；若本项目某天想用 SW，这条是明确的成本 | 【官方文档】docs/limitations.md |

---

## 6 能否直接使用（把 msw 引进 MV3 扩展，用来拦任意页面的请求）

### 6.1 结论

**不能直接使用。** 更精确的结论分三层：

| 用法 | 判定 | 原因 |
|---|---|---|
| 用 `setupWorker()`（SW 路线）拦**任意第三方页面** | ❌ **不能** | 见 6.2 的 E1–E4：扩展无法把 SW 脚本注册到别人的源上；脚本必须由目标源自己提供 |
| 用 `setupWorker()` 拦**扩展自己的页面**（内置 AriaNg UI / 扩展页） | ❌ **不能**（按官方文档） | Chrome 官方明确："This does not work for extensions."（见 E3）；扩展的 SW 由 manifest 声明，不由 `navigator.serviceWorker.register()` 注册 |
| 用 `@mswjs/interceptors`（browser preset）在页面里拦 `fetch`/XHR/WS | ✅ **技术上可用（但需自建上层）** | 它就是 JS API 层 patch，与 R9 同构；但 msw 的 `setupWorker`/`http` handler 体系依赖 source 抽象，直接拿来要评估；且必须注入到页面 MAIN world |

### 6.2 逐条核实（这是"能不能"的核心）

**E1. 规范层面：SW 脚本必须与注册它的页面同源。**
【规范】SW spec Register 算法："If job's script url's origin and job's referrer's origin are not same origin, then: Invoke Reject Job Promise with job and 'SecurityError' DOMException."
【平台文档】MDN register() 的异常条目："SecurityError DOMException — The scriptURL is not a potentially trustworthy origin… The scriptURL and scope are not same-origin with the registering page."
【平台文档】Chromium 实现（Blink）里的同源检查与错误文案（`third_party/blink/renderer/modules/service_worker/service_worker_container.cc`）：

```cc
if (!document_origin->CanRequest(script_url)) {
  scoped_refptr<const SecurityOrigin> script_origin = SecurityOrigin::Create(script_url);
  resolver->Reject(ServiceWorkerErrorForUpdate::AsJSException(
      script_state, mojom::blink::ServiceWorkerErrorType::kSecurity,
      StrCat({"Failed to register a ServiceWorker: The "
              "origin of the provided scriptURL ('", script_origin->ToString(),
              "') does not match the current origin ('", document_origin->ToString(), "')."})));
  return promise;
}
```

（[chromium/src main: service_worker_container.cc](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/third_party/blink/renderer/modules/service_worker/service_worker_container.cc)，2026-10-06 抓取）
还有一道 scheme 白名单检查（同一文件）：

```cc
if (!SchemeRegistry::ShouldTreatURLSchemeAsAllowingServiceWorkers(page_url.Protocol())) {
  ... "Failed to register a ServiceWorker: The URL protocol of the current origin ('",
      document_origin->ToString(), "') is not supported."
}
```

含义：**扩展资源（`chrome-extension://<id>/...`）不能被注册成 `https://example.com` 页面的 Service Worker**——因为那不是同源；而扩展也没有办法把脚本"真的"放到 `https://example.com` 的服务器上（除非用户自己部署）。

**E2. 内容脚本只能在"页面的源"下注册。**

- 【平台文档】Chrome 扩展官方文档（Cross-origin network requests）："**Content scripts initiate requests on behalf of the web origin that the content script has been injected into** and therefore content scripts are also subject to the same origin policy. Extension origins aren't so limited."（[developer.chrome.com/docs/extensions/develop/concepts/network-requests](https://developer.chrome.com/docs/extensions/develop/concepts/network-requests)）
- 【平台文档】Chrome 扩展官方文档（Content scripts）："Content scripts live in an isolated world… An isolated world is a private execution environment that isn't accessible to the page or other extensions."（[developer.chrome.com/docs/extensions/develop/concepts/content-scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts)）
- 【推论】内容脚本里调用 `navigator.serviceWorker.register('/mockServiceWorker.js')`，只可能注册到**宿主页面的源**上；而该 URL 必须由宿主页面的服务器提供。扩展不能提供 `https://example.com/mockServiceWorker.js` 的内容（DNR 重定向是唯一可疑的例外，见 E4）。

**E3. 扩展页面自己也不能用 JS API 注册 SW（官方明说）。**
【平台文档】Chrome 扩展官方文档（Extension service workers basics）："Service workers in web pages or web apps register service workers by first feature-detecting for `serviceWorker` in `navigator` then calling `register()` inside feature detection. **This does not work for extensions.**"（[developer.chrome.com/docs/extensions/develop/concepts/service-workers/basics](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/basics)）
补充：【平台文档】Chromium 里 `chrome-extension` 是被注册为"允许 SW 的 scheme"的——`extensions/renderer/dispatcher.cc`："// chrome-extension: resources should be allowed to register ServiceWorkers." + `WebSecurityPolicy::RegisterURLSchemeAsAllowingServiceWorkers(extension_scheme);`（[chromium/src main: extensions/renderer/dispatcher.cc](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/renderer/dispatcher.cc)）。这说明"扩展源可以有 SW"（MV3 的 background SW 就是），但**注册动作由浏览器按 manifest 完成，而不是页面 JS**；结论 E3 以 Chrome 官方文档为准。

**E4. 唯一"有条件"的技术路径：用 DNR 把 `https://target/mockServiceWorker.js` 重定向到扩展资源。**

- 【平台文档】DNR 官方文档支持把请求重定向到扩展内资源：

  ```json
  { "action": { "type": "redirect", "redirect": { "extensionPath": "/a.jpg" } } }
  ```

  "The following example shows how to redirect a request from example.com to a page within the extension itself. The extension path `/a.jpg` resolves to `chrome-extension://EXTENSION_ID/a.jpg`… For this to work the manifest should declare `/a.jpg` as a web accessible resource."（[developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest)）
- 【平台文档】DNR 与 SW 的关系（关键限制）："A declarativeNetRequest only applies to requests that reach the network stack. This includes responses from the HTTP cache, but may not include responses that go through a service worker's `onfetch` handler. declarativeNetRequest won't affect responses generated by the service worker or retrieved from `CacheStorage`, but it will affect calls to `fetch()` made in a service worker."（同上）
- 【推论】理论上：加一条 DNR 规则把 `https://target/mockServiceWorker.js` 重定向到扩展的 `web_accessible_resources`，页面（MAIN world 注入的脚本）再 `register('/mockServiceWorker.js')`，就可能让**目标源出现一个由扩展提供的 SW**。
- **【未验证】**：我没有找到任何官方文档说明"SW 脚本请求是否受 DNR 影响"（SW 脚本 fetch 的 `service-workers mode` 是 `none`，按规范"会到达网络栈"；但上面那句"may not include responses that go through a service worker's onfetch handler"并不直接回答 SW 脚本本身）。**没有实测**（本环境无浏览器）。
- 即便该路径成立，它也不是"使用 msw"了，而是**自己造一个注入 SW 的机制**，并且要吞下 6.3 的全部后果。

### 6.3 就算技术路径能打通，后果是什么（必须写清）

1. **注册是"按源、全局、持久"的，不是"按 URL、按任务"的。** SW 一旦在 `example.com` 上激活，它就控制该源下**所有**页面与请求（scope 覆盖范围内），无法只拦 `example.com:8443/rpc` 一条 URL（对比 Q-D1 的"只支持一条精准匹配 URL"）。想只拦一条路径，必须把 scope 缩到脚本目录（例如 `/rpc/`），前提是你能在 `/rpc/mockServiceWorker.js` 提供脚本——这要求 DNR 对具体路径重定向，进一步增加脆弱性。
2. **与站点自身的 SW 冲突，且只能二选一。** 【官方文档】msw guides/recipes/merging-service-workers.md："The browser can only register a single Service Worker per scope." 若目标站点自己有 SW（现代站点很常见），扩展的做法要么被拒绝、要么顶掉站点的 SW（造成离线/缓存逻辑失效）。
3. **卸载残留风险。** SW 注册存在浏览器 profile 里；扩展被禁用/卸载后，那条注册是否被清理不由扩展控制。一个"给用户浏览器留下控制某站点所有请求的 SW"的行为，在隐私/商店合规上是高风险项（本项目 R8/Q-D2 已把"盲区必须告知用户"作为纪律，这条属于更严重的一类）。
4. **拦截层次与 R9 相反。** R9 定的是"请求发出之前就地短路，不是网络层的重定向/代理；CORS、混合内容、证书等全部不适用"。SW 属于**网络栈内部**：请求已经进入网络栈，CORS 语义仍会作用在最终响应上（跨源 mock 响应必须自带 `Access-Control-Allow-Origin` 等头，否则页面读不到）；`no-cors` 请求的响应必然是 opaque（§3.2），完全不可读。这直接违背 R9 的设计前提。
5. **需要页面侧配合注入**：注册动作必须在**目标页面自身的源与文档上下文**里发生（脚本 URL 由该源提供，见 E1/E2），扩展只能靠在目标页面 JS 世界（MAIN world）里执行的脚本去触发它，并且必须在 `document_start` 阶段完成（否则首屏请求漏拦）。内容脚本（隔离世界）能否直接调用 `register()` 未实测（见 §8 U2）。
6. **对扩展自身页面也没救**：扩展页不能用 `register()`（E3），内置 AriaNg UI（R5）只能靠 JS 层拦截；因此"SW 路线"无法覆盖 R5 要求的"同一路径"。

### 6.4 如果要用 msw 的能力，需要什么改造

| 改造项 | 内容 | 依据 |
|---|---|---|
| C1 | **不用 `setupWorker()`/`ServiceWorkerSource`**，改用 `@mswjs/interceptors` 的 browser preset（`FetchInterceptor` + `XMLHttpRequestInterceptor`）作为"转发器"的 JS 层实现 | 【源码】presets/browser.ts；msw 自己就是这么用的（SW 不可用时的 FallbackHttpSource、以及 WS） |
| C2 | **MAIN world 注入**：`chrome.scripting.executeScript({ target, world: 'MAIN', files: [...] })`，在 `document_start` 执行 | 【平台文档】scripting: `ExecutionWorld`：`"MAIN": Specifies the main world of the DOM, which is the execution environment shared with the host page's JavaScript.` |
| C3 | **在 MAIN world 里不能直接用扩展的 chunk 加载**：需要把拦截器代码打包成自包含脚本注入（MV3 禁止远程代码；注入脚本本身是扩展包内文件，允许）；同时注意 `web_accessible_resources` 与页面 CSP 的影响（注入脚本执行在页面上下文，受页面 CSP 影响的方式随浏览器而异，**未验证**） | MV3 通用约束 + 【平台文档】content scripts/DNR 文档 |
| C4 | **自建上层**：不从 msw 拿 handler 体系（它绑定 NetworkSource/frame），而是复用其"匹配 → 解析 → 响应"的事件模型；aria2 的 JSON-RPC/XML-RPC/WS 语义要自己写 | 【源码】handler/source 的耦合关系见 §2.1 |
| C5 | **XHR 进度事件要自己处理**（如果走 SW 就必然丢，走 JS 层拦截器则原生支持） | 【官方文档】docs/limitations.md |
| C6 | **拒绝/错误语义要对齐 R3/Q-B2**：interceptors 默认把 handler 抛错变成 500 响应，需要改造成 aria2 风格错误体 | 【源码】handle-request.ts 的 `createServerErrorResponse` |
| C7 | **许可证与来源标注**：MIT，可商用；但若直接复制其实现（而非作为依赖），需保留版权与许可声明 | 【源码】LICENSE.md |

---

## 7 许可证、维护状态、成熟度

| 维度 | 数据 | 来源 |
|---|---|---|
| 许可证 | **MIT**："MIT License / Copyright (c) 2018–present Artem Zakharchenko" | 【源码】[msw LICENSE.md](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/LICENSE.md)；[interceptors LICENSE.md](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/LICENSE.md) |
| npm 最新版 | msw **3.0.2**（2026-10-03 发布）；`@mswjs/interceptors` **0.45.7**（2026-10-04 发布） | npm registry（2026-10-06 抓取）：`https://registry.npmjs.org/msw`、`https://registry.npmjs.org/@mswjs%2finterceptors` |
| 发布节奏 | 近 6 个月 **19 个版本**（2.13.0 → 3.0.2）；3.0.0 于 2026-09-28 发布；官方 ADR 写明自动化发布："the library releases automatically every day" | npm `time` 字段（2026-10-06）；【源码】[decisions/releases.md](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/decisions/releases.md) |
| 下载量 | msw 周下载 **26,798,820**、月 **87,549,356**；interceptors 周 **28,432,828**、月 **93,854,910** | npm downloads API（2026-10-06 抓取，区间见 §9） |
| GitHub 规模 | msw：**18.3k stars / 629 forks / 12 open issues / 1 open PR**（页面数字）；contributors 172（shields.io 徽章数据）；最后提交 2026-10-05 前后；interceptors：689 stars / 175 forks / 7 watching / 21 open issues（shields） | GitHub 页面 HTML（2026-10-06 抓取；GitHub REST API 因共享 IP 触发 60 req/h 限流，改用页面 + shields.io 交叉核对，见 §8） |
| 运行时要求 | **ESM-only**（v3 起）、Node **>= 22.12.0**；granular entrypoints（`msw/browser`、`msw/http`、`msw/ws`、`msw/sse`…） | 【官方文档】blog/introducing-msw-3.0；【源码】package.json `engines`/`exports` |
| 维护姿态 | 活跃（当日提交、每日自动发布）；但对"非标准环境"明确不接单：ADR | 【源码】[decisions/jest-support.md](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/decisions/jest-support.md)："That is not a reasonable use of the limited contributors' time."；docs/limitations.md 亦自述 "development tool" |
| 成熟度/定位 | 浏览器+Node 双端 API mocking 的事实标准之一（"The industry standard for API mocking in JavaScript." 是它在 package.json 里的 description），生态成熟、文档完善、测试覆盖广（仓库自带 vitest 浏览器/Node 双项目与大量 compliance 测试） | 【源码】package.json `description`；【源码】discoveries/architecture.md "For verification, Vitest has separate `unit`, `node`, `memory`, and Chromium browser projects." |

**是否适合作为生产依赖（针对本项目）**：

- **作为"给用户用的运行时拦截器"不合适**：它是开发/测试期工具（官方自述 development tool），且它的浏览器拦截主线依赖"你自己的应用部署 SW 脚本"这一前提（§3、§6）。
- **作为"设计参考 + 局部代码复用"合适**：`@mswjs/interceptors` 是独立的、可单独依赖的包（MIT、周下载量 > 2600 万、无 SW 依赖），其 browser preset 与 R9 同构，可作为转发器实现的起点；但要用它就得接受它把 `fetch`/`XMLHttpRequest`/`WebSocket` 全局 patch 掉（这正是 R9 的选择）。
- **供应链提示**：ESM-only + Node>=22 意味着若在**扩展构建期**使用 msw 作为 dev 依赖没有障碍；若要在**扩展运行时**塞进 MV3 的 service worker（例如用 msw/node 的 Node 版，不，MV3 的 background SW 不是 Node），则完全不适用。

---

## 8 未验证 / 存疑

| # | 事项 | 现状与影响 |
|---|---|---|
| U1 | **DNR 重定向能否作用于 Service Worker 脚本请求**（即 `https://target/mockServiceWorker.js` → `chrome-extension://…/sw.js` 是否真的能让页面注册成功） | 未验证：无官方文档表述、本环境无浏览器可实测。这是 §6.2 E4 那条"有条件路径"成立与否的关键；即便成立也要吞下 §6.3 的后果 |
| U2 | **内容脚本里 `navigator.serviceWorker.register()` 的确切行为**（是抛 SecurityError 还是被浏览器以其他方式拒绝；隔离世界的 ExecutionContext 归属） | 部分未验证：官方文档只说明"内容脚本以页面源发起请求"，Blink 源码给出同源拒绝条件；未找到"内容脚本调用 register"的官方专门说明，也未实测 |
| U3 | **"被 SW respondWith 的请求仍出现在 DevTools Network" 的官方原句** | 未找到直接表述；本文的结论由 DevTools Timing 文档（"Request to ServiceWorker" 阶段）、CDP `Response.fromServiceWorker` 字段、SW 规范中 Handle Fetch 的位置共同推出（§2.2.4 已标注为推论） |
| U4 | **JS 层 patched 全局的抗检测程度**（如 `fetch.toString()`、属性描述符、`Object.getOwnPropertyNames` 是否与原生逐位一致） | 未验证：msw 源码里没有看到针对 `Function.prototype.toString` 的伪装代码，也没有文档承诺"不可检测" |
| U5 | **官方文档与 v0.45.7 源码的不一致①**：docs/limitations.md 说 "MSW cannot intercept requests performed via direct net.connect()/net.createConnection() calls"，但 v0.45.7 的 `SocketInterceptor` 恰恰 patch 了 `net.Socket.prototype.connect`（原始 connect 被保留用于 passthrough） | 存疑/文档滞后。含义：Node 侧"能不能拦裸 socket"的实际能力以源码为准；引用这句话时需注明版本与出入 |
| U6 | **官方文档与源码的不一致②**：docs/index.md 说 Node 侧 "MSW uses _class extension_ instead of module patching"，v3 博客说新架构"doesn't patch request clients, or internal classes, or agents"，但 v0.45.7 源码里明确用 `patchesRegistry` patch 了 `http.request`/`http.get`/`http.ClientRequest`/`globalThis.fetch`/`net.Socket.prototype.connect` | 存疑。二者可以调和（"不 patch 客户端类"指的是不再做 `MockHttpSocket extends net.Socket` 那种类替换，而是 patch TCP/TLS wrap），但表面文字与源码不一致，引用时需谨慎 |
| U7 | **GitHub REST API 数据（stars/open issues 的精确值）** | GitHub API 在本次环境中因共享 IP 触发限流（60 req/h 用尽，返回 403 `API rate limit exceeded`），改用 GitHub 页面 HTML（18.3k stars / 12 issues / 1 PR / 629 forks，抓取时间 2026-10-06）与 shields.io 徽章交叉核对；contributors 172 **仅来自 shields.io**，未二次验证 |
| U8 | **msw 在 SW 路线下对 `no-cors` 请求"mock 后页面拿到的具体形态"** | 本文给出的是规范推导（no-cors → opaque filtered response，status 0 / body null）＋ msw 源码注释（opaque 响应不可操作、msw 直接跳过处理）。未实测"给 no-cors 请求 mock 一个响应，页面看到什么" |
| U9 | **msw 是否会在页面/扩展环境下与已有 SW 交互产生别的副作用**（例如 `clients.claim()` 抢占已打开的页面） | 仅源码可读：`activate` 里无条件 `self.clients.claim()`，`getWorkerInstance` 在"页面没有 controller 但存在注册"时会 `location.reload()`。这两条对"第三方注入"场景的含义（会在用户页面上直接 reload！）值得注意，但未实测 |
| U10 | **Firefox 对 XHR 不触发 fetch 事件、以及 `chrome.` 命名空间下扩展页的 SW 注册行为** | 前者为官方文档自述（未实测）；后者只查了 Chrome 官方文档与 Chromium 源码，未查 Firefox/WebKit |

---

## 9 证据清单（URL + 原文摘录）

> 抓取时间统一为 **2026-10-06（UTC）**。仓库链接使用 commit 永久链接。

### 9.1 msw 源码（v3.0.2，commit `501a591640648c86b9733167eab7d29339671eec`）

| # | 位置 | 原文摘录（英文原样） |
|---|---|---|
| S1 | [src/mockServiceWorker.js](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/mockServiceWorker.js) | `addEventListener('fetch', function (event) { … if (activeClientIds.size === 0) { return } const requestId = crypto.randomUUID(); event.respondWith(handleRequest(event, requestId)) })`；<br>`function passthrough(data) { … return fetch(requestClone, { headers }) }`；<br>`// Remove the "accept" header value that marked this request as passthrough. This prevents request alteration and also keeps it compliant with the user-defined CORS policies.`；<br>`if (event.request.mode === 'navigate' && body instanceof ReadableStream) { body = await new Response(body).arrayBuffer() }`；<br>`Reflect.defineProperty(mockedResponse, IS_MOCKED_RESPONSE, { value: true, enumerable: true })` |
| S2 | [src/mockServiceWorker.js（DevTools 特例）](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/mockServiceWorker.js#L122-L130) | `// Opening the DevTools triggers the "only-if-cached" request that cannot be handled by the worker. Bypass such requests.` |
| S3 | [src/mockServiceWorker.js（SSE 特例）](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/mockServiceWorker.js#L190-L210) | `// Omit the body of server-sent event stream responses. Cloning such responses would prevent client-side stream cancelations from reaching the original stream…` |
| S4 | [src/browser/setup-worker.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/setup-worker.ts#L50-L75) | `const httpSource = supportsServiceWorker() ? await ServiceWorkerSource.from({…}) : new FallbackHttpSource({ quiet: options?.quiet })`；`sources: [httpSource, new InterceptorSource({ interceptors: [new WebSocketInterceptor()] })]` |
| S5 | [src/browser/sources/fallback-http-source.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/sources/fallback-http-source.ts#L1-L15) | `super({ interceptors: [new XMLHttpRequestInterceptor(), new FetchInterceptor()] })` |
| S6 | [src/browser/utils/supports.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/utils/supports.ts) | `return typeof navigator !== 'undefined' && 'serviceWorker' in navigator && typeof location !== 'undefined' && location.protocol !== 'file:'`；<br>`// Returns a boolean indicating whether the current browser supports ReadableStream as a Transferable when posting messages.` |
| S7 | [src/browser/utils/get-worker-instance.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/utils/get-worker-instance.ts) | `const registration = await navigator.serviceWorker.register(url, options)`；`Failed to register a Service Worker for scope ('${scopeUrl.href}') with script ('${absoluteWorkerUrl}'): Service Worker script does not exist at the given path. Did you forget to run "npx msw init <PUBLIC_DIR>"?` |
| S8 | [src/browser/utils/validate-worker-scope.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/utils/validate-worker-scope.ts) | `Cannot intercept requests on this page because it's outside of the worker's scope ("${registration.scope}")…` |
| S9 | [src/browser/sources/service-worker-source.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/sources/service-worker-source.ts#L318-L332) | `/** CORS requests with mode: "no-cors" result in "opaque" responses. That kind of responses cannot be manipulated in JavaScript due to the security considerations. @see https://github.com/mswjs/msw/issues/529 */` |
| S10 | [src/browser/sources/service-worker-source.ts（keepalive / 完整性）](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/browser/sources/service-worker-source.ts#L285-L300) | `this.#keepAliveInterval = window.setInterval(() => { this.#channel.postMessage('KEEPALIVE_REQUEST') }, 5000)`（#L293）；`The currently registered Service Worker has been generated by a different version of MSW (${packageVersion}) and may not be fully compatible…`（#L400-L425，`INTEGRITY_CHECK_REQUEST` 见 #L408） |
| S11 | [cli/init.js](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/cli/init.js) | `fs.copyFileSync(SERVICE_WORKER_BUILD_PATH, workerDestinationPath)`（把 worker 脚本复制到应用 public 目录） |
| S12 | [config/copy-service-worker.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/config/copy-service-worker.ts#L36-L42) | `.replace('<INTEGRITY_CHECKSUM>', checksum).replace('<PACKAGE_VERSION>', packageJson.version)` |
| S13 | [src/core/utils/execute-handlers.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/core/utils/execute-handlers.ts) | `// If the handler produces some result for this request, it automatically becomes matching.`；`// Stop the lookup if this handler returns a mocked response.` |
| S14 | [src/core/experimental/frames/http-frame.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/core/experimental/frames/http-frame.ts#L140-L300) | `// Requests wrapped in explicit "bypass(request)"`；`// No matching handlers.`→`passthrough()`；`// Handlers that returned no mocked response.`→`passthrough()` |
| S15 | [src/utils/passthrough.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/utils/passthrough.ts#L20-L40) | `return new Response(null, { status: 302, statusText: 'Passthrough', headers: { [REQUEST_INTENTION_HEADER_NAME]: RequestIntention.passthrough } })` |
| S16 | [src/core/experimental/request-utils.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/core/experimental/request-utils.ts) | `export function shouldBypassRequest(request: Request): boolean { return !!request.headers.get('accept')?.includes('msw/passthrough') }` |
| S17 | [src/core/experimental/on-unhandled-frame.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/core/experimental/on-unhandled-frame.ts) | `export type UnhandledFrameStrategy = 'bypass' \| 'warn' \| 'error'`；`// Ignore unhandled common HTTP assets.` |
| S18 | [src/http/http-response.ts](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/src/http/http-response.ts) | `export class HttpResponse<BodyType extends DefaultBodyType> extends FetchResponse`；`// Automatically set the "Content-Length" response header for non-empty text responses.` |
| S19 | [decisions/releases.md](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/decisions/releases.md) | `The next version of the library releases automatically every day.` |
| S20 | [decisions/jest-support.md](https://github.com/mswjs/msw/blob/501a591640648c86b9733167eab7d29339671eec/decisions/jest-support.md) | `MSW offers no official support for Jest.`；`That is not a reasonable use of the limited contributors' time.` |

### 9.2 @mswjs/interceptors 源码（v0.45.7，commit `49d7901772d5c07b71d75b7470a2562ef28c3755`）

| # | 位置 | 原文摘录 |
|---|---|---|
| I1 | [src/presets/browser.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/presets/browser.ts) | `export default [new FetchInterceptor(), new XMLHttpRequestInterceptor()] as const` |
| I2 | [src/interceptors/fetch/web.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/fetch/web.ts) | `patchesRegistry.applyPatch(globalThis, 'fetch', (realFetch) => { return async (input, init) => { … const requestClone = request.clone(); const [responseError, originalResponse] = await until(() => realFetch(requestClone)) …`；`// Mocked responses have no URL. Mimic the actual fetch and set the response URL to the request URL.` |
| I3 | [src/interceptors/XMLHttpRequest/xml-http-request-proxy.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/XMLHttpRequest/xml-http-request-proxy.ts#L19-L47) | `const XMLHttpRequestProxy = new Proxy(globalThis.XMLHttpRequest, { construct(target, args, newTarget) { … } })`；`// Forward prototype descriptors onto the proxied object.` |
| I4 | [src/interceptors/XMLHttpRequest/xml-http-request-controller.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/XMLHttpRequest/xml-http-request-controller.ts) | `define(this.request, 'status', response.status)`；`this.setReadyState(this.request.HEADERS_RECEIVED)`；`this.trigger('progress', this.request, { loaded: receivedBytes, total: responseBodyLength })`；`switch (this.request.responseType) { case 'json': … case 'arraybuffer': … case 'blob': … }` |
| I5 | [src/interceptors/ClientRequest/index.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/ClientRequest/index.ts#L18-L77) | `patchesRegistry.applyPatch(http, 'ClientRequest', (ClientRequest) => new Proxy(ClientRequest, { construct(target, args, newTarget) { return runInRequestContext(() => Reflect.construct(target, args, newTarget), requestLogger) } }))`；`patchesRegistry.applyPatch(https, 'request', …)` |
| I6 | [src/interceptors/net/index.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/net/index.ts#L203-L225) | `Intercept connections at the "net.Socket.prototype.connect" level instead of patching the "net.connect()" module function. ESM consumers snapshot the module bindings at import time…`；`const passthroughSocket = new net.Socket(socketOptions)` |
| I7 | [src/interceptors/http/source.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptors/http/source.ts#L37-L45) | `Interceptor for HTTP requests in Node.js. Routes socket connections through an HTTP parser.` |
| I8 | [discoveries/architecture.md](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/discoveries/architecture.md) | `Browser clients \| fetch/web and XMLHttpRequest/web intercept at the API boundary and implement response/event behavior there. Node's socket mechanism does not apply.`；`passthrough -> real connection; flush buffered writes; forward real events/data` |
| I9 | [src/utils/handle-request.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/utils/handle-request.ts#L216-L222) | `// If the request hasn't been handled by this point, passthrough.`；`await options.controller.respondWith(createServerErrorResponse(resultError))` |
| I10 | [src/utils/fetch-utils.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/utils/fetch-utils.ts#L140-L260) | `Undici keeps an internal "Symbol(state)" that holds the actual value of response status. Update that in Node.js.`；`Object.defineProperty(response, 'url', { value: url, enumerable: true, configurable: true, writable: false })` |
| I11 | [src/utils/patches-registry.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/utils/patches-registry.ts#L1-L60) | `Object.defineProperty(owner, key, { value: getNextValue(owner[key]), enumerable: true, configurable: true })`；`public restoreAllPatches(): void` |
| I12 | [src/utils/create-proxy.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/utils/create-proxy.ts#L70-L80) | `@note Using "Reflect.get()" here causes "TypeError: Illegal invocation".` |
| I13 | [src/utils/clone-response.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/utils/clone-response.ts) | `/** Clone for observers without letting their unread body block caller cancellation. */` |
| I14 | [src/interceptor.ts](https://github.com/mswjs/interceptors/blob/49d7901772d5c07b71d75b7470a2562ef28c3755/src/interceptor.ts#L18-L95) | `static singleton<T extends Interceptor<any>>(InterceptorClass: (new () => T) & { symbol: symbol }): T`；`if (this.readyState !== InterceptorReadyState.ACTIVE && !this.predicate()) { return }` |

### 9.3 msw 官方文档（mswjs.io 仓库 commit `610762537b2d672fc6820ac27ce1c00a1e41a4a3`）

| # | 页面 | 原文摘录 |
|---|---|---|
| D1 | [docs/index.md](https://github.com/mswjs/mswjs.io/blob/610762537b2d672fc6820ac27ce1c00a1e41a4a3/src/content/docs/index.md) | `Mock Service Worker (MSW) is an API mocking library for browser and Node.js. It helps you intercept, observe, and affect the network of your application.`；`MSW uses the Service Worker API to intercept actual production requests on the network level. Instead of patching fetch and meddling with your application's integrity, MSW bets on the platform…` |
| D2 | [guides/integrations/browser.md](https://github.com/mswjs/mswjs.io/blob/610762537b2d672fc6820ac27ce1c00a1e41a4a3/src/content/guides/integrations/browser.md) | `If your application registers a Service Worker it must host and serve it.`；`Although Service Workers are meant to be served via HTTPS, browsers allow registering workers on HTTP while developing on localhost.` |
| D3 | [api/setup-worker/start.md](https://github.com/mswjs/mswjs.io/blob/610762537b2d672fc6820ac27ce1c00a1e41a4a3/src/content/api/setup-worker/start.md) | `Keep in mind that a Service Worker can only control the network from the clients (pages) hosted at its level or down. You likely always want to register the worker at the root.` |
| D4 | [guides/recipes/merging-service-workers.md](https://github.com/mswjs/mswjs.io/blob/610762537b2d672fc6820ac27ce1c00a1e41a4a3/src/content/guides/recipes/merging-service-workers.md) | `The browser can only register a single Service Worker per scope. This means that if your application already registers a Service Worker, it cannot register another one for MSW in parallel.` |
| D5 | [docs/limitations.md](https://github.com/mswjs/mswjs.io/blob/610762537b2d672fc6820ac27ce1c00a1e41a4a3/src/content/docs/limitations.md) | `This library uses the Service Worker API to intercept requests in the browser. Any limitations of that API or any limitations of its implementation in individual browsers are transitively inherited by MSW.`；`The Service Worker API translates all outgoing requests on the page to Fetch API requests. Those, sadly, do not have a concept of request progress…`；`Firefox does not notify the worker when an XMLHttpRequest happens on the page.`；`Due to technical limitations, MSW cannot intercept requests performed via direct net.connect()/net.createConnection() calls.`；`Mock Service Worker positions itself as a development tool` |
| D6 | [api/passthrough.md](https://github.com/mswjs/mswjs.io/blob/610762537b2d672fc6820ac27ce1c00a1e41a4a3/src/content/api/passthrough.md) | `Unlike bypass(), the passthrough() function does not result in an additional request…` |
| D7 | [api/bypass.md](https://github.com/mswjs/mswjs.io/blob/610762537b2d672fc6820ac27ce1c00a1e41a4a3/src/content/api/bypass.md) | `Requests performed via bypass() will never be intercepted, even if there are otherwise matching request handlers present in the network description.` |
| D8 | [docs/http/mocking-responses/streaming.md](https://github.com/mswjs/mswjs.io/blob/610762537b2d672fc6820ac27ce1c00a1e41a4a3/src/content/docs/http/mocking-responses/streaming.md) | `You can respond to the intercepted request with a stream of data by constructing a ReadableStream instance and providing it as the body of a mocked response.` |
| D9 | [blog/introducing-msw-3.0.md](https://github.com/mswjs/mswjs.io/blob/610762537b2d672fc6820ac27ce1c00a1e41a4a3/src/content/blog/introducing-msw-3.0.md) | `The new architecture of Interceptors doesn't patch request clients, or internal classes, or agents.`；`Moving the interception any lower would require recompiling Node.js.`；`Starting since v3.0, MSW is ESM-only.` |
| D10 | [api/cli/init.md](https://github.com/mswjs/mswjs.io/blob/610762537b2d672fc6820ac27ce1c00a1e41a4a3/src/content/api/cli/init.md) | `A relative path to the public directory of your application.`（`npx msw init ./public`） |

线上页面（同内容，便于直接引用；2026-10-06 实测均 `200`）：<https://mswjs.io/docs>、<https://mswjs.io/docs/limitations>、<https://mswjs.io/api/setup-worker/start>、<https://mswjs.io/guides/integrations/browser>、<https://mswjs.io/api/passthrough>、<https://mswjs.io/api/bypass>、<https://mswjs.io/guides/recipes/merging-service-workers>、<https://mswjs.io/api/cli/init>（`/docs/...` 前缀形式会 301 到上述规范地址）

### 9.4 规范 / MDN / Chromium / Chrome 平台文档

| # | 来源 | 原文摘录 |
|---|---|---|
| P1 | [Service Worker spec（w3c.github.io/ServiceWorker）](https://w3c.github.io/ServiceWorker/) | Register 算法：`If job's script url's origin and job's referrer's origin are not same origin, then: Invoke Reject Job Promise with job and "SecurityError" DOMException.`；`If job's scope url's origin and job's referrer's origin are not same origin, then: Invoke Reject Job Promise with job and "SecurityError" DOMException.` |
| P2 | 同上（scope 路径限制） | `service workers are restricted by the path of the service worker script. For example, a service worker script at https://www.example.com/~bob/sw.js can be registered for the scope url https://www.example.com/~bob/ but not for the scope https://www.example.com/ or https://www.example.com/~alice/.` |
| P3 | 同上（Match Service Worker Registration） | `Set matchingScopeString to the longest value in scopeStringSet which the value of clientURLString starts with, if it exists.`；`Note: The URL string matching in this step is prefix-based rather than path-structural.` |
| P4 | 同上（Handle Fetch） | `Assert: request's destination is not "serviceworker".`；`If request's destination is either "embed" or "object", then: Return null.`；`Else if request is a subresource request, then: If client's active service worker is non-null, set registration to client's active service worker's containing service worker registration. Else, return null.` |
| P5 | [Fetch spec（fetch.spec.whatwg.org）](https://fetch.spec.whatwg.org/) | `A request has an associated service-workers mode, that is "all" or "none". Unless stated otherwise it is "all". This determines which service workers will receive a fetch event for this fetch.`；HTTP fetch：`If request's service-workers mode is "all", then: Let requestForServiceWorker be a clone of request.` |
| P6 | 同上（SW 内 fetch 不再进 SW） | `The fetch(input, init) method steps are: … Let globalObject be request's client's global object. If globalObject is a ServiceWorkerGlobalScope object, then set request's service-workers mode to "none".` |
| P7 | 同上（no-cors/opaque） | `"no-cors" — Restricts requests to using CORS-safelisted methods and CORS-safelisted request-headers. Upon success, fetch will return an opaque filtered response.`；`An opaque filtered response is a filtered response whose type is "opaque", URL list is « », status is 0, status message is the empty byte sequence, header list is « », body is null, and body info is a new response body info.`；`Set response to the following filtered response with response as its internal response, depending on request's response tainting: … "opaque" → opaque filtered response` |
| P8 | [MDN ServiceWorkerContainer.register()](https://developer.mozilla.org/en-US/docs/Web/API/ServiceWorkerContainer/register) | `SecurityError DOMException — The scriptURL is not a potentially trustworthy origin, such as localhost or an https URL. The scriptURL and scope are not same-origin with the registering page.`；`A service worker can't have a scope broader than its own location, unless the server specifies a broader maximum scope in a Service-Worker-Allowed header on the service worker script.`；`The default scope for a service worker registration is the directory where the service worker script is located.` |
| P9 | [MDN ServiceWorkerGlobalScope: fetch event](https://developer.mozilla.org/en-US/docs/Web/API/ServiceWorkerGlobalScope/fetch_event) | `The fetch event … is fired in the service worker's global scope when the main app thread makes a network request. This includes not only explicit fetch() calls from the main thread, but also implicit network requests to load pages and subresources (such as JavaScript, CSS, and images) made by the browser following page navigation.` |
| P10 | [Chromium: third_party/blink/renderer/modules/service_worker/service_worker_container.cc](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/third_party/blink/renderer/modules/service_worker/service_worker_container.cc) | `if (!document_origin->CanRequest(script_url)) { … "Failed to register a ServiceWorker: The origin of the provided scriptURL ('…') does not match the current origin ('…')." }`；`if (!SchemeRegistry::ShouldTreatURLSchemeAsAllowingServiceWorkers(page_url.Protocol())) { … "The URL protocol of the current origin ('…') is not supported." }` |
| P11 | [Chromium: extensions/renderer/dispatcher.cc](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/renderer/dispatcher.cc) | `// chrome-extension: resources should be allowed to register ServiceWorkers.` + `WebSecurityPolicy::RegisterURLSchemeAsAllowingServiceWorkers(extension_scheme);` |
| P12 | [Chrome DevTools Network reference（Timing）](https://developer.chrome.com/docs/devtools/network/reference) | `ServiceWorker Preparation. The browser is starting up the service worker.`；`Request to ServiceWorker. The request is being sent to the service worker.`；`Content Download. The browser is receiving the response, either directly from the network or from a service worker.` |
| P13 | [CDP browser_protocol.json（Network.Response）](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/browser_protocol.json) | `fromServiceWorker: "Specifies that the request was served from the ServiceWorker."`；`serviceWorkerResponseSource: "Response source of response from ServiceWorker."`（枚举 `cache-storage/http-cache/fallback-code/network`）；`Network.setBypassServiceWorker: "Toggles ignoring of service worker for each request."` |
| P14 | [CDP Fetch domain](https://chromedevtools.github.io/devtools-protocol/tot/Fetch/) | `A domain for letting clients substitute browser's network layer with client code.`；`enable: Enables issuing of requestPaused events. A request will be paused until client calls one of failRequest, fulfillRequest or continueRequest/continueWithAuth.`；`fulfillRequest: Provides response to the request.` |
| P15 | [Chrome 扩展文档：Cross-origin network requests](https://developer.chrome.com/docs/extensions/develop/concepts/network-requests) | `Content scripts initiate requests on behalf of the web origin that the content script has been injected into and therefore content scripts are also subject to the same origin policy. Extension origins aren't so limited.` |
| P16 | [Chrome 扩展文档：Content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts) | `Content scripts live in an isolated world, allowing a content script to make changes to its JavaScript environment without conflicting with the page or other extensions' content scripts.`；`An isolated world is a private execution environment that isn't accessible to the page or other extensions.` |
| P17 | [Chrome 扩展文档：Extension service workers basics](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/basics) | `Service workers in web pages or web apps register service workers by first feature-detecting for serviceWorker in navigator then calling register() inside feature detection. This does not work for extensions.` |
| P18 | [Chrome 扩展文档：chrome.scripting（ExecutionWorld）](https://developer.chrome.com/docs/extensions/reference/api/scripting) | `"MAIN" — Specifies the main world of the DOM, which is the execution environment shared with the host page's JavaScript.` |
| P19 | [Chrome 扩展文档：declarativeNetRequest](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest) | `A declarativeNetRequest only applies to requests that reach the network stack. This includes responses from the HTTP cache, but may not include responses that go through a service worker's onfetch handler.`；`A declarativeNetRequest rule cannot redirect from a public resource request to a resource that is not web accessible.`；`The following example shows how to redirect a request from example.com to a page within the extension itself… For this to work the manifest should declare /a.jpg as a web accessible resource.`（`"redirect": { "extensionPath": "/a.jpg" }`） |
| P20 | [Chrome 扩展文档：chrome.debugger](https://developer.chrome.com/docs/extensions/reference/api/debugger) | `The chrome.debugger API serves as an alternate transport for Chrome's remote debugging protocol. Use chrome.debugger to attach to one or more tabs to instrument network interaction…`；`You must declare the "debugger" permission in your extension's manifest to use this API.`；`Fired when browser terminates debugging session for the tab. This happens when either the tab is being closed or Chrome DevTools is being invoked for the attached tab.`（附带 CDP Fetch 域见 P14：可用于统一拦截/伪造响应，但需要 `debugger` 权限；**是否存在"调试横幅"提示未找到官方表述，见 §8**） |

### 9.5 版本与社区数据（2026-10-06 抓取）

| # | 数据 | 命令/来源 | 结果 |
|---|---|---|---|
| M1 | msw dist-tags / 最新版 | `curl -s https://registry.npmjs.org/msw` | `latest: 3.0.2`（2026-10-03）；历史版本数 340；`license: MIT` |
| M2 | msw 近 6 个月发布 | 同上 `time` 字段 | 19 个版本：2.13.0 (2026-04-06) … 2.15.0 (2026-07-08)、**3.0.0 (2026-09-28)**、3.0.1 (2026-09-30)、3.0.2 (2026-10-03) |
| M3 | msw 下载量 | `curl -s https://api.npmjs.org/downloads/point/last-week/msw` / `last-month/msw` | week: `{"downloads":26798820,"start":"2026-09-28","end":"2026-10-04"}`；month: `{"downloads":87549356,"start":"2026-09-05","end":"2026-10-04"}` |
| M4 | @mswjs/interceptors | `curl -s https://registry.npmjs.org/@mswjs%2finterceptors` + downloads API | `latest: 0.45.7`（2026-10-04）；week `28432828`、month `93854910` |
| M5 | GitHub 页面数据 | `https://github.com/mswjs/msw`（HTML，API 限流） | `18.3k stars / 629 forks / 12 Issues / 1 Pull requests`；LICENSE: MIT |
| M6 | GitHub 页面数据（interceptors） | `https://github.com/mswjs/interceptors`（HTML） | `689 stars / 7 watching / 175 forks`；MIT license |
| M7 | 交叉核对徽章 | `https://img.shields.io/github/stars/mswjs/msw.json`、`.../contributors/...`、`.../issues/...`、`.../last-commit/...` | stars `18k`、contributors **172**（仅徽章数据）、issues `12 open`、last commit `yesterday`；interceptors contributors **71** |
| M8 | 本地仓库 HEAD | `git log -1`（/tmp/msw、/tmp/interceptors、/tmp/docs-site） | msw `501a591640648c86b9733167eab7d29339671eec` 2026-10-05；interceptors `49d7901772d5c07b71d75b7470a2562ef28c3755` 2026-10-04（`chore(release): v0.45.7`）；docs `610762537b2d672fc6820ac27ce1c00a1e41a4a3` 2026-10-05 |
