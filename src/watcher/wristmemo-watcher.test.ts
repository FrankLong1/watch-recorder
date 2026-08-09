import { describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, realpath, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  AppServerClient,
  WATCHER_VERSION,
  appServerArgs,
  codexUserAgentMatchesVersion,
  codexChildEnvironment,
  discoverMemos,
  googleIdentityToken,
  listMemosPage,
  markInterrupted,
  pollIsStale,
  processDue,
  readState,
  retryDelayMs,
  scanMemoPages,
  taskPrompt,
  threadStartRequest,
  turnStartRequest,
  validatedFeedUrl,
  validatedTaskCwd,
  writeState,
  type Config,
  type TaskClient,
  type WatcherState,
} from "./wristmemo-watcher";

function state(): WatcherState {
  return { version: 2, watcherVersion: WATCHER_VERSION, bootstrappedAt: "2026-08-08T00:00:00.000Z", memos: {} };
}

describe("production Codex desktop watcher", () => {
  test("creates a read-only, network-disabled task with real transcript semantics", () => {
    const transcript = "Please propose a safer reconciliation design.";
    expect(appServerArgs()).toEqual(["app-server", "--stdio", "-c", "mcp_servers={}"]);
    expect(threadStartRequest({ taskCwd: "/workspace/projects/watch-recorder" }, 3)).toEqual({
      method: "thread/start",
      id: 3,
      params: {
        cwd: "/workspace/projects/watch-recorder",
        approvalPolicy: "never",
        sandbox: "read-only",
        serviceName: "wristmemo_watcher",
      },
    });
    const turn = turnStartRequest({ taskCwd: "/workspace/projects/watch-recorder" }, "thread-1", transcript, 4);
    expect(turn.params).toMatchObject({
      threadId: "thread-1",
      cwd: "/workspace/projects/watch-recorder",
      approvalPolicy: "never",
      sandboxPolicy: { type: "readOnly", networkAccess: false },
    });
    expect(JSON.stringify(turn)).toContain(transcript);
    expect(taskPrompt(transcript)).toContain("human continuation");
    expect(taskPrompt(transcript)).toContain("strictly read-only");
  });

  test("keeps service credentials and config paths out of the Codex child environment", () => {
    expect(codexChildEnvironment({
      PATH: "/usr/bin",
      HOME: "/home/user",
      LANG: "en_US.UTF-8",
      XDG_CONFIG_HOME: "/private/config",
      WRISTMEMO_GOOGLE_AUDIENCE: "must-not-cross-process",
      OPENAI_API_KEY: "also-must-not-cross-process",
    })).toEqual({ PATH: "/usr/bin", HOME: "/home/user", LANG: "en_US.UTF-8" });
  });

  test("requires a credential-free HTTPS watcher endpoint", () => {
    expect(validatedFeedUrl("https://watcher.example/base/")).toBe("https://watcher.example/base");
    expect(() => validatedFeedUrl("http://watcher.example")).toThrow("HTTPS");
    expect(() => validatedFeedUrl("https://token@watcher.example")).toThrow("without credentials");
    expect(() => validatedFeedUrl("https://watcher.example?token=bad")).toThrow("query");
  });

  test("canonicalizes and validates the exact project path", async () => {
    const home = await realpath(await mkdtemp(join(tmpdir(), "wristmemo-home-")));
    const project = join(home, "Projects", "watch-recorder");
    const watcherRoot = join(home, ".local", "opt", "wristmemo-watcher");
    const link = join(home, "linked-project");
    try {
      await mkdir(project, { recursive: true });
      await mkdir(watcherRoot, { recursive: true });
      await symlink(project, link);
      await expect(validatedTaskCwd(project, { home, watcherRoots: [watcherRoot] })).resolves.toBe(project);
      await expect(validatedTaskCwd(home, { home, watcherRoots: [watcherRoot] })).rejects.toThrow("broad");
      await expect(validatedTaskCwd(join(home, "Projects"), { home, watcherRoots: [watcherRoot] })).rejects.toThrow("too broad");
      await expect(validatedTaskCwd(watcherRoot, { home, watcherRoots: [watcherRoot] })).rejects.toThrow();
      await expect(validatedTaskCwd(project, {
        home,
        watcherRoots: [join(project, ".watcher-state")],
      })).rejects.toThrow("watcher root");
      await expect(validatedTaskCwd(link, { home, watcherRoots: [watcherRoot] })).rejects.toThrow("symlinks");
      await expect(validatedTaskCwd("Projects/watch-recorder", { home, watcherRoots: [watcherRoot] })).rejects.toThrow("absolute");
    } finally {
      await rm(home, { recursive: true, force: true });
    }
  });

  test("keeps a long-running turn alive and returns as soon as turn/start is accepted", async () => {
    const directory = await mkdtemp(join(tmpdir(), "wristmemo-app-server-"));
    const fakeCodex = join(directory, "codex");
    try {
      await writeFile(fakeCodex, `#!/usr/bin/env bash
set -euo pipefail
IFS= read -r initialize
printf '%s\n' '{"id":1,"result":{"userAgent":"codex-cli 0.145.0","platformFamily":"unix"}}'
IFS= read -r initialized
IFS= read -r thread_list
printf '%s\n' '{"id":2,"result":{"data":[]}}'
IFS= read -r thread_start
printf '%s\n' '{"id":3,"result":{"thread":{"id":"thread-visible"}}}'
IFS= read -r turn_start
printf '%s\n' '{"id":4,"result":{"turn":{"id":"turn-running","status":"inProgress"}}}'
sleep 5
`, { mode: 0o700 });
      const client = new AppServerClient({
        codexBin: fakeCodex,
        expectedCodexVersion: "0.145.0",
        rpcTimeoutMs: 2_000,
        taskCwd: directory,
      });
      await client.start();
      const boundaries: string[] = [];
      const startedAt = Date.now();
      const result = await client.createTask("Inspect the repo and draft a plan.", {
        async threadRequestStarting() { boundaries.push("thread-request"); },
        async threadCreated(id) { boundaries.push(`thread:${id}`); },
        async turnRequestStarting() { boundaries.push("turn-request"); },
        async turnCreated(id) { boundaries.push(`turn:${id}`); },
      });
      expect(Date.now() - startedAt).toBeLessThan(1_000);
      expect(result).toEqual({ threadId: "thread-visible", turnId: "turn-running" });
      expect(client.compatibility().alive).toBe(true);
      expect(boundaries).toEqual(["thread-request", "thread:thread-visible", "turn-request", "turn:turn-running"]);
      await client.close();
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("fails compatibility health when Codex no longer matches the manually verified version", async () => {
    const directory = await mkdtemp(join(tmpdir(), "wristmemo-version-"));
    const fakeCodex = join(directory, "codex");
    try {
      await writeFile(fakeCodex, `#!/usr/bin/env bash
set -euo pipefail
IFS= read -r initialize
printf '%s\n' '{"id":1,"result":{"userAgent":"codex-cli 0.146.0"}}'
IFS= read -r initialized
sleep 5
`, { mode: 0o700 });
      const client = new AppServerClient({
        codexBin: fakeCodex,
        expectedCodexVersion: "0.145.0",
        rpcTimeoutMs: 1_000,
        taskCwd: directory,
      });
      await expect(client.start()).rejects.toThrow("compatibility");
      await client.close();
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("matches only the exact pinned Codex version token", () => {
    expect(codexUserAgentMatchesVersion("codex-cli 0.145.0", "0.145.0")).toBe(true);
    expect(codexUserAgentMatchesVersion("codex_cli_rs/0.145.0 (unix)", "0.145.0")).toBe(true);
    expect(codexUserAgentMatchesVersion("codex-cli 0.145.0-alpha.1", "0.145.0")).toBe(false);
    expect(codexUserAgentMatchesVersion("codex-cli 0.145.0", "0.14")).toBe(false);
  });

  test("writes a private atomic v2 state ledger and upgrades v1 without text", async () => {
    const directory = await mkdtemp(join(tmpdir(), "wristmemo-state-"));
    const path = join(directory, "state.json");
    try {
      await writeFile(path, JSON.stringify({ version: 1, memos: { old: { status: "pending", discoveredAt: "now" } } }));
      expect((await readState(path)).version).toBe(2);
      await writeState(path, state());
      expect((await stat(path)).mode & 0o777).toBe(0o600);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("ships a versioned image layer without runtime config or mutable state", async () => {
    const root = import.meta.dir;
    expect((await readFile(join(root, "VERSION"), "utf8")).trim()).toBe(WATCHER_VERSION);
    const installer = await readFile(join(root, "image", "install-image-layer.sh"), "utf8");
    const startup = await readFile(join(root, "image", "245-wristmemo-watcher.sh"), "utf8");
    expect(installer).toContain("/opt/wristmemo-watcher/${version}");
    expect(installer).toContain("test ! -e /opt/wristmemo-watcher/current/watcher.env");
    expect(startup).toContain(".config/wristmemo-watcher/watcher.env");
    expect(startup).toContain("/opt/wristmemo-watcher/current/service.sh start");
    expect(`${installer}\n${startup}`).not.toContain("your-cloud-run-service.example");
    expect(`${installer}\n${startup}`).not.toContain("Voice memo transcript");
  });

  test("builds the same versioned image artifact reproducibly", async () => {
    const root = import.meta.dir;
    const first = await mkdtemp(join(tmpdir(), "wristmemo-artifact-a-"));
    const second = await mkdtemp(join(tmpdir(), "wristmemo-artifact-b-"));
    try {
      for (const output of [first, second]) {
        const build = Bun.spawn([join(root, "image", "build-artifact.sh"), output], {
          stdout: "ignore",
          stderr: "pipe",
        });
        expect(await build.exited).toBe(0);
      }
      const artifact = `wristmemo-watcher-${WATCHER_VERSION}.tar.gz`;
      expect(await readFile(join(first, artifact))).toEqual(await readFile(join(second, artifact)));
    } finally {
      await rm(first, { recursive: true, force: true });
      await rm(second, { recursive: true, force: true });
    }
  });

  test("deduplicates a commit that appears arbitrarily far behind the high-water cursor", () => {
    const current = state();
    const later = { id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", transcribedAt: "2026-08-08T10:05:00.000Z", transcript: "later" };
    expect(discoverMemos(current, [later], "2026-08-08T10:05:01.000Z")).toBe(true);
    current.memos[later.id].status = "succeeded";

    const delayed = { id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", transcribedAt: "2026-08-07T10:04:00.000Z", transcript: "delayed commit" };
    expect(discoverMemos(current, [delayed, later], "2026-08-08T10:06:00.000Z")).toBe(true);
    expect(Object.keys(current.memos)).toHaveLength(2);
    expect(current.memos[delayed.id].status).toBe("pending");
    expect(current.memos[later.id].status).toBe("succeeded");
    expect(current.cursor).toEqual({ id: later.id, transcribedAt: later.transcribedAt });
    expect(discoverMemos(current, [delayed, later], "2026-08-08T10:07:00.000Z")).toBe(false);
  });

  test("paginates the complete owner feed from the beginning", async () => {
    const ids = [
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      "cccccccc-cccc-cccc-cccc-cccccccccccc",
    ];
    const requestedAfter: string[] = [];
    const feed = (async (input: string | URL | Request) => {
      const url = new URL(String(input));
      requestedAfter.push(url.searchParams.get("after") ?? "");
      const afterId = url.searchParams.get("after_id");
      const start = afterId === ids[1] ? 2 : 0;
      const memos = ids.slice(start, start + 2).map((id, offset) => ({
        id,
        transcript: `memo ${start + offset}`,
        transcribedAt: `2026-08-08T10:0${start + offset}:00.000Z`,
      }));
      return Response.json({ memos });
    }) as typeof fetch;
    const pages: string[][] = [];
    await scanMemoPages({
      feedUrl: "https://watcher.example",
      googleAudience: "audience",
      feedTimeoutMs: 1_000,
      batchSize: 2,
    }, async (page) => {
      pages.push(page.map((memo) => memo.id));
    }, feed, async () => "header.payload.signature");
    expect(pages).toEqual([ids.slice(0, 2), ids.slice(2)]);
    expect(requestedAfter).toEqual([
      "1970-01-01T00:00:00.000Z",
      "2026-08-08T10:01:00.000Z",
    ]);
  });

  test("a permanent memo failure does not block a later memo and leaks no transcript", async () => {
    const directory = await mkdtemp(join(tmpdir(), "wristmemo-queue-"));
    const path = join(directory, "state.json");
    const project = join(directory, "Projects", "target");
    await mkdir(project, { recursive: true });
    const current = state();
    const first = { id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", transcribedAt: "2026-08-08T10:00:00.000Z", transcript: "SECRET FIRST TRANSCRIPT" };
    const second = { id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", transcribedAt: "2026-08-08T10:01:00.000Z", transcript: "SECRET SECOND TRANSCRIPT" };
    discoverMemos(current, [first, second]);
    await writeState(path, current);
    const client: TaskClient = {
      async createTask(transcript, boundary) {
        if (transcript.includes("FIRST")) throw new Error(`do not persist ${transcript}`);
        await boundary.threadRequestStarting();
        await boundary.threadCreated("thread-second");
        await boundary.turnRequestStarting();
        await boundary.turnCreated("turn-second");
        return { threadId: "thread-second", turnId: "turn-second" };
      },
    };
    const config = {
      feedUrl: "https://watcher.example",
      googleAudience: "audience",
      pollMs: 20_000,
      batchSize: 100,
      maxAttempts: 1,
      stateRoot: directory,
      codeRoot: directory,
      codexBin: "codex",
      taskCwd: project,
      rpcTimeoutMs: 30_000,
      feedTimeoutMs: 10_000,
      expectedCodexVersion: "0.145.0",
    } satisfies Config;
    try {
      await processDue(config, path, current, [first, second], client);
      expect(current.memos[first.id].status).toBe("failed");
      expect(current.memos[second.id].status).toBe("succeeded");
      const persisted = await readFile(path, "utf8");
      expect(persisted).not.toContain("SECRET FIRST TRANSCRIPT");
      expect(persisted).not.toContain("SECRET SECOND TRANSCRIPT");
      expect(persisted).not.toContain("do not persist");
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("crash recovery preserves safe and uncertain thread/turn boundaries", async () => {
    const directory = await mkdtemp(join(tmpdir(), "wristmemo-recovery-"));
    const path = join(directory, "state.json");
    const current = state();
    current.memos = {
      safe: { status: "started", discoveredAt: "now" },
      resumable: { status: "started", discoveredAt: "now", threadRequestStartedAt: "then", threadId: "thread-1" },
      uncertainThread: { status: "started", discoveredAt: "now", threadRequestStartedAt: "then" },
      uncertainTurn: { status: "started", discoveredAt: "now", threadRequestStartedAt: "then", threadId: "thread-2", turnRequestStartedAt: "later" },
    };
    try {
      await writeState(path, current);
      await markInterrupted(path, current);
      expect(current.memos.safe.status).toBe("pending");
      expect(current.memos.resumable.status).toBe("pending");
      expect(current.memos.resumable.error).toContain("resumed");
      expect(current.memos.uncertainThread.status).toBe("interrupted");
      expect(current.memos.uncertainTurn.status).toBe("interrupted");
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("bounds feed requests and validates transcript-bearing payloads", async () => {
    const fetchThatNeverResponds = ((_input: string | URL | Request, init?: RequestInit) =>
      new Promise<Response>((_resolve, reject) => {
        const signal = init?.signal;
        if (!signal) return reject(new Error("missing abort signal"));
        signal.addEventListener("abort", () => reject(signal.reason), { once: true });
      })) as typeof fetch;
    await expect(listMemosPage({
      feedUrl: "https://watcher.invalid",
      googleAudience: "audience",
      feedTimeoutMs: 10,
      batchSize: 20,
    }, { id: "00000000-0000-0000-0000-000000000000", transcribedAt: "1970-01-01T00:00:00.000Z" },
    fetchThatNeverResponds, async () => "header.payload.signature")).rejects.toThrow();
  });

  test("gets an audience-bound attached-service-account token", async () => {
    let requestedUrl = "";
    let requestedFlavor = "";
    const metadataFetch = (async (input: string | URL | Request, init?: RequestInit) => {
      requestedUrl = String(input);
      requestedFlavor = new Headers(init?.headers).get("Metadata-Flavor") ?? "";
      return new Response("header.payload.signature\n", { status: 200 });
    }) as typeof fetch;
    await expect(googleIdentityToken("audience", 1_000, metadataFetch)).resolves.toBe("header.payload.signature");
    expect(new URL(requestedUrl).searchParams.get("audience")).toBe("audience");
    expect(requestedFlavor).toBe("Google");
  });

  test("aligns retry and stale-health thresholds with the 20 second poll", () => {
    expect(retryDelayMs(1)).toBe(20_000);
    expect(retryDelayMs(10)).toBe(10 * 60_000);
    const current = state();
    current.poll = { lastSucceededAt: "2026-08-08T00:00:00.000Z", consecutiveFailures: 0 };
    expect(pollIsStale(current, { pollMs: 20_000, feedTimeoutMs: 10_000 }, Date.parse("2026-08-08T00:01:21.000Z"))).toBe(true);
  });
});
