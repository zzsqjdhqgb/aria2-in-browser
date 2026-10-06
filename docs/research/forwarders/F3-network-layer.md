# F3 — 网络层路线：DNR / webRequest / CDP 能替代 JS 层吗

> 本文只做技术边界测绘。不改代码，不改 `concept-design.md`，不涉及其他成员的文件。

---

## 0 元信息

| 项 | 值 |
|---|---|
| 文档编号 | F3（任务 t8 `[f3]`） |
| 主题 | 网络层拦截路线（declarativeNetRequest / chrome.debugger+CDP Fetch / MV2 blocking webRequest / Firefox filterResponseData）能否替代 JS API 层拦截 |
| 核对日期 | **2026-10-06（UTC）**（本机 `date -u` 输出 `Tue Oct 6 09:56:09 UTC 2026`） |
| 对标运行时 | **Chrome Stable 154.0.8037.97/.98**（2026-10-01 发布，Windows/Mac；Linux 154.0.8037.97）[E35]；Extended Stable 152.0.7977.152；Dev 157.0.8081.0（2026-10-02）[E35]；**Chrome DevTools Protocol 1.3**（`browser_protocol.json` 顶层 `"version": {"major":"1","minor":"3"}`）[E13]；**Firefox** 发行说明页当前列出的最新版本 157.0 [E35] |
| 方法 | 仅取官方文档与官方源码：`developer.chrome.com`、`chromedevtools.github.io` / ChromeDevTools 协议 JSON、`chromium.googlesource.com`（Chromium 源码，含 `generated_resources.grd`）、`developer.mozilla.org`、`extensionworkshop.com`、`blog.mozilla.org/addons`、WHATWG Fetch Standard |
| 证据编号 | 正文引用 `[E##]`，逐条对应 §8 证据清单（含 URL + 原文摘录） |
| 标记约定 | ✅ = 官方文档/源码直接陈述；🟡 = 官方材料可推出、但无一句直陈；❔ = **未验证**（查不到，或只有非官方来源） |
| 不在范围 | 具体规则表设计、代码实现、引擎详细设计、"JS 层怎么做"（属其他 F 文档） |

**关于"禁止凭记忆断言"的自查声明**：本文每一条 ✅ 结论后都跟 §8 的官方原文摘录；凡本轮未找到官方依据者，一律进 §7 标 ❔，**不写进 §1/§3/§6 的裁定依据**。

---

## 1 一句话结论

> **DNR 这条网络层路线永远无法单独承担 Mock 层（它没有任何字段能承载响应体）；CDP `Fetch` 这条网络层路线"能"，但代价（`debugger` 权限警告 + 不可关闭的横幅 + 目标级互斥 + 无双全浏览器挂载 + DevTools 一开就掉线）使它不适合做默认路径。因此网络层不是 JS 层的替代品，而是 JS 层的补丁；R9 的结论维持，R9 的论据措辞需要修正。**

三句话展开：

1. **DNR 做不到返回响应体** —— 官方把 DNR 的能力穷举为 block / redirect / upgradeScheme / allow(AllRequests) / modifyHeaders 五类（`RuleActionType` 枚举六项含 `allow`），`Redirect` 类型的字段只有 `extensionPath` / `regexSubstitution` / `transform` / `url`，`RuleAction` 只有 `redirect` / `requestHeaders` / `responseHeaders` / `type` 四个字段 —— **任何一条字段都无法承载"由扩展在运行期生成的响应体"** [E1][E2][E3][E4]。因此"用 DNR 重定向到扩展资源来伪造 RPC 响应"这条路是死的：扩展到扩展资源的重定向必须命中 `web_accessible_resources`（静态打包文件）[E8]，而 `fetch()` 跟随重定向到非 HTTP(S) scheme 时按 Fetch 标准直接返回 **network error** [E10]。
2. **CDP `Fetch` 做得到** —— 官方对 `Fetch` 域的定义就是"让客户端用代码替换浏览器的网络层"，`Fetch.enable` 会暂停请求直到客户端回 `fulfillRequest`，而 `fulfillRequest.body` 就是任意 base64 响应体 [E13]；`Fetch` 明确在 `chrome.debugger` 允许访问的 CDP 域白名单里 [E14]。**但**普通扩展**不能**挂到浏览器级 target（源码里 `targetId: "browser"` 走的是 `ExtensionIsTrusted()`，只有 Perfetto UI 那个受信扩展能过）[E17]，只能逐 tab / 逐 worker target 挂 [E16][E15]。
3. **因此分工是**：JS API 层负责"**返回任意响应体**"这一唯一不可替代的能力（Mock 层的地基）；网络层里 **DNR 只能做"补漏 + 硬阻断"**（把穿透变成显式失败，而不是 Mock 成功）；**CDP 只适合做可选的高级模式或调试工具**（正好对应 Q-D6「Mock 控制台」）。

**对 R9 的裁定意见：维持结论，修正论据。** 详见 §6.1。

---

## 2 机制

### 2.1 declarativeNetRequest（DNR）—— 声明式网络层

**它是什么**：扩展把规则写成 JSON，由浏览器在网络栈里代扩展执行；扩展代码在匹配时**不被调用** [E1][E1b][E27]。

**一条规则能做什么（官方穷举，共 5 类 6 个 action）** ✅ [E1][E2]：

| `RuleActionType` | 语义（官方原文） | 生效阶段 |
|---|---|---|
| `block` | "Block the network request." | 请求发出**前** [E6] |
| `redirect` | "Redirect the network request." | 请求发出前 [E6] |
| `allow` | "Allow the network request. The request won't be intercepted if there is an allow rule which matches it." | 请求发出前（优先级最高）[E6] |
| `allowAllRequests` | "Allow all requests within a frame hierarchy, including the frame request itself."（条件是只能写 `sub_frame`/`main_frame`） | 请求发出前 [E6] |
| `upgradeScheme` | "Upgrade the network request url's scheme to https if the request is http or ftp." | 请求发出前 [E6] |
| `modifyHeaders` | "Modify request/response headers from the network request." | 请求头阶段 / 收到响应头后 [E6] |

> ⚠️ **关于表头那个"5 类"**：`allow` 与 `allowAllRequests` 在能力分类上算同一类（"否定 block"），所以官方口径写"四类/五类"（`RuleActionType` 枚举里则是六个字面值）。本文引用时两种口径都保留原样。

> **这里就是本题最关键的一问的答案**：官方文档、官方参考页、Chromium 源码里的实现 README，三处把 DNR 的能力各穷举了一遍，**没有一项是"生成/替换响应体"** [E1][E2][E3][E27]。其中 `RuleActionType` 是**封闭枚举**，`RuleAction` 是**封闭字段集**，`Redirect` 也是**封闭字段集** —— 这不是"文档没写"，而是"类型系统里没有这个字段"。

**规则的三处来源与配额** ✅ [E11]：

| 类型 | 生命周期 | 上限 |
|---|---|---|
| static | 随扩展安装/升级打包加载 | 最多 100 个 ruleset，同时启用 ≤ 50；保底 30000 条；Chrome 有 **300,000 条全局共享池**（2024-05-30 版 content-filtering 页） |
| dynamic | 跨浏览器会话与扩展升级持久 | safe 规则（`block`/`allow`/`allowAllRequests`/`upgradeScheme`）**30000**；unsafe 规则（如 `redirect`）最多 **5000**（计入 30000 内） |
| session | 浏览器关闭 / 扩展更新即清空 | **5000** |

另有：正则规则每种类型合计 ≤ 1000 条；单条规则编译后 < 2KB，超了会被静默忽略（只有 unpacked 扩展才打印警告）[E11]。

**`redirect` 能重定向到哪（`Redirect` 类型的全部字段）** ✅ [E4]：

- `url` —— 直给 URL，"Redirects to JavaScript urls are not allowed."
- `extensionPath` —— "Path relative to the extension directory. Should start with '/'."，解析为 `chrome-extension://EXTENSION_ID/<path>`；**该资源必须在 `web_accessible_resources` 里**，否则规则报错 [E8]
- `transform`（`URLTransform`：scheme/host/port/path/query/query_transform/fragment）
- `regexSubstitution` —— 配合 `regexFilter` 的捕获组重写

**`modifyHeaders` 的三操作与限制** ✅ [E5]：

- 操作：`append` / `set` / `remove`。
- 请求头 `append` 有一张**大小写敏感的白名单**：`accept, accept-encoding, accept-language, access-control-request-headers, cache-control, connection, content-language, cookie, forwarded, if-match, if-none-match, keep-alive, range, te, trailer, transfer-encoding, upgrade, user-agent, via, want-digest, x-forwarded-for`。
- 同头多规则冲突的合并顺序有明确规定（append 之后只能 append；set 之后只能 append；remove 之后不能再改）[E6]。
- **官方没有给出"响应头不能改哪些"的白名单**（只给了请求头 append 白名单）→ 见 §7。

