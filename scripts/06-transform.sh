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
require_cmd bq python3

# Set by validate_sql; checked once at the end so one bad model does not hide
# the others — the point of validating is to see every problem at once.
VALIDATE_FAILED=0
# Tables whose schema could not be read, so their descriptions were not
# applied. Collected rather than fatal — see describe_columns.
#
# describe_columns must stay a plain call in run_sql. Pipe it, or wrap it in
# $(...), and it runs in a subshell where this assignment is discarded — the
# run would then go green over an undescribed table, which is the failure this
# variable exists to prevent.
DESCRIBE_FAILED=""

# COLUMN DESCRIPTIONS ARE ONE OPERATION, NOT ONE PER COLUMN
#
# BigQuery caps table metadata updates at 5 per 10 seconds per table, and the
# models here carry 7 to 26 descriptions each. Issued as separate ALTERs they
# exceed that, and the failure lands AFTER the CREATE: the table rebuilt and
# correct, its descriptions half applied, the run red. Three attempts to pace
# around the cap each failed differently — five at a time (the CREATE also
# counts), four then five (the gap is measured start to start, so batches
# overlap in a sliding window), and again on a table rebuilt many times in one
# day. Pacing was the wrong shape of fix.
#
# `bq update --schema` sets every description in ONE call. The cap stops being
# something to stay under, and the pauses go with it — about eight minutes off
# a full transform.
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

# The table a model builds, e.g. "marts.kpi_subscription_audit".
model_table() {
  awk '/^CREATE OR REPLACE TABLE /{print $5; exit}' "$1"
}

# Read the built table's schema, merge in the descriptions the model declares,
# write it back once. Two metadata reads and one write per table, against a
# cap of five per ten seconds, so there is nothing to pace.
#
# A description naming a column the table does not have stops the run, the way
# the ALTER it replaces did: scripts/lib/merge_descriptions.py exits non-zero
# and set -e carries it. Without that a renamed column would go quietly
# undescribed until check_described caught it minutes later, naming no model.
describe_columns() {
  local f="$1" table schema merged
  table="$(model_table "$f")"
  [ -n "$table" ] || die "no CREATE OR REPLACE TABLE in ${f#"$REPO_ROOT"/}"
  schema="$(mktemp)"
  merged="$(mktemp)"
  # shellcheck disable=SC2064  # expand the paths now, not at trap time
  trap "rm -f '$schema' '$merged'" RETURN

  log "  \$ bq update --schema $table   # all columns, one call"
  # shellcheck disable=SC2086  # $BQ is intentionally word-split
  $BQ show --schema --format=prettyjson "$table" > "$schema"

  # bq exits 0 and prints NOTHING for a table with no columns, so set -e
  # cannot see this and the empty file is the only evidence. Feeding it to
  # merge_descriptions.py ends the run on a JSONDecodeError naming a line of
  # Python rather than a table -- which is how four consecutive nightly
  # transforms died at stg_alarmdotcom__customers, three models into staging,
  # leaving every mart unbuilt while the manual runs people did instead
  # looked fine.
  #
  # Recorded and reported after the build instead, the same shape as
  # missing_input skipping a model and check_described running last: one
  # undescribable table must not cost every model behind it. The run still
  # goes red -- check_describe_failures below -- but the data is fresh first.
  # check_described cannot catch this one on its own: a table with no columns
  # has no column missing a description.
  if [ ! -s "$schema" ]; then
    warn "$table: bq returned an empty schema — the table has no columns"
    DESCRIBE_FAILED="$DESCRIBE_FAILED $table"
    return 0
  fi

  python3 "$SCRIPT_DIR/lib/merge_descriptions.py" "$f" < "$schema" > "$merged"
  # shellcheck disable=SC2086  # $BQ is intentionally word-split
  $BQ update --schema "$merged" "$table" >/dev/null
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
# Runs after the build, before check_described, and names what that check
# cannot: a table with no columns reports no undescribed column, so without
# this an empty-schema table would pass silently.
check_describe_failures() {
  local t
  [ -n "$DESCRIBE_FAILED" ] || return 0
  warn "tables whose schema could not be read, so no description was applied:"
  for t in $DESCRIBE_FAILED; do
    warn "    $t"
  done
  warn "a table with no columns is a build that produced nothing usable —"
  warn "check the model's source data landed, and that its SELECT projects columns"
  die "every other model was built; fix these and re-run"
}

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
  if is_validate; then
    info "Validating selected models (no build) for '$CLIENT_SLUG'"
  else
    info "Transform (selected models) for '$CLIENT_SLUG' in $GCP_PROJECT_ID"
  fi
  for f in "$@"; do
    [ -f "$f" ] || die "no such model file: $f"
    run_sql "$f"
  done
  # The dataset-wide description sweep is deliberately skipped for an explicit
  # model list, but this reports only the models just run, so silence here
  # would mean "Transform done." over a table that got no descriptions.
  is_validate || check_describe_failures
else
  if is_validate; then
    info "Validating (no build) for '$CLIENT_SLUG' in $GCP_PROJECT_ID"
  else
    info "Transform for '$CLIENT_SLUG' in $GCP_PROJECT_ID: staging"
  fi
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
    info "NOTHING WAS BUILT — this was a validation pass. To build:"
    info "  ./scripts/06-transform.sh $CLIENT_SLUG"
    exit 0
  else
    info "Transform: every agent-readable table described"
    check_describe_failures
    check_described
  fi
fi

info "Transform done."
