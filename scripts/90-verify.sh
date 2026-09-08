#!/usr/bin/env bash
# 90-verify.sh <client-slug> — prove Phase 1 did what the trust doc claims.
#
# Checks, in order:
#   1. All datasets exist in the configured location
#   2. Both service accounts exist
#   3. IAM policy assertions (reader on DATASETS_AGENT; reader ABSENT from
#      raw, and from staging unless AGENT_SCOPE=wide)
#   4. Impersonated smoke test via the BigQuery REST API:
#        - positive: query marts._flywheel_canary as hermes-reader → HTTP 200
#        - negative: query raw._flywheel_canary the same way → HTTP 403
#
# The positive test retries for up to ~5 minutes (IAM propagation can take
# minutes). The negative test only runs after the positive passes — before
# propagation, EVERYTHING 403s, which would prove nothing.
# shellcheck disable=SC2086  # $BQ is intentionally word-split
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0"
load_client "$1"

FIRST_RAW="$(set -- $DATASETS_RAW; printf '%s' "$1")"

if is_dry_run; then
  info "[dry-run] verify is read-only; a real run asserts:"
  log "  - datasets ($ALL_DATASETS) exist in $BQ_LOCATION"
  log "  - SAs $SA_HERMES_READER_EMAIL and $SA_INGEST_WRITER_EMAIL exist"
  log "  - $SA_HERMES_READER has dataViewer on $DATASETS_AGENT and nothing else (AGENT_SCOPE=$AGENT_SCOPE)"
  log "  - impersonated query on $DATASET_MARTS._flywheel_canary → HTTP 200"
  log "  - impersonated query on $FIRST_RAW._flywheel_canary → HTTP 403"
  exit 0
fi

require_cmd gcloud bq curl

RESULTS=""
FAILURES=0
record() { # record PASS|FAIL <description>
  RESULTS="$RESULTS  $1  $2
"
  [ "$1" = "PASS" ] || FAILURES=$((FAILURES + 1))
}

info "Verifying '$CLIENT_SLUG' (project $GCP_PROJECT_ID)"

