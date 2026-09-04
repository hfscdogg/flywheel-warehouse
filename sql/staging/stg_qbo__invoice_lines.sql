-- stg_qbo__invoice_lines — one row per sales line on the latest version of
-- each QuickBooks Online customer invoice.
-- Grain: one row per (invoice_id, line). Source: raw_qbo.invoice.
--
-- The invoice header (stg_qbo__invoices) says who owes us and how much; the
-- LINES say what we sold them. Only SalesItemLineDetail lines are kept —
-- subtotal, discount and group lines are presentation, not sales.
CREATE OR REPLACE TABLE staging.stg_qbo__invoice_lines
OPTIONS (description = """
One row per sales line on each QuickBooks customer invoice, from the latest version of the invoice. This is where revenue BY ITEM lives: the invoice header only carries the customer and total.
Each line names an item (what was sold), quantity, unit price and amount. The income account an item posts to is on stg_qbo__items.income_account_id; join on item_id for revenue by account.
Amounts USD. Subtotal and discount lines are excluded, so summing amount here can differ slightly from the invoice total when a discount was applied.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.invoice
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
),
lines AS (
  SELECT
    _source_id                                              AS invoice_id,
    JSON_VALUE(payload, '$.DocNumber')                      AS doc_number,
    SAFE_CAST(JSON_VALUE(payload, '$.TxnDate') AS DATE)     AS txn_date,
    JSON_VALUE(payload, '$.CustomerRef.value')              AS customer_id,
    JSON_VALUE(payload, '$.CustomerRef.name')               AS customer_name,
    line,
    line_no,
    _loaded_at
  FROM latest, UNNEST(JSON_QUERY_ARRAY(payload, '$.Line')) AS line WITH OFFSET AS line_no
)
SELECT
  CONCAT(invoice_id, '-', COALESCE(JSON_VALUE(line, '$.Id'), CAST(line_no AS STRING)))
                                                            AS invoice_line_id,
  invoice_id,
  line_no,
  doc_number,
  txn_date,
  customer_id,
  customer_name,
  SAFE_CAST(JSON_VALUE(line, '$.Amount') AS NUMERIC)        AS amount,
  JSON_VALUE(line, '$.Description')                         AS description,
  JSON_VALUE(line, '$.SalesItemLineDetail.ItemRef.value')   AS item_id,
  JSON_VALUE(line, '$.SalesItemLineDetail.ItemRef.name')    AS item_name,
  SAFE_CAST(JSON_VALUE(line, '$.SalesItemLineDetail.Qty') AS NUMERIC)
                                                            AS quantity,
  SAFE_CAST(JSON_VALUE(line, '$.SalesItemLineDetail.UnitPrice') AS NUMERIC)
                                                            AS unit_price,
  SAFE_CAST(JSON_VALUE(line, '$.SalesItemLineDetail.ServiceDate') AS DATE)
                                                            AS service_date,
  _loaded_at                                                AS loaded_at
FROM lines
WHERE JSON_VALUE(line, '$.DetailType') = 'SalesItemLineDetail';

ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN invoice_line_id
  SET OPTIONS (description = "Key: invoice_id plus the line id QuickBooks assigns within the invoice.");
ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN invoice_id
  SET OPTIONS (description = "The invoice this line belongs to; joins to stg_qbo__invoices.invoice_id.");
ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN line_no
  SET OPTIONS (description = "Zero-based position of the line on the invoice.");
ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN doc_number
  SET OPTIONS (description = "Invoice number as shown to the customer.");
ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN txn_date
  SET OPTIONS (description = "Invoice date. Use this for by-month revenue questions.");
ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN customer_id
  SET OPTIONS (description = "QuickBooks customer invoiced; joins to stg_qbo__customers.customer_id.");
ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN customer_name
  SET OPTIONS (description = "Customer display name at the time the invoice was last saved.");
ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN amount
  SET OPTIONS (description = "Line amount, USD: quantity times unit price.");
ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN description
  SET OPTIONS (description = "Line description as printed on the invoice.");
ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN item_id
  SET OPTIONS (description = "The product or service sold; joins to stg_qbo__items.item_id, whose income_account_id is the revenue account this line posts to.");
ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN item_name
  SET OPTIONS (description = "Name of that product or service.");
ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN quantity
  SET OPTIONS (description = "Quantity sold.");
ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN unit_price
  SET OPTIONS (description = "Price per unit, USD.");
ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN service_date
  SET OPTIONS (description = "Date the service was performed, when entered; NULL otherwise.");
ALTER TABLE staging.stg_qbo__invoice_lines ALTER COLUMN loaded_at
  SET OPTIONS (description = "When the invoice this line came from was last loaded into the warehouse (UTC).");
