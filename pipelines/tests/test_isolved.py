"""iSolved timecards: the window, the paging, and what lands.

The API's paging is not documented (the Deluge fetch in forecast-utilization
asks for pages 0, 1 and 2 and adds them up), so the reader has to be right
whether pages count from 0 or from 1, and must never count a page twice:
doubled hours would look like overtime, not like a bug.
"""

import unittest
from datetime import date

from pipelines.isolved import ingest

DAY = date(2026, 11, 3)
URL = "https://example.test/rest/api/clients/1/legals/2/timecardData"


class HTTPError(Exception):
    pass


class Resp:
    url = URL

    def __init__(self, status, body=None):
        self.status_code, self._body = status, body
        self.text = "" if body is None else str(body)

    def raise_for_status(self):
        if self.status_code >= 400:
            raise HTTPError(self.status_code)

    def json(self):
        if self._body is None:
            raise ValueError("no json")
        return self._body


class FakeHttp:
    """Serves timecard pages by page number; token grants in order."""

    def __init__(self, pages=None, grants=(), get_replies=None):
        self.pages = pages or {}
        self.grants = list(grants)
        self.get_replies = list(get_replies or [])
        self.posts, self.gets = [], []

    def post(self, url, data=None, auth=None, headers=None, timeout=None):
        self.posts.append({"url": url, "data": data, "auth": auth})
        return self.grants.pop(0)

    def get(self, url, headers=None, params=None, timeout=None):
        self.gets.append({"url": url, "auth": headers["Authorization"], "params": params})
        if self.get_replies:
            return self.get_replies.pop(0)
        return Resp(200, {"results": self.pages.get(params["page"], [])})


class FixedToken:
    def __init__(self):
        self.invalidated = 0

    def bearer(self):
        return f"t{self.invalidated}"

    def invalidate(self):
        self.invalidated += 1


def emp(first, last, hours, item="Hourly Regular"):
    return {"employeeFirstName": first, "employeeLastName": last,
            "timecardData": [{"payItems": [{"payItemName": item, "payItemHours": hours}]}]}


ANN, BOB, CAL = emp("Ann", "Lee", 8), emp("Bob", "Roe", 7.5), emp(" Cal ", "Poe", 4, "PTO")


class Window(unittest.TestCase):
    def test_the_nightly_window_trails_today(self):
        days = ingest.window(date(2026, 11, 10), 35)
        self.assertEqual((days[0], days[-1], len(days)),
                         (date(2026, 10, 6), date(2026, 11, 10), 36))

    def test_a_full_refresh_starts_at_the_history_start(self):
        days = ingest.window(date(2026, 11, 10), 35, date(2026, 1, 1))
        self.assertEqual((days[0], days[-1]), (date(2026, 1, 1), date(2026, 11, 10)))

    def test_a_start_after_today_is_refused(self):
        with self.assertRaises(ValueError):
            ingest.window(date(2026, 11, 10), 35, date(2027, 1, 1))

    def test_batches_cover_every_day_once(self):
        days = ingest.window(date(2026, 11, 10), 69)
        got = ingest.batches(days, 31)
        self.assertEqual([len(b) for b in got], [31, 31, 8])
        self.assertEqual([d for b in got for d in b], days)

    def test_a_bad_history_start_says_which_setting(self):
        with self.assertRaises(SystemExit) as caught:
            ingest.parse_day(None, "ISOLVED_HISTORY_START")
        self.assertIn("ISOLVED_HISTORY_START", str(caught.exception))


