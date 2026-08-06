/// Cloud SQL access.
///
/// Connects over the Unix socket that Cloud Run mounts from its
/// `cloud_sql_instance` volume, authenticating with the service account's own
/// IAM token rather than a password. This mirrors the established pattern in
/// `slop-apps/src/apps/inbox/src/server/agent-inbox.ts`, which is the working
/// reference for this instance.

import { SQL } from "bun";
import type { DatabaseConfig } from "./config";

const METADATA_TOKEN_URL =
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";
const TOKEN_ROTATION_MARGIN_MS = 5 * 60 * 1000;
/// IAM tokens expire after an hour, so connections are recycled before then.
const IAM_CONNECTION_MAX_LIFETIME_SECONDS = 45 * 60;

export class DatabaseUnavailableError extends Error {}
export class MemoInProgressError extends Error {}

let cachedToken: { token: string; expiresAt: number } | undefined;

async function iamAccessToken(): Promise<string> {
  const override = process.env.WRISTMEMO_DB_IAM_TOKEN?.trim();
  if (override) return override;

  if (cachedToken && Date.now() < cachedToken.expiresAt - TOKEN_ROTATION_MARGIN_MS) {
    return cachedToken.token;
  }

  const response = await fetch(METADATA_TOKEN_URL, {
    headers: { "Metadata-Flavor": "Google" },
  });
  if (!response.ok) {
    throw new DatabaseUnavailableError(`metadata token request failed (${response.status})`);
  }

  const body = (await response.json()) as { access_token?: unknown; expires_in?: unknown };
  if (typeof body.access_token !== "string" || !body.access_token || typeof body.expires_in !== "number") {
    throw new DatabaseUnavailableError("metadata token response was invalid");
  }

  cachedToken = { token: body.access_token, expiresAt: Date.now() + body.expires_in * 1000 };
  return cachedToken.token;
}

/// Bun's `SQL` picks up `DATABASE_URL` from the environment on its own, which
/// would silently win over an explicit socket configuration. Hide it for the
/// duration of the call.
function newSqlClient(options: ConstructorParameters<typeof SQL>[0]): SQL {
  const saved = process.env.DATABASE_URL;
  delete process.env.DATABASE_URL;
  try {
    return new SQL(options);
  } finally {
    if (saved !== undefined) process.env.DATABASE_URL = saved;
  }
}

export interface MemoRecord {
  id: string;
  userId: string;
  recordedAt: Date;
  durationSeconds: number;
  transcript: string;
  body: string;
  route: string | null;
  model: string;
}

export interface MemoStore {
  isTranscribed(id: string): Promise<boolean>;
  withMemoLock<T>(id: string, operation: () => Promise<T>): Promise<T>;
  save(memo: MemoRecord): Promise<void>;
  ping(): Promise<void>;
}

export function createMemoStore(config: DatabaseConfig): MemoStore {
  let sql: SQL | undefined;

  function client(): SQL {
    if (sql) return sql;
    if (config.kind === "url") {
      sql = newSqlClient({ url: config.url, max: 5 });
      return sql;
    }
    sql = newSqlClient({
      path: `${config.socketDir}/${config.connectionName}/.s.PGSQL.5432`,
      username: config.user,
      password: iamAccessToken,
      database: config.name,
      max: 5,
      maxLifetime: IAM_CONNECTION_MAX_LIFETIME_SECONDS,
    });
    return sql;
  }

  function wrap(error: unknown): never {
    if (error instanceof DatabaseUnavailableError) throw error;
    throw new DatabaseUnavailableError(error instanceof Error ? error.message : "database request failed");
  }

  return {
    async isTranscribed(id) {
      try {
        const rows = (await client()`
          SELECT 1
          FROM wristmemo.memos
          WHERE id = ${id}::uuid AND transcript IS NOT NULL
        `) as unknown[];
        return rows.length > 0;
      } catch (error) {
        wrap(error);
      }
    },

    /// Serialises a memo across every Cloud Run replica. A retry can overlap
    /// the original request when its response is lost, so an existence check
    /// alone would let both requests pay OpenAI before either writes the row.
    async withMemoLock(id, operation) {
      try {
        const reserved = await client().reserve();
        let locked = false;
        try {
          const rows = await reserved<{ locked: boolean }[]>`
            SELECT pg_try_advisory_lock(hashtextextended(${id}, 0)) AS locked
          `;
          if (rows[0]?.locked !== true) throw new MemoInProgressError();
          locked = true;
          return await operation();
        } finally {
          try {
            if (locked) {
              await reserved`
                SELECT pg_advisory_unlock(hashtextextended(${id}, 0))
              `;
            }
          } finally {
            reserved.release();
          }
        }
      } catch (error) {
        if (error instanceof MemoInProgressError) throw error;
        wrap(error);
      }
    },

    /// Idempotent on the watch-generated id, so a retried upload updates the
    /// row it already wrote instead of failing or duplicating.
    async save(memo) {
      try {
        await client()`
          INSERT INTO wristmemo.memos (
            id, user_id, recorded_at, duration_s, transcript, body, route, model, transcribed_at
          ) VALUES (
            ${memo.id}::uuid,
            ${memo.userId},
            ${memo.recordedAt},
            ${memo.durationSeconds},
            ${memo.transcript},
            ${memo.body},
            ${memo.route},
            ${memo.model},
            clock_timestamp()
          )
          ON CONFLICT (id) DO UPDATE SET
            transcript = EXCLUDED.transcript,
            body = EXCLUDED.body,
            route = EXCLUDED.route,
            model = EXCLUDED.model,
            transcribed_at = EXCLUDED.transcribed_at,
            updated_at = clock_timestamp()
        `;
      } catch (error) {
        wrap(error);
      }
    },

    async ping() {
      try {
        await client()`SELECT 1`;
      } catch (error) {
        wrap(error);
      }
    },
  };
}
