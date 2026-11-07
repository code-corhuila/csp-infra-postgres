#!/bin/sh
# Instance setup of the single PostgreSQL of the environment (Annex J.5.5 and J.7). It runs only when the
# volume is empty, and it can be run again by hand when a domain is added: every statement is idempotent.
# The roles of each domain (booking_reader, booking_writer, auth_reader...) and its schema are created by its
# -db repository; here only the login users exist, with the passwords of the environment, and their search_path.
# The exception is <domain>_migrator (booking_migrator, auth_migrator and workflow_migrator so far): the login of the migration executor
# of the -db repository, owner of the schema of its domain, so that no executor connects as the instance administrator
# after this script. It has CREATEROLE because the migrations create the roles of the domain (V002 of csp-booking-db,
# V012 of csp-auth-db, V003 of csp-workflow); on PostgreSQL 16 that only lets it manage the roles it creates itself. It also has CREATE on the
# database (see below). A new domain adds one call to migrator() at the end.
# The passwords reach psql as variables and are quoted by the engine (:'name'), never spliced into the SQL.
set -e

# migrator <domain> <password>: the <domain>_migrator login and the schema it owns.
# A new environment: the migrator creates the schema, so V001 of the -db repository finds it. An environment that
# already ran the migrations as the administrator: the schema, its tables and the control table pass to the migrator,
# and it gets the admin option on the roles the administrator created, so the next migrations can still grant them.
# Sequences owned by a column follow their table.
# The optional third argument is the prefix of the logins and roles when it differs from the schema name (Ticketing: schema
# ticketing_fulfillment, ticketing_migrator, ticketing_reader, ticketing_writer, ticketing_outbox_reader).
migrator() {
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -v domain="$1" -v prefix="${3:-$1}" -v migrator="${3:-$1}_migrator" -v migrator_password="$2" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN CREATEROLE PASSWORD %L', :'migrator', :'migrator_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'migrator')\gexec
SELECT format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I', :'domain', :'migrator')\gexec
-- PostgreSQL checks CREATE on the database before it looks at IF NOT EXISTS, so V001 of the -db repository
-- (CREATE SCHEMA IF NOT EXISTS <domain>) fails without it even though the schema exists. The grant does not
-- give access to the schemas of other domains.
SELECT format('GRANT CREATE ON DATABASE %I TO %I', current_database(), :'migrator')\gexec
SELECT format('ALTER SCHEMA %I OWNER TO %I', :'domain', :'migrator')\gexec
SELECT format('ALTER %s %I.%I OWNER TO %I',
              CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END,
              n.nspname, c.relname, :'migrator')
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = :'domain' AND c.relkind IN ('r', 'p', 'v', 'm') AND pg_get_userbyid(c.relowner) <> :'migrator'\gexec
SELECT format('GRANT %I TO %I WITH ADMIN OPTION', rolname, :'migrator') FROM pg_roles
WHERE rolname IN (:'prefix' || '_reader', :'prefix' || '_writer', :'prefix' || '_outbox_reader')\gexec
SQL
}

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -v booking_password="$BOOKING_APP_PASSWORD" -v auth_password="$AUTH_APP_PASSWORD" \
  -v worker_password="$WORKER_APP_PASSWORD" -v workflow_password="$WORKFLOW_APP_PASSWORD" -v ticketing_password="$TICKETING_APP_PASSWORD" <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'booking_app', :'booking_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'booking_app')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'auth_app', :'auth_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auth_app')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'worker_app', :'worker_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'worker_app')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'workflow_app', :'workflow_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'workflow_app')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'ticketing_app', :'ticketing_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ticketing_app')\gexec
ALTER ROLE booking_app SET search_path = booking;
ALTER ROLE auth_app SET search_path = auth;
ALTER ROLE workflow_app SET search_path = workflow;
ALTER ROLE ticketing_app SET search_path = ticketing_fulfillment;
SQL

migrator booking "$BOOKING_MIGRATOR_PASSWORD"
migrator auth "$AUTH_MIGRATOR_PASSWORD"
migrator workflow "$WORKFLOW_MIGRATOR_PASSWORD"
migrator ticketing_fulfillment "$TICKETING_MIGRATOR_PASSWORD" ticketing
