-- kpi_paid_media — Google Ads spend and results per campaign per day.
-- Grain: one row per (date, campaign_id).
--
-- The paid half of marketing: what the ads cost and what Google Ads says
-- they produced. It does not say which deals the ads brought in. The CRM's
-- Marketing Channel does that (kpi_deal_attribution), and it undercounts
-- paid search: from 2026-04-01 to 2026-09-27 one deal was marked "Google Ads
-- (paid)" and 68 "Website inquiry", while GA4 credited 10 of the 12 website
-- form submissions from 2026-08-24 to Paid Search. An ad click that becomes
-- a website form is usually recorded as Website inquiry.
CREATE OR REPLACE TABLE marts.kpi_paid_media
OPTIONS (description = """
Google Ads spend and results per campaign per day, from BigQuery's Google Ads transfer: cost, clicks, impressions, interactions and Google Ads' own conversions, with the campaign's name, type and current status.
Cost, clicks, impressions, interactions and conversions add up across rows. Conversions are Google Ads' count from its conversion actions, not CRM leads or deals.
Cost per deal needs care: the CRM's Marketing Channel records most paid-search leads as Website inquiry, not Google Ads (paid), because the ad click became a website form. Compare spend with kpi_deal_attribution's Marketing & website group, and GA4's Paid Search sessions in kpi_website_traffic, not with Google Ads (paid) alone.
The last week can still move as Google revises clicks and conversions.
""")
AS
WITH d AS (
  SELECT report_date, campaign_id, cost, clicks, impressions, interactions,
         conversions, conversions_value, loaded_at
  FROM staging.stg_google_ads__campaign_daily
),
c AS (
  SELECT campaign_id, campaign_name, channel_type, campaign_status
  FROM staging.stg_google_ads__campaigns
)
SELECT
  d.report_date                                    AS date,
  d.campaign_id,
  COALESCE(c.campaign_name, CONCAT('campaign ', CAST(d.campaign_id AS STRING))) AS campaign_name,
  c.channel_type,
  c.campaign_status,
  d.cost,
  d.clicks,
  d.impressions,
  d.interactions,
  d.conversions,
  d.conversions_value,
  MAX(d.loaded_at) OVER ()                         AS data_through,
  CURRENT_TIMESTAMP()                              AS computed_at
FROM d
LEFT JOIN c USING (campaign_id);

ALTER TABLE marts.kpi_paid_media ALTER COLUMN date
  SET OPTIONS (description = "Day the ads ran, in the Google Ads account's time zone.");
ALTER TABLE marts.kpi_paid_media ALTER COLUMN campaign_id
  SET OPTIONS (description = "Google Ads campaign id; stays fixed when a campaign is renamed.");
ALTER TABLE marts.kpi_paid_media ALTER COLUMN campaign_name
  SET OPTIONS (description = "Campaign name as it is now in Google Ads; 'campaign <id>' when the campaign report has not listed it yet.");
ALTER TABLE marts.kpi_paid_media ALTER COLUMN channel_type
  SET OPTIONS (description = "Campaign type: SEARCH, PERFORMANCE_MAX, DISPLAY, LOCAL_SERVICES and so on.");
ALTER TABLE marts.kpi_paid_media ALTER COLUMN campaign_status
  SET OPTIONS (description = "ENABLED, PAUSED or REMOVED as of today, not as of the row's date.");
ALTER TABLE marts.kpi_paid_media ALTER COLUMN cost
  SET OPTIONS (description = "What Google charged, USD. Adds up across rows.");
ALTER TABLE marts.kpi_paid_media ALTER COLUMN clicks
  SET OPTIONS (description = "Clicks on the ads. Not website visits: GA4 counts those. Adds up across rows.");
ALTER TABLE marts.kpi_paid_media ALTER COLUMN impressions
  SET OPTIONS (description = "Times an ad was shown. Adds up across rows.");
ALTER TABLE marts.kpi_paid_media ALTER COLUMN interactions
  SET OPTIONS (description = "Clicks plus other engagements Google counts for the ad format, such as calls. Adds up across rows.");
ALTER TABLE marts.kpi_paid_media ALTER COLUMN conversions
  SET OPTIONS (description = "Conversions as Google Ads counts them; can be fractional. Not CRM leads or deals. Adds up across rows.");
ALTER TABLE marts.kpi_paid_media ALTER COLUMN conversions_value
  SET OPTIONS (description = "Value Google Ads assigns to those conversions from its settings; not revenue. Adds up across rows.");
ALTER TABLE marts.kpi_paid_media ALTER COLUMN data_through
  SET OPTIONS (description = "Newest day the Google Ads transfer has loaded, the same on every row; later days are not in yet.");
ALTER TABLE marts.kpi_paid_media ALTER COLUMN computed_at
  SET OPTIONS (description = "When this table was built (UTC).");
