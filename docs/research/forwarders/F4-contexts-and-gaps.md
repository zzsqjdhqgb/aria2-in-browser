# F4 — 上下文与来源覆盖矩阵 + 拦截盲区清单

## 0 元信息

| 项 | 值 |
|---|---|
| 文档 | F4 — 上下文与来源覆盖矩阵 + 拦截盲区清单 |
| 团队任务 | `t9 [f4]`（aria2-in-browser-boundary / 浏览器技术边界测绘） |
| 作者 | fwd-contexts |
| 用途 | ① 给后续「能力清单」「详细设计」提供"哪些页面/上下文能被注入、哪些不能"的输入；② 附录 A 是**可直接对用户公示**的拦截盲区清单（依据 concept-design §5.1 Q-D2） |
| 核对日期 | **2026-10-06**（UTC） |
| 核对基准浏览器 | **Chrome 154.0.8037.97**（stable，来源：Chrome 版本历史官方 API）；**Microsoft Edge 154.0.4258.62**（Stable，2026-10-05 发布，来源：Edge Updates 官方 API） |
| 源码核对基准 | Chromium `main` 分支，commit **`a4f419a126457afbcb38999b80dbffd5a29ebadf`**（2026-10-06 09:55 UTC）。§8 中 Chromium 源码链接均指向该 commit，行号随上游变动可能漂移 |
| 结论体裁 | 文献 + 官方源码核对。**本文件不是实验报告**：未在真实浏览器上逐条复现；标注为「未验证」的条目需要实测（见 §7.2） |
| 依据等级 | 【官方文档】= developer.chrome.com / learn.microsoft.com 等官方文档原文；【源码】= Chromium/Blink 源码（带行号）；【规范】= WHATWG/W3C/MDN；【社区经验，未验证】；【未验证】= 查不到权威依据 |
| 在范围内 | 只回答"某个页面/上下文能不能被注入、能不能在 JS API 层拦截请求" |
| 不在范围内 | 转发器用什么技术包 `fetch`/XHR/WebSocket（F1/F2/F3）；DNR 规则细节；Mock 层协议还原；引擎能力实现 |

**术语**

- **注入** = 扩展把 JS 放进某个执行上下文（内容脚本、`chrome.scripting.executeScript`）。
- **JS API 层拦截** = 在请求**发出之前**就地改写/短路 `fetch` / `XMLHttpRequest` / `WebSocket`（concept-design R9）。**要拦到网页自己的请求，注入必须落在网页自己的 JS 上下文（MAIN world）**，理由见 §2.1。
- **本扩展** = aria2-in-browser。文中"host 权限"指 `host_permissions` / `content_scripts.matches` / `activeTab` 三者之一提供的页面访问权。

---

## 1 一句话结论

1. **"能不能拦"不是一个布尔值**，而是 `页面 scheme × 扩展权限 × 帧种类 × 执行上下文（主文档 / 子帧 / worker）` 的乘积。本文件给出 34 条上下文的逐条判定（§4）。
2. **绝大多数真实网页场景可拦**：普通 `http(s)` 页面 + 有对应 host 权限 + 在 `document_start` 注入 MAIN world，即可在页面自身脚本运行前替换 `fetch`/XHR/WebSocket。
3. **存在一组"技术上做不到"的上下文**（不是体验问题，而是浏览器没有这个能力或明确禁止）：`chrome://` / `edge://` 内部页面、其它扩展的页面、Chrome 应用商店页面、内置 PDF 阅读器、`view-source:` 页面，以及**网页创建的 Worker / SharedWorker / Service Worker 内部**——没有任何官方 API 能把脚本注入 worker 全局作用域（§5.2）。
4. **存在一组"能拦，但代价高 / 体验差 / 要用户配合"的情形**：无 host 权限的站点、跨域 iframe、`about:blank`/`srcdoc`/`data:`/`blob:` 帧、`file://` 页面（需用户手动开关）、无痕窗口（需用户手动开关）、安装或授权之后未刷新的页面、CSP 严格的页面（§5.3）。
5. **"覆盖尽可能多的来源"（R4.1）的代价是广域 host 权限**：要覆盖任意站点与任意跨域 iframe，实际上需要 `<all_urls>` 级别权限，官方文档明确提示"影响所有主机"会**拉长 Chrome 应用商店审核时长**，并触发安装时的权限警告。这是需要用户裁定的决策点（§6.4/§6.5）。
6. **面向用户的盲区清单见附录 A**（条目化、每条写"什么情况下拦不到 + 后果是什么"），可直接摘取公示。

---

## 2 机制

### 2.1 要拦网页自己的请求，注入必须落在 MAIN world

- 内容脚本默认运行在 **isolated world**：官方原文 —— "Not only does each extension run in its own isolated world, but content scripts and the web page do too. This means that none of these (web page, content scripts, and any running extensions) can access the context and variables of the others."【官方文档 E1】⇒ **isolated world 里拿不到、也改不了页面自己的 `fetch`/`XMLHttpRequest`/`WebSocket`**。
- 因此转发器必须注入 **`world: "MAIN"`**（与页面共享 JS 环境）。三条装载路径：
  | 装载路径 | 官方要点 | 关键版本/限制 |
  |---|---|---|
  | manifest `content_scripts`（静态声明） | 在文档生命周期的每个阶段，**静态声明的内容脚本最先注入**；`run_at: "document_start"` = "Scripts are injected after any files from `css`, but before any other DOM is constructed or any other script is run."【E1】 | `world` 字段只对 MV3 生效（MV2 会加安装警告）【源码 E10】 |
  | `chrome.scripting.registerContentScripts`（动态） | 需要在 manifest 里声明 `"scripting"` 权限 **加上注入目标页面的 host 权限**；支持 `world`（官方标注 Chrome 102+）【E2】 | 动态注册可 `persistAcrossSessions` |
  | `chrome.scripting.executeScript`（即时） | 官方标注 `world` Chrome 95+；`target` 只有 `tabId` / `frameIds` / `documentIds` / `allFrames`【E2】 | 目标维度**只有 frame/document**，没有 worker |

  （MAIN world 注入网页这件事，官方 what's-new 记为 "Chrome 95: inject scripts directly into pages"【E3】）

### 2.2 决定"能否注入"的 4 道关卡

1. **能不能匹配（scheme 白名单）**
   - 官方 match patterns 文档：scheme "Must be one of the following …: `http`, `https`, a wildcard `*` which matches only `http` or `https`, `file`. For information on injecting content scripts into unsupported schemes, such as `about:` and `data:`, see Injecting in related frames."【E4】
   - 源码把这张白名单写死：内容脚本 `matches` 的合法 scheme = `chrome-ui | http | https | file | ftp | uuid-in-package`（**不含 `chrome-extension`、`data`、`blob`、`filesystem`、`ws`、`view-source`**）；且默认再扣掉 `chrome-ui`【源码 E8】。
2. **有没有权限**
   - 声明式内容脚本靠 `content_scripts.matches` 获得"可注入的主机"——官方原文：`"content_scripts.matches"` "Contains one or more match patterns that allows content scripts to inject into one or more hosts. Changes may trigger a warning."【E30】；`chrome.scripting` 系列靠 `host_permissions` 或 `activeTab`；`activeTab` 只在用户主动触发时临时授予，并且 "Access is not granted to restricted pages, such as `chrome://` pages."，页面导航/关闭即失效【E5】。
   - 另有"用户级站点屏蔽"路径：命中时报错字符串 `"Blocked"`【源码 E11】。注意该路径受特性开关 `kExtensionsMenuAccessControl` 控制，而在核对基准 commit 上它**在非 Android 平台默认关闭**（`BASE_FEATURE(kExtensionsMenuAccessControl, IS_ANDROID ? ENABLED : DISABLED_BY_DEFAULT)`）【源码 E31】⇒ 桌面稳定版上这条不一定生效，列为未验证。
