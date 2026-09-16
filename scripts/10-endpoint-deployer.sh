#!/usr/bin/env bash
# 10-endpoint-deployer.sh <client-slug> [revoke]
#
# Creates the service account GitHub Actions uses to REDEPLOY the agent
# endpoint, and nothing else. Run once per client, by a human, after
# 07-hermes-endpoint.sh has deployed the service for the first time.
#
# WHY A SEPARATE IDENTITY
# ingest-writer already exists and every ingest workflow impersonates it, so
# reusing it here would be one line. It is the wrong line: that account holds
# dataEditor on every dataset, and adding deploy rights to it means any
# workflow that can write BigQuery can also ship a new revision of the agent
# endpoint. These are unrelated powers and they get unrelated identities.
#
# WHY NOT JUST GIVE IT WHAT 'deploy' NEEDS
# 07's `deploy` action also enables APIs, creates the token secret, and runs
# `gcloud projects add-iam-policy-binding`. An identity that can do that can
# rewrite the project's IAM policy, which is not a power a CI job should hold
# to ship a container. So this grants only what `redeploy` needs, and
# `redeploy` refuses to bootstrap — the first deploy stays a human's job.
#
# WHAT IT GETS, AND WHERE
#   run.admin                on THE ONE SERVICE, not the project. Deploying a
#                            revision and keeping --allow-unauthenticated set
#                            needs admin on the service; scoping it to the
#                            resource means this account cannot create,
#                            delete, or touch any other Cloud Run service.
#   iam.serviceAccountUser   on hermes-reader ONLY. Required to deploy a
#                            service that RUNS AS hermes-reader. Scoped to the
#                            one account, so it cannot act as ingest-writer.
#   cloudbuild.builds.editor \ `gcloud run deploy --source` builds the image
#   artifactregistry.writer   } with Cloud Build and pushes it. These are
#   storage.objectAdmin      / project-level because the build staging bucket
#                            and registry are project resources.
#
# It gets NO BigQuery access, NO Secret Manager access, and no ability to
# change IAM. Read the grants back with:
#   gcloud projects get-iam-policy $GCP_PROJECT_ID \
#     --flatten=bindings[].members --filter="bindings.members:endpoint-deployer"
#
# `revoke` removes the WIF binding, which cuts GitHub off immediately while
# leaving the account and its grants intact for a later re-bind.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0 <client-slug> [revoke]"
load_client "$1"
ACTION="${2:-grant}"
require_cmd gcloud

if [ -z "${GITHUB_REPO:-}" ] || [ -z "${WIF_POOL:-}" ]; then
  die "GITHUB_REPO and WIF_POOL must be set in clients/$CLIENT_SLUG/client.env"
fi

SA_ENDPOINT_DEPLOYER="${SA_ENDPOINT_DEPLOYER:-endpoint-deployer}"
SA_ENDPOINT_DEPLOYER_EMAIL="${SA_ENDPOINT_DEPLOYER}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
RUN_REGION="${RUN_REGION:-us-east4}"
HERMES_MCP_SERVICE="${HERMES_MCP_SERVICE:-hermes-mcp}"

POOL_NAME="$(gcloud iam workload-identity-pools describe "$WIF_POOL" \
  --project "$GCP_PROJECT_ID" --location=global --format='value(name)' 2>/dev/null || true)"
[ -n "$POOL_NAME" ] || is_dry_run || die "workload identity pool '$WIF_POOL' not found — run 05-ingestion-infra.sh first"

if [ "$ACTION" = "revoke" ]; then
  info "Revoking GitHub's ability to impersonate $SA_ENDPOINT_DEPLOYER"
  run gcloud iam service-accounts remove-iam-policy-binding "$SA_ENDPOINT_DEPLOYER_EMAIL" \
    --project "$GCP_PROJECT_ID" \
    --role=roles/iam.workloadIdentityUser \
    --member="principalSet://iam.googleapis.com/$POOL_NAME/attribute.repository/$GITHUB_REPO" \
    --format=none --quiet
  log "  the account and its grants remain; re-run without 'revoke' to restore"
  exit 0
fi

info "Service account: $SA_ENDPOINT_DEPLOYER_EMAIL"
if probe gcloud iam service-accounts describe "$SA_ENDPOINT_DEPLOYER_EMAIL" --project "$GCP_PROJECT_ID"; then
  log "  exists"
else
  run gcloud iam service-accounts create "$SA_ENDPOINT_DEPLOYER" \
    --project "$GCP_PROJECT_ID" \
    --display-name="Flywheel agent-endpoint deployer (CI)" \
    --description="Redeploys the hermes-mcp Cloud Run service from GitHub Actions. No BigQuery, no Secret Manager, no IAM admin."
fi

# Service-scoped, not project-scoped. The service must already exist, which is
# the point: the first deploy is a human's, and this account cannot make one.
info "run.admin on the service '$HERMES_MCP_SERVICE' only"
if probe gcloud run services describe "$HERMES_MCP_SERVICE" \
     --project "$GCP_PROJECT_ID" --region "$RUN_REGION"; then
  run gcloud run services add-iam-policy-binding "$HERMES_MCP_SERVICE" \
    --project "$GCP_PROJECT_ID" --region "$RUN_REGION" \
    --member="serviceAccount:$SA_ENDPOINT_DEPLOYER_EMAIL" \
    --role=roles/run.admin --format=none --quiet
elif ! is_dry_run; then
  die "service '$HERMES_MCP_SERVICE' not found in $RUN_REGION — run '07-hermes-endpoint.sh $CLIENT_SLUG deploy' first; this script grants rights ON that service and cannot precede it"
fi

info "serviceAccountUser on $SA_HERMES_READER (deploy a service that runs as it)"
run gcloud iam service-accounts add-iam-policy-binding "$SA_HERMES_READER_EMAIL" \
  --project "$GCP_PROJECT_ID" \
  --member="serviceAccount:$SA_ENDPOINT_DEPLOYER_EMAIL" \
  --role=roles/iam.serviceAccountUser --format=none --quiet

# Project-level, because a source deploy builds through Cloud Build and pushes
# to Artifact Registry, and both are project resources. If a deploy ever fails
# at "Uploading sources" or on the registry push, the missing role is one of
# these three — add it here rather than widening to a broader role.
info "Cloud Build + Artifact Registry + build staging (source deploys)"
for role in roles/cloudbuild.builds.editor roles/artifactregistry.writer roles/storage.objectAdmin; do
  run gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
    --member="serviceAccount:$SA_ENDPOINT_DEPLOYER_EMAIL" \
    --role="$role" --condition=None --format=none --quiet
done

info "Binding: this repo's workflows may impersonate $SA_ENDPOINT_DEPLOYER"
run gcloud iam service-accounts add-iam-policy-binding "$SA_ENDPOINT_DEPLOYER_EMAIL" \
  --project "$GCP_PROJECT_ID" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/$POOL_NAME/attribute.repository/$GITHUB_REPO" \
  --format=none --quiet

log ""
info "Done. Set this as a GitHub Actions repository variable:"
log "  WIF_DEPLOYER_SERVICE_ACCOUNT = $SA_ENDPOINT_DEPLOYER_EMAIL"
log ""
log "  Then gate it: Settings -> Environments -> 'endpoint' -> Required reviewers."
log "  Without that environment the deploy workflow still runs, but with no"
log "  human in the loop, which is the thing the split was for."
