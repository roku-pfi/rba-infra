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
| decision-service | Deployment (2) + HPA | ClusterIP; `/healthz` + `/metrics`; HPA min 2 / max 5 |
| idp | Deployment + Ingress | Public on `localhost:8080` |
| demo-banking | separate chart, ns `demo` | Host `demo.localhost:8080`; authenticates via IdP |
| event-publisher / profile-service / audit-service | Deployment | Workers; no HTTP probes yet |
| audit-api | Deployment | Same image as audit-service, command `rba-audit-api` |
| prometheus / grafana / kube-state-metrics | Deployment | K8s-2; Grafana Ingress `/grafana` |

Tenant policies live in Postgres (`rba_decision.tenant_policies`, ADR-0033):
every PDP replica reads the same rows and caches them for
`POLICY_CACHE_SECONDS` (5 s), so `PUT /tenants/{tenant_id}/policy` reaches all
replicas within that window and survives restarts. The image's
`config/policies/*.yaml` only seed tenants that have no row yet.

Grafana: http://localhost:8080/grafana (`admin` / `admin`). Provisioned dashboard
**RBA / RBA PDP** (decision mix, score heatmap, p95/p99, HPA replicas). Load the
HPA with `../../scripts/load-hpa.sh`. When the HPA is enabled the Deployment
omits `spec.replicas` so Helm does not fight the scale subresource.
