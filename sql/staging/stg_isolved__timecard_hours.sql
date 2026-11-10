-- stg_isolved__timecard_hours — hours on each employee's timecard, by day
-- and pay item.
-- Grain: one row per (work_date, employee, pay item).
-- Source: raw_isolved.timecards (one row per employee per day pulled;
--   payload.record is the API's employee record, payload.work_date the day
--   it was asked for) and raw_isolved.timecard_days (one row per day pulled).
--
-- The ingest re-pulls a trailing five weeks every night, because a timecard
-- is corrected after the fact. Each day is read from the NEWEST run that
-- pulled it, through timecard_days: that table has a row for a day even when
-- the pull found nobody, so a timecard removed in iSolved leaves here too
-- instead of surviving from an older pull.
--
-- The day comes from the request, not the record: the ingest asks for one
-- day at a time (pipelines/lib/sources.py, ISOLVED).
--
-- Names, not ids: the fields this reads are the ones the utilization email's
-- fetch already relies on (hfscdogg/forecast-utilization). An employee id
-- can be added once a landed payload shows what iSolved calls it.
CREATE OR REPLACE TABLE staging.stg_isolved__timecard_hours
OPTIONS (description = """
Hours on each employee's iSolved timecard (the payroll and time system, through Dominion Payroll), one row per work date, employee and pay item, refreshed nightly for the last five weeks. This is what people were clocked and paid for, as opposed to hours sold (D-Tools) or hours logged against a job (meetings in Zoho CRM). It carries hours only: no pay rate, no dollars, and no job, so it cannot say which project an hour belongs to. Sum hours where is_time_on_clock for hours worked; PTO, holiday and salaried rows are the other pay items. Employees are named as payroll spells them (legal names), which can differ from the name in Zoho CRM (James here, Jim there). The most recent days change until the pay period is processed. Personal payroll data: report totals, not one person's time off.
""")
AS
WITH pulls AS (
  SELECT _source_id AS work_date_text, _run_id, _loaded_at
  FROM raw_isolved.timecard_days
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id ORDER BY _loaded_at DESC
  ) = 1
),
records AS (
  SELECT t.payload, p._loaded_at
  FROM raw_isolved.timecards AS t
  JOIN pulls AS p
    ON JSON_VALUE(t.payload, '$.work_date') = p.work_date_text
   AND t._run_id = p._run_id
),
items AS (
  SELECT
    SAFE_CAST(JSON_VALUE(r.payload, '$.work_date') AS DATE)       AS work_date,
    TRIM(JSON_VALUE(r.payload, '$.record.employeeFirstName'))     AS first_name,
    TRIM(JSON_VALUE(r.payload, '$.record.employeeLastName'))      AS last_name,
    JSON_VALUE(item, '$.payItemName')                             AS pay_item,
    SAFE_CAST(JSON_VALUE(item, '$.payItemHours') AS NUMERIC)      AS hours,
    r._loaded_at
  FROM records AS r,
    UNNEST(JSON_QUERY_ARRAY(r.payload, '$.record.timecardData')) AS day_record,
    UNNEST(JSON_QUERY_ARRAY(day_record, '$.payItems')) AS item
)
SELECT
  work_date,
  TRIM(CONCAT(COALESCE(first_name, ''), ' ', COALESCE(last_name, ''))) AS employee_name,
  first_name,
  last_name,
  pay_item,
  SUM(hours)                                                      AS hours,
  -- The utilization report's rule (forecast-utilization, PAY_ITEMS_WORKED):
  -- a whitelist, so a pay item nobody has seen yet counts as not worked
  -- until someone decides otherwise.
  pay_item IN ('Hourly Regular', 'Overtime')                      AS is_time_on_clock,
  MAX(_loaded_at)                                                 AS loaded_at
FROM items
WHERE pay_item IS NOT NULL
GROUP BY work_date, first_name, last_name, pay_item;

ALTER TABLE staging.stg_isolved__timecard_hours ALTER COLUMN work_date
  SET OPTIONS (description = "The day the hours were worked or taken.");
ALTER TABLE staging.stg_isolved__timecard_hours ALTER COLUMN employee_name
  SET OPTIONS (description = "First and last name as payroll holds them. A legal name, so it may not equal the person's name in Zoho CRM; match by hand or through an alias, never by guessing.");
ALTER TABLE staging.stg_isolved__timecard_hours ALTER COLUMN first_name
  SET OPTIONS (description = "First name as payroll holds it.");
ALTER TABLE staging.stg_isolved__timecard_hours ALTER COLUMN last_name
  SET OPTIONS (description = "Last name as payroll holds it.");
ALTER TABLE staging.stg_isolved__timecard_hours ALTER COLUMN pay_item
  SET OPTIONS (description = "iSolved pay item the hours are under, e.g. Hourly Regular, Overtime, PTO, Salary Hours.");
ALTER TABLE staging.stg_isolved__timecard_hours ALTER COLUMN hours
  SET OPTIONS (description = "Hours under this pay item for this employee on this day. Overtime hours are hours, not yet multiplied by 1.5.");
ALTER TABLE staging.stg_isolved__timecard_hours ALTER COLUMN is_time_on_clock
  SET OPTIONS (description = "TRUE for Hourly Regular and Overtime, the pay items the weekly utilization report counts as hours worked. FALSE for PTO, Salary Hours (office staff) and any other pay item.");
ALTER TABLE staging.stg_isolved__timecard_hours ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this day was last pulled from iSolved (UTC).");
