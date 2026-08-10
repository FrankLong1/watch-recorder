#!/bin/bash
# Build, upload, configure, verify, commit, tag, and push a WristMemo TestFlight release.
set -euo pipefail

ROOT="${WRISTMEMO_RELEASE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

source scripts/lib/project-config.sh
source scripts/lib/app-store-connect.sh

PROJECT="src/swift_app/WristMemo.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
SCHEME="WristMemo"
EXPORT_OPTIONS="src/swift_app/Config/TestFlightExportOptions.plist"
CONFIG_FILE="${WRISTMEMO_TESTFLIGHT_CONFIG:-src/swift_app/Config/TestFlight.local.env}"
REMOTE="${WRISTMEMO_RELEASE_REMOTE:-origin}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
pass() { printf '\033[32m✓ %s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  ./scripts/release-testflight.sh --prepare VERSION BUILD
  ./scripts/release-testflight.sh [--dry-run] VERSION BUILD
  ./scripts/release-testflight.sh --resume VERSION BUILD
  ./scripts/release-testflight.sh --retry-upload VERSION BUILD

Examples:
  ./scripts/release-testflight.sh --prepare 1.6 13
  # Edit docs/releases/1.6.md, then:
  ./scripts/release-testflight.sh 1.6 13

Actions:
  --prepare       Create the required release-note template and stop.
  --dry-run       Validate the local release inputs and print the plan. No mutation or network.
  --resume        Continue a release from its durable state in build/releases/.
  --retry-upload  Retry upload only after an interrupted upload remained invisible to Apple.

The normal release path deliberately has no --skip-tests, --skip-upload, or
--skip-push switches. A TestFlight build is complete only after Apple reports
it in the Internal group as IN_BETA_TESTING and the exact release commit and tag
have been pushed.
EOF
}

action="release"
positionals=()
while (($#)); do
    case "$1" in
        --prepare)      action="prepare" ;;
        --dry-run)      action="dry-run" ;;
        --resume)       action="resume" ;;
        --retry-upload) action="retry-upload" ;;
        --help|-h)      usage; exit 0 ;;
        --*)            die "Unknown option: $1 (try --help)" ;;
        *)              positionals+=("$1") ;;
    esac
    shift
done

[[ ${#positionals[@]} -eq 2 ]] || { usage >&2; exit 2; }
VERSION="${positionals[0]}"
BUILD="${positionals[1]}"
NOTES_FILE="docs/releases/${VERSION}.md"
RELEASE_BRANCH="codex/release-${VERSION}"
ARCHIVE_PATH="build/releases/WristMemo-${VERSION}-${BUILD}.xcarchive"
EXPORT_PATH="build/releases/export-${VERSION}-${BUILD}"
STATE_FILE="build/releases/${VERSION}-${BUILD}.json"
ARCHIVE_LOG="build/releases/WristMemo-${VERSION}-${BUILD}-archive.log"
UPLOAD_LOG="build/releases/WristMemo-${VERSION}-${BUILD}-upload.log"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]] \
    || die "VERSION must be a major.minor value such as 1.6."
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] \
    || die "BUILD must be a positive integer."

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

