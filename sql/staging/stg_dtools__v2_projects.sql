-- stg_dtools__v2_projects — latest record per D-Tools Cloud project, from
-- the v2 API (pipelines/dtools/v2.py).
-- Grain: one row per project_id.
-- Source: raw_dtools.v2_projects (append-only; payload = the project list row).
CREATE OR REPLACE TABLE staging.stg_dtools__v2_projects
OPTIONS (description = """
D-Tools projects, one row per project, from the D-Tools v2 API: number, name, client, stage and dates. Cost and margin are in stg_dtools__v2_project_proposals; kpi_project_job_costing puts the two together.
Includes archived projects (is_archived). Amounts USD.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_dtools.v2_projects
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                     AS project_id,
  JSON_VALUE(payload, '$.number')                                AS project_number,
  JSON_VALUE(payload, '$.name')                                  AS project_name,
  JSON_VALUE(payload, '$.clientName')                            AS client_name,
  -- Same order as stg_dtools__projects: stage is the finest, stageGroup the
  -- bucket it rolls up into. Either may arrive as a string or an object.
  COALESCE(JSON_VALUE(payload, '$.stage.name'),
           JSON_VALUE(payload, '$.stage'),
           JSON_VALUE(payload, '$.stageGroup.name'),
           JSON_VALUE(payload, '$.stageGroup'))                  AS stage,
  SAFE_CAST(JSON_VALUE(payload, '$.price') AS NUMERIC)           AS list_price,
  SAFE_CAST(JSON_VALUE(payload, '$.isArchived') AS BOOL)         AS is_archived,
  SAFE_CAST(JSON_VALUE(payload, '$.createdDate') AS TIMESTAMP)   AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.completedDate') AS TIMESTAMP) AS completed_at,
  SAFE_CAST(JSON_VALUE(payload, '$.modifiedDate') AS TIMESTAMP)  AS modified_at,
  _loaded_at                                                     AS loaded_at
FROM latest;

ALTER TABLE staging.stg_dtools__v2_projects ALTER COLUMN project_id
  SET OPTIONS (description = "D-Tools project id; the key. Joins stg_dtools__v2_project_proposals.project_id.");
ALTER TABLE staging.stg_dtools__v2_projects ALTER COLUMN project_number
  SET OPTIONS (description = "D-Tools project number as shown in D-Tools.");
ALTER TABLE staging.stg_dtools__v2_projects ALTER COLUMN project_name
  SET OPTIONS (description = "Project name.");
ALTER TABLE staging.stg_dtools__v2_projects ALTER COLUMN client_name
  SET OPTIONS (description = "Client name as entered in D-Tools.");
ALTER TABLE staging.stg_dtools__v2_projects ALTER COLUMN stage
  SET OPTIONS (description = "Where the project is in D-Tools' project pipeline.");
ALTER TABLE staging.stg_dtools__v2_projects ALTER COLUMN list_price
  SET OPTIONS (description = "Price on the project list row, USD. Prefer sold_price from stg_dtools__v2_project_proposals, which is the proposal's own total.");
ALTER TABLE staging.stg_dtools__v2_projects ALTER COLUMN is_archived
  SET OPTIONS (description = "TRUE when the project is archived in D-Tools.");
ALTER TABLE staging.stg_dtools__v2_projects ALTER COLUMN created_at
  SET OPTIONS (description = "When the project was created in D-Tools.");
ALTER TABLE staging.stg_dtools__v2_projects ALTER COLUMN completed_at
  SET OPTIONS (description = "When the project was completed in D-Tools; NULL while open.");
ALTER TABLE staging.stg_dtools__v2_projects ALTER COLUMN modified_at
  SET OPTIONS (description = "Last modified time in D-Tools.");
ALTER TABLE staging.stg_dtools__v2_projects ALTER COLUMN loaded_at
  SET OPTIONS (description = "When the warehouse loaded this version of the record.");
