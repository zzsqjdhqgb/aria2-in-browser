# F1 — 转发器的注入机制与时机

> 本轮只回答一件事：**转发器代码怎么装进执行环境、什么时候装进去**。
> 「拦截哪些 API、怎么 patch、命中后怎么处理」不在本文范围（属另一成员的议题）。

---

## 0 元信息

| 项 | 值 |
|---|---|
| 文档 ID | F1-injection |
| 所属 | aria2-in-browser「浏览器技术边界测绘」 |
| 议题 | [f1] 转发器的注入机制与时机 |
| 作者 | fwd-inject（团队成员） |
| 版本 / 状态 | v1 / 完成（待复核） |
| 日期 | 2026-10-06 |
| 证据核对日期 | **2026-10-06**：§8 中每条 URL 均于该日实际抓取（HTML 或官方 `.md.txt` 纯文本版） |
| 证据来源口径 | 仅 `developer.chrome.com`、`developer.mozilla.org`、MDN `browser-compat-data`（MDN 兼容性表数据源）、Chrome 官方帮助站。博客 / StackOverflow / AI 内容**未**作为结论依据 |
| 浏览器版本口径 | 只照抄官方页面文本中标注的版本要求（如「Chrome 102+」「Chrome 111」「Chrome 138 及以上」）。**本机 Chrome 实际版本号未核对**，因此任何「当前稳定版就是如此」的说法一律写「未验证」 |
| 依赖输入 | `/workspace/docs/concept-design/concept-design.md` v0.5（R4/R5/R9/R10、Q-D1/D2/D3/D5、§6 已接受风险） |
| 范围外 | 具体拦截哪些 API、patch 的实现与语义、Mock 层与错误模型、下载引擎、DNR 规则细节、WebSocket 协议细节 |

**标注约定**

| 标记 | 含义 |
|---|---|
| `[官方]` | 有官方文档原文直接支撑（§8 给出 URL + 摘录） |
| `[官方-间接]` | 官方文档没有这一句，但由多条原文可直接推出 |
| `[推断]` | 我方的技术推断，依据已写出，需实测确认 |
| `[未验证]` | 查不到官方依据，明确不写结论 |

**证据编号速查**（正文用 `E#` 引用，全文用同一套编号）

| 编号 | 来源 | 编号 | 来源 |
|---|---|---|---|
| E1–E7 | Chrome《Content scripts》概念页（分主题引用） | E21 | Chrome `offscreen` API |
| E8 | Chrome《Manifest - content scripts》 | E22 | Chrome `permissions` API |
| E9 | Chrome `scripting` API | E23 | Chrome《Declare permissions》 |
| E10 | Chrome《Message passing》 | E24 | Google 官方帮助：站点访问 |
| E11 | Chrome《Service worker lifecycle》 | E25 | Chrome《Host permissions 过渡指南》（标注 MV2） |
| E12 | Chrome《Web Accessible Resources》 | E26 | Chrome《Match patterns》 |
| E13 | MDN《Content scripts》 | E27 | Chrome《What's new in extensions》 |
| E14 | MDN `scripting.ExecutionWorld` | E28 | MDN browser-compat-data |
| E15 | MDN `manifest.json/content_scripts` | E29 | Chrome `extensionTypes.RunAt` |
| E16 | MDN `web_accessible_resources` | E30 | Chrome `declarativeNetRequest` |
| E17 | MDN 扩展 CSP | E31 | Chrome `webRequest` |
| E18 | Chrome《Manifest - Content Security Policy》 | E32 | Chrome `webNavigation` |
| E19 | Chrome《Improve extension security》 | E33 | Chrome 博客《Instant Navigation》 |
| E20 | Chrome `userScripts` API | E34 | web.dev《Preload scanner》 |
| — | — | E35–E39 | `storage` / `real-time` / MDN `postMessage` / MDN `connect` / MDN `onMessage` |

---

## 1 一句话结论

**推荐主力注入方式：manifest 静态声明 `content_scripts` + `run_at: "document_start"` + `world: "MAIN"`。**
理由：静态声明在官方文档里被明确为「同一生命周期阶段内最先注入」`[官方]`（E3），且不依赖 SW 存活；`world: "MAIN"` 是唯一被官方文档定义为「与宿主页面 JavaScript 共享执行环境」的内容脚本执行世界 `[官方]`（E8/E9）；默认 `world` 是 `ISOLATED`、默认 `run_at` 是 `document_idle`，两者都是「忘了改就晚一整拍」的默认值陷阱 `[官方]`（E4/E9）。

**时机下限：`document_start`。**
这是 JS 层能拿到的最早时机，官方定义是「在 css 注入之后、任何其它 DOM 被构建或**任何其它脚本被执行之前**」`[官方]`（E4/E29）。但它**不**保证「页面/浏览器还没发出请求」：导航请求本身、preload scanner 驱动的提前抓取、其它文档（iframe/opener/worker）发起的请求都可能在注入前就已上路，而这些在 JS 层**原理上不可达**。想更早就只剩网络层（DNR），而 R9 已裁定不走网络层（拿不到任意响应体）`[裁定]`。

**最大风险：注入时机竞态 × MAIN world 无扩展 API × MV3 SW 30 秒空闲终止，三者叠加。**
`world: "MAIN"` 里**没有**任何扩展 API `[官方]`（E14），所以每个被拦截的请求都必须跨 world 通信；而承载扩展逻辑的 MV3 Service Worker 官方定义为「空闲 30 秒即被终止」`[官方]`（E11/E36）。结果是「转发器在页面里永活、但扩展侧随时休眠」，延迟与失败模式都必须按「每次通信都可能唤醒一个冷上下文」设计，而**官方没有给出任何唤醒延迟数值** `[未验证]`（E11）。

---

## 2 机制

### 2.1 执行上下文全景（谁在哪儿、能碰什么）

| 执行上下文 | 运行在页面全局内？ | 能用扩展 API？ | 是否可被扩展装载 | 与扩展主进程的默认通信 | 证据 |
|---|---|---|---|---|---|
| MV3 Service Worker | 否（独立 worker，无 DOM） | 是（全部） | 扩展自身 | —（它就是主进程） | E11 |
| offscreen document | 否（隐藏的扩展页） | **只有 `runtime`** | 扩展自身 | `runtime` 消息 | E21 |
| content script（`world: "ISOLATED"`，默认） | **否**（隔离世界） | 部分白名单（`dom`/`i18n`/`storage`/`runtime` 子集） | 静态/动态/程序化 | `runtime.sendMessage` / `connect` | E1/E2 |
| content script（`world: "MAIN"`） | **是**（与页面共享执行环境） | **否**（无任何扩展 API） | 静态/动态/程序化 | 只能借共享 DOM 桥接（如 `window.postMessage`） | E8/E14/E7 |
| 扩展页面 / popup / options | 否（`chrome-extension://` 文档自己的全局） | 是（`extension_pages` CSP 之下） | 扩展自身 | `runtime` 消息 | E18/E19 |
| 被访问的网页 | 是 | 否（**例外**：`externally_connectable` 命中的页面可拿到受限 messaging API） | — | 仅经内容脚本桥 | E10 |
| 页面内的 Worker（Dedicated/Shared） | 否（独立全局，非 DOM 文档） | 否 | **官方无此注入目标** | — | E9/E1 `[官方-间接]` |
| 页面自己注册的 Service Worker | 否 | 否 | 官方无此注入路径 | — | E30/E1 `[官方-间接]` |

一句话：**「能改页面 JS」与「能用扩展 API」在 Chrome 里是互斥的两个世界。**`[官方]`（E1/E2/E14）

### 2.2 world 选择：ISOLATED vs MAIN

**官方定义（照抄）**

- Chrome `scripting` API：`"ISOLATED"` = *"Specifies the isolated world, which is the execution environment unique to this extension"*；`"MAIN"` = *"Specifies the main world of the DOM, which is the execution environment shared with the host page's JavaScript"*（E9）。
- Chrome 清单参考：`"world"` 默认 `"ISOLATED"`；选 `"MAIN"` 意味着 *"the script will share the execution environment with the host page's JavaScript"*，并附 **Warning**：*"There are risks involved when using the `"MAIN"` world. The host page can access and interfere with the injected script."*（E8）
- MDN：`MAIN` = *"The web page execution environment. This environment is shared with the web page without isolation. **Scripts in this environment do not have any access to APIs that are only available to content scripts.**"*（E14）

**为什么 monkey-patch 必须用 MAIN world `[官方]`**

1. ISOLATED world 与页面各有自己的 JS 全局与变量，双方互不可见：*"none of these (web page, content scripts, and any running extensions) can access the context and variables of the others"*（E1）；MDN 进一步给出可观测后果：*"Content scripts cannot see JavaScript variables defined by page scripts."*、*"If a page script redefines a built-in DOM property, the content script sees the original version of the property, not the redefined version."*，并说明 *"In Chrome this behavior is enforced through an isolated world"*（E13）。
   ⇒ 在 ISOLATED world 里替换 `window.fetch`，页面的 `fetch` 仍是原版；改动只对隔离世界自己生效。
2. MAIN world 与页面**共享同一个执行环境**（E8/E9），所以在其中对 `window.fetch` / `XMLHttpRequest` / `WebSocket` 做的替换，页面自己的调用就能看见。
3. 代价：MAIN world 拿不到扩展 API（E14），且页面对注入代码**可读、可改、可干扰**（E8 的 Warning、E14 的 Warning）。
   ⇒ 转发器在 MAIN world 的代码必须假定「同堆的对手就是被服务的页面」。

**一个容易漏掉的对比项：`USER_SCRIPT` 世界。** Chrome 另有 `chrome.userScripts` API，其孤立世界叫 `USER_SCRIPT`，也支持 `MAIN`；但使用它需要 `userScripts` 权限，**且用户必须在扩展详情页打开开关**（Chrome 138 起是 *"Allow User Scripts"* 开关；138 之前是开发者模式开关）`[官方]`（E20）。这是**额外**的用户授权流程，见 §2.5。

