#!/usr/bin/env bash
# Bring the whole cloud environment up, end to end (ADR-0031, I-4).
#
#   scripts/aws-up.sh
#
# Images → runtime stack → charts → CloudFront re-pointed → smoke test.
# Costs about US$0.27/hour from the runtime apply until scripts/aws-down.sh.
# Safe to re-run: every step is idempotent, so a second run after a failure (or
# after a code change) picks up where things are.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INFRA_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
ROOT=$(cd "$INFRA_DIR/.." && pwd)
TOFU="$INFRA_DIR/tofu"
export AWS_PROFILE=${AWS_PROFILE:-rokusec}
export AWS_REGION=${AWS_REGION:-us-east-1}
SESSION_DIR="$INFRA_DIR/.session"   # gitignored; holds the generated values
mkdir -p "$SESSION_DIR"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing '$1' ($2)" >&2; exit 1; }; }

step "checking tools and AWS login"
need aws "brew install awscli"; need tofu "brew install opentofu"; need helm "brew install helm"
need kubectl "brew install kubectl"; need docker "start OrbStack"; need curl "-"
docker info >/dev/null 2>&1 || { echo "Docker is not running: start OrbStack." >&2; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || aws sso login
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="rokusec-tofu-state-$ACCOUNT"
REGISTRY="$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com"

# ---------------------------------------------------------------- images
SERVICES=(rba-decision-service rba-idp rba-event-publisher rba-profile-service rba-audit-service rba-demo-banking rba-demo-kaze)
heads=""; dirty=0
for svc in "${SERVICES[@]}" rba-contracts rba-features; do
  heads+="$svc $(git -C "$ROOT/$svc" rev-parse HEAD)"$'\n'
  if [[ -n "$(git -C "$ROOT/$svc" status --porcelain)" ]]; then
    echo "  (uncommitted changes in $svc)"; dirty=1
  fi
done
TAG=$(printf '%s' "$heads" | shasum | cut -c1-12)
# Immutable tags: uncommitted work gets a tag of its own.
if [[ "$dirty" -eq 1 ]]; then TAG="$TAG-dirty-$(date +%s)"; fi
step "images, tag $TAG"
TAG="$TAG" "$SCRIPT_DIR/build-images.sh" --push

# ---------------------------------------------------------------- runtime stack
step "runtime stack (EKS, RDS, Valkey, NAT) — ~20 min the first time"
if [[ ! -f "$TOFU/runtime/terraform.tfvars" ]]; then
  echo "state_bucket = \"$BUCKET\"" > "$TOFU/runtime/terraform.tfvars"
fi
tofu -chdir="$TOFU/runtime" init -input=false -backend-config="bucket=$BUCKET" >/dev/null
tofu -chdir="$TOFU/runtime" apply -input=false -auto-approve

rt() { tofu -chdir="$TOFU/runtime" output -raw "$1"; }
fd() { tofu -chdir="$TOFU/foundation" output -raw "$1"; }
fdj() { tofu -chdir="$TOFU/foundation" output -json "$1"; }
tofu -chdir="$TOFU/foundation" init -input=false -backend-config="bucket=$BUCKET" >/dev/null
eval "$(rt kubeconfig_command)" >/dev/null
CTX=$(kubectl config current-context)
AUTH=$(fdj hosts | python3 -c 'import json,sys;print(json.load(sys.stdin)["auth"])')
BANK=$(fdj hosts | python3 -c 'import json,sys;print(json.load(sys.stdin)["bank"])')

# ---------------------------------------------------------------- charts
step "session values"
cat > "$SESSION_DIR/rba.yaml" <<YAML
images: {registry: "$REGISTRY", tag: "$TAG"}
dataPlane:
  postgres: {host: "$(rt rds_endpoint)"}
  redis: {host: "$(rt valkey_endpoint)"}
ingress:
  originVerify: "$(fd origin_verify_header)"
  annotations:
    alb.ingress.kubernetes.io/security-groups: "$(rt alb_security_group_id)"
apps:
  idp:
    env:
      TRUSTED_PROXY_CIDRS: "$(rt trusted_proxy_cidrs)"
YAML
cat > "$SESSION_DIR/demo.yaml" <<YAML
image: "$REGISTRY/rba-demo-banking"
tag: "$TAG"
ingress:
  originVerify: "$(fd origin_verify_header)"
  annotations:
    alb.ingress.kubernetes.io/security-groups: "$(rt alb_security_group_id)"
YAML
cat > "$SESSION_DIR/kaze.yaml" <<YAML
image: "$REGISTRY/rba-demo-kaze"
tag: "$TAG"
ingress:
  originVerify: "$(fd origin_verify_header)"
  annotations:
    alb.ingress.kubernetes.io/security-groups: "$(rt alb_security_group_id)"
YAML
chmod 600 "$SESSION_DIR"/*.yaml

step "helm: rba (init Jobs first, then the services)"
helm upgrade --install rba "$INFRA_DIR/helm/rba" --kube-context "$CTX" \
  --namespace rba -f "$INFRA_DIR/helm/rba/values-aws.yaml" -f "$SESSION_DIR/rba.yaml" \
  --wait --timeout 15m
step "helm: demo (Roku Bank)"
helm upgrade --install demo "$INFRA_DIR/helm/demo" --kube-context "$CTX" \
  --namespace demo --create-namespace -f "$INFRA_DIR/helm/demo/values-aws.yaml" -f "$SESSION_DIR/demo.yaml" \
  --wait --timeout 10m
step "helm: kaze (Kaze Labs)"
helm upgrade --install kaze "$INFRA_DIR/helm/demo" --kube-context "$CTX" \
  --namespace demo -f "$INFRA_DIR/helm/demo/values-aws.yaml" -f "$INFRA_DIR/helm/demo/values-kaze.yaml" \
  -f "$INFRA_DIR/helm/demo/values-kaze-aws.yaml" -f "$SESSION_DIR/kaze.yaml" \
  --wait --timeout 10m

# ---------------------------------------------------------------- edge
step "waiting for the ALB"
ALB=""
for _ in $(seq 60); do
  ALB=$(kubectl --context "$CTX" -n rba get ingress idp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "$ALB" ]]; then break; fi
  sleep 10
done
[[ -n "$ALB" ]] || { echo "the ALB did not appear; see: kubectl -n kube-system logs deploy/aws-load-balancer-controller" >&2; exit 1; }
echo "  $ALB"

step "pointing CloudFront at the ALB (~5 min)"
tofu -chdir="$TOFU/foundation" apply -input=false -auto-approve -var "origin_domain=$ALB"
for id in $(fdj distribution_ids | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin).values()))'); do
  aws cloudfront wait distribution-deployed --id "$id"
done

step "smoke test"
for host in "$AUTH" "$BANK"; do
  for _ in $(seq 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "https://$host/healthz" || true)
    if [[ "$code" == 200 ]]; then break; fi
    sleep 10
  done
  echo "  https://$host/healthz → $code"
done

cat <<TXT

$(printf '\033[1m')RokuSec is up.$(printf '\033[0m')  Remember: about US\$0.27/hour until scripts/aws-down.sh.

  Console      https://$AUTH/admin
  Roku Bank    https://$BANK/
  Grafana      https://$AUTH/grafana   (admin / tofu -chdir=tofu/runtime output -raw grafana_admin_password)

  Fresh databases: nobody has a passkey yet. First, the platform operator:
    kubectl -n rba exec deploy/idp -c idp -- python -m rba_idp.activation juan@rokusec.example --tenant rokusec
  then enroll at https://$AUTH/activate. Seeded passwords are <name>-<suffix>:
    tofu -chdir=tofu/runtime output -raw seed_password_suffix
TXT
