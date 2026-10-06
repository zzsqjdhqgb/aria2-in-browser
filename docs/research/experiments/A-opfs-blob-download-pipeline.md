# A：`OPFS → blob URL → chrome.downloads.download` 功能可行性实测

> 被测候选路线：`fetch 多路 Range → 写进 OPFS 暂存 → getFile() → URL.createObjectURL() → chrome.downloads.download({url: blobUrl}) → 落到用户下载目录`
>
> 本轮只隔离测试 `OPFS → blob URL → downloads` 这一段。**没有引入网络**：字节在本地生成后写进 OPFS，**多路 Range 下载本身未测**（见 §7）。
>
> 关键代码在 `/tmp/aria2-probe/A-pipeline/`；本文档是唯一写进 `/workspace` 的文件。

---

## 0 元信息

| 项 | 值 | 来源（实测命令） |
|---|---|---|
| 浏览器 | **Google Chrome for Testing 148.0.7778.96** | `/root/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome --version` |
| CDP 版本 | `product: Chrome/148.0.7778.96`，`protocolVersion: 1.3`，`jsVersion: 14.8.178.14`，`revision: @8625e066febc721e015ea99842da12901eb7ed73` | `Browser.getVersion`（CDP，由 driver 记录进 `results-full.json`） |
| 日期 | **2026-10-06**（UTC 11:59:13 → 12:00:05 主矩阵；12:02 phase E；12:06 phase G。容器时钟 CST = UTC+8） | `date -u` / driver 时间戳 |
| 系统 | Linux x86_64 容器，root，19 GB RAM，`/tmp` overlay 933 GB 可用 | `free -g`、`df -h /tmp` |
| 扩展 | 未打包 MV3，扩展 ID `hngdpehglkiklacpdfmfikfejmjgnfai`（= unpacked 路径的 SHA-256 前 32 hex 映射 a–p），权限 `downloads / offscreen / unlimitedStorage / storage` | `chrome.runtime.getManifest()` |
| 自动化 | playwright-core **1.60.0**（`npm i playwright-core@1.60.0` 装在 `/tmp/aria2-probe/A-pipeline/pw`），显式 `executablePath` 指向共享缓存 | `runx.sh` |
| 显示 | `Xvfb :96/:99 …`（**本镜像缺 `xauth`，`xvfb-run -a` 直接报错 `xauth command not found`**，改为手工起 Xvfb + `DISPLAY=`），扩展必须 headed | `runx.sh` 输出 |
| 下载落盘目录 | `/tmp/aria2-probe/A-pipeline/home/Downloads`（绝对路径；通过 `env.HOME` 控制） | 见 §2 校准 |
| 磁盘 | 起始 `/tmp` 可用 933 GB，结束 933 GB；整个实验峰值占用 < 2 GB；每个大档测完立即删除 | `df -h /tmp`（§9 有逐档记录） |

**Playwright 陷阱（实测，不是文档推断）**：`launchPersistentContext()` 无条件发送
`Browser.setDownloadBehavior{behavior:"allowAndName", downloadPath:<artifacts>}`，会把**每个落盘文件改名成 GUID**，并让 `chrome.downloads.download({filename})` 参数**被忽略**。本实验在 launch 之后立刻补发
`Browser.setDownloadBehavior{behavior:"default"}` 撤销它，并用一次“校准下载”确认生效。详见 §3.5 / §6.4。

---

## 1 一句话结论

**通，但只有一个可行形态：必须由“文档侧”（offscreen document）造 blob URL、由 MV3 service worker 调 `chrome.downloads.download`。**
这一形态下 10 MB / 200 MB 均**完整落盘且逐字节正确**（sha256 与 Node 端独立重算一致），并且**免手势、不弹框**。

同时实测到两个"半边死"：
- **offscreen 里没有 `chrome.downloads`**（`Object.keys(chrome)` 只有 `["csi","loadTimes","runtime"]`）→ 「offscreen 造 + offscreen 调」这格**不可能**；offscreen 里唯一能发起下载的是 `<a download>` 点击（实测可行，但绕开了 downloads API）。
- **SW 里没有 `URL.createObjectURL`**（`TypeError: URL.createObjectURL is not a function`）→ SW **不能自己造** blob URL。

生命周期规则也很干净：**blob URL 只需活到 `downloads.download()` 返回**。之后立刻 `revokeObjectURL()` 或 `closeDocument()` 都不影响下载（200 MB 实测仍完整落盘、sha256 逐字节一致）；反之在调用**之前**销毁 → `NETWORK_FAILED` / `state: interrupted`、`bytesReceived: 0`。

---

## 2 测试扩展的结构与最小代码

### 2.1 文件结构（`/tmp/aria2-probe/A-pipeline/ext/`）

```
ext/
  manifest.json      # MV3，权限 downloads/offscreen/unlimitedStorage/storage
  sw.js              # service worker：downloads 事件记录 + 命令路由 + SW 侧 OPFS 读写
  offscreen.html     # 空白文档
  offscreen.js       # 文档侧：OPFS 写、createObjectURL、<a download>、fetch 探针
  probe.html/probe.js# 普通扩展页面（<a download> 对照组）
  flags.js           # 由 driver 重写，仅用于 §6.4 的 A/B（importScripts 同步加载）
```

### 2.2 manifest.json（完整）

```json
{
  "manifest_version": 3,
  "name": "A-pipeline probe",
  "version": "1.0",
  "minimum_chrome_version": "116",
  "permissions": ["downloads", "offscreen", "unlimitedStorage", "storage"],
  "background": { "service_worker": "sw.js" },
  "action": { "default_title": "probe" }
}
```

### 2.3 SW 侧最小代码（关键片段）

