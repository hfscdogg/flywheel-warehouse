-- stg_dtools__quotes — latest record per D-Tools Cloud quote.
-- Grain: one row per quote_id.
-- Source: raw_dtools.quotes (append-only; fetched per opportunity —
-- see pipelines/lib/sources.py DTOOLS).
-- Field paths are best-effort pending verification against live payloads;
-- an all-NULL column means a wrong path — a one-line COALESCE fix here.
CREATE OR REPLACE TABLE staging.stg_dtools__quotes AS
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
