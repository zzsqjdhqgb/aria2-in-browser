# 独立复核：带 Cookie 下载 / 多线程下载 关键断言核实（t12 / t13）

> 本文件是「aria2-in-browser 浏览器技术边界测绘」的输入文档之一，任务号 **t19**。
> **本文不复用、不继承 `needs-A-cookie-multithread.md`（下称 A）与 `needs-B-cookie-multithread.md`（下称 B）的任何结论倾向**：两份文件只作为「被核实的断言清单」使用；本文每一条判定都回到本轮**重新抓取**的规范原文 / 官方文档 / 开源项目源码。
> 本文只写本文件；未改代码、未改 `docs/concept-design/concept-design.md`、未改 A/B 两份文件。

---

## 0 元信息

| 项 | 值 |
|---|---|
| 复核人 | `sum-cookie-evidence`（团队 `aria2-in-browser-boundary`，任务 t19，attempt `0b03065b-b3da-4745-886c-f0967463eb20`） |
| 复核日期 | **2026-10-06**（UTC，与本轮全部抓取同批） |
| 复核对象 | `/workspace/docs/research/prior-art/needs-A-cookie-multithread.md`（515 行）与 `needs-B-cookie-multithread.md`（953 行）；上位依据 `/workspace/docs/concept-design/concept-design.md` v0.5（R1–R13、§5.2、§6、附录 A） |
| 判定三态 | **已核实**（在一手证据里命中原文/源码逻辑，且未发现反证）｜**已证伪**（含「部分证伪 / 表述过度概括 / 引用路径错误」，即该断言按字面解读与一手证据矛盾）｜**无法核实**（查不到决定性证据，明确写出卡点） |
| 取证方式（本次全部重做） | ①规范原文：Fetch / File System / Storage / Service Worker / WebIDL / RFC 9113；②MDN；③Chrome 官方扩展文档（在线最新版）；④**Chromium 源码** `chromium.googlesource.com`（`?format=TEXT` → base64 解码）；⑤开源项目源码：GitHub `raw.githubusercontent.com` + `codeload` tarball 全仓 grep；⑥GitHub API 取最后提交时间；⑦Chrome Web Store 商品页 HTML；⑧Chromium issue tracker 的 JSON 端点（`/action/issues/<id>`）；⑨aria2 官方手册 |
| 明确未做 | **本轮没有任何真实浏览器实测**（无网络请求验证、无扩展加载、无 DNR/OPFS 运行）。本文所有「已核实」都是**文档级或源码级**核实；凡需要运行时行为的结论一律落在「无法核实」或显式标注「实现级未实测」 |
| 快照说明 | 抓取物只存在于临时目录（`/tmp/ev`）供取证，不作为交付物；**本文件的唯一交付物就是本文件** |
| 与 A/B 的关系 | A/B 的分工是「调研」；本文只做「核实」，因此本文**不重复**它们的方案描述与建议，只回答「这句话对不对」 |

### 0.1 本轮抓取到的关键证据锚点（便于日后复检）

- Chromium 源码（`main` 分支、未固定 commit）：`extensions/browser/api/cookies/cookies_helpers.cc`、`cookies_api.cc`、`net/cookies/cookie_options.h`、`cookie_partition_key_collection.{h,cc}`、`chrome/browser/extensions/api/downloads/downloads_api.cc`、`download_extension_errors.h`、`net/http/http_util.cc`、`extensions/browser/api/declarative_net_request/{constants.h,indexed_rule.cc}`、`net/socket/client_socket_pool_manager.cc`、`components/download/public/common/download_url_parameters.{h,cc}`、`third_party/blink/renderer/modules/file_system_access/file_system_file_handle.idl`
- 开源项目（本轮自己 clone / raw 抓取）：Aria2-Explorer、Aria2-for-chrome、YAAW-for-Chrome、turbo-download-manager（含全仓 tarball）、downthemall、ipull、Get-cookies.txt-LOCALLY、Cookie-Editor、webtorrent、StreamSaver.js、FileSaver.js、browser-fs-access、native-file-system-adapter

---

## 1 核实结论摘要

### 1.1 计数（与 §2 三张表逐行对应）

| 结论 | 条数 | 占比 |
|---|---|---|
| **已核实** | **40** | 85% |
| **已证伪 / 需修正（含部分证伪）** | **3**（其中 1 条是 A/B **共同**的错） | 6% |
| **无法核实** | **4**（外加 §5 列出的 8 条子项） | 9% |
| 合计 | 47 | 100% |

### 1.2 一句话结论

**没有发现任何一条「如果错了就会让整个方案翻车」的断言被证伪。** A/B 用来支撑「Cookie 是 fetch 的 forbidden header」「`chrome.cookies` 能读 HttpOnly」「`chrome.downloads` 的 `headers` 不能带 Cookie」「DNR `append` 白名单含 `cookie` 且分隔符为 `"; "`」「OPFS 同步随机写只在 Dedicated Worker」「每 host 6 连接」「HTTP/2 用 `SETTINGS_MAX_CONCURRENT_STREAMS`」「MV3 SW 30s/5min/30s 终止」这批**骨架结论，逐条在一手规范/源码里命中原文**，可以继续作为后续「能力清单」与详细设计的地基。

真正的交叉验证收益集中在 5 处（详见 §3/§4/§6）：

1. **两份共同错**：`chrome.cookies.getAll({..., partitionKey: {}})` 被两份都描述为「拿分区 cookie」；Chromium 源码显示空对象 `{}` 语义是 **`CookiePartitionKeyCollection::ContainsAll()`（匹配所有分区键，含未分区）**，而省略 `partitionKey` 才是「只要未分区」。
2. **两份共同的过度概括**：把 MV3 改请求头说成「唯一通路是 DNR」。A 明文写「唯一」，B 用同一框架；实际至少还有两条（policy-installed 扩展的 `webRequestBlocking`——A 自己引了；`chrome.debugger` + CDP `Network.setExtraHTTPHeaders`——B 自己列为未验证）。
3. **两份都列为「未验证」、但本轮拿到了源码级答案**：`chrome.downloads.download()` 请求**默认 `credentials_mode = kInclude`，且其 traffic annotation 声明 `cookies_allowed: YES` / `cookies_store: "user"`** ⇒ 「下载请求是否自带 cookie」不再是纯未知（细节见 §6.1）。
4. **两份都列为「未验证」、本轮在规范层面给出肯定答案**：OPFS 的**异步**路径（`navigator.storage.getDirectory()` / `createWritable()`）在 Service Worker 里**规范上是暴露的**（`[Exposed=(Window,Worker)]` + `ServiceWorkerGlobalScope` 的 `[Global=(Worker,ServiceWorker)]`）；仍然只有 `createSyncAccessHandle()` 是 `[Exposed=DedicatedWorker]`。
5. **两份都保留为「无法核实」、本轮也只能维持**：DNR 是否作用于 `chrome.downloads` 触发的请求。本轮额外查到了 Chromium issue 40256297 的正文（用 issue tracker 的 JSON 端点拿到），但它的主题是「DNR 响应头强制下载」，**与 downloads API 无关**；源码路径也未能定位到决定性判据（见 §5.1）。

### 1.3 复核覆盖的重点问题（任务点名的 6 项）

| 任务点名 | 结论 |
|---|---|
| `Cookie` 是否确实是 fetch 的 forbidden header | **是**（Fetch 规范列表原文 + MDN + MDN Cookie 页字段表） |
| `chrome.cookies` 能否读 HttpOnly、需要什么权限 | **能读**；需 `"cookies"` 权限 + 目标 host 的 host permissions；源码 `MakeAllInclusive()` / `set_include_httponly()` 为证 |
| `chrome.downloads.download({headers})` 支持哪些请求头 | 受 `net::HttpUtil::IsSafeHeader` 校验；`kForbiddenHeaderFields` 含 `cookie`/`referer`/`user-agent`/`origin` 等；**`range` 不在禁列**；错误串 `"Unsafe request header name"` |
| DNR `modifyHeaders` 能否设 Cookie | `append` 有官方白名单明文（含 `cookie`，分隔符 `"; "`）；`set` **无明文禁止也无官方示例 → 维持「未验证/无法核实」**；`remove` 官方有示例 |
| 随机写入能力在哪些执行上下文可用 | 用户可见文件：FSA `createWritable`（`[Exposed=(Window,Worker)]`，但 picker 需 `Window` + 瞬态激活）；OPFS：`createWritable`（Window/Worker 含 SW）+ `createSyncAccessHandle`（**仅 Dedicated Worker**，独占锁） |
| 现成方案是否真实存在、描述是否准确 | **全部真实存在**；Aria2 Explorer / YAAW / Aria2-for-chrome / Get-cookies / Cookie-Editor / TDM / DTA / ipull / WebTorrent / StreamSaver / FileSaver 的引用逐条命中。**3 处引用/描述错误**见 §3.4–§3.6 |

---

## 2 逐条核实表

> 阅读提示：**出处**列写「A §x」或「B §x」表示该断言来自哪份文件（两方皆有则并列）。**证据**列给 URL + 原文/源码摘录；摘录为英文原文（保留原文错误拼写）。**影响**列说明这条错了会伤到哪里。
> 全部 URL 均为本轮抓取时的地址（Chrome 文档为「在线最新版」，Chromium 为 `main` 分支未固定 commit）。

### 2.1 表 A：Cookie 与请求头（17 条）

