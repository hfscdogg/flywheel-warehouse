"""QuickBooks Desktop export (a Drive folder) → raw_vendor.qbd_* landing tables.

Livewire kept its books in QuickBooks Desktop from 2003 to March 2022 and the
subscription is being cancelled. The history was exported once, by hand, to
a Google Drive folder (report.py describes the files). This lands every
report in it and checks the exports are complete before anyone relies on
them — which matters most while QuickBooks can still open the company file,
because a report that came out wrong can only be run again until then.

Why raw_vendor. These are files a person exported and dropped in a folder,
the same as the monitoring vendors' reports, and ingest-vendor is the
account that lands such files. Giving them a raw_qbd of their own would
need a new account, its trust binding and its grants, all owner-run setup,
for a load that happens once. Every table is prefixed qbd_ so nothing here
is mistaken for a vendor's roster.

Access. The folder is shared, Viewer, with the ingest-vendor service
account, which reads it through the Drive API with a read-only scope. The
account can read only what is shared with it.

Each run lists the folder and loads only files it has not loaded before (by
Drive file id and content checksum), so a nightly run is a listing and
nothing else, and a file uploaded late — or exported again — loads on the
next run. Landing tables are append-only, like every landing table; a row's
_source_id is "<file id>:<line>", and staging picks the newest file per name.

What fails the run (after everything else has loaded, so one bad file never
holds back the rest):
  - a report QuickBooks cut off at its CSV row cap (report.ROW_CAP); it must
    be exported again in smaller date ranges;
  - a year whose General Ledger does not tie to its Trial Balance, or whose
    General Ledger files do not cover the whole year. Re-exported pieces of a
    year (2015-01-01_2015-06-30 + 2015-07-01_2015-12-31) are checked as one.
Each check is recorded in qbd_checks either way, so whether the export is
complete is a query, not a log search.

Env / client.env:
  QBD_DRIVE_FOLDER_ID   the Drive folder; unset means nothing to do.
  QBD_MAX_MB            files larger than this are skipped. Default 50: the
                        largest report is about 12 MB, and the backup and
                        portable company file are never downloaded at all.
"""

import logging
from datetime import date, timedelta

from ..lib import runner, util
from . import report

log = logging.getLogger("flywheel.ingest.qbd")

DRIVE = "https://www.googleapis.com/drive/v3/files"
SCOPES = ["https://www.googleapis.com/auth/drive.readonly"]
FILES_TABLE = "qbd_files"
CHECKS_TABLE = "qbd_checks"
DEFAULT_MAX_MB = 50


class DriveSetupError(RuntimeError):
    """The folder cannot be read yet, with the sentence that says what to do."""


def drive_session():
    import google.auth
    from google.auth.transport.requests import AuthorizedSession
    creds, _ = google.auth.default(scopes=SCOPES)
    return AuthorizedSession(creds), getattr(creds, "service_account_email", None)


def explain(resp, folder_id, project_id, account):
    """Turn a Drive refusal into the one thing to do about it, or None."""
    try:
        body = resp.json().get("error", {})
    except ValueError:
        body = {}
    reasons = {e.get("reason") for e in body.get("errors", [])}
    message = body.get("message", "")
    if resp.status_code == 403 and ("accessNotConfigured" in reasons
                                    or "SERVICE_DISABLED" in message
                                    or "has not been used" in message):
        return ("The Google Drive API is turned off in this project. Turn it on "
                "(one button), then re-run: https://console.cloud.google.com/"
                f"apis/library/drive.googleapis.com?project={project_id}")
    if resp.status_code == 404:
        who = account or f"ingest-vendor@{project_id}.iam.gserviceaccount.com"
        return (f"Drive folder {folder_id} is not visible to {who}. Share the "
                "folder with that address as Viewer, then re-run.")
    return None


def list_folder(session, folder_id, project_id, account):
    """Every file directly in the folder: id, name, size, md5, modifiedTime."""
    meta = session.get(f"{DRIVE}/{folder_id}",
                       params={"fields": "id,name", "supportsAllDrives": "true"})
    if meta.status_code >= 400:
        hint = explain(meta, folder_id, project_id, account)
        if hint:
            raise DriveSetupError(hint)
        util.raise_for_status(meta, "drive folder")
    files, token = [], None
    while True:
        params = {
            "q": f"'{folder_id}' in parents and trashed = false",
            "fields": "nextPageToken,files(id,name,mimeType,size,md5Checksum,modifiedTime)",
            "pageSize": "1000",
            "supportsAllDrives": "true",
            "includeItemsFromAllDrives": "true",
        }
        if token:
            params["pageToken"] = token
        resp = util.raise_for_status(session.get(DRIVE, params=params), "drive list")
        page = resp.json()
        files.extend(page.get("files", []))
        token = page.get("nextPageToken")
        if not token:
            return files


