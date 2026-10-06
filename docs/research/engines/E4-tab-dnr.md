# E4 — 标签页 + DNR 触发下载（核实并深化概念设计文档附录 A）

## 0 元信息

| 项 | 值 |
|---|---|
| 文档 ID | E4-tab-dnr |
| 任务 | t4 [e4]：核实并深化 `/workspace/docs/concept-design/concept-design.md` 附录 A 描述的机制 |
| 作者 | eng-tab-dnr（团队 aria2-in-browser-boundary） |
| 核对日期 | **2026-10-06（UTC）** |
| 文档快照 | Chrome for Developers 官方文档，抓取日期 2026-10-06；各页 `Last updated` 见 §8 |
| 源码快照 | `chromium/src` `main` 分支，HEAD `a4f419a12645`（2026-10-06 抓取，经 chromium.googlesource.com） |
| 浏览器实测 | **无**。本环境没有 Chrome/Chromium 二进制（`which google-chrome/chromium` 均无，无 Playwright），因此**所有"运行期实际行为"一律标 🟠未验证**，只给文档/源码级证据 |
| 覆盖浏览器 | 仅 Chrome（MV3）。Firefox/Safari 不在本题范围 |
| 交付范围 | 只写本文件；未修改任何代码、未修改 `concept-design.md`、未触碰其他成员文件 |

### 0.1 证据等级

| 标记 | 含义 |
|---|---|
| **[A]** | 官方文档原文（Chrome for Developers / MDN / W3C），§8 给出 URL 与原文摘录 |
| **[B]** | Chromium 源码（`main` 分支文件 + 摘录），§8 给出文件与 URL |
| **[C]** | 推断或未验证（含"文档/源码都没说"的情形），**不得当作结论使用** |

### 0.2 本报告与 E1 的关系

`E1`（`chrome.downloads` 路线，队友文档）是**发起下载 + 观测下载**的路线；`E4`（本文件）是**在导航请求上改请求头 / 改响应头来间接发起下载**的路线。
本报告的核心结论之一是：**E4 单独无法观测自己触发的下载**，必须借用 `chrome.downloads` 的事件/查询——即 **E4 在实现上必须与 E1 的观测层合流**（详见 §1、§4.3、§6.2）。E4 与 E1 的分工不是"二选一"，而是"触发通道 + 观测通道"。

---

## 1 一句话结论

**附录 A 描述的机制在 Chrome MV3 上"结构上成立"，但它只能当"辅助通道"，不能当主力下载引擎。**
它的真实价值是把 `chrome.downloads.download()` **拒绝的敏感请求头**（代表：`Cookie`）注入到浏览器自己的导航请求上，并用响应头 `Content-Disposition` 强制走下载、顺带确定文件名；它的代价是：**规则是扩展级/全局的**（作用域要靠 `tabIds`/域名条件手动收窄）、**必须真的开一个标签页**、**拿不到任务句柄**，因此**进度/状态/暂停/取消/文件名收尾全部要回到 `chrome.downloads` 去关联**——这条途径**必然与 E1 合流**。

三个必须写进能力报告的硬事实（附录 A 未提到，容易被忽略）：

1. **DNR 规则默认不匹配 `main_frame`。** 不写 `"resourceTypes": ["main_frame"]` 时，规则对"打开标签页"这个顶层导航**根本不生效**，而且**不报错**——下载不会触发，页面开始渲染 [B/§8-B5]。这是本机制最隐蔽的失败模式。
2. **`append` 只能用于一个 21 项的固定白名单**（含 `cookie`，不含 `referer`/`origin`/`authorization`）；`set`/`remove` 在文档与源码中都没有名字白名单 [A/B/§8-A7、B6]。所以"任意注入 header"并不成立，只能**逐头选策略**。
3. **落盘目录完全不可控**（附录 A.4.1 已记录），文件名要靠响应头或 `onDeterminingFilename` 二次争取；这与 R13（用户可调整默认参数，例如保存目录）正面冲突（§6.4）。

**定位：只能当辅助（E1 的 header 补丁层）。**
**最大风险：DNR 规则是"改网络请求"级别的全局副作用**——若清理不及时或作用域没收窄，会长期、静默地改变**用户正常浏览**该 URL 时的请求头/响应头行为（比"该 RPC 地址的真实服务不可访问"的影响面更大，因为它作用在网络层而非 JS API 层）。

---

## 2 机制（逐步核实附录 A 的三步）

### 2.1 附录 A 的机制还原

附录 A 描述：① 加 DNR 规则拦截请求并注入 header；② 再加一条 DNR 规则拦截响应、写 `Content-Disposition: attachment; filename="…"`；③ 用 `chrome.tabs` 打开 `urlA`，"等几秒"，下载开始。

核实结论：**三步的每一步在 Chrome MV3 上都有官方文档支撑，但每一步都有附录 A 未写出的必要条件。**

### 2.2 第 1 步：DNR 规则怎么写、怎么改请求头

规则是 `chrome.declarativeNetRequest.Rule`：`id`＋`action`＋`condition`（`priority` 可选，默认 1）[A/§8-A1]。改头用 `action.type = "modifyHeaders"` ＋ `requestHeaders` / `responseHeaders` 数组，数组元素为 `ModifyHeaderInfo{header, operation, value}`；`value` **在 `append` 与 `set` 时必须给出** [A/§8-A1]。

`HeaderOperation` 三值语义（文档原文 + 源码实现）：

| 操作 | 文档语义 | 源码实现（要点） | 名字限制 |
|---|---|---|---|
| `set` | 设置为给定值 | `RemoveHeader(header)` 后 `AddHeader(header, value)`；**不存在**的头直接新增 [B/§8-B7] | 文档与源码中**未发现**名字白名单 → 🟠"任意头可 set"未验证 |
| `append` | 值追加到已有头（用合适分隔符） | 请求头路径：已有值 ＋ 分隔符 ＋ 新值（分隔符来自固定表：`cookie` 用 `"; "`，`user-agent` 用 `" "`，其余多为 `", "`）；响应头路径：直接 `AddHeader(header,value)` [B/§8-B6、B7] | **请求头仅 21 项白名单**：`accept, accept-encoding, accept-language, access-control-request-headers, cache-control, connection, content-language, cookie, forwarded, if-match, if-none-match, keep-alive, range, te, trailer, transfer-encoding, upgrade, user-agent, via, want-digest, x-forwarded-for` [A/§8-A7][B/§8-B6]；**响应头 append 没有此白名单**（源码里白名单校验只对请求头生效）[B/§8-B17] |
| `remove` | 删除该头 | `RemoveHeader(header)` [B/§8-B7] | —— |

跨规则/跨扩展的叠加顺序是**规定死的**（重要，否则同一头被多条规则改会不可预测）：

> "If a rule appends to a header, then lower priority rules can only append to that header. Set and remove operations are not allowed.
> If a rule sets a header, then only lower priority rules from the same extension can append to that header. No other modifications are allowed.
> If a rule removes a header, then lower priority rules cannot further modify the header." [A/§8-A6]

规则在**注册时**就会被校验（不是运行时静默忽略）：头名必须过 `net::HttpUtil::IsValidHeaderName`；请求头 `append` 若不在白名单内直接返回 `ERROR_APPEND_INVALID_REQUEST_HEADER`；`append`/`set` 必须给 `value`，`remove` 给了 `value` 反而报错 [B/§8-B17]。⇒ **写错规则会以 `updateSessionRules()` promise reject 的形式暴露出来（好）**；而"条件写窄/写错导致匹配不到"则是静默的（坏，见 §5.1）[A/§8-A2]。

**为什么必须用这条路而不是 `chrome.downloads({headers})`**（核实附录 A.3 的前提）：

- `chrome.downloads.download()` 的 `headers` 选项被官方文档限定："each header is represented as a dictionary containing the keys name and either value or binaryValue, **restricted to those allowed by XMLHttpRequest**" [A/§8-A9]。
- 该限制的**具体清单在源码里**：`net::HttpUtil::IsSafeHeader()` 拒绝 `proxy-*` / `sec-*` 前缀，以及来自 fetch 标准的禁用头列表 `accept-charset, accept-encoding, access-control-request-headers, access-control-request-method, connection, content-length, **cookie**, cookie2, date, dnt, expect, **host**, keep-alive, **origin**, **referer**, **set-cookie**, te, trailer, transfer-encoding, upgrade, user-agent, via`（注释原文："The list comes from the fetch standard."）[B/§8-B3]；调用失败时扩展 API 直接返回错误 `kInvalidHeaderUnsafe` [B/§8-B4]。
- 而 DNR 的 `append` 白名单**明确包含 `cookie`** [A/§8-A7][B/§8-B6]。

