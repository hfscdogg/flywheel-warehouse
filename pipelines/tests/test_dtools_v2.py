"""D-Tools Cloud v2 ingest and sign-in — stdlib only, no network, no GCP.

v2 is the only D-Tools API that returns cost, and it authenticates as a person
through Entra External ID, so two things here can fail silently and expensively:
the refresh token (lose a rotated one and the nightly dies until someone signs
in again) and the resumable fetch (land out of order and the watermark skips
records that never landed, with nothing reporting it).
"""

import datetime
import pathlib
import re
import unittest
import zlib

from pipelines.dtools import signin, v2
from pipelines.lib import config
from pipelines.lib.sources import DTOOLS_V2, ZOHO

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


class Livewire(unittest.TestCase):
    """Production values from D-Tools (Dave Kirn, 2026-09-30). The docs site
    shows the demo environment's, and D-Tools' MCP client ids get a token the
    data endpoints refuse."""

    def setUp(self):
        self.s = v2.settings(config.load_client("livewire").env)

    def test_it_signs_in_to_production(self):
        tenant = "fb1ad9bb-9bd2-45fe-a065-c8a0370c2913"
        self.assertEqual(self.s["authority"],
                         f"https://{tenant}.ciamlogin.com/{tenant}")
        self.assertEqual(self.s["client_id"], "6ccf1cdf-d7f7-4aa4-a292-16ac4c1d6504")

    def test_it_asks_for_the_data_api_scope(self):
        self.assertEqual(self.s["scope"],
                         "api://0d607d3e-ee5d-4992-a722-9f5be9c67a17/access_as_user")

    def test_pages_stay_within_the_apis_maximum(self):
        # D-Tools caps pageSize at 500.
        self.assertLessEqual(DTOOLS_V2["page_size"], 500)


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


def projects_api(listed, missing=(), no_info=()):
    def get(url, params):
        if url.endswith("/projects"):
            return Resp(200, {"projects": listed, "totalProjects": len(listed)})
        pid = url.split("/projects/")[1].split("/")[0]
        if pid in missing:
            return Resp(404)
        if url.endswith("/proposal"):
            if pid in no_info:
                return Resp(404)
            return Resp(200, {"quoteNumber": f"Q{pid}", "projectNumber": f"P{pid}"})
        return Resp(200, {"summary": {"cost": 10.0, "price": 15.0}})
    return api_with(get)


class RunProjects(unittest.TestCase):
    LISTED = [rec(i, f"2026-09-0{i}T00:00:00Z") for i in range(1, 4)]

    def test_each_batch_lands_its_proposals_before_the_list_rows(self):
        # The list load advances the watermark. Landing it first would let a
        # run that dies on the proposals skip those projects for good.
        land = Recorder()
        v2.BATCH_SIZE, saved = 2, v2.BATCH_SIZE
        try:
            v2.run_projects(projects_api(self.LISTED)[0], land, None)
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
                v2.run_projects(projects_api(self.LISTED)[0], land, None)
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
        v2.run_projects(projects_api(self.LISTED, missing={"2"})[0], spy, None)
        self.assertEqual([r["project_id"] for r in seen], ["1", "3"])
        self.assertEqual(seen[0]["project_modified_date"], "2026-09-01T00:00:00Z")
        self.assertEqual(seen[0]["proposal"]["summary"]["cost"], 10.0)

    def test_nothing_changed_still_lands_both_tables(self):
        # An empty pull must still reach runner.land: it creates the tables
        # and writes the run log the freshness check reads.
        land = Recorder()
        v2.run_projects(projects_api([])[0], land, None)
        self.assertEqual(land.calls, [(v2.PROPOSALS, []), (v2.PROJECTS, [])])


