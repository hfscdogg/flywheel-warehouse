# Operating Metrics Dashboard v2 — Widget Inventory

- Workspace: **Zoho CRM Reports** (workspace id 769101000000007003)
- Dashboard: **Operating Metrics Dashboard v2** (view id 769101000005925472)
- Captured: 2026-08-24 (America/New_York) — read-only extraction, no changes saved
- Purpose: reconciliation source-of-truth for flywheel-warehouse BigQuery KPI marts

## Widget → underlying report checklist

| # | Widget title (on dashboard) | Underlying report | Report view id | Type | Slug (file prefix) |
|---|------------------------------|-------------------|----------------|------|--------------------|
| 1 | Operating Metrics - Report | Operating Metrics - Report | 769101000005897516 | Pivot | operating-metrics-report |
| 2 | Next Billing Revenue | Next Billing Revenue | 769101000004877767 | Pivot | next-billing-revenue |
| 3 | Monthly Revenue - This Year | Monthly Revenue - This Year | 769101000004877820 | Pivot | monthly-revenue-this-year |
| 4 | Pipeline Hours by Potential Owner | Pipeline Hours by Potential Owner | 769101000005926224 | Chart (stacked bar) | pipeline-hours-by-potential-owner |
| 5 | Pipeline Report- V1 | Pipeline Report- V1 | 769101000013916016 | Pivot | pipeline-report-v1 |

Widget titles match the underlying report names 1:1 (verified in Edit Design; view ids from dashboard DOM match report URLs).

## What each report computes / reads / excludes

### 1. Operating Metrics - Report (Pivot)
Rows: `Date Dimension.Date` @ Week&Year.
Data (column, aggregation, source table — "Actual" in UI = aggregate formula):
- Total Revenue — Sum — `Total Revenue.Total Revenue` (displayed as "Total Closed Won Revenue")
- No. of RMR Weekly Deals — Aggregate formula — `Weekly Expected Revenue by Potential.No. of RMR Weekly Deals`
- Pipeline Hours — Sum — `Weekly Expected Revenue by Potential.Pipeline Hours`
- Written Business — Sum — `Written Business SQL.Written Business`
- Pipeline Hours Revenue — Sum — `Weekly Expected Revenue by Potential.Pipeline Hours Revenue` (displayed "Pipeline Revenue")
- L4B Pipeline Revenue — Sum — `Weekly Expected Revenue by Potential.L4B Pipeline Revenue`
- Sales Run-Rate Annualized — Aggregate formula — `Weekly Expected Revenue by Potential`
- RMR Sales Run-Rate — Aggregate formula — `Weekly Expected Revenue by Potential`
- L4B Run-Rate Annualized — Aggregate formula — `Weekly Expected Revenue by Potential`
- Packaged Projects % — Aggregate formula — `Weekly Expected Revenue by Potential`
- Projects completed on time % — Sum — `Stamped Weekly Expected Revenue by Potential Data`
- Actual vs. Billed Hours % — Sum — `Stamped Weekly Expected Revenue by Potential Data`
- Consults Actual — Sum — `Sales Trackers.Consults Actual`
- Churn Rate — Sum — `Subscription Churn Last 12 Months (Weekly).Churn Rate`
Filters: none (0). User filters: none (0). Excludes: nothing at report level.

### 2. Next Billing Revenue (Pivot)
Base: `Subscriptions (Zoho Finance)`.
Rows: `Next Billing Date` @ Mon&Year. Data: `Total (BCY)` Sum (displayed "Total Revenue"); report formula `RMR % of Ops Exp` = `100*"2. Total (BCY)"/275000` (hard-coded $275,000 ops-expense denominator).
Filters (1): `Subscription Status` — Include only `live` (excludes cancelled, dunning, expired, non_renewing, paused, trial_expired, unpaid).
User filters: none (0).

### 3. Monthly Revenue - This Year (Pivot)
Base: `Invoices (Zoho Finance)`.
Rows: `Invoice Date` @ Mon&Year (displayed "Month"). Data: `Total (BCY)` Sum (displayed "Paid Revenue"); report formula `RMR % of Ops Exp` = `100*"2. Total (BCY)"/275000`.
Filters (1): `Invoice Date` — Relative: **Year to Date** (excludes anything before Jan 1 of current year and future dates).
User filters: none (0).

### 4. Pipeline Hours by Potential Owner (Chart, stacked bars)
Base: `Weekly Expected Revenue by Potential`.
X-Axis: `Date` @ Week&Year. Y-Axis: `Pipeline Hours` Sum. Color: `Potential Owner` (Actual).
Filters (1): `Date` — Relative: **Last 12 Months**.
User filters: none (0).

