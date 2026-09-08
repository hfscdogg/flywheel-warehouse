-- stg_vendor__alarmdotcom_billing — what Alarm.com charges us, per charge.
-- Grain: one row per charge line. An account carries a "Monthly Fee" row plus
--   one row per add-on it has, so an account's monthly cost is the SUM of its
--   recurring rows — never the value of any single row.
-- Source: raw_vendor.alarmdotcom_billing (drop-bucket uploads of the dealer
--   site billing export).
--
-- WHY THE GRAIN MATTERS
-- Accounts carry between 1 and 31 charge rows, median 7. Taking one row as
-- the account's price understates the bill by roughly eight times, and the
-- add-on rows are where the variation lives: two accounts on the same
-- package differ entirely by what is switched on.
--
-- RECURRING VS ONE-OFF
-- is_recurring marks the charges that repeat: the vendor types those
-- FutureService, meaning next month's bill, and types prorations and
-- activation fees Service or Activation. Both are kept — they are money we
-- paid — but only the recurring ones belong in a monthly rate, so the audit
-- filters on this rather than on a date.
--
-- customer_id is Alarm.com's own account id and joins one-to-one to
-- stg_vendor__alarmdotcom_accounts (597 of 597 on the 2026-09-08 files),
-- which is where the address and the Security Central cross-key live.
CREATE OR REPLACE TABLE staging.stg_vendor__alarmdotcom_billing
OPTIONS (description = """
What Alarm.com bills Livewire, from the dealer-site billing export. ONE ROW PER CHARGE, not per account: every account has a Monthly Fee row plus a row per add-on, so an account's monthly cost is the SUM of its rows. Accounts carry 1 to 31 rows.
Filter to is_recurring before summing a monthly rate: the export also carries one-off prorations and activation fees.
customer_id joins one-to-one to stg_vendor__alarmdotcom_accounts. kpi_subscription_audit uses this table.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_vendor.alarmdotcom_billing
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id ORDER BY _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                 AS charge_key,
  JSON_VALUE(payload, '$."Customer ID"')                     AS customer_id,
  JSON_VALUE(payload, '$."Charge Description"')              AS charge_description,
  JSON_VALUE(payload, '$."Charge Type"')                     AS charge_type,
  JSON_VALUE(payload, '$."Charge Type"') = 'FutureService'   AS is_recurring,
  SAFE_CAST(JSON_VALUE(payload, '$."Charge Amount"') AS NUMERIC)
                                                             AS charge_amount,
  SAFE.PARSE_DATE('%Y-%m-%d', JSON_VALUE(payload, '$."Charge Date"'))
                                                             AS charged_on,
  JSON_VALUE(payload, '$."Package Description"')             AS package_description,
  JSON_VALUE(payload, '$."Add-on Description"')              AS addon_description,
  NULLIF(JSON_VALUE(payload, '$."Customer CS Account Number"'), '')
                                                             AS cs_account_number,
  COALESCE(
    NULLIF(TRIM(CONCAT(
      COALESCE(JSON_VALUE(payload, '$."First Name"'), ''), ' ',
      COALESCE(JSON_VALUE(payload, '$."Last Name"'), ''))), ''),
    JSON_VALUE(payload, '$."Company Name"')
  )                                                          AS subscriber_name,
  NULLIF(JSON_VALUE(payload, '$."Term Date"'), '')           AS term_date,
  _loaded_at                                                 AS loaded_at
FROM latest;

ALTER TABLE staging.stg_vendor__alarmdotcom_billing ALTER COLUMN charge_key
  SET OPTIONS (description = "Synthesised key for this charge line: customer id, charge description and charge date. The export numbers nothing, and those three are unique across it.");
ALTER TABLE staging.stg_vendor__alarmdotcom_billing ALTER COLUMN customer_id
  SET OPTIONS (description = "Alarm.com customer id. Joins one-to-one to stg_vendor__alarmdotcom_accounts.customer_id, which carries the address and Security Central's account number.");
ALTER TABLE staging.stg_vendor__alarmdotcom_billing ALTER COLUMN charge_description
  SET OPTIONS (description = "What this line is for: 'Monthly Fee' is the base charge every account has, and 'Add-on: X' lines are the extras switched on for it.");
ALTER TABLE staging.stg_vendor__alarmdotcom_billing ALTER COLUMN charge_type
  SET OPTIONS (description = "The vendor's own type: FutureService is next month's recurring charge, Service is a proration already incurred, Activation is a one-off setup fee.");
ALTER TABLE staging.stg_vendor__alarmdotcom_billing ALTER COLUMN is_recurring
  SET OPTIONS (description = "TRUE when this charge repeats monthly (charge_type FutureService). Filter on this before summing an account's monthly rate, or one-off prorations and activation fees inflate it.");
ALTER TABLE staging.stg_vendor__alarmdotcom_billing ALTER COLUMN charge_amount
  SET OPTIONS (description = "What Alarm.com charges for this one line per month, USD. 0.00 is a real free line — many add-ons are included in the package. SUM an account's recurring rows for its monthly cost.");
ALTER TABLE staging.stg_vendor__alarmdotcom_billing ALTER COLUMN charged_on
  SET OPTIONS (description = "Date the charge applies to. Recurring rows all carry the start of the coming billing month.");
ALTER TABLE staging.stg_vendor__alarmdotcom_billing ALTER COLUMN package_description
  SET OPTIONS (description = "Alarm.com service package the account is on, when the line names one.");
ALTER TABLE staging.stg_vendor__alarmdotcom_billing ALTER COLUMN addon_description
  SET OPTIONS (description = "The add-on this line bills for, when it is an add-on line rather than the base fee.");
ALTER TABLE staging.stg_vendor__alarmdotcom_billing ALTER COLUMN cs_account_number
  SET OPTIONS (description = "Security Central's account number for the same property, without its prefix. The prefixed form on stg_vendor__alarmdotcom_accounts.sc_account_no is the one to join on.");
ALTER TABLE staging.stg_vendor__alarmdotcom_billing ALTER COLUMN subscriber_name
  SET OPTIONS (description = "Name on the Alarm.com record: first and last name, or the company name.");
ALTER TABLE staging.stg_vendor__alarmdotcom_billing ALTER COLUMN term_date
  SET OPTIONS (description = "Termination date when the account is ending; NULL on live accounts.");
ALTER TABLE staging.stg_vendor__alarmdotcom_billing ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