class QuoteNumber(unittest.TestCase):
    """A project's quote number is the only key D-Tools shares with Zoho
    CRM, where hours worked live (a deal's QB_Estimate_Num). It appears
    only in the project's proposal info, so that lands with the cost."""

    LISTED = [rec(i, f"2026-09-0{i}T00:00:00Z") for i in range(1, 3)]

    def landed(self, **kw):
        seen = []

        def land(entity, records, id_field, modified_field):
            if entity == v2.PROPOSALS:
                seen.extend(records)
            return len(records)
        api, http, _ = projects_api(self.LISTED, **kw)
        v2.run_projects(api, land, None)
        return seen, http

    def test_each_proposal_lands_with_its_quote_number(self):
        seen, http = self.landed()
        self.assertEqual([r["proposal_info"]["quoteNumber"] for r in seen], ["Q1", "Q2"])
        self.assertIn("https://api.d-tools.cloud/api/v2/projects/1/proposal",
                      [g[0] for g in http.gets])

    def test_a_missing_info_still_lands_the_cost(self):
        seen, _ = self.landed(no_info={"1"})
        self.assertEqual([r["project_id"] for r in seen], ["1", "2"])
        self.assertIsNone(seen[0]["proposal_info"])
        self.assertEqual(seen[0]["proposal"]["summary"]["cost"], 10.0)

    def test_time_entries_are_not_pulled(self):
        # D-Tools records hours sold; hours worked are Zoho CRM meetings.
        self.assertNotIn("time_entries", DTOOLS_V2)
        self.assertEqual(v2.ENTITIES, [v2.PROJECTS, v2.PROPOSALS, v2.PURCHASE_ORDERS,
                                       v2.BILLING])


def proj(i, modified="2026-11-01T00:00:00Z", completed="2026-10-01T00:00:00Z"):
    return {"id": str(i), "modifiedDate": modified, "completedDate": completed}


def billed(project, invoices=(), change_orders=()):
    return {"project_id": project["id"],
            "project_modified_date": project["modifiedDate"],
            "invoices": list(invoices), "change_orders": list(change_orders)}


def invoice(total, paid=None, **over):
    return {"number": "INV-1", "totalAmount": total, "paidAmount": paid, **over}


class OwesMoney(unittest.TestCase):
    def test_an_invoice_paid_short_of_its_total_is_owed(self):
        p = proj(1)
        self.assertTrue(v2.owes_money(billed(p, [invoice(1000.0)])))
        self.assertTrue(v2.owes_money(billed(p, [invoice(1000.0, 400.0)])))
        self.assertTrue(v2.owes_money(billed(p, [invoice(50.0, 50.0), invoice(20.0)])))

    def test_paid_in_full_archived_or_absent_is_not(self):
        p = proj(1)
        self.assertFalse(v2.owes_money(billed(p, [invoice(1000.0, 1000.0)])))
        self.assertFalse(v2.owes_money(billed(p, [invoice(1000.0, archived=True)])))
        self.assertFalse(v2.owes_money(billed(p)))
        self.assertFalse(v2.owes_money(None))

    def test_a_float_cent_does_not_keep_a_paid_invoice_open(self):
        self.assertFalse(v2.owes_money(billed(proj(1), [invoice(0.3, 0.1 + 0.2)])))


class DueForSweep(unittest.TestCase):
    """Which projects are asked for their invoices tonight. Too few and a
    payment is never seen, with nothing reporting it; all of them and the
    nightly makes thousands of calls to learn nothing."""

    DAY = datetime.date(2026, 11, 20)

    def why(self, project, landed, day=None, recheck=7):
        return v2.due_for_sweep(project, landed, day or self.DAY, recheck)

    def quiet_day(self, project, recheck=7):
        """A date that is not this project's recheck day."""
        slot = zlib.crc32(project["id"].encode()) % recheck
        d = self.DAY
        while d.toordinal() % recheck == slot:
            d += datetime.timedelta(days=1)
        return d

    def test_never_landed_is_swept(self):
        self.assertEqual(self.why(proj(1), None), "new")

    def test_a_project_changed_since_it_landed_is_swept(self):
        p = proj(1)
        landed = billed({**p, "modifiedDate": "2026-10-01T00:00:00Z"})
        self.assertEqual(self.why(p, landed), "modified")

    def test_the_same_instant_spelled_two_ways_is_not_a_change(self):
        p = proj(1, modified="2026-11-01T00:00:00Z")
        landed = billed({**p, "modifiedDate": "2026-11-01T00:00:00+00:00"})
        self.assertIsNone(self.why(p, landed, self.quiet_day(p)))

    def test_an_open_project_is_swept_every_night(self):
        p = proj(1, completed=None)
        self.assertEqual(self.why(p, billed(p), self.quiet_day(p)), "open")

    def test_a_completed_project_still_owing_is_swept_every_night(self):
        # The receivables case: job done, final invoice outstanding, and the
        # payment arriving is not known to move the project's modified date.
        p = proj(1)
        self.assertEqual(self.why(p, billed(p, [invoice(900.0)]), self.quiet_day(p)),
                         "unpaid")

    def test_a_settled_completed_project_waits_for_its_recheck_day(self):
        p = proj(1)
        landed = billed(p, [invoice(900.0, 900.0)])
        week = [self.DAY + datetime.timedelta(days=i) for i in range(7)]
        self.assertEqual([self.why(p, landed, d) for d in week].count("recheck"), 1)
        self.assertEqual([self.why(p, landed, d) for d in week].count(None), 6)

    def test_rechecks_are_spread_over_the_week_not_stacked_on_one_night(self):
        week = [self.DAY + datetime.timedelta(days=i) for i in range(7)]
        per_day = [sum(1 for i in range(700)
                       if self.why(proj(i), billed(proj(i)), d) == "recheck") for d in week]
        self.assertEqual(sum(per_day), 700)
        self.assertLess(max(per_day), 200)