### 2.3 run_at 与时间轴

**官方定义（照抄，E4/E29）**

| 值 | 官方原文 |
|---|---|
| `document_start` | *"Scripts are injected after any files from css, but before any other DOM is constructed or any other script is run."* |
| `document_end` | *"Scripts are injected immediately after the DOM is complete, but before subresources like images and frames have loaded."* |
| `document_idle`（**默认**） | *"Preferred. Use `"document_idle"` whenever possible."* / *"The browser chooses a time to inject scripts between `"document_end"` and immediately after the `window.onload` event fires."* |

`RunAt` 类型页把语义总结为 *"The soonest that the JavaScript or CSS will be injected into the tab. Defaults to `"document_idle"`."*（E29）

**`document_start` 足够吗？——分两半回答**

- **够的一半（官方保证）**：`document_start` 注入发生在**该文档自己的任何脚本执行之前**（E4）。所以「页面第一个 `<script>` 就发起请求」这一情形，只要它是文档内脚本发起的，注入是赶得上的。同一阶段内的顺序也有保证：*"Within a given stage of the document lifecycle, content scripts declared statically in the manifest are the first to be injected, before content scripts registered in any other way."*（E3）
- **不够的一半（官方没有承诺「注入前没有请求」）**：`document_start` 的官方措辞只约束「DOM 未构建、脚本未执行」，**没有任何一句**说此前没有网络请求。已知至少有这些请求可能更早：
  - 导航请求本身（它必然早于任何注入）；
  - **preload scanner**：官方（web.dev）描述浏览器有 *"a secondary HTML parser"*，它 *"examines raw markup in order to find resources to opportunistically fetch before the primary HTML parser would otherwise discover them"*，且主解析器被 CSS/阻塞脚本卡住时它仍在并行抓取（E34）`[官方]`；
  - 其它文档发起的请求（opener、iframe、页面已有的 Worker）；
  - 预渲染/bfcache 中的页面（见 §5 F5）。
  ⇒ 「`document_start` 之前已发出的请求拦不到」这条，**官方没有逐字写过**，属 `[官方-间接]`/`[推断]`：依据是「注入时机定义 + preload scanner 官方描述」。
- **能否更早？**
  - JS 层：**没有比 `document_start` 更早的官方注入点**。程序化注入有 `injectImmediately`（Chrome 102+），但官方明确打了折扣：*"Note that this is not a guarantee that injection will occur prior to page load, as the page may have already loaded by the time the script reaches the target."*（E9）
  - 网络层：`declarativeNetRequest`（DNR）是唯一能在**请求发出前**介入的机制 —— *"Before a request is made, an extension can block or redirect (including upgrading the scheme from HTTP to HTTPS) it with a matching rule."*（E30）`[官方]`。但 DNR 的动作集合是 block / redirect / upgradeScheme / allow / allowAllRequests / modifyHeaders（E30），**不含「合成任意响应体」** `[官方-间接]`，因此不满足 R9 要求的「就地短路并返回任意响应」。
  - MV3 里 `webRequest` 已无法阻塞：*"As of Manifest V3, the "webRequestBlocking" permission is no longer available for most extensions."*（E31）`[官方]`
  - `chrome.webNavigation.onBeforeNavigate` 只说 *"Fired when a navigation is about to occur."*（E32），**官方未定义**它与页面脚本执行的先后顺序，且官方明确 *"There is no defined ordering between events of the webRequest API and the events of the webNavigation API."*（E32）⇒ 不能当作「比 document_start 更早」的可靠钩子 `[未验证]`。

**结论**：JS 层时机下限 = `document_start`，且必须**显式**设置（默认是 `document_idle`）。比它更早只能走网络层，而网络层被 R9 排除（§6）。

### 2.4 三种装载方式对比

| 维度 | manifest 静态声明 | `chrome.scripting.registerContentScripts` 动态注册 | `chrome.scripting.executeScript` 程序化注入 |
|---|---|---|---|
| 声明位置 | `manifest.json` → `content_scripts`（E8） | SW 运行时注册（Chrome 96+）（E9） | SW 运行时调用（E9） |
| 需要的权限 | `content_scripts.matches` 的匹配模式本身即授权来源；官方把「manifest 声明的内容脚本注入」列为**不需要** host 权限的特例（E23） | `scripting` 权限 **+** 目标页面的 host 权限（`host_permissions` 或 `activeTab`）（E9）；且 *"Registered content scripts are only executed if the extension is granted host permissions for the domain."*（E13） | 同上（E9/E23） |
| 注入时机 | 可选 `run_at`，默认 `document_idle`（E8） | 可选 `runAt`，默认 `document_idle`（E9） | *"By default, the script will be run at `document_idle`, or immediately if the page has already loaded."*（E9） |
| 是否能赶在页面脚本前 | **能**（`document_start`，且同阶段内静态脚本最先注入）（E3/E4） | 能（`runAt: "document_start"`）（E9），但生效条件受 host 权限与授权状态影响（E13/E25） | 不保证：只能「尽快」，官方明说可能晚于页面加载（E9） |
| 是否随会话保留 | 是（就是包的一部分） | 默认 `persistAcrossSessions: true`（E9） | 否，一次性 |
| 是否随扩展更新失效 | 随包更新 | **扩展更新时被清空**，需在 `runtime.onInstalled` 的 `"update"` 分支重建（E13） | — |
| 运行时可变 | 否（改动 = 发新版本 + 可能触发新权限警告）（E23） | 是（`updateContentScripts` / `unregisterContentScripts`）（E9） | 是 |
| 是否依赖 SW 存活 | 否（浏览器侧声明）`[推断]` | 注册动作需要 SW 醒着；**注册结果**存于浏览器侧 `[推断]` | **是**（调用方就是 SW） |
| world 支持 | `world` 字段（E8）；MDN 兼容性数据：Chrome **111** 起（E28） | `world`：Chrome **102+**（E9/E27） | `world`：Chrome **95+**（E9/E27） |

补充约束（全部 `[官方]`，E9）：
- `registerContentScripts` 的 `matches` *"Must be specified"*；
- 解析/文件校验失败或 id 已存在时 *"no scripts are registered"*（原子性）；
- `unregisterContentScripts` *"will not remove scripts or styles that have already been injected"*（注销不等于卸载）；
- `ScriptInjection.func` 会被序列化 *"This function will be serialized, and then deserialized for injection. This means that any bound parameters and execution context will be lost."*；
- `args` *"must be JSON-serializable"*。

### 2.5 动态注册需要额外权限与用户授权流程吗？

分三层，结论不同：

1. **API 权限层**：需要 `scripting`；并且 *"declare the `"scripting"` permission in the manifest plus the host permissions for the pages to inject scripts into. Use the `"host_permissions"` key or the `"activeTab"` permission, which grants temporary host permissions."*（E9）`[官方]`
2. **主机授权层（这才是「用户授权流程」的真正所在）**：
   - 若 host 权限写在 `host_permissions`：安装时一次性授权（并显示权限警告）；用户在扩展详情页/右键菜单里可以把站点访问改为 *"change the extension's site access to On select, On specific sites, or On all sites."*（Google 官方帮助，E24），受限站点上的内容脚本**不会自动注入**（E25）；若把扩展设为「点击时」(on click)，*"The extension essentially behaves as though it used the `activeTab` permission."*（E25）
   - 若 host 权限放在 `optional_host_permissions`：可在运行时用 `permissions.request()` 申请，但官方要求 *"Permissions must be requested from inside a user gesture, like a button's click handler."*（E22）`[官方]`，且 *"These permissions must either be defined in the `optional_permissions` field of the manifest or be required permissions that were withheld by the user."*（E22）。Chrome 133+ 另提供 `permissions.addHostAccessRequest()`，把「请求某个 host 的访问权」挂到具体标签页上（E22）`[官方]`。
   - 选 optional 的官方理由之一：*"Easier upgrades: When you upgrade your extension, Chrome won't disable it for your users if the upgrade adds optional rather than required permissions."*（E22）`[官方]`
3. **「额外权限」的红线**：**不要**误以为需要 `userScripts`。`chrome.userScripts` 是另一条路（它面向「运行扩展包外、用户提供的任意代码」），要求 `userScripts` 权限**外加用户手动打开开关**（Chrome 138+ 是每个扩展详情页的 *"Allow User Scripts"*；138 之前需要开发者模式），且未打开时 API 为 `undefined`（E20）`[官方]`。用 `content_scripts` / `scripting` + `world: "MAIN"` 做转发器**不需要**这个开关。

**动态注册在「host 权限未授予」时的确切行为**：官方只在 MDN 写了「已注册的内容脚本仅在扩展被授予该域 host 权限时才执行」（E13），**没有**说明 `registerContentScripts` 调用本身是失败还是「注册成功但不注入」`[未验证]`（§7 第 U8 条）。

### 2.6 MAIN world ↔ 扩展的通信通道

MAIN world 没有扩展 API（E14），因此通道只能建立在**共享 DOM**上。官方给的就是这条路：*"Although the execution environments of content scripts and the pages that host them are isolated from each other, they share access to the page's DOM. If the page wishes to communicate with the content script, or with the extension through the content script, it must do so through the shared DOM."* —— 官方示例用 `window.postMessage()`，并在文档侧用 `event.source !== window` 过滤（E7）`[官方]`。

可用通道（按官方支持强度排序）：

