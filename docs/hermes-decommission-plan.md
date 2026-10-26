# Hermes decommission plan: livewire-dw

Decision (Henry, 2026-10-18): Hermes is out. Nothing in Flywheel may depend on
or reference it. The Livewire station reads through station-reader, not
hermes-reader.

This plan retires every Hermes resource in `livewire-dw` and then removes Hermes
from this repo. Each part disables before it deletes, so for the first 30 days
everything except the Cloud Run service can be undone with one command.

> **ON HOLD (2026-10-25).** Henry still wants an easy way to ask the warehouse
> questions, including from his phone. Decision (2026-10-25): **A now, B this week.**
> - A: ask Claude with the BigQuery connector. It runs as Henry's own login, so it is
>   not limited to marts; use the read-only query tool.
> - B: keep the endpoint without Hermes. Rename the service, give it its own read-only
>   reader account, keep the marts-and-staging limit, the SELECT-only guard and the
>   goal cards, and connect it to Claude.
>
> Part A below starts only once B is live. At that point it retires hermes-reader, the
> old service name and the token. endpoint-deployer and endpoint-builder are kept only
> if B still deploys from CI, and the legacy repo-wide WIF binding on endpoint-deployer
> is removed either way. Step 0 (inventory) is read-only and can run now.

## What exists (from the repo; confirm with the inventory)

| Resource | Created by | Holds |
|---|---|---|
| Cloud Run service `hermes-mcp` (us-east4) | `07-hermes-endpoint.sh deploy` | runs as hermes-reader; mounts `hermes-endpoint-token` |
| `hermes-reader@` | `02`, `03` | `bigquery.jobUser` (project); `dataViewer` on marts and staging (AGENT_SCOPE=wide); `secretAccessor` on the token; Henry holds `serviceAccountTokenCreator` on it |
| `endpoint-deployer@` | `10-endpoint-deployer.sh` | `run.admin` on the service; `serviceAccountUser` on hermes-reader and endpoint-builder; project `cloudbuild.builds.editor`, `artifactregistry.writer`, custom `flywheelSourceBucketLister`; `storage.admin` on `gs://run-sources-livewire-dw-us-east4`; WIF bindings for deploy-endpoint.yml **and a legacy repo-wide one** |
| `endpoint-builder@` | `common.sh converge_endpoint_builder` | project `run.builder` |
| Secret `hermes-endpoint-token` | `07` | the bearer token agents send |
| Custom role `flywheelSourceBucketLister` | `10` | `storage.buckets.list` |
| Artifact Registry `cloud-run-source-deploy` (us-east4) | first source deploy | hermes-mcp images |
| Bucket `run-sources-livewire-dw-us-east4` | first source deploy | uploaded source archives |
| GitHub variable `WIF_DEPLOYER_SERVICE_ACCOUNT`, environment `endpoint` | manual setup | used only by deploy-endpoint.yml |

## Step 0: inventory (read-only)

```sh
cd ~/flywheel-warehouse && git fetch -q origin hermes-decommission \
  && git show origin/hermes-decommission:docs/hermes-inventory-livewire.sh | bash | tee ~/hermes-inventory-2026-10-25.txt
```

Two answers come from this before anything is removed:
- **Is anything still calling hermes-mcp?** Section 1b lists requests from the last 14 days. A Telegram bot or a Claude
  session using `.mcp.json` would show up here. Any caller loses access at step 1.
- **Does the inventory match the table above?** Anything extra gets added to the plan before the steps below run.

## Part A: cloud, in order, each with Henry's approval

1. **Stop the endpoint.** `./scripts/07-hermes-endpoint.sh livewire delete` deletes the Cloud Run service. This is
   the one step that is not a disable; it can only be undone by redeploying. It cuts off every agent within seconds.
2. **endpoint-deployer.** Remove both WIF bindings (this is the last repo-wide binding on any account), the
   `serviceAccountUser` grants on hermes-reader and endpoint-builder, the three project roles, and `storage.admin` on
   the build bucket. Then disable the account. `10-endpoint-deployer.sh livewire revoke` covers part of this; the rest
   is explicit `gcloud` commands, listed in the PR before it runs.
3. **endpoint-builder.** Remove project `run.builder`, then disable the account.
4. **hermes-reader.** Remove `dataViewer` on marts and staging, project `jobUser`, `secretAccessor` on the token, and
   Henry's `serviceAccountTokenCreator`. Then disable the account.
5. **Token.** Disable every version of `hermes-endpoint-token`, without deleting them.
6. **GitHub.** Delete the variable `WIF_DEPLOYER_SERVICE_ACCOUNT` and the environment `endpoint`.
7. **Verify.** Re-run the inventory. Expected result: the service is gone, all three accounts are disabled with no
   project roles and no dataset grants, the token is disabled, and there is no WIF binding on any Hermes account.

After 30 days with nothing broken: delete the three accounts, the secret, the custom role, the Artifact Registry
images and the source bucket.

## Part B: repo (one PR after Part A; the template gets the same)

- Remove `hermes-mcp/`, `.github/workflows/deploy-endpoint.yml`, `scripts/07-hermes-endpoint.sh`,
  `scripts/10-endpoint-deployer.sh`, `scripts/04-agent-key.sh`, `.mcp.json`, and the tests for them.
- `02`, `03`, `common.sh`, `client.env`: stop creating and granting hermes-reader. The reader account becomes a setting
  (see 90-verify below).
- `90-verify.sh`: make the reader under test configurable and point it at station-reader (step 9, option 2).
- Mart descriptions and docs that name hermes-mcp as the way agents read: reword them without naming a reader.
  `trust.md`, `access-tiers.md` and `phase-4-hermes-endpoint.md` (the last one is retired).

## Open question for Henry

Is anything outside Flywheel still pointed at hermes-mcp, for example the Telegram bot from Tier 2b (2026-09-04)?
Step 1 ends it. The inventory's request log will show whether anything has called it recently.
