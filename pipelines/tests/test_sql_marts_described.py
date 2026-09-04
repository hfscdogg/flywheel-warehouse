"""Every mart, and every column of every mart, carries a BigQuery description.

hermes-mcp/server.py serves exactly these to agents: list_kpi_tables returns
the table description, get_table_schema the column descriptions. A column
without one is not undocumented — it is a column Hermes will query
confidently and explain wrong. That is the difference between an agent that
can run SQL and one that gives the right answer in Telegram.

The descriptions live in the mart SQL itself (OPTIONS on the CREATE, ALTER
COLUMN ... SET OPTIONS after it), so this test reads the SQL. It extracts the
output columns from the final SELECT and requires an ALTER for each; a new
column with no description fails here, before the scheduled transform ever
sees it. 06-transform.sh repeats the check against BigQuery after the build.
"""

import pathlib
import re
import unittest

MARTS = pathlib.Path(__file__).resolve().parents[2] / "sql" / "marts"

_TABLE_DESC = re.compile(
    r'^CREATE OR REPLACE TABLE marts\.(\w+)\nOPTIONS \(description = """\n(.+?)\n"""\)\nAS\n',
    re.S | re.M)
_ALTER = re.compile(
    r'^ALTER TABLE marts\.(\w+) ALTER COLUMN (\w+)\n  SET OPTIONS \(description = "([^"]+)"\);$',
    re.M)


def _strip_comments(sql):
    return re.sub(r"--[^\n]*", "", sql)


def final_select_columns(sql):
    """Output column names of the statement's final SELECT.

    The last top-level `SELECT` (column 0) up to the next top-level `FROM`
    is the projection; split it on depth-0 commas and take each item's alias
    or, failing that, its last dotted identifier.
    """
    # The CREATE statement only: everything before the first ALTER. Not a
    # split on ";" — the table description is prose and may contain one.
    create = sql.split("\nALTER TABLE ", 1)[0]
    create = re.sub(r'OPTIONS \(description = """.*?"""\)', "", create, flags=re.S)
    body = _strip_comments(create)
    start = body.rfind("\nSELECT\n")
    assert start >= 0, "no top-level SELECT"
    rest = body[start + len("\nSELECT\n"):]
    # kpi_cash is scalar subqueries with no FROM at all; the projection then
    # runs to the end of the statement.
    end = re.search(r"^FROM ", rest, re.M)
    proj = rest[:end.start()] if end else rest.rstrip().rstrip(";")
    items, depth, cur = [], 0, []
    for ch in proj:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            items.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    items.append("".join(cur))
    cols = []
    for item in items:
        item = " ".join(item.split())
        if not item:
            continue
        m = re.search(r"\bAS (\w+)$", item)
        cols.append(m.group(1) if m else item.split(".")[-1])
    return cols


class TestMartsDescribed(unittest.TestCase):
    def marts(self):
        files = sorted(MARTS.glob("kpi_*.sql"))
        self.assertGreater(len(files), 3, "glob matched nothing — the tests below would be vacuous")
        return files

    def test_every_mart_has_a_table_description(self):
        for f in self.marts():
            with self.subTest(mart=f.name):
                m = _TABLE_DESC.search(f.read_text())
                self.assertIsNotNone(m, "no OPTIONS (description = \"\"\"...\"\"\") on the CREATE")
                self.assertEqual(m.group(1), f.stem, "description is on a different table")
                self.assertGreater(len(m.group(2)), 80, "description too short to guide an agent")

    def test_every_output_column_is_described(self):
        for f in self.marts():
            with self.subTest(mart=f.name):
                sql = f.read_text()
                cols = final_select_columns(sql)
                described = {c: d for t, c, d in _ALTER.findall(sql) if t == f.stem}
                self.assertEqual(sorted(cols), sorted(described),
                                 "output columns and ALTER COLUMN descriptions differ")
                for c, d in described.items():
                    self.assertGreater(len(d), 15, f"{c}: description too short")

    def test_alters_name_this_mart_only(self):
        # A copy-paste from another mart would silently describe the wrong table.
        for f in self.marts():
            with self.subTest(mart=f.name):
                tables = {t for t, _, _ in _ALTER.findall(f.read_text())}
                self.assertEqual(tables, {f.stem})

    def test_descriptions_do_not_create_false_dependencies(self):
        # 06-transform.sh reads a mart's inputs by grepping for `staging.<x>`,
        # so prose that mentions a staging table would make the mart wait on it.
        for f in self.marts():
            with self.subTest(mart=f.name):
                sql = f.read_text()
                for t, c, d in _ALTER.findall(sql):
                    self.assertNotIn("staging.", d, f"{c}: names a staging table")
                m = _TABLE_DESC.search(sql)
                self.assertNotIn("staging.", m.group(2))


if __name__ == "__main__":
    unittest.main()
