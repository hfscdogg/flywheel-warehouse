-- stg_dtools__quotes — latest record per D-Tools Cloud quote.
-- Grain: one row per quote_id.
-- Source: raw_dtools.quotes (append-only; fetched per opportunity —
-- see pipelines/lib/sources.py DTOOLS).
-- Field paths are best-effort pending verification against live payloads;
-- an all-NULL column means a wrong path — a one-line COALESCE fix here.
CREATE OR REPLACE TABLE staging.stg_dtools__quotes
OPTIONS (description = """
D-Tools quotes, one row per quote. Several quotes can belong to one opportunity as it is revised; status says which is current. Amounts USD.
opportunity_id is ALWAYS NULL: the D-Tools endpoint returns no opportunity reference, so quotes cannot be joined to opportunities or to projects from this table. A question about which quotes belong to a job cannot be answered here — say so rather than returning an empty join as if it meant no quotes exist.
There is no cost on a quote either, only price and servicePrice, so quote margin is not available.
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
  -- NOT IN THE PAYLOAD, AND CANNOT BE. Verified by probing every key in
  -- raw_dtools.quotes on 2026-09-16: the 14 fields GetQuotes returns are
  -- acceptedDate, createdDate, id, isIncludedInTotal, isServiceQuote,
  -- modifiedDate, name, number, price, servicePrice, state, systemState,
  -- validUntilDate and version. No opportunity reference of any spelling.
  -- NULL on all 3,165 rows since this model was written.
  --
  -- The value is not lost, only discarded: quotes are fetched PER
  -- OPPORTUNITY (GetQuotes 400s without an opportunityId), so
  -- pipelines/dtools/ingest.py loops over the ids and knows which one each
  -- quote came from. Stamping it onto the record at ingest is the fix, and
  -- it is an ingest change rather than a SQL one. Kept here reading a path
  -- that does not exist would be pretending otherwise.
  CAST(NULL AS STRING)                                       AS opportunity_id,
  JSON_VALUE(payload, '$.name')                              AS name,
  COALESCE(JSON_VALUE(payload, '$.quoteNumber'),
           JSON_VALUE(payload, '$.number'))                  AS quote_number,
  -- VERIFIED 2026-09-16: the field is `state`, not `status`, so both paths
  -- below missed and this column was NULL on all 3,165 rows. `systemState`
  -- is D-Tools' own workflow state and answers only where state is absent —
  -- a different thing, not a second spelling. Same bug and same shape as
  -- stg_dtools__projects.status, which looked for a `status` GetProjects
  -- does not return either.
  COALESCE(JSON_VALUE(payload, '$.state.name'),
           JSON_VALUE(payload, '$.state'),
           JSON_VALUE(payload, '$.systemState.name'),
           JSON_VALUE(payload, '$.systemState'))             AS status,
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
  SET OPTIONS (description = "ALWAYS NULL, and not a bug to work around. D-Tools' GetQuotes response carries no opportunity reference — verified 2026-09-16 by listing every key in the raw payload — so there is nothing to read. A quote therefore cannot be joined to its opportunity or to a project from this table today. Do not infer that a quote has no opportunity: every quote has one, and the ingest even knows which, because quotes are fetched one opportunity at a time; the value is discarded rather than recorded. Populating it is an ingest change, not a query someone can write.");
ALTER TABLE staging.stg_dtools__quotes ALTER COLUMN name
  SET OPTIONS (description = "Quote name.");
ALTER TABLE staging.stg_dtools__quotes ALTER COLUMN quote_number
  SET OPTIONS (description = "Quote number shown to the client.");
ALTER TABLE staging.stg_dtools__quotes ALTER COLUMN status
  SET OPTIONS (description = "Where the quote stands in D-Tools, from the payload's state, falling back to D-Tools' own systemState — two different things, so a value here is the finer of them that was present. Was NULL on every row until 2026-09-16: the model looked for a status field the GetQuotes response does not return.");
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
