# Cutover log: livewire, 2026-10-18

Runbook: [runbook-identity-cutover.md](runbook-identity-cutover.md), steps 1 to 5.
Operator: henry@getlivewire.com. Scripts run in Google Cloud Shell; GitHub side
(variables, workflow dispatch) via the GitHub connector. Steps 7 to 9 are out
of scope until one green nightly cycle.

## Preconditions

- Repo `main` at `6651fd9` (SoundVision fix PR #103 merged).
- Claude Code container: no gcloud credentials and an invalid `GH_TOKEN`, so
  owner-level GCP commands run in Cloud Shell instead.
- Cloud Shell, 14:45 local:
  - `gcloud auth list`: active account `henry@getlivewire.com`
  - `gcloud config get-value project`: `livewire-dw`
- Open question before step 2: the scripts create and grant on `hermes-reader`
  and `hermes-mcp`. Nothing references `station-reader`. Awaiting decision.

## Step 1: accounts and grants

- Cloud Shell had a stale `~/flywheel-warehouse` from before #103 (no cutover
  scripts). `git pull --ff-only origin main` fast-forwarded it: 59 files
  changed, including `docs/runbook-identity-cutover.md`,
  `scripts/11-retire-ingest-writer.sh`, `pipelines/lib/readonly_sql.py`. HEAD
  now at #107 (`fix: the IAM audit writes its inventory outside the repo`).
- Note: under `DRY_RUN=1`, `probe` always reports "absent", so 02's plan shows
  every account as "creating". The real state comes from
  `gcloud iam service-accounts list`.

- Cloud Shell, 14:52: `git rev-parse --short HEAD` → `6651fd9`. No tracked
  files modified. Untracked: `Transform`, `audit.sh`,
  `leak_highest_confidence.csv`. No script or workflow references them.
- Existing service accounts in livewire-dw (all enabled):
  `ingest-writer`, `711707450526-compute@developer`, `hermes-reader`,
  `station-reader`, `endpoint-builder`, `endpoint-deployer`, `kitchen-runner`.
  None of the 8 new accounts exist yet. `station-reader` and `kitchen-runner`
  are not managed by any script in this repo.
- `DRY_RUN=1 ./scripts/02-service-accounts.sh livewire`: plans `create` for
  ingest-zoho, ingest-zohobilling, ingest-dtools, ingest-qbo, ingest-vendor,
  ingest-alarmdotcom, transform-writer, warehouse-reader. Nothing else.
  On the real run `hermes-reader` already exists, so 02 only updates its display
  name.

## Decision: Hermes is out (Henry, 14:55)

Hermes is not to be used for anything Flywheel-related. Consequences for this
cutover:

