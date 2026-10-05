# 模块间通信与数据流

## 调用关系图

```
                        ┌─────────────────────┐
                        │    popup/App.tsx     │
                        │  (enable/disable +   │
                        │   Open AriaNg)       │
                        └──────────┬──────────┘
                                   │ runtime.sendMessage
                                   │ ("get-enabled" / "set-enabled")
                                   ▼
┌──────────────────────────────────────────────────────┐
│                   background.ts                       │
│                 (Service Worker)                      │
│                                                       │
│  onMessage 监听器:                                    │
│    "aria2-rpc"      →  aria2-handler.ts              │
│    "set-enabled"    →  storage.ts                    │
│    "get-enabled"    →  storage.ts                    │
│                                                       │
│  直接调用:                                            │
│    downloadManager.init() / destroy()                 │
└────┬──────────────┬──────────────────────────────────┘
     │ import       │ runtime.onMessage
     ▼              ▲
┌─────────────┐     │ runtime.sendMessage
│ core/       │     │
│             │     └──────────────────────────────┐
│ aria2-handler.ts                                 │
│   ├─ storage (isEnabled / loadSettings)          │
│   └─ download-manager (create/pause/resume...)   │
│                                                  │
│ download-manager.ts                              │
│   ├─ storage (loadTasks / saveTasks)             │
│   ├─ browser.downloads API                      │
│   ├─ browser.tabs API                           │
│   └─ browser.declarativeNetRequest API           │
│                                                  │
│ storage.ts                                       │
│   └─ browser.storage.local                      │
└──────────────────────────────────────────────────┘
                                                   │
┌──────────────────────────────────────────────────┘
│  CustomEvent on window
▼
┌──────────────────────────┐    runtime.sendMessage    ┌──────────────────────┐
│  main.content.ts         │◄─────────────────────────►│ bridge.content.ts    │
│  (MAIN world)            │   CustomEvent              │ (ISOLATED world)    │
│                          │   "aria2-shim-request"     │                      │
│  劫持:                   │   "aria2-shim-response"    │  监听:               │
│    window.fetch          │                            │    aria2-shim-request│
│    XMLHttpRequest        │                            │                      │
│    window.WebSocket      │                            │  调用:               │
│                          │                            │    runtime.sendMessage│
│  sendToBackground()      │                            │    dispatchEvent     │
│    → dispatchEvent       │                            │                      │
│    ← addEventListener    │                            │                      │
└──────────────────────────┘                            └──────────────────────┘
```

## 通信协议

### 协议 1：模块导入（同步，编译时确定）

```
types.ts  ←  storage.ts  ←  download-manager.ts  ←  aria2-handler.ts  ←  background.ts
```

箭头方向 = import 方向。所有 core 模块之间为标准的 TypeScript 模块导入。

### 协议 2：扩展消息传递（异步，运行时）

```
                    ┌──────────┐
                    │  popup   │
                    └────┬─────┘
                         │ runtime.sendMessage({type:"get-enabled"})
                         │ runtime.sendMessage({type:"set-enabled", enabled})
                         ▼
                    ┌────────────┐
                    │ background │
                    └─────┬──────┘
                          ▲
                          │ runtime.sendMessage({type:"aria2-rpc", payload})
                          │
                    ┌─────┴───────┐
                    │   bridge    │
                    │ (ISOLATED)  │
                    └─────────────┘
```

**消息格式：**

```typescript
// aria2-rpc 消息
{ type: "aria2-rpc", payload: Aria2RpcRequest | Aria2RpcRequest[] }

// 响应
{ jsonrpc: "2.0", id: string | number, result?: unknown, error?: { code: number, message: string } }

// 状态消息
{ type: "get-enabled" }
// 响应
{ enabled: boolean }

{ type: "set-enabled", enabled: boolean }
// 响应
{ success: true, enabled: boolean }
```

### 协议 3：CustomEvent 事件（异步，同进程跨 world）

MAIN world 与 ISOLATED world 之间通过在 `window` 上 dispatch/listen 自定义事件通信。

```
MAIN world (main.content.ts)          ISOLATED world (bridge.content.ts)
─────────────────────────────         ─────────────────────────────────
dispatchEvent(                         addEventListener(
  "aria2-shim-request",                  "aria2-shim-request",
  { detail: {                            async (e) => {
      _requestId: crypto.randomUUID(),     const { _requestId, body } = e.detail
      body: jsonRpcRequest                 const response = await runtime.sendMessage(...)
  }})                                      dispatchEvent("aria2-shim-response", {
                                             detail: { _requestId, data: response }
addEventListener(                          })
  "aria2-shim-response",                 }
  (e) => {                              )
    if (e.detail._requestId !== mine) return
    resolve(e.detail.data)
  }
)
```

