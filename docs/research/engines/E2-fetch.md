# E2 — fetch / XHR 取字节的能力边界

## 0 元信息

| 项 | 值 |
|---|---|
| 文档 | E2 — fetch / XHR 取字节的能力边界（浏览器技术边界测绘输入文档） |
| 对应任务 | t2 [e2]（成员 eng-fetch） |
| 版本 / 状态 | v1.0 / 首轮测绘完成 |
| 核对日期 | **2026-10-06（UTC）** —— 本文所有官方引用均于该日抓取原文（`curl` 取全文 + 逐字摘录），引文为英文原文照抄 |
| 浏览器基线 | 以 **Chrome（Manifest V3）** 为主。文档中出现的版本号一律来自引用源自身（抓取时 `chrome.offscreen` 页面已带有「Chrome now supports the standardized `browser.*` namespace (available from Chrome 148)」的站点级提示，见 E19）。Firefox / Safari 差异仅在有官方来源时提及，否则不写 |
| 范围 | 「把字节从网络取到手」这一段：请求侧可控面、各执行上下文下的 CORS / host_permissions 表现、流式读取与背压、进度推导、取消、Range 伪造多连接、MV3 生命周期对长下载的影响 |
| 不在范围 | 落盘/持久化（eng-disk）、`chrome.downloads`（eng-downloads）、`chrome.tabs` + DNR（eng-tab-dnr）、转发器拦截（fwd-*）。本文只在「交出的数据形态」接口处一句话说明下游需要什么 |
| 引用规则 | 结论 = 官方文档 / 现行标准 / Chromium 源码原文；**推断**明确标注「推断」；查不到写进 §7「未验证」，不猜 |
| 证据编号 | 文中 `【E<n>】` 指向 §8 证据清单 |

**方法说明**：为避免凭记忆断言，本文所有引文来自 2026-10-06 直接抓取的页面/规范/源码全文，再逐字摘录；引用规范时以当时页面标注的版本为准（Fetch Standard 抓取时标注 *Living Standard — Last Updated 6 October 2026*）。

---

## 1 一句话结论

**`fetch()` 完全有能力把字节从网络取到手（流式读取、Range、Abort 都可用，XHR 则在 MV3 service worker 里根本不存在）；这条途径能不能当下载引擎的「取字节层」，不取决于 fetch 本身，而取决于两个宿主选择：**

1. **CORS 分水岭** —— 只有**扩展自己的上下文**（MV3 service worker / 扩展页面 / offscreen document）在声明了 `host_permissions` 后可以不受 CORS 限制地取跨域字节；**content script（ISOLATED）即使有 `host_permissions` 也强制按「页面 origin + CORS」处理**，MAIN world 与普通页面则完全是页面自身的 CORS。这是本项目最关键的分水岭。
2. **生命周期分水岭** —— MV3 service worker 在「空闲 30 秒 / 单个请求超过 5 分钟 / fetch 响应超过 30 秒未到达」时会被 Chrome 终止；`chrome.offscreen` 文档是唯一被官方描述为「除 AUDIO_PLAYBACK 外**其它 reason 不设寿命上限**」的长期宿主。

**定位：能当主力——但要落在 offscreen document（或等价的扩展页面）里做取字节；放在 MV3 service worker 里只能当「短请求辅助」。**

**最大风险：宿主选择错误。** 在 SW 里做长下载会出现「响应头已到、body 还在流、SW 被回收」的静默失败；MV3 没有事务性恢复，已读未落盘的字节会丢，且从 JS 侧看不到「为什么失败」（CORS/网络/TLS 一律是 `TypeError`）。**次大风险是能力误判**：`Range`/多连接是否可用是**目标服务器**的属性（不是扩展的静态能力），因此它不能写进 R11/Q-B8 的静态 bool 能力集，只能在运行期探测 + 降级/报错。

---

## 2 机制

### 2.1 请求侧：可控范围（能设什么、不能设什么）

#### 2.1.1 不可设置的请求头（forbidden request-header）——准确清单

规范原文（Fetch Standard §2.2.2，E1）给出的判定是「名字命中下列之一 **或** 以 `proxy-` / `sec-` 开头（byte-lowercased 后）**或** 命中 `X-HTTP-Method*` 三个特例且值为 forbidden method（`CONNECT`/`TRACE`/`TRACK`）」：

```
`Accept-Charset` `Accept-Encoding` `Access-Control-Request-Headers`
`Access-Control-Request-Method` `Connection` `Content-Length` `Cookie` `Cookie2`
`Date` `DNT` `Expect` `Host` `Keep-Alive` `Origin` `Referer` `Set-Cookie`
`TE` `Trailer` `Transfer-Encoding` `Upgrade` `Via`
```

> "These are forbidden so the user agent remains in full control over them."【E1】

MDN 的术语页给出基本相同的清单（差异：规范多一个 `Cookie2`；MDN 额外注明 Chrome 还禁止 `Access-Control-Request-Private-Network`，以及 `Referer` 虽在规范清单里但可通过 `referrer` 选项程序化修改）【E2】。

**关键行为**：设置 forbidden 头**不会报错**，而是被**静默丢弃**——规范中 `Headers` 的 header 校验在 guard = `request` 时对该头返回 false，调用方不会得到异常【E1，§5.1 "To validate a header"】。

对本项目的后果（逐条，均为「能不能 / 代价 / 在哪能做」）：

| 头 | fetch 里能不能设 | 说明与替代 |
|---|---|---|
| `Cookie` | ❌ 禁止 | 唯一能带 cookie 的方式是让浏览器自己的 cookie jar 发（`credentials` 选项 + `host_permissions`），见 §2.2.4；要注入「jar 里没有的 cookie 字符串」必须走别的途径（DNR 改请求头 = 其它成员任务） |
| `Host` | ❌ 禁止 | 虚拟主机级测试不可行 |
| `Origin` | ❌ 禁止 | 扩展上下文请求的 Origin 头行为见 §2.2.1（content script 用页面 origin）与 §7 未验证项 4（扩展上下文**官方未写清楚**） |
| `Referer` | ❌ 作为头不可设；✅ 经 `referrer` / `referrerPolicy` 选项间接控制 | MDN 明确："the header can be programmatically modified"【E2】；但 `referrer` 只能取「同源相对/绝对 URL、空串、`about:client`」【E3】 |
| `Sec-*` | ❌ 一律禁止（前缀规则） | `Sec-Fetch-*`、`Sec-CH-*`、`Sec-Purpose` 等**无法伪造**，反爬/CDN 会看到与真实浏览器一致的（而非脚本伪造的）取值 |
| `User-Agent` | ⚠️ 不在 forbidden 清单，但 Chrome 静默丢弃 | MDN 原文："The `User-Agent` header used to be forbidden, but no longer is. However, Chrome still silently drops the header from Fetch requests (see crbug.com/571722)."【E2】 |
| `Content-Length` / `Transfer-Encoding` / `Connection` / `TE` / `Trailer` / `Upgrade` / `Keep-Alive` | ❌ 禁止 | 传输层细节由浏览器掌控 |
| `Authorization` | ✅ 可设 | 跨域时属 "CORS non-wildcard request-header name"，会触发 preflight 且 `Access-Control-Allow-Origin: *` 不适用【E1】 |
| 其它自定义头（如 `X-Aria2-*`、`X-Token`） | ✅ 可设 | 跨域时**非** CORS-safelisted → 触发 OPTIONS preflight（普通页面/content script）；扩展上下文（host_permissions 生效时）不 preflight，见 §2.2 |

**CORS-safelisted request-header**（不触发 preflight 的白名单，规范原文）【E1】：`accept`、`accept-language`、`content-language`、`content-type`（仅 `application/x-www-form-urlencoded` / `multipart/form-data` / `text/plain`）、**`range`（有条件，见 §2.6）**；且值长度 ≤ 128、所有 safelisted 头值合计 ≤ 1024 字节（超限则全部转入 unsafe 名单）。

#### 2.1.2 请求选项语义（fetch 的 RequestInit）

以下均为 MDN `RequestInit` 的官方口径【E3】：

