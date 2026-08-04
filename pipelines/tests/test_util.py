"""Tests for the pure helpers — stdlib only, no GCP/network imports."""

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


if __name__ == "__main__":
    unittest.main()
