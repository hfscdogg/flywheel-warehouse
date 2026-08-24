-- stg_qbo__items — latest record per QuickBooks Online item (product/service).
-- Grain: one row per item_id.
-- Source: raw_qbo.item (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__items AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.item
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                  AS item_id,
  JSON_VALUE(payload, '$.Name')                               AS name,
  JSON_VALUE(payload, '$.Type')                               AS item_type,
  SAFE_CAST(JSON_VALUE(payload, '$.UnitPrice') AS NUMERIC)    AS unit_price,
  SAFE_CAST(JSON_VALUE(payload, '$.PurchaseCost') AS NUMERIC) AS purchase_cost,
  SAFE_CAST(JSON_VALUE(payload, '$.Active') AS BOOL)          AS is_active,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.CreateTime') AS TIMESTAMP)      AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.LastUpdatedTime') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                  AS loaded_at
FROM latest;
