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

# Set by validate_sql; checked once at the end so one bad model does not hide
# the others — the point of validating is to see every problem at once.
VALIDATE_FAILED=0

# BigQuery caps table metadata updates at 5 per 10 seconds PER TABLE, and the
# models here carry 7 to 26 ALTER COLUMN statements apiece. Sent as one script
# they go over the cap, and the failure lands AFTER the CREATE has run: the
# table is rebuilt and correct, its descriptions are half applied, and the run
# is red. Re-running does not reliably fix it either — a model with more than
# five descriptions can never apply them all in one submission no matter how
# long you wait first, which is what made this look like a quota that needed
# waiting out rather than a batch that needed splitting.
#
# So the build and the descriptions are submitted separately, and the
# descriptions go five at a time with a pause between batches. Deterministic
# instead of lucky, for about two seconds per five columns.
DESCRIBE_BATCH=5
DESCRIBE_PAUSE=11

bq_query() {
  # shellcheck disable=SC2086  # $BQ is intentionally word-split
  $BQ query --use_legacy_sql=false --format=none
}

# VALIDATE=1 checks every model against BigQuery without building anything.
#
# sqlfluff parses these files but does not resolve names, so it passes SQL
# BigQuery then rejects — a HAVING that reads an aggregate through a SELECT
# alias parsed cleanly and failed the whole mart at run time, after four
# merges and several days, because the model only runs at the end of a
# transform. --dry_run does full semantic validation and processes no bytes,
# so the same mistake is a few seconds of feedback instead of a deploy.
#
# Only the build half is validated: the descriptions are ALTERs against a
# table the dry run has not created, so BigQuery cannot check them this way.
is_validate() { [ "${VALIDATE:-0}" = "1" ]; }

validate_sql() {
  local f="$1"
  log "  \$ bq query --dry_run < ${f#"$REPO_ROOT"/}"
  # shellcheck disable=SC2086  # $BQ is intentionally word-split
  if awk '/^ALTER TABLE/{exit} {print}' "$f" \
       | $BQ query --use_legacy_sql=false --dry_run --format=none; then
    return 0
  fi
  warn "INVALID: ${f#"$REPO_ROOT"/}"
  return 1
}

# Everything before the first ALTER builds the table; everything from there on
# describes it. Splitting on the first `ALTER TABLE` at the start of a line
# relies on the same layout pipelines/tests/test_sql_marts_described.py enforces:
# the descriptions are one contiguous block at the end of every model.
run_sql() {
  local f="$1"
  if is_dry_run; then
    log "[dry-run] $BQ query < ${f#"$REPO_ROOT"/}   # build, then descriptions"
    return 0
  fi
  if is_validate; then
    validate_sql "$f" || VALIDATE_FAILED=1
    return 0
  fi
  log "  \$ bq query < ${f#"$REPO_ROOT"/}"
  awk '/^ALTER TABLE/{exit} {print}' "$f" | bq_query
  describe_columns "$f"
}

DESCRIBE_LAST=0

# One batch of descriptions. The cap is measured over a window, so what has to
# be spaced is the START of one batch from the start of the last — and a
# submission already takes several seconds of that window by itself. Sleeping
# only the shortfall rather than the whole window costs nothing in
# correctness and takes about a third off the run.
describe_batch() {
  local chunk="$1" batches="$2" elapsed
  if [ "$batches" -gt 0 ]; then
    elapsed=$(( $(date +%s) - DESCRIBE_LAST ))
    if [ "$elapsed" -lt "$DESCRIBE_PAUSE" ]; then
      sleep "$(( DESCRIBE_PAUSE - elapsed ))"
    fi
  fi
  DESCRIBE_LAST=$(date +%s)
  printf '%s' "$chunk" | bq_query
}

describe_columns() {
  # The CREATE counts against the same cap. It lands two seconds before the
  # first batch does, inside the same ten-second window, so a first batch of
  # five makes six operations and the fifth ALTER is rejected — with the table
  # already rebuilt, which is the failure this whole split exists to prevent.
  # Only the first batch is short; every later one is clear of the build.
  local f="$1" chunk="" stmts=0 batches=0 limit=$((DESCRIBE_BATCH - 1))
  while IFS= read -r line; do
    chunk="$chunk$line"$'\n'
    case "$line" in *\;) stmts=$((stmts + 1)) ;; esac
    [ "$stmts" -lt "$limit" ] && continue
    describe_batch "$chunk" "$batches"
    batches=$((batches + 1))
    chunk=""
    stmts=0
    limit="$DESCRIBE_BATCH"
  done < <(awk '/^ALTER TABLE/,0' "$f")
  # A trailing partial batch, and the whole job for a model with fewer than
  # DESCRIBE_BATCH columns.
  [ "$stmts" -gt 0 ] && describe_batch "$chunk" "$batches"
  # Explicit: the test above is the last command, and a model whose
  # descriptions divided evenly would otherwise return its false.
  return 0
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

# Agents learn what a table means from BigQuery's table and column
# descriptions — hermes-mcp serves exactly those, nothing else — so a table or
# column without one is not undocumented, it is a table Hermes will query
# confidently and explain wrong. Covers marts and staging, since a Tier 2b
# agent reads both. Runs AFTER everything is built: the data is never left
# stale, the run just goes red until the description is added (in the model's
# SQL, as OPTIONS on the CREATE and ALTER COLUMN ... SET OPTIONS after it).
check_described() {
  local check="$REPO_ROOT/sql/checks/described.sql" missing
  if is_dry_run; then
    log "[dry-run] $BQ query --format=csv < ${check#"$REPO_ROOT"/}   # expect no rows"
    return 0
  fi
  log "  \$ bq query < ${check#"$REPO_ROOT"/}"
  # shellcheck disable=SC2086  # $BQ is intentionally word-split
  missing="$($BQ query --use_legacy_sql=false --format=csv < "$check" | tail -n +2)"
  [ -z "$missing" ] && { log "  every mart table and column is described"; return 0; }
  warn "tables or columns with no description (what Hermes would see as blank):"
  printf '%s\n' "$missing" | sed 's/^/    /' >&2
  die "add OPTIONS(description) / ALTER COLUMN ... SET OPTIONS in that model's SQL"
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
  if is_validate; then
    [ "$VALIDATE_FAILED" = 0 ] || die "one or more models are invalid (above)"
    info "every model is valid SQL against this project's schema"
  else
    info "Transform: every agent-readable table described"
    check_described
  fi
fi

info "Transform done."
