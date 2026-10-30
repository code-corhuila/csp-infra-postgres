#!/usr/bin/env sh
# Brings one environment down. It never removes the volume: in qa and main the volume is the history of
# the system and `down -v` is never run (Annex J.5.4).
# usage: ./scripts/down.sh dev|qa|main     (the environment is required: there is no default)
set -eu
cd "$(dirname "$0")/.."
environment="${1:-}"
case "$environment" in dev|qa|main) ;; *) echo "usage: $0 dev|qa|main"; exit 1 ;; esac
docker compose --env-file "env/$environment.env" down
