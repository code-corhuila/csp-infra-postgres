#!/usr/bin/env sh
# Creates the shared network (idempotent) and brings the whole platform up.
set -eu
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "missing .env: cp env/.env.develop.example .env"; exit 1; }
grep -q '^JWT_PUBLIC_KEY=.' .env || { echo "JWT_PUBLIC_KEY is empty: run ./scripts/dev-keys.sh (develop only)"; exit 1; }
docker network inspect platform >/dev/null 2>&1 || docker network create platform
docker compose --env-file .env up -d --build
docker compose ps
