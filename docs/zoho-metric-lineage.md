# Zoho "Operating Metrics Dashboard v2" — metric lineage

Machine-readable extraction lives in [`zoho-reference/`](../zoho-reference/)
(synced 2026-08-24 from the Drive folder "Zoho Dashboard Internals"; evidence
screenshots remain in Drive). This doc parses it into
**metric → formula → source columns → filters/exclusions** so the BigQuery
marts can be diffed against it — see
[zoho-reconciliation.md](zoho-reconciliation.md) for the diff.

Shorthand: `P` = Potentials (CRM Deals), `SH` = Stage History, `M` = Meetings
rollup, `DD` = Date Dimension, `WERP` = Weekly Expected Revenue by Potential
query table, `Subs`/`Inv` = Subscriptions/Invoices (Zoho Finance).

## Shared building blocks

| Block | Definition | Source |
|---|---|---|
| `Forecast Type` (P formula col) | `Won` if Stage ∈ {RFP Sent, Closed Won, Closed Won - Service, Closed Won - Design Retainer, Closed Won - Not Ready, Change Order, Tentatively Scheduled, Rough-In, Rough-In Scheduled, Rough-In Complete, Trim-Out, Trim Out Scheduled, Trim-Out Complete, Finish-Out, Finish Out Scheduled, Finish-Out Complete, Punch Out, Punch Out Scheduled, Service Call Scheduled, Service Call Complete, Installation Complete}; `Lost` if Stage ∈ {Closed Lost to Competition, Client decided not to do work, Client in holding pattern, Closed Lost - Unable to Contact}; else `Open` | formulas.md → Potentials |
| "Won" (query-table variant) | `Probability (%) = 100` (NOT Forecast Type) — used by Total Revenue QT and every WERP accrual column | qt_total_revenue.sql, qt_weekly…sql |
| `RMR Deal` (P formula col) | Prob=100 AND (Alarm Monitoring Plan LIKE '%$%' OR Pick Service Plan LIKE '%$%' OR '%Prepaid%') | formulas.md |
| `Expired Date` (Subs formula col) | status='expired' → Expiry Date, else Cancelled Date | formulas.md |
| WERP row grain | Saturday (`DD.Weekday = 7`) × deal × windowed stage-history state: dedup keeps last SH transition per deal-week (`Week Row Number = 1`) while in window, then carries the final state forward (`Potential Row Number = 1`) | qt_weekly…sql |
| WERP scope filters | Date in **last 18 months** (+6 days forward), `SH.Probability > 0`, deals **created in last 3 years** | qt_weekly…sql WHERE |
| Meetings rollup `M` | per deal: Days Spent, ceil(Σ Duration Man-Hrs), Latest/First Meeting — only Event Type ∈ {Install - Warranty / Punchout, " Finish Out", "Finish-Out ($$$)"} and Event Status ∈ {Ready to Bill, Complete} | qt_weekly…sql |

## Widget 1 — Operating Metrics - Report (pivot, rows = week ending Saturday)

| Metric (display) | Formula | Source columns | Filters / exclusions |
|---|---|---|---|
| Total Closed Won Revenue | Sum(`Total Revenue`) | P.Amount, joined DD on date(P.Closing Date) | **Prob = 100**, **Test Record = false**, Closing Date in **last 18 months** |
| No. of RMR Weekly Deals | count_if(`Weekly RMR Deal?`='Yes') | WERP: RMR Deal flag surfaced only in the deal's closing week | WERP scope; RMR Deal def above |
| Pipeline Hours | Sum(`Pipeline Hours`) | `if(SH.Prob < 100, SH."Expected Revenue" * .33 / 100, NULL)` | WERP scope (Prob>0 ⇒ effectively Prob 1–99) |
| Written Business | Sum(WB QT.`Written Business`) | P.Amount dated by D&E Effective Date = coalesce(D&E Completed, D&E Complete Date) | `D&E Used? = 'Yes'`, effective date not null; **no** time window |
| Pipeline Revenue | Sum(`Pipeline Hours Revenue`) | `if(SH.Prob < 100, SH."Expected Revenue", NULL)` | WERP scope |
| L4B Pipeline Revenue | Sum(`L4B Pipeline Revenue`) | as above + `P."Commercial?" = 'Yes'` | WERP scope |
| Sales Run-Rate Annualized | `52 × Weekly AVG Sales`; Weekly AVG Sales = sum_if(Prob=100, `Yearly Accrued Revenue` / week(Date)) | Yearly Accrued Revenue = SH.Expected Revenue when Prob=100, same calendar year as Closing Date, week ≥ closing week (in-year accrual carry) | WERP scope; resets every Jan 1 |
| RMR Sales Run-Rate | `100 × (count_if(RMR Deal?='Yes') / MAX(week(Date)) × 52/12) / 28` | WERP `RMR Deal?` (in-year, week ≥ closing week) | **hard-coded /28** (annual RMR-deal target) |
| L4B Run-Rate Annualized | `52 × Weekly AVG L4B Sales` | Yearly Accrued L4B Revenue (adds Commercial?='Yes') | WERP scope |
| Packaged Projects % | 100 × count_if(Prob=100 ∧ ER≥221 ∧ Packaged Deal?=true) / count_if(Prob=100 ∧ ER≥221 ∧ Closing Week=Week) | `Packaged Deal?` = Built Using Packages? surfaced only in closing week | **ER ≥ 221 threshold**; closing-week cohort |
| Projects completed on time % | Sum from **Stamped** WERP Data (manual snapshot table, 204 rows) | stamped column | live equivalent: count_if(`Completed on Time`='On Time')/count |
| Actual vs. Billed Hours % | Sum from **Stamped** table | stamped column | live equivalent: 100×ΣM.Total Hours Spent / ΣP.FO Hours Sold |
| Consults Actual | Sum(Sales Trackers.`Consults Actual`) | plain CRM custom-module column | none |
| Churn Rate | Sum(churn QT.`Churn Rate`) | see Widget-independent churn QT below | — |

