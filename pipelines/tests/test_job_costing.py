"""Job costing: sold versus actual, per D-Tools project.

kpi_project_job_costing joins three sources on the only keys they share:
D-Tools purchase-order lines by project_id, and Zoho CRM by a deal's
estimate number equalling the proposal's quote number. That second key is
typed by hand and missing on most deals, so the rules that keep the table
honest are about what happens when it is absent or ambiguous.

Each test below breaks when one of these is edited away:
- hours are counted the way Zoho's own Actual vs Billed Hours report counts
  them, and only from meetings logged against a deal;
- a quote number on more than one deal links to none of them, and no hours
  appear on a project that did not link;
- the link is the estimate number, never a name;
- test deals are left out, equipment cost is quantity times unit cost, and
  the D-Tools job runs nightly so the new tables stay fresh.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
MART = ROOT / "sql" / "marts" / "kpi_project_job_costing.sql"
MEETINGS = ROOT / "sql" / "staging" / "stg_zoho__meetings.sql"
PROPOSALS = ROOT / "sql" / "staging" / "stg_dtools__v2_project_proposals.sql"
PO_LINES = ROOT / "sql" / "staging" / "stg_dtools__v2_po_lines.sql"
DEALS = ROOT / "sql" / "staging" / "stg_zoho__deals.sql"
ZOHO_REPORT = ROOT / "zoho-reference" / "qt_weekly_expected_revenue_by_potential.sql"
WORKFLOW = ROOT / ".github" / "workflows" / "ingest-dtools-v2.yml"


def flat(text):
    return " ".join(re.sub(r"--[^\n]*", "", text).split())


def build_half(path):
    """The CREATE statement alone, without the description ALTERs."""
    src = path.read_text()
    return flat(src[:src.index("ALTER TABLE")])


def output_columns(sql):
    """{alias: expression} of the final SELECT, split on top-level commas."""
    body = sql[sql.rindex("SELECT project_id,") + len("SELECT "):sql.rindex(" FROM joined")]
    parts, depth, cur = [], 0, ""
    for ch in body:
        depth += (ch == "(") - (ch == ")")
        if ch == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += ch
    parts.append(cur.strip())
    out = {}
    for part in parts:
        expr, _, alias = part.rpartition(" AS ")
        out[alias or part] = expr or part
    return out


class HoursWorked(unittest.TestCase):
    def test_the_job_hours_filter_is_zohos_own(self):
        # zoho-reference holds the Zoho Analytics query behind Actual vs
        # Billed Hours; its lists are the definition, one spelling with a
        # stray leading space included.
        report = ZOHO_REPORT.read_text()
        types = {t.strip() for t in re.findall(r"'([^']+)'", re.search(
            r'"Event Type"\s+IN\s*\(([^)]*\)[^)]*)\)', report).group(1))}
        statuses = {t.strip() for t in re.findall(r"'([^']+)'", re.search(
            r'"Event Status"\s+IN\s*\(([^)]*)\)', report).group(1))}
        sql = build_half(MEETINGS)
        clause = sql[sql.index("event_type IN ("):sql.index("AS is_job_hours")]
        self.assertEqual(set(re.findall(r"event_type IN \(([^)]*\)[^)]*)\)", clause)[0]
                             .replace("'", "").split(", ")), types)
        self.assertEqual(set(re.findall(r"event_status IN \(([^)]*)\)", clause)[0]
                             .replace("'", "").split(", ")), statuses)

    def test_the_type_is_trimmed_before_it_is_compared(self):
        self.assertIn("TRIM(JSON_VALUE(payload, '$.Event_Type')) AS event_type",
                      build_half(MEETINGS))

    def test_only_a_meeting_on_a_deal_has_a_deal(self):
        # What_Id also points at contacts and accounts; their ids are not deals.
        self.assertIn("IF(JSON_VALUE(payload, '$.\"$se_module\"') = 'Deals', "
                      "JSON_VALUE(payload, '$.What_Id.id'), NULL) AS deal_id",
                      build_half(MEETINGS))

    def test_hours_worked_sums_job_hours_only(self):
        self.assertIn("SUM(IF(is_job_hours, man_hours, 0)) AS hours_worked",
                      build_half(MART))


class TheLink(unittest.TestCase):
    def setUp(self):
        self.sql = build_half(MART)

    def test_it_is_the_estimate_number(self):
        self.assertIn("ON d.estimate_number = r.quote_number", self.sql)

    def test_no_name_is_ever_joined_on(self):
        for on in re.findall(r"\bON\b(.*?)(?=\bLEFT JOIN\b|\bWHERE\b|\bGROUP BY\b|\)|$)",
                             self.sql):
            self.assertNotRegex(on, r"name", f"a join on a name: ON{on}")

    def test_a_quote_number_on_several_deals_links_to_none(self):
        self.assertIn("WHEN d.deals > 1 THEN 'several deals'", self.sql)

    def test_no_hours_without_a_link(self):
        cols = output_columns(self.sql)
        for col in ("zoho_deal_id", "zoho_deal_name", "fo_hours_sold",
                    "total_hours_sold", "hours_worked", "job_visits", "hours_over_sold"):
            with self.subTest(col):
                self.assertTrue(cols[col].startswith("IF(zoho_link = 'linked',"),
                                f"{col} is not gated on the link: {cols[col]}")

    def test_test_deals_are_left_out(self):
        self.assertIn("AND COALESCE(is_test_record, FALSE) = FALSE", self.sql)

    def test_both_sides_of_the_key_are_trimmed(self):
        self.assertIn("NULLIF(TRIM(JSON_VALUE(payload, '$.QB_Estimate_Num')), '') "
                      "AS estimate_number", build_half(DEALS))
        self.assertIn("NULLIF(TRIM(COALESCE(JSON_VALUE(payload, '$.proposal_info.quoteNumber'), "
                      "JSON_VALUE(payload, '$.proposal_info.dataTags.quoteNumber'))), '')",
                      build_half(PROPOSALS))


class SuspectProposals(unittest.TestCase):
    def test_a_cost_above_price_is_flagged_not_dropped(self):
        # 21 proposals since 2025 carried $1.5M more cost than price; they
        # stay in the table, marked, so totals can be taken with and without.
        cols = output_columns(build_half(MART))
        self.assertEqual(cols["cost_above_price"], "sold_cost > sold_price")
        self.assertNotIn("WHERE sold_cost", build_half(MART))


class EquipmentCost(unittest.TestCase):
    def test_a_line_costs_quantity_times_unit_cost(self):
        self.assertIn("ROUND(quantity * unit_cost, 2) AS line_cost", build_half(PO_LINES))

    def test_only_lines_bought_for_a_project_count(self):
        self.assertIn("WHERE project_id IS NOT NULL GROUP BY project_id", build_half(MART))


class Freshness(unittest.TestCase):
    def test_the_d_tools_job_runs_nightly(self):
        # The new staging tables are freshness-checked at 3 days; a
        # manual-only job would fail that check within the week.
        self.assertRegex(WORKFLOW.read_text(), r"(?m)^  schedule:\n    - cron: \"\d+ \d+ \* \* \*\"")


if __name__ == "__main__":
    unittest.main()
