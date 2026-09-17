"""BigQuery caps a description, and an over-long one fails the whole model.

A column description may be 1024 characters and a table description 16384.
`bq update --schema` rejects the entire call when any one column is over, so
a single long description leaves that table with NO descriptions at all --
not the one that was too long, all of them -- and takes the transform red.

This is not hypothetical. marts.kpi_subscription_audit.match_via reached 1028
characters when the email and phone match tiers were documented, and the
transform then failed on that table for two runs. It was invisible for days
because a separate bug meant no description was being applied at all, so the
limit was never reached to be rejected; the moment descriptions started
working again, this surfaced.

The descriptions in this repo are written for agents and they are meant to be
long -- they are the only thing hermes-mcp serves. So the failure mode is
built into how the repo works, and belongs in a test that runs on every
commit rather than in a production transform seven minutes in.
"""

import pathlib
import re
import unittest

SQL = pathlib.Path(__file__).resolve().parents[2] / "sql"

# https://cloud.google.com/bigquery/quotas -- description length limits.
COLUMN_MAX = 1024
TABLE_MAX = 16384

# Written for headroom, not for the cliff: a description one character under
# the limit fails the next time anyone clarifies a sentence. Findings between
# the two are reported by test_headroom as a warning-shaped failure.
COMFORTABLE = 980


def column_descriptions():
    """(file, column, text) for every ALTER COLUMN ... SET OPTIONS."""
    out = []
    for path in sorted(SQL.rglob("*.sql")):
        src = path.read_text()
        for m in re.finditer(
                r'ALTER COLUMN (\w+)\s*\n?\s*SET OPTIONS\s*\(\s*description\s*=\s*'
                r'"((?:[^"\\]|\\.)*)"', src):
            out.append((path.name, m.group(1), m.group(2)))
    return out


def table_descriptions():
    """(file, text) for every CREATE ... OPTIONS(description = \"\"\"...\"\"\")."""
    out = []
    for path in sorted(SQL.rglob("*.sql")):
        src = path.read_text()
        for m in re.finditer(r'OPTIONS\s*\(description = """(.*?)"""', src, re.S):
            out.append((path.name, m.group(1)))
    return out


class DescriptionLimits(unittest.TestCase):
    def test_there_are_descriptions_to_check(self):
        # A regex that silently stops matching would make every test below
        # pass on an empty list, which is the failure mode of a guard like
        # this one.
        self.assertGreater(len(column_descriptions()), 200)
        self.assertGreater(len(table_descriptions()), 30)

    def test_every_column_description_fits(self):
        over = [(f, c, len(d)) for f, c, d in column_descriptions()
                if len(d) > COLUMN_MAX]
        self.assertEqual(
            over, [],
            f"a column description exceeds BigQuery's {COLUMN_MAX}-character "
            "limit; bq update rejects the whole table, so EVERY column on it "
            "would go undescribed and the transform would fail on that model")

    def test_every_table_description_fits(self):
        over = [(f, len(d)) for f, d in table_descriptions() if len(d) > TABLE_MAX]
        self.assertEqual(
            over, [],
            f"a table description exceeds BigQuery's {TABLE_MAX}-character limit")

    def test_headroom(self):
        # Not the same test: this one is about the next edit, not this one.
        tight = [(f, c, len(d)) for f, c, d in column_descriptions()
                 if COMFORTABLE < len(d) <= COLUMN_MAX]
        self.assertEqual(
            tight, [],
            f"a column description is within {COLUMN_MAX - COMFORTABLE} "
            f"characters of the {COLUMN_MAX} limit. Trim it now: the next "
            "person to clarify a sentence will not be thinking about a "
            "character count, and the failure lands in a production "
            "transform, not here")


if __name__ == "__main__":
    unittest.main()
