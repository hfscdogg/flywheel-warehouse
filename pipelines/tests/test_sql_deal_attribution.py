"""kpi_deal_attribution's channel grouping — stdlib only.

The attribution dashboard groups the CRM Marketing Channel values into five
buckets, and kpi_marketing_attribution separately flags which of them are
marketing-sourced. If the two lists drift, "what did marketing bring in"
has two answers in the same warehouse. These tests hold them together.
"""

import pathlib
import re
import unittest

MARTS = pathlib.Path(__file__).resolve().parents[2] / "sql" / "marts"


def quoted(block):
    return set(re.findall(r"'([^']+)'", block))


def marketing_sourced():
    src = (MARTS / "kpi_marketing_attribution.sql").read_text()
    m = re.search(r"channel IN \(((?:[^()]|\([^)]*\))*)\)\s*AS is_marketing_sourced", src)
    return quoted(m.group(1))


def group_values(group):
    src = (MARTS / "kpi_deal_attribution.sql").read_text()
    m = re.search(r"WHEN d\.ch IN \(((?:[^()]|\([^)]*\))*)\)\s*THEN '" + re.escape(group) + "'", src)
    if not m:
        raise AssertionError(f"no IN-list for {group}")
    return quoted(m.group(1))


class ChannelGroups(unittest.TestCase):
    def test_the_parsers_find_the_lists(self):
        self.assertGreaterEqual(len(marketing_sourced()), 8)
        self.assertGreaterEqual(len(group_values("Marketing & website")), 8)

    def test_marketing_and_website_is_exactly_the_marketing_sourced_list(self):
        self.assertEqual(group_values("Marketing & website"), marketing_sourced())

    def test_referrals_and_business_dev(self):
        self.assertEqual(group_values("Referrals & business dev"), {
            "REFERRAL - BUILDER/TRADE", "REFERRAL - CLIENT/WORD-OF-MOUTH",
            "BUSINESS DEVELOPMENT/OUTBOUND"})

    def test_an_unknown_value_is_visible_not_folded_into_a_group(self):
        src = (MARTS / "kpi_deal_attribution.sql").read_text()
        self.assertIn("ELSE 'Other (unmapped)'", src)

    def test_the_comparison_is_on_the_normalised_value(self):
        # The values above are uppercase; compared against the raw field
        # they would match nothing and every deal would read Other.
        src = (MARTS / "kpi_deal_attribution.sql").read_text()
        self.assertIn("NULLIF(UPPER(TRIM(marketing_channel)), '') AS ch", src)


if __name__ == "__main__":
    unittest.main()