**优先级（跨扩展）** ✅ [E6]：同一扩展内 `allow/allowAllRequests > block > upgradeScheme > redirect`；跨扩展 `block > redirect/upgradeScheme > allow/allowAllRequests`，同级取**最近安装**的扩展。官方明确警告：**同 action 同 priority 的规则执行顺序不做保证，跨浏览器不标准化**。

**新增能力（Chrome 128+）**：`RuleCondition.responseHeaders` / `excludedResponseHeaders` 可以**按响应头匹配**规则，但官方特别说明：走到这个阶段"the request has already been sent to the server"，**此时 block/redirect 规则虽然仍会执行，但"cannot actually block or redirect the request"** —— block 会变成"页面收到一个被阻断的响应、Chrome 提前终止请求" [E6]。这条对理解 DNR 的能力天花板很重要：**越靠后匹配，越只能"打断"，越不能"伪造"**。

### 2.2 chrome.debugger + CDP `Fetch` 域 —— 命令式网络层

**链路**：扩展拿 `debugger` 权限 → `chrome.debugger.attach(target, "0.1")` → `chrome.debugger.sendCommand(target, "Fetch.enable", {patterns, handleAuthRequests})` → 收到 `Fetch.requestPaused` → 回 `Fetch.fulfillRequest` / `failRequest` / `continueRequest` / `continueWithAuth` [E13][E16]。

**`Fetch` 域定义** ✅ [E13]：

> "A domain for letting clients substitute browser's network layer with client code."

**`Fetch.enable`** ✅ [E13]：

> "Enables issuing of requestPaused events. A request will be paused until client calls one of failRequest, fulfillRequest or continueRequest/continueWithAuth."

**`Fetch.fulfillRequest` 的全部参数** ✅ [E13]：

| 参数 | 类型 | 必填 | 官方说明 |
|---|---|---|---|
| `requestId` | `RequestId` | ✔ | 来自 `requestPaused` |
| `responseCode` | integer | ✔ | HTTP 响应码 |
| `responseHeaders` | `HeaderEntry[]` | | 响应头 |
| `binaryResponseHeaders` | string | | `\0` 分隔的 name:value 序列，base64 传输（给非 UTF-8 值用） |
| `body` | string | | **"A response body. If absent, original response body will be used if the request is intercepted at the response stage and empty body will be used if the request is intercepted at the request stage. (Encoded as a base64 string when passed over JSON)"** |
| `responsePhrase` | string | | 状态短语 |

→ **`body` 就是"扩展自己生成的任意响应体"**，且**请求阶段拦截**（`requestStage: "Request"`，默认值）时原请求还**没有被发到服务器** [E13]。**这是 Chrome 上唯一一条真正能承担 Mock 层的网络层路径**（Firefox 的 `filterResponseData` 是否等价见 §7 V12）。

**拦截范围（`RequestPattern`）** ✅ [E13]：

- `urlPattern`：通配符 `*`/`?`，省略等价于 `"*"`（即全部）。
- `resourceType`：取值来自 `Network.ResourceType` = `Document, Stylesheet, Image, Media, Font, Script, TextTrack, XHR, Fetch, Prefetch, EventSource, WebSocket, Manifest, SignedExchange, Ping, CSPViolationReport, Preflight, FedCM, Other` —— **包含 `WebSocket`、`Preflight`、`Document`**。
- `requestStage`：`Request`（发出前）| `Response`（收到响应后、响应体之前）。
- `Fetch.requestPaused` 事件在**重定向的每一跳**都会再触发一次（`redirectedRequestId` 字段标识来源）。

**`chrome.debugger` 允许的 CDP 域白名单（含 `Fetch`）** ✅ [E14]：

> "For security reasons, the browser.debugger API does not provide access to all Chrome DevTools Protocol Domains. The available domains are: Accessibility, Audits, CacheStorage, Console, CSS, Database, Debugger, DOM, DOMDebugger, DOMSnapshot, Emulation, **Fetch**, IO, Input, Inspector, Log, Network, Overlay, Page, Performance, Runtime, Storage, Target, Tracing, WebAudio, and WebAuthn."

**能挂到哪些 target** ✅ [E16]：`Debuggee` = `tabId` | `extensionId` | `targetId` 三选一；`DebuggerSession` 额外可带 `sessionId`（Chrome 125+ 的 **flat session**，用来在同一个根会话里操作子 target）[E15]。Chrome 官方文档把 target 说成"could include a tab, an iframe or a worker"，并给出用 `Target.setAutoAttach({flatten:true, filter:[{type:"iframe"}]})` 挂 OOPIF/关联 worker 的做法；同时警告**自动挂载是单层的、不递归**（A→B→C 要各挂一次）[E15]。

**普通扩展挂不上浏览器级 target** ✅（源码级）：
`chrome/browser/extensions/api/debugger/debugger_api.cc` 里 `constexpr char kBrowserTargetId[] = "browser";`，但真正走 `CreateForBrowser(...)` 的分支条件是 `*debuggee_.target_id == kBrowserTargetId && ExtensionIsTrusted(*extension())`，而 `ExtensionIsTrusted()` 的实现是 `extension.id() != extension_misc::kPerfettoUIExtensionId → return false` [E17]。

**额外发现（对 Q-D5 有直接价值）** ✅：`ExtensionDevToolsClientHost::Attach()` 在挂上之后会调 `IncrementServiceWorkerKeepaliveCount(..., ServiceWorkerExternalRequestTimeoutType::kDoesNotTimeout, Activity::DEBUGGER, ...)` —— **只要调试器挂着，扩展的 SW 就不会超时被杀** [E22]。这跟 §3.6 的 SW 生命周期形成互补。

### 2.3 MV2 blocking webRequest（Chrome 已淘汰 / Firefox 现状）

**Chrome 侧** ✅：

- MV3 下 `webRequestBlocking` 只剩一条缝：**"As of Manifest V3, this is only available to policy installed extensions."** [E24]
- 官方还给出了替代口径：**"We are confident that most request blocking use cases can be solved with the new declarativeNetRequest API … However, for complex enterprise (or education) use cases, dynamic request blocking is still supported."** [E34]
- MV2 的死刑时间线 ✅ [E25]：
  - 2024-06-03：Beta/Dev/Canary 起逐步禁用 MV2；
  - 2025-03-31：所有渠道默认禁用，但用户还能手动打开；
  - **2025-07-24：Chrome 138 起全渠道禁用，用户无法再打开**；
  - 企业策略 `ExtensionManifestV2Availability` 随 **Chrome 139** 移除；
  - **2026-08-31：Chrome Web Store 中剩余的 MV2 扩展全部下架**（现有安装且 Chrome ≤ 138 者仍可运行，但不能再更新/重装）。
  - → **截至核对日期，"Chrome 上还有 MV2 blocking webRequest"这条路已不存在**（除非企业策略环境，而策略路径也在 Chrome 139 结束）。

**Firefox 侧** ✅：

- Mozilla 官方表态（2021-05-27，Rob Wu）：**"we have decided to implement DNR *and* continue maintaining support for blocking webRequest"**，以及 **"We will support blocking webRequest until there's a better solution which covers all use cases we consider important, since DNR as currently implemented by Chrome does not yet meet the needs of extension developers."** [E31]
- **现行 MDN 权限清单里 `webRequestBlocking` 仍作为普通 API 权限列出，没有任何 Manifest V3 限制标注** [E31]。
  - ⚠️ **反面提醒（本轮已自查并纠正）**：Chrome 侧的 `permissions-list` **同样**仍列着 `"webRequestBlocking" — "Allows the use of the chrome.webRequest API for blocking."`，**也不带 MV3 限制标注** [E24b]。→ **"权限清单里还有它"不能作为"还能用"的证据**；Chrome 的真实约束写在 webRequest API 参考页上（"As of Manifest V3, this is only available to policy installed extensions." [E24]）。因此 Firefox 侧的判断只能依赖 Mozilla 的明确表态 [E31]，不能依赖清单存在性 —— 这一条已列为 §7 V11。
- Firefox 的 blocking 能力面 ✅（MDN）：可 `cancel` 于 `onBeforeRequest`/`onBeforeSendHeaders`/`onAuthRequired`；可 `redirect` 于 `onBeforeRequest`/`onHeadersReceived`；可改请求头于 `onBeforeSendHeaders`；可改响应头于 `onHeadersReceived`；可供凭据于 `onAuthRequired`；**返回对象的 `redirectUrl`——"Redirections to non-HTTP schemes such as `data:` are allowed."** 且重定向沿用原方法（`onHeadersReceived` 阶段发起时改用 GET）[E28][E30]。

