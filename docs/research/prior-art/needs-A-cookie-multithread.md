# 既有方案调研 A：带 Cookie 下载 / 多线程下载

> 本文是「aria2-in-browser 浏览器技术边界测绘」的输入文档之一，回答两个需求导向的问题：
> **需求 A** — 浏览器里「带 Cookie（含 HttpOnly）下载」有哪些现成做法、能不能用、代价是什么；
> **需求 B** — aria2 的 `split` / `max-connection-per-server` 语义在浏览器里能不能复现。
>
> 本文只做调研与判断，不做设计、不改代码、不改 `docs/concept-design/concept-design.md`。
> 所有结论都附官方文档或源码 URL；查不到的写入 §8「未验证 / 存疑」，不做记忆性断言。

---

## 0 元信息

| 项 | 值 |
|---|---|
| 调研日期 | **2026-10-06**（UTC） |
| 调研人 | `prior-cookie-a`（按团队要求**独立**完成，未与 `prior-cookie-b` 交换结论） |
| 适用浏览器 | 主要以 **Chrome / Chromium（Manifest V3）** 为对象。Firefox 只在明示处单独标注；Safari 基本未覆盖 |
| 版本线索（用于未来复核） | 官方文档快照中出现的最高/最近版本标记：`Chrome 148`（Chrome 文档称标准化 `browser.*` 命名空间自 Chrome 148 起可用）、`Chrome 130`、`Chrome 119`、`Chrome 108`（MSE 进入 dedicated worker）。**本次未确认调研时 Chrome 稳定版号**，见 §8 |
| 方法 | ① 直接抓取 MDN / Chrome Developers / WHATWG Fetch 规范 / RFC 原文；② 抓取 **Chromium 源码**（`chromium.googlesource.com`，`?format=TEXT`）核对行为；③ `git clone --depth 1` 开源扩展/库源码并检索。凡引文均标 URL；源码类引用标到文件与行号 |
| 主要来源 | MDN、Chrome for Developers、WHATWG Fetch、RFC 9113、Google Chromium 源码、aria2 官方手册、Aria2 Explorer / YAAW-for-Chrome、Turbo Download Manager、DownThemAll、WebTorrent、StreamSaver.js、FileSaver.js、Cookie-Editor、Chrome Web Store 商品页 |
| 未覆盖 | Safari 行为；Chrome for Android；真实网络环境的实测（本轮全部为文档/源码级调研） |

---

## 1 一句话结论

**需求 A（带 Cookie 下载）**：**有成熟解法，但解法是"绕开浏览器发请求"** —— 成熟方案（Aria2 Explorer / YAAW-for-Chrome）用 `chrome.cookies.getAll()` 读出 cookie（**包括 HttpOnly**：Chromium 源码里该 API 明确用 `CookieOptions::MakeAllInclusive()` 请求 Cookie 列表），拼成 `Cookie: k=v; k2=v2` 字符串，再通过 **aria2 的 RPC `header` 选项交给外部的 aria2c 去发**；而在浏览器内部，`Cookie` 是 **forbidden request header**（JS 永远设不进去），要让浏览器自己发的请求带上额外 cookie，官方唯一通路是 **DNR `modifyHeaders`**（Chrome 允许对 `cookie` 做 `append`，分隔符 `"; "`），或**干脆让浏览器自己发**（导航 / 标签页 / 表单，浏览器自动附带 cookie，HttpOnly 也照发）。

**需求 B（多线程下载）**：**基本复现不了 aria2 语义** —— 多路 Range 请求在技术上发得出去（`Range` 不是 forbidden header，且是 CORS-safelisted），但瓶颈在"**没有 API 能把分片写到用户可见文件的任意偏移**"：File System Access 的 `FileSystemWritableFileStream` 支持按 `position` 写入 / `seek()` / `truncate()`，但需要 transient user activation、写的是临时文件、`close()` 才落盘；OPFS 可随机写但**对用户不可见**、且高性能的 `createSyncAccessHandle()` **只能在 Dedicated Worker** 里用，最终还要整份拷贝出去；两个成熟下载管理器直接给出了否定结论 —— DownThemAll!：*"Segmented downloads — Cannot be done with WebExtensions"*；Chrono：*"it does not offer multi-threaded downloading capability"*。

---

## 2 需求 A：带 Cookie 下载的现有方案

> 阅读提示：A-1～A-6 是**能力事实**（浏览器允许做什么），A-7 起是**现成方案**（别人怎么做的）。需求 A 最重要的一类方案是 **A-7 把下载转交外部 aria2 的扩展**。

### A-1 页面自身同源发起（基线）

| 项 | 内容 |
|---|---|
| 原理 | 页面用 `fetch()` / `XHR` / 表单 / 导航请求同源 URL 时，浏览器按 cookie 存储规则**自动附加** cookie；JS 不需要也无法自己设置 `Cookie` 头 |
| 出处 | <https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header> ；<https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie> |
| 关键事实 | ① `Cookie` 是 **forbidden request header**："A **forbidden request header** is an HTTP header name-value pair that cannot be set or modified programmatically in a request."（列表内含 `Cookie`）；② **HttpOnly 不妨碍发送**：*"Note that a cookie that has been created with HttpOnly will still be sent with JavaScript-initiated requests, for example, when calling XMLHttpRequest.send() or fetch()."* |
| 适用场景 | 下载 URL 与页面同源、且 cookie 是 `SameSite` 允许的 |
| 局限 | HttpOnly 只是**读不到**（`document.cookie` 看不到），不是**发不出**；但页面拿不到 HttpOnly 的值 ⇒ **无法把它转发给别的引擎（例如 aria2）**。这正是 A-7 必须用扩展 API 的原因 |
| 本次未做 | 实测（浏览器行为随版本漂移，需要复核） |

### A-2 页面跨源 `fetch` + `credentials: 'include'`

| 项 | 内容 |
|---|---|
| 出处 | `RequestInit.credentials`：<https://developer.mozilla.org/en-US/docs/Web/API/RequestInit> ；CORS 指南：<https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS> ；SameSite：<https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie> |
| 原理 | 默认 `credentials: "same-origin"`；要跨源带 cookie 必须显式 `include` |
| 三条硬限制 | ① **默认值**：*"Defaults to `same-origin`."*；② **必须服务器同意**：*"even if `credentials` is set to `include`, the server must also agree to their inclusion by including the `Access-Control-Allow-Credentials` in its response. Additionally, in this situation the server must explicitly specify the client's origin in the `Access-Control-Allow-Origin` response header (that is, `*` is not allowed)."*；③ **SameSite 仍会拦**：`SameSite=Strict` = *"Send the cookie only for requests originating from the same site that set the cookie."*；`SameSite=Lax` 只对 *"cross-site requests that meet both of the following criteria: The request is a top-level navigation … The request uses a safe method"* 放行 —— 明确排除 `fetch()`：*"This would exclude, for example, requests made using the `fetch()` API"* |
| 对下载的含义 | 目标站点若没给 CORS 头（下载型站点几乎都不会给），**跨源 `fetch(credentials:'include')` 拿不到响应体** ⇒ 页面自身无法"跨源带 cookie 下载" |
| 附注 | 第三方 cookie 拦截 / CHIPS（`Partitioned`）会进一步影响 cookie 是否随请求发出（本轮未展开，见 §8） |

### A-3 扩展 service worker（MV3 SW）里 `fetch` 的 cookie 表现

| 项 | 内容 |
|---|---|
| 出处 | Chrome 官方文档 *Storage and cookies*：<https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies> ；*Cross-origin network requests*：<https://developer.chrome.com/docs/extensions/develop/concepts/network-requests> |
| 关键原文（最有用的一条） | *"For cookies associated with third-party sites, such as for a third-party site loaded in a frame on an extension page, or **a request made from an extension page to a third-party origin**, cookies behave the same as the web except in two ways: … **Requests from an extension to a third-party are treated as same-site if the extension has host permissions for the third-party. This means `SameSite=Strict` cookies can be sent.** Note that this only applies to network requests, not access through `document.cookie` in JavaScript, and does not apply if third-party cookies are blocked."* |
| 跨源权限 | *"Extension origins aren't so limited. A script executing in an extension service worker or foreground tab can talk to remote servers outside of its origin, as long as the extension requests host permissions."* ⇒ 有 host permission 时，扩展 SW 的跨源 `fetch` 不受普通 CORS 限制 |
| 结论 | 扩展 SW 里 `fetch(url, {credentials:'include'})` 是**能在浏览器内部带上目标站 cookie 的唯一正路**；有 host permission 时连 `SameSite=Strict` 都可能带上（Chrome 官方明说） |
| 局限 / 未验证 | ① 仍需 `credentials:'include'`（跨源默认 `same-origin` 不带）；② 只对**网络请求**成立（`document.cookie` 依旧看不到 HttpOnly）；③ 第三方 cookie 被拦时不成立；④ 文档给的是规则描述，**本次没有实测**（§8） |

### A-4 content script 里 `fetch` 的 cookie 表现

| 项 | 内容 |
|---|---|
| 出处 | <https://developer.chrome.com/docs/extensions/develop/concepts/network-requests> |
| 原文 | *"Content scripts initiate requests on behalf of the web origin that the content script has been injected into and therefore content scripts are also subject to the same origin policy. … **Cross-origin requests are always treated as such in content scripts, even if the extension has host permissions.**"* |
| 结论 | content script 的请求**按页面 origin 算**（cookie 跟页面走，受页面 SameSite 语境约束），且**吃 CORS**（host permission 不给它开绿灯）⇒ 与 SW 是两套语义，不能混用 |
| 对下载的含义 | 想借页面身份拿 cookie 时 content script 合适；想绕 CORS 必须回 SW |

### A-5 `chrome.cookies` 能读到什么（**能不能读 HttpOnly**）

| 项 | 内容 |
|---|---|
| 官方文档 | <https://developer.chrome.com/docs/extensions/reference/api/cookies> |
| 权限要求 | *"To use the cookies API, declare the `"cookies"` permission in your manifest along with **host permissions for any hosts whose cookies you want to access**."*；`getAll()`：*"This method only retrieves cookies for domains that the extension has host permissions to."* |
| 字段 | 返回的 `Cookie` 含 `httpOnly`：*"`httpOnly` boolean — True if the cookie is marked as HttpOnly (i.e. the cookie is inaccessible to client-side scripts)."* |
| **HttpOnly 可读的源码级证据** | `extensions/browser/api/cookies/cookies_helpers.cc` 的 `GetCookieListFromManager()` 用 `net::CookieOptions::MakeAllInclusive()` 调 `CookieManager::GetCookieList`：<https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/cookies/cookies_helpers.cc> ；而 `net/cookies/cookie_options.h` 对该方法注释为：*"Convenience method for where you need a CookieOptions that will work for getting/setting all types of cookies, **including HttpOnly and SameSite cookies**."*（同文件默认值 `bool exclude_httponly_ = true;`，即默认排除、该 API 特意不排除）：<https://chromium.googlesource.com/chromium/src/+/main/net/cookies/cookie_options.h> ；`cookies_api.cc` 中 set 路径同样显式 `options.set_include_httponly();` + `MakeInclusive()`：<https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/cookies/cookies_api.cc> |
| 结论 | **能读 HttpOnly**（不是"能读 document.cookie 之外的都读不到"），前提是 `cookies` 权限 + 对应 host permission |
| 边角 | 分区 cookie 需要 `partitionKey`（Chrome 119+）；隐身窗口需 `storeId`；`getAll` 返回不按 `httpOnly` 过滤（参数表里没有该过滤项，见文档） |
| 未验证 | `getAll` 是否会在某些场景下丢弃分区/未分区之一（A-7 的实现在代码里对 `partitionKey: {}` 做了 try/catch 容错，说明跨浏览器有差异） |