| # | 断言 | 出处 | 结果 | 证据（URL + 原文/源码摘录） | 影响 |
|---|---|---|---|---|---|
| A01 | `Cookie` 是 fetch 的 forbidden request header，JS 无法设置或修改 | A §C1/A-6、B §A-6.1/C1 | **已核实** | <https://fetch.spec.whatwg.org/#forbidden-header-name>：forbidden request-header 名单含 `` `Cookie` ``，并注 *"These are forbidden so the user agent remains in full control over them."*；<https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header>：*"A forbidden request header is an HTTP header name-value pair that cannot be set or modified programmatically in a request."*（名单含 `Cookie`）；<https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cookie>：字段表 *"Forbidden request header — Yes"* | 核心约束成立：任何「fetch 手写 Cookie 头」的方案在规范层就不成立 |
| A02 | `User-Agent` 已从 fetch 规范解禁，但 Chrome 仍静默丢弃（crbug 571722） | A §9.1 E2 附注 | **已核实** | MDN 同上页注：*"The User-Agent header used to be forbidden, but no longer is. However, Chrome still silently drops the header from Fetch requests (see Chromium bug 571722)."*；Chromium <https://chromium.googlesource.com/chromium/src/+/main/net/http/http_util.cc> L432-434：`// TODO(mmenke): This is no longer banned, but still here due to issues mentioned in https://crbug.com/571722.` 后跟 `"user-agent"` | 「`chrome.downloads` 不能设 UA」结论仍成立，但原因是 Chromium 历史保留而非 fetch 规范（A/B 均未点破，见 §4.3） |
| A03 | `Range` 不是 forbidden header、单区间时是 CORS-safelisted、且是 privileged no-CORS request-header；服务器可忽略 `Range` 返回 200 | A §B-9(c)/§9.1 E3、B §C11/C12 | **已核实** | Fetch 规范：*"A privileged no-CORS request-header name is a header name that is a byte-case-insensitive match for one of `Range`. … `Range` headers are commonly used by downloads and media fetches."*，CORS-safelisted 段含 `` `range` Let rangeValue be the result of parsing a single range header value given value and false.`` + *"As web browsers have historically not emitted ranges such as `bytes=-500` this algorithm does not safelist them."*；<https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Range>：*"The header is a CORS-safelisted request header when the directive specifies a single byte range."* + *"Forbidden request header — No"* + *"A server that doesn't support range requests may ignore the Range header and return the whole resource with a 200 status code."* | 「多路 Range 发得出去」成立；「服务器可以无视 Range」成立 ⇒ 分片方案必须处理 200 降级 |
| A04 | `chrome.downloads.download({headers})` 对每个 header 依次校验 `IsValidHeaderName` → `IsSafeHeader` → `IsValidHeaderValue`，禁 `cookie`/`referer`/`user-agent`/`origin`/`host`/`accept-encoding` 等，错误串 `"Unsafe request header name"`；`Range` 不在禁列 | A §C2/§9.3 E24/E25、B §A-6.2/§9.2(25)(26)(27) | **已核实** | <https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/extensions/api/downloads/downloads_api.cc> L1222-1233：`if (!net::HttpUtil::IsSafeHeader(header.name, header.value)) { return RespondNow(Error(download_extension_errors::kInvalidHeaderUnsafe)); }`；<https://chromium.googlesource.com/chromium/src/+/main/net/http/http_util.cc> L409-434 `kForbiddenHeaderFields[]` 依次含 `"cookie"`, `"cookie2"`, `"origin"`, `"referer"`, `"set-cookie"`, `"user-agent"`（**无 `range`**），`IsSafeHeader` L469-477 逐项 `EqualsCaseInsensitiveASCII`；<https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/extensions/api/downloads/download_extension_errors.h> L23：`inline constexpr char kInvalidHeaderUnsafe[] = "Unsafe request header name";` | 核心死路确认：`chrome.downloads` 永远不能带 Cookie/Referer/UA ⇒ 附录 A 的前提「downloads 不支持敏感 header」有源码级支撑 |
| A05 | Chrome 文档口径：`headers` 被描述为 *"restricted to those allowed by XMLHttpRequest"* | A §A-6 路线2、B §9.1(4) | **已核实** | <https://developer.chrome.com/docs/extensions/reference/api/downloads>（`DownloadOptions.headers`）：*"Extra HTTP headers to send with the request if the URL uses the HTTP[s] protocol. Each header is represented as a dictionary containing the keys `name` and either `value` or `binaryValue`, restricted to those allowed by XMLHttpRequest."* | 文档与源码互相印证 |
| A06 | 用 `chrome.cookies` 需 `"cookies"` 权限 + 目标 host 的 host permissions；`getAll` 只返回扩展有 host 权限的域的 cookie | A §A-5/§9.2 E15、B §A-4 | **已核实** | <https://developer.chrome.com/docs/extensions/reference/api/cookies>：*"To use the cookies API, declare the `"cookies"` permission in your manifest along with host permissions for any hosts whose cookies you want to access."*；`getAll()`：*"This method only retrieves cookies for domains that the extension has host permissions to."*；`Cookie.httpOnly`：*"True if the cookie is marked as HttpOnly (i.e. the cookie is inaccessible to client-side scripts)."* | 权限申请必须进「能力报告」（R13-3）的结论成立 |
| A07 | `chrome.cookies` 能读到 HttpOnly：`GetCookieListFromManager()` 用 `CookieOptions::MakeAllInclusive()`；`set` 路径显式 `set_include_httponly()` | A §A-5/§9.3 E21-23、B §A-4/§9.2(28) | **已核实**（并精确化） | <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/cookies/cookies_helpers.cc> L175-192：`manager->GetCookieList(url, net::CookieOptions::MakeAllInclusive(), …)`；<https://chromium.googlesource.com/chromium/src/+/main/net/cookies/cookie_options.h> L263-274：注释 *"…work for getting/setting all types of cookies, including HttpOnly and SameSite cookies."* + 默认 `bool exclude_httponly_ = true;` + `MakeAllInclusive()`；<https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/cookies/cookies_api.cc> L613-616：`options.set_include_httponly();`；同文件 L433-441：`getAll` **有 url 时**走 `GetCookieListFromManager`，**url 为空时**才走 `GetAllCookiesFromManager`（`cookies_helpers.cc` L187-192 直接 `manager->GetAllCookies()`，同样无 HttpOnly 过滤） | 「HttpOnly 可读」成立。**精确化**：B §A-4 写「`getAll` 路径直接调 `GetAllCookiesFromManager`」——只在 `getAll` 不带 `url` 时成立；Aria2 Explorer 这类带 `url` 的调用实际走 `GetCookieListFromManager`（结论不变，但引用要改） |
| A08 | `chrome.cookies.getAll({url, storeId, partitionKey: {}})` 用来「拿分区 cookie」（两份都把空对象解释为「分区 cookie 那一路」） | A §A-5 边角/A-7.1、B §A-4/A-5.1 | **已证伪（共同错误）** | <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/cookies/cookies_helpers.cc> L418-432：`if (!partition_key) { return net::CookiePartitionKeyCollection(); } if (!partition_key->top_level_site) { return net::CookiePartitionKeyCollection::ContainsAll(); } if (partition_key->top_level_site.value().empty()) { return net::CookiePartitionKeyCollection(); }`；<https://chromium.googlesource.com/chromium/src/+/main/net/cookies/cookie_partition_key_collection.h> L62-76：`bool ContainsAllKeys() const { return !state_; }`、注释 *"If this is nullopt, the instance matches all keys."*；<https://chromium.googlesource.com/chromium/src/+/main/net/cookies/cookie_partition_key_collection.cc> L15-17：默认构造 = 空集合（`state_` 为空 ⇒ `IsEmpty()` ⇒ 「避开搜索 PartitionedCookieMap」，即只匹配未分区）；Chrome 文档：*"By default, all API methods operate on unpartitioned cookies. The partitionKey property can be used to override this behavior."*（<https://developer.chrome.com/docs/extensions/reference/api/cookies>） | **两份研究共同犯的同一个错**（见 §4.1）。后果：①两次 `getAll` 中第二次是**全部键的超集**（含未分区），不是「另一个分区」；②`new Map([...cookies, ...partitionedCookies])` 的「后者覆盖前者」语义 = **分区 cookie 覆盖同名未分区 cookie**，在「请求实际不带分区」的场景会拼错值；③能力/文档若照抄「partitionKey: {} 拿分区 cookie」会误导后续设计 |
| A09 | DNR `append` 的官方白名单明文包含 `cookie`，追加分隔符为 `"; "` | A §C4/§9.2 E19/§9.3 E27、B §A-6.3/C9/§9.2(30) | **已核实** | <https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest>「Header modification」：*"The append operation is only supported for the following request headers: accept, … cookie, … range, … user-agent, … This allowlist is case sensitive (bug 449152902). When appending to a request or response header, the browser will use the appropriate separator where possible."*；源码 <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/declarative_net_request/constants.h> L317-339：`{{"cookie", "; "}, … {"range", ", "}, … {"user-agent", " "}}` | 「浏览器内注入自定义 Cookie 头」唯一有文档背书的路成立 |
| A10 | 白名单只约束 `append`；`set`/`remove` 在规则解析期不受白名单限制；越界 append 直接导致规则安装失败（`ERROR_APPEND_INVALID_REQUEST_HEADER`） | A §C4/F7/§9.3 E28、B §A-6.3 | **已核实** | <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/declarative_net_request/indexed_rule.cc> L516-538：`if (are_request_headers && header_info.operation == dnr_api::HeaderOperation::kAppend) { if (!kDNRRequestHeaderAppendAllowList.contains(base::ToLowerASCII(header_info.header))) { return ParseResult::ERROR_APPEND_INVALID_REQUEST_HEADER; } }`（即仅 request + append 查名单） | 「白名单外的 header 只能用 set」这一推论成立；同时也说明「DNR 规则安装失败是显式的、不是静默丢弃」 |
| A11 | 「DNR 能否 `set` 整个 `Cookie` 头」必须实测（两份都标未验证） | A §5.1 不能做③/§8.8、B §A-6.3/§8.1 | **无法核实（维持）** | 官方文档只给 `append` 白名单（同上）；<https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest/ModifyHeaderInfo> 同样只有 append 列表 + *"In Firefox, the extension needs host permissions for the new value of the Host header."*；未找到任何「禁止 set Cookie」的明文，也未找到官方 `set` Cookie 示例；运行时合并顺序（<https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest> L403-406：*"If a rule sets a header, then only lower priority rules from the same extension can append to that header."*）**不等于**「允许 set」。本轮无实测 | 保持「未实测不得声明」的结论；能力清单不能把「替换式 Cookie 注入」写成已支持 |
| A12 | MV2 时代可用 `webRequestBlocking` + `extraHeaders` 改写 `Cookie`；MV3 普通扩展已不可用 | A §A-6 补充/§9.2 E20、B §A-6.6/§9.1(7) | **已核实** | MV2 文档 <https://developer.chrome.com/docs/extensions/mv2/reference/webRequest>：*"Starting from Chrome 72, the following request headers are **not provided** and cannot be modified or removed without specifying `'extraHeaders'` in `opt_extraInfoSpec`："* 列表为 `Accept-Language / Accept-Encoding / Referer / Cookie`；MV3 文档 <https://developer.chrome.com/docs/extensions/reference/api/webRequest>：*"As of Manifest V3, the `"webRequestBlocking"` permission is no longer available for most extensions. … Policy installed extensions can continue to use `"webRequestBlocking"`."* | 「历史路不可用」成立；**但注意**它同时是 A14 的反例来源 |
| A13 | 「多个扩展改同一个头时，只有最近安装的生效，其余被静默忽略」 | A §C12/F8/§7 | **已证伪（范围迁移错误）** | 该原文确实存在，但在 **webRequest** 页：<https://developer.chrome.com/docs/extensions/reference/api/webRequest> L479-482：*"Only one extension can redirect a request or modify a header at a time. If more than one extension attempts to modify the request, the most recently installed extension wins, and all others are ignored. An extension is not notified if its instruction to modify or redirect has been ignored."*。而 **DNR** 页对 header modification 的描述是**跨扩展按优先级叠加**：<https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest> L400-406：*"These rules are applied by Chrome in an order such that rules from a more recently installed extension are always evaluated before rules from an older extension. … If a rule appends to a header, then lower priority rules can only append to that header."*；只有 block/redirect 才是「选一个」：L398 *"If two rules are of the same type, Chrome chooses the rule from the most recently installed extension."* | A 把 webRequest 的「赢者通吃」直接搬到 DNR，作为「多扩展改头冲突」盲区（F8）**不成立/至少无证据**；后续盲区清单应按 DNR 的「叠加 + 优先级」描述重写 |
| A14 | 「MV3 里改请求头唯一通路是 DNR」 | A §C4（明文「唯一」）；B §A-6.3/§5.1（同一框架，未写「唯一」） | **已证伪（过度概括）** | A 自己引用的 webRequest 文档就给出例外：*"Policy installed extensions can continue to use `"webRequestBlocking"`."*（同 A12 证据）；另有一条 B 自己列为未验证的通路：`chrome.debugger` + CDP `Network.setExtraHTTPHeaders`（命令确实存在：<https://chromedevtools.github.io/devtools-protocol/tot/Network/#method-setExtraHTTPHeaders>；`chrome.debugger` 参考页 <https://developer.chrome.com/docs/extensions/reference/api/debugger>） | 「唯一」的措辞会误导后续设计把 DNR 当成唯一可选项；实际应写「普通扩展的**常规**通路是 DNR，另有两条受限/未验证通路」 |
| A15 | 有 host permissions 时，扩展对第三方的请求被当作 same-site（`SameSite=Strict` 也能发），第三方 cookie 被拦则不适用，且只对网络请求、不含 `document.cookie`；内容脚本则始终按页面 origin、跨源始终跨源 | A §A-3/A-4/§C6、B §A-3.1/A-3.2/C3/C4 | **已核实** | <https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies> L250-259：*"For cookies associated with third-party sites, such as … a request made from an extension page to a third-party origin, cookies behave the same as the web except in two ways: … Requests from an extension to a third-party are treated as same-site if the extension has host permissions for the third-party. This means `SameSite=Strict` cookies can be sent. Note that this only applies to network requests, not access through `document.cookie` in JavaScript, and does not apply if third-party cookies are blocked."*；L247：*"Cookies set on `chrome-extension://` pages always use `SameSite=Lax`."*；<https://developer.chrome.com/docs/extensions/develop/concepts/network-requests> L198-210：*"Content scripts initiate requests on behalf of the web origin … Cross-origin requests are always treated as such in content scripts, even if the extension has host permissions."* | 三条活路里的「扩展 SW fetch」语义成立；注意官方原文说的是「requests from an extension」，**未明确覆盖导航/tabs 或 `chrome.downloads` 场景**（见 §6.3） |
| A16 | 跨源 `fetch` 默认 `credentials: same-origin`；`include` 还需服务端 `Access-Control-Allow-Credentials` + 回显具体 origin（不能 `*`）；`SameSite=Lax` 明确排除 fetch；HttpOnly cookie 仍会随 JS 发起的请求发出 | A §A-1/A-2/§9.1 E4/E5、B §A-1/A-2/C5-C7、§9.1(8)-(11) | **已核实** | <https://developer.mozilla.org/en-US/docs/Web/API/RequestInit>：*"`same-origin`: Only send and include credentials for same-origin requests. … Defaults to `same-origin`."* / *"even if `credentials` is set to `include`, the server must also agree to their inclusion by including the `Access-Control-Allow-Credentials` in its response. Additionally, in this situation the server must explicitly specify the client's origin in the `Access-Control-Allow-Origin` response header (that is, `*` is not allowed)."*；<https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie>：L241-244 *"This would exclude, for example, requests made using the `fetch()` API"*；L216-218 *"Note that a cookie that has been created with HttpOnly will still be sent with JavaScript-initiated requests, for example, when calling `XMLHttpRequest.send()` or `fetch()`."* | 页面侧三堵墙成立；「HttpOnly 只限制读、不限制发」成立 |
| A17 | Chrome 文档称标准化 `browser.*` 命名空间自 **Chrome 148** 起可用 | A §0 版本线索 | **已核实** | <https://developer.chrome.com/docs/extensions/reference/api/cookies> 页顶横幅：*"Chrome now supports the standardized browser.* namespace (available from Chrome 148). We are gradually updating the documentation."* | 说明本轮 Chrome 文档对应 ~148 版本线；复核时请以当日稳定版为准（本文未查稳定版号） |

