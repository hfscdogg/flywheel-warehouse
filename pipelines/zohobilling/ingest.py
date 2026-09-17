"""Zoho Billing → raw_zohobilling. Full pull per run (small subscription book).

Auth: OAuth refresh-token flow like Zoho CRM, but with ZohoSubscriptions.*
scopes, so it uses its own client id/secret/refresh-token secrets in the
client's Secret Manager. ZOHO_BILLING_ORG_ID identifies the billing org and
is required on every call.

Why full pull, not incremental: the whole book is a couple of thousand rows,
and cancelled/expired subscriptions are exactly what the subscription audit
needs — a last_modified_time watermark would quietly stop refreshing rows
that stopped changing.

Customers are the exception: the list endpoint carries no address at all, so
the list lands every night as before AND, when ZOHOBILLING_CUSTOMER_DETAIL is
set, the per-customer GET lands on top of it for every customer modified
since the detail fetch last reached them. See fetch_customer_details.
"""

import logging
import time

from ..lib import runner, util
from ..lib.sources import ZOHO, ZOHO_BILLING

log = logging.getLogger("flywheel.ingest.zohobilling")

#: The detail fetch keeps its own watermark. The list lands nightly under
#: "customers" and advances that watermark to the newest customer in the
#: book, so reading it here would say every customer had already been
#: detailed when none had -- the state the first live attempt left behind.
DETAIL_WATERMARK_ENTITY = "customers_detail"

#: Detail records land this many at a time, so a run that stops early --
#: budget, token, runner -- keeps everything fetched up to the last batch.
DETAIL_BATCH_SIZE = 200

#: Minutes of detail fetching per run before stopping and leaving the rest
#: for the next one. GitHub Actions kills a job at 360; the list pull and the
#: landing need some of that.
DETAIL_BUDGET_MINUTES_DEFAULT = 240


def get_access_token(http, project_id):
    from ..lib import secret_store

    accounts_host = util.env_or("ZOHO_ACCOUNTS_HOST", ZOHO["default_accounts_host"])
    resp = http.post(f"https://{accounts_host}/oauth/v2/token", data={
        "grant_type": "refresh_token",
        "client_id": secret_store.get(project_id, "flywheel-zohobilling-client-id"),
        "client_secret": secret_store.get(project_id, "flywheel-zohobilling-client-secret"),
        "refresh_token": secret_store.get(project_id, "flywheel-zohobilling-refresh-token"),
    }, timeout=30)
    util.raise_for_status(resp, "Zoho Billing token refresh")
    body = resp.json()
    if "access_token" not in body:
        raise RuntimeError(f"Zoho Billing token refresh failed: {body}")
    return body["access_token"], body.get("api_domain", "https://www.zohoapis.com")


def fetch_entity(http, token, api_domain, org_id, entity, limit):
    """All pages of one Billing entity."""
    headers = {
        "Authorization": f"Zoho-oauthtoken {token}",
        ZOHO_BILLING["org_header"]: org_id,
    }
    url = f"{api_domain}/{ZOHO_BILLING['api_path']}/{entity['path']}"
    records, page = [], 1
    while True:
        resp = http.get(url, headers=headers, params={
            "page": page, "per_page": ZOHO_BILLING["page_size"],
            # Cancelled/expired subscriptions matter for the audit, so no
            # status filter — the default listing is every subscription.
        }, timeout=60)
        if resp.status_code == 204:
            break
        util.raise_for_status(resp, f"Zoho Billing {entity['name']}")
        body = resp.json()
        records.extend(body.get(entity["list_key"], []))
        if limit and len(records) >= limit:
            return records[:limit]
        if not body.get("page_context", {}).get("has_more_page"):
            break
        page += 1
    return records


def customers_needing_detail(listed, since):
    """Listed customers whose detail we have not already fetched.

    `since` is the stored watermark — the newest last_modified_time we have
    landed a detail record for. None (a first run, or --full-refresh) means
    every customer. A listed customer with no last_modified_time at all is
    always re-fetched: unknown is not the same as unchanged, and guessing
    wrong here silently freezes an address.
    """
    if since is None:
        return list(listed)
    modified = ZOHO_BILLING["modified_field"]
    # Parsed, not compared as strings. Zoho lists "2026-09-17T15:00:00-0400"
    # and the stored watermark is UTC "2026-09-17T16:35:35+00:00"; as strings
    # the first sorts BEFORE the second although it is the later instant,
    # and a customer changed after the watermark would never be re-fetched.
    since_ts = util.parse_ts(since)
    out = []
    for c in listed:
        ts = util.parse_ts(c.get(modified))
        if ts is None or since_ts is None or ts > since_ts:
            out.append(c)
    return out


