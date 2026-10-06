# E5 — 替代与跨界途径：哪些能用、哪些必须出局

## 0 元信息

| 项 | 值 |
|---|---|
| 文档 ID | E5-alternatives |
| 所属任务 | t5（替代与跨界途径：哪些能用、哪些必须出局） |
| 作者 | eng-alt |
| 核对日期 | **2026-10-06（UTC）** |
| 目标浏览器基线 | Chrome 稳定版处于 **15x 系列**（`developer.chrome.com/release-notes` 显示 Chrome 155 的 release notes 已发布，见 E37；offscreen 文档已把 `hasDocument()` 标为 Chrome 150+，见 E1）；Manifest **V3**；Firefox 侧以 MDN / extensionworkshop 当前版本为准（MV3 自 **Firefox 109** GA，见 E23） |
| 输入 | `/workspace/docs/concept-design/concept-design.md` v0.5（R1–R13、Q-D2、Q-B7、Q-C4 等） |
| 本文范围 | 逐条评估 6 条"其它可能充当下载引擎/执行者"的途径 + 1 条跨界途径（IWA Direct Sockets）与其历史尸体（Chrome Apps `chrome.sockets.*`）；给出"进入候选清单 / 必须排除"两张清单 |
| 本文不涉及 | `chrome.downloads`（t1）、`fetch`/XHR 取字节（t2）、落盘与持久化（t3）、`chrome.tabs` + DNR（t4）、转发器侧拦截（t6–t10）——仅在需要划界时交叉引用 |
| 证据方法 | 只取**官方文档**（developer.chrome.com、developer.mozilla.org、extensionworkshop.com、blog.mozilla.org、chromedevtools.github.io / ChromeDevTools 官方仓库、w3.org、bittorrent.org）与**官方源码**（chromium/chromium 镜像、ChromeDevTools/devtools-protocol PDL）。每条结论给 URL + 逐字英文摘录。抓不到的写「未验证」。**时间敏感项全部标注页面自带的 Last updated 日期** |
| 采集方式说明 | 当前 CDP 文档站 `https://chromedevtools.github.io/devtools-protocol/tot/Fetch/` 已改为 JS 应用（页面只做重定向，正文由脚本渲染），因此 CDP 结论一律引用官方仓库里的协议源文件 `pdl/domains/*.pdl`（ChromeDevTools/devtools-protocol，协议版本 `major 1 minor 3`，见 E40）；`www.w3.org` 对 `curl` 返回 403（机器人防护），部分 W3C 页面改由 web_fetch 取得（见 §7） |

---

## 1 一句话结论

**这 6 条途径 + 1 条跨界途径里，没有任何一条能成为主下载引擎**：其中 3 条只值得到"上下文/兜底"级别的候选（offscreen document、扩展页面、`chrome.debugger` + CDP `Fetch` 域），其余必须明确排除（popup 作为执行者、用 WebTransport/WebRTC 承担 BT、native messaging、MV2 blocking `webRequest`、IWA Direct Sockets，另加已死的 Chrome Apps `chrome.sockets.*`），而 `chrome.debugger` 之所以不能进产品候选，不是因为它做不到，而是因为它的代价（**用户可见的"正在调试此浏览器"横幅 + 同一 target 只能挂一个调试器 + 与 DevTools 互斥 + 企业策略可禁用**）与 R1/R10 的"零安装、结果兑现"目标不相容。

### 1.1 应当进入候选清单的途径（3 条，全部带角色限定）

| 途径 | 候选角色 | 能支撑哪类下载 | 一句话理由（证据） |
|---|---|---|---|
| **offscreen document** | **DOM 承载上下文**（不是下载引擎） | 不能发起下载，但能承载需要 DOM/Blob/Worker/WebRTC 的引擎组件 | "The runtime API is the only extensions API supported by offscreen documents."（E1）⇒ 它拿不到 `chrome.downloads`；但可作为引擎内"需要 DOM 的小组件"宿主 |
| **扩展页面（`chrome-extension://` 页面 / 扩展标签页）** | **受限场景下的下载执行者** | 用户在页面上主动发起、且能接受"页面必须存在"的下载 | 扩展页面是完整扩展上下文（E29 的 CSP 定义明确含 popup/背景 worker/扩展打开的标签页），可跑 fetch/流/`chrome.downloads`（推论，见 §2.6）；但**无生命周期保障**（E27/E26） |
| **`chrome.debugger` + CDP `Fetch` 域** | **研究/兜底/诊断**（不进产品候选） | 命中 URL 时**返回任意响应体**、改写请求头/响应头/状态码——R9 语境下"最接近 DNR 替代品"的唯一机制 | "A domain for letting clients substitute browser's network layer with client code."；`Fetch.fulfillRequest` 带 `responseCode` / `responseHeaders` / `body`（E6）。代价见 E3/E4/E5 |

> 三者的角色互不相同：**只有第 2 条是"下载执行者"候选**，第 1 条是执行环境候选，第 3 条是能力验证与兜底手段。若只允许一条进"引擎候选"，答案是**扩展页面**——但它必须与"浏览器原生下载接管（`chrome.downloads`）"配合，否则一关页就断。

### 1.2 必须明确排除的途径（6 条 + 1 条已死途径）

| 途径 | 排除理由（一句话） | 关键证据 |
|---|---|---|
| **popup 作为下载执行者** | "Popups automatically close when the user focuses on some portion of the browser outside of the popup. There is no way to keep the popup open after the user has clicked away." | E24 |
| **WebTransport 承担 P2P / 类 BT 传输** | 必须有支持 WebTransport 的 **HTTP/3 服务器**（extended CONNECT + 2xx）才能建会话；datagram 只是"UDP-like"，不能连任意 UDP 端点 | E8 |
| **WebRTC data channel 承担 BT 传输** | 对端必须同样是 WebRTC 端点；WebTorrent 官方承认 web peer "can only connect to other clients that support WebTorrent/WebRTC"；BT 的 DHT 与 UDP tracker 要 UDP、peer wire 要 TCP/uTP，浏览器都不可达 | E9/E13/E10/E11/E12/E14 |
| **native messaging** | 必须在本机安装 native host（manifest + 注册表/固定路径），"The native application is not installed or managed by the browser." ⇒ 与 R1「免安装」直接冲突 | E15/E16 |
| **MV2 blocking `webRequest`（Chrome）** | Chrome 138 是最后一个支持 MV2 的版本，Chrome 139 起连企业豁免一起移除，2026-08-31 所有残留 MV2 扩展从商店下架；MV3 下 `webRequestBlocking` "is only available to policy installed extensions" | E17/E18/E19 |
| **IWA Direct Sockets（跨界）** | 官方明说首次发布"will only be available to Chrome Enterprise administered ChromeOS devices and select development partners"，且必须打包成 Signed WebBundle 并签名 ⇒ 既非"装一个扩展"，也非通用平台 | E35/E34 |
| （附）**Chrome Apps `chrome.sockets.tcp/udp`** | Chrome Apps 2020 年废弃，"supported only for ChromeOS until Jan 2025"——历史上唯一"网页拿 raw socket"的官方途径已经死亡 | E33 |

Firefox 的 `filterResponseData()` **不进候选清单，但保留"参照实现"地位**：它是当前唯一官方支持的"流式改写响应体"扩展能力，用来给 Chrome 侧的 CDP/DNR 能力上限做对照（E20/E21/E22，见 §2.5、§6）。

---

## 2 机制（逐条）

### 2.1 offscreen document（MV3）

**是什么。** MV3 扩展的 service worker 没有 DOM，offscreen document 是"隐藏文档"上下文，用来补 DOM 能力：

> "Service workers don't have DOM access, and many websites have content security policies that limit the functionality of content scripts. The Offscreen API allows the extension to use DOM APIs in a hidden document without interrupting the user experience by opening new windows or tabs."（E1，Last updated 2026-09-21）

**能用什么。**
- **DOM API 可用**；**扩展 API 只有 `runtime`**："The runtime API is the only extensions API supported by offscreen documents."（E1）
- **reason 枚举是封闭集合**（E1 原文）：`TESTING` / `AUDIO_PLAYBACK` / `IFRAME_SCRIPTING` / `DOM_SCRAPING` / `BLOBS` / `DOM_PARSER` / `USER_MEDIA` / `DISPLAY_MEDIA` / `WEB_RTC` / `CLIPBOARD` / `LOCAL_STORAGE` / `WORKERS` / `BATTERY_STATUS` / `MATCH_MEDIA` / `GEOLOCATION`。**没有任何与"下载""文件系统"相关的 reason**（E1 全文 grep 无 FILE/DOWNLOAD 类 reason）。
- `justification` 只是给用户看的字符串："which is a developer-written string, and not a parameter with effects on the document"（E2）。

**生命周期。**
- "Reasons are set during document creation to determine the document's lifespan. The AUDIO_PLAYBACK reason sets the document to close after 30 seconds without audio playing. **All other reasons don't set lifetime limits.**"（E1）
- 设计意图是"用完即走"："The page will have a lifetime mechanism similar to event pages in Manifest V2, in that it will be torn down when it stops performing actions."（E2，Last updated 2023-01-25）
- 数量：一个扩展（每 profile）**同时只能有一个**；incognito split 模式下普通与隐身各一个（E1/E2）。URL 必须是打包的静态 HTML（"An offscreen document's URL must be a static HTML file bundled with the extension."，E1）。

