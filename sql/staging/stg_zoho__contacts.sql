-- stg_zoho__contacts — latest record per Zoho CRM contact.
-- Grain: one row per contact_id.
-- Source: raw_zoho.contacts (append-only; payload = full Zoho v2 record).
CREATE OR REPLACE TABLE staging.stg_zoho__contacts AS
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
