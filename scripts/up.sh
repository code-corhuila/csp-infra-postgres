#!/usr/bin/env sh
# Creates the shared network (idempotent) and brings the whole platform up.
set -eu
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "missing .env: cp env/.env.develop.example .env"; exit 1; }
grep -q '^JWT_PUBLIC_KEY=.' .env || { echo "JWT_PUBLIC_KEY is empty: run ./scripts/dev-keys.sh (develop only)"; exit 1; }
grep -Eq '^SERVICE_TOKEN=.|^SERVICE_TOKEN_FILE=.' .env || { echo "SERVICE_TOKEN (or SERVICE_TOKEN_FILE) is empty: csp-worker would be refused by the booking service; run ./scripts/dev-keys.sh (develop only)"; exit 1; }
# The booking service only lets the subject csp-worker call its internal operations: any other token is a 403.
token=$(grep '^SERVICE_TOKEN=' .env | cut -d= -f2-) || true
if [ -n "$token" ]; then
  payload=$(printf '%s' "$token" | cut -d. -f2 | tr '_-' '/+')
  while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="$payload="; done
  printf '%s' "$payload" | base64 -d 2>/dev/null | grep -Eq '"sub" *: *"csp-worker"' || { echo "SERVICE_TOKEN is not a token whose sub is csp-worker: run ./scripts/dev-keys.sh (develop only)"; exit 1; }
fi
docker network inspect platform >/dev/null 2>&1 || docker network create platform
docker compose --env-file .env up -d --build
docker compose ps
