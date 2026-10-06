# F2 — JS API 覆盖面：哪些请求拦得住、怎么拦

## 0 元信息

| 项 | 值 |
|---|---|
| 文档 | F2 / 转发器研究：JS API 覆盖面 |
| 团队任务 | t7（[f2]），attempt 1 |
| 上游输入 | `/workspace/docs/concept-design/concept-design.md` v0.5（重点：R4、R5、R9、Q-D2、Q-D3） |
| 主题 | 逐个 JS 层请求途径：能否在 MAIN world 覆盖 / 覆盖点在哪 / 伪造一个以假乱真的返回有多难 |
| 核对日期 | **2026-10-06（UTC）** |
| 浏览器/版本 | Chrome stable **155.0.8059.26**（win64 稳定通道，来源 [E21]）；Firefox release **157.0**（来源 [E22]）。本文件默认目标为 **Chrome / Manifest V3**；Firefox 差异只在有文档支撑处标注 |
| 规范基线 | WHATWG Living Standard（Fetch / XHR / WebSocket / DOM / WebIDL / HTML，均于核对日抓取）+ W3C Beacon |
| 证据等级 | **A** = 规范原文摘录；**B** = 官方文档（MDN / developer.chrome.com）原文摘录；**C** = 相关第三方库**源码**摘录（用于证明"前端实际怎么发请求"）；**D** = 未验证（进 §7） |
| 环境限制 | 本机**没有任何浏览器与扩展运行时**，全部结论来自规范/文档/源码，**无实测**。凡"规范未写死、只能实测确认"的策略点，一律标注并汇总到 §7 |
| 不写什么 | 不写实现代码、不写注入机制（属 fwd-inject 的任务）、不写网络层路线（DNR / webRequest / CDP 只在冲突节做对照） |

**术语**

- **MAIN world**：与宿主页面共享的执行环境（Chrome 扩展文档原文见 [E15]）。
- **realm**：一个独立的 JS 全局环境（每个 Window / DedicatedWorker / SharedWorker / ServiceWorker / isolated world 各一个）。同一页面内**不同 realm 的补丁互不可见**。
- **覆盖点**：我们替换/包裹的对象与属性（如 `window.fetch`、`XMLHttpRequest.prototype.send`）。
- **伪造难度**：让"没联网的假对象"在客户端眼里与真货不可区分所需的代价（本文件评级：低 / 中 / 高 / 极高）。
- **盲区**：命中拦截地址、但请求依然发到网络或根本无法被我们看到的途径/来源。

---

## 1 一句话结论

**能拦**：`fetch`、`XMLHttpRequest`、`WebSocket`、`EventSource`、`navigator.sendBeacon` 五条页面 JS 入口都可以在 MAIN world 就地短路（R9 成立）；其中 **`fetch` 的伪造品是原生 `Response` 对象、保真度最高**，`XMLHttpRequest` 用**原型级 patch** 可做到几乎无感，**`WebSocket` 必须整对象手搓**、是成本最高的必选项。

**必须支持的三条**（由"前端真实怎么发请求"决定）：**XHR**（AriaNg 的 HTTP 通道，经 AngularJS `$http` → `XMLHttpRequest`，[E17][E18]）、**WebSocket**（AriaNg 的 WS 通道 + aria2 的服务端通知语义，[E19][E20]）、**`fetch`**（现代前端与脚本的默认通道，成本极低，顺带支持）。`EventSource` / `sendBeacon` 成本低但收益低，可按"可选项"处理。

**明确放弃**：`WebTransport`、`WebSocketStream`、`RTCPeerConnection` 数据通道（aria2 客户端不用，伪造成本极高）；**页面 Worker / Service Worker 内的请求**（初版放弃，理由与成本见 §5.1）；**Isolated Web App 的 Direct Sockets**（结构上拦不到，[E23]）。

**真实盲区**（不是"我们的实现没做好"，是浏览器结构决定的）：页面在注入前**已经捕获的原生引用**（例如 `angular-websocket` 在模块求值时就执行 `Socket = Socket || window.WebSocket`，[E20]）；**同源新开 iframe 取原生 API**；**其它扩展的 isolated world 与其后台上下文**；**页面自己的 Service Worker**；**WebRTC / 导航 / 子资源加载**；以及一切走 **C++ 侧网络栈而非 JS API** 的请求。

---

## 2 机制

### 2.0 判断框架

对每条途径固定回答四问：

1. **能否在 MAIN world 覆盖**：覆盖对象是否在页面 realm 的全局对象/原型链上（§2.1 给出规范依据）。
2. **覆盖点在哪**：构造器 / 原型方法 / 原型 accessor / 实例属性，四级之一。
3. **伪造一个以假乱真的返回有多难**：能否返回**原生对象**（最容易）还是必须手搓整对象（最难）。
4. **什么时候失效**：跨 realm、注入时序、被捕获引用、被页面还原。

### 2.1 覆盖点的规范基础（为什么"能覆盖"、以及"覆盖了也不是真的"）

**(a) 构造器可替换。** 规范规定每个暴露的接口在 realm 的全局对象上有一个属性，其值即接口对象（interface object，函数对象）：WebIDL §3.7 —— "For every interface that is exposed in a given realm … a corresponding property exists on the realm's global object. The name of the property is the identifier of the interface, and its value is an object called the interface object."（[E1]）因此 `XMLHttpRequest`、`WebSocket`、`EventSource`、`Response`、`Headers`、`Worker` 这些**构造器都是全局对象上的属性**，`window.X = Fake` 这类替换在规范层面成立（属性是否 writable/configurable：规范给出了"操作函数"的通用描述符 `[[Writable]]: modifiable, [[Enumerable]]: true, [[Configurable]]: modifiable`（`modifiable=false` 仅当 `[Unforgeable]`），见 WebIDL §3.7.7（[E2]）；**该描述符是否同样用于全局对象上的接口对象属性，规范文本未明写，实测确认列入 §7**）。

**(b) `fetch` 是"全局对象自己的成员"而不是原型成员。** `fetch` 声明在 `WindowOrWorkerGlobalScope` mixin 上（Fetch 规范原文：`partial interface mixin WindowOrWorkerGlobalScope { [NewObject] Promise<Response> fetch(...) }`，[E3]）。WebIDL 规定：常规属性/操作默认定义在**接口原型对象**上，"unless the attribute is unforgeable or if the interface was declared with the `[Global]` extended attribute, in which case they are exposed on every object that implements the interface"（§3.7.6 属性、§3.7.7 操作，[E2]）；而 `Window` 正是 `[Global]`。**推论**：`window.fetch` 是 window 自身的属性（不是 `Window.prototype` 上的）；**规范推导**下 `delete window.fetch` 不会把原生 fetch 暴露回来（原型上没有第二份），而是让 `fetch` 彻底消失——该行为与下面的"页面可反向覆盖"一并列入 §7 U1 待实测。页面对同一属性做 `Object.defineProperty(window,'fetch',…)` 可以**反向覆盖我们的补丁**——Chrome 官方文档也明确提示 MAIN world 的这一风险："Warning: There are risks involved when using the 'MAIN' world. The host page can access and interfere with the injected script."（[E16]）

**(c) 原型上的方法与 accessor 可被重定义。** 属性访问器的描述符为 `{[[Getter]]: getter, [[Setter]]: setter, [[Enumerable]]: true, [[Configurable]]: true}`（`configurable=false` 仅当 `[Unforgeable]`，[E2]）——所以 `XMLHttpRequest.prototype` 上的 `status`/`responseText`/`send` 等都可以被**原型级替换**，且替换后对未命中请求可转调原生实现。

**(d) 假对象**不能**借用原生 accessor（这是"整对象伪造"成本的根本来源）。** WebIDL §3.8：只有带 `[[PrimaryInterface]]` 槽的对象才是平台对象，"A JavaScript value value implements an interface interface if value is a platform object and the inclusive inherited interfaces of value.[[PrimaryInterface]] contains interface."（[E4]）属性 getter/setter 与操作函数在调用时都做品牌检查："If jsValue does not implement target, then: … Otherwise, throw a TypeError."（操作：[E2]；getter/setter 同节）。**结论**：`WebSocket.prototype.readyState` 的 getter 用在一个手搓对象上会 `TypeError`；`EventTarget.prototype.addEventListener.call(假对象,…)` 同样 `TypeError`。想用 `Object.setPrototypeOf(fake, WebSocket.prototype)` 继承原生 getter，只会在第一次读 `readyState` 时爆炸；**唯一出路是把该接口的每个成员都作为自有属性/方法重新实现**。

**(e) 只读属性的赋值语义。** 规范注释："Attempting to assign to a property corresponding to a read only attribute results in different behavior depending on whether the script doing so is in strict mode. When in strict mode, such an assignment will result in a TypeError being thrown. When not in strict mode, the assignment attempt will be ignored."（[E2]）→ 若把假对象挂到真实原型上，`fake.status = 200` 会静默失败/抛错，必须 `Object.defineProperty`。

**(f) 身份与类型标识。** 接口原型对象的 class string 是接口限定名（[E2]），并且"any object with a class string must have a `%Symbol.toStringTag%` property with `{[[Writable]]: false, [[Enumerable]]: false, [[Configurable]]: true}`"（[E2]）→ 原生对象 `Object.prototype.toString.call(x)` 为 `"[object XMLHttpRequest]"`/`"[object WebSocket]"`；手搓对象默认是 `"[object Object]"`，需要自己补一个不可写但可配置的 `Symbol.toStringTag` 才能对齐。

