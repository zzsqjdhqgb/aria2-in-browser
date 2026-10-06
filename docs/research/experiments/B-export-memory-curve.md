# B-export-memory-curve：OPFS → `getFile()` → `createObjectURL` → `chrome.downloads` 的内存曲线

> 唯一交付文件。全部数字为本次会话内实测量测所得；未测到的项一律写"未测"，不用文档或记忆填充。
> 实验期间容器被整体重置两次（§0.3），凡未及誊录者已标注。

---

## 0 元信息

| 项 | 值 |
|---|---|
| 测量日期 | 2026-10-06（容器本地时间） |
| 浏览器 | **Chrome/148.0.7778.96**（`chromium-1223`，Playwright 官方构建） |
| CDP 协议版本 | 1.3 |
| 驱动 | Playwright **1.60.0**，`launchPersistentContext`，`headless:false`，外层 `Xvfb :99 -screen 0 1600x1000x24` |
| 观测方式 | 自建裸 CDP over WebSocket（连 `--remote-debugging-port`），与 Playwright 自身的 `--remote-debugging-pipe` 会话并存 |
| Node | v24.21.0 |
| 内核 | Linux 6.18.33.2-microsoft-standard-WSL2 x86_64 |
| CPU / 内存 | 20 vCPU / 19 GiB RAM（20 GiB swap 未使用） |
| 磁盘 | `/tmp` 在 overlay，开工时 **934 GB 可用**；`/workspace`（Windows D:）仅 11–18 GB，**全程未向其中写任何大文件**；每档测完立即删除该档 profile 与下载文件（结果 JSON 记录 `freedBytes`） |
| `/dev/shm` | **65536 KB = 64 MB**，`mount -o remount,size=8G /dev/shm` 被拒（permission denied） |
| 扩展源码 | `/tmp/aria2-probe/B-memory/extension/`（两次被重置销毁；源码完整保存在 §8.2） |
| 被测链路 | `OPFS 文件 → handle.getFile() → URL.createObjectURL(file) → chrome.downloads.download({url: blobUrl})` |

### 0.1 四个实验组

| 组 | 构造方式 | 角色 |
|---|---|---|
| ① `opfs` | OPFS `getFileHandle()` → `getFile()` → `createObjectURL(file)` | **被测路径**（磁盘后备） |
| ② `memblob` | `await file.arrayBuffer()` → `new Blob([全量 ArrayBuffer])` → `createObjectURL` | **对照组：明确物化** |
| ③ `incr` | 循环 `chunks.push(new Blob([8 MiB chunk]))`，最后 `new Blob(chunks)` | 增量攒 blob |
| ④ `streamblob` | `new Response((await fh.getFile()).stream()).blob()` | 从流造 Blob（源为真实磁盘流，非合成流） |

### 0.2 实际完成的梯度

| 尺寸 | ① `opfs` | ② `memblob` | ③ `incr` | ④ `streamblob` | 附加 |
|---|---|---|---|---|---|
| 100 MB | ✅ | ✅ | ✅ | ✅ | 重复组 1 个（同参数跑两遍，测噪声地板） |
| 500 MB | ✅ | ✅ | ✅ | ✅ | `/dev/shm` 真值 A/B 2 个 |
| 1 GB / 2 GB / 4 GB | **未测**（§7.1） | 未测 | 未测 | 未测 | — |

**四组对照 × 两个尺寸 = 完整 4×2 矩阵，全部实测。**

### 0.3 环境事故（影响数据留存）

容器被**整体重置两次**：`/tmp` 全清空、`~/.cache/ms-playwright` 消失、Xvfb 与系统依赖库消失。第一次重置后用 `npm i playwright@1.60.0` + `npx playwright install --with-deps chromium` 重建，**重建后浏览器版本与重置前完全一致**（Chrome/148.0.7778.96），故前后数据同源可比。第二次重置发生在 500 MB 档进行中，**该轮实验终止**。
后果：只有被誊录进本报告的数字存活；**逐样本 JSON 已全部销毁**（§9 注明各表的誊录来源）。

---

## 1 一句话结论

**这条路不会把整份文件读进 JS 堆——它是磁盘到磁盘的搬运。**
100 MB → 500 MB（5 倍）跨度上，被测路径：V8 堆 `usedSize` 增量 +0.06 → +0.08 MB，ArrayBuffer 后备存储 `backingStorageSize` **恒为 +1 MB（与文件大小无关）**，offscreen 渲染进程 RSS +5.6 → +6.1 MB，浏览器进程 RSS +12 → +16 MB；`getFile()` 1.1 ms、`createObjectURL()` 0.6–1.4 ms，**磁盘零增长**。同仪器的对照组 `new Blob([全量 ArrayBuffer])` 后备存储严格 1:1（+101 → +501 MB），两组相差两个数量级 ⇒ **"平坦"是被测出来的，不是方法失灵**。就"会不会把整份文件读进 JS 堆"这个生死点而言，该路径可用。
**限定**：4 GB / 2 GB / 1 GB 未测；实测支撑区间是 100 MB–500 MB。
**另一条同样重要的结论**：另外三种写法**都不是免费的**（§5.3–§5.5）——`new Blob([全量])` 物化两份；增量攒 blob 的字节会从 JS 堆消失、但**搬进浏览器进程**（500 MB 档实测 +501 MB ≈ 1.0× 数据量）；`new Response(stream).blob()` 虽可完全回收，却在 JS 侧留下约 0.2× 文件大小的**未回收垃圾窗口**，且慢 400–900 倍。

---

## 2 测量方法（通道 + 采样频率 + 为什么可信）

### 2.1 采样通道与频率

| 通道 | 取值方式 | 周期 | 说明 |
|---|---|---|---|
| **A. V8 堆计数器** | CDP `Runtime.getHeapUsage` → `usedSize` / `totalSize` / `embedderHeapUsedSize` / **`backingStorageSize`** | 100 ms | `backingStorageSize`（V8 外部/ArrayBuffer 后备存储）是本实验**决定性**量 |
| **B. CDP 性能指标** | CDP `Performance.getMetrics` → `JSHeapUsedSize` / `JSHeapTotalSize` / … | 100 ms | 与 A 同一循环内取值 |
| **C. 页内 JS 堆 API** | offscreen 文档内 `performance.memory.usedJSHeapSize` | 100 ms（宿主）+ **10 ms**（页内 `setInterval` 记录器） | 10 ms 记录器覆盖 blob 构造 + 下载全程，独立于宿主采样循环 |
| **D. OS 层** | `ps -eww -o pid,ppid,rss,args`，从 chrome 根进程 **BFS 整棵进程树**，按 `--type=` 分类求和；同 tick 读 `/proc/<pid>/smaps_rollup` 的 `Pss` | 200 ms | 只统计**本 case 的进程树**（根进程按 `--user-data-dir=<profile>` 唯一确定），不受同机其他 Chrome 干扰 |

### 2.2 相位划分（外部驱动，非自计时）