### A-6 读到的 cookie 怎么塞进请求（**三条路 + 一条死路**）

**死路（务必记住）**：JS 无法设置 `Cookie` 头 —— `Cookie` 位于 Fetch 规范的 **forbidden request-header** 列表：*"A header (name, value) is forbidden request-header if … `Cookie` … These are forbidden so the user agent remains in full control over them."*（<https://fetch.spec.whatwg.org/#forbidden-header-name>，MDN 中文/英文同样列出 <https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header>）。**任何"用 fetch 手动加 Cookie 头"的方案都不可能成立。**

**路线 1：DNR `modifyHeaders`（扩展内唯一能改请求头的方式）**

- 文档：<https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest>（Header modification 一节）
- `cookie` 在 Chrome 的 **append 白名单**里：*"The `append` operation is only supported for the following request headers: accept, accept-encoding, accept-language, access-control-request-headers, cache-control, connection, content-language, **cookie**, forwarded, if-match, if-none-match, keep-alive, **range**, te, trailer, transfer-encoding, upgrade, user-agent, via, want-digest, x-forwarded-for. This allowlist is case sensitive (bug 449152902). **When appending to a request or response header, the browser will use the appropriate separator where possible.**"*（同页示例甚至演示了 `{"header":"cookie","operation":"remove"}`）
- 分隔符的**源码级证据**：`extensions/browser/api/declarative_net_request/constants.h` 中 `kDNRRequestHeaderAppendAllowList` 为 `{"cookie", "; "}`（其余多为 `", "`；`user-agent` 为 `" "`）：<https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/declarative_net_request/constants.h>
- **限制点**：只有 `append` 受白名单约束；`set` / `remove` 在规则解析时不看白名单（`indexed_rule.cc` 的 `ValidateHeadersForModification()` 仅在 `operation == kAppend` 且是请求头时查白名单，越界直接报 `ERROR_APPEND_INVALID_REQUEST_HEADER` = **规则安装失败**，不是静默忽略）：<https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/declarative_net_request/indexed_rule.cc>
- MDN 同款说明（Firefox/Chrome 差异）：<https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest/ModifyHeaderInfo>
- **注意**：DNR 是"网络层"的，作用于**浏览器实际发出的请求**；对"请求根本不发出的场景"无意义（与本项目 R9 的 JS 层短路无关）

**路线 2：`chrome.downloads.download({headers})` —— 想都别想**

- Chrome 文档只说：*"headers … Extra HTTP headers to send with the request if the URL uses the HTTP[s] protocol. Each header is represented as a dictionary containing the keys `name` and either `value` or `binaryValue`, **restricted to those allowed by XMLHttpRequest**."*：<https://developer.chrome.com/docs/extensions/reference/api/downloads>
- 真正的判定在源码：`chrome/browser/extensions/api/downloads/downloads_api.cc` 对每个 header 依次校验 `net::HttpUtil::IsValidHeaderName` → **`net::HttpUtil::IsSafeHeader`**（失败报 `kInvalidHeaderUnsafe`）→ `IsValidHeaderValue`：<https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/extensions/api/downloads/downloads_api.cc>
- `IsSafeHeader` 的禁用列表来自 fetch 规范，**含 `cookie`、`referer`、`user-agent`、`origin`、`host`、`accept-encoding` 等**（`net/http/http_util.cc` 的 `kForbiddenHeaderFields`）：<https://chromium.googlesource.com/chromium/src/+/main/net/http/http_util.cc>
- 旁证（Firefox 侧措辞更明确）：MDN `downloads.download` —— *"The headers that are forbidden by XMLHttpRequest and fetch cannot be specified, however, Firefox 70 and later enables the use of the Referer header. Attempting to use a forbidden header throws an error."*：<https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/downloads/download>
- **推论（对本项目很重要）**：`Range` **不在**该禁用列表里 ⇒ 理论上可以给下载请求下 `Range` 头（但浏览器下载器是否 honor、是否会因此变成 206 分片，**未验证**，见 §8）

**路线 3：让浏览器自己发（导航 / 标签页 / 表单 / `<a download>`）**

- 这类请求"由浏览器发起"，cookie 由浏览器按 cookie 存储规则**自动附带**（HttpOnly 同样附带，理由同 A-1 的 MDN 引文：HttpOnly 只限制 JS 读取，不限制发送）
- 现成工程实践：**附录 A 的样机就是这条路**（`chrome.tabs` 打开 URL，让浏览器原生下载流接管）
- 局限：① 落盘位置/文件名由浏览器与两条 DNR 决定（附录 A §A.4 已记录）；② SameSite 语境变化时行为不同（跨站导航有 `Lax` 门槛、`Strict` 更严）；③ **无法把"只有扩展 API 才读得到的 cookie"作为数据流注入到别的请求**，只能"让浏览器用它自己那份 cookie 去发"；④ 扩展自己发起的导航是否算 same-site（从而带 `Strict` cookie）**本次未找到官方明文**（见 §8）

**补充（MV3 已无 webRequest 阻塞式改造头）**

- *"As of Manifest V3, the `"webRequestBlocking"` permission is no longer available for most extensions. … Policy installed extensions can continue to use `"webRequestBlocking"`."*（`webRequestBlocking`: *"As of Manifest V3, this is only available to policy installed extensions."*）：<https://developer.chrome.com/docs/extensions/reference/api/webRequest> ⇒ MV3 普通扩展**只能用 DNR** 改请求头
- 且 *"Only one extension can redirect a request or modify a header at a time. If more than one extension attempts to modify the request, the most recently installed extension wins, and all others are ignored."*（同页）⇒ **多扩展冲突/被静默忽略**是一条真实盲区

### A-7 【核心】把浏览器下载转交外部 aria2 的扩展：**它们怎么取 cookie、怎么传给 aria2**

#### A-7.1 Aria2 Explorer（`alexhua/Aria2-Explorer`，Chrome/Edge，MV3）

| 项 | 内容 |
|---|---|
| 出处 | 仓库：<https://github.com/alexhua/Aria2-Explorer> ；代码：<https://github.com/alexhua/Aria2-Explorer/blob/master/background.js#L110-L154>；清单：<https://github.com/alexhua/Aria2-Explorer/blob/master/manifest.json> |
| 调研到的版本 | `manifest_version: 3`，`version: 2.8.3`（clone 的 `master`，最后一次提交 2026-10-06） |
| 权限 | `permissions: ["cookies","tabs","notifications","contextMenus","downloads","storage","scripting","sidePanel","power"]`，`host_permissions: ["<all_urls>"]` ⇒ "cookies + 全站 host permission"是标配 |
| 取 cookie（原理） | `chrome.cookies.getAll({url, storeId})`；再对分区 cookie 单独 `chrome.cookies.getAll({url, storeId, partitionKey: {}})`（try/catch 容错，注释：*"Ignore browsers that do not support partitionKey."*）；`storeId` 由 `downloadItem.incognito` 决定 |
| 拼装 | `const cookieMap = new Map([...cookies, ...partitionedCookies].map(c => [c.name, c.value]))` → `cookieItems.push(name + "=" + value)` |
| 传给 aria2 | `headers.push("Cookie: " + cookieItems.join("; "))`，再 `headers.push("User-Agent: " + navigator.userAgent)`；随后作为 **JSON-RPC `aria2.addUri` 的 `header` 选项**发出：`aria2.addUri(downloadItem.url, options)`，`options.header = headers` |
| 用了哪些 API | `chrome.cookies`、`chrome.downloads`（`onDeterminingFilename` 捕获浏览器下载、必要时 `chrome.downloads.cancel` + 回退 `chrome.downloads.download`）、`chrome.storage`、`chrome.tabs`/内置 AriaNg UI |
| 适用场景 | 浏览器里看到的下载 → 交给本机 aria2c 下（**真正的多线程/断点续传由 aria2c 提供**） |
| 局限 | ① 必须已有 aria2 RPC 服务；② cookie 是**快照**（下载时读一次，长任务期间不会刷新）；③ 只按 `url` 取 cookie，不处理"下载 URL 与登录页不同域"的场景；④ `multiTask`（多地址/镜像）时用的是 `referrer` 而非 `url` 取 cookie；⑤ 分区 cookie 需较新浏览器；⑥ 明文写"Cookie"到 aria2 参数里，等于把凭据交给本地 aria2（本地进程，风险可接受但要知道） |

#### A-7.2 Aria2 for Chrome（`alexhua/Aria2-for-chrome`）

| 项 | 内容 |
|---|---|
| 出处 | <https://github.com/alexhua/Aria2-for-chrome> ；<https://github.com/alexhua/Aria2-for-chrome/blob/master/background.js#L110-L154> |
| 调研到的版本 | `manifest_version: 3`，`version: 2.8.3`（最后一次提交 2026-10-06）；**代码与本仓库 A-7.1 的 `background.js`/`manifest.json` 在本次 clone 到的内容上基本一致**（同作者两条产品线已收敛） |
| 取 cookie / 传递 | 与 A-7.1 相同：`chrome.cookies.getAll` → `"Cookie: " + join("; ")` → `aria2.addUri` 的 `header` 选项 |
| 结论 | 与 A-7.1 视为同一解法，不重复计数 |

#### A-7.3 YAAW for Chrome（`acgotaku/YAAW-for-Chrome`）

| 项 | 内容 |
|---|---|
| 出处 | <https://github.com/acgotaku/YAAW-for-Chrome> ；代码：<https://github.com/acgotaku/YAAW-for-Chrome/blob/master/background.js#L114-L134>；清单：<https://github.com/acgotaku/YAAW-for-Chrome/blob/master/manifest.json> |
| 调研到的版本 | `manifest_version: 3`，`version: 1.0.0`（最后一次提交 2026-06-13） |
| 权限 | `permissions: ["cookies","notifications","tabs","contextMenus","downloads","storage"]`，`host_permissions: ["<all_urls>"]` |
| 取 cookie / 传递（原文） | `chrome.cookies.getAll({ url: fileDownloadInfo.link }, function (cookies) { … formatedCookies.push(cookie.name + '=' + cookie.value) … header.push('Cookie: ' + formatedCookies.join('; ')); header.push('User-Agent: ' + navigator.userAgent); … method: 'aria2.addUri', params: [[link], { header }] … })` |
| 结论 | 与 A-7.1 同一解法（**独立实现、同一套路**——这就是该问题的"事实标准"） |
| 局限 | 除 A-7.1 的①～④外，它还顺带把 Basic `Authorization` 头也一起塞进 options（`parameter.options.headers.Authorization = authStr`），说明"浏览器设不进的头 → 交给 aria2 设"是通用套路 |

**A-7 的小结（本题最重要的结论）**

> 成熟解法是 **"扩展读 cookie（`chrome.cookies`，含 HttpOnly）+ 把 Cookie 头交给一个非浏览器 HTTP 客户端（aria2c）去发"**。
> 它之所以成立，恰恰是因为**请求最终不是浏览器发的**——绕开了 forbidden header、CORS、SameSite 三堵墙。
> 对我们项目而言：**这条路的"难点部分"（读 cookie、拼 Cookie 头）可以直接复用；"最后一步"（谁来发）在我们这里必须换成浏览器自己的下载通路**，因此不能用"aria2c 帮我们发"这一招（详见 §5）。

#### A-7.4 其它同类（**未逐一验证**）

- `mayswind/AriaNg`：纯 Web UI，无扩展权限，**读不到 HttpOnly cookie**（只能靠 `document.cookie` 或用户手填 `header`）；本轮**未抓取源码验证**，列为 §8。
- 「Aria2 Manager / Aria2 Pro Downloader」等其它 aria2 前端/扩展：本轮未验证。

