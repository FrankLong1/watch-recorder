#!/bin/bash
# Build → install → drive → assert on the watchOS simulator, in one command.
# `./scripts/sim.sh --help` documents every flag; run.sh is the real-hardware counterpart.

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/project-config.sh

SCHEME="WristMemo Watch App"
BUNDLE_ID="$WRISTMEMO_WATCH_BUNDLE_ID"
SUBSYSTEM="$WRISTMEMO_LOGGING_SUBSYSTEM"
DD="build/simdd"
SHOTS="build/shots"

SIM_SELECTOR=""
RECORD_SECONDS=3
TIMEOUT=45
MAX_FIRST_SAMPLE_MS=20000
SCENARIO="all"
DO_BUILD=1
KEEP=0
RUN_UNIT=1
RUN_UI=1
RUN_HARNESS=1
REPEAT=1
WATCH=0

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }
pass() { printf '\033[32m  ✓ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m  ✗ %s\033[0m\n' "$1" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

usage() {
    cat <<'USAGE'
sim.sh — build, install, drive and assert on the watchOS simulator.

  ./scripts/sim.sh                      unit tests, UI taps, and every harness scenario
  ./scripts/sim.sh --unit               Swift Testing logic bundle only (~2s)
  ./scripts/sim.sh --ui                 XCUITest taps only
  ./scripts/sim.sh --scenario NAME      one scenario: record-save|prearm|recovery|latency|all
  ./scripts/sim.sh --watch              re-run on save
  ./scripts/sim.sh --repeat N           run N times; reports any run that differs
  ./scripts/sim.sh --devices            list watch simulators

  --simulator UDID|NAME         which simulator (default: a booted watch, else the first)
  --record-seconds N            recording length for record-save (default 3)
  --timeout N                   per-condition poll deadline in seconds (default 45)
  --max-first-sample-ms N       latency budget (default 20000; simulator, not device)
  --no-build                    reuse the last build
  --keep                        keep a screenshot and the parsed index in build/shots

The simulator cannot test the physical Action button or real press-to-record
latency. -WristMemoAutoRecord is the stand-in for the same in-process request
path; see docs/operations/LATENCY.md and scripts/run.sh for the device story.
USAGE
    exit 0
}

SCENARIOS="record-save prearm recovery latency all"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --simulator)           SIM_SELECTOR="$2"; shift 2 ;;
        --record-seconds)      RECORD_SECONDS="$2"; shift 2 ;;
        --timeout)             TIMEOUT="$2"; shift 2 ;;
        --max-first-sample-ms) MAX_FIRST_SAMPLE_MS="$2"; shift 2 ;;
        # Validated here rather than after the build — a typo should not cost a
        # full compile before it is reported.
        --scenario)            SCENARIO="$2"; RUN_UNIT=0; RUN_UI=0
                               [[ " $SCENARIOS " == *" $SCENARIO "* ]] \
                                   || die "Unknown scenario '$SCENARIO' ($SCENARIOS)"
                               shift 2 ;;
        --no-build)            DO_BUILD=0; shift ;;
        --keep)                KEEP=1; shift ;;
        --unit)                RUN_UI=0; RUN_HARNESS=0; shift ;;
        --ui)                  RUN_UNIT=0; RUN_HARNESS=0; shift ;;
        --repeat)              REPEAT="$2"; shift 2 ;;
        --watch)               WATCH=1; shift ;;
        --devices)             xcrun simctl list devices available | sed -n '/watchOS/,/^--/p'; exit 0 ;;
        --help|-h)             usage ;;
        *)                     die "Unknown flag: $1  (--help for usage)" ;;
    esac
done

command -v xcrun >/dev/null || die "xcrun not found — install Xcode command line tools."
xcrun simctl help >/dev/null 2>&1 || die "simctl unavailable. Is CoreSimulator running? Open Simulator.app once."

