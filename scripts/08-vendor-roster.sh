#!/usr/bin/env bash
# 08-vendor-roster.sh <client-slug> <vendor> <export-file>
#
# Loads a monitoring vendor's account roster (Security Central, Alarm.com, ...)
# into raw_vendor.<vendor>_accounts, in the same landing shape every pipeline
# uses: the whole record as JSON in `payload` plus metadata columns.
#
# Why a script and not a pipeline: these vendors have no self-serve API for
# the dealer account list (Alarm.com integrates via its Partner Portal or
# SecurityTrax; Security Central exports from its portal), so the roster
# arrives as a periodic export a human downloads. Run this whenever a fresh
# export lands; the staging model always reads the latest load per account.
#
# Accepts .xlsx (parsed with the standard library — no third-party deps) or
# .csv. The first row is the header; report-style separator rows (a single
# leading cell like "ACCOUNT: A1000-2496") are skipped.
#
#   ./scripts/08-vendor-roster.sh livewire securitycentral ~/Downloads/AllAccounts.xlsx
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 3 ] || {
  printf 'Usage: %s <client-slug> <vendor> <export-file>\n' "$0" >&2
  printf 'Example: %s livewire securitycentral ~/Downloads/AllAccounts.xlsx\n' "$0" >&2
  exit 2
}
load_client "$1"
VENDOR="$2"
EXPORT_FILE="$3"
require_cmd bq python3

case "$VENDOR" in
  *[!a-z0-9_]*) die "vendor must be lowercase letters, digits, underscores (got '$VENDOR')" ;;
esac
[ -f "$EXPORT_FILE" ] || die "no such export file: $EXPORT_FILE"

DATASET="raw_vendor"
case " $DATASETS_RAW " in
  *" $DATASET "*) : ;;
  *) die "$DATASET is not in DATASETS_RAW for '$CLIENT_SLUG' — add it and re-run ./scripts/setup.sh $CLIENT_SLUG" ;;
esac

TABLE="${VENDOR}_accounts"
RUN_ID="vendor-$VENDOR-$(date -u +%Y%m%dT%H%M%SZ)"
NDJSON="$(mktemp -t vendor-roster.XXXXXX)"
trap 'rm -f "$NDJSON"' EXIT

info "Converting $EXPORT_FILE → landing rows (run $RUN_ID)"
EXPORT_FILE="$EXPORT_FILE" RUN_ID="$RUN_ID" python3 - > "$NDJSON" <<'PYEOF'
"""Export file → newline-delimited landing rows. Standard library only."""
import csv, datetime, json, os, re, sys, xml.etree.ElementTree as ET, zipfile

path, run_id = os.environ["EXPORT_FILE"], os.environ["RUN_ID"]
loaded_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"


def xlsx_rows(path):
    """Minimal xlsx reader: shared strings + first worksheet, in column order."""
    with zipfile.ZipFile(path) as z:
        shared = []
        if "xl/sharedStrings.xml" in z.namelist():
            for si in ET.fromstring(z.read("xl/sharedStrings.xml")):
                shared.append("".join(t.text or "" for t in si.iter(f"{NS}t")))
        sheet = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))
        for row in sheet.iter(f"{NS}row"):
            cells = {}
            for c in row.iter(f"{NS}c"):
                ref = c.get("r", "")
                col = re.match(r"[A-Z]+", ref)
                if not col:
                    continue
                idx = 0
                for ch in col.group(0):
                    idx = idx * 26 + (ord(ch) - 64)
                v = c.find(f"{NS}v")
                text = c.find(f"{NS}is")
                if c.get("t") == "s" and v is not None:
                    value = shared[int(v.text)]
                elif text is not None:
                    value = "".join(t.text or "" for t in text.iter(f"{NS}t"))
                else:
                    value = v.text if v is not None else None
                cells[idx - 1] = value
            width = max(cells) + 1 if cells else 0
            yield [cells.get(i) for i in range(width)]


rows = xlsx_rows(path) if path.lower().endswith(".xlsx") else (
    r for r in csv.reader(open(path, newline="", encoding="utf-8-sig")))

header, emitted = None, 0
for raw in rows:
    cells = ["" if v is None else str(v).strip() for v in raw]
    if not any(cells):
        continue
    if header is None:
        header = [c or f"col{i}" for i, c in enumerate(cells)]
        continue
    # Report-style separator rows carry a single value, usually in column 0
    # ("ACCOUNT: A1000-2496"); real data rows fill several columns.
    if sum(1 for c in cells if c) <= 1:
        continue
    record = {header[i]: cells[i] for i in range(min(len(header), len(cells))) if cells[i]}
    if not record:
        continue
    # Prefer an explicit account column as the stable id; fall back to the
    # whole row so nothing is silently dropped.
    source_id = next((record[k] for k in record if k.strip().upper() == "ACCOUNT"), None)
    print(json.dumps({
        "payload": record,
        "_source_id": source_id or json.dumps(record, sort_keys=True)[:256],
        "_modified_at": None,
        "_loaded_at": loaded_at,
        "_run_id": run_id,
    }))
    emitted += 1

if not emitted:
    sys.exit("no data rows parsed — check the export's header row")
print(f"parsed {emitted} rows", file=sys.stderr)
PYEOF

ROWS="$(wc -l < "$NDJSON" | tr -d ' ')"
info "Loading $ROWS rows into $GCP_PROJECT_ID:$DATASET.$TABLE (append-only)"
if is_dry_run; then
  log "[dry-run] bq load --source_format=NEWLINE_DELIMITED_JSON --autodetect $DATASET.$TABLE <ndjson>"
else
  run bq --headless=true --project_id="$GCP_PROJECT_ID" load \
    --source_format=NEWLINE_DELIMITED_JSON \
    --schema='payload:JSON,_source_id:STRING,_modified_at:TIMESTAMP,_loaded_at:TIMESTAMP,_run_id:STRING' \
    "$DATASET.$TABLE" "$NDJSON"
fi

info "Loaded. Rebuild staging + marts to pick it up:"
log "  ./scripts/06-transform.sh $CLIENT_SLUG"
