"""QuickBooks Online reports and budgets → raw_qbo. The books, as the books say.

pipelines/qbo/ingest.py lands transactions: invoices, bills, purchases,
payments. Those cannot be summed back into the P&L. Payroll, depreciation,
accruals and the monthly adjustments arrive as journal entries, deposits and
transfers, which are not pulled, and the statements are built by QuickBooks'
own rules for which account each posting reaches. The CFO's monthly package
is QuickBooks' reports verbatim, so this lands QuickBooks' reports verbatim:

  reports       each report as QuickBooks returned it, one record per report
                per run (ProfitAndLoss, BalanceSheet, CashFlow; monthly
                columns). The source of truth the lines below are checked
                against.
  report_lines  the same reports flattened: one record per (report row,
                month), with the row's section path, account id, and whether
                it is an account line or a section total.
  budgets       every Budget record (the P&L budget by account and month).

Reports are not incremental: a closed month can still change (a late bill, a
reclassification at close), so every run pulls the whole window again and
staging reads the newest run. The window starts on 1 January three years
back, which covers the package's four-year performance summary.

Reads the same refresh token as ingest-qbo and writes back a rotated one the
same way. The two must never run at once, or one of them refreshes with a
token the other has already retired: the workflows share one concurrency
group.
"""

import logging
from datetime import date

from ..lib import runner, util
from ..lib.sources import QBO

log = logging.getLogger("flywheel.ingest.qbo_reports")

REPORTS = ("ProfitAndLoss", "BalanceSheet", "CashFlow")
ENTITIES = ["reports", "report_lines", "budgets"]
YEARS_BACK = 3
TOLERANCE = 0.01


def window(today, years_back=YEARS_BACK):
    """(start, end) ISO dates: 1 January `years_back` years ago, to today."""
    return date(today.year - years_back, 1, 1).isoformat(), today.isoformat()


def fetch_report(http, token, realm_id, name, start, end, basis):
    resp = http.get(
        f"{QBO['base_url']}/v3/company/{realm_id}/reports/{name}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        params={"start_date": start, "end_date": end,
                "summarize_column_by": "Month", "accounting_method": basis,
                "minorversion": QBO["minorversion"]},
        timeout=120,
    )
    util.raise_for_status(resp, f"QBO report {name}")
    return resp.json()


def fetch_budgets(http, token, realm_id):
    resp = http.get(
        f"{QBO['base_url']}/v3/company/{realm_id}/query",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        params={"query": "SELECT * FROM Budget", "minorversion": QBO["minorversion"]},
        timeout=60,
    )
    util.raise_for_status(resp, "QBO query Budget")
    return resp.json().get("QueryResponse", {}).get("Budget", [])


def _meta(col, name):
    for m in col.get("MetaData") or []:
        if m.get("Name") == name:
            return m.get("Value")
    return None


def period_columns(report):
    """[(index, start, end)] for the month columns; the label and Total go.

    A column is a period only if QuickBooks gave it both dates. The first
    column is the row label; a Total column carries no dates, and summing it
    alongside the months would count every figure twice.
    """
    cols = (report.get("Columns") or {}).get("Column") or []
    out = []
    for i, col in enumerate(cols):
        start, end = _meta(col, "StartDate"), _meta(col, "EndDate")
        if i > 0 and start and end:
            out.append((i, start, end))
    return out


def _amount(cell):
    value = (cell or {}).get("value")
    if value in (None, ""):
        return None
    try:
        return float(value)
    except ValueError:
        return None


