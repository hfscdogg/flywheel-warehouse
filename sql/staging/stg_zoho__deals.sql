-- stg_zoho__deals — latest record per Zoho CRM deal.
-- Grain: one row per deal_id.
-- Source: raw_zoho.deals (append-only; payload = full Zoho v2 record).
CREATE OR REPLACE TABLE staging.stg_zoho__deals AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_zoho.deals
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
),
fields AS (
  SELECT
    _source_id                                                 AS deal_id,
    JSON_VALUE(payload, '$.Deal_Name')                         AS deal_name,
    JSON_VALUE(payload, '$.Stage')                             AS stage,
    JSON_VALUE(payload, '$.Pipeline')                          AS pipeline,
    SAFE_CAST(JSON_VALUE(payload, '$.Amount') AS NUMERIC)      AS amount,
    SAFE_CAST(JSON_VALUE(payload, '$.Probability') AS INT64)   AS probability_pct,
    SAFE_CAST(JSON_VALUE(payload, '$.Closing_Date') AS DATE)   AS closing_date,
    JSON_VALUE(payload, '$.Lead_Source')                       AS lead_source,
    JSON_VALUE(payload, '$.Account_Name.id')                   AS account_id,
    JSON_VALUE(payload, '$.Account_Name.name')                 AS account_name,
    JSON_VALUE(payload, '$.Contact_Name.id')                   AS contact_id,
    JSON_VALUE(payload, '$.Contact_Name.name')                 AS contact_name,
    JSON_VALUE(payload, '$.Owner.name')                        AS owner_name,
    JSON_VALUE(payload, '$.Owner.email')                       AS owner_email,
    SAFE_CAST(JSON_VALUE(payload, '$.Created_Time') AS TIMESTAMP)  AS created_at,
    SAFE_CAST(JSON_VALUE(payload, '$.Modified_Time') AS TIMESTAMP) AS modified_at,
    _loaded_at                                                 AS loaded_at
  FROM latest
)
SELECT
  *,
  -- Zoho's default closed stages are "Closed Won" / "Closed Lost" /
  -- "Closed-Lost to Competition". Matched loosely so renamed stages that
  -- keep the words still classify.
  REGEXP_CONTAINS(LOWER(COALESCE(stage, '')), 'won')  AS is_won,
  REGEXP_CONTAINS(LOWER(COALESCE(stage, '')), 'lost') AS is_lost
FROM fields;
