-- stg_vendor__inventory_deferrals — the month-end inventory deferral sheet.
-- Grain: one row per job listed on a month's tab (per table on the tab).
-- Source: raw_vendor.gsheet_inventory_lines, from the "Inventory Adjustments
--   Monthly" Google Sheet (pipelines/gsheets/, docs/gsheets.md).
--
-- The sheet is re-landed whole each time it changes; only the newest version
-- is read, so a line deleted from the sheet leaves this table too.
CREATE OR REPLACE TABLE staging.stg_vendor__inventory_deferrals
OPTIONS (description = """
Livewire's month-end inventory deferral sheet ("Inventory Adjustments Monthly", kept by the controller since January 2018), one row per job on each month's tab. At each month end, equipment (merchandise and parts) already bought for a job that has not been fully billed is deferred out of that month's P&L; this is the list behind that adjusting entry, with the amount deferred per job and notes on when it will bill (PB = progress billing).
A month's tabs: the first table is unlabeled (section NULL); later tabs split it into MERCH, PARTS and occasionally GBRV. Some months have a revised tab; use is_superseded = FALSE for one answer per month. A job deferred over several months appears on every tab until billed, so do not sum amount_to_defer across months: sum within one tab_month.
Each table's own Total row is checked against these lines in stg_vendor__inventory_deferral_checks; where they differ, the sheet's total is what was booked.
""")
AS
WITH latest AS (
  SELECT *
  FROM raw_vendor.gsheet_inventory_lines
  QUALIFY JSON_VALUE(payload, '$.version') = FIRST_VALUE(JSON_VALUE(payload, '$.version')) OVER (
    PARTITION BY JSON_VALUE(payload, '$.file_id') ORDER BY _loaded_at DESC)
),
lines AS (
  SELECT
    _source_id                                                       AS line_key,
    SAFE.PARSE_DATE('%Y-%m-%d', JSON_VALUE(payload, '$.tab_month'))  AS tab_month,
    JSON_VALUE(payload, '$.tab')                                     AS tab,
    SAFE_CAST(JSON_VALUE(payload, '$.revised') AS BOOL)              AS is_revised,
    JSON_VALUE(payload, '$.section')                                 AS section,
    SAFE.PARSE_DATE('%Y-%m-%d', JSON_VALUE(payload, '$.original_month')) AS original_month,
    JSON_VALUE(payload, '$.original_month_text')                     AS original_month_text,
    JSON_VALUE(payload, '$.customer')                                AS customer_name,
    JSON_VALUE(payload, '$.project')                                 AS project_name,
    REGEXP_REPLACE(JSON_VALUE(payload, '$.estimate'), r'\.0$', '')   AS estimate_number,
    SAFE_CAST(JSON_VALUE(payload, '$.total') AS NUMERIC)             AS job_amount,
    SAFE_CAST(JSON_VALUE(payload, '$.percent') AS FLOAT64)           AS share_deferred,
    ROUND(SAFE_CAST(JSON_VALUE(payload, '$.amount_to_defer') AS NUMERIC), 2) AS amount_to_defer,
    JSON_VALUE(payload, '$.invoice_month')                           AS billing_note,
    TO_JSON_STRING(JSON_QUERY(payload, '$.notes'))                   AS other_notes,
    SAFE_CAST(JSON_VALUE(payload, '$.row') AS INT64)                 AS sheet_row,
    _loaded_at                                                       AS loaded_at
  FROM latest
)
SELECT
  line_key,
  tab_month,
  tab,
  is_revised,
  -- A month with a revised tab: the original is superseded by it.
  NOT is_revised AND COUNTIF(is_revised) OVER (PARTITION BY tab_month) > 0 AS is_superseded,
  section,
  original_month,
  original_month_text,
  customer_name,
  project_name,
  estimate_number,
  job_amount,
  share_deferred,
  amount_to_defer,
  billing_note,
  NULLIF(other_notes, 'null') AS other_notes,
  sheet_row,
  loaded_at
FROM lines;
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN line_key
  SET OPTIONS (description = "Unique id of this line: the sheet's version, tab and row.");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN tab_month
  SET OPTIONS (description = "Month end the deferral was booked for (first day of the month), read from the tab's name.");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN tab
  SET OPTIONS (description = "Name of the tab in the sheet, as typed (e.g. 'Sept 2022', 'Revised April 2024').");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN is_revised
  SET OPTIONS (description = "TRUE when the tab is a revised version of the month ('Revised' in its name).");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN is_superseded
  SET OPTIONS (description = "TRUE when the same month also has a revised tab, so this one was replaced. Filter is_superseded = FALSE for one version per month.");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN section
  SET OPTIONS (description = "Table on the tab: NULL for the first, unlabeled table; MERCH (merchandise), PARTS, GBRV or another label typed above a later table.");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN original_month
  SET OPTIONS (description = "Month the equipment was bought or the job started, first of the month. A month written without a year is placed in the latest such month not after tab_month. NULL when the cell held something else.");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN original_month_text
  SET OPTIONS (description = "The Original Month cell as stored in the sheet (a month name, or a date serial for cells typed as dates).");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN customer_name
  SET OPTIONS (description = "Customer as typed on the sheet. Usually matches stg_qbo__customers.display_name, but it is hand-typed, so spellings vary.");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN project_name
  SET OPTIONS (description = "Project or job name as typed on the sheet.");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN estimate_number
  SET OPTIONS (description = "Estimate or proposal number the job was sold on, when given.");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN job_amount
  SET OPTIONS (description = "Amount of the equipment line before the deferral share is applied, USD. Only on tabs with Total and % columns (2026 onward and a few earlier tables); NULL elsewhere.");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN share_deferred
  SET OPTIONS (description = "Share of job_amount deferred, as a fraction (0.37 = 37%): the part not yet billed. NULL where the sheet gives only the amount.");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN amount_to_defer
  SET OPTIONS (description = "Amount deferred out of tab_month's P&L for this line, USD. Sum within one tab_month and section; NULL where the cell was left empty.");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN billing_note
  SET OPTIONS (description = "The Invoice Month cell: when or how the job will bill, free text (e.g. 'Feb', 'PB to 90% in August', 'final billed in Oct').");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN other_notes
  SET OPTIONS (description = "Any other cells on the row, as JSON keyed by their column header (e.g. Operations Notes, Notes, Additional PB); NULL when none.");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN sheet_row
  SET OPTIONS (description = "Row number on the tab, to find the line in the sheet.");
ALTER TABLE staging.stg_vendor__inventory_deferrals ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this version of the sheet was loaded into the warehouse (UTC).");
