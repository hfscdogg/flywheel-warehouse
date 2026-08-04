# pipelines/ — Phase 2 (ingestion)

Placeholder. Phase 2 builds scheduled pulls from Zoho CRM, D-Tools Cloud, and
QuickBooks Online into the `raw_*` datasets, following the same GitHub Actions
pattern as Intel Engine: one workflow per source, cron-scheduled, manually
triggerable.

## Design (settled now so Phase 2 starts from decisions, not debates)

- **One workflow per source** (`zoho.yml`, `dtools.yml`, `qbo.yml`), each with
  `schedule:` cron + `workflow_dispatch:` for manual runs, and a
  `concurrency:` group per source so runs never overlap.
- **Auth to GCP: Workload Identity Federation, never key files.** The workflow
  exchanges its GitHub OIDC token for `ingest-writer` credentials via
  `google-github-actions/auth@v2`.
- **Source-system credentials** (Zoho/D-Tools/QBO OAuth tokens) live in GitHub
  Environment secrets. The one-time OAuth consent clicks are a human step —
  credential grants stay with Henry.
- **Load pattern:** append-only landing tables in `raw_*`, one per source
  entity, with `_loaded_at` timestamps. Dedup/latest-record logic belongs in
  `staging` (Phase 3), not in the loader.

## One-time WIF setup (run in Phase 2, per client)

```sh
PROJECT=livewire-dw
REPO=<github-org>/flywheel-warehouse    # set to this repo's actual org/name

gcloud iam workload-identity-pools create flywheel-github \
  --project="$PROJECT" --location=global \
  --display-name="Flywheel GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc github \
  --project="$PROJECT" --location=global \
  --workload-identity-pool=flywheel-github \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository == '$REPO'"

POOL_ID=$(gcloud iam workload-identity-pools describe flywheel-github \
  --project="$PROJECT" --location=global --format='value(name)')

gcloud iam service-accounts add-iam-policy-binding \
  "ingest-writer@$PROJECT.iam.gserviceaccount.com" \
  --project="$PROJECT" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/$POOL_ID/attribute.repository/$REPO"
```

## Example workflow shape (commented until Phase 2)

```yaml
# name: ingest-zoho
# on:
#   schedule:
#     - cron: "0 6 * * *"        # daily 06:00 UTC
#   workflow_dispatch:
# concurrency:
#   group: ingest-zoho
#   cancel-in-progress: false
# permissions:
#   contents: read
#   id-token: write              # required for WIF
# jobs:
#   ingest:
#     runs-on: ubuntu-latest
#     steps:
#       - uses: actions/checkout@v4
#       - uses: google-github-actions/auth@v2
#         with:
#           workload_identity_provider: projects/<num>/locations/global/workloadIdentityPools/flywheel-github/providers/github
#           service_account: ingest-writer@livewire-dw.iam.gserviceaccount.com
#       - name: Pull from Zoho → raw_zoho
#         env:
#           ZOHO_REFRESH_TOKEN: ${{ secrets.ZOHO_REFRESH_TOKEN }}
#         run: python pipelines/zoho/ingest.py --client livewire
```
