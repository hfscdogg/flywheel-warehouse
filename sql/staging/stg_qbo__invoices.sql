-- stg_qbo__invoices — latest record per QuickBooks Online invoice.
-- Grain: one row per invoice_id.
-- Source: raw_qbo.invoice (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__invoices
OPTIONS (description = """
QuickBooks customer invoices, one row per invoice: who owes us, how much, when due, and what is still unpaid. This is the HEADER only; what was sold is on its lines in stg_qbo__invoice_lines. Amounts USD.
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
fields AS (
  SELECT
    _source_id                                                  AS invoice_id,
    JSON_VALUE(payload, '$.DocNumber')                          AS doc_number,
    SAFE_CAST(JSON_VALUE(payload, '$.TxnDate') AS DATE)         AS txn_date,
    SAFE_CAST(JSON_VALUE(payload, '$.DueDate') AS DATE)         AS due_date,
    JSON_VALUE(payload, '$.CustomerRef.value')                  AS customer_id,
    JSON_VALUE(payload, '$.CustomerRef.name')                   AS customer_name,
    SAFE_CAST(JSON_VALUE(payload, '$.TotalAmt') AS NUMERIC)     AS total_amount,
    SAFE_CAST(JSON_VALUE(payload, '$.Balance') AS NUMERIC)      AS balance,
    JSON_VALUE(payload, '$.CurrencyRef.value')                  AS currency,
    SAFE_CAST(JSON_VALUE(payload, '$.MetaData.CreateTime') AS TIMESTAMP)      AS created_at,
    SAFE_CAST(JSON_VALUE(payload, '$.MetaData.LastUpdatedTime') AS TIMESTAMP) AS modified_at,
    _loaded_at                                                  AS loaded_at
  FROM latest
)
SELECT
  invoice_id,
  doc_number,
  txn_date,
  due_date,
  customer_id,
  customer_name,
  total_amount,
  balance,
  currency,
  created_at,
  modified_at,
  loaded_at,
  COALESCE(balance, 0) = 0 AS is_paid
FROM fields;

ALTER TABLE staging.stg_qbo__invoices ALTER COLUMN invoice_id
  SET OPTIONS (description = "QuickBooks invoice id; the key. stg_qbo__invoice_lines.invoice_id joins here.");
ALTER TABLE staging.stg_qbo__invoices ALTER COLUMN doc_number
  SET OPTIONS (description = "Invoice number shown to the customer.");
ALTER TABLE staging.stg_qbo__invoices ALTER COLUMN txn_date
  SET OPTIONS (description = "Invoice date.");
ALTER TABLE staging.stg_qbo__invoices ALTER COLUMN due_date
  SET OPTIONS (description = "Date payment is due; past this the balance is overdue.");
ALTER TABLE staging.stg_qbo__invoices ALTER COLUMN customer_id
  SET OPTIONS (description = "Customer invoiced; joins to stg_qbo__customers.");
ALTER TABLE staging.stg_qbo__invoices ALTER COLUMN customer_name
  SET OPTIONS (description = "Customer display name.");
ALTER TABLE staging.stg_qbo__invoices ALTER COLUMN total_amount
  SET OPTIONS (description = "Invoice total, USD.");
ALTER TABLE staging.stg_qbo__invoices ALTER COLUMN balance
  SET OPTIONS (description = "Unpaid remainder, USD. 0 means paid in full; this is the accounts-receivable amount.");
ALTER TABLE staging.stg_qbo__invoices ALTER COLUMN currency
  SET OPTIONS (description = "Currency code; USD.");
ALTER TABLE staging.stg_qbo__invoices ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_qbo__invoices ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_qbo__invoices ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
ALTER TABLE staging.stg_qbo__invoices ALTER COLUMN is_paid
  SET OPTIONS (description = "TRUE when balance is 0.");
