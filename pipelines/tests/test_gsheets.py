"""The close sheets: workbook reading, the inventory and discount shapes.

Fixtures are built here as minimal .xlsx files in the shapes found on the
real sheets (2026-11-03): an unlabeled first table closed by a bare number,
MERCH/PARTS sections, the PARTS header that labels column E "$ to Defer"
over Total / % / $ to Defer, a tab-wide running total, and a SUM that missed
an inserted row.
"""

import io
import sys
import types
import unittest
import zipfile
from unittest import mock
from datetime import date
from xml.sax.saxutils import escape

from pipelines.gsheets import ingest, workbook as w


def _xlsx(tabs):
    """tabs: [(name, [[cell, ...], ...])]. Strings shared, numbers as values.

    A None row is left empty, so row numbers match a sheet with blank rows.
    """
    shared, index = [], {}

    def sid(s):
        if s not in index:
            index[s] = len(shared)
            shared.append(s)
        return index[s]

    def col(i):
        out = ""
        i += 1
        while i:
            i, r = divmod(i - 1, 26)
            out = chr(65 + r) + out
        return out

    sheets = []
    for _, rows in tabs:
        xml_rows = []
        for r, cells in enumerate(rows, start=1):
            if not cells:
                continue
            xs = []
            for c, v in enumerate(cells):
                if v is None:
                    continue
                ref = f"{col(c)}{r}"
                if isinstance(v, (int, float)):
                    xs.append(f'<c r="{ref}"><v>{v}</v></c>')
                else:
                    xs.append(f'<c r="{ref}" t="s"><v>{sid(v)}</v></c>')
            xml_rows.append(f'<row r="{r}">{"".join(xs)}</row>')
        sheets.append(
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            f'<sheetData>{"".join(xml_rows)}</sheetData></worksheet>')
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("xl/workbook.xml",
                   '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
                   'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
                   + "".join(f'<sheet name="{escape(n)}" sheetId="{i + 1}" r:id="rId{i + 1}"/>'
                             for i, (n, _) in enumerate(tabs))
                   + "</sheets></workbook>")
        z.writestr("xl/_rels/workbook.xml.rels",
                   '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                   + "".join(f'<Relationship Id="rId{i + 1}" Target="worksheets/sheet{i + 1}.xml"/>'
                             for i in range(len(tabs)))
                   + "</Relationships>")
        z.writestr("xl/sharedStrings.xml",
                   '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
                   + "".join(f"<si><t>{escape(s)}</t></si>" for s in shared) + "</sst>")
        for i, xml in enumerate(sheets):
            z.writestr(f"xl/worksheets/sheet{i + 1}.xml", xml)
    return buf.getvalue()


HEADER_2018 = ["Original Month", "Customer", "Project (if any)", "Estimate", "$ to Defer", "Invoice Month"]
HEADER_2026 = ["Original Month", "Customer", "Project (if any)", "Estimate", "Total", "%",
               "$ to Defer", "Invoice Month", "Notes"]
HEADER_PARTS = ["Original Month", "Customer", "Project (if any)", "Estimate", "$ to Defer",
                None, None, "Invoice Month"]

INVENTORY = _xlsx([
    ("Jan 2018", [
        HEADER_2018,
        ["December", "George Kirkland", "Alarm.com System", 19361, 1311.99, "Feb"],
        ["January", "Eric Jones", "Family Room 4K Upgrade", 19597, 3748.44],
        [None, None, None, None, 5060.43],
    ]),
    ("Sept 2026", [
        [None, "September 2026"],
        ["MERCH"],
        HEADER_2026,
        [46082, "Paul Weissend", "Overas Residence", None, 1822.35, 0.37, 671.9, "PB to 63% in March"],
        [46235, "Drew Parker", "Upgrades for 5103 Cary", None, 4495.5, 1, 4495.5, "No PB"],
        [None, None, None, "Total", None, None, 5167.4],
        None,
        ["PARTS"],
        HEADER_PARTS,
        [46082, "Paul Weissend", "Overas Residence", None, 1674.88, 0.37, 619.71, "PB to 63%"],
        [46143, "Brinkman Constructors", "Richmond Office", None, 872.11, 0.5, 436.06],
        [None, None, None, "Total", None, None, 1055.77],
        ["Allison Patel"],
        [None, None, None, None, None, None, 6223.17],
    ]),
    ("July 2023", [
        HEADER_2018,
        ["July", "10 Squared", "8647 Barrique Rd", 28559, 5512.09],
        ["July", "Wes Kaufman", "New Home AV", 28661, 7909.59],
        [None, None, None, None, 7909.59],
        [None, None, None, None, 72310.41],
        [None, "Parts"],
        ["July", "Spinnaker Consulting Group", "Office AV", 22024, 2564.82],
        [None, None, None, None, 2564.82],
        [None, "Parts Okay - SMH 10/26/25"],
    ]),
    ("July 2024 Revised", [
        HEADER_2018,
        ["July", "Tye Babb", "Den TV", 19943, 1050.01],
        [None, None, None, None, 1050.01],
    ]),
    ("Notes", [["not a month"]]),
])

