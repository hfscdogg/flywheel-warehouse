"""Shared ingest run scaffolding: args, logging, landing loads, watermarks."""

import argparse
import logging
import uuid

from . import config, util

log = logging.getLogger("flywheel.ingest")


def parse_args(source_name):
    p = argparse.ArgumentParser(description=f"Ingest {source_name} into raw_{source_name}")
    p.add_argument("--client", default="livewire", help="client slug (clients/<slug>/)")
    p.add_argument("--full-refresh", action="store_true",
                   help="ignore watermarks; pull everything")
    p.add_argument("--limit", type=int, default=0,
                   help="stop each entity after N records (smoke runs)")
    p.add_argument("--dry-run", action="store_true",
                   help="print the plan; no network, no GCP")
    return p.parse_args()


def setup(source_name, entities):
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    args = parse_args(source_name)
    cfg = config.load_client(args.client)
    dataset = cfg.raw_dataset_for(source_name)
    if dataset is None:
        log.info("client '%s' has no raw_%s in DATASETS_RAW — source disabled, nothing to do",
                 cfg.slug, source_name)
        raise SystemExit(0)
    if args.dry_run:
        log.info("[dry-run] would ingest %s into %s.%s (entities: %s)%s",
                 source_name, cfg.project_id, dataset, ", ".join(entities),
                 " FULL REFRESH" if args.full_refresh else "")
        raise SystemExit(0)
    run_id = f"{source_name}-{uuid.uuid4().hex[:12]}"
    log.info("run %s: client=%s dataset=%s.%s", run_id, cfg.slug, cfg.project_id, dataset)
    return args, cfg, dataset, run_id


def land(bq_mod, bq, cfg, dataset, entity, records, id_field, modified_field, run_id):
    """Wrap records, load them, advance the watermark. Returns rows loaded."""
    loaded_at = util.utcnow_iso()
    if not records:
        log.info("%s: no new records", entity)
        return 0
    rows = [util.build_row(r, id_field, modified_field, run_id, loaded_at) for r in records]
    table_id = bq_mod.ensure_table(bq, cfg, dataset, entity.lower(), bq_mod.LANDING_SCHEMA)
    n = bq_mod.load_rows(bq, table_id, rows, bq_mod.LANDING_SCHEMA)
    high = util.max_modified(records, modified_field)
    if high:
        bq_mod.set_watermark(bq, cfg, dataset, entity, high, run_id, loaded_at)
    log.info("%s: loaded %d rows into %s (watermark → %s)", entity, n, table_id, high)
    return n
