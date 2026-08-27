-- stg_alarmdotcom__customers — latest record per Alarm.com customer account.
-- Grain: one row per customerId.
-- Source: raw_alarmdotcom.customers (append-only; payload = Partner API record).
--
-- VERIFY on first run: field paths are written from the Partner Portal API
-- docs, not observed responses. Two things can produce an all-NULL column
-- here and they are worth telling apart — a wrong path, or a rep credential
-- without permission for that property (the API returns null rather than an
-- error in that case).
--
-- Shaped to line up with stg_vendor__securitycentral_accounts so both
-- vendors can feed one audit: same address_key, same is_active_at_vendor.
CREATE OR REPLACE TABLE staging.stg_alarmdotcom__customers AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_alarmdotcom.customers
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id ORDER BY _loaded_at DESC
  ) = 1
),
fields AS (
  SELECT
    _source_id                                                AS customer_id,
    JSON_VALUE(payload, '$.firstName')                        AS first_name,
    JSON_VALUE(payload, '$.lastName')                         AS last_name,
    LOWER(JSON_VALUE(payload, '$.email'))                     AS email,
    JSON_VALUE(payload, '$.customerName')                     AS customer_name,
    JSON_VALUE(payload, '$.status')                           AS status,
    JSON_VALUE(payload, '$.address.street1')                  AS street_address,
    JSON_VALUE(payload, '$.address.street2')                  AS street_address_2,
    JSON_VALUE(payload, '$.address.city')                     AS city,
    JSON_VALUE(payload, '$.address.state')                    AS state,
    JSON_VALUE(payload, '$.address.postalCode')               AS zip,
    JSON_VALUE(payload, '$.dealerId')                         AS dealer_id,
    _loaded_at                                                AS loaded_at
  FROM latest
)
SELECT
  *,
  COALESCE(
    NULLIF(TRIM(CONCAT(COALESCE(first_name, ''), ' ', COALESCE(last_name, ''))), ''),
    customer_name
  )                                                           AS subscriber_name,
  -- Alarm.com has no single documented "active" flag; absent a status value
  -- treat the account as active, since its presence on the dealer's customer
  -- list is what we are billed for. Revisit once the first run shows what
  -- status actually contains.
  COALESCE(LOWER(status) NOT IN ('cancelled', 'canceled', 'inactive', 'terminated'), TRUE)
                                                              AS is_active_at_vendor,
  -- Same join key as the Security Central model: house number + ZIP.
  CONCAT(
    COALESCE(REGEXP_EXTRACT(street_address, r'^(\d+)'), ''), '|',
    COALESCE(REGEXP_EXTRACT(zip, r'(\d{5})'), '')
  )                                                           AS address_key
FROM fields;
