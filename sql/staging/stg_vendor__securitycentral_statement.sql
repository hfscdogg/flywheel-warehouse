-- stg_vendor__securitycentral_statement — what Security Central billed us,
-- per account, per line, from the monthly dealer statement.
-- Grain: one row per billed line (an account's Monitoring line plus any test
--   lines, plus the prorated activation and disconnect lines of the month),
--   so an account's cost is the SUM of its recurring rows.
-- Source: raw_vendor.securitycentral_statement (drop-bucket uploads of the
--   "Statement EMail" PDF Security Central Accounting sends on the 25th).
--
-- THE SAME PRICE AS THE RECURRING REPORT, ARRIVING ON ITS OWN
-- stg_vendor__securitycentral_recurring carries the same per-resource rate
-- from the Customer System Recurring report, which someone has to pull from
-- SCAN. The statement is emailed, so it is the feed that stays current.
-- kpi_subscription_audit prices an account from whichever of the two was
-- loaded more recently.
--
-- NOT ALREADY MONTHLY, UNLIKE THE RECURRING REPORT
-- The statement prints the charge for the period printed: 5.00 against one
-- month, 15.00 against three, 30.00 against six. monthly_amount divides by
-- the months in the period. Do not read amount as a monthly rate.
--
-- ONE STATEMENT IS NOT THE ROSTER
-- An account billed ahead appears only in the month it is billed, so it is
-- absent from two statements out of three while still live. covered_through
-- (= period_end) is what says whether an account is still paid up; the audit
-- counts a line while that date is at or after the month of the latest
-- statement loaded, not merely while the line is on the latest statement.
--
-- account_no joins the roster, the weekly feed and the recurring report; the
-- statement prints it solid (A16511523) and the parser hyphenates it.
-- Disconnect lines and one add-on line print no account at all.
CREATE OR REPLACE TABLE staging.stg_vendor__securitycentral_statement
OPTIONS (description = """
What Security Central billed Livewire per account, from the monthly dealer statement PDF emailed on the 25th. ONE ROW PER BILLED LINE, not per account: an account's Monitoring line plus its test lines, so an account's monthly cost is the SUM of its recurring rows (section = 'recurring'; activation and disconnect rows are prorations, not a rate).
amount is the charge for the period printed, NOT a monthly figure; monthly_amount is amount divided by the months the period spans and is what to sum.
An account billed quarterly or semi-annually appears only on the statement that bills it, so use covered_through, not presence on the latest statement, to decide whether it is still paid up. Join to the roster, the weekly status feed and the recurring report on account_no. kpi_subscription_audit uses this table.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_vendor.securitycentral_statement
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id ORDER BY _loaded_at DESC
  ) = 1
),
typed AS (
  SELECT
    _source_id                                                  AS line_key,
    SAFE.PARSE_DATE('%m/%d/%y', JSON_VALUE(payload, '$.STATEMENT_DATE'))
                                                                AS statement_date,
    JSON_VALUE(payload, '$.DEALER_ACCOUNT')                     AS dealer_account,
    JSON_VALUE(payload, '$.INVOICE_NO')                         AS invoice_no,
    JSON_VALUE(payload, '$.SECTION')                            AS section,
    NULLIF(JSON_VALUE(payload, '$.ACCOUNT'), '')                AS account_no,
    JSON_VALUE(payload, '$.SUBSCRIBER')                         AS subscriber_name,
    JSON_VALUE(payload, '$.ADDRESS')                            AS street_address,
    JSON_VALUE(payload, '$.DESCRIPTION')                        AS resource_description,
    SAFE.PARSE_DATE('%m/%d/%y', JSON_VALUE(payload, '$.PERIOD_START'))
                                                                AS period_start,
    SAFE.PARSE_DATE('%m/%d/%y', JSON_VALUE(payload, '$.PERIOD_END'))
                                                                AS period_end,
    SAFE_CAST(JSON_VALUE(payload, '$.AMOUNT') AS NUMERIC)       AS amount,
    SAFE_CAST(JSON_VALUE(payload, '$.PAGE') AS INT64)           AS statement_page,
    _loaded_at                                                  AS loaded_at
  FROM latest
)
SELECT
  line_key,
  statement_date,
  dealer_account,
  invoice_no,
  section,
  account_no,
  subscriber_name,
  street_address,
  resource_description,
  period_start,
  period_end,
  -- 11/01–11/30 is 1, 11/01–01/31 is 3, 11/01–04/30 is 6. Measured from the
  -- day after period_end so a full month counts as one, not zero. Prorated
  -- activation and disconnect periods are short of a month and floor to 1.
  GREATEST(DATE_DIFF(DATE_ADD(period_end, INTERVAL 1 DAY), period_start, MONTH), 1)
                                                                AS period_months,
  amount,
  ROUND(amount / GREATEST(DATE_DIFF(DATE_ADD(period_end, INTERVAL 1 DAY), period_start, MONTH), 1), 5)
                                                                AS monthly_amount,
  period_end                                                    AS covered_through,
  statement_page,
  loaded_at
FROM typed;

ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN line_key
  SET OPTIONS (description = "Synthesised key: statement date, section, account number (or name@address where the statement prints none) and service description. The statement numbers nothing; a month's bill is a fact of that month, so the date is part of the key.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN statement_date
  SET OPTIONS (description = "Date printed on the statement, the 25th of the month it was issued.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN dealer_account
  SET OPTIONS (description = "Livewire's dealer account number at Security Central (000312).");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN invoice_no
  SET OPTIONS (description = "Security Central invoice number this line was billed on. Activations and disconnects share one, recurring charges another.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN section
  SET OPTIONS (description = "Which part of the statement the line is from: recurring (the charge for the coming period, the only kind that is a rate), activation (prorated first charge for a new account, positive) or disconnect (prorated credit for an account that left, negative).");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN account_no
  SET OPTIONS (description = "Security Central account number, hyphenated (A1651-1523) to match stg_vendor__securitycentral_accounts, _status and _recurring. NULL on disconnect lines and on the one add-on line the statement prints without one.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN subscriber_name
  SET OPTIONS (description = "Name on the Security Central record, exactly as printed, wrapped lines rejoined.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN street_address
  SET OPTIONS (description = "Street line of the monitored premises as printed. No city or ZIP: the statement prints neither.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN resource_description
  SET OPTIONS (description = "What is billed: Monitoring, a scheduled test (Test Monthly, Weekly Test, Bi-Weekly Test), Open/Close Log, or a cellular package.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN period_start
  SET OPTIONS (description = "First day of the period this line charges for.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN period_end
  SET OPTIONS (description = "Last day of the period this line charges for.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN period_months
  SET OPTIONS (description = "Months the period spans: 1 for monthly accounts, 3 or 6 for accounts billed ahead, 1 for a prorated activation or disconnect.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN amount
  SET OPTIONS (description = "USD charged for the period printed, exactly as the statement prints it. NOT a monthly figure on quarterly and semi-annual lines; negative on disconnect credits.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN monthly_amount
  SET OPTIONS (description = "amount divided by period_months: the per-month cost of this line. SUM an account's recurring rows for its monthly cost. 0.00 is a real free line, usually a test signal.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN covered_through
  SET OPTIONS (description = "Last day this line's charge covers (= period_end). An account is paid up while this is at or after today's month, even when it is absent from the latest statement, as accounts billed ahead are.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN statement_page
  SET OPTIONS (description = "Page of the statement PDF the line was read from, for checking a row against the document.");
ALTER TABLE staging.stg_vendor__securitycentral_statement ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
