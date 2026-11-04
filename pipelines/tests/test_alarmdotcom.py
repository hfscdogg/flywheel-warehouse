"""Alarm.com sign-in: two-factor web service token and token renewal.

Alarm.com requires two-factor on the rep login used for the Partner API
(webservices@alarm.com, 2026-08-31). The Auth reference names the field:
x_twofactor_device_id, "Required for password grant_type if client has 2FA
enabled". Tokens last 899 seconds and come with a refresh token. A failed
sign-in must never be retried: repeated failures lock the login.
"""

import unittest

from pipelines.alarmdotcom import ingest

SECRETS = {
    "flywheel-alarmdotcom-username": "rep",
    "flywheel-alarmdotcom-password": "pw",
    "flywheel-alarmdotcom-client-id": "client",
    "flywheel-alarmdotcom-twofactor-device-id": "wst",
}


class Resp:
    def __init__(self, status, body):
        self.status_code, self._body = status, body

    def json(self):
        if self._body is None:
            raise ValueError("no json")
        return self._body


class FakeHttp:
    def __init__(self, token_replies, pages=()):
        self.token_replies = list(token_replies)
        self.pages = list(pages)
        self.posts, self.gets = [], []

    def post(self, url, data=None, headers=None, timeout=None):
        self.posts.append(dict(data))
        return self.token_replies.pop(0)

    def get(self, url, headers=None, params=None, timeout=None):
        self.gets.append(headers["Authorization"])
        return self.pages.pop(0)


def grant(access, refresh="r1", expires=899):
    return Resp(200, {"access_token": access, "refresh_token": refresh,
                      "expires_in": expires, "token_type": "bearer"})


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


def token(http, clock=None):
    t = ingest.Token(http, "p", clock=clock or Clock())
    t._secret = SECRETS.__getitem__
    return t


class SignIn(unittest.TestCase):
    def test_password_grant_sends_the_web_service_token(self):
        http = FakeHttp([grant("a1")])
        self.assertEqual(token(http).bearer(), "a1")
        self.assertEqual(http.posts, [{
            "grant_type": "password", "username": "rep", "password": "pw",
            "client_id": "client", "x_twofactor_device_id": "wst"}])

    def test_a_live_token_is_reused(self):
        http = FakeHttp([grant("a1")])
        t = token(http)
        t.bearer()
        self.assertEqual(t.bearer(), "a1")
        self.assertEqual(len(http.posts), 1)

    def test_renews_with_the_refresh_token_before_expiry(self):
        clock = Clock()
        http = FakeHttp([grant("a1", "r1"), grant("a2", "r2")])
        t = token(http, clock)
        t.bearer()
        clock.t = 899 - ingest.RENEW_MARGIN_S + 1
        self.assertEqual(t.bearer(), "a2")
        self.assertEqual(http.posts[1], {"grant_type": "refresh_token",
                                         "refresh_token": "r1", "client_id": "client"})

    def test_a_refused_refresh_signs_in_again(self):
        clock = Clock()
        http = FakeHttp([grant("a1"), Resp(400, {"error": "invalid_grant"}), grant("a3")])
        t = token(http, clock)
        t.bearer()
        clock.t = 1000
        self.assertEqual(t.bearer(), "a3")
        self.assertEqual(http.posts[2]["grant_type"], "password")

    def test_a_refused_sign_in_raises_once_and_names_the_cause(self):
        http = FakeHttp([Resp(400, {"error": "invalid_grant",
                                    "error_description": "Invalid credentials."})])
        with self.assertRaises(RuntimeError) as e:
            token(http).bearer()
        self.assertEqual(len(http.posts), 1)          # never retried
        self.assertIn("Invalid credentials.", str(e.exception))
        self.assertIn("flywheel-alarmdotcom-twofactor-device-id", str(e.exception))
        self.assertNotIn("pw", str(e.exception).replace("password", ""))

    def test_a_non_json_refusal_still_raises(self):
        http = FakeHttp([Resp(502, None)])
        with self.assertRaises(RuntimeError):
            token(http).bearer()


class Pages:
    """GET responses keyed by URL suffix and page number."""

    def __init__(self, id_pages, records, refuse=()):
        self.id_pages, self.records, self.refuse = id_pages, records, set(refuse)
        self.calls = []

    def get(self, url, headers=None, params=None, timeout=None):
        self.calls.append((url.rsplit("/v1/", 1)[1], dict(params or {}), headers["Authorization"]))
        if url.endswith("/customers"):
            page = params["searchParameters.pageNumber"]
            return Resp(200, [{"customerId": i} for i in self.id_pages.get(page, [])])
        cid = int(url.rsplit("/", 1)[1])
        if cid in self.refuse:
            return Resp(403, {"message": "Forbidden"})
        return Resp(200, dict(self.records.get(cid, {"customerId": cid, "firstName": f"c{cid}"})))


def live_token():
    t = token(FakeHttp([grant("a1")]))
    t.bearer()
    return t


