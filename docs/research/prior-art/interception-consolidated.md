# 拦截三问 对照总结（t14 × t15 合并版）

> 本文件是 `aria2-in-browser` 项目「浏览器技术边界测绘」的**合并结论文档**：把同一题目由两名研究员**各自独立**完成的两份调研（A / B）逐条对照，给出**唯一的、带依据的**合并结论。
> **输入（两份都存在，均已完整阅读）**：
> - A = `/workspace/docs/research/prior-art/interception-three-questions.md`（研究员 prior-intercept-a，任务 t14）
> - B = `/workspace/docs/research/prior-art/interception-three-questions-2.md`（研究员 prior-intercept-b，任务 t15）
>
> **本文不推翻也不需要读者重读 A/B**：§2 是逐条对照表，§1/§5/§7 是可直接引用的合并结论。A/B 原文中未被本文裁定推翻的细节，仍以 A/B 为最细来源。

---

## 0 元信息

| 项 | 值 |
|---|---|
| 文档性质 | **合并结论（输入文档）**，不做设计、不含代码 |
| 任务 | `t20`（attempt 1），执行者 `sum-intercept-diff` |
| 日期 | **2026-10-06**（本文所有 URL 均为该日或该日之前抓取；A/B 的抓取日期同为 2026-10-06） |
| 输入 A | 663 行；113 处 URL 引用 / **57 个去重来源**（本文统计口径：正则抓取 `http(s)://` 链接后去重；与 A/B 自报的数字因口径不同可能有 ±1 差异） |
| 输入 B | 834 行；91 处 URL 引用 / **53 个去重来源**（同上口径） |
| 阅读前提 | 已读 `/workspace/docs/concept-design/concept-design.md` v0.5（R4、R5、R9、Q-D1、§6） |
| 本次对照方法 | ① 两份文档**逐节逐表**对照；② 对**分歧点**回到官方文档 / 规范 / Chromium 源码（`refs/heads/main` 与**历史 tag 逐版本比对**）/ 线上扩展 CRX 解包产物 / npm 包源码**重新取证**；③ 对两份共同给出的关键结论**抽样独立复核**；④ 复核不到的，一律标注「未验证」或「待裁定」 |
| 标记约定 | ✅ 一致 ｜ 🔁 侧重点不同但可兼容 ｜ ❌ 表述冲突（本文已裁定） ｜ ❓ 两份均无证据 ｜ **【本文复核】** = 本文重新取证过的条目 |

**证据等级**（沿用 B 的标记，便于交叉引用）

- **A** = 官方规范 / 官方文档（WHATWG、Chrome for Developers、MDN）
- **B** = Chromium 源码（`chromium.googlesource.com`）
- **C** = 开源项目源码 / README / **发布产物（CRX 解包、npm 包）**
- **D** = 厂商官方文档 / 官方博客（闭源产品的官方说明）
- **E** = 推断（无直接出处）

**本文复核新增的证据（供下游直接引用，详表见 §8.1）**

1. 【本文复核】DNR「跳过其它扩展发起的非 main_frame 请求」的引入版本**精确到 Chrome 129**：`ruleset_manager.cc` 在 `128.0.6613.84`、`128.0.6613.137` **无**该分支，在 `129.0.6668.0`、`129.0.6668.58`、`130.0.6723.1` **有**（逐 tag 抓取比对）。→ 解决了 A §9.4 的存疑项。
2. 【本文复核】A 关于 Chrome 117 引入 webRequest「其它扩展过滤」的版本核对**独立复现成功**（`116.0.5845.0` 无 / `117.0.5938.0` 有）。
3. 【本文复核】A 关于三个线上扩展的第一手结论（ModHeader / Requestly / Tamper Dev 的 manifest 与产物行为）**全部复现**；B 的「取证通道全失败」属**本环境当时的工具性失败**，不构成对 A 的反证。三份 CRX 本次成功下载并解包。
4. 【本文复核】B 的「host permission 的合法 scheme 不含 `chrome-extension`」与「user script 合法 scheme 不含 `SCHEME_EXTENSION`」两条源码引用**逐字复现**。
5. 【本文复核】「`isTrusted` 不可由脚本伪造」由规范升级为**确证**：DOM 标准中 `isTrusted` 带 **`[LegacyUnforgeable]`** 扩展属性 ⇒ 真事件实例上无法遮蔽。同时澄清 msw 的 `EventPolyfill` 之所以能写 `isTrusted = true`，是因为它**根本不是真 `Event`**（详见 §3-D7）。
6. 【本文复核】A §2.2 的事件名 `onSendRequest` **不存在**，官方事件名为 `onSendHeaders`（事实性笔误，本文已更正，见 §3-D10）。

---

## 1 合并结论（三问各一句）

1. **拦截转发标签页请求**：能"看到并改写"的途径共五层，但**在今天的 Chrome 上只有两层能"凭空回答一个请求"**——`chrome.debugger` + CDP `Fetch.fulfillRequest`（能返回任意响应体，代价是用户可见的调试信息条、与 DevTools 互斥、单调试器、企业策略可整体阻止）与 **MAIN world 的 JS API 层改写**（本项目 R9 所选路径，零用户可见成本）；`declarativeNetRequest`「能 block / redirect / modifyHeaders，但**没有任何合成响应体能力**」，MV3 观测型 `webRequest` 只能看不能改，MV2 阻塞式 `webRequest`（历史上唯一能用 `data:` 重定向在网络层造 body 的官方途径）在 Chrome 上已死（138 最后支持、139 起失效、2026-08-31 起 CWS 无 MV2；仅策略安装扩展例外，Firefox 仍保留）。
2. **fetch / XHR 劫持**：五个现成库（`ajax-hook` / `xhook` / `fetch-intercept` / `@mswjs/interceptors` / `sinon-nise`）**一律替换全局构造器或全局函数，没有一个去改原型方法**，因此**必须在 MAIN world（页面 realm）执行**、且**必须早于页面第一次取到 `fetch` / `XMLHttpRequest`**；伪造只有两条硬底线——`Response` 必须用**真 `Response`** 再造（否则 `instanceof` / `Symbol.toStringTag` 露馅），`XMLHttpRequest` 必须包一个**真的原生实例**（纯 JS 伪对象过不了 WebIDL brand check，直接抛 `TypeError`）；可检测面集中在 `Function.prototype.toString`、属性描述符、全局绑定的 identity、事件对象与时序、同步 XHR，其中 `isTrusted` 属**规范级不可伪造**。
3. **能否拦截 / 修改其它扩展的网络请求**：**默认不能，且这是浏览器有意为之的四道独立闸门**——① content script 的 match pattern 合法 scheme 里**没有 `chrome-extension`**（Chromium `UserScript::ValidUserScriptSchemes`），别的扩展页面注入不进去；② `webRequest` 自 **Chrome 117** 起在事件分发层按渲染进程过滤掉"其它扩展发起的请求"；③ DNR 自 **Chrome 129** 起跳过"其它扩展发起的非 main_frame 请求"，且**任何**规则都不作用于 `chrome-extension:` 目标 URL；④ `chrome.debugger` 附加别的扩展页面 / Worker 需要命令行开关 `--extensions-on-extension-urls`（`extensionId` 目标还需 `--silent-debugger-extension-api`），浏览器级 target 只对 Perfetto UI 扩展开放。再加上 host permission 的合法 scheme 同样不含 `chrome-extension`，连"取到 initiator 权限"这条补救路也堵死。⇒ **第三方 aria2 前端扩展自己发出的 `localhost:6800` 请求接不住**；唯一可服务的是"跑在普通网页（或我们自己的扩展页）里、通过页面 realm 的 JS API 发 RPC 的前端"。

---

## 2 逐条对照表

> 表格读法：「是否一致」列的 ✅/🔁/❌/❓ 见 §0；「裁定 + 依据」列为最终采用的说法，冲突项已在 §3 展开。

### 2.1 第一问：拦截转发「标签页发出的请求」

