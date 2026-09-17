-- fresh — every source feeding the warehouse has loaded recently enough to
-- be worth answering from. Run by 06-transform.sh after the build; any row
-- returned is a failure. Not a model: it creates nothing and lives outside
-- sql/marts and sql/staging so the transform never treats it as one.
--
-- WHY THIS EXISTS. A transform over stale sources succeeds. Every model
-- rebuilds, every check passes, the marts are served, and the answers are
-- quietly out of date -- which is worse than an error, because an error is
-- visible and this is not. On 2026-09-17 the ingests did not run at their
-- scheduled hour and the transform rebuilt all 35 models from the previous
-- day's extract without a word.
--
-- THE THRESHOLDS ARE EACH SOURCE'S OWN CADENCE, NOT ONE NUMBER. An API
-- source ingested nightly gets 3 days: two missed nights plus room for the
-- schedule to slip, which it does. A hand-uploaded vendor report gets the
-- vendor's own cadence plus room for a late upload -- 14 days for Security
-- Central's weekly Customer Count, 45 for the monthly reports. A threshold
-- that fires every week gets ignored, and an ignored check is worse than no
-- check because it also reads as coverage.
--
-- drop_prefix names the folder to upload to, so the failure says what to do
-- rather than only what is wrong. NULL for API sources: those are a workflow
-- to re-run, not a file to find.
--
-- NOT LISTED: staging.stg_alarmdotcom__customers. It is empty by design until
-- the Alarm.com Partner API is credentialed, so MAX(loaded_at) is NULL and it
-- would fail this check every night for a reason nobody can act on. The
-- dealer-site export is the live Alarm.com feed and IS checked here.
-- pipelines/tests/test_sql_freshness.py holds that exemption and fails if any
-- other staging table with a loaded_at column goes unchecked.
WITH loaded AS (
  SELECT 'stg_dtools__opportunities' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_dtools__opportunities
  UNION ALL
  SELECT 'stg_dtools__projects' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_dtools__projects
  UNION ALL
  SELECT 'stg_dtools__quotes' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_dtools__quotes
  UNION ALL
  SELECT 'stg_qbo__accounts' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_qbo__accounts
  UNION ALL
  SELECT 'stg_qbo__bill_lines' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_qbo__bill_lines
  UNION ALL
  SELECT 'stg_qbo__bills' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_qbo__bills
  UNION ALL
  SELECT 'stg_qbo__customers' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_qbo__customers
  UNION ALL
  SELECT 'stg_qbo__estimates' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_qbo__estimates
  UNION ALL
  SELECT 'stg_qbo__invoice_lines' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_qbo__invoice_lines
  UNION ALL
  SELECT 'stg_qbo__invoices' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_qbo__invoices
  UNION ALL
  SELECT 'stg_qbo__items' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_qbo__items
  UNION ALL
  SELECT 'stg_qbo__payments' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_qbo__payments
  UNION ALL
  SELECT 'stg_qbo__purchase_lines' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_qbo__purchase_lines
  UNION ALL
  SELECT 'stg_qbo__purchase_orders' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_qbo__purchase_orders
  UNION ALL
  SELECT 'stg_qbo__vendors' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_qbo__vendors
  UNION ALL
  SELECT 'stg_zoho__accounts' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_zoho__accounts
  UNION ALL
  SELECT 'stg_zoho__contacts' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_zoho__contacts
  UNION ALL
  SELECT 'stg_zoho__deals' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_zoho__deals
  UNION ALL
  SELECT 'stg_zoho__leads' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_zoho__leads
  UNION ALL
  SELECT 'stg_zohobilling__customers' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_zohobilling__customers
  UNION ALL
  SELECT 'stg_zohobilling__subscriptions' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest
  FROM staging.stg_zohobilling__subscriptions
  UNION ALL
  SELECT 'stg_vendor__alarmdotcom_accounts', 45, 'alarmdotcom/customerlist', MAX(loaded_at)
  FROM staging.stg_vendor__alarmdotcom_accounts
  UNION ALL
  SELECT 'stg_vendor__alarmdotcom_billing', 45, 'alarmdotcom/billing', MAX(loaded_at)
  FROM staging.stg_vendor__alarmdotcom_billing
  UNION ALL
  SELECT 'stg_vendor__parasol_accounts', 45, 'parasol/invoice', MAX(loaded_at)
  FROM staging.stg_vendor__parasol_accounts
  UNION ALL
  SELECT 'stg_vendor__securitycentral_accounts', 45, 'securitycentral/allaccounts', MAX(loaded_at)
  FROM staging.stg_vendor__securitycentral_accounts
  UNION ALL
  SELECT 'stg_vendor__securitycentral_recurring', 45, 'securitycentral/recurring', MAX(loaded_at)
  FROM staging.stg_vendor__securitycentral_recurring
  UNION ALL
  SELECT 'stg_vendor__securitycentral_status', 14, 'securitycentral/customercount', MAX(loaded_at)
  FROM staging.stg_vendor__securitycentral_status
)
SELECT
  table_name,
  FORMAT_TIMESTAMP('%Y-%m-%d', newest) AS newest_load,
  DATE_DIFF(CURRENT_DATE(), DATE(newest), DAY) AS age_days,
  max_age_days,
  IFNULL(CONCAT('upload to gs://<vendor-drop-bucket>/', drop_prefix, '/'),
         'ingest workflow has not run') AS fix
FROM loaded
WHERE newest IS NULL
   OR newest < TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL max_age_days DAY)
ORDER BY age_days DESC;
