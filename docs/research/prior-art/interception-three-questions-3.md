# 拦截与转发：三问独立调研（第三份）

> 本文件是 `/workspace/docs/research/prior-art/` 下**第三份独立调研**。
> 按任务要求，调研者**未阅读**同目录下的 `interception-three-questions.md` 与 `interception-three-questions-2.md`，也未与之对照；只读了 `/workspace/docs/concept-design/concept-design.md`（v0.5），其余全部从零检索。
> 调研方法：4 个并行子调研（各限定单一问题，不派生下一层）+ 调研者本人逐条回原始来源核实；关键行为另做**真机实验**（见 §0）。

---

## 0 元信息

| 项 | 值 |
|---|---|
| 调研日期 | **2026-10-06** |
| 调研者 | 独立调研（第 3 份） |
| 项目语境 | `aria2-in-browser`：在浏览器内冒充 aria2 RPC 服务端。相关裁定：R4（转发器覆盖多途径 × 多来源）、R5（内置 UI 不得走特殊通道，仅允许换"装载方式"）、R8（扩展不能监听端口）、R9（拦截发生在 JS API 层）、Q-D1（现阶段只拦一条精准匹配 URL）、Q-D2（盲区必须列出）、§6（已接受风险） |
| 适用浏览器 / 版本 | **Chrome：MV2 已死**——`Chrome 138` 是最后一个支持 MV2 的版本（2025-07-24 全渠道禁用），`ExtensionManifestV2Availability` 策略随 Chrome 139 移除，**2026-08-31 Chrome Web Store 清空全部 MV2 扩展**；下文未标注版本者按 Chrome 139+ / MV3 讨论。**Firefox**：MV2 未废弃，MV2/MV3 都保留 blocking `webRequest`，另有 `filterResponseData`。CDP 按 `devtools-protocol` master（`tot`）当日快照。 |
| 一手来源 | `developer.chrome.com`（含 `.md.txt` 纯文本端点）、`raw.githubusercontent.com/mdn/content`、`mdn/browser-compat-data`、`chromium.googlesource.com`（`?format=TEXT` → base64）、`raw.githubusercontent.com/ChromeDevTools/devtools-protocol`、`tc39.es/ecma262`、`webidl.spec.whatwg.org`、各库/扩展的 GitHub 源码（raw 或 codeload tarball）、W3C WebExtensions CG issue 原文、tampermonkey.net / violentmonkey.github.io / docs.requestly.com。 |
| 真机实验环境 | **有浏览器可用（先前判断有误，已更正）**：playwright-core 1.60.0 + `/root/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome`，实测 `HeadlessChrome/148.0.0.0`（Linux x86_64），本地 `http://127.0.0.1:8931` 起了一个 Node HTTP 服务用于真实 XHR 基线；探针脚本在 `/tmp/v3exp/probe.mjs`（**未写入工作区**）。凡标【本调研实测】者是该环境下的观测值；未标者来自文档/源码。 |
| 环境限制 | ① 真机实验**没有加载任何扩展**（未做 MV3 扩展 E2E），所以"扩展侧"结论全部来自官方文档 + Chromium 源码 + 官方浏览器测试；② 容器内没有 Firefox，跨浏览器结论来自 MDN/BCD；③ 部分站点（StackOverflow、issues.chromium.org 评论、CWS 详情页）是 JS 渲染或有反爬，凡抓不到的一律进 §9。 |
| 与现有裁定的关系 | 见 §8：本调研**支持** R9（JS API 层），并指出 R5 的"唯一例外"在 Chrome 上属于**结构性必须**而非偶发。 |

---

## 1 一句话结论（三问各一句）

1. **拦截层**：MV2 blocking 在 Chrome 上已不可用（只剩策略安装），MV3 只读 `webRequest` 只能观测（无响应体、不能 cancel/redirect），`declarativeNetRequest` 的 block/redirect/modifyHeaders **全都不能合成响应体**（"synthetic 200 response"至今仍是 2025-09 的开放提案）；`chrome.debugger` + CDP `Fetch.fulfillRequest` **确实能返回任意响应体**（Tamper Dev v2 就是这么做的，chromium 还为此在 attach 期间把扩展 SW 无限期保活），代价是全局"正在调试"提示条、与 DevTools 互斥（用户按 F12 即失效）、附加范围受 Chromium 明文 URL 限制；而 **content script 在 MAIN world 改写 JS API 是唯一"请求根本不发出去、响应体随便造、零权限零 UI"的常规路径** —— R9 的路线在能力上是唯一自洽的选择。
2. **封装劫持**：现成库分两派——**换全局构造器/全局函数**（ajax-hook、xhook、fetch-intercept、nise `useFakeXMLHttpRequest`）与 **`Proxy` 包裹原生对象**（`@mswjs/interceptors`、Requestly 的 client.js 也近似前者）；抗检测性的分水岭是 `Function.prototype.toString`（普通 JS 函数替换会暴露源码；`Proxy`/bound 走规范的 `NativeFunction` 分支 —— 【本调研实测】但**名字会丢**：原生是 `function fetch() { [native code] }`，Proxy 后是 `function () { [native code] }`，而 `.name` 仍是 `"fetch"`，两者不一致本身就是指纹）、`instanceof`/`Symbol.toStringTag`（用真 `new Response()`/`Reflect.construct` 即可通过；xhook 的 facade **根本不是 XHR 实例**、nise 是另起一套类）、属性形态（实例 own 属性数量、`enumerable` 被改）、事件语义（`isTrusted` 无法伪造、`target/currentTarget/timeStamp` 语义、事件顺序）与同步 XHR（msw **直接放弃**同步 XHR，ajax-hook/xhook/nise 有专门分支）；**所有这类库都必须运行在 MAIN world**，因为隔离世界与页面各自持有独立的 `fetch`/`XMLHttpRequest` 绑定，改一边不影响另一边。
3. **其它扩展的网络请求**：**不能**（这次查实了，四条互相独立的硬证据）——① content script **无法注入** `chrome-extension://` 页面（match pattern 的 scheme 白名单里根本没有 `chrome-extension`；content script 的 `matches` 用 `kValidUserScriptSchemes` 解析，**自家扩展页也不行**）；② `webRequest` 对"由扩展发起的子资源请求"有两道闸门（`ListenerMatchesRequest()` 要求监听者与请求同进程；非导航请求还必须对 **initiator** 有 host permission，而 `Extension::kValidHostPermissionSchemes` **不含 `SCHEME_EXTENSION`**，永远拿不到），官方浏览器测试的注释原话就是"Any requests made by it should not be visible to other extensions"；③ DNR 在 `ShouldEvaluateRulesetForRequest()` 里明文 `initiator_precursor.host() != ruleset.extension_id → return false`，并有专门的 `CrossExtensionRequestBlocking` 单测；④ `chrome.debugger` 附加到"恰好在一个标签页里打开的别的扩展页面"被 `ExtensionMayAttachToURL()` 挡死（除 `--extensions-on-chrome-urls`）。⇒ **接不住第三方 aria2 前端扩展发出的请求，必须自带 UI**（唯一例外：对方从**普通网页上下文**发请求，见 §4.6）。

---

## 2 第一问：拦截转发「标签页发出的请求」的现有方案

### 2.0 分层对照（本问骨架）

| 层 | 手段 | 请求发出前短路 | 能否合成任意响应体 | 覆盖来源 | 现状 |
|---|---|---|---|---|---|
| 网络层 | MV2 blocking `webRequest` | 能 cancel/redirect | 只能靠 `redirectUrl: "data:..."` 变通 | 有 host permission 的页面/子资源 | **Chrome 已死**；Firefox 仍可 |
| 网络层（只读） | MV3 `webRequest` | 不能 | 不能 | 同上 | 可用但纯观测 |
| 网络层（声明式） | `declarativeNetRequest` | block/redirect/modifyHeaders | **不能** | 同上 | MV3 唯一官方替代 |
| 调试层 | `chrome.debugger` + CDP `Fetch` | 能（paused 后 fulfill） | **能** | 被附加 target 内的请求 | 可用，代价高（infobar / 与 DevTools 互斥） |
| JS API 层 | MAIN world 脚本改 `window.fetch`/`XMLHttpRequest`/`WebSocket` | **能** | **能**（返回真 `Response`） | 仅**同一 world** 内的脚本 | 需 MAIN world；受 CSP/注入时机限制 |
| （Firefox 专有） | `webRequest.filterResponseData` | 不能短路，能改流 | 能 | Firefox only | Chrome 无此 API |

---

### 2.1 MV2 blocking `webRequest`（现状、平台支持）

- **出处（Chrome 时间线）**：<https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline>（`.md.txt` 端点抓取）
  - "**Aug 31st 2026: All remaining Manifest V2 extensions removed from the Chrome Web Store**"；"Existing installs on Chrome 138 or earlier will continue to run, but they can no longer receive updates or be reinstalled if removed."
  - "With Chrome 138 all users on all channels of Chrome have now Manifest V2 extensions disabled. Users can no longer turn them back on."；"For Enterprises, the `ExtensionManifestV2Availability` policy will be removed with Chrome 139."
  - "**Chrome 138 is the final version of Chrome to support Manifest V2 extensions**"
- **出处（API 现状）**：<https://developer.chrome.com/docs/extensions/reference/api/webRequest>
  - "As of Manifest V3, the `"webRequestBlocking"` permission is no longer available for most extensions. … Policy installed extensions can continue to use `"webRequestBlocking"`."
  - 权限表："`webRequestBlocking` — Required to register blocking event handlers. As of Manifest V3, this is only available to policy installed extensions."
  - BCD 佐证（<https://raw.githubusercontent.com/mdn/browser-compat-data/main/webextensions/manifest/permissions.json>）：chrome note 逐字 "In Manifest V3, no longer available for most extensions (the exception being policy-installed extensions). Use the `declarativeNetRequest` API instead."
- **原理**：在网络栈请求生命周期钩子上返回 `BlockingResponse{cancel, redirectUrl, requestHeaders, responseHeaders, authCredentials}`；原文："If "blocking" is specified in the "extraInfoSpec" parameter, the event listener should return an object of this type."
- **伪造响应体的唯一 MV2 变通**：`redirectUrl` 允许非 HTTP scheme —— 原文："If set, the original request is prevented from being sent/completed and is instead redirected to the given URL. **Redirections to non-HTTP schemes such as `data:` are allowed.**"；另有 "If a request is redirected to a `data://` URL, `onBeforeRedirect` is the last reported event."
- **覆盖**：`http/https/ftp/file/ws/wss/urn/chrome-extension`（原文列举）；WebSocket **只有握手**："the API does not intercept: Individual messages sent over an established WebSocket connection. WebSocket closing connection. Redirects are not supported for WebSocket requests."
- **局限**：① Chrome 普通安装路径已不可用；② 需要"请求 URL + initiator"双向 host permission（"Starting from Chrome 72, an extension will be able to intercept a request only if it has host permissions to both the requested URL and the request initiator."）；③ 走网络层 ⇒ 页面可观测到 redirect；④ 无法返回"非重定向"的自定义响应体。

### 2.2 MV3 观测型 `webRequest`（能看到什么、绝对不能做什么）

- **出处**：<https://developer.chrome.com/docs/extensions/reference/api/webRequest>
  - 关键澄清："**Aside from `"webRequestBlocking"`, the webRequest API is unchanged and available for normal use.**"
- **能看到**：`onBeforeRequest` 的 `details`：`documentId`(106+)、`documentLifecycle`、`frameId`、`frameType`、`initiator`(63+，"The origin where the request was initiated. This does not change through redirects. If this is an opaque origin, the string 'null' will be used.")、`method`、`parentDocumentId`、`parentFrameId`、`requestBody`、`requestId`、`tabId`、`timeStamp`、`type`、`url`；`requestBody` 只在 extraInfoSpec 含 `'requestBody'` 时提供，子字段 `error`/`formData`/`raw: UploadData[]`；`OnBeforeRequestOptions` = `"blocking" | "requestBody" | "extraHeaders"`。
- **不能做**：非策略扩展拿不到 `blocking` ⇒ 不能 cancel/redirect/改头；**没有任何响应体字段**（`onResponseStarted`："Fires when the first byte of the response body is received… **This event is informational and handled asynchronously. It does not allow modifying or canceling the request.**"）。
  - **写 blocking 监听器会怎样（源码级）**：`extensions/browser/api/web_request/web_request_api.cc`
    ```cpp
    bool is_blocking = extra_info_spec & (ExtraInfoSpec::BLOCKING | ExtraInfoSpec::ASYNC_BLOCKING);
    if (is_blocking && !has_blocking_permission()) { return RespondNow(Error(keys::kBlockingPermissionRequired)); }
    ```
    错误文案（`web_request_api_constants.cc`，逐字）："**You do not have permission to use blocking webRequest listeners. Be sure to declare the webRequestBlocking permission in your manifest. Note that webRequestBlocking is only allowed for extensions that are installed using ExtensionInstallForcelist.**"
- **意义**：只能当旁路审计，**不能承担 R4.1 的转发职责**。

### 2.3 `declarativeNetRequest`（block / redirect / modifyHeaders 各自能力）

- **出处**：<https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest>
- **动作枚举（逐字）**：`"block"` / `"redirect"` / `"allow"`（"The request won't be intercepted if there is an allow rule which matches it."）/ `"upgradeScheme"`（"Upgrade the network request url's scheme to https if the request is http or ftp."）/ `"modifyHeaders"`（"Modify request/response headers from the network request."）/ `"allowAllRequests"`。
- **redirect 目标**：`url` / `extensionPath` / `transform`(`URLTransform`) / `regexSubstitution`；`url` 的官方限制仅 "The redirect url. Redirects to JavaScript urls are not allowed."
  - WebIDL（<https://chromium.googlesource.com/chromium/src/+/main/extensions/common/api/declarative_net_request.webidl>）：`URLTransform.scheme` 注释 "The new scheme for the request. Allowed values are "http", "https", "ftp" and "chrome-extension"."
- **modifyHeaders**：`ModifyHeaderInfo{header, operation(append|set|remove), value}`；`append` 仅对白名单请求头有效（原文列出 accept…x-forwarded-for，"This allowlist is case sensitive"）。响应侧只能改 header。
- **限额**：静态 ruleset ≤100、同时启用 ≤50、保底 30,000 条；session 5,000；dynamic 安全 30,000 / unsafe 5,000；正则 ≤1,000 条/类。

**关键子问题：DNR 能否合成自定义响应体？——不能。四条独立证据：**

1. **结构/源码级**：`dictionary RuleAction { required RuleActionType type; Redirect redirect; sequence<ModifyHeaderInfo> requestHeaders; sequence<ModifyHeaderInfo> responseHeaders; };`（WebIDL 原文）——**没有任何 body 字段**，动作枚举里也没有 "respond" 类动作。
2. **官方文档通篇没有该能力**：该页全文里唯一出现 "body" 的一句是 "Note that if a request made it to this stage, the request has already been sent to the server and the server has received data like the request body. A block or redirect rule with a response headers condition will still run--but cannot actually block or redirect the request."
3. **追踪中的提案反证**：W3C WebExtensions CG <https://github.com/w3c/webextensions/issues/868>（2025-09-10）把合成响应列为**待实现修复**：
   - "For subresource requests affected by DNR `redirect`, return a **synthetic 200 response** (body = redirect target) without exposing a network redirect to page scripts: `fetch(..., { redirect: "error" })` does not reject; `Response.redirected === false`; No redirect hop visible to page JS"
   - 同 issue 证明 DNR redirect **可被页面检测**（`fetch(url,{redirect:"error"})` 会 reject）。
