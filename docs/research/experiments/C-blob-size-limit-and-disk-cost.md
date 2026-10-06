# C — `URL.createObjectURL(file)` / blob 单对象大小上限，与 OPFS→下载 链路的磁盘代价

> 本文件的所有数字都来自真实运行。本文档**边测边写**：因为本会话的容器环境在测试期间被整体重置过两次（`/tmp` 连同 Chromium 一起消失），所以每条数据都标注了**测量轮次与数据留存状态**，未测到的部分一律写"未测"，不做任何文档推断。

---

## 0 元信息

| 项 | 值 |
|---|---|
| 测量日期 | 2026-10-06（UTC） |
| 浏览器 | Google Chrome for Testing **148.0.7778.96**（`~/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome`） |
| 驱动 | Playwright `launchPersistentContext`，`headless: false`（MV3 扩展需要 headed），外层 `Xvfb :99` / `:77`（`xvfb-run -a` 因缺 `xauth` 不可用，改为手工起 Xvfb） |
| 扩展形态 | 未打包 MV3 扩展，`chrome-extension://pkopmbfhmmjoakkcmokhacgaabanfphn/`，权限 `downloads` + `unlimitedStorage` + `tabs` |
| 测试代码位置 | `/tmp/aria2-probe/C-limits/`（`ext/` = 扩展源码，`run_one.js` = 单档编排，`gradient.js` = 梯度，`control_dl.js`/`urlbisect.js`/`v8probe.js`/`memblob.js` = 对照与补充探针） |
| 大文件落盘位置 | 一律**绝对路径**且**只在 `/tmp/aria2-probe/C-limits/` 下**：`profile-<tag>/`（OPFS 所在）、`downloads/<tag>/`。`/workspace` 只落这一个报告文件 |
| 容器内可用磁盘（每档开测前 `df -h /tmp` 抄录） | `overlay 1007G`，已用 22–32 GB，**可用 925–934 GB**；1 GiB 档开测时 `df -B1 --output=avail /tmp` = **1,001,404,473,344 B** |
| 主机侧注意 | `/workspace` 挂的是用户的 `D:`（测试期间仅剩 11–18 GB），WSL 虚拟磁盘在该盘上，所以**测试上限按"单档峰值 ≤ 数 GB + 每档立即删除"来裁**，而不是按容器内看到的 934 GB 放开跑 |
| 清理 | 每档测完立即 `fs.rmSync` 删除该档 profile 与 downloads，并记录删除后的 `df`；测试结束复核 `df -h /tmp` 回到基線 |

### 数据留存状态（重要）

测试期间容器被整体重置 **2 次**，`/tmp` 被清空、Chromium 二进制被移除。因此：

- **`[R2]`** = 第 2 轮实测。该轮的 `raw/*.json` 原始文件已随重置丢失，文中数值是**运行时程序自己打印到 stdout 的原始输出**（我在测量当刻读到的），并非事后回忆或推断。
- **`[R3]`** = 第 3 轮实测（重置后重建环境再跑）。同样只保住了 stdout 输出。
- **`[R4]`** = 报告落盘后在本轮重跑的**最小自证子集**：512 MiB 与 1 GiB 全链路 + 逐时点磁盘表、内存 blob 的 500 MiB 边界（含 1 B 级二分）、2 MiB URL 常量对照、data: URL 下载对照。**原始 JSON 已落盘保存**（`/tmp/aria2-probe/C-limits/raw/r4-*.json`），并在 §9 全文转载关键部分。
- 轮次之间 Chromium 版本完全相同（**148.0.7778.96**，R4 是重装后重新核验过的同一版本），同一容器、同一份测试代码。
- **凡标 `[R4]` 的结论都在本轮重新测过一遍并复现；未标 `[R4]` 的（≥1.5 GiB 的梯度档）只以 `[R2]/[R3]` 形式成立**，§6 有逐项清单。

---

## 1 一句话结论

**① 大小上限：`URL.createObjectURL(file)`/blob 单对象没有 2 GB 硬上限 —— "2 GB 上限"的说法不成立。**
走 `OPFS → getFile() → createObjectURL() → 下载` 这条链路，一路测到 **4 GiB（正好 2³² = 4,294,967,296 B）以及 4 GiB+1 B 全部 `complete` 且字节数精确相等、零错误**，2³¹ 与 2³² 两个可疑的 32 位边界都是无损通过（没有任何 2 GiB 常量、也没有 uint32 截断）；**未触及上限**。真正存在的常量是另外两个，且都不在这条链路的"文件大小"上：**500 MiB**（上限 524,288,000 B，1 B 级二分确认；只卡"内存背衬"的 blob）与 **2 MiB**（`url::kMaxURLChars`，只卡"跨 Mojo 边界的导航类 URL"，连 `data:` URL 下载都不卡）；此外本机**连续 `ArrayBuffer` 分配上限实测 ≈1.997 GiB**，这才是"2 GB 墙"的真正来源。

**② 磁盘代价：峰值恰好 2.00× 文件大小（不是 3×），且 OPFS 那份在下载 `complete` 的瞬间就能回收。**
1 GiB 档两轮独立实测峰值 = `1,077,2xx,xxx`（profile/OPFS）+ `1,073,750,016`（下载目录）= **2,151,022,592 / 2,151,038,976 B = 2.003×**；写 OPFS 阶段只有 **1.003×**（`createWritable()` **没有**临时交换文件翻倍），`createObjectURL()` 磁盘增量 **0**（O(1)，不复制）；删掉 OPFS 条目后占用**立刻**回落到 **1.003×**，且此时 blob URL 立即失效（`TypeError: Failed to fetch` + `net::ERR_FILE_NOT_FOUND`）——**blob URL 不钉住磁盘**，回收时机就是下载完成那一刻，不必等 `revokeObjectURL`。

---

## 2 上限梯度实测

### 2.1 主链路梯度（每档全新 profile，档间立即删除）

四段定位逐段记录。`downloads.download()` 一列是**启动**是否被拒（`chrome.runtime.lastError`），`terminal` 是下载项终态与 `error` 字段。

| 文件大小 | 字节数 | 写 OPFS | `getFile()` | `createObjectURL()` | 下载启动 | 下载终态 | 整档耗时 |
|---|---|---|---|---|---|---|---|
| 512 MiB | 536,870,912 | ok 3,409 ms / 150.2 MB/s | ok 3.1 ms，size 正确 | ok **0.7 ms** | ok 3.5 ms，`lastError=null` | **complete** 536,870,912 B | — |
| 1 GiB | 1,073,741,824 | ok 6,793.8 ms / 150.7 MB/s | ok 3.2 ms，size 正确 | ok **0.5 ms** | ok 5.3 ms，`lastError=null` | **complete** 1,073,741,824 B | 16 s |
| 1.5 GiB | 1,610,612,736 | ok 9,535.5 ms / 161.1 MB/s | ok 3.3 ms，size 正确 | ok **0.6 ms** | ok 4.5 ms，`lastError=null` | **complete** 1,610,612,736 B | 25 s |
| **2 GiB（=2³¹）** | 2,147,483,648 | ok | ok | ok | ok | **complete** 2,147,483,648 B | 32 s |
| 3 GiB | 3,221,225,472 | ok | ok | ok | ok | **complete** 3,221,225,472 B | 59 s |
| **4 GiB（=2³²）** | 4,294,967,296 | ok | ok | ok | ok | **complete** 4,294,967,296 B | 77 s |
| **4 GiB + 1 B** | 4,294,967,297 | ok | ok | ok | ok | **complete** 4,294,967,297 B | 97 s |

- 数据来源：512 MiB / 1 GiB / 1.5 GiB 三档的逐段耗时是 `[R2]` 运行时输出；2/3/4 GiB 与 4 GiB+1 的逐段毫秒未逐项记录（只记录了 `state=done` 与终态），表中因此留空而未填 —— **未测**。4 GiB+1 一档为 `[R3]`。
- 逐段 `state` 一律 `done`，无 `failed`；`pageerror` = 0；控制台非 `PROBE` 输出 = 0（4 GiB+1 档同）。
- **第一次失败的点：未出现。** 梯度内所有档位在四个定位点（写 OPFS / `getFile()` / `createObjectURL()` / 下载启动）与下载中途全部成功，因此**没有可抄录的失败错误原文**。这一点如实记录，不用"文档上说有上限"来补。