class CustomerIds(unittest.TestCase):
    def test_filters_by_dealer_and_includes_terminated(self):
        pages = Pages({0: [1, 2]}, {})
        ingest.list_customer_ids(pages, live_token(), "1087", page_size=5)
        _, params, auth = pages.calls[0]
        self.assertEqual(params["searchParameters.dealerId"], "1087")
        self.assertEqual(params["searchParameters.includeTermed"], "true")
        self.assertEqual(params["searchParameters.pageSize"], 5)
        self.assertEqual(auth, "Bearer a1")

    def test_zero_based_paging_reads_every_page(self):
        pages = Pages({0: [1, 2], 1: [3, 4], 2: [5]}, {})
        self.assertEqual(ingest.list_customer_ids(pages, live_token(), "1087", 2), [1, 2, 3, 4, 5])

    def test_one_based_paging_loses_nothing_and_counts_nothing_twice(self):
        # Page 0 read as page 1: the repeat adds nothing and paging carries on.
        pages = Pages({0: [1, 2], 1: [1, 2], 2: [3, 4], 3: [5]}, {})
        self.assertEqual(ingest.list_customer_ids(pages, live_token(), "1087", 2), [1, 2, 3, 4, 5])

    def test_an_api_ignoring_the_page_number_stops(self):
        class Same(Pages):
            def get(self, url, headers=None, params=None, timeout=None):
                return Resp(200, [{"customerId": 1}, {"customerId": 2}])
        self.assertEqual(ingest.list_customer_ids(Same({}, {}), live_token(), "1087", 2), [1, 2])

    def test_zero_means_not_found(self):
        pages = Pages({0: [0]}, {})
        self.assertEqual(ingest.list_customer_ids(pages, live_token(), "1087", 2), [])

    def test_paging_that_never_ends_raises(self):
        class Endless(Pages):
            def get(self, url, headers=None, params=None, timeout=None):
                n = params["searchParameters.pageNumber"]
                return Resp(200, [{"customerId": 2 * n + 1}, {"customerId": 2 * n + 2}])
        with self.assertRaises(RuntimeError):
            ingest.list_customer_ids(Endless({}, {}), live_token(), "1087", 2, max_pages=5)


class Customers(unittest.TestCase):
    def test_reads_each_customer_once(self):
        pages = Pages({0: [11, 12]}, {11: {"customerId": 11, "firstName": "Ann"}})
        records, skipped = ingest.fetch_customers(pages, live_token(), "1087", pause=0)
        self.assertEqual([r["customerId"] for r in records], [11, 12])
        self.assertEqual(records[0]["firstName"], "Ann")
        self.assertEqual(skipped, [])
        self.assertEqual([c[0] for c in pages.calls[1:]], ["customers/11", "customers/12"])

    def test_an_account_the_rep_cannot_read_is_skipped(self):
        pages = Pages({0: [11, 12, 13]}, {}, refuse={12})
        records, skipped = ingest.fetch_customers(pages, live_token(), "1087", pause=0)
        self.assertEqual([r["customerId"] for r in records], [11, 13])
        self.assertEqual(skipped, [(12, 403)])

    def test_most_accounts_refused_fails_the_run(self):
        pages = Pages({0: [11, 12, 13]}, {}, refuse={11, 12})
        with self.assertRaises(RuntimeError):
            ingest.fetch_customers(pages, live_token(), "1087", pause=0)

    def test_limit_caps_the_detail_reads(self):
        pages = Pages({0: [11, 12, 13]}, {})
        records, _ = ingest.fetch_customers(pages, live_token(), "1087", limit=2, pause=0)
        self.assertEqual(len(records), 2)

    def test_each_read_asks_for_a_current_bearer(self):
        clock = Clock()
        t = token(FakeHttp([grant("a1"), grant("a2"), grant("a3")]), clock)
        pages = Pages({0: [11, 12]}, {})
        real = pages.get

        def get(url, headers=None, params=None, timeout=None):
            r = real(url, headers=headers, params=params, timeout=timeout)
            clock.t += 900                             # each call outlives the token
            return r
        pages.get = get
        ingest.fetch_customers(pages, t, "1087", pause=0)
        self.assertEqual([c[2] for c in pages.calls], ["Bearer a1", "Bearer a2", "Bearer a3"])


class Secrets(unittest.TestCase):
    def test_setup_creates_every_secret_the_pipeline_reads(self):
        import pathlib
        import re
        root = pathlib.Path(__file__).resolve().parents[2]
        common = (root / "scripts" / "lib" / "common.sh").read_text()
        listed = set(re.search(r'alarmdotcom\) echo "([^"]+)"', common).group(1).split())
        code = (root / "pipelines" / "alarmdotcom" / "ingest.py").read_text()
        self.assertEqual(set(re.findall(r"flywheel-alarmdotcom-[a-z-]+", code)), listed)


if __name__ == "__main__":
    unittest.main()
