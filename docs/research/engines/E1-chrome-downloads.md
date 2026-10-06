# E1 — chrome.downloads 路线（浏览器原生下载子系统）的能力边界

> 本文是「浏览器技术边界测绘」中 **E1 途径** 的输入文档，供后续「能力清单」「能力→接口行为规则表」与详细设计使用。
> 本文**只做边界测绘**：回答「能不能做 / 代价是什么 / 在哪个上下文里能做 / 会不会被生命周期打断」，不写 API 教程，不给设计结论。
> 引用编号 `[E#]` 对应 §8 证据清单。**未验证**的结论集中在 §7，正文中一律显式标注。

---

## 0 元信息：核对日期、浏览器与版本、主要依据文档

| 项 | 值 |
|---|---|
| 核对日期 | **2026-10-06**（UTC） |
| 主要依据 | Chrome Extensions 官方 API 参考（`browser.downloads`、`declarativeNetRequest`、`offscreen`、`scripting`、`webRequest`、`permissions-list`）、Chrome 官方开发指南（service worker 生命周期 / 事件 / 内容脚本 / MV3 迁移）、MDN WebExtensions、Google Chrome 帮助中心 |
| 代码级依据 | **Chromium `main` 分支，commit `1c5c9592bf28cc227aa41f8dfbe8d53467f8b6e4`，committer time 2026-10-06 09:51:20 UTC**（通过 `chromium.googlesource.com` 的 `?format=TEXT` 逐文件抓取；每条给出文件路径与行号） |
| 文档快照版本 | downloads 参考页脚注 **"Last updated 2026-10-04 UTC"**；生命周期页脚注 "Last updated 2023-05-02 UTC"；DNR 页面内已出现 **Chrome 145**（`topDomains`）与 **Chrome 148**（`browser.*` 标准化命名空间）的版本标注 ⇒ 文档快照 ≈ **Chrome 148+** 时代 |
| 实测 Chrome 版本 | **未实测**。本环境无法启动浏览器，所有结论均来自官方文档 + Chromium 源码；凡未在真实 Chrome 上复现者，正文中标注「未运行时验证」 |
| 浏览器适用范围 | 结论默认针对 **Chrome / Chromium（MV3 扩展）**。Firefox 的 `browser.downloads` 有若干差异（见 §8 [E23]、§7 #14），非本途径主线 |
| 版本漂移警示 | 浏览器 API 会漂移。本文所有引用均带核对日期；**Chrome 主版本号一旦前进，`§3` 的源码级结论与 `§5` 的 bug 级结论必须重新核对** |

**约定**：正文中 `（✓2026-10-06｜证据 [E#]）` = 该结论的核对日期与证据条目。`〔推断〕` = 由证据推导而非文档明文；`〔未验证〕` = 未找到权威出处。

---

## 1 一句话结论（能做 / 不能做 / 有条件能做）

**有条件能做，且是「最像下载器」的一条途径，但能力天花板很低。**

- **能做**：真的把文件下载到磁盘（浏览器下载子系统执行）、真的给回真实进度（`bytesReceived` / `totalBytes`）、真的能暂停 / 恢复 / 取消 / 删除文件、任务句柄跨浏览器重启持久、下载全程由浏览器（而非扩展 SW）托管 ⇒ **可以当下载引擎主力**（在只做单连接 HTTP(S) 下载的定位下）。
- **不能做**（硬墙）：指定绝对保存路径；发起多连接 / 分片下载；设置敏感请求头（`Cookie` / `Referer` / `Origin` / `User-Agent` / `Host` / `Content-Length` … 见 §3.2）；自动接受「危险下载」判定（`acceptDanger` 只允许可见上下文）；限速；排队等待（没有 waiting 态）。BT / Metalink / 多源镜像 / 校验和等 aria2 能力完全不存在。
- **条件性**：`saveAs` / `conflictAction: prompt` 会弹系统对话框（无人值守场景不可用）；`resume()` 只在 `canResume` 为真时有效；`onDeterminingFilename` 只能「建议」文件名，会被更后安装的扩展抢占，且只接受相对路径。
- **本途径的最大结构性风险**：**它不是一个下载引擎，而是「浏览器下载管理器」的远程控制面**——一切落盘策略、安全策略、UI 策略都由浏览器用户设置决定，扩展只能读结果、不能改规则（§5.1、§5.3）。

---

## 2 机制（步骤级，能照着复现）

以下步骤来自官方文档与 Chromium 源码，**未在真实浏览器复现**（本环境无浏览器）。标注为「文档明文」的步骤有官方出处；标注为「源码」的步骤来自 §0 所列 commit。

### 2.1 发起一次下载（最小路径）

1. **声明权限**：`manifest.json` 里写 `"permissions": ["downloads"]`。
   文档明文：*"You must declare the `"downloads"` permission in the extension manifest to use this API."*（✓2026-10-06｜[E1][E22]）安装时用户看到警告文案 **"Manage your downloads."**（[E22]）。
2. **在扩展上下文中调用**（MV3 service worker / 扩展页 / popup）：
   ```js
   const id = await chrome.downloads.download({
     url,                       // 必填，唯一必填项 [E1]
     filename: "sub/dir/name.ext", // 可选，相对 Downloads 目录 [E1]
     conflictAction: "uniquify", // uniquify | overwrite | prompt [E1]
     saveAs: false,             // 可选 [E1]
     method: "GET",             // GET | POST [E1]
     headers: [{ name: "Authorization", value: "Bearer x" }] // 可选，受限 [E1][E3]
   });
   ```
   返回 `Promise<number>` = 新 `DownloadItem` 的 `id`；成功即「已入队并由浏览器接管」，**不等于下载完成**。（✓2026-10-06｜[E1][E2]）
3. **浏览器下载子系统接管**：请求由浏览器进程的 DownloadManager 发出（`rfh` 为空时走 `storage_partition->GetURLLoaderFactoryForBrowserProcessIOThread()`；`rfh` 非空时走 `kDownload` 类型的工厂）（源码 ✓2026-10-06｜[E9]）。**下载进度与扩展 SW 的存活无关**（详 §3.6）。
4. **读进度 / 状态**（唯一能拿到真实字节数的办法）：
   ```js
   const [item] = await chrome.downloads.search({ id }); // 或批量 { state: "in_progress" }
   ```
   `item.bytesReceived` / `item.totalBytes` / `item.state` / `item.paused` / `item.error` / `item.canResume` / `item.filename`（绝对本地路径）。（✓2026-10-06｜[E1]）
5. **收状态迁移事件**：`chrome.downloads.onChanged` 携带 `DownloadDelta`（**不含 `bytesReceived`、不含 `estimatedEndTime`**）；`onCreated` 在下载开始时给完整 `DownloadItem`。（✓2026-10-06｜[E1][E2]）
6. **操纵**：`pause(id)` / `resume(id)` / `cancel(id)` / `removeFile(id)` / `erase(query)` / `show(id)` / `showDefaultFolder()`。（✓2026-10-06｜[E1]）
7. **收尾**：`state: "complete"` + `filename` 为最终绝对路径；或 `state: "interrupted"` + `error`（`InterruptReason` 枚举）。（✓2026-10-06｜[E1]）

### 2.2 事件注册（MV3 特有，必须照做）

事件监听器**必须在 SW 顶层同步注册**：*"Event handlers in service workers need to be declared in the global scope, meaning they should be at the top level of the script and not be nested inside functions. This ensures that they are registered synchronously on initial script execution, which enables Chrome to dispatch events to the service worker as soon as it starts."*（✓2026-10-06｜[E15]）

### 2.3 与 DNR 的相互作用（本途径的核心疑点，独立核实结果）

附录 A 声称「`chrome.downloads` 触发的下载会无视修改请求头的 DNR」。**执行结论**：

1. **官方文档中不存在任何地方描述 `chrome.downloads` 与 DNR 的关系**——既没有肯定句，也没有否定句。我核对了 downloads 参考页、DNR 参考页全文（含 Rule evaluation / ResourceType / RuleCondition / modifyHeaders / header modification 各节）、webRequest 参考页、MV3 已知问题页：**零命中**。（✓2026-10-06｜[E1][E13]）
2. **能查到的唯一直接证据是社区经验**：Stack Overflow 77932227（2024-02-03，Chrome 121）：从 **MV3 service worker** 调 `chrome.downloads.download()` 时 `modifyHeaders` 规则不生效，而同一规则对页面 `fetch` 有效；无任何回答，评论只有「It's a bug in Chrome.」。（✓2026-10-06｜[E18]）
3. **源码级独立核实（Chromium main）给出一个更精确、且与社区经验一致的结论——它是上下文相关的**：

   | 调用方上下文 | 是否有 `RenderFrameHost` | 下载是否经过 DNR 代理 | 结论 |
   |---|---|---|---|
   | MV3 service worker（扩展后台） | **无** | **否** | DNR（含 `modifyHeaders`）**不生效** |
   | 扩展页面 / popup / 标签页里的扩展文档 | **有** | **是** | DNR **生效**（含 `modifyHeaders`） |

   链条（每步均给文件与行号，✓2026-10-06）：
   - `chrome.downloads.download()` 的实现里，若 `render_frame_host()` 为空（**源码注释原文：`// Service-worker-based extensions may have no associated rfh.`**）则构造无 frame 的 `DownloadUrlParameters`，只 `set_render_process_host_id(source_process_id())`，**不设 routing id**（[E4]，`chrome/browser/extensions/api/downloads/downloads_api.cc`）。
   - `DownloadUrlParameters` 的默认 frame routing id 是 **-1**（[E11]，`components/download/public/common/download_url_parameters.cc`）；而有 frame 时 `RenderFrameHostImpl::CreateDownloadUrlParameters` 会同时传 `GetProcess()->GetDeprecatedID()` 与 `GetRoutingID()`（[E10]，`content/browser/renderer_host/render_frame_host_impl.cc:8730`）。
   - `DownloadManagerImpl::BeginResourceDownloadOnChecksComplete` 用 `RenderFrameHost::FromID(params->render_process_host_id(), params->render_frame_host_routing_id())` 反查 frame，**查不到即 `rfh == nullptr`**（[E9]，`content/browser/download/download_manager_impl.cc`）。
   - 工厂构造 `CreatePendingSharedURLLoaderFactory(storage_partition, rfh)` **只有 `rfh` 非空时才调用 `WillCreateURLLoaderFactory(..., URLLoaderFactoryType::kDownload, ...)`**；`rfh` 为空时直接退化为浏览器进程工厂（[E9]）。而 `StoragePartitionImpl` 内部**从不**调用 `WillCreateURLLoaderFactory`（[E28]，`content/browser/storage_partition_impl.cc`，全文 grep 无命中）。
   - DNR 规则的匹配**只发生在** `ExtensionWebRequestEventRouter::OnBeforeRequest → RulesetManager::EvaluateBeforeRequest` 与 `OnHeadersReceived → EvaluateRequestWithHeaders`（[E8]，`extensions/browser/api/web_request/extension_web_request_event_router.cc:1020-1036, 1250-1257`），而该 event router 只由 WebRequestAPI 代理驱动；代理的安装点**唯一**是 `ChromeContentBrowserClient::WillCreateURLLoaderFactory → WebRequestAPI::MaybeProxyURLLoaderFactory`（[E6]，`chrome/browser/chrome_content_browser_client.cc:6828-6866`；[E7]，`extensions/browser/api/web_request/web_request_api.cc:780, 835`）。
   - `URLLoaderFactoryType::kDownload` 是内容层明确定义的枚举值（注释 `// For downloads.`），且 `WillCreateURLLoaderFactory` 的契约明确说：*"An opaque origin is passed currently for navigation (kNavigation) and download (kDownload) factories even though requests from these factories can have a valid `network::ResourceRequest::request_initiator`."*（[E5]，`content/public/browser/content_browser_client.h:1843-1871, 1912`）。

