# rba Helm chart

Umbrella chart for the **local k3d** stack: Redis / Postgres / RabbitMQ plus
the application Deployments. Install via `../../scripts/k3d-up.sh` (builds
images, imports them into k3d, then `helm upgrade --install`).

Compose (`../../docker-compose.yml`) stays the inner-loop data plane when you
are not running a cluster ([ADR-0010](../../../docs/decisions/0010-shared-local-data-plane.md),
[ADR-0020](../../../docs/decisions/0020-local-k8s-k3d-helm.md)).

| Workload | Kind | Notes |
|---|---|---|
| redis / postgres / rabbitmq | Deployment + PVC | Same images as compose; Recreate |
| decision-service | Deployment (2) + HPA | ClusterIP; `/healthz` probes |
| idp | Deployment + Ingress | Public on `localhost:8080` |
| event-publisher / profile-service / audit-service | Deployment | Workers; no HTTP probes yet |
| audit-api | Deployment | Same image as audit-service, command `rba-audit-api` |

`PUT /policy` is still in-process + per-pod YAML. Default policy from the
image is identical across replicas; a live PUT will not fan out. Shared
policy store is a follow-up.
