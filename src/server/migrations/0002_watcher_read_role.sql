\set ON_ERROR_STOP on

BEGIN;

-- The workstation watcher is deliberately read-only. It can discover that a
-- transcript arrived, but cannot change a memo or reach a neighbouring schema.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wristmemo_watcher') THEN
    CREATE ROLE wristmemo_watcher NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA wristmemo TO wristmemo_watcher;
GRANT SELECT ON wristmemo.memos TO wristmemo_watcher;

-- Created first with `gcloud sql users create ... --type=CLOUD_IAM_SERVICE_ACCOUNT`.
GRANT wristmemo_watcher TO :"watcher_database_user";

COMMIT;