| # | 议题 | A 的结论 | B 的结论 | 是否一致 | 裁定 + 依据 |
|---|---|---|---|---|---|
| 1.1 | MV2 阻塞式 `webRequest` 的平台现状 | Chrome 已死：**138 最后支持 / 139 起失效 / 2026-08-31 CWS 移除全部 MV2**；策略安装扩展例外；**Firefox MV3 仍保留**；Safari 不支持 | 同结论（引用同一官方时间线：Chrome 139 起失效、2026-08-31 CWS 清空；Firefox 保留） | ✅ | **采纳**。官方文档与时间线：<https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline>、<https://developer.chrome.com/docs/extensions/reference/api/webRequest>、<https://blog.mozilla.org/addons/2022/05/18/manifest-v3-in-firefox-recap-next-steps/>。实际含义：**对普通用户这条路已不存在**（非"有风险"，是"不可用"） |
| 1.2 | MV2 能否合成响应体 | **能**：`redirectUrl` 允许 `data:`（官方原文 "Redirections to non-HTTP schemes such as `data:` are allowed."）；Firefox 另有 `filterResponseData` 可完全控制响应体 | **能**：同一条 `data:` 原文 + Resource Override 源码实证；Firefox 侧 `filterResponseData` 单独标注 | ✅ | **采纳**。A/B 引同一条文档；Resource Override 源码（<https://github.com/kylepaulsen/ResourceOverride/blob/master/src/background/requestHandling.js>）给出 Chrome `redirectUrl:"data:…"` 与 Firefox `filterResponseData` 两种实现。**但平台已死（见 1.1），且 `data:` 重定向只能整体替换、无法按请求体动态生成**（两份均如此判断） |
| 1.3 | MV3 观测型 `webRequest` | 能看（含请求体、请求头、响应头、`initiator`），**不能 cancel / redirect / 改头** | 同结论；补充"响应体不可见；Chrome 侧没有 `filterResponseData`" | ✅ | **采纳**。官方原文 "Aside from `"webRequestBlocking"`, the webRequest API is unchanged and available for normal use."（webRequest 文档同页） |
| 1.4 | DNR 的能力边界 / **能否合成响应体** | **不能**：六个 action 穷举（block / upgradeScheme / allow / allowAllRequests / redirect / modifyHeaders），无一能携带响应体 | **不能**：同结论；并补一条**厂商侧证据**——Requestly 官方对照表把 `Serve local file Response` / `Modify HTML/JS/CSS Response` / `Map Local` 列为扩展 ❌、桌面应用 ✅ | ✅ | **采纳（两份证据互补）**。接口层依据：<https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest>（`RuleActionType` / `RuleAction` 只有 headers 字段）；厂商侧依据：<https://docs.requestly.com/account/how-is-browser-extension-different-from-a-desktop-app>。**结论：DNR 不能承担"冒充 aria2 RPC 服务端"** |
| 1.5 | DNR `redirect` 能否指向 `data:` | **未验证**（A §9.1）；补充判断"即便允许，也只能是规则里写死的静态字符串" | **未验证**（B U3）；补充"源码只显式拒绝 `javascript:`" | ✅（两份同判未验证） | **仍为未验证，但本次把边界收紧了一步**【本文复核】：`indexed_rule.cc` 的 `ParseRedirect()` 只对 `javascript:` 返回 `ERROR_JAVASCRIPT_REDIRECT`（<https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/browser/api/declarative_net_request/indexed_rule.cc>），DNR 文档也只写 "Redirects to JavaScript urls are not allowed." ⇒ **解析层不禁止 `data:`** ≠ **网络栈一定接受并生效**。结论不受影响（无论允许与否都造不出动 body）。详见 §4-① |
| 1.6 | CDP `Fetch.fulfillRequest` 能否返回自定义响应体 | **能**（协议 `body` 字段原文） | **能**；并给出 Tamper Dev v2 的调用源码 | ✅ | **采纳**。协议定义：<https://chromedevtools.github.io/devtools-protocol/tot/Fetch/>、机器可读 JSON <https://github.com/ChromeDevTools/devtools-protocol/blob/master/json/browser_protocol.json>（本次核对：`body` = "A response body. If absent, original response body will be used…"） |
| 1.7 | CDP 路线的代价 | ①用户可见横幅（除 `--silent-debugger-extension-api` / 策略安装）②DevTools 抢占即 detach ③**Chrome 155 起企业策略"全有或全无"**（`--disable-features=ExtensionDebuggerStrictPolicyRestrictions` 仅过渡，Chrome 160 移除）④`chrome.debugger` 不需要 host 权限但安装警告很吓人 ⑤每次拦截一次 CDP 往返 | ①必然弹"started debugging this browser"信息条（给出 `debugger_api.cc` + `generated_resources.grd` 的证据链）②DevTools 互斥 ③**同一目标只能有一个调试器**（`kAlreadyAttachedError`）④企业策略可阻止（引 `debugger` 文档小节）⑤不能做无声后台通道 | 🔁 | **合并采纳**：两边的清单**互补而非冲突**——A 独有"Chrome 155/160 的精确时间线"，B 独有"单调试器 + 信息条文案 + 源码证据"。**【本文复核】A 的时间线成立**：官方博客 <https://developer.chrome.com/blog/debugger-enterprise-policy-restrictions>（2026-09-08 发布）明确 Chrome 155 Stable 于 **2026-10-06** rollout、`--disable-features=…` 在 **Chrome 160 移除**；B 的 Perfetto 与 `kBrowserTargetId` 源码引用亦复现（见 1.8） |
| 1.8 | `chrome.debugger` 的附加范围 | tab 及其 OOPIF/worker 需按 Chrome 125+ flat session 逐个挂（`Target.setAutoAttach` + `sessionId`） | 除 tab/`setAutoAttach` 外，补一条**决定性限制**：浏览器级 target（`targetId:"browser"`）只对 Perfetto UI 扩展开放（`kBrowserTargetId` + `ExtensionIsTrusted`） | 🔁 | **合并采纳**：两者说的是不同层次。**【本文复核】B 的源码引用成立**：`debugger_api.cc` 中 `kBrowserTargetId[] = "browser"`、`ExtensionIsTrusted()` 仅认 `extension_misc::kPerfettoUIExtensionId`（<https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/extensions/api/debugger/debugger_api.cc>）。**含义：不存在"挂浏览器 target 再 setAutoAttach 到别人进程"的绕道** |
| 1.9 | MAIN world JS 改写 | 唯一"请求不发到网络"的通用路径；覆盖面取决于注入时机与 realm | 同结论，作为"本项目 R9 所选路径" | ✅ | **采纳**。注入面与隔离语义见 <https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts>、<https://developer.chrome.com/docs/extensions/reference/api/scripting>、<https://developer.chrome.com/docs/extensions/reference/api/userScripts> |
| 1.10 | **现成扩展：Requestly** | **拿到 CRX 产物**：manifest 含 `declarativeNetRequest`+`webRequest`+`scripting`+`proxy`+`tabs`+`webNavigation`，静态 ruleset `delayRules`/`headerRules`；`page-scripts/ajaxRequestInterceptor.ps.js` 里 hook `XHR.prototype.open/send/setRequestHeader/abort`、`XMLHttpRequest.prototype = rqProxyXhr`、`fetch = async (…) => {…}`，命中规则时 `new Response(…)`；SW 中 7 处 `world:"MAIN"` | **没拿到 manifest**（GitHub 默认分支已无 `browser-extension` 目录）⇒ 标未验证；只取到厂商对照表：扩展**不能** serve 本地文件 / 改 HTML-CSS-JS 响应 | ❌（表象冲突） | **裁定：两者都成立，描述的是不同资源类别，合起来才是完整图景**（详见 §3-D1）。**【本文复核】A 的 CRX 结论逐条复现**：本次下载 `mdnleldcmiljblolnjhpnblkcekpdkpa` v**26.9.29**（MV3），permissions 确含 `declarativeNetRequest`/`webRequest`/`scripting`/`proxy`/`tabs`/`webNavigation`，`declarative_net_request.rule_resources` = `delay_rules`+`header_rules`，`page-scripts/ajaxRequestInterceptor.ps.js` 内含 `new Response(m?null:new Blob([f])`、`XMLHttpRequest.prototype.open/send/setRequestHeader/abort=`、`fetch=async(...)`、`rqProxyXhr`×37。⇒ **Requestly = DNR（网络层）+ MAIN world 页面脚本（JS 层造 Response）双管齐下**；厂商表说的是"文档/静态资源类响应"它改不了（那是网络层能力，DNR 无 body） |
| 1.11 | **现成扩展：ModHeader** | **拿到 CRX 产物**：v**2026.8.8.18**（MV3），权限**只有** `clipboardRead,clipboardWrite,declarativeNetRequest,storage` + `host_permissions:<all_urls>`；**无 `webRequest`、无 `debugger`、无 content scripts**；`background.js` 组装 `{type:"modifyHeaders", requestHeaders/responseHeaders}` 并调 `updateDynamicRules`/`updateSessionRules` | **三条取证通道全部失败**（CWS 页面 JS 渲染抓不到文本 / `clients2.google.com` CRX 被 TLS 拒 / chrome-stats 403）⇒ 标"完全未验证" | ❌（证据可得性） | **裁定：A 正确，B 属取证通道失败**（详见 §3-D2）。**【本文复核】A 的结论逐条复现**：本次 CRX 下载成功（795 KB），manifest 权限与 A 所列**完全一致**，`background.js` 中 `type:"modifyHeaders"`、`requestHeaders`、`responseHeaders`、`updateDynamicRules`、`updateSessionRules` 各 1 处。⇒ **ModHeader V3 = 纯 DNR `modifyHeaders`**。副作用：B §9-U1 可关闭 |
| 1.12 | **现成扩展：Tamper Dev** | 商店 CRX v**2**（**MV3**），权限只有 `debugger, activeTab, scripting`；产物含 `chrome.debugger`、`Fetch.enable`、`Fetch.continueRequest`、`Fetch.fulfillRequest` | 依据 **GitHub `google/tamperchrome` 源码**：`v2/manifest_base.json` 是 **MV2**（`"manifest_version": 2`），并明确写"其当前在商店的形态未验证" | ❌（表象冲突） | **裁定：两份各说了一个真实产物（仓库 MV2 / 商店 MV3），不冲突**（详见 §3-D3）。**【本文复核】两边都复现**：商店 CRX `cpcmdnpekbomkhllkbmghhbefjbbjgni` v2 是 **MV3**、权限 `debugger,activeTab,scripting`，产物中 `Fetch.fulfillRequest`/`Fetch.enable`/`Fetch.continueRequest`×3/`Fetch.getResponseBody`/`Fetch.requestPaused`×2/`chrome.debugger.attach` 全部存在；GitHub `master/v2/manifest_base.json` 确为 `"manifest_version": 2`。⇒ **Tamper Dev = debugger + CDP Fetch**，B 引的 `request.ts`/`interception.ts` 源码可作实现参考 |
| 1.13 | **现成扩展：Resource Override / Redirector** | MV2 blocking：前者 Chrome 用 `data:` 重定向造 body、Firefox 用 `filterResponseData`；后者纯 `{redirectUrl}` | 同结论（引同一仓库 master 分支） | ✅ | **采纳**。`<https://github.com/kylepaulsen/ResourceOverride>`、`<https://github.com/einaregilsson/Redirector>`。**两者都是 MV2 ⇒ 在 Chrome 上已不可用**，仅作"历史上如何造 body"的参考 |
| 1.14 | **现成扩展：Tampermonkey / Violentmonkey** | 页面世界注入：TM `@sandbox` = `raw`(MAIN，默认) / `JavaScript`(Firefox USERSCRIPT_WORLD) / `DOM`(ISOLATED)；VM MV2 manifest | 同结论，并补 VM `@inject-into` = `page`/`content`/`auto` 与 `auto` 在严格 CSP 下退化到 content 的行为 | ✅ | **采纳**。TM 文档 <https://www.tampermonkey.net/documentation.php?q=sandbox>、<https://www.tampermonkey.net/documentation.php?q=unsafeWindow>；VM 文档 <https://violentmonkey.github.io/api/metadata-block/#inject-into>。**注意 VM 的 `auto` 降级 ≠ R5 的"换装载方式"**：降级到 content 等于放弃 JS 层拦截，必须区分（B 明确指出） |
| 1.15 | Firefox 对照 | MV3 保留 blocking webRequest；`filterResponseData` 可完全控制响应体；match pattern 允许 `(chrome-)extension` scheme | 同结论；Firefox 细节多处标未验证 | ✅ | **采纳**。MDN：<https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest/StreamFilter>、<https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest>、<https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Match_patterns> |
| 1.16 | `webRequest` 事件名（细节） | 写 `onSendRequest` | 写 `onSendHeaders` | ❌（A 笔误） | **裁定：B 正确**。官方事件列表只有 `onSendHeaders`，不存在 `onSendRequest`（webRequest 文档同页，本次抓取核对）。更正见 §3-D10 |
| 1.17 | 缓存黑洞 | 内存缓存命中的请求对 webRequest 不可见 | 同结论（官方原文 "Requests that are answered from the in-memory cache are invisible to the web request API."） | ✅ | **采纳**，须进"拦截盲区清单" |