def billing_api(listed, invoices=None, change_orders=None, missing=(), odd=()):
    invoices, change_orders = invoices or {}, change_orders or {}

    def get(url, params):
        if url.endswith("/projects"):
            return Resp(200, {"projects": listed, "totalProjects": len(listed)})
        pid = url.split("/projects/")[1].split("/")[0]
        if pid in missing:
            return Resp(404)
        if pid in odd:
            return Resp(200, {"error": "nope"})
        if url.endswith("/invoices"):
            return Resp(200, {"items": invoices.get(pid)})
        if url.endswith("/change-orders"):
            return Resp(200, {"items": change_orders.get(pid, [])})
        raise AssertionError(f"unexpected GET {url}")
    return api_with(get)


class Spy(Recorder):
    """A Recorder that also keeps the records it was handed."""

    def __init__(self, **kw):
        super().__init__(**kw)
        self.records = []

    def __call__(self, entity, records, id_field, modified_field):
        n = super().__call__(entity, records, id_field, modified_field)
        self.records.extend(records)
        return n


class RunBilling(unittest.TestCase):
    DAY = DueForSweep.DAY

    def run_it(self, listed, landed=None, limit=0, land=None, **kw):
        land = land or Spy()
        api, http, _ = billing_api(listed, **kw)
        n = v2.run_billing(api, land, lambda: landed or {}, limit, today=self.DAY)
        return land, http, n

    def test_a_first_run_lands_every_project_with_its_invoices_and_change_orders(self):
        listed = [proj(1), proj(2)]
        land, http, n = self.run_it(
            listed, invoices={"1": [invoice(500.0, 500.0)]},
            change_orders={"1": [{"number": 3, "price": 120.0}]})
        self.assertEqual(n, 2)
        self.assertEqual(land.calls, [(v2.BILLING, ["1", "2"])])
        one, two = land.records
        self.assertEqual(one["invoices"][0]["paidAmount"], 500.0)
        self.assertEqual(one["change_orders"][0]["price"], 120.0)
        self.assertEqual(one["project_modified_date"], "2026-11-01T00:00:00Z")
        # A project with nothing billed still lands, as an empty record.
        self.assertEqual((two["invoices"], two["change_orders"]), ([], []))
        self.assertIn("https://api.d-tools.cloud/api/v2/projects/1/invoices",
                      [g[0] for g in http.gets])

    def test_the_project_list_is_read_whole_not_since_a_watermark(self):
        _, http, _ = self.run_it([proj(1)])
        listing = [g for g in http.gets if g[0].endswith("/projects")]
        self.assertNotIn("fromModifiedDate", listing[0][2])
        self.assertEqual(listing[0][2]["includeArchived"], "true")

    def test_only_projects_due_are_asked(self):
        settled, owing = proj(1), proj(2)
        quiet = DueForSweep().quiet_day(settled)
        landed = {"1": billed(settled, [invoice(10.0, 10.0)]),
                  "2": billed(owing, [invoice(10.0)])}
        land = Spy()
        api, http, _ = billing_api([settled, owing], invoices={"2": [invoice(10.0, 10.0)]})
        v2.run_billing(api, land, lambda: landed, today=quiet)
        self.assertEqual(land.calls, [(v2.BILLING, ["2"])])
        self.assertFalse([g for g in http.gets if "/projects/1/" in g[0]])
        # And what lands is the payment, which is the point of asking.
        self.assertFalse(v2.owes_money(land.records[0]))

    def test_nothing_due_still_reaches_land(self):
        # It creates the table and writes the run log the freshness check reads.
        p = proj(1)
        land = Spy()
        api, _, _ = billing_api([p])
        v2.run_billing(api, land, lambda: {"1": billed(p)},
                       today=DueForSweep().quiet_day(p))
        self.assertEqual(land.calls, [(v2.BILLING, [])])

    def test_a_project_deleted_since_listing_is_skipped(self):
        land, _, _ = self.run_it([proj(1), proj(2)], missing={"1"})
        self.assertEqual(land.calls, [(v2.BILLING, ["2"])])

    def test_an_unexpected_shape_fails_rather_than_landing_as_no_invoices(self):
        # {"error": ...} landed as [] would read as a project owing nothing.
        with self.assertRaises(RuntimeError) as cm:
            self.run_it([proj(1)], odd={"1"})
        self.assertIn("items", str(cm.exception))

    def test_a_failure_keeps_every_earlier_batch_and_the_next_run_resumes(self):
        listed = [proj(i, modified=f"2026-11-0{i}T00:00:00Z") for i in range(1, 4)]
        land = Spy(fail_on=lambda e, rs: any(r["project_id"] == "3" for r in rs))
        v2.BATCH_SIZE, saved = 2, v2.BATCH_SIZE
        try:
            with self.assertRaises(RuntimeError):
                self.run_it(listed, land=land)
            self.assertEqual(land.calls, [(v2.BILLING, ["1", "2"])])
            # Next night: what landed is settled and not due; 3 never landed.
            landed = {r["project_id"]: r for r in land.records}
            quiet = self.DAY
            while any(v2.due_for_sweep(p, landed[p["id"]], quiet, 7) for p in listed[:2]):
                quiet += datetime.timedelta(days=1)
            again = Spy()
            api, _, _ = billing_api(listed)
            v2.run_billing(api, again, lambda: landed, today=quiet)
            self.assertEqual(again.calls, [(v2.BILLING, ["3"])])
        finally:
            v2.BATCH_SIZE = saved

    def test_limit_caps_the_projects_swept(self):
        land, _, _ = self.run_it([proj(i) for i in range(1, 6)], limit=2)
        self.assertEqual(len(land.records), 2)

    def test_a_bare_array_is_read_as_the_items(self):
        api, _, _ = api_with(lambda u, p: Resp(200, [{"number": "INV-9"}]))
        self.assertEqual(v2.fetch_items(api, "/projects/{id}/invoices", "1"),
                         [{"number": "INV-9"}])


