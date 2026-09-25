-- qbo_reports_tie — QuickBooks' three reports agree with themselves and with
-- each other, every month. Run by 06-transform.sh after the build; any row
-- returned is a failure. Not a model: it creates nothing.
--
-- WHY THIS EXISTS. The accountant's August 2026 package was internally
-- inconsistent twice. The first version repeated a month in three trend
-- reports, so a P&L total overstated income by $212k. The corrected version
-- printed year-to-date net income as -$226,155 on its P&L pages and
-- -$229,295 on its balance sheet and cash flow pages, because those were run
-- before $3,140 of later entries. A package built from this warehouse must
-- not be able to do either, so the transform goes red when:
--
--   1. a P&L computed line is not the arithmetic of the lines above it
--   2. the cash flow does not open with that month's P&L net income
--   3. the balance sheet's Net Income is not the P&L's year to date
--   4. total assets do not equal total liabilities and equity
--   5. a section's account lines do not add up to its printed total, which
--      is also what proves the flattening in pipelines/qbo/reports.py kept
--      every account once (a parent's own postings, never the Total column)
--
-- The cash flow's operating section is left out of 5: it opens with net
-- income and then a separate adjustments section, so its accounts alone do
-- not make its total; 2 and the adjustments section's own tie cover it.
WITH l AS (
  SELECT report, report_group, period_start, row_seq, depth, label, line_type,
         IFNULL(amount, 0) AS amount
  FROM staging.stg_qbo__report_lines
),
group_total AS (
  SELECT report, report_group, period_start, amount
  FROM l
  WHERE line_type = 'total'
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY report, report_group, period_start ORDER BY depth, row_seq) = 1
),
m AS (
  SELECT
    period_start,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'Income', amount, NULL))             AS income,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'COGS', amount, NULL))               AS cogs,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'GrossProfit', amount, NULL))        AS gross_profit,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'Expenses', amount, NULL))           AS expenses,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'NetOperatingIncome', amount, NULL)) AS net_operating_income,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'OtherIncome', amount, NULL))        AS other_income,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'OtherExpenses', amount, NULL))      AS other_expenses,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'NetOtherIncome', amount, NULL))     AS net_other_income,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'NetIncome', amount, NULL))          AS net_income,
    MAX(IF(report = 'BalanceSheet' AND report_group = 'TotalAssets', amount, NULL))         AS total_assets,
    MAX(IF(report = 'BalanceSheet' AND report_group = 'TotalLiabilitiesAndEquity', amount, NULL))
                                                                                            AS total_liabilities_equity
  FROM group_total
  GROUP BY period_start
),
lines_named AS (
  SELECT
    period_start,
    MAX(IF(report = 'CashFlow' AND line_type = 'account' AND label = 'Net Income', amount, NULL))     AS cash_flow_net_income,
    MAX(IF(report = 'BalanceSheet' AND line_type = 'account' AND label = 'Net Income', amount, NULL)) AS balance_sheet_net_income
  FROM l
  GROUP BY period_start
),
ytd AS (
  SELECT
    period_start,
    net_income,
    SUM(net_income) OVER (
      PARTITION BY EXTRACT(YEAR FROM period_start) ORDER BY period_start) AS net_income_ytd
  FROM m
),
accounts AS (
  SELECT report, report_group, period_start, SUM(amount) AS amount
  FROM l
  WHERE line_type = 'account'
    AND NOT (report = 'CashFlow' AND report_group = 'OperatingActivities')
  GROUP BY report, report_group, period_start
),
checks AS (
  SELECT '1 P&L: income - cost of goods sold = gross profit' AS check_name, period_start,
         income - cogs AS computed, gross_profit AS printed FROM m
  UNION ALL
  SELECT '1 P&L: gross profit - expenses = net operating income', period_start,
         gross_profit - expenses, net_operating_income FROM m
  UNION ALL
  SELECT '1 P&L: other income - other expenses = net other income', period_start,
         other_income - other_expenses, net_other_income FROM m
  UNION ALL
  SELECT '1 P&L: net operating income + net other income = net income', period_start,
         net_operating_income + net_other_income, net_income FROM m
  UNION ALL
  SELECT '2 cash flow opens with the P&L net income', period_start,
         m.net_income, n.cash_flow_net_income
  FROM m JOIN lines_named AS n USING (period_start)
  UNION ALL
  SELECT '3 balance sheet net income = P&L net income year to date', period_start,
         y.net_income_ytd, n.balance_sheet_net_income
  FROM ytd AS y JOIN lines_named AS n USING (period_start)
  UNION ALL
  SELECT '4 total assets = total liabilities and equity', period_start,
         total_assets, total_liabilities_equity FROM m
  UNION ALL
  SELECT CONCAT('5 ', a.report, ' ', a.report_group, ': accounts add up to the section total'),
         period_start, a.amount, t.amount
  FROM accounts AS a
  JOIN group_total AS t USING (report, report_group, period_start)
)
SELECT
  check_name,
  FORMAT_DATE('%Y-%m', period_start) AS month,
  ROUND(computed, 2)                  AS computed,
  ROUND(printed, 2)                   AS printed,
  ROUND(IFNULL(computed, 0) - IFNULL(printed, 0), 2) AS difference
FROM checks
WHERE ABS(IFNULL(computed, 0) - IFNULL(printed, 0)) > 0.01
ORDER BY check_name, month
LIMIT 50;
