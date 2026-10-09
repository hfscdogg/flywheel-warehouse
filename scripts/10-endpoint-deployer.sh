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
#   artifactregistry.writer  / with Cloud Build and pushes it. Project-level,
#                            because both are project resources.
#   iam.serviceAccountUser   on endpoint-builder ONLY. The source build runs
#                            as that account (lib/common.sh), and starting a
#                            build that runs as an account needs actAs on it.
#                            Never on the default compute account, which
#                            usually holds project Editor.
#   storage.buckets.list     at project level, through a custom role holding
#                            that one permission. `gcloud run deploy --source`
#                            lists buckets to find its staging bucket before
#                            it uploads; the list shows bucket names and
#                            metadata, never contents.
#   storage.admin            on the ONE bucket Cloud Run stages source uploads
#                            through (run-sources-<project>-<region>), never
#                            the project. objectAdmin is NOT enough: the
#                            upload calls storage.buckets.get, which is a
#                            bucket-level permission objectAdmin lacks.
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

if is_dry_run; then
  POOL_NAME="projects/<project-number>/locations/global/workloadIdentityPools/$WIF_POOL"
else
  POOL_NAME="$(gcloud iam workload-identity-pools describe "$WIF_POOL" \
    --project "$GCP_PROJECT_ID" --location=global --format='value(name)' 2>/dev/null || true)"
  [ -n "$POOL_NAME" ] || die "workload identity pool '$WIF_POOL' not found — run 05-ingestion-infra.sh first"
fi

# Only deploy-endpoint.yml, on WIF_ALLOWED_REF, may act as this account. That
# file is the one with `environment: endpoint`, so the approval gate cannot be
# stepped around by a different workflow, or this one on another branch.
DEPLOY_MEMBER="$(wif_workflow_member "$POOL_NAME" deploy-endpoint.yml)"
# What this script bound before 2026-10-09: any workflow, any branch.
LEGACY_MEMBER="$(wif_repo_member "$POOL_NAME")"

if [ "$ACTION" = "revoke" ]; then
  info "Revoking GitHub's ability to impersonate $SA_ENDPOINT_DEPLOYER"
  for member in "$DEPLOY_MEMBER" "$LEGACY_MEMBER"; do
    remove_resource_binding "iam service-accounts" "$SA_ENDPOINT_DEPLOYER_EMAIL" \
      "$member" roles/iam.workloadIdentityUser
  done
  log "  the account and its grants remain; re-run without 'revoke' to restore"
  exit 0
fi

# The pinned binding matches on attribute.job_workflow_ref, which a provider
# made before 2026-10-09 does not map. Binding to it there would match
# nothing, and removing the repo-wide binding below would then break deploys.
if ! is_dry_run; then
  MAPPING="$(gcloud iam workload-identity-pools providers describe github \
    --project "$GCP_PROJECT_ID" --location=global --workload-identity-pool="$WIF_POOL" \
    --format='value(attributeMapping)' 2>/dev/null || true)"
  case "$MAPPING" in
    *job_workflow_ref*) : ;;
    *) die "the WIF provider does not map job_workflow_ref yet — run 05-ingestion-infra.sh $CLIENT_SLUG first" ;;
  esac
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
# to Artifact Registry, and both are project resources.
info "Cloud Build + Artifact Registry (source deploys)"
for role in roles/cloudbuild.builds.editor roles/artifactregistry.writer; do
  run gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
    --member="serviceAccount:$SA_ENDPOINT_DEPLOYER_EMAIL" \
    --role="$role" --condition=None --format=none --quiet
done

# THE BUILD RUNS AS endpoint-builder, AND THIS ACCOUNT MAY ACT AS IT ONLY.
# Before 2026-09-28 the build ran as the project's default compute account,
# which usually holds Editor on the project; allowing this account to act as
# that one would have made it a project editor. converge_endpoint_builder
# (lib/common.sh) creates the build account with roles/run.builder and
# nothing else, and is idempotent, so running this script alone is enough
# for a client whose endpoint was first deployed before the build account
# existed.
converge_endpoint_builder

info "serviceAccountUser on $SA_ENDPOINT_BUILDER (start a build that runs as it)"
run gcloud iam service-accounts add-iam-policy-binding "$SA_ENDPOINT_BUILDER_EMAIL" \
  --project "$GCP_PROJECT_ID" \
  --member="serviceAccount:$SA_ENDPOINT_DEPLOYER_EMAIL" \
  --role=roles/iam.serviceAccountUser --format=none --quiet

