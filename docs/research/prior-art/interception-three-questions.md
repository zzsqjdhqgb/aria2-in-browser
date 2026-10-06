# 拦截三问（研究员 A）— 标签页请求转发 / fetch 与 XHR 劫持 / 能否拦其它扩展

## 0 元信息

| 项 | 值 |
|---|---|
| 文档性质 | 既有方案调研（prior art），**输入文档**，不做设计 |
| 调研人 | prior-intercept-a（与 prior-intercept-b **各自独立**完成同一题目） |
| 调研日期 | **2026-10-06**（下文所有 URL 均为该日抓取） |
| 适用浏览器/版本 | **Chrome stable ≈ 155**（官方博客称 Chrome 155 Stable 于 2026-10-06 开始 rollout）；Chrome 的 MV2 支持止于 **138**（企业策略）/ **139**（完全移除）；Firefox：以 MDN 兼容数据（BCD）与 Mozilla 官方博客为准，未绑定具体版本号；Safari 仅在兼容数据表中出现 |
| 方法 | 官方文档（Chrome for Developers / MDN / Mozilla）＋ **Chromium 源码（`main` 分支，辅以历史 tag 对比）** ＋ **线上扩展的已发布产物（Chrome Web Store CRX 解包后的 manifest 与 JS）** ＋ npm/GitHub 上的库源码。所有关键结论给 URL，关键处给原文摘录 |
| 阅读前提 | 已读 `/workspace/docs/concept-design/concept-design.md` v0.5（R4、R5、R9、Q-D1、§6） |
| 声明 | 凡标「**推断**」的条目是由已引用的来源**逻辑推出**，不是来源直述；凡标「未验证」的条目是本次查不到可靠来源 |

---

## 1 一句话结论（三问各一句）

1. **拦截转发「标签页发出的请求」**：在 Chrome MV3 时代，网络层只剩两条真实可选的路——**DNR（能 block / redirect / 改头，但没有任何合成响应体的能力）** 与 **`chrome.debugger` + CDP `Fetch`（确实能用 `Fetch.fulfillRequest` 连响应体一起伪造，代价是用户可见的调试横幅、会与 DevTools 互斥、企业策略限制）**；MV2 的 blocking `webRequest` 在 Chrome 上已死（仅策略安装扩展例外），但它在 Firefox MV3 中仍然存在，并且历史上是唯一能"重定向到 `data:` URL 以凭空造响应体"的官方途径（Resource Override 就是这么干的）。
2. **fetch / XHR 劫持**：现成库分成两派——**改全局构造器**（ajax-hook / xhook / nise-sinon，替换 `window.XMLHttpRequest`）与 **改全局函数 / 代理实例**（fetch-intercept、@mswjs/interceptors、Requestly 的页面脚本）；它们都能完整伪造响应，但**都会留下可检测的痕迹**（`toString` 输出、属性描述符、事件对象原型与 `isTrusted`、同步 XHR 被放弃等），并且**必须运行在 MAIN world（页面世界）**——隔离世界（ISOLATED world，默认的 content script 世界）里打的补丁对页面和别的扩展都不可见，反之亦然。
3. **能否拦截其它扩展的请求**：**基本不能**，且这是浏览器有意为之——content script 的 match pattern 不允许 `chrome-extension://` scheme（Chromium `UserScript` 的合法 scheme 集合里没有 `SCHEME_EXTENSION`）；`webRequest` 自 Chrome 117 起在监听器层面就按「发起者的渲染进程」把别的扩展的请求滤掉；DNR 自 Chrome 129/130 起直接跳过「由别的扩展发起的非 main_frame 请求」，且永不匹配 URL 为 `chrome-extension://` 的请求；`chrome.debugger` 也禁止 attach 到别的扩展的页面（除非启动时带 `--extensions-on-extension-urls` / `--extensions-on-chrome-urls`）。**因此：一个第三方 aria2 前端扩展自己发出的 `localhost:6800` 请求，我们接不住**；能接住的只有"跑在普通网页里的 aria2 前端"。

---

## 2 第一问：拦截转发「标签页发出的请求」的现有方案

### 2.0 能力总表（先看结论）

| 方案 | 走哪一层 | 能拦到"标签页 JS 发出的请求"？ | 能改变请求（URL/方法/头/体）？ | 能合成响应体？ | 能只看不改？ | Chrome MV3 现状 |
|---|---|---|---|---|---|---|
| MV2 blocking `webRequest` | 网络层（请求已到网络栈之前） | 是 | 是（cancel / redirectUrl / 请求头 / 响应头） | **能**（`redirectUrl` 允许 `data:`；Firefox 另有 `filterResponseData`） | 是 | **不可用**（除策略安装扩展） |
| MV2/MV3 观测型 `webRequest` | 网络层（旁路观察） | 是 | **否** | 否 | 是（含请求体、请求头、响应头） | 可用 |
| `declarativeNetRequest` | 网络层（声明式） | 是 | 是（block / redirect / upgradeScheme / modifyHeaders） | **否**（无任何响应体接口；redirect 的 scheme 变换只允许 http/https/ftp/chrome-extension） | 否（设计上不给内容） | **官方推荐路径** |
| `chrome.debugger` + CDP `Fetch` | 渲染器/网络之间的调试层 | 是（附着目标内全部请求或按 pattern） | 是（`continueRequest` 改 URL/method/headers/postData） | **能**（`Fetch.fulfillRequest` 带 `body`） | 是 | 可用（有用户可见成本） |
| content script 在 JS 层改写 | 页面 JS 层（MAIN world） | 是（fetch / XHR / WebSocket 等 JS API 调用） | 是 | **能**（构造 `Response` / 伪造 XHR 实例） | 是 | 可用（受 world、CSP、时序限制） |

> 关键对照：R9 已裁定拦截发生在 **JS API 层**，命中后请求**不发出**。上表中只有最后一行（以及 `chrome.debugger` 的 `Fetch.fulfillRequest`）满足"请求根本不发到网络"；DNR 的 block 也满足"不发请求"，但**返回不了我们想要的自定义响应体**。

---

### 2.1 MV2 blocking `webRequest`

**名称 / 出处**：`chrome.webRequest`（Manifest V2 的 `webRequestBlocking` 权限）— <https://developer.chrome.com/docs/extensions/reference/api/webRequest>

**原理 / 用的 API**：在请求生命周期各阶段注册**同步**回调，回调返回 `webRequest.BlockingResponse` 决定请求后续走向。官方原文：

> "If the optional `opt_extraInfoSpec` array contains the string `'blocking'` (only allowed for specific events), the callback function is handled synchronously. ... Depending on the context, this response allows canceling or redirecting a request (`onBeforeRequest`), canceling a request or modifying headers (`onBeforeSendHeaders`, `onHeadersReceived`), and canceling a request or providing authentication credentials (`onAuthRequired`)."（同页）

**能覆盖到什么程度**

- `cancel` / `redirectUrl` / `requestHeaders` / `responseHeaders` / `authCredentials`（同页 BlockingResponse 类型）。
- **可以合成自定义响应体**：`redirectUrl` 的文档原文是 "Redirections to non-HTTP schemes such as `data:` are allowed."（同页）。也就是说，把命中 URL 重定向到一个 `data:` URL，等价于"凭空返回一段响应体"。
- Firefox 还有一条 Chrome 没有的路：`webRequest.filterResponseData()` 返回 `StreamFilter`，MDN 原文："You can think of the stream filter as sitting between the networking stack and the browser's rendering engine. ... **The filter has full control over the response body**"（<https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest/StreamFilter>）。注意此时**请求已经发出去了**，只是响应被改写。

**现成代码证据（真实项目这么干）**

- **Resource Override**（MV2，`webRequest` + `webRequestBlocking` + `<all_urls>`，见其 manifest：<https://github.com/kylepaulsen/ResourceOverride/blob/master/manifest.json>）在 `src/background/requestHandling.js` 里实现"用本地内容替换线上内容"：
  - Firefox 分支：`browser.webRequest.filterResponseData(requestId).onstart = e => { e.target.write(encoder.encode(file)); e.target.disconnect(); }` 并返回 `{cancel: true, responseHeaders:[...]}`；
  - 其它浏览器（Chrome）分支：`return { redirectUrl: "data:" + mime + ";charset=UTF-8;base64," + btoa(...) }`。
  - 源文件：<https://github.com/kylepaulsen/ResourceOverride/blob/master/src/background/requestHandling.js>（第 6–28 行）
- **Redirector**（MV2，`webRequest` + `webRequestBlocking` + `webNavigation` + `tabs`，见 <https://github.com/einaregilsson/Redirector/blob/master/manifest.json>）在 `js/background.js` 中返回 `{ redirectUrl: result.redirectTo }`（纯重定向，不做响应体）。

**现状 / 是否还有平台支持（逐平台）**

| 平台 | blocking `webRequest` 现状 | 证据 |
|---|---|---|
| Chrome | MV3 里 `webRequestBlocking` "is no longer available for most extensions... only available to policy installed extensions"；MV2 本体已死：Chrome 138 是最后一个支持 MV2 的版本（配合企业策略），**Chrome 139 起 MV2 扩展彻底失效**；2026-08-31 起所有剩余 MV2 扩展从 Chrome Web Store 移除 | <https://developer.chrome.com/docs/extensions/reference/api/webRequest>；<https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline> |
| Firefox | **MV3 仍然保留 blocking webRequest**。Mozilla 原文："Mozilla will maintain support for blocking WebRequest in MV3. To maximize compatibility with other browsers, we will also ship support for declarativeNetRequest." | <https://blog.mozilla.org/addons/2022/05/18/manifest-v3-in-firefox-recap-next-steps/> |
| Safari | `webRequestBlocking` 兼容数据显示 `"safari": { "version_added": false }` | <https://github.com/mdn/browser-compat-data/blob/main/webextensions/manifest/permissions.json> |

**局限**

- 需要**同时**对「请求 URL」和「发起者」有 host 权限（Chrome 72 起）："Starting from Chrome 72, an extension will be able to intercept a request only if it has host permissions to both the requested URL and the request initiator."（webRequest 文档）
- 敏感头（`Cookie`、`Referer`、`Origin`、`Set-Cookie` 等）默认不可见/不可改，需要 `'extraHeaders'`，而文档同时警告它有性能代价（同页）。
- 内存缓存命中的请求对 webRequest **不可见**（同页 Caching 节）。
- blocking 回调是同步的：**不能**在里面做异步 IO（比如等一个 mock 层返回）；要"按请求动态生成响应体"，`data:` 重定向是唯一现成手法（**推断**，基于 BlockingResponse 的同步语义与 `redirectUrl` 的文档）。
- 对 WebSocket：Chrome 58 起能看到握手请求，但 "The API does **not intercept**: Individual messages sent over an established WebSocket connection. WebSocket closing connection."，且 "Redirects are **not supported** for WebSocket requests."（同页）。
- 多扩展冲突时只有"最近安装的扩展"生效（同页 Conflict resolution），**推断**：与我们同装一个能改头的扩展时行为不可控。

---

### 2.2 MV3 观测型 `webRequest`

**名称 / 出处**：MV3 下的 `chrome.webRequest`（去掉 `webRequestBlocking`）— 同 2.1 链接

**能看到什么**

- 官方原文："Aside from `"webRequestBlocking"`, the webRequest API is unchanged and available for normal use."（webRequest 文档顶部 Note）
- 因此仍可监听 `onBeforeRequest`（含 `requestBody`）、`onBeforeSendHeaders`、`onSendRequest`、`onHeadersReceived`、`onCompleted`、`onErrorOccurred` 等，拿到 URL、方法、frameId/tabId、请求头、响应头、状态码、错误；`details.initiator`（Chrome 63+）给出"发起请求的源"。
- 需要 `webRequest` 权限 + 对应 host 权限（同页 Permissions）。

