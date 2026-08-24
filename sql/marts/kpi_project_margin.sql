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
-- Columns:
--   project_id/project_name/client_name/status   from D-Tools
--   quoted_price/quoted_cost/quoted_margin/quoted_margin_pct
--   qbo_customer_id/qbo_matched                  name-match result
--   customer_project_count   projects sharing this QBO customer (NULL if unmatched)
--   invoiced_to_date/collected_to_date/ar_balance  QBO, customer-level
--   computed_at              build timestamp
CREATE OR REPLACE TABLE marts.kpi_project_margin AS
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