**(g) 事件层的硬伤：合成事件的 `isTrusted` 永远是 false。** DOM 规范 `dispatchEvent()` 步骤："Initialize event's isTrusted attribute to false."；MDN 表述为"true when the event was generated by the user agent … and false when the event was dispatched via `EventTarget.dispatchEvent()`"（[E5][E6]）。→ 我们伪造的 `readystatechange`/`open`/`message`/`close` 全都带 `isTrusted === false`，**这是 JS 层无法消除的差异**（真 XHR/WS 事件为 true）。

**(h) 事件是"同步派发、异步时序"。** DOM 的 "fire an event" 算法最终就是同步 `dispatch`（[E5]）；XHR/WS/EventSource 的规范都把事件放在 fetch/协议的异步回调或**任务队列**里触发（WebSocket 明确写 "queue a task"，[E12]）。→ 补丁**不能在 `send()` 里同步派发事件**，否则"先在 `send()` 后注册监听"的客户端会漏事件（与真实实现可观察地不同）。

### 2.2 `fetch`

- **能否 MAIN world 覆盖**：能。覆盖点 = 全局对象上的 `fetch`（§2.1(b)），一次赋值/defineProperty 即覆盖全部 `fetch()` 调用（裸标识符 `fetch(...)` 与 `window.fetch(...)` 走同一属性）。
- **覆盖点在哪**：`window.fetch`（必须同时决定是否覆盖 `Request`/`Response`/`Headers` 构造器；通常**不需要**——我们返回的是真 `Response`）。
- **伪造难度：低（但要做到"完全一致"不可能）。**

  关键事实（Fetch 规范，[E7][E8][E9][E10]）：

  | 属性 | `new Response(body, init)` 的值 | 说明 |
  |---|---|---|
  | `type` | `"default"`（"Unless stated otherwise, it is 'default'"，而真实同源 fetch 是 `"basic"`、跨源 CORS 是 `"cors"`） | **必须用自有属性覆盖**（原型上是只读 getter） |
  | `url` | `""`（getter：response 的 URL 为 null 时返回空串） | 真实 fetch 为请求的最终 URL，**必须覆盖** |
  | `redirected` | `false`（URL 列表长度 > 1 才为 true） | 命中`/jsonrpc` 一般无重定向，可留默认 |
  | `status` / `statusText` | `200` / `""`（可经 init 指定：status 必须在 200–599，否则 `RangeError`；statusText 必须匹配 reason-phrase，否则 `TypeError`） | aria2 的 RPC 常规是 HTTP 200，够用 |
  | `ok` | 由 status 推导（ok status = 200–299） | 自动正确 |
  | `headers` | 真 `Headers` 对象，guard = `"response"` | **可直接构造**：`new Response(body,{headers})`；注意 guard 为 `"response"` 时 `Set-Cookie` 属 forbidden response-header name，写入被静默忽略（[E10]） |
  | `body` / `bodyUsed` / `text()`/`json()`/`clone()` | 原生行为（Body mixin） | 无需伪造 |

  - **流式 body 可用**：`Response` 构造器的 body 参数允许 `ReadableStream`（[E7]），客户端可用 `res.body.getReader()` 或 `for await` 增量读取；`clone()` 会 tee（body 已 disturbed 时抛 `TypeError`）。→ 若 Mock 层要"边下载边喂进度"，这条路成立。
  - **失败语义**：真实 `fetch()` 在网络错误时**拒绝 promise 并抛 `TypeError`**（"If response is a network error, then reject p with a TypeError"，[E9]）；`network error` 是 `type="error"`、`status=0`、headers 空、body null 的响应（[E9]）。→ 假 fetch 不能用 `Response.error()` 当作返回值的"错误响应"（真实 fetch 永远不会把它 resolve 出来），必须 `Promise.reject(new TypeError(...))`。
  - **覆盖成本**：约 3 个实例自有属性（`url`/`type`/`redirected`）+ 一次全局替换；`Response` 本体是真货 → `instanceof Response`、`[object Response]`、`res.json()` 全部原生。
- **何时失效**：页面在注入前已捕获 `fetch` 引用（例如把它作为参数传进库、或 `const f = fetch` 早于注入）；页面主动 `Object.defineProperty(window,'fetch',…)` 覆盖我们（[E16]）；同源 iframe / Worker / SW 等**其它 realm**（§5.1）。

### 2.3 `XMLHttpRequest`

- **能否 MAIN world 覆盖**：能。构造器对象在全局对象上（§2.1(a)），`XMLHttpRequest.prototype` 上的方法与 accessor 可重定义（§2.1(c)）。**扩展面**：`[Exposed=(Window,DedicatedWorker,SharedWorker)]`（XHR 规范 IDL，[E11]）→ 这意味着 **Worker 里也有一份自己的 XHR，页面补丁不覆盖它**；同时 **ServiceWorker 里没有 XHR**（曝光集不含 ServiceWorker）。
- **覆盖点在哪（两条策略，推荐后者）**：
  - **策略 A：替换构造器**。`window.XMLHttpRequest = Fake`。缺点：要重实现全部成员；`instanceof`/类型标识要额外对齐；页面用 `Object.getPrototypeOf`、`Symbol.hasInstance`、`constructor` 都可能看出差异；且**未命中请求也要走我们的假对象**（把真实请求也接管了，风险面大）。
  - **策略 B：原型级 patch（推荐）**。只重定义 `XMLHttpRequest.prototype` 上的 `open`/`send`/`setRequestHeader`/`abort`/`getAllResponseHeaders`/`getResponseHeader` 与**只读 accessor**（`readyState`/`status`/`statusText`/`response`/`responseText`/`responseURL`），用 `WeakMap<xhr, state>` 判断"这个实例是否命中拦截地址"：未命中 → 转调原生（`nativeGetter.call(this)` / 原生方法 `Reflect.apply`），命中 → 短路并返回伪造视图。好处：实例身份、`instanceof`、`[object XMLHttpRequest]`、`addEventListener`/`dispatchEvent`、`upload`、`timeout` **全部保持原生**，事件可直接 `dispatchEvent`（但 `isTrusted=false`，§2.1(g)）。
  - **替换 accessor 时必须成对处理 getter/setter**：`timeout`、`withCredentials`、`responseType`、`onreadystatechange` 等 IDL 是**读写属性**，只替换 getter 会让页面的赋值静默失效/抛错（§2.1(e)）。
- **需要伪造什么（XHR 规范原文，[E11]）**：
  - `readyState`：常量 `UNSENT=0`/`OPENED=1`/`HEADERS_RECEIVED=2`/`LOADING=3`/`DONE=4`；原生 `open()` 已把真实实例推进到 1 并派发过一次 `readystatechange`，命中后我们接管 2→3→4。
  - `status`/`statusText`：getter 直接返回 response 的 status/status message（→ 我们的数字/文本）。
  - `responseText`：**若 `responseType` 不是空串或 `"text"` 必须抛 `InvalidStateError`**；state 不是 loading/done 时返回空串。
  - `response`：`responseType` 为空串/`"text"` 时行为同 `responseText`；其它类型在 state 不是 done 时返回 **null**（→ 假实现必须按类型分别给 `ArrayBuffer`/`Blob`/字符串/解析后的 JSON，否则前端读到的形状不对）。
  - `responseURL`：response 的 URL 序列化（去掉 fragment）。
  - `getAllResponseHeaders()`：规范算法是 sort-and-combine + 逐行 `name: value\r\n`（名字用 legacy-uppercase 排序，[E11]）→ 假实现返回**一整串**，且大小写/排序要按规范来，否则严格解析的库会读出差异；`getResponseHeader(name)` 是单值查询（大小写不敏感）。
  - `open()` 的异常面（要让未命中/异常路径与原生一致）：非法 method/URL → `SyntaxError`；`CONNECT`/`TRACE`/`TRACK` → `SecurityError`；Window 上 `async=false` 且 `timeout≠0` 或 `responseType≠""` → `InvalidAccessError`；`send()` 在非 opened 或已发送时 → `InvalidStateError`；`setRequestHeader()` 同上。
- **事件时序（"同步异步语义"，规范依据 [E11]）**：
  - 发送成功路径：`loadstart` → `readystatechange(2)` → `readystatechange(3)`+`progress`（**约 50ms 节流**："If not roughly 50ms have passed since these steps were last invoked, then return"）→ `readystatechange(4)` → `load` → `loadend`。
  - 失败路径：`readystatechange(4)` → `error`/`timeout`/`abort`（其一）→ `loadend`；`abort()` 的特殊点：若状态是 done，则回到 `unsent` 且**不派发 `readystatechange`**（"No readystatechange event is dispatched."）。
  - `progress` 事件是 `ProgressEvent`：`loaded`=transmitted、`lengthComputable`/`total` 仅当 length≠0。
  - **全部必须异步（任务/宏任务）派发**，不能用同步或微任务在 `send()` 内完成——规范把它们放在异步回调与任务队列中（[E11]），且"先 `send()` 后挂 `onload`"的写法在真实 XHR 下是能收到事件的。
- **伪造难度：中**（比 fetch 高：要重实现 accessor 与事件序列；比 WebSocket 低：**有真实实例可挂载**，事件/监听器/实例身份都是原生的）。
- **何时失效**：Worker 内的 XHR（另一 realm）；`fetch` 在 Worker/SW 中；注入前已保存的 `XMLHttpRequest.prototype.send` 引用（页面保留原生引用即可绕过原型 patch——但页面通常不会这么做）。

### 2.4 `WebSocket`（最难的一条）

**为什么最难**：`new WebSocket(url)` 的构造步骤**立即在并行线程上发起真实握手**（"Run this step in parallel: Establish a WebSocket connection…"，[E12]），**没有"创建一个还没连的 WebSocket 实例"这种 API**。也就是说：**我们没有真实实例可以挂载**，必须**整对象手搓**；而 §2.1(d) 又禁止我们借用原生 accessor。这是"必选项里成本最高"的根本原因。

