-- stg_zohobilling__subscriptions — latest record per Zoho Billing subscription.
-- Grain: one row per subscription_id.
-- Source: raw_zohobilling.subscriptions (append-only; payload = Billing v1 record).
--
-- Field paths VERIFIED against live payloads on the first run (2026-08-27,
-- 2,209 subscriptions): status, customer_name, amount and the billing dates
-- all populate. The date fields are sparse by design — next_billing_at only
-- on active subscriptions, cancelled_at only on cancelled ones — so a low
-- non-zero count there is correct, not a wrong path.
CREATE OR REPLACE TABLE staging.stg_zohobilling__subscriptions
OPTIONS (description = """
Zoho Billing subscriptions, one row per subscription: what each customer is being charged for on a recurring basis. is_active is the test for a live subscription. Amounts USD per interval.
""")
AS
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
    -- Plan fields are top-level on the LIST endpoint (verified against live
    -- payloads 2026-08-27); the nested $.plan object only appears on the
    -- per-subscription GET.
    JSON_VALUE(payload, '$.plan_code')                            AS plan_code,
    JSON_VALUE(payload, '$.plan_name')                            AS plan_name,
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
  subscription_id,
  subscription_name,
  status,
  customer_id,
  customer_name,
  email,
  plan_code,
  plan_name,
  amount,
  interval_unit,
  interval_count,
  activated_at,
  next_billing_at,
  expires_at,
  cancelled_at,
  created_at,
  modified_at,
  loaded_at,
  -- 'live' is Zoho's active state; the dashboard's Next Billing Revenue
  -- widget filters on exactly that (zoho-reference/00-widget-inventory.md).
  status = 'live' AS is_active
FROM fields;

ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN subscription_id
  SET OPTIONS (description = "Zoho Billing subscription id; the key.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN subscription_name
  SET OPTIONS (description = "Subscription name.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN status
  SET OPTIONS (description = "live, cancelled, expired, trial, and so on; is_active reduces it to a boolean.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN customer_id
  SET OPTIONS (description = "Subscribing customer; joins to stg_zohobilling__customers.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN customer_name
  SET OPTIONS (description = "That customer's display name.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN email
  SET OPTIONS (description = "Customer email on the subscription.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN plan_code
  SET OPTIONS (description = "Plan code.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN plan_name
  SET OPTIONS (description = "Plan name, e.g. the monitoring or support tier.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN amount
  SET OPTIONS (description = "Recurring amount per interval, USD.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN interval_unit
  SET OPTIONS (description = "months or years.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN interval_count
  SET OPTIONS (description = "How many interval units between charges; 1 with months is monthly.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN activated_at
  SET OPTIONS (description = "When the subscription went live.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN next_billing_at
  SET OPTIONS (description = "Next charge date for a live subscription.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN expires_at
  SET OPTIONS (description = "Expiry date, when set.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN cancelled_at
  SET OPTIONS (description = "When it was cancelled; NULL when it was not.");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
ALTER TABLE staging.stg_zohobilling__subscriptions ALTER COLUMN is_active
  SET OPTIONS (description = "TRUE when status is live. Use this, not status, for the has-a-subscription test.");