SECURITY = _xlsx([
    ("September 2026", [["anything", "goes", "here"]]),
    ("Monthly Deferred", [
        [None, None, "3 year agreements", "5 year agreements", "Total (month)",
         "Deferred Sec Disc 3 year", "Deferred Sec Disc 5 year", "Monthly Total Deferred Disc",
         "Total Deferred Sec Disc", "Total Amortized 3 Yr", "Total Amortized 5 yr",
         "Total Monthly Amortization", "Total Amortized ", "Checks & Balances Column"],
        [None, "January 2021", 42.89, 95.47, 138.37, 1544.12, 5728.45, 7272.57, 7272.57,
         42.89, 95.47, 138.37, 138.37, 7134.2],
        [None, "December 2021", "$0.00", "$143.06", "$143.06", "$0.00", "$8,583.56",
         "$8,583.56", "$81,017.73", "$518.16", "$1,039.41", "$1,557.57", "$9,444.55",
         "$39,095.97", "$32,477.23 deferred 1/1/22 for 2021 adjustment"],
        [None, "Total"],
    ]),
])


class Values(unittest.TestCase):
    def test_num_reads_stored_and_typed_forms(self):
        self.assertEqual(w.num("$1,822.35"), 1822.35)
        self.assertEqual(w.num("-$6,169.09"), -6169.09)
        self.assertEqual(w.num("(12.00)"), -12.0)
        self.assertAlmostEqual(w.num("37%"), 0.37)
        self.assertEqual(w.num("1822.35"), 1822.35)
        self.assertIsNone(w.num("PB to 90%  in May"))
        self.assertIsNone(w.num(None))

    def test_month_from_text_serial_and_bare_month(self):
        self.assertEqual(w.month("March 2026"), date(2026, 3, 1))
        self.assertEqual(w.month("Sept 2022"), date(2022, 9, 1))
        self.assertEqual(w.month("46098.0"), date(2026, 3, 1))
        jan = date(2018, 1, 1)
        self.assertEqual(w.month("December ", jan), date(2017, 12, 1))
        self.assertEqual(w.month("January", jan), date(2018, 1, 1))
        self.assertIsNone(w.month("sonos amps", jan))
        self.assertIsNone(w.month("July"))

    def test_an_amount_is_not_a_date(self):
        self.assertIsNone(w.excel_date("1311.99"))

    def test_tab_names_as_typed(self):
        self.assertEqual(w.tab_month("Jan 2018"), (date(2018, 1, 1), False))
        self.assertEqual(w.tab_month("April1 2024"), (date(2024, 4, 1), False))
        self.assertEqual(w.tab_month("Revised April 2024"), (date(2024, 4, 1), True))
        self.assertEqual(w.tab_month("March 2024 Revised"), (date(2024, 3, 1), True))
        self.assertEqual(w.tab_month("Monthly Deferred"), (None, False))


class Workbook(unittest.TestCase):
    def test_every_tab_in_order_with_sheet_row_numbers(self):
        tabs = w.read_workbook(INVENTORY)
        self.assertEqual([t for t, _ in tabs],
                         ["Jan 2018", "Sept 2026", "July 2023", "July 2024 Revised", "Notes"])
        sept = dict(tabs)["Sept 2026"]
        self.assertNotIn(7, [r for r, _ in sept])            # the blank row
        self.assertEqual(sept[0], (1, [None, "September 2026"]))

    def test_rows_lands_every_non_empty_row(self):
        tabs = w.read_workbook(SECURITY)
        rows = w.rows("security_discounts", tabs)
        self.assertEqual(len(rows), 5)
        self.assertEqual(rows[0]["tab"], "September 2026")
        self.assertEqual(rows[0]["id"], "security_discounts:0:1")
        self.assertEqual(rows[0]["cells"], ["anything", "goes", "here"])


