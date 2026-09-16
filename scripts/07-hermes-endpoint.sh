#!/usr/bin/env bash
# 07-hermes-endpoint.sh <client-slug> [deploy|rotate-token|url|delete]
#
# Phase 4: the agent endpoint. Deploys hermes-mcp/ to Cloud Run in the
# client's project with the service's RUNTIME IDENTITY set to hermes-reader
# — no key exists anywhere, and IAM (03-iam.sh) enforces marts-only access.
# Agents authenticate to the endpoint with a bearer token held in the
# client's own Secret Manager.
#
#   deploy        enable APIs, mint the token secret if absent, converge the
#                 IAM this needs, deploy/update the service, print the URL
#   redeploy      ONLY the deploy step: ship the current hermes-mcp/ to the
#                 EXISTING service. Converges no APIs, creates no secret,
#                 touches no IAM policy. Exists so the recurring 10% of
#                 'deploy' can run somewhere that is not a human's laptop:
#                 shipping a new revision is routine and happens whenever
#                 server.py or AGENT_SCOPE changes, while the other four
#                 steps are first-run convergence that need project-IAM and
#                 Secret Manager admin. Splitting them is what lets CI hold
#                 run.admin + serviceAccountUser and nothing else.
#                 Refuses to run until 'deploy' has been run once by a human.
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

[ $# -ge 1 ] || usage_and_exit "$0 (actions: deploy | redeploy | rotate-token | url | delete)"
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

# THE ^@^ IS LOAD-BEARING. --set-env-vars splits pairs on a COMMA, so a value
# that itself contains one is read as the start of the next pair:
# "DATASETS_AGENT=marts,staging" parses as DATASETS_AGENT=marts plus a bare
# token "staging" with no '=', and gcloud rejects the whole invocation with a
# usage dump. The ^delim^ prefix is gcloud's documented escape for exactly
# this — it makes '@' the separator instead, so commas inside values are just
# characters.
#
# This is not hypothetical. AGENT_SCOPE was set to "wide" on 2026-09-04,
# which made DATASETS_AGENT "marts staging" and so put a comma in the value.
# EVERY deploy from that day until 2026-09-16 died on this line, and the
# failure looked like nothing: the script exits non-zero, the existing
# revision keeps serving, and the endpoint carries on answering — just from
# code that predates the variable. The visible symptom was two weeks away
# from the cause: agents were told staging did not exist, because the running
# revision had no DATASETS_AGENT at all and fell back to marts.
#
# `--labels` below is a genuine comma-separated list of two labels and is
# correct as written; only values that can contain a comma need the escape.
#
# The Cloud Run deploy itself, shared by 'deploy' and 'redeploy' so the two
# cannot drift into shipping differently configured revisions. Everything it
# needs is already true by the time either caller reaches it: the token secret
# exists, hermes-reader can read it, and the build identity can build.
deploy_service() {
  info "Deploying $HERMES_MCP_SERVICE to Cloud Run ($RUN_REGION) as $SA_HERMES_READER_EMAIL"
  run gcloud run deploy "$HERMES_MCP_SERVICE" \
    --project "$GCP_PROJECT_ID" --region "$RUN_REGION" \
    --source "$REPO_ROOT/hermes-mcp" \
    --service-account "$SA_HERMES_READER_EMAIL" \
    --allow-unauthenticated \
    --set-secrets "HERMES_TOKEN=${TOKEN_SECRET}:latest" \
    --set-env-vars "^@^GCP_PROJECT_ID=${GCP_PROJECT_ID}@DATASET_MARTS=${DATASET_MARTS}@DATASETS_AGENT=${DATASETS_AGENT// /,}" \
    --memory 512Mi --cpu 1 --max-instances 2 --timeout 120 \
    --labels "managed-by=${LABEL_MANAGED_BY},env=${LABEL_ENV}"
  # --allow-unauthenticated is the transport layer only: the app itself
  # rejects every request without the bearer token (401), and the runtime
  # identity can read DATASETS_AGENT and nothing else regardless.
  # DATASETS_AGENT is what the server LISTS; IAM (03-iam.sh) is what it can
  # actually read. They agree because both derive from AGENT_SCOPE.
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

    deploy_service
    print_connection_info
    ;;

  redeploy)
    # Deliberately refuses to bootstrap. A caller holding only run.admin on
    # this service and serviceAccountUser on hermes-reader cannot create the
    # token secret or grant the build identity its role, so a first deploy
    # attempted here would fail deep inside gcloud with a permission error
    # that reads like a broken pipeline rather than "this was never meant to
    # run here". One check up front says it plainly.
    #
    # ONE CHECK, NOT TWO, AND THIS ONE ON PURPOSE. The first version also
    # probed `gcloud secrets describe` for the token secret, and the first
    # gated run failed on it saying the secret did not exist — while the
    # running service was mounting that very secret. `secrets describe` needs
    # secretmanager.viewer, which the deployer account is deliberately not
    # given, and probe() cannot tell "absent" from "not allowed to look": both
    # are a false. So the guard asserted something untrue about a secret that
    # was fine, and pointed at the wrong remedy.
    #
    # The check is also redundant. The service mounts
    # HERMES_TOKEN=<secret>:latest, so a service that exists is proof the
    # secret exists. Asking about the service answers both questions using a
    # permission this account actually holds.
    info "Redeploy: shipping current hermes-mcp/ to the existing service"
    # Skipped under DRY_RUN, where probe() reports everything absent on
    # purpose so a dry run prints every create step. Without this the plan
    # preview could never get past the check and would show nothing.
    if ! is_dry_run; then
      if ! probe gcloud run services describe "$HERMES_MCP_SERVICE" \
           --project "$GCP_PROJECT_ID" --region "$RUN_REGION"; then
        # Deliberately not "does not exist": probe() returns false for a
        # missing service AND for one this identity may not read, and saying
        # which would be a guess. Name both, so the reader checks the right
        # thing instead of chasing the one the message picked.
        die "cannot see Cloud Run service '$HERMES_MCP_SERVICE' in $RUN_REGION — either it does not exist yet, in which case run '$0 $CLIENT_SLUG deploy' once from an admin session, or this identity lacks run.viewer on it (10-endpoint-deployer.sh grants run.admin on the service; check it ran against this region)"
      fi
    fi
    deploy_service
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
    die "unknown action '$ACTION' (expected: deploy | redeploy | rotate-token | url | delete)"
    ;;
esac
