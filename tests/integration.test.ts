import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { Aria2RpcResponse, StoredTask } from "@/core/types";
import { DEFAULT_SETTINGS } from "@/core/types";

// =============================================================================
// Helpers
// =============================================================================

function rpc(method: string, params?: unknown[], id: string | number = "1") {
    return { jsonrpc: "2.0", id, method, params };
}

function downloadItem(overrides: Record<string, unknown> = {}) {
    return {
        id: 99, url: "http://x.com/z", filename: "z", state: "in_progress",
        bytesReceived: 0, fileSize: -1, mime: "application/octet-stream",
        startTime: new Date().toISOString(), danger: "safe", exists: true,
        paused: false, canResume: true, ...overrides,
    };
}

function fireDownloadCreated(item: Record<string, unknown>) {
    const listeners = (browser as any)._internal.downloadsCreatedListeners;
    listeners[listeners.length - 1]?.(item);
}

function fireDownloadChanged(delta: Record<string, unknown>) {
    const listeners = (browser as any)._internal.downloadsChangedListeners;
    listeners[listeners.length - 1]?.(delta);
}

function fireStorageChanged(key: string, newValue: unknown) {
    const listeners = (browser as any)._internal.onChangedListeners;
    listeners[listeners.length - 1]?.({ [key]: { newValue } }, "local");
}

function lastTabArgs() {
    const calls = (browser.tabs.create as ReturnType<typeof vi.fn>).mock.calls;
    return calls[calls.length - 1]?.[0] as { url?: string; active?: boolean };
}

async function freshImport() {
    vi.resetModules();
    // Re-wire addListener mocks so the DownloadManager constructor can register listeners
    const internal = (browser as any)._internal;
    (browser.downloads.onCreated.addListener as ReturnType<typeof vi.fn>).mockImplementation(
        (fn: (...args: unknown[]) => void) => internal.downloadsCreatedListeners.push(fn),
    );
    (browser.downloads.onChanged.addListener as ReturnType<typeof vi.fn>).mockImplementation(
        (fn: (...args: unknown[]) => void) => internal.downloadsChangedListeners.push(fn),
    );
    (browser.storage.onChanged.addListener as ReturnType<typeof vi.fn>).mockImplementation(
        (fn: (...args: unknown[]) => void) => internal.onChangedListeners.push(fn),
    );
    return await import("@/core/aria2-handler");
}

// =============================================================================
// Tests
// =============================================================================

