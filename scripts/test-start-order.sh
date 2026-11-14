#!/usr/bin/env sh
# Checks the start order of scripts/up.sh (issues #59 and #63): PostgreSQL healthy, then the migration of every domain, then the rest.
# Needs no Docker. Prints the totals; exits 1 on any failure.
# usage: ./scripts/test-start-order.sh
set -u
cd "$(dirname "$0")/.."
pass=0
fail=0
check() {  # description, command...
  description="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); echo "ok   $description"; else fail=$((fail + 1)); echo "FAIL $description"; fi
}
line_of() { grep -n -- "$1" scripts/up.sh | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1; }
before() { [ -n "$(line_of "$1")" ] && [ -n "$(line_of "$2")" ] && [ "$(line_of "$1")" -lt "$(line_of "$2")" ]; }

check "up.sh starts postgres and waits for it" grep -q 'up -d --wait postgres' scripts/up.sh
check "up.sh runs the executors as tooling services" grep -Eq -- '--profile tooling run --rm .*"\$executor"' scripts/up.sh
for executor in booking-db-migrate auth-db-migrate ticketing-db-migrate worker-db-migrate workflow-db-migrate; do
  check "up.sh runs $executor" grep -Eq -- "for executor in .*$executor" scripts/up.sh
done
check "up.sh runs the migration of catalog as a tooling service" grep -Eq -- '--profile tooling run --rm .*catalog-db-migrate' scripts/up.sh
check "postgres is awaited before the executors" before 'up -d --wait postgres' 'for executor in'
check "mongodb is awaited before the migration of catalog" before 'up -d --wait mongodb' 'catalog-db-migrate'
check "the executors run before the full up" before 'catalog-db-migrate' 'up -d --build'
check "the executors run before mongodb is awaited" before 'for executor in' 'up -d --wait mongodb'
check "the healthcheck of postgres is a TCP check" grep -q 'pg_isready -h 127.0.0.1' compose.yml

echo "passed: $pass, failed: $fail, total: $((pass + fail))"
[ "$fail" -eq 0 ]
