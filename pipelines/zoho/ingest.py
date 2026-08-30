"""Zoho CRM → raw_zoho. Incremental via If-Modified-Since per module.

Auth: OAuth refresh-token flow against the account's Zoho data center
(ZOHO_ACCOUNTS_HOST env var overrides the default for .eu/.in/... tenants).
Credentials come from Secret Manager in the client's project.
"""

import logging

from ..lib import runner, util
from ..lib.sources import ZOHO

log = logging.getLogger("flywheel.ingest.zoho")


def get_access_token(http, project_id):
    from ..lib import secret_store

    accounts_host = util.env_or("ZOHO_ACCOUNTS_HOST", ZOHO["default_accounts_host"])
    resp = http.post(f"https://{accounts_host}/oauth/v2/token", data={
        "grant_type": "refresh_token",
        "client_id": secret_store.get(project_id, "flywheel-zoho-client-id"),
        "client_secret": secret_store.get(project_id, "flywheel-zoho-client-secret"),
        "refresh_token": secret_store.get(project_id, "flywheel-zoho-refresh-token"),
    }, timeout=30)
    util.raise_for_status(resp, "Zoho token refresh")
    body = resp.json()
    if "access_token" not in body:
        raise RuntimeError(f"Zoho token refresh failed: {body}")
    # api_domain pins the correct data center for record calls.
    return body["access_token"], body.get("api_domain", "https://www.zohoapis.com")


def fetch_module(http, token, api_domain, module, since, limit):
    """All pages of one module, optionally only records modified since the watermark."""
    headers = {"Authorization": f"Zoho-oauthtoken {token}"}
    if since is not None:
        headers["If-Modified-Since"] = since.isoformat()
    records, page = [], 1
    while True:
        resp = http.get(
            f"{api_domain}/crm/{ZOHO['api_version']}/{module}",
            headers=headers,
            params={"page": page, "per_page": ZOHO["page_size"]},
            timeout=60,
        )
        if resp.status_code == 304 or resp.status_code == 204:
            break  # 304: nothing modified since watermark; 204: module empty
        util.raise_for_status(resp, f"Zoho module {module}")
        body = resp.json()
        records.extend(body.get("data", []))
        if limit and len(records) >= limit:
            return records[:limit]
        if not body.get("info", {}).get("more_records"):
            break
        page += 1
    return records


def main():
    args, cfg, dataset, run_id = runner.setup("zoho", ZOHO["modules"])
    # GCP/network deps load only on real runs — --dry-run stays stdlib-only.
    from ..lib import bq as bq_mod
    from ..lib import web

    http = web.session()
    token, api_domain = get_access_token(http, cfg.project_id)
    bq = bq_mod.client_for(cfg)

    total = 0
    for module in ZOHO["modules"]:
        since = None if args.full_refresh else bq_mod.get_watermark(bq, cfg, dataset, module)
        records = fetch_module(http, token, api_domain, module, since, args.limit)
        total += runner.land(bq_mod, bq, cfg, dataset, module, records,
                             ZOHO["id_field"], ZOHO["modified_field"], run_id)
    log.info("done: %d rows total", total)


if __name__ == "__main__":
    main()
