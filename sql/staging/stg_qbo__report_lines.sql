-- stg_qbo__report_lines — QuickBooks' own Profit & Loss, Balance Sheet and
-- Cash Flow, one row per (report, row, month), from the newest pull.
-- Grain: one row per (report, row_seq, period_start).
-- Source: raw_qbo.report_lines, flattened by pipelines/qbo/reports.py.
--
-- Every run lands the whole three-year window again, because a closed month
-- can still change, so only the newest run per report is current. Older runs
-- stay in raw_qbo as the record of what the books said when. Measured on the
-- first run (2026-09-25 17:40 UTC) against QuickBooks' printed reports: every
-- section of every month added up, and August 2026 income ($334,179.49), net
-- income ($20,944.89) and year-to-date net income (-$226,154.77) matched the
-- accountant's updated August package to the dollar.
CREATE OR REPLACE TABLE staging.stg_qbo__report_lines
OPTIONS (description = """
QuickBooks' own Profit and Loss, Balance Sheet and Cash Flow reports, one row per report line per month, from the newest pull. These are the books as QuickBooks prints them, including journal entries, payroll, depreciation and accruals, which no transaction table here carries.
line_type 'account' is one account's figure; 'total' is a section total or a computed line such as Gross Profit or Net Income. Never add totals to accounts: sum line_type = 'account' within a section, or read the section's total row.
Profit and Loss and Cash Flow amounts are for the month. Balance Sheet amounts are the balance at period_end. Accrual basis. Amounts USD.
""")
AS
WITH newest AS (
  SELECT JSON_VALUE(payload, '$.report') AS report, MAX(_loaded_at) AS loaded_at
  FROM raw_qbo.report_lines
  GROUP BY report
)
SELECT
  JSON_VALUE(l.payload, '$.report')                                  AS report,
  JSON_VALUE(l.payload, '$.basis')                                   AS basis,
  SAFE_CAST(JSON_VALUE(l.payload, '$.period_start') AS DATE)         AS period_start,
  SAFE_CAST(JSON_VALUE(l.payload, '$.period_end') AS DATE)           AS period_end,
  SAFE_CAST(JSON_VALUE(l.payload, '$.row_seq') AS INT64)             AS row_seq,
  SAFE_CAST(JSON_VALUE(l.payload, '$.depth') AS INT64)               AS depth,
  JSON_VALUE(l.payload, '$.section_path')                            AS section_path,
  JSON_VALUE(l.payload, '$.group')                                   AS report_group,
  JSON_VALUE(l.payload, '$.label')                                   AS label,
  JSON_VALUE(l.payload, '$.account_id')                              AS account_id,
  JSON_VALUE(l.payload, '$.line_type')                               AS line_type,
  SAFE_CAST(JSON_VALUE(l.payload, '$.amount') AS NUMERIC)            AS amount,
  l._run_id                                                          AS run_id,
  l._loaded_at                                                       AS loaded_at
FROM raw_qbo.report_lines AS l
JOIN newest AS n
  ON JSON_VALUE(l.payload, '$.report') = n.report AND l._loaded_at = n.loaded_at;

ALTER TABLE staging.stg_qbo__report_lines ALTER COLUMN report
  SET OPTIONS (description = "Which QuickBooks report: ProfitAndLoss, BalanceSheet or CashFlow.");
ALTER TABLE staging.stg_qbo__report_lines ALTER COLUMN basis
  SET OPTIONS (description = "Accounting basis the report was run on; Accrual, as the accountant's package is.");
ALTER TABLE staging.stg_qbo__report_lines ALTER COLUMN period_start
  SET OPTIONS (description = "First day of the month this figure covers.");
ALTER TABLE staging.stg_qbo__report_lines ALTER COLUMN period_end
  SET OPTIONS (description = "Last day of the month. A Balance Sheet figure is the balance on this date; the current month ends on the day of the pull.");
ALTER TABLE staging.stg_qbo__report_lines ALTER COLUMN row_seq
  SET OPTIONS (description = "Position of the line in the report, top to bottom. Order by it to print the report as QuickBooks does.");
ALTER TABLE staging.stg_qbo__report_lines ALTER COLUMN depth
  SET OPTIONS (description = "Nesting level: 0 for a top section such as Income or Assets, one deeper for each sub-section.");
ALTER TABLE staging.stg_qbo__report_lines ALTER COLUMN section_path
  SET OPTIONS (description = "The sections above the line, outermost first, joined with ' > ', e.g. 'Expenses > ADMINISTRATIVE EXPENSE > OCCUPANCY EXPENSE'.");
ALTER TABLE staging.stg_qbo__report_lines ALTER COLUMN report_group
  SET OPTIONS (description = "QuickBooks' own name for the top section the line sits in, e.g. Income, COGS, GrossProfit, Expenses, NetOperatingIncome, OtherIncome, NetIncome. Stable where labels are not: prefer it for picking a report total.");
ALTER TABLE staging.stg_qbo__report_lines ALTER COLUMN label
  SET OPTIONS (description = "The line as printed: an account name such as SALES M (Merchandise), or a total such as Total Income or Net Income.");
ALTER TABLE staging.stg_qbo__report_lines ALTER COLUMN account_id
  SET OPTIONS (description = "QuickBooks account id on account lines; joins to the chart of accounts. NULL on totals and computed lines.");
ALTER TABLE staging.stg_qbo__report_lines ALTER COLUMN line_type
  SET OPTIONS (description = "account for one account's own figure, total for a section total or computed line. Adding totals to accounts counts money twice.");
ALTER TABLE staging.stg_qbo__report_lines ALTER COLUMN amount
  SET OPTIONS (description = "USD. NULL where QuickBooks printed a blank, which is not the same as zero.");
ALTER TABLE staging.stg_qbo__report_lines ALTER COLUMN run_id
  SET OPTIONS (description = "The ingest run this pull came from; one per pull.");
ALTER TABLE staging.stg_qbo__report_lines ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this pull was loaded into the warehouse (UTC).");
