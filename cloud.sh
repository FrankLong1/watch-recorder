#!/bin/bash
# Drive the upload leg end to end against the real Cloud Run service.
#
#   ./cloud.sh              build, plant a memo, upload, verify
#   ./cloud.sh --db         ...and confirm the row in Cloud SQL
#   ./cloud.sh --say "..."  use your own words instead of the default memo
#   ./cloud.sh --keep       leave the memo in the container afterwards
#
# sim.sh covers the watch: recording, pre-arm, crash recovery, latency.
# This covers what happens after — leg ② of 1a_UPLOAD_PATHS.md.
#
# It does NOT need a watch, a pair, or WatchConnectivity. A memo is planted
# directly into the phone app's container exactly as `session(_:didReceive:)`
# would have left it, which makes the upload path testable on its own.
#
# Credentials come from .env via SIMCTL_CHILD_*, so no token is ever written
# into the Xcode scheme (which is committed) or into the repo.
#
# Caveat worth knowing: the simulator has no background transfer daemon, so
# TranscriptionClient falls back to a default URLSession there. This proves the
# request, auth, retry policy and state machine. It cannot prove that an upload
# survives the app being suspended — only hardware shows that.
set -euo pipefail
cd "$(dirname "$0")"

DO_DB=0; KEEP=0; PHRASE="Follow up. Call the broker about the NVDA position."
while [[ $# -gt 0 ]]; do
    case "$1" in
        --db)   DO_DB=1; shift ;;
        --keep) KEEP=1; shift ;;
        --say)  PHRASE="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
