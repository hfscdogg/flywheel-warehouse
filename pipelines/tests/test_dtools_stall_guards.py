"""Guards against the 2026-10-26 D-Tools stall: the quotes phase went silent
until the runner's six-hour limit, and projects never loaded behind it.

Four guards, one test each: the job's own time limit, projects ahead of
quotes, a progress line during quotes, and a cap on Retry-After that fails
instead of sleeping. CI's unit job is stdlib-only, so the cap's decision is
tested there directly; the end-to-end test drives a real 429 through requests
against a local server, proving the error escapes the HTTP stack, and runs
wherever requests is installed (any dev checkout with requirements.txt).
"""

import http.server
import logging
import pathlib
import re
import threading
import unittest
from unittest import mock

from pipelines.dtools import ingest
from pipelines.lib import util
from pipelines.lib.sources import DTOOLS

try:
    from pipelines.lib import web
except ImportError:  # stdlib-only CI job
    web = None

ROOT = pathlib.Path(__file__).resolve().parents[2]


class Resp:
    status_code = 200

    def json(self):
        return [{"id": "q"}]


class FakeHttp:
    def __init__(self):
        self.calls = 0

    def get(self, *a, **kw):
        self.calls += 1
        return Resp()


class WorkflowTimeout(unittest.TestCase):
    def test_ingest_job_has_a_60_minute_limit(self):
        text = (ROOT / ".github/workflows/ingest-dtools.yml").read_text()
        job = re.search(r"\n  ingest:\n(.*?)\n    steps:", text, re.DOTALL)
        self.assertIsNotNone(job)
        self.assertRegex(job.group(1), r"\n    timeout-minutes: 60\b")


class EntityOrder(unittest.TestCase):
    def test_projects_load_before_quotes(self):
        names = [e["name"] for e in DTOOLS["entities"]]
        self.assertEqual(names[0], "opportunities")  # quotes need its ids
        self.assertLess(names.index("projects"), names.index("quotes"))
        self.assertTrue(DTOOLS["entities"][-1].get("per_opportunity"))


class QuotesProgress(unittest.TestCase):
    def test_logs_every_250_calls_and_at_the_end(self):
        fake = FakeHttp()
        entity = next(e for e in DTOOLS["entities"] if e.get("per_opportunity"))
        ids = [str(i) for i in range(600)]
        with self.assertLogs("flywheel.ingest.dtools", logging.INFO) as cm:
            records = ingest.fetch_quotes(fake, {}, entity, ids, limit=None)
        self.assertEqual((fake.calls, len(records)), (600, 600))
        progress = [m for m in cm.output if "quotes: " in m]
        self.assertEqual(len(progress), 3, progress)
        self.assertIn("250/600 opportunities, 250 quotes", progress[0])
        self.assertIn("500/600 opportunities, 500 quotes", progress[1])
        self.assertRegex(progress[0], r"\d+s elapsed")
        self.assertIn("done, 600 opportunities, 600 quotes", progress[2])


class Handler(http.server.BaseHTTPRequestHandler):
    retry_after = "3600"
    hits = 0

    def do_GET(self):
        type(self).hits += 1
        if type(self).hits == 1:
            self.send_response(429)
            self.send_header("Retry-After", type(self).retry_after)
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            body = b"[]"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, *a):
        pass


class RetryAfterCap(unittest.TestCase):
    def test_over_the_cap_raises_a_clear_error(self):
        with self.assertRaises(util.RetryAfterTooLong) as cm:
            util.check_retry_after(3600.0, 429, "https://d/x")
        msg = str(cm.exception)
        self.assertIn("HTTP 429 from https://d/x", msg)
        self.assertIn("3600s", msg)
        self.assertIn(f"{util.RETRY_AFTER_CAP_SECONDS}s cap", msg)

    def test_at_or_under_the_cap_passes_through(self):
        cap = util.RETRY_AFTER_CAP_SECONDS
        self.assertEqual(util.check_retry_after(cap, 429, "u"), cap)
        self.assertEqual(util.check_retry_after(1.0, 503, "u"), 1.0)
        self.assertIsNone(util.check_retry_after(None, 503, "u"))

    def test_cap_is_well_under_the_job_limit(self):
        self.assertLessEqual(util.RETRY_AFTER_CAP_SECONDS, 600)

    def test_session_uses_the_capped_retry(self):
        # Read as text so the stdlib-only CI job checks the wiring too.
        src = (ROOT / "pipelines/lib/web.py").read_text()
        self.assertRegex(src, r"retry = CappedRetry\(")
        self.assertRegex(src, r"return check_retry_after\(super\(\)\.get_retry_after")


@unittest.skipIf(web is None, "requests not installed (stdlib-only CI job)")
class RetryAfterCapEndToEnd(unittest.TestCase):
    def serve(self, retry_after):
        Handler.retry_after, Handler.hits = retry_after, 0
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        s = web.session()
        # The session only mounts https; reuse the very same adapter for the
        # local plain-http server so this exercises the production retry.
        s.mount("http://", s.get_adapter("https://example.com"))
        return s, f"http://127.0.0.1:{srv.server_address[1]}/x"

    def test_long_retry_after_fails_fast_with_a_clear_error(self):
        s, url = self.serve("3600")
        # Any sleep at all means the cap did not fire; fail now, not in an hour.
        no_sleep = mock.patch("urllib3.util.retry.time.sleep",
                              side_effect=AssertionError("slept on Retry-After"))
        with no_sleep, self.assertRaises(util.RetryAfterTooLong) as cm:
            s.get(url, timeout=10, proxies={"http": None, "https": None})
        self.assertIn("HTTP 429 from /x asked to retry after 3600s", str(cm.exception))

    def test_short_retry_after_is_honored_and_retried(self):
        s, url = self.serve("1")
        resp = s.get(url, timeout=10, proxies={"http": None, "https": None})
        self.assertEqual((resp.status_code, Handler.hits), (200, 2))


if __name__ == "__main__":
    unittest.main()