### 2.2 表 B：现成方案是否真实存在、描述是否准确（16 条）

| # | 断言 | 出处 | 结果 | 证据（URL + 原文/源码摘录） | 影响 |
|---|---|---|---|---|---|
| B01 | Aria2 Explorer 为 `manifest_version: 3` / `version: 2.8.3`，permissions 含 `cookies`…`downloads`，`host_permissions: ["<all_urls>"]` | A §A-7.1/E29、B §A-5.1 | **已核实** | <https://raw.githubusercontent.com/alexhua/Aria2-Explorer/master/manifest.json>：`"version": "2.8.3"`, `"manifest_version": 3`, `"permissions": ["cookies","tabs","notifications","contextMenus","downloads","storage","scripting","sidePanel","power"]`, `"host_permissions": ["<all_urls>"]`（另有 `"minimum_chrome_version": "116.0.0"`，B 已提、A 未提） | 参照物真实存在且版本号准确 |
| B02 | 取 cookie 实现：`chrome.cookies.getAll({url, storeId})` → 再 `getAll({url, storeId, partitionKey:{}})`（try/catch 容错）→ `Map` 去重 → `"Cookie: " + join("; ")` → 作为 aria2 `header` 选项随 `aria2.addUri` 发出；**不过滤 httpOnly** | A §A-7.1/E30、B §A-5.1(2)(3) | **已核实** | <https://raw.githubusercontent.com/alexhua/Aria2-Explorer/master/background.js>：L110-128 `async function getCookies(downloadItem)`（含 L117-121 try/catch + 注释 `// Ignore browsers that do not support partitionKey.`）；L143-147 `headers.push("Cookie: " + cookieItems.join("; ")); headers.push("User-Agent: " + navigator.userAgent);`；L154-155 `options.header = headers; … aria2.addUri(downloadItem.url, options)`；全函数无 `httpOnly` 判定 | 「成熟解法＝读出来 + 外送」成立；行号与 A/B 引用基本一致（A 写 L110-L154、B 写 110-132/134-165，均落在同一函数族） |
| B03 | Aria2 Explorer 有安全闸门：仅 `https/wss`、localhost 或显式 `ignoreInsecure` 才附 cookie，本地化文案提示风险 | B §A-5.1(4) | **已核实** | 同 `background.js` L137：`if (rpcItem.ignoreInsecure \|\| Utils.isLocalhost(rpcItem.url) \|\| /^(https\|wss)/i.test(rpcItem.url)) {`；<https://raw.githubusercontent.com/alexhua/Aria2-Explorer/master/_locales/en/messages.json>：*"For insecure RPC, the related website cookies will not be attached when auto-download or direct export."* | 佐证「cookie 外送」的风险面是作者自己承认的 |
| B04 | YAAW-for-Chrome 为 MV3 / 1.0.0，permissions 含 `cookies`，host_permissions `<all_urls>`；`chrome.cookies.getAll({url})` → `Cookie:` 头 → `aria2.addUri` 的 `header`；并把 Basic `Authorization` 塞进 options | A §A-7.3/E31、B §A-5.2 | **已核实** | <https://raw.githubusercontent.com/acgotaku/YAAW-for-Chrome/master/manifest.json>（`"manifest_version": 3`, `"version": "1.0.0"`, permissions 含 `cookies`）；<https://raw.githubusercontent.com/acgotaku/YAAW-for-Chrome/master/background.js> L114-135：`chrome.cookies.getAll({ url: fileDownloadInfo.link }, function (cookies) { … formatedCookies.push(cookie.name + '=' + cookie.value) … header.push('Cookie: ' + formatedCookies.join('; ')); header.push('User-Agent: ' + navigator.userAgent) … method: 'aria2.addUri', params: [[fileDownloadInfo.link], { header }] })`；L108-109：`parameter.options.headers.Authorization = authStr` | 「同一范式被至少两个独立扩展使用」成立 |
| B05 | `alexhua/Aria2-for-chrome` 与 A-7.1 是同一作者、同 `2.8.3`/MV3，取 cookie 代码一致 | A §A-7.2/E32 | **已核实** | <https://raw.githubusercontent.com/alexhua/Aria2-for-chrome/master/manifest.json>：`"version": "2.8.3"`, `"manifest_version": 3`；<https://raw.githubusercontent.com/alexhua/Aria2-for-chrome/master/background.js> L110-155（`getCookies` / `partitionKey` / `Cookie: ` 拼装与 A-7.1 同型，行号一致） | 「同作者两条产品线已收敛」成立；引用同一份代码时不应重复计数 |
| B06 | Get cookies.txt LOCALLY 0.7.2（MV3）`permissions: ["activeTab","cookies","downloads","notifications"]`、`host_permissions: ["<all_urls>"]`；导出 Netscape 时只取 `{domain, expirationDate, path, secure, name, value}`（不区分 httpOnly ⇒ HttpOnly 值会被导出） | B §A-5.4 | **已核实** | <https://raw.githubusercontent.com/kairi003/Get-cookies.txt-LOCALLY/master/src/manifest.json>（权限与 host_permissions 原文一致）；<https://raw.githubusercontent.com/kairi003/Get-cookies.txt-LOCALLY/master/src/modules/cookie_format.mjs>：`({ domain, expirationDate, path, secure, name, value })`（无 `httpOnly`），并有 `header` 序列化 `` `${name}=${value};` `` | 「扩展读 HttpOnly」的独立旁证成立（注意：该仓库最后提交为 **2025-10-05**，B 未给时间） |
| B07 | Cookie-Editor 直接读写 `cookie.httpOnly`，导出选项含 `httponly` | A §A-8/E33 | **已核实** | <https://raw.githubusercontent.com/Moustachauve/cookie-editor/master/interface/popup/cookie-list.js>：L199-200 `if (httpOnly !== undefined) { cookie.httpOnly = httpOnly; }`；<https://raw.githubusercontent.com/Moustachauve/cookie-editor/master/interface/options/options.html> L84：`<option value="httponly">Http Only</option>`；仓库最后提交 **2026-08-14**（GitHub API commits 端点） | 旁证成立。**但**其 manifest 路径本轮仍未定位（`/manifest.json`、`/src/manifest.json`、`/interface/manifest.json` 均 404；GitHub contents API 被限流）——A 的「未验证」保留正确 |
| B08 | TDM（Turbo Download Manager）的多段判定/分片/206 校验/最小最大分片/默认 3 线程 | A §B-1/E34、B §B-1/(1)(2)(3) | **已核实**（A 有一处数值需修正） | <https://raw.githubusercontent.com/inbasic/turbo-download-manager/master/src/lib/wget.js> L124-131：`'multi-thread': !!length && contentEncoding === null && req.getResponseHeader('Accept-Ranges') === 'bytes' && lengthComputable !== 'false'`；L88-90：`obj.headers.Range = \`bytes=${range.start}-${range.end}\`;`；L70-73：`// make sure server supports partial content fetching; 206` + `throw new utils.CError(\`expected 206 but got ${res.status}\`, 1, …)`；<https://raw.githubusercontent.com/inbasic/turbo-download-manager/master/src/lib/config.js> L178 `config.defineInt('wget.threads', 3);`、L185-186 `('wget.min-segment-size', 50 * 1024, 1024)` / `('wget.max-segment-size', 100 * 1024 * 1024, 100 * 1024)` | 骨架可复用成立。**修正**：A §B-1 写 `max-segment-size`（50 MBytes）——那是源码头注释 L22 的写法；**默认值是 100 MiB**（config.js），B 正确（见 §3.6） |
| B09 | TDM 的按 offset 写盘依赖 HTML5 FileSystem（`createWriter`/`seek`/`truncate`）与 **Chrome App 专属** `chrome.fileSystem`；扩展构建（`manifest-extension.json`）是 MV2 且权限里**没有** `fileSystem` | A §B-1/E35/E36、B §B-1/(4)(5) | **已核实**（B 有一处引用路径错误） | <https://raw.githubusercontent.com/inbasic/turbo-download-manager/master/src/lib/chrome/chrome-cm.js> L346-356：`write: function (file, offset, arr) { … file.createWriter(function (fileWriter) { … fileWriter.seek(offset); fileWriter.write(blob); }`，L337-344 `truncate`，L319 `window.requestFileSystem = window.requestFileSystem \|\| window.webkitRequestFileSystem;`，L263-271 `chrome.fileSystem.chooseEntry({type:'openDirectory'} …)` + `chrome.fileSystem.retainEntry(folder)`；<https://raw.githubusercontent.com/inbasic/turbo-download-manager/master/src/manifest-extension.json>：`"manifest_version": 2`，permissions = `storage/tabs/notifications/contextMenus/webRequest/<all_urls>/clipboardRead/downloads`（**无 `fileSystem`**） | 「TDM 的写盘前提在 MV3 扩展里不存在」成立。**修正**：B §B-1 把该代码的路径写成 `src/lib/opera/chrome-cm.js`——该文件在 master 里只有一行 `../chrome/chrome-cm.js`（构建期 include 占位符，本轮实测 22 字节）；实际实现文件是 `src/lib/chrome/chrome-cm.js`（A 引用正确，见 §3.5） |
| B10 | TDM 仓库停更于 **2017-02-21**（0.3.4），商店页仍宣称多线程 | A §B-1/E37、B §B-1 | **已核实** | GitHub API `repos/inbasic/turbo-download-manager/commits?per_page=1`：`2017-02-21T07:58:28Z  9b5db35a  "updating to 0.3.4"`；商店页 <https://chromewebstore.google.com/detail/turbo-download-manager-cl/kemfccojgjoilhfmcblgimbggikekjip>：*"multi-threading support"*、*"Speeds up downloads (speed depends on the number of segments and your network capacity)"* | 「生态已死」的结论成立 |
| B11 | TDM 全仓库 `src/` 检索 cookie **唯一命中** Firefox 层的 `forceAllowThirdPartyCookie = true`（即它不自己拼 Cookie 头） | B §A-5.5 | **已核实** | 本轮自行下载 `codeload.github.com/inbasic/turbo-download-manager/tar.gz/refs/heads/master` 后 `grep -rin "cookie" tdm/*/src/` → **恰好 1 处**：`src/lib/firefox/firefox.js:112: .forceAllowThirdPartyCookie = true;`（配合 `req.channel.QueryInterface(Ci.nsIHttpChannelInternal)`） | 「浏览器内自建下载器的扩展不构造 Cookie 头」成立；也说明「带 cookie」与「自己发多段」在生态里确实分离 |
| B12 | DownThemAll! 4.15.1 的 `Readme.md`/`TODO.md` 官方判定「Segmented downloads — Cannot be done with WebExtensions …」等 | A §B-2/E38/E39、B §B-2/§9.3(35) | **已核实** | <https://raw.githubusercontent.com/downthemall/downthemall/master/Readme.md> L13/L17/L19（*"we cannot do our own downloads any longer but have to go through the browser download manager always"*；*"… doesn't eat all the system memory for breakfast."*）；<https://raw.githubusercontent.com/downthemall/downthemall/master/TODO.md> L30-52：`P4` / *"Stuff that probably cannot be implemented due to WeberEension limitations."*（原文拼写）/ *"Segmented downloads — Cannot be done with WebExtensions - downloads API has no support and manually downloading, storing in temporary add-on storage and reassmbling the downloaded parts later is not only efficient but does not reliabliy work due to storage limitations."*（原文拼写）/ *"Checksums/Hashes? … cannot actually read the downloaded data"* / *"Mirrors? …"*；<https://raw.githubusercontent.com/downthemall/downthemall/master/manifest.json>：`"manifest_version": 2, "version": "4.15.1"` | 「权威否定证据」成立；**附加观察**：TODO 现在还有一条 *"Speed limiter — Cannot be done with the WebExtensions downloads API"*，两份都未提 |
| B13 | Chrono / FDM 商店页口径：Chrono 自认「用 Chrome 内置 Downloads API ⇒ 无多线程、只能在默认下载目录及其子目录」；FDM 需本机安装 + native client | A §B-3/E40、§B-4/E41、B §B-3 | **已核实** | <https://chromewebstore.google.com/detail/chrono-download-manager/mciiogijehkdemklbdcbfkefimifhecn>（页面 HTML 原文命中）：*"Chrono currently uses Chrome™'s built-in Downloads API, so it does not offer multi-threaded downloading capability and has limited support for pausing and resuming a large download."* + *"All downloaded files can only be saved under Chrome™'s default downloads folder or any of its subdirectories."*；<https://chromewebstore.google.com/detail/download-with-free-downlo/jlodlegnpjplclncjkgolcmdhjmlokna>：*"Sends your downloading jobs to the Free Download Manager by pausing the built-in download manager"* + *"For the extension to be able to communicate with FDM, a small native client is required."* | 「浏览器内多连接方案一律把传输外包」成立 |
| B14 | ipull：浏览器默认 `DEFAULT_PARALLEL_STREAMS_FOR_BROWSER = 3`；`headers.range = bytes=start-end-1`；`accept-ranges === "bytes"` 判定；内存合并（`resultAsBlobURL` / `Uint8Array`）；`onWrite(cursor, buffers, options)` | B §B-4 | **已核实** | <https://raw.githubusercontent.com/ido-pluto/ipull/main/src/download/browser-download.ts> L8：`const DEFAULT_PARALLEL_STREAMS_FOR_BROWSER = 3;`；<https://raw.githubusercontent.com/ido-pluto/ipull/main/src/download/download-engine/streams/download-engine-fetch-stream/download-engine-fetch-stream-fetch.ts> L36 `headers.range = \`bytes=${this._startSize}-${this._endSize - 1}\`;`、L100 `const acceptRange = this.options.acceptRangeIsKnown ?? response.headers.get("accept-ranges") === "bytes";`、L90 `"Accept-Encoding": "identity"`、L104 `contentEncoding`；<https://raw.githubusercontent.com/ido-pluto/ipull/main/README.md>：L17 *"Super fast file downloader with multiple connections"*、L52 *"Download a file in the browser using multiple connections"*、L67 `resultAsBlobURL()`、L81 `onWrite: (cursor: number, buffers: Uint8Array[], options) => {` | 「浏览器里 fetch 多段技术上通」成立；「默认 3 路」有源码级证据 |
| B15 | WebTorrent `client.createServer()` 支持 Range、需 `controller: ServiceWorkerRegistration`（*"Required!"*）；`storeCacheSlots` 默认 20；`storeOpts.rootDir` 为浏览器端 `FileSystemDirectoryHandle`；`skipVerify` 反证默认校验 | A §B-5/E42 | **已核实** | <https://raw.githubusercontent.com/webtorrent/webtorrent/master/docs/api.md>：L284-293 *"Create an http server to serve the contents of this torrent, dynamically fetching the needed torrent pieces to satisfy http requests. Range requests are supported."* + `controller: ServiceWorkerRegistration // … Browser only. Required!`；L129 `storeCacheSlots … [default=20]`；L132 `skipVerify`；L161 *"`storeOpts.rootDir` — (browser only) FileSystemDirectoryHandle … allows the user to specify a custom directory to stores the files in"* | 「多分片 + 随机访问 + 落地」的已落地范式成立 |
| B16 | StreamSaver 依赖 MITM service worker 伪造 `Content-Disposition`、页面卸载即断流、SW 会 idle（30s/5min）、需用户交互、只能顺序写；FileSaver 受 Blob 上限（Chrome 2GB / Firefox 800MiB / Android RAM/5）；browser-fs-access 是 ponyfill；native-file-system-adapter 的 `sandbox` 适配器 deprecated | A §B-7/E43、§B-8/E44、B §B-5.3/§B-5.4/§B-5.5 | **已核实** | <https://raw.githubusercontent.com/jimmywarting/StreamSaver.js/master/README.md> L21-24 *"Instead of saving data in client-side storage or in memory you could now actually create a writable stream directly to the file system … This is accomplish by emulating how a server would instruct the browser to save a file using some response header + service worker"*、L83 *"on user interaction** … get around the popup blockers"*、L84 *"(worker goes idle after 30 sec in firefox, 5 minutes in blink)"*、L86 *"**Handle unload event** when user leaves the page. The download gets broken when you leave the page."*、L7 whatwg/fs 会让它们「a bit obsolete」；<https://raw.githubusercontent.com/eligrey/FileSaver.js/master/README.md> L1/L21/L23/L24（Max Blob Size 表）；<https://raw.githubusercontent.com/GoogleChromeLabs/browser-fs-access/main/README.md> L5-6 *"transparent fallback to the `<input type="file">` and `<a download>` legacy methods. This library is a ponyfill."*；<https://raw.githubusercontent.com/jimmywarting/native-file-system-adapter/master/README.md> L23 *"`sandbox` (deprecated): Uses requestFileSystem …"* | 「顺序写路线不能用于乱序回填」成立 |