⇒ **"能不能设置通常被 fetch 禁止的头"的准确答案**：
- 对 `Cookie`：**能越过 XHR 限制**——但走的是 `append`（在浏览器 cookie jar 已生成的 `Cookie` 头后面追加，源码注释说明这是"支持多值的标准请求头"白名单）[B/§8-B6/B7]；`set` 覆盖整条 `Cookie` 头**没有**文档级许可，🟠未验证。
- 对 `Referer` / `Origin` / `Host` / `Authorization` / 自定义头：文档与源码中**只有 `append` 白名单**，没有 `set` 黑名单 → 只能用 `set` 试，🟠未验证（需实测 + `onRuleMatchedDebug`）。
- 一个副产品：因为 `Cookie` 头是**浏览器自己带上的**（jar 里的、含 HttpOnly 的 cookie 都在），E4 **不需要读取 cookie**，所以"HttpOnly cookie 不可读"这个前置限制在 E4 路径上不构成障碍 [C，推断自 B6]。

### 2.3 第 2 步：拦截响应、重写 `Content-Disposition` 到底发生了什么

机制成立，链路如下（全部有源码/文档支撑）：

1. DNR 的 `responseHeaders` 在 **`modifyHeaders` 动作**里声明 [A/§8-A1]，在响应头到达后由 Chrome 评估（"Once the response headers have been received, Chrome evaluates rules with a responseHeaders condition."）[A/§8-A5]。
2. 改写的做法是：**复制原始响应头为 `override_response_headers`，在其上做 set/remove/append** [B/§8-B7]；随后 proxying loader 用改写后的对象替换响应头再交给下游：
   > `current_response_->headers = override_headers_;` —— 见 `web_request_proxying_url_loader_factory.cc` 的 `OverwriteHeadersAndContinueToResponseStarted()`，注释还说明**导航与 worker 请求**会重解析 `ParsedHeader` 以反映被改写的头 [B/§8-B8]。
3. 浏览器判定"这是下载"用的是**改写后的头**：`content::download_utils::MustDownload()` 里
   > `if (net::HttpContentDisposition(*headers, /*referrer_charset=*/std::string()).is_attachment()) { return true; }` [B/§8-B1]。
4. 导航型下载不是"重新发一次请求"，而是**把已经在飞的导航响应截下来交给下载系统**：`DownloadManagerImpl` 走 `InterceptDownloadFromNavigation(...)` 并把 `response_head` / `response_body` / loader client 端点一起移交 [B/§8-B9]。
5. 即使不改 `Content-Disposition`，**不能内联渲染的 MIME 类型**本来也会变成下载：`IsDownload()` 在 `MustDownload()` 为假时，若 MIME 不受支持且响应是 2xx 也返回 true [B/§8-B2]。
6. 有一个"Chrome 可以隐藏某些响应头不让扩展改"的钩子（`ExtensionsAPIClient::ShouldHideResponseHeader`），但 Chrome 的实现**只隐藏 Gaia 主机的 Dice / Mirror 头**（OAuth 防泄漏），与 `Content-Disposition` 无关 [B/§8-B16]。

⇒ 因此第 2 步的**真实作用有两层**：**(a) 对"本来会被渲染"的类型强制下载；（b) 提供文件名**（与附录 A.4.2 的记录一致）。对 `application/octet-stream` 之类，第 2 步在"强制下载"上是冗余的，但文件名仍然只有它能给（除非用 `onDeterminingFilename`，见 §4.3）。

**副作用与"会不会被忽略"**（逐条给依据）：

| 风险 | 是否有依据 | 说明 |
|---|---|---|
| 污染其它请求 | **[A] 确定存在** | 规则是扩展级的、按 `condition` 匹配，"命中 `urlA` 时对**所有**匹配该规则的请求生效"（附录 A.4.7 的记录正确）。不限定 `tabIds`/`initiatorDomains`/`requestDomains` 时，用户在别的标签页打开同一 URL 也会被改头/强制下载 |
| 被浏览器忽略 | **[A] 有确定的忽略场景** | ① 请求没到网络栈就不适用："declarativeNetRequest won't affect responses generated by the service worker or retrieved from CacheStorage, but it will affect calls to fetch() made in a service worker." [A/§8-A8]；② 无该 URL 的 host 权限时规则不生效 [A/§8-A3]；③ 被更高优先级的 `allow`/`allowAllRequests` 规则覆盖时不生效 [A/§8-A5]；④ 只有 **session 规则**支持 `tabIds`，用 dynamic 规则写 `tabIds` 是无效的 [A/§8-A4] |
| 静默失效（最危险） | **[B] 确定存在** | 不写 `resourceTypes` 时默认掩码是 `ElementType_ANY & ~ElementType_MAIN_FRAME`（**排除 main_frame**），顶层导航不会被匹配 [B/§8-B5]。文档在 `excludedResourceTypes` 里有一句措辞可疑的对应说明（"If neither of them is specified, all resource types except "main_frame" are blocked."）[A/§8-A4] |

### 2.4 第 3 步：用标签页触发下载——"等几秒"到底在等什么

`chrome.tabs.create()` 返回 `Promise<Tab>` [A/§8-A11]；创建/导航标签页**不需要任何权限**（"Most features don't require any permissions to use. For example: creating a new tab, reloading a tab, navigating to another URL, etc."）[A/§8-A12]。

"等几秒"实际上在等**四件不可控的事**，其中只有第一件可以确定化：

| 等待对象 | 能否用确定性信号替代 |
|---|---|
| ① DNR 规则异步落地 | **能**：`updateSessionRules()` 返回 "Promise that resolves once the update is complete"，且更新是 "a single atomic operation" [A/§8-A2] → `await` 即可，不需要 sleep |
| ② 导航的网络往返（DNS/TLS/首字节） | **不能**；只能等下载系统的事件（下一条）而不是死等时间 |
| ③ 浏览器把响应判定为下载并建 `DownloadItem` | **能**：`chrome.downloads.onCreated`（"This event fires with the DownloadItem object when a download begins."）[A/§8-A10]；源码显示事件路由观察的是整个 profile 的 DownloadManager（`ExtensionDownloadsEventRouter::OnDownloadCreated(DownloadManager*, DownloadItem*)`），只过滤掉 temporary 与 `DownloadSource::INTERNAL_API` 两类 [B/§8-B10、§8-B11] |
| ④ 文件名的确定 | **能**：`chrome.downloads.onDeterminingFilename`（"During the filename determination process, extensions will be given the opportunity to override the target DownloadItem.filename."）[A/§8-A10]；另一个早于 `onCreated` 的通知点 [A] |

**推荐的确定性顺序**（把附录 A 的"sleep 几秒"整体替换掉）：

```
await updateSessionRules({addRules})              // ① 规则就绪（promise 语义保证）
const tab = await tabs.create({url:'about:blank', active:false})   // 先建 tab 拿 tabId
await updateSessionRules({addRules:[...tabIds:[tab.id]]})          // ② 若用 tabIds 作用域，必须 tab 先存在
await tabs.update(tab.id, {url: urlA})            // ③ 真正的导航
// ④ 不再 sleep：等 downloads.onCreated（或 onDeterminingFilename）拿到 DownloadItem.id
// ⑤ 超时（自定）→ 报错，附 webNavigation/tabs 诊断信息（R2：如实报错）
```

**重要的顺序陷阱（附录 A 未提）**：如果要用 `tabIds` 收窄作用域，**必须"先建空标签页拿到 tabId → 装规则 → 再 `tabs.update` 导航"**；直接 `tabs.create({url: urlA})` 会在你拿到 tabId 之前就开始导航，规则来不及带 `tabIds` [A/§8-A4、§8-A11 → 🟠C 组合推断]。

