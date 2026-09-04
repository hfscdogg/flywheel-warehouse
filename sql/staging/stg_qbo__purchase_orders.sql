-- stg_qbo__purchase_orders — latest record per QuickBooks Online purchase order.
-- Grain: one row per purchase_order_id.
-- Source: raw_qbo.purchaseorder (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__purchase_orders
OPTIONS (description = """
QuickBooks purchase orders, one row per PO: what we have ordered from a vendor. A PO is a commitment, not spend; spend is the bill or purchase that follows. Amounts USD.
""")
AS
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

ALTER TABLE staging.stg_qbo__purchase_orders ALTER COLUMN purchase_order_id
  SET OPTIONS (description = "QuickBooks purchase order id; the key.");
ALTER TABLE staging.stg_qbo__purchase_orders ALTER COLUMN doc_number
  SET OPTIONS (description = "PO number.");
ALTER TABLE staging.stg_qbo__purchase_orders ALTER COLUMN txn_date
  SET OPTIONS (description = "Purchase order date.");
ALTER TABLE staging.stg_qbo__purchase_orders ALTER COLUMN vendor_id
  SET OPTIONS (description = "Vendor ordered from; joins to stg_qbo__vendors.");
ALTER TABLE staging.stg_qbo__purchase_orders ALTER COLUMN vendor_name
  SET OPTIONS (description = "Vendor display name.");
ALTER TABLE staging.stg_qbo__purchase_orders ALTER COLUMN po_status
  SET OPTIONS (description = "Open or Closed.");
ALTER TABLE staging.stg_qbo__purchase_orders ALTER COLUMN total_amount
  SET OPTIONS (description = "PO total, USD.");
ALTER TABLE staging.stg_qbo__purchase_orders ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_qbo__purchase_orders ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_qbo__purchase_orders ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
