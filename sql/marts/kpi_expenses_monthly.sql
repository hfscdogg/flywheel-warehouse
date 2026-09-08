-- kpi_expenses_monthly — money out by expense account, vendor and month,
-- from QuickBooks Online bills and purchases.
-- Grain: one row per (month, account, vendor, source, payment_type).
--
-- Answers "what do we spend on X" without knowing X in advance: filter on
-- account_name (or account_type / classification) and sum. Two sources of
-- spend, both needed: a BILL is a vendor invoice we were sent; a PURCHASE is
-- money paid directly — card, check, cash — and was never a bill. Freight,
-- fuel, software and the like are often paid on a card, so bills alone
-- undercount.
--
-- Item-based lines name an item rather than an account; their account is the
-- item's expense account, resolved here through stg_qbo__items so every line
-- lands on an account. Lines with neither (a malformed item) carry NULL
-- account columns and are kept, not dropped, so the totals still reconcile.
--
-- Column meanings are declared at the end of this file (ALTER COLUMN ...
-- SET OPTIONS). BigQuery serves them to agents through hermes-mcp, so that
-- is the one copy — do not restate them here.
CREATE OR REPLACE TABLE marts.kpi_expenses_monthly
OPTIONS (description = """
Money out by expense account, vendor and month, from QuickBooks bills AND purchases (card, check, cash). One row per (month, account, vendor, source, payment_type). Amounts USD, positive for expense.
To answer what we spend on something: filter account_name (e.g. LIKE '%Freight%') or account_type, then SUM(amount) by month. Do not filter to source = 'bill' unless the question is about vendor invoices specifically; card and check spend is real spend.
account_classification separates Expense from Cost of Goods Sold and from balance-sheet accounts (an asset purchase is not an expense). Item-based lines are already resolved to the item's expense account.
This is transaction detail rolled up by month, not the P&L: no journal entries, no depreciation, no accruals. For AR and AP balances use kpi_cash.
""")
AS
WITH items AS (
  SELECT item_id, expense_account_id, expense_account_name
  FROM staging.stg_qbo__items
),
bill_lines AS (
  SELECT
    'bill'                                          AS source,
    CAST(NULL AS STRING)                            AS payment_type,
    l.txn_date,
    COALESCE(l.account_id, i.expense_account_id)    AS account_id,
    COALESCE(l.account_name, i.expense_account_name) AS account_name,
    l.vendor_id,
    l.vendor_name,
    l.bill_id                                       AS txn_id,
    l.amount
  FROM staging.stg_qbo__bill_lines l
  LEFT JOIN items i ON i.item_id = l.item_id
),
purchase_lines AS (
  SELECT
    'purchase'                                      AS source,
    l.payment_type,
    l.txn_date,
    COALESCE(l.account_id, i.expense_account_id)    AS account_id,
    COALESCE(l.account_name, i.expense_account_name) AS account_name,
    IF(l.payee_type = 'Vendor', l.payee_id, NULL)   AS vendor_id,
    l.payee_name                                    AS vendor_name,
    l.purchase_id                                   AS txn_id,
    l.amount
  FROM staging.stg_qbo__purchase_lines l
  LEFT JOIN items i ON i.item_id = l.item_id
),
-- Columns listed, not SELECT *: a UNION matches by position.
lines AS (
  SELECT source, payment_type, txn_date, account_id, account_name,
         vendor_id, vendor_name, txn_id, amount
  FROM bill_lines
  UNION ALL
  SELECT source, payment_type, txn_date, account_id, account_name,
         vendor_id, vendor_name, txn_id, amount
  FROM purchase_lines
),
accounts AS (
  SELECT account_id, account_type, classification
  FROM staging.stg_qbo__accounts
)
SELECT
  DATE_TRUNC(l.txn_date, MONTH)                     AS month,
  l.account_id,
  l.account_name,
  a.account_type,
  a.classification                                  AS account_classification,
  l.vendor_id,
  l.vendor_name,
  l.source,
  l.payment_type,
  COUNT(DISTINCT l.txn_id)                          AS txn_count,
  COUNT(*)                                          AS line_count,
  SUM(COALESCE(l.amount, 0))                        AS amount,
  CURRENT_TIMESTAMP()                               AS computed_at
FROM lines l
LEFT JOIN accounts a ON a.account_id = l.account_id
WHERE l.txn_date IS NOT NULL
GROUP BY month, l.account_id, l.account_name, a.account_type, a.classification,
         l.vendor_id, l.vendor_name, l.source, l.payment_type;

-- What agents read. hermes-mcp serves these descriptions verbatim through
-- get_table_schema, and a column without one is a column Hermes will guess
-- at. 06-transform.sh fails the run if any mart column has no description.
-- Renaming a column above without updating it here fails here, loudly.
ALTER TABLE marts.kpi_expenses_monthly ALTER COLUMN month
  SET OPTIONS (description = "First day of the calendar month of the transaction date.");
ALTER TABLE marts.kpi_expenses_monthly ALTER COLUMN account_id
  SET OPTIONS (description = "QuickBooks account the spend posts to. Item-based lines are already resolved to the item's expense account. NULL only when a line named neither an account nor a known item.");
ALTER TABLE marts.kpi_expenses_monthly ALTER COLUMN account_name
  SET OPTIONS (description = "Name of that account as it appears in the chart of accounts, e.g. Freight and Shipping, Fuel, Software Subscriptions. Filter on this to answer what we spend on something.");
ALTER TABLE marts.kpi_expenses_monthly ALTER COLUMN account_type
  SET OPTIONS (description = "QuickBooks account type: Expense, Cost of Goods Sold, Other Expense, Fixed Asset, and so on.");
ALTER TABLE marts.kpi_expenses_monthly ALTER COLUMN account_classification
  SET OPTIONS (description = "Expense, Asset, Liability, Equity or Revenue. Only Expense rows are operating spend; an Asset row is a purchase of equipment or inventory, not an expense.");
ALTER TABLE marts.kpi_expenses_monthly ALTER COLUMN vendor_id
  SET OPTIONS (description = "QuickBooks vendor paid. NULL for purchases with no payee or a non-vendor payee.");
ALTER TABLE marts.kpi_expenses_monthly ALTER COLUMN vendor_name
  SET OPTIONS (description = "Display name of the vendor or payee.");
ALTER TABLE marts.kpi_expenses_monthly ALTER COLUMN source
  SET OPTIONS (description = "bill (a vendor invoice we were sent) or purchase (paid directly: card, check or cash). Both are real spend; sum across both unless the question is specifically about vendor invoices.");
ALTER TABLE marts.kpi_expenses_monthly ALTER COLUMN payment_type
  SET OPTIONS (description = "For purchases: CreditCard, Check or Cash. NULL for bills.");
ALTER TABLE marts.kpi_expenses_monthly ALTER COLUMN txn_count
  SET OPTIONS (description = "Distinct bills or purchases behind this row.");
ALTER TABLE marts.kpi_expenses_monthly ALTER COLUMN line_count
  SET OPTIONS (description = "Line items behind this row; one transaction can carry several lines to the same account.");
ALTER TABLE marts.kpi_expenses_monthly ALTER COLUMN amount
  SET OPTIONS (description = "Total spend for this month, account, vendor and source, USD. Positive for expense; a negative is a vendor credit.");
ALTER TABLE marts.kpi_expenses_monthly ALTER COLUMN computed_at
  SET OPTIONS (description = "When this row was built (UTC).");
