#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables set here are consumed by sourcing scripts
# Shared helpers for flywheel-warehouse scripts. Sourced, never executed.
# Bash 3.2 compatible (macOS default shell).
#
# Contract for callers:
#   set -euo pipefail
#   . "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
#   load_client "$1"
#
# DRY_RUN=1 prints every mutating command instead of executing it, and
# existence probes report "absent" so the printed plan shows the full
# create path. Under DRY_RUN nothing requires the Google Cloud SDK.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log()  { printf '%s\n' "$*"; }
info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

is_dry_run() { [ "${DRY_RUN:-0}" = "1" ]; }

# Execute a command (logged), or just print it under DRY_RUN=1.
run() {
  if is_dry_run; then
    log "[dry-run] $*"
    return 0
  fi
  log "  \$ $*"
  "$@"
}

# Silent read-only existence check. Under DRY_RUN, always "absent" so the
# dry-run plan shows every create step.
probe() {
  if is_dry_run; then
    return 1
  fi
  "$@" >/dev/null 2>&1
}

# retry <max-attempts> <sleep-seconds> <cmd...>
retry() {
  local max="$1" delay="$2" n=1
  shift 2
  while true; do
    if "$@"; then return 0; fi
    if [ "$n" -ge "$max" ]; then
      warn "giving up after $max attempts: $*"
      return 1
    fi
    log "  ...attempt $n/$max failed; retrying in ${delay}s"
    sleep "$delay"
    n=$((n + 1))
  done
}

require_cmd() {
  if is_dry_run; then return 0; fi
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 \
      || die "'$c' not found on PATH — see docs/phase-0-checklist.md (install the Google Cloud SDK)."
  done
}

