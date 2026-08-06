/// Forwards audio to OpenAI without ever landing it.
///
/// The multipart envelope is built by hand so the request body can stay a
/// stream. Using `FormData` would mean materialising the whole file to build a
/// `Blob`, which turns a constant-memory proxy into one that holds every
/// concurrent upload in RAM at once — and puts the bytes somewhere a crash dump
/// could capture them. The envelope is small and fixed, so the only thing that
/// flows through here is the caller's own stream.

export class TranscriptionError extends Error {
  /// True when retrying could plausibly succeed — network faults and OpenAI
  /// 5xx. A 4xx means the request itself is wrong and will fail identically.
  readonly retryable: boolean;

  constructor(message: string, retryable: boolean) {
    super(message);
    this.name = "TranscriptionError";
    this.retryable = retryable;
  }
}

export interface TranscribeOptions {
  audio: ReadableStream<Uint8Array>;
  /// Byte length of `audio`, needed to compute the multipart Content-Length.
  audioLength: number;
  apiKey: string;
  baseUrl: string;
  model: string;
  signal?: AbortSignal;
}

export interface Transcription {
  text: string;
  model: string;
}

export function multipart(model: string, audio: ReadableStream<Uint8Array>, audioLength: number) {
  const boundary = `----wristmemo${crypto.randomUUID().replaceAll("-", "")}`;
  const encoder = new TextEncoder();

  const head = encoder.encode(
    `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="model"\r\n\r\n` +
      `${model}\r\n` +
      `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="response_format"\r\n\r\n` +
      `json\r\n` +
      `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="file"; filename="memo.m4a"\r\n` +
      `Content-Type: audio/mp4\r\n\r\n`,
  );
  const tail = encoder.encode(`\r\n--${boundary}--\r\n`);

  const reader = audio.getReader();
  let sentHead = false;
  let released = false;

  function releaseReader() {
    if (released) return;
    released = true;
    reader.releaseLock();
  }

  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        if (!sentHead) {
          sentHead = true;
          controller.enqueue(head);
          return;
        }

        const { done, value } = await reader.read();
        if (done) {
          controller.enqueue(tail);
          controller.close();
          releaseReader();
          return;
        }
        controller.enqueue(value);
      } catch (error) {
        releaseReader();
        controller.error(error);
      }
    },
    async cancel(reason) {
      try {
        await reader.cancel(reason);
      } finally {
        releaseReader();
      }
    },
  });

  return {
    body,
    contentType: `multipart/form-data; boundary=${boundary}`,
    contentLength: head.byteLength + audioLength + tail.byteLength,
  };
}

export async function transcribe(options: TranscribeOptions): Promise<Transcription> {
  const { body, contentType, contentLength } = multipart(
    options.model,
    options.audio,
    options.audioLength,
  );

  let response: Response;
  try {
    response = await fetch(`${options.baseUrl}/audio/transcriptions`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${options.apiKey}`,
        "Content-Type": contentType,
        "Content-Length": String(contentLength),
      },
      body,
      // Required to send a streaming request body.
      duplex: "half",
      signal: options.signal,
    } as RequestInit);
  } catch (error) {
    throw new TranscriptionError(
      error instanceof Error ? error.message : "transcription request failed",
      true,
    );
  }

  if (!response.ok) {
    // The body may carry OpenAI's error message, but it may also echo request
    // detail, so only the status is surfaced or logged.
    await response.body?.cancel();
    throw new TranscriptionError(`openai responded ${response.status}`, response.status >= 500);
  }

  const parsed = (await response.json()) as { text?: unknown };
  if (typeof parsed.text !== "string") {
    throw new TranscriptionError("transcription response had no text", false);
  }

  return { text: parsed.text.trim(), model: options.model };
}
