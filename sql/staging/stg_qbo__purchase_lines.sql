-- stg_qbo__purchase_lines — one row per line on the latest version of each
-- QuickBooks Online purchase: a card charge, check, or cash expense.
-- Grain: one row per (purchase_id, line). Source: raw_qbo.purchase.
--
-- A Purchase is money out that was never a vendor bill — paid on the spot
-- rather than invoiced. Same line shape as a bill: account-based or
-- item-based. The header's AccountRef is the bank or card account the money
-- LEFT, not what it was spent on; that is on the lines.
CREATE OR REPLACE TABLE staging.stg_qbo__purchase_lines
OPTIONS (description = """
One row per line item on each QuickBooks purchase, from the latest version of the purchase. A purchase is spend that was paid directly rather than invoiced by a vendor: a credit card charge, a check, or cash. Together with stg_qbo__bill_lines this is all money out by account.
Each line names either an account (account_id) or an item (item_id). For item lines the account is the item's expense account; join stg_qbo__items on item_id. kpi_expenses_monthly has already combined bills and purchases and resolved item accounts, and is the easier place to answer what we spend on something.
paid_from_account_name is the bank or card the money left, not what it was spent on. Amounts USD, positive for expense.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.purchase
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
),
lines AS (
  SELECT
    _source_id                                              AS purchase_id,
    JSON_VALUE(payload, '$.DocNumber')                      AS doc_number,
    SAFE_CAST(JSON_VALUE(payload, '$.TxnDate') AS DATE)     AS txn_date,
    JSON_VALUE(payload, '$.PaymentType')                    AS payment_type,
    JSON_VALUE(payload, '$.AccountRef.value')               AS paid_from_account_id,
    JSON_VALUE(payload, '$.AccountRef.name')                AS paid_from_account_name,
    JSON_VALUE(payload, '$.EntityRef.value')                AS payee_id,
    JSON_VALUE(payload, '$.EntityRef.name')                 AS payee_name,
    JSON_VALUE(payload, '$.EntityRef.type')                 AS payee_type,
    line,
    line_no,
    _loaded_at
  FROM latest, UNNEST(JSON_QUERY_ARRAY(payload, '$.Line')) AS line WITH OFFSET AS line_no
)
SELECT
  CONCAT(purchase_id, '-', COALESCE(JSON_VALUE(line, '$.Id'), CAST(line_no AS STRING)))
                                                            AS purchase_line_id,
  purchase_id,
  line_no,
  doc_number,
  txn_date,
  payment_type,
  paid_from_account_id,
  paid_from_account_name,
  payee_id,
  payee_name,
  payee_type,
  JSON_VALUE(line, '$.DetailType')                          AS detail_type,
  SAFE_CAST(JSON_VALUE(line, '$.Amount') AS NUMERIC)        AS amount,
  JSON_VALUE(line, '$.Description')                         AS description,
  JSON_VALUE(line, '$.AccountBasedExpenseLineDetail.AccountRef.value')
                                                            AS account_id,
  JSON_VALUE(line, '$.AccountBasedExpenseLineDetail.AccountRef.name')
                                                            AS account_name,
  JSON_VALUE(line, '$.ItemBasedExpenseLineDetail.ItemRef.value')
                                                            AS item_id,
  JSON_VALUE(line, '$.ItemBasedExpenseLineDetail.ItemRef.name')
                                                            AS item_name,
  COALESCE(JSON_VALUE(line, '$.AccountBasedExpenseLineDetail.CustomerRef.value'),
           JSON_VALUE(line, '$.ItemBasedExpenseLineDetail.CustomerRef.value'))
                                                            AS customer_id,
  COALESCE(JSON_VALUE(line, '$.AccountBasedExpenseLineDetail.CustomerRef.name'),
           JSON_VALUE(line, '$.ItemBasedExpenseLineDetail.CustomerRef.name'))
                                                            AS customer_name,
  COALESCE(JSON_VALUE(line, '$.AccountBasedExpenseLineDetail.BillableStatus'),
           JSON_VALUE(line, '$.ItemBasedExpenseLineDetail.BillableStatus'))
                                                            AS billable_status,
  _loaded_at                                                AS loaded_at
FROM lines
WHERE JSON_VALUE(line, '$.DetailType')
      IN ('AccountBasedExpenseLineDetail', 'ItemBasedExpenseLineDetail');

ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN purchase_line_id
  SET OPTIONS (description = "Key: purchase_id plus the line id QuickBooks assigns within the purchase.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN purchase_id
  SET OPTIONS (description = "The purchase transaction this line belongs to.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN line_no
  SET OPTIONS (description = "Zero-based position of the line on the purchase.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN doc_number
  SET OPTIONS (description = "Check number or reference as entered in QuickBooks; often blank for card charges.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN txn_date
  SET OPTIONS (description = "Transaction date. Use this for by-month spend questions.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN payment_type
  SET OPTIONS (description = "How it was paid: CreditCard, Check or Cash.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN paid_from_account_id
  SET OPTIONS (description = "The bank or credit card account the money left. NOT what it was spent on; see account_id.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN paid_from_account_name
  SET OPTIONS (description = "Name of that bank or card account.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN payee_id
  SET OPTIONS (description = "Who was paid: a vendor, customer or employee id, per payee_type. NULL when no payee was recorded.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN payee_name
  SET OPTIONS (description = "Display name of the payee.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN payee_type
  SET OPTIONS (description = "Vendor, Customer or Employee, saying which table payee_id joins to.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN detail_type
  SET OPTIONS (description = "AccountBasedExpenseLineDetail (the line names an account) or ItemBasedExpenseLineDetail (the line names an item; its account is the item's expense account).");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN amount
  SET OPTIONS (description = "Line amount, USD, positive for expense.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN description
  SET OPTIONS (description = "Free-text memo on the line, as typed in QuickBooks.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN account_id
  SET OPTIONS (description = "Expense account the line posts to, for account-based lines; NULL for item-based lines. Joins to stg_qbo__accounts.account_id.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN account_name
  SET OPTIONS (description = "Name of that account, e.g. Freight and Shipping. NULL for item-based lines.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN item_id
  SET OPTIONS (description = "Item on the line, for item-based lines; NULL for account-based lines. Joins to stg_qbo__items.item_id, whose expense_account_id is the account this line hits.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN item_name
  SET OPTIONS (description = "Name of that item. NULL for account-based lines.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN customer_id
  SET OPTIONS (description = "Customer or job the line was charged to, when the cost is tied to one; NULL when not. Joins to stg_qbo__customers.customer_id.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN customer_name
  SET OPTIONS (description = "Display name of that customer or job.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN billable_status
  SET OPTIONS (description = "Billable, NotBillable or HasBeenBilled: whether this cost is meant to be passed on to the customer, and whether it has been.");
ALTER TABLE staging.stg_qbo__purchase_lines ALTER COLUMN loaded_at
  SET OPTIONS (description = "When the purchase this line came from was last loaded into the warehouse (UTC).");
