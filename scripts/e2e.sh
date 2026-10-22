#!/usr/bin/env bash
# End-to-end tests of the scenario map (ADR-0035) against a running cluster.
#
#   scripts/e2e.sh                 k3d (default)
#   E2E_LOAD=1 scripts/e2e.sh      plus the load scene (~90 s more)
#   scripts/e2e.sh -k kaze         any pytest arguments
#
# Against AWS, point it at the cloud first (see e2e/README.md).
set -euo pipefail
E2E_DIR=$(cd "$(dirname "$0")/../e2e" && pwd)
if [[ ! -x "$E2E_DIR/.venv/bin/python" ]]; then
  python3.12 -m venv "$E2E_DIR/.venv"
  "$E2E_DIR/.venv/bin/pip" install -q -r "$E2E_DIR/requirements.txt"
  "$E2E_DIR/.venv/bin/python" -m playwright install chromium
fi
cd "$E2E_DIR"
exec .venv/bin/python -m pytest -q "$@"