### A-8 cookie 导出/编辑类扩展（证明"扩展可读写 HttpOnly"的独立旁证）

| 项 | 内容 |
|---|---|
| 方案 | Cookie-Editor（`Moustachauve/cookie-editor`，最后一次提交 2026-08-14） |
| 出处 | <https://github.com/Moustachauve/cookie-editor> ；`interface/popup/cookie-list.js`（读写 `httpOnly`）、`interface/options/options.html`（导出格式含 `httponly` 选项） |
| 原理 | 用 `chrome.cookies` 的 get/set 系列；代码里直接读写 `cookie.httpOnly` 字段，导出选项里也有 "Http Only" 列 ⇒ 与 A-5 的源码结论一致 |
| 对本项目的用处 | 说明"扩展读 HttpOnly cookie"在商店里是**被允许且普遍**的能力，不是灰色手段；同时它是"cookie 导出"任务的现成竞争者/参照 |
| 未验证 | 其 manifest 权限清单（clone 到的工作区未定位到 manifest 路径），故只作旁证不作主证据 |

### A-9 顺带结论：**多线程下载管理器扩展基本不用自己取 cookie**

- Chrono / DownThemAll / Turbo Download Manager(Classic) 这类扩展把请求交给**浏览器自身的下载器**（详见 §3），cookie 由浏览器自动附带，**因此它们的源码里没有 cookie 读取逻辑**。本轮在 DownThemAll 仓库（`master`，最后一次提交 2026-05-27）内检索 `cookie`/`credentials` 未发现自建 cookie 交接机制（检索为定性，未做穷尽枚举）。
- 结论：**"带 cookie"和"多线程"这件事在生态里是"**二选一**"的** —— 要么用浏览器下载器（有 cookie、无多线程、Cookie 头不可定制），要么交给外部 aria2（可定制 cookie、可多线程、但要装 aria2）。这直接命中我们项目的靶心：**两者都要**，所以必须自己拼装（§5）。

---

## 3 需求 B：多线程 / 多连接下载的现有方案

### B-1 Turbo Download Manager（`inbasic/turbo-download-manager`，Chrome/Firefox/Opera/Electron）

| 项 | 内容 |
|---|---|
| 出处 | <https://github.com/inbasic/turbo-download-manager> ；核心：<https://github.com/inbasic/turbo-download-manager/blob/master/src/lib/wget.js> ；写盘：<https://github.com/inbasic/turbo-download-manager/blob/master/src/lib/chrome/chrome-cm.js#L320-L357> ；扩展清单：<https://github.com/inbasic/turbo-download-manager/blob/master/src/manifest-extension.json> |
| 调研到的版本 | `master` 最后一次提交 **2017-02-21**（0.3.4）；商店页仍在：<https://chromewebstore.google.com/detail/turbo-download-manager-cl/kemfccojgjoilhfmcblgimbggikekjip>（*"a download manager with multi-threading support"*，"Speeds up downloads (speed depends on the number of segments and your network capacity)"） |
| 多线程原理（原文） | 参数：`min-segment-size`（注释 *"minimum thread size; 50 KBytes"*）、`max-segment-size`（50 MBytes）；`chunk()` 里 `if (report) obj.headers.Range = 'bytes=' + range.start + '-' + range.end;`；分片条件：`'multi-thread': !!length && contentEncoding === null && req.getResponseHeader('Accept-Ranges') === 'bytes' && lengthComputable !== 'false'`；拿不到 206 直接失败：`if (res.status && res.status !== 206 && obj.headers.Range) throw new utils.CError('expected 206 but got ' + res.status)` |
| 合并/写盘原理 | 分片写入是 **按 offset 写**：`obj.writer(range, {offset, buffer})`；Chrome 侧实现：`file.createWriter(function (fileWriter) { … fileWriter.seek(offset); fileWriter.write(blob); })`，截断用 `fileWriter.truncate(bytes)`（HTML5 `FileWriter`） |
| 依赖的 API（关键） | `app.fileSystem.root.external()` 用 **`chrome.fileSystem.chooseEntry/restoreEntry`**（**Chrome App 专属 API**，普通扩展拿不到）；`root.internal()` 用 `navigator.webkitTemporaryStorage.requestQuota` + `window.requestFileSystem(TEMPORARY)`（deprecated 的 webkit 沙箱文件系统）；导出口子用 `URL.createObjectURL(file)`。扩展清单 `src/manifest-extension.json` 只有 `storage/tabs/notifications/contextMenus/webRequest/<all_urls>/clipboardRead/downloads`，**没有 `fileSystem`** |
| 适用场景 | 曾经的 Chrome App / Firefox 附加组件 / Electron（能拿到平台文件 API） |
| 局限 | ① **生态已死**：仓库停更于 2017，Chrome Apps 平台本身已被 Google 淘汰；② 扩展构建里存在 `app.download = (obj) => chrome.downloads.download({url, filename})`（`src/lib/opera/opera.js`）这条**回到浏览器下载器**的路径，而它的按 offset 写入依赖 `chrome.fileSystem`（**Chrome App 专属 API，普通扩展不可用**）⇒ 多线程写入在扩展形态下**很可能拿不到文件句柄**（本次未实际运行验证，见 §8）；③ 依赖 `Accept-Ranges: bytes` + 无 `Content-Encoding` + 已知长度，三者缺一即退化成单流 |
| 对本项目的价值 | **是"浏览器里真的做过多连接下载"的最好证据**，但它成功的前提（Chrome App 的文件系统 API）**在 MV3 扩展里不复存在** |

### B-2 DownThemAll!（`downthemall/downthemall`，Firefox WebExtension）

| 项 | 内容 |
|---|---|
| 出处 | <https://github.com/downthemall/downthemall> ；`Readme.md`：<https://github.com/downthemall/downthemall/blob/master/Readme.md> ；`TODO.md`：<https://github.com/downthemall/downthemall/blob/master/TODO.md> |
| 调研到的版本 | `master` 最后一次提交 2026-05-27（4.15.1），**活跃维护中** |
| 官方结论（原文明引） | Readme L13：*"Being a WebExtension it lacks a ton of features the original DownThemAll! had. … WebExtensions are extremely limited in what they can do."*；L17：*"**we cannot do our own downloads any longer but have to go through the browser download manager always**"*；L19：*"I spent countless hours evaluating various workarounds to enable us to do our own downloads instead of relying on the downloads API … From using `IndexedDB` to store retrieved chunks via `XHR`, to doing nasty service-worker tricks to fake a download that the backend would retrieve with `XHR`. The last one looks promising but I have yet to get it to work in a manner that is reliable, performs well enough and doesn't eat all the system memory for breakfast."* |
| TODO.md（P4：*"Stuff that probably cannot be implemented due to WeberEension limitations"*，原文含拼写错误） | *"Segmented downloads — Cannot be done with WebExtensions - downloads API has no support and manually downloading, storing in temporary add-on storage and reassmbling the downloaded parts later is not only efficient but does not reliabliy work due to storage limitations."*；*"Checksums/Hashes? — Cannot be done with WebExtensions - cannot actually read the downloaded data"*；*"Mirrors? — Cannot be done with WebExtensions - no low level APIs, see segmented downloads"*；*"Metalink? — Currently infeasible, as we cannot look into download data streams."* |
| 多连接 | **没有**；UI 里的 "Connections" 只是历史遗留（`windows/prefs.html` 有该控件，代码侧本次只找到 `concurrent`（同时下载的**文件数**）在 `windows/prefs.ts` 中使用） |
| 局限 | Firefox 实现，但因为走的是**同一套 `downloads` API 抽象**（Chrome 亦然），这份"做不到"的清单对 Chrome MV3 **高度可迁移** |
| 对本项目的价值 | 提供**权威的否定证据**：分段下载、校验、镜像在 WebExtension 里都没有可靠实现；且明确指出"临时存储重拼"的**存储限额**问题 |

### B-3 Chrono Download Manager（Chrome）

| 项 | 内容 |
|---|---|
| 出处 | 商店页：<https://chromewebstore.google.com/detail/chrono-download-manager/mciiogijehkdemklbdcbfkefimifhecn> |
| 官方原文（KNOW ISSUES） | *"Chrono currently uses Chrome™'s built-in Downloads API, so **it does not offer multi-threaded downloading capability** and has limited support for pausing and resuming a large download. All downloaded files can only be saved under Chrome™'s default downloads folder or any of its subdirectories."* |
| 原理 | 走 `chrome.downloads`；提供重命名/规则/任务队列等 *"organizing / renaming / routing"* 功能，**不做传输层加速** |
| 局限 | 不能多线程；不能自选目录（只能在默认下载目录及其子目录）；暂停/恢复能力有限 |
| 对本项目的价值 | **厂商自己承认**："用 Chrome 内置 Downloads API ⇒ 没有多线程能力"。这是"多线程"能力在浏览器里不可真实还原的直接证据 |

### B-4 需要本机程序的"加速下载"扩展（Free Download Manager / IDM 类）

| 项 | 内容 |
|---|---|
| 出处 | FDM 扩展商店页：<https://chromewebstore.google.com/detail/download-with-free-downlo/jlodlegnpjplclncjkgolcmdhjmlokna> |
| 官方原文 | *"Sends your downloading jobs to the Free Download Manager by pausing the built-in download manager … **Notes: 1. For the extension to work you need to have Free Download Manager (FDM) installed; … 2. For the extension to be able to communicate with FDM, a small native client is required.** This native client can be found at https://github.com/belaviyo/native-client/releases."* |
| 原理 | 扩展只负责"**暂停浏览器下载 + 把真实可下载 URL/上下文交给本机程序**"，多连接/加速全部发生在**本机程序**里（Native Messaging 客户端） |
| 对本项目的价值 | 与 A-7 同类结构：**"浏览器内多连接下载"的现成方案一律把实际传输外包**。这与我们 R1"免安装 aria2"的诉求正面冲突（除非我们把多线程做进浏览器，或退回"单流+伪装"） |

### B-5 WebTorrent 浏览器版（浏览器端分片下载 + 校验 + 服务化）

| 项 | 内容 |
|---|---|
| 出处 | <https://github.com/webtorrent/webtorrent> ；`docs/api.md`：<https://github.com/webtorrent/webtorrent/blob/master/docs/api.md> |
| 分片/并发 | BitTorrent 分片模型（多 peer / 多片并发），`strategy: 'rarest' | 'sequential'`；*"client.createServer([opts], force) — Create an http server to serve the contents of this torrent, **dynamically fetching the needed torrent pieces to satisfy http requests. Range requests are supported.** … `controller: ServiceWorkerRegistration // … Browser only. Required!`"*（api.md L286 起） |
| 落盘/存储 | ① 内存 chunk store：`storeCacheSlots: Number // Number of chunk store entries (torrent pieces) to cache in memory [default=20]`（L129）；② **浏览器可写用户目录**：`storeOpts.rootDir — (browser only) FileSystemDirectoryHandle — if supported by the browser, allows the user to specify a custom directory to stores the files in, retaining the torrent's folder and file structure`（L161）；③ 校验：`skipVerify: Boolean // If true, client will skip verification of pieces for existing store and assume it's correct`（L132，反证默认会校验） |
| 适用场景 | P2P 传输；请求方（`<video>` / 普通 HTTP 客户端）通过 **Service Worker 提供的虚拟 HTTP 端点**按 Range 取数据 |
| 局限 | ① 需要 Service Worker 与页面绑定；② 浏览器端目录写入依赖 `FileSystemDirectoryHandle`（Chromium 系可用）且需用户授权；③ 实际吞吐受分片/peer 影响，不解决"单条 HTTP 连接多连接加速"的问题 |
| 对本项目的价值 | **证明了浏览器里可以做"多分片并发 + 落地 + 随机访问读"**：分片在内存/句柄里，随机访问通过 SW 的 Range 服务对外暴露。这是"合并"的一种已落地范式（但它是"边下边服务"，不是"先拼成整文件再交给下载器"） |

