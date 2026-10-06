# 需求导向既有方案调研 B：带 Cookie 下载 / 多线程下载（独立重复研究）

> 本文件是 `aria2-in-browser` 项目「浏览器技术边界测绘」的输入文档之一。
> 研究员：**prior-cookie-b**（与 prior-cookie-a 各自独立完成同一题目；本文件未参考对方的任何中间产物或结论）。
> 本文只做**既有方案调研**，不产出设计、不改任何代码。

---

## 0 元信息

| 项 | 值 |
|---|---|
| 调研日期 | **2026-10-06**（UTC，源文件抓取时间 2026-10-06 09:5x–10:1x UTC） |
| 主要适用浏览器 | **Chrome 桌面版（Manifest V3 / Chromium `main` @ 2026-10-06）**；Firefox 作为对照（DownThemAll 4.15.1 为 Firefox WebExtension，MDN 文档兼容 Firefox） |
| Chromium 源码基准 | `chromium.googlesource.com/chromium/src/+/main/...`（未固定 commit；引用时给出文件 URL） |
| 被调研对象的版本 | Aria2 Explorer **2.8.3**（MV3，`minimum_chrome_version: 116.0.0`，仓库最后提交 2026-10-06）；YAAW-for-Chrome **1.0.0**（MV3，最后提交 2026-06-13）；Turbo Download Manager（MV2，**最后提交 2017-02-21，已停更**）；DownThemAll WE **4.15.1**（MV2，最后提交 2026-05-27）；Get cookies.txt LOCALLY **0.7.2**（MV3）；ipull（最后提交 2025-05-28）；StreamSaver.js（最后提交 2026-07-30）；FileSaver.js（最后提交 2022-09-22） |
| 已读前置文档 | `/workspace/docs/concept-design/concept-design.md` v0.5（R1–R13、§5.2 裁定详情、§6 已接受风险、附录 A） |
| 调研方式 | 官方文档全文抓取 + Chromium/开源项目**源码**抓取（codeload tarball）+ 官方仓库 README/TODO 原文；不使用记忆性断言 |
| 证据标注 | `[官方文档]` / `[源码]` / `[第三方报告]`（非官方，仅作旁证） / `[未验证]`（查不到，明确列出） |

### 0.1 主要来源（完整 URL + 摘录见 §9）

**规范 / 浏览器官方文档**
- Fetch 语义与凭据：MDN `Request.credentials`、MDN *Using Fetch → Including credentials*、MDN `Access-Control-Allow-Credentials`、MDN `Set-Cookie`（SameSite）、MDN *Forbidden request header*、MDN `Cookie`（明确标注 Forbidden request header: Yes）
- 扩展上下文：Chrome *Storage and cookies*（**本文最关键的一页**）、Chrome *Cross-origin network requests*、Chrome *Service worker lifecycle*（SW 终止条件）、Chrome `chrome.cookies`、Chrome `chrome.downloads`、Chrome `chrome.declarativeNetRequest`、Chrome `chrome.debugger`、Chrome MV2 `chrome.webRequest`
- 落盘 / 多线程：MDN `Range`、`Accept-Ranges`、`206`、`If-Range`、`Content-Range`、`Response.body`、`FileSystemWritableFileStream`、`FileSystemFileHandle.createSyncAccessHandle`、`FileSystemSyncAccessHandle.write`、OPFS、`showSaveFilePicker`、`StorageManager.getDirectory`；RFC 9113（HTTP/2）
- 配额/手势策略：Chromium 企业策略 `FileOrDirectoryPickerWithoutGestureAllowedForOrigins.yaml`

**Chromium 源码（决定性证据）**
- `chrome/browser/extensions/api/downloads/downloads_api.cc`（`chrome.downloads.download({headers})` 的整流校验）
- `net/http/http_util.cc`（`kForbiddenHeaderFields`，含 `cookie`）
- `chrome/browser/extensions/api/downloads/download_extension_errors.h`（错误串 `"Unsafe request header name"`）
- `extensions/browser/api/cookies/cookies_api.cc`（`options.set_include_httponly()`、`GetAllCookiesFromManager`）
- `net/socket/client_socket_pool_manager.cc`（**每主机 6 连接**）
- `extensions/common/api/declarative_net_request.webidl`（`HeaderOperation` = append/set/remove）

**既有方案源码 / README**
- Aria2 Explorer `background.js`（cookie → aria2 `header`）
- YAAW-for-Chrome `background.js`（同型）
- Get cookies.txt LOCALLY（MV3 cookie 读 + 落盘导出）
- Turbo Download Manager `src/lib/wget.js`、`src/lib/opera/chrome-cm.js`、`src/lib/chrome/chrome-cm.js`、`src/lib/io.js`、`src/lib/config.js`
- DownThemAll WE `Readme.md`、`TODO.md`
- ipull `README.md`、`src/download/browser-download.ts`、`.../download-engine-fetch-stream-fetch.ts`
- StreamSaver.js / FileSaver.js / browser-fs-access / native-file-system-adapter 的 README
- aria2 官方手册（`split` / `max-connection-per-server` / `min-split-size` / `header` / `continue`）
- 第三方报告：Stack Overflow 77932227（`chrome.downloads` 请求不享 DNR 改头）

---

## 1 一句话结论

**需求 A（带 Cookie 下载）**：**有成熟解法，但不在"浏览器自己下载"这条路上**——成熟做法是"用扩展 API 把 cookie **读出来**，拼成 `Cookie:` 头，交给**外部 aria2** 的 `header` 选项"（Aria2 Explorer / YAAW-for-Chrome 都是这么做的，且能拿到 HttpOnly cookie）；若要在**浏览器内部**发起一个真正带 cookie 的下载，只有三条路可行：① 在扩展 SW 里用 `fetch(..., {credentials:'include'})` **让浏览器自己带 cookie**（有 host permissions 时扩展请求被当作 same-site，SameSite=Strict 也会发）；② 用 **DNR `modifyHeaders`** 注入（官方对 **append** 的允许清单里**明文包含 `cookie`**，`set` 未见禁止明文，但**未实测**）；③ **让浏览器自己发**（`chrome.tabs` 导航 / 原生下载流，cookie 天然带上——即附录 A 的路线）。**两条死路**已被源码级证据钉死：`fetch` 不能设 `Cookie`（forbidden header），`chrome.downloads.download({headers})` 也不能设（Chromium 用 `net::HttpUtil::IsSafeHeader` 校验并返回 `"Unsafe request header name"`）。

**需求 B（多线程下载）**：**浏览器扩展里没有可用的"现成多线程下载引擎"**——唯一真正做到多段的扩展 Turbo Download Manager **已于 2017 年停更**，其磁盘层依赖 Chrome App 的 `chrome.fileSystem` / 已废弃的 HTML5 FileSystem API；DownThemAll 官方 TODO 直接判定"**分段下载在 WebExtension 里做不到**（下载 API 不支持，手工存分片再重组不可靠）"。**但结论不是"不可能"**：`fetch` + `Range: bytes=a-b` 并发是可行的（ipull 这类网页库就这么做，浏览器默认 3 路），真正的难点在**落盘**——必须自己找地方做「随机偏移写入」（File System Access 的 `FileSystemWritableFileStream.seek()` 或 OPFS 的 `createSyncAccessHandle().write(buf,{at})`），或者退化成内存里合并（受 Blob/RAM 限制）。**aria2 的 `split` / `max-connection-per-server` 语义无法原样复现**（受同域 6 连接、HTTP/2 多路复用、服务器 `Accept-Ranges` 三项约束），属于"条件性可用"；另外 **MV3 service worker 本身扛不住长下载**（官方文档：空闲 30 秒、单请求超过 5 分钟、或 `fetch()` 响应超过 30 秒未到达即被终止），多段下载的执行体必须放在扩展页/offscreen 文档 + dedicated worker 里。

---

## 2 需求 A：带 Cookie 下载的现有方案

### 2.0 先把问题拆成三个独立问题（否则会混为一谈）

1. **谁在发请求**：页面（MAIN world）／内容脚本／扩展 SW 或扩展页——三者 cookie 规则完全不同；
2. **cookie 从哪来**：浏览器自己按 cookie jar + SameSite 规则挑（"让浏览器自己发"）；还是扩展用 `chrome.cookies` **手工读出来**再塞进请求（只有这一条能覆盖 HttpOnly）；
3. **怎么塞进请求**：请求头里能不能写 `Cookie`？能不能让 `fetch` 带？能不能用 `chrome.downloads` 带？

下面按"方案"逐个给证据。

---

### A-1 页面自身/同源发起（浏览器自动带 cookie）

