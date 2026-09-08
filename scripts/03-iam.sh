#!/usr/bin/env bash
# 03-iam.sh <client-slug> — every IAM binding, in one auditable place.
#
# The trust surface (docs/trust.md) is defined here:
#   hermes-reader : jobUser (project) + dataViewer on marts — and on staging
#                   too when the client's AGENT_SCOPE is "wide" (Tier 2b)
#   ingest-writer : jobUser (project) + dataEditor (each dataset, dataset-level)
#   ADMIN_USER    : serviceAccountTokenCreator on the hermes-reader SA
#
# hermes-reader deliberately gets NOTHING on raw_*, ever. Staging is the
# client's call (AGENT_SCOPE); raw is not.
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
require_cmd gcloud bq python3

# grant_dataset_role <sa-email> <role> <dataset>
# Dataset-level grants via dataset access entries (bq show → append → bq
# update --source). 'bq add-iam-policy-binding' on a DATASET needs Google
# allowlisting; access entries are the GA mechanism for the same grant.
# Check-then-converge: no-op when the entry already exists.
grant_dataset_role() {
  ds_email="$1"; ds_role="$2"; ds_name="$3"
  if is_dry_run; then
    log "[dry-run] bq update --source <access+={\"role\":\"$ds_role\",\"userByEmail\":\"$ds_email\"}> $GCP_PROJECT_ID:$ds_name"
    return 0
  fi
  ds_tmp="$(mktemp)"
  $BQ show --format=prettyjson "$GCP_PROJECT_ID:$ds_name" > "$ds_tmp"
  if DS_EMAIL="$ds_email" DS_ROLE="$ds_role" python3 - "$ds_tmp" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
email, role = os.environ["DS_EMAIL"], os.environ["DS_ROLE"]
# BigQuery stores premium role strings as legacy names in the access array.
LEGACY = {"roles/bigquery.dataViewer": "READER",
          "roles/bigquery.dataEditor": "WRITER",
          "roles/bigquery.dataOwner": "OWNER"}
wanted = {role, LEGACY.get(role, role)}
with open(path) as f:
    ds = json.load(f)
access = ds.get("access", [])
if any(e.get("userByEmail") == email and e.get("role") in wanted for e in access):
    sys.exit(3)  # already present — converged
access.append({"role": role, "userByEmail": email})
with open(path, "w") as f:
    json.dump({"access": access}, f)
sys.exit(0)
PYEOF
  then
    run $BQ update --source "$ds_tmp" "$GCP_PROJECT_ID:$ds_name"
    log "  granted $ds_role to $ds_email on $ds_name"
  else
    rc=$?
    if [ "$rc" -eq 3 ]; then
      log "  $ds_email already has $ds_role on $ds_name — converging"
    else
      rm -f "$ds_tmp"
      die "failed to compute access entries for $GCP_PROJECT_ID:$ds_name"
    fi
  fi
  rm -f "$ds_tmp"
}

info "IAM bindings for '$CLIENT_SLUG' in $GCP_PROJECT_ID"

info "hermes-reader: query jobs at project level"
run gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:$SA_HERMES_READER_EMAIL" \
  --role=roles/bigquery.jobUser --condition=None --format=none --quiet

info "hermes-reader: read access on $DATASETS_AGENT (AGENT_SCOPE=$AGENT_SCOPE)"
for ds in $DATASETS_AGENT; do
  grant_dataset_role "$SA_HERMES_READER_EMAIL" roles/bigquery.dataViewer "$ds"
done

info "ingest-writer: query jobs at project level"
run gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:$SA_INGEST_WRITER_EMAIL" \
  --role=roles/bigquery.jobUser --condition=None --format=none --quiet

info "ingest-writer: dataset-level write access (not project-level)"
for ds in $ALL_DATASETS; do
  grant_dataset_role "$SA_INGEST_WRITER_EMAIL" roles/bigquery.dataEditor "$ds"
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
