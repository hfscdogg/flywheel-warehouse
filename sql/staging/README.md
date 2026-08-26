# sql/staging/ — Phase 3 (raw → staging)

One model per source entity, `stg_<source>__<entity>.sql`. Each is a plain
`CREATE OR REPLACE TABLE staging.<name> AS …` statement that:

- picks the **latest record** per `_source_id` from the append-only landing
  table (`ROW_NUMBER()` over `_modified_at DESC, _loaded_at DESC`),
- extracts typed columns from the JSON `payload` (`SAFE_CAST` everywhere —
  a malformed value becomes NULL, never a failed build),
- keeps `loaded_at` for lineage.

Dataset names are unqualified (`raw_zoho.deals`, `staging.stg_zoho__deals`):
`bq query --project_id` resolves them against the client's project, so one
SQL tree serves every client with zero templating.

Run via [`scripts/06-transform.sh`](../../scripts/06-transform.sh) (staging
then marts); the `transform` workflow runs it daily at 07:00 UTC, after the
ingests. Models for a source missing from the client's `DATASETS_RAW` are
skipped, mirroring the pipelines' "source disabled" behavior.

## Models

| Source | Models |
|--------|--------|
| Zoho CRM | `stg_zoho__leads`, `stg_zoho__contacts`, `stg_zoho__accounts`, `stg_zoho__deals` |
| Zoho Billing | `stg_zohobilling__subscriptions`, `stg_zohobilling__customers` |
| D-Tools Cloud | `stg_dtools__opportunities`, `stg_dtools__quotes`, `stg_dtools__projects` |
| QuickBooks Online | `stg_qbo__customers`, `stg_qbo__vendors`, `stg_qbo__items`, `stg_qbo__accounts`, `stg_qbo__estimates`, `stg_qbo__invoices`, `stg_qbo__bills`, `stg_qbo__payments`, `stg_qbo__purchase_orders` |

**D-Tools field paths are best-effort** (same VERIFY-on-first-run posture as
`pipelines/lib/sources.py`): the JSON paths were written from the API docs,
not observed payloads. An all-NULL column after the first live run means a
wrong path — a one-line `COALESCE` fix in the model.

The same posture applies to the **Zoho custom-field API names** in
`stg_zoho__deals` (`Commercial`, `Alarm_Monitoring_Plan`,
`Pick_Service_Plan`, `Marketing_Channel`): derived from the CRM display
names, unverified against a live payload.

## Access

Staging tables are readable by `ingest-writer` only; agents never see them
(`hermes-reader` is scoped to `marts`).

## Coming: GA4 (attribution)

The GA4 → BigQuery native export lands Google-managed `events_YYYYMMDD` and
`pseudonymous_users_YYYYMMDD` tables in an `analytics_<property_id>` dataset
(linked 2026-08-24; first tables ~24h later). Once the property id is known,
`stg_ga4__*` models go here — first-touch acquisition per visitor, joined to
Zoho leads on captured `gclid`/UTM fields for end-to-end attribution.