### 5. Pipeline Report- V1 (Pivot)
Base: `Potentials` (Zoho CRM).
Rows: `Potential Owner Name` (Actual), `Probability (%)` (Actual(D)), `Amount` (Actual(D)), `Project GM% (Pre)` (Actual(D)), `Potential Name` (Actual), `Stage` (Actual).
Data: `Amount` Sum (displayed "Total Amount"), `Expected Revenue` Sum.
Filters (2):
- `Probability (%)` — Ranges: include **1 to 99** (excludes 0% and 100% deals).
- `Commercial?` — Include only value **1** (commercial deals only).
User filters (1): `Potential Owner Name` — default **- Select -** (none; unfiltered until a user picks).

## Base tables used (deduped)

| # | Table | Type | View id | Used by |
|---|-------|------|---------|---------|
| 1 | Total Revenue | Query table (SQL: qt_total_revenue.sql) | 769101000010672002 | Operating Metrics - Report |
| 2 | Weekly Expected Revenue by Potential | Query table (SQL: qt_weekly_expected_revenue_by_potential.sql), ~354,647 rows | 769101000005302002 | Operating Metrics - Report, Pipeline Hours by Potential Owner |
| 3 | Written Business SQL | Query table (SQL: qt_written_business_sql.sql), 1,911 rows | 769101000010678071 | Operating Metrics - Report |
| 4 | Stamped Weekly Expected Revenue by Potential Data | Regular (stamped snapshot), 204 rows | 769101000010608662 | Operating Metrics - Report |
| 5 | Sales Trackers | Regular (Zoho CRM custom module sync) | 769101000009983051 | Operating Metrics - Report |
| 6 | Subscription Churn Last 12 Months (Weekly) | Query table (SQL: qt_subscription_churn_last_12_months_weekly.sql), 158 rows | 769101000007614002 | Operating Metrics - Report |
| 7 | Date Dimension | Regular (local calendar table, daily grain through 2089) | 769101000005086675 | Operating Metrics - Report (rows axis); joined in query tables |
| 8 | Subscriptions (Zoho Finance) | Synced (Zoho Finance connector), 2,207 rows | 769101000002005757 | Next Billing Revenue |
| 9 | Invoices (Zoho Finance) | Synced (Zoho Finance connector), 60,470 rows | 769101000002005848 | Monthly Revenue - This Year |
| 10 | Potentials | Synced (Zoho CRM Deals module) | 769101000000007018 | Pipeline Report- V1; upstream of most query tables |

Query tables reference these further upstream tables inside their SQL: Date Dimension, Potentials, Stage History, Meetings, Subscriptions (Zoho Finance).

## Dashboard-level user filters / defaults

See 01-dashboard-defaults.png. In-widget user filter on Pipeline Report- V1: "Potential Owner Name", default "- Select -".

## Connector sync (workspace Data Sources view, checked 2026-08-24 ~1:35 PM EDT)

| Data source | Org | Last sync | Schedule | Next scheduled |
|---|---|---|---|---|
| **Zoho CRM** | LIVEWIRE, LLC | Data Sync Successful — 24 Aug 2026, 11:22:14 AM EDT | Every 3 hours (TZ: GMT-5 Eastern, America/Indiana/Indianapolis) | 24 Aug 2026, 02:22:22 PM EDT |
| **Zoho Finance** (Zoho Invoice, Zoho Billing, Zoho Inventory, Zoho Expense) | Livewire | Data Sync Successful — 24 Aug 2026, 01:54:00 PM EDT | Every 3 hours (TZ: GMT) | 24 Aug 2026, 04:54:12 PM EDT |
| Zoho Desk | getlivewire | 24 Aug 2026, 08:40:00 AM GMT | — | 25 Aug 2026, 08:40:00 AM GMT |
| Zoho Campaigns | Livewire | 24 Aug 2026, 02:14:35 PM EDT | — | 24 Aug 2026, 05:12:35 PM EDT |
| Zoho Analytics (getlivewire_projects) | — | 24 Aug 2026, 12:12:52 PM EDT | — | 24 Aug 2026, 03:10:08 PM EDT |
| Local Drive | — | Sync Success | Not applicable | — |

Zoho CRM modules synced into "Zoho CRM Modules (Data)" (module tables, excluding workspace-local query tables kept in the same folder): Account Notes, Accounts, Call Notes, Calls, Case Notes, Cases, Contact Notes, Contacts, Control4 Users (custom), Lead Notes, Leads, Meeting Notes, Meetings, Potential Notes, Potentials, Sales Rep Goal Notes, Sales Rep Goals, Sales Tracker Notes, Sales Trackers, Stage History, Task Notes, Tasks, Users — plus Zoho Projects tables (Projects, Tasks, Tasks Owner, Timesheets, Users, Hours Planned Vs Hours Spent).

Dashboard-relevant sources: Potentials, Stage History, Meetings, Sales Trackers (Zoho CRM, synced every 3h); Subscriptions + Invoices (Zoho Finance, synced every 3h); Date Dimension (local); query tables recompute on read.

Screenshots: 02-data-sources-overview.png, 02-data-sources-zoho-crm.png, 02-data-sources-zoho-finance.png.
