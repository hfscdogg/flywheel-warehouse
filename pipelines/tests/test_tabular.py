"""Tests for pipelines.lib.tabular — vendor report parsing.

These reports are shaped for human eyes, and the failure mode that matters is
silent: a summary row parsed as a customer, or columns shifted by one, both
produce plausible-looking records that quietly corrupt the audit. The fixtures
below are trimmed from the real 2026-08-27 exports, including the rows that
caused trouble.
"""

import io
import unittest
import zipfile

from pipelines.lib import tabular

# The "Customer Count" report as Manitou emits it: a `sep=,` preamble, no
# header row, and a trailing counts row whose four values are a red herring
# ("0, 1, 520, 67" has exactly the right shape for a record).
CUSTOMERCOUNT = (
    "sep=,\r\n"
    '2311636,"William Goodrum (Cottage) [A1651/1857]",Active,3/14/2019\r\n'
    '1088430,"Pellock, Mr./Mrs. [A1000-2496]",Active,7/2/2015\r\n'
    '1044907,"Old Account [A1000-3311]",Deactivated,1/9/2011\r\n'
    "0,1,520,67\r\n"
).encode("utf-8")


def _xlsx(rows):
    """Minimal .xlsx bytes with inline strings, for the All Accounts shape."""
    def cell(col, value):
        ref = f"{chr(65 + col)}1"
        return (f'<c r="{ref}" t="inlineStr"><is><t>{value}</t></is></c>'
                if value else f'<c r="{ref}"/>')

    body = "".join(
        f'<row>{"".join(cell(i, v) for i, v in enumerate(r))}</row>' for r in rows)
    sheet = ('<?xml version="1.0"?><worksheet xmlns="http://schemas.'
             f'openxmlformats.org/spreadsheetml/2006/main"><sheetData>{body}'
             "</sheetData></worksheet>")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("xl/worksheets/sheet1.xml", sheet)
    return buf.getvalue()


ALLACCOUNTS = _xlsx([
    ["ACCOUNT", "CONTRACT", "SUBSCRIBER", "STATUS", "TYPE", "STARTED", "CONTACT"],
    ["ACCOUNT: A1000-2496", "", "", "", "", "", ""],   # report separator row
    ["A1000-2496", "1088430", "Mr./Mrs. Pellock|13413 Langford Dr||Midlothian, VA 23113",
     "Active", "Residential", "2015-07-02 00:00:00", "804-555-0100"],
    ["A1000-2496", "1088430", "Mr./Mrs. Pellock|13413 Langford Dr||Midlothian, VA 23113",
     "Active", "Residential", "2015-07-02 00:00:00", "804-555-0101"],
    ["A1651-1857", "2311636", "William Goodrum|9 Cottage Ln||Richmond, VA 23226",
     "Active", "Residential", "2019-03-14 00:00:00", "804-555-0102"],
])


class TestCustomerCount(unittest.TestCase):
    KEY = "securitycentral/customercount"

    def setUp(self):
        self.records = tabular.parse(CUSTOMERCOUNT, "45779342.CSV", self.KEY)

    def test_drops_preamble_and_summary_row(self):
        # Four data-shaped lines in, three real records out: `sep=,` is a
        # preamble and "0,1,520,67" is the counts row.
        self.assertEqual(len(self.records), 3)
        self.assertNotIn("1", [r["SUBSCRIBER"] for r in self.records])

    def test_columns_are_named_by_the_spec_not_the_first_row(self):
        # The file has no header, so a header-sniffing parser would eat the
        # first customer and label everything with their data.
        self.assertEqual(self.records[0], {
            "CONTRACT": "2311636",
            "SUBSCRIBER": "William Goodrum (Cottage) [A1651/1857]",
            "STATUS": "Active",
            "STARTED": "3/14/2019",
        })

    def test_keeps_deactivated_accounts(self):
        # DEACTIVATED is a finding in the audit, not noise to filter here.
        self.assertIn("Deactivated", [r["STATUS"] for r in self.records])

    def test_id_and_table(self):
        self.assertEqual(tabular.id_column(self.KEY), "CONTRACT")
        self.assertEqual(tabular.table_name(self.KEY), "securitycentral_status")


class TestAllAccounts(unittest.TestCase):
    KEY = "securitycentral/allaccounts"

    def setUp(self):
        self.records = tabular.parse(ALLACCOUNTS, "AllAccounts.xlsx", self.KEY)

    def test_drops_separator_rows_keeps_every_contact_row(self):
        # "ACCOUNT: A1000-2496" is a separator; the two Pellock rows are the
        # same account with two phone numbers and both are real records
        # (staging dedups to one row per account, not this parser).
        self.assertEqual(len(self.records), 3)
        self.assertEqual(len({r["ACCOUNT"] for r in self.records}), 2)

    def test_header_row_names_the_columns(self):
        self.assertEqual(self.records[0]["ACCOUNT"], "A1000-2496")
        self.assertEqual(self.records[0]["CONTRACT"], "1088430")
        self.assertEqual(self.records[0]["TYPE"], "Residential")

    def test_id_and_table_match_the_cli_loader(self):
        # scripts/08-vendor-roster.sh lands the same export in the same table
        # keyed the same way; a browser upload and a CLI load must be
        # interchangeable or staging would see two disjoint rosters.
        self.assertEqual(tabular.id_column(self.KEY), "ACCOUNT")
        self.assertEqual(tabular.table_name(self.KEY), "securitycentral_accounts")


class TestFormatSpecs(unittest.TestCase):
    def test_unknown_format_fails_loudly(self):
        with self.assertRaises(ValueError):
            tabular.parse(b"a,b\n1,2\n", "x.csv", "securitycentral/nope")

    def test_every_format_is_complete(self):
        # A spec missing a key would fail at ingest time, in a scheduled job.
        for key, spec in tabular.FORMATS.items():
            with self.subTest(key=key):
                self.assertIn("/", key, "keys are '<vendor>/<report>' drop prefixes")
                self.assertTrue(spec["table"].isidentifier())
                self.assertTrue(spec["id_column"])
                if spec["columns"]:
                    self.assertIn(spec["id_column"], spec["columns"])

    def test_tables_are_distinct(self):
        tables = [s["table"] for s in tabular.FORMATS.values()]
        self.assertEqual(len(tables), len(set(tables)))


if __name__ == "__main__":
    unittest.main()
