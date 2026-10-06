# 对照总结：带 Cookie 下载 / 多线程下载（t12 vs t13 合并结论）

> 本文件是 `aria2-in-browser` 项目「浏览器技术边界测绘」的**合并输入文档**：把两名研究员**各自独立**完成的同一题目（`needs-A-…` / `needs-B-…`）逐条对照后，给出**一份**可以直接喂给后续「能力清单」与详细设计的结论。
>
> **本轮做的不只是"合并"**：对所有**分歧点**、以及所有**决定结论的关键证据**，都回到官方文档 / 源码原文重新核验了一遍（核验明细见 §7.1）。核验中发现**两份报告都判为"未验证"的一处关键事实其实有官方明文**（`chrome.downloads` 自带 cookie，见 §3-D1），也发现**三处具体事实分歧**（TDM 分片参数、TDM 写盘文件出处、Chrono 证据可用性）可以定案。
>
> 本文件只写自身；不修改代码、不修改 `docs/concept-design/concept-design.md`、不修改两位研究员的报告。

---

## 0 元信息

| 项 | 值 |
|---|---|
| 文档 | `/workspace/docs/research/prior-art/needs-cookie-consolidated.md` |
| 任务 | t18「对照总结：带 Cookie 下载 / 多线程下载（t12 vs t13）」 |
| 日期 | **2026-10-06**（UTC） |
| 作者 | `sum-cookie-diff` |
| 输入 A（t12） | `needs-A-cookie-multithread.md`，515 行 / ~93 KB，调研人 `prior-cookie-a` |
| 输入 B（t13） | `needs-B-cookie-multithread.md`，953 行 / ~99.5 KB，调研人 `prior-cookie-b` |
| 上游裁定 | `docs/concept-design/concept-design.md` v0.5（R1–R13、§5.2、§6、附录 A） |
| 适用对象 | Chrome / Chromium **Manifest V3**（与两份报告一致；Firefox 仅作对照，Safari 未覆盖） |
| 方法 | ① 逐条对齐两份报告的结论、证据与"未验证"清单；② 对**分歧点 / 关键证据 / 共同依赖的硬结论**回源核验：Chromium 源码（`chromium.googlesource.com` + `?format=TEXT`，base64 解码后 grep）、Chrome for Developers 文档、MDN、GitHub raw 源码、Chrome Web Store 页面、aria2 官方手册 |
| 本轮核验量 | Chromium 源码 **8** 个文件、Chrome 官方文档 **6** 页、MDN **5** 页、开源项目 **6** 个、商店页 **1** 张、aria2 手册 **1** 页（逐条见 §7.1） |
| 未做 | **任何浏览器内实测**（两份报告同样没有）；未逐一复核两份报告的全部 61 / 122 条 URL；Chromium 引用基于 `main` 在线版（**未固定 commit**，行号为 2026-10-06 抓取时所见） |
| 强度标注约定 | 【官方文档】【源码】【成熟实现】= 本轮亲自核到的证据；【继承】= 采信两份报告之一但本轮未独立复核；**【未验证】** = 两份都没有官方/源码证据，或本轮复核后仍无定论 |

---

## 1 合并结论（两个需求各一句）

**需求 A（带 Cookie 下载）**：成熟解法是"**把 cookie 读出来、交给浏览器之外的东西去发**"（Aria2 Explorer 2.8.3 / YAAW-for-Chrome 1.0.0 用 `chrome.cookies.getAll({url,storeId,partitionKey})` 读含 HttpOnly 的 cookie，拼成 `Cookie: k=v; …` 塞进 `aria2.addUri` 的 `header` 选项交给外部 aria2c）；本项目必须"**在浏览器内落地**"，合并后可行通路只有三条 —— ①**让浏览器自己带**（`chrome.downloads.download()` 的官方文档明文"请求会包含该 hostname 当前设置的全部 cookie"，`chrome.tabs` 导航 + 原生下载流同理，且无需 `cookies` 权限）；②**扩展上下文 `fetch(…, {credentials:'include'})`**（有目标 host 权限时扩展对第三方的请求被当作 same-site，Chrome 官方明文，连 `SameSite=Strict` 都可能带上）；③**`chrome.cookies` 读值 + DNR `modifyHeaders` 注入**（`append` 的官方白名单明文含 `cookie`、分隔符 `"; "` 有源码证据，是**唯一能自定义 Cookie 值**的浏览器内通路，但 `set` 的运行时生效未验证）；而"自己写 `Cookie` 头"的两条路（`fetch` 手写头、`chrome.downloads.download({headers})`）分别被 Fetch 规范与 Chromium 源码**钉死**。

**需求 B（多线程下载）**：扩展生态里**没有可用的现成多线程引擎**（Turbo Download Manager 2017-02-21 停更、磁盘层依赖 Chrome App 的 `chrome.fileSystem`；DownThemAll 官方 TODO 判定 *"Segmented downloads — Cannot be done with WebExtensions"*；Chrono 商店页自认 *"does not offer multi-threaded downloading capability"*），但"自建多段"**技术上可行**：`fetch` + `Range` 并发 → **随机偏移写盘**（OPFS `createSyncAccessHandle().write(buf,{at})` 仅 dedicated worker 且对用户不可见；或 FSA `write({position})` 需瞬态用户激活、`close()` 前不落盘）；**aria2 的 `split` / `max-connection-per-server` 语义无法原样复现**（HTTP/1.1 同 host 6 连接、HTTP/2 单连接多路复用、服务器可忽略 `Range`、浏览器里无"多服务器分片"概念），且 **MV3 service worker 会被"空闲 30 秒 / 单请求 >5 分钟 / `fetch()` 响应 >30 秒未到达"终止** ⇒ 引擎的长下载循环必须放在扩展页 / offscreen 文档 + dedicated worker 里。

---

## 2 逐条对照表

> 「是否一致」取值：**一致** = 结论与理由基本相同；**一致（互补）** = 结论相同、证据或覆盖面互补；**表述差异** = 实质相同但一方表述过宽/过窄；**分歧** = 至少有一处不能同时成立（详见 §3）。

