"""Parse vendor export files (.xlsx / .csv) into records. Standard library only.

Monitoring vendors hand over reports, not APIs, and the reports are shaped for
human eyes: a header row that may be absent, `sep=,` preambles, separator rows
between records, and trailing summary lines. Each known report is described by
a format spec rather than sniffed, because guessing wrong here silently
mislabels columns instead of failing loudly.
"""

import csv
import io
import re
import xml.etree.ElementTree as ET
import zipfile

NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"

# Known vendor report formats, keyed by "<vendor>/<report>" — which is also
# the drop-bucket prefix an employee uploads into, so the key uses the
# vendor's own name for the report rather than ours.
#   columns:   None -> the file's first row is the header
#              [...] -> the file has no header; these name the columns in order
#   id_column: which parsed column identifies the record (the landing _source_id)
#   table:     landing table under raw_vendor. Named separately from the key
#              because the drop folder is named for the vendor's report and
#              the table for what it holds: "allaccounts" is the roster
#              scripts/08-vendor-roster.sh already loads into
#              securitycentral_accounts (both paths must land in one table),
#              and "customercount" is really a weekly status feed. The table
#              name is also what sql/staging/stg_vendor__<table>.sql reads.
#   require:   column -> regex every real record must match. These reports end
#              with a counts row that has the right shape but nonsense values
#              ("0, 1, 520, 67"), so shape alone cannot separate data from
#              summary; a date column that must look like a date can.
FORMATS = {
    # SCAN portal "All Accounts" export: header row, one row per contact, with
    # "ACCOUNT: X" separator rows between records. Carries street addresses.
    # Not schedulable at the central station — uploaded when someone requests
    # a fresh one, which is why status comes from the weekly report below.
    "securitycentral/allaccounts": {
        "columns": None,
        "id_column": "ACCOUNT",
        "table": "securitycentral_accounts",
        "require": {"STARTED": r"^\d{4}-\d{2}-\d{2}"},
    },
    # Scheduled Manitou "Customer Count" report: no header, a `sep=,` preamble,
    # and a trailing summary row. Name and account are packed into one field
    # ("William Goodrum (Cottage) [A1651/1857]"). No address — this is the
    # weekly status feed, joined to the roster above on CONTRACT.
    "securitycentral/customercount": {
        "columns": ["CONTRACT", "SUBSCRIBER", "STATUS", "STARTED"],
        "id_column": "CONTRACT",
        "table": "securitycentral_status",
        "require": {"STARTED": r"^\d{1,2}/\d{1,2}/\d{4}$"},
    },
}


def _col_index(ref):
    """'BC7' -> 54 (zero-based column index)."""
    m = re.match(r"[A-Z]+", ref or "")
    if not m:
        return None
    idx = 0
    for ch in m.group(0):
        idx = idx * 26 + (ord(ch) - 64)
    return idx - 1


def xlsx_rows(data):
    """Rows of the first worksheet, in column order. Bytes in, lists out."""
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        shared = []
        if "xl/sharedStrings.xml" in z.namelist():
            for si in ET.fromstring(z.read("xl/sharedStrings.xml")):
                shared.append("".join(t.text or "" for t in si.iter(f"{NS}t")))
        sheet = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))
        for row in sheet.iter(f"{NS}row"):
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
                cells[idx] = value
            yield [cells.get(i) for i in range(max(cells) + 1 if cells else 0)]


def csv_rows(data):
    """Rows of a CSV, skipping the `sep=,` preamble some exporters emit."""
    text = data.decode("utf-8-sig", errors="replace")
    for row in csv.reader(io.StringIO(text)):
        if len(row) == 1 and row[0].lower().startswith("sep="):
            continue
        yield row


def parse(data, filename, fmt_key):
    """Export bytes -> list of dicts, per the named format spec.

    Skips blank rows, report separator rows (a single populated cell), and
    trailing summary rows (fewer cells than the format expects).
    """
    spec = FORMATS.get(fmt_key)
    if spec is None:
        raise ValueError(f"unknown vendor report format '{fmt_key}' "
                         f"(known: {', '.join(sorted(FORMATS))})")
    rows = xlsx_rows(data) if filename.lower().endswith(".xlsx") else csv_rows(data)

    header = list(spec["columns"]) if spec["columns"] else None
    records = []
    for raw in rows:
        cells = ["" if v is None else str(v).strip() for v in raw]
        if not any(cells):
            continue
        if header is None:                      # first non-empty row is the header
            header = [c or f"col{i}" for i, c in enumerate(cells)]
            continue
        populated = sum(1 for c in cells if c)
        if populated <= 1:                      # separator row ("ACCOUNT: A1000-2496")
            continue
        if spec["columns"] and populated < len(header):
            continue                            # trailing summary row
        record = {header[i]: cells[i]
                  for i in range(min(len(header), len(cells))) if cells[i]}
        if not record:
            continue
        if any(not re.match(pat, record.get(col, ""))
               for col, pat in spec.get("require", {}).items()):
            continue                            # summary/counts row
        records.append(record)
    return records


def id_column(fmt_key):
    return FORMATS[fmt_key]["id_column"]


def table_name(fmt_key):
    """Landing table under raw_vendor for a format key."""
    return FORMATS[fmt_key]["table"]
