#!/bin/sh
# Instance setup of the single PostgreSQL of the environment (Annex J.5.5 and J.7). It runs only when the
# volume is empty, and it can be run again by hand when a domain is added: every statement is idempotent.
# The roles of each domain (booking_reader, booking_writer, auth_reader...) and its schema are created by its
# -db repository; here only the login users exist, with the passwords of the environment, and their search_path.
# The passwords reach psql as variables and are quoted by the engine (:'name'), never spliced into the SQL.
set -e
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -v booking_password="$BOOKING_APP_PASSWORD" -v auth_password="$AUTH_APP_PASSWORD" \
  -v worker_password="$WORKER_APP_PASSWORD" <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'booking_app', :'booking_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'booking_app')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'auth_app', :'auth_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auth_app')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'worker_app', :'worker_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'worker_app')\gexec
ALTER ROLE booking_app SET search_path = booking;
ALTER ROLE auth_app SET search_path = auth;
SQL
