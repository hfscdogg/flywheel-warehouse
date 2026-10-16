#!/usr/bin/env bash
# 90-verify.sh <client-slug> — prove Phase 1 did what the trust doc claims.
#
# Checks, in order:
#   1. All datasets exist in the configured location
#   2. Every service account exists (agent + one per pipeline job)
#   3. IAM policy assertions (reader on DATASETS_AGENT; reader ABSENT from
#      raw, and from staging unless AGENT_SCOPE=wide)
#   4. What must NOT be there, read from the live policies rather than from
#      the list of grants these scripts make:
#        - hermes-reader holds nothing on any dataset outside DATASETS_AGENT
#        - the retired ingest-writer holds nothing anywhere in the project
#          (project, any dataset under any role, secrets, accounts, buckets)
#        - the wif-rehearsal account does not exist and is named nowhere
#        - no WIF provider but WIF_POOL/github accepts GitHub tokens, and that
#          one pins the repository and WIF_ALLOWED_REF
#        - no account trusts a federated principal other than one workflow
#          file on WIF_ALLOWED_REF (no repo-wide principalSet)
#   5. Impersonated smoke test via the BigQuery REST API:
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

# The agent's account and one per pipeline job (lib/common.sh).
pipeline_and_agent_sas() {
  local src
  printf '%s\n' "$SA_HERMES_READER_EMAIL"
  for src in $INGEST_SOURCES; do ingest_sa_email "$src"; printf '\n'; done
  printf '%s\n%s\n' "$SA_TRANSFORM_EMAIL" "$SA_PROBE_EMAIL"
}

if is_dry_run; then
  info "[dry-run] verify is read-only; a real run asserts:"
  log "  - datasets ($ALL_DATASETS) exist in $BQ_LOCATION"
  log "  - SAs exist: $(pipeline_and_agent_sas | tr '\n' ' ')"
  log "  - no ingest account is bound on $DATASET_STAGING or $DATASET_MARTS"
  log "  - $SA_HERMES_READER has dataViewer on $DATASETS_AGENT and nothing else (AGENT_SCOPE=$AGENT_SCOPE)"
  log "  - $SA_HERMES_READER has no grant on any project dataset outside $DATASETS_AGENT"
  log "  - $SA_INGEST_WRITER_EMAIL is named in no policy in $GCP_PROJECT_ID"
  log "  - $SA_WIF_REHEARSAL_EMAIL does not exist and is named in no policy"
  log "  - the only WIF provider accepting GitHub tokens is ${WIF_POOL:-<WIF_POOL>}/github, pinned to $WIF_ALLOWED_REF"
  log "  - every federated binding names one workflow file on $WIF_ALLOWED_REF"
  log "  - impersonated query on $DATASET_MARTS._flywheel_canary → HTTP 200"
  log "  - impersonated query on $FIRST_RAW._flywheel_canary → HTTP 403"
  exit 0
fi

require_cmd gcloud bq curl python3

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
for email in $(pipeline_and_agent_sas); do
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
for ds in $DATASETS_RAW $STAGING_EXPECTED_ABSENT $GA4_EXPORT_DATASET; do
  DS_ACCESS="$($BQ show --format=prettyjson "$GCP_PROJECT_ID:$ds" 2>/dev/null || true)"
  if [ -z "$DS_ACCESS" ]; then
    record FAIL "policy: could not read access on $ds"
  elif printf '%s' "$DS_ACCESS" | grep -q "$SA_HERMES_READER_EMAIL"; then
    record FAIL "policy: hermes-reader UNEXPECTEDLY bound on $ds"
  else
    record PASS "policy: hermes-reader has no grant on $ds"
  fi
done

# An ingest account writes its own raw dataset only (03-iam.sh). Bound on
# staging or marts means it can rewrite what the agent reads.
for ds in $DATASET_STAGING $DATASET_MARTS; do
  DS_ACCESS="$($BQ show --format=prettyjson "$GCP_PROJECT_ID:$ds" 2>/dev/null || true)"
  for src in $INGEST_SOURCES; do
    email="$(ingest_sa_email "$src")"
    if [ -z "$DS_ACCESS" ]; then
      record FAIL "policy: could not read access on $ds"
      break
    elif printf '%s' "$DS_ACCESS" | grep -q "$email"; then
      record FAIL "policy: $email UNEXPECTEDLY bound on $ds"
    else
      record PASS "policy: $email has no grant on $ds"
    fi
  done
done

PROJECT_JOBUSERS="$(gcloud projects get-iam-policy "$GCP_PROJECT_ID" \
  --flatten='bindings[].members' \
  --filter='bindings.role=roles/bigquery.jobUser' \
  --format='value(bindings.members)' 2>/dev/null || true)"
for email in $(pipeline_and_agent_sas); do
  if printf '%s\n' "$PROJECT_JOBUSERS" | grep -q "serviceAccount:$email"; then
    record PASS "policy: $email has project-level jobUser"
  else
    record FAIL "policy: $email missing project-level jobUser"
  fi
done

# 4. Absences. Each check above asks whether the grants this repo makes are
# there; these ask whether anything else is. A retired account can keep a
# grant no script ever listed, and a hand-made rehearsal path is in no script
# at all, so both are read from every policy in the project.
PROJECT_DATASETS="$(project_datasets)"
[ -n "$PROJECT_DATASETS" ] || record FAIL "absence: could not list the project's datasets"

