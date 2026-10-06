# 转发器构造方案（实测版）

| 项 | 值 |
|---|---|
| 文档类别 | **构造方案**（由实测确定，非推导） |
| 日期 | 2026-10-06 |
| 证据基础 | `docs/research/experiments/E-websocket-interceptor-fidelity.md` + `docs/research/forwarders/F1–F5` |
| 验证环境 | Chrome for Testing **148.0.7778.96**，xvfb / headless，未打包 MV3 扩展 |
| 与概念文档的关系 | 本文实现 `concept-design.md` 的**第一层（用户入口层·转发器）** |
| 重要限定 | 每个数字标注出处。**未实测的一律标明"未测"。** |

---

## 1. 一句话结论

**注入层自研，拦截层复用两个库。**

```
注入层   manifest 静态 content_scripts + world:"MAIN" + run_at:"document_start"
         └─ 两个库都不提供，必须自研
拦截层   fetch / XHR → @mswjs/interceptors（pin 死版本）
         WebSocket  → vista 的 interceptWebSocket，但必须 fork 并修 7 处
桥       ISOLATED world content script + window.postMessage
         └─ MAIN world 拿不到任何 chrome.* API，这是必经之路
```

**这是唯一可行形态**，理由见 §2。

---

## 2. 为什么是"JS 层"且只有这一条路

| 途径 | 能否"凭空回答一个请求" | 判决 |
|---|---|---|
| **MAIN world + JS 层 patch** | ✅ 能，零用户可见成本 | ✅ **唯一正路** |
| `declarativeNetRequest` | ❌ **结构上不可能**：`RuleActionType` 六个值（block/redirect/allow/allowAllRequests/upgradeScheme/modifyHeaders）里没有任何字段能承载响应体 | 出局 |
| DNR 重定向到扩展资源当响应体 | ❌ Fetch 标准：`locationURL` 非 HTTP(S) scheme → 直接 `network error` | 出局 |
| DNR 重定向替换 SW 脚本 | ❌ 规范对该请求明写 `redirect mode = "error"` | 出局 |
| MV3 观测型 `webRequest` | ❌ 只读（写 blocking 监听器会报只对 `ExtensionInstallForcelist` 放行） | 出局 |
| MV2 blocking `webRequest` | 曾能用 `data:` 重定向合成响应体，但 **Chrome 138 最后支持、139 移除企业豁免、2026-08-31 CWS 清空 MV2** | 已死 |
| `chrome.debugger` + CDP `Fetch.fulfillRequest` | ✅ 能返回任意 body | ⚠️ 可作可选高级模式，**不作默认**：必然弹"正在调试此浏览器"提示条、**按 F12 就被踢掉**、单调试器、企业策略可封 |

**`chrome.debugger` 的定位（需用户裁定）**：仅作观测通道（Q-D6 控制台），还是允许作为网络层兜底拦截？后者与 R9 字面冲突。

---

## 3. 注入层（自研，唯一路径）

### 3.1 推荐形态

**manifest 静态声明 `content_scripts` + `world:"MAIN"` + `run_at:"document_start"`。**

两个**默认值陷阱**必须显式覆盖：默认 `world = ISOLATED`、默认 `run_at = document_idle`。

官方依据：**同一生命周期阶段内，静态声明的脚本最先注入**（"content scripts declared statically in the manifest are the first to be injected, before content scripts registered in any other way"）。动态 `chrome.scripting.registerContentScripts` 在同一 stage 里排在静态声明之后，因此只在"需要按用户配置动态增删匹配范围"时才用——本项目 Q-D1 只支持一条固定 URL，**静态声明足够**。

> **注意**：程序化 `executeScript` 默认 `document_idle`，`injectImmediately` 官方明说**不保证早于页面加载**。所以主力必须是静态声明。

### 3.2 时机的下限与边界

- **`document_start` 是 JS 层能拿到的最早时机**（官方定义：任何其它脚本执行之前）
- **但官方不承诺"注入前没有请求"**——导航请求、preload scanner 抓取的子资源、其它文档的请求都可能更早。**这是已接受的盲区。**
- 比 `document_start` 更早只有网络层 DNR，而 DNR 已被 §2 排除

### 3.3 CSP —— 最大的风险已实测排除

Chrome 文档写着"When a content script is injected into the main world, the CSP of the page applies."，这曾是本项目的**第一优先级 POC 风险**。

**实测结论：不挡。** 严格 CSP 页（`default-src 'self'; script-src 'self'`，同页内联脚本确实被拦 = CSP 生效对照）上，MAIN world 注入**照常成功**，页面的 `fetch` / `XHR` / `WebSocket` 全部被改写并拿到伪造响应；同样的 bundle 装进 `world:"ISOLATED"` 则**完全无效**（页面 API 保持原生）。

