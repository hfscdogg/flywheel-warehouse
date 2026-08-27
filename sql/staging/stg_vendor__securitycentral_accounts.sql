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
CREATE OR REPLACE TABLE staging.stg_vendor__securitycentral_accounts AS
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
  *,
  TRIM(REGEXP_EXTRACT(city_state_zip, r'^([^,]+),'))      AS city,
  REGEXP_EXTRACT(city_state_zip, r',\s*([A-Z]{2})\s')     AS state,
  REGEXP_EXTRACT(city_state_zip, r'(\d{5})(?:-\d{4})?\s*$') AS zip,
  status = 'Active'                                       AS is_active_at_vendor,
  -- Join key for matching billing records: house number + ZIP. Street names
  -- are written inconsistently across systems ("Dr" vs "Drive"), but the
  -- house number and ZIP rarely vary, and the pair is close to unique.
  CONCAT(
    COALESCE(REGEXP_EXTRACT(street_address, r'^(\d+)'), ''), '|',
    COALESCE(REGEXP_EXTRACT(city_state_zip, r'(\d{5})(?:-\d{4})?\s*$'), '')
  )                                                       AS address_key
FROM fields;
