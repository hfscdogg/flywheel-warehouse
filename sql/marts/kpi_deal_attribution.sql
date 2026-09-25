-- kpi_deal_attribution — every CRM deal ("potential") with who owns it, which
-- channel brought it, and where it stands. Grain: one row per deal.
--
-- The marketing attribution dashboard filters by any date range, rep,
-- channel, status and customer, so it needs deals, not pre-cut weeks or
-- months: kpi_marketing_attribution (weekly) and kpi_sales_pipeline
-- (monthly) cannot be re-cut to an arbitrary range. This table is the row
-- set those filters run over.
--
-- The channel is the CRM Marketing Channel field. Since 2026-04-01 the team
-- reviews each deal and records the channel there, "Not reviewed" included,
-- which is what the dashboard calls its Verified (manual) basis. Measured
-- 2026-09-25 against the dashboard for 2026-04-01 to 09-25: pipeline and
-- estimated revenue matched it to the dollar for referrals ($5,109,941 /
-- $943,635), marketing ($811,077 / $228,780) and unattributed ($49,080 /
-- $20,422). channel_group is the dashboard's grouping of those values.
--
-- New vs existing client depends on the range being looked at, so the table
-- carries the contact's first-ever deal date and the reader compares it
-- with the range start; a stored flag would be right for one range only.
--
-- Column meanings are declared at the end of this file.
CREATE OR REPLACE TABLE marts.kpi_deal_attribution
OPTIONS (description = """
Every Zoho CRM deal (the dashboard calls them potentials), one row per deal: owner, marketing channel, stage, outcome, amount and probability-weighted estimate. Use it for any date range, rep, channel or customer cut; for ready-made weekly or monthly series use kpi_marketing_attribution or kpi_sales_pipeline.
Filter created_date to the range. outcome is won, lost or open from the corrected stage lists. channel_group is the dashboard's grouping; marketing_channel is the reviewed value it comes from, recorded since 2026-04-01 only, so older deals are Not reviewed.
New vs existing client depends on the range: a deal is from a new client when contact_first_deal_date is on or after the range start, from an existing client when before it, and has no client when contact_id is NULL. Amounts USD; CRM test records excluded.
""")
AS
WITH deals AS (
  SELECT *, NULLIF(UPPER(TRIM(marketing_channel)), '') AS ch
  FROM staging.stg_zoho__deals
  WHERE NOT COALESCE(is_test_record, FALSE)
),
first_deal AS (
  SELECT contact_id, MIN(DATE(created_at)) AS contact_first_deal_date
  FROM deals
  WHERE contact_id IS NOT NULL
  GROUP BY contact_id
)
SELECT
  d.deal_id,
  DATE(d.created_at)                  AS created_date,
  d.owner_name,
  NULLIF(TRIM(d.marketing_channel), '') AS marketing_channel,
  -- Compared uppercased and trimmed, as kpi_marketing_attribution does, so
  -- a stray space or a recased picklist value still lands in its group.
  CASE
    WHEN d.ch = 'EXISTING/REPEAT CLIENT'
      THEN 'Existing / repeat clients'
    WHEN d.ch IN ('REFERRAL - BUILDER/TRADE', 'REFERRAL - CLIENT/WORD-OF-MOUTH',
                  'BUSINESS DEVELOPMENT/OUTBOUND')
      THEN 'Referrals & business dev'
    -- kpi_marketing_attribution's marketing-sourced list, the same values.
    WHEN d.ch IN ('WEBSITE INQUIRY', 'GOOGLE ADS (PAID)', 'GOOGLE LSA (PAID)',
                  'DIRECT (PHONE/WALK-IN)', 'GOOGLE/BING ORGANIC',
                  'GOOGLE BUSINESS PROFILE', 'HOUZZ', 'EMAIL/NEWSLETTER')
      THEN 'Marketing & website'
    WHEN d.ch = "UNKNOWN/CAN'T DETERMINE"
      THEN 'Unattributed / unknown'
    WHEN d.ch IS NULL OR d.ch = 'NOT REVIEWED'
      THEN 'Not reviewed'
    -- A value added to the picklist later lands here, visibly, rather than
    -- inside a group it may not belong to.
    ELSE 'Other (unmapped)'
  END                                 AS channel_group,
  d.stage,
  CASE WHEN d.is_won THEN 'won' WHEN d.is_lost THEN 'lost' ELSE 'open' END
                                      AS outcome,
  d.amount,
  d.expected_revenue,
  d.closing_date,
  d.contact_id,
  f.contact_first_deal_date,
  d.account_id,
  d.account_name,
  CURRENT_TIMESTAMP()                 AS computed_at
FROM deals d
LEFT JOIN first_deal f USING (contact_id);

ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN deal_id
  SET OPTIONS (description = "Zoho CRM deal id; the key. One row per deal.");
ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN created_date
  SET OPTIONS (description = "Date the deal was created (UTC). The dashboard's From and To filter this column.");
ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN owner_name
  SET OPTIONS (description = "The rep who owns the deal in the CRM.");
ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN marketing_channel
  SET OPTIONS (description = "The CRM Marketing Channel value as recorded, e.g. Website inquiry, Referral - Builder/Trade, Not reviewed. The team reviews and records it on each deal since 2026-04-01; before that it is almost always NULL. NULL when blank.");
ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN channel_group
  SET OPTIONS (description = "The dashboard's channel grouping: Existing / repeat clients; Referrals & business dev (builder/trade and client referrals, outbound business development); Marketing & website (website inquiry, paid Google, direct and other marketing channels); Unattributed / unknown; Not reviewed (includes NULL, so nearly every deal before 2026-04-01). Other (unmapped) means a channel value this table does not know yet: report it rather than guessing its group.");
ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN stage
  SET OPTIONS (description = "Current CRM pipeline stage.");
ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN outcome
  SET OPTIONS (description = "won, lost or open, from the stage lists corrected 2026-09-25 (Finish Out Complete and Closed Won - Cash and Carry won, RFP Sent open). Won revenue is SUM(amount) WHERE outcome = 'won'.");
ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN amount
  SET OPTIONS (description = "Deal amount, USD. SUM over deals in a range is the dashboard's Total pipeline (sum of Amount), whatever their outcome.");
ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN expected_revenue
  SET OPTIONS (description = "Probability-weighted amount from the CRM, USD: the dashboard's Estimated revenue when summed over every deal, and its Open est. rev when summed over outcome = 'open'.");
ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN closing_date
  SET OPTIONS (description = "Expected or actual closing date entered on the deal.");
ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN contact_id
  SET OPTIONS (description = "CRM contact on the deal; NULL when none is linked (the dashboard's no-contact potentials).");
ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN contact_first_deal_date
  SET OPTIONS (description = "Date of this contact's first-ever deal. Compare with the range start: on or after it means a new client, before it an existing one. Count net-new clients as distinct contact_id with contact_first_deal_date inside the range.");
ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN account_id
  SET OPTIONS (description = "CRM account (the customer) on the deal.");
ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN account_name
  SET OPTIONS (description = "Customer account name. Names a customer: do not paste lists of these outside Livewire.");
ALTER TABLE marts.kpi_deal_attribution ALTER COLUMN computed_at
  SET OPTIONS (description = "When this row was built (UTC).");
