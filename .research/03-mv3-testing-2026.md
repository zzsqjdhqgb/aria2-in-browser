# Testing a WXT + MV3 extension in 2026 (and verifying it without a human)

Research date: **2026-10-04**. Every claim tagged **[measured]** was reproduced in this container
(Debian, no display, root) with Playwright 1.63.0 / Chromium **153.0.8010.12** / Chrome for Testing
**154.0.8037.97**, jsdom **30.1.2**, happy-dom **20.14.5**, `@webext-core/fake-browser` **1.5.2**
(the version WXT 0.20.x installs). Everything else is cited to a primary source.

Repo under discussion: `wxt ^0.20.18` + `vitest ^4.1.10`, hand-written `chrome` mock in
[`tests/setup.ts`](../tests/setup.ts), 1,528 lines of tests, 0 real-browser tests.

---

## Bottom line

1. Your mock is **not trustworthy for the four APIs that carry the extension's risk**
   (`downloads.*`, `tabs.create/remove`, `declarativeNetRequest.updateSessionRules`, service-worker
   lifetime). It is fine for pure logic.
2. Playwright **can** load your unpacked MV3 build fully headless in a container — but *only* with
   the full Chromium build (`channel: 'chromium'`), never with the default headless shell, and never
   with Chrome/Chrome-for-Testing. I verified all three cases.
3. I found a **real latent bug in this repo** that the mock structurally cannot catch (DNR session-rule
   ID collision after a service-worker restart). Details in Q3.
4. There is **no** recognized standard, tool, or generator for "mock fidelity" of `chrome.*`.
   The cheapest real defense is `chrome-types` + a type-level contract check, which I verified works.

---

## Q1 — First-class ways to test a WXT/MV3 extension

