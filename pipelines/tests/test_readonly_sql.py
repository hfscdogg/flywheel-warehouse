"""Read-only SQL is whatever BigQuery says is a single SELECT.

The agent endpoint and the probe workflow both take SQL from outside. The
regex they used until 2026-10-09 stripped comments without knowing about
string literals, so `SELECT '/*'; DROP TABLE x; SELECT '*/'` read as one
SELECT. readonly_sql asks BigQuery instead: a dry run reports the statement
type, and only "SELECT" passes. These tests use a fake client that answers
the way BigQuery does, so they need no GCP.
"""

import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PIPELINES_COPY = ROOT / "pipelines" / "lib" / "readonly_sql.py"
ENDPOINT_COPY = ROOT / "hermes-mcp" / "readonly.py"
SERVER = ROOT / "hermes-mcp" / "server.py"

_spec = importlib.util.spec_from_file_location("readonly_sql", PIPELINES_COPY)
readonly_sql = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(readonly_sql)


class FakeConfig:
    def __init__(self, **kw):
        self.kw = kw


class FakeJob:
    def __init__(self, statement_type):
        self.statement_type = statement_type


class FakeClient:
    """Answers a dry run with the statement type BigQuery would report."""

    def __init__(self, statement_type):
        self.statement_type = statement_type
        self.calls = []

    def query(self, sql, job_config):
        self.calls.append((sql, job_config.kw))
        return FakeJob(self.statement_type)


class Check(unittest.TestCase):
    def check(self, statement_type, sql="SELECT 1", **config):
        client = FakeClient(statement_type)
        return client, readonly_sql.check(client, sql, FakeConfig, **config)

    def test_a_select_passes(self):
        _, stmt = self.check("SELECT", "WITH a AS (SELECT 1) SELECT * FROM a")
        self.assertEqual(stmt, "WITH a AS (SELECT 1) SELECT * FROM a")

    def test_anything_else_is_refused(self):
        for kind in ("SCRIPT", "INSERT", "UPDATE", "DELETE", "MERGE", "DROP_TABLE",
                     "CREATE_TABLE_AS_SELECT", "EXPORT_DATA", "TRUNCATE_TABLE",
                     "SOMETHING_NEW", None, ""):
            with self.subTest(kind=kind):
                with self.assertRaises(readonly_sql.NotReadOnly):
                    self.check(kind)

    def test_the_old_regex_bypass_is_a_script_and_is_refused(self):
        # BigQuery reports more than one statement as SCRIPT, whatever the
        # literals and comments in it.
        with self.assertRaises(readonly_sql.NotReadOnly):
            self.check("SCRIPT", "SELECT '/*'; DROP TABLE marts.x; SELECT '*/'")

    def test_it_is_a_dry_run_in_the_callers_context(self):
        client, _ = self.check("SELECT", default_dataset="p.marts", use_legacy_sql=False)
        (_, kw), = client.calls
        self.assertIs(kw["dry_run"], True)
        self.assertEqual(kw["default_dataset"], "p.marts")
        self.assertIs(kw["use_legacy_sql"], False)

    def test_the_text_classified_is_the_text_returned(self):
        # The old check returned a comment-stripped rewrite. Here comments
        # and literals survive untouched; only edge whitespace and trailing
        # semicolons go.
        sql = "  SELECT '--x' AS a /* keep */ FROM t -- end\n;; "
        client, stmt = self.check("SELECT", sql)
        self.assertEqual(stmt, "SELECT '--x' AS a /* keep */ FROM t -- end")
        self.assertEqual(client.calls[0][0], stmt)

    def test_an_empty_query_never_reaches_bigquery(self):
        for sql in ("", "   ", ";", " ; ;", None):
            with self.subTest(sql=sql):
                client = FakeClient("SELECT")
                with self.assertRaises(readonly_sql.NotReadOnly):
                    readonly_sql.check(client, sql, FakeConfig)
                self.assertEqual(client.calls, [])


class OneModuleTwoPlaces(unittest.TestCase):
    def test_the_two_copies_are_identical(self):
        # The endpoint deploys hermes-mcp/ alone, so it carries its own copy.
        self.assertEqual(PIPELINES_COPY.read_text(), ENDPOINT_COPY.read_text(),
                         "hermes-mcp/readonly.py and pipelines/lib/readonly_sql.py "
                         "differ; copy one over the other")

    def test_the_endpoint_uses_it_before_running_anything(self):
        src = SERVER.read_text()
        body = src[src.index("def query(sql: str)"):]
        body = body[:body.index("\n@mcp.tool()")]
        self.assertLess(body.index("_read_only(client, sql)"), body.index("client.query("))
        self.assertIn("readonly.check(", src)
        self.assertNotIn("_clean_select", src)
