#!/usr/bin/env bash
# 05-ingestion-infra.sh <client-slug> — Phase 2 infrastructure: Workload
# Identity Federation for GitHub Actions + Secret Manager containers for
# source-system credentials.
#
# Credential model (docs/trust.md): ALL source credentials (Zoho, D-Tools,
# QBO) live in Secret Manager inside the client's own project. GitHub holds
# no client secrets — workflows authenticate via WIF (OIDC, no key files)
# and read credentials at runtime as their source's own ingest account,
# which can read that source's secrets and no others. The QBO and D-Tools v2
# refresh tokens rotate; their accounts can add new versions of those only.
#
# Trust is pinned to a workflow FILE on ONE branch. GitHub signs
# job_workflow_ref (<owner>/<repo>/.github/workflows/<file>@<ref>) into every
# Actions token, and each account trusts only the workflow files that do its
# job, on WIF_ALLOWED_REF (main). Before 2026-10-09 every account trusted the
# whole repository, so any workflow on any branch could act as any of them,
# including the endpoint deployer, skipping its approval gate.
#
# CUTOVER for a client set up before then: docs/runbook-identity-cutover.md.
# This script only ADDS: the old repo-wide binding on ingest-writer stays
# until 11-retire-ingest-writer.sh removes it, so the nightly pipelines keep
# running until each workflow's repository variable points at its new account.
#
# Requires GITHUB_REPO and WIF_POOL in client.env (the "Phase 2" block).
# Idempotent: check-then-converge throughout. DRY_RUN=1 supported.
# shellcheck disable=SC2086  # $GCLOUD flag strings are intentionally word-split
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0"
load_client "$1"
require_cmd gcloud

if [ -z "${GITHUB_REPO:-}" ] || [ -z "${WIF_POOL:-}" ]; then
  die "GITHUB_REPO and WIF_POOL must be set in clients/$CLIENT_SLUG/client.env (uncomment the Phase 2 block)"
fi

SECRET_LABELS="managed-by=$LABEL_MANAGED_BY,client=$CLIENT_SLUG,env=$LABEL_ENV"

info "Phase 2 infra for '$CLIENT_SLUG' in $GCP_PROJECT_ID (repo: $GITHUB_REPO)"

info "Enabling APIs (secretmanager, sts)"
run gcloud services enable secretmanager.googleapis.com sts.googleapis.com \
  --project "$GCP_PROJECT_ID" --quiet

# ── Workload Identity Federation ─────────────────────────────────────────
info "Workload identity pool: $WIF_POOL"
if probe gcloud iam workload-identity-pools describe "$WIF_POOL" \
    --project "$GCP_PROJECT_ID" --location=global; then
  info "pool exists — converging nothing (immutable fields)"
else
  run gcloud iam workload-identity-pools create "$WIF_POOL" \
    --project "$GCP_PROJECT_ID" --location=global \
    --display-name="Flywheel GitHub Actions"
fi

# job_workflow_ref is what the bindings below match on; ref and the condition
# refuse a token from any branch but WIF_ALLOWED_REF before a binding is even
# consulted. repository stays mapped so the retired repo-wide binding keeps
# working until 11-retire-ingest-writer.sh removes it.
WIF_ATTRIBUTE_MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.job_workflow_ref=assertion.job_workflow_ref"
WIF_ATTRIBUTE_CONDITION="assertion.repository == '$GITHUB_REPO' && assertion.ref == '$WIF_ALLOWED_REF'"

info "OIDC provider: github (repo $GITHUB_REPO, ref $WIF_ALLOWED_REF only)"
if probe gcloud iam workload-identity-pools providers describe github \
    --project "$GCP_PROJECT_ID" --location=global \
    --workload-identity-pool="$WIF_POOL"; then
  # A provider made before 2026-10-09 trusts the whole repo and maps no
  # job_workflow_ref, so without this the pinned bindings below would match
  # nothing. update-oidc with the same values is a no-op.
  info "provider exists — converging mapping and condition"
  run gcloud iam workload-identity-pools providers update-oidc github \
    --project "$GCP_PROJECT_ID" --location=global \
    --workload-identity-pool="$WIF_POOL" \
    --attribute-mapping="$WIF_ATTRIBUTE_MAPPING" \
    --attribute-condition="$WIF_ATTRIBUTE_CONDITION"