| 通道 | 官方支持 | 关键限制 |
|---|---|---|
| MAIN world →（`window.postMessage`）→ ISOLATED world 桥 →（`runtime.sendMessage` / `connect`）→ SW | `[官方]` E7 | ① 页面**也能**监听/伪造消息（E7 官方示例自己就要求过滤来源）② 消息按 `window.postMessage` 的克隆规则传递（结构化克隆：函数、DOM 节点不可传；`MessagePort` 可通过 `transfer` 列表转移）（E37） |
| MAIN world →（页面直接调用）→ `chrome.runtime.sendMessage(extensionId, …)`（需 `externally_connectable`） | `[官方]` E10 | 需要 manifest 声明 `externally_connectable.matches`，且 *"This exposes the messaging API to any page that matches the match patterns you specify."*（E10）；需知道扩展 ID；并且 *"It is not possible to send a message from an extension to a web page."*（E10）⇒ 只能当上行通道，下行仍需 postMessage |
| `MessageChannel` / 转移 `MessagePort` 到另一个 world | `[未验证]` | `window.postMessage` 的 `transfer` 官方支持转移 `MessagePort`（E37），但**没有**官方文档说明「ISOLATED world 与 MAIN world 之间转移 port 可用」；需实测 |
| `CustomEvent` + `detail` / 共享 DOM 属性 | `[官方-间接]` | 属于「共享 DOM」范畴（E7），但官方未给专门示例；结构化克隆限制同样适用 |

**跨 world 回到扩展一侧之后**，通道自身的官方约束（全部 E10 `[官方]`）：
- 序列化：*"In Chrome, the message passing APIs use JSON serialization. Notably, this is different to other browsers which implement the same APIs with the structured clone algorithm. This means a message (and responses provided by recipients) can contain any valid `JSON.stringify()` value. Other values will be coerced into serializable values (notably `undefined` will be serialized as `null`);"*（E10）。
  ⇒ **不能**经 `runtime.sendMessage` 传 `ArrayBuffer`/`Map`/`Set`/函数/`Blob`（Chrome 口径）；要传二进制得自己编码（或在兼容浏览器上依赖结构化克隆，但那不是 Chrome 的行为）。
- 大小上限：*"The maximum size of a message is 64 MiB."*（E10）
- 长连接：`runtime.connect()` 得到 `Port`，用 `postMessage` 收发（E10/E38）；`onDisconnect` 官方列出的触发原因包括「对端没有 `onConnect` 监听器」「标签页/帧被卸载」「对端调用 `disconnect()`」（E10）。
- `onMessage` 异步回复：官方给三种方式（同步 `sendResponse` / `return true` / 从 **Chrome 148** 起可 `return` promise）（E10）；**注意 MDN 上「Chrome 尚不支持 promise 返回值」的说法已过时**，应以 Chrome 官方为准（E10 vs E39）`[官方]`。
- 错误处理：Chrome 146 起，监听器抛错会让发送侧 promise reject；**无法序列化的响应**会使发送侧收到 *"Error: Could not serialize message."*（E10）`[官方]`。

### 2.7 web_accessible_resources（WAR）的作用与配置

官方原文（E12）`[官方]`：
- *"Web-accessible resources are files inside an extension that can be accessed by web pages or other extensions."*
- *"By default no resources are web accessible"*（默认全关，理由是防指纹与防被利用）。
- 暴露后才能通过 `chrome-extension://[PACKAGE ID]/[PATH]` 访问，*"The resources are served with appropriate CORS headers, so they're available via `fetch()`."*
- **关键的一条**：*"Content scripts themselves do not need to be allowed."*（E12）；MDN 同义：*"Note that content scripts don't need to be listed as web accessible resources."*（E16）
  ⇒ 用 `content_scripts` / `registerContentScripts` / `executeScript({files})` 装载转发器时，**不需要** WAR；只有当你改用「往页面里插 `<script src="chrome-extension://…">`」或「DNR 重定向到扩展资源」时，才需要把资源列进 WAR（E12/E30）。
- MV3 结构：数组项含 `resources` + （`matches` 或 `extension_ids`）；`matches` *"Only the origin is used to match URLs"*，Chrome 下路径必须是 `/*`（E12/E16）。
- `use_dynamic_url: true` 时只用每会话生成的动态 ID 访问（浏览器重启或扩展重载后重新生成）（E12/E16）。
- 官方同时给出安全代价：暴露的资源 *"also exposes the resources to any first-party or third-party scripts running on the same site."*（E1）

### 2.8 页面 CSP 会不会挡住注入

官方明文（E5，Chrome 内容脚本页）：*"When a content script is injected into the main world, the CSP of the page applies."*
对照：隔离世界的 content script 用的是**扩展自己的** CSP —— `script-src 'self' 'wasm-unsafe-eval' 'inline-speculation-rules' chrome-extension://<id>/; object-src 'self';`，其效果是 *"prevents the use of `eval()` as well as loading external scripts."*（E6）`[官方]`

由此得到两条**必须区分**的结论：
- ISOLATED world 的转发器：不受页面 CSP 影响（用扩展 CSP）`[官方]`（E6）。
- MAIN world 的转发器：*"the CSP of the page applies"*（E5）`[官方]`。但官方**没有**逐条说明「这句话具体会拦掉什么」——例如「扩展自己用 `js: [...]` 装载的 MAIN world 文件，会不会因页面 `script-src` 不含该来源而整个不执行」`[未验证]`。MDN 的补充只能说明「Chrome 里很多 DOM API 走扩展 CSP 而非页面 CSP」（E17）`[官方]`。
  ⇒ 实操含义（`[推断]`）：MAIN world 代码应假定页面 CSP 生效，**不要用 `eval` / `new Function` / 动态注入外部脚本**；页面 CSP 具体拦到什么程度必须实测（§7 U1、U2）。

扩展自身页面另有一套、且**不可放宽**的 CSP（E18/E19）`[官方]`：
- 默认：`{"extension_pages": "script-src 'self'; object-src 'self';", …}`；最低可接受策略是 `script-src 'self' 'wasm-unsafe-eval'; object-src 'self';`，且 *"The `extension_pages` policy cannot be relaxed beyond this minimum value."*
- MV3 下 `script-src` / `object-src` / `worker-src` 只允许 `self` / `none` / `wasm-unsafe-eval`（以及未打包扩展的 localhost）；`eval`、`new Function`、远程代码一律不允许（E19）。
  ⇒ 内置 AriaNg UI 及转发器都必须**打包在扩展内**、以本地文件加载；若某个 UI 依赖 `eval`，在扩展页里会直接失败。

### 2.9 R5 特例：扩展自身页面怎么装载「同一个转发器」

**前提事实**：扩展页面无法被注入 content script。MDN 明确：*"Extensions cannot inject content scripts into privileged browser UI pages (such as about:debugging, about:addons, reader view, view-source, or the PDF viewer) **or extension pages**."*（E13）`[官方]`；Chrome 的 match pattern 只支持 `http` / `https` / `*` / `file` 四种 scheme（E26），**表达不了 `chrome-extension://`**，因此静态声明与 host 权限层面都无法把「扩展自己的页面」纳入注入范围。

**官方给的替代装载方式**（就是 R5 说的「只换装载方式」）：*"If an extension wants to run code in an extension page dynamically, it can include a script in the page. This script contains the code to run and registers a `runtime.onMessage` listener that implements a way to execute the code. The extension can then send a message to the listener to trigger the code's execution."*（E13）`[官方]`
更简单的情形（内置 UI 是我们自己打包的页面）：直接在页面 HTML 里用本地 `<script>` / `<script type="module">` 装载同一个转发器模块即可 —— 这属于「扩展自身页面的普通脚本」，受 `extension_pages` CSP 约束（`script-src 'self'`，E18），完全合法。

**为什么这决定「转发器必须是可独立装载的模块」**（这是技术事实的直接后果，`[推断]`，但依据充分）：

- 两种装载方式唯一的**公共运行环境**是「纯页面全局」：MAIN world 里**没有**任何扩展 API（E14），扩展页里虽然**有** `chrome.runtime` 等，但为了同一份代码两边都能跑，核心不得直接依赖 `chrome.*`。
- 于是「不换调用路径」在技术上就等价于：**同一份核心代码、在同一个页面全局里、对同一批 API（fetch/XHR/WebSocket…）做同样的 patch**；两种装载方式之间只允许替换**绑定层**（配置从哪来、事件往哪送）。
- 因此核心必须：(a) 不引用 `chrome.*`；(b) 通过一个显式的「传输适配器 + 配置」接口被装配；(c) 可被两种入口装载（MAIN world 的 content script 文件 / 扩展页的 `<script>`）。
- 反过来讲：如果核心直接调用 `chrome.runtime.sendMessage`，它就**不可能**在 MAIN world 跑（E14），R4.1 要求的「拦截所有普通标签页」直接落空。

**R5 的两处额外代价**（记录，供详细设计参考）：
1. 两种装载方式的**时序不同**：扩展页是本地文档，脚本加载即生效、不存在「页面脚本先跑了」的竞态；网页侧则受 `document_start` 与站点授权状态约束（§2.3/§2.5）。
2. 「不换调用路径」要求内置 UI 必须真的去 `fetch`/WS 访问用户配置的那个 URL；一旦 UI 走任何直接调用 Mock 层的捷径，就违反 R5 —— 这条是纯设计约束，技术上无阻碍。

---

## 3 硬约束

> 每条 = 一句可作为设计前提的硬约束 + 证据编号。`[官方]` 为官方原文支撑。

