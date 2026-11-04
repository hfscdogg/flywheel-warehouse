"""Security Central's monthly statement: parse, reconcile, plan.

The fixture is synthetic but laid out like the real statement (read
2026-11-04, 12 pages, 522 lines): an Activations section with its invoice
heading, unheaded disconnects with no account numbers, Current Recurring
Charges, and the Current Charges Summary whose Totals row the lines must
match. It carries each oddity the real one has: a name that wraps under its
line, a service that wraps under its line, a name tall enough to straddle
its line's row (so the row has no name cell), and an Open/Close Log line
with no account number.
"""

import unittest

from pipelines.scstatement import ingest, statement


def pdf(runs):
    body = "\n".join(
        f"BT /F1 7.0 Tf 9.3 TL {x} {y} Td ({text}) Tj T* ET" for x, y, text in runs)
    return (b"%PDF-1.4\n1 0 obj\n<< /Length " + str(len(body)).encode()
            + b" >>\nstream\n" + body.encode("latin-1")
            + b"\nendstream\nendobj\ntrailer\n<< >>\n%%EOF\n")


def row(y, *cells):
    xs = [60, 245, 425, 580, 740, 800, 860, 920]
    return [(xs[i], y, c) for i, c in enumerate(cells)]


def statement_pdf(recurring_total="22.00", summary_total="20.40", due="20.40"):
    runs = []
    y = 800
    for cells in [
        ("LIVEWIRE, LLC.", "SECURITY CENTRAL"),
        ("Total Amount Due =", due),
        ("RICHMOND, VA  23230", "CHARLOTTE, NC  28260", "Stmt Date:", "10/25/26"),
        ("Account No.:", "000312"),
        ("DUE UPON RECEIPT",),
        ("Invoice Date: 10/25/26", "Customer Activations", "Invoice No.: SI1"),
        ("ANN NEW", "1 MAIN ST", "A16511918 Monitoring", "09/22/26 - 10/31/26", "6.50"),
        ("Total Activations:", "6.50"),
        ("BOB GONE", "2 ELM ST", "Monitoring", "09/26/26 - 10/31/26", "-5.83"),
        ("Total Disconnects", "-5.83"),
        ("Invoice Date: 10/25/26", "Current Recurring Charges", "Invoice No.: SI2"),
        ("CAROL LONGNAME - GREENTECH", "3 OAK AVE", "A16511856 Monitoring", "11/01/26 - 11/30/26", "5.00"),
        ("RENEWABLES",),
        ("DAN PKG", "4 PINE RD", "A17323731 Security Package with", "11/01/26 - 11/30/26", "5.30"),
        ("Cellular",),
        ("EVE SHERWOOD - INDOOR SPORTS", "MAINTENANCE"),
        ("5 GOLF RD", "A16511686 Monitoring", "11/01/26 - 11/30/26", "5.00"),
        ("FACILITY",),
        ("SYSTEM 13", "6 FARM BLVD", "Open/Close Log", "11/01/26 - 11/30/26", "6.70"),
        ("Total Recurring Charges", recurring_total),
        ("Totals", "1.00", "6.50", "1.00", "-5.83", "4.00", "22.00", summary_total),
        ("PAGE:", "1"),
    ]:
        if cells[0] == "5 GOLF RD":
            runs += [(245, y, cells[0]), (425, y, cells[1]), (580, y, cells[2]), (740, y, cells[3])]
        else:
            runs += row(y, *cells)
        y -= 12
    return pdf(runs)