**Firefox `filterResponseData`（本题最强的"网络层伪造"对照物）** ✅：

- 入口：`webRequest.filterResponseData(requestId)` → `webRequest.StreamFilter` [E29]。
- 官方定位：**"The stream filter gives the web extension full control over the stream, with the ability to monitor and modify the response. It's the extension's responsibility to write and close or disconnect the stream, as the default behavior is to keep the request open without a response."** [E29]
- 更狠的一句：**"The filter is passed HTTP response data as it's received from the network."** + **"The filter has full control over the response body, and the default behavior without any listeners or write calls is to have a stream without content that never closes."** [E30]
- 权限：`webRequest` + `webRequestBlocking` + host 权限；**Firefox 110 起 MV3 扩展还要额外申请 `webRequestFilterResponse`**；Firefox 95 起拦 Service Worker 脚本还要 `webRequestFilterResponse.serviceWorkerScript` [E29]。
- ⚠️ 但要注意它的**语义前提仍然是"有一个来自网络的响应"**：官方描述是"response data as it's received from the network"，而"write 了才给渲染引擎"这句话管的是**响应体**，不是**响应头/状态码**（过滤器不提供改 responseCode 的入口）[E30]。→ **它能不能"完全凭空合成一个从未存在的响应（含状态码）"官方文档没有正面回答**，进 §7 标 ❔。

### 2.4 三条路线的层次对照

```
                        请求是否真正出网？        能否返回扩展生成的响应体？
                        ─────────────────        ─────────────────────────
JS API 层（R9 现裁定）   否（就地短路）✔          能（自己构造 Response）✔
DNR（声明式网络层）       是（block 会打断）        不能（无任何承载字段）✘
CDP Fetch（命令式网络层） 否（requestPaused 挂起）✔ 能（fulfillRequest.body）✔
MV2 blocking webRequest  是（钩在网络栈上）        不能（Chrome 从未提供）✘
  └ Chrome               —（已死，见 E25）         —
  └ Firefox              是（redirectUrl 可改道）   只有 filterResponseData：能改已到达的响应体，
                                                   能否凭空合成整条响应 ❔（§7 V12）
```

引用锚点：JS 层与 DNR 的差别见 [E6][E27]；CDP 的"暂停在发网之前"见 [E13]；Chrome MV2 的死亡见 [E25]。

---

## 3 硬约束

### 3.1 【致命约束】DNR 没有"响应体"这个概念

- `RuleActionType` 是封闭枚举（6 项）[E2]；`RuleAction` 只有 4 个字段 [E3]；`Redirect` 只有 4 个字段 [E4]；官方三处能力穷举都不含响应体 [E1][E2][E27]。
- **推论（本文最重要的一条）**：DNR 永远无法**单独**承担 Mock 层。这不是"实现难度"问题，是 API 表面缺失。
- ❔ 官方**没有**一句"declarativeNetRequest 不能生成响应体"的显式表述（见 §7）—— 但不影响结论，因为封闭枚举/封闭字段集本身就是完备证据。

### 3.2 【致命约束】重定向到扩展资源对 `fetch()` 是 network error

- DNR 重定向到扩展资源**必须**该资源在 `web_accessible_resources` 中，否则报错（连同扩展自己拥有的资源也一样）[E8]。
- 但即使声明了，**页面里的 `fetch()` 也拿不到它**：WHATWG Fetch Standard §4.5 `HTTP-redirect fetch` 明确写：

  > "If locationURL's scheme is not an HTTP(S) scheme, then return a network error." [E10]

  `chrome-extension://` 不是 HTTP(S) scheme ⇒ 跟随重定向时直接 `network error`。同一节还给了重定向上限 **20 次**。
- 补充（源码级）✅：DNR 的**规则解析层只禁了 `javascript:` scheme**（`return ParseResult::ERROR_JAVASCRIPT_REDIRECT`），**并没有拦 `data:`** [E26]。所以"规则能不能写成 `data:` URL"与"页面 `fetch()` 能不能消费它"是**两个层面**的问题：前者在解析层通过，后者被 Fetch 标准的 scheme 限制卡死在 §3.2 第一段那条规则上。（`data:` 重定向在**导航**场景能否成立：❔ §7 V2）
- 所以"用 DNR 把 RPC 请求重定向到一个扩展资源里打包好的假 JSON"这条**在页面的 fetch/XHR 上根本不成立**；它只在 `main_frame` 导航这类**不走 fetch 重定向算法**的场景成立（官方示例正是 `resourceTypes: ["main_frame"]`）[E4][E8]。
- `web_accessible_resources` 本身是"会带上合适的 CORS 头"的 [E9]，但这一条救不了 scheme 限制。

### 3.3 DNR 的适用面：只作用于"到达网络栈的请求"

✅ 官方原文 [E7]：

> "A declarativeNetRequest only applies to requests that reach the network stack. This includes responses from the HTTP cache, but may not include responses that go through a service worker's `onfetch` handler. declarativeNetRequest won't affect responses generated by the service worker or retrieved from CacheStorage, but it will affect calls to `fetch()` made in a service worker."

含义：**页面（或任何 SW）自己 `fetch` 出来的请求，DNR 管得到；由 ServiceWorker 的 `onfetch` 自行合成、或从 CacheStorage 取出的响应，DNR 管不到**。这正好是"JS 层能覆盖、网络层覆盖不到"的一块，也是 §5 盲区表的来源之一。

### 3.4 DNR 的配额、权限与优先级

见 §2.1 表。工程含义只有一句：**DNR 规则是稀缺且全局共享的资源**（静态全局池 300,000 条，被所有扩展瓜分，Chrome 128 起用户禁用的扩展不再占额）[E11]。对"只拦截一条精准 URL"（Q-D1）而言配额完全不是问题；对"按任务动态加规则"（附录 A 的做法）要注意 dynamic unsafe 规则只有 5000 条 [E11]。

权限侧 ✅ [E12][E12b]：

- `declarativeNetRequest` 与 `declarativeNetRequestWithHostAccess` **"provide the same capabilities, and both require host permissions; however, the latter prevents host permission warnings"** —— 即**两者能力相同、都要求 host 权限**，差别只在于**后者不触发 host 权限警告**；
- 而权限清单里只有前者带一条能力警告：**"Block content on any page."**（对"只拦截一条 URL"的扩展来说，这是一条明显过重的警告）；
- `declarativeNetRequestFeedback` 只对 unpacked 扩展生效，**商店安装的扩展上它会被忽略**（即线上拿不到 `getMatchedRules` / `onRuleMatchedDebug`）→ 对 Q-D6「Mock 控制台」的可观测性是一条硬约束；
- `redirect` / `modifyHeaders` 这类动作用的扩展需要 host 权限（迁移文档原话："Notice that redirecting also requires the `declarativeNetRequestWithHostAccess` permission in addition to the host permission."）[E12]。

### 3.5 CDP Fetch 的代价（五条，全部有据）

1. **权限与安装期警告** ✅：`debugger` 权限在官方权限清单里显示**两条**警告 —— "Access the page debugger backend." 与 **"Read and change all your data on all websites."** [E20]。Chromium 源码里的注释解释了这个"全站"来源：*"The `debugger` permission implies all URLs access (and indicates such to the user), so we don't check explicit page access."* [E20]。官方同时确认 `chrome.debugger` **不需要 host permissions** [E20]。
2. **不可关闭的横幅** ✅：Chromium 资源串 `IDS_DEV_TOOLS_INFOBAR_LABEL` = `"<ph name="CLIENT_NAME">$1<ex>Extension Foo</ex></ph>" started debugging this browser`，其描述明确写 **"The label does not disappear until the user dismisses it, even if the debugger is detached, and so should not imply that the debugger must still be debugging the browser, only that it was"** [E21]。源码里 `ExtensionDevToolsClientHost::Attach()` 只有在 `--silent-debugger-extension-api` 开关存在、或扩展是**策略安装**时才抑制这条警告 [E21]。
3. **互斥：一个 target 同时只有一个调试器客户端** ✅：源码常量 `kAlreadyAttachedError` = **"Another debugger is already attached to the \* with id: \*."** [E18]。
4. **DevTools 一开，扩展就掉线** ✅：`chrome.debugger.onDetach` 官方说明 —— **"Fired when browser terminates debugging session for the tab. This happens when either the tab is being closed or Chrome DevTools is being invoked for the attached tab."** [E19]。
5. **挂载粒度：没有"全浏览器"这一档** ✅：普通扩展不能挂浏览器 target（只有 Perfetto UI 受信扩展能）[E17]，只能逐 `tabId` / `targetId` 挂，OOPIF 与 worker 还要靠 `Target.setAutoAttach` 单层递归 [E15][E16]。→ 想覆盖"每一个浏览器标签页"（R4.1 的原话）意味着**逐 tab 挂载**；而横幅是挂在被挂载 target 所属的 `WebContents` 上的（源码里 `CreateWarningInfobar()` / `CreateWarningMessage()` 都取 `agent_host_->GetWebContents()`）[E21]，所以**用户打扰随被挂载的 tab 数线性叠加** 🟡。
6. （附带）**企业策略会整块封死** ✅：`ExtensionSettings` 配了 `runtime_blocked_hosts` → `attach()` 报 "Host access is restricted by policy."；`DisableScreenshots`/DLP 生效 → `attach()` 报 "Screenshot capture is restricted by policy." [E14]。

