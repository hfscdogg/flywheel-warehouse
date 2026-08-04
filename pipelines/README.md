# pipelines/ — Phase 2 (ingestion)

Scheduled pulls from Zoho CRM, D-Tools Cloud, and QuickBooks Online into the
`raw_*` datasets. One GitHub Actions workflow per source
(`.github/workflows/ingest-*.yml`): cron-scheduled (06:00/06:20/06:40 UTC),
manually triggerable via `workflow_dispatch`, one `concurrency` group per
source+client so runs never overlap.

## How a run works

1. **Auth to GCP:** Workload Identity Federation — the workflow's GitHub OIDC
   token is exchanged for `ingest-writer` credentials
   (`google-github-actions/auth@v2`). No key files anywhere.
2. **Source credentials:** read at runtime from **Secret Manager in the
   client's project** (`flywheel-*` secrets). GitHub holds no client secrets
   — only two non-sensitive repo *variables* (`WIF_PROVIDER`,
   `WIF_SERVICE_ACCOUNT`). Setup: `scripts/05-ingestion-infra.sh`, then
   [docs/phase-2-credentials.md](../docs/phase-2-credentials.md).
3. **Load pattern:** append-only landing tables, one per source entity, full
   record as a JSON `payload` column plus `_source_id`, `_modified_at`,
   `_loaded_at`, `_run_id`. Partitioned on `_loaded_at`, clustered on
   `_source_id`. Dedup/latest-record logic belongs in `staging` (Phase 3).
4. **Incremental:** per-entity watermarks in `raw_<source>._flywheel_state`
   (append-only; latest row wins). Zoho uses `If-Modified-Since`; QBO filters
   on `MetaData.LastUpdatedTime`; D-Tools full-pulls every run (small data).
   `--full-refresh` ignores watermarks.

## Sharp edges handled

- **QBO rotates refresh tokens.** Each refresh can return a new token and
  kill the old one. `qbo/ingest.py` writes the new token back to Secret
  Manager immediately (`ingest-writer` has `secretVersionAdder` on that one
  secret). This is why credentials live in Secret Manager, not GitHub.
- **Zoho data centers.** The token endpoint depends on the tenant's region
  (`ZOHO_ACCOUNTS_HOST`, default `accounts.zoho.com`); record calls follow
  the `api_domain` the token response returns.
- **D-Tools endpoints are VERIFY-on-first-run.** Paths/pagination in
  `lib/sources.py` are best-effort; the fetcher is generic, so a wrong path
  is a one-line fix in `sources.py`.

## Layout

```
lib/util.py       pure helpers (env parsing, row building, watermarks) — stdlib only
lib/config.py     loads clients/<slug>/client.env; per-client source enablement
lib/sources.py    per-source settings: entities, fields, pagination
lib/bq.py         landing tables, loads, watermark state   (imports google-cloud-bigquery)
lib/secret_store.py  Secret Manager read/write             (imports google-cloud-secret-manager)
lib/web.py        requests session with retry/backoff
lib/runner.py     shared run scaffolding (args, logging, land+watermark)
zoho/ dtools/ qbo/   one ingest.py per source
tests/            stdlib-only unit tests (run in CI without pip installs)
```

## Running locally

```sh
pip install -r pipelines/requirements.txt
gcloud auth application-default login   # or impersonate ingest-writer
python -m pipelines.zoho.ingest --client livewire --dry-run   # plan only
python -m pipelines.zoho.ingest --client livewire --limit 25  # smoke run
```

A client without a given source simply omits `raw_<source>` from
`DATASETS_RAW` — the pipeline exits 0 with "source disabled".
