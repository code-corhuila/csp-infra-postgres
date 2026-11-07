#!/usr/bin/env sh
# Checks the start order of scripts/up.sh (issue #59): PostgreSQL healthy, then the migration of csp-workflow, then the rest.
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
check "up.sh runs the migration of the workflow as a tooling service" grep -Eq -- '--profile tooling run --rm .*workflow-db-migrate' scripts/up.sh
check "postgres is awaited before the migration" before 'up -d --wait postgres' 'workflow-db-migrate'
check "the migration runs before the full up" before 'workflow-db-migrate' 'up -d --build'
check "the healthcheck of postgres is a TCP check" grep -q 'pg_isready -h 127.0.0.1' compose.yml

echo "passed: $pass, failed: $fail, total: $((pass + fail))"
[ "$fail" -eq 0 ]
