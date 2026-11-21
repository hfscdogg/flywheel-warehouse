-- stg_dtools__v2_invoices — the invoices (payment requests) sent from D-Tools.
-- Grain: one row per invoice_id.
-- Source: raw_dtools.v2_project_billing (append-only; payload = one project's
-- invoices and change orders as pipelines/dtools/v2.py landed them). The
-- newest record per project wins BY LOAD, not by the project's modified
-- time: an invoice is paid without its project changing, so two records of
-- one project can carry the same modified time and different payments.
--
-- Paths verified 2026-11-21 against the first full load (1,699 projects,
-- 1,493 invoices). An invoice does not name its project; the record it
-- landed in does. Its paymentPaymentTerms array says what it bills: 1,491
-- invoices carry one line and 2 carry two, so the first line stands for the
-- invoice. dueDate is filled on 92 invoices and integrationNumber on 7.
--
-- paidAmount cannot settle what is owed on its own: 10 invoices D-Tools
-- calls Paid show less paid than billed, 7 Drafts show money paid, and 12
-- show more paid than billed. D-Tools' status is the statement of whether an
-- invoice is settled; the amounts say how much.
CREATE OR REPLACE TABLE staging.stg_dtools__v2_invoices
OPTIONS (description = """
Invoices sent to clients from D-Tools, one row per invoice: deposit requests, progress payments, final payments and change order payments, with what was billed, what was paid and when. Livewire has billed projects from D-Tools, not QuickBooks, since early 2026; D-Tools invoices here go back to May 2023.
is_open says whether money is still expected and balance_due how much; use those, not total_amount minus paid_amount, which is unreliable on settled invoices. A Draft has not been sent and is not owed. This is D-Tools' view only: a payment taken outside D-Tools and never marked there still shows as open. integration_number, the link to QuickBooks, is empty on nearly every invoice. Amounts USD.
""")
AS
WITH latest AS (
  SELECT payload, _source_id, _loaded_at
  FROM raw_dtools.v2_project_billing
  WHERE _source_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _source_id
    ORDER BY _loaded_at DESC
  ) = 1
),
invoices AS (
  SELECT
    _source_id AS project_id,
    inv,
    JSON_QUERY_ARRAY(inv, '$.paymentPaymentTerms')[SAFE_OFFSET(0)] AS term,
    _loaded_at AS loaded_at
  FROM latest,
       UNNEST(JSON_QUERY_ARRAY(payload, '$.invoices')) AS inv
),
fields AS (
  SELECT
    JSON_VALUE(inv, '$.id')                                             AS invoice_id,
    project_id,
    NULLIF(TRIM(JSON_VALUE(inv, '$.number')), '')                       AS invoice_number,
    JSON_VALUE(inv, '$.status')                                         AS status,
    CASE
      WHEN JSON_VALUE(term, '$.changeOrderId') IS NOT NULL THEN 'Change order'
      WHEN JSON_VALUE(term, '$.quoteId') IS NOT NULL THEN 'Quote'
      WHEN term IS NOT NULL THEN 'Project'
    END                                                                 AS billed_for,
    JSON_VALUE(term, '$.term')                                          AS term_name,
    NULLIF(TRIM(JSON_VALUE(term, '$.quoteNumber')), '')                 AS quote_number,
    SAFE_CAST(JSON_VALUE(term, '$.changeOrderNumber') AS INT64)         AS change_order_number,
    ROUND(SAFE_CAST(JSON_VALUE(inv, '$.amount') AS NUMERIC), 2)         AS amount,
    ROUND(SAFE_CAST(JSON_VALUE(inv, '$.tax') AS NUMERIC), 2)            AS tax,
    ROUND(SAFE_CAST(JSON_VALUE(inv, '$.totalAmount') AS NUMERIC), 2)    AS total_amount,
    ROUND(COALESCE(SAFE_CAST(JSON_VALUE(inv, '$.paidAmount') AS NUMERIC), 0), 2)
                                                                        AS paid_amount,
    ROUND(COALESCE(SAFE_CAST(JSON_VALUE(inv, '$.refundAmount') AS NUMERIC), 0), 2)
                                                                        AS refund_amount,
    DATE(SAFE_CAST(JSON_VALUE(inv, '$.billingDate') AS TIMESTAMP))      AS billed_on,
    DATE(SAFE_CAST(JSON_VALUE(inv, '$.dueDate') AS TIMESTAMP))          AS due_on,
    DATE(SAFE_CAST(JSON_VALUE(inv, '$.paidDate') AS TIMESTAMP))         AS paid_on,
    SAFE_CAST(JSON_VALUE(inv, '$.sharedOn') AS TIMESTAMP)               AS shared_at,
    SAFE_CAST(JSON_VALUE(inv, '$.viewedOn') AS TIMESTAMP)               AS viewed_at,
    NULLIF(TRIM(JSON_VALUE(inv, '$.integrationNumber')), '')            AS integration_number,
    COALESCE(SAFE_CAST(JSON_VALUE(inv, '$.archived') AS BOOL), FALSE)   AS is_archived,
    loaded_at
  FROM invoices
),
judged AS (
  SELECT
    *,
    -- Settled or not yet sent, by D-Tools' own word. Any status not named
    -- here counts as open: a status this model has never seen should show up
    -- in receivables and be questioned, not vanish from them.
    NOT is_archived
      AND COALESCE(status, '') NOT IN ('Paid', 'Deposited', 'Draft', 'Partially Refunded')
      AS is_open
  FROM fields
)
SELECT
  invoice_id,
  project_id,
  invoice_number,
  status,
  is_open,
  IF(is_open, GREATEST(total_amount - paid_amount, 0), 0) AS balance_due,
  billed_for,
  term_name,
  quote_number,
  change_order_number,
  amount,
  tax,
  total_amount,
  paid_amount,
  refund_amount,
  billed_on,
  due_on,
  paid_on,
  shared_at,
  viewed_at,
  integration_number,
  is_archived,
  loaded_at
