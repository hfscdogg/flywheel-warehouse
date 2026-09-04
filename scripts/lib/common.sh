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
           SA_INGEST_WRITER LABEL_MANAGED_BY LABEL_ENV KEY_DIR; do
    eval "[ -n \"\${$v:-}\" ]" || die "client.env for '$slug' is missing required variable: $v"
  done
  [ "$CLIENT_SLUG" = "$slug" ] \
    || die "CLIENT_SLUG ('$CLIENT_SLUG') does not match directory name ('$slug')"
  case "$CLIENT_SLUG$GCP_PROJECT_ID" in
    *CHANGEME*) die "client.env for '$slug' still contains CHANGEME placeholders" ;;
  esac

  SA_HERMES_READER_EMAIL="${SA_HERMES_READER}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
  SA_INGEST_WRITER_EMAIL="${SA_INGEST_WRITER}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
  ALL_DATASETS="$DATASETS_RAW $DATASET_STAGING $DATASET_MARTS"

  # What hermes-reader may read (docs/access-tiers.md). Optional in
  # client.env; absent means narrow, the Tier 2a default.
  AGENT_SCOPE="${AGENT_SCOPE:-narrow}"
  case "$AGENT_SCOPE" in
    narrow) DATASETS_AGENT="$DATASET_MARTS" ;;
    wide)   DATASETS_AGENT="$DATASET_MARTS $DATASET_STAGING" ;;
    *) die "client.env for '$slug': AGENT_SCOPE must be narrow or wide (got '$AGENT_SCOPE')" ;;
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