- **能否 MAIN world 覆盖**：能。替换全局 `WebSocket`（接口对象，§2.1(a)）；`[Exposed=(Window,Worker)]`（[E12]）→ 每个 realm 各有一份。
- **覆盖点在哪**：`window.WebSocket`（构造器整体替换）。替换后 `x instanceof WebSocket` **自动成立**（`instanceof` 走我们新构造器的 `prototype` 链），无需额外处理；`Object.prototype.toString` 需补 `Symbol.toStringTag = "WebSocket"`（§2.1(f)）。
- **必须重实现的成员（WebSocket 规范 IDL，[E12]）**：常量 `CONNECTING=0/OPEN=1/CLOSING=2/CLOSED=3`；`readyState`、`bufferedAmount`（真语义：队列中未发出的字节数）、`url`、`protocol`（子协议协商结果，初始空串）、`extensions`（扩展协商结果，初始空串）、`binaryType`（初始 `"blob"`，可设 `"arraybuffer"`）；`send(data)`/`close(code, reason)`；`onopen/onmessage/onerror/onclose`；**以及 `addEventListener`/`removeEventListener`/`dispatchEvent`**（不能借用 `EventTarget.prototype`，§2.1(d)——最省事的做法是 `class FakeWS extends EventTarget`，让事件层是真货）。
- **必须复刻的校验语义（否则客户端会看到假异常差异）**：`send()` 在 `CONNECTING` 时抛 `InvalidStateError`；`close(code)` 只接受 `1000` 或 `3000–4999`，否则抛 `InvalidAccessError`；`reason` 的 UTF-8 编码超过 123 字节抛 `SyntaxError`；在 `CLOSING/CLOSED` 下 `close()` 是 no-op（[E12]）。
- **必须复刻的事件语义（[E12]）**：
  - `open`：**先 `readyState=1` 再派发**，且**必须 `queue a task`**（"Since the algorithm above is queued as a task, there is no race condition between … and the script setting up an event listener for the open event."）。
  - `message`：`MessageEvent`，`data` 依 `binaryType` 决定是字符串 / `Blob` / `ArrayBuffer`，`origin` 初始化为该 WebSocket URL 的 origin 序列化。
  - `close`：`CloseEvent`，带 `code`/`reason`/`wasClean`；失败关闭时 `code=1006`，并且**规范禁止向脚本泄露失败原因**（"User agents must not convey any failure information to scripts in a way that would allow a script to distinguish …"，[E12]）→ 我们的假实现**也必须保持这种"什么都不说"的姿态**（不编造 DNS/连接错误文案）。
  - `error`：只在"fail the WebSocket connection"或 buffer 满时派发；`Event`，**不含任何信息**（[E12]）→ 假实现不应在 `error` 上挂自定义字段。
  - 事件派发用 WebSocket task source（[E12]）→ 全部异步。
- **"转发器轮询 Mock 层"来近似服务端推送：可行，但只覆盖"应用层消息"。** Q-D3 的裁定（轮询 Mock 层）本质上是把"Mock 层 → 客户端"的推送改成客户端侧驱动：假 socket 是**我们自己的对象**，客户端 `send()` 的内容交给 Mock 层，Mock 层的应答与 aria2 通知（`aria2.onDownloadStart` 等，[E19]）由**轮询结果**在客户端侧**异步**派发成 `message`。要点与代价：
  1. **可行**：不存在"必须由服务端 TCP 主动推"的硬约束——因为 WS 服务端本身就是我们伪造的；AriaNg 读的是 `readyState` 和事件（[E20]）。
  2. **粒度 = 通知延迟**：轮询间隔决定 aria2 通知的到达延迟；`message` 派发必须经任务队列（与真实现一致）。
  3. **不可伪造的协议级特性**：ping/pong 帧、`Sec-WebSocket-Extensions` 协商、`bufferedAmount` 的真实流量控制语义、以及关闭握手的字节级过程（[E12]）。这些只影响"协议自省型"客户端；aria2 前端不用。
  4. **重连语义必须模拟**：AriaNg 的 WS 服务自己实现了重连（`reconnectInterval`，且检查 `socketClient.readyState === CONNECTING || OPEN`，[E20]）→ 如果假 socket 在"Mock 层不可用"时随意置 `CLOSED`，会触发前端重连风暴；反之若永远 `OPEN`，又要保证 `send()` 有去有回。**结论：假 socket 的状态机要显式设计，不能只做"能收发"。**
- **伪造难度：高**（对象整搓 + 状态机 + 事件时序 + 校验语义；比 fetch/XHR 高一个量级，但**没有不可逾越的墙**）。
- **扩展侧有没有更省事的替代**：**没有可直接用的**。`webRequest` 从 Chrome 58 起能拦 **WebSocket 握手请求**，但明确**不拦截已建立连接上的单条消息、也不支持 WS 重定向**（"the API does not intercept: Individual messages sent over an established WebSocket connection. WebSocket closing connection. Redirects are not supported for WebSocket requests."，[E24]）。`declarativeNetRequest` 的资源类型里有 `"websocket"`，动作只有 `block`/`redirect`/`allow`/`upgradeScheme`/`modifyHeaders`/`allowAllRequests`，**没有任何"提供响应体"的动作**（[E25]）→ 想"返回一个以假乱真的 RPC 响应"，扩展侧无路可走，**只能在 JS 层伪造实例**。

### 2.5 `EventSource`

- **能否 MAIN world 覆盖**：能（接口对象 + `[Exposed=(Window,Worker)]`，[E13]）。
- **覆盖点在哪**：`window.EventSource` 构造器整体替换；`readyState` 常量注意与 WS 不同：`CONNECTING=0`、`OPEN=1`、`CLOSED=2`（[E13]）。
- **要伪造什么**：`url`、`withCredentials`、`readyState`、`close()`、`onopen/onmessage/onerror`、`addEventListener` 家族（同 §2.1(d)，用 `EventTarget` 做基类）。
- **语义要求（[E13]）**：`announce` 时先 `readyState=OPEN` 再派发 `open`；`reestablish` 时先置 `CONNECTING` 再派发 `error`，然后按 reconnection time 重试（可带 `Last-Event-ID`）；`fail the connection` 时置 `CLOSED` 并派发 `error`，**之后不再重连**；`close()` 置 `CLOSED`。→ 自动重连是 API 契约的一部分，假实现要么真实模拟、要么明确不复用（否则前端的重连逻辑会错乱）。
- **伪造难度：中低**（单向、事件少），但**可省**：aria2 的 RPC 没有 SSE 通道（[E19] 只列 JSON-RPC over HTTP/GET/WebSocket 与 XML-RPC over HTTP），拦它只是为了"覆盖更全"（R4.1）；收益/成本比一般。
- **注意**：这是"覆盖途径"而非"兑现能力"——即使拦截了，也要由 Mock 层决定是否真的产出 `text/event-stream` 语义。

### 2.6 `navigator.sendBeacon`

- **能否 MAIN world 覆盖**：能（`Navigator.prototype.sendBeacon`，可原型级替换；规范签名 `boolean sendBeacon(USVString url, optional BodyInit? data = null)`，[E14]）。
- **要伪造什么**：几乎不用——`sendBeacon` 只返回布尔值。
- **语义（[E14]）**：请求是 `POST` + `keepalive` + `credentials: include`，`mode` 默认 `no-cors`（Content-Type 非 safelist 时升为 `cors`）；URL 非 http(s) 或不可解析 → `TypeError`；数据超过 keepalive 队列上限 → 返回 `false`，否则返回 `true`。**规范明确没有响应回调**："Beacon API does not provide a response callback."，并且"this method does not provide any information whether the data transfer has succeeded or not."
- **拦截价值**：拦截后我们**只能兑现"被接受"**（返回 true 并把数据交给 Mock 层），**不能兑现"响应"**（客户端拿不到任何返回体）。→ 对 aria2 RPC 无用（前端不会用 beacon 发 RPC）；作为 R4.1 的"覆盖更多途径"可实现，但必须在盲区清单里写清"beacon 的语义只到投递为止"。
- **伪造难度：低**（但"以假乱真的返回"这件事本身在 API 层面无意义——真实调用者拿不到响应）。

### 2.7 其它 JS 入口（逐条裁定）

