# Aria2-in-Browser 架构文档

## 项目概述

WXT 浏览器扩展（Chrome MV3），拦截 Aria2 JSON-RPC 调用并将其重定向到浏览器的原生下载管理器。用户可使用 AriaNg 作为下载管理界面，而由浏览器负责实际下载。

## 核心通信链路

```
AriaNg (页面)                          Extension
┌──────────────────┐             ┌──────────────────────────────┐
│ new WebSocket()  │───拦截───→  │ main.content.ts (MAIN world) │
│ fetch()          │   CustomEvent│   ↕ window.dispatchEvent    │
│ XMLHttpRequest   │             │ bridge.content.ts (ISOLATED) │
└──────────────────┘             │   ↕ runtime.sendMessage     │
                                 │ background.ts (ServiceWorker)│
                                 │   ↕                          │
                                 │ aria2-handler.ts             │
                                 │   ↕                          │
                                 │ download-manager.ts          │
                                 │   ↕                          │
                                 │ browser.downloads API        │
                                 └──────────────────────────────┘
```

## 模块清单

### entrypoints/ — WXT 扩展入口点

#### popup/ — 扩展弹窗（React）

| 文件 | 角色 |
|------|------|
| `index.html` | HTML entry，包含 `<script type="module" src="./main.tsx">` 使 Vite/Rolldown 正确打包 React 代码 |
| `main.tsx` | React 入口：`createRoot(document.getElementById("app")!).render(<App />)` |
| `App.tsx` | React 组件：enable/disable 开关 + "Open AriaNg" 按钮（带 hash RPC 设置） |
| `style.css` | Catppuccin Mocha 暗色主题样式 |

#### background.ts — Service Worker

- 注册 `browser.runtime.onMessage` 监听
- `"aria2-rpc"` → 分发给 `aria2-handler.ts`，异步返回响应
- `"set-enabled"` → 通过 `storage.ts` 启用/禁用，禁用时取消所有下载
- `"get-enabled"` → 返回当前启用状态
- 在 `beforeunload` 时调用 `downloadManager.destroy()` 进行清理

#### main.content.ts — MAIN world Content Script

注入所有页面（`<all_urls>`），`document_start`，在页面 JavaScript 运行之前执行。

**三个拦截器：**

1. **`window.fetch`** — 检查 URL 是否包含 `localhost:6800` 或 `127.0.0.1:6800`，如果包含则通过桥接层转发 body，并返回伪造的 Response
2. **`XMLHttpRequest.prototype.open/send`** — `open` 标记 `__aria2` 标志（始终调用原始 open 以确保 readyState ≥ 1，从而 setRequestHeader 能正常工作）；`send` 转发给桥接层并手动触发 `onload`/`loadend` 事件
3. **`window.WebSocket`** — Proxy 拦截构造函数；针对 aria2 URL 返回 FakeWebSocket，在内存中模拟 WebSocket 生命周期（open → send → message → close）

通过 `window.dispatchEvent`/`window.addEventListener` 与 ISOLATED world 通过自定义事件通信。

#### bridge.content.ts — ISOLATED world Content Script

注入所有页面（`<all_urls>`），`document_start`。

- 监听来自 MAIN world 的 `"aria2-shim-request"` 自定义事件
- 通过 `browser.runtime.sendMessage` 转发给后台
- 通过 `"aria2-shim-response"` 将结果分派回 MAIN world
- 捕获错误并作为带错误详情的结构化响应向上游传播

### core/ — 核心逻辑

#### types.ts — 类型定义

- **Aria2 JSON-RPC 类型：** `Aria2RpcRequest`、`Aria2RpcResponse`、`Aria2TaskInfo`、`Aria2VersionResult`、`Aria2GlobalStat`、`Aria2SessionInfo`、`MultiCallItem`
- **内部类型：** `DownloadRequest`、`DownloadTask`、`InternalStatus`、`TaskQuery`、`TaskChangeListener`
- **存储类型：** `AppSettings`、`StoredTask`、`DEFAULT_SETTINGS`
- **工具函数：** `toAria2Status()`（内部状态 → Aria2 RPC 状态）、`TERMINAL_STATUSES`（终态集合）

#### storage.ts — Settings 与 Task 持久化

