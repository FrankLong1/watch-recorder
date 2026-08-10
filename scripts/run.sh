#!/bin/bash
# Build and install WristMemo on physical hardware.
#
#   ./scripts/run.sh              build for the paired iPhone (the reliable default)
#   ./scripts/run.sh --phone      same as above
#   ./scripts/run.sh --watch      build and install directly on the Watch
#   ./scripts/run.sh --record     direct Watch build, then launch into recording
#   ./scripts/run.sh --doctor     explain what is connected and what to do next
#   ./scripts/run.sh --devices    show devices Xcode can currently use
#   ./scripts/run.sh --logs       explain the supported watchOS logging path
#
# The phone path embeds the Watch app in WristMemo.app, then lets the paired
# iPhone deliver it. It avoids the fragile Mac → Watch Wi-Fi tunnel entirely.
# Use --watch only when that tunnel is healthy and you want the faster loop.

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/project-config.sh

PROJECT="src/swift_app/WristMemo.xcodeproj"
PHONE_SCHEME="WristMemo"
WATCH_SCHEME="WristMemo Watch App"
PHONE_BUNDLE_ID="$WRISTMEMO_PHONE_BUNDLE_ID"
WATCH_BUNDLE_ID="$WRISTMEMO_WATCH_BUNDLE_ID"
PHONE_DD="build/phone-dd"
WATCH_DD="build/watch-dd"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }
pass() { printf '\033[32m✓ %s\033[0m\n' "$1"; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: ./scripts/run.sh [--phone | --watch | --record | --doctor | --devices | --logs]

  --phone    Normal path (default): build and install through the connected iPhone.
  --watch    Build and install directly on the Watch. Requires the Mac → Watch tunnel.
  --record   Same as --watch, then launch straight into recording.
  --doctor   Show the connected phone, Watch visibility, and installed app version.
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
        --doctor)  mode="doctor" ;;
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
    local connection_requirement="${2:-any}"
    python3 - "$device_json" "$prefix" "$connection_requirement" <<'PY'
import json
import sys

path, prefix, connection_requirement = sys.argv[1:]
try:
    devices = json.load(open(path))["result"]["devices"]
except Exception:
    sys.exit(0)

matches = []
for device in devices:
    hardware = device.get("hardwareProperties", {})
    product_type = str(hardware.get("productType", ""))
    if not product_type.startswith(prefix):
        continue
    tunnel_state = str(device.get("connectionProperties", {}).get("tunnelState", ""))
    if connection_requirement == "connected" and tunnel_state != "connected":
        continue
    matches.append(device)

if len(matches) > 1:
    names = ", ".join(
        str(d.get("deviceProperties", {}).get("name", "unnamed device"))
        for d in matches
    )
    print(f"AMBIGUOUS: {names}")
    sys.exit(0)
if not matches:
    sys.exit(0)

device = matches[0]
hardware = device.get("hardwareProperties", {})
properties = device.get("deviceProperties", {})
print("\t".join((
    str(device.get("identifier", "")),
    str(hardware.get("udid", "")),
    str(hardware.get("productType", "")),
    str(properties.get("name", hardware.get("productType", ""))),
    str(properties.get("developerModeStatus", "unknown")),
)))
PY
}

doctor() {
    local phone_row phone_id phone_udid phone_model phone_name phone_developer_mode
    local phone_app watch_row watch_id watch_udid watch_model watch_name watch_developer_mode

    bold "WristMemo deployment check"

    phone_row="$(read_device iPhone connected)"
    [[ "$phone_row" != AMBIGUOUS:* ]] \
        || die "More than one connected iPhone was found: ${phone_row#AMBIGUOUS: }. Disconnect the one you are not using."
    if [[ -z "$phone_row" ]]; then
        warn "✗ iPhone: not connected"
        printf '%s\n' "  Plug it in with USB, unlock it, tap Trust, then run this check again."
        return 1
    fi

    IFS=$'\t' read -r phone_id phone_udid phone_model phone_name phone_developer_mode <<<"$phone_row"
    pass "iPhone: ${phone_name} (${phone_model})"
    if [[ "$phone_developer_mode" == "enabled" ]]; then
        pass "iPhone Developer Mode: enabled"
    else
        warn "✗ iPhone Developer Mode: ${phone_developer_mode}"
    fi

    phone_app=$(xcrun devicectl device info apps --device "$phone_id" \
        --bundle-id "$PHONE_BUNDLE_ID" 2>/dev/null \
        | awk -v bundle="$PHONE_BUNDLE_ID" '$2 == bundle { print "version " $3 ", build " $4 }') \
        || phone_app=""
    if [[ -n "$phone_app" ]]; then
        pass "iPhone app installed: ${phone_app}"
    else
        warn "• iPhone app: not installed yet"
    fi

    watch_row="$(read_device Watch any)"
    if [[ "$watch_row" == AMBIGUOUS:* ]]; then
        warn "• Apple Watch: more than one Xcode record (${watch_row#AMBIGUOUS: })"
        printf '%s\n' "  Remove stale pairings in Xcode → Window → Devices and Simulators."
    elif [[ -z "$watch_row" ]]; then
        warn "• Apple Watch: not visible to Xcode"
        printf '%s\n' \
            "  This does not block the normal iPhone install." \
            "  It only blocks ./scripts/run.sh --watch, the optional faster path."
    else
        IFS=$'\t' read -r watch_id watch_udid watch_model watch_name watch_developer_mode <<<"$watch_row"
        pass "Apple Watch visible: ${watch_name} (${watch_model})"
        if xcrun devicectl device info apps --device "$watch_id" >/dev/null 2>&1; then
            pass "Direct Watch developer connection: ready"
        else
            warn "• Direct Watch developer connection: paired but not ready"
        fi
    fi

    printf '\n%s\n' "Normal deploy: ./scripts/run.sh"
}

