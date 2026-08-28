"""Vendor report drop bucket → raw_vendor landing tables.

Monitoring vendors send reports, not APIs. This lets anyone with access to
the client's drop bucket upload an export from a browser — no CLI, no repo —
and have the warehouse pick it up on the next scheduled run.

Layout, one prefix per known report format (pipelines/lib/tabular.FORMATS),
each landing in that format's raw_vendor table:

    gs://<bucket>/securitycentral/allaccounts/AllAccounts.xlsx
        -> raw_vendor.securitycentral_accounts  (same table 08-vendor-roster.sh
           loads, so a browser upload and a CLI load are interchangeable)
    gs://<bucket>/securitycentral/customercount/45779342.CSV
        -> raw_vendor.securitycentral_status

Processed files move to processed/<prefix>/<timestamp>-<name> so a re-run
never double-loads and the drop folders stay empty enough to see at a glance
whether this week's report arrived. Landing tables are append-only; staging
keeps the latest row per record, so re-uploading the same export is harmless.

Env:
  VENDOR_DROP_BUCKET  optional; defaults to <project-id>-vendor-drops
"""

import logging
import os

from ..lib import runner, tabular, util

log = logging.getLogger("flywheel.ingest.vendordrop")


def pending_blobs(bucket, fmt_key, slug):
    """Unprocessed uploads under one format prefix, oldest first.

    Zero-byte objects are skipped: 09-vendor-drop.sh writes an empty `.keep`
    per prefix so the folders are visible in the console, and an interrupted
    browser upload can leave one behind too.

    The bucket is not probed with exists() first. That calls buckets.get,
    which `roles/storage.objectAdmin` — what ingest-writer is granted — does
    not include, so the readiness check would fail on a bucket the pipeline
    can read perfectly well. Listing is the real test; a missing bucket
    surfaces here instead.
    """
    from google.api_core import exceptions as gexc
    try:
        blobs = list(bucket.list_blobs(prefix=f"{fmt_key}/"))
    except gexc.NotFound:
        raise RuntimeError(
            f"drop bucket gs://{bucket.name} does not exist — "
            f"run ./scripts/09-vendor-drop.sh {slug}") from None
    except gexc.Forbidden:
        raise RuntimeError(
            f"no access to gs://{bucket.name} — re-run "
            f"./scripts/09-vendor-drop.sh {slug} to grant ingest-writer") from None
    return sorted((b for b in blobs if not b.name.endswith("/") and b.size),
                  key=lambda b: b.time_created)


def main():
    args, cfg, dataset, run_id = runner.setup(
        "vendor", [tabular.table_name(k) for k in sorted(tabular.FORMATS)])
    from google.cloud import storage

    from ..lib import bq as bq_mod

    bucket_name = os.environ.get("VENDOR_DROP_BUCKET", f"{cfg.project_id}-vendor-drops")
    gcs = storage.Client(project=cfg.project_id)
    bucket = gcs.bucket(bucket_name)

    bq = bq_mod.client_for(cfg)
    # A landing table per known format, whether or not anyone uploaded
    # anything. runner.land() does the same for the API sources and for the
    # same reason: staging models read every entity's table, so existence
    # cannot depend on data volume. It matters more here, because uploads are
    # occasional by nature — without this, kpi_subscription_audit is skipped
    # for want of a status table rather than falling back to the roster's own
    # status, which is exactly what status_source exists to report.
    for fmt_key in sorted(tabular.FORMATS):
        bq_mod.ensure_table(bq, cfg, dataset, tabular.table_name(fmt_key),
                            bq_mod.LANDING_SCHEMA)

    total, files = 0, 0
    for fmt_key in sorted(tabular.FORMATS):
        for blob in pending_blobs(bucket, fmt_key, cfg.slug):
            log.info("%s: parsing %s (%d bytes)", fmt_key, blob.name, blob.size)
            records = tabular.parse(blob.download_as_bytes(),
                                    blob.name, fmt_key)
            if args.limit:
                records = records[:args.limit]
            # No source-side modified timestamp in these reports; the upload
            # is the only "when", and _loaded_at already carries it.
            total += runner.land(bq_mod, bq, cfg, dataset,
                                 tabular.table_name(fmt_key), records,
                                 tabular.id_column(fmt_key), None, run_id)
            files += 1
            dest = f"processed/{blob.name}"
            stamped = f"{os.path.dirname(dest)}/{util.utcnow_iso()[:19]}-{os.path.basename(dest)}"
            bucket.copy_blob(blob, bucket, stamped)
            blob.delete()
            log.info("%s: archived to gs://%s/%s", fmt_key, bucket_name, stamped)

    if not files:
        log.info("no new files in gs://%s — nothing to do", bucket_name)
    log.info("done: %d files, %d rows total", files, total)


if __name__ == "__main__":
    main()
