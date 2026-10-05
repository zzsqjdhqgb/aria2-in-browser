# The harness

This directory documents the **portable AI-coding harness** applied to this repository.
The harness is not a tool you install — it is a small set of files that make an agent's
work *checkable*. Everything here is meant to be copied to other projects.

## The idea in one paragraph

A model's opinion about its own work is not evidence. The literature is unambiguous:
self-reflection with no external signal scores **below** doing nothing
([Reflexion ablation](https://arxiv.org/abs/2303.11366): 0.52 vs 0.60), and intrinsic
self-correction *reduces* accuracy on every model and benchmark tested
([ICLR 2024](https://arxiv.org/abs/2310.01798)). So a harness should not ask the agent to
try harder — it should **manufacture external signals, make them impossible to fake, and
hand them back verbatim**. The same model moves 15–20 points on SWE-bench Verified purely
from harness design ([survey](https://arxiv.org/abs/2606.20683): GPT-4o 23.2% under
SWE-agent vs 38.8% under Agentless).

## Layers

| Layer | File(s) | Needs restart? | Enforced by |
|---|---|---|---|
| Context | `AGENTS.md` | no | injected every request by DSH |
| Skills | `.agents/skills/*/SKILL.md` | no | discovered live; loaded on demand |
| Gate | `scripts/verify.sh` | no | exit code |
| Entry ritual | `scripts/session-start.sh` | no | exit code (refuses on red baseline) |
| State | `docs/harness/STATE.json` | no | read at session start; updated at session end |
| Measurement | `scripts/eval.sh` + `tests/cases.json` | no | deterministic per-case check |

Everything in the table needs **no restart** — that is deliberate. DSH reads skills,
`AGENTS.md`, and files from disk live; only profile-level plugin changes (hooks, presets)
require a restart. Prefer the live surfaces.

## Design rules this harness follows

1. **Enforcement over prose.** A rule that nothing checks is a suggestion. "Always run the
   typecheck" belongs in `verify.sh`, not in a paragraph. Anthropic's own docs draw this
   line ("CLAUDE.md instructions … are advisory, hooks are deterministic") and practitioners
   converge on it independently.
2. **The context file stays small and non-inferable.** It exists for facts the code cannot
   tell you: which world a script runs in, why the tab-based download path is deliberate,
   that DNR rules outlive the service worker. Anything derivable from the repo does not
   belong there — a bloated context file causes real instructions to be ignored.
3. **Prefer a deterministic check to a judgement call.** `verify.sh` exits non-zero; that is
   not arguable. `eval.sh` prefers a `cmd` check over a `regex` check for the same reason.
4. **Measure the harness, not the vibes.** `tests/cases.json` is a fixed task set so a change
   to the harness can be shown to help or hurt. Without it, "the new skill feels better" is
   the only available evidence.
5. **Name what is not verified.** Every report ends with the limits of its own oracle.
   Over-claiming is the failure mode a harness exists to prevent.

## Files

| File | Purpose |
|---|---|
| `STATE.json` | Durable cross-session state: baseline, done, broken, next, constraints, notVerified. Structured rather than prose on purpose — models rewrite narrative Markdown far more casually than JSON. |
| `../../AGENTS.md` | The context file. Read by DSH and injected into every request. |
| `../../scripts/verify.sh` | The gate. types + tests + build. The single definition of "done". |
| `../../scripts/session-start.sh` | Orient → verify baseline → reconcile state. Exits 1 on a red baseline so work cannot silently start on top of breakage. |
| `../../scripts/eval.sh` | Runs `tests/cases.json` through `dsh --profile headless --json` in isolated copies, judges each case deterministically, and compares two runs. |
| `../../tests/cases.json` | The fixed task set. |
| `../../.agents/skills/` | `verify-loop`, `oracle-fidelity`, `context-hygiene`, `delegation`, `session-start`. |

## Porting to another project

1. Copy `scripts/verify.sh` and edit the three gate commands for that toolchain
   (typecheck / test / build). Keep the three-gate structure.
2. Copy `scripts/session-start.sh`; it needs no edits.
3. Copy `scripts/eval.sh` and `tests/cases.json`; write 3–5 cases with `cmd` checks.
4. Write an `AGENTS.md` with **only** what is not inferable: the commands, the module map,
   and the traps that cost real time. Delete anything the code already says.
5. Copy `.agents/skills/` as-is. The skills are project-agnostic.
6. Create `docs/harness/STATE.json` and record the real baseline — including whether it is
   currently red. A harness that starts by lying about its starting state is worse than none.

## Known weaknesses of this harness

Recorded here so the next session does not over-trust it:

- **The test oracle is weak.** `tests/setup.ts` mocks the whole `browser` global. Real
  Chrome rejects duplicate DNR rule IDs, JSON round-trips `storage.local`, and returns an
  empty `url` with a separate `pendingUrl` from `tabs.create`. See `oracle-fidelity`.
- **No real-browser test exists.** Headless Playwright *can* load this extension
  (`channel: 'chromium'`, never the default headless shell, never `channel: 'chrome'`), but
  that spec has not been written.
- **The eval cases are smoke tests, not a benchmark.** Five cheap cases catch harness
  regressions; they do not measure capability. Two of them (`001`, `005`) both key on the
  same "tests green, types red" fact and are partly redundant.
- **Case `004` is close to unfalsifiable** — it passes by reading a state file this harness
  created. Treat it as a regression guard on the state file, not as a capability test.
- **No profile-level enforcement yet.** `dsh-hooks-claude-code` can block a tool call using
  an existing `hooks.json`, which would make the gate genuinely non-skippable rather than
  merely documented. That needs a profile edit and a restart, so it is deliberately deferred.

## Measuring a harness change

```bash
bash scripts/eval.sh --label before
# … change the harness (add a skill, tighten AGENTS.md, add a case) …
bash scripts/eval.sh --label after
bash scripts/eval.sh --compare before after
```

Comparison prints per-case pass/fail transitions, wall time, tool-call count, and token
totals. Treat a single run per label as a weak signal: model output varies. A change is
only interesting when it flips a case consistently across repeated runs.