⇒ 那句 CSP 说的是注入脚本**能做什么**（eval / 内联 / 远程脚本），**不是能否注入、能否改全局**。

**反过来还有一条对我们有利的实测**：**严格 CSP 页上原生 WebSocket 通道根本不可用**——`connect-src` 回落 `'self'`，`new WebSocket()` 返回时 `readyState` 已经是 3（直接死）。而 MAIN world 的 mock 路径能正常握手（`0 → 1`）。**在那类页面上，我们的伪造是唯一能工作的 WS。**

### 3.4 仍然成立的两条代价

1. **`document_start` 是"文档承诺的 stage 顺序"，不是"相对任意页面脚本的绝对保证"**。晚注入会被页面的"早期捕获"绕过——**实测活证**：`angular-websocket` 在模块求值时就 `Socket = Socket || window.WebSocket`，晚一步整条 WS 通道漏网。
2. **"The host page can access and interfere with the injected script."**（Chrome manifest 文档原文）——**页面可以检测甚至拆掉我们的 patch**。这与 §8 的反检测弱点叠加，无法根除。

---

## 4. 跨 world 桥（必经之路）

**MAIN world 拿不到任何扩展 API**（`chrome.runtime` 等一律不可用）。所以：

- 上行用**共享 DOM**：官方路径是 `window.postMessage`（下行不能用 `externally_connectable`——官方明确"不能从扩展向网页发消息"）
- 消息在 Chrome 是 **JSON 序列化**（不是结构化克隆），**上限 64 MiB** ⇒ **不能用来搬二进制**
- 另一侧是 ISOLATED world content script，它再把命中信息与响应体交给扩展后台

**生命周期约束**：MV3 SW 空闲 30 秒被终止；**Chrome 114 起"打开 port 不再重置计时器"**，需持续发消息保活；**官方没有给出任何唤醒延迟数值**。⇒ 每个 RPC 都可能唤醒冷上下文，**这是本项目最大的工程风险，且无官方数据可依**。

（Q-D3 已裁定：转发器**轮询** Mock 层来近似推送，不依赖 SW 生命周期；Q-D5 已裁定状态必须持久化。）

---

## 5. 拦截层选型

### 5.1 fetch 与 XHR

**`@mswjs/interceptors`** 的 `FetchInterceptor` / `XMLHttpRequestInterceptor`。

- 它就是 `patch globalThis.fetch` + `Proxy XMLHttpRequest`，**与 R9「JS API 层短路」严格同向**
- msw 的 SW 路线下请求**真的会发到网络**（这正是 msw 宣传的"能在 DevTools 里看见"），**违反 R9**——所以只取拦截器，不取 SW
- 必须 **pin 死确切版本**：0.x、ESM-only、`engines.node>=22`、发布节奏约 **1.8 天/版**、**单维护者**
- **打包要求**：必须打包成扩展内的单文件 IIFE（MAIN world 注入要求单文件），**不能用 `executeScript({func})` 传函数**——序列化会丢掉闭包里的 `realFetch`

### 5.2 WebSocket

**判决：用 `vista`（`@rxliuli/vista`）的 `interceptWebSocket`，但必须 fork 并修 7 处。**

**为什么不用 msw 的 `WebSocketInterceptor`**——它在本题的硬需求"**未命中原样放行**"上实测不保真：

| 场景 | 原生 | msw | vista |
|---|---|---|---|
| 未命中的请求 | `readyState=0`，**无任何事件** | **`open@0` + `readyState=1`** | 与原生一致 |
| `'not a url'` | `error → close 1006 (wasClean:`**`false`**`)` | `open@1 → error → close 1006 (wasClean:`**`true`**`)` | 与原生一致 |
| `send()` 在 `CONNECTING` 调用 | 抛 `InvalidStateError`，**连接不受影响** | 抛的 `DOMException.name` 是 `"Error"`，且 **`readyState` 立刻 `0→2→3`，派发 `close 1000/wasClean:true`** | 与原生逐字一致 |
| `Object.keys(window)` 含 `WebSocket` | `false` | **`true`**（还把 `WebSocket` 变 enumerable，并塞 `__MSW_INTERCEPTORS_REGISTRY`） | `false` |
| 每页 `apply()` 次数 | — | **只能一次**（第二次抛 `Invariant Violation: already replaced.`） | 可重复（可 cancel 还原） |

⇒ **"命中就伪造、未命中原样放行"是写死的需求，msw 直接违背。**

**为什么 vista 的缺陷只能靠 fork 修**：实测 vista 的 middleware 上下文只有 **9 个固定键**（`onClientMessage, onClose, onOpen, onServerMessage, protocols, sendToClient, sendToServer, type, url`），`hasSocketLike: []`、无 symbol ——**拿不到 socket 实例**。所以下面 1–7 项里有 6 项改不了，只能改源码。