3. **是不是"受限 URL"**：`PermissionsData::CanRunOnPage()` 会先调用 `IsRestrictedUrl()`，命中即 `kDenied`【源码 E11】。受限判定含：scheme 不在扩展合法 scheme 集合内（`about:blank` / `about:srcdoc` 例外）、`chrome://`（报 `"Cannot access a chrome:// URL"`）、**其它扩展的页面**（报 `"Cannot access a chrome-extension:// URL of different extension"`）【源码 E11】。
4. **客户端级否决**：Chrome 对 Chrome 应用商店域名单独判不可脚本化（`"The extensions gallery cannot be scripted."`）【源码 E12】；**PDF 内容帧**被硬性判 `kDenied`【源码 E13】。

### 2.3 特殊帧的 origin 回退（`about:` / `data:` / `blob:` / `filesystem:`）

`about:blank`、`srcdoc`、`data:`、`blob:`、`filesystem:` 这些 URL 无法被 match pattern 直接匹配，官方给出的机制是 **origin 回退**：

- `match_about_blank`：只覆盖"父/打开者 URL 命中 `matches`"的 `about:blank` 帧，默认 `false`【E6】。
- `match_origin_as_fallback`：**按创建该帧的 initiator 的 origin 判定**，覆盖 `about:`、`data:`、`blob:`、`filesystem:`；因为比的是 origin，**要求 `matches` 里的路径必须是 `*`**；两者同时出现时本项优先【E1】【E6】。
- 源码里对应的白名单正是 `about / blob / data / filesystem` 四种 scheme；且当帧是"不透明 origin"时用 **precursor origin**，若扩展访问不到该 precursor 则回退失败、不注入【源码 E9】。
- 版本：官方 what's-new 记为 "Chrome 99: `match_origin_as_fallback` in Canary"【E14】；manifest 参考页未标最低版本（⇒ 见 §7）。

### 2.4 时序：注入之前发生的请求拦不到

- `document_start` 静态脚本的语义是"在其它任何脚本运行之前"【E1】，**所以它覆盖的是"页面加载开始时的脚本"**；
- 页面在扩展生效之前（扩展刚安装/刚被授权、页面未刷新）已经运行的脚本，其后续请求也不会被拦（脚本里保存的原始 `fetch` 引用不会被替换）——**这条的浏览器行为没有官方明文，见 §7**；
- 只有"在页面里注入的转发器先跑过"之后发出的请求才会被拦。

### 2.5 为什么不能用 DNR 补 Worker 盲区

`declarativeNetRequest` 的动作类型只有 `block` / `redirect` / `modifyHeaders` / `allow` / `allowAllRequests` / `upgradeScheme`【E7】——**没有任何"合成任意响应体"的动作**。官方还说明它与 Service Worker 的关系："A declarativeNetRequest only applies to requests that reach the network stack. This includes responses from the HTTP cache, but may not include responses that go through a service worker's `onfetch` handler. declarativeNetRequest won't affect responses generated by the service worker or retrieved from `CacheStorage`, but it will affect calls to `fetch()` made in a service worker."【E7】

⇒ 结论：DNR 能在网络层看到/改道请求（**包括 worker、SW 里发出的 `fetch()`**），但**既不能合成响应体**，也管不到 SW `onfetch` 自己生成的响应。因此 **Worker / SW 盲区不能被 DNR 消除**。

---

## 3 硬约束（编号 C1–C15）

| ID | 约束 | 依据 |
|---|---|---|
| **C1** | 内容脚本 `matches` 的 scheme 只能是 `http` / `https` / `*`(仅 http、https) / `file`（源码再放开 `ftp`、`uuid-in-package`）；`chrome-extension`、`data`、`blob`、`filesystem`、`ws`、`view-source` 都**不能写进 `matches`** | 【E4】【源码 E8】 |
| **C2** | `chrome://` 默认不是合法 scheme（只有 `--extensions-on-chrome-urls` 命令行开关或组件扩展例外）；`edge://` 同理不在 Edge 允许的 scheme 列表内 | 【源码 E8】【E15】 |
| **C3** | 没有 host 权限 ⇒ 内容脚本不注入、`executeScript` 报错（`"Cannot access contents of the page. Extension manifest must request permission to access the respective host."`） | 【源码 E11】【E2】【E30】 |
| **C4** | `activeTab` 只能"用户主动触发 → 当前标签页 → 导航即失效"，且**不给受限页面**；不能作为"每个标签页都拦"的机制 | 【E5】 |
| **C5** | 其它扩展的页面：普通扩展**永远**不能注入（源码：`Only allowlisted extensions may run scripts on another extension's page.`，另有 `--extensions-on-extension-urls` 开关例外） | 【源码 E13】【源码 E11】 |
| **C6** | Chrome 应用商店域名被单独判为不可脚本化 | 【源码 E12】 |
| **C7** | **PDF 内容帧被硬性拒绝**：父帧是 PDF 扩展 origin（`mhjfbmdgcfjbbpaeojofohoefgiehjai`）时直接返回 `kDenied` | 【源码 E13】【源码 E16】 |
| **C8** | 每个子帧**独立**判定：`allFrames: true` 时 "Each frame is checked independently for URL requirements; it will not inject into child frames if the URL requirements are not met." ⇒ 跨域 iframe 需要**该帧自身 origin** 的匹配/权限 | 【E2】 |
| **C9** | `file://` 页面：需要 `"file:///"` 匹配模式，并且**用户手动授权**（`"Allow access to File URLs"`，`chrome://extensions` 页面上每扩展一个开关） | 【E4】【E17】【E15】 |
| **C10** | `about:`/`data:`/`blob:`/`filesystem:` 帧：必须开 `match_origin_as_fallback`（或 `match_about_blank`），且**模式路径必须为 `*`**；扩展访问不到 precursor origin 时不注入 | 【E1】【E6】【源码 E9】 |
| **C11** | 注入到 MAIN world 的脚本**受页面 CSP 约束**：官方原文 "When a content script is injected into the main world, the CSP of the page applies." | 【E1】 |
| **C12** | 无法注入到网页的 worker 全局作用域：`chrome.scripting` 的 `target` 只有 frame/document 维度；内容脚本的匹配与注入以 frame 为单位；源码里"worker 线程上的 ScriptContext 集合"只服务于**扩展自身**的 Service Worker | 【E2】【源码 E18】【源码 E19】 |
| **C13** | 无法用"包装脚本"替换 Service Worker 的脚本 URL：SW 脚本的协议必须属于"允许 Service Worker"的**注册集合**，该集合的默认值只有 `{"http","https"}`（扩展另加注册自己的 scheme），Blink 源码的失败文案为 `"Failed to register a ServiceWorker: The URL protocol of the script ('…') is not supported."`（把脚本 URL 填进引号内）；且脚本 URL 必须与 referrer 同源 | 【源码 E20】【规范 E21】 |
| **C14** | 只有落在"允许 Service Worker"注册集合内的 scheme 才能跑 SW；DNR 无法合成响应体 ⇒ JS 层拦截无法用 DNR 替代 | 【源码 E20】【E7】 |
| **C15** | 无痕窗口默认拦不到，需用户在扩展详情页开启 `"Allowed in Incognito"` | 【E17】【源码 E11】 |

