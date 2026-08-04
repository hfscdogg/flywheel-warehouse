# flywheel-warehouse

The data warehouse behind **Flywheel** — Livewire's results-oriented AI consulting offering — and the client-onboarding runbook, written as code.

This repo does two jobs at once:

1. **Stands up Livewire's own BigQuery warehouse** (`livewire-dw`): raw data in from Zoho, D-Tools Cloud, and QuickBooks Online; KPI mart tables out, read by Flywheel's agents.
2. **Onboards the next client.** Every script is parameterized by a per-client config file. Client #2 is a directory copy, a config edit, and one command.

## Architecture

```
Zoho CRM ─────┐
D-Tools Cloud ├──▶  raw_zoho / raw_dtools / raw_qbo  ──▶  staging  ──▶  marts
QuickBooks ───┘          (ingest-writer SA)                             │
                                                                        ▼
                                                          Hermes agents (hermes-reader SA:
                                                          read-only, marts only, revocable)
```

One GCP project per client. The project is the namespace, so dataset names stay fixed.

## Phases

| Phase | What | Status |
|-------|------|--------|
| 0 | GCP project, billing, APIs (human, ~30 min) | ✅ done for Livewire — [docs/phase-0-checklist.md](docs/phase-0-checklist.md) |
| 1 | Warehouse scaffold: datasets, IAM, scoped read-only service account | ✅ this repo — [scripts/](scripts/) |
| 2 | Ingestion: scheduled pulls from Zoho / D-Tools / QBO | 🔜 [pipelines/](pipelines/README.md) |
| 3 | Staging + KPI mart SQL | 🔜 [sql/](sql/) |
| 4 | Agent goal cards | 🔜 [goal-cards/](goal-cards/README.md) |
| 5 | Productization: trust doc + onboarding runbook | drafted — [docs/trust.md](docs/trust.md), [docs/runbook-new-client.md](docs/runbook-new-client.md) |

## Quickstart (Livewire)

Prerequisites: Google Cloud SDK installed, `gcloud auth login` as the project owner.

```sh
./scripts/00-preflight.sh livewire   # read-only readiness check
./scripts/setup.sh livewire          # datasets → service accounts → IAM → verify
```

`setup.sh` is idempotent — re-running it converges to the same state and is the
acceptance test. To see the full command plan without touching GCP:

```sh
DRY_RUN=1 ./scripts/setup.sh livewire
```

## New client in three commands

```sh
cp -r clients/_template clients/acme
$EDITOR clients/acme/client.env       # fill in every CHANGEME
./scripts/setup.sh acme
```

Full operator walkthrough: [docs/runbook-new-client.md](docs/runbook-new-client.md).

## Revoking agent access

The trust promise ("you can revoke it anytime") is a script, not a support ticket:

```sh
./scripts/99-teardown.sh <client> --revoke-agent
```

Removes the agent service account's IAM bindings, deletes any keys, and disables
the account — under a minute, fully reversible by re-running `03-iam.sh`.
Details: [docs/trust.md](docs/trust.md).

## Repo map

```
clients/     per-client config (one dir per client; _template to copy)
scripts/     Phase 1: idempotent gcloud/bq scripts, numbered in run order
docs/        Phase 0 checklist, trust doc, operator runbook, conventions
pipelines/   Phase 2 placeholder: ingestion workflows (GitHub Actions + WIF)
sql/         Phase 3 placeholder: staging + marts models
goal-cards/  Phase 4 placeholder: KPI goal cards for the agents
```