```js
// sw.js —— 事件必须注册在顶层（每次 SW 启动都会重新注册）
chrome.downloads.onCreated.addListener(d => log({ ev: 'onCreated', item: slim(d) }));
chrome.downloads.onChanged.addListener(delta => log({ ev: 'onChanged', delta }));

// 建 offscreen
await chrome.offscreen.createDocument({
  url: 'offscreen.html', reasons: ['BLOBS'],
  justification: 'assemble bytes and create blob URLs for the download pipeline probe',
});
// 是否已存在（Chrome 116+）：chrome.runtime.getContexts
const has = (await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'] })).length > 0;

// 关键那一行：SW 造不了 URL，只能拿 offscreen 造好的字符串
const id = await chrome.downloads.download({ url: blobUrlFromOffscreen, saveAs: false,
                                             filename: 'name.bin', conflictAction: 'overwrite' });
```

SW 与 offscreen 之间的 RPC：SW `chrome.runtime.sendMessage({target:'offscreen', op, args, __reply:id})`，
offscreen 执行完再 `chrome.runtime.sendMessage({__reply:id, result})`（SW 的 `sendMessage` 不会投递给自己的 onMessage）。

### 2.4 offscreen 侧最小代码（关键片段）

```js
// offscreen.js
const root = await navigator.storage.getDirectory();          // OPFS 可用
const fh   = await root.getFileHandle('payload.bin', {create:true});
const w    = await fh.createWritable();
await w.write(new Uint8Array(8*1024*1024));                   // 分片写
await w.write({ type:'write', position: 16*1024*1024, data: chunk });  // 乱序按偏移写：可行
await w.close();

const file = await fh.getFile();                 // File（type 由文件名后缀推导，见 §3.6）
const url  = URL.createObjectURL(file);          // ← 只有文档侧能做这件事
// 然后把 url 作为字符串交给 SW 去 chrome.downloads.download
```

### 2.5 测试字节是“可独立重算”的

为了让“下载下来的文件是否正确”可被 Node 端独立验证（而不是只看 `state: complete`），字节按**绝对偏移的纯函数**生成：
每 1 MiB 一个块，块头 16 字节 `42 4C 4B <blockIdx&0xff> | u32be(blockIdx) | u32be(total) | EE EE EE EE`，其余填 `TILE[offset % 4096]`，`TILE[i] = (i*31 + (i>>8)*97 + 7) & 0xff`。
Node 端用同一函数重算 → 得到期望 sha256 与任意偏移的 32 字节片段，与浏览器侧 / 磁盘上的文件比对。

---

## 3 组合矩阵结果

主矩阵运行：`bash runx.sh full`（`full` = 200 MB 档），全部结果落进 `out/results-full.json`。
落盘目录统一为 `/tmp/aria2-probe/A-pipeline/home/Downloads`。

| # | 谁造 blob URL | 谁发起下载 | 是否启动 | 是否完成 | 最终路径 | 文件名 | `bytesReceived` | 备注 |
|---|---|---|---|---|---|---|---|---|
| ① | offscreen | **offscreen `chrome.downloads`** | ❌ | ❌ | — | — | — | **API 不存在**：`chrome.downloads` undefined |
| ①' | offscreen | **offscreen `<a download>` 点击** | ✅ | ✅ | `…/home/Downloads/b1c-off-anchor.bin` | `b1c-off-anchor.bin`（显式） | 10485760/10485760 | id=3；可用的替代写法 |
| ② | offscreen | **SW `chrome.downloads`** | ✅ | ✅ | `…/home/Downloads/058c4684-….txt` | 未给 filename → **blob UUID + `.txt`** | 10485760/10485760 | id=4；**本路线的可行形态** |
| ②b | offscreen | SW（显式 `filename:'sub/b2b-sw-named.bin'`） | ✅ | ✅ | `…/Downloads/**sub**/b2b-sw-named.**txt**` | 子目录可建；后缀被改成 `.txt` | 10485760/10485760 | id=5；原因见 §3.6 |
| ②c | offscreen | SW（`new Blob([file])` 包一层） | ✅ | ✅ | `…/Downloads/b2d-wrapped.txt` | 同样被改成 `.txt` | 10485760/10485760 | id=6 |
| ③ | 普通扩展页（tab） | **tab `<a download download=''`** | ✅ | ✅ | `…/Downloads/008e48a9-93ae-43a1-b5a7-307d8549f8c4` | **blob UUID，无后缀** | 10485760/10485760 | id=7；对照 |
| ③b | 普通扩展页（tab） | tab `<a download download='b3b-tab-anchor.bin'` | ✅ | ✅ | `…/Downloads/b3b-tab-anchor.bin` | `b3b-tab-anchor.bin` | 10485760/10485760 | id=8；对照 |
| ④ | **SW** | SW | ❌ | ❌ | — | — | — | `URL.createObjectURL is not a function` |
| ⑤ | （对照）无 blob | SW `data:` URL | ✅ | ✅ | `…/Downloads/sw-dataurl-control.bin` | `sw-dataurl-control.bin` | 1024/1024 | id=9；证明 downloads API 本身正常 |

补充实测（同一轮）：

- **②的 blob URL 跨上下文可解析**：SW 自己 `fetch(offscreenBlobUrl)` → `status 200, bytes 10485760, headHex 424c4b00…`（`B2c`）。所以跨上下文传的是**活 URL**，不只是字符串。
- **`bytesReceived` 有值**：blob 下载在 `onCreated` 时 `bytesReceived: 0`，完成时给出真实值（`209715200/209715200`）；`fileSize/totalBytes` 在 `onCreated` 时就已知（Chrome 知道 blob 大小）。`data:` URL 在 `onCreated` 时 `fileSize: 0, totalBytes: 0`，完成时才填。
- **事件序列（每一格都是同一形状，实测原文见 §9.1）**：
  `onCreated(filename="", state=in_progress)` → `onChanged{filename: 绝对路径}` → `onChanged{state:"complete", endTime}`；
  失败时只有一条：`onChanged{error:"NETWORK_FAILED", state:"interrupted"}`。
- **`saveAs` 全程为 false**，没有弹框，也没有任何用户手势 —— “免手势落盘”这一点成立。

### 3.5 校准：文件到底落在哪、名字是不是真的

`C0_calibration_where_do_files_land`：

