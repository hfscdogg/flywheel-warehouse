"""Google Analytics 4 reaches the warehouse through a view, not an ingest.

Google writes the GA4 property's export into the client's project itself,
as one table per day in a dataset named for the property. raw_ga4.events is
a view over it (01-datasets.sh), so staging reads raw_<source>.<entity> like
every other source and the transform's source-enabled and missing-input
checks apply unchanged. Three things have to hold for that to be safe, and
each test below breaks when one of them is edited away:

- the two client settings agree, or the transform either skips the model
  forever or runs it against a view that was never created;
- ingest-writer can read the export and hermes-reader cannot, the same
  boundary raw_* has;
- the view leaves out the intraday tables, which duplicate a day.
"""

import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
COMMON = ROOT / "scripts" / "lib" / "common.sh"
DATASETS = ROOT / "scripts" / "01-datasets.sh"
IAM = ROOT / "scripts" / "03-iam.sh"
VERIFY = ROOT / "scripts" / "90-verify.sh"
LIVEWIRE = ROOT / "clients" / "livewire" / "client.env"
SESSIONS = ROOT / "sql" / "staging" / "stg_ga4__sessions.sql"
TRAFFIC = ROOT / "sql" / "marts" / "kpi_website_traffic.sql"


def load_client(raw, export):
    """Run load_client on a throwaway client; (exit status, stderr)."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        (tmp / "scripts" / "lib").mkdir(parents=True)
        shutil.copy(COMMON, tmp / "scripts" / "lib" / "common.sh")
        env = LIVEWIRE.read_text()
        env = re.sub(r'^CLIENT_SLUG=.*$', 'CLIENT_SLUG="t"', env, flags=re.M)
        env = re.sub(r'^DATASETS_RAW=.*$', f'DATASETS_RAW="{raw}"', env, flags=re.M)
        env = re.sub(r'^GA4_EXPORT_DATASET=.*$', f'GA4_EXPORT_DATASET="{export}"', env, flags=re.M)
        (tmp / "clients" / "t").mkdir(parents=True)
        (tmp / "clients" / "t" / "client.env").write_text(env)
        r = subprocess.run(
            ["bash", "-c", f'. "{tmp}/scripts/lib/common.sh"; load_client t'],
            capture_output=True, text=True)
        return r.returncode, r.stderr


class TheTwoSettingsAgree(unittest.TestCase):
    def test_livewire_has_both(self):
        env = LIVEWIRE.read_text()
        self.assertRegex(env, r'(?m)^DATASETS_RAW="[^"]*\braw_ga4\b')
        self.assertRegex(env, r'(?m)^GA4_EXPORT_DATASET="analytics_\d+"')

    def test_both_set_loads(self):
        self.assertEqual(load_client("raw_zoho raw_ga4", "analytics_1")[0], 0)

    def test_neither_set_loads(self):
        self.assertEqual(load_client("raw_zoho", "")[0], 0)

    def test_the_source_without_the_export_is_refused(self):
        code, err = load_client("raw_zoho raw_ga4", "")
        self.assertNotEqual(code, 0)
        self.assertIn("GA4_EXPORT_DATASET is not set", err)

    def test_the_export_without_the_source_is_refused(self):
        code, err = load_client("raw_zoho", "analytics_1")
        self.assertNotEqual(code, 0)
        self.assertIn("raw_ga4 is not in DATASETS_RAW", err)


class TheView(unittest.TestCase):
    def setUp(self):
        self.src = DATASETS.read_text()

    def test_it_is_created_over_the_export(self):
        self.assertIn("CREATE OR REPLACE VIEW \\`$GCP_PROJECT_ID.raw_ga4.events\\`", self.src)
        self.assertIn("FROM \\`$GCP_PROJECT_ID.$GA4_EXPORT_DATASET.events_*\\`", self.src)

    def test_intraday_tables_are_left_out(self):
        # events_* also matches events_intraday_YYYYMMDD, which GA4 replaces
        # with the day's final table: reading both counts a day twice.
        self.assertIn("WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}\\$')", self.src)

    def test_the_staging_model_reads_the_view(self):
        # 06-transform.sh finds a staging model's inputs by grepping for
        # raw_<source>.<table>; reading the export directly would bypass the
        # missing-input skip and fail the transform for a client without it.
        sql = SESSIONS.read_text()
        self.assertEqual(set(re.findall(r"\braw_\w+\.\w+", sql)), {"raw_ga4.events"})
        self.assertNotRegex(sql, r"analytics_\d+")


class WhoCanReadTheExport(unittest.TestCase):
    def test_ingest_writer_reads_it(self):
        self.assertIn(
            'grant_dataset_role "$SA_INGEST_WRITER_EMAIL" roles/bigquery.dataViewer "$GA4_EXPORT_DATASET"',
            IAM.read_text())

    def test_hermes_reader_never_does(self):
        for line in IAM.read_text().splitlines():
            if "GA4_EXPORT_DATASET" in line:
                self.assertNotIn("HERMES", line)

    def test_verify_checks_hermes_reader_is_kept_out(self):
        self.assertRegex(VERIFY.read_text(),
                         r"for ds in \$DATASETS_RAW [^;]*\$GA4_EXPORT_DATASET; do")


class TheSessions(unittest.TestCase):
    def test_landing_pages_keep_the_path_only(self):
        # Query strings carry form values and click ids.
        sql = SESSIONS.read_text()
        self.assertIn(r"REGEXP_EXTRACT(s.landing_page, r'^https?://[^/?#]+(/[^?#]*)') AS landing_path",
                      " ".join(sql.split()))
        final = sql[sql.rindex("\nSELECT\n"):sql.index("\nFROM s\n")]
        self.assertEqual(final.count("landing_page"), 1,
                         "the full landing URL is output as well as its path")

    def test_one_row_per_session(self):
        # Exactly these two: grouping by day as well splits a session that
        # crosses midnight into two.
        self.assertRegex(SESSIONS.read_text(), r"(?m)^  GROUP BY user_pseudo_id, ga_session_id$")

    def test_the_mart_reads_the_sessions(self):
        self.assertEqual(set(re.findall(r"\bstaging\.\w+", TRAFFIC.read_text())),
                         {"staging.stg_ga4__sessions"})


if __name__ == "__main__":
    unittest.main()