| 选项 | 取值 | 语义要点（原文摘要） | 对下载引擎的意义 |
|---|---|---|---|
| `credentials` | `omit` / `same-origin`(默认) / `include` | "Controls whether or not the browser sends credentials with the request, as well as whether any `Set-Cookie` response headers are respected. Credentials are cookies, TLS client certificates, or authentication headers…"；`include` 时服务器还必须回 `Access-Control-Allow-Credentials` 且 ACAO 不能是 `*` | 想带目标站 cookie（含 SameSite 严格）**必须显式 `include`**，且在扩展上下文还要有 host_permissions（§2.2.4） |
| `mode` | `cors`(默认) / `same-origin` / `no-cors` / `navigate` | `no-cors` 的三条硬限制：方法仅 HEAD/GET/POST；头仅 safelisted **且 `Range` 也被禁止**；响应 opaque（headers/body 不可读、status 恒 0）。"This also applies to any headers added by service workers." | `no-cors` 对「取字节」**完全无用**（读不到 body） |
| `redirect` | `follow`(默认) / `error` / `manual` | `manual` 返回 opaque-redirect 过滤响应 | 见下 |
| `cache` | `default` / `no-store` / `reload` / `no-cache` / `force-cache` / `only-if-cached` | 规范：`only-if-cached` "…returns a network error. (Can only be used when request's mode is `same-origin`…)"【E1】 | 想绕过 HTTP 缓存重复下载要显式 `no-store`/`reload`；`only-if-cached` 交叉验证成本高 |
| `referrer` / `referrerPolicy` | 同源相对/绝对 URL / 空串 / `about:client`；策略同 Referrer-Policy | 见 2.1.1 | 只能"减少"或"同源设置"，不能任意伪装 Referer |
| `integrity` | `<algo>-<base64>`（sha256/384/512） | 浏览器校验整份资源，不匹配则 fetch 以网络错误 reject | 整文件校验可用（但无分块校验；且对 Range 分片请求的校验语义未在 MDN 说明——见 §7） |
| `keepalive` | bool（默认 false） | "the browser will not abort the associated request if the page that initiated it is unloaded before the request is complete"；**body 上限 64 KiB**；"It is also available in service workers." | 面向「页面卸载」，**不是**「SW 回收」的保活（§7 未验证） |
| `signal` | `AbortSignal` | 见 §2.5 | 取消/超时 |
| `priority` | `high`/`low`/`auto` | 同类型请求内相对优先级 | 多连接时可用于给关键分片提优先级（有限） |
| `targetAddressSpace` | `local`/`loopback`/`public` | 影响 mixed-content 处理；见 Local Network Access【E3】 | 下载 localhost/LAN 目标时相关，见 §5 F11（Chrome 142 起 LNA 权限提示，E34/E36） |
| `duplex` | 必须为 `half`（当 body 是 ReadableStream 时） | 请求体流式上传的要求 | 与下载（响应流）无关 |

**`redirect: 'manual'` 的一个硬限制**：规范定义 opaque-redirect 过滤响应为 `type = "opaqueredirect"`、`status = 0`、`header list = « »`、`body = null`【E1】。即**手动模式下拿不到 `Location` 头、也读不到响应体**，因此「自己追踪重定向链、按最终 URL 命名文件」在 fetch 里做不到精细控制；能用的是 `Response.url` / `Response.redirected`（最终结果层面的信息）。`redirect: 'error'` 则把重定向变成网络错误。

### 2.2 执行上下文差异（本项目的关键分水岭）

#### 2.2.1 官方对扩展跨域请求的裁定

Chrome 扩展官方文档（"Cross-origin network requests"，页面标注 Last updated 2012-09-18，但仍是当前文档）原文【E17】：

> "Regular web pages can use the `fetch()` or `XMLHttpRequest` APIs … but they're limited by the same origin policy. **Content scripts initiate requests on behalf of the web origin that the content script has been injected into and therefore content scripts are also subject to the same origin policy.** Extension origins aren't so limited. **A script executing in an extension service worker or foreground tab can talk to remote servers outside of its origin, as long as the extension requests host permissions.**"

> "If the extension attempts to request content from a security origin other than its own … this will be treated as a cross-origin request **unless the extension has host permissions**. **Cross-origin requests are always treated as such in content scripts, even if the extension has host permissions.**"

同一页还确认 XHR 的可用边界：

> "The `XMLHttpRequest()` API is supported in extensions **outside of the service worker**, and calling it triggers the extension service worker's fetch handler. New work should favor `fetch()` wherever possible."【E17】

Chromium 安全团队的正式文档（"Changes to Cross-Origin Requests in Chrome Extension Content Scripts"，含 2020-09-17 修订）给出机制与版本【E27】：

> "**Stage #2: Remove ability to bypass CORS from content scripts** … This change started in **Chrome 85**. The changes means that **cross-origin fetches initiated from content scripts will have an `Origin` request header with the page's origin**, and the server has a chance to approve the request with a matching `Access-Control-Allow-Origin` response header."

> "**Extension pages, such as background pages, popups, or options pages, are unaffected by this change and will continue to be allowed to bypass CORS for cross-origin requests as they do today.**"

> "content scripts will lose the ability to fetch cross-origin data from origins in their extension's permissions, and they will only be able to fetch data that the underlying page itself has access to."

MV3 迁移文档确认 SW 里没有 XHR【E22】:

> "`XMLHttpRequest()` **can't be called from a service worker, extension or otherwise.** Replace calls from your background script to `XMLHttpRequest()` with calls to global `fetch()`."

#### 2.2.2 上下文对照表（同一段 fetch 代码在六个宿主里的表现）

| 上下文 | 请求的 origin | host_permissions 是否豁免 CORS | 典型结果 | 能否跑 XHR | 页面 CSP 是否影响 |
|---|---|---|---|---|---|
| **MV3 扩展 service worker** | 扩展 origin（`chrome-extension://<id>`） | ✅ 是（声明了对应 host） | 无 host 权限 → 按跨域处理，通常被 CORS 拦 | ❌ 不存在【E22】 | 不适用（扩展自己的 CSP） |
| **扩展页面**：popup / options / side panel | 扩展 origin | ✅ 是 | 同 SW | ✅ 可用【E17】 | 扩展 CSP（`connect-src` 默认不限制，除非自定义 manifest CSP，E17 末尾） |
| **offscreen document** | 扩展 origin（是扩展页面的一种） | ✅ 是（"The extension's permissions carry over to offscreen documents"【E19】） | 同扩展页面；**但只能用 `chrome.runtime` 这一个扩展 API** | ✅ 可用（XHR 是 web 平台 API，不受"只有 runtime 一个扩展 API"的限制） | 扩展 CSP |
| **content script（ISOLATED world，默认）** | **页面 origin**（Chrome 85+） | ❌ **不豁免**（"even if the extension has host permissions"【E17】） | 跨域请求按页面身份走 CORS；服务器不回 ACAO 就失败 | ✅ 可用（普通 `window` 上下文） | ❌ 不受页面 CSP 影响（ISOLATED world 用扩展的 CSP 串，文档给出的策略串只有 `script-src`/`object-src`、**无 `connect-src`**，见下【E21】） |
| **content script（`world: "MAIN"`）** | 页面 origin（与页面共享 JS 环境） | ❌ 不豁免（等同页面脚本） | 同页面 | ✅ 可用 | ✅ **页面 CSP 生效**（"When a content script is injected into the main world, the CSP of the page applies."【E21】） |
| **普通页面** | 页面 origin | ❌ 不适用（页面无扩展特权） | 标准 CORS | ✅ 可用 | ✅ 生效 |

补充引文：
- ISOLATED world 的 CSP 是**扩展定义**的固定串：「Content scripts running in isolated worlds have the following Content Security Policy (CSP): `script-src 'self' 'wasm-unsafe-eval' 'inline-speculation-rules' chrome-extension://…/; object-src 'self';`」——该串**不含 `connect-src`**，故 content script 的 `fetch` 不受页面 `connect-src` 限制【E21】。
- `world` 枚举的官方定义：「`"ISOLATED"` Specifies the isolated world, which is the execution environment unique to this extension. `"MAIN"` Specifies the main world of the DOM, which is the execution environment shared with the host page's JavaScript.」【E26】
- offscreen 文档的权限与 API 边界：「The extension's permissions carry over to offscreen documents, but with limits on extension API access… because the `browser.runtime` API is the only extensions API supported by offscreen documents, messaging must be handled using members of that API.」【E19】

