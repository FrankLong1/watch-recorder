#!/bin/bash
# Exercise the complete release state machine against local Git and fake Apple/Xcode services.
set -euo pipefail

SOURCE_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
REAL_GIT=$(command -v git)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/wristmemo-release-integration.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT

fail() {
    printf 'release-testflight integration test failed: %s\n' "$1" >&2
    exit 1
}

make_fake_commands() {
    local fake_bin="$1"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/xcodebuild" <<'FAKE_XCODEBUILD'
#!/bin/bash
set -euo pipefail
archive_path=""
export_path=""
mode="archive"
while (($#)); do
    case "$1" in
        -archivePath) archive_path="$2"; shift 2 ;;
        -exportPath) export_path="$2"; shift 2 ;;
        -exportArchive) mode="export"; shift ;;
        *) shift ;;
    esac
done

if [[ "$mode" == "archive" ]]; then
    for relative in \
        'Products/Applications/WristMemo.app/Info.plist' \
        'Products/Applications/WristMemo.app/Watch/WristMemo Watch App.app/Info.plist' \
        'Products/Applications/WristMemo.app/Watch/WristMemo Watch App.app/PlugIns/WristMemoControls.appex/Info.plist'; do
        plist="$archive_path/$relative"
        mkdir -p "$(dirname "$plist")"
        plutil -create xml1 "$plist"
        plutil -insert CFBundleShortVersionString -string "$MOCK_VERSION" "$plist"
        plutil -insert CFBundleVersion -string "$MOCK_BUILD" "$plist"
    done
else
    mkdir -p "$export_path"
    touch "$MOCK_UPLOADED_MARKER"
fi
FAKE_XCODEBUILD

    cat >"$fake_bin/curl" <<'FAKE_CURL'
#!/bin/bash
set -euo pipefail
method="GET"
output=""
url=""
while (($#)); do
    case "$1" in
        --request) method="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        --header|--write-out|--data-binary) shift 2 ;;
        --silent|--show-error) shift ;;
        *) url="$1"; shift ;;
    esac
done

status=200
body='{}'
case "$method $url" in
    "GET "*'/v1/apps?'*)
        body='{"data":[{"type":"apps","id":"app-id"}]}'
        ;;
    "GET "*'/v1/betaGroups?'*)
        body='{"data":[{"type":"betaGroups","id":"group-id","attributes":{"name":"Internal","isInternalGroup":true}}]}'
        ;;
    "GET "*'/v1/builds?'*'filter%5BbetaGroups%5D='*)
        if [[ -e "$MOCK_GROUPED_MARKER" ]]; then
            body='{"data":[{"type":"builds","id":"build-id","attributes":{"version":"13","processingState":"VALID"}}]}'
        else
            body='{"data":[]}'
        fi
        ;;
    "GET "*'/v1/builds?'*)
        if [[ -e "$MOCK_UPLOADED_MARKER" ]]; then
            body='{"data":[{"type":"builds","id":"build-id","attributes":{"version":"13","processingState":"VALID"}}]}'
        else
            body='{"data":[]}'
        fi
        ;;
    "GET "*'/betaBuildLocalizations?'*)
        body='{"data":[]}'
        ;;
    "POST "*'/v1/betaBuildLocalizations')
        status=201
        body='{"data":{"type":"betaBuildLocalizations","id":"localization-id"}}'
        ;;
    "POST "*'/relationships/builds')
        touch "$MOCK_GROUPED_MARKER"
        status=204
        body=''
        ;;
    "GET "*'/buildBetaDetail?'*)
        body='{"data":{"type":"buildBetaDetails","id":"detail-id","attributes":{"internalBuildState":"IN_BETA_TESTING"}}}'
        ;;
    *)
        printf 'Unexpected fake App Store Connect request: %s %s\n' "$method" "$url" >&2
        exit 8
        ;;
esac
printf '%s' "$body" >"$output"
printf '%s' "$status"
FAKE_CURL
    chmod +x "$fake_bin/xcodebuild" "$fake_bin/curl"
}

make_fixture() {
    local name="$1"
    local fixture="$temporary_root/$name"
    local remote="$temporary_root/$name-remote.git"
    local key_path="$temporary_root/$name-AuthKey_TESTKEY.p8"

    mkdir -p \
        "$fixture/scripts/lib" \
        "$fixture/scripts/tests" \
        "$fixture/src/swift_app/WristMemo.xcodeproj" \
        "$fixture/src/swift_app/Config" \
        "$fixture/docs/releases"
    cp "$SOURCE_ROOT/scripts/release-testflight.sh" "$fixture/scripts/release-testflight.sh"
    cp "$SOURCE_ROOT/scripts/lib/app-store-connect.sh" "$fixture/scripts/lib/app-store-connect.sh"
    cp "$SOURCE_ROOT/scripts/lib/project-config.sh" "$fixture/scripts/lib/project-config.sh"
    cp "$SOURCE_ROOT/src/swift_app/Config/TestFlightExportOptions.plist" "$fixture/src/swift_app/Config/TestFlightExportOptions.plist"
    cp "$SOURCE_ROOT/.gitignore" "$fixture/.gitignore"
    printf '#!/bin/bash\nexit 0\n' >"$fixture/scripts/check-public.sh"
    printf '#!/bin/bash\nexit 0\n' >"$fixture/scripts/sim.sh"
    chmod +x "$fixture/scripts/"*.sh
    printf '%s\n' \
        'MARKETING_VERSION = 1.5;' \
        'CURRENT_PROJECT_VERSION = 12;' \
        >"$fixture/src/swift_app/WristMemo.xcodeproj/project.pbxproj"

    "$REAL_GIT" init -q "$fixture"
    "$REAL_GIT" -C "$fixture" config user.name "Release Integration Test"
    "$REAL_GIT" -C "$fixture" config user.email "release-integration@example.invalid"
    "$REAL_GIT" -C "$fixture" add .
    "$REAL_GIT" -C "$fixture" commit -qm fixture
    "$REAL_GIT" init --bare -q "$remote"
    "$REAL_GIT" -C "$fixture" remote add origin "$remote"
    "$REAL_GIT" -C "$fixture" push -q -u origin HEAD

    cat >"$fixture/docs/releases/1.6.md" <<'NOTES'
# WristMemo 1.6

TestFlight build: 13

Released: 2000-01-01

## What's new

- Automated integration release.

## What to test

1. Install and exercise the build.
NOTES

    openssl ecparam -name prime256v1 -genkey -noout -out "$key_path" 2>/dev/null
    cat >"$fixture/src/swift_app/Config/TestFlight.local.env" <<CONFIG
ASC_KEY_ID="TESTKEY"
ASC_ISSUER_ID="00000000-0000-0000-0000-000000000000"
ASC_KEY_PATH="$key_path"
ASC_POLL_INTERVAL_SECONDS="1"
ASC_PROCESSING_TIMEOUT_SECONDS="5"
CONFIG

    printf '%s\t%s\n' "$fixture" "$remote"
}

