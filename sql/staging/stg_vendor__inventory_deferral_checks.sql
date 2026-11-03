-- stg_vendor__inventory_deferral_checks — does each table on the inventory
-- deferral sheet add up to its own Total row?
-- Grain: one row per total row on a month's tab.
-- Source: raw_vendor.gsheet_inventory_checks (pipelines/gsheets/workbook.py).
CREATE OR REPLACE TABLE staging.stg_vendor__inventory_deferral_checks
OPTIONS (description = """
For each table on each month's tab of the inventory deferral sheet (see stg_vendor__inventory_deferrals), the sheet's own Total against the sum of the lines the warehouse read under it. Where ties is FALSE, the two differ by `difference` (lines minus sheet): usually a SUM formula that misses a row inserted above or below its range, or rows the controller left out of the total on purpose. The sheet's total is the amount that was booked; the lines show what it was made of.
""")
AS
WITH latest AS (
  SELECT *
  FROM raw_vendor.gsheet_inventory_checks
  QUALIFY JSON_VALUE(payload, '$.version') = FIRST_VALUE(JSON_VALUE(payload, '$.version')) OVER (
    PARTITION BY JSON_VALUE(payload, '$.file_id') ORDER BY _loaded_at DESC)
)
SELECT
  _source_id                                                       AS check_key,
  SAFE.PARSE_DATE('%Y-%m-%d', JSON_VALUE(payload, '$.tab_month'))  AS tab_month,
  JSON_VALUE(payload, '$.tab')                                     AS tab,
  JSON_VALUE(payload, '$.section')                                 AS section,
  JSON_VALUE(payload, '$.kind')                                    AS total_kind,
  SAFE_CAST(JSON_VALUE(payload, '$.lines') AS INT64)               AS lines,
  ROUND(SAFE_CAST(JSON_VALUE(payload, '$.sheet_total') AS NUMERIC), 2) AS sheet_total,
  ROUND(SAFE_CAST(JSON_VALUE(payload, '$.lines_total') AS NUMERIC), 2) AS lines_total,
  ROUND(SAFE_CAST(JSON_VALUE(payload, '$.difference') AS NUMERIC), 2)  AS difference,
  SAFE_CAST(JSON_VALUE(payload, '$.ok') AS BOOL)                   AS ties,
  SAFE_CAST(JSON_VALUE(payload, '$.row') AS INT64)                 AS sheet_row,
  _loaded_at                                                       AS loaded_at
FROM latest;
ALTER TABLE staging.stg_vendor__inventory_deferral_checks ALTER COLUMN check_key
  SET OPTIONS (description = "Unique id of this total: the sheet's version, tab and row.");
ALTER TABLE staging.stg_vendor__inventory_deferral_checks ALTER COLUMN tab_month
  SET OPTIONS (description = "Month the tab is for (first day of the month).");
ALTER TABLE staging.stg_vendor__inventory_deferral_checks ALTER COLUMN tab
  SET OPTIONS (description = "Name of the tab in the sheet, as typed.");
ALTER TABLE staging.stg_vendor__inventory_deferral_checks ALTER COLUMN section
  SET OPTIONS (description = "Table the total closes: NULL for the first, unlabeled table; MERCH, PARTS, GBRV otherwise. Same as stg_vendor__inventory_deferrals.section.");
ALTER TABLE staging.stg_vendor__inventory_deferral_checks ALTER COLUMN total_kind
  SET OPTIONS (description = "'section' when the total covers the table above it; 'tab' when it is a running total of every table on the tab.");
ALTER TABLE staging.stg_vendor__inventory_deferral_checks ALTER COLUMN lines
  SET OPTIONS (description = "Number of lines the total was compared with.");
ALTER TABLE staging.stg_vendor__inventory_deferral_checks ALTER COLUMN sheet_total
  SET OPTIONS (description = "The total as the sheet computes it, USD.");
ALTER TABLE staging.stg_vendor__inventory_deferral_checks ALTER COLUMN lines_total
  SET OPTIONS (description = "Sum of amount_to_defer over those lines, USD.");
ALTER TABLE staging.stg_vendor__inventory_deferral_checks ALTER COLUMN difference
  SET OPTIONS (description = "lines_total minus sheet_total, USD. Positive when the sheet's total leaves lines out.");
ALTER TABLE staging.stg_vendor__inventory_deferral_checks ALTER COLUMN ties
  SET OPTIONS (description = "TRUE when the lines add up to the sheet's total within a cent.");
ALTER TABLE staging.stg_vendor__inventory_deferral_checks ALTER COLUMN sheet_row
  SET OPTIONS (description = "Row of the total on the tab.");
ALTER TABLE staging.stg_vendor__inventory_deferral_checks ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this version of the sheet was loaded into the warehouse (UTC).");