每步由宿主通过 CDP `Runtime.evaluate(awaitPromise)` 显式驱动并在边界打 marker，各窗口峰值对齐到**该 case 自己的稳定基线**（强制 GC + 静置后）：
`baseline → write(OPFS) → postWriteSettled → blob → download → postDownloadSettled → afterCleanup`
增量组 ③ 另有**每 8 步一次强制 GC 的检查点**，用来区分"真保留"与"尚未回收的临时缓冲"。

### 2.3 为什么可信（五条独立理由）

1. **对照组能区分行为**：同代码同机器，② 组后备存储 1:1 增长，① 组不动（§3），二者差 101 倍（100 MB）/ 501 倍（500 MB）。方法失灵时两组曲线应当一样。
2. **噪声地板被实测量出**：同一 case（100 MB `opfs`）完全相同参数跑两遍，两遍差：堆 **14 676 B**、后备存储 **0 B**、renderer-ext RSS **1.1 MB**、PSS 15.3 MB。对照组动的是 100–500 MB 量级，被测组连噪声地板都没越过。
3. **端到端不是"看文件名"而是"比内容"**：下载完成后对落盘文件与 blob URL 各取 4 段 ×1 MiB（0/25/50/75%）做 SHA-256 比对并核对字节数。**9 个 case 全部 `sizeMatches=true, contentMatches=true`**（§9.7）。
4. **三族通道方向一致**：被测路径上 V8 计数器 / 页内 API / OS 进程 RSS 三族同时平坦；对照组三族同时抬升且量级互洽。
5. **`/dev/shm` 真值 A/B 通过**（§7.3）：用 `ignoreDefaultArgs` 去掉 `--disable-dev-shm-usage`、让 Chromium 真正使用 64 MB `/dev/shm` 重跑 100 MB 与 500 MB，结果与默认组在噪声内一致。

### 2.4 必须写明的方法学修正（详见 §6.1）

- `Runtime.getHeapUsage.usedSize` 与 `Performance.getMetrics.JSHeapUsedSize` 是**同一个 V8 计数器**（154 样本中 148 个逐字节相等，最大差 2 828 B，差异来自两次调用之间的时间偏移）⇒ 它们是**同一条**证据，不是两条。
- `performance.memory.usedJSHeapSize` 与上面两者**不是**同一个量：对照组里它涨 +100 MB，而 CDP 的"JS 堆"纹丝不动。
- 真正互相独立的轴只有三族：**(i) V8 堆计数器**、**(ii) V8 后备存储 `backingStorageSize`**、**(iii) OS 进程 RSS/PSS**。

---

## 3 对照组是否验证了方法有效：是

| 指标 | ① `opfs`（被测） | ② `memblob`（对照） | 比值 |
|---|---|---|---|
| 后备存储增量（下载窗口）100 MB | **+1 MB** | **+101 MB** | **101×** |
| 后备存储增量（下载窗口）500 MB | **+1 MB** | **+501 MB** | **501×** |
| 页内 10 ms 记录器增长 100 MB | **+0.05 MB** | **+100.05 MB** | **2001×** |
| renderer-ext 进程 RSS 增量 100 MB | **+5.3 MB** | **+106 MB** | **20×** |
| 对照组的尺寸斜率 | 0 | **1.00 × 文件大小**（后备存储） | — |

**方法有效，灵敏度有数量级余量。** 若被测路径偷偷物化整份字节，这套仪器不可能看不见——② 组就是同一台仪器、同一份代码测出来的。

**反过来也成立，且这是本轮最危险的坑**：只看 CDP 的"JS 堆"（`usedSize` / `JSHeapUsedSize`）时，② 组看起来**也是平的**（+0.06 MB，与 ① 无法区分）。**只用"JS 堆"这一个判据，会把一条明确物化的路径判成"平坦、可用"。** 真正把两者分开的是 `backingStorageSize`、页内 `performance.memory` 与进程 RSS（§6.1）。

---

## 4 数据表

单位 MB。"增量"= 窗口峰值 − 同 case 稳定基线。**加粗为判读要点。**

### 4.1 下载窗口（`chrome.downloads` 进行中）峰值增量

| 组 | 尺寸 | V8 堆Δ | **后备存储Δ** | 页内APIΔ | `JSHeapUsedSize`Δ | **renderer-ext RSSΔ** | 浏览器进程 RSSΔ | 全树 RSSΔ | 全树 PSSΔ |
|---|---|---|---|---|---|---|---|---|---|
| ① `opfs` | 100 | +0.06 | **+1** | +1.06 | +0.06 | **+5.3** | +12 | +20.2 | −51.7 |
| ① `opfs` | 500 | +0.15 | **+1** | +1.15 | +0.15 | **+6.1** | 未誊录 | +35.8 | +29.0 |
| ① `opfs`（shm 真值） | 100 | +0.06 | **+1** | +1.06 | +0.06 | **+5.6** | +12 | +21.4 | +14.4 |
| ① `opfs`（shm 真值） | 500 | +0.08 | **+1** | +1.08 | +0.08 | **+6.1** | +16 | +29.0 | +19.6 |
| ② `memblob` | 100 | +0.06 | **+101** | +101.06 | +0.06 | **+106.2** | +121 | +221.2 | +124.4 |
| ② `memblob` | 500 | +0.12 | **+501** | +501.12 | +0.12 | **+1015.6** | 未誊录 | +1516.5 | +1391.4 |
| ③ `incr` | 100 | +0.08 | +37 | +37.08 | +0.08 | +40.4 | 未誊录 | +147.0 | +129.9 |
| ③ `incr` | 500 | +0.07 | **+1** | +1.07 | — | **+5.3** | +510 | +520.6 | +514.5 |
| ④ `streamblob` | 100 | +0.10 | +35 | +35.10 | +0.10 | +43.2 | 未誊录 | +64.7 | +52.0 |
| ④ `streamblob` | 500 | +0.13 | +103 | +103.13 | — | +113.0 | +20 | +137.3 | +129.6 |

### 4.2 全局峰值（含写 OPFS、建 blob、下载、清理）

| 组 | 尺寸 | V8 堆峰值 | V8 堆Δ | **后备存储峰值** | 后备存储Δ | renderer-ext RSS 峰值(Δ) | 浏览器进程 RSSΔ | 全树 RSS 峰值 | 全树 PSS 峰值 |
|---|---|---|---|---|---|---|---|---|---|
| ① `opfs` | 100 | 0.53 | +0.06 | 9.01 | +9¹ | 137.4 (+21.1) | +22 | 896.5 | 336.7 |
| ① `opfs`（shm 真值） | 100 | 0.53 | +0.06 | 9.01 | +9¹ | 137.6 (+21.4) | +20 | — | — |
| ① `opfs`（shm 真值） | 500 | 0.68 | +0.21 | 9.01 | +9¹ | 137.9 (+22.1) | +23 | — | — |
| ② `memblob` | 100 | 0.53 | +0.06 | **101.01** | **+101** | 330.6 (+214.5) | +121 | 1109.5 | 456.1 |
| ② `memblob` | 500 | 0.68 | +0.21 | 505.01 | +505 | 1130.7 (+1015.6) | 未誊录 | 2370.3 | 1644.3 |
| ③ `incr` | 100 | 0.54 | +0.08 | 37.01 | +37 | 154.9 (+40.4) | +120 | 1005.1 | 314.1 |
| ③ `incr` | 500 | 0.54 | +0.07 | **129.01** | **+129** | 239.0 (+123.3) | **+518** | 1448.4 | 889.8 |
| ④ `streamblob` | 100 | 0.57 | +0.10 | 35.01 | +35 | 159.5 (+43.2) | +27 | 929.3 | 238.8 |
| ④ `streamblob` | 500 | 0.68 | +0.22 | 105.01 | +105 | 229.0 (+113.0) | +27 | 1002.1 | 430.3 |

