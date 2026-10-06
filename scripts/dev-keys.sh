#!/usr/bin/env sh
# DEVELOPMENT ONLY. Generates an RS256 key pair in keys/ (git-ignored) and writes
# into .env the public key every service validates with, plus a service token
# for csp-worker (its sub must be csp-worker: csp-booking-api only lets that subject call its internal operations). qa and main use the identity service's keys,
# injected as secrets — never these.
set -eu
cd "$(dirname "$0")/.."
mkdir -p keys
[ -f keys/jwt-private.pem ] || openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out keys/jwt-private.pem 2>/dev/null
openssl pkey -in keys/jwt-private.pem -pubout -out keys/jwt-public.pem

# One line with literal \n escapes: that is how a .env file holds a PEM.
public_key=$(awk '{ printf "%s\\n", $0 }' keys/jwt-public.pem)
service_token=$(./scripts/dev-token.sh csp-worker 1440)

touch .env
grep -v -e '^JWT_PUBLIC_KEY=' -e '^SERVICE_TOKEN=' .env > .env.tmp || true
printf 'JWT_PUBLIC_KEY="%s"\n' "$public_key" >> .env.tmp
printf 'SERVICE_TOKEN=%s\n' "$service_token" >> .env.tmp
mv .env.tmp .env
echo "keys/ and .env updated. A user token: ./scripts/dev-token.sh <subject> [minutes]"
