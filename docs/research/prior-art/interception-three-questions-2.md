# 拦截三问 B：标签页请求转发 / fetch 与 XHR 劫持 / 能否拦其它扩展

> 本文件是 `aria2-in-browser` 项目「浏览器技术边界测绘」的既有方案调研产物之一。
> **独立重复说明**：本题由 `prior-intercept-a` 与 `prior-intercept-b` 各自独立完成；本文件作者为 **prior-intercept-b**，撰写过程中**未参考**任何其他人的中间产物、结论或草稿。

---

## 0 元信息

| 项 | 值 |
|---|---|
| 文档 | 既有方案调研 —— 拦截三问 B |
| 任务 | `t15`（attempt 1） |
| 作者 | prior-intercept-b（独立重复研究） |
| 调研日期 | **2026-10-06**（UTC） |
| 适用浏览器基线 | Chromium / Chrome 系（官方文档 + **Chromium `main` 分支源码**，抓取于 2026-10-06）；另附 Firefox 对照，凡 Firefox 结论均单独标注 |
| 版本说明 | 文档中的里程碑（Chrome 138 / 139 / 125 / 72 / 58 …）来自官方文档与 Chromium 源码注释；**本次未逐一核对"当前稳定版号"**，凡涉及"当前版本"的表述均以官方文档文字为准 |
| 方法 | 只采信：① W3C/WHATWG 规范 ② Chrome for Developers / MDN 官方文档 ③ Chromium 源码（chromium.googlesource.com / GitHub 镜像）④ 开源项目源码与官方文档。**禁止凭记忆断言**；取不到证据的内容一律进 §9「未验证 / 存疑」 |
| 覆盖范围 | 第一问：拦截并转发"标签页发出的请求"的现有方案与现成扩展；第二问：`fetch` / `XMLHttpRequest` 封装劫持的现成库、伪造与反检测；第三问：能否拦截/修改**其它扩展**发出的网络请求 |
| 不在范围 | 具体设计、接口规格、代码实现、性能基准；Windows/macOS 平台差异；Safari/WebKit 与 Edge 专属行为（未验证） |
| 硬约束遵守 | 本次只写本文件；未改动任何代码，未改动 `/workspace/docs/concept-design/concept-design.md`，未触碰其他成员文件 |

**证据等级标记**（全文使用）

- **A** = 官方规范 / 官方文档（W3C、WHATWG、Chrome for Developers、MDN）
- **B** = Chromium 源码（`chromium.googlesource.com`，`main` 分支）
- **C** = 开源项目源码 / README
- **D** = 厂商官方文档 / 官方博客（闭源产品的官方说明）
- **E** = 推断（无直接出处，正文中显式写"推断"，并进 §9）

---

## 1 一句话结论（三问各一句）

1. **第一问（转发标签页请求）**：能"看到并改写"标签页请求的途径有五层 —— MV2 阻塞式 `webRequest`（**平台已死**：Chrome 139 起 MV2 全面失效，2026-08-31 CWS 已下架全部剩余 MV2 扩展）、MV3 观测型 `webRequest`（只能看、**不能改**）、`declarativeNetRequest`（能 block/redirect/改头，**不能合成响应体**）、`chrome.debugger` + CDP `Fetch` 域（**能 `Fetch.fulfillRequest` 返回任意响应体**，但代价是"正在调试此浏览器"信息条、与 DevTools 互斥、企业策略可阻止）、以及 content script 在 **MAIN world 的 JS API 层改写**（本项目 R9 所选路径，覆盖面取决于注入时机与目标 realm）。
2. **第二问（fetch / XHR 劫持）**：本次调研的五个库（`ajax-hook`、`xhook`、`fetch-intercept`、`@mswjs/interceptors`、`sinon/nise`）**一律通过替换全局构造器/全局函数**来实现（**没有一个去改原型方法** —— `ajax-hook` 源码注释给出了原因），因此**只能作用于本 realm**、**必须跑在 MAIN world 才能拦页面自己的 `fetch`/`XHR`**；`Response` 只能"用真 `Response` 再补只读字段"，`XMLHttpRequest` 实例**无法用纯 JS 对象伪造**（WebIDL brand check 会抛 `TypeError`），只能包一个真 XHR；同步 XHR、事件时序、`Function.prototype.toString` 是主要的可检测面。
3. **第三问（拦别的扩展）**：**默认答案是不能**。①content script 的 match pattern **根本不支持 `chrome-extension://` scheme**（Chromium `UserScript::ValidUserScriptSchemes` 不含 `SCHEME_EXTENSION`），别的扩展页面注入不进去；②`webRequest` 的事件路由器**显式过滤来自其它扩展的请求**（"Filter requests from other extensions / apps"）；③DNR 对"其它扩展发起的非主框架请求"**整套 ruleset 直接跳过**，且**任何资源都不允许作用在 `chrome-extension:` scheme 上**；④`chrome.debugger` 附加到别的扩展页面/Service Worker 需要命令行开关 `--extensions-on-extension-urls`，`extensionId` 目标还需要 `--silent-debugger-extension-api`，浏览器级 target 只对 Perfetto 白名单扩展开放。
   → 对"让第三方 aria2 前端扩展连 `localhost:6800` 的请求被我们接住"这一动机：**默认不可行**；仅有三种例外（浏览器带命令行开关启动、该扩展自己在页面 MAIN world 发请求、该扩展主动与我们集成），均不构成产品方案。

---

## 2 第一问：拦截并转发「标签页发出的请求」的现有方案

### 2.0 先分层：五条途径各自站在哪一层

| # | 途径 | 所在层 | 命中后请求是否发出 | 能否给出自定义响应体 | 平台现状（2026-10-06） |
|---|---|---|---|---|---|
| 1 | MV2 阻塞式 `webRequest` | 网络层（浏览器进程内，请求发出前） | **可选**：返回 `cancel`/`redirectUrl` 时否，仅改头时是 | **能**（`redirectUrl` 允许 `data:` URL） | **已死**（Chrome 139 起 MV2 不可用） |
| 2 | MV3 观测型 `webRequest` | 网络层（只读） | 是（无法阻止） | 否 | 可用（`webRequest` 权限仍在） |
| 3 | `declarativeNetRequest`（DNR） | 网络层（声明式规则，不进入 JS 回调） | 取决于 action（block 可阻止） | **不能**（没有任何 action 能提供响应体） | 可用，MV3 主力 |
| 4 | `chrome.debugger` + CDP `Fetch` 域 | 调试协议层（可拦到"请求/响应"两个阶段） | 可（`fulfillRequest` 直接回答，`failRequest` 失败） | **能**（`Fetch.fulfillRequest.body`） | 可用，但用户可见成本高 |
| 5 | content script / user script 在 JS API 层改写 | 渲染进程 JS 层（页面 realm 内） | **否**（在本 realm 内就地短路） | **能**（构造任意 `Response`） | 可用，本项目 R9 所选路径 |

> 证据见下面各小节。层与层的差别是本文件后续所有结论的基础：**只有 4 与 5 能"凭空回答一个请求"**；1 只能靠 `data:` 重定向近似；2 与 3 完全不能。

### 2.1 MV2 阻塞式 `webRequest`（现状 / 是否还有平台支持）

**出处**
- Chrome for Developers，`chrome.webRequest`（A）：<https://developer.chrome.com/docs/extensions/reference/api/webRequest>
- Chrome for Developers，MV2 退役时间线（A）：<https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline>
- Chrome for Developers，把阻塞式 webRequest 迁移到 DNR（A）：<https://developer.chrome.com/docs/extensions/develop/migrate/blocking-web-requests>

**原理 / 能力**
- 监听器加 `"blocking"` 后**同步**返回 `BlockingResponse`，可 `cancel: true`、`redirectUrl`、改写请求头/响应头。
- 原文（A，`webRequest` 文档，`BlockingResponse.redirectUrl`）：

  > "Only used as a response to the onBeforeRequest and onHeadersReceived events. If set, the original request is prevented from being sent/completed and is instead redirected to the given URL. **Redirections to non-HTTP schemes such as `data:` are allowed.**"

  → **MV2 阻塞式 webRequest 可以合成自定义响应体**，办法是把请求重定向到一个 `data:` URL。
- 现成实例（C）：Resource Override 源码里就是这么做的 —— `src/background/requestHandling.js`：

  ```js
  redirectUrl: "data:" + mimeAndFile.mime + ";charset=UTF-8;base64," + ...
  ```
  <https://github.com/kylepaulsen/ResourceOverride/blob/master/src/background/requestHandling.js>

**平台现状（这是本小节的重点）**
- 原文（A，`webRequest` 文档顶部注记）：

  > "As of Manifest V3, the `"webRequestBlocking"` permission is no longer available for most extensions. … Policy installed extensions can continue to use `"webRequestBlocking"`."
  > Permissions 小节："`webRequestBlocking` Required to register blocking event handlers. As of Manifest V3, **this is only available to policy installed extensions**."
- 原文（A，MV2 时间线）：
  - "Jul 24th 2025: Manifest V2 is disabled everywhere … You can no longer turn them back on."（Chrome 138 之后）
  - "Manifest V2 extensions will cease to function for any user upgrading to **Chrome 139** and subsequent versions."
  - "**Aug 31st 2026**: All remaining Manifest V2 extensions removed from the Chrome Web Store."
- 结论：**MV2 阻塞式 `webRequest` 对普通用户已经没有任何平台支持**。唯一例外是"策略安装扩展"（企业策略 `ExtensionSettings` 强制安装）；但它同样受 §4.2 的"其它扩展过滤"约束 —— 即策略安装也**救不了**"拦第三方扩展请求"这件事。

**覆盖范围**：MV2 时期为全部 `http/https/ws/wss/file/ftp/urn/chrome-extension（仅自家）` 请求；可见性受 host permission 与"隐藏请求"清单限制（见 §2.2 同款限制）。

**局限**（除平台已死外）
- 一切都要在网络层发生：命中后请求仍走网络栈（除 `cancel`/`data:` 重定向），拿不到"在页面里就地短路"的效果。
- 有一处官方明确的可见性黑洞（A，`webRequest` 文档）：

  > "Requests that are answered from the in-memory cache are invisible to the web request API."

### 2.2 MV3 观测型 `webRequest`（能看到什么、不能做什么）

**出处**：同 §2.1（A）。Firefox 对照见 MDN（A）：<https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest>

**能看到什么**
- 事件仍齐全：`onBeforeRequest` / `onBeforeSendHeaders` / `onSendHeaders` / `onHeadersReceived` / `onResponseStarted` / `onCompleted` / `onErrorOccurred` / `onAuthRequired`（后者还需 `webRequestAuthProvider`）。
- 文档原文（A）："Aside from `"webRequestBlocking"`, the webRequest API is unchanged and available for normal use."
- 请求体可见：`OnBeforeRequestOptions` 枚举含 `"requestBody"`（"Specifies that the request body should be included in the event"）。
- **响应体不可见**：本次在 Chrome `webRequest` 文档中检索 "response body"，只出现在 `onResponseStarted` 的释义里（"the first byte of the response body is received"），**没有任何响应体读取 API**。Chrome 侧不存在 `webRequest.filterResponseData`（Firefox 有，见下）。

**不能做什么**
- 不能注册阻塞监听器（`webRequestBlocking` 仅策略安装扩展可用，见 §2.1）；因此**不能 cancel、不能 redirect、不能改头**。
- 可见性限制（A，原文）：

  > "The webRequest API only exposes requests that the extension has permission to see, given its host permissions. Moreover, only the following schemes are accessible: `http://`, `https://`, `ftp://`, `file://`, `ws://` (since Chrome 58), `wss://` (since Chrome 58), `urn:` (since Chrome 91), or `chrome-extension://`. In addition, even certain requests with URLs using one of the above schemes are hidden. These include **`chrome-extension://other_extension_id` where `other_extension_id` is not the ID of the extension to handle the request**, … Also **synchronous XMLHttpRequests from your extension are hidden from blocking event handlers** in order to prevent deadlocks."
  > "Starting from Chrome 72, an extension will be able to intercept a request only if **it has host permissions to both the requested URL and the request initiator**."

**Firefox 对照（重要差异）**
- MDN（A）明确提供 `webRequest.filterResponseData`：原文 "To modify response bodies for a request, call `webRequest.filterResponseData`, passing it the ID of the request. This returns a `webRequest.StreamFilter` object that you can use to examine and modify the data as it is received by the browser."（需要 `webRequestBlocking` + `webRequest` + 目标 host 权限）
- → **Firefox 是唯一"按官方文档"能在 webRequest 层改响应体的浏览器**；但需要 `webRequestBlocking`，Firefox 侧仍支持阻塞式 webRequest（MDN 文档页面 2026-10-06 抓取时仍如此描述）。Firefox 的具体行为本项目未做进一步验证，见 §9。

