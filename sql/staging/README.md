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
skipped, mirroring the pipelines' "source disabled" behavior. A model whose
raw table does not exist yet is skipped too — a source can be enabled before
its first successful pipeline run (new source, or one still waiting on
credentials), and one missing table must not take the whole transform, marts
included, down with it. A mart whose staging inputs were skipped for that
reason is skipped in turn; the transform derives each mart's inputs from the
`staging.*` references in its own SQL, so there is no dependency list to keep
in step.

## Models

| Source | Models |
|--------|--------|
| Zoho CRM | `stg_zoho__leads`, `stg_zoho__contacts`, `stg_zoho__accounts`, `stg_zoho__deals` |
| Zoho Billing | `stg_zohobilling__subscriptions`, `stg_zohobilling__customers` |
| Monitoring vendors | `stg_vendor__securitycentral_accounts` (address roster), `stg_vendor__securitycentral_status` (weekly status feed) — both from uploaded report files, see [docs/vendor-reports.md](../../docs/vendor-reports.md) |
| Alarm.com | `stg_alarmdotcom__customers` (Partner Portal API, scheduled pipeline) |
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

**Security Central is two feeds, not one.** The central station can schedule
its "Customer Count" report weekly but not the "All Accounts" export, and only
All Accounts carries a street address. So `stg_vendor__securitycentral_status`
holds the current status (refreshed weekly) and
`stg_vendor__securitycentral_accounts` holds the addresses (refreshed on
request); `kpi_subscription_audit` joins them on contract number. Verified
against the 2026-08-27 files: 586/586 roster contracts present in the weekly
feed, plus 2 accounts the weekly feed has and the roster doesn't.

**Zoho Billing subscription paths are verified** (first live run 2026-08-27,
2,209 subscriptions): plan fields sit at the top level of the LIST response,
not under a nested `$.plan` object — that only appears on the
per-subscription GET. Sparse date columns (`next_billing_at`,
`cancelled_at`, `expires_at`) are correct: they exist only for subscriptions
in the matching state.

**Zoho Billing customers come from the per-customer GET, not the list.** The
list endpoint returns no `billing_address` object at all — verified
2026-08-30, 0 of 34,248 landed rows had one — so
`stg_zohobilling__customers`' address columns were entirely NULL and
`kpi_subscription_audit` reported all 522 active vendor accounts as
`BILLED_NO_MATCH`. That reads like 522 unbilled customers and is really an
empty join side. `pipelines/zohobilling/ingest.py` now uses the list only to
enumerate ids and lands the per-customer GET, re-fetching only customers
modified since the stored watermark. The address paths themselves are
**VERIFY-on-first-run** against a detail payload.

## Access

Staging tables are readable by `ingest-writer` only; agents never see them
(`hermes-reader` is scoped to `marts`).

## Coming: GA4 (attribution)

The GA4 → BigQuery native export lands Google-managed `events_YYYYMMDD` and
`pseudonymous_users_YYYYMMDD` tables in an `analytics_<property_id>` dataset
(linked 2026-08-24; first tables ~24h later). Once the property id is known,
`stg_ga4__*` models go here — first-touch acquisition per visitor, joined to
Zoho leads on captured `gclid`/UTM fields for end-to-end attribution.
