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

- Your raw CRM, project, or accounting data (`raw_*` datasets)
- Intermediate transformations (`staging`)
- Anything else in your GCP project — storage, compute, logs, billing
- Anything outside GCP entirely

`scripts/90-verify.sh` proves this mechanically on every setup run: it queries
`marts` as `hermes-reader` (expects success) and then queries a raw dataset the
same way (expects **Access Denied**).

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

## Revoke anytime

One command, under a minute:

```sh
./scripts/99-teardown.sh <client> --revoke-agent
```

This removes both IAM bindings, deletes any keys, and disables the service
account. The agents lose all access immediately. Your data is untouched, and
re-granting later is equally scripted.

## Where your data lives

In **your** GCP project, on **your** billing account, in the BigQuery region
you chose. Flywheel operates inside it by invitation; it never leaves.

## Auditability

Cloud Audit Logs record every query `hermes-reader` runs — what, when, and
against which table. You can review that history in your project's console
without asking anyone.