**辅助诊断信号**（不能当主信号）：`chrome.webNavigation.onBeforeNavigate/onCommitted/onCompleted/onErrorOccurred`（需 `"webNavigation"` 权限）[A/§8-A13]；`chrome.tabs.onUpdated` 的 `changeInfo.status`（`"unloaded"|"loading"|"complete"`）[A/§8-A11]。
**🟠未验证**：当导航被转成下载时，`webNavigation.onCompleted` 是否永不触发、`onErrorOccurred` 是否报 `ERR_ABORTED`（文档只说 "Fired when an error occurs and the navigation is aborted. This can happen if either a network error occurred, or the user aborted the navigation." [A/§8-A13]），因此**不能用它们判断下载成功**。

### 2.5 为什么"用 tabs 而不是 `chrome.downloads`"这个前提基本成立

附录 A.3 的原话是"`chrome.downloads` 触发的下载会无视修改请求头的 DNR"。核实结果：

- **官方文档层面：找不到任何关于"downloads API 的请求是否经过 DNR"的表述**（DNR 参考页正文提取文本约 5.3 万字符，未出现 "download" 一词；站点侧边导航已排除）→ 这条断言**没有文档支撑**。
- **源码层面：存在两条独立线索支持"MV3 SW 发起的 downloads 请求不经过 DNR/webRequest 管线"**：
  1. 下载请求的 loader factory 只在**有关联 RenderFrameHost** 时才走 embedder 钩子（进而可能装上扩展 webRequest/DNR 代理）：`if (rfh) { … GetContentClient()->browser()->WillCreateURLLoaderFactory(… URLLoaderFactoryType::kDownload …) }` [B/§8-B12]；而 `chrome.downloads.download()` 的实现里，**service worker 场景没有 rfh**（源码注释原文："Service-worker-based extensions may have no associated `rfh`."）[B/§8-B4]。
  2. 即使代理装上了，webRequest/DNR 管线还会**隐藏浏览器发起的非导航请求**：
     > `// Hide all non-navigation requests made by the browser. crbug.com/40092481.` / `if (!request.is_navigation_request) { return true; }` [B/§8-B13]。
- 🟠**未验证（但与 E1 文档收敛）**：反过来，**从扩展页面（有 rfh）调用 `chrome.downloads.download()`** 时，源码结构显示 loader factory 会走 `kDownload` 类型并可能被扩展代理（线索 1 的 `if (rfh)` 分支）→ 此时 DNR 生效。队友 E1 文档（§2.3）独立核实后把这一格判为"**是**（源码级结论，非官方文档承诺）"；本报告同意其源码依据，但仍按"无浏览器可实测"标记为未验证（§7.10）。无论哪种口径，都意味着附录 A 的前提**只在 MV3 SW 场景成立**。

⇒ 结论：**附录 A 的机制选择是合理的（tabs 导航请求是导航类请求，不会被上述两条过滤掉），但其断言"downloads 一定无视 DNR"只能标为"源码结构支持、未实测"**。

#### 2.5.1 与 E1 文档的一致性说明（资源类型口径，避免两文档打架）

队友的 E1 文档（`/workspace/docs/research/engines/E1-chrome-downloads.md` §1、§2.3）独立核实后给出同一结论：**MV3 SW 调用的 `chrome.downloads.download()` 不经过 DNR；有帧的扩展页面调用时经过**；并指出"下载请求在 webRequest/DNR 眼里是 `other` 资源类型，想命中它的规则 `resourceTypes` 必须含 `other`"。两处口径必须对齐：

- `other` 只适用于**下载子系统自己发起的请求**：`bool WebRequestProxyingURLLoaderFactory::IsForDownload() const { return loader_factory_type_ == content::ContentBrowserClient::URLLoaderFactoryType::kDownload; }` [B/§8-B20]；而 `WebRequestResourceType ToWebRequestResourceType(const network::ResourceRequest& request, bool is_download) { … if (is_download) { return WebRequestResourceType::OTHER; } … }` [B/§8-B19]。
- **E4 的导航请求走 `kNavigation`**，不是 `kDownload` → 在 DNR 眼里是 `main_frame` → E4 的规则必须写 `resourceTypes: ["main_frame"]`（§2.4、§3.2）。

⇒ **E4 用 `main_frame`；E1 若要用 DNR 命中 downloads API 的请求则应写 `other`（且只在该请求确实被代理的前提下）**。两者不是同一条请求，规则不能互相套用。

---

## 3 硬约束

### 3.1 权限

| 需要什么 | 事实 | 依据 |
|---|---|---|
| `declarativeNetRequest` / `declarativeNetRequestWithHostAccess` | 两者"provide the same capabilities"，差别只在何时请求权限；`declarativeNetRequest` 在安装时**给出隐式访问的只有 `allow`/`allowAllRequests`/`block`**（原文："provides implicit access to allow, allowAllRequests and block rules"）。⇒ 🟠**推断**：`modifyHeaders`（本机制的核心动作）不在隐式名单里，因此需要 host 权限；文档没有一句逐字写"modifyHeaders 需要 host 权限" | [A/§8-A3]（推断部分见 §7.13） |
| host 权限 | "you must request host permissions before you can perform any action on a host"；DNR 规则对无权限的 URL 不生效 | [A/§8-A3] |
| `downloads` | 观测下载（`onCreated`/`onChanged`/`onDeterminingFilename`/`search`/`pause`/`resume`/`cancel`）必须声明 `"downloads"` | [A/§8-A9] |
| `tabs` | **发起不需要**；只在需要读 `url`/`pendingUrl`/`title`/`favIconUrl` 时才需要 | [A/§8-A12] |
| `webNavigation` | 使用该 API 的任何方法与事件都要声明 | [A/§8-A13] |
| `declarativeNetRequestFeedback` | 仅调试：`getMatchedRules()` 与 `onRuleMatchedDebug()` 需要它，且**只在 unpacked 扩展可用** | [A/§8-A1、§8-A10] |

### 3.2 规则作用域（决定"会不会污染"）

- 可用维度：`urlFilter`/`regexFilter`（二者只能选一）、`resourceTypes`/`excludedResourceTypes`、`requestDomains`(Chrome 101+)、`initiatorDomains`(Chrome 101+)、`requestMethods`(Chrome 91+)、`domainType`、`responseHeaders` 条件(Chrome 128+)、`topDomains`(Chrome 145+)、`tabIds`/`excludedTabIds`(Chrome 92+) [A/§8-A4]。
- **`tabIds` 只支持 session 规则**："Only supported for session-scoped rules."；`TAB_ID_NONE`（即 -1）"matches requests which don't originate from a tab" [A/§8-A4]。
- 导航请求的 `tabId` 是可用的（Chrome 在导航时把 tab/window id 塞进 `ExtensionNavigationUIData`）[B/§8-B14，源码取证]。
- 默认掩码**排除 `main_frame`** [B/§8-B5] → 导航必须显式写 `resourceTypes: ["main_frame"]`。
- 🟠未验证：`initiatorDomains` 对"由标签页直接导航"的请求算不算——导航请求的 initiator 通常是页面自身/`null`，文档只说"This matches against the request initiator and not the request url." [A/§8-A4]，**不要依赖它来限定标签页**。

### 3.3 生命周期与条数上限

| 规则类型 | 持久性 | 上限 | 依据 |
|---|---|---|---|
| 静态（`rule_resources` 清单） | 随扩展包安装/升级 | 每扩展最多 100 个 ruleset，同时最多启用 50 个；跨启用 ruleset **保证至少 30000 条**；超出部分吃全局配额（全局上限 300000/配置文件 [B/§8-B15]） | [A/§8-A15、§8-A16] |
| 动态（`updateDynamicRules`） | **跨浏览器会话与扩展升级持久** | 总数 `MAX_NUMBER_OF_DYNAMIC_RULES = 30000`，其中"unsafe"（`modifyHeaders` 属于 unsafe）`MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES = 5000` | [A/§8-A2、§8-A16] |
| 会话（`updateSessionRules`） | **浏览器关闭即清空；扩展被更新也清空**；"backed in memory" | `MAX_NUMBER_OF_SESSION_RULES = 5000`（unsafe 同为 5000） | [A/§8-A2、§8-A16] |
| 正则规则 | —— | 每种类型 `MAX_NUMBER_OF_REGEX_RULES = 1000`，且单条编译后 < 2KB | [A/§8-A15、§8-A16] |

对 E4 的含义：每条任务大约 1–2 条 `modifyHeaders` 规则（请求头 1 条、响应头 1 条），5000 条 unsafe 会话规则 ≈ 2500 个并发任务的上限——**配额不是瓶颈，清理时机才是**。