**不能做什么**

- **任何 blocking 行为**：不能 cancel、不能 redirect、不能改请求/响应头、不能改响应体、不能提供 auth 凭据。MV3 的替代品就是 DNR（<https://developer.chrome.com/docs/extensions/develop/migrate/blocking-web-requests>：把 block/redirect/modifyHeaders 三类"逐用例改写"为声明式规则）。
- **自 Chrome 117 起，别的扩展发起的请求在监听器层面就被过滤掉了**（见 §4.2）：Chromium `extension_web_request_event_router.cc` 中 `ListenerMatchesRequest()`：

  ```cpp
  // Filter requests from other extensions / apps. This does not work for
  // content scripts, or extension pages in non-extension processes.
  if (is_request_from_extension &&
      listener.id.render_process_id != request.global_id.child_id) {
    return false;
  }
  ```
  （<https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/web_request/extension_web_request_event_router.cc>）
  版本核对：该片段在 `refs/tags/117.0.5938.0`、`120`、`128`、`138` 存在，在 `116.0.5845.0` 及更早**不存在** ⇒ **Chrome 117 引入**（本次逐版本抓取比对得出）。
- 状态在 SW 内存里不可靠（SW 会被回收），观测到的事件与"拦截"能力之间没有桥。

---

### 2.3 `declarativeNetRequest`（DNR）

**名称 / 出处**：`chrome.declarativeNetRequest` — <https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest>（Chrome 84+）

**能力（官方列举，逐条）**

官方对"一条规则能做什么"的原文列举：

> "A single rule does one of the following: Block a network request. Upgrade the schema (http to https). Prevent a request from getting blocked by negating any matching blocked rules. Redirect a network request. Modify request or response headers."

- **block**：请求前拦截（`{type:"block"}`）。
- **redirect**：`{type:"redirect", redirect:{ url | extensionPath | transform | regexSubstitution }}`。redirect 的 target 细节：
  - `url`："The redirect url. **Redirects to JavaScript urls are not allowed.**"（同页 Redirect 类型）
  - `transform.scheme` 的允许值："Allowed values are `"http"`, `"https"`, `"ftp"` and `"chrome-extension"`."（同页 URLTransform）
  - `extensionPath`：重定向到扩展内资源，但该资源必须声明为 `web_accessible_resources`，否则报错（同页 Web accessible resources 节）。
- **modifyHeaders**：请求头与响应头都能改；响应头阶段改**请求**头无效（"Applying modifications to response headers works in the same way... Applying modifications to request headers does nothing, since the request has already been made."）；append 只支持白名单头。
- **responseHeaders 条件**（Chrome 128+）：可以"等响应头到了再决策"，但文档明确此时**请求已经发出去**，block/redirect 只能"让页面收到一个被阻断的响应 / 再发一次重定向请求"："Note that if a request made it to this stage, the request has already been sent to the server and the server has received data like the request body."
- **规则规模**：静态 ≥30000 条保证、动态 unsafe 5000 / safe 30000、session 5000、regex 规则上限 1000（同页 Rule limits）。
- **匹配面**：`urlFilter` / `regexFilter`（RE2）/ `initiatorDomains`（"matches against the request initiator and not the request url"）/ `requestDomains` / `resourceTypes`（枚举里含 `websocket`、`webtransport`、`xmlhttprequest`）/ `tabIds` / `responseHeaders` 等。
- **生效边界**（同页 "Interactions with service workers"）："A declarativeNetRequest only applies to requests that reach the network stack. This includes responses from the HTTP cache, but may not include responses that go through a service worker's `onfetch` handler. declarativeNetRequest won't affect responses generated by the service worker or retrieved from `CacheStorage`, but it will affect calls to `fetch()` made in a service worker."

**关键问题：能不能合成自定义响应体？→ 不能（官方接口层面不存在该能力）**

- DNR 的 action 表是**穷举**的（block / upgradeScheme / allow / allowAllRequests / redirect / modifyHeaders），**没有任何"提供响应体/响应状态/响应内容"的字段**（同上）。
- redirect 只能指向：URL（禁止 `javascript:`）、扩展内静态资源（`extensionPath` + WAR）、或做 URL 变换（scheme 只允许 http/https/ftp/chrome-extension）。
  - **未验证**：`redirect.url` 是否允许 `data:`。文档只显式禁止 `javascript:`；本次没有找到"允许/禁止 data: "的官方说明，也没有条件实测。即使允许，其能力也仅限于**规则里写死的静态字符串**（无法按请求读取请求体、无法动态生成 RPC 响应）。
- 因此：**DNR 无法承担"冒充 aria2 RPC 服务端"的任务**（我们要的是逐请求动态生成的 JSON-RPC 响应）。

**现成扩展用的就是它**

- **ModHeader V3**（Chrome Web Store `cndlnhnjdlmipaflgajjikndbfkfnohp`，版本 `2026.8.8.18`，MV3）：解包后的 `manifest.json` 里权限只有 `clipboardRead, clipboardWrite, declarativeNetRequest, storage` + `host_permissions: <all_urls>`，**没有 `webRequest`、没有 `debugger`、没有 content scripts**；`background.js` 里组装 `{type:"modifyHeaders", requestHeaders:[...], responseHeaders:[...]}` 规则并调用 `updateDynamicRules` / `updateSessionRules`。（本次对 CRX 解包后核对，见 §10；商店页：<https://chromewebstore.google.com/detail/modheader-v3-%E2%80%94-by-modhead/cndlnhnjdlmipaflgajjikndbfkfnohp>）
- **Requestly**（`mdnleldcmiljblolnjhpnblkcekpdkpa`，版本 `26.9.29`，MV3）：manifest 权限含 `declarativeNetRequest` 与 `webRequest` 同时存在，并带静态规则集 `delayRules` / `headerRules`；SW 中调用 `updateDynamicRules` / `updateSessionRules`。（同上核对）
- 附注（风险背景，非技术结论）：ModHeader 于 2026-07 被 Chrome/Edge 商店下架，第三方报道见 <https://thehackernews.com/2026/07/google-and-microsoft-pull-modheader.html>（**非官方来源**，仅作背景）。

---

### 2.4 `chrome.debugger` + CDP `Fetch` 域

**出处**：<https://developer.chrome.com/docs/extensions/reference/api/debugger>；CDP Fetch 域 <https://chromedevtools.github.io/devtools-protocol/tot/Fetch/>（协议定义 JSON：<https://github.com/ChromeDevTools/devtools-protocol/blob/master/json/browser_protocol.json>）

**能不能用 `Fetch.fulfillRequest` 返回自定义响应体？→ 能。**

协议原文（`browser_protocol.json`，`Fetch.fulfillRequest`）：

> `requestId` (required) — An id the client received in requestPaused event.
> `responseCode` (required) — An HTTP response code.
> `responseHeaders` / `binaryResponseHeaders` (optional)
> **`body` (optional) — "A response body. If absent, original response body will be used if the request is intercepted at the response stage and empty body will be used if the request is intercepted at the request stage. (Encoded as a base64 string when passed over JSON)"**
> `responsePhrase` (optional)

配套能力：

- `Fetch.enable(patterns, handleAuthRequests)`："If specified, only requests matching any of these patterns will produce fetchRequested event and will be paused until clients response. If not set, all requests will be affected."；`RequestPattern.urlPattern` 是通配（`*`、`?`，转义 `\`），`resourceType`、`requestStage`（Request / Response）可选。
- `fetch.requestPaused` 事件说明请求被暂停，必须由 `continueRequest` / `failRequest` / `fulfillRequest` 之一回复；请求/响应阶段靠 `responseStatusCode` 等字段区分；重定向会带 `redirectedRequestId`。
- `Fetch.continueRequest` 可以改 URL（"modified in a way that's not observable by page"）、method、postData、headers。
- **`chrome.debugger` 允许的 CDP 域里包含 Fetch**：官方文档 "Restricted domains" 一节列出可用域，包括 `Fetch`、`Network`、`Runtime`、`Page` 等。

**能拦到什么范围**

- 目标是 `Debuggee`：`tabId` / `extensionId` / `targetId`（`Debuggee` 类型）。一个 tab 及其 OOPIF/worker 需要按 Chrome 125+ 的 flat session（`Target.setAutoAttach` + `sessionId`）逐个挂上去（文档 "Attach to related targets"）。
- 附着后，`Fetch.enable` 可以拦到该目标内**所有**匹配 pattern 的请求（含 XHR/fetch/子资源），**不受页面 JS 层是否被 hook 影响**，包括 Service Worker 中发出的网络请求（**推断**：SW 是独立 target/worker，需按文档挂到 worker target 上；文档明确 worker target 的附着要校验 parent 的 URL）。
- `chrome://` 等 WebUI 内部帧会被拒：源码里 `if (render_frame_host->GetWebUI()) { *error = manifest_errors::kCannotAccessChromeUrl; result = false; }`（`chrome/browser/extensions/api/debugger/debugger_api.cc`）。
- 别的扩展的页面会被拒（见 §4.4）。

**代价（逐条，均有来源）**

1. **用户可见警告**：`ExtensionDevToolsClientHost::Attach()` 里，除非进程带 `--silent-debugger-extension-api` 或扩展是策略安装（`Manifest::IsPolicyLocation`），否则会调 `CreateWarningInfobar()` / `CreateWarningMessage()`——桌面端是横幅（`chrome/browser/extensions/api/debugger/debugger_api.cc`、`extension_dev_tools_infobar_delegate.cc`）。
2. **与 DevTools 互斥 / 会掉线**：`onDetach` 事件说明 "Fired when browser terminates debugging session for the tab. This happens when either the tab is being closed or **Chrome DevTools is being invoked for the attached tab**."（debugger 文档）⇒ 用户一按 F12 我们的拦截就断。
3. **企业策略（Chrome 155 起更严）**：若管理员配置了 `runtime_blocked_hosts` / `DisableScreenshots` / DLP，`chrome.debugger.attach()` 会在**所有目标**上以 `"Host access is restricted by policy."` / `"Screenshot capture is restricted by policy."` 失败（all-or-nothing 模型），可临时用 `--disable-features=ExtensionDebuggerStrictPolicyRestrictions` 回退，该开关 Chrome 160 移除。<https://developer.chrome.com/blog/debugger-enterprise-policy-restrictions>
4. **需要 debugger 权限、且不需要 host 权限**：官方把 `chrome.debugger` 列为"host permissions 不需要"的特例（<https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions>）；源码注释亦写 "The `debugger` permission implies all URLs access (and indicates such to the user), so we don't check explicit page access."（`debugger_api.cc`）⇒ **安装时警告很吓人**（**推断**）。
5. **性能与开发复杂度**：每个被拦截请求都要被暂停并往返一次扩展进程（CDP 往返 + `base64` 编解码）。文档没给性能数字（**未验证**），但 `Fetch.enable` 的语义就是"暂停直到客户端响应"（协议原文）。
6. **协议版本**：`attach(target, requiredVersion)` 需要与浏览器协议主版本匹配（文档 `attach()`）；不同 Chrome 版本间行为需自行兼容（**推断**）。

**现成扩展用的就是它**