# 1. Datasets exist, in the right location
for ds in $ALL_DATASETS; do
  LOC="$($BQ show --format=prettyjson "$GCP_PROJECT_ID:$ds" 2>/dev/null \
    | grep -o '"location": *"[^"]*"' | cut -d'"' -f4 || true)"
  if [ "$LOC" = "$BQ_LOCATION" ]; then
    record PASS "dataset $ds exists in $BQ_LOCATION"
  else
    record FAIL "dataset $ds missing or wrong location (got '${LOC:-none}')"
  fi
done

# 2. Service accounts exist
for email in "$SA_HERMES_READER_EMAIL" "$SA_INGEST_WRITER_EMAIL"; do
  if probe gcloud iam service-accounts describe "$email" --project "$GCP_PROJECT_ID"; then
    record PASS "service account $email exists"
  else
    record FAIL "service account $email missing"
  fi
done

# 3. Policy assertions — read the dataset access array via 'bq show'.
# ('bq get-iam-policy' on a DATASET needs Google allowlisting and errors out,
# which || true would swallow — making the positive check false-FAIL and the
# negative checks vacuous. 03-iam.sh writes access entries; read the same.)
MARTS_ACCESS="$($BQ show --format=prettyjson "$GCP_PROJECT_ID:$DATASET_MARTS" 2>/dev/null || true)"
if [ -z "$MARTS_ACCESS" ]; then
  record FAIL "policy: could not read access on $DATASET_MARTS"
elif printf '%s' "$MARTS_ACCESS" | grep -q "$SA_HERMES_READER_EMAIL"; then
  record PASS "policy: hermes-reader bound on $DATASET_MARTS"
else
  record FAIL "policy: hermes-reader NOT bound on $DATASET_MARTS"
fi

# Staging is asserted present or absent according to the client's choice;
# raw is asserted absent unconditionally.
STAGING_EXPECTED_ABSENT="$DATASET_STAGING"
[ "$AGENT_SCOPE" = "wide" ] && STAGING_EXPECTED_ABSENT=""
if [ "$AGENT_SCOPE" = "wide" ]; then
  ST_ACCESS="$($BQ show --format=prettyjson "$GCP_PROJECT_ID:$DATASET_STAGING" 2>/dev/null || true)"
  if printf '%s' "$ST_ACCESS" | grep -q "$SA_HERMES_READER_EMAIL"; then
    record PASS "policy: hermes-reader bound on $DATASET_STAGING (AGENT_SCOPE=wide)"
  else
    record FAIL "policy: hermes-reader NOT bound on $DATASET_STAGING but AGENT_SCOPE=wide"
  fi
fi
# shellcheck disable=SC2086  # intentional word-split of the dataset lists
for ds in $DATASETS_RAW $STAGING_EXPECTED_ABSENT; do
  DS_ACCESS="$($BQ show --format=prettyjson "$GCP_PROJECT_ID:$ds" 2>/dev/null || true)"
  if [ -z "$DS_ACCESS" ]; then
    record FAIL "policy: could not read access on $ds"
  elif printf '%s' "$DS_ACCESS" | grep -q "$SA_HERMES_READER_EMAIL"; then
    record FAIL "policy: hermes-reader UNEXPECTEDLY bound on $ds"
  else
    record PASS "policy: hermes-reader has no grant on $ds"
  fi
done

PROJECT_JOBUSERS="$(gcloud projects get-iam-policy "$GCP_PROJECT_ID" \
  --flatten='bindings[].members' \
  --filter='bindings.role=roles/bigquery.jobUser' \
  --format='value(bindings.members)' 2>/dev/null || true)"
for email in "$SA_HERMES_READER_EMAIL" "$SA_INGEST_WRITER_EMAIL"; do
  if printf '%s\n' "$PROJECT_JOBUSERS" | grep -q "serviceAccount:$email"; then
    record PASS "policy: $email has project-level jobUser"
  else
    record FAIL "policy: $email missing project-level jobUser"
  fi
done

# 4. Impersonated smoke test (REST API: deterministic status codes, no jq)
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
TOKEN=""

get_token() {
  TOKEN="$(gcloud auth print-access-token \
    --impersonate-service-account="$SA_HERMES_READER_EMAIL" 2>/dev/null || true)"
  [ -n "$TOKEN" ]
}

query_as_reader() { # sets HTTP_CODE; response body in $TMP
  local ds="$1" body
  # shellcheck disable=SC2016  # backticks are BigQuery identifier quoting, not expansion
  body="$(printf '{"query":"SELECT dataset FROM `%s.%s._flywheel_canary` LIMIT 1","useLegacySql":false,"location":"%s"}' \
    "$GCP_PROJECT_ID" "$ds" "$BQ_LOCATION")"
  HTTP_CODE="$(curl -s -o "$TMP" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    "https://bigquery.googleapis.com/bigquery/v2/projects/$GCP_PROJECT_ID/queries" \
    -d "$body")"
}

positive_ok() {
  query_as_reader "$DATASET_MARTS"
  # The queries endpoint can return 200 with an embedded error — guard both.
  [ "$HTTP_CODE" = "200" ] && ! grep -q '"errorResult"' "$TMP"
}

info "Smoke test: impersonating $SA_HERMES_READER_EMAIL (tokenCreator + IAM propagation can take minutes on first run)"
if ! retry 6 10 get_token; then
  record FAIL "could not mint impersonated token as $ADMIN_USER (tokenCreator grant propagating? run as a different user?)"
else
  if retry 20 15 positive_ok; then
    record PASS "hermes-reader can query ${DATASET_MARTS}._flywheel_canary (HTTP 200)"
    query_as_reader "$FIRST_RAW"
    if [ "$HTTP_CODE" = "403" ]; then
      record PASS "hermes-reader DENIED on ${FIRST_RAW}._flywheel_canary (HTTP 403)"
    else
      record FAIL "hermes-reader NOT denied on ${FIRST_RAW}._flywheel_canary (HTTP $HTTP_CODE — expected 403)"
    fi
  else
    record FAIL "hermes-reader cannot query ${DATASET_MARTS}._flywheel_canary (last HTTP $HTTP_CODE)"
  fi
fi

log ""
info "Results"
printf '%s' "$RESULTS"
log ""
if [ "$FAILURES" -ne 0 ]; then
  die "$FAILURES check(s) failed"
fi
info "ALL CHECKS PASSED — Phase 1 verified for '$CLIENT_SLUG'."
