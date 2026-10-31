"""Tests for pipelines.qbd — the QuickBooks Desktop export and its checks.

The export is the only copy of 2003–2022 once the subscription is cancelled,
and the checks are what say it is safe to cancel. Each case here is a way the
real export went wrong or nearly did: the 2015 General Ledger came out cut
off at 32,768 rows and looked like a normal file, and a Trial Balance names
a subaccount "Parent:Child" where the ledger nests it under its parent.
"""

import unittest

from pipelines.qbd import ingest, report

GL = b'''\
,"Type","Date","Num","Name","Memo","Split","Debit","Credit","Balance"
"Checking",,,,,,,,,100.00
,"Payment","10/30/2003","2199","Acme",,"Accounts Receivable",50.00,"",150.00
"Total Checking",,,,,,,50.00,0.00,150.00
"Savings",,,,,,,,,0.00
"Tax Payments",,,,,,,,,0.00
,"Transfer","11/01/2003",,,,"Checking",25.00,"",25.00
"Total Tax Payments",,,,,,,25.00,0.00,25.00
"Total Savings",,,,,,,25.00,0.00,25.00
"Sales",,,,,,,,,0.00
,"Invoice","10/30/2003","70","Acme",,"Accounts Receivable","",175.00,-175.00
"Total Sales",,,,,,,0.00,175.00,-175.00
"TOTAL",,,,,,,75.00,175.00,0.00
'''

TB = b'''\
,"Dec 31, 03"
,"Debit","Credit"
"Checking",150.00,""
"Savings",0.00,""
"Savings:Tax Payments",25.00,""
"Sales","",175.00
"TOTAL",175.00,175.00
'''


def parsed(data):
    return report.parse(data, "x.csv")[0]


class Names(unittest.TestCase):
    def test_report_basis_and_period_come_from_the_name(self):
        d = report.describe("qbd_general-ledger_accrual_2015-01-01_2015-12-31.csv")
        self.assertEqual((d["report"], d["basis"], d["period_start"], d["period_end"]),
                         ("general-ledger", "accrual", "2015-01-01", "2015-12-31"))
        self.assertEqual(report.describe("qbd_trial-balance_2015-12-31.csv")["as_of"],
                         "2015-12-31")
        by_year = report.describe("qbd_profit-and-loss_cash_by-year_2003_2023.csv")
        self.assertEqual((by_year["report"], by_year["basis"], by_year["period_end"]),
                         ("profit-and-loss", "cash", "2023-12-31"))

    def test_the_names_the_export_actually_used(self):
        # A doubled extension from a save dialog, upper-case from QuickBooks,
        # an underscore inside the report name.
        self.assertEqual(report.describe("qbd_ap-aging-detail_2026-10-21.csv.csv")["as_of"],
                         "2026-10-21")
        self.assertEqual(report.describe("qbd_payroll.CSV")["report"], "payroll")
        self.assertEqual(report.describe("qbd_lists_all.iif")["format"], "iif")

    def test_table_names_are_bigquery_safe(self):
        self.assertEqual(report.table_name("sales-by-customer-detail"),
                         "qbd_sales_by_customer_detail")


