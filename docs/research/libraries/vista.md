# rxliuli/vista 调研

> **结论速览（先给答案）**
> - **它是什么**：一个 ~5.5 KB(gzip)、零依赖、MIT 的**浏览器运行时请求拦截库**——通过改写 `globalThis.fetch` / `XMLHttpRequest` / `WebSocket`，把请求/响应包进一个 Koa/Hono 风格的洋葱中间件链，从而**观察、改写、以及完全伪造**（mock）HTTP 与 WebSocket 流量。
> - **能不能借鉴**：**能，而且是目前看到的与本项目第一层（转发器）最贴形的开源实现**。中间件模型、"最后一段中间件＝原始请求"、fetch/XHR 归一化上下文、WebSocket 全 mock 模式，逐条都能用。
> - **能不能直接用**：**有条件能**。它本身是"纯运行时 patch 全局变量"的库，不含任何注入机制、不依赖扩展 API / Service Worker / 构建插件，塞进 MV3 没有技术障碍；但**它只作用于"它自己被加载的那个 JS 世界"**。要拦**任意第三方页面**，必须由**我们**负责把它注入页面的 MAIN world（`world: "MAIN"`）并在页面脚本运行前完成替换——这层不在 vista 里，且其中"页面 CSP 是否阻挡"这一条官方文档有相反方向的表述、**本次未实测**（见 §5、§7）。
> - **风险提示**：WebSocket 拦截器在源码里被标注 `/** @beta */`；项目只有 27 star、单维护者、CI 不跑测试；与 MSW 等"用 Proxy 包 XHR"的库存在已知不兼容（issue #5，修复 PR #8 被 close 未合并）。

---

## 0 元信息

| 项 | 值 |
|---|---|
| 调研日期 | 2026-10-06（UTC） |
| 调研对象 | `rxliuli/vista` — https://github.com/rxliuli/vista |
| 快照版本（源码） | 默认分支 `main`，HEAD = **`55bba2f1455869f74febe0c353ccc66ce11becc8`**，提交信息 `0.5.3`，作者提交时间 2026-08-02（+0700）。**注：`v0.5.3` 没有 git tag**，仓库最后一个 tag 是 `v0.5.2` |
| 快照版本（发布物） | npm `@rxliuli/vista@0.5.3`（`dist-tags.latest`），发布时间 2026-08-02T04:58:54Z（与 HEAD 的提交信息 `0.5.3`、提交时间同日）。**未做逐文件 diff**：仅抽样核对了 `npm pack` 出的 `dist/` 文件清单与 `dist/*.mjs` 内容，与 HEAD 源码结构一致 |
| 许可证 | MIT（`LICENSE`：`MIT License / Copyright (c) 2024 rxliuli`；`package.json`："license": "MIT"） |
| 主要来源 | ① 本地浅克隆 `git clone --depth 50 https://github.com/rxliuli/vista`（源码级阅读，共 1427 行 TS）② npm registry / tarball ③ 仓库 README 与 GitHub 页面（issue/PR/star 数）④ 作者本人的设计文章（原文站被 Cloudflare 拦截，见下）⑤ Chrome 官方扩展文档 ⑥ WHATWG 规范 |
| 引用约定 | 源码引用一律给出 **SHA 固定链接**（`…/blob/55bba2f…/…`），行号对应该 commit |
| 调研充分度自评 | **总体：高。** 问题 1/2/4/6 = **高**（源码逐行 + 发布物 + 元数据实测）；问题 3 = **高**（与本项目 concept-design 逐条对照）；问题 5 = **中**（MV3 侧有官方文档支撑，但**本沙箱无可用浏览器，全部 MV3 行为均未实测**，且作者未给出 MV3/MAIN world 的官方说明）。**所有"未验证"项集中列在 §7，未用推测填补。** |

**本次调研的已知获取限制（影响证据等级）**

1. `https://rxliuli.com/blog/intercepting-network-requests-in-chrome-extensions/` 与 `https://blog.rxliuli.com/p/7ffe39eff5c64f5d90acf21518e39d63/` 均返回 **HTTP 403（Cloudflare "Just a moment..."）**；Wayback Machine 无快照。本文使用的是第三方站点 **tool.lu** 的转载页（`https://tool.lu/index.php/ru_RU/article/77N/preview`，其页面自述"出处：https://rxliuli.com/blog/intercepting-network-requests-in-chrome-extensions/"），且是**机器译文**，措辞可能与原文有出入 → 引文标注为"转载/译文"。
2. **沙箱内无浏览器可用**（无 `playwright`、无 `chromium/google-chrome/firefox` 二进制，`/workspace/node_modules` 为空），因此**没有做任何运行时实验**：所有关于"行为"的结论都来自源码阅读与规范/官方文档，而不是实测。
3. 克隆是 `--depth 50` 浅克隆 → 历史分析只覆盖最近 50 个提交。
4. GitHub REST API 被限流（`API rate limit exceeded`），issue/PR/star 数据来自 **HTML 页面抓取**，未与 API 交叉核对。

---

## 1 它是什么（一句话）

**`@rxliuli/vista` 是一个"浏览器内的请求拦截中间件库"：它把 `fetch` / `XMLHttpRequest` / `WebSocket` 三个全局对象换成自己的实现，让调用方以 Koa/Hono 风格的洋葱中间件去监听、改写、甚至完全伪造请求与响应。**

