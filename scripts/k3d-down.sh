#!/usr/bin/env bash
# Tear down the local k3d cluster. Does not delete built Docker images.
set -euo pipefail

CLUSTER=rba

if ! command -v k3d >/dev/null 2>&1; then
  echo "missing 'k3d'. Install with: brew install k3d" >&2
  exit 1
fi

if k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
  k3d cluster delete "$CLUSTER"
else
  echo "cluster ${CLUSTER} is not present"
fi
