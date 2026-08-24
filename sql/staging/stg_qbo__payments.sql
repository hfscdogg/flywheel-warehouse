-- stg_qbo__payments — latest record per QuickBooks Online customer payment.
-- Grain: one row per payment_id.
-- Source: raw_qbo.payment (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__payments AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.payment
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                  AS payment_id,
  SAFE_CAST(JSON_VALUE(payload, '$.TxnDate') AS DATE)         AS txn_date,
  JSON_VALUE(payload, '$.CustomerRef.value')                  AS customer_id,
  JSON_VALUE(payload, '$.CustomerRef.name')                   AS customer_name,
  SAFE_CAST(JSON_VALUE(payload, '$.TotalAmt') AS NUMERIC)     AS total_amount,
  SAFE_CAST(JSON_VALUE(payload, '$.UnappliedAmt') AS NUMERIC) AS unapplied_amount,
  JSON_VALUE(payload, '$.PaymentRefNum')                      AS payment_ref_num,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.CreateTime') AS TIMESTAMP)      AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.LastUpdatedTime') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                  AS loaded_at
FROM latest;