| 入口 | MAIN world 可覆盖? | 覆盖点 | 难度 | 裁定与依据 |
|---|---|---|---|---|
| `fetchLater`（`Window.fetchLater`） | 能 | `window.fetchLater` | 低（但它绕过 `fetch` 补丁，必须单独打） | 规范已定义（Fetch 规范 `partial interface Window { [NewObject, SecureContext] FetchLaterResult fetchLater(...) }`，[E3]）；MDN 标注 "Limited availability … Experimental"（[E26]）→ 初版**可不实现**，但**盲区清单要提**，否则"延迟发送"的请求会漏 |
| `WebTransport` | 对象层可包装，**会话层不可伪造** | `window.WebTransport` | 极高 | MDN 已标 Baseline 2026（[E27]）；构造即发起真实 HTTP/3 会话，假对象要伪造 `ready`/流/数据报，且 aria2 不提供 WT 端点 → **明确放弃** |
| `WebSocketStream` | 能 | `window.WebSocketStream` | 高 | MDN："Experimental"（[E28]）→ **放弃**（同上，且实验 API 无客户端在用） |
| `Worker` / `SharedWorker` / `ServiceWorker` **构造器** | 能（构造器在全局对象上） | `window.Worker` 等 | 高（要改写/包裹脚本源，CSP、模块 worker、`importScripts` 各自有坑） | 拦"创建新 Worker"是**唯一**能在 JS 层摸到 Worker realm 的机会；**初版放弃**，作为"若将来要覆盖 Worker"的预留点（§5.1） |
| 动态 `import()` / `<script>` / `<img>` / `<link>` / CSS `url()` / `<iframe>` / `new Audio()` | **不能**（这些不是可调用的请求 API） | — | — | 浏览器子资源加载，不走任何被我们覆盖的函数；DNR/网络层才有手段（[E25]）。对 RPC 场景无影响（前端不会用 `<img>` 发 JSON-RPC） |
| `RTCPeerConnection` / `createDataChannel` | 对象可包装，**语义不可伪造** | `window.RTCPeerConnection` | 极高 | 数据通道"creates a new channel linked with the remote peer"（[E29]），需要信令与对端，**无法连到 `ws://` 服务端** → 对 aria2 场景**无需拦截**，列为盲区即可 |
| 浏览器自身发起的请求（导航、预加载扫描器、favicon、`<link rel=preload>`）与**页面 SW 里的 `fetch`**（另一 realm） | 不能 | — | — | 前者不经任何 JS API；后者是我们注入不到的执行环境（§5.1）；JS 层都无响应能力（§5.3） |
| `TCPSocket`/`UDPSocket`（Direct Sockets，Isolated Web App 专用） | 不能 | — | — | Chrome 文档："The Direct Sockets API addresses this limitation by enabling Isolated Web Apps (IWAs) to establish direct TCP and UDP connections"（[E23]）→ 普通页面/扩展页拿不到这些构造器；若客户端跑在 IWA 里，**结构上拦不到**（§5.3） |
| WebAssembly 内的"网络调用" | 视胶水而定 | 仍是上面那些 JS API | — | WASM 自身没有网络原语，运行在沙箱里并受同源/权限策略约束（MDN："WebAssembly is specified to be run in a safe, sandboxed execution environment. Like other web code, it will enforce the browser's same-origin and permissions policies."，[E30]）→ **WASM 不是独立盲区**，它是"同一批 JS API 的调用者"；真正的风险是**胶水在注入前捕获了原生引用**（同 §5.2） |

### 2.8 命中判定与 R9 的一致性

R9 要求"命中规则后请求根本不会发到网络上"。可在 JS 层满足：

- `fetch`：命中 → 直接 resolve 假 `Response`，**不调用原生 fetch**（调用链上没有任何网络副作用）。
- XHR：命中 → 我们接管 `send()`，**不调用原生 send**（`open()` 本身不发包；但注意：**真实 `open()` 已经在原生实例上执行过**，其副作用仅限内部状态与一次 `readystatechange`）。
- WebSocket：命中 → **根本不构造原生 WebSocket**，没有握手包。
- EventSource / sendBeacon：同构。
- **必须避免的自伤**：转发器与 Mock 层的通道若用 `fetch('http://localhost:6800/...')` 或原生 WS 回环，就会**真的发包**（并且会被自己的规则再次命中）。设计约束：**Mock 层通道走扩展消息（`chrome.runtime` 消息 / `postMessage`），不走 HTTP**。

---

## 3 硬约束（编号清单）

| # | 约束 | 依据 |
|---|---|---|
| C1 | 补丁**只在其所在 realm 生效**；Window / DedicatedWorker / SharedWorker / ServiceWorker / isolated world 各自一份全局对象与环境 | [E1][E11][E12][E15] |
| C2 | 构造器是全局对象属性 → 可替换；替换后 `instanceof` 自动成立（新构造器的 prototype 链） | [E1] |
| C3 | 接口对象与原型成员的属性描述符（writable/configurable）在规范中由"操作/属性通用描述符"给出，但**全局对象上的接口对象属性描述符未在规范正文写明** → 实现须 `try/catch` 并准备回退 | [E2]；§7 U1 |
| C4 | 手搓对象**不能**借用原生 accessor/方法（品牌检查抛 `TypeError`） | [E4] |
| C5 | `EventTarget` 的方法同样有品牌检查 → 假 WS/ES 必须自带事件层（用 `class X extends EventTarget` 最省事） | [E4][E5] |
| C6 | 只读属性赋值在严格模式抛 `TypeError`、非严格静默失败 → 必须 `Object.defineProperty` | [E2] |
| C7 | 替换读写属性（`timeout`/`withCredentials`/`responseType`/`on*`）时必须同时提供 setter，否则破坏页面赋值 | [E2][E11] |
| C8 | 合成事件 `isTrusted === false`，**不可消除** | [E5][E6] |
| C9 | 事件必须**异步**派发（任务队列），不得在 `send()` 内同步派发 | [E11][E12] |
| C10 | XHR `responseText`/`response`/`responseXML` 有按 `responseType` 与 state 的**异常/空值契约**，假实现必须一致 | [E11] |
| C11 | XHR `getAllResponseHeaders()` 的排序/大小写/`\r\n` 拼接是规范算法，不是"随便拼" | [E11] |
| C12 | `new Response()` 的 `status` 限 200–599、`statusText` 限 reason-phrase、null-body-status 不许带 body | [E8] |
| C13 | 构造的 `Response` 的 `url` 为 `""`、`type` 为 `"default"` → 想伪装真实 fetch 必须覆盖这两个只读属性 | [E7][E8] |
| C14 | `Response.headers` 的 guard 是 `"response"`，`Set-Cookie` 写入被忽略 | [E10] |
| C15 | 真实 `fetch` 的网络错误是 **promise reject TypeError**，不是 resolve 一个 `Response.error()` | [E9] |
| C16 | WebSocket 无"未连接实例"构造路径 → 必须整对象伪造 | [E12] |
| C17 | WS `send`/`close` 的参数校验与异常类型固定；假实现不照做会产生"客户端只在假服务端才会遇到的错误" | [E12] |
| C18 | WS 失败关闭必须"什么都不说"（1006，不泄露原因），假实现不得自创错误文案 | [E12] |
| C19 | `sendBeacon` 无响应回调 → 拦它只能兑现"投递" | [E14] |
| C20 | 扩展文档明确警告 MAIN world 可被宿主页面访问/干扰 → **不假设补丁不可被还原** | [E16] |
| C21 | MAIN world 注入的脚本受**页面 CSP** 约束（Chrome 文档仅就"注入到 main world"作此表述；程序化注入是否同样受限 → §7 U2） | [E15] |
| C22 | 静态内容脚本在 `document_start` 注入是在**页面任何脚本之前**（"after any files from css, but before any other DOM is constructed or any other script is run."）→ 这是"抢在页面捕获原生引用之前"的唯一时间窗 | [E15] |
| C23 | 结构上**没有**向页面的 Worker / Service Worker 注入脚本的扩展 API（`InjectionTarget` 只有 `tabId`/`frameIds`/`documentIds`/`allFrames`） | [E15] |
| C24 | 内容脚本 `matches` 只支持 `http`/`https`/通配/`file` 四种 scheme → **`chrome-extension://`、`chrome://`、`view-source:`、PDF viewer 等页面无法用声明式注入覆盖** | [E31] |
| C25 | `about:`/`data:`/`blob:`/`filesystem:` 帧需要 `match_origin_as_fallback`（或 `match_about_blank`）才会被注入 | [E15] |
| C26 | 扩展侧对 WS 只能拦握手，**看不到也管不了已建立连接的消息** | [E24] |
| C27 | DNR 无"提供响应体"动作 → 网络层无法代替 JS 层伪造 RPC 响应 | [E25] |

---

## 4 能力映射

### 4.1 裁定表（必须支持 / 可选 / 放弃）

| 途径 | 裁定 | 理由（要点） |
|---|---|---|
| **XMLHttpRequest** | **必须支持** | AriaNg 的 HTTP RPC 通道经 AngularJS `$http` → `new window.XMLHttpRequest()`（[E17][E18]）；JSON-RPC over HTTP（POST/GET）与 XML-RPC over HTTP 都走它 |
| **WebSocket** | **必须支持**（第一版，与 Q-D3 一致） | AriaNg 的 WS 通道走原生 WebSocket（[E20]），aria2 的 WS 通道还承载**服务端通知**（[E19]）；且这是扩展侧做不到、只能 JS 层伪造的一条（[E24][E25]） |
| **fetch** | **必须支持**（成本最低） | 现代前端/脚本的默认通道；伪造品是原生 `Response`，保真度最高 |
| EventSource | 可选（低优先） | aria2 无 SSE 通道（[E19]）；只为 R4.1 的"覆盖更全" |
| `navigator.sendBeacon` | 可选（低优先） | 只兑现"投递"，无响应语义（[E14]） |
| `fetchLater` | 可选（建议先只列入盲区） | 实验性（[E26]）；但要意识到它绕过 `fetch` 补丁 |
| Worker / SharedWorker / ServiceWorker 构造器 | **初版放弃**（列为盲区） | 覆盖率取决于页面是否新建 worker；改写脚本源在 CSP/模块化/`importScripts` 上各有坑（[E15]）；先不做 |
| WebTransport / WebSocketStream | **明确放弃** | 客户端不用（aria2 无对应端点）+ 伪造会话成本极高（[E27][E28]） |
| RTCPeerConnection 数据通道 | **放弃（且无需拦）** | 需要真实对端与信令，连不上 `ws://` 服务端（[E29]） |
| Direct Sockets（IWA） | **放弃（结构上拦不到）** | 仅 Isolated Web App 可用（[E23]） |
| WebAssembly 内的网络 | **不单独处理** | 无网络原语，走 JS 胶水（[E30]） |

### 4.2 可拦截途径完整清单 + 实现难度评级

