# 如何用 Harness 放大一个不够强的模型

**项目**：`aria2-browser-shim`（WXT + MV3 + TypeScript，~2,900 行，伪造 aria2 JSON-RPC → 浏览器原生下载）
**日期**：2026-10-05
**问题**：模型本身不够强。只允许改 prompt / 工具 / 工作流 / 验证回路 / 上下文管理 / 插件 / 流程，不允许训练模型 —— 哪些改动真的有用？
**方法**：18 个并行 agent 做过两轮文献+实践扫描（arXiv / ICSE / NeurIPS / 官方工程博客 / HN），全部结论按"是否有实测数字"和"能否迁移到本项目（小体量、mock 测试）"两级打分。原始记录见 `raw/01-academic-sweep.raw.txt`、`raw/02-practitioner-sweep.raw.txt`、`03-mv3-testing-2026.md`。

---

## 0. 结论摘要（先看这个）

**最反直觉、也最重要的一条**：在所有可直接抄的改动里，**收益最大的是"接口/验证回路"，不是"模型/多智能体"**。同一模型换 harness，SWE-bench Verified 上差 **15~20 个百分点**（GPT-4o：SWE-agent 23.2% vs Agentless 38.8%）[^survey]。而多智能体是**最贵且最不适合本项目的**方向 —— Anthropic 自己的文章就写了"多数编码任务缺少真正可并行的子任务，多智能体不是好选择"，代价约 **15 倍 token**[^multiagent]。

**第二重要**：本项目的**验证器本身不可信**。这是全项目最大的风险，且已有文献量化：Agentless 生成的 213 个复现测试里只有 **44%** 在真补丁下能正确验证；Reflexion 在 MBPP 上自生成测试有 **16.3%** 把错解认证为对[^reflexion]。我们现在的 vitest 全绿，但**测量的不是 aria2 协议语义，而是"我们的 mock 有没有被调用"**。在这个基础上做任何 agent 自动化，都是在放大一个错误的信号。

**第三**：绿色测试给了虚假安全感 —— 我实测发现 `vitest run` **99/99 全绿**的同时 `tsc --noEmit` **28 个错误**。只跑测试就宣布"完成"的回路，会放过一个不能干净编译的代码树。

**优先顺序**（按 证据强度 × 本项目收益 / 成本）：

| # | 机制 | 实测依据 | 成本 | 本项目优先级 |
|---|---|---|---|---|
| 1 | 编辑后强制 `tsc`/lint 门禁 | +3.0 pt（SWE-bench Lite，固定模型）[^sweagent] | 极低（已有工具链） | **P0** |
| 2 | 修 mock 保真度 / 协议契约测试 | Agentless 仅 44% 测试有效；Reflexion 16.3% 假阳性[^agentless][^reflexion] | 中 | **P0** |
| 3 | 陈旧工具输出掩码（保留最近 ~10 轮原文） | 同解率下省 ~50% 成本[^trap] | 低 | **P1** |
| 4 | 上下文文件只放"不可推断事实" + 每条规则转成可执行检查 | Anthropic 官方 + HN 实践双向收敛[^ccbp] | 低 | **P1** |
| 5 | 编辑前"复述失败断言 + 目标行" | 纯长度即导致 13.9–85% 退化，即使完美检索[^ctxlen] | 低 | **P1** |
| 6 | best-of-N + 真 oracle 筛选，替代无限迭代 | Agentless 32%@$0.70 vs SWE-agent 23%@$1.62[^agentless] | 中 | **P2** |
| 7 | 只读子 agent（侦察/验证），硬性输出预算 | 上下文隔离有效，但编码不适合并行[^multiagent] | 中 | **P2** |
| 8 | 并行多写者子 agent | 官方明确不推荐；Cognition 称"非常脆弱"[^cognition] | 高（15× token） | **不做** |

---

## 1. 边界条件（决定了哪些论文结论不能抄）