## Widget 2 — Next Billing Revenue (pivot)

| Metric | Formula | Source | Filters |
|---|---|---|---|
| Total Revenue | Sum(`Total (BCY)`) by Next Billing Date @ Mon&Year | Subs.Total (BCY) | **Subscription Status = 'live' only** (excludes cancelled, dunning, expired, non_renewing, paused, trial_expired, unpaid) |
| RMR % of Ops Exp | `100 × "2. Total (BCY)" / 275000` | report formula | **hard-coded $275,000 ops-expense denominator** |

## Widget 3 — Monthly Revenue - This Year (pivot)

| Metric | Formula | Source | Filters |
|---|---|---|---|
| Paid Revenue | Sum(`Total (BCY)`) by Invoice Date @ Mon&Year | Inv.Total (BCY) | **Invoice Date relative = Year to Date** only. **No status filter** — despite the "Paid Revenue" label it includes open/overdue/draft/void invoices |
| RMR % of Ops Exp | `100 × "2. Total (BCY)" / 275000` | report formula | same hard-coded 275000 |

## Widget 4 — Pipeline Hours by Potential Owner (stacked bar)

Sum(WERP.`Pipeline Hours`) by week (X) and `Potential Owner` (color).
Filter: Date relative = **Last 12 Months** (narrower than the QT's 18-month
window). Same `ER × .33 / 100` hours formula.

## Widget 5 — Pipeline Report- V1 (pivot)

Sum(`Amount`) ("Total Amount") and Sum(`Expected Revenue`) over Potentials,
rows Owner → Probability → Amount → Project GM% (Pre) → Name → Stage.
Filters: **Probability (%) in 1–99** (excludes 0% and 100%) AND
**Commercial? = 1** only. User filter Potential Owner defaults to none.

## Churn query table (feeds Widget 1 Churn Rate)

Per Saturday over the **last 36 months** window shown, joining every
subscription with `Start Date ≤ date` AND (`date ≤ Expired Date + 12 months`
OR not expired):

- `Churn Rate = to_percentage(100 × count_if(Expired Date not null) / COUNT(Subscription ID))`
- **Expired subs stay in the denominator (and numerator) for 12 months after
  expiry**, then fall out — churn is "% of the last-12-months-relevant base
  that has expired", not a period churn rate.

## Zoho-side quirks recorded as-is (reconcile against the formula as written)

1. **"Lost Deals Count Last 365 Days" counts Won deals** — the stored formula
   filters `Forecast Type = 'Won'` (copy-paste of the Won aggregate). Every
   downstream consumer (`Win Rate Percentage Last 365 Days`[`11`],
   `Predicted New Deals Count Next 90 Days`, `Predicted New Business`) is
   biased to a ~100% win rate. Zoho-side defect; do not "fix" in
   reconciliation comparisons.
2. Two "won" definitions coexist: `Forecast Type` (stage list) vs
   `Probability = 100` (query tables). They disagree for any deal whose stage
   is in the Won list but probability ≠ 100 (and vice versa).
3. Pipeline-hours factor inconsistency: WERP uses `ER × .33 / 100`; the
   Potentials formula column "Pipeline in labor hours" uses `ER × 0.3 / 100`.
   The dashboard reads the `.33` version.
4. Invoice `Age Tier` bucket 1 is labeled "0 - 30 days" but its condition is
   `Age in Days <= 20`; ages measure from **Invoice Date**, not Due Date.
5. "Paid Revenue" (Widget 3) has no payment/status condition (see above).
6. `RMR Sales Run Rate` (Potentials aggregate variant) has an
   always-true OR chain (`!= 'Opt Out' or != null or != 'Existing Subscriber'`)
   — the widget uses the WERP variant instead, but don't reconcile against
   this one.

## Sync cadence (tolerance windows for totals comparisons)

Zoho CRM → Analytics every 3h (Eastern); Zoho Finance → Analytics every 3h
(GMT); warehouse ingests daily at 06:00–06:40 UTC. Any totals comparison
should pin an as-of time and tolerate up to one warehouse cycle + one Zoho
sync (~27h worst case) of drift; prefer comparing periods closed ≥ 48h ago.