**何时必须清理**（按"谁先失效"整理）：

1. 任务结束/失败 → `updateSessionRules({removeRuleIds})`（否则规则会一直改该 URL 的请求）。
2. 引擎切换（Q-C5 规定有活动任务时禁止切换，所以切换时点天然安全）→ 清空本引擎全部规则。
3. **浏览器重启**：session 规则自动清空 [A]，但**动态规则会残留** [A] → 如果 E4 用动态规则存"常态化"的头注入，必须在 `runtime.onStartup` 时对账清理（"When a user profile starts, the browser.runtime.onStartup event fires but no service worker events are invoked." [A/§8-A17]）。
4. **扩展更新**：session 规则被清空 [A] → 在途任务会立刻失去规则（下载可能仍在继续，但后续同名请求不再被改），要么在 `onInstalled` 里重建、要么把在途任务标记为失败（R2）。
5. 标签页被关闭后：`tabIds` 不会复用（"Tab IDs are unique within a browser session." [A/§8-A11]），所以带 `tabIds` 的残留规则是**惰性**的——但仍占配额；而且如果残留规则**没有限定 `tabIds`**（等于对全浏览器生效），它会继续命中新请求。

### 3.4 执行上下文差异（本题核心视角）

| 上下文 | DNR API | `tabs.create/update/remove` | `downloads` 事件 | 说明 |
|---|---|---|---|---|
| MV3 Service Worker | ✅（§3.1 权限齐全时） | ✅ | ✅ | 唯一务实的宿主；但会被 Chrome 终止（"After 30 seconds of inactivity"；单次事件处理超过 5 分钟；`fetch()` 响应超过 30 秒），"if the service worker has gone dormant, an incoming event will revive them" [A/§8-A17]。**规则本身由浏览器持有，不会被 SW 终止影响** [A/§8-A2：session rules "backed in memory"；B/§8-B18：规则由浏览器进程的 `RulesetManager` 评估] |
| 扩展页面 / popup | ✅ | ✅ | ✅ | 只在打开时存在；不能作为长期宿主 |
| **offscreen document** | ❌ | ❌ | ❌ | 官方原文："The runtime API is the only extensions API supported by offscreen documents." [A/§8-A18] → offscreen 只能"传话"，实现不了 E4 的任何一步 |
| **content script（两种 world）** | ❌ | ❌ | ❌ | 官方原文列出可直接访问的 API 只有 `dom, i18n, storage, runtime.*`："Content scripts are unable to access other APIs directly." [A/§8-A19] |
| 页面（MAIN world） | ❌ | ❌ | ❌ | 无扩展 API |

**推论**：E4 的"规则 + 触发 + 监听"三件事**必须落在 SW（或扩展页面）**，且监听器必须在 SW 顶层同步注册才能在 SW 休眠后被唤醒 [C，结合 A17 的"incoming event will revive them"与 MV3 常规约束]。offscreen/content script 只能承担 UI/桥接。

---

## 4 能力映射

### 4.1 原子能力（对照 R11 的 bool 能力集合）

| 能力 | E4 能否声明 | 依据 / 代价 |
|---|---|---|
| `withHeader` | **能，但"有条件"** | `append` 仅 21 项白名单 [A/§8-A7][B/§8-B6]；`set`/`remove` 无名字白名单但也无"支持哪些头"的官方承诺 → 声明 `withHeader` 时必须同时给出"能注入的头清单从哪来"的说明，否则违反 R2/R10 的精神 |
| 进度上报（真实性） | **不能由 E4 自己提供** | DNR/tabs 路径不产生任何进度回调；必须靠 `chrome.downloads`（§4.3） |
| 文件名控制 | **能（两种手段）** | ① 响应头 `Content-Disposition` [A/§8-A1][B/§8-B8]；② `onDeterminingFilename` 覆盖（"as a path relative to the user's default Downloads directory, possibly containing subdirectories. Absolute paths, empty paths, and paths containing back-references ".." will be ignored."）[A/§8-A9] |
| 保存目录（`dir`） | **不能** | 路径只能是 Downloads 目录下的**相对**路径 [A/§8-A9]；tab 触发的下载连相对路径都不给，完全由浏览器设置决定（附录 A.4.1 记录正确） |
| 暂停/恢复/取消/删除 | **间接能** | 关联到 `DownloadItem.id` 后可调 `chrome.downloads.pause/resume/cancel/erase` [A/§8-A9] |
| 单线程以外的并发/多连接（`multithread`） | **不能** | 每条任务 = 一个标签页 + 一条浏览器下载流；附录 A.4.5 记录正确 |
| 并发任务 | **能但脆弱** | 每任务一个标签页；但规则按 URL 匹配、下载关联也按 URL → **同一 URL 的并发任务会互相污染**（§5.7） |
| POST / 自定义方法 | **不能** | `tabs.create/update` 只给 URL，无 body [A/§8-A11] |
| 认证/危险文件策略 | **不可控** | 完全交给浏览器的下载 UX（见 §5.9） |

### 4.2 一条任务的最小动作序列

```jsonc
// 规则 1：请求头注入（示例：append Cookie；set 白名单外的头属未验证区）
{ "id": 1001, "priority": 1,
  "action": { "type": "modifyHeaders",
    "requestHeaders": [ { "header": "Cookie", "operation": "append", "value": "sessionid=…" } ] },
  "condition": { "urlFilter": "|https://example.com/file.bin|",
                 "resourceTypes": ["main_frame"],      // ← 不写就完全不生效
                 "tabIds": [12345] } }                  // ← 只有 session 规则支持
// 规则 2：强制下载 + 文件名
{ "id": 1002, "priority": 1,
  "action": { "type": "modifyHeaders",
    "responseHeaders": [ { "header": "Content-Disposition", "operation": "set",
                           "value": "attachment; filename=\"file.bin\"" } ] },
  "condition": { "urlFilter": "|https://example.com/file.bin|", "resourceTypes": ["main_frame"], "tabIds": [12345] } }
```

### 4.3 与 E1 的合流点（**本题要求明确写出的依赖关系**）

E4 **不能**自己回答"下载开始了没有、下了多少、成功还是失败"。唯一可行的观测通道是 `chrome.downloads`：

1. **拿到句柄**：`downloads.onCreated`（DownloadItem 全文）或 `downloads.onDeterminingFilename`（更早）[A/§8-A10]。
2. **进度**：`onChanged` **不推送** `bytesReceived`/`estimatedEndTime`——原文："When any of a DownloadItem's properties **except bytesReceived and estimatedEndTime** changes, this event fires…" [A/§8-A10]；`DownloadDelta` 字段表里也确实没有 `bytesReceived` [A/§8-A10] → **进度只能靠轮询 `downloads.search({id})` 读 `bytesReceived`/`totalBytes`**（`DownloadQuery.id` 与 `DownloadItem.bytesReceived/totalBytes` 均支持 [A/§8-A9]）。这正好落在 Q-B7 的补充裁定上（"若引擎能…主动轮询取得真实进度…则按真实进度上报"）。
3. **状态机**：`onChanged` 的 `state`（`in_progress` → `complete` / `interrupted`）[A/§8-A9、A10]，`error`（`InterruptReason` 枚举，含 `NETWORK_*`/`SERVER_*`/`FILE_*`/`USER_*`）[A/§8-A9]。
4. **文件名/路径**：`DownloadItem.filename`（绝对本地路径）、`finalUrl`、`mime`、`referrer`、`startTime`、`endTime`、`exists`、`danger`、`incognito` [A/§8-A9]。
5. **关联手段**：`DownloadItem` **没有 `tabId` 字段**（字段表里没有）[A/§8-A9] → 只能按 `url`/`finalUrl` + `startTime`/`startedAfter` 匹配（`DownloadQuery` 支持 `id`、`url`、`urlRegex`、`finalUrl`、`finalUrlRegex`、`startedAfter`、`startedBefore`、`state`、`mime`、`filename`、`filenameRegex`、`limit`、`orderBy` 等）[A/§8-A9]。

⇒ **明确写出**：**E4 的实现必然包含一个"E1 式"的 `chrome.downloads` 观测层**；如果连"下载确实开始了"都拿不到（关联失败、`onCreated` 未到），E4 就只能按 Q-B7 的姿态 **b**（只在开始/结束两个瞬间改状态），而且**必须把"没观测到"当成可上报的失败（R2）**，不能假装成功。

