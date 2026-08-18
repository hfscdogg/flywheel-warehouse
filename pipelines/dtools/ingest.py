"""D-Tools Cloud → raw_dtools. Full pull every run (small data volumes).

Endpoint paths, auth, response shapes, and pagination in lib/sources.py
DTOOLS were verified against the live API reference
(https://dtcloudapi.d-tools.cloud/apidocs/index.html) on the first live run:

- Auth is TWO headers: the tenant API key (X-API-Key) plus the fixed Basic
  Authorization value D-Tools publishes in its public docs.
- List endpoints wrap results under an entity-named key ('opportunities',
  'projects') with page/pageSize pagination.
- GetQuotes requires an opportunityId (400 without one, despite the spec
  marking it optional) and returns a bare array — so quotes are fetched per
  opportunity id, after the opportunities pull.
"""

import logging

from ..lib import runner
from ..lib.sources import DTOOLS

log = logging.getLogger("flywheel.ingest.dtools")


def _headers(api_key):
    # D-Tools requires BOTH headers (see lib/sources.py DTOOLS).
    return {
        "X-API-Key": api_key,
        "Authorization": DTOOLS["auth_basic"],
        "Accept": "application/json",
    }


def fetch_entity(http, api_key, entity, limit):
    """Paginated list pull; the list sits under entity['list_key'] (or is bare)."""
    records, page = [], 1
    while True:
        resp = http.get(
            f"{DTOOLS['base_url']}{entity['path']}",
            headers=_headers(api_key),
            params={"page": page, "pageSize": DTOOLS["page_size"]},
            timeout=60,
        )
        resp.raise_for_status()
        body = resp.json()
        batch = body if isinstance(body, list) else body.get(entity.get("list_key", "items"), [])
        records.extend(batch)
        if limit and len(records) >= limit:
            return records[:limit]
        if len(batch) < DTOOLS["page_size"]:
            break
        page += 1
    return records


def fetch_quotes(http, api_key, entity, opportunity_ids, limit):
    """One GetQuotes call per opportunity id; returns the combined list."""
    records = []
    for oid in opportunity_ids:
        resp = http.get(
            f"{DTOOLS['base_url']}{entity['path']}",
            headers=_headers(api_key),
            params={"opportunityId": oid},
            timeout=60,
        )
        resp.raise_for_status()
        body = resp.json()
        records.extend(body if isinstance(body, list) else body.get("items", []))
        if limit and len(records) >= limit:
            return records[:limit]
    return records


def main():
    entity_names = [e["name"] for e in DTOOLS["entities"]]
    args, cfg, dataset, run_id = runner.setup("dtools", entity_names)
    # GCP/network deps load only on real runs — --dry-run stays stdlib-only.
    from ..lib import bq as bq_mod
    from ..lib import secret_store, web

    http = web.session()
    api_key = secret_store.get(cfg.project_id, "flywheel-dtools-api-key")
    bq = bq_mod.client_for(cfg)

    total = 0
    opportunity_ids = []
    for entity in DTOOLS["entities"]:
        if entity.get("per_opportunity"):
            records = fetch_quotes(http, api_key, entity, opportunity_ids, args.limit)
        else:
            records = fetch_entity(http, api_key, entity, args.limit)
            if entity["name"] == "opportunities":
                opportunity_ids = [r["id"] for r in records if r.get("id")]
        total += runner.land(bq_mod, bq, cfg, dataset, entity["name"], records,
                             DTOOLS["id_field"], DTOOLS["modified_field"], run_id)
    log.info("done: %d rows total", total)


if __name__ == "__main__":
    main()
