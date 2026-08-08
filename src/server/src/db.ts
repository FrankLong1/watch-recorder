/// Cloud SQL access.
///
/// Connects over the Unix socket that Cloud Run mounts from its
/// `cloud_sql_instance` volume, authenticating with the service account's own
/// IAM token rather than a password. This mirrors the established pattern in
/// a sibling private project's queue service, which is the working
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

export interface MemoFeedRecord {
    id: string;
    /// Lossless UTC timestamp cursor from Postgres, including microseconds.
    transcribedAt: string;
}

/// A transcript the authenticated memo owner may read on their phone. This is
/// intentionally separate from the watcher feed, which remains metadata-only.
export interface MemoTranscriptRecord extends MemoFeedRecord {
  /// Unix seconds from the watch's recorded-at value, suitable for direct
  /// display on the phone without locale-sensitive server formatting.
  recordedAt: number;
  durationSeconds: number;
  transcript: string;
}

export interface MemoStore {
  isTranscribed(id: string): Promise<boolean>;
  withMemoLock<T>(id: string, operation: () => Promise<T>): Promise<T>;
  save(memo: MemoRecord): Promise<void>;
  listTranscribedAfter(cursor: MemoFeedRecord, limit: number): Promise<MemoFeedRecord[]>;
  listTranscriptsAfter(
    userId: string,
    cursor: MemoFeedRecord,
    limit: number,
  ): Promise<MemoTranscriptRecord[]>;
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
    // Driver messages can contain connection names, SQL fragments, or row
    // detail. Preserve the failure class, not the provider's text.
    throw new DatabaseUnavailableError("database request failed");
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
      let reserved: Awaited<ReturnType<SQL["reserve"]>>;
      try {
        reserved = await client().reserve();
      } catch (error) {
        wrap(error);
      }

      let locked = false;
      try {
        let rows: { locked: boolean }[];
        try {
          rows = (await reserved`
            SELECT pg_try_advisory_lock(hashtextextended(${id}::text, 0)) AS locked
          `) as { locked: boolean }[];
        } catch (error) {
          wrap(error);
        }
        if (rows[0]?.locked !== true) throw new MemoInProgressError();
        locked = true;

        // Deliberately not wrapped. A transcription failure is not a database
        // failure, and reporting it as one both hides the cause and sends the
        // phone the wrong status code.
        return await operation();
      } finally {
        try {
          if (locked) {
            await reserved`
              SELECT pg_advisory_unlock(hashtextextended(${id}::text, 0))
            `;
          }
        } finally {
          reserved.release();
        }
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

    async listTranscribedAfter(cursor, limit) {
      try {
        return (await client()`
          SELECT
            id::text,
            to_char(
              transcribed_at AT TIME ZONE 'UTC',
              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
            ) AS "transcribedAt"
          FROM wristmemo.memos
          WHERE transcribed_at IS NOT NULL
            AND (transcribed_at, id) > (${cursor.transcribedAt}::timestamptz, ${cursor.id}::uuid)
          ORDER BY transcribed_at ASC, id ASC
          LIMIT ${limit}
        `) as MemoFeedRecord[];
      } catch (error) {
        wrap(error);
      }
    },

    async listTranscriptsAfter(userId, cursor, limit) {
      try {
        return (await client()`
          SELECT
            id::text,
            EXTRACT(EPOCH FROM recorded_at)::double precision AS "recordedAt",
            duration_s::double precision AS "durationSeconds",
            transcript,
            to_char(
              transcribed_at AT TIME ZONE 'UTC',
              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
            ) AS "transcribedAt"
          FROM wristmemo.memos
          WHERE user_id = ${userId}
            AND transcript IS NOT NULL
            AND transcribed_at IS NOT NULL
            AND (transcribed_at, id) > (${cursor.transcribedAt}::timestamptz, ${cursor.id}::uuid)
          ORDER BY transcribed_at ASC, id ASC
          LIMIT ${limit}
        `) as MemoTranscriptRecord[];
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
