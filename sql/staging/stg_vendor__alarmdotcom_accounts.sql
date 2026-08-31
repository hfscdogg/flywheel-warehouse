-- stg_vendor__alarmdotcom_accounts — the Alarm.com dealer-site customer list.
-- Grain: one row per Alarm.com customer id.
-- Source: raw_vendor.alarmdotcom_accounts (drop-bucket uploads of the
--   "Custom List" export from the dealer site).
--
-- This is the export a human downloads, distinct from
-- stg_alarmdotcom__customers, which the Partner API pipeline fills. The
-- export arrived first because the API is still waiting on a working
-- client_id, and it turns out to be the better feed: complete addresses on
-- every row, and a column the API does not obviously expose.
--
-- THE CROSS-VENDOR KEY
-- CS Account Prefix + CS Account Number is Security Central's own account
-- number for the same property (A1651-1047). That is an exact key between
-- two vendors, where the audit's address match is only ever an approximation
-- — 502 of 597 rows carry it. Worth more than any address heuristic, and it
-- also gives the CRM a value to store if anyone ever wants this permanent.
--
-- Pending Termination Date marks an account on its way out. An account is
-- treated as active unless it carries one: Alarm.com does not publish a
-- status column in this export, and presence on the dealer's list is what
-- we are billed for.
CREATE OR REPLACE TABLE staging.stg_vendor__alarmdotcom_accounts AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_vendor.alarmdotcom_accounts
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id ORDER BY _loaded_at DESC
  ) = 1
),
fields AS (
  SELECT
    _source_id                                                AS customer_id,
    JSON_VALUE(payload, '$.SC_ACCOUNT')                       AS sc_account_no,
    JSON_VALUE(payload, '$["First Name"]')                    AS first_name,
    JSON_VALUE(payload, '$["Last Name"]')                     AS last_name,
    JSON_VALUE(payload, '$["Customer Company Name"]')         AS company_name,
    JSON_VALUE(payload, '$["System Description"]')            AS property_label,
    JSON_VALUE(payload, '$["Street 1"]')                      AS street_address,
    JSON_VALUE(payload, '$["City"]')                          AS city,
    JSON_VALUE(payload, '$["State"]')                         AS state,
    JSON_VALUE(payload, '$["Postal Code"]')                   AS zip,
    JSON_VALUE(payload, '$["Service Package"]')               AS service_package,
    JSON_VALUE(payload, '$["Primary E-Mail"]')                AS email,
    SAFE.PARSE_DATE('%m/%d/%Y', JSON_VALUE(payload, '$["Join Date (EDT)"]'))
                                                              AS started_on,
    JSON_VALUE(payload, '$["Pending Termination Date (EDT)"]') AS pending_termination,
    _loaded_at                                                AS loaded_at
  FROM latest
)
SELECT
  *,
  COALESCE(
    NULLIF(TRIM(CONCAT(COALESCE(first_name, ''), ' ', COALESCE(last_name, ''))), ''),
    company_name
  )                                                           AS subscriber_name,
  pending_termination IS NULL OR pending_termination = ''     AS is_active_at_vendor,
  -- Same key, verbatim, as the other vendor models and the audit mart.
  CONCAT(
    COALESCE(REGEXP_EXTRACT(street_address, r'^\s*(\d+)'), ''), '|',
    COALESCE(REGEXP_REPLACE(REGEXP_REPLACE(
      LOWER(COALESCE(REGEXP_EXTRACT(street_address, r'^\s*\d+\s+(.*)$'), '')),
      r'\b(st|street|rd|road|dr|drive|ln|lane|ct|court|cir|circle|pl|place|ave|avenue|blvd|boulevard|way|ter|terrace|trl|trail|pkwy|parkway|hwy|highway|apt|unit|ste|suite)\b\.?', ''),
      r'[^a-z0-9]+', ''), ''), '|',
    COALESCE(REGEXP_EXTRACT(zip, r'^(\d{5})'), '')
  )                                                           AS address_key
FROM fields;
