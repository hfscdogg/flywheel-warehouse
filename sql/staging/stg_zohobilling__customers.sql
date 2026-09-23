-- stg_zohobilling__customers — latest record per Zoho Billing customer.
-- Grain: one row per customer_id.
-- Source: raw_zohobilling.customers (append-only; payload = Billing v1 record).
--
-- Carries the billing-side name and address, which is the join key for
-- matching vendor account rosters (alarm monitoring, central station) to
-- customers who are actually subscribed.
CREATE OR REPLACE TABLE staging.stg_zohobilling__customers
OPTIONS (description = """
Zoho Billing customers, one row per customer: who can hold a subscription. Only customers Zoho still lists: the list is a full pull every run, and a profile absent from the newest one was merged away or deleted in Zoho, so it is dropped here rather than kept from an older run. The address columns are populated only for customers the per-customer detail fetch has reached (Billing's list endpoint returns none); until that backfill completes, matching to a service address goes through the CRM account by name instead.
""")
AS
-- The landing table is append-only and every run lands the WHOLE customer
-- list, so "latest record per customer" alone keeps a customer forever: a
-- profile merged into another in Zoho (which deletes it) or removed outright
-- simply stops arriving, and its last record stays the newest one it has.
-- Measured 2026-09-22: 80 such ghosts, 22 of them not listed since the first
-- pull on 2026-08-31, and 38 of the audit's 109 duplicate-profile accounts
-- were matched to one -- profiles already merged in Zoho, so the merge could
-- never clear the finding. The newest run's list is the set of customers
-- Zoho has now; a customer outside it is dropped.
--
-- Which run is newest is decided by _loaded_at, not by a watermark: the list
-- lands first in a run and the detail batches follow under the same _run_id,
-- so the run holding the most recent record always has its full list landed
-- (runner.land loads it atomically). No workflow input trims the list, so a
-- run's list is the book.
WITH newest_run AS (
  SELECT _run_id
  FROM raw_zohobilling.customers
  WHERE _source_id IS NOT NULL
  ORDER BY _loaded_at DESC
  LIMIT 1
),
listed AS (
  SELECT DISTINCT _source_id
  FROM raw_zohobilling.customers
  WHERE _run_id = (SELECT _run_id FROM newest_run)
),
latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_zohobilling.customers
  WHERE _source_id IS NOT NULL
    AND _source_id IN (SELECT _source_id FROM listed)
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    -- A customer lands twice per run when the detail fetch is on: once from
    -- the list (no address) and once from the per-customer GET (address),
    -- both carrying the same last_modified_time. Of two records of the same
    -- modification, the one with an address is the fuller one and wins;
    -- without this tie-break the nightly list record, loaded later, would
    -- quietly erase every address the detail fetch landed.
    ORDER BY _modified_at DESC NULLS LAST,
             (JSON_VALUE(payload, '$.billing_address.address') IS NOT NULL) DESC,
             _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                    AS customer_id,
  JSON_VALUE(payload, '$.display_name')                         AS display_name,
  JSON_VALUE(payload, '$.company_name')                         AS company_name,
  LOWER(JSON_VALUE(payload, '$.email'))                         AS email,
  JSON_VALUE(payload, '$.phone')                                AS phone,
  JSON_VALUE(payload, '$.billing_address.address')              AS billing_address,
  JSON_VALUE(payload, '$.billing_address.city')                 AS billing_city,
  JSON_VALUE(payload, '$.billing_address.state')                AS billing_state,
  JSON_VALUE(payload, '$.billing_address.zip')                  AS billing_zip,
  SAFE_CAST(JSON_VALUE(payload, '$.created_time') AS TIMESTAMP)       AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.last_modified_time') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                    AS loaded_at
FROM latest;

ALTER TABLE staging.stg_zohobilling__customers ALTER COLUMN customer_id
  SET OPTIONS (description = "Zoho Billing customer id; the key. stg_zohobilling__subscriptions.customer_id joins here.");
ALTER TABLE staging.stg_zohobilling__customers ALTER COLUMN display_name
  SET OPTIONS (description = "Display name; matched by name to Zoho CRM account names.");
ALTER TABLE staging.stg_zohobilling__customers ALTER COLUMN company_name
  SET OPTIONS (description = "Company name, when a business.");
ALTER TABLE staging.stg_zohobilling__customers ALTER COLUMN email
  SET OPTIONS (description = "Customer email.");
ALTER TABLE staging.stg_zohobilling__customers ALTER COLUMN phone
  SET OPTIONS (description = "Customer phone.");
ALTER TABLE staging.stg_zohobilling__customers ALTER COLUMN billing_address
  SET OPTIONS (description = "Billing street; NULL for nearly all rows.");
ALTER TABLE staging.stg_zohobilling__customers ALTER COLUMN billing_city
  SET OPTIONS (description = "Billing city; usually NULL.");
ALTER TABLE staging.stg_zohobilling__customers ALTER COLUMN billing_state
  SET OPTIONS (description = "Billing state; usually NULL.");
ALTER TABLE staging.stg_zohobilling__customers ALTER COLUMN billing_zip
  SET OPTIONS (description = "Billing ZIP; usually NULL.");
ALTER TABLE staging.stg_zohobilling__customers ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_zohobilling__customers ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_zohobilling__customers ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