describe("Integration: RPC → Download Pipeline", () => {
    let handleAria2Request: typeof import("@/core/aria2-handler").handleAria2Request;
    let dm: typeof import("@/core/download-manager").downloadManager;

    beforeEach(async () => {
        vi.clearAllMocks();
        const mod = await freshImport();
        handleAria2Request = mod.handleAria2Request;
        dm = (await import("@/core/download-manager")).downloadManager;
        await dm.init();
        await browser.storage.local.set({ settings: { ...DEFAULT_SETTINGS, enabled: true } });
    });

    afterEach(async () => {
        await dm.destroy().catch(() => {});
    });

    // =====================================================================
    // Full download lifecycle
    // =====================================================================

    it("addUri → create → browser match → tellStatus reflects progress", async () => {
        // 1. Add a download via RPC
        const res = (await handleAria2Request(
            rpc("aria2.addUri", [["http://cdn.example.com/video.mp4"], { out: "video.mp4", dir: "/dl" }]),
        )) as Aria2RpcResponse;
        const gid = res.result as string;
        expect(gid).toBeTruthy();

        // 2. Verify tab was opened in background
        expect(lastTabArgs().url).toBe("http://cdn.example.com/video.mp4");
        expect(lastTabArgs().active).toBe(false);

        // 3. Verify initial pending state
        let task = dm.getTask(gid)!;
        expect(task.status).toBe("pending");
        expect(task.request.filename).toBe("video.mp4");

        // 4. Simulate browser download created event
        fireDownloadCreated(downloadItem({ id: 42, url: "http://cdn.example.com/video.mp4", fileSize: 1048576 }));

        // 5. Verify transition to in_progress
        task = dm.getTask(gid)!;
        expect(task.status).toBe("in_progress");
        expect(task.browserDownloadId).toBe(42);
        expect(task.totalBytes).toBe(1048576);

        // 6. Simulate progress
        fireDownloadChanged({ id: 42, bytesReceived: { current: 524288 }, totalBytes: { current: 1048576 } });

        // 7. Verify via tellStatus
        const statusRes = (await handleAria2Request(rpc("aria2.tellStatus", [gid]))) as Aria2RpcResponse;
        const info = statusRes.result as Record<string, unknown>;
        expect(info.gid).toBe(gid);
        expect(info.status).toBe("active");
        expect(info.completedLength).toBe("524288");
    });

    it("addUri → download complete → appears in tellStopped", async () => {
        const res = (await handleAria2Request(rpc("aria2.addUri", [["http://cdn.example.com/doc.pdf"]]))) as Aria2RpcResponse;
        const gid = res.result as string;

        fireDownloadCreated(downloadItem({ id: 55, url: "http://cdn.example.com/doc.pdf" }));
        fireDownloadChanged({ id: 55, state: { current: "complete" } });

        expect(dm.getTask(gid)!.status).toBe("complete");

        const stopped = (await handleAria2Request(rpc("aria2.tellStopped", [0, 10]))) as Aria2RpcResponse;
        const tasks = stopped.result as Array<Record<string, unknown>>;
        expect(tasks.find((t) => t.gid === gid)).toBeDefined();
    });

    it("addUri → download interrupted → task shows error", async () => {
        const res = (await handleAria2Request(rpc("aria2.addUri", [["http://cdn.example.com/broken.zip"]]))) as Aria2RpcResponse;
        const gid = res.result as string;

        fireDownloadCreated(downloadItem({ id: 66, url: "http://cdn.example.com/broken.zip" }));
        fireDownloadChanged({ id: 66, state: { current: "interrupted" }, error: { current: "SERVER_FAILED" } });

        const task = dm.getTask(gid)!;
        expect(task.status).toBe("error");
        expect(task.error).toBe("SERVER_FAILED");
    });

    // =====================================================================
    // Control flow
    // =====================================================================

    it("pause → unpause → remove cycle via RPC", async () => {
        const res = (await handleAria2Request(rpc("aria2.addUri", [["http://cdn.example.com/ctl.bin"]]))) as Aria2RpcResponse;
        const gid = res.result as string;
        fireDownloadCreated(downloadItem({ id: 77, url: "http://cdn.example.com/ctl.bin" }));

        // Pause via RPC
        await handleAria2Request(rpc("aria2.pause", [gid]));
        expect(browser.downloads.pause).toHaveBeenCalledWith(77);

        // Unpause via RPC
        await handleAria2Request(rpc("aria2.unpause", [gid]));
        expect(browser.downloads.resume).toHaveBeenCalledWith(77);

        // Remove via RPC
        await handleAria2Request(rpc("aria2.remove", [gid]));
        expect(dm.getTask(gid)!.status).toBe("cancelled");
    });

    it("pauseAll pauses all in_progress tasks", async () => {
        const r1 = (await handleAria2Request(rpc("aria2.addUri", [["http://a.com/1"]]))) as Aria2RpcResponse;
        const r2 = (await handleAria2Request(rpc("aria2.addUri", [["http://a.com/2"]]))) as Aria2RpcResponse;
        fireDownloadCreated(downloadItem({ id: 1, url: "http://a.com/1" }));
        fireDownloadCreated(downloadItem({ id: 2, url: "http://a.com/2" }));

        await handleAria2Request(rpc("aria2.pauseAll"));
        expect(browser.downloads.pause).toHaveBeenCalledTimes(2);
    });

    // =====================================================================
    // Shutdown
    // =====================================================================

    it("shutdown disables extension and cancels all downloads", async () => {
        await handleAria2Request(rpc("aria2.addUri", [["http://a.com/1"]]));
        await handleAria2Request(rpc("aria2.addUri", [["http://a.com/2"]]));

        await handleAria2Request(rpc("aria2.shutdown"));

        const stored = await browser.storage.local.get("settings");
        expect((stored as Record<string, unknown>).settings).toHaveProperty("enabled", false);

        const all = dm.queryTasks();
        for (const t of all) expect(t.status).toBe("cancelled");
    });

    // =====================================================================
    // Persistence across "restarts"
    // =====================================================================

    it("persists tasks to storage on state change", async () => {
        vi.useFakeTimers();

        const res = (await handleAria2Request(rpc("aria2.addUri", [["http://cdn.example.com/persist.zip"]]))) as Aria2RpcResponse;
        const gid = res.result as string;
        fireDownloadCreated(downloadItem({ id: 88, url: "http://cdn.example.com/persist.zip", fileSize: 500 }));
        fireDownloadChanged({ id: 88, state: { current: "complete" } });

        // Flush the 3-second debounced persist
        await vi.advanceTimersByTimeAsync(3500);

        const raw = await browser.storage.local.get("tasks");
        const tasks = (raw as Record<string, unknown>).tasks as StoredTask[];
        expect(tasks).toBeDefined();
        expect(tasks.find((t) => t.id === gid)).toBeDefined();

        vi.useRealTimers();
    });

    it("restores completed tasks from storage on re-init", async () => {
        // Pre-populate storage with a completed task BEFORE importing dm
        await browser.storage.local.set({
            tasks: [{
                id: "restored-1", url: "http://cdn.example.com/old.zip",
                filename: "old.zip", directory: "", status: "complete",
                bytesReceived: 1024, totalBytes: 1024, createdAt: Date.now() - 10000,
            }],
        });

        // Destroy current dm and re-import to simulate restart
        await dm.destroy();

        // dm.destroy() persists empty tasks — overwrite back to our pre-populated data
        await browser.storage.local.set({
            tasks: [{
                id: "restored-1", url: "http://cdn.example.com/old.zip",
                filename: "old.zip", directory: "", status: "complete",
                bytesReceived: 1024, totalBytes: 1024, createdAt: Date.now() - 10000,
            }],
        });

        const mod = await freshImport();
        const newDm = (await import("@/core/download-manager")).downloadManager;
        await newDm.init();

        const task = newDm.getTask("restored-1")!;
        expect(task.status).toBe("complete");
        expect(task.url).toBe("http://cdn.example.com/old.zip");
    });

    it("marks pending tasks as error after restart", async () => {
        await browser.storage.local.set({
            tasks: [{
                id: "pending-old", url: "http://cdn.example.com/lost.zip",
                filename: "lost.zip", directory: "", status: "pending",
                bytesReceived: 0, totalBytes: 0, createdAt: Date.now() - 5000,
            }],
        });

        await dm.destroy();
        // Restore pre-populated data after destroy() overwrites it
        await browser.storage.local.set({
            tasks: [{
                id: "pending-old", url: "http://cdn.example.com/lost.zip",
                filename: "lost.zip", directory: "", status: "pending",
                bytesReceived: 0, totalBytes: 0, createdAt: Date.now() - 5000,
            }],
        });

        const mod = await freshImport();
        const newDm = (await import("@/core/download-manager")).downloadManager;
        await newDm.init();

        const task = newDm.getTask("pending-old")!;
        expect(task.status).toBe("error");
        expect(task.error).toContain("restarted");
    });

    // =====================================================================
    // Stats & global state
    // =====================================================================

    it("getGlobalStat reflects actual download manager state", async () => {
        const r1 = (await handleAria2Request(rpc("aria2.addUri", [["http://a.com/1"]]))) as Aria2RpcResponse;
        const r2 = (await handleAria2Request(rpc("aria2.addUri", [["http://a.com/2"]]))) as Aria2RpcResponse;
        await handleAria2Request(rpc("aria2.addUri", [["http://a.com/3"]]));

        fireDownloadCreated(downloadItem({ id: 1, url: "http://a.com/1" }));
        fireDownloadCreated(downloadItem({ id: 2, url: "http://a.com/2" }));
        // Task 3 remains pending

        await dm.cancel(r2.result as string);

        const stat = (await handleAria2Request(rpc("aria2.getGlobalStat"))) as Aria2RpcResponse;
        const s = stat.result as Record<string, string>;
        expect(s.numActive).toBe("1");
        expect(s.numWaiting).toBe("1");
        expect(s.numStopped).toBe("1");
    });

    // =====================================================================
    // Error handling
    // =====================================================================

    it("returns error when extension is disabled", async () => {
        await browser.storage.local.set({ settings: { ...DEFAULT_SETTINGS, enabled: false } });
        const res = (await handleAria2Request(rpc("aria2.getVersion"))) as Aria2RpcResponse;
        expect(res.error?.code).toBe(-32000);
    });

    it("re-enabling restores RPC access", async () => {
        await browser.storage.local.set({ settings: { ...DEFAULT_SETTINGS, enabled: false } });
        let res = (await handleAria2Request(rpc("aria2.getVersion"))) as Aria2RpcResponse;
        expect(res.error?.code).toBe(-32000);

        await browser.storage.local.set({ settings: { ...DEFAULT_SETTINGS, enabled: true } });
        res = (await handleAria2Request(rpc("aria2.getVersion"))) as Aria2RpcResponse;
        expect(res.result).toBeDefined();
    });

    it("rejects unauthorized requests when rpcSecret is set", async () => {
        await browser.storage.local.set({ settings: { ...DEFAULT_SETTINGS, rpcSecret: "s3cret" } });
        const bad = (await handleAria2Request(rpc("aria2.getVersion"))) as Aria2RpcResponse;
        expect(bad.error?.code).toBe(-32001);

        const good = (await handleAria2Request(rpc("aria2.getVersion", ["token:s3cret"]))) as Aria2RpcResponse;
        expect(good.result).toBeDefined();
    });
});