- **Tamper Dev**（Chrome Web Store `cpcmdnpekbomkhllkbmghhbefjbbjgni`，MV3）：解包后的 manifest 权限**只有** `debugger, activeTab, scripting`；其 SW 产物里出现 `chrome.debugger`（`background/out/.../debuggee.js`）、`Fetch.enable`（`interception.js`）、`Fetch.continueRequest`、`Fetch.fulfillRequest`（`request.js`）。产品自述："Unlike most other extensions, Tamper Dev allows you to intercept, inspect and modify the requests before they are sent to the server."（<https://tamper.dev/>）

---

### 2.5 content script 在 JS 层改写

**原理**：把拦截代码注入**页面世界（MAIN world）**，覆盖 `window.fetch` / `XMLHttpRequest`（原型或构造器）/ `WebSocket` 构造器等，命中规则时**不调用原生实现**，直接构造返回值。

**Chrome 官方提供的注入面**

- manifest `content_scripts[].world`（默认 `ISOLATED`）：官方说明 "The JavaScript world for a script to execute within. Defaults to `ISOLATED`."（<https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts>）
- `chrome.scripting.executeScript({target, world, func|files})`：`ExecutionWorld` = `ISOLATED` / `MAIN`（<https://developer.chrome.com/docs/extensions/reference/api/scripting>）
- `chrome.userScripts.register({world: 'MAIN' | 'USER_SCRIPT'})`（Chrome 120+，且用户在扩展详情页打开 "Allow User Scripts"）：官方原文 "Both user and content scripts can run in an isolated world or in the main world. ... Scripts running in the main world are accessible to host pages and other extensions and are visible to host pages and to other extensions."（<https://developer.chrome.com/docs/extensions/reference/api/userScripts>）
- **时序**：`run_at: "document_start"` = "Script is injected after any files from css, but before any other DOM is constructed or **any other script is run**."（<https://developer.chrome.com/docs/extensions/reference/api/extensionTypes>）。同阶段内静态声明的 content script 最先注入，且按 manifest 顺序（content-scripts 文档）。
- **CSP**：MAIN world 注入受页面 CSP 约束——官方原文 "When a content script is injected into the main world, the CSP of the page applies."（content-scripts 文档）
- **隔离世界不可见**：官方原文 "An **isolated world** is a private execution environment that isn't accessible to the page or other extensions. A practical consequence of this isolation is that JavaScript variables in an extension's content scripts are not visible to the host page or other extensions' content scripts."（同页）⇒ **推断**：在隔离世界改 `fetch`/`XMLHttpRequest` 对页面（以及别的扩展）无效，所以"JS 层劫持"必须落在 MAIN world。

**覆盖范围**

- 页面上所有走标准 JS API 的请求：`fetch`、`XMLHttpRequest`（异步且改写正确时也包括同步）、`WebSocket`（需另打构造器）、`EventSource`、`navigator.sendBeacon` 等——**每一个都要单独打补丁**（**推断**，来自"JS API 层"定义）。
- **打不到**：`<img>`/`<video>`/`<iframe>`/导航等由浏览器自身发起的请求；Worker / Service Worker 里的请求（不同全局）；`document_start` 之前已执行的代码；页面用原生引用绕过（先保存了原始 `fetch` 引用）；**别的扩展的隔离世界**里的调用。

**真实产品证据（重点）**

- **Requestly** 的 MV3 包（v26.9.29）里有一份 **MAIN world 页面脚本** `page-scripts/ajaxRequestInterceptor.ps.js`（SW 中 7 处 `world:"MAIN"`、`chrome.scripting` 的 `registerContentScripts` / `executeScript`）：
  - 覆盖 XHR：`XMLHttpRequest.prototype.open/send/setRequestHeader/abort` 以及 `XMLHttpRequest.prototype = rqProxyXhr` 这类构造器级替换；
  - 覆盖 fetch：`const t = fetch; fetch = async (...r) => { ... }`，并在命中"本地响应"规则时返回 **`new Response(m ? null : new Blob([f]), {status, statusText, headers})`**——即**自己造一个 Response**；
  - 同时用 DNR 的 `updateDynamicRules` / `updateSessionRules` 做网络层规则。
  （以上为对 CRX 解包产物 `page-scripts/ajaxRequestInterceptor.ps.js`、`serviceWorker.js` 的核对；商店页 <https://chromewebstore.google.com/detail/requestly-intercept-modif/mdnleldcmiljblolnjhpnblkcekpdkpa>）

---

### 2.6 其它现成扩展逐个查证（用了什么手段）

| 扩展 | 出处 / 版本 | 用了哪些 API（已核对产物或源码） | 原理 | 覆盖范围 | 局限 |
|---|---|---|---|---|---|
| **Requestly** | CRX `mdnleldcmiljblolnjhpnblkcekpdkpa` v26.9.29（MV3） | `declarativeNetRequest`（+静态 ruleset delay/header）、`webRequest`（观测）、`scripting`（MAIN world）、`proxy`、`tabs`、`webNavigation` | 网络层 DNR + **页面 JS 层 hook fetch/XHR** 双管齐下；JS 层可返回自造 `Response` | 页面内的 fetch/XHR（含 mock body）；网络层的 block/redirect/改头 | 仍是"页面 JS 层"局限（Worker/SW、注入前请求、别的扩展）；DNR 不能造 body |
| **ModHeader V3** | CRX `cndlnhnjdlmipaflgajjikndbfkfnohp` v2026.8.8.18（MV3） | **仅** `declarativeNetRequest` + `storage` + clipboard；`host_permissions: <all_urls>`；无 content script / 无 debugger | 纯 DNR `modifyHeaders`（请求头+响应头），动态/会话规则 | 所有命中 URL 的请求/响应头 | 不能造 body、不能改 URL 语义之外的响应、设计上不读内容 |
| **Tamper Dev** | CRX `cpcmdnpekbomkhllkbmghhbefjbbjgni` v2（MV3） | **`debugger`** + `activeTab` + `scripting`；CDP `Fetch.enable/continueRequest/fulfillRequest` | 调试协议层拦截，请求发出前暂停并可伪造整个响应 | 附着 tab（及可挂的 worker/frame）内所有匹配请求 | 调试横幅、DevTools 互斥、企业策略、每次拦截走 IPC |
| **Resource Override** | GitHub `master` manifest v1.3.2（**MV2**） | `webRequest`+`webRequestBlocking`+(`<all_urls>`)+`tabs`；content script `scriptInjector.js`（`document_start`, all_frames）；后台 blocking 监听 | 网络层 redirect / `data:` 造 body / Firefox `filterResponseData` 改写 body；另注入脚本改写页面内容 | 所有标签页请求（网络层） | MV2，Chrome 上已不可用；只能整段替换文件内容 |
| **Redirector** | GitHub `master` manifest（**MV2**） | `webRequest`+`webRequestBlocking`+`webNavigation`+`tabs` | `onBeforeRequest` 返回 `{redirectUrl}` | 所有标签页请求 | 只做 URL 重定向；MV2 |
| **Tampermonkey** | 文档 <https://www.tampermonkey.net/documentation.php?locale=en&q=unsafeWindow> | userscript 运行世界由 `@sandbox` 控制：`raw`=MAIN_WORLD（默认）、`JavaScript`=需 `unsafeWindow`（Firefox 用 USERSCRIPT_WORLD 并绕 CSP）、`DOM`=ISOLATED_WORLD | userscript 直接在页面世界改写 JS；`unsafeWindow` 即"页面那个 window" | 取决于脚本；可 hook 页面的 fetch/XHR | 需要用户装脚本；MAIN world 注入可能因 CSP 失败（文档明说会按顺序降级到其它 sandbox） |
| **Violentmonkey** | GitHub `src/manifest.yml`（jsdelivr 最新 tag 2.49.4）**MV2** | `webRequest`+`webRequestBlocking`+`<all_urls>`+`tabs`；content scripts `injected-web.js`+`injected.js`，`document_start`、`all_frames`；`wrappedJSObject` 处理 Firefox Xray | 与 TM 同路：内容脚本做桥，页面世界脚本做改写 | 同 TM | 同 TM；本仓库的 manifest 是 MV2（其 MV3 发行包本次**未验证**） |
| **Tamper Chrome（历史）** | 由 Tamper Dev 官网指向 <https://github.com/google/tamperchrome> | Chrome Debugger Extension（历史项目） | CDP 拦截 | 同 Tamper Dev | 已归档/被新项目取代（tamper.dev 页面自称是 "the new version"） |

---

## 3 第二问：fetch / XHR 封装劫持的现有做法

### 3.0 逐库总表

| 库 | 出处（版本） | 改构造器还是原型方法 | 拦截点 | 能否伪造响应 | 抗检测性 | 要求的 world |
|---|---|---|---|---|---|---|
| **ajax-hook** | <https://github.com/wendux/ajax-hook>（npm 3.0.3） | **替换全局构造器**（`win.XMLHttpRequest = HookXMLHttpRequest`），并**在实例上**用 getter/setter 包装方法与属性 | `window.XMLHttpRequest` 构造 + 实例的 `open/send/setRequestHeader/abort` 等 | **能**（`handler.resolve(response)` 直接写 `readyState=4` / `status` / `responseText` / headers 并触发事件） | 中：`prototype` 被复用（`instanceof` 仍真），但 `XMLHttpRequest.prototype.constructor` 被改写、实例上多出一堆 own 属性、事件对象是自制 `Event` | **MAIN world** |
| **xhook** | <https://github.com/jpillora/xhook>（npm 1.6.2） | **替换全局构造器**（`windowRef.XMLHttpRequest = Xhook`），自建 facade 实例；同时**替换 `window.fetch`** | `XMLHttpRequest` 全流程 facade；`window.fetch` 包装 | **能**（README 明写 "Simulate responses transparently"，`before` 回调可给出 response） | 中/低：实例是**纯 JS facade**，没有真实 XHR 对象做底，`instanceof` 只对（已被替换的）全局成立 | **MAIN world** |
| **fetch-intercept** | <https://github.com/werk85/fetch-intercept>（npm 2.4.0） | **直接替换全局函数**：`env.fetch = (fetch => ...)(env.fetch)` | 只拦 fetch | 能（`response` 拦截器可替换 Response） | 低：`fetch.toString()` 直接暴露包装源码；无 `toString` 伪装 | **MAIN world**（非 content-script 环境亦可，只要是同一个全局对象） |
| **@mswjs/interceptors** | <https://github.com/mswjs/interceptors>（npm 0.45.7） | XHR：**`new Proxy(globalThis.XMLHttpRequest, {construct})`——构造器代理 + 真实实例 + 逐方法/属性代理**；fetch：`patchesRegistry.applyPatch(globalThis,'fetch',…)` | XHR：`open/send/setRequestHeader/getAllResponseHeaders/…`；fetch：整个 `globalThis.fetch` | 能（`controller.respondWith(new Response(...))`） | 高（相对最好）：XHR 底层是**真实 XHR 实例**并复制原型描述符；但仍用**自制 Event 对象**（`EventPolyfill`/`ProgressEventPolyfill`），且把 `window.fetch` 属性改成 `configurable:true, enumerable:true` 但**未设 `writable`** | **同一 JS 全局即可**（浏览器里就是 MAIN world；库本身有 browser 构建与 `/web` 入口） |
| **sinon / nise** | <https://github.com/sinonjs/nise>（npm nise 6.1.5） | **替换全局构造器**（`useFakeXMLHttpRequest()` 安装 fake `XMLHttpRequest`，文档："Also fakes native XMLHttpRequest and ActiveXObject"） | 全局 `XMLHttpRequest`；`FakeXMLHttpRequest` 自带 `setStatus/setResponseHeaders/setResponseBody/respond/error` | **能**（fake server 语义的核心） | 低（测试库，不追求伪装）：`FakeXMLHttpRequest` 是脚本实现，原型/`toString`/事件都与原生不同 | 测试环境（jsdom/浏览器全局）；要生效必须**在代码保存 `XMLHttpRequest` 引用之前**安装（nise 文档 & xhook README 同款警告） |
| **mock-socket**（WebSocket 补充） | <https://github.com/thoov/mock-socket> | 提供 `WebSocket` 类 + `Server`，通常**显式替换**全局 `WebSocket` | `WebSocket` 构造 | 能（模拟连接/收发） | 低（测试库） | 同一全局（MAIN world） |
| **Tampermonkey `unsafeWindow`** | 文档见 §2.6 | 不属于库，而是"拿到页面 world 的 window 再自己改" | 任意 JS API | 取决于脚本 | 取决于脚本 | MAIN world（`@sandbox raw/JavaScript`）；Firefox 需 `cloneInto`/`exportFunction` 共享对象 |

