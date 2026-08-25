"""Flywheel marts MCP server — the client-hosted agent endpoint.

Runs on Cloud Run inside the client's GCP project AS the hermes-reader
service account (the runtime identity, no key anywhere), so GCP IAM is the
real enforcement: dataViewer on the marts dataset plus jobUser, nothing
else. The checks in this file only exist to fail politely before IAM would
fail loudly.

Any MCP-capable agent (Hermes Agent, Claude, ChatGPT, ...) connects over
streamable HTTP at /mcp with a bearer token; deploy and token handling live
in scripts/07-hermes-endpoint.sh.

Env (set by the deploy script):
  HERMES_TOKEN      required — shared secret the agent presents as
                    "Authorization: Bearer <token>"
  GCP_PROJECT_ID    client project (falls back to ADC's default project)
  DATASET_MARTS     marts dataset name (default "marts")
  MAX_BYTES_BILLED  per-query byte cap (default 1 GiB)
  MAX_ROWS          per-query returned-row cap (default 1000)
"""
import os
import re
import secrets

import uvicorn
from google.cloud import bigquery
from mcp.server.fastmcp import FastMCP
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse

PROJECT = os.environ.get("GCP_PROJECT_ID") or None
DATASET = os.environ.get("DATASET_MARTS", "marts")
TOKEN = os.environ["HERMES_TOKEN"]
MAX_BYTES_BILLED = int(os.environ.get("MAX_BYTES_BILLED", str(1024**3)))
MAX_ROWS = int(os.environ.get("MAX_ROWS", "1000"))

# Cloud Run scales to zero between conversations, so no per-session state.
mcp = FastMCP("flywheel-marts", stateless_http=True)

_bq = None


def bq() -> bigquery.Client:
    global _bq
    if _bq is None:
        _bq = bigquery.Client(project=PROJECT)
    return _bq


def _json_safe(value):
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    return str(value)  # DATE/TIMESTAMP/NUMERIC etc.


def _clean_select(sql: str) -> str:
    """Reject anything but a single SELECT/WITH statement.

    IAM makes writes impossible for hermes-reader anyway; this just turns
    the denial into a clear message instead of a BigQuery permission error.
    """
    no_comments = re.sub(r"--[^\n]*|/\*.*?\*/", " ", sql, flags=re.S)
    stmt = no_comments.strip().rstrip(";").strip()
    if not stmt:
        raise ValueError("empty query")
    if ";" in stmt:
        raise ValueError("one statement per query")
    if not re.match(r"(?is)^(select|with)\b", stmt):
        raise ValueError("read-only endpoint: SELECT/WITH statements only")
    return stmt


@mcp.tool()
def list_kpi_tables() -> list:
    """List the KPI tables in the marts dataset with row counts and
    descriptions. These tables are the agent-facing source of truth."""
    client = bq()
    dataset = f"{client.project}.{DATASET}"
    out = []
    for item in client.list_tables(dataset):
        if item.table_id.startswith("_"):  # infra (canary), not a KPI
            continue
        table = client.get_table(item.reference)
        out.append({
            "table": item.table_id,
            "rows": table.num_rows,
            "description": table.description or "",
        })
    return out


@mcp.tool()
def get_table_schema(table: str) -> dict:
    """Get the column names, types, and descriptions of one marts table."""
    if not re.fullmatch(r"[A-Za-z0-9_]+", table):
        raise ValueError("invalid table name")
    client = bq()
    ref = client.get_table(f"{client.project}.{DATASET}.{table}")
    return {
        "table": table,
        "rows": ref.num_rows,
        "description": ref.description or "",
        "columns": [
            {"name": f.name, "type": f.field_type, "description": f.description or ""}
            for f in ref.schema
        ],
    }


@mcp.tool()
def query(sql: str) -> dict:
    """Run a read-only SQL query against the marts dataset (BigQuery
    Standard SQL). Unqualified table names resolve to marts, e.g.
    SELECT * FROM kpi_sales_pipeline ORDER BY month DESC LIMIT 12."""
    client = bq()
    stmt = _clean_select(sql)
    job = client.query(stmt, job_config=bigquery.QueryJobConfig(
        default_dataset=f"{client.project}.{DATASET}",
        maximum_bytes_billed=MAX_BYTES_BILLED,
        use_legacy_sql=False,
    ))
    rows, truncated = [], False
    for row in job.result():
        if len(rows) >= MAX_ROWS:
            truncated = True
            break
        rows.append({k: _json_safe(v) for k, v in row.items()})
    return {"rows": rows, "row_count": len(rows), "truncated": truncated}


class BearerAuth(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        presented = request.headers.get("authorization", "")
        if not secrets.compare_digest(presented, f"Bearer {TOKEN}"):
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        return await call_next(request)


app = mcp.streamable_http_app()  # serves MCP at /mcp
app.add_middleware(BearerAuth)

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
