-- kpi_sales_pipeline — monthly sales-funnel scoreboard from Zoho CRM.
-- Grain: one row per calendar month, from the first month with CRM activity
-- through three months ahead (future months carry the open pipeline expected
-- to close then). Shaped for direct agent consumption: no joins needed.
--
-- Column meanings are declared at the end of this file (ALTER COLUMN ...
-- SET OPTIONS). BigQuery serves them to agents through hermes-mcp, so that
-- is the one copy — do not restate them here.
CREATE OR REPLACE TABLE marts.kpi_sales_pipeline
OPTIONS (description = """
Monthly sales funnel from Zoho CRM, one row per calendar month from the first month with CRM activity through three months ahead.
Past months carry actuals: leads and deals created, won and lost counts and amounts, win rate, days to win. The current and future months also carry the open pipeline expected to close in that month; open_expected_closing is the probability-weighted figure the Zoho dashboard plots as pipeline.
For week-level questions use kpi_sales_weekly. Amounts USD; CRM test records excluded.
""")
AS
WITH deals AS (
  SELECT *, COALESCE(closing_date, DATE(modified_at)) AS closed_date
  FROM staging.stg_zoho__deals
  -- Test records are excluded from Zoho's revenue reporting
  -- (docs/zoho-reconciliation.md P2); absent field = not a test.
  WHERE NOT COALESCE(is_test_record, FALSE)
),
leads AS (
  SELECT * FROM staging.stg_zoho__leads
),
bounds AS (
  SELECT LEAST(
    COALESCE((SELECT MIN(DATE_TRUNC(DATE(created_at), MONTH)) FROM deals),
             DATE_TRUNC(CURRENT_DATE(), MONTH)),
    COALESCE((SELECT MIN(DATE_TRUNC(DATE(created_at), MONTH)) FROM leads),
             DATE_TRUNC(CURRENT_DATE(), MONTH))
  ) AS first_month
),
months AS (
  SELECT month
  FROM bounds,
       UNNEST(GENERATE_DATE_ARRAY(
         first_month,
         DATE_ADD(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 3 MONTH),
         INTERVAL 1 MONTH)) AS month
),
lead_activity AS (
  SELECT DATE_TRUNC(DATE(created_at), MONTH) AS month,
         COUNT(*) AS leads_created
  FROM leads
  WHERE created_at IS NOT NULL
  GROUP BY month
),
deal_created AS (
  SELECT DATE_TRUNC(DATE(created_at), MONTH) AS month,
         COUNT(*) AS deals_created,
         SUM(COALESCE(amount, 0)) AS new_pipeline_amount
  FROM deals
  WHERE created_at IS NOT NULL
  GROUP BY month
),
deal_closed AS (
  SELECT DATE_TRUNC(closed_date, MONTH) AS month,
         COUNTIF(is_won) AS deals_won,
         SUM(IF(is_won, COALESCE(amount, 0), 0)) AS won_amount,
         COUNTIF(is_lost) AS deals_lost,
         SUM(IF(is_lost, COALESCE(amount, 0), 0)) AS lost_amount,
         APPROX_QUANTILES(
           IF(is_won, DATE_DIFF(closed_date, DATE(created_at), DAY), NULL),
           2)[OFFSET(1)] AS median_days_to_win
  FROM deals
  WHERE (is_won OR is_lost) AND closed_date IS NOT NULL
  GROUP BY month
),
open_pipeline AS (
  SELECT DATE_TRUNC(closing_date, MONTH) AS month,
         COUNT(*) AS open_deals_closing,
         SUM(COALESCE(amount, 0)) AS open_amount_closing,
         SUM(COALESCE(expected_revenue, 0)) AS open_expected_closing
  FROM deals
  WHERE NOT is_won AND NOT is_lost AND closing_date IS NOT NULL
  GROUP BY month
)
SELECT
  m.month,
  COALESCE(l.leads_created, 0)        AS leads_created,
  COALESCE(dc.deals_created, 0)       AS deals_created,
  COALESCE(dc.new_pipeline_amount, 0) AS new_pipeline_amount,
  COALESCE(cl.deals_won, 0)           AS deals_won,
  COALESCE(cl.won_amount, 0)          AS won_amount,
  COALESCE(cl.deals_lost, 0)          AS deals_lost,
  COALESCE(cl.lost_amount, 0)         AS lost_amount,
  ROUND(SAFE_DIVIDE(cl.deals_won, cl.deals_won + cl.deals_lost) * 100, 1)
                                      AS win_rate_pct,
  cl.median_days_to_win,
  COALESCE(op.open_deals_closing, 0)  AS open_deals_closing,
  COALESCE(op.open_amount_closing, 0) AS open_amount_closing,
  COALESCE(op.open_expected_closing, 0) AS open_expected_closing,
  CURRENT_TIMESTAMP()                 AS computed_at
