"""QuickBooks reports flattening — stdlib only.

The monthly statements are QuickBooks' reports, nested to any depth. The
flattening is the one place this ingest can quietly get the books wrong: drop
a parent account's own postings, count the Total column as a month, or lose
the section a line sits in, and every figure built on report_lines is off
while the landing looks fine. These tests carry a report in QuickBooks' shape
(Columns with StartDate/EndDate metadata; Section rows with Header, Rows,
Summary) and pin what lands.
"""

import pathlib
import unittest
from datetime import date

from pipelines.qbo import reports

ROOT = pathlib.Path(__file__).resolve().parents[2]


def col(title, start=None, end=None):
    meta = []
    if start:
        meta = [{"Name": "StartDate", "Value": start}, {"Name": "EndDate", "Value": end}]
    return {"ColTitle": title, "ColType": "Money", "MetaData": meta}


def cells(label, *amounts, id=None):
    first = {"value": label}
    if id:
        first["id"] = id
    return [first] + [{"value": a} for a in amounts]


def data(label, *amounts, id=None):
    return {"type": "Data", "ColData": cells(label, *amounts, id=id)}


def section(label, rows, total, group=None, header_amounts=None):
    header = cells(label, *(header_amounts or ["", "", ""]))
    return {"type": "Section", "group": group, "Header": {"ColData": header},
            "Rows": {"Row": rows}, "Summary": {"ColData": total}}


# Two months plus a Total column. SALES M is a parent with a sub-account and
# direct postings of its own (the Data row named for the parent).
PNL = {
    "Columns": {"Column": [
        {"ColTitle": "", "ColType": "Account"},
        col("Jul 2026", "2026-07-01", "2026-07-31"),
        col("Aug 2026", "2026-08-01", "2026-08-31"),
        col("Total"),
    ]},
    "Rows": {"Row": [
        section("Income", [
            section("SALES M (Merchandise)", [
                data("SALES M (Merchandise)", "90.00", "150.00", id="10"),
                data("Merchandise - Online", "10.00", "41.51", id="11"),
            ], cells("Total SALES M (Merchandise)", "100.00", "191.51", "291.51")),
            data("SALES S (Services & Labor)", "108.39", "102.49", "210.88", id="20"),
        ], cells("Total Income", "208.39", "294.00", "502.39"), group="Income"),
        {"type": "Section", "group": "GrossProfit",
         "Summary": {"ColData": cells("Gross Profit", "208.39", "294.00", "502.39")}},
    ]},
}


class Window(unittest.TestCase):
    def test_three_full_years_back_to_today(self):
        self.assertEqual(reports.window(date(2026, 9, 25)), ("2023-01-01", "2026-09-25"))


class Periods(unittest.TestCase):
    def test_only_dated_columns_are_months_and_the_total_is_dropped(self):
        # Counting the Total column as a month would double every figure.
        self.assertEqual(reports.period_columns(PNL),
                         [(1, "2026-07-01", "2026-07-31"), (2, "2026-08-01", "2026-08-31")])


def lines(report=PNL):
    return reports.flatten(report, "ProfitAndLoss", "Accrual")


def pick(ls, label, month="2026-08-01", line_type=None):
    return [l for l in ls if l["label"] == label and l["period_start"] == month
            and (line_type is None or l["line_type"] == line_type)]


class Flatten(unittest.TestCase):
    def test_one_record_per_row_and_month_never_the_total_column(self):
        ls = lines()
        self.assertEqual({l["period_start"] for l in ls}, {"2026-07-01", "2026-08-01"})
        # 3 account rows + 3 totals (SALES M, Income, Gross Profit), 2 months.
        self.assertEqual(len(ls), 12)

    def test_a_parent_accounts_own_postings_land_as_an_account_line(self):
        (own,) = pick(lines(), "SALES M (Merchandise)", line_type="account")
        self.assertEqual(own["amount"], 150.0)
        self.assertEqual(own["account_id"], "10")
        self.assertEqual(own["section_path"], "Income > SALES M (Merchandise)")

    def test_totals_are_marked_and_carry_their_section(self):
        (total,) = pick(lines(), "Total SALES M (Merchandise)")
        self.assertEqual(total["line_type"], "total")
        self.assertEqual(total["amount"], 191.51)
        self.assertEqual(total["section_path"], "Income > SALES M (Merchandise)")
        self.assertEqual(total["group"], "Income")

    def test_a_computed_line_with_no_rows_still_lands(self):
        (gp,) = pick(lines(), "Gross Profit")
        self.assertEqual((gp["line_type"], gp["group"], gp["amount"]),
                         ("total", "GrossProfit", 294.0))

    def test_account_lines_sum_to_the_printed_total(self):
        ls = lines()
        accounts = sum(l["amount"] for l in ls
                       if l["line_type"] == "account" and l["period_start"] == "2026-08-01")
        (income,) = pick(ls, "Total Income")
        self.assertAlmostEqual(accounts, income["amount"], places=2)

    def test_blank_cells_are_null_not_zero(self):
        report = {**PNL, "Rows": {"Row": [data("Empty", "", "5.00", id="9")]}}
        (jul,) = pick(lines(report), "Empty", month="2026-07-01")
        self.assertIsNone(jul["amount"])

    def test_header_figures_are_kept_when_a_parent_carries_them(self):
        report = {**PNL, "Rows": {"Row": [section(
            "Parent", [data("Child", "1.00", "2.00", id="2")],
            cells("Total Parent", "4.00", "7.00", "11.00"),
            header_amounts=["3.00", "5.00", "8.00"])]}}
        ls = lines(report)
        (parent,) = pick(ls, "Parent", line_type="account")
        self.assertEqual(parent["amount"], 5.0)
        self.assertEqual(reports.total_mismatches(report), [])


class TotalsCheck(unittest.TestCase):
    def test_a_report_that_adds_up_has_no_mismatches(self):
        self.assertEqual(reports.total_mismatches(PNL), [])

    def test_a_section_that_does_not_add_up_is_reported_with_its_month(self):
        broken = {**PNL, "Rows": {"Row": [section(
            "Income", [data("A", "1.00", "2.00", id="1")],
            cells("Total Income", "1.00", "9.00", "10.00"))]}}
        bad = reports.total_mismatches(broken)
        self.assertEqual(len(bad), 1)
        self.assertEqual(bad[0][:2], ("Income", "2026-08-01"))


class SharesTheQboToken(unittest.TestCase):
    def test_it_can_never_run_alongside_ingest_qbo(self):
        # Both refresh the same rotating QuickBooks token. Run together, one
        # refreshes with a token the other has just retired, and QuickBooks
        # ingestion stops until someone re-authorises the app.
        wf = ROOT / ".github" / "workflows"
        group = "group: ingest-qbo-${{ inputs.client || 'livewire' }}"
        self.assertIn(group, (wf / "ingest-qbo.yml").read_text())
        self.assertIn(group, (wf / "ingest-qbo-reports.yml").read_text())


if __name__ == "__main__":
    unittest.main()