**结论（本项目的分水岭）**：想「不受 CORS 限制地取任意目标站的字节」，**必须在扩展自己的上下文里发请求**（SW / 扩展页面 / offscreen document）。content script 只能取「页面本来就能取的」字节 —— 这与 R4.1「尽可能多地拦截各种来源，包括 MAIN WORLD 注入脚本」在**拦截**层成立，但在**引擎取字节**层会出现「拦到了 RPC 请求、却下不动文件」的组合，必须写进盲区清单（§5、§6）。

#### 2.2.3 MAIN world 的定位

MAIN world 与页面共享执行环境【E26】，且页面 CSP 生效【E21】。**官方文档没有一句明确的「MAIN world 不能用扩展 API」**（§7 未验证项 5），但从「shared with the host page's JavaScript」+「页面 CSP 生效」两条已足以判定：**在 CORS 上它等同页面脚本，不能享受 host_permissions 豁免**。

#### 2.2.4 cookie 与 "same-site" 待遇（扩展上下文的隐性优势）

Chrome 官方 "Storage and cookies" 文档【E20】：

> "For cookies associated with third-party sites, such as for a third-party site loaded in a frame on an extension page, or **a request made from an extension page to a third-party origin**, cookies behave the same as the web except in two ways:
> - Third-party cookies are never blocked even in subframes if the top-level page for a given tab is a `chrome-extension://` page.
> - **Requests from an extension to a third-party are treated as same-site if the extension has host permissions for the third-party. This means `SameSite=Strict` cookies can be sent.** Note that this only applies to network requests, not access through `document.cookie` in JavaScript, and **does not apply if third-party cookies are blocked**."

> "Extension storage is shared across the extension's origin including the extension service worker, any extension pages (including popups and the side panel), and offscreen documents. In content scripts, calling web storage APIs accesses data from the host page the content script is injected on and not the extension."

对本项目的意义：**扩展上下文 + host_permissions + `credentials: "include"` 是「带 cookie 下载」在 fetch 途径下唯一可行组合**；且它带的是浏览器 cookie jar 里该站真实的 cookie（含 SameSite=Strict），不是脚本伪造值。反过来，如果目标 cookie 只存在于扩展自己的存储/aria2 的 `--header` 语义里，fetch 途径**无法注入**（`Cookie` 是 forbidden 头）。

### 2.3 取字节：流式读取与交出的数据形态

MDN `Response.body`【E4】：

> "The `body` read-only property of the `Response` interface is a `ReadableStream` of the body contents."

> "The stream is a **readable byte stream**, which supports zero-copy reading using a `ReadableStreamBYOBReader`."

> "Note: This feature is available in Web Workers."

可用的读取方式（同一 body 只能消费一次，`bodyUsed` 语义见 MDN/E4）：

- `response.body.getReader()` → `reader.read()` 得到 `{ value: Uint8Array, done }`；
- `response.body.getReader({ mode: "byob" })` + `ReadableStreamBYOBReader.read(view)` → 复用调用方缓冲区（降低拷贝）；
- 便利方法 `arrayBuffer()` / `blob()` / `text()` / `json()` 会把**整个 body 收进内存**（对大下载是反模式；且与流式读取互斥）。

**本层向下游交出的数据形态（接口约定，仅此一句，落盘细节归 eng-disk）**：

```
每个 chunk：Uint8Array（byte stream；BYOB 时可能落在调用方传入的 ArrayBuffer 上）
顺序：单 reader 顺序到达；同一 HTTP 响应内字节区间单调递增、不重叠
端到端元数据：{ requestedUrl, finalUrl, status, responseHeaders, contentType?,
                contentLength?: number /* 可能缺失或是压缩后长度 */,
                receivedBytes: number, chunk: Uint8Array }
多路 Range 时：每一路是一条独立的「(offset, length) → 有序 chunk 流」，
               拼接/随机写在落盘层完成，本层不做合并
跨上下文搬运：不要用 chrome.runtime 消息搬二进制（见 §5 F13）
```

### 2.4 背压（backpressure）

平台侧语义（MDN "Streams API concepts"）【E5】：

> "**Backpressure** — this is the process by which a single stream or a pipe chain regulates the speed of reading/writing. When a stream later in the chain is still busy and isn't yet ready to accept more chunks, it sends a signal backwards through the chain to tell earlier transform streams (or the original source) to slow down delivery…"

> "Internal queues employ a **queuing strategy**… compares the size of the chunks in the queue to a value called the **high water mark**… `high water mark - total size of chunks in queue = desired size`"

**但「fetch 响应体是否把背压传导到网络/TCP」在规范里并没有定义**：对 Fetch Standard 全文检索 `backpressure` / `back pressure` / `high water mark` / `desiredSize` **零命中**（抓取版检索结果，E1）。Chromium 实现侧，Blink 的 `BodyStreamBuffer::Pull()` 是**由流的 pull 驱动**取数据的（`Pull()` → `ProcessData()`；`ContextDestroyed()` → `StopLoading()`）【E29】，说明 JS 侧读取确实驱动数据流动；但网络层 data pipe 的缓冲上限没有任何官方文档说明。

→ 工程结论：**「不读就不占内存、不会下载」不能当成已证实的保证**；必须「读到就尽快交给落盘/持久层」，并在 §7 记为需实测项。

### 2.5 取消：AbortController 的时机与副作用

MDN【E6】：

> "The `abort()` method of the `AbortController` interface aborts an asynchronous operation before it has completed. This is able to abort **fetch requests, the consumption of any response bodies, or streams**."
> "If not specified, the reason is set to `"AbortError"` `DOMException`."（可用 `abort(reason)` 传自定义原因）

规范的 `fetch()` 取消算法【E1，§ "To abort a fetch() call"】：

> "Reject promise with error. This is a no-op if promise has already fulfilled. If request's body is non-null and is readable, then cancel request's body with error. … If response's body is non-null and is readable, then **error response's body with error**."

可用性（MDN Browser Compat Data，抓取于 2026-10-06）【E16】：

| 特性 | Chrome |
|---|---|
| `AbortController` / `AbortSignal`（基本） | 2019 起（MDN 标注 "available across browsers since March 2019"） |
| `AbortSignal.timeout(ms)` | Chrome 103（部分实现，超时抛 `AbortError`）→ **Chrome 124 起完整**（抛 `TimeoutError`） |
| `AbortSignal.any([...])` | Chrome 116 |
| `AbortSignal.abort()` (静态) | Chrome 93 |

要点：abort 同时作用于「未结算的 promise」与「已建立但未读完的 body 流」；abort 之后已经到达的字节**不会**被额外保留（流被 error）。**副作用**：请求很可能已经真的发到服务器（服务器可能已开始产出/记账），取消只保证客户端不再消费 —— 精确的「是否已发出/服务器是否已收到」官方未定义（§7 未验证项 6）。

### 2.6 Range：能否伪造 aria2 的「多连接」

#### 2.6.1 单区间可直接用；多区间/后缀区间会触发 preflight

规范对 safelisted 的判定【E1】：

> "`range` — 1. Let rangeValue be the result of **parsing a single range header value** given value and false. 2. If rangeValue is failure, then return false. 3. **If rangeValue[0] is null, then return false.** As web browsers have historically not emitted ranges such as `bytes=-500` this algorithm does not safelist them."

→ 结论：`Range: bytes=0-1023`、`bytes=1024-` **是** CORS-safelisted（跨域不 preflight）；`bytes=-500`（后缀区间）与 `bytes=0-99,200-299`（多区间）**不是** → 在页面/content script 上下文会触发 OPTIONS preflight，服务器不支持 preflight 就直接失败。

另外 `Range` 在规范里被定义为 "privileged no-CORS request-header name"，**在 `mode: "no-cors"` 下会被移除**（MDN 也写明 no-cors 时 `Range` 连设都不允许）【E1/E3】。

#### 2.6.2 服务器不支持 Range 时的行为

MDN【E7】：

> "A server that doesn't support range requests **may ignore the `Range` header and return the whole resource with a 200 status code**."
> "If the server sends back ranges, it uses the **206** Partial Content status code…"
> "If the ranges are invalid, the server returns the **416** Range Not Satisfiable error."
> "If the requested data has a content coding applied, **each byte range represents the encoded sequence of bytes, not the bytes that would be obtained after decoding**."