- 出处：[MDN Request.credentials](https://developer.mozilla.org/en-US/docs/Web/API/Request/credentials)；[MDN Using Fetch → Including credentials](https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API/Using_Fetch)
- 原理：`fetch` 默认 `credentials: 'same-origin'`，"Only send and include credentials for same-origin requests. This is the default."（MDN）。同源请求自动带 cookie，无需任何扩展能力。
- 局限：只对**同源**有效；跨源立刻进入 A-2 的三堵墙。

### A-2 跨源 `fetch` + `credentials:'include'`：CORS / ACAC / SameSite 三堵墙

- 出处：MDN（同上）+ [MDN Access-Control-Allow-Credentials](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Access-Control-Allow-Credentials) + [MDN Set-Cookie → SameSite](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie)
- 原理与原文：
  - "Note that if a cookie's SameSite attribute is set to `Strict` or `Lax`, then the cookie will not be sent cross-site, even if credentials is set to include."（MDN Using Fetch）
  - "Additionally, in this situation the server must explicitly specify the client's origin in the Access-Control-Allow-Origin response header (that is, `*` is not allowed)."（MDN Using Fetch）
  - SameSite=Lax 的白名单里**明确排除 fetch**："This would exclude, for example, requests made using the fetch() API"（MDN Set-Cookie）
- **对本项目的直接含义**：`credentials:'include'` 不是"能带 cookie"的同义词，它是"我愿意带"，还要服务器同意（CORS）且 cookie 的 SameSite 允许。**在页面上下文里，扩展无法绕过这三者**。
- 适用场景：目标站点自己配好了 CORS 的公开 API。
- 局限：对第三方下载站点，三堵墙基本必然命中。

### A-3 扩展上下文发起 fetch（MV3 service worker / 扩展页 / content script）

这是本题最容易搞错的地方，分开说。

#### A-3.1 扩展 SW / 扩展页（有 host permissions 时）

- 出处：**[Chrome Storage and cookies](https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies)**（关键页，文档页脚标注 "Last updated 2023-09-28 UTC"）与 [Chrome Cross-origin network requests](https://developer.chrome.com/docs/extensions/develop/concepts/network-requests)
- 原理（原文，决定性）：
  > "Requests from an extension to a third-party are treated as **same-site** if the extension has **host permissions** for the third-party. This means **SameSite=Strict cookies can be sent**. Note that this only applies to network requests, not access through `document.cookie` in JavaScript, and **does not apply if third-party cookies are blocked**."
  > "Third-party cookies are never blocked even in subframes if the top-level page for a given tab is a `chrome-extension://` page."
- 另一条必须叠加的规则：`fetch` 的默认 `credentials` 是 `same-origin`（见 A-1），而扩展 SW 对第三方站点而言是**跨源**请求，所以**必须显式写 `credentials:'include'`**，否则浏览器不会附 cookie。这一点官方文档没有把两句话写在同一页，属于**由两条官方规则推出的组合结论**（本文把它标为"由官方规则推导"，非官方明文）。
- 适用场景：**这正是我们引擎最可能用的路径**：扩展 SW + `host_permissions` 覆盖目标站 → fetch 自动带 cookie（含 HttpOnly，浏览器自己发，扩展甚至不需要 `cookies` 权限）。
- 局限：① 用户若在扩展详情页**收回了 host permissions**（MV3 可事后收回），same-site 例外失效；② 第三方 cookie 被屏蔽时例外失效（该页原文）；③ 无法给请求加 `Cookie` 头（见 A-6.1），只能"让浏览器自己挑 cookie"；④ 精确控制（只带某些 cookie）做不到。

#### A-3.2 内容脚本（content script）

- 出处：Chrome *Cross-origin network requests*（原文）
  > "Content scripts initiate requests on behalf of the web origin that the content script has been injected into and therefore content scripts are also subject to the same origin policy."
  > "Cross-origin requests are always treated as such in content scripts, **even if the extension has host permissions**."
- 结论：内容脚本里发 fetch = **页面的 fetch**，走 A-1/A-2 的规则（同源自动带、跨源要 CORS）；**不享受** A-3.1 的 same-site 例外。
- 对本项目：拦截器注入在页面 MAIN world 的情况下（R4.1/R9），**不能**靠内容脚本替用户带 cookie 去做跨域下载。

### A-4 `chrome.cookies` 能读到什么（**HttpOnly 可读**，需要什么权限）

- 出处：[Chrome chrome.cookies API](https://developer.chrome.com/docs/extensions/reference/api/cookies)；[MDN WebExtensions cookies.Cookie](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/cookies/Cookie)；[MDN cookies.getAll](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/cookies/getAll)
- 权限要求（原文）：
  > "To use the cookies API, declare the `"cookies"` permission in your manifest along with **host permissions for any hosts whose cookies you want to access**."
  > "This method only retrieves cookies for domains that the extension has host permissions to."（`getAll` 说明）
- **HttpOnly**：
  - 文档层面：`Cookie` 类型含 `httpOnly` 字段——"True if the cookie is marked as HttpOnly (i.e. the cookie is inaccessible to client-side scripts)."（Chrome 文档 / MDN 同义）。**能读到这个字段本身就说明 API 能看到 HttpOnly cookie**。
  - 源码层面（决定性）：Chromium `extensions/browser/api/cookies/cookies_api.cc` 的 `getAll` 路径直接调 `cookies_helpers::GetAllCookiesFromManager(...)`（对 cookie manager 直接取全部，**无 HttpOnly 过滤**）；`set` 路径显式 `options.set_include_httponly();`（允许扩展设置 HttpOnly cookie）。→ [cookies_api.cc](https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/cookies/cookies_api.cc)
  - 行为层面（旁证）：成熟扩展 Aria2 Explorer / YAAW-for-Chrome **都没有对 `httpOnly` 做任何过滤**，直接把 `name=value` 全量拼进 `Cookie` 头（见 A-5）。cookie 导出扩展 Get cookies.txt LOCALLY（MV3，`permissions: ["activeTab","cookies","downloads","notifications"]`）也是全量导出。
- **结论：`chrome.cookies` + host permissions 是唯一能拿到 HttpOnly cookie 值的浏览器途径**（页面 JS 永远拿不到）。
- 局限：需要 `cookies` 权限（安装时警告）+ 目标 host 权限；`getAll` 必须按 URL/storeId 查询，**拿不到"请求实际会发哪些 cookie"的完整语义**（SameSite/分区/CHIPS 需要自己处理，见 §6）。

### A-5 【必须调研的成熟方案】把下载转交给外部 aria2 的扩展是怎么取 cookie 的

#### A-5.1 Aria2 Explorer（alexhua/Aria2-Explorer，v2.8.3，MV3）

- 出处 URL：
  - 仓库：<https://github.com/alexhua/Aria2-Explorer>
  - manifest：<https://github.com/alexhua/Aria2-Explorer/blob/master/manifest.json>
  - 关键代码：<https://github.com/alexhua/Aria2-Explorer/blob/master/background.js>（本次抓取时 master 最后提交 2026-10-06）
- 原理（源码，逐段）：
  1. **拦截浏览器下载**：`chrome.downloads.onDeterminingFilename.addListener(captureDownload)`；捕获后 `chrome.downloads.cancel(id)` 再转给 aria2。
     ```js
     const isDownloadListened = () => chrome.downloads.onDeterminingFilename.hasListener(captureDownload);
     ...
     if (Configs.integration && shouldCapture(downloadItem)) {
         chrome.downloads.cancel(downloadItem.id)...
     ```
  2. **取 cookie**（background.js:110-132，原文）：
     ```js
     async function getCookies(downloadItem) {
         let storeId = (downloadItem.incognito || chrome.extension.inIncognitoContext) ? "1" : "0";
         let url = downloadItem.multiTask ? downloadItem.referrer : downloadItem.url;
         let cookies = await chrome.cookies.getAll({ url, storeId });
         let partitionedCookies = [];
         try {
             partitionedCookies = await chrome.cookies.getAll({ url, storeId, partitionKey: {} });
         } catch {
             // Ignore browsers that do not support partitionKey.
         }
         const cookieMap = new Map([...cookies, ...partitionedCookies].map(cookie => [cookie.name, cookie.value]));
         let cookieItems = [];
         for (const [name, value] of cookieMap) {
             cookieItems.push(name + "=" + value);
         }
         return cookieItems;
     }
     ```
     注意：**没有过滤 `cookie.httpOnly`**；还额外查了一次 `partitionKey: {}`（拿分区 cookie，CHIPS）。
  3. **塞进请求**（background.js:134-165，原文）：
     ```js
     let headers = [];
     if (cookieItems.length > 0) {
         headers.push("Cookie: " + cookieItems.join("; "));
     }
     headers.push("User-Agent: " + navigator.userAgent);
     let options = await Aria2Options.getUriTaskOptions(rpcItem.url);
     if (!!options.header) {
         options.header = options.header.split('\n').filter(item => !/^(cookie|user-agent|connection)/i.test(item));
         headers = headers.concat(options.header);
     }
     options.header = headers;
     if (downloadItem.referrer) options.referer = downloadItem.referrer;
     ...
     return aria2.addUri(downloadItem.url, options)
     ```
     → **它绕开浏览器限制的办法是：根本不让浏览器发这个请求，而是把 cookie 字符串交给 aria2**（aria2 的 `header` 选项，等价命令行 `--header`，可重复）。
  4. 安全闸门（源码 + 本地化文案）：只在 RPC 端点是 `https/wss`、localhost、或用户显式 `ignoreInsecure` 时才附 cookie；文案原文："For insecure RPC, the related website cookies will not be attached when auto-download or direct export."（`_locales/en/messages.json`）
- 用了哪些 API：`chrome.downloads.onDeterminingFilename/cancel`、`chrome.cookies.getAll`（含 `partitionKey`）、`chrome.extension.inIncognitoContext`、`storage`、`tabs/sidePanel/notifications`；权限 `["cookies","tabs","notifications","contextMenus","downloads","storage","scripting","sidePanel","power"]` + `host_permissions: ["<all_urls>"]`。
- 适用场景：**把浏览器里的下载交给本机/远程 aria2** —— 与本项目"把 RPC 请求转接到浏览器下载能力"方向相反，但**"cookie 怎么取"这一步完全同构**，是本项目 `withHeader`/cookie 能力的最重要参照物。
- 局限：① cookie 字符串是**快照**，长下载期间 cookie 轮转不会更新；② 全量 cookie 交给外部（含 HttpOnly）有隐私/泄露面（作者用"RPC 必须 https/localhost"缓解）；③ 不构造 cookie 的 SameSite/Path/Domain 语义，只是 `name=value` 拼接（可能与站点预期顺序/重复名不完全一致）；④ 依赖 `chrome.cookies` 权限 + host 权限，用户拒权即失效。

#### A-5.2 YAAW-for-Chrome（acgotaku/YAAW-for-Chrome，v1.0.0，MV3）

- 出处：[background.js](https://github.com/acgotaku/YAAW-for-Chrome/blob/master/background.js)、[manifest.json](https://github.com/acgotaku/YAAW-for-Chrome/blob/master/manifest.json)
- 原理（源码原文，与 A-5.1 同型、更简短）：
  ```js
  function aria2Send (rpcPath, fileDownloadInfo) {
    ...
    chrome.cookies.getAll({ url: fileDownloadInfo.link }, function (cookies) {
      const formatedCookies = []
      cookies.forEach(cookie => {
        formatedCookies.push(cookie.name + '=' + cookie.value)
      })
      const header = []
      header.push('Cookie: ' + formatedCookies.join('; '))
      header.push('User-Agent: ' + navigator.userAgent)
      const rpcData = { jsonrpc: '2.0', method: 'aria2.addUri', id: ..., params: [[fileDownloadInfo.link], { header }] }
  ```
- 权限：`["cookies","notifications","tabs","contextMenus","downloads","storage"]` + `host_permissions: ["<all_urls>"]`；拦截用 `chrome.downloads.onDeterminingFilename` / `onCreated`。
- 结论：**同一套成熟范式被至少两个独立扩展使用**（`chrome.cookies.getAll` → `Cookie:` 头 → aria2 `header` 选项）。这是"同一问题的成熟解法"。

#### A-5.3 Aria2 Integration（baptistecdr/aria2-extensions）

- 出处：<https://github.com/baptistecdr/aria2-extensions>、README 原文 "Capture links, selected text, and browser downloads with a single click or from the extension popup."、"Capture browser downloads and redirect them to your server"
- [未验证]：该仓库**不含扩展源码**（`aria2-integration/` 目录为空，仓库里只有 README/打包产物目录），因此**无法给出它取 cookie 的源码级证据**。README 只声明会捕获浏览器下载并转发，未提 cookie 处理。**不要**把它当作与 A-5.1 同等强度的证据。

#### A-5.4 cookie 导出类扩展（Get cookies.txt LOCALLY，0.7.2，MV3）

- 出处：<https://github.com/kairi003/Get-cookies.txt-LOCALLY>、[src/manifest.json](https://github.com/kairi003/Get-cookies.txt-LOCALLY/blob/master/src/manifest.json)、[src/modules/get_all_cookies.mjs](https://github.com/kairi003/Get-cookies.txt-LOCALLY/blob/master/src/modules/get_all_cookies.mjs)、[src/modules/cookie_format.mjs](https://github.com/kairi003/Get-cookies.txt-LOCALLY/blob/master/src/modules/cookie_format.mjs)
- 原理：`permissions: ["activeTab","cookies","downloads","notifications"]` + `host_permissions: ["<all_urls>"]`；用 `chrome.cookies.getAll(details)` 取全量（含分区处理），序列化成 Netscape/JSON；**序列化时不区分 httpOnly**（`jsonToNetscapeMapper` 只取 `domain, expirationDate, path, secure, name, value`）→ 功能上意味着 **HttpOnly cookie 的值会被导出**。
- 对本项目的意义：进一步证明"扩展能读 HttpOnly"，且"读 cookie"这件事本身是**合规且常见的扩展能力**。

#### A-5.5 下载管理器扩展代表：Turbo Download Manager 的 cookie 策略（**完全不碰 Cookie 头**）

- 出处：<https://github.com/inbasic/turbo-download-manager>（MV2，最后提交 2017-02-21）
- 事实：对全仓库 `src/` 做 `grep -i cookie`，**唯一命中**是 Firefox 层的一行：
  ```js
  req.channel.QueryInterface(Ci.nsIHttpChannelInternal)
    .forceAllowThirdPartyCookie = true;
  ```
  （`src/lib/firefox/firefox.js`）——即：TDM **从不自己拼 `Cookie` 头**，它的多段请求走 `fetch`/XHR，**cookie 由浏览器自己带**；在 Firefox 里还需要用特权 API **强制允许第三方 cookie**，否则多段请求可能不带 cookie。
- 对照意义：与 A-5.1/A-5.2（把 cookie **读出并外送**）形成鲜明对比——**"在浏览器内自己下载"的扩展不需要、也不能自己构造 Cookie 头，只能依赖浏览器**。这正是本项目引擎的处境。
- 局限/注意：`Ci.nsIHttpChannelInternal` 是 Firefox 特权 XPCOM 接口（MV2/legacy 时代），在 MV3 WebExtension 里**不可用**；`[未验证]` 当前 MV3 下 Chrome 是否有等价能力（本文未找到）。

### A-6 读到的 cookie 怎么塞进请求——**`Cookie` 是 forbidden header，根本设不进去**

#### A-6.1 死路 1：`fetch(url, {headers: {Cookie: ...}})`

- 出处：[MDN Forbidden request header](https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header)、[MDN Cookie header](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cookie)
- 原文：
  > "A forbidden request header is an HTTP header name-value pair that **cannot be set or modified programmatically in a request**."（清单中**列有 `Cookie`**）
  > MDN Cookie 页头部的字段表：`Forbidden request header` → **Yes**
- 结论：**在页面、内容脚本、扩展 SW 里，`Cookie` 都无法通过 fetch/XHR 设置**（XHR 的 `setRequestHeader` 同样被 Fetch 规范约束；`document.cookie` 只能影响浏览器自己发请求时的 jar，不改本次请求）。**这条墙是硬的。**

#### A-6.2 死路 2：`chrome.downloads.download({headers: [{name:"Cookie", ...}]})`

- 官方文档口径（[Chrome chrome.downloads](https://developer.chrome.com/docs/extensions/reference/api/downloads)）：
  > "Extra HTTP headers to send with the request if the URL uses the HTTP[s] protocol. Each header is represented as a dictionary containing the keys `name` and either `value` or `binaryValue`, **restricted to those allowed by XMLHttpRequest**."
- 源码口径（决定性）：Chromium `chrome/browser/extensions/api/downloads/downloads_api.cc`
  ```cc
  if (options.headers) {
    for (const downloads::HeaderNameValuePair& header : *options.headers) {
      if (!net::HttpUtil::IsValidHeaderName(header.name)) {
        return RespondNow(Error(download_extension_errors::kInvalidHeaderName));
      }
      if (!net::HttpUtil::IsSafeHeader(header.name, header.value)) {
        return RespondNow(Error(download_extension_errors::kInvalidHeaderUnsafe));
      }
      ...
      download_params->add_request_header(header.name, header.value);
  ```
  `net/http/http_util.cc` 的 `kForbiddenHeaderFields` 原文清单（部分）：
  ```cc
  // A header string containing any of the following fields will cause
  // an error. The list comes from the fetch standard.
  const char* const kForbiddenHeaderFields[] = {
      "accept-charset", ..., "connection", "content-length", "cookie", "cookie2",
      "date", "dnt", "expect", "host", "keep-alive", "origin", "referer",
      "set-cookie", "te", "trailer", "transfer-encoding", "upgrade", "user-agent", "via",
  ```
  错误串（`download_extension_errors.h`）：`kInvalidHeaderUnsafe[] = "Unsafe request header name";`
- 结论：**`chrome.downloads.download({headers})` 传 `Cookie`/`Referer`/`User-Agent`/`Origin`/`Set-Cookie` 会被拒绝**（API 直接返回错误）。这从源码层面**支持了附录 A 的判断**（"`chrome.downloads` 不支持敏感 header"），并给出了更精确的边界：不是"敏感 header 不支持"，而是**"Fetch 规范里 forbidden 的那一批都不支持"**。
- 附带（同一源码）：`download_params->set_initiator(extension()->origin())`（SW 场景）、`set_do_not_prompt_for_login(true)`。→ **`chrome.downloads` 触发的下载的发起方是扩展 origin**（对目标站点是跨源请求）。

#### A-6.3 活路 1：DNR `modifyHeaders` 注入 Cookie

- 出处：[Chrome declarativeNetRequest](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest#header-modification)、[MDN ModifyHeaderInfo](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest/ModifyHeaderInfo)、[Chromium IDL](https://chromium.googlesource.com/chromium/src/+/main/extensions/common/api/declarative_net_request.webidl)
- 原文（Chrome 文档 "Header modification"）：
  > "The **append** operation is only supported for the following request headers: accept, accept-encoding, accept-language, access-control-request-headers, cache-control, connection, content-language, **cookie**, forwarded, if-match, if-none-match, keep-alive, range, te, trailer, transfer-encoding, upgrade, user-agent, via, want-digest, x-forwarded-for. This allowlist is case sensitive."
  MDN 同页："In Chrome, "append" is supported for the following request headers: ... **Cookie** ...; In Firefox, the extension needs host permissions for the new value of the Host header."
- `HeaderOperation`（IDL）只有三种：`append` / `set` / `remove`；`ModifyHeaderInfo.value` 的 IDL 注释："The new value for the header. Must be specified for `<code>append</code>` and `<code>set</code>` operations."
- **未验证（重要）**：官方文档只给了 **append 的白名单（含 cookie）**，**没有**任何"禁止 `set` cookie"的明文；我也没找到官方示例用 `set` 改 `Cookie`。→ **"DNR 能否 `set` 整个 Cookie 头"必须实测**，本文不给定论。`append` 是文档背书可行的那条。
- 时序（Chrome 文档原文）："Before Chrome sends request headers to the server, the headers are updated based on matching modifyHeaders rules."（说明 DNR 改头发生在浏览器附加 cookie 之后的发送前阶段）
- 权限：`"declarativeNetRequest"` 或 `"declarativeNetRequestWithHostAccess"`（文档原文：两者能力相同，差别在权限请求时机；后者"you must request host permissions before you can perform any action on a host"）。
- **副作用面**：DNR 是**扩展级**规则，命中 URL 的**所有**请求都会被改（附录 A.4.7 已记录此点），且规则要随任务动态增删（session rules，上限 5000；[Chrome 文档 "Session rules"](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest#rule-limits)）。

#### A-6.4 活路 2：扩展 SW 里 `fetch`，**让浏览器自己带 cookie**（见 A-3.1）

- 为什么这是"活路"：不能设 `Cookie` 头 ≠ 不能带 cookie。带 cookie 的合法姿势是**不写 `Cookie` 头**，而是提供 `credentials:'include'` + 满足同站/权限条件，由浏览器从 cookie jar 里挑。
- 代价：**无法精确控制**带哪些 cookie；HttpOnly 也能带上（浏览器自己发），但扩展拿不到"我到底带了什么"的清单（除非同时也用 `chrome.cookies` 去推演）。

#### A-6.5 活路 3：让浏览器自己发（导航 / 标签页 / 原生下载流）——**附录 A 的路线**

- 出处：附录 A（`chrome.tabs` 打开 `urlA` + 两条 DNR）；[MDN Set-Cookie → SameSite](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie)（导航属于会发 Lax cookie 的场景："It would include requests made when the user clicks a link in the top-level browsing context from one site to another, or an assignment to document.location, or a `<form>` submission."）
- 原理：顶层导航/表单提交天然携带该站点的 cookie（含 HttpOnly，含 Lax），无需扩展做任何 cookie 工作。
- **重要旁证（第三方报告）**：Stack Overflow《Chrome Downloads API http requests are not getting modified by Declarative Net Request API》（2024-02-03，0 回答）原文：
  > "when I try to download a file using chrome's Downloads API, the download request is not getting modified and hence fails. … if I trigger the download from DOM, the request is getting modified properly."
  → **用户实测报告：DNR 对 `chrome.downloads` 触发的请求不生效，对 DOM/导航触发的请求生效**。这**不是官方文档**，但它与附录 A.3 的原因说明一致，且我在本轮**没有**找到任何官方原文明确这一点 → 记为 `[第三方报告]`。
- 局限（附录 A.4 已列）：落盘位置由浏览器下载设置决定；需要一个标签页；有"等几秒"的时间依赖；DNR 规则全局生效。

#### A-6.6 历史路（MV2）：`chrome.webRequest.onBeforeSendHeaders`（blocking）+ `extraHeaders`

- 出处：[Chrome MV2 webRequest](https://developer.chrome.com/docs/extensions/mv2/reference/webRequest)
- 原文：
  > "Starting from Chrome 72, the following request headers are not provided and cannot be modified or removed without specifying 'extraHeaders' in opt_extraInfoSpec: Accept-Language, Accept-Encoding, Referer, **Cookie**"
- 说明：MV2 时代扩展**可以真正改写 `Cookie` 请求头**（需 `webRequestBlocking` + `extraHeaders`）。**MV2 已废弃**（Chrome Web Store 不再接受；本项目按 MV3 设计），因此这条只能当"老方案为何能做到"的对照，**不可用**。

#### A-6.7 其它可能路径

- `chrome.debugger` + CDP `Network.setExtraHTTPHeaders`：本轮**未验证**——我抓取了 [chrome.debugger 文档](https://developer.chrome.com/docs/extensions/reference/api/debugger) 但**没有找到**关于调试横幅/权限代价的原文可引，且 CDP 具体命令未在官方扩展文档中说明。**列出但不推荐，标注未验证**。
- 直接改 cookie jar（`chrome.cookies.set`）让浏览器自己带：理论可行（`set_include_httponly()` 允许写 HttpOnly），但**会污染用户 cookie**，不是"给一次下载带 header"的等价物。`[推论，未见项目这么做]`。
- `chrome.downloads.download` 是否会自动带该站 cookie：**未验证**。源码只显示下载请求的 initiator 是扩展 origin、headers 受 forbidden 限制；我没有找到"downloads 请求带 cookie"的官方明文。→ §8。

---

## 3 需求 B：多线程下载的现有方案

### 3.0 aria2 的语义基线（要复现的对象）

- 出处：[aria2 官方手册](https://aria2.github.io/manual/en/html/aria2c.html)
- 原文：
  > `-s, --split=<N>`：Download a file using N connections. … The number of connections to the same host is restricted by the `--max-connection-per-server` option. … **Default: 5**
  > `-x, --max-connection-per-server=<NUM>`：The maximum number of connections to one server for each download. **Default: 1**
  > `-k, --min-split-size=<SIZE>`：aria2 does not split less than 2*SIZE byte range. … If SIZE is 15M, since 2*15M > 20MiB, aria2 does not split file and download it using 1 source.
  > `--header=<HEADER>`：Append HEADER to HTTP request header.（可重复）
  > `-c, --continue[=true|false]`：Continue downloading a partially downloaded file.
- 这意味着"多线程"在 aria2 里不是"开 N 条连接"这么简单，而是**分片模型 + 最小分片 + 每服务器连接上限 + 断点续传控制文件**的组合。

### B-1 现成方案：Turbo Download Manager（唯一真正实现多段的浏览器扩展）

- 出处：<https://github.com/inbasic/turbo-download-manager>（**最后提交 2017-02-21，已停更**）
  - 引擎：<https://github.com/inbasic/turbo-download-manager/blob/master/src/lib/wget.js>
  - 磁盘层（扩展构建）：<https://github.com/inbasic/turbo-download-manager/blob/master/src/lib/opera/chrome-cm.js>
  - 磁盘层（Chrome App 构建）：<https://github.com/inbasic/turbo-download-manager/blob/master/src/lib/chrome/chrome-cm.js>
  - 默认参数：<https://github.com/inbasic/turbo-download-manager/blob/master/src/lib/config.js>
  - README："Turbo Download Manager is an open-source multi-platform download manager with multi-threading support"
- 原理（源码原文）：
  1. **探测**（`wget.js` head()）：先用 `XMLHttpRequest` 发 `HEAD`（拿不到 Content-Length 时退化为 `GET` 并在 readyState 2/3 时 abort），据响应头判定：
     ```js
     'multi-thread': !!length &&
         contentEncoding === null &&
         req.getResponseHeader('Accept-Ranges') === 'bytes' &&
         lengthComputable !== 'false'
     ```
     → **多线程的三个前提条件：有长度、无 Content-Encoding、`Accept-Ranges: bytes`**（源码级印证"服务器不支持 Range 就不能多线程"）。
  2. **分片**（`wget.js`）：
     ```js
     obj.headers.Range = `bytes=${range.start}-${range.end}`;
     ...
     len = Math.max(len, obj['min-segment-size'] || 50 * 1024);
     len = Math.min(len, obj['max-segment-size'] || 100 * 1024 * 1024);
     let threads = Math.floor(info.length / len);
     if (!info['multi-thread']) { threads = 1; }
     ```
     并发数默认 **3**：`config.defineInt('wget.threads', 3);`
  3. **校验 206**（源码原文）：
     ```js
     // make sure server supports partial content fetching; 206
     if (res.status && res.status !== 206 && obj.headers.Range) {
       throw new utils.CError(`expected 206 but got ${res.status}`, 1, ...);
     }
     ```
     降级路径（源码注释）："if download does not support multi-threading do not send range info"。
  4. **写盘 = 随机偏移写入**（`io.js` + 平台层）：`io.File.prototype.write(offset, arr)` → `app.fileSystem.file.write(file, offset, arr)`；Chrome 实现：
     ```js
     write: function (file, offset, arr) {
       return new Promise(function (resolve, reject) {
         file.createWriter(function (fileWriter) {
           let blob = new Blob(arr, {type: 'application/octet-stream'});
           fileWriter.onwrite = () => resolve();
           fileWriter.seek(offset);
           fileWriter.write(blob);
     ```
     先把文件 `truncate(length)` 预分配，再按 offset 写入；`write-size` 聚合缓冲（`writer` 函数把连续分片缓冲合并到阈值再落盘）。
  5. **完成/落盘**：`io.File.prototype.flush()` 在内部临时 FS 情况下用 `Blob` + `URL.createObjectURL` + 隐藏 `<a download>` 点击触发保存，并在 2 分钟后删除临时文件。
- 用了哪些 API：`fetch`（Response.body reader）/`XMLHttpRequest`、`Range` 头、HTML5 FileSystem API（`root.getFile` / `file.createWriter` / `fileWriter.seek`）、Chrome App 专属 `chrome.fileSystem`（保留目录句柄）、MV2 `webRequest` 权限。
- 适用场景：当年（MV2 + Chrome App 时代）真能多线程下载并直写磁盘。
- **今天能不能用**：**不能直接借鉴实现**——① 仓库停更于 2017；② `chrome.fileSystem` 是 **Chrome App** API（Chrome Apps 已废弃，非 ChromeOS 不再支持）；③ HTML5 FileSystem API（`webkitRequestFileSystem` 系）已被弃用，`native-file-system-adapter` 的 README 直接把 `sandbox` 适配器标为 "**deprecated**: Uses requestFileSystem ... Only supported in Chromium-based browsers"；④ 扩展构建的 `manifest-extension.json` 是 MV2。
- **可借鉴的部分**：分片判定条件（长度 + 无编码 + Accept-Ranges）、206 校验、最小/最大分片、offset 写入的架构（这正是今天 OPFS `write(buf,{at})` 的等价物）。

### B-2 现成方案：DownThemAll! WE（**官方否定结论**，Firefox）

- 出处：<https://github.com/downthemall/downthemall>（4.15.1，MV2 WebExtension，最后提交 2026-05-27）
  - [Readme.md](https://github.com/downthemall/downthemall/blob/master/Readme.md)、[TODO.md](https://github.com/downthemall/downthemall/blob/master/TODO.md)
- 原文（Readme.md，作者 Nils Maier）：
  > "What this furthermore means is that some bugs we fixed in the original DownThemAll! are back, as **we cannot do our own downloads any longer but have to go through the browser download manager always** …"
  > "I spent countless hours evaluating various workarounds to enable us to do our own downloads instead of relying on the downloads API … From using `IndexedDB` to store retrieved chunks via `XHR`, to doing nasty service-worker tricks to fake a download that the backend would retrieve with `XHR`. The last one looks promising but I have yet to get it to work in a manner that is reliable, performs well enough and **doesn't eat all the system memory for breakfast**."
- 原文（TODO.md，"P4 Stuff that probably cannot be implemented due to WebExtension limitations"）：
  > "**Segmented downloads** — Cannot be done with WebExtensions - downloads API has no support and manually downloading, storing in temporary add-on storage and reassembling the downloaded parts later is not only [in]efficient but does not reliably work due to storage limitations."
  > "**Checksums/Hashes?** — Cannot be done with WebExtensions - cannot actually read the downloaded data"
  > "**Mirrors?** — Cannot be done with WebExtensions - no low level APIs, see segmented downloads"
- **时代性注意**：DTA 的这一判断形成于 File System Access API（2020+）与 OPFS（2023+）之前，其"storage limitations"的论据在今天**部分被削弱**（OPFS 可以随机写盘、分片不必留在内存）。但两条**没有被削弱**的结论是：① **浏览器的创建下载（`downloads` API / 原生下载流）不提供分段能力**，想多段必须自己 fetch 全部分片；② **扩展上下文里"长期、可靠、低内存"地持有拼装状态**是工程难点（SW 生命周期、存储配额、用户手势）。
- 适用场景：Firefox 上的批量抓取（选择/重命名/队列），**不做多段**。

### B-3 Chrono Download Manager

- 出处（商店）：<https://chromewebstore.google.com/detail/chrono-download-manager/mciiogijehkdemklbdcbfkefimifhecn>
- `[未验证]`：本轮**未取得**其源码或关于"多线程"的官方技术说明（GitHub 上未找到可用的官方仓库；商店页为 JS 渲染，未取到可引原文）。**不作为证据使用**。

### B-4 网页端"多段下载"库：ipull（浏览器模式）

- 出处：<https://github.com/ido-pluto/ipull>（最后提交 2025-05-28）
  - [README.md](https://github.com/ido-pluto/ipull/blob/main/README.md)："> Super fast file downloader with multiple connections"；Features 列表含 "Download using parallels connections"、"Pausing and resuming downloads"、"Node.js and browser support"
  - [src/download/browser-download.ts](https://github.com/ido-pluto/ipull/blob/main/src/download/browser-download.ts)：`const DEFAULT_PARALLEL_STREAMS_FOR_BROWSER = 3;`
  - [download-engine-fetch-stream-fetch.ts](https://github.com/ido-pluto/ipull/blob/main/src/download/download-engine/streams/download-engine-fetch-stream/download-engine-fetch-stream-fetch.ts)：`headers.range = \`bytes=${this._startSize}-${this._endSize - 1}\`;` 与 `const acceptRange = this.options.acceptRangeIsKnown ?? response.headers.get("accept-ranges") === "bytes";`
- 原理：`fetch` + `Range` 并发；先做探测（源码里有 `range: "bytes=0-0"` 的探测请求）；`Accept-Ranges` 判定为 bytes 才多段，否则降级。
- **合并方式：内存**。README 原文的浏览器示例：`image.src = downloader.writeStream.resultAsBlobURL(); console.log(downloader.writeStream.result); // Uint8Array` → 结果在内存里拼成一个 `Uint8Array`/Blob URL。也支持 `onWrite: (cursor, buffers, options) => {...}` 自定义落盘（**给出了 offset/cursor 语义**，可接 OPFS/FSA）。
- 实现细节（源码原文，对约束 C12/F10 的印证）：
  - 探测请求显式带 `"Accept-Encoding": "identity"`（避免压缩导致长度/字节语义失效）；
  - `const contentEncoding = response.headers.get("content-encoding"); if (contentEncoding && contentEncoding !== "identity") { length = 0; }`（有编码则长度不可用）；
  - 长度未知且 `acceptRange` 时，用 `range: "bytes=0-0"` 再探一次并解析 `content-range` 拿总长（`parseHttpContentRange(contentRange)?.size`）。
- 局限：① CORS——README 明确给了 `acceptRangeIsKnown` / `defaultFetchDownloadInfo` 两个开关"to overcome CORS"，因为跨源读 `Accept-Ranges`/`Content-Range` 需要 `Access-Control-Expose-Headers`（这是**网页**的痛点；**扩展 SW 有 host permissions 时不受 CORS 限制**）；② 默认内存合并（`writeStream.result` 是 `Uint8Array`），大文件会撞 Blob/RAM 上限；③ 我**没有**在源码里看到"分片请求必须收到 206 才接受"的校验（只有 `accept-ranges` 判定 + 非 2xx 抛错）→ 若服务器谎报 `Accept-Ranges` 却返回 200，ipull 的行为**未验证**。
- 对本项目的意义：**证明"浏览器里 fetch 多段"技术上是通的**，并且给出了"探测 → 判定 → 并发 → 按 offset 回写"的标准骨架。

### B-5 落盘/合并方案（决定多线程能不能落地的关键）

#### B-5.1 `FileSystemWritableFileStream`（File System Access，用户可见文件）

- 出处：[MDN FileSystemWritableFileStream](https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream)、[MDN FileSystemFileHandle.createWritable](https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle/createWritable)、[MDN showSaveFilePicker](https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker)
- **能 seek 到任意 offset 写入**（原文示例）：
  ```js
  writableStream.write({ type: "write", position, data });
  writableStream.write({ type: "seek", position });
  writableStream.write({ type: "truncate", size });
  ```
  "Writes content into the file the method is called on, at the current file cursor offset."；`createWritable({keepExistingData:true})` 可保留既有内容（**这对断点续传重要**）。
- 上下文与交互成本：`showSaveFilePicker()` 由 `Window` 提供；MDN 原文 "**Transient user activation is required. The user has to interact with the page or a UI element in order for this feature to work.**"（另有 Chromium 企业策略 [FileOrDirectoryPickerWithoutGestureAllowedForOrigins.yaml](https://chromium.googlesource.com/chromium/src/+/main/components/policy/resources/templates/policy_definitions/Miscellaneous/FileOrDirectoryPickerWithoutGestureAllowedForOrigins.yaml) 原文："For security reasons, the showOpenFilePicker(), showSaveFilePicker() and showDirectoryPicker() web APIs **require a prior user gesture ("transient activation")** to be called or will otherwise fail."）
- **对本项目的致命点**：RPC 请求来自页面 JS，**没有用户手势**；如果"多线程引擎"要求每次下载都弹一次保存对话框，就与 aria2 语义（`dir` 参数自动落盘）冲突。→ 只能用**目录**句柄（`showDirectoryPicker()`，一次授权）或换 OPFS。

#### B-5.2 OPFS（`navigator.storage.getDirectory()` + `createSyncAccessHandle()`）

- 出处：[MDN OPFS](https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system)、[MDN createSyncAccessHandle](https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle/createSyncAccessHandle)、[MDN FileSystemSyncAccessHandle.write](https://developer.mozilla.org/en-US/docs/Web/API/FileSystemSyncAccessHandle/write)、[MDN StorageManager.getDirectory](https://developer.mozilla.org/en-US/docs/Web/API/StorageManager/getDirectory)
- 原文：
  > OPFS "provides access to a special kind of file that is highly optimized for performance and offers **in-place write access** to its content."（OPFS 页）
  > "It also has a set of **synchronous calls available (other File System API calls are asynchronous) that can be run inside web workers only** so as not to block the main thread."
  > `createSyncAccessHandle`："**only available in Dedicated Web Workers**" / "it is only usable inside dedicated Web Workers for files within the origin private file system"
  > `write(buffer, { at })`：`at` = "A number representing the offset in bytes from the start of the file that the buffer should be written at."（**随机偏移写入**，正是多段合并需要的）
  > 独占锁："Creating a FileSystemSyncAccessHandle takes an **exclusive lock** on the file … This prevents the creation of further FileSystemSyncAccessHandles or FileSystemWritableFileStreams for the file until the existing access handle is closed."（`mode` 另有 `readwrite-unsafe` 允许多句柄并发）
  > 配额："The OPFS is subject to **browser storage quota restrictions**, just like any other origin-partitioned storage mechanism"；"**Clearing storage data for the site deletes the OPFS.**"
- 上下文成本：SW **不能**用 `createSyncAccessHandle`（那是 dedicated worker 专属）→ 在 MV3 里要落盘多段数据，需要**扩展页/offscreen document + dedicated Worker**（扩展页里创建 worker 是允许的，但 **MV3 CSP 禁止远程代码**，worker 必须打包）。
- `[未验证]`：OPFS 的**异步**写路径（`getDirectory()` + `createWritable()`）在 **extension service worker** 里是否可用。MDN 只写 "available in Web Workers"、并列出 `WorkerNavigator.storage` 作为访问入口；我没有找到"Service Worker 支持/不支持"的明文 → 需实测。**但无论如何，sync handle 一定不在 SW 里。**
- 配额缓解（Chrome 扩展文档原文）："Request the `"unlimitedStorage"` permission, which affects both extension and web storage APIs and **exempts extensions from both quota restrictions and eviction**." + "Call `navigator.storage.persist()` for protection against eviction."

#### B-5.3 `FileSaver.js`（Blob 触发下载）

- 出处：<https://github.com/eligrey/FileSaver.js>（最后提交 2022-09-22）
- README 原文：它有浏览器 **Max Blob Size** 表——Chrome **2GB**、Firefox 20+ **800 MiB**、IE 10+ 600 MiB …；并自述："if you need to save really large files bigger than the blob's size limitation or don't have enough RAM, then have a look at the more advanced StreamSaver.js"。
- 结论：**内存整体合并 + Blob** 的路线，受 2GB/内存限制，不是多段下载的落盘方案，只能作为"最后一步把已合并结果交回浏览器下载"的手段。

#### B-5.4 `StreamSaver.js`（伪造成服务器响应，流式落盘）

- 出处：<https://github.com/jimmywarting/StreamSaver.js>（最后提交 2026-07-30）
- README 原文：
  > "Instead of saving data in client-side storage or in memory you could now actually create a **writable stream directly to the file system** … This is accomplish[ed] by **emulating how a server would instruct the browser to save a file using some response header + service worker**"
  > "If the file you are trying to save comes from the cloud/server **use the server instead** of emulating what the browser does to save files on the disk using StreamSaver. Add those extra Response headers and **don't use AJAX** to get it."
  > "The download gets broken when you leave the page."；不安全上下文（HTTP）下要开弹窗装 SW，且要求 "initiate the `createWriteStream` on user interaction"；"worker goes idle after 30 sec in firefox, 5 minutes in blink"
  > 顶注：新规范（whatwg/fs）"is more or less going to make FileSaver, StreamSaver and similar packages a bit obsolete in the future"
- 结论：它是**顺序** WritableStream（没有 seek 语义）→ **不能用于多段乱序合并**；但它揭示了本项目关心的另一条路：**"让浏览器下载流接管"**（与附录 A 思路同源）。注意其 SW 依赖 + 页面 unload 断流的限制。

#### B-5.5 `browser-fs-access` / `native-file-system-adapter`（polyfill 定位）

- 出处：[GoogleChromeLabs/browser-fs-access](https://github.com/GoogleChromeLabs/browser-fs-access/blob/main/README.md)（"a transparent fallback to the `<input type="file">` and `<a download>` legacy methods. This library is a ponyfill."）；[jimmywarting/native-file-system-adapter](https://github.com/jimmywarting/native-file-system-adapter/blob/master/README.md)（提供 `getOriginPrivateDirectory()` 与多种后端：`node`/`deno`/`sandbox`(deprecated)/`indexeddb`/`memory`/`cache`，以及 `FileSystemWritableFileStream` ponyfill "to truncate and write data"）
- 结论：这两者**不提供多段下载逻辑**，只解决"同一套 FS API 在不同环境可用"。对本项目的价值 = 若未来要兼容 Firefox/Safari，可用它们做落盘抽象层；**不能**替代 OPFS 的随机写能力本身。

### B-6 合并写入：两条可行路线的取舍（本节为对上面证据的汇总判断，非新事实）

| 路线 | 随机写 | 上下文 | 用户交互 | 主要风险 |
|---|---|---|---|---|
| FSA 目录句柄（`showDirectoryPicker` → `FileSystemDirectoryHandle` → 文件 `createWritable({keepExistingData:true})`） | ✅ `seek()` / `{type:'write',position}` | Window（扩展页 / offscreen 文档 / 侧栏）——`showDirectoryPicker` 是 `Window` 上的 API | **需要一次用户手势**（授权目录） | 扩展无法自动弹窗（RPC 上下文无手势）→ 需"首次配置时授权目录，之后复用句柄"（句柄持久化需 IndexedDB + 权限复检，`[未验证]`） |
| OPFS（`getDirectory()` → `createSyncAccessHandle()`） | ✅ `write(buf,{at})` | **dedicated worker**（扩展页开 worker） | 无需手势 | 配额/被清理（`unlimitedStorage` + `persist()` 可缓解）；扩展页必须存在（`offscreen` 文档或侧栏/标签页）；写入不可见给用户，最终要"导出"给浏览器下载 |
| 内存合并（Blob / Uint8Array，ipull 浏览器默认） | ✅（内存） | 任意 | 无 | `2GB` Blob / RAM |

---

## 4 硬约束（不可逾越的墙，逐条给证据）

| # | 约束 | 证据（URL） | 强度 |
|---|---|---|---|
| C1 | **`Cookie` 无法由 JS 设置**（fetch/XHR/Headers 均不行） | MDN Forbidden request header（清单含 Cookie）：<https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header>；MDN Cookie 页 "Forbidden request header: Yes" | 硬（规范） |
| C2 | **`chrome.downloads.download({headers})` 不能带 Cookie/Referer/UA/Origin/Set-Cookie**，会直接报错 `"Unsafe request header name"` | Chromium `downloads_api.cc` + `net/http/http_util.cc` 的 `kForbiddenHeaderFields` + `download_extension_errors.h`；Chrome 文档 "restricted to those allowed by XMLHttpRequest" | 硬（源码 + 文档） |
| C3 | **扩展只有在拥有该 host 的 host permissions、且第三方 cookie 未被屏蔽时**，对第三方的请求才被当作 same-site，SameSite=Strict cookie 才会发 | Chrome *Storage and cookies* 原文 | 硬（官方文档） |
| C4 | **内容脚本永远不享受 C3**：内容脚本按页面 origin 走同源策略，"even if the extension has host permissions" | Chrome *Cross-origin network requests* 原文 | 硬 |
| C5 | **跨源 `fetch` 默认不带凭据**：`credentials` 默认 `same-origin`，跨源必须显式 `include` | MDN Request.credentials 原文 | 硬（规范） |
| C6 | **`credentials:'include'` 还要服务器同意**：`Access-Control-Allow-Credentials` 必须为 true 且 `Access-Control-Allow-Origin` 必须回显具体 origin（不能 `*`） | MDN Using Fetch / MDN ACAC 原文 | 硬（规范） |
| C7 | **SameSite=Lax/Strict 的 cookie 在 fetch 中不会跨站发送**（Lax 的白名单明确排除 fetch） | MDN Set-Cookie 原文 | 硬（规范） |
| C8 | **导航类请求天然带 cookie，但不能附加自定义头**（除 DNR/（已废弃的 MV2 webRequest）） | MDN Set-Cookie（Lax 覆盖顶层导航/表单）；MV2 webRequest 的 extraHeaders 原文 | 硬 |
| C9 | **DNR 能改请求头**：`append` 的官方白名单**明文包含 `cookie`**；`set` 无明文禁止但也无官方示例 | Chrome DNR "Header modification" 原文 + MDN 同页 | 文档级；`set` 待实测 |
| C10 | **DNR 对 `chrome.downloads` 触发的请求疑似不生效**（对 DOM/导航触发生效） | Stack Overflow 77932227（**第三方报告**，非官方） | 中（旁证） |
| C11 | **服务器可以忽略 `Range`**：不支持时返回 200 + 全量内容 → 分片请求会拿到整文件 | MDN Range 原文："A server that doesn't support range requests may ignore the Range header and return the whole resource with a 200 status code." | 硬（规范） |
| C12 | **多段下载的三个前提**：有 Content-Length、无 Content-Encoding、`Accept-Ranges: bytes`（并且要实收 206） | TDM `wget.js` 源码；ipull 源码；aria2 手册（min-split-size 说明其分片逻辑） | 强（成熟实现） |
| C13 | **同域连接上限 6**（HTTP/1.1，Chromium 普通池） | Chromium `net/socket/client_socket_pool_manager.cc`："Default to allow up to 6 connections per host." | 硬（源码） |
| C14 | **HTTP/2 下是"一条连接多条流"**：并发上限由对端 `SETTINGS_MAX_CONCURRENT_STREAMS` 决定（"Initially, there is no limit to this value. It is recommended that this value be no smaller than 100"） | RFC 9113 §5.2.1 / §6.5.2：<https://www.rfc-editor.org/rfc/rfc9113.html#section-5.2.1> | 硬（RFC） |
| C15 | **响应体是顺序 ReadableStream**，不能随机读取（要分段只能靠 `Range` 头多次请求） | MDN `Response.body`："a ReadableStream of the body contents" | 硬（规范） |
| C16 | **FSA 文件写入支持任意 position/seek**，但 `showSaveFilePicker` 需要**瞬态用户激活** | MDN FileSystemWritableFileStream 示例 + MDN showSaveFilePicker + Chromium 企业策略原文 | 硬（规范 + 官方策略） |
| C17 | **OPFS 的同步随机写只在 dedicated worker 里可用**，且 `createSyncAccessHandle` 对文件加独占锁 | MDN createSyncAccessHandle 原文 | 硬（规范/实现） |
| C18 | **OPFS 受配额限制、可能被清理**；扩展可用 `unlimitedStorage` + `navigator.storage.persist()` 豁免 | MDN OPFS + Chrome *Storage and cookies* 原文 | 硬 |
| C19 | **页面卸载会中断 StreamSaver 式流式下载**；mitm SW 需要安全上下文；SW 会 idle | StreamSaver README 原文 | 中（README） |
| C20 | **Blob 有大小上限**（Chrome 2GB 量级；Firefox 800MiB 量级） | FileSaver README 表格 | 中（README，年代较老） |
| C21 | **MV3 service worker 会被终止**：空闲 30 秒、单个请求/事件处理超过 **5 分钟**、或 **`fetch()` 响应超过 30 秒才开始到达** | [Chrome Service worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle) 原文："After 30 seconds of inactivity" / "When a single request, such as an event or API call, takes longer than 5 minutes to process" / "When a fetch() response takes more than 30 seconds to arrive." | 硬（官方文档） |

---

## 5 对本项目的可用性判断

> 前提回顾：R9 裁定"拦截发生在 JS API 层，命中后请求根本不会发到网络"。因此 **cookie 需求不出现在"拦截 RPC"环节，只出现在"引擎真正去下载文件"环节**。下面按引擎能力（R11 的原子能力）给出判断。

### 5.1 需求 A → `withHeader` / cookie 类能力

**能借鉴（强烈推荐）**
- **Aria2 Explorer 的取 cookie 范式可整段照搬**：`chrome.cookies.getAll({url, storeId, partitionKey:{}})`（+ `"cookies"` 权限 + host 权限），`name=value` 拼接。代码短、两个独立项目验证过、且能覆盖 HttpOnly 与分区 cookie。
- 安全闸门（RPC 必须 https/localhost）值得照搬：如果引擎把 cookie 交给**扩展外部**的什么东西，明文 HTTP 泄露面是真实的。

**能直接用（在"浏览器内下载"这个方向上）**
1. **扩展 SW + host permissions + `fetch(credentials:'include')`**：让浏览器自己带 cookie。这是唯一"不用 `cookies` 权限、不手工拼 cookie"的正路，且 HttpOnly 自动带上。**代价**：不可控（无法只带部分 cookie）、依赖 host 权限未被收回、被 3PC 屏蔽策略影响。
2. **DNR `modifyHeaders`（append）注入 `Cookie`**：与附录 A 的机制同源（附录 A 已经在用 DNR 改请求头），官方白名单背书。**代价**：规则是扩展级（对所有匹配请求生效）、要动态增删、只能 append（不能替换/删除既有 cookie，除非 `set` 实测可用）。
3. **附录 A 路线（`chrome.tabs` 打开 URL，让浏览器原生下载流接管）**：cookie 天然带上、HttpOnly 天然带上、不需要 `cookies` 权限。**这就是"带 Cookie 下载"在当前裁定下最省事的路**。

**需要改造**
- 若 Mock 层要**汇报** `withHeader` 能力（R11/Q-B8 布尔能力），必须诚实区分三种子情形：① 只支持"浏览器自己带的 cookie"；② 支持自定义非敏感头（DNR）；③ 支持自定义敏感头（`Cookie`/`Referer`/`User-Agent`）——只有 ②③ 都可达时才算"完整 withHeader"。按 C2，**`chrome.downloads` 路线永远做不到 ③**。
- 若要把 `chrome.cookies` 读到的 cookie **注入到"浏览器自己发的下载"**里（即"既要让浏览器发，又要自定义 Cookie 值"），只有 DNR 一条路，且 `set` 可行性未验证 → **必须实测后再声明能力**（Q-C4：能力静态，运行时不可用要报错而不是缩能力）。

### 5.2 需求 B → `multithread` 能力

**能借鉴**
- TDM 的**判定条件与分片骨架**（长度 + 无内容编码 + `Accept-Ranges: bytes`；206 校验；min/max segment；offset 回写）是直接可复用的设计，且它已经和"每服务器连接上限"的现实妥协过（默认 3 线程）。
- ipull 给出的"探测 → `Range` 并发 → 按 cursor 回写 `onWrite(cursor, buffers)`"骨架，正好能接到 OPFS 的 `write(buf,{at:cursor})`。

**能直接用**
- `fetch` + `Range` 的并发请求本身：**可用**（扩展 SW 有 host 权限时不受 CORS 限制，`Accept-Ranges`/`Content-Range` 都能读；网页里则要 CORS 暴露响应头）。
- 落盘：**OPFS（dedicated worker 里的 `createSyncAccessHandle`）是唯一不打扰用户、又能随机写的方案**；FSA 目录句柄是"用户可见文件"的唯一方案，但需要一次手势。

**需要改造 / 做不到的**
- **aria2 的 `split` 语义无法原样复现**：aria2 的 `split` 允许跨 server 分片（多 URI），浏览器里没有"多服务器"概念；`max-connection-per-server` 在 HTTP/1.1 下会被 **6 连接/主机**（C13）约束，在 HTTP/2 下则变成"一条连接上的并发流"（C14），此时"线程数"只是并发流数，**收益模型与 aria2 完全不同**。
- **落盘路径与 aria2 语义冲突**：aria2 的 `dir` 是服务器端路径；浏览器里 OPFS 是私有沙箱，用户看不到，最后仍需"导出"（`chrome.downloads.download(blobURL)` 或 FSA 目录句柄）——**这一步的可行性与配额/内存限制需要在详细设计里专门解决**（`[未验证]`：`chrome.downloads.download` 是否接受 `blob:` URL；常规浏览器行为是接受，但我未找到明文证据）。
- **进度上报**（Q-B7）：多段引擎可以从各段 fetch 的字节数累加出真实进度 → 应上报真实进度；单连接降级时同样可以（基于 `Response.body` reader 的累计字节）。
- **断点续传**：需要自己实现（aria2 用 `.aria2` 控制文件记录分片状态）。浏览器侧可用：OPFS 里放一个"控制文件"（记录已完成分片 + ETag/Last-Modified），恢复时用 `If-Range` 校验（MDN If-Range）。`[设计建议，非既有方案]`

### 5.3 推荐组合（供能力清单/详细设计参考）

1. **Cookie 优先用"浏览器自己发"**：能走附录 A（tabs/原生下载）就走；需要扩展内 fetch 时用 `credentials:'include'` + host permissions。
2. **自定义头（尤其 `Cookie`/`Referer`）用 DNR**：与附录 A 已有机制统一，避免引入第三种机制。
3. **多线程只在满足 C12 时启用**，落盘用 **OPFS + dedicated worker**；不满足时**降级为单连接真实下载**（符合 R10 的"伪装还原"：真实结果兑现、`connections` 字段按 Q-B3 不变量自洽合成）。
4. **`chrome.downloads` 不应用于需要自定义敏感头的场景**（C2/C10），它适合"无头需求、只要落盘"的单连接路径（但要注意其 cookie 行为未验证）。
5. **引擎的长下载循环不能跑在 MV3 SW 里**（C21：`fetch()` 响应超过 30 秒才到达 / 单请求超过 5 分钟都会被终止）→ 多段下载的执行体建议放在**扩展页或 offscreen 文档 + dedicated Worker**；这也顺带解决了 C17（OPFS sync handle 只能在 dedicated worker 用）。

---

## 6 失败模式与盲区

| # | 失败模式 | 依据 / 说明 |
|---|---|---|
| F1 | **cookie 是快照**：长下载期间 cookie 轮转/过期，请求 401/403；Aria2 Explorer 把 cookie 当一次性字符串交给 aria2 → 同一问题 | A-5.1 源码 |
| F2 | **分区 cookie（CHIPS）/ storeId/incognito**：不查 `partitionKey` 会漏 cookie；`storeId` 不区分会拿到错误 store 的 cookie | Chrome cookies 文档（`partitionKey`/`storeId` 字段）+ Aria2 Explorer 同时查两份 |
| F3 | **3PC 屏蔽 / 用户收回 host 权限** → A-3.1 的 same-site 例外失效，cookie 静默不带 | Chrome *Storage and cookies* 原文 |
| F4 | **SameSite=None 必须 Secure**；扩展自身的 `chrome-extension://` 页无法设置 `Secure`/`SameSite=None`/`Partitioned` cookie | Chrome *Storage and cookies* 原文 |
| F5 | **在页面里注入的拦截器（MAIN world）拿不到 HttpOnly cookie**（`document.cookie` 看不到），也无法用 fetch 带自定义 cookie | MDN/C1；Chrome *Storage and cookies*："this only applies to network requests, not access through document.cookie" |
| F6 | **cookie 泄漏面**：把全量 cookie（含 HttpOnly）交给外部 aria2 后，明文 HTTP RPC 会把它暴露在网络里 | A-5.1 的安全闸门与本地化文案 |
| F7 | **DNR 规则串台**：同一 URL 的其他请求也会被注入 cookie / 被强制 `Content-Disposition` | Chrome DNR（扩展级规则）；附录 A.4.7 |
| F8 | **DNR 对 downloads 请求不生效**（第三方报告）→ 依赖 DNR 的 header 方案与 `chrome.downloads` 不兼容 | C10（旁证） |
| F9 | **服务器忽略 Range（200）**：分片请求拿到全量 → 数据错位/重复下载 | C11 |
| F10 | **压缩内容不能分片**：有 `Content-Encoding` 时 byte range 是"编码后字节"（且多数服务器不 range 压缩流） | TDM 判定条件（`contentEncoding === null`）；MDN Range："If the requested data has a content coding applied, each byte range represents the encoded sequence of bytes" |
| F11 | **同域 6 连接**：分片数 > 6 在 HTTP/1.1 下不会更快，反而挤占其他请求 | C13 |
| F12 | **HTTP/2 下"多线程"意义改变**：并发流数量受服务端 `SETTINGS_MAX_CONCURRENT_STREAMS` 限制；且单 TCP 连接的流控（window）可能成为新瓶颈 | C14；RFC 9113 §5.2 Flow Control |
| F13 | **扩展 SW 生命周期**：MV3 SW 在"空闲 30 秒 / 单个请求超过 5 分钟 / `fetch()` 响应超过 30 秒才到达"时会被 Chrome 终止 → **多段下载的长时间 fetch 循环不能放在 SW 里**（需 offscreen 文档 / 扩展页 + worker） | [Chrome Service worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle) 原文（见 C21）；StreamSaver README 的 SW idle 观察；本项目 Q-D3/Q-D5 已承认 SW 生命周期不可靠 |
| F14 | **OPFS 被清理/配额耗尽**：站点数据清理、磁盘压力驱逐会在中途毁掉分片 | C18 |
| F15 | **FSA 需要用户手势**：RPC 触发下载时无手势 → 保存对话框弹不出来 | C16 |
| F16 | **内存合并爆掉**：Blob/RAM 上限（Chrome ~2GB） | C20；DTA 的 "eat all the system memory" 评价 |
| F17 | **无分片校验**：DTA 明确说 WebExtension "cannot actually read the downloaded data"（指下载 API 的流），本项目自读流可以算 hash，但没有服务器提供的 per-piece hash | DTA TODO 原文；`[本项目可自行用 crypto.subtle 做整文件校验]` |
| F18 | **断点续传的资源变更**：服务器文件更新后按旧 offset 续传会拼出坏文件，必须用 `If-Range`/ETag 校验 | MDN If-Range（条件请求）；aria2 手册 `-c` |
| F19 | **`chrome.downloads` 的 cookie 行为未知**：可能有 cookie、可能没有（未验证），不能作为能力前提 | §8 |

---

## 7 与现有裁定的冲突（逐条对照 R1–R13 与附录 A）

| 裁定 | 与本调研的对照 | 判定 |
|---|---|---|
| **R1 目标形态**（转接到浏览器下载能力） | 需求 A 的成熟解法（交给**外部** aria2）方向相反；本项目要的是"浏览器内的下载能力"，**不能照抄 Aria2 Explorer 的最终落点**，只能借鉴"取 cookie"这一段 | 无冲突，但**借鉴范围要收窄** |
| **R2 能力缺口必须报错** | 若引擎声明 `withHeader` 但实际只能做到"浏览器自带 cookie"（不可控），属于能力的**过度声明**风险 → 建议把能力拆细或按 Q-C4 运行期报错 | 潜在冲突，需在能力清单里消解 |
| **R3 三值语义 / 伪装还原** | 多线程不可达时降级为单连接 + 合成 `connections` 数据 = 典型"伪装还原"（R10 判据：文件真的下载下来了） | 一致 |
| **R8 无法监听端口** | 与本调研无关（未被挑战） | 一致 |
| **R9 拦截在 JS API 层** | 关键结论：**拦截层与 cookie 无关**（请求根本不出网）；cookie 只在引擎真正下载时出现。A-3.1 的 same-site 例外只对"引擎发出的网络请求"有用 | 一致，且**澄清了一个容易混淆的点** |
| **R10 伪装还原判据 = 结果兑现** | 需求 B 的"单连接降级"完全符合；需求 A 中"浏览器自动带 cookie"也能兑现（文件下下来了） | 一致 |
| **R11 引擎声明原子能力（bool）** | 调研显示 `multithread` 与 `withHeader` **都是有条件的**（Accept-Ranges/206、敏感头/权限/3PC）。布尔模型无法表达这些条件 → 建议能力名拆细（如 `multiConnRange`、`customSensitiveHeader`），或按 Q-B8 的"能力缺失时该伪装还是拒绝由 Mock 层按类规定"处理 | 需要细化（与 Q-B8 的已知代价一致） |
| **R12 同时只启用一个引擎** | 无影响 | 一致 |
| **R13 用户可操作范围** | 若采用 FSA 目录句柄方案，"首次授权目录"属于"调整默认参数（例如保存目录）"的合法范围 | 一致 |
| **Q-B3 伪装自洽性**（`connections` 分片不重叠、并为文件分片划分） | 降级方案必须合成合法的 `connections` 数组；本调研不提供实现，仅指出**这是降级方案的必做项** | 一致，需实现 |
| **Q-B6 版本号不作协商开关** | 前端会展示 `--split` 之类的功能；用户对多线程的期待与本调研的"条件性可用"会碰撞 → 与 §6 已接受风险同源 | 一致（预期行为） |
| **Q-B7 进度姿态** | 多段/单段都能拿真实进度（字节累计），按 Q-B7"若引擎能拿真实进度则按真实进度上报" | 一致 |
| **Q-C4 运行期错误形态** | 权限不足（cookies/host permissions 被拒）、FSA 无手势、Range 不可用等，**不应缩能力**，应报错 | 一致，且给了具体场景 |
| **Q-D5 状态持久化不依赖 SW 内存** | 多段下载的分片状态必须落盘（OPFS 控制文件），**与 Q-D5 完全同构**；同时 OPFS 在"浏览器彻底退出"后仍在（除非用户清数据），需要注意"SW 重启不模拟重启"但"存储被清"是另一回事（C18/F14） | 一致，需在详细设计里处理 |
| **附录 A（`chrome.tabs` + 两条 DNR）** | ① 附录 A 用 DNR 注入请求头 —— 与本调研 C9（append 白名单含 cookie）**一致**；② 附录 A 断言"`chrome.downloads` 触发的下载会无视修改请求头的 DNR" —— 本调研找到**第三方实测报告**（C10）与**源码级的 header 限制**（C2）作为旁证，但**没有官方原文**；③ 附录 A 未涉及 cookie 来源，本调研补齐：**走 tabs 路线时 cookie 由浏览器自动带上（含 HttpOnly），不需要 `chrome.cookies` 权限** —— 这可能是附录 A 未写出的一个重要优点 | 一致；**附录 A 的前提仍需官方证据或实测确认** |

---

## 8 未验证 / 存疑（**不要当成事实使用**）

1. **DNR `set` 整个 `Cookie` 头是否生效**：官方只给了 `append` 白名单（含 cookie）；`set` 无禁止明文、也无官方示例 → **必须实测**（Chrome 桌面版，静态/会话规则各测一次）。
2. **`chrome.downloads.download()` 是否自动携带目标站点 cookie**：未找到官方明文；源码只显示请求 initiator 是扩展 origin。若"不带"，则"想让下载带 cookie 又不想走 tabs"就没有低成本方案。
3. **OPFS 的 `navigator.storage.getDirectory()` / `createWritable()` 在 extension service worker 里是否可用**（`createSyncAccessHandle` 肯定不可用——dedicated worker only）。
4. **`chrome.downloads.download({url: blobURL})` 是否被接受**（用于把 OPFS 里拼好的文件"导出"给浏览器落盘）。
5. **扩展页/offscreen 里 `showDirectoryPicker()` / `showSaveFilePicker()` 的行为与句柄持久化**（IndexedDB 存 `FileSystemHandle` + 再授权语义在扩展上下文是否一致）。
6. **`chrome.debugger` + CDP 改请求头**的可行性与代价（未查证官方原文）。
7. **Chrono Download Manager 是否真有多段下载**（未取到源码/官方技术说明）。
8. **Aria2 Integration（baptistecdr）取 cookie 的实现**（仓库无源码）。
9. **HTTP/2 下 Chrome 对同一 host 的并发 fetch 是否有额外节流**（除 `SETTINGS_MAX_CONCURRENT_STREAMS` 外）——未找到官方说明。
10. **Firefox 侧的对应结论**（除 DTA/MDN 外未系统调研；`browser.downloads.download({headers})` 的限制未查证）。
11. **服务器对 `Range` 的部分支持/错误 Content-Range 的实测行为**（只有规范层结论 C11）。
12. **DNR 是否真的完全不作用于 `chrome.downloads` 请求**（只有第三方报告 C10；官方 issue 40256297 页面为 JS 渲染，本轮**未能取到正文**——<https://issues.chromium.org/issues/40256297>）。

---

## 9 证据清单（URL + 原文摘录）

> 摘录均为抓取当日的页面/源码原文（英文原样）。`⚠` 标记表示该页/文件在引文中有重要日期或版本信息。

### 9.1 官方文档

1. **Chrome — Storage and cookies**（⚠ 页脚 "Last updated 2023-09-28 UTC"）
   <https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies>
   > "Requests from an extension to a third-party are treated as same-site if the extension has host permissions for the third-party. This means SameSite=Strict cookies can be sent. Note that this only applies to network requests, not access through `document.cookie` in JavaScript, and does not apply if third-party cookies are blocked."
   > "Third-party cookies are never blocked even in subframes if the top-level page for a given tab is a `chrome-extension://` page."
   > "Cookies set on `chrome-extension://` pages always use SameSite=Lax."
   > "Request the `"unlimitedStorage"` permission, which affects both extension and web storage APIs and exempts extensions from both quota restrictions and eviction."
   > "Extension storage is shared across the extension's origin including the extension service worker, any extension pages (including popups and the side panel), and offscreen documents. In content scripts, calling web storage APIs accesses data from the host page the content script is injected on and not the extension."

2. **Chrome — Cross-origin network requests**
   <https://developer.chrome.com/docs/extensions/develop/concepts/network-requests>
   > "Content scripts initiate requests on behalf of the web origin that the content script has been injected into and therefore content scripts are also subject to the same origin policy."
   > "A script executing in an extension service worker or foreground tab can talk to remote servers outside of its origin, as long as the extension requests host permissions."
   > "Cross-origin requests are always treated as such in content scripts, even if the extension has host permissions."

2b.【补充来源，编号不占用主线】**Chrome — Service worker lifecycle**（⚠ 页脚 "Last updated 2023-05-02 UTC"）
   <https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle>
   > "Normally, Chrome terminates a service worker when one of the following conditions is met:
   > - After 30 seconds of inactivity. …
   > - When a single request, such as an event or API call, takes longer than 5 minutes to process.
   > - When a fetch() response takes more than 30 seconds to arrive."
   > "Nevertheless, you should design your service worker to be resilient against unexpected termination."

3. **Chrome — chrome.cookies**
   <https://developer.chrome.com/docs/extensions/reference/api/cookies>
   > "To use the cookies API, declare the `"cookies"` permission in your manifest along with host permissions for any hosts whose cookies you want to access."
   > "True if the cookie is marked as HttpOnly (i.e. the cookie is inaccessible to client-side scripts)."（`httpOnly` 字段）
   > "This method only retrieves cookies for domains that the extension has host permissions to."（`getAll`）

4. **Chrome — chrome.downloads**
   <https://developer.chrome.com/docs/extensions/reference/api/downloads>
   > "Extra HTTP headers to send with the request if the URL uses the HTTP[s] protocol. Each header is represented as a dictionary containing the keys `name` and either `value` or `binaryValue`, restricted to those allowed by XMLHttpRequest."

5. **Chrome — chrome.declarativeNetRequest**（Header modification / 权限 / 规则上限 / 与 SW 的交互）
   <https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest>
   > "The append operation is only supported for the following request headers: accept, accept-encoding, accept-language, access-control-request-headers, cache-control, connection, content-language, cookie, forwarded, if-match, if-none-match, keep-alive, range, te, trailer, transfer-encoding, upgrade, user-agent, via, want-digest, x-forwarded-for. This allowlist is case sensitive"
   > "Before Chrome sends request headers to the server, the headers are updated based on matching modifyHeaders rules."
   > "A declarativeNetRequest only applies to requests that reach the network stack."
   > （权限）"The `"declarativeNetRequest"` and `"declarativeNetRequestWithHostAccess"` permissions provide the same capabilities. The difference between them is when permissions are requested or granted."

6. **MDN — declarativeNetRequest.ModifyHeaderInfo**
   <https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest/ModifyHeaderInfo>
   > "In Chrome, "append" is supported for the following request headers: … **Cookie** …"
   > "In Firefox, the extension needs host permissions for the new value of the Host header."

7. **Chrome — MV2 webRequest（历史路径）**
   <https://developer.chrome.com/docs/extensions/mv2/reference/webRequest>
   > "Starting from Chrome 72, the following request headers are not provided and cannot be modified or removed without specifying 'extraHeaders' in opt_extraInfoSpec: Accept-Language, Accept-Encoding, Referer, Cookie"

8. **MDN — Request.credentials**
   <https://developer.mozilla.org/en-US/docs/Web/API/Request/credentials>
   > "`same-origin`: Only send and include credentials for same-origin requests. **This is the default.**" / "`include`: Always include credentials, even for cross-origin requests."

9. **MDN — Using Fetch（Including credentials）**
   <https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API/Using_Fetch>
   > "Note that if a cookie's SameSite attribute is set to Strict or Lax, then the cookie will not be sent cross-site, even if credentials is set to include."
   > "the server must explicitly specify the client's origin in the Access-Control-Allow-Origin response header (that is, `*` is not allowed)"

10. **MDN — Set-Cookie（SameSite）**
    <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie>
    > "Lax: Send the cookie only for requests originating from the same site that set the cookie, and for cross-site requests that meet both of the following criteria: The request is a top-level navigation … This would exclude, for example, requests made using the fetch() API … It would include requests made when the user clicks a link in the top-level browsing context from one site to another, or an assignment to document.location, or a `<form>` submission."

11. **MDN — Access-Control-Allow-Credentials**
    <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Access-Control-Allow-Credentials>
    > "The server allows credentials to be included in cross-origin HTTP requests." / "`true` … This is the only valid value for this header"

12. **MDN — Forbidden request header**
    <https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header>
    > "A forbidden request header is an HTTP header name-value pair that cannot be set or modified programmatically in a request."（清单含 **Cookie**、Set-Cookie、Host、Origin、Referer、User-Agent…）

13. **MDN — Cookie header**
    <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cookie>
    > 字段表："Forbidden request header — **Yes**"

14. **MDN — Range / Accept-Ranges / 206 / If-Range / Content-Range**
    <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Range>
    > "A server that doesn't support range requests may ignore the Range header and return the whole resource with a 200 status code."
    > "The header is a CORS-safelisted request header when the directive specifies a single byte range."
    <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Accept-Ranges>
    > "`none`: No range unit is supported."
    <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/206>
    > "If several ranges are requested, the Content-Type is set to multipart/byteranges"
    <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/If-Range>
    <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Range>

15. **MDN — Response.body**
    <https://developer.mozilla.org/en-US/docs/Web/API/Response/body>
    > "The body read-only property of the Response interface is a ReadableStream of the body contents." / "The stream is a readable byte stream, which supports zero-copy reading using a ReadableStreamBYOBReader."

16. **MDN — FileSystemWritableFileStream（+ write）**
    <https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream>
    > "writableStream.write({ type: "write", position, data });" / "writableStream.write({ type: "seek", position });" / "writableStream.write({ type: "truncate", size });"
    > "Writes content into the file the method is called on, at the current file cursor offset."

17. **MDN — FileSystemFileHandle.createSyncAccessHandle / FileSystemSyncAccessHandle.write**
    <https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle/createSyncAccessHandle>
    > "Note: This feature is only available in Dedicated Web Workers."
    > "Creating a FileSystemSyncAccessHandle takes an exclusive lock on the file associated with the file handle. This prevents the creation of further FileSystemSyncAccessHandles or FileSystemWritableFileStreams for the file until the existing access handle is closed."
    <https://developer.mozilla.org/en-US/docs/Web/API/FileSystemSyncAccessHandle/write>
    > "`at`: A number representing the offset in bytes from the start of the file that the buffer should be written at."
    > "writes performed using FileSystemSyncAccessHandle.write() are much more performant. This makes them suitable for significant, large-scale file updates"

18. **MDN — OPFS**
    <https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system>
    > "It provides access to a special kind of file that is highly optimized for performance and offers in-place write access to its content."
    > "The OPFS is subject to browser storage quota restrictions …" / "Clearing storage data for the site deletes the OPFS."
    > "It also has a set of synchronous calls available … that can be run inside web workers only"

19. **MDN — showSaveFilePicker**
    <https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker>
    > "SecurityError DOMException: Thrown if the call was blocked by the same-origin policy or it was not called via a user interaction such as a button press."
    > "Transient user activation is required. The user has to interact with the page or a UI element in order for this feature to work."

20. **MDN — StorageManager.getDirectory / FileSystemFileHandle.createWritable**
    <https://developer.mozilla.org/en-US/docs/Web/API/StorageManager/getDirectory>
    > "Note: This feature is available in Web Workers."
    <https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle/createWritable>
    > "`keepExistingData` … When set to true if the file exists, the existing file is first copied to the temporary file."

21. **MDN — WebExtensions cookies（对照）**
    <https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/cookies/Cookie>
    > "`httpOnly`: A boolean, true if the cookie is marked as HttpOnly (i.e., the cookie is inaccessible to client-side scripts), or false otherwise."
    <https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/cookies/getAll>
    > "To use this method, an extension must have the `"cookies"` permission and relevant host permissions."

22. **RFC 9113（HTTP/2）**
    <https://www.rfc-editor.org/rfc/rfc9113.html#section-5.2.1>
    > "SETTINGS_MAX_CONCURRENT_STREAMS (0x03): This setting indicates the maximum number of concurrent streams that the sender will allow. … Initially, there is no limit to this value. It is recommended that this value be no smaller than 100, so as to not unnecessarily limit parallelism."

23. **Chromium 企业策略 — FileOrDirectoryPickerWithoutGestureAllowedForOrigins.yaml**
    <https://chromium.googlesource.com/chromium/src/+/main/components/policy/resources/templates/policy_definitions/Miscellaneous/FileOrDirectoryPickerWithoutGestureAllowedForOrigins.yaml>
    > "For security reasons, the showOpenFilePicker(), showSaveFilePicker() and showDirectoryPicker() web APIs require a prior user gesture ("transient activation") to be called or will otherwise fail."

24. **aria2 官方手册**
    <https://aria2.github.io/manual/en/html/aria2c.html>
    > `-s, --split=<N>` "Download a file using N connections. … The number of connections to the same host is restricted by the --max-connection-per-server option. … Default: 5"
    > `-x, --max-connection-per-server=<NUM>` "The maximum number of connections to one server for each download. Default: 1"
    > `-k, --min-split-size=<SIZE>` "aria2 does not split less than 2*SIZE byte range."
    > `--header=<HEADER>` "Append HEADER to HTTP request header."
    > `-c, --continue[=true|false]` "Continue downloading a partially downloaded file."

### 9.2 Chromium 源码

25. **`chrome/browser/extensions/api/downloads/downloads_api.cc`**
    <https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/extensions/api/downloads/downloads_api.cc>
    > ```cc
    > if (options.headers) {
    >   for (const downloads::HeaderNameValuePair& header : *options.headers) {
    >     if (!net::HttpUtil::IsValidHeaderName(header.name)) {
    >       return RespondNow(Error(download_extension_errors::kInvalidHeaderName));
    >     }
    >     if (!net::HttpUtil::IsSafeHeader(header.name, header.value)) {
    >       return RespondNow(Error(download_extension_errors::kInvalidHeaderUnsafe));
    >     }
    > ```
    > "// Service-worker-based extensions may have no associated `rfh`. … download_params->set_initiator(extension()->origin());"
    > "download_params->set_do_not_prompt_for_login(true);"

26. **`net/http/http_util.cc`**
    <https://chromium.googlesource.com/chromium/src/+/main/net/http/http_util.cc>
    > ```cc
    > // A header string containing any of the following fields will cause
    > // an error. The list comes from the fetch standard.
    > const char* const kForbiddenHeaderFields[] = {
    >     "accept-charset", "accept-encoding", "access-control-request-headers",
    >     "access-control-request-method", "connection", "content-length", "cookie",
    >     "cookie2", "date", "dnt", "expect", "host", "keep-alive", "origin",
    >     "referer", "set-cookie", "te", "trailer", "transfer-encoding", "upgrade",
    >     // TODO(mmenke): This is no longer banned, but still here due to issues
    >     // mentioned in https://crbug.com/571722.
    >     "user-agent", "via", };
    > ```

27. **`chrome/browser/extensions/api/downloads/download_extension_errors.h`**
    <https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/extensions/api/downloads/download_extension_errors.h>
    > `inline constexpr char kInvalidHeaderUnsafe[] = "Unsafe request header name";`

28. **`extensions/browser/api/cookies/cookies_api.cc`**
    <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/cookies/cookies_api.cc>
    > ```cc
    > net::CookieOptions options;
    > options.set_include_httponly();
    > ```
    > （`getAll` 路径）`cookies_helpers::GetAllCookiesFromManager(...)`（无 HttpOnly 过滤）

29. **`net/socket/client_socket_pool_manager.cc`**
    <https://chromium.googlesource.com/chromium/src/+/main/net/socket/client_socket_pool_manager.cc>
    > "// Default to allow up to 6 connections per host. Experiment and tuning may
    > // try other values (greater than 0).  Too large may cause many problems, such
    > // as home routers blocking the connections!?!?  See http://crbug.com/12066."
    > ```cc
    > std::array<size_t, kSocketPoolTypesSize> g_max_sockets_per_group =
    >     std::to_array<size_t>({ 6,   // kNormal
    >                             255  // kWebSocket
    >     });
    > ```

30. **`extensions/common/api/declarative_net_request.webidl`**
    <https://chromium.googlesource.com/chromium/src/+/main/extensions/common/api/declarative_net_request.webidl>
    > ```webidl
    > enum HeaderOperation {
    >   // Adds a new entry for the specified header. When modifying the headers of
    >   // <a href="#header_modification">specific headers</a>.
    >   "append",
    >   // Sets a new value for the specified header, removing any existing headers
    >   "set",
    >   // Removes all entries for the specified header.
    >   "remove"
    > };

### 9.3 既有方案源码 / README

31. **Aria2 Explorer**（v2.8.3，MV3）
    <https://github.com/alexhua/Aria2-Explorer> / <https://github.com/alexhua/Aria2-Explorer/blob/master/background.js>
    > `getCookies()`：`chrome.cookies.getAll({ url, storeId })` + `chrome.cookies.getAll({ url, storeId, partitionKey: {} })` → `cookieItems.push(name + "=" + value)`
    > `send2Aria()`：`headers.push("Cookie: " + cookieItems.join("; "));` … `options.header = headers;` … `aria2.addUri(downloadItem.url, options)`
    > `captureDownload`：`chrome.downloads.onDeterminingFilename.addListener(captureDownload)` + `chrome.downloads.cancel(downloadItem.id)`
    > `_locales/en/messages.json`："For insecure RPC, the related website cookies will not be attached when auto-download or direct export."
    > `manifest.json`：`"manifest_version": 3`, `"version": "2.8.3"`, `permissions` 含 `"cookies"`, `host_permissions: ["<all_urls>"]`

32. **YAAW-for-Chrome**（v1.0.0，MV3）
    <https://github.com/acgotaku/YAAW-for-Chrome/blob/master/background.js>
    > ```js
    > chrome.cookies.getAll({ url: fileDownloadInfo.link }, function (cookies) {
    >   const formatedCookies = []
    >   cookies.forEach(cookie => { formatedCookies.push(cookie.name + '=' + cookie.value) })
    >   const header = []
    >   header.push('Cookie: ' + formatedCookies.join('; '))
    >   header.push('User-Agent: ' + navigator.userAgent)
    >   const rpcData = { jsonrpc: '2.0', method: 'aria2.addUri', id: ..., params: [[fileDownloadInfo.link], { header }] }
    > ```

33. **Get cookies.txt LOCALLY**（0.7.2，MV3）
    <https://github.com/kairi003/Get-cookies.txt-LOCALLY>
    > `src/manifest.json`：`"permissions": ["activeTab", "cookies", "downloads", "notifications"]`, `"host_permissions": ["<all_urls>"]`
    > `src/modules/get_all_cookies.mjs`：`chrome.cookies.getAll(details)`（含 fetch 失败重试与分区处理）、`chrome.cookies.getAllCookieStores()`
    > `src/modules/cookie_format.mjs`：`jsonToNetscapeMapper` 只取 `{ domain, expirationDate, path, secure, name, value }`（**不区分 httpOnly，HttpOnly cookie 的值会被导出**）

34. **Turbo Download Manager**（MV2，最后提交 **2017-02-21**）
    <https://github.com/inbasic/turbo-download-manager/blob/master/src/lib/wget.js>
    > ```js
    > 'multi-thread': !!length &&
    >     contentEncoding === null &&
    >     req.getResponseHeader('Accept-Ranges') === 'bytes' &&
    >     lengthComputable !== 'false'
    > ```
    > ```js
    > obj.headers.Range = `bytes=${range.start}-${range.end}`;
    > ...
    > // make sure server supports partial content fetching; 206
    > if (res.status && res.status !== 206 && obj.headers.Range) {
    >   throw new utils.CError(`expected 206 but got ${res.status}`, 1, {url: obj.urls[0]});
    > }
    > ```
    > ```js
    > len = Math.max(len, obj['min-segment-size'] || 50 * 1024);
    > len = Math.min(len, obj['max-segment-size'] || 100 * 1024 * 1024);
    > let threads = Math.floor(info.length / len);
    > if (!info['multi-thread']) { threads = 1; }
    > ```
    <https://github.com/inbasic/turbo-download-manager/blob/master/src/lib/config.js>
    > `config.defineInt('wget.threads', 3);` / `config.defineInt('wget.min-segment-size', 50 * 1024, 1024);` / `config.defineInt('wget.max-segment-size', 100 * 1024 * 1024, 100 * 1024);`
    <https://github.com/inbasic/turbo-download-manager/blob/master/src/lib/opera/chrome-cm.js>
    > ```js
    > write: function (file, offset, arr) {
    >   return new Promise(function (resolve, reject) {
    >     file.createWriter(function (fileWriter) {
    >       let blob = new Blob(arr, {type: 'application/octet-stream'});
    >       fileWriter.onerror = (e) => reject(e);
    >       fileWriter.onwrite = () => resolve();
    >       fileWriter.seek(offset);
    >       fileWriter.write(blob);
    > ```
    <https://github.com/inbasic/turbo-download-manager/blob/master/src/lib/io.js>
    > `io.File.prototype.write = function (offset, arr) { … app.fileSystem.file.write(this.file, offset, arr) … }`
    > `flush()`：内部临时 FS 下用 `URL.createObjectURL(file)` + `link.dispatchEvent(new MouseEvent('click'))`
    <https://github.com/inbasic/turbo-download-manager/blob/master/src/lib/firefox/firefox.js>
    > 全仓库唯一 cookie 相关代码（下载管理器不自己构造 `Cookie` 头，依赖浏览器/特权 API）：
    > ```js
    > req.channel.QueryInterface(Ci.nsIHttpChannelInternal)
    >   .forceAllowThirdPartyCookie = true;
    > ```

35. **DownThemAll! WE**（4.15.1）
    <https://github.com/downthemall/downthemall/blob/master/Readme.md>
    > "we cannot do our own downloads any longer but have to go through the browser download manager always"
    > "From using `IndexedDB` to store retrieved chunks via `XHR`, to doing nasty service-worker tricks to fake a download that the backend would retrieve with `XHR`. The last one looks promising but I have yet to get it to work in a manner that is reliable, performs well enough and doesn't eat all the system memory for breakfast."
    <https://github.com/downthemall/downthemall/blob/master/TODO.md>
    > "P4 — Stuff that probably cannot be implemented due to WeberEension limitations."（原文拼写如此）
    > "**Segmented downloads** — Cannot be done with WebExtensions - downloads API has no support and manually downloading, storing in temporary add-on storage and reassembling the downloaded parts later is not only efficient but does not reliabliy work due to storage limitations."（原文拼写如此）
    > "**Checksums/Hashes?** — Cannot be done with WebExtensions - cannot actually read the downloaded data"

36. **ipull**
    <https://github.com/ido-pluto/ipull/blob/main/README.md>
    > "Super fast file downloader with multiple connections" / "Download using parallels connections" / "Download a file in the browser using multiple connections"
    > `image.src = downloader.writeStream.resultAsBlobURL(); console.log(downloader.writeStream.result); // Uint8Array`
    > `onWrite: (cursor: number, buffers: Uint8Array[], options) => {...}`
    <https://github.com/ido-pluto/ipull/blob/main/src/download/browser-download.ts>
    > `const DEFAULT_PARALLEL_STREAMS_FOR_BROWSER = 3;`
    <https://github.com/ido-pluto/ipull/blob/main/src/download/download-engine/streams/download-engine-fetch-stream/download-engine-fetch-stream-fetch.ts>
    > `headers.range = \`bytes=${this._startSize}-${this._endSize - 1}\`;`
    > `const acceptRange = this.options.acceptRangeIsKnown ?? response.headers.get("accept-ranges") === "bytes";`

37. **StreamSaver.js**（README；最后提交 2026-07-30）
    <https://github.com/jimmywarting/StreamSaver.js/blob/master/README.md>
    > "Instead of saving data in client-side storage or in memory you could now actually create a writable stream directly to the file system … This is accomplish by emulating how a server would instruct the browser to save a file using some response header + service worker"
    > "If the file you are trying to save comes from the cloud/server use the server instead of emulating what the browser does to save files on the disk using StreamSaver. Add those extra Response headers and don't use AJAX to get it."
    > "The download gets broken when you leave the page."；"initiate the `createWriteStream` on user interaction"；"worker goes idle after 30 sec in firefox, 5 minutes in blink"
    > （顶注）新规范 whatwg/fs "is more or less going to make FileSaver, StreamSaver and similar packages a bit obsolete in the future"

38. **FileSaver.js**（README；最后提交 2022-09-22）
    <https://github.com/eligrey/FileSaver.js/blob/master/README.md>
    > 浏览器 Max Blob Size 表：Chrome **2GB**、Firefox 20+ **800 MiB**、IE 10+ 600 MiB
    > "if you need to save really large files bigger than the blob's size limitation or don't have enough RAM, then have a look at the more advanced StreamSaver.js"

39. **browser-fs-access**
    <https://github.com/GoogleChromeLabs/browser-fs-access/blob/main/README.md>
    > "This module allows you to easily use the File System Access API on supporting browsers, with a transparent fallback to the `<input type="file">` and `<a download>` legacy methods. This library is a ponyfill."

40. **native-file-system-adapter**
    <https://github.com/jimmywarting/native-file-system-adapter/blob/master/README.md>
    > "Ponyfills for `showDirectoryPicker`, `showOpenFilePicker` and `showSaveFilePicker`, with fallbacks to regular input elements."
    > "`sandbox` (deprecated): Uses requestFileSystem … Only supported in Chromium-based browsers using the Blink engine."

### 9.4 第三方报告（**非官方，仅旁证**）

41. **Stack Overflow 77932227 — "Chrome Downloads API http requests are not getting modified by Declarative Net Request API"**（2024-02-03 提问，截至本次抓取 **0 回答**；通过 Atom feed 抓取）
    <https://stackoverflow.com/questions/77932227>（页面本身对 curl 403，本次经 <https://stackoverflow.com/feeds/question/77932227> 获取正文）
    > "when I try to download a file using chrome's Downloads API, the download request is not getting modified and hence fails."
    > "if I trigger the download from DOM, the request is getting modified properly."
    > "I have verified this behavior using chrome://net-export and netlog_viewer."
    > 提问者还贴出 `chrome.downloads.download({... headers: [{name:"Accept", value:"..."}]})` 的用法（即：他想用 DNR 补上的正是 downloads API 不接受的 forbidden 头）

42. **Chromium issue 40256297 — "Can't download PDF files from chrome extension by adding `content-disposition` in declarativeNetRequest"**
    <https://issues.chromium.org/issues/40256297>
    > `[未验证]`：该页为 JS 渲染，本轮**未能取到正文**（仅从搜索摘要知其标题/主题与"用 DNR 改 `Content-Disposition` 强制下载"相关）。**未作为证据使用**，仅登记线索。

---

## 附：本文件的取证方式（便于复核）

- 官方文档：`curl` 抓取 HTML → 去标签转文本 → 关键字定位；引用处保留英文原文。
- Chromium 源码：`chromium.googlesource.com/.../<file>?format=TEXT`（base64）→ 解码 → 关键字定位。
- 开源项目：`codeload.github.com/<owner>/<repo>/tar.gz/refs/heads/<branch>` 全仓库下载后本地 `grep`，避免"只读 README"的偏差；引用的 GitHub blob URL 均已用 HTTP 200 校验。
- 最后提交时间：`https://github.com/<owner>/<repo>/commits.atom` 的 `<updated>` 字段。
- 未取到证据的点，一律写入 §8，不猜测。
