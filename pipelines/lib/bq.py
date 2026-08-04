"""BigQuery landing-table and watermark helpers (imports google-cloud-bigquery)."""

from google.cloud import bigquery

# Landing tables: full source record as JSON payload plus extraction metadata.
# Dedup/latest-record logic belongs in staging (Phase 3), not here.
LANDING_SCHEMA = [
    bigquery.SchemaField("payload", "JSON"),
    bigquery.SchemaField("_source_id", "STRING"),
    bigquery.SchemaField("_modified_at", "TIMESTAMP"),
    bigquery.SchemaField("_loaded_at", "TIMESTAMP"),
    bigquery.SchemaField("_run_id", "STRING"),
]

# _flywheel_* prefix is reserved for infrastructure tables (docs/conventions.md).
STATE_TABLE = "_flywheel_state"
STATE_SCHEMA = [
    bigquery.SchemaField("entity", "STRING"),
    bigquery.SchemaField("watermark", "TIMESTAMP"),
    bigquery.SchemaField("run_id", "STRING"),
    bigquery.SchemaField("recorded_at", "TIMESTAMP"),
]


def client_for(cfg):
    return bigquery.Client(project=cfg.project_id, location=cfg.bq_location)


def ensure_table(bq, cfg, dataset, name, schema):
    table_id = f"{cfg.project_id}.{dataset}.{name}"
    table = bigquery.Table(table_id, schema=schema)
    if schema is LANDING_SCHEMA:
        table.time_partitioning = bigquery.TimePartitioning(field="_loaded_at")
        table.clustering_fields = ["_source_id"]
    bq.create_table(table, exists_ok=True)
    return table_id


def load_rows(bq, table_id, rows, schema):
    """Batch-load rows (atomic per call, free tier, safe to re-run: append-only)."""
    job = bq.load_table_from_json(
        rows,
        table_id,
        job_config=bigquery.LoadJobConfig(
            schema=schema,
            write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
        ),
    )
    job.result()
    return job.output_rows


def get_watermark(bq, cfg, dataset, entity):
    """Latest recorded watermark for an entity, or None (state is append-only)."""
    table_id = f"{cfg.project_id}.{dataset}.{STATE_TABLE}"
    sql = f"""
        SELECT watermark FROM `{table_id}`
        WHERE entity = @entity
        ORDER BY recorded_at DESC LIMIT 1
    """
    job = bq.query(sql, job_config=bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("entity", "STRING", entity)],
    ))
    try:
        for row in job.result():
            return row.watermark
    except Exception:
        return None  # state table absent on first run
    return None


def set_watermark(bq, cfg, dataset, entity, watermark_iso, run_id, recorded_at):
    table_id = ensure_table(bq, cfg, dataset, STATE_TABLE, STATE_SCHEMA)
    load_rows(bq, table_id, [{
        "entity": entity,
        "watermark": watermark_iso,
        "run_id": run_id,
        "recorded_at": recorded_at,
    }], STATE_SCHEMA)
