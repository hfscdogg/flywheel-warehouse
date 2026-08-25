-- kpi_sales_weekly — weekly sales scoreboard from Zoho CRM.
-- Grain: one row per week, from the first week with CRM activity through the
-- current week. The monthly view of the same funnel is kpi_sales_pipeline;
-- this exists for "how did we do last week" questions.
--
-- Weeks are Sunday→Saturday and keyed by their SATURDAY end date, matching
-- the Zoho Analytics convention (its Date Dimension query tables filter
-- Weekday = 7). "Last week" in this table therefore means the same span it
-- means in the Operating Metrics dashboard.
--
-- Won/lost follow the Forecast Type stage lists in stg_zoho__deals (install
-- stages count as Won); CRM test records are excluded. Won revenue is deal
-- Amount at close, the dashboard's measure.
--
-- Columns:
--   week_ending           Saturday that closes the week (the key)
--   week_start            Sunday that opens it
--   leads_created         leads created in the week
--   deals_created         deals created in the week
--   new_pipeline_amount   sum of amounts on deals created in the week
--   deals_won/won_amount  deals closed-won in the week (by closing date)
--   deals_lost/lost_amount  deals closed-lost in the week
--   close_rate_pct        won / (won + lost) among deals closed that week
--   won_amount_trailing_4w  won_amount summed over this week + prior 3
--   computed_at           build timestamp
CREATE OR REPLACE TABLE marts.kpi_sales_weekly AS
WITH deals AS (
  SELECT *, COALESCE(closing_date, DATE(modified_at)) AS closed_date
  FROM staging.stg_zoho__deals
  WHERE NOT COALESCE(is_test_record, FALSE)
),
leads AS (
  SELECT * FROM staging.stg_zoho__leads
),
bounds AS (
  SELECT LEAST(
    COALESCE((SELECT MIN(DATE(created_at)) FROM deals), CURRENT_DATE()),
    COALESCE((SELECT MIN(DATE(created_at)) FROM leads), CURRENT_DATE())
  ) AS first_day
),
weeks AS (
  -- Saturday closing each week, from the first week of activity to the
  -- current one. DATE_TRUNC(..., WEEK) is Sunday-based in BigQuery.
  SELECT DATE_ADD(week_start, INTERVAL 6 DAY) AS week_ending, week_start
  FROM bounds,
       UNNEST(GENERATE_DATE_ARRAY(
         DATE_TRUNC(first_day, WEEK),
         DATE_TRUNC(CURRENT_DATE(), WEEK),
         INTERVAL 1 WEEK)) AS week_start
),
lead_activity AS (
  SELECT DATE_ADD(DATE_TRUNC(DATE(created_at), WEEK), INTERVAL 6 DAY) AS week_ending,
         COUNT(*) AS leads_created
  FROM leads
  WHERE created_at IS NOT NULL
  GROUP BY week_ending
),
deal_created AS (
  SELECT DATE_ADD(DATE_TRUNC(DATE(created_at), WEEK), INTERVAL 6 DAY) AS week_ending,
         COUNT(*) AS deals_created,
         SUM(COALESCE(amount, 0)) AS new_pipeline_amount
  FROM deals
  WHERE created_at IS NOT NULL
  GROUP BY week_ending
),
deal_closed AS (
  SELECT DATE_ADD(DATE_TRUNC(closed_date, WEEK), INTERVAL 6 DAY) AS week_ending,
         COUNTIF(is_won) AS deals_won,
         SUM(IF(is_won, COALESCE(amount, 0), 0)) AS won_amount,
         COUNTIF(is_lost) AS deals_lost,
         SUM(IF(is_lost, COALESCE(amount, 0), 0)) AS lost_amount
  FROM deals
  WHERE (is_won OR is_lost) AND closed_date IS NOT NULL
  GROUP BY week_ending
)
SELECT
  w.week_ending,
  w.week_start,
  COALESCE(l.leads_created, 0)        AS leads_created,
  COALESCE(dc.deals_created, 0)       AS deals_created,
  COALESCE(dc.new_pipeline_amount, 0) AS new_pipeline_amount,
  COALESCE(cl.deals_won, 0)           AS deals_won,
  COALESCE(cl.won_amount, 0)          AS won_amount,
  COALESCE(cl.deals_lost, 0)          AS deals_lost,
  COALESCE(cl.lost_amount, 0)         AS lost_amount,
  ROUND(SAFE_DIVIDE(cl.deals_won, cl.deals_won + cl.deals_lost) * 100, 1)
                                      AS close_rate_pct,
  SUM(COALESCE(cl.won_amount, 0)) OVER (
    ORDER BY w.week_ending ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
  )                                   AS won_amount_trailing_4w,
  CURRENT_TIMESTAMP()                 AS computed_at
FROM weeks w
LEFT JOIN lead_activity l USING (week_ending)
LEFT JOIN deal_created dc USING (week_ending)
LEFT JOIN deal_closed cl USING (week_ending);
