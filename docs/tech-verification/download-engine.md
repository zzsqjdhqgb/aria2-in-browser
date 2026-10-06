# 下载引擎构造方案（实测版）

| 项 | 值 |
|---|---|
| 文档类别 | **构造方案**（由实测确定，非推导） |
| 日期 | 2026-10-06 |
| 证据基础 | `docs/research/experiments/` 下 4 份实验报告（A / B / C / D） |
| 验证环境 | Chrome for Testing **148.0.7778.96**，xvfb / headless，未打包 MV3 扩展 |
| 与概念文档的关系 | 本文实现 `concept-design.md` 的**第三层（下载引擎）**；不涉及第二层 Mock 语义与第一层转发器 |
| 重要限定 | 文中每个数字都标注了出自哪一份实验。**未实测的一律标明"未测"，不得当作结论引用。** |

---

## 1. 一句话结论

**`fetch` 多路 Range → OPFS 暂存 → `getFile()` → `createObjectURL()` → `chrome.downloads.download` 是唯一可行形态，且它被平台强制拆成两个上下文：blob URL 必须由 offscreen document 创建，下载必须由 MV3 service worker 发起。**

它同时拿到三样东西：**多连接下载、免用户手势、落进用户的下载目录**。这三样在此之前没有任何单一方案能同时满足。

---

## 2. 数据流与上下文分工

```
       网络
        │  ① resp.body.pipeTo(opfsWritable)      ← 真流式、带背压，JS 堆不驻留
        ▼
   OPFS 暂存（<id>.part）                        ← 用户不可见，免手势
        │  ② getFile() → File（磁盘文件的活句柄）  ← 0.7 ms，O(1)
        │  ③ createObjectURL(file)               ← 0.6 ms，O(1)，磁盘零增长
        ▼
   blob: URL
        │  ④ chrome.downloads.download({url, filename})   ← 必须由 SW 发起
        ▼
   用户的下载目录
        │  ⑤ 下载 complete → 立即删 OPFS 条目（空间立刻回收）
        ▼
```

### 为什么必须两个上下文（平台强制，不是设计选择）

| 能力 | offscreen document | MV3 service worker |
|---|---|---|
| `URL.createObjectURL` | ✅ | ❌ **`is not a function`**（`[Exposed=(Window,DedicatedWorker,SharedWorker)]`） |
| `chrome.downloads` | ❌ **`undefined`** | ✅ |
| OPFS 写 | ✅ | ✅ |
| OPFS 乱序按偏移写（`createWritable` + `write({position})`） | ✅ | ✅ |
| `createSyncAccessHandle` | ❌ | ❌（**两边都没有**） |
| 寿命限制 | 除 `AUDIO_PLAYBACK` 外**无** | 空闲 30 s / 单请求 5 min |

> offscreen document 里 `Object.keys(chrome)` 实测只有 `["csi","loadTimes","runtime"]`。
> 两个上下文的能力**互补且不可互换**。（实验 A）

**退路（不推荐）**：offscreen 内 `<a download>` 点击也能落盘，10 MB 实测完整；但它绕开 `downloads` API，**没有事件、没有进度、没有暂停取消**，等于放弃 `tellStatus` 那套语义。

---

## 3. 实测约束（每条都能追到实验）

### 3.1 大小：**没有 2 GB 上限**

| 档位 | 结果 |
|---|---|
| 512 MiB / 1 GiB / 1.5 GiB | complete，字节精确 |
| **2 GiB（正好 2³¹）** | complete → **无 2 GiB 常量** |
| 3 GiB | complete |
| **4 GiB（正好 2³²）** | complete → **无 uint32 截断** |
| 4 GiB + 1 B | complete |

（实验 C）

**"2 GB 墙"的真身是另外三件事，都不是文件大小：**

