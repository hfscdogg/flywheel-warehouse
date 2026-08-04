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

# revoke_dataset_role <sa-email> <role> <dataset>
# Mirror of grant_dataset_role in 03-iam.sh: dataset-level revocation via
# access entries ('bq remove-iam-policy-binding' on a dataset needs Google
# allowlisting). Accepts both premium and legacy role names in the access
# array (dataViewer→READER, dataEditor→WRITER). Re-runnable: absent entry
# or absent dataset is a no-op.
revoke_dataset_role() {
  ds_email="$1"; ds_role="$2"; ds_name="$3"
  if is_dry_run; then
    log "[dry-run] bq update --source <access-={\"role\":\"$ds_role\",\"userByEmail\":\"$ds_email\"}> $GCP_PROJECT_ID:$ds_name"
    return 0
  fi
  if ! probe $BQ show --format=none "$GCP_PROJECT_ID:$ds_name"; then
    info "dataset $ds_name absent — nothing to revoke"
    return 0
  fi
  ds_tmp="$(mktemp)"
  $BQ show --format=prettyjson "$GCP_PROJECT_ID:$ds_name" > "$ds_tmp"
  if DS_EMAIL="$ds_email" DS_ROLE="$ds_role" python3 - "$ds_tmp" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
email, role = os.environ["DS_EMAIL"], os.environ["DS_ROLE"]
LEGACY = {"roles/bigquery.dataViewer": "READER",
          "roles/bigquery.dataEditor": "WRITER",
          "roles/bigquery.dataOwner": "OWNER"}
wanted = {role, LEGACY.get(role, role)}
with open(path) as f:
    ds = json.load(f)
access = ds.get("access", [])
kept = [e for e in access
        if not (e.get("userByEmail") == email and e.get("role") in wanted)]
if len(kept) == len(access):
    sys.exit(3)  # already absent — converged
with open(path, "w") as f:
    json.dump({"access": kept}, f)
sys.exit(0)
PYEOF
  then
    run $BQ update --source "$ds_tmp" "$GCP_PROJECT_ID:$ds_name"
    log "  revoked $ds_role from $ds_email on $ds_name"
  else
    rc=$?
    if [ "$rc" -eq 3 ]; then
      info "dataset grant $ds_role for $ds_email on $ds_name already absent"
    else
      rm -f "$ds_tmp"
      die "failed to compute access entries for $GCP_PROJECT_ID:$ds_name"
    fi
  fi
  rm -f "$ds_tmp"
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
  revoke_dataset_role "$SA_HERMES_READER_EMAIL" roles/bigquery.dataViewer "$DATASET_MARTS"
  revoke_sa "$SA_HERMES_READER_EMAIL" "hermes-reader"
  info "Agent access revoked. Re-grant: 03-iam.sh + 'gcloud iam service-accounts enable'."
}

revoke_writer() {
  info "Revoking pipeline access ($SA_INGEST_WRITER_EMAIL)"
  remove_project_binding "$SA_INGEST_WRITER_EMAIL" roles/bigquery.jobUser
  for ds in $ALL_DATASETS; do
    revoke_dataset_role "$SA_INGEST_WRITER_EMAIL" roles/bigquery.dataEditor "$ds"
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