class Parse(unittest.TestCase):
    def setUp(self):
        self.result = statement.parse(statement_pdf())
        self.lines = self.result["lines"]

    def test_header(self):
        head = self.result["statement"]
        self.assertEqual(head["statement_date"], "2026-10-25")
        self.assertEqual(head["account_number"], "000312")
        self.assertEqual(head["total_due"], 20.40)

    def test_sections_and_fields(self):
        self.assertEqual([l["section"] for l in self.lines],
                         ["activation", "disconnect", "recurring", "recurring", "recurring", "recurring"])
        ann = self.lines[0]
        self.assertEqual((ann["customer_name"], ann["street"], ann["account_number"], ann["service"]),
                         ("ANN NEW", "1 MAIN ST", "A16511918", "Monitoring"))
        self.assertEqual((ann["period_start"], ann["period_end"], ann["amount"]),
                         ("2026-09-22", "2026-10-31", 6.50))
        self.assertEqual(ann["invoice_number"], "SI1")

    def test_disconnects_carry_no_account_or_invoice(self):
        bob = self.lines[1]
        self.assertIsNone(bob["account_number"])
        self.assertIsNone(bob["invoice_number"])
        self.assertEqual(bob["amount"], -5.83)

    def test_a_name_wrapped_under_its_line(self):
        self.assertEqual(self.lines[2]["customer_name"], "CAROL LONGNAME - GREENTECH RENEWABLES")

    def test_a_service_wrapped_under_its_line(self):
        self.assertEqual(self.lines[3]["service"], "Security Package with Cellular")
        self.assertEqual(self.lines[3]["customer_name"], "DAN PKG")

    def test_a_name_straddling_its_line(self):
        eve = self.lines[4]
        self.assertEqual(eve["customer_name"], "EVE SHERWOOD - INDOOR SPORTS MAINTENANCE FACILITY")
        self.assertEqual(eve["street"], "5 GOLF RD")
        self.assertEqual(eve["account_number"], "A16511686")

    def test_a_line_printed_without_account_number(self):
        self.assertIsNone(self.lines[5]["account_number"])
        self.assertEqual(self.lines[5]["service"], "Open/Close Log")

    def test_lines_are_numbered(self):
        self.assertEqual([l["line"] for l in self.lines], [1, 2, 3, 4, 5, 6])


class Reconcile(unittest.TestCase):
    def test_a_section_total_that_disagrees_lands_nothing(self):
        with self.assertRaises(ValueError) as e:
            statement.parse(statement_pdf(recurring_total="23.00"))
        self.assertIn("Total Recurring Charges 23.00", str(e.exception))

    def test_a_summary_that_disagrees_with_the_amount_due(self):
        with self.assertRaises(ValueError) as e:
            statement.parse(statement_pdf(due="99.99"))
        self.assertIn("amount due 99.99", str(e.exception))

    def test_a_missing_summary(self):
        rows = [["Stmt Date:", "10/25/26"], ["Total Amount Due =", "0.00"]]
        with self.assertRaises(ValueError) as e:
            statement.parse_rows(rows)
        self.assertIn("Summary Totals row not found", str(e.exception))


class Plan(unittest.TestCase):
    def test_new_pdfs_only(self):
        files = [
            {"id": "a", "name": "000312-20260925.pdf", "md5Checksum": "1", "size": "10"},
            {"id": "b", "name": "000312-20261025.pdf", "md5Checksum": "2", "size": "10"},
            {"id": "c", "name": "Thanksgiving.docx", "md5Checksum": "3", "size": "10"},
        ]
        to_load, skipped = ingest.plan(files, {"a:1"})
        self.assertEqual([f["id"] for f in to_load], ["b"])
        self.assertEqual(skipped, [("Thanksgiving.docx", "not a PDF")])

    def test_records_carry_the_statement_and_a_stable_id(self):
        parsed = statement.parse(statement_pdf())
        recs = ingest.records({"id": "F1", "name": "000312-20261025.pdf"}, parsed)
        self.assertEqual(recs[0]["id"], "F1:1")
        self.assertEqual(recs[0]["statement_date"], "2026-10-25")
        self.assertEqual(recs[0]["dealer_account"], "000312")
        self.assertEqual(len({r["id"] for r in recs}), len(recs))


if __name__ == "__main__":
    unittest.main()