| 维度 | 本项目实际情况 | 对 harness 的含义 |
|---|---|---|
| 规模 | ~2,900 行，5 个源文件 | **整个仓库装得进上下文**。长上下文类优化的绝对收益远小于 SWE-bench 数字 |
| Oracle 强度 | vitest + **手写 chrome mock** | 逻辑层 oracle 强；MV3 运行时语义 oracle **弱且滞后** → 必须靠"治理"而非"测试"补 |
| 可逆性 | manifest 权限 / DNR 规则 / service worker 生命周期 | 低可逆 → 这些面需要人工 gate |
| 并行度 | 改动高度耦合（manifest ↔ SWE ↔ content script） | 多智能体收益低、协调成本高 |
| 计费 | 疑似订阅制而非按 token | 掩码的收益体现在**延迟与稳定性**，不是钱 |

> 该框架来自 2026 年 harness 综述的 Table V：**oracle 强度**和**动作不可逆性**决定该投入验证回路还是治理闸门[^survey]。

---

## 2. 证据分级：真正有数字支撑的机制

### 2.1 接口（ACI）比模型更值钱 —— 每个配置项都有实测价签

SWE-agent 在同一模型（GPT-4 Turbo）上逐项消融，SWE-bench Lite[^sweagent]：

| 配置项 | 结果 | Δ |
|---|---|---|
| 完整 ACI | 18.00% | 基线 |
| **去掉编辑后 linter 检查** | 15.0% | **−3.0** |
| 完全没有专用编辑工具 | 10.3% | −7.7 |
| 迭代式分页搜索（VSCode 风格） | 12.0% | **−6.0，比没有搜索工具（15.7）还差** |
| 100 行窗口 vs 整文件读取 | 18.0 / 12.7 | −5.3 |
| 折叠最近 5 条以外的观察 | 18.0 / 15.0 | −3.0 |
| 去掉一条示范轨迹 | 16.3% | −1.7 |
| 纯 shell 基线 | 11.0% | 相对 +64% |

**可抄**：① 每次编辑后立刻 `tsc --noEmit`，失败则**拒绝该编辑**并把错误原文+出错片段回灌；② 用精确字符串/行范围替换，永不整文件重写；③ 搜索结果**硬性截断并拒绝**（"匹配过多，请收窄"），不要分页；④ 文件读取给 ~100 行窗口 + 总行数 + 省略标记；⑤ 只保留最近 5 条工具输出原文，更早的压成一行。

> 迭代分页搜索比"没有搜索工具"更差 —— 这是全篇最反直觉的数字。agent 会把预算烧在翻页上。

### 2.2 上下文：稀释与干扰，而非"遗忘"

- **Lost in the Middle**（TACL 2023）：GPT-3.5 在 20 篇文档 QA 上，金标在第 0 位 75.8%、第 9 位 53.8%，而**闭卷是 56.1%** —— 给 20 篇文档反而不如不给[^litm]。2025 年 Chroma 复现**没有**重现这种位置敏感性，所以把"边缘放约束"当作廉价保险，别指望 20 个点[^chroma]。
- **Context Length Alone Hurts**（EMNLP 2025 Findings）：即使**完美检索**、且干扰项被 attention mask 掉，仅长度本身就让准确率掉 13.9%–85%；HumanEval 在 30k token 时 Llama3-8B **−47.6%**[^ctxlen]。这支持"先复述再动手"的两段式调用。
- **The Complexity Trap**（NeurIPS 2025 DL4C workshop）：工具观察占每轮 token 的 **~84%**。把旧观察替换成占位符（observation masking）在 **同解率**下省 ~50% 成本，效果与 LLM 摘要**持平**；最佳滚动窗口 M=10（M=20 反而变差）[^trap]。
  - 反例必须记住：在 Gemini 2.5 Flash (thinking) 上，掩码 **−4.0 pt**（p=0.0406），摘要在该模型上 **−9.0 pt**。**当前失败信息永远不要掩码**。

### 2.3 验证：正确性信号决定一切，自省无用