FROM judged;

ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN invoice_id
  SET OPTIONS (description = "D-Tools invoice id; the key.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN project_id
  SET OPTIONS (description = "D-Tools project the invoice belongs to; joins stg_dtools__v2_projects.project_id.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN invoice_number
  SET OPTIONS (description = "Invoice number as shown in D-Tools, e.g. INV-1122.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN status
  SET OPTIONS (description = "D-Tools' status for the invoice. Seen: Draft (not sent), Sent, Due, Overdue, Paid, Deposited (paid and banked), Partially Refunded.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN is_open
  SET OPTIONS (description = "TRUE when money is still expected: not archived, and status is anything other than Paid, Deposited, Draft or Partially Refunded. A status never seen before counts as open so it shows up and gets questioned.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN balance_due
  SET OPTIONS (description = "What is still owed on the invoice, USD: total_amount minus paid_amount when is_open, never below zero; 0 when not open. Sum this for receivables.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN billed_for
  SET OPTIONS (description = "What the invoice bills: Quote (a term of the sold proposal, usually the deposit), Change order, or Project (a project-level term such as completion). From the invoice's first term line.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN term_name
  SET OPTIONS (description = "Name of the payment term billed, e.g. Deposit, Payment, Project Completion and Acceptance.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN quote_number
  SET OPTIONS (description = "D-Tools quote number the invoice bills, when billed_for is Quote. Matches stg_dtools__v2_project_proposals.quote_number and a Zoho deal's estimate_number.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN change_order_number
  SET OPTIONS (description = "Number of the change order the invoice bills, when billed_for is Change order. Always an External one: joins stg_dtools__v2_change_orders on project_id and change_order_number where change_type = 'External'.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN amount
  SET OPTIONS (description = "Invoice amount before tax, USD.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN tax
  SET OPTIONS (description = "Sales tax on the invoice, USD.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN total_amount
  SET OPTIONS (description = "Invoice total including tax, USD: what the client was asked to pay.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN paid_amount
  SET OPTIONS (description = "Amount D-Tools records as paid, USD; 0 when none. Not reliable alone: some Paid invoices show less than total_amount and a few show more. Use is_open and balance_due for what is owed.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN refund_amount
  SET OPTIONS (description = "Amount refunded, USD; 0 when none.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN billed_on
  SET OPTIONS (description = "Billing date on the invoice. NULL on a few; fall back to shared_at.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN due_on
  SET OPTIONS (description = "Due date. NULL on most invoices: Livewire rarely sets one, so age an invoice from billed_on, not from this.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN paid_on
  SET OPTIONS (description = "Date D-Tools records the payment; NULL while unpaid.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN shared_at
  SET OPTIONS (description = "When the invoice was sent to the client from D-Tools; NULL if never shared that way.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN viewed_at
  SET OPTIONS (description = "When the client first opened the invoice; NULL if they have not.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN integration_number
  SET OPTIONS (description = "The invoice's number in the accounting system (QuickBooks). NULL on nearly every invoice, so it cannot be used to match D-Tools invoices to QuickBooks in general.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN is_archived
  SET OPTIONS (description = "TRUE when the invoice is archived in D-Tools. Archived invoices are never open.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN loaded_at
  SET OPTIONS (description = "When the warehouse last read this invoice's project from D-Tools. Open projects and projects with an open invoice are re-read nightly, the rest weekly.");
