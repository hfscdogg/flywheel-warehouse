"""Read-only SQL, decided by BigQuery rather than by a regex.

The agent endpoint (hermes-mcp/server.py) and the probe workflow
(pipelines/probe.py) both take SQL from outside and must run only reads.
Until 2026-10-09 both decided that with a regex: strip comments, refuse a
";", require a leading SELECT or WITH. The comment stripping did not know
about string literals, so

    SELECT '/*'; DROP TABLE marts.x; SELECT '*/'

reduced to "SELECT ' '" and passed, and the probe then ran the original
text, three statements, as an account holding dataEditor.

So nobody parses SQL here. BigQuery dry-runs the statement, which costs
nothing and runs nothing, and says what it is: job.statement_type is
"SELECT" for a query (WITH included), "SCRIPT" for anything with more than
one statement, and the DML/DDL name for a write. Anything but "SELECT" is
refused, including a type this code has never heard of. The text that was
classified is the text that runs, byte for byte.

Stdlib only. The BigQuery client and its QueryJobConfig class are passed in,
so this imports without google-cloud-bigquery installed and the tests need
no GCP. This file exists twice, here and as pipelines/lib/readonly_sql.py,
because the endpoint deploys hermes-mcp/ on its own;
pipelines/tests/test_readonly_sql.py fails if the two copies differ.
"""

READ_ONLY_TYPES = frozenset({"SELECT"})


class NotReadOnly(ValueError):
    """The statement is empty, or BigQuery says it is not a plain query."""


def normalize(sql):
    """Trim whitespace and trailing semicolons, nothing else.

    Comments and literals are left exactly as written: rewriting the text is
    how the old check came to approve one statement and run another.
    """
    stmt = (sql or "").strip()
    while stmt.endswith(";"):
        stmt = stmt[:-1].rstrip()
    if not stmt:
        raise NotReadOnly("empty query")
    return stmt


def check(client, sql, job_config_cls, **config):
    """Dry-run `sql` and return it, normalized, if it is a single SELECT.

    `config` is passed to the dry run's QueryJobConfig (default_dataset,
    use_legacy_sql and so on), so the statement is classified in the same
    context it will run in. Raises NotReadOnly otherwise; a dry run that
    BigQuery itself rejects raises BigQuery's own error.
    """
    stmt = normalize(sql)
    job = client.query(stmt, job_config=job_config_cls(dry_run=True, use_query_cache=False, **config))
    kind = getattr(job, "statement_type", None)
    if kind not in READ_ONLY_TYPES:
        raise NotReadOnly(
            f"read-only: a single SELECT only (BigQuery reads this as {kind or 'unknown'})")
    return stmt