**覆盖范围**：与 MV2 相同的 scheme 清单，但**只能看**。Worker 内请求、`chrome://` 页面、PDF viewer 等是否可见：本次未逐条验证，见 §9。

### 2.3 `declarativeNetRequest`（DNR）

**出处**
- Chrome for Developers，`chrome.declarativeNetRequest`（A）：<https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest>
- Chromium 源码（B）：
  - `extensions/browser/api/declarative_net_request/ruleset_manager.cc`
  - `extensions/browser/api/declarative_net_request/indexed_rule.cc`
  - <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/browser/api/declarative_net_request/>

**block / redirect / modifyHeaders 各自能力**
- Action 类型（A，`RuleActionType` 枚举原文）：

  > `"block"` Block the network request.
  > `"redirect"` Redirect the network request.
  > `"allow"` Allow the network request. …
  > `"upgradeScheme"` Upgrade the network request url's scheme to https …
  > `"modifyHeaders"` Modify request/response headers from the network request.
  > `"allowAllRequests"` Allow all requests within a frame hierarchy …
- `modifyHeaders` 的能力边界（A）：`RuleAction` 只有 `requestHeaders` 与 `responseHeaders` 两个字段，逐条"set/append/remove"某个 header。**没有 body 字段。**
- `redirect` 的能力（A）：`Redirect` 类型只有 `url` / `extensionPath` / `transform` / `regexSubstitution`；"The redirect url. **Redirects to JavaScript urls are not allowed.**"（源码侧一致：`indexed_rule.cc` 只对 `javascript:` scheme 报 `ERROR_JAVASCRIPT_REDIRECT`）。
- 权限（A）：redirect / modifyHeaders 需要 `declarativeNetRequestWithHostAccess` 或 `declarativeNetRequest` + host permissions。迁移文档原文："Notice that redirecting also requires the `"declarativeNetRequestWithHostAccess"` permission in addition to the host permission."
- 重定向目标限制（A）："A declarativeNetRequest rule cannot redirect from a public resource request to a resource that is not web accessible."（即不能随手 redirect 到扩展的任意内部资源，必须声明 `web_accessible_resources`）

**关键：能不能合成自定义响应体 → 不能**
- 依据一（A）：`RuleActionType` 的六个取值里没有任何一个能携带响应体；`RuleAction` 字段只有 headers 相关。
- 依据二（A，DNR 文档开篇）：

  > "The `chrome.declarativeNetRequest` API is used to block or modify network requests by specifying declarative rules. This lets extensions modify network requests **without intercepting them and viewing their content**, thus providing more privacy."
- 依据三（D）：Requestly 官方文档的"浏览器扩展 vs 桌面应用"对照表里，**扩展**列明确写了 `Serve local file Response ❌`、`Modify HTML/JS/CSS Response ❌`、`Map Local ❌`，而桌面应用（本地代理）为 ✅；并以一句话总结：

  > "The extension works within the limitations of browser APIs. Features like serving local files or modifying HTML/CSS content are only supported in the desktop app due to broader system access."
  > <https://docs.requestly.com/account/how-is-browser-extension-different-from-a-desktop-app>
- 理论上唯一的近似手段是 `redirect` 到 `data:` URL（源码只拦 `javascript:`），**但**：①是否真被网络栈接受、是否与 MV2 的 `data:` 重定向同等语义，本次**未找到官方说明**；②即便如此它也只能整条替换、无法按 aria2 请求体动态生成响应（规则是声明式的，运行时只能增删规则）。→ 见 §9。

**对本项目特别相关的一条**：`modifyHeaders` 的 `responseHeaders` 可以 `set` `Content-Disposition: attachment; filename=...`，这与概念设计附录 A 的第 2 条 DNR 吻合（A 侧能力成立）。

### 2.4 `chrome.debugger` + CDP `Fetch` 域

**出处**
- Chrome for Developers，`chrome.debugger`（A）：<https://developer.chrome.com/docs/extensions/reference/api/debugger>
- CDP `Fetch` 域（A）：<https://chromedevtools.github.io/devtools-protocol/tot/Fetch/>
  - 机器可读协议定义（A）：<https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/browser_protocol.json>
- 实践样例（C）：Tamper Dev v2 源码 <https://github.com/google/tamperchrome>（`v2/background/src/{debuggee,interception,request}.ts`）

**能不能用 `Fetch.fulfillRequest` 返回自定义响应体 → 能**
- CDP 协议定义原文（A，`Fetch.fulfillRequest`）：

  > "Provides response to the request."
  > 参数 `body`：**"A response body. If absent, original response body will be used if the request is intercepted at the response stage and empty body will be used if the request is intercepted at the request stage."**（base64 编码传输）

- 真实项目里的用法（C，Tamper Dev v2）：

  ```js
  // v2/background/src/request.ts
  return this.debuggee.sendCommand('Fetch.fulfillRequest', {
    requestId: this.id,
    responseCode: response.status || this.status || 0,
    responseHeaders: response.responseHeaders || this.responseHeaders,
    body: response.responseBody || undefined
  })
  ```
  ```js
  // v2/background/src/interception.ts
  await this.debuggee.sendCommand('Fetch.enable', {
    patterns: [
      { urlPattern: pattern, requestStage: 'Request' },
      { urlPattern: pattern, requestStage: 'Response' },
    ]
  })
  ```
  `manifest_base.json`：`"permissions": ["debugger", "activeTab"]`，`chrome.debugger.attach(this.target, '1.2', …)`，target = `{ tabId: tab.id }`。

**能拦到什么范围**
- 按 tab 附加（`Debuggee.tabId`），或用 `Target.setAutoAttach`（Chrome 125+ 支持扁平会话）自动附加到 out-of-process iframe / worker；`RequestPattern` 支持 `urlPattern`（通配 `*`/`?`）、`resourceType`、`requestStage`（`Request` | `Response`）→ **范围比 DNR 精确、比 JS 层宽**（能拦到页面里任何网络途径，包括 `<img>`、`fetch`、XHR、WebSocket 握手等）。
- `Fetch` 域在 `chrome.debugger` 的**允许域名白名单**内（A，`debugger` 文档 "Restricted domains" 列表包含 Fetch/Network/Page/Runtime/Target…）。
- 阶段语义（A，CDP）："Request will intercept before the request is sent. Response will intercept after the response is received (but before response body is received)."

**代价（逐条，均有出处）**
1. **用户可见的调试信息条（普通安装的扩展无法关闭）**（B，`chrome/browser/extensions/api/debugger/debugger_api.cc` + `extension_dev_tools_infobar_delegate.cc` + `chrome/app/generated_resources.grd`）：

   ```cpp
   // We allow policy-installed extensions to circumvent the normal infobar warning.
   const bool suppress_warning =
       base::CommandLine::ForCurrentProcess()->HasSwitch(::switches::kSilentDebuggerExtensionAPI) ||
       Manifest::IsPolicyLocation(extension_->location());
   if (!suppress_warning) { CreateWarningInfobar(); }
   ```
   > `IDS_DEV_TOOLS_INFOBAR_LABEL` = "'<ph name="CLIENT_NAME">$1<ex>Extension Foo</ex></ph>' **started debugging this browser**"
   注（B，源码注释）："The label does not disappear until the user dismisses it, even if the debugger is detached."
   → 对普通用户，`chrome.debugger.attach()` **一定**会弹出该信息条；只有策略安装扩展或带 `--silent-debugger-extension-api` 启动才不弹。
2. **与 DevTools 互斥**（A，`onDetach` 原文）："Fired when browser terminates debugging session for the tab. This happens when either the tab is being closed or **Chrome DevTools is being invoked for the attached tab**."
3. **同时只能有一个调试器**：错误串 `kAlreadyAttachedError` = "Another debugger is already attached to the * with id: *."（B，`debugger_api.cc`）。用户打开 DevTools / 别的调试类扩展先附加，就失败。
4. **企业策略可整体阻止**（A，`debugger` 文档 "Enterprise policy restrictions"）：`runtime_blocked_hosts`、`DisableScreenshots`、DLP 规则都会让 `attach()` 直接失败。
5. **不能用作"无声后台通道"**：附加即展示信息条，属于用户可感知的强提示（产品体验问题，非技术阻塞）。
6. 附加目标的限制见 §4.4（别的扩展的页面/worker 需要命令行开关）。

### 2.5 content script 在 JS 层改写（本项目 R9 的路径）

**出处**
- Chrome for Developers，Content scripts（A）：<https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts>
- Chrome for Developers，manifest `content_scripts`（A）：<https://developer.chrome.com/docs/extensions/reference/manifest/content-scripts>
- Chrome for Developers，`chrome.scripting`（A）：<https://developer.chrome.com/docs/extensions/reference/api/scripting>
- Chrome for Developers，`chrome.userScripts`（A）：<https://developer.chrome.com/docs/extensions/reference/api/userScripts>

**原理 / 用了哪些 API**：把"转发器"代码作为 content script 注入目标页面，用 `"world": "MAIN"`（或 `scripting.executeScript({world:'MAIN'})`、userScripts 的 `"MAIN"`）跑进**页面的执行环境**，在那里替换 `window.fetch` / `window.XMLHttpRequest`（详见 §3），命中规则时直接返回构造好的响应。

**覆盖范围**
- 覆盖**同 realm 的所有 JS 发起的网络调用**（fetch/XHR 包装库都拦得到；`<img>`/`<script>` 标签、`sendBeacon`、导航等不属于 JS API 层 → 不在覆盖范围）。
- 覆盖**能注入到的 frame**：`all_frames` 可覆盖子框架；跨源 iframe 需其 URL 匹配 match pattern。
- 覆盖**时机**：默认 `document_idle`，`"document_start"` 是最早可注入点；在此之前发出的请求拦不到（概念设计 §6 第 4 条已列为预期盲区）。

**局限（逐条有据）**
1. **只在被注入的那个 realm 内有效**（A，content scripts 原文）：

   > "An **isolated world** is a private execution environment that isn't accessible to the page or other extensions. … Not only does each extension run in its own isolated world, but content scripts and the web page do too. This means that none of these (web page, content scripts, and any running extensions) can access the context and variables of the others."
   > → 注入到 MAIN world 才能改页面自己的 `fetch`/`XHR`；**改不到任何 ISOLATED world（含别的扩展的 content script）**。
2. **MAIN world 受页面 CSP 约束**（A，同一文档）：

   > "When a content script is injected into the main world, **the CSP of the page applies**."
   （ISOLATED world 有扩展自己的 CSP：`script-src 'self' 'wasm-unsafe-eval' 'inline-speculation-rules' chrome-extension://<id>/`）
3. **注入脚本对页面完全可见、可被篡改**（A，manifest 文档警告）：

   > "**Warning:** There are risks involved when using the `"MAIN"` world. The host page can access and interfere with the injected script."
4. **`chrome://`、`view-source:`、PDF viewer、Chrome Web Store 等受限页面注入不进去**，这是概念设计 §6 已接受的风险；本文件不再重复论证。
5. **Worker 内的请求**：属于另一个 realm（WorkerGlobalScope），content script 不覆盖；若要拦 Worker，需要在 Worker 上下文里另行注入（`xhook` 支持 Worker 全局对象，见 §3.3；但**扩展能否稳定地向页面的 Worker 注入脚本**，本次未验证 → §9）。

### 2.6 现成扩展逐个核查

> 说明：闭源扩展无法取证源码时，只采用**厂商官方文档/官方博客**（D）并显式标注"未验证源码"。本次尝试过三条取证通道均失败：Chrome Web Store 页面为 JS 渲染（抓不到文本）、`clients2.google.com` 的 CRX 下载在本环境被 TLS 层拒绝、`chrome-stats.com` 被 Cloudflare 拦截（403）。因此 ModHeader 一项**取不到一手证据**，只能据其官方站点跳转行为与第三方报道，按 §9 处理。

#### 2.6.1 Requestly

| 项 | 内容 |
|---|---|
| 出处 | <https://docs.requestly.com/account/how-is-browser-extension-different-from-a-desktop-app>；<https://requestly.com/blog/how-to-load-a-different-api-response-in-frontend-code/>；开源仓库 <https://github.com/requestly/requestly>（本次 sparse clone 后发现 `browser-extension` 目录在当前默认分支已不存在，未能取得其 Chrome 扩展 manifest → 记为未验证） |
| 原理 | 扩展内做 HTTP 规则（含 Response Rule）；**保真度受限时由桌面应用（本地代理）承担** |
| 用了哪些 API | **未验证**（未取到 manifest）。可确认的是它的能力边界与"浏览器 API 限制"一致；其扩展能提供 REST API 的 Response Rule，但**不能** serve 本地文件、**不能**改 HTML/JS/CSS 响应 |
| 覆盖范围 | 浏览器内请求（含 REST API 响应体替换，官方博客口径）；系统级/其它应用不支持（官方对照表 `System-wide Proxy ❌`） |
| 局限 | 官方原文："The extension works within the limitations of browser APIs. Features like serving local files or modifying HTML/CSS content are only supported in the desktop app due to broader system access." |

