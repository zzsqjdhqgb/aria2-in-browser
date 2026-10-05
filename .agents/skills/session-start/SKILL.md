---
name: session-start
description: Use at the beginning of a session on an existing project, when resuming work after a break, or when a task spans multiple sessions. Establishes a verified baseline before any new work, and maintains the durable state file across sessions.
whenToUse: First action on a non-trivial project; returning to unfinished work; whenever "what was I doing" is unclear.
---

# Session start: never build on an unverified baseline

The failure this prevents is specific and expensive: an agent resumes a project, finds
something broken (or does not notice), and starts adding to it. Anthropic's
long-running-agent write-up states it plainly
([effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)):

> "If the agent had instead started implementing a new feature, it would likely make the
> problem worse."

Their session-start ritual, in order: `pwd` → read the progress file → read the feature
list → `git log --oneline -20` → run the bootstrap/verify script → **only then** pick the
next task.

## Procedure

1. **Orient (cheap, no assumptions).**
   - `pwd`, and confirm you are in the project root.
   - Read the project's context file (`AGENTS.md` / `CLAUDE.md`) — it names the gates and
     conventions. Read `docs/harness/STATE.md` if it exists.
   - `git log --oneline -20` and `git status --short`. Uncommitted changes are the most
     common surprise.
2. **Verify the baseline before touching anything.** Run the project's single gate
   command (see `verify-loop`). Record the result verbatim.
   - **Green** → proceed.
   - **Red** → do **not** start the new task. Report the failing gate and either fix the
     baseline first (if trivial and in scope) or ask. Silently working on top of a red
     baseline means every later signal is uninterpretable.
3. **Reconcile the state file** with reality. State files drift; git does not lie.
4. **Then plan.** Name the next concrete step, not the whole project.

Install this as one command so it cannot be skipped: `templates/session-start.sh` in this
skill.

## The state file

Persist across sessions in a **structured** file, not prose. Rationale from the same
source: models are measurably less likely to inappropriately rewrite structured data
(JSON) than narrative Markdown, so the durable record survives contact with an agent.

Keep it small — it is re-read every session, so it is a recurring context tax:

```jsonc
// docs/harness/STATE.json
{
  "goal": "one sentence",
  "baseline": { "command": "…", "result": "green", "checkedAt": "…" },
  "done":   [ "shipped thing, with the evidence" ],
  "broken": [ "known-broken + how you know" ],
  "next":   "the single next concrete step",
  "constraints": [ "hard-won facts that must not be rediscovered" ],
  "notVerified": [ "what the gate cannot see" ]
}
```

`constraints` is the highest-value field. Anything learned the hard way — "DNR rules
persist across service-worker restarts but in-memory counters do not", "downloads are
renamed to GUIDs under Playwright" — costs a full investigation to rediscover.

## Rules

- **A baseline claim without a command is a rumour.** Record `command` + observed result,
  not "tests pass".
- **Dependencies may not exist.** A fresh clone or container frequently has no
  `node_modules`; a "the tests passed" note from a previous session is then
  unreproducible. Install, then re-measure. Treat prior green claims as unverified until
  you reproduce them in this session.
- **Commit before and after** substantive work. Git is the rollback mechanism that makes
  "revert the bad attempt" possible; without a clean commit, an agent's mistake is
  entangled with good work.
- **Update the state file at the end of the session**, while the details are still in
  context — not at the start of the next one, when they are gone.
