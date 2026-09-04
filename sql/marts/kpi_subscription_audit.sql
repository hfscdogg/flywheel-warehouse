-- kpi_subscription_audit — monitoring accounts a vendor bills us for, matched
-- against what the customer is actually subscribed to.
-- Grain: one row per (vendor, account). Security Central, Alarm.com and
-- Parasol today; another vendor joins by adding a CTE producing the same
-- columns.
--
-- THREE VENDORS, THREE SERVICES — OVERLAP IS NOT A FINDING
-- Security Central is security monitoring, Alarm.com is interactive smart-home
-- services, Parasol is 24/7 remote support. They are wholly separate products,
-- so one property legitimately appears under all three and we legitimately pay
-- all three for it. Do not dedupe across vendors: an address showing up three
-- times is three real costs, and collapsing them would hide two of them. The
-- unit of the audit is the (vendor, account) pair, never the address.
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
-- Matching to billing is on house number + street name + ZIP (address_key),
-- the street name suffix-stripped so "Dr" and "Drive" agree. Alarm.com has a
-- second route: its export carries Security Central's account number, an
-- exact key, so a row the address misses can borrow the match of the Security
-- Central account it is the same property as (`match_via = 'sc_account'`).
-- Street names
-- are written inconsistently between systems ("Dr" vs "Drive"), but house
-- number and ZIP rarely vary. Unmatched rows are reported, not hidden: a low
-- match rate means the key needs work, and treating "unmatched" as "unbilled"
-- without checking would manufacture false leaks.
--
-- Column meanings are declared at the end of this file (ALTER COLUMN ...
-- SET OPTIONS). BigQuery serves them to agents through hermes-mcp, so that
-- is the one copy — do not restate them here.
CREATE OR REPLACE TABLE marts.kpi_subscription_audit
OPTIONS (description = """
Monitoring accounts that three vendors bill Livewire for, matched to Zoho Billing to find accounts we pay for with no live customer subscription.
ONE ROW PER (vendor, account). The same property legitimately appears under several vendors because they sell different services: Security Central is security monitoring, Alarm.com is interactive smart-home, Parasol is 24/7 remote support. Never dedupe across vendors; a property on all three is three real costs.
The leak is finding = BILLED_NO_SUBSCRIPTION. BILLED_NO_MATCH means no billing customer could be found, which is unknown, not a proven leak.
Before acting on any row check name_overlaps: FALSE means the address probably matched the wrong household.
vendor_monthly_cost is populated for Parasol ONLY. Security Central and Alarm.com publish no per-account rate, so a SUM across vendors understates the true cost by roughly two thirds and must be labelled as Parasol-only.
No live subscription means none in Zoho Billing. A customer paying by check or outside Zoho looks identical here and must be confirmed by a person before anything is cancelled.
""")
AS
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
    r.address_key,
    -- Security Central's feeds carry no per-account price; only Parasol's
    -- invoice does. NULL means "we do not know what this one costs", not
    -- "it is free".
    CAST(NULL AS NUMERIC)                       AS vendor_monthly_cost
  FROM roster r
  FULL OUTER JOIN weekly w ON r.contract_no = w.contract_no
),
-- Alarm.com comes from the dealer-site "Custom List" export rather than the
-- Partner API: the export landed first while the API waits on a working
-- client_id, and it is the better feed anyway — an address on every row, and
-- Security Central's own account number on 502 of 597, which is an exact
-- cross-vendor key where the address match is only an approximation. When
-- the API is credentialed its staging model joins in here; today it is empty
-- and the export is the whole picture.
alarmdotcom AS (
  SELECT
    sc_account_no                               AS contract_no,
    customer_id                                 AS account_no,
    subscriber_name,
    street_address,
    city,
    state,
    zip,
    service_package                             AS account_type,
    IF(is_active_at_vendor, 'Active', 'Pending Termination')
                                                AS vendor_status,
    is_active_at_vendor,
    'export'                                    AS status_source,
    loaded_at                                   AS status_as_of,
    TRUE                                        AS in_roster,
    started_on,
    address_key,
    CAST(NULL AS NUMERIC)                       AS vendor_monthly_cost
  FROM staging.stg_vendor__alarmdotcom_accounts
),
-- Parasol bills from an invoice that doubles as the roster, so every account
-- is active by construction and every one carries its own rate. That rate is
-- what makes a Parasol finding actionable without a lookup: the monthly cost
-- of the leak is on the row.
parasol AS (
  SELECT
    CAST(NULL AS STRING)                        AS contract_no,
    account_no,
    subscriber_name,
    street_address,
    city,
    state,
    zip,
    service_tier                                AS account_type,
    'Billed'                                    AS vendor_status,
    is_active_at_vendor,
    'invoice'                                   AS status_source,
    loaded_at                                   AS status_as_of,
    TRUE                                        AS in_roster,
    CAST(NULL AS DATE)                          AS started_on,
    address_key,
    monthly_rate                                AS vendor_monthly_cost
  FROM staging.stg_vendor__parasol_accounts
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
    address_key,
    vendor_monthly_cost
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
    address_key,
    vendor_monthly_cost
  FROM alarmdotcom
  UNION ALL
  SELECT
    'parasol' AS vendor,
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
    address_key,
    vendor_monthly_cost
  FROM parasol
),
billing_direct AS (
  SELECT
    CONCAT(
      COALESCE(REGEXP_EXTRACT(billing_address, r'^\s*(\d+)'), ''), '|',
      COALESCE(REGEXP_REPLACE(REGEXP_REPLACE(
        LOWER(COALESCE(REGEXP_EXTRACT(billing_address, r'^\s*\d+\s+(.*)$'), '')),
        r'\b(st|street|rd|road|dr|drive|ln|lane|ct|court|cir|circle|pl|place|ave|avenue|blvd|boulevard|way|ter|terrace|trl|trail|pkwy|parkway|hwy|highway|apt|unit|ste|suite)\b\.?', ''),
        r'[^a-z0-9]+', ''), ''), '|',
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
),
-- Alarm.com's export carries Security Central's own account number on 502 of
-- 597 rows (CS Account Prefix + CS Account Number, e.g. A1651-1047), and the
-- alarmdotcom CTE above puts it in contract_no. This maps that number to the
-- Security Central account's address, so an Alarm.com row whose own address
-- reaches no customer can borrow the address of the Security Central account
-- it is provably the same property as.
--
-- One row per account number: two Security Central rows can share one (the
-- same account with two contacts), and without this a single Alarm.com
-- account would fan out into several audit rows.
sc_account_address AS (
  SELECT account_no, address_key
  FROM securitycentral
  WHERE account_no IS NOT NULL AND address_key != '|'
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY account_no ORDER BY address_key
  ) = 1
),
-- Each account resolved to a Billing customer, by its own address first and
-- by the Security Central bridge second. Order matters: the address match is
-- a heuristic and the account number is an identifier, but an address that
-- already found a customer found it for THIS property, whereas the bridge
-- asserts two vendors' records are the same property. Direct-first keeps a
-- vendor's own row authoritative and uses the bridge only where it adds
-- something — measured at 15 accounts on the 2026-08-31 data, all of them
-- previously BILLED_NO_MATCH.
--
-- `v.*` is safe here where the UNION above lists every column: this selects
-- from one source, so there is no positional hazard to guard against.
matched AS (
  SELECT
    v.*,
    COALESCE(direct.customer_id, bridged.customer_id)     AS customer_id,
    COALESCE(direct.display_name, bridged.display_name)   AS display_name,
    CASE
      WHEN direct.customer_id IS NOT NULL THEN direct.match_via
      WHEN bridged.customer_id IS NOT NULL THEN 'sc_account'
    END                                                   AS match_via
  FROM accounts v
  LEFT JOIN customer_by_address direct
    ON v.address_key = direct.address_key AND v.address_key != '|'
  LEFT JOIN sc_account_address bridge
    ON v.vendor = 'alarmdotcom' AND v.contract_no = bridge.account_no
  LEFT JOIN customer_by_address bridged
    ON bridge.address_key = bridged.address_key
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
  v.vendor_monthly_cost,
  v.customer_id                         AS matched_customer_id,
  v.display_name                        AS matched_customer_name,
  v.match_via,
  -- Does any word of the vendor's subscriber name appear in the matched
  -- customer's? Agreement is weak evidence; DISAGREEMENT is strong evidence
  -- of a bad match, and that is what this is for. Never act on a
  -- BILLED_NO_SUBSCRIPTION row where this is FALSE without checking it by
  -- hand — the key is an address heuristic, not an identifier.
  (SELECT LOGICAL_OR(LENGTH(t) >= 3 AND STRPOS(LOWER(v.display_name), t) > 0)
   FROM UNNEST(SPLIT(LOWER(REGEXP_REPLACE(
     COALESCE(v.subscriber_name, ''), r'[^a-zA-Z ]', '')), ' ')) AS t)
                                        AS name_overlaps,
  COALESCE(s.active_subscriptions, 0)   AS active_subscriptions,
  COALESCE(s.subscription_amount, 0)    AS subscription_amount,
  s.plan_names,
  CASE
    WHEN NOT COALESCE(v.is_active_at_vendor, FALSE) THEN 'DEACTIVATED'
    WHEN NOT v.in_roster THEN 'BILLED_NO_ROSTER'
    WHEN v.customer_id IS NULL THEN 'BILLED_NO_MATCH'
    WHEN COALESCE(s.active_subscriptions, 0) = 0 THEN 'BILLED_NO_SUBSCRIPTION'
    ELSE 'OK'
  END                                   AS finding,
  CURRENT_TIMESTAMP()                   AS computed_at
FROM matched v
LEFT JOIN subs s ON s.customer_id = v.customer_id;

-- What agents read. hermes-mcp serves these descriptions verbatim through
-- get_table_schema, and a column without one is a column Hermes will guess
-- at. 06-transform.sh fails the run if any mart column has no description.
-- Renaming a column above without updating it here fails here, loudly.
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN vendor
  SET OPTIONS (description = "Which vendor bills us for this account: securitycentral (security monitoring), alarmdotcom (interactive smart-home) or parasol (24/7 remote support). Different services, so one property on all three is normal.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN account_no
  SET OPTIONS (description = "The vendor's own account number for this account.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN contract_no
  SET OPTIONS (description = "Security Central: the contract number. Alarm.com: Security Central's account number for the same property, an exact cross-vendor key. Parasol: NULL.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN subscriber_name
  SET OPTIONS (description = "Name on the vendor's record for this account.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN street_address
  SET OPTIONS (description = "Service address per the vendor.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN city
  SET OPTIONS (description = "Service city per the vendor.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN state
  SET OPTIONS (description = "Service state per the vendor.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN zip
  SET OPTIONS (description = "Service ZIP per the vendor; may carry ZIP+4 for Alarm.com.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN account_type
  SET OPTIONS (description = "Security Central: Residential, Commercial or Commercial Fire. Alarm.com: the service package. Parasol: the service tier, Essential or Enhanced.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN vendor_status
  SET OPTIONS (description = "The vendor's own status word. Only Active counts as active; Deactivated and Inactive do not.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN status_source
  SET OPTIONS (description = "Where vendor_status came from: weekly (Security Central weekly Customer Count feed), roster (Security Central All Accounts export, used when the weekly feed has no row), export (Alarm.com dealer-site export), invoice (Parasol monthly invoice).");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN status_as_of
  SET OPTIONS (description = "When that status was loaded into the warehouse (UTC).");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN in_roster
  SET OPTIONS (description = "FALSE when the account is known only from a feed that carries no address, so no billing match was possible. TRUE for every Alarm.com and Parasol row.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN started_on
  SET OPTIONS (description = "Account start date per the vendor. NULL for Parasol, whose invoice does not carry one.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN vendor_monthly_cost
  SET OPTIONS (description = "What this vendor charges for THIS account per month, USD. Parasol ONLY. NULL for Security Central and Alarm.com means the vendor does not tell us the rate, not that the account is free.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN matched_customer_id
  SET OPTIONS (description = "Zoho Billing customer matched to this account. NULL when no match was found.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN matched_customer_name
  SET OPTIONS (description = "Display name of the matched Zoho Billing customer.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN match_via
  SET OPTIONS (description = "How the billing customer was reached: crm (vendor address to a Zoho CRM account, then to Billing by customer name), billing (a Billing address directly), sc_account (Alarm.com only: through Security Central's account number, an exact key rather than an address guess). NULL when unmatched.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN name_overlaps
  SET OPTIONS (description = "TRUE when a word of the vendor's subscriber name appears in the matched customer's name. FALSE is a strong signal the address matched the WRONG household; never act on such a row without checking it by hand.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN active_subscriptions
  SET OPTIONS (description = "Number of live Zoho Billing subscriptions for the matched customer. 0 when unmatched.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN subscription_amount
  SET OPTIONS (description = "Summed recurring amount of those live subscriptions, USD.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN plan_names
  SET OPTIONS (description = "Comma-separated names of the live plans, for judging fit.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN finding
  SET OPTIONS (description = "OK: active at the vendor with a live subscription. BILLED_NO_SUBSCRIPTION: active at the vendor, customer matched, no live subscription; the leak. BILLED_NO_MATCH: active at the vendor but no billing customer could be matched; unknown, not a proven leak. BILLED_NO_ROSTER: active but absent from the roster; request a fresh export before judging. DEACTIVATED: not active at the vendor; informational.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN computed_at
  SET OPTIONS (description = "When this row was built (UTC).");
