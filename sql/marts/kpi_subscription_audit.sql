-- kpi_subscription_audit — monitoring accounts a vendor bills us for, matched
-- against what the customer is actually subscribed to.
-- Grain: one row per vendor account (Security Central today; other vendors
-- join here as their rosters land).
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
-- visible instead of quietly overriding this week's answer.
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
--   vendor                 monitoring vendor (constant per source table)
--   account_no             vendor's account number
--   contract_no            vendor's contract number (the join key between feeds)
--   subscriber_name / street_address / city / state / zip
--   account_type           Residential / Commercial / Commercial Fire
--   vendor_status          the vendor's own word: Active, Deactivated, or
--                          (rarely) Inactive. Only 'Active' counts as active.
--   status_source          'weekly' (Customer Count) or 'roster' (All Accounts)
--   status_as_of           when that status was loaded
--   in_roster              FALSE when the All Accounts export has no row for
--                          this account → no address, so no billing match
--   started_on             vendor account start date
--   matched_customer_id    Zoho Billing customer, NULL when no address match
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
accounts AS (
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
billing_customers AS (
  SELECT
    customer_id,
    display_name,
    CONCAT(
      COALESCE(REGEXP_EXTRACT(billing_address, r'^(\d+)'), ''), '|',
      COALESCE(REGEXP_EXTRACT(billing_zip, r'(\d{5})'), '')
    ) AS address_key
  FROM staging.stg_zohobilling__customers
  WHERE billing_address IS NOT NULL AND billing_zip IS NOT NULL
),
-- One customer per address; duplicates keep the lowest id, as elsewhere.
customer_by_address AS (
  SELECT address_key, customer_id, display_name
  FROM billing_customers
  WHERE address_key != '|'
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY address_key ORDER BY customer_id
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
  'securitycentral'                     AS vendor,
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