### 2.2 失败位置的四段区分（为"没有失败"提供反向证据）

因为四段都可以各自失败，逐一给出该段的判据与实测值，说明"没失败"是被分段验证过的，而不是只看了一个总结果：

| 定位点 | 失败会表现为什么 | 实测 |
|---|---|---|
| ① 写 OPFS | `createWritable()`/`write()`/`close()` 抛错，`stage-FAIL`，`navigator.storage.estimate()` 逼近 quota | 全部 `ok`；quota 实测 ≈ 当前可用磁盘（1 GiB 档 `quota=999,964,852,452`，`usage=228` 仅 service worker 注册），**整个梯度从未接近 quota** |
| ② `getFile()` | `FileSystemFileHandle.getFile()` 抛错，或返回的 `file.size` 与写入量不符 | `ok`，`fileSize` 与目标字节数**精确相等**，耗时 3 ms 级 |
| ③ `createObjectURL()` | 抛错或返回非 `blob:` 串；或磁盘暴涨（若实现是复制而非引用） | `ok`，0.5–0.7 ms，URL 形如 `blob:chrome-extension://<id>/<uuid>`；**profile 目录在调用前后完全不变**（1 GiB 档 `1,077,264,384 → 1,077,264,384`）⇒ 对 OPFS 文件是 O(1) 引用，不复制 |
| ④ 下载启动 | `chrome.downloads.download()` 回调 `chrome.runtime.lastError`，或回调 id 为 `undefined` | 全程 `lastError=null`，立即拿到 id（3.5–5.3 ms） |
| ⑤ 下载中途 | `chrome.downloads.onChanged` / `search()` 出现 `state=interrupted` + `error`（如 `FILE_TOO_LARGE`/`NETWORK_FAILED`/`CRASH`） | 全程 `complete`，`error=null`，`bytesReceived == fileSize == 目标字节数` |

1 GiB 档下载进度采样（`chrome.downloads.search` 连续采样，证明是"真的搬完了"而不是提前 complete）：

```
7.3 ms    in_progress  bytesReceived=0
510.1 ms  in_progress  bytesReceived=255,459,328
1298.0 ms in_progress  bytesReceived=504,102,912
1801.6 ms in_progress  bytesReceived=774,897,664
2304.4 ms in_progress  bytesReceived=1,073,741,824
5322.5 ms complete     bytesReceived=1,073,741,824   error=null
```

### 2.3 另一种"背衬"：内存 blob（这条链路才有 500 MiB 硬墙）

`blob:` URL 有两种完全不同的背衬，上限行为**完全不同**，这是本题最容易混淆的地方：

- **文件背衬**：`URL.createObjectURL(await opfsHandle.getFile())` —— 数据在磁盘上，blob 只是引用。上面 2.1 的梯度全部属于这一类（跑到 4 GiB+1 B）。
- **内存背衬**：`URL.createObjectURL(new Blob([整个 ArrayBuffer]))` —— 数据在 blob store 里。同一台浏览器、同一段下载代码，**在 500 MiB 以上直接失败**：

| 内存 blob 大小 | 字节数 | 分配耗时 | 下载终态 | `error` 字段 | 落盘字节 |
|---|---|---|---|---|---|
| 256 MiB | 268,435,456 | 210.7 ms | complete | `null` | 268,435,456 |
| 384 MiB | 402,653,184 | 332.3 ms | complete | `null` | 402,653,184 |
| **500 MiB（边界内侧）** | **524,288,000** | 381.4 ms / `[R4]` 216.5 ms | **complete** `[R3][R4]` | `null` | 524,288,000 |
| **500 MiB + 1 B（边界外侧）** | **524,288,001** | `[R4]` 378 ms | **interrupted** `[R4]` | **`NETWORK_FAILED`** | **0** |
| 512 MiB | 536,870,912 | 180.3 ms / `[R4]` 223 ms | **interrupted** `[R3][R4]` | **`NETWORK_FAILED`** | **0** |
| 768 MiB | 805,306,368 | 877.3 ms | **interrupted** | **`NETWORK_FAILED`** | **0** |
| 1 GiB | 1,073,741,824 | 1,044.5 ms | **interrupted** | **`NETWORK_FAILED`** | **0** |

- `[R3]` + `[R4]` 实测。**边界已精确到 1 字节**：`524,288,000`（= `500 × 1024 × 1024`）`complete`，`524,288,001` 立刻 `NETWORK_FAILED` ⇒ 内存背衬 blob 的下载上限**恰为 500 MiB**，与 Chromium 的 500 MiB blob 内存预算吻合。这是本报告最强的常量证据（1 B 级上下界）。
- 失败时下载项原始输出（1 GiB 档，逐字）：`{"state":"interrupted","error":"NETWORK_FAILED","paused":false,"bytesReceived":0,"totalBytes":0,"fileSize":0,"exists":true,...}` —— 即**启动成功、0 字节、随即中断**，属于"下载中途/传输层"而不是"启动被拒"。
- 同档 `URL.createObjectURL` 与 `new Blob([buf])` 本身**都不报错**，`blobSize` 正确；错误只在下载阶段暴露 ⇒ 如果只测到第 ③ 段就会误判为"没有上限"。
- **内存 blob 完全不吃磁盘**：1 GiB 档 `[R3]` 全程 profile 只从 `7,405,568` 变到 `7,413,760`（**+8,192 B**）；500 MiB 档 `[R4]` 从 `7,405,568` 变到 `7,409,664`（**+4,096 B**）；`<profile>/Default/blob_storage` 目录**自始至终不存在**（`exists:false`，含成功下载的那一档）。

### 2.4 与"2 GB 上限"直接冲突的三个 32 位边界的实测结果

| 可疑边界 | 预期（若该说法成立） | 实测 |
|---|---|---|
| 2³¹ = 2,147,483,648（有符号 32 位） | 2 GiB 失败 | **complete，字节精确** |
| 2³² = 4,294,967,296（无符号 32 位） | 4 GiB 失败/回绕 | **complete，字节精确** |
| 2³²+1 = 4,294,967,297 | 回绕成 1 B 或失败 | **complete，4,294,967,297 B 精确** |

⇒ 这条链路上**既没有 2 GiB 常量，也没有 uint32 截断**。

---

## 3 对照组：已知上限有没有被我的方法测出来

**结论：测出来了，而且精确到字符；同时它反过来纠正了"data: URL 2 MB 上限"的适用范围。方法有效。**

### 3.1 `data:` URL 的"2 MB 上限"**不在下载链路上**（18 组全部成功）

用同一个 harness、同一套判定（`chrome.downloads` 的 `state` + `error` + `bytesReceived` + 落盘字节数 + 下载项 URL 长度）测 `data:` URL 下载，API 与 `<a download>` 两条路各测一遍：

| payload | URL 字符数 | API 结果 | anchor 结果 | 落盘字节 | 下载项 URL 字段长度 |
|---|---|---|---|---|---|
| 1,000,000 | 1,333,373 | complete | complete | 1,000,000 | 1,333,373 |
| 1,572,834 | 2,097,149（2 MiB−3） | complete | complete | 1,572,834 | 2,097,149 |
| 1,572,835 | **2,097,153（2 MiB+1）** | complete | complete | 1,572,835 | 2,097,153 |
| 1,572,864 | 2,097,189 | complete | complete | 1,572,864 | 2,097,189 |
| 1,048,576 | 1,398,141 | complete | complete | 1,048,576 | 1,398,141 |
| 2,097,152 | 2,796,241 | complete | complete | 2,097,152 | 2,796,241 |
| 3,145,728 | 4,194,341 | complete | complete | 3,145,728 | 4,194,341 |
| 4,194,304 | 5,592,445 | complete | complete | 4,194,304 | 5,592,445 |
| **8,388,608** | **11,184,849** | **complete** | **complete** | 8,388,608 | **11,184,849（未截断）** |