FROM months m
LEFT JOIN lead_activity l USING (month)
LEFT JOIN deal_created dc USING (month)
LEFT JOIN deal_closed cl USING (month)
LEFT JOIN open_pipeline op USING (month);

-- What agents read. hermes-mcp serves these descriptions verbatim through
-- get_table_schema, and a column without one is a column Hermes will guess
-- at. 06-transform.sh fails the run if any mart column has no description.
-- Renaming a column above without updating it here fails here, loudly.
ALTER TABLE marts.kpi_sales_pipeline ALTER COLUMN month
  SET OPTIONS (description = "First day of the calendar month.");
ALTER TABLE marts.kpi_sales_pipeline ALTER COLUMN leads_created
  SET OPTIONS (description = "Leads created in the month.");
ALTER TABLE marts.kpi_sales_pipeline ALTER COLUMN deals_created
  SET OPTIONS (description = "Deals created in the month.");
ALTER TABLE marts.kpi_sales_pipeline ALTER COLUMN new_pipeline_amount
  SET OPTIONS (description = "Sum of deal amounts on deals created in the month, USD.");
ALTER TABLE marts.kpi_sales_pipeline ALTER COLUMN deals_won
  SET OPTIONS (description = "Deals closed-won in the month, by closing date. Install stages count as won.");
ALTER TABLE marts.kpi_sales_pipeline ALTER COLUMN won_amount
  SET OPTIONS (description = "Sum of deal amounts on deals won in the month, USD.");
ALTER TABLE marts.kpi_sales_pipeline ALTER COLUMN deals_lost
  SET OPTIONS (description = "Deals closed-lost in the month, by closing date.");
ALTER TABLE marts.kpi_sales_pipeline ALTER COLUMN lost_amount
  SET OPTIONS (description = "Sum of deal amounts on deals lost in the month, USD.");
ALTER TABLE marts.kpi_sales_pipeline ALTER COLUMN win_rate_pct
  SET OPTIONS (description = "deals_won / (deals_won + deals_lost) among deals closed in the month, as a percentage 0 to 100. NULL when nothing closed.");
ALTER TABLE marts.kpi_sales_pipeline ALTER COLUMN median_days_to_win
  SET OPTIONS (description = "Median days from deal creation to won close, over deals won in the month.");
ALTER TABLE marts.kpi_sales_pipeline ALTER COLUMN open_deals_closing
  SET OPTIONS (description = "Still-open deals whose expected close date falls in this month. A forecast; meaningful for the current and future months.");
ALTER TABLE marts.kpi_sales_pipeline ALTER COLUMN open_amount_closing
  SET OPTIONS (description = "Raw deal amount on those open deals, USD.");
ALTER TABLE marts.kpi_sales_pipeline ALTER COLUMN open_expected_closing
  SET OPTIONS (description = "Zoho probability-weighted Expected Revenue on those open deals, USD. This is the pipeline measure the Zoho dashboard plots.");
ALTER TABLE marts.kpi_sales_pipeline ALTER COLUMN computed_at
  SET OPTIONS (description = "When this row was built (UTC).");
