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

# Google Ads is not ingested either. BigQuery's Google Ads transfer writes
# raw_google_ads.p_ads_<Report>_<customer id>, a name the transform cannot
# find a model's input by (it reads lower-case raw_<source>.<table>) and
# that differs per client. So each report staging reads gets a view with a
# plain name, as GA4 does. The transfer creates its tables on its first
# run; before that there is nothing to put a view over, so a missing report
# is skipped with a warning and this script is re-run after the first load.
# Explicit columns, so a field Google adds does not change the view.
# _PARTITIONTIME is the day each row was reported for.
ads_view() {  # ads_view <view> <report> <description> <columns>
  local table="p_ads_$2_$GOOGLE_ADS_CUSTOMER_ID"
  if ! is_dry_run && ! probe $BQ show --format=none "$GCP_PROJECT_ID:raw_google_ads.$table"; then
    warn "raw_google_ads.$table does not exist yet (the transfer has not run): view raw_google_ads.$1 skipped; re-run this script after the first transfer run"
    return 0
  fi
  info "View raw_google_ads.$1 over $table"
  # shellcheck disable=SC2016  # backticks are BigQuery identifier quoting, not expansion
  SQL="$(printf '%s' "CREATE OR REPLACE VIEW \`$GCP_PROJECT_ID.raw_google_ads.$1\`
OPTIONS (description = '$3 Managed by 01-datasets.sh.')
AS
SELECT _PARTITIONTIME AS partition_time, $4
FROM \`$GCP_PROJECT_ID.raw_google_ads.$table\`")"
  run $BQ query --use_legacy_sql=false --format=none "$SQL"
}

if [ -n "$GOOGLE_ADS_CUSTOMER_ID" ]; then
  ads_view campaign_basic_stats CampaignBasicStats \
    "Google Ads campaign performance for $CLIENT_DISPLAY_NAME, one row per day, campaign, device and network, from the Google Ads transfer." \
    "segments_date, campaign_id, customer_id, segments_device, segments_ad_network_type, metrics_cost_micros, metrics_clicks, metrics_impressions, metrics_interactions, metrics_conversions, metrics_conversions_value"
  ads_view campaigns Campaign \
    "Google Ads campaigns for $CLIENT_DISPLAY_NAME, one row per campaign per day the transfer ran, from the Google Ads transfer." \
    "campaign_id, customer_id, campaign_name, campaign_status, campaign_serving_status, campaign_advertising_channel_type, campaign_advertising_channel_sub_type, campaign_bidding_strategy_type, campaign_budget_amount_micros, campaign_start_date_time, campaign_end_date_time"
fi

info "Datasets done."