4. **附带结论（对附录 A 机制直接有用）**：下载请求在 webRequest / DNR 眼里是 **`other`** 资源类型——`ToWebRequestResourceType(request, is_download)` 中 `if (is_download) return WebRequestResourceType::OTHER;`（[E12]，`extensions/browser/api/web_request/web_request_info.cc:176-184`）。因此**任何想命中下载请求的 DNR 规则，`resourceTypes` 必须包含 `"other"` 或不写 `resourceTypes`**；DNR 的 `ResourceType` 枚举里根本没有 `"download"`（[E13]）。
5. **反面约束**：DNR 规则必须**先于请求存在**。Chrome DevRel（Oliver Dunk）在 chromium-extensions 官方群组的回答：*"I'm afraid that adding dynamic headers isn't currently something the API supports."*——在 `webRequest` 回调里现加规则**不会**作用于该在途请求（✓2026-10-06｜[E25]）。

> 因此，把附录 A 的说法改写成可复核的形式应是：**「从 MV3 service worker 调用的 `chrome.downloads.download()` 不经过 DNR 的 request-header 修改（也不经过 DNR 的其它匹配），因为该路径不安装 webRequest/DNR 代理；从有帧的扩展上下文调用时则会经过。」** 这一改写是 **源码级结论，非官方文档承诺**，属 §7 存疑项。

---

## 3 硬约束（不可逾越的墙，逐条给证据）

### 3.1 落盘位置：只能给「相对 Downloads 目录」的路径，绝对路径直接报错

- 文档明文：`filename` = *"A file path relative to the Downloads directory to contain the downloaded file, possibly containing subdirectories. **Absolute paths, empty paths, and paths containing back-references ".." will cause an error.**"*（✓2026-10-06｜[E1][E2]）
- 源码实现（更细）：`downloads_api.cc` 先 `base::ReplaceChars(*options.filename, "%", "_", &filename)`（**`%` 被替换成 `_`**，源码注释 `// Strip "%" character as it affects environment variables.`），再 `net::IsSafePortableRelativePath()` 校验，失败即返回错误串 `"Invalid filename"`（`download_extension_errors::kInvalidFilename`）。（✓2026-10-06｜[E4][E26]）
- `onDeterminingFilename` 的 `suggest()` 走同一条约束：*"Absolute paths, empty paths, and paths containing back-references ".." will be **ignored**"*（注意这里是静默忽略，不是报错）。（✓2026-10-06｜[E1][E2]）
- **结果**：`R13` 允许用户「调整默认参数（例如保存目录）」——在 chrome.downloads 路线上**无法实现**绝对保存目录；只能做到「Downloads 目录之下的子目录」这一档。（对照 §6 R13）

### 3.2 请求头：只能设「XHR 允许的头」，敏感头一律被拒（这是硬墙，有源码白名单）

- 文档明文：`headers` = *"Extra HTTP headers to send with the request if the URL uses the HTTP[s] protocol. … **restricted to those allowed by XMLHttpRequest.**"*（✓2026-10-06｜[E1][E2]）
- **源码实现给出了确切黑名单**（`net::HttpUtil::IsSafeHeader()`，`net/http/http_util.cc`，✓2026-10-06｜[E3]）：
  - 名称以 `proxy-` 或 `sec-` 开头 → 拒绝（大小写不敏感）；
  - 命中 `kForbiddenHeaderFields` 中的任一项 → 拒绝。**完整列表（原文照录）**：
    `accept-charset, accept-encoding, access-control-request-headers, access-control-request-method, connection, content-length, cookie, cookie2, date, dnt, expect, host, keep-alive, origin, referer, set-cookie, te, trailer, transfer-encoding, upgrade, user-agent, via`
  - `x-http-method` / `x-http-method-override` / `x-method-override` 的头值里出现 `connect / trace / track` → 拒绝。
  - ⇒ **`Cookie`、`Referer`、`Origin`、`User-Agent`、`Host`、`Content-Length` 全部在硬黑名单里，无法通过 `headers` 设置。为什么？因为该 API 复用了网络栈里给 XHR/fetch 用的「安全头」判定（Fetch 规范的 forbidden header 集），而不是给扩展留的后门。**
- 调用方看到的错误（源码串）：名称非法 → `"Invalid request header name"`；名字/值不安全 → `"Unsafe request header name"`；值非法 → `"Invalid request header value"`。（✓2026-10-06｜[E4][E26]）
  ⚠️ 但官方文档明确警告：*"The error strings are not guaranteed to remain backwards compatible between releases. **Extensions must not parse it.**"*（[E1]）⇒ 这些串**不可用于错误映射**，只能用于人工排障。
- **Cookie 的替代来源**：`download()` 文档明文 *"If the URL uses the HTTP[S] protocol, then the request will include all cookies currently set for its hostname."*（✓2026-10-06｜[E1]）⇒ **浏览器里已有的 Cookie 会自动带**，`withHeader` 里「注入自定义 Cookie」这一条做不到。
- `binaryValue` 的歧义（⚠️）：`headers` 的注释说每个头含 `name` 与 `value` **或 `binaryValue`**（[E1][E2]），但**当前 WebIDL 里 `HeaderNameValuePair` 只定义了 `name` 与 `value` 两个成员**（[E2]）。⇒ `binaryValue` 疑似文档/IDL 不同步，**未验证**（§7）。
- 方向性补充：把请求头「加进去」的合法途径在**另一条途径**（DNR）上，但 DNR 的 `append` 操作只支持一个固定白名单（`accept, accept-encoding, accept-language, access-control-request-headers, cache-control, connection, content-language, **cookie**, forwarded, if-match, if-none-match, keep-alive, range, te, trailer, transfer-encoding, upgrade`），`set`/`remove` 不受该白名单限制（✓2026-10-06｜[E13]）。这解释了附录 A 为什么绕道 DNR。

### 3.3 没有 waiting / 排队态；没有限速；没有多连接；没有校验和

- `State` 枚举只有三值：`"in_progress"` / `"interrupted"` / `"complete"`（✓2026-10-06｜[E1][E2]）⇒ aria2 的 `waiting` 必须由 Mock 层自己伪造/维护，浏览器侧不存在「排队但不开始」的状态。
- 没有任何速率控制、连接数、分片（`split`）、`max-connection-per-server` 对应字段（`DownloadOptions` 全文只有 `url / filename / conflictAction / saveAs / method / headers / body`）。（✓2026-10-06｜[E1][E2]）
- 有 `body` 与 `method: POST` 支持（[E1][E2]），但**没有独立的「下载多个文件 / 只下载压缩包中某几个文件」能力**。

### 3.4 危险下载：判定不可编程、接受必须有人在场

- `DownloadItem.danger` 是 `DangerType` 枚举，含 `"file"`、`"url"`、`"content"`、`"uncommon"`、`"host"`、`"unwanted"`、`"safe"`、`"accepted"` 以及一批 Safe Browsing / 企业策略相关值（`"deepScannedFailed"`, `"sensitiveContentBlock"`, `"blockedTooLarge"`, `"forceSaveToGdrive"` …）。（✓2026-10-06｜[E1]）
- 接受危险下载的 API：`acceptDanger(downloadId)` —— *"Prompt the user to accept a dangerous download. **Can only be called from a visible context (tab, window, or page/browser action popup).** Does not automatically accept dangerous downloads."*（✓2026-10-06｜[E1][E2]）
  ⇒ **MV3 service worker 里无法调用 `acceptDanger`** ⇒ 无人值守场景下，被判危险的下载会**停在半路**（数据先落在临时文件，直到「不危险或危险被接受」才改名并置 `complete`）。
