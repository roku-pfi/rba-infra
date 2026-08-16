# rba-infra

Shared **platform / local-dev** repo for the RBA polyrepo
([`github.com/roku-pfi`](https://github.com/roku-pfi)). Owns compose, k3d,
and Helm so service repos stay application-only
(`docs/plans/development_plan.md` §4.1, §9; [ADR-0010](../docs/decisions/0010-shared-local-data-plane.md),
[ADR-0020](../docs/decisions/0020-local-k8s-k3d-helm.md)).

No application business logic lives here. Services consume URLs; they do not
run their own Redis / Postgres / RabbitMQ containers.

> Status: [`../docs/plans/status.md`](../docs/plans/status.md). AI: [`AGENTS.md`](AGENTS.md).

## What lives here vs in a service repo

| Concern | Where |
|---|---|
| Redis (online `ProfileState`) | **here** — one shared cache |
| Postgres *server* + per-service DBs | **here** — one server, many databases |
| RabbitMQ (outbox fan-out) | **here** |
| k3d / Helm | **here** (K8s-1 + K8s-2 Prometheus/Grafana) |
| Tilt / GitOps / CI templates | **here** (not started — K8s-3) |
| Decision / profile / audit / IdP *code* + Dockerfiles | respective `rba-*` repos |
| Service-owned *tables* | created by that service on startup / migrations |

**Database-per-service** means separate *databases* on one Postgres, not a
container per service. IdP users live in `rba_idp`, never in `rba_decision`.

## Layout

```
docker-compose.yml            # redis, postgres, rabbitmq + named volumes
compose/init-databases.sql    # CREATE DATABASE rba_{decision,profile,audit,idp}
docker/dockerignore           # shared polyrepo-context ignore for image builds
k3d/cluster.yaml              # k3d cluster rba, host 8080 → Traefik 80
helm/rba/                     # umbrella chart: data plane + app Deployments + Prometheus/Grafana
scripts/k3d-up.sh             # build images, import, helm install
scripts/k3d-down.sh           # k3d cluster delete
scripts/load-hpa.sh           # in-cluster load Job that should move the PDP HPA
load/evaluate_load.py         # stdlib hammer for POST /risk/evaluate
```

Images: `redis:7-alpine`, `postgres:16-alpine`,
`rabbitmq:3.13-management-alpine`. Credentials for local dev: user/password
`rba` / `rba` (not for production).

## Two local modes

| Mode | When | Command |
|---|---|---|
| **Compose + venvs** | hacking one service | `docker compose up -d` then uvicorn / CLIs |
| **k3d + Helm** | the graded cluster story | `./scripts/k3d-up.sh` |

Do not run both data planes at once — they both want 6379/5432/5672 on the
host if you also port-forward. k3d keeps datastores ClusterIP (no host bind)
except the IdP Ingress on **8080**.

## Kubernetes (K8s-1 + K8s-2)

Needs Docker or OrbStack running, plus:

```bash
brew install k3d helm   # kubectl is usually already present
./scripts/k3d-up.sh
```

That builds images from the polyrepo root (sibling `rba-*` checkouts),
creates cluster `rba` if missing, imports images, and
`helm upgrade --install rba ./helm/rba -n rba`.

| URL | What |
|---|---|
| http://localhost:8080/login | Hosted IdP login |
| http://localhost:8080/admin | Admin console |
| http://localhost:8080/grafana | Grafana (admin/admin; anonymous Viewer). Dashboard **RBA / RBA PDP** |

PDP is ClusterIP only (`decision-service:8000` inside the cluster). To curl
it from the laptop:

```bash
kubectl --context k3d-rba -n rba port-forward svc/decision-service 8000:8000
```

Tear down: `./scripts/k3d-down.sh` (does not delete built images).

`decision-service` runs **2 replicas** with an HPA (min 2 / max 5, CPU 70%).
`PUT /policy` is still per-pod; default image policy matches across replicas.

Move the HPA (needs the cluster already up):

```bash
./scripts/load-hpa.sh
```

That Job POSTs `/risk/evaluate` until `currentReplicas` rises. Watch it on the
Grafana **PDP HPA replicas** panel. Scale-down waits ~5 minutes after load
stops.

## Local data plane (compose)

```bash
docker compose up -d
docker compose ps
```

`init-databases.sql` runs **once** on an empty Postgres volume. Adding a new
DB later on an existing volume requires a manual `CREATE DATABASE`.

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
- Dockerfiles belong in service repos; Helm stays here.
- Never commit real secrets; local `rba`/`rba` is documented default only.

## Status

K8s-1 (k3d + Helm) and K8s-2 (Prometheus / Grafana + HPA load) are done.
Compose still supported. Tilt / GitOps / CI templates still ahead — `../docs/plans/status.md`.
