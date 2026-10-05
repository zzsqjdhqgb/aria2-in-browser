# Entrypoints 模块

浏览器的每个扩展入口点。使用 WXT 的 `defineContentScript` / `defineBackground` 进行定义。

## 依赖关系

```
popup/App.tsx ──runtime.sendMessage──→ background.ts ←──runtime.sendMessage── bridge.content.ts
                                            │                                       ↑
                                            ├─ import → aria2-handler.ts            │ CustomEvent
                                            ├─ import → download-manager.ts         │
                                            └─ import → storage.ts                  │
                                                                              main.content.ts
```

---

## `background.ts` — Service Worker

**类型：** WXT background script（`defineBackground`）

**职责：** 扩展的消息路由中心。接收来自 content scripts 和 popup 的消息，分发给 core 模块。

**依赖（import）：** `@/core/aria2-handler` `@/core/storage` `@/core/download-manager`

**消息处理：**

| 消息类型 | 来源 | 操作 |
|----------|------|------|
| `"aria2-rpc"` | bridge（ISOLATED world） | 调用 `handleAria2Request(payload)`，异步返回响应 |
| `"set-enabled"` | popup | `setEnabled(enabled)` → `downloadManager.cancelAll()`（若禁用） |
| `"get-enabled"` | popup | `isEnabled()` → 返回 `{enabled}` |

**生命周期：**

- 启动时：`downloadManager.init()` 从存储恢复任务
- `beforeunload` 时：`downloadManager.destroy()` 清理

---

## `popup/` — 扩展弹窗

**类型：** WXT HTML entrypoint（`index.html` + React）

**子模块：**

| 文件 | 角色 |
|------|------|
| `index.html` | HTML 壳，`<script type="module" src="./main.tsx">` 引入 React 入口 |
| `main.tsx` | React 入口：`createRoot` → `render(<App />)` |
| `App.tsx` | React 组件，包含 UI 与交互逻辑 |
| `style.css` | Catppuccin Mocha 暗色主题样式 |

**App.tsx 内部结构：**

| 部分 | 说明 |
|------|------|
| State | `enabled: boolean` `loading: boolean` `stats: {active, waiting, stopped}` |
| `useEffect` | 挂载时通过 `runtime.sendMessage({type:"get-enabled"})` 获取初始状态 |
| `handleToggle` | 切换 enabled，通过 `runtime.sendMessage({type:"set-enabled"})` 通知后台 |
| `handleOpenAriaNg` | 通过 `tabs.create()` 打开 AriaNg（URL 包含 `#!/settings/rpc/set/...` 自动配置 RPC） |
| UI | Header（标题 + 状态点）、Toggle 开关、Open AriaNg 按钮、统计文字 |

**与后台的通信：** 仅使用 `browser.runtime.sendMessage`（`get-enabled` / `set-enabled`）。

---

## `main.content.ts` — MAIN World Content Script

**类型：** WXT content script（`defineContentScript`，`world: "MAIN"`）

**注入范围：** `<all_urls>` `document_start`

**职责：** 在页面 JavaScript 运行之前劫持 `fetch`、`XMLHttpRequest`、`WebSocket`。运行在页面的 JS 上下文中，故可直接覆写 `window` 上的 API。

**依赖（非 import，均为运行时 DOM API）：** 无模块导入。通过 `window.addEventListener/dispatchEvent` 与 bridge 通信。

**子模块（三个拦截器）：**

### 1. `window.fetch` 拦截器

```
覆盖 window.fetch
  ├─ URL 包含 localhost:6800 / 127.0.0.1:6800？
  │     ├─ init?.body 存在？
  │     │     → sendToBackground(body) → 返回 Response(json)
  │     └─ 无 body（GET 请求）
  │           → 返回 Response('{"result":"OK"}')
  └─ 非 aria2 URL
        → originalFetch(...) 透传
```

### 2. `XMLHttpRequest.prototype` 拦截器

**`open` 覆写：**
```
覆盖 XMLHttpRequest.prototype.open
  ├─ URL 匹配 localhost:6800？
  │     → 设置 this.__aria2 = true
  │     → 始终调用 origXHROpen（确保 readyState ≥ 1，使 setRequestHeader 可用）
  └─ 非 aria2 URL
        → origXHROpen(...)
```

**`send` 覆写：**
```
覆盖 XMLHttpRequest.prototype.send
  ├─ this.__aria2？
  │     → handleAria2Request(bodyStr)
  │         .then → Object.defineProperties 设置 readyState=4, status=200, responseText
  │                → dispatchEvent("load")  + dispatchEvent("loadend")
  │         .catch → dispatchEvent("error")
  └─ 非 aria2
        → origXHRSend(...)
```

### 3. `window.WebSocket` 拦截器

```
Proxy 拦截 WebSocket 构造函数
  ├─ URL 包含 localhost:6800？
  │     → new FakeWebSocket(url, protocols)
  └─ 非 aria2 URL
        → Reflect.construct(OriginalWebSocket, args)
```

**FakeWebSocket（内部类）：**
- `extends EventTarget`，实现 WebSocket 接口（CONNECTING/OPEN/CLOSING/CLOSED、readyState、send、close）
- 构造函数通过 `setTimeout(0)` 延迟触发 `open` 事件
- `send()` → `_handleMessage()` → `sendToBackground()` → 触发 `onmessage`
- `close()` → 延迟触发 `onclose` 事件
- 完全在内存中运行，无网络连接

**`sendToBackground()` — 与 bridge 通信：**
```
sendToBackground(body)
  ├─ 生成 crypto.randomUUID() 作为 _requestId
  ├─ Promise 包装：
  │     ├─ 注册 "aria2-shim-response" 监听器（过滤 _requestId）
  │     ├─ dispatchEvent("aria2-shim-request", {_requestId, body})
  │     └─ 30s 超时 → reject
  └─ 返回 Promise<unknown>
```

---

## `bridge.content.ts` — ISOLATED World Content Script

**类型：** WXT content script（`defineContentScript`，默认 ISOLATED world）

**注入范围：** `<all_urls>` `document_start`

**职责：** MAIN world（无 extension API）与 background（仅 extension 上下文可见）之间的桥接。

**依赖（非 import，均为运行时扩展 API）：** `browser.runtime.sendMessage` `window.addEventListener`

**消息流：**

```
注册 window.addEventListener("aria2-shim-request")
  ├─ 提取 {_requestId, body}
  ├─ browser.runtime.sendMessage({type:"aria2-rpc", payload:body})
  │     ├─ 成功 → dispatchEvent("aria2-shim-response", {_requestId, data})
  │     └─ 失败 → dispatchEvent("aria2-shim-response", {_requestId, error, data: rpcError})
  └─ (async 事件处理器)
```

**为什么需要 ISOLATED world 桥接：**
- MAIN world content script 可劫持页面 JS 对象，但无 `browser.runtime` 权限
- ISOLATED world content script 有完整扩展 API，但无法覆写页面的 `window.fetch`
- 两者通过 `window` 上的自定义事件通信（Chrome 在两个 world 间共享 DOM 事件目标）
