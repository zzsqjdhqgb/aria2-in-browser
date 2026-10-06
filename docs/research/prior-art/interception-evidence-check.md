# 拦截三问 · 关键断言独立复核（t21 / 拦截证据核实）

## 0 元信息

| 项 | 值 |
|---|---|
| 文档性质 | **复核报告（第三份）**——对 t14 / t15 两份调研的**事实性断言**做独立核实；不重做调研、不做设计 |
| 复核人 | `sum-intercept-evidence`（t21，attempt 1） |
| 复核日期 | **2026-10-06（UTC）**；所有 URL 均为当日实际抓取 |
| 复核对象 | `/workspace/docs/research/prior-art/interception-three-questions.md`（t14，663 行，作者 prior-intercept-a）；`/workspace/docs/research/prior-art/interception-three-questions-2.md`（t15，834 行，作者 prior-intercept-b） |
| 前置阅读 | `/workspace/docs/concept-design/concept-design.md` v0.5（R4 / R5 / R8 / R9 / Q-D1 / §6） |
| 独立声明 | **未复用两位研究员的结论倾向**：本报告每一条都重新取一手证据。不采信两份文档中的任何引文，除非本次亲自下载到同一原文 |
| 取证手段 | ① 官方文档（Chrome for Developers / MDN / WHATWG 规范 / CDP 机器可读协议定义 JSON）② **Chromium 源码按 tag 逐版本抓取**（`chromium/chromium` GitHub 镜像 + `chromium.googlesource.com`；含当前 Stable tag `154.0.8037.0` 与 `main`）③ **npm registry 最新发布包**（下载 tarball 解包读源码）④ **Chrome Web Store CRX**（`clients2.google.com` 下载后解包，读 manifest 与发布产物） |
| 三态定义 | **已核实**＝本次拿到原文且与断言一致；**已证伪**＝本次拿到的原文与断言矛盾；**无法核实**＝本次取不到决定性证据（一律说明卡在哪） |
| 覆盖量 | 逐条核实 **62 条**断言（§2 表格行数）：**已核实 52 / 已证伪 5 / 无法核实 5**（其中 B9 为"主体已核实、例外分支无法核实"；另有若干"结论对但表述不精确"的附注，不计入三态） |
| 结论提要 | 两份研究的**主干结论全部成立**；但 t14 有 **5 条断言被证伪**（4 条版本/引用类 + 1 条 API 名笔误，其中 2 条直接影响"能否拦其它扩展"的版本叙事），t15 有 **3 条"无法核实"本次被成功核实**、1 条版本表述不精确 |

> **给下游的一句话**：t14/t15 关于"**DNR 不能合成响应体**、**CDP `Fetch.fulfillRequest` 能返回自定义响应体且代价高**、**MV3 `webRequest` 只能看**、**默认拦不到其它扩展的请求**、**JS API 层（MAIN world）是唯一零成本伪造响应体的路径**"五条主干结论，本次**逐条独立复核后全部维持**；需要修正的只有**版本归属**与**两条引用细节**（见 §3、§4）。

---

## 1 核实结论摘要

### 1.1 五条主干断言：全部维持

| 主干断言 | 复核结果 | 一句话证据 |
|---|---|---|
| DNR 不能合成自定义响应体（action 穷举，无 body 字段） | ✅ 已核实 | 官方 `RuleActionType` 只有 6 个取值；`RuleAction` 字段只有 `redirect` / `requestHeaders` / `responseHeaders` / `type`（本次抓取官方文档） |
| CDP `Fetch.fulfillRequest` 能返回自定义响应体 | ✅ 已核实 | 协议定义 `body` 参数原文 + Tamper Dev 商店版 MV3 产物里的 `Fetch.fulfillRequest`（本次 CRX 解包） |
| `chrome.debugger` 代价：用户可见信息条、与 DevTools 互斥、单调试器、企业策略 | ✅ 已核实 | 源码 `suppress_warning` 分支 + `generated_resources.grd` 原文 + `onDetach` 文档 + 官方博客 |
| MV3 `webRequest` 只能观测（除策略安装扩展） | ✅ 已核实 | 官方文档 `webRequestBlocking` "only available to policy installed extensions" + "the webRequest API is unchanged and available for normal use" |
| content script 不能注入 `chrome-extension://` 页面 | ✅ 已核实 | `user_script.cc` 的 `kValidUserScriptSchemes` 不含 `SCHEME_EXTENSION` + match patterns 文档 scheme 清单 |
| **`chrome.webRequest` / DNR 看不到其它扩展发起的请求**（本题最重要） | ✅ 已核实（结论）；⚠️ **版本叙事证伪** | 源码两处过滤都在；但**不是 Chrome 117 / 129-130 引入**（见 1.2） |
| MAIN world JS 层改写是唯一"零用户成本 + 任意响应体"路径 | ✅ 已核实 | 隔离世界互不可见 + MAIN world 受页面 CSP + 五个库均替换全局绑定 |

### 1.2 被证伪的断言（5 条，全部来自 t14 的版本/引用核对）

| # | 断言（出处） | 证伪证据（摘要） | 后果 |
|---|---|---|---|
| X1 | "webRequest 自 **Chrome 117** 起才按渲染进程过滤其它扩展的请求（116 无 / 117 有）"（t14 §2.2、§4.2、C12、证据表 E25） | 该过滤在 **51.0.2704.79（2016）** 的 `extensions/browser/api/web_request/web_request_api.cc` 中**已经存在**；70 / 92 / 100 / 104 / 110 / 116 全都有。117 的差异只是**文件被拆分为 `extension_web_request_event_router.cc`**（116 的目录里没有这个文件） | t14 的"逐 tag 核对"是**假阴性**；若下游引用"117 之前也许能拦"，会得到反向结论。真实结论是：这是**十年未变的既定行为** |
| X2 | "DNR 跳过其它扩展请求这条在 **128 无 / 130 有**（129/130 引入）"（t14 §4.3、C13、证据表 E27） | 128.0.6613.84 **已有**该过滤（126/127 无）；128 版本里变量名拼写为 **`initator_precursor`**（少一个 `i`），按正确拼写 grep 必然落空。"非 main_frame"这个例外在 **133 无 / 134 有** ⇒ 例外是 **Chrome 134** 加的 | 版本叙事错误：真实演进是"128 起**跳过其它扩展的全部请求**（含 main_frame）→ 134 起**放开 main_frame 导航**"。t14 恰好把方向说反了 |
| X3 | "Chrome **stable ≈ 155**；官方博客称 Chrome 155 Stable 于 2026-10-06 开始 rollout"（t14 §0 元信息） | `chromiumdash` 与 `chromereleases` 官方博客：**2026-10-06 的 Stable 是 154.0.8037.97/.98（2026-10-01 发布）**；155 处于 **Beta**（ChromeOS Beta 155.0.8059.31，2026-10-05） | 基线写错。凡以"155 已进入 stable"为前提的推论必须重新表述（企业策略那条"Chrome 155 起"仍是官方原文，属于"将在 155 生效"） |
| X4 | "**MDN 的 match pattern 文档把 `(chrome-)extension` 列为合法 scheme**"（t14 §4.1） | 本次抓取的当前 MDN 文本中检索 `moz-extension` / `chrome-extension` **0 命中**；`<all_urls>` 列出的 scheme 是 "http", "https", "ws", "wss", "ftp", "data", "file" | 该论据不存在；t14 的结论（不能注入）仍由 ①Chrome match patterns 文档 ②`user_script.cc` 两条证据支撑，不受影响 |
| X5 | 事件名 **`onSendRequest`**（t14 §2.2） | 官方 webRequest 事件表里 `onSendRequest` **0 命中**，正确名是 **`onSendHeaders`**（t15 用的是正确名） | 笔误；按这个名字写代码/查文档会失败 |

> **t14 的错误性质**：X1、X2 **不是判断错误，而是"我核对过版本"的方法本身有漏洞**——用"文件在某个 tag 上是否存在"代替"代码内容在某个 tag 上是否存在"，且用**正确拼写的标识符**去 grep 一个**拼错的标识符**。这是本报告最想留给团队的方法论教训（见 §6.5）。

### 1.3 t15 的三条"无法核实"本次被成功核实（可以撤销）

t15 §10.5 记录了"三条取证通道全失败"（CWS 页面 JS 渲染、CRX 下载 TLS 被拒、chrome-stats 403），因此把 ModHeader 标为"完全未验证"、把 Requestly 的 manifest 标为"未验证"。**本次这三条通道里最关键的 CRX 下载在本环境完全可用**：

| t15 的未验证项 | 本次结果 | 取法 |
|---|---|---|
| U1 ModHeader 用了什么 API | ✅ **已核实**：MV3，版本 `2026.8.8.18`，权限仅 `clipboardRead/clipboardWrite/declarativeNetRequest/storage` + `host_permissions: <all_urls>`，**无** `webRequest`/`debugger`/content scripts；`background.js` 使用 `modifyHeaders` + `updateDynamicRules`/`updateSessionRules` | CRX 下载解包读 manifest 与 background.js |
| U2 Requestly 扩展的 manifest / API | ✅ **已核实**：MV3，`26.9.29`，权限含 `declarativeNetRequest` + `webRequest` + `scripting` + `proxy` + `tabs` + `webNavigation`，静态 ruleset `delayRules`/`headerRules`，`externally_connectable.ids` 白名单 | 同上 |
| U16 Tamper Dev / Requestly / Resource Override 商店实际形态（部分） | ✅ **已核实**：Tamper Dev 商店版为 **MV3**，权限 `debugger/activeTab/scripting`，后台产物含 `Fetch.enable` / `Fetch.continueRequest` / `Fetch.fulfillRequest`；仓库 `v2/manifest_base.json` 确为 **MV2**（t15 说法成立） | CRX 解包 + GitHub raw |