# --- pick a simulator ----------------------------------------------------------
# Prefer an already-booted watch (fast); otherwise take the first available one
# and boot it. Never trust a hard-coded UDID — they change per machine.
resolve_simulator() {
    local json; json=$(mktemp); trap 'rm -f "$json"' RETURN
    xcrun simctl list devices available --json > "$json" 2>/dev/null || die "simctl list failed"
    python3 - "$json" "${SIM_SELECTOR:-}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
want = sys.argv[2] if len(sys.argv) > 2 else ""
watches = []
for runtime, devices in data.get("devices", {}).items():
    if "watchOS" not in runtime:
        continue
    for d in devices:
        if d.get("isAvailable"):
            watches.append((d["udid"], d["name"], d.get("state", "")))
if not watches:
    sys.exit(0)
if want:
    hits = [w for w in watches if want in (w[0], w[1])]
    if len(hits) > 1:
        print("AMBIGUOUS " + " | ".join(f"{n} ({u})" for u, n, _ in hits)); sys.exit(0)
    if not hits:
        print("NOMATCH"); sys.exit(0)
    print(f"{hits[0][0]} {hits[0][1]}"); sys.exit(0)
booted = [w for w in watches if w[2] == "Booted"]
pick = booted[0] if booted else watches[0]
print(f"{pick[0]} {pick[1]}")
PY
}

read -r SIM SIM_NAME <<<"$(resolve_simulator)" || true
[[ -n "${SIM:-}" ]] || die "No available watchOS simulator. Install a watchOS runtime in Xcode › Settings › Components."
[[ "$SIM" != "AMBIGUOUS" ]] || die "Simulator name matched more than one device. Pass a UDID to --simulator."
[[ "$SIM" != "NOMATCH" ]] || die "No watch simulator matched '$SIM_SELECTOR'. Try --devices."

bold "Simulator: $SIM_NAME ($SIM)"
if [[ "$(xcrun simctl list devices | grep "$SIM" | grep -c Booted || true)" == "0" ]]; then
    bold "Booting…"
    xcrun simctl boot "$SIM" 2>/dev/null || true
fi
xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || die "Simulator never finished booting."

# --- build ---------------------------------------------------------------------
# `build/` is gitignored, so it does not exist in a fresh clone. Everything below
# writes logs and derived data there.
mkdir -p "$(dirname "$DD")"

# build-for-testing so --repeat and both test bundles reuse a single build.
# Shared with watch mode, which rebuilds on every save.
build_once() {
    xcodebuild build-for-testing -project src/swift_app/WristMemo.xcodeproj -scheme "$SCHEME" \
        -destination "id=$SIM" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO > "$DD.log" 2>&1
}
build_errors() { grep -E "error:" "$DD.log" | head -20; }

if (( DO_BUILD )); then
    bold "Building…"
    build_once || { build_errors; die "Build failed (full log: $DD.log)"; }
fi

APP="$DD/Build/Products/Debug-watchsimulator/$SCHEME.app"
[[ -d "$APP" ]] || die "No built app at $APP — run without --no-build."

# `simctl install` hands out a NEW data container every time, so the store path
# has to be re-resolved after any install — caching it once goes stale silently
# and every file assertion then inspects an empty directory.
resolve_store() {
    STORE="$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data)/Library/Application Support/WristMemo"
}

install_app() {
    xcrun simctl install "$SIM" "$APP" >/dev/null
    # The watch simulator records through the Mac microphone; macOS must have
    # granted Simulator.app microphone access for audio to be non-silent.
    xcrun simctl privacy "$SIM" grant microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
    resolve_store
}
install_app
bold "Store: ${STORE/#$HOME/~}"

# --- helpers -------------------------------------------------------------------
# Poll for a condition instead of sleeping and hoping. Everything timing-related
# in this script goes through here.
poll_until() {
    local deadline=$(( $(date +%s) + TIMEOUT ))
    while (( $(date +%s) < deadline )); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 0.25
    done
    return 1
}

# Reset by clearing the store, not by reinstalling: a reinstall would move the
# container out from under every subsequent assertion, and deleting the store is
# both faster and exactly the state a fresh install produces.
reset_app_state() {
    xcrun simctl terminate "$SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true
    resolve_store
    rm -rf "$STORE"
}