### 3.6 Service Worker 生命周期（两条相反的约束）

- **没挂调试器时** ✅ [E23]：Chrome 在 (a) **30 秒无活动**、(b) 单次请求/API 调用**超过 5 分钟**、(c) `fetch()` 响应**超过 30 秒**时终止 SW。（官方另注：活跃的 WebSocket 连接现在会延长 SW 寿命。）
- **挂着调试器时** ✅ [E22]：SW 被 `kDoesNotTimeout` 无限期保活。
- → 网络层（CDP）路线顺带解决了 Q-D5 的 SW 生命周期问题，**但代价是 §3.5 的横幅**。

### 3.7 WebSocket / WebTransport 的边界

- DNR 的 `ResourceType` 枚举包含 `websocket` 与 `webtransport` [E33]，说明规则**能匹配**这两类；但**官方没有说明 DNR 对 WebSocket 的 redirect 是否生效** → 进 §7 ❔。（对照：现行 webRequest 文档里明确 **"Redirects are not supported for WebSocket requests."**，且 "the API does not intercept: Individual messages sent over an established WebSocket connection. WebSocket closing connection." [E32]）
- CDP 侧：`Network.ResourceType` 含 `WebSocket`，而 `Fetch` 域里**没有任何帧级 API**，所以即便能拦到 WebSocket，也只能停在握手这一层（**推论**，官方未直述 `Fetch` 对 WebSocket 握手的行为）→ 与 E32 的 webRequest 结论同构，两者都**只覆盖握手**。
- 对 Q-D3（WebSocket 通道）的含义：**无论网络层还是 JS 层，WebSocket 都不是"用同一个拦截机制顺手解决"的东西**。

### 3.8 缓存

- DNR **作用于**来自 HTTP 缓存的响应 [E7]。
- 对照 MV2 webRequest 的官方说明：**"Requests that are answered from the in-memory cache are invisible to the web request API."**，改行为后需要 `handlerBehaviorChanged()` 清缓存 [E24]。→ DNR 与旧 webRequest 在这点上**行为不同**。

### 3.9 Chrome vs Firefox 的平台差异（一句话级）

| 手段 | Chrome（MV3） | Firefox（MV3） |
|---|---|---|
| DNR | 有，能力集见 §2.1 | 有（官方称为了 Chrome 兼容而实现）[E31] |
| blocking webRequest | **已死**（MV3 仅策略安装；MV2 于 Chrome 138 全渠道禁用）[E24][E25] | **仍支持**（官方承诺 + MDN 无 MV3 限制标注）[E31] |
| 改响应体 | 无 | `filterResponseData` + `webRequestFilterResponse`（110+）[E29] |
| CDP / debugger | `chrome.debugger`（受限域白名单含 `Fetch`）[E14] | ❔ 未找到等价的 "attach + 原始 CDP" 官方 API（见 §7） |

---

## 4 能力映射

> ⚠️ **读表前提**：下表中 **JS 层一列只是"R9 当前裁定"的占位，本文件不为其做证据核实**（属其他 F 文档的范围）。本文件的裁决对象只有 DNR / CDP 两列。

### 4.1 对 R4.1「转发器」：网络层能补什么、补不了什么

| R4.1 诉求 | JS 层（占位，不在本文核实范围） | DNR | CDP Fetch |
|---|---|---|---|
| 拦截 `fetch` / `XMLHttpRequest` | 待 JS 层文档裁决 | 🟡 能匹配 `xmlhttprequest` 资源类型，但**只能 block/redirect，不能给响应体** [E2][E6] | ✅ 能匹配 `XHR`/`Fetch` 并 `fulfillRequest` [E13] |
| 拦截 `WebSocket` | 待 JS 层文档裁决 | 🟡 枚举里有 `websocket`，但 redirect 行为未文档化 ❔ [E33] | 🟡 只能拦握手，帧级不在 `Fetch` 域 [E32] §7 V7 |
| 覆盖"每一个标签页" | 待 JS 层文档裁决 | ✅（扩展级规则，天然全局）[E6] | ❌ 逐 target 挂；横幅 + 互斥 [E17][E15][E18] |
| 未命中就原样放行 | 待 JS 层文档裁决 | ✅（无匹配规则即不动作） | ✅（`continueRequest`）[E13] |
| 命中后"真实服务无法再访问"（§6.2/Q-A3） | ⚠️ **只对走 JS API 的请求成立**（本文 §6.2） | ✅ **能真正做到硬阻断**（这才是 DNR 的真正价值） | ✅ 请求被暂停、不出网 [E13] |
| 命中后返回 aria2 语义的响应 | 待 JS 层文档裁决 | ❌（无响应体）[E2][E3][E4] | ✅（`fulfillRequest.body`）[E13] |

### 4.2 对 R11「原子能力」：网络层能兑现哪些

| 原子能力（用户示例） | DNR | CDP Fetch | 备注 |
|---|---|---|---|
| `withHeader` | ✅ 请求头 `set`/`append`（append 有白名单）[E5]；⚠️ 但**改请求头会参与 CORS 检查**（现行 webRequest 文档口径："request header modifications affect Cross-Origin Resource Sharing (CORS) checks … it will result in sending a CORS preflight"）[E37] | ✅ `continueRequest.headers` 覆盖请求头（**"the overrides do not extend to subsequent redirect hops"**）[E13] | 两条路都能做到；DNR 是声明式、CDP 是命令式 |
| `Content-Disposition` 强制下载（附录 A） | 🟡 `modifyHeaders.responseHeaders` 能改响应头 [E5]，但**"改 Content-Disposition 就能触发下载"官方没有直述** ❔ | 🟡 `fulfillRequest` 里可以带任意响应头 [E13] | 附录 A 那条机制需在引擎设计阶段单独验证 |
| `multithread` | ❌ 无关 | ❌ 无关 | 网络层完全够不着分片下载；属引擎层 |
| `memUnlimited` | ❌ 无关 | ❌ 无关 | 同上 |
| 「下载引擎触发」 | 🟡 DNR 只负责给一次真实请求改头/改响应头，真正的下载流由浏览器下载栈接管 | ❌ 用 CDP 伪造响应体会**绕开**下载栈的行为，方向相反 | 与附录 A 的 `chrome.tabs` + DNR 组合是同一条线 |

> 结论：**网络层是"请求定制类能力"的天然落点，但不是"多连接 / 内存"类能力的落点**。这与 R11 的布尔能力模型不冲突 —— 网络层手段只贡献 `withHeader` 这一族。

### 4.3 分工矩阵（本文件的结论性产出）

| 职责 | 归属 | 依据 |
|---|---|---|
| 生成并返回任意 RPC 响应体（Mock 层地基） | **只能 JS API 层**（或可选 CDP 模式） | DNR 无承载字段 [E2][E3][E4] |
| 就地短路、不触发 CORS/混合内容/证书 | JS API 层；CDP 次之 | DNR 走真实网络栈 [E27] |
| 让"命中地址的真实服务不可访问"（Q-A3/§6.2 的兑现） | **只有网络层（DNR block）能做到全覆盖** | JS 层只管 JS API 调用 |
| 拦截"不走 JS API 的网络途径"（地址栏导航、`<img src>`、`<script src>` 等） | DNR（但只能 block/redirect，返回不了 Mock 响应） | [E6] |
| 拦截 Worker / ServiceWorker 内部请求 | JS 层（注入得进去就拦）；DNR 能匹配但只能 block；CDP 需 `setAutoAttach` 单层挂 | [E7][E15] |
| 覆盖"每一个标签页" | DNR（天然扩展级）；CDP ❌ | [E17] |
| 调试与可观测（Q-D6） | **CDP 是天然工具** | [E13][E14] |

