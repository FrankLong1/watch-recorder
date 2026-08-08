import { describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  HELLO_WORLD_PROMPT,
  appServerArgs,
  codexChildEnvironment,
  googleIdentityToken,
  listMemos,
  markInterrupted,
  pollIsStale,
  readState,
  retryDelayMs,
  runAppVisibleTask,
  threadStartRequest,
  turnStartRequest,
  validatedFeedUrl,
  writeState,
} from "./wristmemo-watcher";

describe("Codex desktop wiring watcher", () => {
  test("uses a local stdio app-server and a read-only exact prompt", () => {
    expect(appServerArgs()).toEqual([
      "app-server",
      "--stdio",
    ]);
    expect(threadStartRequest({ taskCwd: "/home/user" })).toEqual({
      method: "thread/start",
      id: 1,
      params: {
        cwd: "/home/user",
        approvalPolicy: "never",
        sandbox: "read-only",
      },
    });
    expect(turnStartRequest({ taskCwd: "/home/user" }, "thread-1")).toEqual({
      method: "turn/start",
      id: 2,
      params: {
        threadId: "thread-1",
        input: [{ type: "text", text: "Reply with exactly: hello world" }],
        cwd: "/home/user",
        approvalPolicy: "never",
        sandboxPolicy: { type: "readOnly", networkAccess: false },
      },
    });
    expect(HELLO_WORLD_PROMPT).toBe("Reply with exactly: hello world");
  });

  test("keeps service credentials out of the Codex child environment", () => {
    expect(codexChildEnvironment({
      PATH: "/usr/bin",
      HOME: "/home/user",
      LANG: "en_US.UTF-8",
      WRISTMEMO_GOOGLE_AUDIENCE: "must-not-cross-process",
      OPENAI_API_KEY: "also-must-not-cross-process",
    })).toEqual({
      PATH: "/usr/bin",
      HOME: "/home/user",
      LANG: "en_US.UTF-8",
    });
  });

  test("requires a credential-free HTTPS watcher endpoint", () => {
    expect(validatedFeedUrl("https://watcher.example/base/")).toBe("https://watcher.example/base");
    expect(() => validatedFeedUrl("http://watcher.example")).toThrow("HTTPS");
    expect(() => validatedFeedUrl("https://token@watcher.example")).toThrow("without credentials");
    expect(() => validatedFeedUrl("https://watcher.example?token=bad")).toThrow("query");
  });

  test("creates a task through the app-server protocol and records its id first", async () => {
    const directory = await mkdtemp(join(tmpdir(), "wristmemo-app-server-"));
    const fakeCodex = join(directory, "codex");
    const capture = join(directory, "requests.jsonl");
    const captureForShell = capture.replaceAll("'", "'\"'\"'");
    try {
      await writeFile(
        fakeCodex,
        `#!/usr/bin/env bash
set -euo pipefail
capture_file='${captureForShell}'
IFS= read -r initialize
printf '%s\\n' "$initialize" >>"$capture_file"
printf '%s\\n' '{"id":0,"result":{}}'
IFS= read -r initialized
printf '%s\\n' "$initialized" >>"$capture_file"
IFS= read -r thread_start
printf '%s\\n' "$thread_start" >>"$capture_file"
printf '%s\\n' '{"id":1,"result":{"thread":{"id":"thread-app-visible"}}}'
IFS= read -r turn_start
printf '%s\\n' "$turn_start" >>"$capture_file"
printf '%s\\n' '{"id":2,"result":{"turn":{"id":"turn-hello"}}}'
printf '%s\\n' '{"method":"item/completed","params":{"threadId":"thread-app-visible","turnId":"turn-hello","item":{"type":"agentMessage","text":"hello world","phase":"final_answer"}}}'
printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-app-visible","turn":{"id":"turn-hello","status":"completed","items":[]}}}'
`,
        { mode: 0o700 },
      );
      const recorded: string[] = [];
      const result = await runAppVisibleTask(
        {
          codexBin: fakeCodex,
          taskCwd: directory,
          taskTimeoutMs: 5_000,
        },
        async (threadId) => {
          recorded.push(`created:${threadId}`);
        },
        async () => {
          recorded.push("requesting");
        },
      );

      expect(result).toEqual({ threadId: "thread-app-visible", turnId: "turn-hello" });
      expect(recorded).toEqual(["requesting", "created:thread-app-visible"]);
      const requests = (await readFile(capture, "utf8"))
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line));
      expect(requests[0]).toMatchObject({
        method: "initialize",
        params: { clientInfo: { name: "wristmemo_watcher" } },
      });
      expect(requests[1]).toEqual({ method: "initialized", params: {} });
      expect(requests[2]).toEqual(threadStartRequest({ taskCwd: directory }));
      expect(requests[3]).toEqual(turnStartRequest({ taskCwd: directory }, "thread-app-visible"));
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("writes a private, atomically replaceable state ledger", async () => {
    const directory = await mkdtemp(join(tmpdir(), "wristmemo-watcher-"));
    const path = join(directory, "state.json");
    try {
      await writeState(path, {
        version: 1,
        bootstrappedAt: "2026-08-08T00:00:00.000Z",
        memos: { "memo-1": { status: "ignored", discoveredAt: "2026-08-08T00:00:00.000Z" } },
      });
      expect(await readState(path)).toEqual({
        version: 1,
        bootstrappedAt: "2026-08-08T00:00:00.000Z",
        memos: { "memo-1": { status: "ignored", discoveredAt: "2026-08-08T00:00:00.000Z" } },
      });
      expect((await stat(path)).mode & 0o777).toBe(0o600);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("backs off retryable failures from one minute to fifteen minutes", () => {
    expect(retryDelayMs(1)).toBe(60_000);
    expect(retryDelayMs(2)).toBe(120_000);
    expect(retryDelayMs(10)).toBe(15 * 60_000);
  });

  test("bounds watcher feed requests with an abort signal", async () => {
    const fetchThatNeverResponds = ((_input: string | URL | Request, init?: RequestInit) =>
      new Promise<Response>((_resolve, reject) => {
        const signal = init?.signal;
        if (!signal) return reject(new Error("missing abort signal"));
        signal.addEventListener("abort", () => reject(signal.reason), { once: true });
      })) as typeof fetch;

    await expect(listMemos({
      feedUrl: "https://watcher.invalid",
      googleAudience: "server-client.apps.googleusercontent.com",
      feedTimeoutMs: 10,
      batchSize: 20,
    }, {
      id: "00000000-0000-0000-0000-000000000000",
      transcribedAt: "1970-01-01T00:00:00.000Z",
    }, fetchThatNeverResponds, async () => "header.payload.signature")).rejects.toThrow();
  });

  test("gets an audience-bound service-account token from Google metadata", async () => {
    let requestedUrl = "";
    let requestedFlavor = "";
    const metadataFetch = (async (input: string | URL | Request, init?: RequestInit) => {
      requestedUrl = String(input);
      requestedFlavor = new Headers(init?.headers).get("Metadata-Flavor") ?? "";
      return new Response("header.payload.signature\n", { status: 200 });
    }) as typeof fetch;

    await expect(googleIdentityToken(
      "server-client.apps.googleusercontent.com",
      1_000,
      metadataFetch,
    )).resolves.toBe("header.payload.signature");

    const url = new URL(requestedUrl);
    expect(url.hostname).toBe("metadata.google.internal");
    expect(url.searchParams.get("audience")).toBe("server-client.apps.googleusercontent.com");
    expect(url.searchParams.get("format")).toBe("full");
    expect(requestedFlavor).toBe("Google");
  });

  test("does not automatically retry an uncertain thread creation", async () => {
    const directory = await mkdtemp(join(tmpdir(), "wristmemo-recovery-"));
    const path = join(directory, "state.json");
    try {
      const state = {
        version: 1 as const,
        bootstrappedAt: "2026-08-08T00:00:00.000Z",
        memos: {
          safe: {
            status: "started" as const,
            discoveredAt: "2026-08-08T00:00:00.000Z",
          },
          uncertain: {
            status: "started" as const,
            discoveredAt: "2026-08-08T00:00:00.000Z",
            threadRequestStartedAt: "2026-08-08T00:01:00.000Z",
          },
        },
      };
      await writeState(path, state);
      await markInterrupted(path, state);

      const recovered = await readState(path);
      expect(recovered.memos.safe.status).toBe("pending");
      expect(recovered.memos.safe.nextAttemptAt).toBeDefined();
      expect(recovered.memos.uncertain.status).toBe("interrupted");
      expect(recovered.memos.uncertain.nextAttemptAt).toBeUndefined();
      expect(recovered.memos.uncertain.error).toContain("inspect recent tasks");
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("marks poll health stale after three missed intervals", () => {
    const now = Date.parse("2026-08-08T00:04:00.000Z");
    const state = {
      version: 1 as const,
      bootstrappedAt: "2026-08-08T00:00:00.000Z",
      poll: {
        lastSucceededAt: "2026-08-08T00:00:59.999Z",
        consecutiveFailures: 2,
      },
      memos: {},
    };
    expect(pollIsStale(state, { pollMs: 60_000, feedTimeoutMs: 30_000 }, now)).toBe(true);
    expect(pollIsStale(state, { pollMs: 120_000, feedTimeoutMs: 30_000 }, now)).toBe(false);
  });
});
