\set ON_ERROR_STOP on

BEGIN;

-- The phone pulls its own transcript history in transcription order. This
-- keeps the cursor query bounded as the durable transcript archive grows.
CREATE INDEX IF NOT EXISTS memos_user_transcribed
  ON wristmemo.memos (user_id, transcribed_at ASC, id ASC)
  WHERE transcript IS NOT NULL AND transcribed_at IS NOT NULL;

COMMIT;
