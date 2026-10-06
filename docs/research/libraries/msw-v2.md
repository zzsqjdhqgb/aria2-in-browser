# mswjs/msw（Mock Service Worker）独立调研 — v2

> 本文是**独立复调**产物。调研者**未阅读**同目录下的 `msw.md`，也未与其对照；全部结论来自一手来源（仓库源码 / 官方文档源码 / 规范 / 运行时实验）。两份产物由项目负责人对照。
>
> 面向的裁定基准：`/workspace/docs/concept-design/concept-design.md` 的 **R4**（转发器：多途径 × 多来源）、**R5**（内置 UI 不得走特殊通道）、**R9**（拦截在 JS API 层）、**R10**（伪装还原 = 结果兑现）。

---

## 0 元信息

### 0.1 调研日期

**2026-10-06（UTC）**，取证窗口 10:13Z – 11:0xZ。所有"最近 N 天/月"的统计以此为基准。

### 0.2 所依据的版本（全部固定到 tag 或 commit）

| 对象 | 版本 | 标识 | 备注 |
|---|---|---|---|
| `mswjs/msw` | **v3.0.2** | tag `v3.0.2`；克隆 HEAD `501a591640648c86b9733167eab7d29339671eec`（= `v3.0.2-1-g501a5916`，比 tag 多 1 个 commit） | 该多余 commit 只改了 `media/github-social-preview.png`（`git diff --stat v3.0.2..HEAD` 仅此一文件），源码等价于 v3.0.2 |
| `msw` npm 包 | **3.0.2** | 发布 2026-10-03T01:31:45.411Z | registry `dist-tags.latest` |
| `mswjs/interceptors` | **v0.45.7** | tag `v0.45.7`；克隆 HEAD `49d7901772d5c07b71d75b7470a2562ef28c3755`（HEAD == tag，`git describe --tags --exact-match` = `v0.45.7`） | 精确对齐 |
| `@mswjs/interceptors` npm 包 | **0.45.7** | 发布 2026-10-04T02:29:47.097Z | msw 3.0.2 声明 `^0.45.6`，落在范围内 |
| `mswjs/mswjs.io`（官方文档站源码） | main | HEAD `610762537b2d672fc6820ac27ce1c00a1e41a4a3`，2026-10-05 | 用于"官方文档原文" |
| Service Workers 规范 | **W3C 编辑草案**（活标准，非 WHATWG） | <https://w3c.github.io/ServiceWorker/> | 本次拉取。注：任务提示中的 `https://service-worker-speci.netlify.app/` **返回 HTTP 404**（镜像不存在），故改用 W3C 官方草案 |

**为什么要盯 msw 3.0.2**：v3.0.0 于 **2026-09-28** 落地（`2bb43428 feat!: v3.0.0 (#2692)`，`!` 表示 breaking），距离调研日仅 8 天。v2 时代的架构描述（`SetupWorkerApi` / `SetupServerApi` 直接 new 拦截器）**在 v3 已不存在**，本文一律以 v3.0.2 为准。

### 0.3 用到的取证通道及成功率

| # | 通道 | 结果 | 说明 |
|---|---|---|---|
| 1 | **完整 git 克隆**（`git clone` 无 `--depth`） | ✅ 成功 | `msw` 316 个 tag / 1802 commit；`interceptors` 250 个 tag / 875 commit。拿到全部 tag、commit、作者、日期 |
| 2 | `raw.githubusercontent.com` | ✅ 成功 | 用于按 tag 取 LICENSE 等 |
| 3 | **npm registry HTTP API**（`registry.npmjs.org`） | ✅ 成功 | 全部 4 个文档 HTTP 200；拿到 dist-tags / 全版本 / 发布时间 / 依赖 / 体积 |
| 4 | **npm downloads API** | ✅ 成功 | 周/月/日下载量 |
| 5 | **unpkg**（发布产物本体） | ✅ 成功 | **关键**：直接读 `@mswjs/interceptors@0.45.7/lib/node/index.js` 的 export 列表，绕开"源码 ≠ 发布物"的疑虑 |
| 6 | **本地 `npm install` + 运行时实验** | ✅ 成功 | Node v24.21.0 下装 `msw@3.0.2` + `@mswjs/interceptors@0.45.7`，实跑 4 组实验（见 §7、§4.5） |
| 7 | GitHub 仓库页面 HTML 抓取 | ✅ 成功 | star/fork/watcher/open-issue 计数（页面内嵌 JSON + `Counter` 元素） |
| 8 | `github.com/.../releases.atom` | ✅ 成功 | 两个仓库各 10 条 release 正文 |
| 9 | W3C Service Workers 规范 / MDN / Chrome 开发者文档 | ✅ 成功 | 用于 §3 / §6 的平台约束 |
| 10 | GitHub **issue 页面 HTML**（内嵌 JSON） | ✅ 成功 | 逐字核到 issue #23 / #2667 / #346 的标题、评论正文与浏览器报错原文（§6.2 ⑦） |
| 11 | **GitHub REST API** | ❌ **失败（HTTP 403，硬限流）** | `x-ratelimit-limit: 60`、`x-ratelimit-remaining: 0`、`x-ratelimit-reset: 1791284244`（= 2026-10-06 10:57:24Z）。`/repos/*`、`/contributors`、`/subscribers` 全部 403，且 403 响应**不带 `Link` 头**（所以拿不到 contributor 总数）。环境中无 `GH_TOKEN`/`GITHUB_TOKEN` |
| 12 | `github.com/<repo>/watchers` 页面 | ❌ 失败（HTTP 404） | 该路由已移除 |
| 13 | MSW 官方文档站渲染页 | ⚠️ 未用 | 改用**文档站源码仓库**（通道 1 的子集），可拿到逐行原文，比抓渲染页更硬 |

> **上一次调研的限流问题本次已解除影响**：通道 1/5/6 三条互相独立的硬通道取代了 GitHub API —— 版本、活跃度、发布物导出面全部坐实，且比 API 更精确（API 给不出"tag 与 HEAD 差 1 个 commit"这种细节）。

### 0.4 调研充分度自评

| 题目要求 | 自评 | 依据 |
|---|---|---|
| 1. 是什么 / 解决什么 / 面向什么场景 | **充分** | 官方文档源码 + 包元数据 + v3 架构源码 |
| 2. 实现原理（SW 路线 + JS 层路线，带源码位置） | **充分** | 460 行 worker 模板全文 + 浏览器/Node 两套拦截器源码逐行；SW 注册链路 `setup-worker → ServiceWorkerSource → getWorkerInstance → navigator.serviceWorker.register` 完整读出 |
| 3. SW 路线前提条件与边界 | **较充分** | 规范原文 + 官方文档 + `validate-worker-scope.ts` 等实现。少数条目标为存疑（§9.4/9.5） |
| 4. JS 层拦截技术细节 | **充分** | fetch/XHR/Node socket 三路源码 + 4 组运行时实验 |
| 5. 能否借鉴 | **充分（含判断）** | 逐条落到 R4/R5/R9/R10 的哪一层 |
| 6. 能否直接使用（MV3 拦任意页面） | **充分** | 规范硬约束 + 实现证据 + 替代路径；结论"不能"有规范级证据 |
| 7. 文档 vs 源码不一致 | **充分** | 找到 **6 处**（2 处强 + 4 处附带），其中 **2 处有运行时实证**、**3 处有发布产物复核**；含 1 处**行为性失效**（§7.6） |
| 8. 许可证 / 维护 / 成熟度 | **充分** | 全 git 历史 + registry + 页面抓取；GitHub API 的缺口已标注 |
| 9. 未验证 / 存疑 | 已单列 | 12 条 |

**最大不确定性**：`mswjs.io` 站点源码的"官方文档"身份 —— 它是 `mswjs` 组织下的官方文档仓库，但活站渲染是否与 main 完全一致未逐页比对（§9.6）。另外浏览器侧行为（`Response.type`、MAIN world 注入受不受页面 CSP 限制）只能靠仓库自带测试断言与 Chrome 文档措辞，**本机无浏览器**（§9.2/9.7）。

---

## 1 它是什么

### 1.1 一句话

**MSW（Mock Service Worker）是一个"开发期 API mock 库"**，不是网络代理、不是下载器、更不是"拦截任意页面"的工具。它让你在**你自己的应用**里声明"哪些请求返回什么响应"，而不改动应用的请求代码。

官方定义（`docs-io/src/content/docs/index.md:6`）：

> Mock Service Worker (MSW) is an API mocking library for browser and Node.js. It helps you intercept, observe, and affect the network of your application.

`msw/package.json:4` 的 description 更直白：`"The industry standard for API mocking in JavaScript."`

### 1.2 解决什么问题

三个诉求（README 的 Features 段）：

1. **对应用代码透明** —— 应用不知道自己被 mock 了（`index.md:8` "creates a truly seamless API mocking experience"）。
2. **跨环境复用同一份 mock 定义** —— 浏览器开发、Node 单测、Storybook、E2E 都能用同一组 handler（`index.md:14, 24`）。
3. **"偏离最小化"** —— 尽量不 monkey-patch 请求客户端，让代码跑在接近生产的环境里（`index.md:18`）。

第 3 点是 MSW 的**核心卖点**，也是它与 `nock` / `cy.intercept` / 手写 `fetch` stub 的分野（`docs/comparison.md`）。

### 1.3 面向什么场景（**关键定性**）

| 场景 | 是否目标 |
|---|---|
| 前端开发时后端没准备好 / 想造边界数据 | ✅ |
| 单元/集成测试里替掉外部 API | ✅ |
| Storybook / 组件预览 / 演示 | ✅ |
| **拦截"别人的网站"的请求** | ❌ **完全不是目标**，且平台层面做不到（见 §6） |
| 生产运行时长期挂载 | ❌ 反模式（见 §8.4） |

**MSW 的隐含前提是"你是这个应用的主人"**：它要求你把 `mockServiceWorker.js` 放进**你自己应用**的 public 目录、由**你自己的服务器**伺服（`guides/best-practices/managing-the-worker.md:32-34`）。这条前提正是 §6 结论的根基。

### 1.4 包结构与依赖关系

```
msw@3.0.2  ──依赖──▶  @mswjs/interceptors@^0.45.6  （实际解析到 0.45.7）
（高层：handler 匹配、响应解析、SW 编排、CLI、Vite 插件）
                  （低层：真正干活的网络拦截）
```

- `msw/package.json:143`：`"@mswjs/interceptors": "^0.45.6"`（**caret 范围，非 pin**）。仓库自带 `pnpm-lock.yaml` 锁的是 0.45.6。
- `@mswjs/interceptors` 自我定位（README:3）："Low-level network interception library for Node.js."，且 README:52 明说：**"Interceptors is **not** an API mocking library."** 它存在的目的是"让别的开发者写自己的高层 mock 库"（README:54）。

### 1.5 v3 的架构（与 v2 完全不同的地方，必须知道）

v3.0.2 **没有** `SetupWorkerApi` / `SetupServerApi` 这两个类了。取而代之的是 **NetworkSource** 抽象（`src/core/experimental/`）：

| 类 | 文件 | 作用 |
|---|---|---|
| `NetworkSource` | `src/core/experimental/sources/network-source.ts` | 基类，"网络从哪来" |
| `ServiceWorkerSource` | `src/browser/sources/service-worker-source.ts` | 浏览器主路线：Service Worker |
| `FallbackHttpSource` | `src/browser/sources/fallback-http-source.ts:10-15` | **浏览器备胎**：不支持 SW 时改用 JS 层 patch |
| `InterceptorSource` | `src/core/experimental/sources/interceptor-source.ts` | 把 `BatchInterceptor` 包成 source |

浏览器侧编排（`src/browser/setup-worker.ts:51-76`）：

```ts
const httpSource = supportsServiceWorker()
  ? await ServiceWorkerSource.from({ /* … */ })
  : new FallbackHttpSource({ quiet: options?.quiet })

network.configure({
  sources: [
    httpSource,
    new InterceptorSource({ interceptors: [new WebSocketInterceptor()] }),
  ],
  onUnhandledFrame: options?.onUnhandledFrame ?? 'warn',
  // …
})
```

读法：**浏览器里 HTTP 走 Service Worker（或 fallback），WebSocket 永远走 JS 层拦截器**。

Node 侧（`src/node/setup-server.ts:16-21`）：

```ts
const defaultInterceptors: Array<Interceptor<any>> = [
  new ClientRequestInterceptor(),
  new XMLHttpRequestInterceptor(),
  new FetchInterceptor(),
  new WebSocketInterceptor(),
]
```

全部经由 `InterceptorSource` → `BatchInterceptor`（`interceptor-source.ts:43-60`）。**没有用** `HttpRequestInterceptor` / `SocketInterceptor`（后面 §7 会看到这很重要）。

---

## 2 实现原理

MSW 有**两条完全不同的拦截路线**。必须分开讲，否则会得出错误结论。

### 2.1 路线 A：浏览器 Service Worker（主路线）

#### 2.1.1 `mockServiceWorker.js` 是怎么"装上去"的

**它不是构建产物，是一个手写的模板文件**，位于 `msw/src/mockServiceWorker.js`（460 行，`msw` 仓库内），构建时被处理并拷到 `lib/mockServiceWorker.js`。

处理插件是 `config/plugins/rolldown/copy-worker-plugin.ts:8-14, 23-48, 50-77`，它做了两件事：

```ts
const SERVICE_WORKER_ENTRY_PATH = url.fileURLToPath(
  new URL('../../../src/mockServiceWorker.js', import.meta.url))
const SERVICE_WORKER_OUTPUT_PATH = url.fileURLToPath(
  new URL('../../../lib/mockServiceWorker.js', import.meta.url))
// …
/**
 * Compute the integrity checksum of the worker script.
 * The script is normalized before hashing so that cosmetic changes
 * (comments, including legal ones, and whitespace) do not invalidate
 * the checksum. Compression and mangling are disabled to keep the
 * checksum stable across minifier updates.
 */
export async function getWorkerChecksum(): Promise<string> {
  const bundle = await Rolldown.rolldown({ input: SERVICE_WORKER_ENTRY_PATH, platform: 'browser', treeshake: false })
  const { output } = await bundle.generate({ format: 'iife', comments: false,
    minify: { compress: false, mangle: false, codegen: { removeWhitespace: true } } })
  return crypto.createHash('md5').update(chunk.code, 'utf8').digest('hex')
}
```

即：**对脚本做"去注释/去空白"的归一化后算 MD5**，再把该值（连同包版本）替换进模板里的 `PACKAGE_VERSION` / `INTEGRITY_CHECKSUM` 占位符（`src/mockServiceWorker.js:10-11`），最后暴露为 `package.json` 的 `"./mockServiceWorker.js": "./lib/mockServiceWorker.js"`。

这个 checksum 的用途在 §2.1.1 的注册流程里：页面 `start()` 时向 worker 发 `INTEGRITY_CHECK_REQUEST`，worker 回 `{ packageVersion, checksum }`；不一致就打印"当前注册的 worker 脚本是另一个 msw 版本生成的，可能不完全兼容"（`service-worker-source.ts:406-433`）。**这是一个很值得借鉴的"客户端/注入物版本对齐"机制。**

**装到用户项目**：`npx msw init <PUBLIC_DIR>`（`docs/api/cli/init.md:17`）把该文件**拷进用户应用的静态目录**。加 `--save` 会把目录记进 `package.json` 的 `msw.workerDirectory`，以后每次装包自动同步（`init.md:57`）。

**装到浏览器**（运行时注册链路）：

1. 用户调 `worker.start()` → `setupWorker` 的 `start`（`src/browser/setup-worker.ts:43`）
2. → `supportsServiceWorker()`（`src/browser/utils/supports.ts:5-12`）
3. → `ServiceWorkerSource.from()` → `#startWorker()`（`service-worker-source.ts:212`）
4. → `getWorkerInstance(url, options, findWorker)`（`service-worker-source.ts:219-223`）
5. → **`navigator.serviceWorker.register(url, options)`**（`src/browser/utils/get-worker-instance.ts:59`）

```ts
// get-worker-instance.ts:54-66
// When the Service Worker wasn't found, register it anew and return the reference.
const [registrationError, registrationResult] = await until<
  Error,
  ServiceWorkerInstanceTuple
>(async () => {
  const registration = await navigator.serviceWorker.register(url, options)
  return [
    getWorkerByRegistration(registration, absoluteWorkerUrl, findWorker),
    registration,
  ]
})
```

**这就是全部。注册走的是标准 `navigator.serviceWorker.register()`，没有任何扩展特权、没有任何绕过。** 因此 §3 的全部平台约束原样继承。

注册后：

- worker 的 `install` 事件里 `self.skipWaiting()`（`mockServiceWorker.js:20-22`）
- `activate` 里 `event.waitUntil(self.clients.claim())`（`:24-26`）—— **立刻接管已打开的页面**
- 页面侧 `ServiceWorkerSource.enable()` 等 worker 到 `activated`，然后 `postMessage('MOCK_ACTIVATE')`，并等 `MOCKING_ENABLED` 回执（`service-worker-source.ts:112-155`）
- 注册后若 `!navigator.serviceWorker.controller` 但已有匹配注册 → `location.reload()`（`get-worker-instance.ts:26-34`，硬刷新场景的自我修复）
- 每 5 秒发 `KEEPALIVE_REQUEST`（`service-worker-source.ts:293-295`）—— 应对 SW 生命周期不可靠
- `stop()` 时发 `CLIENT_CLOSE`，无剩余 client 时 **worker 自己 `self.registration.unregister()`**（`mockServiceWorker.js:56-59`）

