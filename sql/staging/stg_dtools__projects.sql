-- stg_dtools__projects — latest record per D-Tools Cloud project.
-- Grain: one row per project_id.
-- Source: raw_dtools.projects (append-only; payload = full API record).
-- Field paths are best-effort pending verification against live payloads;
-- an all-NULL column means a wrong path — a one-line COALESCE fix here.
CREATE OR REPLACE TABLE staging.stg_dtools__projects AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_dtools.projects
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                 AS project_id,
  JSON_VALUE(payload, '$.name')                              AS name,
  COALESCE(JSON_VALUE(payload, '$.client.name'),
           JSON_VALUE(payload, '$.clientName'))              AS client_name,
  COALESCE(JSON_VALUE(payload, '$.status.name'),
           JSON_VALUE(payload, '$.status'))                  AS status,
  JSON_VALUE(payload, '$.opportunityId')                     AS opportunity_id,
  SAFE_CAST(COALESCE(JSON_VALUE(payload, '$.price'),
                     JSON_VALUE(payload, '$.totalPrice'),
                     JSON_VALUE(payload, '$.contractPrice')) AS NUMERIC)  AS price,
  SAFE_CAST(COALESCE(JSON_VALUE(payload, '$.cost'),
                     JSON_VALUE(payload, '$.totalCost'),
                     JSON_VALUE(payload, '$.estimatedCost')) AS NUMERIC)  AS cost,
  SAFE_CAST(JSON_VALUE(payload, '$.createdDate') AS TIMESTAMP)  AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.modifiedDate') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                 AS loaded_at
FROM latest;