> 说明：C1–C11 是"逐页面/逐帧"的门槛；C12–C14 是"执行上下文类型"的门槛（worker / Service Worker）；C15 是用户级开关。**它们不可互相补偿**：页面能拦 ≠ 页面里 worker 的请求能拦。

---

## 4 能力映射（覆盖矩阵）

判定列：**能** / **不能** / **有条件** / **非目标** / **未验证**。
"代价"列区分"技术做不到"与"能做但代价高/体验差"。

### 4.1 主矩阵

| # | 上下文 / 来源 | 判定 | 技术原因 | 代价 / 备注 |
|---|---|---|---|---|
| 1 | 普通 `http(s)` 页面，**有**匹配 host 权限 | **能** | 静态内容脚本可在 `document_start` 注入 MAIN world；R9 要求的 JS API 层包裹在页面自身脚本前完成 | 基本代价：权限（见 #2/#5） |
| 2 | 普通 `http(s)` 页面，**无**权限 | **不能** | 内容脚本不注入；`executeScript` 直接返回权限错误【C3】 | 技术不可行；补救手段是用户授权（#3/#4） |
| 3 | 用户只授权了部分站点（withheld）| **不能**（该站点） | 权限是逐站点的：未授予的站点不会注入【C3】。额外的"用户级站点屏蔽"路径（错误 `"Blocked"`）受默认关闭的特性开关 `kExtensionsMenuAccessControl` 控制【源码 E31】 | 技术不可行（由用户授权状态决定） |
| 4 | 用 `activeTab` 临时授权（用户点击扩展图标） | **有条件** | 只对当前标签页、用户手势后、导航即失效；受限页面不授予【C4】 | **代价高/体验差**：需要每次用户手势，不能作为"常驻拦截" |
| 5 | 同源 iframe | **能** | 与主文档同源 ⇒ 同一套匹配/权限即可 | — |
| 6 | 跨域 iframe，**扩展有该帧 origin 的权限** | **能** | `all_frames: true` + 该帧 URL 命中匹配模式；每帧独立判定【C8】 | 需要更大范围 host 权限 |
| 7 | 跨域 iframe，**无该帧 origin 权限** | **不能** | 该帧独立判定为不匹配【C8】 | 技术不可行（除非扩大权限） |
| 8 | `about:blank` / `srcdoc` 帧（有 initiator） | **有条件** | 需 `match_about_blank` 或 `match_origin_as_fallback`；MOAF 要求路径为 `*`【C10】 | 配置代价（模式写法受限） |
| 9 | `data:` 文档（作为 iframe） | **有条件** | 同上，`data:` 在 origin 回退白名单内；须能访问 precursor origin | 配置代价；顶层 `data:` 已被浏览器禁止（#10） |
| 10 | `data:` 作为**顶层**页面 | **不能** | Chrome 已封禁"内容发起的顶层 `data:` 导航"：`<a>`、`window.open`、`window.location` 都被拦【E22】 | 不是"拦不到"，而是**这种页面不再存在** |
| 11 | `blob:` / `filesystem:` 帧 | **有条件** | 在 origin 回退白名单内【C10】 | 配置代价 |
| 12 | 顶层 `blob:` 文档 | **未验证** | MOAF 的官方描述针对"帧（frames）"，顶层 blob 文档如何判定未找到明文 | 见 §7 |
| 13 | 带 `sandbox` 属性的 iframe | **未验证** | 未找到官方条文说明 sandbox 对内容脚本注入的影响；源码注释把"沙箱帧"视为真正的 origin 边界（`unlike e.g. a sandboxed frame`），但未直接回答注入与否 | 见 §7；建议实测 |
| 14 | 页面创建的 **Dedicated Worker**（`new Worker(...)`） | **不能**（JS 层） | 没有任何官方 API 能注入 worker 全局作用域【C12】 | **技术不可行**；包装法（改写 `Worker` 构造器 + `blob:` 包装脚本）为无官方支持的绕路，见 §5.3-① |
| 15 | 页面创建的 **SharedWorker** | **不能**（JS 层） | 同 #14 | 同上 |
| 16 | 页面注册的 **Service Worker**（含 SW 自身触发的请求） | **不能**（JS 层） | 同 #14；且 SW 脚本无法用 `blob:` 包装替换（协议不允许）【C13】 | **技术不可行** |
| 17 | **扩展自身**页面（`chrome-extension://<自己>/…`，即内置 AriaNg UI） | **不能靠内容脚本注入；改用页面自身装载** | `chrome-extension` 不在内容脚本 scheme 白名单【C1】；host 权限的合法 scheme 集合同样不含 `chrome-extension`【源码 E23】 | **代价低**：该页面由扩展打包，直接 `<script>` 引入同一份转发器即可（concept-design R5 允许的"最小修改/另一种装载方式"） |
| 18 | **其它扩展**的页面 | **不能** | 普通扩展永远不能注入（源码硬拒 + `"Cannot access a chrome-extension:// URL of different extension"`）【C5】 | **技术不可行** |
| 19 | `chrome://` 页面（设置、扩展管理、新标签页…） | **不能** | scheme 不在白名单；受限判定报 `"Cannot access a chrome:// URL"`【C2】 | **技术不可行** |
| 20 | `edge://` 页面 | **不能** | Edge 的匹配模式 scheme 白名单同样只有 `http/https/file/ftp`【E15】；实现与 Chromium 共用 | **技术不可行**（Edge 官方**明文**未找到，见 §7） |
| 21 | Chrome 应用商店页面（`chromewebstore.google.com`、`chrome.google.com/webstore`） | **不能** | 商店域名被单独判为不可脚本化 `"The extensions gallery cannot be scripted."`【C6】 | **技术不可行** |
| 22 | 内置 PDF 阅读器里的 PDF（顶层打开 PDF 文档） | **不能** | PDF 内容帧被硬性 `kDenied`（父帧 = PDF 扩展 origin）【C7】；PDF 文档本身也不是网页文档 | **技术不可行** |
| 23 | `view-source:` 页面 | **不能** | `view-source` 不在扩展合法 scheme 集合内 ⇒ 受限 URL；也不能写进 `matches`【C1】 | **技术不可行** |
| 24 | `file://` 页面，用户**已**开启"允许访问文件网址" | **能** | `"file:///"` 匹配模式 + 用户手动授权【C9】 | 需要用户一次性操作 |
| 25 | `file://` 页面，用户**未**开启 | **不能** | 同上；`fileAccess` 被收回后 `file` scheme 会从合法 scheme 里剔除 | **技术不可行（在用户当前设置下）**，属"可解除" |
| 26 | 无痕窗口，用户**已**勾选"在无痕模式下启用" | **能** | 与普通窗口相同机制 | 需要用户一次性操作；官方文档只说明该设置控制"扩展对无痕模式的访问"，未单独描述无痕下的注入行为（见 §7 U15） |
| 27 | 无痕窗口，用户**未**勾选 | **不能** | 扩展在无痕下默认不运行【C15】 | **技术不可行（当前设置下）**，属"可解除" |
| 28 | 扩展安装 / 授权**之后未刷新**的旧页面 | **不能** | 内容脚本在文档加载时注入；已加载文档不会追溯注入 | 属"可解除"（刷新即可）；具体浏览器行为**未验证**，见 §7 |
| 29 | 页面在转发器注入**之前**已发出的请求 | **不能** | `document_start` 也只能"最早"，不能追回已经发出的请求【§2.4】 | 技术不可行（时序） |
| 30 | 页面 CSP 严格（如 `worker-src`/`connect-src` 收窄） | **有条件** | MAIN world 注入受页面 CSP 约束【C11】；CSP 的 worker 指令还会影响"包装 worker"这类绕路（见 §5.3-①） | 取决于目标站点，需要实测 |
| 31 | 浏览器地址栏直接访问 RPC 地址、`curl`、浏览器外程序 | **非目标** | 扩展无法监听 TCP 端口；能服务的只有浏览器内 JS 客户端（concept-design R8） | 与盲区区分：**这不是漏洞，是产品边界** |
| 32 | 非 JS API 的网络途径：`<a href>` 导航、表单提交、`<img>`/`<script>`/`<link>` 资源加载 | **非目标**（R9 明示拦截发生在 JS API 层） | 这些请求不经过被包裹的 JS API | 若需要，唯一手段是 DNR（网络层），但 DNR 不能合成响应体【§2.5】 |
| 33 | DevTools 页面（`devtools://`） | **不能** | scheme 不在白名单；DevTools 扩展是另一套机制 | **技术不可行**（对本案无实际影响） |
| 34 | 页面从**不被注入的同源文档**取原生接口（如 `iframe.contentWindow.fetch`、`window.open('about:blank')` 后取 `fetch`） | **未验证** | 原理层面：包裹只作用于"已被注入的 JS 全局"，JS 里**已经取到的引用**不会被后续改写影响；是否真能构成绕过取决于注入时序（`about:blank` 帧何时注入）——未找到官方说明 | 属"刻意绕过"场景；见 §7 U14 |

