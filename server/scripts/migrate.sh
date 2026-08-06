#!/usr/bin/env bash
# Applies migrations in order and records filename plus SHA-256 in a ledger, so
# a migration that changed after it was applied fails before any SQL runs.
#
# Modelled on the migrate.sh in a sibling private project, which is the
# established runner for this Cloud SQL instance.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${DATABASE_URL:?Set DATABASE_URL to an IAM-authenticated PostgreSQL connection.}"
: "${INGEST_DATABASE_USER:?Set INGEST_DATABASE_USER to the Cloud Run service account database user.}"

MIGRATIONS=(
  "0001_wristmemo.sql"
)

psql_db() {
  "${PSQL_BIN:-psql}" "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 "$@"
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${ROOT}/migrations/$1" | awk '{print $1}'
  else
    shasum -a 256 "${ROOT}/migrations/$1" | awk '{print $1}'
  fi
}

ensure_ledger() {
  psql_db <<'SQL'
CREATE SCHEMA IF NOT EXISTS wristmemo;
CREATE TABLE IF NOT EXISTS wristmemo.migration_ledger (
  version integer PRIMARY KEY CHECK (version > 0),
  filename text UNIQUE NOT NULL CHECK (filename ~ '^[0-9]{4}_[a-z0-9_]+[.]sql$'),
  checksum text NOT NULL CHECK (checksum ~ '^[0-9a-f]{64}$'),
  applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
SQL
}

recorded_checksum() {
  psql_db -tAc "SELECT checksum FROM wristmemo.migration_ledger WHERE filename = '$1'"
}

apply_migration() {
  local filename="$1" version="$2" expected actual
  actual="$(checksum "${filename}")"
  expected="$(recorded_checksum "${filename}")"

  if [[ -n "${expected}" ]]; then
    if [[ "${expected}" != "${actual}" ]]; then
      echo "FATAL: ${filename} changed after it was applied" >&2
      echo "  recorded ${expected}" >&2
      echo "  on disk  ${actual}" >&2
      exit 1
    fi
    echo "skip  ${filename} (already applied)"
    return
  fi

  echo "apply ${filename}"
  psql_db -v "ingest_database_user=${INGEST_DATABASE_USER}" -f "${ROOT}/migrations/${filename}"
  psql_db -c "INSERT INTO wristmemo.migration_ledger (version, filename, checksum)
              VALUES (${version}, '${filename}', '${actual}')"
}

ensure_ledger

version=0
for filename in "${MIGRATIONS[@]}"; do
  version=$((version + 1))
  apply_migration "${filename}" "${version}"
done

echo "done"
