#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/release-testflight.sh"
LIBRARY="$ROOT/scripts/lib/app-store-connect.sh"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/wristmemo-release-tests.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT

fail() {
    printf 'release-testflight test failed: %s\n' "$1" >&2
    exit 1
}

fixture="$temporary_root/repository"
mkdir -p \
    "$fixture/scripts/lib" \
    "$fixture/src/swift_app/WristMemo.xcodeproj" \
    "$fixture/src/swift_app/Config" \
    "$fixture/docs/releases"
cp "$SCRIPT" "$fixture/scripts/release-testflight.sh"
cp "$LIBRARY" "$fixture/scripts/lib/app-store-connect.sh"
cp "$ROOT/scripts/lib/project-config.sh" "$fixture/scripts/lib/project-config.sh"
cp "$ROOT/src/swift_app/Config/TestFlightExportOptions.plist" "$fixture/src/swift_app/Config/TestFlightExportOptions.plist"
printf '%s\n' \
    'MARKETING_VERSION = 1.5;' \
    'CURRENT_PROJECT_VERSION = 12;' \
    >"$fixture/src/swift_app/WristMemo.xcodeproj/project.pbxproj"

git -C "$fixture" init -q
git -C "$fixture" config user.name "Release Test"
git -C "$fixture" config user.email "release-test@example.invalid"
git -C "$fixture" add .
git -C "$fixture" commit -qm fixture
fixture_branch=$(git -C "$fixture" branch --show-current)

WRISTMEMO_RELEASE_ROOT="$fixture" "$fixture/scripts/release-testflight.sh" --prepare 1.6 13 >/dev/null
notes="$fixture/docs/releases/1.6.md"
[[ -f "$notes" ]] || fail "--prepare did not create release notes"
sed -i '' \
    -e 's/- TODO/- Automated release test notes./' \
    -e 's/1. TODO/1. Install and exercise the build./' \
    "$notes"

dry_run_output=$(WRISTMEMO_RELEASE_ROOT="$fixture" \
    "$fixture/scripts/release-testflight.sh" --dry-run 1.6 13)
grep -Fq 'Local TestFlight preflight passed' <<<"$dry_run_output" \
    || fail "--dry-run did not pass valid inputs"
grep -Fq 'No files, Git refs, network services, or Apple data were changed.' <<<"$dry_run_output" \
    || fail "--dry-run did not report its safety boundary"
[[ "$(git -C "$fixture" branch --show-current)" == "$fixture_branch" ]] \
    || fail "--dry-run changed branches"
[[ "$(sed -n -E 's/.*MARKETING_VERSION = ([^;]+);/\1/p' "$fixture/src/swift_app/WristMemo.xcodeproj/project.pbxproj")" == "1.5" ]] \
    || fail "--dry-run changed the project version"

printf 'unrelated\n' >"$fixture/unrelated.txt"
if WRISTMEMO_RELEASE_ROOT="$fixture" \
    "$fixture/scripts/release-testflight.sh" --dry-run 1.6 13 >/dev/null 2>&1; then
    fail "--dry-run accepted an unrelated worktree change"
fi
rm "$fixture/unrelated.txt"

key_path="$temporary_root/AuthKey_TESTKEY.p8"
openssl ecparam -name prime256v1 -genkey -noout -out "$key_path" 2>/dev/null
ASC_KEY_ID="TESTKEY"
ASC_ISSUER_ID="00000000-0000-0000-0000-000000000000"
ASC_KEY_PATH="$key_path"
source "$LIBRARY"
token=$(asc_jwt)
ruby -rbase64 -rjson -ropenssl - "$token" "$key_path" <<'RUBY'
token, key_path = ARGV
header_segment, payload_segment, signature_segment = token.split(".")
abort "JWT does not have three segments" unless signature_segment

decode = ->(value) { Base64.urlsafe_decode64(value + "=" * ((4 - value.length % 4) % 4)) }
header = JSON.parse(decode.call(header_segment))
payload = JSON.parse(decode.call(payload_segment))
abort "wrong JWT algorithm" unless header["alg"] == "ES256"
abort "wrong JWT key id" unless header["kid"] == "TESTKEY"
abort "wrong JWT issuer" unless payload["iss"] == "00000000-0000-0000-0000-000000000000"
abort "wrong JWT audience" unless payload["aud"] == "appstoreconnect-v1"
abort "JWT lifetime is too long" unless payload["exp"] - payload["iat"] == 600

raw = decode.call(signature_segment)
abort "wrong raw ES256 signature length" unless raw.bytesize == 64
r = OpenSSL::BN.new(raw.byteslice(0, 32), 2)
s = OpenSSL::BN.new(raw.byteslice(32, 32), 2)
der = OpenSSL::ASN1::Sequence([
  OpenSSL::ASN1::Integer(r),
  OpenSSL::ASN1::Integer(s)
]).to_der
key = OpenSSL::PKey.read(File.binread(key_path))
digest = OpenSSL::Digest::SHA256.digest("#{header_segment}.#{payload_segment}")
abort "JWT signature did not verify" unless key.dsa_verify_asn1(digest, der)
RUBY

fake_bin="$temporary_root/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/curl" <<'FAKE_CURL'
#!/bin/bash
set -euo pipefail
output=""
authorization=""
while (($#)); do
    case "$1" in
        --output) output="$2"; shift 2 ;;
        --header)
            if [[ "$2" == @* ]]; then
                authorization=$(<"${2#@}")
            elif [[ "$2" == Authorization:* ]]; then
                authorization="$2"
            fi
            shift 2
            ;;
        --request|--write-out|--data-binary) shift 2 ;;
        --silent|--show-error) shift ;;
        *) shift ;;
    esac
done
[[ "$authorization" =~ ^Authorization:\ Bearer\ [^.]+\.[^.]+\.[^.]+$ ]] || exit 9
printf '{"data":[{"id":"mock-app"}]}' >"$output"
printf '200'
FAKE_CURL
chmod +x "$fake_bin/curl"
ASC_API_BASE="https://example.invalid"
api_response=$(PATH="$fake_bin:$PATH" asc_request GET '/v1/apps?limit=1')
[[ "$(jq -r '.data[0].id' <<<"$api_response")" == "mock-app" ]] \
    || fail "asc_request did not return the mocked JSON body"

printf 'release-testflight tests passed.\n'
