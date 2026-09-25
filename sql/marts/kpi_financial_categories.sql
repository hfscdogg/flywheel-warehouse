-- kpi_financial_categories — the Profit and Loss by category, actual and
-- budget, per month, including the budgeted months still to come.
-- Grain: one row per (month, report_group, category, subcategory).
--
-- The accountant's package summarises the P&L by its top-level sections
-- (COMPENSATION - ID, ADMINISTRATIVE EXPENSE, PRODUCTION & SERVICE, SALES
-- EXPENSE, and on the income side the monitoring income sections) and sets
-- the rest of the year's budget beside the year to date. kpi_financial_monthly
-- has only group totals and only months with actuals, so this carries both.
--
-- Subcategory and category can be NULL, so the actual and budget sides are
-- matched on IFNULL keys: a full outer join needs plain equalities.
--
-- A category is the section one level under the P&L group; a subcategory
-- the one under that (OCCUPANCY EXPENSE sits inside ADMINISTRATIVE EXPENSE).
-- An account directly under the group is its own category. Amounts are the
-- account lines added up, never section totals, so nothing counts twice;
-- sql/checks/qbo_reports_tie.sql holds the account lines equal to every
-- section's printed total. Budget lines are placed by the account's most
-- recent position in the P&L.
CREATE OR REPLACE TABLE marts.kpi_financial_categories
OPTIONS (description = """
The Profit and Loss by category, one row per month, P&L group, category and subcategory: the actual and the active QuickBooks budget. Months run from January three years back to December of the current year, so budgeted months still to come are here with a NULL actual.
A category is a top-level P&L section such as COMPENSATION - ID or ADMINISTRATIVE EXPENSE, or an account sitting directly under the group; a subcategory is the level below, e.g. OCCUPANCY EXPENSE inside ADMINISTRATIVE EXPENSE. Categories add up to their group totals in kpi_financial_monthly.
The budget is QuickBooks' own, not the accountant's package budget.
""")
AS
WITH lines AS (
  SELECT
    period_start,
    report_group,
    account_id,
    amount,
    IF(depth <= 1, label, SPLIT(section_path, ' > ')[SAFE_OFFSET(1)]) AS category,
    CASE
      WHEN depth <= 1 THEN NULL
      WHEN depth = 2 THEN label
      ELSE SPLIT(section_path, ' > ')[SAFE_OFFSET(2)]
    END AS subcategory
  FROM staging.stg_qbo__report_lines
  WHERE report = 'ProfitAndLoss' AND line_type = 'account'
),
actual AS (
  SELECT period_start AS month, report_group, category, subcategory,
         IFNULL(category, '') AS cat_key, IFNULL(subcategory, '') AS sub_key,
         SUM(amount) AS amount
  FROM lines
  GROUP BY month, report_group, category, subcategory
),
placement AS (
  SELECT
    account_id,
    ARRAY_AGG(STRUCT(report_group, category, subcategory) ORDER BY period_start DESC LIMIT 1)[OFFSET(0)] AS p
  FROM lines
  WHERE account_id IS NOT NULL
  GROUP BY account_id
),
budget AS (
  SELECT
    b.budget_month AS month,
    pl.p.report_group AS report_group,
    pl.p.category AS category,
    pl.p.subcategory AS subcategory,
    IFNULL(pl.p.category, '') AS cat_key,
    IFNULL(pl.p.subcategory, '') AS sub_key,
    SUM(b.amount) AS budget_amount
  FROM staging.stg_qbo__budgets AS b
  JOIN placement AS pl USING (account_id)
  WHERE b.is_active AND b.budget_type = 'ProfitAndLoss'
  GROUP BY month, report_group, category, subcategory, cat_key, sub_key
)
SELECT
  COALESCE(a.month, b.month)                                AS month,
  COALESCE(a.month, b.month) < DATE_TRUNC(CURRENT_DATE(), MONTH) AS is_complete_month,
  COALESCE(a.report_group, b.report_group)                  AS report_group,
  COALESCE(a.category, b.category)                          AS category,
  COALESCE(a.subcategory, b.subcategory)                    AS subcategory,
  a.amount,
  b.budget_amount,
  CURRENT_TIMESTAMP()                                       AS computed_at
FROM actual AS a
FULL OUTER JOIN budget AS b
  ON a.month = b.month
 AND a.report_group = b.report_group
 AND a.cat_key = b.cat_key
 AND a.sub_key = b.sub_key;

ALTER TABLE marts.kpi_financial_categories ALTER COLUMN month
  SET OPTIONS (description = "First day of the month. Runs to December of the current year; months after the current one carry budget only.");
ALTER TABLE marts.kpi_financial_categories ALTER COLUMN is_complete_month
  SET OPTIONS (description = "TRUE for months before the current one. The current month is month to date; later months are budget only.");
ALTER TABLE marts.kpi_financial_categories ALTER COLUMN report_group
  SET OPTIONS (description = "P&L group: Income, COGS, Expenses, OtherIncome or OtherExpenses.");
ALTER TABLE marts.kpi_financial_categories ALTER COLUMN category
  SET OPTIONS (description = "Top-level section under the group as QuickBooks prints it, e.g. COMPENSATION - ID, ADMINISTRATIVE EXPENSE, Security Monitoring Income; or an account sitting directly under the group.");
ALTER TABLE marts.kpi_financial_categories ALTER COLUMN subcategory
  SET OPTIONS (description = "The level below the category, e.g. OCCUPANCY EXPENSE inside ADMINISTRATIVE EXPENSE; NULL for amounts posted at the category itself. Sum over subcategories for the category total.");
ALTER TABLE marts.kpi_financial_categories ALTER COLUMN amount
  SET OPTIONS (description = "Actual for the month, USD, as the P&L prints it: COGS and expenses positive, contra accounts such as discounts negative. NULL for months not yet reached.");
ALTER TABLE marts.kpi_financial_categories ALTER COLUMN budget_amount
  SET OPTIONS (description = "Active QuickBooks budget for the month, USD; NULL where nothing is budgeted. Budgets exist from January 2026.");
ALTER TABLE marts.kpi_financial_categories ALTER COLUMN computed_at
  SET OPTIONS (description = "When this table was built (UTC).");