// =============================================================================
// Background message handler integration
// =============================================================================

describe("Integration: Background Message Handler", () => {
    let dm: typeof import("@/core/download-manager").downloadManager;

    beforeEach(async () => {
        vi.clearAllMocks();
        await freshImport();
        dm = (await import("@/core/download-manager")).downloadManager;
        await dm.init();
        await browser.storage.local.set({ settings: { ...DEFAULT_SETTINGS, enabled: true } });
    });

    afterEach(async () => {
        await dm.destroy().catch(() => {});
    });

    it("processes aria2-rpc message through full pipeline", async () => {
        // Simulate background.ts message listener
        const { handleAria2Request } = await import("@/core/aria2-handler");

        let capturedResponse: unknown;
        const sendResponse = (resp: unknown) => { capturedResponse = resp; };

        const returned = (() => {
            const message = {
                type: "aria2-rpc",
                payload: { jsonrpc: "2.0", id: "bg-1", method: "aria2.getVersion", params: [] },
            };
            handleAria2Request(message.payload as never)
                .then((response) => sendResponse(response))
                .catch((err) =>
                    sendResponse({
                        jsonrpc: "2.0", id: null,
                        error: { code: -32603, message: err instanceof Error ? err.message : String(err) },
                    }),
                );
            return true; // async
        })();

        expect(returned).toBe(true);

        await vi.waitFor(() => expect(capturedResponse).toBeDefined(), { timeout: 2000 });
        const resp = capturedResponse as Aria2RpcResponse;
        expect(resp.jsonrpc).toBe("2.0");
        expect(resp.id).toBe("bg-1");
        expect(resp.result).toBeDefined();
    });

    it("get-enabled returns current state", async () => {
        const { isEnabled } = await import("@/core/storage");
        const enabled = await isEnabled();
        expect(enabled).toBe(true);
    });

    it("set-enabled toggles and cancels downloads", async () => {
        const { setEnabled } = await import("@/core/storage");

        // Create an active task
        const { handleAria2Request } = await import("@/core/aria2-handler");
        const res = (await handleAria2Request(rpc("aria2.addUri", [["http://a.com/z"]]))) as Aria2RpcResponse;
        const gid = res.result as string;
        fireDownloadCreated(downloadItem({ id: 99, url: "http://a.com/z" }));

        // Disable via setEnabled
        await setEnabled(false);
        await dm.cancelAll();

        expect(dm.getTask(gid)!.status).toBe("cancelled");
        expect(await (await import("@/core/storage")).isEnabled()).toBe(false);
    });
});