4. **DNR 也读不到请求体**：CG <https://github.com/w3c/webextensions/issues/109>："The declarativeNetRequest API is currently useless for this use case, not supporting POST content processing nor transformation before pattern matching."
5. **重定向到扩展资源（最接近"假响应"）的致命伤**：目标必须 web accessible（"A declarativeNetRequest rule cannot redirect from a public resource request to a resource that is not web accessible."）；而 **POST 会被 `net::ERR_UNSAFE_REDIRECT` 打死**——Chromium issue 324676520（<https://issues.chromium.org/issues/324676520>，正文在本调研抓取的页面载荷中逐字可读）："Once redirected, the browser displays an exception: `net::ERR_UNSAFE_REDIRECT` … This is assumed to be because the redirected uses a 307, which preserves the method and body when redirecting. So a POST request with a BODY are sent to the chrome-extension:// url of the exposed json file within the extension. This triggers the error in the browser. **I suspect a 302 would not cause this problem, but there is no ability to override the status code in the redirect.**"

### 2.4 `chrome.debugger` + CDP `Fetch` 域（能否 `Fetch.fulfillRequest` 返回自定义响应体）

- **`Fetch` 在 `chrome.debugger` 的可用域白名单内**：<https://developer.chrome.com/docs/extensions/reference/api/debugger> 原文："For security reasons, the `browser.debugger` API does not provide access to all Chrome DevTools Protocol Domains. The available domains are: `Accessibility`, `Audits`, `CacheStorage`, `Console`, `CSS`, `Database`, `Debugger`, `DOM`, `DOMDebugger`, `DOMSnapshot`, `Emulation`, **`Fetch`**, `IO`, `Input`, `Inspector`, `Log`, `Network`, `Overlay`, `Page`, `Performance`, `Runtime`, `Storage`, `Target`, `Tracing`, `WebAudio`, and `WebAuthn`."
- **CDP 规范（`browser_protocol.json` @ master，逐字）**：
  - 域描述："A domain for letting clients substitute browser's network layer with client code."
  - `Fetch.enable`："Enables issuing of requestPaused events. A request will be paused until client calls one of failRequest, fulfillRequest or continueRequest/continueWithAuth."；`patterns`："If specified, only requests matching any of these patterns will produce fetchRequested event and will be paused until clients response. **If not set, all requests will be affected.**"
  - `RequestStage`："Request will intercept before the request is sent. Response will intercept after the response is received (but before response body is received)."
  - `Fetch.fulfillRequest`："Provides response to the request."；参数 `requestId`、`responseCode`("An HTTP response code.")、`responseHeaders`、`binaryResponseHeaders`、**`body`（"A response body. If absent, original response body will be used if the request is intercepted at the response stage and empty body will be used if the request is intercepted at the request stage. (Encoded as a base64 string when passed over JSON)"）**、`responsePhrase`。
  - `Fetch.continueRequest`：可改 `url`（"the request url will be modified in a way that's not observable by page"）、`method`、`postData`、`headers`；`Fetch.failRequest`（按 `Network.ErrorReason` 失败）；`Fetch.getResponseBody`（仅 Response 阶段，与 `takeResponseBodyAsStream` 互斥）；`Fetch.continueResponse`（改状态码/响应头）。
  - `RequestPattern.resourceType` 用 `Network.ResourceType`（枚举**含 `WebSocket`**）；但 tot 规范的 Fetch 域里 **0 处** "websocket" 字样，Fetch 的实现路径是 URLLoader 拦截（`content/browser/devtools/devtools_url_loader_interceptor.cc`）⇒ **WS 消息级拦截无规范支持，握手能否被 pause 也查不到明文**（§9）。
- **能拦到的范围**：**被 attach 的那一个 target** 内、走 URLLoader 的 HTTP(S) 请求（主文档、子框架（事件带 `frameId`）、导航、XHR/fetch/script/image… 可用 `resourceType` 细分）；用 `Target` 域 + `DebuggerSession.sessionId`（"If sessionId is specified for arguments sent from onEvent, it means the event is coming from a child protocol session within the root debuggee session."）可延伸到 OOPIF/worker 子会话，但每个 session 要各自 `Fetch.enable`。是 **per-target / per-frame**，不是全局进程。
- **现成先例（本问最硬的"能"证据）**：**Tamper Dev**（<https://github.com/google/tamperchrome> v2）
  - `v2/manifest_base.json`：`"permissions": ["debugger", "activeTab"]`，MV2，`minimum_chrome_version: 87`。
  - `v2/background/src/interception.ts`：`await this.debuggee.sendCommand('Fetch.enable', { patterns: [{ urlPattern: pattern, requestStage: 'Request' }, { urlPattern: pattern, requestStage: 'Response' }] })`，按 `params.responseStatusCode` 区分阶段。
  - `v2/background/src/request.ts`：`return this.debuggee.sendCommand('Fetch.fulfillRequest', { requestId: this.id, responseCode: response.status || this.status || 0, responseHeaders: …, body: response.responseBody || undefined });`
  - `v2/background/src/debuggee.ts`：`this.target = { tabId: tab.id }; chrome.debugger.attach(this.target, '1.2', …)`
- **代价与限制（逐条有据）**
  1. 需要 `"debugger"` 权限；官方权限警告（<https://raw.githubusercontent.com/GoogleChrome/developer.chrome.com/main/site/en/docs/extensions/mv3/permission_warnings/index.md>，`<tr id="debugger">`）："**Access the page debugger backend**"（与 "Read and change all your data on all websites" 同级警告）。
  2. **全局提示条（源码级）**：`chrome/browser/extensions/api/debugger/extension_dev_tools_infobar_delegate.h`："// An infobar used to globally warn users that an extension is debugging the browser (which has security consequences)."；`kAutoCloseDelay = base::Seconds(5)`；"infobar_ is set after attaching an extension and is deleted 5 seconds after detaching the extension."；文案来自 `chrome/app/generated_resources.grd:4771`：`IDS_DEV_TOOLS_INFOBAR_LABEL` = `"<ph name="CLIENT_NAME">$1<ex>Extension Foo</ex></ph>" started debugging this browser`，其 `desc` 还写明 "**The label does not disappear until the user dismisses it, even if the debugger is detached**"；按钮是 `IDS_APP_CANCEL`，`ShouldExpire()==false`（导航不会让它消失）。策略安装扩展可用 `--silent-debugger-extension-api` 抑制。
  3. **与 DevTools 互斥**：文档 `onDetach`："Fired when browser terminates debugging session for the tab. This happens when either the tab is being closed or **Chrome DevTools is being invoked for the attached tab**."；`DetachReason` = `"target_closed" | "canceled_by_user"`。⇒ 用户按 F12 就踢掉扩展，拦截静默失效。
  4. `extensionId` 目标被限制："Attaching to an extension background page is only possible when the `--silent-debugger-extension-api` command-line switch is used."
  5. 受限页面：WebUI（chrome://）→ `kCannotAccessChromeUrl`；**别的扩展的 `chrome-extension://` URL 被拒**（§4.4）；`file://` 需文件访问权限；privileged WebContents 直接拒。注意源码注释："NOTE: The debugger permission implies all URLs access … so we don't check explicit page access."（不受 host_permissions 限制）。
  6. **MV3 副作用（有利的一条）**：attach 期间扩展 SW 被**无限期保活**——`chrome/browser/extensions/api/debugger/debugger_api.cc:616-626`：`service_worker_keepalive_ = process_manager->IncrementServiceWorkerKeepaliveCount(*extension_service_worker_id_, content::ServiceWorkerExternalRequestTimeoutType::kDoesNotTimeout, Activity::DEBUGGER, /*extra_data=*/std::string());`（对照 SW 生命周期文档："After 30 seconds of inactivity."）
  7. 每个 target 只能有一个调试客户端：`kAlreadyAttachedError[] = "Another debugger is already attached to the * with id: *."`
  8. 挂起风险：`Fetch.enable` 命中而客户端不回包，请求会一直挂着（规范原文）⇒ SW 必须对每个 `requestPaused` 都 respond。

### 2.5 content script 在 JS 层改写（MAIN world）

- **原理**：在页面自己的 JS 环境里替换 `window.fetch` / `window.XMLHttpRequest` / `window.WebSocket`，命中规则就地 `return new Response(...)`，请求**不进网络栈**。
- **world 语义（官方）**：<https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts>
  - "Content scripts live in an isolated world, allowing a content script to make changes to its JavaScript environment without conflicting with the page or other extensions' content scripts."
  - "**Not only does each extension run in its own isolated world, but content scripts and the web page do too.** This means that none of these (web page, content scripts, and any running extensions) can access the context and variables of the others."
  - 声明支持 `"world": "MAIN" | "ISOLATED"`（`ExecutionWorld`，"Defaults to `ISOLATED`"）；`match_origin_as_fallback` 只覆盖 `about:`/`data:`/`blob:`/`filesystem:`。
  - "When a content script is injected into the main world, **the CSP of the page applies**."
  - manifest `world` 键的 Aside 警告："There are risks involved when using the "MAIN" world. The host page can access and interfere with the injected script."
  - 版本：manifest `content_scripts.world` Chrome 111+；`chrome.scripting` 的 `world`/`ExecutionWorld` Chrome 102+（MDN BCD）。
- **注入时机**：`document_start` = "Scripts are injected after any files from css, but before any other DOM is constructed or any other script is run."；`injectImmediately` 的注释仍提醒："Note that this is not a guarantee that injection will occur prior to page load, as the page may already have loaded by the time the script reaches the target."
- **覆盖范围**：仅 MAIN world 内的脚本；**改不到隔离世界**（扩展 content script 自己发的请求用隔离世界的 `fetch`）。
- **局限**：`document_start` 之前已发出的请求拦不到（Q-D2 已列）；CSP 可能挡住 MAIN world 注入（Tampermonkey/Violentmonkey 官方文档都把它当现实约束）；`chrome://`、PDF viewer、view-source 等不能注入；页面对 hook 的检测（§3.7）。

### 2.6 Firefox 专有：`webRequest.filterResponseData`（跨浏览器对照）

- **出处**：MDN <https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest/filterResponseData>（原始 markdown：`raw.githubusercontent.com/mdn/content/main/files/en-us/mozilla/add-ons/webextensions/api/webrequest/filterresponsedata/index.md`）
  - "Use this function to create a `webRequest.StreamFilter` object for a request. **The stream filter gives the web extension full control over the stream, with the ability to monitor and modify the response.**"
  - "…you must have the `"webRequest"` and `"webRequestBlocking"` API permissions… **From Firefox 110, Manifest V3 extensions must also request the `"webRequestFilterResponse"` permission to use this API.**"
- **BCD（Chrome 不支持）**：`webextensions/api/webRequest.json` → `filterResponseData.__compat.support` = `{"chrome": {"version_added": false}, "firefox": {"version_added": "57"}, "safari": {"version_added": false}}`。
- **意义**：Chrome 上没有任何"读/改响应体"的网络层 API。

---

### 2.7 现成项目/扩展逐个查

#### (1) Requestly — <https://github.com/requestly/requestly> / 文档 <https://docs.requestly.com>
**这是本问信息量最大的一个，且"官方文档说法"与"代码实际做法"必须分开看。**

- **官方能力表**（<https://docs.requestly.com/account/how-is-browser-extension-different-from-a-desktop-app>）：`Serve local file Response` 浏览器扩展 ❌ / 桌面 App ✅；`Modify HTML/JS/CSS Response` ❌ / ✅；`Map Local` ❌ / ✅；`System-wide Proxy` ❌ / ✅；`Map Remote` ✅ / ✅。官方注："💡 **The extension works within the limitations of browser APIs. Features like serving local files or modifying HTML/CSS content are only supported in the desktop app due to broader system access.**"
  - → 这条只说明"**网络层**造不出响应 / 不能当系统代理"，**不等于**它在浏览器里不能伪造响应。
- **MV3 manifest 实际内容**（`browser-extension/mv3/src/manifest.chrome.json`，本调研直接抓取）：`"manifest_version": 3`；`permissions: ["contextMenus","declarativeNetRequest","declarativeNetRequestFeedback","scripting","storage","tabs","webRequest"]`；`host_permissions: ["<all_urls>"]`；`declarative_net_request.rule_resources = [{id:"delay_rules", …}]`；content_scripts：`client.cs.js`（`http://*/*`,`https://*/*`, `run_at: document_start`, `all_frames: true`）。
- **响应改写走页面 JS 层**（源码级）：
  - 注入：`browser-extension/mv3/src/service-worker/services/clientHandler.ts` 全文核心 = `chrome.scripting.executeScript({ target, files: ["client.js"], world: "MAIN", injectImmediately: true })`。
  - 打补丁：`browser-extension/mv3/src/client-scripts/ajaxRequestInterceptor.js` 里 `XMLHttpRequest.prototype = XHR.prototype;`、`XMLHttpRequest.prototype.open = function (method, url) {…}`、`XMLHttpRequest.prototype.send = …`、`XMLHttpRequest.prototype.setRequestHeader = …`、`const _fetch = fetch; fetch = async (resource, initOptions = {}) => {…}`，命中规则时 `return new Response(new Blob([customResponse]), { status: …, statusText: …, headers: … })`；静态响应（`serveWithoutRequest`）**完全不发网络请求**。
  - MV2 时代它用的是 blocking webRequest：PR <https://github.com/requestly/requestly/pull/1536> 的 diff 删除了 `chrome.webRequest.onBeforeRequest.addListener(overrideRequest, {`；MV3 的 DNR 只用于规则解析（`app/src/modules/extension/mv3RuleParser/*`）。
- **覆盖 / 局限**：fetch+XHR 双补丁、可完全不出网合成响应（**这是"JS API 层"路线最完整的开源样板**）；但只覆盖 content script 能注入的框架，页面提前缓存了原生引用 / Worker / 已加载页面 / 严格 CSP 都会漏；不拦 WebSocket。
- **对本项目的启发**：商业扩展在 MV3 下的**响应伪造就是靠 MAIN world 打补丁**，与 R9 完全同路。

#### (2) ModHeader — <https://modheader.com>
- **能查到**：官网仅功能描述（"Edit request and response headers … Change request headers, response headers, Cookie, and Set-Cookie from the popup."、"Filter by URL, tab, or resource"）；首页仍链 CWS `.../detail/modheader/idgpnmonknjnojddfkpgkljpfnnfcklj`。
- **查不到**：`https://github.com/ModHeader/ModHeader` **404**（本调研与子调研均实测），`raw.githubusercontent.com/ModHeader/ModHeader/{master,main}/manifest.json` 404，`codeload` 亦失败；CWS 详情页是客户端渲染，抓到的 HTML 里没有扩展名/manifest；chrome-stats/socket.dev 403、AMO API 401。
- **结论（保守）**：主能力=改请求/响应头（与 `webRequest`/DNR `modifyHeaders` 一致），**机制与在架状态本次均未取得一手证据**；网上"2026-07 被下架"的说法，子调研用 CWS 页面对照实验**未能证实**（对照组同样不含扩展名）⇒ 列入 §9，不作为论据。

