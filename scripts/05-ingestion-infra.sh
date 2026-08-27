#!/usr/bin/env bash
# 05-ingestion-infra.sh <client-slug> — Phase 2 infrastructure: Workload
# Identity Federation for GitHub Actions + Secret Manager containers for
# source-system credentials.
#
# Credential model (docs/trust.md): ALL source credentials (Zoho, D-Tools,
# QBO) live in Secret Manager inside the client's own project. GitHub holds
# no client secrets — workflows authenticate via WIF (OIDC, no key files)
# and read credentials at runtime as ingest-writer. The QBO refresh token
# rotates; ingest-writer can add new versions of that one secret only.
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

SECRET_NAMES="flywheel-zoho-client-id flywheel-zoho-client-secret flywheel-zoho-refresh-token \
flywheel-zohobilling-client-id flywheel-zohobilling-client-secret flywheel-zohobilling-refresh-token \
flywheel-dtools-api-key \
flywheel-qbo-client-id flywheel-qbo-client-secret flywheel-qbo-refresh-token flywheel-qbo-realm-id"
ROTATING_SECRET="flywheel-qbo-refresh-token"
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

info "OIDC provider: github (locked to repo $GITHUB_REPO)"
if probe gcloud iam workload-identity-pools providers describe github \
    --project "$GCP_PROJECT_ID" --location=global \
    --workload-identity-pool="$WIF_POOL"; then
  info "provider exists"
else
  run gcloud iam workload-identity-pools providers create-oidc github \
    --project "$GCP_PROJECT_ID" --location=global \
    --workload-identity-pool="$WIF_POOL" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository == '$GITHUB_REPO'"
fi

if is_dry_run; then
  POOL_NAME="projects/<project-number>/locations/global/workloadIdentityPools/$WIF_POOL"
else
  POOL_NAME="$(gcloud iam workload-identity-pools describe "$WIF_POOL" \
    --project "$GCP_PROJECT_ID" --location=global --format='value(name)')"
fi

info "Binding: this repo's workflows may impersonate ingest-writer"
run gcloud iam service-accounts add-iam-policy-binding "$SA_INGEST_WRITER_EMAIL" \
  --project "$GCP_PROJECT_ID" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/$POOL_NAME/attribute.repository/$GITHUB_REPO" \
  --format=none --quiet

# ── Secret containers ────────────────────────────────────────────────────
info "Secret containers (values loaded by a human — docs/phase-2-credentials.md)"
for s in $SECRET_NAMES; do
  if probe gcloud secrets describe "$s" --project "$GCP_PROJECT_ID"; then
    info "secret $s exists"
  else
    run gcloud secrets create "$s" --project "$GCP_PROJECT_ID" \
      --replication-policy=automatic --labels="$SECRET_LABELS"
  fi
  run gcloud secrets add-iam-policy-binding "$s" --project "$GCP_PROJECT_ID" \
    --member="serviceAccount:$SA_INGEST_WRITER_EMAIL" \
    --role=roles/secretmanager.secretAccessor --format=none --quiet
done

# QBO rotates refresh tokens on use; the pipeline writes the new one back.
info "Rotation writeback: ingest-writer may add versions of $ROTATING_SECRET only"
run gcloud secrets add-iam-policy-binding "$ROTATING_SECRET" --project "$GCP_PROJECT_ID" \
  --member="serviceAccount:$SA_INGEST_WRITER_EMAIL" \
  --role=roles/secretmanager.secretVersionAdder --format=none --quiet

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
log "     gh variable set WIF_SERVICE_ACCOUNT --repo $GITHUB_REPO --body '$SA_INGEST_WRITER_EMAIL'"
log ""
log "2. Load the credential values into Secret Manager:"
log "     see docs/phase-2-credentials.md (the three OAuth walkthroughs)"
