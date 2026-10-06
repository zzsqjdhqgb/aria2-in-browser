# F5 — 权限、安全模型、跨浏览器差异与内置 UI 特例

## 0 元信息

| 项 | 值 |
|---|---|
| 文档 | F5《权限、安全模型、跨浏览器差异与内置 UI 特例》 |
| 归属 | 项目 aria2-in-browser｜边界测绘｜转发器研究（任务 t10 / seed f5） |
| 目标读者 | 后续「能力清单」与详细设计；为"多途径拦截""多来源覆盖""内置 AriaNg UI"提供权限与安全输入 |
| 核对日期 | **2026-10-06**（环境时钟 `date -u +%F`），正文简称"本次核对" |
| 核对方法 | 只采信官方一手来源：developer.chrome.com、developer.mozilla.org（含 `mdn/content`、`mdn/browser-compat-data` 原始文件）、learn.microsoft.com（含 `MicrosoftDocs/edge-developer` 原始 Markdown）、extensionworkshop.com、blog.mozilla.org、chromium.org、w3c.github.io、whatwg.org、以及项目官方仓库源码。Chrome 官方页面正文通过 `r.jina.ai` 通道提取（devsite 页面导航体量过大，直接抓取被截断），引用 URL 一律为官方原址 |
| 显式约定 | 每条结论给「结论 + 来源 + 逐字摘录」。**查不到的一律写入 §7，不猜**；凡属我方的推理而非文档断言，正文标注「**推论**」 |

### 0.1 核对时的版本锚点（取自被核对文档自身，不代表我方对"当前最新版"的声明）

