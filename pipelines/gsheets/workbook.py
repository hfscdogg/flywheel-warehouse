"""Read a Google Sheet's .xlsx export, and shape Livewire's two close sheets.

Pure functions, bytes in and records out, so the tests run on fixtures and
nothing here touches the network.

Two workbooks, both kept by hand one tab per month (ingest.py says how they
arrive):

  inventory_adjustments  "Inventory Adjustments Monthly": what was sold
      (merchandise, parts) but not yet billed at month end, and so deferred
      out of that month's P&L. One table per section (MERCH, PARTS, ...) with
      a "Total" row under it.
  security_discounts     "Security Discounts (deferred)": the monitoring-
      agreement discounts given each month, deferred and amortized over the
      agreement's 36 or 60 months. The month tabs are pasted QuickBooks
      reports in three different layouts over the years; the "Monthly
      Deferred" tab is the schedule the journal entries are booked from, and
      is what gets shaped here. The discount invoice lines themselves are in
      QuickBooks Online (stg_qbo__invoice_lines).

Every non-empty row of every tab is also landed as-is (rows()), so a tab
this module does not shape is still in the warehouse to read.

An .xlsx stores values, not what the sheet displays: "$1,822.35" is 1822.35,
"37%" is 0.37, and a date is a day count from 1899-12-30. num() and month()
read either form, because hand-typed cells arrive as text.
"""

import io
import re
import zipfile
import xml.etree.ElementTree as ET
from datetime import date, timedelta

NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
REL = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
PKG_REL = "{http://schemas.openxmlformats.org/package/2006/relationships}"

MONTHS = {m: i + 1 for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}
EXCEL_EPOCH = date(1899, 12, 30)


# ── Workbook ────────────────────────────────────────────────────────────────

def _col_index(ref):
    """'BC7' -> 54 (zero-based column index)."""
    m = re.match(r"[A-Z]+", ref or "")
    if not m:
        return None
    idx = 0
    for ch in m.group(0):
        idx = idx * 26 + (ord(ch) - 64)
    return idx - 1


def read_workbook(data):
    """[(tab_name, [(row_number, cells)])] for every tab, in tab order.

    cells is a list of strings (None where empty), trailing empties dropped.
    Rows with nothing in them are left out; row_number is the sheet's own
    1-based row, so a landed row can be found in the sheet.
    """
    tabs = []
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = set(z.namelist())
        shared = []
        if "xl/sharedStrings.xml" in names:
            for si in ET.fromstring(z.read("xl/sharedStrings.xml")):
                shared.append("".join(t.text or "" for t in si.iter(f"{NS}t")))
        targets = {}
        for rel in ET.fromstring(z.read("xl/_rels/workbook.xml.rels")).iter(f"{PKG_REL}Relationship"):
            target = rel.get("Target").lstrip("/")
            targets[rel.get("Id")] = target if target.startswith("xl/") else f"xl/{target}"
        book = ET.fromstring(z.read("xl/workbook.xml"))
        for sheet in book.iter(f"{NS}sheet"):
            path = targets.get(sheet.get(f"{REL}id"))
            if path not in names:
                continue
            rows = []
            for row in ET.fromstring(z.read(path)).iter(f"{NS}row"):
                cells = {}
                for c in row.iter(f"{NS}c"):
                    idx = _col_index(c.get("r", ""))
                    if idx is None:
                        continue
                    v = c.find(f"{NS}v")
                    inline = c.find(f"{NS}is")
                    if c.get("t") == "s" and v is not None:
                        value = shared[int(v.text)]
                    elif inline is not None:
                        value = "".join(t.text or "" for t in inline.iter(f"{NS}t"))
                    else:
                        value = v.text if v is not None else None
                    if value is not None and value.strip() != "":
                        cells[idx] = value
                if cells:
                    rows.append((int(row.get("r")),
                                 [cells.get(i) for i in range(max(cells) + 1)]))
            tabs.append((sheet.get("name"), rows))
    return tabs


def rows(workbook_name, tabs):
    """Every non-empty row of every tab, as landing records."""
    out = []
    for tab_index, (tab, tab_rows) in enumerate(tabs):
        for row_number, cells in tab_rows:
            out.append({
                "id": f"{workbook_name}:{tab_index}:{row_number}",
                "workbook": workbook_name,
                "tab": tab,
                "tab_index": tab_index,
                "row": row_number,
                "cells": cells,
            })
    return out


# ── Values ──────────────────────────────────────────────────────────────────

def num(value):
    """'$1,234.50' / '-$6,169.09' / '(12.00)' / '37%' / 1234.5 -> float, else None.

    A percent written as text comes back as a fraction, the same as the
    number Sheets stores for a cell formatted as a percent.
    """
    if value is None:
        return None
    s = str(value).strip().replace(",", "").replace("$", "").replace(" ", "")
    if not s:
        return None
    negative = s.startswith("(") and s.endswith(")")
    s = s.strip("()")
    percent = s.endswith("%")
    s = s.rstrip("%")
    try:
        n = float(s)
    except ValueError:
        return None
    if percent:
        n /= 100
    return -n if negative else n


