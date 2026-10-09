#!/usr/bin/env bash
# 02-service-accounts.sh <client-slug> — create/converge the service
# accounts: hermes-reader (agents) and one per pipeline job — an ingest
# account per source, transform-writer and warehouse-reader (probe). What each
# may do is 03-iam.sh and 05-ingestion-infra.sh; lib/common.sh says why.
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
for src in $INGEST_SOURCES; do
  create_sa "$(ingest_sa_name "$src")" "$(ingest_sa_email "$src")" "ingest raw_$src only"
done
create_sa "$SA_TRANSFORM" "$SA_TRANSFORM_EMAIL" "build staging and marts"
create_sa "$SA_PROBE" "$SA_PROBE_EMAIL" "read-only probe"
info "Service accounts done."
