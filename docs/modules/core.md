# Core 模块

四个纯逻辑模块，不依赖浏览器扩展特定的构建语义，可在 Node 测试中直接导入。

## 依赖关系

```
types.ts  ←──  storage.ts  ←──  download-manager.ts  ←──  aria2-handler.ts
   ↑              ↑                    ↑                        ↑
   └──────────────┴────────────────────┴────────────────────────┘
                (所有模块均依赖 types.ts)
```

---

## `types.ts` — 类型定义（无运行时依赖）

**职责：** 项目中所有 TypeScript 类型与常量的唯一来源。

**子模块：**

| 子模块 | 内容 |
|--------|------|
| Aria2 JSON-RPC 类型 | `Aria2RpcRequest` `Aria2RpcResponse` `Aria2TaskInfo` `Aria2VersionResult` `Aria2GlobalStat` `Aria2SessionInfo` `Aria2FileInfo` `Aria2UriInfo` `MultiCallItem` |
| 内部任务类型 | `DownloadRequest` `DownloadTask` `InternalStatus` `TaskQuery` `TaskChangeListener` |
| 存储类型 | `AppSettings` `StoredTask` `DEFAULT_SETTINGS` |
| 常量 | `TERMINAL_STATUSES: Set<"complete"|"error"|"cancelled">` |
| 辅助函数 | `toAria2Status(s: InternalStatus): Aria2TaskStatus` — 映射内部状态到 aria2 RPC 状态 |

**被以下模块导入：** `storage.ts` `download-manager.ts` `aria2-handler.ts` 所有测试文件

---

## `storage.ts` — 持久化层

**职责：** 封装 `browser.storage.local`，提供 settings、task snapshot、sessionId 的读写。

**依赖：** `types.ts`

**导出接口：**

| 函数 | 签名 | 说明 |
|------|------|------|
| `loadSettings` | `() => Promise<AppSettings>` | 读取设置（与 DEFAULT_SETTINGS 合并） |
| `saveSettings` | `(s: AppSettings) => Promise<void>` | 持久化设置 |
| `isEnabled` | `() => Promise<boolean>` | 读取 enabled 标志 |
| `setEnabled` | `(v: boolean) => Promise<void>` | 设置 enabled（保持其他字段不变） |
| `saveTasksSnapshot` | `(tasks: Map<string,DownloadTask>, max?: number) => Promise<void>` | 保存任务快照（按时间排序，截断） |
| `loadTasksSnapshot` | `() => Promise<StoredTask[]>` | 载入任务快照 |
| `loadSessionId` | `() => Promise<string\|null>` | 载入持久化 session ID |
| `saveSessionId` | `(sid: string) => Promise<void>` | 保存 session ID |
| `onSettingsChange` | `(handler) => () => void` | 注册变更回调，返回取消订阅函数 |

**模块级副作用：** 注册 `browser.storage.onChanged` 监听器，检测 `settings` key 变更后遍历 `changeHandlers` Set 通知所有订阅者。

**被以下模块导入：** `download-manager.ts` `aria2-handler.ts` `background.ts`

---

## `download-manager.ts` — 下载任务管理器（单例）

**职责：** 将 aria2 下载请求映射到浏览器原生下载，跟踪生命周期，持久化任务状态。

**依赖：** `types.ts` `storage.ts`

**单例：** `export const downloadManager = new DownloadManager()`

**构造时副作用：** 注册 `browser.downloads.onCreated` 和 `browser.downloads.onChanged` 监听器。

**子模块（内部方法分组）：**

| 分组 | 方法 | 说明 |
|------|------|------|
| 生命周期 | `init()` | 从存储恢复任务 |
| | `destroy()` | 清理：取消下载、移除标签、删除 DNR 规则、持久化 |
| 任务操作 | `create(req: DownloadRequest): Promise<string>` | 创建任务 → DNR 注入 header → 打开隐藏 tab → 返回 GID |
| | `pause(taskId)` | 暂停浏览器下载 |
| | `resume(taskId)` | 恢复浏览器下载 |
| | `cancel(taskId)` | 取消任务，标记为 cancelled |
| | `cancelAll()` | 取消所有非终态任务 |
| 查询 | `getTask(taskId): DownloadTask\|undefined` | 按 GID 查询 |
| | `queryTasks(filter?: TaskQuery): DownloadTask[]` | 条件查询（支持 status 过滤、offset、limit） |
| 清理 | `removeTask(taskId): boolean` | 删除终态任务（非终态拒绝删除） |
| | `purgeCompleted(): number` | 清除所有终态任务 |
| 事件 | `onTaskChange(listener): () => void` | 注册变更监听器 |
| 内部 | `injectHeaders()` | 创建 DNR 规则注入 Content-Disposition / 自定义 header |
| | `cleanup()` | 删除 DNR 规则、关闭关联标签 |
| | `onBrowserDownloadCreated` | 通过 URL 匹配浏览器下载与等待中的 task |
| | `onBrowserDownloadChanged` | 跟踪进度更新（bytesReceived、totalBytes、speed、状态） |
| | `schedulePersist` / `flushPersist` / `persistNow` | 3 秒防抖持久化 |