#### 2.1.2 worker 脚本内部：它凭什么是"位置正确"的

`mockServiceWorker.js` 只注册 4 类监听器：

| 行 | 监听器 | 作用 |
|---|---|---|
| 20-22 | `install` | `skipWaiting()` |
| 24-26 | `activate` | `clients.claim()` |
| 28-120 | `message` | `KEEPALIVE_REQUEST` / `INTEGRITY_CHECK_REQUEST` / `MOCK_ACTIVATE` / `CLIENT_CLOSE` |
| **122-141** | **`fetch`** | **拦截本体** |

```js
// mockServiceWorker.js:122-141
addEventListener('fetch', function (event) {
  // Opening the DevTools triggers the "only-if-cached" request
  // that cannot be handled by the worker. Bypass such requests.
  if (
    event.request.cache === 'only-if-cached' &&
    event.request.mode !== 'same-origin'
  ) {
    return
  }

  // Bypass all requests when there are no active clients.
  if (activeClientIds.size === 0) {
    return
  }

  const requestId = crypto.randomUUID()
  event.respondWith(handleRequest(event, requestId))
})
```

**为什么"能拦到页面的请求"**：Service Worker 一旦 `claim()` 了页面，页面的**所有** fetch（包括 `fetch()`、`XMLHttpRequest`、`<img>`、`<script>`、导航）都会先在 SW 的 `fetch` 事件里过一遍。这是平台保证，不是 MSW 的技巧。

**SW 处在什么位置**：它**不在页面的 JS realm 里**，而是同源下的一个独立 worker 线程。这是个决定性的架构事实 —— 后面 §6 的结论直接来自它。

#### 2.1.3 请求如何从 worker 交回页面（MSW 自研的私有协议）

SW 里没有用户的 handler，handler 在页面里。所以 MSW 自己在两者之间搭了一条 **RPC 通道**：

```js
// mockServiceWorker.js:277-360（节选）
async function getResponse(event, client, requestId) {
  const requestClone = event.request.clone()

  // ① 未激活 → 直接放行
  if (!client) { return passthrough() }
  if (!activeClientIds.has(client.id)) { return passthrough() }

  // ② 把请求序列化后发给主 client，并转移请求体的 ReadableStream
  const serializedRequest = await serializeRequest(event.request)
  const clientMessage = await sendToClient(
    client,
    { type: 'REQUEST', payload: { id: requestId, ...serializedRequest } },
    [serializedRequest.body],
  )

  // ③ 等页面回话
  switch (clientMessage.type) {
    case 'MOCK_RESPONSE': return respondWithMock(clientMessage.data, event)
    case 'PASSTHROUGH':   return passthrough(clientMessage.data)
  }
  return passthrough()
}
```

`sendToClient` 用 **`MessageChannel` + `client.postMessage(message, [port2, ...transferables])`**（`:386-403`），并把 **`ReadableStream` 作为 Transferable 直接转移**（这是 MSW 的一个硬核细节，浏览器需支持 stream transfer，`supports.ts:19-30` 有特性探测）。

页面侧对应的协议在 `src/browser/utils/worker-channel.ts:7-23`：

```ts
export type WorkerChannelEventMap = {
  REQUEST: WorkerEvent<IncomingWorkerRequest>
  RESPONSE: WorkerEvent<IncomingWorkerResponse>
  REQUEST_ERROR: WorkerEvent<IncomingWorkerRequestError>
  MOCKING_ENABLED: WorkerEvent<{ client: { id: string; frameType: string } }>
  CLIENT_CLOSED: TypedEvent<never>
  INTEGRITY_CHECK_RESPONSE: WorkerEvent<{ packageVersion: string; checksum: string }>
  KEEPALIVE_RESPONSE: TypedEvent<never>
}
```

页面回话的两种结果（`worker-channel.ts:80-86`）：`MOCK_RESPONSE`（带响应体和可转移的 `ReadableStream`）或 `PASSTHROUGH`（带要改的请求头）。

#### 2.1.4 worker 如何合成它返回给页面的 `Response`

```js
// mockServiceWorker.js:410-439
async function respondWithMock(response, event) {
  // Setting response status code to 0 is a no-op.
  // However, when responding with a "Response.error()", the produced Response
  // instance will have status code set to 0. Since it's not possible to create
  // a Response instance with status code 0, handle that use-case separately.
  if (response.status === 0) {
    return Response.error()
  }

  let body = response.body

  // Buffer the streamed mocked response body for navigation requests.
  // The stream is transferred from the client that is being navigated
  // away from. Once the navigation commits, that client gets destroyed
  // and the stream will never complete, resulting in an empty document.
  // Buffering here keeps "event.respondWith()" pending (the navigation
  // cannot commit) until the entire body arrives from the client.
  if (event.request.mode === 'navigate' && body instanceof ReadableStream) {
    body = await new Response(body).arrayBuffer()
  }

  const mockedResponse = new Response(body, response)

  Reflect.defineProperty(mockedResponse, IS_MOCKED_RESPONSE, {
    value: true,
    enumerable: true,
  })

  return mockedResponse
}
```

三个要点：

1. **就是一个普通的 `new Response(body, response)`** —— 没有伪造 `Response` 子类，没有改原型。
2. **导航请求（`mode === 'navigate'`）必须把流缓冲成 ArrayBuffer**，否则导航提交后 client 被销毁、流永远不完成、页面空白。这是一个非常具体、非常真实的工程教训。
3. `IS_MOCKED_RESPONSE = Symbol('isMockedResponse')`（`:12`）用 `Reflect.defineProperty` 打在响应上，**唯一用途是向页面回报 `isMockedResponse: true`**（`:213`），不参与任何安全/信任判断。

#### 2.1.5 passthrough 在 SW 里怎么做

```js
// mockServiceWorker.js:285-320
function passthrough(data) {
  const headers = new Headers()
  const requestHeaders = data?.request?.headers
  // …用客户端给的 headers（反映 handler 里的修改），否则用原始 headers
  // Remove the "accept" header value that marked this request as passthrough.
  // This prevents request alteration and also keeps it compliant with the
  // user-defined CORS policies.
  const acceptHeader = headers.get('accept')
  if (acceptHeader) {
    const values = acceptHeader.split(',').map((v) => v.trim())
    const filteredValues = values.filter((v) => v !== 'msw/passthrough')
    if (filteredValues.length > 0) headers.set('accept', filteredValues.join(', '))
    else headers.delete('accept')
  }
  return fetch(requestClone, { headers })
}
```

**就是在 SW 里真的 `fetch()` 一次**，并且要把 MSW 自己塞进去的 `msw/passthrough` 标记从 `accept` 头里剥掉（成因见 §4.4 的 `bypass()`）。

#### 2.1.6 为什么被 SW 拦下的请求还能出现在 DevTools 的 Network 面板里

这是 MSW 反复宣传的一个特性，官方有一句权威表述（`docs-io/src/content/blog/why-use-mock-service-worker.md:27`）：

> Unlike the conventional request client stubbing, the Service Worker allows us to intercept requests _after_ they are being dispatched by your application. This means _after_ `window.fetch` is finished its business. **Such requests actually happen, are observable in the network traffic, and are responded to with mocks on the browser level. Your application doesn't even know there's a mocked API involved.**

同文 `:21` 作为反面对照：

> …when stubbing request clients, you are no longer making real requests. … You can see that by opening the Network tab in your DevTools and witness how empty and lonely it is while your application "communicates" with the mocked API.

`README` 里 Kent C. Dodds 的推荐语也印证："…not only could I still see the mocked responses in my DevTools…"。

**机理**：请求是由**页面的渲染进程**发起、**已经进入浏览器的网络栈**之后，才在 SW 的 `fetch` 事件里被 `respondWith()` 截走的。Network 面板记录的是"网络栈收到了一次请求"，而 `respondWith()` 只是决定这次请求的响应从哪来 —— 所以条目在。这与 `docs/websocket/event-logs.md:6` 形成鲜明对照：WebSocket 的 mock 走 JS 层，"won't appear as network entries in your browser's DevTools"。

> **对本项目的意义（提前点出）**：这正是 R9 与 SW 路线的**本质分歧**。R9 要求"命中规则后请求根本不会发到网络上"——SW 路线**做不到**这一点（请求确实发出去了，只是被本地截答）。所以 §6 的"借鉴 interceptors、不用 msw 的 SW"不是妥协，而是与 R9 严格一致的选择。

### 2.2 路线 B：`@mswjs/interceptors` 的 JS 层拦截

先给一个**必须先建立的认识**：v0.45.7 里 **Node 侧已经不是"JS API 层 patch"了，而是 TCP/TLS socket 层拦截**。这与旧版本（以及很多二手资料）的描述完全不同。

#### 2.2.1 浏览器侧：两个真正的 JS API patch

**`FetchInterceptor`（浏览器）** — `src/interceptors/fetch/web.ts`

```ts
// fetch/web.ts:26-37
export class FetchInterceptor extends Interceptor<HttpRequestEventMap> {
  static symbol = Symbol.for('fetch-interceptor')

  protected predicate() {
    return hasConfigurableGlobal('fetch')
  }

  protected async setup() {
    logger.verbose('patching global fetch...')
    this.subscriptions.push(
      patchesRegistry.applyPatch(globalThis, 'fetch', (realFetch) => {
        return async (input, init) => {
          // …（见下）
        }
      })
    )
  }
}
```

**拦截点 = 替换 `globalThis.fetch`**。请求进入 handler 时被构造成一个**普通 `Request`**（`fetch/web.ts:47-54`）：

```ts
const resolvedInput =
  typeof input === 'string' &&
  typeof location !== 'undefined' &&
  !URL.canParse(input)
    ? new URL(input, location.href)   // JSDOM 场景下解析相对 URL
    : input

const request = new Request(resolvedInput, init)
```

**`XMLHttpRequestInterceptor`（浏览器）** — `src/interceptors/XMLHttpRequest/web.ts:17-27`

```ts
protected setup() {
  logger.verbose('patching "XMLHttpRequest"...')
  this.subscriptions.push(
    patchesRegistry.applyPatch(globalThis, 'XMLHttpRequest', () => {
      return createXMLHttpRequestProxy({ emitter: this.emitter, logger })
    })
  )
}
```

**拦截点 = 替换 `globalThis.XMLHttpRequest` 构造函数本身**（不是 patch 原型方法）。替换物是一个 **Proxy**，只有 `construct` 陷阱（`xml-http-request-proxy.ts:22-53`），构造出真 XHR 实例后，把原型描述符逐个搬到实例上，再用 `createProxy` 包一层实例 Proxy，在实例层拦 `open` / `addEventListener` / `setRequestHeader` / `send`（`xml-http-request-controller.ts:77-199`）。

#### 2.2.2 `patchesRegistry`：patch 的统一入口

`src/utils/patches-registry.ts:6-39`

```ts
public applyPatch<Owner extends object, K extends keyof Owner>(
  owner: Owner, key: K, getNextValue: (realValue: Owner[K]) => Owner[K]
): () => void {
  const ownerReplacements = this.#replacements.get(owner)
  invariant(!ownerReplacements?.has(key),
    `Failed to replace a global value at "${String(key)}": already replaced.`)

  const match = getDeepPropertyDescriptor(owner, key)   // 沿原型链找描述符
  if (typeof match === 'undefined') { console.warn(/* not a global value */); return () => {} }

  if (match.descriptor.configurable) {
    Object.defineProperty(owner, key, {
      value: getNextValue(owner[key]), enumerable: true, configurable: true,
    })
  } else if (match.descriptor.writable) {
    owner[key] = getNextValue(owner[key])
  } else {
    throw new Error(`Failed to patch a non-configurable non-writable property …`)
  }
  // …并返回一个可逆的 restorePatch()
}
```

**关键设计**：`getNextValue(owner[key])` 把**当前值**作为参数传进去 —— 这既是 patch 手段，也是**保存原件**的手段（`realFetch` 就是这么来的）。

#### 2.2.3 Node 侧：socket 级拦截（v0.42.0 起的大改）

**没有 `MockHttpSocket`，没有 `MockClientRequest`，没有 `src/interceptors/https/` 目录。** 这些是旧版本的类名。

真实结构（`find src/interceptors -maxdepth 1 -type d`）：`ClientRequest` / `WebSocket` / `XMLHttpRequest` / `fetch` / `http` / `net`。

三层：

**第 1 层 —— `SocketInterceptor`（真正的拦截发生地）** `src/interceptors/net/index.ts:139-144`

```ts
export class SocketInterceptor extends Interceptor<SocketEventMap> {
  static symbol = Symbol.for('socket-interceptor')

  protected predicate(): boolean {
    return true
  }
```

它 patch 的是：

- `net.Socket.prototype.connect`
- `tls.TLSSocket.prototype._wrapHandle`
- `tls.TLSSocket.prototype._start`
- `http.Agent.prototype.addRequest`

源码注释（`net/index.ts:205-214`）解释了为什么不 patch `net.connect` 这个模块函数：

> Intercept connections at the "net.Socket.prototype.connect" level instead of patching the "net.connect()" module function. **ESM consumers snapshot the module bindings at import time** ("import * as net from 'node:net'"), so reassigning "net.connect" is invisible to them.

同一个拦截器里还有 `mockLookup`（`net/index.ts:109-134`）：**任何主机名都解析为 `127.0.0.1`/`::1`，不做真实 DNS**。目的写在注释里："This ensures the 'lookup'/'connectionAttempt' socket events fire even for non-existent hosts"。

**第 2 层 —— `NodeHttpRequestSource`（把 socket 字节解析成 HTTP）** `src/interceptors/http/source.ts:40-52`

```ts
/**
 * Interceptor for HTTP requests in Node.js.
 * Routes socket connections through an HTTP parser.
 */
export class NodeHttpRequestSource extends Interceptor<HttpRequestEventMap> {
  static symbol = Symbol.for('node-http-request-source')

  protected predicate(): boolean { return true }

  protected setup(): void {
    const socketInterceptor = Interceptor.singleton(SocketInterceptor)
    socketInterceptor.apply(this)
    // …
```

用 **llhttp（WASM）** 解析（`source.ts:230` `new HttpRequestParser({...})`，wasm 在 `src/interceptors/http/http-parser/llhttp/llhttp.wasm`）。

**第 3 层 —— 面向用户的 `ClientRequestInterceptor` / `FetchInterceptor` / `XMLHttpRequestInterceptor` / `HttpRequestInterceptor`：它们只做"归因 + 转发"** `src/interceptors/ClientRequest/index.ts:20-36`

```ts
protected setup(): void {
  const requestSource = Interceptor.singleton(NodeHttpRequestSource)
  const requestLogger = this.logger
  requestSource.apply(this)
  this.subscriptions.push(() => { requestSource.dispose(this) })

  this.subscriptions.push(
    forwardHttpEvents({
      source: requestSource,
      emitter: this.emitter,
      predicate: (initiator) => {
        return initiator instanceof http.ClientRequest
      },
    })
  )
  // …然后是 http.ClientRequest / http.get / http.request / https.get / https.request 的 patch
```

再往下（`:38-76`）它确实 patch 了 `http.ClientRequest`、`http.get`、`http.request`、`https.get`、`https.request`，但**这些 patch 只做一件事**：

```ts
patchesRegistry.applyPatch(http, 'get', (httpGet) => {
  return function mockHttpGet(...args) {
    return runInRequestContext(() => {
      return httpGet(...(args as [any, any]))
    }, requestLogger)
  }
})
```

即 `runInRequestContext(...)` —— 用 **`AsyncLocalStorage`** 标注"这次请求是谁发起的"。原因写在 `src/request-context.ts:23-29`："The initiator is the callback's return value (e.g. the 'ClientRequest' instance), so it cannot be known before running the callback."

**归因谓词决定谁能收到事件**（`src/interceptors/http/forward-events.ts:25-38`）：

```ts
source.on('request', async (event) => {
  if (predicate(event.initiator)) {
    await emitter.emitAsPromise(event)
  }
}, { signal: controller.signal })
```

- `ClientRequestInterceptor`：`initiator instanceof http.ClientRequest`
- Node `FetchInterceptor`：`initiator instanceof Request`
- Node `XMLHttpRequestInterceptor`：`initiator instanceof XMLHttpRequest`
- `HttpRequestInterceptor`：`() => true`（**全部**）

#### 2.2.4 Node 侧如何合成响应（全篇最"真"的一段）

`src/interceptors/http/source.ts:635-852`。手法是：**用 Node 自己的 `http.ServerResponse` 生成真实的 HTTP/1.1 字节，然后 `push` 进客户端正在读的那个 socket。**

```ts
// source.ts:664-696（节选）
const incomingMessage = new IncomingMessage(socket)
incomingMessage.method = request.method

const serverResponse = new ServerResponse(incomingMessage)

const responseSocket = new net.Socket()
responseSocket._writeGeneric = (writev, data, encoding, callback) => {
  unwrapPendingData(data, (chunk, encoding) => {
    socket.push(toBuffer(chunk), encoding)     // ← 真字节写回客户端 socket
  })
  callback?.()
}
```

```ts
// source.ts:712-727（节选）
responseSocket.on('drain', () => serverResponse.emit('drain'))
serverResponse.assignSocket(responseSocket)

serverResponse.removeHeader('connection')
serverResponse.removeHeader('date')

const rawResponseHeaders = getRawFetchHeaders(response.headers)
serverResponse.writeHead(
  response.status,
  response.statusText || STATUS_CODES[response.status],
  rawResponseHeaders,
)
```

