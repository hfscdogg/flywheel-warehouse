# sql/marts/ — Phase 3 (KPI marts)

One table per KPI family, `kpi_<domain>.sql`, shaped for direct agent
consumption: pre-aggregated, documented columns, no joins required to answer
the KPI question. `marts` is the **only** dataset `hermes-reader` can see —
keep anything not meant for agents out of it. (`_flywheel_canary` also lives
here, created by `scripts/01-datasets.sh`.)

Built by [`scripts/06-transform.sh`](../../scripts/06-transform.sh) after
staging; the `transform` workflow runs daily at 07:00 UTC.

## Descriptions are the agent's documentation

`hermes-mcp` serves BigQuery's table and column descriptions to the agent —
`list_kpi_tables` returns the table description, `get_table_schema` the
column ones — and nothing else. Whatever is not in a description, Hermes does
not know. The `--` comments in the SQL are for people; the agent never sees
them.

So every mart carries both, **in its own SQL file**:

```sql
CREATE OR REPLACE TABLE marts.kpi_x
OPTIONS (description = """
What the table is, its grain, and what NOT to do with it.
""")
AS
WITH ...;

ALTER TABLE marts.kpi_x ALTER COLUMN finding
  SET OPTIONS (description = "OK: ... BILLED_NO_SUBSCRIPTION: the leak. ...");
```

Write them for the agent, not the engineer: state the grain, name the traps
(a Parasol-only cost column, a customer-level figure that double-counts per
project, a one-row snapshot with no history), and say which sibling table
answers the neighbouring question. The table description is what the agent
reads first, so it carries the most weight.

Two guards keep this honest. `pipelines/tests/test_sql_marts_described.py`
extracts every output column of every mart's final `SELECT` and fails CI if
one has no `ALTER COLUMN` description; `06-transform.sh` runs
`sql/checks/marts_described.sql` after the build and fails the run if
BigQuery reports any mart table or column without one. Renaming a column
without updating its `ALTER` fails in both places, loudly. Descriptions must
not mention `staging.<table>` — the transform reads a mart's inputs by
grepping for that, and prose would turn into a dependency.

## kpi_sales_pipeline — monthly sales funnel (Zoho CRM)

One row per calendar month, first CRM activity through three months ahead.
Leads/deals created, won/lost counts and amounts, `win_rate_pct`,
`median_days_to_win` (deal creation → won close), and forward-looking
`open_deals_closing`/`open_amount_closing`/`open_expected_closing` (open
deals by expected close month; `open_expected_closing` is Zoho's
probability-weighted Expected Revenue, the dashboard's pipeline measure).
Feeds the `sales_pipeline_velocity` goal card.

## kpi_sales_weekly — weekly sales scoreboard (Zoho CRM)

The same funnel as `kpi_sales_pipeline` at week grain, for "how much did we
sell last week" and "what was our close rate" questions. Weeks are
Sunday→Saturday, keyed by `week_ending` (the Saturday), matching the Zoho
Analytics convention — its Date Dimension query tables filter `Weekday = 7`
— so "last week" means the same span it means in the dashboard. Carries
leads/deals created, won/lost counts and amounts, `close_rate_pct`, and
`won_amount_trailing_4w`. Won revenue is deal `Amount` at close, the
dashboard's measure.

## kpi_marketing_attribution — deal outcomes by channel (Zoho CRM)

One row per (`week_ending`, `marketing_channel`), same Saturday-ending weeks
as `kpi_sales_weekly`. Channel is the CRM's own "Marketing Channel" field on
deals — sales-team attribution, no web analytics involved.
`is_marketing_sourced` marks the channels the dashboard's "Marketing
Pipeline Amount" formula counts (Google Ads/LSA/organic/GBP, Houzz,
email/newsletter, website inquiry, direct), so "what did marketing bring in"
means the same thing here as in Zoho. Deals with no channel set appear as
`(unset)` — a high share there means CRM data entry, not a data bug.

## kpi_project_margin — per-project margin (D-Tools + QBO)

