# hermes-mcp/ — Phase 4 (the agent endpoint)

A small MCP server, deployed to Cloud Run **inside the client's project,
running as `hermes-reader`** — the service's runtime identity is the scoped
service account, so there is no key anywhere and GCP IAM enforces the
client's chosen scope (`marts`, or `marts` + `staging`; never `raw_*`). Any MCP-capable agent (Hermes Agent, Claude, ChatGPT)
connects to `https://<service-url>/mcp` with a bearer token.

Tools exposed:

| Tool | What |
|------|------|
| `list_kpi_tables` | every table the agent may read (`marts`, plus `staging` under wide scope) with row counts + descriptions |
| `get_table_schema` | columns/types/descriptions of one table, `name` or `dataset.name` |
| `query` | read-only Standard SQL, unqualified names resolve to `marts`; `staging.<name>` for staging |
| `list_goal_cards` | the KPIs the agents are accountable to: kpi, title, status, owner, cadence, mart, target |
| `get_goal_card` | one card verbatim: canonical query, baseline, target, and the rules for reading it |

The descriptions are the agent's only documentation: they are set in each
mart's SQL (`OPTIONS(description)` on the `CREATE`, `ALTER COLUMN ... SET
OPTIONS` after it) and the transform fails if any mart lacks one — see
[`sql/marts/README.md`](../sql/marts/README.md).

The goal cards come from [`goal-cards/<client>/`](../goal-cards/README.md).
They live outside this directory, so the deploy copies this directory and
that client's cards into a temporary build source (`goal_cards/` beside
`server.py`); `goal_cards.py` serves them. A card change reaches the agent
at the next redeploy.

Deploy, token rotation, and teardown: [`scripts/07-hermes-endpoint.sh`](../scripts/07-hermes-endpoint.sh).
Operator runbook: [`docs/phase-4-hermes-endpoint.md`](../docs/phase-4-hermes-endpoint.md).

Guardrails in the server (IAM is the real boundary; these fail politely
first): single SELECT/WITH statement only, `maximum_bytes_billed` cap
(1 GiB default), returned rows capped (1000 default).
