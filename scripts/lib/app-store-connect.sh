#!/bin/bash
# App Store Connect API helpers. This file is sourced by release-testflight.sh.

ASC_API_BASE="${ASC_API_BASE:-https://api.appstoreconnect.apple.com}"

asc_require_tools() {
    local tool
    for tool in curl jq ruby; do
        command -v "$tool" >/dev/null 2>&1 \
            || { printf 'Missing required command: %s\n' "$tool" >&2; return 1; }
    done
}

asc_validate_config() {
    local name
    for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
        [[ -n "${!name:-}" ]] \
            || { printf 'Missing %s in TestFlight.local.env.\n' "$name" >&2; return 1; }
    done

    [[ "$ASC_KEY_PATH" = /* ]] \
        || { printf 'ASC_KEY_PATH must be an absolute path outside the repository.\n' >&2; return 1; }
    [[ -f "$ASC_KEY_PATH" ]] \
        || { printf 'App Store Connect key does not exist at ASC_KEY_PATH.\n' >&2; return 1; }
}

asc_urlencode() {
    jq -nr --arg value "$1" '$value | @uri'
}

asc_jwt() {
    ruby -rbase64 -rjson -ropenssl - "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$ASC_KEY_PATH" <<'RUBY'
key_id, issuer_id, key_path = ARGV

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

now = Time.now.to_i
header = { alg: "ES256", kid: key_id, typ: "JWT" }
payload = {
  iss: issuer_id,
  iat: now,
  exp: now + 600,
  aud: "appstoreconnect-v1"
}
signing_input = [header, payload].map { |part| base64url(JSON.generate(part)) }.join(".")

private_key = OpenSSL::PKey.read(File.binread(key_path))
digest = OpenSSL::Digest::SHA256.digest(signing_input)
der_signature = private_key.dsa_sign_asn1(digest)
sequence = OpenSSL::ASN1.decode(der_signature)
raw_signature = sequence.value.map do |integer|
  bytes = integer.value.to_s(2)
  abort "Invalid ES256 signature component" if bytes.bytesize > 32
  bytes.rjust(32, "\0")
end.join
abort "Invalid ES256 signature length" unless raw_signature.bytesize == 64

puts "#{signing_input}.#{base64url(raw_signature)}"
RUBY
}

asc_request() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    local response_file header_file old_umask status token

    old_umask=$(umask)
    umask 077
    response_file=$(mktemp "${TMPDIR:-/tmp}/wristmemo-asc-response.XXXXXX")
    header_file=$(mktemp "${TMPDIR:-/tmp}/wristmemo-asc-header.XXXXXX")
    umask "$old_umask"
    token=$(asc_jwt) || { rm -f "$response_file" "$header_file"; return 1; }
    printf 'Authorization: Bearer %s\n' "$token" >"$header_file"
    unset token

    local -a curl_args=(
        --silent
        --show-error
        --request "$method"
        --header "@${header_file}"
        --header "Accept: application/json"
        --output "$response_file"
        --write-out '%{http_code}'
    )
    if [[ -n "$body" ]]; then
        curl_args+=(--header "Content-Type: application/json" --data-binary "$body")
    fi

    if ! status=$(curl "${curl_args[@]}" "${ASC_API_BASE}${path}"); then
        printf 'App Store Connect request failed before receiving a response: %s %s\n' \
            "$method" "$path" >&2
        rm -f "$response_file" "$header_file"
        return 1
    fi

    if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
        printf 'App Store Connect rejected %s %s (HTTP %s).\n' "$method" "$path" "$status" >&2
        if [[ -s "$response_file" ]]; then
            jq -r '.errors[]? | "  \(.status // "error") \(.title // ""): \(.detail // "")"' \
                "$response_file" >&2 2>/dev/null || sed -n '1,20p' "$response_file" >&2
        fi
        rm -f "$response_file" "$header_file"
        return 1
    fi

    if [[ -s "$response_file" ]]; then
        cat "$response_file"
    fi
    rm -f "$response_file" "$header_file"
}