### 2.2 第二问：`fetch` / `XMLHttpRequest` 劫持

| # | 议题 | A 的结论 | B 的结论 | 是否一致 | 裁定 + 依据 |
|---|---|---|---|---|---|
| 2.1 | 库清单 | ajax-hook / xhook / fetch-intercept / @mswjs/interceptors / sinon-nise（+ mock-socket 作 WebSocket 补充、Tampermonkey `unsafeWindow`） | 同样五个库（+ Tampermonkey / Violentmonkey 的 world 语义）；**明确 WebSocket 劫持不在本次范围** | 🔁 | **合并采纳**：B 的五个库是核心集合；A 多出的 `mock-socket`（<https://github.com/thoov/mock-socket>）与 WS 讨论是**本项目 Q-D3 必需的补充**，应保留进能力清单输入 |
| 2.2 | 改构造器还是改原型方法 | 两派：**改全局构造器**（ajax-hook / xhook / nise）与**改全局函数 / 代理实例**（fetch-intercept / msw / Requestly 页面脚本）；改原型的库一个都没有，ajax-hook 源码注释解释了原因 | 完全同结论："**没有一个去改原型方法**"，同样引 ajax-hook 的源码注释 | ✅ | **采纳**。ajax-hook 注释原文："We shouldn't hookAjax XMLHttpRequest.prototype because we can't guarantee that all attributes are on the prototype."（<https://github.com/wendux/ajax-hook/blob/master/src/xhr-hook.js>） |
| 2.3 | 各库拦截点逐一 | ajax-hook＝全局构造器+实例包装；xhook＝facade 构造器+`window.fetch`；fetch-intercept＝直接赋值 `fetch`；msw＝`new Proxy(globalThis.XMLHttpRequest,{construct})`+真实例+原型描述符复制、fetch 走 `patchesRegistry`；nise＝替换全局，纯 JS `FakeXMLHttpRequest` | 同结论，逐库给出源码路径 | ✅ | **采纳**。msw 的关键实现两份都落到 `xml-http-request-proxy.ts` / `patches-registry.ts`（<https://github.com/mswjs/interceptors>） |
| 2.4 | `Response` 怎么造才不露馅 | 必须用**真 `Response`**（Requestly `new Response(new Blob([f]),{status,statusText,headers})`；msw `new FetchResponse(…)`） | 同结论，**并给出规范级解释**：`url` 恒为 `""`、`redirected` 恒 `false`、`type` 为 `default`（跨源真响应是 `cors`/`opaque`），只能靠实例上遮蔽只读字段缓解 | 🔁 | **合并采纳，B 的规范依据更强**（Fetch 规范 <https://fetch.spec.whatwg.org/>；WebIDL 属性位于 interface prototype object 且可配置 <https://webidl.spec.whatwg.org/>）。**这是本项目的硬约束**：命中拦截返回的 `Response` 与真实网络响应在这三个字段上必然不同，须列入"可检测面"接受 |
| 2.5 | `XMLHttpRequest` 实例能否用纯 JS 对象伪造 | 未直接给规范依据；表述为"自建 facade 的原生原型链、内部槽全部缺失" | **明确给出 WebIDL brand check 依据**：非法 `this` 抛 `TypeError`；结论"必须持有真实 XHR 实例"（ajax-hook / xhook / msw 都持有，nise 放弃） | 🔁（B 更完整） | **采纳 B 的表述**（WebIDL <https://webidl.spec.whatwg.org/>）。**这是不可绕过的硬边界**：`XMLHttpRequest.prototype.open.call({},…)` 类操作必然抛错 ⇒ 实现路线只能是"真实例 + 外壳" |
| 2.6 | 同步 XHR | msw **明确放弃并放行**；ajax-hook 因包装 `send()` 且可不调原生实现，**理论上可同步伪造**（推断）；MDN 判 deprecated | 逐库给结论并附源码：**xhook ✅ / ajax-hook ✅ / msw ❌ / nise ❌**；并引 XHR 规范（同步下 `timeout` 抛 `InvalidAccessError`、错误路径抛异常而非派发事件、规范原文"in the process of being removed from the web platform"） | 🔁（B 更完整） | **采纳 B 的矩阵**（xhook/ajax-hook 的同步分支有源码依据）；**A 的"msw 放弃"与 B 一致**。注：A 文档并未声称 xhook 支持同步（t14 的任务摘要里那句"xhook✅"实际出自 B），不存在冲突。**项目含义见 §5-①(b)** |
| 2.7 | 事件对象 / `isTrusted` | 事件是最常见破绽：ajax-hook 用 `new Event(name)` 且在**游离的 `<a>` 元素**上派发（`getEventTarget(xhr)=document.createElement('a')`）；msw 用 `EventPolyfill` 且写 `isTrusted=true`；结论"`isTrusted` 无法伪造（推断），属**不可完全消除**的破绽" | 只说"事件由控制器手工触发、时序与原生不同"，未展开 `isTrusted` | 🔁（A 更细） | **A 的细节成立，但其中一条推断应升级为确证、另一条需澄清**（详见 §3-D7）：**【本文复核】**DOM 标准里 `isTrusted` 带 `[LegacyUnforgeable]` ⇒ **真事件实例上确实无法伪造**（<https://dom.spec.whatwg.org/#dom-event-istrusted>）；而 msw 的 `EventPolyfill` 之所以能写 `isTrusted=true`，是因为它**不是真 `Event`**（普通 JS 类 + own 字段），且 msw 的 `trigger()` **根本不调用 `dispatchEvent`**，而是**手工回调 `on*` 与自建监听器表**（npm `@mswjs/interceptors@0.45.7`：`src/interceptors/XMLHttpRequest/polyfills/event-polyfill.ts`、`utils/create-event.ts`、`xml-http-request-controller.ts`）⇒ 用 msw 路线时，`event.target`（progress 类事件为 `null`）、`instanceof Event`、以及"**不走 `dispatchEvent`**"这三处都是**额外的暴露面** |
| 2.8 | 抗检测手段清单 | D1–D8：`toString` / 属性描述符 / `prototype.constructor` / 实例 own 属性 / 事件对象与 `isTrusted` / 保存原生引用 / 直接实例化对照 / `Symbol.toStringTag`；并给出 puppeteer-extra-plugin-stealth 的 `makeNativeString` + 代理 `Function.prototype.toString` 作现成反制 | D1–D9：追加 **D4 库里自带的标记属性**（ajax-hook 的 `__origin_xhr`、msw 的 `Symbol.for('fetch-interceptor')`）、**D5 Resource Timing 旁证**、**D9 环境指纹**（自认无依据）；每条给"反制 + 残留风险" | 🔁（并行互补） | **合并采纳为一张 9 条的检测面清单**：A 独有的"`<a>` 元素派发""stealth 反制实现"与 B 独有的"库自带标记名""Resource Timing 旁证"**互不重复，都保留**。其中 D9（`navigator.webdriver` 等）**B 自己标为无依据**，下游不得当结论用 |
| 2.9 | 要求的 world | 一律 **MAIN world**；隔离世界的补丁对页面与其它扩展不可见 | 同结论，并列表给出"哪些做法必须 MAIN、哪些天生 ISOLATED（含 `nise` 只在测试环境）" | ✅ | **采纳**。官方原文："An isolated world is a private execution environment that isn't accessible to the page or other extensions."（<https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts>） |
| 2.10 | 注入时机 | 必须早于页面第一次取用；`document_start` 是最优但仍有竞态 | 同结论；补"全局被冻结/不可配置时 `patchesRegistry` 直接抛错"的源码依据 | 🔁 | **合并采纳**（xhook/fetch-intercept README 的"先加载"警告 + msw `patches-registry.ts`）。**两条都要进盲区清单** |
| 2.11 | 覆盖范围 | fetch / XHR / WebSocket（另打构造器）/ `EventSource` / `sendBeacon`；**打不到**标签元素、Worker/SW、`document_start` 之前的代码、已保存的原生引用、别的扩展的隔离世界 | 同结论（并把 WS 明确留白为 U7） | ✅ | **采纳**。补充：DNR 只对"到达网络栈"的请求生效，**SW 自己生成的响应不在其内**（官方 "Interactions with service workers" 节） |

### 2.3 第三问：能否拦截或修改「其它扩展」的网络请求（**本文重点**）

> 这一问两份的**最终结论完全一致（不能）**，分歧只在"哪一段证据更决定"。下面把两份的证据**并排摆开**。

