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
-- Column meanings are declared at the end of this file (ALTER COLUMN ...
-- SET OPTIONS). BigQuery serves them to agents through hermes-mcp, so that
-- is the one copy — do not restate them here.
CREATE OR REPLACE TABLE marts.kpi_sales_weekly
OPTIONS (description = """
Weekly sales scoreboard from Zoho CRM, one row per week from the first week with CRM activity through the current week.
Weeks run Sunday to Saturday and are keyed by their Saturday (week_ending), matching the Zoho dashboard, so last week is the most recent week_ending before today. Won revenue is deal Amount at close.
For monthly or forecast questions use kpi_sales_pipeline. Amounts USD; CRM test records excluded.
""")
AS
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

-- What agents read. hermes-mcp serves these descriptions verbatim through
-- get_table_schema, and a column without one is a column Hermes will guess
-- at. 06-transform.sh fails the run if any mart column has no description.
-- Renaming a column above without updating it here fails here, loudly.
ALTER TABLE marts.kpi_sales_weekly ALTER COLUMN week_ending
  SET OPTIONS (description = "Saturday that closes the week; the key. Weeks run Sunday to Saturday, matching the Zoho dashboard.");
ALTER TABLE marts.kpi_sales_weekly ALTER COLUMN week_start
  SET OPTIONS (description = "Sunday that opens the week.");
ALTER TABLE marts.kpi_sales_weekly ALTER COLUMN leads_created
  SET OPTIONS (description = "Leads created in the week.");
ALTER TABLE marts.kpi_sales_weekly ALTER COLUMN deals_created
  SET OPTIONS (description = "Deals created in the week.");
ALTER TABLE marts.kpi_sales_weekly ALTER COLUMN new_pipeline_amount
  SET OPTIONS (description = "Sum of deal amounts on deals created in the week, USD.");
ALTER TABLE marts.kpi_sales_weekly ALTER COLUMN deals_won
  SET OPTIONS (description = "Deals closed-won in the week, by closing date. Install stages count as won.");
ALTER TABLE marts.kpi_sales_weekly ALTER COLUMN won_amount
  SET OPTIONS (description = "Sum of deal amounts on deals won in the week, USD.");
ALTER TABLE marts.kpi_sales_weekly ALTER COLUMN deals_lost
  SET OPTIONS (description = "Deals closed-lost in the week, by closing date.");
ALTER TABLE marts.kpi_sales_weekly ALTER COLUMN lost_amount
  SET OPTIONS (description = "Sum of deal amounts on deals lost in the week, USD.");
ALTER TABLE marts.kpi_sales_weekly ALTER COLUMN close_rate_pct
  SET OPTIONS (description = "deals_won / (deals_won + deals_lost) among deals closed in the week, as a percentage 0 to 100. NULL when nothing closed.");
ALTER TABLE marts.kpi_sales_weekly ALTER COLUMN won_amount_trailing_4w
  SET OPTIONS (description = "won_amount summed over this week and the three before it, USD.");
ALTER TABLE marts.kpi_sales_weekly ALTER COLUMN computed_at
  SET OPTIONS (description = "When this row was built (UTC).");
