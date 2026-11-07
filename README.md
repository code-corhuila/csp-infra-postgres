# csp-infra

> The PostgreSQL instance of the platform, its composition, observability, environments and development identity

Part of the **Cinesync Platform (CSP)** distributed system, Grupo 1.
Governance and documentation live in [`csp-docs`](https://github.com/code-corhuila/csp-docs).

This repository is the one Annex J (J.8) renamed from `csp-infra` to `csp-infra-postgres`: it **defines the single PostgreSQL instance** of each environment (container, volume, login users, one env file per environment), and it keeps the **root composition** of the platform there (J.8.1). Apart from that instance, **it composes; it does not contain.** Every runnable repository ships its own
`deploy/compose.yml`; this repository includes them, creates the shared network and adds the cross-cutting
services that belong to no domain: observability.

```
compose.yml                    root: includes every repository, adds observability
env/<environment>.env.example    one file per environment: dev, qa, main (Annex J.5.1)
observability/                 OpenTelemetry collector, Prometheus, Grafana
scripts/up.sh dev|qa|main     checks env/<environment>.env, creates the network and brings everything up
scripts/down.sh
scripts/internal-ca.sh          internal CA of one environment and the TLS certificate of Catalog in keys/tls/<env>/ (ADR-067)
scripts/test-internal-ca.sh     checks of the script and of the TLS variables of the env examples (prints totals)
scripts/dev-keys.sh            DEVELOPMENT ONLY: RS256 key pair in keys/ (git-ignored), JWT_PUBLIC_KEY, SERVICE_TOKEN, WORKFLOW_SERVICE_TOKEN and APP_AUTH_JWT_PRIVATE_KEY in env/dev.env
scripts/dev-token.sh           DEVELOPMENT ONLY: prints a signed token for a subject, with `iss` csp-auth and `aud` csp-internal (ADR-056)
```

## Repositories are cloned as siblings

The `include` paths of `compose.yml` assume that every repository is cloned next to this one, in a folder named as the repository (`csp-booking-db`, `csp-booking-api`, `csp-auth-db`, `csp-auth-api`, `csp-worker`, `csp-infra-mongo`, `csp-catalog-db`, `csp-catalog-api`, `csp-infra-redis`, `csp-infra-rabbitmq`, `csp-infra-rustfs`, `csp-api-gateway`). A missing
sibling fails loudly on `up`: nothing is silently skipped.

## The booking slice

`compose.yml` runs the single PostgreSQL instance of the environment (Annex J) and includes `csp-booking-db`,
`csp-booking-api` and `csp-worker`. The migration executor of a `-db` repository is a tooling service: it does
not start with `up`, but `./scripts/up.sh` runs every executor (booking, auth, ticketing, concessions, worker, workflow and catalog) after the
database is healthy and before the services start, so an environment brought up from scratch or after a pull that adds a migration
is migrated. The migrations are idempotent; you can still run one executor by hand, as the commands below do.

```bash
cp env/dev.env.example env/dev.env  # set PG_ADMIN_PASSWORD, BOOKING_APP_PASSWORD, BOOKING_MIGRATOR_PASSWORD, WORKER_APP_PASSWORD, WORKFLOW_APP_PASSWORD and WORKFLOW_MIGRATOR_PASSWORD
./scripts/dev-keys.sh                 # dev only: JWT_PUBLIC_KEY and the SERVICE_TOKEN of csp-worker
./scripts/up.sh dev
docker compose --env-file env/dev.env run --rm booking-db-migrate
```

The migration executor of `csp-booking-db` does not connect as the administrator: the instance creates the login
`booking_migrator` (password `BOOKING_MIGRATOR_PASSWORD`), owner of the `booking` schema, with `CREATEROLE` because the
migrations create the roles of the domain (on PostgreSQL 16 that only lets it manage the roles it creates) and `CREATE` on
the database, which PostgreSQL requires even for `CREATE SCHEMA IF NOT EXISTS`. The pattern is `<domain>_migrator`; auth
follows in its own change. **An environment that already exists** adds `BOOKING_MIGRATOR_PASSWORD` to its env file, recreates
the `postgres` container and runs the init script once by hand (see "An existing environment: switch to the migrators"): the script
moves the schema, its tables and the control table to `booking_migrator` (and the same for `auth_migrator`), and then
`BOOKING_DB_USER`, `BOOKING_DB_PASSWORD`, `AUTH_DB_USER` and `AUTH_DB_PASSWORD` point to them.

**Service-only side of `csp-booking-api`.** The platform gives Booking three things besides its database. `SERVICE_SUBJECTS` (`csp-worker`) lets the worker call
the maintenance operations; `WORKFLOW_SUBJECTS` (`csp-workflow`) lets the workflow service call `/internal/workflow/`, and empty keeps that family closed; a
subject of one list gets `403` on the other family (ADR-035). `CATALOG_BASE_URL` points to Catalog inside the platform network and
`CATALOG_SERVICE_TOKEN_HOST_FILE` is the absolute path of the file that holds the credential of `booking-service` (`iss` `csp-auth`, `aud` `csp-internal`, ADR-056): compose
mounts it read-only at `CATALOG_SERVICE_TOKEN_FILE` and the service re-reads it every 30 s. In develop `./scripts/dev-keys.sh` writes it (`keys/booking-service.token`) and fills in
the path; in qa and main the identity service issues it as the secret `CATALOG_SERVICE_TOKEN` and the deployment writes its value to a file. `./scripts/up.sh` refuses to start
without that file. **An environment that already exists** copies the new block of its `env/*.env.example` (the four variables above) before the next `./scripts/up.sh`.

Until the schema is migrated, `GET /health/ready` of the booking service answers `503` and the worker logs the
failed sweep with its correlation id; the next sweep works. Then `csp-worker` calls the expiration operation of
`csp-booking-api` every minute with its service token.

## The auth slice

`compose.yml` also includes `csp-auth-db` (the migration executor `auth-db-migrate`) and `csp-auth-api`. The
instance creates the login `auth_app` (password `AUTH_APP_PASSWORD`) with `search_path = auth`; the executor connects
as `auth_migrator` (password `AUTH_MIGRATOR_PASSWORD`), owner of the `auth` schema, with the same rights and the same
bootstrap as `booking_migrator` (see the booking slice). The migration `V013` grants `auth_writer` to `auth_app` and
`auth_outbox_reader` to `worker_app`, so both logins must exist **before** the migration runs: that is why the
instance creates them and the executor does not.

```bash
cp env/dev.env.example env/dev.env  # also set AUTH_MIGRATOR_PASSWORD and AUTH_APP_PASSWORD, URL-safe because it goes inside APP_AUTH_DATABASE_URL: openssl rand -hex 24
./scripts/dev-keys.sh                 # dev only: also APP_AUTH_JWT_PRIVATE_KEY, the private half of the pair every service validates with
./scripts/up.sh dev
docker compose --env-file env/dev.env --profile tooling run --rm auth-db-migrate
```

Run the executor before using the API: until the schema is migrated, the API has no tables to work with. In qa and
main `APP_AUTH_JWT_PRIVATE_KEY` is injected as a secret by the owner of the identity service and is never versioned;
the development key never leaves `develop`.

The signing key of auth (`APP_AUTH_JWT_PRIVATE_KEY`) is a secret that sits in the same env files as the database credentials, so in `qa` and `main` it is injected as a secret by the owner of the identity service and the example files only carry the empty placeholder. A leaked env file of those environments exposes both the database access and the ability to sign tokens, so the real files are never versioned (they are git-ignored) and are readable only by the people who operate the environment.

**An environment that already exists** has a volume, so the init script does not run again (Annex J.5.5). Add the
login once by hand: recreate the `postgres` container so it receives `AUTH_APP_PASSWORD`, `BOOKING_MIGRATOR_PASSWORD` and `AUTH_MIGRATOR_PASSWORD` (the volume and its data are
kept), then run the same script, which is idempotent.

```bash
docker compose --env-file env/dev.env up -d postgres
docker compose --env-file env/dev.env exec -T postgres sh /docker-entrypoint-initdb.d/01-instance.sh
```

### An existing environment: switch to the migrators

Do it in this order, once per environment (dev, qa, main), with `env/<environment>.env`. It was rehearsed with the real
compose and executors, on an environment already migrated as the administrator.

1. **Back up first** (Annex J.5.4). The database and the logins are saved separately, and a restore into a new instance
   needs both: `pg_dump` alone does not carry the roles (`booking_migrator`, `auth_app`...).

   ```bash
   docker compose --env-file env/qa.env exec -T postgres sh -c "pg_dump -U postgres -d csp -Fc -f /tmp/csp.dump && pg_dumpall -U postgres --globals-only > /tmp/globals.sql"
   docker cp csp-qa-postgres-1:/tmp/csp.dump . && docker cp csp-qa-postgres-1:/tmp/globals.sql .
   ```

   To restore into an empty instance: `psql -U postgres -f globals.sql`, then `createdb csp` and `pg_restore -d csp csp.dump`.
   The only error of the first step is that the role `postgres` already exists.
2. **Add `BOOKING_MIGRATOR_PASSWORD` and `AUTH_MIGRATOR_PASSWORD` to the env file, above the `BOOKING_DB_*` and `AUTH_DB_*`
   lines**, as in `env/*.env.example` (`openssl rand -hex 24`). Compose expands `${...}` in the order of the file: a password
   defined below the line that uses it expands to an empty string and the executor connects without one. In qa and main
   they are injected as secrets, never versioned.
3. **Recreate `postgres`** so it receives the variables; the volume and its data are kept. Without them Compose stops with
   `set BOOKING_MIGRATOR_PASSWORD`.

   ```bash
   docker compose --env-file env/qa.env up -d postgres
   ```
4. **Run the init script once**, by hand; it is idempotent. It creates both logins and moves the schemas, their tables and the
   control tables to them.

   ```bash
   docker compose --env-file env/qa.env exec -T postgres sh /docker-entrypoint-initdb.d/01-instance.sh
   ```
5. **Check the owners.** `booking` and `auth` must belong to `booking_migrator` and `auth_migrator`.

   ```bash
   docker compose --env-file env/qa.env exec -T postgres psql -U postgres -d csp -c "select nspname, nspowner::regrole from pg_namespace where nspname in ('auth','booking')"
   ```
6. **Only now** set `BOOKING_DB_USER=booking_migrator`, `BOOKING_DB_PASSWORD=${BOOKING_MIGRATOR_PASSWORD}`,
   `AUTH_DB_USER=auth_migrator` and `AUTH_DB_PASSWORD=${AUTH_MIGRATOR_PASSWORD}`, and run the executors; with nothing pending they
   answer `No migration necessary`. Switching before step 4 fails, because the logins do not exist yet.

   ```bash
   docker compose --env-file env/qa.env --profile tooling run --rm booking-db-migrate
   docker compose --env-file env/qa.env --profile tooling run --rm auth-db-migrate
   ```

## The MongoDB instance

The single MongoDB instance (Annex J) is defined in `csp-infra-mongo`, which has its own `compose.yml` and includes the
executor of `csp-catalog-db`. This repository includes it, so one `up.sh` starts both engines on the `platform`
network, and the two infrastructure repositories never talk to each other: services reach `postgres:5432` and
`mongodb:27017` by name. The MongoDB variables (`MONGO_ADMIN_*`, `MONGO_KEYFILE`, `CATALOG_DB_*`, `CATALOG_APP_PASSWORD`) live in the same
`env/<environment>.env`; `WORKER_APP_PASSWORD` is the password of `worker_app` in both engines.

```bash
docker compose --env-file env/dev.env --profile tooling run --rm catalog-db-migrate
```

## The catalog API

`csp-catalog-api` is included from `../csp-catalog-api/deploy/compose.yml`, so it must be cloned as a sibling of this
repository (`csp-catalog-db`, whose executor `csp-infra-mongo` already includes, is also listed in `compose.yml`). The service
is `catalog-api` on port `8082` of the `platform` network and is not published to the host: only the gateway reaches it, and
Booking calls it by name with its service credential (`https://catalog-api:8082/api/v1/catalog`, ADR-067). It logs in to MongoDB as `catalog_app`, so
`CATALOG_APP_PASSWORD` is required, and it validates tokens with the same `JWT_PUBLIC_KEY` as the other services. `SERVICE_SUBJECTS`
of the platform belongs to `csp-worker`; the subjects the catalog accepts on its availability route come from the optional
`CATALOG_SERVICE_SUBJECTS` (default `booking-service`). Run the migration executor before starting the service, so that
`catalog_app` already holds `catalog_writer`:

```bash
docker compose --env-file env/dev.env --profile tooling run --rm catalog-db-migrate
docker compose --env-file env/dev.env up -d --build catalog-api
```

## TLS to the catalog API (ADR-067)

`csp-catalog-api` answers HTTPS only. Every environment (`dev`, `qa`, `main`) has its own internal CA, `csp-internal-ca` (RSA 3072, 1 year), never
shared, and Catalog has a certificate issued by it (RSA 2048, **90 days**) with the names `catalog-api` and `localhost`. The callers trust that CA and nothing
else. One command creates both and writes the three host paths into `env/<environment>.env` (`dev-keys.sh` runs it for `dev`):

```bash
./scripts/internal-ca.sh dev|qa|main
```

It writes `keys/tls/<environment>/` (git-ignored): `ca.crt` (public), `catalog.crt` (the chain: certificate of Catalog, then the CA), `catalog.key`
and `ca.key`. **`ca.key` never leaves that folder**: it is not mounted into any container and no repository holds it. `./scripts/up.sh` refuses to start
when one of the three host files is missing.

**Renewal every 90 days:** run the same command again before the certificate expires. The CA is kept while it has more than 30 days left (so the callers
need no change) and a new certificate of Catalog is issued; the services re-read the files, so nothing restarts. When the CA is about to expire (1 year) the
command creates a new one, and every service that mounts `ca.crt` is restarted. Check the dates with
`openssl x509 -in keys/tls/<environment>/catalog.crt -noout -enddate`.

The variables are the same in every repository. Inside the containers the files are always `/run/tls/catalog.crt`, `/run/tls/catalog.key` and
`/run/tls/ca.crt` (`CATALOG_TLS_CERTIFICATE_FILE`, `CATALOG_TLS_PRIVATE_KEY_FILE`, `CATALOG_TLS_CA_FILE`); on the host they are the files named by
`CATALOG_TLS_CERTIFICATE_HOST_FILE`, `CATALOG_TLS_PRIVATE_KEY_HOST_FILE` and `CATALOG_TLS_CA_HOST_FILE`. The compose files of the services live in their own
repositories and must mount, read-only and in this order:

1. `csp-catalog-api`: `CATALOG_TLS_CERTIFICATE_HOST_FILE` at `/run/tls/catalog.crt`, `CATALOG_TLS_PRIVATE_KEY_HOST_FILE` at `/run/tls/catalog.key`, and
   `CATALOG_TLS_CA_HOST_FILE` at `/run/tls/ca.crt` (for its health check); it passes the three `CATALOG_TLS_*_FILE` variables.
2. `csp-api-gateway`: `CATALOG_TLS_CA_HOST_FILE` at `/run/tls/ca.crt`, and `APP_GATEWAY_CATALOG_UPSTREAM` (`https://catalog-api:8082`).
3. `csp-booking-api`: `CATALOG_TLS_CA_HOST_FILE` at `/run/tls/ca.crt`, `CATALOG_TLS_CA_FILE`, and `CATALOG_BASE_URL`
   (`https://catalog-api:8082/api/v1/catalog`), which it refuses when it is not `https://`.

Only the certificate and key mount into Catalog; the callers get only the public `ca.crt`. **An environment that already exists** copies the new block of
its `env/*.env.example` (`CATALOG_BASE_URL`, the six `CATALOG_TLS_*` variables and `APP_GATEWAY_CATALOG_UPSTREAM`) and runs the command before the next
`./scripts/up.sh`. Check the script and the variables with `./scripts/test-internal-ca.sh` (it prints the totals): it generates the three environments in a
temporary folder and verifies the chain, the two names, the 90 days and 1 year, that a certificate of one environment is rejected by the CA of another, and the
`https://` values of the env examples.

## The SMTP relay of the identity service

`csp-auth-api` sends the verification code of the email change through an SMTP relay (ADR-034). Its six variables
(`APP_AUTH_SMTP_HOST`, `_PORT`, `_USER`, `_PASSWORD`, `_FROM`, `_TLS`) live in the same `env/<environment>.env` and reach the
service through its own `deploy/compose.yml`. Without a host the two email-change routes answer `404`. In development the
example points to the Mailpit catcher of `csp-auth-api` (`docker compose --profile mail up mailpit`); in qa and main the six
values are injected as environment secrets and the example files only carry the empty placeholders; the real env files are never
versioned. An existing environment copies the block from `env/<environment>.env.example` before the next `./scripts/up.sh`.

The registration needs `APP_AUTH_REGISTRATION_CONFIRM_URL` (ADR-062): the page of the auth portal that the confirmation link opens (the address of the shell followed by
`/auth/confirm-registration`, without a fragment; the example of development already carries it). It is not a secret. `POST /register` creates no account: it mails that
link, so without the variable, or without the SMTP host, nobody can finish registering (the route still answers as usual and the service logs a `WARN`), and an environment
created from an older example has to add it.

The password reset needs one more variable, `APP_AUTH_PASSWORD_RESET_URL` (ADR-050): the page of the auth portal that the link of the mail opens, as the
browser reaches it (the address of the shell followed by `/auth/reset-password`, without a fragment; the example of development already carries it). It is not a secret.
Without it, or without the SMTP host, `POST /forgot-password` and `POST /reset-password` answer `404`, so an environment created from an older example has to add it.

**Real provider in development, with an expired key that does not break anything.** The service keeps pointing at Mailpit
(`APP_AUTH_SMTP_HOST=mailpit`, port `1025`, `APP_AUTH_SMTP_TLS=none`) and Mailpit relays the messages to a real SMTP provider, so every
message is shown at `http://localhost:8025`. Set `APP_AUTH_SMTP_TIMEOUT=15s` (the default, 5 s, is shorter than the handshake with the
provider) and the `MAILPIT_RELAY_*` variables of `env/dev.env` (host, port, user,
password, and `MAILPIT_RELAY_MATCHING`, a regular expression of the recipients that reach the provider: test addresses such as
`@example.com` should not), keep `APP_AUTH_SMTP_FROM` on a sender the provider has verified, and start it:

```bash
./scripts/mailpit-relay.sh      # writes env/mailpit-relay.yml (git-ignored) and MAILPIT_RELAY_FILE
docker compose --env-file env/dev.env --profile mail-relay up -d mailpit-relay    # instead of the profile `mail`
```

What was checked, on the development environment with the real service (recipients at `@example.com`, a copy of the API on the same image):

| Provider | Password reset (queued) | Email change (synchronous) |
|---|---|---|
| Expired key (`535 Authentication failed`), `APP_AUTH_SMTP_TIMEOUT=15s` | `202` at once | `202` in 1.2 s |
| Unreachable, `APP_AUTH_SMTP_TIMEOUT=5s` | `202` at once | `500` at 5.0 s |
| Unreachable, `APP_AUTH_SMTP_TIMEOUT=15s` | `202` at once | `500` at 10.2 s (the request deadline of 10 s) |

An expired key makes the relay fail with an error in the Mailpit log (`docker logs csp-dev-mailpit-relay-1`) and nothing else: Mailpit still
answers `250` and stores the message. A provider that is **unreachable or slow** is different: Mailpit relays inside the SMTP session, so it
answers the service only when the relay gives up (about 20 s when the provider is unreachable, 40 s with a greeting delayed by 40 s). The email
change sends its code synchronously and answers `500` when the timeout or the request deadline expires, although Mailpit stores the message
afterwards (a retry can duplicate it). The password reset is queued, so it is not affected. If the provider is down, use the profile `mail`
(no relay) until it is back. To renew the key or change provider, edit the `MAILPIT_RELAY_*` variables and run `./scripts/mailpit-relay.sh` and
the `up` command again; nothing else changes. Development only: qa and main use the six `APP_AUTH_SMTP_*` secrets directly.

## The Redis instance

The single Redis instance (Annex J) is defined in `csp-infra-redis`, which has its own `compose.yml`; `csp-infra-redis` must be
cloned as a sibling of this repository. This repository includes it, so one `up.sh` starts PostgreSQL, MongoDB and Redis on
the `platform` network, and services reach `redis:6379` by name. Redis keeps the auth state (attempt counters, temporary
lockout, revoked `jti`) and has no persistence. Its variables live in the same `env/<environment>.env`: `REDIS_ADMIN_PASSWORD`,
`AUTH_REDIS_PASSWORD` (URL-safe, because it goes inside `APP_AUTH_REDIS_URL`: `openssl rand -hex 24`) and `APP_AUTH_REDIS_URL`.
In qa and main the passwords are injected as environment secrets; the example files only carry the empty placeholders and the real
env files are never versioned.

**An environment that already exists** has an env file created before Redis, so add the two Redis variables to it (copy the block
from `env/<environment>.env.example`) before running `./scripts/up.sh`: the Redis service reads them from there.

```bash
./scripts/up.sh dev
```

## The RabbitMQ broker

The single RabbitMQ instance of the environment (ADR-036) is defined in `csp-infra-rabbitmq`, which has its own `compose.yml`;
`csp-infra-rabbitmq` must be cloned as a sibling of this repository. This repository includes it, so one `up.sh` also starts the
broker on the `platform` network, and services reach `rabbitmq:5672` by name. The broker is not published to the host: it creates
the exchanges `cine.events` and `cine.dlx` and one login per service, and no queues (each consumer declares its own at start-up).
Its variables live in the same `env/<environment>.env`: `RABBIT_ADMIN_PASSWORD`, `WORKER_RELAY_PASSWORD`,
`TICKETING_FULFILLMENT_PASSWORD` and `CONCESSIONS_PASSWORD` (URL-safe: `openssl rand -hex 24`), and `RELAY_AMQP_URL`, the URL
with the login `worker_relay` that `csp-worker` uses to publish. The broker does not start while one of the four passwords is
empty. In qa and main the passwords are injected as environment secrets.

**An environment that already exists** has an env file created before the broker, so add the block "The single RabbitMQ broker"
from `env/<environment>.env.example` to it before running `./scripts/up.sh`: the composition fails with `set <NAME>` otherwise.

**The relay of the auth events is enabled in the development example.** `AUTH_OUTBOX_RELAY_ENABLED=true` there because this
composition runs `csp-ticketing-api`, which declares the queues of the auth events (`cine.ticketing_fulfillment.user-registered`
and `cine.ticketing_fulfillment.user-email-changed`, with their `.dlq`). The order is: broker healthy, Ticketing migrated and running,
and then the relay. Keep the relay off in an environment until those queues exist. An event relayed before the queues exist is an
unroutable permanent failure; how to replay it is in the README of `csp-worker`.

## The ticketing service

`csp-ticketing-api` issues and emails the tickets and keeps its state in schema `ticketing_fulfillment` of this PostgreSQL instance (ADR-017). The repositories `csp-ticketing-db` and `csp-ticketing-api` must be cloned as siblings of this one. The platform gives them three things.

- **The database.** `postgres/init/01-instance.sh` creates the login `ticketing_app` (password `TICKETING_APP_PASSWORD`, `search_path` `ticketing_fulfillment`) and the migration executor `ticketing_migrator` (password `TICKETING_MIGRATOR_PASSWORD`), owner of the schema, with `CREATEROLE` and `CREATE` on the database. The schema is `ticketing_fulfillment` but the roles are `ticketing_*` (`ticketing_reader`, `ticketing_writer`, `ticketing_outbox_reader`), so `migrator()` takes the prefix as an optional third argument. The tooling service `ticketing-db-migrate` of `csp-ticketing-db` applies the migrations.
- **The variables.** Every one is named `TICKETING_*` or `OBJECT_STORAGE_*`, because `SPRING_DATASOURCE_*` and `RABBITMQ_*` belong to other services in the file they share: `TICKETING_DB_USER` and `TICKETING_DB_PASSWORD` (the executor), `TICKETING_APP_USER` and `TICKETING_APP_PASSWORD` (the service), `TICKETING_FULFILLMENT_PASSWORD` (its broker login, already in the broker block), `OBJECT_STORAGE_ACCESS_KEY` and `OBJECT_STORAGE_SECRET_KEY` (the read-only account of the bucket of the PDFs; the service refuses to start without them) and `TICKETING_SMTP_*`. The service builds its AMQP connection from the login and the password, so `TICKETING_AMQP_URL` is not needed here.
- **Object storage and mail catcher.** The bucket `tickets` comes from `csp-infra-rustfs` and the catcher from the profile `mail` of `csp-auth-api` (sections below), so in development `/health/ready` answers `200` once both are up and the service was created with the keys of the storage.

```bash
./scripts/up.sh dev
docker compose --env-file env/dev.env --profile tooling run --rm ticketing-db-migrate
```

**An environment that already exists** keeps its PostgreSQL volume, so the init script does not run again: add the new block to the env file, then run `docker compose --env-file env/<environment>.env exec postgres sh /docker-entrypoint-initdb.d/01-instance.sh` once (every statement is idempotent) before the migration.

## The concessions service

`csp-concessions-api` keeps products, combos, stock and orders in schema `concessions` of this PostgreSQL instance. The repositories `csp-concessions-db` and `csp-concessions-api` must be cloned as siblings of this one. The platform gives them two things.

- **The database.** `postgres/init/01-instance.sh` creates the login `concessions_app` (password `CONCESSIONS_APP_PASSWORD`, `search_path` `concessions`) and the migration executor `concessions_migrator` (password `CONCESSIONS_MIGRATOR_PASSWORD`), owner of the schema, with `CREATEROLE` and `CREATE` on the database. The roles `concessions_reader`, `concessions_writer` and `concessions_outbox_reader` and the grants to `concessions_app` and `worker_app` come from the migrations of `csp-concessions-db`.
- **The variables.** They are named `CONCESSIONS_*` because `SPRING_DATASOURCE_*` belong to Booking in the file they share: `CONCESSIONS_DB_USER` and `CONCESSIONS_DB_PASSWORD` (the executor) and `CONCESSIONS_APP_USER` and `CONCESSIONS_APP_PASSWORD` (the service). `WORKFLOW_SUBJECTS=csp-workflow` and `SERVICE_SUBJECTS` are the ones of the Booking block and also reach Concessions, so the workflow service can call `/internal/workflow/` (ADR-069). The gateway already routes `/api/v1/concessions/` to `concessions-api:8085`.

```bash
./scripts/up.sh dev
docker compose --env-file env/dev.env --profile tooling run --rm concessions-db-migrate
```

**An environment that already exists** keeps its PostgreSQL volume, so the init script does not run again: add the new block to the env file, then run `docker compose --env-file env/<environment>.env exec postgres sh /docker-entrypoint-initdb.d/01-instance.sh` once (every statement is idempotent) before the migration. The outbox relay of Concessions in `csp-worker` stays off until its flag is set.

## The object storage and the mail catcher

**Storage.** The single RustFS instance of the environment (ADR-058) is defined in `csp-infra-rustfs`, which must be cloned as a sibling of this repository (a clone of the former `csp-infra-minio` is not it: the repository was renamed). This repository includes it, so `up.sh` starts it on the `platform` network (`rustfs:9000`, never published to the host; the console is only published by the dev file of its own repository) and then runs its one-shot setup job (`docker compose run --rm -T setup < ../csp-infra-rustfs/rustfs/setup.sh`), which creates the private bucket `tickets` (versioning, 30-day expiry of old versions, hard quota) and two accounts: `ticketing_pdf_reader` (read on `tickets/*`, the `OBJECT_STORAGE_*` account of `csp-ticketing-api`) and `ticketing_pdf_writer` (write and read on `tickets/*`, for the PDF job of `csp-worker`). The setup is idempotent and `up.sh` refuses to start while `RUSTFS_ROOT_USER`, `RUSTFS_ROOT_PASSWORD`, `TICKETING_PDF_WRITER_SECRET` or `TICKETING_PDF_READER_SECRET` is empty (`openssl rand -hex 24`). `OBJECT_STORAGE_SECRET_KEY` is `${TICKETING_PDF_READER_SECRET}`, so the storage block must come before the Ticketing block in the env file (Compose only expands variables defined earlier). `csp-worker` does not read `OBJECT_STORAGE_*` (the reader's here): its `deploy/compose.yml` passes its own `PDF_STORAGE_*` variables, with the account `ticketing_pdf_writer`, the secret `TICKETING_PDF_WRITER_SECRET` and the bucket `TICKETS_BUCKET`, so the examples need no extra storage variable for it; its PDF job is off by default (`RENDER_TICKET_PDFS_ENABLED=false`).

**Mail catcher.** Mailpit is the profile `mail` of `csp-auth-api` and is reused, not duplicated: `env/dev.env.example` sets `COMPOSE_PROFILES=mail`, so `up` starts it (SMTP `mailpit:1025` on the platform network; messages at `http://localhost:8025`, loopback only). The service forces SMTP authentication and STARTTLS unless told otherwise, which the catcher does not offer, so development sets `TICKETING_SMTP_AUTH=false` and `TICKETING_SMTP_STARTTLS=false` (qa and main keep `true` with their provider). Requires the compose of `csp-ticketing-api` that reads them (code-corhuila/csp-ticketing-api#71).

**An environment that already exists** copies the new variables from `env/<environment>.env.example` (the block "The single object storage" and the two `TICKETING_SMTP_*` flags), and recreates `ticketing-api` once so that it reads the reader account: `docker compose --env-file env/dev.env up -d ticketing-api`.

## The API gateway

The API gateway (`csp-api-gateway`, NGINX) is included from `../csp-api-gateway/deploy/compose.yml`, so `csp-api-gateway` must be
cloned as a sibling of this repository. It is the **only application service published to the host** (port `8000`; Grafana and Prometheus bind loopback only); every other service,
and the databases, are reachable only on the `platform` network. It routes `/api/v1/<domain>/...` to the owning service and
does not validate tokens (each service does).

Its only variable is `APP_GATEWAY_CORS_ORIGIN_REGEX`, the browser origins it allows, as a regular expression that the gateway
anchors as `^...$`. In dev the example file carries the scaffold default (shell on `4200`, remotes on `4201`-`4205`); in qa and
main it is a placeholder and the real origins of the environment go there (the real env files are never versioned).

**An environment that already exists** has an env file created before the gateway, so add `APP_GATEWAY_CORS_ORIGIN_REGEX` to it
(copy the line from `env/<environment>.env.example`) before running `./scripts/up.sh`. Without it, the gateway falls back to
its development default, which allows only `localhost` origins.

## Prometheus: what it scrapes and the latency alert

`observability/prometheus.yml` has three scrape jobs: `otel-collector` (`otel-collector:8889`), `csp-auth-api`
(`auth-api:8081`, path `/metrics`, on the `platform` network) and `csp-worker-outbox` (see the next section). `csp-auth-api` exports `auth_http_requests_total{route,method,outcome}` and
`auth_http_request_duration_seconds{route,method}` (buckets 0.05, 0.1, 0.25, 0.5, 1 and 2.5 seconds). Those series exist only once a
`csp-auth-api` that serves `/metrics` is deployed; until then the target shows as down in Prometheus and the alert has no data.

`observability/alerts/auth-latency.yml` (mounted read-only into the Prometheus container, loaded by `rule_files`) holds the rule
`AuthCredentialsLatencyP95AboveSlo`: the p95 of `POST /api/v1/auth/login` or `POST /api/v1/auth/register` above 1 second for 15 minutes,
only for a route with at least 10 requests in those 15 minutes (a guard against the low traffic). Severity `ticket`, team `auth`. ADR-061 in
`csp-docs` decides it (code-corhuila/csp-docs#281).

**No Alertmanager route exists yet in this repository**: the alert is visible in Prometheus (`http://127.0.0.1:9090/alerts`) and nothing notifies anyone.

The rule has unit tests (`observability/alerts/auth-latency.test.yml`). Run them, and the checks of the configuration, with the Prometheus image
of `compose.yml` (no local installation):

```bash
docker run --rm --entrypoint promtool -v "$PWD/observability:/o:ro" -w /o prom/prometheus:v2.54.1 check rules alerts/auth-latency.yml
docker run --rm --entrypoint promtool -v "$PWD/observability:/o:ro" -w /o prom/prometheus:v2.54.1 test rules alerts/auth-latency.test.yml
docker run --rm --entrypoint promtool -v "$PWD/observability/prometheus.yml:/etc/prometheus/prometheus.yml:ro" -v "$PWD/observability/alerts:/etc/prometheus/alerts:ro" prom/prometheus:v2.54.1 check config /etc/prometheus/prometheus.yml
```

## The workflow service

`csp-workflow` orchestrates the sagas that cross domains (Norma 5.8, ADR-066) and keeps their state in schema `workflow` of this PostgreSQL
instance (ADR-065). The platform gives it four things.

- **The database.** `postgres/init/01-instance.sh` creates the login `workflow_app` (password `WORKFLOW_APP_PASSWORD`, `search_path` `workflow`) and
  the migration executor `workflow_migrator` (password `WORKFLOW_MIGRATOR_PASSWORD`), owner of the `workflow` schema, with `CREATEROLE` and `CREATE` on
  the database, the same pattern as `booking_migrator` and `auth_migrator`. No `-db` repository owns this schema: its migrations live in `db/` of
  `csp-workflow` and the tooling service `workflow-db-migrate` of that repository applies them. Migration `V003` creates `workflow_writer` and `V005` makes
  `workflow_app` a member of it, so the login must exist **before** the migration runs: that is why the init script creates it.
- **The variables.** Every one of this domain is named `WORKFLOW_*`, because `SERVICE_TOKEN` and `SPRING_DATASOURCE_*` belong to `csp-worker` and
  `csp-booking-api` in the file the services share: `WORKFLOW_DB_USER` and `WORKFLOW_DB_PASSWORD` (the executor), `WORKFLOW_APP_USER` and
  `WORKFLOW_APP_PASSWORD` (the service), and `WORKFLOW_SERVICE_TOKEN`.
- **The credential for Booking.** `WORKFLOW_SERVICE_TOKEN` has `sub` `csp-workflow`, which `WORKFLOW_SUBJECTS=csp-workflow` (set for `csp-booking-api` above) lets
  call `/internal/workflow/` and nothing else. In develop `./scripts/dev-keys.sh` writes it; in qa and main the identity service issues it and the deployment
  injects it as a secret. `./scripts/up.sh` refuses to start without it and checks its subject, as it does for the token of `csp-worker`.
- **The route.** The gateway sends `/api/v1/sagas` to `workflow:8086` (`APP_GATEWAY_WORKFLOW_UPSTREAM`); the service is not published to the host.

```bash
./scripts/dev-keys.sh                 # dev only: also WORKFLOW_SERVICE_TOKEN
./scripts/up.sh dev
docker compose --env-file env/dev.env --profile tooling run --rm workflow-db-migrate
docker compose --env-file env/dev.env up -d workflow
```

`./scripts/up.sh` already does the first and third steps in the right order (issue #59): it starts PostgreSQL and waits until it is healthy, runs `workflow-db-migrate` (a tooling service that `up` never starts by itself), and only then brings up everything else, so the service never starts before `workflow.saga` exists and needs no restart. The healthcheck of PostgreSQL is a TCP check (`pg_isready -h 127.0.0.1`) because the temporary server of the first start listens on the socket only. `./scripts/test-start-order.sh` checks that order and prints totals. The explicit commands above remain for a manual run (for example, to apply a new migration without restarting the platform).

The service refuses to start without its database, its public key or its token, so run the executor first. In an environment whose volume already exists, run
the init script once by hand so the two logins appear (every statement is idempotent), as described in "An existing environment: switch to the migrators":

```bash
docker compose --env-file env/dev.env exec -T postgres sh /docker-entrypoint-initdb.d/01-instance.sh
```

## The outbox relay metrics and alerts of csp-worker

ADR-014 asks for metrics and alerts of the outbox relay. `csp-worker` exposes no `/metrics` (Norma 5.7.1 admits only its health point, see its README), so the
metrics come from the state table of the relay: the service `postgres-exporter` of `compose.yml` connects as `worker_app` (owner of schema `worker`, no privilege on
the other schemas) and runs the two queries of `observability/postgres-exporter-queries.yaml`; its own default metrics are off. Prometheus scrapes it as the job
`csp-worker-outbox` (`postgres-exporter:9187`). It needs schema `worker` to exist (`worker-db-migrate` of `csp-worker`, before the relays are turned on); until then the
queries fail and the series do not exist. It reads no password besides `WORKER_APP_PASSWORD`, which goes in separate variables, so it needs no URL-safe value.

| Series | Labels | Meaning |
|---|---|---|
| `worker_outbox_relay_events` | `source`, `status` | Events of the outbox (`booking`, `auth`, `concessions`, `ticketing_fulfillment`) in each status: `PENDING`, `PUBLISHED`, `FAILED_PERMANENT`, `FAILED_EXHAUSTED` |
| `worker_outbox_relay_pending_overdue_seconds` | `source` | Seconds that the oldest pending event is past its next attempt; `0` when none is due |
| `worker_outbox_relay_pending_max_attempts` | `source` | Largest number of attempts of a pending event |

`observability/alerts/worker-outbox-relay.yml` holds the three alerts of ADR-014, all with severity `ticket` and `component: csp-worker`, and a fourth that is not in the ADR:

- `WorkerOutboxRelayOldestPendingAbove5m`: a pending event is more than 5 minutes past its next attempt for 1 minute, which means a relay that stopped or stalled.
- `WorkerOutboxRelayEventFailed`: any event in `FAILED_PERMANENT` or `FAILED_EXHAUSTED`; it waits for an operator and the replay is in the README of `csp-worker`.
- `WorkerOutboxRelayPendingEventRetrying`: a pending event with 10 attempts or more. Published events keep the attempts they took, so counting them would keep the alert on for ever.
- `WorkerOutboxMetricsDown`: the exporter does not answer for 5 minutes, so the other three are blind.

**Two limits.** The state table has no discovery time, so "the age of the oldest pending event" is how late its next attempt is: an event that waits for a retry is not old, and a relay that
runs keeps it at zero. And the publish latency that ADR-014 lists cannot be read from this table, because the creation time of an event lives in the outbox of its domain, which the worker only reads.
There is still **no Alertmanager route**: the alerts are visible in Prometheus and nothing notifies anyone.

The rules have unit tests (`observability/alerts/worker-outbox-relay.test.yml`), run like the ones above:

```bash
docker run --rm --entrypoint promtool -v "$PWD/observability:/o:ro" -w /o prom/prometheus:v2.54.1 check rules alerts/worker-outbox-relay.yml
docker run --rm --entrypoint promtool -v "$PWD/observability:/o:ro" -w /o prom/prometheus:v2.54.1 test rules alerts/worker-outbox-relay.test.yml
```

## One environment, one project, one volume

Annex J.5 gives each environment its own env file (`env/dev.env`, `env/qa.env`, `env/main.env`, created from the `.example` files) and fixes in it its `COMPOSE_PROJECT_NAME` (`csp-dev`, `csp-qa`, `csp-main`), so every environment has its own container and its own volume. `./scripts/up.sh dev|qa|main` and `./scripts/down.sh dev|qa|main` take the environment as a required argument: there is no default, so a script run on a qa or main host never acts on `dev` by accident. In qa and main the volume is the history of the system: `docker compose down -v` is never run and the database is backed up before migrating (J.5.4).

## Rules

- **No secret is versioned.** `env/*.example` carries names and placeholders only; `keys/` and the real `env/*.env` files are git-ignored.
- **Development keys are not the identity service.** `dev-keys.sh` exists so the system runs before the identity
  domain exists. In qa and main the public key and the service tokens come from the identity service, injected as
  secrets. The service token of `csp-worker` carries `sub` = `csp-worker`: the booking service only lets that
  subject call its internal operations, and `SERVICE_SUBJECTS=csp-worker` lets the same token call the purge operation
  of the identity service (`PURGE_AUTH_ENABLED`). The development token comes from `scripts/dev-keys.sh`; in qa and main
  it comes from the secret manager (`SERVICE_TOKEN_FILE`), because the identity service issues no service credentials.
- **One network, `platform`,** created by `scripts/up.sh`. Every repository joins it.

```bash
cp env/dev.env.example env/dev.env
./scripts/dev-keys.sh                 # develop only
./scripts/up.sh dev
./scripts/dev-token.sh <subject> [minutes]
```

## Branching

Three permanent branches. **None of them accepts a direct commit** — you enter through a child
branch and leave through a Pull Request.

```
develop  <--PR--  feat/... fix/... chore/...
qa       <--PR--  qa/...
main     <--PR--  release/...  hotfix/...
```

Promotion happens **by re-application** (`git cherry-pick -x`), never by merging one permanent
branch into another: `merge develop -> qa` and `merge qa -> main` do not exist in this model.

`main` requires **1 approval from `ariel5253`**. On `develop` and `qa` the team sets its own review
rule.

Full policy: `00-governance/branching-policy.md` in `csp-docs`.
