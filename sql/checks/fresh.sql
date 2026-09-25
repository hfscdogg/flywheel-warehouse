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
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         CAST(NULL AS STRING) AS raw_table
  FROM staging.stg_dtools__opportunities
  UNION ALL
  SELECT 'stg_dtools__projects' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         CAST(NULL AS STRING) AS raw_table
  FROM staging.stg_dtools__projects
  UNION ALL
  SELECT 'stg_dtools__quotes' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         CAST(NULL AS STRING) AS raw_table
  FROM staging.stg_dtools__quotes
  UNION ALL
  SELECT 'stg_qbo__accounts' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_qbo.account' AS raw_table
  FROM staging.stg_qbo__accounts
  UNION ALL
  SELECT 'stg_qbo__bill_lines' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_qbo.bill' AS raw_table
  FROM staging.stg_qbo__bill_lines
  UNION ALL
  SELECT 'stg_qbo__bills' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_qbo.bill' AS raw_table
  FROM staging.stg_qbo__bills
  UNION ALL
  SELECT 'stg_qbo__customers' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_qbo.customer' AS raw_table
  FROM staging.stg_qbo__customers
  UNION ALL
  SELECT 'stg_qbo__estimates' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_qbo.estimate' AS raw_table
  FROM staging.stg_qbo__estimates
  UNION ALL
  SELECT 'stg_qbo__invoice_lines' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_qbo.invoice' AS raw_table
  FROM staging.stg_qbo__invoice_lines
  UNION ALL
  SELECT 'stg_qbo__invoices' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_qbo.invoice' AS raw_table
  FROM staging.stg_qbo__invoices
  UNION ALL
  SELECT 'stg_qbo__items' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_qbo.item' AS raw_table
  FROM staging.stg_qbo__items
  UNION ALL
  SELECT 'stg_qbo__payments' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_qbo.payment' AS raw_table
  FROM staging.stg_qbo__payments
  UNION ALL
  SELECT 'stg_qbo__purchase_lines' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_qbo.purchase' AS raw_table
  FROM staging.stg_qbo__purchase_lines
  UNION ALL
  SELECT 'stg_qbo__purchase_orders' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_qbo.purchaseorder' AS raw_table
  FROM staging.stg_qbo__purchase_orders
  UNION ALL
  -- GA4 is not ingested by us: Google writes the export daily, the next
  -- day. loaded_at is the newest event in it, so 3 days means two missing
  -- days, i.e. the export stopped (unlinked, or the property's quota hit).
  SELECT 'stg_ga4__sessions' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         CAST(NULL AS STRING) AS raw_table
  FROM staging.stg_ga4__sessions
  UNION ALL
  SELECT 'stg_qbo__report_lines' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_qbo.report_lines' AS raw_table
  FROM staging.stg_qbo__report_lines
  UNION ALL
  SELECT 'stg_qbo__budgets' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_qbo.budgets' AS raw_table
  FROM staging.stg_qbo__budgets
  UNION ALL
  SELECT 'stg_qbo__vendors' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_qbo.vendor' AS raw_table
  FROM staging.stg_qbo__vendors
  UNION ALL
  SELECT 'stg_zoho__accounts' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_zoho.accounts' AS raw_table
  FROM staging.stg_zoho__accounts
  UNION ALL
  SELECT 'stg_zoho__contacts' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_zoho.contacts' AS raw_table
  FROM staging.stg_zoho__contacts
  UNION ALL
  SELECT 'stg_zoho__deals' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_zoho.deals' AS raw_table
  FROM staging.stg_zoho__deals
  UNION ALL
  SELECT 'stg_zoho__leads' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         'raw_zoho.leads' AS raw_table
  FROM staging.stg_zoho__leads
  UNION ALL
  SELECT 'stg_zohobilling__customers' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         CAST(NULL AS STRING) AS raw_table
  FROM staging.stg_zohobilling__customers
  UNION ALL
  SELECT 'stg_zohobilling__subscriptions' AS table_name, 3 AS max_age_days,
         CAST(NULL AS STRING) AS drop_prefix, MAX(loaded_at) AS newest,
         CAST(NULL AS STRING) AS raw_table
  FROM staging.stg_zohobilling__subscriptions
  UNION ALL
  SELECT 'stg_vendor__alarmdotcom_accounts', 45, 'alarmdotcom/customerlist', MAX(loaded_at), NULL
  FROM staging.stg_vendor__alarmdotcom_accounts
  UNION ALL
  SELECT 'stg_vendor__alarmdotcom_billing', 45, 'alarmdotcom/billing', MAX(loaded_at), NULL
  FROM staging.stg_vendor__alarmdotcom_billing
  UNION ALL
  SELECT 'stg_vendor__parasol_accounts', 45, 'parasol/invoice', MAX(loaded_at), NULL
  FROM staging.stg_vendor__parasol_accounts
  UNION ALL
  SELECT 'stg_vendor__securitycentral_accounts', 45, 'securitycentral/allaccounts', MAX(loaded_at), NULL
  FROM staging.stg_vendor__securitycentral_accounts
  UNION ALL
  SELECT 'stg_vendor__securitycentral_recurring', 45, 'securitycentral/recurring', MAX(loaded_at), NULL
  FROM staging.stg_vendor__securitycentral_recurring
  UNION ALL
  SELECT 'stg_vendor__securitycentral_status', 14, 'securitycentral/customercount', MAX(loaded_at), NULL
  FROM staging.stg_vendor__securitycentral_status
),
-- The run log (pipelines/lib/bq.py RUNS_TABLE): one row per entity per run,
-- empty pulls included. Read for the two INCREMENTAL API sources only,
-- QuickBooks and Zoho CRM, whose landing tables grow only when a record
-- changes. There MAX(loaded_at) says when something last changed, which for
-- a quiet entity can be days while the ingest runs green every night:
-- 2026-09-25, stg_qbo__purchase_orders "3 days old, ingest workflow has not
-- run" the morning after ingest-qbo passed for the third night running. The
-- other API sources pull in full every run, so their loaded_at already is
-- the run time, and a hand upload has no run but the upload.
ran AS (
  SELECT CONCAT('raw_qbo.', entity) AS raw_table, MAX(ran_at) AS ran_at
  FROM raw_qbo._flywheel_runs
  GROUP BY entity
  UNION ALL
  SELECT CONCAT('raw_zoho.', entity) AS raw_table, MAX(ran_at) AS ran_at
  FROM raw_zoho._flywheel_runs
  GROUP BY entity
),
-- Newest of the last load and the last run. GREATEST is NULL if either side
-- is, so each NULL is taken apart explicitly: a table never loaded whose
-- ingest ran (nothing to find yet) is current; one that loaded but has no
-- run logged (loaded before the log existed) keeps its load time.
checked AS (
  SELECT
    l.table_name, l.max_age_days, l.drop_prefix,
    CASE
      WHEN r.ran_at IS NULL THEN l.newest
      WHEN l.newest IS NULL THEN r.ran_at
      ELSE GREATEST(l.newest, r.ran_at)
    END AS newest
  FROM loaded AS l
  LEFT JOIN ran AS r USING (raw_table)
)
SELECT
  table_name,
  FORMAT_TIMESTAMP('%Y-%m-%d', newest) AS newest_load,
  DATE_DIFF(CURRENT_DATE(), DATE(newest), DAY) AS age_days,
  max_age_days,
  CASE
    WHEN drop_prefix IS NOT NULL THEN CONCAT('upload to gs://<vendor-drop-bucket>/', drop_prefix, '/')
    WHEN STARTS_WITH(table_name, 'stg_ga4__') THEN 'GA4 export stopped: check the BigQuery link in GA4 Admin'
    ELSE 'ingest workflow has not run'
  END AS fix
FROM checked
WHERE newest IS NULL
   OR newest < TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL max_age_days DAY)
ORDER BY age_days DESC;
