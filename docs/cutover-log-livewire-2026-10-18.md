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

_Pending: provider readback (the `update-oidc` line scrolled off), then 09._
