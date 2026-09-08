-- stg_qbo__bills — latest record per QuickBooks Online vendor bill.
-- Grain: one row per bill_id.
-- Source: raw_qbo.bill (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__bills
OPTIONS (description = """
QuickBooks vendor bills, one row per bill: who we owe, how much, when due, and what is still unpaid. This is the HEADER only; what the bill was for is on its lines in stg_qbo__bill_lines. Amounts USD.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.bill
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                  AS bill_id,
  JSON_VALUE(payload, '$.DocNumber')                          AS doc_number,
  SAFE_CAST(JSON_VALUE(payload, '$.TxnDate') AS DATE)         AS txn_date,
  SAFE_CAST(JSON_VALUE(payload, '$.DueDate') AS DATE)         AS due_date,
  JSON_VALUE(payload, '$.VendorRef.value')                    AS vendor_id,
  JSON_VALUE(payload, '$.VendorRef.name')                     AS vendor_name,
  SAFE_CAST(JSON_VALUE(payload, '$.TotalAmt') AS NUMERIC)     AS total_amount,
  SAFE_CAST(JSON_VALUE(payload, '$.Balance') AS NUMERIC)      AS balance,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.CreateTime') AS TIMESTAMP)      AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.LastUpdatedTime') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                  AS loaded_at
FROM latest;

ALTER TABLE staging.stg_qbo__bills ALTER COLUMN bill_id
  SET OPTIONS (description = "QuickBooks bill id; the key. stg_qbo__bill_lines.bill_id joins here.");
ALTER TABLE staging.stg_qbo__bills ALTER COLUMN doc_number
  SET OPTIONS (description = "The vendor's invoice number as entered.");
ALTER TABLE staging.stg_qbo__bills ALTER COLUMN txn_date
  SET OPTIONS (description = "Bill date.");
ALTER TABLE staging.stg_qbo__bills ALTER COLUMN due_date
  SET OPTIONS (description = "Date payment is due; past this the balance is overdue.");
ALTER TABLE staging.stg_qbo__bills ALTER COLUMN vendor_id
  SET OPTIONS (description = "Vendor billed; joins to stg_qbo__vendors.");
ALTER TABLE staging.stg_qbo__bills ALTER COLUMN vendor_name
  SET OPTIONS (description = "Vendor display name.");
ALTER TABLE staging.stg_qbo__bills ALTER COLUMN total_amount
  SET OPTIONS (description = "Bill total, USD.");
ALTER TABLE staging.stg_qbo__bills ALTER COLUMN balance
  SET OPTIONS (description = "Unpaid remainder, USD. 0 means paid in full; this is the accounts-payable amount.");
ALTER TABLE staging.stg_qbo__bills ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_qbo__bills ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_qbo__bills ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
