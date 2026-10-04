-- stg_dtools__v2_project_proposals — latest proposal per D-Tools project.
-- Grain: one row per project_id.
-- Source: raw_dtools.v2_project_proposals (append-only). Each row is the
-- project's proposal data (cost and price) landed with its proposal info
-- (quote number) by pipelines/dtools/v2.py; see that file.
--
-- Paths verified 2026-10-03 against the first full load: summary.cost and
-- summary.price are filled on every proposal; the quote number sits under
-- proposal_info.dataTags (proposal_info.quoteNumber is empty), and is the
-- same five-digit number Zoho CRM deals carry as QB_Estimate_Num.
CREATE OR REPLACE TABLE staging.stg_dtools__v2_project_proposals
OPTIONS (description = """
D-Tools proposals, one row per project: what the job was sold for and what D-Tools expects it to cost, split into product and labor, plus the quote number.
These are sold (estimated) figures, not actuals: actual equipment cost is in stg_dtools__v2_po_lines and actual hours worked in stg_zoho__meetings. quote_number is the only key D-Tools shares with Zoho CRM, as a deal's estimate_number. Amounts USD, before tax.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_dtools.v2_project_proposals
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
),
fields AS (
  SELECT
    _source_id                                                                  AS project_id,
    NULLIF(TRIM(COALESCE(JSON_VALUE(payload, '$.proposal_info.quoteNumber'),
                         JSON_VALUE(payload, '$.proposal_info.dataTags.quoteNumber'))), '')
                                                                                AS quote_number,
    JSON_VALUE(payload, '$.proposal_info.quoteStateName')                       AS quote_state,
    SAFE_CAST(JSON_VALUE(payload, '$.proposal.summary.price') AS NUMERIC)       AS sold_price,
    SAFE_CAST(JSON_VALUE(payload, '$.proposal.summary.cost') AS NUMERIC)        AS sold_cost,
    SAFE_CAST(JSON_VALUE(payload, '$.proposal.summary.productPrice') AS NUMERIC) AS sold_product_price,
    SAFE_CAST(JSON_VALUE(payload, '$.proposal.summary.productCost') AS NUMERIC) AS sold_product_cost,
    SAFE_CAST(JSON_VALUE(payload, '$.proposal.summary.laborPrice') AS NUMERIC)  AS sold_labor_price,
    SAFE_CAST(JSON_VALUE(payload, '$.proposal.summary.laborCost') AS NUMERIC)   AS sold_labor_cost,
    SAFE_CAST(JSON_VALUE(payload, '$.project_modified_date') AS TIMESTAMP)      AS project_modified_at,
    _loaded_at                                                                  AS loaded_at
  FROM latest
)
SELECT
  project_id,
  quote_number,
  quote_state,
  sold_price,
  sold_cost,
  sold_price - sold_cost                                      AS sold_margin,
  ROUND(SAFE_DIVIDE(sold_price - sold_cost, sold_price) * 100, 1) AS sold_margin_pct,
  sold_product_price,
  sold_product_cost,
  sold_labor_price,
  sold_labor_cost,
  project_modified_at,
  loaded_at
FROM fields;

ALTER TABLE staging.stg_dtools__v2_project_proposals ALTER COLUMN project_id
  SET OPTIONS (description = "D-Tools project id; the key. Joins stg_dtools__v2_projects.project_id.");
ALTER TABLE staging.stg_dtools__v2_project_proposals ALTER COLUMN quote_number
  SET OPTIONS (description = "D-Tools quote number of the project's proposal. Equals a Zoho deal's estimate_number when someone entered it there; the only link between the two systems.");
ALTER TABLE staging.stg_dtools__v2_project_proposals ALTER COLUMN quote_state
  SET OPTIONS (description = "State of the quote in D-Tools, e.g. Accepted.");
ALTER TABLE staging.stg_dtools__v2_project_proposals ALTER COLUMN sold_price
  SET OPTIONS (description = "Proposal total the client was sold, USD, before tax.");
ALTER TABLE staging.stg_dtools__v2_project_proposals ALTER COLUMN sold_cost
  SET OPTIONS (description = "Cost D-Tools estimates for the proposal, products plus labor, USD.");
ALTER TABLE staging.stg_dtools__v2_project_proposals ALTER COLUMN sold_margin
  SET OPTIONS (description = "sold_price minus sold_cost, USD: the gross margin as sold.");
ALTER TABLE staging.stg_dtools__v2_project_proposals ALTER COLUMN sold_margin_pct
  SET OPTIONS (description = "sold_margin as a percent of sold_price, one decimal.");
ALTER TABLE staging.stg_dtools__v2_project_proposals ALTER COLUMN sold_product_price
  SET OPTIONS (description = "Equipment portion of sold_price, USD.");
ALTER TABLE staging.stg_dtools__v2_project_proposals ALTER COLUMN sold_product_cost
  SET OPTIONS (description = "Equipment portion of sold_cost, USD.");
ALTER TABLE staging.stg_dtools__v2_project_proposals ALTER COLUMN sold_labor_price
  SET OPTIONS (description = "Labor portion of sold_price, USD.");
ALTER TABLE staging.stg_dtools__v2_project_proposals ALTER COLUMN sold_labor_cost
  SET OPTIONS (description = "Labor portion of sold_cost, USD.");
ALTER TABLE staging.stg_dtools__v2_project_proposals ALTER COLUMN project_modified_at
  SET OPTIONS (description = "The project's modified time when this proposal was read.");
ALTER TABLE staging.stg_dtools__v2_project_proposals ALTER COLUMN loaded_at
  SET OPTIONS (description = "When the warehouse loaded this version of the record.");