#### (3) Tamper Dev（原 Tamper Chrome）— <https://github.com/google/tamperchrome>
- **机制**：`debugger` + `activeTab`，`chrome.debugger.attach({tabId}, '1.2')` + CDP `Fetch.enable` / `Fetch.requestPaused` / `Fetch.continueRequest` / `Fetch.getResponseBody` / **`Fetch.fulfillRequest`**（§2.4 已列文件与代码）。
- **覆盖**：被附加标签页内、匹配 `urlPattern` 的请求与响应（Request/Response 两阶段），可改 URL/method/headers/body 与**替换整个响应体**。
- **局限**：MV2 manifest；必须 infobar 警告；与 DevTools 互斥；只覆盖被 attach 的 tab；README 原文："**Tamper Chrome was version 1, which uses a deprecated API, and will stop working at some point.** Users should migrate to Tamper Dev (v2)."（v1 的 `v1/extension/manifest.json` 同时含 `webRequest` + `webRequestBlocking` + `debugger`）。

#### (4) Resource Override — <https://github.com/kylepaulsen/ResourceOverride>
- **manifest（MV2）**：`{"manifest_version": 2, "permissions": ["webRequest","webRequestBlocking","<all_urls>","tabs"], "background": {"page": "src/background/background.html"}, "content_scripts": [{"matches": ["*://*/*"], "js": ["src/inject/scriptInjector.js"], "all_frames": true, "run_at": "document_start"}], "devtools_page": "src/ui/devtools.html"}`
- **原理（`src/background/requestHandling.js`）**：同一函数两条路——
  ```js
  const replaceContent = (requestId, mimeAndFile) => {
      if (browser.webRequest.filterResponseData) {        // Firefox
          browser.webRequest.filterResponseData(requestId).onstart = e => { … write(file) … disconnect(); };
          return { cancel: true, responseHeaders: [{name:"Content-Type", value: mimeAndFile.mime}] };
      }
      // browsers that dont support filterResponseData     // Chrome
      return { redirectUrl: "data:" + mimeAndFile.mime + ";charset=UTF-8;base64," + btoa(unescape(encodeURIComponent(mimeAndFile.file))) };
  };
  ```
  另有 `src/background/background.js` 里 `chrome.webRequest.onBeforeRequest.addListener(…, ["blocking"])` 等。
- **局限（README 原文）**："!!! Development on RO has stopped indefinitely !!!"、"You can try to use my half baked MV3 branch here, but it is untested and I won't be supporting it."、"I'm not the biggest fan of what MV3 is forcing upon people" ⇒ **MV2 阻塞式 webRequest 路线在 MV3 已死**。

#### (5) Redirector — <https://github.com/einaregilsson/Redirector>
- **manifest（MV2）**：`{"manifest_version": 2, "permissions": ["webRequest","webRequestBlocking","webNavigation","storage","tabs","http://*/*","https://*/*","notifications"], "background": {"scripts": ["js/redirect.js","js/background.js"], "persistent": true}}`
- **原理**：`chrome.webRequest.onBeforeRequest.addListener(checkRedirects, filter, ["blocking"])`，处理器 `return { redirectUrl: result.redirectTo };`
- **局限**：纯 URL 重定向，不能改响应体；无 MV3 分支（探测 `mv3`/`main`/`manifest-v3` 均 404）。

#### (6) Tampermonkey — <https://www.tampermonkey.net/documentation.php>
- **`@sandbox`（逐字）**：<https://www.tampermonkey.net/documentation.php?ext=ejkj&q=sandbox>
  - "`@sandbox` allows Tampermonkey to decide where the userscript is injected: `MAIN_WORLD` - the page; `ISOLATED_WORLD` - the extension's content script; `USERSCRIPT_WORLD` - a special context created for userscripts"
  - `raw`："always needs to run in page context, the `MAIN_WORLD`. At the moment this mode is the default if `@sandbox` is omitted. **If injection into the `MAIN_WORLD` is not possible (e.g. because of a CSP) the userscript will be injected into other (enabled) sandboxes according to the order of this list.**"
  - `JavaScript`：needs access to `unsafeWindow`（Firefox 的 `USERSCRIPT_WORLD` "also bypasses existing CSPs"）；`DOM`：执行在 `ISOLATED_WORLD`。
- **`unsafeWindow`（逐字）**："The `unsafeWindow` object provides access to the `window` object of the page that Tampermonkey is running on, rather than the `window` object of the Tampermonkey extension."
- **网络能力在 MV3 被砍**（`?q=webRequest`，本调研抓取）："Note: this API is experimental and might change at any time. **It is also not available anymore at Manifest v3 versions of Tampermonkey 5.2+ (Chrome and derivates).**"（`GM_webRequest` 同样不可用；其规则动作只有 cancel/redirect，只处理 `sub_frame, script, xhr and websocket`）⇒ **用户脚本管理器自身没有响应体改写的一等 API**，只能靠脚本自己在 MAIN world 打补丁。
- **MV3 现状**：FAQ Q408（`?q=Q408`）说明 Chrome 120+ 上会（自动）更新到 MV3 版本。

#### (7) Violentmonkey — <https://violentmonkey.github.io/>（开源：<https://github.com/violentmonkey/violentmonkey>）
- **manifest（`src/manifest.yml`）**：`manifest_version: 2`；`permissions: [tabs, <all_urls>, webRequest, webRequestBlocking, notifications, storage, unlimitedStorage, clipboardWrite, contextMenus, cookies]`；content_scripts `injected-web.js`+`injected.js`（`matches: [<all_urls>]`, `run_at: document_start`, `all_frames: true`）。
- **官方文档（逐字）**：<https://violentmonkey.github.io/posts/inject-into-context/>
  - "Violentmonkey supports 2 types of context for a script to execute in: context of a web page / context of content scripts"
  - "Mode: `page` — … **Injection fails in Firefox on sites with strict CSP that forbids inline scripts created by a WebExtension**, like GitHub."
  - "Mode: `content` — Scripts run in the content context, a secure 'isolated world'. **Content userscripts can't access JavaScript objects of the webpage in Chrome**… Universal workaround: DOM messaging via `CustomEvent` (synchronous) or `window.postMessage` (asynchronous)."
- **`@inject-into`（<https://violentmonkey.github.io/api/metadata-block/>）**：`auto` = "Try to inject into context of the web page. If blocked by CSP rules, inject as a content script."；MV3 仍是未上架 CWS 的测试版本（release 说明："MV3 version for Chrome, might still have bugs, requires Chrome/ium 135+, not yet published to CWS"），MV3 路径改用 `chrome.declarativeNetRequest` 的 session rules（`src/background/utils/dnr.js`）。
- **意义**：这是"MAIN world 才能改页面对象、隔离世界改不到"的另一份一手官方陈述，并暴露 CSP 失败模式。

#### (8) 顺带：Tamper Chrome v1 与 msw 的 WebSocket 拦截器
- **Tamper Chrome v1**（同仓库 `v1/extension/manifest.json`）：MV2 + `webRequest` + `webRequestBlocking` + `debugger`，已被 v2 取代。
- **`@mswjs/interceptors` 的 WebSocket 拦截器**（§3.5）：`new Proxy(globalThis.WebSocket, {construct})` + 自造 `WebSocketOverride extends EventTarget implements WebSocket`（`src/interceptors/WebSocket/web-socket-override.ts`）——JS 层拦 WS 的现成范式，但**不继承原生 `WebSocket`**，`instanceof` 会失败。

---

## 3 第二问：fetch / XHR 封装劫持的现有做法

> 每个库的"拦截点"都由我下载源码 tarball 后**逐行读过**；标【子调研实测】的行为观测来自子调研在 **Chromium 1223（playwright-core 1.60.0）+ Node 24** 上的实验，我复核了其引用的源码行与关键结论；标【本调研实测】的是我在 **Chromium 148.0.0.0** 上的探针结果。

### 3.0 规范依据（后面反复引用）

- **`Function.prototype.toString`（ECMA-262，<https://tc39.es/ecma262/multipage/fundamental-objects.html#sec-function.prototype.tostring>）**，算法逐字：
  1. "If func is an Object, func has a `[[SourceText]]` internal slot, func.`[[SourceText]]` is a sequence of Unicode code points, and `HostHasSourceTextAvailable(func)` is true, then Return `CodePointsToString(func.[[SourceText]])`."
  2. "If func is a **built-in function object**, return an implementation-defined String source code representation of func. The representation must have the syntax of a **NativeFunction**."
  3. "**If func is an Object and `IsCallable(func)` is true, return an implementation-defined String source code representation of func. The representation must have the syntax of a `NativeFunction`.**"
  - `NativeFunction : function NativeFunctionAccessor_opt PropertyName ( FormalParameters ) { [ native code ] }`
  - **【本调研实测】（HeadlessChrome 148）**：
    - `Function.prototype.toString.call(window.fetch)` → `"function fetch() { [native code] }"`
    - `Function.prototype.toString.call(new Proxy(window.fetch, {}))` → **`"function () { [native code] }"`**（走第 3 步，但**名字丢了**）
    - `Function.prototype.toString.call(window.fetch.bind(window))` → 同上
    - `Function.prototype.toString.call(async (a,b)=>{})` → `"async (a,b)=>{}"`（普通 JS 函数直接暴露源码）
    - 而 `new Proxy(window.fetch,{}).name === "fetch"`、`.length === 1`（与原生一致）⇒ **`fn.name` 说"我是 fetch"，`fn.toString()` 里却没有 `fetch` 这个词**，这个**自相矛盾**本身就是一行可查的指纹（比"Proxy 一定安全"更准确的说法）。
- **平台对象的 `Symbol.toStringTag` 与属性描述符（WebIDL，<https://webidl.spec.whatwg.org/>）**，逐字：
  - "Some objects described in this section are defined to have a **class string**, which is the string to include in the string returned from `Object.prototype.toString`."；"If an object has a class string classString, then the object must, at the time it is created, have a property whose name is the `%Symbol.toStringTag%` symbol with `PropertyDescriptor{[[Writable]]: false, [[Enumerable]]: false, [[Configurable]]: true, [[Value]]: classString}`."；"The class string of an interface prototype object is the interface's qualified name."
  - **操作（operation，如 `fetch`、`XMLHttpRequest.prototype.open`）**："Let `modifiable` be false if op is unforgeable and true otherwise. Let desc be the `PropertyDescriptor{[[Value]]: method, [[Writable]]: modifiable, [[Enumerable]]: true, [[Configurable]]: modifiable}`."
  - **属性（attribute，如 `XMLHttpRequest.prototype.readyState`）**："Let desc be the `PropertyDescriptor{[[Getter]]: getter, [[Setter]]: setter, [[Enumerable]]: true, [[Configurable]]: configurable}`."
  - **`[Global]` 接口（Window/Worker 都是）**："Regular attributes are exposed on the interface prototype object, **unless the attribute is unforgeable or if the interface was declared with the `[Global]` extended attribute, in which case they are exposed on every object that implements the interface.**"
  - **【本调研实测】原生基线（HeadlessChrome 148）**：
    | 对象 | 描述符 |
    |---|---|
    | `window.fetch` | `{writable:true, enumerable:true, configurable:true}` |
    | `window.XMLHttpRequest`（接口对象） | `{writable:true, **enumerable:false**, configurable:true}` |
    | `window.WebSocket` | `{writable:true, enumerable:false, configurable:true}` |
    | `XMLHttpRequest.prototype.open` | `{writable:true, enumerable:true, configurable:true}` |
    | `Response.prototype.url` | accessor `{enumerable:true, configurable:true}` |
    | `Object.keys(new XMLHttpRequest()).length` | **0**（`getOwnPropertyNames` 也是 0） |
    | `Object.prototype.toString.call(new XMLHttpRequest())` | `"[object XMLHttpRequest]"`；`XMLHttpRequest.prototype[Symbol.toStringTag] === "XMLHttpRequest"` |
    | `Object.prototype.toString.call(new Response("x"))` | `"[object Response]"` |
  - **【本调研实测】`Object.defineProperty` 的语义陷阱（很容易搞错，务必记住）**：对**已存在**的属性做 `Object.defineProperty(o,k,{value:v, enumerable:true, configurable:true})`（**不写 `writable`**）：`writable` **保持原值 true**（不是默认 false）；但如果原本 `enumerable:false` 而现在写 `enumerable:true`，那就会**真的变成 true**：
    - `window.fetch` 打补丁后：`{writable:true, enumerable:true, configurable:true}`（**与原生完全一致**）
    - `window.XMLHttpRequest` 打补丁后：`{writable:true, **enumerable:true**, configurable:true}`（**原生是 false ⇒ 被改了，一行可查**）
- **`Event.isTrusted`（MDN）**："…is `true` when the event was generated by the user agent … and `false` when the event was dispatched via `EventTarget.dispatchEvent()`."；**【本调研实测】**：`el.dispatchEvent(new Event('x'))` → `isTrusted === false`。
- **【本调研实测】真实 XHR 事件基线（HeadlessChrome 148，`GET http://127.0.0.1:8931/`）**：
  `readystatechange(rs=1)` → `loadstart(rs=1)` → `readystatechange(rs=2)` → `readystatechange(rs=3)` → `progress(rs=3)` → `readystatechange(rs=4)` → `load(rs=4)` → `loadend(rs=4)`；
  全部 `isTrusted:true`、`target === currentTarget === xhr`；`readystatechange` 的 `constructor.name === "Event"`、其余为 `"ProgressEvent"`；`Object.prototype.toString.call(e)` 分别是 `[object Event]` / `[object ProgressEvent]`；`timeStamp` 是**相对量级**（54–61ms，不是 epoch 毫秒）。
  → 这就是"伪造 XHR"要对齐的靶子。

### 3.1 ajax-hook — <https://github.com/wendux/ajax-hook>

- **出处/读过的文件**：`src/xhr-hook.js`、`src/xhr-proxy.js`（tarball：`codeload.github.com/wendux/ajax-hook/tar.gz/refs/heads/master`）
- **拦截点（替换构造器，不 patch 原型方法）**：
  ```js
  export function hook(proxy, win) {
    win = win || window;
    var originXhr = win.XMLHttpRequest;
    var HookXMLHttpRequest = function () {
      var xhr = new originXhr();                    // 内部持有一个真 XHR
      … this[attr] = hookFunction(attr); … Object.defineProperty(this, attr, {get: getterFactory(attr), set: setterFactory(attr), enumerable: true}) …
      this[OriginXhr] = xhr;                         // var OriginXhr = '__origin_xhr';
    }
    HookXMLHttpRequest.prototype = originXhr.prototype;    // ← 保 instanceof
    HookXMLHttpRequest.prototype.constructor = HookXMLHttpRequest;
    win.XMLHttpRequest = HookXMLHttpRequest;
    Object.assign(win.XMLHttpRequest, {UNSENT:0, OPENED:1, HEADERS_RECEIVED:2, LOADING:3, DONE:4});
  }
  ```
  源码注释自认设计取舍："We shouldn't hookAjax XMLHttpRequest.prototype because we can't guarantee that all attributes are on the prototype. Instead, hooking XMLHttpRequest instance can avoid this problem."
