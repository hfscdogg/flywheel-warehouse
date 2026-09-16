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
-- RUN ORDER
-- This mart now reads two billing tables that did not exist before, and
-- 06-transform.sh skips a mart whose inputs have never been built. The
-- vendordrop ingest creates a landing table per known report on every run
-- whether or not anyone uploaded anything, so running it once ahead of the
-- transform is enough — which is the order the scheduled workflows already
-- run in (06:50, then 07:00). Run the transform first on a fresh clone and
-- the audit is skipped with a message naming the missing table, not built
-- wrong.
--
-- WHAT EACH ACCOUNT COSTS
-- All three vendors now price their own accounts, each from a separate
-- billing feed, and each bills one account as several lines: Security
-- Central as monitoring plus scheduled tests, Alarm.com as a base fee plus a
-- row per add-on, Parasol as one line item. Those are summed to the account
-- before they reach this table, so vendor_monthly_cost is per account and
-- summing it across vendors is a real total rather than the Parasol-only
-- figure this mart used to report.
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
-- Two more keys sit between the addresses and the name: Alarm.com's
-- export carries an email on every row and Security Central's a contact
-- phone on most, and either matched against Zoho Billing's own email and
-- phone reaches 37 accounts no address or name could
-- (`match_via = 'email'` / `'phone'`).
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
vendor_monthly_cost is populated for all three vendors, each from that vendor's own billing feed, so summing it across vendors gives a real total. It is NULL where a vendor's billing feed has not been uploaded or carries no row for the account, which means the cost is unknown, never that the account is free.
No live subscription means none in Zoho Billing. A customer paying by check or outside Zoho looks identical here and must be confirmed by a person before anything is cancelled.
Check match_via before acting: name means the account was matched only because its subscriber name matched exactly one Billing customer, with no address and no contact detail agreeing. That is the weakest link in the table and two unrelated households can share a name. email and phone are stronger than name and weaker than an address.
READ qbo_monitoring_revenue BEFORE QUOTING THE LEAK. Zoho Billing is not the whole picture: Livewire's customers all flow into QuickBooks and check payers land only there, so a customer can be absent from Billing and still be invoiced for monitoring every month. qbo_monitoring_revenue is TRUE when the account's QuickBooks customer has been invoiced on a monitoring income account (Security Monitoring, Invision Monitoring, or a security agreement discount) on an invoice that was not voided. Measured 2026-09-16: 128 of the 229 BILLED_NO_SUBSCRIPTION rows are TRUE, so roughly half the leak list is accounted for and the unexplained remainder is about 101 accounts and $14,000 a year, not $31,752.
qbo_monitoring_revenue is ADVISORY and is NOT part of finding. finding still asks Zoho Billing alone, so a BILLED_NO_SUBSCRIPTION row with qbo_monitoring_revenue TRUE is a row the finding gets wrong. Report both; never quote the BILLED_NO_SUBSCRIPTION total without saying how much of it this column explains.
FALSE is not proof of a leak. It means no monitoring revenue was found for a QuickBooks customer this account could be resolved to, which includes the case where it reached no QuickBooks customer at all (qbo_customer_id IS NULL, 51 of the 229). Some customers also pay Security Central directly and will still surface here; that needs a known exclusion list Livewire has not supplied yet.
The QuickBooks customer is resolved independently of the Billing one, from the account's own address, email, phone and name, so the two can disagree. Judge the QuickBooks match by qbo_match_via and qbo_name_overlaps, exactly as you would judge the Billing match by match_via and name_overlaps.
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
sc_identity AS (
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
-- What Security Central charges for each account, from the monthly recurring
-- report — the only feed of theirs that carries a price at all. An account is
-- billed as several resource lines (monitoring, plus any scheduled tests), so
-- the account's cost is their sum. monthly_amount is already monthly on every
-- line including the quarterly and yearly ones; see the staging model.
sc_billing AS (
  SELECT
    account_no,
    SUM(monthly_amount)     AS monthly_cost,
    MAX(loaded_at)          AS loaded_at,
    -- Carried so a billing-only account arrives with a name on it. Those are
    -- the rows the audit most wants a human to look at, and an unnamed one
    -- cannot be checked against anything.
    ANY_VALUE(subscriber_name) AS subscriber_name
  FROM staging.stg_vendor__securitycentral_recurring
  WHERE account_no IS NOT NULL AND account_no != ''
  GROUP BY account_no
),
-- FULL OUTER, like the join above and for the same reason: an account
-- Security Central bills us for that reaches neither the roster nor the
-- weekly feed is the most expensive kind of leak there is, and an inner join
-- would drop exactly those rows. They arrive with in_roster FALSE, which is
-- what BILLED_NO_ROSTER exists to report.
--
-- A billing-only row is active by construction — we are being invoiced for it
-- this month — which is the same reading the Parasol CTE below takes of its
-- invoice.
--
-- The QUALIFY guards the sum: where two identity rows share one account
-- number, both would otherwise carry the account's full cost and a SUM across
-- the mart would count it twice. The cost lands on one row; the other reads
-- NULL, meaning "not known here", exactly as it did before this feed existed.
securitycentral AS (
  SELECT
    i.contract_no,
    COALESCE(i.account_no, b.account_no)        AS account_no,
    COALESCE(i.subscriber_name, b.subscriber_name) AS subscriber_name,
    i.street_address,
    i.city,
    i.state,
    i.zip,
    i.account_type,
    COALESCE(i.vendor_status, 'Billed')         AS vendor_status,
    COALESCE(i.is_active_at_vendor, TRUE)       AS is_active_at_vendor,
    COALESCE(i.status_source, 'recurring')      AS status_source,
    COALESCE(i.status_as_of, b.loaded_at)       AS status_as_of,
    COALESCE(i.in_roster, FALSE)                AS in_roster,
    i.started_on,
    COALESCE(i.address_key, '|')                AS address_key,
    IF(ROW_NUMBER() OVER (
         PARTITION BY COALESCE(i.account_no, b.account_no)
         ORDER BY i.contract_no NULLS LAST
       ) = 1, b.monthly_cost, NULL)             AS vendor_monthly_cost
  FROM sc_identity i
  FULL OUTER JOIN sc_billing b ON i.account_no = b.account_no
),
-- Alarm.com comes from the dealer-site "Custom List" export rather than the
-- Partner API: the export landed first while the API waits on a working
-- client_id, and it is the better feed anyway — an address on every row, and
-- Security Central's own account number on 502 of 597, which is an exact
-- cross-vendor key where the address match is only an approximation. When
-- the API is credentialed its staging model joins in here; today it is empty
-- and the export is the whole picture.
-- Alarm.com bills an account as a base fee plus a row per add-on switched on
-- for it, between 1 and 31 rows, so the account's cost is their sum. Only the
-- recurring rows count: the same export carries prorations and activation
-- fees, which are real money but not a monthly rate.
adc_billing AS (
  SELECT customer_id, SUM(charge_amount) AS monthly_cost
  FROM staging.stg_vendor__alarmdotcom_billing
  WHERE is_recurring
  GROUP BY customer_id
),
alarmdotcom AS (
  SELECT
    a.sc_account_no                             AS contract_no,
    a.customer_id                               AS account_no,
    a.subscriber_name,
    a.street_address,
    a.city,
    a.state,
    a.zip,
    a.service_package                           AS account_type,
    IF(a.is_active_at_vendor, 'Active', 'Pending Termination')
                                                AS vendor_status,
    a.is_active_at_vendor,
    'export'                                    AS status_source,
    a.loaded_at                                 AS status_as_of,
    TRUE                                        AS in_roster,
    a.started_on,
    a.address_key,
    -- LEFT, not inner: an account on the dealer list with no charge row is
    -- still an account, and reads NULL rather than disappearing.
    b.monthly_cost                              AS vendor_monthly_cost
  FROM staging.stg_vendor__alarmdotcom_accounts a
  LEFT JOIN adc_billing b ON a.customer_id = b.customer_id
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
-- NOT EVERY ROW IN THE BILLING BOOK IS A CUSTOMER
-- Zoho Billing carries internal records alongside real customers: a generic
-- "service" record, and staff-created ones marked in the display name
-- ("Dayna Andersen **TEST**"). They are ordinary rows with ordinary emails and
-- addresses, so every match path in this file would happily reach one, and a
-- vendor account matched to a non-customer is worse than an unmatched one: it
-- reports BILLED_NO_SUBSCRIPTION -- a leak, with a customer name beside it --
-- for a record that was never going to hold a subscription.
--
-- Observed on 2026-09-15: Livewire's own Alarm.com account reached the
-- "service" record by shared email and was reported as the single largest
-- leak on the contact tier, $98.63 a month. Two office accounts had reached
-- the **TEST** record by address earlier.
--
-- Deliberately narrow, on evidence rather than a guess at what a fake record
-- looks like. Two rules:
--   ** anywhere in the name -- a marker a person typed on purpose, and a
--      character pair that does not occur in a real name.
--   an exact name in the literal list below -- exact, never a substring, so
--      a real customer called "Service Plus LLC" is untouched.
-- Extend the list only from what a query shows, never from a hunch. To see
-- what it excludes today, and what else might belong:
--   SELECT customer_id, display_name, email
--   FROM staging.stg_zohobilling__customers
--   WHERE REGEXP_CONTAINS(COALESCE(display_name, ''), r'\*\*')
--      OR LOWER(TRIM(COALESCE(display_name, ''))) IN ('service')
--
-- Every path reads this rather than the staging table, so the exclusion is
-- declared once and cannot be forgotten in a tier added later.
-- pipelines/tests/test_sql_address_key.py fails the build if any path goes
-- back to reading staging.stg_zohobilling__customers directly.
--
-- `*` is safe here: one source, no UNION, so there is no positional hazard.
billing_customers AS (
  SELECT *
  FROM staging.stg_zohobilling__customers
  WHERE NOT REGEXP_CONTAINS(COALESCE(display_name, ''), r'\*\*')
    AND LOWER(TRIM(COALESCE(display_name, ''))) NOT IN ('service')
),
-- THE QUICKBOOKS CUSTOMER BOOK, READ ONCE
-- Two independent things need it: the Billing bridge below (a QBO address
-- resolved to a Billing customer by name) and the QBO evidence path further
-- down (a vendor account resolved to a QBO customer in its own right). They
-- are separate questions and must not be chained -- see the block above
-- customer_by_qbo -- but they read the same book, so it is read once here.
-- pipelines/tests/test_sql_address_key.py fails the build if any path goes
-- back to the staging table directly, the same guard billing_customers has.
--
-- NOT FILTERED THE WAY billing_customers IS, and deliberately so. QuickBooks
-- carries job records alongside households -- "Pulley Residence Security
-- System Budget", "Den", "Office Surge Protection", each with the real payer
-- in company_name -- but they are ordinary customers that hold real invoices,
-- not the fake records the Billing filter drops. There is no marker that
-- separates a job from a household, so none is invented here; the cost is
-- that a vendor account can resolve to a job rather than its parent and miss
-- revenue billed to the parent. That direction is safe: it understates the
-- evidence and leaves the row in the leak list for a person to check.
-- `*` is safe here: one source, no UNION, so there is no positional hazard.
qbo_customers AS (
  SELECT * FROM staging.stg_qbo__customers
),
-- '||' is the empty key: it is house|street|zip, so a record that yielded
-- none of the three still carries two separators. Guarding on '|' — as this
-- file did until pipelines/tests/test_sql_address_key.py existed — excludes
-- nothing, so every addressless record kept its empty key, the QUALIFY below
-- collapsed them all onto one row, and a record with no parseable address
-- could be matched to whichever customer happened to win that collapse. No
-- vendor row has an empty key today, which is the only reason it never fired.
billing_direct AS (
  SELECT
    CONCAT(
      COALESCE(REGEXP_EXTRACT(billing_address, r'^\s*(\d+)'), ''), '|',
      COALESCE(REGEXP_REPLACE(REGEXP_REPLACE(
        REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
          LOWER(COALESCE(REGEXP_EXTRACT(billing_address, r'^\s*\d+\s+(.*)$'), '')),
          r'\b(n|s)(?:orth|outh)(e|w)(?:ast|est)\b', r'\1\2'),
          r'\b(n|s)(?:orth|outh)\b', r'\1'),
          r'\b(e|w)(?:ast|est)\b', r'\1'),
        r'\b(st|street|rd|road|dr|drive|ln|lane|ct|court|cir|circle|pl|place|ave|avenue|blvd|boulevard|way|ter|terrace|trl|trail|pkwy|parkway|hwy|highway|apt|unit|ste|suite)\b\.?', ''),
        r'[^a-z0-9]+', ''), ''), '|',
      COALESCE(REGEXP_EXTRACT(billing_zip, r'(\d{5})'), '')
    ) AS address_key,
    customer_id,
    display_name,
    'billing' AS match_via
  FROM billing_customers
  WHERE billing_address IS NOT NULL AND billing_zip IS NOT NULL
),
-- One Billing customer per normalized name; duplicates keep the lowest id.
billing_by_name AS (
  SELECT LOWER(TRIM(display_name)) AS name_key, customer_id, display_name
  FROM billing_customers
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
  WHERE a.address_key != '||' AND a.account_name IS NOT NULL
),
-- A third address source, for properties Zoho CRM has no address for.
-- QuickBooks has carried BillAddr all along and it was simply never
-- extracted; an address that is wrong there bounces an invoice, so it gets
-- corrected, which is a forcing function the CRM's addresses do not have.
-- Measured at 154 accounts and $2,143 a month no other path reaches, and it
-- is the only route to Parasol, whose subscriber names are absent from Zoho
-- almost entirely (7 of 125).
billing_via_qbo AS (
  SELECT q.address_key, b.customer_id, b.display_name, 'qbo' AS match_via
  FROM qbo_customers q
  JOIN billing_by_name b
    ON LOWER(TRIM(q.display_name)) = b.name_key
  WHERE q.address_key != '||' AND q.display_name IS NOT NULL
),
-- One customer per address. The ordering is deliberately conservative: a
-- direct Billing address wins, then the CRM bridge exactly as before, and
-- QuickBooks last. QBO is not weaker evidence — both are a mailing address
-- in another system resolved to Billing by name — but ranking it last makes
-- this change purely ADDITIVE: every address that already resolved keeps the
-- customer it had, and QBO only fills gaps. That is far easier to verify
-- than a reshuffle, and the 874 CRM matches can be checked not to have moved.
-- Duplicates within a path keep the lowest id, as elsewhere.
customer_by_address AS (
  SELECT address_key, customer_id, display_name, match_via
  FROM (
    SELECT * FROM billing_direct WHERE address_key != '||'
    UNION ALL
    SELECT * FROM billing_via_crm
    UNION ALL
    SELECT * FROM billing_via_qbo
  )
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY address_key
    ORDER BY CASE match_via WHEN 'billing' THEN 0 WHEN 'crm' THEN 1 ELSE 2 END,
             customer_id
  ) = 1
),
-- NAME MATCHING, THE LAST RESORT
-- Zoho Billing's customer list returns no addresses, so the address paths
-- above reach Billing only by borrowing an address from a CRM account and
-- hopping back by name. That leaves accounts whose customer is plainly in
-- Billing under their own name but whose property has no CRM record to
-- borrow from: 324 of the 577 unmatched accounts measured on 2026-09-08,
-- $3,167 a month. More vendor names are found in Billing (204 + 141) than
-- in CRM (189 + 135), so this goes to Billing directly rather than through
-- the CRM bridge.
--
-- WEAKER THAN AN ADDRESS, AND RANKED THAT WAY
-- Two unrelated households can share a name, and a false match does not
-- leave an honest gap — it makes a confident wrong statement about a real
-- customer. So this is used only where both address paths found nothing, it
-- is reported as its own match_via rather than folded in, and a name that
-- belongs to more than one Billing customer identifies nobody and is
-- dropped rather than resolved arbitrarily.
billing_by_unique_name AS (
  SELECT
    name_key,
    ANY_VALUE(customer_id)  AS customer_id,
    ANY_VALUE(display_name) AS display_name
  FROM (
    SELECT
      TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
        LOWER(COALESCE(display_name, '')),
        r'\([^)]*\)', ' '),
        r'[^a-z0-9]+', ' '),
        r'\s+', ' ')) AS name_key,
      customer_id,
      display_name
    FROM billing_customers
  ) c
  -- An empty key would collapse every unnamed customer onto one row and
  -- match every unnamed account to it, which is the shape of bug the
  -- address guard already carries a comment about.
  WHERE name_key != ''
  GROUP BY name_key
  -- Qualified deliberately. HAVING resolves a bare name against the SELECT
  -- aliases first, and ANY_VALUE(customer_id) AS customer_id shadows the
  -- column, so an unqualified customer_id here reads as
  -- COUNT(DISTINCT ANY_VALUE(customer_id)) and BigQuery rejects the whole
  -- model as an aggregate of an aggregate.
  HAVING COUNT(DISTINCT c.customer_id) = 1
),
-- CONTACT KEYS: EMAIL AND PHONE
-- Zoho Billing carries an email and a phone on the customer, and two of the
-- three vendor exports carry one too: Alarm.com an email on every one of its
-- 597 rows, Security Central a contact phone on 559 of 588. Neither was used
-- until now. They earn their place because they are the only keys in this
-- model that are near-identifiers rather than heuristics -- an address is
-- approximate and a name is ambiguous, but two records sharing an email
-- address are almost always the same person.
--
-- Measured on the 2026-09-15 data: 37 accounts no other path reached, 16 from
-- Alarm.com worth $291.29 a month and 21 from Security Central worth $80,
-- with 32 of the 37 also agreeing on name. No key was shared by more than two
-- accounts, and that is the number that mattered: a shared key -- an
-- installer's email, a main office line sitting on every account they ever
-- touched -- would manufacture a confident wrong match for every account
-- hanging off it. Re-check the fan-out if this tier ever grows sharply.
--
-- A key belonging to more than one Billing customer identifies nobody and is
-- dropped, exactly as billing_by_unique_name drops an ambiguous name.
billing_by_email AS (
  SELECT
    LOWER(TRIM(c.email))      AS contact_key,
    ANY_VALUE(c.customer_id)  AS customer_id,
    ANY_VALUE(c.display_name) AS display_name
  FROM billing_customers c
  WHERE TRIM(COALESCE(c.email, '')) != ''
  GROUP BY contact_key
  -- Qualified for the same reason billing_by_unique_name is: ANY_VALUE(...)
  -- AS customer_id shadows the column, and a bare name here reads as an
  -- aggregate of an aggregate.
  HAVING COUNT(DISTINCT c.customer_id) = 1
),
-- Phone numbers are written a dozen ways ("(804) 555-0142", "+1 804 555
-- 0142", "804.555.0142"). Reduce to digits and keep the last ten, which drops
-- a country code without having to know whether one is there. Fewer than ten
-- digits is not a number that can be matched -- an extension, a truncated
-- field -- and is excluded rather than padded.
billing_by_phone AS (
  SELECT
    RIGHT(REGEXP_REPLACE(c.phone, r'[^0-9]', ''), 10) AS contact_key,
    ANY_VALUE(c.customer_id)  AS customer_id,
    ANY_VALUE(c.display_name) AS display_name
  FROM billing_customers c
  WHERE LENGTH(REGEXP_REPLACE(COALESCE(c.phone, ''), r'[^0-9]', '')) >= 10
  GROUP BY contact_key
  HAVING COUNT(DISTINCT c.customer_id) = 1
),
-- One Billing customer per vendor account, reached by that account's own
-- contact details. Parasol's invoice carries neither an email nor a phone, so
-- it has no branch here and can never match this way.
--
-- The QUALIFY deduplicates for the reason sc_account_address does: two
-- Security Central rows can share an account number (one account, two
-- contacts), and two contacts can carry two phone numbers reaching two
-- different customers. Without it one account fans out into several audit
-- rows. Lowest id wins, as everywhere else in this file.
--
-- THE VENDOR SIDE OF THOSE KEYS, EXTRACTED ONCE
-- Two consumers now need an account's email and phone: the Billing contact
-- tier just below, and the QuickBooks path further down. Extracted here once
-- rather than in each, because this is exactly the drift the key tests exist
-- to catch -- a phone reduced to ten digits in one place and to seven in
-- another matches nobody, silently. The empty-key exclusions live here too,
-- so a blank email cannot join from the vendor side no matter who reads this.
vendor_contact AS (
  SELECT
    'alarmdotcom'            AS vendor,
    a.customer_id            AS account_no,
    LOWER(TRIM(a.email))     AS email_key,
    CAST(NULL AS STRING)     AS phone_key
  FROM staging.stg_vendor__alarmdotcom_accounts a
  WHERE TRIM(COALESCE(a.email, '')) != ''
  UNION ALL
  SELECT
    'securitycentral',
    s.account_no,
    NULL,
    RIGHT(REGEXP_REPLACE(s.contact_phone, r'[^0-9]', ''), 10)
  FROM staging.stg_vendor__securitycentral_accounts s
  WHERE LENGTH(REGEXP_REPLACE(COALESCE(s.contact_phone, ''), r'[^0-9]', '')) >= 10
),
customer_by_contact AS (
  SELECT vendor, account_no, customer_id, display_name, match_via
  FROM (
    SELECT
      v.vendor,
      v.account_no,
      b.customer_id,
      b.display_name,
      'email'        AS match_via
    FROM vendor_contact v
    JOIN billing_by_email b ON b.contact_key = v.email_key
    WHERE v.email_key IS NOT NULL
    UNION ALL
    SELECT
      v.vendor,
      v.account_no,
      b.customer_id,
      b.display_name,
      'phone'
    FROM vendor_contact v
    JOIN billing_by_phone b ON b.contact_key = v.phone_key
    WHERE v.phone_key IS NOT NULL
  )
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY vendor, account_no ORDER BY customer_id
  ) = 1
),
-- ============================================================================
-- THE QUICKBOOKS EVIDENCE PATH -- ADVISORY, NOT PART OF `finding`
-- ============================================================================
-- Zoho Billing was never the right test for "is this customer paying us",
-- only the one this mart had. Livewire's customers all flow into QuickBooks
-- and check payers land there too, so QBO is the superset: a customer can be
-- absent from Billing entirely and still be invoiced for monitoring every
-- month. Measured 2026-09-16, 128 of the 229 BILLED_NO_SUBSCRIPTION rows have
-- monitoring revenue in QuickBooks. Roughly half the leak list is wrong.
--
-- RESOLVED INDEPENDENTLY, NOT BRIDGED THROUGH BILLING
-- Nothing links a QuickBooks customer to a Zoho Billing one -- no shared id,
-- and the two books are maintained separately. The tempting shortcut is to
-- hop Billing -> QBO by name off the match this mart already made, and it is
-- wrong: every one of the eight customer-resolving paths above terminates in
-- billing_customers, so that hop would stack a second name match on top of
-- whatever key found the Billing customer, and the combined claim would be
-- weaker than the weakest of the two. It would also quietly degrade every OK
-- row, since a bad second hop cannot be seen from the first.
--
-- So this resolves the vendor account to a QuickBooks customer from scratch,
-- in parallel with the Billing match and sharing none of its output, using
-- the keys stg_qbo__customers carries in its own right: address_key, email,
-- phone, display_name. The two answers are reported side by side and a
-- disagreement between them is information, not a bug to be resolved here.
--
-- An ambiguous key identifies nobody and is dropped, exactly as the Billing
-- tiers drop one. Same rule, same reason, four more times.
qbo_by_address AS (
  SELECT
    c.address_key             AS match_key,
    ANY_VALUE(c.customer_id)  AS customer_id,
    ANY_VALUE(c.display_name) AS display_name
  FROM qbo_customers c
  WHERE c.address_key != '||'
  GROUP BY match_key
  -- Qualified for the reason billing_by_unique_name is: ANY_VALUE(...) AS
  -- customer_id shadows the column and the bare form is an aggregate of an
  -- aggregate, which BigQuery rejects outright.
  HAVING COUNT(DISTINCT c.customer_id) = 1
),
qbo_by_email AS (
  SELECT
    LOWER(TRIM(c.email))      AS match_key,
    ANY_VALUE(c.customer_id)  AS customer_id,
    ANY_VALUE(c.display_name) AS display_name
  FROM qbo_customers c
  WHERE TRIM(COALESCE(c.email, '')) != ''
  GROUP BY match_key
  HAVING COUNT(DISTINCT c.customer_id) = 1
),
qbo_by_phone AS (
  SELECT
    RIGHT(REGEXP_REPLACE(c.phone, r'[^0-9]', ''), 10) AS match_key,
    ANY_VALUE(c.customer_id)  AS customer_id,
    ANY_VALUE(c.display_name) AS display_name
  FROM qbo_customers c
  WHERE LENGTH(REGEXP_REPLACE(COALESCE(c.phone, ''), r'[^0-9]', '')) >= 10
  GROUP BY match_key
  HAVING COUNT(DISTINCT c.customer_id) = 1
),
-- A NAME KEY OF ITS OWN, BECAUSE THE VENDORS DISAGREE ON NAME ORDER
-- Parasol writes "Tilghman, Richard" where QuickBooks writes "Richard
-- Tilghman". The Billing name key above does not invert on the comma and
-- does not need to, since Billing is matched from vendor names that mostly
-- already read first-name-first. Here it is the difference between reaching
-- 3 of Parasol's 39 leak rows and reaching 33 of them, so this key carries
-- one extra pass: anything before the first comma moves to the end.
--
-- Written out twice, once here and once in the join below, and the two must
-- reduce a name identically or equal names produce unequal keys and this
-- whole tier silently matches nobody. pipelines/tests/test_sql_address_key.py
-- compares the copies, as it does for the Billing name key and the phone key.
qbo_by_name AS (
  SELECT
    qbo_name_key              AS match_key,
    ANY_VALUE(customer_id)    AS customer_id,
    ANY_VALUE(display_name)   AS display_name
  FROM (
    SELECT
      TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
        LOWER(COALESCE(display_name, '')),
        r'\([^)]*\)', ' '),
        r'^\s*([^,]+?)\s*,\s*(.+)$', r'\2 \1'),
        r'[^a-z0-9]+', ' '),
        r'\s+', ' ')) AS qbo_name_key,
      customer_id,
      display_name
    FROM qbo_customers
  ) c
  -- An empty key would collapse every unnamed customer onto one row and
  -- match every unnamed account to it, the same hazard the address and
  -- Billing name guards each carry a comment about.
  WHERE qbo_name_key != ''
  GROUP BY match_key
  HAVING COUNT(DISTINCT c.customer_id) = 1
),
-- One QuickBooks customer per vendor account. Ranked strongest first:
-- address, then the two contact keys, then the name. Same ordering logic as
-- the Billing side -- a shared email is near-identifying, a shared name is
-- not -- though here the name tier does most of the work (121 of the 178
-- leak rows it reaches), because a QuickBooks address is a BILLING address
-- and often differs from the service address the vendor holds.
--
-- The QUALIFY keeps the grain: two Security Central identity rows can share
-- an account number, and without it one account fans out into several audit
-- rows. Lowest id wins, as everywhere else in this file.
customer_by_qbo AS (
  SELECT vendor, account_no, customer_id, display_name, match_via
  FROM (
    SELECT
      v.vendor,
      v.account_no,
      COALESCE(a.customer_id, e.customer_id, p.customer_id, n.customer_id)
                                                    AS customer_id,
      COALESCE(a.display_name, e.display_name, p.display_name, n.display_name)
                                                    AS display_name,
      CASE
        WHEN a.customer_id IS NOT NULL THEN 'address'
        WHEN e.customer_id IS NOT NULL THEN 'email'
        WHEN p.customer_id IS NOT NULL THEN 'phone'
        WHEN n.customer_id IS NOT NULL THEN 'name'
      END                                           AS match_via
    FROM accounts v
    LEFT JOIN qbo_by_address a
      ON a.match_key = v.address_key AND v.address_key != '||'
    LEFT JOIN vendor_contact vc
      ON vc.vendor = v.vendor AND vc.account_no = v.account_no
    LEFT JOIN qbo_by_email e ON e.match_key = vc.email_key
    LEFT JOIN qbo_by_phone p ON p.match_key = vc.phone_key
    LEFT JOIN qbo_by_name n
      ON n.match_key = TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
           LOWER(COALESCE(v.subscriber_name, '')),
           r'\([^)]*\)', ' '),
           r'^\s*([^,]+?)\s*,\s*(.+)$', r'\2 \1'),
           r'[^a-z0-9]+', ' '),
           r'\s+', ' '))
     AND n.match_key != ''
  )
  WHERE customer_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY vendor, account_no ORDER BY customer_id
  ) = 1
),
-- MONITORING REVENUE, IDENTIFIED BY INCOME ACCOUNT
-- Which item is monitoring is a bookkeeping fact, not a string-matching
-- guess: every monitoring item posts to one of three income accounts, and
-- the bookkeeper assigns that account when the item is created. Matching on
-- item names instead would miss the ones that do not say "monitoring"
-- (LWS-APPCONTROL, INV-FULL-ANN) and catch ones that are not.
--   Security Monitoring Income  -- 46 active items, the LWS-* family
--   Invision Monitoring Income  -- 17 items, INV-FULL-ANN, INVISIONPACKAGE-*
--   Security Discounts          -- 4 items, the 2/3/5-year agreement
--                                  discounts. Contra-revenue on the same
--                                  service: a line here is still evidence
--                                  the customer is on a monitoring
--                                  agreement, which is what this measures.
--
-- total_amount > 0 excludes voided invoices. QuickBooks keeps a void as a
-- zero-amount invoice with its lines intact, so a naive filter counts one as
-- revenue; a voided monitoring invoice is the opposite of evidence.
--
-- WHAT THIS CANNOT SAY: that the monitoring line itself was paid.
-- stg_qbo__payments carries no link to an invoice -- QuickBooks returns it in
-- Line[].LinkedTxn[] and the raw payload is not extracted that far -- so the
-- strongest available claim is "invoiced, and that invoice carries no
-- balance", which is what last_settled_on reports. A partial payment against
-- a multi-line invoice cannot be attributed to a line either way.
qbo_monitoring AS (
  SELECT
    l.customer_id,
    MAX(i.txn_date)                            AS last_invoiced_on,
    MAX(IF(i.balance = 0, i.txn_date, NULL))   AS last_settled_on
  FROM staging.stg_qbo__invoice_lines l
  JOIN staging.stg_qbo__invoices i ON i.invoice_id = l.invoice_id
  JOIN staging.stg_qbo__items it ON it.item_id = l.item_id
  WHERE it.income_account_name IN (
          'Security Monitoring Income',
          'Invision Monitoring Income',
          'Security Discounts')
    AND i.total_amount > 0
  GROUP BY l.customer_id
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
  WHERE account_no IS NOT NULL AND address_key != '||'
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
    COALESCE(direct.customer_id, bridged.customer_id, contact.customer_id,
             named.customer_id)                           AS customer_id,
    COALESCE(direct.display_name, bridged.display_name, contact.display_name,
             named.display_name)                          AS display_name,
    CASE
      WHEN direct.customer_id IS NOT NULL THEN direct.match_via
      WHEN bridged.customer_id IS NOT NULL THEN 'sc_account'
      WHEN contact.customer_id IS NOT NULL THEN contact.match_via
      WHEN named.customer_id IS NOT NULL THEN 'name'
    END                                                   AS match_via
  FROM accounts v
  LEFT JOIN customer_by_address direct
    ON v.address_key = direct.address_key AND v.address_key != '||'
  LEFT JOIN sc_account_address bridge
    ON v.vendor = 'alarmdotcom' AND v.contract_no = bridge.account_no
  LEFT JOIN customer_by_address bridged
    ON bridge.address_key = bridged.address_key
  -- Above the name match, below both address paths. An email or a phone is
  -- better evidence than a shared name, so this is deliberately NOT the
  -- purely-additive ranking the QuickBooks bridge used: an account that
  -- matched by name alone can move here, and to a different customer. That is
  -- the intended improvement rather than a regression, but it does mean the
  -- name tier's count should FALL when this lands. Check it; do not assume.
  LEFT JOIN customer_by_contact contact
    ON contact.vendor = v.vendor AND contact.account_no = v.account_no
  -- Last: only reached where no address and no contact path resolved. The subscriber
  -- name is reduced the same way the Billing name is — parentheticals
  -- ("ADRIANNE JOSEPH (MAIN HOUSE)") and punctuation dropped — and an empty
  -- result never joins.
  LEFT JOIN billing_by_unique_name named
    ON TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
         LOWER(COALESCE(v.subscriber_name, '')),
         r'\([^)]*\)', ' '),
         r'[^a-z0-9]+', ' '),
         r'\s+', ' ')) = named.name_key
   AND named.name_key != ''
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
  -- The QuickBooks answer, reported beside the Billing one and deliberately
  -- NOT folded into `finding` in this change. These columns say what the
  -- evidence is; the gate still asks Zoho Billing alone, so every existing
  -- row keeps the finding it had and the two can be compared on real data
  -- before one is allowed to override the other. Folding
  -- qbo_monitoring_revenue into the revenue gate is the next change, not
  -- this one.
  q.customer_id                         AS qbo_customer_id,
  q.display_name                        AS qbo_customer_name,
  q.match_via                           AS qbo_match_via,
  -- The same sanity check name_overlaps applies to the Billing match, on the
  -- QuickBooks one. Agreement is weak evidence; DISAGREEMENT means the key
  -- probably reached the wrong household, and a row that is being kept OFF
  -- the leak list on the strength of a wrong match is the expensive error
  -- here -- it is a monthly cost nobody ever looks at again.
  (SELECT LOGICAL_OR(LENGTH(t) >= 3 AND STRPOS(LOWER(q.display_name), t) > 0)
   FROM UNNEST(SPLIT(LOWER(REGEXP_REPLACE(
     COALESCE(v.subscriber_name, ''), r'[^a-zA-Z ]', '')), ' ')) AS t)
                                        AS qbo_name_overlaps,
  qm.customer_id IS NOT NULL            AS qbo_monitoring_revenue,
  qm.last_invoiced_on                   AS qbo_monitoring_last_invoiced,
  qm.last_settled_on                    AS qbo_monitoring_last_settled,
  CASE
    WHEN NOT COALESCE(v.is_active_at_vendor, FALSE) THEN 'DEACTIVATED'
    WHEN NOT v.in_roster THEN 'BILLED_NO_ROSTER'
    WHEN v.customer_id IS NULL THEN 'BILLED_NO_MATCH'
    WHEN COALESCE(s.active_subscriptions, 0) = 0 THEN 'BILLED_NO_SUBSCRIPTION'
    ELSE 'OK'
  END                                   AS finding,
  CURRENT_TIMESTAMP()                   AS computed_at
