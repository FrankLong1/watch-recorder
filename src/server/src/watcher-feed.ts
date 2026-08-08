import type { Hono } from "hono";
import { DatabaseUnavailableError, type MemoFeedRecord, type MemoStore } from "./db";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ZERO_UUID = "00000000-0000-0000-0000-000000000000";
const MAX_WATCHER_PAGE_SIZE = 500;

type WatcherStore = Pick<MemoStore, "listTranscribedAfter">;
type WatcherLog = (message: string, fields?: Record<string, string | number>) => void;
type WatcherAuthorization = (authorization: string | undefined) => Promise<"authorized" | "unauthorized" | "forbidden">;

export function watcherCursor(query: (name: string) => string | undefined): MemoFeedRecord | null {
  const transcribedAt = query("after") ?? "1970-01-01T00:00:00.000000Z";
  const id = query("after_id") ?? ZERO_UUID;
  if (!Number.isFinite(Date.parse(transcribedAt)) || !UUID.test(id)) return null;
  return { transcribedAt, id };
}

export function watcherLimit(raw: string | undefined): number | null {
  if (!raw) return 100;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1 || value > MAX_WATCHER_PAGE_SIZE) return null;
  return value;
}

export function registerWatcherFeed(
  app: Hono,
  options: { authorize: WatcherAuthorization; store: WatcherStore; log: WatcherLog },
): void {
  app.get("/v1/watcher/memos", async (c) => {
    const authorization = await options.authorize(c.req.header("authorization"));
    if (authorization === "unauthorized") return c.json({ error: "unauthorized" }, 401);
    if (authorization === "forbidden") return c.json({ error: "forbidden" }, 403);
    const cursor = watcherCursor((name) => c.req.query(name));
    const limit = watcherLimit(c.req.query("limit"));
    if (!cursor || !limit) return c.json({ error: "invalid cursor or limit" }, 400);

    try {
      const memos = await options.store.listTranscribedAfter(cursor, limit);
      return c.json({ memos });
    } catch (error) {
      if (error instanceof DatabaseUnavailableError) {
        options.log("watcher feed database unavailable");
        return c.json({ error: "database unavailable" }, 503);
      }
      options.log("watcher feed failed", { detail: error instanceof Error ? error.name : "unknown" });
      return c.json({ error: "internal error" }, 500);
    }
  });
}