- **抗检测性**：
  - ✅ `instanceof` 保住（`HookXMLHttpRequest.prototype === 原生 prototype`，连"提前保存的原生构造器"也成立）；`Object.prototype.toString` 仍是 `[object XMLHttpRequest]`；`window.XMLHttpRequest` 描述符不变（普通赋值）。
  - ❌ 实例上**每个成员都成了 own property**（方法复制、属性用 `defineProperty` 且**没写 configurable ⇒ 默认 false**）⇒【子调研实测】`Object.keys(xhr).length` ≈ 37–38（原生 0）、`hasOwnProperty('open') === true`、`'__origin_xhr' in xhr` 一行品牌识别、`readyState` 变成实例自有访问器且 `configurable:false`。
  - ❌ `HookXMLHttpRequest` 是普通 JS 函数 ⇒ `XMLHttpRequest.toString()`、`xhr.constructor.name`（压缩后甚至是 `"h"`）、`xhr.open.toString()` 全部暴露 JS 源码；全仓 grep 无 `toString`/`[native code]` 伪装。
  - ❌ **伪造 `isTrusted`**：`src/xhr-proxy.js:237` 有 `event.isTrusted = true;`（我亲自 grep 到），但事件对象是**纯对象**（不是 `Event` 实例）⇒【子调研实测】`e instanceof Event === false`、`[object Object]`、却报 `isTrusted:true`。这是"一眼假"的典型。
- **事件时序**【子调研实测】：有 `onRequest` 且 resolve 假响应时，`open()` 后 `readyState` 停在 **0**（因为 open 钩子返回 true 阻断了真实 open），`resolve()` 同步触发，只发 `readystatechange(0→4)` → `load` → `loadend`，**没有 loadstart/progress**；`send()` 返回后 readyState 仍 0，约一个宏任务后变 4（`config.async === false ? req() : setTimeout(req)`，`xhr-proxy.js:221`）；**upload 事件完全不合成**；`reject({type:'timeout'})` 后 readyState 仍 0（原生超时是 4）。
- **同步 XHR**：**支持**（同一个三目分支：同步时 `req()` 直接同步调用）。
- **responseType / headers**【子调研实测】：假响应**恒为字符串**（`xhrProxy.response = xhrProxy.responseText = response.response;`，`xhr-proxy.js:61`），`responseType` 为 json/arraybuffer/blob/document 时 `typeof xhr.response === 'string'`；`responseURL` 为 `""`；`getResponseHeader` 大小写敏感（provider 给 `'Content-Type'` 时 `getResponseHeader('Content-Type')` 与 `('content-type')` 都返回 null）。
- **要求的 world**：**MAIN world**。API 显式接受 `win`（`hook(proxy, win)`，默认 `window`），可传 `iframe.contentWindow`（README 说明只能拦**同源** iframe）。要拦页面自己的请求就必须把页面 realm 的 window 传进去。
- **局限**：只做 XHR（issue #129 "怎么样拦截fetch请求" = 不支持 fetch）；实例 own property 化导致形态失真；不再活跃。

### 3.2 xhook — <https://github.com/jpillora/xhook>

- **出处/读过的文件**：`src/main.js`、`src/patch/xmlhttprequest.js`、`src/patch/fetch.ts`、`src/misc/{window.js,event-emitter.ts,events.js,headers.js}`
- **拦截点（替换构造器 + 替换全局函数）**：`windowRef.XMLHttpRequest = Xhook;`（`xmlhttprequest.js:412`）、`windowRef.fetch = Xhook;`（`fetch.ts:149`，我亲自 grep 到）；导入即启用（`main.js`: `xhook.enable();`）。XHR 侧返回的是**纯对象 facade**：`var facade = EventEmitter();`（`xmlhttprequest.js:170`）。
- **抗检测性**：
  - ❌❌ **facade 根本不是 XHR 实例**：`grep -rn "prototype" src/` 全仓只命中 `src/misc/array.js` 的 `Array.prototype.slice` ⇒ 从不碰 `XMLHttpRequest.prototype`；`EventEmitter` 返回对象字面量 `const emitter = {}` ⇒ 原型链是 `Object.prototype` ⇒【子调研实测】`xhr instanceof XMLHttpRequest === false`（对保存下来的原生构造器也 false）、`Object.prototype.toString.call(xhr) === '[object Object]'`。
  - ❌ 实例 31 个自有可枚举 key、`hasOwnProperty('open') === true`、`xhr.open.name === ""`、`xhr.open.toString()` 泄漏源码；`xhr.upload` 是纯 EventEmitter 对象（`upload instanceof XMLHttpRequestUpload === false`）。
  - ⚪ 事件是**真 Event**、`isTrusted:false`（未伪造，这点是对的），但 `e.target` 被 `Object.defineProperty(..., "target", {writable:false, value:this})` 装成 **own data property**（原生是 prototype 访问器），`e.currentTarget === null`。
  - ❌ fetch 侧同样是普通 JS 函数替换 ⇒ `fetch.toString()` 暴露源码、`.name` 变化。
- **事件时序**【子调研实测】：`send()` 内部**同步**走完 readyState 1→2→3→4，`load`/`loadend` 被 `setTimeout(emitFinal, 0)` 推迟（源码 `if (request.async === false) { emitFinal(); } else { setTimeout(emitFinal, 0); }`）；假响应路径不发 `progress`。
- **同步 XHR**：**支持**，且 sync 时**跳过异步钩子**：`} else if (hook.length === 2 && request.async) { … } else { //skip async hook on sync requests  done(); }`（README："You may use synchronous XHR, though this will cause asynchronous hooks to be **skipped**."）——子调研**未能真正验证**这一条（其脚本被前一个 hook 抢先返回假响应），见 §9。
- **responseType / headers**【子调研实测】：fake + `responseType='json'` 时 `xhr.response === ""`（源码 `done()` 与 `writeBody()` 之间 `response.data` 与 `userResponse.data` 不一致的 bug）；`getResponseHeader` 大小写敏感；`responseURL` 未设置。fetch 侧返回**真 `Response`**（`new Response(...)`，`fetch.ts:97-106`），但 `r.url === ""`。
- **要求的 world**：**MAIN world**。`src/misc/window.js` 顶层探测 `WorkerGlobalScope`/`global`/`window`；README 明确加载顺序要求："⚠️ It's **important** to include XHook first as other libraries may store a reference to `XMLHttpRequest` before XHook can patch it"。
- **局限**：`instanceof` 直接破功；issue #165（别的库改了 prototype 后失效）、#177（facade 缺 `responseType`）、#151（打断 `navigator.sendBeacon`）。

### 3.3 fetch-intercept — <https://github.com/werk85/fetch-intercept>

- **出处/读过的文件**：`src/attach.js`、`src/browser.js`、`src/node.js`
- **拦截点（只替换全局 `fetch` 函数值）**：
  ```js
  module.exports = function attach(env) {
    if (!env.fetch) { try { require('whatwg-fetch'); } catch (err) { throw Error('No fetch avaibale…'); } }
    env.fetch = (function (fetch) { return function (...args) { return interceptor(fetch, ...args); }; })(env.fetch);
    return { register: …, clear: … };
  };
  // browser.js: module.exports = attach(ENVIRONMENT_IS_WORKER ? self : window);
  ```
- **抗检测性**：**最弱**——普通赋值（描述符不变）但 `fetch` 变成 IIFE 返回的匿名普通函数 ⇒ `fetch.name === ""`、`fetch.length === 0`（原生 `"fetch"`/1）、`Function.prototype.toString` 直接暴露源码；无任何伪装；不打补丁 XHR。**返回真 `Response`**（用户自己 `new Response`）是它相对 ajax-hook/xhook 的优势。
- **事件时序**：不涉及（纯 Promise 链：request 逆序 → fetch → response 正序）。
- **同步 XHR**：不适用（不支持 XHR）。
- **要求的 world**：**MAIN world**（patch 当前 realm 的 global）；README 只有加载顺序要求（"You need to require `fetch-intercept` before you use `fetch` the first time."）。
- **局限**：只覆盖 fetch；不拦 XHR/WS；无人维护。

### 3.4 `@mswjs/interceptors` — <https://github.com/mswjs/interceptors>（**本问最有参考价值**）

- **出处/读过的文件**：`src/interceptors/fetch/web.ts`、`src/interceptors/XMLHttpRequest/{web.ts,xml-http-request-proxy.ts,xml-http-request-controller.ts}`、`src/interceptors/WebSocket/{index.ts,web-socket-override.ts,utils/bind-event.ts}`、`src/utils/{patches-registry.ts,has-configurable-global.ts,create-proxy.ts,find-property-source.ts,fetch-utils.ts}`、`src/interceptor.ts`
- **拦截点**：
  - **XHR：`Proxy` 包裹原生构造器 + `Reflect.construct` 真实例**
    ```ts
    const XMLHttpRequestProxy = new Proxy(globalThis.XMLHttpRequest, {
      construct(target, args, newTarget) {
        const originalRequest = Reflect.construct(target, args, newTarget) as XMLHttpRequest;
        const prototypeDescriptors = Object.getOwnPropertyDescriptors(target.prototype);
        for (const propertyName in prototypeDescriptors) Reflect.defineProperty(originalRequest, propertyName, prototypeDescriptors[propertyName]);
        …
        return xhrRequestController.request;   // ← 真·原生 XHR 实例（被 Proxy/controller 挂钩）
      },
    });
    ```
    ⇒ `instanceof` 与原生访问器都保住；代价是**把整个原型的属性复制成实例 own 属性**（可检测）。
  - **fetch**：`patchesRegistry.applyPatch(globalThis, 'fetch', (realFetch) => async (input, init) => {…})` —— 这里是**普通 async 箭头函数**，`fetch.toString()` 会暴露源码（与 XHR 侧的 Proxy 策略不一致，是它的破绽）。
  - **WebSocket**：`new Proxy(globalThis.WebSocket, {construct})` + 自造 `class WebSocketOverride extends EventTarget implements WebSocket`（`web-socket-override.ts:19`）⇒ 不继承原生 WebSocket，`instanceof WebSocket` 不成立（子调研按源码结构推断，未实测）。
- **属性描述符处理（值得抄）**：`patches-registry.ts`
  ```ts
  if (match.descriptor.configurable) {
    Object.defineProperty(owner, key, { value: getNextValue(owner[key]), enumerable: true, configurable: true });
  } else if (match.descriptor.writable) { owner[key] = getNextValue(owner[key]); }
  ```
  - 【本调研实测】"不写 writable ⇒ 变 false"是**错的**（我已用 Chromium 148 证伪）：`window.fetch` 打完补丁描述符**完全不变**；**但** `window.XMLHttpRequest` 的 `enumerable` 会从 `false` 被改成 `true`（因为这里显式写了 `enumerable:true`）⇒ **一行 `Object.getOwnPropertyDescriptor(window,'XMLHttpRequest').enumerable` 就能识别**。
  - 另有 `has-configurable-global.ts`（补丁前检查可配置性，不可配置时 `console.error`）、`find-property-source.ts`（沿原型链找属性归属）、`create-proxy.ts`（`handler.get` 里显式注明 "Using `Reflect.get()` here causes **'TypeError: Illegal invocation'**"）⇒ 这份代码自己承认了"伪造对象 + 原生访问器"的陷阱。
- **伪造 `Response` 的做法**：`src/utils/fetch-utils.ts` 里 `export class FetchResponse extends Response {…}`，并用 `Object.defineProperty(response,'status'|'url', …)` 覆盖真实例属性、`clone()` 手工同步内部状态 ⇒ 响应是**真 Response 实例（子类）**：`instanceof Response` 成立、`[object Response]` 成立；但【子调研实测】`Object.prototype.hasOwnProperty.call(r,'url') === true`（原生 `url` 是原型 getter）、`r.constructor === Response` 为 false。
- **事件语义（三种不一致）**【子调研实测】：`readystatechange` 走自造 `EventPolyfill` → **`isTrusted = true` 显式伪造**（`polyfills/event-polyfill.ts:13` `public isTrusted: boolean = true`）+ `timeStamp = Date.now()`（epoch 量级）+ `[object Object]` + `e instanceof Event === false`；而 `load/progress/loadend` 用**真 `ProgressEvent`**（`create-event.ts`）→ `isTrusted:false`、`target === null`。⇒ 同一次请求里 `isTrusted` 一会儿 true 一会儿 false，比"全是 false"更容易被识别。
- **事件时序**【子调研实测】：`open()` → 原生 readystatechange@1；`send()` 用 `queueMicrotask` 延后触发 onRequest（源码注释：为了用户能先挂 `loadend`）；mock 序列 `loadstart → rs@2 → rs@3 → progress → rs@4 → load → loadend`，顺序符合规范；`total` 只从 `content-length` 推导；**唯一合成 upload 进度**的库。
- **同步 XHR：不支持，直接放行**：`if (this.sync) { console.warn(\`Failed to intercept an XMLHttpRequest (${this.method} ${this.url}): synchronous requests are not supported. This request will be performed as-is.\`); return invoke(); }`（`xml-http-request-controller.ts`）。⇒ 同步 XHR 会**悄悄走真实网络**，还会打印一句可搜索的固定文案。
- **responseType**【子调研实测】：json/arraybuffer/blob ✓；**document ✗**（`get response()` 没有 `'document'` 分支，返回字符串）；`responseText` 在 `responseType='json'` 时抛的是 `InvariantError`（`e.name === "Invariant Violation"`，**不是** `DOMException('InvalidStateError')`）。
- **要求的 world**：**MAIN world**（全部基于 `globalThis` 补丁；库自己 issue #321 里作者的描述就是"using a chrome extension to inject my code into the same execution context as the page"；#771 讨论两个扩展各自 Proxy 包裹导致叠加，说明同 realm 内的单例只在本扩展内有效）。
- **局限**：面向测试框架（依赖 `rettime`）；fetch 侧 `toString` 破绽；XHR 侧 own-property 与 `enumerable` 破绽；WS 侧 `instanceof` 破绽；`responseType='document'` 与同步 XHR 明确不支持。

### 3.5 sinon / nise 的 fake server — <https://github.com/sinonjs/nise>

- **出处/读过的文件**：`lib/fake-xhr/index.js`、`lib/fake-server/index.js`、`lib/fake-server/fake-server-with-clock.js`、`lib/event/{event.js,progress-event.js,event-target.js}`
- **拦截点（替换构造器 + 另起一套实现）**：`useFakeXMLHttpRequest()` 里 `globalScope.XMLHttpRequest = FakeXMLHttpRequest;`；`fakeServer.create()` → `this.xhr = fakeXhr.useFakeXMLHttpRequest();`；**不支持 fetch**（全仓 `fetch` 只出现在注释的 spec 链接里）。
- **抗检测性**：假 XHR 是纯 JS 类，不继承原生 `XMLHttpRequest.prototype` ⇒ 保存原生引用做 `instanceof` 为 false、`[object Object]`；`xhr.constructor.name === 'FakeXMLHttpRequest'`；方法在 prototype 上（`hasOwnProperty('open') === false`，比 ajax-hook/xhook"正常"一点）但 `xhr.open.toString()` 仍是源码；**事件是纯对象**——【我亲自读了 `lib/event/event.js`】它只有 `type/bubbles/cancelable/target/currentTarget/defaultPrevented` 与 `initEvent/stopPropagation/preventDefault`，**根本没有 `isTrusted`、`timeStamp`、`stopImmediatePropagation`、`composedPath`**；`EventTargetHandler` 把 `on*` 处理器中转到 addEventListener（`readystatechange` 不在其中的 relay 列表，由 `readyStateChange` 显式调用）。
- **事件时序**：`open()` → `readyStateChange(OPENED)` 同步；`respond()` 里按 `chunkSize || 10` 分块派发 LOADING（async），DONE 时 `progress = {loaded:100,total:100}`；`fakeServer.autoRespond` 用 `setTimeout(..., autoRespondAfter || 10)`；`respondImmediately` 同步 respond。
- **同步 XHR**：**支持**（`this.async = typeof async === "boolean" ? async : true;`，sync 分支不分块、不同步派发）。
- **要求的 world**：**MAIN world**（patch 你传入的 globalScope）。
- **局限**：**为单元测试设计**——装上以后所有 XHR 都不再真的发出去，靠 `server.respond()` 手动驱动；事件语义与 DOM Event 差距最大（连 `isTrusted` 都没有）；`xhr.upload` 是纯对象。

