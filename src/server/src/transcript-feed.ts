import type { Hono } from "hono";
import { DatabaseUnavailableError, type MemoFeedRecord, type MemoStore } from "./db";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ZERO_UUID = "00000000-0000-0000-0000-000000000000";
const MAX_TRANSCRIPT_PAGE_SIZE = 200;

type TranscriptStore = Pick<MemoStore, "listTranscriptsAfter">;
type TranscriptLog = (message: string, fields?: Record<string, string | number>) => void;
type TranscriptAuthorization = (
  authorization: string | undefined,
) => Promise<{ userId: string } | "unauthorized" | "forbidden">;

export function transcriptCursor(query: (name: string) => string | undefined): MemoFeedRecord | null {
  const transcribedAt = query("after") ?? "1970-01-01T00:00:00.000000Z";
  const id = query("after_id") ?? ZERO_UUID;
  if (!Number.isFinite(Date.parse(transcribedAt)) || !UUID.test(id)) return null;
  return { transcribedAt, id };
}

export function transcriptLimit(raw: string | undefined): number | null {
  if (!raw) return 100;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1 || value > MAX_TRANSCRIPT_PAGE_SIZE) return null;
  return value;
}

/// Registers the phone's read-only transcript history.
///
/// The API authenticates the person who recorded the memo and filters by their
/// immutable Google subject-derived database identity before selecting text.
/// The workstation watcher keeps its separate, metadata-only endpoint.
export function registerTranscriptFeed(
  app: Hono,
  options: { authorize: TranscriptAuthorization; store: TranscriptStore; log: TranscriptLog },
): void {
  app.get("/v1/memos", async (c) => {
    const authorization = await options.authorize(c.req.header("authorization"));
    if (authorization === "unauthorized") return c.json({ error: "unauthorized" }, 401);
    if (authorization === "forbidden") return c.json({ error: "forbidden" }, 403);

    const cursor = transcriptCursor((name) => c.req.query(name));
    const limit = transcriptLimit(c.req.query("limit"));
    if (!cursor || !limit) return c.json({ error: "invalid cursor or limit" }, 400);

    try {
      const memos = await options.store.listTranscriptsAfter(authorization.userId, cursor, limit);
      return c.json({ memos });
    } catch (error) {
      if (error instanceof DatabaseUnavailableError) {
        options.log("transcript feed database unavailable");
        return c.json({ error: "database unavailable" }, 503);
      }
      options.log("transcript feed failed", { detail: error instanceof Error ? error.name : "unknown" });
      return c.json({ error: "internal error" }, 500);
    }
  });
}