### 3.1 逐库要点（含源码级证据）

**ajax-hook（3.0.3，`src/xhr-hook.js`）**

- 明确选择"改构造器 + 包装实例"而非改原型，源码注释原文：
  > "We shouldn't hookAjax XMLHttpRequest.prototype because we can't guarantee that all attributes are on the prototype。Instead, hooking XMLHttpRequest instance can avoid this problem."
- 关键实现：`HookXMLHttpRequest.prototype = originXhr.prototype; HookXMLHttpRequest.prototype.constructor = HookXMLHttpRequest; win.XMLHttpRequest = HookXMLHttpRequest;`，并 `Object.assign(win.XMLHttpRequest, {UNSENT:0,…})`（<https://github.com/wendux/ajax-hook/blob/master/src/xhr-hook.js>）。
- 伪造响应：`Handler.resolve(response)` 里直接写 `xhrProxy.readyState=4; status; responseText; statusText;` 再依次触发 `readystatechange` → `load` → `loadend`（<https://github.com/wendux/ajax-hook/blob/master/src/xhr-proxy.js>）。
- **只做 XHR，不碰 fetch**（源码里没有 fetch 相关代码）⇒ 对我们的 RPC 场景必须再补一层 fetch hook。

**xhook（1.6.2，`dist/xhook.js`）**

- 构造器替换：`patch() { if (Native) windowRef.XMLHttpRequest = Xhook; }`；另有 `fetch` 模块 `patch() { if (Native) windowRef.fetch = Xhook; }`，`xhook.enable()` 同时打这两个补丁（<https://github.com/jpillora/xhook/blob/master/dist/xhook.js>）。
- facade 是自建对象（源码注释 "openning facade xhr (not real xhr)"），事件由自己的 emitter `dispatchEvent` 派发，并 `Object.defineProperty(args[0],"target",{writable:false,value:this})` 修补 `target`。
- README 特性列表含 "Simulate **responses** transparently" 与 "Backwards compatible `addEventListener`"（<https://github.com/jpillora/xhook>）。
- README 的重要警告（对我们的注入时序直接相关）："It's **important** to include XHook first as other libraries may store a reference to `XMLHttpRequest` before XHook can patch it."

**fetch-intercept（2.4.0，`lib/browser.js`）**

- `env.fetch = function (fetch) { return function () { return interceptor(fetch, ...args) } }(env.fetch)`——**直接赋值替换**全局 `fetch`；拦截器数组按注册顺序执行，`request` 可改 url/config，`response` 可替换整个 Response（<https://github.com/werk85/fetch-intercept>）。
- 无任何 `toString`/描述符伪装；README 亦要求"在使用 fetch 之前 require"。

**@mswjs/interceptors（0.45.7）**

- 定位说明（README）："Low-level network interception library for Node.js."，但 `FetchInterceptor` 章节原文："Intercepts HTTP requests made via the global `fetch` function. In Node.js, the global `fetch` is powered by Undici; **in the browser, it is the native `window.fetch`**."；XHR 章节原文："Intercepts HTTP requests made via `XMLHttpRequest`, **both in the browser and in Node.js**"。两个拦截器都有 `/node` 与 `/web` 两个版本（`package.json` 的 `exports` 里 `.` 映射到 `./lib/browser/index.js`，`./XMLHttpRequest` 也有 browser 分支）。
- XHR 实现（`src/interceptors/XMLHttpRequest/xml-http-request-proxy.ts`，从 npm 包的 sourcemap 还原）：
  ```ts
  const XMLHttpRequestProxy = new Proxy(globalThis.XMLHttpRequest, {
    construct(target, args, newTarget) {
      const originalRequest = Reflect.construct(target, args, newTarget) as XMLHttpRequest
      // Forward prototype descriptors onto the proxied object.
      const prototypeDescriptors = Object.getOwnPropertyDescriptors(target.prototype)
      for (const propertyName in prototypeDescriptors) {
        Reflect.defineProperty(originalRequest, propertyName, prototypeDescriptors[propertyName])
      }
      ...
      return xhrRequestController.request
    },
  })
  ```
  ⇒ 底层是**真实 XHR 实例**（`instanceof XMLHttpRequest` 成立），但对外是 Proxy。
- **同步 XHR 明确不支持**（`xml-http-request-controller.ts`，`send` 分支）：
  ```ts
  if (this.sync) {
    console.warn(`Failed to intercept an XMLHttpRequest (${this.method} ${this.url}): synchronous requests are not supported. This request will be performed as-is.`)
    return invoke()   // 直接放行到真实网络
  }
  ```
- 事件对象是自制类：`EventPolyfill`（自己声明 `isTrusted = true`、`target`、`composedPath()` 返回 `[]`…）与 `ProgressEventPolyfill`；`create-event.ts` 对 progress 类事件优先用真 `ProgressEvent`（浏览器里存在），其它用 `EventPolyfill`。
- fetch 补丁的安装方式（`src/utils/patches-registry.ts`）：
  ```ts
  if (match.descriptor.configurable) {
    Object.defineProperty(owner, key, { value: getNextValue(owner[key]), enumerable: true, configurable: true })
  }
  ```
  注意**没有传 `writable`** ⇒ 默认 `false`（**推断**：`Object.getOwnPropertyDescriptor(window,'fetch').writable` 从 `true` 变 `false`，这是一个可被页面检测到的差异）。该文件还实现了 `restorePatch()` 做还原。
- `has-configurable-global.ts`：若全局属性不可配置则报错并放弃拦截（"Failed to apply interceptor: the global `fetch` property is non-configurable."）。

**sinon / nise（nise 6.1.5）**

- nise 文档原文："Provides a fake implementation of XMLHttpRequest and provides several interfaces for manipulating objects created by it. **Also fakes native XMLHttpRequest and ActiveXObject**（when available, and only for XMLHTTP progids）."；API 含 `setStatus / setResponseHeaders / setResponseBody / respond / error / autoRespond / autoRespondAfter`（<http://sinonjs.github.io/nise/>）。
- 实现是纯 JS 的 `function FakeXMLHttpRequest(config) {...}`（`lib/fake-xhr/index.js`），有 `FakeXMLHttpRequest.defake()` 用于"把 fake 转成真 XHR 再跑"的桥接。
- 关键限制（**推断**自其设计 + xhook/fetch-intercept README 的同款警告）：必须**先于被测代码**替换全局构造器，否则代码里保存的引用会绕过 fake。

**WebSocket 的对应做法（补充）**

- 浏览器层：Chrome blocking `webRequest` 只能看握手、**不支持 WS 重定向、不拦消息**（webRequest 文档）；DNR 的 `resourceTypes` 含 `websocket`（DNR 文档 ResourceType 枚举）。
- JS 层：`mock-socket` 提供可替换的 `WebSocket` 类与 `Server`（<https://github.com/thoov/mock-socket>），这是"在 MAIN world 用自造 WebSocket 类顶替原生构造器"的现成实现。**未验证**：能否完整复刻 `readyState`/`bufferedAmount`/二进制帧/子协议协商等语义而不被页面识破。

### 3.2 改「构造器」还是「原型方法」——差异与代价

| 手法 | 实例真实性 | `instanceof` | 例子 | 主要破绽 |
|---|---|---|---|---|
| 替换全局构造器（真实例做底） | 真 XHR 对象在内部 | 成立（因为换了全局，且原型复用） | ajax-hook、msw（Proxy construct）、nise | `XMLHttpRequest.prototype.constructor` 被改写；实例上出现 own 属性/描述符与原生不同 |
| 替换全局构造器（自建 facade） | 完全假的 JS 对象 | 只对"被替换后的全局"成立 | xhook | 原生原型链、内部槽、事件对象全部缺失 |
| 只改原型方法 | 真实例 | 成立 | （本问未找到主流库纯用此法；ajax-hook 源码解释为何不用） | 当属性在实例上而非原型上时漏 hook |
| 直接替换全局函数（fetch） | 返回真 `Response`（构造） | 成立 | fetch-intercept、msw、Requestly | `fetch.toString()` / 属性描述符 / `name`、`length` |

### 3.3 让伪造不被识破：具体要处理什么（每条给依据）

1. **`Response` 用真构造函数造**：Requestly 造 `new Response(new Blob([f]), {status, statusText, headers})`（CRX 产物）；msw 用 `new FetchResponse(...)`（`create-response.ts`）。这样 `instanceof Response`、`response.json()/text()` 语义天然成立。
2. **`toString` 不能暴露包装源码**：`Function.prototype.toString` 返回函数源码（MDN：<https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Function/toString>），原生函数会显示 `[native code]`。对抗手段在世界里已有成熟实现：puppeteer-extra-plugin-stealth 的 `_utils/index.js` 用 `Function.toString + ''` 缓存原生模板，生成 `function <name>() { [native code] }`（`makeNativeString`），并代理 `Function.prototype.toString`（`patchToString`/`redirectToString`），源码注释还提醒"Whenever we add a `Function.prototype.toString` proxy we should preload the cache before"。<https://github.com/berstend/puppeteer-extra/blob/master/packages/puppeteer-extra-plugin-stealth/evasions/_utils/index.js>
3. **属性描述符要与原生一致**：msw 的 `patchesRegistry` 用 `defineProperty` 但漏了 `writable`（见上）；原生 `window.fetch` 是 `writable:true, enumerable:true, configurable:true`（**推断**：这是 Web IDL/规范里全局函数属性的一般形态）。ajax-hook 在实例上用 `Object.defineProperty(this, attr, {get,set,enumerable:true})`——`configurable` 默认 `false`（**推断**自 `Object.defineProperty` 默认值），而原生 XHR 属性在原型上、通常 `configurable:true`。
4. **`instanceof` 双向检查**：页面既可能检查 `xhr instanceof XMLHttpRequest`（换了全局就成立），也可能持有**原始构造器引用**再检查（`originalXHR instanceof ...` 不被骗）——所以"劫持必须早于页面保存引用"（xhook/README、fetch-intercept/README 都强调）。
5. **事件时序与事件对象**：
   - 原生异步 XHR 的 `readystatechange` 是 task 级异步，`load`/`loadend` 在 DONE 之后按序派发；`onprogress` 在 LOADING 期间多次触发。
   - 伪造时的常见破绽：手写 `Event` 而非真 `ProgressEvent`（ajax-hook 用 `new Event(name)`，并对 `addEventListener` 监听者派发在**游离的 `<a>` 元素**上：`getEventTarget(xhr)` = `document.createElement('a')`）；msw 的 `EventPolyfill` 把 `isTrusted` 写成 `true`（真 `new ProgressEvent()` 的 `isTrusted` 是 `false`——**推断**，依据 `isTrusted` 的定义：只有 UA 派发的事件为 true）。
   - **推断**：`event.target`/`currentTarget`/`isTrusted`/`lengthComputable`/`loaded`/`total`、以及 `upload` 上的事件，是最容易被页面拿来对比的地方。
