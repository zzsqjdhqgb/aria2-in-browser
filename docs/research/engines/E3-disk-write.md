# E3 — 字节落盘：流式写大文件与持久化边界

## 0 元信息

| 项 | 值 |
|---|---|
| 文档编号 | E3（引擎研究 / 字节落盘） |
| 主题 | 把已经到手的字节写到哪、怎么落盘、能不能流式写；执行上下文差异与拦截/生命周期边界 |
| 作者 | eng-disk（AgentTeams `aria2-in-browser-boundary`） |
| 产出日期 | 2026-10-06 |
| 证据核对日期 | **2026-10-06（UTC）**；所有网络文档均为当日实时抓取 |
| 目标读者 | 后续「能力清单」「能力 → 接口行为规则表」「详细设计」 |
| 上游输入 | `/workspace/docs/concept-design/concept-design.md` v0.5（R1–R13 为硬性裁定；附录 A 为已知下载引擎样例） |
| 范围（含） | 落盘目标选择、流式写入、用户可见性、配额与持久化、句柄/权限跨会话、各执行上下文可用性 |
| 范围（不含） | 如何取得字节（fetch / DNR / XHR / WebSocket 等，属 E1/E2）；RPC 协议实现；UI 设计；性能基准实测 |
| 方法 | 只采信官方文档/规范/浏览器官方源码；每条结论附 URL 与关键原文摘录；查不到的一律进 §7「未验证」，不做记忆性断言 |
| 环境限制 | 本执行环境**没有可用的浏览器二进制**（`google-chrome`/`chromium` 均不存在），因此**没有任何实测数据**；所有结论均为文档/规范/源码层面 |

### 0.1 证据等级定义（全文使用）

| 等级 | 含义 | 判定 |
|---|---|---|
| **A** | 规范（WHATWG/W3C/WICG）或浏览器官方文档（MDN、developer.chrome.com、web.dev）的逐字陈述 | 可直接作为结论依据 |
| **B** | 浏览器官方源码 / 官方 bug 跟踪 / 官方企业策略定义中的实现事实 | 作为「实现事实」依据，非规范承诺 |
| **C** | 推断（由 A/B 组合推出，但官方文档没有逐字对应句） | 必须显式标注，写入 §7 待验证 |
| **U** | 未验证（查不到官方来源） | 只写进 §7，正文不得当结论用 |

### 0.2 适用版本基线

- Chrome/Chromium：以 **Chrome 122+**（持久权限行为引入）为基线；文档中出现的更晚特性（如 `offscreen.hasDocument()` 标注 Chrome 150+，E9）说明抓取到的文档对应 2026 年下半年的 Chrome。
- 文档页「最后更新」：Chrome `downloads` API 页 2026-10-04、`offscreen` 页 2026-09-21、`service-worker lifecycle` 页 2023-05-02、`storage-and-cookies` 页 2023-09-28（均在 §8 标注）。
- 其它浏览器：Firefox / Safari 在关键 API 上**与 Chrome 差异极大**（见 §4.2），文中逐条标注。

---

## 1 一句话结论

### 1.1 正面回答任务要求的四问

**Q：能不能把一个 4GB 级的文件流式写到用户磁盘、内存不爆？**

**能，但只有「两条能把文件交到用户磁盘的路 + 一条沙箱暂存路」，取舍各不相同：**

1. **File System Access API（`showSaveFilePicker` → `FileSystemWritableFileStream`）**：可以。写入是 `WritableStream` 语义，规范要求实现「不要把 buffer 全放内存，而用临时文件」，并承诺**背压**；只要按 chunk `await` 写入 / `pipeTo`，JS 堆上只有当前 chunk，内存不随文件增长（[E2]）。**这是唯一能把 GB 级字节落到「用户自己选的、用户能在文件管理器里看到的磁盘位置」的内存安全路径。**
   - 代价 1：必须在一个**有瞬时用户激活（transient user activation）的 Window 上下文**里调用 picker；picker 的规范门槛是「global 必须是 Window」+「必须有 transient activation」+「与 top-level 同源」（[E1]）。
   - 代价 2：`createWritable()` 的实现语义是**「写临时文件、close 时才替换目标」**，所以**磁盘峰值 ≥ 文件大小**，且**中途崩溃/中断不会留下可续用的部分文件**；Chrome **没有**实现 in-place 模式（[E2] 明确写 "This is not currently implemented in Chrome"）。
   - 代价 3：`close()` 会跑「implementation-defined malware scans and safe browsing checks」，失败时以 `AbortError` 拒绝（[E2]）——即**「字节全都写完了，但最后一步落盘失败」**是规范允许的，必须报错而不能当成功（R2/R10）。

2. **浏览器原生下载流（`chrome.downloads.download()`，或附录 A 的 `chrome.tabs` + DNR）**：也可以，而且**最省内存（JS 完全不接触字节）、不受存储配额约束**；但**落点不可由扩展精确控制**（`filename` 只能是「相对 Downloads 目录」的路径，绝对路径报错 [E23]），且字节不回流到 JS（无法做 aria2 式的分片/校验/RPC 层进度合成，只能读 `chrome.downloads` 自己的事件）。

3. **OPFS（`navigator.storage.getDirectory()`）**：可以流式写、内存安全、**不需要任何用户手势**，但**文件不在“用户磁盘”的可见位置**——MDN 原文：「The OPFS is not intended to be visible to the user」（[E6]）。要交给用户，必须再做**第二次 1:1 复制/下载**（见 §2.3、§5）。

**不能**：`Blob` + `URL.createObjectURL` + `a[download]`、`data:` URL、纯内存缓冲 —— 这三条都要先**把整个文件物化成一份完整对象**，GB 级必然撞上内存/实现上限（§2.4–2.6）。

**Q：在哪个执行上下文里可以？**

| 动作 | 可用的上下文 | 依据 |
|---|---|---|
| 调用 FSA picker（`showSaveFilePicker`） | **只有 Window 且有瞬时用户激活**：扩展页（标签页）、popup、side panel；普通网页（由 MAIN world 注入脚本借页面的 Window 与手势调用，但权限归页面源，不适合本产品）。**MV3 service worker、offscreen document、任何 Worker 都不行**（SW 没有 `window`；offscreen 明确「can't be focused」，拿不到用户激活） | [E1]（Window-only + activation）、[E9]（offscreen 不可聚焦）、[E25]（策略文档复述「必须先前有用户手势」） |
| 向已有句柄流式写入（`createWritable().write()`） | 任何持有句柄且权限为 `granted` 的 **Window 或 Worker**（`FileSystemWritableFileStream` 是 `[Exposed=(Window, Worker)]`） | [E2] IDL、[E4] |
| OPFS 写入 | 同上，且**规范上包含 service worker**（`StorageManager` 是 `[Exposed=(Window, Worker)]`）；同步句柄 `createSyncAccessHandle()` **仅 DedicatedWorker** | [E2] IDL、[E5] |
| `chrome.downloads` 触发原生下载 | 任何能调用扩展 API 的上下文（MV3 SW、扩展页、popup、side panel）；**内容脚本不能直接调用**（只能直接访问 `dom/i18n/storage/runtime` 子集，须消息转发 [E36]）；offscreen 只能用 `runtime`，同样须转发 [E9]。下载由浏览器进程执行，不依赖 JS 存活 | [E23]、[E9]、[E36]、[E10] |
| `URL.createObjectURL` | **Window / DedicatedWorker / SharedWorker；Service Worker 不暴露** | [E17] 规范 IDL、[E18] Chromium IDL、[E19] MDN |

**Q：用户交互成本是多少？**

| 途径 | 交互成本 | 跨会话 |
|---|---|---|
| FSA picker | **1 次点击 + 1 次「保存」对话框**（每个会话/每次新建目标）；对**没有权限请求管理器**的扩展上下文（如 popup、side panel），Chromium 会自动授予写权限、不再多弹一个框（[E26]）；扩展页标签页是否也自动授予见 §7 **U2b** | Chrome 122+ 会出现三选一提示（本次/每次访问/拒绝），选「每次访问」后可持久；否则下次需再次手势（[E8]） |
| `chrome.downloads` | 默认 **0 次**；`saveAs: true` 时 1 次文件选择框（[E23]） | 无状态，每次都要用户操作（若配了 saveAs） |
| 附录 A 的 tabs+DNR | **0 次点击**，但会**打开一个标签页**（可见副作用） | 同理 |
| OPFS | **0 次**，但用户在文件管理器里**找不到文件**；取回要额外一步（另一次手势或另一次下载） | 需要处理配额/驱逐 |

**Q：最大风险？**
**「任务被接受、进度看起来在跑，最终用户拿不到文件」**——即撞上 R10/R2 红线。三条具体来源：(a) picker 需要手势，SW 里做不到 ⇒ 引擎不能在无人值守时"开始下载"；(b) `close()` 的安全检查失败会整份作废（[E2]）；(c) OPFS 落点对用户不可见 ⇒ 若不做导出，"下载完成"对用户等于 0 收益。

### 1.2 落盘途径 × 上下文（速查，详见 §4.2）

图例：✅ 官方文档直接支持；🟡 有条件（需手势/需句柄转交/推断）；❌ 不可用；❓ 未验证。

