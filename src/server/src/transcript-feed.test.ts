import { describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { DatabaseUnavailableError, type MemoFeedRecord, type MemoTranscriptRecord } from "./db";
import { registerTranscriptFeed } from "./transcript-feed";

const memo: MemoTranscriptRecord = {
  id: "986bb295-f478-4428-a341-02c88b814bf0",
  recordedAt: 1_754_667_100.25,
  durationSeconds: 12.4,
  transcript: "Buy more NVDA before earnings.",
  transcribedAt: "2026-08-08T15:31:50.299417Z",
};

function testApp(
  listTranscriptsAfter: (userId: string, cursor: MemoFeedRecord, limit: number) => Promise<MemoTranscriptRecord[]>,
  authorization: { userId: string } | "unauthorized" | "forbidden" = { userId: "google:owner" },
) {
  const app = new Hono();
  const logs: Array<{ message: string; fields?: Record<string, string | number> }> = [];
  registerTranscriptFeed(app, {
    authorize: async () => authorization,
    store: { listTranscriptsAfter },
    log: (message, fields) => logs.push({ message, fields }),
  });
  return { app, logs };
}

describe("transcript feed", () => {
  test("returns an owner's transcript history with an exact cursor", async () => {
    const calls: Array<{ userId: string; cursor: MemoFeedRecord; limit: number }> = [];
    const { app } = testApp(async (userId, cursor, limit) => {
      calls.push({ userId, cursor, limit });
      return [memo];
    });
    const after = "2026-08-08T15:30:00.123456Z";
    const afterId = "11111111-1111-1111-1111-111111111111";
    const response = await app.request(
      `/v1/memos?after=${encodeURIComponent(after)}&after_id=${afterId}&limit=20`,
      { headers: { Authorization: "Bearer valid-owner-token" } },
    );

    expect(response.status).toBe(200);
    expect(calls).toEqual([{
      userId: "google:owner",
      cursor: { transcribedAt: after, id: afterId },
      limit: 20,
    }]);
    expect(await response.json()).toEqual({ memos: [memo] });
  });

  test("never queries transcripts without an allowed user", async () => {
    let called = false;
    const { app } = testApp(async () => {
      called = true;
      return [];
    }, "unauthorized");

    expect((await app.request("/v1/memos")).status).toBe(401);
    expect(called).toBe(false);
  });

  test("distinguishes a valid but unallowed user", async () => {
    const { app } = testApp(async () => [], "forbidden");
    expect((await app.request("/v1/memos", {
      headers: { Authorization: "Bearer another-person-token" },
    })).status).toBe(403);
  });

  test("rejects invalid pagination before selecting text", async () => {
    let calls = 0;
    const { app } = testApp(async () => {
      calls += 1;
      return [];
    });

    expect((await app.request("/v1/memos?after=bad")).status).toBe(400);
    expect((await app.request("/v1/memos?after_id=bad")).status).toBe(400);
    expect((await app.request("/v1/memos?limit=201")).status).toBe(400);
    expect(calls).toBe(0);
  });

  test("makes a database failure visible without exposing its detail", async () => {
    const { app, logs } = testApp(async () => {
      throw new DatabaseUnavailableError("private database detail");
    });
    const response = await app.request("/v1/memos");

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "database unavailable" });
    expect(logs).toEqual([{
      message: "transcript feed database unavailable",
      fields: undefined,
    }]);
    expect(JSON.stringify(logs)).not.toContain("private database detail");
  });
});
