-- kpi_website_traffic — website sessions per day by channel, source, medium
-- and campaign, from Google Analytics 4.
-- Grain: one row per (date, channel_group, source, medium, campaign).
--
-- The website half of marketing: how many visits each channel brought and
-- how many of them submitted a form. It does not say which visits became
-- deals; the reviewed Marketing Channel on each CRM deal does that, in
-- kpi_deal_attribution. Ad spend is not here either: GA4's export carries
-- none, so cost per visit needs the Google Ads transfer.
CREATE OR REPLACE TABLE marts.kpi_website_traffic
OPTIONS (description = """
Website sessions per day from Google Analytics 4, by GA4 channel group, source, medium and campaign, since the export began on 2026-08-24: sessions, engaged sessions, browsers, page views, sessions that began with a Google Ads click, and sessions with a form submission.
Sessions, engaged sessions, page views and form sessions add up across rows. users does not: the same browser can appear on several days or channels, so for users over a period count distinct user_pseudo_id in stg_ga4__sessions.
Channels are GA4's own, not the CRM's Marketing Channel, and nothing here joins to a deal. No ad spend. Yesterday can be missing until GA4 writes it mid-morning.
""")
AS
SELECT
  session_date                                               AS date,
  channel_group,
  source,
  medium,
  campaign,
  COUNT(*)                                                   AS sessions,
  COUNTIF(is_engaged)                                        AS engaged_sessions,
  COUNT(DISTINCT user_pseudo_id)                             AS users,
  SUM(page_views)                                            AS page_views,
  COUNTIF(is_google_ads_click)                               AS google_ads_click_sessions,
  COUNTIF('form_submit' IN UNNEST(event_names))              AS form_submit_sessions,
  COUNTIF('generate_lead' IN UNNEST(event_names))            AS generate_lead_sessions,
  MAX(loaded_at)                                             AS data_through,
  CURRENT_TIMESTAMP()                                        AS computed_at
FROM staging.stg_ga4__sessions
GROUP BY date, channel_group, source, medium, campaign;

ALTER TABLE marts.kpi_website_traffic ALTER COLUMN date
  SET OPTIONS (description = "Day the sessions started, in the GA4 property's reporting time zone.");
ALTER TABLE marts.kpi_website_traffic ALTER COLUMN channel_group
  SET OPTIONS (description = "GA4's default channel group, e.g. Organic Search, Paid Search, Direct, Referral; Unassigned when GA4 gave none. GA4's grouping, not the CRM Marketing Channel.");
ALTER TABLE marts.kpi_website_traffic ALTER COLUMN source
  SET OPTIONS (description = "Where the sessions came from, e.g. google, bing, houzz.com; (direct) for no referrer or tag.");
ALTER TABLE marts.kpi_website_traffic ALTER COLUMN medium
  SET OPTIONS (description = "How they came, e.g. organic, cpc (paid click), referral, email; (none) for direct.");
ALTER TABLE marts.kpi_website_traffic ALTER COLUMN campaign
  SET OPTIONS (description = "Campaign name from GA4 attribution or the link's utm_campaign; NULL when untagged.");
ALTER TABLE marts.kpi_website_traffic ALTER COLUMN sessions
  SET OPTIONS (description = "Website sessions. Adds up across rows.");
ALTER TABLE marts.kpi_website_traffic ALTER COLUMN engaged_sessions
  SET OPTIONS (description = "Sessions GA4 counts as engaged: over 10 seconds, two or more pages, or a key event. Adds up across rows.");
ALTER TABLE marts.kpi_website_traffic ALTER COLUMN users
  SET OPTIONS (description = "Distinct browsers in this row. Does not add up across days or channels; a browser is not a person.");
ALTER TABLE marts.kpi_website_traffic ALTER COLUMN page_views
  SET OPTIONS (description = "Pages viewed. Adds up across rows.");
ALTER TABLE marts.kpi_website_traffic ALTER COLUMN google_ads_click_sessions
  SET OPTIONS (description = "Sessions whose landing URL carried a Google Ads click id: visits that began with a paid Google Ads click. Adds up across rows.");
ALTER TABLE marts.kpi_website_traffic ALTER COLUMN form_submit_sessions
  SET OPTIONS (description = "Sessions in which GA4's automatic form_submit event fired. It fires for any form on the site, not only enquiry forms, so it is an upper bound on web leads. Adds up across rows.");
ALTER TABLE marts.kpi_website_traffic ALTER COLUMN generate_lead_sessions
  SET OPTIONS (description = "Sessions with a generate_lead event, which fires only if the site sends it; zero means the event is not set up, not that there were no leads.");
ALTER TABLE marts.kpi_website_traffic ALTER COLUMN data_through
  SET OPTIONS (description = "Newest event in the GA4 export when this was built (UTC); later days are not in yet.");
ALTER TABLE marts.kpi_website_traffic ALTER COLUMN computed_at
  SET OPTIONS (description = "When this table was built (UTC).");
