"""Zoho Desk → raw_zohodesk. Tickets incremental on modifiedTime; reference
lists (departments, agents, teams) full pull every run.

Why this source exists: Desk is the system of record for Livewire's tickets.
The CRM Cases module gets a copy of each web consult booking and nobody
updates it (every sales case since September 2026 sat "Unclaimed" in CRM on
2026-11-04 while Zack had closed them in Desk). Tickets, their status and
their outcome have to be read from Desk or they are not readable at all.

Auth: OAuth refresh-token flow like Zoho CRM, but with Desk.* scopes, so it
uses its own client id/secret/refresh-token secrets in the client's Secret
Manager. ZOHO_DESK_ORG_ID identifies the Desk organization and is required
on every call.

Incremental: tickets are searched by modifiedTimeRange from the watermark to
now, so a ticket closed last night lands tonight with its closedTime and
final status. A full refresh walks windows of ZOHO_DESK["window_days"] from
history_start to now, so no single search needs an offset past whatever
ceiling Desk's search endpoint has.
"""

import logging
from datetime import datetime, timedelta, timezone

from ..lib import runner, util
from ..lib.sources import ZOHO, ZOHO_DESK

log = logging.getLogger("flywheel.ingest.zohodesk")


def get_access_token(http, project_id):
    from ..lib import secret_store

    accounts_host = util.env_or("ZOHO_ACCOUNTS_HOST", ZOHO["default_accounts_host"])
    resp = http.post(f"https://{accounts_host}/oauth/v2/token", data={
        "grant_type": "refresh_token",
        "client_id": secret_store.get(project_id, "flywheel-zohodesk-client-id"),
        "client_secret": secret_store.get(project_id, "flywheel-zohodesk-client-secret"),
        "refresh_token": secret_store.get(project_id, "flywheel-zohodesk-refresh-token"),
    }, timeout=30)
    util.raise_for_status(resp, "Zoho Desk token refresh")
    body = resp.json()
    if "access_token" not in body:
        raise RuntimeError(f"Zoho Desk token refresh failed: {body}")
    # Desk does not live on www.zohoapis.com; the token response's api_domain
    # is the CRM host. ZOHO_DESK_API_DOMAIN overrides for .eu/.in tenants.
    return body["access_token"]


def api_domain():
    return util.env_or("ZOHO_DESK_API_DOMAIN", ZOHO_DESK["default_api_domain"]).rstrip("/")