**创建流程：**

```
create(request)
  ├─ generateId()        → 16 字符 hex GID
  ├─ injectHeaders()     → DNR 规则（Content-Disposition, custom headers）
  ├─ tabs.create()       → 打开隐藏标签触发浏览器下载
  └─ 状态 → "pending"    → 启动 120s 超时定时器
       │
       ▼ onCreated 事件
  通过 URL 匹配 task → status → "in_progress"
  ├─ clearTimeout()      → 取消超时
  ├─ cleanup()           → 移除 DNR 规则 / 关闭标签
  └─ 状态通过 onChanged 持续跟踪
```

**被以下模块导入：** `aria2-handler.ts` `background.ts`

---

## `aria2-handler.ts` — Aria2 JSON-RPC 方法调度器

**职责：** 解析 JSON-RPC 请求、分发到具体 method handler、返回标准响应。

**依赖：** `types.ts` `storage.ts` `download-manager.ts`

**导出接口：**

| 函数 | 签名 |
|------|------|
| `handleAria2Request` | `(body: Request\|Request[]) => Promise<Response\|Response[]>` |

**入口处理流：**

```
handleAria2Request(body)
  ├─ body 是数组？
  │     → Promise.all(body.map(handleSingle))
  ├─ body.method === "system.multicall"？
  │     → 遍历 calls[] 依次调用 callMethod，错误包装为 {code, message}
  └─ 否则
        → handleSingle(body)
            ├─ isEnabled()？ → 否 → rpcError(-32000)
            ├─ rpcSecret？ → token 校验
            └─ callMethod(method, params)
```

**子模块（按功能域分组的 RPC 方法）：**

| 域 | 方法 | 内部操作 |
|----|------|----------|
| auth | 所有方法共用 | `isEnabled()` 检查 | token:xxx 前缀 |
| 创建 | `aria2.addUri` | `parseAddUri()` → `downloadManager.create()` |
| 控制 | `pause` `forcePause` | `downloadManager.pause(gid)` |
| | `unpause` | `downloadManager.resume(gid)` |
| | `remove` `forceRemove` | `downloadManager.cancel(gid)` |
| | `pauseAll` `forcePauseAll` | 获取所有 in_progress → 逐个 pause |
| | `unpauseAll` | 获取所有 paused → 逐个 resume |
| 查询 | `tellStatus` | `downloadManager.getTask()` → `buildTaskInfo()` |
| | `tellActive` | `downloadManager.queryTasks({status:"in_progress"})` |
| | `tellWaiting` | `downloadManager.queryTasks({status:["pending","paused"]})` |
| | `tellStopped` | `downloadManager.queryTasks({status:["complete","error","cancelled"]})` |
| 元数据 | `getUris` `getFiles` | 从 DownloadTask 构建 URI/文件信息 |
| | `getPeers` `getServers` | 返回 `[]`（无 BT/P2P） |
| 选项 | `getOption` `changeOption` `getGlobalOption` `changeGlobalOption` | 读取/写入 storage settings |
| 统计 | `getGlobalStat` | 遍历全部 task 聚合 numActive/numWaiting/numStopped/speed |
| 系统 | `getVersion` | 返回 `"1.37.0-shim"` + 特性列表（无 BT/FTP） |
| | `getSessionInfo` | 返回持久化 sessionId |
| | `shutdown` `forceShutdown` | `cancelAll()` → `setEnabled(false)` |
| 自省 | `system.listMethods` | 返回全部支持的 method 名称 |
| | `system.listNotifications` | 返回 `[]` |
| | `system.multicall` | 批量调用，每个子调用错误包装为 `{code, message}` |
| 不支持 | `addTorrent` `addMetalink` | 抛出 `{code:-32000, message:"xxx not supported"}` |

**内部辅助函数：**

| 函数 | 说明 |
|------|------|
| `handleSingle(request)` | 单条 JSON-RPC 请求的处理：auth 检查 → `callMethod()` → `rpcOk/rpcError` |
| `callMethod(method, params)` | 按 method 名称分派，返回结果或抛出 `{code, message}` |
| `buildTaskInfo(task, keys?)` | 将内部 DownloadTask 映射为 Aria2TaskInfo（支持字段过滤） |
| `buildGlobalStat()` | 遍历全部 task 聚合统计信息 |
| `parseAddUri(params)` | 从 aria2.addUri params 解析出 DownloadRequest（url、headers、filename 等） |
| `stripToken(params)` | 从 params 中剥离 `token:xxx` 前缀 |
| `getSessionId()` | 获取或生成持久化 session ID（缓存 + storage 后备） |
| `rpcOk(id, result)` / `rpcError(id, code, msg)` | 构造标准 JSON-RPC 响应 |

**被以下模块导入：** `background.ts`