于是调用方拿到的 `IncomingMessage` **是 Node 的 HTTP 客户端解析器从真实字节里解析出来的**，不是伪造对象 —— 这是 MSW 能吹"deviation-free"的底气。结束判定（`source.ts:828-851`）：

```ts
const isSelfDelimitingResponse =
  request.method === 'HEAD' ||
  response.headers.has('content-length') ||
  response.headers.has('transfer-encoding') ||
  !FetchResponse.isResponseWithBody(response.status)
```

**读这层的意义（对本项目很关键）**：这是一套"**手工实现一个假的 HTTP 服务端**"的完整工程 —— 和 aria2-in-browser 要干的事情**同构**。区别只是 MSW 把假服务端装在了 socket 层，而本项目（按 R9）要装在 JS API 层。

---

## 3 前提条件与能力边界

### 3.1 SW 路线的硬前提（全部是平台级，不可绕）

| # | 前提 | 依据 |
|---|---|---|
| P0 | **脚本 URL 的 scheme 必须是 `http`/`https`** | 规范 "Start Register"（<https://w3c.github.io/ServiceWorker/#start-register-algorithm>）："If scriptURL's scheme is not one of "http" and "https", reject promise with a TypeError and abort these steps." → **`chrome-extension://` 的 URL 直接被拒** |
| P1 | **必须是安全上下文**（`https:` 或 `localhost`） | 规范 §6.1："Service workers must execute in secure contexts. Service worker clients must also be secure contexts to register a service worker registration…" |
| P2 | **`scriptURL` 与 scope 都必须与注册页面同源** | 规范 "Register"（<https://w3c.github.io/ServiceWorker/#register-algorithm>）："If job's script url's origin and job's referrer's origin are not same origin, then: Invoke Reject Job Promise with job and "SecurityError" DOMException." / "If job's scope url's origin and job's referrer's origin are not same origin, then: … "SecurityError" DOMException."；MDN 同调："**The `scriptURL` and scope are not same-origin with the registering page.**" |
| P3 | **默认 scope = 脚本所在目录**（把 `./` 解析到 `scriptURL` 上）；要更大 scope 需要**伺服该脚本的服务器**给 `Service-Worker-Allowed` 响应头 | 规范 §6.5 Path restriction（<https://w3c.github.io/ServiceWorker/#path-restriction>）："a service worker script at `https://www.example.com/~bob/sw.js` can be registered for the scope url `https://www.example.com/~bob/` **but not for the scope `https://www.example.com/`**… Servers can remove the path restriction by setting a `Service-Worker-Allowed` header **on the service worker script**." |
| P4 | **脚本必须由目标源自己伺服** | 规范 §6.3.1 Origin restriction："A service worker executes in **the registering service worker client's origin**. … **Therefore, service workers cannot be hosted on CDNs.**"；MSW 官方 `managing-the-worker.md:32-34` 要求你"打开脚本 URL 确认能返回 `application/javascript`"；`get-worker-instance.ts:74-85` 在 404 时报 `Did you forget to run "npx msw init <PUBLIC_DIR>"?` |
| P5 | **页面必须在 worker 的 scope 内** | 规范 "Match Service Worker Registration"（按 storage key=origin + client URL 的**最长前缀**匹配）；`src/browser/utils/validate-worker-scope.ts:8-19` |
| P6 | `file:` 协议不行 | `src/browser/utils/supports.ts:10`：`location.protocol !== 'file:'` |

**P3 的一个关键细节**：`Service-Worker-Allowed` **只能放宽 path 比较，不能放宽 origin**。规范的 "Update" 算法里这一步是：

> If maxScope's origin is job's script url's origin, then: Set maxScopeString to "/", followed by the strings in maxScope's path …

规范自己也点明了这个不对称：

> However, the path restriction is **not considered a hard security boundary, as only origins are**.

→ 所以"扩展能不能靠 DNR 注入一个 `Service-Worker-Allowed` 头来给自己开 scope"这个问题，答案是**不能**：DNR 改头改不动 origin 检查，而 origin 检查就已经把扩展挡住了。

`validate-worker-scope.ts` 全文（这段代码本身就是 MSW 对 scope 边界最凝练的陈述）：

```ts
export function validateWorkerScope(
  registration: ServiceWorkerRegistration,
): void {
  if (!location.href.startsWith(registration.scope)) {
    devUtils.warn(
      `Cannot intercept requests on this page because it's outside of the worker's scope ("${registration.scope}"). If you wish to mock API requests on this page, you must resolve this scope issue.

- (Recommended) Register the worker at the root level ("/") of your application.
- Set the "Service-Worker-Allowed" response header to allow out-of-scope workers.`,
    )
  }
}
```

官方文档同调（`docs/api/setup-worker/start.md:52-56`）：

> Keep in mind that a Service Worker can only control the network from the clients (pages) hosted at its level or down. You likely always want to register the worker at the root.

### 3.2 SW 路线能拦到哪些请求

SW 的 `fetch` 事件覆盖**受控 client 发起的全部网络获取**：

| 请求类型 | 能否拦到 | 依据 |
|---|---|---|
| 同源 `fetch()` | ✅ | `mockServiceWorker.js:122-141` |
| 同源 `XMLHttpRequest` | ✅（Firefox 除外） | 同上 |
| **导航请求** | ✅ **能** | `:427` 专门处理 `event.request.mode === 'navigate'`（流缓冲） |
| 跨域请求 | ✅ 事件会触发 | SW 控制的是 **client**，不是 URL；但渲染端仍按 Fetch 的 filtered-response 规则处理（见下） |
| `no-cors` 请求 | ⚠️ 事件触发，但**返回值受 tainting 规则过滤** | 规范 §4.6.7 注释 |
| `<img>` / `<script>` / `<link>` 等子资源 | ✅ 走同一个 fetch 事件 | 但 **MSW 默认把它们从"未处理告警"里排除**，见 §3.4 |
| **WebSocket 握手** | ❌ **SW 覆盖不到** | 见下 |

规范 §4.6.7 `event.respondWith(r)` 的注释是跨域/tainting 问题的规范级答案：

> Note: Developers can set the argument r with either a promise that resolves with a Response object or a Response object (which is automatically cast to a promise). Otherwise, a network error is returned to Fetch. **Renderer-side security checks about tainting for cross-origin content are tied to the types of filtered responses defined in Fetch.**

即：**SW 能给出响应，但渲染端还要过一遍 Fetch 的 tainting/过滤**。`no-cors` 请求不会被"提权"成一个可读的完整响应。

**WebSocket 为什么不在 SW 里**：`setup-worker.ts:65-76` 显示 MSW 在浏览器里**额外**挂了一个 `InterceptorSource({ interceptors: [new WebSocketInterceptor()] })`。如果 SW 的 `fetch` 事件能覆盖 WS 握手，这个就是多余的。补充证据：interceptors README:241-246 明说 `WebSocketInterceptor` "provides its connection-level API **only for the global WHATWG `WebSocket` class**"；MSW 文档 `websocket/index.md` 也把 WS 当作独立的 JS 层能力。

### 3.3 SW 路线拦不到的东西（官方明列 + 源码实证）

| 盲区 | 依据 |
|---|---|
| **scope 之外的页面** | `validate-worker-scope.ts:11` |
| **SW 激活前页面已发出的请求** | `getResponse`：`if (!activeClientIds.has(client.id)) return passthrough()`（`mockServiceWorker.js:331-333`）。缓解手段是 `worker.start({ waitUntilReady: true })`（默认 true，`start.md:151-157`）会"Defers any application requests that happen during the Service Worker registration" |
| **DevTools 打开的副作用请求** | `:125-130`：`cache === 'only-if-cached' && mode !== 'same-origin'` 直接 `return`（不 `respondWith`） |
| **XHR 的 progress / upload progress 事件** | `docs/limitations.md:12`："The Service Worker API translates all outgoing requests on the page to Fetch API requests. Those, sadly, do not have a concept of request progress and so the related progress and upload progress events _will not be dispatched_ on the intercepted XMLHttpRequest." |
| **Firefox：页面上的 `XMLHttpRequest` 完全不通知 worker** | `docs/limitations.md:25`："Firefox does not notify the worker when an `XMLHttpRequest` happens on the page. … Even if you have a matching request handler for the request, it won't be matched and the mocked response won't be sent if it's an `XMLHttpRequest`." |
| **不同 realm 的请求**（其他 SW / SharedWorker / 未受控 iframe） | 平台语义：SW 只控制匹配其 scope 的 client |

### 3.4 MSW 自己判定"请求该不该被拦"的方式

这是 §5 要借鉴的点之一 —— MSW 的策略是 **"先全拦，再降噪"**，而不是"先判定该不该拦"：

1. 只要在 scope 内且 client 激活，**全部**过一遍 handler 列表；
2. 没命中任何 handler 时，按 `onUnhandledFrame`（默认 `'warn'`）处理（`start.md:103-120`）：`warn` / `error` / `bypass`；
3. **但默认会静默忽略"常见静态资源请求"**（`start.md:147`），判定函数是 `isCommonAssetRequest()`（`docs/api/is-common-asset-request.md:23-33`）：

> - Has a `file:` protocol;
> - Has a hostname of common static assets providers (e.g. `fonts.googleapis.com`);
> - Includes `/node_modules` substring in its pathname;
> - Includes `@vite` in its pathname;
> - Is an HTML (`.html`), CSS (…), JavaScript (…), image (…), font (…), video (…), audio (…), or other document format (…) request.

> **判据性质**：这是**降噪白名单**（"别刷控制台"），不是权限模型。真正的"该不该拦"由 handler 的 predicate 决定。

### 3.5 JS 层路线的边界

| 边界 | 依据 |
|---|---|
| 只覆盖它 patch 过的全局/模块 | `patches-registry.ts` 的调用点即全部覆盖范围 |
| **同步 XHR 不支持**（放行） | `xml-http-request-controller.ts:128-133`：`if (this.sync) { console.warn('Failed to intercept an XMLHttpRequest (…) : synchronous requests are not supported. This request will be performed as-is.'); return invoke() }` |
| 浏览器路线不覆盖 WebSocket 之外的非 HTTP 协议 | 只有 `FetchInterceptor` / `XMLHttpRequestInterceptor` / `WebSocketInterceptor` 三个浏览器拦截器（`src/presets/browser.ts:8-11`） |
| **无第三方 patch 冲突检测** | 只防"自己重复 patch"（`patches-registry.ts:13-16` 的 `invariant`）。别的库先 patch 过 `fetch`，MSW 会把那个 wrapper 当成 `realFetch` 链上去，不报警 |
| Node 侧：请求虽被 socket 层看见，但**按 initiator 过滤后才交给 MSW** | `ClientRequest/index.ts:32-34` + `forward-events.ts:28`（§7 不一致 #2 的核心） |

---

## 4 关键技术细节

### 4.1 拦截点总表

| 运行时 | 类 | 拦截点 | 源码位置 |
|---|---|---|---|
| 浏览器 | `FetchInterceptor` | `Object.defineProperty(globalThis, 'fetch', …)` | `interceptors/src/interceptors/fetch/web.ts:37` |
| 浏览器 | `XMLHttpRequestInterceptor` | `Object.defineProperty(globalThis, 'XMLHttpRequest', …)` → 构造函数 Proxy | `XMLHttpRequest/web.ts:21`、`xml-http-request-proxy.ts:22-53` |
| 浏览器 | `WebSocketInterceptor` | `Object.defineProperty(globalThis, 'WebSocket', …)` → 构造函数 Proxy | `WebSocket/index.ts:137-160, 306-308` |
| 浏览器 | （SW） | `addEventListener('fetch', …)` + `event.respondWith()` | `msw/src/mockServiceWorker.js:122-141` |
| Node | `SocketInterceptor` | `net.Socket.prototype.connect` / `tls.TLSSocket.prototype._wrapHandle` / `_start` / `http.Agent.prototype.addRequest` | `interceptors/src/interceptors/net/index.ts:139, 215-219, 387-390, 425-429, 503-506` |
| Node | `NodeHttpRequestSource` | 在 socket 上跑 llhttp 解析 | `http/source.ts:40, 230, 557` |
| Node | `ClientRequestInterceptor` | `http.ClientRequest` / `http.get` / `http.request` / `https.get` / `https.request`（**仅归因**） | `ClientRequest/index.ts:38-76` |
| Node | `FetchInterceptor` | `globalThis.fetch`（**仅归因**） | `fetch/node.ts:52-101` |

### 4.2 如何伪造可信的 `Response`

#### fetch 路线：不伪造，只"补全"（`fetch/web.ts:111-206`）

```ts
// fetch/web.ts:133-148
let response: Response

if (isCompressedResponse(rawResponse)) {
  response = new FetchResponse(decompressResponse(rawResponse), {
    status: rawResponse.status,
    statusText: rawResponse.statusText,
    headers: rawResponse.headers,
  })
  copyRawHeaders(rawResponse.headers, response.headers)
} else {
  response = rawResponse          // ← 默认原样转发 handler 的 Response
}

// Mocked responses have no URL. Mimic the actual fetch
// and set the response URL to the request URL.
FetchResponse.setUrl(request.url, response)
```

源码注释（`:121-132`）解释了为什么原样转发："Forward the mocked response instance as-is. Wrapping it in a new `Response` drops any runtime-specific state the environment attached to it…"

`FetchResponse.setUrl`（`src/utils/fetch-utils.ts:240-285`）是**最核心的"让它看起来像真的"**：

```ts
static setUrl(url: string | undefined, response: Response): void {
  if (!url || url === 'about:' || !URL.canParse(url)) return

  const state = getValueBySymbol<UndiciResponseState>('state', response)
  if (state) {
    // In Undici, push the URL to the internal list of URLs.
    state.urlList.push(new URL(url))
  } else {
    // In other libraries, redefine the `url` property directly.
    Object.defineProperty(response, 'url', {
      value: url, enumerable: true, configurable: true, writable: false,
    })
    // url 是自有属性，不会随 clone 传递 → 手动代理 clone()
    if (!(response instanceof FetchResponse)) {
      const originalClone = response.clone
      Object.defineProperty(response, 'clone', {
        value: function clone(this: Response): Response {
          const clonedResponse = originalClone.call(this)
          FetchResponse.setUrl(url, clonedResponse)   // 克隆体也要有 url
          return clonedResponse
        },
        // …
      })
    }
  }
  Object.defineProperty(response, kUrl, { value: url, enumerable: false })
}
```

`clone()` 也要重写（`fetch-utils.ts:356-372`）把自定义 `status`/`url` 带过去，否则 `response.clone()` 一调就露馅。

#### XHR 路线：改**实例**上的 getter（`xml-http-request-controller.ts`）

```ts
// :291-307
Object.defineProperties(this.request, {
  response:     { enumerable: true, configurable: false, get: () => this.response },
  responseText: { enumerable: true, configurable: false, get: () => this.responseText },
  responseXML:  { enumerable: true, configurable: false, get: () => this.responseXML },
})
```

```ts
// :411-416
define(this.request, 'status', response.status)
define(this.request, 'statusText', response.statusText)
if (!this.request.responseURL) define(this.request, 'responseURL', response.url)
```

`define()` 辅助函数（`:907-918`）：

```ts
function define(target: object, property: string | symbol, value: unknown): void {
  Reflect.defineProperty(target, property, {
    writable: true, enumerable: true, value,
  })
}
```

`readyState` 通过 `setReadyState()`（`:753-781`）改，并附带触发 `readystatechange`。

**响应体不流式，全缓冲**（`:490-512`）：

```ts
const reader = response.body.getReader()
while (true) {
  if (responseReadController.signal.aborted) break
  const { value, done } = await reader.read()
  if (done) { processResponseEndOfBody(); return }
  processResponseBodyChunk(value.byteLength)
  this.responseBuffer = concatArrayBuffer(this.responseBuffer, value)
}
```

`response` / `responseText` / `responseXML` 三个 getter 再从 `this.responseBuffer` 里按**真实的 `responseType`** 转换（`:587-693`）。`responseType` **从不被伪造** —— 是读它然后让字节去适配它。

事件也全部手工合成：`trigger()`（`:786-821`）自己调 `on<event>` 回调和注册的 listener，用 `createEvent()` 造 `ProgressEvent`。

#### Node 路线：生成真字节（见 §2.2.4）

### 4.3 抗检测（anti-detection）的真实水平

这一节结论比较反直觉：**MSW/interceptors 的"抗检测"其实很薄**。

| 项 | 事实 | 依据 |
|---|---|---|
| `Response.type` | **不伪造**。mock 响应在浏览器里 `type === 'default'` | 仓库自带测试 `test/modules/fetch/response/fetch-response-init.neutral.test.ts:50-52`：`expect(response.type).toBe(task.file.projectName === 'browser' ? 'default' : 'basic')`；对照 `:66-68` 真实（bypass）响应在浏览器里是 `'cors'`。`vitest.config.ts` 的 `browser` 项目是 **Playwright + Chromium** |
| `Response.ok` | **从不赋值**，靠平台 getter 从 `status` 推导 | `grep -rn "\.ok\b" src/` 只命中 CONNECT 相关检查 |
| `Response.redirected` | 只在真正跟了重定向后写，克隆时保留 | `fetch/utils/follow-redirect.ts:89-92`、`clone-response.ts:68` |
| `Response.url` | ✅ 认真伪造（含 clone 传递、Undici 内部 state） | `fetch-utils.ts:240-285, 356-372` |
| raw headers | ✅ 保留原始大小写/重复头 | `copyRawHeaders()`（`ClientRequest/utils/record-raw-headers.ts:311-334`） |
| **`globalThis.fetch.name`** | ❌ **变成空字符串** | 替换体是 `return async (input, init) => {…}`（匿名箭头函数，`fetch/web.ts:38`）。**本机实测**：patch 前 `"fetch"`，patch 后 `""` |
| `XMLHttpRequest` 全局 | ✅ 是 Proxy，`name` / `prototype` 与原生一致 | `createXMLHttpRequestProxy`：`new Proxy(globalThis.XMLHttpRequest, { construct(...) })` 只加构造陷阱 |
| 重复 patch 防护 | ⚠️ 只防自己（`invariant(!ownerReplacements?.has(key))`）；**无第三方 patch 检测、无 marker symbol** | `patches-registry.ts:13-16`；`globalThis.__MSW_INTERCEPTORS_REGISTRY` 只被 `Interceptor.singleton` 用，且只用于 Node 侧 source |