| # | 议题 | A 的结论 | B 的结论 | 是否一致 | 合并裁定 + 依据 |
|---|---|---|---|---|---|
| 1 | **带 Cookie 下载的可行途径（浏览器内）** | 三条：① DNR `modifyHeaders`（唯一能自定义 Cookie 头的浏览器内通路）② 让浏览器自己发（`chrome.tabs` 导航/原生下载流）③ 扩展 SW `fetch(credentials:'include')` | 三条，同一集合（① SW fetch ② DNR ③ 让浏览器自己发=附录 A） | **一致** | 合并为三条活路，无遗漏；另加"浏览器自己发"家族里的 **`chrome.downloads` 自带 cookie**（§3-D1，官方明文）。【官方文档】<https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies>；<https://developer.chrome.com/docs/extensions/reference/api/downloads> |
| 2 | **`Cookie` 无法用 fetch 设置 → 怎么绕** | `Cookie` 是 Fetch 规范 forbidden request-header，"任何用 fetch 手动加 Cookie 头的方案都不可能成立"；绕法只有"让浏览器自己挑 cookie"或"用 DNR 注入" | 同；并补 MDN `Cookie` 页字段表 `Forbidden request header: Yes`，点明"不能设 `Cookie` 头 ≠ 不能带 cookie" | **一致（互补）** | B 的第 2 句是关键澄清：**带 cookie 的合法姿势是"不写 Cookie 头"**。【规范】<https://fetch.spec.whatwg.org/#forbidden-header-name>；【官方文档】<https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header> |
| 3 | **`chrome.downloads.download({headers})` 的支持范围** | 经 `net::HttpUtil::IsSafeHeader` 校验，`kForbiddenHeaderFields` 含 cookie/referer/user-agent；`Range` **不在**名单里（但下载器是否 honor 未验证） | 同样是 forbidden 那一批被拒；补错误串 `"Unsafe request header name"`；并指出请求 initiator 是扩展 origin、`set_do_not_prompt_for_login(true)` | **一致（互补）** | 本轮核到源码：`downloads_api.cc` L1222-1237 依次 `IsValidHeaderName` → `IsSafeHeader` → `IsValidHeaderValue`；`http_util.cc` L411-436 的 `kForbiddenHeaderFields` **确无 `range`**；`download_extension_errors.h` L23 `kInvalidHeaderUnsafe[] = "Unsafe request header name"`。【源码】见 §7.1 |
| 4 | **`chrome.cookies` 能否读 HttpOnly** | **能**。源码：`cookies_helpers.cc` 的 `GetCookieListFromManager()` 用 `net::CookieOptions::MakeAllInclusive()`（注释 "including HttpOnly and SameSite cookies"） | **能**。源码：`cookies_api.cc` 的 `getAll` 走 `GetAllCookiesFromManager(...)`（无 HttpOnly 过滤）；`set` 路径 `options.set_include_httponly()`；另有成熟扩展全量拼接作行为旁证 | **一致（互补）** | 本轮核到两条源码路径**都成立但适用分支不同**：`getAll` 带 `url` 时走 `GetCookieListFromManager`（`MakeAllInclusive`），不带 `url` 时走 `GetAllCookiesFromManager`（`GetAllCookies`）⇒ Aria2 Explorer 的 `getAll({url})` 正是 A 描述的路径。详见 §3-D6。【源码】`cookies_api.cc` L434/L438、`cookies_helpers.cc` L175-193 |
| 5 | **`chrome.cookies` 的权限与查询模型** | `"cookies"` 权限 + 目标 host 权限；`storeId` 区分隐身；分区 cookie 需 `partitionKey`（Chrome 119+），Aria2 Explorer 用 try/catch 容错 | 同；并强调 `partitionKey`/`storeId` 漏查会拿错/漏 cookie（CHIPS） | **一致** | 官方文档原文已核："To use the cookies API, declare the `"cookies"` permission in your manifest along with host permissions for any hosts whose cookies you want to access."、"This method only retrieves cookies for domains that the extension has host permissions to."【官方文档】<https://developer.chrome.com/docs/extensions/reference/api/cookies> |
| 6 | **读到的 cookie 怎么塞进请求（三条活路的具体做法）** | 路由 1 DNR（append 白名单含 `cookie`、分隔符 `"; "`）；路由 2 `chrome.downloads({headers})`= 死路；路由 3 让浏览器自己发 | 活路 1 DNR append；活路 2 SW `fetch(credentials:'include')`；活路 3 导航/原生下载流；死路 1/2 同 | **一致** | 同一集合。补充：`fetch(credentials:'include')` 的"必须显式 include + 有 host 权限才算 same-site"是**由两条官方规则拼出的组合结论**（B 自己标注为"由官方规则推导"，A 未标注）——合并后按 B 的标注口径采用。【官方文档】storage-and-cookies + <https://developer.mozilla.org/en-US/docs/Web/API/Request/credentials> |
| 7 | **DNR 的 append 白名单 / 分隔符 / `set` 与 `remove`** | append 白名单含 `cookie`，分隔符源码为 `"; "`；**只有 append 受白名单约束**（`indexed_rule.cc` 仅在 `kAppend` 时校验，规则装不上会报 `ERROR_APPEND_INVALID_REQUEST_HEADER`）；`set` 的实际生效未验证 | append 白名单含 `cookie`（官方明文），`set` **无禁止明文也无官方示例** → 必须实测；DNR 改头发生在浏览器附加 cookie 之后的发送前阶段 | **一致（互补）** | 本轮同时核到：`constants.h` 的 `kDNRRequestHeaderAppendAllowList` 里 `{"cookie", "; "}`、`{"range", ", "}`、`{"user-agent", " "}`；`indexed_rule.cc` 的白名单检查带 `are_request_headers && operation == kAppend` 前置条件 ⇒ **A 的"仅 append 受限"成立**，B 的"set 未验证"也成立（安装 vs 生效是两件事，见 §3-D7）。【源码】【官方文档】见 §7.1 |
| 8 | **`chrome.downloads` 自己发请求时带不带 cookie** | 未验证，推测走 profile cookie store（§8.3） | 未验证；只从源码看到 initiator 是扩展 origin、`set_do_not_prompt_for_login(true)`（§8.2） | **两份均为"未验证" → 本轮定案为"带"** | **官方明文**：`download()` 条目写 "Download a URL. **If the URL uses the HTTP[S] protocol, then the request will include all cookies currently set for its hostname.**" ⇒ 两处"未验证"可撤销。残余未知：HttpOnly/分区/`SameSite=Strict` 是否同样覆盖（文档未细分）。见 §3-D1。【官方文档】<https://developer.chrome.com/docs/extensions/reference/api/downloads> |
| 9 | **把下载转交外部 aria2 的扩展：现成做法** | Aria2 Explorer 2.8.3（MV3）与 YAAW-for-Chrome 1.0.0（MV3）**同一范式**：`chrome.cookies.getAll({url,storeId})`（+`partitionKey:{}` 容错）→ `Map` 去重 → `"Cookie: " + join("; ")` → `aria2.addUri(url, {header:[…]})`；Aria2 for Chrome 同代码 | 同两个项目，逐段贴源码；另外把 `Aria2 Integration`（仓库无源码）与 cookie 导出扩展 `Get cookies.txt LOCALLY` 分别标为 `[未验证]` / 旁证 | **一致（互补）** | 本轮抽验 Aria2 Explorer `background.js` L110-126、L143-169 与 YAAW `background.js` L114-126，**代码与两份报告的引用逐字一致**；manifest 亦核到 MV3 / 2.8.3 / `cookies`+`<all_urls>`。B 对 Aria2 Integration 的降级处理（不当同等强度证据）正确。【源码】见 §7.1 |
| 10 | **多线程下载的可行性（基调）** | "aria2 的 split/max-connection-per-server 基本**复现不了**"；自建需要一整套前置（Range 并发 + 随机写盘 + 自导出） | "扩展里**没有现成的**多线程引擎，但结论**不是不可能**"；给了 ipull 作为浏览器端多段的实现证据 | **表述差异（非事实分歧）** | 两者在说两件事：**"复现 aria2 语义"不可行**（A 对）与**"做多段下载"可行但有硬代价**（B 对）。合并口径：*自建多段技术上可行；aria2 语义不可原样复现*。依据：MDN OPFS/FSA + TDM 分片骨架 + ipull（`DEFAULT_PARALLEL_STREAMS_FOR_BROWSER = 3`）+ DTA/Chrono 的否定结论。【源码】【官方文档】见 §7.1、§3-D8 |
| 11 | **现成多线程引擎与官方否定证据** | TDM（分片骨架可借鉴、磁盘层已死）；DTA TODO "Cannot be done with WebExtensions"；Chrono 商店页原文；FDM 类需本机程序 + native client | TDM（唯一真多段，2017 停更）；DTA；**Chrono 标为 [未验证]（未取到页面原文）** | **唯一分歧是 Chrono 证据**（其余一致） | 本轮用 curl 取 Chrono 商店页 HTML，**命中原文** *"Chrono currently uses Chrome™'s built-in Downloads API, so it does not offer multi-threaded downloading capability…"* ⇒ **A 的证据成立，B 的"未验证"是抓取限制**。见 §3-D2。【商店页】见 §7.1 |
| 12 | **分片前置条件与 206 / 降级** | TDM 三条件（有长度 + 无 `Content-Encoding` + `Accept-Ranges: bytes`），非 206 直接抛错；服务器不支持 Range 则退化单流 | 同（TDM 源码 + ipull 的探测与 `accept-ranges` 判定）；补 MDN：服务器**可以忽略 Range** 返回 200；有内容编码时 byte range 是"编码后字节" | **一致（互补）** | 合并为"**多段可用性的三前提 + 一条降级规则**"：不满足即单流，且必须显式处理"服务器返回 200"的情形（否则数据错位/重复）。B 的 MDN 补充比 A 的源码单点更完整。【源码】【官方文档】<https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Range> |
| 13 | **TDM 关键参数（线程数 / 最小最大分片）** | 默认 3 线程；min 50 KB；**max 50 MBytes**（引 `wget.js` 文件头注释） | 默认 3 线程（`config.defineInt('wget.threads', 3)`）；min 50 KB；**max 100 MB**（引 `config.js` 与 `wget.js` 的 `\|\| 100*1024*1024`） | **分歧（数值）** | 回源定案：`wget.js` **注释** L21-22 写 50 KBytes / **50 MBytes**，但**代码** L461 是 `\|\| 100 * 1024 * 1024`，且 `config.js` L186 `config.defineInt('wget.max-segment-size', 100 * 1024 * 1024, 100 * 1024)` ⇒ **运行时默认 100 MiB，B 正确**；A 引的是过期注释。见 §3-D3。【源码】见 §7.1 |
| 14 | **TDM 写盘实现与构建形态（文件出处）** | 写盘=按 offset：`src/lib/chrome/chrome-cm.js`（`file.createWriter`+`seek`/`write`）；`external()` 用 Chrome App 的 `chrome.fileSystem`，`internal()` 用 `webkitTemporaryStorage`+`requestFileSystem`；扩展清单 `src/manifest-extension.json` 是 MV2 且**无 `fileSystem` 权限** | 写盘=`src/lib/opera/chrome-cm.js`；Chrome App 构建=`src/lib/chrome/chrome-cm.js` | **表述差异** | `src/lib/opera/chrome-cm.js` 的内容**只有一行** `../chrome/chrome-cm.js`（构建 include，本轮 HTTP 200 核到），扩展 manifest 的 `background.scripts` 加载的正是这一份 ⇒ 两者指向**同一个实现体**；A 引的是代码正文，B 引的是构建入口。合并后统一以 `src/lib/chrome/chrome-cm.js` 为代码出处，并保留 A 的"扩展形态很可能拿不到文件句柄"结论（见 §3-D4）。【源码】见 §7.1 |
| 15 | **多线程结果的合并与落盘途径** | OPFS `createSyncAccessHandle({at})`（性能好、仅 Dedicated Worker、独占锁、对用户不可见、需整份导出、需 `unlimitedStorage`）**或** FSA `createWritable`+`write({position})`（用户可见、需瞬态激活、写临时文件、`close()` 才落盘）；WebTorrent 是"多分片+SW Range 服务"的落地范式 | FSA 目录句柄（**推荐**：一次手势授权目录，后续复用句柄）或 OPFS（无手势但要 offscreen/扩展页 + dedicated worker）；另列内存合并（ipull 默认，2GB Blob 上限） | **一致（互补）** | 两条路线集合相同。B 的"**FSA 用目录句柄而非 save picker**"是对 A 未展开的关键补充：RPC 触发下载时没有用户手势，只有"首次配置授权目录 + `createWritable({keepExistingData:true})`"才贴近 aria2 的 `dir` 语义。本轮核到 MDN：`write()` "No changes are written to the actual file on disk until the stream has been closed. Changes are typically written to a temporary file instead."、`createSyncAccessHandle` "only available in Dedicated Web Workers"。【官方文档】见 §7.1 |
| 16 | **断点续传** | `chrome.downloads` 只有 `pause/resume/canResume`，是否依赖服务器 Range **未验证**；自建续传须自己持久化分片状态（TDM 写文件 offset；DTA 的临时存储重拼不可靠） | 自己实现：OPFS 放"控制文件"记录已完成分片 + ETag/Last-Modified，恢复时用 `If-Range` 校验；`createWritable({keepExistingData:true})` 对续传重要 | **一致（互补）** | 合并为：浏览器**不提供**可直接复用的续传机制；自建方案必须自带分片状态持久化 + 条件请求校验（`If-Range`）。注意 `resume()` 与 Range 的关系本轮仍无官方说明（§4）。【官方文档】<https://developer.chrome.com/docs/extensions/reference/api/downloads> |
| 17 | **分片 / 整文件校验** | 自建通路可 `crypto.subtle.digest`；浏览器下载器写下的文件**读不回**（DTA：*"Checksums/Hashes? — Cannot be done with WebExtensions - cannot actually read the downloaded data"*）；无服务器 per-piece hash 时只能整文件校验 | 同（引 DTA 原文），并注明"本项目自读流可以算 hash，但没有服务器提供的 per-piece hash" | **一致** | 合并：**校验能力取决于"数据是否经过我们的手"**——`chrome.downloads` 路线不可校验；自建 fetch 路线可做整文件 hash，分片级校验只在服务器提供 hash 时才有意义。【源码/README】<https://github.com/downthemall/downthemall/blob/master/TODO.md> |
| 18 | **并发上限（HTTP/1.1 / HTTP/2）** | Chromium `g_max_sockets_per_group = {6, 255}`（kNormal/kWebSocket，注明常量是 `per_group` 且未核对 group 定义）；HTTP/2 `SETTINGS_MAX_CONCURRENT_STREAMS` 建议 ≥100，且各流共享同一 TCP 的流控 | 同源码：注释 "Default to allow up to 6 connections per host."；HTTP/2 并发流由对端设置决定 | **一致（互补）** | 本轮核到源码 L46-58：注释 "Default to allow up to 6 connections per host." + `{6, // kNormal, 255 // kWebSocket}`；同文件另有 `g_max_sockets_per_proxy_chain = {128, 128}` ⇒ **A 的"per_group 提醒"是对的**：6 是分组上限而非唯一约束，跨代理链另有 128 的总量上限。工程结论仍是"分片数 > 6 在 HTTP/1.1 下不会更快"。【源码】见 §7.1 |
| 19 | **MV3 执行上下文 / SW 生命周期** | 未系统展开；仅在 StreamSaver 处引到 "worker goes idle after 30 sec in firefox, 5 minutes in blink" | **重点结论**：Chrome 官方三类终止条件（空闲 30 s / 单请求 >5 min / `fetch()` 响应 >30 s 未到达）⇒ 多段下载执行体**不能放 SW**，应放扩展页/offscreen + dedicated Worker；且 dedicated worker 正好满足 OPFS sync handle 的上下文要求 | **一致（互补，B 覆盖更完整）** | 本轮核到官方原文三条件逐字成立；这是**对项目架构影响最大的一条"两份报告覆盖面不对称"**：A 的报告未引 Chrome 官方的 SW 生命周期条款（只在 StreamSaver 处引到 Firefox/Blink 的 idle 观察）。合并后以 B 为准。【官方文档】<https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle> |
| 20 | **与 R1–R13 及附录 A 的对照** | 逐条对照，结论：R3 的两个落点（`multithread` 无法真实还原；`withHeader` 部分可真实还原）；建议把 cookie 来源与 header 注入拆成不同原子能力；附录 A 的 A.3 前半有源码支持、后半只有社区证据 | 逐条对照，结论：R3 的"单连接降级 + 合成 `connections`"= 典型伪装还原；建议能力名拆细（`multiConnRange`、`customSensitiveHeader`）；补齐附录 A 未写出的优点（tabs 路线天然带 HttpOnly cookie、无需 `cookies` 权限） | **一致（互补）** | 两份对 R1–R13 **均无冲突**，且**都指向同一动作**：把"条件性"写进能力粒度/能力报告，否则 bool 能力会撒谎（与 Q-B8 已承认的代价一致）。合并建议见 §5.2。【继承】两份报告 §7 的逐条对照（本轮抽验其引用无误） |
| 21 | **失败模式与盲区（各自独有项）** | 独有：**多扩展抢同一个头时只有"最近安装的"生效，其余被静默忽略**；DNR append 越界导致**规则安装失败**（`ERROR_APPEND_INVALID_REQUEST_HEADER`）易被当成"没生效"；`chrome.downloads` 落盘目录不可控；FileSaver 2GB/内存；进度语义冲突；拦截盲区 × cookie | 独有：`chrome-extension://` 页 cookie 恒为 `SameSite=Lax`；3PC 屏蔽/用户收回 host 权限导致 same-site 例外失效；cookie 泄漏面（明文 HTTP RPC）；**无分片校验**；续传遇上资源变更（须 `If-Range`）；**SW 生命周期**；`chrome.downloads` cookie 行为未知 | **一致（互补）** | 两份的失败模式清单（A 的 F1–F20 与 B 的 F1–F19）去重后互为补充，**没有互相否证**。A 的"C12 多扩展冲突"本轮核到官方原文逐字成立（*"Only one extension can redirect a request or modify a header at a time… the most recently installed extension wins, and all others are ignored. An extension is not notified…"*），**属于必须写进能力报告/盲区清单的条目**，B 报告未覆盖。【官方文档】<https://developer.chrome.com/docs/extensions/reference/api/webRequest> |
| 22 | **隐私 / 安全面（cookie 外送）** | 明文把 `Cookie` 写进 aria2 参数 = 把凭据交给本地 aria2c；风险可接受但要知道 | 引 Aria2 Explorer 的安全闸门（RPC 必须 https/localhost，否则不附 cookie）与本地化文案；cookie 泄漏面 | **一致（互补）** | 本项目与外部 aria2 的情形**不同**（我们不外送 cookie），但**若将来做"导出给外部"或 RPC 走明文，必须复用同样的闸门**；B 的原文证据更硬。【源码】Aria2 Explorer `_locales/en/messages.json`【继承】 |
| 23 | **调研完备度 / 未验证清单** | §8 共 **14** 条未验证；声明无任何实测 | §8 共 **12** 条未验证；声明无任何实测 | **一致（互补）** | 两份的"未验证"并集经去重后 = §4 的清单；本轮又补掉其中 1 条（`chrome.downloads` 自带 cookie）并新增 1 条官方证据（多扩展冲突）。**共同缺口：0 实测**。 |

