-- stg_vendor__securitycentral_statement — every line of Security Central's
-- monthly statements.
-- Grain: one row per line per statement.
-- Source: raw_vendor.securitycentral_statement_lines, parsed from the PDF
--   statement emailed on the 25th (pipelines/scstatement/,
--   docs/vendor-reports.md). A statement lands only if its lines reconcile
--   with its own printed totals.
CREATE OR REPLACE TABLE staging.stg_vendor__securitycentral_statement
OPTIONS (description = """
Security Central's monthly alarm-monitoring statement, one row per line: every account Livewire is billed for, with the account holder, street, Security Central account number, service and amount. Three sections: activation (accounts started since the last statement, prorated), disconnect (accounts ended, credited back, no account number printed) and recurring (next month's charge for every active account). Every statement since loading began is kept; is_latest_statement = TRUE gives the current roster. Each statement reconciled to its own printed totals before it was loaded.
The street has no city or ZIP; account_number matches Alarm.com's CS account (stg_alarmdotcom__customers.central_station_account) and Security Central's other reports.
""")
AS
WITH latest_load AS (
  SELECT *
  FROM raw_vendor.securitycentral_statement_lines
  QUALIFY ROW_NUMBER() OVER (PARTITION BY _source_id ORDER BY _loaded_at DESC) = 1
),
lines AS (
  SELECT
    _source_id                                                       AS line_key,
    SAFE.PARSE_DATE('%Y-%m-%d', JSON_VALUE(payload, '$.statement_date')) AS statement_date,
    JSON_VALUE(payload, '$.section')                                 AS section,
    JSON_VALUE(payload, '$.customer_name')                           AS customer_name,
    JSON_VALUE(payload, '$.street')                                  AS street,
    JSON_VALUE(payload, '$.account_number')                          AS printed_account_number,
    JSON_VALUE(payload, '$.service')                                 AS service,
    SAFE.PARSE_DATE('%Y-%m-%d', JSON_VALUE(payload, '$.period_start')) AS period_start,
    SAFE.PARSE_DATE('%Y-%m-%d', JSON_VALUE(payload, '$.period_end'))   AS period_end,
    ROUND(SAFE_CAST(JSON_VALUE(payload, '$.amount') AS NUMERIC), 2)  AS amount,
    JSON_VALUE(payload, '$.invoice_number')                          AS invoice_number,
    SAFE_CAST(JSON_VALUE(payload, '$.line') AS INT64)                AS statement_line,
    JSON_VALUE(payload, '$.file')                                    AS source_file,
    _loaded_at                                                       AS loaded_at
  FROM latest_load
)
SELECT
  line_key,
  statement_date,
  statement_date = MAX(statement_date) OVER () AS is_latest_statement,
  section,
  customer_name,
  street,
  -- A few lines (Open/Close Log) print no account number; the account's
  -- other lines on the same statement, same holder and street, carry it.
  COALESCE(printed_account_number,
           MAX(printed_account_number) OVER (
             PARTITION BY statement_date, section, customer_name, street)) AS account_number,
  service,
  period_start,
  period_end,
  amount,
  invoice_number,
  statement_line,
  source_file,
  loaded_at
FROM lines;
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN line_key
  SET OPTIONS (description = "Unique id of this line: the statement file and its line number.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN statement_date
  SET OPTIONS (description = "Date printed on the statement (the 25th of each month).");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN is_latest_statement
  SET OPTIONS (description = "TRUE for lines of the most recent statement loaded. Filter on it, with section = 'recurring', for the accounts Security Central currently bills.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN section
  SET OPTIONS (description = "activation (new since the last statement, prorated), disconnect (ended, credited) or recurring (next month's charge for an active account).");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN customer_name
  SET OPTIONS (description = "Account holder as Security Central prints it, upper case; a business or property may carry a location after a dash (e.g. 'EVAN SHERWOOD - PRO SHOP').");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN street
  SET OPTIONS (description = "Street address of the monitored property, as printed. No city or ZIP on the statement.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN account_number
  SET OPTIONS (description = "Security Central account number (e.g. A16511523). Equals Alarm.com's CS account prefix and number. NULL on disconnect lines, which print none.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN service
  SET OPTIONS (description = "What the line bills: Monitoring, a scheduled test (Weekly Test, Bi-Weekly Test, Test Monthly), Open/Close Log, or a package (Security Package with Cellular, Smart Home with Cellular).");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN period_start
  SET OPTIONS (description = "First day the line bills for.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN period_end
  SET OPTIONS (description = "Last day the line bills for. A period longer than a month (quarterly or half-year billing) charges for all of it at once.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN amount
  SET OPTIONS (description = "Amount charged for the period, USD. Negative on disconnects (credit). Not a monthly rate when the period is longer than a month.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN invoice_number
  SET OPTIONS (description = "Security Central invoice the line is on (one for activations, one for recurring charges); NULL on disconnects.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN statement_line
  SET OPTIONS (description = "Order of the line on the statement, from 1.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN source_file
  SET OPTIONS (description = "Name of the statement PDF in the Drive folder (e.g. 000312-20261025.pdf).");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN loaded_at
  SET OPTIONS (description = "When the statement was loaded into the warehouse (UTC).");