```
download -> id=1
chrome.downloads.search -> filename: /tmp/aria2-probe/A-pipeline/home/Downloads/calib-where.bin
ls /tmp/aria2-probe/A-pipeline/home/Downloads -> ["calib-where.bin"]   (11 bytes)
ls /tmp/aria2-probe/A-pipeline/downloads     -> []                     (Playwright 的 downloadsPath 已被撤销)
```

即：**`filename` 参数被尊重、文件名不是 GUID**。这是后面所有“文件名”结论可信的前提。

### 3.6 文件名规则（哪来的 `.txt`）

实测 `File.type` 由 **OPFS 条目名的后缀**推导（`E1`，2 MB 分片写）：

| OPFS 条目名 | `getFile().type` | 不带 `filename` 下载后的落盘名 | `mime` |
|---|---|---|---|
| `e1-bin.bin` | `application/octet-stream` | `<blob-uuid>`（**无后缀**） | application/octet-stream |
| `e1-json.json` | `application/json` | （同上规律） | — |
| `e1-internal.internal` | `""` | `<blob-uuid>.txt` | **text/plain** |
| `e1-noext` | `""` | （同上规律） | — |

结论：
1. **OPFS 内部文件名绝不会被带出去**。不给 `filename` 时，落盘名 = **blob URL 的 UUID**（`058c4684-92a4-475d-b2b8-a7b3a319ae22`），与 `opfs-internal-9f3c.internal` 无关。
2. 若 blob 的 MIME 为空，Chrome 嗅探成 `text/plain`，于是**给 UUID 补上 `.txt`**；即使你显式传 `filename:'sub/b2b-sw-named.bin'`，**后缀也会被改成 `.txt`**（`b2b-sw-named.bin → b2b-sw-named.txt`）。
3. 工程含义：造 blob 时**显式带 MIME**（如 `new Blob(chunks, {type:'application/octet-stream'})`）或让源文件有正确后缀，否则用户拿到的是 `.txt`。

---

## 4 blob URL 生命周期实测

200 MB 档，`phaseE.js`（`out/results-phaseE.json`）。时间以 `downloads.download()` 调用起点为 0。

| 实验 | 动作与时序 | 结果 | 证据 |
|---|---|---|---|
| **C1** | 10 MB：调用后立刻 `revokeObjectURL()`（同一 tick，另加重复 revoke） | ✅ **完成** `state:complete` `bytesReceived 10485760`；`revokeObjectURL` 幂等不报错 | 落盘 `c1-revoke-immediate.bin` |
| **E2b** | **200 MB**：`downloads.download()` 于 **6 ms** 返回 → **10 ms** 时 `revokeObjectURL()` → 传输实际持续到 **1.48 s** | ✅ **完成**，磁盘 209715200 字节，**sha256 = 64c09889…（与预期逐字节一致）** | `e2b-revoke-midflight.bin` |
| **E2a** | **200 MB**：6 ms 返回 → **13 ms** `chrome.offscreen.closeDocument()` → 传输到 **1.85 s** | ✅ **完成**，209715200 字节，**sha256 一致** | `e2a-close-midflight.bin`；事件里可见 `offscreen_ready_msg`（重开）在其后才出现 |
| **C4** | 10 MB：调用后 120 ms 关 offscreen | ✅ 完成（10 MB 传输仅 46 ms，其实在关闭前就结束了 → 该格不构成“飞行中”） | 由 E2a 用 200 MB 重做 |
| **C1b** | **先** `revokeObjectURL()` **再** `downloads.download()` | ❌ `state:"interrupted"`，`error:"NETWORK_FAILED"`，`bytesReceived:0`，`fileSize:0`；同刻 `fetch(url)` → `TypeError: Failed to fetch` | 落盘 `c1b-revoked-first.bin`（0 字节） |
| **C3** | **先** `closeDocument()` **再** `downloads.download()` | ❌ 同上 `NETWORK_FAILED` / interrupted；`swFetchBlobUrl` → `TypeError: Failed to fetch` | `c3-after-close.bin` |
| **C2** | 完成后 revoke | ✅ 文件仍在磁盘、item 仍 `complete` | `c2-revoke-after.bin` |
| **C5** | `closeDocument()` 后重新 `createDocument()`，再新造 URL | ✅ 新 offscreen 工作正常（`c5-after-reopen.bin` 完成） | — |

**可操作的规则**：`await chrome.downloads.download(...)` 返回后，blob URL 的使命就结束了 —— 可以立即 `revokeObjectURL()` 并关闭 offscreen 文档来释放内存，下载不受影响；但**绝不能在调用前销毁**。

---

## 5 OPFS 写入能力实测（offscreen vs SW）

`A4/A5/A8/A9/A11/A12`，`out/results-full.json`。

| 能力 | offscreen document | MV3 service worker |
|---|---|---|
| `navigator.storage.getDirectory()` | ✅ `function` | ✅ `function` |
| 写 10 MB（2 MB 分片） | ✅ `size 10485760`，`msTotal 80.4`（`msOpen 2.7`） | ✅ `size 10485760`，`msTotal 2354.9`（首次/冷，见下） |
| 写 **200 MB**（8 MB 分片 ×25） | ✅ `size 209715200`，`msTotal 1327.1` | ✅ `size 209715200`，`msTotal 1552.4` |
| 读回**对方**写的文件 | ✅ 读 `sw-10mb.bin`：`headHex 424c4b00…, tailHex d6f51433…` | ✅ 读 `off-10mb.bin`：同上 head/tail |
| 列举（`root.entries()`） | ✅ 同时看到 `sw-10mb.bin` 与 `off-10mb.bin` | ✅ 同上 → **同一命名空间** |
| 10 MB 内容 sha256 | ✅ `b9f90cd7…a85fab` = Node 端独立重算值 | （同函数实现） |
| 删除 | ✅ `removeEntry` | ✅ `removeEntry` |
| **乱序按偏移写**（多连接组装的刚需） | ✅ `createWritable()` + `write({type:'write', position, data})` + `seek()` | ✅ 同样可用 |
| `createSyncAccessHandle` | ❌ `undefined`（document 本来就没有） | ❌ **`undefined`**（连 SW 也没有） |
| 配额 | `quota ≈ 992 GB`，`usageDetails.fileSystem` 随写入增长 | 同 |

