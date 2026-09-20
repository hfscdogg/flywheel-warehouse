"""Tests for the Zoho Billing customer-detail fetch — stdlib only.

The list endpoint carries no billing address, so the audit's join key comes
from a per-customer GET. Which customers get re-fetched matters (too few and
an address silently freezes, too many and a first run's worth of API calls
repeats every night), and so does how the run behaves when it cannot finish:
the first live attempt died at minute 62 having landed nothing, because it
held everything for one load at the end, never refreshed its token, and had
no notion of stopping early.
"""

import pathlib
import unittest

from pipelines.zohobilling.ingest import (
    DETAIL_WATERMARK_ENTITY, customers_needing_detail, detail_fetch_order,
    fetch_customer_details, land_detail_batch)

SQL = pathlib.Path(__file__).resolve().parents[2] / "sql"

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

    def test_the_comparison_is_by_instant_not_by_string(self):
        # Zoho lists a compact local offset; the stored watermark is UTC. As
        # strings "…T15:00:00-0400" sorts before "…T16:35:35+00:00", although
        # it is 19:00Z and the later instant. Compared as strings this
        # customer is never re-fetched and their address freezes silently.
        listed = [{"customer_id": "9", "last_modified_time": "2026-09-17T15:00:00-0400"}]
        self.assertEqual(ids(customers_needing_detail(listed, "2026-09-17T16:35:35+00:00")),
                         ["9"])
        # And the same instant spelled two ways is NOT newer.
        listed = [{"customer_id": "9", "last_modified_time": "2026-09-17T12:35:35-0400"}]
        self.assertEqual(ids(customers_needing_detail(listed, "2026-09-17T16:35:35+00:00")),
                         [])


class TestDetailFetchOrder(unittest.TestCase):
    def test_oldest_first_and_unknown_last(self):
        # The detail watermark is the newest modification LANDED. Fetching
        # oldest-first is what lets a run that stops early leave an honest
        # watermark for the next one to resume from.
        stale = [
            {"customer_id": "c", "last_modified_time": "2026-09-01T00:00:00-0400"},
            {"customer_id": "x"},
            {"customer_id": "a", "last_modified_time": "2026-01-01T00:00:00+00:00"},
            {"customer_id": "b", "last_modified_time": "2026-06-01T00:00:00Z"},
        ]
        self.assertEqual(ids(detail_fetch_order(stale)), ["a", "b", "c", "x"])


class FakeResponse:
    def __init__(self, status, body=None):
        self.status_code = status
        self._body = body or {}
        self.text = ""

    def json(self):
        return self._body

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")


class FakeHttp:
    """Serves customer detail; can 401 on chosen tokens."""

    def __init__(self, expired_tokens=()):
        self.expired = set(expired_tokens)
        self.calls = []

    def get(self, url, headers, timeout):
        token = headers["Authorization"].split()[-1]
        customer_id = url.rsplit("/", 1)[-1]
        self.calls.append((customer_id, token))
        if token in self.expired:
            return FakeResponse(401)
        # Shaped like Zoho's per-customer GET: updated_time, created_time
        # and the address, but NO last_modified_time (probed 2026-09-20).
        return FakeResponse(200, {"customer": {
            "customer_id": customer_id,
            "updated_time": f"2026-01-{int(customer_id):02d}T00:00:00Z",
            "billing_address": {"address": f"{customer_id} Main St"}}})


def listed(n):
    return [{"customer_id": str(i), "last_modified_time": f"2026-01-{i:02d}T00:00:00Z"}
            for i in range(1, n + 1)]