### 4.2 判定统计（用于公示口径）

- **能**：#1、#5、#6、#24、#26（5 条，均需权限/用户设置满足）
- **有条件**：#4、#8、#9、#11、#30（5 条：配置代价或页面条件）
- **不能**：#2、#3、#7、#10、#14、#15、#16、#18、#19、#20、#21、#22、#23、#25、#27、#28、#29、#33（18 条，其中 #25/#27/#28 属"可解除"）
- **未验证**：#12、#13、#34（3 条）
- **非目标**：#31、#32（2 条）
- **特例**：#17（自身页面：不能注入，但可用页面自身装载等价达成）

> 口径提醒：**"不能"里最需要公示的是 #14/#15/#16（worker 类）、#18~#23（受限页面类）**，因为它们无法通过"多给权限"或"用户设置"解除。反过来 #25/#27/#28 只是"用户还没做那个设置/还没刷新"，文案上不应与前者混为一谈。

---

## 5 失败模式与盲区

### 5.1 分类原则（严格区分"技术做不到"与"能但代价高"）

| 类别 | 定义 | 能否解除 | 影响产品口径 |
|---|---|---|---|
| **A. 技术上做不到** | 浏览器没有该能力，或明确禁止 | 不能（除非浏览器改） | 必须在盲区清单里如实公示（Q-D2） |
| **B. 能但代价高 / 体验差** | 机制存在，但需要用户操作、要大权限、要重载、会给页面留下可见副作用 | 能（改设置/加权限/刷新） | 需要产品裁定是否做、怎么做；文案写成"需要你配合" |
| **C. 未验证** | 查不到权威依据 | — | 按 Q-D2 精神：**不得作为"能拦"宣传**，进入 §7 待实测 |

### 5.2 A 类：技术上做不到（清单）

| 项 | 上下文 | 后果 |
|---|---|---|
| A1 | `chrome://` / `edge://` 页面 | 页面内请求不会被拦截；不过这些页面本来不会调用 aria2 RPC |
| A2 | 其它扩展的页面 | 同上 |
| A3 | Chrome 应用商店页面 | 同上 |
| A4 | 内置 PDF 阅读器 / PDF 文档 | PDF 里没有网页 JS 可拦；PDF 阅读器页面本身也注入不了 |
| A5 | `view-source:` 页面 | 同上 |
| A6 | 网页的 **Dedicated Worker** 内的 `fetch`/XHR/WebSocket | 这些请求不会被拦，会真的发到网络上（目标不可达则失败）；**这是 Q-D2 中"技术上做不到就不拦"的情形** |
| A7 | 网页的 **SharedWorker** | 同上 |
| A8 | 网页的 **Service Worker**（页面注册的），以及 SW 被事件唤醒后自己发起的请求 | 同上 |
| A9 | 顶层 `data:` 页面 | 浏览器已禁止这种顶层页面存在 |
| A10 | 注入之前已经发出的请求（时序） | 拦不到（`document_start` 已把窗口压到最小） |
| A11 | 地址栏 / `curl` / 浏览器外程序 / 非 JS 网络途径 | **非目标**（R8/R9），不计入盲区清单 |

### 5.3 B 类：能拦但有代价

① **Worker 的"包装脚本"绕路（把 #14/#15 从"不做"变成"可能可做"，但代价高）**

- 思路：在 MAIN world 改写 `window.Worker` / `SharedWorker` 构造器，用 `blob:` 包装脚本 + `importScripts(原脚本)`，把 shim 带进 worker。
- 已知的**有依据**的约束：
  - `importScripts()` 在 module worker 里直接 `throw a TypeError`（规范）【规范 E24】⇒ module worker 需要另一套（动态 `import()`，跨源还需 CORS）。
  - 页面 CSP 约束 worker 脚本来源：`worker-src` 缺失时依次回退 `child-src` → `script-src` → `default-src`【规范 E25】；且 MAIN world 注入受页面 CSP 约束【C11】。若站点禁止 `blob:` worker，绕路直接失败。
  - SW 不能用这种方式（协议不允许，见 C13）。
- **结论：属于"未验证 + 代价高"**。对页面的副作用（`Worker` 不再是原生的、`instanceof`/`toString` 变化、构造器可见）会带来兼容风险；**没有官方文档支持**，不应写进公示的"能力"里。若要尝试，必须先做 §7.2 的实测。

② **跨域 iframe / 任意站点覆盖**：需要 `<all_urls>` 级别权限（以及 iframe 自身 origin 的匹配），触发安装警告；官方明确 `<all_urls>` "affects all hosts"，Chrome 商店审核"may take longer"【E4】。

③ **`about:blank`/`srcdoc`/`data:`/`blob:` 帧**：需要 `match_origin_as_fallback`，而它要求 `matches` 路径为 `*`【E1】⇒ 与"只拦一条精准 URL"（Q-D1）的阶段性约束相互影响。

④ **`file://` / 无痕**：纯用户操作成本（各一个开关）【E17】。

⑤ **安装/授权后未刷新的页面**：需要提示用户"刷新页面"。（具体行为未验证，见 §7）

### 5.4 运行期表现：注入失败大多"静默"

- 声明式内容脚本注入失败时，官方文档**没有**描述任何用户可见反馈；实际表现是"页面照常、只是没有拦截器"（用户感知为"这个地址没被拦"）——**此条为社区经验，未验证（U13）**。
- `chrome.scripting.executeScript` 会把失败以错误形式返回（错误文案如 `"Cannot access contents of the page…"` / `"Cannot access a chrome:// URL"` / `"The extensions gallery cannot be scripted."`）【源码 E11/E12】——如果设计里用"按需注入"路径，就有可靠的失败信号；如果只靠静态声明，需要自己探测。
- **对产品的直接含义**：需要一个"本页是否已挂上转发器"的自检 + 对用户的解释口径（Q-D6 的 Mock 控制台可承担）。

### 5.5 与"服务对象边界"的关系（避免把非目标写成盲区）