### 2.3 表 C：多线程 / 落盘 / 并发（14 条）

| # | 断言 | 出处 | 结果 | 证据（URL + 原文/源码摘录） | 影响 |
|---|---|---|---|---|---|
| C01 | FSA `write()` 支持 `position`/`seek`/`truncate`（可任意偏移写用户可见文件）；**`close()` 之前不落盘**（写临时文件）；`showSaveFilePicker()` 需**瞬态用户激活** + 安全上下文 | A §B-9(a)/§C9、B §B-5.1/§C16 | **已核实** | <https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream/write>：*"No changes are written to the actual file on disk until the stream has been closed. Changes are typically written to a temporary file instead."*；*"`position` … Can also be set if type is `"write"`, in which case the write will start at the specified position."*；`NotAllowedError` = *"Thrown if `PermissionStatus.state` is not granted."*；<https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker>：*"Transient user activation is required. The user has to interact with the page or a UI element in order for this feature to work."*；Chromium 策略 <https://chromium.googlesource.com/chromium/src/+/main/components/policy/resources/templates/policy_definitions/Miscellaneous/FileOrDirectoryPickerWithoutGestureAllowedForOrigins.yaml>：*"For security reasons, the showOpenFilePicker(), showSaveFilePicker() and showDirectoryPicker() web APIs require a prior user gesture ("transient activation") to be called or will otherwise fail."* | 「FSA 可随机写、但有手势/临时文件代价」成立；**补充**：`write()` 页标注 *"This feature is available in Web Workers"* ⇒ 写入动作本身可放 Worker，只有 picker 在 `Window`（两份未分开这两件事，见 §6.6） |
| C02 | 用户可见文件路径的写是**非原地写**（临时文件 + 安全校验），大文件性能差 | A §B-9(a)/E10、B §B-5.1 | **已核实** | <https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system>：*"These writes are not in-place, and instead use a temporary file. … As a result, these operations are fairly slow. … the performance suffers when making more significant, large-scale file updates"* | 「FSA 直写大文件慢」成立 |
| C03 | OPFS `createSyncAccessHandle()` **只在 Dedicated Web Worker 可用**、对文件加**独占锁**，`write(buffer, {at})` 支持随机偏移 | A §B-9(b)/§C10、B §B-5.2/§C17 | **已核实** | <https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle/createSyncAccessHandle>：*"Note: This feature is only available in Dedicated Web Workers."* / *"it is only usable inside dedicated Web Workers for files within the origin private file system"* / *"Creating a FileSystemSyncAccessHandle takes an exclusive lock on the file …"*；规范 IDL：<https://fs.spec.whatwg.org/> — `[ Exposed = DedicatedWorker , SecureContext ] interface FileSystemSyncAccessHandle { … write ( AllowSharedBufferSource buffer , optional FileSystemReadWriteOptions options = {} ) … }` 与 `[ Exposed = DedicatedWorker ] Promise < FileSystemSyncAccessHandle > createSyncAccessHandle ();`；Blink：<https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/modules/file_system_access/file_system_file_handle.idl> `Exposed=DedicatedWorker` | 最关键的执行上下文约束成立；MV3 SW 拿不到同步随机写 |
| C04 | OPFS 对用户不可见、受配额限制、清站点数据即删；扩展可用 `"unlimitedStorage"` 豁免 | A §B-9(b)/§C10、B §B-5.2/§C18 | **已核实** | MDN OPFS 页：*"private to the origin of the page and not visible to the user"* / *"The OPFS is not intended to be visible to the user."* / *"The OPFS is subject to browser storage quota restrictions"* / *"Clearing storage data for the site deletes the OPFS."*；<https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies>：*"Request the `"unlimitedStorage"` permission, which affects both extension and web storage APIs and exempts extensions from both quota restrictions and eviction."* | 「下完要整份导出 + 峰值 2× 磁盘」的推论成立 |
| C05 | 「OPFS 在 MV3 service worker 中的可用性」两份都标**未验证**（只看 MDN 的 *"available in Web Workers"*） | A §8.6、B §8.3 | **已核实（规范级，实现级未实测）** | 规范链条：①<https://fs.spec.whatwg.org/> — `[ SecureContext ] partial interface StorageManager { Promise < FileSystemDirectoryHandle > getDirectory (); };` 与 `[ Exposed =( Window , Worker ), SecureContext , Serializable ] interface FileSystemFileHandle … createWritable()`；②<https://storage.spec.whatwg.org/> — `[ SecureContext , Exposed =( Window , Worker )] interface StorageManager { … }`；③`ServiceWorkerGlobalScope` 的 `[Global]` 含 `Worker`：<https://w3c.github.io/ServiceWorker/> — `[ Global =( Worker , ServiceWorker ), Exposed = ServiceWorker , SecureContext ] interface ServiceWorkerGlobalScope : WorkerGlobalScope`（对照 `DedicatedWorkerGlobalScope` 为 `[ Global =( Worker , DedicatedWorker ), Exposed = DedicatedWorker ]`，<https://html.spec.whatwg.org/multipage/workers.html>）；④WebIDL 暴露规则：「*An interface … is exposed in a given realm realm if … realm.[[GlobalObject]] does not implement an interface that is in construct's exposure set, then return false*」，且 `[Global]` 一节说明 *"The global names for the interface are the identifiers that can be used to reference it in the [Exposed] extended attribute. A single name can be shared across multiple different global interfaces … For example, `"Worker"` is used to refer to several distinct types of threading-related global interfaces."*（<https://webidl.spec.whatwg.org/#introduction>、§3.3.7/§3.3.8）⇒ `Worker` ∈ exposure set 且 `Worker` 是 `ServiceWorkerGlobalScope` 的 global name ⇒ **ServiceWorker 隐式继承该暴露** | 「SW 里完全不能碰 OPFS」不成立：**异步**路径按规范可用（`getDirectory()` + `createWritable()`）；**同步句柄仍然只属于 Dedicated Worker**。实现级仍需实测（Chrome 扩展 SW 是否真暴露 `navigator.storage.getDirectory`） |
| C06 | HTTP/1.1 每 host 正常连接上限 **6**（WebSocket 255） | A §C7/E26、B §C13 | **已核实**（需精确化「host/group」） | <https://chromium.googlesource.com/chromium/src/+/main/net/socket/client_socket_pool_manager.cc> L46-58：`// Default to allow up to 6 connections per host.…` + `std::array<size_t, kSocketPoolTypesSize> g_max_sockets_per_group = std::to_array<size_t>({ 6, // kNormal  255 // kWebSocket });`；同文件另有 `g_max_sockets_per_proxy_chain = {128, …}` 与 soft cap | 「同域并发 6」这一常识的源码出处成立；精确化：常量名是 `per_group`（分组的实际键是 host:port + 代理链），另有 per-proxy-chain 上限 128 与软上限 |
| C07 | HTTP/2 单连接多路复用；并发上限由服务端 `SETTINGS_MAX_CONCURRENT_STREAMS` 决定（建议 ≥100）；所有流共享同一 TCP 的流控 | A §C8/E6、B §C14/§9.1(22) | **已核实** | <https://www.rfc-editor.org/rfc/rfc9113.txt> §6.5.2：*"SETTINGS_MAX_CONCURRENT_STREAMS (0x03): This setting indicates the maximum number of concurrent streams that the sender will allow. … It is recommended that this value be no smaller than 100, so as to not unnecessarily limit parallelism."*；§5.2 *"Using streams for multiplexing introduces contention over use of the TCP connection, resulting in blocked streams. … Flow control is used for both individual streams and the connection as a whole."* | 「HTTP/2 下多连接语义变形」成立 |
| C08 | MV3 SW 被终止的条件：空闲 30 秒；单个请求/事件处理超过 **5 分钟**；**`fetch()` 响应超过 30 秒才到达** | B §C21/F13/§9.1(2b)（A 仅经 StreamSaver README 间接提及） | **已核实** | <https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle>：*"Normally, Chrome terminates a service worker when one of the following conditions is met: After 30 seconds of inactivity. Receiving an event or calling an extension API resets this timer. When a single request, such as an event or API call, takes longer than 5 minutes to process. When a fetch() response takes more than 30 seconds to arrive."* | 「长下载循环不能放 SW」成立。**补充**：同页 Chrome 116+ 起「活跃 WebSocket 连接可延长 SW 寿命」、「部分 API 可越过 5 分钟」（见 §6.5） |
| C09 | aria2 语义基线：`--split` 默认 **5**、`--max-connection-per-server` 默认 **1**、`--min-split-size` 规则「不小于 2×SIZE」（默认 20M）、`--header` 可重复 | B §3.0/§9.1(24) | **已核实** | <https://aria2.github.io/manual/en/html/aria2c.html>：`-x, --max-connection-per-server=<NUM>` *"The maximum number of connections to one server for each download. Default: 1"*；`-s, --split=<N>` *"Download a file using N connections. … The number of connections to the same host is restricted by the --max-connection-per-server option. … Default: 5"*；`-k, --min-split-size=<SIZE>` *"aria2 does not split less than 2*SIZE byte range. … Default: 20M"*；`--header=<HEADER>` *"Append HEADER to HTTP request header. You can use this option repeatedly…"* | 「要复现的对象」描述准确 |
| C10 | `chrome.downloads` 的能力边界：默认下载目录下的相对路径、无按 offset 写、无读回数据流、不能设 cookie/referer/UA 等头、不能多连接 | A §B-10/§C11、B §B-5.3/§C2 | **已核实** | <https://developer.chrome.com/docs/extensions/reference/api/downloads>：`filename` *"A file path relative to the Downloads directory to contain the downloaded file … Absolute paths, empty paths, and paths containing back-references ".." will cause an error."*；`canResume` *"True if the download is in progress and paused, or else if it is interrupted and can be resumed starting from where it was interrupted."*；`resume()` *"The request will fail if the download is not active."*（文档**未提** Range/字节范围依赖）；DTA TODO *"cannot actually read the downloaded data"* | 「唯一浏览器自己发+自己写+有真实进度的通路」成立；同时确认 `dir` 语义无法对齐 |
| C11 | 「`chrome.downloads` 发出的请求是否自带目标站点 cookie」两份都标**未验证**（文档无说明） | A §8.3、B §8.2 | **已核实（源码级，方向为「会带」）** | ①`DownloadUrlParameters` 构造函数默认 `credentials_mode_(::network::mojom::CredentialsMode::kInclude)`：<https://chromium.googlesource.com/chromium/src/+/main/components/download/public/common/download_url_parameters.cc> L40；②`chrome.downloads.download()` 的 network traffic annotation 明确声明 `cookies_allowed: YES` / `cookies_store: "user"`：<https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/extensions/api/downloads/downloads_api.cc> L1168-1183（`net::DefineNetworkTrafficAnnotation("downloads_api_run_async", …)`）；③SW 场景下 `download_params->set_initiator(extension()->origin())`（同文件 L1205） | **两份都把这条当未知，实际源码指向「带 cookie」**。但 **SameSite 语义仍未定**（initiator 是扩展 origin ⇒ 跨站；官方 same-site 例外只写「requests from an extension」，未提 downloads），见 §6.1/§6.3 |
| C12 | 「DNR 是否真的不作用于 `chrome.downloads` 发起的请求」两份都只有社区证据、标未验证 | A §8.1/C13/F9、B §C10/F8/§8.12 | **无法核实（维持）** | 唯一直接报告仍是 <https://stackoverflow.com/questions/77932227/chrome-downloads-api-http-requests-are-not-getting-modified-by-declarative-net-request-api>（第三方、0 回答）；本轮额外用 JSON 端点取到 Chromium issue 正文（<https://issues.chromium.org/issues/40256297>，端点 `https://issues.chromium.org/action/issues/40256297`）：其主题是 *"Can't download PDF files from chrome extension by adding `content-disposition` in declarativeNetRequest"*，正文里的规则是 **responseHeaders** + `content-disposition`，**完全没有涉及 `chrome.downloads`** ⇒ 两份把它列为「线索」是合适的，但**不能当作旁证**；DNR 文档只有 *"A declarativeNetRequest only applies to requests that reach the network stack."*（<https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest> L449），并不能推出下载请求不生效 | 附录 A 的前提仍需**实测**；本条是本项目最贵的一条未知 |
| C13 | hls.js 的分片并发度（两份都未给结论：A §8.11、B 未列） | A §8.11 | **无法核实** | 本轮未复核 hls.js 源码（不在核实范围）；MSE 侧结论已核实：<https://developer.mozilla.org/en-US/docs/Web/API/Media_Source_Extensions_API> *"Starting with Chrome 108, MSE features are available in dedicated web workers"*；MSE 只能喂解码器、不能产出任意二进制 | 对「多线程下载」结论无影响 |
| C14 | 「本轮全部为文档/源码级调研，没有任何实测」 | A §8.14、B §8（整体） | **无法核实/自认属实** | 两份文件均无实测记录；本文同样无实测 | 后续详细设计前建议补一轮最小实测（HttpOnly 注入、DNR append 生效范围、DNR×downloads、OPFS 吞吐、`chrome.downloads` cookie/SameSite 行为） |

