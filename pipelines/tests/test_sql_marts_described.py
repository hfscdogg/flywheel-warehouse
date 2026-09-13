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

SQL = pathlib.Path(__file__).resolve().parents[2] / "sql"
# Both datasets a Tier 2b agent can read. Staging is not optional: an agent
# that can query it will, and an undescribed staging column is the same
# confidently-wrong answer as an undescribed mart column.
MODEL_DIRS = {"marts": SQL / "marts", "staging": SQL / "staging"}

_TABLE_DESC = re.compile(
    r'^CREATE OR REPLACE TABLE (marts|staging)\.(\w+)\nOPTIONS \(description = """\n(.+?)\n"""\)\nAS\n',
    re.S | re.M)
_ALTER = re.compile(
    r'^ALTER TABLE (marts|staging)\.(\w+) ALTER COLUMN (\w+)\n  SET OPTIONS \(description = "([^"]+)"\);$',
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
    def models(self):
        files = [(ds, f) for ds, d in MODEL_DIRS.items() for f in sorted(d.glob("*.sql"))
                 if f.name != "README.md"]
        self.assertGreater(len(files), 20, "glob matched nothing — the tests below would be vacuous")
        return files

    def test_every_model_has_a_table_description(self):
        for ds, f in self.models():
            with self.subTest(model=f.name):
                m = _TABLE_DESC.search(f.read_text())
                self.assertIsNotNone(m, "no OPTIONS (description = \"\"\"...\"\"\") on the CREATE")
                self.assertEqual((m.group(1), m.group(2)), (ds, f.stem), "description is on a different table")
                # Floors catch placeholders ("TODO", "tbd", "x"), not brevity:
                # "Customer email." is a complete description of a column
                # named email.
                self.assertGreater(len(m.group(3)), 60, "description too short to guide an agent")

    def test_every_output_column_is_described(self):
        for ds, f in self.models():
            with self.subTest(model=f.name):
                sql = f.read_text()
                cols = final_select_columns(sql)
                described = {c: d for s, t, c, d in _ALTER.findall(sql) if (s, t) == (ds, f.stem)}
                self.assertEqual(sorted(cols), sorted(described),
                                 "output columns and ALTER COLUMN descriptions differ")
                for c, d in described.items():
                    self.assertGreater(len(d), 8, f"{c}: description too short")

    def test_alters_name_this_model_only(self):
        # A copy-paste from another model would silently describe the wrong table.
        for ds, f in self.models():
            with self.subTest(model=f.name):
                tables = {(s, t) for s, t, _, _ in _ALTER.findall(f.read_text())}
                self.assertEqual(tables, {(ds, f.stem)})

    def test_descriptions_do_not_create_false_dependencies(self):
        # 06-transform.sh reads a model's inputs by grepping its SQL: a mart
        # waits on every `staging.<x>` it mentions, a staging model on every
        # `raw_<src>.<x>`. Prose that names one becomes a dependency.
        for ds, f in self.models():
            with self.subTest(model=f.name):
                sql = f.read_text()
                pat = r"staging\." if ds == "marts" else r"raw_[a-z0-9_]+\."
                for _, _, c, d in _ALTER.findall(sql):
                    self.assertIsNone(re.search(pat, d), f"{c}: names an input table")
                m = _TABLE_DESC.search(sql)
                self.assertIsNone(re.search(pat, m.group(3)))


class TestDescriptionsAreOneOperation(unittest.TestCase):
    """Descriptions go on in a single call, not one ALTER per column.

    BigQuery caps table metadata updates at 5 per 10 seconds per table and the
    models here carry 7 to 26 descriptions. Three attempts to pace separate
    ALTERs under that cap each failed differently, every one of them leaving a
    table rebuilt and correct with its descriptions half applied. `bq update
    --schema` writes them all at once, so there is no cap to stay under.

    If a later change reintroduces per-column ALTERs or a sleep, it has
    reintroduced that failure, and this says so.
    """

    TRANSFORM = SQL.parent / "scripts" / "06-transform.sh"

    def test_descriptions_are_written_with_one_schema_update(self):
        text = self.TRANSFORM.read_text()
        self.assertIn("bq update --schema", text)
        self.assertIn("merge_descriptions.py", text)

    def test_no_pacing_remains(self):
        text = self.TRANSFORM.read_text()
        for gone in ("DESCRIBE_BATCH", "DESCRIBE_PAUSE", "describe_batch"):
            self.assertNotIn(gone, text,
                             f"{gone} is pacing left over from the batching "
                             f"approach; one update needs no pacing")
        self.assertNotRegex(text, r"(?m)^\s*sleep ",
                            "a sleep in the transform means something is "
                            "being paced around a cap again")

    def test_the_merger_is_executable_python(self):
        merger = SQL.parent / "scripts" / "lib" / "merge_descriptions.py"
        self.assertTrue(merger.is_file(), "merge_descriptions.py is missing")
        compile(merger.read_text(), str(merger), "exec")


if __name__ == "__main__":
    unittest.main()


class TestDescriptionsAreOneTrailingBlock(unittest.TestCase):
    """The descriptions must be one contiguous block at the end of a model.

    scripts/06-transform.sh submits a model in two pieces, splitting at the
    first line that starts with `ALTER TABLE`: everything before it builds the
    table, everything after describes it, five statements at a time so the run
    stays inside BigQuery's cap of 5 metadata updates per table per 10
    seconds. It counts those five by counting lines that END in a semicolon.

    Two things have to hold for that to be right, and neither fails loudly on
    its own: nothing but descriptions may follow the first ALTER, and each
    description must be one statement over two lines. A wrapped description
    whose first line happened to end in a semicolon would be miscounted, and
    an ALTER placed mid-file would truncate the build.
    """

    def models(self):
        files = [f for d in MODEL_DIRS.values() for f in sorted(d.glob("*.sql"))]
        self.assertGreater(len(files), 20, "glob matched nothing")
        return files

    def test_nothing_but_descriptions_follows_the_first_alter(self):
        for f in self.models():
            with self.subTest(model=f.name):
                _, sep, tail = f.read_text().partition("\nALTER TABLE ")
                if not sep:
                    continue                    # no descriptions to split off
                # Whole lines, so prose inside a description cannot be mistaken
                # for SQL: every line of the block belongs to an ALTER.
                for line in _strip_comments(tail).splitlines():
                    if not line.strip():
                        continue
                    self.assertRegex(
                        line,
                        r"^(?:(?:ALTER TABLE )?(?:marts|staging)\.\w+ ALTER COLUMN \w+"
                        r"|  SET OPTIONS \(description = \".*\"\);)$",
                        "a line after the first ALTER is not part of a column "
                        "description; 06-transform.sh would pace it as one")

    def test_each_description_is_two_lines_ending_in_a_semicolon(self):
        # What the transform counts to size a batch. A description that wrapped
        # onto a third line would put more than five statements in a
        # submission, which is the cap it exists to stay under.
        for f in self.models():
            with self.subTest(model=f.name):
                _, sep, tail = f.read_text().partition("\nALTER TABLE ")
                if not sep:
                    continue
                lines = [x for x in _strip_comments(tail).splitlines() if x.strip()]
                self.assertEqual(len(lines) % 2, 0, "odd number of lines")
                for head, opts in zip(lines[::2], lines[1::2]):
                    self.assertNotRegex(head, r";\s*$", "ALTER line ends a statement early")
                    self.assertRegex(opts, r"\);\s*$", "SET OPTIONS line does not end the statement")

    def test_the_build_half_holds_exactly_one_create(self):
        # More than one statement in the build half means something other than
        # the CREATE rides along on every run. Split on the statement-ending
        # ");" of the CREATE rather than on any semicolon: a table description
        # is prose and contains them.
        for f in self.models():
            with self.subTest(model=f.name):
                build = _strip_comments(f.read_text().partition("\nALTER TABLE ")[0])
                self.assertTrue(build.lstrip().startswith("CREATE OR REPLACE TABLE"))
                self.assertEqual(build.rstrip()[-1], ";", "build does not end a statement")
                # Exactly one CREATE, and nothing else that starts a
                # statement of its own.
                self.assertEqual(
                    len(re.findall(r"(?m)^CREATE OR REPLACE TABLE ", build)), 1,
                    "more than one CREATE in the build half")
                self.assertNotRegex(
                    build, r"(?m)^(INSERT|MERGE|DROP|ALTER|TRUNCATE|GRANT)\b",
                    "a second statement in the build half")
