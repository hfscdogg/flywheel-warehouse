# Vendor reports → the warehouse

Monitoring vendors bill per account and expose no API for the account list.
Security Central runs Manitou; its reports come out of the SCAN portal or
arrive by email. So the data gets in as files, and this is how a file becomes
a warehouse table without anyone opening a terminal.

## The two Security Central reports

| Report | Carries | How often | Why we need it |
|--------|---------|-----------|----------------|
| **Customer Count** | contract, subscriber, status, start date | **weekly, scheduled** — Security Central emails it | the audit's live status: who is still active at the central station |
| **All Accounts** | the above **plus street address** and account type | on request (SCAN export, not schedulable) | the address, which is the only way to match an account to a Zoho Billing customer |

Neither is sufficient alone. The audit joins them on contract number and takes
status from the weekly file and address from the roster, so a fresh weekly
report re-audits everyone against addresses captured whenever the last roster
was pulled. See [`sql/marts/kpi_subscription_audit.sql`](../sql/marts/kpi_subscription_audit.sql).

## The drop bucket

A Cloud Storage bucket in the client's project with one folder per report.
Anyone granted access drags the file into the right folder in a browser; the
`ingest-vendordrop` workflow picks it up on the next run (06:50 UTC, before
the 07:00 transform), lands it in `raw_vendor`, and moves the file to
`processed/` so nothing loads twice.

```
gs://livewire-dw-vendor-drops/
  securitycentral/allaccounts/      ← the SCAN "All Accounts" export (.xlsx)
  securitycentral/customercount/    ← the weekly emailed report (.CSV)
  processed/                        ← where the pipeline files them afterwards
```

An empty drop folder means this week's report has not arrived yet — that is
the whole status display.

### One-time setup (owner)

```sh
./scripts/09-vendor-drop.sh livewire
```

Creates the bucket, grants `ingest-writer` read/archive on it, and prints the
console URL. Then set the repo variable so the workflow finds it:

```sh
gh variable set VENDOR_DROP_BUCKET --repo hfscdogg/flywheel-warehouse \
  --body 'livewire-dw-vendor-drops'
```

(Optional — the pipeline defaults to `<project-id>-vendor-drops`.)

### Giving an employee the job (owner)

```sh
./scripts/09-vendor-drop.sh livewire grant amy@getlivewire.com
```

`objectCreator` + `objectViewer` **on this bucket only**: they can add files
and see what they added. No BigQuery, no other bucket, nothing else in the
project. Revoke by removing those two bindings on the bucket.

### What the employee does

> Every Monday, Security Central emails the **Customer Count** report.
> Save the attachment, open
> https://console.cloud.google.com/storage/browser/livewire-dw-vendor-drops,
> click into `securitycentral/customercount/`, and drop the file in.
> That's the whole job — the file disappears from that folder within a day
> once the warehouse has read it.

The file name doesn't matter; the folder does. Re-uploading the same file is
harmless (landing tables are append-only and staging keeps the latest row per
record), so when in doubt, upload it.

### Refreshing the roster

The All Accounts export isn't schedulable, so ask Security Central for one
when addresses go stale — quarterly is plenty, or whenever
`kpi_subscription_audit` shows a run of `BILLED_NO_ROSTER` findings (accounts
in the weekly feed that the roster has never seen). Drop it in
`securitycentral/allaccounts/` the same way.

## The command-line path (still supported)

`scripts/08-vendor-roster.sh` loads an All Accounts export straight from a
laptop, bypassing the bucket:

```sh
./scripts/08-vendor-roster.sh livewire securitycentral ~/Downloads/AllAccounts.xlsx
```

It lands the same rows in the same table (`raw_vendor.securitycentral_accounts`)
with the same `_source_id`, so the two paths are interchangeable — use
whichever is at hand.

## Adding another vendor report

Report formats are declared, not sniffed, in
[`pipelines/lib/tabular.py`](../pipelines/lib/tabular.py):

```python
"securitycentral/customercount": {
    "columns": ["CONTRACT", "SUBSCRIBER", "STATUS", "STARTED"],
    "id_column": "CONTRACT",
    "table": "securitycentral_status",
    "require": {"STARTED": r"^\d{1,2}/\d{1,2}/\d{4}$"},
},
```

- `columns: None` means the file's first row is the header; a list means it
  has none and these name the columns in order.
- `require` is what separates real records from the trailing summary row
  these reports end with. The Customer Count summary is `0,1,520,67` — the
  right shape for a record, so only "the date column must look like a date"
  catches it. Skipping `require` on a report that has one silently loads a
  fake customer.
- `table` is the `raw_vendor` landing table, which is also what
  `sql/staging/stg_vendor__<table>.sql` reads.

Add the key to `DROP_PREFIXES` in `scripts/09-vendor-drop.sh`, re-run it to
create the folder, add a case to `pipelines/tests/test_tabular.py`, and write
the staging model. No pipeline code changes.