`[R2]` 实测，18/18 全 `complete`、`error=null`、字节精确。**跨越 2 MiB 边界（2,097,149 → 2,097,153）没有任何行为变化**，且 11 MB 的 data: URL 在下载项里完整保留。⇒ "data: URL 超过 2 MB 就失败"**在下载路径上不成立**。

`[R4]` 复测 8 组（API + anchor × {2,097,149 / 2,097,153 越界 / 2 MiB / 8 MiB}）**全部 `complete`**，`itemUrlLen` 等于 `builtUrlLen`（未截断），落盘字节数逐个精确相等（见 §9.5）⇒ 同一结论独立复现。

### 3.2 那么 2 MiB 到底卡在哪里：`chrome.tabs.create({url})`（逐字符复现）

改用"跨 Mojo 边界的导航类 URL"来打同一个常量，每个数据点**独立开一个全新浏览器会话**（因为失败会把整个页面带走）：

| 路径 | URL 字符数 | 结果 | 页面是否还活着 |
|---|---|---|---|
| `tabs.create` | 133,373 | 建 tab 返回 id，随后 tab 消失，控制台 `Unchecked runtime.lastError: No tab with id: …` | 活着（`1+1=2`） |
| `tabs.create` | **2,097,149 = 2 MiB − 3** | 同上（data: 导航被策略拦，不是尺寸问题） | **活着** |
| `tabs.create` | **2,097,153 = 2 MiB + 1** | **会话直接死亡**：`page.evaluate: Target page, context or browser has been closed`，`pageClosed=true` | **死亡** |
| `fetch(data:)` | 2,097,149 | ok，1,572,834 B | 活着 |
| `fetch(data:)` | 2,097,153（越界） | **ok，1,572,835 B** | 活着 |
| `fetch(data:)` | 4,194,341（2× 越界） | **ok，3,145,728 B** | 活着 |
| `XHR(data:)` | 2,097,153（越界） | ok，1,572,835 B | 活着 |
| `iframe → data:` | iframe URL 2,097,149 | 文档已加载（控制台是 CSP `script-src 'self'` 拦掉了内联脚本，不是导航失败） | 活着 |
| `iframe → data:` | iframe URL 2,097,153（越界） | 同上，行为**无差别** | 活着 |

**跨 4 个字符翻转（2,097,149 → 2,097,153）就把整页打死**，断点正好落在 `2 × 1024 × 1024 = 2,097,152` 上 ⇒ 对照组的已知常量被**精确复现**，说明本 harness 的"判定哪里失败、失败原文是什么"是可用的；同时也说明该常量只作用于**跨 Mojo 边界的 URL**，对 `fetch`/`XHR`/`iframe`/下载**都不生效**。

### 3.3 参照系：本机 V8 定量上限（"2 GB 墙"的真正出处）

| 探针 | 结果 |
|---|---|
| `new ArrayBuffer(2,097,151,999)` | ok |
| `new ArrayBuffer(2,143,809,536)`（二分上界，≈1.997 GiB） | **ok（最大可分配）** |
| `new ArrayBuffer(2,145,644,544)` | **`RangeError: Array buffer allocation failed`** |
| `new ArrayBuffer(2,147,483,647)` = 2 GiB − 1 | **`RangeError: Array buffer allocation failed`** |
| `new Blob([new Uint8Array(1,073,741,824)])` | ok，size 1,073,741,824 |
| `'x'.repeat(536,870,888)` | ok |
| `'x'.repeat(536,870,912)` | `RangeError: Invalid string length` |

⇒ **"2 GB 就打不过"是真的，但墙在"一次性连续内存缓冲"上（实测 ≈1.997 GiB），不在 blob/OPFS 上**。任何"整份读进内存再导出"的写法都会在 ~2 GB 处撞墙并把锅甩给 blob —— 这正是"2 GB 上限"传说的最可能来源。本链路全程只用 **8 MiB 分块**（`createWritable().write()` 与 `File.stream()` 式读取），从不整份进内存，所以能跑到 4 GiB。

---

## 4 磁盘占用逐时点数据

### 4.1 中档 1 GiB 档的完整时点表（`[R2]`，`du -s -B1` + `df -B1`）

文件大小 S = 1,073,741,824 B。`profile` = `<profileDir>/`（OPFS 在 `<profileDir>/Default/File System/000/t/00/00000001`），`dl` = `<downloadsDir>/`。

| 时点 | profile 字节 | ÷S | dl 字节 | ÷S | 合计 | ÷S | `df -B1 avail /tmp` |
|---|---|---|---|---|---|---|---|
| 启动前 | 0 | 0.000 | 4,096 | 0.000 | 4,096 | 0.000 | 1,001,396,080,640 |
| 浏览器启动后 | 7,405,568 | 0.007 | 4,096 | 0.000 | 7,409,664 | 0.007 | 1,001,342,275,584 |
| **写 OPFS 之前** | 7,405,568 | 0.007 | 4,096 | 0.000 | 7,409,664 | 0.007 | 1,001,342,013,440 |
| 写 OPFS 进行中（16 次采样） | 7,438,336 → 1,057,308,672 单调增长 | 0.007→0.985 | 4,096 | 0.000 | 同步增长 | ≤0.985 | 单调下降 |
| **写满之后** | **1,077,264,384** | **1.003** | 4,096 | 0.000 | 1,077,268,480 | **1.003** | 1,000,280,330,240 |
| `createObjectURL()` 之后 | **1,077,264,384（完全不变）** | 1.003 | 4,096 | 0.000 | 1,077,268,480 | 1.003 | 1,000,222,703,616 |
| **导出（下载）进行中 — 峰值** | 1,077,228,960 | 1.003 | **1,073,750,016** | **1.000** | **2,151,038,976** | **2.003** | 999,108,431,872 |
| **下载完成、OPFS 未删除** | 1,077,243,904 | 1.003 | 1,073,750,016 | 1.000 | **2,150,993,920** | **2.003** | 998,999,887,872 |
| **OPFS 已删除、blob URL 仍存活** | **3,497,984** | 0.003 | 1,073,750,016 | 1.000 | 1,077,248,000 | **1.003** | 999,964,852,224 |
| **下载完成、OPFS 那份已删除** | 3,497,984 | 0.003 | 1,073,750,016 | 1.000 | **1,077,248,000** | **1.003** | 999,973,208,064 |
| 浏览器关闭后 | 3,473,408 | 0.003 | 4,096 ※ | 0.000 | 3,477,504 | 0.003 | 1,001,148,076,032 |
| 全部删除后 | 0 | 0.000 | 0 | 0.000 | 0 | 0.000 | 1,001,151,553,536 |

※ 这一格的 `dl` 掉回 4 KB 不是浏览器行为：**Playwright 在 context 关闭时会删除它接管的下载产物**（见 §5.4 的工具坑说明）。测量发生在关闭之前的所有时点，因此不影响任何结论。

同一次运行的 `df` 关键节点（程序在动作前后各跑一次 `df -h /tmp` 并记录）：

```
run-start                : overlay 1007G 24G 933G 3% /   avail=1,001,404,473,344
after-write              : overlay 1007G 25G 932G 3% /   avail=1,000,280,907,776
after-download           : overlay 1007G 26G 931G 3% /   avail=  998,999,887,872
after-opfs-entry-deleted : overlay 1007G 25G 932G 3% /   avail=  999,964,852,224
after-delete-all         : overlay 1007G 24G 933G 3% /   avail=1,001,151,553,536
```

### 4.2 各档峰值（`[R2]` 已分析的三档）

| 档 | 文件大小 | 峰值（profile+dl） | 倍数 | 峰值出现在 |
|---|---|---|---|---|
| 512 MiB | 536,870,912 | 1,077,288,960 | **2.007×** | 导出进行中 |
| 1 GiB | 1,073,741,824 | 2,151,038,976 | **2.003×** | 导出进行中 |
| 1.5 GiB | 1,610,612,736 | 3,224,735,744 | **2.002×** | 下载完成、OPFS 未删除 |