concept-design R8/R9 已把"服务对象 = 浏览器内 JS 客户端、拦截层次 = JS API 层"定死。因此地址栏访问、`curl`、`<a>`/表单导航、资源加载**不是盲区，而是设计边界**。公示时必须分开陈述，否则会被误读为"扩展有缺陷"。

> **面向用户的可公示版本 → 见文末「附录 A — 拦截盲区清单」**（A.1 硬性拦不到 / A.2 需用户配合 / A.3 非目标）。

---

## 6 与现有裁定的冲突 / 需要用户裁定的点

| # | 关联裁定 | 冲突或影响 | 建议 |
|---|---|---|---|
| 6.1 | **R4.1**（尽可能多地拦截各种来源） | "尽可能"没有边界，而浏览器给的是硬边界（§4）。若不做区分，会把 A 类（技术不可行）与 B 类（需配合）混为一谈，损害 R2/R10 的"能力诚实" | 用 §4 矩阵作为"尽可能"的正式落地：A 类公示、B 类做成设置/引导。**不冲突，但需要把口径写死** |
| 6.2 | **R5**（内置 AriaNg UI 不得走特殊通道）+ 其唯一例外 | 事实核对：扩展自身页面**不能**靠内容脚本注入（C1 + host 权限 scheme 不含 `chrome-extension`）。R5 的"例外条款"被真实触发 | 采用 R5 允许的最小修改：**该页面自己 `<script>` 引入同一份转发器脚本**。请求仍走同一条路径、同一个 Mock 层 ⇒ 不是"特殊接入方式" |
| 6.3 | **Q-D2**（盲区必须列出并告知用户；Worker 能做就拦、做不到就不拦） | 本文件给出结论：Worker/SharedWorker/Service Worker **属于 A 类（做不到）**，不是"不想做" | 附录 A 直接公示；§5.3-① 的绕路**不得**作为默认能力宣传 |
| 6.4 | **Q-D1**（第一阶段只拦一条精准 URL） | 与"覆盖多来源"正交：覆盖矩阵决定"哪些页面里的这条 URL 会被命中"。但 B 类② 需要广域权限，与"只拦一条 URL"的保守姿态冲突 | 需用户裁定：第一阶段是否申请 `<all_urls>`（安装警告 + 审核成本），还是只申请少数站点 |
| 6.5 | **Q-A3 / Q-A4**（命中即拦、无来源白名单、secret 可关闭） | concept-design §6.3 说"风险面当前被 Q-D1 限定"；一旦为覆盖多来源而扩大 host 权限，**任何能命中该 URL 的页面都能控制下载**的风险面随之扩大 | 若采纳广域权限，建议同步评估是否把 `rpc secret` 默认开启（**属概念层决策，超出本题范围**，仅提示） |
| 6.6 | concept-design §6.4（已接受风险条目：`chrome://`、扩展页 CSP、PDF、view-source、`document_start` 之前、非 JS 途径、Worker） | 本文件是该条目的**具体化**：给出逐条判定、依据与"可解除/不可解除"的区分 | 公示文档可直接引用附录 A |
| 6.7 | **R9**（拦截在 JS API 层） | 与 Worker 盲区互为因果：JS API 层拦截要求"能注入"，而 worker 注入不存在；网络层替代方案（DNR）不能合成响应体 | 维持 R9；把 Worker 列为 A 类盲区（已在 §2.5 说明为何 DNR 不能补救） |
| 6.8 | **R12 / Q-C5**（引擎切换） | 无冲突；但若未来把"注入方式"当作引擎能力之一，注意 `world: MAIN` 是**转发器层**的事，不应下沉到引擎能力（R11 的原子能力是下载能力） | 提示 |

---

## 7 未验证

### 7.1 未验证清单（**不得**在公示文档中写成结论）

| 编号 | 未验证内容 | 现状 |
|---|---|---|
| U1 | manifest `content_scripts.world` 的最低 Chrome 版本 | 官方 manifest 参考页未标注版本；`chrome.scripting` 侧标注 Chrome 95+/102+【E2】【E3】 |
| U2 | `edge://` 页面无法注入的 **Microsoft 明文** | 只找到 Edge 的匹配模式 scheme 白名单（`http/https/file/ftp`）【E15】+ 共享 Chromium 实现；未找到"`edge://` 不可注入"的直述 |
| U3 | `match_origin_as_fallback` 的准确起始版本 | what's-new 标 "Chrome 99 … in Canary"【E14】；参考文档未标版本 |
| U4 | 带 `sandbox` 属性的 iframe（含 `srcdoc`+`sandbox`）内容脚本注入行为 | 未找到官方条文 |
| U5 | 顶层 `blob:` 文档 | MOAF 官方描述只针对"帧" |
| U6 | fenced frames / `disallowdocumentaccess` 帧 | 未找到官方条文（源码仅提到"不是 origin 边界"【源码 E9】） |
| U7 | 页面 prerender 状态下的注入与拦截 | 源码有 prerender 相关分支（`kWithheld` 在 prerender 帧上按拒绝处理）【源码 E13】，但对本项目的结论未定 |
| U8 | 运行期授权 / 扩展新安装后，"已打开且未刷新"的页面是否一定不生效 | 无官方明文；社区经验是"需要刷新"（标【社区经验，未验证】） |
| U9 | 对**扩展自身页面**用 `chrome.scripting.executeScript` 的实际结果（报错？静默失败？成功？） | 无官方明文；本文件只据 scheme 白名单给出"声明式不可行"的结论 |
| U10 | `chrome.scripting.executeScript` 对 `about:blank` / `data:` 帧的行为细节 | 未验证 |
| U11 | Worker 包装法（§5.3-①）在任何真实站点上是否可用（CSP、module worker、`toString` 副作用、跨源 `importScripts` 细节） | **完全未验证，无官方支持** |
| U12 | `<all_urls>` 与 `file://` 的交互（是否需要在开启文件访问后才能覆盖 file://） | 文档只说 `file:///` 需手动授权【E4】；组合行为未验证 |
| U13 | 声明式内容脚本注入失败时的用户可见反馈 | 无官方描述；"静默不注入"为社区经验 |
| U14 | 页面能否通过"未被注入的同源文档"取到原生 `fetch`/`XHR` 从而绕过包裹（§4 #34） | 时序未验证，无官方说明；需要实测 |
| U15 | 无痕窗口下内容脚本注入的具体行为细节（文档只说该设置控制"扩展对无痕模式的访问"） | 未找到更细的官方描述 |

### 7.2 建议的实测清单（一次浏览器内实验即可覆盖大部分 U 项）

1. 静态 + 动态两种装载方式，在 `document_start` / MAIN world 下能否拦到页面首个 `fetch`；
2. `match_origin_as_fallback` 对 `about:blank` / `srcdoc` / `data:` / `blob:` 四种帧的实际效果；
3. 跨域 iframe（有/无该帧 origin 权限）两态；
4. `new Worker` 场景：确认不加包装时拦不到（A6 复核）；
5. sandbox iframe / 顶层 blob 文档；
6. `file://` 与无痕两态；
7. "先开页面再授权"是否需要刷新；
8. 自身扩展页面用 `executeScript` 的返回值。

---

## 8 证据清单

> 所有条目核对日期 **2026-10-06**。Chromium 源码链接固定到 commit `a4f419a126457afbcb38999b80dbffd5a29ebadf`，`#数字` 为行号锚点（上游改动会使行号漂移）。
> 源码链接前缀：`https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/`

