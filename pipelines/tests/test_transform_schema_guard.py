"""The transform reads each built table's schema back before describing it.

`bq show --schema --format=prettyjson` is trusted to put JSON on stdout and
nothing else, and when it does not, the whole nightly transform dies three
models into staging with a JSONDecodeError naming a line of Python. Every
mart behind it is left unbuilt, and nothing in the message says which table
or which command was at fault.

That happened for real on 2026-09-17: the run died at
stg_alarmdotcom__customers, the first model of the night, and the marts
carrying that day's merged SQL never got built.

The first guard written for it tested whether the file was EMPTY, on the
theory that a table with no columns was the cause. That misses the case
that actually fires: bq writing a credential WARNING to stdout, which
lands in the file because stdout is redirected into it. Such a file is not
empty, so the guard passed it to the parser and the run died anyway.

So the guard is tested here by running the real block out of the script
against real files, rather than by reading it. A guard that only recognises
one of two shapes of the same failure is the bug, not the fix.
"""

import json
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = (pathlib.Path(__file__).resolve().parents[2]
          / "scripts" / "06-transform.sh")

START = 'if [ ! -s "$schema" ]; then'
END = 'python3 "$SCRIPT_DIR/lib/merge_descriptions.py"'


def guard_source():
    """The guard block, lifted verbatim out of describe_columns."""
    src = SCRIPT.read_text()
    if START not in src:
        raise AssertionError("describe_columns no longer guards an empty schema")
    if END not in src:
        raise AssertionError("describe_columns no longer calls merge_descriptions")
    return src[src.index(START):src.index(END)].rstrip()


def run_guard(contents):
    """Run the guard over a file holding `contents`.

    Returns (rejected, log). `rejected` is whether the schema was refused and
    the table recorded, which is what keeps the run going instead of dying in
    the parser.
    """
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        handle.write(contents)
        schema = handle.name
    script = f"""
set -e
warn() {{ printf '%s\\n' "$*" >&2; }}
table="staging.stg_x"
schema="{schema}"
DESCRIBE_FAILED=""
guard() {{
{guard_source()}
  printf 'REACHED_PARSER\\n'
  return 0
}}
guard
printf 'FAILED:%s\\n' "$DESCRIBE_FAILED"
"""
    done = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    pathlib.Path(schema).unlink()
    if done.returncode != 0:
        raise AssertionError(f"guard exited {done.returncode}: {done.stderr}")
    return "REACHED_PARSER" not in done.stdout, done.stderr


def stdout_filter():
    """The sed program describe_columns pipes `bq show` through."""
    src = SCRIPT.read_text()
    for line in src.splitlines():
        if "show --schema --format=prettyjson" in line and "sed -n" in line:
            return line.split("sed -n", 1)[1].split(">", 1)[0].strip()
    raise AssertionError("describe_columns no longer filters bq's stdout")


def run_filter(text):
    """What lands in the schema file when bq prints `text`."""
    done = subprocess.run(["bash", "-c", f'sed -n {stdout_filter()}'],
                          input=text, capture_output=True, text=True)
    if done.returncode != 0:
        raise AssertionError(f"filter exited {done.returncode}: {done.stderr}")
    return done.stdout


SCHEMA = '[{"name": "customer_id", "type": "STRING"}]'
WARNING = ("WARNING: `--scopes` flag may not work as expected and will be "
           "ignored for account type external_account.")
PRETTY = '[\n  {\n    "name": "customer_id",\n    "type": "STRING"\n  }\n]\n' 


class SchemaGuard(unittest.TestCase):
    def test_json_schema_reaches_the_parser(self):
        """The ordinary case must still go through, or nothing is described."""
        rejected, _ = run_guard(SCHEMA)
        self.assertFalse(rejected)

    def test_wrapped_json_schema_reaches_the_parser(self):
        """merge_descriptions.py accepts the wrapped form; so must the guard."""
        rejected, _ = run_guard('{"schema": {"fields": ' + SCHEMA + "}}")
        self.assertFalse(rejected)

    def test_empty_schema_is_refused(self):
        rejected, log = run_guard("")
        self.assertTrue(rejected)
        self.assertIn("staging.stg_x", log)

    def test_warning_on_stdout_is_refused(self):
        """The failure that actually took the 2026-09-17 nightly transform.

        Not empty, so an emptiness test lets it through; not JSON, so the
        parser dies on it. Mutation check: drop the json.load guard from
        describe_columns and this is the test that fails.
        """
        rejected, _ = run_guard(WARNING + "\n")
        self.assertTrue(rejected)

    def test_warning_prefixed_schema_is_refused(self):
        """Valid JSON with a warning glued to the front is still not parseable."""
        rejected, _ = run_guard(WARNING + "\n" + SCHEMA)
        self.assertTrue(rejected)

    def test_refusal_logs_what_arrived(self):
        """Whatever bq did send has to reach the log, or the next person is
        diagnosing this from a Python traceback all over again."""
        _, log = run_guard(WARNING + "\n" + SCHEMA)
        self.assertIn("--scopes", log)


class StdoutFilter(unittest.TestCase):
    """The guard is the backstop; this is what stops it firing every night.

    bq puts its credential warnings on stdout, and describe_columns redirects
    stdout into the schema file, so under WIF every table in the warehouse
    got a warning glued to the front of its JSON. On 2026-09-17 that was all
    35 of them: the transform finished with fresh data and not one column
    description applied, which is the whole of what hermes-mcp serves.
    """

    def test_warning_prefix_is_dropped(self):
        kept = run_filter(WARNING + "\n" + PRETTY)
        self.assertEqual(json.loads(kept), json.loads(PRETTY))

    def test_several_warnings_are_dropped(self):
        kept = run_filter(WARNING + "\n" + WARNING + "\n" + PRETTY)
        self.assertEqual(json.loads(kept), json.loads(PRETTY))

    def test_clean_output_is_untouched(self):
        self.assertEqual(json.loads(run_filter(PRETTY)), json.loads(PRETTY))

    def test_wrapped_form_survives_the_filter(self):
        wrapped = '{\n  "schema": {\n    "fields": []\n  }\n}\n'
        self.assertEqual(json.loads(run_filter(WARNING + "\n" + wrapped)),
                         json.loads(wrapped))

    def test_filtered_warning_then_passes_the_guard(self):
        """End to end: what the filter keeps is what the guard must accept."""
        rejected, _ = run_guard(run_filter(WARNING + "\n" + PRETTY))
        self.assertFalse(rejected)

    def test_nothing_but_warnings_still_reaches_the_guard(self):
        """A filter that invents JSON would be worse than the bug. If bq sent
        no schema at all, the file must end up empty and be refused."""
        rejected, _ = run_guard(run_filter(WARNING + "\n"))
        self.assertTrue(rejected)


if __name__ == "__main__":
    unittest.main()