- 乱序写实测（`phaseG`，两边结果相同）：依次写 `{at:8MiB,0x33} {at:0,0x11} {at:16MiB,0x22}` → `size 17825792`，读回 `at0=[17,17,17,17] at8MiB=[51,51,51,51] at16MiB=[34,34,34,34]`。**偏移精确命中**。
- 所以“多路 Range 各自写自己的偏移”在 **SW 和 offscreen 两边都能做**（用 `createWritable()` 的定位写；`createSyncAccessHandle` 这条路在 Chrome 148 的 MV3 SW 里不存在）。
- `A4` 的 2354 ms 是 SW 冷启动/被 driver evaluate 唤醒时的单次抖动；同代码 200 MB 只用 1552 ms。这条**不构成结论**，只说明单点耗时噪声大。

---

## 6 失败与报错原文

> 规则：每个失败先排除“我自己写错了”。下面每条都给出**原始报错串**和**至少一种替代写法**的实测结果。

### 6.1 「offscreen 造 + offscreen 调」不可行

```
{"ok":false,"errName":"TypeError",
 "errMessage":"chrome.downloads is undefined in the offscreen document",
 "chromeKeys":["csi","loadTimes","runtime"]}
```

独立佐证（`A2_offInfo`，直接读 offscreen 的全局）：

```
{"isDocument":true,"hasGetDirectory":"function","hasCreateObjectURL":"function",
 "hasDownloadApi":"undefined","hasDownloadsNamespace":"undefined",
 "chromeKeys":["csi","loadTimes","runtime"]}
```

**不是写法问题**：`chrome` 对象在 offscreen 里存在（`runtime` 可用，RPC 正常），但**根本没有 `downloads` 命名空间**。
**替代写法（实测可行）**：`①'` —— 在 offscreen 里 `<a download>` 点击：
`offAnchorClick` 返回 `{"ok":true,...,"inDocument":true,"hasFocus":false,"visibility":"visible"}`，文件 `b1c-off-anchor.bin` 10485760 字节完整落盘。
代价：绕开 downloads API，拿不到 `downloads` 的事件流/暂停/取消/`filename` 控制；且这是“文档发起下载”，语义上更接近浏览器自身的下载路径。

### 6.2 SW 不能造 blob URL

```
{"ok":false,"errName":"TypeError",
 "errMessage":"URL.createObjectURL is not a function",
 "errStack":"TypeError: URL.createObjectURL is not a function\n    at chrome-extension://hngdpehglkiklacpdfmfikfejmjgnfai/sw.js:182:145"}
```

`A3_swInfo_createObjectURL`：`{"hasGetDirectory":"function","hasCreateObjectURL":"undefined","selfCtor":"ServiceWorkerGlobalScope"}`。
**不是写法问题**：`typeof URL.createObjectURL === "undefined"`，`URL` 本身存在。故 SW 造 URL 这条**没有替代写法**，只能由文档侧造。

### 6.3 调用前销毁 URL / 关闭文档 → NETWORK_FAILED

```
{"state":"interrupted","error":"NETWORK_FAILED","bytesReceived":0,"totalBytes":0,"fileSize":0}
onChanged {"error":"NETWORK_FAILED","filename":"…/c1b-revoked-first.bin","mime":"application/octet-stream","state":"interrupted"}
fetch(已 revoke 的 URL) -> TypeError: Failed to fetch
```

替代写法：把 `revoke`/`closeDocument` 挪到 `downloads.download()` **之后**（§4 的 E2a/E2b 证明完全可行）。

### 6.4 两个“工具/仪器”层面的坑（都不是平台限制，但会污染结论）

**(a) Playwright 把文件名改成 GUID，并吞掉 `filename` 参数。**
`launchPersistentContext` 内部：

```js
// playwright-core/lib/coreBundle.js (CRBrowserContext.initialize)
promises.push(this._browser._session.send("Browser.setDownloadBehavior", {
  behavior: this._options.acceptDownloads === "accept" ? "allowAndName" : "deny",
  browserContextId: this._browserContextId,
  downloadPath: this._browser.options.downloadsPath, eventsEnabled: true }));
```

实测后果：`filename:"named-by-me.txt"` → 落盘 `/tmp/playwright-artifacts-XXXX/54c2a982-99e6-415c-9a91-514259f59430`；传 `acceptDownloads:'internal-browser-default'` 也**没能**绕开。
**解法（实测有效）**：launch 后补发 `Browser.setDownloadBehavior{behavior:"default"}`（`ctx.browser().newBrowserCDPSession()`）→ 立刻恢复原生行为，落盘 `/tmp/aria2-probe/A-pipeline/home/Downloads/named-by-me.txt`。
（中途我曾用 `behavior:'allow' + downloadPath` 覆盖，落盘名变成 `download`，**`filename` 参数依旧被吞** —— 所以只有 `default` 是对的。）

**(b) 自己注册的空 `onDeterminingFilename` 监听器会静默改写文件名。**
A/B（`ab-dfl.js`，同一扩展同一 200 MB→2 MB 简化流程，只切 `self.__ENABLE_DFL`；脚本重写 `ext/flags.js` 后重启浏览器，脚本以 `importScripts('flags.js')` 同步加载）：

| `onDeterminingFilename` 监听器 | 请求的 `filename` | 实际落盘名 |
|---|---|---|
| 未注册 | `ab-named.bin` | ✅ `/…/Downloads/ab-named.bin` |
| **已注册但从不调用 `suggest()`** | `ab-named.bin` | ❌ `/…/Downloads/ce8fe493-de53-4d93-a4d6-81edede0e20b`（blob UUID） |

每个条件各跑 1 轮、每轮 3 个下载（`dflEvents captured: 0` vs `3`，确认监听器确实收到了事件）。同一轮内该效应在 3 个用例上一致。
**注意**：本轮更早的一次 A/B 曾得出“监听器无影响”的结论，那是被 §6.4(a) 的 `behavior:'allow'` 覆盖污染（该模式下 `filename` 参数本来就被吞）；改用 `behavior:'default'` 后效应才显现。这两个坑会互相掩盖。
**这条是给实现者的警告**：注册了 `onDeterminingFilename` 却不调用 `suggest()`，等于把你的 `filename` 参数丢掉。本文档其它所有文件名结论都建立在 `__ENABLE_DFL=false` 之上。

