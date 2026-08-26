-- stg_zohobilling__subscriptions — latest record per Zoho Billing subscription.
-- Grain: one row per subscription_id.
-- Source: raw_zohobilling.subscriptions (append-only; payload = Billing v1 record).
--
-- Field names are best-effort from the Zoho Billing v1 API (same
-- VERIFY-on-first-run posture as the D-Tools paths): an all-NULL column
-- after the first live run means a wrong path, not an empty book.
CREATE OR REPLACE TABLE staging.stg_zohobilling__subscriptions AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_zohobilling.subscriptions
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
),
fields AS (
  SELECT
    _source_id                                                    AS subscription_id,
    JSON_VALUE(payload, '$.name')                                 AS subscription_name,
    JSON_VALUE(payload, '$.status')                               AS status,
    JSON_VALUE(payload, '$.customer_id')                          AS customer_id,
    JSON_VALUE(payload, '$.customer_name')                        AS customer_name,
    LOWER(JSON_VALUE(payload, '$.email'))                         AS email,
    JSON_VALUE(payload, '$.plan.plan_code')                       AS plan_code,
    JSON_VALUE(payload, '$.plan.name')                            AS plan_name,
    SAFE_CAST(JSON_VALUE(payload, '$.amount') AS NUMERIC)         AS amount,
    JSON_VALUE(payload, '$.interval_unit')                        AS interval_unit,
    SAFE_CAST(JSON_VALUE(payload, '$.interval') AS INT64)         AS interval_count,
    SAFE_CAST(JSON_VALUE(payload, '$.activated_at') AS DATE)      AS activated_at,
    SAFE_CAST(JSON_VALUE(payload, '$.next_billing_at') AS DATE)   AS next_billing_at,
    SAFE_CAST(JSON_VALUE(payload, '$.expires_at') AS DATE)        AS expires_at,
    SAFE_CAST(JSON_VALUE(payload, '$.cancelled_at') AS DATE)      AS cancelled_at,
    SAFE_CAST(JSON_VALUE(payload, '$.created_time') AS TIMESTAMP)       AS created_at,
    SAFE_CAST(JSON_VALUE(payload, '$.last_modified_time') AS TIMESTAMP) AS modified_at,
    _loaded_at                                                    AS loaded_at
  FROM latest
)
SELECT
  *,
  -- 'live' is Zoho's active state; the dashboard's Next Billing Revenue
  -- widget filters on exactly that (zoho-reference/00-widget-inventory.md).
  status = 'live' AS is_active
FROM fields;
