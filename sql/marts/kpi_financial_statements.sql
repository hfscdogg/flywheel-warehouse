-- kpi_financial_statements — the monthly Profit & Loss, Balance Sheet and
-- Cash Flow exactly as QuickBooks prints them, with the budget beside each
-- P&L account. Grain: one row per (report, month, row_seq).
--
-- The accountant's monthly package is these three reports plus a budget, so
-- this is the table it can be rebuilt from, and sql/checks/qbo_reports_tie.sql
-- fails the transform when the three reports stop agreeing with each other.
-- For one row per month of headline figures and ratios, kpi_financial_monthly.
--
-- Column meanings are declared at the end of this file.
CREATE OR REPLACE TABLE marts.kpi_financial_statements
OPTIONS (description = """
QuickBooks' own Profit and Loss, Balance Sheet and Cash Flow, one row per report line per month, January three years back to the current month, accrual basis. These are the books as the accountant's package prints them, including payroll, depreciation and journal entries that no transaction table carries.
Never sum a column blindly: line_type 'total' rows already contain the 'account' rows above them. Sum line_type = 'account', or read a total row. Order by row_seq to print a report.
Profit and Loss and Cash Flow amounts are for the month; Balance Sheet amounts are the balance at month end. The current month is month-to-date (is_complete_month = FALSE). For headline figures and ratios per month use kpi_financial_monthly.
""")
AS
WITH lines AS (
  SELECT * FROM staging.stg_qbo__report_lines
),
budget AS (
  SELECT account_id, budget_month, SUM(amount) AS budget_amount
  FROM staging.stg_qbo__budgets
  WHERE is_active AND budget_type = 'ProfitAndLoss'
  GROUP BY account_id, budget_month
)
SELECT
  l.report,
  l.period_start                                        AS month,
  l.period_end,
  l.period_end = LAST_DAY(l.period_start, MONTH)
    AND l.period_start < DATE_TRUNC(CURRENT_DATE(), MONTH)  AS is_complete_month,
  l.row_seq,
  l.depth,
  l.section_path,
  l.report_group,
  l.label,
  l.account_id,
  l.line_type,
  l.amount,
  IF(l.report = 'ProfitAndLoss' AND l.line_type = 'account', b.budget_amount, NULL)
                                                        AS budget_amount,
  l.loaded_at                                           AS pulled_at,
  CURRENT_TIMESTAMP()                                   AS computed_at
FROM lines AS l
LEFT JOIN budget AS b
  ON b.account_id = l.account_id AND b.budget_month = l.period_start;

ALTER TABLE marts.kpi_financial_statements ALTER COLUMN report
  SET OPTIONS (description = "ProfitAndLoss, BalanceSheet or CashFlow.");
ALTER TABLE marts.kpi_financial_statements ALTER COLUMN month
  SET OPTIONS (description = "First day of the month the figure belongs to.");
ALTER TABLE marts.kpi_financial_statements ALTER COLUMN period_end
  SET OPTIONS (description = "Last day covered: month end, or the day of the pull for the current month. A Balance Sheet figure is the balance on this date.");
ALTER TABLE marts.kpi_financial_statements ALTER COLUMN is_complete_month
  SET OPTIONS (description = "FALSE for the current month, which is month-to-date. Compare complete months only.");
ALTER TABLE marts.kpi_financial_statements ALTER COLUMN row_seq
  SET OPTIONS (description = "Position in the report, top to bottom; the same in every month. Order by it to print the report.");
ALTER TABLE marts.kpi_financial_statements ALTER COLUMN depth
  SET OPTIONS (description = "Nesting level: 0 for top sections and computed lines, one deeper per sub-section.");
ALTER TABLE marts.kpi_financial_statements ALTER COLUMN section_path
  SET OPTIONS (description = "Sections above the line, outermost first, joined with ' > ', e.g. 'Expenses > ADMINISTRATIVE EXPENSE > OCCUPANCY EXPENSE'.");
ALTER TABLE marts.kpi_financial_statements ALTER COLUMN report_group
  SET OPTIONS (description = "QuickBooks' name for the top section: Income, COGS, GrossProfit, Expenses, NetOperatingIncome, OtherIncome, OtherExpenses, NetOtherIncome, NetIncome on the P&L; BankAccounts, AR, CurrentAssets, FixedAssets, AP, CurrentLiabilities, Equity and so on on the Balance Sheet.");
ALTER TABLE marts.kpi_financial_statements ALTER COLUMN label
  SET OPTIONS (description = "The line as printed: an account such as SALES M (Merchandise), or a total such as Total Income or Net Income.");
ALTER TABLE marts.kpi_financial_statements ALTER COLUMN account_id
  SET OPTIONS (description = "QuickBooks account id on account lines; NULL on totals and computed lines.");
ALTER TABLE marts.kpi_financial_statements ALTER COLUMN line_type
  SET OPTIONS (description = "account: one account's own figure. total: a section total or a computed line, which already includes the account rows above it. Adding the two counts money twice.");
ALTER TABLE marts.kpi_financial_statements ALTER COLUMN amount
  SET OPTIONS (description = "USD as QuickBooks prints it. NULL where the report shows a blank; treat as zero only when summing.");
ALTER TABLE marts.kpi_financial_statements ALTER COLUMN budget_amount
  SET OPTIONS (description = "The active QuickBooks budget for this account and month, USD, on Profit and Loss account lines only; NULL on totals, on other reports, and for accounts or months with no budget. Budgets exist from 2026.");
ALTER TABLE marts.kpi_financial_statements ALTER COLUMN pulled_at
  SET OPTIONS (description = "When QuickBooks was read for these figures (UTC). The books can change after it; a month is only as final as its close.");
ALTER TABLE marts.kpi_financial_statements ALTER COLUMN computed_at
  SET OPTIONS (description = "When this row was built (UTC).");
