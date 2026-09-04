-- described — every table and column an agent can read has a BigQuery
-- description. Run by 06-transform.sh after the build; any row returned is a
-- failure. Not a model: it creates nothing and lives outside sql/marts and
-- sql/staging so the transform never treats it as one.
--
-- Why it exists: hermes-mcp serves these descriptions to agents, and they
-- are the only thing telling Hermes what `finding` or `vendor_monthly_cost`
-- means. A table without them still builds green and answers wrong. Covers
-- marts and staging: a Tier 2b agent reads both. _-prefixed infra tables
-- (the canary) are exempt.
WITH tables AS (
  SELECT table_schema, table_name FROM marts.INFORMATION_SCHEMA.TABLES
  WHERE table_type = 'BASE TABLE'
  UNION ALL
  SELECT table_schema, table_name FROM staging.INFORMATION_SCHEMA.TABLES
  WHERE table_type = 'BASE TABLE'
),
described AS (
  SELECT table_schema, table_name FROM marts.INFORMATION_SCHEMA.TABLE_OPTIONS
  WHERE option_name = 'description'
  UNION ALL
  SELECT table_schema, table_name FROM staging.INFORMATION_SCHEMA.TABLE_OPTIONS
  WHERE option_name = 'description'
),
columns AS (
  SELECT table_schema, table_name, column_name, description
  FROM marts.INFORMATION_SCHEMA.COLUMN_FIELD_PATHS
  UNION ALL
  SELECT table_schema, table_name, column_name, description
  FROM staging.INFORMATION_SCHEMA.COLUMN_FIELD_PATHS
)
SELECT 'table' AS kind, CONCAT(t.table_schema, '.', t.table_name) AS name
FROM tables t
LEFT JOIN described d
  ON d.table_schema = t.table_schema AND d.table_name = t.table_name
WHERE t.table_name NOT LIKE '\\_%' AND d.table_name IS NULL
UNION ALL
SELECT 'column' AS kind,
       CONCAT(table_schema, '.', table_name, '.', column_name) AS name
FROM columns
WHERE table_name NOT LIKE '\\_%'
  AND (description IS NULL OR description = '')
ORDER BY kind, name;