class TestFetchCustomerDetails(unittest.TestCase):
    def fetch(self, http, n, **kw):
        landed_batches = []
        result = fetch_customer_details(
            http, "tok0", "https://api", "org", listed(n), None, 0,
            land=lambda batch: landed_batches.append(list(batch)) or len(batch), **kw)
        return result, landed_batches

    def test_records_land_in_batches_not_at_the_end(self):
        # Holding everything for one load is what lost 250 fetched records
        # when the first live run died. Every full batch must land as it
        # fills, and the remainder after the loop.
        (landed, finished), batches = self.fetch(FakeHttp(), 7, batch_size=3)
        self.assertTrue(finished)
        self.assertEqual(landed, 7)
        self.assertEqual([len(b) for b in batches], [3, 3, 1])

    def test_batches_arrive_oldest_first(self):
        _, batches = self.fetch(FakeHttp(), 5, batch_size=2)
        ids_in_order = [r["customer_id"] for b in batches for r in b]
        self.assertEqual(ids_in_order, ["1", "2", "3", "4", "5"])

    def test_a_detail_record_is_stamped_with_the_lists_modified_time(self):
        # Zoho's detail GET returns updated_time and no last_modified_time.
        # The first budgeted run (2026-09-19) landed 1,160 such records with
        # a NULL _modified_at: the watermark never advanced, so the next run
        # would have re-fetched the same 1,160, and staging's NULLS LAST
        # tie-break handed every one of those addresses back to the list
        # record. The detail must land carrying the list's instant.
        _, batches = self.fetch(FakeHttp(), 3, batch_size=10)
        stamped = [r["last_modified_time"] for r in batches[0]]
        self.assertEqual(stamped, [r["last_modified_time"] for r in listed(3)])
        self.assertTrue(all("billing_address" in r for r in batches[0]))

    def test_the_lists_instant_wins_over_the_details_own(self):
        # The watermark is compared against LIST times. A detail time newer
        # than the list's could carry it past a customer not yet fetched.
        class NewerDetail(FakeHttp):
            def get(self, url, headers, timeout):
                resp = super().get(url, headers, timeout)
                resp._body["customer"]["last_modified_time"] = "2030-01-01T00:00:00Z"
                return resp
        _, batches = self.fetch(NewerDetail(), 2, batch_size=10)
        self.assertEqual([r["last_modified_time"] for r in batches[0]],
                         [r["last_modified_time"] for r in listed(2)])

    def test_a_listed_customer_with_no_timestamp_lands_its_detail_unstamped(self):
        # Unknown stays unknown: it is always re-fetched, and inventing an
        # instant for it would let the watermark claim it was covered.
        batches = []
        fetch_customer_details(FakeHttp(), "tok0", "https://api", "org",
                               [{"customer_id": "1"}], None, 0,
                               land=lambda b: batches.append(list(b)) or len(b))
        self.assertNotIn("last_modified_time", batches[0][0])

    def test_a_401_refreshes_the_token_once_and_retries(self):
        # The token expires after an hour and the backfill runs for four.
        http = FakeHttp(expired_tokens={"tok0"})
        tokens = iter(["tok1"])
        (landed, finished), batches = self.fetch(
            http, 2, batch_size=10, refresh_token=lambda: next(tokens))
        self.assertTrue(finished)
        self.assertEqual(landed, 2)
        # First call with the stale token 401s, is retried with the fresh
        # one, and the fresh token is kept for the customers after it.
        self.assertEqual(http.calls, [("1", "tok0"), ("1", "tok1"), ("2", "tok1")])

    def test_a_401_after_a_refresh_is_a_real_failure(self):
        http = FakeHttp(expired_tokens={"tok0", "tok1"})
        with self.assertRaises(Exception):
            self.fetch(http, 1, refresh_token=lambda: "tok1")

    def test_without_a_refresher_a_401_raises(self):
        with self.assertRaises(Exception):
            self.fetch(FakeHttp(expired_tokens={"tok0"}), 1)

    def test_the_budget_stops_the_run_and_lands_the_partial_batch(self):
        # Zoho's pace is not ours to change; the run has to stop before the
        # runner kills it, keep what it fetched, and say what is left.
        ticks = iter(range(100))
        (landed, finished), batches = self.fetch(
            FakeHttp(), 10, batch_size=4, budget_seconds=5, clock=lambda: next(ticks))
        self.assertFalse(finished)
        # Clock reads 0 at start, then 1..: budget spent on the 5th customer.
        self.assertEqual(landed, 5)
        self.assertEqual([len(b) for b in batches], [4, 1])

    def test_a_budget_that_runs_out_on_the_last_customer_still_finishes(self):
        ticks = iter(range(100))
        (landed, finished), batches = self.fetch(
            FakeHttp(), 3, batch_size=10, budget_seconds=3, clock=lambda: next(ticks))
        self.assertTrue(finished)
        self.assertEqual(landed, 3)


class FakeBqMod:
    LANDING_SCHEMA = []

    def __init__(self):
        self.watermarks = []
        self.loaded = []

    def ensure_table(self, bq, cfg, dataset, name, schema):
        return f"p.{dataset}.{name}"

    def load_rows(self, bq, table_id, rows, schema):
        self.loaded.append((table_id, rows))
        return len(rows)

    def set_watermark(self, bq, cfg, dataset, entity, watermark, run_id, recorded_at):
        self.watermarks.append((entity, watermark))


class TestLandDetailBatch(unittest.TestCase):
    ENTITY = {"name": "customers", "id_field": "customer_id"}

    def test_it_advances_the_detail_watermark_not_the_lists(self):
        # The list lands nightly under "customers" and its watermark is the
        # newest customer in the book. Reading THAT as "already detailed" is
        # how the first attempt would have fetched nothing on its second run.
        mod = FakeBqMod()
        n = land_detail_batch(mod, None, None, "raw_zohobilling", self.ENTITY, [
            {"customer_id": "1", "last_modified_time": "2026-01-01T00:00:00Z"},
            {"customer_id": "2", "last_modified_time": "2026-01-05T00:00:00Z"},
        ], "run")
        self.assertEqual(n, 2)
        self.assertEqual(mod.loaded[0][0], "p.raw_zohobilling.customers")
        self.assertEqual([e for e, _ in mod.watermarks], [DETAIL_WATERMARK_ENTITY])
        self.assertTrue(mod.watermarks[0][1].startswith("2026-01-05"))
        self.assertNotEqual(DETAIL_WATERMARK_ENTITY, "customers")


class TestStagingPrefersTheRecordWithAnAddress(unittest.TestCase):
    STAGING = SQL / "staging" / "stg_zohobilling__customers.sql"

    def test_the_tie_break_sits_between_modified_and_loaded(self):
        # With the detail fetch on, a customer lands twice per run with the
        # same last_modified_time: the list record (no address) and the
        # detail record (address). Ordering by load time alone would let
        # tomorrow's list record erase today's address.
        flat = " ".join(self.STAGING.read_text().split())
        self.assertIn(
            "ORDER BY _modified_at DESC NULLS LAST, "
            "(JSON_VALUE(payload, '$.billing_address.address') IS NOT NULL) DESC, "
            "_loaded_at DESC", flat,
            "the fuller record of the same modification must win, or the "
            "nightly list record erases every address the detail fetch landed")


if __name__ == "__main__":
    unittest.main()