| 上下文 \ 途径 | FSA picker | FSA 流式写（已有句柄） | OPFS 写入 | `chrome.downloads` | Blob+`a[download]` | `data:` URL |
|---|---|---|---|---|---|---|
| MV3 service worker | ❌ [E1] | ❓（权限须先由 Window 授予） | 🟡（规范允许，Chrome 文档未列明） | ✅ [E23] | ❌ 无 `createObjectURL` [E18] | ✅ 但 ≤2MB 有效 [E22] |
| offscreen document | ❌（不能聚焦 ⇒ 无激活）[E9] | ❓ 同上 | 🟡 | ✅ | ✅（`BLOBS` reason 明示）[E9] | ✅ 但 ≤2MB |
| 扩展页（标签页，chrome-extension://） | 🟡 机制上成立（Chromium 有 `chrome-extension` 源分支 [E26]），但「扩展页可用」本身及写权限是否自动授予见 §7 U1 / U2b | ✅ | ✅ | ✅ | ✅ | ✅ |
| popup | ✅ 但**页面随失焦销毁**，不能承载长写 [E32] | 🟡（短任务可用） | 🟡 | ✅ | 🟡 | 🟡 |
| side panel | ✅（视为扩展页）[E26] | ✅ | ✅ | ✅ | ✅ | ✅ |
| 内容脚本（ISOLATED）/ MAIN world | ❓（归属页面源；未查到官方逐字说明） | 🟡 | ❌（用宿主页面的存储） | ✅（扩展 API） | 🟡 | 🟡 |
| 扩展源的 Dedicated Worker | ❌ | ✅（受权限约束） | ✅（含同步句柄） | ❌（无扩展 API） | ✅ | ✅ |
| 页面里的 Worker | ❌ | 🟡 | ✅ | ❌ | ✅ | ✅ |

### 1.3 这条途径在「下载引擎候选」里的定位

- **落盘不是「引擎」，而是所有引擎都要选一个的「末端」**。它的能力直接决定引擎能声明哪些原子能力（R11）、以及哪些 aria2 语义只能「不实现」。
- 定位建议：**`chrome.downloads` 原生流是「默认落盘末端」（0 交互、0 内存、0 配额）**；**FSA 是「需要用户指定路径 / 需要 JS 掌握字节（分片、校验、header 注入后自取）时的唯一大文件末端」**；**OPFS 只是「中转缓存 / 断点续传的暂存区」，不能当作交付给用户的终点**。

---

## 2 机制

### 2.0 三条根本不同的字节通路（先分清「谁持有字节」）

```
通路 A（原生下载流）：网络 -> 浏览器进程（下载系统）-> 磁盘
        JS 只提交 URL / 观察事件，从不持有字节。代表：chrome.downloads、tabs+DNR。
通路 B（JS 自取 + JS 落盘）：网络 -> fetch ReadableStream -> JS -> FileSystemWritableFileStream -> 磁盘
        字节经过渲染进程/Worker 的 JS 堆（按 chunk），落点由句柄决定。代表：FSA(用户选文件)、OPFS。
通路 C（物化后再交付）：网络 -> JS/Blob 存储（整份对象）-> blob:/data: URL -> 浏览器下载系统 -> 磁盘
        必须先完整持有整份字节（内存或浏览器 blob 存储），再把 URL 交给下载系统。
```

**这三条通路的差别不是「快慢」，而是「字节是否必须完整存在过」「落点谁决定」「JS 是否会因生命周期被杀而中断」。** 后文所有结论都由这三个问题派生。

### 2.1 通路 A：原生下载流

**A-1 `chrome.downloads.download()`**

- 机制：扩展提交 `DownloadOptions`（`url` / `filename` / `conflictAction` / `saveAs` / `headers` / `method` / `body`），浏览器下载系统自己取字节、自己写盘；扩展只拿到 `downloadId` 与事件流。
- 字节归属：**扩展侧 JS 不接触字节**（由 API 契约推定：API 只暴露 URL 与事件，没有任何字节回传接口；docs 无逐字声明，标 C）。
- **写盘细节有官方描述**：`acceptDanger` 条目里写明「When all the data is fetched into a temporary file and either the download is not dangerous or the danger has been accepted, then the temporary file is renamed to the target filename, the state changes to 'complete'」（[E23]）——即**原生下载也是「临时文件 + 改名」，且「危险文件」会插入一个用户审批环节**。
- 落点：`filename` = 「A file path relative to the Downloads directory …；Absolute paths, empty paths, and paths containing back-references ".." will cause an error.」（[E23]）⇒ **扩展无法把文件写到 Downloads 之外的绝对路径**（用户可用 `saveAs` 自选，但那是每次交互）。
- 用户手势：文档**未列出**手势要求（与 FSA 形成鲜明对比）；`saveAs`/`filename` 都会走浏览器的保存流程。`acceptDanger` 明确「Can only be called from a visible context (tab, window, or page/browser action popup)」（[E23]）——**这说明「危险下载的处理」必须在可见上下文，SW/offscreen 不可**。
- `data:` URL：**小 payload 直接可行**。Chromium 的扩展下载 API 浏览器测试里有一条名为 `DownloadExtensionTest_Download_DataURL` 的用例，注释是「Valid data URLs are valid URLs.」，用 `data:text/plain,hello` 断言成功创建并跑到 complete（[E24]）。但见 §2.5 的 2MB 上限。
- 内存：由浏览器进程承担，与 JS 堆无关；MB 级网络缓冲，不随文件大小增长。

**A-2 附录 A 的 `chrome.tabs` + 两条 DNR**

- 机制：DNR 改请求头 + 把响应改写成 `Content-Disposition: attachment` ⇒ 浏览器原生下载流接管。
- 落盘结论与本文件一致：**落点由浏览器的下载设置决定，不由扩展决定**（概念设计 §A.4.1 已记录），JS 不接触字节 ⇒ 字节不进 JS 堆，GB 级文件不构成内存瓶颈（该机制不涉及任何 JS 落盘 API）。
- 代价：多一个标签页；下载系统的"临时文件 + 改名 + 可能的安全检查"同样适用（[E23] 的 `acceptDanger` 描述对原生下载普遍成立，标 B/C）。

### 2.2 通路 B-1：File System Access API（用户可见的磁盘位置）

这是本题最重要的机制，逐点列清：

**（1）取得句柄：`showSaveFilePicker()`**

- 规范 IDL 明确只挂在 Window 上：`[SecureContext] partial interface Window { … showSaveFilePicker(…) }`（[E1]）。
- 三道门槛（规范逐字）：origin 不能是 opaque；必须与 top-level 同源；**global 必须是 `Window`**；**必须有 transient activation**（[E1]）。不满足时抛 `SecurityError`。
- MDN：`SecurityError … Thrown if the call was blocked by the same-origin policy or it was not called via a user interaction such as a button press.`、`Transient user activation is required.`（[E3]）。
- Chromium 企业策略把这条约束写成了可运维对象：`showOpenFilePicker() / showSaveFilePicker() / showDirectoryPicker()`「require a prior user gesture ("transient activation") to be called or will otherwise fail」，只有管理员白名单源可豁免（Chrome 113+）（[E25]）。
- **Chromium 明确为扩展源写了专门分支**（B 级：实现事实）：`chrome_file_system_access_permission_context.cc` 里，当 `FileSystemAccessPermissionRequestManager::FromWebContents(web_contents)` 为空时，注释写「Extension contexts (popup, side panel) may not have a permission request manager attached. Since the user already explicitly selected a file/folder via the file picker dialog (which is a strong user gesture), we can auto-grant the permission for extensions without showing an additional prompt.」，判据是 `rfh->GetLastCommittedOrigin().scheme() == "chrome-extension"`（[E26]）。
  - ⇒ **可确认**：Chromium 的 FSA 权限链路里确实存在「`chrome-extension` 源」这一等公民，扩展页面有能力走完 picker → 写权限的链路。
  - ⇒ **范围限定**：自动授予只被注释在「没有权限请求管理器」的上下文（举的例子是 popup、side panel）。**扩展页（标签页）有 `WebContents`，是否也走这条自动授予路径未验证**（§7 U2b）；若走常规提示，则第 2 次确认框仍可能出现，而且「瞬时激活只有几秒」（[E33]）可能已被保存对话框耗尽。
- 同一文件里另一条关键事实：**权限请求必须有 RenderFrameHost**，没有 RFH 的情形（注释：「Requested from a worker, or a no longer existing tab.」）直接返回 `kInvalidFrame`（[E26]）⇒ **Worker/无可视帧的上下文无法发起权限请求**；另一处注释「Prevent background permission dialog spam by requiring a user gesture」，无 transient activation 时返回 `kNoUserActivation`（[E26]）。

**（2）写入：`FileSystemFileHandle.createWritable()` → `FileSystemWritableFileStream`**

- 类型关系：`[Exposed=(Window, Worker), SecureContext] interface FileSystemWritableFileStream : WritableStream`（[E2]）；MDN 表述为「a WritableStream object with additional convenience methods, which operates on a single file on disk」，并给 `write()/seek()/truncate()`（[E4]）。
- **写临时文件、close 才生效**（规范逐字）：
  - 「Any changes made through stream won't be reflected in the file entry … until the stream has been closed.」
  - 「User agents try to ensure that no partial writes happen, i.e. the file will either contain its old contents or it will contain whatever data was written through stream up until the stream has been closed.」
  - 「This is typically implemented by writing data to a temporary file, and only replacing the file entry … with the temporary file when the writable filestream is closed.」
  - 「If `keepExistingData` is false or not specified, the temporary file starts out empty, otherwise the existing file is first copied to this temporary file.」（⇒ `keepExistingData: true` 会**先整份复制**原文件）
  - 「Creating a FileSystemWritableFileStream takes a shared lock on the file entry … This prevents the creation of FileSystemSyncAccessHandles for the entry, until the stream is closed.」
  - **in-place 缺失**：规范里挂了 WICG issue #67 的讨论并注明「This is not currently implemented in Chrome.」（[E2]）