**一句话的分工表述**：
> **JS 层负责"假装成 aria2"，网络层负责"别让别人假装成 aria2"。** 前者需要响应体，后者不需要。

---

## 5 失败模式与盲区

> 每条给出：现象 → 机制 → 依据（或 ❔）。

| # | 现象 | 机制 | 依据 |
|---|---|---|---|
| F1 | 用 DNR 重定向伪造 RPC 响应，页面 `fetch` 直接 `TypeError: Failed to fetch` | Fetch 标准：重定向到非 HTTP(S) scheme → network error | [E10] |
| F2 | 同上，即使换成重定向到打包好的扩展页面，也只能导航不能 `fetch` | 同上 + `web_accessible_resources` 是**静态打包资源**，无法承载运行期数据 | [E8][E9][E10] |
| F3 | DNR `block` 命中后页面看到的是"网络错误"，不是 aria2 的 JSON-RPC 错误对象 | `block` 的官方描述是页面收到"blocked response"、Chrome 提前终止请求 | [E6] |
| F4 | 页面用 ServiceWorker `onfetch` 自行合成响应时，DNR 规则完全看不到 | 官方：DNR 不影响 SW 生成或 CacheStorage 取出的响应 | [E7] |
| F5 | 扩展自己的 `fetch()` 发到被拦截地址，DNR 规则是否生效不确定 | 官方未说明 DNR 对 `chrome-extension://` 发起方请求的适用性 | ❔ §7 |
| F6 | 用 CDP 方案时，用户打开 DevTools 排查问题 → 扩展的拦截整个断掉 | `onDetach`：DevTools 被调起即终止扩展的调试会话 | [E19] |
| F7 | 用户开了另一个用 `debugger` 的扩展 → 抢不到，attach 失败 | "Another debugger is already attached to the * with id: *." | [E18] |
| F8 | 每个被拦截的标签页上方都挂着一条**不可自动消失**的横幅 | `IDS_DEV_TOOLS_INFOBAR_LABEL`；描述里明说 detached 也不消失 | [E21] |
| F9 | 企业环境整块不可用 | `runtime_blocked_hosts` / DLP / `DisableScreenshots` 都会让 `attach()` 直接报错 | [E14] |
| F10 | 用 CDP 覆盖新标签页有竞态：tab 创建到 attach 完成之间的请求一定会漏 | 只能先 `chrome.tabs.onCreated` 再 attach；官方无"自动附加到所有新 tab"的能力（`setAutoAttach` 是**关联 target** 而非全局） | [E15]（推论，官方未直述 ❔） |
| F11 | 想靠 CDP 一次覆盖整浏览器 —— 做不到 | 普通扩展不能挂浏览器 target（只有 Perfetto 受信扩展） | [E17] |
| F12 | 长耗时的 RPC 调用把扩展 SW 拖死 | SW 30s 空闲 / 单请求 5min / fetch 响应 30s 上限 | [E23] |
| F13 | 网络层规则**跨扩展**互相打架，且顺序不保证 | 官方警告"同 action 同 priority 顺序不做保证、跨浏览器不标准化"；跨扩展同 action 取"最近安装" | [E6] |
| F14 | 部署到 Firefox 时同一套代码不成立 | Firefox 无 `chrome.debugger` 等价物（❔）；反之 Chrome 无 `filterResponseData` | [E29][E31] + §7 |
| F15 | 重定向丢 POST body / 变成 GET | Fetch 标准：301/302 + POST、303 + 非 GET/HEAD → 方法改 GET、body 置 null；**DNR 没有字段能指定重定向状态码**（❔ 未找到官方说明） | [E10] + §7 |
| F16 | `blob:` / `data:` 等非 HTTP(S) 请求 | CDP `Network.ResourceType` 里有 `Other`，但官方未说明 `Fetch` 是否覆盖 `blob:`/`data:` 发起的请求 | ❔ §7 |
| F17 | 用 `debugger` 权限上架商店的审核风险 | 官方权限清单只给了两条警告文案；**Web Store 对 `debugger` 权限的专项政策未在本轮找到官方文本** | ❔ §7 |

---

## 6 与现有裁定的冲突

### 6.1 对 R9 的裁定意见：**维持结论，修正论据**（详见 §1 与下表）

R9 原文（`concept-design.md` 第 109–112 行）：

> **R9（原 D2）拦截层次**
> 拦截发生在 **JS API 层**——在请求**发出之前**就地短路，**不是**网络层的重定向 / 代理。
> - 命中规则后请求**根本不会发到网络上** ⇒ CORS、混合内容、证书、真实服务是否存在**全部不适用**。
> - 与"用 DNR 重定向"不是同一条路：DNR 走网络层，拿不到"返回任意响应体"的能力。

| R9 的组成部分 | 本轮核实结论 | 裁定 |
|---|---|---|
| （a）"拦截发生在 JS API 层" | 这与"唯一可行的默认路径"一致：网络层里 DNR 拿不到响应体；CDP 能拿但代价不可接受（§3.5） | **维持** |
| （b）"命中后请求根本不会发到网络上 ⇒ CORS/混合内容/证书全部不适用" | **只对走 JS API 的请求成立**。对不走 JS API 的途径（地址栏导航、`<img>`/`<script>` 等），JS 层无从下手，请求**会**真的出网；此时"真实服务不可访问"的承诺（§6.2 的第 2 条 + Q-A3）会落空 | **修正**：把"全部不适用"限定为"经 JS API 发出的命中请求" |
| （c）"与用 DNR 重定向不是同一条路：DNR 走网络层，拿不到返回任意响应体的能力" | 前半句 ✅，后半句对 **DNR 本身** ✅ —— 但**不能推广成"网络层拿不到响应体"**：官方把 CDP `Fetch` 域定义为"substitute browser's network layer with client code"，其 `fulfillRequest.body` 就是任意响应体 [E13][E14] | **修正**：把论据从"网络层"收紧为"**声明式**网络层（DNR）" |

**修正后的 R9 建议表述（供 captain/用户采纳，本文不擅自改 `concept-design.md`）**：

> **R9（修订版）拦截层次**
> 默认拦截发生在 **JS API 层**——在请求**发出之前**就地短路。
> - 命中规则的、**经由 JS API** 发出的请求根本不会发到网络上 ⇒ 对这些请求，CORS、混合内容、证书、真实服务是否存在全部不适用。
> - 对**不经 JS API** 的网络途径，JS 层不适用；如需兑现"该地址真实服务不可访问"，必须另加**网络层硬阻断**（DNR `block`），而该硬阻断**只能失败、不能返回 Mock 响应**。
> - "用 DNR 重定向"确实不是同一条路：**DNR（声明式网络层）没有任何字段能承载响应体**，且页面 `fetch()` 跟随重定向到非 HTTP(S) scheme 会直接 `network error`。注意此结论**不适用于命令式网络层**（`chrome.debugger` + CDP `Fetch` 可以返回任意响应体），后者因权限、横幅、互斥、挂载粒度等原因仅作为可选路径。

### 6.2 与 §6「已接受的风险与预期行为」第 2 条的冲突

原文（第 254 行）：

> 2. **命中拦截地址后，该地址上的真实服务无法再被访问**（R9 + Q-A3）。用户配置即放弃该地址的真实连通性。

在纯 JS 层方案下，**这句话对"不走 JS API 的请求"是假的**。可选收敛方式（本文只列出，不裁定）：

- **方案 A**：承认缩小，把该条改写为"**经由 JS API 的请求无法再访问该地址的真实服务**"。
- **方案 B**：加一条 DNR `block` 规则兜底，使"真实服务不可访问"在**所有**途径上成立；代价是那些请求会得到网络错误而非 aria2 错误（与 R2/R3 的三值语义无关，因为它们本来就不在服务对象边界 R8 内）。

> 这条不在 F3 的裁定权内 —— 但它是 R9 修正后**必须由 captain/用户拍板**的下游后果。

### 6.3 与 R5「内置 UI 不得走特殊通道」的冲突

R5 要求内置 AriaNg UI 与普通页面**走同样路径**。若未来采用 CDP 路线：
- 扩展自身页面（`chrome-extension://<id>/...`）本身就是一个可 attach 的 target；但**给它 attach 会额外弹一条横幅**，且这条路径与"普通页面"在实现上完全不同（targetId 挂载 vs tabId 挂载）。
- 更关键：`ExtensionMayAttachToURL` 源码注释里写明 `debugger` 权限"implies all URLs access"，挂载行为**天然是"特殊通道"** [E20]。同一段源码还显示：扩展**可以**挂到自己 `chrome-extension://<自己的 id>/` 页面，但挂**别的扩展**的扩展页会被 `kCannotAccessExtensionUrl` 拒掉 [E36] —— 也就是说这条路的覆盖范围还受"谁的页面"影响，本身就不是"普通页面同款"。
- → **CDP 路线会直接违背 R5 的精神**，这是除 §3.5 之外的另一条否决理由。