---

## 3 被证伪的断言及其后果

> 判定口径：按**字面**与一手证据比对。若一条断言「方向对、细节/范围错」，标为「部分证伪」并写明哪半句错。

### 3.1 【共同错误·高危】F-01：`partitionKey: {}` 被两份都描述为「拿分区 cookie」

- 断言原文：
  - A §A-7.1：「`chrome.cookies.getAll({url, storeId})`；再对分区 cookie 单独 `chrome.cookies.getAll({url, storeId, partitionKey: {}})`」
  - B §A-5.1(2)：「还额外查了一次 `partitionKey: {}`（拿分区 cookie，CHIPS）」
- 一手证据：`CookiePartitionKeyCollectionFromApiPartitionKey()`（见 §2.1 A08 的 URL 与摘录）三态语义是：
  1. **不传 `partitionKey`** → `CookiePartitionKeyCollection()` = 空集合 = **只匹配未分区 cookie**（Chrome 文档同款表述：*"By default, all API methods operate on unpartitioned cookies."*）；
  2. **传 `{}`（对象存在、`topLevelSite` 缺省）** → `ContainsAll()` = **匹配所有分区键**（含未分区）；
  3. **传 `{ topLevelSite: "" }`** → 回到空集合 = 只匹配未分区。
- 后果（对本项目）：
  1. Aria2 Explorer 的两次调用**不是互补关系**：第二次是**所有分区键的超集**，第一次被完全覆盖；
  2. `new Map([...cookies, ...partitionedCookies])` 的后写覆盖 → **同名 cookie 取到的是分区版本**，若目标请求实际处在未分区语境，拼出的 `Cookie:` 头与浏览器真发的头**可能不一致**（这正是 Mock 层「入站 header 与实际发出头一致性」要处理的场景，A §F10 提到了现象但归因错了）；
  3. 若后续文档/能力清单照抄「`partitionKey:{}` = 分区 cookie」，会把「读分区 cookie」写成一件需要两次调用 + 去重规则的事，而实际正确写法是「一次 `getAll({url, partitionKey:{}})` 即得全量 + 按需过滤」；
  4. 版本门槛：`partitionKey` 为 Chrome 119+（<https://developer.chrome.com/docs/extensions/reference/api/cookies> L289-292），旧版会抛错——Aria2 Explorer 的 try/catch 正是为此，但两份都把它解释成「拿分区 cookie 的容错」。