- **内存模型**（规范逐字）：`[[buffer]]`「can get arbitrarily large, so it is expected that implementations will not keep this in memory, but instead use a temporary file for this.」；并且「All operations executed on the stream are queuable and producers will be able to respond to backpressure.」；「when piping a ReadableStream into a FileSystemWritableFileStream object, this position is updated with the number of bytes that passed through the stream.」（[E2]）⇒ **`fetch().body.pipeTo(writable)` 是规范支持且带背压的流式写法**。
- **随机写**：`write({type:"write", position, data})`、`seek(position)`、`truncate(size)` 都支持（[E2][E4]）⇒ 分片/多连接写同一文件在**同一会话内**技术上可行（注意：目标文件在 close 前不可见，且被 shared lock 独占）。
- **close 的风险**：`closeAlgorithm` 会「Run implementation-defined malware scans and safe browsing checks. If these checks fail, reject closeResult with an "AbortError" DOMException」（[E2]）。
- 权限：`createWritable()` 会 `request access given "readwrite"`，**权限不是 `granted` 就拒绝**（[E2]）；注意这一步**规范里没有**要求 transient activation —— 需要激活的是「请求权限」那一步（见下）。
- 写权限授予：pickers 成功后返回的句柄对 `readwrite` 的 permission state「should be granted」（[E1]）；对已存在文件，Chrome 会在拿到写权限前弹一次确认（[E7]「The permission request can only be triggered by a user gesture」）。**扩展上下文**：没有权限请求管理器的扩展上下文（注释举 popup/side panel）会被自动授予，不再弹框（[E26]；扩展页标签页的情形见 §7 U2b）。

**（3）跨会话/跨上下文：句柄是「可序列化对象」**

- MDN：「Objects based on `FileSystemHandle` can also be serialized into an IndexedDB database instance, or transferred via `postMessage()`.」（[E5]）
- Chrome 文档：「File handles and directory handles are serializable, which means that you can save a file or directory handle to IndexedDB, or call `postMessage()` to send them between the same top-level origin.」（[E7]）
- **但 Chrome 的扩展消息通道传不了句柄**：「In Chrome, the message passing APIs use JSON serialization. Notably, this is different to other browsers which implement the same APIs with the structured clone algorithm.」（[E29]）⇒ `chrome.runtime.sendMessage` / `Port.postMessage` **无法**搬运 `FileSystemHandle`；跨上下文接力只能走 **IndexedDB**（同一扩展源共享，见 [E11]）或同源 Window 之间的 `postMessage`。
- **权限能否持久**：Chrome 122 起有「持久权限」三选一提示（Allow this time / Allow on every visit / Don't allow），触发条件是「上一次访问授予过权限 + 句柄存在 IndexedDB 里 + 本次访问取回句柄并调用 `FileSystemHandle.requestPermission()`」；「If the user denies or dismisses the prompt more than three times, it will no longer trigger, and instead the regular permission prompt will show.」；已安装应用（installed apps）自动持久化（[E8]）。
- **`requestPermission()` 依据规范也需要 Window + transient activation**：权限请求算法里「If global is not a Window, then throw a SecurityError」「If global does not have transient activation, then throw a SecurityError」（[E1]）。
- 反面：Chrome 的 FSA 文档「Permission persistence」一节仍写着旧行为「can continue to save changes … until all tabs for its origin are closed. Once a tab is closed, the site loses all access.」（[E7]）——**该页（2024-08 发布）尚未反映 [E8] 的 Chrome 122 持久权限**，两者不矛盾，但引用时必须注意时效。**这类前后不一致本身就是「不能凭记忆/二手资料下结论」的活例子。**

### 2.3 通路 B-2：OPFS（`navigator.storage.getDirectory()`）

- 是什么：源私有文件系统，属于 **bucket file system**（[E2] 的 permission constraints：「If entry represents a file system entry in a bucket file system, this descriptor's permission state must always be granted.」）⇒ **不需要任何权限提示/手势**。
- 用户可见性（MDN 逐字）：「Browsers persist the contents of the OPFS to disk somewhere, but you cannot expect to find the created files matched one-to-one. **The OPFS is not intended to be visible to the user.**」；「Clearing storage data for the site deletes the OPFS.」；「The OPFS is subject to browser storage quota restrictions」（[E6]）。
- 写入方式：
  - 异步：`getFileHandle(..., {create:true})` → `createWritable()` →（同一套 `FileSystemWritableFileStream`，**注意仍是「临时文件 + close 替换」语义**）→ `close()`（[E2][E6]）。
  - 同步：`createSyncAccessHandle()`（`read/write/truncate/getSize/flush/close`），规范 `[Exposed=DedicatedWorker]`（[E2]），MDN「This class is only accessible inside dedicated Web Workers for files within the origin private file system.」（[E5]）⇒ **MV3 SW 里不能用同步句柄**（若 OPFS 在 SW 可用，也只能用异步 API）。
- 上下文可用性：`StorageManager` 是 `[Exposed=(Window, Worker)]`（[E15] 的 Storage spec 与 [E2] 的 partial interface）⇒ **规范层面包含 service worker**。但 Chrome 的扩展文档在「Access in service workers」只列了「The IndexedDB and Cache Storage APIs are accessible in service workers. However, Local Storage and Session Storage are not.」（[E11]）——**没有逐字列 OPFS**，这是 §7 的一条未验证项（实务上建议用 offscreen document 兜底）。
- 「导出成本」（把 OPFS 文件交给用户）：三条可选
  1. `showSaveFilePicker` + 复制：再要一次手势，且是**第二次全量读写**（写侧又是临时文件 ⇒ 磁盘峰值约 2 倍文件大小）。
  2. `URL.createObjectURL(await handle.getFile())` + `a[download]`：不需要手势，但 **blob URL 生命周期绑在创建它的文档/Worker 上**，「Browsers will release object URLs automatically when the document is unloaded」（[E20]）⇒ 承载下载的页面必须一直活着，且 SW 根本无法创建 blob URL（[E18]）。
  3. `chrome.downloads.download({url: blobUrl})`：同上，且见 §2.4 的分区/生命周期不确定性。
  - 是否「零 JS 内存地导出」：**未验证**（见 §7 U7）。仅能确认 blob URL 本身是「引用」，以及 Chromium 的 blob 系统有 500MB 内存上限、超出后落盘分页（[E27]）。

### 2.4 通路 C-1：`Blob` + `URL.createObjectURL` + `a[download]`

- **必须先有完整的 `Blob`**。构造 Blob 意味着整份字节已经存在于某处（JS 堆 → 浏览器 blob 存储），**没有任何背压**；因此对 GB 级文件，这条路径的本质就是「先物化再下载」，不是流式落盘。
- Chromium 的 blob 存储有明确的内存上限与分页参数（B 级）：`kDefaultMaxBlobInMemorySpace = 500 MiB`、`kDefaultMaxPageFileSize = 100 MiB`、`kDefaultMinPageFileSize = 5 MiB`，注释「This is the maximum amount of memory we can use to store blobs.」「This is the maximum file size we can create.」；错误枚举含 `ERR_OUT_OF_MEMORY`、`ERR_FILE_WRITE_FAILED`（[E27]）⇒ 大 Blob 会被分页到磁盘（因此有「写盘再读回」的隐蔽成本），内存压力下也可能直接失败。
- blob URL 的生命周期与分区（规范 + MDN）：
  - File API 规范 §8.3.3「Lifetime of blob URLs」扩展了文档卸载清理步骤：「Remove from store any entries for which the value's environment is equal to environment.」，并留了一条开放注记「This needs a similar hook when a worker is unloaded.」（[E17]）
  - MDN：「Browsers will release object URLs automatically when the document is unloaded」；「Blob URLs have an associated creator origin … can only be fetched from environments where the storage key matches that of the creator environment. Blob URL navigations are not subject to this restriction」（[E20]）
- **Service Worker 里没有 `createObjectURL`**：规范 IDL `[Exposed=(Window, DedicatedWorker, SharedWorker)]`（[E17]），Chromium Blink IDL 相同（[E18]），MDN 明说「This feature is not available in Service Workers due to its potential to create memory leaks.」（[E19]）⇒ **MV3 SW 不可能自己造 blob URL**；要造只能在扩展页/offscreen（offscreen 的 `BLOBS` reason 正是为此存在：「Specifies that the offscreen document needs to interact with Blob objects (including URL.createObjectURL())」，[E9]），并且必须**活到下载读完**。
- `a[download]` 本身：MDN 页面极简（只说明文件名语义）（[E30]）；HTML 规范 §4.6.6「Downloading resources」说明「This value can be overridden by the Content-Disposition HTTP header's filename parameters.」以及跨源情形需要配合 `Content-Disposition: attachment`（[E30]）。**「必须是同源或 blob:/data:」这条常见说法在现行 HTML 规范里没有对应逐字条文**（见 §7 U8），不要写进能力清单。
- `chrome.downloads` 用 blob URL：浏览器下载栈本身支持 blob:（Chromium 有 `DownloadDangerousBlobData` 等用例，且下载实现里有 `blob_url_loader_factory` 分支，[E34]）；但扩展 API 路径下「从 SW 发起 + 跨上下文持有」的组合**未验证**（§7 U6），且上面两条硬伤（SW 造不出 URL、文档卸载即失效）已足以把它排除在主路径之外。

### 2.5 通路 C-2：`data:` URL 交给 `chrome.downloads`

- **小 payload 可行**（Chromium 官方测试 `DownloadExtensionTest_Download_DataURL` 注释「Valid data URLs are valid URLs.」，[E24]）。
- **但硬上限把它钉死在「小文件」档**：
  - Chromium 的 Mojo 限制了跨进程传递的 URL 长度：`url/mojom/url.mojom` 里 `const uint32 kMaxURLChars = 2097152;` 并注释「The longest GURL length that may be passed over Mojo pipes. Longer GURLs may be created and will be considered valid, but when pass over Mojo, URLs longer than this are silently replaced with empty, invalid GURLs.」（[E22]）——**扩展 API 调用正是跨 Mojo 传 URL** ⇒ 超过 ~2MB 的 data URL 会被静默变成无效 URL（表现为 `Invalid URL` 之类的失败，而非"截断"）。
  - MDN data URL 页另给浏览器级上限：「Chromium and Firefox limit `data` URLs to 512MB, and Safari (WebKit) limits them to 2048MB.」，同时「top-level navigation to `data:` URLs is blocked in all modern browsers」（[E21]）。
  - 另注意 base64 膨胀 33%，且内容要留在内存里拼字符串。
