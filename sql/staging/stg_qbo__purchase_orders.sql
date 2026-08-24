-- stg_qbo__purchase_orders — latest record per QuickBooks Online purchase order.
-- Grain: one row per purchase_order_id.
-- Source: raw_qbo.purchaseorder (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__purchase_orders AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.purchaseorder
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                  AS purchase_order_id,
  JSON_VALUE(payload, '$.DocNumber')                          AS doc_number,
  SAFE_CAST(JSON_VALUE(payload, '$.TxnDate') AS DATE)         AS txn_date,
  JSON_VALUE(payload, '$.VendorRef.value')                    AS vendor_id,
  JSON_VALUE(payload, '$.VendorRef.name')                     AS vendor_name,
  -- Open / Closed
  JSON_VALUE(payload, '$.POStatus')                           AS po_status,
  SAFE_CAST(JSON_VALUE(payload, '$.TotalAmt') AS NUMERIC)     AS total_amount,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.CreateTime') AS TIMESTAMP)      AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.LastUpdatedTime') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                  AS loaded_at
FROM latest;
