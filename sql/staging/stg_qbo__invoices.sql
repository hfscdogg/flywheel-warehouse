-- stg_qbo__invoices — latest record per QuickBooks Online invoice.
-- Grain: one row per invoice_id.
-- Source: raw_qbo.invoice (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__invoices AS
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
  *,
  COALESCE(balance, 0) = 0 AS is_paid
FROM fields;
