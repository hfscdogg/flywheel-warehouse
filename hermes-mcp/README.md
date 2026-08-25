# hermes-mcp/ — Phase 4 (the agent endpoint)

A small MCP server, deployed to Cloud Run **inside the client's project,
running as `hermes-reader`** — the service's runtime identity is the scoped
service account, so there is no key anywhere and GCP IAM enforces
marts-only access. Any MCP-capable agent (Hermes Agent, Claude, ChatGPT)
connects to `https://<service-url>/mcp` with a bearer token.

Tools exposed:

| Tool | What |
|------|------|
| `list_kpi_tables` | KPI tables in `marts` with row counts + descriptions |
| `get_table_schema` | columns/types/descriptions of one table |
| `query` | read-only Standard SQL, unqualified names resolve to `marts` |

Deploy, token rotation, and teardown: [`scripts/07-hermes-endpoint.sh`](../scripts/07-hermes-endpoint.sh).
Operator runbook: [`docs/phase-4-hermes-endpoint.md`](../docs/phase-4-hermes-endpoint.md).

Guardrails in the server (IAM is the real boundary; these fail politely
first): single SELECT/WITH statement only, `maximum_bytes_billed` cap
(1 GiB default), returned rows capped (1000 default).
