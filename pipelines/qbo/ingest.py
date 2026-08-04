"""QuickBooks Online → raw_qbo. Incremental on MetaData.LastUpdatedTime.

Sharp edge this pipeline exists to handle: QBO ROTATES REFRESH TOKENS — a
token refresh can return a new refresh token, and the old one dies. The new
value is written straight back to Secret Manager (ingest-writer holds
secretVersionAdder on that one secret), so the pipeline stays stateless.
"""

import logging

from ..lib import runner
from ..lib.sources import QBO

log = logging.getLogger("flywheel.ingest.qbo")

REFRESH_SECRET = "flywheel-qbo-refresh-token"


def get_access_token(http, project_id):
    from ..lib import secret_store

    refresh_token = secret_store.get(project_id, REFRESH_SECRET)
    resp = http.post(
        QBO["token_url"],
        auth=(
            secret_store.get(project_id, "flywheel-qbo-client-id"),
            secret_store.get(project_id, "flywheel-qbo-client-secret"),
        ),
        data={"grant_type": "refresh_token", "refresh_token": refresh_token},
        headers={"Accept": "application/json"},
        timeout=30,
    )
    resp.raise_for_status()
    body = resp.json()

    # Rotation writeback — this must happen before anything else can fail.
    new_refresh = body.get("refresh_token")
    if new_refresh and new_refresh != refresh_token:
        from ..lib import secret_store as _ss

        _ss.add_version(project_id, REFRESH_SECRET, new_refresh)
        log.info("QBO rotated the refresh token — new version written to Secret Manager")

    return body["access_token"]


def fetch_entity(http, token, realm_id, entity, since, limit):
    """Page through the query API for one entity."""
    where = ""
    if since is not None:
        where = f" WHERE MetaData.LastUpdatedTime > '{since.isoformat()}'"
    records, start = [], 1
    while True:
        query = (f"SELECT * FROM {entity}{where} "
                 f"ORDERBY MetaData.LastUpdatedTime "
                 f"STARTPOSITION {start} MAXRESULTS {QBO['page_size']}")
        resp = http.get(
            f"{QBO['base_url']}/v3/company/{realm_id}/query",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
            params={"query": query, "minorversion": QBO["minorversion"]},
            timeout=60,
        )
        resp.raise_for_status()
        page = resp.json().get("QueryResponse", {}).get(entity, [])
        records.extend(page)
        if limit and len(records) >= limit:
            return records[:limit]
        if len(page) < QBO["page_size"]:
            break
        start += QBO["page_size"]
    return records


def main():
    args, cfg, dataset, run_id = runner.setup("qbo", QBO["entities"])
    # GCP/network deps load only on real runs — --dry-run stays stdlib-only.
    from ..lib import bq as bq_mod
    from ..lib import secret_store, web

    http = web.session()
    token = get_access_token(http, cfg.project_id)
    realm_id = secret_store.get(cfg.project_id, "flywheel-qbo-realm-id")
    bq = bq_mod.client_for(cfg)

    total = 0
    for entity in QBO["entities"]:
        since = None if args.full_refresh else bq_mod.get_watermark(bq, cfg, dataset, entity)
        records = fetch_entity(http, token, realm_id, entity, since, args.limit)
        total += runner.land(bq_mod, bq, cfg, dataset, entity, records,
                             QBO["id_field"], QBO["modified_field"], run_id)
    log.info("done: %d rows total", total)


if __name__ == "__main__":
    main()
