-- kpi_dtools_receivables — the collections worklist: every D-Tools invoice
-- that D-Tools still shows unpaid, with a QuickBooks cross-check.
-- Grain: one row per unpaid D-Tools invoice (invoice_id).
--
-- WHY BOTH SYSTEMS. Payment requests (deposits, progress payments, change
-- orders) go out from D-Tools. QuickBooks holds the revenue invoices those
-- payments are later applied to; a deposit for future work lands in
-- QuickBooks as a payment with no invoice. So QuickBooks AR alone misses
-- requests not yet invoiced there, and D-Tools alone overstates what is
-- owed: a request paid by check and entered only in QuickBooks keeps its
-- Sent status in D-Tools. On 2026-11-22, 15 of the unpaid D-Tools invoices
-- of $3,000 or more had a QuickBooks payment for the exact amount.
--
-- THE QUICKBOOKS LINK IS A HINT, NOT A KEY. The two systems share no invoice
-- key, and names are never matched (see kpi_project_job_costing). The only
-- cross-check is a QuickBooks payment for exactly the invoice's total, dated
-- no earlier than a week before the invoice. It misses payments made in
-- parts or combined with other invoices, and two unrelated payments can
-- share an amount, so next_step says check_quickbooks, never paid.
--
-- Column meanings are declared at the end of this file (ALTER COLUMN ...
-- SET OPTIONS). BigQuery serves them to agents through hermes-mcp, so that
-- is the one copy — do not restate them here.
CREATE OR REPLACE TABLE marts.kpi_dtools_receivables
OPTIONS (description = """
Collections worklist: one row per D-Tools invoice (payment request) that D-Tools still shows unpaid, with its project, age and a QuickBooks cross-check. next_step sorts them: collect, not_sent or check_quickbooks.
SUM(open_balance) is NOT what clients owe: requests paid outside D-Tools still appear, flagged check_quickbooks only when a QuickBooks payment matches the exact amount. Sum next_step = 'collect' for the best estimate, and expect some of that to be paid too.
Current state at build time, no history. Excludes archived invoices. Amounts USD. Rebuilt daily.
""")
AS
WITH unpaid AS (
  SELECT *
  FROM staging.stg_dtools__v2_invoices
  WHERE status IN ('Draft', 'Sent', 'Due', 'Overdue')
    AND NOT COALESCE(is_archived, FALSE)
    AND open_balance > 0.50
),
qbo_match AS (
  SELECT
    u.invoice_id,
    COUNT(*)                                            AS qbo_same_amount_payments,
    ARRAY_AGG(p.txn_date ORDER BY p.txn_date LIMIT 1)[OFFSET(0)]      AS qbo_payment_date,
    ARRAY_AGG(p.customer_name ORDER BY p.txn_date LIMIT 1)[OFFSET(0)] AS qbo_payment_customer
  FROM unpaid AS u
  JOIN staging.stg_qbo__payments AS p
    ON ABS(p.total_amount - u.total_amount) < 0.01
   AND p.txn_date >= DATE_SUB(COALESCE(u.billing_date, DATE(u.shared_at), DATE '2000-01-01'),
                              INTERVAL 7 DAY)
  GROUP BY u.invoice_id
)
SELECT
  u.invoice_id,
  u.invoice_number,
  CASE
    WHEN m.invoice_id IS NOT NULL THEN 'check_quickbooks'
    WHEN u.status = 'Draft' THEN 'not_sent'
    ELSE 'collect'
  END                                                   AS next_step,
  u.status                                              AS dtools_status,
  pr.client_name,
  pr.project_number,
  pr.project_name,
  pr.stage                                              AS project_stage,
  u.payment_terms,
  u.has_change_order,
  u.billing_date,
  u.due_date,
  DATE(u.shared_at)                                     AS shared_date,
  DATE(u.viewed_at)                                     AS viewed_date,
  u.total_amount,
  u.paid_amount,
  u.open_balance,
  COALESCE(u.due_date < CURRENT_DATE(), FALSE) OR u.status = 'Overdue' AS is_past_due,
  DATE_DIFF(CURRENT_DATE(),
            COALESCE(u.due_date, u.billing_date, DATE(u.shared_at)), DAY) AS age_days,
  COALESCE(m.qbo_same_amount_payments, 0)               AS qbo_same_amount_payments,
  m.qbo_payment_date,
  m.qbo_payment_customer,
  u.project_id
FROM unpaid AS u
LEFT JOIN staging.stg_dtools__v2_projects AS pr USING (project_id)
LEFT JOIN qbo_match AS m USING (invoice_id);

ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN invoice_id
  SET OPTIONS (description = "D-Tools invoice id; the key. Joins stg_dtools__v2_invoices.invoice_id.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN invoice_number
  SET OPTIONS (description = "Invoice number as shown in D-Tools, e.g. INV-1557.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN next_step
  SET OPTIONS (description = "What to do with the invoice. collect: sent and no QuickBooks payment matches, so chase it. not_sent: still a draft in D-Tools, decide whether to send. check_quickbooks: a QuickBooks payment for the exact amount exists, so it is probably paid and D-Tools needs updating.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN dtools_status
  SET OPTIONS (description = "Status in D-Tools: Draft, Sent, Due or Overdue.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN client_name
  SET OPTIONS (description = "Client name on the D-Tools project.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN project_number
  SET OPTIONS (description = "D-Tools project number, e.g. P-2694.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN project_name
  SET OPTIONS (description = "D-Tools project name.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN project_stage
  SET OPTIONS (description = "Where the project is in D-Tools' pipeline. An unpaid deposit on a Completed project, or any request on an Estimate, deserves a second look before chasing.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN payment_terms
  SET OPTIONS (description = "The payment terms this invoice requests, e.g. Deposit or Project Completion and Acceptance.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN has_change_order
  SET OPTIONS (description = "TRUE when the invoice bills a change order.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN billing_date
  SET OPTIONS (description = "Invoice date in D-Tools; NULL on many invoices from 2023.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN due_date
  SET OPTIONS (description = "Date payment is due; often NULL on deposits.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN shared_date
  SET OPTIONS (description = "Date the invoice was shared with the client from D-Tools; NULL if never shared that way.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN viewed_date
  SET OPTIONS (description = "Date the client last opened the shared invoice; NULL if never opened.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN total_amount
  SET OPTIONS (description = "Amount requested including tax, USD.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN paid_amount
  SET OPTIONS (description = "Amount D-Tools shows as paid so far, USD.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN open_balance
  SET OPTIONS (description = "total_amount minus paid_amount, USD: what D-Tools still shows unpaid. Not proof it is owed; read with next_step.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN is_past_due
  SET OPTIONS (description = "TRUE when the due date has passed or D-Tools marks the invoice Overdue. FALSE when there is no due date.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN age_days
  SET OPTIONS (description = "Days since the due date, or the billing date when there is none, or the shared date; negative when not yet due, NULL when the invoice carries no date. Anything over about 120 with no QuickBooks match is more likely stale than owed.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN qbo_same_amount_payments
  SET OPTIONS (description = "Count of QuickBooks payments for exactly total_amount dated no earlier than a week before the invoice. 0 does not prove it is unpaid: split or combined payments do not match.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN qbo_payment_date
  SET OPTIONS (description = "Date of the earliest matching QuickBooks payment; NULL when none.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN qbo_payment_customer
  SET OPTIONS (description = "QuickBooks customer on that payment, for a person to compare with client_name and project_name. The match is by amount only, never by name.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN project_id
  SET OPTIONS (description = "D-Tools project id; joins stg_dtools__v2_projects and kpi_project_job_costing.");
