-- stg_dtools__v2_invoices — one row per D-Tools invoice (a payment request
-- sent to a client), from the latest landed copy of each project's billing.
-- Grain: one row per invoice_id.
-- Source: raw_dtools.v2_project_billing (append-only; payload = one project's
-- invoices and change_orders arrays, wrapped with project_id).
--
-- D-Tools is where Livewire asks for money (deposits, progress payments,
-- change orders); QuickBooks is where revenue invoices live. A request paid
-- outside D-Tools often keeps its Sent status here, so status alone does not
-- say whether money is owed: see marts.kpi_dtools_receivables.
CREATE OR REPLACE TABLE staging.stg_dtools__v2_invoices
OPTIONS (description = """
D-Tools invoices, one row per invoice: the payment requests sent to clients from D-Tools (deposits, progress payments, change orders), what was asked, what D-Tools shows as paid and when.
A request paid outside D-Tools can still read Sent here, so open_balance overstates what is owed. Use marts.kpi_dtools_receivables for collections. Amounts USD.
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
    JSON_VALUE(i, '$.id')                                             AS invoice_id,
    _source_id                                                        AS project_id,
    JSON_VALUE(i, '$.number')                                         AS invoice_number,
    JSON_VALUE(i, '$.status')                                         AS status,
    SAFE_CAST(JSON_VALUE(i, '$.archived') AS BOOL)                    AS is_archived,
    (SELECT STRING_AGG(
              COALESCE(JSON_VALUE(t, '$.term'),
                       CONCAT('Change order ', JSON_VALUE(t, '$.changeOrderNumber'))),
              ' + ' ORDER BY SAFE_CAST(JSON_VALUE(t, '$.order') AS INT64))
       FROM UNNEST(JSON_QUERY_ARRAY(i, '$.paymentPaymentTerms')) AS t) AS payment_terms,
    EXISTS (SELECT 1
              FROM UNNEST(JSON_QUERY_ARRAY(i, '$.paymentPaymentTerms')) AS t
             WHERE JSON_VALUE(t, '$.changeOrderId') IS NOT NULL)       AS has_change_order,
    SAFE_CAST(SUBSTR(JSON_VALUE(i, '$.billingDate'), 1, 10) AS DATE)  AS billing_date,
    SAFE_CAST(SUBSTR(JSON_VALUE(i, '$.dueDate'), 1, 10) AS DATE)      AS due_date,
    SAFE_CAST(JSON_VALUE(i, '$.sharedOn') AS TIMESTAMP)               AS shared_at,
    SAFE_CAST(JSON_VALUE(i, '$.viewedOn') AS TIMESTAMP)               AS viewed_at,
    SAFE_CAST(SUBSTR(JSON_VALUE(i, '$.paidDate'), 1, 10) AS DATE)     AS paid_date,
    ROUND(SAFE_CAST(JSON_VALUE(i, '$.totalAmount') AS NUMERIC), 2)    AS total_amount,
    ROUND(SAFE_CAST(JSON_VALUE(i, '$.tax') AS NUMERIC), 2)            AS tax_amount,
    ROUND(COALESCE(SAFE_CAST(JSON_VALUE(i, '$.paidAmount') AS NUMERIC), 0), 2)   AS paid_amount,
    ROUND(COALESCE(SAFE_CAST(JSON_VALUE(i, '$.refundAmount') AS NUMERIC), 0), 2) AS refund_amount,
    _loaded_at                                                        AS loaded_at
  FROM latest,
       UNNEST(JSON_QUERY_ARRAY(payload, '$.invoices')) AS i
)
SELECT
  invoice_id,
  project_id,
  invoice_number,
  status,
  is_archived,
  payment_terms,
  has_change_order,
  billing_date,
  due_date,
  shared_at,
  viewed_at,
  paid_date,
  total_amount,
  tax_amount,
  paid_amount,
  refund_amount,
  ROUND(total_amount - paid_amount, 2) AS open_balance,
  loaded_at
FROM invoices
WHERE invoice_id IS NOT NULL
-- An invoice belongs to one project; keep the newest copy if it ever lands
-- under two.
QUALIFY ROW_NUMBER() OVER (PARTITION BY invoice_id ORDER BY loaded_at DESC) = 1;

ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN invoice_id
  SET OPTIONS (description = "D-Tools invoice id; the key.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN project_id
  SET OPTIONS (description = "D-Tools project the invoice bills; joins stg_dtools__v2_projects.project_id.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN invoice_number
  SET OPTIONS (description = "Invoice number as shown in D-Tools, e.g. INV-1557.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN status
  SET OPTIONS (description = "D-Tools status: Draft, Sent, Due, Overdue, Paid, Deposited or Partially Refunded. Sent, Due and Overdue are not proof money is owed: payments taken outside D-Tools do not update it.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN is_archived
  SET OPTIONS (description = "TRUE when the invoice is archived in D-Tools.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN payment_terms
  SET OPTIONS (description = "The project payment terms this invoice requests, e.g. Deposit or Project Completion and Acceptance; several joined with a plus sign.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN has_change_order
  SET OPTIONS (description = "TRUE when the invoice bills a change order.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN billing_date
  SET OPTIONS (description = "Invoice date in D-Tools. NULL on many invoices from 2023.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN due_date
  SET OPTIONS (description = "Date payment is due. Often NULL on deposits.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN shared_at
  SET OPTIONS (description = "When the invoice was shared with the client from D-Tools; NULL if never shared that way.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN viewed_at
  SET OPTIONS (description = "When the client last opened the shared invoice; NULL if never opened.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN paid_date
  SET OPTIONS (description = "Date D-Tools recorded payment; NULL while unpaid in D-Tools.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN total_amount
  SET OPTIONS (description = "Amount requested including tax, USD.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN tax_amount
  SET OPTIONS (description = "Sales tax included in total_amount, USD.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN paid_amount
  SET OPTIONS (description = "Amount D-Tools shows as paid, USD; 0 when none. Can include card fees, so it may exceed total_amount.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN refund_amount
  SET OPTIONS (description = "Amount refunded through D-Tools, USD; 0 when none.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN open_balance
  SET OPTIONS (description = "total_amount minus paid_amount, USD: what D-Tools itself still shows unpaid. Can be negative when fees were paid on top.");
ALTER TABLE staging.stg_dtools__v2_invoices ALTER COLUMN loaded_at
  SET OPTIONS (description = "When the warehouse loaded this version of the project's billing.");
