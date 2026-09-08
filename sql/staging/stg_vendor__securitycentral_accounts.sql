-- stg_vendor__securitycentral_accounts — latest load per Security Central account.
-- Grain: one row per vendor account number.
-- Source: raw_vendor.securitycentral_accounts, loaded by
--   scripts/08-vendor-roster.sh from the portal's "All Accounts" export.
--
-- The export is report-shaped: one row per account CONTACT, so an account
-- with two phone numbers appears twice. Dedup keeps the most recently
-- loaded row per account.
--
-- SUBSCRIBER packs name and address into one pipe-delimited string:
--   "Mr./Mrs. Pellock|13413 Langford Dr||Midlothian, VA 23113"
--   [0] name  [1] street  [2] unit (usually empty)  [3] "City, ST ZIP"
CREATE OR REPLACE TABLE staging.stg_vendor__securitycentral_accounts
OPTIONS (description = """
Security Central accounts from the All Accounts export, one row per account: the roster with addresses. Security Central is the central station that monitors alarms; we pay them per account. Status here is as of the export; the weekly feed in stg_vendor__securitycentral_status is fresher. kpi_subscription_audit joins the two on contract_no.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_vendor.securitycentral_accounts
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id ORDER BY _loaded_at DESC
  ) = 1
),
parsed AS (
  SELECT
    _source_id                                            AS account_no,
    JSON_VALUE(payload, '$.CONTRACT')                     AS contract_no,
    JSON_VALUE(payload, '$.STATUS')                       AS status,
    JSON_VALUE(payload, '$.TYPE')                         AS account_type,
    JSON_VALUE(payload, '$.CONTACT')                      AS contact_phone,
    SAFE_CAST(SUBSTR(JSON_VALUE(payload, '$.STARTED'), 1, 10) AS DATE) AS started_on,
    SPLIT(JSON_VALUE(payload, '$.SUBSCRIBER'), '|')       AS subscriber_parts,
    _loaded_at                                            AS loaded_at
  FROM latest
),
fields AS (
  SELECT
    * EXCEPT (subscriber_parts),
    TRIM(subscriber_parts[SAFE_OFFSET(0)])                AS subscriber_name,
    TRIM(subscriber_parts[SAFE_OFFSET(1)])                AS street_address,
    TRIM(subscriber_parts[SAFE_OFFSET(2)])                AS unit,
    TRIM(subscriber_parts[SAFE_OFFSET(3)])                AS city_state_zip
  FROM parsed
)
SELECT
  account_no,
  contract_no,
  status,
  account_type,
  contact_phone,
  started_on,
  loaded_at,
  subscriber_name,
  street_address,
  unit,
  city_state_zip,
  TRIM(REGEXP_EXTRACT(city_state_zip, r'^([^,]+),'))      AS city,
  REGEXP_EXTRACT(city_state_zip, r',\s*([A-Z]{2})\s')     AS state,
  REGEXP_EXTRACT(city_state_zip, r'(\d{5})(?:-\d{4})?\s*$') AS zip,
  status = 'Active'                                       AS is_active_at_vendor,
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
    COALESCE(REGEXP_EXTRACT(city_state_zip, r'(\d{5})'), '')
  )  AS address_key
FROM fields;

ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN account_no
  SET OPTIONS (description = "Security Central account number, e.g. A1651-1857; the key. Appears on Alarm.com records as sc_account_no.");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN contract_no
  SET OPTIONS (description = "Contract number; the join key to the weekly status feed. One contract can cover two accounts.");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN status
  SET OPTIONS (description = "Active, Deactivated or Inactive as of the export.");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN account_type
  SET OPTIONS (description = "Residential, Commercial or Commercial Fire.");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN contact_phone
  SET OPTIONS (description = "Contact phone on the account.");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN started_on
  SET OPTIONS (description = "Account start date.");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN subscriber_name
  SET OPTIONS (description = "Subscriber name on the account.");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN street_address
  SET OPTIONS (description = "Service street address.");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN unit
  SET OPTIONS (description = "Unit or apartment, when present.");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN city_state_zip
  SET OPTIONS (description = "City, state and ZIP as exported.");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN city
  SET OPTIONS (description = "Service city.");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN state
  SET OPTIONS (description = "Two-letter state.");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN zip
  SET OPTIONS (description = "5-digit ZIP.");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN is_active_at_vendor
  SET OPTIONS (description = "TRUE when status is Active.");
ALTER TABLE staging.stg_vendor__securitycentral_accounts ALTER COLUMN address_key
  SET OPTIONS (description = "Address match key used to line this record up with the same property in other systems: house number | street name with its suffix stripped | 5-digit ZIP. A heuristic, not an identifier; two different households can share one. Equal keys across tables mean the same address, not proof of the same customer.");