### 3.2 【A 单方·中危】F-02：把 webRequest 的「多扩展改头只有最近安装者生效」迁移到 DNR

- 断言原文：A §C12/F8/§7「**多个扩展改同一个头时只有"最近安装的"生效，其余被静默忽略**」（依据 webRequest 页原文）。
- 结果：**该原文只在 webRequest 页成立**；DNR 页明确描述跨扩展的**叠加**语义（追加可继续追加、`set` 之后只允许同扩展低优先级继续追加），只有 block/redirect 才是「选一个」（证据与摘录见 §2.1 A13）。
- 后果：A 的「新增盲区 ②：多扩展改头冲突无通知」作为 **DNR 盲区**不成立；若写进「拦截盲区清单」，会得到一条**虚假盲区**。真正需要写的是：「DNR 规则之间按扩展安装时间 + 规则优先级排序叠加；与其它扩展的规则可能互相追加/覆盖，且没有『你的规则被忽略』的通知机制」——这需要另做验证，本轮不给定论。

### 3.3 【A 单方·中危】F-03：A 的一句话结论「没有 API 能把分片写到用户可见文件的任意偏移」自相矛盾

- 断言原文：A §1「瓶颈在『**没有 API 能把分片写到用户可见文件的任意偏移**』：FSA 的 `FileSystemWritableFileStream` 支持按 `position` 写入 / `seek()` / `truncate()`，但需要 transient user activation、写的是临时文件、`close()` 才落盘」。
- 结果：**同句后半段就推翻了前半段**。一手证据（§2.3 C01）显示：`write({type:"write", position, data})` 就是「按偏移写用户可见文件」，且句柄一旦获得（目录级授权一次），后续写入**不需要每次手势**。
- 后果：只读 §1 的下游读者会得出「多线程在浏览器里根本不可能落地」的过强结论，从而在能力清单里低估 `multithread`（实际是「可做，但要付出：一次目录授权 + 临时文件/非原地写代价 + OPFS 或 FSA 二选一 + 最终导出」）。A 自己在 §5.2 的判断是对的，问题只在 §1 的措辞。

### 3.4 【B 单方·低危】F-04：TDM 磁盘层代码的文件路径引用错误

- 断言原文：B §B-1 来源列表把「磁盘层（扩展构建）」指向 `src/lib/opera/chrome-cm.js`，并在该 URL 下引用 `write: function (file, offset, arr) { … file.createWriter … }`。
- 结果：master 上 `src/lib/opera/chrome-cm.js` 只有 **22 字节**，内容是一行 `../chrome/chrome-cm.js`（构建期 include 占位符，由 gulp 的 `opera-build`/`shadow('opera')` 流程展开）；被引用的实现代码实际位于 `src/lib/chrome/chrome-cm.js`（A §B-1 引用正确）。**结论不受影响**（两处都指向同一段 Chrome App/HTML5 FS 代码）。
- 后果：若后续有人「按 B 的 URL 去读代码」，会读到占位符而误判「TDM 的写盘层不存在/已删」。引用需改为 `src/lib/chrome/chrome-cm.js`（并注明扩展构建期由 `src/lib/opera/chrome-cm.js` 这个 include 桩引用）。

### 3.5 【B 单方·低危】F-05：「`getAll` 路径直接调 `GetAllCookiesFromManager`（无 HttpOnly 过滤）」不完整

- 断言原文：B §A-4/A-5.4「`getAll` 路径直接调 `cookies_helpers::GetAllCookiesFromManager(...)`（对 cookie manager 直接取全部，无 HttpOnly 过滤）」。
- 结果：`cookies_api.cc` L433-441 显示 `getAll` **有 `url` 时走 `GetCookieListFromManager`**（`MakeAllInclusive()`，同样含 HttpOnly），**只有 `url` 为空时**才走 `GetAllCookiesFromManager`。结论（HttpOnly 可读）不变，机制引用需修正。
- 后果：无实质危害；但若后续要复刻「通过 cookie manager 全量枚举」的行为（例如按 storeId 全量导出），必须知道**带 url 与不带 url 是两条代码路径**，反过滤/权限判定点不同。

### 3.6 【A 单方·低危】F-06：TDM `max-segment-size` 写成 50 MBytes

- 断言原文：A §B-1「参数：`min-segment-size`（注释 *"minimum thread size; 50 KBytes"*）、`max-segment-size`（50 MBytes）」。
- 结果：50 MBytes 是 `wget.js` 头注释的写法；**实际默认值是 `100 * 1024 * 1024`**（`config.js` L186），且 A 自己的任务摘要又写「min/max 50KB/100MB」，前后不一致。
- 后果：仅数值细节；若后续照抄「50MB 分片上限」会与真实实现不符。

### 3.7 未被证伪的「高危断言」清单（正能量结论）

以下断言是本项目最容易翻车的地方，本轮**全部核实为真**，可以放心写入能力清单：

1. `Cookie` 是 fetch forbidden header（A01）；
2. `chrome.cookies` 能读 HttpOnly、需 `cookies` + host permissions（A06/A07）；
3. `chrome.downloads.download({headers})` 不能带 `cookie`/`referer`/`user-agent`，但 `range` 不被禁（A04）；
4. DNR `append` 白名单含 `cookie`，分隔符 `"; "`（A09）；
5. `createSyncAccessHandle` 仅 Dedicated Worker + 独占锁 + `{at}` 随机写（C03）；
6. DNR 的 `set`/`remove` 不受 append 白名单约束（但 `set` Cookie 是否生效仍未验证）（A10/A11）。

---

## 4 两份研究共同犯的错

> **本节是交叉验证最值钱的产出**：A/B 由两位研究员独立完成、结论高度一致（这本身说明骨架结论可靠），但也因此**共享了同一批盲区**。以下按严重度排列。

### 4.1 🔴 M-01（共同错误）：`partitionKey: {}` 语义被两份同时误述

- 两份都把它当成「专门取分区 cookie 的第二次调用」，实际源码语义是 `ContainsAll()`（所有分区键，含未分区）。
- 详细证据与后果见 **§3.1**；两份文件里的出现位置：A §A-7.1、A §5.1 表格行「可直接借鉴（几乎照搬）」；B §A-4、B §A-5.1(2)、B §5.1「Aria2 Explorer 的取 cookie 范式可整段照搬」。
- 为什么危险：**它直接进入了两份文件共同推荐的「照搬」清单**。如果后续实现照抄「两次 getAll + Map 去重」，同名分区 cookie 与未分区 cookie 的优先级会被静默倒置，产出与浏览器实际发送行为不一致的 `Cookie` 头——这正好命中本项目 R10「结果兑现」与 Q-B3「伪装自洽」的判据。

### 4.2 🟡 M-02（共同的过度概括）：「MV3 里改请求头只有 DNR 一条路」

- A 明文写「MV3 里改请求头唯一通路是 DNR」（§C4/§5.1）；B 没有写「唯一」，但它的方案框架（A-6.3「活路 1」+ A-6.6「历史路」+ A-6.7「其它可能路径（未验证）」）与 A 相同，最终给用户的可用通路清单也只有 DNR。
- 实际至少两条例外：① **policy installed extensions 仍可用 `webRequestBlocking`**（A 自己引用的原文就写了这句）；② **`chrome.debugger` + CDP `Network.setExtraHTTPHeaders`**（命令存在，B 在 §8.6 列为未验证）。
- 为什么重要：本项目要做「请求头注入」的引擎设计；如果按「唯一通路」做技术选型，会把「DNR 对 `chrome.downloads` 不生效」（尚未证实）变成**无解**。正确表述应是「普通扩展的常规通路是 DNR；另有两条例外/旁路，代价与适用面未验证」。

### 4.3 🟢 M-03（共同的小偏差）：`user-agent` 被当成「fetch 规范里的 forbidden header」

- 两份都把 `user-agent` 列入「fetch 规范禁止的 header」语境（A §C2/E25、B §C2/§9.2(26)）。
- 事实：**fetch 规范当前列表里已经没有 `User-Agent`**；Chromium 保留它是因为历史兼容（源码注释 *"This is no longer banned, but still here due to issues mentioned in https://crbug.com/571722."*）。MDN 亦专门加注说明（见 §2.1 A02）。
- 影响：结论（`chrome.downloads` 不能设 UA）不变；但「forbidden 列表 = fetch 规范」的因果叙述在 `user-agent` 这一条上不成立，写进能力报告会显得论证不严谨。

### 4.4 交叉验证的正面结论

除以上 3 条外，两份文件在**所有被本文抽查的事实性断言上都一致且正确**（39 条已核实，含 8 条「两份都列为未验证/无法核实」的项）。特别值得记录的独立一致性：

- 双方都独立指出了「`chrome.downloads` 无视改头 DNR」**只有社区证据**（A §8.1、B §8.12），并都拒绝把它升级为结论——本轮复核确认这个克制是正确的（§2.3 C12）；
- 双方都独立指出了「第三方 cookie 被拦时扩展 same-site 例外失效」，并都引用了同一句 Chrome 文档原文（§2.1 A15）；
- 双方对 MV3 SW 生命周期的处理不同（A 只在 StreamSaver 一节间接提及，B 用官方文档钉死），B 的处理更完整。

---

## 5 无法核实的断言

> 判定「无法核实」= 本轮**没有在一手证据里找到决定性判据**。以下每条写清「卡在哪里」，以及需要什么才能解决。

### 5.1 🔴 DNR 是否作用于 `chrome.downloads` 发起的请求（A §8.1/C13/F9、B §C10/F8/§8.12）

- 现状：只有一条第三方提问（0 回答，提问者自称用 `chrome://net-export` 验证过）：*"when I try to download a file using chrome's Downloads API, the download request is not getting modified and hence fails. … if I trigger the download from DOM, the request is getting modified properly."*（<https://stackoverflow.com/questions/77932227>）。
- 本轮新增尝试与卡点：①用 issue tracker JSON 端点取到了 <https://issues.chromium.org/issues/40256297> 的正文，但它是 **responseHeaders/content-disposition** 的问题，**不含 downloads API**，不能当旁证；②在 Chromium 源码里尝试沿 `DownloadUrlParameters` → `set_url_loader_factory`（`download_item_impl.cc` L2677-2678 会 `download_params->set_url_loader_factory(url_loader_factory_->Clone())`）追到扩展 webRequest/DNR 的代理工厂，但**未能定位决定性的挂载点**（涉及的 `components/download/internal/common/download_manager_impl.cc` 路径在本轮抓取时未取到正文）。
- 需要什么：一次实测（`chrome.downloads.download()` + DNR `modifyHeaders`，用 `chrome://net-export` 或服务端回显头比对），或在源码里定位 `DownloadURLLoaderFactory` 是否被 `WebRequestProxyingURLLoaderFactory` 包裹。

### 5.2 🟡 DNR `set` 整个 `Cookie` 头是否生效（A §8.8、B §8.1）

- 卡点：官方只给 `append` 白名单；`set` 既无禁止明文也无官方示例；规范/源码只证明「解析期不拦」，**不能证明「运行期会被应用且不被浏览器后续步骤覆盖」**。需要实测。