**H1** 每个 JavaScript 执行世界各自独立：页面、每个扩展的 content script、扩展之间**互不可见**；ISOLATED world 中 patch 页面 API 对页面**无效**。`[官方]` E1/E13
**H2** 只有 `world: "MAIN"` 与页面**共享执行环境**，页面自己的调用才能看到 patch。`[官方]` E8/E9
**H3** `world: "MAIN"` 中**没有任何扩展 API**（`chrome.runtime` 等一律不可用）。`[官方]` E14
**H4** MAIN world 的代码对页面**可读、可改、可干扰**（官方 Warning）。`[官方]` E8/E14
**H5** `world` 默认 `ISOLATED`；`run_at` / `runAt` 默认 `document_idle`。**不显式设置就得不到想要的时机与上下文。**`[官方]` E8/E9
**H6** JS 层最早的注入时机是 `document_start`（css 之后、任何其它 DOM 构建与脚本执行之前）。`[官方]` E4/E29
**H7** 同一生命周期阶段内，**manifest 静态声明的脚本最先注入**，先于任何其它方式注册的脚本。`[官方]` E3
**H8** 「注入前没有请求」**不是**官方承诺；导航请求、preload scanner 抓取、其它文档的请求都可能更早。`[官方-间接]` E4/E34
**H9** 程序化注入不保证早于页面加载（`injectImmediately` 的官方限定）；`executeScript` 默认 `document_idle`，页面已加载则立即执行。`[官方]` E9
**H10** 比 JS 更早只有网络层；MV3 的 `webRequest` 不能阻塞（`webRequestBlocking` 只对策略安装的扩展可用），DNR 能「在请求发出前」block/redirect/modifyHeaders，但动作集合里没有「合成任意响应体」。`[官方]` E30/E31
**H11** `chrome.scripting` 需要 `scripting` 权限 **+** 目标页 host 权限（或 `activeTab`）。`[官方]` E9
**H12** 已注册的动态内容脚本**只在已获得该域 host 权限时才执行**。`[官方]` E13
**H13** 动态注册默认跨会话保留（`persistAcrossSessions` 默认 `true`），但**扩展更新会清空内容脚本**，需在 `runtime.onInstalled` 的 `update` 分支重建。`[官方]` E9/E13
**H14** 运行时 host 权限必须由用户在**用户手势**中授予（`permissions.request()`）；用户还可以把站点访问改成 `On select` / `On specific sites` / `On all sites`，受限站点上内容脚本不会自动注入。`[官方]` E22/E24/E25
**H15** 扩展页面（含 popup/options/内置 UI）**不能被注入**；match pattern 也无法表达 `chrome-extension://`。官方替代方案是「在页面里放一个脚本 + `runtime.onMessage` 监听器」。`[官方]` E13/E26
**H16** 隔离世界的 content script 用**扩展自己的 CSP**，不受页面 CSP 影响；MAIN world 注入时**页面 CSP 适用**。`[官方]` E5/E6
**H17** 扩展页面的 CSP 默认 `script-src 'self'; object-src 'self';` 且**不可放宽**（MV3 下 `script-src` 只允许 `self`/`none`/`wasm-unsafe-eval` 等）；`eval` 与远程代码在扩展里不可用。`[官方]` E18/E19
**H18** content script 自身**不需要**声明为 web_accessible_resources；WAR 只在「页面/其它扩展要直接访问扩展文件」时才需要。`[官方]` E12/E16
**H19** `runtime` 消息在 **Chrome 里是 JSON 序列化**（非结构化克隆），上限 64 MiB；函数、`Map`、`Set`、`ArrayBuffer` 等不能直接传。`[官方]` E10
**H20** MAIN world 与扩展之间的下行消息**只能借共享 DOM**（官方路径是 `window.postMessage`）；`externally_connectable` 只解决「网页 → 扩展」方向。`[官方]` E7/E10
**H21** MV3 Service Worker 空闲 **30 秒**被终止；单个请求/事件超过 **5 分钟**、`fetch()` 响应超过 **30 秒**也会被终止；休眠时事件会唤醒它。`[官方]` E11/E36
**H22** 打开的 port **不再**重置空闲计时器（Chrome 114 起），只有**发送长连接消息**才保活；SW 内 WebSocket 消息自 Chrome 116 起重置计时器。`[官方]` E11
**H23** SW 的全局变量会在终止时丢失，状态必须落到 `storage`；`storage.session` 是内存态、禁用/重载/更新/浏览器重启即清空，且默认不对 content script 暴露。`[官方]` E11/E35
**H24** offscreen document 只能用 `runtime` API，且同一扩展同时只能有一个。`[官方]` E21
**H25** `chrome.userScripts`（含 `USER_SCRIPT` 世界）需要 `userScripts` 权限 **+** 用户手动开关（Chrome 138+ 为 Allow User Scripts，之前为开发者模式）。转发器走 `content_scripts`/`scripting` 时**不需要**它。`[官方]` E20

---

## 4 能力映射

### 4.1 执行上下文 × 转发器关心的能力

| 上下文 | 改页面全局 API（monkey-patch） | 用扩展 API | 装载方式 | 最早生效时机 | 跨上下文通信 | 可否承载转发器核心 |
|---|---|---|---|---|---|---|
| content script `ISOLATED` | ❌（E1/E13） | ✅ 白名单子集（E2） | 静态/动态/程序化 | `document_start`（E4） | `runtime.sendMessage` / `connect`（E2/E10） | ❌ 只能当「桥」 |
| content script `MAIN` | ✅（E8/E9） | ❌（E14） | 静态/动态/程序化 | `document_start`（E4） | 共享 DOM（`postMessage`）（E7） | ✅ **主力** |
| 扩展页面 / 内置 UI | ✅（页面自己的全局） | ✅ | 页面内 `<script>` / ESM（E13/E18） | 文档加载即生效 | `runtime` 直连 | ✅ **R5 同源装载**（E13） |
| popup | ✅（popup 自己的全局，无意义） | ✅ | 页面内脚本 | 打开即生效 | `runtime` 直连 | ⚠️ 仅控制面 |
| MV3 SW | ❌ 无页面 | ✅ | 扩展自身 | — | — | ⚠️ 只能当后端（E11） |
| offscreen document | ❌（隐藏扩展页，E21） | 仅 `runtime`（E21） | 扩展自身 | — | `runtime` | ⚠️ 可做数据面，不能注入 |
| 页面内 Worker | ❌ 官方无注入目标（E9/E1） | ❌ | 无 | — | — | ❌ 盲区 |
| 页面的 Service Worker | ❌ 官方无注入路径 | ❌ | 无 | — | — | ❌ 盲区（DNR 能影响其 `fetch`，E30） |

### 4.2 三种装载方式的能力映射（速查）

| 需求 | 静态声明 | 动态注册 | 程序化 `executeScript` |
|---|---|---|---|
| 赶在页面首个脚本之前 | ✅（最优先，E3/E4） | ✅（E9） | ❌ 不保证（E9） |
| 用户现配 URL（Q-D1）后才生效 | ❌ 需发新版本 | ✅（E9） | ⚠️ 需 SW 在恰当的时机被唤醒 |
| 不需要 `scripting` 权限 | ✅（E23） | ❌（E9） | ❌（E9） |
| 不需要 host 权限 | ✅（作为特例，E23） | ❌（E13） | ✅ 仅 `activeTab` 场景（E9/E25） |
| 跨浏览器重启保留 | ✅ | ✅（默认，E9） | ❌ |
| 跨扩展更新保留 | ✅ | ❌ 需重建（E13） | ❌ |
| 覆盖 iframe | `all_frames`（E8） | `allFrames`（E9） | `target.allFrames`（E9） |
| 能覆盖 `about:`/`data:`/`blob:`/`filesystem:` 帧 | `match_origin_as_fallback`（E8） | `matchOriginAsFallback`（Chrome 119+，E9） | — |

---

## 5 失败模式与盲区

### 5.1 时机类

| # | 失败/盲区 | 机制 | 证据 |
|---|---|---|---|
| F1 | 转发器**默认太晚**（`document_idle`） | 未显式设 `run_at`/`runAt`；默认值下注入发生在 DOM 完成前后，页面早已发完请求 | E8/E9 |
| F2 | 注入前已发出的请求拦不到 | 导航请求、preload scanner 抓取、其它文档的请求；JS 层原理上不可达 | E4/E34 `[官方-间接]` |
| F3 | 页面**已经加载完成后**才开始装载（扩展刚安装、刚授权、SW 刚被执行） | `executeScript` 官方限定不保证早于页面加载；动态注册/授权晚于文档创建时，本轮文档不会补注入 | E9/E25 |
| F4 | 用户在站点访问里设为「点击时 / 指定站点」，目标站未授权 | 受限站点内容脚本不自动注入；`document_idle` 可在授权后立即注入，而 `document_start`/`document_end` 需要**刷新页面** | E24/E25 `[官方]`（E25 页面标注为 MV2 过渡指南，MV3 是否逐字一致 `[未验证]`） |
| F5 | 预渲染 / bfcache 页面 | 预渲染页是**已加载的文档**，其 `document_start` 早已过去；`frameId == 0` 对它不成立，且官方说明 webNavigation 事件可在 `prerender` 状态下触发 | E33 `[官方]`；「预渲染页里是否会注入、何时注入」`[未验证]` |
| F6 | 特殊页面完全不可注入 | `chrome://`、`view-source:`、PDF viewer、其它扩展页面、`about:`/`data:`/`blob:`/`filesystem:`（除非 `match_origin_as_fallback`）；Chrome 企业策略 `runtime_blocked_hosts` 还会再收窄 | E8/E13/E23 |

### 5.2 上下文与能力类

| # | 失败/盲区 | 机制 | 证据 |
|---|---|---|---|
| F7 | 在 ISOLATED world 写转发器 ⇒ **完全无效** | 隔离世界与页面变量互不可见，patch 打在自己那份全局上 | E1/E13 |
| F8 | MAIN world 里调 `chrome.*` ⇒ 直接抛错 | MAIN world 无任何扩展 API | E14 |
| F9 | 页面可以篡改/绕过/观察转发器 | 官方 Warning：MAIN world 与页面同堆、无隔离 | E8/E14 |
| F10 | 页面自己也在 patch 同一批 API（框架、其它扩展） | 多个 patch 叠加顺序无官方约定；谁在外层决定行为 | `[推断]`（无官方依据，需实测） |
| F11 | Worker 内请求拦不到 | 内容脚本的注入目标只有文档（`tabId`/`frameIds`/`documentIds`），没有 Worker 目标；Worker 有独立全局 | E9/E1 `[官方-间接]`；Q-D2 已接受 |
| F12 | 页面 Service Worker / CacheStorage 生成的响应 | DNR 官方明确不作用于 SW 生成的响应与 CacheStorage，只影响 `fetch()` 调用 | E30 |
| F13 | 若改用 `<script src="chrome-extension://…">` 注入 | 需要 WAR；且页面 CSP 是否拦截该 `<script>` 无官方结论 | E12/E5 `[未验证]` |

