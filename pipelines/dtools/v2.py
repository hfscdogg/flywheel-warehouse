"""D-Tools Cloud API v2 → raw_dtools (v2_* tables). The API that carries cost.

v1 (pipelines/dtools/ingest.py) lands opportunities, quotes and projects from
list endpoints that return no cost field of any name, so kpi_project_margin
has had quoted price and no cost. v2 exposes cost in three places, one landing
table each:

- v2_project_proposals: a project's proposal data. Its summary carries cost,
  productCost, laborCost and margin; the labor summary splits labor cost by
  labor type. One GET per project, only for projects modified since the last
  run (v2_projects holds the list and the watermark).
- v2_purchase_orders: purchase order detail, whose products carry unitCost and
  the projectId they were bought for. One GET per changed purchase order.
- v2_time_entries: every time entry, with totalCost and costPerHour. No id
  and no modified date exist on these, so each run pulls them all.

Auth is delegated Entra External ID: see lib/sources.py DTOOLS_V2 and
pipelines/dtools/signin.py. Every shape here is from the published spec,
none yet observed; staging models wait for the first run's payloads.

Changed records are fetched OLDEST-FIRST in batches, and each batch lands
before the next is fetched, its list rows last so the watermark only moves
past what has landed. A run that dies keeps every finished batch and the next
run resumes from there: the Zoho Billing detail fetch's first attempt held
everything for one load at the end and lost an hour's work to a 401.
"""

import logging

from ..lib import runner, util
from ..lib.sources import DTOOLS_V2

log = logging.getLogger("flywheel.ingest.dtools_v2")

PROJECTS = "v2_projects"
PROPOSALS = "v2_project_proposals"
PURCHASE_ORDERS = "v2_purchase_orders"
TIME_ENTRIES = "v2_time_entries"
ENTITIES = [PROJECTS, PROPOSALS, PURCHASE_ORDERS, TIME_ENTRIES]

REQUIRED_ENV = ("DTOOLS_V2_TENANT_ID", "DTOOLS_V2_CLIENT_ID", "DTOOLS_V2_SCOPE")
BATCH_SIZE = 100


def settings(env):
    """The per-environment values D-Tools issues, from client.env.

    None is secret. Missing ones fail here, before any network call, with the
    names to set, rather than as an opaque 400 from the token endpoint.
    """
    missing = [k for k in REQUIRED_ENV if not env.get(k)]
    if missing:
        raise RuntimeError(
            "D-Tools v2 is not configured: set " + ", ".join(missing) +
            " in client.env (values issued by D-Tools; none is secret)")
    tenant = env["DTOOLS_V2_TENANT_ID"]
    return {
        "authority": (env.get("DTOOLS_V2_AUTHORITY")
                      or f"https://{tenant}.ciamlogin.com/{tenant}").rstrip("/"),
        "client_id": env["DTOOLS_V2_CLIENT_ID"],
        "scope": env["DTOOLS_V2_SCOPE"],
        "account_id": env.get("DTOOLS_V2_ACCOUNT_ID") or None,
        "base_url": (env.get("DTOOLS_V2_BASE_URL")
                     or DTOOLS_V2["base_url_default"]).rstrip("/"),
    }


def token_url(st):
    return f"{st['authority']}/oauth2/v2.0/token"


def refresh_access_token(http, st, refresh_token):
    """Trade the stored refresh token for (access_token, new_refresh_token)."""
    resp = http.post(
        token_url(st),
        data={
            "grant_type": "refresh_token",
            "client_id": st["client_id"],
            "refresh_token": refresh_token,
            "scope": f"{st['scope']} offline_access",
        },
        headers={"Accept": "application/json"},
        timeout=30,
    )
    if resp.status_code in (400, 401):
        try:
            err = resp.json().get("error")
        except ValueError:
            err = None
        if err in ("invalid_grant", "interaction_required"):
            # The one failure a person has to fix, so say how. A password
            # change, a revoked session or ~90 days unused all end here.
            raise RuntimeError(
                f"D-Tools refused the stored refresh token ({err}). Sign in "
                "again as the D-Tools service user: "
                "python -m pipelines.dtools.signin --client <slug>")
    util.raise_for_status(resp, "D-Tools v2 token refresh")
    body = resp.json()
    return body["access_token"], body.get("refresh_token")


class Api:
    """Bearer-authenticated GETs against the v2 base URL.

    read_secret/write_secret are passed in so the class holds no credential
    store of its own and tests need no GCP.
    """

    def __init__(self, http, st, read_secret, write_secret):
        self.http = http
        self.st = st
        self.read_secret = read_secret
        self.write_secret = write_secret
        self._access = None

    def authenticate(self):
        stored = self.read_secret()
        access, rotated = refresh_access_token(self.http, self.st, stored)
        # Writeback first: Entra may have retired the token just used, and
        # anything failing after this point must not take the new one with it.
        if rotated and rotated != stored:
            self.write_secret(rotated)
            log.info("Entra rotated the refresh token — new version written to Secret Manager")
        self._access = access

    def _headers(self):
        h = {"Authorization": f"Bearer {self._access}", "Accept": "application/json"}
        if self.st["account_id"]:
            h["X-DTools-AccountId"] = str(self.st["account_id"])
        return h

    def get(self, path, params=None):
        """GET, re-authenticating once on a 401: a first run of ~1,600
        project GETs can outlive a one-hour access token."""
        for attempt in (1, 2):
            resp = self.http.get(f"{self.st['base_url']}{path}", headers=self._headers(),
                                 params=params, timeout=60)
            if resp.status_code == 401 and attempt == 1:
                log.info("access token expired mid-run; refreshing")
                self.authenticate()
                continue
            return resp
        return resp


