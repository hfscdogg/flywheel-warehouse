"""Tests for the Zoho Desk ingest — stdlib only.

Desk is the ticket system of record (the CRM copy of a ticket is never
updated), so what matters here is that the incremental window never skips a
modification and that a long backfill is walked in slices Desk's search
offset ceiling cannot break.
"""

import unittest
from datetime import datetime, timedelta, timezone

from pipelines.lib.sources import ZOHO_DESK
from pipelines.zohodesk.ingest import (
    desk_ts, fetch_reference, fetch_tickets_window, search_windows, since_for)

UTC = timezone.utc


class FakeResp:
    def __init__(self, status, body=None):
        self.status_code = status
        self._body = body or {}
        self.text = ""
        self.url = "https://desk.zoho.com/api/v1/tickets/search"

    def json(self):
        return self._body

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")


class FakeHttp:
    """Answers GETs from a queue and records the params each was sent."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def get(self, url, headers=None, params=None, timeout=None):
        self.calls.append((url, headers, params))
        return self.responses.pop(0)


class TestDeskTimestamp(unittest.TestCase):
    def test_gmt_millisecond_z(self):
        # Desk's range params take yyyy-MM-ddTHH:mm:ss.SSSZ in GMT and reject
        # an offset; an EDT instant has to arrive already converted.
        edt = datetime(2026, 11, 4, 9, 30, 15, 250000, tzinfo=timezone(timedelta(hours=-4)))
        self.assertEqual(desk_ts(edt), "2026-11-04T13:30:15.250Z")

    def test_zero_millis_are_spelled_out(self):
        self.assertEqual(desk_ts(datetime(2026, 1, 1, tzinfo=UTC)), "2026-01-01T00:00:00.000Z")


class TestSearchWindows(unittest.TestCase):
    def test_nightly_run_is_one_window(self):
        since = datetime(2026, 11, 3, 6, 0, tzinfo=UTC)
        now = datetime(2026, 11, 4, 6, 0, tzinfo=UTC)
        self.assertEqual(search_windows(since, now, 30), [(since, now)])

    def test_backfill_is_sliced_and_ends_at_now(self):
        since = datetime(2026, 1, 1, tzinfo=UTC)
        now = datetime(2026, 3, 15, 12, 0, tzinfo=UTC)
        windows = search_windows(since, now, 30)
        self.assertEqual(windows[0], (since, since + timedelta(days=30)))
        self.assertEqual(windows[-1][1], now)
        # Contiguous: each window starts where the last ended, so a ticket
        # modified at a boundary is in exactly one of them.
        for (_, end), (start, _) in zip(windows, windows[1:]):
            self.assertEqual(end, start)
        self.assertEqual(len(windows), 3)

    def test_watermark_in_the_future_means_nothing_to_do(self):
        now = datetime(2026, 11, 4, tzinfo=UTC)
        self.assertEqual(search_windows(now + timedelta(hours=1), now, 30), [])


class TestSinceFor(unittest.TestCase):
    def test_first_run_starts_at_history(self):
        self.assertEqual(since_for(None, False).isoformat(), "2015-01-01T00:00:00+00:00")

    def test_full_refresh_ignores_the_watermark(self):
        wm = datetime(2026, 11, 1, tzinfo=UTC)
        self.assertEqual(since_for(wm, True).year, 2015)

    def test_watermark_is_recovered_from_one_second_before(self):
        # The range is inclusive at the start and Desk stamps to the
        # millisecond: the ticket that set the watermark lands again rather
        # than a ticket modified in the same second never landing.
        wm = datetime(2026, 11, 3, 6, 0, 0, tzinfo=UTC)
        self.assertEqual(since_for(wm, False), wm - timedelta(seconds=1))

    def test_iso_string_watermark_is_accepted(self):
        self.assertEqual(since_for("2026-11-03T06:00:00+00:00", False),
                         datetime(2026, 11, 3, 5, 59, 59, tzinfo=UTC))

    def test_naive_watermark_is_read_as_utc(self):
        self.assertEqual(since_for(datetime(2026, 11, 3, 6, 0), False).tzinfo, UTC)


class TestFetchTicketsWindow(unittest.TestCase):
    START = datetime(2026, 11, 3, tzinfo=UTC)
    END = datetime(2026, 11, 4, tzinfo=UTC)

    def test_pages_until_a_short_page(self):
        full = [{"id": str(i), "modifiedTime": "2026-11-03T10:00:00.000Z"}
                for i in range(ZOHO_DESK["page_size"])]
        http = FakeHttp([FakeResp(200, {"data": full}), FakeResp(200, {"data": full[:3]})])
        got = fetch_tickets_window(http, "tok", "org", self.START, self.END, 0)
        self.assertEqual(len(got), ZOHO_DESK["page_size"] + 3)
        # Second page starts after the first; Desk's offset is 1-based.
        self.assertEqual(http.calls[0][2]["from"], 1)
        self.assertEqual(http.calls[1][2]["from"], 1 + ZOHO_DESK["page_size"])

    def test_204_is_an_empty_window_not_an_error(self):
        http = FakeHttp([FakeResp(204)])
        self.assertEqual(fetch_tickets_window(http, "tok", "org", self.START, self.END, 0), [])

    def test_request_shape(self):
        http = FakeHttp([FakeResp(204)])
        fetch_tickets_window(http, "tok", "org", self.START, self.END, 0)
        url, headers, params = http.calls[0]
        self.assertTrue(url.endswith("/api/v1/tickets/search"))
        self.assertEqual(headers["orgId"], "org")
        self.assertEqual(headers["Authorization"], "Zoho-oauthtoken tok")
        self.assertEqual(params["modifiedTimeRange"],
                         "2026-11-03T00:00:00.000Z,2026-11-04T00:00:00.000Z")
        self.assertEqual(params["sortBy"], "modifiedTime")
        self.assertEqual(params["limit"], ZOHO_DESK["page_size"])

    def test_limit_stops_a_smoke_run(self):
        full = [{"id": str(i)} for i in range(ZOHO_DESK["page_size"])]
        http = FakeHttp([FakeResp(200, {"data": full})])
        self.assertEqual(len(fetch_tickets_window(http, "t", "o", self.START, self.END, 5)), 5)


class TestFetchReference(unittest.TestCase):
    def test_reads_the_entitys_own_list_key(self):
        teams = {"name": "teams", "path": "teams", "list_key": "teams"}
        http = FakeHttp([FakeResp(200, {"teams": [{"id": "1"}, {"id": "2"}]})])
        self.assertEqual(len(fetch_reference(http, "t", "o", teams, 0)), 2)
        self.assertTrue(http.calls[0][0].endswith("/api/v1/teams"))


if __name__ == "__main__":
    unittest.main()
