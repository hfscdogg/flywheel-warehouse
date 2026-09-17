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
        # Normalised to UTC, not passed through: +05:30 and its UTC
        # equivalent are the same instant, and the landing column is a
        # TIMESTAMP with no timezone of its own. Passing the raw value through
        # is what let Zoho Billing's compact offset reach BigQuery and fail
        # seventeen nights of loads — see NormalizeTs below.
        self.assertEqual(row["_modified_at"], "2026-08-01T04:30:00+00:00")
        self.assertEqual(row["_run_id"], "run1")
        self.assertEqual(row["payload"], self.RECORD)

    def test_build_row_dotted_field(self):
        row = util.build_row(self.RECORD, "id", "MetaData.LastUpdatedTime", "r", "t")
        self.assertEqual(row["_modified_at"], "2026-08-02T00:00:00+00:00")

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


class NormalizeTs(unittest.TestCase):
    """A source timestamp must reach BigQuery in a spelling it accepts.

    BigQuery's JSON loader is stricter than datetime.fromisoformat. Zoho
    Billing returns a compact UTC offset -- no colon -- and the loader rejects
    it, failing the WHOLE load because a landing load runs at max_bad_records
    0. raw_zohobilling.customers stopped landing on 2026-08-31 and the nightly
    failed every night for seventeen days on one row.

    parse_ts already handled the value, which is why the watermark kept
    advancing while the data did not land: the two paths disagreed about what
    a timestamp is, and only one of them talked to BigQuery.
    """

    #: Verbatim from the failing run's log, 2026-09-17.
    ZOHO_COMPACT_OFFSET = "2026-09-16T16:35:35-0400"

    def test_the_value_that_broke_it(self):
        self.assertEqual(util.normalize_ts(self.ZOHO_COMPACT_OFFSET),
                         "2026-09-16T20:35:35+00:00")

    def test_every_dialect_lands_as_one(self):
        # Same instant, four spellings, one stored form. A landing column is a
        # TIMESTAMP and holds no timezone of its own, so normalising to UTC
        # loses nothing.
        for value in ("2026-09-16T16:35:35-0400",
                      "2026-09-16T16:35:35-04:00",
                      "2026-09-16T20:35:35Z",
                      "2026-09-16T20:35:35+00:00"):
            with self.subTest(value=value):
                self.assertEqual(util.normalize_ts(value),
                                 "2026-09-16T20:35:35+00:00")

    def test_a_naive_timestamp_is_left_at_its_own_offset(self):
        # No offset means none can be invented; it must still parse.
        self.assertTrue(util.normalize_ts("2026-09-16 20:35:35"))

    def test_none_stays_none(self):
        # Alarm.com exposes no modified timestamp at all.
        self.assertIsNone(util.normalize_ts(None))

    def test_an_unparseable_value_lands_null_rather_than_failing_the_run(self):
        # Staging orders by _modified_at DESC NULLS LAST, _loaded_at DESC, so
        # one NULL degrades to load order for that record instead of losing
        # every row in the batch.
        with self.assertLogs("flywheel.util", level="WARNING") as caught:
            self.assertIsNone(util.normalize_ts("not a date"))
        self.assertIn("not a date", caught.output[0])

    def test_build_row_normalizes_rather_than_passing_the_raw_value(self):
        # The regression that matters: build_row is the one place a source
        # timestamp reaches a BigQuery TIMESTAMP column.
        row = util.build_row(
            {"id": "7", "last_modified_time": self.ZOHO_COMPACT_OFFSET},
            "id", "last_modified_time", "run-1", "2026-09-17T00:00:00+00:00")
        self.assertEqual(row["_modified_at"], "2026-09-16T20:35:35+00:00")
        self.assertNotEqual(row["_modified_at"], self.ZOHO_COMPACT_OFFSET)

    def test_build_row_survives_a_bad_timestamp(self):
        row = util.build_row(
            {"id": "7", "last_modified_time": "garbage"},
            "id", "last_modified_time", "run-1", "2026-09-17T00:00:00+00:00")
        self.assertIsNone(row["_modified_at"])
        self.assertEqual(row["_source_id"], "7")  # the record still lands


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