> **对本项目的直接含义**：如果目标页面的脚本做"指纹检测"（例如 `fetch.toString()`、`fetch.name`、`response.type`），MSW 的浏览器拦截器**挡不住**。本项目若要拦 aria2 前端（AriaNg 之类），检测压力小得多，但"`Response.type` 是 `'default'`"这类差异仍会被细心的代码看到（例如依赖 `response.type === 'basic'` 的分支）。

### 4.4 passthrough 的三种实现

| 层 | 手段 | 源码 |
|---|---|---|
| 浏览器 `fetch` | 调**抓到的原件** `realFetch(request.clone())` | `fetch/web.ts:61-110`（`:75-80`） |
| 浏览器 XHR | **推迟调用原实例的 `open`+`send`**。`send` 里不调真 send，只在 `queueMicrotask` 里等 handler 结算；`!this[kIsRequestHandled]` 才 `invoke()` | `xml-http-request-controller.ts:171-189`；`open`/`setRequestHeader` 已经同步放过（`:99`、`:120`） |
| SW | 在 worker 里 `fetch(requestClone, { headers })` | `mockServiceWorker.js:285-320` |
| Node socket | `socketController.passthrough()` → 用原始 options 建真连接 | `net/index.ts`、`http/source.ts` |

**dispatch 决策在 `handle-request.ts:218-224`**：

```ts
// If the request hasn't been handled by this point, passthrough.
if (options.controller.readyState === RequestController.PENDING) {
  return await options.controller.passthrough()
}
return options.controller.handled
```

`RequestController` 是个四态机（`request-controller.ts:16-20`）：`PENDING=0 / PASSTHROUGH=1 / RESPONSE=2 / ERROR=3`，用 `invariant` 保证**一个请求只能被处理一次**（`:46-52`、`:71-80`、`:110-118`）。

**MSW 层的 passthrough 是个精彩的"魔术响应"**（`msw/src/utils/passthrough.ts:23-31`）：

```ts
export function passthrough(): HttpResponse<any> {
  return new Response(null, {
    status: 302,
    statusText: 'Passthrough',
    headers: {
      [REQUEST_INTENTION_HEADER_NAME]: RequestIntention.passthrough,
    },
  }) as HttpResponse<any>
}
```

即：**用一个带私有头 `x-msw-intention: passthrough` 的 302 响应**当"意图信号"，`isPassthroughResponse()`（`:40-46`）再把它认回来。

而 `bypass()`（`msw/src/utils/bypass.ts:43`）走的是另一条路 —— 在 `accept` 头上打标：

```ts
/**
 * Send the internal request header that would instruct MSW
 * to perform this request as-is, ignoring any matching handlers.
 * @note Use the `accept` header to support scenarios when the
 * request cannot have headers (e.g. `sendBeacon` requests).
 */
requestClone.headers.append('accept', 'msw/passthrough')
```

这就是为什么 SW 的 `passthrough()` 要专门把 `msw/passthrough` 从 `accept` 里剥掉（`mockServiceWorker.js:302-317`）—— 否则这个内部标记会泄漏到真实服务器上，还会破坏 CORS。

> **这是 §5 最值得抄的一条设计**：**"用响应/请求本身携带控制意图"**，而不是另开控制通道。对本项目 R5"内置 UI 不得走特殊通道"极有参考价值。

### 4.5 流式响应（ReadableStream）

| 场景 | 处理 | 源码 |
|---|---|---|
| fetch，mock 响应 | **原样是流**，不缓冲 | `fetch/web.ts:142-144` |
| fetch，需要给 `response` 事件监听器一份 | **手写 tee**（不是 `.tee()`） | `src/utils/clone-response.ts:5-72` |
| fetch，mock 且被压缩 | `DecompressionStream` / `BrotliDecompressionStream` | `fetch/utils/decompression.ts:78-96` |
| SW → 页面 | `ReadableStream` 作为 **Transferable** 经 `postMessage` 转移 | `mockServiceWorker.js:208-230, 398-401` |
| SW，导航请求 | **必须缓冲成 ArrayBuffer**（否则页面空白） | `mockServiceWorker.js:421-429` |
| XHR | **不流式**，全缓冲（见 §4.2） | `xml-http-request-controller.ts:490-512` |
| Node socket | `serverResponse.write(value)` 循环 + `'drain'` 背压 | `http/source.ts:787-819` |

`clone-response.ts` 全文要点（**这是本报告认为最值得逐字读的一段工程代码**）：

```ts
/** Clone for observers without letting their unread body block caller cancellation. */
export function cloneResponse(response: Response): [Response, Response] {
  const clone = FetchResponse.clone(response)
  if (!response.body || !clone.body) return [response, clone]

  const observer = wrapResponse(clone)
  const caller = wrapResponse(response, observer.cancel)
  return [caller.response, observer.response]
}

function wrapResponse(response: Response, onCancel?: (reason: unknown) => Promise<void>) {
  const body = response.body!
  const reader = body.getReader()
  const cancel = (reason: unknown) => (body.locked ? reader.cancel(reason) : body.cancel(reason))
  const stream = new ReadableStream<Uint8Array>(
    {
      async pull(controller) {
        const { done, value } = await reader.read()
        if (done) { controller.close(); reader.releaseLock(); return }
        controller.enqueue(value)
      },
      async cancel(reason) {
        const cancellation = cancel(reason)
        if (onCancel) {
          // Caller cancellation owns both branches.
          await Promise.all([cancellation, onCancel(reason)])
        } else {
          // An observer must not wait for the caller to consume its branch
          void cancellation.catch(() => {})
        }
        reader.releaseLock()
      },
    },
    { highWaterMark: 0 }
  )
  const wrappedResponse = new FetchResponse(stream, response)
  copyRawHeaders(response.headers, wrappedResponse.headers)
  Object.defineProperties(wrappedResponse, {
    type: { value: response.type },
    redirected: { value: response.redirected },
  })
  return { response: wrappedResponse, cancel }
}
```

三个非显然的要点：

1. **`highWaterMark: 0`** —— 不做预读，避免"观察者没消费就把调用方卡住"。
2. **取消耦合**：调用方 `cancel()` 时同时取消观察者分支（`Promise.all`），但观察者自己 `cancel()` 时不阻塞调用方。
3. **`type` / `redirected` 要手动搬** —— 因为包装成了新的 `Response`（`new FetchResponse(stream, response)`），这两个 getter 的值会丢。

仓库里 **没有一处 `.tee()` 调用**（`grep -rn "tee()" src/ test/` → 0 命中）。

---

## 5 能否借鉴

逐条给出**用在本项目哪一层**（对着 concept-design 的三层结构）。

### 5.1 【强烈推荐】拦截器层抽象 → 用在**第一层 转发器**

`Interceptor<EventMap>` 的契约极小（`src/interceptor.ts:56-57, 59-100`）：

```ts
protected abstract predicate(): boolean
protected abstract setup(): void

public apply(owner: object = this): void { /* 幂等 + predicate 门禁 + setup */ }
public dispose(owner: object = this): void { /* 引用计数 + 逆序撤销 + removeAllListeners */ }
```

配 `BatchInterceptor`（`batch-interceptor.ts:63-114`）：**"任一子拦截器 predicate 通过就算通过"**，并把子拦截器事件桥接到自己身上。

**为什么对本项目有价值**：R4.1 要求"尽可能多地拦截各种途径（fetch / XHR / WebSocket…）"。这个抽象正好给出一个"每途径一个 `Interceptor` 实现 + 一个 batch 统一对外"的骨架，而且 `apply(owner)` 的**引用计数**设计能干净处理"同一途径被多个来源（多个标签页 / 多个引擎）启用"的场景。

### 5.2 【强烈推荐】可逆 patch + 原件保留 → 用在**第一层 转发器**

`patchesRegistry.applyPatch(owner, key, getNextValue)` 同时解决三件事：

1. **保存原件**：`getNextValue(owner[key])` 把当前值喂进来（`patches-registry.ts:29/34`）。
2. **不破坏描述符**：按 `configurable` / `writable` 分情况处理，最后用 `Object.defineProperty(match.owner, key, match.descriptor)` 原样还原（`:53`）。
3. **能撤销**：返回 `restorePatch`，`dispose()` 时逆序执行。

**对本项目的价值**：扩展注入 MAIN world 后，如果不清洗就把 `window.fetch` 留在被 patch 状态，会与页面其它代码、其它扩展互相污染。**"可逆 + 保留原件 + 幂等"是转发器的基本卫生**。

### 5.3 【推荐】"谓词 + 解析器"的 handler 模型 → 用在**第二层 Mock 层**

官方描述（`docs/http/intercepting-requests/index.md:19-27`）：

> Every request handler consists of two parts: a _predicate_ and a _response resolver_. A predicate decides which requests to intercept, and a resolver decides what to do with those requests.

匹配语义（`src/core/utils/execute-handlers.ts:39-56`）非常值得逐字读：

```ts
for (const handler of handlers) {
  result = await handler.run({ request, requestId, resolutionContext })
  // If the handler produces some result for this request, it automatically becomes matching.
  if (result !== null) { matchingHandler = handler }
  // Stop the lookup if this handler returns a mocked response.
  if (result?.response) { break }
}
```

即 **"穿透匹配 + 最后一个有效命中者胜出 + 遇到真实响应即停"**。

**对本项目的价值**：这个形状与 concept-design **Q-B4/Q-B8** 要的"能力集合 + 请求上下文 → 接口行为（真实 / 伪装 / 不实现）"的规则推导**同构**：

| MSW | aria2-in-browser |
|---|---|
| `predicate`（方法 + URL + 自定义函数） | 方法 + 请求上下文（Q-B4 的"粒度 2"） |
| `resolver` 返回 `Response` | 判"真实还原" |
| 返回"什么都不做" → `passthrough()` | 判"伪装还原"（结果兑现，过程不同 → 但本项目是**要真下载**） |
| 抛错 → 500 `'Unhandled Exception'`（`response-utils.ts:7-26`） | 判"不实现" → Q-B2 三段式的错误码 |

注意 **Q-B4 的"一票否决"** 与 MSW 的"最后命中者胜出"是**不同**的合成规则 —— MSW 的规则是"顺序 + 短路"，本项目要的是"最弱正向结果 + 任一不实现则整体不实现"。**借形状，不借语义**。

### 5.4 【推荐】URL 匹配与参数解析 → 用在**第二层 Mock 层**

`match-request-url.ts:22-45`：支持 `string | RegExp`，字符串走 `normalizePath` + `@msw/url` 的 `matchPattern`，返回 `{ matches, params }`。

**对本项目的价值**：Q-D1 现阶段只支持"一条精准匹配的 URL"，但结构上留好 `Path = string | RegExp` 与 `params` 的位置，后续扩展零改造成本。

**但要注意**：MSW 文档在这个点上写错了（§7 附带发现 3），**v3 已经不使用 `path-to-regexp`**。

### 5.5 【强烈推荐】"用载体本身携带控制意图" → 用在**转发器 ↔ Mock 层**，直接服务 **R5**

MSW 有两处绝妙设计：

- `passthrough()` = 一个带 `x-msw-intention: passthrough` 私有头的 **302 响应**（`msw/src/utils/passthrough.ts:23-31`）。
- `bypass()` = 在 **`accept`** 头上追加 `msw/passthrough`（`msw/src/utils/bypass.ts:43`），选 `accept` 的理由写在注释里："to support scenarios when the request cannot have headers (e.g. `sendBeacon` requests)"。
- SW 侧再把标记剥掉，保证不泄漏给真实服务器（`mockServiceWorker.js:302-317`）。

**为什么对本项目特别有价值**：R5 要求"内置 AriaNg UI **不得走特殊通道**，必须和普通页面走同样的路径"。MSW 的做法恰好证明：**"统一路径"和"能区分意图"不矛盾** —— 用请求/响应自身的标准字段（header / status）承载意图，路径仍然只有一条。同时要吸取它的教训：**内部标记必须在出口处剥掉**，否则泄漏给真实服务会改变语义。

### 5.6 【推荐】流式响应的"双分支 + 取消耦合" → 用在**第一层 转发器**

见 §4.5。转发器命中后要把请求体交给 Mock 层、又要把（可能的）原始响应交给调用方；`cloneResponse` 的 `highWaterMark: 0` + 取消耦合 + `type/redirected` 手动搬运，是"我读了一份但不能拖累调用方"的成熟解法。

对本项目还有一层意义：**Q-D3（WebSocket）与 Q-B7（进度姿态）**都涉及"流式/增量"，这套原语可以直接复用。

### 5.7 【推荐】initiator 归因（`AsyncLocalStorage`）→ 用在**第一层 转发器 / 第三层 下载引擎层**

`runInRequestContext`（`ClientRequest/index.ts:42-44`）+ `predicate: (initiator) => initiator instanceof http.ClientRequest`（`:32-34`）解决的是 **"这次请求是谁发的"**。

**对本项目的价值**：R4.1 要求覆盖"每一个浏览器标签页、MAIN WORLD 的注入脚本等等"。归因机制可用于：

- 区分请求来自哪个来源（内置 UI / 普通页面 / 别的扩展）；
- 与 Q-A4"不做来源白名单"并存，但**用于可观测性**（Q-D6 Mock 控制台）；
- 与 R12（全局只启用一个引擎）配合时，路由决策需要知道上下文。

### 5.8 【参考】SW 生命周期不可靠的应对 → 用在**第一层 转发器（若用到 SW）**

MSW 的 `KEEPALIVE_REQUEST`（`service-worker-source.ts:293-295`，每 5s）、`INTEGRITY_CHECK`（版本校验，`:406-433`）、`CLIENT_CLOSE` 自注销（`mockServiceWorker.js:37-70`）都是"SW 会随时被杀"的具体对策。

**与本项目的对应**：Q-D3 已经裁定"转发器轮询 Mock 层近似推送（不依赖 SW 生命周期）"、Q-D5 裁定"状态必须持久化、不依赖 SW 内存"。**MSW 的这些手法与本项目的裁定方向一致，但 MSW 本身恰恰是"依赖 SW 内存"的反面教材** —— 它把 client 集合、pending 请求全放在 worker 的 `Map`/`Set` 里（`mockServiceWorker.js:14-18`）。**这一条只借问题意识，不借实现**。

### 5.9 【不借鉴】SW 路线本身

理由见 §6。要点：SW 路线**违反 R9**（请求真的发出去了），且**在 MV3 扩展里对第三方源根本不可用**。

### 5.10 【不借鉴】"用内存 Map 存运行状态"

`pendingRequests`（`mockServiceWorker.js:18`）、`activeClientIds`（`:14`）都在 worker 内存里。SW 一被杀就全丢。这与 **Q-D5** 直接冲突。

---

## 6 能否直接使用

### 6.1 结论

> # **不能。**
>
> 把 `msw` 引进一个 MV3 扩展、用它去拦截**任意页面**（不是开发者自己的应用）的请求 —— **不可行**。这不是"配置问题"或"权限问题"，而是 **Service Worker 的注册模型决定的**：扩展无法把 Service Worker 注册到别人的源上。
>
> **有条件的替代路径**：直接依赖 `@mswjs/interceptors` 的**浏览器那两个拦截器**（`FetchInterceptor` / `XMLHttpRequestInterceptor`），通过 `chrome.scripting` 注入到目标页面的 **MAIN world**。这条路与本项目的 **R9 完全一致**，但需要自研注入与通信层，且**不能**复用 `msw` 的 `setupWorker` / handler / CLI / Vite 插件。

### 6.2 为什么不能（逐条，按杀伤力排序）

**① SW 脚本必须与页面同源 —— 扩展做不到**

`navigator.serviceWorker.register()` 的规范级约束（MDN `ServiceWorkerContainer.register()`，`SecurityError` 条目）：

> The `scriptURL` is not a potentially trustworthy origin, such as `localhost` or an `https` URL. **The `scriptURL` and scope are not same-origin with the registering page.**

MSW 的实现就是标准调用（`get-worker-instance.ts:59`），没有任何扩展特权：

```ts
const registration = await navigator.serviceWorker.register(url, options)
```

**后果**：在 `https://example.com` 的页面里（哪怕从 content script 里调用），`register('chrome-extension://<id>/mockServiceWorker.js')` 是跨源 → `SecurityError`。反过来，`register('/mockServiceWorker.js')` 会去 `https://example.com/mockServiceWorker.js` 取脚本 —— **而扩展无法在别人的源上放文件**。

**② `web_accessible_resources` 解决不了这个问题**

