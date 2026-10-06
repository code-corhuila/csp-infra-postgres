#!/usr/bin/env sh
# DEVELOPMENT ONLY. Prints an RS256 token signed with keys/jwt-private.pem.
# usage: ./scripts/dev-token.sh [subject] [minutes]
set -eu
cd "$(dirname "$0")/.."
subject="${1:-dev-user}"
minutes="${2:-60}"
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"sub":"%s","iat":%s,"exp":%s}' "$subject" "$now" "$((now + minutes * 60))" | b64url)
signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -binary -sign keys/jwt-private.pem | b64url)
printf '%s.%s.%s\n' "$header" "$payload" "$signature"