### 5.3 通信与生命周期类

| # | 失败/盲区 | 机制 | 证据 |
|---|---|---|---|
| F14 | 每个被拦截请求都要跨 world 通信 ⇒ 延迟与吞吐上限由通道决定 | MAIN world 无扩展 API；官方路径是 `postMessage` + `runtime` 消息 | E7/E14/E10 |
| F15 | SW 空闲 30 秒即终止 ⇒ 冷上下文唤醒 | 计时器由事件/API 调用重置；休眠时事件会唤醒 | E11/E36 |
| F16 | **唤醒延迟无官方数值** | 官方只描述生命周期与「事件唤醒」，未给任何延迟数字 | E11 `[未验证]` |
| F17 | 消息序列化踩坑 | Chrome 用 JSON 序列化：`ArrayBuffer`/`Map`/`Set`/`undefined`（→`null`）等行为与结构化克隆不同；上限 64 MiB | E10 |
| F18 | 无法序列化响应 ⇒ 发送侧 reject | 官方示例：`sendResponse(() => {})` → *"Error: Could not serialize message."* | E10 |
| F19 | port 断连 | 官方列出的 `onDisconnect` 原因含「对端无监听器」「帧/标签页卸载」；**SW 被终止是否断开 port 未在官方列出** | E10 `[未验证]` |
| F20 | port 不再保活 | Chrome 114 起「打开 port 不再重置计时器」，必须持续发消息 | E11 |
| F21 | 状态放 SW 全局 ⇒ SW 重启即丢 | 官方要求持久化，且 `storage.session` 是内存态、默认不对 content script 暴露 | E11/E35 |
| F22 | 页面导航/关闭 ⇒ MAIN world 里的转发器状态随之销毁 | 文档级上下文，注入不跨导航 | E1/E4 `[官方-间接]`；Q-D5 要求状态持久化在存储中 |
| F23 | 扩展更新后动态注册被清空 ⇒ 转发器「消失」 | 官方要求 `runtime.onInstalled` + `"update"` 分支重建 | E13 |
| F24 | `unregisterContentScripts` 不等于「卸载已注入的代码」 | 官方原文：不会移除已注入的脚本/样式 | E9 |
| F25 | `userScripts` 路线会引入用户开关（额外授权） | 未打开时 API 为 `undefined`，扩展上下文重载前状态还会残留 | E20 |
| F26 | offscreen 不能当注入点 | 它是扩展页、无页面 JS、且只能用 `runtime`；同时只能存在一个 | E21 |

### 5.4 安全类（官方明确警告）

- 页面对 MAIN world 代码 **可读可改可干扰**（E8/E14）；被服务的页面本身就是潜在对手。
- content script 被视为**较不可信**的上下文：官方建议 *"Assume that messages from a content script might have been crafted by an attacker and make sure to validate and sanitize all input."*（E10）—— 本项目的转发器情况更糟：**MAIN world 比 content script 更不可信**（页面可直接改写它）`[推断]`（依据 E8/E10）。
- `window.postMessage` 通道页面**同样能监听**（E7 官方示例自己就要求 `event.source !== window` 过滤）。

---

## 6 与现有裁定的冲突

| 裁定 | 与本文事实的关系 | 结论 / 需带走的输入 |
|---|---|---|
| **R4.1**「尽可能多地拦截各种来源：每一个浏览器标签页、MAIN WORLD 的注入脚本」 | 「每一个标签页」在技术上**不可能完全达成**：扩展自身页面、`chrome://`、PDF viewer、view-source 等不可注入（E13/E26）；页面内 Worker 无注入目标（E9） | 与 Q-D2 一致地**记录为盲区**；普通网页标签页可用「静态 + MAIN + document_start」全覆盖 |
| **R5**「内置 UI 不得走特殊通道；注入不进去时只换装载方式、不换调用路径」 | 官方事实支持这条裁定：扩展页面**确实**注入不进去（E13），而官方给出的替代方案正是「在页面里放脚本」（E13） | **转发器必须做成可独立装载的模块**：核心不得引用 `chrome.*`（MAIN world 没有，E14），只暴露「配置 + 传输适配器」接口；网页侧由 MAIN world content script 装载，扩展页侧由页面内 `<script>` 装载（§2.9） |
| **R9**「拦截发生在 JS API 层，不是网络层」 | 与「更早的 DNR」冲突，但裁定已明确选择 JS 层；代价即 H8/F2：`document_start` 之前的请求确实拦不到 | **不改变裁定**；把代价写进盲区（Q-D2） |
| **Q-D1**「现阶段只拦截一条精准匹配的 URL」 | 注入范围由 match pattern / glob 决定，**host 权限是 origin 粒度**（官方：host permissions 的 path 被忽略，E26）；内容脚本 `matches` 支持路径通配（`https://*/foo*`，E26） | 设计输入：**权限按 origin 申请（1 个 host），拦截判定按完整 URL**（在转发器内部比对）；精确路径匹配可用 `include_globs`（E8）进一步收窄注入面 |
| **Q-D2**「盲区必须明确列出」 | 本文 §5 已给出可入清单的条目（F1–F26） | 直接作为「拦截盲区清单」的素材 |
| **Q-D3**「WebSocket 第一版实现；允许转发器轮询 Mock 层（不依赖 SW 生命周期）」 | 轮询本身仍要跨 world 通信；SW 侧保活有官方依据：Chrome 114 起「发送长连接消息保持 SW 存活」（E11）；SW 内 WebSocket 消息自 Chrome 116 起重置计时器（E11） | 「不依赖 SW 生命周期」≠「SW 不参与」：**实际会有一次消息唤醒**；延迟无官方数值（F16），需实测 |
| **Q-D5**「SW 重启不模拟 aria2 重启 ⇒ 状态必须持久化」 | 与 SW 生命周期完全一致（E11）；额外提醒：MAIN world 转发器随页面销毁（F22），页面侧状态也不得作为唯一真值 | Mock 层状态一律落扩展存储；`storage.session` 不能用作「跨浏览器会话」的持久层（E35） |
| **R8**「服务对象只限浏览器内 JS 客户端」 | 一致：注入能覆盖的只有文档内的 JS（E1/E13） | 无冲突 |
| **§6 已接受风险 4**「`document_start` 之前已发出的请求是盲区」 | 本文把它从「断言」升级为「有官方依据的表述」：`document_start` 的定义只承诺脚本顺序，不承诺请求顺序（E4/E34） | 保持已接受 |
| **§6 已接受风险 4**「扩展页 CSP」 | 需区分两种 CSP：隔离世界用扩展 CSP、MAIN world 用页面 CSP（E5/E6）；扩展页 CSP 另有独立约束（E18） | 已在 §2.8 细化 |

**需要向后续设计传递的三条硬性输入**
1. 转发器核心**不得依赖扩展 API**（否则 MAIN world 跑不了）。
2. 装载方式允许「网页侧 = MAIN world content script」「扩展页侧 = 页面内脚本」，两者共用同一核心与同一拦截路径。
3. 时机下限 = `document_start`，且必须显式声明；无法覆盖更早的请求。

---

## 7 未验证

> 以下条目**没有**找到官方文档依据，后续必须实测或在详细设计中明确列为假设。

| # | 未验证项 | 为什么重要 | 建议验证方式 |
|---|---|---|---|
| U1 | MAIN world 注入的代码**是否会被页面 CSP 阻止执行**，以及具体拦到什么 | 直接决定能否在全网站（含严格 CSP 站点）工作 | 用 `script-src 'self'` 的测试页 + `world: "MAIN"` 注入，观察是否执行 |
| U2 | 用 `<script src="chrome-extension://…">`（WAR）注入时，页面 `script-src` 是否拦截该脚本 | 决定备选装载方式可用性 | 同上测试页 + WAR 注入 |
| U3 | `document_start` 与 **preload scanner** 抓取的真实先后 | 决定「第一个请求」边界 | DevTools Network + `document_start` 打点对照 |
| U4 | **预渲染（Speculation Rules）页面**里是否注入、以什么时机注入 | 影响「导航即命中」场景 | 官方无文档；用 prerender 测试页 + 扩展日志 |
| U5 | 跨 world 转移 `MessagePort`（`window.postMessage` + `transfer`）是否可用 | 决定是否有低延迟双向通道（对比每次 `runtime` 消息） | 隔离世界与 MAIN world 对测 |
| U6 | SW 被终止时既有 port 是否断开、重连需要多久 | 决定长连接方案是否可用 | 观察 `onDisconnect` + 计时 |
| U7 | SW 冷启动/消息唤醒的**延迟数值** | 官方无任何数值；影响 Q-D3 轮询周期设计 | 压测：`performance.now()` 跨端打点 |
| U8 | host 权限**未授予**时 `registerContentScripts` 的行为（报错 vs 注册成功但不注入） | 决定「先注册后授权」流程是否可行 | 未授权 host 上注册并观察 |
| U9 | 同一阶段内**跨 world** 的注入顺序（MAIN 与 ISOLATED 谁先） | 影响「桥」的初始化竞态 | 两个世界各打时间戳 |
| U10 | 能否向**扩展自己的页面**注入（`chrome://extensions` 之外的 `chrome-extension://`） | R5 的边界确认 | `executeScript` 指向扩展页，记录错误 |
| U11 | `chrome.scripting.executeScript` 对 `chrome://`、`view-source:` 的具体报错文本 | 便于把错误变成用户可见提示 | 逐一尝试并记录 `lastError` |
| U12 | 向页面内 **Worker / Worklet** 注入的任何可能 | Q-D2 要求「技术上能做到就拦」 | 官方无目标类型；尝试 `executeScript` 到 worker（预期不可） |
| U13 | 站点访问设为「点击时」后，`document_start` 内容脚本的实际行为在 **MV3** 下是否仍如 MV2 文档所述（需刷新） | 决定「运行时授权」后的用户引导文案 | 手测：受限站点上授权前后各注入一次 |
| U14 | `runtime.sendMessage` 从 content script 发往**休眠 SW** 的实际唤醒耗时分位 | 决定 RPC 响应时间承诺 | 压测（与 U7 合并） |
| U15 | MAIN world 里 `window.postMessage` 的**吞吐**上限 | 决定能否承载 WebSocket 轮询 | 基准测试 |
| U16 | MDN 与 Chrome 文档在 `onMessage` promise 返回上的分歧（MDN 标注 Chrome 不支持，Chrome 文档写 Chrome 148 起支持） | 决定异步回复写法 | 以 Chrome 官方为准；查本机 Chrome 版本实测（E10 vs E39） |
| U17 | 页面对 MAIN world 代码的**干扰/还原**在真实站点上的频率与手法 | 影响是否需要「只读锚点 + 幂等重装」之类的自保设计 | 站点抽样 + 实测 |