**能否发起下载 / 承载 File System Access？**
- 发起下载：**不能**（推论，依据 E1 的"只有 runtime API"）。`chrome.downloads` 属于扩展 API，offscreen 不在可用列表内。
- File System Access：**不能实用地承载**。两个硬点：① `showSaveFilePicker()` 是 `Window` 方法且 **"Transient user activation is required."**（E31）；② offscreen **"can't be focused"**（E1）⇒ 无法产生 user activation；Chrome FSA 文档给出的运行时错误正是 `SecurityError ... Must be handling a user gesture to show a file picker.`（E30）。
- 能做的是"承载 DOM 型组件"：Blob/`URL.createObjectURL`（`BLOBS`）、`DOMParser`（`DOM_PARSER`）、Worker（`WORKERS`）、WebRTC（`WEB_RTC`）、localStorage（`LOCAL_STORAGE`）——这些恰好是若干"引擎内部小组件"需要的东西。

**代价。** 需要 `offscreen` 权限；文档创建/销毁带来额外的生命周期管理（E1 提供 `runtime.getContexts()` 的存活检测模板）；不能聚焦、无用户手势。

**判定：进入候选清单（角色＝DOM 承载上下文，非下载引擎）。**
能支撑的下载类型：**无**（它自己不能落盘）。但对引擎层有真实价值：任何"需要 DOM/Blob/Worker 才能装配字节流"的引擎组件可以在 offscreen 里跑，再把字节交给真正的落盘途径。

### 2.2 `chrome.debugger` 与 CDP

**是什么。** 扩展通过 CDP 直接操作浏览器：

> "The chrome.debugger API serves as an alternate transport for Chrome's remote debugging protocol. Use chrome.debugger to attach to one or more tabs to instrument network interaction, debug JavaScript, mutate the DOM and CSS, and more."（E3，Last updated 2026-10-05）

**网络能力（能否替代 DNR 做请求改写 / 能否自定义响应体）。**
- 扩展可用域是**白名单**，`Fetch` 与 `Network` 都在名单内："For security reasons, the browser.debugger API does not provide access to all Chrome DevTools Protocol Domains. The available domains are: Accessibility, Audits, CacheStorage, Console, CSS, Database, Debugger, DOM, DOMDebugger, DOMSnapshot, Emulation, **Fetch**, IO, Input, Inspector, Log, **Network**, Overlay, Page, Performance, Runtime, Storage, Target, Tracing, WebAudio, and WebAuthn."（E3）
- `Fetch` 域的设计目的就是**用客户端代码替换网络层**："A domain for letting clients substitute browser's network layer with client code."（E6）。关键命令与参数（E6，PDL 原文）：
  - `Fetch.enable(patterns, handleAuthRequests)`："If not set, all requests will be affected."；`RequestPattern.requestStage` 取值 `Request` / `Response`（"Response will intercept after the response is received (but before response body is received)"）。
  - `Fetch.continueRequest(requestId, url, method, postData, headers, interceptResponse)`：**改 URL / 方法 / 请求体 / 请求头**。
  - `Fetch.fulfillRequest(requestId, responseCode, responseHeaders, binaryResponseHeaders, body, responsePhrase)`："Provides response to the request."，可给**任意 body**（"If absent, original response body will be used if the request is intercepted at the response stage and empty body will be used if the request is intercepted at the request stage."）。
  - `Fetch.continueResponse(...)`：**experimental**，"Continues loading of the paused response, optionally modifying the response headers. If either responseCode or headers are modified, all of them must be present."
  - `Fetch.getResponseBody`（返回 `body` + `base64Encoded`）与 `Fetch.takeResponseBodyAsStream`（返回 `IO.StreamHandle`，互斥）。
- `Network` 域**不能**替代 `Fetch` 做响应体替换：当前协议里 `Network.getResponseBody` 只读（"Returns content served for the given request."），且 `Network.setRequestInterception` **已从当前 `Network.pdl` 中消失**（本次核对 grep `setRequestInterception` 在 `pdl/domains/Network.pdl` 中**零命中**；E7）。也就是说，"拦截-改写"这件事在当前 CDP 里**只有 `Fetch` 域能做**。
- 因此：**"命中某 URL 时返回任意响应体"在 Chrome 里可达，但它走的是 CDP `Fetch.fulfillRequest`，而不是 DNR**（DNR 的动作枚举里没有改 body 的项：`block` / `redirect` / `allow` / `upgradeScheme` / `modifyHeaders` / `allowAllRequests`，E36）。

**代价（这是排除它进产品候选的原因）。**
1. 需要 `debugger` 权限（"You must declare the "debugger" permission in your extension's manifest to use this API."，E3）。
2. **用户可见的横幅**。Chromium 源码：桌面平台走 infobar 路径（"Win/Mac/Linux/Chrome OS use the infobar API for the warning message."），横幅文案是 `"$1" started debugging this browser`，且注释明确说明它**不会自动消失**："The label does not disappear until the user dismisses it, even if the debugger is detached..."（E4/E5）。
3. **同一 target 只能挂一个调试器**：Chromium 源码里的报错字符串为 `Another debugger is already attached to the * with id: *`（E5）——这意味着**用户开着 DevTools 时扩展 attach 会失败**，反过来扩展挂着时用户开 DevTools 也会冲突（同一常量覆盖两种客户端）。
4. **企业策略可直接毙掉**：`ExtensionSettings` 的 `runtime_blocked_hosts` 会让 attach 失败并报 "Host access is restricted by policy."；DLP/`DisableScreenshots` 会报 "Screenshot capture is restricted by policy."（E3）。
5. **跨上下文覆盖是 target 粒度**：tab 内多个同进程 frame 可能共享 target，跨进程 frame 要 `Target.setAutoAttach`（flatten session）才能继续下钻，"this is not recursive"（E3）。
6. **副作用式的好处**：Chrome 118 起"Active debugger sessions created using the browser.debugger API now keep the service worker alive."（E25）——调试会话能撑住 SW，但这依赖"一直挂着调试器"。

**判定：排除出产品候选；保留为"研究/兜底/诊断"手段。**
能力上它是**最强**的一条（唯一能改写请求头 + 响应头 + 返回任意响应体），但用户可见横幅 + 与 DevTools 互斥 + 策略可变，与 R1 的"无感安装"、R10 的"结果兑现"不相容。__若__未来做"带 header 下载"的实验验证（附录 A 那条 DNR 路线的可行性对照），可以临时用它做基准，但不进引擎清单。

### 2.3 WebTransport / WebRTC data channel

**WebTransport。** MDN 现状为 Baseline 2026 newly available（页面 last modified 2026-09-25）：

> "The WebTransport API provides a modern update to WebSockets, transmitting data between client and server using HTTP/3 Transport."；"To open a connection to an HTTP/3 server, you pass its URL to the WebTransport() constructor. Note that the scheme needs to be HTTPS, and the port number needs to be explicitly specified."；"A WebTransport connection requires a supporting server. To establish a session, the client sends an extended CONNECT request with a :protocol pseudo-header identifying WebTransport... The server accepts the session by sending a successful (2xx) response."；"It enables reliable transport via streams and unreliable transport via UDP-like datagrams."（E8）

⇒ 它是**客户端→HTTP/3 服务器**的传输；"datagrams"是 QUIC 会话内的不可靠消息，**不是**任意的 UDP socket；对端必须显式实现 WebTransport。做 BT 的 UDP tracker/DHT 前提是"能给任意 UDP 端点收发数据包"，WebTransport 不满足。

**WebRTC data channel。** 需要信令与 ICE（"ICE is a framework to allow your web browser to connect with peers."，STUN/TURN 视 NAT 而定，E38）；数据通道是 SCTP over DTLS（"any data transmitted on an RTCDataChannel is automatically secured using Datagram Transport Layer Security (DTLS)"；消息大小默认 "a default value of 64 kilobytes is assumed"，"most modern browsers support sending messages of at least 256 kilobytes"，E9）。对端必须是**同样讲 WebRTC 的 peer**。

**BT 在浏览器里到底缺什么（这条支撑「BT 判不实现」）。**

| BT 必需组件 | 规范原文 | 浏览器可达性 |
|---|---|---|
| peer wire protocol | "BitTorrent's peer protocol operates over TCP or uTP."（BEP 3，E10） | ❌ 没有 raw TCP；WebSocket 只能连 HTTP(S) 服务器 |
| DHT（BEP 5） | "The protocol is based on Kademila [1] and is **implemented over UDP**."；"A "peer" is a client/server listening on a **TCP port**... A "node" is a client/server listening on a **UDP port** implementing the distributed hash table protocol."（E11） | ❌ 没有 raw UDP，无法收 KRPC 查询、无法被其他节点查询 |
| UDP tracker（BEP 15） | "UDP Tracker Protocol for BitTorrent"；"An additional advantage is that a UDP based binary protocol doesn't require a complex parser and no connection handling"（E12） | ❌ 同 UDP；HTTP(S) tracker 可用 fetch 访问，但拿到 peer 列表也没用（连不上） |
| raw socket 规范 | W3C「TCP and UDP Socket API」可提供 raw UDP / TCP client / TCP server（E14），但状态是 **Working Group Note 2015-07-23**："Members of this Working Group have agreed **not to progress** the TCP UDP Sockets API specification further as a Recommendation track document"（E14） | ❌ 无浏览器实现（未把该 Note 当作实现依据）。另一份更早的「Raw Sockets」2013 Note 抓取被 W3C 防护拦截，见 §7 |

**WebTorrent 这条"浏览器 BT"路线本身也承认只能自成一体：**