### 3.6 Tampermonkey / Violentmonkey 的 `unsafeWindow` 类做法

- **Tampermonkey**：`unsafeWindow` = "the `window` object of the page that Tampermonkey is running on"；要改页面真正的 `fetch` 必须让脚本跑在 `MAIN_WORLD`（`@sandbox raw`，默认）；CSP 挡住时会**静默降级**到别的 sandbox（此时 hook 不在页面 realm，拦截整体失效）；`@webRequest`/`GM_webRequest` 在 **MV3 版 5.2+ 已不可用**（本节均已引原文，见 §2.7(6)）。
- **Violentmonkey**：`@inject-into page|content|auto`；`page` 模式才能访问页面 JS 对象，`content`（隔离世界）**在 Chrome 里访问不到页面对象**；`auto` 在 CSP 阻挡时退化为 content script（§2.7(7)）。
- **对本项目的直接含义**：R4.1 要求"覆盖 MAIN WORLD 的注入脚本"⇒ **转发器本体必须能跑在 MAIN world**；隔离世界那份只能当"信使"。

### 3.7 页面如何检测自己被 hook（以及可行的反制）

| # | 检测手段 | 依据 | 现成库的表现 | 反制（可行性） |
|---|---|---|---|---|
| 1 | `Function.prototype.toString` 是否 `[native code]` | ECMA-262 第 1/3 步；【本调研实测】普通函数→源码、Proxy/bound→`NativeFunction` 但**丢名字** | ajax-hook/xhook/fetch-intercept/msw(fetch 侧) 全是 JS 源码；全仓无伪造 | **Proxy 包裹**（`toString` 变原生形态）＋**注意名字**：`fn.name` 与 `toString` 内容要自洽；**不能**彻底解决（干净 iframe 对照，见 #2） |
| 2 | 用**干净 iframe** 取一份未被 patch 的原生引用做对照（CreepJS 的 `getBehemothIframe()` 就是这个思路） | CreepJS 源码、invisible_playwright 文档："**A pristine reference.** Create an iframe, reach into its `contentWindow`, and take a clean copy of the built-ins from a context your patch never ran in. Then compare… it defeats page-level patching generally" | 所有 JS 层 hook 都挡不住 | **基本不可行**（除非引擎级修改） |
| 3 | 描述符/原型链巡检：`Object.getOwnPropertyDescriptor(window,'XMLHttpRequest').enumerable`、`getOwnPropertyNames(fn)` 是否只有 `['length','name']` | MDN + WebIDL 描述符规则；【本调研实测】原生 `window.XMLHttpRequest` 的 `enumerable` 是 **false** | **msw 把它改成 true**（可一行识别）；ajax-hook 给实例加 37–38 个 own 属性；xhook 31 个 | **可行**：`defineProperty` 时**显式写全**三个特性、对齐原生形态；尽量把成员留在 prototype |
| 4 | `Object.keys(xhr).length` / `hasOwnProperty('open')` | 原生 XHR 实例 own 属性 = **0**（【本调研实测】） | msw 26–27、ajax-hook 37–38、xhook 31；ajax-hook 还有品牌串 `'__origin_xhr' in xhr` | **可行**：内部状态放闭包/`WeakMap`；必须放实例时用 `Symbol`（但 `Reflect.ownKeys` 仍能看到） |
| 5 | `x instanceof XMLHttpRequest`（含提前保存的原生构造器） | MDN `instanceof` | ajax-hook ✅、msw ✅（`Reflect.construct`）；**xhook ❌、nise ❌** | **可行**（复用真实构造器/实例） |
| 6 | `Object.prototype.toString.call(x)` / `Symbol.toStringTag` | WebIDL class string 规则 | ajax-hook/msw ✅ `[object XMLHttpRequest]`；xhook/nise ❌ `[object Object]` | 可行但注意：把 tag 放**实例**上就是 own 属性（回到 #3/#4） |
| 7 | 事件真实性：`isTrusted`、`timeStamp` 量级、`target/currentTarget`、`e instanceof Event` | MDN；【本调研实测】原生全 `isTrusted:true`、`target===currentTarget===xhr`、timeStamp 相对量级（~55ms）、`[object Event]`/`[object ProgressEvent]` | ajax-hook **伪造 `isTrusted=true`**（纯对象）；msw 的 `readystatechange` 伪造 `isTrusted=true` + epoch timeStamp + `[object Object]`；xhook/nise 没伪造但 target/currentTarget/构造器不对 | **不要伪造 `isTrusted`**（只能靠 UA 真派发）；改用真 `Event`/`ProgressEvent` 构造器并让 `target/currentTarget/timeStamp` 语义对齐；`isTrusted:false` 本身在合法 `dispatchEvent()` 场景也会出现，不必强求 true |
| 8 | 状态机/时序观测（`readyState` 序列、`loadstart`/`progress`/`upload` 是否缺失、`send()` 返回时的 readyState） | XHR 规范 + 【本调研实测】原生序列（§3.0） | ajax-hook：open 后 rs 仍 0、无 loadstart/progress/upload；xhook：send() 返回时 rs 已 4；nise：分块派发但事件类型不同 | **可行但工作量大**：严格按规范顺序派发（含 loadstart/progress/upload/loadend），别在 `send()` 返回前把 rs 推到 4 |
| 9 | 同步 XHR / 固定日志 / 错误类型指纹 | 规范；【子调研实测】msw 对 `open(...,false)` 打印固定 `console.warn` 并放行；`responseText` 误用抛 `InvariantError` 而非 `DOMException` | msw 明确不支持同步 XHR | **可行**：同步路径必须真支持；错误一律用真 `DOMException`；别打可搜索的日志 |
| 10 | `Error().stack` 栈帧指纹（CreepJS 用 `AT_FUNCTION`/`PROXY_INSTANCE` 正则） | CreepJS `creep/src/lies/index.ts` | 任何 JS 层 hook 都会留帧 | **不可行**（只能减少层数、避免 Proxy 中转） |
| 11 | `document.currentScript` 检查脚本来源 | MDN `Document.currentScript` | 扩展 MAIN world 注入在页面侧没有对应 `<script>` 元素 | **无出处可引**：本次未找到"扩展注入是否可被 currentScript 检测"的权威说明（§9） |
| 12 | `navigator.webdriver` | MDN | 与 hook 无关（三个库都不碰） | 误判项；本项目也不该去改它 |

**结论**：抗检测的"最高性价比"组合是 **Proxy 包裹 + 原描述符形状 + 真实例（`Reflect.construct`）+ 真 `Response`/`Event` 构造器 + 不伪造 `isTrusted` + 严格状态机**；`isTrusted`、栈帧、干净 iframe 对照是三处**无法消除**的固有差异，只能减少暴露面。对本项目（服务的是一心想连 aria2 的前端，而非对抗性反爬站点）而言，**优先级应是"语义正确"高于"不可检测"**：错乱的 `readyState`/`status` 会让 AriaNg 直接误判失败（子调研举了 msw issue #321 的真实站点案例：页面在 `onload` 里读到 `xhr.status === 0` 而误判失败）。

---

## 4 第三问：能否拦截或修改「其它扩展」的网络请求

> 结论先行：**不能**（对本项目的实际动机而言，见 §4.6）。逐条给证据。

### 4.1 content script 能不能注入到 `chrome-extension://` 页面？

**结论：别家 = 不能；自家 = 不能（声明式/动态 content script 是硬性不能；`executeScript` 也基本不可能，且无官方明文）。**

- **match pattern 规范层**：<https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns> 原文："`scheme`: Must be one of the following… `http` / `https` / A wildcard `*`, which matches only `http` or `https` / `file`"；"`<all_urls>` Matches any URL that starts with a permitted scheme"。我抓的全文**不含 `chrome-extension`**（也不含 `ftp`）。
- **代码层（决定性）**：content script 的 `matches` 用"用户脚本可注入 scheme"位掩码解析，**不含 `SCHEME_EXTENSION`**：
  - `extensions/common/user_script.cc`（我亲自抓取，逐字）：
    ```cpp
    // The bitmask for valid user script injectable schemes used by URLPattern.
    enum {
      kValidUserScriptSchemes = URLPattern::SCHEME_CHROMEUI | URLPattern::SCHEME_HTTP | URLPattern::SCHEME_HTTPS |
                                URLPattern::SCHEME_FILE | URLPattern::SCHEME_FTP | URLPattern::SCHEME_UUID_IN_PACKAGE
    };
    ```
    以及 `UserScript::ValidUserScriptSchemes(bool can_execute_script_everywhere)`：`if (can_execute_script_everywhere) return URLPattern::SCHEME_ALL;`（只有 component/白名单扩展才拿到 SCHEME_ALL）。
  - `extensions/common/utils/content_script_utils.cc`（我亲自抓取）：`ParseMatchPatterns()` 里 `const int valid_schemes = UserScript::ValidUserScriptSchemes(can_execute_script_everywhere); URLPattern pattern(valid_schemes); pattern.Parse(match_str)`。
  - 同一函数被 `chrome.scripting.registerContentScripts` 复用（子调研追到 `scripting_api.cc` → `script_serialization.cc` → `ParseMatchPatterns`）。
  - ⇒ 显式写 `chrome-extension://…/*` **解析失败**；`<all_urls>`、`*://*/*` 也不会命中扩展页。**自家扩展页同样不命中**（白名单里根本没有这个 scheme）。
- **MDN（跨浏览器）**：`raw.githubusercontent.com/mdn/content/.../content_scripts/index.md` 原文："**Extensions cannot inject content scripts into privileged browser UI pages** (such as `about:debugging`, `about:addons`, reader view, view-source, or the PDF viewer) **or extension pages**."；并给出正确做法："If an extension wants to run code in an extension page dynamically, it can include a script in the page…"
- **`executeScript` 的 host permission 也匹配不到 `chrome-extension://`**：`extensions/common/extension.cc:217` `kValidHostPermissionSchemes = SCHEME_CHROMEUI|HTTP|HTTPS|FILE|FTP|WS|WSS|UUID_IN_PACKAGE`（**无 SCHEME_EXTENSION**）⇒ `PermissionsData::CanAccessPage()` 对扩展页必然 kDenied（**自家页也一样**，因为没有 pattern 能 match 上）。`IsRestrictedUrl()` 只对"**别人家**的扩展 URL"给出 `kCannotAccessExtensionUrl`（§4.2 引原文），自家 URL 走到的是 host-permission 那一层。
- **渲染进程侧**：`extensions/renderer/extension_injection_host.cc`（子调研引用，逐字）："`// Only allowlisted extensions may run scripts on another extension's page.`" + `if (outermost_origin->scheme() == kExtensionScheme && outermost_origin->host() != extension_->id() && !PermissionsData::CanExecuteScriptEverywhere(...)) return kDenied;`
- **CG 佐证**：<https://github.com/w3c/webextensions/issues/1054>（open）请求"允许扩展在**自己的沙箱扩展页**里 executeScript"，并说 "**This is currently not possible** if part of the extension's functionality involves injecting code."
- **文档沉默处**：**"自家扩展页能否 `chrome.scripting.executeScript`"查不到官方明文**；最接近的是上面的权限/注入源码（指向"不行"）与 #1054 ⇒ 标为**有条件/待实测**（§9）。
- **对本项目的意义（重要）**：R5 说的"扩展页注入失败"**不是偶发**，而是**声明式 content script 在本项目内置 UI 上结构性不可用**；R5 允许的"换装载方式"（例如内置页面里直接 `<script src>` 打包好的同一份转发器）实际上是**唯一可行**的做法。见 §8。

### 4.2 `chrome.webRequest` 能不能看到并改写其它扩展发起的请求？

**结论：不能（MV2 与 MV3 都不可行）。**

1. **闸门一：同进程过滤**（`extensions/browser/api/web_request/extension_web_request_event_router.cc` → `WebRequestEventRouter::ListenerMatchesRequest()`，我亲自抓取，逐字）：
   ```cpp
   // Filter requests from other extensions / apps. This does not work for
   // content scripts, or extension pages in non-extension processes.
   if (is_request_from_extension &&
       listener.id.render_process_id != request.global_id.child_id) {
     return false;
   }
   ```
   其中 `IsRequestFromExtension()`（同文件）：
   ```cpp
   // Returns whether |request| has been triggered by an extension enabled in |context|.
   bool IsRequestFromExtension(const WebRequestInfo& request, content::BrowserContext* context) {
     if (!request.global_id.child_id) return false;
     const Extension* extension = ProcessMap::Get(context)->GetEnabledExtensionByProcessID(request.global_id.child_id);
     return extension && !extension->is_hosted_app();
   }
   ```
   ⇒ 扩展进程发起的请求只投递给**同进程**的监听者（即它自己）；注释还暴露了已知漏洞面："This does not work for content scripts, or extension pages in non-extension processes."
2. **闸门二：initiator 的 host permission 永远拿不到**（同函数继续，逐字）：
   ```cpp
   PermissionsData::PageAccess access = WebRequestPermissions::CanExtensionAccessURL(
       PermissionHelper::Get(&browser_context), listener.id.extension_id,
       request.url, request.frame_data.tab_id, crosses_incognito,
       WebRequestPermissions::REQUIRE_HOST_PERMISSION_FOR_URL_AND_INITIATOR,
       request.initiator, request.web_request_type);
   if (access != PermissionsData::PageAccess::kAllowed) { … return false; }
   ```
   `web_request_permissions.cc` 中该模式对**非导航请求**的判定：
   ```cpp
   case WebRequestPermissions::REQUIRE_HOST_PERMISSION_FOR_URL_AND_INITIATOR: {
     PageAccess request_access = GetHostAccessForURL(*extension, url, tab_id);
     …
     if (is_navigation_request) return request_access;        // ← 导航不看 initiator
     if (request_access == PageAccess::kDenied) return request_access;
     if (!initiator || initiator->opaque()) return request_access;
     return GetHostAccessForURL(*extension, initiator->GetURL(), tab_id);   // ← 子资源要看 initiator
   }
   ```
   而 host permission 的 scheme 掩码被 `Extension::kValidHostPermissionSchemes` 限定（`extensions/common/extension.cc`，逐字）：
   ```cpp
   const int Extension::kValidHostPermissionSchemes =
       URLPattern::SCHEME_CHROMEUI | URLPattern::SCHEME_HTTP | URLPattern::SCHEME_HTTPS |
       URLPattern::SCHEME_FILE | URLPattern::SCHEME_FTP | URLPattern::SCHEME_WS |
       URLPattern::SCHEME_WSS | URLPattern::SCHEME_UUID_IN_PACKAGE;
   ```
   **不含 `SCHEME_EXTENSION`** ⇒ 任何 `<all_urls>`/任何 match pattern 都拿不到"别的扩展 origin"的 host permission ⇒ **看不到该请求**。（对照 `url_pattern.h` 对 `SCHEME_ALL` 的注释："**SCHEME_ALL will match every scheme, including chrome://, chrome-extension://, about:, etc. Because this has lots of security implications, third-party extensions should usually not be able to get access to URL patterns initialized this way.**"）