| # | 途径 | MAIN world 覆盖 | 覆盖点 | 假返回的保真度 | 伪造难度 | 主要失效条件 |
|---|---|---|---|---|---|---|
| 1 | `fetch` | ✅ | `window.fetch` | **高**（返回真 `Response`，仅 `url`/`type`/`redirected` 需覆盖） | **低** | 跨 realm；注入前已捕获 `fetch`；页面反覆盖 |
| 2 | `XMLHttpRequest` | ✅ | `XMLHttpRequest.prototype`（推荐）/ 构造器 | **高**（真实例 + 原生事件层，仅状态/响应视图是伪造的） | **中** | Worker 内实例；注入前已保存原生方法引用 |
| 3 | `WebSocket` | ✅ | `window.WebSocket`（整对象） | 中（对象与事件可高仿；协议级特性不可伪造） | **高** | 跨 realm；注入前已捕获构造器（[E20] 就是实例）；页面反覆盖 |
| 4 | `EventSource` | ✅ | `window.EventSource`（整对象） | 中（单向、事件少；但重连是契约） | 中低 | 同上 |
| 5 | `navigator.sendBeacon` | ✅ | `Navigator.prototype.sendBeacon` | 低（只有布尔返回） | 低 | 无响应可兑现；页面反覆盖 |
| 6 | `fetchLater` | ✅ | `window.fetchLater` | 低—中 | 低（若真做） | 实验性；不在初版范围 |
| 7 | `Worker`/`SharedWorker`/`ServiceWorker` 构造器 | ✅ | `window.*` | — | 高 | 覆盖不全；CSP/模块 worker 复杂 |
| 8 | `WebTransport` / `WebSocketStream` | ⚠️（对象可换） | `window.*` | 低 | 极高 | 会话/流语义无法伪造 |
| 9 | `RTCPeerConnection` | ⚠️（对象可换） | `window.RTCPeerConnection` | — | 极高 | 需要真实对端；对 aria2 无意义 |

**真实盲区**（无法通过"JS 层覆盖"解决）：见 §5。

---

## 5 失败模式与盲区

### 5.1 来源盲区（"拦不到谁发的请求"）

1. **页面自己的 Worker / SharedWorker / ServiceWorker** —— 每个 worker 有独立全局环境（MDN：`WorkerGlobalScope`"won't access … directly … inherited by more specific global scopes such as `DedicatedWorkerGlobalScope` and `SharedWorkerGlobalScope`"，[E32]），而扩展的注入目标只有 frame/document（[E15]）→ **结构上无法把补丁送进去**。注意 XHR 在 SW 中根本不存在（曝光集不含 SW，[E11]），SW 里只有 `fetch`/`WebSocket`。
   **若将来要覆盖**：唯一入口是页面 realm 里的 `Worker`/`SharedWorker`/`ServiceWorker.register` 构造器（改写脚本源 + 在 worker 内自打补丁），成本高、覆盖不全（已在 worker 里跑着的、被 CSP 拦的、被注册脚本接管的都拦不住）。
2. **其它扩展的 isolated world** —— 隔离世界对页面**不可访问**（Chrome 文档："An isolated world is a private execution environment that isn't accessible to the page or other extensions' content scripts."；"none of these (web page, content scripts, and any running extensions) can access the context and variables of the others."，[E15]）→ 别的扩展在其隔离世界里发的请求，我们既看不到也改不了。
3. **未匹配的 frame** —— 我们只在 `matches` 命中的文档里注入；一个未注入的 frame（跨源、或 URL 不在规则内）里的脚本可以用原生 API 打 `localhost:6800`。`allFrames` 也需要每个帧**独立**满足 URL 要求（"Each frame is checked independently for URL requirements"，[E15]）。
4. **同源新 iframe / 新 realm 取原生 API** —— 页面随时可以 `document.createElement('iframe')` 取一份未被 patch 的原始 `fetch`/`WebSocket`（若该 frame 不被注入）。这是 MAIN world 补丁的通用上限（C20：[E16] 已官方警告宿主页面可干预）。
5. **注入前建立的引用** —— 库在模块求值时就抓走原生构造器。**已证实的实例**：AriaNg 依赖的 `angular-websocket@2.0.1` 在模块顶层执行 `Socket = Socket || window.WebSocket || window.MozWebSocket;`，之后一律 `new Socket(url)`（[E20]）→ **只要注入发生在这段模块代码之后，AriaNg 的 WS 通道就整个绕过我们**。这直接说明 C22（`document_start` 必须在页面脚本之前）是硬要求，而不是优化项。

### 5.2 时序盲区

- 主文档导航请求本身（地址栏/`<a>`/form/`window.open`/`meta refresh`）在 JS 之前就发生；JS 层**没有**"给导航提供响应"的能力（页面自己的 Service Worker 在其 scope 内可以，但那不是我们的注入）。
- 预加载扫描器、favicon、`<link rel=preload>`、`<script src>`、CSS 里的 `url()` 等子资源加载不走可覆盖的 JS API（[E25] 是网络层手段）。
- `document_start` 是"页面任何脚本之前"（[E15]），但**不能早于浏览器自身**（导航、预加载）——概念文档 §6.4 里"document_start 之前已发出的请求"应理解为"**非 JS 发起的请求 + 早于注入的其它扩展**"，而不是"页面脚本抢跑"。

### 5.3 途径盲区（拦不到的网络出口）

| 途径 | 为什么拦不到 | 对 aria2 场景的影响 |
|---|---|---|
| Isolated Web App 的 `TCPSocket`/`UDPSocket`（Direct Sockets） | 仅 IWA 可用，普通页面/扩展页无此构造器（[E23]） | 只在"客户端跑在 IWA"时出现；极低概率，列入盲区 |
| WebRTC 数据通道 | 需真实对端 + 信令（[E29]） | 无法连 ws 服务端 → 无影响 |
| `WebTransport` 会话建立后的流 | `webRequest` 在其握手后"cannot observe or intervene in the session"（[E24]）；JS 层要伪造会话成本极高 | 无影响（aria2 无 WT 端点） |
| 页面 Service Worker 里的 `fetch`（含它自己对 `localhost:6800` 的请求） | 另一 realm，且无注入 API（[E15]） | 中：某些前端会把请求放 SW；列盲区并告知 |
| 其它扩展后台/隔离世界里的请求 | 见 §5.1.2 | 中：任何扩展都能打这个地址 |
| **JSONP 形式的 JSON-RPC over GET**（`<script src>` / `$http.jsonp`） | JSONP 是**子资源加载**，不经 XHR/fetch 补丁。aria2 手册的 GET 通道含 JSONP 形态（[E19]）；**AriaNg 实际不用**（HTTP 服务只用 `$http` 的 POST/GET，[E17]），但第三方前端可能用 | 低—中：前端层面的漏网，需在盲区清单写明"JSONP 不在覆盖范围" |
| 浏览器界面/内部页面（`chrome://`、PDF viewer、`view-source:`、`chrome-extension://`） | `matches` 的 scheme 白名单不含这些（[E31]） | 与 R8 一致（这些不是"页面客户端"）；但**内置 AriaNg 页属 `chrome-extension://`，同样不在白名单**（见 §6.4） |

### 5.4 "拦到了但不像"——可检测差异清单

| 差异 | 能否消除 | 依据 |
|---|---|---|
| 合成事件 `isTrusted === false` | **不能**（JS 层无法造 trusted 事件） | [E5][E6] |
| 构造 `Response` 的 `type="default"`（非 `"basic"`） | 能（自有属性覆盖） | [E8] |
| 构造 `Response` 的 `url=""` | 能（自有属性覆盖） | [E8] |
| 伪造实例的自有属性形状（`Object.getOwnPropertyNames` 比原生多） | 部分（原型级 patch 可避免；整对象伪造不可避免） | [E2] |
| `fn.toString()` 不再返回 `"function fetch() { [native code] }"` | 能（覆盖 `Function.prototype.toString`），但会让"检测"变成对抗，收益低 | [E33] |
| Resource Timing 中缺少 `initiatorType="fetch"/"xmlhttprequest"/"beacon"` 的记录（真实请求有，我们命中后不发包） | **不能**（不发包就没有 timing 条目） | [E34] |
| DevTools Network 面板没有对应条目 | **不能** | 同上 |
| WS 协议级特性：`extensions` 协商、ping/pong、`bufferedAmount` 的真实流量控制 | **不能** | [E12] |
| XHR `upload` 事件（上传进度）语义 | 视实现（GET 无 body 时原生也只走 `loadstart`/`loadend`） | [E11] |

**结论**：能做到"**客户端库正常工作**"级别的以假乱真；做不到"**对抗型检测**"级别的不可区分。设计目标应按前者设定（与 R3/R10 的"结果兑现"精神一致）。

### 5.5 协议层盲区（WebSocket 专属）

- 握手细节（`Sec-WebSocket-Protocol` 协商、`Sec-WebSocket-Extensions`、Cookie/Origin 头）在假 socket 里是"我们说了算"，但**服务端视角不存在**——若客户端把 `protocol` 用于协议选择（aria2 不需要），要给出合理值（空串或客户端提供的第一个子协议）。
- 关闭码：正常关闭用 `1000`；若我们无法区分"正常/异常"，只能按 `wasClean` 语义近似。
- `bufferedAmount`：真实语义与发送队列/事件循环步进相关（规范有精确定义，[E12]）→ 假实现只应给"0 或估算值"，并在文档里承认。

### 5.6 与 R9 承诺的核对

R9："命中规则后请求根本不会发到网络上。" 本文件逐条核对 **成立**（§2.8），但有两个必须写进设计的附加约束：

1. **转发器自身的 Mock 通道不得走网络**（否则"命中后仍会发包"，且会被自己再次命中）。
2. **未命中的请求必须原样放行**，包括：命中原型级 patch 但 URL 不匹配的 XHR（转调原生）、非 `ws://` 目标、`sendBeacon` 的非匹配 URL。

---

## 6 与现有裁定的冲突

### 6.1 R9（拦截在 JS API 层）——一致，但补齐边界

