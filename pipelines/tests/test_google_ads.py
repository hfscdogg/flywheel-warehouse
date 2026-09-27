"""Google Ads reaches the warehouse through BigQuery's own transfer.

The Google Ads transfer writes raw_google_ads.p_ads_<Report>_<customer id>.
The transform finds a staging model's inputs by reading lower-case
raw_<source>.<table> names out of its SQL, so a model reading
p_ads_CampaignBasicStats_9919533169 would never find its input and would
be skipped every night without a word. 01-datasets.sh therefore puts views
with plain names over the reports, and staging reads those.

Each test below breaks when one of these is edited away:
- the customer id and the source are set together, or not at all;
- staging reads the plain-named views, never a p_ads_ table or a customer id;
- spend comes from the basic report, whose impressions are not inflated
  by the click-type split, and micros become dollars;
- the mart reads staging only, and every new staging table is watched for
  freshness.
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
LIVEWIRE = ROOT / "clients" / "livewire" / "client.env"
DAILY = ROOT / "sql" / "staging" / "stg_google_ads__campaign_daily.sql"
CAMPAIGNS = ROOT / "sql" / "staging" / "stg_google_ads__campaigns.sql"
MART = ROOT / "sql" / "marts" / "kpi_paid_media.sql"
FRESH = ROOT / "sql" / "checks" / "fresh.sql"


def flat(text):
    return " ".join(re.sub(r"--[^\n]*", "", text).split())


def load_client(raw, customer):
    """Run load_client on a throwaway client; (exit status, stderr)."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        (tmp / "scripts" / "lib").mkdir(parents=True)
        shutil.copy(COMMON, tmp / "scripts" / "lib" / "common.sh")
        env = LIVEWIRE.read_text()
        env = re.sub(r'^CLIENT_SLUG=.*$', 'CLIENT_SLUG="t"', env, flags=re.M)
        env = re.sub(r'^DATASETS_RAW=.*$', f'DATASETS_RAW="{raw}"', env, flags=re.M)
        env = re.sub(r'^GA4_EXPORT_DATASET=.*$', '', env, flags=re.M)
        env = re.sub(r'^GOOGLE_ADS_CUSTOMER_ID=.*$', f'GOOGLE_ADS_CUSTOMER_ID="{customer}"',
                     env, flags=re.M)
        (tmp / "clients" / "t").mkdir(parents=True)
        (tmp / "clients" / "t" / "client.env").write_text(env)
        r = subprocess.run(
            ["bash", "-c", f'. "{tmp}/scripts/lib/common.sh"; load_client t'],
            capture_output=True, text=True)
        return r.returncode, r.stderr


class TheTwoSettingsAgree(unittest.TestCase):
    def test_livewire_has_both(self):
        env = LIVEWIRE.read_text()
        self.assertRegex(env, r'(?m)^DATASETS_RAW="[^"]*\braw_google_ads\b')
        self.assertRegex(env, r'(?m)^GOOGLE_ADS_CUSTOMER_ID="\d+"')

    def test_both_set_loads(self):
        self.assertEqual(load_client("raw_zoho raw_google_ads", "1234567890")[0], 0)

    def test_neither_set_loads(self):
        self.assertEqual(load_client("raw_zoho", "")[0], 0)

    def test_the_source_without_the_id_is_refused(self):
        code, err = load_client("raw_zoho raw_google_ads", "")
        self.assertNotEqual(code, 0)
        self.assertIn("GOOGLE_ADS_CUSTOMER_ID is not set", err)

    def test_the_id_without_the_source_is_refused(self):
        code, err = load_client("raw_zoho", "1234567890")
        self.assertNotEqual(code, 0)
        self.assertIn("raw_google_ads is not in DATASETS_RAW", err)

    def test_the_id_as_google_prints_it_is_refused(self):
        # Google Ads shows 991-953-3169; the table name carries 9919533169.
        code, err = load_client("raw_zoho raw_google_ads", "991-953-3169")
        self.assertNotEqual(code, 0)
        self.assertIn("digits only", err)


class TheViews(unittest.TestCase):
    def setUp(self):
        self.src = DATASETS.read_text()

    def test_they_sit_over_the_transfer_tables(self):
        self.assertIn('local table="p_ads_$2_$GOOGLE_ADS_CUSTOMER_ID"', self.src)
        self.assertIn("ads_view campaign_basic_stats CampaignBasicStats", self.src)
        self.assertIn("ads_view campaigns Campaign ", self.src)

    def test_a_report_not_yet_landed_is_skipped_not_fatal(self):
        body = self.src[self.src.index("ads_view() {"):]
        body = body[:body.index("\n}\n")]
        self.assertIn('probe $BQ show --format=none "$GCP_PROJECT_ID:raw_google_ads.$table"', body)
        self.assertIn("return 0", body)

    def test_staging_reads_only_the_views(self):
        # A p_ads_ name or a customer id in the SQL is invisible to the
        # transform's input check, and ties the model to one client.
        for path in (DAILY, CAMPAIGNS):
            sql = path.read_text()
            with self.subTest(path.name):
                self.assertTrue(set(re.findall(r"\braw_\w+\.\w+", sql)) <=
                                {"raw_google_ads.campaign_basic_stats",
                                 "raw_google_ads.campaigns"})
                self.assertNotIn("p_ads_", sql)
                self.assertNotRegex(sql, r"\d{10}")


class TheSpend(unittest.TestCase):
    def setUp(self):
        self.sql = flat(DAILY.read_text())

    def test_it_comes_from_the_basic_report(self):
        # CampaignStats is split by click type, which counts an impression
        # once per click type: 7,645 there against 4,752 here on 2026-09-27.
        self.assertIn("FROM raw_google_ads.campaign_basic_stats", self.sql)

    def test_micros_become_dollars(self):
        self.assertIn("ROUND(SUM(metrics_cost_micros) / 1e6, 2) AS cost", self.sql)

    def test_one_row_per_day_and_campaign(self):
        # Exactly these two: grouping by device or network as well splits
        # a campaign's day into several rows.
        self.assertIn("GROUP BY report_date, campaign_id;", self.sql)

    def test_a_day_counts_once(self):
        self.assertIn("WHERE segments_date = DATE(partition_time)", self.sql)

    def test_campaigns_take_the_newest_copy(self):
        self.assertIn(
            "QUALIFY ROW_NUMBER() OVER (PARTITION BY campaign_id ORDER BY partition_time DESC) = 1",
            flat(CAMPAIGNS.read_text()))


class TheMart(unittest.TestCase):
    def test_it_reads_staging_only(self):
        self.assertEqual(set(re.findall(r"\bstaging\.\w+", MART.read_text())),
                         {"staging.stg_google_ads__campaign_daily",
                          "staging.stg_google_ads__campaigns"})

    def test_a_campaign_missing_from_the_list_keeps_its_spend(self):
        # An inner join would drop the spend of a campaign the campaign
        # report has not listed yet.
        self.assertIn("LEFT JOIN c USING (campaign_id)", flat(MART.read_text()))

    def test_every_staging_table_is_watched(self):
        src = FRESH.read_text()
        for table in ("stg_google_ads__campaign_daily", "stg_google_ads__campaigns"):
            self.assertIn(f"FROM staging.{table}", src)
        self.assertIn("STARTS_WITH(table_name, 'stg_google_ads__')", src)


if __name__ == "__main__":
    unittest.main()
