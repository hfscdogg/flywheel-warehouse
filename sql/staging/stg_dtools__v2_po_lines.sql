-- stg_dtools__v2_po_lines — one row per product line on a D-Tools purchase
-- order, from the latest copy of each order.
-- Grain: one row per (purchase_order_id, line_number).
-- Source: raw_dtools.v2_purchase_orders (append-only; payload = the order's
-- detail, whose products array carries unitCost and the projectId each line
-- was bought for). Lines of a re-edited order are replaced, not added to.
CREATE OR REPLACE TABLE staging.stg_dtools__v2_po_lines
OPTIONS (description = """
D-Tools purchase order lines, one row per product on an order: what was actually bought for a job and what it cost. line_cost is quantity times unit_cost.
project_id is NULL on lines bought for stock rather than a job. Order-level tax and shipping are not spread over lines. Amounts USD.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_dtools.v2_purchase_orders
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
),
lines AS (
  SELECT
    _source_id                                                         AS purchase_order_id,
    JSON_VALUE(payload, '$.number')                                    AS po_number,
    COALESCE(JSON_VALUE(payload, '$.status.name'),
             JSON_VALUE(payload, '$.status'))                          AS po_status,
    SAFE_CAST(JSON_VALUE(payload, '$.orderedDate') AS TIMESTAMP)       AS ordered_at,
    off + 1                                                            AS line_number,
    NULLIF(JSON_VALUE(p, '$.projectId'), '')                           AS project_id,
    JSON_VALUE(p, '$.brand')                                           AS brand,
    JSON_VALUE(p, '$.model')                                           AS model,
    SAFE_CAST(JSON_VALUE(p, '$.quantity') AS NUMERIC)                  AS quantity,
    SAFE_CAST(JSON_VALUE(p, '$.receivedQuantity') AS NUMERIC)          AS received_quantity,
    SAFE_CAST(JSON_VALUE(p, '$.unitCost') AS NUMERIC)                  AS unit_cost,
    _loaded_at                                                         AS loaded_at
  FROM latest,
       UNNEST(JSON_QUERY_ARRAY(payload, '$.products')) AS p WITH OFFSET AS off
)
SELECT
  purchase_order_id,
  line_number,
  po_number,
  po_status,
  ordered_at,
  project_id,
  brand,
  model,
  quantity,
  received_quantity,
  unit_cost,
  ROUND(quantity * unit_cost, 2) AS line_cost,
  loaded_at
FROM lines;

ALTER TABLE staging.stg_dtools__v2_po_lines ALTER COLUMN purchase_order_id
  SET OPTIONS (description = "D-Tools purchase order id; with line_number, the key.");
ALTER TABLE staging.stg_dtools__v2_po_lines ALTER COLUMN line_number
  SET OPTIONS (description = "Position of the line on the order, from 1.");
ALTER TABLE staging.stg_dtools__v2_po_lines ALTER COLUMN po_number
  SET OPTIONS (description = "Purchase order number as shown in D-Tools.");
ALTER TABLE staging.stg_dtools__v2_po_lines ALTER COLUMN po_status
  SET OPTIONS (description = "Order status in D-Tools, e.g. Ordered or Received.");
ALTER TABLE staging.stg_dtools__v2_po_lines ALTER COLUMN ordered_at
  SET OPTIONS (description = "When the order was placed.");
ALTER TABLE staging.stg_dtools__v2_po_lines ALTER COLUMN project_id
  SET OPTIONS (description = "D-Tools project the line was bought for; joins stg_dtools__v2_projects.project_id. NULL for stock purchases.");
ALTER TABLE staging.stg_dtools__v2_po_lines ALTER COLUMN brand
  SET OPTIONS (description = "Product brand.");
ALTER TABLE staging.stg_dtools__v2_po_lines ALTER COLUMN model
  SET OPTIONS (description = "Product model.");
ALTER TABLE staging.stg_dtools__v2_po_lines ALTER COLUMN quantity
  SET OPTIONS (description = "Quantity ordered.");
ALTER TABLE staging.stg_dtools__v2_po_lines ALTER COLUMN received_quantity
  SET OPTIONS (description = "Quantity received so far.");
ALTER TABLE staging.stg_dtools__v2_po_lines ALTER COLUMN unit_cost
  SET OPTIONS (description = "Cost per unit paid to the supplier, USD.");
ALTER TABLE staging.stg_dtools__v2_po_lines ALTER COLUMN line_cost
  SET OPTIONS (description = "quantity times unit_cost, USD: the line's actual equipment cost.");
ALTER TABLE staging.stg_dtools__v2_po_lines ALTER COLUMN loaded_at
  SET OPTIONS (description = "When the warehouse loaded this version of the order.");
