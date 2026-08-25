-- stg_zoho__deals — latest record per Zoho CRM deal.
-- Grain: one row per deal_id.
-- Source: raw_zoho.deals (append-only; payload = full Zoho v2 record).
CREATE OR REPLACE TABLE staging.stg_zoho__deals AS
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
  *,
  forecast_type = 'Won'  AS is_won,
  forecast_type = 'Lost' AS is_lost
FROM classified;
