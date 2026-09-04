-- stg_vendor__parasol_accounts — accounts Parasol bills us for.
-- Grain: one row per synthesised account key.
-- Source: raw_vendor.parasol_accounts (drop-bucket uploads of the monthly
--   invoice PDF, which is the only roster Parasol provides).
--
-- The invoice is the roster: every line item is one monitored property, and
-- uniquely among our vendors it carries the RATE for that specific account.
-- A leak found here has a price on it rather than an estimate.
--
-- Every account on the invoice is by definition active — Parasol stops
-- billing when service stops — so is_active_at_vendor is unconditionally
-- TRUE and there is no deactivated cohort to reconcile.
CREATE OR REPLACE TABLE staging.stg_vendor__parasol_accounts
OPTIONS (description = """
Parasol accounts, one row per line item on the latest monthly invoice, which is the only roster Parasol provides. Parasol sells 24/7 remote support; every row is an account we are billed for and monthly_rate is what it costs, the only vendor that tells us. kpi_subscription_audit uses this table.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_vendor.parasol_accounts
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id ORDER BY _loaded_at DESC
  ) = 1
),
fields AS (
  SELECT
    _source_id                                            AS account_no,
    JSON_VALUE(payload, '$.SUBSCRIBER')                   AS subscriber_name,
    JSON_VALUE(payload, '$.LABEL')                        AS property_label,
    JSON_VALUE(payload, '$.STREET')                       AS street_address,
    JSON_VALUE(payload, '$.CITY_STATE_ZIP')               AS city_state_zip,
    JSON_VALUE(payload, '$.TIER')                         AS service_tier,
    SAFE_CAST(JSON_VALUE(payload, '$.RATE') AS NUMERIC)   AS monthly_rate,
    _loaded_at                                            AS loaded_at
  FROM latest
)
SELECT
  account_no,
  subscriber_name,
  property_label,
  street_address,
  city_state_zip,
  service_tier,
  monthly_rate,
  loaded_at,
  TRIM(REGEXP_EXTRACT(city_state_zip, r'^([^,]+?)[, ]+(?:VA|Virginia)'))  AS city,
  REGEXP_EXTRACT(city_state_zip, r'\b(VA|Virginia)\b')                    AS state,
  REGEXP_EXTRACT(city_state_zip, r'\b(\d{5})\b')                          AS zip,
  TRUE                                                                    AS is_active_at_vendor,
  -- Address match key: house number | street name (suffix-stripped) | ZIP5.
  -- Kept verbatim in step with the other vendor models and the audit mart;
  -- see stg_vendor__securitycentral_accounts for why the street name is not
  -- optional. The pipeline normalises Parasol's number-last addresses
  -- ("Longfield Road 629") before landing, so this sees a leading number.
  CONCAT(
    COALESCE(REGEXP_EXTRACT(street_address, r'^\s*(\d+)'), ''), '|',
    COALESCE(REGEXP_REPLACE(REGEXP_REPLACE(
      LOWER(COALESCE(REGEXP_EXTRACT(street_address, r'^\s*\d+\s+(.*)$'), '')),
      r'\b(st|street|rd|road|dr|drive|ln|lane|ct|court|cir|circle|pl|place|ave|avenue|blvd|boulevard|way|ter|terrace|trl|trail|pkwy|parkway|hwy|highway|apt|unit|ste|suite)\b\.?', ''),
      r'[^a-z0-9]+', ''), ''), '|',
    COALESCE(REGEXP_EXTRACT(city_state_zip, r'\b(\d{5})\b'), '')
  )                                                                       AS address_key
FROM fields;

ALTER TABLE staging.stg_vendor__parasol_accounts ALTER COLUMN account_no
  SET OPTIONS (description = "Synthesised key: Parasol assigns no account numbers, so this is built from name, street, ZIP and label.");
ALTER TABLE staging.stg_vendor__parasol_accounts ALTER COLUMN subscriber_name
  SET OPTIONS (description = "Name on the invoice line, surname first.");
ALTER TABLE staging.stg_vendor__parasol_accounts ALTER COLUMN property_label
  SET OPTIONS (description = "Label Parasol prints for the location, e.g. Home.");
ALTER TABLE staging.stg_vendor__parasol_accounts ALTER COLUMN street_address
  SET OPTIONS (description = "Service street address, normalised so the house number leads.");
ALTER TABLE staging.stg_vendor__parasol_accounts ALTER COLUMN city_state_zip
  SET OPTIONS (description = "City, state and ZIP as printed.");
ALTER TABLE staging.stg_vendor__parasol_accounts ALTER COLUMN service_tier
  SET OPTIONS (description = "Essential or Enhanced.");
ALTER TABLE staging.stg_vendor__parasol_accounts ALTER COLUMN monthly_rate
  SET OPTIONS (description = "What Parasol charges for this account per month, USD.");
ALTER TABLE staging.stg_vendor__parasol_accounts ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
ALTER TABLE staging.stg_vendor__parasol_accounts ALTER COLUMN city
  SET OPTIONS (description = "Service city parsed from city_state_zip.");
ALTER TABLE staging.stg_vendor__parasol_accounts ALTER COLUMN state
  SET OPTIONS (description = "Service state.");
ALTER TABLE staging.stg_vendor__parasol_accounts ALTER COLUMN zip
  SET OPTIONS (description = "5-digit ZIP.");
ALTER TABLE staging.stg_vendor__parasol_accounts ALTER COLUMN is_active_at_vendor
  SET OPTIONS (description = "Always TRUE: being on the invoice is what active means for Parasol.");
ALTER TABLE staging.stg_vendor__parasol_accounts ALTER COLUMN address_key
  SET OPTIONS (description = "Address match key used to line this record up with the same property in other systems: house number | street name with its suffix stripped | 5-digit ZIP. A heuristic, not an identifier; two different households can share one. Equal keys across tables mean the same address, not proof of the same customer.");
