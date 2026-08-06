/// WristMemo ingest.
///
/// One endpoint. The phone POSTs a finished memo's audio; this streams it to
/// OpenAI, stores the transcript, and answers with a status code and nothing
/// else. Audio is never written to disk, a bucket, or a log — see
/// 1_INGEST_ARCHITECTURE.md.

import { createHash, timingSafeEqual } from "node:crypto";
import { Hono } from "hono";
import { loadConfig } from "./config";
import { createMemoStore, DatabaseUnavailableError, MemoInProgressError } from "./db";
import { parseRoute } from "./routing";
import { transcribe, TranscriptionError } from "./transcribe";

const config = loadConfig();
const store = createMemoStore(config.database);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function log(message: string, fields: Record<string, string | number> = {}) {
  // Structured, and deliberately incapable of carrying audio or transcript text.
  console.log(JSON.stringify({ message, ...fields }));
}

/// Compares digests rather than the raw values so the comparison is
/// length-independent as well as time-independent.
function tokenMatches(presented: string, expected: string): boolean {
  const a = createHash("sha256").update(presented).digest();
  const b = createHash("sha256").update(expected).digest();
  return timingSafeEqual(a, b);
}

function bearer(header: string | undefined): string | null {
  if (!header) return null;
  const [scheme, ...rest] = header.split(" ");
  if (scheme?.toLowerCase() !== "bearer") return null;
  const token = rest.join(" ").trim();
  return token || null;
}

const app = new Hono();

app.get("/readyz", async (c) => {
  try {
    await store.ping();
    return c.text("ok");
  } catch {
    return c.text("database unavailable", 503);
  }
});

app.post("/v1/memos/:id", async (c) => {
  const token = bearer(c.req.header("authorization"));
  if (!token || !tokenMatches(token, config.ingestToken)) {
    return c.json({ error: "unauthorized" }, 401);
  }

  const id = c.req.param("id");
  if (!UUID.test(id)) {
    return c.json({ error: "id must be a uuid" }, 400);
  }

  const recordedAtSeconds = Number(c.req.header("x-recorded-at"));
  const durationSeconds = Number(c.req.header("x-duration"));
  if (!Number.isFinite(recordedAtSeconds) || recordedAtSeconds <= 0) {
    return c.json({ error: "x-recorded-at must be unix seconds" }, 400);
  }
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) {
    return c.json({ error: "x-duration must be seconds" }, 400);
  }

  // The multipart envelope sent upstream needs a length, and a background
  // URLSession uploading from a file always supplies one.
  const declaredLength = Number(c.req.header("content-length"));
  if (!Number.isSafeInteger(declaredLength) || declaredLength <= 0) {
    return c.json({ error: "content-length is required" }, 411);
  }
  if (declaredLength > config.maxAudioBytes) {
    return c.json({ error: "audio too large" }, 413);
  }

  const audio = c.req.raw.body;
  if (!audio) {
    return c.json({ error: "body is required" }, 400);
  }

  try {
    return await store.withMemoLock(id, async () => {
      // The lock covers the existence check and OpenAI call, not just the
      // write. A retry whose first response was lost therefore cannot be
      // transcribed or billed twice.
      if (await store.isTranscribed(id)) {
        await audio.cancel();
        log("already transcribed", { id });
        return c.body(null, 204);
      }

      const result = await transcribe({
        audio,
        audioLength: declaredLength,
        apiKey: config.openaiApiKey,
        baseUrl: config.openaiBaseUrl,
        model: config.openaiModel,
        signal: AbortSignal.timeout(4 * 60 * 1000),
      });

      const { route, body } = parseRoute(result.text);

      await store.save({
        id,
        userId: config.defaultUserId,
        recordedAt: new Date(recordedAtSeconds * 1000),
        durationSeconds,
        transcript: result.text,
        body,
        route,
        model: result.model,
      });

      log("transcribed", {
        id,
        durationSeconds: Math.round(durationSeconds),
        bytes: declaredLength,
        characters: result.text.length,
        route: route ?? "none",
      });
      return c.body(null, 204);
    });
  } catch (error) {
    if (error instanceof MemoInProgressError) {
      await audio.cancel();
      return c.json({ error: "memo is already being transcribed" }, 503, {
        "Retry-After": "30",
      });
    }
    if (error instanceof DatabaseUnavailableError) {
      log("database unavailable", { id, detail: error.message });
      return c.json({ error: "database unavailable" }, 503);
    }
    if (error instanceof TranscriptionError) {
      log("transcription failed", { id, detail: error.message });
      return c.json({ error: "transcription failed" }, error.retryable ? 502 : 500);
    }
    log("unhandled error", { id, detail: error instanceof Error ? error.name : "unknown" });
    return c.json({ error: "internal error" }, 500);
  }
});

log("listening", { port: config.port, model: config.openaiModel });

export default {
  port: config.port,
  fetch: app.fetch,
  // Uploads are streamed, so this only has to admit the largest single memo.
  maxRequestBodySize: config.maxAudioBytes + 1024 * 1024,
};
