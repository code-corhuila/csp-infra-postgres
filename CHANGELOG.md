# Changelog

All notable changes of `csp-infra-postgres` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each change is recorded in the pull request that introduces it.

## [Unreleased]

## [3.0.0] - 2026-10-15

### Fixed

- The development env example turns on the `csp-worker` jobs that complete a purchase (HU-TICKETING-002, ADR-014, ADR-057, ADR-058): `OUTBOX_RELAY_ENABLED`, `RENDER_TICKET_PDFS_ENABLED`, `HOLD_EXPIRY_WARNINGS_ENABLED`, `CONCESSIONS_OUTBOX_RELAY_ENABLED` and `CONCESSIONS_EVENTS_ENABLED` are `true`, and the new `DISPATCH_TICKET_EMAILS_ENABLED=true` sends the ticket email. With the booking relay off a reservation was confirmed but its events stayed in the outbox, so the ticket was never issued. `qa.env.example` and `main.env.example` are not changed: turning those jobs on in those environments is an environment decision.
- `TICKETING_PORTAL_URL` of the three env examples is the address of the shell (`http://localhost:4200`) instead of the standalone ticketing portal (`4205`): the ticket email links to `<url>/dashboard/tickets` and only the shell holds the session of the person (HU-TICKETING-002, ADR-058).
- `./scripts/up.sh` runs the migration executor of every domain (code-corhuila/csp-infra-postgres#63, HU-TICKETING-002): `booking-db-migrate`, `auth-db-migrate`, `ticketing-db-migrate`, `worker-db-migrate` and `workflow-db-migrate` after PostgreSQL is healthy, and `catalog-db-migrate` after MongoDB is, all before `up -d --build`. Before this only the one of `csp-workflow` ran, and an environment brought up from scratch or after a pull that adds a migration started the services against missing or old schemas. Every migration is idempotent. `scripts/test-start-order.sh` checks the order.
- `csp-workflow` no longer stops when it starts before its migration (code-corhuila/csp-infra-postgres#59): `workflow-db-migrate` is in the `tooling` profile, so `./scripts/up.sh` (`up -d --build` only) never ran it and the service started without `workflow.saga`. `up.sh` now runs `up -d --wait postgres`, then the migration with `FLYWAY_CONNECT_RETRIES=10`, then the full `up`. The healthcheck of `postgres` in `compose.yml` is now a TCP check (`pg_isready -h 127.0.0.1`), because on an empty volume the temporary init server listens on the socket only and the container could be healthy before the logins exist. `scripts/test-start-order.sh` checks the order and prints totals; the README says so. No change in `csp-workflow`.

### Added

- The three env examples list the `csp-worker` variables of Concessions that the platform passes and the examples lacked (HU-CONCESSIONS-004): `CONCESSIONS_OUTBOX_RELAY_ENABLED` and `CONCESSIONS_EVENTS_ENABLED`, both `false`, and `CONCESSIONS_AMQP_URL`, built from `CONCESSIONS_PASSWORD`. Found by running the platform end to end.
- The platform composes Concessions (HU-CONCESSIONS-004, ADR-069): `compose.yml` includes `../csp-concessions-db/deploy/compose.yml` and `../csp-concessions-api/deploy/compose.yml` and gives the PostgreSQL container `CONCESSIONS_APP_PASSWORD` and `CONCESSIONS_MIGRATOR_PASSWORD`; `postgres/init/01-instance.sh` creates the login `concessions_app` (`search_path` `concessions`) and the migration executor `concessions_migrator`, and `scripts/up.sh` runs `concessions-db-migrate`. The three `env/*.env.example` files list `CONCESSIONS_APP_PASSWORD`, `CONCESSIONS_MIGRATOR_PASSWORD`, `CONCESSIONS_DB_USER`, `CONCESSIONS_DB_PASSWORD` and `CONCESSIONS_APP_USER`; `WORKFLOW_SUBJECTS=csp-workflow` was already there. The README has a section for the service. Requires the compose files of `csp-concessions-db` and `csp-concessions-api` that read those names.

- The development environment example enables the Auth outbox relay now that the platform composition includes Ticketing and its Auth-event queues (code-corhuila/csp-auth-api#108).
- The three env examples list the `csp-worker` variables that the platform already passes and the examples lacked (code-corhuila/csp-infra-postgres#65, HU-TICKETING-005): `HOLD_EXPIRY_WARNINGS_ENABLED` (`false`) and `HOLD_EXPIRY_WARNINGS_EVERY` (`30`), `OUTBOX_RELAY_ENABLED` (`false`) and `OUTBOX_RELAY_EVERY` (`5`) of the Booking relay, which needs schema `worker` migrated and `RELAY_AMQP_URL` (said in a comment), and `RENDER_TICKET_PDFS_ENABLED` (`false`). The worker writes the ticket PDFs from its own `PDF_STORAGE_*` variables, wired in its compose from `TICKETING_PDF_WRITER_SECRET` and `TICKETS_BUCKET`, so the reader account `OBJECT_STORAGE_*` of `csp-ticketing-api` is not reused. The README no longer calls that wiring a follow-up.
- The platform composes the object storage of the ticket PDFs and a mail catcher (code-corhuila/csp-infra-postgres#58, ADR-058): `compose.yml` includes `../csp-infra-rustfs/compose.yml` (RustFS on the `platform` network, bucket `tickets`, `ticketing_pdf_reader` for `csp-ticketing-api` and `ticketing_pdf_writer` for `csp-worker`); `scripts/up.sh` runs its idempotent setup job after `up` and refuses to start without the root account and the two secrets; the three `env/*.env.example` files list the storage block (names and placeholders only), set `OBJECT_STORAGE_ACCESS_KEY=ticketing_pdf_reader` and `OBJECT_STORAGE_SECRET_KEY=${TICKETING_PDF_READER_SECRET}`, and add `TICKETING_SMTP_AUTH` and `TICKETING_SMTP_STARTTLS` (`false` in development, `true` in qa and main). `env/dev.env.example` also sets `COMPOSE_PROFILES=mail`, so the Mailpit of `csp-auth-api` starts with the platform instead of being duplicated here. Requires the compose of `csp-ticketing-api` that reads the two SMTP flags (code-corhuila/csp-ticketing-api#71). An environment created before this change copies the new variables into its env file.
- The platform composes Ticketing (code-corhuila/csp-infra-postgres#41): `compose.yml` includes `../csp-ticketing-db/deploy/compose.yml` and `../csp-ticketing-api/deploy/compose.yml` and gives the PostgreSQL container `TICKETING_APP_PASSWORD` and `TICKETING_MIGRATOR_PASSWORD`; `postgres/init/01-instance.sh` creates the login `ticketing_app` (`search_path` `ticketing_fulfillment`) and the executor `ticketing_migrator`, for which `migrator()` now takes an optional prefix because the schema `ticketing_fulfillment` and the roles `ticketing_*` differ; the three `env/*.env.example` files list the Ticketing variables (names and placeholders only) and the README has a section. Requires the compose of `csp-ticketing-api` that reads domain variables and V010 of `csp-ticketing-db` (it grants `ticketing_writer` to `ticketing_app`; without it every request that touches the database fails with `permission denied for schema ticketing_fulfillment`). An environment created before this change has to copy the new block into its env file and run the init script once.
- TLS to the catalog API (code-corhuila/csp-docs#289 criterion 2, ADR-067): `scripts/internal-ca.sh dev|qa|main` creates the internal CA of the environment (`csp-internal-ca`, RSA 3072, 1 year) and the certificate of Catalog (90 days, names `catalog-api` and `localhost`, chain PEM) in the git-ignored `keys/tls/<environment>/`, keeps the CA key out of every container, and writes `CATALOG_TLS_CERTIFICATE_HOST_FILE`, `CATALOG_TLS_PRIVATE_KEY_HOST_FILE` and `CATALOG_TLS_CA_HOST_FILE` into the env file. The three `env/*.env.example` files state `CATALOG_BASE_URL=https://catalog-api:8082/api/v1/catalog`, `APP_GATEWAY_CATALOG_UPSTREAM=https://catalog-api:8082`, the three container paths (`/run/tls/...`) and the host files; `dev-keys.sh` runs the script for dev and `up.sh` refuses to start without the three files. `scripts/test-internal-ca.sh` checks all of it (SAN, chain, validity, cross-environment rejection, env examples) and prints totals. The README says what each service repository mounts and how to renew every 90 days. Requires the matching changes of `csp-catalog-api`, `csp-api-gateway` and `csp-booking-api`; an environment created before this change copies the new block into its env file.

- The platform composes `csp-workflow` (code-corhuila/csp-workflow#1, ADR-065, ADR-066): `compose.yml` includes `../csp-workflow/deploy/compose.yml` and gives the PostgreSQL container `WORKFLOW_APP_PASSWORD` and `WORKFLOW_MIGRATOR_PASSWORD`; `postgres/init/01-instance.sh` creates the login `workflow_app` (`search_path` `workflow`) and the migration executor `workflow_migrator`, owner of the `workflow` schema, with the same call `migrator workflow` as the other domains. The three `env/*.env.example` files list `WORKFLOW_APP_PASSWORD`, `WORKFLOW_MIGRATOR_PASSWORD`, `WORKFLOW_DB_USER`, `WORKFLOW_DB_PASSWORD`, `WORKFLOW_APP_USER` and `WORKFLOW_SERVICE_TOKEN` (`WORKFLOW_SUBJECTS=csp-workflow` was already there). `scripts/dev-keys.sh` writes `WORKFLOW_SERVICE_TOKEN` (`sub` `csp-workflow`), and `scripts/up.sh` refuses to start without it and checks its subject, with the check of the token of `csp-worker` now a function used twice. The route `/api/v1/sagas` is the one of `csp-api-gateway#34`; the README has a section for the service.
- The metrics and the alerts of the outbox relay of `csp-worker` (ADR-014, `code-corhuila/csp-worker#25`): the service `postgres-exporter` reads `worker.outbox_relay_state` as `worker_outbox_relay_events`,
  `worker_outbox_relay_pending_overdue_seconds` and `worker_outbox_relay_pending_max_attempts`; Prometheus scrapes it as `csp-worker-outbox` and loads `observability/alerts/worker-outbox-relay.yml`
  (oldest pending event more than 5 minutes past its next attempt, any event failed for good, a pending event with 10 attempts, and the exporter down) with `promtool` tests. There is no `/metrics` in the worker
  (Norma 5.7.1). Limits: no discovery time in the state table, so the age is the lateness of the next attempt, and no publish latency. No Alertmanager route yet.
- The platform gives `csp-booking-api` its service-only settings (`code-corhuila/csp-infra-postgres#48`, `code-corhuila/csp-booking-api#69`): `WORKFLOW_SUBJECTS=csp-workflow`,
  `CATALOG_BASE_URL`, `CATALOG_SERVICE_TOKEN_FILE` and `CATALOG_SERVICE_TOKEN_HOST_FILE` in the three `env/*.env.example` files, `SERVICE_SUBJECTS` documented as shared with Booking,
  `./scripts/dev-keys.sh` writes `keys/booking-service.token` (sub `booking-service`) and the path of that file, `./scripts/up.sh` refuses to start without it, and a README paragraph.
  Requires the compose of `csp-booking-api` that passes `SERVICE_SUBJECTS` and `WORKFLOW_SUBJECTS` (`code-corhuila/csp-booking-api#75`). An environment created before this change has
  to copy the new block into its env file.
- `APP_AUTH_REGISTRATION_CONFIRM_URL` in `env/dev.env.example` (`http://localhost:4200/auth/confirm-registration`), `env/qa.env.example` and `env/main.env.example` (empty, to be set to the
  address of the shell of the environment followed by `/auth/confirm-registration`), with a paragraph in the README: since `csp-auth-api` records a registration request and creates
  the account when the owner opens the link (code-corhuila/csp-docs#282, ADR-062), an environment without it cannot confirm any registration. An existing environment copies the
  variable before the next `./scripts/up.sh`.
- Composition of the RabbitMQ broker: `include` of `csp-infra-rabbitmq` in `compose.yml` (the service `rabbitmq` on the `platform` network, not published), the
  passwords of its logins (`RABBIT_ADMIN_PASSWORD`, `WORKER_RELAY_PASSWORD`, `TICKETING_FULFILLMENT_PASSWORD`, `CONCESSIONS_PASSWORD`) and `RELAY_AMQP_URL`
  in the three `env/*.env.example` files, and a README section with the start-up order. `AUTH_OUTBOX_RELAY_ENABLED` is listed as `false` until the consumers of
  Ticketing are composed. An environment created before this change has to copy the new block into its env file.
- `APP_AUTH_PASSWORD_RESET_URL` in `env/dev.env.example` (`http://localhost:4200/auth/reset-password`), `env/qa.env.example` and `env/main.env.example` (empty, to be set to the
  address of the shell of the environment followed by `/auth/reset-password`), with a paragraph in the README: `csp-auth-api` reads it to enable the password reset
  routes (ADR-050), and an environment copied from the examples without it answered `404` on `POST /forgot-password` and `POST /reset-password`. Found when running the
  `release/3.0.0` branches together. Refs code-corhuila/csp-docs#186.
- Prometheus scrapes `csp-auth-api` (`auth-api:8081`, `/metrics`) and loads the rule `AuthCredentialsLatencyP95AboveSlo`
  (`observability/alerts/auth-latency.yml`, mounted read-only in `compose.yml`): p95 of login or register above 1 second for 15 minutes, with a guard
  of at least 10 requests in those 15 minutes. It has promtool unit tests and a README section; no Alertmanager route exists yet, so it only shows in
  Prometheus. Refs code-corhuila/csp-docs#281 (technical issue #36).
- Development mail relay: `scripts/mailpit-relay.sh` renders `env/mailpit-relay.yml` (git-ignored) from the new `MAILPIT_RELAY_*` variables of `env/dev.env`
  (host, port, STARTTLS, user, password and the regular expression of the recipients to relay), for the profile `mail-relay` of `csp-auth-api`: Mailpit
  stores every message and also relays the matching ones to a real SMTP provider, so an expired key only fails the relay. A provider that is
  unreachable or slow keeps Mailpit waiting inside the SMTP session and the synchronous email change answers `500`, while the password reset is
  not affected (measured, table in the README). README section and variables in `env/dev.env.example`.
- Composition of the catalog: `include` of `csp-catalog-db` and `csp-catalog-api` in `compose.yml` (the service `catalog-api` on port `8082`, not
  published), and a README section (sibling checkout, `CATALOG_APP_PASSWORD`, the optional `CATALOG_SERVICE_SUBJECTS`, migrate before starting).
  `csp-infra-mongo` already includes the executor of `csp-catalog-db`, so that include is declared twice with the same file.

### Changed

- `scripts/dev-token.sh` adds `iss` `csp-auth` and `aud` `csp-internal` to the `sub`, `iat` and `exp` it already wrote (ADR-056), so the development
  service credentials carry the claims that `csp-auth-api` requires. `scripts/dev-keys.sh` gets them through it.
- qa: `PURGE_AUTH_ENABLED` is `true` in `env/qa.env.example`. The service token of `csp-worker` is loaded as an environment secret of qa (ADR-030, ADR-020); `main` stays `false` until it has its own key pair.
- The three `env/*.env.example` files follow the catalog migrator of `csp-infra-mongo` (code-corhuila/csp-infra-mongo#9): `CATALOG_DB_USER=catalog_migrator`
  (the owner of `catalog_db`, used by the executor of `csp-catalog-db`) and the new `CATALOG_APP_PASSWORD` of `catalog_app`, the login of
  `csp-catalog-api`, which has no role of its own until `csp-catalog-db` grants `catalog_writer`. Without the variable the Mongo compose
  refuses to start. An existing environment switches by hand, in the order of the README of `csp-infra-mongo`.

### Added

- The SMTP relay of `csp-auth-api` in the three `env/*.env.example` files (`APP_AUTH_SMTP_*`: the Mailpit catcher in development, empty
  placeholders for the secrets of qa and main) and a README section, so the platform passes them to the email change of HU-AUTH-004 (ADR-034).
- README: the steps of an existing environment to switch to the migrators, in the order that was rehearsed (code-corhuila/csp-infra-postgres#20): back up first
  (`pg_dump` and the roles, as a restore into a new instance needs both), define the migrator passwords above the `BOOKING_DB_*` and `AUTH_DB_*` lines (Compose
  expands `${...}` in file order), recreate `postgres`, run `01-instance.sh` once, check the owners, then switch the executors.
- Login `auth_migrator` for the migration executor of `csp-auth-db` (pattern `<domain>_migrator`, code-corhuila/csp-infra-postgres#18),
  the second domain after `booking_migrator`: `AUTH_MIGRATOR_PASSWORD` in `compose.yml` and the three `env/*.env.example` files, where
  `AUTH_DB_USER` and `AUTH_DB_PASSWORD` now point to it instead of the administrator. `postgres/init/01-instance.sh` keeps the bootstrap
  of a migrator in one function, `migrator()`, called once per domain.
- Login `booking_migrator` for the migration executor of `csp-booking-db` (pattern `<domain>_migrator`, code-corhuila/csp-infra-postgres#16):
  `postgres/init/01-instance.sh` creates it idempotently with `CREATEROLE`, makes it owner of the `booking` schema, moves the existing tables
  and control table to it and gives it the admin option on the booking roles; `BOOKING_MIGRATOR_PASSWORD` in `compose.yml` and the three
  `env/*.env.example` files, where `BOOKING_DB_USER` and `BOOKING_DB_PASSWORD` now point to it instead of the administrator. Auth follows in
  its own change.
- Purge of the identity service in the platform environment: `SERVICE_SUBJECTS` (read by `csp-auth-api`) and `PURGE_AUTH_ENABLED`
  (read by `csp-worker`) in the three `env/*.env.example` files (enabled in dev, off in qa and main until the secret manager
  provides the service token) and the README note on the service token.
- Composition of the API gateway: `include` of `csp-api-gateway` in `compose.yml` (the only service published to the host, port
  `8000`), the `APP_GATEWAY_CORS_ORIGIN_REGEX` variable in the three `env/*.env.example` files and the README section (sibling
  checkout, CORS variable, step for an existing environment).
- Composition of the Redis instance: `include` of `csp-infra-redis` in `compose.yml`, the Redis variables
  (`REDIS_ADMIN_PASSWORD`, `AUTH_REDIS_PASSWORD`, `APP_AUTH_REDIS_URL`) in the three `env/*.env.example` files and the README steps
  (sibling checkout, order, variables to add to an existing environment).
- Composition of the auth service: `include` of `csp-auth-db` (migration executor `auth-db-migrate`) and `csp-auth-api`, the login
  `auth_app` with `search_path = auth` in `postgres/init/01-instance.sh`, the auth variables in the three `env/*.env.example`
  files, the development signing key written by `scripts/dev-keys.sh`, and the README steps (migrate before starting auth).
  ([#8](https://github.com/code-corhuila/csp-infra-postgres/issues/8), [#9](https://github.com/code-corhuila/csp-infra-postgres/pull/9))
- This changelog.

### Changed

- `scripts/dev-token.sh` adds `iss` `csp-auth` and `aud` `csp-internal` to the `sub`, `iat` and `exp` it already wrote (ADR-056), so the development
  service credentials carry the claims that `csp-auth-api` requires. `scripts/dev-keys.sh` gets them through it.
- qa: `PURGE_AUTH_ENABLED` is `true` in `env/qa.env.example`. The service token of `csp-worker` is loaded as an environment secret of qa (ADR-030, ADR-020); `main` stays `false` until it has its own key pair.
- The three `env/*.env.example` files follow the catalog migrator of `csp-infra-mongo` (code-corhuila/csp-infra-mongo#9): `CATALOG_DB_USER=catalog_migrator`
  (the owner of `catalog_db`, used by the executor of `csp-catalog-db`) and the new `CATALOG_APP_PASSWORD` of `catalog_app`, the login of
  `csp-catalog-api`, which has no role of its own until `csp-catalog-db` grants `catalog_writer`. Without the variable the Mongo compose
  refuses to start. An existing environment switches by hand, in the order of the README of `csp-infra-mongo`.
- The "URL-safe" note of the env examples sits above `AUTH_APP_PASSWORD`, the password that goes inside
  `APP_AUTH_DATABASE_URL`, and the README documents the auth signing key as a secret.
  ([#10](https://github.com/code-corhuila/csp-infra-postgres/pull/10))

## Before the changelog

- Composition of the MongoDB instance in the root composition.
  ([#5](https://github.com/code-corhuila/csp-infra-postgres/pull/5))
- `up.sh` and `down.sh` require the environment instead of defaulting to `dev`.
  ([#6](https://github.com/code-corhuila/csp-infra-postgres/pull/6))
- Env files and Compose projects named as Annex J asks.
  ([#3](https://github.com/code-corhuila/csp-infra-postgres/pull/3))
- Single PostgreSQL instance, composition of the booking slice and scaffold of the platform.
  ([#1](https://github.com/code-corhuila/csp-infra-postgres/pull/1))
- Promotions to `qa`: [#2](https://github.com/code-corhuila/csp-infra-postgres/pull/2),
  [#4](https://github.com/code-corhuila/csp-infra-postgres/pull/4) and
  [#7](https://github.com/code-corhuila/csp-infra-postgres/pull/7).