def flatten(report, name, basis):
    """One record per (row, month): the report as rows a table can hold.

    QuickBooks nests rows to any depth: a Section has a Header (its label), a
    Rows list, and a Summary (its total). A parent account with sub-accounts
    is a Section; its own direct postings, when it has any, arrive as a Data
    row inside it. Every Data row lands as line_type 'account' and every
    Summary as 'total', each carrying the path of section labels above it,
    so the P&L can be rebuilt at any level without re-reading the JSON.
    """
    periods = period_columns(report)
    records, seq = [], [0]

    def emit(cells, path, group, line_type, depth):
        label_cell = cells[0] if cells else {}
        seq[0] += 1
        for i, start, end in periods:
            records.append({
                "report": name,
                "basis": basis,
                "period_start": start,
                "period_end": end,
                "row_seq": seq[0],
                "depth": depth,
                "section_path": " > ".join(path),
                "group": group,
                "label": label_cell.get("value"),
                "account_id": label_cell.get("id"),
                "line_type": line_type,
                "amount": _amount(cells[i] if i < len(cells) else None),
            })

    def walk(rows, path, group, depth):
        for row in rows or []:
            rtype = row.get("type")
            if rtype == "Section" or "Rows" in row or "Summary" in row:
                header = (row.get("Header") or {}).get("ColData") or []
                label = header[0].get("value") if header else None
                sub_path = path + [label] if label else path
                sub_group = row.get("group") or group
                # A header with figures of its own is a parent account's
                # direct postings; land it rather than lose it.
                if any(_amount(c) is not None for c in header[1:]):
                    emit(header, path, sub_group, "account", depth)
                walk((row.get("Rows") or {}).get("Row"), sub_path, sub_group, depth + 1)
                summary = (row.get("Summary") or {}).get("ColData")
                if summary:
                    emit(summary, sub_path, sub_group, "total", depth)
            elif row.get("ColData"):
                emit(row["ColData"], path, group, "account", depth)

    walk((report.get("Rows") or {}).get("Row"), [], None, 0)
    return records


def total_mismatches(report):
    """Sections whose rows do not add up to their own Summary, per month.

    The flattening is only trustworthy if, for every section that has rows,
    its account lines plus its sub-sections' totals equal the total QuickBooks
    printed. A section with no rows (Gross Profit, Net Income) is QuickBooks'
    arithmetic across sections and is not checked here.
    """
    periods = period_columns(report)
    bad = []

    def value(cells, i):
        return _amount(cells[i]) if i < len(cells) else None

    def walk(rows, path):
        for row in rows or []:
            children = (row.get("Rows") or {}).get("Row")
            summary = (row.get("Summary") or {}).get("ColData")
            header = (row.get("Header") or {}).get("ColData") or []
            label = header[0].get("value") if header else row.get("group")
            if children:
                walk(children, path + [label])
            if not (children and summary):
                continue
            for i, start, _ in periods:
                parts = [value(header, i) or 0.0]
                for child in children:
                    csum = (child.get("Summary") or {}).get("ColData")
                    cells = csum if csum else child.get("ColData") or []
                    parts.append(value(cells, i) or 0.0)
                printed = value(summary, i) or 0.0
                if abs(sum(parts) - printed) > TOLERANCE:
                    bad.append((" > ".join(path + [label]), start, round(sum(parts), 2), printed))

    walk((report.get("Rows") or {}).get("Row"), [])
    return bad


def main():
    args, cfg, dataset, run_id = runner.setup("qbo", ENTITIES)
    from ..lib import bq as bq_mod
    from ..lib import secret_store, web
    from .ingest import get_access_token

    basis = util.env_or("QBO_REPORTS_BASIS", "Accrual")
    start, end = window(date.today())
    http = web.session()
    token = get_access_token(http, cfg.project_id)
    realm_id = secret_store.get(cfg.project_id, "flywheel-qbo-realm-id")
    bq = bq_mod.client_for(cfg)

    raw, lines = [], []
    for name in REPORTS:
        report = fetch_report(http, token, realm_id, name, start, end, basis)
        bad = total_mismatches(report)
        for path, month, summed, printed in bad[:20]:
            log.warning("%s: %s %s rows sum to %s, report prints %s",
                        name, path, month, summed, printed)
        if bad:
            log.warning("%s: %d section-months do not add up; landed anyway, "
                        "staging must not trust this report's lines", name, len(bad))
        raw.append({"report": name, "basis": basis, "start_date": start,
                    "end_date": end, "mismatches": len(bad), "body": report})
        flat = flatten(report, name, basis)
        log.info("%s: %d columns, %d lines", name, len(period_columns(report)), len(flat))
        lines.extend(flat)

    total = runner.land(bq_mod, bq, cfg, dataset, "reports", raw, "report", None, run_id)
    total += runner.land(bq_mod, bq, cfg, dataset, "report_lines", lines, None, None, run_id)
    total += runner.land(bq_mod, bq, cfg, dataset, "budgets", fetch_budgets(http, token, realm_id),
                         QBO["id_field"], None, run_id)
    log.info("done: %d rows total (%s to %s, %s)", total, start, end, basis)


if __name__ == "__main__":
    main()