class ZohoMeetings(unittest.TestCase):
    def test_the_zoho_ingest_pulls_meetings(self):
        # Events is the API name of Meetings, where technicians log hours.
        self.assertIn("Events", ZOHO["modules"])


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
    def test_the_secret_exists_and_the_dtools_account_may_replace_it(self):
        # A rotated token the pipeline may not write back is lost the first
        # night Entra rotates it; the ingest dies the next night. The secret
        # belongs to the D-Tools ingest account (scripts/lib/common.sh), and
        # 05-ingestion-infra.sh grants each source's rotating secrets to it.
        common = (ROOT / "scripts" / "lib" / "common.sh").read_text()
        src = (ROOT / "scripts" / "05-ingestion-infra.sh").read_text()
        name = DTOOLS_V2["refresh_secret"]

        def entry(fn):
            body = common[common.index(f"{fn}() {{"):]
            body = body[:body.index("\n}\n")]
            return re.search(r"^\s*dtools\)\s+echo \"([^\"]*)\"", body, re.M).group(1).split()

        self.assertIn(name, entry("source_secrets"))
        self.assertIn(name, entry("source_rotating_secrets"))
        self.assertIn('for s in $(source_rotating_secrets "$src")', src)
        self.assertIn("roles/secretmanager.secretVersionAdder", src)

if __name__ == "__main__":
    unittest.main()
