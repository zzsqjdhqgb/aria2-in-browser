# AGENTS.md

Guidance for AI agents working in this repository. Keep this file **small**: every line
is re-sent on every request, and a bloated context file causes the real instructions to be
ignored. Add a line only when it prevents a mistake that nothing else catches.

## What this is

Browser extension (WXT + Manifest V3 + TypeScript). It impersonates an aria2 JSON-RPC
server so UserScripts/AriaNg can talk to it, and forwards the resulting downloads to the
browser's native download manager. It is a compatibility layer, not a download manager:
no BitTorrent, no multi-threading, no FTP.

## Commands

```bash
bash scripts/session-start.sh   # FIRST: orient + verify baseline before any new work
bash scripts/verify.sh          # the gate: tsc + vitest + wxt build (must exit 0)
bash scripts/verify.sh --quick  # types + tests only
bash scripts/eval.sh --dry-run  # list harness regression cases
```

**IMPORTANT: a green `vitest` run does NOT mean the tree is healthy.** The baseline was
measured as tests 99/99 green with `tsc --noEmit` failing on 28 errors. Always run the
full gate from `scripts/verify.sh`, never `vitest` alone, before claiming work is done.

## Where things are

| Path | Role |
|---|---|
| `core/aria2-handler.ts` | JSON-RPC method dispatch — the protocol contract |
| `core/download-manager.ts` | task lifecycle, tabs, DNR rules, downloads API |
| `core/storage.ts`, `core/types.ts` | persistence and the shared type vocabulary |
| `entrypoints/main.content.ts` | MAIN world: intercepts `fetch` / `XMLHttpRequest` / `WebSocket` |
| `entrypoints/bridge.content.ts` | ISOLATED world: relays CustomEvents to the background |
| `entrypoints/background.ts` | service worker: message routing, enable/disable |
| `docs/comms.md` | **authoritative** inter-module protocol and data flow (Chinese) |
| `docs/harness/STATE.json` | durable cross-session state — read it, update it |
| `.agents/skills/` | harness skills; loaded on demand (see below) |

## Non-obvious facts you cannot infer from the code

- **Three worlds, not one.** `fetch`/XHR/WebSocket patching happens in the MAIN world and
  cannot use extension APIs; everything crossing to the background goes through
  `bridge.content.ts` in the ISOLATED world via `CustomEvent` + `runtime.sendMessage`.
  `docs/comms.md` is the protocol authority — read it before changing messaging.
- **Only `localhost:6800` / `127.0.0.1:6800` is intercepted.** Changing the match pattern
  touches the content script *and* the manifest.
- **Downloads are triggered by opening a background tab, deliberately.** `chrome.downloads.download()`
  cannot have its headers modified by `declarativeNetRequest`; a `tabs.create({active:false})`
  navigation *can*. See `KNOWN_ISSUES.md` #1 and #2 — do not "simplify" this back.
- **DNR session rules persist across service-worker restarts, but in-memory state does not.**
  Any counter or map that allocates rule IDs must survive a restart, or it will collide with
  rules that are still installed. `core/download-manager.ts` currently gets this wrong.
- **The test suite mocks the entire `browser`/`chrome` global** (`tests/setup.ts`). It is a
  logic oracle, not a fidelity oracle. Real Chrome rejects duplicate DNR rule IDs and invalid
  enum values, JSON round-trips `storage.local` (the mock returns the same object reference),
  and `tabs.create` returns an empty `url` plus a `pendingUrl`. Do not treat green tests as
  evidence about browser behaviour.

## Skills (load with the `skill` tool)

`verify-loop` (before any "done" claim) · `oracle-fidelity` (when writing or trusting tests) ·
`context-hygiene` (long sessions) · `delegation` (subagents/workflows) ·
`session-start` (resuming work).

## Working agreements

- **Verify before claiming.** Report the exact command and its observed result. Name what is
  *not* verified. Never report done on a partial gate.
- **Never weaken a check to make it pass** — no deleted or loosened assertions, no narrowed
  `include`/`exclude`, no `--passWithNoTests`. Changing a test's expectation requires saying
  why the old one was wrong.
- **Two strikes, then stop.** If the same fix fails twice, write the state to
  `docs/harness/STATE.json` and report instead of guessing a third time.
- **Commit before and after** substantive changes; git is the rollback mechanism.
- Prefer editing existing files over adding abstractions; this codebase is small on purpose.

## When you finish

Update `docs/harness/STATE.json`: `baseline`, `done`, `broken`, `next`, and any new entry in
`constraints`. That file — not the conversation — is what the next session reads.
