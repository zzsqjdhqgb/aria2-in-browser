---
name: context-hygiene
description: Use in long sessions, after large tool outputs, when the conversation feels cluttered, before switching to an unrelated task, and whenever you notice you are repeating an earlier call or forgetting a constraint. Manages the limited attention budget.
whenToUse: Sessions past ~10 tool calls; after a big log/diff/directory dump; on task switches; when a constraint gets violated twice.
---

# Context hygiene: treat context as a budget, not a bucket

Long context is not free capacity. Measured:

- **Context Length Alone Hurts** (EMNLP 2025 Findings,
  [arXiv:2510.05381](https://arxiv.org/abs/2510.05381)): with **perfect retrieval** and
  distractors attention-masked away, accuracy still fell **13.9%–85%** as input grew to
  30k tokens. HumanEval specifically: **−47.6%** (Llama3-8B). The fix is to shorten the
  context, not to retrieve better.
- **The Complexity Trap** (NeurIPS 2025 DL4C workshop,
  [arXiv:2508.21433](https://arxiv.org/abs/2508.21433)): tool observations are **~84%** of
  tokens per turn. Replacing old observations with a placeholder ("observation masking")
  matched LLM summarisation in solve rate at **~50% lower cost**. A rolling window of
  **M=10** turns was best; M=20 was worse.
- **Context Rot** (Chroma, 2025, [trychroma.com](https://www.trychroma.com/research/context-rot)):
  near-miss distractors hurt more than unrelated text, and damage compounds with length.
- Counter-warning from the same masking paper: on a thinking model, masking cost
  **−4.0 pt** (p=0.04). So masking is not unconditionally safe.

## What to mask (old, and never current)

| Mask once stale | Keep verbatim |
|---|---|
| full test/build logs already reasoned about | **the currently failing assertion** |
| whole-file `cat` dumps | the **current edit diff** |
| directory listings, grep dumps | file paths you are actively editing |
| successful command output | the **error that motivated the current fix** |
| superseded diffs | durable decisions (write them to a file first) |

Rule of thumb: keep the last ~10 tool results verbatim; reduce older ones to one line
(`[omitted: vitest run — 84 lines, 99 passed]`). **Never mask the failure you are
working on.**

## Ordering: edges are stronger than the middle

Put non-negotiable constraints where they will be read: invariants **at the top**,
the acceptance criterion **restated at the end of the task message**. Long reference
material belongs on disk with a path, not inline in the middle.

Honesty note ([arXiv:2307.03172](https://arxiv.org/abs/2307.03172)): the famous
U-shaped "lost in the middle" curve is a GPT-3.5-era result and a 2025 replication did
**not** reproduce the position sensitivity. Treat edge placement as cheap insurance,
not as a 20-point gain.

## Write state down before you lose it

Compaction and context resets lose whatever was only in the conversation. Before a
long stretch of work, or when the session is getting heavy, persist:

- decisions made and **why** (including rejected options),
- current failing test name + exact assertion,
- files touched and the next concrete step,
- constraints discovered the hard way (these are the most expensive to rediscover).

Format matters: prefer a **structured file** over prose for machine-read state, because
models are measurably less likely to casually rewrite structured data than narrative
text (see the `session-start` skill's state file).

## Rules

- **Two strikes, then clear.** After being corrected twice on the same issue, stop
  patching. Summarise the state to disk and restart with a clean context. Continuing
  inside a polluted context has negative expected value.
- **Fresh context beats a long context** for review and verification — hand the
  reviewer the artifact and the criterion, not your entire reasoning history.
- **Do not re-read what you already read** in this session unless it changed on disk.
  Re-reading is the most common invisible context leak.
- **Cap your own outputs.** When a command can produce unbounded output, bound it
  (`| tail -40`, `--reporter=dot`, `--quiet`). An agent that dumps 5,000 lines into its
  own context has spent its budget on nothing.
- **Mask, do not summarise, by default.** Summarisation adds a model call, can
  hallucinate, and measured no better than masking.

## Escalation

If context pressure is genuinely unavoidable, say so explicitly and propose the reset
plan, rather than silently degrading. A human told "this needs a clean session" can act;
a human reading a quietly-worse answer cannot.