FROM matched v
LEFT JOIN subs s ON s.customer_id = v.customer_id
-- Keyed on (vendor, account_no) like the contact join above, and for the same
-- reason: an account number is unique only within a vendor, so joining on it
-- alone would match one vendor's account to another's customer.
LEFT JOIN customer_by_qbo q
  ON q.vendor = v.vendor AND q.account_no = v.account_no
LEFT JOIN qbo_monitoring qm ON qm.customer_id = q.customer_id;

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
  SET OPTIONS (description = "Where vendor_status came from: weekly (Security Central weekly Customer Count feed), roster (Security Central All Accounts export, used when the weekly feed has no row), recurring (Security Central billing report, for an account that reaches neither of those but is still being invoiced), export (Alarm.com dealer-site export), invoice (Parasol monthly invoice).");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN status_as_of
  SET OPTIONS (description = "When that status was loaded into the warehouse (UTC).");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN in_roster
  SET OPTIONS (description = "FALSE when the account is known only from a feed that carries no address, so no billing match was possible — including a Security Central account that appears in the recurring billing report but in neither the roster nor the weekly feed. TRUE for every Alarm.com and Parasol row.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN started_on
  SET OPTIONS (description = "Account start date per the vendor. NULL for Parasol, whose invoice does not carry one.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN vendor_monthly_cost
  SET OPTIONS (description = "What this vendor charges for THIS account per month, USD, from that vendor's own billing feed: Security Central's recurring report, Alarm.com's billing export, Parasol's invoice. Already summed over the several lines a vendor bills one account as. NULL means the cost is not known for that account — its vendor's billing feed has not been uploaded, or carries no row for it — and never that the account is free.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN matched_customer_id
  SET OPTIONS (description = "Zoho Billing customer matched to this account. NULL when no match was found.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN matched_customer_name
  SET OPTIONS (description = "Display name of the matched Zoho Billing customer.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN match_via
  SET OPTIONS (description = "How the billing customer was reached, strongest first: sc_account (Alarm.com only, through Security Central's account number, an exact key), billing (a Billing address directly), crm (vendor address to a Zoho CRM account, then to Billing by customer name), qbo (vendor address to a QuickBooks billing address, then to Billing by customer name), email (the account's own email address matched exactly one Zoho Billing customer; Alarm.com only, as no other vendor export carries one), phone (the same by contact phone reduced to its last ten digits; Security Central only), name (the subscriber name matched exactly one Zoho Billing customer, used only where nothing above resolved). NULL when unmatched. A name match is the WEAKEST: it says two records share a name, not that they are the same household, so confirm a name-matched row against the property before acting on it. email and phone rank above name and below both address paths, so an account that once matched by name may now match by contact, to a different customer.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN name_overlaps
  SET OPTIONS (description = "TRUE when a word of the vendor's subscriber name appears in the matched customer's name. FALSE is a strong signal the address matched the WRONG household; never act on such a row without checking it by hand. Carries no information where match_via is name, which matched on the name to begin with — judge those rows by the address instead.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN active_subscriptions
  SET OPTIONS (description = "Number of live Zoho Billing subscriptions for the matched customer. 0 when unmatched.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN subscription_amount
  SET OPTIONS (description = "Summed recurring amount of those live subscriptions, USD.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN plan_names
  SET OPTIONS (description = "Comma-separated names of the live plans, for judging fit.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN qbo_customer_id
  SET OPTIONS (description = "QuickBooks customer this account was resolved to, INDEPENDENTLY of the Zoho Billing match: from the account's own address, email, phone or name, never by bridging from the Billing customer. NULL when no QuickBooks customer could be reached (51 of the 229 leak rows), which is unknown, not evidence of anything. The two matches are separate answers and may disagree; that disagreement is information.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN qbo_customer_name
  SET OPTIONS (description = "Display name of that QuickBooks customer. QuickBooks carries job records alongside households ('Pulley Residence Security System Budget', 'Den'), so a name that reads like a project rather than a person means the account resolved to a job; revenue billed to its parent customer will not be counted.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN qbo_match_via
  SET OPTIONS (description = "How the QuickBooks customer was reached, strongest first: address (the account's address key matched exactly one QuickBooks customer), email, phone (last ten digits), name (the subscriber name matched exactly one QuickBooks customer, with the vendor's 'Last, First' order inverted to match QuickBooks). NULL when unmatched. name does most of the work here (121 of 178 matched leak rows) because a QuickBooks address is a BILLING address and often differs from the service address the vendor holds. A name match is the weakest: it says two records share a name, not that they are the same household.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN qbo_name_overlaps
  SET OPTIONS (description = "TRUE when a word of the vendor's subscriber name appears in the QuickBooks customer's name. What name_overlaps is for the Billing match, for this one. FALSE is a strong signal the key reached the WRONG household — and a wrong match here is the expensive direction, because it can keep a real leak OFF the list. Carries no information where qbo_match_via is name. 126 of the 128 rows with monitoring revenue are TRUE.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN qbo_monitoring_revenue
  SET OPTIONS (description = "TRUE when the matched QuickBooks customer has ever been invoiced on a monitoring income account — Security Monitoring Income, Invision Monitoring Income, or Security Discounts (the 2/3/5-year agreement discounts, contra-revenue on the same service and so still evidence of an agreement) — on an invoice with a total above zero, which excludes voided invoices. Identified by the item's income account, a bookkeeping fact, not by matching item names. TRUE means this row's BILLED_NO_SUBSCRIPTION finding is probably wrong. FALSE means no such revenue was found, which includes the case where no QuickBooks customer was matched at all — check qbo_customer_id before reading FALSE as a leak. This column is ADVISORY: finding does not consider it.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN qbo_monitoring_last_invoiced
  SET OPTIONS (description = "Date of the most recent non-voided monitoring invoice for the matched QuickBooks customer; NULL when there is none. Use it to tell a current agreement from one that lapsed years ago. Of the 128 leak rows with monitoring revenue, 124 were invoiced within the last twelve months, so recency is not what is driving this number.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN qbo_monitoring_last_settled
  SET OPTIONS (description = "Date of the most recent such monitoring invoice that carries no remaining balance. This is the strongest paid-signal available: QuickBooks payments carry no link to the invoice they settle, so the monitoring LINE cannot be traced to a payment — only the invoice it sat on can be shown to be fully settled. All 124 recently-invoiced leak rows are settled. NULL means no monitoring invoice has been settled, which on a recent invoice may mean nothing more than that it is not due yet.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN finding
  SET OPTIONS (description = "OK: active at the vendor with a live subscription. BILLED_NO_SUBSCRIPTION: active at the vendor, customer matched, no live subscription; the leak. BILLED_NO_MATCH: active at the vendor but no billing customer could be matched; unknown, not a proven leak. Always read finding together with match_via: a BILLED_NO_SUBSCRIPTION reached by name is a weaker claim than one reached by address or account number. BILLED_NO_ROSTER: active but absent from the roster; request a fresh export before judging. DEACTIVATED: not active at the vendor; informational.");
ALTER TABLE marts.kpi_subscription_audit ALTER COLUMN computed_at
  SET OPTIONS (description = "When this row was built (UTC).");
