#!/bin/bash
# Fail when the tracked tree contains secrets, live infrastructure identifiers,
# personal machine paths, or private artifacts.
set -euo pipefail
cd "$(dirname "$0")/.."

failures=0

check_regex() {
    local label="$1"
    local pattern="$2"
    local matches
    if matches=$(git grep --untracked --exclude-standard -nIE -e "$pattern" -- . ':!scripts/check-public.sh'); then
        printf 'public-tree check: %s\n%s\n' "$label" "$matches" >&2
        failures=$((failures + 1))
    fi
}

check_regex "private key material" '-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----'
check_regex "provider credential" '(sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{30,}|AKIA[0-9A-Z]{16}|ya29[.][A-Za-z0-9_-]{20,})'
check_regex "personal email provider address" '[A-Za-z0-9._%+-]+@(gmail|icloud|outlook|hotmail|yahoo)[.][A-Za-z]{2,}'
check_regex "absolute home-directory path" '(/Users/[^/[:space:]]+|/home/[^/[:space:]]+)/'
check_regex "deployed Cloud Run URL" 'https://[^[:space:]"`]+[.]run[.]app'
check_regex "concrete GCP service-account address" '[a-z0-9-]+@[a-z0-9-]+[.]iam[.]gserviceaccount[.]com'
check_regex "concrete Apple development team" 'DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}([;[:space:]]|$)'

private_artifacts=$(git ls-files --cached --others --exclude-standard | grep -E '(^|/)([.]env([.].*)?|terraform[.]tfvars|[^/]+[.]tfstate([.].*)?|[^/]+[.](pem|p12|mobileprovision|wav|m4a|caf|mp3|sqlite|db))$' | grep -vE '(^|/)[.]env[.]example$' || true)
if [[ -n "$private_artifacts" ]]; then
    printf 'public-tree check: private artifact filenames\n%s\n' "$private_artifacts" >&2
    failures=$((failures + 1))
fi

if [[ -f .private-patterns ]]; then
    while IFS= read -r pattern; do
        [[ -n "$pattern" && "$pattern" != \#* ]] || continue
        if matches=$(git grep --untracked --exclude-standard -nF -e "$pattern" -- . ':!scripts/check-public.sh'); then
            printf 'public-tree check: locally private identifier found\n%s\n' "$matches" >&2
            failures=$((failures + 1))
        fi
    done < .private-patterns
fi

if [[ $failures -ne 0 ]]; then
    printf 'public-tree check failed with %d finding group(s).\n' "$failures" >&2
    exit 1
fi

printf 'public-tree check passed.\n'