206 的响应形态：单区间返回 `Content-Range`；多区间返回 `multipart/byteranges`【E8】。416 时「browsers typically either abort the operation… or request the whole document again without ranges」，且建议响应带 `Content-Range: bytes */<length>`【E9】。

→ 引擎必须**同时检查 status（206 vs 200）与 `Content-Range`**，否则会把「服务器忽略 Range 后返回的 200 全量」当成某一分片，造成数据错位（§5 F5）。

#### 2.6.3 并发与连接数

**HTTP/1.1：Chromium 源码里同一 host 的并发 socket 上限是 6**（`net/socket/client_socket_pool_manager.cc`）【E28】：

> "// Default to allow up to 6 connections per host. Experiment and tuning may try other values (greater than 0). Too large may cause many problems, such as home routers blocking the connections!?!? See http://crbug.com/12066."
> `g_max_sockets_per_group = { 6, /* kNormal */ 255 /* kWebSocket */ }`

并且每个 pool 的软上限是 256（`g_socket_soft_cap_per_pool = {256, 256}`）【E28】。

**HTTP/2（与 HTTP/3）：协议本身把并发请求多路复用到同一连接上**（RFC 9113）【E30】：

> "Multiplexing of requests is achieved by having each HTTP request/response exchange associated with its own stream… Streams are largely independent of each other, so a blocked or stalled request or response does not prevent progress on other streams."

→ 结论：**「多连接」在 HTTP/1.1 上最多 6 并发/主机（超过的部分排队，不报错）；在 HTTP/2 上「连接数」不再是并发请求数的上限**，多路 Range 请求会在一条连接里并行。**没有**任何 API 层面上的「并发请求数上限」可调；也没有官方文档给出「每渲染进程/每扩展的 fetch 并发上限」。

#### 2.6.4 拼接：没有浏览器能力，纯 JS

规范和浏览器 API **不提供任何「合并分片」的原语**。`fetch` 只给「一次响应的字节流」；分片→整文件必须由调用方按 offset 写盘。可用的官方随机写途径属于落盘层（例如 File System Access API 的 `FileSystemWritableFileStream.write()` 支持 `position`），本层只保证交出「(offset, length) + 有序 chunk」这一形态（§2.3）。

#### 2.6.5 与 aria2「多连接」语义的差距

- aria2 的 `split`/`max-connection-per-server` 是**客户端自选的分片策略 + 失败重试**；fetch 途径能做到「同一文件多路单区间 Range 并发」，但：
  - 每路都是**独立的 CORS 请求**（在 content script/页面下还各自可能 preflight）；
  - 服务器不支持 Range 时**没有任何协商手段**，只能整体降级为单流；
  - 「暂停/恢复」没有原生支持 —— 恢复=重新发 Range 请求（需要服务器支持）；
  - 分片进度追踪要自己维护（每路 `receivedBytes` + offset）。

### 2.7 宿主生命周期：MV3 service worker 会杀死长下载

Chrome 官方 "The extension service worker lifecycle" 页（页面标注 Last updated 2023-05-02）【E18】：

> "Normally, Chrome terminates a service worker when one of the following conditions is met:
> - **After 30 seconds of inactivity. Receiving an event or calling an extension API resets this timer.**
> - **When a single request, such as an event or API call, takes longer than 5 minutes to process.**
> - **When a `fetch()` response takes more than 30 seconds to arrive.**"

> "Events and calls to extension APIs reset these timers… **Nevertheless, you should design your service worker to be resilient against unexpected termination.**"

> "To optimize the resource consumption of your extension, **avoid keeping your service worker alive indefinitely if possible.** Test your extensions to ensure that you're not doing this unintentionally."

> "**Any global variables you set will be lost if the service worker shuts down.** Instead of using global variables, save values to storage."

版本演进（同页）【E18】：

| Chrome | 变化 |
|---|---|
| 105 | `runtime.connectNative()` 保持 SW 存活 |
| 109 | **offscreen document 发出的消息会重置 SW 计时器** |
| 110 | **扩展 API 调用重置计时器**（此前只有"正在运行的 event handler"才算） |
| 114 | **长连接消息（port 上发消息）保持 SW 存活；仅"打开 port"不再重置计时器** |
| 116 | **WebSocket 收发消息重置 SW 空闲计时器**；部分 API（`desktopCapture.chooseDesktopMedia`、`identity.launchWebAuthFlow`、`management.uninstall`、`permissions.request`）被允许**突破 5 分钟** |
| 118 | `debugger` 会话保持 SW 存活 |
| 120 | `chrome.alarms` 最小周期降到 **30s**（"to match the service worker lifecycle"） |

**SW 被回收时进行中的 fetch 会怎样？** 官方文档**没有**直接写"进行中的 fetch 会被中止/数据会丢"；但有三条官方旁证【E18/E23/E29】：

1. 生命周期页只说「30 秒空闲终止」「fetch 响应 >30s 未到就终止」——即 **fetch 活动本身不是文档承认的保活来源**；
2. WebSocket 官方文档明确写了同类现象：「Previously, a service worker could become inactive despite a WebSocket connection being active if no other extension events occurred for 30 seconds. **This would terminate the service worker and close the WebSocket connection.**」【E23】；
3. Blink 源码里 body 流的宿主上下文销毁会停止取数：`void ContextDestroyed() override { buffer_->StopLoading(); }`（`BodyStreamBuffer::LoaderClient`，注释引用 crbug.com/1007162「worker thread is being terminated」）【E29】。

→ **推断（标注为推断）**：SW 终止 = 上下文被销毁 ⇒ 进行中的 fetch、已建立但未读完的 body 流随之消失，**已读入 SW 内存但未持久化的字节丢失**。要满足 Q-D5（"SW 重启不构成重启"、状态必须持久化），引擎的持久化必须在**每个 chunk 到达时**发生，而不是"下载完成后统一写"。

**扩展能不能阻止回收？** 官方**没有**提供"阻止回收"的 API；只有"重置计时器"的手段（上面那张表）。文档甚至反向劝导「avoid keeping your service worker alive indefinitely」【E18】。可用的保活手段（按官方口径）：周期性扩展 API 调用、port 上持续发消息、WebSocket 心跳（官方给的示例是每 20s 发一次心跳，特意小于 30s 空闲窗口）【E23】、`chrome.alarms`（最小 30s，恰好卡在边界，不能作为唯一保活手段）、debugger 会话（有可见代价）。**而这些手段都改变不了「单个请求 > 5 分钟」这条终止条件**——除非命中 Chrome 116 的少数 API 例外清单【E18】。

**offscreen document 的生命周期**（官方）【E19】：

> "Reasons are set during document creation to determine the document's lifespan. **The `AUDIO_PLAYBACK` reason sets the document to close after 30 seconds without audio playing. All other reasons don't set lifetime limits.**"

> "Though an extension package can contain multiple offscreen documents, **an installed extension can only have one open at a time**. If the extension is running in split mode with an active incognito profile, the normal and incognito profiles can each have one offscreen document."

→ 结论（官方明确部分）：选非 `AUDIO_PLAYBACK` 的 reason 时，文档没有寿命上限，且它是**扩展页面**（跑在 `window` 里，权限随扩展、可用 `fetch`/`XHR`/IndexedDB）。**「它会不会随 SW 回收而被销毁」官方未说明**（§7 未验证项 3）。

---

## 3 硬约束（编号清单）

每条格式：**结论 / 依据 / 影响的上下文**。能当主力/辅助的判断集中放 §4。

