-- stg_qbo__bill_lines — one row per line on the latest version of each
-- QuickBooks Online vendor bill.
-- Grain: one row per (bill_id, line). Source: raw_qbo.bill.
--
-- The bill header (stg_qbo__bills) says who we owe and how much; the LINES
-- say what for. Each expense line names either an account directly
-- (AccountBasedExpenseLineDetail) or an item (ItemBasedExpenseLineDetail),
-- and the account an item line hits is the item's expense account — join
-- stg_qbo__items on item_id to resolve it. Subtotal and other non-expense
-- line types are dropped.
--
-- Lines are taken from the latest header record, so a re-edited bill
-- replaces its lines rather than accumulating them.
CREATE OR REPLACE TABLE staging.stg_qbo__bill_lines
OPTIONS (description = """
One row per line item on each QuickBooks vendor bill, from the latest version of the bill. This is where spend BY ACCOUNT lives: the bill header only carries the vendor and total.
Each line names either an account (account_id) or an item (item_id). For item lines the account is the item's expense account; join stg_qbo__items on item_id and use expense_account_id there. kpi_expenses_monthly has already done that join and is the easier place to answer what we spend on something.
Amounts USD, positive for expense. Bills only; card and check spend is in stg_qbo__purchase_lines.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.bill
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
),
lines AS (
  SELECT
    _source_id                                              AS bill_id,
    JSON_VALUE(payload, '$.DocNumber')                      AS doc_number,
    SAFE_CAST(JSON_VALUE(payload, '$.TxnDate') AS DATE)     AS txn_date,
    JSON_VALUE(payload, '$.VendorRef.value')                AS vendor_id,
    JSON_VALUE(payload, '$.VendorRef.name')                 AS vendor_name,
    line,
    line_no,
    _loaded_at
  FROM latest, UNNEST(JSON_QUERY_ARRAY(payload, '$.Line')) AS line WITH OFFSET AS line_no
)
SELECT
  CONCAT(bill_id, '-', COALESCE(JSON_VALUE(line, '$.Id'), CAST(line_no AS STRING)))
                                                            AS bill_line_id,
  bill_id,
  line_no,
  doc_number,
  txn_date,
  vendor_id,
  vendor_name,
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
  SAFE_CAST(JSON_VALUE(line, '$.ItemBasedExpenseLineDetail.Qty') AS NUMERIC)
                                                            AS quantity,
  SAFE_CAST(JSON_VALUE(line, '$.ItemBasedExpenseLineDetail.UnitPrice') AS NUMERIC)
                                                            AS unit_price,
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

ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN bill_line_id
  SET OPTIONS (description = "Key: bill_id plus the line id QuickBooks assigns within the bill.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN bill_id
  SET OPTIONS (description = "The bill this line belongs to; joins to stg_qbo__bills.bill_id.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN line_no
  SET OPTIONS (description = "Zero-based position of the line on the bill.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN doc_number
  SET OPTIONS (description = "The vendor's invoice number as entered on the bill.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN txn_date
  SET OPTIONS (description = "Bill date. Use this for by-month spend questions.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN vendor_id
  SET OPTIONS (description = "QuickBooks vendor id; joins to stg_qbo__vendors.vendor_id.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN vendor_name
  SET OPTIONS (description = "Vendor display name at the time the bill was last saved.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN detail_type
  SET OPTIONS (description = "AccountBasedExpenseLineDetail (the line names an account) or ItemBasedExpenseLineDetail (the line names an item; its account is the item's expense account).");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN amount
  SET OPTIONS (description = "Line amount, USD, positive for expense.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN description
  SET OPTIONS (description = "Free-text memo on the line, as typed in QuickBooks.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN account_id
  SET OPTIONS (description = "Expense account the line posts to, for account-based lines; NULL for item-based lines. Joins to stg_qbo__accounts.account_id.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN account_name
  SET OPTIONS (description = "Name of that account, e.g. Freight and Shipping. NULL for item-based lines.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN item_id
  SET OPTIONS (description = "Item on the line, for item-based lines; NULL for account-based lines. Joins to stg_qbo__items.item_id, whose expense_account_id is the account this line hits.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN item_name
  SET OPTIONS (description = "Name of that item. NULL for account-based lines.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN quantity
  SET OPTIONS (description = "Quantity on an item-based line; NULL otherwise.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN unit_price
  SET OPTIONS (description = "Unit cost on an item-based line, USD; NULL otherwise.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN customer_id
  SET OPTIONS (description = "Customer or job the line was charged to, when the cost is tied to one; NULL when not. Joins to stg_qbo__customers.customer_id.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN customer_name
  SET OPTIONS (description = "Display name of that customer or job.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN billable_status
  SET OPTIONS (description = "Billable, NotBillable or HasBeenBilled: whether this cost is meant to be passed on to the customer, and whether it has been.");
ALTER TABLE staging.stg_qbo__bill_lines ALTER COLUMN loaded_at
  SET OPTIONS (description = "When the bill this line came from was last loaded into the warehouse (UTC).");
