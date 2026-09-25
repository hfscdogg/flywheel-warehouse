"""Every source the warehouse answers from is checked for staleness.

A transform over stale sources SUCCEEDS. Every model rebuilds, every other
check passes, the marts are served, and the answers are quietly out of date.
That is worse than an error: an error is visible and this is not. On
2026-09-17 the ingests did not run at their scheduled hour and the transform
rebuilt all 35 models from the previous day's extract without a word.

sql/checks/fresh.sql closes that, and this is what stops it going hollow. The
check names its sources explicitly -- one SELECT per staging table, the way
every model in this repo lists its columns -- so it cannot drift silently:
add a staging model and forget the check, and the new table is simply never
looked at. Nothing fails. The warehouse just stops watching one of its feeds.

So the test is the reverse lookup: every staging table carrying a loaded_at
column must appear in fresh.sql or in EXEMPT below, with a reason.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHECK = ROOT / "sql" / "checks" / "fresh.sql"
TRANSFORM = ROOT / "scripts" / "06-transform.sh"
STAGING = ROOT / "sql" / "staging"

# Tables deliberately not freshness-checked. Each needs a reason that is about
# the DATA, not about the check being inconvenient.
EXEMPT = {
    # Empty by design until the Alarm.com Partner API is credentialed, so
    # MAX(loaded_at) is NULL and it would fail every night for something
    # nobody can act on. The dealer-site export is the live Alarm.com feed
    # and IS checked.
    "stg_alarmdotcom__customers",
}

# An API source ingested nightly; a missed night is not yet a problem, two is.
DAILY_MAX = 3
# No threshold may be so loose that the check cannot fail before a quarter's
# reporting is built on stale numbers.
CEILING = 45


def staging_tables_with_loaded_at():
    out = set()
    for path in sorted(STAGING.glob("*.sql")):
        src = path.read_text()
        m = re.search(r"CREATE OR REPLACE TABLE staging\.(\w+)", src)
        if m and re.search(r"\bAS loaded_at\b", src):
            out.add(m.group(1))
    return out


def checked_tables():
    """(table, max_age_days) for every source named in fresh.sql."""
    src = CHECK.read_text()
    body = src[src.index("WITH loaded AS ("):]
    return {m.group(1): int(m.group(2)) for m in
            re.finditer(r"SELECT '(\w+)'(?:\s+AS table_name)?,\s*(\d+)", body)}


class Freshness(unittest.TestCase):
    def test_the_parsers_find_something(self):
        # Both sides of this test are regexes over SQL. If either silently
        # stops matching, every assertion below passes over empty sets.
        self.assertGreater(len(staging_tables_with_loaded_at()), 20)
        self.assertGreater(len(checked_tables()), 20)

    def test_every_source_is_checked_or_exempt(self):
        missing = staging_tables_with_loaded_at() - set(checked_tables()) - EXEMPT
        self.assertEqual(
            missing, set(),
            "a staging table carries loaded_at but no freshness check. Add it "
            "to sql/checks/fresh.sql with its source's own cadence, or to "
            "EXEMPT here with a reason about the data")

    def test_the_check_names_no_table_that_does_not_exist(self):
        extra = set(checked_tables()) - staging_tables_with_loaded_at()
        self.assertEqual(
            extra, set(),
            "fresh.sql checks a table that no staging model builds; the "
            "check would fail the transform on a table that cannot be fixed")

    def test_exemptions_are_real_tables(self):
        # An exemption for a table that no longer exists is a hole left open
        # for a name someone may reuse.
        stale = EXEMPT - staging_tables_with_loaded_at()
        self.assertEqual(stale, set(),
                         "an EXEMPT entry names no existing staging model")

    def test_api_sources_are_held_to_the_daily_threshold(self):
        loose = {t: d for t, d in checked_tables().items()
                 if not t.startswith("stg_vendor__") and d > DAILY_MAX}
        self.assertEqual(
            loose, {},
            f"an API source ingested nightly is allowed more than {DAILY_MAX} "
            "days; that is a hand-upload threshold on an automated feed")

    def test_no_threshold_is_unbounded(self):
        loose = {t: d for t, d in checked_tables().items() if d > CEILING}
        self.assertEqual(loose, {},
                         f"a threshold above {CEILING} days cannot fail in "
                         "time to matter")

    def test_the_failure_says_what_to_do(self):
        # A check that reports a problem without naming the remedy gets
        # rediscovered from scratch every time it fires.
        src = CHECK.read_text()
        self.assertIn("AS fix", src)
        self.assertIn("upload to gs://", src)


# Sources pulled incrementally: their landing tables grow only when a record
# changes, so MAX(loaded_at) is when something last changed, not when the
# ingest last ran. The check must read the run log for every one of these.
INCREMENTAL = ("stg_qbo__", "stg_zoho__")


def raw_tables_named():
    """{staging table: raw_table} as fresh.sql names them."""
    src = CHECK.read_text()
    body = src[src.index("WITH loaded AS ("):src.index("\nran AS (")]
    out = {}
    for m in re.finditer(r"SELECT '(\w+)' AS table_name,.*?(?:'(raw_\w+\.\w+)'|NULL AS STRING\)) AS raw_table",
                         body, re.S):
        out[m.group(1)] = m.group(2)
    return out


def model_raw_input(table):
    src = (STAGING / f"{table}.sql").read_text()
    return sorted(set(re.findall(r"\braw_[a-z0-9_]+\.[a-z0-9_]+", src)))


class AQuietIncrementalSourceIsNotStale(unittest.TestCase):
    """2026-09-25: stg_qbo__purchase_orders failed the transform as "3 days
    old, ingest workflow has not run" on the third green ingest-qbo in a row.
    Nobody had edited a purchase order since 09-22, so nothing new landed.

    Found by mutation: pointing one entry's raw_table at the wrong entity, or
    dropping the join to the run log, fails the tests below.
    """

    def test_every_incremental_source_names_the_raw_table_it_reads(self):
        named = raw_tables_named()
        incremental = {t for t in checked_tables() if t.startswith(INCREMENTAL)}
        self.assertGreater(len(incremental), 10)
        for table in sorted(incremental):
            with self.subTest(table=table):
                self.assertEqual(
                    [named.get(table)], model_raw_input(table),
                    "the run log is joined on the raw table this staging "
                    "model reads; a different name checks another entity's "
                    "runs, or none")

    def test_the_run_log_is_read_for_each_incremental_source(self):
        src = " ".join(CHECK.read_text().split())
        for ds in sorted({model_raw_input(t)[0].split(".")[0]
                          for t in checked_tables() if t.startswith(INCREMENTAL)}):
            with self.subTest(dataset=ds):
                self.assertIn(f"FROM {ds}._flywheel_runs", src)

    def test_the_verdict_is_taken_after_the_run_log_join(self):
        src = " ".join(CHECK.read_text().split())
        self.assertIn("LEFT JOIN ran AS r USING (raw_table)", src)
        self.assertIn("GREATEST(l.newest, r.ran_at)", src)
        final = src[src.rindex("SELECT table_name,"):]
        self.assertIn("FROM checked WHERE", final,
                      "the final SELECT reads the loads alone, so a quiet "
                      "entity is still reported stale")

    def test_the_run_log_table_name_matches_the_pipeline(self):
        lib = (ROOT / "pipelines" / "lib" / "bq.py").read_text()
        self.assertIn('RUNS_TABLE = "_flywheel_runs"', lib)


class TheCheckIsActuallyRun(unittest.TestCase):
    """A check nothing calls is worse than no check: it reads as coverage.

    Found by mutation — deleting the `check_fresh` call from the transform
    left the whole suite green, which is exactly the state this file exists
    to make impossible.
    """

    def body(self):
        return " ".join(TRANSFORM.read_text().split())

    def test_the_transform_defines_it(self):
        self.assertIn("check_fresh() {", self.body())

    def test_the_transform_calls_it(self):
        src = self.body()
        calls = src.count(" check_fresh ") + src.count("; check_fresh")
        self.assertGreater(
            calls, 0,
            "06-transform.sh defines check_fresh but never calls it, so no "
            "run has ever looked at whether its sources are current")

    def test_it_runs_after_the_build_not_instead_of_it(self):
        # A stale source is not a reason to withhold the fresher models. The
        # data lands first and the run goes red after, the same ordering
        # check_described uses.
        src = self.body()
        self.assertLess(
            src.index("check_described"), src.rindex("check_fresh"),
            "check_fresh runs before the descriptions check; it belongs last, "
            "after everything is built")

    def test_a_stale_source_ends_the_run_red(self):
        src = TRANSFORM.read_text()
        body = src[src.index("check_fresh() {"):]
        body = body[:body.index("\n}\n")]
        self.assertIn("die ", body,
                      "check_fresh warns but does not fail the run, so a "
                      "stale source is reported into a log nobody reads")


if __name__ == "__main__":
    unittest.main()
