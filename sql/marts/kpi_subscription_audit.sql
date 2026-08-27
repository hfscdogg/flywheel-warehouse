-- kpi_subscription_audit — monitoring accounts a vendor bills us for, matched
-- against what the customer is actually subscribed to.
-- Grain: one row per vendor account (Security Central today; other vendors
-- join here as their rosters land).
--
-- The leak this exists to find: an account still active at the central
-- station whose customer has no live Zoho Billing subscription. We pay the
-- vendor every month and collect nothing.
--
-- Matching is on house number + ZIP (address_key). Street names are written
-- inconsistently between systems ("Dr" vs "Drive"), but house number and ZIP
-- rarely vary. Unmatched rows are reported, not hidden: a low match rate
-- means the key needs work, and treating "unmatched" as "unbilled" without
-- checking would manufacture false leaks.
--
-- Columns:
--   vendor                 monitoring vendor (constant per source table)
--   account_no             vendor's account number
--   subscriber_name / street_address / city / state / zip
--   account_type           Residential / Commercial / Commercial Fire
--   vendor_status          Active / Deactivated at the vendor
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
--   BILLED_NO_MATCH         active at vendor, no billing customer matched
--                           → either a leak or an address-key miss; check first
--   OK                      active at vendor with a live subscription
--   DEACTIVATED             not active at the vendor (informational)
CREATE OR REPLACE TABLE marts.kpi_subscription_audit AS
WITH vendor_accounts AS (
  SELECT * FROM staging.stg_vendor__securitycentral_accounts
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
  v.subscriber_name,
  v.street_address,
  v.city,
  v.state,
  v.zip,
  v.account_type,
  v.status                              AS vendor_status,
  v.started_on,
  c.customer_id                         AS matched_customer_id,
  c.display_name                        AS matched_customer_name,
  COALESCE(s.active_subscriptions, 0)   AS active_subscriptions,
  COALESCE(s.subscription_amount, 0)    AS subscription_amount,
  s.plan_names,
  CASE
    WHEN NOT v.is_active_at_vendor THEN 'DEACTIVATED'
    WHEN c.customer_id IS NULL THEN 'BILLED_NO_MATCH'
    WHEN COALESCE(s.active_subscriptions, 0) = 0 THEN 'BILLED_NO_SUBSCRIPTION'
    ELSE 'OK'
  END                                   AS finding,
  CURRENT_TIMESTAMP()                   AS computed_at
FROM vendor_accounts v
LEFT JOIN customer_by_address c
  ON v.address_key = c.address_key AND v.address_key != '|'
LEFT JOIN subs s ON s.customer_id = c.customer_id;
