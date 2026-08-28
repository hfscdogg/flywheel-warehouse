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

# stg_<source>__<entity>.sql -> raw_<source>.<entity>, the table it reads.
model_raw_table() {
  local b
  b="$(basename "$1" .sql)"
  case "$b" in
    stg_*__*) b="${b#stg_}"; printf 'raw_%s.%s' "${b%%__*}" "${b#*__}" ;;
    *) printf '' ;;
  esac
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

# The staging tables a mart reads, derived from the SQL itself rather than a
# hand-kept manifest: marts write to marts.* and read staging.*, so every
# staging reference in the file is an input. Keeps the list from drifting
# out of step with the model.
mart_staging_deps() {
  grep -oE 'staging\.[a-z0-9_]+' "$1" | sort -u
}

# A mart whose staging inputs are not all built yet must be skipped, not run:
# a staging model can be skipped for a source with no data landed (above), and
# under set -e the mart reading it would otherwise take down every mart after
# it. Reports the first missing table so the skip line says why.
missing_dep() {
  local dep
  for dep in $(mart_staging_deps "$1"); do
    table_present "$dep" || { printf '%s' "$dep"; return 0; }
  done
  return 1
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
    raw_tbl="$(model_raw_table "$f")"
    if ! table_present "$raw_tbl"; then
      info "skip $(basename "$f") — $raw_tbl not found (source enabled, no data landed yet)"
      continue
    fi
    run_sql "$f"
  done
  info "Transform: marts"
  for f in "$REPO_ROOT"/sql/marts/*.sql; do
    [ -f "$f" ] || die "no mart models found under sql/marts/"
    if missing="$(missing_dep "$f")"; then
      info "skip $(basename "$f") — $missing not built (upstream source has no data yet)"
      continue
    fi
    run_sql "$f"
  done
fi

info "Transform done."
