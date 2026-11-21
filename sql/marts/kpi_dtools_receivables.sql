-- kpi_dtools_receivables — what clients still owe on invoices sent from
-- D-Tools, and how old each one is.
-- Grain: one row per open invoice with a balance (invoice_id).
--
-- Open is stg_dtools__v2_invoices.is_open: D-Tools' own status, not the
-- arithmetic of billed minus paid. An invoice is aged from its billing date,
-- or from the day it was sent when it has none: only 92 of 1,493 invoices
-- carry a due date, so "overdue" by due date would describe almost nothing.
--
-- Column meanings are declared at the end of this file (ALTER COLUMN ...
-- SET OPTIONS). BigQuery serves them to agents through hermes-mcp, so that
-- is the one copy — do not restate them here.
CREATE OR REPLACE TABLE marts.kpi_dtools_receivables
OPTIONS (description = """
What clients still owe on invoices sent from D-Tools, one row per open invoice with a balance, with its project, client and age. Sum balance_due for the total owed; group by project_number or client_name for who owes it, or by age_bucket for how old it is.
THIS IS D-TOOLS' VIEW, NOT THE BOOKS. An invoice stays open here until someone marks it paid in D-Tools. A payment recorded only in QuickBooks, or a deposit request that was replaced or abandoned and never closed, still shows as owed. On the first load (2026-11-21) the table held 88 invoices and $656,000: 52 of them, $447,000, were more than 90 days old, and 41 of those were billed before 2026, when Livewire still sent its payment requests from QuickBooks. Another 11, $145,000, had no date at all. Treat 91+ and Undated rows as questions to check against QuickBooks (kpi_project_margin.ar_balance, stg_qbo__invoices), not as money known to be owed. Rows 0 to 60 days old are the reliable part.
Drafts are not here: a draft has not been sent. Only project invoices are covered, not service contract or service call invoices. Amounts USD.
""")
AS
WITH open_invoices AS (
  SELECT
    *,
    COALESCE(billed_on, DATE(shared_at)) AS aged_from
  FROM staging.stg_dtools__v2_invoices
  -- A few invoices D-Tools still calls Sent are paid in full; nothing is
  -- owed on them, so they are not receivables.
  WHERE is_open
    AND balance_due > 0
)
SELECT
  i.invoice_id,
  i.invoice_number,
  i.project_id,
  p.project_number,
  p.project_name,
  p.client_name,
  p.stage                                            AS project_stage,
  p.completed_at IS NOT NULL                         AS project_completed,
  i.status,
  i.billed_for,
  i.term_name,
  i.change_order_number,
  i.total_amount,
  i.paid_amount,
  i.balance_due,
  i.billed_on,
  i.due_on,
  i.aged_from,
  DATE_DIFF(CURRENT_DATE(), i.aged_from, DAY)        AS days_outstanding,
  CASE
    WHEN i.aged_from IS NULL THEN 'Undated'
    WHEN DATE_DIFF(CURRENT_DATE(), i.aged_from, DAY) <= 30 THEN '0-30'
    WHEN DATE_DIFF(CURRENT_DATE(), i.aged_from, DAY) <= 60 THEN '31-60'
    WHEN DATE_DIFF(CURRENT_DATE(), i.aged_from, DAY) <= 90 THEN '61-90'
    ELSE '91+'
  END                                                AS age_bucket,
  i.viewed_at IS NOT NULL                            AS client_viewed,
  CURRENT_TIMESTAMP()                                AS computed_at
FROM open_invoices AS i
LEFT JOIN staging.stg_dtools__v2_projects AS p USING (project_id);

ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN invoice_id
  SET OPTIONS (description = "D-Tools invoice id; the key. Joins stg_dtools__v2_invoices.invoice_id.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN invoice_number
  SET OPTIONS (description = "Invoice number as shown in D-Tools, e.g. INV-1122.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN project_id
  SET OPTIONS (description = "D-Tools project id; joins stg_dtools__v2_projects.project_id and kpi_project_job_costing.project_id.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN project_number
  SET OPTIONS (description = "D-Tools project number as shown in D-Tools, e.g. P-2140.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN project_name
  SET OPTIONS (description = "Project name.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN client_name
  SET OPTIONS (description = "Client name as entered in D-Tools. One client can have several projects, each with its own invoices.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN project_stage
  SET OPTIONS (description = "Where the project is in D-Tools' project pipeline.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN project_completed
  SET OPTIONS (description = "TRUE when the project is marked completed in D-Tools: the work is done and this invoice is still open.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN status
  SET OPTIONS (description = "D-Tools' status for the invoice: Sent, Due or Overdue. Overdue is D-Tools' own flag and needs a due date, which most invoices lack; use days_outstanding for age.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN billed_for
  SET OPTIONS (description = "What the invoice bills: Quote (a term of the sold proposal, usually the deposit), Change order, or Project (a project-level term such as completion).");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN term_name
  SET OPTIONS (description = "Name of the payment term billed, e.g. Deposit, Payment, Project Completion and Acceptance.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN change_order_number
  SET OPTIONS (description = "Number of the External change order billed, when billed_for is Change order; NULL otherwise.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN total_amount
  SET OPTIONS (description = "Invoice total including tax, USD: what the client was asked to pay.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN paid_amount
  SET OPTIONS (description = "Amount D-Tools records as paid against the invoice so far, USD; 0 when none.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN balance_due
  SET OPTIONS (description = "What is still owed on the invoice, USD: total_amount minus paid_amount. Sum this for receivables.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN billed_on
  SET OPTIONS (description = "Billing date on the invoice; NULL on some.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN due_on
  SET OPTIONS (description = "Due date; NULL on most invoices, since Livewire rarely sets one.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN aged_from
  SET OPTIONS (description = "The date the invoice's age is counted from: billed_on, or the day it was sent when it has no billing date. NULL when it has neither.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN days_outstanding
  SET OPTIONS (description = "Days from aged_from to the day this table was built. NULL when aged_from is NULL.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN age_bucket
  SET OPTIONS (description = "days_outstanding as a bucket: 0-30, 31-60, 61-90, 91+, or Undated when the invoice has no date to age from. 91+ rows are the ones most likely to be already paid outside D-Tools; check them before chasing.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN client_viewed
  SET OPTIONS (description = "TRUE when the client has opened the invoice sent from D-Tools. FALSE also covers invoices never sent through D-Tools' sharing.");
ALTER TABLE marts.kpi_dtools_receivables ALTER COLUMN computed_at
  SET OPTIONS (description = "When this table was built.");
