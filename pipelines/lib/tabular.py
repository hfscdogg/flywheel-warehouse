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

from . import pdftext

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
    # Parasol's monthly invoice, which is also the only roster they give us:
    # one line item per monitored account, carrying name, address, service
    # tier and — uniquely among our vendors — the rate we are charged for
    # that specific account. A leak found here comes with its own price tag
    # instead of an estimate.
    #
    # `pdf_probe` marks the format as PDF and names a string that must appear
    # in the extracted text; see pdftext.detect_shift. `id_column` is the
    # synthesised ACCOUNT key, since Parasol prints no account number.
    # Alarm.com dealer-site "Custom List" export. Preamble lines carry a
    # single cell each and are skipped as separator rows; the 43-column header
    # is then the first row wide enough to be one.
    #
    # This export carries CS Account Prefix + CS Account Number — Security
    # Central's own account number for the same property. That is an exact
    # cross-vendor key, which the address heuristic is only ever an
    # approximation of, so it is assembled here as SC_ACCOUNT.
    "alarmdotcom/customerlist": {
        "columns": None,
        "id_column": "Customer ID",
        "table": "alarmdotcom_accounts",
        # Two columns arrive wrapped for Excel's benefit: the id as a
        # =HYPERLINK() formula and the account number as ="1047".
        "clean": {
            "Customer ID": r"(\d+)\s*\)\s*$",
            "CS Account Number": r'="?([^"]*)"?$',
        },
        "derive": {"SC_ACCOUNT": ("CS Account Prefix", "CS Account Number")},
        "require": {"Customer ID": r"^\d+$"},
    },
    "parasol/invoice": {
        "columns": None,
        "id_column": "ACCOUNT",
        "table": "parasol_accounts",
        "pdf_probe": "Parasol",
        # Only the rate is required. A missing ZIP makes an account
        # unmatchable, not unreal — dropping it here would hide a line we are
        # billed for, which is the opposite of the point.
        "require": {"RATE": r"^\d+\.\d\d$"},
    },
}

# One invoice line item spans several drawn runs. Their ORDER is not reliable:
# some items carry an "Upgrade"/"Downgrade" prefix run, long customer names
# wrap onto a second run, and a missing address line shifts everything after
# it. Positional parsing silently mislabelled 8 of 285 accounts and collided
# three more onto one key — both of which lose an account we are paying for.
# So fields are identified by what they contain, not where they sit.
_PARASOL_ITEM = re.compile(r"Parasol Monitoring Service\s*--\s*(\w+)")
_MONEY = re.compile(r"^\d+(?:\.\d\d)?$")
_ZIP = re.compile(r"\b\d{5}\b")
# Trailing glyphs from the vendor's contact icons ride along on the name run.
_NAME_ICONS = re.compile(r"[y+]{1,3}(?=\s*\||\s*$)")


def parse_parasol_invoice(data, spec):
    """Line items from a Parasol invoice PDF.

    Parasol prints no account number, so ACCOUNT is synthesised. It has to be
    stable month to month and unique within one invoice: three households in
    ZIP 23226 whose street line carries no house number collapsed onto a
    single key, and staging keeps one row per key, so two of the three would
    have vanished from an audit whose entire job is finding accounts nobody
    is watching.
    """
    lines = pdftext.lines(data, spec["pdf_probe"])
    marks = [i for i, l in enumerate(lines) if _PARASOL_ITEM.match(l)]
    records = []
    for n, start in enumerate(marks):
        end = marks[n + 1] if n + 1 < len(marks) else min(start + 12, len(lines))
        tier = _PARASOL_ITEM.match(lines[start]).group(1)
        block = lines[start + 1:end]
        money = [b for b in block if _MONEY.match(b)]
        words = [b for b in block if not _MONEY.match(b)]
        if len(money) < 3 or not words:
            continue                        # not a complete line item

        # The name run is the one carrying the "name | label" separator.
        named = next((w for w in words if "|" in w), words[0])
        name, _, label = named.partition("|")
        # The address runs are whatever sits between the name and the end,
        # with the ZIP-bearing one as city/state/ZIP and the rest as street.
        tail = words[words.index(named) + 1:]
        csz = next((w for w in reversed(tail) if _ZIP.search(w)), "")
        street = normalize_street(" ".join(w for w in tail if w != csz))
        records.append({
            "SUBSCRIBER": _NAME_ICONS.sub("", name).strip(),
            "LABEL": _NAME_ICONS.sub("", label).strip(),
            "STREET": street,
            "CITY_STATE_ZIP": csz.strip(),
            "TIER": tier,
            "RATE": money[1],               # qty, rate, discount, amount
            "ACCOUNT": account_key(_NAME_ICONS.sub("", name), street, csz,
                                   _NAME_ICONS.sub("", label)),
        })
    return records


