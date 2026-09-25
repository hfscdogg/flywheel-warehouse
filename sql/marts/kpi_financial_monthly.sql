-- kpi_financial_monthly — one row per month of the figures the accountant's
-- package leads with: P&L totals against budget, balance-sheet position,
-- cash flow, and the KPI dashboard's mixes and margins.
-- Grain: one row per month, January three years back to the current month.
--
-- Group totals are read from QuickBooks' own total lines, never re-added, so
-- every figure here is one QuickBooks printed. A report_group's total is its
-- shallowest total line (Total Income, not Total SALES S inside it).
--
-- The mixes and margins are Livewire's chart of accounts and follow the
-- package's own definitions, each checked against its August 2026 KPI
-- dashboard (equipment 60%, parts 29%, direct labor 49%, security
-- monitoring 29%, mix 57/12/31, current ratio 1.17). An account that exists
-- as a parent with sub-accounts is read from its section total, so it
-- includes them. They are keyed by the account's printed name: a renamed
-- account leaves its ratio NULL rather than wrong.
CREATE OR REPLACE TABLE marts.kpi_financial_monthly
OPTIONS (description = """
One row per month from QuickBooks' own reports: income, gross profit, expenses, operating income and net income against the active budget; current assets and liabilities, cash, receivables, payables and customer deposits at month end; cash flow; and the KPI dashboard's sales mix and margins. Accrual basis, USD.
The current month is month-to-date (is_complete_month = FALSE): compare complete months only. Budgets exist from 2026; budget columns are NULL before.
Every amount is a figure QuickBooks printed, so it matches the accountant's package when both are run on the same books. For line-level detail use kpi_financial_statements.
""")
AS
WITH lines AS (
  SELECT * FROM staging.stg_qbo__report_lines
),
-- A report_group's own total: its shallowest total line.
group_totals AS (
  SELECT report, report_group, period_start, amount
  FROM lines
  WHERE line_type = 'total'
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY report, report_group, period_start ORDER BY depth, row_seq) = 1
),
g AS (
  SELECT
    period_start,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'Income', amount, NULL))             AS income,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'COGS', amount, NULL))               AS cogs,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'GrossProfit', amount, NULL))        AS gross_profit,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'Expenses', amount, NULL))           AS expenses,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'NetOperatingIncome', amount, NULL)) AS net_operating_income,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'NetOtherIncome', amount, NULL))     AS net_other_income,
    MAX(IF(report = 'ProfitAndLoss' AND report_group = 'NetIncome', amount, NULL))          AS net_income,
    MAX(IF(report = 'BalanceSheet' AND report_group = 'CurrentAssets', amount, NULL))       AS current_assets,
    MAX(IF(report = 'BalanceSheet' AND report_group = 'CurrentLiabilities', amount, NULL))  AS current_liabilities,
    MAX(IF(report = 'BalanceSheet' AND report_group = 'BankAccounts', amount, NULL))        AS bank_balance,
    MAX(IF(report = 'BalanceSheet' AND report_group = 'AR', amount, NULL))                  AS accounts_receivable,
    MAX(IF(report = 'BalanceSheet' AND report_group = 'AP', amount, NULL))                  AS accounts_payable,
    MAX(IF(report = 'CashFlow' AND report_group = 'OperatingActivities', amount, NULL))     AS operating_cash_flow,
    MAX(IF(report = 'CashFlow' AND report_group = 'CashIncrease', amount, NULL))            AS net_cash_change
  FROM group_totals
  GROUP BY period_start
),
-- One P&L account including its sub-accounts: the section total when the
-- account is a parent, else its own line.
named AS (
  SELECT
    period_start,
    label,
    COALESCE(
      MAX(IF(line_type = 'total', amount, NULL)),
      MAX(IF(line_type = 'account', amount, NULL))) AS amount
  FROM (
    SELECT period_start, line_type, amount,
           IF(line_type = 'total' AND STARTS_WITH(label, 'Total '), SUBSTR(label, 7), label) AS label
    FROM lines
    WHERE report = 'ProfitAndLoss'
  )
  GROUP BY period_start, label
),
n AS (
  SELECT
    period_start,
    MAX(IF(label = 'SALES M (Merchandise)', amount, NULL))          AS sales_merchandise,
    MAX(IF(label = 'SALES P (Install Parts)', amount, NULL))        AS sales_parts,
    MAX(IF(label = 'SALES S (Services & Labor)', amount, NULL))     AS sales_services,
    MAX(IF(label = 'COGS M (Merchandise)', amount, NULL))           AS cogs_merchandise,
    MAX(IF(label = 'COGS I (Do Not Use)', amount, NULL))            AS cogs_i,
    MAX(IF(label = 'COGS P (Parts and Materials)', amount, NULL))   AS cogs_parts,
    MAX(IF(label = 'COMP 1 - Direct Labor Wages', amount, NULL))    AS direct_labor,
    MAX(IF(label = 'C1 - Outsourced Labor services', amount, NULL)) AS outsourced_labor
  FROM named
  GROUP BY period_start
),
-- Security Monitoring Income is a parent: its own line is the gross billed,
-- its section total is net of discounts and monitoring expenses.
sec AS (
  SELECT
    period_start,
    MAX(IF(line_type = 'account' AND label = 'Security Monitoring Income', amount, NULL))       AS security_monitoring_gross,
    MAX(IF(line_type = 'total' AND label = 'Total Security Monitoring Income', amount, NULL))  AS security_monitoring_net,
    MAX(IF(report = 'BalanceSheet' AND line_type = 'account' AND label = 'CUSTOMER DEPOSITS', amount, NULL)) AS customer_deposits
  FROM lines
  GROUP BY period_start
),
-- The active budget, rolled up to the P&L group each account prints in.
account_group AS (
  SELECT DISTINCT account_id, report_group
  FROM lines
  WHERE report = 'ProfitAndLoss' AND line_type = 'account' AND account_id IS NOT NULL
),
budget AS (
  SELECT
    b.budget_month AS period_start,
    SUM(IF(a.report_group = 'Income', b.amount, 0))        AS budget_income,
    SUM(IF(a.report_group = 'COGS', b.amount, 0))          AS budget_cogs,
    SUM(IF(a.report_group = 'Expenses', b.amount, 0))      AS budget_expenses,
    SUM(IF(a.report_group = 'OtherIncome', b.amount, 0))
      - SUM(IF(a.report_group = 'OtherExpenses', b.amount, 0)) AS budget_net_other_income,
    COUNTIF(a.report_group IS NULL)                        AS budget_lines_unplaced
  FROM staging.stg_qbo__budgets AS b
  LEFT JOIN account_group AS a USING (account_id)
  WHERE b.is_active AND b.budget_type = 'ProfitAndLoss'
  GROUP BY b.budget_month
)
SELECT
  period_start                                                         AS month,
  period_start < DATE_TRUNC(CURRENT_DATE(), MONTH)                   AS is_complete_month,
  g.income, g.cogs, g.gross_profit,
  ROUND(SAFE_DIVIDE(g.gross_profit, g.income) * 100, 1)               AS gross_margin_pct,
  g.expenses, g.net_operating_income, g.net_other_income, g.net_income,
  bu.budget_income,
  bu.budget_income - bu.budget_cogs                                    AS budget_gross_profit,
  bu.budget_expenses,
  bu.budget_income - bu.budget_cogs - bu.budget_expenses               AS budget_net_operating_income,
  bu.budget_income - bu.budget_cogs - bu.budget_expenses + bu.budget_net_other_income
                                                                       AS budget_net_income,
  bu.budget_lines_unplaced,
  n.sales_merchandise, n.sales_parts, n.sales_services,
  ROUND(SAFE_DIVIDE(n.sales_merchandise, g.income) * 100, 1)          AS material_mix_pct,
  ROUND(SAFE_DIVIDE(n.sales_parts, g.income) * 100, 1)                AS parts_mix_pct,
  ROUND(SAFE_DIVIDE(n.sales_services, g.income) * 100, 1)             AS labor_mix_pct,
  ROUND(SAFE_DIVIDE(n.sales_merchandise - IFNULL(n.cogs_merchandise, 0) - IFNULL(n.cogs_i, 0),
                    n.sales_merchandise) * 100, 1)                     AS equipment_margin_pct,
  ROUND(SAFE_DIVIDE(n.sales_parts - IFNULL(n.cogs_parts, 0), n.sales_parts) * 100, 1)
                                                                       AS parts_margin_pct,
  ROUND(SAFE_DIVIDE(n.sales_services - IFNULL(n.direct_labor, 0) - IFNULL(n.outsourced_labor, 0),
                    n.sales_services) * 100, 1)                        AS direct_labor_margin_pct,
  s.security_monitoring_gross, s.security_monitoring_net,
  ROUND(SAFE_DIVIDE(s.security_monitoring_net, s.security_monitoring_gross) * 100, 1)
                                                                       AS security_monitoring_margin_pct,
  g.current_assets, g.current_liabilities,
  ROUND(SAFE_DIVIDE(g.current_assets, g.current_liabilities), 2)      AS current_ratio,
  g.current_assets - g.current_liabilities                             AS working_capital,
  g.bank_balance, g.accounts_receivable, g.accounts_payable, s.customer_deposits,
  g.operating_cash_flow, g.net_cash_change,
  CURRENT_TIMESTAMP()                                                  AS computed_at
