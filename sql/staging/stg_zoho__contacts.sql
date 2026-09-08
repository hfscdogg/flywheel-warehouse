-- stg_zoho__contacts — latest record per Zoho CRM contact.
-- Grain: one row per contact_id.
-- Source: raw_zoho.contacts (append-only; payload = full Zoho v2 record).
CREATE OR REPLACE TABLE staging.stg_zoho__contacts
OPTIONS (description = """
Zoho CRM contacts, one row per person the sales team deals with, each linked to the account (company or household) they belong to. Join to stg_zoho__accounts on account_id.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_zoho.contacts
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                 AS contact_id,
  JSON_VALUE(payload, '$.First_Name')                        AS first_name,
  JSON_VALUE(payload, '$.Last_Name')                         AS last_name,
  JSON_VALUE(payload, '$.Full_Name')                         AS full_name,
  LOWER(JSON_VALUE(payload, '$.Email'))                      AS email,
  JSON_VALUE(payload, '$.Phone')                             AS phone,
  JSON_VALUE(payload, '$.Account_Name.id')                   AS account_id,
  JSON_VALUE(payload, '$.Account_Name.name')                 AS account_name,
  JSON_VALUE(payload, '$.Owner.name')                        AS owner_name,
  JSON_VALUE(payload, '$.Owner.email')                       AS owner_email,
  SAFE_CAST(JSON_VALUE(payload, '$.Created_Time') AS TIMESTAMP)  AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.Modified_Time') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                 AS loaded_at
FROM latest;

ALTER TABLE staging.stg_zoho__contacts ALTER COLUMN contact_id
  SET OPTIONS (description = "Zoho CRM contact id; the key.");
ALTER TABLE staging.stg_zoho__contacts ALTER COLUMN first_name
  SET OPTIONS (description = "First name.");
ALTER TABLE staging.stg_zoho__contacts ALTER COLUMN last_name
  SET OPTIONS (description = "Last name.");
ALTER TABLE staging.stg_zoho__contacts ALTER COLUMN full_name
  SET OPTIONS (description = "Full name.");
ALTER TABLE staging.stg_zoho__contacts ALTER COLUMN email
  SET OPTIONS (description = "Contact email.");
ALTER TABLE staging.stg_zoho__contacts ALTER COLUMN phone
  SET OPTIONS (description = "Contact phone.");
ALTER TABLE staging.stg_zoho__contacts ALTER COLUMN account_id
  SET OPTIONS (description = "Account the contact belongs to; joins to stg_zoho__accounts.");
ALTER TABLE staging.stg_zoho__contacts ALTER COLUMN account_name
  SET OPTIONS (description = "That account's name.");
ALTER TABLE staging.stg_zoho__contacts ALTER COLUMN owner_name
  SET OPTIONS (description = "CRM user who owns the contact.");
ALTER TABLE staging.stg_zoho__contacts ALTER COLUMN owner_email
  SET OPTIONS (description = "That owner's email.");
ALTER TABLE staging.stg_zoho__contacts ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_zoho__contacts ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_zoho__contacts ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