class Inventory(unittest.TestCase):
    def setUp(self):
        self.lines, self.checks = w.inventory(w.read_workbook(INVENTORY))

    def by(self, tab, section=None):
        return [x for x in self.lines if x["tab"] == tab and x["section"] == section]

    def test_header_names_the_columns(self):
        jan = self.by("Jan 2018")
        self.assertEqual([x["customer"] for x in jan], ["George Kirkland", "Eric Jones"])
        self.assertEqual(jan[0]["amount_to_defer"], 1311.99)
        self.assertEqual(jan[0]["invoice_month"], "Feb")
        self.assertEqual(jan[0]["original_month"], "2017-12-01")

    def test_total_and_percent_columns(self):
        merch = self.by("Sept 2026", "MERCH")
        self.assertEqual(merch[0]["total"], 1822.35)
        self.assertAlmostEqual(merch[0]["percent"], 0.37)
        self.assertEqual(merch[0]["amount_to_defer"], 671.9)
        self.assertEqual(merch[0]["original_month"], "2026-03-01")
        self.assertEqual(merch[0]["invoice_month"], "PB to 63% in March")
        self.assertIsNone(merch[0]["notes"])

    def test_parts_header_over_total_percent_defer(self):
        parts = self.by("Sept 2026", "PARTS")
        self.assertEqual(len(parts), 2)
        self.assertEqual(parts[0]["total"], 1674.88)
        self.assertAlmostEqual(parts[0]["percent"], 0.37)
        self.assertEqual(parts[0]["amount_to_defer"], 619.71)
        self.assertEqual(parts[0]["invoice_month"], "PB to 63%")
        self.assertIsNone(parts[0]["notes"])

    def test_a_name_or_note_alone_is_neither_a_section_nor_a_job(self):
        self.assertEqual({x["section"] for x in self.lines}, {None, "MERCH", "PARTS"})
        self.assertNotIn("Parts Okay - SMH 10/26/25", [x["customer"] for x in self.lines])

    def test_every_total_is_checked(self):
        ties = {(c["tab"], c["section"], c["kind"]): c["ok"] for c in self.checks}
        self.assertEqual(ties, {
            ("Jan 2018", None, "section"): True,                 # bare number
            ("Sept 2026", "MERCH", "section"): True,             # labeled "Total"
            ("Sept 2026", "PARTS", "section"): True,
            ("Sept 2026", "PARTS", "tab"): True,                 # running total of the tab
            ("July 2023", None, "section"): False,
            ("July 2023", "PARTS", "section"): True,             # label in column B
            ("July 2024 Revised", None, "section"): True,
        })

    def test_a_total_that_misses_a_row_is_reported_not_hidden(self):
        bad = next(c for c in self.checks if c["tab"] == "July 2023")
        self.assertEqual(bad["sheet_total"], 7909.59)
        self.assertEqual(bad["lines_total"], 13421.68)
        self.assertEqual(bad["difference"], 5512.09)
        self.assertEqual(len(self.by("July 2023")), 2)            # both lines kept
        # the stray 72,310.41 under it is neither a table's nor the tab's total
        self.assertNotIn(72310.41, [c["sheet_total"] for c in self.checks])

    def test_revised_tab_and_non_month_tab(self):
        self.assertTrue(self.by("July 2024 Revised")[0]["revised"])
        self.assertFalse(any(x["tab"] == "Notes" for x in self.lines))

    def test_ids_are_unique(self):
        ids = [x["id"] for x in self.lines] + [c["id"] for c in self.checks]
        self.assertEqual(len(ids), len(set(ids)))


class MonthlyDeferred(unittest.TestCase):
    def setUp(self):
        self.rows = w.monthly_deferred(w.read_workbook(SECURITY))

    def test_one_row_per_month(self):
        self.assertEqual([r["month"] for r in self.rows], ["2021-01-01", "2021-12-01"])

    def test_headers_name_the_amounts(self):
        jan, dec = self.rows
        self.assertEqual(jan["deferred_3yr"], 1544.12)
        self.assertEqual(jan["discount_3yr"], 42.89)
        self.assertEqual(jan["balance_check"], 7134.2)
        self.assertEqual(dec["deferred_cumulative"], 81017.73)
        self.assertEqual(dec["amortized_cumulative"], 9444.55)

    def test_a_cell_past_the_last_column_is_the_note(self):
        jan, dec = self.rows
        self.assertIsNone(jan["note"])
        self.assertEqual(dec["note"], "$32,477.23 deferred 1/1/22 for 2021 adjustment")