| 真常量 | 值 | 卡的是什么 |
|---|---|---|
| **500 MiB** | **524,288,000 B** | **内存背衬** blob 的下载上限。524,288,000 → complete；**524,288,001 → `NETWORK_FAILED`，0 字节**（1 字节级二分） |
| 2 MiB | 2,097,152 字符 | `url::kMaxURLChars`，只卡**跨 Mojo 的导航类 URL**（`tabs.create`：2,097,149 存活 → 2,097,153 整页死亡）。**连 `data:` URL 下载都不卡** |
| ≈1.997 GiB | 2,143,809,536 B | **连续 `ArrayBuffer` 分配**上限（`new ArrayBuffer(2 GiB−1)` → `RangeError`） |

> **500 MiB 这一条是架构级的**：它意味着"把字节攒在内存里造 blob"的写法（`new Blob([...])`、增量 `new Blob(chunks)`）**永远做不了大文件**，与内存开销无关，是硬顶。

### 3.2 创建：O(1)，与文件大小无关

| 步骤 | 256 MB | 1024 MB | Δheap | Δbacking |
|---|---|---|---|---|
| `getFile()` | 0.7 ms | **0.7 ms（相同）** | 0.00 MB | 0.00 MB |
| `createObjectURL()` | 0.6 ms | 0.6 ms | 0.00 MB | 0.00 MB |

**文件大 4 倍，耗时不变**——若是拷贝，耗时必然随尺寸增长。（实验 D）

**一处概念澄清**：对**已经物化好的** 1 GiB Blob 调 `createObjectURL` 同样只要 0.3 ms / 0.00 MB ⇒ **② 的成本与源无关**；人们通常归给"创建对象 URL"的那 1 GB 开销，**其实全部属于 `new Blob([...])` 那一步**。（实验 D）

### 3.3 消费：流式，RSS 恒定

1 GiB 下载：**3106 ms（330 MB/s）**，**32 个采样点 renderer 进程 RSS 恒为 231.3 MB（Δ+0.0）**，V8 堆恒 0.50 MB，磁盘单调增长（1.5→82→288→519→754→962→1074 MB）。（实验 D）

**方向性证据**：File 版 **330 MB/s** 比 ArrayBuffer 版 **424 MB/s** **更慢**——File 版要读盘 + 写盘，内存版只写盘。**若 File 版偷偷物化，它不会更慢。**（同尺寸 `cp` 557 MB/s）

**整条路的内存代价是常数级的**：后备存储增量 100 MB 档 +1 MB、**500 MB 档仍是 +1 MB（斜率 0）**，renderer RSS +5.6 → +6.1 MB，浏览器进程 +12 → +16 MB。（实验 B）

### 3.4 磁盘：峰值 2.003×，完成即可回收

1 GiB 档逐时点（两轮独立吻合）：

| 时点 | 合计 | 相对文件大小 |
|---|---|---|
| 写满 OPFS 之后 | 1,077,268,480 | **1.003×** |
| `createObjectURL()` 之后 | 不变 | 1.003×（O(1)，不复制） |
| **导出进行中（峰值）** | **2,151,022,592** | **2.003×** |
| OPFS 已删、blob URL 仍存活 | 1,077,243,904 | **1.003×** |

- 写 OPFS 期间**没有**临时交换文件翻倍（全程只有一个 `t/00/00000001` 在长）
- 删掉 OPFS 条目后空间**立刻**回来，且 **blob URL 当刻失效**（`Failed to fetch` + `net::ERR_FILE_NOT_FOUND`）
- ⇒ **回收时机 = 下载 `complete` 那一刻，不必等 `revokeObjectURL`**

（实验 C）

### 3.5 生命周期：引用只需活到"调用那一刻"

| 操作 | 结果 |
|---|---|
| `download()` 返回后 **+13 ms 关掉 offscreen**、**+10 ms revoke blob URL** | 200 MB 完整落盘，sha256 一致（实验 A） |
| `download()` 返回后 **+8 ms 删 OPFS 条目**、**+15 ms 改名** | 1 GiB 完整落盘，逐块 sha256 一致（实验 D） |
| 在调用**之前**销毁 / 删除 | `NETWORK_FAILED` / `interrupted` / 0 字节 |

