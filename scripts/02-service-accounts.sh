#!/usr/bin/env bash
# 02-service-accounts.sh <client-slug> — create/converge the two service
# accounts: hermes-reader (agents) and ingest-writer (pipelines).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0"
load_client "$1"
require_cmd gcloud

create_sa() {
  local name="$1" email="$2" purpose="$3"
  local display="Flywheel: $purpose ($CLIENT_DISPLAY_NAME)"
  if probe gcloud iam service-accounts describe "$email" --project "$GCP_PROJECT_ID"; then
    info "service account $name exists — converging display name"
    run gcloud iam service-accounts update "$email" --project "$GCP_PROJECT_ID" \
      --display-name "$display" --quiet
  else
    info "creating service account $name"
    run gcloud iam service-accounts create "$name" --project "$GCP_PROJECT_ID" \
      --display-name "$display" \
      --description "managed-by=flywheel client=$CLIENT_SLUG" --quiet
    # New SAs are eventually consistent: an immediate IAM binding in 03 can
    # fail with "service account does not exist". Wait (up to ~60s) until
    # describe succeeds.
    if ! is_dry_run; then
      retry 12 5 probe gcloud iam service-accounts describe "$email" --project "$GCP_PROJECT_ID" \
        || die "service account $email not visible after creation"
    fi
  fi
}

info "Service accounts for '$CLIENT_SLUG' in $GCP_PROJECT_ID"
create_sa "$SA_HERMES_READER" "$SA_HERMES_READER_EMAIL" "agent read-only, marts only"
create_sa "$SA_INGEST_WRITER" "$SA_INGEST_WRITER_EMAIL" "ingestion writer"
info "Service accounts done."