### 6.5 我自己写错过的两处（记录以免读者重踩）

- 我第一次写 OPFS 分片填充循环时 `TILE` 只有 4096 字节却按整块长度 `subarray`，会 `RangeError`；改为 `n = min(blockEnd-o, 4096 - o%4096)` 后正确（已体现在最终代码里）。
- 我第一次跑 Phase B 忘记先建 offscreen 文档，得到
  `"sendMessage to offscreen failed: Error: Could not establish connection. Receiving end does not exist."`
  —— 这是**我的脚本顺序问题**，不是平台问题；driver 之后在任何 phase 前都先 `ensureOffscreen()`。

---

## 7 未能测成的部分与原因

1. **多路 Range 抓取本身没测**（本轮硬性要求：不引入网络变量）。所以“多连接”只到“字节按偏移分片写进 OPFS”为止；真实并发连接下的乱序到达、失败重试、连接数上限**未测**。
2. **`saveAs: true`（另存为对话框）未测**：需要真实 UI 交互，Xvfb 下的自动化不可靠；本轮全部用 `saveAs:false`。
3. **用户偏好“下载前询问保存位置”未测**：profile 是全新的，未改该 pref。
4. **>2 GB 的 blob 未测**（最大 200 MB）；超大对象在渲染进程/浏览器进程的内存与 blob 存储行为**未测**。
5. **SW 被杀后下载是否延续未测**：本轮 SW 全程未死（`bootCount: 1`，`Z_bootCount {"bootCount":1,"currentBootId":1}`），因此“下载是浏览器进程行为、与 SW 生命周期无关”这一点**我只是没有观测到反例，不算实测结论**。
6. **并发多下载 / 队列行为未测**（每次只跑一个下载）。
7. **只在 Chrome 148.0.7778.96 / Linux / 未打包扩展下测过**；其它版本、其它平台、企业策略、隐身模式未测。
8. **`memory` 相关只记录了 `performance.memory` 原始值**（增量 26.3 MB vs 一次性 211.8 MB used heap），**未做内存结论** —— 内存上限由另一位实验员负责，避免重复劳动。
9. offscreen 文档里**除 `downloads` 外的其它 chrome API 未逐一枚举**（只打了 `Object.keys(chrome)`）。
10. **offline/网络中断、磁盘写满（quota exceeded）路径未测**。

---

## 8 复现步骤

### 8.1 环境

```bash
# 浏览器（共享缓存，不重下）
/root/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome --version
# -> Google Chrome for Testing 148.0.7778.96

# xauth 缺失，xvfb-run 不可用；手工起 Xvfb
which xauth || echo "no xauth -> use raw Xvfb"
Xvfb :99 -screen 0 1600x1200x24 -nolisten tcp &

# 驱动库（只要 playwright-core，浏览器用共享缓存）
mkdir -p /tmp/aria2-probe/A-pipeline/pw
cd /tmp/aria2-probe/A-pipeline/pw && npm i playwright-core@1.60.0
```

### 8.2 目录

全部绝对路径、且都在 `/tmp/aria2-probe/A-pipeline` 下（不碰 `/workspace` 所在盘）：

```
/tmp/aria2-probe/A-pipeline/
  ext/                 # 扩展源码（§2.1）
  pw/node_modules/     # playwright-core 1.60.0
  driver.js            # 主矩阵 + 生命周期 driver
  phaseE.js            # 200MB 飞行中 close/revoke + 文件名→MIME 映射
  phaseF.js phaseG.js  # createSyncAccessHandle / 乱序定位写
  ab-dfl.js            # §6.4(b) 的 A/B
  runx.sh              # 起 Xvfb + 跑 driver + 前后 df
  profile/ home/ downloads/ out/
```

### 8.3 启动配方（关键 4 行）

```js
const ctx = await chromium.launchPersistentContext('/tmp/aria2-probe/A-pipeline/profile', {
  headless: false,                                  // 扩展必须 headed
  executablePath: '/root/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome',
  acceptDownloads: true,
  downloadsPath: '/tmp/aria2-probe/A-pipeline/downloads',   // 显式绝对路径
  env: { ...process.env, HOME: '/tmp/aria2-probe/A-pipeline/home' },
  args: [`--disable-extensions-except=/tmp/aria2-probe/A-pipeline/ext`,
         `--load-extension=/tmp/aria2-probe/A-pipeline/ext`,
         '--disable-dev-shm-usage', '--no-first-run'],
});
// ★ 必须补这一行，否则文件名全是 GUID、filename 参数被吞（§6.4a）
const bs = await ctx.browser().newBrowserCDPSession();
await bs.send('Browser.setDownloadBehavior', { behavior: 'default' });
```

取 SW / offscreen：

```js
const sw  = ctx.serviceWorkers().find(w => w.url().includes(EXT_ID));  // 注意过滤掉组件扩展的 SW
await sw.evaluate(r => globalThis.__cmd(r), { op, args });             // 直接驱动 SW
await sw.evaluate(() => globalThis.__cmd({op:'ensureOffscreen'}));
// offscreen 文档不是 Playwright 的 page target：
//   ctx.pages()       -> ["about:blank", "chrome-extension://…/probe.html"]
//   ctx.backgroundPages() -> []
// 只能通过 chrome.runtime.getContexts 在 SW 里看到它（contextType: "OFFSCREEN_DOCUMENT"）
```

运行：

```bash
bash /tmp/aria2-probe/A-pipeline/runx.sh full        # 主矩阵（200MB 档），约 50 s
DISPLAY=:99 node /tmp/aria2-probe/A-pipeline/phaseE.js   # 飞行中销毁 / MIME 映射
DISPLAY=:99 node /tmp/aria2-probe/A-pipeline/phaseG.js   # 乱序定位写
for F in false true; do DISPLAY=:99 node /tmp/aria2-probe/A-pipeline/ab-dfl.js $F; done  # §6.4b A/B
```