### 8.1 官方文档

| ID | 用于 | 摘录（原文） | URL |
|---|---|---|---|
| **E1** | isolated world、MAIN world 与 CSP、`document_start` 语义、`all_frames`、`match_origin_as_fallback`、静态脚本优先 | "Content scripts live in an isolated world…"; "Not only does each extension run in its own isolated world, but content scripts and the web page do too. This means that none of these (web page, content scripts, and any running extensions) can access the context and variables of the others."; "Scripts are injected after any files from css, but before any other DOM is constructed or any other script is run."; "When specified and set to true, Chrome will look at the origin of the initiator of the frame to determine whether the frame matches, rather than at the URL of the frame itself."; "Because this compares the origin of the initiator frame… Chrome requires any content scripts specified with `match_origin_as_fallback` set to true to also specify a path of `*`."; "When a content script is injected into the main world, the CSP of the page applies." | [Content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts?hl=en) |
| **E2** | `chrome.scripting` 需要 host 权限、`world` 版本、`allFrames` 每帧独立判定、`target` 只有 frame/document 维度 | "To use the browser.scripting API, declare the `scripting` permission in the manifest plus the host permissions for the pages to inject scripts into."; `world` "Chrome 95+"/"Chrome 102+"; "Each frame is checked independently for URL requirements; it will not inject into child frames if the URL requirements are not met." | [chrome.scripting](https://developer.chrome.com/docs/extensions/reference/api/scripting?hl=en) |
| **E3** | MAIN world 注入的起始版本 | "Chrome 95: inject scripts directly into pages — The `chrome.scripting` API's `executeScript()` method can now inject scripts directly into a page's main world." | [What's new in Chrome extensions](https://developer.chrome.com/docs/extensions/whats-new) |
| **E4** | match pattern 的 scheme 白名单、`<all_urls>`、`file:///` 需手动授权 | "Must be one of the following…: `http`, `https`, A wildcard `*`, which matches only `http` or `https`, `file`. For information on injecting content scripts into unsupported schemes, such as `about:` and `data:`, see Injecting in related frames."; "`<all_urls>` Matches any URL that starts with a permitted scheme… Because it affects all hosts, Chrome web store reviews for extensions that use it may take longer."; "`"file:///"` Allows your extension to run on local files. This pattern requires the user to manually grant access." | [Match patterns](https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns?hl=en) |
| **E5** | `activeTab` 的时效与受限页面 | "Access to the tab lasts while the user is on that page, and is revoked when the user navigates away or closes the tab."; "Access is not granted to restricted pages, such as `chrome://` pages." | [The "activeTab" permission](https://developer.chrome.com/docs/extensions/develop/concepts/activeTab?hl=en) |
| **E6** | `match_about_blank` / `match_origin_as_fallback` 的默认值与语义 | "`match_about_blank`: … Whether the script should inject into an `about:blank` frame where the parent URL matches one of the patterns declared in `matches`. Defaults to false."; "`match_origin_as_fallback`: … Whether the script should inject in frames that were created by a matching origin… include frames with different schemes, such as `about:`, `data:`, `blob:`, and `filesystem:`." | [content_scripts (manifest key)](https://developer.chrome.com/docs/extensions/reference/manifest/content-scripts?hl=en) |
| **E7** | DNR 的动作类型里没有"合成响应体"；DNR 与 SW 的关系（会被 SW 的 onfetch 挡住） | "Before a request is made, an extension can block or redirect (including upgrading the scheme from HTTP to HTTPS) it with a matching rule."；动作枚举：`block` / `redirect` / `modifyHeaders` / `allow` / `allowAllRequests` / `upgradeScheme`；"A declarativeNetRequest only applies to requests that reach the network stack… may not include responses that go through a service worker's `onfetch` handler. declarativeNetRequest won't affect responses generated by the service worker or retrieved from `CacheStorage`, but it will affect calls to `fetch()` made in a service worker." | [declarativeNetRequest](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest?hl=en) |
| **E14** | MOAF 版本线索 | "Chrome 99: match_origin_as_fallback in Canary — Content scripts can now specify the `match_origin_as_fallback` key to inject into frames that are related to a matching frame, including frames with `about:`, `data:`, `blob:`, and `filesystem:` URLs." | [What's new in Chrome extensions](https://developer.chrome.com/docs/extensions/whats-new) |
| **E15** | Edge 的 scheme 白名单与 file 授权 | "A match pattern is essentially a URL that begins with a permitted scheme (`http`, `https`, `file`, or `ftp`), and that can contain `*` characters."; "A Microsoft Edge extension can request access to `file` URLs. To enable this feature, you need to explicitly configure this access. Access to `file` URLs isn't automatic." | [Defining match patterns for an extension to access file URLs (Microsoft Learn)](https://learn.microsoft.com/en-us/microsoft-edge/extensions-chromium/developer-guide/match-patterns) |
| **E17** | `file://` 开关与无痕开关是**用户可见的每扩展设置** | "`isAllowedFileSchemeAccess()`: Retrieves the state of the extension's access to the 'file://' scheme. This corresponds to the user-controlled per-extension 'Allow access to File URLs' setting accessible via the `chrome://extensions` page."; "`isAllowedIncognitoAccess()`: … the user-controlled per-extension 'Allowed in Incognito' setting accessible via the `chrome://extensions` page." | [chrome.extension](https://developer.chrome.com/docs/extensions/reference/api/extension?hl=en) |
| **E22** | 顶层 `data:` 导航已被封禁 | "Remove content-initiated top frame navigations to data URLs — … we're blocking web pages from loading `data:` URLs in the top frame. This applies to `<a>` tags, `window.open`, `window.location` and similar mechanisms. The `data:` scheme will still work for resources loaded by a page." | [Chrome 60 deprecations](https://developer.chrome.com/blog/chrome-60-deprecations?hl=en) |
| **E26** | 版本基线 | Chrome stable = **154.0.8037.97**；Edge Stable = **154.0.4258.62**（发布 2026-10-05） | [Chrome 版本历史 API](https://versionhistory.googleapis.com/v1/chrome/platforms/linux/channels/stable/versions?pageSize=1) / [Edge Updates API](https://edgeupdates.microsoft.com/api/products?view=enterprise) |

### 8.2 Chromium / Blink 源码（commit `a4f419a1…`）

| ID | 用于 | 摘录 / 位置 | URL |
|---|---|---|---|
| **E8** | 内容脚本 `matches` 的合法 scheme；`chrome://` 默认被剔除 | `kValidUserScriptSchemes = URLPattern::SCHEME_CHROMEUI \| SCHEME_HTTP \| SCHEME_HTTPS \| SCHEME_FILE \| SCHEME_FTP \| SCHEME_UUID_IN_PACKAGE`（`extensions/common/user_script.cc:69`）；`ValidUserScriptSchemes()` 在未开 `--extensions-on-chrome-urls` 时 `&= ~SCHEME_CHROMEUI`（`…:109-118`）；`ParseMatchPatterns()` 中 `file` scheme 在 `!ALLOW_FILE_ACCESS` 时被剔除并记 `wants_file_access`（`extensions/common/utils/content_script_utils.cc:299-306`） | [#69](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/common/user_script.cc#69) · [#259](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/common/utils/content_script_utils.cc#259) |
| **E9** | origin 回退白名单 = `about/blob/data/filesystem`；无 precursor 时回退失败不注入 | `static const char* const kAllowedSchemesToMatchOriginAsFallback[] = { url::kAboutScheme, url::kBlobScheme, url::kDataScheme, url::kFileSystemScheme };`（`extensions/common/content_script_injection_url_getter.cc:32`）；"When there's no valid tuple … there's no origin to fallback to. Bail."；"It's okay to ignore this case for context classification because it's not meant as an origin boundary (unlike e.g. a sandboxed frame)."（`…:122`） | [#32](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/common/content_script_injection_url_getter.cc#32) |
| **E10** | manifest 内容脚本的 `world` 仅 MV3 有效；`match_about_blank` 与 MOAF 的优先级 | "Parse execution world. This should only be possible for MV3."（`extensions/common/manifest_handlers/content_scripts_handler.cc`）；"When both `match_origin_as_fallback` and `match_about_blank` are specified, `match_origin_as_fallback` takes priority."（同文件注释） | [content_scripts_handler.cc](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/common/manifest_handlers/content_scripts_handler.cc#103) |
| **E11** | 受限 URL 判定、`chrome://`、其它扩展页、无权限报错、用户站点级屏蔽 | `PermissionsData::IsRestrictedUrl()`：非合法 scheme（`about:blank`/`about:srcdoc` 例外）判受限；`kCannotAccessChromeUrl`；`kCannotAccessExtensionUrl`（`extensions/common/permissions/permissions_data.cc:128-176`）；`CanRunOnPage()` 先 `if (IsRestrictedUrl(document_url, error)) return kDenied;`（`…:699`）；用户站点级屏蔽 `constexpr char kErrorBlocked[] = "Blocked";`（`…:37`、`…:707`）。错误字符串定义见 `extensions/common/manifest_constants.h:218-242`：`"Cannot access a chrome:// URL"`、`"Cannot access a chrome-extension:// URL of different extension"`、`"Cannot access contents of the page. Extension manifest must request permission to access the respective host."`、`"Either the '<all_urls>' or 'activeTab' permission is required."` | [#128](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/common/permissions/permissions_data.cc#128) · [#218](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/common/manifest_constants.h#218) |
| **E12** | Chrome 应用商店不可脚本化 | `ChromeExtensionsClient::IsScriptableURL()`：`// The gallery is special-cased as a restricted URL for scripting to prevent access to special JS bindings we expose to the gallery …` + `kCannotScriptGallery`（`chrome/common/extensions/chrome_extensions_client.cc:153-165`）；`kCannotScriptNtp = "The New Tab Page cannot be scripted."`（`manifest_constants.h:241`） | [#153](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/chrome/common/extensions/chrome_extensions_client.cc#153) |
| **E13** | PDF 帧硬拒；其它扩展页硬拒；withheld 语义 | "`// Block executing scripts in the PDF content frame. The parent frame should be the PDF extension frame.`" 返回 `kDenied`（`extensions/renderer/extension_injection_host.cc:62-71`）；"`// Only allowlisted extensions may run scripts on another extension's page.`"（`…:83`） | [#62](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/renderer/extension_injection_host.cc#62) |
| **E16** | PDF 扩展 ID 与 origin 判定 | `// The extension id of the PDF extension.` `kPdfExtensionId[] = "mhjfbmdgcfjbbpaeojofohoefgiehjai"`（`extensions/common/constants.h:298`）；`IsPdfExtensionOrigin()` = `origin.scheme() == extensions::kExtensionScheme && origin.host() == extension_misc::kPdfExtensionId`（`components/pdf/common/pdf_util.cc:33`） | [pdf_util.cc#33](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/components/pdf/common/pdf_util.cc#33) |
| **E18** | 注入 API 的目标维度只有 frame/document；worker 线程上的上下文集合只服务扩展自身 SW | `chrome.scripting` 的 `InjectionTarget` 字段 = `all_frames` / `document_ids` / `frame_ids` / `tab_id`（`extensions/browser/api/scripting/scripting_api.cc:90-98`）；`WorkerScriptContextSet` 文件头注释："`// A set of ScriptContexts owned by worker threads.`"，其 `GetContextByV8Context()` 注释："`Returns the ScriptContext for a Service Worker \|v8_context\|…`"（`extensions/renderer/worker_script_context_set.h:18-34`） | [scripting_api.cc#90](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/browser/api/scripting/scripting_api.cc#90) · [worker_script_context_set.h#18](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/renderer/worker_script_context_set.h#18) |
| **E19** | worker 线程调度器面向扩展 Service Worker | `extensions/renderer/worker_thread_dispatcher.h` 仅依赖 `mojom/service_worker_host.mojom.h` / `WebServiceWorkerContextProxy`（扩展 SW 场景） | [worker_thread_dispatcher.h](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/renderer/worker_thread_dispatcher.h#1) |
| **E20** | SW 脚本协议限制：默认只允许 `http`/`https`，其余 scheme 必须显式注册 | Blink：`if (!SchemeRegistry::ShouldTreatURLSchemeAsAllowingServiceWorkers(script_url.Protocol()))` → `"Failed to register a ServiceWorker: The URL protocol of the script ('…') is not supported."`（`third_party/blink/renderer/modules/service_worker/service_worker_container.cc:383-393`）；注册表默认值 `service_worker_schemes({"http", "https"})`，注释："For ServiceWorker schemes: HTTP is required because http://localhost is considered secure."（`third_party/blink/renderer/platform/weborigin/scheme_registry.cc:69-74`），查询函数见 `…:269-275` | [service_worker_container.cc#383](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/third_party/blink/renderer/modules/service_worker/service_worker_container.cc#383) · [scheme_registry.cc#69](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/third_party/blink/renderer/platform/weborigin/scheme_registry.cc#69) |
| **E23** | host 权限的合法 scheme 不含 `chrome-extension` | `Extension::kValidHostPermissionSchemes = SCHEME_CHROMEUI \| SCHEME_HTTP \| SCHEME_HTTPS \| SCHEME_FILE \| SCHEME_FTP \| SCHEME_WS \| SCHEME_WSS \| SCHEME_UUID_IN_PACKAGE`（`extensions/common/extension.cc:217`）；`CanSpecifyHostPermission()` 单独限制 `chrome://`（`extensions/common/manifest_handlers/permissions_parser.cc:58-83`） | [extension.cc#217](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/common/extension.cc#217) · [permissions_parser.cc#58](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/common/manifest_handlers/permissions_parser.cc#58) |
| **E27** | `URLPattern` 的合法 scheme 全表（用于证明 `view-source` 等不在内） | `kValidSchemes = { http, https, file, ftp, chrome, chrome-extension, filesystem, ws, wss, data, uuid-in-package }`（`extensions/common/url_pattern.cc:34-44`）；`IsValidSchemeForExtensions()`（`…:137-144`） | [url_pattern.cc#34](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/common/url_pattern.cc#34) |
| **E28** | 未发现"把内容脚本注入页面 worker"的任何特性开关 | `extensions/common/extension_features.cc` 中与 worker 相关的特性只有 `kComponentExtensionAllowWorkerChromeResources`、`kExtensionsServiceWorkerStartRetry`、`kUseNewServiceWorkerTaskQueue`（均指扩展自身 SW），**没有** worker 内容脚本注入相关项 | [extension_features.cc](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/common/extension_features.cc) |
| **E31** | "用户级站点屏蔽"路径受默认关闭的特性开关控制 | `BASE_FEATURE(kExtensionsMenuAccessControl, IS_ANDROID ? base::FEATURE_ENABLED_BY_DEFAULT : base::FEATURE_DISABLED_BY_DEFAULT);`（`extensions/common/extension_features.cc:162-168`）；`PermissionsData::IsUrlBlockedByUser()` 首先检查该开关，未启用即返回 false（`extensions/common/permissions/permissions_data.cc:660-672`） | [extension_features.cc#162](https://chromium.googlesource.com/chromium/src/+/a4f419a126457afbcb38999b80dbffd5a29ebadf/extensions/common/extension_features.cc#162) |

### 8.3 规范

| ID | 用于 | 摘录（原文） | URL |
|---|---|---|---|
| **E21** | SW 脚本必须与 referrer 同源 | "If job's script url's origin and job's referrer's origin are not same origin, then: Invoke Reject Job Promise with job and "SecurityError" DOMException." | [Service Workers spec](https://w3c.github.io/ServiceWorker/) |
| **E24** | module worker 里 `importScripts()` 直接抛错（影响 Worker 包装法） | "Import scripts into worker global scope … 1. If worker global scope's type is "module", throw a TypeError exception." | [HTML Standard — Workers](https://html.spec.whatwg.org/multipage/workers.html#dom-workerglobalscope-importscripts) |
| **E25** | CSP 对 worker 脚本来源的回退链（影响 Worker 包装法） | "If this directive is absent, the user agent will first look for the `child-src` directive, then the `script-src` directive, then finally for the `default-src` directive, when governing worker execution." | [MDN — CSP: worker-src](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy/worker-src) |
| **E29** | worker 有独立全局作用域（解释"为什么注入文档 ≠ 注入 worker"） | "`WorkerGlobalScope` serves as the base class for specific types of worker global scope objects, including `DedicatedWorkerGlobalScope`, `SharedWorkerGlobalScope`, and `ServiceWorkerGlobalScope`." | [HTML Standard — Workers（§ the WorkerGlobalScope common interface）](https://html.spec.whatwg.org/multipage/workers.html#the-workerglobalscope-common-interface) |
| **E30** | 声明式内容脚本的注入权来自 `content_scripts.matches` | "`"content_scripts.matches"` Contains one or more match patterns that allows content scripts to inject into one or more hosts. Changes may trigger a warning." | [Declare permissions](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions?hl=en) |

---

## 附录 A — 拦截盲区清单（面向用户 · 可直接公示）

> 用法：A.1 是**浏览器不允许**（装哪个版本、给多少权限都一样）；A.2 是**你配合一下就能拦到**；A.3 是**本来就不做的事**（不是缺陷）。列表逐条给"什么情况下拦不到"和"后果是什么"。

### A.1 硬性拦不到（浏览器不允许）

1. **浏览器的内部页面（`chrome://…`、`edge://…`，包括设置、扩展管理、新标签页）**
   - 什么情况下拦不到：你在这些页面上，或这些页面自己发请求时。
   - 后果：这些页面发出的请求不会被转给下载引擎。实际上这些页面不会去调用 aria2 的 RPC，日常使用不受影响。
2. **Chrome 应用商店的页面（`chromewebstore.google.com` 等）**
   - 什么情况下拦不到：你浏览扩展商店页面时。
   - 后果：同上；商店页面也不会调用 RPC。
3. **其它扩展自己的页面**
   - 什么情况下拦不到：某个扩展自带界面页面里发起请求时。
   - 后果：这些请求不会被拦截。浏览器安全策略禁止一个扩展改写另一个扩展的页面。
4. **浏览器内置 PDF 阅读器里打开的 PDF**
   - 什么情况下拦不到：你在浏览器里打开 PDF 时。
   - 后果：PDF 里没有网页脚本可拦；阅读器本身也是浏览器自己的页面。
5. **"查看网页源代码"页面（`view-source:`）**
   - 什么情况下拦不到：你打开 `view-source:` 形式的地址时。
   - 后果：不会拦截；这种页面也不会发 RPC 请求。
6. **网页里的 Worker / SharedWorker / Service Worker 发出的请求**
   - 什么情况下拦不到：网页把请求写在后台线程里（一些现代前端框架、离线网页应用会这样做）。这些线程有独立于页面的运行环境，浏览器没有提供把脚本注入进去的能力。
   - 后果：**这类请求不会被拦截**，会真的按原地址发到网络上；如果那个地址上并没有真实服务（我们正是要顶替它），请求就会失败，网页里对应的功能会报网络错误。这是"技术上做不到就不拦"的诚实边界。
7. **顶层 `data:` 页面**
   - 什么情况下拦不到：不存在这种情况——浏览器已经禁止网页导航到顶层的 `data:` 地址（Chrome 60 起）。
   - 后果：无（这种页面根本打不开）。

### A.2 需要你配合一下才能拦到（不是做不到）

8. **没有授权给本扩展的网站**
   - 什么情况下拦不到：本扩展只被授权了一部分站点（安装时按站点授权，或后续被调整）。
   - 后果：这些页面里发往被拦截地址的请求不会被拦截，会真的发到网络上（通常失败）。
   - 怎么解决：在扩展详情页把该网站的访问权限打开（或安装时授予全部站点）。
9. **本地 HTML 文件（`file://`）**
   - 什么情况下拦不到：默认情况下本扩展没有本地文件访问权。
   - 后果：本地打开的 HTML 文件里发往被拦截地址的请求不会被拦截。
   - 怎么解决：在扩展详情页打开 **"允许访问文件网址"**。
10. **无痕窗口**
    - 什么情况下拦不到：默认本扩展在无痕模式下不运行。
    - 后果：无痕窗口里的页面不会被拦截。
    - 怎么解决：在扩展详情页打开 **"在无痕模式下启用"**。
11. **扩展刚安装/刚授权之前就已打开的页面（没有刷新过）**
    - 什么情况下拦不到：页面在本扩展生效之前就加载完成了；注入发生在页面加载时，不会追着改已经加载完的页面。
    - 后果：这些老页面不会被拦截。
    - 怎么解决：**刷新页面**（或重新打开标签页）。
12. **页面加载最开始的那一刻，本扩展还没接管之前发出的请求**
    - 什么情况下拦不到：极少数页面会在加载的第一个瞬间就发请求（本扩展已尽量提前到页面任何脚本运行之前）。
    - 后果：这一小段窗口内的请求不会被拦截。刷新后通常正常。
13. **页面自身的内容安全策略（CSP）很严格时**
    - 什么情况下拦不到：目标站点用 CSP 限制脚本/网络行为时，注入到页面环境里的转发器可能被限制。
    - 后果：可能部分或全部无法拦截（具体取决于站点）。此项目前属于**待实测**范围，我们不把它算作"已支持"。
14. **网页刻意绕过（从另一个不被接管的文档里取"原始"接口）**
    - 什么情况下拦不到：网页若刻意从不被接管的同源文档中取出原始的请求接口来发请求，可能绕过本扩展的拦截。
    - 后果：这类请求不会被拦截（属极端/刻意场景，正常前端不会这么做）。此项目前**待实测**，不把它算作"已支持"。

### A.3 本来就不做的事（不是缺陷）

15. **在浏览器地址栏直接粘贴 RPC 地址访问**：本扩展不是网络服务，不监听端口（浏览器扩展在技术上做不到）。请用会发 RPC 请求的前端（如内置的 AriaNg 界面）。
16. **浏览器之外的程序（`curl`、桌面软件、脚本）**：同上，它们连不上本扩展。
17. **不是脚本发出的请求**：网页里的链接导航、表单提交、`<img>`/`<script>` 之类的资源加载不走被接管的 JS 接口，因此不会被拦截。本扩展的定位是"接住 aria2 RPC 客户端的请求"，不是"网络代理"。
