"""Security Central monthly statements (a Drive folder) → raw_vendor.

The statement arrives by email on the 25th. A Google Apps Script in the
recipient's own Gmail (scripts/apps-script/save-vendor-documents.gs)
saves each statement PDF into a Drive folder, so the warehouse never reads a
mailbox. That folder is shared, Viewer, with ingest-vendor, which reads it
here through the same read-only Drive access as the QuickBooks Desktop
export (pipelines/qbd/ingest.py).

Each run lists the folder and loads only PDFs it has not loaded before (by
Drive file id and checksum), so a nightly run is a listing and nothing else
except after the 25th.

  securitycentral_statement_lines  one row per line on the statement
  securitycentral_statement_files  one row per statement loaded

A statement that does not reconcile with its own printed totals lands
nothing: the run records the problem in the files table, fails, and the
alert opens an issue. The other statements in the folder still load.

Env / client.env:
  SC_STATEMENT_DRIVE_FOLDER_ID   the Drive folder; unset means nothing to do.
"""

import logging

from ..lib import runner, util
from ..qbd.ingest import DriveSetupError, download, drive_session, file_key, list_folder
from . import statement

log = logging.getLogger("flywheel.ingest.scstatement")

LINES = "securitycentral_statement_lines"
FILES = "securitycentral_statement_files"
MAX_BYTES = 20 * 1048576


def plan(files, loaded):
    """(to_load, skipped) from a folder listing. Pure, for the tests."""
    to_load, skipped = [], []
    for f in sorted(files, key=lambda f: f["name"]):
        if not f["name"].lower().endswith(".pdf"):
            skipped.append((f["name"], "not a PDF"))
        elif int(f.get("size") or 0) > MAX_BYTES:
            skipped.append((f["name"], "over the size cap"))
        elif file_key(f) not in loaded:
            to_load.append(f)
    return to_load, skipped


def records(f, parsed):
    """Landing records for one parsed statement file."""
    head = parsed["statement"]
    common = {"file": f["name"], "file_id": f["id"],
              "statement_date": head["statement_date"],
              "dealer_account": head["account_number"]}
    return [dict(line, **common, id=f"{f['id']}:{line['line']}") for line in parsed["lines"]]


def loaded_keys(bq, cfg, dataset):
    try:
        return {r[0] for r in bq.query(
            f"SELECT DISTINCT _source_id FROM `{cfg.project_id}.{dataset}.{FILES}` "
            "WHERE JSON_VALUE(payload, '$.ok') = 'true'").result()}
    except Exception:          # table absent until the first load
        return set()


def main():
    args, cfg, dataset, run_id = runner.setup("vendor", [LINES, FILES])
    folder_id = util.env_or("SC_STATEMENT_DRIVE_FOLDER_ID",
                            cfg.env.get("SC_STATEMENT_DRIVE_FOLDER_ID"))
    from ..lib import bq as bq_mod
    bq = bq_mod.client_for(cfg)
    for table in (LINES, FILES):
        bq_mod.ensure_table(bq, cfg, dataset, table, bq_mod.LANDING_SCHEMA)
    if not folder_id:
        log.info("SC_STATEMENT_DRIVE_FOLDER_ID not set for '%s' — nothing to do", cfg.slug)
        return
    session, account = drive_session()
    try:
        files = list_folder(session, folder_id, cfg.project_id, account)
    except DriveSetupError as e:
        raise SystemExit(str(e))
    to_load, skipped = plan(files, loaded_keys(bq, cfg, dataset))
    for name, why in skipped:
        log.info("skip %s: %s", name, why)
    log.info("%d files in folder, %d new statements", len(files), len(to_load))

    failed = []
    for f in to_load:
        info = {"key": file_key(f), "file": f["name"], "file_id": f["id"],
                "modified_at": f.get("modifiedTime")}
        try:
            parsed = statement.parse(download(session, f["id"]))
        except ValueError as e:
            log.error("%s: %s", f["name"], e)
            failed.append(f["name"])
            runner.land(bq_mod, bq, cfg, dataset, FILES,
                        [dict(info, ok=False, problem=str(e))], "key", "modified_at", run_id)
            continue
        rows = records(f, parsed)
        n = runner.land(bq_mod, bq, cfg, dataset, LINES, rows, "id", None, run_id)
        head = parsed["statement"]
        runner.land(bq_mod, bq, cfg, dataset, FILES, [dict(
            info, ok=True, statement_date=head["statement_date"],
            dealer_account=head["account_number"], total_due=head["total_due"],
            totals=head["totals"], lines=n)], "key", "modified_at", run_id)
        log.info("%s: statement %s, %d lines, $%.2f due", f["name"],
                 head["statement_date"], n, head["total_due"])
    if failed:
        raise SystemExit("Security Central statement(s) did not reconcile: "
                         + ", ".join(failed) + f" (see {dataset}.{FILES})")


if __name__ == "__main__":
    main()