WAR 只让**页面的脚本能 fetch 到扩展的文件**（Chrome 文档：content scripts 要访问扩展文件"you need to declare them as web-accessible resources"），它**不改变 URL 的源**，也不改变 SW 注册的同源要求。

**③ `Service-Worker-Allowed` 也帮不上**

SW scope 可以超出脚本目录，但**只有伺服该脚本的服务器能发这个响应头**（规范 §"Start Register" / MDN）。扩展既不是那个服务器，也就发不了这个头。

**④ 扩展自身的 Service Worker 是另一个东西**

MV3 的 `"background": { "service_worker": "..." }` 注册出来的是**扩展源**（`chrome-extension://<id>/`）下的 SW，scope 只在扩展源内。它**不是**页面 SW，**不能**拦截 `https://example.com` 页面的 `fetch`。这是 MV3 里最常见的概念混淆点。

**⑤ `declarativeNetRequest` 也做不到**

Chrome DNR 文档的 `RuleActionType` 枚举**就是全部能力**（<https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest#type-RuleActionType>）：

> "block" — Block the network request.
> "redirect" — Redirect the network request.
> "allow" — Allow the network request. …
> "upgradeScheme" — Upgrade the network request url's scheme to https …
> "modifyHeaders" — Modify request/response headers from the network request.
> "allowAllRequests" — Allow all requests within a frame hierarchy …

**没有"合成任意响应体"这一项。** 这与 concept-design **R9** 的判断完全一致（"与'用 DNR 重定向'不是同一条路：DNR 走网络层，拿不到'返回任意响应体'的能力"）。

补两条"看起来有希望但其实不行"的路径：

- **DNR 重定向到扩展资源当响应体**：不行。Fetch 标准（<https://fetch.spec.whatwg.org/#http-redirect-fetch>）："If locationURL's scheme is not an HTTP(S) scheme, then return a network error." —— `chrome-extension://` 不是 HTTP(S) scheme。
- **DNR 重定向去替换 SW 脚本**：也不行。规范 "Update" 算法里对 worker 脚本请求明写：**"Set request's redirect mode to "error"."**

**⑥ 就算 SW 能注册，它也不满足 R9**

见 §2.1.6：SW 路线下**请求真的发到了网络上**（这正是 MSW 宣传的"能出现在 DevTools"）。而 R9 要求"命中规则后请求**根本不会发到网络上** ⇒ CORS、混合内容、证书、真实服务是否存在**全部不适用**"。

**这一条是决定性的**：即使某个浏览器将来允许扩展注册跨源 SW，那条路线对本项目**仍然是错的**。

**⑦ MSW 上游从来没有、也不打算支持"扩展里拦第三方页面"**

这一条不是技术约束，而是**生态事实**——它决定了"指望上游补一个开关"这条路不存在：

- 官方文档 `guides/recipes/custom-worker-script-location`（scope 问题的专门页面）把所有放宽 scope 的办法总结为：
  > There are multiple ways to allow the worker to control pages outside of its location. **Note that all of these methods imply you have access to the development server**, which with most modern frameworks you do to some extent.
- 官方 `guides/integrations/browser`：**"If your application registers a Service Worker it must host and serve it."**
- 官方 `guides/recipes/merging-service-workers`：**"The browser can only register a single Service Worker per scope."**
- 仓库里**搜索"browser extension" / "chrome extension" 一无所获**（我在 `src/` 与 `README.md` 里 grep → 0 命中；文档仓库里的 "extension" 全是 `ctx.extensions()` 这个已废弃 API 或"by extension"这种普通用词）。
- GitHub issue #23（标题 **"Browser extension"**）—— *"Developing a browser extension is currently out of scope. I find **a browser's DevTools to be the best extension**."*（注：这是该 issue 下的一条评论正文；本报告只核到正文文本，未核到作者身份字段。）
- GitHub issue #2667（标题 **"Support to plasmo and browser extensions background requests"**）—— *"The Service Worker API intercepts any outgoing requests on the page. If it doesn't capture plasmo, there must be a reason for it, otherwise it would've already been supported."*；关闭语 *"Closing due to the lack of context."*
- GitHub issue #346（标题 **"Cannot set serviceWorker.URL to subdirectory because it limits what requests can be intercepted."**）—— 提问者自己复现了浏览器报错 *"Failed to register a ServiceWorker for scope ('http://localhost:3000/') with script ('http://localhost:3000/static/mockServiceWorker.js'): **The path of the provided scope ('/') is not under the max scope allowed ('/static/')**. Adjust the scope, move the Service Worker script, or use the `Service-Worker-Allowed` HTTP header to allow the scope."*，并自行给出结论 *"You can't put the mockServiceWorker.js anywhere - it must be in the same directory or in a parent directory of the URLs that you want to intercept."*
  > ⚠️ **归属更正**：这句结论出自**提问者**（他自己关闭了 issue，说是"to help anyone else"），**不是维护者的表述**。我**没有**核到维护者对它的明确认可。但浏览器报错文本本身是我逐字核到的，**它才是这条证据的硬核部分** —— 它直接演示了 §3.1 P3（path restriction）在真实浏览器里的样子。
- 两个仓库的 issue 标题、上述评论正文与报错文本均由我**从 `github.com` 页面内嵌 JSON 中逐字提取核对**（core REST API 全程 403，见 §9.8）。GitHub 搜索"msw 在第三方站点上的拦截"**没有**任何命中该主题的结果。

### 6.3 那什么能用？—— `@mswjs/interceptors` 的浏览器拦截器

`msw` 的 `setupWorker` 在浏览器里其实有**第二条路**（`setup-worker.ts:61-63`）：

```ts
const httpSource = supportsServiceWorker()
  ? await ServiceWorkerSource.from({ /* … */ })
  : new FallbackHttpSource({ quiet: options?.quiet })
```

`FallbackHttpSource`（`src/browser/sources/fallback-http-source.ts:10-15`）：

```ts
export class FallbackHttpSource extends InterceptorSource {
  constructor(private readonly options: FallbackHttpSourceOptions) {
    super({
      interceptors: [new XMLHttpRequestInterceptor(), new FetchInterceptor()],
    })
  }
}
```

**这就是纯 JS 层 patch**，与 R9 一致。但它只在"当前 realm 不支持 SW"时启用（`supports.ts:5-12`：无 `navigator.serviceWorker` 或 `location.protocol === 'file:'`），且**它只作用于运行它的那个 realm**。

所以对本项目而言，**真正可用的是这两个拦截器类本身**，而不是 `setupWorker`。

### 6.4 所需改造（如果走 6.3 的路）

| # | 改造 | 说明 |
|---|---|---|
| C1 | **不走 `msw/browser`**，直接依赖 `@mswjs/interceptors` 的 `/fetch/web` 与 `/XMLHttpRequest/web` | 注意 `./fetch` 的 `browser` 条件是浏览器版，`./XMLHttpRequest` 同理（`interceptors/package.json` exports） |
| C2 | 用 **manifest 静态 `content_scripts`** 声明 `world: "MAIN"` + `run_at: "document_start"` + `all_frames: true`（这是**顺序最强**的注入位置） | Chrome："Within a given stage of the document lifecycle, **content scripts declared statically in the manifest are the first to be injected, before content scripts registered in any other way.** They are injected in the order in which they are specified in the manifest."（<https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts#static-declarative>）。动态 `chrome.scripting.registerContentScripts` 在同一 stage 里**排在静态声明之后**，因此只在"需要按用户配置动态增删匹配范围"时才用（本项目 Q-D1 只支持一条固定 URL，静态声明足够） |
| C3 | **必须打包成扩展内的 JS 文件**，不能靠 `executeScript({ func })` 传函数 | `func` 序列化后会丢失模块作用域与状态（尤其是把 `realFetch` 保存在闭包里这件事） |
| C4 | **MAIN world 拿不到 `chrome.*` API** → 需要一个 `ISOLATED` world 的 content script 做桥（`window.postMessage` / `CustomEvent`），把命中信息与响应体交给扩展后台 | 这是本项目"引擎层调 `chrome.downloads`"的必经之路。⚠️ "MAIN world 注入的代码能否调 `chrome.*`"这一点**我没有从官方文档拿到明确表述**，见 §9.13 |
| C5 | 把 handler 判定改成 **R-Q-D1 的"一条精准匹配 URL"** | 不要引入 MSW 的 handler 数组/谓词模型（它假设你拥有全部请求） |
| C6 | 自己处理 **realm 覆盖缺口**：只有页面主 realm 被 patch；Worker / Service Worker / Worklet 内的 `fetch` 不在内 | concept-design §6 风险 4 已经接受"技术上拦不到的 Worker 内请求" |
| C7 | 注入时机要**尽早**且要处理"扩展安装/启用前已加载的页面" | `document_start` 的定义是"injected after any files from `css`, but before any other DOM is constructed or **any other script is run**"（Chrome manifest 文档）。**但这是"文档承诺的 stage 顺序"，不是"相对任意页面脚本的绝对保证"** —— 它保证的是 content script 之间与文档生命周期的相对位置。另外动态注册发生在扩展启动之后，对已加载页面无效，需要 `chrome.tabs.reload` 或接受缺口 |
| C8 | 处理 **MAIN world 的两项已文档化代价** | ① **"When a content script is injected into the main world, the CSP of the page applies."**（Chrome content-scripts 概念页）—— 具体后果未实测，见 §9.2；② **"Warning: There are risks involved when using the `"MAIN"` world. The host page can access and interfere with the injected script."**（Chrome manifest content-scripts 文档）—— 这意味着**页面可以检测甚至拆掉我们的 patch**，与 §4.3 的反检测弱点叠加 |
| C9 | **接受反检测弱点**：`fetch.name` 变 `''`、`Response.type` 是 `'default'` | 若要修，需要自己给替换函数命名、并在 `respondWith` 后 `Object.defineProperty(response, 'type', ...)`。**MSW 不做这件事，本项目要自己做** |
| C10 | 把 `@mswjs/interceptors` **pin 到确切版本** | 0.x 且发布节奏约 1.8 天/版（§8.2），近 3 个版本都在改 TCP/TLS 层 |
| C11 | **不要考虑 `chrome.userScripts`** | 它的 `world: "MAIN"` 功能等价，但需要用户开"Allow User Scripts"开关（Chrome ≥138）或开发者模式（<138）—— **无法正常分发给普通用户**。另外注意：**豁免页面 CSP 的是 `"USER_SCRIPT"` world，不是 `"MAIN"`**（Chrome userScripts 文档） |

### 6.4.1 还有别的路吗？—— 一条值得记下但不建议的路

本文考察的范围内，**唯一另一个**能给任意页面请求"编写响应体"的已文档化 Chrome 能力是 **`chrome.debugger` + CDP `Fetch.fulfillRequest`**（对照：MSW 自己的 comparison 页说 Playwright "Uses the Chrome DevTools Protocol to intercept requests on the browser level"）。

**不建议**，原因：需要 `"debugger"` 权限（权限警告极重）、会显示"XX 正在调试此浏览器"信息栏、且是**网络层**方案 —— 与 R9"JS API 层短路"的裁定方向不符。**列为一条未展开的备选，供"详细设计"阶段参考**（§9.14）。

### 6.5 一句话总结

**"msw 的 Service Worker 路线在 MV3 扩展里拦任意页面"= 不能（平台不允许，且违反 R9）；"借 `@mswjs/interceptors` 的浏览器 JS 层拦截器 + 自研 MAIN world 注入"= 有条件可行，且与 R9 同向。**

---

## 7 官方文档与源码的不一致之处

> **方法说明**：我不能确认上一份调研发现的是哪两处（未读该文件）。以下是我**从零自查**得到的结果，按"证据强度"排序。**判定原则：以发布产物（unpkg / npm tarball）与实际运行为准，其次以 tag 源码为准；文档为最后。**

### 7.1 【强不一致 #1，运行时必然报错】XHR progress recipe 的 import 路径是错的

**文档原文**（`docs-io/src/content/guides/recipes/xmlhttprequest-progress-events.md:14-30`）：

```ts
import { getResponse } from 'msw'
import { XMLHttpRequestInterceptor } from '@mswjs/interceptors'   // ← 第 16 行
import { handlers } from './handlers'

const interceptor = new XMLHttpRequestInterceptor()
```

**源码/发布产物**：`@mswjs/interceptors` v0.45.7 的**根入口不导出任何拦截器**。

`interceptors/src/index.ts` 全文只有 19 行，全部导出是：

```ts
export { Interceptor } from './interceptor'
export { BatchInterceptor } from './batch-interceptor'
export { InterceptorError } from './interceptor-error'
export { RequestController, type RequestControllerSource } from './request-controller'
export type { HttpRequestEventMap, HttpRequestEvent, HttpResponseEvent } from './events/http'
/* Utils */
export { createRequestId } from './create-request-id'
export { getCleanUrl } from './utils/get-clean-url'
export { encodeBuffer, decodeBuffer } from './utils/buffer-utils'
export { FetchRequest, FetchResponse } from './utils/fetch-utils'
export { resolveWebSocketUrl } from './utils/resolve-web-socket-url'
```

**发布产物独立复核**（unpkg，`@mswjs/interceptors@0.45.7/lib/node/index.js` 的最后一行）：

```js
export { BatchInterceptor, FetchRequest, FetchResponse, Interceptor, InterceptorError,
         RequestController, createRequestId, decodeBuffer, encodeBuffer, getCleanUrl,
         resolveWebSocketUrl };
```

**运行时实证**（本机 Node v24.21.0 + 真实安装的 0.45.7）：

```
$ node -e "import { XMLHttpRequestInterceptor } from '@mswjs/interceptors'"
SyntaxError: The requested module '@mswjs/interceptors' does not provide an export named 'XMLHttpRequestInterceptor'

$ node -e "import('@mswjs/interceptors/XMLHttpRequest').then(m=>console.log(Object.keys(m)))"
[ 'XMLHttpRequestInterceptor' ]
```

**哪一方准**：**源码/发布产物准。文档错。**

**正确写法**（interceptors README:333 自己就是对的）：

```ts
import { XMLHttpRequestInterceptor } from '@mswjs/interceptors/XMLHttpRequest'
```

**影响**：这是**开发期就会炸**的 `SyntaxError`（ESM 具名导入在模块实例化阶段校验），不是"运行到某分支才出错"。任何人照抄这页 recipe 都会失败。

**补充**（同一代码块里的另一处问题）：该 recipe 还调 `getResponse(handlers, request)`。这条**是对的** —— msw v3.0.2 从根入口导出 `getResponse`（`src/core/index.ts:32`），签名 `getResponse(handlers, request, resolutionContext?)`（`src/utils/get-response.ts:16-20`）与用法一致。所以这个代码块**只有第一行 import 是坏的**。

### 7.2 【强不一致 #2，已被运行时实验双向坐实】Node 侧"技术上做不到 socket 级拦截"的说法已过时

**文档原文**（`docs-io/src/content/docs/limitations.md:31-33`，全文小节）：