- 中断原因里有 `FILE_VIRUS_INFECTED`、`FILE_BLOCKED`、`FILE_SECURITY_CHECK_FAILED`、`FILE_TOO_LARGE`（✓2026-10-06｜[E1]）。
- 面向用户的行为：*"Chrome automatically blocks dangerous downloads…"*；被拦的项 **1 小时后**从下载历史自动移除（"If you take no action, Chrome will remove it from your history in one hour."）（✓2026-10-06｜[E24]）。
- 交叉约束：DNR 也无法凭扩展意志扭转浏览器侧的处理策略——官方 issue 40256297（Chrome 109）中，「用 DNR 给 PDF 响应加 `Content-Disposition: attachment` 强制下载」被报告为不生效（规则计数徽标显示命中）；issue 状态未核实为已修复（✓2026-10-06｜[E13]，见 §7 #11）。

### 3.5 浏览器设置会直接改写结果（不可编程、不可读）

- 若浏览器开启「下载前询问每个文件的保存位置」，扩展无法关闭它；`saveAs: true` 或 `conflictAction: "prompt"` 会弹系统对话框（✓2026-10-06｜[E1]：*"The user will be prompted with a file chooser dialog."* / *"Use a file-chooser to allow the user to select a filename regardless of whether `filename` is set or already exists."*）。〔推断〕「扩展无法关闭该浏览器设置」是从「无任何相关 API」推断的，非文档明文。
- 社区报告（**未验证**）：从 service worker 调 `downloads.download({saveAs:true})`，在该设置开启时，下载会**静默变成 `interrupted` / `USER_CANCELED`**，对话框根本没有出现，且 `chrome.runtime.lastError` 为 undefined（SO 69776708，2021，Chrome ≈95，**无回答**）。⚠️ 单点报告、年代较早，必须在目标 Chrome 上复测（✓2026-10-06 检索｜[E27]）。

### 3.6 生命周期：下载本体不受 SW 回收影响，但「扩展侧的状态机」会被回收打断

- SW 回收的官方判据：*"After 30 seconds of inactivity. Receiving an event or calling an extension API resets this timer. / When a single request, such as an event or API call, takes longer than 5 minutes to process. / When a fetch() response takes more than 30 seconds to arrive."*；并且 *"if the service worker has gone dormant, an incoming event will revive them"*；兜底要求 *"you should design your service worker to be resilient against unexpected termination"*，全局变量会丢失、应写 storage。（✓2026-10-06｜[E14]）
- **下载本体**：由浏览器下载子系统执行（§2.1 步骤 3），不依赖扩展 SW 存活；`DownloadItem.id` 文档明文 *"An identifier that is persistent across browser sessions."*（[E1]）⇒ 浏览器重启后仍可 `search({id})`。⚠️ **「SW 回收后下载继续」这一句话本身没有官方明文**，属架构推断（§7）。
- **事件是否还会送达**：结论是**会**，而且有 2026 年的 Chromium 测试为证——issue 40878315「The listener of downloads.onChanged is not running when Service Worker is inactive (MV3)」（Chrome 107 报告）已在 **2026-08-27** 被 commit `0800948c9d63d39244ad3012191105689d49ed1b` 关闭，提交信息原文：*"After this CL, a browser test is added to verify that `chrome.downloads.onChanged` wakes up an inactive Manifest V3 service worker and correctly records the event timestamp and delta in storage. The reported issue appears to have been resolved by prior work on service worker event dispatching."*（✓2026-10-06｜[E16]）
  ⇒ **修好得很晚**：在 2026-08 之前的 Chrome 上，SW 休眠期间的 `onChanged` 可能丢失；把「任务完成」这种关键状态只挂在事件上是不安全的。
- **`onCreated` 的陷阱**：issue 451089037（Chrome 141 stable，Windows）报告 *"`chrome.downloads.onCreated.addListener` get fires with previous DownloadItems including when `DownloadItem` state being `'complete'` or `'interrupted'` when chrome launches."*——**浏览器启动时 `onCreated` 会为历史下载项再次触发**。若用 `onCreated` 做「新任务」判定，会把旧任务当成新任务。（✓2026-10-06｜[E17]，issue 状态未核实）

### 3.7 上下文可用性矩阵（本途径的核心视角）

| 执行上下文 | `chrome.downloads` 可用？ | 证据 |
|---|---|---|
| MV3 extension service worker | ✅ 可用（主战场） | [E1][E4]（实现里显式处理 SW 无 frame 的分支） |
| 扩展页面（含内置 AriaNg UI 页） | ✅ 可用（有 frame ⇒ 还能被 DNR 命中，§2.3） | [E1][E4] |
| popup / 扩展 action 弹窗 | ✅ 可用；且**只有这类可见上下文**才能 `acceptDanger` / `open` | [E1][E2] |
| **offscreen document** | ❌ **不可用** | *"The `runtime` API is the only extensions API supported by offscreen documents."*（[E19]）；官方博客同义表述："only the `chrome.runtime` messaging APIs are exposed to the offscreen document"（[E19]） |
| content script（ISOLATED world） | ❌ 不可直接调用 | 官方可用 API 列表仅 `dom, i18n, storage, runtime.connect(), runtime.getManifest(), runtime.getURL(), runtime.id, runtime.onConnect, runtime.onMessage, runtime.sendMessage()`，并明确 *"Content scripts are unable to access other APIs directly. But they can access them indirectly by exchanging messages with other parts of your extension."*（[E20]）⇒ 只能消息转发到 SW/扩展页 |
| MAIN world 注入脚本 | ❌ 不可用 | MAIN world = *"the main world of the DOM, which is the execution environment shared with the host page's JavaScript"*（[E21]），即页面 JS 环境，没有扩展 API 绑定 |
| 页面内的普通 Web Worker / 扩展页派生的 Worker | ❌（**未验证**，见 §7） | 未找到官方明文列举 Worker 的可用 API；但 content script 与 offscreen 的文档模式（白名单 + 「runtime 是唯一」）一致指向不可用。**不要凭此下设计结论，需实测** |
| 沙箱化 iframe（manifest `"sandbox"`） | ❓ 未知 | 未找到官方文档对 `chrome.downloads` 在此上下文的说明（§7） |

---

## 4 能力映射（这条途径能支撑哪些原子能力；逐条标 能 / 不能 / 有条件）

> 下表是**给后续「能力清单」的输入草案**，能力名沿用 R11 给的示例风格（`multithread` / `withHeader` / `memUnlimited`），其余为我方按 aria2 语义补的候选名，**并非已裁定的枚举**。判定以「结果能否兑现」（R10）为准。

| # | 候选原子能力 | 判定 | 依据 / 边界 |
|---|---|---|---|
| 1 | `httpDownload`（单连接 HTTP(S) 下载） | **能** | `download(options)` 返回 id 即开始。[E1] |
| 2 | `postDownload`（POST 请求体下载） | **能** | `HttpMethod` 只有 `"GET"`/`"POST"`；`DownloadOptions.body` 存在。[E1][E2] |
| 3 | `realProgress`（真实进度） | **能，但要轮询** | `bytesReceived` / `totalBytes`（未知时 `-1`）只有通过 `search()` 拿；`onChanged` **明确不含**这两个字段。[E1][E2] |
| 4 | `pauseResume` | **有条件** | `pause()` 要求下载处于 active，否则失败；`resume()` 要求 **`canResume === true`**（`DownloadItem.canResume`：*"True if the download is in progress and paused, or else if it is interrupted and can be resumed starting from where it was interrupted."*）；源码里 `resume()` 对「未暂停」是 **no-op 但回报成功**（注释原文：*"Note that if the item isn't paused, this will be a no-op, and the extension call will seem successful."*）。[E1][E4] |
| 5 | `cancel`（取消） | **能** | `cancel(id)`：*"the download is cancelled, completed, interrupted or doesn't exist anymore"*。[E1] |
| 6 | `remove`（从列表移除） | **能，需两步** | `cancel()`（停）+ `erase({id})`（**只清历史不删文件**）；若要删文件另调 `removeFile(id)`（**仅 `complete` 时可删**）。没有「一步删除」。`onErased` 会触发。[E1] |
| 7 | `retry`（重试） | **不能直接做，只能有条件重发** | 无 `retry` API。`resume()` 只在 `canResume` 为真时续传；否则只能**新建一次 `download()`（新 id、新任务）**——对 aria2 的 `gid` 语义是破坏性的。[E1][E4] |
| 8 | `fileRename`（决定文件名） | **有条件** | `filename` 只能是相对 Downloads 目录的路径；`onDeterminingFilename` + `suggest()` 只能**建议**，且：*"If more than one extension overrides the filename, then the last extension installed whose listener passes a suggestion object to suggest wins."*；有 15 秒超时（源码 `determine_filename_timeout_ = base::Seconds(15)`）；每个扩展**最多注册一个监听器**（WebIDL `[maxListeners=1]`）。[E1][E2][E4] |
| 9 | `folderControl`（决定保存目录） | **不能（绝对路径）** | §3.1。只能选 Downloads 目录下的子目录。[E1][E4][E26] |
| 10 | `withHeader`（自定义请求头） | **有条件（弱）** | 只能设 XHR 允许的头；`Cookie`/`Referer`/`Origin`/`User-Agent` 等一律被拒。非敏感头（如 `Authorization`、`Accept-Language`、自定义 `X-*`）可设。[E1][E3] |
| 11 | `cookie`（自定义 Cookie） | **不能** | §3.2。只有「浏览器已有的 Cookie 会自动带上」。[E1] |
| 12 | `multithread`（多连接 / 分片） | **不能** | §3.3。没有任何分片/连接数字段。[E1][E2] |
| 13 | `rangeResume`（断点续传） | **有条件** | 取决于服务端是否支持 Range 与 `canResume`；浏览器内部会续传，但扩展**不能自己指定 Range 起止**（`Range` 不在黑名单里，但能否通过 `headers` 生效**未验证**，§7）。中断原因含 `SERVER_NO_RANGE`。[E1][E3] |
| 14 | `speedLimit`（限速） | **不能** | 无对应 API。[E1][E2] |
| 15 | `queueWait`（排队 / `waiting` 态） | **不能（浏览器侧）** | `State` 无 waiting。[E1] Mock 层需自行维护排队语义。 |
| 16 | `dangerOverride`（自动接受危险下载） | **不能（SW 内）** | §3.4，`acceptDanger` 仅限可见上下文。[E1][E2] |
| 17 | `uiSuppress`（隐藏浏览器下载 UI） | **能，需额外权限** | `setUiOptions({enabled:false})` 需 `"downloads.ui"` 权限（Chrome 105+）；`setShelfEnabled` 自 Chrome 117 起 deprecated。任一扩展关掉即全体隐藏。[E1][E22] |
| 18 | `openFile` / `showInFolder` | **有条件** | `open()` 还需 `"downloads.open"` 权限，且 *"can only be called in response to a user gesture"*；`show()` / `showDefaultFolder()` 无手势要求。[E1][E22] |
| 19 | `persistAcrossRestart`（任务跨浏览器重启持久） | **能** | `id` *"persistent across browser sessions"*；`search({id})` 可回查。[E1] |
| 20 | `observeAllDownloads`（看到全部下载，不只本扩展发起的） | **能** | 事件通过 `DispatchEvent` 派发给所有注册监听的扩展；`DownloadItem.byExtensionId` 是**可选**字段（仅当由扩展发起时才有）。⇒ 引擎必须自己过滤，否则会看到用户手点的下载。[E1][E4] |
| 21 | `checksum` / `bt` / `metalink` / `multiSource` | **不能** | API 表面无任何对应物。[E1][E2] |
| 22 | `memUnlimited`（内存不受限） | **不适用（天然满足）** | 数据不经扩展进程内存，由浏览器直接落盘。[E1][E9]〔推断〕 |
| 23 | `headerEcho`（读取响应头 / Content-Disposition） | **不能直接读** | API 只回吐解析后的 `mime` / `totalBytes` / `filename`，无「响应头字典」。[E1] |
| 24 | `perFileSelection`（只下压缩包里的部分文件，aria2 `--select-file`） | **不能** | 无对应 API。[E1] |

