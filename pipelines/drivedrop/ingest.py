"""Vendor reports saved to Drive folders → the same raw_vendor tables uploads use.

The vendor drop bucket (pipelines/vendordrop) needs a person to upload each
report. Reports a vendor emails can skip that person: an Apps Script in the
recipient's Gmail (scripts/apps-script/save-vendor-documents.gs) saves the
attachment into a Drive folder shared Viewer with ingest-vendor, and this
reads the folder. Each folder is tied to one known report format
(pipelines/lib/tabular.FORMATS), parsed by the same code and landed in the
same table as an upload of that format, so staging and the marts cannot tell
the two routes apart.

A file loads once per content checksum (raw_vendor.drivedrop_files). A file
that parses to nothing is recorded and fails the run, the rule the bucket
follows: every format here is a roster or an invoice, and a real one is
never empty.

Env / client.env:
  DRIVE_DROPS  "<format>=<folder id> ...", e.g. "parasol/invoice=1ySe…".
               Unset means nothing to do.
"""

import logging

from ..lib import runner, tabular, util
from ..qbd.ingest import DriveSetupError, download, drive_session, file_key, list_folder

log = logging.getLogger("flywheel.ingest.drivedrop")

FILES = "drivedrop_files"
MAX_BYTES = 25 * 1048576


def parse_config(spec):
    """'parasol/invoice=ID ...' -> {'parasol/invoice': 'ID'}; unknown formats refused."""
    out = {}
    for part in (spec or "").split():
        fmt_key, sep, folder = part.partition("=")
        if not sep or not folder:
            raise SystemExit(f"DRIVE_DROPS entry '{part}' is not <format>=<folder id>")
        if fmt_key not in tabular.FORMATS:
            raise SystemExit(f"DRIVE_DROPS names '{fmt_key}', which is not a known report "
                             f"format ({', '.join(sorted(tabular.FORMATS))})")
        out[fmt_key] = folder
    return out


def plan(files, loaded):
    """(to_load, skipped) from one folder's listing. Pure, for the tests."""
    to_load, skipped = [], []
    for f in sorted(files, key=lambda f: f["name"]):
        if f.get("mimeType") == "application/vnd.google-apps.folder":
            continue
        if int(f.get("size") or 0) > MAX_BYTES:
            skipped.append((f["name"], "over the size cap"))
        elif file_key(f) not in loaded:
            to_load.append(f)
    return to_load, skipped


def loaded_keys(bq, cfg, dataset):
    try:
        return {r[0] for r in bq.query(
            f"SELECT DISTINCT _source_id FROM `{cfg.project_id}.{dataset}.{FILES}` "
            "WHERE JSON_VALUE(payload, '$.ok') = 'true'").result()}
    except Exception:          # table absent until the first load
        return set()


def main():
    args, cfg, dataset, run_id = runner.setup("vendor", [FILES])
    drops = parse_config(util.env_or("DRIVE_DROPS", cfg.env.get("DRIVE_DROPS")))
    from ..lib import bq as bq_mod
    bq = bq_mod.client_for(cfg)
    bq_mod.ensure_table(bq, cfg, dataset, FILES, bq_mod.LANDING_SCHEMA)
    if not drops:
        log.info("DRIVE_DROPS not set for '%s' — nothing to do", cfg.slug)
        return
    session, account = drive_session()
    loaded = loaded_keys(bq, cfg, dataset)
    failed = []
    for fmt_key, folder_id in sorted(drops.items()):
        table = tabular.table_name(fmt_key)
        bq_mod.ensure_table(bq, cfg, dataset, table, bq_mod.LANDING_SCHEMA)
        try:
            files = list_folder(session, folder_id, cfg.project_id, account)
        except DriveSetupError as e:
            log.error("%s: %s", fmt_key, e)
            failed.append(fmt_key)
            continue
        to_load, skipped = plan(files, loaded)
        for name, why in skipped:
            log.info("%s: skip %s: %s", fmt_key, name, why)
        for f in to_load:
            records = tabular.parse(download(session, f["id"]), f["name"], fmt_key)
            info = {"key": file_key(f), "format": fmt_key, "file": f["name"],
                    "file_id": f["id"], "modified_at": f.get("modifiedTime"),
                    "rows": len(records), "ok": bool(records)}
            n = 0
            if records:
                n = runner.land(bq_mod, bq, cfg, dataset, table, records,
                                tabular.id_column(fmt_key), None, run_id)
                log.info("%s: %s → %d rows in %s", fmt_key, f["name"], n, table)
            else:
                log.error("%s: %s parsed to no rows; is it the right report?",
                          fmt_key, f["name"])
                failed.append(f["name"])
            runner.land(bq_mod, bq, cfg, dataset, FILES, [info], "key",
                        "modified_at", run_id)
    if failed:
        raise SystemExit("Drive drops not loaded: " + ", ".join(failed))


if __name__ == "__main__":
    main()
