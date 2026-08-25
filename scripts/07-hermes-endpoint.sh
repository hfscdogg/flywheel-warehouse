#!/usr/bin/env bash
# 07-hermes-endpoint.sh <client-slug> [deploy|rotate-token|url|delete]
#
# Phase 4: the agent endpoint. Deploys hermes-mcp/ to Cloud Run in the
# client's project with the service's RUNTIME IDENTITY set to hermes-reader
# — no key exists anywhere, and IAM (03-iam.sh) enforces marts-only access.
# Agents authenticate to the endpoint with a bearer token held in the
# client's own Secret Manager.
#
#   deploy        enable APIs, mint the token secret if absent, deploy/update
#                 the Cloud Run service, print the URL + connection info
#   rotate-token  add a new token version and roll the service to it
#   url           print the service URL and how to read the current token
#   delete        remove the service (the token secret is kept; delete it
#                 manually if the client is being torn down)
#
# Revocation story: 'delete' kills the endpoint in seconds; 'rotate-token'
# cuts off anyone holding the old token without redeploying agents' IAM.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0 (actions: deploy | rotate-token | url | delete)"
load_client "$1"
ACTION="${2:-deploy}"
require_cmd gcloud python3

# Optional per-client overrides (clients/<slug>/client.env)
RUN_REGION="${RUN_REGION:-us-east4}"
HERMES_MCP_SERVICE="${HERMES_MCP_SERVICE:-hermes-mcp}"
TOKEN_SECRET="${HERMES_TOKEN_SECRET:-hermes-endpoint-token}"

print_connection_info() {
  local url="(deploy first)"
  if ! is_dry_run; then
    url="$(gcloud run services describe "$HERMES_MCP_SERVICE" \
      --project "$GCP_PROJECT_ID" --region "$RUN_REGION" \
      --format='value(status.url)' 2>/dev/null || true)"
    [ -n "$url" ] || url="(service not found — run deploy)"
  fi
  log ""
  info "Agent connection info for $CLIENT_DISPLAY_NAME"
  log "  MCP endpoint : ${url}/mcp"
  log "  Auth header  : Authorization: Bearer <token>"
  log "  Read token   : gcloud secrets versions access latest --secret $TOKEN_SECRET --project $GCP_PROJECT_ID"
  log ""
  log "  Verify scope from any MCP client (mirrors 90-verify.sh):"
  log "    query: SELECT month, deals_won FROM kpi_sales_pipeline ORDER BY month DESC LIMIT 3   -> rows"
  log "    query: SELECT COUNT(*) FROM \`$GCP_PROJECT_ID.${DATASETS_RAW%% *}.deals\`            -> Access Denied (by design)"
}

mint_token_version() {
  # sys.stdout.write, not print: a trailing newline would be stored in the
  # secret and injected into HERMES_TOKEN, while clients' $(...) strips it —
  # the server also strips defensively, but keep the stored value exact.
  if is_dry_run; then
    log "[dry-run] python3 -c '...secrets.token_hex(32), no trailing newline' | gcloud secrets versions add $TOKEN_SECRET --data-file=- --project $GCP_PROJECT_ID"
    return 0
  fi
  python3 -c 'import secrets, sys; sys.stdout.write(secrets.token_hex(32))' \
    | gcloud secrets versions add "$TOKEN_SECRET" --data-file=- --project "$GCP_PROJECT_ID" >/dev/null
  log "  new token version added to secret '$TOKEN_SECRET'"
}

