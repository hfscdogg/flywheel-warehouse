"""Tests for the pure helpers — stdlib only, no GCP/network imports."""

import os
import tempfile
import unittest
from pathlib import Path

from pipelines.lib import util


class TestParseClientEnv(unittest.TestCase):
    def _parse(self, content):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "client.env"
            p.write_text(content)
            return util.parse_client_env(p)

    def test_basic_and_comments(self):
        env = self._parse(
            '# comment\nCLIENT_SLUG="livewire"\n\nGCP_PROJECT_ID="livewire-dw"\n'
        )
        self.assertEqual(env["CLIENT_SLUG"], "livewire")
        self.assertEqual(env["GCP_PROJECT_ID"], "livewire-dw")

    def test_var_reference_resolves(self):
        env = self._parse('CLIENT_SLUG="acme"\nKEY_DIR="${HOME}/.flywheel/keys/${CLIENT_SLUG}"\n')
        self.assertTrue(env["KEY_DIR"].endswith("/acme"))
        self.assertIn("${HOME}", env["KEY_DIR"])  # unknown refs left verbatim

    def test_real_livewire_config_parses(self):
        repo_root = Path(__file__).resolve().parents[2]
        env = util.parse_client_env(repo_root / "clients" / "livewire" / "client.env")
        self.assertEqual(env["CLIENT_SLUG"], "livewire")
        self.assertEqual(env["GCP_PROJECT_ID"], "livewire-dw")
        self.assertIn("raw_zoho", env["DATASETS_RAW"].split())
        self.assertEqual(env["GITHUB_REPO"], "hfscdogg/flywheel-warehouse")


class TestRowBuilding(unittest.TestCase):
    RECORD = {
        "id": 42,
        "Modified_Time": "2026-08-01T10:00:00+05:30",
        "MetaData": {"LastUpdatedTime": "2026-08-02T00:00:00Z"},
    }

    def test_build_row_flat_field(self):
        row = util.build_row(self.RECORD, "id", "Modified_Time", "run1", "2026-08-04T00:00:00+00:00")
        self.assertEqual(row["_source_id"], "42")
        self.assertEqual(row["_modified_at"], "2026-08-01T10:00:00+05:30")
        self.assertEqual(row["_run_id"], "run1")
        self.assertEqual(row["payload"], self.RECORD)

    def test_build_row_dotted_field(self):
        row = util.build_row(self.RECORD, "id", "MetaData.LastUpdatedTime", "r", "t")
        self.assertEqual(row["_modified_at"], "2026-08-02T00:00:00Z")

    def test_build_row_missing_fields(self):
        row = util.build_row({}, "id", "Modified_Time", "r", "t")
        self.assertIsNone(row["_source_id"])
        self.assertIsNone(row["_modified_at"])


class TestMaxModified(unittest.TestCase):
    def test_mixed_offsets_compare_correctly(self):
        records = [
            {"m": "2026-08-01T23:00:00+00:00"},
            {"m": "2026-08-01T20:00:00-05:00"},  # 01:00 UTC next day — the max
            {"m": "2026-08-01T22:00:00Z"},
        ]
        self.assertEqual(
            util.parse_ts(util.max_modified(records, "m")),
            util.parse_ts("2026-08-01T20:00:00-05:00"),
        )

    def test_empty_and_missing(self):
        self.assertIsNone(util.max_modified([], "m"))
        self.assertIsNone(util.max_modified([{"x": 1}], "m"))


class FakeResponse:
    """Minimal stand-in for requests.Response — only what raise_for_status uses."""

    def __init__(self, status_code, text="", url="https://api.example.com/thing"):
        self.status_code = status_code
        self.text = text
        self.url = url
        self.raised = False

    def raise_for_status(self):
        if self.status_code >= 400:
            self.raised = True
            raise RuntimeError(f"{self.status_code} Client Error")


