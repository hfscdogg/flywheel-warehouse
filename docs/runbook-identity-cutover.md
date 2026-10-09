# Cutover: one account per pipeline job

For a client set up before 2026-10-09, when one account, `ingest-writer`, ran
every pipeline. This closes the four warehouse findings in SoundVision's
validation report (Oct 1) on a live warehouse:

| # | Finding | Closed by |
|---|---------|-----------|
| 1 | The read-only query path can still carry a write | `probe.yml` runs as `warehouse-reader`, which can write nothing, and BigQuery must classify the SQL as a single `SELECT` before it runs (`pipelines/lib/readonly_sql.py`; the agent endpoint uses the same check) |
| 2 | Workflow inputs reach the shell directly | Every workflow passes inputs through `env:`. `pipelines/tests/test_workflow_inputs.py` fails on any `${{ }}` in a `run:` line |
| 3 | Cloud trust accepts any workflow in the repository | The WIF provider accepts `main` only, and each account trusts named workflow files only (`job_workflow_ref`) |
| 4 | One identity holds every connector secret and all write access | `ingest-<source>`, `transform-writer` and `warehouse-reader` replace `ingest-writer` ([trust.md](trust.md#pipeline-identities)) |

Merging the code changes nothing live. The scripts act only when a person
runs them. Each workflow falls back to `WIF_SERVICE_ACCOUNT` (`ingest-writer`)
until its own variable is set. Steps 1 to 5 only add, so the nightly
pipelines keep running throughout. Step 8 removes the old account, and it is
the one step you cannot undo with a single command.

Run everything from an admin session (`gcloud auth login` as the project
owner), on `main`, with the PR merged. Every script supports `DRY_RUN=1` to
print its plan first.

## 1. Create the accounts and their grants

```sh
./scripts/02-service-accounts.sh livewire
./scripts/03-iam.sh livewire
```

Adds `ingest-zoho`, `ingest-zohobilling`, `ingest-dtools`, `ingest-qbo`,
`ingest-vendor`, `ingest-alarmdotcom`, `transform-writer` and
`warehouse-reader`, with BigQuery access per [trust.md](trust.md#pipeline-identities).
Nothing is removed.

## 2. Pin the trust and split the secrets

```sh
./scripts/05-ingestion-infra.sh livewire
./scripts/09-vendor-drop.sh livewire
./scripts/10-endpoint-deployer.sh livewire
```

- `05` updates the WIF provider: it now maps `job_workflow_ref` and refuses
  tokens from any branch but `main`. From here on, a workflow run dispatched
  from a feature branch cannot authenticate. Scheduled runs and dispatches
  from `main` are unaffected. `ingest-writer`'s old binding still matches, so
  nothing stops. `05` then binds each new account to its own workflow files
  and gives it its own source's secrets.
- `09` lets `ingest-vendor` read and archive the drop bucket.
- `10` pins `endpoint-deployer` to `deploy-endpoint.yml` on `main` and removes
  its repo-wide binding. It refuses to run if step `05` has not mapped
  `job_workflow_ref`.

## 3. Point each workflow at its account

`05` prints these. Set them in GitHub as repository **variables** (not secrets):

```sh
gh variable set WIF_SA_INGEST_ZOHO        --repo hfscdogg/flywheel-warehouse --body 'ingest-zoho@livewire-dw.iam.gserviceaccount.com'
gh variable set WIF_SA_INGEST_ZOHOBILLING --repo hfscdogg/flywheel-warehouse --body 'ingest-zohobilling@livewire-dw.iam.gserviceaccount.com'
gh variable set WIF_SA_INGEST_DTOOLS      --repo hfscdogg/flywheel-warehouse --body 'ingest-dtools@livewire-dw.iam.gserviceaccount.com'
gh variable set WIF_SA_INGEST_QBO         --repo hfscdogg/flywheel-warehouse --body 'ingest-qbo@livewire-dw.iam.gserviceaccount.com'
gh variable set WIF_SA_INGEST_VENDOR      --repo hfscdogg/flywheel-warehouse --body 'ingest-vendor@livewire-dw.iam.gserviceaccount.com'
gh variable set WIF_SA_INGEST_ALARMDOTCOM --repo hfscdogg/flywheel-warehouse --body 'ingest-alarmdotcom@livewire-dw.iam.gserviceaccount.com'
gh variable set WIF_SA_TRANSFORM          --repo hfscdogg/flywheel-warehouse --body 'transform-writer@livewire-dw.iam.gserviceaccount.com'
gh variable set WIF_SA_PROBE              --repo hfscdogg/flywheel-warehouse --body 'warehouse-reader@livewire-dw.iam.gserviceaccount.com'
```

**To undo one:** delete its variable, and that workflow goes back to
`ingest-writer` on its next run.

## 4. Run each workflow once from `main`

Actions → each workflow → Run workflow, branch `main`. Run all eight ingests
(`ingest-zoho`, `-zohobilling`, `-dtools`, `-dtools-v2`, `-qbo`,
`-qbo-reports`, `-alarmdotcom`, `-vendordrop`), then `transform`. Each
should pass. Every run's "Authenticate to Google Cloud" step names the
account it used.

Then the probe, three times:

| `sql` | Expected |
|-------|----------|
| `SELECT 1` | passes and prints `[{"f0_": 1}]` |
| `DELETE FROM marts.kpi_sales_pipeline WHERE FALSE` | fails at the dry run, before anything runs |
| `SELECT '/*'; DROP TABLE marts.kpi_sales_pipeline; SELECT '*/'` | fails at the dry run, before anything runs |

The third is the string SoundVision's bypass relied on. Depending on how far
BigQuery gets, the failure reads "BigQuery reads this as DELETE" (or
`SCRIPT`), or it is BigQuery's own access-denied error for
`warehouse-reader`. Either way nothing was written. Check afterwards that
`marts.kpi_sales_pipeline` is still there.

## 5. Redeploy the agent endpoint

Run `deploy-endpoint` (needs its approval) to ship `server.py`'s new
read-only check. The endpoint already ran as `hermes-reader`, which cannot
write, so this changes the error message an agent sees, not what it can do.

## 6. Let one nightly cycle pass

Wait for the 06:00 to 07:00 UTC run of every workflow to come back green on
the new accounts.

## 7. Rotate the connector credentials

`ingest-writer` could read every credential, so treat them all as exposed.
Rotate each source's credentials and load the new values as new secret
versions ([phase-2-credentials.md](phase-2-credentials.md)). Then disable the
old versions:

```sh
gcloud secrets versions list flywheel-zoho-refresh-token --project livewire-dw
gcloud secrets versions disable <old-version> --secret flywheel-zoho-refresh-token --project livewire-dw
```

## 8. Retire `ingest-writer`

```sh
./scripts/11-retire-ingest-writer.sh livewire
gh variable delete WIF_SERVICE_ACCOUNT --repo hfscdogg/flywheel-warehouse
```

The script refuses to run until every new account exists and the provider
maps `job_workflow_ref`. It then asks you to confirm the variables are set.
It removes the old repo-wide binding, every secret grant, every dataset
grant, project `jobUser` and drop-bucket access, then disables the account.
Disabling is reversible (`gcloud iam service-accounts enable`); the grants
have to be re-added by hand.

## 9. Verify, and keep the evidence

```sh
./scripts/90-verify.sh livewire
```

That checks every account exists and has `jobUser`, that no ingest account is
bound on `staging` or `marts`, and that the agent's 200/403 boundary holds.

For the re-verification, also save the output of:

```sh
# 3: the provider and one binding per account
gcloud iam workload-identity-pools providers describe github \
  --project livewire-dw --location=global --workload-identity-pool=flywheel-github \
  --format='yaml(attributeMapping,attributeCondition)'
for a in ingest-zoho ingest-zohobilling ingest-dtools ingest-qbo ingest-vendor \
         ingest-alarmdotcom transform-writer warehouse-reader endpoint-deployer ingest-writer; do
  echo "== $a"
  gcloud iam service-accounts get-iam-policy "$a@livewire-dw.iam.gserviceaccount.com" \
    --project livewire-dw --format='value(bindings.members)'
done

# 4: who can read each secret
for s in $(gcloud secrets list --project livewire-dw --format='value(name)'); do
  echo "== $s"
  gcloud secrets get-iam-policy "$s" --project livewire-dw --format='value(bindings.members)'
done
```

Every binding should name a single `.github/workflows/<file>.yml@refs/heads/main`,
and none should name `attribute.repository`. Each secret should list only its
own source's `ingest-` account.

## New clients

A client set up from now on gets this layout from `setup.sh` and
`05-ingestion-infra.sh` directly. It never has an `ingest-writer`, so it skips
steps 6 to 8.
