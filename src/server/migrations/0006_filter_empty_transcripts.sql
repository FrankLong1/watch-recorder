\set ON_ERROR_STOP on

BEGIN;

-- A zero-word model response is retained as an idempotent no-content outcome,
-- but must never enter either the phone transcript library or watcher feed.
-- Rebuild the cursor index so it contains only admissible transcripts.
DROP INDEX IF EXISTS wristmemo.memos_user_transcribed;
CREATE INDEX memos_user_transcribed
  ON wristmemo.memos (user_id, transcribed_at ASC, id ASC)
  WHERE transcript <> '' AND transcribed_at IS NOT NULL;

COMMIT;
