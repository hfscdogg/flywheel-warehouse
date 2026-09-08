-- stg_zoho__accounts — latest record per Zoho CRM account (company).
-- Grain: one row per account_id.
-- Source: raw_zoho.accounts (append-only; payload = full Zoho v2 record).
CREATE OR REPLACE TABLE staging.stg_zoho__accounts
OPTIONS (description = """
Zoho CRM accounts, one row per account: the customer record the sales team keeps. Has the billing address that Zoho Billing lacks, so this is the bridge from a vendor's service address to a Billing customer (matched on by name).
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_zoho.accounts
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                 AS account_id,
  JSON_VALUE(payload, '$.Account_Name')                      AS account_name,
  JSON_VALUE(payload, '$.Industry')                          AS industry,
  JSON_VALUE(payload, '$.Phone')                             AS phone,
  JSON_VALUE(payload, '$.Website')                           AS website,
  JSON_VALUE(payload, '$.Billing_Street')                    AS billing_street,
  JSON_VALUE(payload, '$.Billing_City')                      AS billing_city,
  JSON_VALUE(payload, '$.Billing_State')                     AS billing_state,
  JSON_VALUE(payload, '$.Billing_Code')                      AS billing_zip,
  JSON_VALUE(payload, '$.Owner.name')                        AS owner_name,
  JSON_VALUE(payload, '$.Owner.email')                       AS owner_email,
  SAFE_CAST(JSON_VALUE(payload, '$.Created_Time') AS TIMESTAMP)  AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.Modified_Time') AS TIMESTAMP) AS modified_at,
  -- Same key the monitoring-vendor models build: house number, street name
  -- with the suffix stripped, ZIP5. Keyed on house number and ZIP alone it
  -- collided across every street in a ZIP; see the vendor models for the note. The CRM
  -- is where Livewire's install addresses actually live: Zoho Billing's list
  -- endpoint returns no address at all, and its customer records carry no CRM
  -- reference (0 of 34,248), so kpi_subscription_audit reaches a subscription
  -- by way of this key and then the account name. Sparse by nature — about a
  -- third of accounts have a billing street — and an account without one
  -- simply does not participate in the match.
  CONCAT(
    COALESCE(REGEXP_EXTRACT(JSON_VALUE(payload, '$.Billing_Street'), r'^\s*(\d+)'), ''), '|',
    COALESCE(REGEXP_REPLACE(REGEXP_REPLACE(
      LOWER(COALESCE(REGEXP_EXTRACT(JSON_VALUE(payload, '$.Billing_Street'), r'^\s*\d+\s+(.*)$'), '')),
      r'\b(st|street|rd|road|dr|drive|ln|lane|ct|court|cir|circle|pl|place|ave|avenue|blvd|boulevard|way|ter|terrace|trl|trail|pkwy|parkway|hwy|highway|apt|unit|ste|suite)\b\.?', ''),
      r'[^a-z0-9]+', ''), ''), '|',
    COALESCE(REGEXP_EXTRACT(JSON_VALUE(payload, '$.Billing_Code'), r'(\d{5})'), '')
  )  AS address_key,
  _loaded_at                                                 AS loaded_at
FROM latest;

ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN account_id
  SET OPTIONS (description = "Zoho CRM account id; the key.");
ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN account_name
  SET OPTIONS (description = "Account name. Matched by name to Zoho Billing customer display names.");
ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN industry
  SET OPTIONS (description = "Industry picklist value.");
ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN phone
  SET OPTIONS (description = "Account phone.");
ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN website
  SET OPTIONS (description = "Account website.");
ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN billing_street
  SET OPTIONS (description = "Billing street address.");
ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN billing_city
  SET OPTIONS (description = "Billing city.");
ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN billing_state
  SET OPTIONS (description = "Billing state.");
ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN billing_zip
  SET OPTIONS (description = "Billing ZIP.");
ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN owner_name
  SET OPTIONS (description = "CRM user who owns the account.");
ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN owner_email
  SET OPTIONS (description = "That owner's email.");
ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN address_key
  SET OPTIONS (description = "Address match key used to line this record up with the same property in other systems: house number | street name with its suffix stripped | 5-digit ZIP. A heuristic, not an identifier; two different households can share one. Equal keys across tables mean the same address, not proof of the same customer.");
ALTER TABLE staging.stg_zoho__accounts ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