### B-6 HLS / DASH 播放器 + MSE（浏览器里最大规模的"分段并发下载 + 合并"）

| 项 | 内容 |
|---|---|
| 出处 | MDN MSE：<https://developer.mozilla.org/en-US/docs/Web/API/Media_Source_Extensions_API> ；hls.js：<https://github.com/video-dev/hls.js>（clone 到 `master`，最后提交 2026-10-06） |
| 原理 | 播放器用 `fetch`/XHR **逐段**拉取媒体分片（每段一个 HTTP 请求），再 `SourceBuffer.appendBuffer()` 交给 MSE 解码播放 |
| 原文 | MDN：*"MSE gives us finer-grained control over how much and how often content is fetched … It lays the groundwork for adaptive bitrate streaming clients (such as those using DASH or HLS) to be built on its extensible API."*；*"Starting with Chrome 108, MSE features are available in dedicated web workers"* |
| 并发度 | **未验证**：hls.js 源码检索未找到名为 `maxNumLoadingRequests` / `concurrent` 的"分片并发度"配置项（只找到 `maxNumRetry` 等重试项），本轮**不给出 hls.js 的具体并发上限**（见 §8） |
| 局限 | ① 合并只能进 MSE（= 必须可播放的媒体格式；**不能产出任意二进制文件**）；② 是"流式播放"模型，不是"落盘整文件"；③ 分片 URL 由清单决定，不等于"同一 URL 的 byte ranges" |
| 对本项目的价值 | 说明"多请求并发 + 本地合并"在浏览器里**早就存在且成熟**，但它的合并终点是**解码器**，不是**文件系统** ⇒ 不能直接借用来实现 `split` |

### B-7 StreamSaver.js（顺序写盘）

| 项 | 内容 |
|---|---|
| 出处 | <https://github.com/jimmywarting/StreamSaver.js> ；`README.md`（`master`，最后提交 2026-07-30） |
| 原理 | *"This is accomplish by emulating how a server would instruct the browser to save a file using some response header + service worker"*；即用 **Service Worker（MITM iframe）伪造一个带 `Content-Disposition: attachment` 的响应**，把 `WritableStream` 数据灌进浏览器原生下载 |
| 原文（限制） | *"**Handle unload event** when user leaves the page. The download gets broken when you leave the page."*；*"…worker goes idle after 30 sec in firefox, 5 minutes in blink…"*；*"best that you initiate the `createWriteStream` on user interaction … this is so that you can get around the popup blockers"*；与 FileSaver 的分工：*"Instead of saving data in client-side storage or in memory you could now actually create a writable stream directly to the file system"* |
| 写入模型 | **只能顺序写**（一个 `WritableStream`），没有 offset/seek 概念 ⇒ **不能**用来按 Range 分片回填 |
| 适用场景 | 源端是流式（媒体、压缩包生成、云盘流）且大小不可知的场景 |
| 局限 | 依赖 SW + MITM iframe；页面不能关；popup/用户手势；SW 生命周期（30s/5min idle）；不是文件系统句柄 |
| 对本项目的价值 | "顺序流"路线的代表：**若不要求断点/分片校验，它可以做到"零内存占用落盘"**，但与我们 `split` 的目标（随机 offset 回填）不匹配 |

### B-8 FileSaver.js（整块 Blob 落盘）

| 项 | 内容 |
|---|---|
| 出处 | <https://github.com/eligrey/FileSaver.js> ；`README.md`（`master`，最后提交 2022-07-27） |
| 原理 | 内存里造 `Blob`（可跨浏览器退化为 `data:` URI），再用临时 `<a download>` 触发保存 |
| 原文（上限表） | *"| Chrome | Blob | Yes | [2GB] | None |"*；*"| Firefox 20+ | Blob | Yes | 800 MiB | …"*；*"| Chrome for Android | Blob | Yes | RAM/5 |"*；开篇建议：*"If you need to save really large files bigger than the blob's size limitation or don't have enough RAM, then have a look at the more advanced StreamSaver.js"* |
| 局限 | **必须整份数据在内存里**，受 blob 上限/内存约束；无法增量、无法随机写 |
| 对本项目的价值 | 只能用于小文件；对"大文件下载引擎"是**不可接受**的路线 |

### B-9 「合并」到底能不能做：两个落盘原语的硬事实（本节的结论核心）

**（a）File System Access：`showSaveFilePicker()` + `createWritable()`**

| 项 | 内容 |
|---|---|
| 出处 | <https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker> ；<https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream> ；<https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream/write> |
| **能按 offset 写吗** | **能**。`write()` 接受 `{type:"write", position, data}`：*"`position` — The byte position the current file cursor should move to if type `"seek"` is used. **Can also be set if type is `"write"`, in which case the write will start at the specified position.** "`；另有 `seek()`（*"Updates the current file cursor offset to the position (in bytes) specified"*）与 `truncate()` |
| 落盘语义 | *"**No changes are written to the actual file on disk until the stream has been closed. Changes are typically written to a temporary file instead.**"* ⇒ **`close()` 之前没有"部分文件"可交付**；中途崩溃会怎样、临时文件是否保留，文档未说明 |
| 性能 | MDN OPFS 页对该路径的描述：*"These writes are not in-place, and instead use a temporary file. … As a result, these operations are fairly slow. It is not so noticeable when you are making small text updates, but the performance suffers when making more significant, large-scale file updates"*（<https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system>） |
| 用户交互成本 | *"**Transient user activation is required.** The user has to interact with the page or a UI element in order for this feature to work."* + *"Secure context"* + *"Limited availability … not Baseline because it does not work in some of the most widely-used browsers"*（Firefox 未实现） |
| 异常 | `NotAllowedError`（*"Thrown if PermissionStatus.state is not granted"*）、`QuotaExceededError` |
| **未验证** | ① 扩展 SW / offscreen document 里能否调用 picker（picker 属 `Window`）；② 授权句柄跨浏览器重启后的续写能力 |

**（b）OPFS：`navigator.storage.getDirectory()` + `createSyncAccessHandle()`**

| 项 | 内容 |
|---|---|
| 出处 | <https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle/createSyncAccessHandle> ；<https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system> |
| 能力 | 同步 `read()/write()`，**支持 `{at: offset}` 随机访问**（页内示例：`syncAccessHandle.write(buffer, {at: offset})`）；*"The synchronous nature of this method brings performance advantages"* |
| **上下文限制（最关键）** | *"**Note: This feature is only available in Dedicated Web Workers.** … it is only usable inside dedicated Web Workers for files within the origin private file system."* ⇒ **MV3 service worker 用不了**；需要专门开 `Worker`。另外 *"Creating a `FileSystemSyncAccessHandle` takes an **exclusive lock** on the file … This prevents the creation of further `FileSystemSyncAccessHandle`s or `FileSystemWritableFileStream`s for the file until the existing access handle is closed."*（新 `mode: "read-only"` 允许多个只读句柄） |
| **用户可见性（对我们的致命点）** | *"The origin private file system (OPFS) is a storage endpoint … **private to the origin of the page and not visible to the user**"*；*"Browsers persist the contents of the OPFS to disk somewhere, but **you cannot expect to find the created files matched one-to-one. The OPFS is not intended to be visible to the user.**"* ⇒ 下完还要**整份拷贝出去**（`getFile()` → Blob → 下载/`showSaveFilePicker`），意味着**峰值 2× 磁盘 + 一次全量拷贝** |
| 配额/生命周期 | *"The OPFS is subject to browser storage quota restrictions … Clearing storage data for the site deletes the OPFS."*；可用 `navigator.storage.estimate()`；扩展可申请 `"unlimitedStorage"`（Chrome 文档：*"Request the `"unlimitedStorage"` permission, which affects both extension and web storage APIs and exempts extensions from both quota restrictions and eviction."*，<https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies>） |
| **未验证** | OPFS 根句柄在 MV3 SW 中能否取得、`getDirectory()` 在 SW 中的可用性（MDN 只写 *"This feature is available in Web Workers"*） |

**（c）分片/断点续传/校验的可行性（综合 A/B 证据）**

| 能力 | 结论 | 证据 |
|---|---|---|
| 多路 Range 并发请求 | **可发**：`Range` 不在 forbidden 列表，且是 CORS-safelisted（仅单区间、值 ≤128）：*"`range` Let rangeValue be the result of parsing a single range header value given value and false. … As web browsers have historically not emitted ranges such as `bytes=-500` this algorithm does not safelist them."*（<https://fetch.spec.whatwg.org/#cors-safelisted-request-header>）；`Range` 另被列为 *"privileged no-CORS request-header name … commonly used by downloads and media fetches"* |
| 服务器不支持 `Accept-Ranges` | 只能退化为**单流**：TDM 的 `multi-thread` 判定要求 `Accept-Ranges: bytes` + 无 `Content-Encoding` + 已知 `Content-Length`，否则 `simple-mode`（B-1） |
| 断点续传 | 浏览器不给"部分文件"：`chrome.downloads` 只有 `pause/resume` 与 `canResume`（*"True if the download is in progress and paused, or else if it is interrupted and can be resumed starting from where it was interrupted."*），**文档未说明其依赖服务器字节范围支持**（§8）；自己实现的续传必须自己持久化"已收到的分片"（TDM 写文件 offset；DTA 说临时存储重拼不可靠） |
| 分片校验 | 可在内存里 `crypto.subtle.digest`，但**拿不到浏览器下载器写下的文件内容**（DTA：*"Checksums/Hashes? — Cannot be done with WebExtensions - cannot actually read the downloaded data"*）；只有自建下载通路（fetch → 自己写盘）才谈得上校验 |
| 并发上限 | HTTP/1.1：**每 proxy-chain 正常连接 6 条**：Chromium `net/socket/client_socket_pool_manager.cc` 中 `g_max_sockets_per_group = { 6, 255 } // kNormal, kWebSocket`（<https://chromium.googlesource.com/chromium/src/+/main/net/socket/client_socket_pool_manager.cc>）；HTTP/2：单连接多路复用，并发由 `SETTINGS_MAX_CONCURRENT_STREAMS` 决定 —— *"This setting indicates the maximum number of concurrent streams that the sender will allow. … **It is recommended that this value be no smaller than 100**, so as to not unnecessarily limit parallelism."*（RFC 9113 §6.5.2，<https://www.rfc-editor.org/rfc/rfc9113.txt>）；且全部流共享同一条 TCP 的流控与拥塞控制：*"Using streams for multiplexing introduces contention over use of the TCP connection, resulting in blocked streams. A flow-control scheme ensures that streams on the same connection do not destructively interfere with each other. Flow control is used for both individual streams and the connection as a whole."*（RFC 9113 §5.2） |

### B-10 唯一的"零写入"通道：`chrome.downloads`

| 项 | 内容 |
|---|---|
| 出处 | <https://developer.chrome.com/docs/extensions/reference/api/downloads> |
| 能给什么 | 进度（`bytesReceived` / `totalBytes` / `fileSize`）、状态、暂停/继续（`pause()`/`resume()`/`canResume`）、文件名（相对下载目录，`onDeterminingFilename`）、`saveAs` |
| 不能给什么 | 不能指定任意目标路径（*"A file path relative to the Downloads directory"*）、不能按 offset 写、不能读回数据流、不能设置 `cookie`/`referer`/`user-agent` 等头（A-6 路线 2）、不能多连接 |
| 对本项目的意义 | 它是**唯一"浏览器自己发 + 浏览器自己写 + 有真实进度"的通路**，也是 §5 里"能直接兑现结果"的那条路；代价是"能力集等于浏览器下载器" |