---

## 3 分歧点与裁定

> 原则：不投票、不折中。能回源定案的定案；定不了的单列 §5「待项目负责人裁定」。

### D1 `chrome.downloads` 自带 cookie：两份都写"未验证"，但官方文档有明文 → **两份都可撤销该"未验证"**

- **A 的依据**：§8.3 "`chrome.downloads` 发出的请求是否自带目标站点 cookie：文档无任何说明（无 `credentials` 概念）。推测走 profile cookie store，但未验证。"
- **B 的依据**：§8.2 "未找到官方明文；源码只显示请求 initiator 是扩展 origin。"（B 还额外核到 `set_do_not_prompt_for_login(true)`）
- **回源核验（本轮）**：Chrome `chrome.downloads` 参考页 `download()` 条目原文 ——
  > "**Download a URL. If the URL uses the HTTP[S] protocol, then the request will include all cookies currently set for its hostname.** If both `filename` and `saveAs` are specified, then the Save As dialog will be displayed…"
  （<https://developer.chrome.com/docs/extensions/reference/api/downloads>，2026-10-06 抓取）
- **裁定**：**`chrome.downloads` 触发的下载请求会带上该 hostname 当前设置的全部 cookie**（官方文档级证据）。这与两份报告从源码推出的"initiator 是扩展 origin"并不矛盾——initiator 决定 Referer/SameSite 语境，cookie 由 cookie jar 按请求 URL 附带。
- **对项目的直接含义**：**"带 cookie 下载"的最低成本通路就是 `chrome.downloads`**，不需要 `cookies` 权限、不需要 DNR；代价是**不能自定义 Cookie 值**（C2 死路）且拿不到响应体做校验/多段。
- **残余未验证**：HttpOnly / CHIPS 分区 / `SameSite=Strict` 三种 cookie 是否也在"all cookies"之列（文档未细分）；`chrome.downloads` 请求是否经过 DNR 仍无官方说明（§4-1）。

