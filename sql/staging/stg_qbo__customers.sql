-- stg_qbo__customers — latest record per QuickBooks Online customer.
-- Grain: one row per customer_id.
-- Source: raw_qbo.customer (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__customers AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.customer
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                    AS customer_id,
  JSON_VALUE(payload, '$.DisplayName')                          AS display_name,
  JSON_VALUE(payload, '$.CompanyName')                          AS company_name,
  LOWER(JSON_VALUE(payload, '$.PrimaryEmailAddr.Address'))      AS email,
  JSON_VALUE(payload, '$.PrimaryPhone.FreeFormNumber')          AS phone,
  SAFE_CAST(JSON_VALUE(payload, '$.Balance') AS NUMERIC)        AS balance,
  SAFE_CAST(JSON_VALUE(payload, '$.Active') AS BOOL)            AS is_active,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.CreateTime') AS TIMESTAMP)      AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.LastUpdatedTime') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                    AS loaded_at
FROM latest;