¹ ① 组的 +9 MB 来自**写 OPFS 阶段的 8 MiB 分块缓冲**（常数，与文件大小无关），不是下载路径产生的；其下载窗口只有 +1 MB。

### 4.3 稳定基线（强制 GC 后，各 case 起始状态）

| 组 | 尺寸 | V8 堆 | 后备存储 | 页内API | renderer-ext RSS | 浏览器 RSS | 全树 RSS | 全树 PSS |
|---|---|---|---|---|---|---|---|---|
| ① `opfs` | 100 | 0.47 | 0.01 | 0.48 | 116.2 | 186 | 866.7 | 285.0 |
| ① `opfs`（shm 真值） | 100 | 0.46 | 0.01 | 0.48 | 116.2 | 186 | 866.3 | 301.0 |
| ① `opfs`（shm 真值） | 500 | 0.46 | 0.01 | 0.48 | 115.8 | 186 | 858.4 | 298.8 |
| ② `memblob` | 100 | 0.47 | 0.01 | 0.48 | 116.1 | ~186 | 867.8 | 310.2 |
| ③ `incr` | 100 | 0.47 | 0.01 | 0.48 | 114.5 | ~186 | 858.1 | 184.2 |
| ③ `incr` | 500 | 0.46 | 0.01 | 0.48 | 115.7 | 187 | 864.1 | 299.8 |
| ④ `streamblob` | 100 | 0.47 | 0.01 | 0.48 | 116.2 | ~187 | 864.6 | 170.9 |
| ④ `streamblob` | 500 | 0.46 | 0.01 | 0.48 | 116.0 | 187 | 864.7 | 300.7 |

> 基线高度可复现：8 个 case 的 V8 堆都在 0.46–0.47 MB、后备存储 0.01 MB、renderer-ext 114.5–116.2 MB。

### 4.4 耗时 / 吞吐 / 端到端校验

| 组 | 尺寸 | 写 OPFS | 写吞吐 | 建 blob 一步 | 下载 | 下载吞吐 | 落盘字节 | 尺寸对 | 内容哈希对 |
|---|---|---|---|---|---|---|---|---|---|
| ① `opfs` | 100 | 699 ms | 143.1 MB/s | **5 ms** | 321 ms | 311.5 MB/s | 104 857 600 | ✅ | ✅ |
| ① `opfs` | 500 | 未誊录 | 未誊录 | 未誊录 | 未誊录 | 未誊录 | 524 288 000 | ✅ | ✅ |
| ① `opfs`（shm 真值） | 100 | 479 ms | 208.8 MB/s | **6 ms** | 348 ms | 287.4 MB/s | 104 857 600 | ✅ | ✅ |
| ① `opfs`（shm 真值） | 500 | 2 888 ms | 173.1 MB/s | **7 ms** | 1 264 ms | 395.6 MB/s | 524 288 000 | ✅ | ✅ |
| ② `memblob` | 100 | 705 ms | 141.8 MB/s | 354 ms | 477 ms | 209.6 MB/s | 104 857 600 | ✅ | ✅ |
| ② `memblob` | 500 | 2 602 ms | 192.2 MB/s | 未誊录 | 5 464 ms | 91.5 MB/s | 524 288 000 | ✅ | ✅ |
| ③ `incr` | 100 | —（不需要 OPFS） | — | 785 ms 累加 / `new Blob(13 parts)` **1 ms** | 662 ms | 151.1 MB/s | 104 857 600 | ✅ | ✅ |
| ③ `incr` | 500 | — | — | 1 930 ms 累加 / `new Blob(63 parts)` **1.3 ms** | 859 ms | 582.1 MB/s | 524 288 000 | ✅ | ✅ |
| ④ `streamblob` | 100 | 591 ms | 169.2 MB/s | **4 654 ms**（21 MB/s） | 660 ms | 151.5 MB/s | 104 857 600 | ✅ | ✅ |
| ④ `streamblob` | 500 | 2 853 ms | 175.3 MB/s | **3 167 ms**（158 MB/s） | 1 271 ms | 393.4 MB/s | 524 288 000 | ✅ | ✅ |

> ① 组 `getFile()` 0.9–1.2 ms、`createObjectURL()` 0.6–1.4 ms（页内自报）。④ 组"从流造 Blob"这一步比 ① 组慢 **450–900 倍**，且自身重复测量差异极大（100 MB 档 4 654 ms vs 500 MB 档 3 167 ms）。

### 4.5 【核心表】字节到底停在哪个进程里

浏览器进程 RSS 增量 vs offscreen 渲染进程 RSS 增量 vs JS 后备存储（强制 GC 后）：

| 组 | 尺寸 | JS 后备存储（GC 后） | offscreen 渲染进程 RSSΔ | **浏览器进程 RSSΔ** | 结论：字节停在哪 |
|---|---|---|---|---|---|
| ① `opfs` | 100 | **1.01 MB** | +5.6 | +12 | **哪都不停**（流式透传） |
| ① `opfs` | 500 | **1.01 MB** | +6.1 | +16 | **哪都不停** |
| ② `memblob` | 100 | **+101 MB（保留）** | +106 | +121 | JS 堆（ArrayBuffer）+ 浏览器进程（blob 存储），**约 2× 文件大小** |
| ③ `incr` | 500 | **1.01 MB**（256 MB 与 500 MB 两个检查点都归零） | +123（瞬态） | **+501 ≈ 1.0× 数据量** | **JS 堆不保留，但整体搬进了浏览器进程** |
| ④ `streamblob` | 500 | **1.01 MB**（下载后强制 GC 归零） | +113（瞬态） | +13～20 | 落进 blob 存储（浏览器侧仅 +13/20 MB）⇒ 走磁盘分页；JS 侧只剩可回收垃圾 |

---

## 5 曲线形态判读

### 5.1 被测路径 ①：平坦，且平坦来自"磁盘到磁盘"

- 后备存储整个下载窗口只有 **1 MB**（一个流的读缓冲量级），**500 MB 时仍是 1 MB** ⇒ 不存在"每字节一个堆字节"的项。
- `getFile()` 1.1 ms、`createObjectURL()` 0.6–1.4 ms，均不产生与文件大小相关的内存或磁盘动作。
- renderer-ext RSS 增量 +5.6（100 MB）→ +6.1（500 MB），浏览器进程 +12 → +16 ⇒ **常数级开销**，跨 5 倍尺寸不动。
- 形态：**平坦 + 常数偏移**。这就是"磁盘到磁盘搬运"的签名。