---

## 5 失败模式与盲区

### 5.1 「静默失信」类（最危险：调用成功但结果不是用户期待的）

| 模式 | 机制 | 证据 |
|---|---|---|
| `resume()` 对未暂停项返回成功但什么都没做 | 源码注释明说 "if the item isn't paused, this will be a no-op, and the extension call will seem successful." | [E4] |
| `saveAs: true` / `conflictAction: "prompt"` 在无 UI 场景下**下载中断且无 lastError** | 社区报告：dialog 未出现，`state=interrupted`、`error=USER_CANCELED`、`chrome.runtime.lastError === undefined` | [E27]（未验证） |
| 下载成功「入队」≠ 结果兑现 | `download()` 只保证「开始」；之后可能 `interrupted` | [E1] |
| `erasedFromHistory` 与「文件还在」的错位 | `erase()` 只清历史；`exists` 字段自身**可能过期**（*"This information may be out of date because Chrome does not automatically watch for file removal"*） | [E1] |

### 5.2 事件与生命周期盲区

- **`onChanged` 拿不到 `bytesReceived`**（文档明文排除该字段与 `estimatedEndTime`）⇒ 进度只能轮询，**事件驱动的进度上报在物理上不可能**。[E1][E2]
- **SW 休眠期间事件丢失是「曾经的 bug、2026-08 才修好」**：判据是 commit `0800948c9d63`（2026-08-27）。在早于该修复的 Chrome 上，`onChanged` 不会唤醒休眠 SW。（§3.6）[E16]
- **`onCreated` 在浏览器启动时会对历史项重放**（Chrome 141 报告）⇒ 任务重建逻辑必须用 `id` + `startTime` + `state` 去重，不能只信事件。[E17]
- **`onDeterminingFilename` 有 15 秒超时**，且*「最后一安装的扩展胜出」*；监听器未按时 `suggest()` 会被自动代答。[E1][E4]
- **SW 被回收会丢掉一切内存状态**（含未 resolve 的 Promise）⇒ Q-D5 已裁定「状态必须持久化、不得依赖 SW 内存」，本途径完全支持这一裁定，但**不能反过来把 SW 常驻当作设计前提**。[E14]
- **未验证**：SW 在 `download()` 调用返回前被回收 ⇒ Promise 丢失（§7）。

### 5.3 用户设置与安全策略盲区（扩展不可编程、不可读）

- 下载目录、是否「每次询问保存位置」、Safe Browsing 严格程度、企业策略（`forceSaveToGdrive` / `forceSaveToOnedrive` / `allowlistedByPolicy` 等 DangerType 就是企业策略的产物）——**这些都在浏览器/策略侧，扩展只能观察到 DangerType 与最终路径**。[E1][E24]
- 危险判定是**异步**的：数据先落临时文件，直到「不危险或已被接受」才改名为目标文件名并置 `complete` ⇒ 中途看到 `state: in_progress` 不代表内容会被保留。[E1][E2]
- `chrome://downloads`、下载气泡/下载架是**浏览器 UI**，扩展只能整体开关（`setUiOptions`），不能自定义。[E1]

### 5.4 排他性与观察面

- 扩展**看不到**下载是否由自己发起以外的方式触发（`byExtensionId` 为空即代表非本扩展发起）⇒ 需要过滤。[E1]
- 一个 profile 内**多个扩展**都在观察同一份下载列表；都能用 `onDeterminingFilename` 抢文件名。[E1][E2]
- **无并发上限文档**：能同时发起多少下载、会不会被节流，官方文档未说明（§7）。

### 5.5 与 DNR 的相互作用（再强调一次，因为这是本途径最容易被误判的一条）

- 从 **SW** 发起 ⇒ DNR 完全看不到该请求（§2.3）⇒ **「用 DNR 给某次下载注入头」这条路在 SW 上下文里走不通**。
- 从**扩展页面**发起 ⇒ DNR 能看到（资源类型 = `other`）⇒ 可以改头，包括加 `Cookie`（`append` 白名单里有 `cookie`）[E13]。
- ⇒ 这条差异**只影响「头注入」的可用性，不影响 aria2 `header` 能力的语义**；但意味着实现层面「同一份 DNR 规则，在不同调用上下文中行为不同」，是**极难排查**的一类 bug（社区报告者本人就卡在这里，[E18]）。

---

## 6 与现有裁定的冲突（逐条对照 R1–R13 与附录 A）

> 判定口径：**是否被推翻 / 是否需要改口径 / 是否原样成立**。

| 裁定 | 与 chrome.downloads 的关系 | 判定 |
|---|---|---|
| **R1** 转接到浏览器下载能力 | chrome.downloads 就是「浏览器自身下载能力」的**官方控制面**，是最直接的兑现 | ✅ 成立，且是 R1 最字面的实现 |
| **R2** 不支持就报错 | 本途径**做不到**的能力很多（§4 的 10/11/12/14/15/16/21/24…）。只要 Mock 层按 §4 如实返回错误，R2 可满足。**风险在于有若干「返回成功但静默失真」的坑（§5.1）**，实现时必须把这些坑显式转成错误或显式降级 | ✅ 成立，**但对实现提出硬要求**（§5.1 四条必须处理） |
| **R3 / R10** 三值语义、以「结果是否兑现」为判据 | 单连接 HTTP 下载**结果真的会发生**（文件真落盘）⇒ `multithread` 走「伪装还原」是正当的（R10 明说：真实结果会发生、只是过程/字段与 aria2 不完全一致）。但「发现断点续传失败」「危险下载被拦」这类**最终拿不到文件**的情况必须走「不实现/报错」。 | ✅ 成立；**「伪装还原」的边界被本途径钉死在「文件确实被下载下来」上** |
| **R4 / R5** 转发器与内置 UI | 与本途径正交（那是第一层的事）。仅一点相关：**内置 AriaNg UI 作为扩展页面调用 chrome.downloads 时，DNR 会生效**（§2.3），而 SW 不会 ⇒ 同一条能力在「UI 路径」和「后台路径」行为不同，**可能违反 R5「UI 不得走特殊通道」的精神**（不是违反条文，但是隐患） | ⚠️ 未被推翻；**新增一个必须被记录的差异点**（建议升级为待裁定项） |
| **R6** Mock 层逐接口还原 | 本途径提供的数据面很窄：**没有响应头、没有多连接、没有 waiting 态、没有 checksum**。`aria2.getFiles` / `tellStatus` 的 `connections` 数组、`files[].uris` 之类必须由 Mock 层合成（属伪装还原） | ✅ 成立；**输入面比 aria2 窄得多**，是后续「还原度文档」的主要工作量 |
| **R7 / R11** 引擎声明原子能力 | §4 的 24 条即能力清单草案。**注意 R11 要求「原子能力只有 bool，不表达数值」**——本途径的「`folderControl` 只能到子目录」「`withHeader` 只支持非敏感头」都是**部分可用**，按 Q-B8 只能拆成更细的 bool 或整条判否（例如 `folderControlAbsolute: false`、`withHeaderSensitive: false`） | ✅ 成立；**但暴露 Q-B8 布尔模型的已知代价**（R11/Q-B8 已承认） |
| **R8** 无法监听端口、只服务浏览器内 JS 客户端 | 完全一致，无冲突 | ✅ 成立 |
| **R9** 拦截发生在 JS API 层 | 正交。**但 §2.3 揭示了一个此前未记录的层次交互**：DNR 属网络层，chrome.downloads 属浏览器 API 层，两者是否见面取决于「有没有 frame」 | ✅ 成立；**新增认知，不冲突** |
| **R12** 同时只启用一个引擎 | 无冲突 | ✅ 成立 |
| **R13** 用户可启用/禁用、**调整默认参数（例如保存目录）**、查看能力报告 | **部分被推翻**：chrome.downloads 路线**无法让用户指定绝对保存目录**，最多是「Downloads 目录下的子目录」（§3.1） | ⚠️ **需要改口径**：R13 第 2 项在本途径上只能降级为「相对子目录 + 是否询问保存位置」，需要在能力清单里显式声明 |
| **Q-B7** 进度姿态（能拿真实进度就报真实进度，不许伪造曲线） | **本途径正好落在 Q-B7 的「引擎能拿到真实进度」分支**：`search()` 可回读 `bytesReceived` / `totalBytes`。Q-B7 补充裁定里的例子（`chrome.downloads` + `bytesReceived`/`totalBytes`）就是本途径 | ✅ 成立，且**强制真实进度**（代价：必须轮询） |
| **Q-C4 / Q-B5** 运行期错误 | 可满足：权限未授予 / 危险下载需人工 / 无可见上下文等都能映射为「引擎侧自定义失败结果」。注意 `download()` 的 `lastError` 串**被文档禁止解析**（[E1]）⇒ 引擎必须自己维护错误分类，不能靠字符串 | ✅ 成立，**但要自己维护错误码表** |
| **Q-C5** 有活动任务时禁止切换引擎 | 本途径的「活动任务」判据很清楚：`search({state:"in_progress"})` + `paused` 非空；但**注意 `onCreated` 重放 bug**（§5.2）会让「任务数」统计出错 | ✅ 成立，**依赖 §5.2 的去重实现** |
| **Q-D5** 持久化、SW 重启不模拟重启 | `DownloadItem.id` 跨浏览器会话持久（[E1]）⇒ 支持；但**必须自己把「任务 ↔ id 的映射」写进扩展存储**，不能放 SW 内存（文档明文 [E14]） | ✅ 成立 |
| **附录 A（用户样例）** | A.3 的说法「chrome.downloads 触发的下载会无视修改请求头的 DNR」——**独立核实结果见 §2.3**：① 官方无任何明文；② 唯一直接证据是社区报告 [E18]；③ **源码级结论是该说法只在「由 service worker 发起」时成立**，由扩展页面发起时 DNR 会生效。A.1 的动机句「chrome.downloads 不支持敏感 header」**被源码完全证实**（[E3] 黑名单含 `cookie`/`referer`/`origin`/`user-agent`）。 | ⚠️ **部分被推翻（更准确地说是被「限定条件」）**：需把 A.3 改写成 §2.3 的上下文相关表述；A.1 的动机**被证实**。另外 A.2 第 3 步「`chrome.tabs` 打开 urlA」属于 **E2 途径（导航触发下载）**，不是本途径，本轮不下结论 |

