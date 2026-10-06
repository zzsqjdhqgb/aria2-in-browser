# D — `blob:` URL 的三段隔离打点：创建 vs 消费

> 实验代号 D（`/tmp/aria2-probe/D-file-blob-isolation/`）。
> 唯一交付文件即本文件。

## 0 元信息

| 项 | 值 |
|---|---|
| 浏览器 | **Chrome for Testing 148.0.7778.96**（CDP `Browser.getVersion` 实测） |
| 协议版本 | 1.3 |
| 测试日期 | 2026-10-06，运行窗口 12:23:43 – 12:26:32 UTC |
| 内核 / 机器 | Linux 6.18.33.2-microsoft-standard-WSL2，20 vCPU，19999 MB RAM |
| 可用磁盘 | `/tmp`（overlay）启动时 **954568.9 MB** 空闲；`/workspace`（挂载 Windows `D:\`）**17757.3 MB** 空闲 |
| 启动方式 | `xvfb-run -a` + headed Chrome（扩展需要 headed），**裸 CDP 驱动，不用 Playwright** |
| 尺寸档 | **256 MB 与 1024 MB**（按 captain 指示收敛到 ≤1 GB） |
| OPFS 写入 | 8 MiB 分块 `createWritable().write()`；256 MB 用 1530.6 ms（167 MB/s），1024 MB 用 5345.8 ms（192 MB/s） |
| 采样 | 阶段边界：6×100 ms 窗口取中位数 + 4 次 RSS；③ 段：JS 堆每 100 ms、RSS 每 200 ms |
| 峰值磁盘占用 | ≈2.2 GB（OPFS 源文件 + 同一时刻仅一份下载产物） |

### 0.1 环境重建说明（必须记录）

本机经历了**两次容器整体重置**，`/tmp` 与 `/root/.cache/ms-playwright/` 被清空，题目给定的 Chromium 与 Playwright 路径（`/tmp/vista-work/pw`）均已不存在。我做了如下重建，**版本与题目给定环境一致**：

- 从 Chrome for Testing 官方源取回 **148.0.7778.96** `linux64` 包（与重置前实测的 `chromium-1223` 同一版本号），解到 `/opt/cft/chrome-linux64/chrome`；
- `apt-get install xvfb xauth` 及 Chrome 运行库（`libglib2.0-0 libnss3 libatk* libcups2 libdrm2 libxkbcommon0 libgbm1 libpango* libcairo2 libasound2` 等）。

**因此本实验不依赖 Playwright**，改用裸 CDP 驱动。这同时规避了 captain 提示的两个工具级坑：本实验既没有注册 `onDeterminingFilename`，也不经过 `launchPersistentContext` 的 `Browser.setDownloadBehavior{behavior:"allowAndName"}`；下载目录通过 profile 的 `Preferences`（`download.default_directory`）显式指定为**绝对路径** `/tmp/aria2-probe/D-file-blob-isolation/downloads/dl-<size>`。

### 0.2 测量协议（为什么"0"可信）

同一套协议施加于**每一个阶段**以及一个**空操作对照组（null-op）**：

```
before   : 强制 GC → 静置 500 ms → 6×100 ms 窗口（取中位数）+ 4 次 RSS 快照
op       : 被测的单次调用，用页面内 performance.now() 计时
raw      : 调用后立刻 6×100 ms 窗口，不 GC     → 抓瞬态
retained : 强制 GC → 静置 → 6×100 ms 窗口       → 抓留存成本
```

窗口取**中位数**而非单点，使一次 GC 停顿或调度抖动无法被报成阶段成本。**null-op 对照给出协议自身的噪声带**——所以"零成本"是相对于一个实测噪声带说的，不是断言。③ 段另加一条独立通道：直接轮询下载目录里文件的**磁盘增长曲线**（`chrome.downloads` 的 `bytesReceived` 对 blob URL 不可靠，理由见 §5.3）。

### 0.3 进程归属标定

所有 RSS 都通过 `/proc/<pid>/stat` + `/proc/<pid>/cmdline` 按进程树采集。offscreen 文档所在进程不是猜的：在 offscreen 里分配 512 MB 并**每 4 KiB 触碰一页**，按 RSS 增量归属（首次尝试按 64 KiB 步进只提交了 1/16 的页，已修正）：

| 尺寸档 | 归属到的 pid | 类型 | 请求 512 MB 实测 RSS 增量 |
|---|---|---|---|
| 256 MB | 9113 | `renderer-ext` | **+521.4 MB** |
| 1024 MB | 9984 | `renderer-ext` | **+521.4 MB** |

即 offscreen 文档独占一个 **extension renderer** 进程，标定误差 ~1.9%。

---

## 1 一句话结论

**假说成立：① `getFile()` 与 ② `createObjectURL()` 都是零成本（亚毫秒、heap/backing 增量为 0.00 MB），全部代价确实压在 ③ 上；而 ③ 是流式消费——1 GiB 下载全程 renderer 堆与 RSS 平坦（Δ+0.0 MB），磁盘字节稳定增长，速率与 `cp` 同量级。**

补两条本次实测才显现的修正：

1. **② 的"零成本"与源无关**：对 1 GiB 的**已物化 Blob** 调 `createObjectURL()` 同样是 0.3 ms / 0.00 MB。人们在 ArrayBuffer 版本里归给"②"的那 1 GB 成本，实际属于 `new Blob([buf])` 这一步，不属于 `createObjectURL`。
2. **③ 不需要"快照"，但需要调用那一刻引用可用**：`File` 是**活句柄而非快照**（删掉 OPFS 条目后读它直接 `NotFoundError`）；但只要 `download()` 调用时条目还在，下载栈会立刻取得自己的持久引用，此后删除/改名毫不影响，1 GiB 完整落盘且逐块校验一致。

---

## 2 三段打点的数据

`Δ` 全部为**窗口中位数之差**，`retained` 指强制 GC 后的留存增量。单位 MB。


### 2.1 256 MB 档

| 阶段 | 单次 op (ms) | 20× 中位数 (ms) | Δheap (MB) | Δbacking (MB) | ΔRSS 总计 (MB) | ΔusedJSHeap (MB) |
|---|---|---|---|---|---|---|
| null-op 对照（不分配） | 0.10 | — | 0.00 | 0.00 | 0.0 | 0.00 |
| ① `opfsHandle.getFile()` | 0.70 | 0.50 | 0.00 | 0.00 | -0.8 | 0.00 |
| ② `URL.createObjectURL(file)` | 0.70 | 0.40 | 0.00 | 0.00 | -0.1 | 0.00 |
| ①M `file.arrayBuffer()`（整份读入） | 536.70 | — | 0.00 | +256.00 | +255.9 | +256.00 |
| ②M `new Blob([整份 ArrayBuffer])` | 206.10 | — | 0.00 | 0.00 | +255.9 | 0.00 |
| ②M' `createObjectURL(已物化 Blob)` | 0.20 | — | 0.00 | 0.00 | 0.0 | 0.00 |

- ③ 段不是瞬时调用，其代价以时间序列给出，见 §5 与 §9。
- 该档 T0 基线：heap 0.48 MB / backing 1.01 MB / 全树 RSS 1249.3 MB。
- OPFS 写入：1530.6 ms（167 MB/s，块 8 MiB）。
- ③ File 版 1 MiB 前缀 sha256 与 OPFS 源一致：**true**。

### 2.2 1024 MB 档

| 阶段 | 单次 op (ms) | 20× 中位数 (ms) | Δheap (MB) | Δbacking (MB) | ΔRSS 总计 (MB) | ΔusedJSHeap (MB) |
|---|---|---|---|---|---|---|
| null-op 对照（不分配） | 0.00 | — | 0.00 | 0.00 | 0.0 | 0.00 |
| ① `opfsHandle.getFile()` | 0.70 | 0.60 | 0.00 | 0.00 | +0.2 | 0.00 |
| ② `URL.createObjectURL(file)` | 0.60 | 0.30 | 0.00 | 0.00 | +0.2 | 0.00 |
| ①M `file.arrayBuffer()`（整份读入） | 2173.60 | — | 0.00 | +1024.00 | +1023.6 | +1024.00 |
| ②M `new Blob([整份 ArrayBuffer])` | 982.90 | — | 0.00 | 0.00 | +1024.9 | 0.00 |
| ②M' `createObjectURL(已物化 Blob)` | 0.30 | — | 0.00 | 0.00 | -1.0 | 0.00 |

- ③ 段不是瞬时调用，其代价以时间序列给出，见 §5 与 §9。
- 该档 T0 基线：heap 0.49 MB / backing 1.01 MB / 全树 RSS 1248.8 MB。
- OPFS 写入：5345.8 ms（192 MB/s，块 8 MiB）。
- ③ File 版 1 MiB 前缀 sha256 与 OPFS 源一致：**true**。


### 2.3 读法

- **① `getFile()`**：256 MB 档 0.7 ms / 1024 MB 档 0.7 ms——**文件大 4 倍，耗时不变**。20 次重复的中位数 0.5 / 0.6 ms，最大值 0.6 / 1.1 ms。heap 与 backing 增量都是 **0.00 MB**，RSS 落在噪声带内（−0.8 / +0.2 MB）。若它拷贝 1 GiB，应该花 ~2.2 s（同尺寸 `arrayBuffer()` 实测 2173.6 ms）。**它没有拷贝。**
- **② `createObjectURL(file)`**：0.6–0.7 ms 单次、0.3–0.4 ms 中位数，heap/backing **0.00 MB**。**登记一个句柄，不碰字节。**
- **对照组 ①M `arrayBuffer()`**：536.7 / 2173.6 ms，`backingStorageSize` **+256.00 / +1024.00 MB**（正好等于载荷），RSS +255.9 / +1023.6 MB。**这是"整份读进内存"的实测形态。**
- **对照组 ②M `new Blob([buf])`**：206.1 / 982.9 ms，RSS **+255.9 / +1024.9 MB**——第二次整份拷贝（进入 renderer 的 blob 存储；它不出现在 `backingStorageSize` 里，因为那不是 V8 backing store）。
- **对照组 ②M' `createObjectURL(materialised Blob)`**：**0.2 / 0.3 ms，Δ 全 0**。这条是本次的关键对照：**物化一个 1 GiB 的 Blob 完全不改变 `createObjectURL` 的成本**——② 永远只是登记句柄。

> **方法学附注（对兄弟实验有用）**：物化的 ArrayBuffer **不出现在** `Runtime.getHeapUsage.usedSize` 里（本实验全程该值为 0.00 MB 增量），只出现在 `backingStorageSize`、`performance.memory.usedJSHeapSize` 和 RSS 里。只看 `usedJSHeapSize`/`usedSize` 会完全漏掉整份 ArrayBuffer。

---

## 3 head-to-head 对照曲线（File 版 vs ArrayBuffer 版）

同尺寸、同一浏览器会话、同一套采样协议、**同一个 ③ 调用**；两组**串行**执行，File 版测完立即删除下载产物再做 ArrayBuffer 版，同一时刻只留一份大文件。


### 3.1 256 MB 档

| 段 | File 版 | ArrayBuffer 对照组 | File 版 / 对照 |
|---|---|---|---|
| **①** 耗时 | **0.70 ms** | **536.7 ms**（`arrayBuffer()`） | **767×** |
| **①** Δbacking / ΔRSS | **0.00 MB** / -0.8 MB | **+256.00 MB** / +255.9 MB | 0 vs 256 MB |
| **②** 耗时 | **0.70 ms**（`createObjectURL(file)`） | 206.1 ms（`new Blob`）+ **0.20 ms**（`createObjectURL(blob)`） | — |
| **②** Δheap / ΔRSS | **0.00 MB** / -0.1 MB | 0.00 MB / **+255.9 MB** | 0 vs 256 MB |
| **③** 耗时 / 速率 | 1024 ms / 250 MB/s | 444 ms / 577 MB/s | 2.31× |
| **③** Δrenderer-ext RSS | **+0.0 MB** | **+0.0 MB** | 都平坦 |

### 3.2 1024 MB 档

| 段 | File 版 | ArrayBuffer 对照组 | File 版 / 对照 |
|---|---|---|---|
| **①** 耗时 | **0.70 ms** | **2173.6 ms**（`arrayBuffer()`） | **3105×** |
| **①** Δbacking / ΔRSS | **0.00 MB** / +0.2 MB | **+1024.00 MB** / +1023.6 MB | 0 vs 1024 MB |
| **②** 耗时 | **0.60 ms**（`createObjectURL(file)`） | 982.9 ms（`new Blob`）+ **0.30 ms**（`createObjectURL(blob)`） | — |
| **②** Δheap / ΔRSS | **0.00 MB** / +0.2 MB | 0.00 MB / **+1024.9 MB** | 0 vs 1025 MB |
| **③** 耗时 / 速率 | 3106 ms / 330 MB/s | 2416 ms / 424 MB/s | 1.29× |
| **③** Δrenderer-ext RSS | **+0.0 MB** | **+0.0 MB** | 都平坦 |


**在 ① 和 ② 这两段上，两条曲线明显分开**——这正是题目要求的判据，且分离幅度极大：

- ① 段耗时：1024 MB 档 **0.7 ms（File） vs 2173.6 ms（ArrayBuffer）= 3105 倍**；256 MB 档 0.7 ms vs 536.7 ms = **767 倍**。
- ① 段内存：File 版 Δbacking **0.00 MB** / ArrayBuffer 版 Δbacking **+1024.00 MB**（正好是整份文件）。
- ② 段内存：File 版 Δ **0.00 MB** / ArrayBuffer 版 `new Blob` **+1024.9 MB**。
- ③ 段：两组都平坦，Δrenderer-ext RSS 均为 **+0.0 MB**。

曲线形态（1024 MB 档，renderer-ext RSS 即持有 offscreen 文档的进程）：

```
        t(ms)   File 版 rendererRSS   ArrayBuffer 版 rendererRSS   磁盘已落盘(File版)
           0              231.3 MB                1256.5 MB            1.5 MB
         200              231.3                    1256.5             82.1 MB
         600              231.3                    1256.5            288.0 MB
        1002              231.3                    1256.5            519.0 MB
        1405              231.3                    1256.5            753.8 MB
        1806              231.3                    1256.5            961.7 MB
        2206              231.3                    1256.5           1073.7 MB
        3007              231.3                    1256.5           1073.7 MB
        ─────────────────────────────────────────────────────────────────────
        Δ               +0.0 MB                  +0.0 MB
