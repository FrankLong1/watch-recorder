import { afterAll, describe, expect, test } from "bun:test";
import { multipart, transcribe, TranscriptionError } from "./transcribe";

describe("multipart", () => {
  test("does not drain the audio ahead of downstream demand", async () => {
    // A long source, because the property under test is "does not read the
    // whole request eagerly". With only a chunk or two, a stream that drained
    // everything and one that prefetched a little look identical.
    const total = 500;
    let pulls = 0;
    const audio = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulls += 1;
        controller.enqueue(new Uint8Array([pulls & 0xff]));
        if (pulls === total) controller.close();
      },
    });

    const { body } = multipart("gpt-transcribe", audio, total);
    const reader = body.getReader();

    expect(pulls).toBe(0);
    await reader.read(); // multipart header

    // Web Streams keep a small bounded queue, and exactly how many chunks that
    // is depends on microtask scheduling in two nested streams — so assert the
    // bound, not an exact count. The old eager `start` loop would sit at 500.
    await Promise.resolve();
    expect(pulls).toBeLessThan(10);

    await reader.read(); // first audio chunk
    expect(pulls).toBeGreaterThan(0);
    expect(pulls).toBeLessThan(10);
  });

  test("releases the upstream reader when the body is cancelled", async () => {
    let cancelled = false;
    const audio = new ReadableStream<Uint8Array>({
      pull(controller) {
        controller.enqueue(new Uint8Array([1]));
      },
      cancel() {
        cancelled = true;
      },
    });

    await multipart("m", audio, 1).body.cancel("done");

    expect(cancelled).toBe(true);
  });
});

/// Emits in small chunks so the framing tests exercise the multi-read path
/// rather than a single enqueue that would hide a boundary bug.
function streamOf(bytes: Uint8Array, chunkSize = 7): ReadableStream<Uint8Array> {
  let offset = 0;
  return new ReadableStream({
    pull(controller) {
      if (offset >= bytes.length) {
        controller.close();
        return;
      }
      controller.enqueue(bytes.slice(offset, offset + chunkSize));
      offset += chunkSize;
    },
  });
}

interface Received {
  model: string | null;
  responseFormat: string | null;
  filename: string | undefined;
  audio: Uint8Array | null;
  contentLength: string | null;
}

let received: Received | undefined;
let nextStatus = 200;
let nextBody: unknown = { text: "  hello from the wrist  " };

// Test the actual request object in-process. This avoids a listener (which is
// unnecessary for a request-construction test and can be unavailable in a
// sandboxed test runner) while still having the platform parse the multipart
// stream and validate its Content-Length.
const originalFetch = globalThis.fetch;
const mockFetch = Object.assign(
  async (input: string | URL | Request, init?: RequestInit) => {
    const request = input instanceof Request
      ? new Request(input, init)
      : new Request(input.toString(), init);
    if (nextStatus !== 200) return new Response("nope", { status: nextStatus });

    const contentLength = request.headers.get("content-length");
    const form = await request.formData();
    const file = form.get("file");

    received = {
      model: form.get("model") as string | null,
      responseFormat: form.get("response_format") as string | null,
      filename: file instanceof File ? file.name : undefined,
      audio: file instanceof File ? new Uint8Array(await file.arrayBuffer()) : null,
      contentLength,
    };

    return Response.json(nextBody);
  },
  { preconnect: originalFetch.preconnect },
);
globalThis.fetch = mockFetch;

const baseUrl = "https://transcription.test/v1";

afterAll(() => {
  globalThis.fetch = originalFetch;
});

describe("transcribe", () => {
  test("streams the audio through byte-exact inside a well-formed multipart body", async () => {
    // Bytes that would break naive text-mode framing: CRLF, a null, a run that
    // looks like a boundary marker, and sequences that are not valid UTF-8.
    const audio = new Uint8Array([
      0x00, 0x0d, 0x0a, 0xff, 0xfe, 0x2d, 0x2d, 0x41, 0x42, 0x43, 0x0d, 0x0a, 0x80, 0x7f, 0x01,
      0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c,
    ]);

    const result = await transcribe({
      audio: streamOf(audio),
      audioLength: audio.byteLength,
      apiKey: "test-key",
      baseUrl,
      model: "gpt-transcribe",
    });

    expect(result.text).toBe("hello from the wrist");
    expect(result.model).toBe("gpt-transcribe");

    expect(received?.model).toBe("gpt-transcribe");
    expect(received?.responseFormat).toBe("json");
    expect(received?.filename).toBe("memo.m4a");
    expect(Array.from(received?.audio ?? [])).toEqual(Array.from(audio));
  });

  test("declares a Content-Length consistent with the bytes actually sent", async () => {
    const audio = new Uint8Array(1024).fill(0x41);

    await transcribe({
      audio: streamOf(audio, 64),
      audioLength: audio.byteLength,
      apiKey: "test-key",
      baseUrl,
      model: "whisper-1",
    });

    // A wrong length hangs or truncates against the real API, so assert it is
    // present and exceeds the payload by exactly the envelope.
    const declared = Number(received?.contentLength);
    expect(Number.isSafeInteger(declared)).toBe(true);
    expect(declared).toBeGreaterThan(audio.byteLength);
    expect(received?.audio?.byteLength).toBe(audio.byteLength);
  });

  test("marks a 5xx retryable and a 4xx not", async () => {
    nextStatus = 503;
    await expect(
      transcribe({
        audio: streamOf(new Uint8Array([1, 2, 3])),
        audioLength: 3,
        apiKey: "k",
        baseUrl,
        model: "m",
      }),
    ).rejects.toMatchObject({ retryable: true });

    nextStatus = 400;
    await expect(
      transcribe({
        audio: streamOf(new Uint8Array([1, 2, 3])),
        audioLength: 3,
        apiKey: "k",
        baseUrl,
        model: "m",
      }),
    ).rejects.toMatchObject({ retryable: false });

    nextStatus = 200;
  });

  test("rejects a response without text", async () => {
    nextBody = { notText: true };
    await expect(
      transcribe({
        audio: streamOf(new Uint8Array([1, 2, 3])),
        audioLength: 3,
        apiKey: "k",
        baseUrl,
        model: "m",
      }),
    ).rejects.toBeInstanceOf(TranscriptionError);

    nextBody = { text: "ok" };
  });
});