---

## 7 未验证 / 存疑

> 按「未来复核成本从高到低」排序。每条注明**为什么未验证**与**怎么验**。

| # | 存疑点 | 现状 | 建议的验证方式 |
|---|---|---|---|
| 1 | 「`chrome.downloads` 请求是否经过 DNR」的**运行时真值** | 官方零明文；SO 单点社区报告 [E18]；**源码分析得出「取决于是否有 frame」**（§2.3）。源码分析未运行时验证 | 用两个 MV3 扩展（一个从 SW 发起、一个从扩展页面发起）对同一 URL 打同一条 `modifyHeaders` 规则，抓包比对请求头 |
| 2 | 上述源码结论是否适用于**发布版 Chrome**（而非 main） | 依据是 Chromium main @`1c5c959` [E0]；发布版可能落后/含分支差异 | 在目标 Chrome 版本上重复 #1 |
| 3 | **Web Worker / Shared Worker / Service Worker（页面侧）内**是否可调 `chrome.downloads` | 未找到官方明文列举 Worker 上下文可用 API（[E20][E19] 只覆盖 content script 与 offscreen）；本文**不从文档推断为「不能」** | 实测：扩展页 `new Worker()` 内 `typeof chrome.downloads` |
| 4 | 沙箱化 iframe（`"sandbox"` manifest 键）内是否可调 `chrome.downloads` | 无官方文档 | 实测 |
| 5 | `DownloadOptions.headers` 的 `binaryValue` 是否真的可用 | 注释说有（[E1][E2]），当前 WebIDL 的 `HeaderNameValuePair` 只定义 `name`/`value`（[E2]）——疑似 IDL 与文档不同步 | 实测：传 `binaryValue` 看是否报错/被忽略 |
| 6 | 通过 `headers` 传 `Range`（不在 [E3] 黑名单里）能否真正发起分段请求 | 黑名单未含 `range`，但文档口径是「restricted to those allowed by XMLHttpRequest」，Fetch 规范里 `Range` 对 XHR 另有约束 ⇒ 两条口径冲突 | 实测 + 抓包 |
| 7 | **SW 在 `download()` 返回前被回收 ⇒ Promise 是否丢失** | 无官方明文；一般性文档只说全局变量会丢（[E14]） | 实测（在 SW 里 sleep 31s 后读结果） |
| 8 | 「SW 回收后下载继续」是否有**官方明文** | 未找到；本文结论基于「下载由浏览器子系统执行」的源码事实（[E9]） | 在文档/issue tracker 里继续找，或按 #7 实测 |
| 9 | 并发下载上限 / 是否会节流 | 官方文档完全未提 | 实测（循环发起 N 个下载） |
| 10 | 社区报告「`saveAs:true` 在 SW 中静默 `USER_CANCELED`」是否仍然成立 | SO 69776708（2021，Chrome ≈95）**无回答** [E27] | 在目标 Chrome（≥148）上复测 |
| 11 | Chromium issue 40256297（DNR 加 `Content-Disposition` 强制下载 PDF 不生效）的**当前状态** | 能取到 issue 正文（Chrome 109 报告），但 issue tracker 的 JSON 接口未提供可解析的状态字段；**无法确认是否已修复** | 在 issue 页面人工确认状态，或直接实测 |
| 12 | issue 451089037（`onCreated` 启动时重放历史项）的**当前状态** | 同上，状态未能从 JSON 解析 | 同上 |
| 13 | 各 `InterruptReason` 与 aria2 `errorCode` 的**映射表** | 本文只列出枚举本身（[E1]），未做映射（不属本轮范围） | 留给「还原度文档」 |
| 14 | Firefox 侧差异的完整清单 | 只核对了 MDN 的 `downloads.download()` 单页（差异见 §4.9 脚注：FF70+ 允许 `Referer`、有 `allowHttpErrors`/`cookieStoreId`/`incognito`、`filename` 规则表述略不同） | 若产品要跨浏览器，需另开一条途径文档 |
| 15 | 「扩展能看到非自己发起的下载」的官方明文 | 文档未直言；依据是 `byExtensionId` 为 optional（[E1]）与事件派发实现（[E4]） | 实测（用户手点下载，看扩展是否收到 `onCreated`） |
| 16 | `chrome.downloads` 权限被用户撤销后的报错形态 | 未验证；Q-C4 要求「运行期失败自定义错误码」，需要实测拿错误串**形态**（但不得解析字符串，[E1]） | 实测 |

**明确未查到的官方出处**（查不到就不猜）：

- 「chrome.downloads 与 DNR 的关系」——**Chrome 官方文档中不存在任何相关表述**（已逐页核对 [E1][E13] 及 webRequest / MV3 已知问题页）。
- 「SW 回收后下载继续」——无官方明文。
- 「Worker / 沙箱 iframe 的 API 可用性」——无官方明文。

---

## 8 证据清单（URL + 原文摘录）

> 全部于 **2026-10-06（UTC）** 核对。Chrome 官方文档页面同时给出「页面页脚最后更新日期」以便判断快照新旧。
> Chromium 源码统一取自 `https://chromium.googlesource.com/chromium/src/+/main/<path>?format=TEXT`，对应 commit **`1c5c9592bf28cc227aa41f8dfbe8d53467f8b6e4`（2026-10-06 09:51:20 UTC）**。下文 URL 用 `.../+main/<path>` 表示该仓库路径。

### [E0] Chromium main 快照
- `https://chromium.googlesource.com/chromium/src/+/main?format=JSON`
- 摘录：`"commit": "1c5c9592bf28cc227aa41f8dfbe8d53467f8b6e4"`，committer time `Tue Oct 06 09:51:20 2026`。

