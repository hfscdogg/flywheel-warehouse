"""JSONPath literals in the SQL models must be ones BigQuery accepts.

sqlfluff validates SQL grammar; a JSONPath is a string literal, so every
dialect on earth parses `'$["First Name"]'` happily and BigQuery rejects it
at execution:

    Invalid token in JSONPath at: ["First Name"]

That is a whole model failing in a scheduled transform over a syntax error
nothing in CI could see. This test reads the string literals themselves.
"""

import pathlib
import re
import unittest

SQL_DIR = pathlib.Path(__file__).resolve().parents[2] / "sql"

# A JSONPath literal: a single-quoted string starting with $.
_PATH = re.compile(r"'(\$[^']*)'")


class TestJsonPaths(unittest.TestCase):
    def paths(self):
        for path in sorted(SQL_DIR.rglob("*.sql")):
            for m in _PATH.finditer(path.read_text()):
                yield path, m.group(1)

    def test_no_bracket_notation(self):
        # BigQuery supports `$.name` and, for names with spaces or other
        # awkward characters, `$."name"`. It does NOT support `$["name"]`
        # or `$['name']` — those are other dialects' spelling.
        bad = [(p.name, jp) for p, jp in self.paths() if "[" in jp]
        self.assertEqual(bad, [], "use $.\"key\" — BigQuery rejects $[\"key\"]")

    def test_quoted_keys_are_balanced(self):
        # `$."Street 1` reaches BigQuery as a runtime error too; a stray
        # quote is the likeliest typo when converting from bracket form.
        for name, jp in ((p.name, jp) for p, jp in self.paths()):
            with self.subTest(sql=name, path=jp):
                self.assertEqual(jp.count('"') % 2, 0)

    def test_keys_with_spaces_are_quoted(self):
        # `$.First Name` parses as SQL and fails in BigQuery.
        for name, jp in ((p.name, jp) for p, jp in self.paths()):
            with self.subTest(sql=name, path=jp):
                if " " in jp:
                    self.assertIn('"', jp)

    def test_the_suite_is_actually_reading_files(self):
        # A rglob that matched nothing would make every test above vacuous —
        # the failure mode this project keeps hitting.
        self.assertGreater(len(list(self.paths())), 20)


if __name__ == "__main__":
    unittest.main()