```

File 版是**一条水平线**：数据从 OPFS 流到下载文件，从未在 renderer 里成形。ArrayBuffer 版只是**整体抬高了 1025 MB**（那 1 GB 在 ① 段就已经躺在进程里了），③ 段本身同样平坦。

---

## 4 对照组是否验证了方法的分辨能力

**验证了，而且是在同一会话、相隔几分钟内用同一台仪器测出来的。**

| 证据 | 数值 | 含义 |
|---|---|---|
| null-op 对照（什么都不分配） | 0.0–0.1 ms，Δheap **0.00**，ΔRSS **0.00** | 仪器不产生虚假读数 |
| ① File | 0.7 ms，Δbacking **0.00 MB** | 仪器在同一会话里报 0 |
| ①M ArrayBuffer | 2173.6 ms，Δbacking **+1024.00 MB** | 同一台仪器报 +1024 MB |
| ①M' vs ① File 的时间比 | **3105×** | 远超任何调度抖动或 CPU 争用能解释的范围 |
| ②M' `createObjectURL(Blob)` | 0.3 ms，Δ **0** | ② 本身与载荷无关，与源类型无关 |

关键是这四条**不是互相独立的断言，而是同一个进程、同一套代码路径、几分钟之内的四次测量**：仪器对空操作读 0，对 File 读 0，对整份 ArrayBuffer 读 +1024 MB。若方法分辨不出来，③ 项会跟 ① File 一样读 0——它没有。

因此 §2 里 ①② 的"0.00 MB"是**仪器有能力测出 1 GB 却读出 0**，而不是"仪器看不见"。

---

## 5 ③ 段的时间序列形态判读

### 5.1 结论：③ 是**流式**消费，不是整份物化

1024 MB 档 File 版，32 个采样点（JS 堆每 100 ms，RSS 每 200 ms）：

- `renderer-ext` RSS **全程 231.3 MB，一个采样点都没动过**（Δ**+0.0 MB**）。
- V8 堆 **0.50 MB 恒定**（Δ **+0.00 MB**）；`backingStorageSize` **1.01 MB 恒定**（Δ **+0.00 MB**）。
- 磁盘上的文件**单调增长**：1.5 → 82 → 188 → 288 → 409 → 519 → 617 → 754 → 856 → 962 → 1066 → 1074 MB，约每 200 ms 推进 110 MB。
- 256 MB 档同样：renderer-ext RSS 230.5 MB 恒定（Δ+0.0），磁盘 2.2 → 33.9 → 98.3 → 131.5 → 197.5 → 234.5 → 268.4 MB。

**1 GiB 的字节从头到尾没有在 renderer 里聚集过。** 若 ③ 要物化，renderer-ext RSS 必须爬升 ~1024 MB；实测爬升 0.0 MB。

ArrayBuffer 版反证同一件事：它的 renderer 在 ③ **开始之前**就已经是 1256.5 MB（① 段读入 1024 MB + ② 段 Blob 拷贝 1024 MB，减去基线），③ 全程仍是 1256.5 MB 不变。**③ 在两个方向上都不是那个花钱的地方。**

### 5.2 那个 +50 MB：出现在 `utility` 进程、与载荷不成比例

File 版 ③ 段总 RSS 在**传输完成后**抬升约 50 MB。逐进程拆开看，它**全部落在 `utility`（下载服务）进程**，且 renderer 完全没动：

| 档 | 进程 | 起 | 峰 | Δ | 载荷 |
|---|---|---|---|---|---|
| 256 MB F | `utility` | 176.9 | 226.3 | **+49.4 MB** | 256 MB |
| 1024 MB F | `utility` | 169.4 | 218.9 | **+49.5 MB** | 1024 MB |
| 256 MB M | `utility` | 177.7 | 177.7 | **+0.0 MB** | 256 MB |
| 1024 MB M | `utility` | 170.1 | 170.1 | **+0.0 MB** | 1024 MB |

判读：**载荷翻 4 倍，这一项只从 49.4 变成 49.5 MB（+0.1 MB）**，所以它**不是载荷物化**，而是一笔与尺寸无关的固定开销；它出现在磁盘已经写满之后（1024 MB 档：磁盘 t≈2206 ms 满，阶跃在 t≈2400 ms），且**只在 File 支撑的 blob 上出现**，内存 Blob 路径上完全没有。

> 这是**实测的形态**；其成因（例如下载完成时的保护性扫描/固定大小缓冲池）本实验**未测**，不作断言。

### 5.3 方法学警告：`bytesReceived` 对 blob URL 不可靠，必须看磁盘

本实验的 ③ 段采样以**下载目录里文件的真实大小**为主通道。理由：`chrome.downloads` 的 `bytesReceived` 在 blob URL 上会在转移早期就跳到 `totalBytes`（因为 blob 的尺寸一开始就已知），不能当作进度。下方原始表里同时给出两者，可以看到 `bytesReceived` 与磁盘字节并不同步，而**磁盘字节才是真进度**。

---

## 6 引用性验证与速度旁证

### 6.1 速度旁证

| 动作 | 载荷 | 耗时 | 速率 |
|---|---|---|---|
| ③ File 版（256 MB） | 256 MB | 1024 ms | 250 MB/s |
| ③ File 版（1024 MB） | 1024 MB | 3106 ms | **330 MB/s** |
| ③ ArrayBuffer 版（256 MB） | 256 MB | 444 ms | 577 MB/s |
| ③ ArrayBuffer 版（1024 MB） | 1024 MB | 2416 ms | **424 MB/s** |
| 纯磁盘拷贝 `cp`（同尺寸，`dd conv=fsync` 源，页缓存热） | 1024 MB | 1837 ms | **557.4 MB/s** |

判读：

- File 版 **330 MB/s** 与 `cp` 的 **557 MB/s 同一量级**（慢 1.7 倍），符合"盘到盘搬运 + blob IPC 开销"，**不符合**内存物化（后者应受 RAM 带宽约束且会伴随 RSS 暴涨）。
- File 版（330 MB/s）**比** ArrayBuffer 版（424 MB/s）**更慢**——这个方向本身就是证据：File 版要**读盘 + 写盘**（2 倍磁盘流量），ArrayBuffer 版只需**从内存写盘**（1 倍）。若 File 版偷偷物化了，它不会更慢。
- 页缓存是热的，`cp` 因此偏乐观；这是本对比的已知偏差，方向上只会**放大** File 版的劣势，不改变结论。

### 6.2 引用性验证（三个变体）


| 变体 | 时机 | 结果 |
|---|---|---|
| **A** 删条目**前**读同一 `File` | — | 成功，sha256 `201932af0bd3336c…` |
| **B** `removeOpfs()` | — | 成功（20.5 ms），`File` 对象仍在（size 268435456） |
| **C** 删条目**后**读同一 `File` | — | **抛 `NotFoundError`**（见下方原文） |
| **D** 删条目**前**调 `download()`… 即条目缺失时才调 | — | **`interrupted` / `NETWORK_FAILED` / bytesReceived=0 / 磁盘 0 字节** |
| **E** `download()` 返回后 **t+8 ms 删除**条目 | 删除时磁盘已写 327680 字节 | **`complete`**，1073741824 字节，4671 ms，逐块校验一致 |
| **F** `download()` 返回后 **t+15 ms 改名**条目 | 改名时磁盘已写 196608 字节 | **`complete`**，1073741824 字节，5013 ms，逐块校验一致 |

变体 C 的原文：

```
page exception: NotFoundError: A requested file or directory could not be found at the time an operation was processed.
```


**变体 B/C/D 合起来给出完整语义：**

1. **`File` 是活句柄，不是快照。** 删掉 OPFS 条目后，同一个 `File` 对象上的 `slice().arrayBuffer()` 直接抛
   `NotFoundError: A requested file or directory could not be found at the time an operation was processed.`
   （删前读同一 `File` 是成功的：sha256 `201932af0bd3336c…`）。**它的字节不在内存里，是按需回读的。**
2. **但下载只需要"调用那一刻"引用可用。** 条目先删再调 `download()` → `state=interrupted`、`error=NETWORK_FAILED`、`bytesReceived=0`、磁盘上一个字节都没有。
3. **调用一旦返回，就再与 OPFS 名字无关。** 在 `download()` 返回后 t+8 ms（此时磁盘刚写 320 KB）删除条目，或 t+15 ms（刚写 196608 字节）改名，**1 GiB 都完整落盘**：4671 ms / 5013 ms，`fileSize=1073741824`，且逐块校验一致（载荷是 1 MiB 随机模板重复，实测首块==第二块==末块，三个 1 MiB 块 sha256 全等）。

所以题目第 8 步的判据需要修正一句：**"删除后不失败"并不等于"启动时做了快照"**。此处不失败，是因为 POSIX 下已打开的 file description 在 unlink 后依然可读——是**持久引用**，不是快照。区分这两个的正是变体 D：条目不存在时 `download()` 立刻失败，说明它**并未**预先持有字节。

### 6.3 一个命名侧的实测观察（不影响任何耗时/内存数字）

题目给的 ③ 请求文件名被改写了一次：File 版请求 `f-1024.bin` → 落盘 `f-1024.bin`（原样）；对照组请求 `m-1024.bin` → 落盘 **`m-1024.txt`**。差别是对照组 `new Blob([buf])` **没有 MIME type**，下载目标判定按 MIME 推了扩展名。尺寸与内容不受影响（`fileSize` 与校验均为 1024 MB / 一致）。这与 captain 提示的 `onDeterminingFilename` 陷阱是**不同机制**，本实验未注册该监听器。另注：传输中文件名为 `Unconfirmed NNNNNN.crdownload`，完成时改名为目标名，属正常行为。

---

## 7 未能测成的部分与原因

1. **2 GiB 档未测。** 被 captain 明确指示收敛到 ≤1 GB（两次容器重置后环境容量与稳定性优先）。**故本报告不含 2 GiB 数据**，任何跨到 2048 MB 的外推都不是实测。
2. **>1 GiB 的 ③ 段形态未测**，因此无法验证"流式"在 2 GiB/4 GiB 是否仍成立。已有的 256 MB / 1024 MB 两档形态一致。
3. **`utility` 进程那 +49.5 MB 的成因未测。** 只测到它的存在、位置（`utility`）、时机（完成之后）与"与载荷不成比例"这一性质。
4. **`cp` 对比的页缓存未清空。** 无法在容器内 drop_caches，故 `cp` 速率偏乐观；已注明偏差方向。
5. **同时存在 CPU/IO 争用。** 另一位实验员（B-memory）在同一时刻运行着自己的 Chrome 实例（实测峰值同机 45 个 chrome 进程）。所有**归属**类测量不受影响（进程树按 pid 隔离），耗时类数字可能被整体抬高；但 §3/§4 的分离幅度是 767×–3105×，远超争用可解释范围。`cp` 对照在全部浏览器退出后测得，无争用。
6. **`getFile()` 在 4 GiB 上的耗时未经我复核。** 兄弟实验报 3 ms；本实验最高只到 1024 MB（0.7 ms）。
7. **变体 B/C/D 的 blob 内容完整性只做了模板周期性校验**（首/中/末块 sha256 相等），未与原始 OPFS 字节做全量比对（源条目已被删除，无法比对）。File 版主实验的 1 MiB 前缀 sha256 与 OPFS 源**逐字节一致**（256 MB 与 1024 MB 两档均 `match:true`）。
8. **`performance.memory` 的枚举键为空数组**（`Object.keys(performance.memory) === []`），但 `usedJSHeapSize` 直接取值可用。

---

## 8 复现步骤

### 8.1 环境准备

```bash
# 1) Xvfb + xauth（扩展需要 headed）
apt-get install -y --no-install-recommends xvfb xauth