class Paging(unittest.TestCase):
    def fetch(self, pages):
        http = FakeHttp(pages)
        records, _ = ingest.fetch_day(http, FixedToken(), URL, DAY)
        return records, http

    def test_one_day_is_asked_for_with_full_datetimes(self):
        _, http = self.fetch({0: [ANN]})
        self.assertEqual(http.gets[0]["params"], {
            "startDate": "2026-11-03T00:00:00", "endDate": "2026-11-03T23:59:59",
            "page": 0})

    def test_pages_counted_from_zero(self):
        records, http = self.fetch({0: [ANN], 1: [BOB]})
        self.assertEqual(records, [ANN, BOB])
        self.assertEqual([g["params"]["page"] for g in http.gets], [0, 1, 2])

    def test_pages_counted_from_one_with_an_empty_page_zero(self):
        records, _ = self.fetch({1: [ANN], 2: [BOB]})
        self.assertEqual(records, [ANN, BOB])

    def test_pages_counted_from_one_with_page_zero_repeating_page_one(self):
        records, _ = self.fetch({0: [ANN], 1: [ANN], 2: [BOB]})
        self.assertEqual(records, [ANN, BOB])

    def test_an_api_ignoring_the_page_number_is_read_once(self):
        http = FakeHttp(get_replies=[Resp(200, {"results": [ANN, BOB]})] * 5)
        records, _ = ingest.fetch_day(http, FixedToken(), URL, DAY)
        self.assertEqual(records, [ANN, BOB])
        self.assertEqual(len(http.gets), 3)

    def test_a_day_nobody_worked_is_empty_not_an_error(self):
        records, http = self.fetch({})
        self.assertEqual(records, [])
        self.assertEqual(len(http.gets), 2)

    def test_paging_that_never_ends_raises(self):
        http = FakeHttp({n: [emp("E", str(n), 1)] for n in range(50)})
        with self.assertRaises(RuntimeError):
            ingest.fetch_day(http, FixedToken(), URL, DAY, max_pages=5)

    def test_an_error_is_raised_not_read_as_an_empty_day(self):
        http = FakeHttp(get_replies=[Resp(500, {"message": "boom"})])
        with self.assertRaises(HTTPError):
            ingest.fetch_day(http, FixedToken(), URL, DAY)

    def test_a_refused_token_is_renewed_once(self):
        tok = FixedToken()
        http = FakeHttp(get_replies=[Resp(401), Resp(200, {"results": [ANN]}),
                                     Resp(200, {"results": []})])
        records, _ = ingest.fetch_day(http, tok, URL, DAY)
        self.assertEqual(records, [ANN])
        self.assertEqual([g["auth"] for g in http.gets[:2]], ["Bearer t0", "Bearer t1"])

    def test_a_token_refused_twice_fails(self):
        http = FakeHttp(get_replies=[Resp(401), Resp(401)])
        with self.assertRaises(HTTPError):
            ingest.fetch_day(http, FixedToken(), URL, DAY)


class Rows(unittest.TestCase):
    def test_a_record_lands_whole_under_the_day_asked_for(self):
        rows = ingest.timecard_rows(DAY, [ANN, CAL])
        self.assertEqual(rows[0], {"key": "2026-11-03|Ann Lee",
                                   "work_date": "2026-11-03", "record": ANN})
        self.assertEqual(rows[1]["key"], "2026-11-03|Cal Poe")

    def test_a_day_row_is_written_for_an_empty_day(self):
        self.assertEqual(ingest.day_row(DAY, [], 1),
                         {"work_date": "2026-11-03", "employees": 0, "pages": 1})


class Clock:
    t = 0.0

    def __call__(self):
        return self.t


def grant(access, expires=3600):
    body = {"access_token": access, "token_type": "bearer"}
    if expires is not None:
        body["expires_in"] = expires
    return Resp(200, body)


def token(http, clock):
    t = ingest.Token(http, "p", "https://example.test/rest", clock=clock)
    t._secret = {"flywheel-isolved-client-id": "id",
                 "flywheel-isolved-client-secret": "secret"}.__getitem__
    return t


class SignIn(unittest.TestCase):
    def test_client_credentials_go_as_basic_auth(self):
        http = FakeHttp(grants=[grant("a1")])
        self.assertEqual(token(http, Clock()).bearer(), "a1")
        self.assertEqual(http.posts, [{
            "url": "https://example.test/rest/api/token",
            "data": {"grant_type": "client_credentials"}, "auth": ("id", "secret")}])

    def test_a_live_token_is_reused_and_an_old_one_renewed(self):
        http, clock = FakeHttp(grants=[grant("a1"), grant("a2")]), Clock()
        t = token(http, clock)
        t.bearer()
        clock.t = 3000
        self.assertEqual(t.bearer(), "a1")
        clock.t = 3590
        self.assertEqual(t.bearer(), "a2")

    def test_a_grant_without_a_lifetime_is_still_renewed(self):
        http, clock = FakeHttp(grants=[grant("a1", None), grant("a2", None)]), Clock()
        t = token(http, clock)
        t.bearer()
        clock.t = ingest.DEFAULT_TOKEN_LIFE_S
        self.assertEqual(t.bearer(), "a2")

    def test_a_refused_grant_raises(self):
        http = FakeHttp(grants=[Resp(401, {"error": "invalid_client"})])
        with self.assertRaises(HTTPError):
            token(http, Clock()).bearer()

    def test_a_reply_without_a_token_names_the_secrets(self):
        http = FakeHttp(grants=[Resp(200, {"message": "nope"})])
        with self.assertRaises(RuntimeError) as caught:
            token(http, Clock()).bearer()
        self.assertIn("flywheel-isolved-client-id", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
