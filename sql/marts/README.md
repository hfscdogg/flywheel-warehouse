# sql/marts/ — Phase 3 (KPI marts)

One table per KPI family, `kpi_<domain>.sql`, shaped for direct agent
consumption: pre-aggregated, documented columns, no joins required to answer
the KPI question. `marts` is the **only** dataset `hermes-reader` can see —
keep anything not meant for agents out of it. (`_flywheel_canary` also lives
here, created by `scripts/01-datasets.sh`.)

Built by [`scripts/06-transform.sh`](../../scripts/06-transform.sh) after
staging; the `transform` workflow runs daily at 07:00 UTC.

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

## kpi_project_margin — per-project margin (D-Tools + QBO)

One row per D-Tools project: quoted price/cost/margin, plus invoiced-to-date,
collected-to-date, and AR balance from QBO. The QBO figures are matched on
normalized client name ↔ customer display name (the systems share no key)
and are **customer-level**: `customer_project_count > 1` means they're
shared across that customer's projects. `qbo_matched = FALSE` rows need a
name fixed on one side.

## kpi_cash — cash position snapshot (QBO)

Single row as of build time: AR total and aging buckets (current, 1–30,
31–60, 61–90, 90+ days past due; no due date counts as current), AP total
and overdue, and invoiced/collected flows over the trailing 30/90 days.
Balances are current-state in QBO, so the table is rebuilt, not accumulated.