build_for() {
    local scheme="$1"
    local udid="$2"
    local name="$3"
    local derived_data="$4"
    local configuration="$5"
    local build_log="${derived_data}.log"
    mkdir -p "$(dirname "$build_log")"

    bold "Building ${configuration} ${scheme} for ${name}…"
    if xcodebuild -project "$PROJECT" -scheme "$scheme" \
        -configuration "$configuration" -destination "id=$udid" -derivedDataPath "$derived_data" \
        -allowProvisioningUpdates build >"$build_log" 2>&1; then
        bold "Build succeeded."
        return
    fi

    grep -E -i 'error:|warning:|\*\* BUILD FAILED \*\*|timed out waiting for all destinations|may need to be unlocked' "$build_log" \
        || tail -n 60 "$build_log"
    warn "Full build log: $build_log"
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

    # The phone bridge is the actual install package. Release omits the Swift
    # debug dylibs, so it gives watchOS the smallest possible companion to
    # stage and install.
    local configuration="Release"
    build_for "$PHONE_SCHEME" "$phone_udid" "$phone_name" "$PHONE_DD" "$configuration" \
        || die "iPhone build failed; nothing was installed."

    local app="$PHONE_DD/Build/Products/${configuration}-iphoneos/WristMemo.app"
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

    bold "iPhone install complete."
    printf '%s\n' \
        "iOS now handles the Watch hand-off; this command cannot claim it finished." \
        "If WristMemo is not on the Watch, open the iPhone Watch app → Available Apps → WristMemo → Install." \
        "Then launch WristMemo once on the Watch and allow microphone access."
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

    build_for "$WATCH_SCHEME" "$watch_udid" "$watch_name" "$WATCH_DD" "Debug" \
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

if [[ "$mode" == "doctor" ]]; then
    doctor
    exit
fi

if [[ "$mode" == "phone" ]]; then
    phone_row="$(read_device iPhone connected)"
    [[ "$phone_row" != AMBIGUOUS:* ]] \
        || die "More than one connected iPhone was found: ${phone_row#AMBIGUOUS: }. Disconnect the one you are not using."
    IFS=$'\t' read -r phone_id phone_udid phone_model phone_name phone_developer_mode <<<"$phone_row"
    [[ -n "${phone_id:-}" && -n "${phone_udid:-}" ]] \
        || die "No iPhone found. Plug it in with USB, unlock it, tap Trust, then rerun."
    install_on_phone "$phone_id" "$phone_udid" "$phone_name"
    exit 0
fi

watch_row="$(read_device Watch any)"
[[ "$watch_row" != AMBIGUOUS:* ]] \
    || die "More than one Apple Watch record was found: ${watch_row#AMBIGUOUS: }. Remove stale pairings in Xcode first."
IFS=$'\t' read -r watch_id watch_udid watch_model watch_name watch_developer_mode <<<"$watch_row"
[[ -n "${watch_id:-}" && -n "${watch_udid:-}" ]] \
    || die "No Apple Watch found. Pair it in Xcode › Window › Devices and Simulators."

if [[ "$mode" == "record" ]]; then
    install_on_watch "$watch_id" "$watch_udid" "$watch_model" "$watch_name" yes
else
    install_on_watch "$watch_id" "$watch_udid" "$watch_model" "$watch_name" no
fi
