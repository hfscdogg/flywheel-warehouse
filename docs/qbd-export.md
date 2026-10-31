# QuickBooks Desktop history → the warehouse

Livewire kept its books in QuickBooks Desktop (QBD) from 2003 through March
2022, then moved to QuickBooks Online, which `ingest-qbo` already pulls. The
QBD subscription is being cancelled. A `.QBW` can only be read by QuickBooks
itself, so the history leaves as a one-time export of reports, saved to a
Google Drive folder, and this page is how that folder becomes warehouse
tables — and how we know the export is complete enough to cancel.

## How it loads

The folder is shared (Viewer) with `ingest-vendor@<project>.iam.gserviceaccount.com`.
The nightly `ingest-vendordrop` workflow runs `pipelines/qbd/ingest.py`
after the vendor drops: it lists the folder through the Drive API, downloads
each `qbd_*.csv` / `.iif` it has not loaded before, and lands one row per
report row in `raw_vendor.qbd_<report>` (`qbd_general_ledger`,
`qbd_sales_by_customer_detail`, …). `QBD_DRIVE_FOLDER_ID` in `client.env`
names the folder.

- **Why `raw_vendor`.** These are files a person exported and dropped
  somewhere, like the monitoring vendors' reports, and `ingest-vendor` is the
  account that lands such files. A `raw_qbd` of its own would need a new
  account, trust binding and grants for a load that happens once.
- **File names carry the metadata.** `qbd_<report>[_<basis>][_<from>_<to> |
  _<as-of> | _by-year_<y0>_<y1>].csv` — the tracker sheet in the folder lists
  every name. A file named otherwise is skipped and logged.
- **The backup (`.qbb`), portable copy (`.qbm`) and tracker sheet** stay in
  the folder as the archive and are never downloaded.
- **Re-runs are free.** A file loads once per content checksum; an edited or
  late file loads on the next run. Landing tables are append-only; a row's
  `_source_id` is `<drive file id>:<line>`.

`raw_vendor.qbd_files` has one row per file loaded (rows, lines, whether it
was cut off), and `raw_vendor.qbd_checks` one row per year checked.

## The checks, and what "safe to cancel" means

The run fails — and the alert opens an issue — when:

1. **A report was cut off.** QuickBooks stopped every CSV export at 32,768
   rows without saying so. In the October 2026 export that cut off the
   General Ledger for 2011–2021, the Journal for 2011–2020, most Transaction
   Detail by Account years, and the all-dates Sales by Customer and Deposit
   Detail files. A cut-off file is exported again in smaller date ranges
   (quarters; months for any quarter that is still cut off). The cut-off
   original can stay in the folder: the year is judged on the pieces.
2. **A year's General Ledger does not tie to its Trial Balance.** For each
   year, the General Ledger files must cover 1 January to 31 December with no
   gap, none cut off, and the one ending 31 December must agree with the
   31 December Trial Balance at every account, subaccounts rolled up.

A year that failed is checked again on every run until it passes, so a
re-exported piece, or a fix to the parser, clears it without re-uploading
anything.

When every year from 2003 to 2022 passes and the backup is in the folder,
the export is complete. Until then QuickBooks Desktop is the only place the
missing rows exist.

```sql
SELECT JSON_VALUE(payload, '$.year') AS year, JSON_VALUE(payload, '$.ok') AS ok,
       JSON_QUERY(payload, '$.problems') AS problems
FROM raw_vendor.qbd_checks
QUALIFY ROW_NUMBER() OVER (PARTITION BY JSON_VALUE(payload, '$.year')
                           ORDER BY _loaded_at DESC) = 1
ORDER BY year;
```

## Accepted at annual totals

QuickBooks cut the 2011–2021 General Ledger exports off at its row cap.
On 2026-10-31 we decided not to re-export them. The sales detail is
complete, the Trial Balance and P&L give every account's total for each of
those years, and the `.QBB` backup in the folder holds the full ledger if
transaction-level detail is ever needed. `QBD_LEDGER_TOTALS_ONLY` in
`client.env` lists those years. They pass the check with a note instead of
failing it, but they still need a Trial Balance, and a complete ledger for
them must still tie.

## What the agents can read

`staging.stg_vendor__qbd_sales_lines` has every sales line from 2003 to March 2022:
customer, job, item, quantity, price and amount. Each line is taken from the
narrowest complete export covering its date, so overlapping exports never
count twice. 2017 Q1–2019 Q2 is missing from the export and is empty here,
not zero. For April 2022 onward, use `stg_qbo__invoice_lines`.
