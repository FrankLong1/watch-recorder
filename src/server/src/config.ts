/// Environment parsing. Everything is read once at boot so a misconfigured
/// deployment fails immediately rather than on the first memo.

function required(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function optional(name: string, fallback: string): string {
  return process.env[name]?.trim() || fallback;
}

function positiveInt(name: string, fallback: number): number {
  const raw = process.env[name]?.trim();
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return value;
}

export interface Config {
  port: number;
  ingestToken: string;
  watcherToken: string;
  openaiApiKey: string;
  openaiBaseUrl: string;
  openaiModel: string;
  /// OpenAI rejects uploads over 25 MB. At the watch's 32 kbit/s that is about
  /// 100 minutes, so this is a guard rather than a real constraint.
  maxAudioBytes: number;
  /// Single-user for now. A real auth layer would derive this from the token.
  defaultUserId: string;
  database: DatabaseConfig;
}

export type DatabaseConfig =
  | { kind: "url"; url: string; name: string }
  | { kind: "socket"; connectionName: string; socketDir: string; user: string; name: string };

function databaseConfig(): DatabaseConfig {
  const name = optional("DATABASE_NAME", "wristmemo");

  // Local development and the migration harness point at a proxy or container.
  const url = process.env.DATABASE_URL?.trim();
  if (url) return { kind: "url", url, name };

  return {
    kind: "socket",
    connectionName: required("CLOUD_SQL_CONNECTION_NAME"),
    socketDir: optional("CLOUD_SQL_SOCKET_DIR", "/cloudsql"),
    user: required("DATABASE_USER"),
    name,
  };
}

export function loadConfig(): Config {
  return {
    port: positiveInt("PORT", 8080),
    ingestToken: required("WRISTMEMO_INGEST_TOKEN"),
    watcherToken: required("WRISTMEMO_WATCHER_TOKEN"),
    openaiApiKey: required("OPENAI_API_KEY"),
    openaiBaseUrl: optional("OPENAI_BASE_URL", "https://api.openai.com/v1"),
    openaiModel: optional("OPENAI_MODEL", "gpt-4o-transcribe"),
    maxAudioBytes: positiveInt("MAX_AUDIO_BYTES", 25 * 1024 * 1024),
    defaultUserId: optional("WRISTMEMO_USER_ID", "frank"),
    database: databaseConfig(),
  };
}