| 锚点 | 出处 | 原文线索 |
|---|---|---|
| Chrome **152** | [MDN Chrome incompatibilities](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Chrome_incompatibilities) | "Chrome support for the `browser` namespace and promises was introduced in Chrome 152"（仅限使用 `devtools_page` 的扩展） |
| Chrome **150** | [Chrome offscreen API](https://developer.chrome.com/docs/extensions/reference/api/offscreen) | `offscreen.hasDocument()` 标注 `Chrome 150+` |
| Chrome **148** | MDN Chrome incompatibilities | "Before Chrome 148, Chrome exposed APIs only under the `chrome` namespace rather than `browser`" |
| Chrome **145** | [Chrome DNR 参考](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest) | `topDomains` / `excludedTopDomains` 标注 `Chrome 145+` |
| Firefox **142** | [MDN permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/permissions) | 地址栏建议点击计为 user action "from Firefox 142" |
| Firefox **128** | MDN DNR / optional_permissions | 动态/会话规则上限拆分、`optional_host_permissions` 均自 Firefox 128 |
| Edge | [Edge MV3 timeline](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/manifest-v3)（Last updated 09/15/2026） | MV2 弃用告警 2026-08/09 起；企业侧 MV2 弃用"Early 2027" |
| 规范 | [Mixed Content（Editor's Draft, 23 Feb 2023）](https://w3c.github.io/webappsec-mixed-content/) | 混合内容的算法定义 |

> 阅读方式：本文的"当前"= **文档当前快照**，不等于某个浏览器发行版号。凡版本敏感处，均附文档标注的引入版本。

---

## 1 一句话结论

**权限模型本身不阻塞我们的方案，真正必须在早期锁定的是「浏览器支持矩阵」。**

1. **注入侧**：Chrome 的"manifest 声明式 content script"**不需要 host 权限**（官方把"允许注入 manifest 声明的 content script"明确列为无需 host 权限的例外）；Firefox 相反，**没有 host 权限就不执行**已注册的 content script。⇒ 同一个转发器，在两个浏览器上的注入前置条件不同。
2. **授权侧**：`permissions.request()` 必须由**用户手势**触发，且只能请求 `optional_permissions` / `optional_host_permissions` 里声明过的项；Chrome 里 `declarativeNetRequest` **不能**声明为可选权限。⇒ "运行时临时要权限"这条路有明确的形状限制，而且我们**不能**把 DNR 降级成可选。
3. **撤销侧**：官方文档描述的是"**访问权限决定注入是否发生**"（按页、按次），以及"扩展页/SW 的跨源请求会像没声明 host 权限一样失败"；**已注入脚本在权限被撤销后是否继续运行，官方无明确文字 ⇒ §7 未验证**。
4. **CSP**：isolated-world content script 有自己的一套 CSP，**页面 CSP 不管它**；一旦代码进 MAIN world，**页面 CSP 就管它**。扩展页（内置 AriaNg 所在）被钉死在 MV3 最小 CSP：`script-src 'self' 'wasm-unsafe-eval'; object-src 'self';`，**不许 eval、不许内联脚本、不许远程脚本，且不可放宽**。
5. **混合内容**：拦截"命中即短路、不发网络请求"在规范结构上确实**绕开了混合内容检查**（检查发生在 Fetch 算法的 Main fetch 里，被替换掉的函数根本不会进入该算法）；并且我们最可能的默认目标 `http://127.0.0.1:6800` 属于 Chromium 的 secure origin 列表，**即使真发请求也不构成混合内容**。
6. **R5 特例（内置 AriaNg）**：扩展页**根本无法被 content script 注入**（Chrome 的 match pattern 连 `chrome-extension` scheme 都不支持；MDN 明文"扩展不能注入扩展页"）。所以 R5 的"换装载方式"不是设计偏好，**是被平台强制的唯一出路**；官方推荐的替代方式恰好是"在页面里直接引入脚本"。
7. **跨浏览器**：Chrome/Edge（Chromium）MV3 **没有** blocking webRequest（仅策略安装扩展），Firefox MV3 **保留** blocking webRequest；Firefox **没有** background service worker（用 event page）；Firefox **没有** offscreen；File System Access 的 `showSaveFilePicker` **Chromium 有、Firefox 没有**。⇒ 至少要在早期把"转发器"和"下载引擎"拆成两套按浏览器分叉的实现，不能假设统一代码路径。

---

## 2 机制

### 2.1 host_permissions 的声明方式与用户授权流程

**（1）MV3 的键位分工（Chrome / Firefox 一致）**

Chrome 官方把权限分成五类键：`permissions`、`optional_permissions`、`content_scripts.matches`、`host_permissions`、`optional_host_permissions`。
来源：[Declare permissions](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions)｜摘录："`"host_permissions"` Contains one or more match patterns that give access to one or more hosts. Changes may trigger a warning."、"`"optional_host_permissions"` Granted by the user at runtime, instead of at install time."

MDN 的口径一致，并给出 MV2→MV3 的迁移关系：
来源：[MDN manifest.json/permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/permissions)｜摘录："Manifest V3 or higher: install time request with the `host_permissions` manifest key. runtime request with the `optional_host_permissions` manifest key."

**（2）host 权限能换来什么（与转发器/引擎直接相关的部分）**

来源：[Declare permissions](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions)｜摘录（Chrome）：
- "Make `fetch()` requests from the extension service worker and extension pages."
- "Read and query the sensitive tab properties (url, title, and favIconUrl) using the `browser.tabs` API."
- "Inject a content script programmatically."
- "Monitor and control the network requests with the `browser.webRequest` API."
- "Redirect and modify requests and response headers using `browser.declarativeNetRequest` API."

同页还给出**无需 host 权限的例外清单**（对本题极其关键）｜摘录：
> "In some special cases, host permissions are **not** required. These include: … **Allowing the injection of a content script declared in the manifest.**"

MDN 侧额外说明 Firefox 的差异：host 权限带来的 `XMLHttpRequest`/`fetch` 无跨源限制"**but not for requests from content scripts**"（MV3 content script 不继承 host 权限，见 2.9）。
来源：[MDN host_permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/host_permissions)

**（3）用户授权流程：安装即授权，但用户随时可以收回**

- Chrome 安装时 `host_permissions` 会进安装提示（MDN：Chrome displays the permissions in the install prompt）；Firefox 直到 **126** 都不在安装提示里显示 MV3 的 host 权限，**Firefox 127 起**才显示 `host_permissions` 与 `content_scripts` 中的 host 权限。
  来源：[MDN host_permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/host_permissions)｜摘录："Until Firefox 126, a Manifest V3 extension's requested host permissions weren't displayed in the install prompt. From Firefox 127, host permissions listed in `host_permissions` and `content_scripts` are displayed in the install prompt."
- Chrome（Chrome 70 起）给用户三个档位："on click / on specific sites / on all requested sites"，并在 `chrome://extensions` 与扩展右键菜单暴露。
  来源：[User controls for host permissions: transition guide](https://developer.chrome.com/docs/extensions/mv2/runtime-host-permissions)｜摘录："Users can choose to allow your extension to run on click, on a specific set of sites, or on all requested sites."

**（4）运行时请求：`permissions.request()` 的硬性形状**

来源：[chrome.permissions API](https://developer.chrome.com/docs/extensions/reference/api/permissions)｜摘录：
- "Request the permissions from within a **user gesture** using `permissions.request()`"
- "These permissions must either be defined in the `optional_permissions` field of the manifest **or be required permissions that were withheld by the user**. Paths on origin patterns will be ignored."
- "You can request **subsets** of optional origin permissions; for example, if you specify `*://*/*` in the `optional_permissions` section of the manifest, you can request `http://example.com/`."
- "If you want to request hosts that you only discover at runtime, include `"https://*/*"` in your extension's `optional_host_permissions` field."

Firefox 的口径（更严格，明写"必须在 user action 的处理器内"）：
来源：[MDN permissions.request](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/permissions/request)｜摘录："The extension can only make the request **inside the handler for a user action**. … The browser makes one request for all requested permissions: either all are granted, or none are."

Chrome 的迁移文档里还有一条**用户手势**的旁证注释：
来源：[runtime-host-permissions](https://developer.chrome.com/docs/extensions/mv2/runtime-host-permissions)｜摘录："// Note: `permissions.request()` requires a user gesture, so this may only be done in response to a user action."

**（5）不能声明为可选的权限（Chrome）**

来源：[chrome.permissions API（"Permissions that can not be specified as optional"表）](https://developer.chrome.com/docs/extensions/reference/api/permissions)｜摘录：表中包含 `"declarativeNetRequest"` — "Grants the extension access to the browser.declarativeNetRequest API."；此外还有 `debugger`、`devtools`、`geolocation`、`proxy`、`tts` 等。
对照 Firefox：MDN 的 `optional_permissions` 列表**包含** `declarativeNetRequest` / `declarativeNetRequestWithHostAccess`（并标注 `webRequest`、`webRequestBlocking` 属"静默授予、不弹窗"）。
来源：[MDN optional_permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/optional_permissions)

**（6）Chrome 133+ 的"host access request"（不依赖用户手势的另一种授权通道）**

来源：[chrome.permissions API / addHostAccessRequest](https://developer.chrome.com/docs/extensions/reference/api/permissions)｜摘录："Chrome 133+ MV3+ … Adds a host access request. Request will only be signaled to the user if extension can be granted access to the host in the request. Request will be reset on cross-origin navigation. When accepted, grants persistent access to the site's top origin."
→ **推论**：这是一条"先声明意图、由用户在扩展菜单里点确认"的通道；Chrome 文档未在该方法下要求调用方处于用户手势中（与 `request()` 的措辞不同）。**该差异未在文档中显式对比，仅按原文措辞记录**；是否真能脱离用户手势调用（尤其从 SW 调用）见 §7-U9。

**（7）权限被撤销后会发生什么**

有文档支撑的部分（Chrome，按"访问权限按站点生效"的模型）：
来源：[runtime-host-permissions](https://developer.chrome.com/docs/extensions/mv2/runtime-host-permissions)｜摘录：
- "The extension can still inject scripts and style sheets automatically for any sites it has access to. … If the content script was set to inject at `document_idle`, the script will inject immediately. Otherwise, Chrome prompts the user to **refresh the page** to allow your extension to inject scripts earlier in page load (at `document_start` or `document_end`)."
- "For sites the extension does not have access to, Chrome badges the extension to indicate that the extension requests access to the page."
- （后台页 XHR）"Trying to access a cookie for another site or make a cross-origin XHR **will fail with an error as if the extension's manifest did not include the host permission**."
- （webRequest）"Chrome then prompts the user to refresh the page to allow your extension to intercept the network requests."

事件面：Chrome 与 Firefox 都提供 `permissions.onRemoved`，官方也建议用它感知用户撤销。
来源：[chrome.permissions / onRemoved](https://developer.chrome.com/docs/extensions/reference/api/permissions)、[MDN permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/permissions)｜摘录（MDN）："Extensions that use optional permissions should listen for `browser.permissions.onAdded` and `browser.permissions.onRemoved` API events to know when a user grants or revokes these permissions."

**没有文档支撑、必须实测的部分**：**权限被撤销后，已经注入在页面里的转发器脚本是否继续运行** → 见 §7-U1。

> **推论（需实测）**：转发器是一段已经执行过的页面内 JS。只要页面没有导航/重载，它在 JS 运行时层面就还在（没有文档声明浏览器会主动销毁它）；它能继续用 `runtime.sendMessage` 与 SW 通信（消息 API 不需要 host 权限），但任何**需要 host 权限的扩展侧动作**（扩展页/SW 向该 host 发 `fetch`、`webRequest` 事件、**再次注入**）会像"没声明该 host"一样失败。DNR 的 `block`/`allow`/`upgradeScheme` 规则不需要 host 权限，仍会生效；`redirect`/`modifyHeaders` 需要 host 权限。

### 2.2 content script 注入是否必须依赖 host 权限

| 注入方式 | Chrome | Firefox |
|---|---|---|
| manifest `content_scripts`（声明式） | **不需要 host 权限**（官方例外清单明文） | **需要**：无 host 权限则不执行 |
| `scripting.registerContentScripts()`（动态声明） | 需 `"scripting"`；host 权限/`activeTab` 关系文档未逐条列出（**未验证**：见 §7-U2） | 同左（MDN 的"Registered content scripts are only executed if the extension is granted host permissions"覆盖"已注册"的两种情况） |
| `scripting.executeScript()`（程序化） | 需要 `"scripting"` + host 权限，或临时性 `activeTab` | 需要 `activeTab` **或** host 权限 |

来源（Chrome 声明式不需要 host 权限）：[Declare permissions](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions)｜摘录见 2.1（2）。
来源（Chrome 程序化需要 host 或 activeTab）：[Content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts)｜摘录："To inject a content script programmatically, your extension needs **host permissions** for the page it's trying to inject scripts into. Host permissions can either be granted by requesting them as part of your extension's manifest or temporarily using `"activeTab"`."
来源（Firefox 需要 host 权限）：[MDN Content scripts](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Content_scripts)｜摘录："**Registered content scripts are only executed if the extension is granted host permissions for the domain.**"；"To inject scripts programmatically, the extension needs either the `activeTab` permission or host permissions. The `scripting` permission is required to use methods from the `scripting` API."

**注入被"站点访问"档位门控（Chrome）**：即使 manifest 里声明了、host 权限在用户那里被收窄，注入也按站点生效，并按 `run_at` 决定是否需要用户刷新页面（见 2.1(7) 摘录）。

**注入不了的地方（对 R5 决定性）**
来源：[MDN Content scripts / Limitations](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Content_scripts)｜摘录："Extensions cannot inject content scripts into privileged browser UI pages (such as `about:debugging`, `about:addons`, reader view, view-source, or the PDF viewer) **or extension pages**."
来源（Chrome，match pattern 的 scheme 白名单）：[Match patterns](https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns)｜摘录："**scheme**: Must be one of the following…: `http`, `https`, A wildcard `*`, which matches only `http` or `https`, `file`" ⇒ **`chrome-extension://` 不是合法 match pattern scheme**，扩展页无法通过 `content_scripts.matches` 命中。

### 2.3 declarativeNetRequest：权限模型与规则配额

**（1）两个权限的区别（不是能力差别，是"何时被授予/是否弹警告"）**

来源：[Chrome DNR 参考 / Permissions](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest)｜摘录：
- "The "`declarativeNetRequest`" and "`declarativeNetRequestWithHostAccess`" permissions provide the **same capabilities**. The difference between them is when permissions are requested or granted."
- "`"declarativeNetRequest"` Triggers a permission warning at install time but provides implicit access to `allow`, `allowAllRequests` and `block` rules."
- "`"declarativeNetRequestWithHostAccess"` A permission warning is not shown at install time, but you must request host permissions before you can perform any action on a host."
- `"declarativeNetRequestFeedback"`：解锁 `getMatchedRules()` 与 `onRuleMatchedDebug`，仅对 unpacked 扩展可用。

来源（Firefox 同构 + 额外要求）：[MDN declarativeNetRequest](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest)｜摘录："The `"declarativeNetRequest"` permission allows extensions to block and upgrade requests **without any host permissions**. Host permissions are required if the extension wants to **redirect requests or modify headers**… For all requests, except for navigation requests (i.e., resource type `main_frame` and `sub_frame`), **host permissions are also required for the request's initiator**."

**（2）配额（Chrome 官方数字；本文只列与"能否超限"相关的量）**

来源：[Chrome DNR / Rule limits](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest)

| 项 | Chrome | Firefox | Edge |
|---|---|---|---|
| 静态规则集数量（manifest 声明） | `MAX_NUMBER_OF_STATIC_RULESETS` = **100** | MDN 未给数值（**未验证**，§7-U3） | 无独立文档数字；随 Chromium（**未验证**） |
| 静态规则集同时启用数 | `MAX_NUMBER_OF_ENABLED_STATIC_RULESETS` = **50**（Chrome 94+） | MDN 页面只写 "Its value is `10`"（**与 Chrome 数字冲突**，见 §6-C3） | 随 Chromium（**未验证**） |
| 静态规则条数 | `GUARANTEED_MINIMUM_STATIC_RULES` = **30000**"guaranteed at least"，超出部分消耗**全局静态规则池**（所有扩展共享），运行时用 `getAvailableStaticRuleCount()` 查询 | MDN 未给 Firefox 数值（**未验证**） | 随 Chromium（**未验证**） |
| 动态规则 | `MAX_NUMBER_OF_DYNAMIC_RULES` = **30000**（Chrome 121+，safe），`MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES` = **5000** | `MAX_NUMBER_OF_DYNAMIC_RULES` = **5000**（Chrome 同页写 30000） | 随 Chromium（**未验证**） |
| 会话规则 | `MAX_NUMBER_OF_SESSION_RULES` = **5000**（Chrome 120+），`MAX_NUMBER_OF_UNSAFE_SESSION_RULES` = **5000** | **5000** | 随 Chromium（**未验证**） |
| 正则规则 | `MAX_NUMBER_OF_REGEX_RULES` = **1000**，且**动态/静态分开计算**；单条编译后 < 2KB，超限"the rule will be ignored" | "this limit is evaluated separately **per ruleset**"（未给数值） | 随 Chromium（**未验证**） |
| 被禁用的静态规则 | "There is a maximum limit of **5000** disabled static rules" | MDN 有 `MAX_NUMBER_OF_DISABLED_STATIC_RULES` 词条（未给数值） | — |

**（3）"是否付费"**

- API 文档里**不存在**任何"付费提升配额"的机制。
- 与配额相邻的官方机制只有一个：**Chrome Web Store 的"跳过审核"（expedited review）**，其适用条件与配额无关，只与"改动仅限 `rule_resources` 指向的文件、且只含 safe rules"有关。
  来源：[Skip review for eligible changes](https://developer.chrome.com/docs/webstore/expedited-review)｜摘录："Drafts are eligible if all of the following conditions are met: The extension has `declarativeNetRequest` as a required permission. The only changes are to files referenced in the `rule_resources` manifest key. Any new rules added, updated or removed from the static rulesets are safe rules."
- ⇒ 结论：**没有付费档**；静态规则超出"保证下限"后是否还能装，取决于全局池，官方给的是"用 `getAvailableStaticRuleCount()` 查询、不要假设"。

**（4）超出配额会发生什么**

来源：[Chrome DNR 参考](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest)｜摘录：
- `updateDynamicRules()`："the promise will be rejected and **no change will be made** to the rule set. This can happen for multiple reasons, such as invalid rule format, duplicate rule ID, **rule count limit exceeded**, internal errors"；"This update happens as a single atomic operation"。
- `updateSessionRules()`：同构（"rule count limit exceeded"）。
- `updateEnabledRulesets()`：同样"rejected and no change"，原因含"rule count limit exceeded"。
- 正则超限："If you try to load a rule that exceeds this limit, you will see a warning like the following and **the rule will be ignored**."
- 静态规则非法："**Invalid static rules in packed extensions are ignored.**"（unpacked 才显示错误/告警）

**（5）DNR 的一个固有边界（对我们"命中即拦"的路线是加分项，也是限制）**

来源：[Chrome DNR 参考 / Interactions with service workers](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest)｜摘录："A declarativeNetRequest only applies to requests that reach the network stack. This includes responses from the HTTP cache, but may not include responses that go through a service worker's `onfetch` handler."

### 2.4 扩展 CSP 与页面 CSP 的相互影响

**（1）MV3 扩展页 CSP：不可放宽**

来源：[Manifest - Content Security Policy](https://developer.chrome.com/docs/extensions/reference/manifest/content-security-policy)｜摘录：
- 默认值："`"extension_pages": "script-src 'self'; object-src 'self';"`，`"sandbox": "sandbox allow-scripts allow-forms allow-popups allow-modals; script-src 'self' 'unsafe-inline' 'unsafe-eval'; child-src 'self';"`"
- 最小值 + 不可放宽："Chrome enforces a **minimum** content security policy for extension pages… `"extension_pages": "script-src 'self' 'wasm-unsafe-eval'; object-src 'self';"` … **The `extension_pages` policy cannot be relaxed beyond this minimum value.** In other words, you cannot add other script sources to directives, such as adding `'unsafe-eval'` to `script-src`."
- sandbox 页定位："the sandbox page does not have access to extension APIs, or direct access to non-sandboxed pages."

**（2）content script（isolated world）有自己的 CSP，页面 CSP 不适用**

来源：[Chrome Content scripts / Content Security Policy](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts)｜摘录：
- isolated world 的 CSP："`script-src 'self' 'wasm-unsafe-eval' 'inline-speculation-rules' chrome-extension://abcdefghijklmopqrstuvwxyz/; object-src 'self';`"；"This prevents the use of `eval()` as well as loading external scripts."
- MAIN world 例外："**When a content script is injected into the main world, the CSP of the page applies.**"

**（3）页面里的 `<script>` 注入（DOM injected script）受页面 CSP 管——这是"放多少逻辑进哪一层"的关键**

来源（历史同源文档、语义仍成立；⚠️ 该页 ms.date=2022-11-09，MV2 时代的措辞，见 §6-C2）：[Edge：Using CSP](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/csp)｜摘录："Content scripts are generally **not** subject to the CSP of the extension. … Additionally, **the CSP of the page doesn't apply to content scripts**. … while the initial script runtime is allowed, **the behavior within the script is regulated by the CSP of the page**. … Since content scripts aren't affected by the CSP of the page, this a great reason to **put as much behavior as possible of your extension into the content script**, rather than DOM injected scripts."

**（4）对本次方案的直接含义**

- 转发器逻辑放在 **isolated-world content script**：不受页面 CSP 约束（但受扩展自身那套 CSP 约束：不能 eval、不能外链脚本）。
- 转发器逻辑要进 **MAIN world**（为了替换页面 `window.fetch` 等）：**页面 CSP 随之适用**（对注入代码自身的 eval / 动态代码执行）；页面 CSP 是否**阻止注入动作本身**，不属于本文结论 → §7-U4。
- 内置 AriaNg 是**扩展页**：受最小 CSP 约束，见 §2.8。

### 2.5 https 页面 → http 目标（混合内容）

**（1）规范怎么定义**

来源：[W3C Mixed Content（ED, 2023-02-23）](https://w3c.github.io/webappsec-mixed-content/)｜摘录：
- "A request is **mixed content** if its URL is not a potentially trustworthy URL **and** the context responsible for loading it prohibits mixed security contexts."
- 分类："upgradeable" = 只含 image / audio / video；"Any mixed content that is not upgradeable … is considered to be **blockable**. Typical examples of this kind of content include scripts, plugin data, **data requested via XMLHttpRequest**, and so on."
- 判定算法：§4.4 "Should fetching request be blocked as mixed content?" — 仅在「settings 不禁止混合内容 / URL 本身可信 / UA 被用户指示放行 / 顶层导航」时返回 allowed，否则 **blocked**。
- 自动升级：§4.1。`upgrade-insecure-requests` 未废弃；`block-all-mixed-content` 已废弃（§6.1）。

**（2）检查发生在**哪一步**——决定"命中即拦"能否绕过**

来源：[WHATWG Fetch Standard](https://fetch.spec.whatwg.org/#main-fetch)｜摘录（Main fetch 步骤）："If **should request be blocked due to a bad port, should fetching request be blocked as mixed content, should request be blocked by Content Security Policy**, … returns blocked, **then return a network error**."
→ **推论（规范结构层面，强）**：混合内容检查是 **Fetch 算法内部的一步**。我们的转发器把页面的 `window.fetch` / `XMLHttpRequest` / `WebSocket` 入口函数替换掉之后，被拦截的调用**不会进入原生算法**，因此这一步、以及 `Upgrade a mixed content request to a potentially trustworthy URL` 都不会执行。当页面的 JS 已经不调用原生 API 时，"https 页面 → http 目标"的混合内容限制**不会触发**。
→ 但这是 **JS 语义的必然结果，不是规范给扩展的特权**：任何绕过原生 API 的路径（Worker 内的真 fetch、`<img>`、导航、页面上未被覆盖的 API）仍然照常受检。这与 R9/Q-D2 的盲区清单互相印证。

**（3）我们的默认目标很可能根本不构成混合内容**

Chromium 官方给出的 "secure origins" 列表包含 loopback 与扩展 scheme：
来源：[Chromium：Prefer Secure Origins For Powerful New Features](https://www.chromium.org/Home/chromium-security/prefer-secure-origins-for-powerful-new-features/)｜摘录（secure origins 的模式列表）：`(https, *, *)`、`(wss, *, *)`、`(*, localhost, *)`、`(*, 127/8, *)`、`(*, ::1/128, *)`、`(file, *, —)`、`(chrome-extension, *, —)`。

MDN 的口径一致（并把"浏览器认为已认证的 scheme（例如扩展用的 scheme）"列入）：
来源：[MDN Secure contexts](https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Secure_Contexts)｜摘录："A host value of `127.0.0.0/8` or `::1/128`；A host value of `localhost`；… A scheme that the browser considers to be authenticated … (for example, those used by browser extensions)."

→ 结论：**`http://127.0.0.1:6800` / `http://localhost:6800` 是 potentially trustworthy URL**，即使真的发起请求也不构成混合内容（Chrome/Chromium 有官方列表；Firefox 侧 MDN 给的是通用口径，**未逐浏览器实测**）。反过来，`http://example.com:8443` 这类**非 loopback 的 http 目标**从 https 页面发起时属于 blockable mixed content，只有"命中即拦"能绕过。

### 2.6 来源识别能力（即便不做白名单）

**（1）注入路径：转发器自己就知道自己是谁（免费且最可靠）**

- 在 content script 里可直接读 `window.location.href` / `document.referrer` / 所在 frame（isolated world 里 `globalThis !== window` 是 Firefox 的已知差异，见 §2.9）。
- 与 SW 通信时，`runtime.MessageSender` 提供来源结构。
  来源：[MDN runtime.MessageSender](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/runtime/MessageSender)｜摘录字段：`documentId`（UUID）、`frameId`（顶层为 0，"only set when `tab` is set"）、`origin`（"may differ from the url property (e.g., about:blank) or be opaque"）、`tab`（`tabs.Tab`，"only present when the connection was opened from a tab (including content scripts)"）、`url`（"If the script is running in an iframe, `url` is the iframe's URL."）。
- 扩展页一侧（内置 AriaNg）走 `runtime.onMessage` 也能拿到 `sender.url`。

**（2）网络观测路径：能拿到来源，但受 host 权限限制**

来源：[Chrome webRequest 参考](https://developer.chrome.com/docs/extensions/reference/api/webRequest)｜摘录：
- 字段 `details.initiator`（"Chrome 63+ … The origin where the request was initiated. … If this is an opaque origin, the string 'null' will be used."）、`tabId`（"Set to -1 if the request isn't related to a tab"）、`documentId`（Chrome 106+）、`frameId`、`parentDocumentId`、`frameType`。
- 权限门槛："an extension will be able to intercept a request only if it has host permissions to **both the requested URL and the request initiator**."（Chrome 72+）
- 可见 scheme 白名单："only the following schemes are accessible: `http://`, `https://`, `ftp://`, `file://`, `ws://`, `wss://`, `urn:`, or `chrome-extension://`"，且 `chrome-extension://other_extension_id` 隐藏。

**（3）DNR 侧：规则能"按来源"匹配，但正常运行时**不会**把来源回报给扩展**

- 匹配条件可用：`initiatorDomains` / `excludedInitiatorDomains`（Chrome 101+）、`domainType`、`tabIds`（**仅 session 规则**，Chrome 92+）、`topDomains`/`excludedTopDomains`（Chrome 145+）。
  来源：[Chrome DNR / RuleCondition](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest)｜对 `tabIds` 的摘录："List of `tabs.Tab.id` which the rule should match. … **Only supported for session-scoped rules**."
- 想拿到"哪些规则命中了"只能靠 `getMatchedRules()` / `onRuleMatchedDebug` + `declarativeNetRequestFeedback`（仅 unpacked；Firefox 还需 `extensions.dnr.feedback` 偏好）。
  来源：[MDN declarativeNetRequest / Testing](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest)｜摘录："in Chrome, these APIs are only available to unpacked extensions. in Firefox, these APIs are only available after setting the `extensions.dnr.feedback` preference to `true`."

**（3'）结论**：**技术上来源是可知的**——只要走"我们自己的转发器"这条路径，来源就是注入点自己（页面/iframe/tab/document 全有）；而"纯网络层路线"想识别来源，需要 host 权限，且拿不到"页面里的逻辑语义"。

### 2.7 跨浏览器关键差异（Chrome / Edge / Firefox，MV3）

| # | 维度 | Chrome (MV3) | Edge (Chromium, MV3) | Firefox (MV3) | 对我们的影响 |
|---|---|---|---|---|---|
| B1 | **blocking webRequest** | **不可用**，除策略安装扩展 | **不可用**（含企业策略豁免，见 MS 原文） | **可用**（Mozilla 明确保留；MDN 现行 `permissions` 页仍把 `webRequestBlocking` 列为 MV2 及以上可用，未加 MV3 排除） | 🔴 决定性：同一套"网络层拦截"代码不能三浏览器通用；Firefox 可以走 blocking webRequest，Chromium 只能走 DNR + JS 层 |
| B2 | **background** | 仅 service worker（Chrome 121 起 MV3 里 `scripts`/`page` 被忽略） | 同 Chromium | **不支持 `background.service_worker`**，用 event page | 🔴 需要"双声明"清单写法；SW 生命周期假设不能跨浏览器 |
| B3 | **DNR 支持度/配额** | 全量；动态 30000/5000、会话 5000、正则 1000 | 随 Chromium | 支持，但动态 5000、session 5000、正则按 ruleset；匹配优先级多一层"session > dynamic > static" | 🟡 我们只用少量规则 ⇒ 配额不构成约束；但**可用的 action 组合**（redirect/modifyHeaders 需 host 权限）要按 Firefox 的严格要求设计 |
| B4 | **offscreen document** | Chrome 109+，需 `"offscreen"` 权限；只有 `runtime` 一个扩展 API；一个 profile 一个 | 随 Chromium（**未验证**） | **无官方支持声明** ⇒ 见 §7-U5 | 🟡 若"引擎"路线依赖 offscreen，则 Firefox 直接缺一条腿 |
| B5 | **File System Access（`showSaveFilePicker` 等）** | Chrome 86+ | Edge = mirror（支持） | **不支持** | 🔴 落盘路线在 Firefox 必须另找途径（`chrome.downloads`/Blob 等），且该方法需要 **transient user activation** |
| B6 | **content script 跨源能力** | MV3：content script **不**继承 host 权限，受页面 CORS 约束；扩展页/SW 才有特权 | 同 Chromium（Edge 文档原文见 §8） | 同（MDN："host permissions don't work in content scripts, but they still do in regular extension pages"） | 🔴 转发器若要在页面侧代替页面发"真实请求"，其跨源能力等同页面；真正的特权请求只能由扩展页/SW 发起 |
| B7 | **content script 生命周期** | 页面导航即销毁；后退时重新注入 | 同 Chromium | **导航后脚本仍驻留**（但其 `window` 属性被销毁） | 🟡 "已注入的转发器"在 Firefox 可能残留，需按 `pageshow/pagehide` 自管理 |
| B8 | **扩展 URL** | `chrome-extension://<固定 id>/` | 同 Chromium | `moz-extension://<随机 UUID>/`（每次安装变） | 🟡 任何硬编码扩展 URL 会碎；必须 `runtime.getURL()` |
| B9 | **命名空间** | Chrome 148 前只有 `chrome`；`browser` 命名空间与新版本相关 | 同 Chromium | 一直 `browser`（Promise 风格） | ⚪ 用 polyfill 或统一封装 |
| B10 | **host 权限的"可选化"** | 安装即授，用户在站点访问 UI 里收窄 | 同 Chromium（Edge 文档明确"controls that enable users to allow or restrict access to websites at runtime"） | MV3 视 host 权限为可选，用户在 Add-ons Manager 授予/撤销 | 🟡 首次运行的"可用性"在两浏览器完全不同：Chrome 可能开箱可用，Firefox 可能第一屏全都不可用 |

来源逐条：
- B1：[Chrome webRequest](https://developer.chrome.com/docs/extensions/reference/api/webRequest)（"`webRequestBlocking` Required to register blocking event handlers. **As of Manifest V3, this is only available to policy installed extensions.**"）；[Chrome 迁移文档](https://developer.chrome.com/docs/extensions/develop/migrate/blocking-web-requests)（"You don't need to make these changes if your extension is installed by policy. For policy installed extensions, the `webRequestBlocking` permission is still available in Manifest V3."）；[Edge MV2→V3](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/migrate-your-extension-from-manifest-v2-to-v3)（"…but we continue to keep the **observational** capabilities of the Web Request API. … **Enterprises can continue to use the blocking behavior** of the Web Request API for extensions that are managed through enterprise policies."）；[Mozilla Add-ons Blog](https://blog.mozilla.org/addons/2022/05/18/manifest-v3-in-firefox-recap-next-steps/)（"**Mozilla will maintain support for blocking WebRequest in MV3.** To maximize compatibility with other browsers, we will also ship support for declarativeNetRequest."）
- B2：[MDN manifest/background](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/background)（"Firefox: `background.service_worker` is **not supported** … supports `background.scripts` (or `background.page`) …"；"Chrome: supports `background.service_worker`. … From Chrome 121, their presence in a Manifest V3 extension is ignored."；跨浏览器做法：同时写 `scripts` 与 `service_worker`）
- B3：见 2.3；Firefox 优先级见 [MDN DNR / Matching precedence](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest)（"After rule priority and rule action, Firefox considers the ruleset the rule belongs to, in this order of precedence: session > dynamic > static rulesets."）
- B4：[Chrome offscreen](https://developer.chrome.com/docs/extensions/reference/api/offscreen)（"Chrome 109+ MV3+"；"the `runtime` API is the only extensions API supported by offscreen documents"；"an installed extension can only have one open at a time"）
- B5：[MDN `showSaveFilePicker()`](https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker)（"Transient user activation is required."；`SecurityError` "if the call was blocked … or it was not called via a user interaction"）；[MDN BCD `api/Window.json`](https://raw.githubusercontent.com/mdn/browser-compat-data/main/api/Window.json)（`showSaveFilePicker`: chrome 86 / edge "mirror" / **firefox false** / safari false）
- B6：[MDN Content scripts / XHR and Fetch](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Content_scripts)（"When using Manifest V3, content scripts can perform cross-origin requests when the destination server opts in using CORS; however, **host permissions don't work in content scripts**, but they still do in regular extension pages."；并指向 Chromium 的 [Changes to Cross-Origin Requests in Chrome Extension Content Scripts](https://www.chromium.org/Home/chromium-security/extension-content-script-fetches/)）
- B7：[MDN Chrome incompatibilities / Content script lifecycle during navigation](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Chrome_incompatibilities)（"In Firefox: Content scripts remain injected in a web page after the user has navigated away. However, window object properties are destroyed… In Chrome: Content scripts are destroyed when the user navigates away…"）
- B8：[MDN Chrome incompatibilities / web_accessible_resources](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Chrome_incompatibilities)（"In Firefox: Resources are assigned a **random UUID** that changes for every instance of Firefox… In Chrome: … The extension ID is fixed for an extension."）
- B9：同上（"Before Chrome 148, Chrome exposed APIs only under the `chrome` namespace rather than `browser`."）
- B10：[MDN host_permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/host_permissions)（"Users can grant or revoke host permissions on an ad hoc basis. Therefore, **most browsers treat `host_permissions` as optional**."）；[Mozilla Blog](https://blog.mozilla.org/addons/2022/05/18/manifest-v3-in-firefox-recap-next-steps/)（"Starting with MV3, we'll be treating **all site access requests from extensions as optional**"）；[Edge MV2→V3](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/migrate-your-extension-from-manifest-v2-to-v3)（"Edge extensions can use controls that enable you to allow or restrict access to websites at runtime."）

**MV2 作为"逃生舱"是否还在？**
- Chrome：**不在**。[Manifest V2 support timeline](https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline)｜摘录："**Jul 24th 2025: Manifest V2 is disabled everywhere.** With Chrome 138 all users on all channels of Chrome have now Manifest V2 extensions disabled. Users can no longer turn them back on."；"Aug 31st 2026: All remaining Manifest V2 extensions removed from the Chrome Web Store."
- Edge：**暂时还有**。[Edge MV3 timeline](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/manifest-v3)｜摘录："Aug. 2026 … a Manifest V2 deprecation warning is displayed."；"**Early 2027** For enterprise customers, deprecation of Manifest V2 extensions is expected to begin."

### 2.8 内置 AriaNg UI 的 CSP 特例（R5 的落点）

**（1）平台事实：扩展页注入不进去，且扩展页 CSP 不可放宽**
- 扩展页不能被 content script 注入：[MDN Content scripts](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Content_scripts)、[Chrome Match patterns](https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns)（见 2.2）。
- 官方给出的"扩展页里动态跑代码"的正统姿势：**在页面里直接引入脚本**。MDN 原文｜摘录："If an extension wants to run code in an extension page dynamically, it can **include a script in the page**. This script contains the code to run and registers a `runtime.onMessage` listener that implements a way to execute the code."
  → 这正是 R5 所述的"只在这个页面里换另一种**装载方式**、不换接入路径"的官方对应做法（同一个 forwarder 文件、同一套拦截逻辑，只是由 `<script src>` 装载，而不是由 extension 注入 API 装载）。

**（2）扩展页 CSP 对 AriaNg 的具体限制**
- 不许内联 `<script>`、不许内联事件处理器、不许 `eval`/`new Function`/字符串 `setTimeout`、不许远程脚本；`extension_pages` 不可放宽（见 2.4(1)）。
- AriaNg 源码快照核对（`mayswind/AriaNg` 主分支，2026-10-06 拉取 `src/index.html`）：**全文没有内联 `<script>` 块**，脚本全部是外链本地文件；样式表里引了 `angular-csp.css`（CSP 模式的配套样式）。→ 说明 AriaNg 的页面结构本身是 CSP 友好的。
  来源：[AriaNg src/index.html](https://raw.githubusercontent.com/mayswind/AriaNg/master/src/index.html)
- AngularJS 的 eval 依赖会自动降级（源码级证据）：AriaNg 打包的是 AngularJS **1.6.10**，其 `csp()` 在无 `ng-csp` 属性时会**主动探测** eval 是否可用：
  来源：[angular.js 1.6.10（官方 CDN）](https://code.angularjs.org/1.6.10/angular.js)｜源码摘录：
  ```js
  csp.rules = { noUnsafeEval: noUnsafeEval(), noInlineStyle: false };
  function noUnsafeEval() { try { new Function(''); return false; } catch (e) { return true; } }
  ```
  且该探测结果被注入 `$parse` 的 `csp: noUnsafeEval`（同一文件：`var noUnsafeEval = csp().noUnsafeEval; … csp: noUnsafeEval`）⇒ 在禁止 `unsafe-eval` 的扩展页里，AngularJS 会改用解释器路径。
- 由此得到的**风险点**（需实测，见 §7-U6）：AngularJS 1.6.10 的解释器模式、以及 AriaNg 依赖的**各第三方库**（`echarts`、`angular-ui-notification`、`angular-sweetalert`、`admin-lte` 等）是否有 `eval`/`new Function`/内联样式/内联脚本？本次只核对了入口 HTML 与 Angular 的 eval 探测；**逐库审计未做**。

**（3）扩展页访问 RPC 地址（localhost）是否受混合内容影响**
- 扩展页是 potentially trustworthy origin（Chromium secure origins 列表含 `(chrome-extension, *, —)`；MDN Secure contexts 也把"浏览器认为已认证的 scheme"列入）。
- RPC 目标若是 `http://127.0.0.1:6800` / `http://localhost:6800`：loopback 同样是 potentially trustworthy ⇒ **不构成混合内容**（§2.5(3)）。
- 扩展页发起 `fetch()` 到任意 origin，需要 host 权限覆盖该 origin（§2.1(2)）。
- 扩展页发起 **`ws://`** 到 loopback：**未验证**（§7-U7）。

### 2.9 与"现有裁定"直接相关的一处 Firefox 差异（转发器可移植性）

- Firefox 的 content script 全局对象不是 `window`（`globalThis` 是另一个对象、以 `window` 为原型），页面属性经 Xray 包裹；Chrome 的 global 就是 `window`。
  来源：[MDN Chrome incompatibilities / Content script environment](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Chrome_incompatibilities)｜摘录："In Firefox: The global scope of the content script environment is **not strictly equal to `window`** … More specifically, the global scope (`globalThis`) is composed of standard JavaScript features as usual, plus `window` as the prototype of the global scope."
- `eval` 语义差异：Chrome 里 `eval` 与 `window.eval` 都在 content script 上下文；Firefox 里 `eval` 在 content script、`window.eval` 在页面上下文。同页｜摘录："In Chrome: `eval` and `window.eval` always runs code in the context of the content script, not in the context of the page."
- MV2 的 `content.XMLHttpRequest` / `content.fetch()`（"以页面身份发请求"）在 MV3 **不存在**（MDN Content scripts｜摘录："This is not possible in Manifest V3, as `content.XMLHttpRequest` and `content.fetch()` are not available."）⇒ 如果转发器需要"代替页面发真实请求"，MV3 下没有现成 API，必须借助扩展页/SW（那又回到 host 权限与 CORS 的约束）。

---

## 3 硬约束（不可协商项）

| ID | 约束 | 依据 |
|---|---|---|
| H1 | `permissions.request()` 必须处于用户手势中；且只能请求 manifest 里已声明的可选项 | §2.1(4) |
| H2 | Chrome 里 `declarativeNetRequest` **不能**是可选权限；要 DNR 就必须进 `permissions` 并吃安装期警告 | §2.1(5) |
| H3 | Firefox MV3 的 host 权限对用户是**可选**的：未授予 = 已注册 content script **不执行** | §2.1(3)、§2.2 |
| H4 | Chrome 的**声明式** content script 不需要 host 权限；**程序化注入**必须有 host 权限或 `activeTab` | §2.2 |
| H5 | 扩展页**不可能**被 content script 注入（Chrome scheme 白名单 + MDN 明文） | §2.2 |
| H6 | 扩展页 CSP 不可放宽：无 eval / 无内联脚本 / 无远程脚本 | §2.4(1) |
| H7 | isolated-world content script 不受页面 CSP 约束；MAIN world 注入后受页面 CSP 约束 | §2.4(2)(3) |
| H8 | MV3 下 content script **不**继承 host 权限，跨源按页面 CORS；特权请求只能由扩展页/SW 发起 | §2.7-B6 |
| H9 | Chromium MV3 无 blocking webRequest（仅策略安装）；Firefox MV3 有 | §2.7-B1 |
| H10 | Chromium MV3 只有 service worker；Firefox 只有 event page | §2.7-B2 |
| H11 | `showSaveFilePicker` 在 Firefox 不存在，且需要 transient user activation | §2.7-B5 |
| H12 | DNR 只作用于到达网络栈的请求 | §2.3(5) |
| H13 | 混合内容检查位于 Fetch 算法内部；绕过原生 JS API 即绕过该检查 | §2.5(2) |
| H14 | 非 loopback 的 `http://` 目标从 https 页面发起 = blockable mixed content；loopback 目标不构成混合内容 | §2.5(1)(3) |
| H15 | 配额超限是**原子失败/规则被忽略**，不会"部分生效" | §2.3(4) |

---

## 4 能力映射

### 4.1 必须在早期就锁定的**浏览器支持矩阵**（本任务的核心交付）

> 说明：本矩阵只覆盖"转发器权限/安全/上下文"相关维度；🟢=官方文档明确支持；🟡=支持但有前置条件；🔴=不支持/不可用；❔=本次未能核实（见 §7）。

| 能力 | Chrome (MV3) | Edge (MV3) | Firefox (MV3) | 我们的方案是否受影响 |
|---|---|---|---|---|
| 声明式 content script 注入 | 🟢 不需要 host 权限 | 🟢 同 Chromium | 🟡 需要 host 权限且用户可撤销 | **受影响**：Firefox 首装可能"零覆盖" |
| 程序化注入 | 🟡 host 权限或 activeTab | 🟡 同 | 🟡 host 权限或 activeTab | 受影响（需备好授权引导） |
| 扩展页被注入 | 🔴 | 🔴 | 🔴 | **受影响（R5 特例的根因）** |
| 运行时请求 host 权限 | 🟡 需用户手势；`addHostAccessRequest`（133+，文档未要求手势） | 🟡 同 | 🟡 需 user action handler | 受影响（授权 UX 要按浏览器分叉） |
| DNR block/allow（无需 host 权限） | 🟢 | 🟢 | 🟢 | 不受影响（我们只加极少量规则） |
| DNR redirect / modifyHeaders | 🟡 需 host 权限（`dNRWithHostAccess` 或 host） | 🟡 同 | 🟡 需 host 权限（**且非导航请求还需 initiator 的 host 权限**） | 受影响（附录 A 的两条 DNR 路线在 Firefox 上要额外 host 权限） |
| DNR 动态/会话规则配额 | 🟢 30000/5000、5000 | 🟢 同 | 🟢 5000/5000 | 不受影响（我们规划 ≤10 条） |
| blocking webRequest | 🔴（仅策略安装） | 🔴（企业策略豁免） | 🟢 | **受影响**：不能作为通用拦截路径 |
| 观测型 webRequest（含 initiator/tabId） | 🟡 需双 host 权限 | 🟡 同 | 🟡 同（MDN 需 `webRequest` + host） | 受影响（"来源识别"的第二条腿有权限门槛） |
| background service worker | 🟢 唯一形态 | 🟢 同 | 🔴（用 event page） | **受影响**：状态机不能依赖 SW 生命周期（与 Q-D5 一致，但要补一句"Firefox 无 SW"） |
| offscreen document | 🟢 109+ | ❔（随 Chromium，未核到 Edge 文档） | ❔/🔴（无官方声明） | 受影响（若引擎依赖 offscreen） |
| `showSaveFilePicker` / File System Access | 🟢 86+，需用户手势 | 🟢 mirror | 🔴 | **受影响**：落盘只能走 downloads/Blob 等 |
| 扩展页 CSP 可放宽（eval/远程） | 🔴 | 🔴（Edge 旧文档写可放宽 ⇒ 见 §6-C2） | 🔴 | 不受影响（AriaNg 页面本身无内联脚本） |
| loopback `http://` 被视为可信来源 | 🟢（Chromium 官方 secure origins 列表） | 🟢（随 Chromium，未单独核到 Edge 文档） | 🟡（MDN 通用口径，未逐浏览器核实） | 不受影响（默认目标不构成混合内容） |
| 扩展页 URL 稳定性 | 🟢 固定 id | 🟢 | 🔴 随机 UUID | 受影响（不能硬编码） |
| content script 跨源特权（MV3） | 🔴 | 🔴 | 🔴 | **受影响**：转发器不能在页面侧"代替页面"发特权请求 |
| `browser.*` 命名空间 | 🟡 Chrome 148 分区差异 | 🟡 同 | 🟢 | 轻微（polyfill 可解） |

**矩阵的含义（要写进后续设计的结论）**：
1. **不存在"一份实现三浏览器通用"的转发器**：至少 `注入授权路径`（Chrome 可直接注入 / Firefox 需先授权）、`网络层路线`（Chromium=DNR / Firefox 可 blocking）、`后台形态`（SW / event page）三处分叉。
2. **"多途径拦截"的可行性排序因浏览器而异**：Firefox 可以用 blocking webRequest 覆盖 JS 层之外的一部分请求；Chromium 只能靠 DNR（无法返回任意响应体，R9 已裁定不走这条路）⇒ 我们实际能依赖的骨架仍是"注入 + JS API 覆盖"。
3. **R5 的"扩展页特例"是唯一出路，不是妥协**：矩阵里"扩展页被注入 = 🔴"三浏览器一致。

### 4.2 本任务范围问题的逐条回答（速查）

| 问题 | 结论 |
|---|---|
| host_permissions 声明方式 | MV3 用 `host_permissions` 声明、`optional_host_permissions` 声明可运行时申请；match pattern；path 被忽略 |
| 用户授权流程 | 安装期提示（Chrome 显示；Firefox 127 起显示）→ 用户可在站点访问/附加组件管理器里随时收窄或撤销；`permissions.request()` 必须用户手势、只能请求已声明项 |
| 权限撤销后已注入的转发器会怎样 | 官方只描述"注入按站点门控"与"扩展页/SW 跨源请求像没声明一样失败"；**已注入脚本的去留无官方文字 ⇒ 未验证** |
| content script 注入是否必须 host 权限 | Chrome 声明式**不必须**；Chrome 程序化、Firefox 全部**必须**（后者还受用户可选授予影响） |
| DNR 配额 | Chrome：静态 100 集/50 启用/保证 30000 条（全局池）、动态 30000(safe)/5000(unsafe)、会话 5000、正则 1000/类、单正则<2KB、禁用静态 5000；Firefox：动态 5000、会话 5000、正则按 ruleset；**无付费档**；超限 = 原子拒绝或规则被忽略 |
| 扩展 CSP 与页面 CSP | isolated world 有自己的 CSP（页面 CSP 不适用）；MAIN world 适用页面 CSP；扩展页不可放宽；sandbox 页可放宽但无扩展 API |
| https → http（混合内容） | 规范：blockable（loopback 除外，属可信来源）；检查在 Fetch 算法内；**"命中即拦、不发网络请求"在结构上完全绕开**（推论，JS 语义必然） |
| 扩展页 CSP 对内置 AriaNg 的限制 | 禁 eval/内联/远程；AriaNg 入口页无内联脚本，AngularJS 1.6.10 自动检测并降级到无 eval 解释器；第三方库未逐库审计 |
| 来源识别 | 注入路径：来源免费可得（document/tab/frame/origin）；网络路径：`initiator`/`tabId`/`documentId`，但需 host 权限（请求 URL + initiator）；DNR 匹配可限定来源，但回报需调试权限 |
| Chrome/Edge/Firefox MV3 差异 | 见 §2.7 表与 §4.1 矩阵；对方案的影响逐条已标注 |

---

## 5 失败模式与盲区

| # | 失败模式 | 触发条件 | 表现 | 依据 |
|---|---|---|---|---|
| F1 | 静默零覆盖（Firefox） | 用户未授予 host 权限 | 已注册 content script **不执行**，用户看到"什么都没发生" | §2.2 |
| F2 | 注入被站点访问档位拦下 | 用户把扩展设为"on click"或限定站点 | Chrome 给扩展打角标；`document_start/end` 注入需用户**刷新页面**后才生效 | §2.1(7) |
| F3 | 授权弹窗失败 | 非用户手势内调用 `permissions.request()` | Promise 被拒或直接不弹 | §2.1(4) |
| F4 | DNR 规则无声失效 | 规则集未启用/超出全局静态池/正则过复杂 | unpacked 有告警，**packed 扩展的非法静态规则被忽略** | §2.3(4) |
| F5 | DNR 对某些请求天然不可见 | 请求由 SW `onfetch` 生成或来自 CacheStorage | 规则不生效 | §2.3(5) |
| F6 | 权限被收窄后扩展侧动作"像没声明" | 用户在站点访问里撤掉该 host | 扩展页/SW 对该 host 的跨源请求失败 | §2.1(7) |
| F7 | 内置 UI 白屏 | 任何第三方库使用 eval/内联脚本/远程脚本 | 扩展页 CSP 直接拦下；控制台报 CSP 违规 | §2.4(1)、§2.8(2) |
| F8 | 混合内容回归 | 走非 loopback 的 http 目标且**未**被我们的转发器命中（放行路径/引擎自取字节） | 请求被 blockable mixed content 拦下 | §2.5(1)(2) |
| F9 | 跨源请求失败（转发器想自己发请求） | MV3 content script 里发跨源请求 | 受页面 CORS 约束（不像扩展页有特权） | §2.7-B6 |
| F10 | Firefox 残留脚本错乱 | 页面导航后 Firefox 仍驻留 content script | 脚本存在但 `window` 属性被销毁、多份转发器叠加 | §2.7-B7 |
| F11 | 扩展 URL 写死导致 Firefox 失效 | 使用硬编码 `chrome-extension://…` | Firefox 是随机 UUID，取不到资源 | §2.7-B8 |
| F12 | 权限模型被误当成"来源白名单" | 以为"没授权就没人能调用 RPC" | 与 Q-A4 一致：**不启用 secret 时任何能命中该 URL 的页面都能控制下载**；权限只管"我们能不能拦"，不管"谁能调我们" | 概念文档 §6-3 + §2.6 |

**盲区（转发器视角，与 Q-D2 对齐）**
- 扩展页、`chrome://`/`about:`/view-source/PDF viewer 等特权页、其它扩展的页面：注入不可能（§2.2）。
- MAIN world 之前的请求（`document_start` 之前）：注入时机决定（属 fwd-inject 的结论，这里只给平台约束）。
- 非 JS API 通道（`<img>`、表单导航、WebRTC、WebTransport、其它扩展的请求）：JS 层替换覆盖不到；Firefox 可用 blocking webRequest 兜一部分，Chromium 只能 DNR（且 DNR 拿不到"任意响应体"，R9 已裁定不走）。
- Worker 内的请求：SW/Worker 上下文里没有我们的注入点（取决于 fwd-contexts 的结论）。

---

## 6 与现有裁定的冲突

| ID | 冲突/张力 | 与哪条裁定相关 | 说明与建议 |
|---|---|---|---|
| C1 | **"复用 aria2 的 rpc secret、允许不启用" 与 "权限模型" 是两条不相干的防线** | Q-A4、概念文档 §6-3 | 权限（host permission）决定**我们能不能拦**，不决定**谁能调我们**。不启用 secret 时，任何能命中该 URL 的页面（包括未授权的页面——只要我们在那里成功注入了）都能控制下载。本轮核对没有发现任何浏览器机制能替代 secret 做"来源白名单"（见 §2.6：能做识别，但识别 ≠ 授权，且用户可撤销权限使识别失效）。**不构成冲突，但必须在能力清单里写清"权限≠授权"**。 |
| C2 | **Edge 官方 CSP 文档与 MV3 现状冲突** | 影响 H6/G-UI 的跨浏览器结论 | Edge 的 CSP 页面（ms.date 2022-11-09）仍写"可以给 `script-src` 加 `unsafe-eval`"、"可以 allowlist https 远程脚本"。这与 Chrome 现行 MV3 的**最小 CSP 不可放宽**直接矛盾。Edge 基于 Chromium，按 Chromium 实现应服从 Chrome 口径；但**未核到 Edge 专门针对 MV3 的 CSP 文档** ⇒ 记为冲突 + §7-U8。设计上取**最严格**口径（当 MV3 不可放宽处理）。 |
| C3 | **DNR "启用静态规则集数量"数字不一致** | 影响 §4.1 配额行 | Chrome API 参考：`MAX_NUMBER_OF_ENABLED_STATIC_RULESETS` = **50**，且正文"only 50 of these rulesets can be enabled at a time"；MDN 同名属性页只写 "Its value is `10`"（未区分浏览器）。二者冲突 ⇒ 本次按 Chrome 官方参考取 **50**，Firefox 取 **10（待验证）**；对我们的用量（≤10 条）无实际影响。 |
| C4 | **"只拦一条精准 URL"（Q-D1）与 Firefox 授权模型叠加后风险放大** | Q-D1、§6-4 | Q-D1 把风险面收窄到 1 条 URL，这是**风险控制**；但 Firefox MV3 下 host 权限默认需要用户授予，若用户为省事直接给"全部站点"，Q-D1 的收窄在权限层面被抵消。建议在能力清单/详细设计里明确：**不要为了省事申请 `<all_urls>` 或 `*://*/*`**，用与 Q-D1 一致的精准 match pattern（`http://127.0.0.1:6800/*` 等）。 |
| C5 | **"多引擎、多途径" 与 Chromium MV3 无 blocking webRequest** | R7、R4.1"尽可能多途径" | Chromium 侧"网络层途径"只剩 DNR（拿不到响应体，且 redirect/modifyHeaders 需要 host 权限）；因此 Chromium 上的"多途径"实际收敛为"注入 + JS API 覆盖 + 少量 DNR（如附录 A 的 header 注入/强制下载）"，Firefox 上才多一条 blocking webRequest。**不是冲突，是能力上限**：建议在能力清单里按浏览器分列"途径集合"。 |
| C6 | **R5"内置 UI 不得走特殊通道"已被平台强制例外** | R5、Q-D1 | 扩展页注入不可能（H5）。R5 已允许"只换装载方式"，故**不构成冲突**；但需要补一条明确表述：内置 UI 的"同路径"= 同一份 forwarder 代码 + 同一拦截规则；差别仅在**由谁装载**（extension 注入 vs 页面内 `<script src>`）。MDN 提供了同构做法（§2.8(1)）。 |

---

## 7 未验证

> 每条都写明"查了什么、为什么定不了"。这些项必须在详细设计前用**实测**闭合，而不是继续查文档。

| ID | 未验证项 | 已查内容 | 需要什么才能定 |
|---|---|---|---|
| U1 | 权限被撤销后，**已注入**的转发器脚本是否继续运行？浏览器是否主动销毁/禁用已注入脚本？扩展是否需要重载？ | Chrome [runtime-host-permissions](https://developer.chrome.com/docs/extensions/mv2/runtime-host-permissions)（只讲"按站点门控注入"与"XHR 像没声明一样失败"）、[chrome.permissions](https://developer.chrome.com/docs/extensions/reference/api/permissions)、MDN [Content scripts](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Content_scripts)/[permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/permissions) 均无明文 | 三浏览器实测：注入 → 撤销 → 观察脚本是否继续拦截、`runtime.sendMessage` 是否仍可通、`permissions.onRemoved` 是否触发 |
| U2 | Chrome 的 `scripting.registerContentScripts()` 是否也需要 host 权限（还是只需 `scripting` + `matches`）？ | [Chrome Content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts) 只说程序化注入（`executeScript`）需要 host/activeTab；register API 的权限要求未在同一段说明；[scripting API 页面](https://developer.chrome.com/docs/extensions/reference/api/scripting) 未逐条核 | 查 scripting API 参考的 Permissions 段或实测 |
| U3 | Firefox 的静态规则集数量上限、静态规则总条数、禁用静态规则上限的**具体数字** | [MDN DNR](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest) 只给出属性存在性与"30000 是 Chrome 的值"；属性页多未给 Firefox 数字 | 查 Firefox 源码/BCD 或实测 |
| U4 | 页面 CSP 是否会**阻止注入动作本身**（例如 `world:"MAIN"` 的 `chrome.scripting.executeScript`），还是只约束注入代码后续的动态代码执行 | [Chrome Content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts) 只有 "When a content script is injected into the main world, the CSP of the page applies." | 归 fwd-inject 实测；本文件只声明"注入后适用页面 CSP" |
| U5 | Firefox 是否支持 offscreen document（无官方支持声明） | MDN `offscreen` 页面 404；`mdn/browser-compat-data/webextensions/api/offscreen.json` 404；[Chrome offscreen 文档](https://developer.chrome.com/docs/extensions/reference/api/offscreen) 仅标 Chrome 109+ | 查 Firefox bug 1573659 之外的官方 issue，或实测 `chrome.offscreen` 是否存在 |
| U6 | AriaNg 打包的第三方库是否全部兼容"无 eval/无内联/无远程"的扩展页 CSP | 已核对 [`src/index.html`](https://raw.githubusercontent.com/mayswind/AriaNg/master/src/index.html)（无内联脚本）与 [AngularJS 1.6.10 的 CSP 自动探测](https://code.angularjs.org/1.6.10/angular.js)；未逐库审计 | 把 AriaNg 打进扩展页跑一遍，看 CSP 违规日志 |
| U7 | 扩展页发起 `ws://127.0.0.1:6800`（AriaNg 的 WebSocket 通道）是否被混合内容/其它策略拦截 | [Mixed Content 规范](https://w3c.github.io/webappsec-mixed-content/) 的算法以"settings 是否禁止混合内容"为前提，但没有针对扩展 scheme 的实现说明；Chrome/Edge/Firefox 均未找到明文 | 实测三浏览器扩展页里的 `new WebSocket("ws://127.0.0.1:6800/jsonrpc")` |
| U8 | Edge MV3 的 `extension_pages` 最小 CSP 是否与 Chrome 完全一致 | [Edge CSP 文档](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/csp) 为 2022 年 MV2 口径；Edge "Migrate MV2→V3" 文档未提 CSP 差异 | 查 Edge 更新的 CSP 文档（未见）或实测 |
| U9 | `chrome.permissions.request()` 能否在 MV3 service worker 中调用（SW 没有页面手势上下文） | [chrome.permissions](https://developer.chrome.com/docs/extensions/reference/api/permissions) 只要求"within a user gesture"；未见 SW 专门说明 | 实测（并与 `addHostAccessRequest` 做取舍） |
| U10 | Safari 侧（非本题目标）的权限/CSP/存储差异 | 未查 | 若未来要覆盖 Safari，另开任务 |

---

## 8 证据清单

### 8.1 一手来源（URL 一览）

**Chrome / Chromium**
1. [chrome.permissions API](https://developer.chrome.com/docs/extensions/reference/api/permissions) — 可选权限、`request()` 用户手势、不可 optional 的权限表、`addHostAccessRequest`（Chrome 133+）、`onRemoved`
2. [Declare permissions](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions) — 五类权限键；host 权限用途；**"manifest 声明的 content script 无需 host 权限"例外**
3. [Content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts) — 静态/动态/程序化注入权限；isolated world CSP 串；MAIN world 适用页面 CSP
4. [Match patterns](https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns) — scheme 白名单（无 `chrome-extension`）
5. [declarativeNetRequest API](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest) — 两种 DNR 权限差异；全部配额数字；超限行为；正则 2KB；禁用静态规则 5000；SW 边界；`tabIds`/`initiatorDomains`/`topDomains`
6. [Replace blocking web request listeners](https://developer.chrome.com/docs/extensions/develop/migrate/blocking-web-requests) — 策略安装扩展仍可用 `webRequestBlocking`；DNR redirect 需 `declarativeNetRequestWithHostAccess` + host 权限
7. [webRequest API](https://developer.chrome.com/docs/extensions/reference/api/webRequest) — `webRequestBlocking` 在 MV3 仅策略安装；`initiator`/`tabId`/`documentId` 字段；"请求 URL + initiator 双 host 权限"；可见 scheme 白名单
8. [Manifest - Content Security Policy](https://developer.chrome.com/docs/extensions/reference/manifest/content-security-policy) — 默认/最小 CSP；不可放宽；sandbox 策略
9. [User controls for host permissions（transition guide）](https://developer.chrome.com/docs/extensions/mv2/runtime-host-permissions) — 三档站点访问；按站点注入门控；`document_idle` 立即注入、其它需刷新；后台 XHR "像没声明一样失败"；`permissions.request()` 需手势
10. [Manifest V2 support timeline](https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline) — Chrome 138（2025-07-24）起 MV2 全面禁用；2026-08-31 CWS 下架
11. [Skip review for eligible changes](https://developer.chrome.com/docs/webstore/expedited-review) — DNR 静态规则改动的免审条件（与配额是否付费相关）
12. [offscreen API](https://developer.chrome.com/docs/extensions/reference/api/offscreen) — Chrome 109+；只有 `runtime`；单实例
13. [Chromium：Prefer Secure Origins For Powerful New Features](https://www.chromium.org/Home/chromium-security/prefer-secure-origins-for-powerful-new-features/) — secure origins 模式列表（loopback、chrome-extension）
14. [Chromium：Changes to Cross-Origin Requests in Chrome Extension Content Scripts](https://www.chromium.org/Home/chromium-security/extension-content-script-fetches/) — MV3 content script CORS 变化（由 MDN 引用）

**Edge（Microsoft）**
15. [Timeline for migrating to Manifest V3](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/manifest-v3) — MV2 弃用时间线（2026-08 告警、2027 初企业弃用）
16. [Migrate an extension from Manifest V2 to V3](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/migrate-your-extension-from-manifest-v2-to-v3) — DNR 取代 webRequest、保留观测能力、企业策略保留 blocking
17. [Using CSP](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/csp) — **2022 年旧文档**，content script/页面 CSP/`<script>` 注入语义（⚠️ 与 MV3 冲突，见 §6-C2）

**Firefox / Mozilla**
18. [Manifest v3 in Firefox: Recap & Next Steps](https://blog.mozilla.org/addons/2022/05/18/manifest-v3-in-firefox-recap-next-steps/) — 明确保留 blocking WebRequest；site access 可选化；event pages
19. [MDN manifest.json/host_permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/host_permissions) — Firefox 126/127 安装提示差异；"most browsers treat host_permissions as optional"
20. [MDN manifest.json/permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/permissions) — host/API/activeTab 三类；`webRequestBlocking`；MV2→MV3 键位
21. [MDN manifest.json/optional_permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/optional_permissions) — 可选项列表（含 DNR 类）；静默授予项；`optional_host_permissions` 自 FF128
22. [MDN manifest.json/optional_host_permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/optional_host_permissions) — 运行时申请 host；用户在附加组件管理器管理
23. [MDN manifest.json/content_scripts](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/content_scripts) — 键位与 `world`
24. [MDN Content scripts](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Content_scripts) — **"无 host 权限不执行"**；不能注入扩展页；MV3 下 host 权限不进 content script；`content.XHR` 在 MV3 不存在
25. [MDN permissions API](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/permissions) / [permissions.request](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/permissions/request) — user action handler 约束；onAdded/onRemoved
26. [MDN declarativeNetRequest](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest) — 权限要求（redirect/modifyHeaders 需 host + initiator host）；Firefox 匹配优先级；limits 结构
27. MDN DNR 属性页：[MAX_NUMBER_OF_DYNAMIC_RULES](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest/MAX_NUMBER_OF_DYNAMIC_RULES)（FF 5000 / Chrome 30000）、[MAX_NUMBER_OF_SESSION_RULES](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest/MAX_NUMBER_OF_SESSION_RULES)（均 5000）、[MAX_NUMBER_OF_ENABLED_STATIC_RULESETS](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest/MAX_NUMBER_OF_ENABLED_STATIC_RULESETS)（"value is 10"，与 Chrome 50 冲突）、[MAX_NUMBER_OF_REGEX_RULES](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest/MAX_NUMBER_OF_REGEX_RULES)、[GUARANTEED_MINIMUM_STATIC_RULES](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/declarativeNetRequest/GUARANTEED_MINIMUM_STATIC_RULES)
28. [MDN manifest.json/background](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/background) — Firefox 无 `service_worker`；Chrome 121 起忽略 MV3 的 `scripts`/`page`；跨浏览器双声明
29. [MDN runtime.MessageSender](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/runtime/MessageSender) — 来源识别字段
30. [MDN Chrome incompatibilities](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Chrome_incompatibilities) — content script 生命周期、扩展 URL UUID、`globalThis`/Xray、WebRequest 差异、Chrome 148/152 命名空间
31. [MDN Secure contexts](https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Secure_Contexts) — potentially trustworthy origins（loopback/localhost/认证 scheme）
32. [MDN `showSaveFilePicker()`](https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker) + [BCD `api/Window.json`](https://raw.githubusercontent.com/mdn/browser-compat-data/main/api/Window.json) — Firefox false

**规范 / 平台**
33. [W3C Mixed Content（ED 2023-02-23）](https://w3c.github.io/webappsec-mixed-content/) — 定义、upgradeable/blockable、§4.4 判定算法、`block-all-mixed-content` 废弃
34. [WHATWG Fetch Standard / Main fetch](https://fetch.spec.whatwg.org/#main-fetch) — 混合内容/CSP/坏端口的检查点（"then return a network error"）
35. [W3C Secure Contexts](https://w3c.github.io/webappsec-secure-contexts/) — 允许 UA 把 `chrome-extension:` 之类 scheme 视为可信

**项目侧源码（用于 UI 特例）**
36. [AriaNg `src/index.html`](https://raw.githubusercontent.com/mayswind/AriaNg/master/src/index.html) — 无内联脚本；引入 `angular-csp.css`
37. [AngularJS 1.6.10（code.angularjs.org）](https://code.angularjs.org/1.6.10/angular.js) — `csp()` 通过 `new Function('')` 探测 eval，并传给 `$parse`

### 8.2 证据强度标注

| 等级 | 含义 | 本文示例 |
|---|---|---|
| A | 官方文档明文 + 逐字摘录 | H1/H2/H3/H4/H5/H6/H9/H10/H11/H12/H14/H15 |
| B | 官方规范算法 + 逐字摘录，需一步推理才能落到本方案 | H13（Fetch Main fetch 的检查点）、F8 |
| C | 官方源码/BCD 数据 | AngularJS CSP 探测；`showSaveFilePicker` 的 Firefox=false |
| D | **推论**（本文标注；需实测） | §2.1(7) "已注入脚本仍在运行"、U1–U10 涉及的行为 |

> 后续设计的硬性要求：任何依赖 D 级的结论，必须在详细设计阶段转成可执行的实测用例，或降级为"仅 Chrome/Edge 承诺"。
