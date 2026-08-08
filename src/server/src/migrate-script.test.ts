import { expect, test } from "bun:test";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

test("fresh databases record retired watcher grants without applying them", async () => {
  const directory = await mkdtemp(join(tmpdir(), "wristmemo-migrate-"));
  const fakePsql = join(directory, "psql");
  const capture = join(directory, "calls.txt");
  const serverRoot = resolve(import.meta.dir, "..");
  try {
    await writeFile(fakePsql, `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"$FAKE_PSQL_CAPTURE"
if [[ "$*" == *"SELECT checksum FROM wristmemo.migration_ledger"* ]]; then
  exit 0
fi
cat >/dev/null || true
`, { mode: 0o700 });
    await chmod(fakePsql, 0o700);

    const process = Bun.spawn(["bash", "scripts/migrate.sh"], {
      cwd: serverRoot,
      env: {
        ...processEnvWithoutDatabaseUrl(),
        DATABASE_URL: "postgres://migration.invalid/wristmemo",
        INGEST_DATABASE_USER: "wristmemo_local",
        PSQL_BIN: fakePsql,
        FAKE_PSQL_CAPTURE: capture,
      },
      stdout: "pipe",
      stderr: "pipe",
    });
    const [exitCode, stdout, stderr] = await Promise.all([
      process.exited,
      new Response(process.stdout).text(),
      new Response(process.stderr).text(),
    ]);

    expect(exitCode, stderr).toBe(0);
    expect(stdout).toContain("retire 0002_watcher_read_role.sql");
    expect(stdout).toContain("retire 0003_watcher_operator_role.sql");
    const calls = await readFile(capture, "utf8");
    expect(calls).not.toContain("-f ".concat(join(serverRoot, "migrations/0002_watcher_read_role.sql")));
    expect(calls).not.toContain("-f ".concat(join(serverRoot, "migrations/0003_watcher_operator_role.sql")));
    expect(calls).toContain("-f ".concat(join(serverRoot, "migrations/0004_retire_watcher_database_access.sql")));
    expect(calls).toContain("-f ".concat(join(serverRoot, "migrations/0005_transcript_history_index.sql")));
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

function processEnvWithoutDatabaseUrl(): Record<string, string> {
  const environment: Record<string, string> = {};
  for (const [name, value] of Object.entries(process.env)) {
    if (value !== undefined && name !== "DATABASE_URL") environment[name] = value;
  }
  return environment;
}
