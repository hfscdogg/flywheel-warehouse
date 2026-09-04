-- stg_qbo__estimates — latest record per QuickBooks Online estimate.
-- Grain: one row per estimate_id.
-- Source: raw_qbo.estimate (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__estimates
OPTIONS (description = """
QuickBooks estimates (quotes sent to customers), one row per estimate. txn_status says whether it was accepted, pending, rejected or closed. Amounts USD.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.estimate
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                  AS estimate_id,
  JSON_VALUE(payload, '$.DocNumber')                          AS doc_number,
  SAFE_CAST(JSON_VALUE(payload, '$.TxnDate') AS DATE)         AS txn_date,
  SAFE_CAST(JSON_VALUE(payload, '$.ExpirationDate') AS DATE)  AS expiration_date,
  -- Pending / Accepted / Closed / Rejected
  JSON_VALUE(payload, '$.TxnStatus')                          AS txn_status,
  JSON_VALUE(payload, '$.CustomerRef.value')                  AS customer_id,
  JSON_VALUE(payload, '$.CustomerRef.name')                   AS customer_name,
  SAFE_CAST(JSON_VALUE(payload, '$.TotalAmt') AS NUMERIC)     AS total_amount,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.CreateTime') AS TIMESTAMP)      AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.LastUpdatedTime') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                  AS loaded_at
FROM latest;

ALTER TABLE staging.stg_qbo__estimates ALTER COLUMN estimate_id
  SET OPTIONS (description = "QuickBooks estimate id; the key.");
ALTER TABLE staging.stg_qbo__estimates ALTER COLUMN doc_number
  SET OPTIONS (description = "Estimate number shown to the customer.");
ALTER TABLE staging.stg_qbo__estimates ALTER COLUMN txn_date
  SET OPTIONS (description = "Estimate date.");
ALTER TABLE staging.stg_qbo__estimates ALTER COLUMN expiration_date
  SET OPTIONS (description = "Date the estimate expires, when set.");
ALTER TABLE staging.stg_qbo__estimates ALTER COLUMN txn_status
  SET OPTIONS (description = "Pending, Accepted, Closed or Rejected.");
ALTER TABLE staging.stg_qbo__estimates ALTER COLUMN customer_id
  SET OPTIONS (description = "Customer the estimate was sent to; joins to stg_qbo__customers.");
ALTER TABLE staging.stg_qbo__estimates ALTER COLUMN customer_name
  SET OPTIONS (description = "Customer display name.");
ALTER TABLE staging.stg_qbo__estimates ALTER COLUMN total_amount
  SET OPTIONS (description = "Estimate total, USD.");
ALTER TABLE staging.stg_qbo__estimates ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_qbo__estimates ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_qbo__estimates ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
