"""D-Tools Cloud v2 ingest and sign-in — stdlib only, no network, no GCP.

v2 is the only D-Tools API that returns cost, and it authenticates as a person
through Entra External ID, so two things here can fail silently and expensively:
the refresh token (lose a rotated one and the nightly dies until someone signs
in again) and the resumable fetch (land out of order and the watermark skips
records that never landed, with nothing reporting it).
"""

import pathlib
import unittest

from pipelines.dtools import signin, v2
from pipelines.lib.sources import DTOOLS_V2

ROOT = pathlib.Path(__file__).resolve().parents[2]

ENV = {
    "DTOOLS_V2_TENANT_ID": "tenant-1",
    "DTOOLS_V2_CLIENT_ID": "client-1",
    "DTOOLS_V2_SCOPE": "api://app/access_as_user",
}


def st(**over):
    return v2.settings({**ENV, **over})


class Resp:
    def __init__(self, status=200, body=None):
        self.status_code = status
        self._body = {} if body is None else body
        self.text = str(self._body)

    def json(self):
        return self._body

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")


class FakeHttp:
    """Answers GETs from a function of (path, params); records every call."""

    def __init__(self, get=None, post=None):
        self._get, self._post = get, post
        self.gets, self.posts = [], []

    def get(self, url, headers=None, params=None, timeout=None):
        self.gets.append((url, dict(headers or {}), dict(params or {})))
        return self._get(url, params or {})

    def post(self, url, data=None, headers=None, timeout=None):
        self.posts.append((url, dict(data or {})))
        return self._post(url, data)


def token_ok(access="acc", refresh="rt-2"):
    return lambda url, data: Resp(200, {"access_token": access, "refresh_token": refresh})


def api_with(get, st_=None, stored="rt-1", post=None):
    written = []
    http = FakeHttp(get=get, post=post or token_ok())
    api = v2.Api(http, st_ or st(), lambda: stored, written.append)
    api.authenticate()
    return api, http, written


class Settings(unittest.TestCase):
    def test_missing_values_are_named_before_any_network_call(self):
        with self.assertRaises(RuntimeError) as cm:
            v2.settings({"DTOOLS_V2_TENANT_ID": "t"})
        msg = str(cm.exception)
        self.assertIn("DTOOLS_V2_CLIENT_ID", msg)
        self.assertIn("DTOOLS_V2_SCOPE", msg)
        self.assertNotIn("DTOOLS_V2_TENANT_ID,", msg)

    def test_authority_comes_from_the_tenant_and_defaults_are_production(self):
        s = st()
        self.assertEqual(s["authority"], "https://tenant-1.ciamlogin.com/tenant-1")
        self.assertEqual(v2.token_url(s),
                         "https://tenant-1.ciamlogin.com/tenant-1/oauth2/v2.0/token")
        self.assertEqual(s["base_url"], "https://api.d-tools.cloud/api/v2")
        self.assertIsNone(s["account_id"])


class TokenRefresh(unittest.TestCase):
    def test_a_rotated_refresh_token_is_written_back(self):
        _, http, written = api_with(lambda u, p: Resp(), stored="rt-1")
        self.assertEqual(written, ["rt-2"])
        sent = http.posts[0][1]
        self.assertEqual(sent["grant_type"], "refresh_token")
        self.assertEqual(sent["refresh_token"], "rt-1")
        self.assertIn("offline_access", sent["scope"])

    def test_an_unchanged_or_absent_refresh_token_writes_nothing(self):
        # Every write is a new secret version; writing the same value nightly
        # would bury the history a rotation problem needs.
        for returned in ("rt-1", None):
            with self.subTest(returned=returned):
                _, _, written = api_with(lambda u, p: Resp(), stored="rt-1",
                                         post=token_ok(refresh=returned))
                self.assertEqual(written, [])

    def test_a_refused_refresh_token_says_to_sign_in_again(self):
        http = FakeHttp(post=lambda u, d: Resp(400, {"error": "invalid_grant"}))
        api = v2.Api(http, st(), lambda: "dead", lambda v: None)
        with self.assertRaises(RuntimeError) as cm:
            api.authenticate()
        self.assertIn("pipelines.dtools.signin", str(cm.exception))


