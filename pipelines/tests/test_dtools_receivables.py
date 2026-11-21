"""D-Tools invoices are read the way that makes receivables true.

Three choices in these models are each one plausible edit away from a wrong
number that nothing else would catch:

- The newest record per project is the newest LOAD. Every other v2 staging
  model orders by the source's modified time first, and copying that here
  would be natural and wrong: an invoice is paid without its project's
  modified time moving, so the record that shows the payment and the one
  before it tie, and the unpaid one can win.
- Open is decided by D-Tools' status, with unknown statuses open. On the
  first load 10 Paid invoices showed less paid than billed and 7 Drafts
  showed money paid; billed-minus-paid alone would have invented receivables
  and hidden others.
- Age runs from the billing date. 92 of 1,493 invoices carry a due date.
"""

import pathlib
import re
import unittest

SQL = pathlib.Path(__file__).resolve().parents[2] / "sql"
INVOICES = (SQL / "staging" / "stg_dtools__v2_invoices.sql").read_text()
CHANGE_ORDERS = (SQL / "staging" / "stg_dtools__v2_change_orders.sql").read_text()
MART = (SQL / "marts" / "kpi_dtools_receivables.sql").read_text()


def code(sql):
    """The model without comments or descriptions, whitespace collapsed."""
    sql = sql[sql.index('""")\nAS\n'):sql.index("\nALTER TABLE")]
    return re.sub(r"\s+", " ", re.sub(r"--[^\n]*", "", sql))


class NewestByLoad(unittest.TestCase):
    def test_both_models_take_the_newest_load_per_project(self):
        for name, sql in (("invoices", INVOICES), ("change orders", CHANGE_ORDERS)):
            with self.subTest(model=name):
                body = code(sql)
                self.assertIn("FROM raw_dtools.v2_project_billing", body)
                self.assertIn(
                    "PARTITION BY _source_id ORDER BY _loaded_at DESC ) = 1", body)
                self.assertNotIn("_modified_at", body)


class Open(unittest.TestCase):
    def closed_statuses(self):
        m = re.search(r"COALESCE\(status, ''\) NOT IN \(([^)]*)\)\s+AS is_open",
                      code(INVOICES))
        self.assertIsNotNone(m, "is_open is no longer a NOT IN over status")
        return set(re.findall(r"'([^']+)'", m.group(1)))

    def test_only_settled_and_unsent_statuses_are_closed(self):
        # Anything else, including a status never seen, stays open and shows.
        self.assertEqual(self.closed_statuses(),
                         {"Paid", "Deposited", "Draft", "Partially Refunded"})

    def test_an_archived_invoice_is_never_open(self):
        self.assertIn("NOT is_archived AND COALESCE(status, '') NOT IN", code(INVOICES))

    def test_nothing_is_owed_on_an_invoice_that_is_not_open(self):
        self.assertIn(
            "IF(is_open, GREATEST(total_amount - paid_amount, 0), 0) AS balance_due",
            code(INVOICES))


class Receivables(unittest.TestCase):
    def test_the_mart_holds_open_invoices_with_a_balance(self):
        body = code(MART)
        self.assertIn("FROM staging.stg_dtools__v2_invoices WHERE is_open "
                      "AND balance_due > 0", body)

    def test_age_runs_from_billing_then_sent_never_from_the_due_date(self):
        body = code(MART)
        self.assertIn("COALESCE(billed_on, DATE(shared_at)) AS aged_from", body)
        self.assertNotIn("DATE_DIFF(CURRENT_DATE(), i.due_on", body)

    def test_an_invoice_whose_project_is_unknown_is_still_listed(self):
        # An INNER JOIN would drop money owed on a project the list missed.
        self.assertIn("LEFT JOIN staging.stg_dtools__v2_projects AS p", code(MART))

    def test_the_description_says_this_is_not_the_books(self):
        self.assertIn("THIS IS D-TOOLS' VIEW, NOT THE BOOKS", MART)


if __name__ == "__main__":
    unittest.main()