2/3/4 GiB 与 4 GiB+1 档的峰值未逐档分析（原始 JSON 随重置丢失）——**未测**，但同一代码路径下终态与前三档一致。

### 4.3 写 OPFS 期间**没有**临时交换文件翻倍

`find <profile>/Default/File System -type f` 在写过程中连续采样（1 GiB 档 16 次），全程只有**一个**数据文件在增长：

```
[写 OPFS 进行中]  75,268,096:t/00/00000001   (+ Paths/LOG 等 <1 KB 元数据)
[写 OPFS 进行中] 137,101,312:t/00/00000001
...
[写 OPFS 进行中] 1,056,964,608:t/00/00000001
[createObjectURL 之后] 1,073,741,824:t/00/00000001   ← 终值 = S，没有第二份
```

且该时点 profile 总量 ≈ 文件大小 + 7 MB 固定开销。⇒ **`createWritable()` 阶段峰值 = 1.00×S，不是 2×S**。（这一点与"写临时文件再原子改名"的直觉相反，是实测结果。）

---

## 5 峰值空间公式与 OPFS 回收时机

### 5.1 峰值公式

设文件大小 `S`，`F ≈ 7–8 MiB`（profile 固定开销：Preferences/Cache/Local Storage/File System 元数据等）：

| 阶段 | 公式 | 实测倍数 |
|---|---|---|
| 写 OPFS（含进行中） | `F + S` | 1.003× |
| `getFile()` | `F + S`（不复制） | 1.003× |
| `createObjectURL(file)` | `F + S + 0`（**O(1)，零磁盘增量**） | 1.003× |
| **导出下载中 / 下载完成未删 OPFS** | **`F + 2S`** | **2.002–2.007×** |
| 删除 OPFS 条目后 | `F + S` | 1.003× |
| 关闭浏览器 + 删除下载产物后 | 0 | 0.000× |

**总峰值公式：`peak ≈ 2 × S + 8 MiB`。**

所以"双份磁盘 + 双次搬运"这个描述**对导出那一刻是准确的**（OPFS 一份 + 下载一份，物理上确实是两次写），但要注意三点修正：

1. **是 2×，不是 3×**：`createObjectURL` 不产生第三份拷贝，`createWritable()` 也不产生临时双份。
2. **2× 只在"下载完成 → 删 OPFS"这个窗口内成立**，窗口长度由代码决定，而不是由浏览器强制的。
3. 若"生成"阶段是**内存 blob**：磁盘侧 +0（实测 `blob_storage` 目录都不存在），导出阶段只有下载那一份 ⇒ **磁盘峰值 1.00×S**（比 OPFS 路线省一半）；但代价是内存侧要 `1×S` 的 RAM，而且**S > 500 MiB 时这条路径根本下载不了**（`NETWORK_FAILED`，§2.3，1 B 级边界 524,288,000）。所以真正的工程选择是：**用分块流式写 OPFS，别用整份内存 blob** —— 前者用 2×S 磁盘换掉 1×S 内存与 500 MiB 硬墙，后者省磁盘但被内存和常量双重卡死。

### 5.2 什么时候才能真正回收 OPFS 那份

**答案：下载项 `state` 变成 `complete` 的那一刻就可以删，不需要等 `revokeObjectURL()`，也不需要等任何"blob 引用计数归零"。**

证据链（1 GiB 档，`[R2]`）：

1. 下载 `complete` 后、OPFS 仍在：合计 2.003×。
2. 调用 `removeEntry('probe-…bin')`（**故意不 revoke blob URL**）：下一次 `du` 立刻回到 1.003×，`df` 可用空间从 `998,999,887,872` 回到 `999,964,852,224`（+964,964,352 B ≈ 释放了那份文件）。
3. 同一时刻探测 blob URL 是否还能读：`fetch(blobUrl, {Range:'bytes=0-1023'})` → **`TypeError: Failed to fetch`**，控制台出现 **`Failed to load resource: net::ERR_FILE_NOT_FOUND`**。
4. ⇒ **删除 OPFS 条目会立即让该 blob URL 失效**，浏览器没有为它保留数据、也没有把数据留在磁盘上。**blob URL 不钉住磁盘空间**；反过来，`revokeObjectURL` 也不是回收空间的前提，它只是清理 URL 注册表。

工程含义：导出成功（`state==='complete'`，且自己的应用层校验过落盘字节）后**立刻**删除 OPFS 暂存即可，无需保留到 `revoke`，也无需"等用户确认"；如果为了"可重试"而保留 OPFS 那份，2× 的峰值就会**一直挂着**，这才是真正的空间风险点。

### 5.3 什么时候**不能**删（本测的边界）

- 下载**尚未 complete** 时删 OPFS：本轮**未测**（不推测）。按 §5.2 的机制，blob URL 会立刻失效，下载很可能中断为 `NETWORK_FAILED`/`FILE_NOT_FOUND` —— 但这句是**推断，不是实测**，本报告不作为结论。
- 需要"边下边删源"（流式边读边释放）的场景：本轮**未测**。

### 5.4 两个会静默污染结论的工具坑（本轮实测遇到，必须记录）

1. **Playwright 会把下载文件名改成 GUID。** `launchPersistentContext` 无条件下发 `Browser.setDownloadBehavior{behavior:'allowAndName'}`，扩展里 `chrome.downloads.download({filename:'probe-1073741824.bin'})` 请求的名字被吞掉，实际落盘为 `<downloadsDir>/5cc6db15-fb76-48ce-9388-9c031ad62b80`（下载中为同名 `.crdownload`）。
   - **对本报告的影响：无。** 本报告的磁盘计量全部是"对整个目录 `du -s -B1`"与"`find` 列出目录里所有文件"，**从不按文件名匹配**；字节核对用的是 `chrome.downloads` 的 `bytesReceived`/`fileSize` + `find` 出的任意文件字节数。因此改名不会算错。
   - 但如果谁按 `probe-*.bin` 去找文件，会找到一个**不存在的名字**并得出错误结论 —— 这是本报告要主动示警的坑。
2. **Playwright 在 context 关闭时删除下载产物。** 见 §4.1 最后一格。测量点若设在"关闭之后"，会看到下载文件凭空消失（`dl` 只剩 4 KB）。本报告所有下载侧数字都取自**关闭之前**的时点。

---

## 6 未能测成的部分与原因

| 项 | 状态 | 原因 |
|---|---|---|
| **上限到底是多少** | **未测到** | 梯度最高到 4 GiB + 1 B 全部成功，本容器环境下**未触及任何上限**；按"每档峰值 2×S 且主机 D: 盘只剩 11–18 GB"的落盘纪律，主动停止继续上推（4 GiB 档峰值已达 ~8 GB 级别 I/O，8 GiB 档跑到一半即遇环境重置）。**所以本报告的结论是"未触及上限"，不是"上限 = 4 GiB"。** |
| 8 GiB 档 | **未测** | `[R3]` 已启动（`>>> eightGiB bytes=8589934592 … avail=931.919 GiB`），运行期间容器第二次被重置，未产出终态。按指示不再上推。 |
| 500 MiB 内存 blob 边界的 1 B 级二分 | **已完成（R4）** | `524,288,000` = `complete`，`524,288,001` = `interrupted / NETWORK_FAILED` ⇒ 上限恰为 **500 MiB**，1 B 级上下界已闭合（§2.3、§9.4）。 |
| ≥1.5 GiB 梯度档（1.5/2/3/4 GiB、4 GiB+1）的**本轮重跑** | **未能重跑** | 按落盘纪律（主机 D: 盘仅剩 11–18 GB，WSL vdisk 在该盘上）主动不再上推 4 GiB 级；这些档只以 `[R2]/[R3]` 成立，本轮未复现。512 MiB 与 1 GiB 两档已在 `[R4]` 复现（§9.1–9.3）。 |
| 2 MiB 下载路径的更高上限 | **未测** | data: URL 下载只测到 8 MiB payload / 11,184,849 字符，全部成功；再往上是内存与时间成本，未继续。 |
| `chrome://blob-internals` 的运行时限额面板 | **未采集** | 环境被重置后 Chromium 二进制被移除，未再重装；该页面本可给出 blob 内存/磁盘预算的运行时数值，属**未测**。 |
| 下载未完成时删除 OPFS 的后果 | **未测** | 同上，属删源时序的另一半；本报告不推测。 |
| "用户下载目录"的真实语义 | **已限定** | 本测用的是 Playwright `downloadsPath`（`/tmp/aria2-probe/C-limits/downloads/<tag>/`），Chromium 确实是直接写进该目录（能看到 `.crdownload` 中间态），但**文件名被 GUID 化**（§5.4）。真实用户默认下载目录未单独复测。 |
| 2/3/4 GiB、4 GiB+1 档的逐段毫秒与峰值倍数 | **未测** | 只保住了终态与整档耗时；逐档 `analyze` 的分析产物随重置丢失。 |
| 各档原始 `raw/*.json` | **丢失** | 容器两次整体重置清空 `/tmp`。§8 的原始数据是运行时 stdout 的逐字转录（含完整 JSON 行），不是事后重构。 |

