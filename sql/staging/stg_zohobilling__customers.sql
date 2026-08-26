-- stg_zohobilling__customers — latest record per Zoho Billing customer.
-- Grain: one row per customer_id.
-- Source: raw_zohobilling.customers (append-only; payload = Billing v1 record).
--
-- Carries the billing-side name and address, which is the join key for
-- matching vendor account rosters (alarm monitoring, central station) to
-- customers who are actually subscribed.
CREATE OR REPLACE TABLE staging.stg_zohobilling__customers AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_zohobilling.customers
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
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