---

## 5 失败模式与盲区

| # | 失败模式 | 后果 | 依据 |
|---|---|---|---|
| 5.1 | `resourceTypes` 未写 `main_frame`（或用 `excludedResourceTypes` 排除了它） | **规则对导航完全不生效且不报错**：响应头没被改写 → 文件名丢失、可渲染类型直接在标签页里打开；请求头也没注入 | [B/§8-B5]，[A/§8-A4] |
| 5.2 | 目标响应由 Service Worker 生成或命中 CacheStorage | DNR 完全看不到该响应（"won't affect responses generated by the service worker or retrieved from CacheStorage"） | [A/§8-A8] |
| 5.3 | 缺少该 URL 的 host 权限 | 规则不生效（静默） | [A/§8-A3] |
| 5.4 | 其它扩展的高优先级 `allow`/`allowAllRequests` 规则命中同一请求 | 本扩展规则被整体绕过 | [A/§8-A5] |
| 5.5 | 规则残留（SW 崩溃、浏览器重启后动态规则仍在、扩展更新清空 session 规则） | 长期静默改变该 URL 的请求行为；或反之，在途任务丢失规则 | [A/§8-A2、§8-A16、§8-A17] |
| 5.6 | 规则未用 `tabIds` 收窄 | 用户/其它标签页访问同一 URL 时也被改头或强制下载（**跨场景污染**） | [A/§8-A4/A5]，[B/§8-B14] |
| 5.7 | 同一 URL 的并发任务 / 用户手动下载同一 URL | 关联错配：把别人的 `DownloadItem` 当成自己的任务；进度/文件名/状态全部张冠李戴 | [A/§8-A9]（DownloadItem 无 tabId） |
| 5.8 | 注册了 `onDeterminingFilename` 但没正确 `suggest()` | **卡住全 profile 的下载**：“The DownloadItem will not complete until all listeners have called suggest… Each extension may not register more than one listener for this event.” | [A/§8-A10] |
| 5.9 | 浏览器的下载 UX/安全策略介入（"询问保存位置"、危险文件拦截、下载气泡） | 下载挂起或需要用户交互；aria2 语义无法表达 → 必须映射成错误或"条件性可用"（Q-B5） | [A/§8-A9：`saveAs`、`danger`/`DangerType`；🟠具体到 tab 触发的行为未验证] |
| 5.10 | 标签页副作用：必须真的开一个标签（`active:false` 只是"不激活"，"Does not affect whether the window is focused"） | 用户能看见标签条变化；想更隐蔽只能 `windows.create({focused:false})`（"If false, opens an inactive window."）多开一个窗口 | [A/§8-A11、§8-A20] |
| 5.11 | 后台标签页被冻结/丢弃（`frozen` Chrome 132+、`discarded`、`autoDiscardable`） | 对**已开始**的下载是否有影响：🟠未验证 | [A/§8-A11] |
| 5.12 | 关闭标签页的时机 | 过早 `tabs.remove()` 是否中断"从导航截下来"的下载：🟠未验证（下载已由下载系统持有，但导航被中断的路径未验证） | [B/§8-B9] |
| 5.13 | 无痕（incognito）窗口 | 规则/事件在无痕 profile 的行为（扩展需被允许在无痕中运行、`DownloadItem.incognito` 语义）：🟠未验证 | [A/§8-A9] |
| 5.14 | SW 生命周期 | SW 在"规则已装、下载未开始"的窗口期内被终止：规则仍在（浏览器持有），但**触发与监听要靠事件唤醒 SW**；唤醒失败/监听器未顶层注册 → 任务无出口 | [A/§8-A17、§8-A18、§8-A19] |
| 5.15 | 死等固定秒数（附录 A 的"等几秒"） | 慢站点 → 误判失败并清理规则（下载随后才开始，变成无规则的下载）；快站点 → 白等 | 本报告 §2.4 的推导 |

---

## 6 与现有裁定的冲突

### 6.1 R9 / D2（拦截发生在 JS API 层，DNR 不是同一条路）

- **不冲突**：E4 是**下载引擎**路线，不是 RPC 转发器路线；R9 关于"转发器在 JS API 层短路"的裁定不受影响。
- **需要在能力报告里说清**：E4 **确实**使用 DNR（网络层），因此 R9 里那句"DNR 走网络层，拿不到返回任意响应体的能力"对 E4 同样成立——E4 不能用来伪造 RPC 响应，只能用来搬运字节。
- **需要额外注意**：E4 的 DNR 规则命中 URL 是"精准匹配的 `urlA`"（Q-D1 的同款风格），但**它作用在真实网络请求上**，而转发器作用在 JS API 层。若某个被监听的 RPC 地址同时出现在下载 URL 上，两条链路会同时命中同一地址，需要显式互斥。

### 6.2 Q-B7（进度姿态）

- E4 自身**没有**进度来源 → 若不合流 E1，则只能按姿态 **b**（开始/结束两瞬间）。
- 裁定补充允许"引擎拿到 `DownloadItem` 句柄后主动轮询 `bytesReceived`/`totalBytes` 就按真实进度上报"——**E4 只能走这条**，且轮询而非事件（§4.3 的 `onChanged` 不含 `bytesReceived`）[A/§8-A10]。
- **冲突点**：裁定假设"引擎能拿到句柄"。E4 的句柄是**猜出来的**（URL+时间关联），因此必须在设计里显式定义"关联失败"的行为——建议归入 Q-B5 的运行期错误（自定义状态码 + 信息），而不是伪装成功。

### 6.3 Q-D5（只有浏览器彻底退出才模拟 aria2 重启）与 Q-C5（有活动任务时禁止切换引擎）

- **一致的部分**：`updateSessionRules` 的规则"不跨会话、存内存"，浏览器关闭即清空 [A/§8-A2] → 语义上与"浏览器退出才重启"吻合；SW 被终止不影响规则（规则在浏览器进程持有）[A/§8-A2、B/§8-B18] → 与"SW 重启不构成重启"吻合。
- **冲突/待办**：
  1. **动态规则会跨浏览器重启残留** [A/§8-A2] → 若 E4 用动态规则，必须在 `runtime.onStartup` 对账清理，否则"重启后仍被改头"会违反 Q-D5 的模拟语义。**结论：E4 应只用 session 规则**（也正好因为 `tabIds` 只支持 session 规则 [A/§8-A4]）。
  2. 规则 id ↔ 任务 id 的映射**必须落存储**（不能放 SW 内存）：`Any global variables you set will be lost if the service worker shuts down.` [A/§8-A17]；这也是 Q-D5 的既有要求。
  3. 扩展更新会清空 session 规则 [A/§8-A2] → 在途任务需要"重启后对账 → 标记失败/重建"的策略，否则会出现"任务在进行但规则没了"的静默错误。

### 6.4 R13（用户可调整默认参数，例如保存目录）

- E4 **完全无法**满足 `dir`：路径只能相对 Downloads 目录（`onDeterminingFilename`/`DownloadOptions.filename` 都是"relative to the user's default Downloads directory"）[A/§8-A9]，而 tab 触发的下载由浏览器设置决定（附录 A.4.1 已记录）。
- ⇒ 引擎能力报告必须写明这一点；Mock 层对 `dir` 参数只能返回错误或"伪装还原"（按 R3/R10 逐接口裁定）。

### 6.5 R2 / R10（诚实）与附录 A 的"等几秒"

- 附录 A 的固定等待**违反 R2 的精神**（无法区分"还在下"和"失败了"）。必须替换为 §2.4 的事件 + 超时 + 明确错误。

### 6.6 R12（同时只启用一个引擎）——需要用户/文档层澄清的一点

- 如果 E4 只作为 E1 的"header 补丁层"，那它**不是一个独立引擎**，而是 E1 引擎内部的一个实现细节 → 与 R12 无冲突，但**需要概念层确认**（本报告不改裁定，只标出该问题）：引擎的原子能力声明若包含 `withHeader`，必须说明它是"downloads API 的头"还是"含敏感头"。

---

## 7 未验证（必须实测才能定稿的清单）

> 本环境**没有任何浏览器二进制**（`google-chrome`/`chromium` 均不存在，无 Playwright），下列全部为**运行期行为**，一律 🟠未验证。每条给出最小验证方式。

