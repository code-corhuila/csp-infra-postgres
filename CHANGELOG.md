# Changelog

All notable changes of `csp-infra-postgres` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each change is recorded in the pull request that introduces it.

## [Unreleased]

## [3.0.0] - 2026-10-15

### Added

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