> "except it uses WebRTC instead of TCP/uTP as the transport protocol"；"Therefore, a browser-based WebTorrent client or **"web peer"** can only connect to other clients that support WebTorrent/WebRTC."（E13，webtorrent 官方 FAQ）

（补充事实：该 FAQ 在本次核对时**未出现 DHT 相关段落**，即连 WebTorrent 自己也没有把"浏览器内 DHT"作为能力宣传——grep `dht` 零命中。）

**能力判定：**
- 能支撑的下载类型：**只有在"对端已实现同一协议"的专有网络里**做 P2P 分发（WebTransport 需要支持 WebTransport 的 HTTP/3 服务器；WebRTC 需要同样是 WebRTC 的 peer；WebTorrent 形态、IPFS 形态），对 aria2/BT 生态**零互通**。
- 代价：需要服务器/信令基础设施 + 自定义协议。
- **判定：排除**（对「BT 判不实现」这条裁定提供正面证据链）。

### 2.4 native messaging

**技术能力。** 扩展可启动本机进程并与其用 stdin/stdout 交换 JSON：

> "Extensions can exchange messages with native applications using an API... Native applications that support this feature must register a native messaging host that can communicate with the extension. Chrome starts the host in a separate process and communicates with it using standard input and standard output streams."；需要 `"nativeMessaging"` 权限；单条消息限制 "The maximum size of a single message from the native messaging host is 1 MB... The maximum size of the message sent to the native messaging host is 64 MiB."（E15）

**为什么与 R1「免安装」冲突。** 它的**全部前提**就是"本机先装好一个程序 + 装好 host manifest"：

> MDN: "Native messaging enables an extension to exchange messages with a native application, **installed on the user's computer**."；"**The native application is not installed or managed by the browser.** The native application is installed, using the underlying operating system's installation machinery. Create a JSON file called the "host manifest" or "app manifest". Install the JSON file in a defined location."；"The app manifest file must be installed along with the native application. The browser reads and validates app manifest files, but it does not install or manage them."（E16）

Chrome 侧同样要求落盘 + 注册表/固定路径：Windows 需要 `HKEY_LOCAL_MACHINE\SOFTWARE\Google\Chrome\NativeMessagingHosts\<name>` 或 `HKEY_CURRENT_USER\...`（"The application installer must create a registry key"），macOS/Linux 要放进 `NativeMessagingHosts/` 目录（E15）。host manifest 里的 `path` 指向本机可执行文件（"Path to the native messaging host binary"，E15）。

**判定：排除。**
能支撑的下载类型：**理论上"全套"**（挂 aria2 本体、挂任意下载器、拿到 raw socket）——但代价是把"免安装"这个 R1 硬目标整个抵掉：用户要先装 aria2/自研 host，扩展退化为"aria2 的另一个前端"，与项目定位相反。**注意这条也是"作弊解"**：任何"装一个本机小工具"的方案都属于 native messaging 的变体，必须一并排除。

### 2.5 MV2 blocking `webRequest`（含 Firefox `filterResponseData` 对照）

**Chrome：已经死透。**
- 时间线（官方页面 Last updated 2026-09-09，E17）："**Jul 24th 2025: Manifest V2 is disabled everywhere**. With Chrome 138 all users on all channels of Chrome have now Manifest V2 [disabled]... For Enterprises, the [ExtensionManifestV2Availability] policy will be removed with Chrome 139."；"**Aug 31st 2026: All remaining Manifest V2 extensions removed from the Chrome Web Store**. All remaining Manifest V2 extensions have been removed from the Chrome Web Store. Existing installs on Chrome 138 or earlier will continue to run, but they can no longer receive updates or be reinstalled if removed."
- MV3 下的能力边界（官方 `chrome.webRequest` 参考，Last updated 2026-09-11，E18）："Note: As of Manifest V3, the **"webRequestBlocking" permission is no longer available for most extensions**. Consider "declarativeNetRequest"... Aside from "webRequestBlocking", the webRequest API is unchanged and available for normal use. **Policy installed extensions** can continue to use "webRequestBlocking"."；权限表："webRequestBlocking — Required to register blocking event handlers. **As of Manifest V3, this is only available to policy installed extensions.**"
- 迁移文档同样给出唯一例外："You don't need to make these changes if your extension is installed by policy. For policy installed extensions, the webRequestBlocking permission is still available in Manifest V3."（E19）
- DNR 的替代上限（E36）：动作枚举只有 `block` / `redirect` / `allow` / `upgradeScheme` / `modifyHeaders` / `allowAllRequests`——**没有任何"改响应体"的动作**。

**Firefox 作为对照（有参考价值，但不进候选）。**
- Mozilla 官方政策（Manifest v3 update，2021-05-27）："After discussing this with several content blocking extension developers, we have decided to **implement DNR and continue maintaining support for blocking webRequest**."；"With both APIs supported in Firefox, developers can choose the approach that works best for them and their users. We will support blocking webRequest until there's a better solution which covers all use cases we consider important, since DNR as currently implemented by Chrome does not yet meet the needs of extension developers."（E22）MDN 的 Firefox 权限页把 `webRequestBlocking` 列为可用权限（只在 `webRequestAuthProvider` 旁标注 "(Manifest V3 and above)"，E39）。
- `filterResponseData()` 是 Firefox 独有的"流式改写响应体"：需要 `webRequest` + `webRequestBlocking` + 目标 host 权限；"To modify the HTTP response bodies for a request, call webRequest.filterResponseData, passing it the ID of the request. This returns a webRequest.StreamFilter object that you can use to examine and modify the data as it is received by the browser."；"**From Firefox 110, Manifest V3 extensions must also request the "webRequestFilterResponse" permission to use this API.**"（E20/E21）
- Firefox 侧补一条容易被忽略的机制：`BlockingResponse` 允许把请求**重定向到 `data:` URL**（"Redirections to non-HTTP schemes such as data: are allowed."，E18）——这等于用另一种方式"返回自定义内容"。把它与 `filterResponseData()` 合起来看：**"浏览器扩展返回任意响应体"在 Firefox 是官方可达的**；在 Chrome 侧等价能力只剩 CDP `Fetch.fulfillRequest`（§2.2）。

**判定：Chrome 侧排除**（MV2 blocking `webRequest` 作为实现手段已经不存在；策略安装例外对 C 端产品不适用）。**Firefox 的 `filterResponseData` 保留为"能力上限参照"**——它证明"浏览器扩展不装本机程序也能返回任意响应体"并非不可能，只是 **Firefox 独有**；具体是否纳入跨浏览器设计由 fwd-security/t10 定，本文只记录事实。

### 2.6 扩展页面 / popup 自己作为下载执行者

**popup：排除。** "Popups automatically close when the user focuses on some portion of the browser outside of the popup. There is no way to keep the popup open after the user has clicked away."（E24，Last updated 2023-12-12）。popup 是"一次点击的短事务"，不能承载下载任务，甚至连"打开下载、然后等它结束"都不成立。

**扩展页面（`chrome-extension://` 下的完整页面 / 扩展标签页）：可以作为受限执行者。**
- 它是**扩展上下文**：CSP 文档明确 "The "extension pages" policy applies to page and worker contexts in the extension. This would include the extension popup, background worker, and tabs with HTML pages or iframes that were opened by the extension."（E29）⇒ **推论**：扩展页面可以调用扩展 API（包括 `chrome.downloads`），并且可以用 fetch/流/Worker/WebSocket 做"自己下载"。与 offscreen 的对比给出了边界：offscreen 是明文的例外（只有 `runtime`，E1），扩展页面不是。
- **但没有任何生命周期保障**：
  - Chrome 会**主动丢弃空闲后台标签页**："When Memory Saver mode is enabled, Chrome will proactively discard tabs that have been unused in the background for some time."；"When a tab is discarded, its title and favicon still appear in the tab strip but **the page itself is gone, exactly as if the tab had been closed normally**. If the user revisits that tab, the page will be reloaded automatically."；"**there is no event that fires when a tab is discarded**, so there's no way for developers to react to the fact that it's happening."（E27，Chrome 108+）更早的 tab discarding 说明："a discarded tab doesn't go anywhere. We kill it but it's still visible on the Chrome tab strip."（E28）
  - 隐藏 5 分钟以上 + 5 层以上的定时器链 + 静音 30s 且无 WebRTC ⇒ **intensive throttling**："the browser will check timers in this group once per minute."（E26，Chrome 88+）。网络请求本身不受此限，但**轮询进度、看门狗、超时逻辑会被拖到分钟级**。
  - 用户可以直接关掉标签页；扩展页面没有被官方文档承诺过任何存活期（§7 标注）。
- CSP 限制："extension_pages" 默认为 `script-src 'self'; object-src 'self';`，且 "The extension_pages policy cannot be relaxed beyond this minimum value."（E29）——不能加载远程代码；对下载执行者而言影响不大（fetch/流是允许的），但意味着引擎逻辑必须打包。

**落盘这条路（与 t1/t3 的接口）：**
- `chrome.downloads.download()` 的 `headers` 参数被官方限定为 "restricted to those allowed by XMLHttpRequest"（E32）——这正是"扩展页面自己带 Cookie 下载"不可行的文档依据，也是附录 A 那条"用 DNR 注入敏感 header"方案存在的理由。
- File System Access 需要 **user activation**（E30/E31），扩展页面在**用户点击**时可以拿到（popup 也可以，但 popup 会关；扩展页面更稳），但**无法在后台无人值守时发起**。

