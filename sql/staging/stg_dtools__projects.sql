-- stg_dtools__projects — latest record per D-Tools Cloud project.
-- Grain: one row per project_id.
-- Source: raw_dtools.projects (append-only; payload = full API record).
-- Field paths are best-effort pending verification against live payloads;
-- an all-NULL column means a wrong path — a one-line COALESCE fix here.
CREATE OR REPLACE TABLE staging.stg_dtools__projects
OPTIONS (description = """
D-Tools projects, one row per project: the job as sold, with its quoted price.
THERE IS NO COST HERE. cost is NULL on every row — the endpoint these are ingested from returns no cost field of any name, confirmed by listing every key in the payload. So this table cannot answer what a job cost or what it earned, only what it was quoted at. D-Tools does hold cost natively, on a different endpoint that is not ingested yet.
kpi_project_margin joins this to QuickBooks invoices by client name for invoiced and collected figures. Amounts USD.
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
  -- RESOLVED, AND THE ANSWER IS THAT IT DOES NOT EXIST.
  -- The probe ran on 2026-09-16 and listed every key in the raw payload. The
  -- 16 fields GetProjects returns are clientId, clientName, clientNumber,
  -- completedDate, createdDate, id, isArchived, modifiedDate, name, number,
  -- price, priority, projectManager, stage, stageGroup and systemState.
  -- There is no opportunity reference under any spelling, so the earlier
  -- guesses ($.opportunityId and two variants) are gone rather than left
  -- looking hopeful: a COALESCE over three paths that cannot exist reads
  -- like an unfinished search instead of a settled question.
  --
  -- The projects -> quotes join this column existed for is therefore not
  -- buildable from these payloads at all. stg_dtools__quotes has no
  -- opportunity reference either, and a project carries nothing tying it to
  -- the opportunity it came from. Relating the two needs a key D-Tools does
  -- not return here.
  CAST(NULL AS STRING)                                       AS opportunity_id,
  SAFE_CAST(COALESCE(JSON_VALUE(payload, '$.price'),
                     JSON_VALUE(payload, '$.totalPrice'),
                     JSON_VALUE(payload, '$.contractPrice')) AS NUMERIC)  AS price,
  -- No cost on this payload, under any name. The probe that settled
  -- opportunity_id listed all 16 fields GetProjects returns and there is no
  -- cost among them; all 1,599 rows read NULL. Kept as a typed NULL rather
  -- than three candidate paths, for the reason the opportunity_id search was
  -- retired above: a COALESCE over paths that cannot exist reads like an
  -- unfinished search, and the next person re-runs it.
  CAST(NULL AS NUMERIC)                                      AS cost,
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
  SET OPTIONS (description = "ALWAYS NULL, settled rather than pending. D-Tools' GetProjects response carries no opportunity reference at all — verified 2026-09-16 by listing every key in the raw payload — so a project cannot be traced to the opportunity it came from, and cannot be joined to quotes, from this data. Treat a question about a project's quotes as unanswerable here and say so; an empty join means the key does not exist, never that the project has no quotes.");
ALTER TABLE staging.stg_dtools__projects ALTER COLUMN price
  SET OPTIONS (description = "Quoted sell price, USD.");
ALTER TABLE staging.stg_dtools__projects ALTER COLUMN cost
  SET OPTIONS (description = "ALWAYS NULL. The endpoint these projects are ingested from returns no cost field of any name, so there is nothing to populate this with — it is empty at the source, not miscomputed. Quoted margin is therefore NOT available: price minus cost is price minus NULL, which is NULL, and an empty result means the data is missing rather than the margin being zero. Say that rather than reporting a margin. D-Tools holds cost on a different endpoint that is not ingested yet.");
ALTER TABLE staging.stg_dtools__projects ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_dtools__projects ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_dtools__projects ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
