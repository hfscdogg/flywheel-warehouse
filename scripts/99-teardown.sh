#!/usr/bin/env bash
# 99-teardown.sh <client-slug> [--revoke-agent|--all-iam|--full] [--yes]
#
# "You can revoke it anytime" (docs/trust.md), as a script. Three escalating
# modes:
#
#   --revoke-agent  (default) Remove hermes-reader's IAM bindings, delete its
#                   keys, DISABLE the SA (reversible). Agents lose all access
#                   in under a minute; data untouched. Undo: 03-iam.sh +
#                   'gcloud iam service-accounts enable'.
#   --all-iam       The above, plus the same for every pipeline identity
#                   (ingest-<source>, transform-writer, warehouse-reader,
#                   and the retired ingest-writer if it still exists).
#   --full          The above, plus DELETE every dataset and those SAs.
#                   Irreversible. Requires typing the project ID.
#
# Idempotent: every removal checks for the binding first, because
# 'remove-iam-policy-binding' exits 1 when the binding is already absent.
# shellcheck disable=SC2086  # $BQ is intentionally word-split
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0 [--revoke-agent|--all-iam|--full] [--yes]"
SLUG="$1"
shift
load_client "$SLUG"
require_cmd gcloud bq python3

MODE="--revoke-agent"
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --revoke-agent|--all-iam|--full) MODE="$arg" ;;
    --yes) ASSUME_YES=1 ;;
    *) die "unknown argument '$arg'" ;;
  esac
done

confirm() { # confirm <prompt> <required-reply>
  [ "$ASSUME_YES" = "1" ] && return 0
  is_dry_run && return 0
  printf '%s\n' "$1"
  printf "Type '%s' to confirm: " "$2"
  read -r reply
  [ "$reply" = "$2" ] || die "confirmation did not match — aborting"
}

# Removal helpers (remove_project_binding, revoke_dataset_role, revoke_sa)
# live in lib/common.sh, shared with 11-retire-ingest-writer.sh.

# --- modes ------------------------------------------------------------------

revoke_agent() {
  info "Revoking agent access for '$CLIENT_SLUG' ($SA_HERMES_READER_EMAIL)"
  remove_project_binding "$SA_HERMES_READER_EMAIL" roles/bigquery.jobUser
  revoke_dataset_role "$SA_HERMES_READER_EMAIL" roles/bigquery.dataViewer "$DATASET_MARTS"
  revoke_sa "$SA_HERMES_READER_EMAIL" "hermes-reader"
  info "Agent access revoked. Re-grant: 03-iam.sh + 'gcloud iam service-accounts enable'."
}

# Every pipeline identity: one per ingest source, transform, probe, and the
# retired single ingest-writer for a client that still has it. Their WIF
# bindings are left in place: a disabled account mints no token anyway, and
# re-enabling it (the documented undo) should not also need 05 re-run.
pipeline_identities() {
  local src
  for src in $INGEST_SOURCES; do ingest_sa_email "$src"; printf '\n'; done
  printf '%s\n%s\n%s\n' "$SA_TRANSFORM_EMAIL" "$SA_PROBE_EMAIL" "$SA_INGEST_WRITER_EMAIL"
}

revoke_writer() {
  local email
  for email in $(pipeline_identities); do
    info "Revoking pipeline access ($email)"
    remove_project_binding "$email" roles/bigquery.jobUser
    for ds in $ALL_DATASETS $GA4_EXPORT_DATASET; do
      revoke_dataset_role "$email" roles/bigquery.dataEditor "$ds"
      revoke_dataset_role "$email" roles/bigquery.dataViewer "$ds"
    done
    revoke_sa "$email" "$email"
  done
}

full_teardown() {
  info "FULL teardown: deleting all datasets and service accounts"
  for ds in $ALL_DATASETS; do
    run $BQ rm -r -f -d "$GCP_PROJECT_ID:$ds"
  done
  for email in "$SA_HERMES_READER_EMAIL" $(pipeline_identities); do
    if is_dry_run || probe gcloud iam service-accounts describe "$email" --project "$GCP_PROJECT_ID"; then
      run gcloud iam service-accounts delete "$email" --project "$GCP_PROJECT_ID" --quiet
    fi
  done
}

case "$MODE" in
  --revoke-agent)
    confirm "This removes ALL agent access for '$CLIENT_SLUG' (data untouched, reversible)." "$CLIENT_SLUG"
    revoke_agent
    ;;
  --all-iam)
    confirm "This removes agent AND pipeline access for '$CLIENT_SLUG' (data untouched, reversible)." "$CLIENT_SLUG"
    revoke_agent
    revoke_writer
    ;;
  --full)
    confirm "IRREVERSIBLE: this DELETES every dataset (all data!) and every Flywheel service account in $GCP_PROJECT_ID." "$GCP_PROJECT_ID"
    revoke_agent
    revoke_writer
    full_teardown
    ;;
esac

info "Teardown ($MODE) complete for '$CLIENT_SLUG'."
