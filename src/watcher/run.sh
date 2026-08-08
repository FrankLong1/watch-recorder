#!/usr/bin/env bash
# Runs the workstation-local WristMemo watcher against the metadata-only HTTPS feed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${WRISTMEMO_WATCHER_FEED_URL:?Set the Cloud Run watcher feed URL.}"
: "${WRISTMEMO_GOOGLE_AUDIENCE:?Set the Google OAuth server client ID.}"

# State updates are intentionally serial: a retry must not race the poller's
# in-memory ledger and turn a completed Codex run back into a stale failure.
if [[ "${1:-watch}" != "--status" ]]; then
  exec 9>"$ROOT/.watcher.lock"
  if ! flock -n 9; then
    echo "The watcher is already running; stop it before bootstrap, retry, or one-shot work." >&2
    exit 75
  fi
fi

export WRISTMEMO_WATCHER_HOME="$ROOT"
exec bun run "$ROOT/wristmemo-watcher.ts" "$@"