| # | 议题 | A 的结论 | B 的结论 | 是否一致 | 裁定 + 依据 |
|---|---|---|---|---|---|
| 3.1 | content script 能否注入 `chrome-extension://` 页面 | **不能**。match pattern 合法 scheme 只有 http/https/`*`/file；Chromium `kValidUserScriptSchemes` **不含 `SCHEME_EXTENSION`**。附：Firefox 的 match pattern 把 `(chrome-)extension` 列为合法 scheme，但跨扩展实际行为**未验证** | **不能**。同两条证据（`user_script.cc` + match patterns 文档），另补 `--extensions-on-extension-urls` 开关门槛；并强调"即使注入进去也拦不到别人的 JS 调用（隔离世界）" | ✅ | **采纳**。**【本文复核】源码逐字复现**：`kValidUserScriptSchemes = SCHEME_CHROMEUI \| SCHEME_HTTP \| SCHEME_HTTPS \| SCHEME_FILE \| SCHEME_FTP \| SCHEME_UUID_IN_PACKAGE`（<https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/user_script.cc>）。**这是 scheme 层的结构性限制，不是 CSP 偶发失败** ⇒ 直接决定 R5 的例外条款必然触发（见 §5-②） |
| 3.2 | `webRequest` 能否**看到**其它扩展发起的请求 | **不能（Chrome 117+）**。`ListenerMatchesRequest()` 的进程过滤；**逐 tag 核对：116 无 / 117 有**；注释自陈例外"does not work for content scripts, or extension pages in non-extension processes" | **不能**。同一段源码；表述为"MV2 也一样，与版本无关"；同样引用该注释作为"有条件"分支 | ✅（结论一致，版本表述有差） | **采纳 A 的版本表述**：**【本文复核】独立复现**：`116.0.5845.0` 0 处、`117.0.5938.0` 1 处。B 的"与版本无关"只在 **≥117** 成立（Chrome ≤116 的 MV2 时代该过滤尚不存在），属**表述不够精确**，非结论错误（见 §3-D8） |
| 3.3 | `webRequest` 能否**改写**其它扩展的请求 | 不能：MV3 无 blocking；且 host permission 只能写 match pattern | 不能，并**补上决定性的权限论证**：`kValidHostPermissionSchemes` **不含 `SCHEME_EXTENSION`**，而子资源请求走 `REQUIRE_HOST_PERMISSION_FOR_URL_AND_INITIATOR` ⇒ initiator 检查必然失败 | 🔁（B 更完整） | **采纳 B 的补强**。**【本文复核】源码复现**：`Extension::kValidHostPermissionSchemes = SCHEME_CHROMEUI \| SCHEME_HTTP \| SCHEME_HTTPS \| SCHEME_FILE \| SCHEME_FTP \| SCHEME_WS \| SCHEME_WSS \| SCHEME_UUID_IN_PACKAGE`（<https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/extension.cc>）。**这一条比"进程过滤"更致命**：即使请求可见，也拿不到 initiator 的主机权限 |
| 3.4 | DNR 能否作用于其它扩展的请求 | **不能**：`chrome-extension:` 目标 URL 一律不求值；自 **Chrome 129/130** 起跳过"其它扩展发起的非 main_frame 请求"（128 无 / 130 有，**未二分到 129**）；main_frame 例外仍在 | **不能**：同两段源码（`ShouldEvaluateRequest` / `ShouldEvaluateRulesetForRequest`），未做版本定位；补 `indexed_rule.cc` 只拒 `javascript:` 与 `kValidHostPermissionSchemes` | ✅（结论一致，A 多版本定位） | **采纳，且【本文复核】把版本精确到 Chrome 129**：`ruleset_manager.cc` 中 `initiator_precursor.scheme() == kExtensionScheme` 分支在 `128.0.6613.84`、`128.0.6613.137` **无**，在 `129.0.6668.0`、`129.0.6668.58`、`130.0.6723.1` **有** ⇒ **引入版本 = Chrome 129**。这解决了 A §9.4 的存疑项，B 的"未定位"随之补全 |
| 3.5 | `chrome.debugger` 能否附加别的扩展页面 / Worker / 后台页 | **不能**（除非 `--extensions-on-extension-urls` / `--extensions-on-chrome-urls`；后台页另需 `--silent-debugger-extension-api`）；WebUI 帧直接拒；worker 校验 parent URL；**自己家的扩展 URL 放行** | 同结论，并补：该限制同时覆盖 `tabId` / `targetId` / 非 WebContents 目标（SW）；浏览器级 target 只对 Perfetto；`kAlreadyAttachedError` | 🔁（B 更完整） | **合并采纳**。**【本文复核】Perfetto 限制复现**（`kBrowserTargetId` + `ExtensionIsTrusted` → `kPerfettoUIExtensionId`）。⇒ **不存在"挂浏览器 target 绕过去"的路** |
| 3.6 | 两份的"有条件"分支 | 若第三方扩展是**通过它的 content script 在普通网页里**发请求：渲染进程属于网页 ⇒ 网络层**能看见**（前提是 URL 与 **initiator 的 host 权限**）；并注明"其它扩展 SW 的 `initiator` 取值"**存疑** | 同样给出"有条件"，但**明确把条件收敛为**：取决于 initiator 取值 + 我们的 host permission；并指出 host permission 无法覆盖 `chrome-extension://` ⇒ 若 initiator 是扩展源则必然失败 | 🔁（B 的链条更闭合） | **合并采纳 B 的收敛**：A 给的"前提"在 initiator 为扩展源时**不可满足**（见 3.3 的 scheme 白名单）。**两份一致同意：即便"看得见"，MV3 下不能改写、DNR 不能造 body ⇒ 仍接不住请求** |
| 3.7 | 其它可能的机制（proxy / devtools / messaging / management / native messaging / SW） | `chrome.proxy` 为"有条件且不适用"；`onMessageExternal` 要求对方配合；devtools 只能事后读 HAR；`chrome.management` 不能 | `chrome.proxy` **不能**（只能选代理，不能凭空回答；自标为推断）；补 Native messaging"出界"（R1 免安装否决）与 **Service Worker 只能拦自己 scope** 两条 | 🔁 | **合并采纳**：两表**互补**。`chrome.proxy` 一行两份措辞不同但**不冲突**（A 说的是"即使能导向代理也需要浏览器外进程"，B 说的是"PAC 不能合成响应"）。B 的 SW 一条保留（本项目无法在 `localhost:6800` 注册 SW —— 没有服务器提供脚本） |
| 3.8 | **动机结论：第三方 aria2 前端扩展连 `localhost:6800` 能否被接住** | **不能**。分五种客户端形态逐一判定；唯一实际可行的一条是"把第三方前端当普通网页跑" | **默认不能**。用四情形表（扩展页/SW、扩展的 content script、扩展注入页面 MAIN world、主动集成）逐一判定 | ✅ | **完全一致，直接采纳**。两处细微差别不影响结论：A 从"前端的形态"（网页 vs 扩展）切入，B 从"扩展怎么发请求"切入；两者都指向**同一句话**：只有**页面 realm** 里的 JS API 调用能被接住 |
| 3.9 | 建议 | 必须自带 UI；把 §7 盲区清单化；禁止"扩展页直接调 Mock 层函数" | 放弃拦第三方扩展，回到 R4.2 自打包 UI + 用户自带的**网页版**前端 | ✅ | **采纳（两份同向）**，与 R4.2 / R5 一致；本文的补充意见见 §5-② |

---

## 3 分歧点与裁定

> 原则：**能定夺的给依据，定不了的不含糊**。D1–D6 是**实质分歧**，D7–D10 是**事实性/表述性分歧**。

### D1 ❌→✅ Requestly 到底能不能"造响应体"？

- **双方依据**：A 有 CRX 产物（MAIN world 页面脚本里 `new Response(…)`，能对命中规则的 XHR/fetch 返回自造响应）；B 有**厂商官方对照表**（扩展列 `Serve local file Response ❌` / `Modify HTML/JS/CSS Response ❌` / `Map Local ❌`，桌面应用 ✅）。
- **裁定：不冲突，两份说的是不同资源类别**。
  - 对照表同一张表里，扩展的 **`HTTP Rules` ✅、`Map Remote` ✅、`File Server` ✅**，只有"**serve 本地文件 / 改 HTML-JS-CSS 响应 / Map Local**"为 ❌ —— 这几项恰好是**网络层的响应内容替换**，而在 MV3 里 DNR 没有 body 能力（见 §2.1-1.4），必须靠桌面代理。⇒ **厂商表本身就是"DNR 不能合成响应体"的旁证**（B 引用得对）。
  - A 观察到的 `new Response(…)` 发生在**页面 JS 层**（MAIN world 脚本），服务对象是 **API/REST 响应**（即表里的 `File Server ✅` 那一类），与"改 HTML/JS/CSS 文档响应"不是一回事。**【本文复核】**两条证据都复现（CRX 解包 + 厂商文档抓取）。
- **下游含义**：引用 Requestly 时**不能**说"扩展可以造任意响应体"；准确说法是"**扩展可以在页面 JS 层为 XHR/fetch 合成响应（REST/API 类），但不能在网络层替换文档类响应**"。

### D2 ❌→✅ ModHeader 的 API 用法（A 有、B 无）

- **双方依据**：A 有 CRX 解包（权限、`background.js` 行为）；B 三条取证通道失败。
- **裁定：A 正确；B 的"未验证"是工具性失败，不是反证。**【本文复核】本次 CRX 下载成功并解包（795 002 字节），manifest 权限 `['clipboardRead','clipboardWrite','declarativeNetRequest','storage']` + `host_permissions:['<all_urls>']`、无 content scripts、无 debugger，`background.js` 含 `type:"modifyHeaders"` 与 `updateDynamicRules` / `updateSessionRules` —— **与 A 所述逐字一致**。
- **下游含义**：B §9-U1 可关闭；`ModHeader V3 = 纯 DNR modifyHeaders` 可作结论引用。附带证据价值：它证明"**纯 DNR 就能做请求/响应头修改器**"，与 §2.1-1.4 相互印证。

