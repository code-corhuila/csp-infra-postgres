#!/usr/bin/env sh
# Creates the shared network (idempotent) and brings the platform up for one environment (Annex J.5).
# usage: ./scripts/up.sh [dev|qa|main]     (default: dev)
set -eu
cd "$(dirname "$0")/.."
environment="${1:-dev}"
case "$environment" in dev|qa|main) ;; *) echo "usage: $0 [dev|qa|main]"; exit 1 ;; esac
env_file="env/$environment.env"
[ -f "$env_file" ] || { echo "missing $env_file: cp env/$environment.env.example $env_file"; exit 1; }
grep -q '^JWT_PUBLIC_KEY=.' "$env_file" || { echo "JWT_PUBLIC_KEY is empty in $env_file: run ./scripts/dev-keys.sh (dev only)"; exit 1; }
grep -Eq '^SERVICE_TOKEN=.|^SERVICE_TOKEN_FILE=.' "$env_file" || { echo "SERVICE_TOKEN (or SERVICE_TOKEN_FILE) is empty in $env_file: csp-worker would be refused by the booking service; run ./scripts/dev-keys.sh (dev only)"; exit 1; }
# The booking service only lets the subject csp-worker call its internal operations: any other token is a 403.
token=$(grep '^SERVICE_TOKEN=' "$env_file" | cut -d= -f2-) || true
if [ -n "$token" ]; then
  payload=$(printf '%s' "$token" | cut -d. -f2 | tr '_-' '/+')
  while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="$payload="; done
  printf '%s' "$payload" | base64 -d 2>/dev/null | grep -Eq '"sub" *: *"csp-worker"' || { echo "SERVICE_TOKEN is not a token whose sub is csp-worker: run ./scripts/dev-keys.sh (dev only)"; exit 1; }
fi
grep -q '^MONGO_KEYFILE=.' "$env_file" || { echo "MONGO_KEYFILE is empty in $env_file: openssl rand -base64 48 | tr -d '
'"; exit 1; }
docker network inspect platform >/dev/null 2>&1 || docker network create platform
docker compose --env-file "$env_file" up -d --build
docker compose --env-file "$env_file" ps
