import { describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { DatabaseUnavailableError, type MemoFeedRecord } from "./db";
import { registerWatcherFeed } from "./watcher-feed";

function testApp(
  listTranscribedAfter: (cursor: MemoFeedRecord, limit: number) => Promise<MemoFeedRecord[]>,
  authorization: "authorized" | "unauthorized" | "forbidden" = "authorized",
) {
  const app = new Hono();
  const logs: Array<{ message: string; fields?: Record<string, string | number> }> = [];
  registerWatcherFeed(app, {
    authorize: async () => authorization,
    store: { listTranscribedAfter },
    log: (message, fields) => logs.push({ message, fields }),
  });
  return { app, logs };
}

describe("watcher feed", () => {
  test("requires the Google service-account identity", async () => {
    let called = false;
    const { app } = testApp(async () => {
      called = true;
      return [];
    }, "unauthorized");

    expect((await app.request("/v1/watcher/memos")).status).toBe(401);
    expect(called).toBe(false);
  });

  test("distinguishes a valid but disallowed Google identity", async () => {
    const { app } = testApp(async () => [], "forbidden");
    expect((await app.request("/v1/watcher/memos", {
      headers: { Authorization: "Bearer valid-token-for-wrong-service-account" },
    })).status).toBe(403);
  });

  test("returns only lossless metadata and forwards the exact cursor", async () => {
    const calls: Array<{ cursor: MemoFeedRecord; limit: number }> = [];
    const { app } = testApp(async (cursor, limit) => {
      calls.push({ cursor, limit });
      return [{
        id: "986bb295-f478-4428-a341-02c88b814bf0",
        transcribedAt: "2026-08-08T15:31:50.299417Z",
      }];
    });
    const after = "2026-08-08T15:30:00.123456Z";
    const afterId = "11111111-1111-1111-1111-111111111111";
    const response = await app.request(
      `/v1/watcher/memos?after=${encodeURIComponent(after)}&after_id=${afterId}&limit=20`,
      { headers: { Authorization: "Bearer google-service-account-id-token" } },
    );

    expect(response.status).toBe(200);
    expect(calls).toEqual([{ cursor: { transcribedAt: after, id: afterId }, limit: 20 }]);
    expect(await response.json()).toEqual({
      memos: [{
        id: "986bb295-f478-4428-a341-02c88b814bf0",
        transcribedAt: "2026-08-08T15:31:50.299417Z",
      }],
    });
  });

  test("rejects invalid cursors and page sizes before querying", async () => {
    let calls = 0;
    const { app } = testApp(async () => {
      calls += 1;
      return [];
    });
    const headers = { Authorization: "Bearer google-service-account-id-token" };

    expect((await app.request("/v1/watcher/memos?after=nope", { headers })).status).toBe(400);
    expect((await app.request("/v1/watcher/memos?after_id=nope", { headers })).status).toBe(400);
    expect((await app.request("/v1/watcher/memos?limit=501", { headers })).status).toBe(400);
    expect(calls).toBe(0);
  });

  test("makes database failures visible without leaking details to the client", async () => {
    const { app, logs } = testApp(async () => {
      throw new DatabaseUnavailableError("private database detail");
    });
    const response = await app.request("/v1/watcher/memos", {
      headers: { Authorization: "Bearer google-service-account-id-token" },
    });

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "database unavailable" });
    expect(logs).toEqual([{
      message: "watcher feed database unavailable",
      fields: undefined,
    }]);
    expect(JSON.stringify(logs)).not.toContain("private database detail");
  });
});
