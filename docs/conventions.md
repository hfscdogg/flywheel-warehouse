# Conventions

Decided once, here, so later phases don't re-litigate them.

## Service accounts

Role-based short names — client identity is carried by the project, not the
SA name:

- `hermes-reader@<project>.iam.gserviceaccount.com` — agents; read `marts` only
- `ingest-writer@<project>.iam.gserviceaccount.com` — pipelines; write raw,
  build staging/marts

Future SAs follow `<consumer>-<verb>` (e.g. `transformer-runner` if Phase 3
splits transformation from ingestion).

## Datasets

Fixed names, one project per client: `raw_<source>` (one per source system),
`staging`, `marts`. A client on different sources changes `DATASETS_RAW` in
their `client.env` — nothing else.

## Tables

- `_flywheel_*` prefix is reserved for infrastructure tables (canaries, audit).
- Phase 3 staging models: `stg_<source>__<entity>` (e.g. `stg_zoho__deals`).
- Phase 3 marts: `kpi_<domain>` (e.g. `kpi_sales_pipeline`), one table per KPI
  family, shaped for direct agent consumption.

## Labels

Every dataset (and, recommended, the project itself) carries:

```
managed-by=flywheel
client=<slug>
env=prod
```

GCP label keys/values allow only lowercase letters, digits, `-`, `_`. The
client-slug validation in `scripts/lib/common.sh` guarantees compliance.

## Scripts

- Numbered in run order: `00–09` preflight/read-only, `01–49` create/converge,
  `90–98` verify, `99` teardown.
- Bash, `set -euo pipefail`, bash-3.2 compatible (macOS default shell — no
  associative arrays, no `mapfile`). `03-iam.sh` additionally requires
  `python3` (JSON handling for dataset access entries).
- Client slug is always required positional argument #1.
- Every `gcloud` call passes `--project`; every `bq` call passes
  `--project_id` and `--headless=true`. Never rely on `gcloud config`.
- Idempotency by check-then-converge (`describe`/`show`, then create or
  update) — never `--force`, which masks drift.
- `DRY_RUN=1` prints the full command plan without executing or requiring the
  SDK.

## bq sharp edges worth remembering

- Labels use colon form in both places: `bq mk` takes repeated
  `--label key:value` and `bq update` takes repeated `--set_label key:value`
  (verified against bq 2.1.36, which rejects `--label key=value`).
- `bq mk` on an existing dataset exits 1; `bq mk --force` exits 0 but silently
  skips (which is why we don't use it).
- `bq add-iam-policy-binding` / `bq get-iam-policy` on a **dataset** require
  Google allowlisting ("This feature requires allowlisting"). Dataset-level
  grants therefore go through **access entries** instead: `bq show` the
  dataset JSON, append to the `access` array, `bq update --source` — see
  `grant_dataset_role` in `scripts/03-iam.sh`. BigQuery normalizes premium
  roles to legacy names in that array (`dataViewer`→`READER`,
  `dataEditor`→`WRITER`, `dataOwner`→`OWNER`), so converge checks must accept
  both forms. Reads (verification) use `bq show` on the same array.
