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

/// What the phone may upload, and the filename to present it under upstream.
///
/// The transcription service picks a decoder from the filename's extension, so
/// the name is not cosmetic: forwarding a raw-PCM CAF as `memo.m4a` does not
/// merely skip a check, it hands the decoder a file it will mis-read. Only
/// formats the service documents as supported appear here; anything else is
/// refused at the edge instead of being relabelled into one of them.
export const AUDIO_FORMATS = {
  "audio/mp4": "memo.m4a",
  "audio/x-m4a": "memo.m4a",
  "audio/mpeg": "memo.mp3",
  "audio/wav": "memo.wav",
  "audio/x-wav": "memo.wav",
  "audio/flac": "memo.flac",
  "audio/ogg": "memo.ogg",
  "audio/webm": "memo.webm",
} as const;

export type AudioContentType = keyof typeof AUDIO_FORMATS;

const DEFAULT_CONTENT_TYPE: AudioContentType = "audio/mp4";

/// Normalises an inbound Content-Type, or `null` when nothing upstream can read
/// it. A missing header is taken as m4a: every memo the phone compressed has
/// always been one, and a build predating the header must keep working.
export function audioFormat(header: string | undefined): AudioContentType | null {
  const value = (header ?? "").split(";")[0]?.trim().toLowerCase() ?? "";
  if (!value) return DEFAULT_CONTENT_TYPE;
  return value in AUDIO_FORMATS ? (value as AudioContentType) : null;
}

/// The status the ingest endpoint answers a failed transcription with.
///
/// The phone's retry loop keys on the class, not the code: it re-sends every
/// 5xx indefinitely and stops on every 4xx. So a failure that will recur
/// identically — an unusable model, audio the service refuses — has to land in
/// the 4xx range, or the memo never reaches a visible `.failed` state and
/// instead retries invisibly forever.
export function transcriptionFailureStatus(error: TranscriptionError): 502 | 422 {
  return error.retryable ? 502 : 422;
}

export interface TranscribeOptions {
  audio: ReadableStream<Uint8Array>;
  /// Byte length of `audio`, needed to compute the multipart Content-Length.
  audioLength: number;
  apiKey: string;
  baseUrl: string;
  model: string;
  /// What the bytes actually are. Defaults to m4a, the only thing the phone
  /// sent before it began declaring the format.
  contentType?: AudioContentType;
  signal?: AbortSignal;
}

export interface Transcription {
  text: string;
  model: string;
}

export function multipart(
  model: string,
  audio: ReadableStream<Uint8Array>,
  audioLength: number,
  contentType: AudioContentType = DEFAULT_CONTENT_TYPE,
) {
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
      `Content-Disposition: form-data; name="file"; filename="${AUDIO_FORMATS[contentType]}"\r\n` +
      `Content-Type: ${contentType}\r\n\r\n`,
  );
  const tail = encoder.encode(`\r\n--${boundary}--\r\n`);

  const reader = audio.getReader();
  let sentHead = false;
  let released = false;

  function releaseReader() {
    if (released) return;
    released = true;
    // Releasing is tidiness only — the reader is discarded along with the
    // stream either way. Bun rejects this call when the surrounding fetch has
    // already detached the request body, which happens on the ordinary success
    // path, so an upload that has actually completed must not be failed by it.
    try {
      reader.releaseLock();
    } catch {
      // Intentionally ignored.
    }
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
      } catch {
        // Same reasoning as releaseReader: the stream is being torn down, and
        // failing to tear it down cleanly is not worth surfacing.
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
    options.contentType,
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
    // 429 is retryable alongside 5xx. It covers both an ordinary rate limit and
    // an exhausted credit balance — neither is a defect in the request, and a
    // memo must not be abandoned because the account was briefly over a limit.
    const retryable = response.status >= 500 || response.status === 429;
    throw new TranscriptionError(`openai responded ${response.status}`, retryable);
  }

  const parsed = (await response.json()) as { text?: unknown };
  if (typeof parsed.text !== "string") {
    throw new TranscriptionError("transcription response had no text", false);
  }

  return { text: parsed.text.trim(), model: options.model };
}
