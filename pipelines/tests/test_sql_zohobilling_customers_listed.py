"""The Billing customers model keeps only customers Zoho still lists.

raw_zohobilling.customers is append-only and every run lands the whole
customer list. "Latest record per customer" alone therefore keeps a customer
forever: a profile merged into another in Zoho (which deletes it) or removed
outright simply stops arriving, and its last record stays the newest one it
has. Measured 2026-09-22: 80 such ghosts in staging, 22 of them not listed
since the first pull on 2026-08-31, and 38 of the audit's 109
duplicate-profile accounts were matched to one -- profiles already merged in
Zoho, so the merge could never clear the finding.

The model now restricts itself to the customers in the newest run's list.
This test pins the shape of that restriction in the SQL text, the way
test_sql_address_key pins the match key: there is no BigQuery in CI, so the
text is what can be checked. Mutation verified: removing the IN filter, or
picking the run by anything other than the newest record, fails.
"""

import pathlib
import re
import unittest

MODEL = (pathlib.Path(__file__).resolve().parents[2]
         / "sql" / "staging" / "stg_zohobilling__customers.sql")


def cte(sql, name):
    """The body of one named CTE, or None."""
    m = re.search(rf"\b{name} AS \((.*?)\n\)", sql, re.S)
    return m.group(1) if m else None


class TestOnlyListedCustomersSurvive(unittest.TestCase):
    def setUp(self):
        self.sql = MODEL.read_text()

    def test_the_newest_run_is_the_one_holding_the_most_recent_record(self):
        # The list lands first in a run and the detail batches follow under
        # the same _run_id, so the run with the newest _loaded_at always has
        # its full list landed. A watermark would not say that.
        body = cte(self.sql, "newest_run")
        self.assertIsNotNone(body, "the model names the newest run in a CTE")
        self.assertIn("SELECT _run_id", body)
        self.assertIn("FROM raw_zohobilling.customers", body)
        self.assertRegex(body, r"ORDER BY _loaded_at DESC\s+LIMIT 1")

    def test_listed_is_the_newest_runs_customers(self):
        body = cte(self.sql, "listed")
        self.assertIsNotNone(body, "the model names the listed customers in a CTE")
        self.assertIn("SELECT DISTINCT _source_id", body)
        self.assertIn("WHERE _run_id = (SELECT _run_id FROM newest_run)", body)

    def test_latest_keeps_only_listed_customers(self):
        # The one line that does the work. Without it the two CTEs above are
        # decoration and every ghost is back.
        body = cte(self.sql, "latest")
        self.assertIsNotNone(body)
        self.assertIn("_source_id IN (SELECT _source_id FROM listed)", body)

    def test_the_description_says_so(self):
        # The description is what an agent reads to understand the table; a
        # ghost profile it once served as current must be explained away.
        self.assertIn("Only customers Zoho still lists", self.sql)


if __name__ == "__main__":
    unittest.main()