### 5.3 🟡 `chrome.downloads` 请求的 SameSite 行为（两份都没问，但由 C11 引出）

- 卡点：已核实 `credentials_mode = kInclude` 与 `cookies_allowed: YES`（§2.3 C11），但 Chrome 官方「扩展→第三方被当作 same-site」的例外写在 **Storage and cookies** 页，原文主语是 *"Requests from an extension"*，**未说明是否覆盖 `chrome.downloads` 发起的请求**；SW 场景下 `set_initiator(extension()->origin())` 使请求对目标站是跨站。Lax/Strict cookie 是否随下载发出，需要实测。

### 5.4 🟡 `chrome.downloads.download({url: "blob:…"})` 是否被接受（B §8.4）

- 卡点：B 已标未验证；本轮在 Chrome downloads 文档与 `downloads_api.cc`（只做 `download_url.is_valid()` 校验）里都**没有**找到 blob/data URL 的允许或禁止明文。需要一个实测或源码里 blob URL 解析路径的证据。

### 5.5 🟡 `showSaveFilePicker()`/`showDirectoryPicker()` 在扩展页 / offscreen document 中的行为与句柄跨重启持久化（A §8.5、B §8.5）

- 卡点：MDN 明确 picker 属 `Window` 接口且需瞬态激活；扩展上下文（扩展页/侧栏/offscreen）能否弹、以及 `FileSystemHandle` 存 IndexedDB 后的再授权语义，官方扩展文档未写。需要实测。

### 5.6 🟡 `chrome.debugger` + CDP 改请求头的可行性与代价（B §8.6）

- 卡点：本轮只核实了 CDP 命令存在（`Network.setExtraHTTPHeaders`）与 `chrome.debugger` 文档存在；**未核实**它能否覆盖 `chrome.downloads` 发起的请求、是否触发调试横幅、以及 MV3 下的权限代价。

### 5.7 🟡 范围性/穷尽性主张

| 断言 | 出处 | 卡在哪里 |
|---|---|---|
| 「TDM 是**唯一**真正实现多段的浏览器扩展」 | A §B-1、B §B-1 | 穷尽性主张无法核实（本轮只验证了 TDM/DTA/Chrono/ipull 这 4 个样本） |
| hls.js 的分片并发度 | A §8.11 | 本轮未查 hls.js 源码（MSE 侧结论已核实） |
| AriaNg 等前端是否/如何构造 cookie | A §8.9 | 未抓 AriaNg 源码 |
| Firefox 侧 `declarativeNetRequest` 的 append 白名单是否与 Chrome 一致 | A §8.12 | 只核实了 MDN 的 Chrome 列表 + Firefox 的 `Host` 补充说明（<https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest/ModifyHeaderInfo>），未逐条比对 |
| Safari 行为、Chrome 稳定版号、Chrome for Android | A §8.10/§8.13、B 未覆盖 | 本轮未查 |
| Cookie-Editor 的 manifest 路径（A §A-8「未验证」） | A §A-8 | `/manifest.json`、`/src/manifest.json`、`/interface/manifest.json` 均 404；GitHub contents API 本轮被限流。其 httpOnly 读写代码已核实，manifest 仍未知 |
| 两份文件均无实测 | A §8.14、B 整体 | 自认项；本轮同样无实测 |

---

## 6 两份都没提到、但我认为关键的点

> 这些不是「错」，而是**后续「能力清单」与详细设计会用到、但两份研究没有覆盖**的事实/线索。每条都给证据。

### 6.1 `chrome.downloads` 请求默认带凭据（源码级），这改变了「浏览器自己发」这条路的论证方式

- `components/download/public/common/download_url_parameters.cc` L40：`credentials_mode_(::network::mojom::CredentialsMode::kInclude)`。
- `chrome/browser/extensions/api/downloads/downloads_api.cc` L1168-1183 的 traffic annotation：`policy { cookies_allowed: YES  cookies_store: "user" … }`。
- 两份研究都把「downloads 是否带 cookie」列为未知（A §8.3、B §8.2），因此它们的「附录 A 路线＝让浏览器自己带 cookie」实际上**是在没有证据的情况下成立的前提**。现在这条前提有了源码级支持（但仍需实测 SameSite 细节，见 §5.3）。
- 对设计的意义：如果 `chrome.downloads` 真能带上目标站 cookie，那么「带 Cookie 下载」的最省事路径可能**不需要 DNR、不需要 `cookies` 权限**；反之若 SameSite 过滤掉 Lax/Strict，则「登录态下载」仍需 DNR/导航路线。

### 6.2 DNR `remove` 是官方示例里唯一被点名的 Cookie 操作；`set` 的合并顺序有明文

- 官方 DNR 页示例：*"The following example removes all cookies from both a main frame and any sub frames. `{ … "requestHeaders" : [{ "header" : "cookie" , "operation" : "remove" }] … }`"*，并且跨扩展优先级规则明确（L403-406，见 §2.1 A13）。
- 两份研究都引了白名单，但都没提「`remove` 有官方示例」与「`set` 之后只允许同扩展低优先级 append」——这两条正好是设计「Cookie 注入 vs 覆盖」时的规则边界。

### 6.3 官方 same-site 例外的主语是「Requests from an extension」，导航与 downloads 未被覆盖

- <https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies> L255-259 的原文（见 §2.1 A15）只谈网络请求，且明确排除 `document.cookie`。
- 这意味着：附录 A 的 `chrome.tabs` 导航路线能否带 `SameSite=Strict` cookie，官方文档**没有回答**（A §8.2 已诚实标注，B 也没有回答）；而 `chrome.downloads` 的 initiator 是扩展 origin，是否适用同一例外也未答。建议在实测清单里把「tabs 导航」「downloads 请求」「扩展 SW fetch」三种发起方式各测一遍 SameSite 三态。

### 6.4 DNR 规则可以按 tab 限定（Chrome 92+，session rules）

- <https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest>：`excludedTabIds` *"Chrome 92+ … List of `tabs.Tab.id` which the rule should not match. An ID of `tabs.TAB_ID_NONE` excludes requests which don't originate from a tab. Only supported for session-scoped rules."*（`tabIds` 同区段出现）。
- 两份研究与 `concept-design.md` 附录 A.4.7 都把「DNR 规则是扩展级、对**所有**匹配请求生效」当作事实；实际上**可以用 session rule + tabIds 收窄作用域**（本项目第一版只拦截一条精准 URL，这个手段正好可用）。

### 6.5 MV3 service worker 并非「只能活 30 秒」：Chrome 116+ 有明确的延期机制

- <https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle> L240-257：Chrome 116 *"Active WebSocket connections now extend extension service worker lifetimes. Sending or receiving messages across a WebSocket in an extension service worker resets the service worker's idle timer."*；*"Additional extension APIs are allowed to go past the five-minute timeout period …"*（列出 desktopCapture / identity.launchWebAuthFlow / management.uninstall / permissions.request）；Chrome 118 起 *"Active debugger sessions … keep the service worker alive."*
- 与本项目的关系：Q-D3 已决定 WebSocket 通道要「转发器轮询 Mock 层」；若把长任务的保活寄望于 SW，**WebSocket 活跃是官方认可的保活手段**，而 `offscreen` 文档（<https://developer.chrome.com/docs/extensions/reference/api/offscreen>）明确只有 `AUDIO_PLAYBACK` 会在「无声 30 秒」后关闭，**其它 reason 不设寿命限制** ⇒ 「扩展页/offscreen + dedicated worker」作为长下载宿主在寿命上比 SW 可靠。
- 两份研究只把 SW 生命周期当**纯限制**（B §C21/F13），没有提这些例外与 offscreen 的寿命规则。

### 6.6 FSA 的「随机写」不等于「必须 `Window` + 每次手势」：写入可在 Worker，只有 picker 需要手势

- <https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream/write> 页顶：*"Note: This feature is available in Web Workers."*；`FileSystemFileHandle` 是 `[Exposed=(Window,Worker)]`（<https://fs.spec.whatwg.org/>）。
- 因此正确的拆分是：**授权（picker）**需要 `Window` + 瞬态激活；**写入（createWritable/write/seek）**可以在 dedicated worker 里做（只要拿到 handle）。
- 两份研究把 FSA 整体描述成「需要用户手势」的 Windows-only 路径（A §C9、B §B-5.1），会让设计者错过「授权一次目录 → 把分片写入放 worker」的组合。

### 6.7 OPFS 也有异步随机写（`createWritable` + `position`），不只有同步句柄

- OPFS 页的「主线程」用法就是 `FileSystemFileHandle.createWritable()` + `write()`（MDN OPFS 页 L154-158 描述用户可见文件的差异；`createWritable` 本身对 OPFS 句柄同样可用，规范 IDL `[Exposed=(Window,Worker)]`）。
- 两份研究都把「OPFS 随机写」与 `createSyncAccessHandle`（Dedicated Worker）绑定（A §B-9(b)、B §B-5.2、B §6 路线表只列 sync handle），只在 FSA 一行提 `createWritable`。
- 对设计的意义：**Service Worker 里也能用 OPFS 的异步路径做带偏移写入**（性能不如 sync handle），这给「引擎执行体到底放哪」多了一个自由度；是否需要 dedicated worker 应由吞吐/并发压测决定，而不是由 API 存在性决定。

### 6.8 `chrome.downloads` 的 `saveAs` 是「落盘位置不可控」的官方逃生口

- <https://developer.chrome.com/docs/extensions/reference/api/downloads>：`saveAs` *"Use a file-chooser to allow the user to select a filename regardless of whether filename is set or already exists."*
- 两份研究都把「downloads 只能在默认下载目录及子目录」当作硬结论（A §C11/F18、B §B-5.3 引 Chrono）。**准确说法**是：不弹选择器时只能写默认目录的相对路径；`saveAs: true` 可以（但需用户交互/选择器，与 aria2 的 `dir` 语义仍无法对齐）。

### 6.9 6 连接的「精确语义」

- 常量名 `g_max_sockets_per_group`，注释 *"Default to allow up to 6 connections per host"*（<https://chromium.googlesource.com/chromium/src/+/main/net/socket/client_socket_pool_manager.cc> L46-58），同文件另有 `g_max_sockets_per_proxy_chain = {128, …}`（L62-65）与 per-pool 软上限（L151-155）。
- 两份研究写作「同域并发 6」在实践上够用，但能力清单里若要用它推导「分片数上限 = 6」，需注意分组键是 host:port（+ 代理链）而非「域」，且 HTTP/2 场景下这条限制根本不参与。

---

## 7 证据清单

> 按「本文件用它证明了什么」分组。所有 URL 均在 2026-10-06 由本轮抓取（Chromium 为 `main` 分支未固定 commit；线上文档为当日最新版）。

### 7.1 规范