---

## 8 证据清单

> 全部 URL 于 **2026-10-06** 抓取。「版本」列只写官方页面文本中标注的版本要求，未标注则写「页面未标注」。

### E1 — Content scripts（Chrome 官方：隔离世界、变量互不可见、静态优先、run_at、postMessage 桥、WAR 提示、CSP）
URL: https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts

- *"Content scripts live in an isolated world, allowing a content script to make changes to its JavaScript environment without conflicting with the page or other extensions' content scripts."*
- *"**Key term:** An **isolated world** is a private execution environment that isn't accessible to the page or other extensions. A practical consequence of this isolation is that JavaScript variables in an extension's content scripts are not visible to the host page or other extensions' content scripts."*
- *"**Note:** Not only does each extension run in its own isolated world, but content scripts and the web page do too. This means that none of these (web page, content scripts, and any running extensions) can access the context and variables of the others."*
- 版本：页面未标注（页首附注：*"Chrome now supports the standardized `browser.*` namespace (available from Chrome 148)"*）

### E2 — 同上页面：内容脚本可直接访问的扩展 API 白名单
- *"Content scripts can access the following extension APIs directly:"* 官方列表项（逐条照抄）：`dom` / `i18n` / `storage` / `runtime.connect()` / `runtime.getManifest()` / `runtime.getURL()` / `runtime.id` / `runtime.onConnect` / `runtime.onMessage` / `runtime.sendMessage()`
- *"Content scripts are unable to access other APIs directly. But they can access them indirectly by exchanging messages with other parts of your extension."*

### E3 — 同上页面：同一阶段内的注入优先级
- *"Within a given stage of the document lifecycle, content scripts declared statically in the manifest are the first to be injected, before content scripts registered in any other way. They are injected in the order in which they are specified in the manifest."*

### E4 — 同上页面：`run_at` 三值定义
- `document_idle`（默认）：*"Preferred. Use `"document_idle"` whenever possible. The browser chooses a time to inject scripts between `"document_end"` and immediately after the `window.onload` event fires. The exact moment of injection depends on how complex the document is and how long it is taking to load, and is optimized for page load speed."*
- `document_start`：*"Scripts are injected after any files from `css`, but before any other DOM is constructed or any other script is run."*
- `document_end`：*"Scripts are injected immediately after the DOM is complete, but before subresources like images and frames have loaded."*

### E5 — 同上页面：MAIN world 与页面 CSP
- *"When a content script is injected into the main world, the CSP of the page applies."*

### E6 — 同上页面：隔离世界的 CSP、`eval` 限制、扩展资源与 WAR
- *"Content scripts running in isolated worlds have the following Content Security Policy (CSP): `script-src 'self' 'wasm-unsafe-eval' 'inline-speculation-rules' chrome-extension://abcdefghijklmopqrstuvwxyz/; object-src 'self';`"*
- *"Similar to the restrictions applied to other extension contexts, this prevents the use of `eval()` as well as loading external scripts."*
- *"You can also access other files in your extension from a content script, using APIs like `fetch()`. To do this, you need to declare them as web-accessible resources. Note that this also exposes the resources to any first-party or third-party scripts running on the same site."*

### E7 — 同上页面：与宿主页面通信（共享 DOM / `window.postMessage`）
- *"Although the execution environments of content scripts and the pages that host them are isolated from each other, they share access to the page's DOM. If the page wishes to communicate with the content script, or with the extension through the content script, it must do so through the shared DOM."*
- 官方示例中桥接侧第一条判断即 `// We only accept messages from ourselves` + `if (event.source !== window) return;`

### E8 — Manifest - content scripts（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/reference/manifest/content-scripts

- `"world"` — `ISOLATED | MAIN`：*"Optional. The JavaScript world for a script to execute within. Defaults to `"ISOLATED"`, which is the execution environment unique to the content script. Choosing the `"MAIN"` world means the script will share the execution environment with the host page's JavaScript."*
- **Warning**：*"There are risks involved when using the `"MAIN"` world. The host page can access and interfere with the injected script."*
- `run_at`：*"`"document_start"`: the DOM is still loading. `"document_end"`: the page's resources are still loading. `"document_idle"`: the DOM and resources have finished loading. This is the default."*
- `all_frames` 默认 `false`；`match_about_blank` 默认 `false`；`match_origin_as_fallback` 默认 `false`（覆盖 `about:`/`data:`/`blob:`/`filesystem:`）
- 版本：**页面未逐字段标注版本**（`world` 的 Chrome 版本见 E28）

### E9 — browser.scripting（Chrome 官方 API 参考）
URL: https://developer.chrome.com/docs/extensions/reference/api/scripting

- **Permissions**：`scripting`；**Manifest**：*"To use the `browser.scripting` API, declare the `"scripting"` permission in the manifest plus the host permissions for the pages to inject scripts into. Use the `"host_permissions"` key or the `"activeTab"` permission, which grants temporary host permissions."*
- `ExecutionWorld`（**Chrome 95+**）：*"`"ISOLATED"` — Specifies the isolated world, which is the execution environment unique to this extension. `"MAIN"` — Specifies the main world of the DOM, which is the execution environment shared with the host page's JavaScript."*
- `RegisteredContentScript.world`：**Chrome 102+**，*"The JavaScript "world" to run the script in. Defaults to `ISOLATED`."*
- `RegisteredContentScript.persistAcrossSessions`：*"Specifies if this content script will persist into future sessions. The default is true."*
- `RegisteredContentScript.matches`：*"Must be specified for `registerContentScripts`."*
- `ScriptInjection.injectImmediately`（**Chrome 102+**）：*"Whether the injection should be triggered in the target as soon as possible. Note that this is not a guarantee that injection will occur prior to page load, as the page may have already loaded by the time the script reaches the target."*
- `executeScript()`：*"Injects a script into a target context. By default, the script will be run at `document_idle`, or immediately if the page has already loaded."*
- `ScriptInjection.func`：*"This function will be serialized, and then deserialized for injection. This means that any bound parameters and execution context will be lost."*；`args`：*"These arguments must be JSON-serializable."*
- `registerContentScripts()`：*"If there are errors during script parsing/file validation, or if the IDs specified already exist, then no scripts are registered."*
- `unregisterContentScripts()`：*"Key point: Unregistering content scripts will not remove scripts or styles that have already been injected."*
- `matchOriginAsFallback`：**Chrome 119+**；`InjectionTarget` 只接受 `tabId` / `frameIds` / `documentIds`（均为文档级目标）
- 版本：`scripting` API 本体 **Chrome 88+ / MV3+**

### E10 — Message passing（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/develop/concepts/messaging

- *"These methods let you send a one-time JSON-serializable message from a content script to the extension, or from the extension to a content script."*
- **Serialization**：*"In Chrome, the message passing APIs use JSON serialization. Notably, this is different to other browsers which implement the same APIs with the structured clone algorithm. This means a message (and responses provided by recipients) can contain any valid `JSON.stringify()` value. Other values will be coerced into serializable values (notably `undefined` will be serialized as `null`);"*
- **Message size limits**：*"The maximum size of a message is 64 MiB."*
- **Port lifetime**：`onDisconnect` 触发原因清单（对端无 `onConnect` 监听器 / 标签页卸载 / 帧卸载 / 接收端帧全部卸载 / 对端 `disconnect()`）；*"Warning: Be aware that a Port can have multiple receivers connected at any given time. As a result, `onDisconnect` may fire more than once…"*
- **异步回复**：*"By default, the `sendResponse` callback must be called synchronously."*；`return true` 保持通道；*"From Chrome 148, you can return a promise from a message listener to respond asynchronously."*
- **错误处理**：*"From Chrome 146, if an `onMessage` listener throws an error … the promise returned by `sendMessage()` in the sender will reject with the error's message."*；序列化失败示例：*"`console.log(e.message); // "Error: Could not serialize message."`"*
- **Send messages from web pages**：*"To send messages from a web page to an extension, specify in your `manifest.json` which websites you want to allow messages from using the `"externally_connectable"` manifest key."*；*"This exposes the messaging API to any page that matches the match patterns you specify."*；*"It is not possible to send a message from an extension to a web page."*
- **Security**：*"Content scripts are less trustworthy than the extension service worker. … Assume that messages from a content script might have been crafted by an attacker and make sure to validate and sanitize all input."*
- 版本：`browser.*` 命名空间自 Chrome 148；promise 监听器 Chrome 148；抛错传播 Chrome 146

### E11 — The extension service worker lifecycle（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle

- **Idle and shutdown**：*"After 30 seconds of inactivity. Receiving an event or calling an extension API resets this timer."* / *"When a single request, such as an event or API call, takes longer than 5 minutes to process."* / *"When a `fetch()` response takes more than 30 seconds to arrive."*
- *"Events and calls to extension APIs reset these timers, and if the service worker has gone dormant, an incoming event will revive them. Nevertheless, you should design your service worker to be resilient against unexpected termination."*
- *"Any global variables you set will be lost if the service worker shuts down. Instead of using global variables, save values to storage."*
- 版本变更：**Chrome 120** alarms 最小周期 30s；**Chrome 118** debugger 会话保活；**Chrome 116** WebSocket 收发消息重置空闲计时器；**Chrome 114** *"Sending a message with long-lived messaging keeps the service worker alive. Opening a port no longer resets the timers."*；**Chrome 110** *"Extension API calls reset the timers."*；**Chrome 109** offscreen 消息重置计时器；**Chrome 105** `connectNative` 保活

### E12 — Manifest - Web Accessible Resources（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/reference/manifest/web-accessible-resources

- *"Web-accessible resources are files inside an extension that can be accessed by web pages or other extensions."*
- *"By default no resources are web accessible, as this allows a malicious website to fingerprint extensions that a user has installed or exploit vulnerabilities … in installed extensions."*
- *"Resources are available in a webpage via the URL `chrome-extension://[PACKAGE ID]/[PATH]`, which can be generated with the `runtime.getURL()` method. The resources are served with appropriate CORS headers, so they're available via `fetch()`."*
- *"**Content scripts themselves do not need to be allowed.**"*
- `"matches"`：*"Only the origin is used to match URLs. Origins include subdomain matching. Google Chrome emits an "Invalid match pattern" error if the pattern has a path other than '/*'."*；`use_dynamic_url`：*"A dynamic ID is generated per session. That means it is regenerated when the browser restarts or the extension reloads."*

### E13 — MDN: Content scripts（WebExtensions）
URL: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Content_scripts

- *"Registered content scripts are only executed if the extension is granted host permissions for the domain."*
- *"Extensions cannot inject content scripts into privileged browser UI pages (such as about:debugging, about:addons, reader view, view-source, or the PDF viewer) or extension pages."*
- 官方替代方式：*"If an extension wants to run code in an extension page dynamically, it can include a script in the page. This script contains the code to run and registers a `runtime.onMessage` listener that implements a way to execute the code. The extension can then send a message to the listener to trigger the code's execution."*
- *"Content scripts cannot see JavaScript variables defined by page scripts."* / *"If a page script redefines a built-in DOM property, the content script sees the original version of the property, not the redefined version."* / *"In Chrome this behavior is enforced through an isolated world, which uses a fundamentally different approach."*
- `matchOriginAsFallback`：*"By default, content scripts do not run in about:blank, about:srcdoc, data:, and blob: pages. To enable their execution, use the `match_origin_as_fallback` option…"*；另有 Chrome 企业策略 *"runtime_blocked_hosts"*
- 版本：MDN 页面未逐条标注 Chrome 版本

### E14 — MDN: scripting.ExecutionWorld
URL: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/scripting/ExecutionWorld

- `ISOLATED`：*"The default content scripts execution environment. This environment is isolated from the page's context: while they share the same document, the global scopes and available APIs differ."*
- `MAIN`：*"The web page execution environment. This environment is shared with the web page without isolation. Scripts in this environment do not have any access to APIs that are only available to content scripts."*
- **Warning**：*"Due to the lack of isolation, the web page can detect and interfere with the executed code. Do not use the MAIN world unless it is acceptable for web pages to read, access, or modify the logic or data that flows through the executed code."*

### E15 — MDN: manifest.json / content_scripts
URL: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/content_scripts

- `world`：*"`"MAIN"` — The web page's execution environment. This environment is shared with the web page without isolation. Scripts in this environment don't have any access to the APIs that are only available to content scripts."* + 同一 **Warning**（同 E14）；*"The default value is `"ISOLATED"`."*
- `run_at`：*"The default value is `"document_idle"`."*；*"In all cases, files in `js` are injected after files in `css`."*

### E16 — MDN: manifest.json / web_accessible_resources
URL: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/web_accessible_resources

- *"Note that content scripts don't need to be listed as web accessible resources."*
- MV3 结构：`resources` +（`matches` 或 `extension_ids`）；Chrome 下 *"the path must be set to `/*`"*；`use_dynamic_url`：*"The dynamic ID is generated per session and regenerated on browser restart or extension reload."*

### E17 — MDN: 扩展 Content Security Policy
URL: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Content_Security_Policy

- *"As of Manifest V3, content scripts share the default CSP as extensions. It is currently not possible to specify a separate CSP for content scripts"*（原文此句后附来源链接标记 `(source)`）
- *"The extent to which the CSP controls loads from content scripts varies by browser. In Firefox, JavaScript features such as eval are restricted by the extension CSP. Generally, most DOM-based APIs are subjected to the CSP of the web page. In Chrome, many DOM APIs are covered by the extension CSP instead of the web page's CSP (crbug 896041)."*

### E18 — Manifest - Content Security Policy（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/reference/manifest/content-security-policy

- 默认：`{"extension_pages": "script-src 'self'; object-src 'self';", "sandbox": "sandbox allow-scripts allow-forms allow-popups allow-modals; script-src 'self' 'unsafe-inline' 'unsafe-eval'; child-src 'self';"}`
- *"Chrome enforces a minimum content security policy for extension pages. It is equivalent to specifying the following policy in your manifest: `{"extension_pages": "script-src 'self' 'wasm-unsafe-eval'; object-src 'self';"}` … The extension_pages policy cannot be relaxed beyond this minimum value."*
- *"The sandbox content security policy can be customized as needed."*（sandbox 页**没有**扩展 API）

### E19 — Improve extension security（Chrome 官方，MV3 迁移指南）
URL: https://developer.chrome.com/docs/extensions/develop/migrate/improve-security

- *"You can no longer execute external logic using `executeScript()`, `eval()`, and `new Function()`."* / *"In Manifest V3, all of your extension's logic must be part of the extension package."*
- *"The `script-src`, `object-src`, and `worker-src` directives may only have the following values: `self`, `none`, `wasm-unsafe-eval`, Unpacked extensions only: any localhost source"`
- `"extension_pages"`：*"Refers to contexts in your extension, including html files and service workers."*

### E20 — browser.userScripts（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/reference/api/userScripts

- 需要 `userScripts` 权限（**Chrome 120+**）；*"Unlike other extension features, such as Content Scripts and the `browser.scripting` API, the User Scripts API lets you run arbitrary code."*
- *"After your extension receives the permission to use the userScripts API, users must enable a specific toggle to allow your extension to use the API."*；**Chrome 138 及以上**：*"The `Allow User Scripts` toggle is on each extension's details page"*；**138 之前**：*"Your users must also enable Developer mode."*
- 未打开时：*"If the `Allow User Scripts` toggle is not enabled, `browser.userScripts` is `undefined`."*
- 世界选择：*"To select the world, pass `"USER_SCRIPT"` or `"MAIN"` when calling `userScripts.register()`."*
- 通信用专用事件：*"These handlers are called `runtime.onUserScriptMessage` and `runtime.onUserScriptConnect`."* + *"Before sending a message, you must call `configureWorld()` with the `messaging` argument set to `true`."*
- *"User scripts are cleared when an extension updates. You can add them back by running code in the `runtime.onInstalled` event handler … Respond only to the `"update"` reason…"*

### E21 — browser.offscreen（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/reference/api/offscreen

- *"Service workers don't have DOM access, and many websites have content security policies that limit the functionality of content scripts. The Offscreen API allows the extension to use DOM APIs in a hidden document without interrupting the user experience by opening new windows or tabs."*
- *"The `runtime` API is the only extensions API supported by offscreen documents."*
- *"Though an extension package can contain multiple offscreen documents, an installed extension can only have one open at a time."*
- 版本：**Chrome 109+ / MV3+**；`runtime.getContexts()` **Chrome 116+**

### E22 — browser.permissions（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/reference/api/permissions

- *"Permissions must be requested from inside a user gesture, like a button's click handler."*（官方示例中的代码注释，原文每行带 `//` 注释符）
- *"These permissions must either be defined in the `optional_permissions` field of the manifest or be required permissions that were withheld by the user. Paths on origin patterns will be ignored."*
- *"Easier upgrades: When you upgrade your extension, Chrome won't disable it for your users if the upgrade adds optional rather than required permissions."*
- `addHostAccessRequest()`（**Chrome 133+**）：*"Adds a host access request. Request will only be signaled to the user if extension can be granted access to the host in the request. Request will be reset on cross-origin navigation."*
- `contains()`：用于检查是否已获某 origin 的权限

### E23 — Declare permissions（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions

- host 权限用途清单包含 *"Inject a content script programmatically."*；特例清单包含 *"Allowing the injection of a content script declared in the manifest."*
- *"Adding or changing match patterns in the `"host_permissions"` and `"content_scripts.matches"` fields of the manifest file will also trigger a warning."*
- *"If your extension needs to run on `file://` URLs or operate in incognito mode, users must give the extension access on its details page."*

### E24 — Google Chrome 官方帮助：站点访问控制（用户视角）
URL: https://support.google.com/chrome_webstore/answer/2664769

- *"Allow site access: On the extension, select Details. Next to "Allow this extension to read and change all your data on websites you visit," change the extension's site access to On select, On specific sites, or On all sites."*
- 三种授予方式：*"When you select the extension: … only allows the extension to access the current site in the open tab or window when you select the extension. If you close the tab or window, you'll have to select the extension to turn it on again."* / *"On [current site]"* / *"On all sites"*
- *"When you grant or cancel these permissions, it will only affect extension sites that match the extension's host permissions."*

### E25 — User controls for host permissions: transition guide（Chrome 官方；**页面标注 Manifest V2**）
URL: https://developer.chrome.com/docs/extensions/mv2/runtime-host-permissions