1. **整链是否跑通**：导航 + 两条规则是否真的产生 `DownloadItem`；`onCreated` 是否到达 SW。验证：unpacked 扩展 + `onRuleMatchedDebug`（`declarativeNetRequestFeedback`）+ 一个返回 `application/octet-stream` 与一个返回 `text/html` 的测试端点。
2. **`resourceTypes` 缺省是否真的漏掉 `main_frame`**（源码已证，但需实测确认端到端症状）。
3. **DNR `set` 能否设置白名单外的头**（`Referer`/`Origin`/`Host`/`Authorization`/自定义头），以及 `set cookie` 与浏览器 cookie jar 的合并结果。
4. **`append cookie` 的实际效果**：是否保留 jar 里的 cookie、顺序、是否重复。
5. **导航被转成下载时**：`webNavigation.onCompleted` / `onErrorOccurred`（`ERR_ABORTED`?）、`tabs.onUpdated.status`、标签页最终停在哪个 URL。
6. **`onCreated` 是否覆盖导航型下载**（源码推断覆盖，未实测）；`onDeterminingFilename` 是否也覆盖它。
7. **关闭标签页的时机**是否影响下载（`onCreated` 后立即 `tabs.remove`）。
8. **后台标签页被冻结/丢弃**是否影响进行中的下载。
9. **关联可靠性**：同 URL 并发、重定向（`url` vs `finalUrl`）、用户同时手动下载同一 URL 时的错配率。
10. **扩展页面（有 rfh）调用 `chrome.downloads.download()` 时 DNR 是否生效**（附录 A 前提的边界条件；本报告与 E1 文档 §2.3 的源码结论一致：会经过 DNR，但无浏览器实测）。
11. **无痕窗口**下的规则与事件行为。
12. **`offscreen` 文档只能访问 runtime** 已由文档确认 [A]，但"通过 SW 中转"的可行性（延迟/唤醒）未验证。
13. **`modifyHeaders` 是否严格要求 host 权限**：文档只写了""declarativeNetRequest" 隐式覆盖 `allow`/`allowAllRequests`/`block`"与"`declarativeNetRequestWithHostAccess` … you must request host permissions before you can perform any action on a host"，**没有一句逐字针对 `modifyHeaders`**。验证：无 host 权限 + 一条 `modifyHeaders` 规则，看 `updateSessionRules` 是否成功、`getMatchedRules`/`onRuleMatchedDebug` 是否命中。
14. **响应头 `append` 是否真的不受 21 项白名单约束**（源码只在请求头分支做白名单校验 [B/§8-B17]）：实测给响应头 append 一个不在白名单里的名字。
15. **规则更新与导航的时序保证**：`updateSessionRules()` promise resolve 之后立即 `tabs.update` 发起导航，规则是否**必然**已生效（文档只承诺"promise resolves once the update is complete"，没有逐字承诺对随后请求的可见性顺序）。

---

## 8 证据清单

> 抓取日期均为 **2026-10-06（UTC）**。文档页会更新，`Last updated` 一并给出；源码引用为 `chromium/src@main` HEAD `a4f419a12645`。

### 8.1 官方文档（[A]）

| ID | 主题 | URL | 原文摘录（逐字） |
|---|---|---|---|
| A1 | DNR API 参考（规则、动作、类型、方法、事件） | https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest （Last updated **2026-09-11 UTC**） | `RuleAction.requestHeaders` / `responseHeaders`: "The request headers to modify for the request. Only valid if RuleActionType is "modifyHeaders"."；`ModifyHeaderInfo.value`: "The new value for the header. Must be specified for `append` and `set` operations."；`getMatchedRules()`: "This method is only available to extensions with the "declarativeNetRequestFeedback" permission or having the "activeTab" permission granted for the tabId specified in filter."；`onRuleMatchedDebug`: "Only available for unpacked extensions with the "declarativeNetRequestFeedback" permission" |
| A2 | 动态 / 会话规则集 | 同上（"Dynamic and session-scoped rulesets"） | "Dynamic rules persist across browser sessions and extension upgrades."；"Session rules are cleared when the browser shuts down and when a new version of the extension is installed."；`updateSessionRules()`: "This update happens as a single atomic operation: either all specified rules are added and removed, or an error is returned." / "These rules are not persisted across sessions and are backed in memory." / "Promise that resolves once the update is complete." |
| A3 | 权限模型 | 同上（"Permissions"） | ""declarativeNetRequest" …provides implicit access to allow, allowAllRequests and block rules."；""declarativeNetRequestWithHostAccess" A permission warning is not shown at install time, but you must request host permissions before you can perform any action on a host." |
| A4 | `RuleCondition` | 同上（type RuleCondition） | `tabIds`: "List of tabs.Tab.id which the rule should match. An ID of tabs.TAB_ID_NONE matches requests which don't originate from a tab. An empty list is not allowed. **Only supported for session-scoped rules.**"；`excludedResourceTypes`: "…If neither of them is specified, all resource types except "main_frame" are blocked."；`responseHeaders`(Chrome 128+) / `initiatorDomains`(Chrome 101+) / `topDomains`(Chrome 145+) |
| A5 | 规则评估（请求 / 响应阶段） | 同上（"Before the request"、"Once a response is received"） | "Rules with a modifyHeaders action are not included here as they will be handled later."；"Once the response headers have been received, Chrome evaluates rules with a responseHeaders condition."；"If the request is not blocked or redirected, Chrome applies any modifyHeaders rules. … Applying modifications to request headers does nothing, since the request has already been made."；"Caution: Browser vendors have agreed not to standardize the order in which rules with the same action and priority run." |
| A6 | 改头的跨规则叠加顺序 | 同上（"Before request headers are sent"） | "If a rule appends to a header, then lower priority rules can only append to that header. Set and remove operations are not allowed. If a rule sets a header, then only lower priority rules from the same extension can append to that header. No other modifications are allowed. If a rule removes a header, then lower priority rules cannot further modify the header." |
| A7 | **Header modification（append 白名单）** | 同上（"Header modification"） | "The append operation is only supported for the following request headers: accept, accept-encoding, accept-language, access-control-request-headers, cache-control, connection, content-language, **cookie**, forwarded, if-match, if-none-match, keep-alive, range, te, trailer, transfer-encoding, upgrade, user-agent, via, want-digest, x-forwarded-for. This allowlist is case sensitive (bug 449152902)." / "When appending to a request or response header, the browser will use the appropriate separator where possible." |
| A8 | 与 Service Worker / CacheStorage 的交互 | 同上（"Interactions with service workers"） | "A declarativeNetRequest only applies to requests that reach the network stack. This includes responses from the HTTP cache, but may not include responses that go through a service worker's onfetch handler. declarativeNetRequest won't affect responses generated by the service worker or retrieved from CacheStorage, but it will affect calls to fetch() made in a service worker." |
| A9 | `chrome.downloads` 参考 | https://developer.chrome.com/docs/extensions/reference/api/downloads （Last updated **2026-10-04 UTC**） | `DownloadOptions.headers`: "…restricted to those allowed by XMLHttpRequest."；`DownloadItem`: `bytesReceived` / `totalBytes` / `state` / `filename`（"Absolute local path."）/ `url`（"The absolute URL that this download initiated from, before any redirects."）/ `finalUrl`(Chrome 54+) / `startTime` / `endTime` / `mime` / `referrer` / `danger` / `incognito` / `error`；`DownloadQuery`: `id`/`url`/`urlRegex`/`finalUrl`/`startedAfter`/`limit`/`orderBy`；`FilenameSuggestion.filename`: "…as a path relative to the user's default Downloads directory, possibly containing subdirectories. Absolute paths, empty paths, and paths containing back-references ".." will be ignored."；Permissions: "You must declare the "downloads" permission…" |
| A10 | `chrome.downloads` 事件 | 同上（"Events"） | `onChanged`: "When any of a DownloadItem's properties **except bytesReceived and estimatedEndTime** changes, this event fires with the downloadId and an object containing the properties that changed."；`onCreated`: "This event fires with the DownloadItem object when a download begins."；`onDeterminingFilename`: "…Each extension may not register more than one listener for this event. Each listener must call suggest exactly once… **The DownloadItem will not complete until all listeners have called suggest.**" |
| A11 | `chrome.tabs` 方法与类型 | https://developer.chrome.com/docs/extensions/reference/api/tabs （Last updated **2026-09-24 UTC**） | `create()` 的 `active`: "Whether the tab should become the active tab in the window. Does not affect whether the window is focused (see windows.update). Defaults to true."；`remove()`: "Closes one or more tabs."；`Tab.id`: "The ID of the tab. **Tab IDs are unique within a browser session.**"；`Tab.frozen`(Chrome 132+)/`discarded`/`autoDiscardable`；`onUpdated` 的 `changeInfo.status`("The tab's loading status.") 与 `TabStatus` 枚举 `"unloaded" / "loading" / "complete"` |
| A12 | `chrome.tabs` 权限 | 同上（"Permissions"） | "Most features don't require any permissions to use. For example: creating a new tab, reloading a tab, navigating to another URL, etc."；""tabs" permission …grants an extension the ability to call tabs.query() against four sensitive properties on tabs.Tab instances: url, pendingUrl, title, and favIconUrl." |
| A13 | `chrome.webNavigation` | https://developer.chrome.com/docs/extensions/reference/api/webNavigation （Last updated **2026-10-04 UTC**） | `onErrorOccurred`: "Fired when an error occurs and the navigation is aborted. This can happen if either a network error occurred, or the user aborted the navigation."；`onCompleted`: "Fired when a document, including the resources it refers to, is completely loaded and initialized."；Permissions: "All browser.webNavigation methods and events require you to declare the "webNavigation" permission…" |
| A15 | DNR 规则条数上限（"Rule limits" 小节） | 同 A1 | "An extension can specify up to 100 static rulesets… but only 50 of these rulesets can be enabled at a time."；"Collectively, those rulesets are guaranteed at least 30,000 rules."；"An extension can have up to 5000 session rules. This is exposed as the MAX_NUMBER_OF_SESSION_RULES."；"An extension can have at least 5000 dynamic rules. This is exposed as the MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES."；"Starting in Chrome 121, there is a larger limit of 30,000 rules available for safe dynamic rules, exposed as the MAX_NUMBER_OF_DYNAMIC_RULES."；"the total number of regular expression rules of each type cannot exceed 1000"；"each rule must be less than 2KB once compiled" |
| A16 | DNR 上限常量值（Properties） | 同 A1 | `MAX_NUMBER_OF_DYNAMIC_RULES = 30000`；`MAX_NUMBER_OF_ENABLED_STATIC_RULESETS = 50`（Chrome 94+）；`MAX_NUMBER_OF_REGEX_RULES = 1000`；`MAX_NUMBER_OF_SESSION_RULES = 5000`（Chrome 120+）；`MAX_NUMBER_OF_STATIC_RULESETS = 100`；`MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES = 5000`（Chrome 120+）；`MAX_NUMBER_OF_UNSAFE_SESSION_RULES = 5000`（Chrome 120+）；`GUARANTEED_MINIMUM_STATIC_RULES = 30000`（Chrome 89+）；"Safe rules are defined as rules with an action of block, allow, allowAllRequests or upgradeScheme."（⇒ `modifyHeaders` 属 unsafe 配额） |
| A17 | 扩展 Service Worker 生命周期 | https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle | "Normally, Chrome terminates a service worker when one of the following conditions is met: After 30 seconds of inactivity… When a single request, such as an event or API call, takes longer than 5 minutes to process… When a fetch() response takes more than 30 seconds to arrive."；"Events and calls to extension APIs reset these timers, and if the service worker has gone dormant, an incoming event will revive them."；"Any global variables you set will be lost if the service worker shuts down."；"When a user profile starts, the browser.runtime.onStartup event fires but no service worker events are invoked." |
| A18 | offscreen document 的 API 面 | https://developer.chrome.com/docs/extensions/reference/api/offscreen （Last updated **2026-09-21 UTC**） | "The runtime API is the only extensions API supported by offscreen documents." |
| A19 | content script 的 API 面 | https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts | "Content scripts can access the following extension APIs directly: dom, i18n, storage, runtime.connect(), runtime.getManifest(), runtime.getURL(), runtime.id, runtime.onConnect, runtime.onMessage, runtime.sendMessage(). Content scripts are unable to access other APIs directly." |
| A20 | `chrome.windows.create` | https://developer.chrome.com/docs/extensions/reference/api/windows （Last updated **2026-09-11 UTC**） | `focused`: "If true, opens an active window. If false, opens an inactive window." |

