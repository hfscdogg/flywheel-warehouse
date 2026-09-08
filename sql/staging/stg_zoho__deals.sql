-- stg_zoho__deals — latest record per Zoho CRM deal.
-- Grain: one row per deal_id.
-- Source: raw_zoho.deals (append-only; payload = full Zoho v2 record).
CREATE OR REPLACE TABLE staging.stg_zoho__deals
OPTIONS (description = """
Zoho CRM deals, one row per deal: the sales pipeline. is_won and is_lost follow Zoho's Forecast Type stage lists, so they mean what the Zoho dashboard means; install stages count as won. Exclude is_test_record = TRUE from any revenue question. Amounts USD.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_zoho.deals
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
),
fields AS (
  SELECT
    _source_id                                                 AS deal_id,
    JSON_VALUE(payload, '$.Deal_Name')                         AS deal_name,
    JSON_VALUE(payload, '$.Stage')                             AS stage,
    JSON_VALUE(payload, '$.Pipeline')                          AS pipeline,
    SAFE_CAST(JSON_VALUE(payload, '$.Amount') AS NUMERIC)      AS amount,
    SAFE_CAST(JSON_VALUE(payload, '$.Probability') AS INT64)   AS probability_pct,
    SAFE_CAST(JSON_VALUE(payload, '$.Expected_Revenue') AS NUMERIC)
                                                               AS expected_revenue,
    SAFE_CAST(JSON_VALUE(payload, '$.Closing_Date') AS DATE)   AS closing_date,
    JSON_VALUE(payload, '$.Lead_Source')                       AS lead_source,
    -- Custom checkbox excluded from Zoho's revenue reporting; NULL when the
    -- field is absent from the payload (treated as not-a-test downstream).
    SAFE_CAST(JSON_VALUE(payload, '$.Test_Record') AS BOOL)    AS is_test_record,
    -- Custom fields behind the dashboard's L4B and RMR splits
    -- (zoho-reference/formulas.md). API names are best-effort from the
    -- display names ("Commercial?", the two service-plan pickers) — same
    -- VERIFY-on-first-run posture as the D-Tools paths.
    JSON_VALUE(payload, '$.Commercial')                        AS commercial,
    JSON_VALUE(payload, '$.Alarm_Monitoring_Plan')             AS alarm_monitoring_plan,
    JSON_VALUE(payload, '$.Pick_Service_Plan')                 AS pick_service_plan,
    JSON_VALUE(payload, '$.Marketing_Channel')                 AS marketing_channel,
    JSON_VALUE(payload, '$.Account_Name.id')                   AS account_id,
    JSON_VALUE(payload, '$.Account_Name.name')                 AS account_name,
    JSON_VALUE(payload, '$.Contact_Name.id')                   AS contact_id,
    JSON_VALUE(payload, '$.Contact_Name.name')                 AS contact_name,
    JSON_VALUE(payload, '$.Owner.name')                        AS owner_name,
    JSON_VALUE(payload, '$.Owner.email')                       AS owner_email,
    SAFE_CAST(JSON_VALUE(payload, '$.Created_Time') AS TIMESTAMP)  AS created_at,
    SAFE_CAST(JSON_VALUE(payload, '$.Modified_Time') AS TIMESTAMP) AS modified_at,
    _loaded_at                                                 AS loaded_at
  FROM latest
),
classified AS (
  SELECT
    *,
    -- Won/Lost/Open per the Zoho Analytics "Forecast Type" formula column on
    -- Potentials (zoho-reference/formulas.md) — the org's authoritative stage
    -- classification. Most Won stages don't contain the word "won" and two
    -- Lost stages don't contain "lost", so explicit lists, not patterns.
    -- A stage outside both lists (including a newly added picklist value)
    -- classifies as Open, same as Zoho's formula.
    CASE
      WHEN stage IN (
        'RFP Sent', 'Closed Won', 'Closed Won - Service',
        'Closed Won - Design Retainer', 'Closed Won - Not Ready',
        'Change Order', 'Tentatively Scheduled',
        'Rough-In', 'Rough-In Scheduled', 'Rough-In Complete',
        'Trim-Out', 'Trim Out Scheduled', 'Trim-Out Complete',
        'Finish-Out', 'Finish Out Scheduled', 'Finish-Out Complete',
        'Punch Out', 'Punch Out Scheduled',
        'Service Call Scheduled', 'Service Call Complete',
        'Installation Complete'
      ) THEN 'Won'
      WHEN stage IN (
        'Closed Lost to Competition', 'Client decided not to do work',
        'Client in holding pattern', 'Closed Lost - Unable to Contact'
      ) THEN 'Lost'
      ELSE 'Open'
    END AS forecast_type
  FROM fields
)
SELECT
  deal_id,
  deal_name,
  stage,
  pipeline,
  amount,
  probability_pct,
  expected_revenue,
  closing_date,
  lead_source,
  is_test_record,
  commercial,
  alarm_monitoring_plan,
  pick_service_plan,
  marketing_channel,
  account_id,
  account_name,
  contact_id,
  contact_name,
  owner_name,
  owner_email,
  created_at,
  modified_at,
  loaded_at,
  forecast_type,
  forecast_type = 'Won'  AS is_won,
  forecast_type = 'Lost' AS is_lost
FROM classified;

ALTER TABLE staging.stg_zoho__deals ALTER COLUMN deal_id
  SET OPTIONS (description = "Zoho CRM deal id; the key.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN deal_name
  SET OPTIONS (description = "Deal name.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN stage
  SET OPTIONS (description = "Current pipeline stage.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN pipeline
  SET OPTIONS (description = "Which pipeline the deal is in.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN amount
  SET OPTIONS (description = "Deal amount, USD; the revenue measure at close.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN probability_pct
  SET OPTIONS (description = "Probability of closing, 0 to 100.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN expected_revenue
  SET OPTIONS (description = "amount times probability, USD; what the dashboard plots as pipeline.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN closing_date
  SET OPTIONS (description = "Expected or actual close date.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN lead_source
  SET OPTIONS (description = "Lead source picklist.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN is_test_record
  SET OPTIONS (description = "TRUE for CRM test records; exclude these from every revenue figure.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN commercial
  SET OPTIONS (description = "Commercial flag as set on the deal.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN alarm_monitoring_plan
  SET OPTIONS (description = "Alarm monitoring plan chosen on the deal, when any.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN pick_service_plan
  SET OPTIONS (description = "Service plan chosen on the deal, when any.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN marketing_channel
  SET OPTIONS (description = "Marketing channel the sales team attributed the deal to.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN account_id
  SET OPTIONS (description = "CRM account on the deal; joins to stg_zoho__accounts.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN account_name
  SET OPTIONS (description = "That account's name.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN contact_id
  SET OPTIONS (description = "CRM contact on the deal; joins to stg_zoho__contacts.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN contact_name
  SET OPTIONS (description = "That contact's name.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN owner_name
  SET OPTIONS (description = "CRM user who owns the deal.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN owner_email
  SET OPTIONS (description = "That owner's email.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN forecast_type
  SET OPTIONS (description = "Zoho Forecast Type of the current stage: Open, Closed Won, Closed Lost, or an install stage.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN is_won
  SET OPTIONS (description = "TRUE when the stage counts as won, per the Forecast Type lists.");
ALTER TABLE staging.stg_zoho__deals ALTER COLUMN is_lost
  SET OPTIONS (description = "TRUE when the stage counts as lost.");