3. **官方文档口径**（<https://developer.chrome.com/docs/extensions/reference/api/webRequest>）：
   - "Starting from Chrome 72, an extension will be able to intercept a request **only if it has host permissions to both the requested URL and the request initiator**."；"To intercept a sub-resource request, the extension must have access to both the requested URL and its initiator."
   - 隐藏规则："In addition, even certain requests with URLs using one of the above schemes are hidden. These include **`chrome-extension://other_extension_id` where `other_extension_id` is not the ID of the extension to handle the request**, … Also **synchronous XMLHttpRequests from your extension are hidden from blocking event handlers in order to prevent deadlocks.**"
   - `initiator` 字段："The origin where the request was initiated. This does not change through redirects. If this is an opaque origin, the string 'null' will be used."（**文档没有给出扩展发起的示例值**，属推断，见 §9）
4. **官方浏览器测试的注释（决定性，我亲自抓取 `chrome/browser/extensions/api/web_request/web_request_apitest.cc:2291-2299`，逐字）**：
   ```
   // The extension frame does run in the extension's process. Any requests made
   // by it should not be visible to other extensions, since they won't have
   // access to the request initiator.
   //
   // OTOH, the content script executes fetches/XHRs as-if they were initiated by
   // the webpage that the content script got injected into.  Here, the webpage
   // has origin of http://127.0.0.1:<some port>, and so the webRequest API
   // extension should have access to the request.
   EXPECT_EQ("Intercepted requests: ?contentscript", listener_result.message());
   ```
   这一段同时确认了 §4.6 的两种情况：(ii)/(iii) 看不到、(i) 能看到。
5. **MV2 vs MV3**：可见性同一份代码；差别只在"看到后能不能改"（MV2 blocking 能 cancel/redirect，MV3 只能看）。
6. **唯一例外**：`is_navigation_request`（`main_frame`/`sub_frame`）**不看 initiator** ⇒ 别家扩展发起的**导航**请求可以被我们"看到"（MV3 下依然改不了）。

### 4.3 `declarativeNetRequest` 能不能匹配/改写其它扩展发起的请求？

**结论：不能（非导航请求）；`chrome-extension://` 的请求 URL 一律不评估；`main_frame` 导航是唯一例外。** 证据（`extensions/browser/api/declarative_net_request/ruleset_manager.cc`，我亲自抓取）：

```cpp
bool RulesetManager::ShouldEvaluateRulesetForRequest(
    const ExtensionRulesetData& ruleset, const WebRequestInfo& request,
    bool is_incognito_context, PageAccess& host_permission_access) const {
  // Extensions should not generally have access to non-main-frame requests
  // initiated by other extensions, though the --extensions-on-chrome-urls
  // switch overrides that restriction.
  // Note: For discussions regarding handling of extension initiated navigations
  //       see crbug.com/41433450 and crbug.com/382670035.
  if (!switches::AreExtensionsOnExtensionURLsAllowed() && request.initiator &&
      request.web_request_type != WebRequestResourceType::MAIN_FRAME) {
    // Checking the precursor is necessary here since requests initiated by
    // manifest sandbox pages have an opaque initiator origin, but still
    // originate from an extension.
    auto initiator_precursor = request.initiator->GetTupleOrPrecursorTupleIfOpaque();
    if (initiator_precursor.scheme() == kExtensionScheme &&
        initiator_precursor.host() != ruleset.extension_id) {
      return false;
    }
  }
```
```cpp
  // Prevent extensions from modifying any resources on the chrome-extension
  // scheme. Practically, this has the effect of not allowing an extension to
  // modify its own resources (The extension wouldn't have the permission to
  // other extension origins anyway).
  if (request.url.SchemeIs(kExtensionScheme)) {
    return false;
  }
```
- **官方单测（我亲自抓取 `chrome/browser/extensions/api/declarative_net_request/ruleset_manager_unittest.cc:1211-1296`）**：
  - "// Tests that extensions can't block requests initiated by other extensions by default." + "// Note: The --extensions-on-chrome-urls switch isn't tested here, see the CrossExtensionRequestBlocking browser test."
  - "// Extensions should be able to block requests that they initiated."
  - "// Extensions should not be able to block (non-navigation) requests initiated…"
  - "// Extensions should be able to block main_frame navigation requests initiated…"
  - "// Extensions should not be able to block sub_frame requests initiated by…"
  - 另有 `RulesetManagerTest.ExtensionScheme` 证明 `chrome-extension://` URL 一律不匹配。
  - 子调研另引浏览器端 E2E `declarative_net_request_browsertest.cc`："Ensure that an extension can block requests that it initiated, but not non-navigation requests that other extensions initiated, unless the `--extensions-on-chrome-urls` switch is used."（该文件我未逐行复核，见 §9）
- **`initiatorDomains` 能否表达扩展 id？** 文档（<https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest#property-RuleCondition-initiatorDomains>）："The rule will only match network requests originating from the list of `initiatorDomains`. … **This matches against the request initiator and not the request url.**"；`excludedInitiatorDomains` 的 Notes 还写："For requests with no associated top-level frame (e.g. **ServiceWorker initiated requests**, the request initiator's domain is considered instead."（SW 请求也看 initiator 的 domain，而 `chrome-extension://<id>/` 的 host 恰好是 `<id>`，**语法上像能写**）——**但即使写得进去也没用**：上面的 `ShouldEvaluateRulesetForRequest()` 在评估前就把"别家扩展发起的非导航请求"整条排除。
- **`urlFilter`/`regexFilter` 能否匹配 `chrome-extension://`？** 不能：正则是"matched against the network request url"，但 DNR **根本不对 `chrome-extension://` 的请求 URL 做评估**（`request.url.SchemeIs(kExtensionScheme) → return false`）。与 scheme 有关的唯一能力是 `URLTransform.scheme` 允许把请求**改写成** `chrome-extension`（那是"把 http 请求指向扩展资源"）。
- **主框架导航是例外**：条件写的是 `request.web_request_type != MAIN_FRAME`，所以别家扩展发起的 main_frame 导航理论上可被 block/redirect；对 aria2 RPC（XHR/fetch）无意义。
- **文档沉默**：**"DNR 不适用于其它扩展请求"没有明文文档**；最接近的是上面的源码注释 + 单测 + E2E。

### 4.4 `chrome.debugger` 能不能附加到"恰好在一个标签页里打开的"别的扩展页面？

**结论：不能（除 `--extensions-on-chrome-urls`）；别家的 Service Worker 也不能。**

`chrome/browser/extensions/api/debugger/debugger_api.cc`（我亲自抓取）：
```cpp
// Returns true if the given |Extension| is allowed to attach to the specified |url|.
bool ExtensionMayAttachToURL(const Extension& extension, Profile* extension_profile, const GURL& url, std::string* error) {
  // Allow the extension to attach to about:blank and empty URLs.
  if (url.is_empty() || url == "about:" || url.IsAboutBlank()) return true;
  …
  bool allow_on_extension_urls = ::extensions::switches::AreExtensionsOnExtensionURLsAllowed();
  if (url_for_restriction_check.SchemeIs(extensions::kExtensionScheme) &&
      url_for_restriction_check.host() != extension.id() &&
      !allow_on_extension_urls) {
    *error = manifest_errors::kCannotAccessExtensionUrl;
    return false;
  }
```
而"按标签页附加"正走这条：`ExtensionMayAttachToWebContents()` → `ExtensionMayAttachToURL(extension, profile, web_contents.GetLastCommittedURL(), error)`，并且连**待提交的导航条目**也一起检查（`GetController().GetPendingEntry()->GetURL()`）。
- **别家 SW（`targetId` 路径）**：同函数 → SW 的 URL 是 `chrome-extension://<别家>/sw.js` ⇒ 同样被拒（子调研指出 worker 父级校验只覆盖 `kTypeDedicatedWorker|kTypeSharedWorker|kTypeOther`，**不含 `kTypeServiceWorker`**，所以只剩 URL 检查，结论不变）。
- **`extensionId` 路径双重受限**：文档原文 "The id of the extension which you intend to debug. **Attaching to an extension background page is only possible when the `--silent-debugger-extension-api` command-line switch is used.**"
- **类型澄清**：`chrome.debugger` **没有** `TargetType` 这个类型；有 `TargetInfoType` = `"page" | "background_page" | "worker" | "other"`（文档散文句里的 "iframe, shared_worker" 与枚举不一致）；CDP 真实类型见 `content/browser/devtools/devtools_agent_host_impl.cc`（tab/page/iframe/worker/shared_worker/service_worker/…）。
- **`getTargets()` 能枚举**：子调研引 `DevToolsAgentHost::GetOrCreateAll()`（只跳过 tab target 与 privileged WebContents，`SerializeTarget` 把 service_worker/shared_worker 映射为 `"worker"`）⇒ 我们**能看到**别家 SW 的 targetId 与 url，但**附不上**。
- 相关旁证（子调研引用，逐字）："`// ... This is done to fix crbug.com/40213673 because an extension cannot inspect another extension.`"

### 4.5 其它机制（逐个判死）

| 机制 | 能否接住第三方扩展的 localhost:6800 请求 | 依据 |
|---|---|---|
| `chrome.proxy` / PAC | **不能**：PAC 只能 `return 'PROXY host:port' \| 'DIRECT'`，不改 URL、不伪造响应体；要伪造 JSON-RPC 必须有个真实 HTTP 服务端（而扩展不能监听端口，R8）。"扩展请求是否经过 PAC"**查不到明确文档** | <https://developer.chrome.com/docs/extensions/reference/api/proxy> |
| `webRequest.onAuthRequired` | **不能**：受 §4.2 同一可见性限制，且只能给凭据/取消 | webRequest 文档权限表（MV3 需 `webRequestAuthProvider`） |
| `externally_connectable` + 跨扩展消息 | **不能（除非对方配合）**："If the `externally_connectable` key is not declared in your extension's manifest, all extensions can connect, but no web pages can connect."；仍需对方实现 `onMessageExternal` 并愿意改用我们的端点 | match patterns 文档 |
| `chrome.runtime.connect` 跨扩展 | 同上 | — |
| `chrome.userScripts` API | **不能**命中扩展页/别家请求：MV3+，需用户打开开关（"Allow User Scripts"），注入 scheme 同 §4.1 的用户脚本白名单（无 chrome-extension） | userScripts 文档 |
| DNR redirect 到 `chrome-extension://<our-id>/…` | **有条件但无用**：① 别家扩展的非导航请求在评估前被排除；② 即便命中，目标必须 `web_accessible_resources`，且 **POST 会被 `net::ERR_UNSAFE_REDIRECT` 打死**（Chromium 324676520）；③ 只能给静态资源，**没有动态响应体** | §4.3 + §2.3 |
| Firefox `webRequest.filterResponseData` | **不能跨扩展**：仍是 webRequest 权限模型（initiator host permission），且 Firefox 专有 | §2.6 |
| Firefox 对别家扩展请求的可见性 | **未验证**（无 Firefox 可测） | §9 |

### 4.6 结论（面向实际动机）

**问：能不能让一个第三方的 aria2 前端扩展（它自己会去连 `localhost:6800`）发出的请求被我们接住？**
**答：不能（按当前 Chromium 的明文设计），因此不能省掉自带 UI。**

| 请求发起位置 | 我们能否看到 | 能否改写/伪造响应 |
|---|---|---|
| **(i) 普通网页上下文**（含别家 content script 注入进网页后发出的 fetch/XHR） | **能**（官方测试注释逐字："the content script executes fetches/XHRs **as-if they were initiated by the webpage**… so the webRequest API extension should have access to the request."） | MV2+blocking / 策略扩展可 block/redirect；MV3 普通扩展只能看，改写需 DNR（且 DNR 无响应体）。**但 MAIN world 的 JS 补丁拦不到"隔离世界的 content script 发出"的请求**（见下） |
| **(ii) 别家扩展的 MV3 Service Worker / MV2 后台页** | **不能**（§4.2 双闸；DNR 侧也被 §4.3 排除） | 不能 |
| **(iii) 别家扩展页渲染在标签页里** | **不能**（同上；DNR 对 `chrome-extension://` URL 直接 skip；debugger 也附不上，§4.4） | 不能 |

补充两条容易误解的细节：
- **(i) 里"能改写"≠"能接住 RPC"**：MV3 的 DNR 不能合成响应体，所以在 (i) 情形下我们也只能 block/redirect，无法给 AriaNg 一个 JSON-RPC 响应。
- **(i) 里"JS 补丁"也帮不上**：如果那个第三方扩展是在自己的 content script（隔离世界）里 fetch，MAIN world 的补丁**改不到隔离世界的 `fetch`**（MDN：页面重定义内置属性对 content script 不可见；Chrome 文档：各自 world 互不可见）——这时只有 DNR/webRequest 这条"看得见但造不出响应"的路。

**唯一真正的"能"**：如果那个前端**不是扩展而是网页**（`http(s)://` 页面里跑 AriaNg），它发出的请求就是普通页面请求，我们的 MAIN-world 转发器 + R9 路线完全适用。⇒ **R4.2（内置 UI）不可省**；但"内置"可以是把 AriaNg 的静态产物打进扩展、在内置页面里用同一份转发器（§8 对 R5 的建议）。
**边界条件**：`--extensions-on-chrome-urls` / `--extensions-on-extension-urls` 这类**命令行开关**会解除 DNR 侧的跨扩展限制（有官方 E2E 测试），webRequest 侧的进程过滤连这个开关都不看；普通用户不可能满足。

---

## 5 硬约束（逐条给证据）

