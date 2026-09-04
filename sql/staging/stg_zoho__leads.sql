-- stg_zoho__leads — latest record per Zoho CRM lead.
-- Grain: one row per lead_id.
-- Source: raw_zoho.leads (append-only; payload = full Zoho v2 record).
-- Dataset names are unqualified on purpose: `bq query --project_id` resolves
-- them against the client's project (scripts/06-transform.sh).
CREATE OR REPLACE TABLE staging.stg_zoho__leads
OPTIONS (description = """
Zoho CRM leads, one row per lead: an inquiry before it is converted to an account and deal.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_zoho.leads
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                 AS lead_id,
  JSON_VALUE(payload, '$.First_Name')                        AS first_name,
  JSON_VALUE(payload, '$.Last_Name')                         AS last_name,
  JSON_VALUE(payload, '$.Full_Name')                         AS full_name,
  JSON_VALUE(payload, '$.Company')                           AS company,
  LOWER(JSON_VALUE(payload, '$.Email'))                      AS email,
  JSON_VALUE(payload, '$.Phone')                             AS phone,
  JSON_VALUE(payload, '$.Lead_Source')                       AS lead_source,
  JSON_VALUE(payload, '$.Lead_Status')                       AS lead_status,
  JSON_VALUE(payload, '$.Industry')                          AS industry,
  JSON_VALUE(payload, '$.City')                              AS city,
  JSON_VALUE(payload, '$.State')                             AS state,
  JSON_VALUE(payload, '$.Owner.name')                        AS owner_name,
  JSON_VALUE(payload, '$.Owner.email')                       AS owner_email,
  SAFE_CAST(JSON_VALUE(payload, '$.Created_Time') AS TIMESTAMP)  AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.Modified_Time') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                 AS loaded_at
FROM latest;

ALTER TABLE staging.stg_zoho__leads ALTER COLUMN lead_id
  SET OPTIONS (description = "Zoho CRM lead id; the key.");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN first_name
  SET OPTIONS (description = "First name.");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN last_name
  SET OPTIONS (description = "Last name.");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN full_name
  SET OPTIONS (description = "Full name.");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN company
  SET OPTIONS (description = "Company, when given.");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN email
  SET OPTIONS (description = "Lead email.");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN phone
  SET OPTIONS (description = "Lead phone.");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN lead_source
  SET OPTIONS (description = "Lead source picklist.");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN lead_status
  SET OPTIONS (description = "Lead status picklist.");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN industry
  SET OPTIONS (description = "Industry picklist.");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN city
  SET OPTIONS (description = "City the lead gave.");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN state
  SET OPTIONS (description = "State the lead gave.");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN owner_name
  SET OPTIONS (description = "CRM user who owns the lead.");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN owner_email
  SET OPTIONS (description = "That owner's email.");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_zoho__leads ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
