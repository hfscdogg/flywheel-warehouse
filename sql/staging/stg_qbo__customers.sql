-- stg_qbo__customers — latest record per QuickBooks Online customer.
-- Grain: one row per customer_id.
-- Source: raw_qbo.customer (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__customers
OPTIONS (description = """
QuickBooks customers, one row per customer. balance is what they currently owe. Names here are matched by display_name to D-Tools client names in kpi_project_margin; there is no shared id between the two systems.
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
  _loaded_at                                                    AS loaded_at
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
