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
SESSION_DIR="$INFRA_DIR/.session"   # gitignored
mkdir -p "$SESSION_DIR"
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
  aws eks update-kubeconfig --name rokusec --region "$AWS_REGION" --alias rokusec >/dev/null
  CTX=$(kubectl config current-context)
  step "saving enrolled passkeys (aws-up restores them)"
  # The passkeys on people's devices are bound to the permanent CloudFront host;
  # only the server's copy of the public keys goes with the database.
  if kubectl --context "$CTX" -n rba exec deploy/idp -c idp -- python -m rba_idp.passkeys export \
      > "$SESSION_DIR/passkeys.new.json" 2>/dev/null; then
    python3 "$SCRIPT_DIR/merge-passkeys.py" "$SESSION_DIR/passkeys.json" "$SESSION_DIR/passkeys.new.json"
    chmod 600 "$SESSION_DIR/passkeys.json"
  else
    echo "  could not export (IdP not running?); keeping the previous file"
  fi
  rm -f "$SESSION_DIR/passkeys.new.json"
  step "uninstalling the charts (the controller deletes the ALB)"
  helm --kube-context "$CTX" -n demo uninstall demo --wait 2>/dev/null || true
  helm --kube-context "$CTX" -n demo uninstall kaze --wait 2>/dev/null || true
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

step "leftovers (anything that could still bill)"
# Asks each service for live resources. The tagging API is not used: it keeps
# listing deleted resources (a NAT gateway in state "deleted", removed
# security-group rules) for a while after a destroy.
left=""
add() { [[ -n "$2" && "$2" != "None" ]] && left+="  $1: $2"$'\n' || true; }
add "EKS clusters" "$(aws eks list-clusters --query 'clusters[?@==`rokusec`]' --output text)"
add "NAT gateways" "$(aws ec2 describe-nat-gateways --filter Name=state,Values=pending,available,deleting --query 'NatGateways[].NatGatewayId' --output text)"
add "RDS" "$(aws rds describe-db-instances --query "DBInstances[?DBInstanceIdentifier=='rokusec'].DBInstanceStatus" --output text 2>/dev/null)"
add "Valkey" "$(aws elasticache describe-replication-groups --query "ReplicationGroups[?ReplicationGroupId=='rokusec'].Status" --output text 2>/dev/null)"
add "load balancers" "$(alb_names)"
add "Elastic IPs" "$(aws ec2 describe-addresses --filters Name=tag:Stack,Values=runtime --query 'Addresses[].PublicIp' --output text)"
add "EC2 instances" "$(aws ec2 describe-instances --filters Name=tag:eks:cluster-name,Values=rokusec Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)"
if [[ -z "$left" ]]; then
  echo "  none. Back to ≈ US\$1/month (foundation only)."
else
  printf 'still present:\n%s' "$left"
fi
