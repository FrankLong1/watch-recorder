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

function requiredList(name: string): string[] {
  const values = required(name)
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  if (values.length === 0) throw new Error(`${name} must contain at least one value`);
  return [...new Set(values)];
}

export interface Config {
  port: number;
  googleOAuthClientId: string;
  googleAllowedUserSubjects: string[];
  googleWatcherServiceAccounts: string[];
  openaiApiKey: string;
  openaiBaseUrl: string;
  openaiModel: string;
  /// OpenAI rejects uploads over 25 MB. At the watch's 32 kbit/s that is about
  /// 100 minutes, so this is a guard rather than a real constraint.
  maxAudioBytes: number;
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
    googleOAuthClientId: required("GOOGLE_OAUTH_CLIENT_ID"),
    googleAllowedUserSubjects: requiredList("GOOGLE_ALLOWED_USER_SUBJECTS"),
    googleWatcherServiceAccounts: requiredList("GOOGLE_WATCHER_SERVICE_ACCOUNTS"),
    openaiApiKey: required("OPENAI_API_KEY"),
    openaiBaseUrl: optional("OPENAI_BASE_URL", "https://api.openai.com/v1"),
    openaiModel: optional("OPENAI_MODEL", "gpt-4o-transcribe"),
    maxAudioBytes: positiveInt("MAX_AUDIO_BYTES", 25 * 1024 * 1024),
    database: databaseConfig(),
  };
}
