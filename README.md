# rba-infra

Shared **platform / local-dev** repo for the RBA polyrepo
([`github.com/roku-pfi`](https://github.com/roku-pfi)). Owns compose (now), and
later Helm/GitOps, CI templates, Prometheus/Grafana, gateway config
(`docs/plans/development_plan.md` §4.1, §9).

## What lives here vs in a service repo

| Concern | Where |
|---|---|
| Redis (online profiles) | **here** — shared cache |
| Postgres *server* + per-service DBs | **here** — one server, many DBs |
| RabbitMQ (Phase 4+) | **here** (when added) |
| k3d/Tilt/Helm/GitOps | **here** (Phase 0 remainder) |
| Decision / profile / audit / IdP *application* code | respective `rba-*` repos |
| Service-owned *schema* (tables) | created by that service on startup / migrations |

## Local data plane (Phase 0 light)

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
| RabbitMQ UI | http://localhost:15672 (rba / rba) |

Then run decision-service from its venv (no compose in that repo):

```bash
cd ../rba-decision-service && source .venv/bin/activate
REDIS_URL=redis://localhost:6379/0 \
DATABASE_URL=postgresql+psycopg://rba:rba@localhost:5432/rba_decision \
uvicorn rba_decision_service.main:app --reload --port 8000
```

> If you previously used `rba-decision-service/docker-compose.yml`, tear it down
> (`docker compose down` there) so ports 6379/5432 are free, then start this stack.

## Status

Light Phase 0 bootstrap (shared compose). Full k3d/Tilt/Helm still ahead — see
`../docs/plans/status.md`.