_LEADING_NUMBER = re.compile(r"^\s*\d+\s")
# Greedy prefix so this lands on the LAST house-number-shaped token:
# "and 351 6802 Paragon Pl" must yield "6802 Paragon Pl", not "351 ...".
_EMBEDDED_ADDRESS = re.compile(r".*\b(\d+\s+[A-Za-z].*)$")
_TRAILING_NUMBER = re.compile(r"^(.*?)[\s,]+(\d+)\s*$")


def normalize_street(street):
    """Put the house number at the front of a Parasol street line.

    Two variants show up, and both cost a match if left alone — the audit
    keys on house number + street + ZIP, so an address without a leading
    number simply never matches:

    "Longfield Road 629"  -> "629 Longfield Road"
        Parasol stores some addresses number-last. Verified against a
        household that also appears in the Security Central roster as
        "629 Longfield Rd", so the reversal recovers the real address rather
        than inventing one.

    "and 351 6802 Paragon Pl" -> "6802 Paragon Pl"
        A long commercial name wraps onto a second run and lands in front of
        the address. Taking the text from the first house-number-shaped token
        drops the fragment.

    A street with no number anywhere is returned unchanged: it will not match,
    which is the honest outcome, and it stays visible in the audit as an
    account we are billed for.
    """
    street = (street or "").strip()
    if not street or _LEADING_NUMBER.match(street):
        return street
    embedded = _EMBEDDED_ADDRESS.search(street)
    if embedded:
        return embedded.group(1).strip()
    trailing = _TRAILING_NUMBER.match(street)
    if trailing:
        return f"{trailing.group(2)} {trailing.group(1).strip()}"
    return street


def account_key(name, street, city_state_zip, label):
    """A stable id for an account the vendor never numbered.

    Built from subscriber name, street and ZIP rather than address alone:
    address alone is not unique here, and a duplicate key silently drops an
    account. The name makes it unique in practice; the cost is that a
    renamed customer reads as a new account, which is visible in the audit
    rather than hidden.
    """
    def norm(value, limit):
        return re.sub(r"[^a-z0-9]+", "", (value or "").lower())[:limit]

    zip5 = _ZIP.search(city_state_zip or "")
    return "-".join(filter(None, [
        norm(name, 16),
        norm(street, 16),
        zip5.group(0) if zip5 else "",
        norm(label, 8),
    ])) or "unkeyed"


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
    if spec.get("pdf_probe"):
        records = parse_parasol_invoice(data, spec)
        return [r for r in records
                if all(re.search(pat, r.get(col, ""))
                       for col, pat in spec.get("require", {}).items())]
    rows = xlsx_rows(data) if filename.lower().endswith(".xlsx") else csv_rows(data)

    header = list(spec["columns"]) if spec["columns"] else None
    records = []
    for raw in rows:
        cells = ["" if v is None else str(v).strip() for v in raw]
        if not any(cells):
            continue
        populated = sum(1 for c in cells if c)
        # Single-cell rows are never data and never a header: they are report
        # separators ("ACCOUNT: A1000-2496") or an export preamble ("Data as
        # of 8/31/2026"). Checked before the header is claimed, or the first
        # preamble line becomes the column names and every record is dropped.
        if populated <= 1:
            continue
        if header is None:                      # first wide row is the header
            header = [c or f"col{i}" for i, c in enumerate(cells)]
            continue
        if spec["columns"] and populated < len(header):
            continue                            # trailing summary row
        record = {header[i]: cells[i]
                  for i in range(min(len(header), len(cells))) if cells[i]}
        if not record:
            continue
        for col, pat in spec.get("clean", {}).items():
            found = re.search(pat, record.get(col, ""))
            if found:
                record[col] = found.group(1).strip()
        for name, (a, b) in spec.get("derive", {}).items():
            left, right = record.get(a, "").strip(), record.get(b, "").strip()
            if left and right:
                record[name] = f"{left}-{right}"
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
