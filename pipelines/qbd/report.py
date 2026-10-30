"""Parse QuickBooks Desktop report exports. Standard library only.

QuickBooks Desktop was Livewire's books from 2003 to March 2022, and the
subscription is being cancelled. A .QBW can only be opened by QuickBooks
itself, so the history leaves as a one-time export: about two hundred CSV
reports and an IIF list file, saved to a Drive folder under names like

    qbd_general-ledger_accrual_2015-01-01_2015-12-31.csv
    qbd_trial-balance_2015-12-31.csv
    qbd_profit-and-loss_accrual_by-year_2003_2023.csv
    qbd_customer-contact-list.csv

The file name is the only place the report, basis and period are recorded,
so it is parsed here and carried onto every row.

The reports are laid out for a reader, not a loader, in three shapes:

  sectioned   a blank first column header, then section rows ("Livewire
              Checking"), the detail rows under them (first cell empty), and
              a "Total Livewire Checking" row closing each section. General
              Ledger, Transaction Detail by Account, Sales by Customer
              Detail, the aging reports, the list exports.
  columnar    the same section rows, but every column is a period or an
              employee (P&L and Balance Sheet by year, Trial Balance,
              payroll), sometimes under two header rows.
  flat        a named first column and one row per posting line (Journal,
              Check Detail, Deposit Detail), with blank separator rows.

All three land the same way: one record per non-blank row, with the cells
keyed by header, the row's section path, and whether it is a section, a
total, or data. Nothing is summed or dropped here; staging decides what a
row means.

THE ROW CAP. QuickBooks Desktop stops a CSV export at 32,768 rows without a
word: the 2015 General Ledger came out at exactly 32,769 lines (the header
plus 32,768) with no closing TOTAL row. It is sorted by account, so it stops
partway through the income accounts and every account after them is absent.
`truncated` flags that, and a truncated file must be exported again in
smaller date ranges while QuickBooks can still open the company file.
"""

import csv
import io
import re

# The QuickBooks CSV export cap: header + 32,768 rows.
ROW_CAP = 32768

NAME_RE = re.compile(
    r"^qbd_(?P<report>[a-z0-9]+(?:[-_][a-z0-9]+)*?)"
    r"(?:_(?P<basis>accrual|cash))?"
    r"(?:_by-year_(?P<y0>\d{4})_(?P<y1>\d{4})"
    r"|_(?P<start>\d{4}-\d{2}-\d{2})_(?P<end>\d{4}-\d{2}-\d{2})"
    r"|_(?P<asof>\d{4}-\d{2}-\d{2}))?"
    r"\.(?:csv|iif)(?:\.csv)?$",
    re.IGNORECASE,
)

# Exports that are not reports: the backup, the portable copy, the company
# file itself, screenshots. They stay in the folder as the archive and are
# never downloaded.
LOADABLE = (".csv", ".iif")


def describe(name):
    """What a file name says: report, basis, period. None if not a qbd_ export.

    >>> describe("qbd_trial-balance_2015-12-31.csv")["report"]
    'trial-balance'
    """
    m = NAME_RE.match(name.strip())
    if not m:
        return None
    d = m.groupdict()
    start, end, asof = d["start"], d["end"], d["asof"]
    if d["y0"]:
        start, end = f"{d['y0']}-01-01", f"{d['y1']}-12-31"
    return {
        "report": d["report"].lower(),
        "basis": (d["basis"] or "").lower() or None,
        "period_start": start,
        "period_end": end,
        "as_of": asof,
        "format": "iif" if name.lower().endswith(".iif") else "csv",
    }


def table_name(report):
    """'general-ledger' -> 'qbd_general_ledger' (raw_vendor landing table)."""
    return "qbd_" + re.sub(r"[^a-z0-9]+", "_", report.lower()).strip("_")