- **Reflexion 的自我否定**（NeurIPS 2023）：HumanEval 91.0% vs 基线 80.1% 的亮眼数字，**建立在自生成测试之上**；在 MBPP 上反而**低于**基线（77.1 vs 80.1），因为自生成测试有 16.3% 把错解判对。消融表更直接：**"只自省、不给测试信号" = 0.52，低于不反思的基线 0.60**[^reflexion]。
- **ICLR 2024 反证**：无外部反馈的内在自我纠错，在**所有**模型、**所有**基准上让准确率**下降**（GPT-4-Turbo GSM8K 91.5→88.0→90.0；Llama-2 62.0→43.5→36.5）[^selfcorrect]。
- **结论**：不要加"review your own work"步骤。要么给可执行的 oracle，要么给人审闸门。中间态（"你再想想"）按证据是**负收益**。
- **Agentless 的数字**（SWE-bench Lite）：固定三阶段流水线 96/300 = 32.00%，$0.70，78k token；对照 SWE-agent + Claude 3.5 Sonnet 23.00%，$1.62，**521k token** —— 交互式 agent 回路用了 **6.7× token、2.3× 成本**换来更低解率[^agentless]。其补丁验证阶段同样暴露：213 个自生成复现测试只有 **94 个（44%）** 在真补丁下成立。

> **对本项目最直接的一句话**：我们的 vitest + mock 就是 Reflexion 里的"Evaluator"。mock 保真度不够 = MBPP 式的 16.3% 假阳性。这是首要修复项。

### 2.4 多智能体：隔离有用，并行写代码有害

Anthropic 原文可直接引用[^multiagent]：
> "some domains that require all agents to share the same context or involve many dependencies between agents are **not a good fit** for multi-agent systems today" … "**most coding tasks involve fewer truly parallelizable tasks than research**, and LLM agents are not yet great at coordinating and delegating to other agents in real time."
> 成本："agents typically use about **4× more tokens** than chat interactions, and multi-agent systems use about **15× more tokens**."

那条广为流传的 **90.2% 提升**是**厂商内部评测**、任务是**网页研究**（文章自己说不代表编码）、未经同行评审 —— 不要引用为编码收益。Cognition 的《Don't Build Multi-Agents》给出对立但结论一致的建议：默认**单线程线性 agent**，委派只做**只读**[^cognition]。

**可抄的只有两点**：① 只读侦察/验证子 agent + 硬性输出预算（1,000–2,000 token 摘要）；② 显式"投入度表"写进 orchestrator prompt（"单文件改动 = 1 agent，3–10 次工具调用"），别指望 agent 自己判断尺度。

### 2.5 契约式自检：项目自己已经有活生生的例子

本项目 `core/aria2-handler.ts` 就是"绿灯但撒谎"的样本：

| 位置 | 行为 | 问题 |
|---|---|---|
| `system.listMethods` | 返回列表**包含** `aria2.addTorrent` / `addMetalink` | 而这两个方法的实现是 `throw "BitTorrent not supported"` —— **能力自述与方法表自相矛盾**。`listMethods` 是给客户端做能力发现用的机器可读契约 |
| `aria2.changePosition` | `return 0`（"接受但无操作"） | 客户端会认为队列顺序已生效 |
| `aria2.changeUri` | `return [1]` | 伪造了成功语义 |
| `aria2.changeGlobalOption` | `max-concurrent-downloads` 存下来但**不生效**（源码注释自认） | `getGlobalOption` 却宣称 `5` —— 配置谎言 |
| `aria2.getVersion` | `enabledFeatures` 已不含 BitTorrent | ✅ 这项已经修对了（`KNOWN_ISSUES.md` #5 该条已过时） |