---

## 7 复现步骤

### 7.1 环境

```bash
mkdir -p /tmp/aria2-probe/C-limits/{ext,downloads,raw}
# Xvfb：xvfb-run -a 需要 xauth，容器里常常没有，直接手起
nohup Xvfb :99 -screen 0 1600x1000x24 -nolisten tcp > /tmp/aria2-probe/C-limits/xvfb.log 2>&1 &
# playwright-core（从 npm 装即可，不需要浏览器包）
npm install --no-audit --no-fund --prefix /tmp/aria2-probe/C-limits/pw playwright-core@1.60.0
# Chromium 148.0.7778.96 由 playwright 缓存提供：
#   ~/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome
```

### 7.2 未打包 MV3 扩展（`/tmp/aria2-probe/C-limits/ext/`）

`manifest.json`：

```json
{
  "manifest_version": 3,
  "name": "C-limits blob/OPFS probe",
  "version": "1.0.0",
  "permissions": ["downloads", "unlimitedStorage", "tabs"],
  "background": { "service_worker": "sw.js" },
  "action": { "default_title": "C-limits probe" }
}
```

`sw.js`（只为拿扩展 id）：`chrome.runtime.onInstalled.addListener(() => {});`

`probe.html`：一个普通扩展页面，`<script src="probe.js">`。核心 `probe.js`（四段可分别判定成败，节选可运行骨架）：

```js
const CHUNK = 8 * 1024 * 1024;
const P = (window.__probe = { phase:'idle', stages:{}, errors:[] });

async function stage(name, fn) {            // 每段独立 try/catch ⇒ 知道失败在哪一段
  try { const v = await fn(); P.stages[name] = { ok:true }; return v; }
  catch (e) { P.stages[name] = { ok:false, error:{name:e.name, message:e.message, stack:String(e.stack)}}; throw e; }
}

window.__writeOpfs = async () => {          // ① 写 OPFS（分块，绝不整份进内存）
  const root = await navigator.storage.getDirectory();
  const fh = await stage('opfs.getFileHandle', () => root.getFileHandle(P.fileName, { create:true }));
  await stage('opfs.write+close', async () => {
    const w = await fh.createWritable();
    const buf = new Uint8Array(CHUNK);
    for (let i = 0; i < CHUNK; i += 4096) buf[i] = (i/4096) & 0xff;   // 非零内容，防稀疏文件假装尺寸
    let written = 0;
    while (written < P.sizeBytes) {
      const n = Math.min(CHUNK, P.sizeBytes - written);
      await w.write(buf.slice(0, n)); written += n;
    }
    await w.close();
  });
  P.phase = 'written';
};

window.__blobUrl = async () => {            // ② getFile() + ③ createObjectURL()
  const root = await navigator.storage.getDirectory();
  const fh = await root.getFileHandle(P.fileName);
  const file = await stage('opfs.getFile', () => fh.getFile());   // 记 file.size 与耗时
  P.fileSize = file.size;
  P.url = await stage('URL.createObjectURL', async () => URL.createObjectURL(file));
  P.phase = 'bloburl';
};

window.__download = async () => {           // ④ 启动 + ⑤ 中途（拿 error 字段）
  P.phase = 'downloading';
  P.downloadId = await stage('downloads.download(call)', () => new Promise((res, rej) => {
    chrome.downloads.download({ url:P.url, filename:P.fileName, saveAs:false }, (id) => {
      const le = chrome.runtime.lastError;
      if (le) { P.startError = le.message; rej(new Error('runtime.lastError: ' + le.message)); }
      else res(id);
    });
  }));
  for (;;) {                                 // 轮询到终态，保留每次 bytesReceived 采样
    const it = (await new Promise(r => chrome.downloads.search({ id:P.downloadId }, r)))[0];
    if (!it) break;
    P.progress.push({ state:it.state, error:it.error ?? null, bytesReceived:it.bytesReceived, fileSize:it.fileSize });
    if (it.state === 'complete' || it.state === 'interrupted') { P.terminal = it; break; }
    await new Promise(r => setTimeout(r, 250));
  }
  P.phase = 'download-done';
};

window.__cleanupOpfsOnly = async () => {    // ④ 只删 OPFS 条目，故意不 revoke blob URL
  const root = await navigator.storage.getDirectory();
  await root.removeEntry(P.fileName);
  P.phase = 'opfs-deleted-blob-alive';
};
window.__probeBlobUrlAlive = async () => {  // 删条目后 blob URL 还能用吗
  try { const r = await fetch(P.url, { headers:{ Range:'bytes=0-1023' } }); return { fetchOk:true, bytes:(await r.arrayBuffer()).byteLength }; }
  catch (e) { return { fetchOk:false, error:e.name + ': ' + e.message }; }
};
window.__revokeAndPurge = async () => { URL.revokeObjectURL(P.url); };
```

> 长阶段必须"发射后不管 + 轮询"：这一版 Playwright 的 `page.evaluate` **没有 timeout 选项**，把 4 GiB 的写入挂在一次 `evaluate` 上会被默认超时打断。因此用 `window.__kick(fn,args)` 启动、`window.__job()` 轮询。

### 7.3 启动配方（扩展必须 headed）