class Config(unittest.TestCase):
    def test_parse_config(self):
        self.assertEqual(ingest.parse_config("a=ID1  b=ID2"), {"a": "ID1", "b": "ID2"})
        self.assertEqual(ingest.parse_config(None), {})
        with self.assertRaises(SystemExit):
            ingest.parse_config("a=ID1 oops")

    def test_shape_by_name(self):
        tabs = w.read_workbook(SECURITY)
        self.assertEqual(set(ingest.shape("security_discounts", tabs)),
                         {ingest.ROWS, ingest.SECURITY_DEFERRED})
        self.assertEqual(set(ingest.shape("something_else", tabs)), {ingest.ROWS})
        inv = ingest.shape("inventory_adjustments", w.read_workbook(INVENTORY))
        self.assertEqual(set(inv), {ingest.ROWS, ingest.INVENTORY_LINES, ingest.INVENTORY_CHECKS})

    def test_livewire_names_both_sheets(self):
        from pipelines.lib import config
        sheets = ingest.parse_config(config.load_client("livewire").env.get("GSHEETS"))
        self.assertEqual(set(sheets), {"inventory_adjustments", "security_discounts"})


class FakeBqMod:
    """pipelines.lib.bq, recording what the run created, loaded and logged."""
    LANDING_SCHEMA = []

    def __init__(self):
        self.ensured, self.loaded, self.runs = [], [], []

    def client_for(self, cfg):
        return None

    def ensure_table(self, bq, cfg, dataset, name, schema):
        self.ensured.append(name)
        return f"p.{dataset}.{name}"

    def load_rows(self, bq, table_id, rows, schema):
        self.loaded.append((table_id.rsplit(".", 1)[1], len(rows)))
        return len(rows)

    def set_watermark(self, *args):
        pass

    def record_run(self, bq, cfg, dataset, entity, run_id, rows_loaded, ran_at):
        self.runs.append(entity)


class Run(unittest.TestCase):
    """main(): what lands, what logs a run, and what an unshared sheet does."""

    SHEETS = {"inventory_adjustments": INVENTORY, "security_discounts": SECURITY}

    def run_main(self, unreadable=(), done=()):
        bq_mod = FakeBqMod()
        cfg = types.SimpleNamespace(
            slug="t", project_id="p",
            env={"GSHEETS": "inventory_adjustments=INV security_discounts=SEC"})
        ids = {"INV": "inventory_adjustments", "SEC": "security_discounts"}

        def meta(session, name, file_id, account, project_id):
            if name in unreadable:
                raise ingest.SheetError(f"{name}: not shared")
            return {"version": "7", "name": name, "modifiedTime": "2026-11-03T12:00:00Z"}

        args = types.SimpleNamespace(full_refresh=False)
        lib = sys.modules["pipelines.lib"]
        with mock.patch.dict(sys.modules, {"pipelines.lib.bq": bq_mod}), \
                mock.patch.object(lib, "bq", bq_mod, create=True), \
                mock.patch.object(ingest.runner, "setup", return_value=(args, cfg, "raw_vendor", "r1")), \
                mock.patch.object(ingest, "drive_session", return_value=(None, "sa@p")), \
                mock.patch.object(ingest, "file_meta", side_effect=meta), \
                mock.patch.object(ingest, "export_xlsx",
                                  side_effect=lambda s, name, fid: self.SHEETS[ids[fid]]), \
                mock.patch.object(ingest, "loaded_versions", return_value=set(done)), \
                mock.patch.dict("os.environ", {}, clear=False):
            try:
                ingest.main()
                exited = None
            except SystemExit as e:
                exited = str(e)
        return bq_mod, exited

    def test_both_sheets_land_and_every_table_logs_a_run(self):
        bq_mod, exited = self.run_main()
        self.assertIsNone(exited)
        self.assertEqual(set(bq_mod.runs), set(ingest.TABLES))
        loaded = dict(bq_mod.loaded)
        self.assertEqual(loaded[ingest.SECURITY_DEFERRED], 2)
        self.assertEqual(loaded[ingest.FILES], 2)
        self.assertEqual(bq_mod.loaded[-1][0], ingest.FILES)       # files last

    def test_an_unchanged_sheet_loads_nothing_but_still_logs_runs(self):
        bq_mod, exited = self.run_main(done={"INV:7", "SEC:7"})
        self.assertIsNone(exited)
        self.assertEqual(bq_mod.loaded, [])
        self.assertEqual(set(bq_mod.runs), set(ingest.TABLES))

    def test_an_unshared_sheet_fails_the_run_and_goes_stale_alone(self):
        bq_mod, exited = self.run_main(unreadable={"inventory_adjustments"})
        self.assertIn("inventory_adjustments: not shared", exited)
        # the tables exist regardless, so staging builds and freshness can say why
        self.assertEqual(set(bq_mod.ensured), set(ingest.TABLES))
        self.assertNotIn(ingest.INVENTORY_LINES, bq_mod.runs)
        self.assertNotIn(ingest.INVENTORY_CHECKS, bq_mod.runs)
        self.assertIn(ingest.SECURITY_DEFERRED, bq_mod.runs)


if __name__ == "__main__":
    unittest.main()