- 一致：五条 JS 入口都能"就地短路"，CORS/混合内容/证书/真实服务存在性均不适用（与 R9 原文相符）。
- **需要写进设计的澄清**：R9 说"不是网络层的重定向/代理，DNR 走网络层拿不到'返回任意响应体'的能力"——本文件给出了规范级佐证：DNR 的动作枚举只有 `block`/`redirect`/`allow`/`upgradeScheme`/`modifyHeaders`/`allowAllRequests`（[E25]），**没有"提供响应体"这一动作**；`webRequest` 对 WS 连消息级拦截都没有（[E24]）。→ R9 的裁定在"能不能伪造响应"这个判据上是**充分且必要**的。
- **已知的非 JS 层备选（不属于本文件，供 captain 与后续任务对照）**：`chrome.debugger` + CDP `Fetch.fulfillRequest` 能在 HTTP(S) 层为用户可见的请求提供响应，**且天然覆盖 Worker/SW 发起的请求**；代价是 `debugger` 权限、用户可见提示、覆盖面是 HTTP 而非 WS。**是否可用：未验证（§7 U5）**。它与 R9 不冲突（R9 是"我们选定的路线"），但应在能力清单里作为"解释为什么不用"的对照项存在。

### 6.2 Q-D3（WebSocket 第一版就实现；可用"转发器轮询 Mock 层"近似推送）

- **支持该裁定可行**：假 socket 由我们构造，客户端 `send()` → Mock 层，Mock 层应答/通知 → 轮询取回 → 异步派发 `message`。不存在"必须真服务端推"的硬约束（§2.4）。
- **需要补充的约束**（建议写入后续详细设计）：
  1. **状态机必须显式**：`CONNECTING→OPEN→CLOSING→CLOSED` 的迁移时机要定义，尤其"Mock 层暂时不可达"时是保持 `OPEN`（并丢弃/排队）还是转 `CLOSING`→`CLOSED`；AriaNg 会依 `readyState` 触发重连（[E20]）。
  2. **通知延迟=轮询周期**，且必须在**任务队列**里派发（与真实现一致，[E12]）。
  3. **`send()` 的参数类型要按规范处理**（string/Blob/ArrayBuffer/ArrayBufferView），并正确更新 `bufferedAmount` 的近似值（[E12]）。
  4. **不要承诺协议级特性**（扩展位、ping/pong），在盲区清单里明说（§5.5）。

### 6.3 Q-D2（盲区必须明确列出；Worker 内请求"能做到就拦"）

- 本文件给出可交付清单：§5.1（来源）、§5.3（途径）、§5.4（可检测差异）。**建议：Worker / SW / 其它扩展 / IWA 全部计入第一版盲区**，理由是注入面（C23：[E15]）与成本；"技术上能做到"的只有"页面 realm 里新建 Worker 的构造器"这一窄口，且覆盖不全。

### 6.4 R4.1（尽可能多拦）与 R5（内置 UI 不得走特殊通道）

- **R5 的"扩展自身页面也可能注入不进去"在文档里有硬依据**：内容脚本 `matches` 的 scheme 白名单只有 `http`/`https`/通配/`file`（[E31]），**`chrome-extension://` 不在其中** → 声明式内容脚本**无法**注入扩展自己的页面；程序化注入到自己扩展页是否可行：**未验证（§7 U3）**。
- **对 R5 的后果**：内置 AriaNg UI 若以 `chrome-extension://…/index.html` 形式加载，就必须走 R5 允许的"唯一例外"——在**该页面内**用另一种装载方式加载转发器（而不是换一条接入路径）。这与概念文档 R5 的措辞完全一致，本文只是把"注入不进去"从推测变成文档级事实。

### 6.5 R2 / R10（能力诚实、结果兑现）与 JS 层的关系

- 转发器只负责"**把命中请求取走、把 Mock 层的回答以 API 语义还回去**"；**响应的内容与错误码一律由 Mock 层决定**，转发器不得自行编造（否则就变成 R2 禁止的"假装正常"）。
- 唯一例外是**协议层的必要包装**（如 `responseText` 类型契约、`getAllResponseHeaders` 的格式、`sendBeacon` 的布尔返回、"数据已接受"）——这些是 API 语义，不是业务承诺。

### 6.6 与概念文档 §6.4 已列盲区的差异（修正与补充）

| §6.4 表述 | 本文结论 |
|---|---|
| "`chrome://` 页面、扩展页 CSP、PDF viewer、view-source" | **确认**，依据是 scheme 白名单（[E31]）；"扩展页 CSP" 更准确的表述是：**扩展页无法被声明式注入**；而 MAIN world 注入到普通页面时受**页面 CSP** 约束（[E15]） |
| "`document_start` 之前已发出的请求" | 细化：页面脚本不可能早于 `document_start` 注入（[E15]）；真正在此之前的是**浏览器自身**（导航/预加载）与**其它扩展**（§5.1.2、§5.2） |
| "不经标准 JS API 的网络途径" | 具体化为：Direct Sockets(IWA)、WebRTC、WebTransport 会话、导航与子资源（§5.3） |
| "技术上拦不到的 Worker 内请求" | 细化：**注入 API 面决定了全部 Worker/SW realm 都拦不到**（[E15]），除非改 Worker 构造器（高成本、覆盖不全） |

---

## 7 未验证

| ID | 未验证项 | 为什么没验证 | 建议的验证方式 |
|---|---|---|---|
| U1 | `window.fetch` / `window.XMLHttpRequest` / `window.WebSocket` 这些属性在真实 Chrome 里的 **writable/configurable 描述符**（决定"能否稳定覆盖"与"页面能否反覆盖"） | WebIDL 正文只写了"全局对象上存在该属性"，未给出该属性的描述符；沙箱内无浏览器 | 在目标 Chrome 版本上跑 `Object.getOwnPropertyDescriptor(window,'fetch')` 等；同时验证 `defineProperty` 覆盖与 `delete` 的行为 |
| U2 | MAIN world 的**程序化**注入（`chrome.scripting.executeScript({world:'MAIN'})`）是否受页面 CSP 约束 | Chrome 文档只写了"内容脚本注入到 main world 时页面的 CSP 生效"（[E15]），未区分静态/动态/程序化 | 在 CSP 严格的页面上分别用三种装载方式注入并观察 |
| U3 | 能否向**自己扩展的页面**（`chrome-extension://…`）程序化注入脚本 | 文档只给出 `matches` 的 scheme 白名单（[E31]），未直接断言程序化注入的结果 | 扩展实测：`scripting.executeScript` 目标为自家扩展页 tab |
| U4 | 把假对象 `Object.setPrototypeOf(fake, WebSocket.prototype)` 后，`EventTarget.prototype` 方法是否仍抛 `TypeError` | 规范依据是 `[[PrimaryInterface]]` 品牌检查（[E4]），但**具体 UA 实现细节**未验证 | 浏览器实测（预期抛错；若不抛错，整对象伪造可以更"瘦"） |
| U5 | CDP `Fetch.fulfillRequest` 能否为**扩展看不到的**请求（Worker/SW）伪造响应；以及能否对 WS 帧提供响应 | 未查证 CDP 文档（属另一路线，不在本任务范围） | 查 CDP Fetch/Network 域文档 + 实测；若成立，它是"Worker/SW 盲区"的唯一非 JS 层解法 |
| U6 | 浏览器是否支持 WASI sockets（`wasi:sockets`） | 未找到"浏览器不支持"的官方声明；MDN 只有"WASM 在沙箱内"的表述（[E30]） | 查 WASI/WASI-sockets 规范与 Chrome 的 WASI 支持状态 |
| U7 | Firefox 侧的差异（isolated world 与页面通信、`cloneInto`/`exportFunction`、`world: MAIN` 支持情况） | 本文件默认 Chrome；未逐项核对 Firefox 官方文档 | 需要跨浏览器时另做一份 Firefox 对照 |
| U8 | AriaNg 对 aria2 WS **通知**的具体消费路径（哪些通知驱动哪些 UI 更新、与轮询周期的耦合） | 只读了 RPC 服务层源码（[E20]），未追 UI 层 | 读 AriaNg `aria2RpcService`/控制器层代码并做集成测试（属"还原度文档"阶段） |
| U9 | 真实 XHR 在 Chrome 中 `readystatechange`/`load` 的**任务队列调度细节**（规范只说异步；不同实现的任务源可能不同） | 无浏览器实测 | 在页面里打点对比原生 XHR 事件时序与我们假实现的时序 |
| U10 | `Response` 构造实例上 `defineProperty(res,'url',…)` 后，客户端 `for...in`/`Object.keys` 是否会看到额外自有属性（可检测性） | 属实测细节 | 浏览器实测 |

---

## 8 证据清单

> 全部 URL 于 **2026-10-06（UTC）** 抓取。摘录为原文（英文）；方括号内为本文引用编号。