project_value() {
    local key="$1"
    local values count
    values=$(sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*([^;]+);/\1/p" "$PBXPROJ" \
        | sort -u)
    count=$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')
    [[ "$count" == "1" ]] \
        || die "$PBXPROJ must contain exactly one unique $key value; found: ${values:-none}"
    printf '%s\n' "$values"
}

validate_next_version() {
    local current_version="$1"
    local current_build="$2"
    local current_major current_minor requested_major requested_minor

    IFS=. read -r current_major current_minor <<<"$current_version"
    IFS=. read -r requested_major requested_minor <<<"$VERSION"
    [[ "$requested_major" == "$current_major" && "$requested_minor" -eq $((current_minor + 1)) ]] \
        || die "TestFlight marketing versions advance by one minor: expected ${current_major}.$((current_minor + 1)), got $VERSION."
    [[ "$BUILD" -eq $((current_build + 1)) ]] \
        || die "TestFlight build numbers increment by one: expected $((current_build + 1)), got $BUILD."
}

validate_note_shape() {
    [[ -f "$NOTES_FILE" ]] || die "Missing $NOTES_FILE. Run --prepare first."
    grep -Fxq "# WristMemo $VERSION" "$NOTES_FILE" \
        || die "$NOTES_FILE must start with '# WristMemo $VERSION'."
    grep -Fxq "TestFlight build: $BUILD" "$NOTES_FILE" \
        || die "$NOTES_FILE must contain 'TestFlight build: $BUILD'."
    grep -Fxq "## What's new" "$NOTES_FILE" \
        || die "$NOTES_FILE is missing the What's new section."
    grep -Fxq "## What to test" "$NOTES_FILE" \
        || die "$NOTES_FILE is missing the What to test section."
    if rg -n 'TODO|TBD|FIXME' "$NOTES_FILE" >/dev/null; then
        die "$NOTES_FILE still contains a TODO/TBD/FIXME placeholder."
    fi
}

extract_what_to_test() {
    awk '
        /^## What to test[[:space:]]*$/ { capture = 1; next }
        capture && /^## / { exit }
        capture { print }
    ' "$NOTES_FILE" | ruby -e 'value = STDIN.read.strip; abort "empty" if value.empty?; abort "too long" if value.length > 4000; print value'
}

update_release_date() {
    ruby - "$NOTES_FILE" "$(date +%F)" <<'RUBY'
path, date = ARGV
text = File.binread(path)
count = text.scan(/^Released: .*$/).length
abort "Expected exactly one Released line in #{path}" unless count == 1
File.binwrite(path, text.sub(/^Released: .*$/, "Released: #{date}"))
RUBY
}

dirty_paths() {
    {
        git diff --name-only
        git diff --cached --name-only
        git ls-files --others --exclude-standard
    } | sed '/^$/d' | sort -u
}

validate_dirty_paths() {
    local allowed_csv="$1"
    local path
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        case ",$allowed_csv," in
            *,"$path",*) ;;
            *) die "Unrelated worktree change blocks release: $path" ;;
        esac
    done < <(dirty_paths)
}

release_fingerprint() {
    shasum -a 256 "$PBXPROJ" "$NOTES_FILE" | shasum -a 256 | awk '{print $1}'
}

set_project_versions() {
    local old_version="$1"
    local old_build="$2"
    ruby - "$PBXPROJ" "$old_version" "$VERSION" "$old_build" "$BUILD" <<'RUBY'
path, old_version, new_version, old_build, new_build = ARGV
text = File.binread(path)
version_pattern = /MARKETING_VERSION = #{Regexp.escape(old_version)};/
build_pattern = /CURRENT_PROJECT_VERSION = #{Regexp.escape(old_build)};/
version_count = text.scan(version_pattern).length
build_count = text.scan(build_pattern).length
abort "No MARKETING_VERSION entries matched #{old_version}" if version_count.zero?
abort "No CURRENT_PROJECT_VERSION entries matched #{old_build}" if build_count.zero?
text.gsub!(version_pattern, "MARKETING_VERSION = #{new_version};")
text.gsub!(build_pattern, "CURRENT_PROJECT_VERSION = #{new_build};")
File.binwrite(path, text)
RUBY
}

phase_number() {
    case "$1" in
        initialized)  echo 0 ;;
        versioned)    echo 10 ;;
        tested)       echo 20 ;;
        archived)     echo 30 ;;
        uploading)    echo 35 ;;
        uploaded)     echo 40 ;;
        processed)    echo 50 ;;
        localized)    echo 60 ;;
        grouped)      echo 70 ;;
        verified)     echo 80 ;;
        committing)   echo 85 ;;
        committed)    echo 90 ;;
        tagging)      echo 95 ;;
        tagged)       echo 100 ;;
        pushing)      echo 105 ;;
        pushed)       echo 110 ;;
        *) die "Unknown release state phase: $1" ;;
    esac
}

state_phase() {
    jq -er '.phase' "$STATE_FILE"
}

phase_at_least() {
    local current target
    current=$(phase_number "$(state_phase)")
    target=$(phase_number "$1")
    (( current >= target ))
}