---

## 6. vista 的 7 处必修

**6 处必须 vendor/fork 那约 100 行 `dist/interceptors/ws.mjs`：**

| # | 缺陷 | 实测表现 |
|---|---|---|
| 1 | **构造异常被 `.catch(()=>{})` 吞掉** | `new WebSocket('ws://')` 不抛错、不派 `error`/`close`、`readyState` **永远停在 0**（静默挂死）；`ws://…/jsonrpc#frag` 更糟——原生抛 `SyntaxError`，vista **静默 mock 成功**（`open@0`，`readyState=1`） |
| 2 | **`close()` 在 CONNECTING 期间调用产生僵尸态** | 派发 close 之后 `readyState` **又回到 1（OPEN）**（4/4 用例） |
| 3 | **`close(code, reason)` 完全无参数校验** | `close(9999)` / `close(1005)` 不抛错，派发带非法 code 的 close 且 `wasClean` 恒 `true`；200 字节 reason 也不抛（原生抛 `SyntaxError`） |
| 4 | **`onopen` 属性处理器恒定先于 `addEventListener` 监听器** | 原生按注册顺序；实测"先 `addEventListener` 后 `onopen`"时 vista 输出 `["onopen-attr","addEventListener"]`，**反序** |
| 5 | **常量位置与属性特征不对** | `WebSocket.prototype` 上**完全没有** `CONNECTING/OPEN/CLOSING/CLOSED`（原生有，且 `writable:false, configurable:false`）；静态常量实测 `writable:true, configurable:true`；实例上多出 4 个 own enumerable 常量 |
| 6 | **`MessageEvent.origin` 恒为 `""`** | mock 消息与**真实透传消息**都是空串（原生 `ws://127.0.0.1:8792`） |
| 7 | **`binaryType` 接受非法值** | 赋 `'bogus'` 后读回 `'bogus'`；原生忽略非法值、保持 `'arraybuffer'` |

**顺带在 fork 里一起修构造器外观**：`name` = `CustomWebSocket`、`length` = 2、`String()` 吐出整个 class 源码、`prototype` 是个新对象——原生分别是 `WebSocket`、`0`、`function WebSocket() { [native code] }`。

**1 处可在我们自己的 middleware 内规避（不改库）**：

vista 的 mock 响应是在 `ws.send()` **调用栈内同步派发** `message`（实测 `deliveredSynchronouslyInsideSend: true`；原生与 msw 都不是）。把 `c.sendToClient(...)` 包一层 `queueMicrotask` 即可。

> **上游是 `@beta` + CI 不跑测试**（两个 workflow 只有 install / build / publish）。**fork 之后回归测试必须由我们自己接管**，§7 的表就是现成的验收基线。

---

## 7. 保真基线（**可直接当验收标准**）

**先说一条两家都做不到的**：**纯 JS 伪造做不到"原型链与 `addEventListener` 同时为真"**。

| 探针 | 原生 | msw | vista |
|---|---|---|---|
| `Object.prototype.toString.call(ws)` | `[object WebSocket]` | `[object EventTarget]` | `[object EventTarget]` |
| `Object.getPrototypeOf(ws) === WebSocket.prototype` | `true` | `false` | `false` |
| `ws instanceof <替换前捕获的原生构造器>` | `true` | `false` | `false` |
| `Object.getOwnPropertyNames(ws)` | `[]` | **14 项**（`readyState/url/protocol/extensions/bufferedAmount/binaryType` 是**可写** data 属性 ⇒ **页面可以直接改写 `ws.readyState`**） | 4 项（常量） |
| mock 事件的 `isTrusted` | `true` | `false` | `false` |

（`isTrusted` 由 DOM 规范的 `[LegacyUnforgeable]` 定死，**改不了**，如实记录、不计为缺陷。）

**结论**：两库在指纹层**都不保真**；vista 的属性分布更接近原生（4 项 vs 14 项），且不污染全局可枚举属性。**以假乱真的目标应定为"客户端库能正常工作"，不是"对抗检测"。**

---

## 8. 拦不到的（盲区 —— Q-D2 要求对用户公示）

### 8.1 技术做不到（加权限也解不开）

- `chrome://`、`edge://` 页面
- **其它扩展的页面**（content script 的 match pattern scheme 白名单不含 `chrome-extension`）
- Chrome 应用商店页面、内置 PDF 阅读器、`view-source:`
- **网页的 Worker / SharedWorker / Service Worker 内部** —— `chrome.scripting` 的 `InjectionTarget` 只有 `tabId / frameIds / documentIds / allFrames`，**没有任何 Worker 目标**；DNR 也补不上（没有"合成响应体"动作，且管不到 SW 的 `onfetch`）。对 Q-D2 的"Worker 能做就拦、做不到就不拦"，**判定为做不到**。
- **其它扩展发出的请求** —— 四道独立闸门：content script scheme 白名单 `/` webRequest 事件路由器显式过滤其它扩展 `/` DNR 对其它扩展非主框架请求整套 ruleset 跳过且不对 `chrome-extension:` 求值 `/` `chrome.debugger` 的 `ExtensionMayAttachToURL` 拒绝。
  ⇒ **第三方 aria2 前端扩展的请求永远接不住，自带 UI 是必需项。**

