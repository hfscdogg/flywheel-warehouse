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
  -- Address match key: house number | street name (suffix-stripped) | ZIP5.
  --
  -- The street name is NOT optional. An earlier version keyed on house number
  -- and ZIP alone, to tolerate "Dr" vs "Drive"; a 5-digit ZIP covers thousands
  -- of homes, so "1594|23113" collided across every street in that ZIP and the
  -- audit matched four of six sampled accounts to a completely different
  -- person. Stripping the suffix keeps the tolerance without the collisions:
  -- "13413 Langford Dr" and "13413 Langford Drive" both key 13413|langford|.
  --
  -- Repeated verbatim in stg_vendor__securitycentral_accounts,
  -- stg_alarmdotcom__customers, stg_zoho__accounts and kpi_subscription_audit
  -- — this repo templates nothing, so the four must be edited together.
  CONCAT(
    COALESCE(REGEXP_EXTRACT(street_address, r'^\s*(\d+)'), ''), '|',
    COALESCE(REGEXP_REPLACE(REGEXP_REPLACE(
      LOWER(COALESCE(REGEXP_EXTRACT(street_address, r'^\s*\d+\s+(.*)$'), '')),
      r'\b(st|street|rd|road|dr|drive|ln|lane|ct|court|cir|circle|pl|place|ave|avenue|blvd|boulevard|way|ter|terrace|trl|trail|pkwy|parkway|hwy|highway|apt|unit|ste|suite)\b\.?', ''),
      r'[^a-z0-9]+', ''), ''), '|',
    COALESCE(REGEXP_EXTRACT(zip, r'(\d{5})'), '')
  )  AS address_key
FROM fields;
