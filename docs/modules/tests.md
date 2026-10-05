# Tests 模块

## 测试基础设施

**框架：** Vitest（`yarn test` / `yarn test:watch`）

**配置：** [vitest.config.ts](../../vitest.config.ts)
- `globals: true` — 无需显式导入 `describe` / `it` / `expect`
- `setupFiles: ["./tests/setup.ts"]` — 每个测试前注入 browser mock
- `alias: { "@": "<root>" }` — 与 WXT 构建一致的路径别名

---

## `tests/setup.ts` — 全局 Browser Mock

**职责：** 提供完整的 `browser` 扩展 API mock，使所有测试可在 Node.js 中运行。

**`createBrowserMock()` 工厂函数：** 每次调用生成全新 mock 实例。

| mock 域 | mock 的 API | 行为 |
|---------|------------|------|
| `storage.local` | `get` `set` `remove` | 内存 Map 实现 |
| `storage.onChanged` | `addListener` `removeListener` | 内部 listener 数组 |
| `downloads` | `onCreated` `onChanged` `pause` `resume` `cancel` `search` | listener 数组 + 可配置返回值 |
| `tabs` | `create` `remove` | `create` 返回 `{id: 999, ...opts}` |
| `declarativeNetRequest` | `updateSessionRules` | 无操作 |
| | `HeaderOperation` `RuleActionType` `ResourceType` | 字符串常量 |
| `runtime` | `sendMessage` `onMessage` | 可配置 mock |

**自动重建设置：**

```
模块加载时：
  创建 initMock → 设置 globalThis.browser → 保存 _internal

每个测试前（vitest beforeEach）：
  1. 创建全新 mock 实例
  2. 从 initMock._internal 复制持久化监听器（storage.onChanged 等）
  3. 设置 globalThis.browser = 新 mock
  4. 后续 import 的模块在此全新 mock 上注册监听器
```

---

## 测试文件

### `types.test.ts` — 类型辅助函数（2 个测试）

| 测试 | 说明 |
|------|------|
| `toAria2Status` | 六个内部状态到 Aria2 状态的映射 |
| `TERMINAL_STATUSES` | 终态集合包含/排除验证 |

**无依赖**，纯函数测试。

---

### `storage.test.ts` — Settings / Session / Tasks 持久化（10 个测试）

4 个 describe 块：

| describe | 测试数 | 验证点 |
|----------|--------|--------|
| Settings persistence | 4 | 默认值、保存/加载合并、`isEnabled`、`setEnabled` 只改 enabled |
| Session ID persistence | 3 | null 初始、保存/加载、覆盖 |
| Task snapshot persistence | 3 | 空返回、保存/加载往返、maxHistory 截断 |
| `onSettingsChange` | 1 | 触发回调 + 取消订阅 |

**依赖模拟：** 无，使用全局 browser mock 的 `storage.local` 和 `onChanged`。

---

### `download-manager.test.ts` — 下载管理器（18 个测试）

1 个 describe 块。**Mock：** `loadTasksSnapshot` `saveTasksSnapshot`（来自 storage.ts）。

| 测试 | 验证点 |
|------|--------|
| `create` 打开后台标签 | tab URL 正确，`active: false` |
| `create` 注入 DNR 规则 | `updateSessionRules` 传入正确的 urlFilter |
| `create` 存储 task | `getTask` 返回 pending 状态 + 完整 request |
| `create` tab 创建失败 | task 标记为 error |
| `cancel` | 状态变为 cancelled，completedAt 已设置 |
| `cancelAll` | 所有非终态 task 变为 cancelled |
| `queryTasks` 排序 | 按 createdAt 降序 |
| `queryTasks` status 过滤 | 按单个状态过滤 |
| `removeTask` 终态删除 | 删除成功，`getTask` 返回 undefined |
| `removeTask` 活跃任务拒绝 | 返回 false |
| `purgeCompleted` | 删除所有终态任务 |
| `init` 恢复已完成任务 | 状态正确恢复 |
| `init` pending 标记为 error | error 消息包含 "restarted" |
| `init` 重新连接活跃下载 | 从 `downloads.search` 恢复进度 |
| `init` 丢失的浏览器下载 | 标记为 error，消息包含 "lost" |
| `onCreated` 匹配 | URL 匹配 → pending → in_progress |
| `onChanged` 完成 | state: "complete" → 终态 |
| `onChanged` 中断 | state: "interrupted" + error → 终态 + errorMessage |
| `destroy` 清理 | 取消活跃下载 |

---

### `aria2-handler.test.ts` — RPC 方法调度器（35 个测试）

1 个 describe 块，6 个功能域。**Mock：** `downloadManager`（全部方法 mock）。

| 域 | 测试数 | 示例验证点 |
|----|--------|-----------|
| JSON-RPC 基础 | 3 | 正确的 2.0 响应、未知方法 error、batch 数组处理 |
| `addUri` | 5 | GID 返回、多 URL、空 uri error、token 前缀剥离 |
| 不支持的方法 | 2 | addTorrent / addMetalink 返回 "not supported" |
| 控制方法 | 9 | pause/unpause/remove/forceRemove 调用 dm、pauseAll/unpauseAll 批量操作 |
| 查询方法 | 5 | tellStatus（含字段过滤）、tellActive/Waiting/Stopped |
| 统计与系统 | 8 | getVersion 特性列表、getSessionInfo 缓存、shutdown 禁用 + 取消、changeGlobalOption |
| `system.multicall` | 3 | 批量处理、错误包装、listMethods 返回全部方法 |
| 禁用状态 | 1 | 禁用时返回 -32000 |
| token auth | 3 | 无 token 拒绝、正确 token 接受、错误 token 拒绝 |
| 边界情况 | 3 | 空 params、id=0、getPeers/getServers 返回 [] |

---

### `integration.test.ts` — 集成测试（23 个测试）

4 个 describe 块，**无 mock**（使用真实 core 模块）。

| 场景组 | 测试数 | 验证点 |
|--------|--------|--------|
| RPC → Download Pipeline | 15 | 完整生命周期、持久化/恢复、统计、auth/disabled |
| Background Message Handler | 3 | 消息路由、get/set-enabled、禁用时取消 |
| Bridge Protocol | 4 | 往返、错误传播、超时、requestId 过滤 |
| Settings Change Propagation | 2 | onChanged 触发 handler、忽略无关 key |

详见 [integration.test.ts](../../tests/integration.test.ts)。