- *"Beginning in Chrome 70, users have the ability to restrict extension host access to a custom list of sites, or to configure extensions to require a click to gain access to the current page."*
- *"What happens if a user chooses to run my extension "on click"? The extension essentially behaves as though it used the `activeTab` permission."*
- **内容脚本与时机**：*"The extension can still inject scripts and style sheets automatically for any sites it has access to. … If the content script was set to inject at `document_idle`, the script will inject immediately. Otherwise, Chrome prompts the user to refresh the page to allow your extension to inject scripts earlier in page load (at `document_start` or `document_end`)."*
- *"You can use the `permissions.contains()` API in order to check whether your extension has been granted access to a given origin."*
- 版本：页面顶部标注 *"Warning: The Chrome Web Store no longer accepts Manifest V2 extensions."*（MV3 下是否逐字一致 `[未验证]`）

### E26 — Match patterns（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns

- *"scheme: Must be one of the following, separated from the rest of the pattern using a colon followed by a double slash (`://`):"* 后接列表项 `http` / `https` / `*`（*"A wildcard `*`, which matches only http or https"*）/ `file`（**不含 `chrome-extension`**）
- *"path: A URL path (/example). For host permissions, the path is required but ignored. The wildcard (/*) should be used by convention."*
- 路径通配示例：*"`https://*/foo*` Matches any URL using the https scheme, on any host, with a path that starts with foo."*
- `file:///` 需要用户手动授权；`<all_urls>` 覆盖所有受支持 scheme

### E27 — What's new in Chrome extensions（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/whats-new

- **Chrome 95**：*"The `chrome.scripting` API's `executeScript()` method can now inject scripts directly into a page's main world. Previously, extensions could only inject directly into the extension's isolated world."*
- **Chrome 102（2022-04-14）**：*"Dynamically registered content scripts can now specify the world that assets will be injected into."*
- **Chrome 102（2022-04-04）**：*"Manifest V3 extensions can now specify the `optional_host_permissions` key…"*

### E28 — MDN browser-compat-data：`manifest.content_scripts.world`
URL: https://raw.githubusercontent.com/mdn/browser-compat-data/main/webextensions/manifest/content_scripts.json

- `world` → `support.chrome.version_added = "111"`；`run_at` → `"≤72"`；`match_origin_as_fallback` → `"99"`
- 说明：这是 MDN 兼容性表的数据源（MDN 官方仓库），用来补 Chrome 参考页缺失的版本号

### E29 — chrome.extensionTypes: `RunAt`（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/reference/api/extensionTypes

- `RunAt` 类型：*"The soonest that the JavaScript or CSS will be injected into the tab."*（属性 `runAt`：*"The soonest that the JavaScript or CSS will be injected into the tab. Defaults to `"document_idle"`."*）；该参考页在类型标题处标注 **Chrome 44+**
- 三值定义原文同 E4

### E30 — browser.declarativeNetRequest（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest

- 动作集合（官方为 5 条列表项，逐条照抄）：*"Block a network request."* / *"Upgrade the schema (http to https)."* / *"Prevent a request from getting blocked by negating any matching blocked rules."* / *"Redirect a network request."* / *"Modify request or response headers."*
- *"DNR rules are applied by the browser across various stages of the network request lifecycle."*（官方小节标题为 "Before the request"）*"Before a request is made, an extension can block or redirect (including upgrading the scheme from HTTP to HTTPS) it with a matching rule."*
- *"A declarativeNetRequest only applies to requests that reach the network stack. This includes responses from the HTTP cache, but may not include responses that go through a service worker's `onfetch` handler. declarativeNetRequest won't affect responses generated by the service worker or retrieved from CacheStorage, but it will affect calls to `fetch()` made in a service worker."*
- *"A declarativeNetRequest rule cannot redirect from a public resource request to a resource that is not web accessible."*
- 权限：`declarativeNetRequest` / `declarativeNetRequestWithHostAccess`；**Chrome 84+**

### E31 — browser.webRequest（Chrome 官方，MV3 能力退化）
URL: https://developer.chrome.com/docs/extensions/reference/api/webRequest

- *"As of Manifest V3, the "webRequestBlocking" permission is no longer available for most extensions. Consider "declarativeNetRequest", which enables use the declarativeNetRequest API."* / *"Policy installed extensions can continue to use "webRequestBlocking"."*
- 观察型使用仍可用：*"the webRequest API is unchanged and available for normal use"*；阻止/修改需要 blocking 权限

### E32 — browser.webNavigation（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/reference/api/webNavigation

- `onBeforeNavigate`：*"Fired when a navigation is about to occur."*（**未**说明与页面脚本执行的先后）
- *"There is no defined ordering between events of the webRequest API and the events of the webNavigation API."*
- 事件顺序：`onBeforeNavigate -> onCommitted -> [onDOMContentLoaded] -> onCompleted`；引入 `documentId` 区分文档生命周期

### E33 — Chrome Extensions: Extending API to support Instant Navigation（Chrome 官方博客）
URL: https://developer.chrome.com/blog/extension-instantnav

- *"Since a tab can now have multiple outermost frames (prerendered and cached pages), the assumption that there is a single outermost frame for a tab is incorrect."* / *"`frameId == 0` will still continue to represent the outermost frame of the active page, but the outermost frames of other pages in the same tab will be non-zero."*
- `DocumentLifecycle` 取值：`"prerender"` / `"active"` / `"cached"` / `"pending_deletion"`；*"For a very first navigation of any page you will see four events … Note that these four events could occur with the DocumentLifecycle state being either `"prerender"` or `"active"`."*
- 预渲染页激活时：`onBeforeNavigate → onCommitted → onCompleted`，*"except for the onDOMContentLoaded event because the page has already been loaded"*
- 关联页面：https://developer.chrome.com/docs/web-platform/prerender-pages （该页 "Impact on extensions" 小节指向：*"See the dedicated post on Chrome Extensions: Extending API to support Instant Navigation"*）

### E34 — Don't fight the browser preload scanner（web.dev，Chrome 团队）
URL: https://web.dev/articles/preload-scanner

- *"browsers do their best to mitigate these problems by way of a secondary HTML parser called a preload scanner."*
- *"A preload scanner's role is speculative, meaning that it examines raw markup in order to find resources to opportunistically fetch before the primary HTML parser would otherwise discover them."*
- *"the preload scanner can look ahead in the raw markup to find that image resource and begin loading it before the primary HTML parser is unblocked."*

### E35 — chrome.storage（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/reference/api/storage + https://developer.chrome.com/docs/extensions/reference/api/storage/StorageArea

- *"Session storage holds data in memory while an extension is loaded. The storage is cleared if the extension is disabled, reloaded, updated, and when the browser restarts. By default, it's not exposed to content scripts, but this behavior can be changed by calling `browser.storage.session.setAccessLevel()`."*
- `setAccessLevel()`（**Chrome 102+**）：*"By default, session storage is restricted to trusted contexts (extension pages and service workers), while managed, local, and sync storage allow access from both trusted and untrusted contexts."*
- *"Extension service workers can't use the Web Storage API."*；*"Content scripts share storage with the host page."*（此处指 `localStorage`）
- 版本：`storage.session` 与 `setAccessLevel()` 均标注 **Chrome 102+**

### E36 — Real time updates（Chrome 官方）
URL: https://developer.chrome.com/docs/extensions/develop/concepts/real-time

- *"Chrome suspends extensions that are not being used after 30 seconds. A number of heuristics goes into Chrome determining if the extension is "being used", one of which is an active WebSocket connection. Chrome won't suspend an extension that has sent or received a WebSocket message in the last 30 seconds."*
- *"Chrome has no way to wake up your extension when a Websocket connection is started outside of your extension."*

### E37 — MDN: Window.postMessage
URL: https://developer.mozilla.org/en-US/docs/Web/API/Window/postMessage

- `transfer` 可选参数用于转移 `MessagePort` 等可转移对象；消息按结构化克隆算法传递（函数、DOM 节点不可克隆）
- 版本：MDN 页面**未**针对「扩展世界边界」作任何说明

### E38 — MDN: runtime.connect
URL: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/runtime/connect

- *"You can call this:"*（后接列表项）*"in an extension's content scripts, to establish a connection with the extension's background scripts (or similarly privileged scripts, like popup scripts or options page scripts)."*；*"Note that you can't use this function to connect an extension to its content scripts. To do this, use `tabs.connect()`."*；*"The port's `onDisconnect` event is fired if the extension does not exist."*

### E39 — MDN: runtime.onMessage
URL: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/runtime/onMessage

- `message` / `sendResponse` 参数：*"This is a serializable object (see Data cloning algorithm)."*
- *"Note: Promise as a return value is not supported in Chrome until Chrome bug 1185241 is resolved. As an alternative, return `true` and use `sendResponse`."* —— **与 Chrome 官方文档（E10：Chrome 148 起支持 promise）不一致，属 MDN 过时内容，以 Chrome 官方为准**

---

## 附：本文对「能力清单 / 详细设计」的直接输入（速查）

1. **主力注入**：`manifest.content_scripts` = `{ matches: [<用户配置 URL 的 origin 模式>], js: [forwarder-main.js], run_at: "document_start", world: "MAIN", all_frames: true/false }`（`all_frames` 依 Q-D2 的 iframe 取舍）。
2. **动态补充**：`chrome.scripting.registerContentScripts([{ id, matches, js, runAt: "document_start", world: "MAIN", persistAcrossSessions: true }])`，权限 `scripting` + host（建议 optional + 用户手势授权）；`runtime.onInstalled("update")` 重建。
3. **时机下限**：`document_start`；`document_start` 之前的请求为已接受盲区。
4. **桥**：ISOLATED world 薄桥（`window.postMessage` ↔ `runtime.sendMessage`/`connect`）+ MAIN world 核心；消息在 Chrome 上是 JSON 序列化，二进制需自行编码。
5. **R5**：内置 UI 页面用页面内 `<script>` 装载同一核心；核心禁止引用 `chrome.*`；两种装载共用一个「配置 + 传输适配器」接口。
6. **最大风险**：SW 30 秒空闲终止带来的唤醒/延迟/断连（无官方延迟数值）＋ MAIN world 无扩展 API 导致的强跨 world 依赖＋页面 CSP 对 MAIN world 的未知影响（U1）。