#### 2.6.2 ModHeader

| 项 | 内容 |
|---|---|
| 出处 | 官网 `https://modheader.com/` 跳转到 `https://app.modheader.com`（本次抓取只得到跳转）；第三方报道 <https://dev.to/yemoyang9a11y/modheader-is-gone-how-to-pick-a-replacement-and-move-your-header-rules-43n>（**非官方，仅作线索**） |
| 原理 | 请求头/响应头修改器（产品定位） |
| 用了哪些 API | **未验证**。按 MV2→MV3 迁移的通用约束，头部修改在 MV3 下通常映射为 DNR `modifyHeaders`；本次**没有取得其 manifest，不作断言** |
| 覆盖范围 / 局限 | **未验证**；特别注意：若它仍是 MV2 扩展，则随 Chrome 139 一并失效（见 §2.1） |

#### 2.6.3 Tamper Dev（原 Tamper Chrome）

| 项 | 内容 |
|---|---|
| 出处 | 官网 <https://tamper.dev/>（"This is the new version of the extension previously called Tamper Chrome"）；源码 <https://github.com/google/tamperchrome> |
| 原理 | 用 `chrome.debugger` 附加到当前标签页，直接说 CDP，在 **Fetch 域**拦截请求/响应并可改写（含响应体） |
| 用了哪些 API（C，v2） | `debugger` + `activeTab`；`chrome.debugger.attach({tabId}, '1.2')`；`Fetch.enable`（`requestStage` 取 `Request` / `Response` 两个阶段）、`Fetch.requestPaused`、`Fetch.getResponseBody`、`Fetch.continueRequest`、**`Fetch.fulfillRequest`（带 `body`）** |
| 覆盖范围 | 单标签页内的全部网络流量（含 HTTPS，"without the need of a proxy"），可改请求头、请求体、URL、响应体 |
| 局限 | ①`chrome.debugger` 的全部代价（信息条 / 与 DevTools 互斥 / 单调试器 / 企业策略，见 §2.4）；②仓库里的 manifest 是 **MV2**（`v2/manifest_base.json`：`"manifest_version": 2`），其"当前在商店的形态"未验证；③需要用户主动打开 Tamper 界面 |

#### 2.6.4 Resource Override

| 项 | 内容 |
|---|---|
| 出处 | 源码 <https://github.com/kylepaulsen/ResourceOverride>（本文件依据其 master 分支源码与 `manifest.json`） |
| 原理 | MV2 阻塞式 `webRequest`：命中规则时用 `redirectUrl` 把请求重定向到 **`data:` URL**（内容来自扩展内存/存储），从而"替换响应"；另有 content script 在 `document_start` 注入、devtools 面板做 UI |
| 用了哪些 API（C） | `manifest.json`：`"permissions": ["webRequest","webRequestBlocking","<all_urls>","tabs"]`、`devtools_page`、`content_scripts[{matches:["*://*/*"], run_at:"document_start"}]` |
| 覆盖范围 | 全部 `*://*/*` 主框架与子框架（`all_frames: true`），可替换 HTML/JS/CSS/JSON 等 |
| 局限 | **MV2 专属** → Chrome 139 起完全不可用（§2.1）；`data:` 重定向是整条替换，无法流式/动态按请求体生成 |

#### 2.6.5 Redirector

| 项 | 内容 |
|---|---|
| 出处 | 源码 <https://github.com/einaregilsson/Redirector>（依据其 master 分支 `manifest.json`） |
| 原理 | 规则驱动的 URL 重定向（`webNavigation` + 阻塞式 `webRequest`） |
| 用了哪些 API（C） | `"permissions": ["webRequest","webRequestBlocking","webNavigation","storage","tabs","http://*/*","https://*/*","notifications"]`，`"manifest_version": 2` |
| 覆盖范围 | 规则命中的请求/导航重定向 |
| 局限 | MV2 专属；只做重定向（不能合成响应体）。**仓库当前是 MV2**，其 Chrome 商店现状未验证（Firefox 版本仍在维护） |

#### 2.6.6 Tampermonkey / Violentmonkey（userscript 管理器）

| 项 | 内容 |
|---|---|
| 出处 | Tampermonkey 文档 <https://www.tampermonkey.net/documentation.php?q=sandbox>、<https://www.tampermonkey.net/documentation.php?q=unsafeWindow>；Violentmonkey 文档 <https://violentmonkey.github.io/api/metadata-block/#inject-into>；Violentmonkey 源码 <https://github.com/violentmonkey/violentmonkey> |
| 原理 | 用户脚本可运行在**页面上下文**，脚本里直接改 `fetch`/`XHR`（社区里大量"劫持请求"脚本正是这么做的）；`unsafeWindow` 用来访问页面 `window` |
| 用了哪些 API | Tampermonkey：`@sandbox` = `raw` / `JavaScript` / `DOM`，分别对应 `MAIN_WORLD` / `USERSCRIPT_WORLD`（Firefox，绕过 CSP）/ `ISOLATED_WORLD`；**`raw`（页面上下文）是省略时的默认值**，MAIN world 注入失败（如 CSP）时按列表回退。Violentmonkey：`@inject-into` = `page`（页面上下文） / `content`（content script 上下文） / `auto`（默认，先试 page，被 CSP 拦则 content）；另有 `@grant none` 关闭沙箱、"can add/modify globals directly" |
| 覆盖范围 | 与 §2.5 完全一致（JS API 层 + 可注入的 realm） |
| 局限 | ①`content` 模式明确"cannot access JavaScript objects of the web page"；②`auto` 在 CSP 严格站点会退化为 content 模式 → JS 层劫持失效；③Tampermonkey 的 `unsafeWindow` 官方描述仅为"provides access to the `window` object of the page"，**不等于**能改页面里已被别的脚本捕获的引用。 |

### 2.7 第一问小结：能力矩阵

| 手段 | 观察请求 | 改请求头 | 改响应头 | 阻止请求 | 合成响应体 | 动态（按请求体）生成 | 用户可感知成本 |
|---|---|---|---|---|---|---|---|
| MV2 blocking webRequest | ✅ | ✅ | ✅ | ✅ | ✅（`data:` 重定向） | ✅（后台 JS 动态决定） | 无（但**平台已死**） |
| MV3 webRequest（观测） | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | 无 |
| DNR | 不可编程观察 | ✅ | ✅ | ✅ | ❌ | ❌ | 无 |
| chrome.debugger + Fetch | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | **极高**（信息条/互斥/单调试器） |
| MAIN-world JS 改写 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 无（但页面可检测/可破坏） |
| ISOLATED-world 改写 | ✅（本扩展自己的调用） | ✅ | — | ✅ | ✅ | ✅ | 无；**拦不到页面 JS**（realm 隔离） |

---

## 3 第二问：`fetch` / `XMLHttpRequest` 封装劫持的现有做法

### 3.1 拦截点的三种形态（先说清"改的是构造器还是原型方法"）

- **改全局函数**（`window.fetch = wrapper`）：`fetch-intercept`、`xhook`（含 fetch patch）、`@mswjs/interceptors` 都这么做。被改的是**全局绑定**，不是 `Response`/`Request`。
- **改全局构造器**（`window.XMLHttpRequest = Wrapper`）：`ajax-hook`、`xhook`、`@mswjs/interceptors`（Proxy）、`nise` 都这么做。这是唯一能同时拦住 `new XMLHttpRequest()` 与所有实例方法调用位置的做法。
- **改原型方法**（`XMLHttpRequest.prototype.open = ...`）：**本次调研的五个库里没有一个这么做**。原因（C 佐证）：`ajax-hook` 源码注释里写得很清楚 —— "We shouldn't hookAjax XMLHttpRequest.prototype because we can't guarantee that all attributes are on the prototype. Instead, hooking XMLHttpRequest instance can avoid this problem."（`src/xhr-hook.js`）。
- 附带结论：**"改原型"不是主流**；实践中的共同前提是"必须早于页面第一次取到 `XMLHttpRequest` / `fetch`"（`xhook` README 原文："It's important to include XHook first as other libraries may store a reference to `XMLHttpRequest` before XHook can patch it"）。

### 3.2 `ajax-hook`

| 项 | 内容 |
|---|---|
| 出处 | <https://github.com/wendux/ajax-hook>（v2，`src/xhr-hook.js` / `src/xhr-proxy.js`） |
| 原理 | 保存原生 `window.XMLHttpRequest`，用一个**普通函数** `HookXMLHttpRequest` 顶替；`new` 时内部创建一个原生 XHR 实例，把它的属性用 `Object.defineProperty` 逐个搬到"代理对象"上（每个函数属性包一层 hook），并把 `HookXMLHttpRequest.prototype = originXhr.prototype; HookXMLHttpRequest.prototype.constructor = HookXMLHttpRequest;`，再把 `UNSENT/OPENED/HEADERS_RECEIVED/LOADING/DONE` 通过 `Object.assign` 挂到新的全局构造器上 |
| 拦截点 | **全局构造器**（`win.XMLHttpRequest = HookXMLHttpRequest`）；实例方法被逐个包壳（`open`/`send`/`setRequestHeader`…），事件回调（`onload`/`onreadystatechange`…）被重写转发 |
| 抗检测性（源码可证的问题） | ①原生实例被存在代理对象的 **`__origin_xhr`** 自有属性上（`this[OriginXhr] = xhr`，`var OriginXhr = '__origin_xhr'`）→ 页面 `for (const k in xhr)` 或直接读 `xhr.__origin_xhr` 即可识破；②`window.XMLHttpRequest.toString()` 不再是 `[native code]`；③代理对象的属性是自己 `defineProperty` 出来的（`enumerable: true`），与原生实例的属性位置/描述符不同 |
| 同步 XHR | **支持**：`xhr.open(rq.method, rq.url, rq.async !== false, …)`；`config.async === false ? req() : setTimeout(req)`（`xhr-proxy.js`）→ 同步请求走同步路径 |
| 要求的 world | **MAIN world**（或任何真的要拦页面 `fetch`/`XHR` 的 realm）；`proxy(proxyObject, [window])` 允许传入目标 window。在 ISOLATED world 里执行只能拦到该 world 自己的调用 |
| 覆盖 | 只覆盖 `XMLHttpRequest`；不管 `fetch`、`WebSocket`、`sendBeacon`、标签元素 |

### 3.3 `xhook`

| 项 | 内容 |
|---|---|
| 出处 | <https://github.com/jpillora/xhook>（`src/main.js`、`src/patch/xmlhttprequest.js`、`src/patch/fetch.ts`、`src/misc/window.js`） |
| 原理 | 自己实现一个 **facade**（`EventEmitter`），替换全局 `XMLHttpRequest`；真实请求由内部原生 XHR 发出，facade 负责把 readyState/事件"重放"给调用方；另有 fetch 的 facade |
| 拦截点 | **两个全局**：`windowRef.XMLHttpRequest = Xhook`（`patch()`）与 `windowRef.fetch = Xhook`（`patch()`）；`xhook.before()` / `xhook.after()` 钩子链 |
| 抗检测性 | ①`window.XMLHttpRequest` 是纯 JS 函数；②事件是**手工 dispatch** 的（`facade.dispatchEvent("readystatechange", {})` 等），与原生事件对象的内部结构不同；③异步最终事件被 `setTimeout(emitFinal, 0)` 推后一个宏任务（见下）；④`Xhook.Native` 暴露原生构造器，页面拿不到但调试器可见 |
| 同步 XHR | **显式支持**：`if (request.async === false) { emitFinal(); } else { setTimeout(emitFinal, 0); }`；且"skip async hook on sync requests"（长度为 2 的 hook 在同步请求里被跳过） |
| 要求的 world | MAIN world。`src/misc/window.js` 还会识别 `WorkerGlobalScope`（`self`）与 Node 的 `global` → **同一套代码可以注入 Worker 上下文**（但"扩展能不能把脚本送进页面的 Worker"是另一个问题，见 §9） |
| 覆盖 | `XMLHttpRequest` + `fetch`（含 Worker 全局对象）；不管 `WebSocket`、`sendBeacon` |

### 3.4 `fetch-intercept`

| 项 | 内容 |
|---|---|
| 出处 | <https://github.com/werk85/fetch-intercept>（`src/attach.js`、`README.md`） |
| 原理 | README 原文："`fetch-intercept` **monkey patches the global `fetch` method** and allows you the usage in Browser, Node and Webworker environments." 拦截器链里最后调用**原生的 `fetch`**，再把真实 `Response` 交给 `response` 拦截器 |
| 拦截点 | 全局函数 `fetch`（`attach(window)` / `attach(self)`）；不碰 `XMLHttpRequest` |
| 抗检测性 | 需要"在第一次使用 `fetch` 之前 require"（README 原文："You need to require `fetch-intercept` before you use `fetch` the first time."）；patch 后 `window.fetch.toString()` 非 native。它**不会**主动掩盖任何痕迹 |
| 能不能伪造响应 | 该库自身只"拦截/改写"；要返回自定义响应，得在 `response` 拦截器里返回一个**你自己的 `Response`**（见 §3.8 的伪造约束） |
| 要求的 world | MAIN world（或目标 fetch 所在 realm） |
| 覆盖 | 只有 `fetch` |