**关键设计决策：**

- 每条请求生成唯一的 `_requestId`（`crypto.randomUUID()`），确保响应精确匹配
- 30 秒超时保护，防止 bridge 静默失效时 Promise 永久挂起
- MAIN world 的 Promise 在收到匹配的 `_requestId` 后 `resolve`
- 非匹配 `_requestId` 的事件被忽略（支持并发请求）

### 协议 4：浏览器扩展 API（异步，由 Chrome 管理）

core 模块之间通过标准 TypeScript 导入通信；popup 和 bridge 通过 `browser.runtime.sendMessage` 与后台通信；MAIN 和 ISOLATED content scripts 之间通过 window 上的自定义事件通信。`

```
download-manager.ts → browser.downloads.*
                    → browser.tabs.*
                    → browser.declarativeNetRequest.*

storage.ts          → browser.storage.local.*
                    → browser.storage.onChanged
```

## 下载完整数据流

```
                        AriaNg (web page)
                             │
                    WebSocket / fetch / XHR
                    to localhost:6800
                             │
              ┌──────────────┴──────────────┐
              │   main.content.ts (MAIN)    │
              │   intercepts:               │
              │   - FakeWebSocket           │
              │   - fetch override           │
              │   - XHR override             │
              └──────────────┬──────────────┘
                             │ CustomEvent("aria2-shim-request")
              ┌──────────────┴──────────────┐
              │  bridge.content.ts (ISO)    │
              │  runtime.sendMessage()      │
              └──────────────┬──────────────┘
                             │ {type:"aria2-rpc", payload}
              ┌──────────────┴──────────────┐
              │    background.ts            │
              │    handleAria2Request()     │
              └──────────────┬──────────────┘
                             │
              ┌──────────────┴──────────────┐
              │   aria2-handler.ts          │
              │   callMethod("aria2.addUri")│
              │   → parseAddUri(params)     │
              │   → downloadManager.create()│
              └──────────────┬──────────────┘
                             │
              ┌──────────────┴──────────────┐
              │  download-manager.ts        │
              │                              │
              │  1. injectHeaders()          │
              │     → DNR rule (CD header)   │
              │  2. tabs.create({url,        │
              │     active:false})           │
              │  3. status → "pending"       │
              └──────────────┬──────────────┘
                             │
              ┌──────────────┴──────────────┐
              │     Chrome Browser           │
              │                              │
              │  download created event      │
              │  → onBrowserDownloadCreated  │
              │  → match by URL              │
              │  → status → "in_progress"    │
              │                              │
              │  download changed events     │
              │  → onBrowserDownloadChanged  │
              │  → update bytes/speed/state  │
              │                              │
              │  terminal state:             │
              │  complete / error / cancelled│
              └──────────────────────────────┘
```

**响应路径（逆向传播）：**

```
browser.downloads event
  → download-manager 更新 task 状态
    → aria2-handler 构建 taskInfo（通过 AriaNg 的轮询 tellStatus/tellActive）
      → background 通过 sendResponse 返回
        → bridge 通过 CustomEvent("aria2-shim-response") 转发
          → main.content 接收 → resolve Promise → 返回给被劫持的 API
            → AriaNg 接收 JSON-RPC 响应
```

## 跨 world 通信机制

Chrome 扩展中，content scripts 在两个隔离的 JavaScript world 中运行：

| world | 能做什么 | 不能做什么 |
|-------|---------|-----------|
| MAIN (`world: "MAIN"`) | 覆写 `window.fetch`、`XMLHttpRequest`、`WebSocket` | 调用 `browser.runtime.*` 等扩展 API |
| ISOLATED（默认） | 调用 `browser.runtime.sendMessage` | 覆写页面中的 `window.fetch` |

**解决方案：** 两个 world 通过 `window` 上的 CustomEvent 通信，因为 Chrome 在两个 world 间**共享 DOM 事件目标**（`window` 和 `document`）。

```
┌── MAIN world ──┐          ┌── ISOLATED world ──┐
│  window.dispatch│          │  window.addEventListener│
│  Event("request")│─────────→│  ("request", handler) │
│                 │          │                       │
│  window.addEvent│          │  window.dispatchEvent │
│  Listener       │←─────────│  ("response")         │
│  ("response")   │          │                       │
└─────────────────┘          └───────────────────────┘
      共享 window (EventTarget) — DOM 事件跨越 world 边界
```
