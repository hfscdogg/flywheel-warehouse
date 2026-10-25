"""Run one read-only query for the probe workflow (.github/workflows/probe.yml).

    SQL='SELECT 1' python -m pipelines.probe --client livewire --max-rows 20

The statement comes from the SQL environment variable, never from argv or a
shell line: it is a free-text workflow input, and the workflow passes it the
only way that cannot become a command.

BigQuery classifies the statement before it runs (pipelines/lib/readonly_sql.py)
and anything but a single SELECT stops here. The workflow also runs as
warehouse-reader, which can read every dataset and write none, so a statement
that got past this check would still be refused. Either one alone keeps a
probe from writing; both are kept.
"""
import argparse
import json
import os
import sys

from google.cloud import bigquery

from pipelines.lib import config, readonly_sql

MAX_BYTES_BILLED = 1024 ** 3  # caps a runaway scan at 1 GiB


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--client", required=True)
    p.add_argument("--max-rows", type=int, default=20)
    args = p.parse_args()

    cfg = config.load_client(args.client)
    print(f"project: {cfg.project_id}")
    client = bigquery.Client(project=cfg.project_id)
    try:
        stmt = readonly_sql.check(client, os.environ.get("SQL", ""),
                                  bigquery.QueryJobConfig, use_legacy_sql=False)
    except readonly_sql.NotReadOnly as e:
        sys.exit(str(e))
    print("statement accepted: BigQuery reads it as a single SELECT")

    job = client.query(stmt, job_config=bigquery.QueryJobConfig(
        use_legacy_sql=False, maximum_bytes_billed=MAX_BYTES_BILLED))
    rows = []
    for row in job.result(max_results=max(args.max_rows, 0)):
        rows.append({k: v if isinstance(v, (bool, int, float, str, type(None))) else str(v)
                     for k, v in row.items()})
    print(json.dumps(rows, indent=2, default=str))


if __name__ == "__main__":
    main()