### 3.5 `@mswjs/interceptors`

| 项 | 内容 |
|---|---|
| 出处 | <https://github.com/mswjs/interceptors>（`src/interceptors/fetch/web.ts`、`src/interceptors/XMLHttpRequest/web.ts`、`src/interceptors/XMLHttpRequest/xml-http-request-proxy.ts`、`src/utils/patches-registry.ts`、`README.md`） |
| 原理 | 浏览器侧：`patchesRegistry.applyPatch(globalThis, 'fetch', …)` 与 `patchesRegistry.applyPatch(globalThis, 'XMLHttpRequest', …)`；XHR 的实现是 **`new Proxy(globalThis.XMLHttpRequest, { construct(...) {…} })`**，构造时仍创建**真正的原生 XHR**（`Reflect.construct(target, args, newTarget)`），再把 `target.prototype` 的所有描述符逐个 `Reflect.defineProperty` 到实例上，最后把实例交给 `XMLHttpRequestController` 做拦截 |
| 拦截点 | 两个全局；`patchesRegistry` 用 `Object.defineProperty(owner, key, {value, enumerable:true, configurable:true})`（可配置时）或直接赋值（可写时），并支持 `restoreAllPatches()` |
| 抗检测性 | ①XHR 用 `Proxy` 包构造器：`xhr instanceof XMLHttpRequest` 仍然成立，`window.XMLHttpRequest` 的 **identity** 变了（若页面事先存过原生引用，一比就露）；②实例上的属性是从原型"搬"过来的 own property（描述符布局与原生不同）；③mock 响应的事件由控制器手工触发，时序与原生不同 |
| 同步 XHR | **不支持**（源码原文）：`console.warn("Failed to intercept an XMLHttpRequest (${method} ${url}): synchronous requests are not supported. This request will be performed as-is.")` 然后直接放行 |
| 要求的 world | MAIN world（浏览器拦截器就是 patch `globalThis`） |
| 补充（README，A 级口径但属第三方文档） | Node 侧走的是 socket 级拦截（`Socket.prototype.connect`、`tcp_wrap`/`tls_wrap`），与浏览器侧完全不是一条路；浏览器侧就是"patch 全局" |

### 3.6 `sinon` / `nise` 的 fake server

| 项 | 内容 |
|---|---|
| 出处 | <https://github.com/sinonjs/nise>（`lib/fake-xhr/index.js`、`lib/fake-server/index.js`） |
| 原理 | `nise` 提供 **`FakeXMLHttpRequest`**（一个纯 JS 重写版 XHR）与 `fakeServer`；`useFakeXMLHttpRequest()` 里直接 `globalScope.XMLHttpRequest = FakeXMLHttpRequest`，并保留 `restore()` 以还原 |
| 拦截点 | **全局构造器**；fake server 的 `respondWith(method, url, body)` + `server.respond()` 是**手工驱动**的；`autoRespond` 用 `setTimeout(..., server.autoRespondAfter 或默认 10ms)` |
| 抗检测性 | 最差的一类：`FakeXMLHttpRequest` 不是平台对象，`xhr instanceof <原生 XMLHttpRequest>`（若页面存了原生引用）为 `false`；实例没有原生内部槽；拿到原生 `XMLHttpRequest.prototype` 的代码调 `open.call(fakeXhr, …)` 会直接抛 `TypeError`（WebIDL brand check，见 §3.8）。它的定位本就是**测试替身**，不追求抗检测 |
| fetch | **不覆盖**：在 `nise/lib` 里检索 `fetch` 只命中注释与测试用例，`fake-server` 不含 fetch 替身 → 只服务 XHR |
| 同步 XHR | fake XHR 的 `send()` 行为由 fake server 手工/延时触发，**不是同步语义**（对同步 XHR 场景不可用） |
| 要求的 world | 测试环境（jsdom/浏览器测试页）的全局作用域；不是生产注入方案 |

### 3.7 Tampermonkey 的 `unsafeWindow` 类做法

| 项 | 内容 |
|---|---|
| 出处 | Tampermonkey 文档（D）：<https://www.tampermonkey.net/documentation.php?q=sandbox>、<https://www.tampermonkey.net/documentation.php?q=unsafeWindow>；Violentmonkey 文档（D）：<https://violentmonkey.github.io/api/metadata-block/#inject-into> |
| 原理 | 用户脚本管理器替脚本决定"注入哪个 world"：Tampermonkey `@sandbox raw` 默认把脚本放进**页面上下文（MAIN_WORLD）**，此时 `unsafeWindow` 就是页面 `window`；`@sandbox JavaScript` 在 Firefox 上创建 `USERSCRIPT_WORLD`（绕过 CSP，但跨上下文传对象要 `cloneInto`/`exportFunction`）；`@sandbox DOM` 才进 ISOLATED world。Violentmonkey `@inject-into page` 同 MAIN world；`content` 模式官方明确"cannot access JavaScript objects of the web page"；`auto` 先试 page、被 CSP 拦则退化为 content |
| 与本项目的关系 | 这正是"扩展向页面注入 JS 层转发器"的成熟先例，且给出了**降级策略**：MAIN world 注入失败时退到 content 模式（但**代价是 JS 层劫持失效**）——与本项目 R5 的"只换装载方式、不换路径"不是一回事，需注意区分 |
| 抗检测性 | 与 §3.2–§3.5 相同：最终都是改全局；不同管理器只是把"包装痕迹"做得多少的区别。**本次未对 Tampermonkey 的注入包装做源码级核实（闭源）** → §9 |

### 3.8 `Response` / `XMLHttpRequest` 实例怎么伪造才不被识破

**(a) `fetch` 一侧：必须返回一个"真的 `Response`"**
- 可行的做法：`new Response(body, {status, statusText, headers})` 构造**真实的 `Response`**，再对少数只读字段用 `Object.defineProperty` 在**实例**上补 own property（`url` / `redirected` 等）。
- 依据（A，Fetch 规范 <https://fetch.spec.whatwg.org/>）：
  - `Response.url` getter："The url getter steps are to return the empty string if this's response's URL is null; otherwise this's response's URL, serialized …" → `new Response()` 的 `url` 必然是 `""`，与真实网络响应（等于请求 URL）不一致，**这是最容易暴露的一点**。
  - `Response.redirected`："return true if this's response's URL list's size is greater than 1; otherwise false" → 合成响应恒为 `false`。
  - `Response.type`："return this's response's type" → 合成响应的 type 为 `default`，而跨源 `fetch` 的真实响应是 `cors`/`opaque`，`no-cors` 请求更是只可能得到 `opaque`。
- IDL 属性是**原型上的访问器**、可配置：WebIDL 规范（A）规定 attribute 的 getter/setter 定义在 interface prototype object 上（"It is located on the interface prototype object …"），配置性为 `[[Configurable]]: true` → 因此**可以在实例上用 `defineProperty` 遮蔽**，也可以整体改 `Response.prototype`（后者全局可见、更易被检测）。
- 结论：**"用真 `Response` + 局部遮蔽只读字段"是抗检测性最好的路径**；纯对象伪装（`{ok:true, json(){…}}`）会在 `instanceof Response`、`Object.prototype.toString.call(r)`（`[object Response]`，由 `Symbol.toStringTag` 决定）、`r.headers` 等任何一处露馅。

**(b) `XMLHttpRequest` 一侧：纯 JS 对象无法通过 brand check**
- WebIDL 规范（A）：平台对象的方法/属性访问会先做 brand check —— "Let validThis be true if jsValue implements target, or false otherwise. If validThis is false … then throw a TypeError."（属性；操作同理）
- 推论（E，但为规范直接结果）：`XMLHttpRequest.prototype.open.call({}, …)` 会抛 `TypeError`（"Illegal invocation" 类错误）。所以**"把 `XMLHttpRequest.prototype` 挂到一个普通对象上"是行不通的**；必须持有一个**真实 XHR 实例**（`ajax-hook`、`xhook`、`@mswjs/interceptors` 全都持有真实实例；`nise` 的 `FakeXMLHttpRequest` 则放弃了这一性质）。
- 可以被伪造的：`readyState`、`status`、`statusText`、`response`、`responseText`、`responseURL`、`getAllResponseHeaders()`、事件对象 —— 但都要**依赖真实 XHR 的对象身份**做载体，否则 `instanceof` 与 brand check 两关过不去。
- 结论：**"不被识破"的上限是"看起来像真的"**，不是"真的是真的"。任何 hook 都留下至少一处：全局绑定 identity、`Function.prototype.toString`、属性描述符布局、事件时序。

**(c) 不可配置 / 只读属性的现实约束**
- 页面若在注入前已 `Object.defineProperty(window, 'fetch', {writable:false})`，或把 `XMLHttpRequest` 存进闭包变量，钩子就装不上（`xhook` README 已提示先加载）；`patchesRegistry` 遇到"不可配置且不可写"会直接抛错（C：`throw new Error('Failed to patch a non-configurable non-writable property …')`）。
- → 对本项目：**注入时机必须早**，且要接受"已捕获引用/已冻结全局"的页面拦不到（归入 §7 盲区）。

### 3.9 事件时序与同步 XHR

- **事件清单（A，XHR 规范 §3.7 Events summary）**：`readystatechange`（"readyState attribute changes value, except when it changes to UNSENT"）、`loadstart`、`progress`、`abort`、`error`、`load`、`timeout`、`loadend`。hook 实现必须**复刻这套顺序**，否则依赖 `readyState` 轮询或事件回调的页面代码会坏掉。
- **同步 XHR 的规范约束（A，XHR 规范）**：
  - `open()` 原文："Throws an `InvalidAccessError` DOMException if **async is false**, the current global object is a **Window** object, and the `timeout` attribute is not zero or the `responseType` attribute is not the empty string."
  - `timeout` setter 原文："If the current global object is a Window object and this's synchronous is true, then throw an `InvalidAccessError` DOMException."
  - 错误路径原文："If xhr's synchronous is true, then throw exception. Fire an event named readystatechange at xhr."（同步时**抛异常而不是派发 error 事件**）
  - **规范已宣判死刑**（A，同规范紧接 `open()` 的一段，逐字）：

    > "Synchronous XMLHttpRequest outside of workers is **in the process of being removed from the web platform** as it has detrimental effects to the end user's experience. (This is a long process that takes many years.) Developers must not pass false for the async argument when the current global object is a Window object."
  - → 对本项目：同步 XHR 的支持是"要不要兼容历史页面"的问题，**不是长期能力**；但若第一版要拦的页面里存在同步 XHR，hook 必须处理（否则会抛错/挂死），`xhook` 的做法可参考。
- **各库的同步支持**：`xhook` ✅（同步派发最终事件、跳过异步 hook）、`ajax-hook` ✅（同步入口）、`@mswjs/interceptors` ❌（显式 warn 后放行）、`nise` ❌（手工驱动语义）。
- **异步事件时序的可检测偏差**：`xhook` 把最终事件放进 `setTimeout(..., 0)`（宏任务），而原生 XHR 的事件也在任务队列里但**与网络完成时机绑定**；`ajax-hook` 在异步路径同样 `setTimeout(req)`。⇒ 页面可以用"`send()` 之后同一任务内是否已经 `readyState===1`"、`performance.now()` 差分等做粗筛（推断，E）。
- **`onprogress` / `onload` 的伪造**：需要 `ProgressEvent`（`lengthComputable/loaded/total`）；`lengthComputable` 与真实 `Content-Length` 不一致时容易被发现（推断，E）。本次**未找到官方文档对"如何伪造 XHR 事件"的权威说明**，故这一节的具体反检测清单属工程推断，见 §9。

### 3.10 页面检测自己被 hook 的常见手段与反制

> 证据分级：下面每条都标注了出处；**没有出处的"检测手段"一律标注为推断**，并在 §9 汇总。

