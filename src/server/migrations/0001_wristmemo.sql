\set ON_ERROR_STOP on

BEGIN;

CREATE SCHEMA IF NOT EXISTS wristmemo;
REVOKE ALL ON SCHEMA wristmemo FROM PUBLIC;

-- The ingest identity gets this role and nothing else. The instance is shared
-- with the agent inbox, so WristMemo must not reach anything outside its own
-- schema.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wristmemo_ingest') THEN
    CREATE ROLE wristmemo_ingest NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS wristmemo.memos (
  -- Generated on the watch and reused unchanged across every hop, which is what
  -- makes a retried upload idempotent rather than duplicating a memo.
  id             uuid PRIMARY KEY,
  user_id        text NOT NULL CHECK (length(user_id) BETWEEN 1 AND 200),
  recorded_at    timestamptz NOT NULL,
  duration_s     real NOT NULL CHECK (duration_s > 0),

  -- Verbatim, as the model returned it.
  transcript     text,
  -- The same text with any spoken routing prefix removed.
  body           text,
  route          text CHECK (route IS NULL OR length(route) BETWEEN 1 AND 100),

  model          text,
  language       text,
  transcribed_at timestamptz,

  created_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at     timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS memos_user_recorded
  ON wristmemo.memos (user_id, recorded_at DESC);

CREATE INDEX IF NOT EXISTS memos_route
  ON wristmemo.memos (user_id, route, recorded_at DESC)
  WHERE route IS NOT NULL;

-- Full-text search is the reason this is Postgres rather than a document store.
-- The two-argument to_tsvector is immutable, so it can back a stored generated
-- column and stay correct without a trigger.
ALTER TABLE wristmemo.memos
  ADD COLUMN IF NOT EXISTS search tsvector
  GENERATED ALWAYS AS (to_tsvector('english', coalesce(body, transcript, ''))) STORED;

CREATE INDEX IF NOT EXISTS memos_search
  ON wristmemo.memos USING gin (search);

GRANT USAGE ON SCHEMA wristmemo TO wristmemo_ingest;
GRANT SELECT, INSERT, UPDATE ON wristmemo.memos TO wristmemo_ingest;

-- The Cloud Run service account's database user, created by Terraform before
-- this runs. Supplied by scripts/migrate.sh as a psql variable.
GRANT wristmemo_ingest TO :"ingest_database_user";

COMMIT;
