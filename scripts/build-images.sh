#!/usr/bin/env bash
# C-5: build every service image for linux/arm64 (EKS Graviton) and
# linux/amd64 (CI runners, x86 laptops) with buildx (ADR-0031).
#
#   scripts/build-images.sh                 # check both platforms build, push nothing
#   scripts/build-images.sh --push          # push to ECR, tag = git SHA of each repo
#   REGISTRY=… TAG=… scripts/build-images.sh --push
#
# Images are tagged by the short SHA of the service's own repo; ECR tags are
# immutable, so a tag always names the same build. Pushing needs AWS
# credentials (profile `rokusec`) and the foundation stack's repositories.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INFRA_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
ROOT=$(cd "$INFRA_DIR/.." && pwd)
PLATFORMS=${PLATFORMS:-linux/arm64,linux/amd64}
BUILDER=rba-multiarch
PUSH=0
[[ "${1:-}" == "--push" ]] && PUSH=1

SERVICES=(
  rba-decision-service
  rba-idp
  rba-event-publisher
  rba-profile-service
  rba-audit-service
  rba-demo-banking
)

if [[ "$PUSH" -eq 1 ]]; then
  : "${AWS_PROFILE:=rokusec}"
  export AWS_PROFILE
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  REGION=${AWS_REGION:-us-east-1}
  REGISTRY=${REGISTRY:-${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com}
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
fi

# A docker-container builder: the default "docker" driver cannot emit a
# multi-platform image. Foreign platforms run under QEMU/Rosetta.
docker buildx inspect "$BUILDER" >/dev/null 2>&1 \
  || docker buildx create --name "$BUILDER" --driver docker-container >/dev/null

IGNORE_DST="$ROOT/.dockerignore"
copied_ignore=0
if [[ ! -f "$IGNORE_DST" ]]; then
  cp "$INFRA_DIR/docker/dockerignore" "$IGNORE_DST"
  copied_ignore=1
fi
cleanup() { if [[ "$copied_ignore" -eq 1 ]]; then rm -f "$IGNORE_DST"; fi; }
trap cleanup EXIT

cd "$ROOT"
for svc in "${SERVICES[@]}"; do
  tag=${TAG:-$(git -C "$svc" rev-parse --short=12 HEAD)}
  args=(--builder "$BUILDER" --platform "$PLATFORMS" -f "$svc/Dockerfile")
  if [[ "$PUSH" -eq 1 ]]; then
    ref="$REGISTRY/$svc:$tag"
    echo "==> $ref ($PLATFORMS)"
    docker buildx build "${args[@]}" -t "$ref" --push .
  else
    echo "==> $svc:$tag ($PLATFORMS, build only)"
    docker buildx build "${args[@]}" .
  fi
done
