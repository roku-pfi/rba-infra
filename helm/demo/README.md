# demo Helm chart

Tenant banking app for **Demo-3**. Installs into namespace **`demo`**. The
platform chart (`../rba`) stays in **`rba`**.

The bank authenticates by redirecting the browser to the IdP Ingress. It must
not call `decision-service`. Presenter walkthrough: `/walkthrough` on this
Ingress (not linked from `/`).

Installed by `../../scripts/k3d-up.sh` after the platform release.