# storage.buckets.list IS A PROJECT PERMISSION, SO IT CANNOT BE BUCKET-SCOPED.
# `gcloud run deploy --source` lists the project's buckets to find its
# staging bucket before uploading, and the run on 2026-09-28 failed on it:
#   ERROR: ... does not have storage.buckets.list access to the Google Cloud
#   project. Permission 'storage.buckets.list' denied ...
# No predefined role holds only that permission, so a custom role carries
# exactly that one: it shows bucket names and metadata, never contents.
BUCKET_LISTER_ROLE="flywheelSourceBucketLister"
info "custom role $BUCKET_LISTER_ROLE: storage.buckets.list only (project)"
if probe gcloud iam roles describe "$BUCKET_LISTER_ROLE" --project "$GCP_PROJECT_ID"; then
  run gcloud iam roles update "$BUCKET_LISTER_ROLE" --project "$GCP_PROJECT_ID" \
    --permissions=storage.buckets.list --quiet --format=none
else
  run gcloud iam roles create "$BUCKET_LISTER_ROLE" --project "$GCP_PROJECT_ID" \
    --title="Flywheel source-deploy bucket lister" \
    --description="storage.buckets.list only: lets gcloud run deploy --source find its staging bucket." \
    --permissions=storage.buckets.list --stage=GA --quiet --format=none
fi
run gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:$SA_ENDPOINT_DEPLOYER_EMAIL" \
  --role="projects/$GCP_PROJECT_ID/roles/$BUCKET_LISTER_ROLE" \
  --condition=None --format=none --quiet

# THE STAGING BUCKET NEEDS storage.admin, NOT objectAdmin, AND THE DIFFERENCE
# IS NOT COSMETIC. `gcloud run deploy --source` stages the upload through a
# Cloud Run-managed bucket and calls storage.buckets.get on it first.
# objectAdmin grants permissions on OBJECTS; buckets.get is a BUCKET-level
# permission and is not in it. The first real deploy through this account
# failed on exactly that, five seconds in:
#
#   Uploading sources.....failed
#   ERROR: ... does not have storage.buckets.get access to the Google Cloud
#   Storage bucket ... 'run-sources-livewire-dw-us-east4'
#
# Granted on THAT ONE BUCKET rather than the project, which is the same
# judgement as run.admin on the one service: this account can stage a build
# and nothing else in Cloud Storage. The bucket name is what Cloud Run
# derives, run-sources-<project>-<region>, and it is created by the first
# source deploy — which is one more reason a human runs `deploy` before this
# script, since a bucket that does not exist cannot be granted on.
BUILD_BUCKET="run-sources-${GCP_PROJECT_ID}-${RUN_REGION}"
info "storage.admin on gs://$BUILD_BUCKET only (source upload staging)"
if probe gcloud storage buckets describe "gs://$BUILD_BUCKET" --project "$GCP_PROJECT_ID"; then
  run gcloud storage buckets add-iam-policy-binding "gs://$BUILD_BUCKET" \
    --project "$GCP_PROJECT_ID" \
    --member="serviceAccount:$SA_ENDPOINT_DEPLOYER_EMAIL" \
    --role=roles/storage.admin --format=none --quiet
elif ! is_dry_run; then
  warn "build staging bucket gs://$BUILD_BUCKET not found — Cloud Run creates it on"
  warn "the first --source deploy. Run '07-hermes-endpoint.sh $CLIENT_SLUG deploy'"
  warn "from an admin session once, then re-run this script to grant on it."
fi

info "Binding: deploy-endpoint.yml on $WIF_ALLOWED_REF may impersonate $SA_ENDPOINT_DEPLOYER"
run gcloud iam service-accounts add-iam-policy-binding "$SA_ENDPOINT_DEPLOYER_EMAIL" \
  --project "$GCP_PROJECT_ID" \
  --role=roles/iam.workloadIdentityUser \
  --member="$DEPLOY_MEMBER" \
  --format=none --quiet
info "Removing the repo-wide binding (any workflow, any branch), if present"
remove_resource_binding "iam service-accounts" "$SA_ENDPOINT_DEPLOYER_EMAIL" \
  "$LEGACY_MEMBER" roles/iam.workloadIdentityUser

log ""
info "Done. Set this as a GitHub Actions repository variable:"
log "  WIF_DEPLOYER_SERVICE_ACCOUNT = $SA_ENDPOINT_DEPLOYER_EMAIL"
log ""
log "  Then gate it: Settings -> Environments -> 'endpoint' -> Required reviewers."
log "  Without that environment the deploy workflow still runs, but with no"
log "  human in the loop, which is the thing the split was for."