// =============================================================================
// Bridge protocol integration (CustomEvent-based communication)
// =============================================================================

describe("Integration: Bridge Protocol", () => {
    // Simulate the MAIN → ISOLATED → background → ISOLATED → MAIN event chain

    it("full bridge round-trip: request → response", async () => {
        const eventTarget = new EventTarget();

        // --- ISOLATED world bridge handler ---
        eventTarget.addEventListener("aria2-shim-request", (async (e: Event) => {
            const detail = (e as CustomEvent).detail;
            const { _requestId, body } = detail;
            try {
                const response = await (browser.runtime.sendMessage as ReturnType<typeof vi.fn>)({
                    type: "aria2-rpc", payload: body,
                });
                eventTarget.dispatchEvent(new CustomEvent("aria2-shim-response", {
                    detail: { _requestId, data: response },
                }));
            } catch (err) {
                eventTarget.dispatchEvent(new CustomEvent("aria2-shim-response", {
                    detail: { _requestId, error: String(err) },
                }));
            }
        }) as EventListener);

        // --- Background mock ---
        (browser.runtime.sendMessage as ReturnType<typeof vi.fn>).mockImplementation(async (msg) => {
            const mod = await import("@/core/aria2-handler");
            return mod.handleAria2Request((msg as { payload: unknown }).payload);
        });

        // --- MAIN world sendToBackground ---
        const sendToBackground = (body: unknown): Promise<unknown> => {
            const requestId = crypto.randomUUID();
            return new Promise((resolve, reject) => {
                const timeout = setTimeout(() => {
                    eventTarget.removeEventListener("aria2-shim-response", handler as EventListener);
                    reject(new Error("Request timeout"));
                }, 30_000);

                function handler(e: Event) {
                    const detail = (e as CustomEvent).detail;
                    if (detail?._requestId !== requestId) return;
                    clearTimeout(timeout);
                    eventTarget.removeEventListener("aria2-shim-response", handler as EventListener);
                    if (detail?.error) reject(new Error(detail.error));
                    else resolve(detail.data);
                }

                eventTarget.addEventListener("aria2-shim-response", handler as EventListener);
                eventTarget.dispatchEvent(new CustomEvent("aria2-shim-request", {
                    detail: { _requestId: requestId, body },
                }));
            });
        };

        // --- Test ---
        const response = await sendToBackground({
            jsonrpc: "2.0", id: "bridge-1", method: "aria2.getVersion", params: [],
        });

        expect(response).toHaveProperty("jsonrpc", "2.0");
        expect(response).toHaveProperty("id", "bridge-1");
        expect(browser.runtime.sendMessage).toHaveBeenCalledTimes(1);
    });

    it("bridge propagates background errors to MAIN", async () => {
        const eventTarget = new EventTarget();

        eventTarget.addEventListener("aria2-shim-request", ((e: Event) => {
            const detail = (e as CustomEvent).detail;
            eventTarget.dispatchEvent(new CustomEvent("aria2-shim-response", {
                detail: {
                    _requestId: detail._requestId,
                    error: "Background unavailable",
                    data: { jsonrpc: "2.0", id: detail.body?.id ?? null, error: { code: -32603, message: "down" } },
                },
            }));
        }) as EventListener);

        const result = await new Promise<unknown>((resolve, reject) => {
            const requestId = "err-test";
            const timeout = setTimeout(() => reject(new Error("timeout")), 1000);

            function handler(e: Event) {
                const detail = (e as CustomEvent).detail;
                if (detail?._requestId !== requestId) return;
                clearTimeout(timeout);
                if (detail?.error) reject(new Error(detail.error));
                else resolve(detail.data);
            }

            eventTarget.addEventListener("aria2-shim-response", handler as EventListener);
            eventTarget.dispatchEvent(new CustomEvent("aria2-shim-request", {
                detail: { _requestId: requestId, body: {} },
            }));
        }).catch((e) => e.message);

        expect(result).toBe("Background unavailable");
    });

    it("MAIN request times out when bridge is silent", async () => {
        const eventTarget = new EventTarget();
        // Bridge never responds

        const result = await new Promise<string>((resolve, reject) => {
            const requestId = "timeout-test";
            const timeout = setTimeout(() => reject(new Error("timeout")), 50);

            function handler(_e: Event) { /* never called */ }

            eventTarget.addEventListener("aria2-shim-response", handler as EventListener);
            eventTarget.dispatchEvent(new CustomEvent("aria2-shim-request", {
                detail: { _requestId: requestId, body: {} },
            }));
        }).catch((e) => (e as Error).message);

        expect(result).toBe("timeout");
    });

    it("ignores responses with wrong requestId", async () => {
        const eventTarget = new EventTarget();

        eventTarget.addEventListener("aria2-shim-request", ((e: Event) => {
            const detail = (e as CustomEvent).detail;
            // Dispatch a response with wrong requestId first
            eventTarget.dispatchEvent(new CustomEvent("aria2-shim-response", {
                detail: { _requestId: "wrong", data: { wrong: true } },
            }));
            // Then dispatch correct one
            eventTarget.dispatchEvent(new CustomEvent("aria2-shim-response", {
                detail: { _requestId: detail._requestId, data: { correct: true } },
            }));
        }) as EventListener);

        const result = await new Promise<unknown>((resolve, reject) => {
            const requestId = "target";
            const timeout = setTimeout(() => reject(new Error("timeout")), 1000);
            function handler(e: Event) {
                const detail = (e as CustomEvent).detail;
                if (detail?._requestId !== requestId) return;
                clearTimeout(timeout);
                resolve(detail.data);
            }
            eventTarget.addEventListener("aria2-shim-response", handler as EventListener);
            eventTarget.dispatchEvent(new CustomEvent("aria2-shim-request", {
                detail: { _requestId: requestId, body: {} },
            }));
        });

        expect(result).toEqual({ correct: true });
    });
});

