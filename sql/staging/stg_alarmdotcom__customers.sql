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
CREATE OR REPLACE TABLE staging.stg_alarmdotcom__customers
OPTIONS (description = """
Alarm.com customers as returned by the Partner API, one row per customer id. EMPTY until the Partner API is credentialed; the dealer-site export in stg_vendor__alarmdotcom_accounts is the live Alarm.com feed and is what the audit uses. Prefer that table.
""")
AS
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
  customer_id,
  first_name,
  last_name,
  email,
  customer_name,
  status,
  street_address,
  city,
  state,
  zip,
  dealer_id,
  loaded_at,
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

ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN customer_id
  SET OPTIONS (description = "Alarm.com customer id.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN first_name
  SET OPTIONS (description = "Customer first name.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN last_name
  SET OPTIONS (description = "Customer last name.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN email
  SET OPTIONS (description = "Customer email.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN customer_name
  SET OPTIONS (description = "Full name as the API returns it.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN status
  SET OPTIONS (description = "Account status word from the API.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN street_address
  SET OPTIONS (description = "Service address street line.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN city
  SET OPTIONS (description = "Service city.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN state
  SET OPTIONS (description = "Service state.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN zip
  SET OPTIONS (description = "Service ZIP.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN dealer_id
  SET OPTIONS (description = "Alarm.com dealer id the customer belongs to.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN subscriber_name
  SET OPTIONS (description = "Display name used for matching: full name, or the parts joined.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN is_active_at_vendor
  SET OPTIONS (description = "TRUE when the status counts as active.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN address_key
  SET OPTIONS (description = "Address match key used to line this record up with the same property in other systems: house number | street name with its suffix stripped | 5-digit ZIP. A heuristic, not an identifier; two different households can share one. Equal keys across tables mean the same address, not proof of the same customer.");
