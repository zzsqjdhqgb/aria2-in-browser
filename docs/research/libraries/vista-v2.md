# rxliuli/vista 调研（v2 · 独立取证版）

> 本文是 `/workspace/docs/research/libraries/vista.md`（下称**原件**）的独立重跑，不覆盖原件。
> 与原件的关系、以及逐条结论的证实/推翻，集中在 **§8**。
>
> **结论速览**
> - **它是什么**：一个约 5.5 KB(gzip)、零运行时依赖、MIT 的**浏览器内请求拦截中间件库**——把 `fetch` / `XMLHttpRequest` / `WebSocket` 三个全局换成自己的实现，以 Koa/Hono 式洋葱中间件让调用方观察、改写、**完全伪造**请求与响应。
> - **能不能借鉴**：**能**。本项目第一层"转发器"所需的"命中即伪造、未命中放行"与它**结构同构**（"真实请求＝链尾中间件"）；WS 的 mock 通道就是 Q-D3 想要的形状。**但它的 XHR 伪造实现有一条致命缺陷**（见下），只能借鉴设计、不能照抄实现。
> - **能不能直接用**：**有条件能**——它可作为依赖放进 MV3（零依赖、无 `eval`、无扩展 API），且**已被至少 3 个真实 MV3 扩展以 `world:"MAIN"` + `document_start` 用于拦截第三方页面**（本次拿到硬证据）；本次还在 Chromium 148 里做了受控实验：**页面严格 CSP 下，MAIN world 注入的 vista 成功伪造了页面自身的 fetch/XHR/WS 响应**。但它**自己没有注入能力、没有 manifest**（全量源码复核确认），这一层必须由宿主提供。**且把它用于"伪造响应"前必须先修它伪造不完整的问题**（`xhr.response`/响应头/`responseType='json'` 全部拿不到伪造值）。
> - **最大的新发现（原件未识别）**：vista 伪造响应时，**页面只能拿到 `responseText`，拿不到 `response`、拿不到任何伪造响应头**——因为 `responseToXHR()` 把伪造属性定义在一个**内部临时 XHR** 上，而 `CustomXHR` 没有把 `response`/`getAllResponseHeaders`/`getResponseHeader` 委托过去。原件 §2.7 的 X3 把这个临时对象当成了页面可见行为，**结论反了**。

---

## 0 元信息

| 项 | 值 |
|---|---|
| 调研日期 | 2026-10-06（UTC） |
| 调研对象 | `rxliuli/vista` — https://github.com/rxliuli/vista ；npm `@rxliuli/vista` |
| 快照版本（源码） | 默认分支 `main`，HEAD = **`55bba2f1455869f74febe0c353ccc66ce11becc8`**，subject `0.5.3`，提交时间 2026-08-02 11:58:10 +0700。**完整克隆**（非浅克隆）：`git rev-list --count HEAD` = **87**，tag 24 个（最大 `v0.5.2`），分支 2 个 |
| 快照版本（发布物） | npm `@rxliuli/vista@0.5.3`（`dist-tags.latest`），发布 2026-08-02T04:58:54Z。tarball **16,091 B / 30 个文件 / unpacked 65,909 B**；`shasum 0e8b870df63d3febeed48e23737d5ba2b998e998`；sha512(hex) `033f469b…b4d4`。**SLSA provenance 已实测解码**：该 sha512 由 GitHub Actions 工作流 `build-and-release.yml` 在 `refs/heads/main` 上、从 **`55bba2f…`** 这个 commit 构建（详见 §10.3） |
| 许可证 | MIT（`LICENSE`：`MIT License / Copyright (c) 2024 rxliuli`；`package.json` `"license": "MIT"`） |
| 引用约定 | 源码引用一律给 **SHA 固定链接**，行号对应 `55bba2f`；运行时结论标注 **【实测】** 并给出实验条件 |

### 0.1 本次用到的取证通道及成功率

| 通道 | 结果 | 说明 |
|---|---|---|
| **Wayback Machine（availability API）** | ✅ **成功** | 两个博客 URL **都有快照**：英文 `20250712131024`、中文 `20251207203712`；已抓 `id_` 原始快照并提取正文 |
| Wayback CDX API | ⚠️ 部分 | `cdx/search/cdx` 返回 **429 Too Many Requests**（限流）；改用 `archive.org/wayback/available` 成功定位快照 |
| 作者博客线上原文 | ❌ 403 | `rxliuli.com/...` 与 `blog.rxliuli.com/...` 仍为 **Cloudflare 403**（与原件相同） |
| **完整 git 克隆** | ✅ 成功 | 87 个提交、全部 tag、全部历史（原件为 `--depth 50` 浅克隆） |
| **npm registry / tarball** | ✅ 成功 | `npm pack` 实测大小与哈希，与 registry 完全一致 |
| **npm 溯源证明（attestations）** | ✅ 成功 | 解出 SLSA payload，绑定到具体 commit |
| **unpkg / jsdelivr** | ✅ 成功 | `dist/index.mjs` 与 tarball 内文件字节一致（sha256 比对） |
| **raw.githubusercontent.com** | ✅ 成功 | README、MBT / clean-twitter / nextcloud 的源文件，全部 200 |
| **GitHub REST API** | ⚠️ 部分 | 首次调用成功（repo 元数据）；随后 **60/hr 未认证额度用尽**，改用 codeload / raw / 网页 |
| **GitHub commit `.patch`** | ✅ 成功 | 用于核实"vista 起源于 Mass Block Twitter" |
| **GitHub issues / PR** | ✅ 成功（API 限流前） | 4 issue + 7 PR 全量正文与评论 |
| **沙箱内真实浏览器** | ✅ **成功（本次最大增量）** | 安装 Playwright + **Chromium 148.0.7778.96**，做了 6 组运行时实验，含 **MV3 扩展 + 严格 CSP 的受控实验** |
| deepwiki.com（仓库 homepage） | ❌ 429 | Vercel 安全检查；经 Wayback 取到 2025-04-27 快照 |
| npmjs.com dependents / grep.app / libraries.io | ❌ | 403 Cloudflare / Vercel 检查点 / "Disabled for performance reasons" |
| GitHub code search | ❌ | `code_search` 额度 60/60 用尽 |

### 0.2 调研充分度自评

**总体：高（高于原件）。** 问题 1/2/4/6 = 高；问题 3 = 高；**问题 5 = 高**——原件最关键的两处"必须 POC"（MAIN world 是否被页面 CSP 阻挡、是否有真实 MV3 用例）本次**都拿到了证据**：
- 真实 MV3 用例：**3 个扩展**（`mass-block-twitter` 78★、`clean-twitter` 18★、`httap`）× `world:"MAIN"` + `document_start`，其中两个已上架商店；
- MAIN world + 严格 CSP：**本地受控实验**（含 ISOLATED 对照组与 CSP 生效对照），fetch/XHR/WS 三条途径全部伪造成功。

**仍未验证的项集中列在 §9**，未用推测填补。**注意**：运行时实验只覆盖 Chromium 148（Playwright 自带构建）与本地 HTTP 服务，**未覆盖 Firefox/Safari、未覆盖真实 Chrome 稳定版、未覆盖 Chrome Web Store 审核行为**。

---

## 1 它是什么

**`@rxliuli/vista` 是一个"浏览器内的请求拦截中间件库"：把 `fetch` / `XMLHttpRequest` / `WebSocket` 三个全局对象换成自己的实现，让调用方用洋葱中间件去监听、改写、甚至完全伪造请求与响应。**