| ID | 主张 | 来源 | 摘录 |
|---|---|---|---|
| E1 | 接口对象是 realm 全局对象上的属性（构造器可替换） | WebIDL §3.7 Interfaces — https://webidl.spec.whatwg.org/ | "For every interface that is exposed in a given realm … a corresponding property exists on the realm's global object. The name of the property is the identifier of the interface, and its value is an object called the interface object." |
| E2 | 属性/操作的定义位置与描述符、品牌检查、只读赋值语义、class string / `Symbol.toStringTag` | WebIDL §3.7.3 / §3.7.6 / §3.7.7 — https://webidl.spec.whatwg.org/ | "Regular attributes are exposed on the interface prototype object, unless the attribute is unforgeable or if the interface was declared with the [Global] extended attribute, in which case they are exposed on every object that implements the interface."；"If jsValue does not implement the interface target, throw a TypeError."；"If validThis is false and attribute was not specified with the [LegacyLenientThis] extended attribute, then throw a TypeError."；"Attempting to assign to a property corresponding to a read only attribute results in different behavior depending on whether the script doing so is in strict mode…"；"If an object has a class string classString, then the object must, at the time it is created, have a property whose name is the %Symbol.toStringTag% symbol with PropertyDescriptor{[[Writable]]: false, [[Enumerable]]: false, [[Configurable]]: true, [[Value]]: classString}." |
| E3 | `fetch` 属于 `WindowOrWorkerGlobalScope` mixin；`fetchLater` 是 Window 上的独立入口 | Fetch Standard §5.6 Fetch methods — https://fetch.spec.whatwg.org/ | "partial interface mixin WindowOrWorkerGlobalScope { [NewObject] Promise<Response> fetch(RequestInfo input, optional RequestInit init = {}); }"；"[Exposed=Window] interface FetchLaterResult { readonly attribute boolean activated; }; partial interface Window { [NewObject, SecureContext] FetchLaterResult fetchLater(RequestInfo input, optional DeferredRequestInit init = {}); }" |
| E4 | "实现接口"= 拥有 `[[PrimaryInterface]]` 槽的平台对象 → 手搓对象不能借用原生成员 | WebIDL §3.8 Platform objects implementing interfaces — https://webidl.spec.whatwg.org/ | "A JavaScript value value is a platform object if value is an Object and if value has a [[PrimaryInterface]] internal slot."；"A JavaScript value value implements an interface interface if value is a platform object and the inclusive inherited interfaces of value.[[PrimaryInterface]] contains interface." |
| E5 | `fire an event` 即同步 dispatch；`dispatchEvent` 会置 `isTrusted=false`；`addEventListener` 依赖实例上的事件监听器列表 | DOM Standard §2.7/§2.8/§2.9 — https://dom.spec.whatwg.org/ | "Return the result of dispatching event at target, with legacy target override flag set if set."；"Initialize event's isTrusted attribute to false."；"The addEventListener(type, callback, options) method steps are: … Add an event listener with this and an event listener whose type is type…" |
| E6 | `isTrusted` 语义（脚本派发的事件为 false） | MDN Event.isTrusted — https://developer.mozilla.org/en-US/docs/Web/API/Event/isTrusted | "The isTrusted read-only property … is a boolean value that is true when the event was generated by the user agent … and false when the event was dispatched via EventTarget.dispatchEvent()." |
| E7 | `Response` 构造器接受 BodyInit（含 `ReadableStream`），`status` 默认 200、`statusText` 默认 "" | MDN Response() — https://developer.mozilla.org/en-US/docs/Web/API/Response/Response ；Fetch Standard Response() steps — https://fetch.spec.whatwg.org/ | MDN: "An object defining a body for the response. This can be null … or one of: Blob, ArrayBuffer, TypedArray, DataView, FormData, ReadableStream, URLSearchParams, String"；"status … The default value is 200."；"statusText … The default value is ''."；规范："The new Response(body, init) constructor steps are: … Set this's headers to a new Headers object … whose header list is this's response's header list and guard is 'response'." |
| E8 | 构造的 `Response`：`url` 为 ""、`type` 为 `"default"`；init 校验（200–599 / reason-phrase / null body status） | Fetch Standard §2.2 与 §5.5 — https://fetch.spec.whatwg.org/ | "A response has an associated type which is 'basic', 'cors', 'default', 'error', 'opaque', or 'opaqueredirect'. Unless stated otherwise, it is 'default'."；"The url getter steps are to return the empty string if this's response's URL is null; otherwise this's response's URL, serialized with exclude fragment set to true."；"The redirected getter steps are to return true if this's response's URL list's size is greater than 1; otherwise false."；"If init['status'] is not in the range 200 to 599, inclusive, then throw a RangeError."；"If init['statusText'] is not the empty string and does not match the reason-phrase token production, then throw a TypeError."；"If response's status is a null body status, then throw a TypeError." |
| E9 | `ok status` = 200–299；`network error` 定义；真实 `fetch` 网络错误 → reject `TypeError` | Fetch Standard §2.2.3 / §2.2 / §5.6 — https://fetch.spec.whatwg.org/ | "An ok status is a status in the range 200 to 299, inclusive."；"A network error is a response whose type is 'error', status is 0, status message is the empty byte sequence, header list is « », body is null…"；"If response is a network error, then reject p with a TypeError and abort these steps." |
| E10 | Response headers 的 guard 与 forbidden response-header name（`Set-Cookie`） | Fetch Standard §2.2.2 / §5.1 — https://fetch.spec.whatwg.org/ | "A forbidden response-header name is a header name that is a byte-case-insensitive match for one of: `Set-Cookie`, `Set-Cookie2`."；"If headers's guard is 'response' and name is a forbidden response-header name, then return false." |
| E11 | XHR：曝光集、只读 accessor 语义、`responseText`/`response` 契约、`getAllResponseHeaders` 算法、open/send/setRequestHeader 异常、事件顺序与 ~50ms 节流、`abort()` 不派发 readystatechange | XHR Standard §3 — https://xhr.spec.whatwg.org/ | "[Exposed=(Window, DedicatedWorker, SharedWorker)] interface XMLHttpRequest : XMLHttpRequestEventTarget"；"If this's response type is not the empty string or 'text', then throw an 'InvalidStateError' DOMException."；"If this's state is not loading or done, then return the empty string."；"If this's state is not done, then return null."；"The getAllResponseHeaders() method steps are: Let output be an empty byte sequence. … append header's name, followed by a 0x3A 0x20 byte pair, followed by header's value, followed by a 0x0D 0x0A byte pair…"；"If this's state is not opened, then throw an 'InvalidStateError' DOMException."；"If not roughly 50ms have passed since these steps were last invoked, then return."；"If this's state is done, then set this's state to unsent and this's response to a network error. No readystatechange event is dispatched."；"Fire an event named readystatechange at xhr. Fire a progress event named load at xhr with transmitted and length. Fire a progress event named loadend at xhr with transmitted and length." |
| E12 | WebSocket：曝光集、构造即并行发起连接、无"未连接实例"、readyState/常量、send/close 校验、事件（open 任务化、message 依赖 binaryType、error 无信息、close 用 CloseEvent）、失败关闭不泄露原因（1006） | WebSocket Standard §3–§4 — https://websockets.spec.whatwg.org/ | "[Exposed=(Window, Worker)]"；"Run this step in parallel: Establish a WebSocket connection given urlRecord, protocols, and client."；"If this's ready state is CONNECTING, then throw an 'InvalidStateError' DOMException."；"If code is present, but is neither an integer equal to 1000 nor an integer in the range 3000 to 4999, inclusive, throw an 'InvalidAccessError' DOMException."；"If reasonBytes is longer than 123 bytes, then throw a 'SyntaxError' DOMException."；"When the WebSocket connection is established, the user agent must queue a task to run these steps: Change the ready state to OPEN (1). … Fire an event named open at the WebSocket object."；"Fire an event named message at the WebSocket object, using MessageEvent, with the origin attribute initialized to the serialization of the WebSocket object's url's origin, and the data attribute initialized to dataForEvent."；"fire an event named error at the WebSocket object"（仅在 fail/flagged full 时）；"Fire an event named close … using CloseEvent, with the wasClean attribute … code … reason …"；"User agents must not convey any failure information to scripts in a way that would allow a script to distinguish the following situations…"；"The binary type, which is a BinaryType. Initially it must be 'blob'." |
| E13 | EventSource：曝光集、常量（0/1/2）、构造异常、`open`/`error`/重连/`fail` 语义 | HTML Standard §9.2 — https://html.spec.whatwg.org/multipage/server-sent-events.html | "[Exposed=(Window, Worker)] interface EventSource : EventTarget"；"CONNECTING (numeric value 0) … OPEN (numeric value 1) … CLOSED (numeric value 2)"；"If urlRecord is failure, then throw a 'SyntaxError' DOMException."；"sets the readyState attribute to OPEN and fires an event named open"；"Set the readyState attribute to CONNECTING. Fire an event named error at the EventSource object."；"sets the readyState attribute to CLOSED and fires an event named error at the EventSource object"；"Once the user agent has failed the connection, it does not attempt to reconnect." |
| E14 | sendBeacon：签名、POST+keepalive+credentials include、无响应回调、返回值语义 | W3C Beacon §2.1/§3 — https://w3c.github.io/beacon/ | "boolean sendBeacon(USVString url, optional BodyInit? data = null);"；"The user agent MUST initiate a fetch with keepalive flag set…"；"Beacon API does not provide a response callback."；"The sendBeacon() method returns true if the user agent is able to successfully queue the data for transfer. Otherwise it returns false."；"this method does not provide any information whether the data transfer has succeeded or not."；"method POST … keepalive true … credentials mode include … initiator type 'beacon'" |
| E15 | 扩展注入面：isolated world 隔离、MAIN world 共享页面环境、`document_start` 时序、注入目标只有 frame/document、MAIN world 受页面 CSP 约束、`matchOriginAsFallback` | Chrome for Developers — Content scripts https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts ；Scripting API https://developer.chrome.com/docs/extensions/reference/api/scripting | "Key term: An isolated world is a private execution environment that isn't accessible to the page or other extensions' content scripts."；"Note: Not only does each extension run in its own isolated world, but content scripts and the web page do too. This means that none of these (web page, content scripts, and any running extensions) can access the context and variables of the others."；"document_start … Scripts are injected after any files from css, but before any other DOM is constructed or any other script is run."；"When a content script is injected into the main world, the CSP of the page applies."；"MAIN: Specifies the main world of the DOM, which is the execution environment shared with the host page's JavaScript."；"InjectionTarget: allFrames / documentIds / frameIds / tabId"；"matchOriginAsFallback … about:, data:, blob:, or filesystem:" |
| E16 | MAIN world 注入可被宿主页面访问与干扰 | Chrome for Developers — manifest `content_scripts` https://developer.chrome.com/docs/extensions/reference/manifest/content-scripts | "Warning: There are risks involved when using the 'MAIN' world. The host page can access and interfere with the injected script." |
| E17 | AriaNg 的 HTTP RPC 走 AngularJS `$http`，且只用 POST/GET（不是 JSONP）；POST 把 JSON 放 body、GET 拼 query string | AriaNg `src/scripts/services/aria2HttpRpcService.js`（master，commit 56d44dc9e822a6f59aae13a542a0cab6cf292d30）— https://github.com/mayswind/AriaNg/blob/master/src/scripts/services/aria2HttpRpcService.js | "angular.module('ariaNg').factory('aria2HttpRpcService', ['$http', …"；"var method = ariaNgSettingService.getCurrentRpcHttpMethod();"；"if (requestContext.method === 'POST') { requestContext.data = angular.toJson(context.requestBody); requestContext.headers['Content-Type'] = 'application/json'; } else if (requestContext.method === 'GET') { requestContext.url = getUrlWithQueryString(requestContext.url, context.requestBody); }" |
| E18 | AngularJS 的 `$httpBackend` 用 `new window.XMLHttpRequest()` | AngularJS `src/ng/httpBackend.js` — https://github.com/angular/angular.js/blob/master/src/ng/httpBackend.js | "return new window.XMLHttpRequest();" |
| E19 | aria2 RPC 通道矩阵与 WS 通知语义 | aria2 官方手册 — https://aria2.github.io/manual/en/html/aria2c.html | "aria2 provides JSON-RPC over HTTP and XML-RPC over HTTP interfaces … aria2 also provides JSON-RPC over WebSocket. JSON-RPC over WebSocket uses the same method signatures and response format as JSON-RPC over HTTP, but additionally provides server-initiated notifications."；"The request path of the JSON-RPC interface (for both over HTTP and over WebSocket) is /jsonrpc. The request path of the XML-RPC interface is /rpc."；"The WebSocket URI for JSON-RPC over WebSocket is ws://HOST:PORT/jsonrpc."；"To send a RPC request to the RPC server, send a serialized JSON string in a Text frame. The response from the RPC server is delivered also in a Text frame."；"The RPC server might send notifications to the client. … The method signature of a notification is much like a normal method request but lacks the id key." |
| E20 | AriaNg 的 WS 通道走 angular-websocket；该库在**模块求值时就捕获** `window.WebSocket`，之后只用捕获的构造器；客户端会读 `readyState` 并按 `reconnectInterval` 重连 | AriaNg `src/scripts/services/aria2WebSocketRpcService.js` 与 `package.json` — https://github.com/mayswind/AriaNg/blob/master/src/scripts/services/aria2WebSocketRpcService.js ；angular-websocket 2.0.1 dist（npm tarball）— https://registry.npmjs.org/angular-websocket/-/angular-websocket-2.0.1.tgz | AriaNg: `'aria2WebSocketRpcService', ['$q', '$websocket', '$timeout', …]`；`socketClient = $websocket(rpcUrl, { … reconnectInterval: … })`；`if (socketClient.readyState === websocketStatusConnecting || socketClient.readyState === websocketStatusOpen)`；依赖："angular-websocket": "^2.0.1"；库源码（dist/angular-websocket.js，行 44 与 403–409）："Socket = Socket || window.WebSocket || window.MozWebSocket;"；"this.create = function create(url, protocols) { … return new Socket(url); }" |
| E21 | Chrome stable 版本 = 155.0.8059.26 | Chrome Version History API — https://versionhistory.googleapis.com/v1/chrome/platforms/win64/channels/stable/versions?pageSize=3 | `{"name":"chrome/platforms/win64/channels/stable/versions/155.0.8059.26","version":"155.0.8059.26"}` |
| E22 | Firefox release 版本 = 157.0 | Mozilla product-details — https://product-details.mozilla.org/1.0/firefox_versions.json | `"LATEST_FIREFOX_VERSION": "157.0"` |
| E23 | Direct Sockets 仅限 Isolated Web App | Chrome for Developers — Direct Sockets (IWA) https://developer.chrome.com/docs/iwa/direct-sockets | "The Direct Sockets API addresses this limitation by enabling Isolated Web Apps (IWAs) to establish direct TCP and UDP connections without a relay server."；"The direct-sockets key determines whether calls to new TCPSocket(…), new TCPServerSocket(…) or new UDPSocket(…) are allowed." |
| E24 | webRequest：可拦 WS 握手；**不拦已建立连接上的消息**；WS 不支持重定向；WebTransport 会话建立后不可观察/干预 | Chrome for Developers — webRequest https://developer.chrome.com/docs/extensions/reference/api/webRequest | "Starting from Chrome 58, the webRequest API supports intercepting the WebSocket handshake request."；"Note that the API does not intercept: Individual messages sent over an established WebSocket connection. WebSocket closing connection. Redirects are not supported for WebSocket requests."；"Once the session is established, extensions cannot observe or intervene in the session via the webRequest API." |
| E25 | DNR：动作枚举无"提供响应体"；资源类型含 `websocket` | Chrome for Developers — declarativeNetRequest https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest | "RuleActionType … 'block' … 'redirect' … 'allow' … 'upgradeScheme' … 'modifyHeaders' … 'allowAllRequests'"；ResourceType 列表含 "websocket"；"A declarativeNetRequest rule cannot redirect from a public resource request to a resource that is not web accessible." |
| E26 | `fetchLater` 为实验性/有限可用 | MDN Window.fetchLater — https://developer.mozilla.org/en-US/docs/Web/API/Window/fetchLater | "Limited availability — This feature is not Baseline because it does not work in some of the most widely-used browsers."；"Experimental: This is an experimental technology" |
| E27 | `WebTransport` 已达 Baseline 2026（可用） | MDN WebTransport — https://developer.mozilla.org/en-US/docs/Web/API/WebTransport | "Baseline 2026" |
| E28 | `WebSocketStream` 为实验性 | MDN WebSocketStream — https://developer.mozilla.org/en-US/docs/Web/API/WebSocketStream | "Experimental: This is an experimental technology" |
| E29 | RTCDataChannel 需要远端对端（不能连任意 TCP/WS 服务端） | MDN RTCPeerConnection.createDataChannel() — https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/createDataChannel | "The createDataChannel() method … creates a new channel linked with the remote peer, over which any kind of data may be transmitted." |
| E30 | WASM 在沙箱内、受同源与权限策略约束（无独立网络能力） | MDN WebAssembly Concepts — https://developer.mozilla.org/en-US/docs/WebAssembly/Guides/Concepts | "WebAssembly is specified to be run in a safe, sandboxed execution environment. Like other web code, it will enforce the browser's same-origin and permissions policies." |
| E31 | 内容脚本 `matches` 的 scheme 白名单（不含 `chrome-extension://` 等） | Chrome for Developers — Match patterns https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns | "scheme: Must be one of the following … http / https / A wildcard * … / file — For information on injecting content scripts into unsupported schemes, such as about: and data:, see Injecting in related frames." |
| E32 | Worker 有独立全局环境 | MDN WorkerGlobalScope — https://developer.mozilla.org/en-US/docs/Web/API/WorkerGlobalScope | "You won't access WorkerGlobalScope directly in your code; however, its properties and methods are inherited by more specific global scopes such as DedicatedWorkerGlobalScope and SharedWorkerGlobalScope." |
| E33 | 内建函数 `toString()` 返回 `[native code]`（补丁函数默认不是） | MDN Function.prototype.toString() — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Function/toString | "If the toString() method is called on built-in function objects, … then toString() returns … function someName() { [native code] }" |
| E34 | Resource Timing `initiatorType` 取值（`fetch`/`xmlhttprequest`/`beacon`） | MDN PerformanceResourceTiming.initiatorType — https://developer.mozilla.org/en-US/docs/Web/API/PerformanceResourceTiming/initiatorType | "beacon — If the request was initiated by a navigator.sendBeacon() method."；"fetch — If the request was initiated by a fetch() method."；"xmlhttprequest — If the request was initiated by an XMLHttpRequest." |

