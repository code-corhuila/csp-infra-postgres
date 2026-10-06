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
scripts/dev-keys.sh            DEVELOPMENT ONLY: RS256 key pair in keys/ (git-ignored), JWT_PUBLIC_KEY and SERVICE_TOKEN in env/dev.env
scripts/dev-token.sh           DEVELOPMENT ONLY: prints a signed token for a subject
```

## Repositories are cloned as siblings

The `include` paths of `compose.yml` assume that every repository is cloned next to this one, in a folder named as the repository (`csp-booking-db`, `csp-booking-api`, `csp-worker`). A missing
sibling fails loudly on `up`: nothing is silently skipped.

## The booking slice

`compose.yml` runs the single PostgreSQL instance of the environment (Annex J) and includes `csp-booking-db`,
`csp-booking-api` and `csp-worker`. The migration executor of a `-db` repository is a tooling service: it does
not start with `up`, it is run once per environment and again whenever a migration is added.

```bash
cp env/dev.env.example env/dev.env  # set PG_ADMIN_PASSWORD, BOOKING_APP_PASSWORD and WORKER_APP_PASSWORD
./scripts/dev-keys.sh                 # dev only: JWT_PUBLIC_KEY and the SERVICE_TOKEN of csp-worker
./scripts/up.sh dev
docker compose --env-file env/dev.env run --rm booking-db-migrate
```

Until the schema is migrated, `GET /health/ready` of the booking service answers `503` and the worker logs the
failed sweep with its correlation id; the next sweep works. Then `csp-worker` calls the expiration operation of
`csp-booking-api` every minute with its service token.

## One environment, one project, one volume

Annex J.5 gives each environment its own env file (`env/dev.env`, `env/qa.env`, `env/main.env`, created from the `.example` files) and fixes in it its `COMPOSE_PROJECT_NAME` (`csp-dev`, `csp-qa`, `csp-main`), so every environment has its own container and its own volume. `./scripts/up.sh dev|qa|main` and `./scripts/down.sh dev|qa|main` take the environment as a required argument: there is no default, so a script run on a qa or main host never acts on `dev` by accident. In qa and main the volume is the history of the system: `docker compose down -v` is never run and the database is backed up before migrating (J.5.4).

## Rules

- **No secret is versioned.** `env/*.example` carries names and placeholders only; `keys/` and the real `env/*.env` files are git-ignored.
- **Development keys are not the identity service.** `dev-keys.sh` exists so the system runs before the identity
  domain exists. In qa and main the public key and the service tokens come from the identity service, injected as
  secrets. The service token of `csp-worker` carries `sub` = `csp-worker`: the booking service only lets that
  subject call its internal operations.
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
