-- stg_qbd__sales_lines — every sales line from QuickBooks Desktop, 2003 to
-- March 2022, before Livewire moved to QuickBooks Online.
-- Grain: one row per line of the Sales by Customer Detail report.
-- Source: raw_vendor.qbd_sales_by_customer_detail, landed from the one-time
--   export in Drive (pipelines/qbd/ingest.py, docs/qbd-export.md), and
--   raw_vendor.qbd_files for which exports were cut off.
--
-- The export was run quarter by quarter (whole years for the early, smaller
-- ones), plus one all-dates file that QuickBooks cut off at its row cap. A
-- line could therefore arrive in more than one file. Each line is taken only
-- from the narrowest complete file covering its date, so nothing counts
-- twice, and a cut-off file never supplies a line a complete one has.
--
-- Rows land append-only; a re-uploaded file gets a new Drive id, so the
-- newest load of each file NAME is the one read.
CREATE OR REPLACE TABLE staging.stg_qbd__sales_lines
OPTIONS (description = """
Every sales line Livewire booked in QuickBooks Desktop, from 2003 until the move to QuickBooks Online in April 2022: one row per line of an invoice, sales receipt, credit memo or statement charge, with the customer, the job, the item sold, quantity, price and amount. This is the job history before 2022; for April 2022 onward use stg_qbo__invoice_lines.
customer_name matches stg_qbo__customers.display_name by name only (no shared id); about 2,200 of today's customers appear here.
Known gap: 2017 Q1 to 2019 Q2 is missing from the export, so those quarters are empty here and are not zero sales. Credit memos carry negative amounts. Lines total roughly 80-87% of QuickBooks Total Income in a year: income booked outside invoices (journal entries, deposits) is not a sales line.
""")
AS
WITH files AS (
  -- Each export's period, newest load per file name, complete exports only.
  SELECT
    JSON_VALUE(payload, '$.file')                                   AS file_name,
    JSON_VALUE(payload, '$.file_id')                                AS file_id,
    SAFE.PARSE_DATE('%Y-%m-%d', JSON_VALUE(payload, '$.period_start')) AS period_start,
    SAFE.PARSE_DATE('%Y-%m-%d', JSON_VALUE(payload, '$.period_end'))   AS period_end
  FROM raw_vendor.qbd_files
  WHERE JSON_VALUE(payload, '$.report') = 'sales-by-customer-detail'
    AND JSON_VALUE(payload, '$.truncated') = 'false'
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY JSON_VALUE(payload, '$.file') ORDER BY _loaded_at DESC
  ) = 1
),
lines AS (
  SELECT
    r._source_id                                                     AS line_key,
    f.file_id,
    f.file_name,
    f.period_start,
    f.period_end,
    SAFE.PARSE_DATE('%m/%d/%Y', JSON_VALUE(r.payload, '$.cells.Date')) AS line_date,
    JSON_VALUE(r.payload, '$.cells.Type')                            AS transaction_type,
    JSON_VALUE(r.payload, '$.cells.Num')                             AS transaction_number,
    JSON_VALUE(r.payload, '$.cells.Name')                            AS full_name,
    JSON_VALUE(r.payload, '$.cells.Item')                            AS item,
    JSON_VALUE(r.payload, '$.cells.Memo')                            AS memo,
    SAFE_CAST(REPLACE(JSON_VALUE(r.payload, '$.cells.Qty'), ',', '') AS NUMERIC) AS quantity,
    SAFE_CAST(REPLACE(REPLACE(JSON_VALUE(r.payload, '$.cells."Sales Price"'), ',', ''), '%', '') AS NUMERIC) AS unit_price,
    SAFE_CAST(REPLACE(JSON_VALUE(r.payload, '$.cells.Amount'), ',', '') AS NUMERIC) AS amount,
    r._loaded_at                                                     AS loaded_at
  FROM raw_vendor.qbd_sales_by_customer_detail AS r
  JOIN files AS f ON JSON_VALUE(r.payload, '$.file_id') = f.file_id
  WHERE JSON_VALUE(r.payload, '$.kind') = 'data'
),
narrowest AS (
  -- Keep a line only when no complete file with a shorter period also
  -- covers its date.
  SELECT
    l.*,
    TRIM(SPLIT(l.full_name, ':')[SAFE_OFFSET(0)])                          AS customer_name,
    NULLIF(TRIM(REGEXP_EXTRACT(l.full_name, r'^[^:]*:(.*)$')), '')         AS job_name,
    COALESCE(TRIM(REGEXP_EXTRACT(l.item, r'^(.*?)\s*\(')), TRIM(l.item))   AS item_code,
    l.file_name                                                            AS source_file
  FROM lines AS l
  WHERE l.line_date IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM files AS o
      WHERE o.file_id != l.file_id
        AND l.line_date BETWEEN o.period_start AND o.period_end
        AND DATE_DIFF(o.period_end, o.period_start, DAY)
          < DATE_DIFF(l.period_end, l.period_start, DAY)
    )
)
SELECT
  line_key,
  line_date,
  transaction_type,
  transaction_number,
  customer_name,
  job_name,
  full_name,
  item_code,
  item,
  memo,
  quantity,
  unit_price,
  amount,
  source_file,
  loaded_at
FROM narrowest;
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN line_key
  SET OPTIONS (description = "Unique id of this line: the Drive file it came from and its line number in that file.");
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN line_date
  SET OPTIONS (description = "Date of the transaction the line is on.");
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN transaction_type
  SET OPTIONS (description = "QuickBooks transaction type: Invoice, Sales Receipt, Credit Memo, Stmt Charge and the like.");
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN transaction_number
  SET OPTIONS (description = "Invoice or receipt number as printed; NULL for statement charges. Lines sharing a number and date are one transaction.");
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN customer_name
  SET OPTIONS (description = "Customer, the part of the QuickBooks name before the first colon. Matches stg_qbo__customers.display_name for customers who carried over.");
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN job_name
  SET OPTIONS (description = "Job (project or property) under the customer, the part after the first colon; NULL when the sale was booked to the customer itself.");
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN full_name
  SET OPTIONS (description = "Full QuickBooks customer:job name as exported.");
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN item_code
  SET OPTIONS (description = "QuickBooks item code, e.g. 07LABOR1MAN for standard hourly labor: the item with its description in parentheses removed.");
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN item
  SET OPTIONS (description = "Item as exported: code followed by its description in parentheses.");
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN memo
  SET OPTIONS (description = "Line description as written on the invoice; often the most specific text about the work done.");
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN quantity
  SET OPTIONS (description = "Quantity sold; hours for labor items.");
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN unit_price
  SET OPTIONS (description = "Price per unit, USD; for percentage items (sales tax) the percentage.");
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN amount
  SET OPTIONS (description = "Line amount, USD. Negative on credit memos and refunds.");
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN source_file
  SET OPTIONS (description = "Name of the exported report file this line came from.");
ALTER TABLE staging.stg_qbd__sales_lines ALTER COLUMN loaded_at
  SET OPTIONS (description = "When the export file was loaded into the warehouse (UTC). The history itself ends in March 2022.");
