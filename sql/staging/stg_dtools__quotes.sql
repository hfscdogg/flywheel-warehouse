-- stg_dtools__quotes — latest record per D-Tools Cloud quote.
-- Grain: one row per quote_id.
-- Source: raw_dtools.quotes (append-only; fetched per opportunity —
-- see pipelines/lib/sources.py DTOOLS).
-- Field paths are best-effort pending verification against live payloads;
-- an all-NULL column means a wrong path — a one-line COALESCE fix here.
CREATE OR REPLACE TABLE staging.stg_dtools__quotes
OPTIONS (description = """
D-Tools quotes, one row per quote. Several quotes can belong to one opportunity as it is revised; status says which is current. Amounts USD.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_dtools.quotes
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _modified_at DESC NULLS LAST, _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                 AS quote_id,
  JSON_VALUE(payload, '$.opportunityId')                     AS opportunity_id,
  JSON_VALUE(payload, '$.name')                              AS name,
  COALESCE(JSON_VALUE(payload, '$.quoteNumber'),
           JSON_VALUE(payload, '$.number'))                  AS quote_number,
  COALESCE(JSON_VALUE(payload, '$.status.name'),
           JSON_VALUE(payload, '$.status'))                  AS status,
  SAFE_CAST(COALESCE(JSON_VALUE(payload, '$.price'),
                     JSON_VALUE(payload, '$.totalPrice'),
                     JSON_VALUE(payload, '$.total')) AS NUMERIC)     AS price,
  SAFE_CAST(COALESCE(JSON_VALUE(payload, '$.cost'),
                     JSON_VALUE(payload, '$.totalCost')) AS NUMERIC) AS cost,
  SAFE_CAST(JSON_VALUE(payload, '$.createdDate') AS TIMESTAMP)  AS created_at,
  SAFE_CAST(JSON_VALUE(payload, '$.modifiedDate') AS TIMESTAMP) AS modified_at,
  _loaded_at                                                 AS loaded_at
FROM latest;

ALTER TABLE staging.stg_dtools__quotes ALTER COLUMN quote_id
  SET OPTIONS (description = "D-Tools quote id; the key.");
ALTER TABLE staging.stg_dtools__quotes ALTER COLUMN opportunity_id
  SET OPTIONS (description = "Opportunity the quote belongs to; joins to stg_dtools__opportunities.");
ALTER TABLE staging.stg_dtools__quotes ALTER COLUMN name
  SET OPTIONS (description = "Quote name.");
ALTER TABLE staging.stg_dtools__quotes ALTER COLUMN quote_number
  SET OPTIONS (description = "Quote number shown to the client.");
ALTER TABLE staging.stg_dtools__quotes ALTER COLUMN status
  SET OPTIONS (description = "Quote status word from D-Tools.");
ALTER TABLE staging.stg_dtools__quotes ALTER COLUMN price
  SET OPTIONS (description = "Quoted sell price, USD.");
ALTER TABLE staging.stg_dtools__quotes ALTER COLUMN cost
  SET OPTIONS (description = "Quoted cost, USD.");
ALTER TABLE staging.stg_dtools__quotes ALTER COLUMN created_at
  SET OPTIONS (description = "When the record was created in the source system (UTC).");
ALTER TABLE staging.stg_dtools__quotes ALTER COLUMN modified_at
  SET OPTIONS (description = "When the record was last changed in the source system (UTC).");
ALTER TABLE staging.stg_dtools__quotes ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
