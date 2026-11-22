-- stg_dtools__v2_change_orders — one row per change order on a D-Tools
-- project, from the latest landed copy of each project's billing.
-- Grain: one row per change_order_id.
-- Source: raw_dtools.v2_project_billing (append-only; payload = one project's
-- invoices and change_orders arrays, wrapped with project_id).
CREATE OR REPLACE TABLE staging.stg_dtools__v2_change_orders
OPTIONS (description = """
D-Tools change orders, one row per change order on a project: its number, name, approval state and price. Price can be negative (a credit).
Whether a change order was invoiced is on stg_dtools__v2_invoices (has_change_order). Amounts USD.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_dtools.v2_project_billing
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _loaded_at DESC
  ) = 1
)
SELECT
  JSON_VALUE(c, '$.id')                                          AS change_order_id,
  _source_id                                                     AS project_id,
  SAFE_CAST(JSON_VALUE(c, '$.number') AS INT64)                  AS change_order_number,
  JSON_VALUE(c, '$.name')                                        AS change_order_name,
  JSON_VALUE(c, '$.state')                                       AS state,
  JSON_VALUE(c, '$.type')                                        AS change_order_type,
  ROUND(SAFE_CAST(JSON_VALUE(c, '$.price') AS NUMERIC), 2)       AS price,
  SAFE_CAST(JSON_VALUE(c, '$.createdDate') AS TIMESTAMP)         AS created_at,
  SAFE_CAST(JSON_VALUE(c, '$.modifiedDate') AS TIMESTAMP)        AS modified_at,
  _loaded_at                                                     AS loaded_at
FROM latest,
     UNNEST(JSON_QUERY_ARRAY(payload, '$.change_orders')) AS c
WHERE JSON_VALUE(c, '$.id') IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY JSON_VALUE(c, '$.id') ORDER BY _loaded_at DESC) = 1;

ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN change_order_id
  SET OPTIONS (description = "D-Tools change order id; the key.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN project_id
  SET OPTIONS (description = "D-Tools project the change order belongs to; joins stg_dtools__v2_projects.project_id.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN change_order_number
  SET OPTIONS (description = "Change order number within its project, from 1.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN change_order_name
  SET OPTIONS (description = "Change order name as entered in D-Tools.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN state
  SET OPTIONS (description = "Approval state in D-Tools, e.g. Approved.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN change_order_type
  SET OPTIONS (description = "Change order type in D-Tools, e.g. Internal.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN price
  SET OPTIONS (description = "Price change the order makes to the project, USD; negative for a credit.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN created_at
  SET OPTIONS (description = "When the change order was created in D-Tools.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN modified_at
  SET OPTIONS (description = "Last modified time in D-Tools.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN loaded_at
  SET OPTIONS (description = "When the warehouse loaded this version of the project's billing.");