# hermes-reader on any dataset the client did not choose, including datasets
# client.env does not name.
OUTSIDE=0
for ds in $PROJECT_DATASETS; do
  case " $DATASETS_AGENT " in *" $ds "*) continue ;; esac
  OUTSIDE=$((OUTSIDE + 1))
  held="$($BQ show --format=prettyjson "$GCP_PROJECT_ID:$ds" 2>/dev/null \
    | dataset_entries_of "$SA_HERMES_READER_EMAIL" | tr '\n' ' ' | sed 's/ $//')"
  if [ -n "$held" ]; then
    record FAIL "absence: hermes-reader holds $held on $ds (outside AGENT_SCOPE=$AGENT_SCOPE)"
    OUTSIDE=-1000
  fi
done
[ "$OUTSIDE" -ge 0 ] \
  && record PASS "absence: hermes-reader holds nothing on the $OUTSIDE datasets outside $DATASETS_AGENT"

# holdings <email>: one line per grant naming <email>, live or deleted,
# anywhere in the project.
holdings() {
  local email="$1" ds res
  gcloud projects get-iam-policy "$GCP_PROJECT_ID" --format=json 2>/dev/null \
    | policy_members_of "$email" | sed 's/^/project /'
  for ds in $PROJECT_DATASETS; do
    $BQ show --format=prettyjson "$GCP_PROJECT_ID:$ds" 2>/dev/null \
      | dataset_entries_of "$email" | sed "s/^/dataset $ds /"
  done
  for res in $(gcloud secrets list --project "$GCP_PROJECT_ID" --format='value(name.basename())' 2>/dev/null); do
    gcloud secrets get-iam-policy "$res" --project "$GCP_PROJECT_ID" --format=json 2>/dev/null \
      | policy_members_of "$email" | sed "s/^/secret $res /"
  done
  for res in $(gcloud iam service-accounts list --project "$GCP_PROJECT_ID" --format='value(email)' 2>/dev/null); do
    gcloud iam service-accounts get-iam-policy "$res" --project "$GCP_PROJECT_ID" --format=json 2>/dev/null \
      | policy_members_of "$email" | sed "s/^/account $res /"
  done
  for res in $(gcloud storage buckets list --project "$GCP_PROJECT_ID" --format='value(name)' 2>/dev/null); do
    gcloud storage buckets get-iam-policy "gs://$res" --format=json 2>/dev/null \
      | policy_members_of "$email" | sed "s/^/bucket $res /"
  done
}

for email in "$SA_INGEST_WRITER_EMAIL" "$SA_WIF_REHEARSAL_EMAIL"; do
  held="$(holdings "$email")"
  if [ -z "$held" ]; then
    record PASS "absence: $email is named in no policy (project, $(printf '%s' "$PROJECT_DATASETS" | wc -w | tr -d ' ') datasets, secrets, accounts, buckets)"
  else
    record FAIL "absence: $email still holds: $(printf '%s' "$held" | tr '\t\n' ' ;')"
  fi
done

if probe gcloud iam service-accounts describe "$SA_WIF_REHEARSAL_EMAIL" --project "$GCP_PROJECT_ID"; then
  record FAIL "absence: $SA_WIF_REHEARSAL_EMAIL still exists"
else
  record PASS "absence: $SA_WIF_REHEARSAL_EMAIL does not exist"
fi
IW_DISABLED="$(gcloud iam service-accounts describe "$SA_INGEST_WRITER_EMAIL" --project "$GCP_PROJECT_ID" \
  --format='value(disabled)' 2>/dev/null || echo absent)"
case "$IW_DISABLED" in
  True|absent) record PASS "absence: $SA_INGEST_WRITER_EMAIL is ${IW_DISABLED/True/disabled}" ;;
  *) record FAIL "absence: $SA_INGEST_WRITER_EMAIL is still enabled" ;;
esac

if [ -n "${GITHUB_REPO:-}" ] && [ -n "${WIF_POOL:-}" ]; then
  STRAY="$(stray_wif_providers)"
  if [ -z "$STRAY" ]; then
    record PASS "absence: no WIF provider but $WIF_POOL/github accepts GitHub tokens"
  else
    record FAIL "absence: extra WIF providers: $(printf '%s' "$STRAY" | tr '\t\n' '/ ')"
  fi
  COND="$(gcloud iam workload-identity-pools providers describe github \
    --project "$GCP_PROJECT_ID" --location=global --workload-identity-pool="$WIF_POOL" \
    --format='value(attributeCondition)' 2>/dev/null || true)"
  case "$COND" in
    *"assertion.repository == '$GITHUB_REPO'"*"assertion.ref == '$WIF_ALLOWED_REF'"*)
      record PASS "policy: $WIF_POOL/github accepts $GITHUB_REPO on $WIF_ALLOWED_REF only" ;;
    *) record FAIL "policy: $WIF_POOL/github condition does not pin repository and ref (got '${COND:-none}')" ;;
  esac
  POOL_NAME="$(gcloud iam workload-identity-pools describe "$WIF_POOL" \
    --project "$GCP_PROJECT_ID" --location=global --format='value(name)' 2>/dev/null || true)"
  if [ -z "$POOL_NAME" ]; then
    record FAIL "policy: workload identity pool $WIF_POOL not found"
  else
    LOOSE="$(loose_wif_bindings "$POOL_NAME")"
    if [ -z "$LOOSE" ]; then
      record PASS "absence: every federated binding names one workflow file on $WIF_ALLOWED_REF"
    else
      record FAIL "absence: loose federated bindings: $(printf '%s' "$LOOSE" | tr '\t\n' ' ;')"
    fi
  fi
fi

# 5. Impersonated smoke test (REST API: deterministic status codes, no jq)
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