- 结论：**只能作为「极小文件/文本」的退化路径**，不能作为下载引擎的落盘机制。

### 2.6 通路 C-3：纯内存缓冲

- 语义：把整个文件收进 `ArrayBuffer` / `Uint8Array` / 字符串，再一次性交付。
- 硬上限（B 级，V8 源码）：`JSArrayBuffer::kMaxByteLength` 在 32 位宿主是 `kMaxInt`（≈2GiB−1），在 64 位（未启用 sandbox）是 `kMaxSafeInteger`，在启用 V8 sandbox 的构建里是 `kMaxSafeBufferSizeForSandbox`（该常量数值本次未取到，见 §7 U5）；并有 `static_assert(kMaxByteLength == v8::TypedArray::kMaxByteLength)`（[E28]）。
- 现实约束：Chrome 64 位桌面单渲染进程可用内存远低于 4GB；一个 4GB 的 `ArrayBuffer` 无论是否被允许，都会把页/扩展进程推到 OOM 边界；而 Blob 路径还有 500MB 的内存空间上限需要分页（[E27]）。
- **结论：纯内存缓冲在本项目里只能用于「小文件 / 元数据（.aria2 控制文件、分片校验值）」，不构成 4GB 级下载的落盘方案。** 唯一可以直接说「内存无上限」的是通路 A（原生下载流，字节根本不进 JS 堆）。

---

## 3 硬约束

> 编号用于后续「能力 → 接口行为规则表」引用。每条给证据与适用面。

| # | 约束 | 关键内容 | 证据 | 适用 |
|---|---|---|---|---|
| **L1** | picker 只在 Window + 瞬时激活下可用 | 规范：`partial interface Window`；算法要求 global 是 `Window` 且有 transient activation；Chrome 策略文档复述「require a prior user gesture … or will otherwise fail」 | [E1][E3][E25] | Chrome/Chromium（Firefox/Safari 无此 API） |
| **L2** | 权限请求同样需要 Window + 手势 | 权限请求算法：非 Window 抛 `SecurityError`、无 transient activation 抛 `SecurityError`；Chromium 无 RFH（worker/无可视帧）直接 `kInvalidFrame` | [E1][E26] | Chrome 122+ 三选一提示；无权限请求管理器的扩展上下文（popup/side panel）自动授予（扩展页见 U2b） |
| **L3** | 写流是「临时文件 + close 替换」 | 「no partial writes」；`keepExistingData:true` 会整份复制；Chrome 未实现 inPlace | [E2] | 全平台实现语义 |
| **L4** | `close()` 可能整份失败 | close 时跑 malware/Safe Browsing 检查，失败 → `AbortError` | [E2] | Chrome/Chromium |
| **L5** | 写流有独占期与共享锁 | 创建 stream 会拿 shared lock，阻止同步句柄；同步句柄拿 exclusive lock | [E2] | 影响「同一文件多写者」 |
| **L6** | 句柄可序列化，但不可走扩展消息 | 可 IndexedDB / `postMessage`（同 top-level origin）；Chrome 的消息 API 是 **JSON 序列化** | [E5][E7][E29] | Chrome 扩展 |
| **L7** | 权限跨会话需持久授权 | Chrome 122+ 三选一；被拒 3 次后提示不再出现；「installed apps」自动持久化 | [E8] | Chrome 122+ |
| **L8** | MV3 SW 无 `window`、且会被生命周期杀死 | 30s 无活动终止；单次请求 >5min 终止；`fetch()` 响应 >30s 未到终止；Web Storage 不可用 | [E10] | MV3 |
| **L9** | SW 里不能创建 blob URL | 规范/Blink IDL `Exposed=(Window, DedicatedWorker, SharedWorker)`；MDN 明说不支持 SW | [E17][E18][E19] | Chrome/Firefox |
| **L10** | blob URL 生命周期绑创建文档 | 文档卸载即从 store 移除；worker 卸载「needs a similar hook」（未定） | [E17][E20] | 全平台 |
| **L11** | blob URL 有存储分区限制 | 「can only be fetched from environments where the storage key matches that of the creator environment」；导航例外 | [E20] | Chrome 115+ 分区 |
| **L12** | 跨 Mojo 的 URL ≤ 2MB | 超长 URL 在跨进程时被**静默替换为空/无效** | [E22] | Chromium |
| **L13** | data: URL 上限 | Chromium/Firefox 512MB、Safari 2048MB；顶层导航被禁 | [E21] | 全平台 |
| **L14** | OPFS 对用户不可见、随站点数据一起被清 | 「not intended to be visible to the user」；「Clearing storage data for the site deletes the OPFS」 | [E6] | 全平台 |
| **L15** | OPFS/扩展存储受配额与驱逐约束 | 无 `unlimitedStorage` 时扩展受配额约束、可在内存压力下被驱逐；请求 `unlimitedStorage` 可豁免配额**与驱逐** | [E11][E12] | Chrome |
| **L16** | `persist()` 只在 Window 可用 | Storage 规范 IDL `[Exposed=Window] persist()`；MDN「not available in Web Workers」 | [E15][E16] | Chrome/Firefox/Safari |
| **L17** | 配额量级 | Chromium 单源 60% 磁盘、浏览器总量 80%；Firefox best-effort 10GiB/组、persistent 50%（上限 8TiB）；Safari 老版本首 1GiB 后弹窗 | [E14] | 各浏览器 |
| **L18** | 超配额报 `QuotaExceededError` | 「Attempting to store more than an origin's quota using IndexedDB, Cache, or OPFS, for example, fails with a QuotaExceededError exception.」 | [E14] | 全平台 |
| **L19** | 扩展的下载落点只能是 Downloads 相对路径 | 绝对路径 / 空路径 / 含 `..` 报错；`saveAs` 走文件选择器 | [E23] | Chrome |
| **L20** | 原生下载对危险文件需可见上下文审批 | `acceptDanger`「Can only be called from a visible context (tab, window, or page/browser action popup)」 | [E23] | Chrome |
| **L21** | popup 随失焦销毁 | MDN WebExtensions：「When the user clicks anywhere outside the popup, the popup is closed.」「The popup's document is … unloaded every time the popup is closed.」 | [E32] | Chrome/Firefox（Chrome 未逐字，标 C） |
| **L22** | offscreen 文档不能聚焦、只能用 `runtime` API | 「Offscreen documents can't be focused.」「The `runtime` API is the only extensions API supported by offscreen documents.」「an installed extension can only have one open at a time」 | [E9] | Chrome 109+ |
| **L23** | SW 生命周期与「字节是否在 JS 里」强相关 | 若写盘发生在 SW：30s/5min 规则直接中断写流；若发生在 offscreen/扩展页，则 SW 重启不影响 | [E10][E9] | MV3 |
| **L24** | 同步 OPFS 句柄仅 DedicatedWorker | 规范 `[Exposed=DedicatedWorker]`；MDN 同 | [E2][E5] | 全平台 |
| **L25** | Chromium blob 内存上限 500MiB、按 100MiB 分页 | `kDefaultMaxBlobInMemorySpace`、`kDefaultMaxPageFileSize`、`ERR_OUT_OF_MEMORY` | [E27] | Chromium（B 级） |
| **L26** | 内容脚本的扩展 API 面极窄 | 「Content scripts can access the following extension APIs directly: dom / i18n / storage / runtime.connect() / runtime.getManifest() / runtime.getURL() / runtime.id / runtime.onConnect / runtime.onMessage / runtime.sendMessage()」；「Content scripts are unable to access other APIs directly.」 | [E36] | Chrome MV3 |
| **L27** | `chrome.storage.local` 默认 10MB（Q-D5 的状态持久化要算这笔账） | 「The storage limit is 10 MB (5 MB in Chrome 113 and earlier), but can be increased by requesting the "unlimitedStorage" permission.」；`QUOTA_BYTES` = 10485760，且「This value will be ignored if the extension has the unlimitedStorage permission.」；`storage.session` 10MB 且只存内存 | [E13] | Chrome MV3 |

### 3.1 关于 L3/L4 的额外说明（对「续传」是致命的）

aria2 的核心体验之一是「断点续传 / 多连接分片写同一文件」。在 FSA 写流下：

- **同一会话内**：`write({position})` / `seek()` / `truncate()` 支持随机写（[E2]），所以「多连接写同一文件」在**同一次 `createWritable()` 生命周期内**可做（前提是分片数据都能到达这个上下文）。
- **跨会话/跨重启**：**做不到**。临时文件语义（L3）意味着**目标文件在 `close()` 前不出现**，崩溃或浏览器退出后不但没有半成品可续，连「已写了多少」都无法从文件本身读出；重新开始只能再要一次手势（L1/L2/L7）。
  ⇒ 若引擎要声明「续传」能力，唯一可行的实现是**在 OPFS 里暂存分片**（可跨会话、无需手势），完成后再整体导出——代价是**磁盘双份 + 双次搬运**（§2.3）。

---

## 4 能力映射

### 4.1 建议的落盘侧原子能力（bool，供 R11 能力清单参考）

> 只列「落盘/持久化」相关的候选能力；命名与最终归并归「能力清单」文档。