⇒ **建议**：t15 §2.6.2 / §2.6.1 / §9 U1·U2 的"未验证"标记可以直接升级为已核实（结论与 t14 一致）；"Requestly 开源仓默认分支不含 `browser-extension` 目录"（t15 §10.5）本次**仍未核实**（GitHub API 403 rate limit），保留无法核实。

---

## 2 逐条核实表

> 列说明：**出处**＝t14＝`interception-three-questions.md`，t15＝`interception-three-questions-2.md`，括号内为章节号。
> 证据列给"最短可判决原文"；完整 URL 见 §7。

### 2.1 A 组 — DNR（本题第一优先）

| # | 断言 | 出处 | 核实结果 | 证据（原文摘录 + URL） | 影响 |
|---|---|---|---|---|---|
| A1 | DNR 的 action 穷举，**没有任何能携带响应体的字段**，因此不能合成自定义响应体 | t14 §2.3、C4；t15 §2.3、C3 | ✅ **已核实** | `RuleActionType` 枚举原文只有：`"block"` / `"redirect"` / `"allow"` / `"upgradeScheme"` / `"modifyHeaders"` / `"allowAllRequests"`；`RuleAction` 属性只有 `redirect / requestHeaders / responseHeaders / type`。[declarativeNetRequest](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest) | 方案主干成立：DNR 不能做 RPC 响应生成器 |
| A2 | `redirect.url` 禁止 `javascript:`；`transform.scheme` 允许 `http/https/ftp/chrome-extension` | t14 §2.3；t15 §2.3 | ✅ **已核实** | "The redirect url. **Redirects to JavaScript urls are not allowed.**"；"Allowed values are `"http"`, `"https"`, `"ftp"` and `"chrome-extension"`."（同页） | redirect 只能做 URL 级替换，不能做 body |
| A3 | `redirect` 到 `data:` 是否可行 | t14 §9.1（未验证）；t15 U3（未验证） | ⚠️ **无法核实** | 官方文档只显式禁止 `javascript:`，未提 `data:`；本次**未实测**、也未在官方源码里找到"允许/拒绝 data:"的判定分支 | 保持"未验证"是对的；任何把 `data:` 当作 DNR 造 body 依据的写法都不成立 |
| A4 | DNR 只作用于到达网络栈的请求；不影响 SW 生成的响应与 CacheStorage，但影响 SW 里的 `fetch()` | t14 §2.3、C5；t15 §2.3 | ✅ **已核实** | "A declarativeNetRequest only applies to requests that reach the network stack. … **won't affect responses generated by the service worker or retrieved from `CacheStorage`, but it will affect calls to `fetch()` made in a service worker.**"（同页） | 转发器的盲区清单可直接引用这一句 |
| A5 | 规则上限：静态保证 30000 / 动态 unsafe 5000、safe 30000（Chrome 121+）/ session 5000 / regex 1000 | t14 §2.3 | ✅ **已核实**（术语更精确） | `GUARANTEED_MINIMUM_STATIC_RULES = 30000`、`MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES`（"at least 5000"）、`MAX_NUMBER_OF_DYNAMIC_RULES = 30000`（Chrome 121 起）、`MAX_NUMBER_OF_SESSION_RULES = 5000`、`MAX_NUMBER_OF_REGEX_RULES = 1000` | 与 Q-D1（只拦一条 URL）无关，但可推翻"用 DNR 做规则引擎"的思路 |
| A6 | URL 为 `chrome-extension://` 的请求，DNR **一律不求值**（无论谁发起） | t14 §4.3-2；t15 §4.3 | ✅ **已核实**（`main` 与 stable 154 一致） | `ShouldEvaluateRequest()`：`// Prevent extensions from modifying any resources on the chrome-extension scheme.` → `if (request.url.SchemeIs(kExtensionScheme)) { return false; }`（[ruleset_manager.cc@main](https://raw.githubusercontent.com/chromium/chromium/main/extensions/browser/api/declarative_net_request/ruleset_manager.cc)，[154.0.8037.0](https://raw.githubusercontent.com/chromium/chromium/154.0.8037.0/extensions/browser/api/declarative_net_request/ruleset_manager.cc)） | 即使 `regexFilter` 写成 `^chrome-extension://` 也不会命中 |
| A7 | "DNR 跳过其它扩展发起的非 main_frame 请求——**128 无 / 130 有**（129/130 引入）" | t14 §4.3、C13、E27 | ❌ **已证伪** | 逐 tag 结果：126/127 **无**；**128.0.6613.84 有**（变量名拼作 `initator_precursor`，是本次 t14 漏检的直接原因）；129/130/132 有且**无** main_frame 例外；133 无例外 / **134 有例外**；154、main 与 134 一致 | 修正为：**128 起**跳过其它扩展的**全部**请求（含 main_frame）→ **134 起**放开 main_frame 导航。t14 的"当前行为"描述（跳过非主框架请求）仍然正确 |
| A8 | `initiatorDomains` 匹配的是"发起者域名"而非请求 URL | t14 §4.3 补充；t15 §4.3 | ✅ **已核实**（文档语义部分） | "This matches against the request initiator and not the request url."（[DNR 文档](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest)） | "无法用 initiatorDomains 表达 `chrome-extension://<id>`"仍是**推断**（官方无明文），但 A7 的求值层跳过已经独立成立 |

### 2.2 B 组 — `chrome.webRequest`

| # | 断言 | 出处 | 核实结果 | 证据（原文摘录 + URL） | 影响 |
|---|---|---|---|---|---|
| B1 | MV3 里 `webRequestBlocking` 只对策略安装扩展开放；其余 webRequest 功能不变 | t14 §2.1、C2；t15 §2.1、C2 | ✅ **已核实** | "As of Manifest V3, the `"webRequestBlocking"` permission is no longer available for most extensions."；"this is only available to policy installed extensions."；"Aside from `"webRequestBlocking"`, the webRequest API is unchanged and available for normal use."（[webRequest](https://developer.chrome.com/docs/extensions/reference/api/webRequest)） | 主路径不依赖 webRequest，无阻塞 |
| B2 | MV2 时间线：Chrome 138 是最后一个支持版本；139 起失效；2026-08-31 从 CWS 移除全部 MV2 | t14 §2.1、C3；t15 §2.1、C1 | ✅ **已核实**（逐字） | "**Aug 31st 2026**: All remaining Manifest V2 extensions removed from the Chrome Web Store."；"Chrome 138 is the final version of Chrome to support Manifest V2 extensions"；"Manifest V2 extensions will cease to function for any user upgrading to Chrome 139"（[MV2 timeline](https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline)） | MV2 方案（Resource Override 式 `data:` 重定向）不可能作为产品路径 |
| B3 | blocking `webRequest` 的 `redirectUrl` 允许 `data:`，可近似"凭空造响应体" | t14 §2.1；t15 §2.1 | ✅ **已核实** | "Redirections to non-HTTP schemes such as `data:` are allowed."（webRequest 文档）；实证：Resource Override `redirectUrl: "data:" + mimeAndFile.mime + ";charset=UTF-8;base64," + …`（[requestHandling.js#L26](https://raw.githubusercontent.com/kylepaulsen/ResourceOverride/master/src/background/requestHandling.js)） | "MV2 曾有第三条路"属实，但平台已死 |
| B4 | `chrome-extension://other_extension_id` 的请求被列为 hidden requests | t14 §4.2；t15 §4.2 | ✅ **已核实** | "These include `chrome-extension://other_extension_id` where `other_extension_id` is not the ID of the extension to handle the request"（webRequest 文档） | **注意**：这一条约束的是**请求的 URL**，不是**发起者**；t14 明确写了这一点，t15 未作区分（见 §4.3） |
| B5 | Chrome 72 起，拦截请求需要同时拥有"请求 URL"与"发起者"的 host 权限 | t14 §2.1、§4.2；t15 §4.2 | ✅ **已核实**（逐字） | "Starting from Chrome 72, an extension will be able to intercept a request only if it has host permissions to both the requested URL and the request initiator."（webRequest 文档） | 这是判断"能否接住别的扩展请求"的第二道闸门 |
| B6 | `ListenerMatchesRequest()` 按渲染进程过滤来自其它扩展的请求 | t14 §4.2、§4.2-4；t15 §4.2、C5 | ✅ **已核实**（代码与函数名都准确） | `// Filter requests from other extensions / apps. This does not work for content scripts, or extension pages in non-extension processes.` → `if (is_request_from_extension && listener.id.render_process_id != request.global_id.child_id) { return false; }`（[main](https://raw.githubusercontent.com/chromium/chromium/main/extensions/browser/api/web_request/extension_web_request_event_router.cc)、[154.0.8037.0](https://raw.githubusercontent.com/chromium/chromium/154.0.8037.0/extensions/browser/api/web_request/extension_web_request_event_router.cc) 第 3081-3083 行） | 结论成立 |
| B7 | "该过滤 **Chrome 117 引入**：116 无 / 117 有" | t14 §2.2、§4.2、C12、E25 | ❌ **已证伪** | 同一段注释与过滤在 51.0.2704.79 / 60 / 65 / 70 / 92 / 100 / 104 / 110 / **116** 的 `extensions/browser/api/web_request/web_request_api.cc` 里都存在；**117 只是把该文件拆出了 `extension_web_request_event_router.cc`**（116 的目录列表里没有新文件） | 见 §3.1；结论方向不变，但"117 起才这样"是错的 |
| B8 | "看到：不能。（**MV2 也一样，与版本无关**）" | t15 §4.2 | ✅ **已核实（结论）** / ⚠️ **表述不精确** | 过滤在 MV2 时代（如 70 / 92）确实存在；但它并非"与版本无关"，只是**远早于 MV3**（本次上溯到 51，未再往前二分） | 建议改为"至少自 Chrome 51 起即如此（早于 MV3 多年）" |
| B9 | 该过滤有例外：content script 与非扩展进程里的扩展页不受影响 | t14 §4.2-5；t15 §4.2 | ✅ **已核实（注释原文）** / 例外分支的 `initiator` 取值 ⚠️ **无法核实** | 注释原文见 B6；t15 自己也把"其它扩展 content script 的 initiator 取值"列为 U5 | 若未来要在网络层"看见"第三方扩展的 content script 请求，必须先实证 initiator 取值 |
| B10 | MV3 的 webRequest 只能看，不能 cancel / redirect / 改头 | t14 §2.2；t15 §2.2、C2 | ✅ **已核实** | 官方 MV2→DNR 迁移文档把 block/redirect/modifyHeaders 三类改写为 DNR；`webRequestBlocking` 权限不存在（[blocking-web-requests](https://developer.chrome.com/docs/extensions/develop/migrate/blocking-web-requests)） | 主路径不依赖它 |
| B11 | 敏感头需 `extraHeaders`；内存缓存命中的请求不可见；WS 只拦握手、不拦消息、不支持 WS 重定向 | t14 §2.1、C11；t15 §2.2、C15 | ✅ **已核实**（逐字） | "Requests that are answered from the in-memory cache are invisible to the web request API."；"the API does **not intercept**: Individual messages sent over an established WebSocket connection. … **Redirects are not supported for WebSocket requests.**"（webRequest 文档） | 盲区清单可直接引用 |
| B12 | 多扩展同时想改同一请求时"最近安装的扩展获胜" | t14 §7 B12、§2.1；t15 §7 F8 | ✅ **已核实** | "Only one extension can redirect a request or modify a header at a time. If more than one extension attempts to modify the request, the most recently installed extension wins"（webRequest 文档 Conflict resolution） | Q-D1 只拦一条 URL 时影响面小 |
| B13 | MV3 webRequest 事件包括 `onSendRequest` | t14 §2.2 | ❌ **已证伪（笔误）** | 官方事件名为 `onSendHeaders`；`onSendRequest` 在文档中 **0 命中**（webRequest 文档 Events 节） | 引用 API 名时需逐字核（t15 用对了） |
| B14 | 扩展 API 里不存在 socket / 监听类 API（R8 的旁证） | t14 C1、§5 C1 | ✅ **已核实（旁证级）** | 官方扩展 API 索引页全文检索 `sockets` **0 命中**（[API 索引](https://developer.chrome.com/docs/extensions/reference/api)）；`chrome.sockets.*` 属已废弃的 Chrome Apps | 支持"扩展不能监听端口"，但严格证明仍需 API 级排除（t14 自己也标了未验证） |

### 2.3 C 组 — `chrome.debugger` + CDP `Fetch`

| # | 断言 | 出处 | 核实结果 | 证据（原文摘录 + URL） | 影响 |
|---|---|---|---|---|---|
| C1 | `Fetch.fulfillRequest` 带 `body`，可返回自定义响应体 | t14 §2.4；t15 §2.4 | ✅ **已核实** | 协议定义：`body` (string, optional) — "A response body. If absent, original response body will be used if the request is intercepted at the response stage and empty body will be used if the request is intercepted at the request stage. (Encoded as a base64 string when passed over JSON)"（[browser_protocol.json](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/browser_protocol.json)）；实证：Tamper Dev 商店版 MV3 产物含 `Fetch.fulfillRequest`（CRX 解包） | 唯一"网络层凭空回答"的正规通道，成立 |
| C2 | `Fetch.enable(patterns)`：不设 patterns 则影响所有请求；被暂停的请求必须由 continue/fail/fulfill 之一回复 | t14 §2.4；t15 §2.4 | ✅ **已核实** | "A request will be paused until client calls one of failRequest, fulfillRequest or continueRequest/continueWithAuth."；patterns — "If not set, all requests will be affected."（同 JSON / [Fetch 域](https://chromedevtools.github.io/devtools-protocol/tot/Fetch/)） | 语义确认 |
| C3 | `Fetch.continueRequest` 可改 URL（对页面不可观测）/method/postData/headers | t14 §2.4 | ✅ **已核实** | "If set, the request url will be modified in a way that's not observable by page."（同 JSON） | 与产品无关（我们不做改请求），但证据准确 |
| C4 | `Fetch` 在 `chrome.debugger` 的可用 CDP 域白名单内 | t14 §2.4；t15 §2.4、C10 | ✅ **已核实** | "Restricted domains … The available domains are: Accessibility, Audits, CacheStorage, Console, CSS, Database, Debugger, DOM, DOMDebugger, DOMSnapshot, Emulation, **Fetch**, IO, Input, Inspector, Log, Network, Overlay, Page, Performance, Runtime, Storage, Target, Tracing, WebAudio, and WebAuthn."（[debugger](https://developer.chrome.com/docs/extensions/reference/api/debugger)） | 通道成立 |
| C5 | 普通安装扩展 attach 必弹 "started debugging this browser" 信息条，仅 `--silent-debugger-extension-api` / 策略安装可免；信息条不自动消失 | t14 §2.4-1；t15 §2.4-1、C9 | ✅ **已核实**（逐字） | 源码：`const bool suppress_warning = …HasSwitch(::switches::kSilentDebuggerExtensionAPI) \|\| Manifest::IsPolicyLocation(extension_->location()); if (!suppress_warning) { …CreateWarningInfobar(); }`；文案 `IDS_DEV_TOOLS_INFOBAR_LABEL` = `"<ph name="CLIENT_NAME">$1<ex>Extension Foo</ex></ph>" started debugging this browser`，描述注明 "The label does not disappear until the user dismisses it, even if the debugger is detached"（[debugger_api.cc](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/extensions/api/debugger/debugger_api.cc)、[generated_resources.grd](https://raw.githubusercontent.com/chromium/chromium/main/chrome/app/generated_resources.grd)） | 作默认路径不可接受；作"高保真可选模式"可 |
| C6 | 用户打开 DevTools 会让调试会话 detach | t14 §2.4-2；t15 §2.4-2、C9 | ✅ **已核实**（逐字） | "Fired when browser terminates debugging session for the tab. This happens when either the tab is being closed or **Chrome DevTools is being invoked for the attached tab.**"（debugger 文档 `onDetach`） | UX 上不可控 |
| C7 | 同一目标同时只能有一个调试器 | t15 §2.4-3、C9 | ✅ **已核实**（逐字） | `kAlreadyAttachedError[] = "Another debugger is already attached to the * with id: *."`（[debugger_api.cc](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/extensions/api/debugger/debugger_api.cc) 第 115-116 行） | 与其它调试类扩展互斥 |
| C8 | 企业策略以"全有或全无"阻止 attach；`--disable-features=ExtensionDebuggerStrictPolicyRestrictions` 可临时回退，该开关 Chrome 160 移除 | t14 §2.4-3、C7；t15 §2.4-4 | ✅ **已核实**（逐字） | "If an extension needs chrome.debugger, it must not have blocked hosts configured…"；"administrators can temporarily revert to the pre-Chrome 155 behavior by launching Chrome with the `--disable-features=ExtensionDebuggerStrictPolicyRestrictions`… the flag will be removed in **Chrome 160**."（[官方博客，last updated 2026-09-16](https://developer.chrome.com/blog/debugger-enterprise-policy-restrictions)）；源码里同样有 `kExtensionDebuggerStrictPolicyRestrictions` 开关 | 企业环境不可依赖 |
| C9 | "Chrome **stable ≈ 155**，官方博客称 155 Stable 于 2026-10-06 开始 rollout" | t14 §0 元信息 | ❌ **已证伪** | `chromiumdash` Stable=**154.0.8037.98**（platform Windows）；官方博客："Stable Channel Update for Desktop — **Thursday, October 1, 2026** … updated to **154.0.8037.97/.98**"；155 在 Beta（2026-10-05 ChromeOS Beta 155.0.8059.31）（[chromiumdash](https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Windows&num=3)、[chromereleases](https://chromereleases.googleblog.com/)） | 基线改为 154；企业策略那条"Chrome 155 起"保留原样（属"将在 155 生效"） |
| C10 | 浏览器级 target（`targetId:"browser"`）只对 Perfetto 白名单扩展开放 | t15 §4.4-3、C11 | ✅ **已核实** | `constexpr char kBrowserTargetId[] = "browser";`；`bool ExtensionIsTrusted(...) { if (extension.id() != extension_misc::kPerfettoUIExtensionId) return false; … }`（debugger_api.cc 第 281-290、1022-1023 行） | 不能靠"附加 browser target"绕过 |
| C11 | `Debuggee.extensionId` 附加扩展后台页需要 `--silent-debugger-extension-api` | t14 §4.4；t15 §4.4-2、C8 | ✅ **已核实**（逐字） | "Attaching to an extension background page is only possible when the `--silent-debugger-extension-api` command-line switch is used."（debugger 文档 `Debuggee.extensionId`） | 与"别人家扩展"相关的门槛之一 |
| C12 | `chrome.debugger` 不需要 host 权限 | t14 §2.4-4 | ✅ **已核实**（逐字） | "In some special cases, host permissions are not required. These include: … Interacting with the browser using the `chrome.debugger` API."（[declare-permissions](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions)） | 安装警告≠权限门槛，需注意用户观感 |
| C13 | 不能 attach 到别的扩展的页面（除非 `--extensions-on-extension-urls` / `--extensions-on-chrome-urls`） | t14 §4.4；t15 §4.4-1、C8 | ✅ **已核实** | `if (url_for_restriction_check.SchemeIs(extensions::kExtensionScheme) && url_for_restriction_check.host() != extension.id() && !allow_on_extension_urls) { *error = manifest_errors::kCannotAccessExtensionUrl; return false; }`（debugger_api.cc `ExtensionMayAttachToURL`） | 第三问的第四条闸门成立 |
| C14 | WebUI（`chrome://`）帧 attach 被拒（`kCannotAccessChromeUrl`） | t14 §2.4、§4.4 | ✅ **已核实** | debugger_api.cc 第 329 行 `*error = manifest_errors::kCannotAccessChromeUrl;`；另有 `extension.permissions_data()->IsRestrictedUrl(...)` | 系统页盲区成立 |

### 2.4 D 组 — content script / world / 规范

| # | 断言 | 出处 | 核实结果 | 证据（原文摘录 + URL） | 影响 |
|---|---|---|---|---|---|
| D1 | content script 的合法 scheme 不含 `chrome-extension`（`kValidUserScriptSchemes`） | t14 §4.1；t15 §4.1、C7 | ✅ **已核实** | `kValidUserScriptSchemes = URLPattern::SCHEME_CHROMEUI \| URLPattern::SCHEME_HTTP \| URLPattern::SCHEME_HTTPS \| URLPattern::SCHEME_FILE \| URLPattern::SCHEME_FTP \| URLPattern::SCHEME_UUID_IN_PACKAGE`（[user_script.cc@main](https://raw.githubusercontent.com/chromium/chromium/main/extensions/common/user_script.cc)） | 自家的、别人家的扩展页都不能靠 content script 注入 |
| D2 | 官方 match patterns 的 scheme 只有 `http` / `https` / `*`（仅 http、https）/ `file` | t14 §4.1；t15 §4.1 | ✅ **已核实**（逐字） | "scheme: Must be one of the following … `http` `https` A wildcard `*`, which matches only http or https `file`"（[match-patterns](https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns)） | 同上 |
| D3 | "MDN 的 match pattern 文档把 `(chrome-)extension` 列为合法 scheme" | t14 §4.1 | ❌ **已证伪** | 当前 MDN 页面检索 `mo-extension`/`chrome-extension` **0 命中**；`<all_urls>` 列出 "http", "https", "ws", "wss", "ftp", "data", "file"；仅有 "Note: Some browsers don't support certain schemes."（[MDN Match patterns](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Match_patterns)） | 论据删除；结论由 D1+D2 支撑 |
| D4 | 隔离世界私有；MAIN world 对页面与其它扩展可见；MAIN world 注入受页面 CSP；`document_start` 语义；同阶段静态 content script 最先注入 | t14 §2.5、C9·C10；t15 §2.5、C12·C13 | ✅ **已核实**（逐字） | "An isolated world is a private execution environment that isn't accessible to the page or other extensions."；"When a content script is injected into the main world, **the CSP of the page applies**."；"Scripts running in the main world are accessible to host pages and other extensions"；"`document_start` Script is injected after any files from css, but before any other DOM is constructed or any other script is run."；"content scripts declared statically in the manifest are the first to be injected, before content scripts registered in any other way"（[content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts)、[userScripts](https://developer.chrome.com/docs/extensions/reference/api/userScripts)、[extensionTypes](https://developer.chrome.com/docs/extensions/reference/api/extensionTypes)） | 主路径成立，盲区清单可直接引用 |
| D5 | 纯 JS 对象无法通过 WebIDL brand check，所以伪造 XHR 必须持有真实例 | t15 §3.8(b)、C14 | ✅ **已核实**（规范原文） | "Let validThis be true if jsValue implements target, or false otherwise. If validThis is false and attribute was not specified with the [LegacyLenientThis] extended attribute, then throw a TypeError."（[WebIDL](https://webidl.spec.whatwg.org/)，attribute setter 步骤） | 库选型结论（真 XHR 做底）有规范依据 |
| D6 | 合成 `Response` 的固有破绽：`url === ""`、`redirected === false`、`type === "default"` | t15 §3.8(a)、D7 | ✅ **已核实**（规范原文） | "The url getter steps are to return the empty string if this's response's URL is null…"；"The redirected getter steps are to return true if this's response's URL list's size is greater than 1; otherwise false."；"The type getter steps are to return this's response's type."（[Fetch 规范](https://fetch.spec.whatwg.org/)） | "局部遮蔽只读字段"是必要动作 |

### 2.5 E 组 — 五个 JS 劫持库

| # | 断言 | 出处 | 核实结果 | 证据（原文摘录 + URL） | 影响 |
|---|---|---|---|---|---|
| E1 | 五个库真实存在，版本为 ajax-hook 3.0.3 / xhook 1.6.2 / fetch-intercept 2.4.0 / @mswjs/interceptors 0.45.7 / nise 6.1.5 | t14 §3.1；t15 §3.2–§3.6 | ✅ **已核实** | npm registry `/latest` 逐个解析并下载 tarball：版本号与断言完全一致 | 引用版本可放心 |
| E2 | ajax-hook：替换全局构造器 + 在实例上包装方法（不改原型）；原生实例存于 `__origin_xhr`；`prototype` 复用但改写 `prototype.constructor`；源码注释解释为何不 hook 原型；不碰 fetch；同步 XHR 走同步分支 | t14 §3.1、§3.2；t15 §3.2 | ✅ **已核实**（逐字） | `var OriginXhr = '__origin_xhr';`；`// We shouldn't hookAjax XMLHttpRequest.prototype because we can't guarantee that all attributes are on the prototype。`；`this[OriginXhr] = xhr;`；`HookXMLHttpRequest.prototype = originXhr.prototype; HookXMLHttpRequest.prototype.constructor = HookXMLHttpRequest; win.XMLHttpRequest = HookXMLHttpRequest;`（[xhr-hook.js](https://github.com/wendux/ajax-hook/blob/master/src/xhr-hook.js)）；`config.async === false ? req() : setTimeout(req)`（xhr-proxy.js）；`src/` 内无 fetch 相关代码 | 库事实准确 |
| E3 | xhook：替换 `XMLHttpRequest` 与 `fetch` 两个全局；实例是纯 JS facade；同步请求立即 emitFinal；README 有"必须先加载"警告与 "Simulate responses"；识别 WorkerGlobalScope | t14 §3.1；t15 §3.3 | ✅ **已核实**（逐字） | `// openned facade xhr (not real xhr)`；`if (request.async === false) { emitFinal(); } else { setTimeout(emitFinal, 0); }`；`windowRef.XMLHttpRequest = Xhook;`；`windowRef.fetch = Xhook;`；`//skip async hook on sync requests`；README：`It's important to include XHook first as other libraries may store a reference to XMLHttpRequest before XHook can patch it`、`Simulate responses`（npm `xhook@1.6.2` `dist/xhook.js`、`README.md`） | 库事实准确（README 措辞是"Simulate responses"，非"transparently"，差异无实质影响） |
| E4 | fetch-intercept：`env.fetch = (fetch => …)(env.fetch)` 直接替换；README 要求首次使用前加载 | t14 §3.1；t15 §3.4 | ✅ **已核实**（逐字） | `env.fetch = function (fetch) { … }(env.fetch)`（npm `fetch-intercept@2.4.0` `lib/browser.js`）；README：`fetch-intercept monkey patches the global fetch method…`；`You need to require fetch-intercept before you use fetch the first time.` | 库事实准确 |
| E5 | @mswjs/interceptors：XHR 用 `new Proxy(globalThis.XMLHttpRequest, {construct})` + `Reflect.construct` 真实例 + 复制原型描述符；同步 XHR 明确不支持并放行（含 warn 原文）；`patchesRegistry` 的 `defineProperty` **无 writable**；`EventPolyfill.isTrusted = true`；用 `Symbol.for('fetch-interceptor')` / `Symbol.for('xhr-interceptor')` 标记；浏览器构建存在（`exports["."].browser`） | t14 §3.1、§3.3；t15 §3.5、D4 | ✅ **已核实**（逐字） | `new Proxy(globalThis.XMLHttpRequest, { construct(target, args, newTarget) { const originalRequest = Reflect.construct(...)` 与 `prototypeDescriptors` 复制；`console.warn(\`Failed to intercept an XMLHttpRequest (${this.method} ${this.url}): synchronous requests are not supported. This request will be performed as-is.\`)` → `return invoke()`；`Object.defineProperty(owner, key, { value, enumerable: true, configurable: true })`；`public isTrusted: boolean = true`；`static symbol = Symbol.for('fetch-interceptor')`；`package.json`：`".": { "browser": "./lib/browser/index.js", … }`（npm `@mswjs/interceptors@0.45.7` 解包源码） | 库事实准确；"漏 writable"这一检测面成立 |
| E6 | nise：`useFakeXMLHttpRequest()` 直接替换全局 `XMLHttpRequest` 为纯 JS 实现；不覆盖 fetch | t14 §3.1、§3.2；t15 §3.6 | ✅ **已核实**（逐字） | `globalScope.XMLHttpRequest = FakeXMLHttpRequest;`（`lib/fake-xhr/index.js` 第 1157 行）；`/lib` 下 `fetch` 仅出现在注释/测试引用，无 fetch 替身（npm `nise@6.1.5`） | 库事实准确 |
| E7 | "真 `new ProgressEvent()` 的 `isTrusted` 为 false / `isTrusted` 不可伪造" | t14 §3.3-5、D5；t15 D5 | ⚠️ **无法核实** | 规范只说 UA 派发的事件 `isTrusted=true`（本次未取到"脚本构造的 ProgressEvent 的 isTrusted 必为 false"的规范原文），也**无法在本环境实测浏览器**；两份研究自己也标注为推断 | 保持"推断"标记；不要写进能力清单 |

### 2.6 F 组 — 现成扩展与用户脚本管理器

| # | 断言 | 出处 | 核实结果 | 证据（原文摘录 + URL） | 影响 |
|---|---|---|---|---|---|
| F1 | Requestly v26.9.29（MV3）：权限含 DNR + webRequest + scripting + proxy + tabs + webNavigation；静态 ruleset delay/header；页面脚本 `page-scripts/ajaxRequestInterceptor.ps.js` 包装 XHR 与 fetch 并 `new Response(...)`；SW 里 7 处 `world:"MAIN"` + `registerContentScripts`/`executeScript`/`updateDynamicRules`/`updateSessionRules` | t14 §2.5、§2.6、E32 | ✅ **已核实**（本次自行下载 CRX 解包） | manifest：`"permissions": ["browsingData","contextMenus","declarativeNetRequest","proxy","scripting","sidePanel","storage","tabs","unlimitedStorage","webNavigation","webRequest"]`，`"version": "26.9.29"`；页面脚本含 `XMLHttpRequest.prototype.open=function(t,r,s=!0){…this.rqProxyXhr…}`、`XMLHttpRequest.prototype=r.prototype`、`const t=fetch;fetch=async(...r)=>{…}`、`new Response(m?null:new Blob([f]),{status:q,statusText:…,headers:d})`；SW 中 `world:"MAIN"` 出现 **7** 次 | 本产品最接近的先例：**"页面 JS 层 hook + 网络层 DNR"双轨**成立 |
| F2 | ModHeader V3 `2026.8.8.18`（MV3）：权限**仅** clipboardRead/clipboardWrite/declarativeNetRequest/storage + `<all_urls>`；无 webRequest/debugger/content scripts；后台用 `modifyHeaders` + `updateDynamicRules`/`updateSessionRules` | t14 §2.3、§2.6、E34；t15 U1（未验证） | ✅ **已核实**（本次 CRX 解包） | `"permissions": ["clipboardRead","clipboardWrite","declarativeNetRequest","storage"]`，`"host_permissions": ["<all_urls>"]`，`"manifest_version": 3`，`"version": "2026.8.8.18"`；`background.js` 中 `modifyHeaders` / `requestHeaders` / `responseHeaders` / `updateDynamicRules` / `updateSessionRules` 各命中 | t14 描述准确；**t15 的"完全未验证"可撤销** |
| F3 | Tamper Dev 商店版 = MV3、权限 debugger+activeTab+scripting、产物用 CDP Fetch；仓库 `v2` manifest 是 MV2 | t14 §2.4、§2.6、E33；t15 §2.6.3、U16 | ✅ **已核实**（CRX + GitHub raw） | CRX manifest：`"manifest_version": 3`、`"permissions": ["debugger","activeTab","scripting"]`，后台产物出现 `Fetch.enable` / `Fetch.continueRequest` / `Fetch.fulfillRequest`；仓库 `v2/manifest_base.json`：`"manifest_version": 2`、`"permissions": ["debugger","activeTab"]` | 双方描述都准确（t14 说商店 MV3、t15 说仓库 MV2，两者是不同代码线） |
| F4 | Resource Override（MV2）：webRequest + webRequestBlocking + `<all_urls>` + tabs；Chrome 用 `data:` 重定向造 body；Firefox 用 `filterResponseData` | t14 §2.6、E35；t15 §2.6.4 | ✅ **已核实**（逐字） | `manifest.json`：`"manifest_version": 2`、`"permissions": ["webRequest","webRequestBlocking","<all_urls>","tabs"]`；`requestHandling.js`：`browser.webRequest.filterResponseData(requestId).onstart = e => { … e.target.disconnect(); }` 与 `redirectUrl: "data:" + mimeAndFile.mime + ";charset=UTF-8;base64," + …` | 两份研究的"唯一历史造 body 途径"实例成立 |
| F5 | Redirector（MV2）：webRequest + webRequestBlocking + webNavigation + tabs；后台 `return { redirectUrl: result.redirectTo }` | t14 §2.6、E36；t15 §2.6.5 | ✅ **已核实** | `manifest.json`：`"manifest_version": 2`、`"permissions": ["webRequest","webRequestBlocking","webNavigation","storage","tabs","http://*/*","https://*/*","notifications"]`；`js/background.js` 第 107 行 `return { redirectUrl: result.redirectTo };` | 准确 |
| F6 | Tampermonkey `@sandbox raw` = MAIN_WORLD 且是默认，MAIN 注入被 CSP 拦时按序回退；Violentmonkey `@inject-into` = page/content/auto，content 模式"cannot access JavaScript objects of the web page"，auto 被 CSP 拦则退化 | t14 §2.6、E23；t15 §3.7、§3.11 | ✅ **已核实**（逐字） | TM："`MAIN_WORLD` - the page … `raw` … **At the moment this mode is the default if @sandbox is omitted.** If injection into the MAIN_WORLD is not possible (e.g. because of a CSP) the userscript will be injected into other (enabled) sandboxes according to the order of this list."；VM："content … can access and modify the page's DOM, but **cannot access JavaScript objects of the web page**"；"auto default Try to inject into context of the web page. If blocked by CSP rules, inject as a content script."（[TM @sandbox](https://www.tampermonkey.net/documentation.php?locale=en&q=sandbox)、[VM metadata](https://violentmonkey.github.io/api/metadata-block/)） | 准确；"降级≠R5 的换装载方式"这一提醒有价值 |
| F7 | Violentmonkey 仓库 manifest 是 MV2（tag 2.49.4） | t14 §2.6、E44；t15 §2.6.6 | ✅ **已核实**（master 分支） | `src/manifest.yml` 首行区：`manifest_version: 2`（jsdelivr `violentmonkey/violentmonkey@master`） | 准确（t14 引 tag、我核 master，二者一致） |
| F8 | Requestly 开源仓默认分支已不含 `browser-extension` 目录 | t15 §10.5、U2 | ⚠️ **无法核实** | GitHub REST API 返回 403 rate limit（`x-ratelimit-remaining: 0` 类错误），本环境无 token；raw 路径探测不足以证明"目录不存在" | 保留未验证；不影响 F1（CRX 已直接核实） |

### 2.7 G 组 — 其它平台事实

| # | 断言 | 出处 | 核实结果 | 证据（原文摘录 + URL） | 影响 |
|---|---|---|---|---|---|
| G1 | Firefox MV3 保留 blocking webRequest；`filterResponseData` 能改响应体 | t14 §2.1、E14·E20；t15 §2.1、§2.2、U10 | ✅ **已核实**（逐字） | "**Mozilla will maintain support for blocking WebRequest in MV3.** To maximize compatibility with other browsers, we will also ship support for declarativeNetRequest."（[Mozilla 博客](https://blog.mozilla.org/addons/2022/05/18/manifest-v3-in-firefox-recap-next-steps/)）；"The filter has **full control over the response body**"（[MDN StreamFilter](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest/StreamFilter)） | Firefox 是唯一"文档级支持改响应体"的平台；但需 `webRequestBlocking` |
| G2 | host permission 的合法 scheme 不含 `chrome-extension` | t14 §4.2-3；t15 §4.2、C6 | ✅ **已核实**（逐字） | `Extension::kValidHostPermissionSchemes = URLPattern::SCHEME_CHROMEUI \| HTTP \| HTTPS \| FILE \| FTP \| WS \| WSS \| UUID_IN_PACKAGE`（[extension.cc@main](https://raw.githubusercontent.com/chromium/chromium/main/extensions/common/extension.cc)） | 构成"接不住别的扩展请求"的第二道闸门 |
| G3 | `--extensions-on-extension-urls`（含向后兼容的 `--extensions-on-chrome-urls`）打开扩展 URL 访问 | t14 §4.4、E29；t15 §4.4、C8 | ✅ **已核实** | `switches.cc`：`AreExtensionsOnExtensionURLsAllowed()` 先查 `kExtensionsOnExtensionURLs`（注释 "Extensions are allowed to run on other extensions with the appropriate commandline switch."），再向后兼容 `--extensions-on-chrome-urls`（[switches.cc@main](https://raw.githubusercontent.com/chromium/chromium/main/extensions/common/switches.cc)） | 命令行开关不是产品可依赖的部署方式 |
| G4 | `chrome.proxy` + PAC 不能合成响应 | t15 §4.5、U9（自标推断） | ⚠️ **无法核实** | 本次未逐字核 `chrome.proxy` 文档；从 API 定位（PAC 只返回代理地址/DIRECT）看结论合理，但缺一手原文 | 保持推断 |
| G5 | debugger 的 flat session / `DebuggerSession` 自 Chrome 125 起 | t14 §2.4 | ✅ **已核实** | debugger 文档：`DebuggerSession Chrome 125+`，"One of tabId, extensionId or targetId must be specified. Additionally, an optional sessionId can be provided."；"Attach to related targets" 节说明 `Target.setAutoAttach` | 与 attach 范围相关 |

---

## 3 被证伪的断言及其后果

### 3.1 X1：`webRequest` 的"其它扩展过滤"被归为 **Chrome 117 引入**（t14）

**断言原文**（t14 §2.2、§4.2、C12、E25）：

> "**版本核对**（本次逐 tag 抓取）：`116.0.5845.0` **无**该过滤；`117.0.5938.0` 及之后（120/128/138）**有** ⇒ **Chrome 117 起生效**。"

**本次实测**（`raw.githubusercontent.com/chromium/chromium/<tag>/extensions/browser/api/web_request/…`）：

| tag | 文件 | 过滤命中 |
|---|---|---|
| 51.0.2704.79（2016 年分支） | `web_request_api.cc` | ✅ 1 |
| 60.0.3112.90 | `web_request_api.cc` | ✅ 1 |
| 65.0.3325.146 | `web_request_api.cc` | ✅ 1 |
| 70.0.3538.77 / 92 / 100 / 104 / 110 | `web_request_api.cc` | ✅ 各 1 |
| **116.0.5845.0** | `web_request_api.cc` | ✅ 1（第 2310-2315 行） |
| **117.0.5938.0** | `extension_web_request_event_router.cc` | ✅ 1（第 2029-2034 行） |
| 154.0.8037.0 / main | `extension_web_request_event_router.cc` | ✅ 1 |

并且：**116 的目录里根本没有 `extension_web_request_event_router.cc` 这个文件**（googlesource 目录列表 + raw 404；117 才拆分出该文件）。⇒ t14 的"116 无 / 117 有"来自**文件路径变更**，与功能时间线无关。

**后果**：
1. "117 之前会不会能拦到别的扩展"这一推论**反向**：真实情况是至少自 **Chrome 51（2016）** 起就不能；这是一个**十年未变的既定行为**，不要指望未来版本放开，也不要用"117 之前可行"解释任何现象。
2. 结论（接不住第三方扩展）**不变**，t14 的 C12 只需把"Chrome 117+"改为"至少自 Chrome 51 起"。
3. 证据链层面的提醒见 §4.1。

### 3.2 X2：DNR 的"其它扩展过滤"被归为 **129/130 引入、128 无**（t14）

**断言原文**（t14 §4.3、C13）：

> "**版本核对**（本次逐 tag 抓取 `ruleset_manager.cc`）：`initiator_precursor.scheme() == kExtensionScheme` 这一条在 `128.0.6613.84` **无**，在 `130.0.6723.1`、`132`…**有** ⇒ **Chrome 129/130 前后引入**"

**本次实测**：

| tag | 其它扩展 initiator 过滤 | "非 main_frame" 例外 |
|---|---|---|
| 126.0.6478.0 / 127.0.6533.0 | ❌ 无 | — |
| **128.0.6613.84** | ✅ **有**（`auto initator_precursor`，**少一个 i**） | ❌ 无（对所有资源类型生效） |
| 129.0.6668.0 / 129.0.6668.60 / 130.0.6723.1 / 132.0.6834.0 / **133.0.6943.53** | ✅ 有 | ❌ 无 |
| **134.0.6998.0** / 135 / 136 / 137 / 145 / 150 / 154.0.8037.0 / main | ✅ 有 | ✅ 有 |

128 的实际代码（原文）：

```cpp
  // Extensions should not generally have access to requests initiated by other
  // extensions, though the --extensions-on-chrome-urls switch overrides that
  // restriction.
  if (!base::CommandLine::ForCurrentProcess()->HasSwitch(
          switches::kExtensionsOnChromeURLs) &&
      request.initiator) {
    // Checking the precursor is necessary here since requests initiated by
    // manifest sandbox pages have an opaque initiator origin, but still
    // originate from an extension.
    auto initator_precursor =                      // ← t14 grep 的拼写是 initiator_precursor
        request.initiator->GetTupleOrPrecursorTupleIfOpaque();
    if (initator_precursor.scheme() == kExtensionScheme &&
        initator_precursor.host() != ruleset.extension_id) {
      return false;
    }
  }
```

**后果**：
1. 版本叙事必须改写为：**Chrome 128 起** DNR 跳过其它扩展发起的**全部**请求（含 main_frame 导航）→ **Chrome 134 起**才放开 main_frame 导航例外。t14 恰好把顺序说反（把"已经存在"读成"没有"，把"例外是后来加的"读成"过滤是后来加的"）。
2. 对产品的含义**没有变化**：当前（154/main）行为就是 t14/t15 描述的"跳过其它扩展发起的非 main_frame 请求；`chrome-extension:` 目标 URL 一律不求值"。
3. 方法论教训见 §4.1（grep 拼写/注释文本）。

### 3.3 X3：基线版本写成 "Chrome stable ≈ 155"（t14）

- t14 §0："Chrome stable ≈ 155（官方博客称 Chrome 155 Stable 于 2026-10-06 开始 rollout）"。
- 实测：`chromiumdash` Stable 通道当前为 `154.0.8037.97/.98`；Chrome Releases 官方博客 2026-10-01 发布 "Stable Channel Update for Desktop … 154.0.8037.97/.98"；155 在 **Beta**（2026-10-05 ChromeOS Beta 155.0.8059.31），Dev 157 / Canary 157。
- **后果**：涉及"当前 stable 行为"的表述要以 **154** 为基线（本次已复核：154 tag 的 webRequest 过滤与 DNR 过滤与 main 行为一致，结论不受影响）。企业策略那条"Chrome 155 起严格化"是官方博客原文（"revert to the pre-Chrome 155 behavior"），保留，但它是"将在 155 生效"，不是"155 已是 stable"。

### 3.4 X4：MDN match pattern 的"extension scheme"论据（t14）

- t14 §4.1："**Firefox 的 match pattern 文档把 `(chrome-)extension` 列为合法 scheme**（MDN 链接），且明确提示 'Some browsers don't support certain schemes'。"
- 实测：当前 MDN 页面中 `chrome-extension` / `moz-extension` **0 命中**；原文只有 "<all_urls> The special value matches all URLs under any of the supported schemes: that is "http", "https", "ws", "wss", "ftp", "data", and "file"."，以及 "Note: Some browsers don't support certain schemes. Check the Browser compatibility table for details."（后半句引用是对的，前半句没有出处）。
- **后果**：删掉该论据（或改写为"MDN 未列出 extension scheme"）。t14 的最终结论（不能注入 `chrome-extension://`）由 D1+D2 两条证据独立支撑，**不需要修改**。

### 3.5 X5：事件名 `onSendRequest`（t14）

- 官方事件表里没有 `onSendRequest`；正确名 `onSendHeaders`（t15 用的是正确名）。属于笔误级错误，但会误导实现者。

---

## 4 两份研究共同犯的错

### 4.1 ★ 共同错误：把 **Chromium 的文件路径（文件名）** 当成 **功能的时间线**

这是本次复核发现的最重要、也是最值得写进团队方法的错误。

- **t14**：用 `extension_web_request_event_router.cc` 在 tag 上"存在/不存在"判定过滤的引入版本，得出"116 无 / 117 有 ⇒ Chrome 117 引入"（X1）。
- **t15**：在同一问题上只引用了同一个**新文件**（`refs/heads/main/.../extension_web_request_event_router.cc`），并表述为"与版本无关"，同样没有回到 116 及更早的 `web_request_api.cc`。
- **共同点**：两份研究**都**以"117 之后才存在的文件"作为该行为的唯一源码证据；**没有任何一方**去看 117 之前承载同一逻辑的 `web_request_api.cc`。
- **实测反驳**：同一段注释与判定在 **51 / 60 / 65 / 70 / 92 / 100 / 104 / 110 / 116** 的 `web_request_api.cc` 中都在；117 只是**文件拆分**（116 目录里没有新文件名）。
- **同源变体**（只在 t14 出现，但方法相同）：用**正确拼写**的标识符（`initiator_precursor`）去 grep 一个**拼错**的标识符（128 的 `initator_precursor`），得到"128 无"的假阴性（X2）。
- **建议的核对规程**（供后续"能力清单/详细设计"沿用）：
  1. 版本核对 grep **注释文本**与**行为性代码片段**（注释比标识符稳定，如 `// Filter requests from other extensions`、`// Prevent extensions from modifying any resources on the chrome-extension scheme`）；
  2. 标识符 grep 至少覆盖常见拼写变体（本次的 `initator_` / `initiator_`）；
  3. 结论必须钉到**当前 stable tag**（本次为 `154.0.8037.0`），而不是 `main`；
  4. 需要精确引入版本时，用 `git log -S<代码片段>` 或 googlesource 的 `+log` 接口二分，而不是采信"文件在某 tag 上不存在"。

### 4.2 共同问题：用 `main` 分支源码代表"当前 Chrome 行为"，没有钉到 stable tag

- 两份研究的关键源码 URL 都是 `refs/heads/main` / `main`（t14 E25–E31、t15 §10.2），而 main 对应的是 Chrome ~157（dev/canary），不是用户当前在跑的 154。
- 本次对关键两条（webRequest 过滤、DNR 过滤）在 `154.0.8037.0` 上做了同样的检查，**结论一致**（属于运气好，不是流程正确）：过滤与注释都在，DNR 也带 main_frame 例外。
- **共同风险**：`main` 里还有 t14/t15 都没提到的新逻辑（例如 `ShouldEvaluateRequest` 里的 `request.is_privileged` 特权内容豁免、WebView 相关开关），这些是否会改变"153/154 的实际行为"，两份研究都没有核对。

### 4.3 共同表述风险：把"请求 URL 是别的扩展"的隐藏条款用在"发起者是别的扩展"的论证里

- 官方 webRequest 文档里 "hidden requests … `chrome-extension://other_extension_id`" 讲的是**请求的 URL**；两份研究都在"其它扩展发起的请求"（第三问）里引用了它。
- **t14 已自我澄清**："注意：这一条说的是'请求的 URL 是别的扩展'，不是'发起者是别的扩展'"——处理正确。
- **t15** 把它列在 §4.2 的"权限关"里（"另外：`chrome-extension://other_extension_id` 这类 URL 本身就被列为 hidden requests"），紧跟"initiator 检查必然失败"的推理，未作区分。
- **结论不受影响**（t15 另有 `ListenerMatchesRequest` 源码与 host-permission scheme 两条独立证据），但**后续文档引用时必须保留 t14 的这句澄清**，否则容易被误读成"看不见发起者"。

### 4.4 一处"共同未覆盖"（不算错，但会影响下游）

两份研究都没有讨论：**CDP `Fetch` 伪造的响应是否仍受 CORS 检查**（以及 `Fetch.fulfillRequest` 对 Service Worker 生成的响应是否有感）。这对本项目是**选型级问题**：R9 的 JS API 层短路天然绕过 CORS（请求根本没发出网络），而 CDP 是在网络层凭空造一个响应——它是否会被渲染进程的 CORS/混合内容检查再次拦下，两份研究都没有验证（见 §6.3）。

---

## 5 无法核实的断言

| # | 断言 | 出处 | 卡在哪里 |
|---|---|---|---|
| U1 | DNR `redirect.url` 是否接受 `data:`（若能，也只是规则里写死的静态串） | t14 §9.1；t15 U3 | 官方文档只显式禁止 `javascript:`；本次未在官方源码里找到允许/拒绝 `data:` 的判定分支，也未做实测（无浏览器环境）。两份研究标"未验证"是**正确**的处理 |
| U2 | `chrome.scripting.executeScript` 能否注入**自己家**的 `chrome-extension://` 页面 | t14 §4.1、§9.2；t15 U15 | 本次下载 `scripting_api.cc` 未找到 extension-scheme 门禁（未命中 `kCannotAccessExtensionUrl` 等），但也没找到"明确允许"的路径；该 API 的权限判定分散在 `permissions_data.cc`/renderer 侧，本次未完成完整追踪。两份研究标"未验证"**正确** |
| U3 | 其它扩展的 **content script** 发出的请求，其 `details.initiator` 取值（决定 `REQUIRE_HOST_PERMISSION_FOR_URL_AND_INITIATOR` 是否放行） | t14 §9.6；t15 U5 | 源码注释确认"进程过滤"对这一类不生效，但 `initiator` 具体取值（页面 origin？扩展 origin？opaque？）无官方文档、本次也无实测手段。保持存疑 |
| U4 | Firefox 中"扩展注入到**别的**扩展页面"的实际行为 | t14 §9.5 | MDN 文本里没有 extension scheme（见 X4），Firefox 的实际注入行为无官方明文，本次未实测 |
| U5 | `isTrusted` 是否可被伪造 / 真 `new ProgressEvent()` 的 `isTrusted` 是否为 false | t14 §3.3、§9.7；t15 D5 | 缺规范原文与实测环境（见 E7）。**两份研究都标了推断，处理正确** |
| U6 | Requestly 开源仓默认分支是否已不含 `browser-extension` 目录 | t15 §10.5、U2 | GitHub API 403 rate limit；raw 路径探测不能证明"不存在" |
| U7 | `chrome.proxy` + PAC 不能合成响应 | t15 §4.5、U9 | 本次未逐字核 `chrome.proxy` 文档（t15 自标推断） |
| U8 | CDP `Fetch` 对 Service Worker 生成响应的可见性；`Fetch.fulfillRequest` 伪造响应的 CORS 语义 | 两份研究**均未提出**（本报告 §6.3 提出） | 无官方明文；需实测（无浏览器环境） |

> 另：t14 §9 与 t15 §9 自己列出的未验证项（性能数字、Safari DNR、`chrome.sockets.*` 现状、msw 浏览器支持定位等）本次**未逐条复核**（超出"关键断言"范围），不作为本报告的结论。

---

## 6 两份都没提到、但我认为关键的点

### 6.1 CRX 取证通道是**可用**的，不要因为一次失败就把结论降级为"未验证"

本次实测：`clients2.google.com/service/update2/crx?...&x=id%3D<id>%26uc` 在本环境对三个扩展全部 **HTTP 200 + `application/x-chrome-extension`**（ModHeader 795 KB / Requestly 1.34 MB / Tamper Dev 550 KB），解包后 manifest 与产物可直接读。t15 §10.5 把这条通道记为"TLS 层被拒"，从而导致 U1/U2 两条本可核实的断言长期悬挂。**建议**：把该命令与解包脚本记入团队的取证工具清单（本次命令：`curl -sSL -o <id>.crx` 后取 CRX 头之后的 ZIP 段解包）。

### 6.2 `chrome.webRequest` 的"其它扩展盲区"是**十年既定行为**（不是新变化）

过滤至少自 **Chromium 51（2016 年分支）** 存在（本次实测 51/60/65/70/92/100/104/110/116）。含义：
- 不要把它当成"MV3 收紧"的一部分来解释；MV2 时代它同样存在。
- 不要指望浏览器在可预见未来放开——这与"扩展之间互相隔离"的安全模型一致。
- 对产品的正面含义：**"接不住第三方扩展"不是我们的实现缺陷，而是平台既定边界**，可以在盲区清单里明确写死。

### 6.3 CDP 伪造响应的 **CORS/混合内容**语义（选型级未验证项）

- R9 之所以选 JS API 层，一个关键红利是"命中后请求根本不发到网络 ⇒ CORS、混合内容、证书全不适用"（concept-design R9 原文）。
- `Fetch.fulfillRequest` 是在**网络层**凭空给出响应，因此**很可能仍要过渲染进程的 CORS/内容类型检查**（例如跨源 `fetch` 的合成响应若缺 `Access-Control-Allow-Origin` 会被拦）。两份研究都只讨论了"能不能造 body"，没有讨论"造出来的 body 能不能被页面拿到"。
- 这不是我们选主路径的理由之外的新负担，但**如果将来把 CDP 作为"高保真可选模式"**，这是必须先实测的第一个问题。

### 6.4 `Fetch.fulfillRequest` 对 Service Worker 生成的响应可能完全无感（推断）

- 与 DNR 同因：SW 生成的响应不经过网络栈。CDP `Fetch` 域挂在网络栈的拦截点上，因此**由 SW 直接返回的响应很可能根本不会触发 `Fetch.requestPaused`**；用户/页面能感知的"被劫持"就不发生。
- 两份研究都只把 SW 盲区写在 **webRequest/DNR** 名下（t14 §7 B2/B13、t15 §2.5-5），没有把它延伸到 CDP 路径。**标注：推断，无官方明文，需实测**。

### 6.5 版本核对方法论（X1/X2 的可复用教训）

见 §4.1 的四条规程。其核心是：**"文件在 tag 上不存在" ≠ "功能在版本上不存在"**；**"grep 不到" ≠ "代码里没有"**。后者在 128 的 `initator_precursor` 上表现得最直接。

### 6.6 `chrome.sockets.*` 不在扩展 API 索引中（R8 的旁证）

官方扩展 API 索引页全文检索 `sockets` **0 命中**（Chrome Apps 的 `chrome.sockets.*` 已随平台废弃）。这给"扩展不能监听 TCP 端口"（R8）提供了一条可引用的旁证；严格证明仍需逐个 API 排除，但方向上已经足够。

### 6.7 引用 API 名要逐字核（X5 的推广）

`onSendRequest`（不存在）vs `onSendHeaders`（正确）、`webRequestBlocking` vs `webRequestBlocking` 权限名的拼写、`declarativeNetRequestWithHostAccess` vs `declarativeNetRequest`——本报告在核对过程中还注意到 t14 §2.6 提到 ModHeader 权限时写作 "declarativeNetRequest"（正确），t15 §2.3 提到 redirect 权限时引用了 `declarativeNetRequestWithHostAccess`（我在 CRX manifest 里没看到该权限，但 Requestly 用的是动态规则 + host_permissions；该说法来自官方迁移文档，**本次未逐字核实该文档句子**，不作为结论）。建议后续文档对 API 名一律加"官方原文出处"。

---

## 7 证据清单

> 取法缩写：**D** = 官方文档（curl 下载 HTML 后提取文本）；**S** = Chromium 源码（`raw.githubusercontent.com/chromium/chromium/<tag>/…`，逐 tag）；**N** = npm registry 最新 tarball 解包；**C** = Chrome Web Store CRX 下载解包；**B** = 官方博客 / chromedash。

### 7.1 官方文档 / 规范 / 协议（D、B）

| URL | 用途 | 本次核到的关键原文 |
|---|---|---|
| https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest | DNR action 穷举、redirect/URLTransform、SW 边界、规则上限、initiatorDomains | `RuleActionType` 6 值；"Redirects to JavaScript urls are not allowed."；scheme 允许值；"won't affect responses generated by the service worker…"；`GUARANTEED_MINIMUM_STATIC_RULES`/`MAX_NUMBER_OF_*` |
| https://developer.chrome.com/docs/extensions/reference/api/webRequest | MV3 blocking 限制、事件能力、隐藏请求、双 host 权限、缓存、WS、冲突解决 | "…only available to policy installed extensions."；"Aside from webRequestBlocking, the webRequest API is unchanged…"；`chrome-extension://other_extension_id`；Chrome 72 双向 host 权限；"invisible to the web request API"；WS 三不拦；"most recently installed extension wins" |
| https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline | MV2 时间线 | "Chrome 138 is the final version…"；"cease to function for any user upgrading to Chrome 139"；"Aug 31st 2026: All remaining Manifest V2 extensions removed…" |
| https://developer.chrome.com/docs/extensions/develop/migrate/blocking-web-requests | MV3 用 DNR 替代 blocking webRequest | 三类用例改写说明（B1/B10 的辅助证据） |
| https://developer.chrome.com/docs/extensions/reference/api/debugger | debugger 权限、可用 CDP 域、`Debuggee`、`onDetach`、企业策略 | "The available domains are: … **Fetch** …"；`--silent-debugger-extension-api`；"Chrome DevTools is being invoked for the attached tab."；enterprise all-or-nothing 段 |
| https://developer.chrome.com/blog/debugger-enterprise-policy-restrictions | 企业策略严格化（last updated 2026-09-16） | "revert to the pre-Chrome 155 behavior… `--disable-features=ExtensionDebuggerStrictPolicyRestrictions`… removed in Chrome 160" |
| https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns | match pattern 合法 scheme | "scheme: Must be one of the following… http / https / * (only http or https) / file" |
| https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts | 隔离世界、MAIN world + CSP、注入顺序 | "An isolated world is a private execution environment that isn't accessible to the page or other extensions."；"When a content script is injected into the main world, the CSP of the page applies." |
| https://developer.chrome.com/docs/extensions/reference/api/userScripts | MAIN/USER_SCRIPT world 语义 | "Scripts running in the main world are accessible to host pages and other extensions…" |
| https://developer.chrome.com/docs/extensions/reference/api/extensionTypes | `document_start` 语义 | "…before any other DOM is constructed or any other script is run." |
| https://developer.chrome.com/docs/extensions/reference/manifest/content-scripts | `world` 默认值、MAIN 警告 | "Defaults to ISOLATED"；"Warning: There are risks involved when using the MAIN world…" |
| https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions | debugger 不需要 host 权限 | "In some special cases, host permissions are not required… Interacting with the browser using the chrome.debugger API." |
| https://developer.chrome.com/docs/extensions/reference/api | 扩展 API 索引（socket 旁证） | 全文 `sockets` 0 命中 |
| https://chromedevtools.github.io/devtools-protocol/tot/Fetch/ 与 https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/browser_protocol.json | CDP Fetch 域 | `fulfillRequest.body` 原文；`enable.patterns` 语义；`continueRequest.url` "not observable by page"；`RequestStage` |
| https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest/StreamFilter | Firefox 改响应体 | "The filter has full control over the response body" |
| https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Match_patterns | MDN 的 scheme 清单（X4 的证伪依据） | `<all_urls>` = "http", "https", "ws", "wss", "ftp", "data", "file"；无 extension scheme |
| https://blog.mozilla.org/addons/2022/05/18/manifest-v3-in-firefox-recap-next-steps/ | Firefox 保留 blocking webRequest | "Mozilla will maintain support for blocking WebRequest in MV3." |
| https://webidl.spec.whatwg.org/ | WebIDL brand check | "Let validThis be true if jsValue implements target… then throw a TypeError." |
| https://fetch.spec.whatwg.org/ | Response 只读 getter | url / redirected / type 三条 getter 步骤原文 |
| https://xhr.spec.whatwg.org/ | 同步 XHR | "Synchronous XMLHttpRequest outside of workers is in the process of being removed from the web platform…"；`InvalidAccessError` 段 |
| https://www.tampermonkey.net/documentation.php?locale=en&q=sandbox | TM `@sandbox` | `raw`→MAIN_WORLD 且默认；CSP 失败按序回退 |
| https://violentmonkey.github.io/api/metadata-block/ | VM `@inject-into` | `page`/`content`/`auto`；content "cannot access JavaScript objects of the web page" |
| https://docs.requestly.com/account/how-is-browser-extension-different-from-a-desktop-app | Requestly 官方能力对照 | 扩展列 `Serve local file Response ❌`、`Modify HTML/JS/CSS Response ❌`、`Map Local ❌`；"The extension works within the limitations of browser APIs." |
| https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Windows&num=3 ；https://chromereleases.googleblog.com/ | 当前 stable 版本（X3 的证伪依据） | Stable 154.0.8037.97/.98（2026-10-01）；155 在 Beta |

### 7.2 Chromium 源码（S，按 tag）

| 文件 | 用途 | 核对结果 |
|---|---|---|
| `extensions/browser/api/web_request/extension_web_request_event_router.cc` @ 117 / 138 / 154.0.8037.0 / main | `ListenerMatchesRequest` 的其它扩展过滤 | 全部存在（B6/B7） |
| `extensions/browser/api/web_request/web_request_api.cc` @ 51 / 60 / 65 / 70 / 92 / 100 / 104 / 110 / 116 | 同一逻辑在 117 之前的位置 | 全部存在 ⇒ X1 证伪 |
| `extensions/browser/api/declarative_net_request/ruleset_manager.cc` @ 126 / 127 / 128 / 129(×2) / 130 / 132 / 133 / 134 / 135 / 136 / 137 / 145 / 150 / 154 / main | DNR 两条过滤与 main_frame 例外 | 128 起有过滤；134 起有例外 ⇒ X2 证伪（A6/A7） |
| `chrome/browser/extensions/api/debugger/debugger_api.cc` @ main | `suppress_warning`、`ExtensionMayAttachToURL`、`kBrowserTargetId`、`kAlreadyAttachedError`、WebUI 拒绝、策略 kill switch | 全部命中（C5/C7/C10/C13/C14） |
| `chrome/browser/extensions/api/debugger/extension_dev_tools_infobar_delegate.cc` + `chrome/app/generated_resources.grd` @ main | 信息条文案 | `IDS_DEV_TOOLS_INFOBAR_LABEL` 原文（C5） |
| `extensions/common/user_script.cc` @ main | `kValidUserScriptSchemes` | 不含 `SCHEME_EXTENSION`（D1） |
| `extensions/common/extension.cc` @ main | `kValidHostPermissionSchemes` | 不含 `SCHEME_EXTENSION`（G2） |
| `extensions/common/switches.cc` @ main | `AreExtensionsOnExtensionURLsAllowed` | 两个开关（G3） |
| `extensions/browser/api/web_request/web_request_permissions.cc` @ main | `HasWebRequestScheme`（含 extension）、`REQUIRE_HOST_PERMISSION_FOR_URL_AND_INITIATOR`、`HideRequest` | 命中（B5/B9/G2） |

### 7.3 npm 发布包（N，tarball 解包）

| 包 / 版本 | 文件 | 用途 |
|---|---|---|
| `ajax-hook@3.0.3` | `src/xhr-hook.js`、`src/xhr-proxy.js` | E2 |
| `xhook@1.6.2` | `dist/xhook.js`、`README.md` | E3 |
| `fetch-intercept@2.4.0` | `lib/browser.js`、`README.md` | E4 |
| `@mswjs/interceptors@0.45.7` | `src/interceptors/XMLHttpRequest/xml-http-request-proxy.ts`、`.../xml-http-request-controller.ts`、`src/utils/patches-registry.ts`、`package.json` | E5 |
| `nise@6.1.5` | `lib/fake-xhr/index.js` | E6 |

### 7.4 Chrome Web Store CRX（C，`clients2.google.com` 下载解包）

| 扩展 / ID / 版本 | 核对内容 | 用途 |
|---|---|---|
| ModHeader V3 `cndlnhnjdlmipaflgajjikndbfkfnohp` `2026.8.8.18` | manifest 权限、`background.js` 的 `modifyHeaders` 调用 | F2 / 撤销 t15 U1 |
| Requestly `mdnleldcmiljblolnjhpnblkcekpdkpa` `26.9.29` | manifest 权限、`page-scripts/ajaxRequestInterceptor.ps.js`（XHR/fetch/`new Response`）、`serviceWorker.js`（7×`world:"MAIN"`） | F1 / 撤销 t15 U2 |
| Tamper Dev `cpcmdnpekbomkhllkbmghhbefjbbjgni` `2` | MV3 manifest 权限、后台产物含 `Fetch.enable`/`continueRequest`/`fulfillRequest` | F3 / t15 U16 |

### 7.5 开源项目源码（GitHub raw）

| URL | 用途 |
|---|---|
| https://raw.githubusercontent.com/google/tamperchrome/master/v2/manifest_base.json （及 `v2/background/src/{debuggee,interception,request}.ts`） | F3（仓库为 MV2；`Fetch.fulfillRequest` 用法） |
| https://raw.githubusercontent.com/kylepaulsen/ResourceOverride/master/manifest.json 、`/src/background/requestHandling.js` | F4 |
| https://raw.githubusercontent.com/einaregilsson/Redirector/master/manifest.json 、`/js/background.js` | F5 |
| https://cdn.jsdelivr.net/gh/violentmonkey/violentmonkey@master/src/manifest.yml | F7（MV2） |

### 7.6 本次记下的"未取证成功"通道

| 通道 | 现象 | 影响 |
|---|---|---|
| `api.github.com`（用于核 Requestly 仓库目录） | HTTP 403 `API rate limit exceeded` | F8 保持无法核实 |
| 浏览器实测（CORS/`isTrusted`/DNR `data:`/executeScript 自家页面） | 本环境无浏览器 | U1/U2/U5/U8 保持无法核实 |

---

*（完）*
