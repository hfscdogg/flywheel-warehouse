# sql/marts/ — Phase 3 (KPI marts)

Placeholder. No SQL until Phase 3.

Conventions (from [docs/conventions.md](../../docs/conventions.md)):

- One table per KPI family: `kpi_<domain>` (e.g. `kpi_sales_pipeline`,
  `kpi_project_margin`, `kpi_cash`).
- Shaped for direct agent consumption: pre-aggregated, documented columns,
  no joins required to answer the KPI question. Every Flywheel engine gets a
  scoreboard table it can't argue with.
- `marts` is the **only** dataset `hermes-reader` can see — keep anything not
  meant for agents out of it.
- `_flywheel_canary` lives here (created by `scripts/01-datasets.sh`) so
  access can be verified before real marts exist.