def _decode(data):
    # QuickBooks writes Windows-1252; a later save in Excel may make it UTF-8
    # with a BOM. Either way every byte must land, so never fail on one.
    for enc in ("utf-8-sig", "cp1252"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("latin-1")


def _blank(row):
    return not any(c.strip() for c in row)


def _headers(header_rows, width):
    """Column names from one or two header rows.

    A Trial Balance heads its columns "Dec 31, 03" over "Debit"/"Credit", and
    the payroll summary puts each employee's name over Hours/Rate/Amount, the
    name written once and the cells after it left empty. The upper row is
    carried right across those empty cells and joined to the lower one, so
    each column gets a name of its own ("Dec 31, 03 | Debit").
    """
    names = []
    for i in range(width):
        parts = []
        for hr in header_rows:
            cell = hr[i].strip() if i < len(hr) else ""
            if hr is not header_rows[-1] and not cell:
                # carry the upper row's label rightwards over its blanks
                cell = next((hr[j].strip() for j in range(i, -1, -1)
                                 if j < len(hr) and hr[j].strip()), "")
            if cell:
                parts.append(cell)
        names.append(" | ".join(parts) or f"col{i}")
    seen, out = {}, []
    for n in names:
        seen[n] = seen.get(n, 0) + 1
        out.append(n if seen[n] == 1 else f"{n} ({seen[n]})")
    return out


def parse_csv(data):
    """(records, info) for one exported report.

    records: one dict per non-blank row after the header —
        row      1-based line number in the file (stable, so a re-load of the
                 same file produces the same ids)
        kind     section | total | grand_total | data
        label    the first column when the report has a label column
        section  the enclosing section names, outermost first
        cells    {column name: cell text} for the non-empty cells
    info: {"rows": data rows, "lines": lines in the file, "has_total": bool,
           "truncated": bool}
    """
    rows = list(csv.reader(io.StringIO(_decode(data))))
    lines = len(rows)
    if not rows:
        return [], {"rows": 0, "lines": 0, "has_total": False, "truncated": False}

    width = max(len(r) for r in rows)
    labelled = not rows[0][0].strip()   # sectioned/columnar: blank first header
    header_rows = [rows[0]]
    body_start = 1
    # A second header row: first cell blank, at least one named cell, before
    # any section or data row (Trial Balance's Debit/Credit, payroll's
    # Hours/Rate under each employee).
    if (labelled and len(rows) > 1 and not rows[1][0].strip()
            and any(c.strip() for c in rows[1])
            and not any(_is_number(c) for c in rows[1][1:])):
        header_rows.append(rows[1])
        body_start = 2
    names = _headers(header_rows, width)

    records, stack, has_total = [], [], False
    for i, row in enumerate(rows[body_start:], start=body_start + 1):
        if _blank(row):
            continue
        first = row[0].strip()
        rest_blank = _blank(row[1:])
        cells = {names[j]: c.strip() for j, c in enumerate(row)
                 if c.strip() and (j > 0 or not labelled)}
        if first == "TOTAL":
            kind = "grand_total"
            has_total = True
        elif labelled and first.startswith("Total "):
            kind = "total"
        elif labelled and first and _is_section(row):
            kind = "section"
        else:
            kind = "data"

        if kind == "total":
            closing = first[len("Total "):]
            # pop to the section this total closes; QuickBooks lower-cases
            # some names in totals ("Total no accnt"), so compare folded.
            folded = [s.casefold() for s in stack]
            if closing.casefold() in folded:
                del stack[folded.index(closing.casefold()):]
        section = list(stack)
        if kind == "section":
            stack.append(first)

        rec = {"row": i, "kind": kind, "section": section, "cells": cells}
        if labelled:
            rec["label"] = first or None
        records.append(rec)

    data_rows = lines - 1          # everything after the first header line
    info = {
        "rows": sum(1 for r in records if r["kind"] == "data"),
        "lines": lines,
        "has_total": has_total,
        # At the cap with no closing TOTAL is certain. At the cap exactly is
        # enough on its own: some reports (Deposit Detail) print a TOTAL per
        # group, so the last line can look closed when the export was not.
        "truncated": data_rows >= ROW_CAP,
    }
    return records, info


def _is_number(cell):
    return bool(re.fullmatch(r"-?[\d,]*\.?\d+%?", cell.strip()))


def _is_section(row):
    """A label with nothing after it but blanks and an opening balance.

    General Ledger opens each account with its name and, in the last column
    only, the balance brought forward ("Livewire Checking",,,,,,,,,0.00).
    Columnar reports open a section with the label and empty-string cells.
    A label followed by real values is an account line, not a section.
    """
    rest = [c.strip() for c in row[1:]]
    filled = [c for c in rest if c]
    return not filled or (len(filled) == 1 and rest[-1] == filled[0]
                          and _is_number(filled[0]) and len(rest) > 2)


def parse_iif(data):
    """(records, info) for an IIF list export.

    Tab-separated; a line starting with "!" names the columns for the record
    type that follows ("!ACCNT\tNAME\tACCNTTYPE…"), and each data line starts
    with that type ("ACCNT\tLivewire Checking\tBANK…").
    """
    headers, records = {}, []
    for i, line in enumerate(_decode(data).splitlines(), start=1):
        if not line.strip():
            continue
        parts = line.split("\t")
        tag = parts[0].strip()
        if tag.startswith("!"):
            headers[tag[1:]] = [p.strip() for p in parts]
            continue
        cols = headers.get(tag)
        cells = {}
        for j, value in enumerate(parts[1:], start=1):
            if value.strip():
                key = cols[j] if cols and j < len(cols) and cols[j] else f"col{j}"
                cells[key] = value.strip()
        records.append({"row": i, "kind": "data", "list": tag, "cells": cells})
    return records, {"rows": len(records), "lines": i if records else 0,
                     "has_total": True, "truncated": False}


def parse(data, name):
    if name.lower().endswith(".iif"):
        return parse_iif(data)
    return parse_csv(data)


# ── Trial balance ↔ general ledger ──────────────────────────────────────────

def amount(cell):
    """'1,819.00' -> 1819.0; '' or missing -> 0.0; '(12.00)' -> -12.0."""
    if cell is None:
        return 0.0
    s = cell.replace(",", "").replace("$", "").strip()
    if not s:
        return 0.0
    if s.startswith("(") and s.endswith(")"):
        s = "-" + s[1:-1]
    return float(s)


def trial_balance(records):
    """{full account name: debit - credit} from a parsed Trial Balance."""
    out = {}
    for r in records:
        if r["kind"] != "data" or not r.get("label"):
            continue
        cells = list(r["cells"].items())
        debit = next((v for k, v in cells if k.endswith("Debit")), "")
        credit = next((v for k, v in cells if k.endswith("Credit")), "")
        out[r["label"]] = round(amount(debit) - amount(credit), 2)
    return out


def ledger_totals(records):
    """{full account name: ending balance} from a parsed General Ledger.

    Each account's "Total …" row carries its ending balance in the Balance
    column, including its subaccounts'. The name is the section path joined
    the way QuickBooks writes a full name ("Parent:Child").
    """
    out = {}
    for r in records:
        if r["kind"] != "total":
            continue
        name = ":".join(r["section"] + [r["label"][len("Total "):]])
        # match the case of the section QuickBooks opened, not the total line
        out[name.casefold()] = round(amount(r["cells"].get("Balance")), 2)
    return out


def reconcile(tb_records, gl_records, tolerance=0.01):
    """Accounts whose General Ledger ending balance differs from the Trial Balance.

    Compares at every account, rolled up: an account's Trial Balance figure
    plus all its subaccounts' against the General Ledger's total for it. A
    General Ledger that was cut off by the row cap never reaches most of its
    totals, so every account after the cut shows here as missing.

    Returns a list of (account, trial_balance, general_ledger) — empty when
    the two agree everywhere.
    """
    tb = trial_balance(tb_records)
    gl = ledger_totals(gl_records)
    rolled = {}
    for name, value in tb.items():
        parts = name.split(":")
        for k in range(1, len(parts) + 1):
            key = ":".join(parts[:k]).casefold()
            rolled[key] = rolled.get(key, 0.0) + value
    diffs = []
    for key, value in sorted(rolled.items()):
        ledger = gl.get(key)
        if ledger is None:
            if abs(value) > tolerance:
                diffs.append((key, round(value, 2), None))
            continue
        if abs(ledger - value) > tolerance:
            diffs.append((key, round(value, 2), ledger))
    return diffs