- `browser.storage.local` 的封装
- **Settings：** `isEnabled()`、`setEnabled()`、`loadSettings()`、`saveSettings()`
- **Tasks：** `saveTasksSnapshot()`（含 maxHistory 去重）、`loadTasksSnapshot()`
- **Session：** `loadSessionId()`、`saveSessionId()`
- **变更监听：** `onSettingsChange()` 在 `browser.storage.onChanged` 触发时通知订阅的 handler

#### download-manager.ts — 下载管理器（单例）

**下载生命周期：**

```
pending → in_progress → complete / error / cancelled (终态)
  ↑                       ↑
  创建时                  paused (可恢复)
```

**`create(request)` 流程：**

1. 生成 16 字符 hex task ID
2. 创建 DNR（declarativeNetRequest）规则，注入 Content-Disposition header（及自定义 headers）
3. 通过 `browser.tabs.create({ url, active: false })` 打开隐藏标签以触发浏览器下载
4. `browser.downloads.onCreated` 监听器通过 URL 匹配浏览器下载与 task
5. `browser.downloads.onChanged` 监听器跟踪进度/状态变化
6. 变更通过 3 秒定时器防抖持久化至 `browser.storage.local`

**主要方法：** `create`、`pause`、`resume`、`cancel`、`cancelAll`、`getTask`、`queryTasks`（含 status 过滤）、`removeTask`、`purgeCompleted`、`destroy`、`init`（从存储恢复）

#### aria2-handler.ts — JSON-RPC 方法调度器

**入口点：** `handleAria2Request(body)` — 处理 single、batch（数组）、`system.multicall`

**支持的方法：**

| 类别 | 方法 |
|------|------|
| 下载 | `aria2.addUri` |
| 控制 | `aria2.pause`、`aria2.forcePause`、`aria2.unpause`、`aria2.remove`、`aria2.forceRemove`、`aria2.pauseAll`、`aria2.forcePauseAll`、`aria2.unpauseAll` |
| 查询 | `aria2.tellStatus`、`aria2.tellActive`、`aria2.tellWaiting`、`aria2.tellStopped` |
| URI/文件 | `aria2.getUris`、`aria2.getFiles`、`aria2.getPeers`（空数组）、`aria2.getServers`（空数组） |
| 选项 | `aria2.getOption`、`aria2.changeOption`、`aria2.getGlobalOption`、`aria2.changeGlobalOption` |
| 统计 | `aria2.getGlobalStat` |
| 系统 | `aria2.getVersion`、`aria2.getSessionInfo`、`aria2.shutdown`、`aria2.forceShutdown` |
| 队列 | `aria2.changePosition`、`aria2.changeUri` |
| 自省 | `system.listMethods`、`system.listNotifications`、`system.multicall` |
| 清理 | `aria2.removeDownloadResult`、`aria2.purgeDownloadResult` |

**Auth：** 支持 `--rpc-secret` token（`token:xxx` 前缀）。设置 secret 后需要提供 token。

**不支持：** BitTorrent（`aria2.addTorrent`）、Metalink（`aria2.addMetalink`）、FTP。

### public/icon/ — 扩展图标

16/32/48/96/128 px 的 PNG 文件。

### tests/ — 测试套件（Vitest）

#### setup.ts — 全局 browser mock

- 完整的 `browser` API mock：`storage.local`（get/set/remove + onChanged）、`downloads`（onCreated/onChanged/pause/resume/cancel/search）、`tabs`（create/remove）、`declarativeNetRequest`（updateSessionRules + HEADER/SET/MODIFY_HEADERS/MAIN_FRAME 常量）、`runtime`（sendMessage/onMessage）
- 自动重建设置：每个 test 重建 mock 实例，复制初始 mock 中的持久化监听器

#### 测试文件

| 文件 | 内容 |
|------|------|
| `types.test.ts` | `toAria2Status()` 状态映射、`TERMINAL_STATUSES` 内容 |
| `storage.test.ts` | Settings/session/tasks 快照持久化、onSettingsChange 处理 |
| `download-manager.test.ts` | 下载生命周期、DNR 规则注入、浏览器下载匹配、init 恢复、销毁 |
| `aria2-handler.test.ts` | 全部 RPC 方法（mock 了 downloadManager）— JSON-RPC 基础、addUri、控制、查询、统计、system.multicall、禁用状态、auth |
| `integration.test.ts` | **新增** — 4 个场景组，包含 23 个测试（见下方） |

