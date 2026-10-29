#!/usr/bin/env sh
# DEVELOPMENT ONLY. Writes env/mailpit-relay.yml (git-ignored) from the MAILPIT_RELAY_* variables of env/dev.env and points
# MAILPIT_RELAY_FILE at it, for the profile `mail-relay` of csp-auth-api (Mailpit that also relays to a real SMTP provider).
# usage: ./scripts/mailpit-relay.sh      then: docker compose --env-file env/dev.env --profile mail-relay up -d mailpit-relay
# To renew the key or change provider, edit the MAILPIT_RELAY_* variables of env/dev.env and run it again.
set -eu
cd "$(dirname "$0")/.."
env_file=env/dev.env
[ -f "$env_file" ] || { echo "missing $env_file: cp env/dev.env.example $env_file"; exit 1; }
value() { grep -E "^$1=" "$env_file" | head -1 | cut -d= -f2- | tr -d '\r'; }
for name in MAILPIT_RELAY_HOST MAILPIT_RELAY_USER MAILPIT_RELAY_PASSWORD MAILPIT_RELAY_MATCHING; do
  [ -n "$(value "$name")" ] || { echo "$name is empty in $env_file"; exit 1; }
done
port=$(value MAILPIT_RELAY_PORT); port="${port:-587}"
starttls=$(value MAILPIT_RELAY_STARTTLS); starttls="${starttls:-true}"
umask 077
relay_file=env/mailpit-relay.yml
{
  printf 'host: %s\n' "$(value MAILPIT_RELAY_HOST)"
  printf 'port: %s\n' "$port"
  printf 'starttls: %s\n' "$starttls"
  printf 'auth: plain\n'
  printf "username: '%s'\n" "$(value MAILPIT_RELAY_USER)"
  printf "password: '%s'\n" "$(value MAILPIT_RELAY_PASSWORD)"
} > "$relay_file"
absolute="$(pwd -W 2>/dev/null || pwd)/$relay_file"
grep -v '^MAILPIT_RELAY_FILE=' "$env_file" > "$env_file.tmp" || true
printf 'MAILPIT_RELAY_FILE=%s\n' "$absolute" >> "$env_file.tmp"
mv "$env_file.tmp" "$env_file"
echo "$relay_file written and MAILPIT_RELAY_FILE set in $env_file"
