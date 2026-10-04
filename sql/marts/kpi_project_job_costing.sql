-- kpi_project_job_costing — sold versus actual, one row per D-Tools project.
-- Grain: one row per project_id.
--
-- Three sources, joined only on keys they share:
--   D-Tools proposal  what the job was sold for and expected to cost
--   D-Tools POs       what the equipment actually cost (by project_id)
--   Zoho CRM          hours sold and hours worked, on the deal whose
--                     estimate number equals the proposal's quote number
-- The quote number is the only key D-Tools and Zoho share, and it is typed
-- into the deal by hand: on 2026-10-03 only 550 of the 1,733 deals closed
-- since 2025 carried one, so most projects have no Zoho side yet.
-- zoho_link says why for each; never fill the gap by matching names.
CREATE OR REPLACE TABLE marts.kpi_project_job_costing
OPTIONS (description = """
Job costing, one row per D-Tools project: what the job was sold for and expected to cost (D-Tools proposal), what its equipment actually cost (D-Tools purchase orders), and hours sold versus hours worked (Zoho CRM).
The hours columns are filled only where zoho_link = 'linked'. A project reaches its Zoho deal through the deal's estimate number, which is typed in by hand and missing on most deals, so on 2026-10-03 only about a third of projects with a proposal linked. Unlinked projects still carry the D-Tools figures. Report the linked share alongside any hours total, and never treat a missing link as zero hours.
actual_equipment_cost counts purchase-order lines tagged to the project; stock pulled from the shelf is not in it. Amounts USD.
""")
AS
WITH projects AS (
  SELECT project_id, project_number, project_name, client_name, stage,
         is_archived, created_at, completed_at, loaded_at
  FROM staging.stg_dtools__v2_projects
),
proposals AS (
  SELECT project_id, quote_number, sold_price, sold_cost, sold_margin,
         sold_margin_pct, sold_product_cost, sold_labor_cost, loaded_at
  FROM staging.stg_dtools__v2_project_proposals
),
po AS (
  SELECT project_id,
         SUM(line_cost)                     AS actual_equipment_cost,
         COUNT(DISTINCT purchase_order_id)  AS purchase_orders
  FROM staging.stg_dtools__v2_po_lines
  WHERE project_id IS NOT NULL
  GROUP BY project_id
),
deals AS (
  SELECT deal_id, deal_name, estimate_number, fo_hours_sold, total_hours_sold
  FROM staging.stg_zoho__deals
  WHERE estimate_number IS NOT NULL
    AND COALESCE(is_test_record, FALSE) = FALSE
),
-- One estimate number may sit on several deals (re-quotes, duplicates).
-- Such a project is reported as ambiguous rather than given any one of them.
deal_per_estimate AS (
  SELECT estimate_number,
         COUNT(*)                AS deals,
         ANY_VALUE(deal_id)      AS deal_id,
         ANY_VALUE(deal_name)    AS deal_name,
         ANY_VALUE(fo_hours_sold)    AS fo_hours_sold,
         ANY_VALUE(total_hours_sold) AS total_hours_sold
  FROM deals
  GROUP BY estimate_number
),
hours AS (
  SELECT deal_id,
         SUM(IF(is_job_hours, man_hours, 0)) AS hours_worked,
         COUNTIF(is_job_hours)               AS job_visits
  FROM staging.stg_zoho__meetings
  WHERE deal_id IS NOT NULL
  GROUP BY deal_id
),
joined AS (
  SELECT
    p.project_id, p.project_number, p.project_name, p.client_name, p.stage,
    p.is_archived, p.created_at, p.completed_at,
    r.quote_number, r.sold_price, r.sold_cost, r.sold_margin, r.sold_margin_pct,
    r.sold_product_cost, r.sold_labor_cost,
    po.actual_equipment_cost, po.purchase_orders,
    CASE
      WHEN r.project_id IS NULL     THEN 'no proposal'
      WHEN r.quote_number IS NULL   THEN 'no quote number'
      WHEN d.estimate_number IS NULL THEN 'no deal with this estimate number'
      WHEN d.deals > 1              THEN 'several deals'
      ELSE 'linked'
    END AS zoho_link,
    d.deals,
    d.deal_id, d.deal_name, d.fo_hours_sold, d.total_hours_sold,
    h.hours_worked, h.job_visits,
    GREATEST(p.loaded_at, COALESCE(r.loaded_at, p.loaded_at)) AS loaded_at
  FROM projects p
  LEFT JOIN proposals r USING (project_id)
  LEFT JOIN po USING (project_id)
  LEFT JOIN deal_per_estimate d ON d.estimate_number = r.quote_number
  LEFT JOIN hours h ON h.deal_id = d.deal_id
)
SELECT
  project_id,
  project_number,
  project_name,
  client_name,
  stage,
  is_archived,
  created_at,
  completed_at,
  quote_number,
  sold_price,
  sold_cost,
  sold_margin,
  sold_margin_pct,
  sold_product_cost,
  sold_labor_cost,
  actual_equipment_cost,
  purchase_orders,
  actual_equipment_cost - sold_product_cost                   AS equipment_cost_over_sold,
  zoho_link,
  IF(zoho_link = 'linked', deal_id, NULL)                     AS zoho_deal_id,
  IF(zoho_link = 'linked', deal_name, NULL)                   AS zoho_deal_name,
  IF(zoho_link = 'linked', fo_hours_sold, NULL)               AS fo_hours_sold,
  IF(zoho_link = 'linked', total_hours_sold, NULL)            AS total_hours_sold,
  IF(zoho_link = 'linked', COALESCE(hours_worked, 0), NULL)   AS hours_worked,
  IF(zoho_link = 'linked', COALESCE(job_visits, 0), NULL)     AS job_visits,
  IF(zoho_link = 'linked', COALESCE(hours_worked, 0) - fo_hours_sold, NULL)
                                                              AS hours_over_sold,
  MAX(loaded_at) OVER ()                                      AS data_through,
  CURRENT_TIMESTAMP()                                         AS computed_at