memo_count()   { python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$STORE/memos.json" 2>/dev/null; }
has_memos()    { [[ "$(memo_count || echo 0)" -ge "${1:-1}" ]]; }
capture_bytes_over() {
    local threshold="$1"
    local biggest
    biggest=$(find "$STORE/Captures" -name '*.caf' -exec stat -f%z {} \; 2>/dev/null | sort -rn | head -1)
    [[ -n "$biggest" && "$biggest" -gt "$threshold" ]]
}

# Log severity, not string matching: a memo whose text contains "error" is not a
# failure. messageType comes from the structured log itself.
assert_log_clean() {
    local since=$(( $(date +%s) - SCENARIO_START + 5 ))
    local bad
    bad=$(xcrun simctl spawn "$SIM" log show --style ndjson --last "${since}s" \
            --predicate "subsystem == \"$SUBSYSTEM\"" 2>/dev/null \
          | python3 -c "
import sys, json
bad = []
for line in sys.stdin:
    line = line.strip()
    if not line.startswith('{'): continue
    try: e = json.loads(line)
    except Exception: continue
    if e.get('messageType') in ('Error', 'Fault'):
        bad.append(f\"[{e.get('messageType')}] {e.get('category','?')}: {e.get('eventMessage','')}\")
print('\n'.join(bad))")
    if [[ -n "$bad" ]]; then fail "log has error/fault entries:"; echo "$bad" | sed 's/^/      /'; return 1; fi
    return 0
}

assert_index_sorted() {
    python3 - "$STORE/memos.json" <<'PY'
import json, sys
memos = json.load(open(sys.argv[1]))
dates = [m["createdAt"] for m in memos]
ids = [m["id"] for m in memos]
problems = []
if dates != sorted(dates, reverse=True):
    problems.append(f"index not newest-first: {dates}")
if len(set(ids)) != len(ids):
    problems.append(f"duplicate ids: {ids}")
if problems:
    print("; ".join(problems)); sys.exit(1)
PY
}

FAILURES=0
scenario_failed() { fail "$1"; FAILURES=$((FAILURES + 1)); }

# Announce, reset, and mark the start of the log window `assert_log_clean` reads.
SCENARIO_START=0
begin_scenario() {
    bold "scenario: $1"
    reset_app_state
    SCENARIO_START=$(date +%s)
}

# --- scenarios -----------------------------------------------------------------
scenario_record_save() {
    begin_scenario record-save
    xcrun simctl launch "$SIM" "$BUNDLE_ID" \
        -WristMemoAutoRecord YES -WristMemoAutoStopAfter "$RECORD_SECONDS" >/dev/null

    if ! poll_until has_memos 1; then scenario_failed "no memo was saved within ${TIMEOUT}s"; return; fi
    pass "memo saved"

    if ! python3 - "$STORE/memos.json" "$RECORD_SECONDS" <<'PY'
import json, sys
memos = json.load(open(sys.argv[1])); want = float(sys.argv[2])
if len(memos) != 1: print(f"expected 1 memo, got {len(memos)}"); sys.exit(1)
got = memos[0]["duration"]
# Generous tolerance: simulator scheduling, not a stopwatch.
if abs(got - want) > 1.5: print(f"duration {got:.2f}s is not within 1.5s of {want}s"); sys.exit(1)
PY
    then scenario_failed "memo duration wrong"; else pass "duration within tolerance of ${RECORD_SECONDS}s"; fi

    if ! assert_index_sorted; then scenario_failed "index ordering"; else pass "index newest-first, no duplicates"; fi
    if ! assert_log_clean; then scenario_failed "log not clean"; else pass "no error/fault log entries"; fi
}

scenario_prearm() {
    begin_scenario prearm
    xcrun simctl launch "$SIM" "$BUNDLE_ID" >/dev/null

    # Idle launch arms the next recorder: exactly one header-only capture.
    # This is not a "drained directory" assertion — that file is the pre-arm.
    if ! poll_until test -d "$STORE/Captures"; then scenario_failed "Captures never created"; return; fi
    if ! poll_until bash -c "ls '$STORE/Captures'/*.caf >/dev/null 2>&1"; then
        scenario_failed "no pre-armed capture appeared"; return
    fi
    local n; n=$(find "$STORE/Captures" -name '*.caf' | wc -l | tr -d ' ')
    local size; size=$(find "$STORE/Captures" -name '*.caf' -exec stat -f%z {} \; | head -1)
    if [[ "$n" != "1" ]]; then scenario_failed "expected 1 pre-armed capture, found $n"; else pass "exactly one pre-armed capture"; fi
    if [[ "$size" -gt 20000 ]]; then scenario_failed "pre-arm is $size bytes — expected a header, not audio"; else pass "pre-arm is header-only ($size bytes)"; fi
    if ! assert_log_clean; then scenario_failed "log not clean"; fi
}

scenario_recovery() {
    begin_scenario recovery

    # 1. a normal, current memo
    xcrun simctl launch "$SIM" "$BUNDLE_ID" -WristMemoAutoRecord YES -WristMemoAutoStopAfter 2 >/dev/null
    if ! poll_until has_memos 1; then scenario_failed "setup memo never saved"; return; fi
    xcrun simctl terminate "$SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true
    pass "current memo saved"

    # 2. a REAL capture, killed mid-recording. A fabricated byte file would not
    #    exercise the same decode path, so record until the capture is safely
    #    past the minimum-duration byte threshold, then hard-kill.
    xcrun simctl launch "$SIM" "$BUNDLE_ID" -WristMemoAutoRecord YES >/dev/null
    if ! poll_until capture_bytes_over 60000; then scenario_failed "capture never grew past threshold"; return; fi
    xcrun simctl terminate "$SIM" "$BUNDLE_ID" >/dev/null
    pass "killed mid-recording, leaving a real orphan"

    local orphan; orphan=$(find "$STORE/Captures" -name '*.caf' -size +50000c | head -1)
    [[ -n "$orphan" ]] || { scenario_failed "no orphan capture on disk"; return; }

    # 3. backdate it. MemoStore reads the *creation* date, so mtime alone is not
    #    enough — and if the volume refuses, fail loudly rather than silently
    #    degrading this into an mtime test.
    SetFile -d '08/01/2026 09:00:00' -m '08/01/2026 09:00:00' "$orphan" 2>/dev/null || {
        scenario_failed "SetFile unavailable — cannot backdate; recovery ordering unverified"; return; }
    local birth; birth=$(stat -f '%SB' -t '%Y-%m-%d' "$orphan")
    if [[ "$birth" != "2026-08-01" ]]; then
        scenario_failed "creation date did not change (got $birth) — this volume ignores it"; return
    fi
    pass "orphan backdated to $birth"

    # 4. relaunch idle; startup recovers it
    SCENARIO_START=$(date +%s)
    xcrun simctl launch "$SIM" "$BUNDLE_ID" >/dev/null
    if ! poll_until has_memos 2; then scenario_failed "orphan was never recovered"; return; fi
    pass "orphan recovered"

    if ! assert_index_sorted; then scenario_failed "index ordering after recovery"; return; fi
    # The point of the whole scenario: the recovered memo uses its own date and
    # therefore sorts last, rather than being inserted at position zero.
    if ! python3 - "$STORE/memos.json" <<'PY'
import json, sys, datetime
memos = json.load(open(sys.argv[1]))
if len(memos) != 2: print(f"expected 2 memos, got {len(memos)}"); sys.exit(1)
def when(m): return datetime.datetime(2001,1,1) + datetime.timedelta(seconds=m["createdAt"])
first, last = when(memos[0]), when(memos[-1])
if last.date() != datetime.date(2026, 8, 1):
    print(f"recovered memo is not last — order is {[str(when(m)) for m in memos]}"); sys.exit(1)
if first <= last:
    print("recovered memo did not sort below the current one"); sys.exit(1)
PY
    then scenario_failed "recovered memo sorted to the top instead of by its own date"
    else pass "backdated memo sorts below the current one"; fi
    if ! assert_log_clean; then scenario_failed "log not clean"; fi
}

scenario_latency() {
    begin_scenario latency
    xcrun simctl launch "$SIM" "$BUNDLE_ID" -WristMemoAutoRecord YES -WristMemoAutoStopAfter 8 >/dev/null

    local ms=""
    local deadline=$(( $(date +%s) + TIMEOUT ))
    while (( $(date +%s) < deadline )); do
        ms=$(xcrun simctl spawn "$SIM" log show --style compact --last "$(( $(date +%s) - SCENARIO_START + 5 ))s" \
                --predicate "subsystem == \"$SUBSYSTEM\"" 2>/dev/null \
             | sed -n 's/.*\[latency\] first sample at \([0-9]*\)ms.*/\1/p' | tail -1)
        [[ -n "$ms" ]] && break
        sleep 0.5
    done

    if [[ -z "$ms" ]]; then scenario_failed "never saw the first-sample marker in the log"; return; fi
    if (( ms > MAX_FIRST_SAMPLE_MS )); then
        scenario_failed "first sample at ${ms}ms exceeds budget ${MAX_FIRST_SAMPLE_MS}ms"
    else
        pass "first sample at ${ms}ms (budget ${MAX_FIRST_SAMPLE_MS}ms, simulator — not device latency)"
    fi
}

run_tests_bundle() {  # $1 = target name, $2 = label
    bold "$2"
    local out="$DD-$1.log"
    if xcodebuild test-without-building -project src/swift_app/WristMemo.xcodeproj -scheme "$SCHEME" \
        -destination "id=$SIM" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO \
        -only-testing:"$1" > "$out" 2>&1; then
        grep -E "Test run with .* passed|with [0-9]+ test" "$out" | tail -1 | sed 's/^/  /' || true
        # A bundle that crashes on launch can still exit 0 having run nothing.
        # Silent zero-coverage is the worst outcome, so count what actually ran.
        # Both runners appear in one log: XCTest reports "Executed N tests" and
        # Swift Testing "Test run with N tests" — either being non-zero is fine.
        local ran
        ran=$(python3 - "$out" <<'PY'
import re, sys
text = open(sys.argv[1], errors='ignore').read()
counts  = [int(m) for m in re.findall(r'Test run with (\d+) test', text)]
counts += [int(m) for m in re.findall(r'Executed (\d+) test', text)]
print(max(counts) if counts else 0)
PY
)
        if [[ "${ran:-0}" -eq 0 ]]; then
            scenario_failed "$1 ran ZERO tests (crash on launch? see $out)"
        else
            pass "$1 passed ($ran tests)"
        fi
    else
        # `|| true` on every diagnostic: a grep that matches nothing returns 1,
        # which under `set -e` would abort before the failure is ever reported.
        { grep -E "error:|✘|failed \(|XCTAssert|Restarting after unexpected exit" "$out" || true; } \
            | head -15 | sed 's/^/      /'
        { grep -A8 "^Failing tests:" "$out" || true; } | head -10 | sed 's/^/      /'
        scenario_failed "$1 failed (full log: $out)"
    fi
}

run_everything() {
    FAILURES=0
    (( RUN_UNIT )) && run_tests_bundle WristMemoTests "unit tests"
    (( RUN_UI ))   && run_tests_bundle WristMemoUITests "UI taps"
    if (( RUN_HARNESS )); then
        case "$SCENARIO" in
            all)          scenario_record_save; scenario_prearm; scenario_recovery; scenario_latency ;;
            record-save)  scenario_record_save ;;
            prearm)       scenario_prearm ;;
            recovery)     scenario_recovery ;;
            latency)      scenario_latency ;;
        esac
    fi
    if (( KEEP )); then
        mkdir -p "$SHOTS"
        xcrun simctl io "$SIM" screenshot "$SHOTS/$(date +%H%M%S).png" >/dev/null 2>&1 || true
        [[ -f "$STORE/memos.json" ]] && cp "$STORE/memos.json" "$SHOTS/memos-$(date +%H%M%S).json" || true
        bold "evidence kept in $SHOTS"
    fi
    return $FAILURES
}

