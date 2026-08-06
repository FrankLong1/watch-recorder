#!/bin/bash
# Build → install → launch → tail logs on the real Apple Watch, in one command.
#
#   ./run.sh              build, install, launch, stream logs
#   ./run.sh --record     ...and start recording immediately (the intent path)
#   ./run.sh --logs       just stream logs from whatever is already installed
#   ./run.sh --devices    show what Xcode can see right now
#
# Requires the CoreDevice tunnel to the watch, which Tailscale breaks. The script
# checks for that up front rather than letting you hit a 3-minute timeout.

set -euo pipefail
cd "$(dirname "$0")"

SCHEME="WristMemo Watch App"
BUNDLE_ID="com.franklong.wristmemo.watchkitapp"
SUBSYSTEM="com.franklong.wristmemo"
DD="build/devicedd"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

# --- find the watch ------------------------------------------------------------
watch_json=$(mktemp)
trap 'rm -f "$watch_json"' EXIT
xcrun devicectl list devices --json-output "$watch_json" >/dev/null 2>&1 || true

read -r WATCH_ID WATCH_UDID WATCH_MODEL WATCH_NAME <<<"$(python3 - "$watch_json" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
for d in devices:
    hw = d.get("hardwareProperties", {})
    if str(hw.get("productType", "")).startswith("Watch"):
        print(d["identifier"], hw.get("udid", ""), hw.get("productType", ""),
              d.get("deviceProperties", {}).get("name", "Apple Watch"))
        break
PY
)"

if [[ "${1:-}" == "--devices" ]]; then
    xcrun devicectl list devices
    exit 0
fi

[[ -n "${WATCH_ID:-}" ]] || die "No Apple Watch found. Pair it in Xcode › Window › Devices and Simulators."
bold "Watch: $WATCH_NAME ($WATCH_MODEL)"

# Watch7,5 and Watch6,18 are the Ultras — everything else has no Action button.
case "$WATCH_MODEL" in
    Watch7,5|Watch6,18|Watch7,17) ;;
    *) warn "  No Action button on this model — test via the watch face complication or Control Center." ;;
esac

# --- the thing that actually breaks this ---------------------------------------
if pgrep -qf "io.tailscale.ipn.macsys.network-extension"; then
    warn ""
    warn "Tailscale is running. Its network extension blocks devicectl's tunnel to"
    warn "the watch, and you will get RemotePairingError 1001 after a long timeout."
    warn "Quit Tailscale (menu bar › Quit), then re-run. Re-enable it afterwards."
    warn ""
    read -r -p "Try anyway? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || exit 1
fi

if [[ "${1:-}" == "--logs" ]]; then
    bold "Streaming logs (ctrl-C to stop)…"
    exec xcrun devicectl device process monitor --device "$WATCH_ID" \
        --predicate "subsystem == \"$SUBSYSTEM\""
fi

# --- build ---------------------------------------------------------------------
bold "Building…"
if ! xcodebuild -project WristMemo.xcodeproj -scheme "$SCHEME" \
    -destination "id=$WATCH_UDID" -derivedDataPath "$DD" \
    -allowProvisioningUpdates build 2>&1 | grep -E "error:|warning:|BUILD"; then
    die "Build failed; refusing to install a possibly stale app."
fi

APP="$DD/Build/Products/Debug-watchos/$SCHEME.app"
[[ -d "$APP" ]] || die "Build produced no app at $APP"

# --- install -------------------------------------------------------------------
bold "Installing to $WATCH_NAME…"
xcrun devicectl device install app --device "$WATCH_ID" "$APP"

# --- launch --------------------------------------------------------------------
launch_args=()
[[ "${1:-}" == "--record" ]] && launch_args=(-WristMemoAutoRecord YES)

bold "Launching…"
xcrun devicectl device process launch --device "$WATCH_ID" --console \
    "$BUNDLE_ID" "${launch_args[@]}"
