#!/usr/bin/env bash
# Hammer POST /risk/evaluate until the decision-service HPA adds a replica.
# Requires an already-running k3d cluster (scripts/k3d-up.sh).
set -euo pipefail

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing '$1'." >&2
    exit 1
  fi
}

need kubectl
need docker
need k3d

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INFRA_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
CLUSTER=rba
KUBE_CONTEXT="k3d-${CLUSTER}"
NS=rba
JOB=pdp-load
DURATION="${DURATION_SECONDS:-180}"
WORKERS="${WORKERS:-24}"
WAIT_EXTRA="${WAIT_EXTRA_SECONDS:-60}"

if ! k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
  echo "cluster ${CLUSTER} is not running. Start it with: ${INFRA_DIR}/scripts/k3d-up.sh" >&2
  exit 1
fi

kubectl --context "$KUBE_CONTEXT" -n "$NS" get deploy decision-service >/dev/null
kubectl --context "$KUBE_CONTEXT" -n "$NS" get hpa decision-service >/dev/null

echo "==> importing python:3.12-slim into k3d (load Job image)"
docker pull python:3.12-slim
k3d image import python:3.12-slim -c "$CLUSTER"

echo "==> recording HPA before load"
kubectl --context "$KUBE_CONTEXT" -n "$NS" get hpa decision-service
before_current=$(kubectl --context "$KUBE_CONTEXT" -n "$NS" get hpa decision-service \
  -o jsonpath='{.status.currentReplicas}')
before_desired=$(kubectl --context "$KUBE_CONTEXT" -n "$NS" get hpa decision-service \
  -o jsonpath='{.status.desiredReplicas}')
echo "before current=${before_current:-?} desired=${before_desired:-?}"

kubectl --context "$KUBE_CONTEXT" -n "$NS" delete job "$JOB" --ignore-not-found
kubectl --context "$KUBE_CONTEXT" -n "$NS" delete configmap "$JOB" --ignore-not-found
kubectl --context "$KUBE_CONTEXT" -n "$NS" create configmap "$JOB" \
  --from-file=evaluate_load.py="$INFRA_DIR/load/evaluate_load.py"

cat <<EOF | kubectl --context "$KUBE_CONTEXT" -n "$NS" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  labels:
    app.kubernetes.io/name: pdp-load
    app.kubernetes.io/part-of: rba
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: load
          image: python:3.12-slim
          imagePullPolicy: Never
          command: ["python", "/load/evaluate_load.py"]
          env:
            - name: PDP_URL
              value: http://decision-service:8000
            - name: DURATION_SECONDS
              value: "${DURATION}"
            - name: WORKERS
              value: "${WORKERS}"
          volumeMounts:
            - name: load
              mountPath: /load
              readOnly: true
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: "1"
              memory: 256Mi
      volumes:
        - name: load
          configMap:
            name: ${JOB}
            defaultMode: 0555
EOF

echo "==> waiting up to $((DURATION + WAIT_EXTRA))s for HPA currentReplicas > ${before_current:-2}"
deadline=$((SECONDS + DURATION + WAIT_EXTRA))
max_current=${before_current:-2}
max_desired=${before_desired:-2}
moved=0
while (( SECONDS < deadline )); do
  current=$(kubectl --context "$KUBE_CONTEXT" -n "$NS" get hpa decision-service \
    -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "")
  desired=$(kubectl --context "$KUBE_CONTEXT" -n "$NS" get hpa decision-service \
    -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || echo "")
  cpu=$(kubectl --context "$KUBE_CONTEXT" -n "$NS" get hpa decision-service \
    -o jsonpath='{range .status.currentMetrics[*]}{.resource.current.averageUtilization}{" "}{end}' \
    2>/dev/null || echo "")
  echo "$(date -u +%H:%M:%S) current=${current:-?} desired=${desired:-?} cpu%=${cpu:-?}"
  if [[ -n "${current}" && "${current}" -gt "${max_current}" ]]; then
    max_current=$current
  fi
  if [[ -n "${desired}" && "${desired}" -gt "${max_desired}" ]]; then
    max_desired=$desired
  fi
  if [[ -n "${current}" && "${current}" -gt "${before_current:-2}" ]]; then
    moved=1
    echo "==> HPA moved: ${before_current} → ${current} replicas"
    break
  fi
  sleep 5
done

echo
echo "==> HPA after watch"
kubectl --context "$KUBE_CONTEXT" -n "$NS" get hpa decision-service
kubectl --context "$KUBE_CONTEXT" -n "$NS" get pods -l app.kubernetes.io/name=decision-service

echo
echo "==> load Job log (tail)"
kubectl --context "$KUBE_CONTEXT" -n "$NS" logs "job/${JOB}" --tail=20 || true

echo
echo "RESULT before_current=${before_current:-?} max_current=${max_current} max_desired=${max_desired} moved=${moved}"
echo "Grafana: http://localhost:8080/grafana  (dashboards → RBA / RBA PDP)"

if [[ "$moved" -ne 1 ]]; then
  echo "HPA did not add a replica within the wait window. Check metrics-server and Job logs." >&2
  exit 1
fi