1. **Chrome 上 MV2 blocking 已不可用**（普通安装）："Chrome 138 is the final version of Chrome to support Manifest V2 extensions" + "this is only available to policy installed extensions"（§2.1）。
2. **MV3 只读 webRequest 不能 cancel/redirect/改头，也没有响应体**：`BlockingResponse` 只对 blocking 监听者生效；`kBlockingPermissionRequired` 错误文案；文档无响应体字段（§2.2）。
3. **DNR 不能合成响应体**：`RuleAction` WebIDL 无 body 字段；CG #868 把"合成 200 响应"作为**待实现**提案；POST 重定向到扩展资源会 `ERR_UNSAFE_REDIRECT`（§2.3）。
4. **Chrome 没有 `filterResponseData`**：BCD `chrome: {"version_added": false}`（§2.6）。
5. **`chrome.debugger` + `Fetch.fulfillRequest` 能返回任意响应体**（CDP 规范 + Tamper Dev v2 源码），且 attach 期间 SW 被 `kDoesNotTimeout` 保活；代价是 infobar、与 DevTools 互斥、附加范围受限（§2.4）。
6. **扩展不能监听 TCP 端口**：MV3 扩展 API 列表里没有 sockets（子调研核对了 API 列表页，搜 "sockets" 0 命中）；这也是项目 R8 的前提。
7. **隔离世界与页面各自持有独立的 JS 内置绑定**：MAIN world 补丁对隔离世界无效（Chrome 文档"none of these … can access the context and variables of the others"+ MDN"页面重定义内置属性对 content script 不可见"）（§2.5、§4.6）。
8. **`chrome-extension://` 不是合法的 content script match scheme**：`kValidUserScriptSchemes` 不含 `SCHEME_EXTENSION`（**自家页也不行**）；MDN 明文"cannot inject … extension pages"（§4.1）。
9. **host permission 的 scheme 掩码不含 `SCHEME_EXTENSION`** ⇒ 永远拿不到"别的扩展 origin"的 host 权限（§4.2）。
10. **webRequest 只向"同进程"监听者投递扩展发起的请求**（源码注释 + 官方浏览器测试断言）（§4.2）。
11. **DNR 明文跳过"别家扩展发起的非导航请求"**，且不评估 `chrome-extension://` 请求 URL（源码 + 单测）（§4.3）。
12. **`chrome.debugger` 不能附加到别家扩展的页面/后台页/SW**（`ExtensionMayAttachToURL` + `--silent-debugger-extension-api`）（§4.4）。
13. **`Event.isTrusted` 无法伪造为 true**（MDN + 【本调研实测】）；真实 XHR 事件的 `isTrusted` 全为 true（§3.0）。
14. **`Function.prototype.toString` 只对"普通 JS 函数替换"暴露源码**；Proxy/bound 走 NativeFunction 分支，但**名字会丢**（【本调研实测】，§3.0）。
15. **`Object.defineProperty` 对已存在属性不写 `writable` 不会重置为 false**，但写 `enumerable:true` 会真的改掉 enumerable（【本调研实测】；msw 的 `window.XMLHttpRequest` 就踩了这一条）（§3.4）。

---

## 6 对本项目的可用性判断

1. **转发器本体：MAIN world 的 JS API 补丁是唯一同时满足 R4.1（多途径）× R9（请求不发出去）× R10（结果兑现）的方案。**
   - 必须覆盖 `fetch`、`XMLHttpRequest`、`WebSocket`（webRequest 只看 WS 握手、DNR 更不可能）。
   - 参考取舍：**XHR 侧学 msw 的 `Proxy + Reflect.construct`**（保住 `instanceof`、原生访问器、`toString` 形态），但**不要**照抄它"把原型描述符全复制到实例"的做法（26–27 个 own 属性是现成的检测点），也不要照抄它"`enumerable:true` 覆盖接口对象"的写法；**fetch 侧不要用普通函数替换**（msw 在 fetch 侧就暴露源码），用 Proxy 并把 `name`/`length` 与 `toString` 内容对齐；**响应对象用真 `Response`**（必要时子类化，注意 `constructor` 会变）。
   - **Requestly 的 MV3 实现（`executeScript({world:'MAIN'})` + fetch/XHR 双补丁 + `new Response(new Blob([customResponse]))`）是与本项目最接近的商业级样板**（§2.7(1)）。
2. **同步 XHR 必须支持**：ajax-hook/xhook/nise 都有显式同步分支，而 **msw 直接放弃**（打印 `console.warn` 并放行真实请求）。命中拦截且 `open(...,false)` 时必须在 `send()` 内**同步**完成 `readyState=4`/`status`/`responseText`。这直接影响 Mock 层设计：**同步路径上不能出现任何 `await`/storage/SW 往返**，需要一个内存镜像（Q-D5 的持久状态要另想办法）。
3. **`WebSocket` 必须自造类**（参考 msw 的 `WebSocketOverride` + 自建 transport；注意别丢 `instanceof`），推送用 Q-D3 的"转发器轮询 + 本地派发"。
4. **打补丁时逐字对齐原生描述符**：`window.fetch` 是 `{w:true,e:true,c:true}`；`window.XMLHttpRequest`/`window.WebSocket` 是 `{w:true,e:false,c:true}`；`XMLHttpRequest.prototype.open` 是 `{w:true,e:true,c:true}`（【本调研实测】基线，§3.0）。
5. **隔离世界只能当"信使"**（`CustomEvent`/`postMessage`）；R5 的"内置 AriaNg UI 不走特殊通道"在实现上意味着**内置页面也要加载同一份 MAIN world 转发器**——而由于 §4.1（content script 无法注入任何扩展页），这条路只能是"页面内直接 `<script>` 引入同一份文件"，**路径不变、装载方式不同**，正好落在 R5 允许的例外里。
6. **网络层手段不要用于主链路**：DNR 无响应体、只读 webRequest 无能、`chrome.debugger` 能行但代价高（infobar + F12 即失效 + per-tab attach + 需要处理每个 `requestPaused`）且**与 R9 冲突**；建议只作为"观测/兜底"第二通道（Q-D6 Mock 控制台可以用它看真实流量）。
7. **"接住第三方 aria2 前端扩展"应判定为不可行**（§4.6）⇒ R4.2 的内置 UI 不可省；若未来想利用现成前端，可行方向是"把前端当**网页**用"（本机/在线 AriaNg、或扩展内置页里以 iframe/`<script>` 方式跑同一份静态产物），而不是"接住别的扩展"。

---

## 7 失败模式与盲区

1. **隔离世界的请求拦不到**（扩展自身 content script / 其他扩展的 content script / `content` 模式的用户脚本）；若 Mock 层自己用隔离世界的 `fetch` 发请求，也可能被自己的规则误伤。
2. **`document_start` 之前已发出的请求拦不到**（Q-D2 已列）；`injectImmediately` 的文档注释明确说"不保证早于页面加载"。
3. **CSP 严格页面 MAIN world 注入失败**（Tampermonkey/Violentmonkey 官方文档都把 CSP 列为 `raw`/`page` 模式失败的原因，失败后会**静默降级**到隔离世界 ⇒ 拦截整体失效）。
4. **不能注入的页面**：`chrome://`、`chrome-extension://`（**含自家**）、PDF viewer、view-source、Web Store（`IsScriptableURL`）。
5. **Worker 内的 `fetch`**：Web Worker / SW 有自己的全局，MAIN world 补丁覆盖不到（Q-D2 的"能做到就拦"）。
6. **同步 XHR 的负担**：同步返回前必须给出完整响应 ⇒ 同步路径不能有异步依赖。
7. **事件/字段完整度**：`onprogress`/`upload.onprogress`/`ontimeout`/`onabort`、`responseType`（`blob|arraybuffer|document|json|stream`）、`getAllResponseHeaders()` 的大小写与结尾 CRLF、`responseURL`、`status===0` 等——任何一个不对，AriaNg 之类的客户端就可能走偏（三个库在这里都有实测破绽：ajax-hook 假响应恒为字符串、xhook 的 `responseType='json'` 返回空串、msw 的 `document` 类型返回字符串且错误类型不是 `DOMException`）。
8. **`isTrusted === false`**（合成事件）无法消除；**不要**伪造为 true。
9. **WS 的握手与消息是两套语义**：JS 层拦 WS 需要自己实现 `WebSocket` 类 + 断线/重连/close code/`bufferedAmount` 语义，是 R4.1 里最重的一块。
10. **多 world / 多扩展重复包裹**：msw 的 issue #771 记录了"两个扩展各自 `new Proxy(globalThis.XMLHttpRequest)`"导致叠加；我们要做幂等标记（注意：标记本身也可能成为指纹）。
11. **DNR/webRequest 作为第二通道时的"全局命中"副作用**：Q-D1 只允许一条精准 URL，但 DNR 规则天生是扩展级、对所有 tab/所有来源生效（概念文档附录 A 已注意到这一点）。
12. **`chrome.debugger` 路线的特有失败**：用户按 F12 → `canceled_by_user` → 拦截静默失效；企业策略可整体封禁；每个 target 一个调试客户端。

---

## 8 与现有裁定的冲突（尤其 R9 与 R5）

| 裁定 | 本调研的发现 | 是否冲突 | 建议 |
|---|---|---|---|
| **R9 拦截发生在 JS API 层** | 与能力边界完全吻合：DNR 无法合成响应体，MV3 只读 webRequest 更不可能；**唯一"能返回任意响应体"的非 JS 路线是 chrome.debugger + CDP `Fetch.fulfillRequest`**（§2.4），而它带来 infobar、与 DevTools 互斥、per-tab attach | **不冲突，反而被强化** | 保持 R9；把 debugger 路线明确写成"非目标/仅观测（Q-D6）" |
| **R5 内置 UI 不得走特殊通道** | 扩展页与普通页在"能否注入转发器"上**并不对等**，而且是**硬性**的：`chrome-extension://` 不是合法 match pattern scheme，`kValidUserScriptSchemes` 不含 `SCHEME_EXTENSION`（**自家页也不行**），MDN 明文说不能注入 extension pages（§4.1） | **潜在冲突**（不是逻辑冲突，而是"同一通道在扩展页上本来就装不上"） | R5 已预置"唯一例外"（换装载方式）；**建议把这条从"例外"升级为"预期路径"**：内置页面直接 `<script>` 引入同一份转发器文件（接入路径不变、只是装载方式不同），并在文档里写明原因 |
| **R4.1 覆盖多来源（每个标签页、MAIN WORLD 注入脚本）** | "其它扩展自身的请求"这一类来源在 Chrome 上**结构性不可达**（§4.2–4.4、§4.6）；"别家 content script 在网页里发的请求"**可见但接不住**（DNR 无响应体、MAIN world 补丁管不到隔离世界） | **需要限定** | 把 R4.1 的"来源"收窄为"页面（含该页面 MAIN world 的一切脚本）"，并在盲区清单里写明"其它扩展自身的请求不在服务范围" |
| **Q-D1 只拦一条精准匹配 URL** | DNR/webRequest 的规则是扩展级、全局生效；JS 层 hook 可以精确到"URL + 方法 + 调用方" | 不冲突 | 主链路继续用 JS 层实现 Q-D1；别引入全局 DNR 规则作为主链路 |
| **Q-D2 拦截盲区必须列出** | 本次新增具体条目：隔离世界的请求、Worker 内请求、CSP 失败静默降级、别家扩展请求不可达、`isTrusted` 检测、`injectImmediately` 不保证早于页面加载 | 不冲突，是补充 | 把 §7 的 1–12 并入"拦截盲区清单" |
| **§6 已接受风险 4（拦截盲区）** | 与 §7 一致 | 不冲突 | — |
| **附录 A（`chrome.tabs` + 两条 DNR 触发原生下载）** | 与本问无关；但注意 DNR 是扩展级规则、且"declarativeNetRequest won't affect responses generated by the service worker or retrieved from CacheStorage"，`modifyHeaders.append` 只对白名单请求头有效 | 不冲突 | 留到引擎设计阶段 |

---

## 9 未验证 / 存疑

> 每条写清"试过什么通道、怎么失败"。

1. **未做任何"加载真实扩展"的 E2E**：真机实验只有（无扩展的）普通页面探针；§4 的扩展侧结论全部来自官方文档 + Chromium 源码 + 官方浏览器测试的注释/断言，**没有一条来自我们自己跑出来的扩展实验**。
2. **"自家扩展页能否 `chrome.scripting.executeScript`"**：无官方明文；代码路径指向"不行"（`kValidHostPermissionSchemes` 不含 `SCHEME_EXTENSION` ⇒ 没有 pattern 能 match），但 `IsRestrictedUrl()` 对自家 URL 是豁免的，二者如何交互我未能实机验证。**这条直接决定 R5 的例外怎么写**，建议优先实测。
3. **`initiator` 字段对"扩展发起的请求"的确切取值**：文档只说 "The origin where the request was initiated"（无扩展示例）；源码用 `request.initiator->GetTupleOrPrecursorTupleIfOpaque()` 判 scheme/host，可反推是 `chrome-extension://<id>` 形态——属**推断**（间接证据：官方测试注释"they won't have access to the request initiator"）。
4. **CDP `Fetch` 能否 pause WebSocket 握手**：`Network.ResourceType` 有 `"WebSocket"`，但 tot 规范 Fetch 域里 0 处 "websocket"；实现路径是 URLLoader 拦截，而 `Network.webSocketCreated` 由 Blink 发出（子调研引 `inspector_network_agent.cc`）⇒ "不能"是强指向的推断，**无官方明文**。
5. **别家扩展 SW 请求在 DNR 里到底走不走到 `ShouldEvaluateRulesetForRequest`**：子调研指出 `ProcessMap` 是否登记 SW 进程未确证（`ProcessManager` 另有一张表），但**不影响结论**（initiator host-permission 闸独立成立，且 DNR E2E 证明 SW initiator 带扩展 origin）。这条 E2E（`declarative_net_request_browsertest.cc`）我**未逐行复核**。
6. **ModHeader 的机制与在架状态**：GitHub 404、官网无 manifest、CWS 页 JS 渲染、第三方"下架"说法对照实验失败（对照组同样不含扩展名）⇒ 只写"主能力=改头"，机制列为未验证。
7. **Tamper Dev / Tamper Chrome 当前 CWS 状态**：tamper.dev 仍链 CWS 详情页，但 CWS 页面无法区分在架/下架。
8. **xhook "同步请求跳过异步 hook"**：只有源码（`xmlhttprequest.js:331-339`）与 README 声明支撑，子调研的实测被前一个 hook 抢先返回假响应，**未真正验证**（我复核了源码行本身）。
9. **nise / fetch-intercept 的运行时观测**：nise 在 Node 24 上实测（浏览器行为按同一代码路径推断）；fetch-intercept 未在浏览器跑（npm 的 `lib/browser.js` 是 webpack bundle，需 `module` shim）。
10. **msw WebSocket 的 `instanceof` 结论**：属源码结构推断（`WebSocketOverride extends EventTarget`），未实测。
11. **`chrome.scripting.executeScript({world:'MAIN'})` 是否免于页面 `script-src` 检查**：Chrome 官方文档查不到明文；只有 Tampermonkey/Violentmonkey 的一手文档把 CSP 当约束（因此它们才需要 fallback）。这直接影响"内置 UI 用哪种装载方式"。
12. **PAC/`chrome.proxy` 是否对扩展发起的请求生效**：查不到明确文档/测试；即便生效也无法伪造响应（PAC 只能返回 `PROXY host:port` / `DIRECT`）。
13. **Firefox 侧**：对"别家扩展请求是否可见"、`filterResponseData` 的 MV3 细节、Firefox DNR 的同类限制，本次**无 Firefox 可测**，均未验证。
14. **DNR `redirect` 到 `data:` URL 是否端到端生效**：子调研称规则解析层只拒 invalid 与 `javascript:`（引 `indexed_rule.cc`，我**未复核**）；我**不采信**这条，标为存疑。
15. **抓取失败/绕路记录**：`source.chromium.org` 为 JS 站（search 端点无结果）⇒ 改用 `chromium.googlesource.com/...?format=TEXT` + Sourcegraph streaming API；`stackoverflow.com` 403（Cloudflare）⇒ 改用 StackExchange API；`issues.chromium.org` 的评论走 XHR（只有描述被服务端预渲染，我成功读到了 324676520 的正文）；GitHub REST API 间歇 403 限流 ⇒ 改用网页内嵌 JSON；CWS 详情页、`chromedevtools.github.io` 的 JS 渲染页 ⇒ 改用 raw JSON。

