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
    run_sql "$f"
  done
  info "Transform: marts"
  for f in "$REPO_ROOT"/sql/marts/*.sql; do
    [ -f "$f" ] || die "no mart models found under sql/marts/"
    run_sql "$f"
  done
fi

info "Transform done."