| # | 约束 | 依据 | 适用上下文 |
|---|---|---|---|
| C1 | `Cookie` / `Host` / `Origin` / `Referer`(头) / `Sec-*` / `Content-Length` 等**不可设置**，且是**静默丢弃**（不报错） | E1 §2.2.2、§5.1；E2 | 全部 |
| C2 | `User-Agent` 不在 forbidden 清单，但 **Chrome 静默丢弃** | E2（crbug 571722） | 全部（Chrome） |
| C3 | 跨域非 safelisted 头 / 非 safelisted 方法会**触发 preflight**，服务器不支持即失败 | E1 §2.2.2；E14 | 页面、content script（ISOLATED/MAIN） |
| C4 | 扩展上下文（SW / 扩展页面 / offscreen）在声明 `host_permissions` 后**不受 CORS 限制**；content script **即使有 host_permissions 也按页面 origin 走 CORS**（Chrome 85+） | E17、E27 | 决定「引擎能不能下别人家的文件」 |
| C5 | content script / MAIN world / 页面里发起的跨域请求，其 `Origin` 头是**页面 origin**；扩展上下文对 host_permissions 内目标的请求被当作 same-origin（行为报告，官方未明文） | E27、E32（[非规范行为报告]） | 影响服务端鉴权/防盗链 |
| C6 | `XHR` 在 MV3 SW 中**不存在**；在扩展页面/content script 中存在 | E22、E17 | SW 只能用 `fetch` |
| C7 | XHR 规范 `responseType` 只有 `""/arraybuffer/blob/document/json/text`，**没有 stream** → Chrome 下 XHR 无法增量读取字节，只能整包拿 | E13（XHR 规范 §3.6.8 / enum）；E15（BCD 子特性只有 arraybuffer/blob/document/json） | 所有用 XHR 的宿主 |
| C8 | SW 在**空闲 30s / 单请求 >5min / fetch 响应 >30s** 任一条件下被终止；**没有任何扩展 API 能阻止回收**，只能重置计时器 | E18 | MV3 SW |
| C9 | 保活手段与其上限：扩展 API 调用（110+）、port 发消息（114+）、WebSocket 收发（116+，官方示例 20s 心跳）、`alarms` 最小 30s（120+） | E18、E23 | MV3 SW |
| C10 | 非 `AUDIO_PLAYBACK` 的 offscreen document **没有文档化寿命上限**；一个扩展**同时只能有一个** offscreen document | E19 | 长任务宿主候选 |
| C11 | `mode: "no-cors"` 的响应是 opaque：**读不到 headers/body，status 恒 0**，且 `Range` 被移除 | E3、E1 | 想读字节 → 此模式无意义 |
| C12 | 单区间 `Range` 是 CORS-safelisted（不 preflight）；**后缀区间与多区间不是** | E1、E7 | 多连接伪造分片 |
| C13 | 服务器可忽略 `Range` 返回 **200 全量**；分片正确性必须靠 status+`Content-Range` 判定 | E7 | 多连接伪造分片 |
| C14 | `Content-Range` **不在** CORS-safelisted response-header 名单内 → 跨域读取需要服务器 `Access-Control-Expose-Headers` | E1 §CORS-safelisted response-header name 清单（仅 Cache-Control / Content-Language / **Content-Length** / Content-Type / Expires / Last-Modified / Pragma） | content script / 页面 |
| C15 | `Content-Length` **是** safelisted response header → 跨域（CORS 模式）无需 expose 即可读 | 同上 | 全部 CORS 模式上下文 |
| C16 | 有 `Content-Encoding` 时，`Content-Length` 指**压缩后**长度；而 JS 拿到的是**解码后**字节 | E11（"other metadata (e.g., Content-Length) refer to the encoded form of the data"）；E1「handle content codings」；E12（HTTP/2 下 `Content-Length` 冗余） | 进度推导必须处理 |
| C17 | 无 `Content-Length`（chunked / HTTP/2 不上报）时**无法得到总长度** → 只能上报已收字节 | E12 | 进度/ETA |
| C18 | `redirect: "manual"` 返回 opaque-redirect（status 0、headers 空、body null）→ 无法读 `Location` | E1 | 需要跟随/记录重定向链时 |
| C19 | `integrity` 可校验整份资源；**没有分块校验** | E3 | aria2 的 `checksum` 语义只能整文件校验 |
| C20 | `Range` 分段与 `Content-Encoding` 叠加时，Range 的单位是**编码后**字节 | E11 | 压缩资源的多连接会得到"压缩流的分片"，必须整体解码后才能用 |
| C21 | Abort 会同时 error 掉 body 流；已到达的数据不保留 | E6、E1 | 取消/超时/重试 |
| C22 | **背压是否传导到网络层没有规范/文档保证**（Fetch Standard 全文无 `backpressure`/`high water mark`） | E1（检索结果）、E29 | 内存控制 |
| C23 | `chrome.runtime` 消息是 **JSON 序列化**（Chrome 与其它浏览器不同）+ **64 MiB 上限** → 不能当二进制通道 | E25 | 跨上下文搬字节 |
| C24 | Local Network Access（LNA）自 **Chrome 142** 起对「公网 → 本地/loopback」请求加权限提示；官方 LNA 文档**未提扩展是否豁免** | E34 | 下载 localhost/LAN 目标的可行性（未验证） |
| C25 | 第三方 cookie 被用户/策略阻止时，扩展发起的请求不再享受 same-site 待遇、cookie 不带 | E20 | 需要登录态的下载 |

---

## 4 能力映射（供「能力清单」参考，按 R11 的原子能力口径）

> 与 R11 对齐：引擎只声明**原子能力**（bool），不声明 RPC 方法。下表是「fetch/XHR 途径」能声明什么、代价是什么。**标注为「运行期依赖」的条目不得写进静态能力集（与 Q-C4 一致：能力静态、运行期情形报错）。**

| 能力（示例名） | fetch/XHR 途径可否声明 | 限制 / 代价 | 上下文约束 |
|---|---|---|---|
| `withHeader`（请求头注入） | ⚠️ **部分可声明** | 只能设非 forbidden 头；`Cookie`/`Referer`(头)/`Origin`/`Sec-*`/`UA` 不可控；跨域非 safelist 头在页面侧触发 preflight | 扩展上下文无 preflight；content script/页面有 |
| `multithread`（多连接） | ✅ 可声明（有真实实现路径） | 需要**目标服务器支持 Range**（运行期依赖 → 不能作为静态能力）；只能用单区间 Range；分片拼接与随机写需要落盘层支持；HTTP/1.1 受每个 host 6 并发限制，HTTP/2 多路复用 | 扩展上下文最稳；content script 下每片都可能 preflight |
| `memUnlimited`（内存不限） | ❌ **不可声明** | 取字节层必须持续消费流；整包 `arrayBuffer()`/`blob()` 会把文件收进内存，与"不限内存"直接冲突 | 全部 |
| `progress`（真实进度） | ✅ 可声明（有 `Content-Length` 时） | 无 `Content-Length`（HTTP/2/chunked）时只能报已收字节 → 对应 Q-B7 的 b 分支；有 `Content-Encoding` 时总长与接收字节不同量纲，必须换算/判定 | 全部 |
| `resume`/`pause`（暂停恢复） | ⚠️ 只有「取消 + Range 续传」 | 没有原生暂停；续传=重新发 Range，依赖服务器支持（运行期依赖） | 全部 |
| `checksum`（完整性校验） | ⚠️ 仅整文件 | `integrity` 只支持 sha256/384/512 且校验整份资源；aria2 的 `--checksum` 若为其它算法/分块语义则不可 | 全部 |
| `cookie`（凭 cookie 下载） | ⚠️ 仅"用浏览器已有 cookie" | 不能注入 cookie 字符串；依赖 cookie jar + `credentials:"include"` + host_permissions 的 same-site 待遇；第三方 cookie 被挡时失效 | 扩展上下文（content script 带页面 cookie） |

**定位结论（要求明确回答）**

- **能当主力** —— 作为下载引擎的「**取字节层**」主力：它是唯一在 MV3 全部上下文都存在的取字节 API，支持流式、Range、取消、真实进度。
- **前提条件（硬性）**：取字节必须运行在**扩展上下文**（首选 offscreen document；次选 SW 但只用于小文件/短请求），否则 CORS 会把"下任意 URL"这件事直接否掉。
- **只能当辅助的情形**：放在 MV3 SW 里时 —— 受 C8 支配，只能服务「30 秒内能拿到响应头、且单请求 5 分钟内完成」的小文件。
- **不可用的情形**：`mode: "no-cors"`（读不到字节）、content script/普通页面里跨域下载（除非服务器给 ACAO）。
- **最大风险**：SW 生命周期（静默失败 + 数据丢失，§2.7）；**次大风险**：把「服务器是否支持 Range / 是否给 CORS 头」误当成引擎的静态能力（违反 Q-C4/R11 的静态能力模型）。

---

