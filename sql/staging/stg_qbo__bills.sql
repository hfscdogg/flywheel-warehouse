-- stg_qbo__bills — latest record per QuickBooks Online vendor bill.
-- Grain: one row per bill_id.
-- Source: raw_qbo.bill (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__bills AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.bill
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                  AS bill_id,
  JSON_VALUE(payload, '$.DocNumber')                          AS doc_number,
  SAFE_CAST(JSON_VALUE(payload, '$.TxnDate') AS DATE)         AS txn_date,
  SAFE_CAST(JSON_VALUE(payload, '$.DueDate') AS DATE)         AS due_date,
  JSON_VALUE(payload, '$.VendorRef.value')                    AS vendor_id,
  JSON_VALUE(payload, '$.VendorRef.name')                     AS vendor_name,
  SAFE_CAST(JSON_VALUE(payload, '$.TotalAmt') AS NUMERIC)     AS total_amount,
  SAFE_CAST(JSON_VALUE(payload, '$.Balance') AS NUMERIC)      AS balance,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.CreateTime') AS TIMESTAMP)      AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.LastUpdatedTime') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                  AS loaded_at
FROM latest;
