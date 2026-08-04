# Onboarding a new Flywheel client

Operator-facing runbook. Livewire was client #1; this is the path for #2..N.

## Prerequisites

- Google Cloud SDK installed and authenticated (`gcloud auth login`) as an
  owner of the client's new project — or run the scripts *with* the client on
  a screen share, in their own auth session. The second option is the better
  trust story: Flywheel never holds owner credentials at all.
- The client has completed [docs/phase-0-checklist.md](phase-0-checklist.md)
  (~30 minutes: project, billing, APIs).

## Steps

1. **Create the client config:**

   ```sh
   cp -r clients/_template clients/<slug>
   ```

   Slug rules: lowercase letters, digits, hyphens; must start with a letter
   (it becomes a GCP label value and part of key paths).

2. **Edit `clients/<slug>/client.env`** — every `CHANGEME`:

   | Variable | What to put there |
   |----------|-------------------|
   | `CLIENT_SLUG` | must match the directory name |
   | `CLIENT_DISPLAY_NAME` | human name, used in SA display names |
   | `GCP_PROJECT_ID` | the project from Phase 0 (globally unique) |
   | `BQ_LOCATION` | `US` unless the client has residency needs (e.g. `us-east4`, `EU`) |
   | `ADMIN_USER` | the human owner's email — gets impersonation rights on the reader SA |
   | `DATASETS_RAW` | one `raw_<source>` per source system, space-separated |

3. **Dry-run first** — show the client exactly what will happen:

   ```sh
   DRY_RUN=1 ./scripts/setup.sh <slug>
   ```

4. **Run it:**

   ```sh
   ./scripts/setup.sh <slug>
   ```

   This runs preflight → datasets → service accounts → IAM → verify, stopping
   on the first failure. The verify step ends with the two lines that matter:
   the agent credential **can** read `marts` and **cannot** read raw data.

5. **Deliver [docs/trust.md](trust.md)** with the verify output attached as
   receipts.

6. **Record the engagement** — commit `clients/<slug>/` to this repo. The
   config file *is* the record; it contains no secrets.

## Differences to expect per client

- **Different source systems** → edit `DATASETS_RAW` (e.g. `raw_hubspot`
  instead of `raw_zoho`). Everything downstream is driven by the list.
- **Org policy blocks SA key creation** (`iam.disableServiceAccountKeyCreation`
  — enforced by default on newer GCP orgs). Fine: the design is
  impersonation-first and never needs a key. Only fight this policy if the
  agent runtime truly can't impersonate; `04-agent-key.sh` explains the
  exemption path when it hits the 403.
- **VPC Service Controls** around BigQuery → the reader SA's queries must
  originate inside the perimeter; plan the agent runtime's network placement
  with the client's security team before promising a timeline.
- **Existing datasets with the same names** → the scripts converge rather than
  fail, but review `bq show` output with the client before running against a
  project that wasn't created fresh in Phase 0.
