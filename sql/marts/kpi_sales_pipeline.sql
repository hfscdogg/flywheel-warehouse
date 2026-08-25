-- kpi_sales_pipeline — monthly sales-funnel scoreboard from Zoho CRM.
-- Grain: one row per calendar month, from the first month with CRM activity
-- through three months ahead (future months carry the open pipeline expected
-- to close then). Shaped for direct agent consumption: no joins needed.
--
-- Columns:
--   month                 first day of the calendar month
--   leads_created         leads created in the month
--   deals_created         deals created in the month
--   new_pipeline_amount   sum of amounts on deals created in the month
--   deals_won/won_amount  deals closed-won in the month (by closing date;
--                         won/lost per Zoho's Forecast Type stage lists —
--                         see stg_zoho__deals; test records excluded)
--   deals_lost/lost_amount  deals closed-lost in the month
--   win_rate_pct          won / (won + lost) among deals closed that month
--   median_days_to_win    median days from deal creation to won-close
--   open_deals_closing / open_amount_closing / open_expected_closing
--                         still-open deals whose expected close falls in the
--                         month (a forecast view; empty for past months that
--                         have no overdue open deals). open_amount_closing is
--                         raw deal amount; open_expected_closing is Zoho's
--                         probability-weighted Expected Revenue — the measure
--                         the Operating Metrics dashboard plots as pipeline.
--   computed_at           build timestamp
CREATE OR REPLACE TABLE marts.kpi_sales_pipeline AS
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
