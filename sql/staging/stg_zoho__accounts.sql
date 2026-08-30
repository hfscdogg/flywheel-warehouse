-- stg_zoho__accounts — latest record per Zoho CRM account (company).
-- Grain: one row per account_id.
-- Source: raw_zoho.accounts (append-only; payload = full Zoho v2 record).
CREATE OR REPLACE TABLE staging.stg_zoho__accounts AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_zoho.accounts
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                 AS account_id,
  JSON_VALUE(payload, '$.Account_Name')                      AS account_name,
  JSON_VALUE(payload, '$.Industry')                          AS industry,
  JSON_VALUE(payload, '$.Phone')                             AS phone,
  JSON_VALUE(payload, '$.Website')                           AS website,
  JSON_VALUE(payload, '$.Billing_Street')                    AS billing_street,
  JSON_VALUE(payload, '$.Billing_City')                      AS billing_city,
  JSON_VALUE(payload, '$.Billing_State')                     AS billing_state,
  JSON_VALUE(payload, '$.Billing_Code')                      AS billing_zip,
  JSON_VALUE(payload, '$.Owner.name')                        AS owner_name,
  JSON_VALUE(payload, '$.Owner.email')                       AS owner_email,
  SAFE_CAST(JSON_VALUE(payload, '$.Created_Time') AS TIMESTAMP)  AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.Modified_Time') AS TIMESTAMP) AS modified_at,
  -- Same house-number + ZIP key the monitoring-vendor models build. The CRM
  -- is where Livewire's install addresses actually live: Zoho Billing's list
  -- endpoint returns no address at all, and its customer records carry no CRM
  -- reference (0 of 34,248), so kpi_subscription_audit reaches a subscription
  -- by way of this key and then the account name. Sparse by nature — about a
  -- third of accounts have a billing street — and an account without one
  -- simply does not participate in the match.
  CONCAT(
    COALESCE(REGEXP_EXTRACT(JSON_VALUE(payload, '$.Billing_Street'), r'^(\d+)'), ''), '|',
    COALESCE(REGEXP_EXTRACT(JSON_VALUE(payload, '$.Billing_Code'), r'(\d{5})'), '')
  )                                                          AS address_key,
  _loaded_at                                                 AS loaded_at
FROM latest;
