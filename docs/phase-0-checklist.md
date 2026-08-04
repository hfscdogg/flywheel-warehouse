# Phase 0 — GCP foundation (human, ~30 minutes)

Everything in this checklist involves account creation, payment methods, or
credential grants, so a human does it once per client. When it's done, Phase 1
onward is scripted.

> **Status for Livewire:** ✅ complete (2026-08-04). Project `livewire-dw`
> exists with billing linked and APIs enabled. This doc remains as the runbook
> for the next client.

## Checklist

1. **Install the Google Cloud SDK** — <https://cloud.google.com/sdk/docs/install>.
   Verify with:

   ```sh
   gcloud version
   ```

2. **Authenticate** as the account that will own the project:

   ```sh
   gcloud auth login
   ```

3. **Create the project.** Project IDs are globally unique across all of GCP —
   if your first choice is taken, pick another and update `GCP_PROJECT_ID` in
   `clients/<slug>/client.env` (nothing else changes).

   ```sh
   gcloud projects create livewire-dw --name="Livewire Data Warehouse"
   ```

4. **Link billing** (console: Billing → Link a billing account, or
   `gcloud billing projects link` if you know the billing account ID).

   > ⚠️ Do this **before** running Phase 1. An unbilled project runs in the
   > BigQuery *sandbox*, which silently adds a forced 60-day expiration to
   > every table.

5. **Enable the required APIs:**

   ```sh
   gcloud services enable \
     bigquery.googleapis.com \
     iam.googleapis.com \
     iamcredentials.googleapis.com \
     cloudresourcemanager.googleapis.com \
     --project livewire-dw
   ```

6. **(Optional) Label the project** so it's identifiable in billing exports:

   ```sh
   gcloud projects update livewire-dw \
     --update-labels managed-by=flywheel,client=livewire,env=prod
   ```

7. **Verify.** Green across the board means Phase 0 is done:

   ```sh
   ./scripts/00-preflight.sh livewire
   ```
