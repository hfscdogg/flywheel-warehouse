"""The probe workflow runs arbitrary input SQL as a dataEditor identity.

`ingest-writer` holds roles/bigquery.dataEditor on every dataset (see
scripts/03-iam.sh), so BigQuery will execute whatever statement this workflow
lets through. Two things stand between a dispatch input and a dropped table,
and both are one edit away from being lost:

  the guard step   rejects anything that is not a single SELECT/WITH
  `env:` passing   keeps the SQL out of the shell command line

The second is the subtler one. `${{ inputs.sql }}` written directly into a
`run:` script is substituted by Actions BEFORE bash parses the line, so a
query containing a quote and a semicolon becomes a command on a runner that
is holding a live WIF credential. Reading it from the environment as "$SQL"
is what makes that impossible, and it looks like a style choice, which is
exactly why it needs a test.

The guard itself is re-implemented here from the workflow's own source rather
than copied, so a change to the workflow that weakens it fails these tests.
"""

import pathlib
import re
import unittest

WORKFLOWS = pathlib.Path(__file__).resolve().parents[2] / ".github" / "workflows"
PROBE = WORKFLOWS / "probe.yml"
TRANSFORM = WORKFLOWS / "transform.yml"


def guard_from_workflow():
    """Extract the guard's three rules out of probe.yml and run them."""
    src = PROBE.read_text()
    body = src[src.index("python3 - <<'PY'"):src.index("PY\n", src.index("python3 - <<'PY'"))]
    for needle in (r're.sub(r"--[^\n]*|/\*.*?\*/"', 'if ";" in bare', '^(select|with)\\b'):
        if needle not in body:
            raise AssertionError(f"guard no longer contains {needle!r}")

    def check(sql):
        bare = re.sub(r"--[^\n]*|/\*.*?\*/", " ", sql, flags=re.S).strip().rstrip(";").strip()
        if not bare:
            return False
        if ";" in bare:
            return False
        return bool(re.match(r"(?is)^(select|with)\b", bare))
    return check


class ProbeGuard(unittest.TestCase):
    def setUp(self):
        self.check = guard_from_workflow()

    def test_read_only_statements_pass(self):
        for sql in ("SELECT 1",
                    "WITH a AS (SELECT 1) SELECT * FROM a",
                    "select 1;",
                    "  \n SELECT 1 \n "):
            with self.subTest(sql=sql):
                self.assertTrue(self.check(sql))

    def test_writes_are_rejected(self):
        for sql in ("DROP TABLE marts.kpi_cash",
                    "DELETE FROM marts.kpi_cash",
                    "TRUNCATE TABLE marts.kpi_cash",
                    "MERGE INTO marts.kpi_cash USING x ON TRUE",
                    "CREATE OR REPLACE TABLE marts.x AS SELECT 1"):
            with self.subTest(sql=sql):
                self.assertFalse(self.check(sql))

    def test_a_write_hidden_behind_a_comment_is_rejected(self):
        # The reason comments are stripped BEFORE the prefix is checked: a
        # naive check sees "--" or "/*" first and reads the statement as a
        # SELECT that happens to start with a comment.
        for sql in ("-- SELECT 1\nDROP TABLE marts.kpi_cash",
                    "/* SELECT 1 */ DELETE FROM marts.kpi_cash"):
            with self.subTest(sql=sql):
                self.assertFalse(self.check(sql))

    def test_a_write_smuggled_after_a_select_is_rejected(self):
        self.assertFalse(self.check("SELECT 1; DROP TABLE marts.kpi_cash"))

    def test_an_empty_or_comment_only_query_is_rejected(self):
        for sql in ("", "   ", "-- only a comment"):
            with self.subTest(sql=sql):
                self.assertFalse(self.check(sql))

    def test_a_word_merely_starting_with_select_is_rejected(self):
        # \b, not a bare prefix match: "SELECTX" and "selectfoo()" are not
        # SELECT statements.
        for sql in ("SELECTX 1", "selectfoo()"):
            with self.subTest(sql=sql):
                self.assertFalse(self.check(sql))


class ProbeInjection(unittest.TestCase):
    """The dispatch inputs must never reach a shell command line."""

    def test_sql_is_passed_through_the_environment(self):
        src = PROBE.read_text()
        self.assertIn("SQL: ${{ inputs.sql }}", src,
                      "the SQL input must be bound to an env var")
        self.assertIn('"$SQL"', src,
                      "the guard must read the SQL from the environment")

    def test_no_dispatch_input_is_interpolated_into_a_run_script(self):
        # Every `${{ inputs.X }}` must appear under `env:`, never inside a
        # `run:` block, where Actions substitutes it before bash sees it.
        src = PROBE.read_text()
        for block in re.findall(r"^\s*run: \|\n((?:\s{10,}.*\n|\n)+)", src, re.M):
            found = re.findall(r"\$\{\{[^}]*\}\}", block)
            self.assertEqual(found, [],
                             f"a run: block interpolates {found}; bind it to "
                             f"an env var and read it as \"$VAR\" instead")

    def test_the_guard_runs_before_the_query(self):
        src = PROBE.read_text()
        self.assertLess(src.index("Reject anything but a single read-only"),
                        src.index("name: Run it"),
                        "the guard step must precede the query step")


class TransformValidateInput(unittest.TestCase):
    """VALIDATE=1 must reach the script, and must default to off."""

    def test_validate_input_is_wired_to_the_env_var(self):
        src = TRANSFORM.read_text()
        self.assertIn("VALIDATE: ${{ inputs.validate && '1' || '0' }}", src,
                      "the validate input must be passed as VALIDATE")

    def test_the_scheduled_build_is_unaffected(self):
        # On a schedule `inputs` is empty, so the expression above resolves to
        # '0'. A default of true, or a bare `${{ inputs.validate }}`, would
        # turn the nightly build into a dry run that silently stops building
        # anything -- marts would go stale with a green run.
        src = TRANSFORM.read_text()
        self.assertNotIn("VALIDATE: ${{ inputs.validate }}", src)
        block = src[src.index("validate:"):src.index("concurrency:")]
        self.assertIn("default: false", block)
