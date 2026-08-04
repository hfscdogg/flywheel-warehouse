#!/usr/bin/env bash
# 01-datasets.sh <client-slug> — create/converge the BigQuery datasets and
# their canary tables.
#
# Idempotency: check-then-converge, never 'bq mk --force' ('--force' exits 0
# on an existing dataset but silently skips, so label/description drift is
# never corrected and real errors can be masked).
# shellcheck disable=SC2086  # $BQ and label flag strings are intentionally word-split
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0"
load_client "$1"
require_cmd bq

info "Datasets for '$CLIENT_SLUG' in $GCP_PROJECT_ID ($BQ_LOCATION)"

for ds in $ALL_DATASETS; do
  DESC="Flywheel-managed dataset for $CLIENT_DISPLAY_NAME (client=$CLIENT_SLUG)"
  if probe $BQ show --format=none "$GCP_PROJECT_ID:$ds"; then
    info "dataset $ds exists — converging description/labels"
    # Note: 'bq update' labels use '--set_label k:v' (colon), unlike
    # 'bq mk' which uses '--label k=v' (equals).
    run $BQ update --description "$DESC" $BQ_UPDATE_LABELS "$GCP_PROJECT_ID:$ds"
  else
    info "creating dataset $ds"
    run $BQ mk --dataset --location="$BQ_LOCATION" --description "$DESC" \
      $BQ_MK_LABELS "$GCP_PROJECT_ID:$ds"
  fi
done

# Canary tables in marts and each raw dataset: they let 90-verify prove the
# reader SA's access boundaries before any real data exists. CREATE TABLE IF
# NOT EXISTS is natively idempotent.
info "Canary tables"
for ds in $DATASETS_RAW $DATASET_MARTS; do
  # shellcheck disable=SC2016  # backticks are BigQuery identifier quoting, not expansion
  SQL="$(printf 'CREATE TABLE IF NOT EXISTS `%s.%s._flywheel_canary` AS SELECT "%s" AS dataset, CURRENT_TIMESTAMP() AS created_at' \
    "$GCP_PROJECT_ID" "$ds" "$ds")"
  run $BQ query --use_legacy_sql=false --format=none "$SQL"
done

info "Datasets done."