class Parse(unittest.TestCase):
    def test_sections_nest_and_close(self):
        rows = parsed(GL)
        tax = next(r for r in rows if r["kind"] == "data"
                   and r["cells"]["Type"] == "Transfer")
        self.assertEqual(tax["section"], ["Savings", "Tax Payments"])
        sales = next(r for r in rows if r["label"] == "Sales")
        self.assertEqual((sales["kind"], sales["section"]), ("section", []))

    def test_a_name_repeated_down_one_branch_closes_the_inner_section(self):
        # The real chart has Insurance > Automobile > Insurance. "Total
        # Insurance" must close the inner one, or Automobile and every
        # sibling after it lose their place (2009, 2010 and 2022 failed on it).
        gl = (b',"Type","Debit","Credit","Balance"\n'
              b'"Insurance",,,,0.00\n'
              b'"Automobile",,,,0.00\n'
              b'"Insurance",,,,0.00\n'
              b',"Check",10.00,"",10.00\n'
              b'"Total Insurance",,10.00,0.00,10.00\n'
              b'"Total Automobile",,10.00,0.00,10.00\n'
              b'"Workers Comp",,,,0.00\n'
              b',"Check",5.00,"",5.00\n'
              b'"Total Workers Comp",,5.00,0.00,5.00\n'
              b'"Total Insurance",,15.00,0.00,15.00\n'
              b'"TOTAL",,15.00,15.00,0.00\n')
        self.assertEqual(report.ledger_totals(parsed(gl)), {
            "insurance:automobile:insurance": 10.0,
            "insurance:automobile": 10.0,
            "insurance:workers comp": 5.0,
            "insurance": 15.0,
        })

    def test_opening_balance_row_is_a_section_not_an_account_line(self):
        rows = parsed(GL)
        checking = next(r for r in rows if r["label"] == "Checking")
        self.assertEqual(checking["kind"], "section")
        self.assertEqual(checking["cells"], {"Balance": "100.00"})

    def test_two_header_rows_name_each_column(self):
        rows = parsed(TB)
        self.assertEqual(rows[0]["cells"], {"Dec 31, 03 | Debit": "150.00"})

    def test_flat_report_keeps_its_first_column(self):
        journal = (b'"Trans #","Type","Date","Account","Debit","Credit"\n'
                   b'"71","Credit Memo","07/08/2003","Accounts Receivable","",50.00\n'
                   b',,,,,\n'
                   b'"TOTAL",,,,50.00,50.00\n')
        rows, info = report.parse(journal, "x.csv")
        self.assertEqual(rows[0]["cells"]["Trans #"], "71")
        self.assertNotIn("label", rows[0])
        self.assertTrue(info["has_total"])
        self.assertEqual(info["rows"], 1)

    def test_windows_1252_text_survives(self):
        rows = parsed(b',"Memo"\n"Caf\xe9",\n"TOTAL",\n')
        self.assertEqual(rows[0]["label"], "Café")

    def test_a_file_at_the_row_cap_is_cut_off(self):
        # Header + 32,768 rows, no TOTAL: what QuickBooks wrote for 2015.
        body = b",\"Type\",\"Balance\"\n" + b",\"Check\",1.00\n" * report.ROW_CAP
        info = report.parse(body, "x.csv")[1]
        self.assertTrue(info["truncated"])
        self.assertFalse(info["has_total"])

    def test_a_file_at_the_cap_is_cut_off_even_if_it_ends_in_total(self):
        # Deposit Detail prints a TOTAL per deposit, so its last line looks
        # closed wherever the export stopped.
        body = (b'"Type","Amount"\n' + b'"Deposit",1.00\n' * (report.ROW_CAP - 1)
                + b'"TOTAL",0.00\n')
        self.assertTrue(report.parse(body, "x.csv")[1]["truncated"])

    def test_a_file_under_the_cap_is_not(self):
        self.assertFalse(report.parse(GL, "x.csv")[1]["truncated"])

    def test_iif_rows_take_their_record_type_header(self):
        iif = b"!ACCNT\tNAME\tACCNTTYPE\nACCNT\tChecking\tBANK\n!CUST\tNAME\nCUST\tAcme\n"
        rows, _ = report.parse(iif, "qbd_lists_all.iif")
        self.assertEqual([(r["list"], r["cells"]) for r in rows], [
            ("ACCNT", {"NAME": "Checking", "ACCNTTYPE": "BANK"}),
            ("CUST", {"NAME": "Acme"}),
        ])


class Reconcile(unittest.TestCase):
    def test_a_complete_ledger_ties_including_subaccounts(self):
        self.assertEqual(report.reconcile(parsed(TB), parsed(GL)), [])

    def test_a_difference_is_named(self):
        tb = TB.replace(b'"Checking",150.00', b'"Checking",151.00').replace(
            b'"TOTAL",175.00', b'"TOTAL",176.00')
        self.assertEqual(report.reconcile(parsed(tb), parsed(GL)),
                         [("checking", 151.0, 150.0)])

    def test_accounts_past_the_cut_are_missing(self):
        cut = GL.split(b'"Sales"')[0]
        self.assertEqual(report.reconcile(parsed(TB), parsed(cut)),
                         [("sales", -175.0, None)])

    def test_amounts(self):
        self.assertEqual(report.amount("1,819.00"), 1819.0)
        self.assertEqual(report.amount("(12.50)"), -12.5)
        self.assertEqual(report.amount(""), 0.0)


def piece(name, data=GL):
    f = dict(name=name, **report.describe(name))
    records, info = report.parse(data, name)
    return f, records, info


TB03 = piece("qbd_trial-balance_2003-12-31.csv", TB)