# 2) Chrome for Testing 148.0.7778.96（与题目给定 chromium-1223 同版本号）
mkdir -p /opt/cft && cd /opt/cft
curl -sSL -o chrome.zip \
  "https://storage.googleapis.com/chrome-for-testing-public/148.0.7778.96/linux64/chrome-linux64.zip"
python3 -c "import zipfile;zipfile.ZipFile('chrome.zip').extractall('.')"   # 无 unzip 时的回退
chmod +x /opt/cft/chrome-linux64/chrome
/opt/cft/chrome-linux64/chrome --version     # -> Google Chrome for Testing 148.0.7778.96

# 3) Chrome 运行库
apt-get install -y --no-install-recommends \
  libglib2.0-0 libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
  libdbus-1-3 libxcb1 libxkbcommon0 libatspi2.0-0 libx11-6 libxcomposite1 libxdamage1 \
  libxext6 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2 \
  fonts-liberation libxshmfence1
```

### 8.2 目录（全部绝对路径，大文件一律在 `/tmp`）

```
/tmp/aria2-probe/D-file-blob-isolation/
├── ext/{manifest.json,sw.js,offscreen.html,offscreen.js}
├── lib.js  boot.js  runner.js  ref2.js  analyze.js  diag.js
├── profiles/p-<size>          # userDataDir
├── downloads/dl-<size>        # 下载目录（Preferences 指定）
└── results/*.json             # 原始数据
```

### 8.3 启动与驱动

扩展加载 + 裸 CDP（**不用 Playwright**）：

```bash
cd /tmp/aria2-probe/D-file-blob-isolation
xvfb-run -a node runner.js --sizes=256,1024 --refs=1 --refmb=1024
```

`lib.js` 里的启动参数（关键项）：

```js
const args = [
  `--user-data-dir=${profile}`,              // 绝对路径
  `--remote-debugging-port=${port}`,
  '--remote-allow-origins=*',
  '--no-first-run','--no-default-browser-check','--no-sandbox',
  '--disable-dev-shm-usage',
  '--safebrowsing-disable-download-protection',
  '--disable-features=Translate,OptimizationHints,MediaRouter,DownloadBubble,DownloadBubbleV2',
  '--disable-extensions-except=' + ext,
  '--load-extension=' + ext,
  'about:blank',
];
spawn('/usr/bin/xvfb-run', ['-a', CHROME, ...args]);
```

下载目录不走 Playwright，而是写进 profile 的 `Preferences`：

```js
fs.writeFileSync(path.join(profile,'Default','Preferences'), JSON.stringify({
  download: { default_directory: dlDir, prompt_for_download: false, directory_upgrade: true },
  savefile: { default_directory: dlDir },
  profile:  { exit_type: 'Normal', exited_cleanly: true },
}));
```

### 8.4 关键代码

**offscreen 里被测的三个阶段**（`ext/offscreen.js`）：

```js
// ① getFile()：保留 File 引用，使堆增量是"留存成本"
getFileOnce: async (name) => {
  const dir = await getDir();
  const fh = S.fh || (await dir.getFileHandle(name || 'blob.bin'));
  S.fh = fh;
  const t0 = performance.now();
  const f = await fh.getFile();
  const t1 = performance.now();
  S.file = f;                                   // 故意保留
  return { ms: +(t1 - t0).toFixed(4), name: f.name, size: f.size };
},

// ② createObjectURL()：保留 URL
createUrlOnce: async () => {
  const t0 = performance.now();
  const u = URL.createObjectURL(S.file);
  const t1 = performance.now();
  S.blobUrl = u;                                // 故意保留
  return { ms: +(t1 - t0).toFixed(4), urlLen: u.length };
},
```

**对照组的物化两步**：

```js
readWholeArrayBuffer: async () => {
  const t0 = performance.now();
  const buf = await S.file.arrayBuffer();       // 整份读进内存
  const t1 = performance.now();
  S.buf = buf;                                  // 故意保留
  return { ms: +(t1 - t0).toFixed(2), bytes: buf.byteLength };
},
newBlobFromBuf: async () => {
  const t0 = performance.now();
  const b = new Blob([S.buf]);                  // 第二次整份拷贝
  const t1 = performance.now();
  S.blob = b;                                   // 故意保留
  return { ms: +(t1 - t0).toFixed(2), size: b.size };
},
```

**写入 OPFS 必须是分块写**（禁止 `new Blob([全量])`，否则污染后续三段测量）：

```js
writeOpfs: async (totalBytes, chunkBytes) => {
  const fh = await (await getDir()).getFileHandle('blob.bin', { create: true });
  const w = await fh.createWritable();
  const chunk = fill(new Uint8Array(chunkBytes));   // 8 MiB，由 1 MiB 随机模板铺满
  for (let written = 0; written < totalBytes; ) {
    const n = Math.min(chunkBytes, totalBytes - written);
    await w.write(n === chunkBytes ? chunk : chunk.subarray(0, n));
    written += n;
  }
  await w.close();
},
```

**③ 的调用在 service worker**（`ext/sw.js`）：

```js
globalThis.__download = async (url, filename) => {
  const id = await chrome.downloads.download({
    url, filename, conflictAction: 'overwrite', saveAs: false,
  });
  return { ok: true, id };
};
```

**③ 段密集采样（每 100 ms JS 堆 / 每 200 ms RSS）+ 磁盘增长轮询**：

```js
const sampler = new Sampler(cdp, offSession, rootPid, { osEvery: 2 });
sampler.t0 = Date.now();
sampler.start(100);            // 注意：绝不 await（start 返回 sampler 自身，循环在 this._p）
const dl = await evalIn(cdp, swSession, `__download(${JSON.stringify(url)}, "f.bin")`);
for (;;) {
  const st  = await evalIn(cdp, swSession, `__search(${dl.id})`);   // 下载状态
  const dir = dirListing(dlDir);                                    // 真实磁盘进度
  if (st[0].state === 'complete' || st[0].state === 'interrupted') break;
  await sleep(60);
}
await sampler.stop();
```

**进程 RSS（`/proc`，比 `ps` 快约 10 倍，故 RSS 能采到 200 ms）**：

```js
const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
const rest = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
const ppid = +rest[1];            // 字段 4
const rssKB = +rest[21] * 4;      // 字段 24（rss，页）→ KB
```

### 8.5 分析

```bash
node analyze.js     # 打印阶段表 + ③ 段时间序列 + 写出 results/analysis.json
```

### 8.6 踩过的坑（复现时会再遇到）

1. **`Sampler.start()` 若返回循环 promise，`await sampler.start()` 会永久死锁**——现象是 ③ 段永不开始、`chrome.downloads.search({})` 返回空数组。本实验第一轮就死在这里（日志留存于 `results/partial-256-preT3.log`）。改为返回 `this`。
2. **offscreen 文档最初以 `type:"other"` + 空 url 出现**，必须先 attach 到那个状态；因此每次都要重新 `Target.getTargets` 匹配谓词，不能信 attach 时缓存的信息。
3. **`Performance.enable` 在 service worker target 上不存在**，必须容忍失败。
4. **容器无 `unzip` 时 `zipfile.extractall` 不保留可执行位**，要 `chmod +x`。
5. **`/dev/shm` 只有 64 MB**，保留 Playwright 同款默认 `--disable-dev-shm-usage`。

---

## 9 原始数据

原始 JSON：`/tmp/aria2-probe/D-file-blob-isolation/results/`
（`size-256.json`、`size-1024.json`、`ref-delete.json`、`ref-rename.json`、`ref2.json`、`analysis.json`、`summary.json`）
逐采样点数据如下。


#### 9.1 1024 MB — ③ File 版

采样 32 点，时长 3106 ms，速率 330 MB/s，最终 `complete`，fileSize 1073741824，文件名 `f-1024.bin`。

Δrenderer-ext RSS = **+0.0 MB**；Δutility RSS = **+49.5 MB**。

| t (ms) | V8 堆 used (MB) | backing (MB) | renderer-ext RSS (MB) | utility RSS (MB) | 全树 RSS (MB) | 磁盘已落盘 (字节) | state |
|---|---|---|---|---|---|---|---|
| 0 | 0.50 | 1.01 | 231.3 | 169.4 | 1253.1 | 1572864 | — |
| 99 | 0.50 | 1.01 | — | — | — | 36700160 | in_progress |
| 200 | 0.50 | 1.01 | 231.3 | 169.4 | 1258.3 | 82051072 | in_progress |
| 300 | 0.50 | 1.01 | — | — | — | 114294784 | in_progress |
| 401 | 0.50 | 1.01 | 231.3 | 169.4 | 1258.6 | 187629568 | in_progress |
| 502 | 0.50 | 1.01 | — | — | — | 222298112 | in_progress |
| 601 | 0.50 | 1.01 | 231.3 | 169.4 | 1258.6 | 288030720 | in_progress |
| 701 | 0.50 | 1.01 | — | — | — | 364314624 | in_progress |
| 801 | 0.50 | 1.01 | 231.3 | 169.4 | 1258.6 | 408551424 | in_progress |
| 902 | 0.50 | 1.01 | — | — | — | 481951744 | in_progress |
| 1002 | 0.50 | 1.01 | 231.3 | 169.4 | 1258.8 | 519045120 | in_progress |
| 1103 | 0.50 | 1.01 | — | — | — | 581632000 | in_progress |
| 1203 | 0.50 | 1.01 | 231.3 | 169.4 | 1259.1 | 616955904 | in_progress |
| 1304 | 0.50 | 1.01 | — | — | — | 688193536 | in_progress |
| 1405 | 0.50 | 1.01 | 231.3 | 169.4 | 1259.1 | 753795072 | in_progress |
| 1504 | 0.50 | 1.01 | — | — | — | 791281664 | in_progress |
| 1604 | 0.50 | 1.01 | 231.3 | 169.4 | 1259.1 | 856227840 | in_progress |
| 1705 | 0.50 | 1.01 | — | — | — | 883425280 | in_progress |
| 1806 | 0.50 | 1.01 | 231.3 | 169.4 | 1259.1 | 961675264 | in_progress |
| 1906 | 0.50 | 1.01 | — | — | — | 1026424832 | in_progress |
| 2005 | 0.50 | 1.01 | 231.3 | 169.4 | 1253.1 | 1065811968 | in_progress |
| 2105 | 0.50 | 1.01 | — | — | — | 1073741824 | in_progress |
| 2206 | 0.50 | 1.01 | 231.3 | 169.4 | 1253.1 | 1073741824 | in_progress |
| 2306 | 0.50 | 1.01 | — | — | — | 1073741824 | in_progress |
| 2406 | 0.50 | 1.01 | 231.3 | 218.9 | 1303.5 | 1073741824 | in_progress |
| 2506 | 0.50 | 1.01 | — | — | — | 1073741824 | in_progress |
| 2606 | 0.50 | 1.01 | 231.3 | 218.9 | 1303.5 | 1073741824 | in_progress |
| 2707 | 0.50 | 1.01 | — | — | — | 1073741824 | in_progress |
| 2807 | 0.50 | 1.01 | 231.3 | 218.9 | 1303.5 | 1073741824 | in_progress |
| 2906 | 0.50 | 1.01 | — | — | — | 1073741824 | in_progress |
| 3007 | 0.50 | 1.01 | 231.3 | 218.9 | 1303.5 | 1073741824 | in_progress |
| 3108 | 0.50 | 1.01 | — | — | — | 1073741824 | complete |

#### 9.2 1024 MB — ③ ArrayBuffer 对照组

采样 25 点，时长 2416 ms，速率 424 MB/s，最终 `complete`，fileSize 1073741824，文件名 `m-1024.txt`。

Δrenderer-ext RSS = **+0.0 MB**；Δutility RSS = **+0.0 MB**。

| t (ms) | V8 堆 used (MB) | backing (MB) | renderer-ext RSS (MB) | utility RSS (MB) | 全树 RSS (MB) | 磁盘已落盘 (字节) | state |
|---|---|---|---|---|---|---|---|
| 0 | 0.50 | 1025.01 | 1256.5 | 170.1 | 3312.9 | 6291456 | — |
| 100 | 0.50 | 1025.01 | — | — | — | 87556096 | in_progress |
| 200 | 0.51 | 1025.01 | 1256.5 | 170.1 | 3312.9 | 273678336 | in_progress |
| 300 | 0.51 | 1025.01 | — | — | — | 361758720 | in_progress |
| 400 | 0.51 | 1025.01 | 1256.5 | 170.1 | 3312.9 | 467140608 | in_progress |
| 500 | 0.51 | 1025.01 | — | — | — | 515375104 | in_progress |
| 600 | 0.51 | 1025.01 | 1256.5 | 170.1 | 3312.9 | 616562688 | in_progress |
| 700 | 0.51 | 1025.01 | — | — | — | 713031680 | in_progress |
| 800 | 0.51 | 1025.01 | 1256.5 | 170.1 | 3312.9 | 735576064 | in_progress |
| 901 | 0.51 | 1025.01 | — | — | — | 747634688 | in_progress |
| 1001 | 0.51 | 1025.01 | 1256.5 | 170.1 | 3312.9 | 767033344 | in_progress |
| 1102 | 0.51 | 1025.01 | — | — | — | 793247744 | in_progress |
| 1202 | 0.51 | 1025.01 | 1256.5 | 170.1 | 3312.9 | 793247744 | in_progress |
| 1302 | 0.51 | 1025.01 | — | — | — | 793247744 | in_progress |
| 1403 | 0.51 | 1025.01 | 1256.5 | 170.1 | 3312.9 | 793247744 | in_progress |
| 1504 | 0.51 | 1025.01 | — | — | — | 793247744 | in_progress |
| 1604 | 0.51 | 1025.01 | 1256.5 | 170.1 | 3313.2 | 896008192 | in_progress |
| 1705 | 0.51 | 1025.01 | — | — | — | 945291264 | in_progress |
| 1805 | 0.51 | 1025.01 | 1256.5 | 170.1 | 3313.2 | 1043857408 | in_progress |
| 1905 | 0.51 | 1025.01 | — | — | — | 1073741824 | in_progress |
| 2005 | 0.51 | 1025.01 | 1256.5 | 170.1 | 3309.4 | 1073741824 | in_progress |
| 2105 | 0.51 | 1025.01 | — | — | — | 1073741824 | in_progress |
| 2205 | 0.51 | 1025.01 | 1256.5 | 170.1 | 3309.4 | 1073741824 | in_progress |
| 2305 | 0.51 | 1025.01 | — | — | — | 1073741824 | in_progress |
| 2406 | 0.51 | 1025.01 | 1256.5 | 170.1 | 3309.4 | 1073741824 | in_progress |

#### 9.3 256 MB — ③ File 版

采样 11 点，时长 1024 ms，速率 250 MB/s，最终 `complete`，fileSize 268435456，文件名 `f-256.bin`。

Δrenderer-ext RSS = **+0.0 MB**；Δutility RSS = **+49.4 MB**。

| t (ms) | V8 堆 used (MB) | backing (MB) | renderer-ext RSS (MB) | utility RSS (MB) | 全树 RSS (MB) | 磁盘已落盘 (字节) | state |
|---|---|---|---|---|---|---|---|
| 0 | 0.50 | 1.01 | 230.5 | 176.9 | 1251.7 | 2162688 | — |
| 100 | 0.50 | 1.01 | — | — | — | 33882112 | in_progress |
| 199 | 0.50 | 1.01 | 230.5 | 176.9 | 1256.6 | 98304000 | in_progress |
| 300 | 0.50 | 1.01 | — | — | — | 131465216 | in_progress |
| 401 | 0.50 | 1.01 | 230.5 | 176.9 | 1256.6 | 197525504 | in_progress |
| 502 | 0.50 | 1.01 | — | — | — | 234487808 | in_progress |
| 602 | 0.50 | 1.01 | 230.5 | 176.9 | 1253.1 | 268435456 | in_progress |
| 702 | 0.50 | 1.01 | — | — | — | 268435456 | in_progress |
| 802 | 0.50 | 1.01 | 230.5 | 226.3 | 1303.8 | 268435456 | in_progress |
| 901 | 0.50 | 1.01 | — | — | — | 268435456 | in_progress |
| 1000 | 0.50 | 1.01 | 230.5 | 226.3 | 1303.8 | 268435456 | in_progress |

#### 9.4 256 MB — ③ ArrayBuffer 对照组

采样 5 点，时长 444 ms，速率 577 MB/s，最终 `complete`，fileSize 268435456，文件名 `m-256.txt`。

Δrenderer-ext RSS = **+0.0 MB**；Δutility RSS = **+0.0 MB**。

| t (ms) | V8 堆 used (MB) | backing (MB) | renderer-ext RSS (MB) | utility RSS (MB) | 全树 RSS (MB) | 磁盘已落盘 (字节) | state |
|---|---|---|---|---|---|---|---|
| 0 | 0.50 | 257.01 | 487.1 | 177.7 | 1775.4 | 9437184 | — |
| 100 | 0.50 | 257.01 | — | — | — | 95879168 | in_progress |
| 200 | 0.50 | 257.01 | 487.1 | 177.7 | 1775.4 | 200278016 | in_progress |
| 300 | 0.50 | 257.01 | — | — | — | 251133952 | in_progress |
| 401 | 0.50 | 257.01 | 487.1 | 177.7 | 1771.5 | 268435456 | in_progress |


### 9.5 阶段窗口原始值（中位数）


#### 256 MB 档

| 阶段 | 窗口 | V8 堆 (MB) | backing (MB) | 全树 RSS (MB) | usedJSHeap (MB) | heapTotal (MB) |
|---|---|---|---|---|---|---|
| T0 基线 | — | 0.48 | 1.01 | 1249.3 | 1.50 | 1.25 |
| null-op (no allocation at all) | before | 0.48 | 1.01 | 1249.4 | 1.50 | 1.25 |
| null-op (no allocation at all) | raw | 0.49 | 1.01 | 1249.4 | 1.50 | 1.25 |
| null-op (no allocation at all) | retained | 0.48 | 1.01 | 1249.4 | 1.50 | 1.25 |
| (1) opfsHandle.getFile() | before | 0.48 | 1.01 | 1249.4 | 1.50 | 1.25 |
| (1) opfsHandle.getFile() | raw | 0.49 | 1.01 | 1249.3 | 1.50 | 1.25 |
| (1) opfsHandle.getFile() | retained | 0.49 | 1.01 | 1248.6 | 1.50 | 1.25 |
| (2) URL.createObjectURL(file) | before | 0.50 | 1.01 | 1248.7 | 1.51 | 1.50 |
| (2) URL.createObjectURL(file) | raw | 0.50 | 1.01 | 1248.7 | 1.51 | 1.50 |
| (2) URL.createObjectURL(file) | retained | 0.50 | 1.01 | 1248.6 | 1.51 | 1.50 |
| (1M) file.arrayBuffer()  [whole file into JS memory] | before | 0.50 | 1.01 | 1259.6 | 1.51 | 1.50 |
| (1M) file.arrayBuffer()  [whole file into JS memory] | raw | 0.50 | 257.01 | 1515.4 | 257.51 | 1.75 |
| (1M) file.arrayBuffer()  [whole file into JS memory] | retained | 0.50 | 257.01 | 1515.4 | 257.51 | 1.75 |
| (2M) new Blob([whole ArrayBuffer]) | before | 0.50 | 257.01 | 1515.4 | 257.51 | 1.75 |
| (2M) new Blob([whole ArrayBuffer]) | raw | 0.50 | 257.01 | 1832.4 | 257.52 | 1.75 |
| (2M) new Blob([whole ArrayBuffer]) | retained | 0.50 | 257.01 | 1771.3 | 257.51 | 1.75 |
| (2M') URL.createObjectURL(materialised Blob) | before | 0.50 | 257.01 | 1771.3 | 257.51 | 1.75 |
| (2M') URL.createObjectURL(materialised Blob) | raw | 0.50 | 257.01 | 1771.3 | 257.52 | 1.75 |
| (2M') URL.createObjectURL(materialised Blob) | retained | 0.50 | 257.01 | 1771.3 | 257.51 | 1.75 |

#### 1024 MB 档

| 阶段 | 窗口 | V8 堆 (MB) | backing (MB) | 全树 RSS (MB) | usedJSHeap (MB) | heapTotal (MB) |
|---|---|---|---|---|---|---|
| T0 基线 | — | 0.49 | 1.01 | 1248.8 | 1.50 | 1.25 |
| null-op (no allocation at all) | before | 0.49 | 1.01 | 1247.2 | 1.50 | 1.25 |
| null-op (no allocation at all) | raw | 0.49 | 1.01 | 1247.2 | 1.50 | 1.25 |
| null-op (no allocation at all) | retained | 0.49 | 1.01 | 1247.2 | 1.50 | 1.25 |
| (1) opfsHandle.getFile() | before | 0.49 | 1.01 | 1247.2 | 1.50 | 1.25 |
| (1) opfsHandle.getFile() | raw | 0.50 | 1.01 | 1247.3 | 1.51 | 1.25 |
| (1) opfsHandle.getFile() | retained | 0.49 | 1.01 | 1247.3 | 1.50 | 1.25 |
| (2) URL.createObjectURL(file) | before | 0.49 | 1.01 | 1247.5 | 1.50 | 1.25 |
| (2) URL.createObjectURL(file) | raw | 0.50 | 1.01 | 1247.5 | 1.51 | 1.25 |
| (2) URL.createObjectURL(file) | retained | 0.49 | 1.01 | 1247.7 | 1.50 | 1.25 |
| (1M) file.arrayBuffer()  [whole file into JS memory] | before | 0.50 | 1.01 | 1259.3 | 1.51 | 1.50 |
| (1M) file.arrayBuffer()  [whole file into JS memory] | raw | 0.50 | 1025.01 | 2282.9 | 1025.51 | 1.75 |
| (1M) file.arrayBuffer()  [whole file into JS memory] | retained | 0.50 | 1025.01 | 2282.9 | 1025.51 | 1.75 |
| (2M) new Blob([whole ArrayBuffer]) | before | 0.50 | 1025.01 | 2282.8 | 1025.51 | 1.75 |
| (2M) new Blob([whole ArrayBuffer]) | raw | 0.51 | 1025.01 | 3500.8 | 1025.52 | 1.75 |
| (2M) new Blob([whole ArrayBuffer]) | retained | 0.50 | 1025.01 | 3307.8 | 1025.52 | 1.75 |
| (2M') URL.createObjectURL(materialised Blob) | before | 0.50 | 1025.01 | 3309.7 | 1025.52 | 1.75 |
| (2M') URL.createObjectURL(materialised Blob) | raw | 0.51 | 1025.01 | 3309.6 | 1025.52 | 1.75 |
| (2M') URL.createObjectURL(materialised Blob) | retained | 0.50 | 1025.01 | 3308.7 | 1025.52 | 1.75 |


---

## 附：一句话回答题目

> **「创建一个 `blob:` URL」和「消费这个 `blob:` URL」是两件事。**
> 创建侧（① `getFile()` + ② `createObjectURL()`）代价为 **0**：0.5–0.7 ms、0.00 MB 堆、0.00 MB backing，且与文件大小无关（256 MB 与 1024 MB 耗时相同）。
> 消费侧（③）是**流式**的：1 GiB 全程 renderer RSS 平坦 **Δ+0.0 MB**、堆恒为 0.50 MB、磁盘字节单调增长、速率 330 MB/s 与 `cp` 的 557 MB/s 同量级；唯一的固定开销是下载**服务进程**在完成时的一笔 **~49.5 MB**（载荷翻 4 倍仅 +0.1 MB，故非物化）。
> 因此"整条路的全部代价都压在 ③ 上"成立——但 ③ 的代价也不是内存，而是**时间/磁盘带宽**。