state_create() {
    local base_commit="$1"
    mkdir -p "$(dirname "$STATE_FILE")"
    jq -n \
        --arg version "$VERSION" \
        --arg build "$BUILD" \
        --arg branch "$RELEASE_BRANCH" \
        --arg baseCommit "$base_commit" \
        '{version: $version, build: $build, branch: $branch, baseCommit: $baseCommit, phase: "initialized"}' \
        >"$STATE_FILE"
}

state_set() {
    local phase="$1"
    local temporary="${STATE_FILE}.tmp"
    jq --arg phase "$phase" '.phase = $phase' "$STATE_FILE" >"$temporary"
    mv "$temporary" "$STATE_FILE"
}

state_set_fingerprint() {
    local fingerprint="$1"
    local temporary="${STATE_FILE}.tmp"
    jq --arg fingerprint "$fingerprint" '.sourceFingerprint = $fingerprint' "$STATE_FILE" >"$temporary"
    mv "$temporary" "$STATE_FILE"
}

state_set_release_commit() {
    local release_commit="$1"
    local temporary="${STATE_FILE}.tmp"
    jq --arg releaseCommit "$release_commit" '.releaseCommit = $releaseCommit' "$STATE_FILE" >"$temporary"
    mv "$temporary" "$STATE_FILE"
}

validate_state() {
    [[ -f "$STATE_FILE" ]] || die "No resumable state at $STATE_FILE."
    jq -e \
        --arg version "$VERSION" \
        --arg build "$BUILD" \
        --arg branch "$RELEASE_BRANCH" \
        '.version == $version and .build == $build and .branch == $branch and (.baseCommit | type == "string")' \
        "$STATE_FILE" >/dev/null \
        || die "$STATE_FILE does not match this release."
    phase_number "$(state_phase)" >/dev/null
}

