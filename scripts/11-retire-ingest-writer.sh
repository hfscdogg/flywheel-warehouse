#!/usr/bin/env bash
# 11-retire-ingest-writer.sh <client-slug> [--yes]
#
# Strips the single pipeline identity this repo used before 2026-10-09 and
# disables it. ingest-writer held every connector secret, dataEditor on raw,
# staging and marts, and trusted any workflow on any branch of the repo. Its
# jobs now run as one account each (lib/common.sh, docs/trust.md).
#
# RUN THIS LAST. Until every workflow's repository variable points at its new
# account, the workflows fall back to WIF_SERVICE_ACCOUNT, which is
# ingest-writer, and retiring it stops the nightly pipelines. The order is in
# docs/runbook-identity-cutover.md: 02, 03, 05, 09, 10, set the variables,
# watch one run of each workflow pass, then this.
#
# The script checks what it can before removing anything: every new account
# exists, and the WIF provider maps job_workflow_ref (without which no pinned
# binding matches). It cannot see GitHub's variables, so it asks.
#
# Reversible: re-enable the account, re-add the bindings you need. Idempotent:
# every removal checks for the binding first.
# shellcheck disable=SC2086  # $BQ is intentionally word-split
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0 [--yes]"
load_client "$1"
ASSUME_YES=0
[ "${2:-}" = "--yes" ] && ASSUME_YES=1
require_cmd gcloud gsutil bq python3

if [ -z "${GITHUB_REPO:-}" ] || [ -z "${WIF_POOL:-}" ]; then
  die "GITHUB_REPO and WIF_POOL must be set in clients/$CLIENT_SLUG/client.env"
fi

info "Retiring $SA_INGEST_WRITER_EMAIL"

# ── Preconditions ───────────────────────────────────────────────────────────
if ! is_dry_run; then
  if ! probe gcloud iam service-accounts describe "$SA_INGEST_WRITER_EMAIL" --project "$GCP_PROJECT_ID"; then
    info "$SA_INGEST_WRITER_EMAIL does not exist — nothing to retire"
    exit 0
  fi
  missing=""
  for src in $INGEST_SOURCES; do
    probe gcloud iam service-accounts describe "$(ingest_sa_email "$src")" --project "$GCP_PROJECT_ID" \
      || missing="$missing $(ingest_sa_email "$src")"
  done
  for email in "$SA_TRANSFORM_EMAIL" "$SA_PROBE_EMAIL"; do
    probe gcloud iam service-accounts describe "$email" --project "$GCP_PROJECT_ID" \
      || missing="$missing $email"
  done
  [ -z "$missing" ] || die "these accounts do not exist yet:$missing — run 02, 03 and 05 first"
  MAPPING="$(gcloud iam workload-identity-pools providers describe github \
    --project "$GCP_PROJECT_ID" --location=global --workload-identity-pool="$WIF_POOL" \
    --format='value(attributeMapping)' 2>/dev/null || true)"
  case "$MAPPING" in
    *job_workflow_ref*) : ;;
    *) die "the WIF provider does not map job_workflow_ref — run 05-ingestion-infra.sh $CLIENT_SLUG first" ;;
  esac
fi

if [ "$ASSUME_YES" != "1" ] && ! is_dry_run; then
  log ""
  log "Every workflow must already be on its own account. In GitHub, check that"
  log "these repository variables are set, and that a run of each workflow has"
  log "passed since:"
  for src in $INGEST_SOURCES; do log "  $(ingest_sa_var "$src")"; done
  log "  WIF_SA_TRANSFORM"
  log "  WIF_SA_PROBE"
  printf "Type '%s' to retire ingest-writer: " "$CLIENT_SLUG"
  read -r reply
  [ "$reply" = "$CLIENT_SLUG" ] || die "confirmation did not match — aborting"
fi

# ── GitHub's way in ─────────────────────────────────────────────────────────
if is_dry_run; then
  POOL_NAME="projects/<project-number>/locations/global/workloadIdentityPools/$WIF_POOL"
else
  POOL_NAME="$(gcloud iam workload-identity-pools describe "$WIF_POOL" \
    --project "$GCP_PROJECT_ID" --location=global --format='value(name)')"
fi
info "Removing the repo-wide WIF binding (any workflow, any branch)"
remove_resource_binding "iam service-accounts" "$SA_INGEST_WRITER_EMAIL" \
  "$(wif_repo_member "$POOL_NAME")" roles/iam.workloadIdentityUser

# ── Secrets ─────────────────────────────────────────────────────────────────
# Every connector's, whether or not this client ingests it: the old script
# granted all sixteen.
info "Removing secret access"
for src in zoho zohobilling dtools alarmdotcom qbo; do
  for s in $(source_secrets "$src"); do
    remove_resource_binding secrets "$s" "serviceAccount:$SA_INGEST_WRITER_EMAIL" \
      roles/secretmanager.secretAccessor
  done
  for s in $(source_rotating_secrets "$src"); do
    remove_resource_binding secrets "$s" "serviceAccount:$SA_INGEST_WRITER_EMAIL" \
      roles/secretmanager.secretVersionAdder
  done
done

# ── BigQuery ────────────────────────────────────────────────────────────────
info "Removing BigQuery access"
for ds in $ALL_DATASETS; do
  revoke_dataset_role "$SA_INGEST_WRITER_EMAIL" roles/bigquery.dataEditor "$ds"
done
if [ -n "$GA4_EXPORT_DATASET" ]; then
  revoke_dataset_role "$SA_INGEST_WRITER_EMAIL" roles/bigquery.dataViewer "$GA4_EXPORT_DATASET"
fi
remove_project_binding "$SA_INGEST_WRITER_EMAIL" roles/bigquery.jobUser

# ── Vendor drop bucket ──────────────────────────────────────────────────────
BUCKET="$(vendor_drop_bucket)"
if is_dry_run || probe gsutil ls -b "gs://$BUCKET"; then
  info "Removing gs://$BUCKET access"
  run gsutil iam ch -d "serviceAccount:$SA_INGEST_WRITER_EMAIL:roles/storage.objectAdmin" "gs://$BUCKET" \
    || warn "could not remove objectAdmin on gs://$BUCKET — check it by hand"
fi

# ── The account ─────────────────────────────────────────────────────────────
revoke_sa "$SA_INGEST_WRITER_EMAIL" "$SA_INGEST_WRITER"

log ""
info "ingest-writer retired. Delete the WIF_SERVICE_ACCOUNT repository variable"
log "  so nothing can fall back to it:"
log "    gh variable delete WIF_SERVICE_ACCOUNT --repo $GITHUB_REPO"