# --- watch mode ----------------------------------------------------------------
# Plain mtime polling: fswatch/entr/watchexec are not installed and this needs
# no new dependencies.
WATCHED="WatchApp Shared WatchControls WristMemoTests WristMemoUITests"
if (( WATCH )); then
    bold "Watching $WATCHED — ctrl-C to stop"
    last=""
    while true; do
        now=$(find $WATCHED -name '*.swift' -exec stat -f '%m %N' {} \; 2>/dev/null | sort | md5)
        if [[ "$now" != "$last" ]]; then
            last="$now"
            printf '\n\033[1m--- %s ---\033[0m\n' "$(date +%H:%M:%S)"
            if build_once && install_app; then
                run_everything && bold "green" || warn "$FAILURES failure(s)"
            else
                build_errors; warn "build failed"
            fi
        fi
        sleep 1
    done
fi

# --- repeat mode ---------------------------------------------------------------
if (( REPEAT > 1 )); then
    bold "Running the suite $REPEAT times to surface races"
    declare -a results
    for ((i = 1; i <= REPEAT; i++)); do
        printf '\n\033[1m--- run %d/%d ---\033[0m\n' "$i" "$REPEAT"
        if run_everything; then results+=("pass"); else results+=("FAIL($FAILURES)"); fi
    done
    echo
    bold "Results across $REPEAT runs:"
    printf '  %s\n' "${results[@]}" | sort | uniq -c
    [[ " ${results[*]} " == *FAIL* ]] && die "not reproducible — see failures above"
    bold "all $REPEAT runs identical"
    exit 0
fi

run_everything
echo
if (( FAILURES == 0 )); then bold "green"; else die "$FAILURES failure(s)"; fi