One row per D-Tools project: quoted price/cost/margin, plus invoiced-to-date,
collected-to-date, and AR balance from QBO. The QBO figures are matched on
normalized client name ↔ customer display name (the systems share no key)
and are **customer-level**: `customer_project_count > 1` means they're
shared across that customer's projects. `qbo_matched = FALSE` rows need a
name fixed on one side.

## kpi_subscription_audit — vendor accounts vs. what customers pay for

One row per (vendor, account) across Security Central, Alarm.com and Parasol, matched
to Zoho Billing on house number + street name + ZIP — by way of Zoho CRM, because Billing
knows who subscribes but not where they live. Its list endpoint returns no
address (0 of 34,248 rows) and its customers carry no CRM reference, so the
chain is address → CRM account → Billing customer, bridged on account name.
`match_via` says which path answered. Alarm.com has a third: its export
carries Security Central's account number on 502 of 597 rows, so a row whose
own address reaches nobody can borrow the match of the Security Central
account it is provably the same property as (`sc_account`). Measured at 15
accounts — the exact key helps less than it sounds like it should, because
most unmatched Alarm.com rows have a Security Central twin that is unmatched
too. The address key is the shared bottleneck, not an Alarm.com weakness. Measured 2026-08-30: 73% of unmatched
vendor accounts reach a CRM account by address, 94% of those reach Billing by
name — roughly 357 of 522 end to end.

**Check `name_overlaps` before acting on any row.** The address key is a
heuristic, not an identifier. Its first version keyed on house number and ZIP
alone and matched four of six sampled accounts to a completely different
household — a 5-digit ZIP covers thousands of homes. The key now includes the
street name with its suffix stripped, and `name_overlaps` reports whether the
vendor's subscriber name shares a word with the matched customer's. FALSE
there means verify by hand; it is the difference between finding a leak and
cancelling a paying customer's alarm monitoring.

**Do not dedupe across vendors.** Monitoring, interactive smart-home services
and remote support are three separate products from three separate companies;
one property on all three is three real monthly costs, not one billed thrice.
The grain is the (vendor, account) pair for that reason. Exists to find the leak: an account
still **active at the central station** whose customer has **no live
subscription** — a monthly vendor cost with no revenue behind it. The
`finding` column separates `BILLED_NO_SUBSCRIPTION` (matched customer, no
live sub — the real leak), `BILLED_NO_MATCH` (in the roster, no billing
customer matched; could be a leak or an address-key miss, check before
acting), `BILLED_NO_ROSTER` (active in this week's feed but absent from the
roster, so there's no address to match — ask for a fresh roster before
judging), `OK`, and `DEACTIVATED`.

A high `BILLED_NO_MATCH` share is a broken join, not a finding: if nearly
every active account lands there while `OK` is empty, the billing side has no
addresses to match against and nobody should be cancelled on the strength of
it. Sanity check before acting — Livewire's 1,402 live subscriptions should
produce hundreds of `OK` rows.

Alarm.com comes from the dealer-site **Custom List export**
(`status_source = 'export'`), not the Partner API — the export landed first
and is the better feed: an address on every row, plus Security Central's own
account number on 502 of 597 rows. That is an **exact cross-vendor key**,
which the address match only approximates; it is also the value worth
storing on the CRM record if this is ever made permanent.

Parasol's monthly **invoice is the roster** (`status_source = 'invoice'`):
every line item is a billed property, so every account is active by
construction, and every row carries `vendor_monthly_cost` — the rate for
that specific account. A Parasol finding therefore comes with its own price
tag rather than an estimate. `vendor_monthly_cost` is NULL for the other
vendors, which means they do not tell us, not that the account is free.

Status comes from the **weekly** Customer Count feed and addresses from the
**occasional** All Accounts roster, joined on contract number, so the audit
re-runs against current status every week without a fresh roster;
`status_source` and `status_as_of` say which feed answered and when. Both
arrive as uploaded files — [docs/vendor-reports.md](../../docs/vendor-reports.md).

## kpi_cash — cash position snapshot (QBO)

Single row as of build time: AR total and aging buckets (current, 1–30,
31–60, 61–90, 90+ days past due; no due date counts as current), AP total
and overdue, and invoiced/collected flows over the trailing 30/90 days.
Balances are current-state in QBO, so the table is rebuilt, not accumulated.