| 候选能力 | 含义（引擎可为 true 的条件） | 原生下载流 | FSA（用户选文件） | OPFS | Blob+`a[download]` | 纯内存 |
|---|---|---|---|---|---|---|
| `streamingWrite` | 字节按 chunk 写出，内存不随文件大小线性增长 | ✅（JS 不持有字节） | ✅ [E2] | ✅ [E2] | ❌ | ❌ |
| `userVisiblePath` | 最终文件出现在用户可在文件管理器中看到的路径 | ✅（浏览器下载目录） | ✅（用户自选） | ❌ [E6] | ✅/🟡（取决于落点） | 🟡 |
| `userChosenPath` | 任务可指定/由用户选择目标路径（对应 R13 的「保存目录」） | 🟡（仅 Downloads 下相对子目录 [E23]） | ✅（但每次要手势） | ❌（无路径概念） | ❌ | ❌ |
| `noUserGesture` | 任务可在无任何用户交互时启动 | ✅ | ❌ [E1] | ✅ | 🟡 | ✅ |
| `resumeWrite` | 中断后可从已写字节继续（跨会话/跨重启） | ❌（引擎看不到字节，只能整体重下） | ❌（L3/L4；临时文件 + close 才生效） | ✅（OPFS 可保留分片） | ❌ | ❌ |
| `multithread`（写侧） | 多写入者并发写同一最终文件 | ❌ | 🟡（同会话内可 `position` 随机写 [E2]，跨会话不可） | ✅（分片各自为文件） | ❌ | ❌ |
| `memUnlimited` | 文件大小不受 JS 内存上限约束 | ✅ | ✅ | ✅ | ❌ [E27][E28] | ❌ |
| `quotaFree` | 不受 origin 存储配额约束 | ✅（不占 origin 存储） | ✅（用户文件不属 origin 存储，**推断 C**） | ❌（受配额；`unlimitedStorage` 可豁免 [E11][E12]） | ❌ | ✅ |
| `writableFromServiceWorker` | 落盘动作可在 MV3 SW 内执行 | ✅ | ❌（picker 需要 Window [E1]） | 🟡（规范允许，Chrome 文档未列明，§7 U3） | ❌（SW 无 `createObjectURL` [E18]） | ✅ |
| `closeTimeVerifiable` | 不存在「写完才失败」的收尾风险 | 🟡（危险文件审批，[E23]） | ❌（close 可能 `AbortError` [E2]） | ❌（同 FSA 写流语义） | 🟡 | ✅ |

> 注意 Q-B8：能力必须全是 bool，不允许数值型（「最大 1GB」之类）。因此落盘侧若要表达阈值，只能新增离散能力名。

### 4.2 落盘途径 × 执行上下文：可用性结论（完整版）

**跨浏览器支持（MDN BCD，[E31]，核对日期 2026-10-06）**：`showSaveFilePicker` 仅 Chromium 系（Chrome 86+、Chrome Android 132+；**Firefox、Safari 均为 false**）；OPFS `navigator.storage.getDirectory()` Chrome 86+ / Firefox 111+ / Safari 15.2+；`createWritable()` 与 `FileSystemWritableFileStream` Chrome 86+ / Firefox 111+ / **Safari 26**；`createSyncAccessHandle()` Chrome 102+ / Firefox 111+ / Safari 15.2+。`chrome.downloads` 属 Chrome 扩展 API（Firefox 对应 `browser.downloads`）。
⇒ 本表**只对 Chromium 系成立**；若将来要考虑 Firefox/Safari，落盘矩阵要整体降级为「OPFS + 浏览器自身下载」两条，**FSA picker 一列直接消失**。

**途径缩写**：P=picker；W=FSA 流式写；O=OPFS 写；D=`chrome.downloads`；B=Blob/objectURL；U=`data:` URL。

| 执行上下文 | P | W | O | D | B | U | 备注 |
|---|---|---|---|---|---|---|---|
| **MV3 service worker** | ❌ 无 `window`，规范要求 global 是 Window [E1] | ❓ 若句柄与权限已由 Window 侧建立并经 IndexedDB 交接，规范未禁止（§7 U2） | 🟡 规范 `Exposed=(Window,Worker)` 允许；Chrome 扩展文档只逐字列了 IndexedDB/Cache [E11]（§7 U3） | ✅ [E23] | ❌ 无 `createObjectURL` [E18][E19] | ✅ 但 ≤2MB [E22][E24] | SW 随时会被 30s/5min 规则杀掉 [E10] |
| **offscreen document** | ❌ 不能聚焦 ⇒ 无 transient activation [E9][E1] | ❓ 同 SW（无 RFH 的权限请求会被拒 [E26]，已有权限时应可写） | 🟡 同上 | ❌ 不能直接调用（只支持 `runtime` API [E9]），须由 SW 转发 | ✅ `BLOBS` reason 明示 [E9] | ✅ ≤2MB | 唯一有 DOM、无生命周期限制的扩展后台上下文 [E9] |
| **扩展页（标签页）** | ✅ Chromium 有 `chrome-extension` 源专用分支 [E26] | ✅ | ✅ | ✅ | ✅ | ✅ ≤2MB | 需要用户保持标签页打开（L21 类比） |
| **popup** | ✅（有手势） | 🟡 页面一失焦就 unload [E32] ⇒ 不能承载分钟级写入 | 🟡 | ✅ | 🟡 | 🟡 | 只适合「点一下拿句柄，然后交给别的上下文」 |
| **side panel** | ✅ Chromium 明确提及 [E26] | ✅ | ✅ | ✅ | ✅ | ✅ | 面板关闭即卸载（同 popup 风险，未逐字验证） |
| **内容脚本（ISOLATED）/ MAIN world** | ❓ 归属源/是否允许未见官方逐字说明（§7 U9） | 🟡 | ❌（Web 存储 API 落在宿主页面源 [E11]） | ❌ 不能直接调用（只可直接用 `dom/i18n/storage/runtime` 子集 [E36]），须消息转发 | 🟡 | 🟡 | 内容脚本可调 `chrome.storage`（扩展存储），但 IndexedDB/OPFS 属于宿主页面 |
| **扩展源 Dedicated Worker** | ❌ | ✅（权限已在句柄上） | ✅（含同步句柄 [E2]） | ❌ 无扩展 API | ✅ | ✅ | 适合做写盘执行体 |
| **页面里的 Worker（宿主页）** | ❌ | 🟡 | ✅ | ❌ | ✅ | ✅ | 与扩展源不同分区 |

### 4.3 对 aria2 语义的落盘侧映射（规则表输入，只给结论）

| aria2 语义 | 原生下载流 | FSA | OPFS |
|---|---|---|---|
| `dir`（保存目录） | 只能映射为「默认下载目录 + 相对子目录」；绝对路径报错 [E23] | 用户自选；无法程序化绑定固定目录（除非持久权限 + 句柄复用 [E8]） | 无目录语义 |
| `out`（文件名） | ✅ `filename` | ✅ 由 picker 决定/建议名 | ✅ 文件系统内命名 |
| 断点续传 | ❌ 无法接管 | ❌ 跨会话不可 | ✅ 暂存分片 |
| 完成后校验/改名 | ❌（字节不可见） | ✅（同会话内可 `truncate`/重写） | ✅ |
| 「文件已存在」 | `conflictAction`（uniquify/overwrite/prompt）[E23] | picker 选择已有文件即覆盖（临时文件替换语义） | 自行管理 |

---

## 5 失败模式与盲区

| # | 失败模式 | 触发条件 | 用户可见现象 | 与裁定的关系 |
|---|---|---|---|---|
| F1 | **无手势导致 picker 直接抛 `SecurityError`** | 在 SW/offscreen/无手势调用 picker | 任务无法开始 | 必须走 R3「不实现」或 Q-B5「运行期错误」，不能假装在下载 |
| F2 | **`close()` 安全检查失败 ⇒ 字节全废** | 目标被判定为危险/恶意、扫描失败 [E2] | 「下载完成度 100% 但文件不存在」 | **R2/R10 红线**：引擎必须回报失败 |
| F3 | **SW 30s/5min 被杀，写流中断** | 写盘逻辑跑在 SW 里 [E10] | 中断、临时文件残留、不可续 | Q-D5「SW 重启不模拟重启」要求状态持久化，但**写流本身不可恢复** |
| F4 | **blob URL 随创建文档卸载失效** | 用 popup/扩展页造 blob URL 后关闭 [E17][E20] | 下载中途 404/失败 | 通路 C 全系不可靠 |
| F5 | **分区不匹配导致 blob URL 取不到** | 创建者分区 ≠ 取用者分区 [E20] | 取用失败 | 设计时固定「创建与消费同一上下文」 |
| F6 | **data URL > 2MB 被静默变无效** | 跨 Mojo 传超长 URL [E22] | `Invalid URL`-类失败 | 只能用于极小文件 |
| F7 | **超配额 `QuotaExceededError`** | OPFS/扩展存储写超配额 [E14] | 写入中途失败 | 需要能力/错误映射 |
| F8 | **数据被驱逐** | 未请求 `unlimitedStorage`、内存压力大、Safari 7 天无交互 [E11][E14] | 已"完成"的任务文件消失 | 「最终结果兑现」被破坏 |
| F9 | **OPFS 文件用户找不到** | 用户去文件管理器找下载文件 [E6] | 认为下载失败 | 产品层必须在存储功能上标注「需要导出」 |
| F10 | **磁盘空间不足** | 4GB 文件，或 FSA 临时文件语义导致峰值 2 倍 | 写入/close 失败 | 需要错误上报（具体错误码未验证，§7 U10） |
| F11 | **popup 关闭打断写入** | 长任务在 popup 内进行 [E32] | 中断 | 设计上禁止 popup 承载写盘 |
| F12 | **权限被拒 3 次后提示不再出现** | 用户反复拒绝 [E8] | 之后只能走常规提示/无法恢复 | 需要 UI 引导 |
| F13 | **`keepExistingData: true` 造成额外整份复制** | 对已存在大文件续写 | 磁盘/耗时翻倍 [E2] | 会与「多连接写已有文件」类需求冲突 |
| F14 | **同一文件的写流与同步句柄互斥** | 同时 `createWritable()` 与 `createSyncAccessHandle()` [E2] | `NoModificationAllowedError` | 设计上要串行化 |
| F15 | **危险文件审批需要可见上下文** | 原生下载命中危险判定，需 `acceptDanger` [E23] | 下载挂在「等待确认」 | SW/offscreen 无法自动处理 ⇒ 任务卡住 |

