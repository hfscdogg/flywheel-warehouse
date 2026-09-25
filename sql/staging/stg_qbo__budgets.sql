-- stg_qbo__budgets — QuickBooks budgets, one row per (budget, account, month).
-- Grain: one row per (budget_id, account_id, budget_month).
-- Source: raw_qbo.budgets, the whole Budget record as QuickBooks returns it;
-- each run lands every budget again, so the newest load per budget wins.
--
-- Livewire has one: "Budget_FY26_P&L", monthly, 2026, 1,080 entries (90
-- accounts x 12 months) on 2026-09-25. A budget line is keyed by account
-- only; the record carries no class, customer or department on any line.
CREATE OR REPLACE TABLE staging.stg_qbo__budgets
OPTIONS (description = """
QuickBooks budgets, one row per budget, account and month: the plan as kept in QuickBooks. Join account_id to the Profit and Loss report lines to put budget beside actual.
Only budgets marked active in QuickBooks are the current plan; an inactive one is an old or draft version. Amounts USD, signed as the Profit and Loss prints each account, so contra accounts such as discounts can be negative.
This is the budget in QuickBooks. On 2026-09-25 it did not match the budget in the accountant's August package (August income $258,101 here, $276,588 there): say which one a comparison uses.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.budgets
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY _source_id ORDER BY _loaded_at DESC) = 1
)
SELECT
  l._source_id                                                   AS budget_id,
  JSON_VALUE(l.payload, '$.Name')                                AS budget_name,
  JSON_VALUE(l.payload, '$.BudgetType')                          AS budget_type,
  SAFE_CAST(JSON_VALUE(l.payload, '$.Active') AS BOOL)           AS is_active,
  JSON_VALUE(d, '$.AccountRef.value')                            AS account_id,
  JSON_VALUE(d, '$.AccountRef.name')                             AS account_name,
  SAFE_CAST(JSON_VALUE(d, '$.BudgetDate') AS DATE)               AS budget_month,
  SAFE_CAST(JSON_VALUE(d, '$.Amount') AS NUMERIC)                AS amount,
  l._loaded_at                                                   AS loaded_at
FROM latest AS l,
  UNNEST(JSON_QUERY_ARRAY(l.payload, '$.BudgetDetail')) AS d;

ALTER TABLE staging.stg_qbo__budgets ALTER COLUMN budget_id
  SET OPTIONS (description = "QuickBooks budget id.");
ALTER TABLE staging.stg_qbo__budgets ALTER COLUMN budget_name
  SET OPTIONS (description = "Budget name as set in QuickBooks, e.g. Budget_FY26_P&L.");
ALTER TABLE staging.stg_qbo__budgets ALTER COLUMN budget_type
  SET OPTIONS (description = "ProfitAndLoss or BalanceSheet.");
ALTER TABLE staging.stg_qbo__budgets ALTER COLUMN is_active
  SET OPTIONS (description = "TRUE for a budget marked active in QuickBooks; use only these as the plan.");
ALTER TABLE staging.stg_qbo__budgets ALTER COLUMN account_id
  SET OPTIONS (description = "QuickBooks account the budget line is for; joins to the Profit and Loss report lines and the chart of accounts.");
ALTER TABLE staging.stg_qbo__budgets ALTER COLUMN account_name
  SET OPTIONS (description = "Account name with its parents, colon-separated, e.g. ADMINISTRATIVE EXPENSE:Bank Charges.");
ALTER TABLE staging.stg_qbo__budgets ALTER COLUMN budget_month
  SET OPTIONS (description = "First day of the month the amount is budgeted for.");
ALTER TABLE staging.stg_qbo__budgets ALTER COLUMN amount
  SET OPTIONS (description = "Budgeted amount for the account in the month, USD.");
ALTER TABLE staging.stg_qbo__budgets ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this budget was last loaded into the warehouse (UTC).");