---

## 4 硬约束（不可逾越的墙，逐条给证据）

| # | 约束 | 证据（URL + 原文） |
|---|---|---|
| C1 | **JS 永远不能设置 `Cookie` 请求头** | Fetch 规范：*"A header (name, value) is forbidden request-header if … `Cookie` … These are forbidden so the user agent remains in full control over them."* <https://fetch.spec.whatwg.org/#forbidden-header-name> ；MDN 列表亦含 `Cookie` <https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header> |
| C2 | **`chrome.downloads` 的 headers 不允许 cookie / referer / user-agent / origin / host / accept-encoding 等** | 源码双重证据：`downloads_api.cc` 用 `net::HttpUtil::IsSafeHeader` 校验并报 `kInvalidHeaderUnsafe` <https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/extensions/api/downloads/downloads_api.cc> ；`kForbiddenHeaderFields` 列表（含 `cookie`、`referer`、`user-agent`）<https://chromium.googlesource.com/chromium/src/+/main/net/http/http_util.cc> ；`Range` **不在**该列表 |
| C3 | **读 HttpOnly cookie 需要扩展 API**（`cookies` 权限 + host permission），页面 `document.cookie` 读不到 | MDN：*"Forbids JavaScript from accessing the cookie, for example, through the `Document.cookie` property."* <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie> ；Chrome：`cookies` 权限 + *"host permissions for any hosts whose cookies you want to access"* <https://developer.chrome.com/docs/extensions/reference/api/cookies> ；HttpOnly **可读**的源码证据：`CookieOptions::MakeAllInclusive()`（*"including HttpOnly and SameSite cookies"*）<https://chromium.googlesource.com/chromium/src/+/main/net/cookies/cookie_options.h> + <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/cookies/cookies_helpers.cc> |
| C4 | **MV3 里改请求头只有 DNR 一条路**，且 `append` 受白名单约束（`cookie` 在名单内，分隔符 `"; "`）；`set`/`remove` 解析期不受白名单约束 | *"As of Manifest V3, the `"webRequestBlocking"` permission is no longer available for most extensions."* <https://developer.chrome.com/docs/extensions/reference/api/webRequest> ；白名单 <https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest> ；分隔符 <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/declarative_net_request/constants.h> ；校验逻辑 <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/declarative_net_request/indexed_rule.cc> |
| C5 | **跨源带凭据的 fetch 需要服务端配合**（`Access-Control-Allow-Credentials` + 具体 origin，不能用 `*`）；`same-origin` 是默认值 | <https://developer.mozilla.org/en-US/docs/Web/API/RequestInit> |
| C6 | **`SameSite` 会拦跨站请求**：`Strict` 只发同站；`Lax` 只放行"顶层导航 + 安全方法"，明确排除 `fetch()` | <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie> ；例外（扩展→第三方被视作 same-site 的前提：有 host permission + 第三方 cookie 未被拦）见 <https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies> |
| C7 | **HTTP/1.1 连接池上限 6**（`kNormal`；WebSocket 255）—— 即"**同域并发连接 6 条**"这一常识的源码出处 | `std::array<size_t, kSocketPoolTypesSize> g_max_sockets_per_group = std::to_array<size_t>({ 6, // kNormal  255 // kWebSocket });` <https://chromium.googlesource.com/chromium/src/+/main/net/socket/client_socket_pool_manager.cc>（注：常量名是 `per_group`，group 的精确构成 = host/port/proxy 链的分组，本次**未逐行核对该定义**，故只落"6 这个数值来自该常量"） |
| C8 | **HTTP/2 下单连接多路复用**：并发上限由服务端 `SETTINGS_MAX_CONCURRENT_STREAMS` 决定（建议 ≥100），所有流共享同一条 TCP 的流控 | RFC 9113 §5.1.2/§5.2/§6.5.2 <https://www.rfc-editor.org/rfc/rfc9113.txt> |
| C9 | **FSA 随机写要用户手势**（transient user activation + secure context），写的是**临时文件，`close()` 才落盘**，且大文件慢 | <https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker> ；<https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream/write> ；<https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system> |
| C10 | **OPFS 高性能随机写只能在 Dedicated Worker**（且独占锁）；**OPFS 对用户不可见**，要交付必须整份拷贝出去 | <https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle/createSyncAccessHandle> ；<https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system> |
| C11 | **`chrome.downloads` 不能按 offset 写、不能读回数据、不能自选任意路径** | <https://developer.chrome.com/docs/extensions/reference/api/downloads> ；并由 DTA 的经验陈述交叉印证 <https://github.com/downthemall/downthemall/blob/master/Readme.md> |
| C12 | **多个扩展改同一个头时只有"最近安装的"生效，其余被静默忽略** | <https://developer.chrome.com/docs/extensions/reference/api/webRequest>（*"Only one extension can redirect a request or modify a header at a time … the most recently installed extension wins"*） |
| C13 | **浏览器下载器不经过 DNR 的请求头修改（社区报告，未获官方确认）** | 见 §8；与 `concept-design.md` 附录 A 的用户结论一致 |

---

## 5 对本项目的可用性判断（能否借鉴 / 能否直接用 / 需要改造成什么）

> 前提回顾（`concept-design.md`）：我们是**在浏览器里冒充 aria2 RPC 服务端**（R1/R6/R8），外部前端（AriaNg 等）把 `aria2.addUri` 发给我们，**请求不会经过真实网络**（R9）。因此"cookie 从哪来"与"cookie 送给谁"和 A-7 的情形**不同**。

### 5.1 需求 A：可借鉴的结论

| 判断 | 内容 |
|---|---|
| **可直接借鉴（几乎照搬）** | ① `chrome.cookies.getAll({url, storeId})`（+`partitionKey` 容错）拿目标 URL 的全部 cookie（**含 HttpOnly**）的写法；② 拼 `Cookie: k=v; k2=v2` 的写法；③ 明确"浏览器请求里塞不了 Cookie 头，所以必须换通路"。证据：A-7.1/A-7.3 的源码 + C1/C2/C3 |
| **必须改造的一点（与 A-7 的本质差异）** | A-7 的最后一步是"**把 Cookie 交给 aria2c，让 aria2c 发**"；我们是"**只能在浏览器里发**"。于是有且只有三种落地方式：<br>① **DNR `modifyHeaders`**（`append`/`set` on `cookie`）把读到的 cookie 注入浏览器发出的那个请求（**唯一能自定义 Cookie 头的浏览器内通路**）；<br>② **让浏览器自己发**（`chrome.tabs` 打开 URL / 触发下载，浏览器用它自己那份 cookie，HttpOnly 天然覆盖）——附录 A 走的就是这条；<br>③ **扩展 SW 的 `fetch(credentials:'include')`** 自己下（有 host permission 时最接近"浏览器自带 cookie 语义"，还能拿到响应体做进度/校验，代价见需求 B）。 |
| **对 Mock 层语义的影响** | 入站 RPC 里客户端（AriaNg/YAAW 风格）**可能自带 `header` 参数**（含 `Cookie:`）——这部分我们可以**直接采用**（既不违反 C1，也不违反 C2，因为最终由 DNR/浏览器负责落地）。这条能显著提升 `withHeader` 能力的"真实还原"比例：**入站 header 的语义可还原，只是落地通路受限** |
| **不能做** | ① 不能用 `chrome.downloads.download({headers})` 传 cookie（C2）；② 不能拿 `document.cookie` 当 cookie 源（拿不到 HttpOnly，且需页面上下文）；③ 不能承诺"任意 header 都能注入"——DNR 请求头 `append` 只允许白名单内（`cookie`/`range`/`user-agent`…），**白名单外的 header 只能用 `set`**（解析期不拦），而 `set` 的实际生效范围/与浏览器自带头的冲突**本轮未验证**（§8） |

### 5.2 需求 B：可借鉴的结论

| 判断 | 内容 |
|---|---|
| `split` / `max-connection-per-server` 能不能**真实还原** | **不能**（在当前浏览器 API 下）。要么"另开多条 `fetch` 分片 + 自己写盘 + 自己出口"，要么退化为单流。证据：C9/C10/C11 + B-2/B-3 的厂商结论 |
| 若坚持自建多连接，需要的最小机制（全部有证据支持） | ① 多路 `Range` 请求（可发，见 B-9(a) 表首行）；② 随机定位写盘：**OPFS + Dedicated Worker `createSyncAccessHandle({at})`**（性能最好、无用户手势、可续传；代价：不可见 + 需整份导出）**或** FSA `createWritable` + `write({position})`（用户可见但需手势 + 临时文件语义 + Firefox 无）；③ 校验：`crypto.subtle.digest`（**只有自建通路才拿得到数据**）；④ 导出：`File` → Blob URL → `chrome.downloads` / `showSaveFilePicker`（注意 FileSaver 的 2GB/内存与"整份拷贝"代价） |
| 若要**省事** | 直接用 `chrome.downloads` 单流，`split>1` 与 `max-connection-per-server>1` 走 **R3「伪装还原」**（R10：结果兑现即可）——但**不能伪造进度曲线**：`chrome.downloads` 能给出 `bytesReceived/totalBytes` 真实进度（Q-B7 已有裁定：能拿到真进度就报真进度） |
| 对能力的映射建议（供后续「能力清单」输入） | `multithread = false`（单流引擎）；若要声明 `true`，则必须绑定"OPFS/FSA 自建通路"这一整套前置条件（用户手势、Worker、导出步骤、磁盘 2×），并把它写进能力报告（R13-3） |
| 与 WebTorrent 的对照 | 它是浏览器里**唯一实际落地的"多分片 + 随机访问 + 落地"** 范式：片在内存/handle，随机访问靠 SW 的 Range 端点对外服务（B-5）。**如果哪天要把 `split` 做成真实还原，这是最接近的参照物**，但它的"出口"是虚拟 HTTP 服务，不是"交给浏览器下载器" |

---

## 6 失败模式与盲区