def desk_ts(dt):
    """A datetime in the spelling Desk's time-range params require:
    yyyy-MM-ddTHH:mm:ss.SSSZ, GMT. Desk rejects an offset and reads a naive
    value as GMT, so everything is converted first."""
    dt = dt.astimezone(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


def search_windows(since, now, window_days):
    """[(start, end), ...] covering since..now in slices of window_days.

    A single search from the watermark is enough on a nightly run. A first
    run or --full-refresh covers years, and Desk pages a search with a
    1-based offset that it caps; walking the range in slices keeps each
    search small enough that the cap never matters, and lands what it has
    walked so far if a later slice fails.

    The last window ends at `now`, never beyond: a window into the future is
    harmless to Desk but makes the watermark lie about what was covered.
    """
    if since >= now:
        return []
    out, start = [], since
    step = timedelta(days=window_days)
    while start < now:
        end = min(start + step, now)
        out.append((start, end))
        start = end
    return out


def _headers(token, org_id):
    return {
        "Authorization": f"Zoho-oauthtoken {token}",
        ZOHO_DESK["org_header"]: org_id,
    }


def fetch_tickets_window(http, token, org_id, start, end, limit):
    """All tickets modified in [start, end), oldest modification first."""
    url = f"{api_domain()}/{ZOHO_DESK['api_path']}/{ZOHO_DESK['search_path']}"
    records, offset = [], 1
    while True:
        resp = http.get(url, headers=_headers(token, org_id), params={
            "modifiedTimeRange": f"{desk_ts(start)},{desk_ts(end)}",
            "sortBy": ZOHO_DESK["search_sort"],
            "from": offset,
            "limit": ZOHO_DESK["page_size"],
        }, timeout=60)
        if resp.status_code == 204:
            break  # Desk's "no results": an empty window, or past the last page
        util.raise_for_status(resp, "Zoho Desk ticket search")
        page = resp.json().get("data", [])
        records.extend(page)
        if limit and len(records) >= limit:
            return records[:limit]
        if len(page) < ZOHO_DESK["page_size"]:
            break
        offset += len(page)
    return records


def fetch_reference(http, token, org_id, entity, limit):
    """All pages of one reference list (departments, agents, teams)."""
    url = f"{api_domain()}/{ZOHO_DESK['api_path']}/{entity['path']}"
    records, offset = [], 1
    while True:
        resp = http.get(url, headers=_headers(token, org_id), params={
            "from": offset, "limit": ZOHO_DESK["page_size"],
        }, timeout=60)
        if resp.status_code == 204:
            break
        util.raise_for_status(resp, f"Zoho Desk {entity['name']}")
        page = resp.json().get(entity["list_key"], [])
        records.extend(page)
        if limit and len(records) >= limit:
            return records[:limit]
        if len(page) < ZOHO_DESK["page_size"]:
            break
        offset += len(page)
    return records


def since_for(watermark, full_refresh):
    """Where the ticket search starts: the stored watermark, or history_start
    on a first run or --full-refresh. A watermark is re-covered from one
    second before it: Desk stamps to the millisecond and the range is
    inclusive at the start, so the boundary ticket lands twice at worst
    (staging keeps the latest) rather than never."""
    if full_refresh or watermark is None:
        return util.parse_ts(ZOHO_DESK["history_start"])
    # BigQuery hands the stored TIMESTAMP back as an aware datetime; a test
    # or a replay may pass the ISO string instead. Either way, UTC.
    ts = watermark if isinstance(watermark, datetime) else util.parse_ts(watermark)
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts - timedelta(seconds=1)


def main():
    entity_names = [ZOHO_DESK["ticket_entity"]] + [e["name"] for e in ZOHO_DESK["reference_entities"]]
    args, cfg, dataset, run_id = runner.setup("zohodesk", entity_names)
    from ..lib import bq as bq_mod
    from ..lib import web

    org_id = util.env_or("ZOHO_DESK_ORG_ID")
    if not org_id:
        raise RuntimeError(
            "ZOHO_DESK_ORG_ID is not set — every Desk API call needs the orgId "
            "header (Desk setup → Developer Space → API, or GET /api/v1/organizations)")

    http = web.session()
    token = get_access_token(http, cfg.project_id)
    bq = bq_mod.client_for(cfg)

    total = 0
    for entity in ZOHO_DESK["reference_entities"]:
        records = fetch_reference(http, token, org_id, entity, args.limit)
        # Reference lists carry no reliable modified stamp across all three
        # endpoints; landed as a full snapshot each run, staging keeps the
        # latest load per id.
        total += runner.land(bq_mod, bq, cfg, dataset, entity["name"], records,
                             ZOHO_DESK["id_field"], None, run_id)

    tickets = ZOHO_DESK["ticket_entity"]
    watermark = None if args.full_refresh else bq_mod.get_watermark(bq, cfg, dataset, tickets)
    now = datetime.now(timezone.utc)
    windows = search_windows(since_for(watermark, args.full_refresh), now,
                             ZOHO_DESK["window_days"])
    log.info("tickets: %d search window(s) from %s", len(windows),
             windows[0][0].isoformat() if windows else "nowhere")
    for start, end in windows:
        records = fetch_tickets_window(http, token, org_id, start, end, args.limit)
        # Landed per window, oldest first, so the watermark only ever moves
        # forward and a run that dies mid-backfill resumes where it stopped.
        total += runner.land(bq_mod, bq, cfg, dataset, tickets, records,
                             ZOHO_DESK["id_field"], ZOHO_DESK["modified_field"], run_id)
        if args.limit and total >= args.limit:
            break
    log.info("done: %d rows total", total)


if __name__ == "__main__":
    main()
