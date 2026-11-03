# Google Sheets → the warehouse

Part of Livewire's month-end close is kept by hand in Google Sheets, one tab
per month. The QuickBooks P&L shows the adjusting entries these sheets
produce but not why they were made, so Stacy asked (2026-11-02) for the
sheets to be in the warehouse. `pipelines/gsheets/` reads them.

| Name in `GSHEETS` | Sheet | What it is |
|---|---|---|
| `inventory_adjustments` | Inventory Adjustments Monthly | Equipment bought for jobs not yet fully billed at month end, deferred out of that month's P&L. January 2018 on. |
| `security_discounts` | Security Discounts (deferred) | Discounts given with 3- and 5-year monitoring agreements, deferred and amortized over 36 or 60 months. January 2021 on. |

## How it loads

Each sheet is shared, **Viewer**, with
`ingest-vendor@<project>.iam.gserviceaccount.com`, the account that already
reads the QuickBooks Desktop export folder. The nightly `ingest-vendordrop`
workflow runs `pipelines/gsheets/ingest.py` after the QuickBooks Desktop
step. It asks Drive for each sheet's version number, and when the version
changed, exports the whole workbook (every tab) as one .xlsx and lands it.
That is the Drive API with a read-only scope, so no Sheets API to turn on
and no new credential.

`GSHEETS` in `client.env` lists them as `<name>=<spreadsheet id>`. The name
picks how a sheet is shaped; any other name lands its rows only.

In `raw_vendor`:

- `gsheet_rows`: every non-empty row of every tab as typed, so a tab
  nothing shapes (Instructions, Doug's Balancing Sheet, the pasted
  QuickBooks reports on the discount month tabs) is still readable.
- `gsheet_inventory_lines`, `gsheet_inventory_checks`,
  `gsheet_security_deferred`: the shaped records behind the staging tables
  below.
- `gsheet_files`: one row per workbook version landed.

Every version lands whole and staging reads only the newest, so a line
deleted from the sheet leaves the warehouse too.

## What the agents and Stacy read

- `staging.stg_vendor__inventory_deferrals`: one row per job per month
  tab and table (unlabeled first table, MERCH, PARTS, GBRV). A job stays
  on every tab until it bills, so sum within a month, never across months.
  Months with a revised tab mark the original `is_superseded`.
- `staging.stg_vendor__inventory_deferral_checks`: each table's own Total
  row against the lines read under it. On the first load (2026-11-03) 183
  of 207 tied to the cent; most of the rest are SUM ranges that miss a row
  inserted above or below them (July 2023 leaves out the first row of both
  tables). The sheet's total is what was booked.
- `staging.stg_vendor__security_discount_schedule`: the Monthly Deferred
  tab, one row per month: new discounts deferred, the month's
  amortization, running totals and the remaining balance. The discount
  invoice lines themselves are in `stg_qbo__invoice_lines`; the month tabs
  are pasted QuickBooks reports in three layouts and are left as rows.

## Reading the sheets

The tabs are typed by people, so the reader is deliberately forgiving and
the checks say where it was not enough:

- An .xlsx holds values, not what the sheet shows: `$1,822.35` is
  `1822.35`, `37%` is `0.37`, a date is a day count. Hand-typed text forms
  are read too.
- Tab names vary (`Sept 2022`, `April1 2024`, `Revised April 2024`). A
  month with no year in Original Month (the 2018 tabs) is the latest such
  month not after the tab's.
- Columns are found by their header. One layout labels column E
  `$ to Defer` over Total, %, $ to Defer in E, F, G; a row with a fraction
  after E and an amount after that is read that way.
- A table ends at a `Total` row or, on most tabs, a bare number under the
  amount column. A bare number equal to every line on the tab is the tab's
  running total. Any other stray number is ignored.

## Things the first load found

Worth a look on the sheets, not something the loader changes:

- Security Discounts, August 2026: the 5-year monthly share is entered as
  $4,443.82, the whole month's deferral, where 1/60 of it (about $74) is
  expected, so monthly amortization jumps from $6,214 to $10,658 and stays
  there.
- Security Discounts, September 2023: the running deferred total rises
  $15,231.30 more than that month's deferral.
- The Security Discounts sheet is shared as editable by anyone with the
  link.

## Adding another sheet

Share it (Viewer) with `ingest-vendor`, add `<name>=<id>` to `GSHEETS`, and
it lands in `gsheet_rows` on the next nightly run. Shaping it into a staging
table is a function in `workbook.py` and a branch in `ingest.shape`.