6. **同步 XHR**：`XMLHttpRequest.open(method,url,false)` 的同步语义要求"`send()` 返回时响应已就绪"。msw 选择**放弃拦截并放行到真实网络**（源码原话，见上），ajax-hook 因为包装 `send()` 且可以完全不调用原生实现，理论上可以立刻写入结果（其 `resolve()` 同步写字段并触发事件）——**推断**：同步 XHR 在 JS 层是**可以**被完整伪造的，但库之间做法不同；且 MDN 明确 "Synchronous XHR is now deprecated and should be avoided"、同步模式下 `timeout`/`abort` 等新特性还会抛 `InvalidAccessError`（<https://developer.mozilla.org/en-US/docs/Web/API/XMLHttpRequest/Synchronous_and_Asynchronous_Requests>）。
7. **`readyState` / `status` / `getAllResponseHeaders()` 的一致性**：msw 对 `getAllResponseHeaders` 打了 Proxy，未到 `HEADERS_RECEIVED` 时返回空串（源码），这是"贴近规范"的做法；伪造时要保证 `status=0` 与 `error` 路径、`responseType`（`arraybuffer`/`blob`/`json`/`text`）与 `response`/`responseText` 的互斥规则自洽（**推断**，来自 XHR 规范语义）。

### 3.4 页面检测自己被 hook 的常见手段（含可行反制）

> 下面每条的"检测手段"都可以由 3.1/3.3 的实现事实直接推出；标注「来源」者表示有明确出处，「推断」者表示由来源逻辑推出。

| # | 检测手段 | 依据 | 反制 |
|---|---|---|---|
| D1 | `fetch.toString()` / `XMLHttpRequest.prototype.open.toString()` 里是否含 `[native code]` | MDN `Function.prototype.toString`；msw/fetch-intercept/Requestly 都是普通 JS 函数 | 代理 `Function.prototype.toString`，返回缓存的 native 模板（stealth 的 `makeNativeString`） |
| D2 | `Object.getOwnPropertyDescriptor(window,'fetch')` 的 `writable/configurable/enumerable` | msw `patchesRegistry` 只设 `enumerable/configurable`（来源） | 显式补齐三个描述符；或改用 `Proxy` 包住原函数而不改属性 |
| D3 | `Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype,'constructor').value` 与全局构造器是否一致 | ajax-hook 改写 `prototype.constructor`（来源） | 不要动 `prototype.constructor`；用 Proxy 构造器（msw 路线） |
| D4 | `xhr.hasOwnProperty('readyState')`、实例 own 属性数量 | ajax-hook 在实例上 defineProperty（来源） | 尽量把补丁放在 Proxy `get` 陷阱里（对外表现为原型属性） |
| D5 | 事件对象：`evt instanceof ProgressEvent`、`evt.isTrusted`、`evt.target === xhr`、`composedPath()` | ajax-hook 的 `<a>` 派发与自制 `Event`；msw 的 `EventPolyfill`（来源） | 用真 `ProgressEvent`/`Event` 构造并正确设 `target`；`isTrusted` 无法伪造（**推断**：只读且由 UA 置位）——属于**不可完全消除**的破绽 |
| D6 | 保存原生引用再比对（`const realFetch = fetch` 在注入前执行） | xhook/fetch-intercept README 的"必须先注入"警告（来源） | 靠 `document_start` 抢先注入；对已保存引用的页面无解 |
| D7 | 直接实例化原始构造器做对照（比如自己 `new XMLHttpRequest()` 看事件时序、请求是否真的上网） | 任意 JS 层伪造都是"旁路"（**推断**） | 无通用解；只能保证"命中与未命中两条路的行为尽量一致" |
| D8 | 检查 `Object.prototype.toString.call(x)` / `Symbol.toStringTag`、`x.constructor` | Web IDL 原型语义（**推断**） | Proxy + 真实例底层（msw 路线）最稳 |

---

## 4 第三问：能否拦截或修改「其它扩展」发出的网络请求

> 本节的每一条都按 **能 / 不能 / 有条件** 给结论，并给出证据（官方文档或 Chromium 源码，含版本核对）。

### 4.1 content script 能不能注入 `chrome-extension://` 页面？

**结论：不能（自己家的、别人家的都不能用 content script 注入）。**

- **Chrome match pattern 的合法 scheme 只有 `http` / `https` / `*`（仅 http/https）/ `file`**（官方原文："**scheme**: Must be one of the following... `http` / `https` / A wildcard `*`, which matches only `http` or `https` / `file`"）。`<all_urls>` 也只匹配"a permitted scheme"。<https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns>
- **Chromium 源码：user script 的合法 scheme 集合里没有 `SCHEME_EXTENSION`**（`extensions/common/user_script.cc`）：
  ```cpp
  enum {
    kValidUserScriptSchemes = URLPattern::SCHEME_CHROMEUI |
                              URLPattern::SCHEME_HTTP | URLPattern::SCHEME_HTTPS |
                              URLPattern::SCHEME_FILE | URLPattern::SCHEME_FTP |
                              URLPattern::SCHEME_UUID_IN_PACKAGE
  };
  ```
  （`ValidUserScriptSchemes()` 仅在 `can_execute_script_everywhere` 时返回 `SCHEME_ALL`；chrome:// 还要 `--extensions-on-chrome-urls` 才放开。）<https://chromium.googlesource.com/chromium/src/+/main/extensions/common/user_script.cc>
- 对比：**Firefox 的 match pattern 文档把 `(chrome-)extension` 列为合法 scheme**（<https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Match_patterns>），且明确提示"Some browsers don't support certain schemes"。**未验证**：Firefox 里是否真的允许扩展往**别的**扩展页面注入（**推断**：即便语法允许，实际注入仍会被扩展页面互相隔离的安全模型拦下；未找到官方明文）。
- **对本项目的含义**：内置 AriaNg UI 如果以 `chrome-extension://<我们的 id>/…` 打开，**不能用 content script 注入**；R5 已经预留了"扩展页注入失败时只换装载方式"的例外条款。**未验证**：`chrome.scripting.executeScript({target:{tabId}})` 对"自己的扩展页"是否放行（本次没有找到官方明文或源码结论；但如果能放行，它仍然算"另一种方式加载那个转发器"，可在 R5 例外范围内）。

### 4.2 `chrome.webRequest` 能不能看到并改写由其它扩展发起的请求？

**结论：不能（Chrome 117+ 起在监听器分发阶段就被过滤；MV3 里连"改写"本身都没有了）。**

1. **改写能力**：MV3 无 `webRequestBlocking`（除策略安装扩展）——见 §2.1。
2. **可见性（官方文档，注意：这一条说的是"请求的 URL 是别的扩展"，不是"发起者是别的扩展"）**：webRequest 文档在列出可访问 scheme 后紧接着写：
   > "In addition, even certain requests with URLs using one of the above schemes are hidden. These include **`chrome-extension://other_extension_id` where `other_extension_id` is not the ID of the extension to handle the request**..."（<https://developer.chrome.com/docs/extensions/reference/api/webRequest>）
3. **发起者权限（官方文档）**："Starting from Chrome 72, an extension will be able to intercept a request only if it has host permissions to both the requested URL and the request initiator."（同页）。而 host permission 只能写 match pattern（scheme 限 http/https/file）⇒ **无法对 `chrome-extension://<别的扩展>` 取得 host 权限**（<https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions>、match patterns 同链接）。
4. **决定性证据（Chromium 源码）**：`ListenerMatchesRequest()` 直接按渲染进程过滤"来自扩展的请求"：
   ```cpp
   // Filter requests from other extensions / apps. This does not work for
   // content scripts, or extension pages in non-extension processes.
   if (is_request_from_extension &&
       listener.id.render_process_id != request.global_id.child_id) {
     return false;
   }
   ```
   而 `is_request_from_extension` 由 `IsRequestFromExtension()` 判定："把发起进程映射到一个已启用扩展"：
   ```cpp
   const Extension* extension = ProcessMap::Get(context)->GetEnabledExtensionByProcessID(request.global_id.child_id);
   return extension && !extension->is_hosted_app();
   ```
   出处：<https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/web_request/extension_web_request_event_router.cc>
   **版本核对**（本次逐 tag 抓取）：`116.0.5845.0` **无**该过滤；`117.0.5938.0` 及之后（120/128/138）**有** ⇒ **Chrome 117 起生效**。
5. **有条件的一条**：注释自己说明该过滤"**does not work for content scripts, or extension pages in non-extension processes**"。⇒ 若第三方扩展是**通过它的 content script 在普通网页里**发出请求，那么该请求的渲染进程属于网页、`is_request_from_extension=false`，我们**可以**在（MV2 blocking 或）观测型 webRequest 里看到它（前提是有 URL 与 initiator 的 host 权限）。**推断**：这一条对"第三方扩展自己从扩展页/SW 发 RPC"的场景无效。
6. **历史注记**：Chrome ≤116 的 MV2 blocking webRequest **没有**该进程过滤 ⇒ 理论上当时能拦到别的扩展的请求（仍需 initiator 的 host 权限，而 `chrome-extension://` host 权限不可得 ⇒ 实际上依然拦不到，除非策略安装）。**未验证**：是否存在通过企业策略安装扩展拿到 `chrome-extension://` 主机权限的路径。

### 4.3 `declarativeNetRequest` 能不能看到并改写由其它扩展发起的请求？

**结论：不能（两层过滤都在源码里）；且 `chrome-extension://` 作为 URL 永远不会被 DNR 匹配。**

`RulesetManager::ShouldEvaluateRulesetForRequest()` 在匹配前做两道检查（<https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/declarative_net_request/ruleset_manager.cc>）：

```cpp
// Prevent extensions from modifying any resources on the chrome-extension
// scheme. Practically, this has the effect of not allowing an extension to
// modify its own resources (The extension wouldn't have the permission to
// other extension origins anyway).
if (request.url.SchemeIs(kExtensionScheme)) {
  return false;
}
...
// Extensions should not generally have access to non-main-frame requests
// initiated by other extensions, though the --extensions-on-chrome-urls
// switch overrides that restriction.
if (!switches::AreExtensionsOnExtensionURLsAllowed() && request.initiator &&
    request.web_request_type != WebRequestResourceType::MAIN_FRAME) {
  auto initiator_precursor = request.initiator->GetTupleOrPrecursorTupleIfOpaque();
  if (initiator_precursor.scheme() == kExtensionScheme &&
      initiator_precursor.host() != ruleset.extension_id) {
    return false;
  }
}
```

**版本核对**（本次逐 tag 抓取 `ruleset_manager.cc`）：`initiator_precursor.scheme() == kExtensionScheme` 这一条在 `128.0.6613.84` **无**，在 `130.0.6723.1`、`132`、`135`、`138`、`main` **有** ⇒ **Chrome 129/130 前后引入**（本次未逐个小版本二分，精确到 129 或 130 之一）。

由此得三条：

1. **不能**：DNR 规则不会对「由另一个扩展发起的非 main_frame 请求」（XHR/fetch/子资源）求值——这正是第三方 aria2 前端扩展发 RPC 的形态。
2. **不能**：URL 为 `chrome-extension://…` 的请求（无论谁的）一律不求值 ⇒ 即便 `regexFilter` 写成 `^chrome-extension://` 也不会命中，`UUIDTransform.scheme` 里的 `"chrome-extension"` 只是"重定向到扩展资源"的允许 scheme，不是"匹配扩展 URL"。
3. **有条件**：**main_frame 导航**由别的扩展发起时不受第 2 条 initiator 过滤（源码里的 `!= MAIN_FRAME` 例外），但这类请求 URL 不能是 `chrome-extension://`，且 DNR 依旧只能 block/redirect，不能造响应体。