**盲区（覆盖不到的地方）**：

- **不经过 JS 的字节落盘**（附录 A 的 DNR 强制下载、`chrome.downloads`、浏览器自身"另存为"）**完全在本引擎的观测之外**：进度、错误、完成事件只能从 `chrome.downloads` 事件或 `tabs` 侧间接获得，无法获得字节本身。
- **用户手动取消/浏览器 UI 干预**（下载气泡、危险文件提示）没有任何扩展可见的统一语义。
- **`chrome://downloads` 之外的下载记录/清理**不由扩展控制。

---

## 6 与现有裁定的冲突

| 相关裁定 | 冲突/影响 | 结论与建议 |
|---|---|---|
| **R13**（用户可调整默认参数，例如保存目录） | 浏览器里没有「保存目录」这一概念：原生下载只能「Downloads 下的相对路径」[E23]；FSA 需要每次手势；OPFS 无路径概念 [E6] | 「保存目录」必须降级为**引擎侧的默认参数**（如「Downloads 下的子目录」或「持久句柄记住的目标文件」），并在能力列表（§4.1）里如实体现（如 `userChosenPath`）。**不要**承诺 aria2 的 `dir` 语义 |
| **R10 / R2**（结果兑现、禁止假装成功） | FSA 的 L3/L4（临时文件 + close 可能失败）与 OPFS 的用户不可见性，都会造成「看起来成功、实际拿不到」 | 引擎必须把**收尾失败**（close 抛错、导出未完成）映射成失败；OPFS 落地的任务在**导出完成前**不得置为 `complete` |
| **Q-D5**（只在浏览器彻底退出后才模拟重启；状态必须持久化在存储中） | **进程状态 ≠ 任务状态**：SW 重启不重启任务，但 FSA 写流/临时文件/句柄的**内存侧状态**会随载体上下文消失；FSA 临时文件在 close 前对谁都不可见 | 建议：把「已落盘字节数」作为**引擎自己维护的持久状态**，落盘执行体放在 offscreen document（无生命周期限制 [E9]）；恢复写盘必须重新走手势（或持久权限） |
| **Q-B7**（能拿到真实进度就报真实进度） | 只有原生下载流能给出「真实进度」（来自浏览器下载系统），FSA/OPFS 侧进度由引擎自己按写入 chunk 数算出 | 落盘侧要暴露「已写字节」计数，供 Mock 层合成 `completedLength` |
| **Q-B5 / Q-C4**（条件性可用归运行期错误；能力静态、不因未授权而缩小） | 落盘能力恰好是**静态声明 + 运行期失败**的典型 | 「无手势 → picker 失败」必须走 Q-B5 的运行期错误路径，**不能**在能力上打折扣（与 Q-C4 一致） |
| **R11/Q-B8**（能力是 bool、引擎只声明原子能力） | 落盘途径的差异是「能力组合」的差异，不是数值差异 | 见 §4.1 的候选能力表；「最大 N GB」之类阈值不可表达，只能新增离散名 |
| **R12/Q-C5**（同时只启用一个引擎；有活动任务时禁止切换） | 不同引擎若采用不同落盘末端，切换会牵动句柄/权限/临时文件 | 「有活动写流时禁止切换」在落盘侧同样适用；建议把「存在未 close 的写流」视为活动任务 |
| **附录 A**（tabs+DNR 触发原生下载） | 与本文件 §2.1 完全一致：字节由浏览器写盘、落点由浏览器设置决定、JS 不接触字节 | 附录 A 的引擎天然具备 `noUserGesture`、`memUnlimited`、`streamingWrite`；缺 `userChosenPath`、`resumeWrite`、字节可见性 |
| **R8/R9**（只在浏览器内服务、在 JS API 层拦截） | 落盘侧不受影响；但要注意「引擎的落盘末端与拦截层无关」——即使拦截成功、字节取到，落盘仍受本文件所有约束 | 规则表要把「取字节能力」与「落盘能力」**正交**处理 |

---

## 7 未验证

> 按「问题 → 已查内容 → 为何未定 → 建议验证方式」记录。任何以此为据的设计都必须先做验证。

| # | 未验证项 | 已查 | 状态 | 建议验证方式 |
|---|---|---|---|---|
| **U1** | `chrome-extension://` 页面的 secure context 判定（FSA picker 的 `SecureContext` 门槛） | MDN（showSaveFilePicker 的 Secure context 说明）、Chromium `net/base/is_potentially_trustworthy.cc`（走 `url::GetSecureSchemes()` 注册表）、`Services` 名单未找到逐字注册点 | **C 级（强推断）**：Chromium 源码里存在 `chrome-extension` 源的 FSA 专用分支 [E26]，且 MV3 扩展本身能跑 service worker，故判定为可用；但**没有找到"chrome-extension 是 secure context"的逐字官方陈述** | 写一个最小扩展页，直接 `showSaveFilePicker()` 实测；或查 Chromium 里 `AddSecureScheme(kExtensionScheme)` 的注册点 |
| **U2** | 句柄经 IndexedDB 从扩展页交到 offscreen document 后，**写权限是否在 offscreen 内仍为 granted** | 规范：权限是 permission descriptor 状态 [E1]；Chrome 文档：扩展存储/源在 SW、扩展页、offscreen 间共享 [E11]；Chrome 122 持久权限依赖「取回句柄 + requestPermission」[E8] | 未验证（规范未描述跨 agent 的句柄权限继承） | 实测：扩展页 picker → 存 IndexedDB → offscreen 读回 → `queryPermission({mode:'readwrite'})` |
| **U2b** | **扩展页（标签页）**调用 picker 后，写权限是自动授予还是仍弹第二个确认框 | [E26] 的自动授予分支注释只举了「popup, side panel」；带 `WebContents` 的扩展页是否也命中 `!request_manager` 分支未验证 | 未验证 | 实测扩展页标签页：picker 之后是否出现第二个写权限气泡；以及 `queryPermission({mode:'readwrite'})` 的返回 |
| **U3** | OPFS 在 MV3 SW 内是否可用 | [E2] IDL `Exposed=(Window,Worker)`；[E11] 只逐字列「IndexedDB / Cache Storage」可 SW 访问；[E12] 说 `unlimitedStorage` 覆盖 OPFS | 未验证（规范允许，Chrome 文档未列明） | 在 SW 里 `await navigator.storage.getDirectory()` 实测；或查 Chromium 扩展相关 bug |
| **U4** | `chrome.downloads.download({url: blobUrl})` 的可行性/寿命（尤其从 SW 发起、blob 由 offscreen 创建） | 下载栈支持 blob（[E34]）；扩展 API 文档未提 blob 限制 [E23]；分区规则 [E20] | 未验证 | 实测三种组合（同上下文/跨上下文/SW 发起）并观察下载完成率 |
| **U5** | V8 sandbox 构建下 `kMaxSafeBufferSizeForSandbox` 的具体数值 | V8 `src/objects/js-array-buffer.h` 取到 `kMaxByteLength` 的三种分支 [E28]；`src/sandbox/sandbox.h` 未取到该常量 | 未验证（只知有分支） | 直接读 V8 头文件对应版本；或在 Chrome 里 try/catch 构造大 ArrayBuffer 实测 |
| **U6** | Blob / `URL.createObjectURL` 的**单对象大小硬上限**（流传的 2GB 说法） | Chromium blob 常量 [E27] 只有内存/分页参数，无 2GB 常量；Chromium issue 375385420（"URL.createObjectURL(blob) fails when blob is very large"）页面为 JS 渲染，本次抓取不到正文 | 未验证 | 打开该 issue（人工浏览器）；或读 `BlobRegistrar`/mojo 大小校验代码 |
| **U7** | `URL.createObjectURL(opfsFile)` + 下载是否**不把整文件读进 JS 堆** | [E20] 只说 blob URL 是引用、支持 Range；[E27] 表明 blob 存储会分页到磁盘 | 未验证（无官方逐字保证） | 实测：写 2GB 到 OPFS，用 blob URL 下载，观察渲染进程内存曲线 |
| **U8** | `a[download]` 的「同源或 blob:/data:」限制 | HTML 规范 §4.6.6 只有 Content-Disposition 相关表述 [E30]；MDN 页面也无同源条文 [E30] | 未验证（**不得**把「必须同源」当结论写进能力清单） | 在 Chrome 实测跨源 `a[download]` 行为 |
| **U9** | 内容脚本（ISOLATED/MAIN world）里调用 picker 的**源归属与是否允许** | 未找到官方文档；[E26] 的扩展分支依赖 `rfh->GetLastCommittedOrigin()` | 未验证 | 实测；或查 Chromium `FileSystemAccessManagerImpl` 对 isolated world 的处理 |
| **U10** | 磁盘写满时各途径的**具体错误形态**（FSA / OPFS / 下载系统） | 规范只给 `AbortError`/`QuotaExceededError`/`NoModificationAllowedError` 等通用形态 [E2][E14]；无 OS 级错误映射文档 | 未验证 | 造小磁盘实测；错误码会影响 Q-C4 的「自定义状态码」设计 |
| **U11** | 隐私模式（Incognito split/spanning）下扩展落盘路径的差异 | 未查（[E11] 只说扩展存储共享，未谈 incognito） | 未验证（未知） | 查 Chromium 文档 + 实测 |
| **U12** | 4GB 级实测（吞吐、close 耗时、内存曲线） | **本环境无浏览器**，无法实测 | 未验证 | 需要真机实验（建议在详细设计阶段做一次 4GB 端到端基准） |
| **U13** | `chrome.downloads` 是否有单文件大小上限、多文件下载是否触发许可提示 | 官方文档未提上限 [E23] | 未验证 | 实测 + 区分离线/联机行为 |
| **U14** | side panel 关闭时是否销毁页面（类比 popup） | 未查到逐字官方说明 | 未验证 | 查 Chrome sidePanel 文档 + 实测 |
| **U15** | FSA 写流的**吞吐上限**（是否受渲染进程/IPC 限制） | 规范只说实现不应全放内存 [E2] | 未知 | 基准测试 |