README 首句原文（[README.md#L6](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L6)）：

> A powerful homogeneous request interception library that supports unified interception of Fetch/XHR/WebSocket requests. It allows you to intervene at different stages of the request lifecycle, enabling various functions such as request monitoring, modification, and mocking.

### 1.1 解决什么问题 / 面向什么场景

作者本人在文章动机里写得很清楚（[tool.lu 转载](https://tool.lu/index.php/ru_RU/article/77N/preview)，机器译文）：

> While implementing the Chrome extension Mass Block Twitter, I needed to block Twitter spam users in bulk. Twitter's request headers contain authentication information that appears to be dynamically generated via JavaScript. Rather than investigating how Twitter generates these authentication details, I decided it would be more efficient to intercept existing network requests, record all headers being used, and then directly utilize these ready-made headers …
>
> Existing libraries I investigated include:
> - mswjs: A mocking library capable of intercepting XHR/fetch requests, but requires a service worker, **which isn't possible for Chrome extension Content Scripts**.
> - xhook: An interception library that can intercept XHR requests but not fetch requests. Additionally, its last update was two years ago …
>
> Therefore, I decided to implement my own solution.

即：**在"没有 Service Worker 可用"的上下文（作者的语境是 Chrome 扩展的 Content Script）里，仍然要能拦住 fetch/XHR**。设计目标（同文）：

> - Intercept fetch/XHR requests
> - Support modifying request URLs to enable proxy requests
> - Support invoking original requests and modifying responses
> - Support SSE (Server-Sent Events) streaming responses

典型场景（README 全篇示例）：注入全局请求头、改写请求 URL、响应缓存、失败重试、改写响应体、改写流式响应（SSE）、拦截/伪造 WebSocket 消息。**其中"响应缓存"示例（命中缓存时 `c.res = cache.get(key).clone(); return`（不调用 `next()`）本质上就是"命中即伪造响应、请求不出网"** —— 与本项目 R9 同构。

### 1.2 核心概念与 API

| 概念 | 说明 | 证据 |
|---|---|---|
| `Vista` 类 | 主入口：`new Vista([...拦截器])` → `.use(mw)` → `.intercept()` → `.destroy()`。内部只做两件事：收集中间件、调用各拦截器并把返回的 cancel 存起来 | [src/vista.ts#L3-L28](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/vista.ts#L3-L28) |
| 拦截器（Interceptor） | `(middlewares) => () => void`，即"装上去返回一个卸载函数"。内置三个：`interceptFetch` / `interceptXHR` / `interceptWebSocket` | [src/types.ts#L11-L13](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/types.ts#L11-L13)、[src/index.ts](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/index.ts) |
| 洋葱中间件 | `(c, next) => void \| Promise<void>`；`await next()` 表示放行到下一层；**不调用 `next()` 就是短路** | [src/context.ts#L5-L15](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/context.ts#L5-L15) |
| HTTP 上下文 | `{ type: 'fetch'\|'xhr'\|'request', req: Request, res: Response }`；注意 **fetch 与 XHR 共用同一个上下文类型**（XHR 只是 `type: 'xhr'`） | [src/interceptors/fetch.ts#L5-L16](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L5-L16)、[src/interceptors/xhr.ts#L308-L312](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L308-L312) |
| WebSocket 上下文 | `{ type:'websocket', url, protocols, sendToClient, sendToServer, onClientMessage, onServerMessage, onOpen, onClose }`；**不调用 `next()` = 完全 mock，不建立真实连接** | [src/interceptors/ws.ts#L12-L37](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L12-L37)、[README.md#L223-L237](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L223-L237) |
| 错误模型 | `HTTPException(status, {res?, message?, cause?})`，其 `getResponse()` 返回一个 `Response`；fetch/XHR 拦截器捕获它并转成响应/错误事件。这是从 Hono 搬来的概念 | [src/http-exception.ts#L44-L81](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/http-exception.ts#L44-L81)、[src/interceptors/fetch.ts#L44-L49](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L44-L49) |
| 内置中间件 | `timeout(ms)` 与 `prettyJSON()` —— 两者都是**从 Hono 直接搬过来的模块**（文件头注释与 JSDoc 链接都指向 hono.dev） | [src/middlewares/timeout.ts](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/middlewares/timeout.ts)、[src/middlewares/pretty-json.ts](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/middlewares/pretty-json.ts) |
| 全局探针 | `getGlobalThis()`：若存在油猴的 `unsafeWindow` 就返回它，否则返回 `globalThis` —— 这是它"能在用户脚本里拦到页面请求"的关键 | [src/interceptors/fetch.ts#L18-L25](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L18-L25) |

README 明确列出的能力与边界（[README.md#L10-L16](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L10-L16)）：Fetch/XHR/WebSocket 三途径；中间件模式；请求前后干预；可改请求与响应数据；**Zero dependency, compact size**；**Supports browser extension and userscript environments**；**Modifiable stream response**。

README 关于"能拦到页面层"的说法（[README.md#L44](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L44)）：

> Vista automatically detects the userscript environment and uses `unsafeWindow` to intercept page-level requests, so no additional configuration is needed.

——**注意限定词：`userscript environment`**。这句是"油猴里自动拦页面请求"，**不是"在扩展 Content Script 里自动拦页面请求"**。

FAQ 明确它只面向浏览器（[README.md#L288-L290](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L288-L290)）：*"Does it support intercepting requests in Node.js? No, it only supports intercepting requests in the browser."*

致谢里承认了血统（[README.md#L292-L295](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L292-L295)）：**xhook**（XHR 拦截的部分实现参考）与 **hono**（API 与中间件模型的来源）。源码里也留了 xhook 的引用注释（[src/interceptors/xhr.ts#L6-L7](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L6-L7)：`// ref: https://github.com/jpillora/xhook/pull/121/files`）。

### 1.3 作者与生态背景

| 项 | 事实 | 来源 |
|---|---|---|
| 作者 | `rxliuli`（GitHub 主页签名："I like to create interesting things, using programming and writing as tools."）；npm 维护者只有 `rxliuli <rxliuli@gmail.com>` | [github.com/rxliuli](https://github.com/rxliuli)、npm registry `maintainers` |
| 相关项目 | 主页置顶仓库含 `joplin-utils`、`redirector`、`userscripts`、`AppDowngrader`；但他本人在 issue #1 里推荐的构建工具是**别人的** `vite-plugin-monkey`（"Check out vite-plugin-monkey, it makes using npm packages and modern development environments simpler."） | [github.com/rxliuli](https://github.com/rxliuli)、[issue #1](https://github.com/rxliuli/vista/issues/1) |
| 生态位 | 定位是"用户脚本 + 扩展 + 普通网页"通用的小型拦截库；提供 CDN/IIFE 构建（`window.Vista`）专门服务不带构建链的用户脚本场景 | [README.md#L28-L44](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L28-L44)、[src/cdn.ts](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/cdn.ts) |
| 名字相近的其它项目 | `rxliuli/httap` 是作者的另一仓库；**本次未能阅读其 README 正文**（GitHub HTML 抓取被导航内容淹没），故不对其下结论 | [github.com/rxliuli/httap](https://github.com/rxliuli/httap) |

---

## 2 实现原理

### 2.1 总览：三件事

1. **替换全局对象**：`fetch` 直接赋值替换；`XMLHttpRequest` / `WebSocket` 用"子类 + 覆盖构造器/全局绑定"替换。
2. **洋葱中间件链**：`handleRequest` 用 16 行递归 compose 实现（[src/context.ts#L5-L15](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/context.ts#L5-L15)）。
3. **把"真实请求"实现为链上最后一段中间件**——所以"某段中间件不调 `next()`" 就等于"请求根本不出网"。

```ts
// src/context.ts#L9-L14（逐字）
const compose = (i: number): Promise<void> => {
  if (i >= middlewares.length) {
    return Promise.resolve()
  }
  return middlewares[i](context, () => compose(i + 1)) as Promise<void>
}
await compose(0)
```

**关键推论（源码可证）**：短路 = 不出网。fetch 与 XHR 都把原请求放在 `[...middlewares, 真实请求中间件]` 的**末尾**（[fetch.ts#L38-L43](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L38-L43)、[xhr.ts#L314-L317](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L314-L317)），中间件不调 `next()` 就永远不会执行那段，因此**不需要任何网络层配合**（正好对应本项目 R9 的"请求根本不会发到网络上"）。

### 2.2 fetch 拦截

```ts
// src/interceptors/fetch.ts#L30-L31（逐字）
const pureFetch = getGlobalThis().fetch
getGlobalThis().fetch = async (input, init) => {
```

```ts
// src/interceptors/fetch.ts#L38-L50（逐字，节选）
await handleRequest(c, [
  ...middlewares,
  async (context) => {
    context.res = await pureFetch(c.req)
  },
])
...
return c.res
```

- 直接把 `c.res`（可能是中间件伪造的 `Response`）返回给调用者。
- 卸载：`getGlobalThis().fetch = pureFetch`（[fetch.ts#L53-L55](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L53-L55)）。
- `HTTPException` 被单独 catch 并转成 `err.getResponse()`（[fetch.ts#L44-L49](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L44-L49)）。

### 2.3 XHR 拦截（最复杂的一块，506 行）

策略：**继承原生 XHR，把"记录"与"真实发送"分离**。

- `class CustomXHR extends getGlobalThis().XMLHttpRequest`（[xhr.ts#L95](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L95)），随后 `getGlobalThis().XMLHttpRequest = CustomXHR`（[xhr.ts#L499-L505](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L499-L505)）。
- `open()` / `setRequestHeader()` / `addEventListener()` / `on*` 只**记录**，不触发真实请求（[xhr.ts#L110-L136](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L110-L136)）。
- `send()` 才构造 `Request`（`type:'xhr'`）并跑中间件链；链尾中间件此刻才 `super.open(...)` / `super.setRequestHeader(...)` / `super.send(...)`，并在 `load` 时把真实响应包成 `Response`（[xhr.ts#L297-L317](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L297-L317)、[xhr.ts#L408-L497](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L408-L497)）。
- 伪造响应时，`responseToXHR()` **另开一个真实的 `new XMLHttpRequest()` 当"属性载体"**，用 `Object.defineProperties` 把 `status/statusText/responseURL/readyState/response/responseType/responseText/getAllResponseHeaders/getResponseHeader` 钉上去，再让 `CustomXHR` 的 getter 委托过去（[xhr.ts#L9-L73](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L9-L73)、[xhr.ts#L214-L247](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L214-L247)）。
- 错误一律转成合成响应 + `error` 事件（`HTTPException` → 其 `Response`；字符串/`Error`/其它 → 500）（[xhr.ts#L318-L354](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L318-L354)）。
- `text/event-stream` 与 `application/octet-stream` 走流式分支（`response` 直接给 `ReadableStream`，`readyState = LOADING`），并且对流式响应逐块派发 `progress`（[xhr.ts#L18-L23](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L18-L23)、[xhr.ts#L358-L395](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L358-L395)）。

一条与本项目**高度相关**的工程细节：作者已经处理过"**别的扩展也在包装 XHR**"的场景，并且刻意通过 `super.*` 读上游，避免读到下游改动过的数据（[xhr.ts#L268-L275](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L268-L275)）：

> ```
> // Build a Response by reading from `super.*` rather than `this.*`. When
> // another extension subclasses CustomXHR (e.g. uBOL Lite's
> // json-prune-xhr-response), `this.response` walks the whole prototype
> // chain starting at the most-derived class, so vista's middleware would
> // receive data that has already been processed by a downstream layer.
> // Reading through `super` makes vista see only its direct upstream,
> // which is what the request/response pipeline model requires — see
> // docs/ubol-compat.md.
> ```

（`docs/ubol-compat.md` **在仓库里不存在**：`.gitignore` 第 6 行忽略 `docs/`；见 §7 存疑项。）

### 2.4 WebSocket 拦截（源码标 `@beta`）

- `class CustomWebSocket extends EventTarget`，然后 `g.WebSocket = CustomWebSocket`（[ws.ts#L46](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L46)、[ws.ts#L295-L298](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L295-L298)）。
- **构造器里就跑中间件链**：链尾中间件才 `new OriginalWebSocket(...)`（[ws.ts#L122-L193](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L122-L193)）。
- **mock 模式**：如果没有任何中间件调 `next()`（`connected === false`），则在链跑完后**直接把自己置为 OPEN 并派发 `open` 事件**，全程不建立真实连接（[ws.ts#L182-L189](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L182-L189)）：

```ts
.then(() => {
  if (!connected) {
    // Mock mode: no next() was called, simulate open
    this.#readyState = 1
    this.#openHandlers.forEach((h) => h())
    this.#emitOpen()
  }
})
```

- 双向消息拦截用"可改写事件对象"实现：`{ get data, replaceWith(d), preventDefault() }`（[ws.ts#L222-L266](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L222-L266)）。
- 反向注入（模拟服务器推送）：`sendToClient(data)` → `#emitMessage` → 同时调用 `onmessage` 与 `dispatchEvent`（[ws.ts#L276-L280](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L276-L280)）。
- `send()` 在非 OPEN 时抛 `DOMException(..., 'InvalidStateError')`；mock 模式 `close()` 用 `queueMicrotask` 补发 `close`（[ws.ts#L195-L218](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L195-L218)）。
- 测试覆盖了真实连接、透传、双向改写、`preventDefault` 阻断、**完全 mock**、`sendToClient` 注入、`onOpen/onClose`（[ws.browser.test.ts](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/__tests__/ws.browser.test.ts)，221 行）。

### 2.5 用了什么 / 不依赖什么

| 问题 | 结论 | 证据 |
|---|---|---|
| 依赖 Service Worker？ | **否**。作者选型的直接原因就是 mswjs 需要 SW 而"Chrome 扩展 Content Script 里不可能用" | 文章（转载/译文） |
| 改写 `fetch` / `XHR`？ | **是**，直接替换全局 | fetch.ts / xhr.ts 上述行 |
| 需要扩展 API？ | **否**。源码里没有任何 `chrome.*` / `browser.*` 调用 | `grep -rnE "userscript\|unsafeWindow\|content script\|extension\|chrome\.\|manifest" src/` 仅命中 `unsafeWindow` 探测与注释（[fetch.ts#L20](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L20)） |
| 只在开发期生效？ | **否**，纯运行时，生产可用 | 无 `process.env.NODE_ENV` 等分支 |
| 依赖构建插件 / 运行时注入？ | **否**。它**不提供任何注入能力**——你必须自己把它加载进目标世界 | 全仓库无 manifest / content_scripts 相关文件 |
| 需要 `eval` / `new Function`？ | **否**（MV3 CSP 友好）。`grep -rnE "\beval\(\|new Function"` 无命中；唯一 DOM 相关代码是 IIFE 入口的 `window.Vista = Vista` | [src/cdn.ts](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/cdn.ts) |
| 需要 DOM？ | **基本不需要**。`interceptXHR` 在 `typeof XMLHttpRequest === 'undefined'` 时返回空卸载函数（[xhr.ts#L92-L94](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L92-L94)），fetch/WS 拦截器只用 `globalThis` | 同上 |
| 运行时依赖 | **零**。`package.json` 无 `dependencies` / `peerDependencies`；`devDependencies` 全部是测试/构建用 | npm registry `versions['0.5.3']` |
| 体积 | `dist/index.iife.mjs` = 22,036 B 原始 / **5,483 B gzip**；完整 ESM 入口集合 = **5,528 B gzip**；npm tarball 16,091 B | 本地 `npm pack @rxliuli/vista@0.5.3` + `gzip -c` 实测 |
| 打包友好度 | `"sideEffects": false`，纯 ESM（`dist/*.mjs` + `.d.ts`），`exports` 只暴露 `"."` | [package.json](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/package.json) |
| 打包瑕疵（实测） | `dist/` 里混进了 `setup.mjs`，它 `import { serve } from "@hono/node-server"` 等**只存在于 devDependencies** 的包——因为 `build.config.ts` 只忽略 `**/*.test.ts`。该文件不在 `index.mjs` 的导出链上，故对正常使用无害，但属于死代码/潜在误用坑 | [build.config.ts#L1-L8](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/build.config.ts)、tarball 内 `package/dist/setup.mjs#L1` |

### 2.6 关键技术点（可以单独抽出来复用的技巧）

1. **"真实请求＝链尾中间件"** —— 让"短路"与"放行"共用一条代码路径，不需要任何 `if (mocked) ... else ...` 分叉。
2. **XHR 的"记录/发送分离"** —— `open()` 必须只记录，否则无法在 `send()` 之前跑中间件（Koa 模型要求"整条链跑一次"）。
3. **伪造 XHR 的"属性委托"手法** —— 借一个真 XHR 当载体 + `Object.defineProperties`，可以绕开"原生 XHR 属性只读"的限制。
4. **WebSocket 用"事件对象可改写"表达阻断与改写**（`replaceWith` / `preventDefault`），而不是另造 API；对页面代码透明。
5. **WebSocket 全 mock 不需要真实服务端** —— 只要不调 `next()`。
6. **`unsafeWindow` 探测** —— 一个函数同时伺候"普通页面 / 油猴 / 扩展"三种装载方式（**但只解决"用哪个全局"，不解决"怎么进到那个世界"**）。
7. **多拦截器共存的防御式写法** —— `super.*` 读上游、`status 0` 走 error 而不是崩在 `new Response(..., {status: 0})`（[xhr.ts#L451-L470](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L451-L470)）。

### 2.7 保真缺口清单（源码级，供"伪装还原"判据用）

> 以下都是**从源码直接读出**的差异，不是实测结果（无浏览器）。它们对项目的价值在于：**R10 要求"伪装还原"必须不露馅，这份清单就是验收检查表的现成素材。**

| # | 缺口 | 依据 |
|---|---|---|
| W1 | `CustomWebSocket extends EventTarget`，不是原生 `WebSocket` 的子类；`WebSocket` 全局被**整体替换**。页面内 `x instanceof WebSocket` 仍为 true（因为 `WebSocket` 也指向新类），但**任何在替换前已捕获原生构造器引用的代码**（其它库、已加载模块、另一个扩展）会得到 false | [ws.ts#L46](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L46)、[ws.ts#L295](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L295) |
| W2 | mock 模式**不解析 URL**。规范的 WebSocket 构造器会解析 URL 并对非法 scheme / 带 fragment 抛 `SyntaxError`；这里是 `this.#url = url.toString()` | 源码 [ws.ts#L122-L124](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L122-L124) vs 规范 [HTML §3.1 constructor steps](https://html.spec.whatwg.org/multipage/web-sockets.html) |
| W3 | mock 模式**不校验 `close(code, reason)`**（规范：非法 code 抛 `InvalidAccessError`；reason > 123 字节抛 `SyntaxError`） | 源码 [ws.ts#L205-L218](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L205-L218) vs 规范 |
| W4 | mock 模式 `protocol` 恒为 `''`、`extensions` 恒为 `''`、`bufferedAmount` 恒为 `0`（真实连接时才有值） | [ws.ts#L56-L95](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L56-L95) |
| W5 | mock 模式的 `open` 在**中间件链 resolve 之后**以微任务派发（`.then`），而非原生"任务"时序；异步中间件会拉长这段延迟 | [ws.ts#L182-L189](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L182-L189) |
| W6 | 新类未设置 `Symbol.toStringTag`；按 Web IDL 规则原生平台对象的类字符串是接口名，`Object.prototype.toString` 结果预计不同（**推断，未实测**） | [Web IDL: class string 规则](https://webidl.spec.whatwg.org/) |
| X1 | XHR `readyState` **直接跳到 4（DONE）**（流式时 3/LOADING），没有 1/2/3 的状态迁移过程 | [xhr.ts#L47-L59](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L47-L59) |
| X2 | `readystatechange` 只在最后与 `load`/`loadend` 一起补发一次（中间件路径下），不是真实的多次迁移事件 | [xhr.ts#L397-L405](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L397-L405) |
| X3 | `getAllResponseHeaders()` 输出**小写 header 名**、`\r\n` 连接、**无结尾 `\r\n`** | [xhr.ts#L42-L70](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L42-L70) |
| X4 | `responseType: 'document'` 落到 `text` 分支（不产生 Document） | [xhr.ts#L35-L39](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L35-L39) |
| X5 | **没有 `upload` 对象**、没有 `timeout`/`ontimeout`、没有 `withCredentials` 的显式处理；`abort()` 未覆盖；同步 XHR（`open(..., false)`）语义被 async 实现吞掉 | `grep` 未命中这些成员，只有 `xhr.ts` 中已列出的属性集合 |
| X6 | `send()` 是 `async`，即**返回 Promise**（原生 `send()` 返回 `undefined`） | [xhr.ts#L297](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L297) |
| X7 | **使用 `#private` 字段**（类字段），任何用 `Proxy` 包裹本类实例的库都会在 setter 上抛错（issue #5 报告 MSW 场景；修复 PR #8 被 **closed 未合并**，当前源码仍是 `#` 字段） | [xhr.ts#L96-L108](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L96-L108)、[issue #5](https://github.com/rxliuli/vista/issues/5)、[PR #8](https://github.com/rxliuli/vista/pull/8) |
| F1 | fetch 侧用**普通赋值**替换 `globalThis.fetch`（未保留原函数的 `name`/属性，也未做可写性防御）；`window.fetch` 会变成自有属性 | [fetch.ts#L30-L31](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L30-L31) |

---

## 3 与本项目问题的交集

本项目要在浏览器里**冒充 aria2 的 RPC 服务端**、拦截页面请求并**伪造响应**（含 WebSocket），形态为 **MV3 扩展**。逐条对照 concept-design：

| 本项目条目 | vista 的对应物 | 交集判定 |
|---|---|---|
| **R4.1 转发器：命中配置地址就拦、未命中放行** | 中间件链 + "链尾＝真实请求"：一个最外层中间件做 URL 判定，命中则 `c.res = 伪造响应; return`（不 `next()`），未命中 `await next()` | ✅ **完全同构**，且**现成可抄** |
| **R9 拦截发生在 JS API 层，命中后请求根本不出网** | fetch 完全不出网（`pureFetch` 未被调用）；XHR 在短路时**根本不会执行 `super.open/super.send`**（都在链尾中间件里） | ✅ **天然满足 R9**（有源码级证据，见 §2.2/§2.3） |
| **R4.1 尽可能多地拦截各种途径** | 覆盖 `fetch` / `XMLHttpRequest` / `WebSocket` 三途径 | 🟡 **覆盖了本项目最关键的三种，但不是全部**：`EventSource`、`navigator.sendBeacon`、`<img>/<script>/<form>` 等非 JS-API 途径、以及 Worker 内的三种 API 都不在其范围内（它只 patch "它所在的那个全局"） |
| **R4.1 尽可能多地拦截各种来源：每个标签页、MAIN WORLD** | **vista 完全没有这一层**（无注入、无 manifest、无 `chrome.*`） | ❌ **空白**，必须由我们用 MV3 注入机制补齐（见 §5） |
| **R5 内置 AriaNg UI 不得走特殊通道** | vista 在"它被加载的那个世界"里工作：扩展自己的页面里直接 `new Vista([...]).intercept()` 即可，用的正是页面普通的 `fetch`/`WebSocket` 路径 | 🟡 **可以支撑 R5**：内置 UI 与普通页面可以共用**同一份转发器代码**（差别只在"装载方式"）；**但注意 vista 实例是"每个世界一份"**——UI 页要自己拦自己，仍需要在该页里装一次，不能靠后台统一拦截 |
| **Q-D3 WebSocket 第一版就实现，允许转发器轮询 Mock 层近似推送** | `interceptWebSocket` 的 mock 模式：不调 `next()` → 不建真连接；中间件里保存 `context`，之后任何时刻用 `context.sendToClient(aria2通知)` 就能给页面推消息；页面发的帧走 `onClientMessage` | ✅ **这就是 Q-D3 想要的形状**，而且比"轮询"更直接（是在页面内注入事件，不需要真的占一个 WS 端口） |
| **Q-B2 三段式错误 / Q-B4 请求上下文** | `context.type`（`'fetch'\|'xhr'\|'websocket'`）+ `HTTPException` 的错误→响应映射 | 🟡 **结构可参考**：vista 的错误模型是"HTTP 状态码"导向（因为抄自 Hono），而 aria2 的 JSON-RPC 需要的是 `{"code":N,"message":...}` + HTTP 200 或协议级错误；需要我们把 `HTTPException` 的思想改造成 RPC 错误体 |
| **Q-D5 状态持久化在存储、不依赖 SW 内存** | 无关（vista 不涉及状态） | ⚪ 无交集 |
| **Q-D2 拦截盲区清单** | vista 的边界直接贡献素材：Worker 内、非 JS API 途径、替换时机之前的请求 | 🟡 **有贡献**：它把盲区边界显式化了（见 §5） |

**一句话**：vista 精准覆盖了本项目**第一层（转发器）中"引擎内部"的那一半**（多途径拦截 + 就地伪造 + WS 通道），但**完全不覆盖另一半**（把代码送进任意第三方页面的 MAIN world、以及由此带来的 CSP/时机/共存问题）。它解决的问题与本项目**高度重叠但不等价**。

---

## 4 能否借鉴（逐条，说明用在哪一层）

| # | 借鉴点 | 用在哪一层 | 为什么值得 |
|---|---|---|---|
| 1 | **洋葱中间件模型**（16 行 compose） | 第一层·转发器 | 转发器的"命中→转 Mock / 未命中→放行"就是一条中间件；后续要加日志、超时、重试都是加一条中间件，不用改核心 |
| 2 | **"真实请求＝链尾中间件"** | 第一层·转发器 | 让 R9 的"不出网"变成结构性保证，而不是散落的 `if` |
| 3 | **fetch/XHR 归一为同一上下文 `{type, req, res}`** | 第一层转发器 ↔ 第二层 Mock 的接口 | Mock 层只实现一次；`type` 字段正好承载 Q-B4 的"请求上下文"维度 |
| 4 | **WebSocket 上下文协议**（`url/protocols/sendToClient/sendToServer/onClientMessage/onServerMessage/onOpen/onClose`） | 第一层·WebSocket 通道 | 直接是 Q-D3 需要的 API 面：把"轮询到的 aria2 通知"用 `sendToClient` 推给页面 |
| 5 | **"不调 next()＝mock"作为 WS 的短路开关** | 第一层·WebSocket 通道 | 命中 `ws://host:port/jsonrpc` 时完全不建真连接；未命中自动放行 |
| 6 | **`replaceWith` / `preventDefault` 的可改写事件对象** | 第一层·WebSocket 通道 | 对页面代码透明地改写/阻断帧；也是"观察流量"的最小 API |
| 7 | **`getGlobalThis()` / `unsafeWindow` 探测** | 第一层·装载层 | 对应 R5 的"只换装载方式，不换路径"：同一份转发器代码可以装进油猴、隔离世界、MAIN world、扩展页 |
| 8 | **拦截器 = `(middlewares) => () => void`（返回卸载函数）** | 第一层·装载层 | 配置变更/页面卸载时能干净还原；也便于"DNR 规则与 JS 补丁一起撤销" |
| 9 | **XHR "记录/发送分离"的顺序技巧** | 第一层·转发器（若自己写 XHR 拦截） | 不这么做就无法保证"中间件在 `send()` 前跑一次" |
| 10 | **伪造 XHR 的"真对象当载体 + `Object.defineProperties` + getter 委托"手法** | 第二层·Mock 的响应落地 | 这是绕过只读属性的现成解法 |
| 11 | **`super.*` 读上游、防下游改写；`status 0` 走 error 不崩** | 第一层·转发器（多扩展共存） | 我们注入 MAIN world 后必然与油猴脚本/其它扩展抢同一个全局，必须设计"叠加式拦截"而不是"独占式替换" |
| 12 | **§2.7 保真缺口清单** | 第二层·Mock 的"还原度"验收 | 它是 R10 判据的现成检查表（`instanceof`、构造器引用、`readyState` 序列、header 大小写、URL 校验、close code 校验……） |
| 13 | **`HTTPException` + `getResponse()`** | 第二层·Mock 的错误出口 | 结构上可改造成 RPC 错误体（Q-B2 的三段式：`-32601` 协议级 / aria2 `{code,message}` / 自定义运行期错误） |
| 14 | **发布的 IIFE 单文件 + `window.Vista`** | 第一层·装载层 | 若我们选择注入 MAIN world，这是最省事的装载形态（5.4 KB gzip，无 eval，MV3 CSP 友好） |
| 15 | **作者踩过的坑**：需要 SW 的方案在 Content Script 里不可用（他弃用 mswjs 的原因） | 架构决策依据 | 直接支持我们"不走 SW 拦截"的路线选择与 R8/R9 的裁定 |

**不建议照搬的**：vista 的 XHR 保真实现（§2.7 X1–X7 的缺口太多）、WebSocket 的 `EventTarget` 子类做法（W1/W6 露馅风险）、以及"用 `HTTPException` 表达一切错误"（与 aria2 错误模型不匹配）。

---

## 5 能否直接使用（MV3 扩展里拦任意第三方页面）

### 5.1 明确结论

| 问法 | 结论 |
|---|---|
| 能否作为依赖放进 MV3 扩展？ | **能。** 纯运行时、零依赖、无 `eval`、无扩展 API、无 SW 依赖 → 打包进 MV3 没有任何机制性障碍（证据：§2.5 全表） |
| 能否用它拦**任意第三方页面**的请求？ | **有条件能。** vista 只 patch **它自己被加载的那个 JS 世界**；要拦页面自己的 `fetch/XHR/WebSocket`，**必须由我们把 vista 注入页面的 MAIN world**——这层是 MV3 注入机制的事，不是 vista 的事 |
| 能否开箱即用（不写注入层）？ | **不能。** README 的"Supports browser extension … environments"指的是"能在扩展环境里跑"，**不等于**"能拦页面"；它以 `unsafeWindow` 覆盖了**油猴**场景，但**没有覆盖扩展 Content Script 的隔离世界** |

### 5.2 前置条件（官方文档依据）

1. **隔离世界 ≠ 页面世界**（Chrome 官方，[Content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts)）：
   > "Content scripts live in an isolated world, allowing a content script to make changes to its JavaScript environment without conflicting with the page or other extensions' content scripts."
   > "Note: Not only does each extension run in its own isolated world, but content scripts and the web page do too. This means that none of these (web page, content scripts, and any running extensions) can access the context and variables of the others."
   → 在默认（ISOLATED）的 content script 里跑 vista，只会拦住**扩展自己**发出的请求。

2. **必须显式选择 MAIN world**（Chrome 官方）：
   - `chrome.scripting.executeScript({ world: "MAIN" })`：`ScriptInjection.world` — *"Chrome 95+ The JavaScript "world" to run the script in. Defaults to ISOLATED."*；`ExecutionWorld."MAIN"` — *"Specifies the main world of the DOM, which is the execution environment shared with the host page's JavaScript."* 见 [browser.scripting](https://developer.chrome.com/docs/extensions/reference/api/scripting)。
   - manifest `content_scripts` 的 `world` 键：*"Optional. The JavaScript world for a script to execute within. Defaults to ISOLATED."* 见 [Content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts)。
   - `chrome.scripting.registerContentScripts({ world: "MAIN" })`：*"Chrome 102+ The JavaScript "world" to run the script in."*（同上 API 页）。

3. **时机**（Chrome 官方，同上 Content scripts 页）：`run_at: "document_start"` = *"Scripts are injected after any files from css, but before any other DOM is constructed or any other script is run."* —— 这是"在页面代码抓到原生 `fetch` 引用之前完成替换"的关键。相反，`executeScript` 默认 *"will be run at document_idle, or immediately if the page has already loaded"*，`injectImmediately` 也只是"尽快"：*"Note that this is not a guarantee that injection will occur prior to page load"*。

4. **MV3 service worker 会随时死**（Chrome 官方，[Service worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle)）：
   > "Normally, Chrome terminates a service worker when one of the following conditions is met: After 30 seconds of inactivity. … When a single request … takes longer than 5 minutes to process."
   > "Any global variables you set will be lost if the service worker shuts down. Instead of using global variables, save values to storage."
   → 与本项目 Q-D5 完全一致；同时也说明"把 Mock 状态放 SW 内存"这条路是错的。

### 5.3 代价与限制（必须写进设计约束的）

| 类别 | 内容 |
|---|---|
| **① 注入层要自己写** | vista 不提供任何注入；我们需要 `world:"MAIN"` 的静态声明或 `scripting` 注册 + 版本门槛（Chrome 95/102） |
| **② 页面 CSP —— 官方表述对我们不利，且未实测** | Chrome 文档明确写着：*"When a content script is injected into the main world, the CSP of the page applies."*（[Content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts)）。而 `userScripts` 文档把 `USER_SCRIPT` 世界描述为 *"exempt from the page's CSP"*（[userScripts](https://developer.chrome.com/docs/extensions/reference/api/userScripts)），反衬出 **MAIN world 不豁免**。**但这条在实践上到底会不会阻止 `scripting.executeScript({world:'MAIN'})` 的注入与全局改写，本次无法实测**（无浏览器）。→ **必须做 POC**，是本项目能否走"MAIN world + vista"路线的第一号风险（写入 §7）。 |
| **③ 替换时机窗口** | 页面若在 `document_start` 之前就捕获了 `window.fetch`（例如更早注入的其它扩展/内联脚本，或用 `import` 缓存的模块），我们的替换对它无效。官方只承诺 `document_start` "before any other DOM is constructed or any other script is run"，但**该承诺在 MAIN world 声明下是否同样成立，未验证** |
| **④ 盲区（与本项目 Q-D2 呼应）** | ① **Worker**：`fetch`/`XMLHttpRequest`/`WebSocket` 分别在 `[Exposed=(Window,Worker)]`、`[Exposed=(Window,DedicatedWorker,SharedWorker)]`、`[Exposed=(Window,Worker)]` 中暴露（[Fetch](https://fetch.spec.whatwg.org/)、[XHR](https://xhr.spec.whatwg.org/)、[HTML WebSockets](https://html.spec.whatwg.org/multipage/web-sockets.html)），它们是**独立全局**；而 `scripting` 的注入目标只有 `tabId/frameIds/documentIds/allFrames`（[API 页](https://developer.chrome.com/docs/extensions/reference/api/scripting)），**没有 Worker 目标** → Worker 内的请求我们拦不到。② `EventSource`、`navigator.sendBeacon`、`<img>/<script>/<form>` 等非 JS API 途径不在 vista 覆盖内。③ `chrome://`、扩展页 CSP、PDF viewer、view-source 等本项目的既有盲区（concept-design §6.4）不受 vista 影响 |
| **⑤ 保真代价** | §2.7 的 W1–W6/X1–X7：伪造对象与原生对象在 `instanceof`（跨引用场景）、`toString`、URL 校验、`readyState` 序列、header 大小写等方面不同。对"只看 JSON-RPC 结果"的 AriaNg 大概率无碍，**但这是要实测的验收线**（本任务未验证 AriaNg 具体做了哪些检测） |
| **⑥ 共存代价** | vista 是"**整体替换全局**"式拦截，不是"链式追加"式。与其它扩展/油猴脚本同处 MAIN world 时，谁后装谁生效；`#private` 字段导致被 `Proxy` 包裹即抛错（[issue #5](https://github.com/rxliuli/vista/issues/5)，修复 PR [#8](https://github.com/rxliuli/vista/pull/8) **closed 未合并**） |
| **⑦ 成熟度代价** | WebSocket 拦截器源码标 `/** @beta */`（[ws.ts#L5-L12](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L5-L12)）；issue #11（"How to use this in React chrome extension?"）作者**只回了一个博客链接**，仓库内**没有 MV3 用例/示例/文档** |
| **⑧ 许可与可控性代价** | MIT → 可自由 fork/vendor。**若采用，建议 vendor（复制源码进本仓库）而非依赖 npm**：代码量小（1427 行）、我们要大改错误模型与 XHR 保真，且需要修 `#private` 兼容问题 |

### 5.4 建议的使用形态（供详细设计参考）

```js
// 在 MAIN world 里执行（由扩展注入，vista 自身不管注入）
new Vista([interceptFetch, interceptXHR, interceptWebSocket])
  .use(async (c, next) => {
    // 第一层转发器：命中用户配置的那一条精准 URL 才拦，否则放行
    if (!isConfiguredTarget(c)) return next()
    if (c.type === 'websocket') return mockAria2Ws(c)   // 不调用 next() ⇒ 不建真连接
    c.res = await mockAria2Rpc(c.req)                   // 就地伪造响应 ⇒ 不出网
  })
  .intercept()
```

对 WebSocket 的轮询推送：在中间件里 `registry.set(c.url, c)` 保存上下文，之后从扩展侧收到 aria2 通知时调用 `c.sendToClient(payload)` ——**这正是 Q-D3 允许的"轮询近似推送"的落地方式**。

### 5.5 替代路线提醒

若 ②（页面 CSP）或 ③（时机）在 POC 中不成立，退路是：**自研转发器**（照搬 §4 的设计而非代码）+ 仍然走 `world:"MAIN"`；或者用 `chrome.userScripts`（`USER_SCRIPT` 世界豁免页面 CSP，但**要求用户打开 Developer mode / "Allow User Scripts" 开关**，官方文档：*"If the Allow User Scripts toggle is not enabled, browser.userScripts is undefined."*，且 `USER_SCRIPT` 世界**不是**页面世界，能否拦页面自身的 `fetch` 需要另行判断——**本任务未验证**）。

---

## 6 许可证、维护状态、成熟度、文档完善度

### 6.1 许可证

| 项 | 值 | 依据 |
|---|---|---|
| 许可证 | **MIT** | [LICENSE](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/LICENSE)：`MIT License / Copyright (c) 2024 rxliuli`；`package.json` `"license": "MIT"` |
| 结论 | 可商用、可修改、可闭源分发，只需保留版权与许可声明 | MIT 标准条款 |

### 6.2 维护状态

| 指标 | 值 | 依据 |
|---|---|---|
| 最近一次提交 | 2026-08-02（HEAD `55bba2f`，提交信息 `0.5.3`） | 本地克隆 `git log -1` |
| 最近一次 npm 发布 | 2026-08-02T04:58:54Z（`0.5.3` = latest） | npm registry `time` |
| 首次发布 | 2025-01-06（`0.1.0`），至今 **29 个版本** | npm registry |
| 发布节奏（近一年） | 2026 年：0.4.9(01-18)、0.4.10/11(02-09)、0.4.12(02-11)、0.5.0(03-23)、0.5.1(04-12)、0.5.2(06-20)、0.5.3(08-02) → **约 1–2 个月一版，仍在维护** | npm registry `time` |
| 维护者 | **1 人**：npm `maintainers = [rxliuli]` | npm registry |
| CI | `build-and-release.yml`（push main 且 `package.json` 变更 → `pnpm build` + `pnpm publish`）与 `claude.yml`（`@claude` 触发的 Anthropic Claude Code Action，模型 `claude-opus-4-6`） | [.github/workflows](https://github.com/rxliuli/vista/tree/55bba2f1455869f74febe0c353ccc66ce11becc8/.github/workflows) |
| ⚠️ CI 不跑测试 | 两个 workflow 里**都没有 `pnpm test`**；测试只在本地/手工执行 | 逐字读完两个 workflow 文件；`package.json` 有 `"test": "vitest run"` 但无人调用 |
| Git tag / GitHub Release | tag 只到 **`v0.5.2`**（`v0.5.3` 未打 tag）；**Releases 页面为空**（无任何 release） | `git tag -l`；GitHub Releases 页抓取无 tag 链接 |

### 6.3 社区规模

| 指标 | 值 | 依据（抓取时间 2026-10-06） |
|---|---|---|
| Star | **27** | 仓库页 HTML：`"stargazerCount":27`、`27 users starred this repository` |
| Fork / watcher | **未取到**（页面未渲染出计数，GitHub API 被限流） | — |
| Issue | **4 条，全部已关闭**：#1（CDN 单文件构建请求，已实现）、#4（中间件设置的 header 未生效，已修）、#5（**与 msw 不兼容**，未修）、#11（**如何在 React Chrome 扩展里使用**，作者只回博客链接） | 各 issue 页面正文 |
| PR | **7 条**：#2/#3（Ocyss）、#6/#7/#9/#10（susnux）**已合并**；**#8（susnux，去掉 `#private` 字段以兼容 MSW）closed 未合并** | 各 PR 页面 |
| 外部贡献者 | **2 人**（Ocyss、susnux） | 各 PR 页面 |
| npm 下载量 | 最近 30 天（2026-09-05 ~ 2026-10-04）**1,098**；最近 7 天（2026-09-28 ~ 10-04）**422** | npm downloads API |
| 结论 | **小众但真实在被使用**（每月 ~1k 下载）；社区极小，**不能指望上游响应你的定制需求** | 同上 |

### 6.4 成熟度

| 维度 | 评价 |
|---|---|
| fetch 拦截 | 成熟。API 简单、被 README 作为主推用法、多版本迭代、体积小 |
| XHR 拦截 | 较成熟但**保真度有限**（§2.7 X1–X7）；已知与 MSW/Proxy 不兼容且未修；被 Firefox 相关 bug 修过（PR #10）、被 `loadend` 修过（PR #9）、被 uBOL 共存场景修过 |
| WebSocket 拦截 | **不成熟**：源码 `/** @beta */`；2026-03-23 的 0.5.0 才引入（`feat: add WebSocket interceptor (beta)`）；有覆盖主要场景的测试，但无保真度测试 |
| 测试 | 1310 行 vitest（浏览器模式，基于 playwright + vitest browser），覆盖 fetch/xhr/ws 主要路径；**但 CI 不执行** |
| 发布工程 | 有自动化发布（OIDC、npm provenance）、OIDC 权限、unbuild 双产物（ESM + IIFE）；**瑕疵**：`dist/setup.mjs` 混入发布包且 import 了 devDependencies（见 §2.5） |
| 版本语义 | 0.x，`0.5.x`；无 CHANGELOG 文件 |

### 6.5 文档完善度

| 项 | 情况 |
|---|---|
| README | 303 行，结构完整：特性、安装（npm + CDN + 油猴 `@require`）、8 个进阶用法示例、API Reference、FAQ、致谢、许可 |
| 类型/注释 | 源码带 JSDoc；公开类型 `FetchContext` / `WebSocketContext` / `FetchMiddleware` 有注释；**WebSocket 相关类型标注 `@beta`** |
| 独立文档站 / CHANGELOG | **无**（仓库根目录只有 README 一个 md 文件；无 `docs/` 目录，且 `.gitignore` 第 6 行为 `docs/`，源码注释引用的 `docs/ubol-compat.md` **不在仓库中**） |
| 扩展/MV3 专项文档 | **无**。issue #11 是唯一的扩展相关问答，答案是外链博客；README 里的 "Supports browser extension … environments" 没有任何展开说明 |
| 作者文章 | 有（英/中双语），讲 fetch/XHR 拦截的**设计思路与简化实现**；**但无 MV3、无 MAIN world、无 content script 与页面世界的区分** |
| 示例仓库 | 仓库内**无 examples/ 目录**（仅测试） |

---

## 7 未验证 / 存疑

> 严格遵守"查不到就写未验证"，以下均为**本次没有取得证据或无法证实**的项。

1. **【最高优先级 · 阻塞性】** `world:"MAIN"` 注入的脚本是否会被**页面 CSP** 阻挡、以及是否仍能改写页面全局。Chrome 官方文档写着 *"When a content script is injected into the main world, the CSP of the page applies."*，但**没有实测**（沙箱无浏览器）。这直接决定 §5 的路线可行性 → **必须 POC**。
2. **`world:"MAIN"`（静态声明）是否也保证 `document_start` 语义**（"before … any other script is run"）。官方 RunAt 说明没有区分 world；**未验证**。
3. **AriaNg 具体做哪些运行期自检**（`instanceof`、`Object.prototype.toString`、`readyState` 序列、`protocol` 协商等），从而 §2.7 的缺口里哪些会真的暴露 → **未验证**（不在本任务范围，建议交给前端兼容性调研）。
4. **作者是否把 vista 真正用于 MV3 扩展**：文章提到的 Mass Block Twitter 未附源码/manifest；仓库无 MV3 示例；issue #11 未获实质回答 → **无法确认有 MV3 生产用例**。
5. **`docs/ubol-compat.md` 的内容**：源码注释引用它，但 `.gitignore` 忽略 `docs/`，仓库里不存在；仓库中 uBOL 相关的只是"模拟下游子类"的回归测试（[xhr.browser.test.ts#L604-L646](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/__tests__/xhr.browser.test.ts#L604-L646)）→ **该文档与真实 uBOL 集成的背景无法核实**。
6. **`#private` 字段导致的实际不兼容范围**：issue #5 只给了 MSW；PR #8 被 close 的原因**未能从其页面提取到评论正文** → "为什么没修"无从判断；当前源码确实仍用 `#` 字段（已核实）。
7. **GitHub 精确数字**：Star=27 来自 HTML 抓取；**fork 数、watcher 数、contributors 数未取到**（API 限流）；issue/PR 列表用 `?q=is%3Aissue` / `is%3Apr` 抓取，可能漏掉更早的被删除/转移项。
8. **作者的博客原文措辞**：rxliuli.com / blog.rxliuli.com 均 403（Cloudflare），Wayback 无快照；本文引用的文章内容来自 **tool.lu 的机器译文转载页**，可能与原文有措辞差异 → 引用时已注明。
9. **未做任何运行时实验**：无浏览器可用（无 playwright/chromium/firefox）。§2.7 中的 W6（`Object.prototype.toString`）等由规范推出的判断属于**推断**；W1 中"替换前捕获的引用会 `instanceof === false`"同样是把源码与 JS 语义结合后的**推断**。
10. **`rxliuli/httap` 与本主题的关系**：未能读取其 README 正文（抓取被 GitHub 导航结构淹没）→ 不下结论。
11. **`userScripts` + `USER_SCRIPT` 世界能否用来拦页面自身请求**：官方只说该世界"exempt from the page's CSP"，但它是**独立于页面的世界**，理论上页面代码不受其 patch 影响 → **未验证**，未在 §5 中作为可行方案推荐。

---

## 8 证据清单（URL + 原文摘录）

> 版本锚点：仓库 **commit `55bba2f1455869f74febe0c353ccc66ce11becc8`**（main，2026-08-02）；npm **`@rxliuli/vista@0.5.3`**。所有源码链接均为该 commit 的固定链接。

### 8.1 仓库源码（SHA 固定链接）

| 位置 | 原文摘录 |
|---|---|
| [src/interceptors/fetch.ts#L30-L31](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L30-L31) | `const pureFetch = getGlobalThis().fetch` / `getGlobalThis().fetch = async (input, init) => {` |
| [src/interceptors/fetch.ts#L38-L43](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L38-L43) | `await handleRequest(c, [...middlewares, async (context) => { context.res = await pureFetch(c.req) }])` |
| [src/interceptors/fetch.ts#L18-L25](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L18-L25) | `if (typeof unsafeWindow !== 'undefined') { return unsafeWindow } return globalThis` |
| [src/interceptors/xhr.ts#L95](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L95) | `class CustomXHR extends getGlobalThis().XMLHttpRequest {` |
| [src/interceptors/xhr.ts#L499-L505](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L499-L505) | `const pureXHR = getGlobalThis().XMLHttpRequest` / `getGlobalThis().XMLHttpRequest = CustomXHR` / `return () => { getGlobalThis().XMLHttpRequest = pureXHR }` |
| [src/interceptors/xhr.ts#L268-L275](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L268-L275) | `// When another extension subclasses CustomXHR (e.g. uBOL Lite's` / `// json-prune-xhr-response), this.response walks the whole prototype` / `// chain …` / `// docs/ubol-compat.md.` |
| [src/interceptors/ws.ts#L5](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L5) | `/** @beta */`（`WSMessageEvent` / `WebSocketContext` / `WSMiddleware` / `interceptWebSocket` 均带此标注） |
| [src/interceptors/ws.ts#L46](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L46) | `class CustomWebSocket extends EventTarget {` |
| [src/interceptors/ws.ts#L182-L189](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L182-L189) | `.then(() => { if (!connected) { // Mock mode: no next() was called, simulate open` / `this.#readyState = 1` … |
| [src/interceptors/ws.ts#L195-L203](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L195-L203) | `throw new DOMException("Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.", 'InvalidStateError')` |
| [src/interceptors/ws.ts#L295-L298](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L295-L298) | `g.WebSocket = CustomWebSocket as any` / `return () => { g.WebSocket = OriginalWebSocket }` |
| [src/context.ts#L9-L15](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/context.ts#L9-L15) | 洋葱模型 compose（16 行） |
| [src/vista.ts#L19-L28](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/vista.ts#L19-L28) | `intercept() { this.cancels = this.interceptors.map(...) }` / `destroy() { this.cancels.forEach((cancel) => cancel()) }` |
| [src/types.ts#L11-L13](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/types.ts#L11-L13) | `export interface Interceptor<M …> { (middlewares: M[], config?: C): () => void }` |
| [package.json](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/package.json) | `"name": "@rxliuli/vista"`, `"license": "MIT"`, `"version": "0.5.3"`, `"sideEffects": false`, 无 `dependencies` |
| [LICENSE](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/LICENSE) | `MIT License` / `Copyright (c) 2024 rxliuli` |
| [README.md#L6](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L6) | `A powerful homogeneous request interception library that supports unified interception of Fetch/XHR/WebSocket requests.` |
| [README.md#L10-L16](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L10-L16) | `🚀 Supports Fetch, XHR and WebSocket interception` … `📦 Zero dependency, compact size` / `🌐 Supports browser extension and userscript environments` |
| [README.md#L44](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L44) | `Vista automatically detects the userscript environment and uses unsafeWindow to intercept page-level requests, so no additional configuration is needed.` |
| [README.md#L223-L237](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L223-L237) | `### Mock WebSocket connection` / `// Don't call next() — fully mock the connection` / `c.sendToClient(...)` |
| [README.md#L288-L290](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L288-L290) | `Does it support intercepting requests in Node.js? No, it only supports intercepting requests in the browser.` |
| [README.md#L292-L295](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L292-L295) | `- [xhook](https://github.com/jpillora/xhook): …` / `- [hono](https://github.com/honojs/hono): …` |
| [.gitignore](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/.gitignore) | 末行 `docs/`（解释了 `docs/ubol-compat.md` 为何不在仓库里） |
| [.github/workflows/build-and-release.yml](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/.github/workflows/build-and-release.yml) | `on: push: branches: [main] paths: ['package.json']` … `run: pnpm build` / `run: pnpm publish --access public`（**无 test 步骤**） |
| [.github/workflows/claude.yml](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/.github/workflows/claude.yml) | `uses: anthropics/claude-code-action@v1` / `--model claude-opus-4-6` |
| [build.config.ts](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/build.config.ts) | `input: 'src/', globOptions: { ignore: ['**/*.test.ts'] }`（→ `setup.ts` 被卷进 dist） |

### 8.2 GitHub 页面（issue / PR / 元数据）

| 来源 | 摘录 |
|---|---|
| [仓库首页](https://github.com/rxliuli/vista) | 描述：`A unified request interceptor library for both Fetch and XHR with middleware support.`；`"stargazerCount":27` |
| [issue #1](https://github.com/rxliuli/vista/issues/1) | 标题：`Request: Provide a CDN-friendly single-file build for easy Tampermonkey/Greasemonkey usage`；作者回复：`Check out vite-plugin-monkey …` → `Nice idea, would you like to submit a PR to add a new bundle format?` |
| [issue #4](https://github.com/rxliuli/vista/issues/4) | 标题：`Headers set in middleware are not applied to XHR`；正文给出 `#getMiddleware` 的修复 diff |
| [issue #5](https://github.com/rxliuli/vista/issues/5) | 标题：`Cannot use the library together with msw`；正文：`This happens because this library uses private fields on the XHR interceptor.` / `MSW uses a Proxy above the real XHR implementation (now its the Vista). So the problem is that a proxy that access target[propertyName] = value cannot work with private fields.` |
| [issue #11](https://github.com/rxliuli/vista/issues/11) | 标题：`How to use this in React chrome extension?`；正文：`Im developing a chrome extension using the crxjs template for react. How can I use this library to intercept the requests inside the react code?`；作者回复只有一个链接：`ref: https://rxliuli.com/blog/intercepting-network-requests-in-chrome-extensions/` |
| [PR #2](https://github.com/rxliuli/vista/pull/2) | `feat: Support CDN import by Ocyss` — MERGED |
| [PR #3](https://github.com/rxliuli/vista/pull/3) | `fix: HTTPException is not a constructor by Ocyss` — MERGED |
| [PR #6](https://github.com/rxliuli/vista/pull/6) | `fix(xhr): ensure to keep headers added by interceptor by susnux` — MERGED |
| [PR #7](https://github.com/rxliuli/vista/pull/7) | `fix(xhr): use correct type for parameter by susnux` — MERGED |
| [PR #8](https://github.com/rxliuli/vista/pull/8) | `fix(xhr): do not use private fields to allow compatibility with MSW by susnux` — **CLOSED（未合并）** |
| [PR #9](https://github.com/rxliuli/vista/pull/9) | `fix(xhr): handle loadend event by susnux` — MERGED |
| [PR #10](https://github.com/rxliuli/vista/pull/10) | `fix(xhr): properly pass request body to XHR in Firefox by susnux` — MERGED |
| [作者主页](https://github.com/rxliuli) | `<meta name="description" content="I like to create interesting things, using programming and writing as tools. - rxliuli">`；置顶仓库含 `joplin-utils`、`redirector`、`userscripts`、`AppDowngrader` |
| [Releases 页](https://github.com/rxliuli/vista/releases) | 无任何 release 条目（抓取到的 `/releases/tag/` 链接数为 0） |

### 8.3 发布物与元数据（实测命令）

| 指令 | 结果 |
|---|---|
| `git log -1` / `git tag -l` | HEAD = `55bba2f1455869f74febe0c353ccc66ce11becc8`（2026-08-02，`0.5.3`）；tag 最大为 `v0.5.2` |
| `curl https://registry.npmjs.org/@rxliuli/vista` | `"license":"MIT"`；`"dist-tags":{"latest":"0.5.3"}`；`time.created 2025-01-06T11:54:34.334Z`；`time['0.5.3'] 2026-08-02T04:58:54.539Z`；29 个版本；`maintainers [{name: rxliuli}]`；最新版无 `dependencies` / `peerDependencies` |
| `curl https://api.npmjs.org/downloads/point/last-month/@rxliuli/vista` | `{"downloads":1098,"start":"2026-09-05","end":"2026-10-04"}` |
| `curl https://api.npmjs.org/downloads/point/last-week/@rxliuli/vista` | `{"downloads":422,"start":"2026-09-28","end":"2026-10-04"}` |
| `npm pack @rxliuli/vista@0.5.3` + `tar tzf` + `gzip -c` | tarball 16,091 B；`dist/index.iife.mjs` 22,036 B → gzip 5,483 B；ESM 入口集合 gzip 5,528 B；`dist/setup.mjs` 首行 `import { serve } from "@hono/node-server"` |
| `grep -rnE "\beval\(\|new Function\|document\.\|window\." src/`（排除测试） | 仅 `src/cdn.ts:4: window.Vista = Vista` → 无 eval、无 DOM 依赖 |
| `grep -rniE "userscript\|unsafeWindow\|content script\|extension\|chrome\.\|manifest" src/` | 仅 `unsafeWindow` 探测与该 uBOL 注释/测试注释 → **无任何扩展 API 调用** |
| `ls -a`（仓库根） | `.github .gitignore LICENSE README.md build.config.ts package.json pnpm-lock.yaml src tsconfig.json vitest.config.ts vitest.shims.d.ts` → **无 docs/、无 examples/、无 CHANGELOG** |
| 沙箱环境检查 | `which chromium chromium-browser google-chrome firefox` 无输出；`require('playwright')` 失败 → **无法做浏览器实验** |

### 8.4 作者文章（原文 403，经 tool.lu 转载/译文）

- 入口：`https://rxliuli.com/blog/intercepting-network-requests-in-chrome-extensions/`（**HTTP 403，Cloudflare**）、中文 `https://blog.rxliuli.com/p/7ffe39eff5c64f5d90acf21518e39d63/`（**HTTP 403**）、Wayback `archived_snapshots: {}`（无快照）
- 实际引用来源：[tool.lu 转载页](https://tool.lu/index.php/ru_RU/article/77N/preview)（自述"出处：https://rxliuli.com/blog/intercepting-network-requests-in-chrome-extensions/"，**机器译文**）

摘录（译文，逐字）：

> - mswjs: A mocking library capable of intercepting XHR/fetch requests, but requires a service worker, which isn't possible for Chrome extension Content Scripts.
> - xhook: An interception library that can intercept XHR requests but not fetch requests. …

> The core approach is to override globalThis.fetch with a custom implementation that runs middlewares and calls the original fetch at an appropriate time

> A complete fetch/XHR interceptor has been implemented and published to npm as @rxliuli/vista.

（**注意**：该文**只讲 fetch 与 XHR**，无 WebSocket 章节；**也未讨论 MV3、MAIN world、页面 CSP**。）

### 8.5 Chrome 官方文档

| 来源 | 原文摘录 |
|---|---|
| [Content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts) | `Content scripts live in an isolated world, allowing a content script to make changes to its JavaScript environment without conflicting with the page or other extensions' content scripts.` |
| 同上 | `Note: Not only does each extension run in its own isolated world, but content scripts and the web page do too. This means that none of these (web page, content scripts, and any running extensions) can access the context and variables of the others.` |
| 同上 | `When a content script is injected into the main world, the CSP of the page applies.` |
| 同上 | `world` — `ExecutionWorld` — `Optional. The JavaScript world for a script to execute within. Defaults to ISOLATED.` |
| 同上 | `run_at` / `document_start` — `Scripts are injected after any files from css, but before any other DOM is constructed or any other script is run.` |
| [browser.scripting](https://developer.chrome.com/docs/extensions/reference/api/scripting) | `ExecutionWorld`（Chrome 95+）— `"ISOLATED" Specifies the isolated world…` / `"MAIN" Specifies the main world of the DOM, which is the execution environment shared with the host page's JavaScript.` |
| 同上 | `ScriptInjection.world` — `Chrome 95+ The JavaScript "world" to run the script in. Defaults to ISOLATED.`；`ContentScript.world`（registerContentScripts）— `Chrome 102+` |
| 同上 | `injectImmediately` — `Note that this is not a guarantee that injection will occur prior to page load, as the page may have already loaded by the time the script reaches the target.` |
| 同上 | `executeScript()` — `Injects a script into a target context. By default, the script will be run at document_idle, or immediately if the page has already loaded.` |
| 同上 | `InjectionTarget` 属性只有 `allFrames` / `frameIds` / `documentIds` / `tabId` → **无 Worker 目标** |
| [browser.userScripts](https://developer.chrome.com/docs/extensions/reference/api/userScripts) | `ExecutionWorld`：`"USER_SCRIPT" Specifies the execution environment that is specific to user scripts and is exempt from the page's CSP.` |
| 同上 | 需要 `"userScripts"` 权限与 `host_permissions`；`Availability Chrome 120+ MV3+`；`If the Allow User Scripts toggle is not enabled, browser.userScripts is undefined.`；Chrome <138 用 Developer mode 开关，≥138 用 "Allow User Scripts" 开关 |
| [Service worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle) | `Normally, Chrome terminates a service worker when one of the following conditions is met: After 30 seconds of inactivity. Receiving an event or calling an extension API resets this timer. When a single request … takes longer than 5 minutes to process.` |
| 同上 | `Any global variables you set will be lost if the service worker shuts down. Instead of using global variables, save values to storage.` |

### 8.6 WHATWG 规范（判定"保真/伪装"的对照基准）

| 来源 | 原文摘录 |
|---|---|
| [HTML §Web sockets](https://html.spec.whatwg.org/multipage/web-sockets.html) | `[Exposed=(Window,Worker)] interface WebSocket : EventTarget {` |
| 同上（构造器步骤） | `Let urlRecord be the result of applying the URL parser to url with baseURL.` / `If urlRecord is failure, then throw a "SyntaxError" DOMException.` / `If urlRecord's scheme is not "ws" or "wss", then throw a "SyntaxError" DOMException.` / `If urlRecord's fragment is non-null, then throw a "SyntaxError" DOMException.` |
| 同上（close 步骤） | `The close(code, reason) method steps are: If code is present, but is neither an integer equal to 1000 nor an integer in the range 3000 to 4999, inclusive, throw an "InvalidAccessError" DOMException.` / `If reasonBytes is longer than 123 bytes, then throw a "SyntaxError" DOMException.` |
| [XHR 规范](https://xhr.spec.whatwg.org/) | `[Exposed=(Window,DedicatedWorker,SharedWorker)] interface XMLHttpRequest : XMLHttpRequestEventTarget {` |
| [Fetch 规范](https://fetch.spec.whatwg.org/) | `partial interface mixin WindowOrWorkerGlobalScope { [NewObject] Promise<Response> fetch(RequestInfo input, optional RequestInit init = {}); };` |
| [Web IDL 规范](https://webidl.spec.whatwg.org/) | `Some objects described in this section are defined to have a class string, which is the string to include in the string returned from Object.prototype.toString. If an object has a class string classString, then the object must, at the time it is created, have a property whose name is the %Symbol.toStringTag% symbol with PropertyDescriptor{… [[Value]]: classString}.` |

---

**（文档结束）本次调研未修改任何代码，未改动 `docs/concept-design/concept-design.md`，仅新增本文件。**