def download(session, file_id):
    resp = session.get(f"{DRIVE}/{file_id}",
                       params={"alt": "media", "supportsAllDrives": "true"})
    return util.raise_for_status(resp, f"drive download {file_id}").content


def file_key(f):
    """A file and its content: a re-uploaded or edited file loads again."""
    return f"{f['id']}:{f.get('md5Checksum') or f.get('modifiedTime')}"


def plan(files, loaded, max_bytes):
    """Split a folder listing into (to_load, skipped). Pure, for the tests.

    skipped is [(name, reason)]: not a qbd_ report name, not a report format
    (the .qbb backup, the .qbm portable copy, the tracker sheet), or too big.
    """
    to_load, skipped = [], []
    for f in sorted(files, key=lambda f: f["name"]):
        name = f["name"]
        if not name.lower().endswith(report.LOADABLE):
            skipped.append((name, "archive only, not a report export"))
            continue
        desc = report.describe(name)
        if desc is None:
            skipped.append((name, "name is not qbd_<report>[_<basis>][_<period>]"))
            continue
        size = int(f.get("size") or 0)
        if size > max_bytes:
            skipped.append((name, f"{size / 1048576:.1f} MB, over the size cap"))
            continue
        if file_key(f) in loaded:
            continue
        to_load.append(dict(f, **desc))
    return to_load, skipped


# ── Year checks ─────────────────────────────────────────────────────────────

def _d(s):
    return date.fromisoformat(s)


def check_year(year, tbs, gls):
    """Is year Y's ledger complete? tbs/gls: [(file, records, info)].

    Complete means: a Trial Balance as of 31 December; General Ledger files,
    none cut off, that together cover 1 January to 31 December without a
    gap; and the one ending 31 December agreeing with the Trial Balance at
    every account. QuickBooks prints each account's balance as of the end of
    a General Ledger's range, so the piece that ends on 31 December carries
    the year-end figures however the year was split.
    """
    result = {"year": year, "ok": False, "problems": [], "differences": []}
    tb = next((t for t in tbs if t[0].get("as_of") == f"{year}-12-31"), None)
    if tb is None:
        result["problems"].append(f"no Trial Balance as of {year}-12-31")
    whole = [g for g in gls if not g[2]["truncated"]]
    cut = [g[0]["name"] for g in gls if g[2]["truncated"]]
    covered = date(year, 1, 1)
    for g in sorted(whole, key=lambda g: g[0]["period_start"]):
        if _d(g[0]["period_start"]) <= covered <= _d(g[0]["period_end"]) + timedelta(days=1):
            covered = max(covered, _d(g[0]["period_end"]) + timedelta(days=1))
    if covered <= date(year, 12, 31):
        gap = f"General Ledger covers {year}-01-01 to {covered - timedelta(days=1)} only"
        if covered == date(year, 1, 1):
            gap = f"no complete General Ledger for {year}"
        if cut:
            gap += f" ({', '.join(cut)} cut off at the {report.ROW_CAP:,}-row cap)"
        result["problems"].append(gap)
    year_end = next((g for g in whole if g[0]["period_end"] == f"{year}-12-31"), None)
    if tb is not None and year_end is not None:
        diffs = report.reconcile(tb[1], year_end[1])
        result["differences"] = [
            {"account": a, "trial_balance": t, "general_ledger": g} for a, t, g in diffs]
        if diffs:
            result["problems"].append(
                f"{len(diffs)} account(s) differ between the {year} General Ledger "
                "and Trial Balance")
    result["ok"] = not result["problems"]
    result["files"] = sorted(x[0]["name"] for x in (tbs + gls))
    return result


def years_of(f):
    """The calendar years a General Ledger or Trial Balance file speaks to."""
    if f["report"] == "trial-balance" and f.get("as_of"):
        return {int(f["as_of"][:4])}
    if f["report"] == "general-ledger" and f.get("period_start"):
        return set(range(int(f["period_start"][:4]), int(f["period_end"][:4]) + 1))
    return set()


# ── Run ─────────────────────────────────────────────────────────────────────

def loaded_keys(bq, cfg, dataset):
    """file_key of every file already landed (empty on the first run)."""
    sql = (f"SELECT DISTINCT _source_id FROM `{cfg.project_id}.{dataset}.{FILES_TABLE}`")
    try:
        return {row[0] for row in bq.query(sql).result()}
    except Exception:          # table absent until the first load
        return set()