---

## 8 证据清单

> 全部于 **2026-10-06（UTC）** 抓取。规范类为「持续更新文档」，URL 固定；Chrome 文档页附其页面自报的 Last updated。

| ID | 来源 | URL | 关键原文摘录（英文为原文） | 等级 |
|---|---|---|---|---|
| **E1** | WICG File System Access 规范（Editor's Draft） | https://wicg.github.io/file-system-access/ ；源码 https://raw.githubusercontent.com/WICG/file-system-access/main/index.bs | `[SecureContext] partial interface Window { … showSaveFilePicker(…) }`；picker 算法：「If global is not a Window, then throw a "SecurityError" DOMException.」「If global does not have transient activation, then throw a "SecurityError" DOMException.」「If settings's origin is not same origin with settings's top-level origin, then throw a "SecurityError" DOMException.」；权限请求算法同样要求 Window + transient activation；picker 返回的句柄对 `readwrite` 的 permission state「should be granted」 | A |
| **E2** | WHATWG File System 规范 | https://fs.spec.whatwg.org/ | 「Any changes made through stream won't be reflected in the file entry … until the stream has been closed.」「User agents try to ensure that no partial writes happen …」「This is typically implemented by writing data to a temporary file, and only replacing the file entry … when the writable filestream is closed.」「If keepExistingData is false or not specified, the temporary file starts out empty, otherwise the existing file is first copied to this temporary file.」；`[[buffer]]`「can get arbitrarily large, so it is expected that implementations will not keep this in memory, but instead use a temporary file for this.」；「All operations executed on the stream are queuable and producers will be able to respond to backpressure.」；closeAlgorithm「Run implementation-defined malware scans and safe browsing checks. If these checks fail, reject closeResult with an "AbortError" DOMException」；「See WICG/file-system-access issue #67 … This is not currently implemented in Chrome.」；IDL：`FileSystemFileHandle` `[Exposed=(Window, Worker), SecureContext, Serializable]`、`createSyncAccessHandle()` `[Exposed=DedicatedWorker]`、`FileSystemWritableFileStream : WritableStream` `[Exposed=(Window, Worker)]`、`partial interface StorageManager { getDirectory() }` | A |
| **E3** | MDN — `Window.showSaveFilePicker()` | https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker | 「Limited availability — This feature is not Baseline…」；「Secure context: available only in secure contexts」；「SecurityError … Thrown if the call was blocked by the same-origin policy or it was not called via a user interaction such as a button press.」；「Transient user activation is required. The user has to interact with the page or a UI element in order for this feature to work.」 | A |
| **E4** | MDN — `FileSystemWritableFileStream` | https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream | 「Baseline 2025 / Newly available / Since September 2025」；「Note: This feature is available in Web Workers.」；「is a WritableStream object with additional convenience methods, which operates on a single file on disk」 | A |
| **E5** | MDN — File System API 总览 | https://developer.mozilla.org/en-US/docs/Web/API/File_System_API | 「Objects based on FileSystemHandle can also be serialized into an IndexedDB database instance, or transferred via postMessage().」；`FileSystemSyncAccessHandle`「is only accessible inside dedicated Web Workers for files within the origin private file system.」 | A |
| **E6** | MDN — Origin private file system (OPFS) | https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system | 「The OPFS is subject to browser storage quota restrictions…」；「Clearing storage data for the site deletes the OPFS.」；「Permission prompts and security checks are not required to access files in the OPFS.」；「Browsers persist the contents of the OPFS to disk somewhere, but you cannot expect to find the created files matched one-to-one. The OPFS is not intended to be visible to the user.」；用户可见文件系统的写入「are not in-place, and instead use a temporary file」 | A |
| **E7** | Chrome for Developers — File System Access API 指南（页面自报 Published 2024-08-19） | https://developer.chrome.com/docs/capabilities/web-apis/file-system-access | 「calling showOpenFilePicker() must be done in a secure context, and must be called from within a user gesture」；错误串「Must be handling a user gesture to show a file picker.」；「File handles and directory handles are serializable … you can save a file or directory handle to IndexedDB, or call postMessage() to send them between the same top-level origin.」；「Permission persistence … until all tabs for its origin are closed. Once a tab is closed, the site loses all access.」（**注意：该表述早于 Chrome 122 持久权限**，见 E8）；「supported on most Chromium browsers on Windows, macOS, ChromeOS, Linux, and Android. A notable exception is Brave…」 | A |
| **E8** | Chrome for Developers Blog — Persistent permissions for the File System Access API（Last updated 2024-01-09） | https://developer.chrome.com/blog/persistent-permissions-for-the-file-system-access-api | Chrome 122 起三选一提示：「Allow this time / Allow on every visit / Don't allow」；触发条件「the app must have stored the corresponding FileSystemHandle objects in IndexedDB… retrieved any one of the stored FileSystemHandle objects from IndexedDB and then have called its FileSystemHandle.requestPermission() method」；「If the user denies or dismisses the prompt more than three times, it will no longer trigger」；「Installed apps will automatically persist permissions once the user grants access.」 | A |
| **E9** | Chrome for Developers — `chrome.offscreen` API（页面自报 Last updated 2026-09-21） | https://developer.chrome.com/docs/extensions/reference/api/offscreen | 「Service workers don't have DOM access…」；「The runtime API is the only extensions API supported by offscreen documents.」；「Offscreen documents can't be focused.」；「An offscreen document is an instance of window, but the value of its opener property is always null.」；「an installed extension can only have one open at a time」；Reasons 中「"BLOBS" Specifies that the offscreen document needs to interact with Blob objects (including URL.createObjectURL()).」；「The AUDIO_PLAYBACK reason sets the document to close after 30 seconds without audio playing. All other reasons don't set lifetime limits.」 | A |
| **E10** | Chrome for Developers — Extension service worker lifecycle（Last updated 2023-05-02） | https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle | 「After 30 seconds of inactivity. Receiving an event or calling an extension API resets this timer.」「When a single request, such as an event or API call, takes longer than 5 minutes to process.」「When a fetch() response takes more than 30 seconds to arrive.」；「Note: The Web Storage API is not available for extension service workers.」；Chrome 114 段「Messages sent from an offscreen document reset the timers.」 | A |
| **E11** | Chrome for Developers — Storage and cookies（Last updated 2023-09-28） | https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies | 「By default, extensions are subject to the normal quota restrictions on storage, which can be checked by calling navigator.storage.estimate(). Storage can also be evicted under heavy memory pressure, although this is rare.」；「Request the "unlimitedStorage" permission, which affects both extension and web storage APIs and exempts extensions from both quota restrictions and eviction.」；「Call navigator.storage.persist() for protection against eviction.」；「Extension storage is shared across the extension's origin including the extension service worker, any extension pages (including popups and the side panel), and offscreen documents.」；「Access in service workers: The IndexedDB and Cache Storage APIs are accessible in service workers. However, Local Storage and Session Storage are not.」 | A |
| **E12** | Chrome for Developers — 扩展权限清单 `unlimitedStorage` | https://developer.chrome.com/docs/extensions/reference/permissions-list | 「"unlimitedStorage" Provides an unlimited quota for chrome.storage.local, IndexedDB, Cache Storage, and Origin Private File System.」 | A |
| **E13** | Chrome for Developers — `chrome.storage` API 参考 | https://developer.chrome.com/docs/extensions/reference/api/storage | 「The storage limit is 10 MB (5 MB in Chrome 113 and earlier), but can be increased by requesting the "unlimitedStorage" permission.」；`QUOTA_BYTES` = 10485760；`storage.session` 10MB 且「holds data in memory」 | A |
| **E14** | MDN — Storage quotas and eviction criteria | https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria | Chromium「an origin can store up to 60% of the total disk size in both persistent and best-effort modes」；「Chrome currently uses at most 80% of the total disk size」；Firefox best-effort「10% of the total disk size… or 10 GiB（group limit）」、persistent「up to 50%… capped at 8 TiB」；Safari 约 60%/WebKit 总量 80%，老版本「an origin is given an initial 1 GiB quota」；「Attempting to store more than an origin's quota using IndexedDB, Cache, or OPFS, for example, fails with a QuotaExceededError exception.」；「Safari and most Chromium-based browsers… automatically approve or deny the request based on the user's history of interaction with the site and do not show any prompts」 | A |
| **E15** | WHATWG Storage 规范 | https://storage.spec.whatwg.org/ | `[SecureContext, Exposed=(Window, Worker)] interface StorageManager { Promise<boolean> persisted(); [Exposed=Window] Promise<boolean> persist(); Promise<StorageEstimate> estimate(); }`（persist 仅 Window） | A |
| **E16** | MDN — `StorageManager.persist()` | https://developer.mozilla.org/en-US/docs/Web/API/StorageManager/persist | 「This method is not available in Web Workers, though the StorageManager interface is.」 | A |
| **E17** | W3C File API 规范 | https://w3c.github.io/FileAPI/ | 「8.3.3. Lifetime of blob URLs：This specification extends the unloading document cleanup steps… Remove from store any entries for which the value's environment is equal to environment.」＋开放注记「This needs a similar hook when a worker is unloaded.」；`[Exposed=(Window, DedicatedWorker, SharedWorker)] partial interface URL { static DOMString createObjectURL(…); }` | A |
| **E18** | Chromium 源码 — Blink `url_file_api.idl` | https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/core/fileapi/url_file_api.idl | `[ImplementedAs=URLFileAPI, Exposed=(Window,DedicatedWorker,SharedWorker)] partial interface URL { … createObjectURL(Blob blob); … }` | B |
| **E19** | MDN — `URL.createObjectURL()` | https://developer.mozilla.org/en-US/docs/Web/API/URL/createObjectURL_static | 「Note: This feature is not available in Service Workers due to its potential to create memory leaks.」；页首宏 `AvailableInWorkers("window_and_worker_except_service")` | A |
| **E20** | MDN — `blob:` URLs | https://developer.mozilla.org/en-US/docs/Web/URI/Reference/Schemes/blob | 「data URLs embed resources in themselves and have severe size limitations, whereas blob URLs… can represent larger resources.」；「Browsers will release object URLs automatically when the document is unloaded」；「Blob URLs have an associated creator origin… can only be fetched from environments where the storage key matches that of the creator environment. Blob URL navigations are not subject to this restriction」；「Blob URLs support fetching with the Range header」 | A |
| **E21** | MDN — `data:` URLs | https://developer.mozilla.org/en-US/docs/Web/URI/Reference/Schemes/data | 「Browsers are not required to support any particular maximum length of data. Chromium and Firefox limit data URLs to 512MB, and Safari (WebKit) limits them to 2048MB.」；「top-level navigation to data: URLs is blocked in all modern browsers」 | A |
| **E22** | Chromium 源码 — `url/mojom/url.mojom` 与 `url/url_constants.h` | https://chromium.googlesource.com/chromium/src/+/main/url/mojom/url.mojom ；https://chromium.googlesource.com/chromium/src/+/main/url/url_constants.h | 「The longest GURL length that may be passed over Mojo pipes. Longer GURLs may be created and will be considered valid, but when pass over Mojo, URLs longer than this are silently replaced with empty, invalid GURLs.」；`const uint32 kMaxURLChars = 2097152;`；`url_constants.h` 中 `inline constexpr size_t kMaxURLChars = 2 * 1024 * 1024;` | B |
| **E23** | Chrome for Developers — `chrome.downloads` API 参考（页面自报 Last updated 2026-10-04） | https://developer.chrome.com/docs/extensions/reference/api/downloads | `url`：「The URL to download.」；`filename`：「A file path relative to the Downloads directory… Absolute paths, empty paths, and paths containing back-references ".." will cause an error.」；`saveAs`：「Use a file-chooser to allow the user to select a filename regardless of whether filename is set or already exists.」；`download()`：「Download a URL. If the URL uses the HTTP[S] protocol, then the request will include all cookies currently set for its hostname. If both filename and saveAs are specified, then the Save As dialog will be displayed…」；`acceptDanger`：「Can only be called from a visible context (tab, window, or page/browser action popup).」「When all the data is fetched into a temporary file and either the download is not dangerous or the danger has been accepted, then the temporary file is renamed to the target filename, the state changes to 'complete'…」；`headers`：「Extra HTTP headers… restricted to those allowed by XMLHttpRequest.」 | A |
| **E24** | Chromium 源码 — 扩展下载 API 浏览器测试 | https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/extensions/api/downloads/downloads_api_browsertest.cc | `// Valid data URLs are valid URLs.` + `DownloadExtensionTest_Download_DataURL`（`data:text/plain,hello`，断言 `OnCreated` 与 `state: complete`）；`DownloadExtensionTest_Download_ConflictAction` 同样使用 data URL | B |
| **E25** | Chromium 源码 — 企业策略 `FileOrDirectoryPickerWithoutGestureAllowedForOrigins` | https://chromium.googlesource.com/chromium/src/+/main/components/policy/resources/templates/policy_definitions/Miscellaneous/FileOrDirectoryPickerWithoutGestureAllowedForOrigins.yaml | 「the showOpenFilePicker(), showSaveFilePicker() and showDirectoryPicker() web APIs require a prior user gesture ("transient activation") to be called or will otherwise fail.」「If this policy is unset, all origins will require a prior user gesture to call these APIs.」；`supported_on: chrome.*:113-` | B |
| **E26** | Chromium 源码 — FSA 权限上下文 | https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/file_system_access/chrome_file_system_access_permission_context.cc | 「Extension contexts (popup, side panel) may not have a permission request manager attached. Since the user already explicitly selected a file/folder via the file picker dialog (which is a strong user gesture), we can auto-grant the permission for extensions without showing an additional prompt.」＋`bool is_extension = rfh->GetLastCommittedOrigin().scheme() == "chrome-extension";`；「Prevent background permission dialog spam by requiring a user gesture.」→ `kNoUserActivation`；「Requested from a worker, or a no longer existing tab.」→ `kInvalidFrame` | B |
| **E27** | Chromium 源码 — Blob 存储常量 | https://chromium.googlesource.com/chromium/src/+/main/storage/browser/blob/blob_storage_constants.h | `kDefaultMaxBlobInMemorySpace = 500u * 1024 * 1024;`「This is the maximum amount of memory we can use to store blobs.」；`kDefaultMaxPageFileSize = 100u * 1024 * 1024;`「This is the maximum file size we can create.」；`kDefaultMinPageFileSize = 5MiB`；`BlobStatus` 含 `ERR_OUT_OF_MEMORY`、`ERR_FILE_WRITE_FAILED` | B |
| **E28** | V8 源码 — ArrayBuffer 上限 | https://chromium.googlesource.com/v8/v8/+/main/src/objects/js-array-buffer.h | `static constexpr size_t kMaxByteLength = kMaxSafeBufferSizeForSandbox;`（V8_ENABLE_SANDBOX）/ `kMaxInt`（32 位）/ `kMaxSafeInteger`（64 位非 sandbox）；`static_assert(kMaxByteLength == v8::TypedArray::kMaxByteLength);` | B |
| **E29** | Chrome for Developers — Message passing | https://developer.chrome.com/docs/extensions/develop/concepts/messaging | 「Serialization: In Chrome, the message passing APIs use JSON serialization. Notably, this is different to other browsers which implement the same APIs with the structured clone algorithm. This means a message… can contain any valid JSON.stringify() value.」 | A |
| **E30** | MDN `HTMLAnchorElement.download` + HTML 规范 §4.6.6 | https://developer.mozilla.org/en-US/docs/Web/API/HTMLAnchorElement/download ；https://html.spec.whatwg.org/multipage/links.html | MDN：「The value, if any, specifies the default file name…」；HTML 规范「4.6.6 Downloading resources」：「This value can be overridden by the Content-Disposition HTTP header's filename parameters.」「In cross-origin situations, the download attribute has to be combined with the Content-Disposition HTTP header, specifically with the attachment disposition type, to avoid the user being warned of possibly nefarious activity.」 | A |
| **E31** | MDN browser-compat-data（BCD） | https://github.com/mdn/browser-compat-data （抓取 `api/Window.json`、`api/StorageManager.json`、`api/FileSystemFileHandle.json`、`api/FileSystemWritableFileStream.json`、`api/FileSystemSyncAccessHandle.json`） | `showSaveFilePicker`：Chrome 86+、Chrome Android 132+、**Firefox false、Safari false**；`StorageManager.getDirectory`：Chrome 86+/Firefox 111+/Safari 15.2+；`StorageManager.persist`：Chrome 55+；`FileSystemFileHandle.createWritable` / `FileSystemWritableFileStream`：Chrome 86+/Firefox 111+/**Safari 26**；`createSyncAccessHandle`/`FileSystemSyncAccessHandle`：Chrome 102+/Firefox 111+/Safari 15.2+ | A |
| **E32** | MDN — WebExtensions Popups | https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/user_interface/Popups | 「When the user clicks anywhere outside the popup, the popup is closed.」「The popup's document is loaded every time the popup is shown, and unloaded every time the popup is closed.」（MDN 的 WebExtensions 文档以 Firefox 为基准；Chrome 行为同构为 C 级推断） | A/C |
| **E33** | HTML 规范 — User activation | https://html.spec.whatwg.org/multipage/interaction.html | 「A user agent also defines a transient activation duration, which is a constant number indicating how long a user activation is available for certain user activation-gated APIs… The transient activation duration is expected be at most a few seconds」；transient activation 定义在 Window `W` 上 | A |
| **E34** | Chromium 源码 — 下载浏览器测试（blob 支持） | https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/download/download_browsertest.cc | 「// Test that we show a dangerous downloads warning for a dangerous file downloaded through a blob: URL.」`IN_PROC_BROWSER_TEST_F(DownloadTest, DownloadDangerousBlobData)`；`content/browser/download/download_manager_impl.cc` 中 `DCHECK_EQ(params->url().SchemeIsBlob(), bool{blob_url_loader_factory});` | B |
| **E36** | Chrome for Developers — Content scripts | https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts | 「Content scripts can access the following extension APIs directly: dom / i18n / storage / runtime.connect() / runtime.getManifest() / runtime.getURL() / runtime.id / runtime.onConnect / runtime.onMessage / runtime.sendMessage()」；「Content scripts are unable to access other APIs directly. But they can access them indirectly by exchanging messages with other parts of your extension.」；「Content scripts live in an isolated world」 | A |

---

## 附录 · 本文件对下游文档的直接输入（可复制）

1. **给「能力清单」**：§4.1 的 10 个候选 bool 能力及其成立条件。
2. **给「能力 → 接口行为规则表」**：§4.2 的上下文矩阵与 §4.3 的语义映射；落盘能力缺失时的行为必须是「不实现」或「运行期错误」，不得伪装（R2/R10）。
3. **给「详细设计」**：
   - 若引擎需要 JS 掌握字节（注入 header / 分片 / 校验）⇒ **必须**设计一个「手势窗口 → 句柄 → IndexedDB 交接 → offscreen/Worker 写入」的流水线（L1/L2/L6/L22）。
   - 若引擎不需要字节 ⇒ 优先 `chrome.downloads`（0 交互、0 内存、0 配额），但要接受 `dir` 语义丢失（L19）。
   - OPFS 只能作为**暂存区**，不是交付终点（L14）。
4. **给「拦截盲区清单」**：落盘侧不引入新的拦截盲区，但引入一类**观测盲区**（原生下载路径下扩展看不到字节，见 §5 盲区小节）。