> 编号 A1–A20 已全部使用；后续补充证据请从 A21 起编号。

### 8.2 Chromium 源码（[B]）

源码 URL 形式：`https://chromium.googlesource.com/chromium/src/+/main/<path>`（`?format=TEXT` 取原文），HEAD `a4f419a12645`，核对日期 2026-10-06。

| ID | 文件 | 摘录 / 事实 |
|---|---|---|
| B1 | `content/browser/loader/download_utils_impl.cc`（`MustDownload`） | `if (net::HttpContentDisposition(*headers, /*referrer_charset=*/std::string()).is_attachment()) { return true; }` |
| B2 | 同上（`IsDownload`） | `if (MustDownload(...)) return true; if (blink::IsSupportedMimeType(mime_type)) return false; return !headers \|\| headers->response_code() / 100 == 2;` |
| B3 | `net/http/http_util.cc`（`IsSafeHeader` + `kForbiddenHeaderFields`） | 注释："A header string containing any of the following fields will cause an error. **The list comes from the fetch standard.**"；列表含 `cookie`（"cookie", "cookie2"）、`host`、`origin`、`referer`、`set-cookie`、`user-agent` 等；另拒绝 `proxy-*` / `sec-*` 前缀 |
| B4 | `chrome/browser/extensions/api/downloads/downloads_api.cc` | `if (auto* rfh = render_frame_host(); rfh) { download_params = rfh->CreateDownloadUrlParameters(...); } else { // Service-worker-based extensions may have no associated \`rfh\`. download_params = std::make_unique<download::DownloadUrlParameters>(...); download_params->set_render_process_host_id(source_process_id()); }`；请求头逐个过 `net::HttpUtil::IsSafeHeader` / `IsValidHeaderName` / `IsValidHeaderValue`，失败即 `kInvalidHeaderUnsafe` 等错误 |
| B5 | `components/url_pattern_index/url_pattern_index.h` + `extensions/browser/api/declarative_net_request/indexed_rule.cc` | `constexpr uint16_t kDefaultFlatElementTypesMask = flat::ElementType_ANY & ~flat::ElementType_MAIN_FRAME;`；`ComputeElementTypes()` 在既无 `resourceTypes` 也无 `excludedResourceTypes` 时 `*element_types = url_pattern_index::kDefaultFlatElementTypesMask;` ⇒ **默认不含 main_frame** |
| B6 | `extensions/browser/api/declarative_net_request/constants.h`（browser 目录下的同名文件） | `// An allowlist of request headers that can be appended onto, in the form of (header name, header delimiter). Currently, this list contains all standard HTTP request headers that support multiple values in a single entry.`；`kDNRRequestHeaderAppendAllowList` 含 `{"cookie", "; "}`、`{"user-agent", " "}`、`{"trailer", ""}` 等 21 项 |
| B7 | `extensions/browser/api/web_request/web_request_api_helpers.cc` | 响应头：`create_override_headers_if_needed()` 复制原始头后 `RemoveHeader`/`AddHeader`（set）、`AddHeader`（append）、`RemoveHeader`（remove）；请求头：`GetDNRNewRequestHeaderValue()` = 已有值 ＋ 白名单里的分隔符 ＋ 新值；`ConflictsWithSubsequentAction()` 实现文档里的叠加规则 |
| B8 | `extensions/browser/api/web_request/web_request_proxying_url_loader_factory.cc` | `current_response_->headers = override_headers_;`（`OverwriteHeadersAndContinueToResponseStarted()`），并有注释说明导航/worker 请求会重解析 `ParsedHeader` 以反映改写后的头 ⇒ **改写后的响应头就是下游（含下载判定）看到的头** |
| B9 | `content/browser/download/download_manager_impl.cc` | 导航型下载走 `InterceptDownloadFromNavigation(..., std::move(response_head), std::move(response_body), std::move(url_loader_client_endpoints), CreatePendingSharedURLLoaderFactory(storage_partition, render_frame_host), is_transient);` ⇒ 不是重新发请求，而是把在飞的导航响应交给下载系统 |
| B10 | `chrome/browser/extensions/api/downloads/downloads_api.cc`（`ShouldExport`） | `return !download_item.IsTemporary() && download_item.GetDownloadSource() != download::DownloadSource::INTERNAL_API;`（`ExtensionDownloadsEventRouter::OnDownloadCreated(DownloadManager* manager, DownloadItem* download_item)` 观察整个 profile 的 DownloadManager） |
| B11 | `components/download/public/common/download_source.h` | `NAVIGATION = 1, // Download is triggered from navigation request.`；`INTERNAL_API = 6, // Download service API background download.`（被 B10 排除的只有 INTERNAL_API） |
| B12 | `content/browser/download/download_manager_impl.cc`（`CreatePendingSharedURLLoaderFactory`） | `if (rfh) { … GetContentClient()->browser()->WillCreateURLLoaderFactory(… ContentBrowserClient::URLLoaderFactoryType::kDownload, …) }` ⇒ 只有**有关联 RenderFrameHost** 的下载才可能被扩展的 loader factory 代理；`URLLoaderFactoryType::kDownload` 定义见 `content/public/browser/content_browser_client.h`（"// For downloads."） |
| B13 | `extensions/browser/api/web_request/web_request_permissions.cc`（`HideRequest`） | `// Hide all non-navigation requests made by the browser. crbug.com/40092481.` / `if (!request.is_navigation_request) { return true; }` ⇒ 浏览器发起的**非导航**请求对 webRequest/DNR 不可见 |
| B14 | `extensions/browser/api/web_request/web_request_api.cc` | 导航请求会带上 tab/window：`is_navigation` 分支里 `ExtensionsBrowserClient::Get()->GetTabAndWindowIdForWebContents(...)` → `ExtensionNavigationUIData(frame, tab_id, window_id)` ⇒ `tabIds` 条件对导航请求可用 |
| B15 | `extensions/browser/api/declarative_net_request/constants.h` | `inline constexpr int kMaxStaticRulesPerProfile = 300000;`、`kMaxDisabledStaticRules = 5000`、`kRegexMaxMemKb = 2` ⇒ 静态规则的**全局**配额与单条正则大小限制 |
| B16 | `chrome/browser/extensions/api/chrome_extensions_api_client.cc`（`ShouldHideResponseHeader`） | 只对 Gaia 主机的 Dice / Mirror 响应头隐藏（OAuth 泄漏防护）⇒ 与 `Content-Disposition` 无关，DNR 改 `Content-Disposition` 不会被这一钩子挡掉 |
| B17 | `extensions/browser/api/declarative_net_request/indexed_rule.cc`（`ValidateHeadersForModification`） | 头名必须过 `net::HttpUtil::IsValidHeaderName`（否则 `ERROR_INVALID_HEADER_TO_MODIFY_NAME`）；`if (are_request_headers && header_info.operation == dnr_api::HeaderOperation::kAppend) { if (!kDNRRequestHeaderAppendAllowList.contains(base::ToLowerASCII(header_info.header))) return ParseResult::ERROR_APPEND_INVALID_REQUEST_HEADER; }` ⇒ **白名单只约束请求头**；`remove` 带 `value` → `ERROR_HEADER_VALUE_PRESENT`；`append`/`set` 缺 `value` → `ERROR_HEADER_VALUE_NOT_SPECIFIED` |
| B18 | `extensions/browser/api/web_request/extension_web_request_event_router.cc`（`OnBeforeRequest` / `OnHeadersReceived`） | `declarative_net_request::RulesetManager* ruleset_manager = declarative_net_request::RulesMonitorService::Get(browser_context)->ruleset_manager(); if (ruleset_manager->HasRulesets(…kOnBeforeRequest)) { … const std::vector<DNRRequestAction>& actions = ruleset_manager->EvaluateBeforeRequest(*request, is_incognito_context); … }` ⇒ DNR 规则由**浏览器进程**的规则管理器评估（不在 SW 内，不随 SW 终止消失）；响应阶段同理走 `EvaluateRequestWithHeaders` |
| B19 | `extensions/browser/api/web_request/web_request_info.cc` | `WebRequestResourceType ToWebRequestResourceType(const network::ResourceRequest& request, bool is_download) { if (request.url.SchemeIsWSOrWSS()) return WebRequestResourceType::WEB_SOCKET; if (is_download) { return WebRequestResourceType::OTHER; } … }` ⇒ 只有"下载子系统发起的请求"才被归类为 `other` |
| B20 | `extensions/browser/api/web_request/web_request_proxying_url_loader_factory.cc`（`IsForDownload`） | `bool WebRequestProxyingURLLoaderFactory::IsForDownload() const { return loader_factory_type_ == content::ContentBrowserClient::URLLoaderFactoryType::kDownload; }` ⇒ 导航型下载（`kNavigation`）不算 download ⇒ DNR 看到的是 `main_frame` |

