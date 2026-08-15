# AGENTS.md — rba-infra

Shared **infrastructure / local-dev** repo for a risk-based authentication (RBA)
thesis project. Owns the platform plane (compose today; Helm/GitOps/CI later) so
service repos stay application-only. Portable orientation for any AI coding tool.

## Where we are / where things are stated

**Polyrepo** (org `github.com/roku-pfi`), siblings cloned side-by-side. Roadmap /
status / decisions live in the **`docs`** repo (`../docs`):

- **Current status → `../docs/plans/status.md`**
- Phase rationale → `../docs/plans/development_plan.md` §4, §8–9
- Narrative → `../docs/devlog.md`

## Layout

```
docker-compose.yml          # Redis + Postgres (shared local data plane)
compose/init-databases.sql  # per-service DBs on first boot
README.md
```

## Guardrails

- Do **not** put application business logic here.
- Do **not** put Redis/Postgres compose back into individual service repos —
  services consume URLs from this stack.
- Database-per-service = separate *databases* (and later schemas/migrations),
  not a separate Postgres container per service on a laptop.
- IdP users/apps live in `rba_idp` — never in `rba_decision`.
- Only commit when explicitly asked; Conventional Commits; never commit secrets.

## Setup

```bash
docker compose up -d
```
