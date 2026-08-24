# zoho-reference/ — Zoho Analytics dashboard extraction (source of truth)

Read-only extraction of the Zoho Analytics **"Operating Metrics Dashboard
v2"** (workspace "Zoho CRM Reports", id 769101000000007003), captured
2026-08-24 and synced byte-for-byte from the Drive folder
["Zoho Dashboard Internals"](https://drive.google.com/drive/folders/1bFNpj8d20N4unpYQNPTxVtzO8pHA_Kqc).

| File | What it is |
|---|---|
| `00-widget-inventory.md` | Source of truth: widgets → reports, data pills, filters, base tables, connector sync cadence |
| `formulas.md` | Every formula column and aggregate formula, verbatim, per table |
| `qt_*.sql` | Full SQL of the 4 Zoho query tables |

The 20 evidence screenshots (`*.png` — Edit Design / Filters / User Filters
per report, dashboard defaults, sync status) stay in the Drive folder; the
`.md`/`.sql` files here are their machine-readable equivalents.

Used by [docs/zoho-metric-lineage.md](../docs/zoho-metric-lineage.md) and
[docs/zoho-reconciliation.md](../docs/zoho-reconciliation.md). Known
Zoho-side defects (e.g. "Lost Deals Count Last 365 Days" counting Won deals)
are preserved verbatim here and flagged in those docs — do not "fix" these
files; re-extract instead when the dashboard changes.
