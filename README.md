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
scripts/dev-keys.sh            DEVELOPMENT ONLY: RS256 key pair in keys/ (git-ignored), JWT_PUBLIC_KEY, SERVICE_TOKEN and APP_AUTH_JWT_PRIVATE_KEY in env/dev.env
scripts/dev-token.sh           DEVELOPMENT ONLY: prints a signed token for a subject, with `iss` csp-auth and `aud` csp-internal (ADR-056)
```

## Repositories are cloned as siblings

The `include` paths of `compose.yml` assume that every repository is cloned next to this one, in a folder named as the repository (`csp-booking-db`, `csp-booking-api`, `csp-auth-db`, `csp-auth-api`, `csp-worker`, `csp-infra-mongo`, `csp-catalog-db`, `csp-catalog-api`, `csp-infra-redis`, `csp-api-gateway`). A missing
sibling fails loudly on `up`: nothing is silently skipped.

## The booking slice

`compose.yml` runs the single PostgreSQL instance of the environment (Annex J) and includes `csp-booking-db`,
`csp-booking-api` and `csp-worker`. The migration executor of a `-db` repository is a tooling service: it does
not start with `up`, it is run once per environment and again whenever a migration is added.

```bash
cp env/dev.env.example env/dev.env  # set PG_ADMIN_PASSWORD, BOOKING_APP_PASSWORD, BOOKING_MIGRATOR_PASSWORD and WORKER_APP_PASSWORD
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
Booking calls it by name with its service credential (`http://catalog-api:8082/api/v1/catalog`). It logs in to MongoDB as `catalog_app`, so
`CATALOG_APP_PASSWORD` is required, and it validates tokens with the same `JWT_PUBLIC_KEY` as the other services. `SERVICE_SUBJECTS`
of the platform belongs to `csp-worker`; the subjects the catalog accepts on its availability route come from the optional
`CATALOG_SERVICE_SUBJECTS` (default `booking-service`). Run the migration executor before starting the service, so that
`catalog_app` already holds `catalog_writer`:

```bash
docker compose --env-file env/dev.env --profile tooling run --rm catalog-db-migrate
docker compose --env-file env/dev.env up -d --build catalog-api
```

## The SMTP relay of the identity service

`csp-auth-api` sends the verification code of the email change through an SMTP relay (ADR-034). Its six variables
(`APP_AUTH_SMTP_HOST`, `_PORT`, `_USER`, `_PASSWORD`, `_FROM`, `_TLS`) live in the same `env/<environment>.env` and reach the
service through its own `deploy/compose.yml`. Without a host the two email-change routes answer `404`. In development the
example points to the Mailpit catcher of `csp-auth-api` (`docker compose --profile mail up mailpit`); in qa and main the six
values are injected as environment secrets and the example files only carry the empty placeholders; the real env files are never
versioned. An existing environment copies the block from `env/<environment>.env.example` before the next `./scripts/up.sh`.

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

`observability/prometheus.yml` has two scrape jobs: `otel-collector` (`otel-collector:8889`) and `csp-auth-api`
(`auth-api:8081`, path `/metrics`, on the `platform` network). `csp-auth-api` exports `auth_http_requests_total{route,method,outcome}` and
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