**判定：进入候选清单（角色＝受限场景的下载执行者）。** 能支撑的下载类型：用户在前台页面上发起、字节由 fetch/流装配、再由 `chrome.downloads`（或 FSA，若有用户手势）落盘；**不支撑**"关掉所有页面后仍在跑的无人值守下载"。

### 2.7 跨界途径：IWA Direct Sockets（以及 Chrome Apps 的尸检）

**IWA Direct Sockets 是唯一"浏览器里能拿 raw TCP/UDP"的官方途径**，官方文档甚至直接点名 DHT：

> "Standard web applications are typically restricted to specific communication protocols like HTTP and APIs like WebSocket and WebRTC... **They cannot establish raw TCP or UDP connections**, which limits the ability of web apps to communicate with legacy systems or hardware devices that use their own non-web protocols."；"The Direct Sockets API addresses this limitation by enabling Isolated Web Apps (IWAs) to establish direct TCP and UDP connections without a relay server."；用例列表含 "**P2P systems: Implementing Distributed Hash Tables (DHT)** or resilient collaboration tools (like IPFS)"；并支持 "Server and listener capabilities: Configuring the IWA to act as a receiving endpoint for incoming TCP connections or UDP datagrams using TCPServerSocket or bound UDPSocket."（E34，Last updated 2025-12-17）

**但它的门槛与 R1 直接冲撞：**
- 能力只在 IWA 里、且需要 manifest 的 `permissions_policy` 打开 `direct-sockets`（+ `cross-origin-isolated`），否则构造函数 "immediately reject with a NotAllowedError"（E34）。
- IWA 不是"装一个扩展"：必须打包 + 签名——"Pages and assets for Isolated Web Apps can't be served from live servers or fetched over the network like normal web applications. Instead... web apps need to package all of the resources they need to run into a **Signed WebBundle**."（E35，Last updated 2026-02-06）
- 可用面：官方明说 "**The initial release of Isolated Web Apps, and any high-trust APIs that require them, will only be available to Chrome Enterprise administered ChromeOS devices and select development partners.** We are looking to expand this to additional partners and unmanaged and cross-platform devices in the future."（E35）

**历史参照（已死的同类）：** Chrome Apps 曾提供 `chrome.sockets.*`（sockets.tcp / sockets.udp），官方现状："Chrome Apps provided Chrome-specific APIs... **They were deprecated in 2020. They are supported only for ChromeOS until Jan 2025.**"（E33）⇒ 该路线不可复用。

**判定：排除（保留为"未来可能性"记录）。** 能支撑的下载类型：**理论上包括完整 BT/DHT/任意 TCP 下载**——但它要求企业托管的 ChromeOS + 签名打包，与"用户装一个扩展就用"是两种产品。**这也是「BT 判不实现」的最强反证边界**：不是浏览器绝对做不到，而是"在扩展形态下做不到"。

---

## 3 硬约束（可直接写进能力清单/设计输入）

### 3.1 上下文与 API 可达性

| 上下文 | 扩展 API 可达性 | DOM | 能否发起下载 | 证据 |
|---|---|---|---|---|
| service worker | 全量（除 DOM 类） | ✗ | 见 t1（本文不裁） | E25 |
| **offscreen document** | **只有 `runtime`** | ✓ | **✗**（推论：只有 runtime） | E1 |
| **扩展页面 / 扩展标签页** | 全量（同扩展上下文） | ✓ | ✓（`chrome.downloads`；FSA 需手势） | E29/E30/E31（推论） |
| popup | 全量 | ✓ | ✓ 但**活不到下载结束** | E24 |
| 内容脚本 | **仅白名单**：`dom` / `i18n` / `storage` / `runtime.connect()` / `runtime.getManifest()` / `runtime.getURL()` / `runtime.id` / `runtime.onConnect` / `runtime.onMessage` / `runtime.sendMessage()`；其余 API 只能靠消息转发 | ✓（页面 DOM） | ✗（不在白名单内） | E41 |
| CDP（`chrome.debugger`） | 不适用（走协议） | — | 可改写请求/响应（**非**落盘 API） | E3/E6 |
| IWA | 不是扩展（有独立 IWA API） | ✓ | 可建 raw TCP/UDP（**仅 IWA**） | E34/E35 |

### 3.2 offscreen 的四条硬约束（E1/E2）

1. `reasons` 是封闭枚举，无"下载/文件"类；`AUDIO_PLAYBACK` 之外无生命周期上限，但设计意图是"停止动作即拆除"（E1/E2）。
2. **每次只有一个** offscreen document（incognito split 例外）。
3. URL 必须是打包的静态 HTML。
4. **不能被聚焦 ⇒ 拿不到 user activation ⇒ 与所有"需要手势"的 API 绝缘**（与 E30/E31 组合）。

### 3.3 CDP 的五条硬约束（E3/E4/E5）

1. `debugger` 权限，且只覆盖白名单域（`Fetch`/`Network` 在列）。
2. 桌面平台显示 infobar：`"$1" started debugging this browser`，用户不点就不消失。
3. 一个 target 只能一个调试器：`Another debugger is already attached to the * with id: *`（与 DevTools 互斥）。
4. 企业策略可以整体禁用 attach。
5. 覆盖是 **target 粒度**，跨进程 frame/worker 需要 `Target.setAutoAttach(flatten)`，且不递归。

### 3.4 传输层硬约束（E8/E9/E10/E11/E12/E14）

| 需求 | 浏览器可得 | 硬约束 |
|---|---|---|
| HTTP(S) 客户端 | ✓ fetch/XHR | 受 CORS/凭据规则（见 t2） |
| WebSocket | ✓ | 只能连 HTTP(S) 服务器（upgrade） |
| QUIC/HTTP3 客户端（可靠流 / 不可靠 datagram） | ✓ WebTransport（Baseline 2026） | 对端必须是支持 WebTransport 的 HTTP/3 服务器 |
| 任意 UDP（DHT/UDP tracker） | ✗ | 规范（2015 Note）不推进、无实现 |
| 任意 TCP（peer wire） | ✗ | 同上 |
| 监听端口 | ✗ | 同上 |
| WebRTC P2P | ✓（需信令/ICE，可被 NAT 限制） | 对端必须是 WebRTC 端点 |

### 3.5 生命周期/用户可见性硬约束（E24/E25/E26/E27）

- popup：失焦即关，官方明确"没有办法"保持打开。
- 扩展 SW：30s 空闲终止 / 单次请求超 5 分钟 / fetch 响应超 30s（E25）。
- 扩展标签页：Memory Saver 主动丢弃，且**丢弃无事件**；隐藏 5 分钟后 timer 每分钟一次。
- 只有 `chrome.debugger` 会话（Chrome 118+）能**额外**撑住 SW（E25）——而它自带横幅。

---

## 4 能力映射

能力名沿用 R11 给出的样例（`multithread` / `withHeader` / `memUnlimited`），并补出与本轮途径强相关的若干能力。符号：✓ 有；△ 有条件/部分；✗ 无；"?": 未验证。
（"落盘可控""进度可观测"这两列与 t1/t3 有重叠，此处只作为**对照列**，详细结论以那两个任务为准。）

| 途径 | 任意响应体 | 请求头改写 | 响应头改写 | 落盘可控 | 进度可观测 | 后台无人值守 | 多连接/分片（`multithread`） | BT/P2P | 零安装（R1） |
|---|---|---|---|---|---|---|---|---|---|
| offscreen document | ✗ | ✗ | ✗ | ✗ | ✗ | △（随扩展进程存活，但不会自己干活） | ✗ | △（`WEB_RTC` reason 可用，但≠BT 互通） | ✓ |
| **扩展页面** | ✓（自己装配） | ✓（fetch） | N/A（自己产出的响应） | △（`chrome.downloads`；FSA 需手势） | △（自己算） | ✗（可被丢弃/关闭） | △（自己开多路 fetch） | ✗ | ✓ |
| popup | ✓ | ✓ | N/A | △ | △ | ✗（失焦即关） | △ | ✗ | ✓ |
| **`chrome.debugger` + CDP `Fetch`** | ✓（`fulfillRequest.body`） | ✓（`continueRequest.headers`） | ✓（`continueResponse`/`fulfillRequest.responseHeaders`） | ✗（不是落盘 API） | △（`Network` 事件可给 `bytesReceived` 类数据，需自行映射） | △（调试会话可撑 SW，但用户可见横幅） | ✗（不改并发模型） | ✗ | ✓（但横幅 + 与 DevTools 互斥） |
| WebTransport | ✗ | ✗ | ✗ | ✗ | ✗ | △ | △（多流） | △（仅同协议 peer） | ✓ |
| WebRTC data channel | ✗ | ✗ | ✗ | ✗ | ✗ | △ | △ | △（仅 WebTorrent peer） | ✓ |
| **native messaging** | ✓（交给本机程序） | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **✗（要装本机程序）** |
| MV2 blocking `webRequest`（Chrome） | ✗（**Chrome 的 webRequest 文档从未提供"改响应体"的能力**——能改的是请求头/响应头与 cancel/redirect；对照：Firefox 有 `filterResponseData`） | ✓（`onBeforeSendHeaders` / `onBeforeRequest`） | ✓（`onHeadersReceived`） | ✗ | ✗ | △ | ✗ | ✗ | **✗（Chrome 已移除）** |
| Firefox `filterResponseData` | ✓（`StreamFilter` 流式改写） | ✓ | ✓ | ✗ | ✗ | △ | ✗ | ✗ | ✓（Firefox 独有） |
| IWA Direct Sockets | ✗ | ✗ | ✗ | △（需自行落盘，IWA 有其他文件 API） | ✗ | ✓ | ✓（自行实现） | **✓（raw TCP/UDP/DHT 官方用例）** | **✗（企业托管 ChromeOS + 签名打包）** |