def excel_date(value):
    """A serial day count ('46098.0') -> date, else None."""
    n = num(value)
    if n is None or not 20000 < n < 80000:      # 1954 to 2119: a date, not an amount
        return None
    return EXCEL_EPOCH + timedelta(days=int(n))


def month(value, context=None):
    """'March 2026' / 'Sept 2022' / a date serial / 'July' -> first of month.

    A month with no year ('July', the 2018 tabs) is read relative to
    `context`, the month of the tab it sits on: the latest such month not
    after the tab, so 'December' on the January 2018 tab is December 2017.
    """
    d = excel_date(value)
    if d is not None:
        return d.replace(day=1)
    if value is None:
        return None
    s = str(value).strip().lower()
    m = re.search(r"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s*(\d{4})?\b", s)
    if not m:
        m = re.search(r"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\d*\s+(\d{4})", s)
        if not m:
            return None
    mon = MONTHS[m.group(1)]
    if m.group(2):
        return date(int(m.group(2)), mon, 1)
    if context is None:
        return None
    year = context.year if mon <= context.month else context.year - 1
    return date(year, mon, 1)


def tab_month(name):
    """(first of month, revised) for a month tab's name; (None, False) otherwise.

    The names are typed by hand: 'Jan 2018', 'Sept 2022', 'April1 2024',
    'March 2024 Revised', 'Revised April 2024'.
    """
    s = name.strip().lower()
    m = re.search(r"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\d*\s+(\d{4})", s)
    if not m:
        return None, False
    return date(int(m.group(2)), MONTHS[m.group(1)], 1), "revised" in s


def _norm(cell):
    return re.sub(r"\s+", " ", (cell or "").strip().lower())


# ── Inventory Adjustments ───────────────────────────────────────────────────

INVENTORY_FIELDS = {
    "original month": "original_month",
    "customer": "customer",
    "project (if any)": "project",
    "estimate": "estimate",
    "total": "total",
    "cost": "total",
    "%": "percent",
    "$ to defer": "amount_to_defer",
    "invoice month": "invoice_month",
}


def _is_inventory_header(cells):
    seen = {_norm(c) for c in cells}
    return "customer" in seen and "original month" in seen


def _section(cells):
    """The label of a section row, upper-cased, or None.

    A lone label in column A (or B) that is not a number or a month: MERCH,
    PARTS, GBRV, and hand-typed variants of them ("Parts", "PARTS Deferral").
    """
    filled = [c for c in cells if c]
    if len(filled) != 1 or not any(cells[:2]):
        return None
    label = filled[0].strip()
    if num(label) is not None or month(label) is not None or len(label) > 30:
        return None
    # A customer's name alone in column A is a note, not a section.
    if not (label.isupper() or re.fullmatch(
            r"(parts|merch)(andise)?( deferrals?| adjustments?)?", label, re.I)):
        return None
    return re.sub(r"\s+deferrals?$", "", label, flags=re.I).upper()