class Get(unittest.TestCase):
    def test_an_expired_access_token_is_refreshed_once_and_the_call_retried(self):
        calls = []

        def get(url, params):
            calls.append(url)
            return Resp(401) if len(calls) == 1 else Resp(200, {"ok": True})
        api, http, _ = api_with(get)
        resp = api.get("/projects")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(http.posts), 2, "no second token refresh on the 401")

    def test_a_second_401_is_returned_not_retried_forever(self):
        api, http, _ = api_with(lambda u, p: Resp(401))
        self.assertEqual(api.get("/projects").status_code, 401)
        self.assertEqual(len(http.gets), 2)

    def test_the_account_header_is_sent_only_when_configured(self):
        api, http, _ = api_with(lambda u, p: Resp(), st_=st(DTOOLS_V2_ACCOUNT_ID="42"))
        api.get("/projects")
        self.assertEqual(http.gets[0][1]["X-DTools-AccountId"], "42")
        api, http, _ = api_with(lambda u, p: Resp())
        api.get("/projects")
        self.assertNotIn("X-DTools-AccountId", http.gets[0][1])
        self.assertEqual(http.gets[0][1]["Authorization"], "Bearer acc")


def paged(rows, key, total_key, cap):
    """A list endpoint that serves at most `cap` rows a page, whatever was asked."""
    def get(url, params):
        page = params["page"]
        chunk = rows[(page - 1) * cap: page * cap]
        return Resp(200, {key: chunk, total_key: len(rows)})
    return get


class FetchList(unittest.TestCase):
    CONF = DTOOLS_V2["projects"]

    def test_a_server_capping_page_size_does_not_end_the_pull_early(self):
        rows = [{"id": str(i)} for i in range(45)]
        api, http, _ = api_with(paged(rows, "projects", "totalProjects", cap=20))
        got = v2.fetch_list(api, self.CONF, {})
        self.assertEqual(len(got), 45)
        self.assertEqual([g[2]["page"] for g in http.gets], [1, 2, 3])

    def test_archived_rows_and_the_watermark_are_asked_for(self):
        api, http, _ = api_with(paged([], "projects", "totalProjects", cap=20))
        v2.fetch_list(api, self.CONF, {"fromModifiedDate": "2026-09-01T00:00:00+00:00"})
        params = http.gets[0][2]
        self.assertEqual(params["includeArchived"], "true")
        self.assertEqual(params["fromModifiedDate"], "2026-09-01T00:00:00+00:00")


def rec(i, ts):
    return {"id": str(i), "modifiedDate": ts}


class Batches(unittest.TestCase):
    def test_oldest_first_and_untimed_records_first(self):
        rs = [rec(1, "2026-09-03T00:00:00Z"), rec(2, None), rec(3, "2026-09-01T00:00:00Z")]
        flat = [r["id"] for b in v2.batches_oldest_first(rs, 10) for r in b]
        self.assertEqual(flat, ["2", "3", "1"])

    def test_a_batch_never_splits_records_modified_at_the_same_instant(self):
        rs = [rec(1, "2026-09-01T00:00:00Z"), rec(2, "2026-09-02T00:00:00Z"),
              rec(3, "2026-09-02T00:00:00Z"), rec(4, "2026-09-03T00:00:00Z")]
        batches = v2.batches_oldest_first(rs, 2)
        self.assertEqual([[r["id"] for r in b] for b in batches], [["1", "2", "3"], ["4"]])


class Recorder:
    """Stands in for runner.land: records (entity, ids) in call order."""

    def __init__(self, fail_on=None):
        self.calls, self.fail_on = [], fail_on

    def __call__(self, entity, records, id_field, modified_field):
        if self.fail_on and self.fail_on(entity, records):
            raise RuntimeError("load failed")
        self.calls.append((entity, [r.get(id_field) if id_field else None for r in records]))
        return len(records)


def projects_api(listed, missing=()):
    def get(url, params):
        if url.endswith("/projects"):
            return Resp(200, {"projects": listed, "totalProjects": len(listed)})
        pid = url.split("/projects/")[1].split("/")[0]
        if pid in missing:
            return Resp(404)
        return Resp(200, {"summary": {"cost": 10.0, "price": 15.0}})
    return api_with(get)[0]


