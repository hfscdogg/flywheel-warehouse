-- stg_vendor__securitycentral_recurring — what Security Central charges us,
-- per account, per month.
-- Grain: one row per recurring resource line (an account's Monitoring line
--   plus any test lines it carries), so an account's cost is the SUM of its
--   rows, not the value of any one of them.
-- Source: raw_vendor.securitycentral_recurring (drop-bucket uploads of the
--   "Customer System Recurring" report).
--
-- THE ONLY PLACE A SECURITY CENTRAL PRICE COMES FROM
-- Neither the All Accounts roster nor the weekly Customer Count feed carries
-- a rate. Before this report landed, every Security Central row in the audit
-- had a NULL cost and the leak total was Parasol's alone.
--
-- ALREADY MONTHLY, DO NOT DIVIDE AGAIN
-- The vendor's "Monthly Amount" column is normalized to a month at their
-- end: 12 quarterly and 12 yearly resources print their monthly share
-- (a yearly one reads 4.58333, being $55 a year over 12), not the amount
-- billed on the cycle. frequency is carried through so that stays checkable,
-- but converting by it would divide the same figure twice.
--
-- account_no is the join to the roster and the weekly feed. The report prints
-- it with a space (A1651 1523) where those use a hyphen; the parser
-- normalizes it, so it lines up with account_no in both.
CREATE OR REPLACE TABLE staging.stg_vendor__securitycentral_recurring
OPTIONS (description = """
What Security Central bills Livewire per account each month, from the Customer System Recurring report. ONE ROW PER RESOURCE, not per account: an account's Monitoring line plus its test lines, so an account's monthly cost is the SUM of its rows.
monthly_amount is already a monthly figure for every row including quarterly and yearly ones; never divide it by the frequency again.
This is the only feed carrying a Security Central price at all. Join to the roster and the weekly status feed on account_no. kpi_subscription_audit uses this table.
bill_price is what the CUSTOMER pays Security Central directly, present only for the few direct-billed accounts, and is not our cost.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_vendor.securitycentral_recurring
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id ORDER BY _loaded_at DESC
  ) = 1
)
SELECT
  _source_id                                                 AS line_key,
  JSON_VALUE(payload, '$.ACCOUNT')                           AS account_no,
  JSON_VALUE(payload, '$.CUSTOMER_NO')                       AS customer_no,
  JSON_VALUE(payload, '$.SUBSCRIBER')                        AS subscriber_name,
  JSON_VALUE(payload, '$.MONITORING_NO')                     AS monitoring_no,
  JSON_VALUE(payload, '$.RESOURCE')                          AS resource_code,
  JSON_VALUE(payload, '$.DESCRIPTION')                       AS resource_description,
  JSON_VALUE(payload, '$.FRQ')                               AS frequency,
  SAFE_CAST(JSON_VALUE(payload, '$.MONTHLY_AMOUNT') AS NUMERIC)
                                                             AS monthly_amount,
  SAFE_CAST(JSON_VALUE(payload, '$.BILL_PRICE') AS NUMERIC)  AS bill_price,
  NULLIF(JSON_VALUE(payload, '$.PMT_METHOD'), '')            AS payment_method,
  SAFE.PARSE_DATE('%m/%d/%y', JSON_VALUE(payload, '$.ACTIVATED'))
                                                             AS activated_on,
  SAFE.PARSE_DATE('%m/%d/%y', JSON_VALUE(payload, '$.NEXT_INVOICE'))
                                                             AS next_invoice_on,
  _loaded_at                                                 AS loaded_at
FROM latest;

ALTER TABLE staging.stg_vendor__securitycentral_recurring ALTER COLUMN line_key
  SET OPTIONS (description = "Synthesised key for this resource line: customer number, resource code and account number. The report numbers its lines nothing, so this is built to be stable month to month.");
ALTER TABLE staging.stg_vendor__securitycentral_recurring ALTER COLUMN account_no
  SET OPTIONS (description = "Security Central account number, e.g. A1651-1523. The join to stg_vendor__securitycentral_accounts and stg_vendor__securitycentral_status. Empty on the two lines the report prints without one.");
ALTER TABLE staging.stg_vendor__securitycentral_recurring ALTER COLUMN customer_no
  SET OPTIONS (description = "Security Central's customer number. Dealer-billed customers read 000312-nnnnn; the few direct-billed ones read Cnnnnnnn.");
ALTER TABLE staging.stg_vendor__securitycentral_recurring ALTER COLUMN subscriber_name
  SET OPTIONS (description = "Name on the Security Central record for this customer.");
ALTER TABLE staging.stg_vendor__securitycentral_recurring ALTER COLUMN monitoring_no
  SET OPTIONS (description = "Security Central's internal monitoring number for the system.");
ALTER TABLE staging.stg_vendor__securitycentral_recurring ALTER COLUMN resource_code
  SET OPTIONS (description = "What is being billed: MON is monitoring, TMO/TWK and similar are scheduled test signals.");
ALTER TABLE staging.stg_vendor__securitycentral_recurring ALTER COLUMN resource_description
  SET OPTIONS (description = "The vendor's wording for the resource, e.g. Monitoring, Test Monthly, Weekly Test.");
ALTER TABLE staging.stg_vendor__securitycentral_recurring ALTER COLUMN frequency
  SET OPTIONS (description = "Billing cycle the vendor invoices on: 1M monthly, 1Q quarterly, 2Q twice-quarterly, 1Y yearly. Informational only — monthly_amount is ALREADY monthly and must not be divided by this.");
ALTER TABLE staging.stg_vendor__securitycentral_recurring ALTER COLUMN monthly_amount
  SET OPTIONS (description = "What Security Central charges us for this resource per month, USD, exactly as the report prints it. Already reduced to a monthly figure on quarterly and yearly rows. SUM the rows of an account to get that account's monthly cost; 0.00 is a real free line, usually a test signal.");
ALTER TABLE staging.stg_vendor__securitycentral_recurring ALTER COLUMN bill_price
  SET OPTIONS (description = "What the CUSTOMER pays Security Central directly, for the few accounts Security Central bills direct. NOT our cost, and NULL on the dealer-billed majority.");
ALTER TABLE staging.stg_vendor__securitycentral_recurring ALTER COLUMN payment_method
  SET OPTIONS (description = "How a direct-billed customer pays Security Central (CHECK, BANK-DRAFT, CC-DRAFT). NULL for dealer-billed accounts.");
ALTER TABLE staging.stg_vendor__securitycentral_recurring ALTER COLUMN activated_on
  SET OPTIONS (description = "When this resource started billing.");
ALTER TABLE staging.stg_vendor__securitycentral_recurring ALTER COLUMN next_invoice_on
  SET OPTIONS (description = "Date the vendor next invoices this resource.");
ALTER TABLE staging.stg_vendor__securitycentral_recurring ALTER COLUMN loaded_at
  SET OPTIONS (description = "When this record was last loaded into the warehouse (UTC).");
