-- stg_google_ads__campaign_daily — Google Ads spend and results per campaign
-- per day.
-- Grain: one row per (report_date, campaign_id).
-- Source: raw_google_ads.campaign_basic_stats, a view (01-datasets.sh) over
-- the Google Ads transfer's CampaignBasicStats report.
--
-- Basic stats, not the transfer's CampaignStats: CampaignStats is also split
-- by click type, and Google counts an impression once for each click type it
-- could lead to, so its impressions run high. Measured 2026-09-27 on the
-- first 35 days: cost, clicks and conversions agree exactly between the two
-- ($1,141.65, 400, 27), impressions do not (4,752 here, 7,645 there).
--
-- The report is also split by device and ad network; this adds those up.
-- Each day is its own partition and the transfer rewrites a day it reloads,
-- so a day is never counted twice (every row's partition equals its date).
CREATE OR REPLACE TABLE staging.stg_google_ads__campaign_daily
OPTIONS (description = """
Google Ads spend and results per campaign per day, from BigQuery's Google Ads transfer: cost, clicks, impressions, interactions, and conversions as Google Ads counts them. Devices and ad networks are added together.
Cost is what Google charged, in USD. Conversions are Google Ads' own count from its conversion actions, fractional under data-driven attribution; they are not CRM leads or deals. For deals, use the Marketing Channel on the deal.
Google can revise a recent day for a few days (invalid clicks, late conversions); the transfer reloads recent days, so the last week can still move.
""")
AS
SELECT
  segments_date                                AS report_date,
  campaign_id,
  ANY_VALUE(customer_id)                       AS customer_id,
  ROUND(SUM(metrics_cost_micros) / 1e6, 2)     AS cost,
  SUM(metrics_clicks)                          AS clicks,
  SUM(metrics_impressions)                     AS impressions,
  SUM(metrics_interactions)                    AS interactions,
  SUM(metrics_conversions)                     AS conversions,
  SUM(metrics_conversions_value)               AS conversions_value,
  MAX(partition_time)                          AS loaded_at
FROM raw_google_ads.campaign_basic_stats
WHERE segments_date = DATE(partition_time)
GROUP BY report_date, campaign_id;

ALTER TABLE staging.stg_google_ads__campaign_daily ALTER COLUMN report_date
  SET OPTIONS (description = "Day the ads ran, in the Google Ads account's time zone.");
ALTER TABLE staging.stg_google_ads__campaign_daily ALTER COLUMN campaign_id
  SET OPTIONS (description = "Google Ads campaign id. Joins to stg_google_ads__campaigns for the name, status and type.");
ALTER TABLE staging.stg_google_ads__campaign_daily ALTER COLUMN customer_id
  SET OPTIONS (description = "Google Ads account id the campaign belongs to.");
ALTER TABLE staging.stg_google_ads__campaign_daily ALTER COLUMN cost
  SET OPTIONS (description = "What Google charged for the day, USD. Adds up across rows.");
ALTER TABLE staging.stg_google_ads__campaign_daily ALTER COLUMN clicks
  SET OPTIONS (description = "Clicks on the ads. A click is not a website visit: GA4 counts the visits that followed. Adds up across rows.");
ALTER TABLE staging.stg_google_ads__campaign_daily ALTER COLUMN impressions
  SET OPTIONS (description = "Times an ad was shown. Adds up across rows.");
ALTER TABLE staging.stg_google_ads__campaign_daily ALTER COLUMN interactions
  SET OPTIONS (description = "Clicks plus other engagements Google counts for the ad format, such as calls from a call ad. Adds up across rows.");
ALTER TABLE staging.stg_google_ads__campaign_daily ALTER COLUMN conversions
  SET OPTIONS (description = "Conversions as Google Ads counts them from the account's conversion actions; can be fractional. Not CRM leads or deals. Adds up across rows.");
ALTER TABLE staging.stg_google_ads__campaign_daily ALTER COLUMN conversions_value
  SET OPTIONS (description = "Value Google Ads assigns to those conversions, from the conversion actions' settings; zero when no value is set. Not revenue. Adds up across rows.");
ALTER TABLE staging.stg_google_ads__campaign_daily ALTER COLUMN loaded_at
  SET OPTIONS (description = "The day the transfer loaded this row for, as a timestamp (midnight UTC). How current Google Ads data is.");
