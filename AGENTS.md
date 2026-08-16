# AGENTS.md — rba-infra

Shared **infrastructure / local-dev** repo for a risk-based authentication (RBA)
thesis project. Owns the platform plane (compose + k3d/Helm) so service repos
stay application-only. Portable orientation for any AI coding tool.

## Where we are / where things are stated

**Polyrepo** (org `github.com/roku-pfi`), siblings cloned side-by-side. Roadmap /
status / decisions live in the **`docs`** repo (`../docs`):

- **Current status → `../docs/plans/status.md`**
- Phase rationale → `../docs/plans/development_plan.md` §4, §8–9
- Narrative → `../docs/devlog.md`
- Local k8s decision → `../docs/decisions/0020-local-k8s-k3d-helm.md`

## Layout

```
docker-compose.yml          # Redis + Postgres + RabbitMQ (no-cluster inner loop)
compose/init-databases.sql  # per-service DBs on first boot
k3d/cluster.yaml            # local cluster (host 8080 → Traefik 80)
helm/rba/                   # umbrella chart (apps + Prometheus/Grafana)
scripts/k3d-up.sh           # build, import, helm install
scripts/k3d-down.sh
scripts/load-hpa.sh         # K8s-2: load Job that should move the PDP HPA
load/evaluate_load.py
README.md
```

## Guardrails

- Do **not** put application business logic here.
- Do **not** put Redis/Postgres compose back into individual service repos —
  services consume URLs from this stack.
- Database-per-service = separate *databases* (and later schemas/migrations),
  not a separate Postgres container per service on a laptop.
- IdP users/apps live in `rba_idp` — never in `rba_decision`.
- Dockerfiles live in service repos; Helm/k3d stay here.
- Only commit when explicitly asked; Conventional Commits; never commit secrets.

## Setup

```bash
# Inner loop (no cluster)
docker compose up -d

# Graded k8s story (needs k3d + helm + Docker/OrbStack)
./scripts/k3d-up.sh
./scripts/load-hpa.sh   # optional: scale the PDP HPA
```