## 5 失败模式与盲区

| # | 触发 | 表现 | 能否检测 | 影响 |
|---|---|---|---|---|
| F1 | SW 空闲 30s / 单请求 >5min / fetch 响应 >30s 未到 | SW 被终止；进行中的请求与未持久化字节消失 | ❌ 从 JS 侧无法可靠感知（SW 已被销毁） | 「看起来在下载，其实没了」——R2 禁止的"假装正常" |
| F2 | 无 host_permissions 的扩展请求 / content script 跨域 | `fetch` reject 为 `TypeError: Failed to fetch`（"There is a network error…"【E10】） | ⚠️ 只知道"失败" | 无法区分 CORS / DNS / TLS / 断网（"CORS failures result in errors but for security reasons, specifics about the error are not available to JavaScript… The only way to determine what specifically went wrong is to look at the browser's console"【E14】）→ 与 R2「如实报错」冲突（见 §6） |
| F3 | 用了 `mode: "no-cors"` | 响应 opaque：headers/body 不可读、status 0 | ✅ 可自查（response.type） | 取字节彻底失败，必须禁止此模式 |
| F4 | 非 safelist 头（如 `Authorization`、自定义 `X-*`）或后缀/多区间 Range 在页面侧 | OPTIONS preflight；服务器不支持 → 请求根本不发 | ⚠️ 同样是 `TypeError` | 「带自定义头」的能力在页面侧不可靠 |
| F5 | 服务器忽略 Range 返回 200 | 拿到**整份**文件当成分片 → 数据错位/重复 | ✅ 必须检查 `status === 206 && Content-Range` | 静默的文件损坏（最危险） |
| F6 | Range 非法/越界 | 416 | ✅ 状态码 | 分片计划重算或降级 |
| F7 | 响应有 `Content-Encoding` | `Content-Length` 是压缩后长度，JS 收到解码后字节 → 进度条可 >100%、与"已下载字节"不符 | ✅ 读 `Content-Encoding` | 进度/ETA 假象；断点续传的 offset 语义也变（Range 以编码后字节计，C20） |
| F8 | HTTP/2 或 chunked 无 `Content-Length` | 无法得到总长 | ✅（header 缺失） | 只能报已收字节（走 Q-B7 的 b 分支）；`files[].length` 无法确定 |
| F9 | 目标站依赖 `Origin`/`Referer`/`Sec-Fetch-*`/UA 判定 | 防盗链/CDN 拒绝或返回不同内容 | ❌ 难以区分（可能表现为 403 或 HTML 错误页） | `withHeader` 能力的天花板 |
| F10 | 目标站依赖第三方 cookie 且被策略拦截 | 请求不带 cookie → 401/403/登录页 | ⚠️ 需要站方明确 | 需要登录态的下载失效（E20） |
| F11 | 目标是 localhost / LAN（Chrome 142+ LNA） | 权限提示或被拦截 | ⚠️ 扩展是否豁免**未验证**（§7） | 本项目"下载本地服务文件"场景存疑 |
| F12 | MAIN world 注入点：页面 CSP `connect-src` 限制 | 注入脚本的 fetch 被 CSP 拦 | ⚠️ 控制台可见 | MAIN world 注入方案天生受页面 CSP 制约（ISOLATED world 不受影响【E21】） |
| F13 | 用 `chrome.runtime` 消息跨上下文搬字节 | JSON 序列化把二进制变成普通对象；>64 MiB 直接失败 | ✅ 尺寸/类型可测 | 必须让字节在**最终宿主**里直接落盘；跨上下文只传元数据/控制消息 |
| F14 | 无背压保证（C22）下长时间不读 | 内存增长、甚至 OOM | ⚠️ 只能观测内存 | 长下载的稳定性风险 |
| F15 | 需要跟随重定向链 | `redirect:"manual"` 拿不到 `Location`（opaque-redirect） | ✅ 已知限制 | 文件名/最终 URL 推断只能用 `Response.url`/`redirected` |
| F16 | 用户关掉 popup / 导航离开页面 | popup 承载的 fetch 随 UI 消失 | ⚠️ | popup **不能**当下载宿主：官方原文 "Popups automatically close when the user focuses on some portion of the browser outside of the popup. **There is no way to keep the popup open** after the user has clicked away."【E37】 |

---

## 6 与现有裁定（R1–R13 / Q-*）的关系

| 裁定 | 关系 | 说明 |
|---|---|---|
| **R9**（拦截发生在 JS API 层，"请求根本不会发到网络上 ⇒ CORS、混合内容、证书全部不适用"） | ⚠️ **需要区分两个层面，否则会误判** | R9 说的是**转发器拦截 RPC 请求**这一段（对 Mock 层成立）；但**下载引擎真的要把字节从网络上取回来**，这一段**完全适用** CORS、`Sec-*`、证书、LNA 等约束。文档层面二者不冲突，工程上必须显式区分"入站 RPC"与"出站下载"两条网络路径。 |
| **R10 / R3**（伪装还原的判据是"最终结果兑现"） | ✅ 一致，且给出可实现路径 | fetch 途径能**真的**兑现"下载完成"，不是假装；多连接能力在服务器支持时可真做，不支持时按 R3 降级为单连接 + 伪装进度（§2.6.5）。 |
| **Q-B7 / Q-B8**（能拿到真实进度就报真实进度） | ✅ 支持 b 分支 | `Content-Length` 可读（C15）→ 可报真实进度；无长度时只能报已收字节（C17），与 Q-B7 的 b 语义一致。 |
| **R11 / Q-C4 / Q-B8**（能力静态、纯 bool；运行期情形**报错**、不缩减能力） | ⚠️ **冲突点，需在能力清单里处理** | 「服务器支持 Range」「服务器给 CORS 头」是**目标站属性**，不是扩展的能力。若把它们写进静态能力集就违反 Q-C4；正确做法是：`multithread` 只声明"本引擎具备多连接实现"，运行期探测失败时报自定义错误/降级（对应 Q-B5/Q-C4 的运行期错误）。 |
| **R4.1 / Q-D2**（尽可能多来源拦截；盲区必须列出） | ⚠️ **放大盲区** | "content script / MAIN world 里拦截成功"≠"引擎下得动"。盲区清单里必须新增一条：**在页面上下文里（content script/MAIN/页面）发起的下载，引擎只能下到服务器允许 CORS 的资源**。 |
| **R5**（内置 AriaNg UI 必须走同样路径，唯一例外是"换装载方式"） | ✅ 兼容 | 内置 UI 在扩展页面里运行 → 天然处于"不受 CORS 限制"的上下文；但**引擎侧仍应显式声明它跑在哪个上下文**，避免把"扩展页面能下"误当成"任何页面都能下"。 |
| **Q-D5**（SW 重启不构成重启、状态必须持久化） | ⚠️ **对引擎提出更硬的要求** | 由于 C8，SW 可能在下载中途消失 → 引擎的持久化必须**按 chunk 增量落盘**（每个 chunk 到达即写），否则 Q-D5 的"状态持久"会退化成"进度丢了"。 |
| **Q-D3**（WebSocket 允许用轮询近似推送，不依赖 SW 生命周期） | ✅ 与本文结论同源 | 官方对 WebSocket 保活的说明（每 20s 心跳 < 30s 空闲窗口）【E23】与 Q-D3 的担忧一致。 |
| **附 A（tabs + DNR 触发下载）** | ✅ 互补，不重叠 | 附 A 走的是**浏览器原生下载流**（`content-disposition`），字节不经过 JS；本文走的是**JS 取字节**。二者在"CORS 是否适用"上完全不同：前者在附录 A 的机制里也不需要 JS 读字节。 |

---

## 7 未验证（不得当作结论使用）

以下条目**在 2026-10-06 没有找到官方依据**，或官方文档只给到间接程度。建议用最小实验逐个证实（每条附建议测法）。