源码位置（`core/aria2-handler.ts`）：`addTorrent`/`addMetalink` 抛错见 [L151-L155](core/aria2-handler.ts#L151-L155)，而它们仍被列入方法表 [L310](core/aria2-handler.ts#L310)；`changePosition` 静默返回见 [L300-L302](core/aria2-handler.ts#L300-L302)；`changeUri` 见 [L303-L305](core/aria2-handler.ts#L303-L305)；`max-concurrent-downloads` 的"存而不用"见 [L258](core/aria2-handler.ts#L258) 与 [L269-L271](core/aria2-handler.ts#L269-L271)。

这些**都是**当前 mock 测试无法发现的：测试断言的是"mock 被怎样调用"，而不是"响应是否满足 aria2 协议语义"。这就是一个可以机械化、可以立刻验证的 harness 靶子。

---

## 3. 业界共识（和上面的论文独立收敛到同一处）

三个来源在**同一个结论**上收敛，且这是全部扫描中置信度最高的一条：

> **散文式规则是"建议"，脚本化检查是"保证"。**
> Anthropic 官方原话："Unlike CLAUDE.md instructions which are **advisory**, hooks are **deterministic** and guarantee the action happens."[^ccbp]
> HN 实践者（自述花了约 $2k、6 个月）："**markdown instructions don't work. AI needs enforcement.**"[^hn]

其余高价值实践：

- **上下文文件剪枝判据**（官方给的删除测试）："Would removing this cause Claude to make mistakes?" 臃肿的 `CLAUDE.md` 会让模型**忽略你真正的指令**；只保留**无法从代码推断**的事实，需要强调的行只留**一条** `IMPORTANT`[^ccbp]。
- **跨会话状态要放 JSON，不放 Markdown**：条目全部以 `passes:false` 起步，只允许改状态字段，并明写"删除或修改测试是不可接受的"；理由是"模型更不容易不当改写 JSON 而非 Markdown"[^longrun]（该特性项目实测：跨会话恢复时，agent 会倾向"删掉测试来修测试"）。
- **每会话开始先跑一遍基线**：`pwd` → 读进度文件 → 读 feature-list → `git log --oneline -20` → 跑 `init.sh` → 然后才动手。理由原文："If the agent had instead started implementing a new feature, it would likely make the problem worse."[^longrun]
- **验证闸门四阶梯**：prompt 内检查 → 独立 evaluator → **Stop hook 阻断回合直到脚本通过** → 新上下文验证子 agent；并配刹车："A reviewer prompted to find gaps will usually report some, even when the work is sound... Chasing every finding leads to over-engineering."[^ccbp]
- **两振出局**：同一问题纠正两次后 `/clear`，别在污染上下文里继续[^ccbp]。
- **Prompt 缓存前缀稳定性**（唯一"机械事实"级发现）：请求分块顺序必须是 `[静态 system+tools] → [项目 CLAUDE.md] → [会话事实] → [消息]`；**前三块禁止时间戳 / run id / 无序 map 序列化**；工具列表**全程冻结**，用消息里的 flag 控制能力而不是增删工具定义 —— "adding or removing a tool invalidates the cache for the entire conversation"[^caching]。
- **工具描述即 prompt**：错误信息要写成"修正指令"（点名参数、给正确示例、给下一步），而不是堆栈[^tools]。

**已辟谣 / 别信**：
- `think / think hard / think harder / ultrathink` 阶梯 —— 扫描 agent 抓取现行 best-practices 页面 **740,018 字节**并 grep，`ultrathink`/`think hard` 等**0 命中**；只存在于 2025-04 的存档版本。不要硬编码进 prompt 模板[^ccbp]。
- "150,000 → 2,000 token，省 98.7%" —— 出自原文自称的**假设性示例**，无基准无实测[^mcp]。
- "工具描述精修后 SWE-bench Verified SOTA" —— 无方法学、无效应量[^tools]。

---

## 4. DSH 现状盘点：哪些杠杆已经装着、哪些空着

我 dump 了当前 profile 的合成配置（`dsh --profile web --dump-config`，1,269 行，38 行被 `disabled: true`）。关键发现：

### 已经在跑但"空转"的

| 能力 | 现状 | 为什么没生效 |
|---|---|---|
| **`agent-instructions`（AGENTS.md 自动注入）** | **已启用**（预算 65,536 字节） | `/workspace/AGENTS.md`、`/root/.dsh/AGENTS.md` **都不存在** → 每次请求注入空内容 |
| **`skill-filesystem` + `tool-skill`** | **已启用**（在 `standard` preset 内） | 磁盘上没有任何 `SKILL.md` → 技能目录为空 |
| **`repeat-tool-reminder`** | 已启用，阈值 3/5/8 | 正常工作中 |
| **`tool-result-pruner`** | preset 内启用（8,192 字符阈值，保留头 4,096 / 尾 1,024） | 正常工作中 —— 与论文的 observation masking 同构 |

> **结论**：DSH 已经把"上下文注入"和"按需技能"两条管线接好了，**只是没有内容**。这是零成本、零重启即可启用的最大杠杆 —— 符合论文第 2.2/3 节，且不需要改任何插件。

### 可选但未启用的（需要改 `cordis.patch.yml` + 重启）

| 插件 | 作用 | 对应文献 |
|---|---|---|
| `dsh-hooks-claude-code` / `dsh-hooks-codex` | 跑现成 `hooks.json` 命令钩子，可**阻断**工具调用并把理由回灌模型 | §3 的"确定性 > 建议"，对应 SWE-agent 的 linter 门禁（+3.0） |
| `dsh-experimental-agent-team` | 单会话内命名团队 + 共享任务板 + 持久消息 | 谨慎：§2.4 说编码不适配并行 |
| `dsh-experimental-auto-review` | 每次工具调用前用当前模型评估该动作，允许则全权执行、拒绝则问用户 | 低可逆面的治理闸门 |
| `dsh-tool-ralph` | 固定目标的 fresh-agent 循环，每轮只带上一轮有界报告 | 长任务上下文重置；官方限制"仅在人类明确要求时使用" |
| `dsh-session-checkpoint-policy` | 模型请求前/有外部副作用的工具前落盘，崩溃可恢复 | 长会话可靠性 |
| `dsh-compaction-basic` + `command-compact` | 压缩 + `/compact` 命令 | 本项目树小，收益有限 |

### 结构限制（必须知道）

- **插件的顶层实例被 `dsh-web-app` 显式禁用**（`tool-bash`、`tool-fs`、`agent-instructions`…），能力改由 **agent preset** 提供（`preset-standard`、`preset-ptc`）。所以**要加能力，改 preset 或新建 preset，而不是重新启用顶层行**。
- **preset 是"每会话可选"的**（`dsh-agent-preset-registry`，默认 `standard`）→ 这是做**实验对照组**的天然机制：可以建一个"带强制门禁"的 preset 和一个基线 preset，跑同一批任务比较。
- 顶层 `workflow-ptc` 在 web 下禁用，但 `standard` preset 内**已启用** `tool-workflow` → 我的 `workflow` 工具来自 preset。
- 改 profile 层配置需要**重启**才生效（HMR 只覆盖 client plugin bundle）。

---

## 5. 实验计划（每个都有假设、判据、成本）

先记录**基线**（2026-10-05 实测，已可复现）：

```
vitest run    : 99 passed / 5 files        → 绿
tsc --noEmit  : exit 2, 28 errors          → 红（全部在 tests/integration.test.ts）
wxt build     : ok, .output/chrome-mv3, 228.9 kB
deps          : node_modules 为空，需先 yarn install（400 包 / 167 MiB / 9s）
```
**注意**：本次开工前 `node_modules` 是**空的** —— 任何"我跑过测试了"的历史结论都不可复现。`scripts/verify.sh` 已固化这三道门禁（实测能正确报出"测试绿但类型红"）。

### P0-A：把验证回路变成机械门禁
- **假设**：把"测试通过"升级为"types + tests + build 三绿"，能消灭"绿测试掩盖红类型"这一类漏检。
- **判据**：`bash scripts/verify.sh --quick` 在修好 `tests/integration.test.ts` 的 28 个错误前后分别退出 1 / 0。
- **成本**：已交付 `scripts/verify.sh`；修复 28 个错误约 1 次会话。

### P0-B：修复 oracle 保真度（最高价值）
- **假设**：现有 99 个测试**无法**发现 §2.5 列出的协议谎言；补一层"aria2 协议契约测试"能立刻暴露它们。
- **做法**：① 用 aria2 官方文档定义每个方法的**成功响应形状与错误码**，写成契约测试（`system.listMethods` 必须与真实可调用集合一致；未实现的 `changePosition`/`changeUri` 必须返回错误或诚实降级）；② 用 Chrome 官方 API JSON schema / `@types/chrome` 给 mock 加**保真度断言**，让 mock 漂移变成测试失败；③ 标注"仅依赖 mock 内部"的低置信断言。
- **判据**：契约测试在**当前**代码上必须**失败**（若全绿说明测试无效——这正是 Agentless 的 44% 陷阱）。
- **成本**：中（1–2 次会话）。

### P1-A：AGENTS.md（零重启、零成本）
- **假设**：把"不可推断事实"注入每次请求，能减少重复探索与 MV3 约定错误。
- **内容**：只写代码里读不出来的东西 —— 三层消息链路与各自的 world；`localhost:6800` 是唯一拦截目标；DNR 走 `tabs.create` 而非 `downloads.download` 的**原因**（`KNOWN_ISSUES.md` #1/#2）；改 manifest 权限会同时影响 content script 与 SWE；`docs/comms.md` 是协议权威。**技巧本身（"能否通过测试"变成纪律）不写进 AGENTS.md，而是写进 `verify.sh`。**
- **判据**：对比同一任务在新会话中的文件读取次数 / 工具调用数。
- **成本**：低。

### P1-B：陈旧观察掩码
- **假设**：长会话中把 >10 轮的 vitest/构建输出替换为占位符，能降低漂移且不损解率。
- **注意**：当前失败输出**永不掩码**；本项目 token 花费疑似订阅制 → 收益主要是延迟/稳定性。
- **判据**：token 用量 + 中途跑偏次数。

### P1-C：编辑前复述门禁
- **假设**：强制"先引用失败断言（expected vs received）+ 目标文件行号，再编辑"能减少基于记忆错位的改动（依据：纯长度即致 13.9–85% 退化）。
- **判据**：同一 bug 的首次修复成功率。

### P2-A：best-of-N + oracle 筛选
- **假设**：对同一任务生成 3–5 个候选补丁，用**既有回归套件**筛选，优于单线迭代（Agentless：32%@$0.70 vs 6.7× token 的 23%）。
- **判据**：解率 + 总 token。**要求**：自动生成的测试必须"改前失败、改后通过"才允许参与筛选。

### P2-B：只读子 agent 侦察
- **假设**：把"仓库测绘 / 失败归因"外包给只读子 agent 并限制返回 ≤800 token，能降低主上下文污染。
- **不要做**：并行多写者（manifest + background + popup 同时改）。

### 长期：把上述固化进 DSH profile
在 `cordis.patch.yml` 里新建一个 preset（如 `gated`），内含 hooks 桥与更严的 pruner 阈值，与 `standard` 做 A/B。**需要重启**，且应新建独立 profile（`dsh --profile shim --from-default-profile web`）而不是改动正在给用户提供界面的 `web` profile。

---

## 6. 证据质量与不确定性（请连同结论一起读）

- **厂商博客全部无方法学**。Anthropic 的每一篇都是"内部经验"，没有样本量、没有基线、没有复现；SWE-bench Verified 的"精确精修工具描述后达 SOTA"连效应量都没有。**把它们当作假设来源，不是证据。**
- **最可信的单条**是 prompt 缓存的前缀匹配约束 —— 它是 API 的机械性质，不是性能主张。
- **不要引用为编码收益的数字**：90.2%（多智能体，内部研究评测）、15×/4× token（自报）、98.7%（假设示例）、"humanize 后提升 34%"（ReAct 的 ALFWorld 是文本游戏）。
- **论文本身的时效性**：Lost in the Middle 的幅度是 GPT-3.5 时代，Chroma 2025 未复现位置敏感性；SWE-bench 数字是 2024 年的 Python 仓库 + 隐藏 pytest oracle，绝对值不可用作目标。可信的是**同模型内跨 harness 的对比**（GPT-4o 23.2 vs 38.8），跨行排名仅供参考。
- **两条扫描轨道（OpenAI/Google 阵营、真实用户报告）返回为空**，我已排除其结论；MV3 测试保真度由独立子 agent 调研中。
- **本项目特有**：`node_modules` 曾为空，因此**此前任何"测试通过"的说法都不可复现**；这是把"可复现的验证命令"列为 P0 的直接原因。

---

## 7. 引用来源

[^sweagent]: SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering (NeurIPS 2024) — https://arxiv.org/abs/2405.15793
[^litm]: Lost in the Middle: How Language Models Use Long Contexts (TACL 2023) — https://arxiv.org/abs/2307.03172
[^chroma]: Context Rot: How Increasing Input Tokens Impacts LLM Performance (Chroma, 2025) — https://www.trychroma.com/research/context-rot
[^ctxlen]: Context Length Alone Hurts LLM Performance Despite Perfect Retrieval (EMNLP 2025 Findings) — https://arxiv.org/abs/2510.05381
[^trap]: The Complexity Trap: Simple Observation Masking Is as Efficient as LLM Summarization for Agent Context Management (NeurIPS 2025 DL4C workshop) — https://arxiv.org/abs/2508.21433
[^reflexion]: Reflexion: Language Agents with Verbal Reinforcement Learning (NeurIPS 2023) — https://arxiv.org/abs/2303.11366
[^selfcorrect]: Large Language Models Cannot Self-Correct Reasoning Yet (ICLR 2024) — https://arxiv.org/abs/2310.01798
[^agentless]: Agentless: Demystifying LLM-based Software Engineering Agents — https://arxiv.org/abs/2407.01489
[^survey]: From Question Answering to Task Completion: A Survey on Agent System and Harness Design (2026) — https://arxiv.org/abs/2606.20683
[^codeact]: Executable Code Actions Elicit Better LLM Agents (CodeAct, ICML 2024) — https://arxiv.org/abs/2402.01030
[^react]: ReAct: Synergizing Reasoning and Acting in Language Models (ICLR 2023) — https://arxiv.org/abs/2210.03629
[^multiagent]: How we built our multi-agent research system (Anthropic, 2025-06-13) — https://www.anthropic.com/engineering/multi-agent-research-system
[^ccbp]: Best practices for Claude Code (Anthropic; live page, canonical code.claude.com) — https://code.claude.com/docs/en/best-practices
[^ctxeng]: Effective context engineering for AI agents (Anthropic, 2025-09-29) — https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
[^longrun]: Effective harnesses for long-running agents (Anthropic, 2025-11-26) — https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
[^tools]: Writing effective tools for agents — with agents (Anthropic, 2025-09-11) — https://www.anthropic.com/engineering/writing-tools-for-agents
[^skills]: Equipping agents for the real world with Agent Skills (Anthropic, 2025-10-16) — https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills
[^mcp]: Code execution with MCP: Building more efficient agents (Anthropic, 2025-11-04) — https://www.anthropic.com/engineering/code-execution-with-mcp
[^caching]: Lessons from building Claude Code: prompt caching is everything — https://claude.dev/blog/lessons-from-building-claude-code-prompt-caching-is-everything/
[^cognition]: Don't Build Multi-Agents (Cognition, 2025-06-12) — https://cognition.com/blog/dont-build-multi-agents
[^hn]: Hacker News discussion on context engineering / agent context windows — https://news.ycombinator.com/item?id=45418251
