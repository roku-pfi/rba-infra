#!/usr/bin/env bash
# Tear the cloud environment down (ADR-0031, I-4). Back to ≈ US$1/month.
#
#   scripts/aws-down.sh
#
# Order matters: the charts are uninstalled first so the Load Balancer
# Controller deletes the ALB it created (OpenTofu does not know about it, and an
# orphaned ALB keeps billing); then CloudFront is pointed away; then the
# runtime stack is destroyed. Safe to re-run.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INFRA_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
TOFU="$INFRA_DIR/tofu"
export AWS_PROFILE=${AWS_PROFILE:-rokusec}
export AWS_REGION=${AWS_REGION:-us-east-1}

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "checking AWS login"
aws sts get-caller-identity >/dev/null 2>&1 || aws sso login
BUCKET="rokusec-tofu-state-$(aws sts get-caller-identity --query Account --output text)"
tofu -chdir="$TOFU/runtime" init -input=false -backend-config="bucket=$BUCKET" >/dev/null
tofu -chdir="$TOFU/foundation" init -input=false -backend-config="bucket=$BUCKET" >/dev/null

alb_names() {
  aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-rokusec')].LoadBalancerName" --output text 2>/dev/null || true
}

if aws eks describe-cluster --name rokusec >/dev/null 2>&1; then
  aws eks update-kubeconfig --name rokusec --region "$AWS_REGION" >/dev/null
  CTX=$(kubectl config current-context)
  step "uninstalling the charts (the controller deletes the ALB)"
  helm --kube-context "$CTX" -n demo uninstall demo --wait 2>/dev/null || true
  helm --kube-context "$CTX" -n rba uninstall rba --wait 2>/dev/null || true
  for _ in $(seq 36); do
    if [[ -z "$(alb_names)" ]]; then break; fi
    echo "  waiting for the ALB to go: $(alb_names)"; sleep 10
  done
fi
[[ -z "$(alb_names)" ]] || { echo "ALB still present: $(alb_names). Not destroying the VPC side; delete it, then re-run." >&2; exit 1; }

step "pointing CloudFront away from the (gone) ALB"
tofu -chdir="$TOFU/foundation" apply -input=false -auto-approve

step "destroying the runtime stack (~10–15 min)"
tofu -chdir="$TOFU/runtime" destroy -input=false -auto-approve

step "leftovers"
left=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Stack,Values=runtime \
  --query 'ResourceTagMappingList[].ResourceARN' --output text)
k8s_sgs=$(aws ec2 describe-security-groups --filters Name=tag-key,Values=elbv2.k8s.aws/cluster \
  --query 'SecurityGroups[].GroupId' --output text)
if [[ -z "$left$k8s_sgs" ]]; then
  echo "  none. Back to ≈ US\$1/month (foundation only)."
else
  echo "  still tagged runtime: ${left:-none}"; echo "  controller security groups: ${k8s_sgs:-none}"
fi