---

### 附：交付摘要（回填 output 用）

- **必须支持**：`XMLHttpRequest`（原型级 patch；AriaNg HTTP RPC 通道）、`WebSocket`（整对象伪造 + 轮询 Mock；AriaNg WS 通道与 aria2 通知）、`fetch`（替换 `window.fetch`，返回原生 `Response` + 覆盖 `url`/`type`/`redirected`）。
- **低成本可选**：`EventSource`、`navigator.sendBeacon`（只兑现投递）、`fetchLater`（建议先只列入盲区）。
- **成本高到应明确放弃**：`WebTransport`、`WebSocketStream`、`RTCPeerConnection`（伪造成本极高且 aria2 客户端不用）；**页面 Worker / SharedWorker / ServiceWorker 内的请求**（无注入 API 面，除非改 Worker 构造器）；**IWA 的 Direct Sockets**（结构上拦不到）。
- **真实盲区（必须告知用户）**：其它 realm（Worker/SW/isolated world/其它扩展）、同源新 iframe 取原生 API、注入前已捕获的原生引用（`angular-websocket` 是活证据）、导航与子资源加载、WebRTC/WebTransport、Direct Sockets。
- **JS 层不可消除的差异**：合成的 `open`/`message`/`close`/`readystatechange`/`load` 等事件 `isTrusted === false`；命中后不发包导致 Resource Timing / DevTools 里没有记录。→ 以假乱真的目标是"客户端库正常工作"，不是"对抗检测"。
