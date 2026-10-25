"""audit.yml runs a fixed set of read-only checks as an account that can only read.

A dispatch input that reached a shell line, or a role that could write or
read data, would turn "let Claude run the checks itself" into a way in. These
tests hold the line on both:

  - the `check` input is a choice, and every choice maps to one script in
    this repository; there is no free-text command or query input;
  - 12-auditor.sh grants only the listed read-only roles, at project level,
    and trusts audit.yml on main and nothing else;
  - none of those roles is a data reader, a secret reader, a job runner or
    an admin;
  - 91-verify-pipelines.sh plans without gcloud.
"""

import os
import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "audit.yml"
PROJECT = "livewire-dw"
AUDITOR = f"auditor@{PROJECT}.iam.gserviceaccount.com"
READ_ONLY_ROLES = {
    "roles/iam.securityReviewer",
    "roles/iam.workloadIdentityPoolViewer",
    "roles/bigquery.metadataViewer",
    "roles/secretmanager.viewer",
    "roles/run.viewer",
    "roles/storage.bucketViewer",
}


def plan(script):
    env = dict(os.environ, DRY_RUN="1")
    out = subprocess.run([str(ROOT / "scripts" / script), "livewire"],
                         capture_output=True, text=True, env=env, cwd=ROOT)
    if out.returncode != 0:
        raise AssertionError(f"{script} dry run failed:\n{out.stdout}\n{out.stderr}")
    return out.stdout


class Workflow(unittest.TestCase):
    text = WORKFLOW.read_text()

    def test_dispatch_only(self):
        on = self.text[self.text.index("\non:"):self.text.index("\nconcurrency:")]
        self.assertIn("workflow_dispatch:", on)
        for trigger in ("schedule:", "push:", "pull_request", "workflow_run:"):
            self.assertNotIn(trigger, on)

    def test_check_is_a_choice_of_known_scripts(self):
        block = self.text[self.text.index("      check:"):self.text.index("\nconcurrency:")]
        self.assertIn("type: choice", block)
        options = re.findall(r"^\s+- ([a-z-]+)$", block, re.M)
        self.assertEqual(options, ["pipelines", "iam-snapshot"])
        run = self.text[self.text.index('case "$CHECK" in'):]
        for opt in options:
            self.assertRegex(run, rf"\n\s+{re.escape(opt)}\)\n\s+\./scripts/\S+\.sh ")
        self.assertIn("*)", run)
        self.assertIn("exit 2", run)

    def test_only_client_and_check_are_inputs(self):
        inputs = self.text[self.text.index("    inputs:"):self.text.index("\nconcurrency:")]
        names = re.findall(r"^      ([a-z_]+):$", inputs, re.M)
        self.assertEqual(names, ["client", "check"])

    def test_authenticates_as_the_auditor_variable(self):
        lines = [l.strip() for l in self.text.splitlines() if l.strip().startswith("service_account:")]
        self.assertEqual(lines, ["service_account: ${{ vars.WIF_SA_AUDIT }}"])

    def test_cannot_write_to_the_repository(self):
        self.assertIn("contents: read", self.text)
        self.assertNotIn("contents: write", self.text)


class Identity(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = plan("12-auditor.sh")

    def test_grants_exactly_the_read_only_roles(self):
        granted = set(re.findall(
            rf"projects add-iam-policy-binding {PROJECT} --member=serviceAccount:{re.escape(AUDITOR)} "
            r"--role=(\S+)", self.text))
        self.assertEqual(granted, READ_ONLY_ROLES)

    def test_no_role_reads_data_or_secrets_or_runs_jobs(self):
        banned = {
            "roles/owner", "roles/editor", "roles/viewer",
            "roles/bigquery.dataViewer", "roles/bigquery.dataEditor", "roles/bigquery.dataOwner",
            "roles/bigquery.user", "roles/bigquery.jobUser", "roles/bigquery.admin",
            "roles/secretmanager.secretAccessor", "roles/secretmanager.admin",
            "roles/storage.objectViewer", "roles/storage.objectAdmin", "roles/storage.admin",
            "roles/iam.serviceAccountTokenCreator", "roles/iam.serviceAccountUser",
            "roles/iam.securityAdmin", "roles/logging.viewer", "roles/logging.privateLogViewer",
        }
        for role in re.findall(r"--role=(\S+)", self.text):
            with self.subTest(role=role):
                self.assertNotIn(role, banned)
                self.assertNotRegex(role.rsplit(".", 1)[-1], r"(?i)(admin|editor|owner|writer)$")

    def test_trusts_audit_yml_on_main_only(self):
        members = re.findall(r"--member=(principalSet://\S+)", self.text)
        self.assertEqual(len(members), 1)
        self.assertTrue(members[0].endswith(
            "/attribute.job_workflow_ref/hfscdogg/flywheel-warehouse/.github/workflows/audit.yml@refs/heads/main"),
            members[0])

    def test_creates_no_key(self):
        self.assertNotIn("keys create", self.text)

    def test_binds_no_dataset_or_secret(self):
        self.assertNotIn("bq update", self.text)
        self.assertNotIn("secrets add-iam-policy-binding", self.text)


class VerifyPipelines(unittest.TestCase):
    def test_plans_without_gcloud(self):
        text = plan("91-verify-pipelines.sh")
        self.assertIn("read-only", text)
        self.assertIn(f"ingest-writer@{PROJECT}.iam.gserviceaccount.com is disabled", text)

    def test_runs_no_query_and_reads_no_secret(self):
        src = (ROOT / "scripts" / "91-verify-pipelines.sh").read_text()
        for forbidden in ("bq query", "secrets versions access", "add-iam-policy-binding",
                          "remove-iam-policy-binding", " disable ", " delete "):
            self.assertNotIn(forbidden, src)


if __name__ == "__main__":
    unittest.main()