load_private_config() {
    [[ -f "$CONFIG_FILE" ]] \
        || die "Missing $CONFIG_FILE. Copy TestFlight.local.env.example and fill it in."
    set -a
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    set +a
    ASC_BETA_GROUP="${ASC_BETA_GROUP:-Internal}"
    ASC_LOCALE="${ASC_LOCALE:-en-US}"
    ASC_POLL_INTERVAL_SECONDS="${ASC_POLL_INTERVAL_SECONDS:-30}"
    ASC_PROCESSING_TIMEOUT_SECONDS="${ASC_PROCESSING_TIMEOUT_SECONDS:-3600}"
    [[ "$ASC_POLL_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] \
        || die "ASC_POLL_INTERVAL_SECONDS must be a positive integer."
    [[ "$ASC_PROCESSING_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
        || die "ASC_PROCESSING_TIMEOUT_SECONDS must be a positive integer."
    asc_require_tools || exit 1
    asc_validate_config || exit 1
    case "$ASC_KEY_PATH" in
        "$ROOT"/*) die "ASC_KEY_PATH must live outside this repository." ;;
    esac
}

app_store_app_id() {
    local bundle_encoded response count
    bundle_encoded=$(asc_urlencode "$WRISTMEMO_PHONE_BUNDLE_ID")
    response=$(asc_request GET "/v1/apps?filter%5BbundleId%5D=${bundle_encoded}&limit=2")
    count=$(jq '.data | length' <<<"$response")
    [[ "$count" == "1" ]] \
        || die "Expected one App Store Connect app for $WRISTMEMO_PHONE_BUNDLE_ID; found $count."
    jq -r '.data[0].id' <<<"$response"
}

internal_group_id() {
    local app_id="$1"
    local app_encoded name_encoded response count internal
    app_encoded=$(asc_urlencode "$app_id")
    name_encoded=$(asc_urlencode "$ASC_BETA_GROUP")
    response=$(asc_request GET "/v1/betaGroups?filter%5Bapp%5D=${app_encoded}&filter%5Bname%5D=${name_encoded}&limit=2")
    count=$(jq '.data | length' <<<"$response")
    [[ "$count" == "1" ]] \
        || die "Expected one '$ASC_BETA_GROUP' beta group for this app; found $count."
    internal=$(jq -r '.data[0].attributes.isInternalGroup' <<<"$response")
    [[ "$internal" == "true" ]] \
        || die "The '$ASC_BETA_GROUP' beta group is not an internal group."
    jq -r '.data[0].id' <<<"$response"
}

build_response() {
    local app_id="$1"
    local app_encoded version_encoded build_encoded
    app_encoded=$(asc_urlencode "$app_id")
    version_encoded=$(asc_urlencode "$VERSION")
    build_encoded=$(asc_urlencode "$BUILD")
    asc_request GET "/v1/builds?filter%5Bapp%5D=${app_encoded}&filter%5BpreReleaseVersion.version%5D=${version_encoded}&filter%5Bversion%5D=${build_encoded}&limit=2"
}

wait_for_processed_build() {
    local app_id="$1"
    local deadline response count processing_state build_id
    deadline=$(( $(date +%s) + ASC_PROCESSING_TIMEOUT_SECONDS ))

    while (( $(date +%s) < deadline )); do
        response=$(build_response "$app_id")
        count=$(jq '.data | length' <<<"$response")
        if [[ "$count" == "0" ]]; then
            printf 'Apple has not exposed %s (%s) yet; checking again in %ss…\n' \
                "$VERSION" "$BUILD" "$ASC_POLL_INTERVAL_SECONDS" >&2
        elif [[ "$count" == "1" ]]; then
            processing_state=$(jq -r '.data[0].attributes.processingState' <<<"$response")
            build_id=$(jq -r '.data[0].id' <<<"$response")
            case "$processing_state" in
                VALID) printf '%s\n' "$build_id"; return 0 ;;
                FAILED|INVALID) die "Apple marked build $VERSION ($BUILD) as $processing_state." ;;
                PROCESSING) printf 'Apple is processing %s (%s); checking again in %ss…\n' \
                    "$VERSION" "$BUILD" "$ASC_POLL_INTERVAL_SECONDS" >&2 ;;
                *) die "Unknown Apple processing state: $processing_state" ;;
            esac
        else
            die "Apple returned multiple builds for exact release $VERSION ($BUILD)."
        fi
        sleep "$ASC_POLL_INTERVAL_SECONDS"
    done

    die "Timed out waiting for Apple to process $VERSION ($BUILD). Resume later with --resume."
}

set_what_to_test() {
    local build_id="$1"
    local notes="$2"
    local response count localization_id body
    response=$(asc_request GET "/v1/builds/${build_id}/betaBuildLocalizations?limit=200")
    count=$(jq --arg locale "$ASC_LOCALE" '[.data[] | select(.attributes.locale == $locale)] | length' <<<"$response")
    [[ "$count" -le 1 ]] || die "Build has multiple $ASC_LOCALE beta localizations."

    if [[ "$count" == "1" ]]; then
        localization_id=$(jq -r --arg locale "$ASC_LOCALE" '.data[] | select(.attributes.locale == $locale) | .id' <<<"$response")
        body=$(jq -n \
            --arg id "$localization_id" \
            --arg notes "$notes" \
            '{data: {type: "betaBuildLocalizations", id: $id, attributes: {whatsNew: $notes}}}')
        asc_request PATCH "/v1/betaBuildLocalizations/${localization_id}" "$body" >/dev/null
    else
        body=$(jq -n \
            --arg build "$build_id" \
            --arg locale "$ASC_LOCALE" \
            --arg notes "$notes" \
            '{data: {type: "betaBuildLocalizations", attributes: {locale: $locale, whatsNew: $notes}, relationships: {build: {data: {type: "builds", id: $build}}}}}')
        asc_request POST "/v1/betaBuildLocalizations" "$body" >/dev/null
    fi
}

build_is_in_group() {
    local build_id="$1"
    local group_id="$2"
    local build_encoded group_encoded response
    build_encoded=$(asc_urlencode "$build_id")
    group_encoded=$(asc_urlencode "$group_id")
    response=$(asc_request GET "/v1/builds?filter%5Bid%5D=${build_encoded}&filter%5BbetaGroups%5D=${group_encoded}&limit=2")
    [[ $(jq '.data | length' <<<"$response") == "1" ]]
}

add_build_to_group() {
    local build_id="$1"
    local group_id="$2"
    local body
    if build_is_in_group "$build_id" "$group_id"; then
        return
    fi
    body=$(jq -n --arg build "$build_id" '{data: [{type: "builds", id: $build}]}')
    asc_request POST "/v1/betaGroups/${group_id}/relationships/builds" "$body" >/dev/null
}

wait_for_internal_testing() {
    local build_id="$1"
    local group_id="$2"
    local deadline response internal_state
    deadline=$(( $(date +%s) + ASC_PROCESSING_TIMEOUT_SECONDS ))

    while (( $(date +%s) < deadline )); do
        if ! build_is_in_group "$build_id" "$group_id"; then
            printf 'Waiting for Internal group assignment to become visible…\n' >&2
            sleep "$ASC_POLL_INTERVAL_SECONDS"
            continue
        fi

        response=$(asc_request GET "/v1/builds/${build_id}/buildBetaDetail?fields%5BbuildBetaDetails%5D=internalBuildState")
        internal_state=$(jq -r '.data.attributes.internalBuildState' <<<"$response")
        case "$internal_state" in
            IN_BETA_TESTING) return 0 ;;
            READY_FOR_BETA_TESTING|PROCESSING)
                printf 'Internal TestFlight state is %s; checking again in %ss…\n' \
                    "$internal_state" "$ASC_POLL_INTERVAL_SECONDS" >&2 ;;
            MISSING_EXPORT_COMPLIANCE|IN_EXPORT_COMPLIANCE_REVIEW|PROCESSING_EXCEPTION|EXPIRED)
                die "Build cannot enter internal testing: $internal_state." ;;
            *) die "Unknown internal TestFlight state: $internal_state" ;;
        esac
        sleep "$ASC_POLL_INTERVAL_SECONDS"
    done

    die "Timed out waiting for Internal TestFlight state IN_BETA_TESTING. Resume later with --resume."
}

validate_archive_versions() {
    local plist short_version build_number found=0
    while IFS= read -r plist; do
        short_version=$(plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null || true)
        build_number=$(plutil -extract CFBundleVersion raw -o - "$plist" 2>/dev/null || true)
        [[ -n "$short_version" && -n "$build_number" ]] || continue
        found=$((found + 1))
        [[ "$short_version" == "$VERSION" && "$build_number" == "$BUILD" ]] \
            || die "Archive version mismatch in $plist: $short_version ($build_number)."
    done < <(find "$ARCHIVE_PATH/Products/Applications" -type f -name Info.plist | sort)
    [[ "$found" -ge 3 ]] \
        || die "Archive validation found only $found versioned app/extension Info.plists."
}

run_logged() {
    local label="$1"
    local log="$2"
    shift 2
    bold "$label"
    if "$@" >"$log" 2>&1; then
        pass "$label"
        return
    fi
    tail -n 100 "$log" >&2
    die "$label failed. Full log: $log"
}

remote_ref_exists() {
    local ref="$1"
    local status
    set +e
    git ls-remote --exit-code "$REMOTE" "$ref" >/dev/null 2>&1
    status=$?
    set -e
    case "$status" in
        0) return 0 ;;
        2) return 1 ;;
        *) die "Could not query $REMOTE for $ref." ;;
    esac
}

prepare_notes() {
    local current_version current_build
    current_version=$(project_value MARKETING_VERSION)
    current_build=$(project_value CURRENT_PROJECT_VERSION)
    validate_next_version "$current_version" "$current_build"
    [[ ! -e "$NOTES_FILE" ]] || die "$NOTES_FILE already exists."
    mkdir -p "$(dirname "$NOTES_FILE")"
    printf '# WristMemo %s\n\nTestFlight build: %s\n\nReleased: %s\n\n## What\047s new\n\n- TODO\n\n## What to test\n\n1. TODO\n' \
        "$VERSION" "$BUILD" "$(date +%F)" >"$NOTES_FILE"
    pass "Created $NOTES_FILE"
    printf 'Edit every TODO, review the notes, then run:\n  ./scripts/release-testflight.sh %s %s\n' \
        "$VERSION" "$BUILD"
}

local_preflight() {
    require_command git
    require_command jq
    require_command ruby
    require_command rg
    require_command shasum
    require_command plutil
    [[ -d "$PROJECT" ]] || die "Missing Xcode project: $PROJECT"
    [[ -f "$EXPORT_OPTIONS" ]] || die "Missing export options: $EXPORT_OPTIONS"
    validate_note_shape
    extract_what_to_test >/dev/null \
        || die "$NOTES_FILE needs nonempty What to test text of at most 4000 characters."
}

dry_run() {
    local current_version current_build
    local_preflight
    validate_dirty_paths "$NOTES_FILE"
    current_version=$(project_value MARKETING_VERSION)
    current_build=$(project_value CURRENT_PROJECT_VERSION)
    validate_next_version "$current_version" "$current_build"
    [[ ! -e "$STATE_FILE" ]] || die "Release state already exists; inspect it and use --resume."
    [[ ! -e "$ARCHIVE_PATH" ]] || die "Archive already exists: $ARCHIVE_PATH"
    [[ ! -e "$EXPORT_PATH" ]] || die "Export path already exists: $EXPORT_PATH"

    pass "Local TestFlight preflight passed"
    printf '%s\n' \
        "Would create branch: $RELEASE_BRANCH" \
        "Would bump: $current_version ($current_build) -> $VERSION ($BUILD)" \
        "Would test, archive, upload, configure Internal, verify IN_BETA_TESTING, commit, tag, and push." \
        "No files, Git refs, network services, or Apple data were changed."
}

if [[ "$action" == "prepare" ]]; then
    prepare_notes
    exit 0
fi
if [[ "$action" == "dry-run" ]]; then
    dry_run
    exit 0
fi

local_preflight
load_private_config

current_branch=$(git branch --show-current)
[[ -n "$current_branch" ]] || die "Releases cannot start from detached HEAD."

if [[ "$action" == "release" ]]; then
    validate_dirty_paths "$NOTES_FILE"
    [[ ! -e "$STATE_FILE" ]] || die "Release state already exists; use --resume."
    [[ ! -e "$ARCHIVE_PATH" ]] || die "Archive already exists: $ARCHIVE_PATH"
    [[ ! -e "$EXPORT_PATH" ]] || die "Export path already exists: $EXPORT_PATH"
    git show-ref --verify --quiet "refs/tags/v${VERSION}" && die "Tag v$VERSION already exists."
    remote_ref_exists "refs/tags/v${VERSION}" && die "Remote tag v$VERSION already exists."

    current_version=$(project_value MARKETING_VERSION)
    current_build=$(project_value CURRENT_PROJECT_VERSION)
    validate_next_version "$current_version" "$current_build"

    app_id=$(app_store_app_id)
    group_id=$(internal_group_id "$app_id")
    existing_builds=$(build_response "$app_id")
    [[ $(jq '.data | length' <<<"$existing_builds") == "0" ]] \
        || die "App Store Connect already contains $VERSION ($BUILD); never reuse it."

    if [[ "$current_branch" != "$RELEASE_BRANCH" ]]; then
        git show-ref --verify --quiet "refs/heads/${RELEASE_BRANCH}" \
            && die "Local branch $RELEASE_BRANCH already exists. Switch to it and inspect before continuing."
        remote_ref_exists "refs/heads/${RELEASE_BRANCH}" \
            && die "Remote branch $RELEASE_BRANCH already exists. Switch to it and inspect before continuing."
        git switch -c "$RELEASE_BRANCH"
    fi
    state_create "$(git rev-parse HEAD)"
else
    validate_state
    [[ "$current_branch" == "$RELEASE_BRANCH" ]] \
        || die "Resume from $RELEASE_BRANCH, not $current_branch."
    if [[ "$action" == "retry-upload" ]]; then
        [[ "$(state_phase)" == "uploading" ]] \
            || die "--retry-upload is allowed only when state is exactly 'uploading'."
        state_set archived
    fi
    app_id=$(app_store_app_id)
    group_id=$(internal_group_id "$app_id")
fi

base_commit=$(jq -r '.baseCommit' "$STATE_FILE")
if phase_at_least committed; then
    release_commit=$(jq -er '.releaseCommit' "$STATE_FILE")
    [[ "$(git rev-parse HEAD)" == "$release_commit" ]] \
        || die "HEAD moved after the release commit. Expected $release_commit."
elif [[ "$(state_phase)" != "committing" ]]; then
    [[ "$(git rev-parse HEAD)" == "$base_commit" ]] \
        || die "HEAD moved after the release began. Expected $base_commit."
fi

if ! phase_at_least versioned; then
    current_version=$(project_value MARKETING_VERSION)
    current_build=$(project_value CURRENT_PROJECT_VERSION)
    if [[ "$current_version" != "$VERSION" || "$current_build" != "$BUILD" ]]; then
        validate_next_version "$current_version" "$current_build"
        set_project_versions "$current_version" "$current_build"
    fi
    update_release_date
    [[ "$(project_value MARKETING_VERSION)" == "$VERSION" ]] || die "Marketing version update failed."
    [[ "$(project_value CURRENT_PROJECT_VERSION)" == "$BUILD" ]] || die "Build number update failed."
    validate_dirty_paths "$PBXPROJ,$NOTES_FILE"
    state_set versioned
    pass "Versioned every shipping target as $VERSION ($BUILD)"
fi

if ! phase_at_least tested; then
    validate_dirty_paths "$PBXPROJ,$NOTES_FILE"
    ./scripts/check-public.sh
    ./scripts/sim.sh --unit
    ./scripts/sim.sh
    validate_dirty_paths "$PBXPROJ,$NOTES_FILE"
    state_set tested
    pass "Release tests passed"
fi

mkdir -p "$(dirname "$ARCHIVE_PATH")"
if ! phase_at_least archived; then
    [[ ! -e "$ARCHIVE_PATH" ]] || die "Archive path unexpectedly exists: $ARCHIVE_PATH"
    validate_dirty_paths "$PBXPROJ,$NOTES_FILE"
    archive_fingerprint=$(release_fingerprint)
    state_set_fingerprint "$archive_fingerprint"
    run_logged "Archive $VERSION ($BUILD)" "$ARCHIVE_LOG" \
        xcodebuild \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -configuration Release \
            -destination 'generic/platform=iOS' \
            -archivePath "$ARCHIVE_PATH" \
            -allowProvisioningUpdates \
            -authenticationKeyPath "$ASC_KEY_PATH" \
            -authenticationKeyID "$ASC_KEY_ID" \
            -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
            archive
    validate_archive_versions
    validate_dirty_paths "$PBXPROJ,$NOTES_FILE"
    [[ "$(release_fingerprint)" == "$archive_fingerprint" ]] \
        || die "Release version or notes changed while Xcode was archiving."
    state_set archived
fi

if ! phase_at_least uploaded; then
    if [[ "$(state_phase)" == "uploading" ]]; then
        warn "The previous upload was interrupted after it started. Waiting for Apple rather than risking a duplicate upload."
        build_id=$(wait_for_processed_build "$app_id")
        state_set processed
    else
        [[ -d "$ARCHIVE_PATH" ]] || die "Missing archive for upload: $ARCHIVE_PATH"
        [[ ! -e "$EXPORT_PATH" ]] || die "Export path unexpectedly exists: $EXPORT_PATH"
        validate_dirty_paths "$PBXPROJ,$NOTES_FILE"
        expected_fingerprint=$(jq -er '.sourceFingerprint' "$STATE_FILE")
        [[ "$(release_fingerprint)" == "$expected_fingerprint" ]] \
            || die "Release files changed after archiving; refusing to upload a mismatched archive."
        state_set uploading
        run_logged "Upload $VERSION ($BUILD)" "$UPLOAD_LOG" \
            xcodebuild \
                -exportArchive \
                -archivePath "$ARCHIVE_PATH" \
                -exportPath "$EXPORT_PATH" \
                -exportOptionsPlist "$EXPORT_OPTIONS" \
                -allowProvisioningUpdates \
                -authenticationKeyPath "$ASC_KEY_PATH" \
                -authenticationKeyID "$ASC_KEY_ID" \
                -authenticationKeyIssuerID "$ASC_ISSUER_ID"
        state_set uploaded
    fi
fi

if ! phase_at_least processed; then
    build_id=$(wait_for_processed_build "$app_id")
    state_set processed
    pass "Apple processed $VERSION ($BUILD)"
else
    response=$(build_response "$app_id")
    [[ $(jq '.data | length' <<<"$response") == "1" ]] \
        || die "Processed build $VERSION ($BUILD) is no longer uniquely available."
    [[ $(jq -r '.data[0].attributes.processingState' <<<"$response") == "VALID" ]] \
        || die "Processed build $VERSION ($BUILD) is no longer VALID."
    build_id=$(jq -r '.data[0].id' <<<"$response")
fi

what_to_test=$(extract_what_to_test) \
    || die "$NOTES_FILE needs nonempty What to test text of at most 4000 characters."
if ! phase_at_least localized; then
    set_what_to_test "$build_id" "$what_to_test"
    state_set localized
    pass "Saved $ASC_LOCALE What to Test metadata"
fi

if ! phase_at_least grouped; then
    add_build_to_group "$build_id" "$group_id"
    state_set grouped
    pass "Assigned build to $ASC_BETA_GROUP"
fi

if ! phase_at_least verified; then
    wait_for_internal_testing "$build_id" "$group_id"
    expected_fingerprint=$(jq -er '.sourceFingerprint' "$STATE_FILE")
    [[ "$(release_fingerprint)" == "$expected_fingerprint" ]] \
        || die "Release files changed after archiving; refusing to commit source that differs from the upload."
    validate_dirty_paths "$PBXPROJ,$NOTES_FILE"
    state_set verified
    pass "Verified $VERSION ($BUILD) as IN_BETA_TESTING"
fi

if ! phase_at_least committed; then
    if [[ "$(state_phase)" == "committing" ]]; then
        if [[ "$(git rev-parse HEAD)" == "$base_commit" ]]; then
            git add -- "$PBXPROJ" "$NOTES_FILE"
            git commit -m "release: v${VERSION}"
        elif [[ "$(git rev-parse HEAD^)" == "$base_commit" \
            && "$(git log -1 --format=%s)" == "release: v${VERSION}" ]]; then
            :
        else
            die "Could not reconcile an interrupted release commit. Inspect Git before resuming."
        fi
    else
        state_set committing
        git add -- "$PBXPROJ" "$NOTES_FILE"
        git commit -m "release: v${VERSION}"
    fi
    expected_fingerprint=$(jq -er '.sourceFingerprint' "$STATE_FILE")
    [[ "$(release_fingerprint)" == "$expected_fingerprint" ]] \
        || die "Release commit does not match the archived source fingerprint."
    validate_dirty_paths ""
    state_set_release_commit "$(git rev-parse HEAD)"
    state_set committed
    pass "Committed exact shipped source"
fi

if ! phase_at_least tagged; then
    state_set tagging
    if git show-ref --verify --quiet "refs/tags/v${VERSION}"; then
        [[ "$(git rev-list -n 1 "v${VERSION}")" == "$(git rev-parse HEAD)" ]] \
            || die "Tag v$VERSION exists but does not point to the release commit."
    else
        git tag "v${VERSION}"
    fi
    state_set tagged
    pass "Tagged v$VERSION"
fi

if ! phase_at_least pushed; then
    state_set pushing
    git push -u "$REMOTE" "$RELEASE_BRANCH"
    git push "$REMOTE" "v${VERSION}"
    remote_branch_sha=$(git ls-remote "$REMOTE" "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')
    remote_tag_sha=$(git ls-remote "$REMOTE" "refs/tags/v${VERSION}" | awk '{print $1}')
    [[ "$remote_branch_sha" == "$(git rev-parse HEAD)" ]] \
        || die "Remote release branch does not point to the shipped commit."
    [[ "$remote_tag_sha" == "$(git rev-parse HEAD)" ]] \
        || die "Remote release tag does not point to the shipped commit."
    state_set pushed
fi

[[ -z "$(git status --short)" ]] || die "Release finished but the working tree is not clean."
bold "TestFlight release v$VERSION is complete."
printf '%s\n' \
    "Apple build: $VERSION ($BUILD)" \
    "Beta group: $ASC_BETA_GROUP — IN_BETA_TESTING" \
    "Git commit: $(git rev-parse HEAD)" \
    "Git tag: v$VERSION" \
    "State: $STATE_FILE"