1. **SW 的流式 fetch：响应头已在 30s 内到达、body 持续流 > 30s 时，SW 是否会被回收？** 官方只写了"fetch 响应超过 30 秒未到达"这一条终止条件【E18】，没有说"响应已到、body 仍在流"时会不会保活。测法：SW 里发起一个大文件 fetch，只读前几 KB 然后空闲，观察 SW 何时终止。
2. **SW 被终止时进行中的 fetch 的确切表现**（promise 是否 reject、`reader.read()` 是否 hang、网络请求是否被取消）：官方未说明。仅有旁证（WebSocket 会被关闭【E23】；Blink 在上下文销毁时 `StopLoading()`【E29】）。
3. **offscreen document 是否会在 SW 回收、浏览器空闲或扩展更新时被销毁**：官方只说"除 AUDIO_PLAYBACK 外不设寿命上限"【E19】，未说明它与 SW 生命周期的关系。
4. **扩展上下文对 `host_permissions` 内目标的请求，在 fetch/HTTP 层是否真的被当作 same-origin**（含默认 `credentials: "same-origin"` 是否因此自动带 cookie、是否不发 `Origin` 头）：目前只有 W3C webextensions 社区组 issue #777 的行为报告【E32，非规范】+ Chrome 文档的间接表述【E17】。
5. **MAIN world 是否能访问扩展 API**：官方文档只写了"shared with the host page's JavaScript"【E26】与"页面 CSP 生效"【E21】；未找到"MAIN world 不能用 `chrome.*`"的官方明文（本轮检索范围内）。
6. **abort 之后**：请求是否已被发出、服务器是否已开始传输/记账：规范只定义客户端行为【E1】，没有服务器侧保证。
7. **fetch 响应体的背压上限**：Fetch Standard 无相关定义【E1】；Chromium data pipe 的缓冲上限无官方文档。
8. **LNA（Chrome 142+）是否豁免扩展上下文**：官方 LNA 博客未提扩展【E34】。
9. **`keepalive: true` 是否能让请求跨越 SW 回收**：MDN 只说"page that initiated it is unloaded"【E3】。
10. **HTTP/2/HTTP/3 下 fetch 的并发请求数是否有其它上限**：Chromium 源码只给了 socket pool 的 per-group 上限 6 与非 WebSocket 的 255【E28】；多路复用下"请求数"的实际上限没有官方文档。
11. **`chrome.runtime.sendMessage` 传 `Uint8Array`/`ArrayBuffer` 的实际结果**：文档只说 "use JSON serialization"（Chrome）与 64 MiB 上限【E25】，未给二进制的明确说明。
12. **`integrity` 与 Range 分片请求叠加时的语义**（是否对分片单独校验、是否会因不完整而失败）：MDN 未说明。
13. **多区间 Range（`multipart/byteranges`）在跨域 + preflight 通过后的可解析性**（浏览器是否保留 multipart 原始 body）：未见官方说明；本文按"不依赖它"处理。
14. **当前 Chrome 稳定版与 MV3 相关的默认值是否已随 2024–2026 年的新政策改变**（本文所用扩展文档页面多数标注最后更新 2022–2023）：需在选定 `minimum_chrome_version` 前复核。

---

## 8 证据清单

> 全部链接抓取于 **2026-10-06（UTC）**。引文为英文原文逐字摘录（规范中的反引号已转为普通文本）。