| # | 检测手段 | 依据 | 可行的反制 | 反制的残留风险 |
|---|---|---|---|---|
| D1 | `window.fetch.toString()` / `window.XMLHttpRequest.toString()` 是否含 `[native code]` | MDN（A）：`Math.abs.toString()` → `"function abs() { [native code] }"` <https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Function/toString> | 改 `Function.prototype.toString` 返回伪造串 | 改 `Function.prototype.toString` 本身又是全局篡改；且 `Function.prototype.toString.call(f)` 仍可绕过（推断，E） |
| D2 | 保存原生构造器引用，做 identity 比较：`const X = XMLHttpRequest; … 后来 X !== window.XMLHttpRequest` | 由 §3.2–§3.5 的实现直接推出（都替换了全局绑定） | 无法真正规避；只能保证"注入足够早"，让页面拿到的就是我们的实现 | 一旦页面在注入前存了引用，或从 iframe 取原生 `XMLHttpRequest`，即可识破（**iframe 取原生构造器是强检测**，推断 E） |
| D3 | 属性描述符检查：`Object.getOwnPropertyDescriptor(window,'fetch')`、实例上的 own property 布局 | 由源码直接推出（`patchesRegistry` 用 `defineProperty`；`ajax-hook` 在实例上 `defineProperty`） | 让描述符尽量贴近原生（`configurable:true/enumerable:true/writable:true`） | 归一化描述符也无法消除 own-vs-prototype 的差别 |
| D4 | 抓 hook 库自己留下的标记属性 | 源码（C）：`ajax-hook` 把原生实例存在 **`__origin_xhr`**；`mswjs` 用 `Symbol.for('fetch-interceptor')` / `Symbol.for('xhr-interceptor')` 作为静态标记 | 换私有 `Symbol`（不带全局注册表）并在构造后删除自有标记 | 任何自有属性都可能被 `Object.getOwnPropertyNames` 枚举出来 |
| D5 | 在真实请求里做"网络层旁证"：页面自己发一个哨兵请求，看 `performance.getEntriesByType('resource')` 是否有对应条目/时长是否异常 | Performance Resource Timing 是浏览器侧独立记录（**本次未逐条验证与 hook 的交互**，属推断 E） | 无干净反制（这是"绕过 JS 层"的旁证） | 若页面用此手段，JS 层拦截会被发现（本项目需评估是否接受） |
| D6 | 时序指纹：`send()` 后同一任务内 `readyState` 是否变化、`load` 事件是否落在下一个宏任务、`performance.now()` 差分 | 由 `xhook`/`ajax-hook` 的 `setTimeout` 实现推出（C）；规范侧只规定事件语义、不规定任务划分（A，XHR 规范 §3.7） | 让 hook 在"同步可判定"的路径上保持同步、异步路径用微任务 | 与真实网络的天然抖动难以完全对齐（推断 E） |
| D7 | `instanceof` 与 `Symbol.toStringTag`：`new Response(...) instanceof Response`、`Object.prototype.toString.call(r)` | WebIDL（A）interface prototype chain；Fetch 规范（A）`Response` 的 `Symbol.toStringTag` | 用真 `Response`（§3.8a） | `Response.url === ""`、`type === 'default'` 等仍可能暴露 |
| D8 | 直接调用原生原型方法：`原始XMLHttpRequest.prototype.open.call(obj, …)` 是否抛 `TypeError` | WebIDL（A）brand check | 只能持有真实例；JS 伪对象无解 | 这是**硬边界**，不是可规避项 |
| D9 | 检查 `navigator.webdriver`、DevTools 打开状态、`console` 行为等环境指纹 | **未在文档中找到可靠依据** | — | 归入 §9 |

**总体判断**：JS 层 hook 的"抗检测"没有终点，只有"成本高低"。对本项目（Q-D1 只拦一条精准 URL）而言，**被检测的风险面主要落在"我们注入到的任意页面"上**（概念设计 §6 也接受了这一点）；如果只拦 `localhost:6800`，绝大多数页面不会去检查自己被 hook。

### 3.11 要求的 world：MAIN vs ISOLATED

| 库 / 做法 | 必须的 world | 原因（出处） |
|---|---|---|
| `ajax-hook` / `xhook` / `fetch-intercept` / `@mswjs/interceptors` | **MAIN world** | 它们替换的是页面 `window` 上的 `fetch`/`XMLHttpRequest`；ISOLATED world 有独立的全局对象（A，content scripts 文档："none of these (web page, content scripts, and any running extensions) can access the context and variables of the others"） |
| Tampermonkey `@sandbox raw`（默认）/ Violentmonkey `@inject-into page` | **页面上下文（MAIN）** | 官方文档明确"`raw` … always needs to run in page context, the `MAIN_WORLD`"；VM：`page` = "Inject into context of the web page … allowing the script to access JavaScript objects of the web page" |
| Tampermonkey `@sandbox DOM` / Violentmonkey `@inject-into content` | ISOLATED | 官方文档：content 模式"cannot access JavaScript objects of the web page" → 只能改 DOM |
| 扩展自己的 content script（`"world": "ISOLATED"`，默认） | ISOLATED | 默认值即 `"ISOLATED"`（A，manifest `content_scripts` 文档）；此时**拦不到页面的任何请求** |
| `nise` / `sinon` fake server | 测试环境全局（与生产注入无关） | 源码：直接替换 `globalScope.XMLHttpRequest` |

**风险与代价（MAIN world）**：页面可读可改我们的代码（A：manifest 文档 WARNING）、受页面 CSP 约束（A：content scripts 文档）、并且**注入失败时无法通过"换 world"补救**（换 ISOLATED 就等于放弃 JS 层拦截）。这正是概念设计 R5 里"扩展页可能注入不进去时只换装载方式"要面对的同一个问题。

---

## 4 第三问：能否拦截或修改「其它扩展」的网络请求

> 本节的结论**逐条给证据**，每条明确标注 **能 / 不能 / 有条件**。调研日期 2026-10-06，基线为 Chromium `main` 分支源码。

### 4.1 content script 能不能注入到 `chrome-extension://` 页面？

- **注入到"别人家"的扩展页面：不能。**
  - 证据一（B）：content script 的 match pattern 走 `UserScript::ValidUserScriptSchemes()`，其允许的 scheme 为

    ```cpp
    kValidUserScriptSchemes = URLPattern::SCHEME_CHROMEUI |
                              URLPattern::SCHEME_HTTP | URLPattern::SCHEME_HTTPS |
                              URLPattern::SCHEME_FILE | URLPattern::SCHEME_FTP |
                              URLPattern::SCHEME_UUID_IN_PACKAGE
    ```
    —— **不含 `URLPattern::SCHEME_EXTENSION`**。`chrome-extension://` 无法作为 content script 的 `matches`。
    <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/user_script.cc>
  - 证据二（A，match patterns 文档）："**scheme**: Must be one of the following … `http` / `https` / 通配 `*`（只匹配 http/https）/ `file`"。<https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns>
  - 证据三（B）：即使某条路径允许访问扩展 URL，也有命令行开关门槛 —— `switches::AreExtensionsOnExtensionURLsAllowed()`（开关 `--extensions-on-extension-urls`，向后兼容 `--extensions-on-chrome-urls`），见 `extensions/common/switches.cc`。
- **注入到"自己家"的扩展页面：能（但不是靠 content script）。**
  - 自己的页面直接 `<script src="...">` 引入同一份转发器代码即可（这正是概念设计 R5 的"只换装载方式，不换路径"）。
  - 权限侧依据（B）：`GetHostAccessForURL()` 对 `url::IsSameOriginWith(url, extension.url())` 直接返回 `kAllowed`（`extensions/browser/api/web_request/web_request_permissions.cc`）→ 扩展对自己页面永远有访问权。
- **附带结论：即使注入进去，也拦不到别人的 JS 调用。** 别的扩展的脚本跑在它自己的 ISOLATED world 里（A，content scripts 文档："an isolated world is a private execution environment that isn't accessible to the page or other extensions"），我们的 MAIN-world hook 与它互不可见。

### 4.2 `chrome.webRequest` 能不能看到并改写"由其它扩展发起"的请求？

- **看到：不能。**（MV2 也一样，与版本无关）
  - 证据（B）：`WebRequestEventRouter::ListenerMatchesRequest()`：

    ```cpp
    // Filter requests from other extensions / apps. This does not work for
    // content scripts, or extension pages in non-extension processes.
    if (is_request_from_extension &&
        listener.id.render_process_id != request.global_id.child_id) {
      return false;
    }
    ```
    → 我们的监听器**只匹配自己进程发起的请求**；别的扩展（扩展页面 / Service Worker 所在的扩展进程）发起的请求不会派发给我们。
    <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/browser/api/web_request/extension_web_request_event_router.cc>
  - 源码注释同时点明了**例外**："This does not work for content scripts, or extension pages in non-extension processes." → **其它扩展的 content script** 发出的请求（跑在页面的渲染进程里）**不属于**该过滤条件，理论上可进入权限检查。
  - **`initiator` 字段取值（官方文档，A）**：`onBeforeRequest` 等事件的 `details.initiator`（Chrome 63+）原文是 —— "The origin where the request was initiated. This does not change through redirects. **If this is an opaque origin, the string 'null' will be used.**"
    - 对本问的含义：来自**扩展页面 / 扩展 Service Worker** 的请求，initiator 是 `chrome-extension://<该扩展ID>`；来自**别的扩展的 content script** 的请求，initiator 取值本次未能确证（Chromium 源码注释确认它不受进程过滤，但未回答 initiator 是页面 origin 还是扩展 origin）→ 见 §9 U5。
    - DNR 侧的对应实现用的是 `request.initiator->GetTupleOrPrecursorTupleIfOpaque()`，源码注释专门解释"requests initiated by manifest sandbox pages have an opaque initiator origin, but still originate from an extension"（即 opaque 的时候要看 precursor）—— 这是"沙箱页也不能用来绕过"的证据。
- **改写：不能（且 MV3 下连"阻止"都不行）。**
  - MV3 没有 `webRequestBlocking`（A，§2.1）；即便 MV2 或策略安装扩展，改写还要过 §4.2 的可见性关。
  - 权限关（A + B）："an extension will be able to intercept a request only if it has host permissions to both the requested URL **and the request initiator**"（A）；代码侧 `CanExtensionAccessURLInternal()` 对子资源请求走 `REQUIRE_HOST_PERMISSION_FOR_URL_AND_INITIATOR`，最终返回 `GetHostAccessForURL(*extension, initiator->GetURL(), tab_id)`（B，`web_request_permissions.cc`）。而 host permission 的合法 scheme **不含 `chrome-extension`**：

    ```cpp
    const int Extension::kValidHostPermissionSchemes =
        URLPattern::SCHEME_CHROMEUI | URLPattern::SCHEME_HTTP | URLPattern::SCHEME_HTTPS |
        URLPattern::SCHEME_FILE | URLPattern::SCHEME_FTP | URLPattern::SCHEME_WS |
        URLPattern::SCHEME_WSS | URLPattern::SCHEME_UUID_IN_PACKAGE;
    ```
    （`extensions/common/extension.cc`）→ **无法对 `chrome-extension://<别人的ID>/` 取得 host permission**，因此 initiator 检查必然失败。
  - 另外（A）：`chrome-extension://other_extension_id` 这类 URL 本身就被列为"hidden requests"。
- **结论**：webRequest 对"别的扩展（扩展页面/SW）发起的请求"是 **不能**；对"别的扩展的 content script 发起的请求"是 **有条件**（可能过得了进程过滤，但取决于其请求的 initiator 取值与我们的 host permission —— 见 §4.6 与 §9 的未验证项）。

### 4.3 `declarativeNetRequest` 能不能看到并改写"由其它扩展发起"的请求？

- **不能（整体跳过 ruleset）。**
  - 证据（B）：`RulesetManager::ShouldEvaluateRulesetForRequest()`：

    ```cpp
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
    <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/browser/api/declarative_net_request/ruleset_manager.cc>
    → 别的扩展发出的**非主框架请求**（`fetch`/XHR 就是这一类），我们的 DNR ruleset **根本不被求值**，无论规则内容是什么。
  - **注意例外**：注释里点明是 "non-main-frame requests"，即 **`main_frame` 导航**仍会被求值；另外 `--extensions-on-extension-urls` / `--extensions-on-chrome-urls` 命令行开关可解除该限制。
- **`chrome-extension://` 作为"目标 URL"：不能。**
  - 证据（B）：`RulesetManager::ShouldEvaluateRequest()`：

    ```cpp
    // Prevent extensions from modifying any resources on the chrome-extension
    // scheme. Practically, this has the effect of not allowing an extension to
    // modify its own resources (The extension wouldn't have the permission to
    // other extension origins anyway).
    if (request.url.SchemeIs(kExtensionScheme)) {
      return false;
    }
    ```
- **`initiatorDomains` 能不能写扩展 ID？**
  - 文档只承诺"domain"语义（A）："The rule will only match network requests originating from the list of `initiatorDomains` … This matches against the request initiator and not the request url. Sub-domains of the listed domains are also matched."
  - 由于 §4.3 第一条的**求值层跳过**，写不写扩展 ID 都不影响结论：**对其它扩展的 fetch/XHR 无效**。至于"扩展 ID 是否会被当作 domain 匹配"（`chrome-extension://<id>` 的 host 就是 ID）—— **本次未找到官方说明，记入 §9**。