每次大动作前后 `df -h /tmp`（`runx.sh` 已内置），单档测完立刻删除落盘文件与 OPFS 条目。

---

## 9 原始数据

### 9.1 `chrome.downloads` 事件序列（主矩阵全量，`results-full.json` → `Z_final_events`）

```
onCreated id=1  data:…Q0FMSUJSQVRJT04=  filename=""  state=in_progress fileSize=0        totalBytes=0        mime=application/octet-stream
  onChanged id=1 {"fileSize":11,"filename":"/tmp/aria2-probe/A-pipeline/home/Downloads/calib-where.bin","totalBytes":11}
  onChanged id=1 {"endTime":"2026-10-06T11:59:22.268Z","state":"complete"}
onCreated id=3  blob:…/368347dd-…        filename=""  state=in_progress fileSize=10485760 totalBytes=10485760 mime=text/plain
  onChanged id=3 {"filename":"/tmp/aria2-probe/A-pipeline/home/Downloads/b1c-off-anchor.bin","mime":"application/octet-stream"}
  onChanged id=3 {"endTime":"2026-10-06T11:59:33.311Z","state":"complete"}
onCreated id=4  blob:…/058c4684-…        filename=""  state=in_progress fileSize=10485760 totalBytes=10485760 mime=text/plain
  onChanged id=4 {"filename":"/tmp/aria2-probe/A-pipeline/home/Downloads/058c4684-92a4-475d-b2b8-a7b3a319ae22.txt"}
  onChanged id=4 {"endTime":"2026-10-06T11:59:33.823Z","state":"complete"}
onCreated id=5  blob:…/1edffafd-…        filename=""  state=in_progress fileSize=10485760 totalBytes=10485760 mime=text/plain
  onChanged id=5 {"filename":"/tmp/aria2-probe/A-pipeline/home/Downloads/sub/b2b-sw-named.txt"}
  onChanged id=5 {"endTime":"2026-10-06T11:59:34.908Z","state":"complete"}
onCreated id=6  blob:…/10b2ee77-…        filename=""  state=in_progress fileSize=10485760 totalBytes=10485760 mime=text/plain
  onChanged id=6 {"filename":"/tmp/aria2-probe/A-pipeline/home/Downloads/b2d-wrapped.txt"}
  onChanged id=6 {"endTime":"2026-10-06T11:59:36.112Z","state":"complete"}
onCreated id=7  blob:…/008e48a9-…        filename=""  state=in_progress fileSize=10485760 totalBytes=10485760 mime=application/octet-stream
onCreated id=8  blob:…/1d6861ed-…        filename=""  state=in_progress fileSize=10485760 totalBytes=10485760 mime=application/octet-stream
  onChanged id=7 {"filename":"/tmp/aria2-probe/A-pipeline/home/Downloads/008e48a9-93ae-43a1-b5a7-307d8549f8c4"}
  onChanged id=8 {"filename":"/tmp/aria2-probe/A-pipeline/home/Downloads/b3b-tab-anchor.bin"}
  onChanged id=7 {"endTime":"2026-10-06T11:59:37.366Z","state":"complete"}
  onChanged id=8 {"endTime":"2026-10-06T11:59:37.367Z","state":"complete"}
onCreated id=9  data:…QUFBQQ==           filename=""  state=in_progress fileSize=0        totalBytes=0        mime=application/octet-stream
  onChanged id=9 {"fileSize":1024,"filename":"/tmp/aria2-probe/A-pipeline/home/Downloads/sw-dataurl-control.bin","totalBytes":1024}
  onChanged id=9 {"endTime":"2026-10-06T11:59:37.646Z","state":"complete"}
onCreated id=10 blob:…/99567e61-…        filename=""  state=in_progress fileSize=10485760 totalBytes=10485760 mime=application/octet-stream
  onChanged id=10 {"filename":"/…/c1-revoke-immediate.bin"}   ; onChanged {"endTime":"…11:59:40.318Z","state":"complete"}
onCreated id=11 blob:…/13fb3131-…        filename=""  state=in_progress fileSize=0        totalBytes=0        mime=
  onChanged id=11 {"error":"NETWORK_FAILED","filename":"/…/c1b-revoked-first.bin","mime":"application/octet-stream","state":"interrupted"}
onCreated id=12 blob:…/394673bf-…        filename=""  state=in_progress fileSize=10485760 totalBytes=10485760 mime=application/octet-stream
  onChanged id=12 {"filename":"/…/c2-revoke-after.bin"}; onChanged {"endTime":"…11:59:41.417Z","state":"complete"}
onCreated id=13 blob:…/452778c3-…        filename=""  state=in_progress fileSize=0        totalBytes=0        mime=
  onChanged id=13 {"error":"NETWORK_FAILED","filename":"/…/c3-after-close.bin","mime":"application/octet-stream","state":"interrupted"}
onCreated id=14 blob:…/88bf4523-…        filename=""  state=in_progress fileSize=10485760 totalBytes=10485760 mime=application/octet-stream
  onChanged id=14 {"filename":"/…/c4-close-midflight.bin"}; onChanged {"endTime":"…11:59:45.688Z","state":"complete"}
onCreated id=15 blob:…/fe89ce9a-…        filename=""  state=in_progress fileSize=10485760 totalBytes=10485760 mime=application/octet-stream
  onChanged id=15 {"filename":"/…/c5-after-reopen.bin"}; onChanged {"endTime":"…11:59:45.884Z","state":"complete"}
onCreated id=16 blob:…/39ee6c7d-…        filename=""  state=in_progress fileSize=209715200 totalBytes=209715200 mime=application/octet-stream
  onChanged id=16 {"filename":"/…/d1-incremental-200mb.bin"}; onChanged {"endTime":"…11:59:53.662Z","state":"complete"}
onCreated id=17 blob:…/a3085471-…        filename=""  state=in_progress fileSize=209715200 totalBytes=209715200 mime=application/octet-stream
  onChanged id=17 {"filename":"/…/d2-oneshot-200mb.bin"}; onChanged {"endTime":"…11:59:55.964Z","state":"complete"}
  onChanged id=16 {"exists":false}          ← driver 校验完 sha256 后立即删文件
onCreated id=18 blob:…/bf0…              filename=""  state=in_progress fileSize=209715200 totalBytes=209715200 mime=application/octet-stream
  onChanged id=18 {"filename":"/…/d3-dropped-200mb.bin"}; onChanged {"endTime":"…12:00:01.797Z","state":"complete"}
onCreated id=19 blob:…/a8d…              filename=""  state=in_progress fileSize=209715200 totalBytes=209715200 mime=application/octet-stream
  onChanged id=19 {"filename":"/…/d4-opfs-200mb.bin"}; onChanged {"endTime":"…12:00:05.228Z","state":"complete"}
```

