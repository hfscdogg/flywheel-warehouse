-- stg_dtools__projects — latest record per D-Tools Cloud project.
-- Grain: one row per project_id.
-- Source: raw_dtools.projects (append-only; payload = full API record).
-- Field paths are best-effort pending verification against live payloads;
-- an all-NULL column means a wrong path — a one-line COALESCE fix here.
CREATE OR REPLACE TABLE staging.stg_dtools__projects
OPTIONS (description = """
D-Tools projects, one row per project: the job as sold, with quoted price and cost. kpi_project_margin joins this to QuickBooks invoices by client name for invoiced and collected figures. Amounts USD.
""")
AS
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
  -- VERIFIED AGAINST A LIVE PAYLOAD, 2026-09-16. GetProjects returns no
  -- `status` field at all, so both paths below it missed and this column was
  -- NULL on all 1,599 rows since the model was written. The payload carries
  -- three fields instead, and they are three different things, not three
  -- spellings of one -- `stage` is the finest (where the job is in the
  -- pipeline) and is what `status` has always meant to kpi_project_margin,
  -- so it wins. `stageGroup` is the coarser bucket that stage rolls up into
  -- and only answers where stage is absent; `systemState` is D-Tools' own
  -- workflow state and is the last resort. Read the value together with
  -- whichever field supplied it if that distinction ever matters -- today it
  -- does not, because stage is populated.
  COALESCE(JSON_VALUE(payload, '$.stage.name'),
           JSON_VALUE(payload, '$.stage'),
           JSON_VALUE(payload, '$.stageGroup.name'),
           JSON_VALUE(payload, '$.stageGroup'),
           JSON_VALUE(payload, '$.systemState.name'),
           JSON_VALUE(payload, '$.systemState'))             AS status,
  -- STILL UNRESOLVED, AND SAY SO RATHER THAN LOOK FIXED.
  -- `$.opportunityId` was verified absent from the GetProjects payload on
  -- 2026-09-16, which is why this has been NULL on all 1,599 rows and why the
  -- projects -> quotes join has never returned a thing. The candidates below
  -- are the shapes D-Tools uses elsewhere, NOT a verified path: if this is
  -- still NULL after a build, the field is named something else again and the
  -- probe has to be run against a live payload to find it.
  -- NOTE THE OTHER HALF OF THAT JOIN IS ALSO BROKEN: stg_dtools__quotes reads
  -- the same '$.opportunityId' and is NULL on all 3,165 of its rows, so
  -- fixing this column alone does not make the join work. Fix both, from one
  -- probe, or neither.
  COALESCE(JSON_VALUE(payload, '$.opportunityId'),
           JSON_VALUE(payload, '$.opportunity.id'),
           JSON_VALUE(payload, '$.opportunityID'))           AS opportunity_id,
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

ALTER TABLE staging.stg_dtools__projects ALTER COLUMN project_id
  SET OPTIONS (description = "D-Tools project id; the key.");
ALTER TABLE staging.stg_dtools__projects ALTER COLUMN name
  SET OPTIONS (description = "Project name.");
ALTER TABLE staging.stg_dtools__projects ALTER COLUMN client_name
  SET OPTIONS (description = "Client name as entered in D-Tools. The only link to QuickBooks is this name, matched to customer display name.");
ALTER TABLE staging.stg_dtools__projects ALTER COLUMN status
  SET OPTIONS (description = "Where the project sits in the D-Tools pipeline. Taken from the payload's stage, falling back to the coarser stageGroup and then to D-Tools' own systemState — three different things, so a value here is the finest of them that was present. Was NULL on every row until 2026-09-16: the model looked for a status field the GetProjects response does not return.");
ALTER TABLE staging.stg_dtools__projects ALTER COLUMN opportunity_id
  SET OPTIONS (description = "The opportunity this project came from. STILL UNVERIFIED and may be NULL on every row: the field name in the GetProjects payload is not known, and the previous guess was confirmed absent on 2026-09-16. The quotes model carries the same unresolved field, so treat a projects-to-quotes join as unavailable until both are populated — an empty join result means the key is missing, not that no quotes exist.");
ALTER TABLE staging.stg_dtools__projects ALTER COLUMN price
  SET OPTIONS (description = "Quoted sell price, USD.");
ALTER TABLE staging.stg_dtools__projects ALTER COLUMN cost
  SET OPTIONS (description = "Quoted cost, USD. price minus cost is the quoted margin.");
ALTER TABLE staging.stg_dtools__projects ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_dtools__projects ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_dtools__projects ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
