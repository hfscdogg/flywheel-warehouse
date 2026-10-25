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
#   --full          The above, plus DELETE everything the setup scripts made:
#                   every dataset, the vendor drop bucket, the agent endpoint
#                   (Cloud Run service) and its token secret, every connector
#                   secret, the workload identity pool with its providers
#                   (and any stray provider that accepts this repository's
#                   GitHub tokens; if the pool still holds a provider pinned
#                   to another repository, only WIF_POOL/github goes), the
#                   endpoint deployer's custom role, and every Flywheel
#                   service account. Irreversible (a deleted pool, provider
#                   or secret is recoverable for 30 days at most). Requires
#                   typing the project ID.
#
# Left behind by --full, because Google made them rather than these scripts:
# the APIs 05 and 07 enabled, and Cloud Run's own source-deploy bucket
# (run-sources-<project>-<region>) and Artifact Registry repository.
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
require_cmd gcloud gsutil bq python3

# Optional per-client overrides, as in 07-hermes-endpoint.sh and
# 10-endpoint-deployer.sh.
RUN_REGION="${RUN_REGION:-us-east4}"
HERMES_MCP_SERVICE="${HERMES_MCP_SERVICE:-hermes-mcp}"
TOKEN_SECRET="${HERMES_TOKEN_SECRET:-hermes-endpoint-token}"
SA_ENDPOINT_DEPLOYER="${SA_ENDPOINT_DEPLOYER:-endpoint-deployer}"
SA_ENDPOINT_DEPLOYER_EMAIL="${SA_ENDPOINT_DEPLOYER}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
BUCKET_LISTER_ROLE="flywheelSourceBucketLister"

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
  # Every dataset, not only marts: under AGENT_SCOPE=wide the agent reads
  # staging too, and a revoke that left that grant behind left the agent's
  # widest view in place behind a disabled account.
  for ds in $ALL_DATASETS $GA4_EXPORT_DATASET; do
    revoke_dataset_role "$SA_HERMES_READER_EMAIL" roles/bigquery.dataViewer "$ds"
  done
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

# Every secret the setup scripts made: each connector's (05), whether or not
# this client ingests that source, and the endpoint token (07).
flywheel_secrets() {
  local src s
  for src in zoho zohobilling dtools alarmdotcom qbo; do
    for s in $(source_secrets "$src"); do printf '%s\n' "$s"; done
  done
  printf '%s\n' "$TOKEN_SECRET"
}

# Every account the setup scripts made, and the rehearsal one nobody should
# have: hermes-reader, the pipeline identities, the endpoint deployer and
# builder (10, lib/common.sh converge_endpoint_builder), wif-rehearsal.
all_identities() {
  printf '%s\n' "$SA_HERMES_READER_EMAIL"
  pipeline_identities
  printf '%s\n%s\n%s\n' "$SA_ENDPOINT_DEPLOYER_EMAIL" "$SA_ENDPOINT_BUILDER_EMAIL" "$SA_WIF_REHEARSAL_EMAIL"
}

full_teardown() {
  info "FULL teardown: the endpoint, secrets, federation, data and accounts"

  # The endpoint first: it serves the agent until it is gone.
  if is_dry_run || probe gcloud run services describe "$HERMES_MCP_SERVICE" \
      --project "$GCP_PROJECT_ID" --region "$RUN_REGION"; then
    run gcloud run services delete "$HERMES_MCP_SERVICE" \
      --project "$GCP_PROJECT_ID" --region "$RUN_REGION" --quiet
  else
    info "Cloud Run service $HERMES_MCP_SERVICE already absent"
  fi

  for s in $(flywheel_secrets); do
    if is_dry_run || probe gcloud secrets describe "$s" --project "$GCP_PROJECT_ID"; then
      run gcloud secrets delete "$s" --project "$GCP_PROJECT_ID" --quiet
    fi
  done

  # GitHub's way in. Deleting the pool deletes its providers; a provider in
  # another pool that accepts this repository's tokens goes too. The pool is
  # shared: while it holds another repository's provider, only ours goes.
  if [ -n "${WIF_POOL:-}" ]; then
    delete_wif_federation
  fi

  for ds in $ALL_DATASETS; do
    if is_dry_run || probe $BQ show --format=none "$GCP_PROJECT_ID:$ds"; then
      run $BQ rm -r -f -d "$GCP_PROJECT_ID:$ds"
    fi
  done
  BUCKET="$(vendor_drop_bucket)"
  if is_dry_run || probe gsutil ls -b "gs://$BUCKET"; then
    run gsutil -m rm -r "gs://$BUCKET"
  fi

  # Strip before deleting: a deleted account's grants stay in every policy as
  # deleted:serviceAccount:<email>, and would sit there until someone looked.
  for email in $(all_identities); do
    strip_member_everywhere "$email"
    if is_dry_run || probe gcloud iam service-accounts describe "$email" --project "$GCP_PROJECT_ID"; then
      run gcloud iam service-accounts delete "$email" --project "$GCP_PROJECT_ID" --quiet
    fi
  done
  if is_dry_run || probe gcloud iam roles describe "$BUCKET_LISTER_ROLE" --project "$GCP_PROJECT_ID"; then
    run gcloud iam roles delete "$BUCKET_LISTER_ROLE" --project "$GCP_PROJECT_ID" --quiet
  fi
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
    confirm "IRREVERSIBLE: this DELETES every dataset and the vendor drop bucket (all data!), the agent endpoint, every Flywheel secret, the GitHub federation and every Flywheel service account in $GCP_PROJECT_ID." "$GCP_PROJECT_ID"
    revoke_agent
    revoke_writer
    full_teardown
    ;;
esac

info "Teardown ($MODE) complete for '$CLIENT_SLUG'."
