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
whether this week's report arrived. A file that yields no records moves to
rejected/<prefix>/ instead, and the run fails so the alert opens an issue:
see handle_upload. Landing tables are append-only; staging
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

    Returns None — not an error — when the bucket is missing or unreadable.
    That is a setup state, not a failure: the landing tables are already
    ensured by the time this runs, so the transform still builds off whatever
    has been loaded by other means. Failing here would turn every scheduled
    run red until someone created the bucket, training the operator to ignore
    a red ingest, and the same posture ("source configured, no data yet")
    is what the rest of the pipeline already takes.

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
        log.warning("gs://%s does not exist — no uploads to read. Run "
                    "./scripts/09-vendor-drop.sh %s to create it.",
                    bucket.name, slug)
        return None
    except gexc.Forbidden:
        log.warning("no access to gs://%s — no uploads to read. Re-run "
                    "./scripts/09-vendor-drop.sh %s to grant ingest-writer.",
                    bucket.name, slug)
        return None
    return sorted((b for b in blobs if not b.name.endswith("/") and b.size),
                  key=lambda b: b.time_created)


def archive(bucket, blob, top):
    """Move an upload to <top>/<its path> with a timestamp; return the new name."""
    dest = f"{top}/{blob.name}"
    stamped = f"{os.path.dirname(dest)}/{util.utcnow_iso()[:19]}-{os.path.basename(dest)}"
    bucket.copy_blob(blob, bucket, stamped)
    blob.delete()
    return stamped


def why_empty(data, name, fmt_key):
    """A sentence for the person who uploaded a file that parsed to nothing."""
    if data.lstrip()[:5] == b"{\\rtf":
        return (f"{name} is a rich-text (.rtf) file, not the vendor's export. It "
                "was probably opened in a text editor and saved again. Upload "
                "the attachment exactly as the vendor sent it.")
    return (f"{name} has no row in the {fmt_key} layout. Check that it is the "
            "right report for this folder, exported in the vendor's own format.")


def handle_upload(bucket, blob, fmt_key, land, limit=None):
    """Parse one upload, land it, and archive it. Returns (rows, archived_to, error).

    A file that parses to NO records is rejected, not processed. On
    2026-09-28 a Customer Count saved as .rtf parsed to nothing, landed zero
    rows, logged "no new records" and was archived as done: a green run, and
    a report that never reached the warehouse. Every format here is a roster
    or an invoice, and a real one is never empty, so zero records always
    means the wrong file. It moves to rejected/ rather than staying put, so
    the folder is clear for the corrected upload and the next scheduled run
    does not fail on the same file again.
    """
    data = blob.download_as_bytes()
    records = tabular.parse(data, blob.name, fmt_key)
    if not records:
        error = why_empty(data, blob.name, fmt_key)
        return 0, archive(bucket, blob, "rejected"), error
    if limit:
        records = records[:limit]
    n = land(records)
    return n, archive(bucket, blob, "processed"), None


def main():
    args, cfg, dataset, run_id = runner.setup(
        "vendor", [tabular.table_name(k) for k in sorted(tabular.FORMATS)])
    from google.cloud import storage

    from ..lib import bq as bq_mod

    bucket_name = util.env_or("VENDOR_DROP_BUCKET", f"{cfg.project_id}-vendor-drops")
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

    total, files, reachable, rejected = 0, 0, True, []
    for fmt_key in sorted(tabular.FORMATS):
        pending = pending_blobs(bucket, fmt_key, cfg.slug)
        if pending is None:          # bucket missing or unreadable; warned once
            reachable = False
            break
        for blob in pending:
            log.info("%s: parsing %s (%d bytes)", fmt_key, blob.name, blob.size)
            # No source-side modified timestamp in these reports; the upload
            # is the only "when", and _loaded_at already carries it.
            def land(records, fmt_key=fmt_key):
                return runner.land(bq_mod, bq, cfg, dataset,
                                   tabular.table_name(fmt_key), records,
                                   tabular.id_column(fmt_key), None, run_id)
            n, stamped, error = handle_upload(bucket, blob, fmt_key, land,
                                              args.limit)
            files += 1
            total += n
            if error:
                log.error("%s: REJECTED, moved to gs://%s/%s: %s",
                          fmt_key, bucket_name, stamped, error)
                rejected.append(stamped)
            else:
                log.info("%s: archived to gs://%s/%s", fmt_key, bucket_name, stamped)

    if not files and reachable:
        log.info("no new files in gs://%s — nothing to do", bucket_name)
    log.info("done: %d files, %d rows total", files, total)
    if rejected:
        # After every other file has loaded, so one bad upload never holds
        # back the rest; failing turns the run red and the alert opens an issue.
        raise SystemExit(f"{len(rejected)} upload(s) held no records and were "
                         f"rejected: {', '.join(rejected)}")


if __name__ == "__main__":
    main()
