-- marts_described — every mart table and column has a BigQuery description.
-- Run by 06-transform.sh after the marts are built; any row returned is a
-- failure. Not a model: it creates nothing and lives outside sql/marts so
-- the transform never treats it as one.
--
-- Why it exists: hermes-mcp serves these descriptions to agents, and they
-- are the only thing telling Hermes what `finding` or `vendor_monthly_cost`
-- means. A mart without them still builds green and answers wrong.
-- _flywheel_canary (and any other _-prefixed infra table) is exempt.
SELECT 'table' AS kind, t.table_name AS name
FROM marts.INFORMATION_SCHEMA.TABLES t
LEFT JOIN marts.INFORMATION_SCHEMA.TABLE_OPTIONS o
  ON o.table_name = t.table_name AND o.option_name = 'description'
WHERE t.table_name NOT LIKE '\\_%'
  AND t.table_type = 'BASE TABLE'
  AND o.option_value IS NULL
UNION ALL
SELECT 'column' AS kind, CONCAT(table_name, '.', column_name) AS name
FROM marts.INFORMATION_SCHEMA.COLUMN_FIELD_PATHS
WHERE table_name NOT LIKE '\\_%'
  AND (description IS NULL OR description = '')
ORDER BY kind, name;
