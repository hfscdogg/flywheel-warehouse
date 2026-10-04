-- stg_zoho__meetings — latest record per Zoho CRM meeting.
-- Grain: one row per meeting_id.
-- Source: raw_zoho.events (append-only; payload = full Zoho v2 record).
-- Events is the API name of the Meetings module. Technicians log the hours
-- they work on a job as meetings on its deal, in Duration (Man Hrs): Zoho
-- CRM, not D-Tools, is where hours worked live. Field names verified against
-- the first load, 2026-10-04 (58,377 meetings).
--
-- Notes, phone numbers, addresses and participants stay in raw: nothing here
-- needs them, and every column below is one an agent may read.
CREATE OR REPLACE TABLE staging.stg_zoho__meetings
OPTIONS (description = """
Zoho CRM meetings, one row per meeting. Technicians log the hours they work on a job as a meeting on its deal: man_hours is that time, and it is the warehouse's only record of hours worked (D-Tools records hours sold, not worked).
is_job_hours marks the meetings Zoho's own Actual vs Billed Hours report counts: event type Install - Warranty / Punchout or Finish-Out, status Ready to Bill or Complete. Sum man_hours over those for hours worked on a deal; other meetings are sales visits, service calls and the like.
deal_id is NULL for a meeting not attached to a deal.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_zoho.events
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
),
fields AS (
  SELECT
    _source_id                                                       AS meeting_id,
    -- What_Id is the record the meeting hangs off; $se_module says which
    -- module that record is in. Only a Deal is a job.
    IF(JSON_VALUE(payload, '$."$se_module"') = 'Deals',
       JSON_VALUE(payload, '$.What_Id.id'), NULL)                    AS deal_id,
    JSON_VALUE(payload, '$."$se_module"')                            AS attached_to,
    TRIM(JSON_VALUE(payload, '$.Event_Type'))                        AS event_type,
    TRIM(JSON_VALUE(payload, '$.Event_Status'))                      AS event_status,
    SAFE_CAST(JSON_VALUE(payload, '$.Start_DateTime') AS TIMESTAMP)  AS start_at,
    SAFE_CAST(JSON_VALUE(payload, '$.End_DateTime') AS TIMESTAMP)    AS end_at,
    SAFE_CAST(JSON_VALUE(payload, '$.Duration_Man_Hrs') AS NUMERIC)  AS man_hours,
    SAFE_CAST(JSON_VALUE(payload, '$.Num_Resources') AS NUMERIC)     AS technicians,
    JSON_VALUE(payload, '$.Owner.name')                              AS owner_name,
    SAFE_CAST(JSON_VALUE(payload, '$.Modified_Time') AS TIMESTAMP)   AS modified_at,
    _loaded_at                                                       AS loaded_at
  FROM latest
)
SELECT
  meeting_id,
  deal_id,
  attached_to,
  event_type,
  event_status,
  start_at,
  end_at,
  man_hours,
  technicians,
  owner_name,
  -- The filter in zoho-reference/qt_weekly_expected_revenue_by_potential.sql,
  -- the Zoho Analytics query behind Actual vs Billed Hours. Its list spells
  -- one type ' Finish Out' with a leading space; event_type is trimmed above
  -- so either spelling counts.
  event_type IN ('Install - Warranty / Punchout', 'Finish Out', 'Finish-Out ($$$)')
    AND event_status IN ('Ready to Bill', 'Complete')                AS is_job_hours,
  modified_at,
  loaded_at
FROM fields;

ALTER TABLE staging.stg_zoho__meetings ALTER COLUMN meeting_id
  SET OPTIONS (description = "Zoho CRM meeting id; the key.");
ALTER TABLE staging.stg_zoho__meetings ALTER COLUMN deal_id
  SET OPTIONS (description = "Zoho CRM deal the meeting is logged against; joins stg_zoho__deals.deal_id. NULL when the meeting hangs off a contact, account or nothing.");
ALTER TABLE staging.stg_zoho__meetings ALTER COLUMN attached_to
  SET OPTIONS (description = "Zoho module of the record the meeting is attached to, e.g. Deals or Contacts.");
ALTER TABLE staging.stg_zoho__meetings ALTER COLUMN event_type
  SET OPTIONS (description = "Meeting type picklist, e.g. Finish-Out ($$$) or Install - Warranty / Punchout.");
ALTER TABLE staging.stg_zoho__meetings ALTER COLUMN event_status
  SET OPTIONS (description = "Meeting status picklist, e.g. Complete or Ready to Bill.");
ALTER TABLE staging.stg_zoho__meetings ALTER COLUMN start_at
  SET OPTIONS (description = "When the meeting starts.");
ALTER TABLE staging.stg_zoho__meetings ALTER COLUMN end_at
  SET OPTIONS (description = "When the meeting ends.");
ALTER TABLE staging.stg_zoho__meetings ALTER COLUMN man_hours
  SET OPTIONS (description = "Duration (Man Hrs): hours worked, summed across the technicians on the visit. The hours-worked measure.");
ALTER TABLE staging.stg_zoho__meetings ALTER COLUMN technicians
  SET OPTIONS (description = "Number of technicians on the visit (Num Resources).");
ALTER TABLE staging.stg_zoho__meetings ALTER COLUMN owner_name
  SET OPTIONS (description = "Zoho user who owns the meeting.");
ALTER TABLE staging.stg_zoho__meetings ALTER COLUMN is_job_hours
  SET OPTIONS (description = "TRUE for the meetings Zoho's Actual vs Billed Hours report counts as hours worked on a job: type Install - Warranty / Punchout or Finish-Out, status Ready to Bill or Complete.");
ALTER TABLE staging.stg_zoho__meetings ALTER COLUMN modified_at
  SET OPTIONS (description = "Last modified time in Zoho.");
ALTER TABLE staging.stg_zoho__meetings ALTER COLUMN loaded_at
  SET OPTIONS (description = "When the warehouse loaded this version of the record.");
