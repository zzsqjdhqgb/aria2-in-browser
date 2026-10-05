---
name: verify-loop
description: Use when about to claim work is done, when tests pass but you are not sure the change is correct, or when you catch yourself editing repeatedly without a green signal. Establishes the project's mechanical verification gate and refuses to let a test-only pass count as done.
whenToUse: Before any "done"/"fixed"/"complete" claim; after any edit to source or tests; when a fix has failed twice.
---

# The verify loop

## Why this skill exists (evidence, not vibes)

A model's own judgment about its work is not a verification signal:

- **Reflexion ablation** (NeurIPS 2023, [arXiv:2303.11366](https://arxiv.org/abs/2303.11366)):
  "self-reflection *without* test generation" scored **0.52** on HumanEval-Rust —
  *below* the 0.60 no-reflection baseline. Reflection only helps when a real
  external signal exists.
- **Large Language Models Cannot Self-Correct Reasoning Yet** (ICLR 2024,
  [arXiv:2310.01798](https://arxiv.org/abs/2310.01798)): with no external feedback,
  self-correction *reduced* accuracy on every model and benchmark tested
  (GPT-4-Turbo GSM8K 91.5 → 88.0 → 90.0).
- **SWE-agent** (NeurIPS 2024, [arXiv:2405.15793](https://arxiv.org/abs/2405.15793)):
  removing the post-edit linter cost **3.0 points** on SWE-bench Lite with the model
  held fixed — the single cheapest config change measured in that paper.

Conclusion: **build the external signal; do not ask for another opinion.** "Review
your own work" is not a verification step.

## The three-gate rule

A green test run is **not** sufficient. Measured on a real project (`aria2-browser-shim`):

```
vitest run      -> 99 passed / 5 files   (GREEN)
tsc --noEmit    -> exit 2, 28 errors     (RED)
```

The suite was fully green while the tree did not compile. Any harness whose "done"
condition is `test` alone will report success on a broken tree.

**All three must pass, or the work is not done:**

| Gate | Command (adapt per project) | Catches |
|---|---|---|
| Types | `npx tsc --noEmit` | signature drift, wrong return types, bad enums |
| Behaviour | `npx vitest run` | logic regressions |
| Artifact | `npx wxt build` (or equivalent) | bundler/entrypoint/config breakage |

## Procedure

1. **Find the project's gate.** Read `AGENTS.md`, then `package.json` `scripts`, then
   `scripts/verify.sh` if present. If no such script exists, **write one** — see
   `templates/verify.sh` in this skill. It must be a single command that exits
   non-zero if any gate fails.
2. **Run the gate before editing.** Record the baseline. You cannot tell whether you
   broke something if you never saw the starting state. If the baseline is already
   red, say so and get agreement on scope *before* touching anything.
3. **Edit one thing.**
4. **Re-run the gate.** On failure, feed back the **raw output**: the failing test
   name, the expected-vs-received values, the compiler error with the offending line.
   Do not summarise it into "tests failed" — the verbatim error is the signal.
5. **Only then claim done**, quoting the exact command and its observed result.

## Hard rules

- **Never report done on a partial run.** "Tests pass" when types are red is a false
  claim, not a partial one.
- **Never fix a failing test by weakening or deleting it.** If a test must change,
  state why the old expectation was wrong. A deleted assertion is indistinguishable
  from a lied-about one in the diff.
- **Never mark a gate green by narrowing its scope** (editing `include`/`exclude`,
  adding `--passWithNoTests`, skipping a file). Fixing the gate's scope is a separate,
  announced change.
- **Two strikes, then stop.** If the same fix has failed twice, stop and report what
  you tried and what the gate says. A third guess inside a polluted context is
  negative expected value (see the two-strike rule in the `context-hygiene` skill).
- **Distrust a suspiciously easy green.** A test that passes before your change and
  after it, on code you know you altered, is probably not testing what you think.
  See the `oracle-fidelity` skill.

## Reporting format

End substantive work with exactly this shape, so a human can audit without re-running:

```
Command:  npx tsc --noEmit && npx vitest run && npx wxt build
Result:   exit 0 — tsc clean; 99/99 tests; build ok (228.9 kB)
Baseline: tsc had 28 errors before this change (now 0)
Not verified: <what the gate cannot see — e.g. real-browser behaviour>
```

That last line is mandatory. Naming what is *not* covered is what stops a harness
from over-claiming, and it is where the next verification investment should go.