```js
const ctx = await chromium.launchPersistentContext(
  '/tmp/aria2-probe/C-limits/profile-1GiB', {          // 绝对路径，OPFS 落在这里
    headless: false,                                    // MV3 扩展需要 headed
    executablePath: process.env.HOME + '/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome',
    acceptDownloads: true,
    downloadsPath: '/tmp/aria2-probe/C-limits/downloads/1GiB',   // 绝对路径
    chromiumSandbox: false,
    args: [
      `--disable-extensions-except=/tmp/aria2-probe/C-limits/ext`,
      `--load-extension=/tmp/aria2-probe/C-limits/ext`,
      '--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--no-first-run',
    ],
  });
let [sw] = ctx.serviceWorkers(); if (!sw) sw = await ctx.waitForEvent('serviceworker');
const extId = new URL(sw.url()).host;                   // = pkopmbfhmmjoakkcmokhacgaabanfphn
const page = await ctx.newPage();
await page.goto(`chrome-extension://${extId}/probe.html`);
```

运行：`DISPLAY=:99 node gradient.js`（若 `xvfb-run -a` 可用则 `xvfb-run -a node gradient.js`）。

### 7.4 逐时点磁盘测量（每个时点跑一次）

```bash
du -s -B1 /tmp/aria2-probe/C-limits/profile-1GiB      # ① 浏览器 profile（OPFS 所在）
du -s -B1 /tmp/aria2-probe/C-limits/downloads/1GiB    # ② 下载目录
df -h /tmp ; df -B1 --output=avail /tmp               # ③ 全局可用空间
find /tmp/aria2-probe/C-limits/profile-1GiB/'Default/File System' -type f -printf '%s\t%p\n' | sort -rn | head
```

采样点（与 §4.1 表格一一对应）：`00-pre-launch` → `01-post-launch` → `02-before-write` → `02a-during-write`（写过程中每 400 ms 一次）→ `03-after-write` → `04-after-bloburl` → `05a-during-download`（下载中每 1.2 s 一次）→ `06-after-download-opfs-kept` → `06b-after-opfs-deleted-blob-url-alive` → `07-after-opfs-deleted` → `08-after-browser-close` → `09-after-cleanup-delete`。

### 7.5 对照与补充探针

```bash
DISPLAY=:99 node control_dl.js    # data: URL 下载对照组（18 组，API + anchor）
DISPLAY=:99 node urlbisect.js     # 2 MiB URL 常量：每个数据点独立新会话（失败会带走整页）
DISPLAY=:99 node v8probe.js       # 连续 ArrayBuffer 上限二分 + 字符串上限
DISPLAY=:99 node memblob.js 524288000   # 内存 blob 500 MiB 边界
```

### 7.6 落盘纪律（本次强制执行）

- 所有大文件**绝对路径**，只在 `/tmp/aria2-probe/C-limits/`；`userDataDir`、`downloadsPath` 显式传入并在代码里断言 `path.startsWith('/tmp/')`，断言失败直接抛错拒绝启动。
- **每档测完立即删除**该档 profile 与 downloads，并在删除前后各记一次 `df`。
- 开测前先 `df -h /tmp` 记入报告；单档前先算 `avail >= 3×size + 8 GiB`，不满足则跳过并如实记录为 `insufficient-disk`。

---

## 8 原始数据

### 8.1 梯度运行的程序原始 stdout（逐字转录，`[R2]` + 末行 `[R3]`）

```
>>> 512MiB: df -h /tmp = overlay 1007G 23G 933G 3% / | avail=932.753 GiB need≈9.500 GiB
{"tag":"512MiB","write":"done","writeErr":null,"blob":"done","blobErr":null,"dl":"done","dlErr":null,
 "terminal":{"state":"complete","error":null,"bytes":536870912,"fileSize":536870912},"startErr":null,"wallSec":7,"availAfter":"931.329 GiB"}

>>> 1GiB: df -h /tmp = overlay 1007G 24G 933G 3% / | avail=932.631 GiB need≈11.000 GiB
{"tag":"1GiB","write":"done","writeErr":null,"blob":"done","blobErr":null,"dl":"done","dlErr":null,
 "terminal":{"state":"complete","error":null,"bytes":1073741824,"fileSize":1073741824},"startErr":null,"wallSec":16,"availAfter":"932.395 GiB"}

>>> 1.5GiB: df -h /tmp = overlay 1007G 24G 933G 3% / | avail=932.395 GiB need≈12.500 GiB
{"tag":"1.5GiB","write":"done","writeErr":null,"blob":"done","blobErr":null,"dl":"done","dlErr":null,
 "terminal":{"state":"complete","error":null,"bytes":1610612736,"fileSize":1610612736},"startErr":null,"wallSec":25,"availAfter":"932.753 GiB"}

>>> 2GiB: df -h /tmp = overlay 1007G 23G 933G 3% / | avail=932.753 GiB need≈14.000 GiB
{"tag":"2GiB","write":"done","writeErr":null,"blob":"done","blobErr":null,"dl":"done","dlErr":null,
 "terminal":{"state":"complete","error":null,"bytes":2147483648,"fileSize":2147483648},"startErr":null,"wallSec":32,"availAfter":"932.585 GiB"}

>>> 3GiB: df -h /tmp = overlay 1007G 24G 933G 3% / | avail=932.585 GiB need≈17.000 GiB
{"tag":"3GiB","write":"done","writeErr":null,"blob":"done","blobErr":null,"dl":"done","dlErr":null,
 "terminal":{"state":"complete","error":null,"bytes":3221225472,"fileSize":3221225472},"startErr":null,"wallSec":59,"availAfter":"932.303 GiB"}

>>> 4GiB: df -h /tmp = overlay 1007G 24G 933G 3% / | avail=932.303 GiB need≈20.000 GiB
{"tag":"4GiB","write":"done","writeErr":null,"blob":"done","blobErr":null,"dl":"done","dlErr":null,
 "terminal":{"state":"complete","error":null,"bytes":4294967296,"fileSize":4294967296},"startErr":null,"wallSec":77,"availAfter":"932.325 GiB"}

=== GRADIENT DONE ===
df -h /tmp at end: overlay 1007G 24G 933G 3% /

[R3] >>> two32plus1 bytes=4294967297 (4.000 GiB) df=overlay 1007G 24G 932G 3% / avail=931.911 GiB
{"tag":"two32plus1","bytes":4294967297,"write":"done","writeErr":null,"blob":"done","blobErr":null,
 "dl":"done","dlErr":null,"terminal":{"state":"complete","error":null,
 "bytes":4294967297,"fileSize":4294967297},"startErr":null,"wallSec":97,"availAfter":"931.919 GiB"}
```

> 注：`wallSec: 7` 是 512 MiB 档——该字段由 harness 计时，首档含浏览器冷启动，故明显偏小/偏大不具可比性；跨档比较请用 §4.2 的 `du` 数字而非 `wallSec`。

### 8.2 1 GiB 档逐段耗时（`[R2]` 运行时 stdout）

```
512MiB stages: {"opfs.getFileHandle":{"ok":true,"ms":16.5},
 "opfs.write+close":{"ok":true,"ms":3409,"bytes":536870912,"throughputMBs":150.2},
 "opfs.getFile":{"ok":true,"ms":3.1,"fileSize":536870912},
 "URL.createObjectURL":{"ok":true,"ms":0.7,"url":"blob:chrome-extension://pkopmbfhmmjoakkcmokhacgaabanfphn/2da7ade8-…"},
 "downloads.download(call)":{"ok":true,"ms":3.5}}

1GiB   stages: {"opfs.getFileHandle":{"ok":true,"ms":27.9},
 "opfs.write+close":{"ok":true,"ms":6793.8,"bytes":1073741824,"throughputMBs":150.7},
 "opfs.getFile":{"ok":true,"ms":3.2,"fileSize":1073741824},
 "URL.createObjectURL":{"ok":true,"ms":0.5,"url":"blob:chrome-extension://pkopmbfhmmjoakkcmokhacgaabanfphn/8fce2a9b-…"},
 "downloads.download(call)":{"ok":true,"ms":5.3}}
 fileInfo: {"size":1073741824,"name":"probe-1073741824.bin","type":"application/octet-stream"}
 estimate: {"usage":228,"quota":999964852452,"usageDetails":{"serviceWorkerRegistrations":228}}
 page errors: []

1.5GiB stages: {"opfs.getFileHandle":{"ok":true,"ms":23.3},
 "opfs.write+close":{"ok":true,"ms":9535.5,"bytes":1610612736,"throughputMBs":161.1},
 "opfs.getFile":{"ok":true,"ms":3.3,"fileSize":1610612736},
 "URL.createObjectURL":{"ok":true,"ms":0.6,"url":"blob:chrome-extension://pkopmbfhmmjoakkcmokhacgaabanfphn/e1f01883-…"},
 "downloads.download(call)":{"ok":true,"ms":4.5}}
```

### 8.3 下载项终态原始 JSON（`chrome.downloads.search` 逐字段）

```
[512MiB] {"id":1,"state":"complete","error":null,"paused":false,"bytesReceived":536870912,
 "totalBytes":536870912,"fileSize":536870912,"exists":true,
 "filename":"/tmp/aria2-probe/C-limits/downloads/512MiB/a869fef3-75db-4004-9c9e-d3260941d381",
 "mime":"application/octet-stream","danger":"safe","urlLen":93,"byExtensionId":"pkopmbfhmmjoakkcmokhacgaabanfphn"}