### 6.4 与 Q-D2「拦截盲区必须明确列出」的关系（新增条目候选）

本文件为「拦截盲区清单」贡献以下**网络层视角**的条目（供后续文档收录）：

1. **JS 层覆盖不到的非 JS-API 网络途径**（地址栏导航、`<img>`/`<script>`/`<link>` 拉取、form 提交）—— DNR 能 block 但返回不了 Mock 响应 [E6]。
2. **ServiceWorker `onfetch` 自行合成或来自 CacheStorage 的响应** —— DNR 明确不生效 [E7]。
3. **`chrome.debugger` 的可用性盲区**：DevTools 被调起、另一个调试器已挂、企业策略、用户手动关闭横幅相关场景 [E14][E18][E19]。
4. **WebSocket 帧级消息** —— 两种网络层手段都只能碰握手 [E32]。
5. **`chrome://` / `view-source:` / PDF viewer** —— 这是原 Q-D2 已列的条目；本轮**未**找到 DNR/CDP 能覆盖它们的官方依据 → ❔。

### 6.5 与附录 A（`chrome.tabs` + DNR 下载引擎样例）的关系

- 附录 A 的两条 DNR 属于**下载引擎层**（R7 第三层），与本文讨论的**转发器层**（R4.1 第一层）是两条独立的线：DNR 在附录 A 里做的是"给真实请求改头 / 改响应头以触发浏览器下载"，**完全不需要响应体**，所以 DNR 在那里是好用的 —— 这恰好反证了"网络层能做请求定制、不能做 Mock"。
- 附录 A §A.3 里"`chrome.downloads` 触发的下载会无视修改请求头的 DNR" —— **本轮未找到官方依据**，标 ❔（§7 V9）。这是用户给的样例事实，本文不证伪也不证实。
- 附录 A §A.2 第 2 步"改 `Content-Disposition` 强制下载" —— `modifyHeaders` 能改响应头是官方能力 ✅ [E5]，但"改了就一定能触发下载"官方未直述 🟡。

---

## 7 未验证（本轮查不到官方依据，**不得当作结论使用**）

| # | 未验证项 | 已尝试的来源 | 影响 |
|---|---|---|---|
| V1 | 官方是否存在一句显式的"declarativeNetRequest 不能生成/返回响应体" | DNR API 参考页、DNR 概念页（仓库 markdown 源）、content-filtering 概念页、Chromium DNR README、MV3 迁移三件套（blocking-web-requests / improve-security / known-issues） | 无（可用封闭枚举/字段集代替，见 §3.1） |
| V2 | DNR 产生的重定向使用的**HTTP 状态码**（决定 POST 是否变 GET、body 是否丢弃） | Chromium `indexed_rule.cc`（只看到 `javascript:` 被禁）、`request_action.{h,cc}`、`constants.h`、DNR README | 中：影响"POST body 会不会丢"的确定回答 |
| V3 | DNR `redirect` 对 `resourceTypes: ["websocket"]` 是否生效 | DNR 参考页只有枚举值，无行为描述 | 中：影响 Q-D3 |
| V4 | DNR 是否作用于 **扩展自己发起**的请求（含 `chrome-extension://` 页面/`fetch`） | DNR 参考页、README、迁移文档均未提及 | 中：影响 R5 与"规则误伤自身"的判断 |
| V5 | CDP `Fetch` 是否覆盖 `blob:` / `data:` / `chrome-extension://` 等非 HTTP(S) 请求 | CDP Fetch 页与 `Network.ResourceType` 枚举中无 scheme 说明 | 中 |
| V6 | `Fetch.requestPaused` 后扩展不响应是否有超时（请求是否永久挂起） | CDP Fetch 域文档无超时说明 | 中：失败模式 F10 的另一半 |
| V7 | CDP `Fetch` 是否覆盖**地址栏直接导航**（用户主动输入 URL）触发的请求 | 官方只说明"target 是 tab"，未对导航来源作区分 | 低-中 |
| V8 | Firefox 是否有等价于 `chrome.debugger` 的"扩展挂调试器 + 原始 CDP"官方 API | MDN 权限清单、`chrome.debugger` 文档 | 低：Firefox 有 `filterResponseData` 替代 |
| V9 | 附录 A 的"`chrome.downloads` 触发的下载会无视修改请求头的 DNR" | Chrome downloads 文档、DNR 文档 | 中：影响下载引擎设计，但不属 F3 |
| V10 | Chrome Web Store 对 `debugger` 权限是否存在**专项**审核政策文本 | Chrome Web Store program policies、user-data-faq | 中：影响 CDP 路线的上架可行性 |
| V11 | Firefox MV3 下 `webRequestBlocking` 在 **2026 年**的最新现状（官方 2021 声明 + 现行 MDN 清单无限制标注，但未找到 2026 年的确认文本） | extensionworkshop MV3 迁移指南（**全页无 "webRequest" 字样**）、MDN 权限清单、MDN webRequest 页 | 中：跨浏览器可行性的关键假设 |
| V12 | `filterResponseData` 能否**凭空合成**一个从未存在的响应（含状态码），而不只是改写已到达的响应体 | MDN `filterResponseData` / `StreamFilter` 页（只描述"modify the response"、"data as it's received from the network"） | 中：决定 Firefox 是否真能替代 Mock 层 |
| V13 | DNR 响应头修改是否存在黑名单（如 `Set-Cookie` 之类） | DNR 参考页只给了**请求头** append 白名单 | 低：影响 `Content-Disposition` 等玩法 |

---

## 8 证据清单

> 全部为核对日期（2026-10-06 UTC）当日抓取的官方页面/源码原文。凡页面自带 "Last updated" 均照录。