case "$ACTION" in
  deploy)
    info "Enabling required APIs"
    run gcloud services enable run.googleapis.com cloudbuild.googleapis.com \
      artifactregistry.googleapis.com secretmanager.googleapis.com \
      --project "$GCP_PROJECT_ID"

    info "Endpoint token secret: $TOKEN_SECRET"
    if probe gcloud secrets describe "$TOKEN_SECRET" --project "$GCP_PROJECT_ID"; then
      log "  secret exists — keeping current token"
    else
      if is_dry_run; then
        log "[dry-run] gcloud secrets create $TOKEN_SECRET --replication-policy=automatic --project $GCP_PROJECT_ID"
        log "[dry-run] (then add a generated 64-hex-char token as the first version)"
      else
        run gcloud secrets create "$TOKEN_SECRET" --replication-policy=automatic \
          --labels "managed-by=${LABEL_MANAGED_BY},env=${LABEL_ENV}" \
          --project "$GCP_PROJECT_ID"
        mint_token_version
      fi
    fi

    info "$SA_HERMES_READER: read access to the token secret (runtime injection)"
    run gcloud secrets add-iam-policy-binding "$TOKEN_SECRET" \
      --project "$GCP_PROJECT_ID" \
      --member "serviceAccount:$SA_HERMES_READER_EMAIL" \
      --role roles/secretmanager.secretAccessor --format=none --quiet

    # 'gcloud run deploy --source' builds with the project's default COMPUTE
    # service account, which on newer projects has no build permissions —
    # the deploy then dies at "Uploading sources" with PERMISSION_DENIED
    # (hit on livewire-dw's first deploy, 2026-08-25). builds.builder is
    # Google's documented remediation; it touches only the build identity,
    # never hermes-reader.
    info "Cloud Build default SA: builder role (required for source deploys)"
    if is_dry_run; then
      log "[dry-run] gcloud projects add-iam-policy-binding $GCP_PROJECT_ID --member serviceAccount:<project-number>-compute@developer.gserviceaccount.com --role roles/cloudbuild.builds.builder"
    else
      PROJECT_NUMBER="$(gcloud projects describe "$GCP_PROJECT_ID" --format='value(projectNumber)')"
      [ -n "$PROJECT_NUMBER" ] || die "could not resolve project number for $GCP_PROJECT_ID"
      run gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
        --member "serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
        --role roles/cloudbuild.builds.builder --format=none --quiet
    fi

    info "Deploying $HERMES_MCP_SERVICE to Cloud Run ($RUN_REGION) as $SA_HERMES_READER_EMAIL"
    run gcloud run deploy "$HERMES_MCP_SERVICE" \
      --project "$GCP_PROJECT_ID" --region "$RUN_REGION" \
      --source "$REPO_ROOT/hermes-mcp" \
      --service-account "$SA_HERMES_READER_EMAIL" \
      --allow-unauthenticated \
      --set-secrets "HERMES_TOKEN=${TOKEN_SECRET}:latest" \
      --set-env-vars "GCP_PROJECT_ID=${GCP_PROJECT_ID},DATASET_MARTS=${DATASET_MARTS}" \
      --memory 512Mi --cpu 1 --max-instances 2 --timeout 120 \
      --labels "managed-by=${LABEL_MANAGED_BY},env=${LABEL_ENV}"
    # --allow-unauthenticated is the transport layer only: the app itself
    # rejects every request without the bearer token (401), and the runtime
    # identity can read marts and nothing else regardless.

    print_connection_info
    ;;

  rotate-token)
    info "Rotating endpoint token for $HERMES_MCP_SERVICE"
    mint_token_version
    # :latest is resolved at instance start — force a new revision so the
    # rotation takes effect now, not at the next cold start.
    run gcloud run services update "$HERMES_MCP_SERVICE" \
      --project "$GCP_PROJECT_ID" --region "$RUN_REGION" \
      --update-env-vars "TOKEN_ROTATED_AT=$(date -u +%Y%m%dT%H%M%SZ)"
    log "  old token is dead; hand the new one to the agent (see 'url')"
    ;;

  url)
    print_connection_info
    ;;

  delete)
    info "Deleting Cloud Run service $HERMES_MCP_SERVICE (agent access ends immediately)"
    run gcloud run services delete "$HERMES_MCP_SERVICE" \
      --project "$GCP_PROJECT_ID" --region "$RUN_REGION" --quiet
    log "  token secret '$TOKEN_SECRET' kept; delete it too if tearing the client down:"
    log "    gcloud secrets delete $TOKEN_SECRET --project $GCP_PROJECT_ID"
    ;;

  *)
    die "unknown action '$ACTION' (expected: deploy | rotate-token | url | delete)"
    ;;
esac
