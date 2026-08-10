import { expect, test } from "bun:test";
import { DATABASE_CONNECTIONS_PER_INSTANCE } from "./db";

test("limits each ingest instance to a small Cloud SQL connection budget", () => {
  // Advisory locks hold a connection through transcription. The Cloud Run
  // instance ceiling is one, so this must remain comfortably below the shared
  // instance's usable connection slots.
  expect(DATABASE_CONNECTIONS_PER_INSTANCE).toBe(2);
});
