"""The lifecycle scripts undo what they do, and verify what must be absent.

Read from the dry-run plans (DRY_RUN=1 prints every command, needs no gcloud):

  - narrowing AGENT_SCOPE revokes hermes-reader's staging grant, not only
    stops adding it;
  - 11-retire strips ingest-writer and wif-rehearsal from every policy,
    deletes wif-rehearsal and any second WIF provider;
  - 99-teardown --revoke-agent takes staging too, and --full removes the
    endpoint, every secret and the federation, not just the accounts;
  - 90-verify asserts the retired and rehearsal paths are absent.
"""

import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PROJECT = "livewire-dw"


def sa(name):
    return f"{name}@{PROJECT}.iam.gserviceaccount.com"


def plan(script, *args, root=ROOT):
    env = dict(os.environ, DRY_RUN="1")
    out = subprocess.run([str(root / "scripts" / script), "livewire", *args],
                         capture_output=True, text=True, env=env, cwd=root)
    if out.returncode != 0:
        raise AssertionError(f"{script} dry run failed:\n{out.stdout}\n{out.stderr}")
    return out.stdout


def revoked_from_agent(text):
    """Datasets the plan takes hermes-reader off, in either removal form."""
    email = sa("hermes-reader")
    found = set()
    for line in text.splitlines():
        if "bq update --source <access-=" in line and email in line:
            found.add(line.rsplit(f"{PROJECT}:", 1)[1].strip())
    return found


class ScopeNarrowing(unittest.TestCase):
    def test_wide_keeps_staging_and_revokes_the_rest(self):
        revoked = revoked_from_agent(plan("03-iam.sh"))
        self.assertNotIn("staging", revoked)
        self.assertNotIn("marts", revoked)
        self.assertTrue({"raw_zoho", "raw_qbo", "analytics_285482813"} <= revoked)

    def test_narrow_revokes_staging(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            shutil.copytree(ROOT / "scripts", root / "scripts")
            shutil.copytree(ROOT / "clients", root / "clients")
            env = root / "clients" / "livewire" / "client.env"
            text = env.read_text()
            self.assertIn('AGENT_SCOPE="wide"', text)
            env.write_text(text.replace('AGENT_SCOPE="wide"', 'AGENT_SCOPE="narrow"'))
            revoked = revoked_from_agent(plan("03-iam.sh", root=root))
        self.assertIn("staging", revoked)
        self.assertNotIn("marts", revoked)


class Retirement(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = plan("11-retire-ingest-writer.sh")

    def test_both_accounts_are_taken_off_every_policy(self):
        for name in ("ingest-writer", "wif-rehearsal"):
            with self.subTest(account=name):
                self.assertIn(f"remove every binding naming {sa(name)}", self.text)

    def test_the_rehearsal_account_is_deleted(self):
        self.assertIn(f"service-accounts delete {sa('wif-rehearsal')}", self.text)

    def test_second_providers_and_loose_bindings_go(self):
        self.assertIn("delete every WIF provider but flywheel-github/github", self.text)
        self.assertIn("remove every federated binding that is not one workflow file", self.text)

    def test_no_early_exit_when_ingest_writer_is_gone(self):
        src = (ROOT / "scripts" / "11-retire-ingest-writer.sh").read_text()
        self.assertNotIn("nothing to retire", src)


class Teardown(unittest.TestCase):
    def test_revoke_agent_takes_staging_too(self):
        text = plan("99-teardown.sh", "--revoke-agent", "--yes")
        email = sa("hermes-reader")
        self.assertIn(f'"userByEmail":"{email}"}}> {PROJECT}:staging', text)
        self.assertIn(f'"userByEmail":"{email}"}}> {PROJECT}:marts', text)

    def test_full_removes_endpoint_secrets_and_federation(self):
        text = plan("99-teardown.sh", "--full", "--yes")
        self.assertIn("gcloud run services delete hermes-mcp", text)
        for secret in ("hermes-endpoint-token", "flywheel-zoho-refresh-token",
                       "flywheel-qbo-refresh-token", "flywheel-dtools-v2-refresh-token"):
            with self.subTest(secret=secret):
                self.assertIn(f"gcloud secrets delete {secret} ", text)
        self.assertIn("gcloud iam workload-identity-pools delete flywheel-github", text)
        self.assertIn("delete every WIF provider but flywheel-github/github", text)
        for name in ("hermes-reader", "ingest-zoho", "transform-writer", "endpoint-deployer",
                     "endpoint-builder", "ingest-writer", "wif-rehearsal"):
            with self.subTest(account=name):
                self.assertIn(f"service-accounts delete {sa(name)}", text)
        self.assertIn("gcloud iam roles delete flywheelSourceBucketLister", text)

    def test_the_endpoint_goes_before_its_identity(self):
        text = plan("99-teardown.sh", "--full", "--yes")
        self.assertLess(text.index("run services delete hermes-mcp"),
                        text.index(f"service-accounts delete {sa('hermes-reader')}"))


class VerifyAbsence(unittest.TestCase):
    def test_the_plan_names_every_absence(self):
        text = plan("90-verify.sh")
        self.assertIn(f"{sa('ingest-writer')} is named in no policy", text)
        self.assertIn(f"{sa('wif-rehearsal')} does not exist and is named in no policy", text)
        self.assertIn("the only WIF provider accepting GitHub tokens is flywheel-github/github", text)
        self.assertIn("every federated binding names one workflow file", text)
        self.assertIn("no grant on any project dataset outside", text)


if __name__ == "__main__":
    unittest.main()
