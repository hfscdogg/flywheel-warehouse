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

# Google Analytics 4 is not ingested. Google writes the property's export into
# this project as one table per day (events_YYYYMMDD), and raw_ga4.events is
# a view over those, so staging reads raw_<source>.<entity> like every other
# source and the transform's missing-input and source-enabled checks apply
# unchanged. The intraday tables (events_intraday_YYYYMMDD) are left out:
# they are replaced by the day's final table and would count a day twice.
# Explicit columns, so a field Google adds does not change the view.
if [ -n "$GA4_EXPORT_DATASET" ]; then
  info "View raw_ga4.events over $GA4_EXPORT_DATASET"
  # shellcheck disable=SC2016  # backticks are BigQuery identifier quoting, not expansion
  SQL="$(printf '%s' "CREATE OR REPLACE VIEW \`$GCP_PROJECT_ID.raw_ga4.events\`
OPTIONS (description = 'Google Analytics 4 export for $CLIENT_DISPLAY_NAME, one row per event, from the daily tables in $GA4_EXPORT_DATASET. Managed by 01-datasets.sh.')
AS
SELECT
  PARSE_DATE('%Y%m%d', event_date) AS event_date,
  event_timestamp,
  event_name,
  event_params,
  user_pseudo_id,
  device.category AS device_category,
  collected_traffic_source,
  session_traffic_source_last_click
FROM \`$GCP_PROJECT_ID.$GA4_EXPORT_DATASET.events_*\`
WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}\$')")"
  run $BQ query --use_legacy_sql=false --format=none "$SQL"
fi

info "Datasets done."
