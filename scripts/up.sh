#!/usr/bin/env sh
# Creates the shared network (idempotent) and brings the platform up for one environment (Annex J.5).
# usage: ./scripts/up.sh dev|qa|main     (the environment is required: there is no default)
set -eu
cd "$(dirname "$0")/.."
environment="${1:-}"
case "$environment" in dev|qa|main) ;; *) echo "usage: $0 dev|qa|main"; exit 1 ;; esac
env_file="env/$environment.env"
[ -f "$env_file" ] || { echo "missing $env_file: cp env/$environment.env.example $env_file"; exit 1; }
grep -q '^JWT_PUBLIC_KEY=.' "$env_file" || { echo "JWT_PUBLIC_KEY is empty in $env_file: run ./scripts/dev-keys.sh (dev only)"; exit 1; }
grep -Eq '^SERVICE_TOKEN=.|^SERVICE_TOKEN_FILE=.' "$env_file" || { echo "SERVICE_TOKEN (or SERVICE_TOKEN_FILE) is empty in $env_file: csp-worker would be refused by the booking service; run ./scripts/dev-keys.sh (dev only)"; exit 1; }
# The booking service only lets a subject call the internal operations of its own family: csp-worker the maintenance ones and
# csp-workflow the ones of /internal/workflow/. Any other token is a 403.
check_subject() {  # variable, subject
  token=$(grep "^$1=" "$env_file" | cut -d= -f2-) || true
  if [ -n "$token" ]; then
    payload=$(printf '%s' "$token" | cut -d. -f2 | tr '_-' '/+')
    while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="$payload="; done
    printf '%s' "$payload" | base64 -d 2>/dev/null | grep -Eq "\"sub\" *: *\"$2\"" || { echo "$1 is not a token whose sub is $2: run ./scripts/dev-keys.sh (dev only)"; exit 1; }
  fi
}
check_subject SERVICE_TOKEN csp-worker
# csp-workflow presents this token to the booking service: without it the sagas cannot hold or confirm a reservation.
grep -q '^WORKFLOW_SERVICE_TOKEN=.' "$env_file" || { echo "WORKFLOW_SERVICE_TOKEN is empty in $env_file: the booking service would refuse csp-workflow; run ./scripts/dev-keys.sh (dev only)"; exit 1; }
check_subject WORKFLOW_SERVICE_TOKEN csp-workflow
# csp-booking-api presents this file to Catalog: without it the seat map and the hold answer 503.
catalog_token_file=$(grep '^CATALOG_SERVICE_TOKEN_HOST_FILE=' "$env_file" | cut -d= -f2-) || true
[ -n "$catalog_token_file" ] && [ -s "$catalog_token_file" ] || { echo "CATALOG_SERVICE_TOKEN_HOST_FILE is empty or points to a missing or empty file in $env_file: it must hold the credential of booking-service for Catalog; run ./scripts/dev-keys.sh (dev only)"; exit 1; }
# Catalog serves HTTPS only (ADR-067): without its certificate, its key and the CA file it does not start and the callers cannot trust it.
for variable in CATALOG_TLS_CERTIFICATE_HOST_FILE CATALOG_TLS_PRIVATE_KEY_HOST_FILE CATALOG_TLS_CA_HOST_FILE; do
  tls_file=$(grep "^$variable=" "$env_file" | cut -d= -f2-) || true
  [ -n "$tls_file" ] && [ -s "$tls_file" ] || { echo "$variable is empty or points to a missing or empty file in $env_file: run ./scripts/internal-ca.sh $environment"; exit 1; }
done
grep -q '^MONGO_KEYFILE=.' "$env_file" || { echo "MONGO_KEYFILE is empty in $env_file: openssl rand -base64 48 | tr -d '[:space:]'"; exit 1; }
docker network inspect platform >/dev/null 2>&1 || docker network create platform
docker compose --env-file "$env_file" up -d --build
docker compose --env-file "$env_file" ps