**映射到 R11 三个样例能力：**
- `withHeader`：**扩展页面**（fetch 自定义头）与 **CDP `Fetch.continueRequest`** 可达；`chrome.downloads` 被文档限制为 "restricted to those allowed by XMLHttpRequest"（E32）；native messaging 把所有问题外包（排除）。
- `multithread`：以上途径**没有一条**能改变浏览器的下载并发模型（`chrome.downloads` 由浏览器决定；fetch 多路只是多个单连接）。CDP/WebTransport/WebRTC 都不能让一个 HTTP 响应被多个 TCP 连接分段取——**这条能力在浏览器形态下找不到正面证据**（见 §7）。
- `memUnlimited`：本轮途径不提供任何"内存/落盘不受限"的官方保证；扩展页面可被丢弃（E27），offscreen 随扩展进程。

---

## 5 失败模式与盲区

### 5.1 offscreen document
- 想让它当执行者 ⇒ **设计期就撞墙**：没有下载类 reason、没有 `chrome.downloads`、不能聚焦（E1）。
- 若强行用 FSA 落盘：报 `SecurityError ... Must be handling a user gesture to show a file picker.`（E30）；对 RPC 客户端表现为"任务创建成功但永远不落盘"——**这正是 R10 定义的"假装正常"**，必须避免。
- 生命周期：reason 决定拆除时机，`AUDIO_PLAYBACK` 有 30s 无音频上限；其它 reason 无官方上限，但文档劝告"不要把它当背景页替代"（E2 原文："The offscreen document should not be the place to store primary extension logic because it has limited API access."）。

### 5.2 `chrome.debugger` / CDP
- **attach 失败**：已有调试器（DevTools/另一个扩展）⇒ `Another debugger is already attached to the * with id: *`（E5）；企业策略 ⇒ "Host access is restricted by policy." / "Screenshot capture is restricted by policy."（E3）。
- **用户取消**：点掉横幅即 detach（`DetachReason` 枚举含 `"canceled_by_user"`，E3）；对任务意味着"下载中途失去改写能力"。
- **半途失效的语义风险**：`Fetch.getResponseBody` 文档警告 "Calling other methods that affect the request or disabling fetch domain before body is received results in an **undefined behavior**."（E6）——依赖 CDP 的引擎在异常路径上没有可承诺的结果，违反 R10。
- **拦截盲区**：覆盖范围是 target 粒度，tab 之外的 target 不是随手可得——`Debuggee.extensionId` 附着到扩展背景页"is only possible when the `--silent-debugger-extension-api` command-line switch is used"；跨进程 frame 需要显式 auto-attach，且 "not recursive"（E3）。这会把 Q-D2 的盲区清单复杂化。
- **用户可见成本**：横幅永久驻留（E4 注释），在"零安装、无感"的产品叙事里是硬伤。

### 5.3 WebTransport / WebRTC / BT
- 失败模式：对端不是 HTTP/3+WebTransport ⇒ 建会话失败；对端不是 WebRTC ⇒ 连不上；DHT/UDP tracker ⇒ **根本没有 API**（E11/E12/E14）。
- 盲区：`magnet:` / `.torrent` 里的 tracker 列表（示例见 E13 的 magnet 带 `udp://` 与 `wss://`）在浏览器里只有 `wss://`/`https://` 形态可用，`udp://` 一条都不可用——对用户表现为"卡在 metadata 阶段"。R2 要求直接报错，这条证据支持在引擎能力层把 BT 标成"不实现"。

### 5.4 native messaging
- 未安装 host ⇒ `Specified native messaging host not found.`；注册表/路径不一致、32/64 位注册表视图问题都有独立报错（E15 的调试清单）。
- 消息上限：host→Chrome 1 MB / Chrome→host 64 MiB（E15）——传输大文件必须走文件路径而非消息。
- 盲区：它把"能力是否可得"交给了用户机器状态，属于 Q-C4 的"运行期错误"来源，但与 R1 冲突的不是错误形态而是前提本身。

### 5.5 MV2 / Firefox 对照
- Chrome：MV2 扩展在 Chrome 139+ 无法运行；商店 2026-08-31 已清理（E17）。任何"回退 MV2 拿 blocking webRequest"的想法都没有实施面。
- Firefox：`filterResponseData` 的已知限制是"小请求示例 + 分块/流式需要更复杂的写法"（MDN 的 Note："The example above only works for small requests that aren't chunked or streamed."，E21）；且它是 Firefox 独有 API（是否进入候选由跨浏览器评估决定）。
- **时效风险**：Mozilla "继续支持 blocking webRequest"的官方声明是 2021 年的（E22），本次核对**没有**找到更新的重申（见 §7）。

### 5.6 扩展页面 / popup
- popup：失焦关闭（E24）⇒ 下载任务被"关掉 UI"直接腰斩。
- 扩展页面：Memory Saver 主动丢弃且**无事件**（E27）⇒ 任何"页面内维护下载状态机"的设计都会在用户离开几分钟后静默丢失；`document.wasDiscarded` 只能**事后**发现（E27）。
- 隐藏页 timer 每分钟一次（E26）⇒ 进度上报/超时判定会退化。
- 结论性盲区：**扩展页面不能作为"保证跑完"的执行者**；要保证跑完就必须把字节交给浏览器下载栈（`chrome.downloads`）或 FSA 已授权的句柄。

### 5.7 IWA
- 普通用户装不上（企业托管 ChromeOS/开发伙伴，E35）⇒ 失败模式不是"报错"而是"这个产品形态根本不可分发"。

---

## 6 与现有裁定的冲突

| 裁定 | 冲突点 | 结论 |
|---|---|---|
| **R1 免安装** | native messaging 要求先装本机程序（E15/E16）；IWA 要求 Signed WebBundle + 签名 + 企业托管 ChromeOS（E34/E35）；Chrome Apps 已死（E33） | **这三条必须出局**；R1 保持不变 |
| **R9 拦截发生在 JS API 层** | `chrome.debugger`+CDP 是**网络层**改写（"substitute browser's network layer with client code"，E6），与 R9 的"请求根本不会发到网络上"是两条路 | 需**划界**：CDP 若用于**引擎**（给某个真实请求改头/换体），不违反 R9（R9 只约束**转发器**的拦截层次）；若有人想用 CDP 来实现"拦截转发"，那就是把 R9 推翻——**不允许**。本条建议由整合者写进边界文档的"层次定义"里 |
| **R2 报错而非假装正常 / R10 结果兑现** | CDP 的 `undefined behavior` 段（E6）、attach 被用户取消（E5 `canceled_by_user`）、offscreen 无手势无法落盘（E30） | 这些途径若被启用，必须把"环境失败"归入 Q-C4 的**运行期错误**（自定义状态码 + 信息），不得静默降级 |
| **R7/R11（引擎声明静态能力）/ Q-C4** | `chrome.debugger` 的可用性依赖用户是否开着 DevTools、企业策略、是否点掉横幅——这是**环境条件**，不是静态能力 | 若要采纳（本文不建议），只能按 Q-C4 处理：能力静态声明、运行期报错，不缩能力 |
| **R12 / Q-C5（同时只启用一个引擎、有任务禁止切换）** | CDP 会话是**全局副作用**（横幅、与 DevTools 互斥），比"启用一个引擎"影响面大得多 | 不宜做成"可选引擎"；若做诊断工具，应独立于引擎层 |
| **Q-D2 拦截盲区清单** | CDP 的 target 粒度覆盖（frame/worker 需 auto-attach 且不递归，E3）+ 扩展标签页会被丢弃（E27） | 盲区清单应新增两条："非 tab target（worker/其它扩展 SW）默认不在 CDP 覆盖内"、"扩展页面执行者会被 Memory Saver 丢弃" |
| **Q-D5（SW 重启不算重启）** | 若用 `chrome.debugger` 做引擎：SW 重启会丢调试会话（会话不持久化；E3/E25） | 必须在 SW 重启后重建 attach，且重建失败要报运行期错误；状态仍需持久化 |
| **Q-B7 进度姿态** | 本轮所有途径都拿不到 aria2 语义的 `connections` 分片/`bytesReceived`（除 `chrome.downloads` 与 `Network` 事件的部分字段） | 落 b 档（开始/结束两态）或由引擎自有进度；与 Q-B7 的补充裁定一致 |
| **R13（查看引擎能力报告）** | 上述"环境条件"（DevTools、策略、Memory Saver）都应出现在能力报告里 | 建议作为"环境检查"而非"能力位"呈现 |

**跨任务接口提醒（不越界，仅记录）：**
- t4（tabs + DNR）路线依赖"强制 `Content-Disposition: attachment`"来触发下载；**CDP `Fetch.fulfillRequest` 能在不改目标站点的前提下做同类事**（改响应头 + 给 body），可作为 t4 的对照实验手段，但不进产品。
- t1（`chrome.downloads`）的 header 限制（E32）与 native messaging 的"外包"是**两条不同的补丁**：前者限制能力，后者违反 R1。

---

## 7 未验证