`onErased` / `onDeterminingFilename` 在主矩阵中**一次都没触发**（`__ENABLE_DFL=false`）。

### 9.2 下载项终态（`Z_final_searchAll`，19 项，节选关键字段）

```
id | url  | filename                                                              | state       | error          | bytesReceived
18 | blob | /…/Downloads/d3-dropped-200mb.bin                                     | complete    | -              | 209715200/209715200
17 | blob | /…/Downloads/d2-oneshot-200mb.bin                                     | complete    | -              | 209715200/209715200
16 | blob | /…/Downloads/d1-incremental-200mb.bin                                 | complete    | -              | 209715200/209715200
19 | blob | /…/Downloads/d4-opfs-200mb.bin                                        | complete    | -              | 209715200/209715200
13 | blob | /…/Downloads/c3-after-close.bin                                       | interrupted | NETWORK_FAILED | 0/0
11 | blob | /…/Downloads/c1b-revoked-first.bin                                    | interrupted | NETWORK_FAILED | 0/0
 4 | blob | /…/Downloads/058c4684-92a4-475d-b2b8-a7b3a319ae22.txt                 | complete    | -              | 10485760/10485760  mime=text/plain
 5 | blob | /…/Downloads/sub/b2b-sw-named.txt                                     | complete    | -              | 10485760/10485760  mime=text/plain
 6 | blob | /…/Downloads/b2d-wrapped.txt                                          | complete    | -              | 10485760/10485760  mime=text/plain
 3 | blob | /…/Downloads/b1c-off-anchor.bin                                       | complete    | -              | 10485760/10485760
 7 | blob | /…/Downloads/008e48a9-93ae-43a1-b5a7-307d8549f8c4                    | complete    | -              | 10485760/10485760
 8 | blob | /…/Downloads/b3b-tab-anchor.bin                                       | complete    | -              | 10485760/10485760
10 | blob | /…/Downloads/c1-revoke-immediate.bin                                  | complete    | -              | 10485760/10485760
12 | blob | /…/Downloads/c2-revoke-after.bin                                      | complete    | -              | 10485760/10485760
14 | blob | /…/Downloads/c4-close-midflight.bin                                   | complete    | -              | 10485760/10485760
15 | blob | /…/Downloads/c5-after-reopen.bin                                      | complete    | -              | 10485760/10485760
 1 | data | /…/Downloads/calib-where.bin                                          | complete    | -              | 11/11
 9 | data | /…/Downloads/sw-dataurl-control.bin                                   | complete    | -              | 1024/1024
```

### 9.3 增量攒 blob（captain 追加组合）

200 MB，每块 8 MB（25 块）。期望 sha256 由 Node 端独立重算：**`64c09889a179ab40624663dffadf3e361ea3e5d3aab61c03a782775f69b5925f`**。

| 造法 | 组装耗时 | 下载后磁盘大小 | 磁盘 sha256 | 与期望 |
|---|---|---|---|---|
| 增量：`chunks.push(new Blob([chunk]))` ×25 → `new Blob(chunks)` | 循环 427.1 ms + **组装 1.2 ms** | 209715200 | `64c09889…b5925f` | ✅ 一致 |
| 一次性：`new Blob([整块 200MB Uint8Array])` | 组装 92.7 ms | 209715200 | `64c09889…b5925f` | ✅ 一致 |
| 增量 + **清空 chunks**（`chunks.length=0; chunks=null`） | 循环 372.3 ms + 组装 1.1 ms | 209715200 | `64c09889…b5925f` | ✅ 一致 |
| OPFS 支撑：写 200 MB → `createObjectURL(getFile())` | 写 958.8 ms | 209715200 | `64c09889…b5925f` | ✅ 一致 |

逐字节切片校验（浏览器内 `fetch(blobUrl)` → `blob.slice()`，四处头/中/尾，与 Node 端期望**逐字节相同**）：

```
@0         424c4b00000000000c800000eeeeeeeef71635547392b1d0ef0e2d4c6b8aa9c8   ← 块0头（total=0x0c800000=200MiB）
@4096      0726456483a2c1e0ff1e3d5c7b9ab9d8f71635547392b1d0ef0e2d4c6b8aa9c8
@104857600 424c4b64000000640c800000eeeeeeeef71635547392b1d0ef0e2d4c6b8aa9c8   ← 块100头（blockIdx=0x64=100）
@209715168 d6f51433527190afceed0c2b4a6988a7c6e504234261809fbeddfc1b3a597897   ← 尾部 32 字节
```

**回答 captain 的三个问题：**
1. **能**被正常消费，且**逐字节正确**：25 块拼出的 blob 经 `downloads.download` 落盘后 sha256 与 Node 端独立重算完全相同，头/中/尾切片也逐字节相同。
2. 与一次性 `new Blob([全量])` **行为一致**（同样 complete、同样 209715200 字节、同样 sha256）。差异只在组装成本：增量循环 427 ms + `new Blob(chunks)` **1.2 ms**，一次性 `new Blob([buffer])` 92.7 ms（因为它要把 200 MB 拷一遍）；且增量路径不必先持有一整块 200 MB 的 `Uint8Array`。**功能上没有额外的失败点**。
3. `new Blob(chunks)` 之后**清空/置 null `chunks` 完全不影响下载**（实测 dropped=true 仍 complete、仍逐字节正确）→ **可以提前释放引用**，Blob 已经持有自己的数据。
   （`performance.memory` 原始记录：增量 26.3 MB vs 一次性 211.8 MB used heap —— **仅供记录，内存结论归另一位实验员**。）

