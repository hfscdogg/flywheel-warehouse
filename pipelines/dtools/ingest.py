"""D-Tools Cloud → raw_dtools. Full pull every run (small data volumes).

VERIFY ON FIRST LIVE RUN: the endpoint paths and pagination params in
lib/sources.py DTOOLS are best-effort and must be confirmed against the
account's D-Tools Cloud API reference. The fetcher is deliberately generic
(path + page/pageSize list pagination, list either bare or under 'items'),
so correcting an entry in sources.py is the entire fix.
"""

import logging

from ..lib import runner
from ..lib.sources import DTOOLS

log = logging.getLogger("flywheel.ingest.dtools")


def fetch_entity(http, api_key, entity, limit):
    headers = {"X-API-Key": api_key, "Accept": "application/json"}
    records, page = [], 1
    while True:
        resp = http.get(
            f"{DTOOLS['base_url']}{entity['path']}",
            headers=headers,
            params={"page": page, "pageSize": DTOOLS["page_size"]},
            timeout=60,
        )
        resp.raise_for_status()
        body = resp.json()
        batch = body if isinstance(body, list) else body.get("items", [])
        records.extend(batch)
        if limit and len(records) >= limit:
            return records[:limit]
        if len(batch) < DTOOLS["page_size"]:
            break
        page += 1
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
    for entity in DTOOLS["entities"]:
        records = fetch_entity(http, api_key, entity, args.limit)
        total += runner.land(bq_mod, bq, cfg, dataset, entity["name"], records,
                             DTOOLS["id_field"], DTOOLS["modified_field"], run_id)
    log.info("done: %d rows total", total)


if __name__ == "__main__":
    main()