---

## 10 证据清单

### 10.1 官方文档 / 规范

| # | 来源 | 用途 |
|---|---|---|
| D1 | <https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline> | MV2 终止时间线（Chrome 138 最后支持、2026-08-31 CWS 清空） |
| D2 | <https://developer.chrome.com/docs/extensions/reference/api/webRequest> | blocking 现状、可见 scheme、`initiator`、`requestBody`、WS 只拦握手、`redirectUrl` 允许 `data:`、隐藏清单 |
| D3 | <https://developer.chrome.com/docs/extensions/develop/migrate/blocking-web-requests> | MV3 用 DNR 替代 blocking（政策安装例外） |
| D4 | <https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest> | 动作枚举、限额、`initiatorDomains`/`regexFilter` 语义、无响应体能力 |
| D5 | <https://chromium.googlesource.com/chromium/src/+/main/extensions/common/api/declarative_net_request.webidl> | `RuleAction` 无 body 字段；`URLTransform.scheme` 含 `chrome-extension` |
| D6 | <https://developer.chrome.com/docs/extensions/reference/api/debugger> | `debugger` 权限、可用 CDP 域含 `Fetch`、`--silent-debugger-extension-api`、`DetachReason`、企业策略限制 |
| D7 | <https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/browser_protocol.json>（网页版 <https://chromedevtools.github.io/devtools-protocol/tot/Fetch/>） | `Fetch.enable/fulfillRequest/continueRequest/getResponseBody/continueResponse` 规范原文；`Network.ResourceType` |
| D8 | <https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns> | 合法 scheme 只有 http/https/*/file；`<all_urls>` 定义；`externally_connectable` |
| D9 | <https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts> | 隔离世界、`world`、`match_origin_as_fallback`、"MAIN world 用页面 CSP"、RunAt 表 |
| D10 | <https://developer.chrome.com/docs/extensions/reference/api/scripting> | `executeScript` 描述、注入目标（tab/frame） |
| D11 | <https://raw.githubusercontent.com/mdn/content/main/files/en-us/mozilla/add-ons/webextensions/content_scripts/index.md> | "cannot inject … or extension pages"；页面重定义内置属性对 content script 不可见 |
| D12 | <https://raw.githubusercontent.com/mdn/content/main/files/en-us/mozilla/add-ons/webextensions/api/webrequest/filterresponsedata/index.md> + <https://raw.githubusercontent.com/mdn/browser-compat-data/main/webextensions/api/webRequest.json> | `filterResponseData` 能力与 Firefox-only（chrome:false） |
| D13 | <https://raw.githubusercontent.com/mdn/content/main/files/en-us/web/api/event/istrusted/index.md> | `isTrusted` 语义 |
| D14 | <https://tc39.es/ecma262/multipage/fundamental-objects.html#sec-function.prototype.tostring> | `Function.prototype.toString` 三步算法 |
| D15 | <https://webidl.spec.whatwg.org/> | class string / `Symbol.toStringTag` / 操作与属性的描述符 / `[Global]` 例外 |
| D16 | <https://developer.chrome.com/docs/extensions/reference/api/proxy> | PAC 只能 `PROXY host:port`/`DIRECT` |
| D17 | <https://raw.githubusercontent.com/GoogleChrome/developer.chrome.com/main/site/en/docs/extensions/mv3/permission_warnings/index.md> | `"debugger"` 权限警告 "Access the page debugger backend" |
| D18 | <https://www.tampermonkey.net/documentation.php?ext=ejkj&q=sandbox> / `?q=unsafeWindow` / `?q=webRequest` | `@sandbox` 三 world、CSP fallback、`unsafeWindow`、`@webRequest` 在 MV3 5.2+ 不可用 |
| D19 | <https://violentmonkey.github.io/posts/inject-into-context/> + <https://violentmonkey.github.io/api/metadata-block/> | page vs content context、CSP 失败、`@inject-into auto` |
| D20 | <https://docs.requestly.com/account/how-is-browser-extension-different-from-a-desktop-app> | 官方承认浏览器版**网络层**不能提供本地文件响应/改响应内容（桌面 App 才行） |
| D21 | <https://developer.chrome.com/docs/extensions/mv3/service_workers/service-worker-lifecycle/> | SW 30 秒空闲终止（对照 attach 期间的 `kDoesNotTimeout`） |
| D22 | <https://github.com/w3c/webextensions/issues/1054> | 请求允许在**自家沙箱扩展页**执行脚本，并称 "This is currently not possible" |

（通道说明：Chrome 文档走 `.md.txt` 纯文本端点或 HTML 去标签；MDN 走 `raw.githubusercontent.com/mdn/*`；规范走 `tc39.es` / `webidl.spec.whatwg.org` 单页 HTML；Tampermonkey 用 `documentation.php?ext=ejkj&q=<条目>`。）

### 10.2 Chromium 源码（`chromium.googlesource.com/chromium/src/+/main/<file>?format=TEXT`，base64 解码后阅读）

| # | 文件 | 关键结论 |
|---|---|---|
| S1 | `extensions/browser/api/web_request/extension_web_request_event_router.cc` | `ListenerMatchesRequest()`："Filter requests from other extensions / apps…"；`REQUIRE_HOST_PERMISSION_FOR_URL_AND_INITIATOR`；`IsRequestFromExtension()` |
| S2 | `extensions/browser/api/web_request/web_request_permissions.cc` | `GetHostAccessForURL()` 同源短路；导航 vs 子资源分支；`HasWebRequestScheme()`；`HideRequest()` |
| S3 | `extensions/common/extension.cc` / `extension.h` | `kValidHostPermissionSchemes` **不含 `SCHEME_EXTENSION`** |
| S4 | `extensions/common/url_pattern.h` / `url_pattern.cc` | `SCHEME_ALL` 注释；`MatchesScheme`/`IsValidScheme` |
| S5 | `extensions/common/manifest_handlers/permissions_parser.cc` | 普通扩展 host permission 用 `kValidHostPermissionSchemes`；只有 `can_execute_script_everywhere` 才给 `SCHEME_ALL` |
| S6 | `extensions/common/user_script.cc` | `kValidUserScriptSchemes` **无 SCHEME_EXTENSION**；`ValidUserScriptSchemes()` |
| S7 | `extensions/common/utils/content_script_utils.cc` | `ParseMatchPatterns()` 用上面的掩码 `pattern.Parse()` ⇒ 扩展页 match 解析失败 |
| S8 | `extensions/common/permissions/permissions_data.cc` | `IsRestrictedUrl()`：别家扩展 URL ⇒ `kCannotAccessExtensionUrl`；activeTab 段把"其它扩展页面"列为受限来源 |
| S9 | `extensions/common/manifest_constants.h` | "Cannot access a chrome-extension:// URL of different extension" |
| S10 | `extensions/browser/api/declarative_net_request/ruleset_manager.cc` | `ShouldEvaluateRulesetForRequest()` 排除别家扩展发起的非导航请求；`request.url.SchemeIs(kExtensionScheme) → false` |
| S11 | `chrome/browser/extensions/api/declarative_net_request/ruleset_manager_unittest.cc` | `RulesetManagerTest.CrossExtensionRequestBlocking` 的四条断言注释 |
| S12 | `chrome/browser/extensions/api/web_request/web_request_apitest.cc` | "Any requests made by it should not be visible to other extensions…" + content script 的 as-if-the-webpage 说明 |
| S13 | `chrome/browser/extensions/api/debugger/debugger_api.cc` | `ExtensionMayAttachToURL()` 拒别家扩展 URL；按 tab 附加的 URL 检查（含 pending entry）；SW 保活 `IncrementServiceWorkerKeepaliveCount(..., kDoesNotTimeout, Activity::DEBUGGER)`；`kAlreadyAttachedError` |
| S14 | `chrome/browser/extensions/api/debugger/extension_dev_tools_infobar_delegate.{h,cc}` + `chrome/app/generated_resources.grd` | 全局提示条："An infobar used to globally warn users that an extension is debugging the browser (which has security consequences)."；文案 `"$1" started debugging this browser`；`kAutoCloseDelay = 5s` |
| S15 | `chrome/common/extensions/chrome_extensions_client.cc` | `IsScriptableURL()` 只挡 Web Store |
| S16 | `extensions/browser/api/web_request/web_request_api.cc` + `web_request_api_constants.cc` | `kBlockingPermissionRequired` 全文；`kInvalidRedirectUrl` 等 |
| S17 | `extensions/browser/script_executor.cc` | 脚本执行路径（仅 PDF 扩展帧特判；未见过滤扩展 URL 的明文） |
| S18 | `extensions/renderer/extension_injection_host.cc`（**子调研引用，我未复核**） | "Only allowlisted extensions may run scripts on another extension's page." |
| S19 | `extensions/business…`/`components/url_pattern_index/url_pattern_index.cc`（**子调研引用，我未复核**） | `DoesOriginMatchInitiatorDomainList()` → host 子域字符串匹配 |

### 10.3 开源项目源码（tarball / raw 抓取后本地阅读）

| # | 仓库 | 读过的文件 / 结论 |
|---|---|---|
| P1 | <https://github.com/google/tamperchrome> | `v2/manifest_base.json`（`debugger`+`activeTab`）、`v2/background/src/interception.ts`（`Fetch.enable` 双阶段）、`v2/background/src/request.ts`（`Fetch.fulfillRequest`）、`v2/background/src/debuggee.ts`（`{tabId}` + `attach('1.2')`）、`v1/extension/manifest.json`、README |
| P2 | <https://github.com/kylepaulsen/ResourceOverride> | `manifest.json`（MV2 + webRequestBlocking + `<all_urls>`）、`src/background/requestHandling.js`（Firefox `filterResponseData` / Chrome `redirectUrl:"data:…"`）、`src/background/background.js`（`onBeforeRequest(...,["blocking"])`）、README（MV3 半成品、停更） |
| P3 | <https://github.com/einaregilsson/Redirector> | `manifest.json`（MV2 + webRequest/webRequestBlocking/webNavigation）、`js/background.js`（`redirectUrl`） |
| P4 | <https://github.com/requestly/requestly> | `browser-extension/mv3/src/manifest.chrome.json`（MV3 + DNR + scripting + webRequest）、`.../service-worker/services/clientHandler.ts`（`executeScript({world:"MAIN", injectImmediately:true})`）、`.../client-scripts/ajaxRequestInterceptor.js`（`XMLHttpRequest.prototype.open/send/setRequestHeader` 覆盖、`fetch = async (...) => …`、`new Response(new Blob([customResponse]), …)`）、PR #1536（删 MV2 blocking 路径） |
| P5 | <https://github.com/wendux/ajax-hook> | `src/xhr-hook.js`（替换构造器、`prototype = originXhr.prototype`、实例 own property）、`src/xhr-proxy.js`（`setTimeout` vs 同步分支、`response = responseText`、**`event.isTrusted = true`**） |
| P6 | <https://github.com/jpillora/xhook> | `src/main.js`、`src/patch/xmlhttprequest.js`（facade = `EventEmitter()`；全仓 `prototype` 只命中 `Array.prototype.slice`）、`src/patch/fetch.ts`（`windowRef.fetch = Xhook`）、`src/misc/event-emitter.ts`、README（加载顺序、"async hooks skipped on sync"） |
| P7 | <https://github.com/werk85/fetch-intercept> | `src/attach.js`（`env.fetch = function(...)`）、`src/browser.js`、`src/node.js` |
| P8 | <https://github.com/mswjs/interceptors> | `src/interceptors/fetch/web.ts`、`src/interceptors/XMLHttpRequest/{web.ts,xml-http-request-proxy.ts,xml-http-request-controller.ts}`、`src/interceptors/WebSocket/{index.ts,web-socket-override.ts}`、`src/utils/{patches-registry.ts,create-proxy.ts,find-property-source.ts,has-configurable-global.ts,fetch-utils.ts}` |
| P9 | <https://github.com/sinonjs/nise> | `lib/fake-xhr/index.js`（`globalScope.XMLHttpRequest = FakeXMLHttpRequest`、`EventTargetHandler`、`defake`、同步/分块分支）、`lib/fake-server/index.js`（`autoRespond`/`respondImmediately`）、`lib/event/event.js`（**事件类无 `isTrusted`/`timeStamp`**） |
| P10 | <https://github.com/violentmonkey/violentmonkey>（`src/manifest.yml`） | MV2 + `webRequest`/`webRequestBlocking` + `injected.js` document_start all_frames |
| P11 | <https://github.com/ModHeader/ModHeader>（失败） | 404：未取得一手证据（§9.6） |

### 10.4 本调研真机实验（Chromium 148，`/tmp/v3exp/probe.mjs`）

| # | 观测 | 结果 |
|---|---|---|
| E1 | 描述符基线 | `window.fetch {w:true,e:true,c:true}`；`window.XMLHttpRequest {w:true,e:false,c:true}`；`XMLHttpRequest.prototype.open {w:true,e:true,c:true}`；`window.WebSocket {w:true,e:false,c:true}`；`Response.prototype.url` accessor |
| E2 | 实例形态 | `Object.keys(new XMLHttpRequest()).length === 0`；`[object XMLHttpRequest]`；`Symbol.toStringTag === "XMLHttpRequest"`；`[object Response]` |
| E3 | `toString` | 原生 `"function fetch() { [native code] }"`；`new Proxy(fetch,{})` → `"function () { [native code] }"`（**名字丢失**）；`.bind()` 同上；普通箭头函数 → 源码 |
| E4 | `defineProperty` 语义 | 对已存在属性不写 `writable` ⇒ 保持 `true`；显式 `enumerable:true` ⇒ 接口对象从 `false` 变 `true`（**可检测**） |
| E5 | 真实 XHR 事件序列 | `readystatechange(1)→loadstart(1)→readystatechange(2)→readystatechange(3)→progress(3)→readystatechange(4)→load(4)→loadend(4)`；全部 `isTrusted:true`、`target===currentTarget===xhr`、`[object Event]`/`[object ProgressEvent]`、`timeStamp` 相对量级 |
| E6 | 合成事件 | `dispatchEvent(new Event('x'))` ⇒ `isTrusted === false` |

### 10.5 Issue / 提案

| # | 来源 | 用途 |
|---|---|---|
| I1 | <https://github.com/w3c/webextensions/issues/868> | DNR redirect 可被 `fetch(...,{redirect:"error"})` 检测；"synthetic 200 response" 仍是**提案** |
| I2 | <https://github.com/w3c/webextensions/issues/610> | MV3 下"重定向到扩展页"的痛点（`regexSubstitution` 传原 URL、必须 `web_accessible_resources`） |
| I3 | <https://github.com/w3c/webextensions/issues/109> | "DNR cannot handle POST payloads" |
| I4 | <https://issues.chromium.org/issues/324676520> | POST 重定向到扩展资源 ⇒ `net::ERR_UNSAFE_REDIRECT`，且无法覆盖重定向状态码（正文逐字读到） |
| I5 | <https://github.com/ghostery/ghostery-extension/issues/2270>（由 I1 引用） | `ERR_UNSAFE_REDIRECT` 的实战踩坑（**未逐字复核正文**） |
| I6 | <https://github.com/w3c/webextensions/issues/1054> | 自家沙箱扩展页注入脚本"currently not possible" |
