-- kpi_cash — cash position snapshot from QuickBooks Online.
-- Grain: single row, as of build time (rebuilt daily; balances are
-- current-state in QBO, so history is not reconstructable anyway).
--
-- AR aging buckets by days past due on open invoice balances; an invoice
-- with no due date counts as current. AP mirrors it for open vendor bills.
-- Flow columns (invoiced/collected) use transaction dates.
--
-- Columns:
--   as_of_date            snapshot date (UTC)
--   ar_total/ar_open_invoices        open invoice balances / count
--   ar_current/ar_1_30/ar_31_60/ar_61_90/ar_over_90   aging buckets
--   ar_overdue_invoices   count of invoices past due
--   ap_total/ap_overdue   open bill balances / past-due portion
--   invoiced_last_30d/_90d   invoice totals by transaction date
--   collected_last_30d/_90d  customer payment totals by transaction date
--   computed_at           build timestamp
CREATE OR REPLACE TABLE marts.kpi_cash AS
WITH open_invoices AS (
  SELECT balance,
         DATE_DIFF(CURRENT_DATE(), due_date, DAY) AS days_past_due
  FROM staging.stg_qbo__invoices
  WHERE COALESCE(balance, 0) > 0
),
open_bills AS (
  SELECT balance,
         DATE_DIFF(CURRENT_DATE(), due_date, DAY) AS days_past_due
  FROM staging.stg_qbo__bills
  WHERE COALESCE(balance, 0) > 0
),
invoiced AS (
  SELECT txn_date, COALESCE(total_amount, 0) AS amount
  FROM staging.stg_qbo__invoices
),
collected AS (
  SELECT txn_date, COALESCE(total_amount, 0) AS amount
  FROM staging.stg_qbo__payments
)
SELECT
  CURRENT_DATE() AS as_of_date,
  (SELECT COALESCE(SUM(balance), 0) FROM open_invoices) AS ar_total,
  (SELECT COUNT(*) FROM open_invoices) AS ar_open_invoices,
  (SELECT COALESCE(SUM(balance), 0) FROM open_invoices
    WHERE days_past_due IS NULL OR days_past_due <= 0) AS ar_current,
  (SELECT COALESCE(SUM(balance), 0) FROM open_invoices
    WHERE days_past_due BETWEEN 1 AND 30) AS ar_1_30,
  (SELECT COALESCE(SUM(balance), 0) FROM open_invoices
    WHERE days_past_due BETWEEN 31 AND 60) AS ar_31_60,
  (SELECT COALESCE(SUM(balance), 0) FROM open_invoices
    WHERE days_past_due BETWEEN 61 AND 90) AS ar_61_90,
  (SELECT COALESCE(SUM(balance), 0) FROM open_invoices
    WHERE days_past_due > 90) AS ar_over_90,
  (SELECT COUNTIF(days_past_due > 0) FROM open_invoices) AS ar_overdue_invoices,
  (SELECT COALESCE(SUM(balance), 0) FROM open_bills) AS ap_total,
  (SELECT COALESCE(SUM(balance), 0) FROM open_bills
    WHERE days_past_due > 0) AS ap_overdue,
  (SELECT COALESCE(SUM(amount), 0) FROM invoiced
    WHERE txn_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)) AS invoiced_last_30d,
  (SELECT COALESCE(SUM(amount), 0) FROM invoiced
    WHERE txn_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)) AS invoiced_last_90d,
  (SELECT COALESCE(SUM(amount), 0) FROM collected
    WHERE txn_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)) AS collected_last_30d,
  (SELECT COALESCE(SUM(amount), 0) FROM collected
    WHERE txn_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)) AS collected_last_90d,
  CURRENT_TIMESTAMP() AS computed_at;