### D2 Chrono 证据能否使用：A 引原文 vs B 标 `[未验证]` → **A 成立，B 是抓取失败**

- **A 的依据**：商店页 KNOW ISSUES 原文 *"Chrono currently uses Chrome™'s built-in Downloads API, so it does not offer multi-threaded downloading capability and has limited support for pausing and resuming a large download."*
- **B 的依据**：§3-B-3 "本轮**未取得**其源码或关于'多线程'的官方技术说明（GitHub 上未找到可用的官方仓库；商店页为 JS 渲染，未取到可引原文）。**不作为证据使用**。"
- **回源核验（本轮）**：`curl` 抓取该商店页（728 KB HTML），在页面内嵌数据中命中上述原文（含 "built-in Downloads API"、"multi-threaded downloading capability" 两处片段）。
- **裁定**：**A 的证据成立**，Chrono 官方自认"用内置 Downloads API ⇒ 没有多线程能力"可列为**厂商级否定证据**；B 的 `[未验证]` 属于工具限制下的保守处理，不是反证。使用时的注意：商店页文案会随版本变动，引用时应带抓取日期。

### D3 TDM `max-segment-size` 默认值：A 说 50 MB，B 说 100 MB → **B 正确**

- **A 的依据**：`src/lib/wget.js` 文件头注释 `[maximum thread size; 50 MBytes]`。
- **B 的依据**：同一文件 `len = Math.min(len, obj['max-segment-size'] || 100 * 1024 * 1024);` 与 `src/lib/config.js` 的 `config.defineInt('wget.max-segment-size', 100 * 1024 * 1024, 100 * 1024);`。
- **回源核验（本轮）**：`wget.js` L21-22 注释确实写 50 KBytes / **50 MBytes**；但 L460-461 代码是 `Math.max(len, obj['min-segment-size'] || 50 * 1024)` 与 `Math.min(len, obj['max-segment-size'] || 100 * 1024 * 1024)`；`config.js` L185-186 的默认值是 `50*1024` 与 `100*1024*1024`。
- **裁定**：**运行时默认 = 最小 50 KiB / 最大 100 MiB**。A 引到的是**过期注释**（注释与实现不一致是 TDM 自身的问题），B 引的是**代码与配置的实际值**。此数值对借鉴意义不大，但属于本对照表必须落地的分歧。

### D4 TDM 写盘代码的文件出处：A 引 `src/lib/chrome/chrome-cm.js`，B 引 `src/lib/opera/chrome-cm.js` → **同一实现体，A 的引用可直接使用**

- **A 的依据**：写盘实现（`file.createWriter` + `fileWriter.seek(offset)`）在 `src/lib/chrome/chrome-cm.js#L320-L357`；扩展清单无 `fileSystem` 权限。
- **B 的依据**：扩展构建的磁盘层是 `src/lib/opera/chrome-cm.js`；`src/lib/chrome/chrome-cm.js` 是 Chrome App 构建。
- **回源核验（本轮）**：`src/lib/opera/chrome-cm.js` 的 HTTP 响应体**只有一行** `../chrome/chrome-cm.js`（构建期的 include 指令）；`src/manifest-extension.json` 的 `background.scripts` 加载的正是 `lib/opera/chrome-cm.js`，而代码正文（`chrome.fileSystem.chooseEntry/restoreEntry`、`requestFileSystem`、`createWriter`、`webkitTemporaryStorage`）全部在 `src/lib/chrome/chrome-cm.js`。
- **裁定**：**两者指向同一个实现体**：opera 版是构建入口，chrome 版是代码正文。合并后统一以 `src/lib/chrome/chrome-cm.js` 作为代码出处（A 的行号有效），并保留 A 的结论：扩展形态下 manifest 无 `fileSystem` 权限 ⇒ `root.external()` 那条路不可用，多线程写入在 MV3 扩展里没有等价物。

### D5 导航类请求是否携带 `SameSite=Strict` cookie：A 标"未验证"，B 表述为"导航天然带 cookie" → **B 的表述过宽，按官方文档收窄**

- **A 的依据**：§8.2 明确列为未验证；C6 要求区分扩展内例外的前提。
- **B 的依据**：C8 "*导航类请求天然带 cookie，但不能附加自定义头*"，引 MDN Set-Cookie 的 **Lax** 白名单（"顶层导航…`<form>` 提交"）。
- **回源核验（本轮）**：MDN Set-Cookie 的确只把"顶层导航/表单提交"写进 **`Lax`** 的放行条件；而 Chrome *Storage and cookies* 的 same-site 例外原文限定为 *"**Requests from an extension to a third-party** are treated as same-site if the extension has host permissions… **Note that this only applies to network requests**…"* —— 官方**没有**把它明确扩展到"扩展发起的顶层导航"。
- **裁定**：**B 的"导航天然带 cookie"只在 `SameSite=Lax` / `None` 范围成立；`SameSite=Strict` 情形无官方证据支持**。A 的"存疑"保留正确。此点为附录 A 路线（`chrome.tabs` + 两条 DNR）的关键前提，列入 §5.1 待裁定 + 实测。

### D6 `chrome.cookies.getAll` 的源码路径：A 引 `GetCookieListFromManager`+`MakeAllInclusive`，B 引 `GetAllCookiesFromManager` 无过滤 → **两者都对，描述的是不同分支**

- **回源核验（本轮）**：`extensions/browser/api/cookies/cookies_api.cc` 的 `CookiesGetAllFunction::Run()`：
  ```cc
  if (url_.is_empty()) {
    cookies_helpers::GetAllCookiesFromManager(cookie_manager, base::BindOnce(&…GetAllCookiesCallback, this));
  } else {
    cookies_helpers::GetCookieListFromManager(cookie_manager, url_, cookie_partition_key_collection, base::BindOnce(&…GetCookieListCallback, this));
  }
  ```
  而 `cookies_helpers.cc` 里：
  ```cc
  void GetCookieListFromManager(…, const GURL& url, …) {
    manager->GetCookieList(url, net::CookieOptions::MakeAllInclusive(), partition_key_collection, …);
  }
  void GetAllCookiesFromManager(…) { manager->GetAllCookies(…); }
  ```
- **裁定**：**两条路径都能拿到 HttpOnly cookie**（`MakeAllInclusive()` 明确包含；`GetAllCookies` 不受 HttpOnly 过滤）。**A 的引用恰是成熟扩展实际使用的 `getAll({url})` 分支**（对结论更直接），B 的引用是"不带 url 的全量分支"。两者互补，合并后两条都写。另核到 `set` 路径 L614-616 `options.set_include_httponly(); options.set_same_site_cookie_context(…MakeInclusive());`，与两份报告一致。

### D7 DNR `set` 能不能改 `Cookie`：A 说"解析期不拦"、B 说"没有禁止明文但也没示例" → **不是分歧，是"安装"与"生效"两件事**

- **回源核验（本轮）**：`indexed_rule.cc` L530-538 ——
  ```cc
  if (are_request_headers && header_info.operation == dnr_api::HeaderOperation::kAppend) {
    if (!kDNRRequestHeaderAppendAllowList.contains(base::ToLowerASCII(header_info.header))) {
      return ParseResult::ERROR_APPEND_INVALID_REQUEST_HEADER;
    }
  }
  ```
  官方文档只声明 append 的白名单，未对 `set` 设限（`ModifyHeaderInfo.value`："Must be specified for `append` and `set` operations."）。