**并且 `File` 是活句柄，不是快照**：删掉 OPFS 条目后再去读同一个 `File` → 直接抛 `NotFoundError`。所以不是"启动时做了快照"，而是 **POSIX 已打开 fd 的语义**——引用只需在调用那一刻有效。（实验 D）

### 3.6 落盘命名（会咬人的两条）

- **不给 `filename`** → 落盘名是 **blob UUID**
- **源文件 MIME 为空** → 被嗅探成 `text/plain`，**强制追加 `.txt`**——**连显式传 `filename: 'x.bin'` 也会被改成 `x.txt`**（对 aria2 的 `files[].path` 语义是硬伤，必须专门处理）
- 好消息：**OPFS 的内部文件名不会泄漏**到落盘名

（实验 A）

---

## 4. 多连接的实现与被削顶的现实

### 4.1 真实可兑现的并发

```
真实并发 = min(请求数 N, 6, 服务器支持 Range ? ∞ : 1)
```

- **HTTP/1.1 同域 6 条连接**（Chromium `client_socket_pool_manager.cc`）
- **HTTP/2 每 host 1 条连接**，所有流共享同一拥塞窗口（RFC 9113 §9.1）
- **服务器可以无视 `Range`**（RFC 9110 §14.2 `A server MAY ignore the Range header field.`）

⇒ **aria2 的 `split` / `max-connection-per-server` 语义不可原样复现**，按 `concept-design.md` R3 走**伪装还原**。

### 4.2 三条实现纪律

1. **先探测再开多段**：`Range: bytes=0-1` 看是否回 206（Download Accelerator 与 TDM 都这么做）。**不支持 Range 时必须降级单连接，而不是报错**——否则破坏 R10「结果最终兑现」。
2. **分片并发必须与写盘串行化解耦**：一个 stream + 所有写操作排队。默认 `mode:"siloed"` 下并发多 writer 各有 swap file、**最后一个赢**。参考实现 `_writeChain` 范式可直接照抄。
3. **每片校验**：状态码必须 206、`Content-Range` 必须与请求区间吻合、单片字节数不符即抛、**收尾再校验整文件大小**。

（来源：`docs/research/prior-art/needs-C-cookie-multithread.md` §3.6，源码级复核）

---

## 5. 参考实现

**`zettifour/download-accelerator`**（MIT，MV3，v1.2.3，CWS id `blnkpmlpabmgkmkdhkdnnphflbddnhjh`）

可照抄的部分：
- **`_writeChain` 串行写链**——"N 路并发读 + 单 writer 顺序落盘"的标准范式
- **双模式分流**：浏览器模式**绝不自己设 `Cookie` 头**（用 `credentials:'include'`），native 模式才拼 `Cookie:`
- **Range 探测与逐片校验**写法
- 它的 offscreen + OPFS `.part` + `createObjectURL` + `a[download]` 结构与我们的 ① 段同构

**不要照抄**：它的权限集合（`<all_urls>` + `cookies` + `nativeMessaging`）与 R1「免安装」和 Q-D1「只拦一条 URL」冲突。**它 Native Mode 的自述恰好是浏览器天花板的旁证**——作者把"绕开 Chrome 的 HTTP/2 复用、开真正的并行 TCP"当作 native 模式的卖点。

---

## 6. 必须映射成失败的收尾点（R10 / R2）

以下每一处都可能造成"**任务被接受、进度在跑、用户最终拿不到文件**"，必须映射为失败，不得伪装成功：

| 收尾点 | 失败形态 |
|---|---|
| OPFS 写入中断 | 任务失败，清理 `.part` |
| `getFile()` / `createObjectURL()` 抛错 | 任务失败（实验 D：删条目后 `NotFoundError`） |
| `downloads.download()` 返回 `lastError` | 任务失败 |
| 下载 `state === 'interrupted'` | 任务失败，读 `error` 字段 |
| 分片校验不符 / 整文件大小不符 | 任务失败 |
| **OPFS 条目删除失败** | 空间未回收，需告警（不影响结果兑现） |