| ID | 主张 | 来源 URL | 原文摘录 |
|---|---|---|---|
| E1 | DNR 的规则能力只有 block/upgradeScheme/redirect/modifyHeaders 四类 | https://developer.chrome.com/docs/extensions/develop/concepts/content-filtering | "These rules are able to: Block a network request. Upgrade the URL scheme to a secure scheme (http to https or ws to wss). Redirect a network request. Modify request or response headers." |
| E1b | 同一穷举（含"否定 allow"） | https://raw.githubusercontent.com/GoogleChrome/developer.chrome.com/main/site/en/docs/extensions/reference/declarativeNetRequest/index.md | "A single rule does one of the following: - Block a network request. - Upgrade the schema (http to https). - Prevent a request from getting blocked by negating any matching blocked rules. - Redirect a network request. - Modify request or response headers." |
| E2 | `RuleActionType` 是封闭枚举（6 项） | https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest#type-RuleActionType | "Enum: \"block\" … \"redirect\" … \"allow\" … \"upgradeScheme\" … \"modifyHeaders\" … \"allowAllRequests\"" |
| E3 | `RuleAction` 只有 4 个字段 | 同上 #type-RuleAction | "redirect: Redirect … Only valid for redirect rules." / "requestHeaders: … The request headers to modify for the request. Only valid if RuleActionType is \"modifyHeaders\"." / "responseHeaders: …" / "type: RuleActionType The type of action to perform." |
| E4 | `Redirect` 只有 4 个字段 | 同上 #type-Redirect | "extensionPath string optional — Path relative to the extension directory. Should start with '/'." / "regexSubstitution …" / "transform URLTransform optional — Url transformations to perform." / "url string optional — The redirect url. Redirects to JavaScript urls are not allowed." |
| E5 | `modifyHeaders` 三操作 + 请求头 append 白名单 | 同上 #type-HeaderOperation 与 #header_modification | "Enum: \"append\" … \"set\" … \"remove\"" / "The append operation is only supported for the following request headers: accept, accept-encoding, accept-language, access-control-request-headers, cache-control, connection, content-language, cookie, forwarded, if-match, if-none-match, keep-alive, range, te, trailer, transfer-encoding, upgrade, user-agent, via, want-digest, x-forwarded-for. This allowlist is case sensitive (bug 449152902)." |
| E6 | DNR 四个执行阶段 + block/redirect 在响应头阶段的退化 + 优先级 | 同上 #rule-evaluation | "Before a request is made, an extension can block or redirect (including upgrading the scheme from HTTP to HTTPS) it with a matching rule." / "Once the response headers have been received, Chrome evaluates rules with a responseHeaders condition." / "Note that if a request made it to this stage, the request has already been sent to the server and the server has received data like the request body. A block or redirect rule with a response headers condition will still run–but cannot actually block or redirect the request." / "In the case of a block rule, this is handled by the page which made the request receiving a blocked response and Chrome terminating the request early." / "Caution: Browser vendors have agreed not to standardize the order in which rules with the same action and priority run." |
| E7 | DNR 只作用于到达网络栈的请求；SW/CacheStorage 例外 | 同上 #interact-w-service-workers | "A declarativeNetRequest only applies to requests that reach the network stack. This includes responses from the HTTP cache, but may not include responses that go through a service worker's onfetch handler. declarativeNetRequest won't affect responses generated by the service worker or retrieved from CacheStorage, but it will affect calls to fetch() made in a service worker." |
| E8 | DNR redirect 到扩展资源必须 web_accessible | 同上 #implementation-web-accessible-resources | "A declarativeNetRequest rule cannot redirect from a public resource request to a resource that is not web accessible. Doing so triggers an error. This is true even if the specified web accessible resource is owned by the redirecting extension."（示例：`{"type":"redirect","redirect":{"extensionPath":"/a.jpg"}}`，`resourceTypes: ["main_frame"]`） |
| E9 | web_accessible_resources 会带 CORS 头 | https://developer.chrome.com/docs/extensions/reference/manifest/web-accessible-resources | "The resources are served with appropriate CORS headers, so they're available via fetch()." |
| E10 | 重定向到非 HTTP(S) scheme ⇒ network error；重定向上限 20 | https://fetch.spec.whatwg.org/#http-redirect-fetch | "If locationURL's scheme is not an HTTP(S) scheme, then return a network error." / "If request's redirect count is 20, then return a network error." / （方法/体规则）"If internalResponse's status is 301 or 302 and request's method is POST … internalResponse's status is 303 and request's method is not GET or HEAD then: Set request's method to GET and request's body to null." |
| E11 | DNR 配额 | DNR 参考页 #limits + E1 页 | "An extension can specify up to 100 static rulesets … but only 50 of these rulesets can be enabled at a time … guaranteed at least 30,000 rules" / "An extension can have up to 5000 session rules." / "Starting in Chrome 121, there is a larger limit of 30,000 rules available for safe dynamic rules" / "the total number of regex rules of each type cannot exceed 1000" / "each rule must be less than 2KB once compiled" / "Chrome has a global shared pool of 300,000 rules" |
| E12 | DNR 权限与安装期警告 | https://developer.chrome.com/docs/extensions/reference/permissions-list | "\"declarativeNetRequest\" … Warning displayed: Block content on any page." / "\"declarativeNetRequestWithHostAccess\" … requires host permissions for all actions." / "\"declarativeNetRequestFeedback\" … for use with unpacked extensions and is ignored for extensions installed from the Chrome Web Store. Warning displayed: Read your browsing history." |
| E12b | 两个 DNR 权限"能力相同、都要 host 权限、只差警告" | https://raw.githubusercontent.com/GoogleChrome/developer.chrome.com/main/site/en/docs/extensions/reference/declarativeNetRequest/index.md （front matter `has_warning`） | "The `declarativeNetRequest` and `declarativeNetRequestWithHostAccess` permissions provide the same capabilities, and both require host permissions; however, the latter prevents host permission warnings." / 另（迁移文档）："Notice that redirecting also requires the \"declarativeNetRequestWithHostAccess\" permission in addition to the host permission."（https://developer.chrome.com/docs/extensions/develop/migrate/blocking-web-requests ） |
| E13 | CDP `Fetch` 域能做什么（含 fulfillRequest.body = base64 任意响应体；enable 会暂停请求） | https://chromedevtools.github.io/devtools-protocol/tot/Fetch/ ；原始规格 https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/browser_protocol.json （`version {"major":"1","minor":"3"}`） | "A domain for letting clients substitute browser's network layer with client code." / "Enables issuing of requestPaused events. A request will be paused until client calls one of failRequest, fulfillRequest or continueRequest/continueWithAuth." / fulfillRequest.`body`: "A response body. If absent, original response body will be used if the request is intercepted at the response stage and empty body will be used if the request is intercepted at the request stage. (Encoded as a base64 string when passed over JSON)" / `RequestStage` enum: `['Request','Response']`，"Request will intercept before the request is sent." / requestPaused: "The request is paused until the client responds with one of continueRequest, failRequest or fulfillRequest." / continueRequest.`headers`: "Note that the overrides do not extend to subsequent redirect hops" |
| E14 | `chrome.debugger` 允许的 CDP 域白名单（含 `Fetch`）；企业策略会整块封死 attach | https://developer.chrome.com/docs/extensions/reference/api/debugger | "For security reasons, the browser.debugger API does not provide access to all Chrome DevTools Protocol Domains. The available domains are: Accessibility, Audits, CacheStorage, Console, CSS, Database, Debugger, DOM, DOMDebugger, DOMSnapshot, Emulation, Fetch, IO, Input, Inspector, Log, Network, Overlay, Page, Performance, Runtime, Storage, Target, Tracing, WebAudio, and WebAuthn." / "If enterprise policy ExtensionSettings configures blocked hosts (runtime_blocked_hosts) for an extension, browser.debugger.attach() is blocked on all targets with the error \"Host access is restricted by policy.\"" （该页 Last updated 2026-10-05 UTC） |
| E15 | 关联 target / flat session / 自动挂载不递归 | 同 E14 #attach-to-related-targets | "Starting in Chrome 125, the browser.debugger API supports flat sessions." / "you may want to connect to further related targets including out-of-process child frames or associated workers" / "Auto-attach only attaches to frames the target is aware of, which is limited to frames which are immediate children of a frame associated with it. … However, this is not recursive" / "Targets represent something which is being debugged—this could include a tab, an iframe or a worker." |
| E16 | `Debuggee` 三选一；挂扩展 background page 需命令行开关 | 同 E14 #type-Debuggee | "Debuggee identifier. Either tabId, extensionId or targetId must be specified" / "The id of the extension which you intend to debug. Attaching to an extension background page is only possible when the --silent-debugger-extension-api command-line switch is used." |
| E17 | 普通扩展不能挂浏览器级 target（只有 Perfetto 受信扩展能） | https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/extensions/api/debugger/debugger_api.cc | `constexpr char kBrowserTargetId[] = "browser";` / `} else if (*debuggee_.target_id == kBrowserTargetId && ExtensionIsTrusted(*extension())) {` / `bool ExtensionIsTrusted(const Extension& extension) { if (extension.id() != extension_misc::kPerfettoUIExtensionId) { return false; } …` / （另见 `getTargets()` 中 `if (host->GetType() == DevToolsAgentHost::kTypeTab) { continue; }` —— 官方 `getTargets()` **不列 tab target**） |
| E18 | 一个 target 同时只能挂一个调试器 | 同 E17 | `constexpr char kAlreadyAttachedError[] = "Another debugger is already attached to the * with id: *.";` |
| E19 | DevTools 被调起会导致扩展调试会话终止 | https://developer.chrome.com/docs/extensions/reference/api/debugger （事件 onDetach） | "Fired when browser terminates debugging session for the tab. This happens when either the tab is being closed or Chrome DevTools is being invoked for the attached tab." |
| E20 | `debugger` 权限的两条安装警告；不需 host 权限；源码解释"全站"来源 | https://developer.chrome.com/docs/extensions/reference/permissions-list ；https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions ；E17 源码 | "\"debugger\" Gives access to the chrome.debugger API. Warnings displayed: Access the page debugger backend. Read and change all your data on all websites." / "In some special cases, host permissions are not required. These include: … Interacting with the browser using the chrome.debugger API." / 源码："NOTE: The `debugger` permission implies all URLs access (and indicates such to the user), so we don't check explicit page access." |
| E21 | 调试横幅文案；detached 后也不消失；仅策略安装或 `--silent-debugger-extension-api` 才抑制 | https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/app/generated_resources.grd ；E17 源码 | `<message name="IDS_DEV_TOOLS_INFOBAR_LABEL" desc="Label displayed in an infobar when external debugger is attached to the browser. The label does not disappear until the user dismisses it, even if the debugger is detached, …"> "<ph name="CLIENT_NAME">$1<ex>Extension Foo</ex></ph>" started debugging this browser` / 源码：`const bool suppress_warning = base::CommandLine::ForCurrentProcess()->HasSwitch(::switches::kSilentDebuggerExtensionAPI) || Manifest::IsPolicyLocation(extension_->location());` |
| E22 | 挂着调试器会让 SW 无限期保活 | 同 E17 | `service_worker_keepalive_ = process_manager->IncrementServiceWorkerKeepaliveCount( *extension_service_worker_id_, content::ServiceWorkerExternalRequestTimeoutType::kDoesNotTimeout, Activity::DEBUGGER, /*extra_data=*/std::string());` |
| E23 | SW 生命周期上限（30s / 5min / fetch 30s） | https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle | "Normally, Chrome terminates a service worker when one of the following conditions is met: After 30 seconds of inactivity. … When a single request, such as an event or API call, takes longer than 5 minutes to process. When a fetch() response takes more than 30 seconds to arrive." |
| E24 | Chrome MV3 下 `webRequestBlocking` 仅策略安装扩展可用；内存缓存请求对 webRequest 不可见 | https://developer.chrome.com/docs/extensions/reference/api/webRequest | "webRequestBlocking — Required to register blocking event handlers. As of Manifest V3, this is only available to policy installed extensions." / "Requests that are answered from the in-memory cache are invisible to the web request API." |
| E24b | Chrome 权限清单**仍**列着 `webRequestBlocking` 且无 MV3 标注（故清单存在性不是可用性证据） | https://developer.chrome.com/docs/extensions/reference/permissions-list | "\"webRequestBlocking\" Allows the use of the chrome.webRequest API for blocking." |
| E25 | MV2 死刑时间线（Chrome 138 全渠道禁用；139 移除企业豁免；2026-08-31 商店清空） | https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline | "Aug 31st 2026: All remaining Manifest V2 extensions removed from the Chrome Web Store" / "Jul 24th 2025: Manifest V2 is disabled everywhere — With Chrome 138 all users on all channels of Chrome have now Manifest V2 extensions disabled. Users can no longer turn them back on." / "For Enterprises, the ExtensionManifestV2Availability policy will be removed with Chrome 139." |
| E26 | （源码）DNR redirect 在规则解析层只禁 `javascript:` | https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/browser/api/declarative_net_request/indexed_rule.cc | `if (redirect_url.SchemeIs(url::kJavaScriptScheme)) { return ParseResult::ERROR_JAVASCRIPT_REDIRECT; }` —— 即解析层**没有**拦 `data:`；实际请求层行为未验证（§7 V2） |
| E27 | DNR 在 `onBeforeRequest` 阶段计算，早于任何 TCP 连接 | https://raw.githubusercontent.com/chromium/chromium/main/extensions/browser/api/declarative_net_request/README.md | "This doc gives a brief overview of the implementation of the declarativeNetRequest API which allows extensions to specify declarative rules to block, redirect, upgrade or modify headers on a network request." / "Declarative Net Request actions are calculated during the onBeforeRequest stage of the webRequest API i.e. before any TCP connection is made with the server. Actions to block, collapse, upgrade or redirect the request are applied at this stage while header modification actions are calculated but not applied yet" |
| E28 | Firefox blocking webRequest 的能力面 | https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest （原始 markdown：https://raw.githubusercontent.com/mdn/content/main/files/en-us/mozilla/add-ons/webextensions/api/webrequest/index.md ） | "To use the \"blocking\" feature, the extension must also have the \"webRequestBlocking\" API permission." / "cancel the request in: onBeforeRequest / onBeforeSendHeaders / onAuthRequired；redirect the request in: onBeforeRequest / onHeadersReceived；modify request headers in: onBeforeSendHeaders；modify response headers in: onHeadersReceived" / "To modify the HTTP response bodies for a request, call webRequest.filterResponseData, passing it the ID of the request." |
| E29 | `filterResponseData` 的定位与权限 | https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest/filterResponseData | "The stream filter gives the web extension full control over the stream, with the ability to monitor and modify the response. It's the extension's responsibility to write and close or disconnect the stream, as the default behavior is to keep the request open without a response." / "From Firefox 95, to use this API to intercept requests related to the loading of service worker scripts, the \"webRequestFilterResponse.serviceWorkerScript\" permission is also required." / "From Firefox 110, Manifest V3 extensions must also request the \"webRequestFilterResponse\" permission to use this API."（页面 last modified 2025-07-17） |
| E30 | `StreamFilter` 的语义（数据来自网络；write 才进渲染引擎） | https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest/StreamFilter （原始 markdown 已抓取） | "The filter is passed HTTP response data as it's received from the network." / "The filter has full control over the response body, and the default behavior without any listeners or write calls is to have a stream without content that never closes." / "Note that the request is blocked during the execution of any event listeners." / 另：`BlockingResponse.redirectUrl` — "Redirections to non-HTTP schemes such as data: are allowed. Redirects use the same request method as the original request unless initiated from onHeadersReceived stage, in which case the redirect uses the GET method."（https://raw.githubusercontent.com/mdn/content/main/files/en-us/mozilla/add-ons/webextensions/api/webrequest/blockingresponse/index.md ） |
| E31 | Mozilla 官方承诺保留 blocking webRequest；MDN 现行清单无 MV3 限制 | https://blog.mozilla.org/addons/2021/05/27/manifest-v3-update/ ；https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/permissions | "we have decided to implement DNR *and* continue maintaining support for blocking webRequest" / "We will support blocking webRequest until there's a better solution which covers all use cases we consider important, since DNR as currently implemented by Chrome does not yet meet the needs of extension developers." / MDN 权限清单里 `webRequestBlocking` 与 `webRequest`、`webRequestFilterResponse` 并列，**无任何 MV3 限制标注** |
| E32 | WebSocket 只拦握手、不拦帧；WebSocket 不支持 redirect | https://developer.chrome.com/docs/extensions/reference/api/webRequest | "Starting from Chrome 58, the webRequest API supports intercepting the WebSocket handshake request. … Note that the API does not intercept: Individual messages sent over an established WebSocket connection. WebSocket closing connection. Redirects are not supported for WebSocket requests." / MDN 侧："Add event listeners for the various stages of making an HTTP request, which includes websocket requests on ws:// and wss://." |
| E33 | DNR 的 `ResourceType` 含 `websocket` / `webtransport` | E2 页 #type-ResourceType | "Enum: \"main_frame\" … \"xmlhttprequest\" … \"websocket\" \"webtransport\" \"webbundle\" \"other\"" |
| E34 | Chrome 官方对 MV2→MV3 阻断用法的替代口径 | https://developer.chrome.com/docs/extensions/develop/migrate/known-issues | "Q: My Manifest V2 extension relies on webRequestBlocking which is not supported in Manifest V3. How can I continue to provide the same functionality in Manifest V3? A: We are confident that most request blocking use cases can be solved with the new declarativeNetRequest API … However, for complex enterprise (or education) use cases, dynamic request blocking is still supported." |
| E35 | 版本与协议版本 | https://chromereleases.googleblog.com/ ；https://www.mozilla.org/en-US/firefox/releases/ ；CDP `browser_protocol.json` | "Stable Channel Update for Desktop — Thursday, October 1, 2026 — The Stable channel has been updated to 154.0.8037.97/.98 for Windows and Mac and 154.0.8037.97 to Linux" / "The Dev channel has been updated to 157.0.8081.0"（2026-10-02）/ "Extended Stable … 152.0.7977.152" / Firefox 发行说明页当前列出的最新版本为 **157.0** / CDP `{"version":{"major":"1","minor":"3"}}` |