else
  run gcloud iam workload-identity-pools providers create-oidc github \
    --project "$GCP_PROJECT_ID" --location=global \
    --workload-identity-pool="$WIF_POOL" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="$WIF_ATTRIBUTE_MAPPING" \
    --attribute-condition="$WIF_ATTRIBUTE_CONDITION"
fi

if is_dry_run; then
  POOL_NAME="projects/<project-number>/locations/global/workloadIdentityPools/$WIF_POOL"
else
  POOL_NAME="$(gcloud iam workload-identity-pools describe "$WIF_POOL" \
    --project "$GCP_PROJECT_ID" --location=global --format='value(name)')"
fi

# bind_workflow <sa-email> <workflow-file>: that file, on WIF_ALLOWED_REF, may
# act as that account. Nothing else may.
bind_workflow() {
  run gcloud iam service-accounts add-iam-policy-binding "$1" \
    --project "$GCP_PROJECT_ID" \
    --role=roles/iam.workloadIdentityUser \
    --member="$(wif_workflow_member "$POOL_NAME" "$2")" \
    --format=none --quiet
}

# ── Ingest: one account per source ───────────────────────────────────────
for src in $INGEST_SOURCES; do
  email="$(ingest_sa_email "$src")"
  info "raw_$src: $(ingest_sa_name "$src")"
  for wf in $(source_workflows "$src"); do
    log "  trusted workflow: $wf"
    bind_workflow "$email" "$wf"
  done

  # Secret containers (values loaded by a human — docs/phase-2-credentials.md)
  for s in $(source_secrets "$src"); do
    if probe gcloud secrets describe "$s" --project "$GCP_PROJECT_ID"; then
      log "  secret $s exists"
    else
      run gcloud secrets create "$s" --project "$GCP_PROJECT_ID" \
        --replication-policy=automatic --labels="$SECRET_LABELS"
    fi
    run gcloud secrets add-iam-policy-binding "$s" --project "$GCP_PROJECT_ID" \
      --member="serviceAccount:$email" \
      --role=roles/secretmanager.secretAccessor --format=none --quiet
  done

  # The pipeline writes a rotated refresh token back; these secrets only.
  for s in $(source_rotating_secrets "$src"); do
    log "  rotation writeback: may add versions of $s"
    run gcloud secrets add-iam-policy-binding "$s" --project "$GCP_PROJECT_ID" \
      --member="serviceAccount:$email" \
      --role=roles/secretmanager.secretVersionAdder --format=none --quiet
  done
done

# ── Transform and probe: no secrets ──────────────────────────────────────
info "transform.yml: $SA_TRANSFORM"
bind_workflow "$SA_TRANSFORM_EMAIL" transform.yml
info "probe.yml: $SA_PROBE"
bind_workflow "$SA_PROBE_EMAIL" probe.yml

# ── Handoff ──────────────────────────────────────────────────────────────
if is_dry_run; then
  PROVIDER_NAME="$POOL_NAME/providers/github"
else
  PROVIDER_NAME="$(gcloud iam workload-identity-pools providers describe github \
    --project "$GCP_PROJECT_ID" --location=global \
    --workload-identity-pool="$WIF_POOL" --format='value(name)')"
fi

log ""
info "Phase 2 infra done. Two manual steps remain:"
log ""
log "1. Set the repo's GitHub *variables* (not secrets — these aren't sensitive):"
log "     gh variable set WIF_PROVIDER --repo $GITHUB_REPO --body '$PROVIDER_NAME'"
for src in $INGEST_SOURCES; do
  log "     gh variable set $(ingest_sa_var "$src") --repo $GITHUB_REPO --body '$(ingest_sa_email "$src")'"
done
log "     gh variable set WIF_SA_TRANSFORM --repo $GITHUB_REPO --body '$SA_TRANSFORM_EMAIL'"
log "     gh variable set WIF_SA_PROBE --repo $GITHUB_REPO --body '$SA_PROBE_EMAIL'"
log ""
log "2. Load the credential values into Secret Manager:"
log "     see docs/phase-2-credentials.md (the three OAuth walkthroughs)"
log ""
log "A client that still has ingest-writer: once a run of each workflow has"
log "passed on its new account, ./scripts/11-retire-ingest-writer.sh $CLIENT_SLUG"