补充：`initiatorDomains` 语义是"域名"——官方原文 "The rule will only match network requests originating from the list of `initiatorDomains`. ... Notes: Sub-domains like `a.example.com` are also allowed. The entries must consist of only ascii characters. ... This matches against the request initiator and not the request url."（DNR 文档）。**推断**：`chrome-extension://abc…` 不是一个"域名"，因此无法用 `initiatorDomains` 表达这种发起者；这层表达能力的缺失与源码里的 initiator 过滤是两道独立闸门。

### 4.4 `chrome.debugger` 能不能附加到「恰好在一个标签页里打开的」其它扩展页面？

**结论：不能（除非浏览器以特殊开关启动）。自己家的扩展页面可以。**

Chromium 源码 `ExtensionMayAttachToURL()`（`chrome/browser/extensions/api/debugger/debugger_api.cc`）：

```cpp
bool allow_on_extension_urls = ::extensions::switches::AreExtensionsOnExtensionURLsAllowed();
if (url_for_restriction_check.SchemeIs(extensions::kExtensionScheme) &&
    url_for_restriction_check.host() != extension.id() &&
    !allow_on_extension_urls) {
  *error = manifest_errors::kCannotAccessExtensionUrl;
  return false;
}
```

`AreExtensionsOnExtensionURLsAllowed()` 只在进程带 `--extensions-on-extension-urls` 或 `--extensions-on-chrome-urls` 时才返回 true（`extensions/common/switches.cc`）。

另外几条相关的硬限制（同一文件 / 官方文档）：

- **后台页**：`Debuggee.extensionId` 的说明——"Attaching to an extension background page is only possible when the `--silent-debugger-extension-api` command-line switch is used."（debugger API 文档）
- **WebUI**：attach 走到 WebUI 帧时直接拒绝（`*error = manifest_errors::kCannotAccessChromeUrl`）。
- **worker**：会校验 parent target 的 URL（防止从受限页面 spawn 的 worker 绕过）。
- **自己家的页面**：`host() != extension.id()` 的条件说明**自己的扩展 URL 是放行的**。
- **即使允许，也仍要付出**调试横幅、DevTools 互斥、企业策略（§2.4）的代价。

### 4.5 还有没有别的 API / 机制？

| 机制 | 能拦别的扩展的请求吗 | 证据 / 说明 |
|---|---|---|
| `chrome.runtime.onMessageExternal` / `externally_connectable` | **不能**（要求对方向我们发消息，即要求对方配合） | 语义是"外部消息"而非请求拦截；我们自己的 Requestly 包里 `externally_connectable` 只列出白名单 id（CRX 核对），说明它也不是拦截机制 |
| `chrome.management` | 不能（只能禁用/卸载/启用） | API 语义；不在本次调研重点（**未验证**具体能力边界） |
| `chrome.proxy`（PAC / 固定代理） | **有条件且不适用**：可以把流量导向一个真实代理进程，但扩展**不能监听端口**（R8 已裁定），所以仍然要依赖浏览器外的进程；且拿不到"逐请求 JS 动态响应" | Chrome 的 `proxy` API 是设置代理配置，不是响应生成器。**未验证**：是否存在纯浏览器内的 PAC→扩展资源路径 |
| `chrome.devtools.network` / `devtools.inspectedWindow` | **不能**（只有用户打开 DevTools 且只对被检查 tab，且 `getHAR` 是事后读取） | API 语义（**未验证**细节） |
| `chrome.webRequest` 的 `webRequestAuthProvider` / onAuthRequired | 不能 | 只处理认证（**未验证**是否覆盖扩展请求；**推断**：同样受 §4.2 的过滤影响） |
| `chrome.downloads` / DNR 强制下载 | 与本问无关（引擎层手段，见附录 A 的样例） | — |
| **把第三方前端当普通网页跑** | **能（唯一实际可行的一条）**：若前端页面是 `http(s)://` 网页，我们的 MAIN world 注入可以 hook 它的 fetch/XHR，在请求发出前短路 | 见 §6（这也是"为什么必须自带 UI"的答案） |

### 4.6 围绕实际动机的结论：第三方 aria2 前端扩展连 `localhost:6800`，我们能接住吗？

**结论：不能（对"扩展形态的第三方前端"）。**

推理链（每条依赖前文已给证据）：

1. 第三方前端扩展发 RPC 的位置只可能是它自己的扩展上下文（扩展页 / SW / offscreen）或它自己的 content script。
2. 若是**扩展页 / SW**：`chrome-extension://<它的 id>` 页面不能被我们注入（§4.1）；它发出的请求会被 webRequest 的进程过滤挡掉（§4.2），被 DNR 的 initiator 过滤挡掉（§4.3），debugger 也 attach 不上去（§4.4）。**⇒ 接不住。**
3. 若它**在自己的 content script（隔离世界）**里发请求：该请求的渲染进程属于网页，网络层**能**看见（§4.2 第 5 点）；但我们在 MAIN world 打的 `fetch`/`XHR` 补丁**对它无效**（官方对隔离世界的明文是"各 world 的 JS 变量互不可见"，见 §2.5；**推断**：同一隔离模型意味着各 world 的全局绑定与原型补丁也不共享）。**⇒ 只能"网络层看见/在 MV2 下改写"，不能"在 JS 层短路"；MV3 下连改写都没有。**
4. 若第三方前端是**普通网页**（自建 AriaNg、`file://`、或某个 web 服务）：MAIN world 注入可以完整接管（§2.5、§3）。**⇒ 能，且这是 R9 想要的形态。**
5. **结论**：想让"任何第三方 aria2 前端都能接到我们的 Mock 层"，**不能**依赖"去拦它"；可行的是①我们自带 UI（R4.2/R5），或②请用户把前端当普通网页打开/用我们的转发器注入该页面。

---

## 5 硬约束（逐条给证据）

| # | 约束 | 证据 |
|---|---|---|
| C1 | 扩展**不能监听 TCP 端口**，因此只能服务"浏览器内的 JS 客户端" | 概念文档 R8 已裁定；Chrome 扩展 API 参考清单中不存在任何 socket/监听类 API（扩展 API 列表见 <https://developer.chrome.com/docs/extensions/reference/api>，无非扩展（Chrome Apps）专用的 sockets 之外无对应项）。**未验证**：Chrome Apps 的 `chrome.sockets.*` 现状（Chrome Apps 平台已废弃）——本次未取得该页面的可用 URL |
| C2 | Chrome MV3 中 blocking `webRequest` 不可用（策略安装扩展例外） | <https://developer.chrome.com/docs/extensions/reference/api/webRequest> |
| C3 | Chrome 上 MV2 整体已死：138 是最后一个支持版本，139 起失效，2026-08-31 从商店移除 | <https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline> |
| C4 | DNR **没有任何**"提供响应体"的能力；redirect 的 scheme 变换只允许 http/https/ftp/chrome-extension；redirect 到 JS URL 被禁止；响应阶段拦截时请求已发出 | <https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest>（Rule / Redirect / URLTransform / Rule evaluation 各节） |
| C5 | DNR 只对"到达网络栈"的请求生效；SW 自己生成的响应与 CacheStorage 不在其内（但 SW 里的 `fetch()` 会被影响） | 同上 "Interactions with service workers" |
| C6 | `chrome.debugger` 会显示用户可见警告（桌面横幅/Android 消息），除非 `--silent-debugger-extension-api` 或策略安装；打开 DevTools 会 detach | `chrome/browser/extensions/api/debugger/debugger_api.cc`（`Attach()`、`CreateWarningInfobar()`）；<https://developer.chrome.com/docs/extensions/reference/api/debugger>（`onDetach`） |
| C7 | Chrome 155 起，企业策略会**全有或全无**地封禁 `chrome.debugger.attach()` | <https://developer.chrome.com/blog/debugger-enterprise-policy-restrictions> |
| C8 | `chrome.debugger` 不能 attach 到别的扩展的页面（除非特殊开关）；不能 attach 扩展后台页（除非 `--silent-debugger-extension-api`）；WebUI 帧直接拒绝 | `debugger_api.cc`；debugger API 文档 `Debuggee.extensionId` |
| C9 | content script 的 match pattern 不支持 `chrome-extension://`；MAIN world 注入受页面 CSP 约束；`document_start` 只保证"在页面第一个脚本之前" | <https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns>；<https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts>；<https://developer.chrome.com/docs/extensions/reference/api/extensionTypes> |
| C10 | MAIN world 的补丁与隔离世界互不可见（页面/其它扩展的 content script 都看不到我们的变量，反之亦然） | <https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts>（"Work in isolated worlds"）；<https://developer.chrome.com/docs/extensions/reference/api/userScripts>（"Scripts running in the main world are accessible to host pages and other extensions..."） |
| C11 | webRequest 的敏感头默认不可见/不可改（需 `'extraHeaders'`，且有性能代价）；内存缓存命中的请求不可见 | <https://developer.chrome.com/docs/extensions/reference/api/webRequest> |
| C12 | Chrome 117+：webRequest 不再向"别的扩展进程发起的请求"派发事件 | `extension_web_request_event_router.cc`（含本次逐版本核对） |
| C13 | Chrome 129/130+：DNR 跳过"别的扩展发起的非 main_frame 请求"；DNR 永不处理 `chrome-extension://` URL | `ruleset_manager.cc`（含本次逐版本核对） |
| C14 | 同步 XHR 已被判 deprecated；同步模式下 `timeout`/`abort` 等会抛 `InvalidAccessError`；msw 明确放弃拦截同步 XHR（放行到真实网络） | <https://developer.mozilla.org/en-US/docs/Web/API/XMLHttpRequest/Synchronous_and_Asynchronous_Requests>；<https://github.com/mswjs/interceptors>（`src/interceptors/XMLHttpRequest/xml-http-request-controller.ts`） |
| C15 | 现代页面常用 Service Worker / Worker：页面 JS 层的补丁**够不到**这些全局里的调用（**推断**自"JS API 层补丁只作用于被打补丁的那个全局"这一事实） | 概念文档 §6 已接受该盲区；本条的"够不到"为推断（未找到官方明文） |

---

## 6 对本项目的可用性判断

面向 R4（转发器）、R9（JS API 层拦截）、Q-D1（只拦一条精准 URL）：

1. **转发器主线（必须做）**：MAIN world 注入 + `fetch` / `XMLHttpRequest` 双层补丁，命中配置 URL 时直接构造响应（JSON-RPC / XML-RPC 全在 JS 层完成），未命中一律透传。
   - 可行性：三个独立真产品（Requestly 页面脚本、ajax-hook、msw）都验证了"构造 `Response` / 伪造 XHR 实例并触发事件"可行。
   - 我们的优势：R9 决定"命中即不发网络请求"，因此**不存在** CORS/混合内容/证书问题（与真实服务是否在线无关）。
   - 建议参照的实现要点（来自 §3.3）：用**真 `Response`**；XHR 走"Proxy 构造器 + 真实例做底"（msw 路线）而不是纯 facade（xhook 路线）；补齐属性描述符；对 `toString` 做处理（自行决定是否伪装，注意这属于"与页面检测对抗"，本项目 §6 已接受风险但没有要求对抗）。