1. **W3C「Raw Sockets」（2013 Note）的状态与原文**：`curl` 对 `www.w3.org` 全部返回 403（Cloudflare 拦截），`web_fetch` 对该 URL 也失败。**未能取得原文**。已取得的等价证据是 2015 年的「TCP and UDP Socket API」Note（E14），其"不推进到 Recommendation"的原文可引用。
2. **Firefox / Safari 是否支持 `chrome.offscreen`**：MDN 不文档 `chrome.*` 命名空间 API，extensionworkshop 的 MV3 迁移指南全文 grep `offscreen` **零命中**（E23）。⇒ **未验证**（Chrome 侧行为见 E1）。
3. **`chrome.debugger` attach 时显示横幅**：Chrome 扩展文档（E3）**没有**明写横幅；该结论来自 Chromium 源码 `chrome/browser/extensions/api/debugger/debugger_api.cc` 与字符串文件（E4/E5）。属**源码级证据**，不是文档级；未在真实 Chrome 上实测。
4. **"一个 target 只能一个调试器"是否等价于"与 DevTools 互斥"**：源码常量 `Another debugger is already attached to the * with id: *` 覆盖所有 ExDevTools 客户端（E5），但官方文档未给出"DevTools 打开时 attach 会失败"的明文。⇒ 表述为**源码级推论**。
5. **offscreen document 是否会在内存压力下被额外回收**：官方文档只给 reason 驱动的生命周期（E1/E2），未见内存压力/崩溃相关说明。⇒ **未验证**。
6. **扩展页面是否有任何官方存活保证**：未找到"扩展标签页不会被丢弃/不会被关闭"的官方承诺；反而有 Memory Saver 的主动丢弃（E27）。⇒ 按"无保证"处理（结论方向是保守的）。
7. **Firefox 当前（2026-10）是否仍保留 MV3 blocking `webRequest`**：官方明文只有 2021-05-27 的 Mozilla 博客（E22）+ MDN 权限页（E39）。⇒ 结论"Firefox 保留"属**官方政策声明（2021）**，**时效性未再验证**。
8. **`multithread` 是否真的在任何浏览器途径下不可达**：本文只证明了"本轮这些途径不改变并发模型"，**没有**穷举 `chrome.downloads` / `Range` 分片 / 流式 fetch 组合（属 t1/t2 范围）。⇒ 本条只标"未验证"，不作为结论。
9. **IWA 当前是否已放宽到非托管设备**：官方 IWA intro（Last updated 2026-02-06，E35）仍写 "initial release ... only be available to Chrome Enterprise administered ChromeOS devices"；本次**没有**找到 2026 年更新的放宽公告。⇒ 时效性未验证。
10. **Chrome 精确稳定版本号**：`developer.chrome.com/release-notes` 只说 "Release notes from Chrome 155 are available on Chrome Status"（E37），`chromereleases.googleblog.com` 在本环境 SSL 连接失败，故未取得精确 stable 版本号。⇒ 记作"15x 系列"。

---

## 8 证据清单

> 每条含：URL / 页面自带日期 / 逐字英文摘录（verbatim）/ 支撑的本文章节。摘录为抓取时的原文；仅做了空白归一化。

**E1 — chrome.offscreen API 参考（Chrome for Developers）**
- URL: https://developer.chrome.com/docs/extensions/reference/api/offscreen （Last updated 2026-09-21 UTC；Availability: Chrome 109+ / MV3+；`hasDocument()` Chrome 150+）
- 摘录：
  - "Service workers don't have DOM access, and many websites have content security policies that limit the functionality of content scripts. The Offscreen API allows the extension to use DOM APIs in a hidden document without interrupting the user experience by opening new windows or tabs."
  - "The runtime API is the only extensions API supported by offscreen documents."
  - "An offscreen document's URL must be a static HTML file bundled with the extension." / "Offscreen documents can't be focused."
  - "Though an extension package can contain multiple offscreen documents, an installed extension can only have one open at a time."
  - "Reasons are set during document creation to determine the document's lifespan. The AUDIO_PLAYBACK reason sets the document to close after 30 seconds without audio playing. All other reasons don't set lifetime limits."
  - Reason enum（完整）：TESTING / AUDIO_PLAYBACK / IFRAME_SCRIPTING / DOM_SCRAPING / BLOBS / DOM_PARSER / USER_MEDIA / DISPLAY_MEDIA / WEB_RTC / CLIPBOARD / LOCAL_STORAGE / WORKERS / BATTERY_STATUS / MATCH_MEDIA / GEOLOCATION
- 支撑：§2.1、§3.1、§3.2、§5.1

**E2 — "Offscreen Documents in Manifest V3"（Chrome for Developers Blog）**
- URL: https://developer.chrome.com/blog/Offscreen-Documents-in-Manifest-v3 （Last updated 2023-01-25 UTC）
- 摘录：
  - "The page will have a lifetime mechanism similar to event pages in Manifest V2, in that it will be torn down when it stops performing actions."
  - "only the chrome.runtime messaging APIs are exposed to the offscreen document."
  - "which is a developer-written string, and not a parameter with effects on the document"
  - "The offscreen document should not be the place to store primary extension logic because it has limited API access."
- 支撑：§2.1、§5.1

**E3 — chrome.debugger API 参考（Chrome for Developers）**
- URL: https://developer.chrome.com/docs/extensions/reference/api/debugger （Last updated 2026-10-05 UTC）
- 摘录：
  - "The chrome.debugger API serves as an alternate transport for Chrome's remote debugging protocol."
  - "You must declare the "debugger" permission in your extension's manifest to use this API."
  - "For security reasons, the browser.debugger API does not provide access to all Chrome DevTools Protocol Domains. The available domains are: Accessibility, Audits, CacheStorage, Console, CSS, Database, Debugger, DOM, DOMDebugger, DOMSnapshot, Emulation, Fetch, IO, Input, Inspector, Log, Network, Overlay, Page, Performance, Runtime, Storage, Target, Tracing, WebAudio, and WebAuthn."
  - 企业策略（原文）："Host restrictions: If enterprise policy ExtensionSettings configures blocked hosts (runtime_blocked_hosts) for an extension, browser.debugger.attach() is blocked on all targets with the error "Host access is restricted by policy.""；"Screenshot and DLP policies: ... browser.debugger.attach() fails with the error "Screenshot capture is restricted by policy."."
  - "Starting in Chrome 125, the browser.debugger API supports flat sessions."；"Auto-attach only attaches to frames the target is aware of... this is not recursive"
  - TargetInfoType 枚举："page" / "background_page" / "worker" / "other"；DetachReason 含 `"canceled_by_user"`。
  - 版本注记："Chrome now supports the standardized browser.* namespace (available from Chrome 148)."
- 支撑：§2.2、§3.3、§5.2、§6

**E4 — Chromium 源码：调试横幅字符串**
- URL: https://raw.githubusercontent.com/chromium/chromium/main/chrome/app/generated_resources.grd （main 分支，抓取于 2026-10-06）
- 摘录：`<message name="IDS_DEV_TOOLS_INFOBAR_LABEL" desc="Label displayed in an infobar when external debugger is attached to the browser. The label does not disappear until the user dismisses it, even if the debugger is detached...">"<ph name="CLIENT_NAME">$1<ex>Extension Foo</ex></ph>" started debugging this browser`
- 支撑：§2.2、§3.3、§5.2

**E5 — Chromium 源码：debugger 错误串与 infobar 路径**
- URL: https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/extensions/api/debugger/debugger_api.cc （main 分支，抓取于 2026-10-06）
- 摘录：
  - `constexpr char kAlreadyAttachedError[] = "Another debugger is already attached to the * with id: *.";`
  - `// Win/Mac/Linux/Chrome OS use the infobar API for the warning message.`（`ExtensionDevToolsClientHost::CreateWarningInfobar()`）
  - `#if !BUILDFLAG(IS_ANDROID) // Android uses the messages API for warnings.`
- 支撑：§2.2、§5.2

**E6 — CDP `Fetch` 域（官方协议源文件）**
- URL: https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/Fetch.pdl （master，抓取于 2026-10-06；协议版本见 E40）
- 摘录：
  - "# A domain for letting clients substitute browser's network layer with client code."
  - "Response will intercept after the response is received (but before response body is received)."
  - `command fulfillRequest`：`integer responseCode` / `optional array of HeaderEntry responseHeaders` / `optional binary body` / `optional string responsePhrase`
  - `command continueRequest`：`optional string url` / `optional string method` / `optional binary postData` / `optional array of HeaderEntry headers`
  - `experimental command continueResponse`："Continues loading of the paused response, optionally modifying the response headers. If either responseCode or headers are modified, all of them must be present."
  - `command getResponseBody`："...Calling other methods that affect the request or disabling fetch domain before body is received results in an undefined behavior."
  - `command takeResponseBodyAsStream`："The request must be paused in the HeadersReceived stage... This method is mutually exclusive with getResponseBody."
- 支撑：§2.2、§3.3、§4、§5.2、§6

**E7 — CDP `Network` 域（官方协议源文件）**
- URL: https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/Network.pdl （master，抓取于 2026-10-06）
- 摘录：`command getResponseBody`（"Returns content served for the given request." → `string body` / `boolean base64Encoded`）；**grep `setRequestInterception` 零命中**（该命令已不在当前协议中）
- 支撑：§2.2、§4

**E8 — MDN: WebTransport API**
- URL: https://developer.mozilla.org/en-US/docs/Web/API/WebTransport_API （last modified 2026-09-25）
- 摘录：
  - "Baseline 2026 — Newly available"
  - "The WebTransport API provides a modern update to WebSockets, transmitting data between client and server using HTTP/3 Transport."
  - "To open a connection to an HTTP/3 server, you pass its URL to the WebTransport() constructor. Note that the scheme needs to be HTTPS, and the port number needs to be explicitly specified."
  - "A WebTransport connection requires a supporting server. To establish a session, the client sends an extended CONNECT request with a :protocol pseudo-header identifying WebTransport."
  - "It enables reliable transport via streams and unreliable transport via UDP-like datagrams."
