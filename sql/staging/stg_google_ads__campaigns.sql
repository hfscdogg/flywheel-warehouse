-- stg_google_ads__campaigns — Google Ads campaigns, one row each.
-- Grain: one row per campaign_id.
-- Source: raw_google_ads.campaigns, a view (01-datasets.sh) over the Google
-- Ads transfer's Campaign report, which holds a full copy of every campaign
-- for each day the transfer ran. The newest copy is the campaign as it is now.
CREATE OR REPLACE TABLE staging.stg_google_ads__campaigns
OPTIONS (description = """
Google Ads campaigns, one row per campaign, as of the transfer's newest run: name, status, type, bidding strategy and budget.
Status is today's; a campaign paused now may have run in the past. For what a campaign spent and when, use stg_google_ads__campaign_daily.
""")
AS
WITH latest AS (
  SELECT
    campaign_id, customer_id, campaign_name, campaign_status, campaign_serving_status,
    campaign_advertising_channel_type, campaign_advertising_channel_sub_type,
    campaign_bidding_strategy_type, campaign_budget_amount_micros,
    campaign_start_date_time, campaign_end_date_time, partition_time
  FROM raw_google_ads.campaigns
  QUALIFY ROW_NUMBER() OVER (PARTITION BY campaign_id ORDER BY partition_time DESC) = 1
)
SELECT
  campaign_id,
  customer_id,
  campaign_name,
  campaign_status,
  campaign_serving_status,
  campaign_advertising_channel_type                  AS channel_type,
  campaign_advertising_channel_sub_type              AS channel_sub_type,
  campaign_bidding_strategy_type                     AS bidding_strategy_type,
  ROUND(campaign_budget_amount_micros / 1e6, 2)      AS daily_budget,
  DATE(campaign_start_date_time)                     AS start_date,
  DATE(campaign_end_date_time)                       AS end_date,
  partition_time                                     AS loaded_at
FROM latest;

ALTER TABLE staging.stg_google_ads__campaigns ALTER COLUMN campaign_id
  SET OPTIONS (description = "Google Ads campaign id. Unique per row.");
ALTER TABLE staging.stg_google_ads__campaigns ALTER COLUMN customer_id
  SET OPTIONS (description = "Google Ads account id the campaign belongs to.");
ALTER TABLE staging.stg_google_ads__campaigns ALTER COLUMN campaign_name
  SET OPTIONS (description = "Campaign name as set in Google Ads. Names can be edited; the id is what stays fixed.");
ALTER TABLE staging.stg_google_ads__campaigns ALTER COLUMN campaign_status
  SET OPTIONS (description = "ENABLED, PAUSED or REMOVED, as of the newest transfer run.");
ALTER TABLE staging.stg_google_ads__campaigns ALTER COLUMN campaign_serving_status
  SET OPTIONS (description = "Whether Google is serving the campaign now, e.g. SERVING, ENDED, SUSPENDED.");
ALTER TABLE staging.stg_google_ads__campaigns ALTER COLUMN channel_type
  SET OPTIONS (description = "Campaign type: SEARCH, PERFORMANCE_MAX, DISPLAY, LOCAL_SERVICES and so on.");
ALTER TABLE staging.stg_google_ads__campaigns ALTER COLUMN channel_sub_type
  SET OPTIONS (description = "Finer campaign type where Google has one; NULL otherwise.");
ALTER TABLE staging.stg_google_ads__campaigns ALTER COLUMN bidding_strategy_type
  SET OPTIONS (description = "How Google bids, e.g. MAXIMIZE_CONVERSIONS, TARGET_CPA, MANUAL_CPC.");
ALTER TABLE staging.stg_google_ads__campaigns ALTER COLUMN daily_budget
  SET OPTIONS (description = "The campaign budget's amount, USD, as set now. Google may spend up to twice a daily budget on one day while keeping to it over the month.");
ALTER TABLE staging.stg_google_ads__campaigns ALTER COLUMN start_date
  SET OPTIONS (description = "Day the campaign was set to start.");
ALTER TABLE staging.stg_google_ads__campaigns ALTER COLUMN end_date
  SET OPTIONS (description = "Day the campaign is set to end; NULL or a far-future date when it has none.");
ALTER TABLE staging.stg_google_ads__campaigns ALTER COLUMN loaded_at
  SET OPTIONS (description = "The day of the transfer run this row comes from, as a timestamp (midnight UTC).");