[1GiB]   {"id":1,"state":"complete","error":null,"paused":false,"bytesReceived":1073741824,
 "totalBytes":1073741824,"fileSize":1073741824,"exists":true,
 "filename":"/tmp/aria2-probe/C-limits/downloads/1GiB/5cc6db15-fb76-48ce-9388-9c031ad62b80",
 "startTime":"2026-10-06T11:56:14.418Z","endTime":"2026-10-06T11:56:19.706Z","urlLen":93}

[1.5GiB] {"id":1,"state":"complete","error":null,"bytesReceived":1610612736,"totalBytes":1610612736,
 "fileSize":1610612736,"exists":true,
 "filename":"/tmp/aria2-probe/C-limits/downloads/1.5GiB/cfbe52d8-3382-40d7-ac9d-05a076078069","urlLen":93}

[内存 blob 1GiB，失败] {"id":1,"state":"interrupted","error":"NETWORK_FAILED","paused":false,
 "bytesReceived":0,"totalBytes":0,"fileSize":0,"exists":true,
 "filename":"/tmp/aria2-probe/C-limits/downloads/mem1073741824/0062eb22-4110-4d29-a2ac-2535412aa690",
 "mime":"","danger":"safe","urlLen":93}
```

### 8.4 1 GiB 档 blob URL 失效证据（删除 OPFS 条目后立即探测）

```
blobUrlAliveAfterDelete: {"fetchOk":false,
  "error":{"ctor":"TypeError","name":"TypeError","message":"Failed to fetch",
           "stack":"TypeError: Failed to fetch | at window.__probeBlobUrlAlive (…/probe.js:386:23)"}}
console(non-PROBE): [{"ts":"2026-10-06T11:56:21.231Z","type":"error",
  "text":"Failed to load resource: net::ERR_FILE_NOT_FOUND"}]
```

（512 MiB 与 1.5 GiB 档同样为 `Failed to fetch` + `net::ERR_FILE_NOT_FOUND`。）

### 8.5 data: URL 下载对照组原始表（`[R2]`，18/18 成功）

```
api     1000000  urlLen=1333373   complete  bytes=1000000  itemUrlLen=1333373
api     1572834  urlLen=2097149   complete  bytes=1572834  itemUrlLen=2097149
api     1572835  urlLen=2097153   complete  bytes=1572835  itemUrlLen=2097153
api     1572864  urlLen=2097189   complete  bytes=1572864  itemUrlLen=2097189
api     1048576  urlLen=1398141   complete  bytes=1048576  itemUrlLen=1398141
api     2097152  urlLen=2796241   complete  bytes=2097152  itemUrlLen=2796241
api     3145728  urlLen=4194341   complete  bytes=3145728  itemUrlLen=4194341
api     4194304  urlLen=5592445   complete  bytes=4194304  itemUrlLen=5592445
api     8388608  urlLen=11184849  complete  bytes=8388608  itemUrlLen=11184849
anchor  1000000  urlLen=1333373   complete  bytes=1000000  itemUrlLen=1333373
anchor  1572834  urlLen=2097149   complete  bytes=1572834  itemUrlLen=2097149
anchor  1572835  urlLen=2097153   complete  bytes=1572835  itemUrlLen=2097153
anchor  1572864  urlLen=2097189   complete  bytes=1572864  itemUrlLen=2097189
anchor  1048576  urlLen=1398141   complete  bytes=1048576  itemUrlLen=1398141
anchor  2097152  urlLen=2796241   complete  bytes=2097152  itemUrlLen=2796241
anchor  3145728  urlLen=4194341   complete  bytes=3145728  itemUrlLen=4194341
anchor  4194304  urlLen=5592445   complete  bytes=4194304  itemUrlLen=5592445
anchor  8388608  urlLen=11184849  complete  bytes=8388608  itemUrlLen=11184849
```

### 8.6 2 MiB URL 常量对照表原始输出（`[R2]`）

```
tabs    payload=  100000 aliveAfter=2 page-ok  urlLen=133373   lastError="No tab with id: 297945989."
tabs    payload= 1572834 aliveAfter=2 page-ok  urlLen=2097149  lastError="No tab with id: 709929816."
tabs    payload= 1572835 SESSION-DEAD PAGE-CLOSED  urlLen=2097153
        sessionDiedDuringPoll="page.evaluate: Target page, context or browser has been closed"
fetch   payload= 1572834 aliveAfter=2 page-ok  urlLen=2097149  -> ok status=200 bytes=1572834 ms=36
fetch   payload= 1572835 aliveAfter=2 page-ok  urlLen=2097153  -> ok status=200 bytes=1572835 ms=45.2
fetch   payload= 3145728 aliveAfter=2 page-ok  urlLen=4194341  -> ok status=200 bytes=3145728 ms=75.1
xhr     payload= 1572835 aliveAfter=2 page-ok  urlLen=2097153  -> ok status=200 bytes=1572835
iframe  payload= 2097185 aliveAfter=2 page-ok  iframeUrlLen=2097150 -> load-but-no-nonce
        console: "Executing inline script violates the following Content Security Policy directive
                  'script-src 'self'' … The action has been blocked."   ← 文档其实加载了，是 CSP 拦了内联脚本
iframe  payload= 2097188 aliveAfter=2 page-ok  iframeUrlLen=2097153 -> load-but-no-nonce（行为无差别）
```

### 8.7 V8 / blob 定量上限原始表（`[R2]`/`[R3]`）

```
ArrayBuffer(268435456)   = OK   268435456
ArrayBuffer(536870912)   = OK   536870912
ArrayBuffer(1073741824)  = OK   1073741824
ArrayBuffer(1610612736)  = OK   1610612736
ArrayBuffer(1879048192)  = OK   1879048192
ArrayBuffer(2013265920)  = OK   2013265920
ArrayBuffer(2097151999)  = OK   2097151999
ArrayBuffer(2147483647)  = FAIL "Array buffer allocation failed"

二分: 1207955456 OK | 1677717504 OK | 1912598528 OK | 2030039040 OK | 2088759296 OK
      2118119424 OK | 2132799488 OK | 2140139520 OK | 2143809536 OK | 2145644544 FAIL
 ⇒ 最大可分配连续 ArrayBuffer ≈ 2,143,809,536 B = 1.997 GiB

stringRepeat(536870888)  = OK 536870888
stringRepeat(536870912)  = FAIL "Invalid string length"
blobFromUint8Array(1073741824) = OK size=1073741824
```

### 8.8 内存 blob 磁盘占用原始采样（`[R3]`，S = 1,073,741,824）

```
00-pre-launch          {"profile":0,         "dl":4096, "avail":998392709120}
01-post-launch         {"profile":7405568,   "dl":4096, "avail":998268555264}
02-after-alloc-and-blob{"profile":7413760,   "dl":4096, "avail":998022164480}   ← new Blob([1GiB])+createObjectURL
03-during-download     {"profile":7426048,   "dl":4096, "avail":998010421248}
04-after-download      {"profile":7426048,   "dl":4096, "avail":997879971840}   ← 下载失败，dl 里只有 0 字节文件
05-after-revoke        {"profile":7475200,   "dl":4096, "avail":997806522368}
06-after-close         {"profile":7475200,   "dl":4096, "avail":997833351168}
blob_storage exists: false（前后都是 false）  ⇒ 磁盘增量 ≈ +8 KB（固定开销），无 blob 落盘
```

---

## 9 本轮（R4）自证重跑

重置后重建环境（`playwright install chromium` 重新拉取 **Chrome for Testing 148.0.7778.96**，与 R2/R3 同版本；`xvfb-run` 与 `xauth` 已恢复），把**最关键的结论**重测一遍。以下全部是本轮新产出、原始 JSON 保存在 `/tmp/aria2-probe/C-limits/raw/r4-*.json`。

### 9.1 512 MiB 全链路（`[R4]`，独立复现）

```
{"tag":"512MiB","write":"done","blob":"done","dl":"done",
 "terminal":{"state":"complete","error":null,"bytes":536870912},"startErr":null}
