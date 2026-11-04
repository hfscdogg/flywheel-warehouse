-- stg_zohodesk__departments — latest record per Zoho Desk department.
-- Grain: one row per department id.
-- Source: raw_zohodesk.departments (append-only full snapshot each run; no
-- modified stamp, so the newest load wins).
--
-- Field paths from the Desk API docs, verified on the first live run.
CREATE OR REPLACE TABLE staging.stg_zohodesk__departments
OPTIONS (description = """
Zoho Desk departments, one row per department: the name behind a ticket's department_id (Sales, Service and so on). Join from stg_zohodesk__tickets.department_id.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_zohodesk.departments
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                 AS department_id,
  JSON_VALUE(payload, '$.name')                              AS department_name,
  SAFE_CAST(JSON_VALUE(payload, '$.isEnabled') AS BOOL)      AS is_enabled,
  SAFE_CAST(JSON_VALUE(payload, '$.isDefault') AS BOOL)      AS is_default,
  _loaded_at                                                 AS loaded_at
FROM latest;

ALTER TABLE staging.stg_zohodesk__departments ALTER COLUMN department_id
  SET OPTIONS (description = "Zoho Desk department id; the key.");
ALTER TABLE staging.stg_zohodesk__departments ALTER COLUMN department_name
  SET OPTIONS (description = "Department name as shown in Desk.");
ALTER TABLE staging.stg_zohodesk__departments ALTER COLUMN is_enabled
  SET OPTIONS (description = "TRUE while the department is active in Desk.");
ALTER TABLE staging.stg_zohodesk__departments ALTER COLUMN is_default
  SET OPTIONS (description = "TRUE for the portal's default department.");
ALTER TABLE staging.stg_zohodesk__departments ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
