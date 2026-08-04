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
#   --all-iam       The above, plus the same for ingest-writer.
#   --full          The above, plus DELETE every dataset and both SAs.
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
require_cmd gcloud bq

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

# --- binding-aware removal helpers (check first: re-runnable) ---------------

remove_project_binding() { # <sa-email> <role>
  local email="$1" role="$2"
  if is_dry_run || gcloud projects get-iam-policy "$GCP_PROJECT_ID" \
      --flatten='bindings[].members' \
      --filter="bindings.role=$role AND bindings.members=serviceAccount:$email" \
      --format='value(bindings.role)' 2>/dev/null | grep -q .; then
    run gcloud projects remove-iam-policy-binding "$GCP_PROJECT_ID" \
      --member="serviceAccount:$email" --role="$role" \
      --condition=None --format=none --quiet
  else
    info "project binding $role for $email already absent"
  fi
}

remove_dataset_binding() { # <sa-email> <role> <dataset>
  local email="$1" role="$2" ds="$3"
  if is_dry_run || $BQ get-iam-policy --format=prettyjson "$GCP_PROJECT_ID:$ds" 2>/dev/null \
      | grep -q "$email"; then
    run $BQ remove-iam-policy-binding \
      --member="serviceAccount:$email" --role="$role" "$GCP_PROJECT_ID:$ds"
  else
    info "dataset binding $role for $email on $ds already absent"
  fi
}

delete_all_user_keys() { # <sa-email>
  local email="$1" key
  if is_dry_run; then
    log "[dry-run] delete all user-managed keys on $email"
    return 0
  fi
  for key in $(gcloud iam service-accounts keys list --iam-account "$email" \
      --project "$GCP_PROJECT_ID" --managed-by=user \
      --format='value(name.basename())' 2>/dev/null || true); do
    run gcloud iam service-accounts keys delete "$key" \
      --iam-account "$email" --project "$GCP_PROJECT_ID" --quiet
  done
}

revoke_sa() { # <sa-email> <label>  — bindings assumed already removed
  local email="$1" label="$2"
  delete_all_user_keys "$email"
  if is_dry_run || probe gcloud iam service-accounts describe "$email" --project "$GCP_PROJECT_ID"; then
    run gcloud iam service-accounts disable "$email" --project "$GCP_PROJECT_ID" --quiet
    info "$label disabled (reversible: gcloud iam service-accounts enable $email)"
  fi
}

# --- modes ------------------------------------------------------------------

revoke_agent() {
  info "Revoking agent access for '$CLIENT_SLUG' ($SA_HERMES_READER_EMAIL)"
  remove_project_binding "$SA_HERMES_READER_EMAIL" roles/bigquery.jobUser
  remove_dataset_binding "$SA_HERMES_READER_EMAIL" roles/bigquery.dataViewer "$DATASET_MARTS"
  revoke_sa "$SA_HERMES_READER_EMAIL" "hermes-reader"
  info "Agent access revoked. Re-grant: 03-iam.sh + 'gcloud iam service-accounts enable'."
}

revoke_writer() {
  info "Revoking pipeline access ($SA_INGEST_WRITER_EMAIL)"
  remove_project_binding "$SA_INGEST_WRITER_EMAIL" roles/bigquery.jobUser
  for ds in $ALL_DATASETS; do
    remove_dataset_binding "$SA_INGEST_WRITER_EMAIL" roles/bigquery.dataEditor "$ds"
  done
  revoke_sa "$SA_INGEST_WRITER_EMAIL" "ingest-writer"
}

full_teardown() {
  info "FULL teardown: deleting all datasets and service accounts"
  for ds in $ALL_DATASETS; do
    run $BQ rm -r -f -d "$GCP_PROJECT_ID:$ds"
  done
  for email in "$SA_HERMES_READER_EMAIL" "$SA_INGEST_WRITER_EMAIL"; do
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
    confirm "IRREVERSIBLE: this DELETES every dataset (all data!) and both service accounts in $GCP_PROJECT_ID." "$GCP_PROJECT_ID"
    revoke_agent
    revoke_writer
    full_teardown
    ;;
esac

info "Teardown ($MODE) complete for '$CLIENT_SLUG'."
