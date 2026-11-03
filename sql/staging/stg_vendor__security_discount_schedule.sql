-- stg_vendor__security_discount_schedule — the monthly deferral and
-- amortization schedule for security-monitoring discounts.
-- Grain: one row per month.
-- Source: raw_vendor.gsheet_security_deferred, the "Monthly Deferred" tab of
--   the "Security Discounts (deferred)" Google Sheet (pipelines/gsheets/).
CREATE OR REPLACE TABLE staging.stg_vendor__security_discount_schedule
OPTIONS (description = """
Livewire's schedule for security system discounts given with a monitoring agreement (25% off with a 3-year agreement, 50% off with 5-year), from the "Monthly Deferred" tab of the controller's Security Discounts sheet, January 2021 onward. A discount is not expensed the month it is given: it is deferred and amortized over the agreement's 36 or 60 months. Each month two journal entries are booked from this schedule: the month's new discounts into Deferred Security Discounts, and the month's amortization back out to Security Monitoring Income: Security Discounts.
The discount invoice lines themselves are in stg_qbo__invoice_lines. The sheet is hand-kept, so its running totals carry its own corrections (see note); deferred_cumulative does not always equal the previous month's plus deferred_month_total.
""")
AS
WITH latest AS (
  SELECT *
  FROM raw_vendor.gsheet_security_deferred
  QUALIFY JSON_VALUE(payload, '$.version') = FIRST_VALUE(JSON_VALUE(payload, '$.version')) OVER (
    PARTITION BY JSON_VALUE(payload, '$.file_id') ORDER BY _loaded_at DESC)
)
SELECT
  SAFE.PARSE_DATE('%Y-%m-%d', JSON_VALUE(payload, '$.month'))      AS month,
  ROUND(SAFE_CAST(JSON_VALUE(payload, '$.deferred_3yr') AS NUMERIC), 2)  AS deferred_3yr,
  ROUND(SAFE_CAST(JSON_VALUE(payload, '$.deferred_5yr') AS NUMERIC), 2)  AS deferred_5yr,
  ROUND(SAFE_CAST(JSON_VALUE(payload, '$.deferred_month_total') AS NUMERIC), 2) AS deferred_month_total,
  ROUND(SAFE_CAST(JSON_VALUE(payload, '$.deferred_cumulative') AS NUMERIC), 2)  AS deferred_cumulative,
  ROUND(SAFE_CAST(JSON_VALUE(payload, '$.discount_3yr') AS NUMERIC), 2)  AS monthly_share_3yr,
  ROUND(SAFE_CAST(JSON_VALUE(payload, '$.discount_5yr') AS NUMERIC), 2)  AS monthly_share_5yr,
  ROUND(SAFE_CAST(JSON_VALUE(payload, '$.amortized_3yr') AS NUMERIC), 2) AS amortization_3yr,
  ROUND(SAFE_CAST(JSON_VALUE(payload, '$.amortized_5yr') AS NUMERIC), 2) AS amortization_5yr,
  ROUND(SAFE_CAST(JSON_VALUE(payload, '$.amortization_month_total') AS NUMERIC), 2) AS amortization_month_total,
  ROUND(SAFE_CAST(JSON_VALUE(payload, '$.amortized_cumulative') AS NUMERIC), 2)    AS amortized_cumulative,
  ROUND(SAFE_CAST(JSON_VALUE(payload, '$.balance_check') AS NUMERIC), 2) AS deferred_balance,
  JSON_VALUE(payload, '$.note')                                    AS note,
  SAFE_CAST(JSON_VALUE(payload, '$.row') AS INT64)                 AS sheet_row,
  _loaded_at                                                       AS loaded_at
FROM latest;
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN month
  SET OPTIONS (description = "Month the entries are booked for (first day of the month).");
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN deferred_3yr
  SET OPTIONS (description = "Discounts given this month with 3-year agreements, deferred, USD.");
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN deferred_5yr
  SET OPTIONS (description = "Discounts given this month with 5-year agreements, deferred, USD.");
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN deferred_month_total
  SET OPTIONS (description = "All discounts deferred this month, USD: the first journal entry (debit Deferred Security Discounts).");
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN deferred_cumulative
  SET OPTIONS (description = "All discounts deferred since January 2021, as the sheet carries it, USD.");
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN monthly_share_3yr
  SET OPTIONS (description = "This month's 3-year discounts divided by 36: what they add to each later month's amortization, USD.");
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN monthly_share_5yr
  SET OPTIONS (description = "This month's 5-year discounts divided by 60: what they add to each later month's amortization, USD. Should be about deferred_5yr / 60; a value near deferred_5yr itself is an entry error on the sheet.");
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN amortization_3yr
  SET OPTIONS (description = "Amortization this month from all open 3-year agreements, USD.");
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN amortization_5yr
  SET OPTIONS (description = "Amortization this month from all open 5-year agreements, USD.");
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN amortization_month_total
  SET OPTIONS (description = "Total amortization this month, USD: the second journal entry (credit Deferred Security Discounts, debit Security Monitoring Income: Security Discounts).");
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN amortized_cumulative
  SET OPTIONS (description = "All amortization since January 2021, USD.");
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN deferred_balance
  SET OPTIONS (description = "The sheet's checks-and-balances column: deferred discounts not yet amortized at month end, USD. Compare with the Deferred Security Discounts balance in QuickBooks.");
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN note
  SET OPTIONS (description = "Note typed beside the month, e.g. a correction booked that month; NULL when none.");
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN sheet_row
  SET OPTIONS (description = "Row of the month on the Monthly Deferred tab.");
ALTER TABLE staging.stg_vendor__security_discount_schedule ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this version of the sheet was loaded into the warehouse (UTC).");
