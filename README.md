# rba-infra

Shared **platform / local-dev** repo for the RBA polyrepo
([`github.com/roku-pfi`](https://github.com/roku-pfi)). Owns compose (now), and
later Helm / GitOps, CI templates, Prometheus / Grafana, gateway config
(`docs/plans/development_plan.md` §4.1, §9).

No application business logic lives here. Services consume URLs; they do not
run their own Redis / Postgres / RabbitMQ containers
([ADR-0010](../docs/decisions/0010-shared-local-data-plane.md)).

> Status: [`../docs/plans/status.md`](../docs/plans/status.md). AI: [`AGENTS.md`](AGENTS.md).

## What lives here vs in a service repo

| Concern | Where |
|---|---|
| Redis (online `ProfileState`) | **here** — one shared cache |
| Postgres *server* + per-service DBs | **here** — one server, many databases |
| RabbitMQ (outbox fan-out) | **here** |
| k3d / Tilt / Helm / GitOps | **here** (Phase 0 remainder — not started) |
| Decision / profile / audit / IdP *code* | respective `rba-*` repos |
| Service-owned *tables* | created by that service on startup / migrations |

**Database-per-service** means separate *databases* on one Postgres, not a
container per service. IdP users live in `rba_idp`, never in `rba_decision`.

## Layout

```
docker-compose.yml            # redis, postgres, rabbitmq + named volumes
compose/init-databases.sql    # CREATE DATABASE rba_{decision,profile,audit,idp}
```

Images: `redis:7-alpine`, `postgres:16-alpine`,
`rabbitmq:3.13-management-alpine`. Credentials for local dev: user/password
`rba` / `rba` (not for production).

`init-databases.sql` runs **once** on an empty Postgres volume. Adding a new
DB later on an existing volume requires a manual `CREATE DATABASE`.

## Local data plane

```bash
docker compose up -d
docker compose ps
```

| Service | URL / DSN |
|---|---|
| Redis | `redis://localhost:6379/0` |
| Postgres (decision) | `postgresql+psycopg://rba:rba@localhost:5432/rba_decision` |
| Postgres (profile) | `postgresql+psycopg://rba:rba@localhost:5432/rba_profile` |
| Postgres (audit) | `postgresql+psycopg://rba:rba@localhost:5432/rba_audit` |
| Postgres (idp) | `postgresql+psycopg://rba:rba@localhost:5432/rba_idp` |
| RabbitMQ AMQP | `amqp://rba:rba@localhost:5672/` |
| RabbitMQ UI | http://localhost:15672 (`rba` / `rba`) |

Healthchecks are defined for all three containers. Volumes:
`rba_redis_data`, `rba_postgres_data`, `rba_rabbitmq_data`.

Then run services from their own venvs — example PDP:

```bash
cd ../rba-decision-service && source .venv/bin/activate
REDIS_URL=redis://localhost:6379/0 \
DATABASE_URL=postgresql+psycopg://rba:rba@localhost:5432/rba_decision \
uvicorn rba_decision_service.main:app --reload --port 8000
```

Full login path: see the workspace [`../README.md`](../README.md).

> If you previously used `rba-decision-service/docker-compose.yml`, tear it
> down (`docker compose down` there) so ports 6379/5432 are free, then start
> this stack.

### Create a DB on an already-initialized volume

```bash
docker compose exec postgres \
  psql -U rba -d postgres -c "CREATE DATABASE rba_idp;"
```

## Guardrails

- Do not put application logic here.
- Do not put Redis/Postgres compose back into individual service repos.
- Never commit real secrets; local `rba`/`rba` is documented default only.

## Status

Light Phase 0 bootstrap (shared compose including RabbitMQ). Full
k3d/Tilt/Helm/CI still ahead — `../docs/plans/status.md`.