pass() { printf '\033[32m  ✓ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m  ✗ %s\033[0m\n' "$1" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

BID=com.franklong.wristmemo
WORK="${TMPDIR:-/tmp}/wristmemo-cloud"
mkdir -p "$WORK"

# --- credentials ---------------------------------------------------------------
[[ -f .env ]] || die ".env not found. It holds WRISTMEMO_INGEST_TOKEN; see server/README.md."
TOKEN=$(grep -E '^WRISTMEMO_INGEST_TOKEN=' .env | head -1 | cut -d= -f2- | tr -d '\n\r')
[[ -n "$TOKEN" ]] || die "WRISTMEMO_INGEST_TOKEN missing from .env"

URL="${WRISTMEMO_INGEST_URL:-$(grep -E '^WRISTMEMO_INGEST_URL=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\n\r')}"
if [[ -z "$URL" ]]; then
    URL=$(terraform -chdir=server/terraform output -raw service_url 2>/dev/null || true)
fi
[[ -n "$URL" ]] || die "No service URL. Add WRISTMEMO_INGEST_URL to .env, or apply the Terraform."
bold "Service: $URL"

# Fail fast and legibly rather than after a four-minute build.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$URL/readyz" || echo 000)
[[ "$code" == "200" ]] || die "Service is not ready (/readyz returned $code)."
pass "service reachable"

# --- simulator -----------------------------------------------------------------
UDID=$(xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
best=None
for runtime, devices in d.items():
    if "iOS" not in runtime: continue
    for dev in devices:
        if not dev.get("isAvailable"): continue
        if not dev["name"].startswith("iPhone"): continue
        # Prefer one that is already booted; booting costs ~30s.
        if dev["state"] == "Booted": print(dev["udid"]); sys.exit(0)
        best = best or dev["udid"]
print(best or "")
')
[[ -n "$UDID" ]] || die "No available iPhone simulator."
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
pass "simulator ready"

# --- build and install ---------------------------------------------------------
bold "Building"
xcodebuild -project WristMemo.xcodeproj -scheme WristMemo -destination "id=$UDID" \
    CODE_SIGNING_ALLOWED=NO -derivedDataPath "$WORK/dd" build > "$WORK/build.log" 2>&1 \
    || { tail -30 "$WORK/build.log"; die "build failed — full log at $WORK/build.log"; }
APP="$WORK/dd/Build/Products/Debug-iphonesimulator/WristMemo.app"
[[ -d "$APP" ]] || die "built, but no app at $APP"
xcrun simctl terminate "$UDID" "$BID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
pass "installed"

# --- plant a memo --------------------------------------------------------------
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BID" data)
MEMOS="$CONTAINER/Documents/Memos"
mkdir -p "$MEMOS"

say -o "$WORK/memo.aiff" "$PHRASE"
afconvert -f m4af -d aac -b 32000 "$WORK/memo.aiff" "$WORK/memo.m4a"

ID=$(uuidgen | tr 'A-Z' 'a-z')
cp "$WORK/memo.m4a" "$MEMOS/$ID.m4a"
DURATION=$(python3 -c "print(round($(stat -f%z "$WORK/memo.m4a") / 4000, 1))")
python3 - "$MEMOS/$ID.json" "$DURATION" <<'PY'
import json, sys, time
# JSONEncoder's default Date strategy is seconds since the 2001 Apple epoch, so
# a POSIX timestamp has to be shifted or the memo decodes as some date in 2058.
json.dump({"recordedAt": time.time() - 978307200,
           "duration": float(sys.argv[2]),
           "uploadState": "pending"}, open(sys.argv[1], "w"))
PY
pass "planted memo $ID"

# --- run -----------------------------------------------------------------------
bold "Uploading"
SIMCTL_CHILD_WRISTMEMO_INGEST_URL="$URL" \
SIMCTL_CHILD_WRISTMEMO_INGEST_TOKEN="$TOKEN" \
    xcrun simctl launch "$UDID" "$BID" >/dev/null

STATE=pending
for _ in $(seq 1 90); do
    STATE=$(python3 -c "import json;print(json.load(open('$MEMOS/$ID.json')).get('uploadState',''))" 2>/dev/null || echo "")
    [[ "$STATE" == "uploaded" || "$STATE" == "failed" ]] && break
    # Doubles as a liveness check and as the poll delay.
    curl -s -o /dev/null --max-time 1 "$URL/readyz" || true
done

FAILURES=0
if [[ "$STATE" == "uploaded" ]]; then
    pass "app reports uploaded"
else
    fail "app reports '$STATE' (expected uploaded)"
    FAILURES=$((FAILURES + 1))
    xcrun simctl spawn "$UDID" log show --last 3m --info \
        --predicate 'subsystem == "com.franklong.wristmemo"' --style compact 2>/dev/null | tail -8
fi

# --- verify the row ------------------------------------------------------------
if [[ $DO_DB -eq 1 ]]; then
    bold "Checking Cloud SQL"
    PSQL="${PSQL_BIN:-/opt/homebrew/opt/libpq/bin/psql}"
    command -v cloud-sql-proxy >/dev/null || die "cloud-sql-proxy not installed (brew install cloud-sql-proxy)"
    [[ -x "$PSQL" ]] || die "psql not found at $PSQL (brew install libpq)"

    cloud-sql-proxy --auto-iam-authn --port 55431 \
        --impersonate-service-account wristmemo-migrator@gv-data-platform.iam.gserviceaccount.com \
        gv-data-platform:us-central1:demo-agent-inbox-postgres > "$WORK/proxy.log" 2>&1 &
    PROXY_PID=$!
    trap 'kill $PROXY_PID 2>/dev/null || true' EXIT

    DSN='host=127.0.0.1 port=55431 dbname=wristmemo user=wristmemo-migrator@gv-data-platform.iam sslmode=disable'
    # IAM grants can take a moment to propagate on a freshly created identity.
    for _ in $(seq 1 25); do "$PSQL" "$DSN" -X -tAc "SELECT 1" >/dev/null 2>&1 && break; done

    ROW=$("$PSQL" "$DSN" -X -tAc \
        "SELECT coalesce(route,'(none)') || ' | ' || coalesce(body,'') FROM wristmemo.memos WHERE id='$ID';" 2>/dev/null || echo "")
    if [[ -n "$ROW" ]]; then
        pass "row in Cloud SQL: $ROW"
    else
        fail "no row for $ID"
        FAILURES=$((FAILURES + 1))
    fi
fi

# --- cleanup -------------------------------------------------------------------
if [[ $KEEP -eq 0 ]]; then
    rm -f "$MEMOS/$ID.m4a" "$MEMOS/$ID.json"
else
    bold "Kept $MEMOS/$ID.*"
fi

echo
if [[ $FAILURES -eq 0 ]]; then
    printf '\033[32mgreen\033[0m\n'
else
    printf '\033[31m%d failure(s)\033[0m\n' "$FAILURES"
    exit 1
fi