| # | 来源 | URL | 关键引文 / 用途 |
|---|---|---|---|
| E1 | WHATWG **Fetch Standard**（抓取时标注 *Living Standard — Last Updated 6 October 2026*） | https://fetch.spec.whatwg.org/ | forbidden request-header 清单与判定（"These are forbidden so the user agent remains in full control over them."）；`Headers` guard=request 时静默丢弃；CORS-safelisted request-header（含 `range` 单区间规则、"As web browsers have historically not emitted ranges such as `bytes=-500` this algorithm does not safelist them"）；"privileged no-CORS request-header name" = `Range`；CORS-safelisted response-header name 清单（Cache-Control / Content-Language / Content-Length / Content-Type / Expires / Last-Modified / Pragma + 非 forbidden response-header）；credentials mode 定义；cache mode（`only-if-cached` 限制）；"Retrieves an opaque-redirect filtered response… status is 0, header list is 「」, body is null"；"To abort a fetch() call… error response's body"；"To handle content codings…"；全文检索 `backpressure`/`high water mark`/`desiredSize` 零命中 |
| E2 | MDN Glossary — **Forbidden request header** | https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header | 同一 forbid 清单；"Note: The `User-Agent` header used to be forbidden, but no longer is. However, Chrome still silently drops the header from Fetch requests (see crbug.com/571722)."；"While the `Referer` header is listed as a forbidden header in the spec, … the header can be programmatically modified … via the `referrer` option."；"Chrome also forbids `Access-Control-Request-Private-Network`" |
| E3 | MDN — **RequestInit** | https://developer.mozilla.org/en-US/docs/Web/API/RequestInit | `credentials` 三值语义与默认 `same-origin`；`mode: "no-cors"` 的三条限制（"the `Range` header is also not allowed"、"The response is opaque… status code is always 0"）；`redirect` `manual` 的说明；`cache` 各值；`referrer`/`referrerPolicy`；`integrity`；`keepalive`（"will not abort the associated request if the page that initiated it is unloaded"、64 KiB 上限、"also available in service workers"）；`priority`；`targetAddressSpace`；`duplex` |
| E4 | MDN — **Response.body** | https://developer.mozilla.org/en-US/docs/Web/API/Response/body | "a `ReadableStream` of the body contents"；"The stream is a readable byte stream, which supports zero-copy reading using a `ReadableStreamBYOBReader`"；"Note: This feature is available in Web Workers." |
| E5 | MDN — **Streams API concepts**（页末标注 last modified Jul 24, 2024） | https://developer.mozilla.org/en-US/docs/Web/API/Streams_API/Concepts | backpressure 定义与 high water mark / desiredSize 公式 |
| E6 | MDN — **AbortController: abort()** | https://developer.mozilla.org/en-US/docs/Web/API/AbortController/abort | "aborts fetch requests, the consumption of any response bodies, or streams"；默认 reason = `AbortError` DOMException；"available in Web Workers" |
| E7 | MDN — **Range** header | https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Range | "A server that doesn't support range requests may ignore the Range header and return the whole resource with a 200 status code."；"**The header is a CORS-safelisted request header when the directive specifies a single byte range.**"；"If the requested data has a content coding applied, each byte range represents the encoded sequence of bytes, not the bytes that would be obtained after decoding." |
| E8 | MDN — **206 Partial Content** | https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/206 | 单区间 → `Content-Range`；多区间 → `multipart/byteranges` |
| E9 | MDN — **416 Range Not Satisfiable** | https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/416 | "browsers typically either abort the operation … or request the whole document again without ranges"；`Content-Range: bytes */<length>` |
| E10 | MDN — **Window.fetch()** | https://developer.mozilla.org/en-US/docs/Web/API/Window/fetch | `TypeError` 的成因之一："There is a network error (for example, because the device does not have connectivity)." |
| E11 | MDN — **Content-Encoding** | https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Encoding | "When the Content-Encoding header is present, other metadata (e.g., Content-Length) refer to the encoded form of the data, not the original resource, unless explicitly stated." |
| E12 | MDN — **Content-Length** | https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Length | "In HTTP/2, Content-Length is redundant, because the content length may be inferred from DATA frames. It may still be included for backwards compatibility."；"Content-Length is limited in that the message size must be known up front" |
| E13 | WHATWG **XMLHttpRequest Standard** | https://xhr.spec.whatwg.org/ | `enum XMLHttpRequestResponseType { "", "arraybuffer", "blob", "document", "json", "text" }`（无 `stream`）；"Fire a progress event named progress"（§3.6.6 等） |
| E14 | MDN — **Cross-Origin Resource Sharing (CORS)** guide | https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS | "CORS failures result in errors but for security reasons, specifics about the error are not available to JavaScript. All the code knows is that an error occurred." |
| E15 | MDN **browser-compat-data** — `api/XMLHttpRequest.json` | https://github.com/mdn/browser-compat-data/blob/main/api/XMLHttpRequest.json | `responseType` 子特性仅 `arraybuffer_value` / `blob_value` / `document_value` / `json_value`（无 stream）；Chrome 31+ |
| E16 | MDN **browser-compat-data** — `api/AbortSignal.json` | https://github.com/mdn/browser-compat-data/blob/main/api/AbortSignal.json | `timeout_static`: Chrome 103（partial，抛 AbortError）→ 124（完整）；`any_static`: Chrome 116；`abort_static`: Chrome 93 |
| E17 | Chrome for Developers — **Cross-origin network requests**（页面标注 Last updated 2012-09-18） | https://developer.chrome.com/docs/extensions/develop/concepts/network-requests | "Content scripts initiate requests on behalf of the web origin…"; "A script executing in an extension service worker or foreground tab can talk to remote servers outside of its origin, as long as the extension requests host permissions."；"**Cross-origin requests are always treated as such in content scripts, even if the extension has host permissions.**"；"The XMLHttpRequest() API is supported in extensions outside of the service worker…"；CSP `connect-src` 提醒 |
| E18 | Chrome for Developers — **The extension service worker lifecycle**（页面标注 Last updated 2023-05-02） | https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle | 三条终止条件（30s 空闲 / 单请求 >5min / fetch 响应 >30s）；"design your service worker to be resilient against unexpected termination"；"avoid keeping your service worker alive indefinitely if possible"；"Any global variables you set will be lost"；Chrome 105/109/110/114/116/118/120 的保活与超时变化 |
| E19 | Chrome for Developers — **chrome.offscreen API** | https://developer.chrome.com/docs/extensions/reference/api/offscreen | "The extension's permissions carry over to offscreen documents, but with limits on extension API access… the `browser.runtime` API is the only extensions API supported"；"The AUDIO_PLAYBACK reason sets the document to close after 30 seconds without audio playing. All other reasons don't set lifetime limits."；"an installed extension can only have one open at a time" |
| E20 | Chrome for Developers — **Storage and cookies** | https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies | "Requests from an extension to a third-party are treated as same-site if the extension has host permissions for the third-party. This means `SameSite=Strict` cookies can be sent. … does not apply if third-party cookies are blocked."；扩展存储跨 SW/扩展页/offscreen 共享 |
| E21 | Chrome for Developers — **Content scripts** | https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts | ISOLATED world 的 CSP 串（仅 `script-src`/`object-src`，无 `connect-src`）；"When a content script is injected into the main world, **the CSP of the page applies**."；"An isolated world is a private execution environment…" |
| E22 | Chrome for Developers — **Migrate to a service worker** | https://developer.chrome.com/docs/extensions/develop/migrate/to-service-workers | "`XMLHttpRequest()` can't be called from a service worker, extension or otherwise."；"Terminating service workers can also end timers before they have completed." |
| E23 | Chrome for Developers — **WebSockets in extensions**（Chrome 116+ 保活示例） | https://developer.chrome.com/docs/extensions/how-to/web-platform/websockets | "Previously, a service worker could become inactive despite a WebSocket connection being active if no other extension events occurred for 30 seconds. This would terminate the service worker and close the WebSocket connection."；"keep a service worker with a WebSocket connection active by exchanging messages within the 30s service worker activity window"；官方示例：每 20s 发一次 keepalive |
| E24 | Chrome for Developers — **Real-time updates**（页面标注 Last updated 2023-12-20） | https://developer.chrome.com/docs/extensions/develop/concepts/real-time | WebSocket 心跳保活表述；"WebSockets run in the web platform, rather than using an extension platform API… Chrome has no way to wake up your extension when a WebSocket…" |
| E25 | Chrome for Developers — **Message passing** | https://developer.chrome.com/docs/extensions/develop/concepts/messaging | "In Chrome, the message passing APIs use JSON serialization. Notably, this is different to other browsers which implement the same APIs with the structured clone algorithm."；"The maximum size of a message is 64 MiB." |
| E26 | Chrome for Developers — **chrome.scripting API**（`ExecutionWorld`） | https://developer.chrome.com/docs/extensions/reference/api/scripting | "`"ISOLATED"` … the execution environment unique to this extension. `"MAIN"` Specifies the main world of the DOM, which is the execution environment shared with the host page's JavaScript." |
| E27 | The Chromium Projects（Chromium Security）— **Changes to Cross-Origin Requests in Chrome Extension Content Scripts**（含 2020-09-17 修订） | https://new.chromium.org/Home/chromium-security/extension-content-script-fetches/ | "cross-origin fetches initiated from content scripts will have an `Origin` request header with the page's origin"；"This change started in Chrome 85."；"**Extension pages … are unaffected by this change and will continue to be allowed to bypass CORS**" |
| E28 | Chromium 源码 — `net/socket/client_socket_pool_manager.cc`（main 分支） | https://chromium.googlesource.com/chromium/src/+/main/net/socket/client_socket_pool_manager.cc | "// Default to allow up to 6 connections per host…"；`g_max_sockets_per_group = { 6 /* kNormal */, 255 /* kWebSocket */ }`；`g_socket_soft_cap_per_pool = { 256, 256 }` |
| E29 | Chromium 源码 — `third_party/blink/renderer/core/fetch/body_stream_buffer.cc`（main 分支） | https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/core/fetch/body_stream_buffer.cc | `void ContextDestroyed() override { buffer_->StopLoading(); }`（注释引用 crbug.com/1007162 "when a worker thread is being terminated"）；`BodyStreamBuffer::Pull()` → `ProcessData()`（pull 驱动）；`ReadableStream::CreateByteStream` |
| E30 | RFC 9113（HTTP/2） | https://www.rfc-editor.org/rfc/rfc9113.html | "Multiplexing of requests is achieved by having each HTTP request/response exchange associated with its own stream … Streams are largely independent of each other, so a blocked or stalled request or response does not prevent progress on other streams." |
| E31 | Chromium 源码 — `extensions/browser/service_worker/service_worker_keepalive.h` 与 `content/public/browser/service_worker_external_request_timeout_type.h`（main 分支） | https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/service_worker/service_worker_keepalive.h ；https://chromium.googlesource.com/chromium/src/+/main/content/public/browser/service_worker_external_request_timeout_type.h | keepalive 以 `Activity::Type` 记账；超时枚举 `kDefault`（= `kRequestTimeout`）与 `kDoesNotTimeout`（"SW won't time out before … `FinishedExternalRequest()` is issued"）——说明**存在**不退出的 keepalive 种类，但**哪种行为用哪种超时未在本文核实**（见 §7） |
| E32 | W3C **webextensions** 社区组 issue #777（2025-03-09 开启，状态 Open / needs-triage） | https://github.com/w3c/webextensions/issues/777 | **[非规范行为报告]** "When fetching a url from allowed host in `host_permissions`, then this request is considered same-origin and no `Origin` header is added."；"I am not aware of forcing the origin header to be sent besides not using GET requests." |
| E33 | MDN — **Content-Range**（用于交叉确认其不在 safelisted 清单） | https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Range | 语义参考；是否需 `Access-Control-Expose-Headers` 由 E1 的 safelisted 清单反推 |
| E34 | Chrome for Developers Blog — **New permission prompt for Local Network Access**（Published 2025-06-09，Update 2025-09-29） | https://developer.chrome.com/blog/local-network-access | "**The Local Network Access permission prompt is launching in Chrome 142.**"；"Local Network Access restricts the ability of websites to send requests to servers on a user's local network (including servers running locally on the user's machine), requiring the user grant the site permission before such requests can be made."；"a 'local network request' [is] any request from the public network to a local network or loopback destination" |
| E35 | Chrome for Developers — **Extension service worker basics** | https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/basics | MV3 SW 注册方式；`import()` 不支持等（上下文补充） |
| E36 | MDN — **Request.targetAddressSpace** | https://developer.mozilla.org/en-US/docs/Web/API/Request/targetAddressSpace | `local` / `loopback` / `public` 语义与 LNA 关联 |
| E37 | Chrome for Developers — **Add a popup** | https://developer.chrome.com/docs/extensions/develop/ui/add-popup | "Popups automatically close when the user focuses on some portion of the browser outside of the popup. There is no way to keep the popup open after the user has clicked away." |

---

### 附：本文用到的术语与编号约定

- 「扩展上下文」= MV3 service worker + 扩展页面（popup / options / side panel）+ offscreen document（三者都是 `chrome-extension://` origin，且声明 host_permissions 后不受 CORS 限制）。
- 「页面上下文」= content script（ISOLATED / MAIN 都算，请求以页面 origin 发出）+ 普通页面。
- 「运行期依赖」= 由**目标服务器**决定、不能写进 R11 静态 bool 能力集的条件（如是否支持 Range、是否给 CORS 头）。