### D3 ❌→✅ Tamper Dev 是 MV2 还是 MV3？

- **双方依据**：A 说商店 CRX 是 MV3（权限 `debugger/activeTab/scripting`）；B 说 GitHub 源码 `v2/manifest_base.json` 是 MV2，并注明商店形态未验证。
- **裁定：两份都对，指向两个不同产物。**【本文复核】商店 CRX = **MV3**；GitHub `master/v2/manifest_base.json` = **`"manifest_version": 2`**。⇒ 引用时必须写明"**仓库源码（MV2）/ 商店产物（MV3）**"，否则会得出"商店版随 Chrome 139 失效"的错误推论。
- **下游含义**：Tamper Dev 作为"CDP 能造响应体"的**行为实证**仍然有效（商店版是 MV3，说明该路线在 MV3 下活着）；但 B 引用的 `request.ts` 源码出自 MV2 仓库，**版本语义不能外推到 MV3**（行为一致，不代表清单一致）。

### D4 ✅ DNR 过滤"其它扩展请求"的引入版本

- **双方依据**：A 做了 128/130 比对，明说未二分到 129；B 未定位版本。
- **裁定：**【本文复核】引入版本 = **Chrome 129**（128.0.6613.84 / 128.0.6613.137 无；129.0.6668.0 / 129.0.6668.58 / 130.0.6723.1 有）。
- **下游含义**：拦截盲区清单可写死"**Chrome 129 起**"，不必再写"129/130 前后"。**注意这是"更晚近才加上"的限制**：它说明"拦其它扩展"即使在过去也从未真正可行（A 的历史注记：≤116 时有进程过滤缺失，但 initiator host 权限仍不可得）。

### D5 ❓ "其它扩展的 content script 发请求"时的 `initiator` 取值

- **双方依据**：A §9.6 存疑；B §9-U5 未验证。两侧都指出源码注释确认它**不受进程过滤**（"does not work for content scripts, or extension pages in non-extension processes"），但**它是否会通过 initiator 的 host 权限检查**取决于该请求的 `initiator` 是网页源还是扩展源。
- **裁定：定不了 —— 详见 §4-③，进 §6 待裁定项。**（结论不受影响：即便"看得见"，MV3 不能改写、DNR 不能造 body。）
- **额外说明**：B 补充的源码注释"manifest sandbox pages 的 initiator 是 opaque origin，但仍是扩展发起的"说明 Chromium 对**扩展源**的判定是"看 precursor"，倾向收紧；但这是**对 sandbox 页**的说明，不能直接外推到 content script。

### D6 ❓ CDP `Fetch` 能否拦截 / 伪造 **WebSocket 握手**

- **双方依据**：**B 直接断言能**（"范围比 DNR 精确、比 JS 层宽（能拦到页面里任何网络途径，包括 `<img>`、`fetch`、XHR、**WebSocket 握手**等）"，未给出处）；**A 明确标未验证**（A §9.3）。
- **裁定：【A 的审慎成立，B 的断言缺证据】——记为未验证。**【本文复核】查证结果：
  - CDP 协议定义里，`Fetch` 域**没有任何 WebSocket 专属的命令或事件**；`RequestPattern.resourceType` 只是复用了 `Network.ResourceType` 枚举，而该枚举**包含 `"WebSocket"`**（<https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/browser_protocol.json>）——这只能说明"**语法上可以写**"，**不能证明握手会被暂停**。
  - `Network` 域的 `webSocketCreated` / `webSocketWillSendHandshakeRequest` / `webSocketHandshakeResponseReceived` / `webSocketFrame*` 是**观测类事件**，与 `Fetch` 的"暂停等待客户端回答"机制无关。
  - Chromium `content/browser/devtools/protocol/fetch_handler.cc` 与 `content/browser/devtools/devtools_url_loader_interceptor.cc`（main）中**没有任何 WebSocket 处理分支**；`Fetch` 的拦截实现挂在 URLLoader 路径上，而 WS 握手走网络服务的 WebSocket 通道。**"没有特判"是弱证据**（不能反证"一定能拦"或"一定不能"）。
  - 旁证（非结论）：Playwright 的请求拦截同样基于 `Fetch` 域，但它为 WebSocket **另立** `page.routeWebSocket()` API（v1.48 新增，<https://playwright.dev/docs/api/class-websocketroute>），这与"`Fetch` 不覆盖 WS 握手"一致，但 Playwright 未明文写这句。
- **下游含义**：**不得**把"CDP 能拦 WebSocket 握手"写进能力清单；本项目 WebSocket 通道（Q-D3）应继续按"**JS 层替换 `window.WebSocket`**"设计（A 已给出 `mock-socket` 作参考实现）。

### D7 ❌→✅ `isTrusted` 到底能不能伪造

- **双方依据**：A 说不能（标**推断**），但同时引用 msw 源码说 `EventPolyfill` 把 `isTrusted` 写成了 `true` —— **A 内部有张力**；B 未直接讨论 `isTrusted`。
- **裁定（本文复核后）**：
  1. **`isTrusted` 在真事件上确实不可伪造**：DOM 标准中该属性带 **`[LegacyUnforgeable]`** 扩展属性 ⇒ 它是实例上的不可配置/不可写属性，无法用 `Object.defineProperty` 遮蔽（<https://dom.spec.whatwg.org/#dom-event-istrusted>）。**A 的结论正确，且从"推断"升级为"规范确证"。**
  2. **msw 的 `isTrusted=true` 不是"伪造成功"，而是"根本没有伪造真事件"**：【本文复核】npm `@mswjs/interceptors@0.45.7` 的 `EventPolyfill` 是一个**普通 JS 类**（`public isTrusted: boolean = true` 是其自身的类字段），且 `createEvent()` **只对 progress 类事件用真 `ProgressEvent`，其余一律用 `EventPolyfill`**；更关键的是 `XMLHttpRequestController.trigger()` **完全不调用 `dispatchEvent`**，而是手工调用 `on*` 回调与自建监听器表（`src/interceptors/XMLHttpRequest/polyfills/event-polyfill.ts`、`utils/create-event.ts`、`xml-http-request-controller.ts`）。
  3. ⇒ 正确的表述应是：**"真事件无法把 `isTrusted` 造为 true；要绕开它只能不用真事件，而那会立刻暴露在 `instanceof Event` / `target` / 监听器语义上。"** A 的 D5 行"`isTrusted` 属不可完全消除的破绽"**保留**，但原因要改写（不是"只读属性改写不了"，而是"改写不了的属性 + 改写就会失去真事件身份"）。
  4. 附带（本文新发现，两份都没有）：沿用 msw 路线时，mock 响应的事件是**直接调用回调/监听器**派发的（`callback.call(target, event)` / `listener.call(target, event)`，见 `trigger()`），**不走 `dispatchEvent`**；其中 progress 类事件（`load`/`loadend`/`progress`/`error`/`timeout`/`abort`/`loadstart`）用的是**真 `ProgressEvent` 但从未被 dispatch** ⇒ `event.target` 为 `null`、`eventPhase` 为 `0`、`composedPath()` 为 `[]`。这类差异比 `isTrusted` 更容易被依赖 `evt.target` 的页面/框架察觉。另注：其 `addEventListener` 会**同时**登记到自建表并调用原生实现（`registerEvent(...)` + `invoke()`），因此监听器**不会漏**（本文修正了一个容易误传的说法）。

### D8 🔁 `webRequest` 其它扩展过滤是"与版本无关"还是"Chrome 117 起"

- **裁定：A 精确，B 的"与版本无关"只在 ≥117 成立**。**【本文复核】逐 tag 复现**：116 无 / 117 有。
- **下游含义**：盲区清单写"**Chrome 117 起**"。此差异不影响任何产品结论（今天没有 Chrome ≤116 的用户）。

### D9 🔁 `chrome.proxy` 的判断措辞

- **裁定：两者不冲突**。A 说"有条件且不适用：即使把流量导向真实代理，扩展**不能监听端口**（R8），仍要依赖浏览器外进程"；B 说"不能（合成响应）：PAC 只负责选代理"。**合并写法**：`chrome.proxy` + PAC **不能回答请求**；唯一用法是导向一个**浏览器之外**的真实代理，这与 R1（免安装）、R8（不能监听端口）同时冲突 ⇒ **排除**。B 自标为推断（U9）的部分以 API 语义补足，无需再取证。

### D10 ❌ A 的事件名笔误

- **裁定：官方事件为 `onSendHeaders`，A 文中的 `onSendRequest` 不存在**（webRequest 文档同页，本次抓取核对）。**低严重度，但下游若照抄会写错事件名**（如"我们监听 `onSendRequest`"），应更正。

---

## 4 两份均缺证据的点

> 以下条目**两份都没有给出决定性证据**（或只有间接/推断依据）。**不得**在下游文档中被当作结论使用。

① **DNR `redirect` 到 `data:` 是否真被网络栈接受并生效**（A §9.1 / B U3）。
　- 现状：两份一致标"未验证"；**本次把范围缩小了一步**【本文复核】——`indexed_rule.cc` 的 `ParseRedirect()` **只对 `javascript:` 报错**（`ERROR_JAVASCRIPT_REDIRECT`），DNR 文档也只写"Redirects to JavaScript urls are not allowed."；`ruleset_manager.cc` 里与 scheme 相关的重定向检查只有 `IsRedirectToFileUrl()`（需文件访问权限）。
　- 仍缺：**网络栈/URLLoader 层的实际行为**（无浏览器环境，未实测）。
　- 为什么重要：如果 `data:` 可用，DNR 就有一条"静态 body"的勉强路径；但**即便是 ✅ 也救不了 RPC 场景**（声明式规则无法按请求体动态生成响应），故该点不影响任何裁定。