| Approach | Status 2026 | Headless container? | Verdict |
|---|---|---|---|
| WXT `WxtVitest()` + `fakeBrowser` ([docs](https://wxt.dev/guide/essentials/unit-testing)) | Official WXT; `@webext-core/fake-browser` 2.0.1 published **2026-07-26**, repo pushed 2026-08-08 | yes (Node) | Good for `storage`/`alarms`-style logic. **Useless for `downloads.*` and DNR** — see below. |
| Vitest + hand-written mock (current) | you own it | yes | Fine for pure logic only. |
| `wxt build` + Playwright unpacked ([WXT's own E2E guide](https://wxt.dev/guide/essentials/e2e-testing)) | WXT: *"Playwright is the only good option for writing Chrome Extension end-to-end tests."* | **yes**, with `channel: 'chromium'` | **The real answer.** |
| Puppeteer ([Chrome's guide](https://developer.chrome.com/docs/extensions/how-to/test/puppeteer)) | 25.12.0 (2026-09-23); `enableExtensions` + `installExtension` since **24.8.0 / 2025-05-02** | yes, `headless: true` | Equivalent, needed only if you want real Chrome via CDP. |
| Selenium / WebDriverIO | listed by [Chrome's E2E page](https://developer.chrome.com/docs/extensions/how-to/test/end-to-end-testing) | possible | Chrome explicitly warns ChromeDriver *"attaches a debugger to all service workers preventing them from being stopped"*. Avoid for MV3. |
| `sinon-chrome` | **dead**: 3.0.1 published 2019-04-01, repo last commit 2021-07-12, 37 open issues | n/a | Don't. |
| `jest-webextension-mock` | alive-ish: 4.2.0 published **2026-06-28**, maintained at `RickyMarou/jest-webextension-mock` | n/a | Jest-flavoured; rejects/ignores most calls. |
| `vitest-chrome` | **dead**: 0.1.0 published 2023-08-25 | n/a | Don't. |
| `vitest-chrome-mv3` | 1.0.0 published 2025-11-19, repo has **0 stars** | n/a | Unproven. |
| `vitest-webextension-mock` | 0.0.7 published 2024-04-02 | n/a | Stale. |
| `mockzilla-webextension` | 0.15.0 published 2022-07-25 | n/a | Dead. |
| Mozilla `web-ext` | 10.7.0 (2026-09-21) | Firefox only | WXT already depends on `web-ext-run` internally (`wxt/dist/core/runners/web-ext.mjs`). **WXT exposes no public launcher API** — `package.json#exports` has only `.`, `./utils/*`, `./browser`, `./testing*`, `./modules`. So the "launcher API" you asked about does not exist publicly. |

### The headline fact about WXT's own recommended mock

`@webext-core/fake-browser` **does not implement the APIs this extension depends on.** Direct probe
against the installed package (`lib/index.mjs`):

```
THROW downloads.download    -> Browser.downloads.download not implemented.
THROW downloads.search      -> Browser.downloads.search not implemented.
THROW tabs.remove(1)        -> Cannot read properties of undefined (reading 'id')
THROW dnr.updateSessionRules-> Browser.declarativeNetRequest.updateSessionRules not implemented.
OK    tabs.create           -> {"highlighted":false,...,"id":1,"url":"about:blank"}
OK    storage.local.set/get -> {"a":1}
THROW runtime.sendMessage   -> No listeners available
```

The bundle contains **966 `not implemented` throws**. So switching from your hand-written mock to
WXT's official recommendation would break your suite rather than fix it. Cost of the check: 2 minutes.

**[measured]** Also: `fakeBrowser.storage.local.set({u: undefined})` drops the key (matches Chrome),
but it stores objects **by reference**, whereas Chrome JSON-round-trips them.

---

## Q2 — Headless unpacked MV3 in a container: exact flags and gotchas

### What works [measured]

```js
// playwright fixtures — VERIFIED working in a display-less Debian container
const context = await chromium.launchPersistentContext('', {
  channel: 'chromium',                 // <- REQUIRED. full Chromium build, not chromium-headless-shell
  headless: true,
  args: [
    `--disable-extensions-except=${path.resolve('.output/chrome-mv3')}`,
    `--load-extension=${path.resolve('.output/chrome-mv3')}`,
  ],
});
let [sw] = context.serviceWorkers();
if (!sw) sw = await context.waitForEvent('serviceworker');   // MV3 service worker
const extensionId = sw.url().split('/')[2];
```

Results in this container (Chromium 153.0.8010.12, Playwright 1.63.0, no `$DISPLAY`):

| Launch config | Result |
|---|---|
| default `headless: true` (no channel) | launches `chromium_headless_shell`; **service worker never appeared** (extension ignored, no error) |
| `channel: 'chromium'`, `headless: true` | ✅ SW target present, `downloads`/`tabs`/DNR/content scripts all worked |
| `channel: 'chromium'`, `headless: false`, args `--headless=new` | ✅ works; SW present, `evaluate()` works |
| `channel: 'chromium'`, `headless: false`, **no display** | ❌ fails to launch (missing X server) |
| `channel: 'chrome'` (Chrome for Testing **154**), `headless: true` + `--load-extension` | ❌ **silently ignored** — no SW, no error message |

Why: Playwright 1.49 replaced old headless with a separate `chromium-headless-shell` build
([playwright#33566](https://github.com/microsoft/playwright/issues/33566)). The headless shell is the
old headless browser and never supported extensions. Playwright's docs now say:
*"Note the use of the `chromium` channel that allows to run extensions in headless mode"* and
*"Google Chrome and Microsoft Edge removed the command-line flags needed to side-load extensions, so
use Chromium that comes bundled with Playwright"* — [playwright.dev/docs/chrome-extensions](https://playwright.dev/docs/chrome-extensions).

⚠️ **WXT's own Playwright example is headed** (`headless: false`, no channel), so it does **not** work
in a headless container as written:
[`examples/playwright-e2e-testing/e2e/fixtures.ts`](https://github.com/wxt-dev/examples/blob/main/examples/playwright-e2e-testing/e2e/fixtures.ts).

⚠️ Chrome's docs are stale on the flag name. They still say *"Start Chrome using the `--headless=new`
flag (headless currently defaults to 'old', which does not support loading extensions)"*
([end-to-end-testing](https://developer.chrome.com/docs/extensions/how-to/test/end-to-end-testing)).
In Chromium 153 `--headless` **is** new headless and `--headless=new` is still accepted [measured].
`--headless=old`/`chrome-headless-shell` are the ones that can't load extensions.

### Docker / system deps [measured]

First launch failed with `error while loading shared libraries: libglib-2.0.so.0`. Fix:

```bash
npx playwright install --with-deps chromium     # or `npx playwright install-deps chromium`
```

Headed fallback needs Xvfb **and `xauth`** — `xvfb-run` failed with `xauth command not found` until
`apt-get install -y xauth`.

### If you must use real Chrome (not bundled Chromium)

`--load-extension` is gone from branded Chrome/Chrome-for-Testing (Chrome 137+). The replacement is the
experimental CDP domain:

- [`Extensions.loadUnpacked`](https://chromedevtools.github.io/devtools-protocol/tot/Extensions/) —
  *"Installs an unpacked extension from the filesystem similar to `--load-extension` CLI flags."*
- **[measured]** on Chrome for Testing 154: `Extensions.loadUnpacked {path}` → `{"id":"ogkcmio…"}` — works.
- Puppeteer wraps it as `browser.installExtension(path)` / `launch({enableExtensions:[path]})`
  (added in **v24.8.0, 2025-05-02**,
  [CHANGELOG](https://github.com/puppeteer/puppeteer/blob/main/CHANGELOG.md),
  [`cdp/Browser.ts`](https://github.com/puppeteer/puppeteer/blob/main/packages/puppeteer-core/src/cdp/Browser.ts)).
  `enableExtensions: true` only avoids pushing `--disable-extensions`
  ([`ChromeLauncher.ts` L285](https://github.com/puppeteer/puppeteer/blob/main/packages/puppeteer-core/src/node/ChromeLauncher.ts)).
- Puppeteer headless: `headless: true` = new headless, `headless: 'shell'` = old headless
  ([pptr.dev](https://pptr.dev/api/puppeteer.launchoptions#headless)) — `'shell'` cannot load extensions.

### Gotchas that will bite you specifically [measured]

1. **Playwright renames every download.** `downloads.download({filename:'aria2shim/name.bin'})` landed at
   `/tmp/playwright-artifacts-*/8e91ee99-….bin` (a GUID). Mechanism: Playwright sends
   `Browser.setDownloadBehavior{behavior:'allowAndName'}` whenever `acceptDownloads === 'accept'`
   (`playwright-core/lib/coreBundle.js`). Do **not** assert on `onChanged.filename` under Playwright.
2. **Playwright's attachment keeps the MV3 service worker alive forever.** With `sw.evaluate()` being
   called, my SW survived 165 s of pure idleness and never emitted `Target.targetDestroyed`. Without any
   debugger attached, the same extension died **30.0 s** after its last event. Chrome documents the same
   trap for Selenium/ChromeDriver. Force-terminate instead (see Q3).
3. Extension ID is random per profile; set a `key` in the manifest for a stable ID
   ([Chrome docs](https://developer.chrome.com/docs/extensions/how-to/test/end-to-end-testing#setting-an-extension-id)).

---

## Q3 — Fidelity gap between your hand-written mock and real Chrome

### Measured divergences (all Chromium 153, headless, real extension)

**`chrome.downloads`**
| Your mock | Real Chrome [measured] |
|---|---|
| `onCreated`/`onChanged` are `vi.fn()` that store listeners; nothing ever fires | `onCreated` fires **6.4 ms** after `download()` and *before* it resolves; then `onChanged` deltas: `filename` (`""` → real path), `fileSize`/`totalBytes`, then `state: in_progress → complete` + `endTime` |
| nobody models `danger`, `exists`, `mime`, `startTime`, `incognito` | `danger:'safe'`, `mime:'application/octet-stream'`, `exists:true` |
| invalid input always "succeeds" | `bad URL` → `Invalid URL`; `filename:'../escape.bin'` → **`Invalid filename`**; `data:` URL → completes (14 bytes); `ftp://` → accepted, fails later |
| no quota/limit modelling | session DNR limit: 5001 rules → **`Session rule count exceeded.`**; storage: 10 MiB → **`Resource::kQuotaBytes quota exceeded`** |

**`chrome.tabs`**
| Your mock | Real Chrome [measured] |
|---|---|
| `create` → `{id: 999, ...opts}`, so `tab.url` is set immediately | `{id: 1079865389, status:'loading', url:'', pendingUrl:'http://…', windowId:…, index:1}` — **`url` is empty, use `pendingUrl`** |
| `remove` always resolves | `remove` twice → rejects `No tab with id: …` |
| no `onRemoved` listener in the mock at all | `onRemoved` fires with `{windowId, isWindowClosing}` |

**`chrome.declarativeNetRequest`** — *the biggest gap*
| Your mock | Real Chrome [measured] |
|---|---|
| `updateSessionRules` = `vi.fn(() => Promise.resolve())`; accepts anything | validates the whole rule at runtime: empty `modifyHeaders` → `Rule with id 2 does not specify a value for "action.requestHeaders" or "action.responseHeaders"…`; bad enum → `resourceTypes[0]: Value must be one of csp_report, font, image, main_frame, …` |
| duplicate IDs never possible (mock resets per test) | `addRules:[{id:42},{id:42}]` → **`Rule with id 42 does not have a unique ID.`**; and a *later* call re-adding id 5 → **`Rule with id 5 does not have a unique ID.`** (not replace) |
| rule effects unobservable | header injection is real and immediate: `x-aria-probe: injected` observed on SW `fetch`, on extension-page navigation, and on page `fetch`, **20 ms** after `updateSessionRules` resolved |
| — | `urlFilter` is a *pattern*, not a literal: `urlFilter:'http://127.0.0.1:18080/echo?a=1*'` also matched `?a=1ZZZ` |

> **Concrete latent bug found in this repo (mock cannot see it).**
> [`core/download-manager.ts:23`](../core/download-manager.ts#L23) sets `private ruleIdCounter = 1` — a
> class field, so it **resets on every service-worker start**. Session DNR rules **persist across SW
> restarts**. [`core/download-manager.ts:103`](../core/download-manager.ts#L103) calls `injectHeaders`
> *outside* the `try` block, and `updateSessionRules` with an existing id rejects (measured above). So
> the first `create()` after a SW restart collides with rule id 1 and the whole aria2 RPC fails.
> Worse, [`core/download-manager.ts:56`](../core/download-manager.ts#L56) restores tasks with
> `_ruleIds: []`, so rules created before the restart are **never removed** → they leak toward the
> 5,000 session-rule limit ("Session rule count exceeded", measured).
> Your mock returns success for all of this.

**`chrome.storage.local`**
| Your mock ([`tests/setup.ts`](../tests/setup.ts)) | Real Chrome [measured] |
|---|---|
| stores objects **by reference**; `get` returns the same object | JSON round-trip: return a fresh copy every read |
| `set({u: undefined})` keeps the key | key silently dropped; functions dropped; `Map` → `{}`; `Date` → `"[object Object]"` |
| `onChanged` listeners registered but never invoked | `onChanged` fires in the **same context** that wrote, with `{oldValue,newValue}` for both `set` and `remove` |
| no quota | `Resource::kQuotaBytes quota exceeded` |

**MV3 service-worker lifetime** — measured with a raw CDP launcher (no debugger attached), polling
`/json/list` per extension ID:

```
1.5s   SW UP   (mine + 2 component extensions)
3.0s   wake (no WebSocket)
34.5s  SW DOWN mine  -> 31.5 s after the last event   (documented 30 s idle timeout)
63.0s  wake with WebSocket ping every 10 s
64.5s  SW UP
153.1s still UP -> 88.6 s alive                       (Chrome 116+ WebSocket keepalive)
153.1s wake with ws=0 (closes socket)
183.1s SW DOWN -> 30.0 s after the socket closed
```

This matches Chrome's docs exactly: terminate after 30 s idle, 5-minute per-request cap, 30-second
fetch cap; *"Active WebSocket connections now extend extension service worker lifetimes"* since
Chrome 116 ([lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle),
[websockets how-to](https://developer.chrome.com/docs/extensions/how-to/web-platform/websockets)).
For this extension that is directly load-bearing: if the SW is asleep when the page's WebSocket sends
its first aria2 request, the ARIA2 RPC path depends on message-wakeup, and any in-memory state is gone.
Nothing in a Node mock can represent this.

**Real-world corroboration of that failure class** (not a mock postmortem, but the production symptom):
[openclaw/openclaw#25228](https://github.com/openclaw/openclaw/issues/25228) (2026-02-24) — an MV3
extension relay whose WebSocket dies when Chrome terminates the service worker; state cleared, user
must re-attach.

### On "where has a mock given a false green in practice?"

I searched hard for a canonical public postmortem ("we shipped because our chrome.* mock lied") and
**found none that is citable**. What exists instead is:
- Chrome's own unit-testing page recommending mocks and never discussing fidelity.
- Chrome's E2E page admitting that automation frameworks change SW lifetime.
- The class of bug above, which is easy to demonstrate locally.

So the honest answer to your question is: the false green is not documented because it is invisible —
it shows up as a production bug, not as a test failure. The repo-level bug I found is a live example.

---

## Q4 — What credibility standard practitioners actually use

**Short answer: there is no recognized standard, and no tool that generates a faithful mock.**
Chrome's [unit testing guide](https://developer.chrome.com/docs/extensions/how-to/test/unit-testing)
literally tells you to write `global.chrome = { tabs: { query: async () => { throw new Error("Unimplemented.") } } }`
and mock with `jest.spyOn`, then says *"we recommend adding end-to-end tests"*. That is the whole
official position.

What actually exists, in increasing order of value:

1. **`chrome-types` — Google's own, generated from Chromium's schemas, daily.**
   [GoogleChrome/chrome-types](https://github.com/GoogleChrome/chrome-types): *"This code is run
   automatically on a daily basis by GitHub Actions… publishes a new version if the output differs."*
   README: *"Depend on it for your Chrome extensions projects (MV3 and above)."*
   npm `chrome-types@0.1.452`, published **2026-10-03** (repo pushed 2026-10-04).
   `@types/chrome@0.3.4` (DefinitelyTyped) published 2026-09-29 — also alive; pick one, they are not
   interchangeable at the type level.

2. **Type-level contract check — verified working.** This is the closest thing to an enforceable
   "the mock still matches the API" assertion, and it is free:

   ```bash
   yarn add -D chrome-types
   ```
   ```ts
   // tsconfig: "types": ["chrome-types"]
   type RealDownloads = typeof chrome.downloads;
   export const mock = {
     download: async (o: chrome.downloads.DownloadOptions): Promise<number> => 1,
     onChanged: { addListener: (_cb: (d: chrome.downloads.DownloadDelta) => void) => {} },
   } satisfies Partial<RealDownloads>;
   ```

   `npx tsc --noEmit` **fails** on real mistakes I introduced [measured]:
   ```
   error TS2740: Type '{ addListener: … }' is missing the following properties from type
     'Event<(downloadDelta: DownloadDelta) => void, …>': removeListener, hasListener, hasListeners, addRules…
   error TS2322: Type 'Promise<{ id: number; }>' is not assignable to type 'Promise<number>'.
   error TS2322: Type '"bogus_type"' is not assignable to type 'ResourceType'.   // DNR enum
   ```
   That last one is exactly the class of error Chrome rejected at runtime in my probe. **Cost: ~30 min,
   confidence: battle-tested (it's just tsc).** Caveat: covering a `Partial<>` subset only constrains
   the members you actually mock — which is what you want.

3. **Raw schema files** (source of truth; note the ongoing JSON → WebIDL migration):
   - `chrome/common/extensions/api/downloads.webidl`
   - `chrome/common/extensions/api/tabs.json`
   - `extensions/common/api/declarative_net_request.webidl`
   - `extensions/common/api/storage.json`, `extensions/common/api/runtime.json`
   (all under https://github.com/chromium/chromium/tree/main/). They encode enums, required/optional and
   min/max, which is why `chrome-types` can catch bad DNR rules at compile time.

4. **Schema-generated mocks: do not exist.** I searched the npm registry (`chrome extension api mock`,
   `webextension mock`) and found no generator; the only hits are the hand-written mock libraries in Q1,
   the newest of which (`jest-webextension-mock`) is a Jest-shaped stub, not schema-derived. Say this
   plainly: nobody has built this.

5. **`webextension-polyfill` is no longer a fidelity oracle — it is archived.**
   `mozilla/webextension-polyfill` is **archived**, final commit 2026-07-30, npm 0.12.0 from 2024-05-14:
   *"Following the adoption of the `browser` namespace by Chrome, this polyfill has served its purpose,
   and will not receive any further updates."* Chrome **148** shipped the native `browser` namespace
   (`chrome.tabs === browser.tabs`) and Chrome **152** lifted the DevTools exception; Chrome 148 also
   made `runtime.onMessage` listeners able to **return a Promise**
   ([browser namespace doc](https://developer.chrome.com/docs/extensions/develop/concepts/browser-namespace)).
   Your `browser` global in tests is WXT/fake-browser, not the polyfill — but note that on modern Chrome
   a promise-returning `onMessage` listener is valid, while `fakeBrowser` may not model it.

6. **"Contract test" as a named pattern: not a thing here.** The only genuine contract test is the
   dual-run: assert the same observable outcome once against the real browser (Playwright E2E) and keep
   the unit test only for the branch logic. Everything else is aspiration.

---

## Q5 — Testing the MAIN-world fetch/XHR/WebSocket interception

### jsdom / happy-dom [measured, jsdom 30.1.2, happy-dom 20.14.5]

| Global | jsdom 30.1.2 | happy-dom 20.14.5 |
|---|---|---|
| `fetch` | **undefined** (`Request`/`Response` too) | present |
| `XMLHttpRequest` | present, and it really hits the network (200 from a local server) | present |
| `WebSocket` | **present** — since **jsdom 11.6.0 (2018-01-22)**, and it connected to a real `ws://` server and echoed a message | present |
| `postMessage` | present but **NOT structured-cloned** | present |

The commonly repeated advice "jsdom has no WebSocket, so you must use a real browser" is **eight years
out of date**. Verify for yourself:

```js
import { JSDOM } from 'jsdom';
const w = new JSDOM('', { url: 'http://127.0.0.1:6800/' }).window;
typeof w.WebSocket; // 'function'
```

**What a jsdom test of your interception actually proves — and what it silently gets wrong:**

- It proves your patch function is *shaped* correctly and that your JSON-RPC munging logic works for
  the sample payloads you wrote.
- It does **not** prove the script runs in the page's MAIN world; jsdom has one realm. `defineContentScript({ world: 'MAIN' })`
  is a manifest-level concept (`"world": "MAIN"` in the built
  [`.output/chrome-mv3/manifest.json`](../.output/chrome-mv3/manifest.json)) that jsdom never sees.
- It gets the MAIN↔ISOLATED bridge **wrong in your favour**: jsdom's `postMessage` passes the *same
  object reference* (I mutated the sender's object afterwards and the receiver observed the mutation;
  a function value passed through untouched). Real Chromium throws:
  `DataCloneError: Failed to execute 'postMessage' on 'Window': () => 1 could not be cloned.` [measured
  in Chromium 153]. Your bridge uses `CustomEvent` instead, which is not cloned in either environment —
  but the event crosses a world boundary in Chrome and does not in jsdom, so ordering/ownership bugs
  are invisible.
- `run_at: document_start` and "am I installed before the page's own scripts run" cannot be tested at all.

### Real browser, no navigation, no display — this is the recipe that works [measured]

```js
// 1. headless container: channel:'chromium' (see Q2). page.evaluate() runs in the MAIN world —
//    verified: a world:'MAIN' content script's window.__mainWorldMarker was visible to page.evaluate,
//    while the ISOLATED script's window.__isolatedMarker was not.
const page = await context.newPage();

// 2. Intercept the aria2 JSON-RPC WebSocket. MUST be registered BEFORE goto —
//    measured: registered after goto, the handler was never called (calls=0) and the page
//    reached the real server; no error was raised.
await page.routeWebSocket(/localhost:6800/, (ws) => {
  ws.onMessage((msg) => ws.send(JSON.stringify({ jsonrpc: '2.0', id: 1, result: 'fake-gid' })));
});

// 3. Serve a page from a local http server; its inline script uses fetch/XHR/WebSocket
await page.goto('http://127.0.0.1:18080/page');
await page.waitForFunction(() => window.__intercepted?.length > 0);
```

A fake aria2 endpoint is ~30 lines of Node (this is what I used):

```js
http.createServer((req, res) => {
  if (req.url.startsWith('/jsonrpc')) {
    let body = ''; req.on('data', (c) => (body += c));
    req.on('end', () => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ jsonrpc: '2.0', id: JSON.parse(body).id, result: 'fake-gid' }));
    });
  }
}).listen(6800, '127.0.0.1');
```

**What only Chrome can tell you, and it is cheap to assert:**
- the shim was installed before the page's scripts (`window.fetch.toString()` / a marker,
  and `page.evaluate` sees it because evaluate is MAIN-world);
- the request never reaches the real port (assert on the fake server's request log);
- the ISOLATED bridge's `browser.runtime.sendMessage` actually reached the SW;
- the DNR-injected header arrived (`x-aria-probe: injected` was visible to the page's own `fetch` [measured]).

### WXT specifics

WXT's docs warn that **MAIN-world content scripts cannot use the extension API** and recommend
`injectScript()` for an unlisted script instead — *"Main world content scripts don't have access to the
extension API"*, *"WXT recommends injecting a script into the main world manually using its
`injectScript` function"*
([content scripts § Isolated World vs Main World](https://wxt.dev/guide/essentials/content-scripts)).
Your `entrypoints/bridge.content.ts` correctly does the `browser.runtime.sendMessage` work in the
ISOLATED world, so you are on the sanctioned architecture; note that MAIN-world content scripts also
do not exist in Firefox, which matters if `build:firefox` is a real target.

`WxtVitest()` and `fakeBrowser` do **nothing** for MAIN-world interception — they only replace the
`browser` global.

---

## Recommended plan for this repo

**Tier 0 — free, do now.** Re-label `tests/*.test.ts` as logic tests. Keep the ones that assert pure
functions (`aria2-handler` parsing, `queryTasks`, status transitions). Delete or rewrite any assertion
that says "the mock recorded a call" as evidence of correctness.

**Tier 1 — ~2 hours, high value.**
1. `yarn add -D chrome-types`; add `"types": ["chrome-types"]` to `tsconfig.json`; annotate the mock in
   [`tests/setup.ts`](../tests/setup.ts) with `satisfies Partial<typeof chrome.downloads>` (and tabs /
   declarativeNetRequest / storage). Free API-drift alarm on every `yarn compile`.
2. Fix the mock's *shape*: JSON round-trip in `storage.local.get/set`; drop `undefined`/function values;
   make `tabs.remove` reject for unknown ids; add `onRemoved`; make `tabs.create` return
   `{id, status:'loading', url:'', pendingUrl}`; make `updateSessionRules` reject duplicate ids and
   invalid enums with Chrome's real message strings.
3. **Fix the two real bugs the mock hid**: seed `ruleIdCounter` from `getSessionRules()` (or persist it),
   and persist `_ruleIds` (or reconstruct rules) so restarts don't leak and collide.

**Tier 2 — the actual answer, ~1 day.**
4. `yarn add -D @playwright/test`; script `"e2e": "wxt build && playwright test"`.
5. Add `e2e/fixtures.ts` per Q2 with `channel: 'chromium'` + `.output/chrome-mv3`, and one spec that:
   serves a fake aria2 JSON-RPC endpoint, loads a page whose script calls fetch/XHR/WebSocket, asserts
   the interception happened in MAIN world, asserts the request never reached the real port, and asserts
   a real `chrome.downloads` entry completes (`downloads.search` → `state:'complete'`).
6. CI: `npx playwright install --with-deps chromium`, then `xvfb-run` is **not** needed (headless).

**Tier 3 — only if you care about the lifecycle bugs, ~half a day.**
7. A raw-CDP spec (launch `chrome-linux64/chrome --headless --remote-debugging-port=9222` yourself, poll
   `/json/list`) to assert "SW dies 30 s after idle" and "SW comes back and still serves aria2 RPC".
   Playwright cannot see this: with Playwright attached the SW never terminated in 165 s [measured].
   Cheaper alternative: force-terminate via CDP `Target.closeTarget` on the SW target (what Puppeteer's
   `worker.close()` does, [Chrome's guide](https://developer.chrome.com/docs/extensions/how-to/test/test-serviceworker-termination-with-puppeteer)).

---

## Things I could not substantiate (stated plainly)

- **No public "our chrome.* mock gave a false green" postmortem exists** that I could find and cite.
- **No schema-driven mock generator exists** for `chrome.*` (npm + web search).
- **No named contract-test standard** for extension mocks. `satisfies typeof chrome.*` + dual-run E2E is
  the best available, not a recognized pattern.
- Google's unit-testing doc offers **no** fidelity guidance whatsoever.
- Whether `Extensions.loadUnpacked` works in **branded** Google Chrome (as opposed to Chrome for
  Testing) is untested here — no branded Chrome in this container. It works on CfT 154 [measured], and
  Puppeteer ships it as the supported path.
