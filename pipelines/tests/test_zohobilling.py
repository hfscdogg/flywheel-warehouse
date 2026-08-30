"""Tests for the Zoho Billing customer-detail selection — stdlib only.

The list endpoint carries no billing address, so the audit's join key comes
from a per-customer GET. Which customers get re-fetched is the only logic
worth testing: too few and an address silently freezes, too many and a first
run's worth of API calls repeats every night.
"""

import unittest

from pipelines.zohobilling.ingest import customers_needing_detail

LISTED = [
    {"customer_id": "1", "last_modified_time": "2026-08-01T10:00:00-0400"},
    {"customer_id": "2", "last_modified_time": "2026-08-29T10:00:00-0400"},
    {"customer_id": "3"},                                  # no timestamp at all
]


def ids(records):
    return [r["customer_id"] for r in records]


class TestCustomersNeedingDetail(unittest.TestCase):
    def test_no_watermark_fetches_everything(self):
        # First run, or --full-refresh.
        self.assertEqual(ids(customers_needing_detail(LISTED, None)), ["1", "2", "3"])

    def test_only_customers_modified_since_the_watermark(self):
        # Steady state: a handful of calls, not the whole book.
        self.assertEqual(
            ids(customers_needing_detail(LISTED, "2026-08-15T00:00:00-0400")),
            ["2", "3"])

    def test_missing_timestamp_is_always_refetched(self):
        # Unknown is not unchanged — assuming otherwise freezes that address
        # forever, and it would never show up as an error.
        self.assertIn("3", ids(customers_needing_detail(LISTED, "2099-01-01T00:00:00-0400")))

    def test_watermark_ahead_of_everything_fetches_only_the_unknowns(self):
        self.assertEqual(
            ids(customers_needing_detail(LISTED, "2099-01-01T00:00:00-0400")), ["3"])

    def test_empty_listing_is_not_an_error(self):
        self.assertEqual(customers_needing_detail([], None), [])


if __name__ == "__main__":
    unittest.main()