2. **WebSocket 通道（Q-D3 第一版就要做）**：JS 层需要单独打 `WebSocket` 构造器补丁（`mock-socket` 提供了可参考的实现模型）；网络层（DNR/CDP）**不能**替我们造 WebSocket 会话语义。
3. **引擎层的两条可选通道（不是转发器，而是"如何真正下载"）**：
   - `chrome.debugger` + `Fetch.fulfillRequest`：**技术上可做**（能把任意请求转成自造响应体），但用户可见横幅 + DevTools 互斥 + 企业策略，作为"默认路径"不可接受；作为**可选的调试/诊断通道**尚有价值。
   - DNR：适合做**改请求头 / 强制下载 / 拦截**（概念文档附录 A 的引擎样例就是这类用法），但**不能**承担 RPC 响应生成。
4. **第三方前端接入（R4.2 / 动机）**：不可行（§4.6）⇒ **必须自带 UI**（与 R5 一致），且该 UI 要么作为普通页面（可被注入），要么接受"只换装载方式"的例外。
5. **拦截规则规模（Q-D1）**：只拦一条精准 URL，使实现可以极简（无需规则引擎、无需动态 DNR 规则、无需 tabId 过滤）；这也把 §4.2 的"多扩展冲突/优先级"问题降到最低。
6. **对"能力诚实"（R2/R10）的补充**：转发器的盲区必须能**枚举并告知用户**（Q-D2 已要求）。本报告 §7 可直接作为该清单的输入。

---

## 7 失败模式与盲区

| # | 失败模式 / 盲区 | 依据 | 可缓解性 |
|---|---|---|---|
| B1 | 页面在 `document_start` 注入之前就发出了请求（内联脚本、预加载、`<script>` 提前执行） | `document_start` 的语义（"before … any other script is run"）与注入顺序说明 | 静态声明 + document_start 是最优；不可避免的竞态要靠 DNR/网络层兜底（但 DNR 造不了响应体） |
| B2 | Worker / Service Worker 内部的 fetch/XHR | 补丁只作用于被打补丁的全局（**推断**）；DNR 能影响 SW 的 `fetch()`（官方原文）但不能造 body | 部分：DNR 可 block/redirect；完整响应仍做不到 |
| B3 | 页面保存了原生 `fetch` / `XMLHttpRequest` 引用（在注入前） | xhook/fetch-intercept README 的警告 | 无解（时序上已经输） |
| B4 | 页面用非 JS API 的方式发请求（导航、`<img>`、`EventSource`、`sendBeacon`、WebTransport、`<video>` 分片…） | "JS API 层"的定义（R9） | 只能靠网络层（DNR 可 block/redirect，不能造 body） |
| B5 | `chrome://`、`view-source:`、PDF viewer、WebUI | webRequest 文档（隐藏敏感请求、scheme 白名单）；debugger 源码拒 WebUI | 无解（概念文档 §6 已接受） |
| B6 | **其它扩展的请求**（含第三方 aria2 前端扩展） | §4 全部证据 | 无解（§4.6） |
| B7 | 同步 XHR | msw 明确放行；MDN 说同步 XHR deprecated | 我们可选择"自己伪造"（ajax-hook 路线可行但风险高：同步 XHR 场景下任何异步等待都不允许） |
| B8 | 页面检测到被 hook 后的行为变化（比如断言 `toString`） | §3.4 | 可做伪装，但 `isTrusted` 等不可完全消除 |
| B9 | 页面 CSP 阻止 MAIN world 注入（`script-src` 严格） | content-scripts 文档原文 | 可用 `chrome.userScripts` 的 USER_SCRIPT world（Firefox 的 USERSCRIPT_WORLD 类似）——但它**不在页面世界里**，改不了页面的 `fetch`（**推断**）；也可以只换装载方式（R5 例外） |
| B10 | SW 生命周期：转发器的状态如果在 SW 内存里会丢 | 概念文档 Q-D5 已裁定持久化 | 设计上已规避 |
| B11 | `chrome.debugger` 路线下用户按 F12 就断链 | debugger 文档 `onDetach` | 只能提示用户，不可控 |
| B12 | DNR 的多扩展冲突（谁赢取决于安装顺序/优先级） | DNR 文档 Rule evaluation；webRequest 文档 Conflict resolution | Q-D1 只一条规则时影响面小 |
| B13 | 请求在"页面 → SW → 网络"链路上被 SW 拦截后重写 | DNR 文档 "won't affect responses generated by the service worker" | 无解 |

---

## 8 与现有裁定的冲突（尤其 R9 与 R5）

**R9「拦截发生在 JS API 层，命中后请求根本不发到网络」**

- ✅ 成立的前提：命中时必须**在 JS 层短路**。这对 `fetch` 完全可行（构造 `Response`），对异步 XHR 可行（伪造实例/事件），对**同步 XHR** 需要特别处理（不能走异步路径；msw 的选择是放行 ⇒ 与 R9 冲突）。
- ⚠️ **与 R9 的潜在冲突**：R9 顺带断言"与 DNR 重定向不是同一条路：DNR 走网络层，拿不到返回任意响应体的能力"——**这条被本报告证实**（C4）；但要注意 DNR **能**做"改请求头 + 强制下载"（附录 A 样例），那属于**引擎层**而非转发器，R9 的表述在概念文档里是限定在"拦截层次"的，不冲突。
- ⚠️ **R9 的边界**：R9 的"命中即短路"只对"我们能注入且请求走标准 JS API"的客户端成立。它**不覆盖**：Worker/SW、其它扩展、`document_start` 之前的请求、非 JS API 请求（§7 B1–B6）。概念文档 §6.4 已把这些列为已接受风险，但**没有区分"技术上能拦但拦不到"与"设计上不打算拦"**——建议在「拦截盲区清单」里按 §7 分类呈现。
- ⚠️ **R9 与"内置 UI 走同样路径"（R5）的组合**：如果内置 UI 是 `chrome-extension://` 页面，MAIN world 注入不可用（§4.1），那就必须用 R5 的例外（"只换装载方式"）。**未验证**：`chrome.scripting.executeScript` 对自己的扩展页是否放行——这决定了 R5 例外是"必须"还是"可选"。

**R5「内置 UI 不得走特殊通道」**

- ✅ 技术可行性支持 R5 的意图：只要 UI 是普通页面，MAIN world 注入就能让它走与普通页面完全相同的路径。
- ⚠️ 需要 R5 例外的场景至少有两个：(a) UI 页面是扩展页；(b) UI 页面有严格 CSP。两者都对应"注入失败 → 换装载方式"（例如在页面里直接 `import` 我们的转发器模块，而不是靠 content script 注入）。**推断**：这两种"另一方式加载"本质上仍是同一个 JS 层实现，符合 R5 的文字与意图。
- ⚠️ **与 R5 的隐含冲突点**：如果为了省事把 UI 做成"扩展页 + 直接调用 Mock 层函数"（跳过 JS API 补丁），那就是 R5 明令禁止的"特殊通道"。§4.1 的结论说明这条捷径很有诱惑力，必须在详细设计里明确禁止。

**其它已裁定项**

- **Q-D1（只拦一条精准 URL）**：与所有方案兼容；对 JS 层补丁来说只需一次字符串比较，复杂度极低。
- **Q-D2（盲区必须列清）**：本报告 §7 可作为清单骨架。
- **§6.2（命中后真实服务不可访问）**：JS 层短路使这一条在"被注入的页面"里成立；但在未被注入的上下文（Worker、别的扩展、非 JS 请求）里，对 `localhost:6800` 的真实连接**仍然会尝试**（可能被拒绝），与"用户配置即放弃该地址连通性"的描述一致。
- **§6.4（扩展页 CSP 是已知盲区）**：本报告 §4.1 给出了更基础的结论（连 match pattern 都不支持），建议把盲区表述从"CSP"升级为"扩展页根本不在可注入范围内"。

---

## 9 未验证 / 存疑

1. **DNR `redirect.url` 是否允许 `data:`**：官方文档只写"Redirects to JavaScript urls are not allowed"，未提 `data:`；`URLTransform.scheme` 的限制也不能直接推出结论。**未验证**（无条件实测）。
2. **`chrome.scripting.executeScript` 能否注入"我们自己的" `chrome-extension://` 页面**：本次只证明了 match pattern 与 user script scheme 层不支持，没有找到 executeScript 对"自己扩展页"的官方明文或源码判定。**未验证**。
3. **CDP `Fetch` 能否拦截/伪造 WebSocket 握手**：`Fetch` 域处理 HTTP 请求；WS 握手是 HTTP upgrade。**未验证**（未找到官方说明）。
4. **Chrome 129/130 精确边界**：本次只在 128（无）与 130（有）之间确认，未二分到 129。**存疑**（结论表述为"Chrome 129/130 前后"）。
5. **Firefox 中"扩展到别的扩展页面"的实际注入行为**：MDN match pattern 文档把 `(chrome-)extension` 列为合法 scheme，但 Firefox 是否真的允许跨扩展注入、以及 Xray/`wrappedJSObject` 在 `moz-extension://` 页面上的表现，**未验证**。
6. **第三方扩展 SW 的 fetch 的 `initiator` 取值**：本报告假设其为 `chrome-extension://<id>`（由 DNR 源码里 `request.initiator` 的 `kExtensionScheme` 判断推断），但**没有找到直接展示该取值的文档/实测**。**存疑**（若取值为 `null`/opaque，结论不变，DNR 的 main_frame 例外仍不适用）。
7. **`isTrusted` 是否可被伪造**：本报告按"UA 置位、不可由脚本构造为 true"推断，未验证是否存在绕过手段。
8. **性能数字**：CDP Fetch 拦截的每请求开销、MAIN world 补丁的开销，本次无来源。
9. **`chrome.sockets.*` 现状**（用于 C1 的替代证据）：Chrome Apps 平台的 sockets 文档页面在本次抓取时 404，未取得可引用 URL。
10. **Safari 的 DNR 支持情况**：本次只核对了 `webRequestBlocking` 在 Safari 不支持（BCD），未查 Safari 的 DNR 能力。
11. **`@mswjs/interceptors` 在浏览器中的官方支持程度**：其 README 首句是 "Low-level network interception library for Node.js."，但同文档与 `package.json` 又提供浏览器构建（`lib/browser/*`）与 `/web` 入口。**存疑**：官方是否仍正式支持浏览器场景（可能主要用于 jsdom）。
12. **Tampermonkey 是否闭源**：本次以官方文档为依据，未查其源码可用性（**未验证**），故未评估其内部实现。

---

## 10 证据清单

> 抓取日期：2026-10-06（除 CRX 为当日从 Chrome Web Store 更新服务下载、GitHub raw 为当日拉取）。

### 10.1 官方文档