class CheckYear(unittest.TestCase):
    def test_a_whole_year_that_ties_passes(self):
        result = ingest.check_year(
            2003, [TB03], [piece("qbd_general-ledger_accrual_2003-01-01_2003-12-31.csv")])
        self.assertTrue(result["ok"], result["problems"])

    def test_a_year_split_into_pieces_is_checked_as_one(self):
        result = ingest.check_year(2003, [TB03], [
            piece("qbd_general-ledger_accrual_2003-01-01_2003-06-30.csv"),
            piece("qbd_general-ledger_accrual_2003-07-01_2003-12-31.csv"),
        ])
        self.assertTrue(result["ok"], result["problems"])

    def test_a_gap_between_pieces_fails(self):
        result = ingest.check_year(2003, [TB03], [
            piece("qbd_general-ledger_accrual_2003-01-01_2003-03-31.csv"),
            piece("qbd_general-ledger_accrual_2003-07-01_2003-12-31.csv"),
        ])
        self.assertFalse(result["ok"])
        self.assertIn("2003-01-01 to 2003-03-31 only", result["problems"][0])

    def test_a_cut_off_year_fails_and_says_why(self):
        name = "qbd_general-ledger_accrual_2003-01-01_2003-12-31.csv"
        f, records, info = piece(name)
        result = ingest.check_year(2003, [TB03], [(f, records, dict(info, truncated=True))])
        self.assertFalse(result["ok"])
        self.assertIn("cut off", result["problems"][0])

    def test_pieces_replace_a_cut_off_whole_year(self):
        # The cut-off full-year file stays in the folder; the re-exported
        # quarters beside it are what the year is judged on.
        name = "qbd_general-ledger_accrual_2003-01-01_2003-12-31.csv"
        f, records, info = piece(name)
        result = ingest.check_year(2003, [TB03], [
            (f, records[:2], dict(info, truncated=True)),
            piece("qbd_general-ledger_accrual_2003-01-01_2003-06-30.csv"),
            piece("qbd_general-ledger_accrual_2003-07-01_2003-12-31.csv"),
        ])
        self.assertTrue(result["ok"], result["problems"])

    def test_a_cut_off_year_accepted_at_totals_passes_and_says_so(self):
        name = "qbd_general-ledger_accrual_2003-01-01_2003-12-31.csv"
        f, records, info = piece(name)
        result = ingest.check_year(2003, [TB03], [(f, records, dict(info, truncated=True))],
                                   totals_only=True)
        self.assertTrue(result["ok"])
        self.assertTrue(result["totals_only"])
        self.assertIn("cut off", result["notes"][0])

    def test_totals_only_still_needs_a_trial_balance(self):
        result = ingest.check_year(
            2003, [], [piece("qbd_general-ledger_accrual_2003-01-01_2003-12-31.csv")],
            totals_only=True)
        self.assertFalse(result["ok"])

    def test_totals_only_does_not_excuse_a_ledger_that_disagrees(self):
        tb = TB.replace(b'"Checking",150.00', b'"Checking",151.00')
        result = ingest.check_year(
            2003, [piece("qbd_trial-balance_2003-12-31.csv", tb)],
            [piece("qbd_general-ledger_accrual_2003-01-01_2003-12-31.csv")],
            totals_only=True)
        self.assertFalse(result["ok"])

    def test_year_lists(self):
        self.assertEqual(ingest.parse_years("2011-2013 2015"), {2011, 2012, 2013, 2015})
        self.assertEqual(ingest.parse_years(None), set())

    def test_no_trial_balance_fails(self):
        result = ingest.check_year(
            2003, [], [piece("qbd_general-ledger_accrual_2003-01-01_2003-12-31.csv")])
        self.assertFalse(result["ok"])


class Plan(unittest.TestCase):
    FILES = [
        {"id": "a", "name": "qbd_trial-balance_2003-12-31.csv", "size": "10", "md5Checksum": "x"},
        {"id": "b", "name": "qbd_backup_2026-10-21.qbb", "size": str(900 * 2**20)},
        {"id": "c", "name": "QBD Export Tracker – Report Names & Checklist"},
        {"id": "d", "name": "notes.csv", "size": "5"},
    ]

    def test_only_report_exports_are_downloaded(self):
        to_load, skipped = ingest.plan(self.FILES, set(), 50 * 2**20)
        self.assertEqual([f["id"] for f in to_load], ["a"])
        self.assertEqual({n for n, _ in skipped}, {
            "qbd_backup_2026-10-21.qbb", "notes.csv",
            "QBD Export Tracker – Report Names & Checklist"})

    def test_a_loaded_file_is_not_loaded_again_unless_it_changed(self):
        self.assertEqual(ingest.plan(self.FILES, {"a:x"}, 50 * 2**20)[0], [])
        changed = [dict(self.FILES[0], md5Checksum="y")]
        self.assertEqual(len(ingest.plan(changed, {"a:x"}, 50 * 2**20)[0]), 1)


class DriveSetup(unittest.TestCase):
    class Resp:
        def __init__(self, status, body):
            self.status_code, self._body = status, body

        def json(self):
            return self._body

    def test_api_off_names_the_switch(self):
        resp = self.Resp(403, {"error": {"message": "Google Drive API has not been used "
                                         "in project 1 before or it is disabled.",
                                         "errors": [{"reason": "accessNotConfigured"}]}})
        hint = ingest.explain(resp, "F", "livewire-dw", None)
        self.assertIn("apis/library/drive.googleapis.com?project=livewire-dw", hint)

    def test_unshared_folder_names_the_account(self):
        hint = ingest.explain(self.Resp(404, {"error": {}}), "F", "livewire-dw", None)
        self.assertIn("ingest-vendor@livewire-dw.iam.gserviceaccount.com", hint)


if __name__ == "__main__":
    unittest.main()
