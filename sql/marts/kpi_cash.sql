-- kpi_cash — cash position snapshot from QuickBooks Online.
-- Grain: single row, as of build time (rebuilt daily; balances are
-- current-state in QBO, so history is not reconstructable anyway).
--
-- AR aging buckets by days past due on open invoice balances; an invoice
-- with no due date counts as current. AP mirrors it for open vendor bills.
-- Flow columns (invoiced/collected) use transaction dates.
--
-- Column meanings are declared at the end of this file (ALTER COLUMN ...
-- SET OPTIONS). BigQuery serves them to agents through hermes-mcp, so that
-- is the one copy — do not restate them here.
CREATE OR REPLACE TABLE marts.kpi_cash
OPTIONS (description = """
Cash position snapshot from QuickBooks Online: accounts receivable with aging buckets, accounts payable, and 30/90-day invoiced and collected totals.
ONE ROW ONLY, current state at build time. There is no history in this table — a trend question cannot be answered from it.
All amounts USD. Rebuilt daily.
""")
AS
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

-- What agents read. hermes-mcp serves these descriptions verbatim through
-- get_table_schema, and a column without one is a column Hermes will guess
-- at. 06-transform.sh fails the run if any mart column has no description.
-- Renaming a column above without updating it here fails here, loudly.
ALTER TABLE marts.kpi_cash ALTER COLUMN as_of_date
  SET OPTIONS (description = "Snapshot date (UTC). This table holds one row, the current state; no history.");
ALTER TABLE marts.kpi_cash ALTER COLUMN ar_total
  SET OPTIONS (description = "Total open customer invoice balances (accounts receivable), USD.");
ALTER TABLE marts.kpi_cash ALTER COLUMN ar_open_invoices
  SET OPTIONS (description = "Count of customer invoices with an open balance.");
ALTER TABLE marts.kpi_cash ALTER COLUMN ar_current
  SET OPTIONS (description = "Open AR not yet past due, USD. Invoices with no due date count here.");
ALTER TABLE marts.kpi_cash ALTER COLUMN ar_1_30
  SET OPTIONS (description = "Open AR 1 to 30 days past due, USD.");
ALTER TABLE marts.kpi_cash ALTER COLUMN ar_31_60
  SET OPTIONS (description = "Open AR 31 to 60 days past due, USD.");
ALTER TABLE marts.kpi_cash ALTER COLUMN ar_61_90
  SET OPTIONS (description = "Open AR 61 to 90 days past due, USD.");
ALTER TABLE marts.kpi_cash ALTER COLUMN ar_over_90
  SET OPTIONS (description = "Open AR more than 90 days past due, USD.");
ALTER TABLE marts.kpi_cash ALTER COLUMN ar_overdue_invoices
  SET OPTIONS (description = "Count of open customer invoices past their due date.");
ALTER TABLE marts.kpi_cash ALTER COLUMN ap_total
  SET OPTIONS (description = "Total open vendor bill balances (accounts payable), USD.");
ALTER TABLE marts.kpi_cash ALTER COLUMN ap_overdue
  SET OPTIONS (description = "Portion of ap_total that is past due, USD.");
ALTER TABLE marts.kpi_cash ALTER COLUMN invoiced_last_30d
  SET OPTIONS (description = "Sum of customer invoices dated in the last 30 days, by transaction date, USD.");
ALTER TABLE marts.kpi_cash ALTER COLUMN invoiced_last_90d
  SET OPTIONS (description = "Sum of customer invoices dated in the last 90 days, by transaction date, USD.");
ALTER TABLE marts.kpi_cash ALTER COLUMN collected_last_30d
  SET OPTIONS (description = "Sum of customer payments received in the last 30 days, by transaction date, USD.");
ALTER TABLE marts.kpi_cash ALTER COLUMN collected_last_90d
  SET OPTIONS (description = "Sum of customer payments received in the last 90 days, by transaction date, USD.");
ALTER TABLE marts.kpi_cash ALTER COLUMN computed_at
  SET OPTIONS (description = "When this row was built (UTC).");
