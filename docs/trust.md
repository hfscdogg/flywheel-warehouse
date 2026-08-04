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

That's the entire grant. You can verify it yourself at any time:

```sh
bq get-iam-policy <your-project>:marts       # hermes-reader appears here…
bq get-iam-policy <your-project>:raw_zoho    # …and nowhere else
```

## What they cannot see

- Your raw CRM, project, or accounting data (`raw_*` datasets)
- Intermediate transformations (`staging`)
- Anything else in your GCP project — storage, compute, logs, billing
- Anything outside GCP entirely

`scripts/90-verify.sh` proves this mechanically on every setup run: it queries
`marts` as `hermes-reader` (expects success) and then queries a raw dataset the
same way (expects **Access Denied**).

## How access works

No long-lived key files by default. The agents authenticate by **impersonating**
`hermes-reader` — short-lived tokens, minted on demand, nothing to leak or
rotate. A downloadable key is created only if an agent runtime genuinely cannot
impersonate, and then `scripts/04-agent-key.sh` handles rotation and revocation.

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