#### integration.test.ts — 集成测试（4 个场景组，共 23 个测试）

**1. Integration: RPC → Download Pipeline（15 个测试）**

真实导入（非 mock）的 `aria2-handler` + `download-manager` + `storage` 串联：

- 完整下载生命周期：`addUri` → 浏览器下载匹配 → `tellStatus` 进度更新
- 下载完成 / 中断 → 状态转换至终态
- 通过 RPC 的 pause / unpause / remove 控制
- `shutdown` 禁用扩展并取消所有下载
- 任务跨"Service Worker 重启"的持久化与恢复（使用 `vi.useFakeTimers()` 提前触发延时写入）
- `destroy()` 后从存储恢复时，将 pending 任务正确标记为 error（已丢失 tab/rule）
- `getGlobalStat` 反映真实的下载管理器状态
- 通过 `rpcSecret` / enabled toggle 进行错误处理

**2. Integration: Background Message Handler（3 个测试）**

模拟 `background.ts` 的 `runtime.onMessage` 分发：

- 完整 `aria2-rpc` 消息管道 → 返回正确的 JSON-RPC 响应
- `get-enabled` / `set-enabled` 状态同步
- 设置为 disabled 时取消活跃下载

**3. Integration: Bridge Protocol（4 个测试）**

使用 `EventTarget` 模拟 MAIN ↔ ISOLATED world 的 CustomEvent 通信：

- 完整往返：dispatch → background → response → resolve
- 错误从 bridge 传播至 MAIN world
- bridge 无响应时超时
- `_requestId` 过滤：忽略错误 requestId 的响应

**4. Integration: Settings Change Propagation（2 个测试）**

`storage.onChanged` → changeHandler 链：

- 设置变更时触发已注册的 handler
- 忽略无关 key 的变更

### 配置层

| 文件 | 作用 |
|------|------|
| `wxt.config.ts` | WXT 构建配置 — React module、permissions（downloads、declarativeNetRequest、tabs、storage）、host_permissions |
| `vitest.config.ts` | Vitest 配置 — 全局 mock、`@` 路径别名 |
| `tsconfig.json` | TypeScript 配置 — 继承 `.wxt/tsconfig.json`，开启 JSX |
| `package.json` | 依赖 — react、wxt、`@wxt-dev/module-react`、vitest |

## 数据流细节

### 下载生命周期

```
用户操作 AriaNg
  │
  ▼
AriaNg 发送 aria2.addUri([urls], options)
  │
  ▼
main.content.ts 拦截 WebSocket/HTTP → 桥接到 ISOLATED world
  │
  ▼
bridge.content.ts → browser.runtime.sendMessage({type:"aria2-rpc"})
  │
  ▼
background.ts → handleAria2Request(payload)
  │
  ▼
aria2-handler.ts: callMethod("aria2.addUri", params)
  │  parseAddUri() → DownloadRequest
  ▼
download-manager.ts: create(request)
  │  1. 生成 taskId
  │  2. DNR 规则注入 Content-Disposition / 自定义 headers
  │  3. browser.tabs.create({url, active:false}) 触发下载
  │  4. 状态 → "pending"，2 分钟超时定时器启动
  ▼
browser.downloads.onCreated → 通过 URL 匹配 task
  │  状态 → "in_progress"
  │  清除超时、移除标签和 DNR 规则
  ▼
browser.downloads.onChanged → 跟踪进度
  │  bytesReceived、totalBytes、speed、状态变更
  ▼
终态 (complete / error / cancelled)
```

### 跨世界通信

```
MAIN world (main.content.ts)
  │  window.dispatchEvent(new CustomEvent("aria2-shim-request", {detail}))
  │
  ▼ Chrome 在两个 world 间共享 DOM 事件
ISOLATED world (bridge.content.ts)
  │  window.addEventListener("aria2-shim-request", handler)
  │  browser.runtime.sendMessage({type:"aria2-rpc", payload})
  │
  ▼ 扩展 API（仅 ISOLATED world 可用）
Service Worker (background.ts)
  │  browser.runtime.onMessage.addListener(handler)
  │  handleAria2Request(payload) → 响应
  ▼
响应沿原路返回：
  background → sendResponse → bridge → dispatchEvent("aria2-shim-response")
  → MAIN world → resolve Promise
```
