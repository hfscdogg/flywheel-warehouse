#!/usr/bin/env bash
# 91-verify-pipelines.sh <client-slug> — READ-ONLY checks of the pipeline
# identities, the part of 90-verify.sh that does not involve the agent reader.
#
#   1. every dataset exists, in BQ_LOCATION
#   2. every pipeline account exists (one per ingest source, the transform,
#      the probe)
#   3. no ingest account is bound on staging or marts, and every pipeline
#      account has project-level bigquery.jobUser
#   4. the retired ingest-writer is disabled and holds nothing: no jobUser,
#      no grant on any dataset, no WIF binding
#
# Reads policies and dataset access lists only; runs no query and reads no
# table data or secret value, so it runs as `auditor` in audit.yml
# (scripts/12-auditor.sh) as well as from an admin session. Exits non-zero
# on any failure.
# shellcheck disable=SC2086  # $BQ is intentionally word-split
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0"
load_client "$1"

PIPELINE_SAS="$SA_TRANSFORM_EMAIL $SA_PROBE_EMAIL"
for src in $INGEST_SOURCES; do PIPELINE_SAS="$PIPELINE_SAS $(ingest_sa_email "$src")"; done

if is_dry_run; then
  info "[dry-run] verify-pipelines is read-only; a real run asserts:"
  log "  - datasets ($ALL_DATASETS) exist in $BQ_LOCATION"
  log "  - accounts exist and hold project jobUser: $PIPELINE_SAS"
  log "  - no ingest account is bound on $DATASET_STAGING or $DATASET_MARTS"
  log "  - $SA_INGEST_WRITER_EMAIL is disabled, with no jobUser, dataset grant or WIF binding"
  exit 0
fi
require_cmd gcloud bq python3

FAILURES=0
pass() { log "PASS  $*"; }
fail() { log "FAIL  $*"; FAILURES=$((FAILURES + 1)); }

# access_json <dataset>: the dataset's access list, or nothing if unreadable.
access_json() { $BQ show --format=json "$GCP_PROJECT_ID:$1" 2>/dev/null || true; }

info "1. datasets exist in $BQ_LOCATION"
for ds in $ALL_DATASETS; do
  loc="$(access_json "$ds" | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["location"])
except Exception: pass' 2>/dev/null || true)"
  if [ "$loc" = "$BQ_LOCATION" ]; then pass "dataset $ds in $BQ_LOCATION"
  else fail "dataset $ds missing or in '${loc:-none}'"; fi
done

info "2. pipeline accounts exist"
for email in $PIPELINE_SAS; do
  if probe gcloud iam service-accounts describe "$email" --project "$GCP_PROJECT_ID"; then pass "account $email exists"
  else fail "account $email missing"; fi
done

info "3. no ingest account on $DATASET_STAGING or $DATASET_MARTS; jobUser for every pipeline account"
for ds in $DATASET_STAGING $DATASET_MARTS; do
  acl="$(access_json "$ds")"
  if [ -z "$acl" ]; then fail "could not read access on $ds"; continue; fi
  for src in $INGEST_SOURCES; do
    email="$(ingest_sa_email "$src")"
    if printf '%s' "$acl" | grep -q "\"$email\""; then fail "$email bound on $ds"
    else pass "$email has no grant on $ds"; fi
  done
done
JOBUSERS="$(gcloud projects get-iam-policy "$GCP_PROJECT_ID" --flatten='bindings[].members' \
  --filter='bindings.role=roles/bigquery.jobUser' --format='value(bindings.members)')"
for email in $PIPELINE_SAS; do
  if printf '%s\n' "$JOBUSERS" | grep -qx "serviceAccount:$email"; then pass "$email has jobUser"
  else fail "$email missing jobUser"; fi
done

info "4. $SA_INGEST_WRITER retired"
if probe gcloud iam service-accounts describe "$SA_INGEST_WRITER_EMAIL" --project "$GCP_PROJECT_ID"; then
  disabled="$(gcloud iam service-accounts describe "$SA_INGEST_WRITER_EMAIL" --project "$GCP_PROJECT_ID" --format='value(disabled)')"
  case "$disabled" in True|true) pass "$SA_INGEST_WRITER is disabled" ;;
    *) fail "$SA_INGEST_WRITER is not disabled" ;; esac
  if gcloud iam service-accounts get-iam-policy "$SA_INGEST_WRITER_EMAIL" --project "$GCP_PROJECT_ID" \
      --format=json | grep -q workloadIdentityUser; then fail "$SA_INGEST_WRITER still has a WIF binding"
  else pass "$SA_INGEST_WRITER has no WIF binding"; fi
else
  pass "$SA_INGEST_WRITER does not exist"
fi
if printf '%s\n' "$JOBUSERS" | grep -qx "serviceAccount:$SA_INGEST_WRITER_EMAIL"; then fail "$SA_INGEST_WRITER still has jobUser"
else pass "$SA_INGEST_WRITER has no jobUser"; fi
for ds in $ALL_DATASETS $GA4_EXPORT_DATASET; do
  acl="$(access_json "$ds")"
  if [ -z "$acl" ]; then fail "could not read access on $ds"; continue; fi
  if printf '%s' "$acl" | grep -q "\"$SA_INGEST_WRITER_EMAIL\""; then fail "$SA_INGEST_WRITER still bound on $ds"
  else pass "$SA_INGEST_WRITER has no grant on $ds"; fi
done

log ""
log "failures: $FAILURES"
[ "$FAILURES" -eq 0 ]
