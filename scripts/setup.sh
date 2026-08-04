#!/usr/bin/env bash
# setup.sh <client-slug> — run the full Phase 1 sequence for one client.
# Idempotent: re-running converges to the same state. DRY_RUN=1 prints the
# complete command plan without touching GCP (no SDK required).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0"
SLUG="$1"
load_client "$SLUG"   # fail fast on bad slug/config before running anything

for step in 00-preflight 01-datasets 02-service-accounts 03-iam 90-verify; do
  info "──────── $step ────────"
  "$SCRIPT_DIR/$step.sh" "$SLUG"
done

info "Phase 1 complete for '$SLUG' (project $GCP_PROJECT_ID)"