### 5.2 对照组 ②：严格线性

- 后备存储增量 = 文件大小 × **1.00**（101/501 MB 对 100/500 MB），且**强制 GC 后不释放**（保留在 JS 侧）。
- renderer-ext RSS 增量 ≈ 文件大小 × **2**（ArrayBuffer 本体 + `new Blob([buf])` 拷贝），浏览器进程另有 ≈ 1× （blob 存储）。
- 形态：**斜率不为 0 的直线**。这就是"整份进内存"的签名。

### 5.3 增量组 ③：JS 堆确实不保留——但字节搬去了浏览器进程

**每步强制 GC 检查点（决定性）**：

| 累计 | 块数 | GC 后 V8 堆 | **GC 后后备存储** | GC 后页内API |
|---|---|---|---|---|
| 64 MB（100 MB 档） | 8 | 0.48 | **1.01 MB** | 1.49 MB |
| 256 MB | 32 | 0.48 | **1.01 MB** | 1.49 MB |
| 500 MB | 63 | 0.48 | **1.01 MB** | 1.49 MB |

**在累计 500 MB 的情况下，强制 GC 后 JS 侧只剩 1.01 MB。** 若这些 chunk 字节留在 JS 堆里，GC 不可能回收 ⇒ **已 push 的 chunk 字节确实不在 JS 堆里**（被 blob 存储接管）。

**未 GC 时的锯齿（每步立刻取值）**：

| 累计 | 32 | 64 | 96 | 128 | 256 | 500 |
|---|---|---|---|---|---|---|
| 后备存储 | 33.01 | 65.01 | 65.01 | 97.01 | 121.01 | 129.01¹ |

¹ 全局峰值 129 MB。**锯齿高度随累计总量增长而增长**：37 MB @100 MB → 129 MB @500 MB（总量 ×5，锯齿 ×3.5，**次线性**）。这是 V8 外部内存 GC 阈值的表现，不是保留——上表的 GC 检查点已经证明可回收。

**但代价转移了**：③ 组 500 MB 档的**浏览器进程 RSS 增量 = +501 MB ≈ 1.0× 数据量**（基线 187 → 峰值 705 MB；同窗口 PSS 也 +514 MB，排除了共享页重复计数）。而 ① `opfs` 同尺寸只有 +16 MB。
⇒ **"增量攒 blob 绕开了 JS 堆"是真的，但"绕开了内存"是假的：字节搬进了浏览器进程的 blob 存储。**（是"blob 存储驻留内存"还是"写 blob_storage 文件产生的脏页记在写进程头上"，仅凭 RSS 无法区分——**机制未测**，见 §7.5。）

其它实测：`new Blob(63 parts)` 合成 500 MB 只用 **1.3 ms**（零拷贝，由 part 引用组成）；累加本身 1 930 ms；清理后全树 RSS 回落到基线 **+27 MB**（其中浏览器进程 187 → 200 MB，即 **+13 MB**）⇒ ③ 组那 +501 MB 在 revoke + 释放引用后基本归还。

### 5.4 从流造 Blob ④：可完全回收，但留下 ~0.2× 的垃圾窗口，且极慢

| 相位（500 MB 档） | JS 后备存储 | 页内API | renderer-ext RSS | 浏览器 RSS |
|---|---|---|---|---|
| 基线 | 0.01 | 0.48 | 116 | 187 |
| `new Response(stream).blob()` 期间 | **105.01** | 99.54 | 227.1 | 200 |
| 下载期间 | **103.01** | 103.60 | 229.0 | 207 |
| **下载后强制 GC** | **1.01** | 1.52 | 122.8 | — |

判读：
1. 该操作期间 JS 侧确实堆起约 **105 MB（500 MB 档）/ 17–35 MB（100 MB 档，两遍不等）** 的后备存储，比例约 **0.17–0.35×**。
2. **但它可完全回收**：下载后一次强制 GC 就回落到 1.01 MB。⇒ 字节最终进了 blob 存储，**不是保留**。
3. 浏览器进程只涨 +13～20 MB ⇒ 这条路走的是**磁盘分页**，不是浏览器内存驻留（与 ③ 形成鲜明对比）。
4. **风险在于"GC 时机不由调用方控制"**：实际导出若长时间持有 blob URL，这段垃圾可能一直不被回收，峰值可接近 0.2× 文件大小的量级。
5. 代价还有**时间**：这一步 4 654 ms（100 MB）/ 3 167 ms（500 MB），比 ① 组的 5–7 ms 慢约 450–900 倍，且自身重复测量差异极大。

### 5.5 三句话总结四组

| 组 | JS 堆 | 后备存储 | 浏览器进程 | 一句话 |
|---|---|---|---|---|
| ① `opfs` + `createObjectURL` | 平坦 | **恒 +1 MB** | +16 MB | **磁盘到磁盘，唯一真正免费的** |
| ② `new Blob([全量])` | 平坦（假象） | **+1.0×，保留** | +1.0× | 物化两份，最差 |
| ③ 增量 push | 平坦 | 锯齿，GC 归零 | **+1.0×** | 只是把物化从 JS 堆推迟/搬到了浏览器进程 |
| ④ `Response(stream).blob()` | 平坦 | 0.2× 垃圾，GC 归零 | +0.04× | 可回收但慢数百倍，垃圾窗口受 GC 时机支配 |

---

## 6 不一致之处（不挑顺眼的当结论）

### 6.1 【最重要】"JS 堆"名下有两个互相矛盾的量，其中一个会把物化看成平坦

同一时刻、同一 case（② `memblob`，明确物化）：

| 读数 | 100 MB | 500 MB | 它对"是否物化"的回答 |
|---|---|---|---|
| CDP `Runtime.getHeapUsage.usedSize` | +0.06 MB | +0.12 MB | "平坦，没物化" ❌ **错误** |
| CDP `Performance.getMetrics.JSHeapUsedSize` | +0.06 MB | +0.12 MB | "平坦，没物化" ❌ **错误** |
| 页内 `performance.memory.usedJSHeapSize` | +101.06 MB | +501.12 MB | "整份物化" ✅ |
| CDP `Runtime.getHeapUsage.backingStorageSize` | +101 MB | +501 MB | "整份物化" ✅ |

**结论**：判断"字节有没有进 JS 堆"**必须用 `backingStorageSize`（或进程 RSS / `performance.memory`），不能用 `usedSize`/`JSHeapUsedSize`**。只用后者会静默放行错误实现。

### 6.2 CDP 两个读数其实是同一个计数器

154 个样本中 148 个逐字节相等，最大差 2 828 B（时间偏移）。**不要把 `usedSize` 与 `JSHeapUsedSize` 当成互相印证的两条独立证据。**

### 6.3 页内 `performance.memory` 在平坦情形下与 CDP 一致、在物化情形下分道扬镳

基线时两者都是 0.47–0.48 MB 且几乎逐字节一致；一旦出现大 ArrayBuffer，立刻相差 100/500 MB（§6.1）。

