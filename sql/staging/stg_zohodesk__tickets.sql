-- stg_zohodesk__tickets — latest record per Zoho Desk ticket.
-- Grain: one row per ticket id.
-- Source: raw_zohodesk.tickets (append-only; payload = Desk v1 ticket as the
-- /tickets/search endpoint returns it).
--
-- Desk is the ticket system of record. The CRM Cases module gets a copy of
-- each web consult booking that nobody updates (every sales case since
-- 2026-09-07 sat "Unclaimed" in CRM on 2026-11-04 while Desk had them
-- closed), so status, assignee and closed time are read from here and never
-- from stg_zoho-side cases.
--
-- Field paths are written from the Desk API docs, NOT yet verified against
-- live payloads: the first ingest lands them and probe.py reads them back.
-- Custom fields arrive under $.cf as cf_<name>; none are extracted until the
-- live shape is seen.
CREATE OR REPLACE TABLE staging.stg_zohodesk__tickets
OPTIONS (description = """
Zoho Desk tickets, one row per ticket: every support request and web consult booking, with its department, status, assignee and when it closed. Desk is the system of record for tickets; the CRM Cases copy is never updated, so use this table for anything about ticket status or outcome. A sales consult booking has subject starting 'Web to Case - New Sales Consultation Booking'. is_closed is the test for a finished ticket.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_zohodesk.tickets
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
),
fields AS (
  SELECT
    _source_id                                                        AS ticket_id,
    JSON_VALUE(payload, '$.ticketNumber')                             AS ticket_number,
    JSON_VALUE(payload, '$.subject')                                  AS subject,
    JSON_VALUE(payload, '$.status')                                   AS status,
    JSON_VALUE(payload, '$.statusType')                               AS status_type,
    JSON_VALUE(payload, '$.priority')                                 AS priority,
    JSON_VALUE(payload, '$.channel')                                  AS channel,
    JSON_VALUE(payload, '$.category')                                 AS category,
    JSON_VALUE(payload, '$.subCategory')                              AS sub_category,
    JSON_VALUE(payload, '$.classification')                           AS classification,
    JSON_VALUE(payload, '$.departmentId')                             AS department_id,
    JSON_VALUE(payload, '$.assigneeId')                               AS assignee_id,
    JSON_VALUE(payload, '$.teamId')                                   AS team_id,
    JSON_VALUE(payload, '$.contactId')                                AS contact_id,
    JSON_VALUE(payload, '$.accountId')                                AS account_id,
    LOWER(JSON_VALUE(payload, '$.email'))                             AS email,
    JSON_VALUE(payload, '$.phone')                                    AS phone,
    JSON_VALUE(payload, '$.webUrl')                                   AS web_url,
    SAFE_CAST(JSON_VALUE(payload, '$.isSpam') AS BOOL)                AS is_spam,
    SAFE_CAST(JSON_VALUE(payload, '$.createdTime') AS TIMESTAMP)      AS created_at,
    SAFE_CAST(JSON_VALUE(payload, '$.modifiedTime') AS TIMESTAMP)     AS modified_at,
    SAFE_CAST(JSON_VALUE(payload, '$.closedTime') AS TIMESTAMP)       AS closed_at,
    SAFE_CAST(JSON_VALUE(payload, '$.dueDate') AS TIMESTAMP)          AS due_at,
    _loaded_at                                                        AS loaded_at
  FROM latest
)
SELECT
  ticket_id,
  ticket_number,
  subject,
  status,
  status_type,
  priority,
  channel,
  category,
  sub_category,
  classification,
  department_id,
  assignee_id,
  team_id,
  contact_id,
  account_id,
  email,
  phone,
  web_url,
  is_spam,
  created_at,
  modified_at,
  closed_at,
  due_at,
  loaded_at,
  -- Desk groups every status into Open, On Hold or Closed (statusType);
  -- closedTime is only stamped once a ticket reaches a Closed status.
  COALESCE(status_type = 'Closed', closed_at IS NOT NULL)             AS is_closed,
  STARTS_WITH(subject, 'Web to Case - New Sales Consultation Booking') AS is_sales_consult
FROM fields;

ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN ticket_id
  SET OPTIONS (description = "Zoho Desk ticket id; the key.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN ticket_number
  SET OPTIONS (description = "The human ticket number shown in Desk and in notification emails.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN subject
  SET OPTIONS (description = "Ticket subject. Web consult bookings start 'Web to Case - New Sales Consultation Booking'.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN status
  SET OPTIONS (description = "Desk status as the team named it (Open, Closed, On Hold and any custom ones); status_type groups them.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN status_type
  SET OPTIONS (description = "Open, On Hold or Closed: Desk's grouping of status. is_closed reduces it to a boolean.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN priority
  SET OPTIONS (description = "Priority as set in Desk (Low, Medium, High, Urgent), NULL when none.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN channel
  SET OPTIONS (description = "How the ticket arrived: Email, Phone, Web, Chat, Forums and so on.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN category
  SET OPTIONS (description = "Ticket category picked by the agent, when the department uses one.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN sub_category
  SET OPTIONS (description = "Sub-category under category, when used.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN classification
  SET OPTIONS (description = "Desk classification (Question, Problem, Feature, Others), when set.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN department_id
  SET OPTIONS (description = "Department the ticket sits in; joins to stg_zohodesk__departments.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN assignee_id
  SET OPTIONS (description = "Agent the ticket is assigned to; joins to stg_zohodesk__agents. NULL when unassigned.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN team_id
  SET OPTIONS (description = "Team the ticket is assigned to, when teams are used; NULL otherwise.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN contact_id
  SET OPTIONS (description = "Desk contact who raised the ticket.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN account_id
  SET OPTIONS (description = "Desk account (company) the contact belongs to, when any.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN email
  SET OPTIONS (description = "Requester email on the ticket, lower-cased; the key for matching a ticket to a CRM lead or contact.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN phone
  SET OPTIONS (description = "Requester phone on the ticket.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN web_url
  SET OPTIONS (description = "Link to the ticket in Zoho Desk.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN is_spam
  SET OPTIONS (description = "TRUE when Desk marked the ticket as spam; leave these out of any count.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN created_at
  SET OPTIONS (description = "When the ticket was created in Desk (UTC).");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN modified_at
  SET OPTIONS (description = "When the ticket was last changed in Desk (UTC).");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN closed_at
  SET OPTIONS (description = "When the ticket was closed in Desk (UTC); NULL while open.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN due_at
  SET OPTIONS (description = "Due date Desk set from the SLA, when any (UTC).");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN is_closed
  SET OPTIONS (description = "TRUE when the ticket is in a Closed status or carries a closed time. Use this, not status, for the finished test.");
ALTER TABLE staging.stg_zohodesk__tickets ALTER COLUMN is_sales_consult
  SET OPTIONS (description = "TRUE when the ticket is a web sales consultation booking (15-minute phone or in-person); the unit behind the weekly consult count.");
