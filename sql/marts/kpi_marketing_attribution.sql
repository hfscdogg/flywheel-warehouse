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
-- Columns:
--   week_ending           Saturday that closes the week
--   marketing_channel     CRM value, uppercased/trimmed; '(unset)' if blank
--   is_marketing_sourced  TRUE for the dashboard's marketing channel list
--   deals_created         deals created in the week on this channel
--   new_pipeline_amount   their summed amount
--   deals_won/won_amount  deals closed-won in the week (by closing date)
--   deals_lost            deals closed-lost in the week
--   close_rate_pct        won / (won + lost) closed that week on this channel
--   computed_at           build timestamp
CREATE OR REPLACE TABLE marts.kpi_marketing_attribution AS
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
