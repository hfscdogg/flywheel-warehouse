"""Tests for scripts/lib/merge_descriptions.py.

This is what puts the column descriptions on a table, in one call instead of
one per column. Its two failure modes are both silent without a test: a
description that does not get applied leaves a column Hermes explains wrong,
and a description naming a column the table does not have needs to stop the
run rather than be skipped.
"""

import importlib.util
import io
import json
import pathlib
import unittest

_PATH = (pathlib.Path(__file__).resolve().parents[2]
         / "scripts" / "lib" / "merge_descriptions.py")
_spec = importlib.util.spec_from_file_location("merge_descriptions", _PATH)
merge = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(merge)


MODEL = '''CREATE OR REPLACE TABLE staging.stg_x
OPTIONS (description = """
A table.
""")
AS
SELECT a, b FROM t;

ALTER TABLE staging.stg_x ALTER COLUMN a
  SET OPTIONS (description = "The first one.");
ALTER TABLE staging.stg_x ALTER COLUMN b
  SET OPTIONS (description = "The second one, with a comma, and a - dash.");
'''


class Descriptions(unittest.TestCase):
    def test_reads_every_alter(self):
        self.assertEqual(
            merge.descriptions(MODEL),
            {"a": "The first one.",
             "b": "The second one, with a comma, and a - dash."})

    def test_ignores_the_table_description(self):
        # The CREATE's OPTIONS(description) is prose in triple quotes and is
        # not a column; reading it as one would describe a column named AS.
        self.assertNotIn("AS", merge.descriptions(MODEL))


class Apply(unittest.TestCase):
    def test_sets_descriptions_on_matching_columns(self):
        fields = [{"name": "a", "type": "STRING"}, {"name": "b", "type": "INT64"}]
        missing = merge.apply(fields, dict(merge.descriptions(MODEL)))
        self.assertEqual(missing, {})
        self.assertEqual(fields[0]["description"], "The first one.")
        self.assertEqual(fields[1]["type"], "INT64", "type must survive intact")

    def test_reports_a_column_the_table_does_not_have(self):
        # The ALTER this replaces failed loudly on a renamed column. Losing
        # that would leave the column undescribed until check_described caught
        # it minutes later, naming no model.
        fields = [{"name": "a", "type": "STRING"}]
        missing = merge.apply(fields, dict(merge.descriptions(MODEL)))
        self.assertEqual(set(missing), {"b"})

    def test_leaves_undescribed_columns_alone(self):
        fields = [{"name": "a", "type": "STRING"},
                  {"name": "b", "type": "STRING"},
                  {"name": "_loaded_at", "type": "TIMESTAMP"}]
        merge.apply(fields, dict(merge.descriptions(MODEL)))
        self.assertNotIn("description", fields[2])

    def test_walks_nested_records(self):
        fields = [{"name": "a", "type": "STRING"},
                  {"name": "wrap", "type": "RECORD",
                   "fields": [{"name": "b", "type": "STRING"}]}]
        missing = merge.apply(fields, dict(merge.descriptions(MODEL)))
        self.assertEqual(missing, {})
        self.assertEqual(fields[1]["fields"][0]["description"],
                         "The second one, with a comma, and a - dash.")


class EveryRealModel(unittest.TestCase):
    def test_each_model_merges_against_its_own_columns(self):
        # Round-trip every model against a schema built from the columns it
        # describes: each must apply cleanly and leave nothing missing.
        sql_dir = pathlib.Path(__file__).resolve().parents[2] / "sql"
        models = [f for d in ("staging", "marts")
                  for f in sorted((sql_dir / d).glob("*.sql"))]
        self.assertGreater(len(models), 20)
        for model in models:
            with self.subTest(model=model.name):
                wanted = merge.descriptions(model.read_text())
                self.assertTrue(wanted, "no descriptions found")
                fields = [{"name": c, "type": "STRING"} for c in wanted]
                self.assertEqual(merge.apply(fields, dict(wanted)), {})
                self.assertTrue(all(f.get("description") for f in fields))


if __name__ == "__main__":
    unittest.main()
