# Phase 4 — the agent endpoint (hermes-mcp)

How an agent gets query access to a client's warehouse. One shape for every
client and every agent runtime: a small MCP server on Cloud Run **in the
client's project, running as `hermes-reader`**. No service-account keys
exist anywhere in this design.

```
agent (Hermes Agent / Claude / ChatGPT — anything MCP-capable)
  │  HTTPS + bearer token
  ▼
Cloud Run: hermes-mcp            ← runtime identity = hermes-reader
  │  BigQuery client, ADC
  ▼
marts dataset ONLY               ← enforced by IAM (03-iam.sh), not by code
```

Why this shape (vs. handing the agent a key): no key to leak, hand off, or
rotate; no `iam.disableServiceAccountKeyCreation` org-policy exemption
during onboarding; works identically for whatever agent a client already
uses; every query is visible in the client's own Cloud Run logs; and
revocation is one command. The trust story in [trust.md](trust.md) is
unchanged — the endpoint *is* the "one narrow, auditable, revocable
credential," in service form.

## Deploy (once per client, ~3 minutes)

As the project owner (`gcloud auth login`), from the repo root:

```sh
DRY_RUN=1 ./scripts/07-hermes-endpoint.sh <client>   # see the plan
./scripts/07-hermes-endpoint.sh <client>             # deploy
```

The script enables the Cloud Run/Build/Secret Manager APIs, generates a
bearer token into the client's own Secret Manager (`hermes-endpoint-token`),
grants the project's default compute service account the
`cloudbuild.builds.builder` role (source deploys build as that account, and
newer projects don't grant it build permissions — without this the deploy
fails at "Uploading sources" with PERMISSION_DENIED), builds `hermes-mcp/`
from source, and deploys it with `--service-account hermes-reader`. It ends
by printing the MCP URL and how to read the token.
`./scripts/07-hermes-endpoint.sh <client> url` reprints that at any time.

First-run notes: the build takes 3–5 minutes; if a step fails with
"API has not been used … or it is disabled" or an IAM PERMISSION_DENIED
right after a grant, that's propagation — wait a minute and re-run the same
command (every step is idempotent).

The service accepts unauthenticated *transport* (`--allow-unauthenticated`)
because agents can't do Google IAM auth; the app returns 401 to every
request without the bearer token, and the runtime identity can read `marts`
and nothing else regardless of what reaches it.

## Connect an agent

Give the agent two values (from the `url` action):

- **Endpoint**: `https://<service-url>/mcp` (MCP streamable-HTTP transport)
- **Header**: `Authorization: Bearer <token>`

For Hermes Agent specifically, add it as a remote MCP server in the agent's
MCP configuration (see the Hermes Agent MCP docs); it will discover the
three tools automatically: `list_kpi_tables`, `get_table_schema`, and
`query` (read-only Standard SQL; unqualified table names resolve to
`marts`).

## Verify the scope (from the agent's seat)

Mirrors `90-verify.sh`, but through the endpoint:

1. `query`: `SELECT month, deals_won FROM kpi_sales_pipeline ORDER BY month DESC LIMIT 3` → rows.
2. `query`: `` SELECT COUNT(*) FROM `<project>.raw_zoho.deals` `` → **Access Denied**. That denial is the product working: the endpoint physically cannot read raw or staging data.

## Rotate / revoke

```sh
./scripts/07-hermes-endpoint.sh <client> rotate-token   # old token dead now
./scripts/07-hermes-endpoint.sh <client> delete         # endpoint gone in seconds
```

Both are client-side operations in the client's own project — consistent
with the [trust.md](trust.md) promise that the client can end access at any
time without Flywheel's involvement.

## Costs & limits

Cloud Run scales to zero between conversations (effectively $0 idle);
per-query caps in the server: 1 GiB `maximum_bytes_billed`, 1000 returned
rows, single SELECT/WITH statement. Raise via env vars in
`scripts/07-hermes-endpoint.sh` if a KPI genuinely needs more.
