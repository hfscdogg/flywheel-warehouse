-- kpi_marketing_attribution — deal outcomes by marketing channel, weekly.
-- Grain: one row per (week_ending, marketing_channel).
--
-- Channel comes from the CRM's own "Marketing Channel" field on deals, so
-- this reflects how the sales team attributes each deal — no web analytics
-- involved. is_marketing_sourced marks the channels the Zoho Analytics
-- "Marketing Pipeline Amount" formula counts as marketing-sourced
-- (zoho-reference/formulas.md), so "what did marketing bring in" here means
-- the same thing it means in the dashboard.
--
-- Weeks are Sunday→Saturday keyed by the Saturday, matching
-- kpi_sales_weekly. Deals with no channel set appear as '(unset)'.
--
-- Column meanings are declared at the end of this file (ALTER COLUMN ...
-- SET OPTIONS). BigQuery serves them to agents through hermes-mcp, so that
-- is the one copy — do not restate them here.
CREATE OR REPLACE TABLE marts.kpi_marketing_attribution
OPTIONS (description = """
Deal outcomes by marketing channel, one row per (week_ending, marketing_channel). Weeks are Sunday to Saturday keyed by the Saturday, the same weeks as kpi_sales_weekly and the Zoho dashboard.
Channel is the CRM field the sales team fills in on each deal; no web analytics are involved. To answer what marketing brought in the way the Zoho dashboard does, filter is_marketing_sourced = TRUE.
A large (unset) share means CRM data entry gaps, not a data bug. Amounts USD; CRM test records excluded.
""")
AS
WITH deals AS (
  SELECT
    COALESCE(closing_date, DATE(modified_at)) AS closed_date,
    created_at,
    amount,
    is_won,
    is_lost,
    COALESCE(NULLIF(UPPER(TRIM(marketing_channel)), ''), '(unset)')
      AS channel
  FROM staging.stg_zoho__deals
  WHERE NOT COALESCE(is_test_record, FALSE)
),
created AS (
  SELECT DATE_ADD(DATE_TRUNC(DATE(created_at), WEEK), INTERVAL 6 DAY) AS week_ending,
         channel,
         COUNT(*) AS deals_created,
         SUM(COALESCE(amount, 0)) AS new_pipeline_amount
  FROM deals
  WHERE created_at IS NOT NULL
  GROUP BY week_ending, channel
),
closed AS (
  SELECT DATE_ADD(DATE_TRUNC(closed_date, WEEK), INTERVAL 6 DAY) AS week_ending,
         channel,
         COUNTIF(is_won) AS deals_won,
         SUM(IF(is_won, COALESCE(amount, 0), 0)) AS won_amount,
         COUNTIF(is_lost) AS deals_lost
  FROM deals
  WHERE (is_won OR is_lost) AND closed_date IS NOT NULL
  GROUP BY week_ending, channel
)
SELECT
  week_ending,
  channel AS marketing_channel,
  -- The dashboard's marketing-sourced list, verbatim.
  channel IN (
    'GOOGLE ADS (PAID)', 'GOOGLE LSA (PAID)', 'GOOGLE/BING ORGANIC',
    'GOOGLE BUSINESS PROFILE', 'HOUZZ', 'EMAIL/NEWSLETTER',
    'WEBSITE INQUIRY', 'DIRECT (PHONE/WALK-IN)'
  ) AS is_marketing_sourced,
  COALESCE(c.deals_created, 0)       AS deals_created,
  COALESCE(c.new_pipeline_amount, 0) AS new_pipeline_amount,
  COALESCE(x.deals_won, 0)           AS deals_won,
  COALESCE(x.won_amount, 0)          AS won_amount,
  COALESCE(x.deals_lost, 0)          AS deals_lost,
  ROUND(SAFE_DIVIDE(x.deals_won, x.deals_won + x.deals_lost) * 100, 1)
                                     AS close_rate_pct,
  CURRENT_TIMESTAMP()                AS computed_at
FROM created c
FULL OUTER JOIN closed x USING (week_ending, channel);

-- What agents read. hermes-mcp serves these descriptions verbatim through
-- get_table_schema, and a column without one is a column Hermes will guess
-- at. 06-transform.sh fails the run if any mart column has no description.
-- Renaming a column above without updating it here fails here, loudly.
ALTER TABLE marts.kpi_marketing_attribution ALTER COLUMN week_ending
  SET OPTIONS (description = "Saturday that closes the week. Weeks run Sunday to Saturday, matching kpi_sales_weekly and the Zoho dashboard.");
ALTER TABLE marts.kpi_marketing_attribution ALTER COLUMN marketing_channel
  SET OPTIONS (description = "The CRM Marketing Channel value on the deal, uppercased and trimmed; (unset) when blank. Sales-team attribution, not web analytics.");
ALTER TABLE marts.kpi_marketing_attribution ALTER COLUMN is_marketing_sourced
  SET OPTIONS (description = "TRUE for the channels the Zoho dashboard counts as marketing-sourced: Google Ads, Google LSA, Google/Bing organic, Google Business Profile, Houzz, email/newsletter, website inquiry, direct.");
ALTER TABLE marts.kpi_marketing_attribution ALTER COLUMN deals_created
  SET OPTIONS (description = "Deals created in the week on this channel.");
ALTER TABLE marts.kpi_marketing_attribution ALTER COLUMN new_pipeline_amount
  SET OPTIONS (description = "Sum of deal amounts on deals created in the week on this channel, USD.");
ALTER TABLE marts.kpi_marketing_attribution ALTER COLUMN deals_won
  SET OPTIONS (description = "Deals closed-won in the week on this channel, by closing date.");
ALTER TABLE marts.kpi_marketing_attribution ALTER COLUMN won_amount
  SET OPTIONS (description = "Sum of deal amounts on those won deals, USD.");
ALTER TABLE marts.kpi_marketing_attribution ALTER COLUMN deals_lost
  SET OPTIONS (description = "Deals closed-lost in the week on this channel.");
ALTER TABLE marts.kpi_marketing_attribution ALTER COLUMN close_rate_pct
  SET OPTIONS (description = "deals_won / (deals_won + deals_lost) among deals closed in the week, as a percentage 0 to 100. NULL when nothing closed.");
ALTER TABLE marts.kpi_marketing_attribution ALTER COLUMN computed_at
  SET OPTIONS (description = "When this row was built (UTC).");