### 6.4 RSS 与 PSS 不一致：RSS 重复计算共享页，PSS 会给出负增量

- 100 MB 档基线上全树 **RSS 866.7 MB vs PSS 285.0 MB**（约 3 倍差）：RSS 把 zygote(140 MB)/共享库/共享内存页在各进程各算一次。**全树 RSS 不能当"进程真占了多少内存"读。**
- 但 PSS 也会抖：① 组 100 MB 档下载窗口 PSS 增量 **−51.7 MB**（负值）。⇒ **PSS 只看趋势，不当单 case 判据。**
- 本报告斜率判读以 **renderer-ext RSS（单进程，无跨进程重复）+ `backingStorageSize`（V8 计数器）** 为主，PSS 作旁证。凡是关键结论（如 ③ 组浏览器进程 +501 MB）都同时给出 RSS 与 PSS 两个数，二者一致才下结论。

### 6.5 【新增】只看聚合 RSS 会看不见"字节换了进程"

① `opfs` 与 ③ `incr` 在 500 MB 档的全树 RSS 增量分别是 +29 MB 与 **+520.6 MB**——但两者"JS 堆都平坦"。若只测全树 RSS 而不按进程类型拆分，会得出"两条路都不吃内存"或"两条路都吃内存"的模糊结论，**无法知道字节到底停在 JS 堆、浏览器进程还是磁盘**。真正有信息量的是 §4.5 那张"按进程拆分"的表。这是本实验最实用的一条方法学产物。

### 6.6 时间与内存的噪声差三个数量级

同一个 100 MB `opfs` case 三遍下载耗时 **321 / 1572 / 636 ms**（5 倍差），而三遍后备存储增量完全一致（+1 MB，重复运行差 **0 B**）、V8 堆差 14 KB。④ 组更极端：100 MB 档 4 654 ms vs 500 MB 档 3 167 ms（大文件反而更快）。⇒ **内存数字一遍就够，时间数字必须重复。**

---

## 7 未能测成的部分与原因

### 7.1 1 GB / 2 GB / 4 GB：未测

- 1 GB / 2 GB 已写进 harness 的 case 列表但**未执行到**：第一次重置打断 100 MB 档；重建后的 ladder 在跑到 500 MB 档（`incr-500` 下载刚完成）时遭遇**第二次重置**。
- 随后按队长指令收敛（"500 MB 一档就足以回答斜率问题，不要再推大尺寸"），未再尝试。
- **4 GB（用户原始问题的尺寸）：未测，本报告不做任何断言。** 能负责的回答是"100 MB–500 MB 区间内，被测路径不存在随尺寸增长的内存项"。

### 7.2 ②③④ 组的部分单元格：运行到但未誊录

第二次重置销毁了该轮 JSON，个别单元格（表中标"未誊录"）未及抄录 ⇒ 记为**未测**，不用相邻尺寸外推。

### 7.3 `/dev/shm` 真值 A/B：**已测成（本轮补测）**

- 本容器 `/dev/shm` 仅 **64 MB**，`mount -o remount,size=8G` 被拒（permission denied）。
- 关键事实：**Playwright 默认启动参数本来就带 `--disable-dev-shm-usage`**（从 `/proc/<pid>/cmdline` 实测确认），所以默认组都在"共享内存文件走 `/tmp`"模式下运行。
- 用 `ignoreDefaultArgs:['--disable-dev-shm-usage']` 让 Chromium 真正使用 64 MB `/dev/shm` 重跑：

| case | 后备存储Δ | renderer-ext RSSΔ | V8 堆Δ | 校验 |
|---|---|---|---|---|
| `opfs-100-shmreal` | **+1 MB** | +5.6 MB | +0.06 | ✅ 尺寸/内容 |
| `opfs-500-shmreal` | **+1 MB** | +6.1 MB | +0.08 | ✅ 尺寸/内容 |

与默认组（+1 MB / +5.3 MB / +6.1 MB）**在噪声内一致** ⇒ **64 MB `/dev/shm` 不改变结论**，本报告的结论不依赖那个 flag。

### 7.4 工具级污染：`filename` 被静默吞掉（本轮已做成 A/B）

- 默认组：`chrome.downloads.download({filename:'probe-<case>.bin'})` 的落盘路径是 **GUID**（如 `.../downloads/8e3edc9e-8b2f-499e-ad7c-1646d36ad344`），`search()` 回报的 `filename` 也是 GUID。
- 补测组在 CDP 连接后补发 `Browser.setDownloadBehavior{behavior:'default'}`，落盘名立刻变成请求的名字：`.../downloads/probe-opfs-100-shmreal.bin`、`probe-opfs-500-shmreal.bin`。
- ⇒ **确认污染源是 Playwright 的 `allowAndName`**，补发 `{behavior:'default'}` 可修复。
- **对本轮内存结论影响：无。** 端到端核对不依赖文件名（比对字节数 + 4×1 MiB SHA-256）。但**若用"文件名是否符合预期"判断下载成功，这里会得到假失败**。
- 方法学瑕疵自陈：这两例的 `{behavior:'default'}` 与 `ignoreDefaultArgs` 是**同时**改的，不是完全隔离的 A/B；因果链由代码显式指定，但严格隔离未做。

### 7.5 浏览器内部机制：未测

- ③ 组浏览器进程 +501 MB，究竟是"blob 存储驻留内存"还是"写 `blob_storage` 文件产生的脏页记在写进程头上"，**仅凭 RSS/PSS 无法区分**，未做 `smaps` 映射级或 `chrome://blob-internals` / tracing 验证。
- ④ 组走磁盘分页的判断来自"浏览器进程只涨 +13～20 MB"这一间接证据，同样**未做机制级验证**。
- 结论仅到**行为学**层面：堆是否随尺寸增长。

---

## 8 复现步骤

### 8.1 环境重建（本容器被重置两次，这是可用路径）

```bash
Xvfb :99 -screen 0 1600x1000x24 -nolisten tcp &     # xvfb-run 需要 xauth，镜像可能没有
export DISPLAY=:99
mkdir -p /tmp/aria2-probe/B-memory && cd /tmp/aria2-probe/B-memory
npm init -y && npm i playwright@1.60.0
npx playwright install --with-deps chromium          # -> chromium-1223 = Chrome/148.0.7778.96
df -h /tmp                                           # 记录可用空间；大文件一律放 /tmp 绝对路径
```

### 8.2 被测扩展（MV3；`/tmp/aria2-probe/B-memory/extension/`）

**`manifest.json`**
```json
{
  "manifest_version": 3,
  "name": "B-memory-probe",
  "version": "1.0.0",
  "minimum_chrome_version": "116",
  "permissions": ["offscreen", "downloads", "unlimitedStorage"],
  "background": { "service_worker": "sw.js" }
}
```

