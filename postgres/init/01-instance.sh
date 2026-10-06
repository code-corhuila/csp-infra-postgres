#!/bin/sh
# Instance setup of the single PostgreSQL of the environment (Annex J.5.5). It runs only when the volume
# is empty, and it can be run again by hand when a domain is added: every statement is idempotent.
# The roles of each domain (booking_reader, booking_writer...) are created by its -db repository; here only
# the login users exist, with the passwords of the environment. The -db grants the roles to them.
set -e
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<SQL
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'booking_app', '$BOOKING_APP_PASSWORD')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'booking_app')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'worker_app', '$WORKER_APP_PASSWORD')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'worker_app')\gexec
ALTER ROLE booking_app SET search_path = booking;
SQL