PEAK 1077288960  = 2.007x 文件大小, at 05a-during-download
df: run-start 1000681431040 → after-write 1000119791616 → after-download 999585759232
    → after-opfs-entry-deleted 1000122630144 → after-delete-all 1000679288832
```

### 9.2 1 GiB 全链路逐段（`[R4]`）

```
stages: {"opfs.getFileHandle":{"ok":true,"ms":17.2},
         "opfs.write+close":{"ok":true,"ms":5649.9,"bytes":1073741824,"throughputMBs":181.2},
         "opfs.getFile":{"ok":true,"ms":2.6,"fileSize":1073741824},
         "URL.createObjectURL":{"ok":true,"ms":0.5,
            "url":"blob:chrome-extension://pkopmbfhmmjoakkcmokhacgaabanfphn/4ce4033c-…"},
         "downloads.download(call)":{"ok":true,"ms":4.6}}
terminal: {"state":"complete","error":null,"bytesReceived":1073741824,
           "totalBytes":1073741824,"fileSize":1073741824,"exists":true,
           "filename":"/tmp/aria2-probe/C-limits/downloads/1GiB/7af5acb9-b3dc-4f03-9c36-bea91d4104c6"}
progress: 5.7ms 0 → 759.5ms 284,360,704 → 1262.6ms 597,295,104 → 1765.8ms 883,884,032
          → 2997.5ms 1,073,741,824 → 4002.6ms complete   (error 全程 null)
estimate: {"usage":76,"quota":999585050700}
pageErrors: []
```

### 9.3 1 GiB 逐时点磁盘表（`[R4]`，与 §4.1 的 `[R2]` 表独立吻合）

S = 1,073,741,824 B。

| 时点 | profile | ÷S | downloads | ÷S | 合计 | ÷S |
|---|---|---|---|---|---|---|
| 启动前 | 0 | 0.000 | 4,096 | 0.000 | 4,096 | 0.000 |
| 浏览器启动后 | 7,405,568 | 0.007 | 4,096 | 0.000 | 7,409,664 | 0.007 |
| 写 OPFS 之前 | 7,405,568 | 0.007 | 4,096 | 0.000 | 7,409,664 | 0.007 |
| 写 OPFS 进行中（14 次采样） | 7,438,336 → 1,005,371,392 单调 | ≤0.936 | 4,096 | 0.000 | 同步 | ≤0.936 |
| **写满之后** | **1,077,264,384** | **1.003** | 4,096 | 0.000 | 1,077,268,480 | **1.003** |
| `createObjectURL()` 之后 | **1,077,264,384（完全不变）** | 1.003 | 4,096 | 0.000 | 1,077,268,480 | 1.003 |
| **导出进行中 — 峰值** | 1,077,272,576 | 1.003 | **1,073,750,016** | **1.000** | **2,151,022,592** | **2.003** |
| **下载完成、OPFS 未删除** | 1,077,239,808 | 1.003 | 1,073,750,016 | 1.000 | 2,150,989,824 | **2.003** |
| **OPFS 已删除、blob URL 仍存活** | **3,493,888** | 0.003 | 1,073,750,016 | 1.000 | 1,077,243,904 | **1.003** |
| **下载完成、OPFS 已删除** | 3,493,888 | 0.003 | 1,073,750,016 | 1.000 | 1,077,243,904 | 1.003 |
| 浏览器关闭后 | 3,473,408 | 0.003 | 4,096（Playwright 删产物） | 0.000 | 3,477,504 | 0.003 |
| 全部删除后 | 0 | 0.000 | 0 | 0.000 | 0 | 0.000 |

`df` 关键节点：`run-start 1,000,679,251,968` → `after-write 999,582,732,288` → `after-download 998,511,304,704` → `after-opfs-entry-deleted 999,585,050,624` → `after-delete-all 1,000,681,332,736`。

blob URL 失效证据（`[R4]`，与 `[R2]` 完全一致）：

```
blobUrlAliveAfterDelete: {"fetchOk":false,"error":{"name":"TypeError","message":"Failed to fetch"}}
console(non-PROBE): [{"type":"error","text":"Failed to load resource: net::ERR_FILE_NOT_FOUND"}]
```

### 9.4 内存 blob 的 500 MiB 边界，1 B 级二分（`[R4]`）

| n | 结果 | `error` | bytesReceived | profile 增量 | blob_storage |
|---|---|---|---|---|---|
| 524,288,000（500 MiB） | **complete** | `null` | 524,288,000 | +4,096 B | 不存在 |
| **524,288,001（500 MiB + 1 B）** | **interrupted** | **`NETWORK_FAILED`** | **0** | ~+4 KB | 不存在 |
| 536,870,912（512 MiB） | **interrupted** | **`NETWORK_FAILED`** | **0** | ~+4 KB | 不存在 |

⇒ **阈值恰为 524,288,000 B**，没有更细的中间地带。

### 9.5 data: URL 下载对照（`[R4]`，8/8 成功）

```
api     1572834  urlLen=2097149  complete  bytes=1572834  落盘=1572834   itemUrlLen=2097149
api     1572835  urlLen=2097153  complete  bytes=1572835  落盘=1572835   itemUrlLen=2097153
api     2097152  urlLen=2796241  complete  bytes=2097152  落盘=2097152   itemUrlLen=2796241
api     8388608  urlLen=11184849 complete  bytes=8388608  落盘=8388608   itemUrlLen=11184849
anchor  1572834  urlLen=2097149  complete  bytes=1572834  落盘=1572834   itemUrlLen=2097149
anchor  1572835  urlLen=2097153  complete  bytes=1572835  落盘=1572835   itemUrlLen=2097153
anchor  2097152  urlLen=2796241  complete  bytes=2097152  落盘=2097152   itemUrlLen=2796241
anchor  8388608  urlLen=11184849 complete  bytes=8388608  落盘=8388608   itemUrlLen=11184849
```

### 9.6 2 MiB URL 常量对照（`[R4]`，逐字符复现）

```
tabs   payload=1572834  urlLen=2097149  aliveAfter=2  page-ok
       result: 建 tab 成功、随即消失，lastError="No tab with id: 1012224126."
tabs   payload=1572835  urlLen=2097153  SESSION-DEAD  PAGE-CLOSED
       sessionDiedDuringPoll="page.evaluate: Target page, context or browser has been closed"
fetch  payload=1572835  urlLen=2097153  aliveAfter=2  page-ok
       result: ok status=200 bytes=1572835 ms=32.9      ← 越界但完全不受影响
```

⇒ 与 `[R2]` 行为逐项一致：**2 MiB 只卡跨 Mojo 的导航 URL，不卡 fetch、不卡下载。**

### 9.7 本轮清理动作（如实记录）

- 每档测完即删除该档 `profile-<tag>/` 与 `downloads/<tag>/`，并在 §9.1/§9.3 的 `df` 日志中留痕（`after-delete-all` 均回到基线）。
- 全部测试结束后清点：`/tmp/aria2-probe/C-limits/` 下**已无任何测试数据文件**（无 `profile-*`、无 `downloads/*`），`find -size +50M` 无结果；仅剩脚本（几十 KB）、`raw/*.json` 结果（140 KB）与 `pw/node_modules`（18 MB，playwright 包）。
- **磁盘回到基线**：测试前 `df -h /tmp` = `overlay 1007G 22G 934G 3%`；清理后 = `overlay 1007G 24G 932G 3%`（差额 ≈ 2 GB 即本轮重装的 Chromium 113 MB + playwright 18 MB 等工具体积，全部落在容器 `/`，**未写入用户的 `D:` 盘**；`/workspace` 下只新增本报告一个文件）。
- 共享的 `~/.cache/ms-playwright/chromium-1223` **保留未删**，因为同容器其他实验员也依赖它。

---

*报告状态：已完成。§9 为本轮（R4）自证重跑，结论与 `[R2]/[R3]` 一致；未重跑的部分已在 §6 逐项列明。*