def detail_fetch_order(stale):
    """Oldest modification first, customers with no timestamp last.

    The detail watermark is the newest modification LANDED, and a run may
    stop before it lands everything. Fetching oldest-first makes that
    watermark honest: everything modified before it has been fetched, so the
    next run resumes exactly where this one stopped instead of re-fetching
    the whole book or, worse, skipping what it never reached. Customers with
    no timestamp are always re-fetched (see customers_needing_detail), so
    where they sit changes nothing about the watermark; last keeps them from
    holding up the ones that do advance it.
    """
    modified = ZOHO_BILLING["modified_field"]
    def key(c):
        ts = util.parse_ts(c.get(modified))
        return (ts is None, ts.timestamp() if ts is not None else 0.0)
    return sorted(stale, key=key)


def fetch_customer_details(http, token, api_domain, org_id, listed, since, limit,
                           land, refresh_token=None, budget_seconds=None,
                           batch_size=DETAIL_BATCH_SIZE, clock=time.monotonic):
    """Full customer records -- the only place a billing address exists.

    The Billing list endpoint returns no billing_address object whatsoever:
    verified 2026-08-30 against the landed data, 0 of 34,248 rows had one.
    Without an address there is nothing to match a monitoring-vendor account
    against directly, and Zoho Billing's own duplicate profiles can only be
    told apart by name, email or phone.

    This is the LIST-vs-GET split that hid plan_code (#18) taken one step
    further: there the field sat at the top level instead of the documented
    nesting, here it is simply absent until you ask for the record itself.

    THE FIRST LIVE ATTEMPT (2026-08-30) DID NOT SURVIVE CONTACT: 6,853
    customers at ~8 detail calls a minute is ~14 hours, the access token
    expires after one, and everything fetched was held for a single load at
    the end -- so the run died on HTTP 401 at minute 62 having landed nothing.
    Three things here answer those three defects:

      * `land` is called every `batch_size` records, in oldest-modified-first
        order, and advances the detail watermark to the batch's newest
        modification. A run that stops for any reason keeps what it landed
        and the next run resumes after it.
      * `refresh_token` is called on a 401 and the request retried once with
        the new token. A second 401 is a real failure.
      * `budget_seconds` stops the loop once spent, after landing the partial
        batch, and logs how many customers remain. Zoho's rate is not ours to
        change, so the backfill takes as many nightly runs as it takes.

    Only customers whose list record is newer than the stored watermark are
    fetched -- every customer on a first run, a handful after the backfill.
    --full-refresh refetches all. Returns (records landed, finished).
    """
    stale = detail_fetch_order(customers_needing_detail(listed, since))
    if limit:
        stale = stale[:limit]
    log.info("customers: %d listed, %d need detail%s", len(listed), len(stale),
             "" if since is None else f" (modified since {since})")

    started = clock()
    landed, batch = 0, []
    for n, listed_customer in enumerate(stale, 1):
        customer_id = listed_customer.get("customer_id")
        if not customer_id:
            continue
        url = f"{api_domain}/{ZOHO_BILLING['api_path']}/customers/{customer_id}"
        resp = http.get(url, headers=_headers(token, org_id), timeout=60)
        # One refresh per customer, not one per run: the token expires every
        # hour and a budgeted run lasts four. A 401 straight after a refresh
        # is not expiry and raises below.
        if resp.status_code == 401 and refresh_token is not None:
            log.info("customers: token expired after %d details; refreshing", n - 1)
            token = refresh_token()
            resp = http.get(url, headers=_headers(token, org_id), timeout=60)
        util.raise_for_status(resp, f"Zoho Billing customer {customer_id}")
        record = resp.json().get("customer")
        if record:
            batch.append(record)
        if len(batch) >= batch_size:
            landed += land(batch)
            batch = []
            log.info("customers: %d/%d details fetched", n, len(stale))
        if budget_seconds is not None and clock() - started >= budget_seconds and n < len(stale):
            if batch:
                landed += land(batch)
                batch = []
            log.warning("customers: detail budget of %ds spent after %d of %d; "
                        "%d remain for the next run", budget_seconds, n,
                        len(stale), len(stale) - n)
            return landed, False
    if batch:
        landed += land(batch)
    return landed, True