### 9.4 blob URL 生命周期（200 MB 飞行中，`results-phaseE.json`）

```
E2a close mid-flight:
  onCreated id=1 12:02:17.428Z fileSize=209715200
  onChanged id=1 12:02:17.435Z {"filename":"/…/e2a-close-midflight.bin"}
  （12:02:17.427+6ms downloads.download 返回；+13ms closeDocument 返回）
  onChanged id=1 12:02:19.274Z {"state":"complete"}     ← 传输 1.85 s，跨过了 close
  磁盘 209715200 字节；sha256 64c09889a179ab40624663dffadf3e361ea3e5d3aab61c03a782775f69b5925f ✅
E2b revoke mid-flight:
  onCreated id=2 12:02:19.320Z fileSize=209715200
  onChanged id=2 12:02:19.324Z {"filename":"/…/e2b-revoke-midflight.bin"}
  （+6ms downloads.download 返回；+10ms revokeObjectURL 返回）
  onChanged id=2 12:02:20.800Z {"state":"complete"}     ← 传输 1.48 s，跨过了 revoke
  磁盘 209715200 字节；sha256 同上 ✅
```

### 9.5 OPFS 能力（`results-full.json` / `results-phaseG.json`）

```
A4  sw  write 10MB  : {"ok":true,"size":10485760,"msTotal":2354.9,"estimate":{"quota":992494715095,"usage":10498263,"usageDetails":{"fileSystem":10485928}}}
A5  off write 10MB  : {"ok":true,"size":10485760,"written":10485760,"msOpen":2.7,"msTotal":80.4}
A11 sw  write 200MB : {"ok":true,"size":209715200,"msTotal":1552.4}
A12 off write 200MB : {"ok":true,"size":209715200,"msTotal":1327.1}
A6  sw  list        : [{"name":"sw-10mb.bin","size":10485760},{"name":"off-10mb.bin","size":10485760}]
A8  sw  reads off file : {"ok":true,"size":10485760,"headHex":"424c4b000000000000a00000eeeeeeeef71635547392b1d0ef0e2d4c6b8aa9c8","tailHex":"d6f51433527190afceed0c2b4a6988a7c6e504234261809fbeddfc1b3a597897"}
A9  off reads sw file  : {"ok":true,"size":10485760,"type":"application/octet-stream","headHex":"424c4b00…","tailHex":"d6f51433…"}
A10 off sha256(10MB)   : b9f90cd793d916e2b910b381289d51d9dcaf11337ded7ba8f95ea14a07a85fab  == Node 期望 ✅
G1  sw  positional writes : {"typeofSeek":"function","positionalWrite":"ok","seekWrite":"ok","thirdWrite":"ok","size":17825792,
                             "readback":[{"at":0,"bytes":[17,17,17,17]},{"at":8388608,"bytes":[51,51,51,51]},{"at":16777216,"bytes":[34,34,34,34]}]}
G2  off positional writes : 与 G1 完全相同
F1  sw  createSyncAccessHandle : {"ok":false,"errMessage":"createSyncAccessHandle is undefined"}
F2  off createSyncAccessHandle : {"undefined"}，typeofCreateWritable "function"
```

### 9.6 磁盘水位（`runx.sh` / driver 内置 `df`）

```
=== df -h /tmp BEFORE ===   overlay 1007G 25G 931G 3%
[df] start: /tmp free = 992.73 GB
[df] after:A11_sw_writes_big:       992.26 GB
[df] after:A12_offscreen_writes_big: 992.05 GB
[df] after:A13_cleanup_big_opfs:    992.47 GB
[df] after:D1_incremental_8MB_chunks: 1000.79 GB   ← 每个大档测完立即删
[df] after:D2_oneshot_blob:           1001.00 GB
[df] after:D3_incremental_chunks_dropped: 1000.79 GB
[df] after:D4_opfs_backed:            1001.00 GB
=== df -h /tmp AFTER ===    overlay 1007G 24G 933G 3%
```

（`statfs` 的 `bavail` 与 `df -h` 口径略有差异，趋势一致：**实验全程未对磁盘造成压力**。）

---

## 10 追加必测：增量攒 blob（单列结论）

**可行，且是与一次性构造等价的一等公民。**

- `new Blob([...chunks])` 是唯一能增量攒的写法，实测**成立**：25 × 8 MB → 200 MB，`new Blob(chunks)` 本身只要 **1.2 ms**（它不复制数据，只是把 25 个已有 blob 串成一个新的复合 blob）。
- 内容**逐字节正确**（sha256 与 Node 独立重算一致，头/中/尾切片一致），与一次性 `new Blob([全量])` 的下载结果**完全一致**（同样 complete、同样 209715200 字节、同样 sha256）。
- **没有额外失败点**；唯一差别是一次性写法要先把 200 MB 整块放进 JS 堆并再拷一遍（92.7 ms），增量写法分块产生、组装近乎零成本。
- **`new Blob(chunks)` 之后可以立刻清空并置 null `chunks`**（`dropped=true` 实测仍完整下载、仍逐字节正确）→ **“必须先在内存里攒齐整份”这个前提可以被绕开**：进程只需同时持有单个分片，组装后即可释放分片引用。
- 配合 §5：分片本身也可以直接落在 OPFS（乱序按偏移写入），此时内存里只需要当前分片。

**对候选路线的意义**：`fetch 多路 Range → 分片 → OPFS/复合 Blob → getFile/new Blob → createObjectURL → SW downloads.download` 这条链，**每一环在 Chrome 148 上都有实测可行的写法**；唯一被平台禁掉的组合是“offscreen 直接调 downloads API”和“SW 自己造 blob URL”，而这两个禁掉点都只需把动作放到正确的一侧，不影响整体可行性。