- **`urlFilter` / `regexFilter` 能不能匹配 `chrome-extension://` 这种 scheme？**
  - 匹配语义上它们是"对 URL 字符串做过滤/正则"，看起来能写；但 §4.3 第二条（`ShouldEvaluateRequest` 对 extension scheme 直接 `return false`）决定了**任何规则都不会作用在 `chrome-extension:` URL 上**。→ **不能**（就"作用"而言）。
- **能力侧再确认**：即便这一切都放行，DNR 也**无法合成响应体**（§2.3），所以对"接住请求并给出 aria2 的 JSON-RPC 响应"这一目标从一开始就不成立。

### 4.4 `chrome.debugger` 能不能附加到"恰好在一个标签页里打开的"其它扩展页面？

- **不能（默认）。** 三条独立证据：
  1. 目标 URL 是别的扩展的 `chrome-extension://` URL 时被拒（B，`debugger_api.cc`）：

     ```cpp
     bool allow_on_extension_urls = ::extensions::switches::AreExtensionsOnExtensionURLsAllowed();
     if (url_for_restriction_check.SchemeIs(extensions::kExtensionScheme) &&
         url_for_restriction_check.host() != extension.id() &&
         !allow_on_extension_urls) {
       *error = manifest_errors::kCannotAccessExtensionUrl;
       return false;
     }
     ```
     该函数同时用于 `tabId` 附加（经 `ExtensionMayAttachToWebContents()` 取标签页 committed URL）、`targetId` 附加、以及**非 WebContents 目标（如 Service Worker）**（`ExtensionMayAttachToAgentHost()` 里对非 WebContents 目标同样调用 `ExtensionMayAttachToURL(agent_host.GetURL())`）。
     <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/extensions/api/debugger/debugger_api.cc>
  2. 用 `extensionId` 直接附加到扩展后台页：A 级文档明确"Attaching to an extension background page is only possible when the `--silent-debugger-extension-api` command-line switch is used."（`Debuggee.extensionId` 词条）
  3. 浏览器级 target（`targetId: "browser"`）只对白名单扩展开放（B）：`else if (*debuggee_.target_id == kBrowserTargetId && ExtensionIsTrusted(*extension()))`，而 `ExtensionIsTrusted()` 只认 Perfetto UI 扩展 ID（`extension_misc::kPerfettoUIExtensionId`）。→ 我们**不能**用"附加浏览器 target 再 `Target.setAutoAttach` 到别人 SW"这条路绕开。
- **"有条件"的部分**：若用户以 `--extensions-on-extension-urls`（或旧名 `--extensions-on-chrome-urls`）启动浏览器，`ExtensionMayAttachToURL` 的条件被解除，则**技术上可以**附加到别的扩展页面/Worker；再叠上 `--silent-debugger-extension-api` 还能直接按 `extensionId` 附加。**但这是命令行开关，不是产品可依赖的部署方式。**

### 4.5 有没有别的 API 或机制能做到？

| 机制 | 结论 | 依据 / 理由 |
|---|---|---|
| `chrome.proxy` + PAC | 不能（合成响应） | PAC 只负责"选哪个代理"，返回的是代理地址或 `DIRECT`；无法在浏览器内凭空回答请求。且本项目 R8 明确"无法监听端口"，本地也没有可做代理的进程（A：`chrome.proxy` 文档语义；**本次未逐条抓取 `chrome.proxy` 文档**，结论标为推断 → §9） |
| `chrome.webNavigation` | 不能 | 纯导航事件（onBeforeNavigate/onCommitted…），无请求改写能力（A，API 定位） |
| `chrome.devtools.network` / `devtools.inspectedWindow` | 不能（且场景不成立） | 只在 devtools 页面里可用，用户必须自己打开 DevTools；`devtools.network` 用于读 HAR，不提供"回答请求"的能力（**未逐条取证** → §9） |
| `chrome.runtime.onMessageExternal` / `externally_connectable` | 有条件（要求对方配合） | 只能让**对方扩展主动连我们**；不是"拦截"（A，messaging 文档语义） |
| `chrome.management` | 不能 | 只能枚举/启停扩展，与网络无关 |
| Native messaging / 本地代理 | 出界 | 需要本机安装原生程序，R1"免安装"直接否决 |
| Firefox `webRequest.filterResponseData` | 有条件 | 能改响应体（A），但"别的扩展发起的请求"在 Firefox 侧同样有 initiator/host 权限约束，**本次未验证** → §9 |
| Service Worker 拦截 | 不能 | SW 只能拦截**自己 scope 内**的请求；我们无法在 `localhost:6800` 上注册 SW（没有服务器提供脚本） |

### 4.6 动机结论：能不能让第三方 aria2 前端扩展发出的请求被我们接住？

**默认：不能。** 把前几节的结论按"该扩展可能怎么发请求"分情况：

| 情形 | 我们能否接住 | 依据 |
|---|---|---|
| A. 第三方扩展在**扩展页面 / Service Worker / 后台页**里 `fetch('http://localhost:6800/jsonrpc')` | ❌ **不能** | webRequest 事件被 `ListenerMatchesRequest` 过滤（§4.2）；DNR ruleset 被跳过（§4.3）；JS 层 hook 到不了它的 realm（§4.1）；debugger 附加上别的扩展页面被拒（§4.4） |
| B. 第三方扩展在**它自己的 content script（ISOLATED world）**里发请求 | ❌ **不能（JS 层）**；网络层**有条件**但无用 | JS 层：realm 隔离（§4.1）；网络层：它跑在页面渲染进程，可能绕过进程过滤，但我们既不能用 MV3 改写（§2.2），DNR 也不能合成响应体（§2.3）——**最多只能"看到/阻断"，无法"接住并回答"** |
| C. 第三方扩展把请求逻辑注入**页面的 MAIN world**（例如注入一段页面脚本去做 RPC） | ✅ **能**（我们的 MAIN-world hook 与它同 realm） | §3.11：hook 生效的前提就是同 realm；这也是唯一在"不依赖对方配合"的情况下能接住的形态 |
| D. 第三方扩展主动与我们集成（消息、`externally_connectable`、改用我们的 URL） | ✅ 能，但不是"拦截" | §4.5 表；属于协作，不是本问题的答案 |

**对产品的直接含义**：想"不打包自己的 AriaNg UI 而直接吃第三方 aria2 前端扩展"，**默认路径不存在**。可选的三条路都不理想：①自己打包 UI（概念设计 R4.2/R5 已选）；②寄望第三方扩展在页面 MAIN world 发请求（不可控、且它连的还是 `localhost:6800`，需要它的请求确实经过页面 realm）；③要求用户带命令行开关启动浏览器（不可接受）。
**唯一稳妥的替代**：让第三方前端**跑在普通网页里**（例如浏览器里打开 AriaNg 的网页版），由我们的 MAIN-world 转发器接住 —— 这正好是概念设计 §3 的"第一层用户入口"设计（用户配置一条精准 URL，页面里的 `fetch`/XHR 被就地短路）。第三方**扩展**形态则不在可行范围内。

---

## 5 硬约束（逐条给证据）

> 只列对本项目有直接约束力的条目。每条给"约束 → 证据"。

| # | 硬约束 | 证据 |
|---|---|---|
| C1 | MV2 阻塞式 webRequest 已无平台支持（Chrome 139 起 MV2 失效；2026-08-31 起 CWS 无 MV2），只有企业策略安装的扩展例外 | A：`webRequest` 文档；A：MV2 退役时间线 |
| C2 | MV3 下 webRequest 只能观测，不能阻断/改写（除非策略安装） | A：`webRequestBlocking` 权限说明 |
| C3 | DNR 无法合成响应体（没有任何 action 携带 body） | A：`RuleActionType` 枚举 / `RuleAction` 字段；D：Requestly 官方对照表 |
| C4 | DNR 规则对"其它扩展发起的非主框架请求"整体不求值；对 `chrome-extension:` 目标 URL 一律不求值 | B：`ruleset_manager.cc` 的 `ShouldEvaluateRulesetForRequest` / `ShouldEvaluateRequest` |
| C5 | webRequest 监听器不匹配其它扩展进程发出的请求 | B：`extension_web_request_event_router.cc` 的 `ListenerMatchesRequest` |
| C6 | host permission 无法覆盖 `chrome-extension://` scheme（`kValidHostPermissionSchemes` 不含 `SCHEME_EXTENSION`） | B：`extensions/common/extension.cc`；A：match patterns 文档的 scheme 清单 |
| C7 | content script 的 match pattern 无法覆盖 `chrome-extension://` scheme | B：`extensions/common/user_script.cc` 的 `kValidUserScriptSchemes` |
| C8 | 访问别的扩展的 URL（附加调试器、跑脚本）需要命令行开关 `--extensions-on-extension-urls`（旧名 `--extensions-on-chrome-urls`）；`extensionId` 调试目标还需 `--silent-debugger-extension-api` | B：`debugger_api.cc`、`extensions/common/switches.cc`；A：`chrome.debugger` 文档 |
| C9 | `chrome.debugger` 附加对普通安装扩展**必然**弹出"started debugging this browser"信息条（只有策略安装或 `--silent-debugger-extension-api` 才抑制）；且与 DevTools 互斥、同一目标只能有一个调试器、企业策略可阻止 | B：`debugger_api.cc`（`suppress_warning` 分支）+ `generated_resources.grd`；A：`onDetach` 说明、企业策略小节；B：`kAlreadyAttachedError` |
| C10 | `chrome.debugger` 的 CDP 域名受限（白名单制），`Fetch` 在名单内 | A：`debugger` 文档 "Restricted domains" |
| C11 | 浏览器级调试 target 只对 Perfetto UI 扩展开放 | B：`debugger_api.cc`（`kBrowserTargetId` + `ExtensionIsTrusted`） |
| C12 | MAIN world 的注入脚本受页面 CSP 约束，且对页面完全可见、可被页面干扰 | A：content scripts 文档（CSP 段、manifest 警告） |
| C13 | realm 隔离：MAIN world 的 hook 对任何 ISOLATED world（含其它扩展的 content script）不可见 | A：content scripts 文档 "Work in isolated worlds" |
| C14 | `XMLHttpRequest` 的纯 JS 伪对象无法通过 WebIDL brand check（`TypeError`），因此 hook 必须持有真 XHR 实例 | A：WebIDL 规范（attributes/operations 的 validThis 检查）；C：五个库的实现策略 |
| C15 | 命中前的可见性黑洞：内存缓存命中的请求对 webRequest 不可见 | A：`webRequest` 文档 "Caching" 小节 |
| C16 | 被 DNR/扩展 redirect 到的资源必须 `web_accessible`，否则报错 | A：DNR 文档实现细节小节 |
| C17 | 同步 XHR 在 Window 上有规范级限制（`timeout` 非零抛 `InvalidAccessError`；同步错误路径抛异常而非派发事件） | A：XHR 规范 |

---

## 6 对本项目的可用性判断

### 6.1 三条候选路线

| 路线 | 与 R9 的关系 | 可行性 | 结论 |
|---|---|---|---|
| **JS API 层 MAIN-world 改写**（`fetch`/`XMLHttpRequest` 包装；`WebSocket` 未调研） | **就是 R9 的定义**（"命中后请求根本不发到网络"） | 高：无额外权限、无用户可见成本、可合成任意响应体、可动态（按请求体生成） | ✅ **主路径**。约束：注入时机要早、只在 MAIN world 生效、页面可检测/可破坏、Worker 与受限页面是盲区 |
| **DNR 网络层重定向** | R9 明确说"与用 DNR 重定向不是同一条路：DNR 走网络层，拿不到返回任意响应体的能力" | 低：**无法合成响应体**（C3），且对 `chrome-extension:` 与其它扩展请求无效（C4） | ❌ 只能做**辅助**（如附录 A 那种"给真实下载请求注入 header / 强制 Content-Disposition"），不能做转发器主干 |
| **chrome.debugger + CDP Fetch** | 语义上最接近"服务端"：可 fulfil 任意响应体、可拦到页面全部网络途径 | 中：技术上可行（Tamper Dev 已证），但**用户可见成本**（信息条、与 DevTools 互斥、单调试器、企业策略） | ⚠️ **不建议做默认路径**；可考虑作为"高保真可选模式"（未在概念设计中出现，属新增议题，需用户裁定） |

### 6.2 对 R4.1「尽可能多地拦截各种途径 / 各种来源」的落地判断

- **途径**：
  - `fetch`、`XMLHttpRequest` → 有成熟做法可直接照抄思路（§3.2–§3.5），核心是替换全局 + 早注入。
  - `WebSocket` → **本次未调研 WebSocket 的劫持现状**（本任务三问未要求），但已确认：DNR/webRequest 只能看到握手请求，看不到握手之后的帧（A：`webRequest` 文档 "the API does **not intercept** individual messages sent over an established WebSocket connection"）。→ 若第一版要实现 Q-D3 的 WS 通道，JS 层替换 `window.WebSocket` 看起来是唯一方向（**未调研，属推断**）；其可行性归入后续能力清单，**本文件不下结论**。
  - 其它 JS API（`sendBeacon`、`EventSource`）→ 未调研。
