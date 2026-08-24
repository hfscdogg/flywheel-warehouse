# Reconciliation: BigQuery KPI marts vs Zoho Operating Metrics Dashboard v2

Diff of each mart's logic (as merged in Phase 3) against the Zoho definitions
in [zoho-metric-lineage.md](zoho-metric-lineage.md). "Mismatch" = the two
systems will report different numbers for a similarly-named concept;
severity says whether that difference is material for reconciling totals.
Nothing here was silently "fixed" — Zoho-side quirks are preserved and the
mart-side gaps are flagged for explicit decisions.

## Structural findings (read these first)

### S1 — The dashboard's finance widgets read Zoho Finance, which the warehouse does not ingest. **HIGH**
"Next Billing Revenue", "Monthly Revenue - This Year", "Churn Rate", and
"RMR % of Ops Exp" are computed from **Subscriptions/Invoices (Zoho
Finance)** — a different system from QuickBooks Online. `kpi_cash` can only
tie to the dashboard's invoice numbers to the extent Zoho Invoice mirrors
QBO. Subscriptions have **no warehouse counterpart at all**: no RMR base, no
next-billing forecast, no churn. Decision needed: add a Zoho Finance source
(`raw_zohofin`) or accept that these four dashboard metrics stay
Zoho-only.

### S2 — CRM modules the dashboard depends on are not in the ingest list. **HIGH**
`pipelines/lib/sources.py` pulls Leads/Contacts/Accounts/Deals. The
dashboard additionally reads **Stage History** (the entire WERP time-series
mechanism), **Meetings** (hours-billed rollup), and **Sales Trackers**
(Consults Actual). Deals custom fields are fine — the full record lands in
`payload` — but stage-transition history is not reconstructable
retroactively, so if weekly pipeline metrics should ever come from the
warehouse, Stage History ingestion should start sooner rather than later.

### S3 — Grain: Zoho is weekly (Saturday, `Weekday = 7`), `kpi_sales_pipeline` is monthly. **MEDIUM**
Not wrong, but totals only reconcile at month boundaries that contain whole
Zoho weeks; compare monthly aggregates of the Zoho weekly rows, tolerating
the week that straddles the month edge.

## kpi_sales_pipeline vs Zoho

| # | Mart logic | Zoho definition | Verdict |
|---|---|---|---|
| P1 | `is_won` = stage matches `/won/`, `is_lost` = `/lost/` (stg_zoho__deals) | `Forecast Type`: **21 Won stages**, most without the word "won" (RFP Sent, Change Order, Tentatively Scheduled, Rough-In*, Trim-Out*, Finish-Out*, Punch Out*, Service Call*, Installation Complete); **4 Lost stages**, two without "lost" (Client decided not to do work, Client in holding pattern) | **MISMATCH — HIGH.** The mart undercounts Won severely (any operational-stage deal) and undercounts Lost (2 of 4 stages). Every downstream column (deals_won, won_amount, win_rate_pct, open pipeline) shifts. Recommend: encode the explicit stage lists in `stg_zoho__deals` (payload has `$.Stage` verbatim). |
| P2 | No test-record exclusion | Total Revenue QT excludes `Test Record = true` | **MISMATCH — MEDIUM.** Add `$.Test_Record` extraction + exclusion or won totals run high by test deals. |
| P3 | Won amount = `Amount` of won deals, all history, by closing month | Total Closed Won Revenue = `Amount` where **Prob = 100**, last **18 months** | **PARTIAL.** Same amount column; different won-definition (P1) and window. Also note Zoho holds two "won" definitions (stage list vs Prob=100) that disagree with each other — pick one per comparison. |
| P4 | `win_rate_pct` = won/(won+lost) closed that month | Zoho `Win Rate %` same shape over Forecast Type | Matches once P1 is settled. |
| P5 | `median_days_to_win` = median(created → closing), won only | Zoho `Avg Sales Cycle` = **mean**(Age in Days) over **Won AND Lost**, where open-ended deals use `now()` | **DIFFERENT METRIC — LOW.** Both defensible; don't expect them to tie. Goal card "sales_pipeline_velocity" (median lead→proposal) matches neither yet. |
| P6 | Open pipeline = NOT won AND NOT lost, by expected close month | Pipeline Report V1: **Prob 1–99 AND Commercial? = 1**; WERP pipeline: SH.Prob in 1–99 (Prob>0 filter + <100 conditions) | **MISMATCH — MEDIUM.** Mart includes Prob=0 deals and non-commercial deals Zoho excludes; "Client in holding pattern" is Open in the mart, Lost in Zoho. |
| P7 | (absent) | Pipeline Hours = `Expected Revenue × .33 / 100` on Prob<100 stage-history state, Saturday grain | **GAP — LOW.** Needs Stage History (S2). Note Zoho's own `.33` vs `0.3` inconsistency — the dashboard uses `.33`. |
| P8 | Leads counted by created month | Dashboard has no lead-volume widget | No conflict. |