README 首句（[README.md#L6](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L6)）：

> A powerful homogeneous request interception library that supports unified interception of Fetch/XHR/WebSocket requests. It allows you to intervene at different stages of the request lifecycle, enabling various functions such as request monitoring, modification, and mocking.

### 1.1 解决什么问题 / 面向什么场景 —— 现在拿到的是**原文**，不是机器译文

原件只能引用 **tool.lu 的机器译文**。本次从 Wayback 取到**作者站点原文快照**（英文 + 中文两版，均为作者本人文字）：

英文原文（[Wayback 20250712131024](http://web.archive.org/web/20250712131024/https://rxliuli.com/blog/intercepting-network-requests-in-chrome-extensions/)，页面标注 `2025-05-10 · 10 min read`）：

> **Motivation** — While implementing the Chrome extension Mass Block Twitter, I needed to block Twitter spam users in bulk. Twitter's request headers contain authentication information that appears to be dynamically generated via JavaScript. Rather than investigating how Twitter generates these authentication details, I decided it would be more efficient to intercept existing network requests…
>
> Existing libraries I investigated include:
> - **mswjs**: A mocking library capable of intercepting XHR/fetch requests, but requires a service worker, **which isn't possible for Chrome extension Content Scripts**.
> - **xhook**: An interception library that can intercept XHR requests but not fetch requests. Additionally, **its last update was two years ago, suggesting that it's no longer maintained.**
>
> Therefore, I decided to implement my own solution.

中文原文（[Wayback 20251207203712](http://web.archive.org/web/20251207203712/https://blog.rxliuli.com/p/7ffe39eff5c64f5d90acf21518e39d63/)，页面标注 `2025年1月2日`、`本文最后更新于：2025年1月15日`）：

> 在实现 Chrome 插件 Mass Block Twitter 时，需要批量屏蔽 twitter spam 用户……因而出现了拦截 xhr 的需求，之前也遇到过需要拦截 fetch 请求的情况，而目前现有的库并不能满足需要。
> - mswjs：一个 mock 库，可以拦截 xhr/fetch 请求，但是需要使用 service worker，**而这对于 Chrome 插件的 Content Script 来说是不可能的**。
> - xhook：一个拦截库，可以拦截 xhr 请求，但无法拦截 fetch 请求，而且最后一个版本是两年前，似乎不再有人维护了

设计目标（两版一致）：拦截 fetch/XHR、支持改 request url 做代理、支持调用原始请求并修改 response、支持 **SSE 流式响应**。

**重要限定**：该文**只讲 fetch 与 XHR**，全文**没有 WebSocket 章节**，也**完全没提 MV3 / MAIN world / CSP / content script 与页面世界的区别**（见 §6.5）。

### 1.2 核心概念与 API

| 概念 | 说明 | 源码位置 |
|---|---|---|
| `Vista` 类 | `new Vista([...拦截器])` → `.use(mw)` → `.intercept()` → `.destroy()` | [src/vista.ts#L3-L28](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/vista.ts#L3-L28) |
| 拦截器 Interceptor | `(middlewares) => () => void`，即"装上、返回卸载函数"；内置 `interceptFetch` / `interceptXHR` / `interceptWebSocket` | [src/types.ts#L11-L13](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/types.ts#L11-L13) |
| 洋葱中间件 | `(c, next) => void \| Promise<void>`；`await next()` 放行到下一层；**不调 `next()` 即短路** | [src/context.ts#L5-L16](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/context.ts#L5-L16) |
| HTTP 上下文 | `{ type: 'fetch'\|'xhr'\|'request', req: Request, res: Response }`；**fetch 与 XHR 共用**，XHR 只是 `type:'xhr'` | [src/interceptors/fetch.ts#L5-L16](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L5-L16)、[xhr.ts#L308-L312](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L308-L312) |
| WebSocket 上下文（`@beta`） | `{ type:'websocket', url, protocols, sendToClient, sendToServer, onClientMessage, onServerMessage, onOpen, onClose }`；**不调 `next()` = 完全 mock，不建真实连接** | [src/interceptors/ws.ts#L12-L37](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L12-L37) |
| 错误模型 | `HTTPException(status, {res?, message?, cause?})`，`getResponse()` 产出 `Response`；fetch/XHR 捕获后转成响应/`error` 事件（概念抄自 Hono） | [src/http-exception.ts](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/http-exception.ts) |
| 内置中间件 | `timeout(ms)`、`prettyJSON()`（文件头 JSDoc 指向 hono.dev，是**从 Hono 搬来的模块**） | [src/middlewares/](https://github.com/rxliuli/vista/tree/55bba2f1455869f74febe0c353ccc66ce11becc8/src/middlewares) |
| 全局探针 | `getGlobalThis()`：存在油猴 `unsafeWindow` 就返回它，否则 `globalThis` | [src/interceptors/fetch.ts#L18-L25](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L18-L25) |

公开导出（`src/index.ts` 逐字）：`export * from './types' / './vista' / './interceptors/fetch' / './interceptors/xhr' / './interceptors/ws' / './middlewares/timeout' / './middlewares/pretty-json'`。运行时实测命名空间键为：`Vista, getGlobalThis, interceptFetch, interceptWebSocket, interceptXHR, prettyJSON, timeout`。
**注意**：`HTTPException` **不在**根入口导出（虽然它出现在公开类型签名里）——这是本次发现的 API 面缺口。

README 明说的能力（[README.md#L10-L16](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L10-L16)）：三途径拦截、中间件模式、请求前后干预、可改请求与响应数据、**Zero dependency, compact size**、**Supports browser extension and userscript environments**、**Modifiable stream response**。

关于"能拦页面层"的唯一说明（[README.md#L44](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L44)）：

> Vista automatically detects the **userscript environment** and uses `unsafeWindow` to intercept page-level requests, so no additional configuration is needed.

——限定词是 **userscript environment**（油猴）。**README 全文 303 行里 `manifest` / `MV3` / `MAIN world` / `content script` / `CSP` 的出现次数为 0**（本次实测 grep，见 §6.5）。

FAQ 明确只面向浏览器（[README.md#L288-L290](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/README.md#L288-L290)）：*"Does it support intercepting requests in Node.js? No, it only supports intercepting requests in the browser."*

### 1.3 作者与生态背景（本次大幅补强）

| 项 | 事实 | 来源 |
|---|---|---|
| 作者 | `rxliuli`；npm 维护者仅 `rxliuli <rxliuli@gmail.com>`；GitHub bio："I like to create interesting things, using programming and writing as tools." | GitHub / npm registry |
| **血统（新证据）** | **vista 是从 `rxliuli/mass-block-twitter` 里抽出来的**。commit `7f54368…`（2025-01-05，"feat: udpate xhr interceptor"）的 diffstat **删除了** `src/lib/interceptors.ts`（241 行）并**加入**了 `libs/rxliuli-vista-0.1.0.tgz`（5,953 B）；次日（2025-01-06T11:54:34Z）vista 0.1.0 发布到 npm。**本次已自行拉取该 commit 的 patch 核实** | `https://github.com/rxliuli/mass-block-twitter/commit/7f54368.patch` |
| repo 元数据 | 27★ / 3 fork / 1 watcher / 157 KB / `open_issues_count: 0` / `archived: false` / `homepage: https://deepwiki.com/rxliuli/vista` | GitHub API（限流前） |
| 贡献者 | 3 人：`rxliuli` 80 次提交、`susnux`(Ferdinand Thiessen) 4、`Ocyss` 3（合计 87） | GitHub API `/contributors` |
| 语言 | `{"TypeScript": 76970}`（100% TS） | GitHub API `/languages` |
| 相关项目 | 同作者 `joplin-utils`(315★)、`llm-api-proxy`(152★)、`AppDowngrader`(116★)、`userscripts`(102★)、`redirector`(85★)、`mass-block-twitter`(78★)、`vista`(27★)、`clean-twitter`(18★)、`httap`(0★) | GitHub 搜索 API |
| **下游真实使用者** | 至少 5 个：`mass-block-twitter`（MV3，`^0.4.9`）、`clean-twitter`（MV3，`^0.5.3`）、`httap`（MV3，`^0.5.2`）、**`nextcloud/end_to_end_encryption`（321★，`package.json:51` 为 `"@rxliuli/vista": "^0.5.3"`）**、`rxliuli/userscripts`（声明但**未实际引用**） | raw.githubusercontent（nextcloud 一行由**本次亲自 curl 核实**） |
| 生态位 | "用户脚本 + 扩展 + 普通网页"通用小型拦截库；提供 CDN/IIFE（`window.Vista`）服务无构建链的用户脚本场景 | README、`src/cdn.ts` |
| ⚠️ README 的自相矛盾 | 原作者在 README 里推荐构建工具时指的是**别人的** `vite-plugin-monkey`（issue #1），说明作者并不打算提供构建链 | issue #1 |

---

## 2 实现原理（带源码位置）

### 2.1 总览：三件事

1. **替换全局对象**：`fetch` 直接赋值替换；`XMLHttpRequest` / `WebSocket` 用"子类 + 换全局"替换。
2. **洋葱中间件链**：16 行递归 compose（[context.ts#L9-L15](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/context.ts#L9-L15)，逐字）：

```ts
const compose = (i: number): Promise<void> => {
  if (i >= middlewares.length) {
    return Promise.resolve()
  }
  return middlewares[i](context, () => compose(i + 1)) as Promise<void>
}
await compose(0)
```

3. **把"真实请求"实现为链上最后一段中间件** ⇒ "某段中间件不调 `next()`"就等于"请求根本不出网"。

**替换发生在 `intercept()` 调用时，不在 import 时**（这一点对宿主的注入时机很关键，【实测】三途径一致）：
`Vista.intercept()` → `this.interceptors.map((interceptor) => interceptor(this.middlewares))`（[vista.ts#L19-L23](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/vista.ts#L19-L23)）。因此**在 `intercept()` 之前被页面捕获的原生引用不会受影响**（`x instanceof 捕获的旧构造器` 为 false）。

### 2.2 fetch 拦截（56 行）

```ts
// src/interceptors/fetch.ts#L30-L31（逐字）
const pureFetch = getGlobalThis().fetch
getGlobalThis().fetch = async (input, init) => {
```
```ts
// src/interceptors/fetch.ts#L38-L43（逐字）
await handleRequest(c, [
  ...middlewares,
  async (context) => {
    context.res = await pureFetch(c.req)
  },
])
```
- 返回 `c.res`（可以是中间件伪造的 `Response`）；卸载即 `getGlobalThis().fetch = pureFetch`（[fetch.ts#L53-L55](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L53-L55)）。
- 【实测】伪造成功：中间件不调 `next()` 时 `fetch(TARGET)` 在 **1 ms** 内返回伪造响应，真实端点未被访问；`{status:200, headers:{'x-test':'mocked-value'}}` 页面可见。
- 【实测】伪造的副作用：`res.url === ""`（原生为真实 URL）、`res.type === "default"`（原生 `"basic"`）。

### 2.3 XHR 拦截（506 行，最复杂）

策略：**继承原生 XHR，把"记录"与"真实发送"分离**。

| 环节 | 位置 | 行为 |
|---|---|---|
| 子类化 | [xhr.ts#L95](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L95) | `class CustomXHR extends getGlobalThis().XMLHttpRequest` |
| `open()` 只记录 | [xhr.ts#L110-L136](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L110-L136) | **不调用 `super.open`** |
| `setRequestHeader()` 只记录 | [xhr.ts#L144-L146](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L144-L146) | 存进 `#headers` |
| `send()` 才跑链 | [xhr.ts#L297-L317](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L297-L317) | 构造 `Request`（`type:'xhr'`），链尾才是 `super.open/super.setRequestHeader/super.send` |
| 伪造响应载体 | [xhr.ts#L9-L73](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L9-L73) | `responseToXHR()` **另开一个 `new XMLHttpRequest()` 当属性载体**，用 `Object.defineProperties` 钉上 `status/statusText/responseURL/readyState/response/responseType/responseText/getAllResponseHeaders/getResponseHeader` |
| getter 委托 | [xhr.ts#L214-L247](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L214-L247) | 只委托 `status/statusText/responseURL/readyState/responseText/responseType` **六个** |
| 换全局 | [xhr.ts#L499-L505](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L499-L505) | `getGlobalThis().XMLHttpRequest = CustomXHR` |

> ⚠️ **上表最后两行是本次最重要的发现**：`response` / `getAllResponseHeaders` / `getResponseHeader` **不在委托之列**，所以伪造值只存在于内部载体上，**页面永远看不到**。原件 X3 恰恰把这个内部实现当成了页面可见行为（见 §7 X3）。【实测】证据见 §2.6。

其他要点：
- 错误一律转成合成响应 + `error` 事件（`HTTPException` → 其 `Response`；字符串/`Error`/其它 → 500）（[xhr.ts#L318-L354](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L318-L354)）。**但错误路径只派发 `error`，不派发 `readystatechange` 与 `loadend`**。
- 流式分支：`text/event-stream` 与 `application/octet-stream`（**必须精确等于**，[xhr.ts#L18-L21](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L18-L21)）时 `response` 给 `ReadableStream`、`readyState = LOADING`，并对 SSE 逐块派发 `progress`。
- 多扩展共存防御：从 `super.*` 读上游而非 `this.*`，注释点名 uBOL Lite（[xhr.ts#L268-L283](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L268-L283)）；注释引用的 `docs/ubol-compat.md` **在仓库中不存在**（`.gitignore` 第 6 行是 `docs/`；且本次用 `git log --all -- 'docs/*'` 确认该路径**从未被提交过**）。

### 2.4 WebSocket 拦截（299 行，源码标 `@beta`）

- `class CustomWebSocket extends EventTarget`（**不是原生 `WebSocket` 的子类**），`g.WebSocket = CustomWebSocket`（[ws.ts#L46](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L46)、[ws.ts#L295-L298](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L295-L298)）。
- **构造器里就跑中间件链**；链尾才 `new OriginalWebSocket(...)`（[ws.ts#L144-L181](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L144-L181)）。
- **mock 模式**：`connected` 标志只在链尾中间件里被置 true，链跑完后若仍为 false，则直接置 OPEN 并派发 `open`（[ws.ts#L182-L189](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L182-L189)）：

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
- 双向消息用"可改写事件对象"`{ get data, replaceWith(d), preventDefault() }`（[ws.ts#L222-L266](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L222-L266)）；反向推送 `sendToClient(data)` → `#emitMessage` → 同时调 `onmessage` 与 `dispatchEvent`（[ws.ts#L276-L280](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L276-L280)）。
- `send()` 非 OPEN 抛 `DOMException(..., 'InvalidStateError')`（[ws.ts#L195-L203](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L195-L203)）；mock 模式 `close()` 用 `queueMicrotask` 补发 `close`（[ws.ts#L205-L218](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L205-L218)）。
- 【实测】**mock 双向通道可用**：页面 `ws.send({id:1,method:'aria2.getVersion'})` → 中间件 `onClientMessage` → `c.sendToClient(伪造 JSON-RPC 响应)` → 页面的 `message` 事件收到 `{"id":1,"result":{"version":"1.37.0"}}`，**全程不建真实连接**。

### 2.5 用了什么 / 不依赖什么

| 问题 | 结论 | 证据 |
|---|---|---|
| 依赖 Service Worker？ | **否**。选型动机就是 mswjs 需要 SW 而"扩展 Content Script 里不可能用" | 博客原文（本次取到原文，非译文） |
| 改写 fetch / XHR / WebSocket？ | **是**，三者都替换全局，**在 `intercept()` 时** | 见 §2.1–§2.4 |
| 依赖扩展 API？ | **否**。全量源码 `grep -rnE 'chrome\.\|browser\.\|manifest\|content_scripts\|eval\(\|new Function' src --include='*.ts'` → **无任何命中（exit 1）**，含测试目录 | 本次亲自执行 |
| 只在开发期生效？ | **否**，纯运行时 | 无 `NODE_ENV` 分支 |
| 依赖构建插件 / 运行时注入？ | **否，而且它完全没有注入能力**——必须由宿主把它加载进目标世界 | 仓库只有 24 个文件，**无 `manifest.json`、无 background/content/inject/sw 文件、无 `public/`**；`grep -rniE 'serviceworker\|manifest\.json\|content_script\|injectScript\|GM_' src README.md build.config.ts package.json` → 无命中 |
| 需要 `eval` / `new Function`？ | **否**（MV3 CSP 友好） | 同上 grep；唯一 `window.` 是 `src/cdn.ts:4 window.Vista = Vista` |
| 需要 DOM？ | **基本不需要** | `interceptXHR` 在 `typeof XMLHttpRequest === 'undefined'` 时返回空卸载函数（[xhr.ts#L92-L94](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L92-L94)） |
| 运行时依赖 | **零**。`package.json` 无 `dependencies` / `peerDependencies` / `engines`；`exports` 只有一个 `"."`（`import` + `types`，**无 `require`/`default`/`browser`**）；`sideEffects: false`；`files: ["dist"]` | npm registry 实测 |
| 体积（本次实测） | tarball 16,091 B / 30 文件 / unpacked 65,909 B；`dist/index.iife.mjs` 22,036 B → **gzip 5,464 B**；ESM 入口闭包 10 个文件 22,482 B → 合并 gzip **5,480–5,496 B**（实测值随拼接顺序小幅变化）；`dist/index.mjs` 本身只是 269 B 的 re-export 壳 | 本地 `npm pack` + `gzip -9` |
| 发布物与源码是否一致 | **是（强证据）**：SLSA provenance 把 tarball 的 sha512 绑定到 `55bba2f…`；且从该 commit 干净重建可产出 27 个 dist 文件**逐字节相同** | §10.3 |
| ⚠️ 发布瑕疵 | `dist/setup.mjs`（2,618 B）被卷进包里，其首行 `import { serve } from "@hono/node-server";` 引用的是 **devDependencies**。但它在 `exports` 之外、也不在 `index.mjs` 的导入闭包内 → **只是死重（约 4% 体积），不会破坏消费者**（深导入报 `ERR_PACKAGE_PATH_NOT_EXPORTED`） | 实测 + [build.config.ts](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/build.config.ts)（入口 glob 掉整个 `src/`，只忽略 `**/*.test.ts`） |

### 2.6 【实测】伪造响应的真实可见性——本项目最该知道的一件事

实验条件：Chromium 148 headless，本地 HTTP 服务，vista 0.5.3 IIFE 经 `addInitScript` 在页面脚本前装入 MAIN world；中间件对 `/api/json` **短路**（不调 `next()`），伪造 `200 + Content-Type: application/json + X-Test: mocked-value + body {"ok":true,"from":"vista-mock"}`。

| 页面读到的 | 【实测】vista 伪造路径 | 原生（同 URL 真实请求） |
|---|---|---|
| `xhr.status` / `statusText` | `200` / `"OK"` ✅ | `200` / `"OK"` |
| `xhr.responseText` | `{"ok":true,"from":"vista-mock"}` ✅ | 真实 body |
| **`xhr.response`** | **`""`（空串，原生 XHR 的值）** ❌ | 真实 body |
| **`xhr.getAllResponseHeaders()`** | **`""`** ❌ | `"connection: keep-alive\r\ncontent-type: …\r\n…\r\n"`（**小写名 + 结尾有 `\r\n`**） |
| **`xhr.getResponseHeader('X-Test')` / `('x-test')`** | **`null` / `null`** ❌ | 大小写不敏感，命中 |
| `xhr.responseURL` | `""`（伪造 `Response` 没有 url）❌ | 真实 URL |
| `responseType='json'` 时 `xhr.response` | **`null`** ❌ | 解析后的对象 |
| `readyState`（`open()` 之后 / `send()` 同步返回后 / 完成） | **`0` / `0` / `4`** ❌（原生 `1` / `1` / …） | `1` / `1` / `4` |
| 事件顺序 | **`load → loadend → readystatechange`** ❌（原生 `rs1,rs2,rs3,rs4,load,loadend`） | 见左 |
| `send()` 返回值 | **`Promise`** ❌ | `undefined` |
| 伪造响应头是否可见（**"改写响应"路径**：调 `next()` 后再换 `c.res`） | `status=200`、`responseText=MODIFIED-BODY`，但 **`response` = 真实网络 body、`getAllResponseHeaders()` = 真实网络响应头、`getResponseHeader('X-Modified-By-Middleware')` = `null`** ❌ | — |

**结论：vista 的"伪造响应"目前只能骗过读 `responseText` 的代码。** 读 `response`、读响应头、或把 `responseType` 设成 `json` 的客户端会拿到**空值或真实网络值**——后者更危险：它会把真实响应当成 mock 结果。

### 2.7 【实测】MV3 + MAIN world + 严格页面 CSP（原件的一号阻塞问题的答案）

实验设计（三格对照，本地加载未打包 MV3 扩展，Chromium 148）：

| 格 | 扩展 | 页面 | 结果 |
|---|---|---|---|
| A | `content_scripts {world:"MAIN", run_at:"document_start"}` | 无 CSP | 注入成功；`document.readyState==='loading'` 时已在页面世界；页面自身 fetch/XHR/WS **全部被替换**；伪造响应命中 |
| B | 同上 | **严格 CSP**：`default-src 'self'; script-src 'self'` | **页面内联脚本被 CSP 拦掉（`inlineRan:false`，证明 CSP 真的生效）**；而 MAIN world 注入**照常成功**，页面自身 `fetch('/api/json')` 拿到 `{"from":"vista-mock","via":"MAIN-world"}` 且响应头 `X-Aria2-Mock: yes` 可见；XHR 拿到伪造 body；**WebSocket 走 mock 模式收到伪造 JSON-RPC 推送**，无 error/close |
| C | `world:"ISOLATED"`（对照组） | 无 CSP | `window.__mainWorld === undefined`（页面看不到隔离世界的变量）；`fetchStillNative/xhrStillNative/wsStillNative` **全为 true**；页面 fetch 拿到**真实服务器**响应 |

**这三格一起回答了**：
1. `world:"MAIN"` 的**文件注入**不会被页面 CSP 阻挡（CSP 约束的是注入代码*去做什么*，例如 `eval`／内联／远程脚本，而不是浏览器注入内容脚本这个动作本身）；
2. **ISOLATED world 拦不到页面请求**——原件 §5.1 的推理正确，本次给了实测对照；
3. `document_start` + MAIN world 下，注入脚本在页面脚本之前完成替换（`readyState === 'loading'`）；
4. Chrome 官方文档那句 *"When a content script is injected into the main world, the CSP of the page applies."* **与"能否注入/能否改写全局"不矛盾**——本次实测证实注入与改写都成功。

---

## 3 与本项目问题的交集

| 本项目条目 | vista 的对应物 | 交集判定 |
|---|---|---|
| **R4.1 命中配置地址就拦、未命中放行** | 中间件链 + "链尾＝真实请求"：最外层中间件做 URL 判定，命中则 `c.res = 伪造响应; return`，未命中 `await next()` | ✅ **结构完全同构**；【实测】两条路径都验证过 |
| **R9 拦截发生在 JS API 层，命中后请求根本不出网** | fetch：`pureFetch` 不会被调用；XHR：`super.open/super.send` 都在链尾中间件里，短路时根本不执行；WS：`connected` 为 false 时不建真实连接 | ✅ **天然满足 R9**（源码 + 实测双证） |
| **R4.1 尽可能多地拦截各种途径** | `fetch` / `XMLHttpRequest` / `WebSocket` 三途径 | 🟡 覆盖了本项目最关键的三种；**`EventSource`、`navigator.sendBeacon`、`<img>/<script>/<form>` 不在内**；**Worker 内的三种 API 也不在内**（它只 patch 自己所在的全局） |
| **R4.1 各种来源：每个标签页、MAIN WORLD** | **vista 完全没有这一层** | ❌ **空白**，必须由宿主用 MV3 注入补齐——但**本次证明这条路可行**（§2.7 + §5.2 的真实用例） |
| **R5 内置 AriaNg UI 不得走特殊通道** | vista 在"它被加载的那个世界"里工作；扩展页里直接 `new Vista([...]).intercept()` 即可 | 🟡 可支撑 R5：内置 UI 与普通页面可共用**同一份转发器代码**；但**每个世界要各装一次**，不能靠后台统一拦 |
| **Q-D3 WebSocket 第一版就实现，允许"轮询近似推送"** | `interceptWebSocket` mock 模式：不调 `next()` → 不建真连接；`onClientMessage` 收客户端帧，`context.sendToClient(aria2 通知)` 推给页面 | ✅ **这就是 Q-D3 想要的形状**，且【实测】双向通；比轮询更直接（在页面内注入事件，不占端口） |
| **Q-B2 三段式错误 / Q-B4 请求上下文** | `context.type`（`'fetch'\|'xhr'\|'websocket'`）+ `HTTPException` → 响应/错误映射 | 🟡 结构可参考，但 vista 的错误模型是 HTTP 状态码导向（抄自 Hono），aria2 要的是 `{"code":N,"message":…}` + HTTP 200 或 JSON-RPC 协议级错误 → **需要改造** |
| **Q-B3 伪装数据自洽 / R10 结果兑现** | ⚠️ **这里 vista 帮不上忙，反而示范了坑**：它伪造的响应在 `response`/响应头/`responseType='json'` 上不兑现（§2.6）。按 R10 的判据（**最终结果是否兑现**），这属于"看似成功、实际拿不到期待结果" | ❌ **不可照抄实现**；其缺口清单正好是 R10 验收表的素材 |
| **Q-D2 拦截盲区清单** | vista 的边界直接贡献素材：Worker 内、非 JS API 途径、替换时机之前的请求、`EventSource`/`sendBeacon` | 🟡 有贡献 |
| **Q-D5 状态持久化** | 无关 | ⚪ 无交集 |

**一句话**：vista 精准覆盖了本项目第一层里"**引擎内部**"的那一半（多途径拦截 + 就地短路 + WS 通道），**完全不覆盖**另一半（把代码送进任意第三方页面的 MAIN world）；而且它的 XHR 伪造实现**达不到本项目 R10 的验收线**。

---

## 4 能否借鉴（逐条 · 用在哪一层 · 源码依据）

| # | 借鉴点 | 用在哪一层 | 依据 / 本次核实 |
|---|---|---|---|
| 1 | **洋葱中间件模型**（16 行 compose） | 第一层·转发器 | [context.ts#L9-L15](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/context.ts#L9-L15) |
| 2 | **"真实请求＝链尾中间件"** ⇒ 短路与放行共用一条路径，R9 的"不出网"成为结构性保证 | 第一层·转发器 | fetch [L38-L43](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L38-L43)、xhr [L314-L317](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L314-L317) |
| 3 | **fetch/XHR 归一为同一上下文 `{type, req, res}`** | 转发器 ↔ Mock 层接口 | [fetch.ts#L5-L16](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L5-L16)、[xhr.ts#L308-L312](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L308-L312)；`type` 正好承载 Q-B4 的"请求上下文"维度 |
| 4 | **WebSocket 上下文协议** `{url, protocols, sendToClient, sendToServer, onClientMessage, onServerMessage, onOpen, onClose}` | 第一层·WS 通道 | [ws.ts#L12-L37](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L12-L37)；【实测】端到端可用 |
| 5 | **"不调 next() ＝ mock"作为 WS 短路开关** | 第一层·WS 通道 | [ws.ts#L182-L189](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L182-L189) |
| 6 | **`replaceWith` / `preventDefault` 的可改写事件对象** | 第一层·WS 通道 | [ws.ts#L222-L266](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L222-L266) |
| 7 | **拦截器 ＝ `(middlewares) => () => void`（返回卸载函数）** | 第一层·装载层 | [types.ts#L11-L13](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/types.ts#L11-L13)、[vista.ts#L19-L28](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/vista.ts#L19-L28)；【实测】`destroy()` 能精确还原三个全局 |
| 8 | **XHR"记录/发送分离"的顺序技巧**（`open()` 不碰原生） | 第一层·转发器（若自写 XHR 拦截） | [xhr.ts#L110-L136](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L110-L136) |
| 9 | **"真对象当属性载体 + `Object.defineProperties` + getter 委托"绕过只读属性** | 第二层·Mock 的响应落地 | [xhr.ts#L9-L73](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L9-L73)、[L214-L247](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L214-L247)。⚠️ **但必须把委托补全**（`response`/`getAllResponseHeaders`/`getResponseHeader` 也要委托），否则就是 §2.6 的坑 |
| 10 | **`super.*` 读上游、防下游改写**；`status 0` 走 error 而不崩在 `new Response(..., {status:0})` | 第一层·转发器（多扩展共存） | [xhr.ts#L268-L283](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L268-L283)、[L451-L470](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L451-L470) |
| 11 | **`getGlobalThis()` / `unsafeWindow` 探测** | 第一层·装载层 | [fetch.ts#L18-L25](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L18-L25)（对应 R5"只换装载方式，不换路径"；**但只解决"用哪个全局"，不解决"怎么进那个世界"**） |
| 12 | **§7 的保真缺口清单** | 第二层·Mock 的"还原度"验收 | 它是 R10 判据的现成检查表——**本次已逐条复核并修正**，见 §7 |
| 13 | **`HTTPException` + `getResponse()` 的错误出口结构** | 第二层·Mock 的错误出口 | [http-exception.ts](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/http-exception.ts)；可改造成 Q-B2 的三段式 |
| 14 | **发布的 IIFE 单文件 + `window.Vista`** | 第一层·装载层 | [cdn.ts](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/cdn.ts)；5.5 KB gzip、无 `eval`、无 `import`（**它不是 ES module，虽然后缀是 `.mjs`**），适合作为 MAIN world 注入载荷 |
| 15 | **作者踩过的坑：需要 SW 的方案在 Content Script 里不可用** | 架构决策依据 | 博客原文（本次取到原文）；直接支持我们"不走 SW 拦截"的路线 |
| 16 | **中间件里读请求体的正确姿势：先 `c.req.clone()`** | 第一层·转发器 | 【实测】不 clone 就读：透传时抛 `TypeError: … Cannot construct a Request with a Request object that has already been used`；用 `clone()` 则透传正常 |
| 17 | **真实 MV3 集成范式**（本项目的装载层可直接照抄的形态） | 第一层·装载层 | `mass-block-twitter`：`defineContentScript({matches, allFrames:true, runAt:'document_start', world:'MAIN'})` + `new Vista([interceptFetch, interceptXHR]).use(...).intercept()`（WXT 构建，`manifestVersion: 3`） |

**明确不建议照搬的**：
- vista 的 **XHR 伪造实现**（`response`/响应头/`responseType='json'` 不兑现，§2.6）；
- **WebSocket 用 `EventTarget` 子类**的做法（指纹泄露严重，§7 W1/W6/N6）；
- **用 `HTTPException` 表达一切错误**（与 aria2 错误模型不匹配）；
- **`#private` 字段**（与任何 Proxy 包装型库不兼容，且这是 MSW 不兼容的根因）。

---

## 5 能否直接使用（MV3 扩展里拦任意第三方页面）

### 5.1 明确结论

| 问法 | 结论 |
|---|---|
| 能否作为依赖放进 MV3 扩展？ | **能。** 零依赖、纯 ESM、`sideEffects:false`、无 `eval`/`new Function`、无扩展 API、无 SW 依赖、5.5 KB gzip ⇒ 打包进 MV3 没有机制性障碍。【实测】本项目的 MV3 实验就是直接把它的 IIFE 放进 `content_scripts` 跑通的 |
| 能否用它拦**任意第三方页面**的请求？ | **有条件能。** vista 只 patch **它自己被加载的那个 JS 世界**；要拦页面自身的 `fetch/XHR/WebSocket`，必须由宿主把它注入页面的 MAIN world。**本次已实测该路线在严格页面 CSP 下成立**（§2.7），且**已有 3 个真实 MV3 扩展这么做**（§5.2） |
| **原件点名的那个空缺：vista 没有注入能力、没有 manifest？** | ✅ **在完整源码里再次确认成立**。仓库 24 个文件里没有 `manifest.json`、没有任何 background/content/inject/service-worker 文件；`grep -rniE 'serviceworker\|manifest\.json\|content_script\|injectScript\|GM_'` 在 `src`/README/构建配置/package.json 上零命中。代码里**唯一**的模块级副作用是 `src/cdn.ts:4 window.Vista = Vista`。⇒ **装载层 100% 是宿主的责任** |
| 能否开箱即用（不写注入层）？ | **不能。** README 的 "Supports browser extension … environments" 只意味着"能在扩展环境里跑"，不等于"能拦页面"；它以 `unsafeWindow` 覆盖了**油猴**，**没有覆盖扩展 Content Script 的隔离世界**（【实测】ISOLATED 对照组：页面 fetch/XHR/WS 全是原生） |

### 5.2 "任意第三方页面"这件事，本次拿到了硬证据

原件说"无法确认有 MV3 生产用例"（其 §7 第 4 条）。**本次确认存在，且不止一个**：

| 项目 | 证据（本次亲自 `curl` raw 核实） |
|---|---|
| `rxliuli/mass-block-twitter`（78★，已上架 Chrome/Firefox/Edge 商店） | `packages/plugin/wxt.config.ts:8` → `manifestVersion: 3`；`packages/plugin/package.json:50` → `"@rxliuli/vista": "^0.4.9"`；`packages/plugin/src/entrypoints/inject.content.ts:362-366` → `defineContentScript({ matches:['https://x.com/**','https://mobile.x.com/**'], allFrames:true, runAt:'document_start', world:'MAIN'` ），`:369` → `new Vista([interceptFetch, interceptXHR])` |
| `rxliuli/clean-twitter`（18★，已上架 AMO） | `entrypoints/filter.content.ts:7-10` → `matches:['*://x.com/*'], runAt:'document_start', world:'MAIN'`；`:14` → `new Vista([interceptFetch, interceptXHR])`；`wxt.config.ts:28` → `manifestVersion: 3` |
| `rxliuli/httap`（0★） | `lib/rules.ts:93-106` 用 **`browser.scripting.registerContentScripts`** 注册 `{js:['/hook.js'], runAt:'document_start', world:'MAIN'}`；`entrypoints/hook.ts` 导入 `vista` 的 `Vista, interceptFetch, interceptXHR, interceptWebSocket` |
| `nextcloud/end_to_end_encryption`（321★） | `package.json:51` → `"@rxliuli/vista": "^0.5.3"`（非扩展，属真实生产应用） |

⇒ 这三条路径（**manifest 静态声明 MAIN world** / **`scripting.registerContentScripts` 动态注册**）都已有真实代码在用。**加上本次 §2.7 的受控实验**，"vista 能否用于 MV3 拦第三方页面"这个问题**已经可以判为"能，且已被实践验证"**。

### 5.3 前置条件、代价与限制

**① 注入层要自己写**：`world:"MAIN"` 的静态声明（manifest）或 `scripting` 注册（Chrome 95+/102+）；时机用 `document_start`。

**② 页面 CSP：本次实测结论与原件不同**
- Chrome 文档原文仍是 *"When a content script is injected into the main world, the CSP of the page applies."*（[Content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts)，CSP 小节内的**普通段落**，不是 Warning/Note）。
- 但**实测**：CSP `default-src 'self'; script-src 'self'` 的页面上，MAIN world 的 `content_scripts` 文件注入**照常执行**、页面全局**照常被改写**、伪造响应照常到达页面代码；同时该页面的**内联脚本确实被拦掉**（证明 CSP 生效）。
- 准确表述：**CSP 约束的是注入脚本"去做什么"（`eval`、内联、加载远程脚本），不是"能不能注入、能不能改全局"**。vista 不含 `eval`/`new Function`，因此天然合规。
- ⚠️ 未覆盖：`unsafe-eval` 类需求、Trusted Types、以及**真实 Chrome 稳定版 / Web Store 审核策略**。

**③ 替换时机窗口**：页面若在替换前已捕获原生引用（更早的扩展、更早的内联脚本、被缓存模块），替换对它无效。【实测】`intercept()` 之前捕获的构造器，其 `instanceof` 对新实例为 false。

**④ 盲区**：
- **Worker**：`fetch`/`XHR`/`WebSocket` 在 Worker 里是**独立全局**；`chrome.scripting` 的 `InjectionTarget` 只有 `tabId/frameIds/documentIds/allFrames`，**没有任何 Worker 目标**（官方 API 面穷举，`worker` 在该页 0 次出现）⇒ **Worker 内的请求拦不到**。
- `EventSource`、`navigator.sendBeacon`、`<img>/<script>/<form>` 等非 JS API 途径不在 vista 覆盖内。
- `chrome://`、其它扩展页、PDF viewer、`view-source:` 等本项目既有盲区不受 vista 影响。
- **同步 XHR 无法伪造**（【实测】mock 模式下 `open(...,false)` + `send()`：`status 0 / readyState 0 / responseText ""`，且静默无错；因为中间件链是异步的，无法在 `send()` 返回前产出响应）。

**⑤ 保真代价（直接决定 R10 验收线）**：见 §7。最重要的一条是 §2.6——**伪造响应目前只有 `responseText` 是真的**。对"只看 JSON-RPC 结果"的 AriaNg 是否致命，取决于它读 `responseText` 还是 `response`（**未验证**，见 §9）。

**⑥ 共存代价**：vista 是"整体替换全局"式拦截；`#private` 字段导致**朴素 `Proxy` 包装即抛错**（【实测】`TypeError: Cannot write private member #method to an object whose class did not declare it`），这正是 issue #5（MSW 不兼容）的根因，修复 PR #8 被**提交者本人关闭、从未合并** ⇒ 现状不会改变。

**⑦ 成熟度代价**：WebSocket 拦截器源码标 `/** @beta */`；**CI 不跑测试**（本次核实两个 workflow 只有 `pnpm install` / `pnpm build` / `pnpm publish`，**无 `pnpm test`**）。

**⑧ 可控性代价**：MIT，可自由 fork/vendor。**若采用，建议 vendor（复制源码进本仓库）而非依赖 npm**：代码量小（12 个源文件 1,336 行，含 dev 用的 `setup.ts` 112 行）、我们要大改错误模型与 XHR 伪造，还要修 `#private` 兼容问题。

### 5.4 建议的使用形态（供详细设计参考）

```js
// MAIN world（由扩展注入，vista 自身不管注入）
new Vista([interceptFetch, interceptXHR, interceptWebSocket])
  .use(async (c, next) => {
    if (c.type === 'websocket') {
      if (!isTargetWs(c.url)) return next()
      // 不调用 next() ⇒ 不建真连接
      c.onClientMessage((ev) => { /* 解析 JSON-RPC，异步产出结果 */ })
      registry.set(c.url, c)                     // 之后用 c.sendToClient(aria2 通知) 推送
      return
    }
    if (!isTargetUrl(c.req.url)) return next()
    const req = c.req.clone()                    // 必须先 clone 再读 body
    c.res = await mockAria2Rpc(req)              // 就地伪造 ⇒ 不出网
  })
  .intercept()
```

⚠️ **落地时必须补的修补**（否则踩 §2.6 的坑）：在自定义 XHR 拦截里，把 `response` / `getAllResponseHeaders` / `getResponseHeader` **一并委托到伪造载体**；并保持 `readyState` 序列、事件顺序与原生一致。

---

## 6 许可证、维护状态、成熟度、文档完善度

### 6.1 许可证

| 项 | 值 |
|---|---|
| 许可证 | **MIT**（`LICENSE` 前两行：`MIT License` / `Copyright (c) 2024 rxliuli`；`package.json` `"license": "MIT"`） |
| 结论 | 可商用、可修改、可闭源分发，只需保留版权与许可声明 |

### 6.2 维护状态

| 指标 | 值 | 依据 |
|---|---|---|
| 最近一次提交 | 2026-08-02（HEAD `55bba2f`，subject `0.5.3`） | 完整克隆 `git log -1` |
| 最近一次 npm 发布 | 2026-08-02T04:58:54Z（`0.5.3` = latest） | npm registry `time` |
| 首次发布 | 2025-01-06T11:54:34Z（`0.1.0`），共 **29 个版本** | npm registry |
| 提交总量 / 作者 | **87** 次提交，3 位作者（rxliuli 80 / susnux 4 / Ocyss 3） | GitHub API（与完整克隆的 `rev-list --count` 一致） |
| 活跃度 | 2026-02:9、03:2、04:3、05:0、06:3、07:0、08:2、09:0 ⇒ **2026-08-02 之后无提交（截至调研日约 2 个月静默）** | GitHub API `/commits` |
| 维护者 | **1 人**（npm `maintainers = [rxliuli]`） | npm registry |
| CI | `build-and-release.yml`（push main 且 `package.json` 变更 → `pnpm install` / `pnpm build` / `pnpm publish`）与 `claude.yml`（`@claude` 触发的 Anthropic Claude Code Action） | 逐字读完两个 workflow 文件 |
| ⚠️ **CI 不跑测试** | 两个 workflow 里**没有 `pnpm test`**（本次亲自 grep `run:` 只有 4 条，全在上表） | 同上 |
| Tag / Release | tag 最大 **`v0.5.2`**（**`v0.5.3` 未打 tag**）；**Releases 为空**；milestones 为空 | API `/tags`（24）、`/releases`（`[]`） |
| 发布供应链 | 有 OIDC + npm provenance/SLSA 证明（见 §10.3） | registry attestations |
| 社区健康度 | `health_percentage: 42`；无 CoC、无 CONTRIBUTING、无 issue/PR 模板 | GitHub API `/community/profile` |

### 6.3 社区规模

| 指标 | 值 |
|---|---|
| Star / Fork / Watcher | **27 / 3 / 1**（GitHub API 实测；原件只拿到 star） |
| Issue | **4 条，全部已关闭**：#1（CDN 单文件构建请求，已实现）、#4（中间件设置的 header 未生效，已修）、#5（**与 msw 不兼容**，`not_planned` 关闭）、#11（**如何在 React Chrome 扩展里用**，作者只回了一个博客链接） |
| PR | **7 条**：#2/#3/#6/#7/#9/#10 已合并；**#8（去掉 `#private` 以兼容 MSW）被提交者 susnux 本人关闭，从未合并** |
| 外部贡献者 | 2 人（Ocyss、susnux） |
| npm 下载量 | 最近 30 天 **1,098**；最近 7 天 **422**；最近 1 天 **44** |
| 结论 | **小众但确实在被使用**，且有一个 321★ 的真实项目依赖；社区极小，**不能指望上游响应定制需求** |

### 6.4 成熟度

| 维度 | 评价 |
|---|---|
| fetch 拦截 | 成熟。API 简单、README 主推、多版本迭代（【实测】伪造响应正确路径最快 1 ms） |
| XHR 拦截 | **中等偏弱**：功能面广（SSE、Firefox body、loadend、uBOL 共存都修过），但**伪造路径的可见性有硬伤**（§2.6），与 MSW/Proxy 不兼容且**已被放弃修复** |
| WebSocket 拦截 | **不成熟**：源码 `/** @beta */`；由 `79d9045 feat: add WebSocket interceptor (beta)` 引入、随 0.5.0（npm 2026-03-23）首次发布；有覆盖主要场景的测试，但无保真度测试 |
| 测试 | 5 个测试文件共 **1,310 行** vitest（browser mode + playwright），覆盖 fetch/xhr/ws 主要路径；**但 CI 不执行** |
| 代码量 | 12 个源文件 **1,336 行**（含 dev 用的 `setup.ts` 112 行）；仓库 TS 合计 2,714 行 |
| 版本语义 | 0.x（`0.5.x`）；**无 CHANGELOG**；npm 版本与 git tag 已漂移 |

### 6.5 文档完善度

| 项 | 情况 |
|---|---|
| README | **303 行**，结构完整（特性、npm/CDN/油猴三种安装、8 个示例、API Reference、FAQ、致谢、许可） |
| ⚠️ **MV3 / MAIN world / CSP 零覆盖** | 本次实测 grep：`manifest` / `mv3` / `main world` / `content script` / `csp` 在 README 中命中数 **0**；`extension` 仅 1 次（第 15 行的特性 bullet） |
| 类型/注释 | 源码带 JSDoc；WS 相关类型全部标 `@beta` |
| 独立文档站 / CHANGELOG | **无**。仓库根目录只有 README 一个 md；无 `docs/`（`.gitignore` 第 6 行忽略 `docs/`，且 `git log --all -- 'docs/*'` 证明该路径**从未被提交**） |
| 扩展/MV3 专项文档 | **无**。issue #11 是唯一的扩展问答，答案是外链博客，而那篇博客**也不讲 MV3/MAIN world/CSP** |
| 示例仓库 | **无** `examples/`（`git log --all --diff-filter=A -- 'examples/*'` 为空，从来没有过），只有测试 |
| 仓库 homepage | `https://deepwiki.com/rxliuli/vista`——**自动生成的陈旧快照**（"Last updated: 27 April 2025"，只读了 README/package.json，从未读 `src/`），且其中 extension/userscript/MV3/CSP 关键词命中数为 0 |

---

## 7 保真缺口复核（原件 §2.7）

> **先更正一个数字**：原件 §2.7 表里是 **14 条**（W1–W6、X1–X7、F1），不是 15 条。本节逐条复核，并给出**本次新增的 N 条**。
> 判定口径：**成立**（源码/实测支持）｜**有误**（事实错误）｜**过度解读**（现象存在但结论超出证据）。

| # | 原件结论 | 本次判定 | 依据（源码位置 / 【实测】结果） |
|---|---|---|---|
| **W1** | `CustomWebSocket extends EventTarget`；替换前捕获的原生构造器 `instanceof` 为 false | ✅ **成立** | [ws.ts#L46](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L46)、[#L295](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L295)；【实测】`x instanceof WebSocket`→true，替换前的引用→false |
| **W2** | mock 模式不解析 URL；规范对非法 scheme/fragment 抛 `SyntaxError`，而这里只 `url.toString()` | 🟡 **部分有误** | 前半**成立**：[ws.ts#L124](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L124) `this.#url = url.toString()`。【实测】vista：`'not a url'`→`"not a url"`、`'/relative'`→`"/relative"`、`'http://example.com/x'`→原样、带 fragment→原样、**全部不抛**。**后半有误**：原生 `http://example.com/x` **不抛**而是改写成 `ws://example.com/x`（`https`→`wss`，WHATWG HTML 的 scheme 重写步骤）；原生 `'not a url'` 也**不抛**（相对 URL 会按文档 base 解析成绝对 URL）。**真正抛 `SyntaxError` 的只有 fragment 与无法解析的 URL**。【实测】原生：fragment→`SyntaxError: …The URL contains a fragment identifier` |
| **W3** | mock 模式不校验 `close(code, reason)` | ✅ **成立**（并发现更严重的连带问题） | [ws.ts#L205-L218](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L205-L218)；【实测】mock：`close(1001)`/`close(1005)`/`close(1000, 200 字节)` **全部不抛**；原生分别抛 `InvalidAccessError`/`InvalidAccessError`/`SyntaxError`。【实测】**新增**：真实连接路径下 vista **先把 `#readyState` 置 2 再委托给原生**，于是一次抛错的 `close()` 会把包装对象**永久卡在 CLOSING**（`rsAfterBadClose: 2`），后续 `close()` 因 `if (this.#readyState >= 2) return` 直接返回、再也到不了原生（原生对照组 `rsAfterBadClose: 0`） |
| **W4** | mock 模式 `protocol`/`extensions` 恒 `''`、`bufferedAmount` 恒 `0` | ✅ **成立**（且比原件更强） | [ws.ts#L58-L59](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L58-L59)、[#L80-L95](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L80-L95)、[#L159-L160](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L159-L160)。**三个 getter 都是只读**（仅 `binaryType` 有 setter），所以**中间件也无法设置**；`context.protocols` 只喂给原生构造器，不影响公开的 `protocol`。【实测】mock 传 `['aria2','jsonrpc']` 后 `protocol` 仍为 `''` |
| **W5** | mock 的 `open` 在链 resolve 之后的微任务派发，异步中间件会拉长延迟 | ✅ **成立** | [ws.ts#L182-L189](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L182-L189)；【实测】构造后同步 `readyState===0`，下一 tick 才 1 |
| **W6** | 未设 `Symbol.toStringTag`，`Object.prototype.toString` 结果不同（**原件标注为推断、未实测**） | ✅ **成立（本次实测坐实）** | `grep -rn toStringTag` 全仓库 **零命中**；【实测】vista WS → `[object EventTarget]`，原生 → `[object WebSocket]`。**补充**：**XHR 侧没有这个问题**——`CustomXHR extends XMLHttpRequest` 会继承接口原型上的 `Symbol.toStringTag`，【实测】`[object XMLHttpRequest]`。所以 W6 是 **WS 专属**缺口 |
| **X1** | `readyState` 直接跳到 4（流式为 3），无 1/2/3 过程 | 🟡 **过度解读（范围写大了）** | **mock 路径成立**：[xhr.ts#L51-L53](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L51-L53)；【实测】mock：`open()` 后 **0**（原生 1）→ 完成后 4，无 2/3。**透传路径不成立**：【实测】`after-open-rs0, onrs2, addrs2, onrs3, addrs3, onload, addload, onloadend, onrs4, addrs4`——**2/3 会转发**。**新增**：透传路径下 **rs1 永不派发**（原生监听器挂在 `super.open` 之后，[xhr.ts#L422](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L422) vs [#L477](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L477)），且 **`open()` 后 `readyState` 恒为 0**（原生 1），**两条路径都一样** |
| **X2** | `readystatechange` 只在最后与 `load`/`loadend` 一起补发一次 | ✅ **成立**（并补充顺序错误） | [xhr.ts#L397-L405](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L397-L405)；【实测】mock 顺序 `load → loadend → readystatechange`，**与原生 `readystatechange → load → loadend` 相反**；透传路径把 DONE 的 rs 抑制后也在最后补发 |
| **X3** | `getAllResponseHeaders()` 输出小写名、`\r\n` 连接、**无结尾 `\r\n`** | ❌ **有误（结论反了）** | 那段代码（[xhr.ts#L60-L69](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L60-L69)）确实存在，但它被 `Object.defineProperties` 定义在 `responseToXHR()` 内部那个**临时 XHR**（[xhr.ts#L13](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L13)）上，而 `CustomXHR` **没有**把 `getAllResponseHeaders`/`getResponseHeader` 委托过去。【实测】页面在 mock 路径拿到的是 **`""` 和 `null`**；在"透传后改写"路径拿到的是**真实网络响应头**（含 `X-Modified…` 缺失）。另外原生 Chrome 的 header 名**本来就是小写**，所以"小写"根本不构成差异；真正的差异是**原生结尾有 `\r\n`** |
| **X4** | `responseType:'document'` 落到 text 分支，不产生 Document | ✅ **成立**（实际更糟） | [xhr.ts#L35-L39](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L35-L39)；【实测】mock + `responseType='document'`：`xhr.response` 为 **`null`**、读 `responseText` 抛 `InvalidStateError` ⇒ **算出来的 text 根本取不到** |
| **X5** | 没有 `upload` / `timeout` / `ontimeout` / `withCredentials` 处理；`abort()` 未覆盖；同步 XHR 语义被吞 | 🟡 **措辞有误**（"没有成员"≠"没有覆盖"） | 这些成员**都继承自原生 XHR**（`xhr.ts#L95 extends`），【实测】`upload`=`object`、`timeout`=`number`、`withCredentials`=`boolean`、`abort`=`function`。准确表述：**未覆盖/未合成**——透传路径上它们由原生生效（`super.open/super.send`），**mock 路径上完全惰性**（无 upload/timeout 事件）。【实测】mock：只收到 1 个 `progress`，`upload-progress`/`upload-load` **不触发**（原生三者都有）。**同步 XHR**：【实测】mock 路径 `open(...,false)`+`send()` → `status 0 / readyState 0 / responseText ""`（静默失败）；透传路径"能用"但因为链尾 `super.send()` 同步完成而侥幸。【实测】**`abort()` 在透传路径会让 `send()` 返回的 Promise 永不 settle**（只收到 `abort`，无 `loadend`；原生有 `abort`+`loadend`） |
| **X6** | `send()` 是 `async`，返回 Promise（原生返回 `undefined`） | ✅ **成立** | [xhr.ts#L297](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L297)；【实测】vista `[object Promise]` / 原生 `[object Undefined]` |
| **X7** | 使用 `#private` 字段，任何用 `Proxy` 包裹本类实例的库都会在 setter 上抛错；issue #5 报告 MSW；修复 PR #8 被 close 未合并 | ✅ **成立** | `#` 成员仍在（`xhr.ts` 18 个、`ws.ts` 20 个）；【实测】`new Proxy(xhr,{set})` → `TypeError: Cannot write private member #method to an object whose class did not declare it`。issue #5 状态 `not_planned`；**PR #8 是提交者本人关闭的**（评论原文："@rxliuli somehow this breaks Vista. So you are right, its better to use browser mode!"）⇒ 不会修 |
| **F1** | fetch 用普通赋值替换；未保留 `name`/属性、无写保护；**`window.fetch` 会变成自有属性** | 🟡 **部分有误** | 赋值/卸载**成立**（[fetch.ts#L30-L31](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L30-L31)、[#L53-L55](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L53-L55)）；**"变成自有属性"错误**——【实测】原生 `window.fetch` **本来就是自有属性**（Web IDL 全局接口成员），描述符 `{writable:true,enumerable:true,configurable:true}` 替换前后**完全一致**。真正丢失的是 `name`（`'fetch'`→`''`）、`length`（`1`→`2`）与 `toString`（原生码→`async (input, init) => {…`），以及确实没有写保护 |

### 7.1 本次新增的缺口（原件未列）

| # | 缺口 | 依据 |
|---|---|---|
| **N1** | **伪造响应只有 `responseText` 可兑现**：`xhr.response` 返回原生值（mock 下为 `""`/`null`），`getAllResponseHeaders()`/`getResponseHeader()` 返回空，`responseType='json'` 时 `response` 为 `null` | 【实测】§2.6；源码 [xhr.ts#L214-L247](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L214-L247) 只委托 6 个属性 |
| **N2** | **XHR 事件顺序反了**：`load → loadend → readystatechange`（原生 `readystatechange → load → loadend`） | 【实测】+ [xhr.ts#L397](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L397) |
| **N3** | **`open()` 之后 `readyState` 仍是 0**（原生为 1），两条路径都如此 | 【实测】`after-open-rs0` |
| **N4** | **透传路径下 rs1 永不派发** | 【实测】原生序列含 `onrs1/addrs1`，vista 无 |
| **N5** | **伪造响应的 `Response` 元信息丢失**：fetch 侧 `res.url === ""`、`res.type === "default"`（原生 `basic`）；XHR 侧 `responseURL` 为 `""` | 【实测】 |
| **N6** | **构造器指纹严重泄露**：`WebSocket.name === "CustomWebSocket"`、`XMLHttpRequest.name === "CustomXHR"`，且 **`String(WebSocket)` 直接吐出整个类源码**（`"class CustomWebSocket extends EventTarget {\n static CONNECTING = 0;…"`），原生为 `"function WebSocket() { [native code] }"` | 【实测】 |
| **N7** | **WS 实例带可枚举自有属性**：`Object.keys(ws)` → `["CONNECTING","OPEN","CLOSING","CLOSED"]`（原生 `[]`），因为它们是 `readonly` 类字段 | 【实测】 |
| **N8** | **WS 真实连接失败会被静默吞掉**：链尾中间件里 `new OriginalWebSocket(...)` 抛错 → 被 `.catch(() => {})` 吞掉，页面既不抛 `SyntaxError` 也收不到 `error`，`readyState` 永远停在 0 | [ws.ts#L190-L192](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L190-L192)；【实测】真实路径传非法 URL 不抛 |
| **N9** | **中间件读请求体不 clone 会炸掉透传**：`await c.req.text()` 后 `next()` ⇒ `TypeError: … a Request object that has already been used` | 【实测】 |
| **N10** | **错误路径不派发 `readystatechange`/`loadend`**（只有 `error`），与原生"任何结束都伴随 loadend"不符 | [xhr.ts#L346-L353](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L346-L353) |
| **N11** | **流式判定要求 `Content-Type` 精确相等**（`text/event-stream` / `application/octet-stream`），带 `; charset=utf-8` 就不走流式分支 | [xhr.ts#L18-L21](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L18-L21) |
| **N12** | **`HTTPException` 未从根入口导出**，却出现在公开类型签名里 | 运行时命名空间实测 + `dist/index.d.ts` |

---

## 8 与原件 vista.md 的差异

### 8.1 被**证实**的结论（独立复核后仍成立）

| 原件结论 | 本次复核方式 |
|---|---|
| 是什么 / 中间件模型 / "真实请求＝链尾中间件" / 不调 `next()` 即不出网 | 完整源码逐行 + **运行时实测**（fetch 1 ms 返回、XHR 不打网络、WS 不建连接） |
| 无 SW 依赖、无扩展 API、无 `eval`/`new Function`、不依赖构建插件、纯运行时 | 全量 grep（含测试目录）亲自执行，均零命中 |
| **没有注入能力、没有 manifest**（原件 §5.1 的核心判断） | ✅ **完整源码再次确认**：24 个文件、无 manifest/background/content/inject/sw；唯一模块级副作用是 `cdn.ts:4` |
| MIT、单人维护、CI 不跑测试、tag 只到 `v0.5.2`、无 Release | 完整克隆 + 逐字读 workflow + API |
| WS 拦截器标 `@beta`、0.5.0 才引入 | `git log --follow src/interceptors/ws.ts` → `79d9045 feat: add WebSocket interceptor (beta)` |
| issue #5 未修、PR #8 未合并 | API 全量：PR #8 `merged_at: null`，**由提交者本人关闭** |
| §2.7 中 **W1/W3/W4/W5/X2/X4/X6/X7 成立** | 见 §7 表（其中 W6 原件标"未实测"，本次坐实） |

### 8.2 被**修正 / 推翻**的结论

| # | 原件 | 本次 | 影响 |
|---|---|---|---|
| 1 | **Wayback 无快照**，只能用 tool.lu 机器译文 | ❌ **推翻**：两个 URL 都**有** Wayback 快照（英文 2025-07-12、中文 2025-12-07），本次用的是**作者原文**（英文 + 中文两版） | 取证等级从"机器译文"升到"原文"；同时发现**英文版 2025-05-10、中文版 2025-01-02**，且两版都**不含 WebSocket 章节、不提 MV3/MAIN world/CSP**（原件的"注意"得到原文确认并加强） |
| 2 | **X3：页面看到的 `getAllResponseHeaders()` 是小写、`\r\n` 连接、无结尾 `\r\n`** | ❌ **推翻**：那段代码在**内部临时 XHR** 上，页面在 mock 路径拿到 **`""`/`null`**；"透传后改写"路径拿到**真实网络响应头** | 直接改变"能否用 vista 伪造响应"的判断——原件据此认为 header 只是"格式差异"，实际是**拿不到** |
| 3 | **F1 子结论：`window.fetch` 会变成自有属性** | ❌ **推翻**：原生 `window.fetch` 本来就是自有属性且描述符完全一致 | 属细节纠错，但原件把它列为"露馅点"是错的；真正的露馅点是 `name`/`length`/`toString` |
| 4 | **W2：非法 scheme 抛 `SyntaxError`** | ❌ **修正**：原生 `http://`→改写为 `ws://`（`https`→`wss`）**不抛**；`'not a url'` 也**不抛**（按 base 解析）。只有 fragment 与不可解析 URL 抛 | 原件引的规范条文本身没错，但**漏了同一步骤里的 scheme 重写**，导致举错例子 |
| 5 | **X1/X2：`readyState` 跳跃 / `readystatechange` 只发一次** | 🟡 **限定范围**：这两条只在 **mock（短路）路径**成立；透传路径会转发 rs2/rs3，只抑制 DONE 并把它挪到最后 | 判断"伪装还原"时要分路径看 |
| 6 | **X5：没有 `upload`/`timeout`/`ontimeout`/`withCredentials`** | 🟡 **措辞修正**：这些成员**存在**（继承）；准确说法是"未覆盖/未合成事件"，透传路径原生生效、mock 路径惰性 | 避免误判"属性不存在"这类可被一行代码证伪的结论 |
| 7 | **W3 只说了 mock 不校验 close** | ➕ **加重**：真实路径下抛错的 `close()` 会把包装对象**永久卡在 CLOSING** | 新增可复现缺陷 |
| 8 | **"无浏览器可用，全部行为结论来自源码阅读"** | ❌ **本次推翻该限制**：装上 Chromium 148，做了 6 组实验（含 MV3 + CSP 受控实验），**§2.6/§2.7/§7 的关键判定均改为实测** | 证据等级整体提升 |
| 9 | 源码行数"共 1427 行 TS" | ⚠️ 本次实测：12 个源文件 **1,336 行**（含 dev 的 `setup.ts` 112 行），测试 1,310 行，仓库合计 2,714 行 | 数字对不上任何自然划分，属小误差 |
| 10 | `dist/setup.mjs` 是"死代码/**潜在误用坑**" | 🟡 **半修正**：确实是死重（2.6 KB / 约 4% 体积），但**不在 `exports` 也不在导入闭包内**，深导入报 `ERR_PACKAGE_PATH_NOT_EXPORTED` ⇒ **不会破坏消费者** | 定性从"潜在坑"降为"打包卫生问题" |

### 8.3 原件标"**未验证**"、本次**拿到了证据**的

| 原件 §7 未验证项 | 本次结论 |
|---|---|
| **1（阻塞性）MAIN world 注入是否被页面 CSP 阻挡** | ✅ **已实测**：严格 CSP 页面上 MAIN world 注入照常执行、页面全局照常被改写、fetch/XHR/WS 伪造全部到达页面代码；同页内联脚本被拦（CSP 生效对照）。**结论：不是阻塞项** |
| **2 `world:"MAIN"` 是否保证 `document_start` 语义** | ✅ **已实测**：注入时 `document.readyState === 'loading'`，页面脚本执行前已完成替换。**注意**：Chrome 文档**没有** MAIN-world 专属的顺序保证（只有通用 RunAt 措辞），本次是实测而非文档保证 |
| **4 作者是否真的把 vista 用于 MV3 扩展** | ✅ **已确认，且不止一个**：`mass-block-twitter`（78★，MV3 + `world:'MAIN'` + `document_start`，已上架商店）、`clean-twitter`（18★）、`httap`（`scripting.registerContentScripts` + MAIN）。并且**已确认 vista 就是从 mass-block-twitter 抽出来的**（commit `7f54368` 的 patch 亲自核实） |
| **5 `docs/ubol-compat.md` 的内容** | ✅ **已确认其不存在的原因**：`.gitignore` 第 6 行 `docs/`，且 `git log --all -- 'docs/*'` 为空 ⇒ **该文件从未进入过 git**。uBOL 相关的只有源码注释与一条回归测试 |
| **6 PR #8 为何被 close** | ✅ **拿到原话**：不是维护者关的，是**提交者 susnux 自己关的**——"@rxliuli somehow this breaks Vista. So you are right, its better to use browser mode! That works without issues." |
| **7 GitHub 精确数字（fork/watcher/contributors）** | ✅ fork **3**、watcher **1**、contributors **3**（80/4/3）、languages `{"TypeScript":76970}`、community health **42%** |
| **8 作者博客原文措辞** | ✅ 拿到**原文**（英文 + 中文两版）；原件引用的措辞基本准确，但**漏了 xhook 那句的结论**："…suggesting that it's no longer maintained." |
| **9 未做任何运行时实验** | ✅ 已补：6 组实验，覆盖 W1–W6 / X1–X7 / F1 的主要判定 + MV3/CSP |
| **10 `rxliuli/httap` 与主题的关系** | ✅ 已确认：**它是 vista 的消费者**（MV3 + React + WXT，README 自述拦截 Fetch/XHR/WebSocket 并存 IndexedDB），但 README **从不提 vista** |
| **11 `userScripts` + `USER_SCRIPT` 世界能否拦页面自身请求** | 🟡 **文档层面可判定**：官方把 `USER_SCRIPT` 描述为"specific to user scripts and is exempt from the page's CSP"，而只有 `MAIN` 被描述为"shared with the host page's JavaScript" ⇒ **USER_SCRIPT 不是页面世界，理论上拦不到页面自身的 fetch**。本次**未做实验**（保留在 §9） |

### 8.4 本次**新增**、原件没有的

1. **§2.6 的"伪造可见性"实测表**（`response`/响应头/`responseType='json'` 全部不兑现）——直接决定本项目能否借鉴其实现。
2. **§2.7 的 MV3 + CSP 三格受控实验**（含 ISOLATED 对照组、CSP 生效对照）。
3. **§1.3 的血统证据**（vista 从 mass-block-twitter 抽出，本地 tarball → npm 次日发布）。
4. **SLSA provenance 绑定 + 发布物与源码一致性证明**（原件明说"未做逐文件 diff"）。
5. **12 条新缺口（N1–N12）**，其中 N1/N2/N6 对本项目最要紧。
6. **`HTTPException` 未导出**的 API 面缺口。
7. **6 个真实依赖方**（含 nextcloud 321★），以及 libraries.io 报"0 dependents"是错的。
8. **deepwiki homepage 是陈旧自动生成快照**（只读 README，不含任何扩展用法）。
9. **`setup.mjs` 不会破坏消费者**的实测结论。
10. **`git` 完整历史**：87 提交、`feat: support node`/`support event/clipboard` 后被移除等原件浅克隆看不到的脉络。

---

## 9 未验证 · 存疑

> 严格遵守"查不到就写未验证"。以下均为本次**没有取得证据或无法证实**的项。

1. **AriaNg 具体做哪些运行期自检**（是否读 `xhr.response` 而非 `responseText`、是否检查 `responseURL`、是否用 `responseType='json'`、是否检查 `protocol`）。这直接决定 §2.6 的 N1 会不会真的暴露。**不在本任务范围**，建议交给前端兼容性调研。
2. **真实 Chrome 稳定版 / Firefox / Safari 的行为**：所有运行时实验都在 **Chromium 148.0.7778.96**（Playwright 自带构建）上做，**未覆盖**其它引擎与稳定版；MV3 实验用的是**本地未打包扩展**，未经过 Web Store 审核流程。
3. **`USER_SCRIPT` 世界能否拦页面自身请求**：文档措辞强烈暗示不能（它不是页面世界），但**本次未做实验**。
4. **完整密码学验证**：SLSA 证明的 payload 已解码并核对 sha512 与 commit，但**没有用 cosign/sigstore 客户端做完整签名链验证**（沙箱未安装）。
5. **Wayback 快照的完整性**：英文快照时间 2025-07-12、中文 2025-12-07；**作者站点线上原文仍 403**，因此无法排除"快照与当前线上版本有差异"。CDX 列表接口本次被 **429** 限流，**未能穷举全部快照**（只用了 availability API 返回的最近快照）。
6. **`mass-block-twitter` 是否曾在 Web Store 被拒/整改**：未查证。
7. **vista 在 Worker / Service Worker 内的可用性**：源码只用 `globalThis`，理论上可以被 import 进 Worker 并 patch 那个全局；但**宿主无法用 `chrome.scripting` 把代码送进 Worker**（API 无该目标），因此对本项目无实际价值。**未实测**。
8. **`trusted-types` / `unsafe-eval` 类 CSP 指令的组合影响**：本次 CSP 只测了 `default-src 'self'; script-src 'self'`。
9. **`npm` 下载量中真实用户 vs CI 的比例**：1,098/月 的数字未做归因。
10. **原件 §7 第 3 条（AriaNg 自检）与第 11 条（userScripts）仍未闭环**——见上 1、3。

---

## 10 证据清单

### 10.1 作者原文（本次经 Wayback 取得，摆脱机器译文）

| 来源 | 内容 |
|---|---|
| `http://web.archive.org/web/20250712131024id_/https://rxliuli.com/blog/intercepting-network-requests-in-chrome-extensions/` | 英文原文快照（页面标注 `2025-05-10 · 10 min read`）。摘录：`mswjs: A mocking library capable of intercepting XHR/fetch requests, but requires a service worker, which isn't possible for Chrome extension Content Scripts.` / `xhook: … its last update was two years ago, suggesting that it's no longer maintained.` / `The core approach is to override globalThis.fetch with a custom implementation that runs middlewares and calls the original fetch at an appropriate time` / `A complete fetch/XHR interceptor has been implemented and published to npm as @rxliuli/vista.` |
| `http://web.archive.org/web/20251207203712id_/https://blog.rxliuli.com/p/7ffe39eff5c64f5d90acf21518e39d63/` | 中文原文快照（`2025年1月2日`，`本文最后更新于：2025年1月15日`）。摘录：`mswjs：一个 mock 库……需要使用 service worker，而这对于 Chrome 插件的 Content Script 来说是不可能的。` |
| 线上地址 | 两者均 **HTTP 403（Cloudflare）**，与原件一致 |

### 10.2 仓库源码（`55bba2f`，SHA 固定链接）

| 位置 | 原文摘录 |
|---|---|
| [src/context.ts#L9-L15](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/context.ts#L9-L15) | 16 行 compose（洋葱模型） |
| [src/vista.ts#L19-L23](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/vista.ts#L19-L23) | `intercept() { this.cancels = this.interceptors.map((interceptor) => interceptor(this.middlewares)) }` |
| [src/types.ts#L11-L13](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/types.ts#L11-L13) | `export interface Interceptor<M …, C extends object = {}> { (middlewares: M[], config?: C): () => void }` |
| [src/interceptors/fetch.ts#L18-L25](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L18-L25) | `if (typeof unsafeWindow !== 'undefined') { return unsafeWindow } return globalThis` |
| [src/interceptors/fetch.ts#L30-L31](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L30-L31) / [#L38-L43](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L38-L43) / [#L53-L55](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/fetch.ts#L53-L55) | `const pureFetch = getGlobalThis().fetch` / `getGlobalThis().fetch = async (input, init) => {` / 链尾 `context.res = await pureFetch(c.req)` / 卸载 |
| [src/interceptors/xhr.ts#L9-L73](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L9-L73) | `const xhr = new XMLHttpRequest()` + `Object.defineProperties(xhr, {status, statusText, responseURL, readyState, response, responseType, responseText, getAllResponseHeaders, getResponseHeader})` —— **临时载体** |
| [src/interceptors/xhr.ts#L95](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L95) | `class CustomXHR extends getGlobalThis().XMLHttpRequest {` |
| [src/interceptors/xhr.ts#L214-L247](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L214-L247) | 只委托 `status/statusText/responseURL/readyState/responseText/responseType`（**无 response / 无头方法**） |
| [src/interceptors/xhr.ts#L297](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L297) | `async send(body?: …): Promise<void> {` |
| [src/interceptors/xhr.ts#L397-L405](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L397-L405) | `for (const type of ['load', 'loadend', 'readystatechange'] as const) {` |
| [src/interceptors/xhr.ts#L499-L505](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/xhr.ts#L499-L505) | `getGlobalThis().XMLHttpRequest = CustomXHR` / 卸载 |
| [src/interceptors/ws.ts#L46](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L46) / [#L124](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L124) / [#L182-L189](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L182-L189) / [#L205-L218](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L205-L218) / [#L295-L298](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/interceptors/ws.ts#L295-L298) | `class CustomWebSocket extends EventTarget {` / `this.#url = url.toString()` / mock `.then(() => { if (!connected) {…} })` / `close(code?, reason?)` 无校验 / 换全局与卸载 |
| [.gitignore](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/.gitignore) | 第 6 行 `docs/`（解释 `docs/ubol-compat.md` 为何不存在）；`git log --all -- 'docs/*'` 为空 ⇒ 从未提交 |
| [build.config.ts](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/build.config.ts) | `input: 'src/'` + `globOptions: { ignore: ['**/*.test.ts'] }` ⇒ `setup.ts` 被卷进 dist |
| [src/index.ts](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/index.ts) | 7 行 re-export（含 `./interceptors/ws`） |
| [src/cdn.ts](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/src/cdn.ts) | `window.Vista = Vista`（全仓库唯一模块级副作用） |
| [LICENSE](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/LICENSE) | `MIT License` / `Copyright (c) 2024 rxliuli` |
| [.github/workflows/build-and-release.yml](https://github.com/rxliuli/vista/blob/55bba2f1455869f74febe0c353ccc66ce11becc8/.github/workflows/build-and-release.yml) | `run:` 仅 4 条：`npm install -g npm@latest` / `pnpm install` / `pnpm build` / `pnpm publish --access public` ⇒ **无测试步骤** |

### 10.3 发布物与供应链（本次亲自执行的命令与结果）

| 指令 | 结果 |
|---|---|
| `git clone https://github.com/rxliuli/vista.git`（完整） | 87 commits；HEAD `55bba2f1455869f74febe0c353ccc66ce11becc8`（2026-08-02 11:58:10 +0700，subject `0.5.3`）；tag 24 个（最大 `v0.5.2`） |
| `npm pack @rxliuli/vista@0.5.3` | `package size: 16.1 kB`、`unpacked size: 65.9 kB`、`total files: 30`、`shasum 0e8b870df63d3febeed48e23737d5ba2b998e998`、`integrity sha512-Az9GmwzACiV0N…71A4Fxu/vK01A==` |
| `sha512sum` | `033f469b0cc00a25743512a740145088…b4d4` |
| `curl https://registry.npmjs.org/-/npm/v1/attestations/@rxliuli%2fvista@0.5.3` → base64 解码 → `jq` | `subject[0].digest.sha512` = `033f469b…b4d4`（**与本地 tarball 一致**）；`predicate.buildDefinition.externalParameters.workflow` = `{ref: refs/heads/main, repository: https://github.com/rxliuli/vista, path: .github/workflows/build-and-release.yml}`；`resolvedDependencies[0].digest.gitCommit` = **`55bba2f1455869f74febe0c353ccc66ce11becc8`**；run = `https://github.com/rxliuli/vista/actions/runs/30733277024/attempts/1` |
| `gzip -9` 实测 | `index.iife.mjs` 22,036 → **5,464**；`index.mjs` 269 → 126；`interceptors/xhr.mjs` 12,415 → 3,223；`interceptors/ws.mjs` 6,240 → 1,580；`setup.mjs` 2,618 → 1,022；ESM 入口闭包（10 文件 22,482 B）合并 gzip ≈ **5,480–5,496** |
| `head -3 dist/setup.mjs` | `import { serve } from "@hono/node-server";` / `import { createNodeWebSocket } from "@hono/node-ws";` / `import { Hono } from "hono";` |
| unpkg vs tarball | `dist/index.mjs` sha256 `d1aba1b4160b80dd2c30ab9aee85af79c7b8dee8c2e3a24eae6540b704041fb1`，**字节一致** |
| 完整重建（子代理执行，结果已核对） | 从 `55bba2f` 干净 `npm install` + `npm run build` ⇒ 27 个 dist 文件**逐字节相同（IDENTICAL: 27 / DIFFERENT: 0）** |
| `curl https://api.github.com/repos/rxliuli/vista` | `stargazers_count: 27`、`forks_count: 3`、`subscribers_count: 1`、`license.spdx_id: MIT`、`open_issues_count: 0`、`homepage: https://deepwiki.com/rxliuli/vista` |

### 10.4 真实 MV3 用例（本次亲自 `curl raw` 核实）

| 来源 | 摘录 |
|---|---|
| `raw.githubusercontent.com/rxliuli/mass-block-twitter/main/packages/plugin/wxt.config.ts` | 第 8 行 `manifestVersion: 3,`；第 25-26 行 `host_permissions: [ 'https://x.com/**', …` |
| 同上 `packages/plugin/package.json` | 第 50 行 `"@rxliuli/vista": "^0.4.9",`；第 44 行 `"wxt": "^0.19.27"` |
| 同上 `packages/plugin/src/entrypoints/inject.content.ts` | 第 362-366 行 `export default defineContentScript({ matches: ['https://x.com/**', 'https://mobile.x.com/**'], allFrames: true, runAt: 'document_start', world: 'MAIN',`；第 369 行 `new Vista([interceptFetch, interceptXHR])` |
| `raw.githubusercontent.com/rxliuli/clean-twitter/main/entrypoints/filter.content.ts` | 第 7-10 行 `defineContentScript({ matches: ['*://x.com/*'], runAt: 'document_start', world: 'MAIN',`；第 14 行 `const vista = new Vista([interceptFetch, interceptXHR])` |
| `raw.githubusercontent.com/rxliuli/clean-twitter/main/wxt.config.ts` | 第 28 行 `manifestVersion: 3,` |
| `raw.githubusercontent.com/nextcloud/end_to_end_encryption/{main,master}/package.json` | 第 51 行 `"@rxliuli/vista": "^0.5.3",`（两个分支均命中） |
| `https://github.com/rxliuli/mass-block-twitter/commit/7f54368.patch` | `From 7f5436841a9273c5bc67810551e826893f9f3d3b`、`Date: Sun, 5 Jan 2025 20:11:23 +0800`、`Subject: [PATCH] feat: udpate xhr interceptor`；diffstat：`libs/rxliuli-vista-0.1.0.tgz | Bin 0 -> 5953 bytes`、`src/lib/interceptors.ts | 241 ----`、`create mode 100644 libs/rxliuli-vista-0.1.0.tgz` |

### 10.5 GitHub issue / PR

| 来源 | 摘录 |
|---|---|
| [issue #1](https://github.com/rxliuli/vista/issues/1) | 标题 `Request: Provide a CDN-friendly single-file build for easy Tampermonkey/Greasemonkey usage`；作者回复 `Check out vite-plugin-monkey …` → CDN/`window.Vista`/`unsafeWindow` 的来源 |
| [issue #4](https://github.com/rxliuli/vista/issues/4) | 标题 `Headers set in middleware are not applied to XHR`（已修） |
| [issue #5](https://github.com/rxliuli/vista/issues/5) | 标题 `Cannot use the library together with msw`；正文 `This happens because this library uses private fields on the XHR interceptor.` / `MSW uses a Proxy above the real XHR implementation (now its the Vista). So the problem is that a proxy that access target[propertyName] = value cannot work with private fields.`；**state = closed (not planned)**，关闭者 susnux |
| [issue #11](https://github.com/rxliuli/vista/issues/11) | 标题 `How to use this in React chrome extension?`；正文 `Im developing a chrome extension using the crxjs template for react. How can I use this library to intercept the requests inside the react code?`；作者唯一回复：`ref: https://rxliuli.com/blog/intercepting-network-requests-in-chrome-extensions/` |
| [PR #8](https://github.com/rxliuli/vista/pull/8) | `fix(xhr): do not use private fields to allow compatibility with MSW` —— **`merged_at: null`，由提交者 susnux 本人于 2025-12-03T19:01:23Z 关闭**；其评论：`@rxliuli somehow this breaks Vista. So you are right, its better to use browser mode! That works without issues.` |
| [#2](https://github.com/rxliuli/vista/pull/2) [#3](https://github.com/rxliuli/vista/pull/3) [#6](https://github.com/rxliuli/vista/pull/6) [#7](https://github.com/rxliuli/vista/pull/7) [#9](https://github.com/rxliuli/vista/pull/9) [#10](https://github.com/rxliuli/vista/pull/10) | 均已合并（CDN 支持、HTTPException 构造、XHR header 保留、类型、`loadend`、Firefox body） |
| Releases / tags | `/releases` → `[]`；`/tags` → 24 个，最新 `v0.5.2`（**`v0.5.3` 无 tag**） |

### 10.6 Chrome 官方文档（本次抓取并逐字核对）

| 来源 | 摘录 |
|---|---|
| [Content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts) | `When a content script is injected into the main world, the CSP of the page applies.`（**CSP 小节内的普通段落**，非 Note/Warning） |
| 同上 | `Content scripts live in an isolated world, allowing a content script to make changes to its JavaScript environment without conflicting with the page or other extensions' content scripts.` / `…none of these (web page, content scripts, and any running extensions) can access the context and variables of the others.` |
| 同上 | `document_start` — `Scripts are injected after any files from css, but before any other DOM is constructed or any other script is run.` |
| [reference/manifest/content-scripts](https://developer.chrome.com/docs/extensions/reference/manifest/content-scripts) | `"world"` — `ISOLATED` \| `MAIN` — `Optional. The JavaScript world for a script to execute within. Defaults to "ISOLATED"… Choosing the "MAIN" world means the script will share the execution environment with the host page's JavaScript.` |
| [browser.scripting](https://developer.chrome.com/docs/extensions/reference/api/scripting) | `ExecutionWorld`（Chrome 95+）：`"ISOLATED" …` / `"MAIN" Specifies the main world of the DOM, which is the execution environment shared with the host page's JavaScript.`；`ScriptInjection.world`（Chrome 95+）/ `RegisteredContentScript.world`（Chrome 102+）；`InjectionTarget` 属性只有 `allFrames / documentIds / frameIds / tabId` ⇒ **无 Worker 目标**（该页 `worker` 出现 0 次） |
| [browser.userScripts](https://developer.chrome.com/docs/extensions/reference/api/userScripts) | `"USER_SCRIPT" Specifies the execution environment that is specific to user scripts and is exempt from the page's CSP.`；`If the Allow User Scripts toggle is not enabled, browser.userScripts is undefined.` |
| [Service worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle) | `After 30 seconds of inactivity…` / `Any global variables you set will be lost if the service worker shuts down. Instead of using global variables, save values to storage.` |
| [browser.webRequest](https://developer.chrome.com/docs/extensions/reference/api/webRequest) | `As of Manifest V3, the "webRequestBlocking" permission is no longer available for most extensions.` / `Note that the API does not intercept: Individual messages sent over an established WebSocket connection.` |
| [browser.declarativeNetRequest](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest) | `A single rule does one of the following: Block a network request. Upgrade the schema… Redirect a network request. Modify request or response headers.` ⇒ **动作枚举里没有任何"合成响应体"能力** |

### 10.7 本次运行时实验（可复现）

环境：Playwright 1.60 + **Chromium 148.0.7778.96**（`chromium-1223` + `chromium_headless_shell-1223`），本地 Node HTTP 服务；工作副本 `/tmp/vista-work/`（**未写入 `/workspace`**，未修改任何被调研仓库）。载荷为 npm 发布的 `@rxliuli/vista@0.5.3` 的 `dist/index.iife.mjs`（sha256 与 tarball 一致）。

| 实验 | 目的 | 结论摘要 |
|---|---|---|
| `exp2` | 伪造可见性 / WS mock / fetch 表面 | §2.6 全表；`send()` 返回 Promise；`[object EventTarget]`；`#private` Proxy 抛错 |
| `exp3` | mock 模式的 WS 校验、双向消息、responseType、sync XHR、upload、`clone()` | W2/W3/W4 实测坐实；mock WS 双向通；mock+sync 完全失效；不 clone 读 body 会抛 |
| `exp4` | 构造器指纹、属性枚举、透传事件序列 | `WebSocket.name==="CustomWebSocket"`、`String(WebSocket)` 泄露类源码、`Object.keys(ws)` 非空 |
| `exp5` | `responseType='json'` | mock 下 `xhr.response === null`（原生为解析后的对象） |
| `exp6` | 透传 `readyState` 序列 / 真实路径 `close()` 校验 / `abort()` | rs1 缺失、rs4 后置、close 抛错后卡 CLOSING、`abort()` 后 `send()` Promise 永不 settle |
| `exp-ext` | **MV3 + MAIN world + 严格 CSP 三格对照** | §2.7；MAIN 成功（含 CSP 页），ISOLATED 失败（对照组） |

**关于本报告的独立性**：所有外部证据（Wayback 原文、raw 源码、npm/registry/provenance、MV3 用例文件、GitHub issue/PR）均由本人直接抓取核对；4 个并行子代理（发布物供应链、保真缺口静态+浏览器复核、Chrome 文档、生态与真实用例）的结论已逐条抽样复核后才写入，其中发布物哈希/SLSA commit、MV3 用例行号、`nextcloud` 依赖行、保真缺口的关键判定均由本人**独立重跑**确认。

---

**（文档结束）本次调研未修改任何代码，未改动 `docs/concept-design/concept-design.md`，未触碰原件 `docs/research/libraries/vista.md`，仅新增本文件。**