### 8.3 抓取失败的来源（供后续复核）

| 来源 | 情况 |
|---|---|
| `web_search` 工具 | 本会话不可用（搜索端点报 `fetch failed`），改用直连官方文档/源码 |
| DuckDuckGo / Mojeek 网页搜索 | 202 / 403，未能用于检索第三方讨论 |
| `issues.chromium.org`（Chromium issue tracker） | 未尝试抓取（JS 渲染）；如需"官方 bug 编号"证据，建议另开一轮（本报告未引用任何 issue） |
| Chrome 实际版本号 | 本机无浏览器，**无法核对当前 stable 版本**；报告中的版本信息一律为文档自带的 `Chrome XX+` 标注（快照里出现的最高标注为 `Chrome 155+`，见 `tabs.create` 的 `splitWithTabId`） |

---

## 附：本报告对附录 A 的修正清单（供概念文档后续引用，**本报告不改概念文档**）

| 附录 A 的原始记录 | 修正 |
|---|---|
| A.2 第 1 条：加 DNR 拦截请求、注入 header | 需补：`condition.resourceTypes` 必须含 `main_frame`；`append` 受 21 项白名单限制；`set` 无官方支持清单 |
| A.2 第 2 条：加 DNR 拦截响应、写 `Content-Disposition` | 成立；补充：改写后的响应头确实是下游可见的头（B8）；对不可渲染的 MIME 类型这一步只是"顺带"，文件名才是它的不可替代作用 |
| A.2 第 3 条：`chrome.tabs` 打开、等几秒 | "等几秒"应替换为：`await updateSessionRules()` → `await tabs.create/update()` → `downloads.onCreated/onDeterminingFilename` 事件 → 超时即报错；`tabIds` 作用域要求"先建 tab 再装规则" |
| A.3 "`chrome.downloads` 触发的下载会无视改请求头的 DNR" | 官方文档**无此表述**；源码层面在 **MV3 SW** 场景有两条支持线索（B12+B13）⇒ 该断言只在 MV3 SW 场景成立。从**扩展页面**（有 rfh）发起时源码显示会经过 DNR（与 E1 文档 §2.3 一致），仍无实测 |
| A.4.3 "等待几秒的时间依赖" | 已给出确定性替代（§2.4） |
| A.4.4 "`withHeader` 可达，途径不是 `chrome.downloads`" | 成立，但"可达"限于：`append` 白名单 + `set` 未验证区 |
| A.4.6 "标签页是否可见/能否自动关闭" | `active:false` 仅"不激活"；标签条仍会出现；自动关闭用 `tabs.remove`（时机风险未验证） |
| A.4.7 "DNR 是扩展级规则、对所有匹配请求生效" | 成立；补充收窄手段（`tabIds` 仅 session 规则、`initiatorDomains`/`requestDomains`/`urlFilter`）与清理时机（§3.3） |
| **新增（与 E1 的口径对齐）** | E4 的导航请求在 DNR 眼里是 `main_frame`（`kNavigation`），E1 若用 DNR 命中 downloads 请求则是 `other`（`kDownload`，见 §2.5.1、B19/B20）；规则不能互相套用 |
| **新增** | ⑥ 进度/状态的唯一来源是 `chrome.downloads`；`onChanged` 不含 `bytesReceived` → 必须轮询 `search`；`DownloadItem` 无 `tabId` → 关联是"猜"的（§4.3、§5.7） |
