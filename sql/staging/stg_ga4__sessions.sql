-- stg_ga4__sessions — website sessions from Google Analytics 4, one row each.
-- Grain: one row per session (user_pseudo_id + ga_session_id).
-- Source: raw_ga4.events, a view over the GA4 property's own daily BigQuery
-- export (01-datasets.sh). Livewire's export starts 2026-08-24.
--
-- A session's channel is GA4's own last-click attribution for it
-- (session_traffic_source_last_click), the figure GA4's Traffic acquisition
-- report shows, with the collected UTM source as the fallback. Landing pages
-- keep the path only: query strings can carry form values and click ids.
--
-- GA4 identifies browsers, not people, and nothing here joins to a CRM deal.
-- Which channel a deal came from is the reviewed Marketing Channel in Zoho.
CREATE OR REPLACE TABLE staging.stg_ga4__sessions
OPTIONS (description = """
Website sessions from Google Analytics 4, one row per session, since the export began on 2026-08-24. Each row carries the channel GA4 credits the session to (its last-click attribution, as in GA4's Traffic acquisition report), the landing page path, device, engagement and the events that fired.
A user here is a browser, not a person: the same person on two devices is two users, and nothing joins a session to a CRM contact or deal. For which channel produced a deal, use the Marketing Channel on the deal.
GA4 writes each day's table the next day, so yesterday can be missing until mid-morning. Times are UTC.
""")
AS
WITH e AS (
  SELECT
    event_date,
    event_timestamp,
    event_name,
    user_pseudo_id,
    device_category,
    (SELECT p.value.int_value FROM UNNEST(event_params) AS p WHERE p.key = 'ga_session_id') AS ga_session_id,
    (SELECT p.value.string_value FROM UNNEST(event_params) AS p WHERE p.key = 'page_location') AS page_location,
    (SELECT COALESCE(p.value.string_value, CAST(p.value.int_value AS STRING))
       FROM UNNEST(event_params) AS p WHERE p.key = 'session_engaged') AS session_engaged,
    session_traffic_source_last_click.cross_channel_campaign.source                AS lc_source,
    session_traffic_source_last_click.cross_channel_campaign.medium                AS lc_medium,
    session_traffic_source_last_click.cross_channel_campaign.campaign_name         AS lc_campaign,
    session_traffic_source_last_click.cross_channel_campaign.default_channel_group AS lc_channel_group,
    session_traffic_source_last_click.google_ads_campaign.campaign_name            AS gads_campaign,
    collected_traffic_source.manual_source        AS utm_source,
    collected_traffic_source.manual_medium        AS utm_medium,
    collected_traffic_source.manual_campaign_name AS utm_campaign,
    collected_traffic_source.gclid                AS gclid
  FROM raw_ga4.events
  WHERE user_pseudo_id IS NOT NULL
),
s AS (
  SELECT
    user_pseudo_id,
    ga_session_id,
    MIN(event_date)                                     AS session_date,
    TIMESTAMP_MICROS(MIN(event_timestamp))              AS session_started_at,
    ARRAY_AGG(
      IF(lc_source IS NULL AND lc_medium IS NULL AND lc_channel_group IS NULL, NULL,
         STRUCT(lc_source AS source, lc_medium AS medium, lc_campaign AS campaign,
                lc_channel_group AS channel_group, gads_campaign AS google_ads_campaign))
      IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS last_click,
    ARRAY_AGG(
      IF(utm_source IS NULL AND utm_medium IS NULL, NULL,
         STRUCT(utm_source AS source, utm_medium AS medium, utm_campaign AS campaign))
      IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS utm,
    LOGICAL_OR(gclid IS NOT NULL)                       AS has_gclid,
    ARRAY_AGG(IF(event_name IN ('session_start', 'page_view'), page_location, NULL)
      IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS landing_page,
    ANY_VALUE(device_category)                          AS device_category,
    LOGICAL_OR(session_engaged = '1')                   AS is_engaged,
    COUNTIF(event_name = 'page_view')                   AS page_views,
    COUNT(*)                                            AS event_count,
    ARRAY_AGG(DISTINCT event_name ORDER BY event_name)  AS event_names
  FROM e
  WHERE ga_session_id IS NOT NULL
  GROUP BY user_pseudo_id, ga_session_id
),
newest AS (
  SELECT TIMESTAMP_MICROS(MAX(event_timestamp)) AS loaded_at FROM raw_ga4.events
)
SELECT
  CONCAT(s.user_pseudo_id, '.', CAST(s.ga_session_id AS STRING))       AS session_key,
  s.session_date,
  s.session_started_at,
  s.user_pseudo_id,
  COALESCE(s.last_click.channel_group, 'Unassigned')                   AS channel_group,
  COALESCE(s.last_click.source, s.utm.source, '(direct)')              AS source,
  COALESCE(s.last_click.medium, s.utm.medium, '(none)')                AS medium,
  COALESCE(s.last_click.campaign, s.utm.campaign)                      AS campaign,
  s.last_click.google_ads_campaign                                     AS google_ads_campaign,
  s.has_gclid                                                          AS is_google_ads_click,
  REGEXP_EXTRACT(s.landing_page, r'^https?://[^/?#]+(/[^?#]*)')        AS landing_path,
  s.device_category,
  s.is_engaged,
  s.page_views,
  s.event_count,
  s.event_names,
  n.loaded_at
FROM s
CROSS JOIN newest AS n;

ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN session_key
  SET OPTIONS (description = "One session: the browser's GA4 id and GA4's session id, joined with a dot. Unique per row.");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN session_date
  SET OPTIONS (description = "Day the session started, in the GA4 property's reporting time zone.");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN session_started_at
  SET OPTIONS (description = "Time of the session's first event (UTC).");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN user_pseudo_id
  SET OPTIONS (description = "GA4's id for the browser. One person on two devices, or after clearing cookies, is two ids; it never identifies a person or a customer.");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN channel_group
  SET OPTIONS (description = "GA4's default channel group for the session, e.g. Organic Search, Paid Search, Direct, Referral, Organic Social; Unassigned when GA4 gave none. Same grouping as GA4's Traffic acquisition report.");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN source
  SET OPTIONS (description = "Where the session came from, e.g. google, bing, houzz.com; (direct) when there was no referrer or campaign tag.");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN medium
  SET OPTIONS (description = "How it came, e.g. organic, cpc (paid click), referral, email; (none) for direct.");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN campaign
  SET OPTIONS (description = "Campaign name from GA4's attribution or the link's utm_campaign tag; NULL when untagged.");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN google_ads_campaign
  SET OPTIONS (description = "Google Ads campaign GA4 attributes the session to, when the property is linked to Google Ads; NULL otherwise.");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN is_google_ads_click
  SET OPTIONS (description = "TRUE when the landing URL carried a Google Ads click id (gclid): the session began with a paid Google Ads click.");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN landing_path
  SET OPTIONS (description = "Path of the first page viewed, without the domain or query string, e.g. /contact.");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN device_category
  SET OPTIONS (description = "desktop, mobile or tablet.");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN is_engaged
  SET OPTIONS (description = "GA4's engaged session: lasted over 10 seconds, viewed two or more pages, or fired a key event.");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN page_views
  SET OPTIONS (description = "Pages viewed in the session.");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN event_count
  SET OPTIONS (description = "Every GA4 event in the session, page views included.");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN event_names
  SET OPTIONS (description = "Distinct GA4 event names that fired in the session, sorted, e.g. form_submission, page_view, phone_link_click. Test for one with 'form_submission' IN UNNEST(event_names).");
ALTER TABLE staging.stg_ga4__sessions ALTER COLUMN loaded_at
  SET OPTIONS (description = "Time of the newest event in the GA4 export when this table was built (UTC), the same on every row. How current the export is: GA4 writes each day's table the next day.");
