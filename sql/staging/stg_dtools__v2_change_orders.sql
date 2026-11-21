-- stg_dtools__v2_change_orders — change orders on D-Tools projects.
-- Grain: one row per change_order_id.
-- Source: raw_dtools.v2_project_billing (append-only; payload = one project's
-- invoices and change orders as pipelines/dtools/v2.py landed them). Newest
-- record per project by load, as in stg_dtools__v2_invoices.
--
-- Paths verified 2026-11-21 against the first full load (1,274 change orders
-- on 743 projects; price filled on every one). The list carries no accepted
-- date and no cost, only the price. number is unique per project and type,
-- not per project: 104 projects have an Internal and an External change
-- order with the same number. All 102 invoices that bill a change order
-- match an External one on number and name, none an Internal one.
CREATE OR REPLACE TABLE staging.stg_dtools__v2_change_orders
OPTIONS (description = """
Change orders on D-Tools projects, one row per change order: its number within the project, name, price and where it stands.
change_type separates Internal change orders (Livewire's own adjustments to a job, about four in five, never invoiced to the client) from External ones (presented to the client and invoiced). Count only External ones as added revenue, and only once system_state is Accepted, Approved or Accepted and Paid. Many prices are negative: scope taken out. Numbers restart per type, so a project can have an Internal 1 and an External 1. An invoice for a change order is in stg_dtools__v2_invoices and always bills an External one: match on project_id and change_order_number with change_type = 'External'. Amounts USD, before tax.
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
  JSON_VALUE(co, '$.id')                                           AS change_order_id,
  _source_id                                                       AS project_id,
  SAFE_CAST(JSON_VALUE(co, '$.number') AS INT64)                   AS change_order_number,
  JSON_VALUE(co, '$.name')                                         AS change_order_name,
  JSON_VALUE(co, '$.type')                                         AS change_type,
  JSON_VALUE(co, '$.state')                                        AS state,
  JSON_VALUE(co, '$.systemState')                                  AS system_state,
  ROUND(SAFE_CAST(JSON_VALUE(co, '$.price') AS NUMERIC), 2)        AS price,
  SAFE_CAST(JSON_VALUE(co, '$.createdDate') AS TIMESTAMP)          AS created_at,
  SAFE_CAST(JSON_VALUE(co, '$.modifiedDate') AS TIMESTAMP)         AS modified_at,
  _loaded_at                                                       AS loaded_at
FROM latest,
     UNNEST(JSON_QUERY_ARRAY(payload, '$.change_orders')) AS co;

ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN change_order_id
  SET OPTIONS (description = "D-Tools change order id; the key.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN project_id
  SET OPTIONS (description = "D-Tools project the change order belongs to; joins stg_dtools__v2_projects.project_id.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN change_order_number
  SET OPTIONS (description = "The change order's number within its project and change_type, from 1. Internal and External are numbered separately, so project_id and this alone do not identify a change order.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN change_order_name
  SET OPTIONS (description = "Name given to the change order in D-Tools.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN change_type
  SET OPTIONS (description = "Internal (Livewire's own adjustment to the job, never invoiced to the client) or External (presented to the client and invoiced).");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN state
  SET OPTIONS (description = "Livewire's own stage name for the change order, e.g. Design Development, Presented, Approved, Paid.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN system_state
  SET OPTIONS (description = "D-Tools' fixed state behind the stage name: Open, Presented, Accepted, Approved, Accepted and Paid, Declined or Approval Rejected. Filter on this, not on state.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN price
  SET OPTIONS (description = "Price of the change order, USD, before tax. Can be negative when scope is removed.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN created_at
  SET OPTIONS (description = "When the change order was created in D-Tools.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN modified_at
  SET OPTIONS (description = "Last modified time in D-Tools.");
ALTER TABLE staging.stg_dtools__v2_change_orders ALTER COLUMN loaded_at
  SET OPTIONS (description = "When the warehouse last read this change order's project from D-Tools.");