- `03-iam.sh` re-applies three `hermes-reader` grants (project `jobUser`,
  `dataViewer` on the agent datasets, Henry's `serviceAccountTokenCreator`).
  It runs only if a read-only check shows all three already exist, so it adds
  nothing new for Hermes.
- `05` and `09` don't reference Hermes and run as written.
- Not running: `10-endpoint-deployer.sh` (grants `endpoint-deployer` rights on
  `hermes-mcp` and `hermes-reader`) and step 5 `deploy-endpoint` (redeploys
  `hermes-mcp`).
- Left open as a result: the endpoint half of finding 1 (the new read-only
  check in `hermes-mcp`'s `server.py`), and `endpoint-deployer`'s repo-wide
  WIF binding (finding 3), which `10` would have pinned. Both go away when
  `hermes-mcp`, `hermes-reader` and `endpoint-deployer` are decommissioned. That
  is a revoke/delete and is not part of today's scope.

### 02 real run (about 18:53Z): FAILED partway

The output scrolled off in Cloud Shell. Recovered from the account list and
Cloud Audit Logs (`CreateServiceAccount`, severity ERROR, last 30 min):

```
2026-10-18T18:53:30.044Z  ingest-vendor       A quota has been reached for project number 711707450526: Service accounts created per minute per project.
2026-10-18T18:53:35.712Z  ingest-alarmdotcom  (same)
2026-10-18T18:53:37.416Z  ingest-alarmdotcom  (same)
2026-10-18T18:53:42.120Z  ingest-alarmdotcom  (same)
2026-10-18T18:53:48.377Z  ingest-alarmdotcom  (same)
2026-10-18T18:54:08.206Z  ingest-alarmdotcom  (same)
```

- Created: ingest-zoho, ingest-zohobilling, ingest-dtools, ingest-qbo,
  ingest-vendor (succeeded after gcloud's retry).
- Not created: ingest-alarmdotcom (gave up after 5 quota errors),
  transform-writer and warehouse-reader (not attempted; the script stops on the first error).
- Diagnosis: the project's per-minute limit on service-account creation. Six
  creates in one minute crossed it. Not a permissions or config fault. Nothing
  was half-made: the missing accounts don't exist at all, and the ones created have no grants yet.
  Nightly pipelines are unaffected (still on `ingest-writer`).

Hermes grant check before 03 (read-only): `hermes-reader` has `READER` on
`marts` and `staging` and `roles/bigquery.jobUser` on the project, and
`henry@getlivewire.com` has `serviceAccountTokenCreator` on it. 03 would
converge all three without change.

03 dry run reviewed in full. Additive only, and matches trust.md: each `ingest-*`
gets `jobUser` + `dataEditor` on its own `raw_<source>`; `transform-writer`
gets `dataViewer` on every raw dataset and `dataEditor` on staging and marts;
`warehouse-reader` gets `jobUser` + `dataViewer` on every dataset.

- Henry approved re-running 02 unchanged (about 19:00Z).

### 02 re-run (about 19:01Z): OK

```
==> creating service account ingest-alarmdotcom
Created service account [ingest-alarmdotcom].
  ...attempt 1/12 failed; retrying in 5s      (visibility wait, expected)
==> creating service account transform-writer
Created service account [transform-writer].
==> creating service account warehouse-reader
Created service account [warehouse-reader].
  ...attempt 1/12 failed; retrying in 5s
==> Service accounts done.
```

Non-compute account count: 14 (6 before + 8 new). Full output in Cloud Shell
`~/02-sa-livewire-rerun.log`.

### 03 (about 19:05Z): OK, step 1 complete

Full output in Cloud Shell `~/03-iam-livewire.log`. Grants applied:

- `hermes-reader`: `already has roles/bigquery.dataViewer on marts`, same on
  `staging` (converging, no change). Project `jobUser` and Henry's
  `serviceAccountTokenCreator` were confirmed present before the run, so
  `add-iam-policy-binding` was a no-op. **Nothing new granted to Hermes.**
- `ingest-zoho`, `-zohobilling`, `-dtools`, `-qbo`, `-vendor`, `-alarmdotcom`:
  `granted roles/bigquery.dataEditor` on their own `raw_<source>` only (plus
  project `jobUser`).
- `transform-writer`: `dataViewer` on raw_zoho, raw_zohobilling, raw_dtools,
  raw_qbo, raw_vendor, raw_alarmdotcom, raw_ga4, raw_google_ads,
  analytics_285482813; `dataEditor` on staging, marts.
- `warehouse-reader`: `dataViewer` on all of the above plus staging and marts.
  No write.
- Ended `==> IAM done.`

## Step 2: trust and secrets

### Pre-check of WIF (about 19:07Z, read-only)

Pool `flywheel-github` has two providers:

| Provider | Condition | Mapping |
|---|---|---|
| `github` | `assertion.repository == 'hfscdogg/flywheel-warehouse'` | `google.subject`, `attribute.repository` |
| `github-kitchen` | `assertion.repository == 'hfscdogg/flywheel-kitchen' && assertion.ref == 'refs/heads/main'` | `google.subject`, `attribute.repository`, `attribute.ref`, `attribute.job_workflow_ref` |

Pool principals bound on service accounts (none at project level):

- `ingest-writer`: `attribute.repository/hfscdogg/flywheel-warehouse`
- `endpoint-deployer`: `attribute.repository/hfscdogg/flywheel-warehouse`
- `kitchen-runner`: `attribute.job_workflow_ref/hfscdogg/flywheel-kitchen/.github/workflows/weekly-brief.yml@refs/heads/main`

What 05's `update-oidc github` will do:

- Touches the `github` provider only. `github-kitchen` and `kitchen-runner`
  are untouched. The new warehouse `job_workflow_ref` values all start with
  `hfscdogg/flywheel-warehouse/`, so they cannot match kitchen's binding and kitchen's cannot match ours.
- Adds `attribute.ref` and `attribute.job_workflow_ref` to the mapping and
  keeps `attribute.repository`, so `ingest-writer`'s and `endpoint-deployer`'s
  repo-wide bindings keep matching.
- Adds `assertion.ref == 'refs/heads/main'`. Every warehouse workflow that
  authenticates to Google is `schedule` + `workflow_dispatch` only (lint.yml,
  the only `push`/`pull_request` workflow, does not authenticate). Scheduled
  runs use the default branch, `main`. Only dispatches from other branches lose
  access, as the runbook intends.

### 05 dry run (about 19:09Z)

Henry approved the 05 dry run and the trust narrowing it applies.

- Provider values match: mapping `google.subject, attribute.repository,
  attribute.ref, attribute.job_workflow_ref`; condition
  `assertion.repository == 'hfscdogg/flywheel-warehouse' && assertion.ref == 'refs/heads/main'`.
  The dry run prints `create`/`create-oidc` because `probe` reports "absent" under
  DRY_RUN. On the real run the existing pool is left alone and the provider takes
  the `update-oidc` path.
- `secretVersionAdder` planned on `flywheel-dtools-v2-refresh-token`
  (ingest-dtools) and `flywheel-qbo-refresh-token` (ingest-qbo) only.
- Existing secrets (read-only list): all 16 `flywheel-*` secrets 05 expects are
  present, so nothing will be created empty. Also present:
  `hermes-endpoint-token`, which 05 does not touch. It goes on the Hermes
  decommission list.

### 05 real run (about 19:12Z): OK

Full output in Cloud Shell `~/05-infra-livewire.log`. Tail:

- Each source: `trusted workflow: <file>.yml` then `Updated IAM policy for
  serviceAccount [ingest-<source>@…]`; `secret flywheel-… exists` then
  `Updated IAM policy for secret [flywheel-…]` (secretAccessor, own source only).
- `rotation writeback: may add versions of flywheel-qbo-refresh-token` (and
  dtools-v2).
- `transform.yml: transform-writer` and `probe.yml: warehouse-reader` bound.
- `==> Phase 2 infra done.` No secrets created.
- Printed variables: `WIF_PROVIDER` =
  `projects/711707450526/locations/global/workloadIdentityPools/flywheel-github/providers/github`,
  plus the 8 `WIF_SA_*` values matching the runbook.

Note: Henry asked whether Claude could run the commands directly. Claude
started a gcloud sign-in in its container before Henry had agreed. The
session's permission guard blocked it, so nothing was authenticated. All GCP
commands continue in Cloud Shell.

### Provider readback (about 19:15Z)

- `~/05-infra-livewire.log`: `==> provider exists — converging mapping and condition` (took the `update-oidc` path).
- `providers list`:
  - `github`: `assertion.repository == 'hfscdogg/flywheel-warehouse' && assertion.ref == 'refs/heads/main'`
  - `github-kitchen`: `assertion.repository == 'hfscdogg/flywheel-kitchen' && assertion.ref == 'refs/heads/main'` (unchanged)

### 09 (about 19:15Z): OK

- `bucket exists`, `==> ingest-vendor: read and archive uploads`, no "could
  not create" warnings. Full output in Cloud Shell `~/09-vendor-livewire.log`.
- `gsutil iam get gs://livewire-dw-vendor-drops`: `ingest-vendor` now sits in the same role
  binding as `ingest-writer`. `ingest-writer` keeps its access until step 8.
- All six upload prefixes have their `.keep`. Pre-existing and left alone:
  `processed/…/2026-08-31T19:25:4x-.keep` files archived in August, before the
  zero-byte placeholder fix.

### 10: skipped (Hermes out of scope, see decision above)

**Step 2 complete except `10`.**

## Step 3: repository variables

- Cloud Shell `gh auth status`: logged in to github.com as `hfscdogg`.
- Workflows read `vars.WIF_SA_<X> || vars.WIF_SERVICE_ACCOUNT`, so an unset
  variable falls back to `ingest-writer`. `ingest-dtools` and `ingest-dtools-v2` share
  `WIF_SA_INGEST_DTOOLS`; `ingest-qbo` and `ingest-qbo-reports` share
  `WIF_SA_INGEST_QBO`. `WIF_PROVIDER` is read by 11 workflows.

- `gh variable list` before (about 19:17Z): `WIF_DEPLOYER_SERVICE_ACCOUNT`
  (endpoint-deployer@…, ~1 month), `WIF_PROVIDER` (projects/711707450526/…,
  ~2 months), `WIF_SERVICE_ACCOUNT` (ingest-writer@…, ~2 months),
  `ZOHOBILLING_CUSTOMER_DETAIL` (1), `ZOHO_BILLING_ORG_ID` (42411013). No
  `WIF_SA_*` set.

### Set (about 19:18Z, Cloud Shell, gh as hfscdogg): OK

```
✓ Created variable WIF_SA_INGEST_ZOHO for hfscdogg/flywheel-warehouse
✓ Created variable WIF_SA_INGEST_ZOHOBILLING for hfscdogg/flywheel-warehouse
✓ Created variable WIF_SA_INGEST_DTOOLS for hfscdogg/flywheel-warehouse
✓ Created variable WIF_SA_INGEST_QBO for hfscdogg/flywheel-warehouse
✓ Created variable WIF_SA_INGEST_VENDOR for hfscdogg/flywheel-warehouse
✓ Created variable WIF_SA_INGEST_ALARMDOTCOM for hfscdogg/flywheel-warehouse
✓ Created variable WIF_SA_TRANSFORM for hfscdogg/flywheel-warehouse
✓ Created variable WIF_SA_PROBE for hfscdogg/flywheel-warehouse
WIF_DEPLOYER_SERVICE_ACCOUNT=endpoint-deployer@livewire-dw.iam.gserviceaccount.com
WIF_PROVIDER=projects/711707450526/locations/global/workloadIdentityPools/flywheel-github/providers/github
WIF_SA_INGEST_ALARMDOTCOM=ingest-alarmdotcom@livewire-dw.iam.gserviceaccount.com
WIF_SA_INGEST_DTOOLS=ingest-dtools@livewire-dw.iam.gserviceaccount.com
WIF_SA_INGEST_QBO=ingest-qbo@livewire-dw.iam.gserviceaccount.com
WIF_SA_INGEST_VENDOR=ingest-vendor@livewire-dw.iam.gserviceaccount.com
WIF_SA_INGEST_ZOHO=ingest-zoho@livewire-dw.iam.gserviceaccount.com
WIF_SA_INGEST_ZOHOBILLING=ingest-zohobilling@livewire-dw.iam.gserviceaccount.com
WIF_SA_PROBE=warehouse-reader@livewire-dw.iam.gserviceaccount.com
WIF_SA_TRANSFORM=transform-writer@livewire-dw.iam.gserviceaccount.com
WIF_SERVICE_ACCOUNT=ingest-writer@livewire-dw.iam.gserviceaccount.com
```

**Step 3 complete.** Undo for any one workflow: `gh variable delete WIF_SA_<X>`
(it falls back to `ingest-writer`).

## Step 4: run each workflow from main

Dispatched by Claude through the GitHub connector, on `main`, with default inputs
(client `livewire`, no full refresh).

### Ingest runs (dispatched 19:18Z, commit `6651fd9`)

Provider in every auth step:
`projects/711707450526/locations/global/workloadIdentityPools/flywheel-github/providers/github`.
"ingest-writer" appears in none of the job logs.

| Run | Workflow | Result | Authenticated as | Evidence |
|---|---|---|---|---|
| 39158194019 | ingest-zoho | success | `ingest-zoho@livewire-dw.iam.gserviceaccount.com` | `done: 7 rows total` |
| 39158196201 | ingest-zohobilling | success | `ingest-zohobilling@…` | `done: 8381 rows total` |
| 39158200016 | ingest-dtools-v2 | success | `ingest-dtools@…` | `done: 32 rows total`; wrote rotated refresh token to Secret Manager |
| 39158201816 | ingest-qbo | success | `ingest-qbo@…` | `Invoice: loaded 1 rows into livewire-dw.raw_qbo.invoice` |
| 39158203642 | ingest-qbo-reports | success | `ingest-qbo@…` | `done: 14586 rows total (2023-01-01 to 2026-10-18, Accrual)` |
| 39158205378 | ingest-alarmdotcom | success | `ingest-alarmdotcom@…` | `ALARMDOTCOM_DEALER_ID is not set ... nothing to pull` (no load) |
| 39158207121 | ingest-vendordrop | success | `ingest-vendor@…` | `no new files in gs://livewire-dw-vendor-drops — nothing to do` |
| 39158197918 | ingest-dtools | success (19:45:52Z) | `ingest-dtools@…` | `done: 7713 rows total` (opportunities 2778, quotes 3285, projects 1650) |

Caveat: alarmdotcom and vendordrop authenticated but wrote nothing, so their
write and secret-read grants are not yet proven by a real load.

All 8 ingests green on their own accounts. transform dispatched 19:50Z (run 39160563424).

### transform (run 39160563424, 19:50Z to 20:02Z): built, red on freshness only, as agreed

```
Replaced livewire-dw.marts.kpi_website_traffic          (and every other mart)
==> Transform: every agent-readable table described
  every mart table and column is described
==> Transform: QuickBooks' reports tie to each other
  QuickBooks' reports agree with each other in every month
==> Transform: every source loaded recently enough to answer from
WARN: sources older than their own cadence allows
    stg_vendor__securitycentral_accounts,2026-08-27,52,45,...
    stg_vendor__alarmdotcom_accounts,2026-08-31,48,45,...
    stg_vendor__parasol_accounts,2026-08-31,48,45,...
    stg_vendor__securitycentral_status,2026-09-28,20,14,...
WARN: the marts above were BUILT and are correct for what has landed
ERROR: a stale source answers confidently and wrongly; this is why it is red
```

The only error is the freshness check (#104, vendor uploads, owned by Henry). This
meets the agreed definition: authenticated and built the marts.

### Probes (probe.yml, run one at a time; the concurrency group holds one pending run)

Auth step: `service_account: warehouse-reader@livewire-dw.iam.gserviceaccount.com`.
"ingest-writer" appears in none of the four logs.

**1. `SELECT 1`**: run 39161598430, success
```
project: livewire-dw
statement accepted: BigQuery reads it as a single SELECT
[
  {
    "f0_": 1
  }
]
```

**2. `DELETE FROM marts.kpi_sales_pipeline WHERE FALSE`**: run 39161671565, failed at the dry run
```
google.api_core.exceptions.Forbidden: 403 POST https://bigquery.googleapis.com/bigquery/v2/projects/livewire-dw/jobs?prettyPrint=false: Access Denied: Table livewire-dw:marts.kpi_sales_pipeline: Permission bigquery.tables.updateData denied on table livewire-dw:marts.kpi_sales_pipeline (or it may not exist).
Job ID: 1ac40577-6227-43c4-a070-bc65046f2665
##[error]Process completed with exit code 1.
```

**3. `SELECT '/*'; DROP TABLE marts.kpi_sales_pipeline; SELECT '*/'`** (SoundVision's bypass): run 39161748750, failed at the dry run
```
google.api_core.exceptions.BadRequest: 400 POST https://bigquery.googleapis.com/bigquery/v2/projects/livewire-dw/jobs?prettyPrint=false: Access Denied: Table livewire-dw:marts.kpi_sales_pipeline: Permission bigquery.tables.delete denied on table livewire-dw:marts.kpi_sales_pipeline (or it may not exist). at [1:14]
Job ID: f3ee5f5a-632e-4e81-b3db-9c5071e25d8c
##[error]Process completed with exit code 1.
```
BigQuery parsed it as a multi-statement script, and the dry run was refused by IAM
before the read-only classifier ran. This is the runbook's second expected outcome
("BigQuery's own access-denied error for warehouse-reader"). Nothing was written.

**4. Afterwards, `SELECT COUNT(*) AS n FROM marts.kpi_sales_pipeline`**: run 39161851451, success
```
statement accepted: BigQuery reads it as a single SELECT
[
  {
    "n": 190
  }
]
```
`marts.kpi_sales_pipeline` is intact.

**Step 4 complete.**

## Step 5: skipped (Hermes out of scope, see decision above)

## Status at end of day

- Done: steps 1 to 4. Script 10 and step 5 were skipped because Hermes is out of scope.
- Waiting: the 2026-10-19 06:00 to 07:00 UTC nightly cycle on the new accounts. "Green"
  means every run authenticates on its new account and transform builds its marts.
  Freshness (#104) is excluded.
- Then: steps 7 to 9 (credential rotation, retire `ingest-writer`, 90-verify), each with
  Henry's approval before anything is revoked or rotated.
- Not yet proven by a real load: `ingest-alarmdotcom` (no dealer ID set) and
  `ingest-vendor` (no new files) authenticated but wrote nothing.
- Follow-ups: decommission Hermes (`hermes-mcp`, `hermes-reader`, `endpoint-deployer`,
  `hermes-endpoint-token`); merge PRs #109 and #110 after the nightly, then port them to the template.

## Decisions (Henry, about 19:30Z)

- **"One green nightly cycle"** for steps 7 to 9 means every workflow authenticates
  on its new account and transform builds its marts. Transform's freshness
  check stays red until four vendor reports are uploaded (issue #104), and that
  does not block the cutover.
- **PR #96** stays a draft until after tomorrow's nightly. Then it is brought up
  to date with main and marked ready for review.
- **PR #105** gets split: a supply-chain PR (merge after the nightly) and a
  lifecycle-script PR whose WIF cleanup is limited to this repo's provider, so
  `github-kitchen` and `kitchen-runner` are never touched. #105 itself is left as is.
- Issues #98 and #102 were closed. Both had passed every scheduled run since their
  single failure.

## Communication

- 2026-10-18 about 20:20Z: Henry approved and Claude posted the status update to Slack
  #all-flywheel (Mark, Chris). It covers steps 1 to 4, the probe results, what this means for
  template builds, and the next steps. The evidence log was offered on request because the
  partners have access to the template repo only, by design.