### 8.2 能但需配合 / 代价高

无 host 权限的站点、跨域 iframe（需帧自身 origin 权限）、`about:blank` / `srcdoc` / `data:` / `blob:` 帧（需 `match_origin_as_fallback` 且 `matches` 路径必须为 `*`）、`file://` 与无痕（用户开关）、**未刷新的旧页面**、以及**注入前已发出的请求**。

> 公示文案请注意：**不要把这 8.2 类写成 8.1 类**。

---

## 9. R5 的落地形态（平台强制，不是设计偏好）

**扩展自身页面在 scheme 层就无法被 content script 注入**（match pattern 只支持 `http/https/*/file`，表达不了 `chrome-extension://`；三浏览器一致）。

⇒ **R5 的"换装载方式"不是例外，是唯一路径。** 内置 AriaNg UI 只能**用页面内 `<script>` 装载同一份转发器**。

**代码组织上的硬含义**：
- **转发器核心不得引用任何 `chrome.*`**
- 两侧共用同一条拦截路径，**只替换"配置 + 传输适配器"这一层绑定**
- **必须禁止"扩展页直接调 Mock 层函数"**
- 需要新增一条验收：**两种装载方式行为逐条一致**（扩展页 `fetch` 有跨源特权、CSP 语义不同，这两条待详细设计实测）

（`msw` 的 `FallbackHttpSource` 是同构先例：SW 不可用时它退化成纯 JS 层拦截器，路径不变、只换装载方式。）

---

## 10. 必须映射成失败的收尾点（R10 / R2）

- 注入失败 / 桥未建立 ⇒ **不要静默降级**，要让上层知道"这一页没被接管"
- 跨 world 消息超 64 MiB 或序列化失败 ⇒ 请求失败，不得伪装成功
- SW 被回收导致的超时 ⇒ 明确的失败，不是"永远等待"
- **页面拆掉我们的 patch**（§3.4 第 2 条）⇒ 无法可靠检测，只能接受

---

## 11. 未测 / 待定

| # | 事项 | 状态 |
|---|---|---|
| U1 | **SW 冷启动与消息唤醒延迟**（官方无任何数值，直接决定桥与轮询方案） | **未测**，无官方数据 |
| U2 | 跨 world `MessagePort` transfer 是否可用 | **未测** |
| U3 | SW 终止时 port 是否断开 | **未测** |
| U4 | 未授权 host 时 `registerContentScripts` 是报错还是"注册成功但不注入" | **未测** |
| U5 | 预渲染页面的注入行为 | **未测** |
| U6 | **二进制帧**、`wss`/TLS、**真 aria2 联调**（E 全程未对真 aria2 跑过） | **未测** |
| U7 | R4.1「尽可能多来源」是否等于上 `<all_urls>` 级权限 —— **与 Q-D1 的保守姿态冲突，需用户裁定** | 待裁定 |

---

## 12. 证据出处

| 来源 | 内容 |
|---|---|
| `docs/research/experiments/E-websocket-interceptor-fidelity.md` | WS 两库对照、7 处必修、保真基线表、服务端 accept 铁证 |
| `docs/research/forwarders/F1-injection.md` | 注入机制与时机、R5 特例、MAIN world 能力与通信 |
| `docs/research/forwarders/F2-js-apis.md` | fetch/XHR/WebSocket 的拦截难度分级与盲区 |
| `docs/research/forwarders/F3-network-layer.md` | 网络层五条途径的能力边界、CDP 的代价 |
| `docs/research/forwarders/F4-contexts-and-gaps.md` | 上下文覆盖矩阵 34 条 + 面向用户的盲区清单 |
| `docs/research/forwarders/F5-permissions-crossbrowser.md` | 权限、DNR 配额、三浏览器支持矩阵 |
| `docs/research/libraries/msw-v2.md` | msw 拦截器层设计、6 处文档/源码不一致、11 条改造清单 |
| `docs/research/libraries/vista-v2.md` | vista 原理、14 条保真缺口、真实 MV3 扩展用例 |

**一条方法学提醒（来自实验 E）**：证明"**没有建真实连接**"，靠客户端侧的"没收到 `error`"是不够的。可靠做法是**把目标指向一个真实监听的端口，然后看服务端 accept 日志**——原生留痕 `GET /jsonrpc HTTP/1.1`，伪造路径那一行**完全不存在**。
