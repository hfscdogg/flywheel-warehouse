-- stg_zohodesk__agents — latest record per Zoho Desk agent.
-- Grain: one row per agent id.
-- Source: raw_zohodesk.agents (append-only full snapshot each run; no
-- modified stamp, so the newest load wins).
--
-- Field paths from the Desk API docs, verified on the first live run.
CREATE OR REPLACE TABLE staging.stg_zohodesk__agents
OPTIONS (description = """
Zoho Desk agents, one row per agent: the person behind a ticket's assignee_id. Join from stg_zohodesk__tickets.assignee_id to count tickets or consults by rep.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_zohodesk.agents
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                 AS agent_id,
  JSON_VALUE(payload, '$.firstName')                         AS first_name,
  JSON_VALUE(payload, '$.lastName')                          AS last_name,
  LOWER(JSON_VALUE(payload, '$.emailId'))                    AS email,
  JSON_VALUE(payload, '$.status')                            AS status,
  JSON_VALUE(payload, '$.roleId')                            AS role_id,
  _loaded_at                                                 AS loaded_at
FROM latest;

ALTER TABLE staging.stg_zohodesk__agents ALTER COLUMN agent_id
  SET OPTIONS (description = "Zoho Desk agent id; the key.");
ALTER TABLE staging.stg_zohodesk__agents ALTER COLUMN first_name
  SET OPTIONS (description = "Agent first name.");
ALTER TABLE staging.stg_zohodesk__agents ALTER COLUMN last_name
  SET OPTIONS (description = "Agent last name.");
ALTER TABLE staging.stg_zohodesk__agents ALTER COLUMN email
  SET OPTIONS (description = "Agent login email, lower-cased; matches the Zoho CRM user email for the same person.");
ALTER TABLE staging.stg_zohodesk__agents ALTER COLUMN status
  SET OPTIONS (description = "ACTIVE or DISABLED in Desk.");
ALTER TABLE staging.stg_zohodesk__agents ALTER COLUMN role_id
  SET OPTIONS (description = "Desk role id (agent, supervisor, administrator).");
ALTER TABLE staging.stg_zohodesk__agents ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