**辅助证据（用于 §6.3 的推理，非独立主张）**：

| ID | 内容 | 来源 | 摘录 |
|---|---|---|---|
| E36 | `debugger` 权限在源码里绑定"扩展对自己 URL 可挂、对别的扩展 URL 不可挂" | E17 源码 `ExtensionMayAttachToURL` | `if (url_for_restriction_check.SchemeIs(extensions::kExtensionScheme) && url_for_restriction_check.host() != extension.id() && !allow_on_extension_urls) { *error = manifest_errors::kCannotAccessExtensionUrl; return false; }` |
| E37 | MV3 webRequest 与 CORS 的关系（现行文档仍保留，用于理解"头部修改会不会炸 CORS"） | https://developer.chrome.com/docs/extensions/reference/api/webRequest | "Starting from Chrome 79, request header modifications affect Cross-Origin Resource Sharing (CORS) checks. If modified headers for cross-origin requests do not meet the criteria, it will result in sending a CORS preflight to ask the server if such headers can be accepted. … On the other hand, response header modifications do not work to deceive CORS checks." |

---

## 9 变更记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v1 | 2026-10-06 | 首版。完成 DNR / chrome.debugger+CDP Fetch / MV2 blocking webRequest / Firefox filterResponseData 四条路线的官方来源核实；给出 R9 裁定意见：**维持结论、修正论据**；新增 13 项未验证条目与 17 条失败模式/盲区候选。 |
