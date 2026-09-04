#!/usr/bin/env bash
# 06-transform.sh <client-slug> [model.sql ...] — build staging and mart
# tables by running the Phase 3 SQL models against the client's project.
#
# Models are plain CREATE OR REPLACE TABLE statements with unqualified
# dataset names (raw_zoho.x, staging.y, marts.z): 'bq query --project_id'
# resolves them against the client's project, so one SQL tree serves every
# client with zero templating.
#
# Idempotent: CREATE OR REPLACE converges to the same state on re-run.
# Ordering matters only between the two directories — staging first, marts
# second (marts read staging); within a directory files are independent.
#
# Staging models for a source the client doesn't use (no raw_<source> in
# DATASETS_RAW) are skipped, mirroring the pipelines' "source disabled"
# behavior. Passing explicit model paths runs exactly those, in order.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0"
load_client "$1"
shift
require_cmd bq

run_sql() {
  local f="$1"
  if is_dry_run; then
    log "[dry-run] $BQ query --use_legacy_sql=false --format=none < ${f#"$REPO_ROOT"/}"
    return 0
  fi
  log "  \$ bq query < ${f#"$REPO_ROOT"/}"
  # shellcheck disable=SC2086  # $BQ is intentionally word-split
  $BQ query --use_legacy_sql=false --format=none < "$f"
}

# stg_<source>__<entity>.sql -> <source>; empty for anything else.
model_source() {
  local b
  b="$(basename "$1")"
  case "$b" in
    stg_*__*) b="${b#stg_}"; printf '%s' "${b%%__*}" ;;
    *) printf '' ;;
  esac
}

source_enabled() {
  local src="$1" ds
  for ds in $DATASETS_RAW; do
    [ "$ds" = "raw_$src" ] && return 0
  done
  return 1
}


# Does <dataset>.<table> exist in the client's project? Models are skipped
# rather than run against a table that isn't there: under set -e one missing
# table would otherwise take the whole transform, every later model included,
# down with it.
table_present() {
  local tbl="$1"
  [ -n "$tbl" ] || return 0            # nothing to check
  is_dry_run && return 0               # dry-run never touches BigQuery
  # shellcheck disable=SC2086  # $BQ is intentionally word-split
  $BQ show --format=none "$GCP_PROJECT_ID:$tbl" >/dev/null 2>&1
}

# The tables a model reads, taken from the SQL itself rather than inferred
# from its filename. A staging model reads raw_<source>.<entity> and writes
# staging.*; a mart reads staging.* and writes marts.*. So within each
# directory every reference of the other kind is an input, and the list can
# never drift out of step with the model.
#
# The filename was the wrong source of truth: stg_qbo__customers.sql looks
# like it reads raw_qbo.customers, but QBO landing tables carry the API's own
# singular entity names (raw_qbo.customer, raw_qbo.purchaseorder), so every
# QBO model was skipped as "no data landed yet" while its data sat there.
model_inputs() {
  case "$(basename "$1")" in
    stg_*) grep -oE 'raw_[a-z0-9_]+\.[a-z0-9_]+' "$1" | sort -u ;;
    *)     grep -oE 'staging\.[a-z0-9_]+' "$1" | sort -u ;;
  esac
}

# A model whose inputs are not all there must be skipped, not run: under set -e
# one missing table would take down every model after it. Reports the first
# one missing so the skip line says which, and the operator can tell a source
# still waiting on credentials from a bug like the one above.
missing_input() {
  local dep
  for dep in $(model_inputs "$1"); do
    table_present "$dep" || { printf '%s' "$dep"; return 0; }
  done
  return 1
}

# Agents learn what a mart means from BigQuery's table and column descriptions
# — hermes-mcp serves exactly those, nothing else — so a mart or column without
# one is not undocumented, it is a table Hermes will query confidently and
# explain wrong. Runs AFTER the marts are built: the data is never left stale,
# the run just goes red until the description is added (in the mart's SQL, as
# OPTIONS on the CREATE and ALTER COLUMN ... SET OPTIONS after it).
check_marts_described() {
  local check="$REPO_ROOT/sql/checks/marts_described.sql" missing
  if is_dry_run; then
    log "[dry-run] $BQ query --format=csv < ${check#"$REPO_ROOT"/}   # expect no rows"
    return 0
  fi
  log "  \$ bq query < ${check#"$REPO_ROOT"/}"
  # shellcheck disable=SC2086  # $BQ is intentionally word-split
  missing="$($BQ query --use_legacy_sql=false --format=csv < "$check" | tail -n +2)"
  [ -z "$missing" ] && { log "  every mart table and column is described"; return 0; }
  warn "marts with no description (what Hermes would see as blank):"
  printf '%s\n' "$missing" | sed 's/^/    /' >&2
  die "add OPTIONS(description) / ALTER COLUMN ... SET OPTIONS in the mart SQL"
}

if [ $# -ge 1 ]; then
  info "Transform (selected models) for '$CLIENT_SLUG' in $GCP_PROJECT_ID"
  for f in "$@"; do
    [ -f "$f" ] || die "no such model file: $f"
    run_sql "$f"
  done
else
  info "Transform for '$CLIENT_SLUG' in $GCP_PROJECT_ID: staging"
  for f in "$REPO_ROOT"/sql/staging/*.sql; do
    [ -f "$f" ] || die "no staging models found under sql/staging/"
    src="$(model_source "$f")"
    if [ -n "$src" ] && ! source_enabled "$src"; then
      info "skip $(basename "$f") — client has no raw_$src (source disabled)"
      continue
    fi
    # A source can be enabled in DATASETS_RAW before its pipeline has ever
    # run — a new source, or one still waiting on credentials.
    if missing="$(missing_input "$f")"; then
      info "skip $(basename "$f") — $missing not found (source enabled, no data landed yet)"
      continue
    fi
    run_sql "$f"
  done
  info "Transform: marts"
  for f in "$REPO_ROOT"/sql/marts/*.sql; do
    [ -f "$f" ] || die "no mart models found under sql/marts/"
    if missing="$(missing_input "$f")"; then
      info "skip $(basename "$f") — $missing not built (upstream source has no data yet)"
      continue
    fi
    run_sql "$f"
  done
  info "Transform: marts described (what agents see)"
  check_marts_described
fi

info "Transform done."