② **`chrome.scripting.executeScript` 能否注入"我们自己的"扩展页面**（A §9.2 / B U15）。
　- 两份都只证明"**content script 的 match pattern / user script scheme 层不支持 `chrome-extension://`**"；对自己家的页面能否用 `scripting` 注入，**都没找到官方明文或源码判定**。
　- 与 R5 的关系：决定 R5 例外是"必须"还是"可选"（A 的判断；B 倾向"直接页内引脚本即可，无需注入"）。**B 的建议不需要这个答案就能落地**。

③ **其它扩展的 content script 发出的请求，其 `initiator` 取值是什么**（A §9.6 / B U5，即本文 §3-D5）。
　- 两份都指出它决定 §2.3-3.6 的"有条件"分支是否放行，且**都没有取证**。

④ **Firefox 侧"拦其它扩展"的实际行为**（A §9.5 / B U10）。
　- Firefox 的 match pattern 文档把 `(chrome-)extension` 列为合法 scheme（A），Firefox 保留 blocking `webRequest` 与 `filterResponseData`（A/B 一致），但**跨扩展可见性与注入行为均未验证**。

⑤ **DNR `initiatorDomains` 是否把扩展 ID 当 domain 匹配**（A §4.3 推断 / B U4）。
　- 两份都指出：由于 ruleset 层对其它扩展请求整体跳过，**该问题在当前约束下没有实际意义**；且官方只承诺 "domain" 语义。

⑥ **CDP `Fetch` 与 WebSocket 握手**（A 标未验证 / B 断言能但无出处，即本文 §3-D6）。

⑦ **各 hook 库的"事件时序 / 反检测"差异清单均无实测**（B U11 明确承认"无浏览器环境"；A 的相关条目多为推断）。
　- 受影响的具体条目：事件任务划分、`performance.now()` 差分、`event.target` 与"不走 `dispatchEvent`"的语义（本文新发现，见 §3-D7-4）、`Resource Timing` 旁证（B D5）、环境指纹（B D9）。

⑧ **`Response` 只读字段在**实例**上 `defineProperty` 遮蔽的跨浏览器一致性**（B U13）。规范允许（原型访问器且 `configurable`），Chrome/Firefox/Safari 的实际可写性**未逐一验证**。

⑨ **性能数字**：CDP 每请求开销、MAIN world 补丁开销（A §9.8 明确无来源）。

⑩ **MV3 观测型 `webRequest` 对 Worker 内请求 / `chrome://` / PDF viewer 的可见性**（B U17；A 亦未逐条验证）。

⑪ **`@mswjs/interceptors` 官方对浏览器场景的支持程度**（A §9.11）：README 首句自称 Node.js 库，但确有 `lib/browser/*` 与 `/web` 入口（本次 `npm pack` 亦见浏览器侧源码）——**"能不能用"证据充分，"官方是否承诺支持"未定**。

⑫ **Tampermonkey 注入包装的源码级细节**（A §9.12 / B U8）：闭源，只能依据官方文档。

---

## 5 对 R9 与 R5 的影响（明确意见）

### 5.1 R9「拦截发生在 JS API 层」——**不动摇，但需要一句限定语和一处边界清单**

**意见：R9 的裁定本身不需要改；需要改的是它的"理由句"和"作用域"的理解。**

1. **主干被两份独立研究双重确认**：DNR 的六个 action 无一能携带响应体（§2.1-1.4，官方文档 + 厂商对照表 + Chromium 源码），MV3 观测型 webRequest 只读，MV2 已死 ⇒ **在"常规扩展 API 层面"，JS API 层确实是唯一能"任意合成响应体 + 零用户可见成本"的路径**。R9 的"命中后请求根本不发到网络"与 DNR 网络层路线**不是同一条路**这一判断**成立**。
2. **必须加的限定语（B 提出，本文同意）**：R9 原文"与'用 DNR 重定向'不是同一条路：DNR 走网络层，**拿不到'返回任意响应体'的能力**"。
   - 逐字读：主语是 DNR ⇒ **完全正确**，无需修订。
   - 若被读成"**只有 JS API 层**能拿到任意响应体"⇒ **不成立**：`chrome.debugger` + CDP `Fetch.fulfillRequest` 可以在**调试协议层**凭空回答任意请求（§2.1-1.6，A/B 一致 + 协议定义 + Tamper Dev 实证）。
   - **建议措辞**：「JS API 层是唯一**零用户可见成本**的可合成任意响应体路径；网络层（DNR）没有该能力；调试协议层（`chrome.debugger` + `Fetch.fulfillRequest`）有，但有不可接受的产品代价；MV2 阻塞式 webRequest 历史上可用 `data:` 重定向近似（平台已死）。」
3. **R9 的作用域边界必须进"拦截盲区清单"（Q-D2）**，且要区分三类：
   - **技术上能拦、实现上要特殊处理**：同步 XHR（xhook/ajax-hook 有同步分支，msw 直接放行；XHR 规范已在移除同步 XHR）。
   - **技术上拦不到（realm 隔离）**：Worker / Service Worker、**其它扩展**的全部形态。
   - **设计上不承诺**：非 JS API 途径（导航、`<img>`、`sendBeacon`、`<video>` 分片…）、`document_start` 之前、内存缓存命中的请求、`chrome://` / PDF viewer / view-source。
   - 概念文档 §6.4 已列这些风险，但**未区分"能拦但没拦到"与"设计上不拦"**（A 的建议，本文同意）。
4. **不需要**把 R9 升级成"唯一路径"或改写为"网络层完全不可用"：DNR 在**引擎层**仍有正当用途（附录 A 的改头 + 强制下载），那与 R9 的"拦截层次"是两个层面，不冲突（A、B 同判）。

### 5.2 R5「内置 UI 不得走特殊通道」——**不动摇，而且被两份证据"加强"：例外条款从"可能触发"变成"必然触发"**

**意见：R5 的文字不必改；但它的例外条款必须在详细设计里被当成"默认路径之一"来设计，并且要新增一条一致性验收。**

1. **为什么例外必然触发（这是本文相对 A/B 的推论）**：content script 的合法 scheme **不含 `chrome-extension`**（§2.3-3.1，源码级）⇒ 只要内置 AriaNg UI 以 `chrome-extension://<我们 ID>/…` 打开，**"走 content script 注入"这条路根本不存在**（不是被 CSP 挡，而是 scheme 层就不在候选集里）。⇒ R5 的"扩展页注入失败时，只换装载方式"**不是一个兜底分支，而是内置 UI 的主装载方式**。
2. **合法做法与禁止做法（两份一致，本文确认）**：
   - ✅ **合法**：扩展页里用 `<script src="…">`（或打包进 UI 的 bundle）**加载同一份转发器代码**，由它去 patch 该页面的 `fetch` / `XMLHttpRequest`，UI 依旧通过 JS API 发 RPC ⇒ **换的是"装载方式"，不是"路径"**。
   - ⛔ **禁止**：UI 直接调用 Mock 层的内部函数 / 直接读写扩展的 state ⇒ **这就是 R5 明令禁止的"特殊通道"**。A 特别提醒这条捷径"很有诱惑力，必须在详细设计里明确禁止"，本文同意并建议把它写成**验收项**。
3. **必须新增的一致性验收（B 提出，本文同意并强化）**：两种装载方式（普通网页 = content script 注入 MAIN world；扩展页 = 页内直接引脚本）下，下列行为必须**逐条一致**，否则就构成事实上的特殊通道：
   - 命中 / 未命中两条路径的分支判定；
   - `fetch` 与 XHR（含同步 XHR）的响应构造与错误形态；
   - **扩展页的 `fetch` 具备 host permission 内的跨源特权**，普通网页没有 ⇒ 任何依赖"页面 fetch 会被 CORS 拦"的假设都会在两种装载方式下表现不同（B 的风险点 1）；
   - **扩展上下文与页面的 CSP 不同**（扩展页受 `script-src 'self' …` 约束，普通页面 MAIN world 注入受**页面** CSP 约束）⇒ 转发器若依赖 `eval` / `new Function` / 外部脚本加载，两种方式受限方式不同（B 的风险点 2）。
   - **注**：以上两条**无法在本次调研中实测**（无浏览器环境），属"必须在详细设计阶段验证"的风险，不是结论。
4. **结论**：R5 与两份研究**不冲突**；并且两份研究给出了同一句话的技术依据：**"扩展自有页面同源 ⇒ 页内直接引脚本 = 换装载方式"是唯一同时满足"能工作"与"不特殊"的做法**。A 与 B 的差别只在落点（A 强调"注入不可能"是更根本的表述升级；B 强调"两种装载方式的一致性"是实质风险）——**两者都要写进详细设计**。

---

## 6 待项目负责人裁定

> 下列各条**不影响已裁定项成立**，属于"要不要把新事实写进概念文档 / 要不要开新议题"。

1. **R9 的理由句是否按 §5.1-2 的措辞修订**（限定为"常规扩展 API 层面"）。理由：CDP 通道能凭空回答请求，属事实层面的补充；不修订也不至于出错，但会被旧资料质疑。
2. **是否新增"CDP 高保真可选模式"议题**（B §6.1 提出：`chrome.debugger` + `Fetch.fulfillRequest` 可作为**非默认**的高保真/诊断通道；A 也认为"作为可选的调试/诊断通道尚有价值"）。**两份都主张不做默认路径**（用户可见信息条 + DevTools 互斥 + 单调试器 + 企业策略），**但"要不要做"是产品决定**。
3. **§6.4 拦截盲区表述升级**：建议把"扩展页 CSP"改为"**扩展页不在 content script 的可注入范围内（scheme 层不支持），另有 CSP 约束**"（A 的主张；B 亦建议把"扩展页 CSP"改为更精确的"MAIN world 注入受页面 CSP 约束"）。二者可合并为一句。
4. **§6.4 是否补入"其它扩展一律拦不到"**：这不是"技术难题"而是**浏览器安全模型的硬边界**（§2.3 全部证据）⇒ 建议作为**产品范围的显式声明**（与 R2 能力诚实一致），而不是埋在"盲区"里。
5. **是否把"内存缓存命中的请求对 webRequest 不可见""Worker/SW realm 拦不到""`document_start` 之前拦不到"三条补进 Q-D2 清单**（A/B 均给证据）。
6. **本文 §4 的 ①②③④ 四项是否安排一次实测/追加调研**（DNR `data:` 重定向、`scripting.executeScript` 注入自家扩展页、content script 请求的 `initiator`、Firefox 跨扩展行为）。**这四项都不影响现有裁定**，只影响措辞精度。

