# The Flywheel trust model

<!-- TODO(productization): polish for sales collateral; add logo/one-pager layout. -->

You own the warehouse. Flywheel's agents get one narrow, auditable, revocable
credential. This document is the whole arrangement — there is nothing else.

## What Flywheel's agents can see

Exactly one thing: **the tables in the `marts` dataset** of your GCP project,
through a service account named `hermes-reader`. Its complete set of
permissions:

| Permission | Scope | Why |
|------------|-------|-----|
| `roles/bigquery.dataViewer` | the `marts` dataset only | read KPI tables |
| `roles/bigquery.jobUser` | project | run the queries that read them |

That's the entire grant. You can verify it yourself at any time by reading
each dataset's access list:

```sh
bq show --format=prettyjson <your-project>:marts      # hermes-reader appears in "access"…
bq show --format=prettyjson <your-project>:raw_zoho   # …and nowhere else
```

(BigQuery displays the read grant under its legacy name `READER` in that
list — same permission, older label.)

## What they cannot see

- Your raw CRM, project, or accounting data (`raw_*` datasets) — never,
  in any configuration
- Intermediate transformations (`staging`) — unless *you* choose the wide
  agent scope in your `client.env` (`AGENT_SCOPE="wide"`, see
  [access-tiers.md](access-tiers.md)), in which case your own agent can read
  the cleaned, row-level tables too
- Anything else in your GCP project — storage, compute, logs, billing
- Anything outside GCP entirely

`scripts/90-verify.sh` proves this mechanically on every setup run: it queries
`marts` as `hermes-reader` (expects success) and then queries a raw dataset the
same way (expects **Access Denied**).

And to be explicit about the other direction: **Flywheel-the-company holds no
standing access to your warehouse at all.** The credential above belongs to
agents working for *you*, inside *your* project. The full map of who can see
what — your humans, your agents, and the (opt-in, aggregates-only, not yet
built) community learning tier — is in [access-tiers.md](access-tiers.md).

## How access works

No long-lived key files. The agents reach the warehouse through a small
query endpoint (**hermes-mcp**) that runs **in your project, as
`hermes-reader`** — Cloud Run's runtime identity is the scoped service
account, so there is no credential file anywhere, every query appears in
your own Cloud Run logs, and the endpoint physically cannot read anything
outside `marts`. Agents authenticate to it with a bearer token stored in
your Secret Manager; rotating or deleting it is one command
(`scripts/07-hermes-endpoint.sh`, see
[phase-4-hermes-endpoint.md](phase-4-hermes-endpoint.md)).

Direct impersonation of `hermes-reader` (short-lived tokens, no key) remains
available for runtimes with their own Google identity, and
`scripts/04-agent-key.sh` exists as a last-resort key escape hatch — but the
endpoint is the default for agent access.

The same principle covers ingestion: your API credentials (CRM, projects,
accounting) are stored in **your own project's Secret Manager** — GitHub and
Flywheel hold nothing. The pipelines federate into your project with
short-lived tokens (no keys) and read the credentials at runtime. Revoke any
of them in your own console anytime.

### Pipeline identities

Each pipeline job runs as its own service account, holding only what that
job touches. A fault or compromise in one connector reaches that connector's
data and credentials, and nothing else.

| Account | Reads | Writes | Secrets |
|---------|-------|--------|---------|
| `ingest-<source>` (one per source system) | — | its own `raw_<source>` only | its own source's credentials only |
| `transform-writer` | every `raw_*` | `staging`, `marts` | none |
| `warehouse-reader` (the probe workflow) | every dataset | nothing | none |
| `hermes-reader` (agents) | `marts` (and `staging` if wide) | nothing | none |

Only one workflow file can borrow each account, and only from the `main`
branch. GitHub signs the calling workflow's file and branch into every token,
and your project's trust settings check both. A workflow on another branch,
or a different workflow in the same repository, gets nothing. You can read
these bindings back in your console under IAM → Workload Identity
Federation, or with the commands in
[runbook-identity-cutover.md](runbook-identity-cutover.md).

Free-text inputs to the workflows reach programs only as data, never as part
of a shell command. SQL typed into the probe workflow runs only if BigQuery
itself classifies it as a single `SELECT`, and the probe's account could not
write even if it did not.

## Revoke anytime

One command, under a minute:

```sh
./scripts/99-teardown.sh <client> --revoke-agent
```

This removes the agent's IAM bindings, deletes any keys, and disables the service
account. The agents lose all access immediately. Your data is untouched, and
re-granting later is equally scripted.

## Where your data lives

In **your** GCP project, on **your** billing account, in the BigQuery region
you chose. Flywheel operates inside it by invitation; it never leaves.

## Auditability

Cloud Audit Logs record every query `hermes-reader` runs — what, when, and
against which table. You can review that history in your project's console
without asking anyone.