def fetch_list(api, conf, params, limit=0):
    """Every page of a v2 list endpoint, archived rows included."""
    records, page = [], 1
    while True:
        resp = api.get(conf["list_path"], params={
            **params, "includeArchived": "true",
            "page": page, "pageSize": DTOOLS_V2["page_size"]})
        util.raise_for_status(resp, f"D-Tools v2 {conf['list_path']} page {page}")
        body = resp.json()
        batch = body.get(conf["list_key"]) or []
        records.extend(batch)
        if limit and len(records) >= limit:
            return records[:limit]
        total = body.get(conf["total_key"])
        # The total is the stop condition when present, so a server that
        # caps pageSize below ours cannot end the pull after one short page.
        if not batch or (total is not None and len(records) >= total) \
                or (total is None and len(batch) < DTOOLS_V2["page_size"]):
            return records
        page += 1


def fetch_detail(api, conf, record_id):
    """One record's detail, or None when it is gone (deleted since listing)."""
    resp = api.get(conf["detail_path"].format(id=record_id), params=conf.get("detail_params"))
    if resp.status_code == 404:
        log.warning("%s %s: 404, skipped", conf["detail_path"], record_id)
        return None
    util.raise_for_status(resp, f"D-Tools v2 {conf['detail_path']} {record_id}")
    return resp.json()


def batches_oldest_first(records, size, modified_field="modifiedDate"):
    """Split records into batches, oldest modification first.

    A batch never ends between two records modified at the same instant: the
    watermark is the batch's newest time, and if the API's fromModifiedDate
    is exclusive, the record left on the far side of a split tie would never
    be listed again. Records with no timestamp go first, and are listed again
    on every run, which is the safe direction.
    """
    def key(r):
        try:
            ts = util.parse_ts(r.get(modified_field))
        except (TypeError, ValueError):
            ts = None
        return (ts is not None, ts.timestamp() if ts else 0.0)

    ordered = sorted(records, key=key)
    out, cur = [], []
    for r in ordered:
        if len(cur) >= size and key(r) != key(cur[-1]):
            out.append(cur)
            cur = []
        cur.append(r)
    if cur:
        out.append(cur)
    return out


def since_params(watermark):
    return {"fromModifiedDate": watermark.isoformat()} if watermark else {}


def run_projects(api, land, watermark, limit=0):
    """Changed projects → their proposal data, batch by batch. Returns rows."""
    conf = DTOOLS_V2["projects"]
    listed = fetch_list(api, conf, since_params(watermark), limit)
    log.info("projects: %d modified since %s", len(listed), watermark)
    if not listed:
        return land(PROPOSALS, [], "project_id", "project_modified_date") + \
            land(PROJECTS, [], "id", "modifiedDate")
    total = 0
    for batch in batches_oldest_first(listed, BATCH_SIZE):
        proposals = []
        for p in batch:
            data = fetch_detail(api, conf, p["id"])
            if data is not None:
                # The proposal body has no project id or modified time of its
                # own, so it lands wrapped with both, untouched inside.
                proposals.append({"project_id": p["id"],
                                  "project_modified_date": p.get("modifiedDate"),
                                  "proposal": data})
        total += land(PROPOSALS, proposals, "project_id", "project_modified_date")
        # The list rows land LAST: their load is what advances the watermark.
        total += land(PROJECTS, batch, "id", "modifiedDate")
    return total


def run_purchase_orders(api, land, watermark, limit=0):
    """Changed purchase orders → their detail, batch by batch. Returns rows."""
    conf = DTOOLS_V2["purchase_orders"]
    listed = fetch_list(api, conf, since_params(watermark), limit)
    log.info("purchase orders: %d modified since %s", len(listed), watermark)
    if not listed:
        return land(PURCHASE_ORDERS, [], "id", "modifiedDate")
    total = 0
    for batch in batches_oldest_first(listed, BATCH_SIZE):
        details = [d for d in (fetch_detail(api, conf, po["id"]) for po in batch)
                   if d is not None]
        total += land(PURCHASE_ORDERS, details, "id", "modifiedDate")
    return total


def run_time_entries(api, land, limit=0):
    records = fetch_list(api, DTOOLS_V2["time_entries"], {}, limit)
    # No id, no modified date: _source_id and _modified_at land NULL and
    # staging reads the newest run whole.
    return land(TIME_ENTRIES, records, None, None)


def main():
    args, cfg, dataset, run_id = runner.setup("dtools", ENTITIES)
    st = settings(cfg.env)
    from ..lib import bq as bq_mod
    from ..lib import secret_store, web

    secret = DTOOLS_V2["refresh_secret"]
    api = Api(web.session(), st,
              lambda: secret_store.get(cfg.project_id, secret),
              lambda value: secret_store.add_version(cfg.project_id, secret, value))
    api.authenticate()
    bq = bq_mod.client_for(cfg)

    def land(entity, records, id_field, modified_field):
        return runner.land(bq_mod, bq, cfg, dataset, entity, records,
                           id_field, modified_field, run_id)

    def watermark(entity):
        return None if args.full_refresh else bq_mod.get_watermark(bq, cfg, dataset, entity)

    total = run_projects(api, land, watermark(PROJECTS), args.limit)
    total += run_purchase_orders(api, land, watermark(PURCHASE_ORDERS), args.limit)
    total += run_time_entries(api, land, args.limit)
    log.info("done: %d rows total", total)


if __name__ == "__main__":
    main()
