#!/bin/bash
# Build and install WristMemo on physical hardware.
#
#   ./scripts/run.sh              build for the paired iPhone (the reliable default)
#   ./scripts/run.sh --phone      same as above
#   ./scripts/run.sh --watch      build and install directly on the Watch
#   ./scripts/run.sh --record     direct Watch build, then launch into recording
#   ./scripts/run.sh --devices    show devices Xcode can currently use
#   ./scripts/run.sh --logs       explain the supported watchOS logging path
#
# The phone path embeds the Watch app in WristMemo.app, then lets the paired
# iPhone deliver it. It avoids the fragile Mac → Watch Wi-Fi tunnel entirely.
# Use --watch only when that tunnel is healthy and you want the faster loop.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="src/swift_app/WristMemo.xcodeproj"
PHONE_SCHEME="WristMemo"
WATCH_SCHEME="WristMemo Watch App"
PHONE_BUNDLE_ID="com.franklong.wristmemo"
WATCH_BUNDLE_ID="com.franklong.wristmemo.watchkitapp"
PHONE_DD="build/phone-dd"
WATCH_DD="build/watch-dd"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: ./scripts/run.sh [--phone | --watch | --record | --devices | --logs]

  --phone    Build the iPhone companion and deliver its embedded Watch app (default).
  --watch    Build and install directly on the Watch. Requires the Mac → Watch tunnel.
  --record   Same as --watch, then launch straight into recording.
  --devices  Show devices that Xcode can currently reach.
  --logs     Explain how to capture supported watchOS device logs.
EOF
}

mode="phone"
for argument in "$@"; do
    case "$argument" in
        --phone)   mode="phone" ;;
        --watch)   mode="watch" ;;
        --record)  mode="record" ;;
        --devices) mode="devices" ;;
        --logs)    mode="logs" ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $argument (try --help)" ;;
    esac
done

if [[ "$mode" == "devices" ]]; then
    exec xcrun devicectl list devices
fi

if [[ "$mode" == "logs" ]]; then
    bold "watchOS logging"
    warn "This Xcode version has no 'devicectl device process monitor' command."
    printf '%s\n' \
        "The app now shows a specific recording failure on the Watch itself." \
        "For full watchOS unified logs, install Apple's watchOS logging profile on" \
        "the paired iPhone, connect that iPhone to the Mac, then use Console.app" \
        "and filter for subsystem: $PHONE_BUNDLE_ID" \
        "See: https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs"
    exit 0
fi

device_json=$(mktemp)
trap 'rm -f "$device_json"' EXIT

if ! xcrun devicectl list devices --json-output "$device_json" >/dev/null 2>&1; then
    die "Xcode could not read connected devices. Unlock the iPhone, reconnect USB, then retry."
fi

read_device() {
    local prefix="$1"
    python3 - "$device_json" "$prefix" <<'PY'
import json
import sys

path, prefix = sys.argv[1:]
try:
    devices = json.load(open(path))["result"]["devices"]
except Exception:
    sys.exit(0)

for device in devices:
    hardware = device.get("hardwareProperties", {})
    product_type = str(hardware.get("productType", ""))
    if product_type.startswith(prefix):
        identifier = str(device.get("identifier", ""))
        udid = str(hardware.get("udid", ""))
        name = str(device.get("deviceProperties", {}).get("name", product_type))
        print("\t".join((identifier, udid, product_type, name)))
        break
PY
}

build_for() {
    local scheme="$1"
    local udid="$2"
    local name="$3"
    local derived_data="$4"
    local build_log
    build_log=$(mktemp)

    bold "Building ${scheme} for ${name}…"
    if xcodebuild -project "$PROJECT" -scheme "$scheme" \
        -destination "id=$udid" -derivedDataPath "$derived_data" \
        -allowProvisioningUpdates build >"$build_log" 2>&1; then
        rm -f "$build_log"
        bold "Build succeeded."
        return
    fi

    grep -E -i 'error:|warning:|\*\* BUILD FAILED \*\*|timed out waiting for all destinations|may need to be unlocked' "$build_log" \
        || tail -n 60 "$build_log"
    rm -f "$build_log"
    return 1
}

