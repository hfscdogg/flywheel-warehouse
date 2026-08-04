#!/usr/bin/env bash
# 00-preflight.sh <client-slug> — read-only environment gate.
# Verifies the operator's machine and the client's GCP project are ready for
# Phase 1. Mutates nothing; safe to run any time.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0"
load_client "$1"

REQUIRED_APIS="bigquery.googleapis.com iam.googleapis.com iamcredentials.googleapis.com cloudresourcemanager.googleapis.com"

if is_dry_run; then
  info "[dry-run] preflight is read-only; a real run checks:"
  log "  - gcloud, bq, curl on PATH"
  log "  - an active gcloud auth session"
  log "  - project $GCP_PROJECT_ID exists and is visible"
  log "  - billing is linked (BigQuery sandbox forces 60-day table expiry)"
  log "  - APIs enabled: $REQUIRED_APIS"
  exit 0
fi

require_cmd gcloud bq curl

FAILED=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=1; }

info "Preflight for client '$CLIENT_SLUG' (project $GCP_PROJECT_ID)"
log "  gcloud $(gcloud version 2>/dev/null | head -n1 | awk '{print $NF}')"

ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1)"
if [ -n "$ACTIVE_ACCOUNT" ]; then
  pass "authenticated as $ACTIVE_ACCOUNT"
else
  fail "no active gcloud auth — run: gcloud auth login"
fi

if gcloud projects describe "$GCP_PROJECT_ID" >/dev/null 2>&1; then
  pass "project $GCP_PROJECT_ID exists and is visible"
else
  fail "cannot see project $GCP_PROJECT_ID — create it or check permissions (docs/phase-0-checklist.md step 3)"
fi

# 'gcloud billing' needs a recent SDK; warn rather than fail if unavailable.
BILLING="$(gcloud billing projects describe "$GCP_PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null || true)"
case "$BILLING" in
  True)  pass "billing is linked" ;;
  False) fail "billing NOT linked — BigQuery sandbox forces 60-day table expiry (docs/phase-0-checklist.md step 4)" ;;
  *)     warn "could not check billing (component unavailable?) — verify manually in the console" ;;
esac

ENABLED_APIS="$(gcloud services list --enabled --project "$GCP_PROJECT_ID" --format='value(config.name)' 2>/dev/null || true)"
MISSING_APIS=""
for api in $REQUIRED_APIS; do
  if printf '%s\n' "$ENABLED_APIS" | grep -qx "$api"; then
    pass "API enabled: $api"
  else
    fail "API not enabled: $api"
    MISSING_APIS="$MISSING_APIS $api"
  fi
done
if [ -n "$MISSING_APIS" ]; then
  log ""
  log "  To enable (Phase 0 is a human step — run this yourself):"
  log "    gcloud services enable$MISSING_APIS --project $GCP_PROJECT_ID"
fi

log ""
if [ "$FAILED" -ne 0 ]; then
  die "preflight failed — see docs/phase-0-checklist.md"
fi
info "Preflight passed."