## kpi_cash vs Zoho

| # | Mart logic | Zoho definition | Verdict |
|---|---|---|---|
| C1 | Source = QBO invoices/bills/payments | Source = Zoho Finance invoices | **See S1.** Logic below compares like-for-like only if the two billing systems agree. |
| C2 | `invoiced_last_30d/90d` = Σ TotalAmt, all invoices, by txn date | "Paid Revenue" = Σ Total (BCY), **YTD by invoice date, no status filter** | **PARTIAL.** Both are status-blind sums by invoice date (label on the Zoho side is a misnomer, preserved as-is). Windows differ (trailing 30/90 vs YTD-by-month). A YTD monthly comparison needs `SUM per month` from the mart's source, not the trailing windows. |
| C3 | AR aging by **days past due** (due_date), buckets 1–30/31–60/61–90/90+; no due date ⇒ current | Zoho `Age Tier` by **days since Invoice Date**, first bucket condition `<= 20` mislabeled "0 - 30"; separate `Status` formula derives Overdue from Due Date | **DIFFERENT METRIC — MEDIUM.** Ours is standard AR aging; Zoho's tiering measures invoice age and has the 20-day boundary quirk (preserved, not fixed). Do not compare buckets directly; compare `ar_total` and overdue totals only. |
| C4 | `collected_*` from QBO Payments | No dashboard counterpart ("Paid Invoice Value" aggregate exists on the table but isn't on this dashboard) | No conflict. |
| C5 | (absent) | Next Billing Revenue: **live-status subscriptions only**, by Next Billing Date month; `RMR % of Ops Exp = 100 × total / 275000` (hard-coded) | **GAP (S1).** If ported: keep the live-only filter and the hard-coded 275,000 as a named, documented constant (`ops_expense_monthly_assumption`), not a silently computed value. |
| C6 | (absent) | Churn Rate: per Saturday, expired ÷ (subs started on/before date, where **expired subs stay in the base for 12 months after expiry**) | **GAP (S1).** The 12-month-tail denominator is intentional; port it verbatim if ported. |

## kpi_project_margin vs Zoho

No project-margin widget exists on this dashboard. Nearest touchpoint:
Pipeline Report V1 exposes `Project GM% (Pre)` (a quoted-margin field stored
on Potentials) as a pivot row. The mart's quoted margin comes from D-Tools
price/cost instead — different quoting system, no logic conflict to
reconcile. If Henry wants CRM-quoted GM% alongside D-Tools margin, `$.Project_GM_Pre`
(exact API name TBD from a live payload) can be added to `stg_zoho__deals`.

## Zoho-side defects (reconcile against the formula as written; do NOT mirror as "correct")

- **Lost Deals Count Last 365 Days counts Won deals** (formula filters
  `Forecast Type = 'Won'`). Downstream: `Win Rate Percentage Last 365
  Days`/`…11` ≈ 100%, `Predicted New Deals Count Next 90 Days` and
  `Predicted New Business - Next 3 Months` are inflated. When comparing any
  of these, reproduce the bug; when building the warehouse's own versions,
  use the correct Lost filter and note the intentional divergence.
- `Age Tier` ≤ 20 labeled "0 – 30 days" (C3).
- "Paid Revenue" includes unpaid/void invoices (C2).
- `.33` vs `0.3` pipeline-hours factor (P7).
- `RMR Sales Run Rate` (Potentials aggregate variant) contains an
  always-true OR chain; the dashboard uses the WERP variant with the
  hard-coded `/28` target instead.

## Comparison protocol (sync-lag tolerance)

Zoho CRM and Zoho Finance sync to Analytics every 3 hours (Eastern / GMT
respectively); the warehouse ingests daily at 06:00–06:40 UTC with the
transform at 07:00 UTC. Rules for any totals comparison:

1. Compare only periods that closed **≥ 48 hours ago** (both systems settled).
2. Record the as-of timestamp of both sides next to every compared number.
3. Expect exact ties only on count metrics over settled periods with aligned
   definitions; money metrics tolerate residual drift from same-day edits.

## Recommended next steps (explicit decisions, not silent fixes)

1. **P1/P2 (mart-side correctness):** encode Zoho's Forecast Type stage
   lists and Test Record exclusion in `stg_zoho__deals` — these reflect how
   Livewire actually runs its pipeline, independent of the dashboard.
2. **S1/S2 (coverage):** decide whether Zoho Finance (subscriptions,
   invoices) and Stage History/Meetings ingestion joins the roadmap; churn
   and RMR metrics are impossible without the former, weekly pipeline
   history degrades every week the latter waits.
3. Leave run-rate, packaged-%, and stamped-snapshot metrics in Zoho for now;
   they encode manual constants (275000, /28, ER≥221) that belong in goal
   cards or client config, not silently inside mart SQL, if ever ported.