| # | 失败模式 | 依据 / 说明 |
|---|---|---|
| F1 | **以为能手动加 `Cookie` 头** → `fetch` 静默丢弃该头或报错 | C1 |
| F2 | **以为 `chrome.downloads({headers})` 能带 cookie** → 直接 `kInvalidHeaderUnsafe` 报错 | C2 |
| F3 | **跨源 `fetch` 没写 `credentials:'include'`** → 一个 cookie 都不带（默认 `same-origin`） | C5 |
| F4 | **目标站点无 CORS 头** → 跨源带凭据的 `fetch` 拿不到响应体（下载型站点普遍如此） | C5 |
| F5 | **`SameSite=Strict` 的登录态在跨站 `fetch` 场景丢失** → 下载到登录页 | C6（扩展内例外：有 host permission 且第三方 cookie 未被拦时才可能带上） |
| F6 | **第三方 cookie 被拦 / CHIPS 分区** → 拿不到或拿错 cookie；`chrome.cookies.getAll` 需分 `partitionKey` 取一次 | A-7.1 源码（两路 `getAll` + try/catch）；Chrome 文档 *"does not apply if third-party cookies are blocked"* |
| F7 | **DNR 规则安装失败被当成"没生效"** → 请求头 `append` 不在白名单时报 `ERROR_APPEND_INVALID_REQUEST_HEADER`（规则根本装不上） | C4 源码 |
| F8 | **与其它扩展抢同一个头** → 只有最近安装的扩展生效，其余静默忽略（无任何提示） | C12 |
| F9 | **浏览器内置下载器不经过 DNR 请求头修改**（附录 A 的前提）→ 用 `chrome.downloads` 注入头会"看不出任何错误地失败" | C13（社区报告 + 用户样例，**未获官方确认**） |
| F10 | **RPC 客户端把浏览器 cookie 当"用户态数据"** → 客户端传的 `header` 参数与浏览器实际发出的头不一致（重复/覆盖），服务器侧看到两个 Cookie | DNR `append` 语义（追加，`"; "` 分隔）vs `set`（覆盖）——需要 Mock 层按 R3 明确裁定 |
| F11 | **多连接方案里的"临时存储重拼"** → 存储限额/清理导致失败；DTA 明确说不可靠 | B-2 |
| F12 | **FSA 授权丢失** → `NotAllowedError`（*"Thrown if PermissionStatus.state is not granted"*）；跨重启续写未验证 | C9 |
| F13 | **OPFS 被清空/驱逐** → *"Clearing storage data for the site deletes the OPFS"*；扩展需 `unlimitedStorage` | C10 + Chrome 文档 |
| F14 | **HTTP/2 下"多连接"退化**：服务端只给少量并发流，或拥塞窗口成为瓶颈 → 分片不比单流快，甚至更慢（大量请求 + 单连接竞争） | C8 |
| F15 | **服务器不支持 Range** → 分片方案必须回退单流（TDM 的 `simple-mode`），否则 206 断言失败 | B-1 |
| F16 | **`Content-Encoding` 非空** → TDM 直接放弃分片（gzip 传输的内容无法按原始偏移拼） | B-1 |
| F17 | **拦截盲区 × cookie 的组合**：SW 生命周期、`chrome://`、扩展页 CSP 等（Q-D2 已列）会命中"引擎拿不到 cookie 或发不出请求"的路径 | `concept-design.md` Q-D2；本次补充：C3/C4 决定"注入通路唯一" |
| F18 | **下载落盘位置不可控**：`chrome.downloads` 只能写进默认下载目录（Chrono 原文；`filename` 是相对路径），与 aria2 的 `dir` 语义无法对齐（R3 需裁定） | B-3 + B-10 |
| F19 | **大文件内存爆掉**（FileSaver 路线 / 纯内存分片合并） | B-8：Chrome Blob 上限 2GB、Android RAM/5 |
| F20 | **进度语义冲突**：自建多连接时进度可精确上报（字节级），但浏览器下载器路线只有 `bytesReceived`；若两者混用，AriaNg 侧速度/ETA 会出现台阶 | Q-B7 裁定 + B-10 |

---

## 7 与现有裁定的冲突（逐条对照 R1–R13 与附录 A）

| 裁定 | 本次调研的对照结论 | 证据 |
|---|---|---|
| **R1**（免安装 aria2、把请求转接到浏览器下载能力） | **不冲突，但能力上限被本次调研钉死**：能拿到 cookie 也能注入 cookie，但**多连接传输**在浏览器内只能"自建 + 自写盘 + 自导出"，或退回单流 | §5.2；B-2/B-3 |
| **R2**（不支持就报错，不假装） | **强化**：`multithread` 若为 false，收到 `split>1` 必须按 R3 裁定（伪装还原或报错），不能"接受了但只下一条连接还不说" | R3/Q-B4 |
| **R3**（三值语义） | 本次给出两个具体落点：① `multithread`：**无法真实还原**（除非接受 OPFS/FSA 一整套前置）；② `withHeader`：**部分可真实还原**（入站 header 语义可保留；`cookie` 可经 DNR 注入；但 `referer`/`user-agent` 等要看 DNR 的 `set` 实际行为——MV2 的 `webRequest` 路线在 MV3 已不可用） | C2/C4；`concept-design.md` 附录 A |
| **R4.1**（尽可能多途径拦截） | **新增一条盲区**：DNR 改头是**网络层**行为，与 R9 的"JS 层短路"互相独立——我们的拦截命中后请求根本不发出，因此**"带 cookie"不会自然发生**；反过来，若某个引擎改用"真下载"，就必须处理 C1–C12 全套约束 | R9 + C1–C12 |
| **R5**（内置 UI 不走特殊通道） | 无冲突；但注意内置 AriaNg 若要从 `document.cookie` 拼 `header`，**只能拿到非 HttpOnly**（C3） | C3 |
| **R6 / R7**（Mock 层逐接口；引擎声明能力） | **建议**：把"cookie 来源"拆成独立原子能力（如 `withCookieFromBrowser`）与"header 注入"分离，因为二者可行域不同（读 cookie 可行；写任意 header 不可行） | §5.1 |
| **R8**（只服务浏览器内 JS 客户端） | 无冲突；反而说明"入站请求可能自带 `header` 参数"，我们**不需要自己造 cookie** 也能覆盖一部分场景 | A-7.3 源码（YAAW 传 `header`） |
| **R9**（JS API 层短路） | **重要提醒**：R9 让 CORS/混合内容/证书不适用，但**不会**让 cookie 问题消失——cookie 只在"引擎真的发请求"时才出现，届时 C1–C12 全部生效 | C1–C12 |
| **R10**（伪装还原判据 = 结果兑现） | **可直接套用**：单流引擎把 `split>1` 伪装还原为单流，文件真的下下来 ⇒ 合规；反之"接受了多连接请求但最终拿不到文件"才违规 | R10 |
| **R11**（能力是 bool 原子能力） | `multithread` 的 bool 语义在浏览器里**代价极高**（要绑定用户手势/Worker/导出/2× 磁盘）；建议能力清单里同时给出"前置条件"字段，否则 bool 会撒谎（Q-B8 已知代价） | §5.2 |
| **R12**（同时只启用一个引擎） | 无冲突；但"多引擎"若要覆盖"有 cookie / 无 cookie / 多连接 / 单连接"四象限，需要至少 2 个引擎（浏览器下载器型 + 自建 fetch 型） | §5 |
| **R13**（引擎可配置项） | `chrome.cookies` 需要 `cookies` + host permissions ⇒ **权限申请必须进"能力报告/用户可见"范围**（R13-3）；`unlimitedStorage` 同理 | C3 + OPFS 配额文档 |
| **附录 A（`chrome.tabs` + 两条 DNR）** | **与本次证据一致**：① A.3 的理由（`chrome.downloads` 不支持敏感 header）**有源码级证据支持**（C2）；② A.3 的另一半（"downloads 触发的下载无视改请求头的 DNR"）**只有社区级证据**，官方文档未提 ⇒ 建议后续做一次实测复核（§8）；③ 本次**补充**一条可选通路：DNR 可以直接 `append`/`set` `cookie`（Chrome 白名单含 `cookie`，分隔符 `"; "`），也就是说"注入 cookie"未必要靠"让浏览器用它自己的 cookie"，可以把**从 `chrome.cookies` 读到的值**显式注入 | C2/C4 + A-7.1 |
| **§6 已接受风险 4（拦截盲区）** | 本次**新增两类盲区**：① DNR 规则安装失败是**静默**的（`ERROR_APPEND_INVALID_REQUEST_HEADER` 只在安装 API 返回时可见）；② 多扩展改头冲突时**只有最近安装者生效**（无通知） | C4 源码 + C12 |
| **Q-B7（进度姿态）** | 与 B-10 一致：`chrome.downloads` 能提供真实进度 ⇒ 该路径应报真实进度，不伪造 | chrome.downloads 文档字段 |

---

## 8 未验证 / 存疑

> 以下条目**没有**官方文档或源码级证据，禁止当作结论使用。

1. **DNR 是否真的不作用于 `chrome.downloads` 发起的请求**：Chrome 文档未提；只找到一条社区问答（标题即结论："Chrome Downloads API http requests are not getting modified by Declarative Net Request API"，2024-02-03，提问者描述"fetch 请求被正常修改，`chrome.downloads.download()` 的请求没有被修改；而从 DOM 触发下载则会被修改"）：<https://stackoverflow.com/questions/77932227/chrome-downloads-api-http-requests-are-not-getting-modified-by-declarative-net-request-api> **（403 于抓取时出现，题面经 Stack Exchange API 取得；无权威回答）** —— 与 `concept-design.md` 附录 A 的用户结论一致，但**未获官方确认**。
2. **从扩展发起的"顶层导航（`chrome.tabs.create`）"是否携带 `SameSite=Strict` cookie**：文档只给了"扩展→第三方网络请求在有 host permission 时被视作 same-site"的规则（适用于扩展发出的请求），**没有**明确回答"扩展新建标签页的导航请求"是否落在这条规则内。需实测。
3. **`chrome.downloads` 发出的请求是否自带目标站点 cookie**：文档无任何说明（无 `credentials` 概念）。推测走 profile cookie store，但**未验证**。
4. **`chrome.downloads.download({headers})` 里的 `Range` 是否被 honor**：`Range` 不在禁用列表（C2），但下载器是否会因此发 206 分片、是否能拼回整文件，**未知**。
5. **`showSaveFilePicker` / `createWritable` 在扩展 SW 或 offscreen document 中的可用性**：MDN 明确它属于 `Window`（*"Windows: showSaveFilePicker() method"*），扩展侧行为未验证。
6. **OPFS 在 MV3 service worker 中的可用性**（`navigator.storage.getDirectory()` / `getFileHandle`）：MDN 只写 *"This feature is available in Web Workers"*，未区分 SW/Dedicated Worker；`createSyncAccessHandle` 已明确仅 Dedicated Worker（C10）。
7. **`chrome.downloads.resume()` 是否依赖服务器支持字节范围**：文档仅写 *"Resume a paused download … The request will fail if the download is not active."* 与 `canResume` 字段，未提 Range。
8. **`Cookie` 通过 DNR 注入时的实际生效范围**：`append` 有白名单与 `"; "` 分隔符（源码级），但 `set`（覆盖）与浏览器自身 Cookie 头的合并顺序、以及是否对**扩展自身发起的 `fetch`** 生效，均未验证。
9. **AriaNg / 其它 aria2 前端的 cookie 处理**：本轮未抓源码；已知 YAAW 风格前端会把 `header`（含 `Cookie:`）交给 aria2，但**AriaNg 是否从 `document.cookie` 取值、取哪些**未验证。
10. **Chrome 稳定版号 / 应用版本**：本次所有 Chrome 文档均为在线最新版，文档内最高版本标记为 `Chrome 148`（`browser.*` 命名空间），但**未确认调研当日 Chrome 稳定版号**。复检时请以当日版本为准。
11. **hls.js / dash.js 的"分片并发度"具体配置**：本次在 hls.js 源码（`master`）检索未发现并发度配置项，**不下结论**。
12. **Firefox 侧**：`chrome.cookies` 的等价能力（`browser.cookies`）与 `declarativeNetRequest` 的 `append` 白名单是否一致（MDN 的 Header limits 提到 Firefox 侧另有 `Host` 规则）——未逐条核对。
13. **Safari**：完全未覆盖。
14. **实测缺失**：本报告全部为文档/源码级调研，**没有在本机浏览器里做过一次真实请求验证**（包括 HttpOnly cookie 的注入效果、DNR 的 append 效果、OPFS 的吞吐）。建议在详细设计前补一轮最小实测。

---

## 9 证据清单（URL + 原文摘录）

> 摘录保持英文原文（含原文中的拼写错误），中文为本文的转述。**加粗**为本文最关键的证据点。

### 9.1 规范 / MDN