### [E1] Chrome Extensions API 参考 — `browser.downloads`（页面页脚：Last updated 2026-10-04 UTC）
- URL: https://developer.chrome.com/docs/extensions/reference/api/downloads
- 关键原文摘录：
  - 描述：*"Use the `chrome.downloads` API to programmatically initiate, monitor, manipulate, and search for downloads."*
  - 权限：*"You must declare the `"downloads"` permission in the extension manifest to use this API."*
  - `download()`：*"Download a URL. If the URL uses the HTTP[S] protocol, then the request will include all cookies currently set for its hostname. If both `filename` and `saveAs` are specified, then the Save As dialog will be displayed, pre-populated with the specified `filename`. … If there was an error starting the download, then `callback` will be called with `downloadId=undefined` and `runtime.lastError` will contain a descriptive string. **The error strings are not guaranteed to remain backwards compatible between releases. Extensions must not parse it.**"*
  - `DownloadOptions.filename`：*"A file path relative to the Downloads directory to contain the downloaded file, possibly containing subdirectories. **Absolute paths, empty paths, and paths containing back-references ".." will cause an error.**"*
  - `DownloadOptions.headers`：*"Extra HTTP headers to send with the request if the URL uses the HTTP[s] protocol. Each header is represented as a dictionary containing the keys `name` and either `value` or `binaryValue`, **restricted to those allowed by XMLHttpRequest**."*
  - `DownloadOptions.saveAs`：*"Use a file-chooser to allow the user to select a filename regardless of whether `filename` is set or already exists."*
  - `DownloadOptions.method` / `HttpMethod`：*"The HTTP method to use if the URL uses the HTTP[S] protocol."*；枚举 `"GET"` / `"POST"`。
  - `FilenameConflictAction`：`uniquify` = *"To avoid duplication, the `filename` is changed to include a counter before the filename extension."*；`overwrite` = *"The existing file will be overwritten with the new file."*；`prompt` = *"The user will be prompted with a file chooser dialog."*
  - `DownloadItem.bytesReceived`：*"Number of bytes received so far from the host, without considering file compression."*
  - `DownloadItem.totalBytes`：*"Number of bytes in the whole file, without considering file compression, or -1 if unknown."*
  - `DownloadItem.state`：*"Indicates whether the download is progressing, interrupted, or complete."*；枚举 `"in_progress"` / `"interrupted"` / `"complete"`。
  - `DownloadItem.paused`：*"True if the download has stopped reading data from the host, but kept the connection open."*
  - `DownloadItem.canResume`：*"True if the download is in progress and paused, or else if it is interrupted and can be resumed starting from where it was interrupted."*
  - `DownloadItem.error`：*"Why the download was interrupted. … errors relating to the process of writing the file to the file system begin with FILE_, and interruptions initiated by the user begin with USER_"*（`InterruptReason` 枚举见页面 Types）。
  - `DownloadItem.id`：*"An identifier that is persistent across browser sessions."*
  - `DownloadItem.filename`：*"Absolute local path."*
  - `DownloadItem.byExtensionId`：*"The identifier for the extension that initiated this download if this download was initiated by an extension. Does not change once it is set."*
  - `DownloadItem.exists`：*"… Also, `search()` may be called as often as necessary, but **will not check for file existence any more frequently than once every 10 seconds**."*
  - `onChanged`：*"When any of a `DownloadItem`'s properties **except `bytesReceived` and `estimatedEndTime`** changes, this event fires with the `downloadId` and an object containing the properties that changed."*
  - `onCreated`：*"This event fires with the `DownloadItem` object when a download begins."*
  - `onDeterminingFilename`：*"During the filename determination process, extensions will be given the opportunity to override the target `DownloadItem.filename`. **Each extension may not register more than one listener** for this event. Each listener must call `suggest` exactly once, either synchronously or asynchronously. … The `DownloadItem` will not complete until all listeners have called `suggest`. … **If more than one extension overrides the filename, then the last extension installed whose listener passes a `suggestion` object to `suggest` wins.**"*
  - `acceptDanger()`：*"Prompt the user to accept a dangerous download. **Can only be called from a visible context (tab, window, or page/browser action popup).** Does not automatically accept dangerous downloads. … When all the data is fetched into a temporary file and either the download is not dangerous or the danger has been accepted, then the temporary file is renamed to the target filename, the `state` changes to 'complete', and `onChanged` fires."*
  - `pause()` / `resume()`：*"Pause the download. … The request will fail if the download is not active."* / *"Resume a paused download. … The request will fail if the download is not active."*
  - `cancel()`：*"Cancel a download. When `callback` is run, the download is cancelled, completed, interrupted or doesn't exist anymore."*
  - `removeFile()`：*"Remove the downloaded file if it exists and the `DownloadItem` is complete; otherwise return an error through `runtime.lastError`."*
  - `erase()`：*"Erase matching `DownloadItem` from history **without deleting the downloaded file**. An `onErased` event will fire for each `DownloadItem` that matches `query`…"*
  - `open()`：*"… This method requires the `"downloads.open"` permission in addition to the `"downloads"` permission. … **This method can only be called in response to a user gesture.**"*
  - `setUiOptions()`：*"Change the download UI of every window associated with the current browser profile. As long as at least one extension has set `UiOptions.enabled` to false, the download UI will be hidden. … Requires the `"downloads.ui"` permission in addition to the `"downloads"` permission."*
  - `setShelfEnabled()`：*"Deprecated since Chrome 117. Use `setUiOptions` instead."*
  - `search()`：*"… To get a specific `DownloadItem`, set only the `id` field. To page through a large number of items, set `orderBy: ['-startTime']`, set `limit` to the number of items per page, and set `startedAfter` to the `startTime` of the last item from the last page."*
  - `DownloadQuery.limit`：*"The maximum number of matching `DownloadItem` returned. Defaults to 1000. Set to 0 in order to return all matching `DownloadItem`."*
  - `FilenameSuggestion.filename`：*"… as a path relative to the user's default Downloads directory, possibly containing subdirectories. **Absolute paths, empty paths, and paths containing back-references ".." will be ignored.** `filename` is ignored if there are any `onDeterminingFilename` listeners registered by any extensions."*
  - `DangerType` 枚举：`file / url / content / uncommon / host / unwanted / safe / accepted / allowlistedByPolicy / asyncScanning / asyncLocalPasswordScanning / passwordProtected / blockedTooLarge / sensitiveContentWarning / sensitiveContentBlock / deepScannedFailed / deepScannedSafe / deepScannedOpenedDangerous / promptForScanning / promptForLocalPasswordScanning / accountCompromise / blockedScanFailed / forceSaveToGdrive / forceSaveToOnedrive`。

### [E2] Chromium API 定义 — `downloads.webidl`（权威接口定义，取代旧的 `downloads.idl`）
- URL: `.../+main/chrome/common/extensions/api/downloads.webidl`
- 关键摘录：
  - `dictionary HeaderNameValuePair { required DOMString name; required DOMString value; };`（**只有 `name` 与 `value`，无 `binaryValue`**）
  - `dictionary DownloadOptions { required DOMString url; DOMString filename; FilenameConflictAction conflictAction; boolean saveAs; HttpMethod method; sequence<HeaderNameValuePair> headers; DOMString body; };`
  - `// Extra HTTP headers to send with the request if the URL uses the HTTP[s] protocol. Each header is represented as a dictionary containing the keys <code>name</code> and either <code>value</code> or <code>binaryValue</code>, restricted to those allowed by XMLHttpRequest.`
  - `// When any of a $(ref:DownloadItem)'s properties except <code>bytesReceived</code> and <code>estimatedEndTime</code> changes, this event fires …`
  - `[maxListeners=1] static attribute OnDeterminingFilenameEvent onDeterminingFilename;`
  - `enum HttpMethod {"GET", "POST"};`；`enum State`（implied `in_progress/interrupted/complete`）；`enum FilenameConflictAction {"uniquify","overwrite","prompt"}`。

### [E3] Chromium 源码 — 请求头黑名单 `net/http/http_util.cc`
- URL: `.../+main/net/http/http_util.cc`
- 关键摘录（`kForbiddenHeaderFields`，第 411-436 行）：
  ```
  const char* const kForbiddenHeaderFields[] = {
      "accept-charset", "accept-encoding", "access-control-request-headers",
      "access-control-request-method", "connection", "content-length",
      "cookie", "cookie2", "date", "dnt", "expect", "host", "keep-alive",
      "origin", "referer", "set-cookie", "te", "trailer",
      "transfer-encoding", "upgrade",
      // TODO(mmenke): This is no longer banned, but still here due to issues
      // mentioned in https://crbug.com/571722.
      "user-agent", "via",
  };
  ```
- `bool HttpUtil::IsSafeHeader(...)`（第 469-497 行）：*"if (base::StartsWith(name, "proxy-", …) || base::StartsWith(name, "sec-", …)) return false;"*，随后逐个匹配上表。
- `kForbiddenMethods[] = { "connect", "trace", "track" }`（用于 `x-http-method*` 系头值检查）。

### [E4] Chromium 源码 — `chrome.downloads` 扩展 API 实现 `chrome/browser/extensions/api/downloads/downloads_api.cc`
- URL: `.../+main/chrome/browser/extensions/api/downloads/downloads_api.cc`
- 关键摘录：
  - SW 无 frame 的分支（约第 1196-1205 行）：
    ```cpp
    if (auto* rfh = render_frame_host(); rfh) {
      download_params = rfh->CreateDownloadUrlParameters(download_url, traffic_annotation);
    } else {
      // Service-worker-based extensions may have no associated `rfh`.
      download_params = std::make_unique<download::DownloadUrlParameters>(download_url, traffic_annotation);
      download_params->set_render_process_host_id(source_process_id());
      download_params->set_initiator(extension()->origin());
    }
    ```
  - `filename` 处理：`// Strip "%" character as it affects environment variables.` → `base::ReplaceChars(*options.filename, "%", "_", &filename)`；`if (!net::IsSafePortableRelativePath(...)) return RespondNow(Error(download_extension_errors::kInvalidFilename));`
  - `headers` 校验：`IsValidHeaderName` → `kInvalidHeaderName`；`net::HttpUtil::IsSafeHeader(...)` → `kInvalidHeaderUnsafe`；`IsValidHeaderValue` → `kInvalidHeaderValue`。
  - `resume()` 的 no-op 语义（`DownloadsResumeFunction::RunInternal`）：*"// Note that if the item isn't paused, this will be a no-op, and the extension call will seem successful."*；且 `Fault(download_item->GetState() == CANCELLED || (INTERRUPTED && !CanResume), kNotResumable)`。
  - `open()` 的上下文限制：`Fault(!user_gesture(), kUserGesture)` + `kInvisibleContext`（需要可见窗口与活动标签页）。
  - 事件派发：`DispatchEvent(events::DOWNLOADS_ON_CREATED, downloads::OnCreated::kEventName, true, Event::WillDispatchCallback(), …)` —— 走通用事件路由，**发给所有注册了监听的扩展**。
  - `ExtensionDownloadsEventRouterData::determine_filename_timeout_ = base::Seconds(15);`

### [E5] Chromium 源码 — `content/public/browser/content_browser_client.h`
- URL: `.../+main/content/public/browser/content_browser_client.h`
- 关键摘录（第 1842-1871 行）：
  ```
  // Describes the purpose of the factory in WillCreateURLLoaderFactory().
  enum class URLLoaderFactoryType {
    // For navigations.
    kNavigation,
    // For downloads.
    kDownload,
    ...
  ```