def failing_years(bq, cfg, dataset):
    """Years whose most recent check did not pass (empty before any check).

    Re-checked on every run, not only when a new file for the year arrives:
    a fix to the parser, or a re-exported piece of another year's ledger,
    must clear a failure without anyone re-uploading the year's files.
    """
    sql = f"""
        SELECT CAST(JSON_VALUE(payload, '$.year') AS INT64) AS year
        FROM `{cfg.project_id}.{dataset}.{CHECKS_TABLE}`
        QUALIFY ROW_NUMBER() OVER (PARTITION BY JSON_VALUE(payload, '$.year')
                                   ORDER BY _loaded_at DESC) = 1
          AND JSON_VALUE(payload, '$.ok') != 'true'
    """
    try:
        return {row[0] for row in bq.query(sql).result()}
    except Exception:          # table absent until the first check
        return set()


def main():
    args, cfg, dataset, run_id = runner.setup("vendor", [FILES_TABLE, CHECKS_TABLE])
    folder_id = util.env_or("QBD_DRIVE_FOLDER_ID", cfg.env.get("QBD_DRIVE_FOLDER_ID"))
    if not folder_id:
        log.info("QBD_DRIVE_FOLDER_ID not set for '%s' — nothing to do", cfg.slug)
        return
    max_bytes = int(util.env_or("QBD_MAX_MB", str(DEFAULT_MAX_MB))) * 1048576

    from ..lib import bq as bq_mod
    bq = bq_mod.client_for(cfg)
    session, account = drive_session()
    try:
        files = list_folder(session, folder_id, cfg.project_id, account)
    except DriveSetupError as e:
        raise SystemExit(str(e))
    to_load, skipped = plan(files, loaded_keys(bq, cfg, dataset), max_bytes)
    for name, why in skipped:
        log.info("skip %s: %s", name, why)
    log.info("%d files in folder, %d new to load", len(files), len(to_load))

    by_name = {f["name"]: f for f in files}
    parsed = {}            # name -> (file, records, info), this run only
    cut, total = [], 0
    for f in to_load:
        data = download(session, f["id"])
        records, info = report.parse(data, f["name"])
        if years_of(f):
            # kept for the year checks below; every other report is landed
            # and let go, so the run holds one large file at a time
            parsed[f["name"]] = (f, records, info)
        common = {k: f.get(k) for k in ("report", "basis", "period_start",
                                        "period_end", "as_of")}
        common.update(file=f["name"], file_id=f["id"])
        rows = [dict(r, **common, id=f"{f['id']}:{r['row']}") for r in records]
        n = runner.land(bq_mod, bq, cfg, dataset, report.table_name(f["report"]),
                        rows, "id", None, run_id) if rows else 0
        runner.land(bq_mod, bq, cfg, dataset, FILES_TABLE, [{
            "key": file_key(f), **common, "bytes": int(f.get("size") or 0),
            "md5": f.get("md5Checksum"), "modified_at": f.get("modifiedTime"),
            "rows_landed": n, **info,
        }], "key", "modified_at", run_id)
        total += n
        if info["truncated"]:
            cut.append(f["name"])
            log.error("%s: CUT OFF at %d lines (QuickBooks' %d-row CSV cap) — "
                      "export it again in smaller date ranges",
                      f["name"], info["lines"], report.ROW_CAP)
        else:
            log.info("%s: %d rows → %s", f["name"], n, report.table_name(f["report"]))

    # Re-check every year a newly loaded GL or TB speaks to, and every year
    # still failing, with all of that year's files, fetching any loaded on
    # an earlier run.
    years = sorted({y for f in to_load for y in years_of(f)}
                   | failing_years(bq, cfg, dataset))
    checks, failed = [], []
    for year in years:
        tbs, gls = [], []
        for name, f in by_name.items():
            desc = report.describe(name)
            if not desc or desc["report"] not in ("trial-balance", "general-ledger"):
                continue
            f = dict(f, **desc)
            if year not in years_of(f):
                continue
            if name not in parsed:
                records, info = report.parse(download(session, f["id"]), name)
                parsed[name] = (f, records, info)
            (tbs if desc["report"] == "trial-balance" else gls).append(parsed[name])
        result = check_year(year, tbs, gls)
        result["key"] = f"{year}:{run_id}"
        checks.append(result)
        if result["ok"]:
            log.info("%d: General Ledger ties to Trial Balance at every account", year)
        else:
            failed.append(year)
            for p in result["problems"]:
                log.error("%d: %s", year, p)
    if checks:
        runner.land(bq_mod, bq, cfg, dataset, CHECKS_TABLE, checks, "key", None, run_id)

    log.info("done: %d files, %d rows", len(to_load), total)
    problems = []
    if cut:
        problems.append(f"{len(cut)} export(s) cut off at the row cap: {', '.join(cut)}")
    if failed:
        problems.append(f"ledger incomplete for {', '.join(map(str, failed))} "
                        f"(see {dataset}.{CHECKS_TABLE})")
    if problems:
        raise SystemExit("QuickBooks Desktop export is not complete — "
                         + "; ".join(problems))


if __name__ == "__main__":
    main()