| # | 来源 | 原文摘录 |
|---|---|---|
| E1 | WHATWG Fetch — forbidden header name<br><https://fetch.spec.whatwg.org/#forbidden-header-name> | *"A header (name, value) is forbidden request-header if these steps return true: If name is a byte-case-insensitive match for one of: `Accept-Charset` … **`Cookie`** … then return true. … These are forbidden so the user agent remains in full control over them."* |
| E2 | MDN — Forbidden request header<br><https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header> | *"A **forbidden request header** is an HTTP header name-value pair that cannot be set or modified programmatically in a request."*（列表含 `Cookie`；`User-Agent` 已解禁但 Chrome 仍丢弃，见 crbug 571722） |
| E3 | WHATWG Fetch — CORS-safelisted request-header<br><https://fetch.spec.whatwg.org/#cors-safelisted-request-header> | *"`range` Let rangeValue be the result of parsing a single range header value given value and false. … As web browsers have historically not emitted ranges such as `bytes=-500` this algorithm does not safelist them."*；另：*"A privileged no-CORS request-header name is a header name that is a byte-case-insensitive match for one of `Range`. … `Range` headers are commonly used by downloads and media fetches."* |
| E4 | MDN — `RequestInit.credentials`<br><https://developer.mozilla.org/en-US/docs/Web/API/RequestInit> | *"`include` Always include credentials, even for cross-origin requests. Including credentials in cross-origin requests can make a site vulnerable to CSRF attacks, so even if `credentials` is set to `include`, the server must also agree to their inclusion by including the `Access-Control-Allow-Credentials` in its response. Additionally, in this situation the server must explicitly specify the client's origin in the `Access-Control-Allow-Origin` response header (that is, `*` is not allowed)."* / *"Defaults to `same-origin`."* |
| E5 | MDN — `Set-Cookie`（SameSite / HttpOnly）<br><https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie> | *"`Strict` Send the cookie only for requests originating from the same site that set the cookie."* / *"`Lax` Send the cookie only for requests originating from the same site that set the cookie, and for cross-site requests that meet both of the following criteria: The request is a top-level navigation … This would exclude, for example, requests made using the `fetch()` API …"* / *"**`HttpOnly`** Forbids JavaScript from accessing the cookie, for example, through the `Document.cookie` property. **Note that a cookie that has been created with HttpOnly will still be sent with JavaScript-initiated requests, for example, when calling XMLHttpRequest.send() or fetch().**"* |
| E6 | RFC 9113（HTTP/2）<br><https://www.rfc-editor.org/rfc/rfc9113.txt> | §6.5.2 *"SETTINGS_MAX_CONCURRENT_STREAMS (0x03): This setting indicates the maximum number of concurrent streams that the sender will allow. This limit is directional … **It is recommended that this value be no smaller than 100**, so as to not unnecessarily limit parallelism."*；§5.2 *"Using streams for multiplexing introduces contention over use of the TCP connection, resulting in blocked streams. … Flow control is used for both individual streams and the connection as a whole."*；§5.1.2 *"Endpoints MUST NOT exceed the limit set by their peer."* |
| E7 | MDN — `FileSystemWritableFileStream`<br><https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream> | *"`FileSystemWritableFileStream.seek()` Updates the current file cursor offset to the position (in bytes) specified." / "`truncate()` Resizes the file associated with the stream to be the specified size in bytes."* |
| E8 | MDN — `FileSystemWritableFileStream.write()`<br><https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream/write> | *"**No changes are written to the actual file on disk until the stream has been closed. Changes are typically written to a temporary file instead.**"* / *"`position` The byte position the current file cursor should move to if type `"seek"` is used. **Can also be set if type `"write"`, in which case the write will start at the specified position.**"* / 异常：*"`NotAllowedError` Thrown if PermissionStatus.state is not granted."* |
| E9 | MDN — `createSyncAccessHandle()`<br><https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle/createSyncAccessHandle> | *"**Note: This feature is only available in Dedicated Web Workers.** … it is only usable inside dedicated Web Workers for files within the origin private file system. **Creating a FileSystemSyncAccessHandle takes an exclusive lock on the file** … This prevents the creation of further `FileSystemSyncAccessHandle`s or `FileSystemWritableFileStream`s for the file until the existing access handle is closed."* |
| E10 | MDN — Origin private file system<br><https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system> | *"The OPFS offers low-level, byte-by-byte file access, which is private to the origin of the page and **not visible to the user**."* / *"**Browsers persist the contents of the OPFS to disk somewhere, but you cannot expect to find the created files matched one-to-one. The OPFS is not intended to be visible to the user.**"* / *"These changes are being made to the user-visible file system … **These writes are not in-place, and instead use a temporary file.** … As a result, these operations are fairly slow."* / *"The OPFS is subject to browser storage quota restrictions … Clearing storage data for the site deletes the OPFS."* |
| E11 | MDN — `showSaveFilePicker()`<br><https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker> | *"**Transient user activation is required.** The user has to interact with the page or a UI element in order for this feature to work."* / *"Secure context"* / *"Limited availability — This feature is not Baseline because it does not work in some of the most widely-used browsers."* |
| E12 | MDN — Media Source Extensions API<br><https://developer.mozilla.org/en-US/docs/Web/API/Media_Source_Extensions_API> | *"MSE gives us finer-grained control over how much and how often content is fetched, and some control over memory usage details, such as when buffers are evicted. It lays the groundwork for adaptive bitrate streaming clients (such as those using DASH or HLS) to be built on its extensible API."* / *"Starting with Chrome 108, MSE features are available in dedicated web workers"* |
| E13 | MDN — `downloads.download()`（WebExtensions，Firefox 视角）<br><https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/downloads/download> | *"`headers` … **The headers that are forbidden by XMLHttpRequest and fetch cannot be specified**, however, Firefox 70 and later enables the use of the Referer header. **Attempting to use a forbidden header throws an error.**"* |
| E14 | MDN — `declarativeNetRequest.ModifyHeaderInfo`<br><https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest/ModifyHeaderInfo> | *"**Header limits** In Chrome, `"append"` is supported for the following request headers: Accept, Accept-Encoding, Accept-Language, Access-Control-Request-Headers, Cache-Control, Connection, Content-Language, **Cookie**, Forwarded, If-Match, If-None-Match, Keep-Alive, **Range**, Te, Trailer, Transfer-Encoding, Upgrade, Via, Want-Digest, X-Forwarded-For"* |

### 9.2 Chrome 官方文档

| # | 来源 | 原文摘录 |
|---|---|---|
| E15 | chrome.cookies 参考<br><https://developer.chrome.com/docs/extensions/reference/api/cookies> | *"To use the cookies API, declare the `"cookies"` permission in your manifest along with **host permissions for any hosts whose cookies you want to access**."* / `getAll()`：*"**This method only retrieves cookies for domains that the extension has host permissions to.**"* / `Cookie.httpOnly`：*"True if the cookie is marked as HttpOnly (i.e. the cookie is inaccessible to client-side scripts)."* |
| E16 | Storage and cookies<br><https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies> | *"For cookies associated with third-party sites, such as for a third-party site loaded in a frame on an extension page, or a request made from an extension page to a third-party origin, cookies behave the same as the web except in two ways: … **Requests from an extension to a third-party are treated as same-site if the extension has host permissions for the third-party. This means `SameSite=Strict` cookies can be sent.** Note that this only applies to network requests, not access through `document.cookie` in JavaScript, and **does not apply if third-party cookies are blocked**."* / *"Request the `"unlimitedStorage"` permission, which affects both extension and web storage APIs and exempts extensions from both quota restrictions and eviction."* |
| E17 | Cross-origin network requests<br><https://developer.chrome.com/docs/extensions/develop/concepts/network-requests> | *"Content scripts initiate requests on behalf of the web origin that the content script has been injected into and therefore content scripts are also subject to the same origin policy. … **Cross-origin requests are always treated as such in content scripts, even if the extension has host permissions.**"* / *"Extension origins aren't so limited. A script executing in an extension service worker or foreground tab can talk to remote servers outside of its origin, as long as the extension requests host permissions."* |
| E18 | chrome.downloads 参考<br><https://developer.chrome.com/docs/extensions/reference/api/downloads> | `DownloadOptions.headers`：*"Extra HTTP headers to send with the request if the URL uses the HTTP[s] protocol. Each header is represented as a dictionary containing the keys `name` and either `value` or `binaryValue`, **restricted to those allowed by XMLHttpRequest**."* / `DownloadItem.canResume`：*"True if the download is in progress and paused, or else if it is interrupted and can be resumed starting from where it was interrupted."* / `resume()`：*"Resume a paused download. … The request will fail if the download is not active."* / `filename`：*"A file path relative to the Downloads directory"* |
| E19 | declarativeNetRequest 参考<br><https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest> | *"Header modification — **The `append` operation is only supported for the following request headers: accept, …, cookie, …, range, …** This allowlist is case sensitive (bug 449152902). **When appending to a request or response header, the browser will use the appropriate separator where possible.**"*；示例规则：*"The following example removes all cookies from both a main frame and any sub frames. `{ … "requestHeaders" : [{ "header" : "cookie" , "operation" : "remove" }] … }`"* |
| E20 | chrome.webRequest 参考<br><https://developer.chrome.com/docs/extensions/reference/api/webRequest> | *"**As of Manifest V3, the `"webRequestBlocking"` permission is no longer available for most extensions.** Consider `"declarativeNetRequest"` … Policy installed extensions can continue to use `"webRequestBlocking"`."* / *"`webRequestBlocking` Required to register blocking event handlers. As of Manifest V3, this is only available to policy installed extensions."* / *"**Only one extension can redirect a request or modify a header at a time.** If more than one extension attempts to modify the request, the most recently installed extension wins, and all others are ignored. An extension is not notified if its instruction to modify or redirect has been ignored."* |

### 9.3 Chromium 源码（决定"到底能不能"的证据）

| # | 来源 | 原文摘录 |
|---|---|---|
| E21 | `extensions/browser/api/cookies/cookies_helpers.cc`<br><https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/cookies/cookies_helpers.cc> | `GetCookieListFromManager()`：`manager->GetCookieList(url, net::CookieOptions::MakeAllInclusive(), …)` ⇒ **扩展 cookies API 用"全包含"选项请求 Cookie 列表** |
| E22 | `net/cookies/cookie_options.h`<br><https://chromium.googlesource.com/chromium/src/+/main/net/cookies/cookie_options.h> | `// Convenience method for where you need a CookieOptions that will work for getting/setting all types of cookies, **including HttpOnly and SameSite cookies**. … static CookieOptions MakeAllInclusive();`（默认字段 `bool exclude_httponly_ = true;`） |
| E23 | `extensions/browser/api/cookies/cookies_api.cc`<br><https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/cookies/cookies_api.cc> | `net::CookieOptions options; options.set_include_httponly(); options.set_same_site_cookie_context(net::CookieOptions::SameSiteCookieContext::MakeInclusive());` ⇒ **写入路径同样显式包含 HttpOnly** |
| E24 | `chrome/browser/extensions/api/downloads/downloads_api.cc`<br><https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/extensions/api/downloads/downloads_api.cc> | `if (options.headers) { for (…) { if (!net::HttpUtil::IsValidHeaderName(header.name)) return RespondNow(Error(kInvalidHeaderName)); **if (!net::HttpUtil::IsSafeHeader(header.name, header.value)) return RespondNow(Error(kInvalidHeaderUnsafe));** …` |
| E25 | `net/http/http_util.cc`<br><https://chromium.googlesource.com/chromium/src/+/main/net/http/http_util.cc> | `// A header string containing any of the following fields will cause an error. The list comes from the fetch standard. const char* const kForbiddenHeaderFields[] = { …, "content-length", **"cookie"**, "cookie2", …, "origin", **"referer"**, "set-cookie", …, **"user-agent"**, "via", };` ⇒ `chrome.downloads` 无法设置 cookie/referer/user-agent；**列表中没有 `range`** |
| E26 | `net/socket/client_socket_pool_manager.cc`<br><https://chromium.googlesource.com/chromium/src/+/main/net/socket/client_socket_pool_manager.cc> | `std::array<size_t, kSocketPoolTypesSize> g_max_sockets_per_group = std::to_array<size_t>({ **6, // kNormal** 255 // kWebSocket });` |
| E27 | `extensions/browser/api/declarative_net_request/constants.h`<br><https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/declarative_net_request/constants.h> | `// An allowlist of request headers that can be appended onto, in the form of (header name, header delimiter). … inline constexpr auto kDNRRequestHeaderAppendAllowList = … {{"accept", ", "}, … **{"cookie", "; "}**, …, {"user-agent", " "}, …};` |
| E28 | `extensions/browser/api/declarative_net_request/indexed_rule.cc`<br><https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/declarative_net_request/indexed_rule.cc> | `if (are_request_headers && header_info.operation == dnr_api::HeaderOperation::kAppend) { … if (!kDNRRequestHeaderAppendAllowList.contains(base::ToLowerASCII(header_info.header))) { return ParseResult::**ERROR_APPEND_INVALID_REQUEST_HEADER**; } }` ⇒ **仅 append 受限；`set`/`remove` 不受该白名单限制** |

