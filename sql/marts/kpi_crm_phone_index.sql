-- kpi_crm_phone_index — every phone number in the CRM, as a match key, with
-- the record it belongs to and that record's deals.
-- Grain: one row per (phone_key, record_type, record_id).
--
-- Why: call tracking (CallRail) knows who called; the CRM knows who became a
-- lead, a deal and a sale. Nobody tags calls by hand reliably (Livewire: 0 of
-- 15 first-time callers tagged, week of 2026-11-10), so the kitchen's weekly
-- brief joins the two on the caller's number instead. It hashes each caller
-- number the same way and looks the keys up here.
--
-- The key is SHA-256 of 'flywheel-phone:' plus the 10-digit North American
-- number. It keeps raw numbers out of the mart and out of the brief, but it
-- is a match key, not encryption: ten digits can be recovered by brute force,
-- so the table is still personal data and stays inside the client's project.
--
-- Normalisation, mirrored exactly by the kitchen (kitchen/sources/crm_match.py):
-- drop a trailing extension (x, ext, extension, #), keep digits only, drop a
-- leading country code 1 from an 11-digit number, and keep only a valid
-- 10-digit NANP number (area code and exchange both start 2-9). Anything
-- else (international, short, junk) gets no key and no row.
--
-- Sources: lead Phone, contact Phone and Mobile, account Phone. Leads have no
-- deals (Zoho turns a converted lead into a contact and account). A contact's
-- deals are those on the contact or on its account; an account's deals are
-- those on the account. Test deals are excluded.
CREATE OR REPLACE TABLE marts.kpi_crm_phone_index
OPTIONS (description = """
Every phone number in the Zoho CRM as a hashed match key, one row per (phone_key, record_type, record_id), with the record's creation date and its deals. Used to match call-tracking callers to the CRM without anyone tagging calls: hash the caller's number the same way and look up phone_key.
phone_key is TO_HEX(SHA256('flywheel-phone:' || ten_digits)), where ten_digits is the North American number with any extension, punctuation and leading country code 1 removed. Raw numbers are not in this table, but the key is reversible by brute force, so treat it as personal data.
A number can belong to several records (a household's account and contact, or a shared office line); records_sharing_phone says how many. Leads carry no deals. Do not count rows as people: count DISTINCT phone_key.
""")
AS
WITH raw_numbers AS (
  SELECT 'lead' AS record_type, lead_id AS record_id,
         CAST(NULL AS STRING) AS contact_id, CAST(NULL AS STRING) AS account_id,
         phone AS raw_phone, created_at
  FROM staging.stg_zoho__leads
  UNION ALL
  SELECT 'contact', contact_id, contact_id, account_id, phone, created_at
  FROM staging.stg_zoho__contacts
  UNION ALL
  SELECT 'contact', contact_id, contact_id, account_id, mobile, created_at
  FROM staging.stg_zoho__contacts
  UNION ALL
  SELECT 'account', account_id, CAST(NULL AS STRING), account_id, phone, created_at
  FROM staging.stg_zoho__accounts
),
digits AS (
  SELECT *,
    REGEXP_REPLACE(
      REGEXP_REPLACE(COALESCE(raw_phone, ''), r'(?i)\s*(x|ext\.?|extension|#)\s*\d+\s*$', ''),
      r'\D', '') AS d0
  FROM raw_numbers
),
ten AS (
  SELECT *, IF(LENGTH(d0) = 11 AND STARTS_WITH(d0, '1'), SUBSTR(d0, 2), d0) AS d10
  FROM digits
),
keyed AS (
  -- A contact with the same number in Phone and Mobile is one row.
  SELECT DISTINCT
    TO_HEX(SHA256(CONCAT('flywheel-phone:', d10))) AS phone_key,
    record_type, record_id, contact_id, account_id,
    DATE(created_at) AS record_created_date
  FROM ten
  WHERE REGEXP_CONTAINS(d10, r'^[2-9][0-9]{2}[2-9][0-9]{6}$')
),
deals AS (
  SELECT deal_id, contact_id, account_id, DATE(created_at) AS created_date,
    CASE WHEN is_won THEN 'won' WHEN is_lost THEN 'lost' ELSE 'open' END AS outcome,
    amount,
    REGEXP_CONTAINS(LOWER(CONCAT(COALESCE(deal_name, ''), ' ', COALESCE(stage, ''))),
                    r'service call') AS is_service_call
  FROM staging.stg_zoho__deals
  WHERE NOT COALESCE(is_test_record, FALSE)
),
record_deals AS (
  SELECT k.phone_key, k.record_type, k.record_id,
    -- No matching deal gives a NULL, which IGNORE NULLS drops; a bare
    -- STRUCT of NULLs would not be dropped and would count as a deal.
    ARRAY_AGG(IF(dl.deal_id IS NULL, NULL,
                 STRUCT(dl.deal_id, dl.created_date, dl.outcome, dl.amount, dl.is_service_call))
              IGNORE NULLS ORDER BY dl.created_date) AS deals
  FROM keyed k
  LEFT JOIN deals dl
    ON k.record_type != 'lead'
   AND (dl.account_id = k.account_id OR (k.contact_id IS NOT NULL AND dl.contact_id = k.contact_id))
  GROUP BY 1, 2, 3
)
SELECT
  k.phone_key,
  k.record_type,
  k.record_id,
  k.contact_id,
  k.account_id,
  k.record_created_date,
  COUNT(*) OVER (PARTITION BY k.phone_key) AS records_sharing_phone,
  -- ARRAY_AGG of nothing but NULLs is NULL, not []; read none as [].
  COALESCE(rd.deals, []) AS deals,
  CURRENT_TIMESTAMP() AS computed_at
FROM keyed k
JOIN record_deals rd USING (phone_key, record_type, record_id);

ALTER TABLE marts.kpi_crm_phone_index ALTER COLUMN phone_key
  SET OPTIONS (description = "TO_HEX(SHA256('flywheel-phone:' || ten_digits)) of the 10-digit North American number. Hash a caller's number the same way to look it up. Reversible by brute force: personal data, never paste outside Livewire.");
ALTER TABLE marts.kpi_crm_phone_index ALTER COLUMN record_type
  SET OPTIONS (description = "lead, contact or account: the CRM module the number was found on.");
ALTER TABLE marts.kpi_crm_phone_index ALTER COLUMN record_id
  SET OPTIONS (description = "Zoho CRM id of that lead, contact or account.");
ALTER TABLE marts.kpi_crm_phone_index ALTER COLUMN contact_id
  SET OPTIONS (description = "The contact id for a contact row; NULL for leads and accounts.");
ALTER TABLE marts.kpi_crm_phone_index ALTER COLUMN account_id
  SET OPTIONS (description = "The account a contact belongs to, or the account itself for an account row; NULL for leads.");
ALTER TABLE marts.kpi_crm_phone_index ALTER COLUMN record_created_date
  SET OPTIONS (description = "Date the lead, contact or account was created in the CRM (UTC). Created before a call means the caller was already known; created on or after it means the call became a new CRM record.");
ALTER TABLE marts.kpi_crm_phone_index ALTER COLUMN records_sharing_phone
  SET OPTIONS (description = "How many rows carry this phone_key. 1 is a clean match; more is a household (account plus contact) or a shared line such as a builder's office, so a match is less certain.");
ALTER TABLE marts.kpi_crm_phone_index ALTER COLUMN deals
  SET OPTIONS (description = "Every non-test deal on the contact or its account (or on the account), oldest first: deal_id, created_date, outcome (won, lost or open, the stage lists of stg_zoho__deals), amount (USD) and is_service_call. Empty for leads and for records with no deals.");
ALTER TABLE marts.kpi_crm_phone_index ALTER COLUMN computed_at
  SET OPTIONS (description = "When this row was built (UTC).");