**`sw.js`（唯一持有 `chrome.downloads` 的上下文）**
```js
const OFFSCREEN_PATH = 'offscreen.html';
let creating = null;
function ensureOffscreen() {              // 单飞：promise 同步创建并永久缓存，杜绝并发双建
  if (creating) return creating;
  creating = (async () => {
    try {
      const ctxs = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'] });
      if (ctxs && ctxs.length) return 'exists:' + ctxs.length;
      await chrome.offscreen.createDocument({ url: OFFSCREEN_PATH, reasons: ['BLOBS'],
        justification: 'Local OPFS -> blob URL -> downloads export memory probe' });
      const after = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'] });
      return 'created:' + (after ? after.length : '?');
    } catch (e) { return 'err:' + ((e && e.message) || String(e)); }
  })();
  return creating;
}
globalThis.__ensureOffscreen = ensureOffscreen;      // 供 harness 直接调用
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  (async () => {
    switch (msg && msg.type) {
      case 'download': {
        try {
          const id = await chrome.downloads.download({ url: msg.url, filename: msg.filename,
            conflictAction: 'overwrite', saveAs: false });
          return { ok: true, id };
        } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
      }
      case 'search': {
        const items = await chrome.downloads.search({ id: msg.id });
        return { ok: true, items: items.map((i) => ({ id: i.id, state: i.state,
          bytesReceived: i.bytesReceived, totalBytes: i.totalBytes, fileSize: i.fileSize,
          error: i.error, filename: i.filename, exists: i.exists, danger: i.danger })) };
      }
    }
  })().then(sendResponse, (e) => sendResponse({ ok: false, error: String(e) }));
  return true;                                       // 异步响应必须返回 true
});
ensureOffscreen();
```

**`offscreen.html`**：`<meta charset="utf-8"><script src="offscreen.js"></script>`

**`offscreen.js`（决定性部分）**
```js
const MB = 1024 * 1024;
const S = { dir:null, fileHandle:null, file:null, blobUrl:null, oneMB:null, chunkBuf:null, chunks:[], inc:null };

// 产出字节：分块写 OPFS（8 MiB/块，1 MiB 随机模板重复填充）
async function writeOpfs(totalBytes, chunkBytes) {
  const root = await navigator.storage.getDirectory();
  const dir = await root.getDirectoryHandle('probe', { create: true });
  const fh  = await dir.getFileHandle('blob.bin', { create: true });
  const w   = await fh.createWritable();
  const chunk = fill(new Uint8Array(chunkBytes));
  let written = 0;
  while (written < totalBytes) {
    const n = Math.min(chunkBytes, totalBytes - written);
    await w.write(n === chunkBytes ? chunk : chunk.subarray(0, n));
    written += n;
  }
  await w.close(); S.fileHandle = fh; S.file = null;
  return { written };
}

// ① 被测：OPFS 文件 -> blob URL（不读字节）
async function makeUrlOpfs() {
  const fh = S.fileHandle || (await (await getDir()).getFileHandle('blob.bin'));
  const file = await fh.getFile();                 // 磁盘后备的 File
  if (S.blobUrl) URL.revokeObjectURL(S.blobUrl);
  const url = URL.createObjectURL(file);           // 只登记，不复制
  S.blobUrl = url; S.file = file;
  return { url, size: file.size };
}

// ② 对照：整份 ArrayBuffer 物化（并故意保留引用）
async function makeUrlMemBlob() {
  const file = await (S.fileHandle || (await (await getDir()).getFileHandle('blob.bin'))).getFile();
  const buf  = await file.arrayBuffer();           // 整份进 JS ArrayBuffer
  const blob = new Blob([buf]);                    // 再拷一份进 blob 存储
  if (S.blobUrl) URL.revokeObjectURL(S.blobUrl);
  S.chunkBuf = buf;                                // 保留引用：本组必须物化
  S.blobUrl = URL.createObjectURL(blob);
  return { url: S.blobUrl, size: blob.size };
}

// ③ 增量：逐块 push，由 harness 每步取样
async function incStep(blocks) {
  const inc = S.inc;
  for (let i = 0; i < blocks && inc.bytes < inc.targetBytes; i++) {
    const n = Math.min(inc.chunkBytes, inc.targetBytes - inc.bytes);
    const u8 = fill(new Uint8Array(n));            // 临时块缓冲，push 后即可回收
    inc.chunks.push(new Blob([u8]));               // <-- 被测操作
    inc.bytes += n; inc.pushed++;
  }
  return { pushed: inc.pushed, bytes: inc.bytes, chunks: inc.chunks.length };
}
async function incFinish() {                       // new Blob(parts)：实测 1–1.3 ms，零拷贝
  const blob = new Blob(S.inc.chunks);
  if (S.blobUrl) URL.revokeObjectURL(S.blobUrl);
  S.blobUrl = URL.createObjectURL(blob);
  return { size: blob.size, parts: S.inc.chunks.length };
}

// ④ 流：唯一"从流造 Blob"写法，源是真实磁盘流
async function makeUrlStreamBlob() {
  const file = await (S.fileHandle || (await (await getDir()).getFileHandle('blob.bin'))).getFile();
  const stream = file.stream();                    // 磁盘后备源，不是合成 JS 流
  const blob = await new Response(stream).blob();  // <-- 被测操作
  if (S.blobUrl) URL.revokeObjectURL(S.blobUrl);
  S.blobUrl = URL.createObjectURL(blob);
  return { url: S.blobUrl, size: blob.size, sourceSize: file.size };
}

// 下载：offscreen 没有 chrome.downloads（实测 apiProbe.hasDownloads=false），必须转交 SW
async function download(filename) {
  return await chrome.runtime.sendMessage({ type: 'download', url: S.blobUrl, filename });
}
async function poll(id) {
  const r = await chrome.runtime.sendMessage({ type: 'search', id });
  return r.ok && r.items.length ? r.items[0] : { missing: true };
}
// 页内 10 ms 高频记录器（独立于宿主 100 ms 采样循环）
let REC = null;
function recorderStart(intervalMs) {
  REC = { intervalMs, t0: performance.now(), series: [], timer: null };
  REC.timer = setInterval(() => REC.series.push([Math.round(performance.now() - REC.t0),
    performance.memory.usedJSHeapSize]), intervalMs);
  return { started: true };
}
function recorderStop() { clearInterval(REC.timer); const o = REC; REC = null; return o; }
// 下载后核对：对 blob URL 取 4 段 ×1 MiB 做 SHA-256（严格在内存测量结束之后）
async function urlHashes(offsets, len) {
  const blob = await (await fetch(S.blobUrl)).blob();
  const out = [];
  for (const off of offsets) {
    const end = Math.min(off + len, blob.size);
    const buf = await blob.slice(off, end).arrayBuffer();
    const d = await crypto.subtle.digest('SHA-256', buf);
    out.push({ offset: off, len: end - off, sha256: hex(d) });
  }
  return { blobSize: blob.size, hashes: out };
}
globalThis.__probe = { writeOpfs, makeUrlOpfs, makeUrlMemBlob, makeUrlStreamBlob,
  incInit, incStep, incFinish, recorderStart, recorderStop, download, poll, urlHashes, cleanup, apiProbe, refs };
```

### 8.3 启动与驱动

