-- stg_qbo__items — latest record per QuickBooks Online item (product/service).
-- Grain: one row per item_id.
-- Source: raw_qbo.item (append-only; payload = full QBO v3 record).
CREATE OR REPLACE TABLE staging.stg_qbo__items
OPTIONS (description = """
QuickBooks products and services, one row per item. An invoice line names an item to say what was sold; a bill or purchase line can name one to say what was bought. The income and expense accounts here are what those lines post to.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_qbo.item
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                  AS item_id,
  JSON_VALUE(payload, '$.Name')                               AS name,
  JSON_VALUE(payload, '$.Type')                               AS item_type,
  SAFE_CAST(JSON_VALUE(payload, '$.UnitPrice') AS NUMERIC)    AS unit_price,
  SAFE_CAST(JSON_VALUE(payload, '$.PurchaseCost') AS NUMERIC) AS purchase_cost,
  SAFE_CAST(JSON_VALUE(payload, '$.Active') AS BOOL)          AS is_active,
  -- An item-based bill or purchase line names an item, not an account; the
  -- account it hits is the item's expense account. Income side likewise.
  JSON_VALUE(payload, '$.ExpenseAccountRef.value')            AS expense_account_id,
  JSON_VALUE(payload, '$.ExpenseAccountRef.name')             AS expense_account_name,
  JSON_VALUE(payload, '$.IncomeAccountRef.value')             AS income_account_id,
  JSON_VALUE(payload, '$.IncomeAccountRef.name')              AS income_account_name,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.CreateTime') AS TIMESTAMP)      AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.MetaData.LastUpdatedTime') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                  AS loaded_at
FROM latest;

ALTER TABLE staging.stg_qbo__items ALTER COLUMN item_id
  SET OPTIONS (description = "QuickBooks item id; the key.");
ALTER TABLE staging.stg_qbo__items ALTER COLUMN name
  SET OPTIONS (description = "Item name.");
ALTER TABLE staging.stg_qbo__items ALTER COLUMN item_type
  SET OPTIONS (description = "Inventory, NonInventory, Service, or a Category or Group.");
ALTER TABLE staging.stg_qbo__items ALTER COLUMN unit_price
  SET OPTIONS (description = "Default sell price, USD.");
ALTER TABLE staging.stg_qbo__items ALTER COLUMN purchase_cost
  SET OPTIONS (description = "Default purchase cost, USD.");
ALTER TABLE staging.stg_qbo__items ALTER COLUMN is_active
  SET OPTIONS (description = "FALSE for items made inactive in QuickBooks.");
ALTER TABLE staging.stg_qbo__items ALTER COLUMN expense_account_id
  SET OPTIONS (description = "Account a bill or purchase line for this item posts to; joins to stg_qbo__accounts.");
ALTER TABLE staging.stg_qbo__items ALTER COLUMN expense_account_name
  SET OPTIONS (description = "Name of that expense account.");
ALTER TABLE staging.stg_qbo__items ALTER COLUMN income_account_id
  SET OPTIONS (description = "Account an invoice line for this item posts to; joins to stg_qbo__accounts.");
ALTER TABLE staging.stg_qbo__items ALTER COLUMN income_account_name
  SET OPTIONS (description = "Name of that income account.");
ALTER TABLE staging.stg_qbo__items ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_qbo__items ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_qbo__items ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
