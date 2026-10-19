#!/bin/sh
# Instance setup of the single PostgreSQL of the environment (Annex J.5.5 and J.7). It runs only when the
# volume is empty, and it can be run again by hand when a domain is added: every statement is idempotent.
# The roles of each domain (booking_reader, booking_writer, auth_reader...) and its schema are created by its
# -db repository; here only the login users exist, with the passwords of the environment, and their search_path.
# The exception is <domain>_migrator (booking_migrator so far): the login of the migration executor of the -db
# repository, owner of the schema of its domain, so that no executor connects as the instance administrator after
# this script. It has CREATEROLE because the migrations create the roles of the domain (V002 of csp-booking-db);
# on PostgreSQL 16 that only lets it manage the roles it creates itself. It also has CREATE on the database (see below).
# The passwords reach psql as variables and are quoted by the engine (:'name'), never spliced into the SQL.
set -e
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -v booking_password="$BOOKING_APP_PASSWORD" -v auth_password="$AUTH_APP_PASSWORD" \
  -v worker_password="$WORKER_APP_PASSWORD" -v booking_migrator_password="$BOOKING_MIGRATOR_PASSWORD" <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'booking_app', :'booking_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'booking_app')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'auth_app', :'auth_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auth_app')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'worker_app', :'worker_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'worker_app')\gexec
SELECT format('CREATE ROLE %I LOGIN CREATEROLE PASSWORD %L', 'booking_migrator', :'booking_migrator_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'booking_migrator')\gexec
-- A new environment: booking_migrator creates the schema, so V001 of csp-booking-db finds it. An environment
-- that already ran the migrations as the administrator: the schema, its tables and the control table pass to
-- booking_migrator, and it gets the admin option on the roles the administrator created (V002), so the next
-- migrations can still grant them. Sequences owned by a column follow their table.
CREATE SCHEMA IF NOT EXISTS booking AUTHORIZATION booking_migrator;
-- PostgreSQL checks CREATE on the database before it looks at IF NOT EXISTS, so V001 of csp-booking-db
-- (CREATE SCHEMA IF NOT EXISTS booking) fails without it even though the schema exists. The grant does not
-- give access to the schemas of other domains.
SELECT format('GRANT CREATE ON DATABASE %I TO booking_migrator', current_database())\gexec
ALTER SCHEMA booking OWNER TO booking_migrator;
DO $$
DECLARE
  item record;
BEGIN
  FOR item IN
    SELECT c.relname,
           CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END AS kind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'booking' AND c.relkind IN ('r', 'p', 'v', 'm') AND pg_get_userbyid(c.relowner) <> 'booking_migrator'
  LOOP
    EXECUTE format('ALTER %s booking.%I OWNER TO booking_migrator', item.kind, item.relname);
  END LOOP;
END
$$;
SELECT format('GRANT %I TO booking_migrator WITH ADMIN OPTION', rolname) FROM pg_roles
WHERE rolname IN ('booking_reader', 'booking_writer', 'booking_outbox_reader')\gexec
ALTER ROLE booking_app SET search_path = booking;
ALTER ROLE auth_app SET search_path = auth;
SQL