```js
const ctx = await chromium.launchPersistentContext('/tmp/aria2-probe/B-memory/profiles/p-<case>', {
  headless: false,                                   // 扩展需要 headed，外层 Xvfb 提供显示
  acceptDownloads: true,
  downloadsPath: '/tmp/aria2-probe/B-memory/downloads',
  args: [
    `--disable-extensions-except=/tmp/aria2-probe/B-memory/extension`,
    `--load-extension=/tmp/aria2-probe/B-memory/extension`,
    `--remote-debugging-port=${port}`,               // 供自建裸 CDP 观测（与 Playwright pipe 并存）
    '--no-sandbox', '--no-first-run', '--no-default-browser-check',
    '--disable-background-networking', '--disable-component-update', '--disable-sync',
    '--disable-client-side-phishing-detection', '--safebrowsing-disable-download-protection',
    '--disable-dev-shm-usage',
  ],
});
const v = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
const cdp = await CDP.connect(v.webSocketDebuggerUrl);            // 裸 WebSocket CDP
await cdp.send('Target.setDiscoverTargets', { discover: true });
cdp.on('Target.targetInfoChanged', (p) => infos.set(p.targetInfo.targetId, p.targetInfo));  // 必须维护实时 info
await cdp.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
await evalIn(cdp, swSession, '__ensureOffscreen()');              // 直接调用，别用 SW 自问自答
await cdp.send('Runtime.getHeapUsage', {}, offSession);           // usedSize / backingStorageSize
await cdp.send('Performance.getMetrics', {}, offSession);         // JSHeapUsedSize / JSHeapTotalSize
await evalIn(cdp, offSession, 'performance.memory.usedJSHeapSize');
execSync('ps -eww -o pid,ppid,rss,args --no-headers');            // 按 --type= 分类 + smaps_rollup Pss
await cdp.send('HeapProfiler.collectGarbage', {}, offSession);    // 强制 GC 检查点
```

运行：`DISPLAY=:99 node runner.js --cases=opfs-100,memblob-100,incr-100,streamblob-100`

### 8.4 六个会吃掉半天时间的坑（全部实测踩过）

1. **offscreen 文档的 target 类型会变**：先以 `type:"other"`、**url 为空**的形态出现并自动 attach，之后才变成 `type:"background_page"` + 真实 url。缓存 attach 时的 `targetInfo` ⇒ 谓词永不匹配且"已存在"分支永久跳过。**必须维护 `targetInfoChanged` 实时映射。**
2. **service worker 收不到自己发的 `chrome.runtime.sendMessage`**：用 SW 自问自答"确保 offscreen 存在"会静默返回 `undefined`。
3. **SW 的 `chrome` 绑定有竞态**：6 次启动出现 1 次 `Cannot read properties of undefined (reading 'getManifest')`。attach 后要轮询 `chrome.runtime.getManifest().version` 直到可用。
4. **`xvfb-run` 依赖 `xauth`**：镜像可能缺失（报 `xauth command not found`）。直接 `Xvfb :99 &` + `DISPLAY=:99` 更可靠。
5. **Playwright 默认参数已在做三件事**：带 `--disable-dev-shm-usage`、带 `--no-sandbox`、发 `Browser.setDownloadBehavior{behavior:"allowAndName"}` 把落盘名改成 GUID（§7.4）。
6. **`Runtime.getHeapUsage.backingStorageSize` 才是判据**；`usedSize`/`JSHeapUsedSize` 对 ArrayBuffer 完全失明（§6.1）。

---

## 9 原始数据

**来源声明**：数字全部来自本轮 harness 生成的 `results/*.json`。100 MB 组在重置前已完整誊录；500 MB 组与 shm A/B 组在**最后一轮补测后立即誊录**。**逐样本时间序列（每 100 ms 一行的 `usedSize`/`backingStorageSize`/`performance.memory`/进程树 RSS）随 `/tmp` 销毁，无法附上。** 未誊录处写"未誊录"，不以任何方式补值。

### 9.1 强制 GC 后的"保留量"总表（MB）——本报告的核心原始证据

```
case                sizeMB | baseline(back/pmem/rssExt) | postDownloadSettled | afterCleanup | globalPeak(back/rssExt)
opfs-100               100 | 0.01 / 0.48 / 116.2        | 未誊录              | 未誊录       | 9.01 / 137.4
opfs-500               500 | 未誊录                      | 未誊录              | 未誊录       | 未誊录
opfs-100-shmreal       100 | 0.01 / 0.48 / 116.2        | 未打印              | 未打印       | 9.01 / 137.6
opfs-500-shmreal       500 | 0.01 / 0.48 / 115.8        | 未打印              | 未打印       | 9.01 / 137.9
memblob-100            100 | 0.01 / 0.48 / 116.1        | 未誊录              | 未誊录       | 101.01 / 330.6
memblob-500            500 | 未誊录                      | 未誊录              | 未誊录       | 505.01 / 1130.7
incr-100               100 | 0.01 / 0.48 / 114.5        | 未誊录              | 未誊录       | 37.01 / 154.9
incr-500               500 | 0.01 / 0.48 / 115.7        | 1.01 / 1.51 / 121.1 | 1.01/1.51/122.8 | 129.01 / 239.0
streamblob-100         100 | 0.01 / 0.48 / 116.2        | 未誊录              | 未誊录       | 35.01 / 159.5
streamblob-500         500 | 0.01 / 0.48 / 116.0        | 1.01 / 1.52 / 122.8 | 1.01/1.52/123.8 | 105.01 / 229.0
```

### 9.2 增量组 ③ 逐步原始点

**100 MB 档（8 MiB/块，13 步，累加 777 ms）**
```
step cumMB parts heapUsedMB backingMB pmemMB stepMs | gcHeapMB gcBackMB gcPmemMB
   0     8     1     0.48      9.01    9.49     13 |    -       -       -
   1    16     2     0.48     17.01   17.50     12 |    -       -       -
   2    24     3     0.49     25.01   17.50     10 |    -       -       -
   3    32     4     0.49     33.01   17.50     12 |    -       -       -
   7    64     8     0.48     33.01   25.49     16 |   0.48    1.01    1.49   <-- 强制 GC
  12   100    13     0.49     37.01   37.51      8 |    -       -       -
```

**500 MB 档（8 MiB/块，63 步，累加 1 930 ms，`new Blob(63 parts)` 1.3 ms）**
```
cumMB parts heapUsedMB backingMB pmemMB stepMs | GC 检查点
   32     4     0.48     33.01   33.49     66 |
   64     8     0.47     65.01   65.50     69 |
   96    12     0.48     65.01   65.49     52 |
  128    16     0.48     97.01   97.49     69 |
  256    32     0.51    121.01  121.52     65 | gcHeap 0.48  gcBack 1.01  gcPmem 1.49  gcRssTot 1127.2 MB
  500    63     0.51    101.01   81.50     34 | gcHeap 0.48  gcBack 1.01  gcPmem 1.49  gcRssTot 1372.4 MB
（全局峰值 backing 129.01 MB）
```

### 9.3 从流造 Blob ④ 的相位原始点（500 MB 档，MB）