FROM g
LEFT JOIN n USING (period_start)
LEFT JOIN sec AS s USING (period_start)
LEFT JOIN budget AS bu USING (period_start);

ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN month
  SET OPTIONS (description = "First day of the month.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN is_complete_month
  SET OPTIONS (description = "FALSE for the current month, which is month-to-date. Compare complete months only.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN income
  SET OPTIONS (description = "Total Income for the month, USD: sales only. Monitoring income is Other Income in these books, inside net_other_income.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN cogs
  SET OPTIONS (description = "Total Cost of Goods Sold for the month, USD, including direct labor wages.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN gross_profit
  SET OPTIONS (description = "Gross Profit as QuickBooks prints it, USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN gross_margin_pct
  SET OPTIONS (description = "gross_profit / income, 0 to 100: the package's Gross Profit Margin.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN expenses
  SET OPTIONS (description = "Total Expenses (operating: compensation, administrative, production and service, sales), USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN net_operating_income
  SET OPTIONS (description = "Net Operating Income, USD: gross profit less expenses, before monitoring and other income.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN net_other_income
  SET OPTIONS (description = "Net Other Income, USD: chiefly security and Invision monitoring income net of their discounts and costs.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN net_income
  SET OPTIONS (description = "Net Income for the month as QuickBooks prints it, USD. Sum complete months for a year-to-date figure.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN budget_income
  SET OPTIONS (description = "Budgeted income for the month from the active QuickBooks budget, USD. NULL where no budget exists (before 2026).");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN budget_gross_profit
  SET OPTIONS (description = "Budgeted income less budgeted cost of goods sold, USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN budget_expenses
  SET OPTIONS (description = "Budgeted operating expenses, USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN budget_net_operating_income
  SET OPTIONS (description = "Budgeted gross profit less budgeted expenses, USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN budget_net_income
  SET OPTIONS (description = "Budgeted net operating income plus budgeted net other income, USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN budget_lines_unplaced
  SET OPTIONS (description = "Budget lines for accounts that do not appear on the Profit and Loss, so they are in no budget total. Should be 0; above 0 means the budget totals are understated.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN sales_merchandise
  SET OPTIONS (description = "SALES M (Merchandise) for the month, USD: equipment sales.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN sales_parts
  SET OPTIONS (description = "SALES P (Install Parts) for the month, USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN sales_services
  SET OPTIONS (description = "SALES S (Services & Labor) for the month including its sub-accounts, USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN material_mix_pct
  SET OPTIONS (description = "sales_merchandise / income, 0 to 100: the package's Material Mix.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN parts_mix_pct
  SET OPTIONS (description = "sales_parts / income, 0 to 100: the package's Parts Mix.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN labor_mix_pct
  SET OPTIONS (description = "sales_services / income, 0 to 100: the package's Labor Mix.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN equipment_margin_pct
  SET OPTIONS (description = "(SALES M - COGS M - COGS I) / SALES M, 0 to 100: the package's Equipment Margin. NULL when an account it needs has been renamed.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN parts_margin_pct
  SET OPTIONS (description = "(SALES P - COGS P including sub-accounts) / SALES P, 0 to 100: the package's Parts Margin.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN direct_labor_margin_pct
  SET OPTIONS (description = "(SALES S - COMP 1 Direct Labor Wages - C1 Outsourced Labor) / SALES S, 0 to 100: the package's Direct Labor Margin.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN security_monitoring_gross
  SET OPTIONS (description = "Security Monitoring Income billed in the month before discounts and monitoring costs, USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN security_monitoring_net
  SET OPTIONS (description = "Total Security Monitoring Income: billed less Security Discounts and Security Monitoring Expenses, USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN security_monitoring_margin_pct
  SET OPTIONS (description = "security_monitoring_net / security_monitoring_gross, 0 to 100: the package's Security Monitoring GM %.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN current_assets
  SET OPTIONS (description = "Total Current Assets at month end, USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN current_liabilities
  SET OPTIONS (description = "Total Current Liabilities at month end, USD, including customer deposits.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN current_ratio
  SET OPTIONS (description = "current_assets / current_liabilities. The package reads 1.2 to 2 as healthy and below 1 as a problem.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN working_capital
  SET OPTIONS (description = "current_assets - current_liabilities, USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN bank_balance
  SET OPTIONS (description = "Total Bank Accounts at month end, USD. Excludes undeposited funds, which the cash flow report counts as cash.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN accounts_receivable
  SET OPTIONS (description = "Total Accounts Receivable at month end, USD. For aging use kpi_cash.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN accounts_payable
  SET OPTIONS (description = "Total Accounts Payable at month end, USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN customer_deposits
  SET OPTIONS (description = "CUSTOMER DEPOSITS at month end, USD: money collected for work not yet invoiced, a current liability.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN operating_cash_flow
  SET OPTIONS (description = "Net cash provided by operating activities in the month, USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN net_cash_change
  SET OPTIONS (description = "Net cash increase for the month from the cash flow report, USD.");
ALTER TABLE marts.kpi_financial_monthly ALTER COLUMN computed_at
  SET OPTIONS (description = "When this row was built (UTC).");
