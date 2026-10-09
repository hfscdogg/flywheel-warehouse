"""The probe workflow runs input SQL, so it must run reads only.

Three things keep a dispatch input from becoming a write, and each looks like
a detail someone could tidy away:

  the account       probe.yml authenticates as warehouse-reader, which reads
                    every dataset and can write none (scripts/03-iam.sh).
  the dry run       BigQuery classifies the statement before it runs, and
                    anything but a single SELECT stops the job
                    (pipelines/lib/readonly_sql.py, tested on its own in
                    test_readonly_sql.py).
  `env:` passing    keeps the SQL out of the shell command line. A
                    `${{ inputs.sql }}` written into a `run:` script is
                    substituted before bash parses it, so a quote and a
                    semicolon become a command on a runner holding a live WIF
                    credential. test_workflow_inputs.py checks every workflow.

Until 2026-10-09 the second was a regex, which a comment marker inside a
string literal walked straight past, and the account was ingest-writer, which
holds dataEditor on every dataset.
"""

import pathlib
import unittest

WORKFLOWS = pathlib.Path(__file__).resolve().parents[2] / ".github" / "workflows"
PROBE = WORKFLOWS / "probe.yml"
TRANSFORM = WORKFLOWS / "transform.yml"


class ProbeWorkflow(unittest.TestCase):
    def src(self):
        return PROBE.read_text()

    def test_it_runs_as_the_read_only_account(self):
        self.assertIn("service_account: ${{ vars.WIF_SA_PROBE || vars.WIF_SERVICE_ACCOUNT }}",
                      self.src())

    def test_the_query_goes_through_the_dry_run_check(self):
        src = self.src()
        self.assertIn("python -m pipelines.probe", src)
        self.assertNotIn("bq query", src,
                         "a bq query step would run the SQL without BigQuery "
                         "classifying it first")
        probe = (WORKFLOWS.parents[1] / "pipelines" / "probe.py").read_text()
        self.assertIn("readonly_sql.check(", probe)
        self.assertLess(probe.index("readonly_sql.check("), probe.index("job = client.query("),
                        "the statement must be classified before it runs")

    def test_no_regex_guard_is_trusted_instead(self):
        # The regex this replaced approved SELECT '/*'; DROP ...; SELECT '*/'.
        self.assertNotIn("re.sub(", self.src())

    def test_sql_is_passed_through_the_environment(self):
        src = self.src()
        self.assertIn("SQL: ${{ inputs.sql }}", src,
                      "the SQL input must be bound to an env var")
        probe = (WORKFLOWS.parents[1] / "pipelines" / "probe.py").read_text()
        self.assertIn('os.environ.get("SQL"', probe)


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
