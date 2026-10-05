---
name: oracle-fidelity
description: Use when writing, reviewing, or trusting tests that rely on mocks, fakes, stubs, or simulated APIs. Distinguishes a test that measures real behaviour from one that only measures whether your mock was called.
whenToUse: When a test asserts on a mock/fake; when adding tests for an external API (browser, network, filesystem, DB); when a suite is green but bugs still reach users.
---

# Oracle fidelity: is your test measuring anything?

Your tests are the signal your whole harness steers by. A weak oracle does not
merely miss bugs — it **actively certifies wrong work**, which is worse than no test
at all.

Measured evidence that this is the dominant failure mode:

- **Agentless** ([arXiv:2407.01489](https://arxiv.org/abs/2407.01489)): 213 generated
  reproduction tests, but only **94 (44%)** actually validated the correct fix when
  the ground-truth patch was applied.
- **Reflexion** ([arXiv:2303.11366](https://arxiv.org/abs/2303.11366)): self-generated
  tests certified a wrong solution **16.3%** of the time on MBPP — which is exactly
  why its HumanEval number (91.0%) is not transferable.
- Locally measured on a real MV3 extension: real `chrome.tabs.create` returns
  `url: ''` with a separate `pendingUrl`, while the hand-written mock returned the URL
  immediately from its arguments. Real `chrome.declarativeNetRequest` **rejects**
  duplicate rule IDs and invalid enums at runtime; the mock accepted everything.
  Real `chrome.storage.local` JSON round-trips and returns a fresh object; the mock
  returned the **same reference**, so "mutate what you read without calling `set()`"
  passed locally and would fail in the browser.
- The same investigation found a real latent bug the mock structurally could not
  catch: a DNR rule-ID counter reset on service-worker restart collided with
  persisted session rules and broke the first RPC after every restart.

## The classification test

Read each assertion and ask: **what would have to break in production for this to go
red?**

| Verdict | Smell | Example |
|---|---|---|
| **Measures nothing** | asserts the mock recorded a call | `expect(browser.tabs.create).toHaveBeenCalled()` |
| **Measures the mock** | asserts a value the mock itself invented | `expect(res.url).toBe("http://x")` when the mock echoes its args |
| **Measures behaviour** | asserts an outcome a caller could observe | task reaches `complete` after an `onChanged` event is delivered |
| **Measures the contract** | asserts against the *real* system's documented shape | `listMethods()` contains exactly the methods that do not throw |

Detecting the first two is mostly mechanical: **grep the test file for the name of
the mocked object appearing on the right-hand side of `expect`.** If `browser.`,
`chrome.`, `fetch`, or the fake's name is the subject of the assertion rather than a
setup step, the assertion is probably about the mock.

## Raising fidelity, cheapest first

1. **Type-level contract check against the real API.** The highest value-per-minute
   move, and it needs no runtime. For browser code install the official
   `chrome-types` (generated from Chromium's own IDL/JSON schemas, published daily)
   and assert your fake satisfies the real shapes:

   ```ts
   const fakeDownloads = { /* … */ } satisfies Partial<typeof chrome.downloads>
   ```

   Verified to catch missing event members (`removeListener`, `hasListener`), wrong
   return types (`Promise<{id}>` vs `Promise<number>`), and invalid enum literals —
   the same class of error the real runtime rejects.
2. **Copy real error strings into the fake.** A fake that never throws cannot test
   your error handling. Take the actual messages from the real system's docs or
   runtime and make the fake reject the same inputs.
3. **Model the real lifecycle, not just the values.** Ordering, event timing,
   persistence, and restart behaviour are where mocks lie most. For extension
   service workers the load-bearing facts are: the worker terminates after ~30 s
   idle, **all in-memory state is lost**, persisted rules survive, and an incoming
   message wakes it.
4. **Round-trip anything that crosses a serialization boundary.** If the real system
   serialises, the fake must too (structured clone, JSON), so reference-identity bugs
   surface locally.
5. **Dual-run one end-to-end path for real.** Logic belongs in fast unit tests; the
   *contract* belongs in at least one test against the genuine system. For a browser
   extension that means loading the built artifact into a real Chromium.

## Rules

- **A new test must fail before the fix and pass after.** Run it against the unfixed
  code first. A test that passes on both sides proves nothing — this is the 44% trap.
- **Never let an auto-generated test participate in selection** until it has been
  shown to fail on the pre-change code.
- **Relabel, do not delete, low-fidelity tests.** Rename the suite or the file to say
  what it actually covers (e.g. `*.logic.test.ts`), so nobody mistakes it for
  end-to-end confidence.
- **State the fidelity gap in your report**: "verified against the fake; the real
  runtime is not covered by this test."

## When this matters most

Mock-based testing is *fine* for pure logic with no external contract — parsing,
state machines, formatting, arithmetic. It becomes dangerous exactly where this
project lives: browser APIs, network interception, permissions, and process
lifecycle. Spend fidelity effort in proportion to (a) how load-bearing the external
contract is and (b) how weak the local signal is.