list_clients() {
  local d name
  for d in "$REPO_ROOT/clients"/*/; do
    name="$(basename "$d")"
    case "$name" in
      _template|'*') : ;;
      *) printf '%s\n' "$name" ;;
    esac
  done
}

usage_and_exit() {
  {
    printf 'Usage: %s <client-slug> [args]\n' "$1"
    printf 'Available clients: %s\n' "$(list_clients | tr '\n' ' ')"
  } >&2
  exit 2
}

# load_client <slug>: source clients/<slug>/client.env, validate it, derive
# service-account emails, dataset list, and bq flag strings.
load_client() {
  local slug="${1:-}"
  [ -n "$slug" ] || die "load_client: missing client slug"
  case "$slug" in
    [a-z]*) : ;;
    *) die "invalid client slug '$slug' (must start with a lowercase letter)" ;;
  esac
  case "$slug" in
    *[!a-z0-9-]*) die "invalid client slug '$slug' (allowed: lowercase letters, digits, hyphens)" ;;
  esac

  local env_file="$REPO_ROOT/clients/$slug/client.env"
  [ -f "$env_file" ] \
    || die "unknown client '$slug' (no $env_file). Available: $(list_clients | tr '\n' ' ')"
  # shellcheck source=/dev/null
  . "$env_file"

  local v
  for v in CLIENT_SLUG CLIENT_DISPLAY_NAME GCP_PROJECT_ID BQ_LOCATION ADMIN_USER \
           DATASETS_RAW DATASET_STAGING DATASET_MARTS SA_HERMES_READER \
           LABEL_MANAGED_BY LABEL_ENV KEY_DIR; do
    eval "[ -n \"\${$v:-}\" ]" || die "client.env for '$slug' is missing required variable: $v"
  done
  [ "$CLIENT_SLUG" = "$slug" ] \
    || die "CLIENT_SLUG ('$CLIENT_SLUG') does not match directory name ('$slug')"
  case "$CLIENT_SLUG$GCP_PROJECT_ID" in
    *CHANGEME*) die "client.env for '$slug' still contains CHANGEME placeholders" ;;
  esac

  SA_HERMES_READER_EMAIL="${SA_HERMES_READER}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
  # The single pipeline identity this repo used before 2026-10-09: every
  # connector secret plus write access to raw, staging and marts. Nothing
  # grants it anything any more; it is named only so 11-retire-ingest-writer.sh
  # and 99-teardown.sh can strip a client that still has it.
  SA_INGEST_WRITER="${SA_INGEST_WRITER:-ingest-writer}"
  SA_INGEST_WRITER_EMAIL="${SA_INGEST_WRITER}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
  # Made by hand in the sandbox to rehearse the 2026-10 cutover, beside a
  # second WIF provider that trusted the whole repository. Never part of the
  # design; named only so 11-retire-ingest-writer.sh can delete it and
  # 90-verify.sh can prove it is gone.
  SA_WIF_REHEARSAL="${SA_WIF_REHEARSAL:-wif-rehearsal}"
  SA_WIF_REHEARSAL_EMAIL="${SA_WIF_REHEARSAL}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

  # One identity per job (docs/trust.md, "Pipeline identities"). Optional in
  # client.env. The ingest identities are one per connector, named
  # <prefix><source>, and exist only for the sources in INGEST_SOURCES.
  SA_TRANSFORM="${SA_TRANSFORM:-transform-writer}"
  SA_TRANSFORM_EMAIL="${SA_TRANSFORM}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
  SA_PROBE="${SA_PROBE:-warehouse-reader}"
  SA_PROBE_EMAIL="${SA_PROBE}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
  SA_INGEST_PREFIX="${SA_INGEST_PREFIX:-ingest-}"

  # Raw datasets a pipeline in this repo writes. raw_ga4 and raw_google_ads
  # are written by Google (the GA4 export, the Ads transfer), so no ingest
  # identity exists for them.
  INGEST_SOURCES=""
  local ds
  for ds in $DATASETS_RAW; do
    case "$ds" in
      raw_ga4|raw_google_ads) : ;;
      raw_*) INGEST_SOURCES="$INGEST_SOURCES ${ds#raw_}" ;;
    esac
  done
  INGEST_SOURCES="${INGEST_SOURCES# }"

  # Workload identity federation trusts this one branch. A workflow on any
  # other ref gets no token (05-ingestion-infra.sh).
  WIF_ALLOWED_REF="${WIF_ALLOWED_REF:-refs/heads/main}"
  # The identity Cloud Build runs as when the agent endpoint is built from
  # source (converge_endpoint_builder below). Optional in client.env.
  SA_ENDPOINT_BUILDER="${SA_ENDPOINT_BUILDER:-endpoint-builder}"
  SA_ENDPOINT_BUILDER_EMAIL="${SA_ENDPOINT_BUILDER}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
  ALL_DATASETS="$DATASETS_RAW $DATASET_STAGING $DATASET_MARTS"

  # What hermes-reader may read (docs/access-tiers.md). Optional in
  # client.env; absent means narrow, the Tier 2a default.
  AGENT_SCOPE="${AGENT_SCOPE:-narrow}"
  case "$AGENT_SCOPE" in
    narrow) DATASETS_AGENT="$DATASET_MARTS" ;;
    wide)   DATASETS_AGENT="$DATASET_MARTS $DATASET_STAGING" ;;
    *) die "client.env for '$slug': AGENT_SCOPE must be narrow or wide (got '$AGENT_SCOPE')" ;;
  esac

  # Google Analytics 4 is not ingested: Google writes the property's export
  # into this project, and raw_ga4.events is a view over it. The two
  # settings only make sense together, so a half-configured client stops
  # here rather than building a view nobody reads or a model with no view.
  GA4_EXPORT_DATASET="${GA4_EXPORT_DATASET:-}"
  case " $DATASETS_RAW " in
    *" raw_ga4 "*)
      [ -n "$GA4_EXPORT_DATASET" ] \
        || die "client.env for '$slug': raw_ga4 is in DATASETS_RAW but GA4_EXPORT_DATASET is not set" ;;
    *)
      [ -z "$GA4_EXPORT_DATASET" ] \
        || die "client.env for '$slug': GA4_EXPORT_DATASET is set but raw_ga4 is not in DATASETS_RAW" ;;
  esac

  # Google Ads is not ingested either: BigQuery's own Data Transfer writes
  # raw_google_ads.p_ads_<Report>_<customer id>, and 01-datasets.sh puts
  # views with plain names over the reports staging reads. The views need
  # the customer id, so the two settings travel together, as GA4's do.
  GOOGLE_ADS_CUSTOMER_ID="${GOOGLE_ADS_CUSTOMER_ID:-}"
  case " $DATASETS_RAW " in
    *" raw_google_ads "*)
      [ -n "$GOOGLE_ADS_CUSTOMER_ID" ] \
        || die "client.env for '$slug': raw_google_ads is in DATASETS_RAW but GOOGLE_ADS_CUSTOMER_ID is not set" ;;
    *)
      [ -z "$GOOGLE_ADS_CUSTOMER_ID" ] \
        || die "client.env for '$slug': GOOGLE_ADS_CUSTOMER_ID is set but raw_google_ads is not in DATASETS_RAW" ;;
  esac
  case "$GOOGLE_ADS_CUSTOMER_ID" in
    *[!0-9]*) die "client.env for '$slug': GOOGLE_ADS_CUSTOMER_ID is digits only, no dashes (got '$GOOGLE_ADS_CUSTOMER_ID')" ;;
  esac

  # Always-explicit project, never interactive first-run init. Intentionally
  # word-split at call sites: run $BQ show ...
  BQ="bq --headless=true --project_id=$GCP_PROJECT_ID"

  # bq mk and bq update both want colon form here: mk uses repeated
  # '--label k:v' (verified against bq 2.1.36); update uses '--set_label k:v'.
  BQ_MK_LABELS="--label managed-by:$LABEL_MANAGED_BY --label client:$CLIENT_SLUG --label env:$LABEL_ENV"
  BQ_UPDATE_LABELS="--set_label managed-by:$LABEL_MANAGED_BY --set_label client:$CLIENT_SLUG --set_label env:$LABEL_ENV"

  export CLOUDSDK_CORE_DISABLE_PROMPTS=1
}

# The build identity for `gcloud run deploy --source` of the agent endpoint.
#
# Without one named, Cloud Build runs the build as the project's DEFAULT
# COMPUTE service account, and whoever deploys must be allowed to act as it.
# That account commonly holds Editor on the whole project, so acting as it
# makes the deployer a project editor in all but name -- the opposite of the
# narrow CI identity 10-endpoint-deployer.sh exists to build. Every CI deploy
# from 2026-09-16 to 2026-09-28 failed one permission short of that grant.
#
# So the build runs as this account instead, holding roles/run.builder,
# Google's role for exactly this job (read the uploaded source, write the
# image to Artifact Registry, write build logs) and nothing else: no
# BigQuery, no Secret Manager, no IAM. The deployer is allowed to act as
# THIS account only (10-endpoint-deployer.sh). Called from both
# 07-hermes-endpoint.sh deploy and 10-endpoint-deployer.sh, so either one
# leaves a client able to build; both are idempotent.
converge_endpoint_builder() {
  info "Build service account: $SA_ENDPOINT_BUILDER_EMAIL (runs the source build)"
  if probe gcloud iam service-accounts describe "$SA_ENDPOINT_BUILDER_EMAIL" --project "$GCP_PROJECT_ID"; then
    log "  exists"
  else
    run gcloud iam service-accounts create "$SA_ENDPOINT_BUILDER" \
      --project "$GCP_PROJECT_ID" \
      --display-name="Flywheel agent-endpoint builder" \
      --description="Cloud Build identity for hermes-mcp source deploys. run.builder only."
    # A new service account is not immediately visible to IAM policy calls.
    if ! is_dry_run; then
      retry 12 5 probe gcloud iam service-accounts describe "$SA_ENDPOINT_BUILDER_EMAIL" \
        --project "$GCP_PROJECT_ID" \
        || die "service account $SA_ENDPOINT_BUILDER_EMAIL not visible after creation"
    fi
  fi
  run gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
    --member="serviceAccount:$SA_ENDPOINT_BUILDER_EMAIL" \
    --role=roles/run.builder --condition=None --format=none --quiet
}

# ── Per-function pipeline identities ────────────────────────────────────────
# Until 2026-10-09 one account, ingest-writer, ran every pipeline: it read all
# sixteen connector secrets and could write raw, staging and marts. A flaw in
# any one connector's code, or any workflow that could borrow that account,
# reached everything. Now each job has its own account holding only what that
# job touches (docs/trust.md, "Pipeline identities"):
#
#   ingest-<source>   its own secrets; dataEditor on raw_<source> only
#   transform-writer  no secrets; reads raw, writes staging and marts
#   warehouse-reader  no secrets; reads everything, writes nothing (probe.yml)
#
# The tables below are the single source of which secrets and workflows
# belong to which source. pipelines/tests/test_identities.py checks them
# against the workflows and the pipeline code, so a new connector cannot be
# wired up here without its workflow being bound, or the other way round.

ingest_sa_name()  { printf '%s%s' "$SA_INGEST_PREFIX" "$1"; }
ingest_sa_email() { printf '%s@%s.iam.gserviceaccount.com' "$(ingest_sa_name "$1")" "$GCP_PROJECT_ID"; }

# The GitHub repository variable a source's workflows read the account from.
ingest_sa_var() { printf 'WIF_SA_INGEST_%s' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }

# source_secrets <source>: the Secret Manager secrets its pipeline reads.
source_secrets() {
  case "$1" in
    zoho)        echo "flywheel-zoho-client-id flywheel-zoho-client-secret flywheel-zoho-refresh-token" ;;
    zohobilling) echo "flywheel-zohobilling-client-id flywheel-zohobilling-client-secret flywheel-zohobilling-refresh-token" ;;
    dtools)      echo "flywheel-dtools-api-key flywheel-dtools-auth-basic flywheel-dtools-v2-refresh-token" ;;
    alarmdotcom) echo "flywheel-alarmdotcom-username flywheel-alarmdotcom-password flywheel-alarmdotcom-client-id" ;;
    qbo)         echo "flywheel-qbo-client-id flywheel-qbo-client-secret flywheel-qbo-refresh-token flywheel-qbo-realm-id" ;;
    vendor)      echo "" ;;  # files in a bucket, no credentials
    *) die "no ingest pipeline is defined for raw_$1 (scripts/lib/common.sh source_secrets)" ;;
  esac
}

# source_rotating_secrets <source>: refresh tokens the pipeline writes back.
# QBO rotates on use; Entra (D-Tools v2) may hand back a new one on refresh.
source_rotating_secrets() {
  case "$1" in
    qbo)    echo "flywheel-qbo-refresh-token" ;;
    dtools) echo "flywheel-dtools-v2-refresh-token" ;;
    *)      echo "" ;;
  esac
}

# source_workflows <source>: the workflow files that ingest it. Each is the
# only workflow allowed to act as that source's account.
source_workflows() {
  case "$1" in
    zoho)        echo "ingest-zoho.yml" ;;
    zohobilling) echo "ingest-zohobilling.yml" ;;
    dtools)      echo "ingest-dtools.yml ingest-dtools-v2.yml" ;;
    alarmdotcom) echo "ingest-alarmdotcom.yml" ;;
    qbo)         echo "ingest-qbo.yml ingest-qbo-reports.yml" ;;
    vendor)      echo "ingest-vendordrop.yml" ;;
    *) die "no ingest workflow is defined for raw_$1 (scripts/lib/common.sh source_workflows)" ;;
  esac
}

# The vendor report drop bucket (09-vendor-drop.sh).
vendor_drop_bucket() { printf '%s' "${VENDOR_DROP_BUCKET:-${GCP_PROJECT_ID}-vendor-drops}"; }

# wif_workflow_member <pool-name> <workflow-file>
# The principal for ONE workflow file on the trusted branch. GitHub signs
# job_workflow_ref into every Actions token as
# <owner>/<repo>/.github/workflows/<file>@<ref>, so a copy of the workflow on
# another branch, or a different workflow in the same repo, never matches.
wif_workflow_member() {
  printf 'principalSet://iam.googleapis.com/%s/attribute.job_workflow_ref/%s/.github/workflows/%s@%s' \
    "$1" "$GITHUB_REPO" "$2" "$WIF_ALLOWED_REF"
}

# The repo-wide principal every binding used before 2026-10-09: ANY workflow
# on ANY branch. Named only so scripts can remove it.
wif_repo_member() {
  printf 'principalSet://iam.googleapis.com/%s/attribute.repository/%s' "$1" "$GITHUB_REPO"
}

# ── IAM helpers shared by 03-iam.sh, 11-retire-ingest-writer.sh and
#    99-teardown.sh ──────────────────────────────────────────────────────────

# grant_dataset_role <sa-email> <role> <dataset>
# Dataset-level grants via dataset access entries (bq show → append → bq
# update --source). 'bq add-iam-policy-binding' on a DATASET needs Google
# allowlisting; access entries are the GA mechanism for the same grant.
# Check-then-converge: no-op when the entry already exists.
# shellcheck disable=SC2086  # $BQ is intentionally word-split
grant_dataset_role() {
  ds_email="$1"; ds_role="$2"; ds_name="$3"
  if is_dry_run; then
    log "[dry-run] bq update --source <access+={\"role\":\"$ds_role\",\"userByEmail\":\"$ds_email\"}> $GCP_PROJECT_ID:$ds_name"
    return 0
  fi
  ds_tmp="$(mktemp)"
  $BQ show --format=prettyjson "$GCP_PROJECT_ID:$ds_name" > "$ds_tmp"
  if DS_EMAIL="$ds_email" DS_ROLE="$ds_role" python3 - "$ds_tmp" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
email, role = os.environ["DS_EMAIL"], os.environ["DS_ROLE"]
# BigQuery stores premium role strings as legacy names in the access array.
LEGACY = {"roles/bigquery.dataViewer": "READER",
          "roles/bigquery.dataEditor": "WRITER",
          "roles/bigquery.dataOwner": "OWNER"}
wanted = {role, LEGACY.get(role, role)}
with open(path) as f:
    ds = json.load(f)
access = ds.get("access", [])
if any(e.get("userByEmail") == email and e.get("role") in wanted for e in access):
    sys.exit(3)  # already present — converged
access.append({"role": role, "userByEmail": email})
with open(path, "w") as f:
    json.dump({"access": access}, f)
sys.exit(0)
PYEOF
  then
    run $BQ update --source "$ds_tmp" "$GCP_PROJECT_ID:$ds_name"
    log "  granted $ds_role to $ds_email on $ds_name"
  else
    rc=$?
    if [ "$rc" -eq 3 ]; then
      log "  $ds_email already has $ds_role on $ds_name — converging"
    else
      rm -f "$ds_tmp"
      die "failed to compute access entries for $GCP_PROJECT_ID:$ds_name"
    fi
  fi
  rm -f "$ds_tmp"
}

# revoke_dataset_role <sa-email> <role> <dataset>
# Mirror of grant_dataset_role. Accepts both premium and legacy role names in
# the access array (dataViewer→READER, dataEditor→WRITER). Re-runnable:
# absent entry or absent dataset is a no-op.
# shellcheck disable=SC2086  # $BQ is intentionally word-split
revoke_dataset_role() {
  ds_email="$1"; ds_role="$2"; ds_name="$3"
  if is_dry_run; then
    log "[dry-run] bq update --source <access-={\"role\":\"$ds_role\",\"userByEmail\":\"$ds_email\"}> $GCP_PROJECT_ID:$ds_name"
    return 0
  fi
  if ! probe $BQ show --format=none "$GCP_PROJECT_ID:$ds_name"; then
    info "dataset $ds_name absent — nothing to revoke"
    return 0
  fi
  ds_tmp="$(mktemp)"
  $BQ show --format=prettyjson "$GCP_PROJECT_ID:$ds_name" > "$ds_tmp"
  if DS_EMAIL="$ds_email" DS_ROLE="$ds_role" python3 - "$ds_tmp" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
email, role = os.environ["DS_EMAIL"], os.environ["DS_ROLE"]
LEGACY = {"roles/bigquery.dataViewer": "READER",
          "roles/bigquery.dataEditor": "WRITER",
          "roles/bigquery.dataOwner": "OWNER"}
wanted = {role, LEGACY.get(role, role)}
with open(path) as f:
    ds = json.load(f)
access = ds.get("access", [])
kept = [e for e in access
        if not (e.get("userByEmail") == email and e.get("role") in wanted)]
if len(kept) == len(access):
    sys.exit(3)  # already absent — converged
with open(path, "w") as f:
    json.dump({"access": kept}, f)
sys.exit(0)
PYEOF
  then
    run $BQ update --source "$ds_tmp" "$GCP_PROJECT_ID:$ds_name"
    log "  revoked $ds_role from $ds_email on $ds_name"
  else
    rc=$?
    if [ "$rc" -eq 3 ]; then
      info "dataset grant $ds_role for $ds_email on $ds_name already absent"
    else
      rm -f "$ds_tmp"
      die "failed to compute access entries for $GCP_PROJECT_ID:$ds_name"
    fi
  fi
  rm -f "$ds_tmp"
}

# remove_project_binding <sa-email> <role>. Checks first, because
# 'remove-iam-policy-binding' exits 1 when the binding is already absent.
remove_project_binding() {
  local email="$1" role="$2"
  if is_dry_run || gcloud projects get-iam-policy "$GCP_PROJECT_ID" \
      --flatten='bindings[].members' \
      --filter="bindings.role=$role AND bindings.members=serviceAccount:$email" \
      --format='value(bindings.role)' 2>/dev/null | grep -q .; then
    run gcloud projects remove-iam-policy-binding "$GCP_PROJECT_ID" \
      --member="serviceAccount:$email" --role="$role" \
      --condition=None --format=none --quiet
  else
    info "project binding $role for $email already absent"
  fi
}

# remove_resource_binding <kind> <resource> <member> <role> [extra flags...]
# Removes a binding on a service account or secret if it is there. <kind> is
# the gcloud group: "iam service-accounts" or "secrets".
remove_resource_binding() {
  local kind="$1" resource="$2" member="$3" role="$4"
  shift 4
  # shellcheck disable=SC2086  # $kind is two words on purpose
  if is_dry_run || gcloud $kind get-iam-policy "$resource" --project "$GCP_PROJECT_ID" "$@" \
      --flatten='bindings[].members' \
      --filter="bindings.role=$role AND bindings.members=\"$member\"" \
      --format='value(bindings.role)' 2>/dev/null | grep -q .; then
    # shellcheck disable=SC2086
    run gcloud $kind remove-iam-policy-binding "$resource" --project "$GCP_PROJECT_ID" "$@" \
      --member="$member" --role="$role" --format=none --quiet
  else
    info "$role for $member on $resource already absent"
  fi
}

delete_all_user_keys() { # <sa-email>
  local email="$1" key
  if is_dry_run; then
    log "[dry-run] delete all user-managed keys on $email"
    return 0
  fi
  for key in $(gcloud iam service-accounts keys list --iam-account "$email" \
      --project "$GCP_PROJECT_ID" --managed-by=user \
      --format='value(name.basename())' 2>/dev/null || true); do
    run gcloud iam service-accounts keys delete "$key" \
      --iam-account "$email" --project "$GCP_PROJECT_ID" --quiet
  done
}

revoke_sa() { # <sa-email> <label>  — bindings assumed already removed
  local email="$1" label="$2"
  delete_all_user_keys "$email"
  if is_dry_run || probe gcloud iam service-accounts describe "$email" --project "$GCP_PROJECT_ID"; then
    run gcloud iam service-accounts disable "$email" --project "$GCP_PROJECT_ID" --quiet
    info "$label disabled (reversible: gcloud iam service-accounts enable $email)"
  fi
}

# ── Removing an account from everything ────────────────────────────────────
# revoke_dataset_role and remove_project_binding above remove one named grant.
# Retiring an account needs the opposite: whatever it holds, wherever it is,
# in whatever form. A dataset access entry can name it as userByEmail or as
# iamMember, under a legacy role (WRITER, OWNER) or a premium one, and once
# the account is deleted IAM rewrites it as deleted:serviceAccount:<email>?uid=.
# Removing only the grants a script once made is how a retired account can
# keep write access to a dataset after 11-retire-ingest-writer.sh has run.

# policy_members_of <email>: reads an IAM policy (JSON) on stdin and prints
# "<role><TAB><member>" for every binding that names <email>, live or deleted.
policy_members_of() {
  POLICY_EMAIL="$1" python3 -c '
import json, os, sys
email = os.environ["POLICY_EMAIL"].lower()
try:
    policy = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for b in policy.get("bindings", []):
    for m in b.get("members", []):
        bare = m.split("?", 1)[0].lower()
        if bare in ("serviceaccount:" + email, "deleted:serviceaccount:" + email):
            print(b["role"] + "\t" + m)
'
}

# dataset_entries_of <email>: reads a dataset (bq show JSON) on stdin and
# prints the role of every access entry that names <email>, in any form.
dataset_entries_of() {
  DS_EMAIL="$1" python3 -c '
import json, os, sys
email = os.environ["DS_EMAIL"].lower()
try:
    ds = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for e in ds.get("access", []):
    bare = (e.get("iamMember") or "").split("?", 1)[0].lower()
    if (e.get("userByEmail") or "").lower() == email or \
            bare in ("serviceaccount:" + email, "deleted:serviceaccount:" + email):
        print(e.get("role", ""))
'
}

# revoke_dataset_member <email> <dataset>: drop every access entry on the
# dataset that names <email>, whatever the role or form. No-op when absent.
# shellcheck disable=SC2086  # $BQ is intentionally word-split
revoke_dataset_member() {
  dm_email="$1"; dm_name="$2"
  if is_dry_run; then
    log "[dry-run] bq update --source <access-=every entry naming $dm_email> $GCP_PROJECT_ID:$dm_name"
    return 0
  fi
  dm_tmp="$(mktemp)"
  if ! $BQ show --format=prettyjson "$GCP_PROJECT_ID:$dm_name" > "$dm_tmp" 2>/dev/null; then
    rm -f "$dm_tmp"
    info "dataset $dm_name absent — nothing to revoke"
    return 0
  fi
  if [ -z "$(dataset_entries_of "$dm_email" < "$dm_tmp")" ]; then
    rm -f "$dm_tmp"
    return 0
  fi
  DS_EMAIL="$dm_email" python3 - "$dm_tmp" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
email = os.environ["DS_EMAIL"].lower()
def names(e):
    if (e.get("userByEmail") or "").lower() == email:
        return True
    bare = (e.get("iamMember") or "").split("?", 1)[0].lower()
    return bare in ("serviceaccount:" + email, "deleted:serviceaccount:" + email)
with open(path) as f:
    ds = json.load(f)
access = ds.get("access", [])
for e in access:
    if names(e):
        print("  dropping %s for %s" % (e.get("role"), email))
with open(path, "w") as f:
    json.dump({"access": [e for e in access if not names(e)]}, f)
PYEOF
  run $BQ update --source "$dm_tmp" "$GCP_PROJECT_ID:$dm_name"
  rm -f "$dm_tmp"
}

# project_datasets: every dataset in the project, not only the ones client.env
# names. A grant on a dataset nobody listed is still a grant.
# shellcheck disable=SC2086  # $BQ is intentionally word-split
project_datasets() {
  $BQ ls --format=json --max_results=10000 2>/dev/null | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except ValueError:
    rows = []
for d in rows or []:
    print(d["datasetReference"]["datasetId"])
'
}

# strip_member_everywhere <email>: remove <email> from the project policy,
# every dataset, every secret, every service account's policy, every bucket
# and every Cloud Run service in RUN_REGION. Re-runnable.
strip_member_everywhere() {
  local email="$1" role member res ds
  if is_dry_run; then
    log "[dry-run] remove every binding naming $email: project, all datasets, secrets, service accounts, buckets, Cloud Run"
    return 0
  fi
  info "Removing $email from every policy in $GCP_PROJECT_ID"
  gcloud projects get-iam-policy "$GCP_PROJECT_ID" --format=json \
    | policy_members_of "$email" | while IFS="$(printf '\t')" read -r role member; do
      # --all: a conditional binding is still a binding.
      run gcloud projects remove-iam-policy-binding "$GCP_PROJECT_ID" \
        --member="$member" --role="$role" --all --format=none --quiet </dev/null
    done
  for ds in $(project_datasets); do
    revoke_dataset_member "$email" "$ds"
  done
  for res in $(gcloud secrets list --project "$GCP_PROJECT_ID" --format='value(name.basename())' 2>/dev/null); do
    gcloud secrets get-iam-policy "$res" --project "$GCP_PROJECT_ID" --format=json 2>/dev/null \
      | policy_members_of "$email" | while IFS="$(printf '\t')" read -r role member; do
        run gcloud secrets remove-iam-policy-binding "$res" --project "$GCP_PROJECT_ID" \
          --member="$member" --role="$role" --format=none --quiet </dev/null
      done
  done
  for res in $(gcloud iam service-accounts list --project "$GCP_PROJECT_ID" --format='value(email)' 2>/dev/null); do
    gcloud iam service-accounts get-iam-policy "$res" --project "$GCP_PROJECT_ID" --format=json 2>/dev/null \
      | policy_members_of "$email" | while IFS="$(printf '\t')" read -r role member; do
        run gcloud iam service-accounts remove-iam-policy-binding "$res" --project "$GCP_PROJECT_ID" \
          --member="$member" --role="$role" --format=none --quiet </dev/null
      done
  done
  for res in $(gcloud storage buckets list --project "$GCP_PROJECT_ID" --format='value(name)' 2>/dev/null); do
    gcloud storage buckets get-iam-policy "gs://$res" --format=json 2>/dev/null \
      | policy_members_of "$email" | while IFS="$(printf '\t')" read -r role member; do
        run gcloud storage buckets remove-iam-policy-binding "gs://$res" \
          --member="$member" --role="$role" --format=none --quiet </dev/null
      done
  done
  if [ -n "${RUN_REGION:-}" ]; then
    for res in $(gcloud run services list --project "$GCP_PROJECT_ID" --region "$RUN_REGION" \
        --format='value(metadata.name)' 2>/dev/null); do
      gcloud run services get-iam-policy "$res" --project "$GCP_PROJECT_ID" --region "$RUN_REGION" \
          --format=json 2>/dev/null \
        | policy_members_of "$email" | while IFS="$(printf '\t')" read -r role member; do
          run gcloud run services remove-iam-policy-binding "$res" --project "$GCP_PROJECT_ID" \
            --region "$RUN_REGION" --member="$member" --role="$role" --format=none --quiet </dev/null
        done
    done
  fi
}

# ── Workload identity federation: one way in ───────────────────────────────
# The design has one pool (WIF_POOL), one provider in it (github), and
# bindings that each name one workflow file on WIF_ALLOWED_REF. Anything else
# that lets a GitHub token from GITHUB_REPO into the project is a second way
# in.
#
# The pool is shared: other repositories (e.g. hfscdogg/flywheel-kitchen) have
# their own providers in it, and their own bindings on their own accounts. A
# provider whose condition pins assertion.repository to another repository,
# and a binding that names another repository, are not ours: nothing here
# flags, deletes or removes them, and the pool is never deleted while such a
# provider remains.

GITHUB_OIDC_ISSUER="https://token.actions.githubusercontent.com"

# wif_providers: "<pool><TAB><provider><TAB><issuer><TAB><other-repo>" for
# every active provider in every pool of the project. <issuer> is '-' when the
# provider is not OIDC. <other-repo> is the repository the provider's
# attributeCondition pins it to when that is not GITHUB_REPO, so the provider
# cannot accept this repository's tokens; '-' otherwise. A condition with
# '||' or a negation is never read as pinned elsewhere: it may still let this
# repository in.
wif_providers() {
  local pool
  for pool in $(gcloud iam workload-identity-pools list --project "$GCP_PROJECT_ID" \
      --location=global --format='value(name.basename())' 2>/dev/null); do
    gcloud iam workload-identity-pools providers list --project "$GCP_PROJECT_ID" \
        --location=global --workload-identity-pool="$pool" --format=json 2>/dev/null \
      | POOL="$pool" REPO="${GITHUB_REPO:-}" python3 -c '
import json, os, re, sys
repo = os.environ["REPO"].lower()

def pinned_elsewhere(cond):
    if not repo or repo in cond.lower() or "||" in cond or re.search(r"!(?!=)", cond):
        return ""
    pins = re.findall(r"assertion\.repository\s*==\s*[\x27\"]([^\x27\"]+)[\x27\"]", cond)
    others = [r for r in pins if r.lower() != repo]
    return others[0] if others else ""

try:
    rows = json.load(sys.stdin)
except ValueError:
    rows = []
for p in rows or []:
    if p.get("state", "ACTIVE") != "ACTIVE":
        continue
    print("\t".join([os.environ["POOL"], p["name"].rsplit("/", 1)[1],
                     (p.get("oidc") or {}).get("issuerUri", "") or "-",
                     pinned_elsewhere(p.get("attributeCondition") or "") or "-"]))
'
  done
}

# stray_wif_providers: "<pool><TAB><provider>" for each second way in for
# GITHUB_REPO's tokens: every other provider in WIF_POOL, and any provider
# elsewhere in the project that accepts GitHub Actions tokens, unless its
# condition pins it to another repository.
stray_wif_providers() {
  local pool provider issuer elsewhere
  wif_providers | while IFS="$(printf '\t')" read -r pool provider issuer elsewhere; do
    [ "$elsewhere" = "-" ] || continue
    if [ "$pool" = "$WIF_POOL" ]; then
      [ "$provider" = "github" ] || printf '%s\t%s\n' "$pool" "$provider"
    elif [ "$issuer" = "$GITHUB_OIDC_ISSUER" ]; then
      printf '%s\t%s\n' "$pool" "$provider"
    fi
  done
}

# other_repo_wif_providers <pool>: "<provider><TAB><repository>" for each
# provider in <pool> pinned to a repository other than GITHUB_REPO.
other_repo_wif_providers() {
  local want="$1" pool provider issuer elsewhere
  wif_providers | while IFS="$(printf '\t')" read -r pool provider issuer elsewhere; do
    [ "$pool" = "$want" ] && [ "$elsewhere" != "-" ] && printf '%s\t%s\n' "$provider" "$elsewhere"
  done
  return 0
}

# delete_stray_wif_providers: delete them, and any pool other than WIF_POOL
# that this leaves with no provider (a pool that still holds another
# repository's provider is kept). Deletion is soft for 30 days
# ('gcloud iam workload-identity-pools providers undelete').
delete_stray_wif_providers() {
  local pool provider left
  if is_dry_run; then
    log "[dry-run] delete every WIF provider but $WIF_POOL/github that accepts GitHub tokens from $GITHUB_REPO (providers pinned to another repository are kept)"
    return 0
  fi
  local stray
  stray="$(stray_wif_providers)"
  printf '%s\n' "$stray" | while IFS="$(printf '\t')" read -r pool provider; do
    [ -n "$pool" ] || continue
    info "Deleting WIF provider $pool/$provider (a second way in for GitHub tokens)"
    run gcloud iam workload-identity-pools providers delete "$provider" \
      --project "$GCP_PROJECT_ID" --location=global --workload-identity-pool="$pool" --quiet </dev/null
    if [ "$pool" != "$WIF_POOL" ]; then
      left="$(gcloud iam workload-identity-pools providers list --project "$GCP_PROJECT_ID" \
        --location=global --workload-identity-pool="$pool" --format='value(name)' 2>/dev/null </dev/null || true)"
      if [ -z "$left" ]; then
        info "Deleting the now-empty pool $pool"
        run gcloud iam workload-identity-pools delete "$pool" \
          --project "$GCP_PROJECT_ID" --location=global --quiet </dev/null
      fi
    fi
  done
}

# delete_wif_federation: teardown of this repository's way in. Deletes the
# stray providers, then WIF_POOL, unless another repository's provider is
# still in it: then only WIF_POOL/github goes and the pool stays.
delete_wif_federation() {
  delete_stray_wif_providers
  if is_dry_run; then
    log "[dry-run] if $WIF_POOL still holds a provider pinned to another repository, delete only $WIF_POOL/github and keep the pool; otherwise:"
    run gcloud iam workload-identity-pools delete "$WIF_POOL" \
      --project "$GCP_PROJECT_ID" --location=global --quiet
    return 0
  fi
  if ! probe gcloud iam workload-identity-pools describe "$WIF_POOL" \
      --project "$GCP_PROJECT_ID" --location=global; then
    info "workload identity pool $WIF_POOL already absent"
    return 0
  fi
  local others
  others="$(other_repo_wif_providers "$WIF_POOL")"
  if [ -n "$others" ]; then
    info "Keeping pool $WIF_POOL: it holds providers for other repositories: $(printf '%s' "$others" | tr '\t\n' ': ')"
    if probe gcloud iam workload-identity-pools providers describe github \
        --project "$GCP_PROJECT_ID" --location=global --workload-identity-pool="$WIF_POOL"; then
      run gcloud iam workload-identity-pools providers delete github \
        --project "$GCP_PROJECT_ID" --location=global --workload-identity-pool="$WIF_POOL" --quiet
    else
      info "WIF provider $WIF_POOL/github already absent"
    fi
  else
    run gcloud iam workload-identity-pools delete "$WIF_POOL" \
      --project "$GCP_PROJECT_ID" --location=global --quiet
  fi
}

# loose_wif_bindings <pool-name>: "<sa><TAB><role><TAB><member>" for every
# federated principal bound on any service account that could match
# GITHUB_REPO's tokens and is not one workflow file on WIF_ALLOWED_REF in
# WIF_POOL: the repo-wide principalSet, another branch, this repository from
# another pool, the whole pool, the repository owner, or any principal from a
# pool of this project that no longer exists. A principal that names another
# repository is that repository's, and is never listed.
loose_wif_bindings() {
  local pool_name="$1" sa pools
  pools="$(gcloud iam workload-identity-pools list --project "$GCP_PROJECT_ID" \
    --location=global --format='value(name)' 2>/dev/null || true)"
  for sa in $(gcloud iam service-accounts list --project "$GCP_PROJECT_ID" --format='value(email)' 2>/dev/null); do
    gcloud iam service-accounts get-iam-policy "$sa" --project "$GCP_PROJECT_ID" --format=json 2>/dev/null \
      | SA="$sa" POOL_NAME="$pool_name" POOLS="$pools" REPO="$GITHUB_REPO" REF="$WIF_ALLOWED_REF" python3 -c '
import json, os, re, sys
try:
    policy = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
pool_name, repo = os.environ["POOL_NAME"], os.environ["REPO"]
rl, owner = repo.lower(), repo.lower().split("/")[0]
pools = set(os.environ.get("POOLS", "").split())
project = pool_name.split("/locations/")[0] + "/"
pinned = "principalSet://iam.googleapis.com/%s/attribute.job_workflow_ref/%s/.github/workflows/" % (
    pool_name, repo)
suffix = "@" + os.environ["REF"]
member_re = re.compile(r"^principal(?:Set)?://iam\.googleapis\.com/"
                       r"(projects/[^/]+/locations/global/workloadIdentityPools/[^/]+)(?:/(.*))?$")

def could_be_ours(pool, rest):
    if pools and pool.startswith(project) and pool not in pools:
        return True  # its pool is gone
    if rest in ("", "*"):
        return True  # anyone the pool admits
    kind, _, value = rest.partition("/")
    v = value.lower()
    if kind == "attribute.repository":
        return v == rl
    if kind == "attribute.repository_owner":
        return v == owner
    if kind == "attribute.job_workflow_ref":
        return v.startswith(rl + "/")
    if kind == "subject":
        return v == "repo:" + rl or v.startswith("repo:" + rl + ":")
    return rl in v

for b in policy.get("bindings", []):
    for m in b.get("members", []):
        if not m.startswith(("principal://", "principalSet://")):
            continue
        wf = m[len(pinned):] if m.startswith(pinned) else ""
        name = wf[: -len(suffix)] if wf.endswith(suffix) else ""
        if name.endswith((".yml", ".yaml")) and "/" not in name:
            continue
        hit = member_re.match(m)
        if hit and could_be_ours(hit.group(1), hit.group(2) or ""):
            print("\t".join([os.environ["SA"], b["role"], m]))
'
  done
}

# remove_loose_wif_bindings <pool-name>: remove every binding
# loose_wif_bindings lists. Listed in full before anything is removed, so no
# removal races the reads.
remove_loose_wif_bindings() {
  local loose sa role member
  if is_dry_run; then
    log "[dry-run] remove every federated binding that is not one workflow file on $WIF_ALLOWED_REF and could match $GITHUB_REPO (bindings naming another repository are kept)"
    return 0
  fi
  loose="$(loose_wif_bindings "$1")"
  printf '%s\n' "$loose" | while IFS="$(printf '\t')" read -r sa role member; do
    [ -n "$sa" ] || continue
    info "Removing loose federated binding on $sa: $member"
    run gcloud iam service-accounts remove-iam-policy-binding "$sa" --project "$GCP_PROJECT_ID" \
      --member="$member" --role="$role" --format=none --quiet </dev/null
  done
}