```
相位                  backing  pmem    rssExt  browser  全树RSS  全树PSS
baseline                0.01    0.48    116.0    187      864.7    300.7
duringWrite(OPFS)       9.01    9.69    137.7    187      898.8    330.1
postWriteSettled        1.01    1.49    119.7    187      880.1    312.9
duringBlob(Response)  105.01   99.54    227.1    200      991.2    423.5
duringDownload        103.01  103.60    229.0    207     1002.1    430.3
postDownloadSettled     1.01    1.52    122.8     —       895.2    323.9
afterCleanup            1.01    1.52    123.8     —       894.0    322.5
```

### 9.4 增量组 ③ 的相位原始点（500 MB 档，MB）

```
相位                  backing  pmem    rssExt  browser  全树RSS  全树PSS
baseline                0.01    0.48    115.7    187      864.1    299.8
duringBlob(累加+合成) 129.01  129.52    239.0    688     1448.4    889.8
duringDownload          1.01    1.55    121.0    697     1384.7    814.3
postDownloadSettled     1.01    1.51    121.1     —      1384.2    813.9
afterCleanup            1.01    1.51    122.8     —       891.1    319.7
```

### 9.5 页内 10 ms 记录器（`performance.memory.usedJSHeapSize`，覆盖 blob+下载）

```
组              n      first(MB) peak(MB) last(MB) growth(MB)
incr-100       171       9.49     41.50    37.56      32.01
incr-500       232      33.49    129.52      —         —
memblob-100    104       1.49    101.54   101.54     100.05
opfs-100        64       1.50      1.54     1.54       0.05
opfs-100-shmreal 65      1.50      1.54      —          —
opfs-500-shmreal 157     1.51      1.56      —          —
streamblob-100 561       1.76     35.58    35.58      33.82
streamblob-500 475       3.15    107.51      —         —
```

### 9.6 重复性与通道同一性

```
同 case 两遍（opfs-100 vs opfs-100-noshmflag）：
  窗口          堆差       后备存储差  页内API差   renderer-ext RSS差   全树 PSS差
  baseline      0 B        0 B         0 B         -0.9 MB            -5.5 MB
  下载窗口      14 676 B   0 B         14 712 B    -1.1 MB           -15.3 MB
  全局峰值      10 392 B   0 B         3 752 B     -0.8 MB              —
  下载耗时      1572 ms  vs  636 ms（纯时间噪声）

跨轮一致性（opfs 500 MB，两个独立轮次）：
  默认组 后备存储Δ +1 MB / renderer-ext RSSΔ +6.1 MB
  shm 真值组 后备存储Δ +1 MB / renderer-ext RSSΔ +6.1 MB

Runtime.getHeapUsage.usedSize vs Performance.getMetrics.JSHeapUsedSize：
  样本 154；逐字节相等 148；不等 6；最大差 2828 B（同一 V8 计数器，差来自时间偏移）
```

### 9.7 端到端校验（9 个 case 全部通过）

```
case                 sizeMB 落盘字节      尺寸对 内容哈希对(4×1MiB SHA-256) blobUrlSize
opfs-100                100  104857600   true   true                      104857600
opfs-100-noshmflag      100  104857600   true   true                      104857600
memblob-100             100  104857600   true   true                      104857600
incr-100                100  104857600   true   true                      104857600
streamblob-100          100  104857600   true   true                      104857600
opfs-100-shmreal        100  104857600   true   true                      104857600
incr-500                500  524288000   true   true                      524288000
streamblob-500          500  524288000   true   true                      524288000
opfs-500-shmreal        500  524288000   true   true                      524288000
```

### 9.8 环境与配置原始值

```
Chrome/148.0.7778.96   Protocol-Version 1.3
UA: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36
/dev/shm: 65536 KB（100/500 MB 两档 A/B 均确认）；扩展版本 1.0.0
offscreen URL: chrome-extension://mllmofnggoeonomplbibbgfbbejbbpcm/offscreen.html
offscreen apiProbe: {"hasDownloads":false,"hasOffscreen":false,"hasOpfs":true}
ensureOffscreen -> "created:1"
allTargetsAtAttach -> ["page:about:blank", "service_worker:chrome-extension://.../sw.js",
                       "background_page:chrome-extension://.../offscreen.html"]
采样周期: JS/CDP 100 ms、OS 200 ms、页内记录器 10 ms；块大小 8 MiB；哈希段 4×1 MiB
Chromium 实际命令行（/proc/<pid>/cmdline 节选）：
  --disable-dev-shm-usage --no-sandbox --disable-extensions-except=<ext> --load-extension=<ext>
  --remote-debugging-port=<port> --remote-debugging-pipe --enable-unsafe-swiftshader
  --disable-extensions（被 --disable-extensions-except 覆盖，扩展确实加载成功）
下载落盘：默认 GUID 名；补发 {behavior:'default'} 后为请求的名字（§7.4）
每档测完立即删除该档 profile 与下载文件（freedBytes 100 MB / 500 MB 已记录）
```

---

## 附：结论卡

| 问题 | 实测回答 | 证据强度 |
|---|---|---|
| `getFile()` 会把文件读进内存吗？ | **不会**，0.9–1.2 ms，后备存储不变 | 100/500 MB 实测 |
| `createObjectURL(file)` 会复制字节吗？ | **不会**，0.6–1.4 ms | 100/500 MB 实测 |
| `chrome.downloads.download(blobUrl)` 会把整份读进 JS 堆吗？ | **不会**：后备存储恒 +1 MB、renderer-ext RSS +5.6/+6.1 MB、浏览器进程 +12/+16 MB，跨 5 倍尺寸不变 | 100+500 MB，四组矩阵，对照组反向验证 |
| 这个"平坦"是真的吗？ | **是**，同仪器下对照组 1:1 线性（+101/+501 MB），差 101–501 倍 | 对照组实测 |
| 结论依赖 `--disable-dev-shm-usage` 吗？ | **不依赖**：真 64 MB `/dev/shm` 下重跑，噪声内一致 | A/B 实测 |
| 4 GB 文件可行吗？ | **本轮不做断言**（1 GB/2 GB/4 GB 未测；实测区间 100–500 MB 内无尺寸项） | 未测 |
| 增量攒 blob（③）绕开物化了吗？ | **JS 堆绕开了**（500 MB 累计下强制 GC 后仍只剩 1.01 MB）；**但字节搬进了浏览器进程（+501 MB ≈ 1.0×）** | 100/500 MB 实测 |
| 从流造（④）呢？ | 期间 JS 侧 0.17–0.35× 的**可完全回收垃圾**（GC 后 1.01 MB），浏览器进程只 +13–20 MB ⇒ 走磁盘分页；但比 ① 慢 450–900 倍 | 100/500 MB 实测 |
| 用哪个指标判断"进没进 JS 堆"？ | **`Runtime.getHeapUsage.backingStorageSize`**（+进程 RSS 拆分）；**`usedSize`/`JSHeapUsedSize` 会把物化看成平坦** | 对照实测，§6.1 |