### 9.4 现成方案（源码 / README / 商店页）

| # | 来源 | 原文摘录 / 关键代码 |
|---|---|---|
| E29 | Aria2 Explorer — 清单<br><https://github.com/alexhua/Aria2-Explorer/blob/master/manifest.json> | `"manifest_version": 3, "version": "2.8.3", "permissions": ["cookies","tabs","notifications","contextMenus","downloads","storage","scripting","sidePanel","power"], "host_permissions": ["<all_urls>"]` |
| E30 | Aria2 Explorer — `background.js` L110–L154<br><https://github.com/alexhua/Aria2-Explorer/blob/master/background.js#L110-L154> | `async function getCookies(downloadItem) { … let cookies = await chrome.cookies.getAll({ url, storeId }); … partitionedCookies = await chrome.cookies.getAll({ url, storeId, partitionKey: {} }); … const cookieMap = new Map([...cookies, ...partitionedCookies].map(cookie => [cookie.name, cookie.value])); … cookieItems.push(name + "=" + value); }` / `if (cookieItems.length > 0) { headers.push("Cookie: " + cookieItems.join("; ")); } headers.push("User-Agent: " + navigator.userAgent); … options.header = headers; … return aria2.addUri(downloadItem.url, options)` |
| E31 | YAAW for Chrome — 清单 + `background.js` L114–L134<br><https://github.com/acgotaku/YAAW-for-Chrome/blob/master/manifest.json> / <https://github.com/acgotaku/YAAW-for-Chrome/blob/master/background.js#L114-L134> | `"manifest_version": 3, "version": "1.0.0", "permissions": ["cookies","notifications","tabs","contextMenus","downloads","storage"], "host_permissions": ["<all_urls>"]` / `chrome.cookies.getAll({ url: fileDownloadInfo.link }, function (cookies) { … header.push('Cookie: ' + formatedCookies.join('; ')); header.push('User-Agent: ' + navigator.userAgent); … method: 'aria2.addUri', params: [[link], { header }] … })` |
| E32 | Aria2 for Chrome<br><https://github.com/alexhua/Aria2-for-chrome> | 同一作者、同一 `2.8.3`/MV3 清单，`background.js` 取 cookie/传 `header` 的代码与 E30 一致（clone 到 `master`，最后提交 2026-10-06） |
| E33 | Cookie-Editor（旁证：扩展可读写 HttpOnly）<br><https://github.com/Moustachauve/cookie-editor> | `interface/popup/cookie-list.js`：`if (httpOnly !== undefined) { cookie.httpOnly = httpOnly; }`；`interface/options/options.html`：`<option value="httponly">Http Only</option>`（`master`，最后提交 2026-08-14） |
| E34 | Turbo Download Manager — 分片逻辑 `src/lib/wget.js`<br><https://github.com/inbasic/turbo-download-manager/blob/master/src/lib/wget.js> | `obj.headers.Range = `bytes=${range.start}-${range.end}`` / `if (res.status && res.status !== 206 && obj.headers.Range) { throw new utils.CError(`expected 206 but got ${res.status}`, 1, …) }` / `'multi-thread': !!length && contentEncoding === null && req.getResponseHeader('Accept-Ranges') === 'bytes' && lengthComputable !== 'false'` / `obj.writer(range, {offset, buffer})` |
| E35 | TDM — 写盘实现 `src/lib/chrome/chrome-cm.js` L320–L357<br><https://github.com/inbasic/turbo-download-manager/blob/master/src/lib/chrome/chrome-cm.js#L320-L357> | `app.fileSystem = { file: { … write: function (file, offset, arr) { return new Promise(… file.createWriter(function (fileWriter) { … **fileWriter.seek(offset); fileWriter.write(blob);** } …` / `truncate: … fileWriter.truncate(bytes)` / `root.internal: navigator.webkitTemporaryStorage.requestQuota(bytes, …) window.requestFileSystem(window.TEMPORARY, bytes, …)` / `root.external: chrome.fileSystem.restoreEntry(storage.folder, …)` |
| E36 | TDM — 扩展构建退化为浏览器下载器 `src/lib/opera/opera.js`<br><https://github.com/inbasic/turbo-download-manager/blob/master/src/lib/opera/opera.js> | `/* app.download */ app.download = (obj) => chrome.downloads.download({ url: obj.url, filename: obj.name });` |
| E37 | TDM（Classic）商店页<br><https://chromewebstore.google.com/detail/turbo-download-manager-cl/kemfccojgjoilhfmcblgimbggikekjip> | *"a download manager with **multi-threading support**"* / *"1. Speeds up downloads (speed depends on the number of segments and your network capacity) …"* |
| E38 | DownThemAll! — `Readme.md`<br><https://github.com/downthemall/downthemall/blob/master/Readme.md> | L13 *"Being a WebExtension it lacks a ton of features the original DownThemAll! had. … **WebExtensions are extremely limited in what they can do.**"* / L17 *"… **we cannot do our own downloads any longer but have to go through the browser download manager always** …"* / L19 *"I spent countless hours evaluating various workarounds … From using `IndexedDB` to store retrieved chunks via `XHR`, to doing nasty service-worker tricks … The last one looks promising but I have yet to get it to work in a manner that is reliable, performs well enough and **doesn't eat all the system memory for breakfast**."* |
| E39 | DownThemAll! — `TODO.md`（P4）<br><https://github.com/downthemall/downthemall/blob/master/TODO.md> | *"**Segmented downloads** — Cannot be done with WebExtensions - downloads API has no support and manually downloading, storing in temporary add-on storage and reassmbling the downloaded parts later is not only efficient but does not reliabliy work due to storage limitations."* / *"**Checksums/Hashes?** — Cannot be done with WebExtensions - cannot actually read the downloaded data"* / *"**Mirrors?** — Cannot be done with WebExtensions - no low level APIs, see segmented downloads"* / *"**Metalink?** — Currently infeasible, as we cannot look into download data streams."*（原文拼写错误照录） |
| E40 | Chrono Download Manager 商店页<br><https://chromewebstore.google.com/detail/chrono-download-manager/mciiogijehkdemklbdcbfkefimifhecn> | *"KNOW ISSUES — **Chrono currently uses Chrome™'s built-in Downloads API, so it does not offer multi-threaded downloading capability** and has limited support for pausing and resuming a large download. All downloaded files can only be saved under Chrome™'s default downloads folder or any of its subdirectories."* |
| E41 | Free Download Manager 扩展商店页<br><https://chromewebstore.google.com/detail/download-with-free-downlo/jlodlegnpjplclncjkgolcmdhjmlokna> | *"Sends your downloading jobs to the Free Download Manager by pausing the built-in download manager"* / *"**Notes: 1. For the extension to work you need to have Free Download Manager (FDM) installed**; … **2. For the extension to be able to communicate with FDM, a small native client is required.**"* |
| E42 | WebTorrent — `docs/api.md`<br><https://github.com/webtorrent/webtorrent/blob/master/docs/api.md> | *"Create an http server to serve the contents of this torrent, dynamically fetching the needed torrent pieces to satisfy http requests. **Range requests are supported.** … `controller: ServiceWorkerRegistration // … Browser only. Required!`"* / *"`storeCacheSlots: Number, // Number of chunk store entries (torrent pieces) to cache in memory [default=20]`"* / *"`storeOpts.rootDir` — (browser only) `FileSystemDirectoryHandle` — if supported by the browser, allows the user to specify a custom directory to stores the files in, retaining the torrent's folder and file structure"* / *"`skipVerify: Boolean, // If true, client will skip verification of pieces for existing store and assume it's correct"* |
| E43 | StreamSaver.js — `README.md`<br><https://github.com/jimmywarting/StreamSaver.js/blob/master/README.md> | *"This is accomplish by emulating how a server would instruct the browser to save a file using some response header + service worker"* / *"**Handle unload event** when user leaves the page. **The download gets broken when you leave the page.**"* / *"… worker goes idle after 30 sec in firefox, 5 minutes in blink …"* / *"it's best that you initiate the `createWriteStream` on user interaction … so that you can get around the popup blockers"* |
| E44 | FileSaver.js — `README.md`<br><https://github.com/eligrey/FileSaver.js/blob/master/README.md> | *"If you need to save really large files bigger than the blob's size limitation or don't have enough RAM, then have a look at the more advanced **StreamSaver.js**"* / 兼容表：*"Chrome — Blob — Yes — 2GB"*、*"Firefox 20+ — Blob — Yes — 800 MiB"*、*"Chrome for Android — Blob — Yes — RAM/5"* |
| E45 | aria2 官方手册<br><https://aria2.github.io/manual/en/html/aria2c.html> | *"`--header=<HEADER>` Append HEADER to HTTP request header. You can use this option repeatedly to specify more than one header: `$ aria2c --header="X-A: b78" --header="X-B: 9J1" "http://host/file"`"* / *"`--load-cookies=<FILE>` Load Cookies from FILE using the Firefox3 format (SQLite3), Chromium/Google Chrome (SQLite3) and the Mozilla/Firefox(1.x/2.x)/Netscape format."* / *"Resume download started by web browsers or other programs: `$ aria2c -c -s2 "http://host/partiallydownloadedfile.zip"`"* |
| E46 | Stack Overflow（**社区证据，非权威**）<br><https://stackoverflow.com/questions/77932227/chrome-downloads-api-http-requests-are-not-getting-modified-by-declarative-net-request-api> | 标题即结论：*"Chrome Downloads API http requests are not getting modified by Declarative Net Request API"*；题面：*"All my HTTP requests to the external website using standard fetch are getting properly modified as expected. However, when I try to download a file using chrome's Downloads API, the download request is not getting modified and hence fails. … However, if I trigger the download from DOM, the request is getting modified properly."*（无权威回答） |

### 9.5 本项目内部依据（只读引用）

| # | 来源 | 用处 |
|---|---|---|
| E47 | `/workspace/docs/concept-design/concept-design.md` R1–R13、§5.2、§6、附录 A | §7 的逐条对照；附录 A 的 `chrome.tabs` + 两条 DNR 样例、A.3 "`chrome.downloads` 触发的下载会无视修改请求头的 DNR" |

---

*报告结束。凡本文与 `prior-cookie-b` 的报告分歧处，请优先复核 §9 中的 URL 原文。*