| # | URL | 支撑的结论 |
|---|---|---|
| E1 | <https://developer.chrome.com/docs/extensions/reference/api/webRequest> | MV3 无 `webRequestBlocking`（策略安装例外）；blocking 回调能力；`redirectUrl` 允许 `data:`；Chrome 72 起需 URL+initiator 双 host 权限；`chrome-extension://other_extension_id` 请求被隐藏；WS 只拦握手、不支持 WS 重定向；敏感头与 `extraHeaders`；缓存不可见；多扩展冲突规则 |
| E2 | <https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline> | MV2 时间线（138 最后支持、139 起失效、2026-08-31 CWS 清空 MV2） |
| E3 | <https://developer.chrome.com/docs/extensions/develop/migrate/blocking-web-requests> | MV3 用 DNR 替代 blocking webRequest 的官方指引（block/redirect/modifyHeaders 三用例） |
| E4 | <https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest> | DNR 全部 action（穷举）与"无响应体能力"；Redirect/URLTransform 细节；responseHeaders 条件；网络栈边界（SW）；规则上限；ResourceType 含 websocket；`initiatorDomains` 语义 |
| E5 | <https://developer.chrome.com/docs/extensions/reference/api/debugger> | debugger 权限；可用 CDP 域含 Fetch；`Debuggee`/`onDetach`（DevTools 抢占）；后台页需 `--silent-debugger-extension-api`；Chrome 125 flat session |
| E6 | <https://developer.chrome.com/blog/debugger-enterprise-policy-restrictions> | Chrome 155 起 debugger 的企业策略全有或全无限制（2026-09 发布） |
| E7 | <https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns> | match pattern 合法 scheme 只有 http/https/*（http、https）/file ⇒ 无法匹配 `chrome-extension://` |
| E8 | <https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts> | 隔离世界定义与互不可见；`world` 字段；MAIN world 受页面 CSP；静态声明优先注入 |
| E9 | <https://developer.chrome.com/docs/extensions/reference/api/scripting> | `ExecutionWorld`（ISOLATED/MAIN）；`registerContentScripts`/`executeScript` |
| E10 | <https://developer.chrome.com/docs/extensions/reference/api/userScripts> | `USER_SCRIPT`/`MAIN` world 语义；main world 对页面与其它扩展可见 |
| E11 | <https://developer.chrome.com/docs/extensions/reference/api/extensionTypes> | `document_start` = "before any other DOM is constructed or any other script is run" |
| E12 | <https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions> | host permissions 用法；`chrome.debugger` 不需要 host 权限 |
| E13 | <https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest> | Firefox：`webRequest`+`webRequestBlocking` 双权限；blocking 语义；`filterResponseData` 用于改响应体 |
| E14 | <https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest/StreamFilter> | StreamFilter "has full control over the response body"；不 write 则页面为空 |
| E15 | <https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest/BlockingResponse> | Firefox 侧 `redirectUrl`（含 `data:`）、`upgradeToSecure`、`web_accessible_resources` 要求 |
| E16 | <https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Match_patterns> | Firefox 允许 `(chrome-)extension` scheme；`<all_urls>` 覆盖范围 |
| E17 | <https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Sharing_objects_with_page_scripts> | Firefox Xray vision；`wrappedJSObject`、`exportFunction`、`cloneInto` |
| E18 | <https://developer.mozilla.org/en-US/docs/Web/API/XMLHttpRequest/Synchronous_and_Asynchronous_Requests> | 同步 XHR deprecated；同步下 timeout/abort 抛 `InvalidAccessError` |
| E19 | <https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Function/toString> | `Function.prototype.toString` 返回函数源码（native 函数显示 `[native code]`）⇒ 检测原理 |
| E20 | <https://blog.mozilla.org/addons/2022/05/18/manifest-v3-in-firefox-recap-next-steps/> | "Mozilla will maintain support for blocking WebRequest in MV3. ... we will also ship support for declarativeNetRequest." |
| E21 | <https://github.com/mdn/browser-compat-data/blob/main/webextensions/manifest/permissions.json> | `webRequestBlocking`：Chrome 的 MV3 限制注记；Safari `false`；`webRequestFilterResponse` 仅 Firefox 110+ |
| E22 | <https://chromedevtools.github.io/devtools-protocol/tot/Fetch/>（协议定义 JSON：<https://github.com/ChromeDevTools/devtools-protocol/blob/master/json/browser_protocol.json>） | `Fetch.enable` 的暂停语义与 pattern；`requestPaused` 阶段判定；`fulfillRequest` 的 `body/responseCode/responseHeaders`；`continueRequest` 可改 URL/method/headers/postData |
| E23 | <https://www.tampermonkey.net/documentation.php?locale=en&q=unsafeWindow>、`&q=sandbox` | `unsafeWindow` 定义；`@sandbox` 的 MAIN_WORLD / ISOLATED_WORLD / USERSCRIPT_WORLD 与 CSP 降级 |
| E24 | <https://violentmonkey.github.io/api/gm/> | `unsafeWindow` 语义；sandbox 默认开启，`@grant none` 关闭 |

### 10.2 Chromium 源码（`main` 分支，本次抓取；含历史 tag 对比）

| # | URL | 支撑的结论 | 版本核对 |
|---|---|---|---|
| E25 | <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/web_request/extension_web_request_event_router.cc> | `ListenerMatchesRequest()` 按渲染进程过滤"来自其它扩展"的请求；`IsRequestFromExtension()` 实现；同步 XHR 不再通知 blocking 监听器；webRequest 走 `REQUIRE_HOST_PERMISSION_FOR_URL_AND_INITIATOR` | 116 无 / 117+ 有 |
| E26 | <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/web_request/web_request_permissions.cc> | `HasWebRequestScheme()` 允许 extension scheme；`GetHostAccessForURL()`（自己扩展 URL 免 host 权限）；initiator 主机权限矩阵；`HideRequest()`（浏览器发起、WebUI、商店、Safebrowsing 等） | 与文档一致 |
| E27 | <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/declarative_net_request/ruleset_manager.cc> | DNR：`chrome-extension://` URL 永不求值；其它扩展发起的非 main_frame 请求跳过的 initiator 过滤；host 权限检查用 `DO_NOT_CHECK_HOST` / `REQUIRE_..._URL_AND_INITIATOR` | 128 无 / 130+ 有 |
| E28 | <https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/extensions/api/debugger/debugger_api.cc> | `ExtensionMayAttachToURL()` 拒绝"别的扩展的 URL"（除非 `AreExtensionsOnExtensionURLsAllowed()`）；WebUI 帧拒绝；worker 校验 parent；`Attach()` 触发警告横幅（除 `--silent-debugger-extension-api` / 策略安装） | — |
| E29 | <https://chromium.googlesource.com/chromium/src/+/main/extensions/common/switches.cc> | `AreExtensionsOnExtensionURLsAllowed()` 依赖 `--extensions-on-extension-urls` 或 `--extensions-on-chrome-urls` |
| E30 | <https://chromium.googlesource.com/chromium/src/+/main/extensions/common/user_script.cc> | `kValidUserScriptSchemes` 不含 `SCHEME_EXTENSION` |
| E31 | <https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/extensions/api/debugger/extension_dev_tools_infobar_delegate.cc> | debugger 警告横幅/消息的存在与实现 |

### 10.3 线上扩展的已发布产物（CRX 解包核对，2026-10-06 下载）

| # | 商店 / 出处 | 核对到的内容 |
|---|---|---|
| E32 | Requestly `mdnleldcmiljblolnjhpnblkcekpdkpa`（CRX v26.9.29，MV3）：<https://chromewebstore.google.com/detail/requestly-intercept-modif/mdnleldcmiljblolnjhpnblkcekpdkpa> | manifest：`declarativeNetRequest`+`webRequest`+`scripting`+`proxy`+`tabs`+`webNavigation`，静态 ruleset（delay/header）；`page-scripts/ajaxRequestInterceptor.ps.js`：`XMLHttpRequest.prototype.open/send/setRequestHeader/abort` 包装、`XMLHttpRequest.prototype = rqProxyXhr`、`fetch = async (...) => {...}`、命中规则时 `new Response(...)`；`serviceWorker.js`：`world:"MAIN"`、`registerContentScripts`、`executeScript`、`updateDynamicRules`/`updateSessionRules` |
| E33 | Tamper Dev `cpcmdnpekbomkhllkbmghhbefjbbjgni`（CRX v2，MV3）：<https://chromewebstore.google.com/detail/tamper-dev/cpcmdnpekbomkhllkbmghhbefjbbjgni> | manifest 权限仅 `debugger`+`activeTab`+`scripting`；SW 产物含 `chrome.debugger`、`Fetch.enable`、`Fetch.continueRequest`、`Fetch.fulfillRequest`；产品页 <https://tamper.dev/> |
| E34 | ModHeader V3 `cndlnhnjdlmipaflgajjikndbfkfnohp`（CRX v2026.8.8.18，MV3）：<https://chromewebstore.google.com/detail/modheader-v3-%E2%80%94-by-modhead/cndlnhnjdlmipaflgajjikndbfkfnohp> | manifest 权限仅 `clipboardRead/clipboardWrite/declarativeNetRequest/storage`；`background.js` 组装 `modifyHeaders`（requestHeaders + responseHeaders）并 `updateDynamicRules`/`updateSessionRules`/`getDynamicRules` |

### 10.4 开源库 / 开源扩展源码

| # | URL | 支撑的结论 |
|---|---|---|
| E35 | <https://github.com/kylepaulsen/ResourceOverride>（manifest、`src/background/background.html`、`src/background/requestHandling.js`） | MV2 blocking 的两种造 body 手法：Firefox `filterResponseData().onstart → write()`；Chrome `redirectUrl: "data:...base64,..."` |
| E36 | <https://github.com/einaregilsson/Redirector>（manifest、`js/background.js`） | MV2 blocking 的纯 `{redirectUrl}` 用法 |
| E37 | <https://github.com/wendux/ajax-hook>（`src/xhr-hook.js`、`src/xhr-proxy.js`） | 构造器替换 + 实例包装；`handler.resolve()` 伪造响应；不覆盖 fetch |
| E38 | <https://github.com/jpillora/xhook>（README、`dist/xhook.js`） | facade 构造器替换 `window.XMLHttpRequest` + `window.fetch`；"Simulate responses transparently"；必须先于其它库加载 |
| E39 | <https://github.com/werk85/fetch-intercept>（README、`lib/browser.js`） | `env.fetch = ...` 直接替换；拦截器链 |
| E40 | <https://github.com/mswjs/interceptors>（README、npm 0.45.7 的 `lib/browser/**` 与 sourcemap 还原的 `src/`） | XHR：`new Proxy(globalThis.XMLHttpRequest,{construct})` + 真实例 + 原型描述符复制；**同步 XHR 明确不支持并放行**；`EventPolyfill`（`isTrusted=true`）；fetch：`patchesRegistry.applyPatch` 的 `defineProperty`（漏 `writable`）；browser/`web` 构建存在 |
| E41 | <https://github.com/sinonjs/nise>（README、官网 <http://sinonjs.github.io/nise/>、`lib/fake-xhr/index.js`） | `useFakeXMLHttpRequest()` 替换原生全局；`FakeXMLHttpRequest` 是纯 JS 实现；`respond/setStatus/...` |
| E42 | <https://github.com/thoov/mock-socket> | WebSocket 类 + Server 的模拟实现 |
| E43 | <https://github.com/berstend/puppeteer-extra/blob/master/packages/puppeteer-extra-plugin-stealth/evasions/_utils/index.js>（及同目录 `withUtils.js`、`evasions/sourceurl/index.js`） | 反检测现成技术：缓存 `Function.toString + ''` 造 native 模板（`makeNativeString`）、代理 `Function.prototype.toString`、清洗错误栈里的 `sourceURL` |
| E44 | <https://github.com/violentmonkey/violentmonkey>（`src/manifest.yml`、`src/injected/content/inject.js`） | MV2 manifest 的 `webRequest`+`webRequestBlocking`；`injected-web.js`+`injected.js`（document_start / all_frames）；`wrappedJSObject` |
| E45 | <https://github.com/cloudbuy/modheader>（`src/manifest.json`） | 旧版 ModHeader（v2.3.2，MV2，`webRequest`+`webRequestBlocking`）——**仅历史参考**，与当前 MV3 版不同（当前版见 E34） |
| E46 | <https://thehackernews.com/2026/07/google-and-microsoft-pull-modheader.html> | ModHeader 被商店下架的背景（**第三方来源，仅作背景**） |