- **裁定**：**`set` 规则能装上**（A 的源码结论成立）；**但 `set` 在运行期能否覆盖/清掉浏览器自己附带的 `Cookie` 头，两份都无证据**（B 的谨慎成立）。合并结论：*安装不是问题，"set 与浏览器自带 Cookie 的合并/覆盖顺序"才是未知；需要实测后再声明能力（与 Q-C4 一致）*。

### D8 多线程可行性的总基调：A "基本复现不了" vs B "不是不可能" → **范围不同，合并为两句**

- **回源核验（本轮）**：A 的否定对象是"aria2 语义"（`split` 可跨多服务器、`max-connection-per-server`、`connections` 数组语义），B 的肯定对象是"多段传输"这一技术行为。
- **裁定**：**两句都保留，但必须写清各自的主语**：
  1. **aria2 的 `split` / `max-connection-per-server` 语义无法原样复现**（浏览器无多服务器分片概念；HTTP/1.1 同 host 6 连接；HTTP/2 并发流受对端限制）；
  2. **"同一 URL 的分片并发下载"技术上可行**，前提是自建 fetch+Range 并自行解决随机写盘与执行上下文。

### D9 "下载管理器扩展都不自己取 cookie" 的适用范围：A 的概括对 TDM 不完全成立 → **以 B 的表述为准**

- **A**：A-9 "Chrono / DownThemAll / Turbo Download Manager(Classic) 这类扩展把请求交给浏览器自身的下载器…因此它们的源码里没有 cookie 读取逻辑"。
- **B**：A-5.5 对 TDM 全仓库 `grep -i cookie`，只有 Firefox 层一行 `forceAllowThirdPartyCookie = true`，结论是"TDM 从不自己拼 Cookie 头，多段请求依赖浏览器带 cookie"。
- **回源核验（本轮）**：`src/lib/firefox/firefox.js` L110-112 确有该三行；TDM 的扩展构建清单里也没有 `cookies` 权限。
- **裁定**：**B 的表述更精确**。TDM 确实**不构造 `Cookie` 头**（与 A 的结论一致），但它也**不把请求交给浏览器下载器**（它自己 fetch 分片，只是 cookie 由浏览器带；扩展构建在拿不到文件句柄时才回退 `chrome.downloads`，见 `src/lib/opera/opera.js`）。修订后的共同结论：*下载管理器类扩展不会自己拼 `Cookie` 头；要么依赖浏览器带（TDM/原生下载流），要么把 cookie 外送给外部程序（Aria2 Explorer 类）。这正是本项目要同时满足"带 cookie"与"可定制"时才被迫面对的矛盾。*

### D10 DTA "临时存储重拼不可靠" 的时代性：A 直接引用 vs B 加了保留 → **B 的保留成立，但 DTA 的核心结论不受影响**

- **B 的依据**：DTA 的判断形成于 FSA（2020+）/ OPFS（2023+）之前，"storage limitations"论据今天部分被削弱；未被削弱的是"浏览器下载 API 不提供分段"与"扩展里长期可靠低内存地持有拼装状态很难"。
- **回源核验（本轮）**：DTA 的 TODO 原文核实无误（含原文拼写错误 "reassembling"→"reassmbling"、"reliably"→"reliabliy"）；MDN 确认 OPFS 支持 `write(buf,{at})` 原地随机写。
- **裁定**：**B 正确**。DTA 的否定结论应被限定引用为"**浏览器自身的下载（`downloads` API / 原生下载流）没有分段能力**"，而**不能**外推为"WebExtension 里不能做多段下载"；后一句只对"依赖下载 API 的实现"成立。

---

## 4 两份均缺证据的点

### 4.1 两份都提到、两份都没有官方/源码证据（合并后仍未解决）

| # | 条目 | A 的说法 | B 的说法 | 本轮复核结果 |
|---|---|---|---|---|
| 1 | **DNR 是否作用于 `chrome.downloads` 发起的请求** | §8.1：只有一条 Stack Overflow（2024-02-03，无权威回答）+ 与附录 A 的用户结论一致 | §8.12 / C10：同一 SO 帖；Chromium issue 40256297 页面 JS 渲染未能取正文 | 仍未找到官方原文；本条直接决定附录 A 的"为什么不用 `chrome.downloads`"是否成立 → 见 §5.1 |
| 2 | **DNR `set` 整个 `Cookie` 头的运行时效果** | §8.8：`set` 与浏览器自带 Cookie 的合并顺序、是否对扩展自身 fetch 生效均未验证 | §8.1：必须实测（静态/会话规则各一次） | 安装期源码已定案（§3-D7）；**运行期仍无证据** |
| 3 | **`chrome.downloads` 的 `headers` 里 `Range` 是否被 honor** | §8.4：`Range` 不在禁用列表，但下载器是否发 206、能否拼回未知 | B 未提出该问题（B 只在 fetch 语境用 Range） | 无任何一方证据；`kForbiddenHeaderFields` 无 `range` 只说明"能传"，不说明"会被执行" |
| 4 | **`chrome.downloads.resume()` 是否依赖服务器字节范围** | §8.7：文档未提 Range | 未直接提出（只引 Chrono"limited support for pausing and resuming"的商店页文案） | 本轮核 `resume()` 文档原文："Resume a paused download. … The request will fail if the download is not active."——**无 Range 说明** |
| 5 | **FSA（`showSaveFilePicker` / `showDirectoryPicker`）在扩展页 / offscreen 文档中的行为与句柄跨会话持久化** | §8.5：MDN 明示属 `Window`，扩展侧行为未验证 | §8.5：`IndexedDB` 存 `FileSystemHandle` + 再授权语义在扩展上下文是否一致，未验证 | 未找到扩展上下文的官方说明 |
| 6 | **OPFS 异步路径在 MV3 SW 中是否可用**（`navigator.storage.getDirectory()` / `createWritable()`） | §8.6：MDN 只写 "available in Web Workers"，未区分 SW/Dedicated Worker | §8.3：同；但指出同步句柄**一定**不在 SW（dedicated worker only） | 本轮核 MDN `createSyncAccessHandle` 明示 dedicated worker only（同步路径定案）；**异步路径在 SW 仍未验证** |
| 7 | **扩展发起的顶层导航是否落在"extension→third-party 视为 same-site"例外内** | §8.2：官方无明文，需实测 | 未提出（B 用 Lax 引文支撑"导航天然带 cookie"） | 见 §3-D5：官方例外原文限定 "network requests"；导航是否属于该例外**仍无证据** |
| 8 | **服务器对 `Range` 的部分支持 / 错误 `Content-Range` 的实际行为** | 只在 §3-B-9 表里给"服务器不支持则退化"的规范结论 | §8.11：只有规范层结论 | 只有规范（200 vs 206）层结论，无实测 |
| 9 | **Firefox / Safari 的对等结论** | Firefox 只标注未逐条核对；Safari 完全未覆盖 | Firefox 未系统调研；Safari 未覆盖 | 两份都缺；本项目当前只按 Chrome MV3 设计，可不阻塞 |
| 10 | **实测数据（任何一条）** | §8.14：全部为文档/源码级，无一次真实请求验证 | 同（附取证方式说明） | **两份的共同最大缺口**；HttpOnly 注入、DNR append/set、OPFS 吞吐、`chrome.downloads` cookie 行为全部只有文档级依据 |

### 4.2 两份都提到、但**本轮回源已补上证据**（不再列为"缺证据"）

| # | 条目 | 补上的证据（本轮核验） |
|---|---|---|
| 1 | `chrome.downloads` 是否自带 cookie | 官方文档明文："the request will include all cookies currently set for its hostname"（§3-D1） |
| 2 | TDM `max-segment-size` 默认值 | `config.js` L186 = 100 MiB；`wget.js` L461 兜底同为 100 MiB（§3-D3） |
| 3 | Chrono 是否有多线程 | 商店页原文命中（§3-D2） |
| 4 | DNR append 的 `cookie` 分隔符 | `constants.h` L326 `{"cookie", "; "}`（A 已给，本轮再次确认） |
| 5 | 多扩展改同一请求头时的行为 | Chrome `webRequest` 文档原文（A 已给，本轮再次确认） |
| 6 | `chrome.cookies.getAll({url})` 的 HttpOnly 路径 | `cookies_api.cc` L438 + `cookies_helpers.cc` L180（§3-D6） |

### 4.3 仅单方提出、同样无证据（不构成"两份均缺"，列出以免漏检）

