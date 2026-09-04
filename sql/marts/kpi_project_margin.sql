-- kpi_project_margin — margin scoreboard, one row per D-Tools project.
-- Grain: one row per project_id.
--
-- Quoted figures come from the D-Tools project record. Invoiced/collected
-- figures come from QBO, matched on normalized client name ↔ customer
-- display name (the systems share no key). The match is customer-level:
-- when one QBO customer spans several projects (customer_project_count > 1),
-- invoiced/collected/ar are shared across those rows, not per-project.
-- qbo_matched = FALSE means no name match — the QBO columns are NULL, and a
-- rename on either side is the usual fix.
--
-- Column meanings are declared at the end of this file (ALTER COLUMN ...
-- SET OPTIONS). BigQuery serves them to agents through hermes-mcp, so that
-- is the one copy — do not restate them here.
CREATE OR REPLACE TABLE marts.kpi_project_margin
OPTIONS (description = """
Margin scoreboard, one row per D-Tools project. Quoted price, cost and margin are per project, from D-Tools.
The QuickBooks figures (invoiced, collected, AR) are matched on customer NAME and are CUSTOMER-level: when customer_project_count > 1 the same dollars appear on every project for that customer, so summing them across projects double-counts.
qbo_matched = FALSE means no QuickBooks customer matched by name and the QBO columns are NULL. Amounts USD.
""")
AS
WITH projects AS (
  SELECT *, NULLIF(LOWER(TRIM(client_name)), '') AS client_key
  FROM staging.stg_dtools__projects
),
customers AS (
  -- One customer per normalized name; duplicates keep the lowest id.
  SELECT customer_id,
         NULLIF(LOWER(TRIM(display_name)), '') AS client_key
  FROM staging.stg_qbo__customers
  WHERE display_name IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY LOWER(TRIM(display_name))
    ORDER BY SAFE_CAST(customer_id AS INT64), customer_id
  ) = 1
),
invoices AS (
  SELECT customer_id,
         SUM(COALESCE(total_amount, 0)) AS invoiced_to_date,
         SUM(COALESCE(balance, 0))      AS ar_balance
  FROM staging.stg_qbo__invoices
  GROUP BY customer_id
)
SELECT
  p.project_id,
  p.name        AS project_name,
  p.client_name,
  p.status,
  p.price       AS quoted_price,
  p.cost        AS quoted_cost,
  p.price - p.cost AS quoted_margin,
  ROUND(SAFE_DIVIDE(p.price - p.cost, p.price) * 100, 1) AS quoted_margin_pct,
  c.customer_id AS qbo_customer_id,
  c.customer_id IS NOT NULL AS qbo_matched,
  IF(c.customer_id IS NULL, NULL,
     COUNT(*) OVER (PARTITION BY c.customer_id)) AS customer_project_count,
  i.invoiced_to_date,
  i.invoiced_to_date - i.ar_balance AS collected_to_date,
  i.ar_balance,
  CURRENT_TIMESTAMP() AS computed_at
FROM projects p
LEFT JOIN customers c USING (client_key)
LEFT JOIN invoices i ON i.customer_id = c.customer_id;

-- What agents read. hermes-mcp serves these descriptions verbatim through
-- get_table_schema, and a column without one is a column Hermes will guess
-- at. 06-transform.sh fails the run if any mart column has no description.
-- Renaming a column above without updating it here fails here, loudly.
ALTER TABLE marts.kpi_project_margin ALTER COLUMN project_id
  SET OPTIONS (description = "D-Tools project id, the key.");
ALTER TABLE marts.kpi_project_margin ALTER COLUMN project_name
  SET OPTIONS (description = "Project name from D-Tools.");
ALTER TABLE marts.kpi_project_margin ALTER COLUMN client_name
  SET OPTIONS (description = "Client name as entered in D-Tools.");
ALTER TABLE marts.kpi_project_margin ALTER COLUMN status
  SET OPTIONS (description = "Project status from D-Tools.");
ALTER TABLE marts.kpi_project_margin ALTER COLUMN quoted_price
  SET OPTIONS (description = "Quoted sell price from D-Tools, USD.");
ALTER TABLE marts.kpi_project_margin ALTER COLUMN quoted_cost
  SET OPTIONS (description = "Quoted cost from D-Tools, USD.");
ALTER TABLE marts.kpi_project_margin ALTER COLUMN quoted_margin
  SET OPTIONS (description = "quoted_price minus quoted_cost, USD.");
ALTER TABLE marts.kpi_project_margin ALTER COLUMN quoted_margin_pct
  SET OPTIONS (description = "quoted_margin / quoted_price as a percentage 0 to 100. NULL when quoted_price is 0.");
ALTER TABLE marts.kpi_project_margin ALTER COLUMN qbo_customer_id
  SET OPTIONS (description = "QuickBooks customer matched to this project by name. NULL when no match.");
ALTER TABLE marts.kpi_project_margin ALTER COLUMN qbo_matched
  SET OPTIONS (description = "TRUE when a QuickBooks customer matched. FALSE means the QBO columns are NULL; a name differs between the two systems.");
ALTER TABLE marts.kpi_project_margin ALTER COLUMN customer_project_count
  SET OPTIONS (description = "How many D-Tools projects share this QuickBooks customer. When greater than 1, invoiced, collected and AR are shared across those projects and must not be summed per project. NULL when unmatched.");
ALTER TABLE marts.kpi_project_margin ALTER COLUMN invoiced_to_date
  SET OPTIONS (description = "Total invoiced to this QuickBooks CUSTOMER, USD. Customer-level, not per project.");
ALTER TABLE marts.kpi_project_margin ALTER COLUMN collected_to_date
  SET OPTIONS (description = "invoiced_to_date minus ar_balance, USD. Customer-level, not per project.");
ALTER TABLE marts.kpi_project_margin ALTER COLUMN ar_balance
  SET OPTIONS (description = "Open balance owed by this QuickBooks CUSTOMER, USD. Customer-level, not per project.");
ALTER TABLE marts.kpi_project_margin ALTER COLUMN computed_at
  SET OPTIONS (description = "When this row was built (UTC).");
