-- kpi_subscription_audit — monitoring accounts a vendor bills us for, matched
-- against what the customer is actually subscribed to.
-- Grain: one row per (vendor, account). Security Central and Alarm.com today;
-- another vendor joins by adding a CTE that produces the same columns.
--
-- The leak this exists to find: an account still active at the central
-- station whose customer has no live Zoho Billing subscription. We pay the
-- vendor every month and collect nothing.
--
-- TWO FEEDS, ONE ROW PER ACCOUNT
-- Security Central can schedule the "Customer Count" report weekly but not
-- the "All Accounts" export, and only All Accounts carries an address. So:
--   status  comes from staging.stg_vendor__securitycentral_status  (weekly)
--   address comes from staging.stg_vendor__securitycentral_accounts (occasional)
-- They join on contract number — a FULL OUTER JOIN, so an account that
-- appears in only one feed is still audited rather than silently dropped.
-- `status_source` says which feed the status came from, so a stale roster is
-- visible instead of quietly overriding this week's answer. Before any weekly
-- file has landed the status table is empty and every row reads 'roster' —
-- the audit still answers, off the roster's own status, rather than waiting
-- on a feed that arrives once a week.
--
-- A contract can cover more than one account (same subscriber, two panels —
-- 2 of 586 in the 2026-08-27 files). The weekly feed reports status per
-- contract, so both accounts inherit it; the grain stays one row per account.
--
-- Matching to billing is on house number + ZIP (address_key). Street names
-- are written inconsistently between systems ("Dr" vs "Drive"), but house
-- number and ZIP rarely vary. Unmatched rows are reported, not hidden: a low
-- match rate means the key needs work, and treating "unmatched" as "unbilled"
-- without checking would manufacture false leaks.
--
-- Columns:
--   vendor                 'securitycentral' or 'alarmdotcom'
--   account_no             vendor's account number
--   contract_no            vendor's contract number (the join key between feeds)
--   subscriber_name / street_address / city / state / zip
--   account_type           Residential / Commercial / Commercial Fire
--                          (Security Central only; NULL for Alarm.com)
--   vendor_status          the vendor's own word: Active, Deactivated, or
--                          (rarely) Inactive. Only 'Active' counts as active.
--   status_source          how status was learned: 'weekly' (Customer Count
--                          feed), 'roster' (All Accounts export), or 'api'
--                          (Alarm.com Partner API, which has one live feed)
--   status_as_of           when that status was loaded
--   in_roster              FALSE when the account is known only from a feed
--                          that carries no address, so no billing match is
--                          possible. Always TRUE for single-feed vendors.
--   started_on             vendor account start date
--   matched_customer_id    Zoho Billing customer, NULL when no address match
--   match_via              how billing was reached: 'billing' (a Billing
--                          address, currently none) or 'crm' (the CRM
--                          account at that address, matched to Billing by
--                          name). NULL when nothing matched.
--   active_subscriptions   live subscriptions for that customer
--   subscription_amount    their summed recurring amount
--   plan_names             comma-separated plan names, for eyeballing fit
--   finding                see below
--   computed_at            build timestamp
--
-- finding values:
--   BILLED_NO_SUBSCRIPTION  active at vendor, customer matched, no live sub
--                           → the leak: investigate and cancel or re-bill
--   BILLED_NO_MATCH         active at vendor, in the roster, no billing
--                           customer matched → a leak or an address-key miss
--   BILLED_NO_ROSTER        active at vendor but absent from the roster
--                           → request a fresh All Accounts export before
--                             judging; not evidence of a leak on its own
--   OK                      active at vendor with a live subscription
--   DEACTIVATED             not active at the vendor (informational)
CREATE OR REPLACE TABLE marts.kpi_subscription_audit AS
WITH roster AS (
  SELECT * FROM staging.stg_vendor__securitycentral_accounts
),
weekly AS (
  SELECT * FROM staging.stg_vendor__securitycentral_status
),
-- One row per account, weekly status winning over the roster's when both
-- feeds carry it. Contract number is the only field both reports share, so
-- it is the join key; where two accounts share one contract the weekly
-- status applies to both, which is what the vendor means by it.
securitycentral AS (
  SELECT
    COALESCE(r.contract_no, w.contract_no)      AS contract_no,
    COALESCE(r.account_no, w.account_no)        AS account_no,
    COALESCE(w.subscriber_name, r.subscriber_name) AS subscriber_name,
    r.street_address,
    r.city,
    r.state,
    r.zip,
    r.account_type,
    COALESCE(w.status, r.status)                AS vendor_status,
    COALESCE(w.is_active_at_vendor, r.is_active_at_vendor) AS is_active_at_vendor,
    IF(w.contract_no IS NULL, 'roster', 'weekly') AS status_source,
    COALESCE(w.loaded_at, r.loaded_at)          AS status_as_of,
    r.contract_no IS NOT NULL                   AS in_roster,
    COALESCE(r.started_on, w.started_on)        AS started_on,
    r.address_key
  FROM roster r
  FULL OUTER JOIN weekly w ON r.contract_no = w.contract_no
),
-- Alarm.com arrives as one API feed carrying status and address together, so
-- there is no roster/status split to reconcile — the shape below just matches
-- the columns above. stg_alarmdotcom__customers builds the same address_key
-- (house number + ZIP) deliberately, so both vendors match billing the same
-- way. Until Alarm.com is credentialed this CTE is simply empty and every
-- row below is Security Central's.
alarmdotcom AS (
  SELECT
    CAST(NULL AS STRING)                        AS contract_no,
    customer_id                                 AS account_no,
    subscriber_name,
    street_address,
    city,
    state,
    zip,
    CAST(NULL AS STRING)                        AS account_type,
    status                                      AS vendor_status,
    is_active_at_vendor,
    'api'                                       AS status_source,
    loaded_at                                   AS status_as_of,
    TRUE                                        AS in_roster,
    CAST(NULL AS DATE)                          AS started_on,
    address_key
  FROM staging.stg_alarmdotcom__customers
),
-- Columns are listed rather than SELECT *: a UNION matches by position, and
-- most of these are STRING, so reordering one CTE would quietly swap city for
-- state instead of failing. Adding a vendor means adding a CTE and one arm
-- here, both of which name every column.
accounts AS (
  SELECT
    'securitycentral' AS vendor,
    contract_no,
    account_no,
    subscriber_name,
    street_address,
    city,
    state,
    zip,
    account_type,
    vendor_status,
    is_active_at_vendor,
    status_source,
    status_as_of,
    in_roster,
    started_on,
    address_key
  FROM securitycentral
  UNION ALL
  SELECT
    'alarmdotcom' AS vendor,
    contract_no,
    account_no,
    subscriber_name,
    street_address,
    city,
    state,
    zip,
    account_type,
    vendor_status,
    is_active_at_vendor,
    status_source,
    status_as_of,
    in_roster,
    started_on,
    address_key
  FROM alarmdotcom
),
-- REACHING A SUBSCRIPTION FROM AN ADDRESS
-- Zoho Billing knows who is subscribed but not where they live: its list
-- endpoint returns no billing_address at all (0 of 34,248 rows), and its
-- customer records carry no CRM reference either (0 of 34,248), so there is
-- no direct key from a monitoring account to a subscription.
--
-- Zoho CRM has the addresses. So the join goes address -> CRM account ->
-- Billing customer, bridged on the account name, which the two systems write
-- near-identically. Measured 2026-08-30: 380 of 522 unmatched vendor accounts
-- reach a CRM account by address (73%), and 1,300 of 1,379 CRM accounts with
-- an address reach a Billing customer by exact name (94%) — about 357 of the
-- 522 end to end. The rest stay BILLED_NO_MATCH, which is the honest answer
-- for them, not a leak.
--
-- The direct Billing-address path is kept and preferred where it exists, so
-- enabling ZOHOBILLING_CUSTOMER_DETAIL later improves this without a rewrite.
-- `match_via` reports which path answered, so a change in the mix is visible
-- rather than silent.
billing_direct AS (
  SELECT
    CONCAT(
      COALESCE(REGEXP_EXTRACT(billing_address, r'^(\d+)'), ''), '|',
      COALESCE(REGEXP_EXTRACT(billing_zip, r'(\d{5})'), '')
    ) AS address_key,
    customer_id,
    display_name,
    'billing' AS match_via
  FROM staging.stg_zohobilling__customers
  WHERE billing_address IS NOT NULL AND billing_zip IS NOT NULL
),
-- One Billing customer per normalized name; duplicates keep the lowest id.
billing_by_name AS (
  SELECT LOWER(TRIM(display_name)) AS name_key, customer_id, display_name
  FROM staging.stg_zohobilling__customers
  WHERE display_name IS NOT NULL AND TRIM(display_name) != ''
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY LOWER(TRIM(display_name)) ORDER BY customer_id
  ) = 1
),
billing_via_crm AS (
  SELECT a.address_key, b.customer_id, b.display_name, 'crm' AS match_via
  FROM staging.stg_zoho__accounts a
  JOIN billing_by_name b
    ON LOWER(TRIM(a.account_name)) = b.name_key
  WHERE a.address_key != '|' AND a.account_name IS NOT NULL
),
-- One customer per address, direct Billing address winning over the CRM
-- bridge; duplicates within a path keep the lowest id, as elsewhere.
customer_by_address AS (
  SELECT address_key, customer_id, display_name, match_via
  FROM (
    SELECT * FROM billing_direct WHERE address_key != '|'
    UNION ALL
    SELECT * FROM billing_via_crm
  )
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY address_key
    ORDER BY IF(match_via = 'billing', 0, 1), customer_id
  ) = 1
),
subs AS (
  SELECT
    customer_id,
    COUNTIF(is_active) AS active_subscriptions,
    SUM(IF(is_active, COALESCE(amount, 0), 0)) AS subscription_amount,
    STRING_AGG(DISTINCT IF(is_active, plan_name, NULL), ', ') AS plan_names
  FROM staging.stg_zohobilling__subscriptions
  GROUP BY customer_id
)
SELECT
  v.vendor,
  v.account_no,
  v.contract_no,
  v.subscriber_name,
  v.street_address,
  v.city,
  v.state,
  v.zip,
  v.account_type,
  v.vendor_status,
  v.status_source,
  v.status_as_of,
  v.in_roster,
  v.started_on,
  c.customer_id                         AS matched_customer_id,
  c.display_name                        AS matched_customer_name,
  c.match_via,
  COALESCE(s.active_subscriptions, 0)   AS active_subscriptions,
  COALESCE(s.subscription_amount, 0)    AS subscription_amount,
  s.plan_names,
  CASE
    WHEN NOT COALESCE(v.is_active_at_vendor, FALSE) THEN 'DEACTIVATED'
    WHEN NOT v.in_roster THEN 'BILLED_NO_ROSTER'
    WHEN c.customer_id IS NULL THEN 'BILLED_NO_MATCH'
    WHEN COALESCE(s.active_subscriptions, 0) = 0 THEN 'BILLED_NO_SUBSCRIPTION'
    ELSE 'OK'
  END                                   AS finding,
  CURRENT_TIMESTAMP()                   AS computed_at
FROM accounts v
LEFT JOIN customer_by_address c
  ON v.address_key = c.address_key AND v.address_key != '|'
LEFT JOIN subs s ON s.customer_id = c.customer_id;
