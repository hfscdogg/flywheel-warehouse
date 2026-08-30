"""Zoho Billing → raw_zohobilling. Full pull per run (small subscription book).

Auth: OAuth refresh-token flow like Zoho CRM, but with ZohoSubscriptions.*
scopes, so it uses its own client id/secret/refresh-token secrets in the
client's Secret Manager. ZOHO_BILLING_ORG_ID identifies the billing org and
is required on every call.

Why full pull, not incremental: the whole book is a couple of thousand rows,
and cancelled/expired subscriptions are exactly what the subscription audit
needs — a last_modified_time watermark would quietly stop refreshing rows
that stopped changing.

Customers are the exception, and they invert the pattern: the list endpoint
carries no address at all, so the list only enumerates ids and the record
landed is the per-customer GET. See fetch_customer_details.
"""

import logging

from ..lib import runner, util
from ..lib.sources import ZOHO, ZOHO_BILLING

log = logging.getLogger("flywheel.ingest.zohobilling")


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
    return [c for c in listed if (c.get(modified) or "") > since or not c.get(modified)]


def fetch_customer_details(http, token, api_domain, org_id, listed, since, limit):
    """Full customer records — the only place a billing address exists.

    The Billing list endpoint returns no billing_address object whatsoever:
    verified 2026-08-30 against the landed data, 0 of 34,248 rows had one.
    Without an address there is nothing to match a monitoring-vendor account
    against, and kpi_subscription_audit reported all 522 active accounts as
    BILLED_NO_MATCH — a broken join that reads like 522 unbilled customers.

    This is the LIST-vs-GET split that hid plan_code (#18) taken one step
    further: there the field sat at the top level instead of the documented
    nesting, here it is simply absent until you ask for the record itself.

    Only customers whose list record is newer than the stored watermark are
    re-fetched — every customer on a first run, a handful after that.
    Addresses change rarely and the whole book is a couple of thousand rows,
    so this stays cheap without going stale. --full-refresh refetches all.
    """
    headers = {
        "Authorization": f"Zoho-oauthtoken {token}",
        ZOHO_BILLING["org_header"]: org_id,
    }
    stale = customers_needing_detail(listed, since)
    if limit:
        stale = stale[:limit]
    log.info("customers: %d listed, %d need detail%s", len(listed), len(stale),
             "" if since is None else f" (modified since {since})")

    records = []
    for n, listed_customer in enumerate(stale, 1):
        customer_id = listed_customer.get("customer_id")
        if not customer_id:
            continue
        url = f"{api_domain}/{ZOHO_BILLING['api_path']}/customers/{customer_id}"
        resp = http.get(url, headers=headers, timeout=60)
        util.raise_for_status(resp, f"Zoho Billing customer {customer_id}")
        record = resp.json().get("customer")
        if record:
            records.append(record)
        if n % 250 == 0:
            log.info("customers: %d/%d details fetched", n, len(stale))
    return records


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
        # Customer detail fetch is off by default. The first live attempt
        # (2026-08-30) showed the approach does not survive contact: 6,853
        # customers, not the ~2.2k the subscription count suggested, fetched
        # at ~8/minute — roughly 14 hours — and Zoho access tokens expire
        # after one, so the run died on HTTP 401 at minute 62 having landed
        # nothing. Three defects compound: no mid-run token refresh, a volume
        # no single run can cover, and an all-or-nothing land at the end that
        # discarded the 250 records it did fetch.
        #
        # Left in place rather than reverted because the underlying finding
        # stands — the list endpoint carries no address — but enabling it
        # again needs all three fixed, plus a decision on whether Zoho CRM's
        # account addresses make it unnecessary. Off, the pipeline behaves
        # exactly as it did before #25 instead of failing nightly.
        if entity["name"] == "customers" and util.env_or("ZOHOBILLING_CUSTOMER_DETAIL"):
            since = None if args.full_refresh else bq_mod.get_watermark(
                bq, cfg, dataset, entity["name"])
            records = fetch_customer_details(http, token, api_domain, org_id,
                                             records, since, args.limit)
        total += runner.land(bq_mod, bq, cfg, dataset, entity["name"], records,
                             entity["id_field"], ZOHO_BILLING["modified_field"], run_id)
    log.info("done: %d rows total", total)


if __name__ == "__main__":
    main()
