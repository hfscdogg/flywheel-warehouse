-- stg_alarmdotcom__customers — latest record per Alarm.com customer account.
-- Grain: one row per customerId.
-- Source: raw_alarmdotcom.customers (append-only; payload = the Partner API
--   CustomerModel from GET /v1/customers/{id}, one per customer).
--
-- Field paths follow the CustomerModel in the API reference
-- (/PartnerApi/help/docs/v1/, read 2026-11-04). A rep credential without
-- permission for a property gets null rather than an error, so an all-NULL
-- column can mean the rep cannot see it.
--
-- Shaped to line up with stg_vendor__securitycentral_accounts so both
-- vendors can feed one audit: same address_key, same is_active_at_vendor.
CREATE OR REPLACE TABLE staging.stg_alarmdotcom__customers
OPTIONS (description = """
Alarm.com customers as returned by the Partner API, one row per customer id, refreshed nightly, terminated accounts included (is_terminated). Carries each account's service plan price and central station account number, which the dealer-site export in stg_vendor__alarmdotcom_accounts does not; that export is still what the subscription audit reads.
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
    JSON_VALUE(payload, '$.companyName')                      AS customer_name,
    SAFE_CAST(JSON_VALUE(payload, '$.isTerminated') AS BOOL)  AS is_terminated,
    JSON_VALUE(payload, '$.installAddress.street1')           AS street_address,
    JSON_VALUE(payload, '$.installAddress.street2')           AS street_address_2,
    JSON_VALUE(payload, '$.installAddress.city')              AS city,
    JSON_VALUE(payload, '$.installAddress.state')             AS state,
    JSON_VALUE(payload, '$.installAddress.zip')               AS zip,
    JSON_VALUE(payload, '$.dealerId')                         AS dealer_id,
    SAFE_CAST(SUBSTR(JSON_VALUE(payload, '$.joinDate'), 1, 10) AS DATE) AS join_date,
    SAFE_CAST(SUBSTR(JSON_VALUE(payload, '$.termDate'), 1, 10) AS DATE) AS term_date,
    -- Security Central's account number as every other source writes it,
    -- prefix and number joined by a dash (A1651-1074): the API returns the
    -- two halves separately. NULL when the prefix is missing, since a bare
    -- number names no account on its own.
    IF(JSON_VALUE(payload, '$.centralStationInfo.accountPrefix') IS NULL
         OR JSON_VALUE(payload, '$.centralStationInfo.accountNumber') IS NULL, NULL,
       CONCAT(JSON_VALUE(payload, '$.centralStationInfo.accountPrefix'), '-',
              JSON_VALUE(payload, '$.centralStationInfo.accountNumber'))) AS central_station_account,
    SAFE_CAST(JSON_VALUE(payload, '$.servicePlanInfo.totalServicePrice') AS NUMERIC) AS service_plan_price,
    JSON_VALUE(payload, '$.servicePlanInfo.packageDescription')        AS service_package,
    SAFE_CAST(SUBSTR(JSON_VALUE(payload, '$.pendingTerminationDateUtc'), 1, 10) AS DATE) AS pending_termination_date,
    _loaded_at                                                AS loaded_at
  FROM latest
)
SELECT
  customer_id,
  first_name,
  last_name,
  email,
  customer_name,
  CASE is_terminated WHEN TRUE THEN 'terminated' WHEN FALSE THEN 'active' END AS status,
  is_terminated,
  join_date,
  term_date,
  central_station_account,
  service_plan_price,
  service_package,
  pending_termination_date,
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
  -- isTerminated is the API's own flag. Absent it (a rep that cannot see it)
  -- the account counts as active: its presence on the dealer's customer list
  -- is what we are billed for.
  NOT COALESCE(is_terminated, FALSE)                          AS is_active_at_vendor,
  -- Address match key: house number | street name (suffix-stripped) | ZIP5.
  --
  -- The street name is NOT optional. An earlier version keyed on house number
  -- and ZIP alone, to tolerate "Dr" vs "Drive"; a 5-digit ZIP covers thousands
  -- of homes, so "1594|23113" collided across every street in that ZIP and the
  -- audit matched four of six sampled accounts to a completely different
  -- person. Stripping the suffix keeps the tolerance without the collisions:
  -- "13413 Langford Dr" and "13413 Langford Drive" both key 13413|langford|.
  --
  -- Kept identical across all six models by
  -- pipelines/tests/test_sql_address_key.py: two sides of this join must
  -- turn the same address into the same string or the match silently
  -- misses. Compass directions are reduced to a letter because
  -- "322 N 25th St" and "322 North 25th Street" are one address.
  -- Repeated verbatim in stg_vendor__securitycentral_accounts,
  -- stg_alarmdotcom__customers, stg_zoho__accounts and kpi_subscription_audit
  -- — this repo templates nothing, so the four must be edited together.
  CONCAT(
    COALESCE(REGEXP_EXTRACT(street_address, r'^\s*(\d+)'), ''), '|',
    COALESCE(REGEXP_REPLACE(REGEXP_REPLACE(
      REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
        LOWER(COALESCE(REGEXP_EXTRACT(street_address, r'^\s*\d+\s+(.*)$'), '')),
        r'\b(n|s)(?:orth|outh)(e|w)(?:ast|est)\b', r'\1\2'),
        r'\b(n|s)(?:orth|outh)\b', r'\1'),
        r'\b(e|w)(?:ast|est)\b', r'\1'),
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
  SET OPTIONS (description = "Company name on the account, for business customers; NULL for most homes.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN status
  SET OPTIONS (description = "'terminated' or 'active', from the API's isTerminated flag; NULL when the rep cannot see it.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN is_terminated
  SET OPTIONS (description = "TRUE when Alarm.com shows the account terminated. Terminated accounts are kept so the audit can find ones still billed.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN join_date
  SET OPTIONS (description = "Date the account joined Alarm.com.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN term_date
  SET OPTIONS (description = "Date the account was terminated; NULL while active.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN central_station_account
  SET OPTIONS (description = "Security Central account number the panel reports under, prefix and number joined (A1651-1074), as Security Central's own reports and stg_vendor__securitycentral_statement.account_number write it: an exact cross-vendor key. NULL when Alarm.com holds no prefix for it.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN service_plan_price
  SET OPTIONS (description = "Total price of the account's current Alarm.com service plan as the API reports it (servicePlanInfo.totalServicePrice), USD. Which side of the bill it is (dealer cost or list price) is not documented; check against an Alarm.com invoice before relying on it.");
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
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN service_package
  SET OPTIONS (description = "Alarm.com service package on the account (e.g. Interactive Gold, Commercial).");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN pending_termination_date
  SET OPTIONS (description = "Date the account is scheduled to terminate; NULL when none is pending. An account pending termination is still active until then.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN is_active_at_vendor
  SET OPTIONS (description = "TRUE when the status counts as active.");
ALTER TABLE staging.stg_alarmdotcom__customers ALTER COLUMN address_key
  SET OPTIONS (description = "Address match key used to line this record up with the same property in other systems: house number | street name with its suffix stripped and any compass direction reduced to a letter (North to n) | 5-digit ZIP. A heuristic, not an identifier; two different households can share one. Equal keys across tables mean the same address, not proof of the same customer.");