class RunProjects(unittest.TestCase):
    LISTED = [rec(i, f"2026-09-0{i}T00:00:00Z") for i in range(1, 4)]

    def test_each_batch_lands_its_proposals_before_the_list_rows(self):
        # The list load advances the watermark. Landing it first would let a
        # run that dies on the proposals skip those projects for good.
        land = Recorder()
        v2.BATCH_SIZE, saved = 2, v2.BATCH_SIZE
        try:
            v2.run_projects(projects_api(self.LISTED), land, None)
        finally:
            v2.BATCH_SIZE = saved
        self.assertEqual([e for e, _ in land.calls],
                         [v2.PROPOSALS, v2.PROJECTS, v2.PROPOSALS, v2.PROJECTS])
        self.assertEqual(land.calls[0][1], ["1", "2"])

    def test_a_failure_keeps_every_earlier_batch(self):
        land = Recorder(fail_on=lambda e, rs: e == v2.PROPOSALS
                        and any(r["project_id"] == "3" for r in rs))
        v2.BATCH_SIZE, saved = 2, v2.BATCH_SIZE
        try:
            with self.assertRaises(RuntimeError):
                v2.run_projects(projects_api(self.LISTED), land, None)
        finally:
            v2.BATCH_SIZE = saved
        self.assertEqual(land.calls, [(v2.PROPOSALS, ["1", "2"]), (v2.PROJECTS, ["1", "2"])])

    def test_a_proposal_lands_wrapped_with_its_project_and_a_404_is_skipped(self):
        land = Recorder()
        seen = []
        orig = land.__call__

        def spy(entity, records, id_field, modified_field):
            if entity == v2.PROPOSALS:
                seen.extend(records)
            return orig(entity, records, id_field, modified_field)
        v2.run_projects(projects_api(self.LISTED, missing={"2"}), spy, None)
        self.assertEqual([r["project_id"] for r in seen], ["1", "3"])
        self.assertEqual(seen[0]["project_modified_date"], "2026-09-01T00:00:00Z")
        self.assertEqual(seen[0]["proposal"]["summary"]["cost"], 10.0)

    def test_nothing_changed_still_lands_both_tables(self):
        # An empty pull must still reach runner.land: it creates the tables
        # and writes the run log the freshness check reads.
        land = Recorder()
        v2.run_projects(projects_api([]), land, None)
        self.assertEqual(land.calls, [(v2.PROPOSALS, []), (v2.PROJECTS, [])])


class RunTimeEntries(unittest.TestCase):
    def test_time_entries_land_whole_with_no_key(self):
        rows = [{"totalCost": 50.0, "projectId": "p"}]

        def get(url, params):
            return Resp(200, {"timeEntries": rows, "totalTimeEntries": 1})
        land = Recorder()
        v2.run_time_entries(api_with(get)[0], land)
        self.assertEqual(land.calls, [(v2.TIME_ENTRIES, [None])])


class SignIn(unittest.TestCase):
    DC = {"device_code": "dc", "interval": 1, "expires_in": 60}

    def test_polling_waits_through_pending_and_slow_down(self):
        answers = iter([(400, {"error": "authorization_pending"}),
                        (400, {"error": "slow_down"}),
                        (200, {"refresh_token": "rt", "access_token": "a"})])
        sleeps = []
        body = signin.poll_for_tokens(st(), self.DC, post=lambda u, f: next(answers),
                                      sleep=sleeps.append, clock=lambda: 0)
        self.assertEqual(body["refresh_token"], "rt")
        self.assertEqual(sleeps, [1, 1, 6])

    def test_a_declined_sign_in_stops(self):
        with self.assertRaises(SystemExit):
            signin.poll_for_tokens(st(), self.DC,
                                   post=lambda u, f: (400, {"error": "access_denied"}),
                                   sleep=lambda s: None, clock=lambda: 0)

    def test_the_token_travels_on_stdin_never_argv(self):
        calls = []

        class Done:
            def __init__(self, rc):
                self.returncode = rc

        def run(cmd, **kw):
            calls.append((cmd, kw))
            return Done(1 if cmd[:3] == ["gcloud", "secrets", "describe"] else 0)
        signin.store_refresh_token("proj", "sec", "SECRET-VALUE", run=run)
        self.assertEqual([c[0][2] for c in calls], ["describe", "create", "versions"])
        for cmd, _ in calls:
            self.assertNotIn("SECRET-VALUE", " ".join(cmd))
        self.assertEqual(calls[-1][1]["input"], "SECRET-VALUE")
        self.assertIn("--data-file=-", calls[-1][0])


class InfraKnowsTheSecret(unittest.TestCase):
    def test_the_secret_exists_and_ingest_writer_may_replace_it(self):
        # A rotated token the pipeline may not write back is lost the first
        # night Entra rotates it; the ingest dies the next night.
        src = (ROOT / "scripts" / "05-ingestion-infra.sh").read_text()
        name = DTOOLS_V2["refresh_secret"]
        names = src[src.index("SECRET_NAMES="):src.index("ROTATING_SECRETS=")]
        rotating = src[src.index("ROTATING_SECRETS="):].splitlines()[0]
        self.assertIn(name, names)
        self.assertIn(name, rotating)
        self.assertIn("for s in $ROTATING_SECRETS", src)


if __name__ == "__main__":
    unittest.main()
