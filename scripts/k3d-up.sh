#!/usr/bin/env bash
# Build service images, create the k3d cluster if needed, import images, helm install.
set -euo pipefail

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing '$1'. Install with: brew install $1" >&2
    exit 1
  fi
}

need docker
need k3d
need helm
need kubectl

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Start OrbStack (or Docker Desktop), then retry." >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INFRA_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
ROOT=$(cd "$INFRA_DIR/.." && pwd)
CLUSTER=rba
TAG=dev
KUBE_CONTEXT="k3d-${CLUSTER}"

cd "$ROOT"

IGNORE_SRC="$INFRA_DIR/docker/dockerignore"
IGNORE_DST="$ROOT/.dockerignore"
copied_ignore=0
if [[ ! -f "$IGNORE_DST" ]]; then
  cp "$IGNORE_SRC" "$IGNORE_DST"
  copied_ignore=1
fi
cleanup() {
  if [[ "$copied_ignore" -eq 1 ]]; then
    rm -f "$IGNORE_DST"
  fi
}
trap cleanup EXIT

build() {
  local dockerfile=$1
  local image=$2
  echo "==> building ${image}:${TAG}"
  DOCKER_BUILDKIT=1 docker build -f "$dockerfile" -t "${image}:${TAG}" .
}

build rba-decision-service/Dockerfile rba-decision-service
build rba-idp/Dockerfile rba-idp
build rba-event-publisher/Dockerfile rba-event-publisher
build rba-profile-service/Dockerfile rba-profile-service
build rba-audit-service/Dockerfile rba-audit-service

if k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
  echo "==> cluster ${CLUSTER} already exists"
else
  echo "==> creating k3d cluster ${CLUSTER}"
  k3d cluster create --config "$INFRA_DIR/k3d/cluster.yaml"
fi

echo "==> importing images into k3d"
k3d image import \
  "rba-decision-service:${TAG}" \
  "rba-idp:${TAG}" \
  "rba-event-publisher:${TAG}" \
  "rba-profile-service:${TAG}" \
  "rba-audit-service:${TAG}" \
  -c "$CLUSTER"

echo "==> helm lint + install"
helm lint "$INFRA_DIR/helm/rba"
helm upgrade --install rba "$INFRA_DIR/helm/rba" \
  --namespace rba \
  --create-namespace \
  --kube-context "$KUBE_CONTEXT" \
  --wait \
  --timeout 5m

echo
kubectl --context "$KUBE_CONTEXT" -n rba get pods,svc,hpa,ingress
echo
echo "IdP:   http://localhost:8080/login"
echo "Admin: http://localhost:8080/admin"
echo "PDP:   kubectl --context ${KUBE_CONTEXT} -n rba port-forward svc/decision-service 8000:8000"
