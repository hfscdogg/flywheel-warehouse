-- stg_qbo__vendors — latest record per QuickBooks Online vendor.
-- Grain: one row per vendor_id.
-- Source: raw_qbo.vendor (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__vendors
OPTIONS (description = """
QuickBooks vendors, one row per vendor. balance is what we currently owe them across open bills.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.vendor
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                    AS vendor_id,
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

ALTER TABLE staging.stg_qbo__vendors ALTER COLUMN vendor_id
  SET OPTIONS (description = "QuickBooks vendor id; the key.");
ALTER TABLE staging.stg_qbo__vendors ALTER COLUMN display_name
  SET OPTIONS (description = "Vendor display name; the name bills show.");
ALTER TABLE staging.stg_qbo__vendors ALTER COLUMN company_name
  SET OPTIONS (description = "Vendor company name.");
ALTER TABLE staging.stg_qbo__vendors ALTER COLUMN email
  SET OPTIONS (description = "Vendor email.");
ALTER TABLE staging.stg_qbo__vendors ALTER COLUMN phone
  SET OPTIONS (description = "Vendor phone.");
ALTER TABLE staging.stg_qbo__vendors ALTER COLUMN balance
  SET OPTIONS (description = "What we owe this vendor now across open bills, USD.");
ALTER TABLE staging.stg_qbo__vendors ALTER COLUMN is_active
  SET OPTIONS (description = "FALSE for vendors made inactive in QuickBooks.");
ALTER TABLE staging.stg_qbo__vendors ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_qbo__vendors ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_qbo__vendors ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
