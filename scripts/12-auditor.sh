#!/usr/bin/env bash
# 12-auditor.sh <client-slug> — the read-only identity behind audit.yml.
#
# audit.yml runs a fixed set of read-only checks (91-verify-pipelines.sh,
# 92-iam-snapshot.sh) from GitHub Actions, so they can be run and read
# without a human pasting commands into Cloud Shell. It runs as `auditor`,
# which this script creates, trusted from audit.yml on WIF_ALLOWED_REF and
# nothing else.
#
# What auditor can do, and why each role:
#   roles/iam.securityReviewer            read every IAM policy, list accounts
#                                         and their key ids, list custom roles
#   roles/iam.workloadIdentityPoolViewer  read the WIF pools and providers
#   roles/bigquery.metadataViewer         read datasets' access lists and table
#                                         metadata; NOT table data
#   roles/secretmanager.viewer            list secrets and versions, read their
#                                         policies; NOT secret values
#   roles/run.viewer                      read Cloud Run services and policies
#   roles/storage.bucketViewer            list buckets; NOT objects
#
# What it cannot do: read a row of any table, read a secret's value, read an
# object, run a query (no bigquery.jobUser), or change anything. None of the
# roles above holds a set*, create*, update* or delete* permission.
#
# Idempotent. DRY_RUN=1 prints the plan. Reversible:
#   gcloud iam service-accounts disable auditor@<project>.iam.gserviceaccount.com
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0"
load_client "$1"
require_cmd gcloud

if [ -z "${GITHUB_REPO:-}" ] || [ -z "${WIF_POOL:-}" ]; then
  die "GITHUB_REPO and WIF_POOL must be set in clients/$CLIENT_SLUG/client.env"
fi

AUDITOR_ROLES="roles/iam.securityReviewer roles/iam.workloadIdentityPoolViewer
roles/bigquery.metadataViewer roles/secretmanager.viewer roles/run.viewer
roles/storage.bucketViewer"

info "$SA_AUDITOR: read-only audit identity for audit.yml"
if is_dry_run || ! probe gcloud iam service-accounts describe "$SA_AUDITOR_EMAIL" --project "$GCP_PROJECT_ID"; then
  run gcloud iam service-accounts create "$SA_AUDITOR" --project "$GCP_PROJECT_ID" \
    --display-name="Flywheel auditor (read-only)" \
    --description="audit.yml only. Reads policies and metadata; no data, no secret values, no writes."
  if ! is_dry_run; then
    retry 12 5 probe gcloud iam service-accounts describe "$SA_AUDITOR_EMAIL" --project "$GCP_PROJECT_ID" \
      || die "service account $SA_AUDITOR_EMAIL not visible after creation"
  fi
else
  log "  $SA_AUDITOR_EMAIL exists"
fi

for role in $AUDITOR_ROLES; do
  run gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
    --member="serviceAccount:$SA_AUDITOR_EMAIL" --role="$role" \
    --condition=None --format=none --quiet
done

if is_dry_run; then
  POOL_NAME="projects/<project-number>/locations/global/workloadIdentityPools/$WIF_POOL"
else
  POOL_NAME="$(gcloud iam workload-identity-pools describe "$WIF_POOL" \
    --project "$GCP_PROJECT_ID" --location=global --format='value(name)')"
fi
log "  trusted workflow: audit.yml"
run gcloud iam service-accounts add-iam-policy-binding "$SA_AUDITOR_EMAIL" \
  --project "$GCP_PROJECT_ID" \
  --role=roles/iam.workloadIdentityUser \
  --member="$(wif_workflow_member "$POOL_NAME" audit.yml)" \
  --format=none --quiet

log ""
info "Then point the workflow at it:"
log "    gh variable set WIF_SA_AUDIT --repo $GITHUB_REPO --body $SA_AUDITOR_EMAIL"
