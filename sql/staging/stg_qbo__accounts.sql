-- stg_qbo__accounts — latest record per QuickBooks Online ledger account.
-- Grain: one row per account_id.
-- Source: raw_qbo.account (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__accounts
OPTIONS (description = """
The QuickBooks chart of accounts, one row per account. Join on account_id to name the account a bill or purchase line posts to. classification separates Expense, Revenue, Asset, Liability and Equity; account_type is finer (Expense vs Cost of Goods Sold, Bank vs Credit Card).
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.account
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                     AS account_id,
  JSON_VALUE(payload, '$.Name')                                  AS name,
  JSON_VALUE(payload, '$.AccountType')                           AS account_type,
  JSON_VALUE(payload, '$.AccountSubType')                        AS account_sub_type,
  JSON_VALUE(payload, '$.Classification')                        AS classification,
  SAFE_CAST(JSON_VALUE(payload, '$.CurrentBalance') AS NUMERIC)  AS current_balance,
  SAFE_CAST(JSON_VALUE(payload, '$.Active') AS BOOL)             AS is_active,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.CreateTime') AS TIMESTAMP)      AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.LastUpdatedTime') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                     AS loaded_at
FROM latest;

ALTER TABLE staging.stg_qbo__accounts ALTER COLUMN account_id
  SET OPTIONS (description = "QuickBooks account id; the key.");
ALTER TABLE staging.stg_qbo__accounts ALTER COLUMN name
  SET OPTIONS (description = "Account name as shown in the chart of accounts, e.g. Freight and Shipping.");
ALTER TABLE staging.stg_qbo__accounts ALTER COLUMN account_type
  SET OPTIONS (description = "QuickBooks account type: Expense, Cost of Goods Sold, Other Expense, Income, Bank, Credit Card, Fixed Asset, and so on.");
ALTER TABLE staging.stg_qbo__accounts ALTER COLUMN account_sub_type
  SET OPTIONS (description = "Finer QuickBooks sub-type, e.g. ShippingFreightDelivery, TravelMeals.");
ALTER TABLE staging.stg_qbo__accounts ALTER COLUMN classification
  SET OPTIONS (description = "Expense, Revenue, Asset, Liability or Equity.");
ALTER TABLE staging.stg_qbo__accounts ALTER COLUMN current_balance
  SET OPTIONS (description = "Balance as QuickBooks reports it now, USD. Meaningful for balance-sheet accounts; for P&L accounts it is year-to-date.");
ALTER TABLE staging.stg_qbo__accounts ALTER COLUMN is_active
  SET OPTIONS (description = "FALSE for accounts that have been made inactive in QuickBooks.");
ALTER TABLE staging.stg_qbo__accounts ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_qbo__accounts ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_qbo__accounts ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
