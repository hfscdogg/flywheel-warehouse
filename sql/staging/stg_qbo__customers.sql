-- stg_qbo__customers — latest record per QuickBooks Online customer.
-- Grain: one row per customer_id.
-- Source: raw_qbo.customer (append-only; payload = full QBO v3 record).
--
-- BillAddr has been in the payload all along — the ingest fetches whole
-- records — and was simply never extracted. It is a better address source
-- than it looks: an address that is wrong in QuickBooks bounces an invoice,
-- so it gets corrected, which is a forcing function the CRM's addresses do
-- not have. kpi_subscription_audit uses it to reach a billing customer for
-- properties Zoho CRM has no address for.
CREATE OR REPLACE TABLE staging.stg_qbo__customers
OPTIONS (description = """
QuickBooks customers, one row per customer. balance is what they currently owe. Names here are matched by display_name to D-Tools client names in kpi_project_margin; there is no shared id between the two systems.\nbilling_street and address_key carry the QuickBooks billing address, which kpi_subscription_audit uses to reach a customer for a monitored property Zoho CRM has no address for. Roughly a sixth of customers have one.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.customer
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                    AS customer_id,
  JSON_VALUE(payload, '$.DisplayName')                          AS display_name,
  JSON_VALUE(payload, '$.CompanyName')                          AS company_name,
  LOWER(JSON_VALUE(payload, '$.PrimaryEmailAddr.Address'))      AS email,
  JSON_VALUE(payload, '$.PrimaryPhone.FreeFormNumber')          AS phone,
  SAFE_CAST(JSON_VALUE(payload, '$.Balance') AS NUMERIC)        AS balance,
  SAFE_CAST(JSON_VALUE(payload, '$.Active') AS BOOL)            AS is_active,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.CreateTime') AS TIMESTAMP)      AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.LastUpdatedTime') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                    AS loaded_at,
  JSON_VALUE(payload, '$.BillAddr.Line1')                       AS billing_street,
  JSON_VALUE(payload, '$.BillAddr.City')                        AS billing_city,
  JSON_VALUE(payload, '$.BillAddr.PostalCode')                  AS billing_zip,
  -- Same key, verbatim, as the vendor models, stg_zoho__accounts and the
  -- audit mart; pipelines/tests/test_sql_address_key.py fails if the copies
  -- drift. Compass directions reduce to a letter, so "322 N 25th St" and
  -- "322 North 25th Street" key alike.
  CONCAT(
    COALESCE(REGEXP_EXTRACT(JSON_VALUE(payload, '$.BillAddr.Line1'), r'^\s*(\d+)'), ''), '|',
    COALESCE(REGEXP_REPLACE(REGEXP_REPLACE(
      REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
        LOWER(COALESCE(REGEXP_EXTRACT(JSON_VALUE(payload, '$.BillAddr.Line1'), r'^\s*\d+\s+(.*)$'), '')),
        r'\b(n|s)(?:orth|outh)(e|w)(?:ast|est)\b', r'\1\2'),
        r'\b(n|s)(?:orth|outh)\b', r'\1'),
        r'\b(e|w)(?:ast|est)\b', r'\1'),
      r'\b(st|street|rd|road|dr|drive|ln|lane|ct|court|cir|circle|pl|place|ave|avenue|blvd|boulevard|way|ter|terrace|trl|trail|pkwy|parkway|hwy|highway|apt|unit|ste|suite)\b\.?', ''),
      r'[^a-z0-9]+', ''), ''), '|',
    COALESCE(REGEXP_EXTRACT(JSON_VALUE(payload, '$.BillAddr.PostalCode'), r'(\d{5})'), '')
  )                                                             AS address_key
FROM latest;

ALTER TABLE staging.stg_qbo__customers ALTER COLUMN customer_id
  SET OPTIONS (description = "QuickBooks customer id; the key.");
ALTER TABLE staging.stg_qbo__customers ALTER COLUMN display_name
  SET OPTIONS (description = "Display name; the name invoices and other tables show.");
ALTER TABLE staging.stg_qbo__customers ALTER COLUMN company_name
  SET OPTIONS (description = "Company name, when the customer is a business.");
ALTER TABLE staging.stg_qbo__customers ALTER COLUMN email
  SET OPTIONS (description = "Customer email.");
ALTER TABLE staging.stg_qbo__customers ALTER COLUMN phone
  SET OPTIONS (description = "Customer phone.");
ALTER TABLE staging.stg_qbo__customers ALTER COLUMN balance
  SET OPTIONS (description = "Open balance owed by this customer now, USD.");
ALTER TABLE staging.stg_qbo__customers ALTER COLUMN is_active
  SET OPTIONS (description = "FALSE for customers made inactive in QuickBooks.");
ALTER TABLE staging.stg_qbo__customers ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_qbo__customers ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_qbo__customers ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
ALTER TABLE staging.stg_qbo__customers ALTER COLUMN billing_street
  SET OPTIONS (description = "Street line of the QuickBooks billing address. This is where invoices go, which is usually but not always the property being monitored.");
ALTER TABLE staging.stg_qbo__customers ALTER COLUMN billing_city
  SET OPTIONS (description = "City of the QuickBooks billing address.");
ALTER TABLE staging.stg_qbo__customers ALTER COLUMN billing_zip
  SET OPTIONS (description = "Postal code of the QuickBooks billing address; may carry ZIP+4.");
ALTER TABLE staging.stg_qbo__customers ALTER COLUMN address_key
  SET OPTIONS (description = "Address match key used to line this record up with the same property in other systems: house number | street name with its suffix stripped and any compass direction reduced to a letter (North to n) | 5-digit ZIP. A heuristic, not an identifier; two different households can share one. Reads as two bare pipes when the customer has no usable billing address, which is most of them.");