// =============================================================================
// Integration: Settings change propagation
// =============================================================================

describe("Integration: Settings Change Propagation", () => {
    beforeEach(async () => {
        vi.resetModules();
        // Re-wire storage.onChanged.addListener so storage.ts can register
        const internal = (browser as any)._internal;
        (browser.storage.onChanged.addListener as ReturnType<typeof vi.fn>).mockImplementation(
            (fn: (...args: unknown[]) => void) => internal.onChangedListeners.push(fn),
        );
    });

    it("storage.onChanged triggers registered change handlers", async () => {
        const { onSettingsChange } = await import("@/core/storage");
        const handler = vi.fn();
        const unsub = onSettingsChange(handler);

        fireStorageChanged("settings", { ...DEFAULT_SETTINGS, enabled: false });
        expect(handler).toHaveBeenCalledTimes(1);
        expect(handler).toHaveBeenCalledWith(expect.objectContaining({ enabled: false }));

        unsub();
        fireStorageChanged("settings", { ...DEFAULT_SETTINGS, enabled: true });
        expect(handler).toHaveBeenCalledTimes(1); // still 1 after unsubscribe
    });

    it("ignores storage changes for unrelated keys", async () => {
        const { onSettingsChange } = await import("@/core/storage");
        const handler = vi.fn();
        onSettingsChange(handler);

        fireStorageChanged("other_key", { some: "value" });
        expect(handler).not.toHaveBeenCalled();
    });
});
