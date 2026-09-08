-- stg_dtools__opportunities — latest record per D-Tools Cloud opportunity.
-- Grain: one row per opportunity_id.
-- Source: raw_dtools.opportunities (append-only; payload = full API record).
-- Field paths are best-effort pending verification against live payloads
-- (same VERIFY-on-first-run posture as pipelines/lib/sources.py): an
-- all-NULL column means a wrong path — a one-line COALESCE fix here.
CREATE OR REPLACE TABLE staging.stg_dtools__opportunities
OPTIONS (description = """
D-Tools sales opportunities, one row per opportunity. An opportunity is a prospective job before it becomes a project; quotes (stg_dtools__quotes) hang off it and a won one becomes a project (stg_dtools__projects). Amounts USD.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_dtools.opportunities
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                 AS opportunity_id,
  JSON_VALUE(payload, '$.name')                              AS name,
  COALESCE(JSON_VALUE(payload, '$.client.name'),
           JSON_VALUE(payload, '$.clientName'))              AS client_name,
  COALESCE(JSON_VALUE(payload, '$.stage.name'),
           JSON_VALUE(payload, '$.stage'),
           JSON_VALUE(payload, '$.pipelineStage'))           AS stage,
  SAFE_CAST(COALESCE(JSON_VALUE(payload, '$.price'),
                     JSON_VALUE(payload, '$.estimatedPrice'),
                     JSON_VALUE(payload, '$.value')) AS NUMERIC) AS price,
  SAFE_CAST(JSON_VALUE(payload, '$.probability') AS INT64)   AS probability_pct,
  COALESCE(JSON_VALUE(payload, '$.owner.name'),
           JSON_VALUE(payload, '$.assignedTo.name'))         AS owner_name,
  SAFE_CAST(JSON_VALUE(payload, '$.createdDate') AS TIMESTAMP)  AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.modifiedDate') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                 AS loaded_at
FROM latest;

ALTER TABLE staging.stg_dtools__opportunities ALTER COLUMN opportunity_id
  SET OPTIONS (description = "D-Tools opportunity id; the key.");
ALTER TABLE staging.stg_dtools__opportunities ALTER COLUMN name
  SET OPTIONS (description = "Opportunity name as entered in D-Tools.");
ALTER TABLE staging.stg_dtools__opportunities ALTER COLUMN client_name
  SET OPTIONS (description = "Client name as entered in D-Tools; matches other systems by name only.");
ALTER TABLE staging.stg_dtools__opportunities ALTER COLUMN stage
  SET OPTIONS (description = "Sales stage word from D-Tools.");
ALTER TABLE staging.stg_dtools__opportunities ALTER COLUMN price
  SET OPTIONS (description = "Expected sell price, USD.");
ALTER TABLE staging.stg_dtools__opportunities ALTER COLUMN probability_pct
  SET OPTIONS (description = "Probability of closing, 0 to 100, as set in D-Tools.");
ALTER TABLE staging.stg_dtools__opportunities ALTER COLUMN owner_name
  SET OPTIONS (description = "D-Tools user who owns the opportunity.");
ALTER TABLE staging.stg_dtools__opportunities ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_dtools__opportunities ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_dtools__opportunities ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