- `chrome.downloads.download({url: blobURL})` 是否被接受（B §8.4，用于把 OPFS 里拼好的文件导出）。
- `chrome.debugger` + CDP `Network.setExtraHTTPHeaders` 改头（B §8.6，仅登记线索）。
- HTTP/2 下 Chrome 对同一 host 的 fetch 是否有额外节流（B §8.9）。
- `chrome.downloads.download({headers})` 里的 `Range` 之外的允许头实际行为（A §3-B-9 表，A 单独标注）。
- hls.js / dash.js 的分片并发度配置（A §8.11，检索未发现即不下结论）。
- AriaNg / 其它前端如何取 cookie（A §8.9；B 未提）。
- Aria2 Integration（baptistecdr）的取 cookie 实现（B A-5.3，仓库无源码）。
- 调研当日 Chrome 稳定版号（A §8.10）。

---

## 5 待项目负责人裁定

> 这些点**无法用官方文档/源码定案**（或虽能定案但属于产品取舍），两份报告的依据都列在下面。

### 5.1 附录 A 的两条前提是否要先做一轮最小实测

- **前提 1**：*"`chrome.downloads` 触发的下载会无视修改请求头的 DNR"*（附录 A.3 的原话）。双方依据：A §8.1 / B §8.12 都只找到同一条第三方实测报告（Stack Overflow 77932227，0 回答），官方无原文；两份报告与附录 A 的结论一致但都未获官方确认。
- **前提 2**：`chrome.tabs` 打开的顶层导航是否携带 `SameSite=Strict` cookie（§3-D5）。双方依据：A 明确列为未验证；B 引用 MDN 的 Lax 条款，但该条款不覆盖 Strict。
- **为什么需要负责人裁定**：这两条决定附录 A 这条路线（也是本项目"带 cookie 下载"的最省事路线）**在真实登录站点上是否兑现**。两份报告都建议做一次最小实测；本合并文档无法替负责人决定是否在详细设计前插入实测轮。
- **可执行的最小实测清单（建议）**：① `chrome.downloads.download()` 一个需要登录态的 URL，看是否带 cookie；② 同 URL 用 DNR `append` 注入一个探针 cookie，看 downloads 请求是否带上（验证前提 1）；③ `chrome.tabs.create` 打开需要 `SameSite=Strict` 登录态的 URL，看是否带 cookie（验证前提 2）；④ DNR `set` Cookie 在普通 fetch 与 downloads 两种请求上的效果（§4-2）。

### 5.2 `multithread` / `withHeader` 的能力粒度怎么定

- 双方共同结论：这两个能力**都是有条件的**（`multithread` 依赖 Content-Length/无编码/`Accept-Ranges`/206/落盘上下文；`withHeader` 依赖"浏览器自带 cookie vs 可自定义值 vs 敏感头"三种子情形）。
- 已知裁定：Q-B8 规定能力是**纯 bool** 且"能力缺失时该伪装还是该拒绝由 Mock 层按能力类别统一规定"；A 建议把"cookie 来源"与"header 注入"拆成两个原子能力（如 `withCookieFromBrowser`），B 建议拆成 `multiConnRange` / `customSensitiveHeader` 之类。
- **待裁定**：能力清单里命名为哪些 bool、以及每个 bool 的"前置条件"是否写进能力报告（R13-3）。两份报告都不反对 bool 模型，但都要求把条件显式化，否则 bool 会撒谎。

### 5.3 多段下载的落盘路线与代价接受

| 路线 | 证据 | 代价（两份报告均确认） |
|---|---|---|
| OPFS（`createSyncAccessHandle().write(buf,{at})`） | MDN：in-place write，仅 dedicated worker，独占锁 | 对用户**不可见**，必须整份导出（峰值 ~2× 磁盘 + 一次全量拷贝）；受配额/清理影响，需 `unlimitedStorage` + `storage.persist()` |
| FSA 目录句柄（`showDirectoryPicker` → `createWritable({keepExistingData:true})`） | MDN + Chromium 企业策略：需要**瞬态用户激活** | RPC 触发下载时**没有用户手势** ⇒ 只能"首次配置时授权目录、之后复用句柄"（句柄持久化在扩展上下文的语义未验证，§4-5）；`close()` 前不落盘 |
| 内存合并（Blob / `Uint8Array`） | ipull 浏览器默认；FileSaver 上限表 Chrome 2GB | 大文件不可用 |

**待裁定**：接受哪条作为"多段引擎"的默认落盘方案，或是否接受"多段能力仅在用户显式配置目录后可用"（这会把 R13-2"调整默认参数"扩展为"必须配置保存目录"）。

### 5.4 引擎的执行上下文（当前裁定的空白）

- 事实：MV3 SW 会被三类条件终止（B 的 C21，本轮核到官方原文）；OPFS 同步句柄只能在 dedicated worker；`showSaveFilePicker` 需要 `Window`。
- **待裁定**：是否正式把"**offscreen 文档 / 扩展页 + 打包的 dedicated Worker**"定为下载引擎的宿主上下文（涉及 MV3 CSP 禁止远程代码、offscreen 文档生命周期、以及 Q-D5 的状态持久化边界）。两份报告都指向该结论，但概念设计的 R4/R7 未涉及执行上下文。

### 5.5 需求 A 的 MVP 落点

- 合并后事实：`chrome.downloads` 路线**自带 cookie**（官方明文）但**不能定制 Cookie/Referer/User-Agent**；DNR 路线**能定制**但受"扩展级规则串台/多扩展冲突/`set` 未验证"影响；tabs 路线最省事但落盘目录、时间依赖与 Strict 前提未定（§5.1）。
- **待裁定**：入站 RPC 自带 `header`（含 `Cookie:`）时，引擎是"照单全收交给 DNR"还是"仅接受能在浏览器内落地的子集"，其余按 R3 报错/伪装还原。这直接决定 `withHeader` 的三值裁定。

### 5.6 是否接受"单流真实下载 + 伪装 `connections`"作为默认

- 两份一致：`multithread=false` 时收到 `split>1`，按 R10 的判据（结果兑现）做**伪装还原**是合法的；两份都提醒必须满足 Q-B3 的不变量（`connections` 不重叠且并为文件分片划分；进度只能报真值，`chrome.downloads` 能给 `bytesReceived/totalBytes`）。
- **待裁定**：这是"确认执行 R3/R10 既有裁定"还是"要新增一个能力名"，以及是否允许把 `connections` 合成为"单连接占满全文件"。

---

## 6 对项目最关键的 3 个发现

### 发现 1：Cookie 有四种"浏览器自己带"的姿势，但只有一种能自定义 Cookie 值

- 让浏览器自己带的四种：① `chrome.downloads.download()`（**官方明文自带该 hostname 的全部 cookie**，本轮新证据，两份报告都误标"未验证"）；② `chrome.tabs` 导航 + 原生下载流（附录 A 路线）；③ 扩展页/SW 的 `fetch(credentials:'include')`（有 host 权限时按 same-site 处理，官方明文）；④ `chrome.cookies.set` 改 cookie jar（B 单方提出，会污染用户 cookie，未见项目这么做）。
- 能自定义 Cookie 值的只有一种：**DNR `modifyHeaders`**（`append` 有官方白名单 + `"; "` 源码级分隔符；`set` 未验证）。两条"自己写 Cookie 头"的路（`fetch`、`chrome.downloads({headers})`）分别被 Fetch 规范与 Chromium 源码钉死。
- **对项目的含义**：`withHeader` 不应是一个 bool，而至少是"浏览器自带 cookie / 可自定义非敏感头 / 可自定义敏感头"三段；且"读 cookie（`chrome.cookies`，含 HttpOnly，源码级确认）"与"注入 cookie（DNR）"是两个独立能力（两份报告不约而同提出）。

### 发现 2：多段下载的真正瓶颈是"落盘 + 执行上下文"，不是网络

- 网络侧都只是"性能与降级"问题：`Range` 可发（CORS-safelisted、非 forbidden），服务器可忽略它返回 200，HTTP/1.1 同 host 6 连接、HTTP/2 单连接多路复用共享流控。
- 落盘侧才是墙：**没有任何 API 能直接写"用户可见文件的任意偏移"**——OPFS 高性能随机写仅 dedicated worker 且对用户不可见（要整份导出）；FSA 能按 `position` 写但要瞬态用户激活、`close()` 前只写临时文件。
- 执行上下文是第二道墙：MV3 SW 在"空闲 30 秒 / 单请求 >5 分钟 / `fetch()` 响应 >30 秒未到达"时被终止（官方原文，本轮核到）⇒ 引擎长循环必须搬出 SW，而搬出去之后又要求 offscreen/扩展页 + 打包 Worker（MV3 CSP）。
- **对项目的含义**：`multithread=true` 的代价不是"写几行 `Range` 代码"，而是"用户手势/不可见沙箱/导出步骤/2× 磁盘/独立执行上下文"一整套，必须在能力报告里显式列出（R13-3），否则违反 R2 的诚实原则。

