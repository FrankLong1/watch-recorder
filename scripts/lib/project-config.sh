#!/bin/bash
# Shared, non-secret project identifiers for local scripts.
#
# Public clones use the neutral defaults below. This machine's ignored
# Signing.local.xcconfig can override the bundle prefix without changing any
# tracked script.

_wristmemo_local_signing="src/swift_app/Config/Signing.local.xcconfig"

_wristmemo_xcconfig_value() {
    local key="$1"
    [[ -f "$_wristmemo_local_signing" ]] || return 0
    sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p" \
        "$_wristmemo_local_signing" | tail -1
}

WRISTMEMO_BUNDLE_PREFIX="${WRISTMEMO_BUNDLE_PREFIX:-$(_wristmemo_xcconfig_value WRISTMEMO_BUNDLE_PREFIX)}"
WRISTMEMO_BUNDLE_PREFIX="${WRISTMEMO_BUNDLE_PREFIX:-com.example.wristmemo}"
WRISTMEMO_PHONE_BUNDLE_ID="${WRISTMEMO_PHONE_BUNDLE_ID:-$WRISTMEMO_BUNDLE_PREFIX}"
WRISTMEMO_WATCH_BUNDLE_ID="${WRISTMEMO_WATCH_BUNDLE_ID:-$WRISTMEMO_BUNDLE_PREFIX.watchkitapp}"
WRISTMEMO_LOGGING_SUBSYSTEM="${WRISTMEMO_LOGGING_SUBSYSTEM:-$WRISTMEMO_BUNDLE_PREFIX}"

unset _wristmemo_local_signing
unset -f _wristmemo_xcconfig_value