class TestRaiseForStatus(unittest.TestCase):
    def test_success_passes_through_silently(self):
        resp = FakeResponse(200, '{"ok": true}')
        with self.assertNoLogs("flywheel.ingest", level="ERROR"):
            self.assertIs(util.raise_for_status(resp), resp)
        self.assertFalse(resp.raised)

    def test_error_logs_body_then_raises(self):
        body = '{"Fault":{"Error":[{"code":"3200","Message":"message=ApplicationAuthenticationFailed"}]}}'
        resp = FakeResponse(403, body)
        with self.assertLogs("flywheel.ingest", level="ERROR") as captured:
            with self.assertRaises(RuntimeError):
                util.raise_for_status(resp, "QBO query Customer")
        logged = "\n".join(captured.output)
        # The reason the caller could not see before must now be in the log.
        self.assertIn("ApplicationAuthenticationFailed", logged)
        self.assertIn("403", logged)
        self.assertIn("QBO query Customer", logged)
        self.assertIn(resp.url, logged)
        self.assertTrue(resp.raised)

    def test_empty_body_is_labelled_not_blank(self):
        with self.assertLogs("flywheel.ingest", level="ERROR") as captured:
            with self.assertRaises(RuntimeError):
                util.raise_for_status(FakeResponse(500, "   "))
        self.assertIn("<empty body>", "\n".join(captured.output))

    def test_long_body_is_truncated_with_original_size(self):
        resp = FakeResponse(502, "x" * 5000)
        with self.assertLogs("flywheel.ingest", level="ERROR") as captured:
            with self.assertRaises(RuntimeError):
                util.raise_for_status(resp)
        logged = "\n".join(captured.output)
        self.assertIn("truncated, 5000 bytes total", logged)
        self.assertLess(len(logged), 5000)

    def test_context_is_optional(self):
        with self.assertLogs("flywheel.ingest", level="ERROR") as captured:
            with self.assertRaises(RuntimeError):
                util.raise_for_status(FakeResponse(404, "nope"))
        # No stray empty brackets when no context is supplied.
        self.assertNotIn("[]", "\n".join(captured.output))


if __name__ == "__main__":
    unittest.main()


class TestGetPathNoField(unittest.TestCase):
    def test_none_field_yields_none(self):
        # Sources with no modified timestamp (Alarm.com) pass None here.
        self.assertIsNone(util.get_path({"a": 1}, None))
        self.assertIsNone(util.max_modified([{"a": 1}], None))

    def test_dotted_path_still_works(self):
        self.assertEqual(util.get_path({"a": {"b": 2}}, "a.b"), 2)


class TestEnvOr(unittest.TestCase):
    """A GitHub Actions `vars.X` that nobody set arrives as "", not absent."""

    def setUp(self):
        self._saved = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(),
                                 os.environ.update(self._saved)))

    def test_set_but_empty_falls_back_to_the_default(self):
        # The bug: os.environ.get("X", default) returns "" here, and an empty
        # bucket name reached storage.bucket() as an IndexError from inside
        # the client library rather than a legible error.
        os.environ["FLYWHEEL_TEST_VAR"] = ""
        self.assertEqual(util.env_or("FLYWHEEL_TEST_VAR", "fallback"), "fallback")

    def test_whitespace_only_is_also_unset(self):
        os.environ["FLYWHEEL_TEST_VAR"] = "   "
        self.assertEqual(util.env_or("FLYWHEEL_TEST_VAR", "fallback"), "fallback")

    def test_value_is_stripped(self):
        # A value pasted with a trailing newline is not a different value.
        os.environ["FLYWHEEL_TEST_VAR"] = "  us-east4\n"
        self.assertEqual(util.env_or("FLYWHEEL_TEST_VAR"), "us-east4")

    def test_absent_returns_the_default(self):
        os.environ.pop("FLYWHEEL_TEST_VAR", None)
        self.assertEqual(util.env_or("FLYWHEEL_TEST_VAR", "fallback"), "fallback")

    def test_absent_with_no_default_is_none(self):
        # Callers that guard with `if not x: raise` rely on a falsy result.
        os.environ.pop("FLYWHEEL_TEST_VAR", None)
        self.assertIsNone(util.env_or("FLYWHEEL_TEST_VAR"))
