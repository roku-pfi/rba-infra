# demo Helm chart

Tenant banking app for **Demo-2**. Installs into namespace **`demo`**. The
platform chart (`../rba`) stays in **`rba`**.

The bank authenticates by redirecting the browser to the IdP Ingress. It must
not call `decision-service`.

Installed by `../../scripts/k3d-up.sh` after the platform release.