def _headers(token, org_id):
    return {
        "Authorization": f"Zoho-oauthtoken {token}",
        ZOHO_BILLING["org_header"]: org_id,
    }


def land_detail_batch(bq_mod, bq, cfg, dataset, entity, records, run_id):
    """Land one batch of detail records and advance the DETAIL watermark.

    Not runner.land: that advances the entity's own watermark, which is the
    list's, and a batch of old records would drag it backwards. The detail
    watermark is the newest modification landed here, and because batches
    arrive oldest-first it only ever moves forward.
    """
    loaded_at = util.utcnow_iso()
    table_id = bq_mod.ensure_table(bq, cfg, dataset, entity["name"].lower(),
                                   bq_mod.LANDING_SCHEMA)
    rows = [util.build_row(r, entity["id_field"], ZOHO_BILLING["modified_field"],
                           run_id, loaded_at) for r in records]
    n = bq_mod.load_rows(bq, table_id, rows, bq_mod.LANDING_SCHEMA)
    high = util.max_modified(records, ZOHO_BILLING["modified_field"])
    if high:
        bq_mod.set_watermark(bq, cfg, dataset, DETAIL_WATERMARK_ENTITY, high,
                             run_id, loaded_at)
    log.info("customers: landed %d detail rows (detail watermark → %s)", n, high)
    return n


def detail_budget_seconds():
    minutes = util.env_or("ZOHOBILLING_DETAIL_BUDGET_MIN", str(DETAIL_BUDGET_MINUTES_DEFAULT))
    return int(minutes) * 60


def main():
    entity_names = [e["name"] for e in ZOHO_BILLING["entities"]]
    args, cfg, dataset, run_id = runner.setup("zohobilling", entity_names)
    from ..lib import bq as bq_mod
    from ..lib import web

    org_id = util.env_or("ZOHO_BILLING_ORG_ID")
    if not org_id:
        raise RuntimeError(
            "ZOHO_BILLING_ORG_ID is not set — every Billing API call needs the "
            "org header (find it via GET /organizations or Billing settings)")

    http = web.session()
    token, api_domain = get_access_token(http, cfg.project_id)
    bq = bq_mod.client_for(cfg)

    total = 0
    for entity in ZOHO_BILLING["entities"]:
        records = fetch_entity(http, token, api_domain, org_id, entity, args.limit)
        # The list lands every run as it always has: it refreshes names,
        # emails and phones for the whole book in one pass.
        total += runner.land(bq_mod, bq, cfg, dataset, entity["name"], records,
                             entity["id_field"], ZOHO_BILLING["modified_field"], run_id)
        # Then, when switched on, the per-customer GET lands on top for every
        # customer the detail fetch has not reached since it was last
        # modified. Same table, same _modified_at; the staging model prefers
        # the record carrying an address, so the detail wins the tie.
        #
        # Off by default. The first live attempt (2026-08-30) died on HTTP
        # 401 at minute 62 having landed nothing -- see fetch_customer_details
        # for the three defects and what answers each. The backfill is ~6,900
        # customers at Zoho's pace and will take several runs; the budget and
        # the detail watermark make each one count. Switch on with the
        # workflow's customer_detail input, or make it nightly by setting the
        # ZOHOBILLING_CUSTOMER_DETAIL repository variable.
        if entity["name"] == "customers" and util.env_or("ZOHOBILLING_CUSTOMER_DETAIL"):
            since = None if args.full_refresh else bq_mod.get_watermark(
                bq, cfg, dataset, DETAIL_WATERMARK_ENTITY)
            landed, finished = fetch_customer_details(
                http, token, api_domain, org_id, records, since, args.limit,
                land=lambda batch: land_detail_batch(bq_mod, bq, cfg, dataset, entity,
                                                     batch, run_id),
                refresh_token=lambda: get_access_token(http, cfg.project_id)[0],
                budget_seconds=detail_budget_seconds())
            total += landed
            if not finished:
                log.warning("customers: detail backfill incomplete; the next run "
                            "resumes from the detail watermark")
    log.info("done: %d rows total", total)


if __name__ == "__main__":
    main()