> ### Direct network connections
>
> **Due to technical limitations, MSW cannot intercept requests performed via direct `net.connect()`/`net.createConnection()` calls.** Most request libraries in Node.js rely on `http.ClientRequest` to perform requests, which is what MSW intercepts. However, certain libraries, like [Undici](https://github.com/nodejs/undici), tap directly into the `node:net` module to perform requests, **and those will not be visible to MSW**.

**源码事实**（`@mswjs/interceptors` **v0.45.7** —— 即 msw 3.0.2 自己依赖并实际加载的那份）：

`src/interceptors/net/index.ts:139`：

```ts
/**
 * Interceptor for `net.Socket` connections.
 */
export class SocketInterceptor extends Interceptor<SocketEventMap> {
```

同版本 README（`:99`）对它能力的原话：

> The lowest-level interceptor in this library. **It intercepts _every outgoing TCP and TLS connection_ in Node.js at the `net.Socket` level, no matter which module or third-party package creates it.**

README `:43-44`：

> - **Spies on the network on the socket level by intercepting `Socket.prototype.connect`, `net.connect()`, and `tls.connect()`**;
> - Stubs `TCPWrap`/`TLSWrap` until the connection is either claimed or passed through;

README `:125`（`HttpRequestInterceptor`）：

> Intercepts **all HTTP requests in Node.js, regardless of the client** that issued them. Because the interception happens at the socket level, this includes `http`/`https` modules, the global `fetch`, **direct Undici usage (`fetch`, `request`, pools, agents)**, and any third-party HTTP client built on top of them…

而且 **msw v3.0.2 自己就装上了它**（传递链路，全部源码可见）：

```
msw/src/node/setup-server.ts:17   new ClientRequestInterceptor()
  → interceptors/src/interceptors/ClientRequest/index.ts:21
      Interceptor.singleton(NodeHttpRequestSource)  +  requestSource.apply(this)
  → interceptors/src/interceptors/http/source.ts:48-49
      Interceptor.singleton(SocketInterceptor)  +  socketInterceptor.apply(this)
```

**运行时实证（本机，两向）**：

实验 A —— 用 `setupServer` 做基准（`msw@3.0.2` + `@mswjs/interceptors@0.45.7`，目标主机是一个不存在的域名，因此"没被拦"必然表现为 DNS 失败）：

```
A) http.request              -> status=undefined body=MOCKED-BY-MSW
B) net.connect (raw HTTP)    -> ERROR ENOTFOUND          ← 文档描述的"拦不到"
C) undici.request (direct)   -> ERROR ENOTFOUND          ← 文档描述的"not visible"
D) global fetch              -> status=200 body=MOCKED-BY-MSW
```

实验 B —— 同一进程、同一目标主机，只把拦截器换成 v0.45.7 里已经存在的那两个：

```
[SocketInterceptor] connection event for host = msw-nonexistent-host-for-probe.invalid port = 80
raw net.connect() result  -> CONNECTED (no real DNS was needed!)
[HttpRequestInterceptor] saw: GET http://msw-nonexistent-host-for-probe.invalid/ping
undici.request (direct) result -> status=200 body=INTERCEPTED-AT-SOCKET-LEVEL
```

**"不存在的域名"这条设计是关键**：`SocketInterceptor` 的 `mockLookup`（`net/index.ts:109-134`）把任何主机名解析到 loopback 且不做真 DNS，所以 `CONNECTED` 只可能来自拦截；而实验 A 的 `ENOTFOUND` 证明**那条链路当时确实没被拦**。

**哪一方准？—— 要分开判，这正是不一致的所在：**

| 断言 | 判定 | 理由 |
|---|---|---|
| "**MSW 拦不到** 直接 `net.connect()`" （作为 `setupServer` 的**结果**） | ✅ **仍然准确** | 实验 A 的 B/C 两行 |
| "**Due to technical limitations**"（作为**原因**） | ❌ **已不准确** | 同一个进程里，同一个依赖包的 `SocketInterceptor` 就做到了（实验 B） |
| "those **will not be visible to MSW**" | ❌ **已不准确** | socket 层的解析器**确实看到了**这些字节（`NodeHttpRequestSource` 是 `ClientRequestInterceptor` 主动 apply 的）。它们只是**因为 initiator 谓词不匹配而没有被转发给 MSW 的 handler** —— 那是 **msw 的路由选择**，不是"技术限制"，也不是"不可见" |

**分歧的精确机制**（三行源码）：

```ts
// interceptors/src/interceptors/ClientRequest/index.ts:32-34
predicate: (initiator) => {
  return initiator instanceof http.ClientRequest
},
```

```ts
// interceptors/src/interceptors/http/forward-events.ts:25-38
source.on('request', async (event) => {
  if (predicate(event.initiator)) {          // ← 原始 net.connect / 直接 undici 的 initiator 是 net.Socket，不匹配
    await emitter.emitAsPromise(event)
  }
}, /* … */)
```

而 `HttpRequestInterceptor`（`http/index.ts:28-30`）的谓词是 `() => true`，所以它能收到。**msw 没有用 `HttpRequestInterceptor`**（`setup-server.ts:16-21`），这才是差别的全部来源。

**对 docs 的公平说明**：`limitations.md` 的主语是"MSW"，对 MSW 而言结论没错。**错的是给了一个"技术限制"的归因**，而这个归因在同一组织、同一依赖树的 v0.45.7 里已经被证伪。文档停留在 interceptors 还是 `http.ClientRequest` patch 时代的认知（socket 级改动于 **v0.42.0** 落地，commit `8a8fe6f feat!: TCP/TLS wrap-based interception (#770)`，2026-07-22）。

### 7.3 【附带发现 #3】"MSW 用 `path-to-regexp@6` 匹配 URL" —— v3 已不再使用

**文档原文**（`docs-io/src/content/docs/http/intercepting-requests/index.md:40`）：

> MSW will use [`path-to-regexp@6`](https://github.com/pillarjs/path-to-regexp/tree/6.x) to match your predicate against outgoing requests to determine if they match. We highly recommend you familiarize yourself with the feature set of that library.

**源码事实**：

`msw/src/core/utils/matching/match-request-url.ts:1-2`：

```ts
import { matchPattern } from '@msw/url'
import { getCleanUrl } from '@mswjs/interceptors'
```

`msw@3.0.2` 的 12 个运行时依赖里**没有 `path-to-regexp`**：

```
@inquirer/confirm, @msw/url, @mswjs/interceptors, cookie, headers-polyfill,
is-node-process, outvariant, rettime, tough-cookie, type-fest, until-async, yargs
```

本机真实安装后复核：`ls node_modules | grep path-to-regexp` → **NOT PRESENT**。

`@msw/url@0.1.2` 的 `dependencies` 是**空的**（`{}`），它用自己实现的 `matchPattern`；`path-to-regexp` 只出现在它的 **devDependencies**（`"path-to-regexp": "^8.4.2"`，用于基准对比与合规参照）。`@msw/url` README:44 自述：

> `matchPattern` uses token-based comparison to completely forego regular expressions… **Doesn't promise full feature parity with `path-to-regexp`** but currently uses its test suite as the compliance bar.

**哪一方准**：**源码准，文档错**。而且这不是"换个库"这么轻 —— 文档**承诺了 `path-to-regexp@6` 的完整特性集**，而新实现明确声明**不保证特性对齐**。用户按文档写复杂 pattern 会踩坑。

### 7.4 【附带发现 #4】"不 patch `fetch`" / "用类扩展而非模块 patch" —— 与 v3 实装相反

**文档原文**（`docs-io/src/content/docs/index.md`）：

> `:18` MSW uses the Service Worker API to intercept actual production requests on the network level. **Instead of patching `fetch`** and meddling with your application's integrity, MSW bets on the platform…
>
> `:20` Even in Node.js, where there are no standard means to intercept requests, **MSW uses _class extension_ instead of module patching** to ensure your tests run in the environment as close to production as possible.

**源码事实**：

1. 浏览器侧**存在**一条 patch `fetch` 的路线：`fallback-http-source.ts:13` → `FetchInterceptor` + `XMLHttpRequestInterceptor`，二者分别 patch `globalThis.fetch`（`fetch/web.ts:37`）与 `globalThis.XMLHttpRequest`（`XMLHttpRequest/web.ts:21`）。
2. Node 侧**全程是模块/prototype patch**，工具类就叫 `patchesRegistry`（`src/utils/patches-registry.ts:102`），调用点包括 `globalThis.fetch`、`globalThis.XMLHttpRequest`、`globalThis.WebSocket`、`http`/`https` 的 `get`/`request`/`ClientRequest`、`net.Socket.prototype.connect`、`http.Agent.prototype.addRequest`。

**"class extension" 在本仓库的检索结果**：`grep -rn "class extension" src/ test/` → **0 命中**。`extends` 只出现在拦截器自身的类继承（`extends Interceptor<…>`）与 `FetchResponse extends Response` 上。

**哪一方准**：**源码准，文档是过时/理想化表述**。这段文字描述的是 v1/v2 早期的设计姿态。

**但要说公道话**：`:18` 对"主路线"的描述是**对的** —— 浏览器里 HTTP 默认确实走 SW。问题在于这句话是**无条件全称判断**（"Instead of patching `fetch`"），而 v3 引入了条件分支。

### 7.5 【附带发现 #5】comparison 表格里"Uses a Service Worker"的绝对化表述

`docs-io/src/content/docs/comparison.md:378`（对 Playwright 一节）、`:173`（对 Mirage 一节）、`:305`（对 Cypress 一节）都写：

> Uses a Service Worker to intercept requests on the browser level.

**源码事实**：v3 里这是**条件**成立（`setup-worker.ts:51-63`），当 `!supportsServiceWorker()`（无 `navigator.serviceWorker` 或 `file:` 协议）时走 `FallbackHttpSource`，那是 `XMLHttpRequestInterceptor` + `FetchInterceptor` 的**纯 JS patch**（`fallback-http-source.ts:13`），**没有 Service Worker**。

**判定**：v2 时代准确，v3 起不完整。对 `file:` 打开的本地 HTML（很常见的 demo 场景）就是错的。

### 7.6 【附带发现 #6，行为性】"装包时自动更新 worker 脚本" —— 该机制在 v3.0.0 已被删除，文档仍在承诺

**文档原文**（两处）：

`docs-io/src/content/api/cli/init.md:57`：

> If this property is present, **whenever you install the `msw` package, the worker script will be copied to the `msw.workerDirectory` destination automatically.** This ensures the worker script being in sync with the currently installed version of the library.

`docs-io/src/content/guides/best-practices/managing-the-worker.md:45-47`：

> It is still recommended to keep the worker script up-to-date with the installed version of MSW. **That is why we recommend using the `--save` flag with the `msw init` command.**
>
> When run with the `--save` flag, the `msw init` command will save the used public path in `package.json`. **Later, whenever you upgrade or downgrade the `msw` dependency, it will automatically generate the worker script at the saved path to keep you in sync.**

**源码/发布产物事实**（按 tag 逐个核对，命令见下）：

| tag | `config/scripts/postinstall.js` | `package.json` 的 `postinstall` 键 |
|---|---|---|
| `v2.11.4` | **EXISTS** | — |
| `v2.14.4` | **EXISTS** | — |
| **`v2.15.0`**（最后一个 v2） | **EXISTS** | `node -e "import('./config/scripts/postinstall.js').catch(() => void 0)"` |
| **`v3.0.0`** | **ABSENT** | **（无）** |
| `v3.0.1` | ABSENT | （无） |
| **`v3.0.2`** | **ABSENT** | **（无）** |

删除者是 **v3.0.0 的同一个 commit**：

```
$ git log --oneline v2.15.0..v3.0.2 --diff-filter=D -- config/scripts/postinstall.js
2bb43428 feat!: v3.0.0 (#2692)
```

**发布产物三重复核**（不只是看源码）：

1. `curl https://unpkg.com/msw@3.0.2/config/scripts/postinstall.js` → **HTTP 404**（51 字节错误体）
2. 本机 `npm install msw@3.0.2` 后：`ls node_modules/msw/config/scripts/` → **No such file or directory**
3. 本机安装后的 `package.json` 的 `scripts` 里 **没有 `postinstall`**，`files` 里却**仍然列着** `"config/scripts/postinstall.js"`（`package.json:119`）—— 一个失效的白名单条目

**为什么这条比前几条更"伤"**：这是一条**行为承诺**，不是措辞问题。

- 用户照文档加 `--save`、把 `workerDirectory` 写进 `package.json`，然后升级 `msw`，**期待 worker 脚本自动同步 —— 实际不会发生**。
- 而 worker 脚本版本不匹配在运行时会撞上 MSW 自己的 **integrity check**（`service-worker-source.ts:406-433`），控制台出现：

  > The currently registered Service Worker has been generated by a different version of MSW (`${packageVersion}`) and may not be fully compatible with the installed version.

- 也就是说：**文档的失效承诺，直接生产出一条用户看不懂的运行时警告。** 用户唯一的补救是重新手动跑 `npx msw init <PUBLIC_DIR>` —— 而文档只在"生成 worker 脚本"一节提过这条命令，并没有说"现在这是唯一途径"。

**哪一方准**：**发布产物准，文档错**。且时间线同样不利：删除发生在 **2026-09-28**（v3.0.0），文档站改版在 **2026-09-30**（2 天后），**仍未修正**。

> **顺带更正我自己的一处初判**：我最初在 §8.4 写"msw 带 postinstall"，**这是错的** —— 依据是 `files` 白名单里的陈旧条目，未核对 `scripts` 键与发布产物。已按上述三重复核改正。**这正是"不能只看一个来源"的实例。**

### 7.7 本节小结

| # | 位置 | 文档说 | 源码/产物说 | 谁准 | 后果 |
|---|---|---|---|---|---|
| 1 | `guides/recipes/xmlhttprequest-progress-events.md:16` | 从 `@mswjs/interceptors` 根入口导入 `XMLHttpRequestInterceptor` | 根入口不导出任何拦截器 | **源码** | 照抄即 `SyntaxError` |
| 2 | `docs/limitations.md:31-33` | 因技术限制，MSW 无法拦 `net.connect()`/直接 Undici，且"不可见" | v0.45.7 有 `SocketInterceptor`；msw 自己传递性地装了它；只是被 initiator 谓词过滤 | **源码（就"技术限制/不可见"而言）**；文档就"MSW 结果"而言仍对 | 误导用户以为能力天花板在平台 |
| 3 | `docs/http/intercepting-requests/index.md:40` | 用 `path-to-regexp@6` | 用 `@msw/url` 的 `matchPattern`，无 `path-to-regexp` 依赖，且**不保证特性对齐** | **源码** | 复杂 pattern 行为不符预期 |
| 4 | `docs/index.md:18,20` | 不 patch `fetch`；Node 用类扩展不用模块 patch | 两处都 patch；工具类名为 `patches-registry` | **源码** | 对"会不会污染我的环境"的判断失真 |
| 5 | `docs/comparison.md:173,305,378` | 用 Service Worker 拦截 | v3 起是条件分支（可退化为 JS patch） | **源码** | `file:` 场景描述错误 |
| 6 | `api/cli/init.md:57` + `guides/best-practices/managing-the-worker.md:45-47` | 装/升降级 `msw` 时 worker 脚本会**自动同步**到 `msw.workerDirectory` | v3.0.0 起 `postinstall` 与 `config/scripts/postinstall.js` **已被删除**（unpkg 404 / 本地安装无此文件） | **发布产物** | **行为性失效**：脚本不会自动更新，转而触发运行时 integrity 警告 |

**共性**：文档站（`mswjs.io`）在新站点改版（`2294105 new site for msw 3.0 release (#536)`，2026-09-30）中**未同步**底层库与 CLI 的重大变更。注意不一致 #2 与 #6 的时间关系：

| 变更 | 落地时间 | commit |
|---|---|---|
| interceptors 改为 socket 级拦截（→ 不一致 #2） | **2026-07-22**（v0.42.0） | `8a8fe6f feat!: TCP/TLS wrap-based interception (#770)` |
| 删除 postinstall（→ 不一致 #6） | **2026-09-28**（v3.0.0） | `2bb43428 feat!: v3.0.0 (#2692)` |
| 文档站改版 | **2026-09-30** | `2294105 new site for msw 3.0 release (#536)` |

即：**改版晚于两处变更，却两处都没修正。** 这说明问题不是"文档还没跟上"，而是**改版时没有把源码当基准做核对**。

**对使用者的操作建议**：以 **tag 源码 + 发布产物 + README（interceptors 那侧）** 为准；`mswjs.io/docs` 的机制性描述在使用前应逐条回源码验证。本报告 §7 的六条可作为一份最小核对清单。

---

## 8 许可证、维护状态、成熟度

### 8.1 许可证

| | msw | @mswjs/interceptors |
|---|---|---|
| 文件 | `LICENSE.md`（**不是 `LICENSE`**） | `LICENSE.md` |
| 字节数 | 1085 | 1085（前 4 行逐字节相同） |
| `package.json` `license` | `"MIT"`（第 115 行） | `"MIT"`（第 59 行） |
| 结论 | **MIT** ✅ | **MIT** ✅ |

`msw/LICENSE.md` 前 5 行：

```
MIT License

Copyright (c) 2018–present Artem Zakharchenko

Permission is hereby granted, free of charge, to any person obtaining a copy
```

**一处小瑕疵（不影响授权）**：interceptors 的 LICENSE 也写 `2018–present`，但它的 git 历史始于 **2020-04-26**（`f83f11ba…`），npm 包创建于 **2021-03-22**。这是从 msw 继承来的模板年份，不是真实年份。

**MIT 对本项目的含义**：可自由用于闭源/商业扩展，只需保留版权与许可声明。**没有 copyleft 传染风险。**

### 8.2 维护状态（全部来自本地完整 git 克隆）

| 指标 | msw | @mswjs/interceptors |
|---|---|---|
| HEAD | `501a5916…`（`v3.0.2-1`） | `49d79017…`（**精确等于 v0.45.7**） |
| HEAD 日期 | 2026-10-05 | 2026-10-04 |
| 首个 commit | **2018-11-13** | **2020-04-26** |
| commit 总数 | 1802 | 875 |
| 近 30 天 commit | **13** | **44** |
| 近 90 天 commit | **13** | 55 |
| 近 365 天 commit | 122 | 97 |
| 不同作者（author 字符串） | 193 | 76 |
| 主要作者 | Artem Zakharchenko 1904；Matt Sutkowski 37；marcosvega91 34；dependabot 28 | Artem Zakharchenko 1169；Michael Solomon 40；dependabot 22 |
| tag 总数 | 316 | 250 |
| 近 12 个月 release | **37**（`v2.11.4` 2025-10-08 → `v3.0.2` 2026-10-03） | **31**（`v0.39.8` 2025-10-13 → `v0.45.7` 2026-10-04） |
| 最近 10 个 release 的平均间隔 | **约 17.4 天** | **约 1.8 天** |

**需要点名的三个"数字陷阱"**（任何自动化管道都会踩）：

1. **`git log --reverse --format=%ad -1` 不返回首个 commit**（`-1` 在 reverse 之前生效，返回的是 HEAD）。正确写法：`git log --format=%ad | tail -1`。
2. **msw 的近 30 天活跃度是"平的"**：`git log --oneline --since=2026-07-09 --until=2026-09-05 | wc -l` → **0**，即 **2026-07-09 → 2026-09-05 有 59 天空窗**，随后在 v3.0.0（2026-09-28）前后爆发。月度：`02=14, 03=15, 04=27, 05=12, 06=0, 07=9, 08=0, 09=9, 10=4`。
3. **"不同作者数"被身份拆分夸大**：`Artem Zakharchenko` 与 `kettanaito` 是同一人，被计两次。保守值：msw 192 / interceptors 75。另外 `git shortlog -sn --all` 统计的是**全部 ref**（msw 2375 commit / interceptors 1348），与 `rev-list --count HEAD`（1802 / 875）不是同一个 commit 宇宙。

**tag 卫生（对自动化消费有实际影响）**：两个仓库都**混用轻量 tag 与附注 tag**（msw 208/108，interceptors 197/53），而 `%(creatordate)` 对两者语义不同；msw 有一个**缺 `v` 前缀的 tag `0.5.1`**；msw 的 `v0.0.1` 日期是 2024-03-15（back-applied，不代表早期发布）。

**最近三个版本的走向**（从 atom feed 与 git log）：

- `interceptors v0.45.7`（2026-10-04）：`net: prevent overlapping writes on a passthrough tls socket after the handle swap (#855)`
- `interceptors v0.45.6`（2026-09-29）：`http: intercept exchanges inside real "CONNECT" tunnels and TLS over provided sockets (#851)` + `ClientRequest: copy Headers subclasses that store headers outside the native store (#852)`
- → **最近 3 个版本全部集中在 CONNECT / TLS passthrough 区域**，这是当前的活跃工作面，也是**稳定性风险面**。
- `msw v3.0.2`（2026-10-03）：单行修复，`vite: support virtual:msw imports in vitest (#2802)`。

### 8.3 社区规模

**GitHub REST API 全程 403（硬限流）**，因此下列数字来自**渲染页 HTML 抓取**（页面内嵌 JSON + `Counter` 元素），已标注来源：

```
# https://github.com/mswjs/msw
id="repo-stars-counter-star" aria-label="18263 users starred this repository" ... title="18,263"
"stargazerCount":18263, "watcherCount":65, "forksCount":629, "defaultBranch":"main"
# https://github.com/mswjs/interceptors
id="repo-stars-counter-star" aria-label="689 users starred this repository" ... title="689"
"stargazerCount":689, "watcherCount":7, "forksCount":175
```

| 指标 | msw | @mswjs/interceptors |
|---|---|---|
| Stars | **18,263** | **689** |
| Forks | 629 | 175 |
| Watchers（页面 `watcherCount`） | 65 | 7 |
| Open issues | 12 | **21** |
| Open PRs | 1 | **7** |

**npm 下载量**（`api.npmjs.org/downloads/point/...`，全部 HTTP 200）：

| 窗口 | msw | @mswjs/interceptors |
|---|---|---|
| 上周（2026-09-28 → 10-04） | **26,798,820** | **28,432,828** |
| 上月 | 87,549,356 | 93,854,910 |
| 单日（2026-10-04） | 1,943,857 | 2,011,168 |

**注意**：`@mswjs/interceptors` 的下载量**高于** msw，但那是**传递依赖流量**（它是 msw、nock 等的底座），不代表独立使用规模。star 数（689 vs 18,263）才是"知名度"的指示。

**发布物规模**：

| | msw 3.0.2 | @mswjs/interceptors 0.45.7 |
|---|---|---|
| `dist.unpackedSize` | 3,347,702 B（约 3.2 MB） | 1,816,732 B（约 1.7 MB） |
| `dist.fileCount` | 257 | 193 |
| 直接依赖数 | 12 | 6 |
| `engines` | `{"node": ">=22.12.0"}` | `{"node": ">=22"}` |
| `type` | `module`（**ESM-only**） | `module`（**ESM-only**） |
| SLSA provenance | ✅ 有（2 个签名） | 未核查 |
| `bugs` 字段 | **缺失** | **缺失** |
| `homepage` | `https://mswjs.io` | **缺失** |
| 维护者 | **单人**：`kettanaito` | **单人**：`kettanaito` |
| 资助 | `https://github.com/sponsors/mswjs` | — |

### 8.4 是否适合作为生产依赖

**结论：`msw` 不适合；`@mswjs/interceptors` 有条件适合（需 pin + 自测）。**

**`msw` —— 不适合作为本项目的生产依赖：**

1. **它的自我定位就是开发期工具。** `docs/limitations.md:27`："Mock Service Worker positions itself as a **development tool**"。README 的安装方式是 `npm install msw --save-dev`（`quick-start.md:16`）。
2. **3.2 MB / 257 文件** 的生产体积，绝大部分（CLI、Vite 插件、`config/`、`src/`）对运行时无用。`files` 白名单是 `["config/constants.js", "config/scripts/postinstall.js", "cli", "lib", "src", "LICENSE.md", "README.md"]` —— 其中 `config/scripts/postinstall.js` 是一个**失效条目**（该文件在 v3.0.0 已删除，unpkg 上 404，见 §7.6）。
   > **无 postinstall 脚本**（我核对过 `scripts` 键、发布产物与本地安装三处）：`msw@3.0.2` 的 `scripts` 里**没有** `postinstall`。所以安装 msw 不会执行任何脚本。**这是我本次调研中自己先判错、后经三重复核改正的一点**（详见 §7.6 末的更正说明）。
3. **12 个直接依赖**，含 `yargs` / `@inquirer/confirm` / `tough-cookie`（CLI 用），对一个只想 patch `fetch` 的扩展是纯负担。
4. **ESM-only + `node >= 22.12.0`**，与浏览器扩展的打包链需要额外适配。
5. **v3.0.0 刚 breaking（8 天前）**，`3.x` 的 API 仍在收敛（`src/core/experimental/` 这个目录名本身就是信号）。
6. **它的核心能力（SW 路线）在本项目里不可用**（§6）。

**`@mswjs/interceptors` —— 有条件适合：**

✅ 有利因素：

- MIT，无传染性；
- 1.7 MB / 6 依赖，相对克制；有正式的浏览器构建（`lib/browser/*`，`platform: browser`，`target: chrome120`）；
- 无 postinstall；
- 有 SLSA provenance 的是 msw（本包未核查）；
- 你要用的两个类（`FetchInterceptor` / `XMLHttpRequestInterceptor`）**接口极小**（`apply` / `dispose` / `on('request')` / `controller.respondWith|passthrough|errorWith`），即使将来弃用，自研替代的成本可控。

⚠️ 风险因素：

- **0.x 版本号**，语义化版本承诺不覆盖 minor；
- **约 1.8 天一个 release**，且近 3 个版本都在改 CONNECT/TLS —— 变更密度高；
- **单维护者**（bus factor = 1）；
- **无 `bugs` URL**（issue 只能走 GitHub 仓库页）；
- **ESM-only**，`engines.node >= 22`；
- 它的自我定位（README:52-54）是"**给写 mock 库的人用的低层库**"，不是"给应用用的稳定依赖"。README:54 原话："As a rule of thumb, if you're uncertain whether you need Interceptors, you likely don't."

**建议（如果采用）**：

1. **pin 到确切版本**（`"@mswjs/interceptors": "0.45.7"`，不要 `^`）；
2. **只 import 需要的子路径**（`/fetch/web`、`/XMLHttpRequest/web`），不要根入口；
3. **在扩展打包层做一层自己的适配接口**，把 `Interceptor` / `RequestController` 挡在内部，便于将来替换；
4. 锁定后**自建回归测试**（尤其 `Response.url` / `Response.type` / `headers` 保真度），因为上游不承诺这些行为稳定。

---

## 9 未验证 / 存疑

按"影响面 × 不确定度"排序。每条写清**试过哪些通道、各自怎么失败的**。

**9.1 `mswjs.io` 活站与 main 分支是否逐字一致 —— 未验证**
我用的是文档仓库 `mswjs/mswjs.io` 的 main HEAD（`6107625`，2026-10-05）。**没有**逐页抓活站做 diff。风险：若活站部署的是旧 commit，§7 的引文行号可能对不上。**缓解**：所有引文都给了仓库路径 + 行号，可复现；活站 URL 亦可在 `https://mswjs.io/<path>` 拼出。未做的原因：345 个 content 文件逐页抓取成本高、收益低。

**9.2 浏览器侧行为**（`Response.type`、CSP 交互、`fetch.name` 的真实表现）—— **部分未验证**
- `fetch.name === ''`：**我在 Node v24.21.0 上实测确认**（patch 前 `"fetch"` → patch 后 `""`）。**浏览器未实测**，但这是纯 JS 语义（匿名箭头函数没有推断名），与运行时无关。
- `Response.type === 'default'`（浏览器）：来自仓库自带测试的**断言文本**（`fetch-response-init.neutral.test.ts:50-52`，browser 项目 = Playwright/Chromium，`vitest.config.ts`），**我没有运行该测试**，也没有浏览器可用。**结论按"仓库自述的期望行为"采信，非我实测。**
- Chrome 文档 "When a content script is injected into the main world, **the CSP of the page applies**"（`content-scripts` 概念页）—— 原文已引。但**实际后果未验证**：MV3 的 `world: "MAIN"` 注入是否会被页面的 `script-src` 拦下、还是仅影响被注入脚本内部的 `eval`/动态 import，我**没有可用的浏览器环境**。试过的通道：Chrome 官方文档（引文如上）、Chrome 扩展 API 参考；**未试**：Chromium 源码 `content_script.cc` / 实机实验。→ **§6 的 C8 必须实机验证后再定。**

**9.3 Node.js 内部机制**（`IncomingMessage` 如何从 push 进来的字节构造、llhttp 解析细节）—— 未验证
interceptors 只是把真字节 `socket.push()` 进客户端 socket（`http/source.ts:691-696`），后续构造发生在 `nodejs/node` 的 `lib/_http_client.js`，**不在两个克隆里**。llhttp 只提供了 `llhttp.wasm` + `constants.cjs`，**不可源码阅读**。

**9.4 SW 对 `no-cors` / 跨域请求的可返回范围 —— 部分未验证**
拿到的是规范 §4.6.7 的一句注释（"Renderer-side security checks about tainting for cross-origin content are tied to the types of filtered responses defined in Fetch."）。**没有**继续追到 Fetch 标准里"filtered response"的具体表格，也**没有**实机验证"SW 能不能给 `no-cors` 请求返回一个可读的非 opaque 响应"。`grep -rn -i "no-cors|opaque|cross-origin|cors"` 在 `docs-io/src/content/docs/*.md` 与 `api/setup-worker/*.md` 中 → **0 命中**，即 MSW 官方**没有**就此表过态。→ 若本项目关心 CORS 语义（R9 说本项目不适用 CORS，所以影响有限），需另行取证。

**9.5 SW `fetch` 事件对 `<img>` / `<script>` / 导航的确切覆盖矩阵 —— 部分未验证**
我确认了：导航有专门分支（`mockServiceWorker.js:427`），子资源会走同一个 fetch 事件（平台语义）。**没有**用实机逐类验证。另外 MSW 的 `isCommonAssetRequest()` 只是**降噪**，不是"不拦截"（§3.4）。若需精确矩阵，应实机跑一遍。

**9.6 `@mswjs/interceptors` 的 ESM 子路径类型解析 —— 未验证**
它的 `exports` 子路径**没有任何 `types` 条件**（14 个子路径全部只有 `browser`/`default`/`node`），只靠顶层 `main` + `types`。根 `.d.ts` 存在（unpkg → HTTP 200，3784 B），但 `@mswjs/interceptors/fetch` 在 `moduleResolution: node16`/`bundler` 下**能否解析到类型**，**未验证**。→ 若本项目用 TypeScript，这是一个前置验证项。

**9.7 `msw` 的 `./vite/client` 把类型指向 `./src/vite/client.d.ts`（发布包里的源码路径）—— 只验证了存在性**
unpkg → HTTP 200，380 B。**没有**验证它能否通过类型检查，也没有确认把 `src/` 打进包是有意为之。

**9.8 GitHub `pushed_at` / `subscribers` / contributor 总数 —— 未验证**
API 全程 403（`x-ratelimit-remaining: 0`，reset 2026-10-06 10:57:24Z，无 token）。替代：本地 HEAD commit 日期作为 `pushed_at` 的**代理**；页面内嵌 `watcherCount`（65 / 7）作为 `subscribers` 的**代理**（二者是否同一量未确认）；`git shortlog` 的 author 字符串数（193 / 76）作为 contributor 数的**代理**（被身份拆分夸大）。`/watchers` 页面 → HTTP 404（路由已移除）。

**9.9 `rettime` 的内部行为 —— 未验证**
`Emitter` / `emitAsPromise` / `hooks` / 通配 `'*'` / 保留事件 `newListener`/`removeListener` 都来自 `rettime@^0.11.12`，两个克隆都没有 `node_modules`。**相关源码级事实不受影响**：`handle-request.ts:125-132` 用 `Promise.race([...])` 且**从不读取 `emitAsPromise` 的解析值**，所以"listener 的返回值（包括返回 `Response`）在本版本里不起作用"这一条是可从本仓库源码确认的。

**9.10 msw HEAD 与 tag v3.0.2 的严格对应 —— 已验证但需说明**
`git describe --tags` = `v3.0.2-1-g501a5916`，`git diff --stat v3.0.2..HEAD` **只列 `media/github-social-preview.png`**。所以严格说：我读的源码是**标签之后的 HEAD**，但源码内容等价于 v3.0.2。npm 上发布的 3.0.2 **比这个 HEAD 早 1 个 commit**（发布 2026-10-03，该 commit 2026-10-05）。

**9.11 我没有运行的验证**
- 没有跑仓库自带的测试套件（两个克隆都没有 `node_modules`，也没有 `lib/` 构建产物）。
- 没有在真实浏览器里跑 `setupWorker`。
- 没有实测 MV3 扩展（**这是 §6 结论中唯一"没有实机证据"的部分**，但结论依据的是规范级同源约束 + 规范级 scope 约束 + MSW 源码里的标准 `register()` 调用，三者互相印证；且"扩展能不能注册跨源 SW"这一具体问题有三条各自充分的规范级阻断理由，见 §3.1 P0/P2/P4）。

**9.12 关于"上一份调研发现的那两处不一致" —— 无法确认是否同一组**
我**没有读** `msw.md`（按任务要求）。所以我找到的 §7.1 / §7.2 **未必**就是上一份报告卡住的那两处。项目负责人对照时请把这一点纳入考虑：本报告的两处是**独立定位**的结果，结论方向是"源码/发布产物为准"。

**9.13 MAIN world 注入的两个"文档没说清"的点 —— 未验证，且**不**可断言**
- **MAIN world 注入的代码能否调用 `chrome.*` 扩展 API？** 检索到的 Chrome 文档页**没有任何明确表述**（既没说可以，也没说不行）。→ **不要断言**。这直接影响 §6.4 的 C4（要不要桥）。
- **页面的 CSP `script-src` 会不会阻断 `chrome.scripting` 的 MAIN world 注入本身？** Chrome 只说了 "When a content script is injected into the main world, the CSP of the page applies."。Chromium 源码显示 MAIN world 走 `ExecuteScriptPolicy::kDoNotExecuteScriptWhenScriptsDisabled` → `LocalDOMWindow::CanExecuteScripts` → `ScriptEnabled()`，但**没有**追通"CSP → `ScriptEnabled()`"这段管道。→ **不要断言**，需实机矩阵验证。

**9.14 `chrome.debugger` + CDP `Fetch.fulfillRequest` —— 未调查**
它是本次考察范围内**唯一另一个**能给任意页面请求编写响应体的已文档化 Chrome 能力（MSW 自己的 comparison 页把 Playwright 归为 "Uses the Chrome DevTools Protocol to intercept requests on the browser level"）。**没有**验证它的可行性、权限成本、与 MV3 的兼容性。列为 §6.4.1 的备选，供后续阶段按需展开。

**9.15 判定"扩展无法注册跨源 SW"时我依赖的规范版本**
用的是 W3C Editor's Draft（`https://w3c.github.io/ServiceWorker/`）。任务提示里提到的 `https://service-worker-speci.netlify.app/` **返回 HTTP 404**（该镜像不存在）。另外需要纠正一个常见的归属错误：**Service Workers 是 W3C 规范，不是 WHATWG 标准**。

---

## 10 证据清单

### 10.1 本地克隆（全部为完整克隆，非 shallow）

| 路径 | 内容 | 标识 |
|---|---|---|
| `/tmp/mswres/msw` | `mswjs/msw` 全历史 | HEAD `501a591640648c86b9733167eab7d29339671eec`（`v3.0.2-1-g501a5916`），316 tag，1802 commit |
| `/tmp/mswres/interceptors` | `mswjs/interceptors` 全历史 | HEAD `49d7901772d5c07b71d75b7470a2562ef28c3755`（**= tag `v0.45.7`**），250 tag，875 commit |
| `/tmp/mswres/docs-io` | `mswjs/mswjs.io` 官方文档源码 | HEAD `610762537b2d672fc6820ac27ce1c00a1e41a4a3`（2026-10-05） |
| `/tmp/mswtest` | 真实安装的运行时：`msw@3.0.2` + `@mswjs/interceptors@0.45.7` + `undici` | Node v24.21.0，npm 11.19.0 |

> 克隆命令：`git clone https://github.com/mswjs/<repo>.git`（无 `--depth`）。文档站随后 `git fetch --unshallow`。

### 10.2 源码位置索引（可直接跳转）

**`msw/src/mockServiceWorker.js`（460 行，SW 路线本体）**

| 行 | 内容 |
|---|---|
| 10-12 | `PACKAGE_VERSION` / `INTEGRITY_CHECKSUM` / `IS_MOCKED_RESPONSE` |
| 14-18 | `activeClientIds` / `pendingRequests`（**内存态**） |
| 20-26 | `install` → `skipWaiting()`；`activate` → `clients.claim()` |
| 28-120 | `message`：`CLIENT_CLOSE` / `KEEPALIVE_REQUEST` / `INTEGRITY_CHECK_REQUEST` / `MOCK_ACTIVATE` |
| **122-141** | **`fetch` 监听器（拦截入口）** |
| 125-130 | `only-if-cached` 旁路（DevTools 副作用） |
| 135-137 | 无 active client 时旁路 |
| 147-234 | `handleRequest` |
| 200-206 | event-stream 响应不 clone |
| 208-230 | 向页面回报 `RESPONSE`（含 `isMockedResponse`） |
| 244-269 | `resolveMainClient`（多 client 选主） |
| 277-360 | `getResponse`（页面 RPC 协议） |
| 285-320 | `passthrough()`（剥离 `msw/passthrough`） |
| 322-333 | 未激活时旁路 |
| 386-403 | `sendToClient`（`MessageChannel` + transferable） |
| 410-439 | `respondWithMock`（含导航流缓冲、`IS_MOCKED_RESPONSE`） |
| 444-460 | `serializeRequest` |

**`msw/src/browser/**`（页面侧编排）**

| 文件:行 | 内容 |
|---|---|
| `setup-worker.ts:16` | `DEFAULT_WORKER_URL = '/mockServiceWorker.js'` |
| `setup-worker.ts:51-63` | SW vs `FallbackHttpSource` 条件分支 |
| `setup-worker.ts:65-76` | sources 装配：HTTP source + `WebSocketInterceptor` |
| `sources/service-worker-source.ts:112-155` | `enable()`：等 activated → `MOCK_ACTIVATE` → 等 `MOCKING_ENABLED` |
| `sources/service-worker-source.ts:191-210` | `terminate()` → `registration.unregister()` |
| `sources/service-worker-source.ts:212-301` | `#startWorker()` |
| `sources/service-worker-source.ts:293-299` | 5s keepalive + `validateWorkerScope` |
| `sources/service-worker-source.ts:406-433` | integrity check（校验 worker 脚本版本） |
| `sources/fallback-http-source.ts:10-15` | **浏览器 JS 层备胎**：`XMLHttpRequestInterceptor` + `FetchInterceptor` |
| `utils/get-worker-instance.ts:19-25` | `navigator.serviceWorker.getRegistrations()` |
| **`utils/get-worker-instance.ts:59`** | **`navigator.serviceWorker.register(url, options)`** |
| `utils/get-worker-instance.ts:74-85` | 404 时提示 `npx msw init` |
| **`utils/validate-worker-scope.ts:8-19`** | **scope 校验 + `Service-Worker-Allowed` 提示** |
| `utils/supports.ts:5-12` | `supportsServiceWorker()`（含 `file:` 排除） |
| `utils/supports.ts:19-30` | `supportsReadableStreamTransfer()` |
| `utils/worker-channel.ts:7-23` | 页面↔worker 消息协议全表 |
| `utils/worker-channel.ts:80-86` | `MOCK_RESPONSE` / `PASSTHROUGH` |
| `utils/get-worker-by-registration.ts:7-27` | 按 scriptURL 谓词认领 worker |

**`msw/src/node/setup-server.ts:16-21`** — Node 默认拦截器清单（**没有** `HttpRequestInterceptor`）

**`msw/src/utils/`**

| 文件:行 | 内容 |
|---|---|
| `passthrough.ts:3,23-31,40-46` | `x-msw-intention` 魔术 302 |
| `bypass.ts:17-56,43,54` | `accept: msw/passthrough` 标记 + 删 `content-length` |
| `get-response.ts:16-29` | `getResponse(handlers, request, ctx?)` |
| `is-common-asset-request.ts` | 静态资源降噪白名单 |

**`msw/src/core/`**

| 文件:行 | 内容 |
|---|---|
| `index.ts:32,81,82,83` | 根导出：`getResponse` / `bypass` / `passthrough` / `isCommonAssetRequest` |
| `experimental/sources/interceptor-source.ts:43-60` | `InterceptorSource` → `BatchInterceptor` |
| `utils/matching/match-request-url.ts:1-2,22-45` | `@msw/url` 的 `matchPattern` + `{matches, params}` |
| `utils/execute-handlers.ts:39-56` | 穿透匹配 + 遇响应即停 |

**`interceptors/src/**`（v0.45.7）**

| 文件:行 | 内容 |
|---|---|
| **`index.ts:1-19`** | **根入口全部导出（无任何拦截器）** |
| `interceptor.ts:5-16,32-45,56-57,59-100` | `Interceptor` 生命周期 / `singleton` / `apply` / `dispose` |
| `batch-interceptor.ts:63-66,71-99,101-114,116-143` | `BatchInterceptor` |
| `request-controller.ts:16-20,45-60,70-99,109-130` | 四态机 + `passthrough/respondWith/errorWith` + 单次处理 `invariant` |
| `events/http.ts:88-92` | `HttpRequestEventMap = { request, response, unhandledException }` |
| `utils/handle-request.ts:113-143,163-215,218-224` | 事件派发 + 未处理则 passthrough + 异常→500 |
| `utils/patches-registry.ts:6-39,102` | patch 统一入口（含原件保留与还原） |
| `utils/fetch-utils.ts:167,213-238,240-285,331-354,356-372` | `FetchResponse`：`setStatus` / `setUrl` / `clone` |
| `utils/clone-response.ts:5-72` | 手写 tee + `highWaterMark: 0` + 取消耦合 |
| **`interceptors/fetch/web.ts:26-27,29-31,37,47-54,61-110,133-148,156-177,207-210,233,235-242`** | 浏览器 `FetchInterceptor` 全程 |
| **`interceptors/XMLHttpRequest/web.ts:10-15,17-27`** | patch `globalThis.XMLHttpRequest` |
| `interceptors/XMLHttpRequest/xml-http-request-proxy.ts:18-53,55-92` | 构造函数 Proxy + 实例 Proxy |
| `interceptors/XMLHttpRequest/xml-http-request-controller.ts:21-23,77-199,128-133,171-189,291-307,411-416,435-457,490-512,537-580,587-693,695-735,753-781,786-821,826-889,907-918` | XHR 伪造全程 |
| **`interceptors/net/index.ts:109-134,139-144,205-219,387-390,425-429,503-506`** | `SocketInterceptor`（TCP/TLS 级） |
| **`interceptors/http/source.ts:40-52,230,272-318,557,635-852`** | `NodeHttpRequestSource`（llhttp + 真字节合成响应） |
| **`interceptors/ClientRequest/index.ts:20-36,32-34,38-76`** | 归因谓词 + 仅归因的 patch |
| `interceptors/http/index.ts:9-33` | `HttpRequestInterceptor`（谓词恒真） |
| `interceptors/http/forward-events.ts:25-38` | **initiator 谓词过滤点** |
| `presets/browser.ts:8-11` / `presets/node.ts:9-13` | 两个 preset |
| `tsdown.config.ts:3-54` | node / browser 两套构建入口 |
| `package.json:8-53` | 14 个 exports 子路径与条件映射 |
| `README.md:3,5-10,39,43-46,52-54,99,125,173,189-191,216,241-246,333,385` | 官方 README 关键断言 |
| `test/modules/fetch/response/fetch-response-init.neutral.test.ts:50-52,66-68` | **`Response.type` 断言（browser='default'）** |
| `vitest.config.ts`（browser 项目） | Playwright + Chromium |

**`msw/package.json`**：第 143 行 `"@mswjs/interceptors": "^0.45.6"`

### 10.3 官方文档位置索引（`mswjs/mswjs.io`）

| 文件:行 | 内容 |
|---|---|
| `src/content/docs/index.md:6,14,18,20` | 定义 / 特性 / "不 patch fetch" / "类扩展" |
| `src/content/docs/limitations.md:8,12,14,25,27,31-33` | SW 继承平台限制 / XHR 进度 / Firefox / **开发工具定位** / **Node socket 断言** |
| `src/content/docs/faq.md:21,25,53` | 网络层 vs 应用层 / 支持所有客户端 / Node ≥22 |
| `src/content/docs/comparison.md:173,305,378` | "Uses a Service Worker…" |
| `src/content/docs/http/intercepting-requests/index.md:19-27,40,42-50,54-58,84-92,94-116` | 谓词/解析器模型 / **`path-to-regexp@6`** / 相对 URL / 查询参数剥离 / 正则 / 自定义谓词 |
| `src/content/docs/http/handling-requests.md:28-42` | `passthrough()` 语义（"仍算已处理"） |
| `src/content/docs/websocket/event-logs.md:6` | WS mock **不出现**在 DevTools |
| `src/content/api/setup-worker/start.md:11,21-26,40-42,52-56,103-147,151-157` | 默认 worker URL / 异步 / `serviceWorker.url` / **scope 警告** / `onUnhandledFrame` / `waitUntilReady` |
| `src/content/api/cli/init.md:17,24-30,36-59` | `msw init` / `PUBLIC_DIR` / `--save` |
| `src/content/guides/best-practices/managing-the-worker.md:5,26,32-34,45` | 提交脚本 / **必须在应用自己的 URL 上可取到** / 主版本内兼容 |
| `src/content/guides/recipes/xmlhttprequest-progress-events.md:10,14-30,45` | **不一致 #1 的原文** |
| `src/content/blog/why-use-mock-service-worker.md:21,25,27,29` | **SW 拦截"请求真的发生"的权威表述** |
| `src/content/api/is-common-asset-request.md:23-33` | 静态资源白名单 |
| `src/content/api/passthrough.md:14-21,40` | `passthrough()` 用法与 `bypass()` 对比 |

活站对应 URL 形如 `https://mswjs.io/docs/limitations`、`https://mswjs.io/api/setup-worker/start` 等。

### 10.4 规范 / 平台文档

| 来源 | 用到的原文 |
|---|---|
| W3C Service Workers（<https://w3c.github.io/ServiceWorker/>，**W3C 编辑草案，不是 WHATWG**） | "Start Register"（scheme 必须 http/https）；"Register"（script url 与 scope url 都须与 referrer 同源，否则 `SecurityError`）；§6.3.1 Origin restriction（"service workers cannot be hosted on CDNs"）；§6.5 Path restriction（`/~bob/sw.js` 的例子 + "only origins are [a hard security boundary]"）；"Update" 算法（`Service-Worker-Allowed` → `maxScope`，"If maxScope's origin is job's script url's origin"；**"Set request's redirect mode to "error"."**）；"Match Service Worker Registration"（按 storage key + 最长前缀）；§6.1 安全上下文；§4.6.7 `respondWith` 的 tainting 注释 |
| MDN `ServiceWorkerContainer.register()`（<https://developer.mozilla.org/en-US/docs/Web/API/ServiceWorkerContainer/register>） | `SecurityError`："**The `scriptURL` and scope are not same-origin with the registering page**"；scope 默认值 = 脚本所在目录；`Service-Worker-Allowed` 的作用 |
| MDN `Service-Worker-Allowed`（<https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Service-Worker-Allowed>） | "Servers can use the `Service-Worker-Allowed` header to allow a service worker to control URLs outside of its own directory." |
| Chrome `chrome.scripting`（<https://developer.chrome.com/docs/extensions/reference/api/scripting>） | `ExecutionWorld`：`"MAIN"` = "the main world of the DOM, which is the execution environment shared with the host page's JavaScript"；`RegisteredContentScript.world`（Chrome 102+）/ `ScriptInjection.world`（Chrome 95+）；程序化注入需 host permissions |
| Chrome content scripts（<https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts>） | `document_start` = "injected after any files from `css`, but before any other DOM is constructed or **any other script is run**"；**"Within a given stage of the document lifecycle, content scripts declared statically in the manifest are the first to be injected, before content scripts registered in any other way."**；isolated world 语义；**"When a content script is injected into the main world, the CSP of the page applies."** |
| Chrome manifest `content_scripts`（<https://developer.chrome.com/docs/extensions/reference/manifest/content-scripts>） | **"Warning: There are risks involved when using the `"MAIN"` world. The host page can access and interfere with the injected script."** |
| Chrome `chrome.userScripts`（<https://developer.chrome.com/docs/extensions/reference/api/userScripts>） | `"USER_SCRIPT"` = "the execution environment that is specific to user scripts and is **exempt from the page's CSP**"（← 豁免**不**适用于 MAIN）；需要用户开 "Allow User Scripts"（≥138）或开发者模式（<138） |
| Chrome `declarativeNetRequest`（<https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest>） | `RuleActionType` 枚举全集（block / redirect / allow / upgradeScheme / modifyHeaders / allowAllRequests）—— **无响应体合成**；"Before a request is made, an extension can block or redirect … it with a matching rule." |
| Fetch 标准（<https://fetch.spec.whatwg.org/#http-redirect-fetch>） | "If locationURL's scheme is not an HTTP(S) scheme, then return a network error." —— 重定向到 `chrome-extension://` 对页面而言是网络错误 |
| Chrome 扩展 Service Worker 基础（<https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/basics>） | "To register an extension service worker, specify it in the `"background"` field of the `manifest.json` file. … **This does not work for extensions.**"（扩展 SW 由浏览器声明式注册，不走 `register()`） |

### 10.5 包元数据 / 发布物

| 来源 | 取到什么 |
|---|---|
| `https://registry.npmjs.org/msw` | 340 版本；dist-tags `latest=3.0.2` / `beta=0.0.0-fetch.rc-4` / `next=2.3.0-ws.rc-12` / `backport=1.3.5`；`time.created=2018-11-18T22:25:58.733Z` |
| `https://registry.npmjs.org/msw/latest` | `unpackedSize=3347702`、`fileCount=257`、12 依赖、`engines.node>=22.12.0`、SLSA provenance |
| `https://registry.npmjs.org/@mswjs/interceptors` | 212 版本；dist-tags `latest=0.45.7` / `backport=0.17.10`；`time.created=2021-03-22T19:32:40.506Z` |
| `https://registry.npmjs.org/@mswjs%2finterceptors/latest` | `unpackedSize=1816732`、`fileCount=193`、6 依赖、`engines.node>=22` |
| `https://unpkg.com/@mswjs/interceptors@0.45.7/lib/node/index.js` | **发布产物 export 列表**（不一致 #1 的独立复核） |
| `https://unpkg.com/@mswjs/interceptors@0.45.7/lib/browser/index.js` | 浏览器根入口（同样不含任何拦截器） |
| `https://unpkg.com/@mswjs/interceptors@0.45.7/lib/node/index.d.ts` | HTTP 200，3784 B |
| `https://registry.npmjs.org/@msw/url/latest` | 0.1.2，`dependencies: {}`（不一致 #3 的关键） |
| `https://api.npmjs.org/downloads/point/last-week|last-month|last-day/<pkg>` | 下载量（§8.3） |
| `https://github.com/mswjs/msw/releases.atom` / `.../interceptors/releases.atom` | 各 10 条 release 正文 |
| `https://github.com/mswjs/msw` / `.../interceptors`（HTML） | star / fork / watcher / open issue / open PR |
| `https://api.github.com/rate_limit` | HTTP 200，`core.remaining = 0`（限流的直接证据） |
| `https://api.github.com/repos/mswjs/msw` | **HTTP 403**，body：`{"message":"API rate limit exceeded for 56.155.32.254. …"}` |

### 10.6 运行时实验（本机，Node v24.21.0 / npm 11.19.0 / `/tmp/mswtest`）

| 实验 | 命令要点 | 观察结果 |
|---|---|---|
| E1 根入口导出面 | `import('@mswjs/interceptors')` | `XMLHttpRequestInterceptor in root? false` |
| E2 文档写法（具名导入） | `import { XMLHttpRequestInterceptor } from '@mswjs/interceptors'` | **`SyntaxError: The requested module … does not provide an export named 'XMLHttpRequestInterceptor'`** |
| E3 正确子路径 | `import('@mswjs/interceptors/XMLHttpRequest')` | `[ 'XMLHttpRequestInterceptor' ]` |
| E4 `setupServer` 拦截范围 | 目标主机为不存在的域名，四种客户端 | `http.request` → MOCKED；`net.connect` → **ENOTFOUND**；`undici.request` → **ENOTFOUND**；`fetch` → MOCKED |
| E5 能力存在性 | 同进程改用 `SocketInterceptor` / `HttpRequestInterceptor` | `connection event for host = … port = 80`、`CONNECTED (no real DNS was needed!)`、`undici.request` → `INTERCEPTED-AT-SOCKET-LEVEL` |
| E6 抗检测面 | `fetch.name` before/after patch；mock 响应的 `type/ok/redirected` | `"fetch"` → **`""`**；`type=basic ok=true redirected=false`（**Node**；浏览器按仓库测试应为 `default`） |
| E7 依赖树 | `npm ls --all` + `ls node_modules \| grep path-to-regexp` | `msw@3.0.2` → `@mswjs/interceptors@0.45.7`（deduped）；**`path-to-regexp` NOT PRESENT** |

### 10.7 本次调研未使用的通道（以及为什么）

| 通道 | 为什么没用 |
|---|---|
| GitHub REST API | 403 硬限流（已记录为 §9.8） |
| GitHub GraphQL API | `rate_limit` 显示 `graphql.limit = 0`（未认证），无法用 |
| 真实浏览器 / Playwright | 本机无浏览器环境（§9.2/9.11）。仓库自带 Playwright 测试只读了断言文本 |
| `mswjs.io` 活站逐页抓取 | 改用文档仓库源码，行号可复现（§9.1） |
| `/workspace/docs/research/libraries/msw.md` | **按任务要求主动不读**，以避免锚定 |

---

*报告结束。所有引文均可在 §10 所列的克隆、发布物或 URL 上复现。若需进一步坐实 §9 的任一条目（尤其 9.2 / 9.4 / 9.5 / 9.7），建议在一台带 Chromium 的机器上跑 §10.6 的 E1–E6 加浏览器版本，并对 MV3 做一次 `world: "MAIN"` + 页面 CSP 的实机矩阵。*