ensure_watch_developer_connection() {
    local watch_id="$1"
    local connection_log
    connection_log=$(mktemp)

    # `list devices` can say "available (paired)" even while the Watch has
    # rejected the Mac's separate developer connection. Ask a real Watch
    # service before spending a minute building an app that cannot install.
    if xcrun devicectl device info apps --device "$watch_id" >"$connection_log" 2>&1; then
        rm -f "$connection_log"
        return
    fi

    rm -f "$connection_log"
    die "Direct Watch install is unavailable: the Watch rejected this Mac's developer connection.
Wake and unlock the Watch, confirm Developer Mode is on (Settings → Privacy & Security),
then restart it if you just enabled Developer Mode. Keep it near the unlocked iPhone and Mac.
In Xcode → Window → Devices and Simulators, wait for the Watch to move to Connected.
Until then, use ./scripts/run.sh (the iPhone bridge) and install WristMemo from Watch → Available Apps."
}

install_on_phone() {
    local phone_id="$1"
    local phone_udid="$2"
    local phone_name="$3"

    build_for "$PHONE_SCHEME" "$phone_udid" "$phone_name" "$PHONE_DD" \
        || die "iPhone build failed; nothing was installed."

    local app="$PHONE_DD/Build/Products/Debug-iphoneos/WristMemo.app"
    [[ -d "$app" ]] || die "Build produced no iPhone app at $app"
    [[ -d "$app/Watch/WristMemo Watch App.app" ]] \
        || die "The iPhone build did not embed the Watch app; refusing to install."

    bold "Installing companion on ${phone_name}…"
    xcrun devicectl device install app --device "$phone_id" "$app"

    bold "Launching companion…"
    if ! xcrun devicectl device process launch --device "$phone_id" "$PHONE_BUNDLE_ID"; then
        warn "The companion installed, but iOS would not foreground it."
        printf '%s\n' \
            "Unlock the iPhone, then tap WristMemo once. That completes the Watch-app handoff." \
            "No rebuild or reinstall is needed."
        return
    fi

    bold "The iPhone is delivering the new Watch app now."
    printf '%s\n' \
        "Keep the Watch nearby and unlocked. If it does not update automatically," \
        "open the iPhone Watch app → Available Apps → WristMemo → Install."
}

install_on_watch() {
    local watch_id="$1"
    local watch_udid="$2"
    local watch_model="$3"
    local watch_name="$4"
    local auto_record="$5"

    bold "Watch: $watch_name ($watch_model)"
    case "$watch_model" in
        Watch7,5|Watch6,18|Watch7,17) ;;
        *) warn "No Action button on this model — use the complication or Control Center." ;;
    esac

    if pgrep -qf "io.tailscale.ipn.macsys.network-extension"; then
        die "Tailscale is running. Quit it before --watch, then retry (it blocks the Watch tunnel)."
    fi

    ensure_watch_developer_connection "$watch_id"

    build_for "$WATCH_SCHEME" "$watch_udid" "$watch_name" "$WATCH_DD" \
        || die "Watch build failed; nothing was installed. Use ./scripts/run.sh for the iPhone bridge."

    local app="$WATCH_DD/Build/Products/Debug-watchos/$WATCH_SCHEME.app"
    [[ -d "$app" ]] || die "Build produced no Watch app at $app"

    bold "Installing to ${watch_name}…"
    xcrun devicectl device install app --device "$watch_id" "$app"

    launch_args=()
    [[ "$auto_record" == "yes" ]] && launch_args=(-WristMemoAutoRecord YES)
    bold "Launching…"
    if ! xcrun devicectl device process launch --device "$watch_id" \
        "$WATCH_BUNDLE_ID" "${launch_args[@]}"; then
        warn "The Watch app installed, but watchOS would not foreground it."
        printf '%s\n' \
            "Unlock the Watch, then open WristMemo once. No rebuild or reinstall is needed."
    fi
}

if [[ "$mode" == "phone" ]]; then
    IFS=$'\t' read -r phone_id phone_udid phone_model phone_name <<<"$(read_device iPhone)"
    [[ -n "${phone_id:-}" && -n "${phone_udid:-}" ]] \
        || die "No iPhone found. Plug it in with USB, unlock it, tap Trust, then rerun."
    install_on_phone "$phone_id" "$phone_udid" "$phone_name"
    exit 0
fi

IFS=$'\t' read -r watch_id watch_udid watch_model watch_name <<<"$(read_device Watch)"
[[ -n "${watch_id:-}" && -n "${watch_udid:-}" ]] \
    || die "No Apple Watch found. Pair it in Xcode › Window › Devices and Simulators."

if [[ "$mode" == "record" ]]; then
    install_on_watch "$watch_id" "$watch_udid" "$watch_model" "$watch_name" yes
else
    install_on_watch "$watch_id" "$watch_udid" "$watch_model" "$watch_name" no
fi