run_release() {
    local fixture="$1"
    local fake_bin="$2"
    local uploaded_marker="$3"
    local grouped_marker="$4"
    shift 4
    PATH="$fake_bin:$PATH" \
    MOCK_VERSION=1.6 \
    MOCK_BUILD=13 \
    MOCK_UPLOADED_MARKER="$uploaded_marker" \
    MOCK_GROUPED_MARKER="$grouped_marker" \
    WRISTMEMO_RELEASE_ROOT="$fixture" \
        "$fixture/scripts/release-testflight.sh" "$@" 1.6 13
}

IFS=$'\t' read -r happy_fixture happy_remote < <(make_fixture happy)
happy_fake_bin="$temporary_root/happy-fake-bin"
make_fake_commands "$happy_fake_bin"
run_release \
    "$happy_fixture" \
    "$happy_fake_bin" \
    "$temporary_root/happy-uploaded" \
    "$temporary_root/happy-grouped" \
    >/dev/null
[[ "$("$REAL_GIT" -C "$happy_fixture" log -1 --format=%s)" == 'release: v1.6' ]] \
    || fail "happy path did not create the release commit"
[[ "$("$REAL_GIT" -C "$happy_fixture" rev-list -n 1 v1.6)" == "$("$REAL_GIT" -C "$happy_fixture" rev-parse HEAD)" ]] \
    || fail "happy path tag does not point to HEAD"
[[ "$(jq -r '.phase' "$happy_fixture/build/releases/1.6-13.json")" == 'pushed' ]] \
    || fail "happy path did not reach pushed state"

IFS=$'\t' read -r resume_fixture resume_remote < <(make_fixture resume)
resume_fake_bin="$temporary_root/resume-fake-bin"
make_fake_commands "$resume_fake_bin"
fake_git_bin="$temporary_root/fake-git-bin"
mkdir -p "$fake_git_bin"
cat >"$fake_git_bin/git" <<'FAKE_GIT'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "commit" && ! -e "$MOCK_COMMIT_INTERRUPTED_MARKER" ]]; then
    "$REAL_GIT" "$@"
    touch "$MOCK_COMMIT_INTERRUPTED_MARKER"
    exit 88
fi
exec "$REAL_GIT" "$@"
FAKE_GIT
chmod +x "$fake_git_bin/git"

set +e
PATH="$fake_git_bin:$resume_fake_bin:$PATH" \
REAL_GIT="$REAL_GIT" \
MOCK_COMMIT_INTERRUPTED_MARKER="$temporary_root/resume-commit-interrupted" \
MOCK_VERSION=1.6 \
MOCK_BUILD=13 \
MOCK_UPLOADED_MARKER="$temporary_root/resume-uploaded" \
MOCK_GROUPED_MARKER="$temporary_root/resume-grouped" \
WRISTMEMO_RELEASE_ROOT="$resume_fixture" \
    "$resume_fixture/scripts/release-testflight.sh" 1.6 13 >/dev/null 2>&1
interrupted_status=$?
set -e
[[ "$interrupted_status" == "88" ]] || fail "commit interruption did not stop with the fake Git status"
[[ "$(jq -r '.phase' "$resume_fixture/build/releases/1.6-13.json")" == 'committing' ]] \
    || fail "interrupted commit was not durably marked committing"
[[ "$("$REAL_GIT" -C "$resume_fixture" log -1 --format=%s)" == 'release: v1.6' ]] \
    || fail "fake interruption did not occur after the real commit"

run_release \
    "$resume_fixture" \
    "$resume_fake_bin" \
    "$temporary_root/resume-uploaded" \
    "$temporary_root/resume-grouped" \
    --resume \
    >/dev/null
[[ "$(jq -r '.phase' "$resume_fixture/build/releases/1.6-13.json")" == 'pushed' ]] \
    || fail "--resume did not recover the interrupted commit"
[[ "$("$REAL_GIT" -C "$resume_fixture" rev-list -n 1 v1.6)" == "$("$REAL_GIT" -C "$resume_fixture" rev-parse HEAD)" ]] \
    || fail "resumed tag does not point to the release commit"

printf 'release-testflight integration tests passed.\n'