---

## 7 对项目最关键的 3 个发现

### 发现 1：R9 不是"择优"，而是"唯一可落地"——因为网络层**从设计上就没有"回答请求"的能力**

DNR 的六个 action 穷举后**没有任何响应体字段**（官方文档），MV3 观测型 webRequest 只读，MV2 阻塞式 webRequest 在 Chrome 已死（138/139/2026-08-31 三个里程碑）⇒ 在**零用户可见成本**的前提下，能"凭空构造响应体"的路只剩 MAIN world 的 JS API 层。唯一的例外是调试协议层的 `Fetch.fulfillRequest`，而它的代价（信息条、与 DevTools 互斥、单调试器、Chrome 155 起企业策略全有或全无）使它只能是可选项。
**行动含义**：把转发器全部押在 MAIN world JS 层是**正确且必要**的；同时"下载引擎"侧的网络层能力（DNR 改头 / 强制下载，见附录 A 样例）与"转发器"侧是**两套机制**，不能混为一谈。
**依据**：§2.1-1.1 / 1.4 / 1.6 / 1.7。

### 发现 2：产品范围存在一条**硬边界**——第三方 aria2「扩展」形态的前端，永远接不住

四道独立闸门（content script 的 scheme 白名单、webRequest 的进程过滤、DNR 的 ruleset 求值跳过、debugger 的 URL/开关限制）加上 host permission 同样不含 `chrome-extension` ⇒ **不是"实现得不够好"，而是浏览器安全模型的边界**。唯一能被服务的是**跑在页面 realm 里的前端**（普通网页，或我们自己的扩展页）。
**行动含义**：① R4.2「自带 AriaNg UI」不是可选项而是**必需项**；② 对外宣传与"能力诚实"（R2）必须写明"**只服务浏览器内的 JS 客户端，且不服务其它扩展**"；③ 对第三方前端的可行支持方式是"请把前端当普通网页打开/由我们的转发器注入该页面"（另一种前端形态），而不是"去拦它"。
**依据**：§2.3 全部条目（其中 3.1/3.3 为本文源码复核）。

### 发现 3：伪造保真度有**不可绕过的下限**，这直接决定实现路线

三条硬约束：① `Response` 必须用真构造器造，而 `url=""`/`type="default"`/`redirected=false` 三个只读字段**必然与真实响应不同**；② `XMLHttpRequest` 纯 JS 伪对象**过不了 WebIDL brand check**，必须持有真实例（⇒ 排除 xhook 式纯 facade，倾向 msw 的 `Proxy(construct)` + 真实例 + 原型描述符复制）；③ 事件侧：`isTrusted` 是 `[LegacyUnforgeable]`，真事件无法伪造成 `true`；而要绕开它就得不用真事件（msw 就是这么做的，代价是 `instanceof Event` 为假、progress 类事件的 `event.target` 为 `null`、且**完全不经过 `dispatchEvent`**）。
**行动含义**：详细设计必须在"**保真度 vs 实现成本**"上做一次显式取舍并记录：建议采用"真 `Response` + Proxy 构造器 + 真 XHR 实例"为基线；对 `toString` / 属性描述符 / 事件对象 / 同步 XHR 逐条给出**接受或对抗**的决定（注意：对抗页面检测**不是**本项目的需求，概念文档 §6 已接受相关风险）。
**依据**：§2.2-2.4 / 2.5 / 2.7，以及 §3-D7。

---

## 8 证据清单

### 8.1 本文复核新增（可直接引用）

| # | URL | 复核内容 | 等级 |
|---|---|---|---|
| R1 | <https://chromium.googlesource.com/chromium/src/+/refs/tags/128.0.6613.84/extensions/browser/api/declarative_net_request/ruleset_manager.cc>（及 `128.0.6613.137` / `129.0.6668.0` / `129.0.6668.58` / `130.0.6723.1` 同路径逐 tag 抓取） | DNR"跳过其它扩展非 main_frame 请求"的引入版本 = **Chrome 129**（128 两版无、129 两版有、130 有） | B |
| R2 | <https://chromium.googlesource.com/chromium/src/+/refs/tags/116.0.5845.0/extensions/browser/api/web_request/extension_web_request_event_router.cc>（及 `117.0.5938.0` / `118.0.5993.0`） | webRequest"其它扩展过滤"引入版本 = **Chrome 117**（116 无 / 117 有）——独立复现 A 的结论 | B |
| R3 | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/extension.cc> | `kValidHostPermissionSchemes` **不含 `SCHEME_EXTENSION`**（逐字复现 B） | B |
| R4 | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/user_script.cc> | `kValidUserScriptSchemes` **不含 `SCHEME_EXTENSION`**（逐字复现 A/B） | B |
| R5 | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/browser/api/declarative_net_request/ruleset_manager.cc> | `ShouldEvaluateRequest()` 对 `chrome-extension:` 目标直接 `return false`；`ShouldEvaluateRulesetForRequest()` 的 initiator precursor 过滤（含 sandbox 页注释）；重定向侧只有 `IsRedirectToFileUrl` 检查 | B |
| R6 | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/browser/api/declarative_net_request/indexed_rule.cc> | `ParseRedirect()` 只对 `javascript:` 返回 `ERROR_JAVASCRIPT_REDIRECT`（`data:` 未被拒绝） | B |
| R7 | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/extensions/api/debugger/debugger_api.cc> | `kBrowserTargetId="browser"` 仅对 `ExtensionIsTrusted()`（= Perfetto UI 扩展）开放；Chrome 155 严格策略分支 `kExtensionDebuggerStrictPolicyRestrictions` + `policy_blocked_hosts` | B |
| R8 | <https://developer.chrome.com/blog/debugger-enterprise-policy-restrictions>（2026-09-08 发布） | Chrome 155 Stable rollout = **2026-10-06**；`runtime_blocked_hosts` / `DisableScreenshots` / DLP ⇒ `attach()` 全有或全无失败；`--disable-features=ExtensionDebuggerStrictPolicyRestrictions` 于 **Chrome 160 移除** | A |
| R9 | <https://dom.spec.whatwg.org/#dom-event-istrusted> | `isTrusted` 带 **`[LegacyUnforgeable]`** ⇒ 真事件实例上不可伪造 | A |
| R10 | CRX 解包：<https://chromewebstore.google.com/detail/modheader-v3-%E2%80%94-by-modhead/cndlnhnjdlmipaflgajjikndbfkfnohp>（v2026.8.8.18） | 权限**仅** `clipboardRead,clipboardWrite,declarativeNetRequest,storage` + `host_permissions:<all_urls>`；无 content scripts / 无 debugger；`background.js` 含 `type:"modifyHeaders"` + `requestHeaders`/`responseHeaders` + `updateDynamicRules`/`updateSessionRules` | C |
| R11 | CRX 解包：<https://chromewebstore.google.com/detail/requestly-intercept-modif/mdnleldcmiljblolnjhpnblkcekpdkpa>（v26.9.29） | permissions 含 `declarativeNetRequest, webRequest, scripting, proxy, tabs, webNavigation`；静态 ruleset `delay_rules`+`header_rules`；`page-scripts/ajaxRequestInterceptor.ps.js` 含 `new Response(m?null:new Blob([f])`、`XMLHttpRequest.prototype.open/send/setRequestHeader/abort=`、`fetch=async(...)`、`XMLHttpRequest.prototype=r`（构造器被替换）；`serviceWorker.js` 中 `world:"MAIN"` 出现 7 次 | C |
| R12 | CRX 解包：<https://chromewebstore.google.com/detail/tamper-dev/cpcmdnpekbomkhllkbmghhbefjbbjgni>（v2）**（商店版 = MV3）** 与 <https://raw.githubusercontent.com/google/tamperchrome/master/v2/manifest_base.json>**（仓库版 = MV2）** | 商店 CRX：`manifest_version:3`、权限 `debugger,activeTab,scripting`、产物含 `Fetch.fulfillRequest`/`Fetch.enable`/`Fetch.continueRequest`/`Fetch.getResponseBody`/`chrome.debugger.attach`；仓库 `v2/manifest_base.json`：`"manifest_version": 2` ⇒ **D3 的裁定依据** | C |
| R13 | <https://docs.requestly.com/account/how-is-browser-extension-different-from-a-desktop-app> | 扩展列：`HTTP Rules ✅`、`Map Remote ✅`、`File Server ✅`；`Serve local file Response ❌`、`Modify HTML/JS/CSS Response ❌`、`Map Local ❌` ⇒ **D1 的裁定依据** | D |
| R14 | npm `@mswjs/interceptors@0.45.7`：`src/interceptors/XMLHttpRequest/polyfills/event-polyfill.ts`、`utils/create-event.ts`、`xml-http-request-controller.ts`、`utils/patches-registry.ts`（<https://www.npmjs.com/package/@mswjs/interceptors>） | `EventPolyfill` 是普通 JS 类且自带 `isTrusted = true`；progress 类事件用真 `ProgressEvent`，其余用 `EventPolyfill`；`trigger()` **不调 `dispatchEvent`**，手工回调 `on*` + 自建监听器表；`patches-registry` 的 `defineProperty` **未设 `writable`**；同步 XHR warn 后放行 ⇒ **D7 的裁定依据** | C |
| R15 | <https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/browser_protocol.json> | `Fetch` 域无 WS 专属命令/事件；`RequestPattern.resourceType` 引用 `Network.ResourceType`（枚举含 `WebSocket`）；WS 相关事件全在 `Network` 域 ⇒ **D6 的裁定依据（部分）** | A |
| R16 | <https://developer.chrome.com/docs/extensions/reference/api/webRequest> | 事件列表**只有 `onSendHeaders`**，无 `onSendRequest` ⇒ D10 | A |
| R17 | <https://playwright.dev/docs/api/class-websocketroute> | 基于 CDP Fetch 的请求拦截之外，Playwright 为 WebSocket **另立** `routeWebSocket()`（v1.48+）⇒ D6 的旁证（非结论） | D |

