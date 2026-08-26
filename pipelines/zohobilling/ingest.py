"""Zoho Billing → raw_zohobilling. Full pull per run (small subscription book).

Auth: OAuth refresh-token flow like Zoho CRM, but with ZohoSubscriptions.*
scopes, so it uses its own client id/secret/refresh-token secrets in the
client's Secret Manager. ZOHO_BILLING_ORG_ID identifies the billing org and
is required on every call.

Why full pull, not incremental: the whole book is a couple of thousand rows,
and cancelled/expired subscriptions are exactly what the subscription audit
needs — a last_modified_time watermark would quietly stop refreshing rows
that stopped changing.
"""

import logging
import os

from ..lib import runner, util
from ..lib.sources import ZOHO, ZOHO_BILLING

log = logging.getLogger("flywheel.ingest.zohobilling")


def get_access_token(http, project_id):
    from ..lib import secret_store

    accounts_host = os.environ.get("ZOHO_ACCOUNTS_HOST", ZOHO["default_accounts_host"])
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


def main():
    entity_names = [e["name"] for e in ZOHO_BILLING["entities"]]
    args, cfg, dataset, run_id = runner.setup("zohobilling", entity_names)
    from ..lib import bq as bq_mod
    from ..lib import web

    org_id = os.environ.get("ZOHO_BILLING_ORG_ID")
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
        total += runner.land(bq_mod, bq, cfg, dataset, entity["name"], records,
                             entity["id_field"], ZOHO_BILLING["modified_field"], run_id)
    log.info("done: %d rows total", total)


if __name__ == "__main__":
    main()
