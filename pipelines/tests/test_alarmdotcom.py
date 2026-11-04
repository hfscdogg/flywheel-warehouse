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


class Paging(unittest.TestCase):
    def test_each_page_asks_for_a_current_bearer(self):
        clock = Clock()
        full = Resp(200, [{"customerId": i} for i in range(ingest.ALARMDOTCOM["page_size"])])
        http = FakeHttp([grant("a1"), grant("a2")], pages=[full, Resp(200, [{"customerId": -1}])])
        t = token(http, clock)
        real_get = http.get

        def get(url, headers=None, params=None, timeout=None):
            r = real_get(url, headers=headers, params=params, timeout=timeout)
            clock.t += 900                            # each page outlives the token
            return r
        http.get = get
        records = ingest.fetch_entity(http, t, "D1", ingest.ALARMDOTCOM["entities"][0], 0)
        self.assertEqual(len(records), ingest.ALARMDOTCOM["page_size"] + 1)
        self.assertEqual(http.gets, ["Bearer a1", "Bearer a2"])


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