- 支撑：§1.2、§2.3、§3.4

**E9 — MDN: Using WebRTC data channels**
- URL: https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Using_data_channels （last modified 2026-06-22）
- 摘录：
  - "any data transmitted on an RTCDataChannel is automatically secured using Datagram Transport Layer Security (DTLS)"
  - "While most modern browsers support sending messages of at least 256 kilobytes..."；"If the max-message-size attribute is not present in the SDP, a default value of 64 kilobytes is assumed."
  - SCTP 相关接口：`RTCSctpTransport` / `RTCDtlsTransport`
- 支撑：§2.3、§3.4

**E10 — BEP 3: The BitTorrent Protocol Specification**
- URL: https://www.bittorrent.org/beps/bep_0003.html
- 摘录："BitTorrent's peer protocol operates over TCP or uTP."；"It is common to announce over a UDP tracker protocol as well."；tracker GET 参数含 `port`（默认 6881 起）
- 支撑：§2.3、§1.2

**E11 — BEP 5: DHT Protocol**
- URL: https://www.bittorrent.org/beps/bep_0005.html （Created 31-Jan-2008；Post-History 22-March-2013）
- 摘录："The protocol is based on Kademila [1] and is implemented over UDP."；"A "peer" is a client/server listening on a TCP port that implements the BitTorrent protocol. A "node" is a client/server listening on a UDP port implementing the distributed hash table protocol."
- 支撑：§2.3、§1.2、§5.3

**E12 — BEP 15: UDP Tracker Protocol for BitTorrent**
- URL: https://www.bittorrent.org/beps/bep_0015.html （Last-Modified Thu Jan 12 12:29:12 2017 -0800；Status: Accepted）
- 摘录："UDP Tracker Protocol for BitTorrent"；"An additional advantage is that a UDP based binary protocol doesn't require a complex parser and no connection handling..."
- 支撑：§2.3

**E13 — WebTorrent 官方 FAQ**
- URL: https://raw.githubusercontent.com/webtorrent/webtorrent/master/docs/faq.md （master，抓取于 2026-10-06）
- 摘录：
  - "except it uses WebRTC instead of TCP/uTP as the transport protocol."
  - "Therefore, a browser-based WebTorrent client or "web peer" can only connect to other clients that support WebTorrent/WebRTC."
  - （grep `dht` 在该文件零命中）
- 支撑：§2.3、§5.3

**E14 — W3C: TCP and UDP Socket API**
- URL: https://www.w3.org/TR/tcp-udp-sockets/ （W3C Working Group Note 23 July 2015）
- 摘录：
  - "This API provides interfaces to raw UDP sockets, TCP Client sockets and TCP Server sockets. As such, this requires a high level of trust in applications that use this API, since raw sockets can be used to work around the same origin security policy."
  - "Members of this Working Group have agreed not to progress the TCP UDP Sockets API specification further as a Recommendation track document, electing instead to publish it as an informative Working Group Note..."
  - 接口：`UDPSocket` / `TCPSocket` / `TCPServerSocket`（含 `localPort`、`joinMulticast` 等）
- 支撑：§2.3、§3.4

**E15 — Chrome: Native messaging**
- URL: https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging （Last updated 2026-09-16 UTC）
- 摘录：
  - "Native applications that support this feature must register a native messaging host that can communicate with the extension. Chrome starts the host in a separate process and communicates with it using standard input and standard output streams."
  - "To register a native messaging host, the application must save a file that defines the native messaging host configuration."
  - "On Windows, the manifest file can be located anywhere in the file system. The application installer must create a registry key, either HKEY_LOCAL_MACHINE\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.my_company.my_application or HKEY_CURRENT_USER\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.my_company.my_application"
  - "The maximum size of a single message from the native messaging host is 1 MB... The maximum size of the message sent to the native messaging host is 64 MiB."
  - "To use these methods, the "nativeMessaging" permission must be declared in your manifest."
  - "Specified native messaging host not found."（调试清单）
- 支撑：§2.4、§5.4

**E16 — MDN: Native messaging**
- URL: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging （last modified 2026-08-27）
- 摘录：
  - "Native messaging enables an extension to exchange messages with a native application, installed on the user's computer."
  - "The native application is not installed or managed by the browser. The native application is installed, using the underlying operating system's installation machinery."
  - "The app manifest file must be installed along with the native application. The browser reads and validates app manifest files, but it does not install or manage them."
- 支撑：§2.4、§1.2

**E17 — Chrome: Manifest V2 deprecation timeline**
- URL: https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline （Last updated 2026-09-09 UTC）
- 摘录：
  - "Aug 31st 2026: All remaining Manifest V2 extensions removed from the Chrome Web Store. All remaining Manifest V2 extensions have been removed from the Chrome Web Store. Existing installs on Chrome 138 or earlier will continue to run, but they can no longer receive updates or be reinstalled if removed."
  - "Jul 24th 2025: Manifest V2 is disabled everywhere. With Chrome 138 all users on all channels of Chrome have now Manifest V2 [disabled]... For Enterprises, the [ExtensionManifestV2Availability] policy will be removed with Chrome 139."
- 支撑：§2.5、§1.2

**E18 — Chrome: chrome.webRequest API 参考**
- URL: https://developer.chrome.com/docs/extensions/reference/api/webRequest （Last updated 2026-09-11 UTC）
- 摘录：
  - "Note: As of Manifest V3, the "webRequestBlocking" permission is no longer available for most extensions. Consider "declarativeNetRequest"... Aside from "webRequestBlocking", the webRequest API is unchanged and available for normal use. Policy installed extensions can continue to use "webRequestBlocking"."
  - "webRequestBlocking — Required to register blocking event handlers. As of Manifest V3, this is only available to policy installed extensions."
  - "onHeadersReceived (optionally synchronous) — Fires each time that an HTTP(S) response header is received... This event is intended to allow extensions to add, modify, and delete response headers, such as incoming Content-Type headers."
  - BlockingResponse.redirectUrl — "Only used as a response to the onBeforeRequest and onHeadersReceived events... Redirections to non-HTTP schemes such as data: are allowed."
- 支撑：§2.5、§1.2、§4

**E19 — Chrome: Migrate to declarative net requests（blocking web requests）**
- URL: https://developer.chrome.com/docs/extensions/develop/migrate/blocking-web-requests （Last updated 2023-03-09 UTC）
- 摘录："You don't need to make these changes if your extension is installed by policy. For policy installed extensions, the webRequestBlocking permission is still available in Manifest V3."
- 支撑：§2.5

**E20 — MDN: webRequest（Firefox）**
- URL: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest （last modified 2025-07-17）
- 摘录："To use the webRequest API for a given host, an extension must have the "webRequest" API permission and the host permission for that host. To use the "blocking" feature, the extension must also have the "webRequestBlocking" API permission."；"To modify the HTTP response bodies for a request, call webRequest.filterResponseData..."
- 支撑：§2.5

**E21 — MDN: webRequest.filterResponseData()**
- URL: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest/filterResponseData （last modified 2025-07-17）
- 摘录：
  - "To use this API, you must have the "webRequest" and "webRequestBlocking" API permissions, and for the event listener, the host permission for the host."
  - "From Firefox 110, Manifest V3 extensions must also request the "webRequestFilterResponse" permission to use this API."
  - "The example above only works for small requests that aren't chunked or streamed."
- 支撑：§2.5、§5.5

**E22 — Mozilla Add-ons Community Blog: "Manifest v3 update"**
- URL: https://blog.mozilla.org/addons/2021/05/27/manifest-v3-update/ （2021-05-27）
- 摘录："After discussing this with several content blocking extension developers, we have decided to implement DNR and continue maintaining support for blocking webRequest."；"With both APIs supported in Firefox, developers can choose the approach that works best for them and their users. We will support blocking webRequest until there's a better solution which covers all use cases we consider important, since DNR as currently implemented by Chrome does not yet meet the needs of extension developers."
- 支撑：§2.5、§7.7

**E23 — Firefox Extension Workshop: Manifest V3 migration guide**
- URL: https://extensionworkshop.com/documentation/develop/manifest-v3-migration-guide/
- 摘录："Manifest V3 became generally available in Firefox 109 after being available as a developer preview from Firefox 101."；"Manifest V3 (MV3) is the umbrella term for several foundational changes to the WebExtensions API in Firefox..."
- 支撑：§0、§7.2

**E24 — Chrome: Add a popup**
- URL: https://developer.chrome.com/docs/extensions/develop/ui/add-popup （Last updated 2023-12-12 UTC）
- 摘录："Popups automatically close when the user focuses on some portion of the browser outside of the popup. There is no way to keep the popup open after the user has clicked away."
- 支撑：§1.2、§2.6、§5.6

**E25 — Chrome: Extension service worker lifecycle**
- URL: https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle （Last updated 2023-05-02 UTC）
- 摘录：
  - "Normally, Chrome terminates a service worker when one of the following conditions is met: After 30 seconds of inactivity... When a single request, such as an event or API call, takes longer than 5 minutes to process. When a fetch() response takes more than 30 seconds to arrive."
  - "Chrome 118 — Active debugger sessions created using the browser.debugger API now keep the service worker alive."
  - "The Web Storage API is not available for extension service workers."