**注意**：`chrome.downloads` 存在"调用成功但静默失真"（`resume()` 对未暂停项 no-op 却报成功；`saveAs` 在无 UI 场景可能静默 `USER_CANCELED` 且 `lastError` 为 undefined），这些必须在详细设计里逐条处理。（`docs/research/engines/E1-chrome-downloads.md`）

---

## 7. 这套方案**不能**提供什么（须向上层如实声明）

- **不能指定绝对保存路径**：只能 Downloads 的相对子目录 ⇒ `concept-design.md` **R13 的能力声明必须降级**
- **不能决定落盘文件名**（当源 MIME 为空时会被强制加 `.txt`）
- **不能自定义敏感请求头**：`chrome.downloads` 的 `headers` 被 `net::HttpUtil::IsSafeHeader` 卡死（cookie / referer / origin / user-agent / host / content-length 全拒），且 **DNR 改头对 SW 发起的 downloads 不生效**（只在扩展页发起时生效）
- **没有 waiting 态、没有限速、没有校验和、没有 retry API**
- **多连接拿不到 aria2 承诺的收益**（见 §4.1）

---

## 8. 未测 / 待定（不得当作结论引用）

| # | 事项 | 状态 |
|---|---|---|
| U1 | 多路 Range **网络抓取本身**（所有实验都刻意"不引入网络变量"） | **未测** |
| U2 | SW 被回收/被杀时，进行中的下载是否延续 | **未测**（实验 A 全程 SW 未死） |
| U3 | `utility`（下载服务）进程在完成后阶跃 +49.5 MB 的成因（与载荷无关，载荷 ×4 只从 49.4→49.5） | **未测** |
| U4 | 1 GB 以上档的内存梯度（B 收敛在 500 MB；C 在 4 GiB 只测了字节正确性） | 部分未测 |
| U5 | 并发多个下载时的相互影响 | **未测** |
| U6 | `saveAs: true`、浏览器"下载前询问位置"偏好 | **未测** |
| U7 | 其它 Chrome 版本 / Edge / Firefox | **未测**（Firefox 无 `showSaveFilePicker`、无 offscreen，须分列） |

---

## 9. 需要用户裁定的两项

1. **保存目录口径**（直接决定 R13 怎么写）：
   - a) 完全交给浏览器下载设置（本方案现状）
   - b) 每次下载弹一次文件选择器（`showSaveFilePicker`，需手势，体验差）
   - c) 只支持 OPFS + 统一的"导出到下载目录"动作
2. **多段下载是否为默认**：考虑到 §4.1 的天花板与"降级不报错"的要求，是默认开多段并伪装 `connections`，还是默认单段、把多段作为可选增强。

---

## 10. 证据出处

| 实验 | 报告 | 测了什么 |
|---|---|---|
| A | `docs/research/experiments/A-opfs-blob-download-pipeline.md` | 通路可行性、上下文组合矩阵、blob URL 生命周期、增量攒 blob、落盘命名 |
| B | `docs/research/experiments/B-export-memory-curve.md` | 内存曲线（斜率 0）、四组造法对照、CDP JS 堆计数器陷阱 |
| C | `docs/research/experiments/C-blob-size-limit-and-disk-cost.md` | 大小上限（4 GiB 无损）、500 MiB 真常量、磁盘峰值 2.003× |
| D | `docs/research/experiments/D-file-blob-stage-isolation.md` | 三段隔离、O(1) 举证、消费流式、File 活句柄语义、方法分辨力 3105× |

**一条方法学警告（来自实验 B）**：CDP 的 `Runtime.getHeapUsage.usedSize` 与 `Performance.getMetrics.JSHeapUsedSize` **是同一个 V8 计数器，都不含 ArrayBuffer 后备存储**——对一条 500 MB 的物化路径只报 **+0.12 MB**。**只用它们会把明确物化的路径判成"平坦可用"。** 判据必须用 `backingStorageSize`，并**按进程类型拆开**看 RSS（500 MB 档整棵进程树 RSS：本方案 +29 MB，增量攒 chunk +520 MB，而两者"JS 堆都平坦"）。