### 发现 3：生态里的"做不到"只对"浏览器自身的下载器"成立，不能外推为"浏览器里做不到"

- DTA 的 TODO（*"Segmented downloads — Cannot be done with WebExtensions"*）、Chrono 商店页（*"it does not offer multi-threaded downloading capability"*）、TDM 的停更与 Chrome App 依赖，**否定的对象是"浏览器内置下载器 / `downloads` API 是否支持分段"**，不是"WebExtension 能否自建多段"。
- 自建多段有真实先例与骨架：TDM 的"长度 + 无 `Content-Encoding` + `Accept-Ranges: bytes` + 实收 206 + min/max 分片 + offset 回写"；ipull 的"探测 → `Range` 并发（浏览器默认 3 路）→ 按 cursor 回写"。区别在于：前者能落盘是因为拿到了 Chrome App 的文件句柄（今天不存在），后者默认在内存合并（大文件撞 2GB）。
- **对项目的含义**：R3 在 `split` / `max-connection-per-server` 上的裁定落点应是"**默认单流真实下载 + `connections` 伪装还原**（R10 合法），把多段作为需要显式配置落盘位置的条件性能力"，而不是"多线程不可实现"或"假装支持"。这也是两份报告在 §5/§7 里唯一的实质分歧（§3-D8）被合并后的共同结论。

---

## 7 证据清单

### 7.1 本轮亲自核验的证据（2026-10-06；Chromium 引用为 `main` 在线版，未固定 commit）

**A. Chromium 源码（`https://chromium.googlesource.com/chromium/src/+/main/<path>?format=TEXT`，base64 解码后检索）**

| # | 文件 | 核到的关键内容 |
|---|---|---|
| S1 | `extensions/browser/api/cookies/cookies_api.cc` | L434 `GetAllCookiesFromManager`（`url_` 为空分支）；L438 `GetCookieListFromManager`（带 url 分支）；L614-616 `options.set_include_httponly(); options.set_same_site_cookie_context(net::CookieOptions::SameSiteCookieContext::MakeInclusive());` |
| S2 | `extensions/browser/api/cookies/cookies_helpers.cc` | L175-183 `GetCookieListFromManager()` → `manager->GetCookieList(url, net::CookieOptions::MakeAllInclusive(), partition_key_collection, …)`；L187-191 `GetAllCookiesFromManager()` → `manager->GetAllCookies(…)`（无 HttpOnly 过滤） |
| S3 | `net/http/http_util.cc` | L411-436 `kForbiddenHeaderFields[]` = accept-charset, accept-encoding, access-control-request-headers, access-control-request-method, connection, content-length, **cookie**, cookie2, date, dnt, expect, host, keep-alive, origin, **referer**, set-cookie, te, trailer, transfer-encoding, upgrade, **user-agent**, via —— **列表内无 `range`** |
| S4 | `chrome/browser/extensions/api/downloads/downloads_api.cc` | L1222-1237：`if (options.headers) { … IsValidHeaderName → IsSafeHeader（失败 kInvalidHeaderUnsafe）→ IsValidHeaderValue → download_params->add_request_header(…) }` |
| S5 | `chrome/browser/extensions/api/downloads/download_extension_errors.h` | L23 `inline constexpr char kInvalidHeaderUnsafe[] = "Unsafe request header name";` |
| S6 | `extensions/browser/api/declarative_net_request/constants.h` | L317-339 `kDNRRequestHeaderAppendAllowList`：`{"cookie", "; "}`、`{"range", ", "}`、`{"user-agent", " "}`、`{"trailer", ""}` 等 |
| S7 | `extensions/browser/api/declarative_net_request/indexed_rule.cc` | L526-538：白名单校验仅在 `are_request_headers && operation == kAppend` 时执行，越界 → `ParseResult::ERROR_APPEND_INVALID_REQUEST_HEADER` |
| S8 | `net/socket/client_socket_pool_manager.cc` | L46-58 注释 "Default to allow up to 6 connections per host." + `g_max_sockets_per_group = { 6 /*kNormal*/, 255 /*kWebSocket*/ }`；L62-66 `g_max_sockets_per_proxy_chain = {128, 128}` |

**B. Chrome for Developers 官方文档**