FROM joined;

ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN project_id
  SET OPTIONS (description = "D-Tools project id; the key.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN project_number
  SET OPTIONS (description = "D-Tools project number.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN project_name
  SET OPTIONS (description = "Project name from D-Tools.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN client_name
  SET OPTIONS (description = "Client name as entered in D-Tools.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN stage
  SET OPTIONS (description = "Where the project is in D-Tools' project pipeline.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN is_archived
  SET OPTIONS (description = "TRUE when the project is archived in D-Tools.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN created_at
  SET OPTIONS (description = "When the project was created in D-Tools.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN completed_at
  SET OPTIONS (description = "When the project was completed in D-Tools; NULL while open.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN quote_number
  SET OPTIONS (description = "D-Tools quote number of the project's proposal; the key into Zoho, where it is a deal's estimate number.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN sold_price
  SET OPTIONS (description = "What the client was sold, from the D-Tools proposal, USD before tax.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN sold_cost
  SET OPTIONS (description = "Cost D-Tools estimated when the job was sold, products plus labor, USD.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN sold_margin
  SET OPTIONS (description = "sold_price minus sold_cost, USD: gross margin as sold.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN sold_margin_pct
  SET OPTIONS (description = "sold_margin as a percent of sold_price, one decimal.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN sold_product_cost
  SET OPTIONS (description = "Equipment cost estimated when sold, USD; compare actual_equipment_cost.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN sold_labor_cost
  SET OPTIONS (description = "Labor cost estimated when sold, USD.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN actual_equipment_cost
  SET OPTIONS (description = "Sum of D-Tools purchase-order lines tagged to this project, quantity times unit cost, USD. Excludes order tax and shipping and stock pulled from the shelf. NULL when no order is tagged to the project.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN purchase_orders
  SET OPTIONS (description = "Number of purchase orders with lines tagged to this project.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN equipment_cost_over_sold
  SET OPTIONS (description = "actual_equipment_cost minus sold_product_cost, USD. Positive means equipment cost more than estimated.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN zoho_link
  SET OPTIONS (description = "Whether the project reached its Zoho deal: linked; several deals (more than one deal carries the quote number, so none is used); no deal with this estimate number (usually not typed on the deal); no quote number; no proposal. Hours columns are filled only when linked.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN zoho_deal_id
  SET OPTIONS (description = "Zoho CRM deal id when linked; joins stg_zoho__deals.deal_id.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN zoho_deal_name
  SET OPTIONS (description = "Zoho CRM deal name when linked.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN fo_hours_sold
  SET OPTIONS (description = "FO Hours Sold on the linked Zoho deal: finish-out labor hours sold. NULL when not linked.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN total_hours_sold
  SET OPTIONS (description = "Total Hours Sold on the linked Zoho deal, every phase. NULL when not linked.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN hours_worked
  SET OPTIONS (description = "Hours worked on the linked deal: man-hours on its install and finish-out meetings marked Ready to Bill or Complete, as Zoho's Actual vs Billed Hours report counts them. 0 when linked with none logged; NULL when not linked.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN job_visits
  SET OPTIONS (description = "Number of meetings counted in hours_worked. NULL when not linked.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN hours_over_sold
  SET OPTIONS (description = "hours_worked minus fo_hours_sold. Positive means the job ran over the hours sold. NULL when not linked or no hours were sold.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN data_through
  SET OPTIONS (description = "Newest D-Tools load behind this table.");
ALTER TABLE marts.kpi_project_job_costing ALTER COLUMN computed_at
  SET OPTIONS (description = "When this table was built.");
