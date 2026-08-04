#!/usr/bin/env bash
# 03-iam.sh <client-slug> — every IAM binding, in one auditable place.
#
# The trust surface (docs/trust.md) is defined here:
#   hermes-reader : jobUser (project) + dataViewer (marts dataset ONLY)
#   ingest-writer : jobUser (project) + dataEditor (each dataset, dataset-level)
#   ADMIN_USER    : serviceAccountTokenCreator on the hermes-reader SA
#
# hermes-reader deliberately gets NOTHING on raw_* or staging.
#
# Bindings run serially: concurrent policy writes hit etag conflicts. Both
# 'gcloud ... add-iam-policy-binding' and 'bq add-iam-policy-binding' are
# no-ops when the binding already exists, so this script is re-runnable.
# shellcheck disable=SC2086  # $BQ is intentionally word-split
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0"
load_client "$1"
require_cmd gcloud bq

info "IAM bindings for '$CLIENT_SLUG' in $GCP_PROJECT_ID"

info "hermes-reader: query jobs at project level"
run gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:$SA_HERMES_READER_EMAIL" \
  --role=roles/bigquery.jobUser --condition=None --format=none --quiet

info "hermes-reader: read access on $DATASET_MARTS ONLY"
run $BQ add-iam-policy-binding \
  --member="serviceAccount:$SA_HERMES_READER_EMAIL" \
  --role=roles/bigquery.dataViewer "$GCP_PROJECT_ID:$DATASET_MARTS"

info "ingest-writer: query jobs at project level"
run gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:$SA_INGEST_WRITER_EMAIL" \
  --role=roles/bigquery.jobUser --condition=None --format=none --quiet

info "ingest-writer: dataset-level write access (not project-level)"
for ds in $ALL_DATASETS; do
  run $BQ add-iam-policy-binding \
    --member="serviceAccount:$SA_INGEST_WRITER_EMAIL" \
    --role=roles/bigquery.dataEditor "$GCP_PROJECT_ID:$ds"
done

# Project Owner does NOT include token creation. This is what lets ADMIN_USER
# impersonate hermes-reader — for 90-verify's smoke test, and for keyless
# agent auth.
info "$ADMIN_USER: impersonation rights on hermes-reader"
run gcloud iam service-accounts add-iam-policy-binding "$SA_HERMES_READER_EMAIL" \
  --project "$GCP_PROJECT_ID" \
  --member="user:$ADMIN_USER" \
  --role=roles/iam.serviceAccountTokenCreator --format=none --quiet

info "IAM done."