- **来源**：
  - 普通标签页（MAIN world）→ 可覆盖（内容脚本 `world: "MAIN"`）。
  - 跨源 iframe → 需 `all_frames` + match pattern 覆盖其 URL；跨源 iframe 的 realm 独立，注入需要匹配（A：content scripts 文档）。
  - Worker → realm 独立，**默认拦不到**（§2.5 第 5 条）；xhook 支持 Worker 全局（C），但"扩展如何把脚本送进页面的 Worker"未验证（§9）。
  - 其它扩展 → **拦不到**（§4）；`chrome://`、PDF viewer、view-source、商店页 → 拦不到（概念设计 §6 第 4 条已接受）。
- **结论**：R4.1 的"尽可能多"在**普通页面 + JS API 层**这个组合上是可以兑现的；跨 realm（Worker/其它扩展/受限页面）必须按 Q-D2 明确列为盲区。

### 6.3 对 R5「内置 UI 不得走特殊通道」的判断

- 内置 AriaNg UI 若作为**扩展页面**打开：它是 `chrome-extension://<我方ID>/...`，是**我们自己的**同源页面（§4.1）→ 没有被"内容脚本注入"的必要，直接在该页面里 `<script>` 引入同一份转发器代码即可。这与 R5 的例外条款一致：**"只换装载方式，不换路径"** —— 路径仍是"MAIN world 里的 JS API 劫持"，只是装载方式从"内容脚本注入"变成"页面自己引脚本"。
- **但要注意一个真实存在的不对称**：普通网页里，转发器由 content script 注入 MAIN world；扩展页面里，如果也想走"注入"，会在 CSP/`document_start` 时机上与普通页面不同（A：MAIN world 受页面 CSP 约束）。因此**必须保证同一份逻辑在两种装载方式下行为一致**（R5 的实质要求），否则就是"特殊通道"。
- 另一个必须显式处理的问题：**扩展页面里 `chrome-extension://` 的 `fetch` 与普通页面的 `fetch` 行为不同**（例如扩展页面对 host permission 内的目标有跨源特权）。这属于"路径之外的差异"，建议在详细设计阶段单独裁定（本文件只指出风险）。

### 6.4 对第三问动机（第三方 aria2 前端扩展）的最终建议

按 §4.6，结论是**放弃"拦截第三方扩展"这条路**，回到 R4.2（自己打包 UI）+ 用户自带的**网页版**前端。若未来用户仍希望支持第三方扩展，唯一可行方向是"**让对方把 RPC 调用放进页面 MAIN world**"或"**对方主动集成**"，两者都需要对方配合，不能作为设计前提。

---

## 7 失败模式与盲区

**（A）JS 层转发器（主路径）**

| # | 失败模式 | 机制 | 后果 | 缓解（若可行） |
|---|---|---|---|---|
| F1 | 注入时机晚于页面首次取用 `fetch`/`XMLHttpRequest` | 页面可能已把原生引用存进变量（`xhook` README 明确提示） | 该页面的 RPC 请求不会被拦 | `document_start` + 同步注入；接受残余风险（Q-D1 只拦一条 URL） |
| F2 | 全局被页面冻结/不可配置 | `defineProperty(writable:false)` 等 | 钩子装不上（`patchesRegistry` 直接抛错） | 无干净解；列入盲区清单 |
| F3 | MAIN world 注入被页面 CSP 阻止 | A：MAIN world 受页面 CSP 约束 | 转发器不生效 | 无（换 ISOLATED 等于放弃 JS 层拦截）——须告知用户 |
| F4 | 页面检测并还原 hook（D1–D8） | 任何一处指纹暴露 | 功能被绕过 | 只降低概率；不建议做"越权对抗" |
| F5 | 请求走 Worker / Service Worker | realm 独立 | 拦不到 | 列入盲区 |
| F6 | 请求不是 JS API 发起（`<img>`、`<script>`、表单导航、`sendBeacon`） | 不在 JS API 层 | 拦不到 | 列入盲区（与 R9 的自洽性：R9 只承诺 JS API 层） |
| F7 | 命中规则配置错误导致误拦（Q-A3：一律拦截） | 用户配置即放弃该地址真实连通性 | 该地址真实服务不可用 | 概念设计 §6 第 2 条已接受 |
| F8 | 多扩展同时 hook 同一全局 | 后注入者覆盖先注入者（`webRequest` 冲突解决是"最近安装者获胜"，JS 层更粗暴：直接覆盖） | 功能互踩 | 明确不支持；须在文档中声明 |
| F9 | 同步 XHR 路径 | 事件语义特殊（抛异常而非事件） | 若处理不当会破坏页面 | 参考 `xhook` 的同步分支实现（C） |

**（B）网络层途径**

| # | 失败模式 | 机制 | 后果 |
|---|---|---|---|
| F10 | 用 DNR 试图"返回响应体" | DNR 无此能力（C3） | 直接不可行 |
| F11 | DNR/webRequest 受缓存黑洞影响 | 内存缓存命中的请求对 webRequest 不可见（C15） | 规则行为"看起来偶发失效" |
| F12 | 内存缓存 / `handlerBehaviorChanged()` 时机 | A：`webRequest` 文档 "Caching" | 规则变更后需刷新，行为不一致 |
| F13 | chrome.debugger 被 DevTools/别的扩展抢占 | 单一调试器（C9） | 拦截中断，需重连与降级 |

**（C）第三问相关盲区**
- 第三方扩展（任何发请求形态）→ 见 §4.6。
- `chrome://`、Chrome Web Store、PDF viewer、view-source → 注入与调试均受限（概念设计 §6 第 4 条已列）。

---

## 8 与现有裁定的冲突（尤其 R9 与 R5）

**R9（"拦截发生在 JS API 层，命中后请求根本不发到网络"）**

- **不冲突**：本文件的主路径结论（§6.1）与 R9 完全同向 —— JS API 层短路是唯一能"任意合成响应体 + 无用户可见成本"的方案。
- **需要澄清的一点**：R9 的第二句"与'用 DNR 重定向'不是同一条路：DNR 走网络层，拿不到返回任意响应体的能力"，在事实层面**成立且已由源码/文档证实**（§2.3、C3）。但 §2.1 显示 **MV2 阻塞式 webRequest 曾经可以**用 `data:` 重定向合成响应体 —— 这不构成对 R9 的反例（MV2 已死，且那条路仍是网络层、无法动态按请求体生成），但**建议在文档里把"技术上曾有第三条路（MV2 `data:` 重定向）"记一笔**，以免未来有人拿旧资料质疑 R9。
- **潜在冲突（需用户裁定的新议题）**：本文件发现 `chrome.debugger` + CDP `Fetch.fulfillRequest` **能**在网络层"凭空回答"任意请求（含响应体），即 R9 里"拿不到返回任意响应体"这句话在**调试层**不成立。R9 的表述若被理解为"只有 JS API 层能拿到任意响应体"，需要修订为"**常规扩展 API** 层面只有 JS API 层能拿到任意响应体；调试协议层可以，但代价不可接受（§2.4）"。

**R5（内置 UI 不得走特殊通道）**

- **不直接冲突**：扩展自有的 `chrome-extension://` 页面天然属于"自己家"（§4.1），页内直接引脚本是"换装载方式，不换路径"，符合 R5 的例外条款。
- **需要注意的实质风险**：
  1. 扩展页面里 `fetch` 的跨源行为与普通页面不同（扩展页面对 host permission 覆盖的目标是特权请求）→ 若转发器依赖"页面 fetch 会被 CORS 拦"之类的假设，两种装载方式下的可观测行为会不一致。**建议在详细设计里显式验证"命中/未命中"两条路径在两种装载方式下的表现完全一致。**
  2. 扩展页面自身的 CSP 与普通页面不同：官方文档在讲 ISOLATED world 的 CSP 时说明了扩展上下文的共性 —— "Similar to the restrictions applied to **other extension contexts**, this prevents the use of `eval()` as well as loading external scripts."（A）→ 若转发器自身依赖 `eval`/`new Function`/外部脚本加载，**两种装载方式都受限，且受限方式不同**，需在详细设计里分别验证。
- **与 Q-D1 的交互**：只拦一条精准匹配 URL，意味着"扩展页面里跑 AriaNg"与"普通页面里跑 AriaNg"都要能命中同一条规则；**普通页面版还需要用户把该 URL 加进我们的匹配配置**（Q-D1 的模型不变）。

**其它可能被波及的裁定**
- Q-D2（拦截盲区必须列明）：本文件的 F1–F6、§4 的全部"不能"条目，都应进入"拦截盲区清单"。
- §6 第 4 条（已接受风险）中的"扩展页 CSP"一条，本次得到官方文档支持（MAIN world 受页面 CSP 约束），表述可保留但建议改为更精确的"MAIN world 注入受页面 CSP 约束"。

---

## 9 未验证 / 存疑

> 以下条目**没有取得足够证据**，不得在下游文档中被当作结论使用。

| # | 事项 | 现状 |
|---|---|---|
| U1 | **ModHeader 用了什么 API** | 官网跳转到 `app.modheader.com`；CWS 页面为 JS 渲染抓不到文本；CRX 下载在本环境被 TLS 拒；chrome-stats 被 Cloudflare 403。**完全未验证** |
| U2 | **Requestly 扩展的 manifest / 具体 API** | GitHub 主仓默认分支已不含 `browser-extension` 目录（sparse clone 后为空）；仅取到官方文档的能力对照表（D）。其扩展**如何**实现 Response Rule（debugger？webRequest？）未验证 |
| U3 | **DNR 的 `redirect` 是否接受 `data:` URL** | 源码只显式拒绝 `javascript:`；文档未承诺 `data:`。是否真被网络栈接受、语义为何，**未验证** |
| U4 | **DNR `initiatorDomains` 能否匹配扩展 ID** | 因 ruleset 对其它扩展请求整体跳过（§4.3），此问题在当前约束下无实际意义；扩展 ID 是否被视作 domain **未验证** |
| U5 | **其它扩展的 content script 发出的请求，其 `initiator` 取值是什么** | 这决定了 `REQUIRE_HOST_PERMISSION_FOR_URL_AND_INITIATOR` 是否放行（§4.2 的"有条件"分支）。源码注释确认了内容脚本不受进程过滤，但 initiator 的取值未在本次调研中确证 |
| U6 | **扩展能否把脚本注入页面的 Web Worker / Service Worker** | 各库支持 Worker 全局（xhook），但扩展侧的注入通路未验证 |
| U7 | **`WebSocket` 的 JS 层劫持现状与约束** | 本任务三问未覆盖；本次只确认"webRequest 拦不到握手后的帧"（A） |
| U8 | **Tampermonkey 的注入包装细节（源码级）** | 闭源；只采信官方文档的 world 说明 |
| U9 | **`chrome.proxy` / `chrome.devtools.*` / `chrome.webNavigation` 的能力边界** | 本文件按 API 定位给出"不能"的判断，**未逐条抓取官方文档原文**，标记为推断 |
| U10 | **Firefox 侧"其它扩展请求"的可拦截性** | 未验证；Firefox 保留 `webRequestBlocking` 与 `filterResponseData`（A，MDN），但跨扩展可见性未查 |
| U11 | **各 hook 库的事件时序与原生 XHR 的差异清单** | 本次只从源码读到 `setTimeout`/同步分支，未做实测（无浏览器环境）。§3.9 的部分表述属推断 |
| U12 | **检测手段 D5（Resource Timing 旁证）、D9（环境指纹）** | 无文档依据，属工程推断 |
| U13 | **`Response` 只读字段在实例上 `defineProperty` 遮蔽的跨浏览器一致性** | 规范允许（原型访问器、configurable），但 Chrome/Firefox/Safari 的实际可写性未逐一验证 |
| U14 | **当前 Chrome 稳定版号与本文所述里程碑的对应关系** | 未核对"今天的稳定版是几"；结论只依赖里程碑本身（138/139） |
| U15 | **`chrome.scripting.executeScript` 注入到"自己家扩展页面"是否在 MV3 下无条件允许** | 权限侧同源允许（B），但 scripting API 的具体门禁（activeTab/host permission）未逐条验证 |
| U16 | **Redirector / Resource Override / Tamper Dev 在当前 Chrome Web Store 的实际形态** | 本文件引用的都是其**开源仓库 master 分支**（Redirector、Resource Override 为 MV2；Tamper Dev v2 为 MV2）。它们在商店里的当前版本/是否仍在架**未验证** |
| U17 | **MV3 观测型 webRequest 对 Worker 内请求、`chrome://` 页面、PDF viewer 的可见性** | 文档只给了 scheme 清单与"某些请求被隐藏"的定性说明，未逐条验证（§2.2 结尾的保留项） |

