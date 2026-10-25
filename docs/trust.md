# The Flywheel trust model

<!-- TODO(productization): polish for sales collateral; add logo/one-pager layout. -->

You own the warehouse. Flywheel's agents get one auditable, revocable
credential, scoped to what you chose. This document is the whole
arrangement — there is nothing else.

## What Flywheel's agents can see

It depends on one setting in your `client.env`, `AGENT_SCOPE`
([access-tiers.md](access-tiers.md)). Either way the agents read through a
service account named `hermes-reader`, and either way they never read
`raw_*`.

| `AGENT_SCOPE` | The agent can read | What that includes |
|---------------|--------------------|--------------------|
| `narrow` (the default) | the `marts` dataset | KPI summary tables |
| `wide` | `marts` **and `staging`** | every cleaned record at row level: customer names, emails, phone numbers, addresses, invoices, projects |

**Livewire runs the wide scope** (since 2026-09-04). Livewire's agent can
read `staging`, row-level customer data included.

`hermes-reader`'s complete set of permissions:

| Permission | Scope | Why |
|------------|-------|-----|
| `roles/bigquery.dataViewer` | `marts`; and `staging` under the wide scope | read the tables |
| `roles/bigquery.jobUser` | project | run the queries that read them |

That's the entire grant. Moving from wide back to narrow revokes the
`staging` grant (`scripts/03-iam.sh`), it does not just stop adding it. You
can verify the grant yourself at any time by reading each dataset's access
list:

```sh
bq show --format=prettyjson <your-project>:marts      # hermes-reader appears in "access"…
bq show --format=prettyjson <your-project>:staging    # …here only under the wide scope…
bq show --format=prettyjson <your-project>:raw_zoho   # …and nowhere else
```

(BigQuery displays the read grant under its legacy name `READER` in that
list — same permission, older label.)

## What they cannot see

- Your raw CRM, project, or accounting data (`raw_*` datasets) — never,
  in any configuration
- Intermediate transformations (`staging`) — under the narrow scope only.
  Under the wide scope (Livewire's) the agent reads `staging`, as above
- Anything else in your GCP project — storage, compute, logs, billing
- Anything outside GCP entirely

`scripts/90-verify.sh` proves this mechanically on every setup run: it queries
`marts` as `hermes-reader` (expects success) and then queries a raw dataset the
same way (expects **Access Denied**). It also reads every dataset in the
project and fails if `hermes-reader` holds anything outside the scope you
chose, and fails if a retired pipeline account or a second way in for GitHub
still exists.

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
outside `marts` (and `staging`, under the wide scope). Agents authenticate to it with a bearer token stored in
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

This removes the agent's IAM bindings (on `marts`, and on `staging` too under
the wide scope), deletes any keys, and disables the service account. The agents lose all access immediately. Your data is untouched, and
re-granting later is equally scripted.

## Where your data lives

Stored in **your** GCP project, on **your** billing account, in the BigQuery
region you chose. Flywheel operates inside it by invitation.

Stored there is not the same as never leaving. Whatever an agent queries is
returned to that agent: to the runtime it runs in and the model provider
behind it. Under the wide scope that can be row-level customer data from
`staging`. The scope setting decides what can be returned; it cannot make a
returned row stay in the project.

## Auditability

Cloud Audit Logs record every query `hermes-reader` runs — what, when, and
against which table. You can review that history in your project's console
without asking anyone.
