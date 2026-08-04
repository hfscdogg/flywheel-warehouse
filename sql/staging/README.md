# sql/staging/ — Phase 3 (raw → staging)

Placeholder. No SQL until Phase 3.

Conventions (from [docs/conventions.md](../../docs/conventions.md)):

- One model per source entity: `stg_<source>__<entity>` (e.g.
  `stg_zoho__deals`, `stg_qbo__invoices`).
- Staging is where dedup, type casting, renaming, and latest-record selection
  happen — the `raw_*` loaders stay append-only and dumb.
- Staging tables are readable by `ingest-writer` only; agents never see them.