- 第 1912 行：*"An opaque origin is passed currently for navigation (kNavigation) and download (kDownload) factories even though requests from these factories can have a valid `network::ResourceRequest::request_initiator`."*
- 第 1976 行起：`virtual void WillCreateURLLoaderFactory(…)` —— 内容层给嵌入层（Chrome）注入工厂拦截器的唯一钩子。

### [E6] Chromium 源码 — `chrome/browser/chrome_content_browser_client.cc`
- URL: `.../+main/chrome/browser/chrome_content_browser_client.cc`
- 关键摘录（第 6828-6866 行 `WillCreateURLLoaderFactory`）：
  ```cpp
  if (web_request_api) {
    bool use_proxy_for_web_request =
        web_request_api->MaybeProxyURLLoaderFactory(
            browser_context, frame, render_process_id, type, …);
  ```
  ⇒ DNR / webRequest 代理的安装点。

### [E7] Chromium 源码 — `extensions/browser/api/web_request/web_request_api.cc`
- URL: `.../+main/extensions/browser/api/web_request/web_request_api.cc`
- 关键摘录：
  - `MaybeProxyURLLoaderFactoryInternal`（第 835 行起）决定是否 `WebRequestProxyingURLLoaderFactory::StartProxying(...)`；判据是 `HasWebRequestOrDeclarativeWebRequestExtension()`（第 1040 行：`return (web_request_extension_count_ > 0) || (declarative_request_extension_count_ > 0);`）——**只装了 DNR 权限的扩展也会启用该代理**。
  - 第 119-120 行枚举注释：`// Proxy will be used only for Declarative{Web|Net}Request* permissions. kOnlyForDeclarativeRequest = 1,`

### [E8] Chromium 源码 — DNR 匹配的实际执行点 `extensions/browser/api/web_request/extension_web_request_event_router.cc`
- URL: `.../+main/extensions/browser/api/web_request/extension_web_request_event_router.cc`
- 关键摘录：第 1020-1036 行 `ruleset_manager->EvaluateBeforeRequest(*request, is_incognito_context)`；第 1250-1257 行 `ruleset_manager->EvaluateRequestWithHeaders(...)`；第 405-414 行 `ActionTracker` 记录命中。
- ⇒ **DNR 规则的匹配只可能发生在 WebRequestAPI 代理内部的 event router 里**。

### [E9] Chromium 源码 — 下载工厂构造 `content/browser/download/download_manager_impl.cc`
- URL: `.../+main/content/browser/download/download_manager_impl.cc`
- 关键摘录（第 399-422 行）：
  ```cpp
  std::unique_ptr<network::PendingSharedURLLoaderFactory>
  CreatePendingSharedURLLoaderFactory(StoragePartitionImpl* storage_partition,
                                      RenderFrameHost* rfh) {
    network::URLLoaderFactoryBuilder factory_builder;
    if (rfh) {
      …
      // Also allow the Content embedder to inject itself if it wants to.
      GetContentClient()->browser()->WillCreateURLLoaderFactory(
          rfh->GetSiteInstance()->GetBrowserContext(), rfh,
          rfh->GetProcess()->GetDeprecatedID(),
          ContentBrowserClient::URLLoaderFactoryType::kDownload, url::Origin(), …);
    }
    …
    return std::make_unique<network::PendingSharedURLLoaderFactoryWithBuilder>(
        std::move(factory_builder),
        storage_partition->GetURLLoaderFactoryForBrowserProcessIOThread());
  }
  ```
- 第 1665 行：`auto* rfh = RenderFrameHost::FromID(params->render_process_host_id(), params->render_frame_host_routing_id());`
  ⇒ **`rfh == nullptr` 时 `WillCreateURLLoaderFactory` 根本不被调用**。

### [E10] Chromium 源码 — `content/browser/renderer_host/render_frame_host_impl.cc`
- URL: `.../+main/content/browser/renderer_host/render_frame_host_impl.cc`
- 第 8730-8737 行：
  ```cpp
  RenderFrameHostImpl::CreateDownloadUrlParameters(const GURL& url, …) const {
    return std::make_unique<download::DownloadUrlParameters>(
        base::PassKey<RenderFrameHostImpl>(), url,
        std::optional<url::Origin>(GetLastCommittedOrigin()),
        GetProcess()->GetDeprecatedID(), GetRoutingID(), traffic_annotation);
  }
  ```
- 第 2330-2334 行：`RenderFrameHostImpl::FromID(int render_process_id, int render_frame_id)` 走 `g_routing_id_frame_map` 查找，查不到返回 `nullptr`。

### [E11] Chromium 源码 — `components/download/public/common/download_url_parameters.cc`
- URL: `.../+main/components/download/public/common/download_url_parameters.cc`
- 第 13-16 行：`DownloadUrlParameters::DownloadUrlParameters(const GURL& url, …) : DownloadUrlParameters(url, std::nullopt, -1, -1, traffic_annotation) {}` ⇒ **默认 `render_process_host_id = -1`、`render_frame_host_routing_id = -1`**。

### [E12] Chromium 源码 — webRequest 资源类型映射 `extensions/browser/api/web_request/web_request_info.cc`
- URL: `.../+main/extensions/browser/api/web_request/web_request_info.cc`
- 第 176-184 行：
  ```cpp
  WebRequestResourceType ToWebRequestResourceType(
      const network::ResourceRequest& request, bool is_download) {
    if (request.url.SchemeIsWSOrWSS()) { return WebRequestResourceType::WEB_SOCKET; }
    if (is_download) { return WebRequestResourceType::OTHER; }
  ```
  ⇒ **下载请求在 webRequest / DNR 中的资源类型是 `OTHER`**。

### [E13] Chrome Extensions API 参考 — `declarativeNetRequest`
- URL: https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest
- 关键原文摘录：
  - Rule evaluation / Before request headers are sent：*"Before Chrome sends request headers to the server, the headers are updated based on matching `modifyHeaders` rules."*
  - Header modification：*"The `append` operation is only supported for the following request headers: `accept`, `accept-encoding`, `accept-language`, `access-control-request-headers`, `cache-control`, `connection`, `content-language`, **`cookie`**, `forwarded`, `if-match`, `if-none-match`, `keep-alive`, `range`, `te`, `trailer`, `transfer-encoding`, `upgrade`"*
  - Headers 示例：*"The following example removes all cookies from both a main frame and any sub frames."*（规则体 `"requestHeaders" : [{ "header" : "cookie" , "operation" : "remove" }]`）
  - `HeaderOperation`：`append` / `set` / `remove`。
  - `ResourceType` 枚举：`main_frame, sub_frame, stylesheet, script, image, font, object, xmlhttprequest, ping, csp_report, media, websocket, webtransport, webbundle, other` —— **没有 `download`**。
  - `RulesetMatcher*` 相关：*"For requests with no associated top-level frame (e.g. ServiceWorker initiated requests), the request initiator's domain is considered instead."*
  - 关联 issue（正文可读、状态未能解析）：https://issues.chromium.org/issues/40256297 — *"The `content-disposition` header isn't added and the PDF file isn't downloaded, even though the badge on the extension icon shows that the rule was executed."*（Chrome 109）

### [E14] Chrome 官方指南 — The extension service worker lifecycle（页面页脚：Last updated 2023-05-02 UTC）
- URL: https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle
- 关键原文摘录：
  - *"Normally, Chrome terminates a service worker when one of the following conditions is met: After 30 seconds of inactivity. Receiving an event or calling an extension API resets this timer. / When a single request, such as an event or API call, takes longer than 5 minutes to process. / When a `fetch()` response takes more than 30 seconds to arrive."*
  - *"Events and calls to extension APIs reset these timers, and if the service worker has gone dormant, **an incoming event will revive them**. Nevertheless, you should design your service worker to be resilient against unexpected termination."*
  - *"Any global variables you set will be lost if the service worker shuts down. Instead of using global variables, save values to storage."*
  - Chrome 120：*"Alarms can now be set to a minimum period of 30s to match the service worker lifecycle."*

### [E15] Chrome 官方指南 — Events in service workers
- URL: https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/events
- 关键原文摘录：*"Event handlers in service workers need to be declared in the global scope, meaning they should be at the top level of the script and not be nested inside functions. This ensures that they are registered synchronously on initial script execution, **which enables Chrome to dispatch events to the service worker as soon as it starts**."*

### [E16] Chromium issue 40878315 + 修复 commit
- Issue URL: https://issues.chromium.org/issues/40878315 —— *"The listener of downloads.onChanged in not running when Service Worker is inactive (MV3)"*，报告版本 Chrome 107，复现步骤含 `chrome.downloads.onChanged.addListener(...)` 写入 `chrome.storage.local` 后比对时间戳。
- 修复 commit：https://chromium.googlesource.com/chromium/src/+/0800948c9d63d39244ad3012191105689d49ed1b （committer date **Thu Aug 27 23:44:58 2026**）
  提交信息原文：*"**[Extensions] Add test for downloads.onChanged with inactive SW** … Before this CL, crbug.com/40878315 reported that the `chrome.downloads.onChanged` listener in a Manifest V3 extension failed to execute or did not record expected timestamps when the background service worker was inactive during a download. After this CL, a browser test is added to verify that **`chrome.downloads.onChanged` wakes up an inactive Manifest V3 service worker** and correctly records the event timestamp and delta in storage. The reported issue appears to have been resolved by prior work on service worker event dispatching."*（`Fixed: 40878315`）

### [E17] Chromium issue 451089037
- URL: https://issues.chromium.org/issues/451089037
- 摘录（正文，**原文拼写如此**）：*"Chrome Version: 141.0.7390.66 (Official Build) (64-bit)"*；*"What happens instead? `chrome.downloads.onCreated.addListener` get fires with previous DownloadItems including when `DownloadItem` state being `'complete'` or `'interrupted'` when chrome lunches."*
- ⚠️ issue 状态未能从 tracker JSON 中解析（§7 #12）。

