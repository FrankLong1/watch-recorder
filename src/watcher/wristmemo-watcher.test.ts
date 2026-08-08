import { describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  HELLO_WORLD_PROMPT,
  appServerArgs,
  readState,
  retryDelayMs,
  runAppVisibleTask,
  threadStartRequest,
  turnStartRequest,
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

  test("creates a task through the app-server protocol and records its id first", async () => {
    const directory = await mkdtemp(join(tmpdir(), "wristmemo-app-server-"));
    const fakeCodex = join(directory, "codex");
    const capture = join(directory, "requests.jsonl");
    const previousCapture = process.env.FAKE_CODEX_CAPTURE;
    try {
      await writeFile(
        fakeCodex,
        `#!/usr/bin/env bash
set -euo pipefail
IFS= read -r initialize
printf '%s\\n' "$initialize" >>"$FAKE_CODEX_CAPTURE"
printf '%s\\n' '{"id":0,"result":{}}'
IFS= read -r initialized
printf '%s\\n' "$initialized" >>"$FAKE_CODEX_CAPTURE"
IFS= read -r thread_start
printf '%s\\n' "$thread_start" >>"$FAKE_CODEX_CAPTURE"
printf '%s\\n' '{"id":1,"result":{"thread":{"id":"thread-app-visible"}}}'
IFS= read -r turn_start
printf '%s\\n' "$turn_start" >>"$FAKE_CODEX_CAPTURE"
printf '%s\\n' '{"id":2,"result":{"turn":{"id":"turn-hello"}}}'
printf '%s\\n' '{"method":"item/completed","params":{"threadId":"thread-app-visible","turnId":"turn-hello","item":{"type":"agentMessage","text":"hello world","phase":"final_answer"}}}'
printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-app-visible","turn":{"id":"turn-hello","status":"completed","items":[]}}}'
`,
        { mode: 0o700 },
      );
      process.env.FAKE_CODEX_CAPTURE = capture;
      const recorded: string[] = [];
      const result = await runAppVisibleTask(
        {
          codexBin: fakeCodex,
          taskCwd: directory,
          taskTimeoutMs: 5_000,
        },
        async (threadId) => {
          recorded.push(threadId);
        },
      );

      expect(result).toEqual({ threadId: "thread-app-visible", turnId: "turn-hello" });
      expect(recorded).toEqual(["thread-app-visible"]);
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
      if (previousCapture === undefined) delete process.env.FAKE_CODEX_CAPTURE;
      else process.env.FAKE_CODEX_CAPTURE = previousCapture;
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
});