### 8.2 官方文档 / 规范（两份共同引用，本文抽样复核）

| # | URL | 支撑 |
|---|---|---|
| E1 | <https://developer.chrome.com/docs/extensions/reference/api/webRequest> | MV3 无 `webRequestBlocking`（策略安装例外）；`redirectUrl` 允许 `data:`；Chrome 72 起 URL+initiator 双 host 权限；`chrome-extension://other_extension_id` 被隐藏；同步 XHR 不通知 blocking 监听器；WS 只拦握手、不拦帧、不支持 WS 重定向；敏感头需 `extraHeaders`；内存缓存不可见；多扩展冲突解决 |
| E2 | <https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline> | MV2 时间线（Chrome 139 起失效；2026-08-31 CWS 清空） |
| E3 | <https://developer.chrome.com/docs/extensions/develop/migrate/blocking-web-requests> | MV3 用 DNR 替代 blocking webRequest 的官方指引 |
| E4 | <https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest> | `RuleActionType` 六值穷举、`RuleAction` 无 body 字段；`Redirect`/`URLTransform` 细节；`initiatorDomains` 语义；responseHeaders 条件（此时请求已发出）；SW 交互边界；规则上限；`web_accessible_resources` 要求 |
| E5 | <https://developer.chrome.com/docs/extensions/reference/api/debugger> | `debugger` 权限与受限 CDP 域（含 Fetch）；`Debuggee.extensionId` 后台页需 `--silent-debugger-extension-api`；`onDetach`（DevTools 抢占）；企业策略小节 |
| E6 | <https://chromedevtools.github.io/devtools-protocol/tot/Fetch/> | `Fetch.enable` 暂停语义；`RequestStage`；`fulfillRequest.body`；`continueRequest` 改 URL/method/headers/postData |
| E7 | <https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns> | match pattern 合法 scheme 仅 http/https/`*`/file |
| E8 | <https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts> | 隔离世界定义与互不可见；`world` 默认 ISOLATED；MAIN world 受页面 CSP |
| E9 | <https://developer.chrome.com/docs/extensions/reference/manifest/content-scripts> | `"world": ISOLATED \| MAIN`；MAIN world 的官方 WARNING |
| E10 | <https://developer.chrome.com/docs/extensions/reference/api/scripting> | `ExecutionWorld` = ISOLATED / MAIN；`registerContentScripts` / `executeScript` |
| E11 | <https://developer.chrome.com/docs/extensions/reference/api/userScripts> | `MAIN` / `USER_SCRIPT` world 语义；main world 对页面与其它扩展可见 |
| E12 | <https://developer.chrome.com/docs/extensions/reference/api/extensionTypes> | `document_start` 语义（"before any other script is run"） |
| E13 | <https://webidl.spec.whatwg.org/> | attribute 位于 interface prototype object 且可配置；brand check（`validThis` 失败抛 `TypeError`）⇒ 纯 JS 伪 XHR 不可行 |
| E14 | <https://fetch.spec.whatwg.org/> | `Response.url` / `redirected` / `type` 的 getter 步骤 ⇒ 合成响应的三个暴露点 |
| E15 | <https://xhr.spec.whatwg.org/> | §3.7 事件清单；同步 XHR 的 `InvalidAccessError`；同步错误路径抛异常；"in the process of being removed" |
| E16 | <https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Function/toString> | 原生函数显示 `[native code]` ⇒ `toString` 检测原理 |
| E17 | <https://developer.mozilla.org/en-US/docs/Web/API/XMLHttpRequest/Synchronous_and_Asynchronous_Requests> | 同步 XHR deprecated 与限制 |
| E18 | <https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest/StreamFilter> | Firefox `filterResponseData` "full control over the response body" |
| E19 | <https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Match_patterns> | Firefox match pattern 允许 `(chrome-)extension` scheme |
| E20 | <https://blog.mozilla.org/addons/2022/05/18/manifest-v3-in-firefox-recap-next-steps/> | Mozilla 在 MV3 继续支持 blocking webRequest |
| E21 | <https://www.tampermonkey.net/documentation.php?q=sandbox>、<https://www.tampermonkey.net/documentation.php?q=unsafeWindow>、<https://violentmonkey.github.io/api/metadata-block/#inject-into> | userscript 管理器：页面上下文 / 隔离上下文 / CSP 降级 与 `unsafeWindow` 语义 |
| E22 | <https://github.com/mdn/browser-compat-data/blob/main/webextensions/manifest/permissions.json> | `webRequestBlocking`：Safari 不支持；`webRequestFilterResponse` 仅 Firefox |

### 8.3 Chromium 源码（`main` 分支；版本比对见 §8.1）

| # | URL | 支撑 |
|---|---|---|
| S1 | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/browser/api/web_request/extension_web_request_event_router.cc> | `ListenerMatchesRequest()` 的"其它扩展 / apps"过滤（含"对 content script 无效"的注释）；`IsRequestFromExtension()` |
| S2 | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/browser/api/web_request/web_request_permissions.cc> | `CanExtensionAccessURLInternal` 的 `REQUIRE_HOST_PERMISSION_FOR_URL_AND_INITIATOR`；`IsSameOriginWith(extension.url()) → kAllowed`；`HideRequest()` |
| S3 | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/browser/api/declarative_net_request/ruleset_manager.cc> | `ShouldEvaluateRequest()`（extension scheme 不处理）与 `ShouldEvaluateRulesetForRequest()`（其它扩展的 initiator 过滤） |
| S4 | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/browser/api/declarative_net_request/indexed_rule.cc> | `ParseRedirect()` 仅拒 `javascript:` |
| S5 | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/user_script.cc> | `kValidUserScriptSchemes` 无 `SCHEME_EXTENSION` |
| S6 | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/extension.cc> | `kValidHostPermissionSchemes` 无 `SCHEME_EXTENSION` |
| S7 | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/switches.cc> | `AreExtensionsOnExtensionURLsAllowed()`（`--extensions-on-extension-urls` / `--extensions-on-chrome-urls`） |
| S8 | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/extensions/api/debugger/debugger_api.cc> | `ExtensionMayAttachToURL()` 拒别的扩展 URL；WebUI 帧拒绝；worker parent 校验；`kBrowserTargetId` + Perfetto；附件警告横幅；`kAlreadyAttachedError`；Chrome 155 严格策略分支 |
| S9 | <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/extensions/api/debugger/extension_dev_tools_infobar_delegate.cc>、<https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/app/generated_resources.grd> | "started debugging this browser" 信息条的实现与文案 |

### 8.4 库 / 扩展源码与产物

| # | URL | 支撑 |
|---|---|---|
| L1 | <https://github.com/wendux/ajax-hook>（`src/xhr-hook.js`、`src/xhr-proxy.js`） | 构造器替换 + 实例包装；`__origin_xhr`；同步分支；不覆盖 fetch |
| L2 | <https://github.com/jpillora/xhook>（`README.md`、`dist/xhook.js`、`src/misc/window.js`） | facade 替换 `XMLHttpRequest` 与 `fetch`；同步 `emitFinal()`；Worker 全局识别；"必须先加载"警告 |
| L3 | <https://github.com/werk85/fetch-intercept> | `env.fetch = …` 直接替换；无任何伪装 |
| L4 | <https://github.com/mswjs/interceptors> | `Proxy(globalThis.XMLHttpRequest,{construct})` + 真实例 + 原型描述符复制；`patchesRegistry`；同步 XHR 放行；`EventPolyfill`（另见 R14 的 npm 复核） |
| L5 | <https://github.com/sinonjs/nise>（+ <http://sinonjs.github.io/nise/>） | `useFakeXMLHttpRequest()` 替换全局；`FakeXMLHttpRequest`；不含 fetch |
| L6 | <https://github.com/thoov/mock-socket> | WebSocket 类 + Server 的模拟实现（WS 劫持参考） |
| L7 | <https://github.com/kylepaulsen/ResourceOverride>（`manifest.json`、`src/background/requestHandling.js`） | MV2 blocking：Chrome `redirectUrl:"data:…"` / Firefox `filterResponseData` |
| L8 | <https://github.com/einaregilsson/Redirector> | MV2 blocking 纯 `{redirectUrl}` |
| L9 | <https://github.com/google/tamperchrome>（`v2/**`） | CDP Fetch 拦截的实现参考（**仓库为 MV2**，商店产物为 MV3） |
| L10 | <https://github.com/violentmonkey/violentmonkey> | MV2 manifest；`injected-web.js` + `injected.js`；`wrappedJSObject` |
| L11 | <https://github.com/berstend/puppeteer-extra/blob/master/packages/puppeteer-extra-plugin-stealth/evasions/_utils/index.js> | 反检测现成实现：`makeNativeString` + 代理 `Function.prototype.toString` |

### 8.5 与本文无关但被两份引用的背景来源（谨慎使用）

- <https://thehackernews.com/2026/07/google-and-microsoft-pull-modheader.html>（第三方报道，仅背景；A 已标注非官方）
- <https://tamper.dev/>（产品自述）
- B §10.5 记录的**取证失败通道**（CWS 详情页 JS 渲染、`clients2.google.com` TLS 拒绝、chrome-stats 403、GitHub REST 403）：**本次其中至少两条已可复现成功**（CRX 下载、GitHub raw），说明那是**当时的环境问题**；后续复核请优先直接解包 CRX 而不是依赖商店页面文本。

---

*（完）*