- 支撑：§3.5、§6

**E26 — Chrome Blog: Heavy throttling of chained JS timers beginning in Chrome 88**
- URL: https://developer.chrome.com/blog/timer-throttling-in-chrome-88/ （Last updated 2021-01-18 UTC）
- 摘录："Intensive throttling happens to timers that are scheduled when none of the minimal throttling or throttling conditions apply, and all of the following conditions are true: The page has been hidden for more than 5 minutes. The chain count is 5 or greater. The page has been silent for at least 30 seconds. WebRTC is not in use. In this case, the browser will check timers in this group once per minute."
- 支撑：§3.5、§5.6

**E27 — Chrome Blog: Memory and Energy Saver mode**
- URL: https://developer.chrome.com/blog/memory-and-energy-saver-mode （Last updated 2022-12-08 UTC）
- 摘录：
  - "When Memory Saver mode is enabled, Chrome will proactively discard tabs that have been unused in the background for some time."
  - "When a tab is discarded, its title and favicon still appear in the tab strip but the page itself is gone, exactly as if the tab had been closed normally."
  - "there is no event that fires when a tab is discarded, so there's no way for developers to react to the fact that it's happening."
  - "document.wasDiscarded"（事后检测）
- 支撑：§2.6、§3.5、§5.6

**E28 — Chrome Blog: Tab Discarding in Chrome（历史）**
- URL: https://developer.chrome.com/blog/tab-discarding （Last updated 2015-08-31 UTC）
- 摘录："Tab discarding allows Chrome to automatically discard tabs that aren't of great interest to you when it's detected that system memory is running pretty low."；"a discarded tab doesn't go anywhere. We kill it but it's still visible on the Chrome tab strip."
- 支撑：§2.6

**E29 — Chrome: content_security_policy manifest key**
- URL: https://developer.chrome.com/docs/extensions/reference/manifest/content-security-policy （Last updated 2024-02-13 UTC）
- 摘录：
  - "The "extension pages" policy applies to page and worker contexts in the extension. This would include the extension popup, background worker, and tabs with HTML pages or iframes that were opened by the extension."
  - 默认："script-src 'self'; object-src 'self';"；"The extension_pages policy cannot be relaxed beyond this minimum value."
- 支撑：§2.6、§3.1

**E30 — Chrome: File System Access API（web.dev/Chrome 文档）**
- URL: https://developer.chrome.com/docs/capabilities/web-apis/file-system-access （Last updated 2024-08-19 UTC）
- 摘录：
  - "Like many other powerful APIs, calling showOpenFilePicker() must be done in a secure context, and must be called from within a user gesture."
  - "A common gotcha is to do this work before the showSaveFilePicker() code has run, resulting in a SecurityError Failed to execute 'showSaveFilePicker' on 'Window': Must be handling a user gesture to show a file picker."（句号属于错误消息文本）
  - "The open file picker can only be shown using a user gesture when served from a secure context."
- 支撑：§2.1、§2.6、§5.1

**E31 — MDN: Window.showSaveFilePicker()**
- URL: https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker （last modified 2026-09-11）
- 摘录："Limited availability — This feature is not Baseline because it does not work in some of the most widely-used browsers."；"Secure context: This feature is available only in secure contexts (HTTPS)"；"Security — Transient user activation is required. The user has to interact with the page or a UI element in order for this feature to work."
- 支撑：§2.1、§2.6

**E32 — Chrome: chrome.downloads API 参考**
- URL: https://developer.chrome.com/docs/extensions/reference/api/downloads （Last updated 2026-10-04 UTC）
- 摘录：`headers` — "Extra HTTP headers to send with the request if the URL uses the HTTP[s] protocol. Each header is represented as a dictionary containing the keys name and either value or binaryValue, **restricted to those allowed by XMLHttpRequest**."
- 支撑：§2.6、§4、§6（与 t1/附录 A 对齐）

**E33 — Chrome for Developers: Apps（Chrome Apps）**
- URL: https://developer.chrome.com/docs/apps
- 摘录："Chrome Apps provided Chrome-specific APIs on top of standardized web technologies to enable you to create experiences that had more access to the underlying operating system. They were deprecated in 2020. They are supported only for ChromeOS until Jan 2025."
- 支撑：§2.7、§1.2

**E34 — Chrome for Developers: Isolated Web Apps — Direct Sockets**
- URL: https://developer.chrome.com/docs/iwa/direct-sockets （Last updated 2025-12-17 UTC）
- 摘录：
  - "Standard web applications are typically restricted to specific communication protocols like HTTP and APIs like WebSocket and WebRTC... They cannot establish raw TCP or UDP connections, which limits the ability of web apps to communicate with legacy systems or hardware devices that use their own non-web protocols."
  - "The Direct Sockets API addresses this limitation by enabling Isolated Web Apps (IWAs) to establish direct TCP and UDP connections without a relay server."
  - 用例："P2P systems: Implementing Distributed Hash Tables (DHT) or resilient collaboration tools (like IPFS)."
  - "Server and listener capabilities: Configuring the IWA to act as a receiving endpoint for incoming TCP connections or UDP datagrams using TCPServerSocket or bound UDPSocket."
  - "The direct-sockets key determines whether calls to new TCPSocket(...), new TCPServerSocket(...) or new UDPSocket(...) are allowed. If this policy is not set, these constructors will immediately reject with a NotAllowedError."
- 支撑：§2.7、§4、§1.2

**E35 — Chrome for Developers: Isolated Web Apps — Introduction**
- URL: https://developer.chrome.com/docs/iwa/introduction （Last updated 2026-02-06 UTC）
- 摘录：
  - "Note: The initial release of Isolated Web Apps, and any high-trust APIs that require them, will only be available to Chrome Enterprise administered ChromeOS devices and select development partners. We are looking to expand this to additional partners and unmanaged and cross-platform devices in the future."
  - "Pages and assets for Isolated Web Apps can't be served from live servers or fetched over the network like normal web applications. Instead, to gain access to the new high-trust security model, web apps need to package all of the resources they need to run into a Signed WebBundle."
- 支撑：§2.7、§1.2、§7.9

**E36 — Chrome: chrome.declarativeNetRequest API 参考（动作枚举）**
- URL: https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest （Last updated 2026-09-11 UTC）
- 摘录：RuleActionType 枚举 = `"block"` / `"redirect"` / `"allow"` / `"upgradeScheme"` / `"modifyHeaders"`（"Modify request/response headers from the network request."）/ `"allowAllRequests"`；"Note that if a request made it to this stage, the request has already been sent to the server and the server has received data like the request body. A block or redirect rule with a response headers condition will still run–but cannot actually block or redirect the request."
- 支撑：§2.2、§2.5（DNR 无"改 body"动作 ⇒ CDP `Fetch` 是唯一替代）

**E37 — Chrome for Developers: Release notes**
- URL: https://developer.chrome.com/release-notes
- 摘录："Release notes from Chrome 155 are available on Chrome Status."
- 支撑：§0、§7.10

**E38 — MDN: Introduction to WebRTC protocols**
- URL: https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Protocols （last modified 2026-09-17）
- 摘录："Interactive Connectivity Establishment (ICE) is a framework to allow your web browser to connect with peers. There are many reasons why a straight up connection from Peer A to Peer B won't work. It needs to bypass firewalls... and relay data through a server if your router doesn't allow you to directly connect with peers."；STUN / TURN 段落
- 支撑：§2.3

**E39 — MDN: manifest.json / permissions（Firefox）**
- URL: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/permissions （last modified 2026-06-11）
- 摘录：可用权限列表含 `webRequest` / `webRequestAuthProvider (Manifest V3 and above)` / `webRequestBlocking` / `webRequestFilterResponse` / `webRequestFilterResponse.serviceWorkerScript`；"webRequestBlocking enables you to use the "blocking" argument, so you can modify and cancel requests."
- 支撑：§2.5（Firefox 权限面），§7.7

**E40 — ChromeDevTools/devtools-protocol: 协议版本**
- URL: https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/browser_protocol.pdl （master，抓取于 2026-10-06）
- 摘录：`version` → `major 1` / `minor 3`
- 支撑：§0（CDP 证据来源说明）

**E41 — Chrome: Content scripts（能力白名单）**
- URL: https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts
- 摘录："Content scripts can access the following extension APIs directly: dom, i18n, storage, runtime.connect(), runtime.getManifest(), runtime.getURL(), runtime.id, runtime.onConnect, runtime.onMessage, runtime.sendMessage(). **Content scripts are unable to access other APIs directly.** But they can access them indirectly by exchanging messages with other parts of your extension."
- 支撑：§3.1（内容脚本行）

---

**结论复述（供整合者直接引用）**

- 进入候选清单：**offscreen document（DOM 承载上下文）**、**扩展页面/扩展标签页（受限执行者）**、**`chrome.debugger` + CDP `Fetch`（研究/兜底，不进产品）**。
- 必须排除：**popup 作为执行者**、**WebTransport 承担 P2P/BT**、**WebRTC data channel 承担 BT 传输**、**native messaging**、**Chrome MV2 blocking `webRequest`**、**IWA Direct Sockets**；另外记录 **Chrome Apps `chrome.sockets.*`** 已死。
- 对既有裁定的净影响：**R1 与「BT 不实现」两条裁定都得到正面证据支持**，无需修改 concept-design.md；新增两条盲区候选（CDP 的 target 粒度覆盖、扩展页面会被 Memory Saver 丢弃）建议由整合者写入 Q-D2 的盲区清单。
