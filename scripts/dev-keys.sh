#!/usr/bin/env sh
# DEVELOPMENT ONLY. Generates an RS256 key pair in keys/ (git-ignored) and writes
# into env/dev.env the public key every service validates with, plus a service token
# for csp-worker (its sub must be csp-worker: csp-booking-api only lets that subject call its internal operations). qa and main use the identity service's keys,
# injected as secrets — never these.
set -eu
cd "$(dirname "$0")/.."
mkdir -p keys
[ -f keys/jwt-private.pem ] || openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out keys/jwt-private.pem 2>/dev/null
openssl pkey -in keys/jwt-private.pem -pubout -out keys/jwt-public.pem

# One line with literal \n escapes: that is how an env file holds a PEM.
public_key=$(awk '{ printf "%s\\n", $0 }' keys/jwt-public.pem)
service_token=$(./scripts/dev-token.sh csp-worker 1440)

env_file=env/dev.env
[ -f "$env_file" ] || cp env/dev.env.example "$env_file"
grep -v -e '^JWT_PUBLIC_KEY=' -e '^SERVICE_TOKEN=' "$env_file" > "$env_file.tmp" || true
printf 'JWT_PUBLIC_KEY="%s"\n' "$public_key" >> "$env_file.tmp"
printf 'SERVICE_TOKEN=%s\n' "$service_token" >> "$env_file.tmp"
mv "$env_file.tmp" "$env_file"
echo "keys/ and $env_file updated. A user token: ./scripts/dev-token.sh <subject> [minutes]"