---

## 10 证据清单

### 10.1 官方文档 / 规范

| 证据 | URL | 关键原文（摘） | 等级 |
|---|---|---|---|
| Chrome `webRequest` API | <https://developer.chrome.com/docs/extensions/reference/api/webRequest> | "As of Manifest V3, the `webRequestBlocking` permission is no longer available for most extensions."；"`webRequestBlocking` … only available to policy installed extensions."；"only the following schemes are accessible: http, https, ftp, file, ws, wss, urn, chrome-extension … `chrome-extension://other_extension_id` … are hidden"；"an extension will be able to intercept a request only if it has host permissions to both the requested URL and the request initiator"；"Redirections to non-HTTP schemes such as `data:` are allowed."；"Requests that are answered from the in-memory cache are invisible to the web request API." | A |
| Chrome MV2 退役时间线 | <https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline> | "Aug 31st 2026: All remaining Manifest V2 extensions removed from the Chrome Web Store."；"Manifest V2 extensions will cease to function for any user upgrading to Chrome 139." | A |
| MV2 → DNR 迁移指南 | <https://developer.chrome.com/docs/extensions/develop/migrate/blocking-web-requests> | "redirecting also requires the `declarativeNetRequestWithHostAccess` permission in addition to the host permission." | A |
| Chrome `declarativeNetRequest` | <https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest> | "modify network requests without intercepting them and viewing their content"；`RuleActionType` 六个取值；`initiatorDomains` 语义；"A declarativeNetRequest rule cannot redirect from a public resource request to a resource that is not web accessible." | A |
| Chrome `chrome.debugger` | <https://developer.chrome.com/docs/extensions/reference/api/debugger> | Restricted domains 列表含 Fetch；`Debuggee.extensionId`："Attaching to an extension background page is only possible when the `--silent-debugger-extension-api` command-line switch is used."；`onDetach`："… or Chrome DevTools is being invoked for the attached tab." | A |
| CDP `Fetch` 域 | <https://chromedevtools.github.io/devtools-protocol/tot/Fetch/> | `Fetch.fulfillRequest`："Provides response to the request."，`body`："A response body. If absent, original response body will be used…"；`RequestStage`："Request … before the request is sent. Response … after the response is received (but before response body is received)." | A |
| CDP 协议机器可读定义 | <https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/browser_protocol.json> | 同上（本次用于核对 `fulfillRequest` 参数与 `RequestPattern`） | A |
| Chrome Content scripts | <https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts> | "An isolated world is a private execution environment that isn't accessible to the page or other extensions."；"When a content script is injected into the main world, the CSP of the page applies."；`world` 默认 `ISOLATED` | A |
| manifest `content_scripts` | <https://developer.chrome.com/docs/extensions/reference/manifest/content-scripts> | `"world"` - `ISOLATED` \| `MAIN`；"**Warning:** There are risks involved when using the `MAIN` world. The host page can access and interfere with the injected script." | A |
| `chrome.scripting` | <https://developer.chrome.com/docs/extensions/reference/api/scripting> | `ExecutionWorld` = `ISOLATED` \| `MAIN`；`world` 默认 `ISOLATED` | A |
| `chrome.userScripts` | <https://developer.chrome.com/docs/extensions/reference/api/userScripts> | "An isolated world is an execution environment that isn't accessible to a host page or other extensions."；"Scripts running in the main world are accessible to host pages and other extensions…"；`ExecutionWorld` = `MAIN` \| `USER_SCRIPT` | A |
| Match patterns | <https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns> | scheme "Must be one of … http / https / `*` / file" | A |
| MDN `webRequest`（Firefox） | <https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest> | "To modify response bodies for a request, call `webRequest.filterResponseData` …" | A |
| Fetch 规范 | <https://fetch.spec.whatwg.org/> | "The url getter steps are to return the empty string if this's response's URL is null…"；`redirected` / `type` getter 步骤 | A |
| XHR 规范 | <https://xhr.spec.whatwg.org/> | §3.7 Events summary；`open()`/`timeout` 对同步请求抛 `InvalidAccessError`；同步错误路径"then throw exception" | A |
| WebIDL 规范 | <https://webidl.spec.whatwg.org/> | "Let validThis be true if jsValue implements target, or false otherwise. If validThis is false … then throw a TypeError."；attribute 位于 interface prototype object | A |
| MDN `Function.prototype.toString` | <https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Function/toString> | `Math.abs.toString()` → `"function abs() { [native code] }"` | A |
| Tampermonkey `@sandbox` | <https://www.tampermonkey.net/documentation.php?q=sandbox> | `MAIN_WORLD` / `ISOLATED_WORLD` / `USERSCRIPT_WORLD`；`raw` "always needs to run in page context, the `MAIN_WORLD`" 且为默认；MAIN 注入失败会回退 | D |
| Tampermonkey `unsafeWindow` | <https://www.tampermonkey.net/documentation.php?q=unsafeWindow> | "The `unsafeWindow` object provides access to the `window` object of the page…" | D |
| Violentmonkey `@inject-into` | <https://violentmonkey.github.io/api/metadata-block/#inject-into> | `page` / `content` / `auto`；content 模式 "cannot access JavaScript objects of the web page" | D |
| Requestly：扩展 vs 桌面应用 | <https://docs.requestly.com/account/how-is-browser-extension-different-from-a-desktop-app> | 扩展列 `Serve local file Response ❌`、`Modify HTML/JS/CSS Response ❌`、`Map Local ❌`；"The extension works within the limitations of browser APIs." | D |

### 10.2 Chromium 源码（`refs/heads/main`，2026-10-06 抓取）

| 证据 | URL | 关键内容 | 等级 |
|---|---|---|---|
| `extensions/browser/api/web_request/web_request_permissions.cc` | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/browser/api/web_request/web_request_permissions.cc> | `CanExtensionAccessURLInternal` 的 `REQUIRE_HOST_PERMISSION_FOR_URL_AND_INITIATOR` 分支；`url::IsSameOriginWith(url, extension.url()) → kAllowed`；`HideRequest()` | B |
| `extensions/browser/api/web_request/extension_web_request_event_router.cc` | 同上目录 `/extension_web_request_event_router.cc` | "Filter requests from other extensions / apps. This does not work for content scripts, or extension pages in non-extension processes." | B |
| `extensions/browser/api/declarative_net_request/ruleset_manager.cc` | 同上目录 `/extensions/browser/api/declarative_net_request/ruleset_manager.cc` | `ShouldEvaluateRulesetForRequest()`（跳过其它扩展发起的非主框架请求）；`ShouldEvaluateRequest()`（跳过 `chrome-extension:` 目标） | B |
| `extensions/browser/api/declarative_net_request/indexed_rule.cc` | 同目录 `/indexed_rule.cc` | `ParseRedirect()`：只对 `javascript:` 报 `ERROR_JAVASCRIPT_REDIRECT` | B |
| `extensions/common/extension.cc` | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/extension.cc> | `kValidHostPermissionSchemes`（不含 `SCHEME_EXTENSION`） | B |
| `extensions/common/user_script.cc` | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/user_script.cc> | `kValidUserScriptSchemes`（不含 `SCHEME_EXTENSION`） | B |
| `extensions/common/url_pattern.cc` | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/url_pattern.cc> | `kValidSchemes` 含 `kExtensionScheme`（解析层允许，权限层不允许） | B |
| `extensions/common/switches.cc` | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/switches.cc> | `kExtensionsOnExtensionURLs = "extensions-on-extension-urls"`；`AreExtensionsOnExtensionURLsAllowed()` | B |
| `chrome/browser/extensions/api/debugger/debugger_api.cc` | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/extensions/api/debugger/debugger_api.cc> | `ExtensionMayAttachToURL()`（别的扩展 URL → `kCannotAccessExtensionUrl`）；`kBrowserTargetId` + `ExtensionIsTrusted()`（仅 Perfetto）；`kAlreadyAttachedError` | B |
| `chrome/browser/extensions/api/debugger/extension_dev_tools_infobar_delegate.cc` | 同目录 `/extension_dev_tools_infobar_delegate.cc` | 调试器附加时弹出信息条的实现 | B |
| `chrome/app/generated_resources.grd` | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/app/generated_resources.grd> | `IDS_DEV_TOOLS_INFOBAR_LABEL` = "'$1' started debugging this browser" | B |
| `extensions/common/permissions/permissions_data.cc` | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/permissions/permissions_data.cc> | `GetPageAccess()` / `CanRunOnPage()`（host permission 判定的落点） | B |

### 10.3 开源项目源码 / README

| 证据 | URL（repo） | 引用文件 | 等级 |
|---|---|---|---|
| Tamper Dev（原 Tamper Chrome） | <https://github.com/google/tamperchrome> | `v2/manifest_base.json`（`["debugger","activeTab"]`）、`v2/background/src/debuggee.ts`（`chrome.debugger.attach`/`sendCommand`）、`v2/background/src/interception.ts`（`Fetch.enable`）、`v2/background/src/request.ts`（`Fetch.getResponseBody`/`continueRequest`/`fulfillRequest`） | C |
| Resource Override | <https://github.com/kylepaulsen/ResourceOverride> | `manifest.json`（MV2，`webRequest`+`webRequestBlocking`，`document_start` 内容脚本）、`src/background/requestHandling.js`（`redirectUrl: "data:…"`） | C |
| Redirector | <https://github.com/einaregilsson/Redirector> | `manifest.json`（MV2，`webRequest`+`webRequestBlocking`+`webNavigation`） | C |
| ajax-hook | <https://github.com/wendux/ajax-hook> | `src/xhr-hook.js`（`win.XMLHttpRequest = HookXMLHttpRequest`、`prototype` 复用、`__origin_xhr`）、`src/xhr-proxy.js`（同步分支、`Object.assign` 常量） | C |
| xhook | <https://github.com/jpillora/xhook> | `src/main.js`、`src/patch/xmlhttprequest.js`（facade 事件、同步 `emitFinal()`、`windowRef.XMLHttpRequest = Xhook`）、`src/patch/fetch.ts`（`windowRef.fetch = Xhook`）、`src/misc/window.js`（Worker/global 识别）、`README.md`（"include XHook first…"） | C |
| fetch-intercept | <https://github.com/werk85/fetch-intercept> | `README.md`（"monkey patches the global `fetch` method"）、`src/attach.js`（拦截器链、真实 Response 透传） | C |
| @mswjs/interceptors | <https://github.com/mswjs/interceptors> | `src/interceptors/fetch/web.ts`、`src/interceptors/XMLHttpRequest/web.ts`、`src/interceptors/XMLHttpRequest/xml-http-request-proxy.ts`（`new Proxy(globalThis.XMLHttpRequest, …)`）、`src/utils/patches-registry.ts`（defineProperty/还原）、`.../xml-http-request-controller.ts`（同步请求 warn 后放行） | C |
| nise（sinon 的底层实现） | <https://github.com/sinonjs/nise> | `lib/fake-xhr/index.js`（`globalScope.XMLHttpRequest = FakeXMLHttpRequest`）、`lib/fake-server/index.js`（`respondWith`、`autoRespond` 用 `setTimeout`） | C |
| Violentmonkey | <https://github.com/violentmonkey/violentmonkey> | `src/injected/content/inject.js`（页面沙箱注入入口）；world 语义以官方文档为准 | C |

### 10.4 厂商官方文档（闭源产品）

| 证据 | URL | 等级 |
|---|---|---|
| Requestly：浏览器扩展 vs 桌面应用对照 | <https://docs.requestly.com/account/how-is-browser-extension-different-from-a-desktop-app> | D |
| Requestly：如何改写 API 响应（博客，推荐桌面应用） | <https://requestly.com/blog/how-to-load-a-different-api-response-in-frontend-code/> | D |
| Tamper Dev 官网 | <https://tamper.dev/> | D |

### 10.5 本次取证失败的通道（记录，便于复核）

| 通道 | 现象 |
|---|---|
| Chrome Web Store 扩展详情页 | 返回空内容（JS 渲染），无法取得 manifest/permissions 文本 |
| `clients2.google.com` CRX 下载 | `OpenSSL SSL_connect: SSL_ERROR_SYSCALL`（本环境网络层被拒） |
| `chrome-stats.com` | Cloudflare 403 |
| Stack Overflow（相关问答） | 403（Cloudflare 挑战页），未能读取正文 |
| `docs.requestly.io` | 301 到 `docs.requestly.com`；原路径已不存在 |
| `github.com` REST API | 403（`x-ratelimit-remaining: 0`）；改用 `raw.githubusercontent.com` 与 `git clone --depth 1` 取证 |
| requestly/requestly 开源仓 | 默认分支已不含 `browser-extension` 目录 |

---

*（完）*
