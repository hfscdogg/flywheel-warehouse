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

_Pending: real run of 02._
