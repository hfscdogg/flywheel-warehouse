"""Google Sheets kept by the client's people → raw_vendor.gsheet_* landing tables.

Livewire's month-end close lives partly in two hand-kept workbooks, one tab
per month (workbook.py says what each holds): the inventory deferred out of
each month's P&L, and the security-monitoring discounts deferred and
amortized over their agreements. They explain the adjusting entries the
QuickBooks P&L shows but cannot account for.

How it reads them. Each sheet is shared, Viewer, with the ingest-vendor
service account, which already reads the QuickBooks Desktop folder through
the Drive API with a read-only scope (pipelines/qbd/ingest.py). The Drive
API exports a whole workbook as one .xlsx, every tab included, so no second
API (Sheets) needs turning on and no second credential exists.

What lands, per changed workbook:
  gsheet_rows               every non-empty row of every tab, as typed
  gsheet_inventory_lines    Inventory Adjustments, one row per deferred job
  gsheet_inventory_checks   each table's own Total against the lines under it
  gsheet_security_deferred  Security Discounts' Monthly Deferred schedule
  gsheet_files              one row per workbook version landed

A workbook loads again only when Drive's version number for it changes, and
every row of that version lands under it; staging reads the newest version
per workbook. Each table still records a run every night, changed or not,
so the freshness check sees an ingest that ran over a sheet nobody edited
as current, and one that stopped running as stale.

A total that does not tie is recorded, not raised: these are people's
spreadsheets, and a SUM that misses an inserted row is the sheet's to fix.
gsheet_inventory_checks says which tab, table and amount.

Env / client.env:
  GSHEETS   "<name>=<spreadsheet id> ...". The name picks the shaping
            (inventory_adjustments, security_discounts); any other name is
            landed as rows only. Unset means nothing to do.
"""

import logging

from ..lib import runner, util
from ..qbd.ingest import DRIVE, drive_session
from . import workbook

log = logging.getLogger("flywheel.ingest.gsheets")

XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
FILES = "gsheet_files"
ROWS = "gsheet_rows"
INVENTORY_LINES = "gsheet_inventory_lines"
INVENTORY_CHECKS = "gsheet_inventory_checks"
SECURITY_DEFERRED = "gsheet_security_deferred"
TABLES = [FILES, ROWS, INVENTORY_LINES, INVENTORY_CHECKS, SECURITY_DEFERRED]
# The tables only one sheet fills: when that sheet cannot be read they record
# no run, so the freshness check reports them, and only them, as stale.
OWNED = {
    "inventory_adjustments": (INVENTORY_LINES, INVENTORY_CHECKS),
    "security_discounts": (SECURITY_DEFERRED,),
}


def parse_config(spec):
    """'a=ID b=ID2' -> {'a': 'ID', 'b': 'ID2'}. Raises on a malformed entry."""
    out = {}
    for part in (spec or "").split():
        name, sep, file_id = part.partition("=")
        if not sep or not name or not file_id:
            raise SystemExit(f"GSHEETS entry '{part}' is not <name>=<spreadsheet id>")
        out[name] = file_id
    return out


def shape(name, tabs):
    """{table: records} for one workbook, by its configured name."""
    out = {ROWS: workbook.rows(name, tabs)}
    if name == "inventory_adjustments":
        out[INVENTORY_LINES], out[INVENTORY_CHECKS] = workbook.inventory(tabs, name)
    elif name == "security_discounts":
        out[SECURITY_DEFERRED] = workbook.monthly_deferred(tabs, name)
    return out


class SheetError(RuntimeError):
    """One sheet cannot be read, with the sentence that says what to do."""


def file_meta(session, name, file_id, account, project_id):
    resp = session.get(f"{DRIVE}/{file_id}", params={
        "fields": "id,name,version,modifiedTime,mimeType", "supportsAllDrives": "true"})
    if resp.status_code == 404:
        who = account or f"ingest-vendor@{project_id}.iam.gserviceaccount.com"
        raise SheetError(f"{name}: spreadsheet {file_id} is not visible to {who}. "
                         "Share the sheet with that address as Viewer, then re-run.")
    return util.raise_for_status(resp, f"drive file {name}").json()


