#!/usr/bin/env bash
# Build a usual login history for demo personas through the real login (e2e/warmup.py).
#
#   scripts/warm-up.sh martin                 10 logins, k3d
#   scripts/warm-up.sh martin diego -n 15
#   TARGET=aws scripts/warm-up.sh martin      after make aws-up
set -euo pipefail
INFRA_DIR=$(cd "$(dirname "$0")/.." && pwd)
E2E_DIR="$INFRA_DIR/e2e"
if [[ ! -x "$E2E_DIR/.venv/bin/python" ]]; then
  python3.12 -m venv "$E2E_DIR/.venv"
  "$E2E_DIR/.venv/bin/pip" install -q -r "$E2E_DIR/requirements.txt"
  "$E2E_DIR/.venv/bin/python" -m playwright install chromium
fi
if [[ "${TARGET:-k3d}" == "aws" ]]; then
  export AWS_PROFILE=${AWS_PROFILE:-rokusec}
  hosts=$(tofu -chdir="$INFRA_DIR/tofu/foundation" output -json hosts)
  host() { python3 -c "import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])" "$hosts" "$1"; }
  export E2E_IDP_URL="https://$(host auth)" E2E_BANK_URL="https://$(host bank)" E2E_KAZE_URL="https://$(host kaze)"
  export E2E_KUBE_CONTEXT=rokusec
  E2E_PASSWORD_SUFFIX=$(tofu -chdir="$INFRA_DIR/tofu/runtime" output -raw seed_password_suffix)
  export E2E_PASSWORD_SUFFIX
fi
cd "$E2E_DIR"
exec .venv/bin/python warmup.py "$@"
