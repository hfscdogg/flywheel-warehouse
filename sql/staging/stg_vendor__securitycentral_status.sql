-- stg_vendor__securitycentral_status — latest known status per account, from
-- the weekly Security Central "Customer Count" report.
-- Grain: one row per contract number.
-- Source: raw_vendor.securitycentral_status (drop-bucket uploads of the
--   "Customer Count" report; the table is named for what it holds).
--
-- This report carries no address — that lives in the All Accounts export,
-- which the central station cannot schedule yet. The two join cleanly on
-- CONTRACT (verified 586/586 across the 2026-08-27 files), so addresses come
-- from the occasional roster and status from this weekly feed.
--
-- SUBSCRIBER packs the name and account into one string:
--   "William Goodrum (Cottage) [A1651/1857]"
-- The bracketed account uses "/" where the roster export uses "-"
-- (A1651/1857 vs A1651-1857), so it is normalized here for joinability.
CREATE OR REPLACE TABLE staging.stg_vendor__securitycentral_status AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_vendor.securitycentral_status
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id ORDER BY _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                 AS contract_no,
  JSON_VALUE(payload, '$.STATUS')                            AS status,
  JSON_VALUE(payload, '$.STATUS') = 'Active'                 AS is_active_at_vendor,
  TRIM(REGEXP_REPLACE(JSON_VALUE(payload, '$.SUBSCRIBER'), r'\[[^\]]*\]', ''))
                                                             AS subscriber_name,
  REPLACE(REGEXP_EXTRACT(JSON_VALUE(payload, '$.SUBSCRIBER'), r'\[([^\]]+)\]'), '/', '-')
                                                             AS account_no,
  SAFE.PARSE_DATE('%m/%d/%Y', JSON_VALUE(payload, '$.STARTED')) AS started_on,
  _loaded_at                                                 AS loaded_at
FROM latest;
