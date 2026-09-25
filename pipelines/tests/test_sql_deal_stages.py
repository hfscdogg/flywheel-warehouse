"""Which Zoho deal stages count as won or lost — stdlib only.

Every won figure in the warehouse (kpi_sales_pipeline, kpi_sales_weekly,
kpi_marketing_attribution, the sales goal card) rests on the stage lists in
stg_zoho__deals. A stage on neither list is silently Open, which is how a
second spelling, 'Finish Out Complete', kept 136 won deals ($1.16M) out of
every won total until 2026-09-25, and 'RFP Sent' put $88,728 of proposals into
August 2026's won revenue. These tests pin the corrected lists.
"""

import pathlib
import re
import unittest

SQL = pathlib.Path(__file__).resolve().parents[2] / "sql" / "staging" / "stg_zoho__deals.sql"


def stage_list(outcome):
    """The quoted stage names in the CASE branch that yields `outcome`."""
    src = SQL.read_text()
    m = re.search(r"WHEN stage IN \(([^)]*)\)\s*THEN '" + outcome + "'", src)
    if not m:
        raise AssertionError(f"no stage list for {outcome}")
    return set(re.findall(r"'([^']+)'", m.group(1)))


class StageLists(unittest.TestCase):
    def test_both_lists_parse(self):
        self.assertGreater(len(stage_list("Won")), 20)
        self.assertGreater(len(stage_list("Lost")), 3)

    def test_both_spellings_of_finish_out_complete_are_won(self):
        self.assertLessEqual({"Finish-Out Complete", "Finish Out Complete"},
                             stage_list("Won"))

    def test_cash_and_carry_is_won(self):
        self.assertIn("Closed Won - Cash and Carry", stage_list("Won"))

    def test_an_rfp_is_not_a_sale(self):
        self.assertNotIn("RFP Sent", stage_list("Won"))
        self.assertNotIn("RFP Sent", stage_list("Lost"))

    def test_old_spellings_are_classified(self):
        self.assertIn("Tentatively_Scheduled", stage_list("Won"))
        self.assertIn("Closed Lost", stage_list("Lost"))

    def test_no_stage_is_both_won_and_lost(self):
        self.assertEqual(stage_list("Won") & stage_list("Lost"), set())


if __name__ == "__main__":
    unittest.main()