| # | 页面 | 核到的原文 |
|---|---|---|
| D1 | [chrome.downloads](https://developer.chrome.com/docs/extensions/reference/api/downloads) | `download()`："Download a URL. **If the URL uses the HTTP[S] protocol, then the request will include all cookies currently set for its hostname.**"；`headers`："…**restricted to those allowed by XMLHttpRequest**."；`resume()`："Resume a paused download. … The request will fail if the download is not active."（**无 Range 说明**） |
| D2 | [storage-and-cookies](https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies) | "**Requests from an extension to a third-party are treated as same-site if the extension has host permissions for the third-party. This means SameSite=Strict cookies can be sent.** Note that this only applies to network requests, not access through `document.cookie` in JavaScript, and does not apply if third-party cookies are blocked."；"Cookies set on `chrome-extension://` pages always use `SameSite=Lax`."；`unlimitedStorage` "exempts extensions from both quota restrictions and eviction." |
| D3 | [service worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle) | "Normally, Chrome terminates a service worker when one of the following conditions is met: **After 30 seconds of inactivity**… **When a single request, such as an event or API call, takes longer than 5 minutes to process.** **When a `fetch()` response takes more than 30 seconds to arrive.**" |
| D4 | [declarativeNetRequest](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest) | "Header modification — **The `append` operation is only supported for the following request headers: accept, …, cookie, …, range, …** This allowlist is case sensitive (bug 449152902)."；"**Before Chrome sends request headers to the server, the headers are updated based on matching modifyHeaders rules.**"；"A declarativeNetRequest only applies to requests that reach the network stack."；`ModifyHeaderInfo.value`："Must be specified for `append` and `set` operations."（**未见对 `set` cookie 的任何禁止或示例**） |
| D5 | [chrome.webRequest](https://developer.chrome.com/docs/extensions/reference/api/webRequest) | "**Only one extension can redirect a request or modify a header at a time.** If more than one extension attempts to modify the request, **the most recently installed extension wins, and all others are ignored**. An extension is not notified if its instruction to modify or redirect has been ignored."；"Note: As of Manifest V3, the `"webRequestBlocking"` permission is no longer available for most extensions… Policy installed extensions can continue to use `"webRequestBlocking"`." |
| D6 | [chrome.cookies](https://developer.chrome.com/docs/extensions/reference/api/cookies) | "To use the cookies API, declare the `"cookies"` permission in your manifest along with host permissions for any hosts whose cookies you want to access."；`getAll`："**This method only retrieves cookies for domains that the extension has host permissions to.**" |

**C. MDN / 规范**

| # | 页面 | 核到的原文 |
|---|---|---|
| M1 | [Window.showSaveFilePicker](https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker) | "**Transient user activation is required.** The user has to interact with the page or a UI element in order for this feature to work." |
| M2 | [FileSystemWritableFileStream.write](https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream/write) | "…at the current file cursor offset. **No changes are written to the actual file on disk until the stream has been closed. Changes are typically written to a temporary file instead.**" |
| M3 | [createSyncAccessHandle](https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle/createSyncAccessHandle) | "**Note: This feature is only available in Dedicated Web Workers.**" |
| M4 | [Set-Cookie](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie) | `SameSite=Lax`："…The request is a top-level navigation… **This would exclude, for example, requests made using the `fetch()` API**… It would include requests made when the user clicks a link in the top-level browsing context from one site to another, or an assignment to `document.location`, or a `<form>` submission." |
| M5 | [Range](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Range) | "**The header is a CORS-safelisted request header when the directive specifies a single byte range.**"；"**Forbidden request header: No**"；"**A server that doesn't support range requests may ignore the Range header and return the whole resource with a 200 status code.**"；"If the requested data has a content coding applied, each byte range represents the encoded sequence of bytes…" |

**D. 开源项目 / 商店页 / 官方手册**

| # | 来源 | 核到的内容 |
|---|---|---|
| O1 | [Aria2 Explorer `background.js`](https://raw.githubusercontent.com/alexhua/Aria2-Explorer/master/background.js) | L110-126 `getCookies()`：`chrome.cookies.getAll({ url, storeId })` + `getAll({url,storeId,partitionKey:{}})`（try/catch）→ `cookieMap` 去重 → `name + "=" + value`；L143-147 `headers.push("Cookie: " + cookieItems.join("; "))`、`push("User-Agent: " + navigator.userAgent)`；L149-169 `options.header = headers` → `aria2.addUri(downloadItem.url, options)` |
| O2 | [Aria2 Explorer `manifest.json`](https://raw.githubusercontent.com/alexhua/Aria2-Explorer/master/manifest.json) | `"version": "2.8.3"`、`"manifest_version": 3`、`"minimum_chrome_version": "116.0.0"`、`permissions` 含 `cookies`/`downloads`、`host_permissions: ["<all_urls>"]` |
| O3 | [YAAW-for-Chrome `background.js`](https://raw.githubusercontent.com/acgotaku/YAAW-for-Chrome/master/background.js) | L114-126：`chrome.cookies.getAll({ url: fileDownloadInfo.link }, …)` → `'Cookie: ' + formatedCookies.join('; ')` + `'User-Agent: ' + navigator.userAgent` → `method: 'aria2.addUri'`；`manifest.json` 为 MV3 |
| O4 | [TDM `src/lib/wget.js`](https://raw.githubusercontent.com/inbasic/turbo-download-manager/master/src/lib/wget.js) | L21-22 注释写 min **50 KBytes** / max **50 MBytes**；L70-72 `if (res.status && res.status !== 206 && obj.headers.Range) throw …`；L89 `obj.headers.Range = bytes=${start}-${end}`；L129 `Accept-Ranges === 'bytes'`；L460-461 代码 `Math.max(len, … \|\| 50*1024)` / `Math.min(len, … \|\| 100*1024*1024)` |
| O5 | [TDM `src/lib/config.js`](https://raw.githubusercontent.com/inbasic/turbo-download-manager/master/src/lib/config.js) | L178 `config.defineInt('wget.threads', 3)`；L185-186 min 50 KiB / **max 100 MiB** |
| O6 | [TDM `src/lib/chrome/chrome-cm.js`](https://raw.githubusercontent.com/inbasic/turbo-download-manager/master/src/lib/chrome/chrome-cm.js) | L266-268 `chrome.fileSystem.chooseEntry/retainEntry`；L319 `window.requestFileSystem = …webkitRequestFileSystem`；L339/L348 `file.createWriter(…)`（L361 附近 `fileWriter.seek(offset); fileWriter.write(blob)`，与两份报告引用一致）；L392 `navigator.webkitTemporaryStorage.requestQuota`；L412 `chrome.fileSystem.restoreEntry` |
| O7 | TDM `src/lib/opera/chrome-cm.js` / `src/manifest-extension.json` / `src/lib/opera/opera.js` | `opera/chrome-cm.js` 内容**仅一行** `../chrome/chrome-cm.js`；`manifest-extension.json` 为 `manifest_version: 2`，`permissions` = storage/tabs/notifications/contextMenus/webRequest/`<all_urls>`/clipboardRead/downloads（**无 `fileSystem`**），`background.scripts` 加载 `lib/opera/chrome-cm.js`；`opera/opera.js` L78 `app.download = (obj) => chrome.downloads.download({…})` |
| O8 | [TDM `src/lib/firefox/firefox.js`](https://raw.githubusercontent.com/inbasic/turbo-download-manager/master/src/lib/firefox/firefox.js) | L110-112 `req.channel.QueryInterface(Ci.nsIHttpChannelInternal).forceAllowThirdPartyCookie = true;`（全仓库唯一的 cookie 相关代码） |
| O9 | [DownThemAll `TODO.md`](https://github.com/downthemall/downthemall/blob/master/TODO.md) / [`Readme.md`](https://github.com/downthemall/downthemall/blob/master/Readme.md) | "P4 — Stuff that probably cannot be implemented due to WeberEension limitations."；"**Segmented downloads** — Cannot be done with WebExtensions - downloads API has no support and manually downloading, storing in temporary add-on storage and reassmbling the downloaded parts later is not only efficient but does not reliabliy work due to storage limitations."；"**Checksums/Hashes?** — Cannot be done with WebExtensions - cannot actually read the downloaded data"；"**Mirrors?** — Cannot be done with WebExtensions - no low level APIs, see segmented downloads"；Readme："we cannot do our own downloads any longer but have to go through the browser download manager always"、"…doesn't eat all the system memory for breakfast" |
| O10 | [Chrono Download Manager 商店页](https://chromewebstore.google.com/detail/chrono-download-manager/mciiogijehkdemklbdcbfkefimifhecn) | "Chrono currently uses Chrome™'s built-in Downloads API, so **it does not offer multi-threaded downloading capability** and has limited support for pausing and resuming a large download. All downloaded files can only be saved under Chrome™'s default downloads folder or any of its subdirectories." |
| O11 | [ipull `browser-download.ts`](https://raw.githubusercontent.com/ido-pluto/ipull/main/src/download/browser-download.ts) / `README.md` | L7 `const DEFAULT_PARALLEL_STREAMS_FOR_BROWSER = 3;`；README："Super fast file downloader with multiple connections" / "Download using parallels connections" |
| O12 | [aria2 官方手册](https://aria2.github.io/manual/en/html/aria2c.html) | "`-s, --split=<N>` ¶ Download a file using N connections. … The number of connections to the same host is restricted by the `--max-connection-per-server` option. … **Default: 5**"；"`-x, --max-connection-per-server=<NUM>` ¶ The maximum number of connections to one server for each download. **Default: 1**"；"`-k, --min-split-size=<SIZE>` … aria2 does not split less than 2*SIZE byte range." |

### 7.2 两份报告共同依赖、本轮**未**独立复核的条目（按"继承"处理）

- Fetch 规范 forbidden header 列表（<https://fetch.spec.whatwg.org/#forbidden-header-name>）与 MDN [Forbidden request header](https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header)：本轮只复核了 Chromium 侧对应实现（S3），规范原文未重新抓取。
- Chrome *Cross-origin network requests*（content script 的 CORS 与 origin 规则）：两份引用一致，本轮未重抓。
- MDN OPFS 页的"not visible to the user / quota / 清理"与 `FileSystemSyncAccessHandle.write({at})`：两份引用一致，本轮只复核了 `createSyncAccessHandle` 的上下文限制（M3）。
- WebTorrent `docs/api.md`、StreamSaver.js、FileSaver.js、browser-fs-access、native-file-system-adapter、Get cookies.txt LOCALLY、Cookie-Editor、Free Download Manager 商店页：两份引用一致，本轮未逐条重抓（其中 FileSaver 的 Blob 上限表、FDM 的 "native client is required" 两条被两份报告同时引用，可信度较高但仍属【继承】）。
- Stack Overflow 77932227（DNR 对 `chrome.downloads` 请求不生效）与 Chromium issue 40256297：两份据同一来源，0 权威回答；本轮**未能**改善（§4-1）。
- 两份报告 §9 中仅单方引用的其它 URL（hls.js、dash.js、MDN MSE、RFC 9113 §5.1.2/§5.2/§6.5.2、Chrome 企业策略 YAML、`Access-Control-Allow-Credentials` 等）：未独立复核。
- 两份报告的"最后提交时间"类元数据（各仓库 commit 日期）：未独立复核。

### 7.3 本合并文档对上游结论的修订一览（便于回溯）

| 上游条目 | 原文/结论 | 本文件修订 | 依据 |
|---|---|---|---|
| A §8.3 / B §8.2 | `chrome.downloads` 是否自带 cookie = 未验证 | **自带该 hostname 的全部 cookie**（官方明文） | §3-D1；证据见 §7.1-B 的 D1 行 |
| B §3-B-3 | Chrono 多线程 = `[未验证]`，不作为证据 | **证据成立**（商店页原文命中） | §3-D2，O10 |
| A §3-B-1 | TDM `max-segment-size` = 50 MBytes | 运行时默认 **100 MiB**（A 引的是过期注释） | §3-D3，O4/O5 |
| B §3-B-1 | TDM 写盘文件 = `src/lib/opera/chrome-cm.js` | 代码正文在 `src/lib/chrome/chrome-cm.js`（opera 版只有一行 include） | §3-D4；证据见 O7 |
| B C8 | "导航类请求天然带 cookie" | 仅 `Lax`/`None`；**`Strict` 无证据** | §3-D5；证据见 M4 与 §7.1-B 的 D2 行 |
| A 的"多线程基本复现不了" | 单句否定 | 拆成"aria2 语义不可复现"+"多段技术可行但有硬代价" | §3-D8 |
| 两份共同 | `chrome.downloads` 自带 cookie / `resume()` 与 Range 关系 | 前者已解决；后者仍未验证 | §4-1 #4 |

---

*报告结束。凡本文件与两份上游报告冲突处，以本文件 §3 的"回源核验"为准；凡本文件标【继承】处，请回到原 URL 复核。*