def inventory(tabs, workbook_name="inventory_adjustments"):
    """(lines, checks) from Inventory Adjustments Monthly.

    lines: one per deferred job per tab section. checks: one per section
    "Total" row, comparing the sheet's own total with the lines read under it,
    so a layout the parser misreads shows up as a difference rather than a
    quietly wrong number.

    Most tables read straight off their header. One layout labels column E
    "$ to Defer" while the rows carry Total, %, then the amount to defer in
    E, F, G (the PARTS table on the 2026 tabs). A header without a % column
    whose row has a fraction right after "$ to Defer" and an amount after
    that is read as Total / % / $ to Defer.
    """
    lines, checks = [], []
    for tab_index, (tab, tab_rows) in enumerate(tabs):
        tab_date, revised = tab_month(tab)
        if tab_date is None:
            continue
        section, header, block, tab_lines = None, None, [], []

        def close(total_row, sheet_total):
            """Check a total row against the lines above it.

            A tab's last total is sometimes the running total of every table
            on it, not of the last one; that reads as a grand total.
            """
            def tied(group):
                read = round(sum(x["amount_to_defer"] or 0 for x in group), 2)
                return read, sheet_total is not None and abs(read - sheet_total) < 0.015
            read, ok = tied(block)
            kind = "section"
            if not ok and len(tab_lines) > len(block):
                grand, grand_ok = tied(tab_lines)
                if grand_ok:
                    read, ok, kind = grand, True, "tab"
            checks.append({
                "id": f"{workbook_name}:{tab_index}:{total_row}",
                "workbook": workbook_name, "tab": tab, "tab_month": tab_date.isoformat(),
                "section": section, "row": total_row, "kind": kind,
                "lines": len(block) if kind == "section" else len(tab_lines),
                "sheet_total": sheet_total, "lines_total": read,
                "difference": None if sheet_total is None else round(read - sheet_total, 2),
                "ok": ok,
            })

        for row_number, cells in tab_rows:
            if _is_inventory_header(cells):
                header = {i: _norm(c) for i, c in enumerate(cells) if c}
                block = []
                continue
            label = _section(cells)
            if label:
                section = label
                continue
            if header is None:
                continue
            total_at = next((i for i, c in enumerate(cells) if _norm(c) == "total"), None)
            if total_at is not None and not any(
                    header.get(i) == "customer" and c for i, c in enumerate(cells)):
                after = [num(c) for c in cells[total_at + 1:]]
                sheet_total = next((n for n in after if n is not None), None)
                close(row_number, sheet_total)
                block = []
                continue
            fields, notes = {}, {}
            for i, c in enumerate(cells):
                name = header.get(i)
                key = INVENTORY_FIELDS.get(name)
                if key:
                    fields[key] = c
                elif c:
                    notes[name or f"column {chr(65 + i) if i < 26 else i + 1}"] = c
            if fields.get("customer") and len([c for c in cells if c]) == 1:
                continue        # a name or note alone on its row, not a job
            if not fields.get("customer"):
                # Most tabs total their table with a bare number under the
                # amount column and no "Total" label.
                filled = [c for c in cells if c]
                # A second loose number under a closed table is someone's
                # working figure unless it is the tab's running total.
                if len(filled) == 1 and num(filled[0]) is not None and tab_lines:
                    value = num(filled[0])
                    tab_sum = sum(x["amount_to_defer"] or 0 for x in tab_lines)
                    if block or abs(tab_sum - value) < 0.015:
                        close(row_number, value)
                    block = []
                continue
            d = next((i for i, n in header.items() if n == "$ to defer"), None)
            has_pct = "%" in header.values()
            if d is not None and not has_pct and len(cells) > d + 2:
                frac, amt = num(cells[d + 1]), num(cells[d + 2])
                if frac is not None and 0 < frac <= 1 and amt is not None:
                    fields["total"], fields["percent"] = cells[d], cells[d + 1]
                    fields["amount_to_defer"] = cells[d + 2]
                    for i in (d + 1, d + 2):
                        notes.pop(header.get(i) or f"column {chr(65 + i)}", None)
            line = {
                "id": f"{workbook_name}:{tab_index}:{row_number}",
                "workbook": workbook_name,
                "tab": tab,
                "tab_month": tab_date.isoformat(),
                "revised": revised,
                "row": row_number,
                "section": section,
                "original_month": (month(fields.get("original_month"), tab_date) or None),
                "original_month_text": fields.get("original_month"),
                "customer": (fields.get("customer") or "").strip(),
                "project": (fields.get("project") or "").strip() or None,
                "estimate": (fields.get("estimate") or "").strip() or None,
                "total": num(fields.get("total")),
                "percent": num(fields.get("percent")),
                "amount_to_defer": num(fields.get("amount_to_defer")),
                "invoice_month": (fields.get("invoice_month") or "").strip() or None,
                "notes": {k: v for k, v in notes.items()} or None,
            }
            if line["original_month"] is not None:
                line["original_month"] = line["original_month"].isoformat()
            lines.append(line)
            block.append(line)
            tab_lines.append(line)
    return lines, checks


# ── Security Discounts: the Monthly Deferred schedule ──────────────────────

DEFERRED_FIELDS = {
    "3 year agreements": "discount_3yr",
    "5 year agreements": "discount_5yr",
    "total (month)": "discount_total",
    "deferred sec disc 3 year": "deferred_3yr",
    "deferred sec disc 5 year": "deferred_5yr",
    "monthly total deferred disc": "deferred_month_total",
    "total deferred sec disc": "deferred_cumulative",
    "total amortized 3 yr": "amortized_3yr",
    "total amortized 5 yr": "amortized_5yr",
    "total monthly amortization": "amortization_month_total",
    "total amortized": "amortized_cumulative",
    "checks & balances column": "balance_check",
}


def monthly_deferred(tabs, workbook_name="security_discounts", tab_name="Monthly Deferred"):
    """One record per month of the Monthly Deferred schedule.

    The column headers, read off the sheet, name what each amount is; a cell
    to the right of the last named column is kept as the month's note (e.g.
    "$32,477.23 deferred 1/1/22 for 2021 adjustment").
    """
    out = []
    for tab_index, (tab, tab_rows) in enumerate(tabs):
        if _norm(tab) != _norm(tab_name):
            continue
        header = None
        for row_number, cells in tab_rows:
            if header is None:
                if any(_norm(c) == "3 year agreements" for c in cells):
                    header = {i: _norm(c) for i, c in enumerate(cells) if c}
                continue
            month_cell = next((c for c in cells if c), None)
            m = month(month_cell)
            if m is None:
                continue
            rec = {"id": f"{workbook_name}:{tab_index}:{row_number}",
                   "workbook": workbook_name, "tab": tab, "row": row_number,
                   "month": m.isoformat(), "note": None}
            last = max(header)
            notes = []
            for i, c in enumerate(cells):
                key = DEFERRED_FIELDS.get(header.get(i))
                if key:
                    rec[key] = num(c)
                elif i > last and c:
                    notes.append(c)
            rec["note"] = " ".join(notes) or None
            out.append(rec)
    return out