### [E18] Stack Overflow 77932227（社区经验；**本途径最关键的一条外部证据**）
- URL: https://stackoverflow.com/questions/77932227/chrome-downloads-api-http-requests-are-not-getting-modified-by-declarative-net-request-api
- 提问时间 2024-02-03（Chrome 121 时代）。原文摘录：*"I am trying to build an extension which uses chrome's Declarative Net Request API to modify my request headers to add forbidden headers. All my HTTP requests to the external website using standard fetch are getting properly modified as expected. **However, when I try to download a file using chrome's Downloads API, the download request is not getting modified and hence fails.**"*（调用点在其 `bg_script.js`，即 MV3 service worker）
- **无任何回答**；评论原文：*"It's a bug in Chrome."* / *"Any idea if an issue is raised and tracked against this bug?"* / *"Is there any other way to achieve this?"*

### [E19] Chrome Extensions API 参考 — `offscreen`（+ 官方博客）
- API URL: https://developer.chrome.com/docs/extensions/reference/api/offscreen
  摘录：*"**The `runtime` API is the only extensions API supported by offscreen documents.**"*；*"The extension's permissions carry over to offscreen documents, but with limits on extension API access. For example, because the `browser.runtime` API is the only extensions API supported by offscreen documents, messaging must be handled using members of that API."*
  `Reason` 枚举（节选）：`TESTING / AUDIO_PLAYBACK / IFRAME_SCRIPTING / DOM_SCRAPING / BLOBS / DOM_PARSER / USER_MEDIA / DISPLAY_MEDIA / WEB_RTC / CLIPBOARD / LOCAL_STORAGE / WORKERS / BATTERY_STATUS / MATCH_MEDIA / GEOLOCATION`。
- 博客 URL: https://developer.chrome.com/blog/Offscreen-Documents-in-Manifest-v3
  摘录：*"To reduce the likelihood of extensions using these as a "background page replacement", **only the `chrome.runtime` messaging APIs are exposed to the offscreen document.**"*

### [E20] Chrome 官方指南 — Content scripts
- URL: https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts
- 摘录：*"Content scripts can access the following extension APIs directly: `dom / i18n / storage / runtime.connect() / runtime.getManifest() / runtime.getURL() / runtime.id / runtime.onConnect / runtime.onMessage / runtime.sendMessage()`"*；*"Content scripts are unable to access other APIs directly. But they can access them indirectly by exchanging messages with other parts of your extension."*

### [E21] Chrome Extensions API 参考 — `scripting`（`ExecutionWorld`）
- URL: https://developer.chrome.com/docs/extensions/reference/api/scripting
- 摘录：*"`"ISOLATED"` Specifies the isolated world, which is the execution environment unique to this extension."* / *"`"MAIN"` Specifies the main world of the DOM, which is the execution environment shared with the host page's JavaScript."*；`world` 默认 `ISOLATED`。
- 另：Content scripts 文档 *"When a content script is injected into the main world, the CSP of the page applies."*

### [E22] Chrome Extensions — Permissions 列表
- URL: https://developer.chrome.com/docs/extensions/reference/permissions-list
- 摘录：`"downloads"` = *"Gives access to the `chrome.downloads` API. **Warning displayed: Manage your downloads.**"*；`"downloads.open"` = *"Allows the use of `chrome.downloads.open()`. Warning displayed: Manage your downloads."*；`"downloads.ui"` = *"Allows the use of `chrome.downloads.setUiOptions()`. Warning displayed: Manage your downloads."*

### [E23] MDN — `downloads.download()`（跨浏览器对照）
- URL: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/downloads/download
- 摘录（与 Chrome 的差异点）：
  - *"`filename` … A `string` representing a file path relative to the default downloads directory … **Absolute paths, empty paths, path components that start and/or end with a dot (.), and paths containing back-references (`../`) will cause an error.**"*
  - *"`headers` … **The headers that are forbidden by `XMLHttpRequest` and `fetch` cannot be specified, however, Firefox 70 and later enables the use of the `Referer` header.** Attempting to use a forbidden header throws an error."*
  - Firefox 独有：`allowHttpErrors`、`cookieStoreId`、`incognito`。
  - *"If the URL uses the HTTP or HTTPS protocol, the request includes all the relevant cookies…"*

### [E24] Google Chrome 帮助 — Google Chrome blocks some downloads
- URL: https://support.google.com/chrome/answer/6261569
- 摘录：*"Chrome automatically blocks dangerous downloads and protects your device and accounts from malware or viruses."*；*"When Chrome blocks a download, you're protected and don't need to take further action. You can remove a warning from your download history by selecting "Delete from history." **If you take no action, Chrome will remove it from your history in one hour.**"*；*"You can always choose to download a file after you receive a warning from Chrome…"*

### [E25] chromium-extensions 官方群组（Chrome DevRel 回答）
- URL: https://groups.google.com/a/chromium.org/g/chromium-extensions/c/yu7RzUMRryk （"Manifest V3 - Intercept request in flight"，2025-02）
- 摘录（Oliver Dunk，*"Oliver Dunk | DevRel, Chrome Extensions"*，2025-02-19）：*"Hi Rahul, I'm afraid that **adding dynamic headers isn't currently something the API supports.** If you could share more about why you're looking to add them, we might be able to provide some suggestions."*
- 提问者原话（说明限制的实际形态）：*"I tried using declarativeNetRequest updateDynamicRule() for modifying request headers, but the rules needs to be created beforehand for it to get applied to a request. If we try to create the rule while listening to a request using the webRequest methods, the rule doesn't get applied to that current ongoing request."*

### [E26] Chromium 源码 — `chrome/browser/extensions/api/downloads/download_extension_errors.h`
- URL: `.../+main/chrome/browser/extensions/api/downloads/download_extension_errors.h`
- 摘录（`inline constexpr char …`）：`kInvalidFilename[] = "Invalid filename"`、`kInvalidHeaderName[] = "Invalid request header name"`、`kInvalidHeaderUnsafe[] = "Unsafe request header name"`、`kInvalidHeaderValue[] = "Invalid request header value"`、`kInvisibleContext[] = …`、`kNotComplete[] = "Download must be complete"`、`kNotResumable[] = "DownloadItem.canResume must be true"`、`kUserGesture[] = "User gesture required"`、`kNotDangerous[] = "Download must be dangerous"`。
- ⚠️ 与 [E1] 的警告冲突：文档明令 *"Extensions must not parse it."* ⇒ 这些串**只能用于人工排障**。

### [E27] Stack Overflow 69776708（社区经验，**未验证**）
- URL: https://stackoverflow.com/questions/69776708/how-to-fix-downloads-with-chrome-downloads-extensions-api-getting-automatical
- 摘录（提问者自述，2021，Chrome ≈95，**无回答**）：*"The download never completes (saveAs dialog never opens even if set to true) / Upon analyzing the DownloadItem object for the returned ID, its status is found to be interrupted and its reason to be USER_CANCELED / No errors are reported in either of the consoles … chrome.runtime.lastError is undefined as well."* 触发条件：浏览器设置 "Ask where to save each file before downloading" 打开。

### [E28] Chromium 源码 — `content/browser/storage_partition_impl.cc`
- URL: `.../+main/content/browser/storage_partition_impl.cc`
- 事实：全文 grep `WillCreateURLLoaderFactory` **无命中**；浏览器进程工厂只在 `CreateURLLoaderFactoryForBrowserProcessInternal`（第 3657 行起）内构造。
- ⇒ 浏览器进程自用的 `GetURLLoaderFactoryForBrowserProcess(IOThread)` 工厂**不经过**扩展注入钩子，因此没有 DNR / webRequest 代理。

### [E29] Chromium 源码 — DNR 规则匹配器入口（补充证据链）
- URL: `.../+main/extensions/browser/api/declarative_net_request/ruleset_manager.h`
- 摘录：`const std::vector<RequestAction>& EvaluateBeforeRequest(...)`；`std::vector<RequestAction> EvaluateRequestWithHeaders(...)`；`virtual void OnEvaluateRequest(const WebRequestInfo& request, …)`。
- 与 [E8] 合看 ⇒ `WebRequestInfo` 是 DNR 匹配的输入类型，而 `WebRequestInfo` 只在 webRequest 代理内部构造。

---

## 附录：本文用到的检索/核对方法（供复核用）

1. 官方文档：`curl` 抓取页面 → 去标签转文本 → 全文 grep 关键词（`download`、`header`、`content script`、`offscreen`、`terminate`…）；同时抓 `.md.txt` 版本（Chrome 文档提供 `…/api/<name>.md.txt` 纯文本源）以获取无噪声原文。
2. Chromium 源码：`https://chromium.googlesource.com/chromium/src/+/main/<path>?format=TEXT` 返回 base64，`base64 -d` 后本地 grep；目录列表用 `.../+main/<dir>/?format=TEXT`。API 定义已从 `downloads.idl` 迁移为 **`downloads.webidl`**（旧路径 404）。
3. 版本锚点：`https://chromium.googlesource.com/chromium/src/+/main?format=JSON` 取当前 commit。
4. issue tracker：`https://issues.chromium.org/action/issues/<id>` 带 `accept: application/json` 可拿到正文（响应带 `)]}'` 前缀，需剥离）；**注意该接口不能直接读出 issue 状态字段**（§7 #11/#12）。
5. Stack Overflow：被 Cloudflare 拦截（403）时改用官方 API `https://api.stackexchange.com/2.3/questions/<id>?site=stackoverflow&filter=withbody`（含 `/answers`、`/comments`）。
6. Google Groups：`curl` 带常见浏览器 UA 可直接拿到服务器渲染的帖子正文（含 Chrome DevRel 回复）。
