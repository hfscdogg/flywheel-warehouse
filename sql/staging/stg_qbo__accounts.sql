-- stg_qbo__accounts — latest record per QuickBooks Online ledger account.
-- Grain: one row per account_id.
-- Source: raw_qbo.account (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__accounts AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.account
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                     AS account_id,
  JSON_VALUE(payload, '$.Name')                                  AS name,
  JSON_VALUE(payload, '$.AccountType')                           AS account_type,
  JSON_VALUE(payload, '$.AccountSubType')                        AS account_sub_type,
  JSON_VALUE(payload, '$.Classification')                        AS classification,
  SAFE_CAST(JSON_VALUE(payload, '$.CurrentBalance') AS NUMERIC)  AS current_balance,
  SAFE_CAST(JSON_VALUE(payload, '$.Active') AS BOOL)             AS is_active,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.CreateTime') AS TIMESTAMP)      AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.LastUpdatedTime') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                     AS loaded_at
FROM latest;