| URL | 用于 |
|---|---|
| <https://fetch.spec.whatwg.org/#forbidden-header-name> | A01 `Cookie` forbidden；A02 `User-Agent` 已不在列 |
| <https://fetch.spec.whatwg.org/#cors-safelisted-request-header> | A03 `Range` CORS-safelisted / privileged no-CORS |
| <https://www.rfc-editor.org/rfc/rfc9113.txt> | C07 HTTP/2 并发流与流控（§5.2、§6.5.2） |
| <https://fs.spec.whatwg.org/> | C03/C05 `createSyncAccessHandle` `[Exposed=DedicatedWorker]`；`StorageManager.getDirectory()` partial interface；`FileSystemFileHandle` `[Exposed=(Window,Worker)]` |
| <https://storage.spec.whatwg.org/> | C05 `StorageManager` `[Exposed=(Window,Worker)]` |
| <https://w3c.github.io/ServiceWorker/> | C05 `ServiceWorkerGlobalScope` `[Global=(Worker,ServiceWorker)]` |
| <https://html.spec.whatwg.org/multipage/workers.html> | C05 `DedicatedWorkerGlobalScope` `[Global=(Worker,DedicatedWorker)]` |
| <https://webidl.spec.whatwg.org/>（§3.3.7 `[Exposed]`、§3.3.8 `[Global]`、暴露判定步骤） | C05：`realm.[[GlobalObject]]` 实现接口的 global name 落在 exposure set 内即暴露；`"Worker"` 是多个 worker 全局接口共享的 global name |
| <https://aria2.github.io/manual/en/html/aria2c.html> | C09 aria2 `split`/`max-connection-per-server`/`min-split-size`/`header` 原文 |

### 7.2 MDN

| URL | 用于 |
|---|---|
| <https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header> | A01；A02 User-Agent 注 |
| <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cookie> | A01 字段表「Forbidden request header — Yes」 |
| <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Range> | A03 单区间 safelisted / 非 forbidden / 服务器可忽略 |
| <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie> | A16 SameSite=Lax 排除 fetch；HttpOnly 仍随 JS 请求发送 |
| <https://developer.mozilla.org/en-US/docs/Web/API/RequestInit> | A16 credentials 默认值与 ACAC 要求 |
| <https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker> | C01 瞬态用户激活 / Secure context |
| <https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream/write> | C01 position 写 / close 才落盘 / NotAllowedError / 可用在 Web Workers |
| <https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle/createSyncAccessHandle> | C03 Dedicated Worker / 独占锁 |
| <https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system> | C02/C04 非原地写慢 / 不可见 / 配额 / 清数据即删 |
| <https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/downloads/download> | A05 Firefox 侧 header 限制措辞 |
| <https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest/ModifyHeaderInfo> | A09/A11 append 列表与 Firefox 差异 |
| <https://developer.mozilla.org/en-US/docs/Web/API/Media_Source_Extensions_API> | C13 MSE 结论与 Chrome 108 worker |

### 7.3 Chrome 官方文档

| URL | 用于 |
|---|---|
| <https://developer.chrome.com/docs/extensions/reference/api/cookies> | A06 权限；A07 `httpOnly` 字段；A08 未分区默认；`partitionKey` Chrome 119+；A17 Chrome 148 `browser.*` |
| <https://developer.chrome.com/docs/extensions/reference/api/downloads> | A05 headers 口径；C10 `filename`/`canResume`/`resume`；§6.8 `saveAs` |
| <https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest> | A09 append 白名单 + 分隔符；A10 说明；A13 跨扩展叠加；C12「只作用于到达网络栈的请求」；§6.4 `tabIds`/`excludedTabIds`；规则上限 5000 |
| <https://developer.chrome.com/docs/extensions/reference/api/webRequest> | A12 MV3 `webRequestBlocking`；A13 webRequest「最近安装者胜」原文 |
| <https://developer.chrome.com/docs/extensions/mv2/reference/webRequest> | A12 MV2 `extraHeaders` + Cookie |
| <https://developer.chrome.com/docs/extensions/reference/api/offscreen> | §6.5 offscreen 寿命规则 |
| <https://developer.chrome.com/docs/extensions/reference/api/debugger> | A14 例外通路的 API 存在性 |
| <https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies> | A15 same-site 例外 / 3PC / `document.cookie`；C04 `unlimitedStorage`；§6.3 主语范围 |
| <https://developer.chrome.com/docs/extensions/develop/concepts/network-requests> | A15 内容脚本跨源 / 扩展 host permissions |
| <https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle> | C08 SW 终止条件；§6.5 Chrome 116+ 延期机制 |
| <https://developer.chrome.com/docs/extensions/develop/migrate/improve-security> | B16 MV3 禁止远程代码（worker 必须打包） |

### 7.4 Chromium 源码

| URL | 用于 |
|---|---|
| <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/cookies/cookies_helpers.cc> | A07 `MakeAllInclusive()` / 两条 getAll 路径；**A08 `CookiePartitionKeyCollectionFromApiPartitionKey`** |
| <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/cookies/cookies_api.cc> | A07 `set_include_httponly()`；A08 getAll 分支 |
| <https://chromium.googlesource.com/chromium/src/+/main/net/cookies/cookie_options.h> | A07 `MakeAllInclusive` 注释 / 默认 `exclude_httponly_ = true` |
| <https://chromium.googlesource.com/chromium/src/+/main/net/cookies/cookie_partition_key_collection.h> | A08 `ContainsAllKeys()` / 默认「匹配所有键」注释 |
| <https://chromium.googlesource.com/chromium/src/+/main/net/cookies/cookie_partition_key_collection.cc> | A08 默认构造 = 空集合；`Contains()` 实现 |
| <https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/extensions/api/downloads/downloads_api.cc> | A04 header 校验；A12 MV2 对比；**C11 traffic annotation `cookies_allowed: YES`** 与 `set_initiator` |
| <https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/extensions/api/downloads/download_extension_errors.h> | A04 错误串 |
| <https://chromium.googlesource.com/chromium/src/+/main/net/http/http_util.cc> | A04 `kForbiddenHeaderFields` / `IsSafeHeader`；A02 user-agent 注释 |
| <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/declarative_net_request/constants.h> | A09 `{"cookie", "; "}` |
| <https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/api/declarative_net_request/indexed_rule.cc> | A10 仅 append 查白名单 |
| <https://chromium.googlesource.com/chromium/src/+/main/net/socket/client_socket_pool_manager.cc> | C06 6/255 与 per-proxy-chain 128 |
| <https://chromium.googlesource.com/chromium/src/+/main/components/download/public/common/download_url_parameters.cc> | C11 `credentials_mode_ = kInclude` 默认 |
| <https://chromium.googlesource.com/chromium/src/+/main/components/download/public/common/download_url_parameters.h> | C11 / §5.1 `set_url_loader_factory`、`set_initiator`、`credentials_mode` |
| <https://chromium.googlesource.com/chromium/src/+/main/components/download/internal/common/download_item_impl.cc> | §5.1 `SetURLLoaderFactory`（L946-948）与 `download_params->set_url_loader_factory(...)`（L2677-2678） |
| <https://chromium.googlesource.com/chromium/src/+/main/content/browser/renderer_host/render_frame_host_impl.cc> | §5.1 `CreateDownloadUrlParameters` 与 PendingSharedURLLoaderFactory 线索 |
| <https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/modules/file_system_access/file_system_file_handle.idl> | C03 `Exposed=DedicatedWorker`（Blink 侧） |
| <https://chromium.googlesource.com/chromium/src/+/main/components/policy/resources/templates/policy_definitions/Miscellaneous/FileOrDirectoryPickerWithoutGestureAllowedForOrigins.yaml> | C01 picker 需瞬态激活（企业策略原文） |

### 7.5 开源项目 / 商店页 / 第三方

| URL | 用于 |
|---|---|
| <https://raw.githubusercontent.com/alexhua/Aria2-Explorer/master/{manifest.json,background.js,_locales/en/messages.json}> | B01/B02/B03（A-7.1 全部细节） |
| <https://raw.githubusercontent.com/alexhua/Aria2-for-chrome/master/{manifest.json,background.js}> | B05 |
| <https://raw.githubusercontent.com/acgotaku/YAAW-for-Chrome/master/{manifest.json,background.js}> | B04（含 `Authorization`） |
| <https://raw.githubusercontent.com/kairi003/Get-cookies.txt-LOCALLY/master/src/{manifest.json,modules/cookie_format.mjs}> | B06 |
| <https://raw.githubusercontent.com/Moustachauve/cookie-editor/master/interface/{popup/cookie-list.js,options/options.html}> | B07（manifest 未定位） |
| <https://raw.githubusercontent.com/inbasic/turbo-download-manager/master/src/{lib/wget.js,lib/config.js,lib/chrome/chrome-cm.js,lib/io.js,lib/firefox/firefox.js,manifest-extension.json}> + <https://codeload.github.com/inbasic/turbo-download-manager/tar.gz/refs/heads/master> | B08/B09/B10/B11（含全仓 `grep -rin cookie` 唯一命中） |
| <https://raw.githubusercontent.com/downthemall/downthemall/master/{Readme.md,TODO.md,manifest.json}> | B12 |
| <https://raw.githubusercontent.com/ido-pluto/ipull/main/{README.md,src/download/browser-download.ts,src/download/download-engine/streams/download-engine-fetch-stream/download-engine-fetch-stream-fetch.ts}> | B14 |
| <https://raw.githubusercontent.com/webtorrent/webtorrent/master/docs/api.md> | B15 |
| <https://raw.githubusercontent.com/jimmywarting/StreamSaver.js/master/README.md>；<https://raw.githubusercontent.com/eligrey/FileSaver.js/master/README.md>；<https://raw.githubusercontent.com/GoogleChromeLabs/browser-fs-access/main/README.md>；<https://raw.githubusercontent.com/jimmywarting/native-file-system-adapter/master/README.md> | B16 |
| <https://chromewebstore.google.com/detail/turbo-download-manager-cl/kemfccojgjoilhfmcblgimbggikekjip>；<https://chromewebstore.google.com/detail/chrono-download-manager/mciiogijehkdemklbdcbfkefimifhecn>；<https://chromewebstore.google.com/detail/download-with-free-downlo/jlodlegnpjplclncjkgolcmdhjmlokna> | B10/B13 商店页原文 |
| <https://api.github.com/repos/{inbasic/turbo-download-manager,alexhua/Aria2-Explorer,acgotaku/YAAW-for-Chrome,downthemall/downthemall,ido-pluto/ipull,kairi003/Get-cookies.txt-LOCALLY,Moustachauve/cookie-editor}/commits?per_page=1> | 各仓库最后提交时间（TDM = 2017-02-21；Aria2-Explorer = 2026-10-06；YAAW = 2026-06-13；DTA = 2026-05-27；ipull = 2025-05-28；Get-cookies = 2025-10-05；Cookie-Editor = 2026-08-14） |
| <https://stackoverflow.com/questions/77932227>（正文经 `https://stackoverflow.com/feeds/question/77932227` 可取） | C12 DNR×downloads 的唯一第三方报告 |
| <https://issues.chromium.org/issues/40256297>（正文经 `https://issues.chromium.org/action/issues/40256297` 获取） | C12：确认该 issue 与 downloads API 无关 |
| <https://chromedevtools.github.io/devtools-protocol/tot/Network/> | A14 `Network.setExtraHTTPHeaders` 存在 |

### 7.6 本项目内部依据（只读引用）

| URL/路径 | 用于 |
|---|---|
| `/workspace/docs/concept-design/concept-design.md` v0.5（R1–R13、§5.2、§6、附录 A） | 判定「影响」时的上位约束（尤其 R10 结果兑现、Q-B3 伪装自洽、Q-B7 进度、Q-D2/D3/D5、附录 A 的「downloads 无视改头 DNR」前提） |
| `/workspace/docs/research/prior-art/needs-A-cookie-multithread.md` | 被核实断言出处（§2 表内「A §x」） |
| `/workspace/docs/research/prior-art/needs-B-cookie-multithread.md` | 被核实断言出处（§2 表内「B §x」） |

---

*报告结束。凡本文与 A/B 两份文件的判断冲突处，请以本文 §2 各表给出的 URL 原文与源码行号为准；凡本文标「无法核实」的项，请勿在后续能力清单/详细设计里当作事实使用。*