def export_xlsx(session, name, file_id):
    resp = session.get(f"{DRIVE}/{file_id}/export", params={"mimeType": XLSX})
    if resp.status_code == 403 and "exportSizeLimitExceeded" in resp.text:
        raise SheetError(f"{name}: too large for Drive's 10 MB export limit")
    return util.raise_for_status(resp, f"drive export {name}").content


def loaded_versions(bq, cfg, dataset):
    """'<file id>:<version>' of every workbook version already landed."""
    try:
        return {r[0] for r in bq.query(
            f"SELECT DISTINCT _source_id FROM `{cfg.project_id}.{dataset}.{FILES}`").result()}
    except Exception:          # table absent until the first load
        return set()


def main():
    args, cfg, dataset, run_id = runner.setup("vendor", TABLES)
    sheets = parse_config(util.env_or("GSHEETS", cfg.env.get("GSHEETS")))
    if not sheets:
        log.info("GSHEETS not set for '%s' — nothing to do", cfg.slug)
        return

    from ..lib import bq as bq_mod
    bq = bq_mod.client_for(cfg)
    # The tables exist from the first run, read or not: the staging models
    # and the freshness check name them, and a missing table would fail the
    # whole transform instead of reporting one stale sheet.
    for table in TABLES:
        bq_mod.ensure_table(bq, cfg, dataset, table, bq_mod.LANDING_SCHEMA)
    session, account = drive_session()
    done = loaded_versions(bq, cfg, dataset)
    batches = {t: [] for t in TABLES}
    unread, unread_names = [], []
    for name, file_id in sheets.items():
        try:
            meta = file_meta(session, name, file_id, account, cfg.project_id)
        except SheetError as e:
            log.error("%s", e)
            unread.append(str(e))
            unread_names.append(name)
            continue
        key = f"{file_id}:{meta['version']}"
        if key in done and not args.full_refresh:
            log.info("%s: unchanged since version %s", name, meta["version"])
            continue
        try:
            tabs = workbook.read_workbook(export_xlsx(session, name, file_id))
        except SheetError as e:
            log.error("%s", e)
            unread.append(str(e))
            unread_names.append(name)
            continue
        common = {"file_id": file_id, "version": meta["version"],
                  "modified_at": meta.get("modifiedTime")}
        counts = {}
        for table, records in shape(name, tabs).items():
            batches[table].extend(dict(r, **common, source_id=f"{key}:{r['id']}")
                                  for r in records)
            counts[table] = len(records)
        bad = [c for c in batches[INVENTORY_CHECKS]
               if c["file_id"] == file_id and not c["ok"]]
        for c in bad:
            log.warning("%s / %s / %s: sheet total %s, lines read %s (difference %s)",
                        name, c["tab"], c["section"] or "first table",
                        c["sheet_total"], c["lines_total"], c["difference"])
        batches[FILES].append(dict(common, source_id=key, workbook=name,
                                   title=meta.get("name"), tabs=len(tabs),
                                   counts=counts, totals_not_tied=len(bad)))
        log.info("%s: version %s, %d tabs, %s", name, meta["version"], len(tabs),
                 ", ".join(f"{t} {n}" for t, n in counts.items()))

    # Files last: a run that dies part-way leaves the version unrecorded, so
    # the next run loads it again whole. A run that could not read a sheet
    # records no run, so the freshness check sees it go stale.
    stale = {t for name in unread_names for t in OWNED.get(name, ())}
    for table in [t for t in TABLES if t != FILES] + [FILES]:
        if table in stale or (unread and table in (ROWS, FILES) and not batches[table]):
            continue
        runner.land(bq_mod, bq, cfg, dataset, table, batches[table],
                    "source_id", "modified_at", run_id)
    if unread:
        raise SystemExit("Google Sheets not read: " + " ".join(unread))


if __name__ == "__main__":
    main()
